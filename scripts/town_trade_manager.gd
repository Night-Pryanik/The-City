# town_trade_manager.gd
# The trade of the city with the towns (small settlements): the mechanics behind the
# order the town window assembles (town_ui.trade_order_submitted).
#
# TWO KINDS OF A DEAL (the "Permanent" checkbox of the trade panel):
#   · A ONE-TIME PURCHASE is settled the moment it is confirmed: the coins move
#     from the treasury of the city into the treasury of the town, the units are
#     written off the warehouse of the town, and the goods are queued on the route
#     from the town to the city (delivery_manager.create_cargo) — the road limits
#     the trade exactly like it limits the production of an improvement.
#   · A STANDING CONTRACT repeats every tick of the city: the town owes `amount`
#     units of the good per second, and the city pays `amount × unit_price` coins
#     per second. The unit price is frozen at the moment of signing. A contract
#     that cannot be paid (the treasury is short) or cannot be fulfilled (the town
#     ran out of the good) is torn automatically — a contract is not a debt, and
#     neither side can be forced into one.
#     What backs a contract is the SUPPLY of the town and not its stock: a town serves an
#     order up to its comfort rate for free, and above it strains — the output follows the
#     order but always falls short of it, so the warehouse drains the faster, the bigger
#     the order (see the supply section of town_economy.gd). The stock is the buffer, the
#     supply is the rate.
#
# THE DELIVERY. The town window can only open a purchase when the road to the town
# exists (town_manager.is_trade_available), and the goods move along that road with
# the standard limits: they queue on the route, are shipped at its flow rate and
# reach the city storage after the transit delay. When there is no route at all
# (a road that does not exist cannot limit anything), the goods are credited to the
# storage at once — the same fallback the production of the improvements uses.
#
# THE LIST OF THE DEALS. The "Trade deals" section of the "Trade" tab shows both kinds of a
# deal (external_trade_tab._collect_deals reads them through main_map.get_town_contracts and
# main_map.get_town_deliveries): the standing contracts, and the one-time purchases whose
# goods are still on the road. A purchase that the road did not limit at all — there is no
# route, or the route shipped it whole in the same tick — leaves nothing to list: it is
# settled, and a row for it would only be a row that cannot be cancelled.
#
# CANCELLING A ONE-TIME PURCHASE. Only the part that has NOT been shipped can be withdrawn:
# the units already dispatched are on the road and beyond recall. The withdrawal puts the
# un-shipped units back into the warehouse of the town and returns their coins to the
# treasury — exactly what the player paid for them, so a cancellation is never a loss and
# never a gain. The queue of a route is shared by everything on it and its units are
# fungible (see delivery_manager), so the un-shipped part of a purchase cannot be read from
# the queue: it is tracked in a LEDGER beside it (_deliveries), fed by the shipments the
# queue announces (delivery_manager.cargo_shipped).
#
# ONE CONTRACT PER GOOD AND TOWN. A town carries at most ONE standing contract for a
# given good — the pair (town, good) is the identity of a deal. An order for a pair that
# already carries a contract therefore EDITS that contract instead of signing a second
# one: only the amount moves, the unit price stays frozen at the price of the signed deal.
# A different price is a different deal, and the way to it is the pair "close the contract
# (close_contract) and sign a new one". The window reads the contract of a row through
# main_map.get_town_contract and opens its settings as an edit of it.
extends Node

# The prefix of the delivery source of a town purchase (the cargo record). The
# source is not displayed anywhere (CityData.record_production_source keeps only the
# fact of the production), the id exists so that the cargo of a purchase can be
# told apart from the cargo of an improvement.
const CARGO_SOURCE_PREFIX := "@town:"

# How many units a deal moves at minimum. The order comes from the window, where
# the amount never falls below 1; the constant keeps the manager safe against a
# hand-made order as well.
const MIN_AMOUNT := 1

# The kind of a deal, as the rows of the "Trade deals" section carry it. The pair
# (town, good) is the identity of a CONTRACT, and a one-time purchase of the same good from
# the same town can stand beside it — so the kind is what tells the two rows apart, and the
# section keys the inline editor of a contract by "kind|town|good" for the same reason.
const KIND_CONTRACT := "contract"
const KIND_DELIVERY := "delivery"

var _town_manager = null
var _delivery_manager = null

# The standing contracts, in the order they were signed. One town carries at most one
# contract per good (see the header), so the pair (town_id, product_id) is unique across
# the list. One record:
#   id            the identifier of the contract ("contract_7");
#   town_id       the id of the town (the reliable key of the town record);
#   town_name     its name, frozen at the signing (the label of the deal);
#   row, col      the hexes of the town (the route and the delivery);
#   product_id    the id of the goods the city buys;
#   product_name  its display name, frozen at the signing;
#   quality       the level of the goods in the warehouse of the town;
#   amount        the units the town owes per tick;
#   unit_price    the coins per unit, frozen at the signing;
#   cost_per_tick amount × unit_price — what the treasury pays every tick.
var _contracts: Array = []

# The serial of the next contract id. It only grows, so an id is never reused
# within a party (a save keeps the contracts, and the counter continues from the
# largest restored one).
var _next_contract_id := 1

# The fraction of a unit of the drain still owed by the warehouse of a town, keyed by
# "town_id|product_id". The drain of a contract is a fraction of a unit per tick, while
# the warehouse holds whole units; the remainder is carried here so that a slow drain is
# paid in full instead of being rounded away on every tick. It is transient state of the
# tick and is NOT saved — a reload loses less than one unit of the drain.
var _drain_remainder: Dictionary = {}

