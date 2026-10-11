# Headless test of goods delivery logistics (scripts/delivery_manager.gd).
#   godot --headless --path . --script res://tests/test_delivery_logistics.gd
#
# The two characteristics of a route are independent: length sets the delivery
# delay (length × transit_time_per_hex), while segment levels set the flow rate
# (average max_speed). Throughput is capped FOR EACH ROUTE SEPARATELY and PER
# PRODUCT: within one product the batches share the limit, but one product never
# spends another's, so a bulk byproduct cannot starve the staple shipped beside
# it. Different routes do not compete. Surplus of own production is not lost, but
# waits to be shipped.
#
# Cases (filter --case=<substring>):
#   delay              — before the delay elapses no goods arrive, after it they do;
#   flow_cap           — arrival does not exceed the route's flow rate;
#   batch_size         — a large batch takes longer to deliver than a small one;
#   shared_route       — several batches on one route share its limit;
#   repeat_purchases   — repeat purchases do not bypass the cap;
#   multi_product_share— a byproduct on the same route must not starve the staple;
#   simultaneous       — batches can be in transit at the same time;
#   independent_routes — different routes are independent;
#   no_loss            — neither duplicates nor losses;
#   save_load          — saving and loading of the queue and goods in transit;
#   time_scale         — a zero delta does not advance delivery, a large one does;
#   road_upgrade       — a faster route ships faster;
#   length_scales_delay— a longer route takes longer to deliver;
#   balance_driven     — the delay coefficient comes from game_balance;
#   production_queue   — improvement production goes to the queue, not to storage;
#   queue_only_backlog — the "awaiting shipment" queue shows only the real backlog.
#
# The tests do not hard-code balance numbers (10/30, 0.2): route parameters are
# set explicitly, and expectations are derived from them and from the manager's
# own SHIP_STEP, so editing data/game_balance.json and data/roads.json does not
# break these checks.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null

