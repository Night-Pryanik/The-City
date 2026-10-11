# delivery_manager.gd
#
# The logistics of the goods on their way to the city. A single central place that
# answers two questions for every route: how fast the road can carry the cargo, and
# how long the cargo is on the road before it starts arriving.
#
# TWO INDEPENDENT CHARACTERISTICS OF A ROUTE (see data/game_balance.json, "logistics"):
#   · the FLOW RATE (units/sec) — the throughput. It is the average max_speed of the
#     segments of the route (data/roads.json), taken from road_manager.find_route_to_city.
#     It is NOT stored here: the road owns it, and the route re-reads it every step, so
#     an upgraded segment changes the flow of the route immediately.
#   · the TRANSIT DELAY (sec) — how long a shipped load travels before it starts to
#     arrive. It is the length of the route in hexes × transit_time_per_hex. A longer
#     route is slower, but a better road is not automatically shorter: the two numbers
#     do not depend on each other.
#
# HOW A CARGO MOVES. Goods produced by an improvement (and, in the future, bought from
# a town) are not put into the city storage at once. They are queued on the route and
# shipped at the flow rate; each shipped load then spends the transit delay on the road
# and is credited to the storage when it arrives. So the road no longer DESTROYS the
# surplus of a fast improvement (it used to be clamped and lost) — the surplus simply
# waits in the queue and is delivered later.
#
# THE FLOW IS PER ROUTE AND PER PRODUCT, AND IS NOT SHARED BETWEEN ROUTES. A route's
# flow rate applies to EACH product it carries separately, so a hex that outputs both a
# staple and a bulk byproduct cannot let the byproduct starve the staple: the byproduct
# queues while the staple keeps arriving. This is the same per-product comparison the
# tooltip makes (map_tooltip.road_capacity_shortfall), so the red road note and the
# delivery agree. Within ONE product the order is FIFO, so no purchase can jump the
# queue. Two different routes do not compete: the road network is not a physical system,
# there is no congestion and no splitting of the throughput of a segment. Three farms on
# three 30-units/sec routes deliver up to 90 units/sec in total even if the routes share
# a segment.
#
# PERFORMANCE. There is no timer and no update loop per batch. main_map calls advance()
# once per frame (only the arrivals walk the routes) and ship() once per simulation
# tick, right after the production of that tick. The number of in-transit records of a
# route is bounded by the transit delay, not by the frame rate.
extends Node

# The transit time per hex used when the balance file has no value. It matches the
# default in data/game_balance.json; the constant exists only so that the game does
# not fall apart on a hand-edited balance file with the field removed.
const DEFAULT_TRANSIT_TIME_PER_HEX := 0.2

# The length of one shipping step, in seconds. It equals the simulation tick: ship() is
# called once per tick, so a route moves flow_rate × SHIP_STEP units per second.
const SHIP_STEP := 1.0

var _main_map = null

# The state of the routes: "row,col" of the SOURCE hex -> the route. The source hex is
# either an improvement of the player or a town (for its future purchases); a hex is
# never both, so one key space is enough. The route stores only the CARGO, never the
# flow or the delay: those belong to the road and are re-read on every shipping step.
#
#   row, col    — the source hex (kept for the route lookup and the save);
#   pending     — the FIFO of the loads waiting to be shipped:
#                 {product, quality, amount (int), source};
#   in_transit  — the loads already on the road: {product, quality, amount (int),
#                 source, remaining (sec)}. The remaining time is a countdown, not an
#                 absolute timestamp, so the save does not depend on a clock;
#   ship_accum  — the per-product fractional credit of the shipping, in units:
#                 {product: float}. It carries the sub-unit remainder between the steps,
#                 so the average flow does not drift for a fractional flow rate (for
#                 example, 28.3 units/sec). One credit per product on purpose: the flow
#                 rate is the throughput of EVERY product, not of the route as a whole.
var _routes: Dictionary = {}


# The reference to main_map is the only way to the routes (get_route_to_city). It is
# passed explicitly, like to the other managers, and not reached through the tree, so
# that a test can drive the manager on a bare scene.
func initialize(main_map) -> void:
    _main_map = main_map
    _routes.clear()


# Drops every route. A new game (and a load) starts from a clean sheet, otherwise the
# cargo of the previous party would leak into the next one.
func clear() -> void:
    _routes.clear()


func get_transit_time_per_hex() -> float:
    var value := float(GameData.game_balance.get("transit_time_per_hex", DEFAULT_TRANSIT_TIME_PER_HEX))
    return value if value > 0.0 else DEFAULT_TRANSIT_TIME_PER_HEX