# The one-time purchases whose goods are still on the road, keyed by "town_id|product_id" —
# the pair that is the identity of a deal (see the header). The ledger exists because the
# queue of a route cannot answer the only question a cancellation asks: how much of what the
# player paid for has NOT left the town yet.
#
# A SECOND PURCHASE OF THE SAME GOOD FROM THE SAME TOWN ADDS TO THE FIRST: the pair is one
# deal, so the row is one row with the totals of both (ordered / still on the way). One record:
#   town_id, town_name, product_id, product_name, row, col
#               — the deal, kept the way a contract keeps its own;
#   ordered     — the units of every purchase of the pair, summed;
#   remaining   — the units still WAITING in the queue of the route: exactly what a
#                 cancellation can withdraw;
#   spent       — the coins paid for `remaining` units, that is the refund: the sum over the
#                 lots of (lot.amount × lot.unit_price);
#   unit_price  — the price of the last purchase of the pair (what the row shows);
#   lots        — the FIFO of the un-shipped purchase lots: {amount, unit_price}. The price
#                 is frozen per lot — the price of the purchase that created it — so a refund
#                 never pays back more than the player actually paid.
var _deliveries: Dictionary = {}

# The units a standing contract has queued on the route and not yet shipped, keyed by
# "town_id|product_id".
#
# A one-time purchase and a standing contract of the same good from the same town are ONE
# stream on the road: the same product, quality and source, so the queue of the route merges
# them into one record (delivery_manager._push_pending) and a shipment cannot be told apart by
# looking at it. The ledger does it: the contract's supply is created every tick and the town
# serves it, so the throughput is spent on the contract BEFORE anything reaches a purchase,
# and only the excess drains a purchase. That is why a purchase behind a contract that
# saturates the road stays whole — and why it can still be cancelled for its full value
# instead of being written off against goods that were never its own.
var _contract_outstanding: Dictionary = {}

# The trade mechanics changed the list of the contracts (signed, updated or torn). The
# column of the deals reads the list on its own rhythm (external_trade_tab.update_values);
# the signal is for the callers that must react at once — the trade panel of the town window
# follows the contract of the good it shows by it (town_ui.on_contracts_changed), so an
# order that has just become a standing contract is editable on the spot.
signal contracts_changed()

# A message for the player: a contract that could not be paid or fulfilled. The
# map shows it in the HUD (see main_map._on_town_trade_notice).
signal notice(message: String, message_type: int)


# The references are passed explicitly, like to the other managers: the towns give
# the warehouse and the treasury, the logistics owns the route from a town to the
# city. A test can drive the manager on a bare scene with a map stub.
func initialize(town_manager, delivery_manager) -> void:
    _town_manager = town_manager
    _delivery_manager = delivery_manager
    _contracts.clear()
    _next_contract_id = 1
    _drain_remainder.clear()
    _deliveries.clear()
    _contract_outstanding.clear()
    # The ledger of the deliveries is fed by the queue itself: the shipments of a route are
    # what tell it how much of a purchase has left the town and is therefore no longer
    # cancellable (see _on_cargo_shipped). The connection is guarded, so a manager
    # re-initialized for a new party does not end up listening twice and counting each
    # shipment double.
    if _delivery_manager != null and _delivery_manager.has_signal("cargo_shipped") \
            and not _delivery_manager.cargo_shipped.is_connected(_on_cargo_shipped):
        _delivery_manager.cargo_shipped.connect(_on_cargo_shipped)


# Drops every contract and every delivery. A new game starts from a clean sheet, otherwise the
# deals of the previous party would be paid by the next one.
func clear() -> void:
    _contracts.clear()
    _next_contract_id = 1
    _drain_remainder.clear()
    _deliveries.clear()
    _contract_outstanding.clear()


# Processes one order from the town window. It returns {"ok": bool, "message":
# String}: the map reports the message in the HUD, both for a settled deal and for a
# refusal (see main_map._on_town_trade_order). The window itself claims nothing about
# the outcome of the order it has handed over.
#
# The order is the dictionary assembled by town_ui._on_confirm_pressed:
#   town_id, town_name, row, col, side ("buy"/"sell"), product_id, product_name,
#   amount, permanent, route_capacity, unit_price.
func submit_order(order: Dictionary) -> Dictionary:
    if str(order.get("side", "")) != "sell":
        # The city sells to a town (the purchase column of the window): the
        # mechanics of that direction do not exist yet.
        return {"ok": false,
                "message": tr("Selling goods to the towns is not implemented yet — the order was not placed.")}
    var amount := int(order.get("amount", 0))
    if amount < MIN_AMOUNT:
        return {"ok": false, "message": tr("The amount must be a positive whole number")}
    var town = _find_town(order)
    if town == null:
        return {"ok": false, "message": tr("The town is not on the map anymore")}
    var product_id := str(order.get("product_id", ""))
    var unit_price := int(order.get("unit_price", 0))
    if unit_price <= 0:
        # A hand-made order without the price of the window: the price is
        # recomputed by the same rule the row showed.
        unit_price = _unit_price_of(town, product_id)
    if bool(order.get("permanent", false)):
        var index := _contract_index(str(town.get("id", "")), product_id)
        if index >= 0:
            # One contract per good and town: an order for a pair that already carries a
            # contract is an edit of it, never a second deal.
            return _update_contract(index, amount)
        return _sign_contract(town, product_id, amount, unit_price)
    return _buy_once(town, product_id, amount, unit_price)


