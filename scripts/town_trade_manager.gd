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
#
# THE DELIVERY. The town window can only open a purchase when the road to the town
# exists (town_manager.is_trade_available), and the goods move along that road with
# the standard limits: they queue on the route, are shipped at its flow rate and
# reach the city storage after the transit delay. When there is no route at all
# (a road that does not exist cannot limit anything), the goods are credited to the
# storage at once — the same fallback the production of the improvements uses.
#
# THE LIST OF THE DEALS. The standing contracts are what the "Trade deals" section
# of the "Trade" tab shows (external_trade_tab._collect_deals reads them through
# main_map.get_town_contracts). A one-time purchase leaves nothing to list: it is
# settled at once.
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

var _town_manager = null
var _delivery_manager = null

# The standing contracts, in the order they were signed. One record:
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

# The trade mechanics changed the list of the contracts (signed or torn). The
# interface reads the list on its own rhythm (external_trade_tab.update_values);
# the signal exists for the callers that want to react at once.
signal contracts_changed()

# A message for the player: a contract that could not be paid or fulfilled. The
# map shows it in the HUD (see main_map._on_town_trade_notice).
signal notice(message: String)


# The references are passed explicitly, like to the other managers: the towns give
# the warehouse and the treasury, the logistics owns the route from a town to the
# city. A test can drive the manager on a bare scene with a map stub.
func initialize(town_manager, delivery_manager) -> void:
    _town_manager = town_manager
    _delivery_manager = delivery_manager
    _contracts.clear()
    _next_contract_id = 1


# Drops every contract. A new game starts from a clean sheet, otherwise the deals
# of the previous party would be paid by the next one.
func clear() -> void:
    _contracts.clear()
    _next_contract_id = 1


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
        if _town_manager.get_town_goods(town, product_id) < amount:
            _tear_contract(i, tr("Contract terminated: %s ran out of %s.") % [
                    str(contract.get("town_name", "")), str(contract.get("product_name", ""))])
            continue
        if CityData.treasury < cost:
            _tear_contract(i, tr("Contract terminated: the treasury cannot pay %d per second for %s from %s.") % [
                    cost, str(contract.get("product_name", "")), str(contract.get("town_name", ""))])
            continue
        _pay_and_deliver(town, product_id, amount, cost)
        i += 1
    # The contracts still standing after the sweep are the plan of this tick. The teardown
    # happens before the record, so a contract that could not be paid or fulfilled never
    # promises goods the city will not receive.
    _record_planned_production()


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
    _pay_and_deliver(town, product_id, amount, total)
    return {"ok": true,
            "message": tr("Purchased %d units of %s from %s.") % [amount, product_name, town_name]}


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


# Tears one contract (the index into _contracts) and tells the player why. The
# deal is not settled: the town could not sell or the city could not pay, and
# neither side is charged for the failed tick.
func _tear_contract(index: int, message: String) -> void:
    _contracts.remove_at(index)
    emit_signal("contracts_changed")
    emit_signal("notice", message)


# The settlement of one delivery: the city pays, the town is paid, the units are
# written off the warehouse of the town and queued on the road to the city.
func _pay_and_deliver(town: Dictionary, product_id: String, amount: int, cost: int) -> void:
    CityData.spend_treasury(cost)
    _town_manager.add_town_treasury(town, cost)
    CityData.record_treasury_expense(GameData.SRC_TOWN_TRADE, cost)
    _town_manager.take_town_goods(town, product_id, amount)
    _deliver_from_town(town, product_id, amount)


# Queues the goods on the route from the town. When there is no route the road
# cannot limit anything, so the goods are credited to the storage at once — the
# same rule the production of an improvement on a hex without a road follows.
func _deliver_from_town(town: Dictionary, product_id: String, amount: int) -> void:
    var quality := TownManager.get_town_goods_quality(town, product_id)
    var row := int(town.get("row", -1))
    var col := int(town.get("col", -1))
    var source := CARGO_SOURCE_PREFIX + str(town.get("id", ""))
    if _delivery_manager != null and row >= 0 and col >= 0 \
            and _delivery_manager.create_cargo(row, col, product_id, quality, amount, source):
        return
    CityData.add_to_storage(product_id, amount, quality)
    CityData.record_production_source(product_id, source, amount)


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