# The parameters of the route from the hex: {"flow_rate": float, "transit_delay": float},
# or an empty dictionary when there is no route. The flow and the delay are recomputed
# from the road every time, so an upgraded segment is reflected at once.
func get_route_info(row: int, col: int) -> Dictionary:
    return _route_params(row, col)


# Advances the arrivals by the frame delta. It is called by main_map once per frame:
# the transit delay is a game-time countdown, so it must not be rounded to whole ticks.
func advance(delta: float) -> void:
    if delta <= 0.0:
        return
    _advance_arrivals(delta)


# One shipping step for every route: each route ships up to flow_rate × SHIP_STEP units
# of EVERY product it is waiting on, FIFO within a product. main_map calls it once per
# simulation tick, right after the production of that tick and BEFORE the interface reads
# the queue (see main_map._process). So the goods of the current tick are already on the
# road when the panel and the tooltip refresh: the "waiting to ship" row shows the real
# backlog of a slow road, and never the fresh production of the second that has just passed.
func ship() -> void:
    var empty_keys: Array = []
    for key in _routes.keys():
        var route: Dictionary = _routes[key]
        var params := _route_params(int(route["row"]), int(route["col"]))
        if params.is_empty():
            # The road is gone (or became unusable). The goods were produced, so they
            # are handed over at once instead of being stranded on a route that no
            # longer exists; the road that is gone cannot limit anything.
            _flush_route(route)
            empty_keys.append(key)
            continue
        _ship_route(route, float(params["flow_rate"]), float(params["transit_delay"]))
        if route["pending"].is_empty() and route["in_transit"].is_empty():
            empty_keys.append(key)
    for key in empty_keys:
        _routes.erase(key)


# Queues a load on the route from the hex. This is the single entry point for both the
# production of the improvements and the (future) purchases from the towns.
#
# It returns false when the goods cannot be routed — there is no road to the city, or
# the amount is not positive. The caller then decides what to do with the goods (the
# production delivers them at once, since a road that does not exist cannot limit
# anything). It returns true when the load has been queued (or handed to a route that
# is already on the road): from that moment the logistics owns it, and the caller must
# NOT credit the storage itself, or the goods would be counted twice.
func create_cargo(row: int, col: int, product: String, quality: String,
        amount: int, source: String = "") -> bool:
    if amount <= 0 or product.is_empty():
        return false
    if _route_params(row, col).is_empty():
        return false
    var route := _get_or_create_route(row, col)
    _push_pending(route, product, quality, amount, source)
    return true


# --- The status for the interface ---

# Everything the interface needs to explain the delivery on the hex:
#   has_route     — whether a route exists at all;
#   flow_rate     — the throughput of the route (units/sec), 0 when there is none;
#   transit_delay — the transit delay of the route (sec), 0 when there is none;
#   pending       — the units waiting to be shipped;
#   in_transit    — the units already on the road;
#   eta           — the time (sec) until the LAST of the in-transit loads arrives, 0
#                   when nothing is on the road. The last one, not the first: the
#                   player reads it as "when the current cargo will have arrived".
func get_route_status(row: int, col: int) -> Dictionary:
    var params := _route_params(row, col)
    var status := {
        "has_route": not params.is_empty(),
        "flow_rate": float(params.get("flow_rate", 0.0)),
        "transit_delay": float(params.get("transit_delay", 0.0)),
        "pending": 0,
        "in_transit": 0,
        "eta": 0.0,
    }
    var route = _routes.get(_route_key(row, col), null)
    if route == null:
        return status
    var pending := 0
    for entry in route["pending"]:
        pending += int(entry.get("amount", 0))
    var in_transit := 0
    var eta := 0.0
    for entry in route["in_transit"]:
        in_transit += int(entry.get("amount", 0))
        eta = maxf(eta, float(entry.get("remaining", 0.0)))
    status["pending"] = pending
    status["in_transit"] = in_transit
    status["eta"] = eta
    return status


# Whether the route has any cargo at all (waiting or on the road). The interface uses
# it to decide whether the delivery rows are worth showing.
func has_cargo(row: int, col: int) -> bool:
    var route = _routes.get(_route_key(row, col), null)
    if route == null:
        return false
    return not route["pending"].is_empty() or not route["in_transit"].is_empty()


# --- The shipping and the arrivals ---