# One Tick of the city: every standing contract is paid and fulfilled. It is
# called by main_map inside the block of the simulation tick, before the shipping,
# so that the goods of a contract share the road with the production of the tick.
#
# It also writes the PLAN of the tick (CityData.record_planned_town_production): the
# standing contracts are a per-second inflow exactly like a working improvement, and the
# green dynamics of the tab "Resources" reads the planned production only — without this
# the goods would arrive while the row insisted that nothing is coming.
func tick_contracts() -> void:
    if _contracts.is_empty():
        return
    # What backs a contract is the SUPPLY of the town, not its stock (see the supply
    # section of town_economy.gd): the stock is only the buffer behind the rate. The
    # supply is credited to the warehouse once per town and product, on the summed demand
    # of that pair, so the rate a town serves is counted exactly once.
    var demand := _aggregate_demand()
    var credited: Dictionary = {}
    var i := 0
    while i < _contracts.size():
        var contract: Dictionary = _contracts[i]
        var town = _town_by_id(str(contract.get("town_id", "")))
        if town == null:
            _tear_contract(i, tr("Contract terminated: the town is gone."))
            continue
        var product_id := str(contract.get("product_id", ""))
        var amount := int(contract.get("amount", 0))
        var cost := int(contract.get("cost_per_tick", 0))
        if amount < MIN_AMOUNT or cost < 0:
            _tear_contract(i, tr("Contract terminated: a broken record."))
            continue
        # The payment is checked BEFORE the supply is credited: a deal the treasury cannot
        # pay never makes the town strain, so the goods it would have made stay out of its
        # warehouse. The strain of a town is for the contracts it actually serves.
        if CityData.treasury < cost:
            _tear_contract(i, tr("Contract terminated: the treasury cannot pay %d per second for %s from %s.") % [
                    cost, str(contract.get("product_name", "")), str(contract.get("town_name", ""))])
            continue
        _credit_town_supply(town, product_id, demand, credited)
        if _town_manager.get_town_goods(town, product_id) < amount:
            _tear_contract(i, tr("Contract terminated: %s ran out of %s.") % [
                    str(contract.get("town_name", "")), str(contract.get("product_name", ""))])
            continue
        if _pay_and_deliver(town, product_id, amount, cost):
            # The goods of this tick are on the road, and they are the goods of the CONTRACT:
            # the ledger remembers them, so that a shipment can be charged to the contract
            # before it reaches a one-time purchase (see _contract_outstanding). A delivery
            # the road did not limit is not remembered — it is not on the road at all.
            var key := _supply_key(str(contract.get("town_id", "")), product_id)
            if not key.is_empty():
                _contract_outstanding[key] = int(_contract_outstanding.get(key, 0)) + amount
        i += 1
    # The contracts still standing after the sweep are the plan of this tick. The teardown
    # happens before the record, so a contract that could not be paid or fulfilled never
    # promises goods the city will not receive.
    _record_planned_production()


# The summed demand of every standing contract, keyed by the town and the good
# ("town_id|product_id" -> units per tick). The supply of a town is credited once per key
# per tick (see _credit_town_supply), so the demand is summed rather than read per contract.
func _aggregate_demand() -> Dictionary:
    var demand: Dictionary = {}
    for contract in _contracts:
        var key := _supply_key(str(contract.get("town_id", "")), str(contract.get("product_id", "")))
        if key.is_empty():
            continue
        demand[key] = int(demand.get(key, 0)) + int(contract.get("amount", 0))
    return demand


# Credits the warehouse of a town with the part of one tick of a contract that the town
# covers from its own output (TownEconomy.get_contract_supply). It is done ONCE per town
# and good per tick — the `credited` set of the caller — so the rate of a town is served
# once and not once per contract.
#
# A contract within the comfort rate of the town leaves the warehouse untouched: the town
# keeps up, and the stock stays where it was. Above it the warehouse loses the drain every
# tick — the more, the bigger the order — and the contract tears once it runs dry.
func _credit_town_supply(town: Dictionary, product_id: String, demand: Dictionary,
        credited: Dictionary) -> void:
    var key := _supply_key(str(town.get("id", "")), product_id)
    if key.is_empty() or credited.has(key):
        return
    credited[key] = true
    var total := float(demand.get(key, 0))
    var supply := TownEconomy.get_contract_supply(total)
    # The town covers `supply` of the `total` it owes and the warehouse loses the rest. The
    # draw is a whole number of units, so the fraction of the drain is carried over to the
    # next tick rather than rounded away (see _drain_remainder).
    var owed := float(_drain_remainder.get(key, 0.0)) + (total - supply)
    var whole := int(floor(owed))
    _drain_remainder[key] = owed - float(whole)
    var credit := int(round(total)) - whole
    if credit > 0:
        _town_manager.add_town_goods(town, product_id, credit)


func _supply_key(town_id: String, product_id: String) -> String:
    if town_id.is_empty() or product_id.is_empty():
        return ""
    return "%s|%s" % [town_id, product_id]


# The planned delivery of every live contract (see CityData.town_planned_production). One
# record per contract, so the tooltip of the row counts the deals behind the amount.
func _record_planned_production() -> void:
    for contract in _contracts:
        CityData.record_planned_town_production(
                str(contract.get("product_id", "")),
                GameData.SRC_TOWN_TRADE,
                int(contract.get("amount", 0)))