# Map stub: a route keyed by "row,col" -> {ok, length, avg_speed}. Lets the
# manager be exercised without a scene, roads or map generation — fast and
# deterministic.
class FakeMap:
    var routes: Dictionary = {}
    func set_route(row: int, col: int, length: int, avg_speed: float) -> void:
        routes["%d,%d" % [row, col]] = {"ok": true, "length": length, "avg_speed": avg_speed}
    func clear_route(row: int, col: int) -> void:
        routes.erase("%d,%d" % [row, col])
    func get_route_to_city(row: int, col: int) -> Dictionary:
        return routes.get("%d,%d" % [row, col], {"ok": false})

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state := {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")

    if WATCHDOG.wants_case("delay"):
        _test_delay(state)
    if WATCHDOG.wants_case("flow_cap"):
        _test_flow_cap(state)
    if WATCHDOG.wants_case("batch_size"):
        _test_batch_size(state)
    if WATCHDOG.wants_case("shared_route"):
        _test_shared_route(state)
    if WATCHDOG.wants_case("repeat_purchases"):
        _test_repeat_purchases(state)
    if WATCHDOG.wants_case("multi_product_share"):
        _test_multi_product_share(state)
    if WATCHDOG.wants_case("simultaneous"):
        _test_simultaneous(state)
    if WATCHDOG.wants_case("independent_routes"):
        _test_independent_routes(state)
    if WATCHDOG.wants_case("no_loss"):
        _test_no_loss(state)
    if WATCHDOG.wants_case("save_load"):
        _test_save_load(state)
    if WATCHDOG.wants_case("time_scale"):
        _test_time_scale(state)
    if WATCHDOG.wants_case("road_upgrade"):
        _test_road_upgrade(state)
    if WATCHDOG.wants_case("length_scales_delay"):
        _test_length_scales_delay(state)
    if WATCHDOG.wants_case("balance_driven"):
        _test_balance_driven(state)
    if WATCHDOG.wants_case("production_queue"):
        await _test_production_queue(state)
    if WATCHDOG.wants_case("queue_only_backlog"):
        await _test_queue_only_backlog(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("DELIVERY LOGISTICS TEST FAILED")
        quit(1)
    else:
        print("DELIVERY LOGISTICS TEST OK")
        quit(0)


# -------------------------------------------------------
# 1. Delay: before it elapses — empty, after it — arrives
# -------------------------------------------------------

func _test_delay(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 10, 10.0)
    check(dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm"),
            "cargo with a route must be accepted into the queue", state)

    # The first step ships the cargo (it is on the road), but it does not reach storage.
    _step(dm)
    check(_delivered("clay") == 0,
            "goods must not arrive before the delay elapses (received %d)"
                    % _delivered("clay"), state)

    # The cargo was shipped on the previous step. We advance slightly less than the
    # delay after shipment — storage is still empty.
    var delay: float = 10.0 * dm.get_transit_time_per_hex()
    _advance(dm, delay - dm.SHIP_STEP)
    check(_delivered("clay") == 0,
            "goods must not arrive before the delay elapses (received %d)"
                    % _delivered("clay"), state)

    # The rest of the delay — and all the cargo is in storage.
    _advance(dm, dm.SHIP_STEP + 0.001)
    check(_delivered("clay") == 5,
            "after the delay all the cargo must arrive (received %d)" % _delivered("clay"), state)

    # No route — the cargo is not accepted (nowhere to carry it).
    check(not dm.create_cargo(1, 1, "clay", "common", 5, "@imp:farm"),
            "without a route the cargo must not be accepted", state)
    dm.free()


# -------------------------------------------------------
# 2. Arrival does not exceed the route's flow rate
# -------------------------------------------------------

func _test_flow_cap(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    var flow := 10.0
    fake.set_route(5, 5, 3, flow)
    dm.create_cargo(5, 5, "clay", "common", 25, "@imp:farm")

    var prev := 0
    var steps := 0
    var worst := 0
    while _delivered("clay") < 25 and steps < 200:
        _step(dm)
        var now := _delivered("clay")
        worst = maxi(worst, now - prev)
        prev = now
        steps += 1
    check(_delivered("clay") == 25,
            "the whole batch must arrive (received %d)" % _delivered("clay"), state)
    check(float(worst) <= flow + 0.001,
            "arrival per step must not exceed the route's flow rate %.1f (received %d)"
                    % [flow, worst], state)
    dm.free()


# -------------------------------------------------------
# 3. A large batch takes longer to deliver than a small one
# -------------------------------------------------------

func _test_batch_size(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    # Same route, different batch size: a large one takes longer.
    var small := _time_to_deliver(fake, 10, 10, 10.0)
    var big := _time_to_deliver(fake, 100, 10, 10.0)
    check(small > 0.0 and big > small,
            "a large batch must take longer to deliver than a small one (%.1f vs %.1f)" % [big, small],
            state)
    dm.free()


# -------------------------------------------------------
# 4-5. Shared route limit: batches and repeat purchases
# -------------------------------------------------------

func _test_shared_route(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    var flow := 10.0
    fake.set_route(5, 5, 3, flow)
    # Two batches on one route, the second created a second after the first.
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    _step(dm)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")

    var prev := 0
    var steps := 0
    var worst := 0
    while _delivered("clay") < 200 and steps < 500:
        _step(dm)
        var now := _delivered("clay")
        worst = maxi(worst, now - prev)
        prev = now
        steps += 1
    check(_delivered("clay") == 200,
            "both batches must arrive in full (received %d)" % _delivered("clay"), state)
    check(float(worst) <= flow + 0.001,
            "batches of one route share its limit %.1f (arrival peak %d)"
                    % [flow, worst], state)
    dm.free()


func _test_repeat_purchases(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    var flow := 8.0
    fake.set_route(5, 5, 3, flow)
    # Many small batches in a row: none must bypass the route's shared limit.
    var created := 0
    var prev := 0
    var worst := 0
    for i in range(40):
        dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm")
        created += 5
        _step(dm)
        var now := _delivered("clay")
        worst = maxi(worst, now - prev)
        prev = now
    check(float(worst) <= flow + 0.001,
            "repeat purchases must not bypass the limit %.1f (arrival peak %d)"
                    % [flow, worst], state)
    dm.free()


# -------------------------------------------------------
# 5b. A byproduct on the same route must not starve the staple
# -------------------------------------------------------

# Regression: a food plant outputs BOTH a staple crop and a bulk byproduct on the same
# hex (data/resources/plants/food_plants.json: `produces: { lentils: 10, feed: 60 }`).
# Both enter one route, and the route's flow rate is the throughput of EVERY product, so
# the byproduct must queue while the staple keeps arriving in full. Before the fix the
# two shared one FIFO and the 60/sec byproduct occupied ~86% of it: the staple was
# starved, the city's food stayed at 0 and the population could never grow.
func _test_multi_product_share(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    _reset_storage("wheat")
    var flow := 10.0
    fake.set_route(5, 5, 1, flow)

    var staple_per_step := 10
    var byproduct_per_step := 60
    var staple_at_mid := 0
    for i in range(20):
        dm.create_cargo(5, 5, "clay", "common", staple_per_step, "@imp:farm")
        dm.create_cargo(5, 5, "wheat", "common", byproduct_per_step, "@imp:farm")
        _step(dm)
        if i == 9:
            staple_at_mid = _delivered("clay")

    var staple_last_10 := _delivered("clay") - staple_at_mid
    check(staple_last_10 == staple_per_step * 10,
            "the staple must keep arriving at its own rate beside the byproduct (received %d, expected %d)"
                    % [staple_last_10, staple_per_step * 10], state)
    check(_delivered("wheat") > 0,
            "the byproduct must still arrive within its own limit (received %d)"
                    % _delivered("wheat"), state)
    check(int(dm.get_route_status(5, 5).get("pending", 0)) > 0,
            "the byproduct's surplus must wait in the queue, not be lost", state)
    dm.free()


# -------------------------------------------------------
# 6. Batches can be in transit at the same time
# -------------------------------------------------------

func _test_simultaneous(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    _reset_storage("wheat")
    # A longer route: the delay exceeds a step, so the first batch is still on the
    # road when the second is shipped.
    fake.set_route(5, 5, 20, 10.0)
    dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm")
    _step(dm)
    # A second batch of another goods is created while the first is still on the road.
    dm.create_cargo(5, 5, "wheat", "common", 5, "@imp:farm")
    _step(dm)
    var products := _in_transit_products(dm, 5, 5)
    check(products.has("clay") and products.has("wheat"),
            "both batches must be in transit at the same time (in transit: %s)" % str(products), state)
    dm.free()


# -------------------------------------------------------
# 7. Different routes are independent
# -------------------------------------------------------

func _test_independent_routes(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    _reset_storage("wheat")
    fake.set_route(5, 5, 3, 10.0)
    fake.set_route(9, 9, 3, 30.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    dm.create_cargo(9, 9, "wheat", "common", 100, "@imp:farm")
    for i in range(5):
        _step(dm)
    check(_delivered("wheat") > _delivered("clay"),
            "a fast route must outpace a slow one (%d vs %d)"
                    % [_delivered("wheat"), _delivered("clay")], state)
    check(_delivered("clay") <= 10 * 5,
            "a slow route must not receive more than its limit (received %d)"
                    % _delivered("clay"), state)
    check(_delivered("wheat") <= 30 * 5,
            "a fast route must not receive more than its limit (received %d)"
                    % _delivered("wheat"), state)
    dm.free()


# -------------------------------------------------------
# 9. Neither duplicates nor losses
# -------------------------------------------------------

func _test_no_loss(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 4, 7.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    var steps := 0
    var peak := 0
    while _delivered("clay") < 100 and steps < 500:
        _step(dm)
        peak = maxi(peak, _delivered("clay"))
        steps += 1
    check(_delivered("clay") == 100,
            "exactly 100 units must arrive, without losses (received %d)" % _delivered("clay"), state)
    check(peak <= 100,
            "there must be no duplicates: storage holds no more than was created (peak %d)" % peak, state)
    check(int(dm.get_route_status(5, 5).get("pending", 0)) == 0
            and int(dm.get_route_status(5, 5).get("in_transit", 0)) == 0,
            "after delivery the route must become empty", state)
    dm.free()


# -------------------------------------------------------
# 10. Saving and loading of the queue and goods in transit
# -------------------------------------------------------

func _test_save_load(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 4, 7.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    for i in range(5):
        _step(dm)

    var before: Dictionary = dm.get_route_status(5, 5)
    var data: Dictionary = dm.serialize()

    var dm2 = load("res://scripts/delivery_manager.gd").new()
    dm2.initialize(fake)
    dm2.deserialize(data)
    var after: Dictionary = dm2.get_route_status(5, 5)
    check(int(after.get("pending", 0)) == int(before.get("pending", 0)),
            "the waiting queue must survive loading (%d -> %d)"
                    % [int(before.get("pending", 0)), int(after.get("pending", 0))], state)
    check(int(after.get("in_transit", 0)) == int(before.get("in_transit", 0)),
            "goods in transit must survive loading (%d -> %d)"
                    % [int(before.get("in_transit", 0)), int(after.get("in_transit", 0))], state)

    # After loading the cargo reaches the end — exactly 100, without duplicates or losses.
    var steps := 0
    while _delivered("clay") < 100 and steps < 500:
        _step(dm2)
        steps += 1
    check(_delivered("clay") == 100,
            "after loading all the cargo must arrive without duplicates or losses (received %d)"
                    % _delivered("clay"), state)
    dm.free()
    dm2.free()


# -------------------------------------------------------
# 10. Pause and time scale
# -------------------------------------------------------

func _test_time_scale(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 3, 10.0)
    dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm")

    # A zero delta (pause) advances nothing.
    dm.advance(0.0)
    check(_delivered("clay") == 0,
            "a zero delta must not advance delivery (received %d)" % _delivered("clay"), state)

    # Ship and deliver in one large step — time passes, delivery advances.
    _step(dm)
    var delay: float = 3.0 * dm.get_transit_time_per_hex()
    dm.advance(delay + 0.001)
    check(_delivered("clay") == 5,
            "a large delta must advance delivery (received %d)" % _delivered("clay"), state)
    dm.free()


# -------------------------------------------------------
# 11. A road upgrade speeds up shipment
# -------------------------------------------------------

func _test_road_upgrade(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 3, 10.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    _step(dm)
    var pending_slow := int(dm.get_route_status(5, 5).get("pending", 0))

    # Upgrade the route: same length, higher flow rate.
    fake.set_route(5, 5, 3, 30.0)
    _step(dm)
    var pending_fast := int(dm.get_route_status(5, 5).get("pending", 0))

    var shipped_slow := 100 - pending_slow
    var shipped_fast := pending_slow - pending_fast
    check(shipped_fast > shipped_slow,
            "after a road upgrade more must be shipped per step (%d vs %d)"
                    % [shipped_fast, shipped_slow], state)
    dm.free()


# -------------------------------------------------------
# 12. Route length sets the delay (independently of the coefficient)
# -------------------------------------------------------

func _test_length_scales_delay(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    # Same cargo and flow, different length: a long route takes longer to deliver.
    var short_time := _time_to_deliver(fake, 5, 3, 10.0)
    var long_time := _time_to_deliver(fake, 5, 30, 10.0)
    check(long_time > short_time,
            "a longer route must take longer to deliver (%.1f vs %.1f)"
                    % [long_time, short_time], state)
    dm.free()


# -------------------------------------------------------
# 12. The delay coefficient is centralized in the data
# -------------------------------------------------------

func _test_balance_driven(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    var value: float = dm.get_transit_time_per_hex()
    check(value > 0.0, "the delay coefficient must be positive (received %.3f)" % value, state)

    # The value comes from game_balance: substituting it in the data changes the route's delay.
    _gdata.game_balance["transit_time_per_hex"] = value * 2.0
    check(absf(dm.get_transit_time_per_hex() - value * 2.0) < 0.0001,
            "the coefficient must be read from game_balance", state)
    _gdata.game_balance["transit_time_per_hex"] = value
    dm.free()


# -------------------------------------------------------
# 3-4 (live scene). Production goes to the queue, not to storage
# -------------------------------------------------------

func _test_production_queue(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    # A synthetic resource with a controlled rate: 15 units per second through a
    # farm (interval 1). The clay product is always available and is not consumed
    # by the city, so storage does not "shrink" from do_tick and the balance
    # converges exactly.
    _gdata.raw_resources["test_clay"] = {
        "id": "test_clay", "name": "Test Clay", "type": "raw",
        "improved_by": "farm", "produces": {"clay": 15},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "a free hex in the influence must be found on the live map", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_clay"
    tile["improvement"] = "farm"
    main_map.road_manager.build_road_from(row, col, main_map.tile_data,
            main_map.map_rows, main_map.map_cols)
    check(main_map.road_manager.get_hex_road_level(row, col) == 1,
            "a road must be built to the improvement", state)

    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    check(main_map.worker_manager.assign_worker(row, col),
            "a worker must be assigned to the improvement", state)
    _cdata.city_storage["clay"] = 0
    main_map.delivery_manager.clear()

    # One production tick: goods go to the delivery queue, not to storage.
    main_map._process(1.0)
    var status: Dictionary = main_map.delivery_manager.get_route_status(row, col)
    var queued := int(status.get("pending", 0)) + int(status.get("in_transit", 0))
    check(int(_cdata.city_storage.get("clay", 0)) == 0,
            "goods with a route must not appear in storage instantly (received %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)
    check(queued == 15,
            "all 15 produced units must enter the queue (received %d)" % queued, state)

    # Stop production and let the logistics carry the cargo to the end.
    main_map.worker_manager.remove_worker(row, col)
    for i in range(40):
        _step(main_map.delivery_manager)
    check(int(_cdata.city_storage.get("clay", 0)) == 15,
            "all produced goods must reach storage (received %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)

    _free(main_map)


# -------------------------------------------------------
# 5. The "awaiting shipment" queue shows only the real backlog
# -------------------------------------------------------

# Regression: the control panel reads the queue INSIDE the tick (do_tick emits
# city_updated), so the tick's shipment must happen BEFORE that read. Otherwise
# a second's fresh production hangs as "awaiting shipment" even on a road that
# carries everything. Both ends are checked here: when the flow is not below
# production the queue is empty, when production is above the flow the queue is a
# real backlog.
func _test_queue_only_backlog(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    # A synthetic resource with a low rate (1 unit/sec through a farm): certainly
    # below the flow of any road, so no queue must appear at all.
    _gdata.raw_resources["test_clay"] = {
        "id": "test_clay", "name": "Test Clay", "type": "raw",
        "improved_by": "farm", "produces": {"clay": 1},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "a free hex in the influence must be found on the live map", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_clay"
    tile["improvement"] = "farm"
    main_map.road_manager.build_road_from(row, col, main_map.tile_data,
            main_map.map_rows, main_map.map_cols)
    check(main_map.road_manager.get_hex_road_level(row, col) == 1,
            "a road must be built to the improvement", state)

    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    main_map.worker_manager.assign_worker(row, col)
    _cdata.city_storage["clay"] = 0
    main_map.delivery_manager.clear()

    var flow := float(main_map.get_route_to_city(row, col).get("avg_speed", 0.0))
    check(flow > 1.0, "the route must carry at least 1 unit/sec (received %.1f)" % flow, state)

    # Key point: the panel and tooltip read the queue INSIDE the tick — on the
    # city_updated signal, which do_tick emits AFTER production. Therefore the queue
    # snapshot is taken right here, in the signal handler, and not after _process:
    # otherwise the test would see the already-shipped state and would not catch the
    # order.
    var capture := {"pending": -1}
    var capture_pending := func():
        var st: Dictionary = main_map.delivery_manager.get_route_status(row, col)
        capture["pending"] = int(st.get("pending", 0))
    _cdata.city_updated.connect(capture_pending)

    # One tick: production is not more than the flow — there must be no queue.
    main_map._process(1.0)
    _cdata.city_updated.disconnect(capture_pending)

    var status: Dictionary = main_map.delivery_manager.get_route_status(row, col)
    var produced := int(_cdata.city_storage.get("clay", 0)) \
            + int(status.get("pending", 0)) + int(status.get("in_transit", 0))
    check(float(produced) <= flow,
            "the test tick must produce no more than the flow %.1f (produced %d)"
                    % [flow, produced], state)
    check(int(capture["pending"]) == 0,
            "the queue the UI reads on the tick must be empty at flow %.1f (received %d)"
                    % [flow, int(capture["pending"])], state)

    # Sharply raise production above the flow: now the queue is a real backlog.
    _gdata.raw_resources["test_clay"]["produces"]["clay"] = int(flow) * 20 + 100
    main_map._process(1.0)
    status = main_map.delivery_manager.get_route_status(row, col)
    check(int(status.get("pending", 0)) > 0,
            "when production is above the flow the queue must grow (received %d)"
                    % int(status.get("pending", 0)), state)

    _free(main_map)


# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# A new delivery manager on a fresh map stub: [manager, stub].
func _new_manager() -> Array:
    var fake := FakeMap.new()
    var dm = load("res://scripts/delivery_manager.gd").new()
    dm.initialize(fake)
    return [dm, fake]


# One step of game time: intake (per-frame) + one shipment (per-tick) — the same
# order as in main_map._process. Shipment is called AFTER intake, as in the game.
func _step(dm) -> void:
    dm.advance(dm.SHIP_STEP)
    dm.ship()


# Time (in seconds of game time) until the full delivery of amount units along a
# route with the given length and flow rate. Runs ITS OWN manager so that the
# leftover accumulator of the previous case does not shift the count.
func _time_to_deliver(fake: FakeMap, amount: int, length: int, flow: float) -> float:
    var dm = load("res://scripts/delivery_manager.gd").new()
    dm.initialize(fake)
    _reset_storage("clay")
    fake.set_route(5, 5, length, flow)
    dm.create_cargo(5, 5, "clay", "common", amount, "@imp:farm")
    var elapsed := 0.0
    var steps := 0
    while _delivered("clay") < amount and steps < 1000:
        _step(dm)
        elapsed += dm.SHIP_STEP
        steps += 1
    dm.free()
    return elapsed


# Advance only the intake by seconds of game time in steps of SHIP_STEP:
# shipment is NOT called — this checks that the cargo arrives on its own by the
# time count.
func _advance(dm, seconds: float) -> void:
    var left := seconds
    while left > 0.0001:
        var step: float = minf(dm.SHIP_STEP, left)
        dm.advance(step)
        left -= step


func _in_transit_products(dm, row: int, col: int) -> Array:
    var key := "%d,%d" % [row, col]
    var out: Array = []
    if not dm._routes.has(key):
        return out
    for entry in dm._routes[key]["in_transit"]:
        out.append(str(entry["product"]))
    return out


func _delivered(pid: String) -> int:
    return int(_cdata.city_storage.get(pid, 0))


func _reset_storage(pid: String) -> void:
    _cdata.city_storage[pid] = 0
    _cdata.city_quality_detail[pid] = {}


# The first free hex in the Ring of Influence: dry, known, without an improvement,
# town or road, without access to fresh water (otherwise the production multiplier
# would shift) — AND with a reachable road plan.
func _find_hex_in_influence(main_map) -> Dictionary:
    var mh = load("res://scripts/map_helpers.gd")
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("decorative", false):
                continue
            if tile.get("in_town_influence", false):
                continue
            if not main_map.is_hex_known(row, col):
                continue
            if mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if mh.get_hex_water_access(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols) != "":
                continue
            if main_map.road_manager.get_hex_road_level(row, col) > 0:
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
                continue
            return {"row": row, "col": col}
    return {}


func _free(main_map) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