# Advances every in-transit load by the frame delta and credits the arrived ones to the
# city storage. The loads were already produced (and, for a purchase, already paid for),
# so the delivery is the only place that turns them into the storage — no duplication,
# no loss.
func _advance_arrivals(delta: float) -> void:
    for key in _routes.keys():
        var route: Dictionary = _routes[key]
        var transit: Array = route["in_transit"]
        var i := 0
        while i < transit.size():
            var entry: Dictionary = transit[i]
            entry["remaining"] = float(entry.get("remaining", 0.0)) - delta
            if float(entry["remaining"]) <= 0.0:
                _deliver(entry)
                transit.remove_at(i)
            else:
                i += 1


func _ship_route(route: Dictionary, flow_rate: float, transit_delay: float) -> void:
    var credits: Dictionary = route["ship_accum"]
    # Every product waiting on this route gets its own full budget for the step: the
    # flow rate is the throughput PER PRODUCT, so a product cannot spend another's.
    var waiting: Dictionary = {}
    for entry in route["pending"]:
        waiting[str(entry["product"])] = true
    for product in waiting:
        credits[product] = float(credits.get(product, 0.0)) + flow_rate * SHIP_STEP
    _dispatch(route, credits, transit_delay)
    # Only the sub-unit remainder carries over to the next step: the flow is a rate, not
    # a reservoir, so a product that shipped less than it could (or had nothing to ship)
    # must not bank the spare throughput and dump it in a burst later.
    for product in credits.keys():
        credits[product] = fmod(float(credits[product]), 1.0)


# Moves each product's share of the queue onto the road, walking the queue in order. The
# budget of a product is its own credit (see _ship_route), so within a product the queue
# stays FIFO while a bulk byproduct can no longer delay the staple behind it.
func _dispatch(route: Dictionary, credits: Dictionary, transit_delay: float) -> void:
    var pending: Array = route["pending"]
    var i := 0
    while i < pending.size():
        var head: Dictionary = pending[i]
        var product := str(head["product"])
        var budget := int(floor(float(credits.get(product, 0.0))))
        if budget <= 0:
            i += 1
            continue
        var take: int = mini(int(head["amount"]), budget)
        head["amount"] = int(head["amount"]) - take
        credits[product] = float(credits[product]) - float(take)
        _add_in_transit(route, product, str(head["quality"]), take,
                str(head["source"]), transit_delay)
        if int(head["amount"]) <= 0:
            pending.remove_at(i)
        # A partially shipped head keeps its place (still at i); its budget is spent, so
        # the next iteration moves past it.


# Adds a shipped load to the road. Loads created in the same shipping step share the
# same remaining time, so they are merged into the tail record: without this a large
# route would keep one record per step instead of one per product.
func _add_in_transit(route: Dictionary, product: String, quality: String,
        amount: int, source: String, transit_delay: float) -> void:
    var transit: Array = route["in_transit"]
    if not transit.is_empty():
        var last: Dictionary = transit[transit.size() - 1]
        if str(last["product"]) == product and str(last["quality"]) == quality \
                and str(last["source"]) == source \
                and is_equal_approx(float(last["remaining"]), transit_delay):
            last["amount"] = int(last["amount"]) + amount
            return
    transit.append({
        "product": product,
        "quality": quality,
        "amount": amount,
        "source": source,
        "remaining": transit_delay,
    })


# Turns an arrived load into the city storage. The quality is preserved, and the source
# is recorded here (and not at the moment of the production) because this is the moment
# the goods actually reach the city.
func _deliver(entry: Dictionary) -> void:
    var amount := int(entry.get("amount", 0))
    if amount <= 0:
        return
    var product := str(entry.get("product", ""))
    CityData.add_to_storage(product, amount, str(entry.get("quality", "common")))
    CityData.record_production_source(product, str(entry.get("source", "")), amount)


# Hands over everything the route still holds. It is used when the route ceases to
# exist: the produced goods must not be lost, and there is nothing left to limit them.
func _flush_route(route: Dictionary) -> void:
    for entry in route["in_transit"]:
        _deliver(entry)
    route["in_transit"].clear()
    for entry in route["pending"]:
        _deliver(entry)
    route["pending"].clear()


# --- The helpers of the routes ---

func _route_key(row: int, col: int) -> String:
    return "%d,%d" % [row, col]


func _get_or_create_route(row: int, col: int) -> Dictionary:
    var key := _route_key(row, col)
    if not _routes.has(key):
        _routes[key] = {
            "row": row,
            "col": col,
            "pending": [],
            "in_transit": [],
            "ship_accum": {},
        }
    return _routes[key]