# The contracts as the rows of the "Trade deals" section: everything the row shows
# (see external_trade_tab._build_deal_row), with the delivery time read from the
# live route. The copies are handed out: the section must not be able to edit the
# records of the manager.
func get_contracts() -> Array:
    var result: Array = []
    for contract in _contracts:
        var product_id := str(contract.get("product_id", ""))
        var deal: Dictionary = contract.duplicate()
        # The fields the row of the "Trade deals" section shows: the display name and
        # the icon are resolved from the common reference, the rest is the contract.
        deal["kind"] = KIND_CONTRACT
        deal["name"] = _product_name(product_id)
        deal["icon"] = str(GameData.get_resource_data(product_id).get("icon", ""))
        deal["type"] = "buy"
        deal["price"] = int(contract.get("unit_price", 0))
        deal["amount"] = int(contract.get("amount", 0))
        deal["cost"] = int(contract.get("cost_per_tick", 0))
        deal["delivery_time"] = _delivery_time(
                int(contract.get("row", -1)), int(contract.get("col", -1)))
        result.append(deal)
    return result


# The one-time purchases whose goods are still on the road, as the rows of the "Trade deals"
# section. The shape is the shape of a contract row (see external_trade_tab._build_deal_row)
# with the fields of a delivery:
#   kind        "delivery" — the pair (town, good) is not enough to tell a purchase from a
#               contract, they can stand at the same time;
#   ordered     the units bought in total (every purchase of the pair, summed);
#   amount, remaining
#               the units still on the way — what a cancellation can withdraw;
#   cost, spent the coins paid for them — what a cancellation returns to the treasury;
#   price       the price of the last purchase (the number the row shows).
#
# A delivery with nothing left on the way is not listed: it is settled, and a row that cannot
# be cancelled would only be noise. The row is assembled field by field rather than copied,
# so that the section never gets a handle on the lots of the ledger and cannot edit them.
func get_deliveries() -> Array:
    var result: Array = []
    for key in _deliveries.keys():
        var delivery: Dictionary = _deliveries[key]
        var remaining := int(delivery.get("remaining", 0))
        if remaining <= 0:
            continue
        var product_id := str(delivery.get("product_id", ""))
        result.append({
            "kind": KIND_DELIVERY,
            "town_id": str(delivery.get("town_id", "")),
            "town_name": str(delivery.get("town_name", "")),
            "row": int(delivery.get("row", -1)),
            "col": int(delivery.get("col", -1)),
            "product_id": product_id,
            "product_name": str(delivery.get("product_name", "")),
            "name": _product_name(product_id),
            "icon": str(GameData.get_resource_data(product_id).get("icon", "")),
            "type": "buy",
            "price": int(delivery.get("unit_price", 0)),
            "ordered": int(delivery.get("ordered", 0)),
            "amount": remaining,
            "remaining": remaining,
            "cost": int(delivery.get("spent", 0)),
            "spent": int(delivery.get("spent", 0)),
            "delivery_time": _delivery_time(
                    int(delivery.get("row", -1)), int(delivery.get("col", -1))),
        })
    return result


# The standing contract of a town for a good, or an empty dictionary when there is none.
# The pair (town, good) is the identity of a deal (see the header), so this is the lookup
# the interfaces use to tell "sign a contract" from "edit the current one". A copy is
# handed out: the caller must not be able to edit the record of the manager.
func get_contract(town_id: String, product_id: String) -> Dictionary:
    var index := _contract_index(town_id, product_id)
    if index < 0:
        return {}
    return (_contracts[index] as Dictionary).duplicate()


# --- The one-time purchase ---

func _buy_once(town: Dictionary, product_id: String, amount: int, unit_price: int) -> Dictionary:
    var total := amount * unit_price
    var town_name := str(town.get("name", tr("Town")))
    var product_name := _product_name(product_id)
    if _town_manager.get_town_goods(town, product_id) < amount:
        return {"ok": false, "message": tr("%s does not have that many units.") % town_name}
    if CityData.treasury < total:
        return {"ok": false, "message": tr("Not enough coins in the treasury! Need %d, treasury has %d")
                % [total, CityData.treasury]}
    var on_the_road := _pay_and_deliver(town, product_id, amount, total)
    if not on_the_road:
        # The road did not limit the deal at all: the goods are already in the storage, so
        # nothing is on the way and there is nothing to cancel.
        return {"ok": true,
                "message": tr("Purchased %d units of %s from %s.") % [amount, product_name, town_name]}
    _track_purchase(town, product_id, amount, unit_price)
    return {"ok": true,
            "message": tr("Purchased %d units of %s from %s. The goods are on the way; the deal can be cancelled in \"Trade deals\".") % [
                    amount, product_name, town_name]}


# Cancels a one-time purchase. Only the part that has NOT been shipped is withdrawn: the units
# still waiting in the queue of the route go back into the warehouse of the town, and the
# coins the player paid for exactly those units go back into the treasury. What is already on
# the road cannot be recalled, and is neither returned nor refunded — the answer says how much
# was actually withdrawn, so the interface can state the outcome before the player commits
# (external_trade_tab._build_delivery_confirmation) and report it afterwards.
#
# The refund is the coins actually paid for the withdrawn units, taken lot by lot from the
# oldest purchase (the order in which the queue of the route lets the loads go). The purchases
# of a pair can be made at different prices, so the sum is exact and never pays back more than
# the treasury was charged.
func cancel_delivery(town_id: String, product_id: String) -> Dictionary:
    var key := _supply_key(town_id, product_id)
    var delivery: Dictionary = _deliveries.get(key, {}) if not key.is_empty() else {}
    if delivery.is_empty() or int(delivery.get("remaining", 0)) <= 0:
        if not key.is_empty():
            _deliveries.erase(key)
        return {"ok": false, "message": tr("There is nothing on the way for this deal.")}
    var remaining := int(delivery.get("remaining", 0))
    var row := int(delivery.get("row", -1))
    var col := int(delivery.get("col", -1))
    var withdrawn := remaining
    if _delivery_manager != null and row >= 0 and col >= 0:
        withdrawn = _delivery_manager.remove_pending(row, col, product_id, remaining)
    if withdrawn <= 0:
        # The queue no longer holds the goods (the road shipped them while the ledger was
        # being read): there is nothing to withdraw, and the ledger is dropped as stale.
        _deliveries.erase(key)
        return {"ok": false, "message": tr("There is nothing on the way for this deal.")}
    var refund := _take_from_lots(delivery, withdrawn)
    if int(delivery.get("remaining", 0)) <= 0:
        _deliveries.erase(key)
    var town = _town_by_id(town_id)
    if town != null:
        _town_manager.add_town_goods(town, product_id, withdrawn)
    CityData.add_treasury(refund)
    # The refund is recorded as a NEGATIVE expense of the same source the purchase spent from,
    # so the breakdown of the treasury nets the cancelled deal out inside the same source
    # instead of showing the expense of goods the city never received.
    CityData.record_treasury_expense(GameData.SRC_TOWN_TRADE, -refund)
    return {"ok": true,
            "message": tr("Cancelled %d units of %s from %s: the goods are back in the warehouse of the town and %d coins are back in the treasury.") % [
                    withdrawn, str(delivery.get("product_name", "")),
                    str(delivery.get("town_name", "")), refund]}


# --- The ledger of the one-time purchases ---

# Remembers a purchase that has gone onto the road. A second purchase of the same good from
# the same town is not a second deal: it ADDS to the first (the pair is the identity of a
# deal, see the header), so the "Trade deals" section keeps one row and its totals are the
# totals of both purchases.
func _track_purchase(town: Dictionary, product_id: String, amount: int, unit_price: int) -> void:
    var key := _supply_key(str(town.get("id", "")), product_id)
    if key.is_empty():
        return
    var delivery: Dictionary = _deliveries.get(key, {})
    if delivery.is_empty():
        delivery = {
            "town_id": str(town.get("id", "")),
            "town_name": str(town.get("name", tr("Town"))),
            "row": int(town.get("row", -1)),
            "col": int(town.get("col", -1)),
            "product_id": product_id,
            "product_name": _product_name(product_id),
            "ordered": 0,
            "remaining": 0,
            "spent": 0,
            "unit_price": unit_price,
            "lots": [],
        }
        _deliveries[key] = delivery
    delivery["ordered"] = int(delivery["ordered"]) + amount
    delivery["unit_price"] = unit_price
    (delivery["lots"] as Array).append({"amount": amount, "unit_price": unit_price})
    _recompute_delivery(delivery)


# Reads the totals of a delivery out of its lots. The lots are the truth: `remaining` and
# `spent` are only their sums, kept ready for the interface. Deriving them instead of counting
# them down on every shipment is what keeps a refund exact when the purchases of a pair were
# made at different prices.
func _recompute_delivery(delivery: Dictionary) -> void:
    var remaining := 0
    var spent := 0
    for lot in delivery["lots"]:
        var lot_amount := int(lot.get("amount", 0))
        remaining += lot_amount
        spent += lot_amount * int(lot.get("unit_price", 0))
    delivery["remaining"] = remaining
    delivery["spent"] = spent


# A load left the queue of a route (delivery_manager.cargo_shipped). The ledger walks the
# shipment down: first the standing contract of the pair, then the one-time purchases, oldest
# first.
#
# The contract goes first because its goods are CREATED every tick and the town serves them:
# what carries the supply of the contract is the throughput of the road, and only the excess
# of the throughput can drain a purchase. So a purchase behind a contract that saturates the
# road stays whole — which is exactly the amount its cancellation must be able to return.
func _on_cargo_shipped(row: int, col: int, product: String, amount: int, source: String) -> void:
    if amount <= 0:
        return
    var town_id := _town_id_of_source(source)
    if town_id.is_empty():
        return
    var key := _supply_key(town_id, product)
    if key.is_empty():
        return
    var left := amount
    var contract_left := int(_contract_outstanding.get(key, 0))
    if contract_left > 0:
        var from_contract: int = mini(left, contract_left)
        contract_left -= from_contract
        left -= from_contract
        if contract_left > 0:
            _contract_outstanding[key] = contract_left
        else:
            _contract_outstanding.erase(key)
    if left > 0:
        _consume_delivery_lots(key, left)


# Charges a shipment to the purchases of a pair, oldest lot first — the order in which the
# queue of the route lets the loads go. A delivery with nothing left on the way is dropped: it
# is settled, and a settled deal must leave no row behind.
func _consume_delivery_lots(key: String, amount: int) -> void:
    var delivery: Dictionary = _deliveries.get(key, {})
    if delivery.is_empty():
        return
    _take_from_lots(delivery, amount)
    if (delivery["lots"] as Array).is_empty():
        _deliveries.erase(key)