# The FIFO tail is merged when the load is the same product of the same quality from
# the same source: the queue keeps one record per such run instead of one per tick,
# and the order of the shipments does not change (the tail is the newest load anyway).
func _push_pending(route: Dictionary, product: String, quality: String,
        amount: int, source: String) -> void:
    var pending: Array = route["pending"]
    if not pending.is_empty():
        var last: Dictionary = pending[pending.size() - 1]
        if str(last["product"]) == product and str(last["quality"]) == quality \
                and str(last["source"]) == source:
            last["amount"] = int(last["amount"]) + amount
            return
    pending.append({
        "product": product,
        "quality": quality,
        "amount": amount,
        "source": source,
    })


# The flow and the delay of the route, or an empty dictionary when there is none. The
# flow is the average speed of the segments; the delay is the length of the route in
# hexes × the transit time per hex.
func _route_params(row: int, col: int) -> Dictionary:
    if _main_map == null or not _main_map.has_method("get_route_to_city"):
        return {}
    var route: Dictionary = _main_map.get_route_to_city(row, col)
    if not route.get("ok", false):
        return {}
    var flow := float(route.get("avg_speed", 0.0))
    if flow <= 0.0:
        return {}
    var delay := float(int(route.get("length", 0))) * get_transit_time_per_hex()
    return {"flow_rate": flow, "transit_delay": delay}


# --- The save ---

# The state of the routes for the save. The flow and the delay are not written: they
# belong to the road and are recomputed on the next step, so a save does not freeze a
# stale throughput. The remaining time of an in-transit load is a countdown, so it
# survives the load without any reference to a clock.
func serialize() -> Dictionary:
    var out: Dictionary = {}
    for key in _routes.keys():
        var route: Dictionary = _routes[key]
        var pending: Array = []
        for entry in route["pending"]:
            pending.append({
                "product": str(entry["product"]),
                "quality": str(entry["quality"]),
                "amount": int(entry["amount"]),
                "source": str(entry["source"]),
            })
        var transit: Array = []
        for entry in route["in_transit"]:
            transit.append({
                "product": str(entry["product"]),
                "quality": str(entry["quality"]),
                "amount": int(entry["amount"]),
                "source": str(entry["source"]),
                "remaining": float(entry["remaining"]),
            })
        var credits: Dictionary = {}
        for product in route["ship_accum"]:
            credits[str(product)] = float(route["ship_accum"][product])
        out[key] = {
            "row": int(route["row"]),
            "col": int(route["col"]),
            "pending": pending,
            "in_transit": transit,
            "ship_accum": credits,
        }
    return out


# Restores the routes from a save. The values come back from JSON, therefore the
# integers arrive as floats and every field is coerced back to its type here; a record
# without a product or a non-positive amount is dropped instead of being carried as a
# broken load that could never be delivered.
func deserialize(data) -> void:
    _routes.clear()
    if not (data is Dictionary):
        return
    for key in data.keys():
        var entry = data[key]
        if not (entry is Dictionary):
            continue
        var row := int(entry.get("row", -1))
        var col := int(entry.get("col", -1))
        if row < 0 or col < 0:
            continue
        var route := _get_or_create_route(row, col)
        var credits: Dictionary = {}
        var saved_credits = entry.get("ship_accum", {})
        if saved_credits is Dictionary:
            for product in saved_credits:
                credits[str(product)] = float(saved_credits[product])
        route["ship_accum"] = credits
        for pending_entry in entry.get("pending", []):
            if not (pending_entry is Dictionary):
                continue
            var amount := int(pending_entry.get("amount", 0))
            var product := str(pending_entry.get("product", ""))
            if amount <= 0 or product.is_empty():
                continue
            route["pending"].append({
                "product": product,
                "quality": str(pending_entry.get("quality", "common")),
                "amount": amount,
                "source": str(pending_entry.get("source", "")),
            })
        for transit_entry in entry.get("in_transit", []):
            if not (transit_entry is Dictionary):
                continue
            var amount := int(transit_entry.get("amount", 0))
            var product := str(transit_entry.get("product", ""))
            if amount <= 0 or product.is_empty():
                continue
            route["in_transit"].append({
                "product": product,
                "quality": str(transit_entry.get("quality", "common")),
                "amount": amount,
                "source": str(transit_entry.get("source", "")),
                "remaining": maxf(0.0, float(transit_entry.get("remaining", 0.0))),
            })