# Takes `amount` units out of the lots of a delivery, oldest first, and returns what those
# units cost — the coins a refund of them owes. The units of a pair are fungible, so which lot
# they are charged to is decided by the order alone; the price is read from the lot that gives
# them up, so a delivery bought at two different prices refunds each part at its own price.
func _take_from_lots(delivery: Dictionary, amount: int) -> int:
    var lots: Array = delivery["lots"]
    var left := amount
    var value := 0
    var i := 0
    while i < lots.size() and left > 0:
        var lot: Dictionary = lots[i]
        var take: int = mini(int(lot.get("amount", 0)), left)
        lot["amount"] = int(lot.get("amount", 0)) - take
        left -= take
        value += take * int(lot.get("unit_price", 0))
        if int(lot["amount"]) <= 0:
            lots.remove_at(i)
        else:
            i += 1
    _recompute_delivery(delivery)
    return value


# The id of the town behind a load, or an empty string when the load is not a town's. The
# source of a town purchase is CARGO_SOURCE_PREFIX + the id of the town; an improvement has a
# source of its own, so it is filtered out here rather than by the hex — a hex is never both a
# town and an improvement, but the source is the fact, not the inference.
func _town_id_of_source(source: String) -> String:
    if not source.begins_with(CARGO_SOURCE_PREFIX):
        return ""
    return source.trim_prefix(CARGO_SOURCE_PREFIX)


# --- The standing contract ---

func _sign_contract(town: Dictionary, product_id: String, amount: int, unit_price: int) -> Dictionary:
    var cost := amount * unit_price
    var town_name := str(town.get("name", tr("Town")))
    var product_name := _product_name(product_id)
    if _town_manager.get_town_goods(town, product_id) < amount:
        return {"ok": false,
                "message": tr("%s does not have %d units for a standing contract.") % [town_name, amount]}
    if CityData.treasury < cost:
        # The contract charges from the very first tick, so it cannot be signed
        # without the coins for that tick.
        return {"ok": false, "message": tr("Not enough coins for the contract: %d per second.") % cost}
    _contracts.append({
        "id": "contract_%d" % _next_contract_id,
        "town_id": str(town.get("id", "")),
        "town_name": town_name,
        "row": int(town.get("row", -1)),
        "col": int(town.get("col", -1)),
        "product_id": product_id,
        "product_name": product_name,
        "quality": TownManager.get_town_goods_quality(town, product_id),
        "amount": amount,
        "unit_price": unit_price,
        "cost_per_tick": cost,
    })
    _next_contract_id += 1
    emit_signal("contracts_changed")
    return {"ok": true,
            "message": tr("Contract signed: %d units of %s per second from %s.") % [amount, product_name, town_name]}


# Edits the standing contract at `index`: the amount is the only term that moves, the
# unit price stays frozen at the price of the signed deal. A different price is a
# different deal, and the way to it is "close the contract and sign a new one" (see the
# header) — so an edit never silently changes what a unit costs. The amount is checked
# against the stock of the town and against the treasury exactly as a fresh signing is:
# the contract charges from the very next tick.
func _update_contract(index: int, amount: int) -> Dictionary:
    var contract: Dictionary = _contracts[index]
    var town = _town_by_id(str(contract.get("town_id", "")))
    if town == null:
        _tear_contract(index, tr("Contract terminated: the town is gone."))
        return {"ok": false, "message": tr("The town is not on the map anymore")}
    var product_id := str(contract.get("product_id", ""))
    var unit_price := int(contract.get("unit_price", 0))
    var cost := amount * unit_price
    var town_name := str(contract.get("town_name", tr("Town")))
    var product_name := str(contract.get("product_name", ""))
    if _town_manager.get_town_goods(town, product_id) < amount:
        return {"ok": false,
                "message": tr("%s does not have %d units for a standing contract.") % [town_name, amount]}
    if CityData.treasury < cost:
        return {"ok": false, "message": tr("Not enough coins for the contract: %d per second.") % cost}
    contract["amount"] = amount
    contract["cost_per_tick"] = cost
    emit_signal("contracts_changed")
    return {"ok": true,
            "message": tr("Contract updated: %d units of %s per second from %s.") % [amount, product_name, town_name]}


# Closes one standing contract by its id: it stops being paid and served from the next
# tick. This is the deliberate counterpart of an automatic tear — the player asks for it,
# so no notice is raised (the caller reports the message in the HUD). The good of the
# closed contract becomes free for a new deal, with the same terms or with different ones.
func close_contract(contract_id: String) -> Dictionary:
    var index := _contract_index_by_id(contract_id)
    if index < 0:
        return {"ok": false, "message": tr("The contract is already closed.")}
    var contract: Dictionary = _contracts[index]
    _contracts.remove_at(index)
    emit_signal("contracts_changed")
    return {"ok": true,
            "message": tr("Contract closed: %s from %s.") % [
                    str(contract.get("product_name", "")), str(contract.get("town_name", ""))]}


# Tears one contract (the index into _contracts) and tells the player why. The
# deal is not settled: the town could not sell or the city could not pay, and
# neither side is charged for the failed tick.
func _tear_contract(index: int, message: String) -> void:
    _contracts.remove_at(index)
    emit_signal("contracts_changed")
    emit_signal("notice", message, 1)


# The settlement of one delivery: the city pays, the town is paid, the units are
# written off the warehouse of the town and queued on the road to the city.
#
# It returns whether the goods actually went ONTO THE ROAD: false means the road did not
# limit the deal at all and they are already in the storage. The caller needs the answer to
# know whether there is anything on the way — and therefore anything to track and to cancel.
func _pay_and_deliver(town: Dictionary, product_id: String, amount: int, cost: int) -> bool:
    CityData.spend_treasury(cost)
    _town_manager.add_town_treasury(town, cost)
    CityData.record_treasury_expense(GameData.SRC_TOWN_TRADE, cost)
    _town_manager.take_town_goods(town, product_id, amount)
    return _deliver_from_town(town, product_id, amount)


# Queues the goods on the route from the town. When there is no route the road
# cannot limit anything, so the goods are credited to the storage at once — the
# same rule the production of an improvement on a hex without a road follows.
# It returns whether the goods were queued (true) or delivered at once (false).
func _deliver_from_town(town: Dictionary, product_id: String, amount: int) -> bool:
    var quality := TownManager.get_town_goods_quality(town, product_id)
    var row := int(town.get("row", -1))
    var col := int(town.get("col", -1))
    var source := CARGO_SOURCE_PREFIX + str(town.get("id", ""))
    if _delivery_manager != null and row >= 0 and col >= 0 \
            and _delivery_manager.create_cargo(row, col, product_id, quality, amount, source):
        return true
    CityData.add_to_storage(product_id, amount, quality)
    CityData.record_production_source(product_id, source, amount)
    return false


# --- The helpers ---

# The record of the town behind an order: by the id first, by the hexes as the
# fallback (a stale window over a town that has not moved).
func _find_town(order: Dictionary):
    if _town_manager == null:
        return null
    var town_id := str(order.get("town_id", ""))
    for town in _town_manager.towns:
        if str(town.get("id", "")) == town_id:
            return town
    return _town_manager.find_town_at(int(order.get("row", -1)), int(order.get("col", -1)))


func _town_by_id(town_id: String):
    if _town_manager == null or town_id.is_empty():
        return null
    for town in _town_manager.towns:
        if str(town.get("id", "")) == town_id:
            return town
    return null


# The index of the standing contract of a town for a good into _contracts, or -1 when
# there is none. The pair (town, good) is the identity of a deal: this is what makes a
# second order for the same pair an edit of the existing contract (see submit_order).
func _contract_index(town_id: String, product_id: String) -> int:
    if town_id.is_empty() or product_id.is_empty():
        return -1
    for i in range(_contracts.size()):
        var contract: Dictionary = _contracts[i]
        if str(contract.get("town_id", "")) == town_id \
                and str(contract.get("product_id", "")) == product_id:
            return i
    return -1


# The index of a contract by its id, or -1 when no contract carries it.
func _contract_index_by_id(contract_id: String) -> int:
    if contract_id.is_empty():
        return -1
    for i in range(_contracts.size()):
        if str((_contracts[i] as Dictionary).get("id", "")) == contract_id:
            return i
    return -1


# The price of one unit the way the sale row of the window showed it: the current
# market price with the quality multiplier of the level the town holds (an unknown
# level has the multiplier 1.0, which is the plain market price).
func _unit_price_of(town: Dictionary, product_id: String) -> int:
    var quality: Dictionary = town.get("quality", {})
    var quality_id := str(quality.get(product_id, ""))
    if quality_id.is_empty() or quality_id == "<null>":
        quality_id = ""
    return int(round(GameData.get_price_for_quality(product_id, quality_id)))


func _product_name(product_id: String) -> String:
    var name := str(GameData.get_resource_data(product_id).get("name", ""))
    if not name.is_empty():
        return name
    var raw: Dictionary = GameData.raw_resources.get(product_id, {})
    if not raw.is_empty():
        return str(raw.get("name", product_id))
    var product: Dictionary = GameData.products.get(product_id, {})
    return str(product.get("name", product_id))


# The transit delay of the route from the town: how long the goods of one tick
# spend on the road. 0 when there is no route — then the goods arrive at once.
func _delivery_time(row: int, col: int) -> float:
    if _delivery_manager == null or row < 0 or col < 0:
        return 0.0
    var status: Dictionary = _delivery_manager.get_route_status(row, col)
    return float(status.get("transit_delay", 0.0))


# --- The save ---

# The contracts for the save. The route is NOT written: the flow and the delay
# belong to the road and are recomputed from the restored network, so a save never
# freezes a stale throughput — the same rule as for the cargo of the delivery.
func serialize() -> Array:
    var out: Array = []
    for contract in _contracts:
        out.append({
            "id": str(contract.get("id", "")),
            "town_id": str(contract.get("town_id", "")),
            "town_name": str(contract.get("town_name", "")),
            "row": int(contract.get("row", -1)),
            "col": int(contract.get("col", -1)),
            "product_id": str(contract.get("product_id", "")),
            "product_name": str(contract.get("product_name", "")),
            "quality": str(contract.get("quality", "")),
            "amount": int(contract.get("amount", 0)),
            "unit_price": int(contract.get("unit_price", 0)),
            "cost_per_tick": int(contract.get("cost_per_tick", 0)),
        })
    return out


# Restores the contracts from a save. The values come back from JSON, therefore
# the integers arrive as floats and every field is coerced back to its type here;
# a record without a town, a good or a positive amount is dropped instead of being
# carried as a deal that could never be paid.
func deserialize(data) -> void:
    clear()
    if not (data is Array):
        return
    for entry in data:
        if not (entry is Dictionary):
            continue
        var amount := int(entry.get("amount", 0))
        var product_id := str(entry.get("product_id", ""))
        if amount < MIN_AMOUNT or product_id.is_empty():
            continue
        var unit_price := int(entry.get("unit_price", 0))
        var cost := int(entry.get("cost_per_tick", 0))
        if cost <= 0 and unit_price > 0:
            # A save without the total: the contract charges what its terms say.
            cost = amount * unit_price
        var town = _town_by_id(str(entry.get("town_id", "")))
        var town_name := str(entry.get("town_name", ""))
        var row := int(entry.get("row", -1))
        var col := int(entry.get("col", -1))
        if town != null:
            # The record of the town is the authority on its name and its hexes.
            town_name = str(town.get("name", town_name))
            row = int(town.get("row", row))
            col = int(town.get("col", col))
        _contracts.append({
            "id": str(entry.get("id", "")),
            "town_id": str(entry.get("town_id", "")),
            "town_name": town_name,
            "row": row,
            "col": col,
            "product_id": product_id,
            "product_name": str(entry.get("product_name", product_id)),
            "quality": str(entry.get("quality", "")),
            "amount": amount,
            "unit_price": unit_price,
            "cost_per_tick": cost,
        })
        # The counter continues after the largest restored id, so a new contract
        # never reuses the id of a restored one.
        var restored_id := str(entry.get("id", ""))
        if restored_id.begins_with("contract_"):
            var serial := restored_id.trim_prefix("contract_")
            if serial.is_valid_int():
                _next_contract_id = maxi(_next_contract_id, int(serial) + 1)


# The ledger of the one-time purchases for the save. The lots are written whole: they are what
# a refund is computed from, so a save that dropped them would silently change what a
# cancellation returns. `remaining` and `spent` are not written — they are the sums of the
# lots, and a save must not be able to disagree with its own source of truth.
func serialize_deliveries() -> Dictionary:
    var deliveries: Array = []
    for key in _deliveries.keys():
        var delivery: Dictionary = _deliveries[key]
        var lots: Array = []
        for lot in delivery["lots"]:
            lots.append({
                "amount": int(lot.get("amount", 0)),
                "unit_price": int(lot.get("unit_price", 0)),
            })
        deliveries.append({
            "town_id": str(delivery.get("town_id", "")),
            "town_name": str(delivery.get("town_name", "")),
            "row": int(delivery.get("row", -1)),
            "col": int(delivery.get("col", -1)),
            "product_id": str(delivery.get("product_id", "")),
            "product_name": str(delivery.get("product_name", "")),
            "ordered": int(delivery.get("ordered", 0)),
            "unit_price": int(delivery.get("unit_price", 0)),
            "lots": lots,
        })
    var outstanding: Dictionary = {}
    for key in _contract_outstanding.keys():
        outstanding[str(key)] = int(_contract_outstanding[key])
    return {"deliveries": deliveries, "contract_outstanding": outstanding}


# Restores the ledger of the one-time purchases. It must run AFTER deserialize (the contracts):
# that one resets the whole state of the manager, the ledger included, so restoring the ledger
# first would only have it wiped.
#
# The values come back from JSON, therefore the integers arrive as floats and every field is
# coerced back to its type here. A record without a town or a good, and a lot that is empty,
# are dropped instead of being carried as a deal that could not be cancelled; `remaining` and
# `spent` are recomputed from the lots.
func deserialize_deliveries(data) -> void:
    _deliveries.clear()
    _contract_outstanding.clear()
    if not (data is Dictionary):
        return
    var saved_deliveries = data.get("deliveries", [])
    if saved_deliveries is Array:
        for entry in saved_deliveries:
            if not (entry is Dictionary):
                continue
            var town_id := str(entry.get("town_id", ""))
            var product_id := str(entry.get("product_id", ""))
            var key := _supply_key(town_id, product_id)
            if key.is_empty():
                continue
            var lots: Array = []
            var saved_lots = entry.get("lots", [])
            if saved_lots is Array:
                for lot_entry in saved_lots:
                    if not (lot_entry is Dictionary):
                        continue
                    var lot_amount := int(lot_entry.get("amount", 0))
                    if lot_amount <= 0:
                        continue
                    lots.append({
                        "amount": lot_amount,
                        "unit_price": maxi(0, int(lot_entry.get("unit_price", 0))),
                    })
            if lots.is_empty():
                continue
            var delivery: Dictionary = {
                "town_id": town_id,
                "town_name": str(entry.get("town_name", "")),
                "row": int(entry.get("row", -1)),
                "col": int(entry.get("col", -1)),
                "product_id": product_id,
                "product_name": str(entry.get("product_name", product_id)),
                "ordered": maxi(0, int(entry.get("ordered", 0))),
                "remaining": 0,
                "spent": 0,
                "unit_price": maxi(0, int(entry.get("unit_price", 0))),
                "lots": lots,
            }
            _recompute_delivery(delivery)
            if int(delivery["remaining"]) <= 0:
                continue
            _deliveries[key] = delivery
    var outstanding = data.get("contract_outstanding", {})
    if outstanding is Dictionary:
        for key in outstanding:
            var amount := int(outstanding[key])
            if amount > 0:
                _contract_outstanding[str(key)] = amount
