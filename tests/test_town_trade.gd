# Headless test of the trade of the city with the towns (scripts/town_trade_manager.gd).
#   godot --headless --path . --script res://tests/test_town_trade.gd
#
# The mechanics behind the order of the town window — the one-time purchase and the
# standing contract. Checked:
#
#   buy_once          — the coins move from the treasury of the city into the treasury
#                       of the town, the units are written off the warehouse of the
#                       town, the goods travel by the road (the transit delay) and
#                       reach the city storage with the quality of the town;
#   refusals          — beyond the stock, without the coins, a wrong side or a zero
#                       amount change nothing at all;#   price_recompute   — an order that carries no price is charged the price of the row;
#   contract_ticks    — a standing contract charges and delivers every tick;
#   plan              — a live contract enters the PLAN of the tick (the green dynamics of
#                       the tab "Resources" reads the plan), a one-time purchase does not,
#                       and a torn contract leaves the plan;
#   contract_breaks   — a contract the treasury cannot pay, a town that ran out of the
#                       goods or a town that is gone is torn automatically, and the
#                       failed tick is not charged;
#   no_route          — without a road the goods are credited to the storage at once;
#   road_capacity     — the flow rate of the route throttles a large purchase;
#   save_load         — the contracts survive a save round-trip and keep charging;
#   deals             — the row shape the "Trade deals" section reads;
#   contract_edit     — one town carries ONE contract per good: a second order for the same
#                       pair edits the contract (the amount moves, the price stays frozen),
#                       a different good is a second contract, and closing frees the good;
#   strain            — what backs a contract is the SUPPLY of the town and not its stock:
#                       it serves an order up to its comfort rate for free, and above it
#                       strains — the warehouse drains the faster, the bigger the order —
#                       until the stock runs dry and the contract tears.
#   sell_once         — the city sells: the goods leave the city storage, the town pays
#                       from its treasury, and the bought goods join the virtual
#                       production of the town (its shelf stays pruned to the sell pool);
#   sell_group        — a group of the buy pool is sold as "any member": the units are
#                       taken from the members the city actually has, chosen at random
#                       (never from a good outside the group), and the group is paid at
#                       its own price — the average of its members;
#   sell_refusals     — a good the town does not buy, a city without the goods, a town
#                       without the coins and an opposite-direction order change nothing;
#   sell_contract     — a standing sale pays and drains every tick, and is torn when the
#                       city runs out of the goods or the town cannot pay;
#   sell_save_load    — a sale contract survives a save round-trip with its direction and
#                       keeps charging.
#
# The map is a stub (a route keyed by "row,col"), the towns are a TownManager with one
# synthetic record, the logistics is a REAL delivery_manager over the stub — the trade
# needs no scene.
extends SceneTree

# The hang watchdog: without it a broken _run() coroutine looks like eternal silence.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Real product id: the price and the icon are read from the common reference, so the
# expectations follow the data and not the constants of the test.
const WOOD := "wood"
# A second good of the same town: the "one contract per good" rule is per good, so a case
# needs two goods to tell "the same good" from "another good".
const PLANKS := "planks"
# A good with an additional ingredient ("gold jewelry with lazurite"): a decorated variant is
# its base for every rule that names the base, so a deal on the plain good must accept it.
const DECORATED_BASE := "gold_jewelry"

# A stub of the map: the logistics read the route from it.
class FakeMap:
	var routes: Dictionary = {}
	func set_route(row: int, col: int, length: int, avg_speed: float) -> void:
		routes["%d,%d" % [row, col]] = {"ok": true, "length": length, "avg_speed": avg_speed}
	func get_route_to_city(row: int, col: int) -> Dictionary:
		return routes.get("%d,%d" % [row, col], {"ok": false})

var _cdata = null
var _gdata = null
var _te = null
var _tm = null
var _dm = null
var _trade = null

func _initialize() -> void:
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state := {"failed": false}
	get_root().get_node("SaveManager").new_game()
	_cdata = get_root().get_node("CityData")
	_gdata = get_root().get_node("GameData")
	# The supply helpers live on the town economy. It is loaded by PATH and not by its
	# global class name: in --script mode the global class would make this file compile
	# before the autoloads exist, and TownEconomy reads GameData.
	_te = load("res://scripts/town_economy.gd")

	if WATCHDOG.wants_case("buy_once"):
		_test_buy_once(state)
	if WATCHDOG.wants_case("refusals"):
		_test_refusals(state)
	if WATCHDOG.wants_case("price_recompute"):
		_test_price_recompute(state)
	if WATCHDOG.wants_case("contract_ticks"):
		_test_contract_ticks(state)
	if WATCHDOG.wants_case("plan"):
		_test_plan(state)
	if WATCHDOG.wants_case("contract_breaks"):
		_test_contract_breaks(state)
	if WATCHDOG.wants_case("no_route"):
		_test_no_route(state)
	if WATCHDOG.wants_case("road_capacity"):
		_test_road_capacity(state)
	if WATCHDOG.wants_case("save_load"):
		_test_save_load(state)
	if WATCHDOG.wants_case("deals"):
		_test_deals(state)
	if WATCHDOG.wants_case("contract_edit"):
		_test_contract_edit(state)
	if WATCHDOG.wants_case("strain"):
		_test_strain(state)
	if WATCHDOG.wants_case("delivery_ledger"):
		_test_delivery_ledger(state)
	if WATCHDOG.wants_case("delivery_cancel"):
		_test_delivery_cancel(state)
	if WATCHDOG.wants_case("delivery_save_load"):
		_test_delivery_save_load(state)
	if WATCHDOG.wants_case("sell_once"):
		_test_sell_once(state)
	if WATCHDOG.wants_case("sell_group"):
		_test_sell_group(state)
	if WATCHDOG.wants_case("sell_refusals"):
		_test_sell_refusals(state)
	if WATCHDOG.wants_case("sell_contract"):
		_test_sell_contract(state)
	if WATCHDOG.wants_case("sell_save_load"):
		_test_sell_save_load(state)
	if WATCHDOG.wants_case("sell_decorated"):
		_test_sell_decorated(state)

	_free_rig()
	WATCHDOG.report_skipped()
	if state["failed"]:
		print("TOWN TRADE TEST FAILED")
		quit(1)
	else:
		print("TOWN TRADE TEST OK")
		quit(0)

# -------------------------------------------------------
# 1. A one-time purchase
# -------------------------------------------------------

func _test_buy_once(state: Dictionary) -> void:
	var town := _rig(10.0, 10)
	var price := _unit_price()
	var amount := 10
	var total := amount * price
	var result = _trade.submit_order(_order(amount, false, price))
	check(bool(result.get("ok", false)),
			"a purchase with enough coins and stock must succeed: %s"
					% str(result.get("message", "")), state)
	check(not str(result.get("message", "")).is_empty(),
			"the answer of the trade must explain itself to the player", state)
	check(_cdata.treasury == 1000 - total,
			"the city must pay %d coins (treasury %d)" % [total, _cdata.treasury], state)
	check(_tm.get_town_treasury(town) == 500 + total,
			"the town must be paid %d coins (treasury %d)"
					% [total, _tm.get_town_treasury(town)], state)
	check(_tm.get_town_goods(town, WOOD) == 90,
			"the stock of the town must fall by %d (got %d)"
					% [amount, _tm.get_town_goods(town, WOOD)], state)
	check(_delivered(WOOD) == 0,
			"the goods must travel by the road, not appear in the storage at once", state)
	check(int(_cdata.treasury_expense_accum.get(_gdata.SRC_TOWN_TRADE, 0)) == total,
			"the payment must be visible in the breakdown of the treasury", state)

	# The delivery: nothing before the transit delay of the route, everything after it.
	var delay := 10.0 * float(_dm.get_transit_time_per_hex())
	_dm.ship()
	_advance(_dm, delay - 1.0)
	check(_delivered(WOOD) == 0,
			"the goods must not arrive before the transit delay (got %d)"
					% _delivered(WOOD), state)
	_advance(_dm, 2.0)
	check(_delivered(WOOD) == amount,
			"after the transit delay the goods must arrive (got %d)"
					% _delivered(WOOD), state)
	check(int(_cdata.city_quality_detail.get(WOOD, {}).get("fine", 0)) == amount,
			"the delivered goods keep the quality of the town (%s)"
					% str(_cdata.city_quality_detail.get(WOOD, {})), state)

# -------------------------------------------------------
# 2. The refusals
# -------------------------------------------------------

func _test_refusals(state: Dictionary) -> void:
	var price := _unit_price()

	# More than the town has: nothing moves.
	var town := _rig(10.0, 10)
	var result = _trade.submit_order(_order(200, false, price))
	check(not bool(result.get("ok", false)),
			"a purchase beyond the stock of the town must not succeed", state)
	check(_cdata.treasury == 1000 and _tm.get_town_treasury(town) == 500
					and _tm.get_town_goods(town, WOOD) == 100 and _delivered(WOOD) == 0,
			"a refused purchase must change nothing", state)

	# Fewer coins than the purchase costs.
	var short := price * 10 - 1
	_cdata.treasury = short
	result = _trade.submit_order(_order(10, false, price))
	check(not bool(result.get("ok", false)),
			"a purchase the treasury cannot pay must not succeed", state)
	check(_cdata.treasury == short,
			"a refused purchase must not write the coins off (treasury %d)"
					% _cdata.treasury, state)
	check(_tm.get_town_goods(town, WOOD) == 100,
			"a refused purchase must not touch the warehouse of the town", state)

	# The city sells to a town: the town does not buy this good (its buy pool is empty).
	var selling := _order(10, false, price)
	selling["side"] = "buy"
	result = _trade.submit_order(selling)
	check(not bool(result.get("ok", false)),
			"a good the town does not buy must not be sold to it", state)
	check(not str(result.get("message", "")).is_empty(),
			"the refusal must explain itself", state)

	# A zero amount is not an order.
	result = _trade.submit_order(_order(0, false, price))
	check(not bool(result.get("ok", false)),
			"a zero amount must not be an order", state)

# -------------------------------------------------------
# 3. The price of an order that carries none
# -------------------------------------------------------

func _test_price_recompute(state: Dictionary) -> void:
	_rig(10.0, 10)
	var price := _unit_price()
	var result = _trade.submit_order(_order(10, false, 0))
	check(bool(result.get("ok", false)),
			"an order without the price must succeed (%s)" % str(result.get("message", "")), state)
	check(_cdata.treasury == 1000 - 10 * price,
			"an order without the price is charged the price of the row (%d, treasury %d)"
					% [10 * price, _cdata.treasury], state)

# -------------------------------------------------------
# 4. A standing contract: every tick
# -------------------------------------------------------

func _test_contract_ticks(state: Dictionary) -> void:
	var town := _rig(10.0, 10)
	var price := _unit_price()
	var amount := 5
	var cost := amount * price
	var result = _trade.submit_order(_order(amount, true, price))
	check(bool(result.get("ok", false)),
			"a contract with enough coins and stock must be signed: %s"
					% str(result.get("message", "")), state)
	check(_trade._contracts.size() == 1,
			"the contract must be recorded (%d)" % _trade._contracts.size(), state)
	check(_cdata.treasury == 1000,
			"signing a contract must not charge anything yet (treasury %d)"
					% _cdata.treasury, state)

	# The first tick: the payment, the write-off, the queue.
	_trade.tick_contracts()
	check(_cdata.treasury == 1000 - cost,
			"the tick of the contract must charge %d (treasury %d)"
					% [cost, _cdata.treasury], state)
	check(_tm.get_town_treasury(town) == 500 + cost,
			"the town must be paid every tick (treasury %d)"
					% _tm.get_town_treasury(town), state)
	check(_tm.get_town_goods(town, WOOD) == 100,
			"the town must keep up: a contract within the comfort rate leaves the warehouse alone (got %d)"
					% _tm.get_town_goods(town, WOOD), state)

	# The goods of the tick travel by the road and arrive.
	var delay := 10.0 * float(_dm.get_transit_time_per_hex())
	_dm.ship()
	_advance(_dm, delay + 1.0)
	check(_delivered(WOOD) == amount,
			"the goods of the tick must arrive after the transit delay (got %d)"
					% _delivered(WOOD), state)

	# The second tick repeats the deal exactly.
	_trade.tick_contracts()
	check(_cdata.treasury == 1000 - 2 * cost,
			"the second tick must charge again (treasury %d)" % _cdata.treasury, state)
	check(_tm.get_town_goods(town, WOOD) == 100,
			"the second tick must keep up as well (got %d)"
					% _tm.get_town_goods(town, WOOD), state)
	_dm.ship()
	_advance(_dm, delay + 1.0)
	check(_delivered(WOOD) == 2 * amount,
			"the goods of the second tick must arrive as well (got %d)"
					% _delivered(WOOD), state)

# -------------------------------------------------------
# 4b. The plan of the tick: the contracts feed the dynamics
# -------------------------------------------------------

func _test_plan(state: Dictionary) -> void:
	var _town := _rig(10.0, 10)
	var price := _unit_price()
	var amount := 5
	var source := str(_gdata.SRC_TOWN_TRADE)

	# A one-time purchase is not a per-second flow: it must not promise anything in the
	# plan (the goods of the deal are a single delivery, not a rate).
	check(bool(_trade.submit_order(_order(amount, false, price)).get("ok", false)),
			"the one-time purchase must go through", state)
	_cdata.reset_counters()
	check(_planned_amount(WOOD, source) == 0,
			"a one-time purchase must not appear in the plan of the tick (got %d)"
					% _planned_amount(WOOD, source), state)

	# A standing contract is a per-second inflow, exactly like a working improvement:
	# the plan of the tick must carry it, otherwise the row of the tab "Resources"
	# reads "[+0" while the goods keep arriving (the green label reads the plan only).
	check(bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)),
			"the contract must be signed", state)
	_cdata.reset_counters()
	_trade.tick_contracts()
	check(_planned_amount(WOOD, source) == amount,
			"the tick of the contract must enter the plan with %d per second (got %d)"
					% [amount, _planned_amount(WOOD, source)], state)
	var entry := _planned_entry(WOOD, source)
	check(is_equal_approx(float(entry.get("interval", -1.0)), 0.0),
			"a contract is a continuous per-second rate, so its interval must be 0 (got %s)"
					% str(entry.get("interval", -1.0)), state)
	check(int(entry.get("count", 0)) == 1,
			"the plan must count the contract behind the amount (got %d)"
					% int(entry.get("count", 0)), state)

	# The user-visible effect: the green dynamics of the row of the tab "Resources"
	# (resources_tab._format_prod_label) must read a positive rate and not "[+0".
	var tab = load("res://scripts/resources_tab.gd").new()
	tab.planned_production_map = _cdata.get_planned_production_map()
	var label_text: String = tab._format_prod_label(WOOD)
	check(label_text == "[+%d≈" % amount,
			"the row of the goods must show a positive dynamics \"[+%d≈\" (got \"%s\")"
					% [amount, label_text], state)
	check(tab._is_displayable(WOOD),
			"a product with a live contract must stay visible in the list", state)
	tab.free()

	# The plan is a RATE, not a running total: the arrival of the goods must not inflate it.
	var delay := 10.0 * float(_dm.get_transit_time_per_hex())
	_dm.ship()
	_advance(_dm, delay + 1.0)
	check(_delivered(WOOD) > 0,
			"the goods of the contract must arrive", state)
	check(_planned_amount(WOOD, source) == amount,
			"the arrival must not change the planned rate (got %d)"
					% _planned_amount(WOOD, source), state)

	# The plan lives exactly one tick: the reset of the next tick clears it.
	_cdata.reset_counters()
	check(_planned_amount(WOOD, source) == 0,
			"the reset of the tick must clear the plan (got %d)"
					% _planned_amount(WOOD, source), state)

	# A contract that is torn promises nothing: the teardown happens before the record.
	_cdata.reset_counters()
	_trade.tick_contracts()
	check(_planned_amount(WOOD, source) == amount,
			"the live contract must be back in the plan (got %d)"
					% _planned_amount(WOOD, source), state)
	# Make the contract unpayable: it must be torn on the next tick and leave the plan.
	_cdata.treasury = 0
	_cdata.reset_counters()
	_trade.tick_contracts()
	check(_trade._contracts.is_empty(),
			"a contract the treasury cannot pay must be lost", state)
	check(_planned_amount(WOOD, source) == 0,
			"a torn contract must not stay in the plan (got %d)"
					% _planned_amount(WOOD, source), state)

# -------------------------------------------------------
# 5. A contract that cannot be paid or fulfilled is torn
# -------------------------------------------------------

func _test_contract_breaks(state: Dictionary) -> void:
	var price := _unit_price()
	var amount := 5
	var cost := amount * price

	# The treasury cannot pay the tick.
	var town := _rig(10.0, 10)
	check(bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)),
			"the contract must be signed", state)
	_cdata.treasury = cost - 1
	var notices: Array = []
	_trade.notice.connect(func(message: String, _message_type: int = 0) -> void:
			notices.append(message))
	_trade.tick_contracts()
	check(_trade._contracts.is_empty(),
			"a contract the treasury cannot pay must be torn", state)
	check(_cdata.treasury == cost - 1,
			"a torn contract must not charge the failed tick (treasury %d)"
					% _cdata.treasury, state)
	check(_tm.get_town_goods(town, WOOD) == 100,
			"a torn contract must not take the goods", state)
	check(notices.size() == 1 and not str(notices[0]).is_empty(),
			"the player must be told why the contract was torn (%s)" % str(notices), state)

	# The town cannot keep up: an order above the ceiling of the town (the rate it can
	# restock a whole warehouse at) drains the stock fast, and the contract is torn once the
	# town can no longer cover one tick.
	_rig(10.0, 10)
	town = _tm.towns[0]
	_cdata.treasury = 1000000
	_tm.add_town_goods(town, WOOD, 1000)
	var over := int(_te.get_contract_ceiling()) + 100
	check(bool(_trade.submit_order(_order(over, true, price)).get("ok", false)),
			"the contract must be signed", state)
	var before: int = _cdata.treasury
	for i in range(40):
		if _trade._contracts.is_empty():
			break
		before = _cdata.treasury
		_trade.tick_contracts()
	check(_trade._contracts.is_empty(),
			"an order the town cannot keep up with must be torn", state)
	check(_cdata.treasury == before,
			"a torn contract must not charge the failed tick (treasury %d)"
					% _cdata.treasury, state)
	check(_tm.get_town_goods(town, WOOD) < over,
			"the failed order must have drained the warehouse below the amount (got %d)"
					% _tm.get_town_goods(town, WOOD), state)

	# The town is gone: a record the map no longer has.
	_rig(10.0, 10)
	check(bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)),
			"the contract must be signed", state)
	_tm.towns.clear()
	_trade.tick_contracts()
	check(_trade._contracts.is_empty(),
			"a contract without a town must be torn", state)

# -------------------------------------------------------
# 6. No road: the goods arrive at once
# -------------------------------------------------------

func _test_no_route(state: Dictionary) -> void:
	var town := _rig(0.0, 0)
	var price := _unit_price()
	var amount := 10
	var total := amount * price
	var result = _trade.submit_order(_order(amount, false, price))
	check(bool(result.get("ok", false)),
			"a purchase without a road must still succeed: %s"
					% str(result.get("message", "")), state)
	check(_delivered(WOOD) == amount,
			"without a road the goods are credited to the storage at once (got %d)"
					% _delivered(WOOD), state)
	check(_cdata.treasury == 1000 - total and _tm.get_town_treasury(town) == 500 + total,
			"the coins must move even without a road", state)
	check(_tm.get_town_goods(town, WOOD) == 90,
			"the warehouse of the town must be written off even without a road", state)

# -------------------------------------------------------
# 7. The road throttles a large purchase
# -------------------------------------------------------

func _test_road_capacity(state: Dictionary) -> void:
	_rig(4.0, 5)
	var amount := 20
	var result = _trade.submit_order(_order(amount, false, _unit_price()))
	check(bool(result.get("ok", false)),
			"the purchase must succeed (%s)" % str(result.get("message", "")), state)
	var status: Dictionary = _dm.get_route_status(5, 5)
	check(int(status.get("pending", 0)) == amount,
			"the whole purchase must wait in the queue of the route (got %d)"
					% int(status.get("pending", 0)), state)

	# One shipping step moves only the flow rate of the route.
	_dm.ship()
	status = _dm.get_route_status(5, 5)
	check(int(status.get("in_transit", 0)) == 4 and int(status.get("pending", 0)) == 16,
			"one step must ship the flow rate of the route (in transit %d, waiting %d)"
					% [int(status.get("in_transit", 0)), int(status.get("pending", 0))], state)
	var delay := 5.0 * float(_dm.get_transit_time_per_hex())
	_advance(_dm, delay + 0.5)
	check(_delivered(WOOD) == 4,
			"only the shipped units may arrive (got %d)" % _delivered(WOOD), state)

	# The rest arrives over the following steps: the road throttles, it does not lose.
	for i in range(10):
		_dm.ship()
		_advance(_dm, delay + 0.5)
	check(_delivered(WOOD) == amount,
			"the whole purchase must be delivered over the following steps (got %d)"
					% _delivered(WOOD), state)

# -------------------------------------------------------
# 8. The save round-trip
# -------------------------------------------------------

func _test_save_load(state: Dictionary) -> void:
	var town := _rig(10.0, 10)
	var price := _unit_price()
	var amount := 5
	check(bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)),
			"the contract must be signed", state)
	var saved: Array = _trade.serialize()
	check(saved.size() == 1,
			"the save must carry the contract (%d)" % saved.size(), state)

	# The round-trip: the same deal, with the same terms.
	var trade2 = load("res://scripts/town_trade_manager.gd").new()
	trade2.initialize(_tm, _dm)
	trade2.deserialize(saved)
	check(trade2._contracts.size() == 1,
			"the contract must be restored (%d)" % trade2._contracts.size(), state)
	var contract: Dictionary = trade2._contracts[0]
	check(str(contract.get("product_id", "")) == WOOD
					and int(contract.get("amount", 0)) == amount
					and int(contract.get("unit_price", 0)) == price
					and int(contract.get("cost_per_tick", 0)) == amount * price,
			"the terms of the contract must survive the save: %s" % str(contract), state)
	check(str(contract.get("town_id", "")) == "town_test"
					and str(contract.get("town_name", "")) == "Testville"
					and int(contract.get("row", 0)) == 5 and int(contract.get("col", 0)) == 5,
			"the town of the contract must survive the save", state)

	# The restored contract keeps charging from the next tick.
	trade2.tick_contracts()
	check(_cdata.treasury == 1000 - amount * price,
			"the restored contract must charge on its tick (treasury %d)"
					% _cdata.treasury, state)
	# The order is within the comfort rate of the town, so the town keeps up and its
	# warehouse does not move — but the goods ARE queued on the road.
	check(_tm.get_town_goods(town, WOOD) == 100,
			"a contract within the comfort rate must not drain the warehouse (got %d)"
					% _tm.get_town_goods(town, WOOD), state)
	check(int(_dm.get_route_status(5, 5).get("pending", 0)) == amount,
			"the restored contract must queue the goods on the road (got %d)"
					% int(_dm.get_route_status(5, 5).get("pending", 0)), state)

	# A broken record is dropped. A second order for the SAME good of the SAME town is an
	# EDIT of the existing contract, not a second deal (one contract per good and town):
	# the list must not grow and the id must stay.
	trade2.deserialize([{"town_id": "town_test"}])
	check(trade2._contracts.is_empty(),
			"a record without goods must be dropped", state)
	trade2.deserialize(saved)
	var restored_id := str(trade2._contracts[0].get("id", ""))
	check(bool(trade2.submit_order(_order(amount + 3, true, price)).get("ok", false)),
			"a second order for the same good must be accepted as an edit", state)
	check(trade2._contracts.size() == 1,
			"one town carries one contract per good, so the list must stay at one (%d)"
					% trade2._contracts.size(), state)
	check(str(trade2._contracts[0].get("id", "")) == restored_id,
			"an edit must keep the id of the contract (%s)" % restored_id, state)
	check(int(trade2._contracts[0].get("amount", 0)) == amount + 3,
			"the edit must write the new amount (got %d)"
					% int(trade2._contracts[0].get("amount", 0)), state)
	trade2.free()

# -------------------------------------------------------
# 9. The row shape of the "Trade deals" section
# -------------------------------------------------------

func _test_deals(state: Dictionary) -> void:
	_rig(10.0, 10)
	var price := _unit_price()
	var amount := 5
	check(bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)),
			"the contract must be signed", state)
	var deals: Array = _trade.get_contracts()
	check(deals.size() == 1,
			"the section must see one deal (%d)" % deals.size(), state)
	if deals.is_empty():
		return
	var deal: Dictionary = deals[0]
	var expected_name := str(_gdata.get_resource_data(WOOD).get("name", ""))
	check(str(deal.get("name", "")) == expected_name,
			"the row must show the display name of the goods (got \"%s\", expected \"%s\")"
					% [str(deal.get("name", "")), expected_name], state)
	check(str(deal.get("icon", "")) == str(_gdata.get_resource_data(WOOD).get("icon", "")),
			"the row must carry the icon of the goods", state)
	check(str(deal.get("type", "")) == "buy",
			"the city buys from the town, so the deal is a purchase", state)
	check(int(deal.get("amount", 0)) == amount,
			"the row must show the volume of the contract (got %d)"
					% int(deal.get("amount", 0)), state)
	check(int(deal.get("cost", 0)) == amount * price,
			"the row must show the payment of the contract (got %d, expected %d)"
					% [int(deal.get("cost", 0)), amount * price], state)
	check(int(deal.get("price", 0)) == price,
			"the row must show the unit price (got %d)" % int(deal.get("price", 0)), state)
	check(str(deal.get("town_name", "")) == "Testville"
			and str(deal.get("product_id", "")) == WOOD,
			"the row must name the town and the goods", state)
	var expected_delay := 10.0 * float(_dm.get_transit_time_per_hex())
	check(is_equal_approx(float(deal.get("delivery_time", 0.0)), expected_delay),
			"the row must show the transit delay of the route (got %s, expected %s)"
					% [str(float(deal.get("delivery_time", 0.0))), str(expected_delay)], state)
	# A copy is handed out: the section cannot edit the records of the manager.
	deal["amount"] = 999
	check(int(_trade.get_contracts()[0].get("amount", 0)) == amount,
			"the deals must be handed out as copies", state)

# -------------------------------------------------------
# 9b. One contract per good and town: edit and close
# -------------------------------------------------------

func _test_contract_edit(state: Dictionary) -> void:
	var _town := _rig(10.0, 10)
	var price := _unit_price()
	var amount := 5

	# The first order signs the contract, and the pair (town, good) finds it.
	check(bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)),
			"the contract must be signed", state)
	check(_trade._contracts.size() == 1,
			"one contract must be recorded (%d)" % _trade._contracts.size(), state)
	var contract_id := str(_trade._contracts[0].get("id", ""))
	check(str(_trade.get_contract("town_test", WOOD).get("id", "")) == contract_id,
			"get_contract must find the contract of the pair (town, good)", state)
	check(_trade.get_contract("town_test", PLANKS).is_empty(),
			"a good without a contract must give an empty record", state)

	# A second order for the SAME pair is an EDIT: the list does not grow, the id stays, the
	# amount moves and the payment of the tick is recounted. The price stays frozen at the
	# price of the signing — a different price is a different deal.
	_cdata.treasury = 1000
	var result = _trade.submit_order(_order(amount + 4, true, price + 1))
	check(bool(result.get("ok", false)),
			"a second order for the same good must be accepted as an edit: %s"
					% str(result.get("message", "")), state)
	check(_trade._contracts.size() == 1,
			"one town must carry one contract per good (got %d)" % _trade._contracts.size(), state)
	check(str(_trade._contracts[0].get("id", "")) == contract_id,
			"an edit must keep the id of the contract", state)
	check(int(_trade._contracts[0].get("amount", 0)) == amount + 4,
			"the edit must write the new amount (got %d)"
					% int(_trade._contracts[0].get("amount", 0)), state)
	check(int(_trade._contracts[0].get("unit_price", 0)) == price,
			"an edit must keep the price frozen at the signing (got %d, expected %d)"
					% [int(_trade._contracts[0].get("unit_price", 0)), price], state)
	check(int(_trade._contracts[0].get("cost_per_tick", 0)) == (amount + 4) * price,
			"the edit must recount the payment of the tick (got %d, expected %d)"
					% [int(_trade._contracts[0].get("cost_per_tick", 0)), (amount + 4) * price], state)

	# The edited contract charges the new amount on the very next tick.
	var before: int = _cdata.treasury
	_trade.tick_contracts()
	check(_cdata.treasury == before - (amount + 4) * price,
			"the edited contract must charge the new amount (treasury %d)" % _cdata.treasury, state)

	# Another good of the SAME town is a DIFFERENT contract: the rule is per good.
	var planks_price := _price_of(PLANKS)
	check(bool(_trade.submit_order(_order_of(PLANKS, amount, true, planks_price)).get("ok", false)),
			"another good of the same town must be signable", state)
	check(_trade._contracts.size() == 2,
			"a different good must be a second contract (got %d)" % _trade._contracts.size(), state)

	# Closing frees the good for a new deal and leaves the other contract alone.
	var close: Dictionary = _trade.close_contract(contract_id)
	check(bool(close.get("ok", false)),
			"closing a contract must succeed: %s" % str(close.get("message", "")), state)
	check(not str(close.get("message", "")).is_empty(),
			"the close must explain itself to the player", state)
	check(_trade._contracts.size() == 1,
			"closing must remove exactly one contract (got %d)" % _trade._contracts.size(), state)
	check(_trade.get_contract("town_test", WOOD).is_empty(),
			"the closed pair must have no contract", state)
	check(not _trade.get_contract("town_test", PLANKS).is_empty(),
			"closing one contract must not touch another good", state)

	# The freed good is signable again, and the new deal is a FRESH contract with a fresh id.
	check(bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)),
			"a good freed by a close must be signable again", state)
	check(_trade._contracts.size() == 2,
			"the new deal must be a fresh contract (got %d)" % _trade._contracts.size(), state)
	check(str(_trade.get_contract("town_test", WOOD).get("id", "")) != contract_id,
			"the new deal must get a fresh id", state)

	# Closing an id that is already gone is refused, not a crash.
	check(not bool(_trade.close_contract(contract_id).get("ok", true)),
			"closing an unknown contract must be refused", state)

# -------------------------------------------------------
# 10. The strain of a town under a standing contract
# -------------------------------------------------------

func _test_strain(state: Dictionary) -> void:
	var price := _unit_price()
	var town := _rig(10.0, 10)
	var comfort: float = _tm.get_town_supply_rate(town, WOOD)
	var ceiling: float = _te.get_contract_ceiling()
	check(comfort > 0.0,
			"a town that trades the good must have a supply rate (got %s)" % str(comfort), state)
	check(is_equal_approx(comfort, _te.get_contract_comfort()),
			"the supply rate must be the comfort rate of a town (got %s)" % str(comfort), state)
	check(comfort < ceiling,
			"the comfort rate must sit below the ceiling (got %s of %s)"
					% [str(comfort), str(ceiling)], state)
	check(is_equal_approx(_te.get_contract_drain(comfort), 0.0),
			"there must be no drain at the comfort rate", state)
	check(_te.get_contract_drain(comfort + 5.0) > 0.0,
			"the drain must begin just above the comfort rate", state)

	# Within the comfort rate: the town keeps up, and the warehouse does not move at all.
	var start: int = _tm.get_town_goods(town, WOOD)
	_cdata.treasury = 1000000
	check(bool(_trade.submit_order(_order(int(comfort), true, price)).get("ok", false)),
			"the contract must be signed", state)
	for i in range(30):
		_trade.tick_contracts()
	check(_trade._contracts.size() == 1,
			"a contract within the comfort rate must stay alive (%d contracts)"
					% _trade._contracts.size(), state)
	check(_tm.get_town_goods(town, WOOD) == start,
			"a contract within the comfort rate must not drain the warehouse (start %d, now %d)"
					% [start, _tm.get_town_goods(town, WOOD)], state)

	# Above the comfort rate the town strains: the warehouse falls behind, and a BIGGER
	# order takes a bigger toll over the same run of ticks.
	var small := int(comfort) + 10
	var big := int(comfort) + 70
	var small_loss := _measure_drain(small, 20, price)
	var big_loss := _measure_drain(big, 20, price)
	check(small_loss > 0,
			"an order above the comfort rate must drain the warehouse (lost %d)" % small_loss, state)
	check(big_loss > small_loss,
			"a bigger order must drain the warehouse faster (%d lost at %d/sec, %d at %d/sec)"
					% [small_loss, small, big_loss, big], state)

# -------------------------------------------------------
# 11. The delivery ledger: one-time purchases tracked on the road
# -------------------------------------------------------

func _test_delivery_ledger(state: Dictionary) -> void:
	var _town := _rig(10.0, 10)
	var price := _unit_price()

	# A one-time purchase on a road creates a delivery record.
	var amount := 20
	var result = _trade.submit_order(_order(amount, false, price))
	check(bool(result.get("ok", false)), "the purchase must succeed", state)
	check(_trade._deliveries.size() == 1,
			"a purchase on the road must create a delivery record (%d)"
					% _trade._deliveries.size(), state)
	var key := "town_test|wood"
	check(_trade._deliveries.has(key),
			"the delivery must be keyed by town|good", state)
	var delivery: Dictionary = _trade._deliveries[key]
	check(int(delivery.get("ordered", 0)) == amount,
			"the ordered amount must be %d (got %d)" % [amount, int(delivery.get("ordered", 0))], state)
	check(int(delivery.get("remaining", 0)) == amount,
			"the remaining must be the full amount before any shipment", state)
	check(int(delivery.get("spent", 0)) == amount * price,
			"the spent must be the full price (got %d)" % int(delivery.get("spent", 0)), state)
	check((delivery["lots"] as Array).size() == 1,
			"one purchase must make one lot (got %d)" % (delivery["lots"] as Array).size(), state)

	# A second purchase of the same good from the same town ADDS to the first.
	# Use 70 so the total is 90: after the first loop ships 50, 40 remain for the
	# contract-first attribution test, and 10 units stay in the town's stock so the
	# contract of 8/sec can be signed.
	var amount2 := 70
	var result2 = _trade.submit_order(_order(amount2, false, price))
	check(bool(result2.get("ok", false)), "the second purchase must succeed", state)
	check(_trade._deliveries.size() == 1,
			"a second purchase of the same good must not make a second record (%d)"
					% _trade._deliveries.size(), state)
	delivery = _trade._deliveries[key]
	check(int(delivery.get("ordered", 0)) == amount + amount2,
			"the ordered total must be the sum of both purchases (got %d)"
					% int(delivery.get("ordered", 0)), state)
	check(int(delivery.get("remaining", 0)) == amount + amount2,
			"the remaining total must be the sum", state)
	check((delivery["lots"] as Array).size() == 2,
			"two purchases must make two lots (got %d)" % (delivery["lots"] as Array).size(), state)

	# The delivery row shape.
	var rows: Array = _trade.get_deliveries()
	check(rows.size() == 1, "one delivery must give one row", state)
	if not rows.is_empty():
		var row: Dictionary = rows[0]
		check(str(row.get("kind", "")) == _trade.KIND_DELIVERY,
				"the row must carry the delivery kind", state)
		check(int(row.get("remaining", 0)) == amount + amount2,
				"the row must show the remaining amount", state)
		check(int(row.get("ordered", 0)) == amount + amount2,
				"the row must show the ordered total", state)
		check(int(row.get("spent", 0)) == (amount + amount2) * price,
				"the row must show the refundable coins", state)

	# Shipments decrease the remaining. The flow is 10/sec, so one tick ships 10 units.
	# The contract has no outstanding, so all 10 go to the purchase.
	for i in range(5):
		_dm.ship()
		# Advance the road so the shipped units arrive and the queue drains.
		_advance(_dm, 10.0)
	check(int(delivery.get("remaining", 0)) == amount + amount2 - 50,
			"after 50 units shipped the remaining must be %d (got %d)"
					% [amount + amount2 - 50, int(delivery.get("remaining", 0))], state)

	# The contract-first attribution: start a contract of 8/sec on the same good.
	# The flow is 10/sec, so the contract takes 8/sec and the purchase drains at 2/sec.
	_cdata.treasury = 1000000
	check(bool(_trade.submit_order(_order(8, true, price)).get("ok", false)),
			"the contract must be signed", state)
	# The contract's cargo was queued in the same tick; re-read the delivery reference
	# because the ledger may have reallocated the dictionary on insertion.
	if not _trade._deliveries.has(key):
		check(false, "the delivery record must still exist after the contract is signed", state)
		return
	delivery = _trade._deliveries[key]
	var before_remaining: int = int(delivery.get("remaining", 0))
	for i in range(5):
		_trade.tick_contracts()
		_dm.ship()
		_advance(_dm, 10.0)
		if _trade._deliveries.has(key):
			delivery = _trade._deliveries[key]
	var after_remaining: int = int(delivery.get("remaining", 0)) if _trade._deliveries.has(key) else 0
	check(after_remaining == before_remaining - 10,
			"with a contract of 8/sec and flow 10/sec, the purchase must drain by 2/sec over 5 ticks (before %d, after %d)"
					% [before_remaining, after_remaining], state)

	# When the purchase is fully shipped, the record disappears.
	while int(delivery.get("remaining", 0)) > 0:
		_trade.tick_contracts()
		_dm.ship()
		_advance(_dm, 10.0)
	check(not _trade._deliveries.has(key),
			"a fully shipped delivery must be dropped from the ledger", state)
	check(_trade.get_deliveries().is_empty(),
			"a fully shipped delivery must give no rows", state)

# -------------------------------------------------------
# 12. Cancelling a one-time purchase
# -------------------------------------------------------

func _test_delivery_cancel(state: Dictionary) -> void:
	var town := _rig(10.0, 10)
	var price := _unit_price()
	var amount := 50
	var total := amount * price
	_cdata.treasury = 1000
	var result = _trade.submit_order(_order(amount, false, price))
	check(bool(result.get("ok", false)), "the purchase must succeed", state)
	var key := "town_test|wood"
	check(_trade._deliveries.has(key), "the delivery must exist", state)

	# Cancel before anything ships: full refund.
	var before_treasury: int = _cdata.treasury
	var before_stock: int = _tm.get_town_goods(town, WOOD)
	var cancel = _trade.cancel_delivery("town_test", WOOD)
	check(bool(cancel.get("ok", false)),
			"the cancellation must succeed: %s" % str(cancel.get("message", "")), state)
	check(_cdata.treasury == before_treasury + total,
			"the full price must be refunded (treasury %d, expected %d)"
					% [_cdata.treasury, before_treasury + total], state)
	check(_tm.get_town_goods(town, WOOD) == before_stock + amount,
			"the full amount must go back into the warehouse (got %d, expected %d)"
					% [_tm.get_town_goods(town, WOOD), before_stock + amount], state)
	check(not _trade._deliveries.has(key),
			"a fully cancelled delivery must be removed from the ledger", state)
	check(int(_cdata.treasury_expense_accum.get(_gdata.SRC_TOWN_TRADE, 0)) == 0,
			"the refund must net the expense to zero in the current window (got %d)"
					% int(_cdata.treasury_expense_accum.get(_gdata.SRC_TOWN_TRADE, 0)), state)

	# A cancellation when nothing is on the way is refused.
	var empty = _trade.cancel_delivery("town_test", WOOD)
	check(not bool(empty.get("ok", false)),
			"a cancellation with nothing on the way must be refused", state)

	# Partial cancellation: ship 20 units, cancel the rest.
	_cdata.treasury = 1000
	_trade.submit_order(_order(amount, false, price))
	for i in range(2):
		_dm.ship()
		_advance(_dm, 10.0)
	var remaining_before: int = int(_trade._deliveries[key].get("remaining", 0))
	var refund_expected: int = remaining_before * price
	before_treasury = _cdata.treasury
	before_stock = _tm.get_town_goods(town, WOOD)
	cancel = _trade.cancel_delivery("town_test", WOOD)
	check(bool(cancel.get("ok", false)), "the partial cancellation must succeed", state)
	check(_cdata.treasury == before_treasury + refund_expected,
			"the partial refund must be %d (treasury %d)"
					% [refund_expected, _cdata.treasury], state)
	check(_tm.get_town_goods(town, WOOD) == before_stock + remaining_before,
			"the partial amount must go back (got %d, expected %d)"
					% [_tm.get_town_goods(town, WOOD), before_stock + remaining_before], state)

	# A second purchase at a different price: the refund is lot-exact.
	_cdata.treasury = 1000
	_trade.submit_order(_order(20, false, price))
	var price2 := price + 5
	_trade.submit_order(_order(30, false, price2))
	# The first lot is 20@price, the second is 30@price2. Cancel everything.
	before_treasury = _cdata.treasury
	cancel = _trade.cancel_delivery("town_test", WOOD)
	check(bool(cancel.get("ok", false)), "the mixed-price cancellation must succeed", state)
	var expected_refund: int = 20 * price + 30 * price2
	check(_cdata.treasury == before_treasury + expected_refund,
			"the mixed-price refund must be exact (got %d, expected %d)"
					% [_cdata.treasury - before_treasury, expected_refund], state)

# -------------------------------------------------------
# 13. The delivery ledger survives a save round-trip
# -------------------------------------------------------

func _test_delivery_save_load(state: Dictionary) -> void:
	var _town := _rig(10.0, 10)
	var price := _unit_price()
	var amount := 40
	_cdata.treasury = 1000
	_trade.submit_order(_order(amount, false, price))
	var key := "town_test|wood"
	# Ship 15 units before the save.
	for i in range(2):
		_dm.ship()
		_advance(_dm, 10.0)
	var remaining_before: int = int(_trade._deliveries[key].get("remaining", 0))
	var spent_before: int = int(_trade._deliveries[key].get("spent", 0))

	var saved: Dictionary = _trade.serialize_deliveries()
	check(saved.has("deliveries") and saved.has("contract_outstanding"),
			"the save must carry both deliveries and contract outstanding", state)

	# The round-trip: the same delivery, with the same lots.
	var trade2 = load("res://scripts/town_trade_manager.gd").new()
	trade2.initialize(_tm, _dm)
	trade2.deserialize_deliveries(saved)
	check(trade2._deliveries.size() == 1,
			"the delivery must be restored (%d)" % trade2._deliveries.size(), state)
	var restored: Dictionary = trade2._deliveries[key]
	check(int(restored.get("remaining", 0)) == remaining_before,
			"the remaining must survive the save (got %d, expected %d)"
					% [int(restored.get("remaining", 0)), remaining_before], state)
	check(int(restored.get("spent", 0)) == spent_before,
			"the spent must survive the save (got %d, expected %d)"
					% [int(restored.get("spent", 0)), spent_before], state)
	check((restored["lots"] as Array).size() == 1,
			"the lots must survive the save (got %d)" % (restored["lots"] as Array).size(), state)

	# The restored delivery is still cancellable.
	var before_treasury: int = _cdata.treasury
	var cancel = trade2.cancel_delivery("town_test", WOOD)
	check(bool(cancel.get("ok", false)), "the restored delivery must be cancellable", state)
	check(_cdata.treasury == before_treasury + remaining_before * price,
			"the restored delivery must refund the right amount", state)
	trade2.free()

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# A fresh rig: one town with 100 units and a treasury of 500, a route of the given
# length and flow (no route when the speed is 0), a real logistics over the stub and
# a trade manager over the towns and the logistics. The city starts with 1000 coins.
# -------------------------------------------------------
# 15. The city sells: a one-time deal
# -------------------------------------------------------

func _test_sell_once(state: Dictionary) -> void:
	var town := _rig(0.0, 0)
	town["buy_pool"] = [WOOD]
	_cdata.city_storage[WOOD] = 50
	var price := int(round(_gdata.get_price(WOOD)))
	var town_before: int = _tm.get_town_treasury(town)
	var city_before: int = _cdata.treasury
	var result = _trade.submit_order(_sell_order(WOOD, 10, false, price))
	check(bool(result.get("ok", false)),
			"a sale with enough goods and coins must succeed: %s"
					% str(result.get("message", "")), state)
	check(not str(result.get("message", "")).is_empty(),
			"a settled sale must say what happened", state)
	check(int(_cdata.city_storage.get(WOOD, 0)) == 40,
			"the goods must leave the city storage (wood %d)"
					% int(_cdata.city_storage.get(WOOD, 0)), state)
	check(_tm.get_town_treasury(town) == town_before - 10 * price,
			"the town must pay for the goods (treasury %d, expected %d)"
					% [_tm.get_town_treasury(town), town_before - 10 * price], state)
	check(_cdata.treasury == city_before + 10 * price,
			"the city must be paid (treasury %d, expected %d)"
					% [_cdata.treasury, city_before + 10 * price], state)
	check(int(_cdata.treasury_income_accum.get(_gdata.SRC_TOWN_TRADE, 0)) == 10 * price,
			"the sale must enter the income of the trade with the towns", state)
	check(_tm.get_town_goods(town, WOOD) == 100,
			"the bought goods join the virtual production of the town and not its shelf", state)


# -------------------------------------------------------
# 16. The city sells a GROUP: any member, chosen from the city stock
# -------------------------------------------------------

func _test_sell_group(state: Dictionary) -> void:
	var town := _rig(0.0, 0)
	town["buy_pool"] = ["@fruits"]
	town["treasury"] = 100000
	var stocked: Array = ["grapes", "figs"]
	_cdata.city_storage.clear()
	for pid in stocked:
		_cdata.city_storage[pid] = 40
	# A good outside the group: it must never be taken for a group sale.
	_cdata.city_storage[WOOD] = 40
	var price: int = _te.get_group_price("@fruits")
	check(price > 0, "the group @fruits must have a price of its own", state)

	# An order that carries no price is charged the group price of the row.
	var result = _trade.submit_order(_sell_order("@fruits", 8, false, 0))
	check(bool(result.get("ok", false)),
			"a group sale with enough members in stock must succeed: %s"
					% str(result.get("message", "")), state)
	var total_stock := 0
	for pid in stocked:
		total_stock += int(_cdata.city_storage.get(pid, 0))
	check(total_stock == 80 - 8,
			"the group sale must take exactly its amount from the members in stock (%d left)"
					% total_stock, state)
	check(int(_cdata.city_storage.get(WOOD, 0)) == 40,
			"a good outside the group must not be taken", state)
	check(_tm.get_town_treasury(town) == 100000 - 8 * price,
			"the town must pay the price of the GROUP (%d, treasury %d)"
					% [price, _tm.get_town_treasury(town)], state)

	# The member is chosen at random, not always the first one. A fresh rig with both
	# members at 40 and ten sales of 2 units: a "first member always" choice would leave
	# the second member untouched, a random one spreads the units over both.
	town = _rig(0.0, 0)
	town["buy_pool"] = ["@fruits"]
	town["treasury"] = 100000
	_cdata.city_storage.clear()
	for pid in stocked:
		_cdata.city_storage[pid] = 40
	_cdata.city_storage[WOOD] = 40
	for i in range(10):
		_trade.submit_order(_sell_order("@fruits", 2, false, price))
	check(int(_cdata.city_storage.get("grapes", 0)) < 40
					and int(_cdata.city_storage.get("figs", 0)) < 40,
			"the group must be spread over its members (grapes %d, figs %d)"
					% [int(_cdata.city_storage.get("grapes", 0)),
					int(_cdata.city_storage.get("figs", 0))], state)
	check(int(_cdata.city_storage.get(WOOD, 0)) == 40,
			"a good outside the group must not be taken by the small sales either", state)


# -------------------------------------------------------
# 17. The refusals of a sale
# -------------------------------------------------------

func _test_sell_refusals(state: Dictionary) -> void:
	var town := _rig(0.0, 0)
	_cdata.city_storage[WOOD] = 50

	# The town does not buy the good: its buy pool is the whole demand.
	var result = _trade.submit_order(_sell_order(WOOD, 5, false, 10))
	check(not bool(result.get("ok", false)),
			"a good outside the buy pool must not be sold", state)
	check(int(_cdata.city_storage.get(WOOD, 0)) == 50 and _cdata.treasury == 1000
					and _tm.get_town_treasury(town) == 500,
			"a refused sale must change nothing", state)

	town["buy_pool"] = [WOOD]
	# The city does not have the goods.
	_cdata.city_storage[WOOD] = 3
	result = _trade.submit_order(_sell_order(WOOD, 5, false, 10))
	check(not bool(result.get("ok", false)),
			"a sale beyond the city storage must not succeed", state)
	check(int(_cdata.city_storage.get(WOOD, 0)) == 3 and _tm.get_town_treasury(town) == 500,
			"a refused sale must not move the goods or the coins", state)

	# The town cannot pay.
	_cdata.city_storage[WOOD] = 50
	town["treasury"] = 5
	result = _trade.submit_order(_sell_order(WOOD, 5, false, 100))
	check(not bool(result.get("ok", false)),
			"a sale the town cannot pay must not succeed", state)
	check(int(_cdata.city_storage.get(WOOD, 0)) == 50 and _tm.get_town_treasury(town) == 5,
			"a refused sale must not write the goods off", state)

	# A group with no member in stock.
	town["buy_pool"] = ["@fruits"]
	town["treasury"] = 500
	_cdata.city_storage.clear()
	result = _trade.submit_order(_sell_order("@fruits", 1, false, 10))
	check(not bool(result.get("ok", false)),
			"a group the city has nothing of must not be sold", state)

	# The opposite direction of an existing contract is a refusal, not an edit.
	town["buy_pool"] = [WOOD]
	_cdata.city_storage[WOOD] = 50
	check(bool(_trade.submit_order(_order(10, true, _unit_price())).get("ok", false)),
			"the town must be able to sign a contract to sell wood", state)
	result = _trade.submit_order(_sell_order(WOOD, 5, true, 10))
	check(not bool(result.get("ok", false)),
			"a contract in the opposite direction must be refused", state)


# -------------------------------------------------------
# 18. A standing sale: it pays and drains every tick
# -------------------------------------------------------

func _test_sell_contract(state: Dictionary) -> void:
	var town := _rig(0.0, 0)
	town["buy_pool"] = [WOOD]
	town["treasury"] = 100000
	_cdata.city_storage[WOOD] = 30
	var price := 5
	var result = _trade.submit_order(_sell_order(WOOD, 10, true, price))
	check(bool(result.get("ok", false)),
			"a standing sale with enough goods and coins must be signed: %s"
					% str(result.get("message", "")), state)
	check(_trade._contracts.size() == 1, "the sale must be one contract", state)
	check(str(_trade._contracts[0].get("side", "")) == "buy",
			"the contract must remember the direction of the town", state)
	check(_trade.get_contracts()[0].get("type", "") == "sell",
			"the row of the deal must be a sale for the city", state)

	var city_before: int = _cdata.treasury
	var town_before: int = _tm.get_town_treasury(town)
	_trade.tick_contracts()
	check(int(_cdata.city_storage.get(WOOD, 0)) == 20,
			"one tick must give the town 10 units (wood %d)"
					% int(_cdata.city_storage.get(WOOD, 0)), state)
	check(_cdata.treasury == city_before + 10 * price,
			"the city must be paid every tick", state)
	check(_tm.get_town_treasury(town) == town_before - 10 * price,
			"the town must pay every tick", state)
	check(_planned_entry(WOOD, _gdata.SRC_TOWN_TRADE).is_empty(),
			"a sale must not enter the plan of the production", state)

	# The stock runs out: the last tick gives what is left, the next one tears.
	_trade.tick_contracts()
	_trade.tick_contracts()
	check(int(_cdata.city_storage.get(WOOD, 0)) == 0,
			"the contract must drain the city storage (wood %d)"
					% int(_cdata.city_storage.get(WOOD, 0)), state)
	_trade.tick_contracts()
	check(_trade._contracts.is_empty(),
			"a sale contract must tear when the city runs out of the goods", state)

	# A town that cannot pay tears the contract before any goods move.
	var town2 := _rig(0.0, 0)
	town2["buy_pool"] = [WOOD]
	town2["treasury"] = 100
	_cdata.city_storage[WOOD] = 30
	check(bool(_trade.submit_order(_sell_order(WOOD, 5, true, 10)).get("ok", false)),
			"the contract must be signed while the town can pay the first tick", state)
	town2["treasury"] = 0
	_trade.tick_contracts()
	check(_trade._contracts.is_empty(),
			"a sale contract must tear when the town cannot pay", state)
	check(int(_cdata.city_storage.get(WOOD, 0)) == 30,
			"a torn tick must not move the goods", state)


# -------------------------------------------------------
# 19. A sale contract survives a save round-trip
# -------------------------------------------------------

func _test_sell_save_load(state: Dictionary) -> void:
	var town := _rig(0.0, 0)
	town["buy_pool"] = [WOOD]
	town["treasury"] = 100000
	_cdata.city_storage[WOOD] = 30
	check(bool(_trade.submit_order(_sell_order(WOOD, 5, true, 4)).get("ok", false)),
			"the sale contract must be signed", state)
	var saved: Array = _trade.serialize()
	var restored = load("res://scripts/town_trade_manager.gd").new()
	restored.initialize(_tm, _dm)
	restored.deserialize(saved)
	var deals: Array = restored.get_contracts()
	check(deals.size() == 1 and str(deals[0].get("type", "")) == "sell",
			"the direction of a sale contract must survive the save", state)
	var before := int(_cdata.city_storage.get(WOOD, 0))
	restored.tick_contracts()
	check(int(_cdata.city_storage.get(WOOD, 0)) == before - 5,
			"a restored sale contract must keep charging", state)
	restored.free()


# -------------------------------------------------------
# 20. A decorated good is its base for a deal
# -------------------------------------------------------

# A generated good ("gold jewelry with lazurite") is its base with additions, so a deal that
# names the plain good must accept it: otherwise the player's decorated jewelry would be
# unsellable and a contract would tear while the shelf is full. The plain good goes first —
# the decoration is worth more and the deal pays the price of the plain one.
func _test_sell_decorated(state: Dictionary) -> void:
	var town := _rig(0.0, 0)
	town["buy_pool"] = [DECORATED_BASE]
	town["treasury"] = 100000
	var decorated: String = _gdata.make_generated_id(DECORATED_BASE, ["lazurite_ore"])
	check(decorated != DECORATED_BASE, "the decorated id must differ from the base", state)
	_cdata.add_to_storage(decorated, 10, "common")
	check(int(_cdata.city_storage.get(DECORATED_BASE, 0)) == 0,
			"the case starts with no plain good on the shelf", state)

	# A one-time sale of the plain good, paid for out of the decorated stock.
	var price := int(round(_gdata.get_price(DECORATED_BASE)))
	var result = _trade.submit_order(_sell_order(DECORATED_BASE, 10, false, price))
	check(bool(result.get("ok", false)),
			"a sale of the plain good must accept the decorated variant: %s"
					% str(result.get("message", "")), state)
	check(int(_cdata.city_storage.get(decorated, 0)) == 0,
			"the decorated good must be shipped (left %d)"
					% int(_cdata.city_storage.get(decorated, 0)), state)

	# A standing contract on the plain good must not tear while only decorated ones are there.
	_cdata.add_to_storage(decorated, 20, "common")
	result = _trade.submit_order(_sell_order(DECORATED_BASE, 5, true, price))
	check(bool(result.get("ok", false)),
			"a standing contract on the plain good must be signed against the decorated stock: %s"
					% str(result.get("message", "")), state)
	_trade.tick_contracts()
	check(_trade._contracts.size() == 1,
			"the contract must survive a tick served from the decorated stock", state)
	check(int(_cdata.city_storage.get(decorated, 0)) == 15,
			"one tick must ship 5 decorated units (left %d)"
					% int(_cdata.city_storage.get(decorated, 0)), state)

	# Both on the shelf: the plain good goes first.
	_cdata.add_to_storage(DECORATED_BASE, 5, "common")
	_trade.tick_contracts()
	check(int(_cdata.city_storage.get(DECORATED_BASE, 0)) == 0,
			"the plain good must be shipped before the decorated one (left %d)"
					% int(_cdata.city_storage.get(DECORATED_BASE, 0)), state)
	check(int(_cdata.city_storage.get(decorated, 0)) == 15,
			"the decorated stock must stay untouched while the plain good lasts (left %d)"
					% int(_cdata.city_storage.get(decorated, 0)), state)


func _rig(speed: float, length: int) -> Dictionary:
	_free_rig()
	_cdata.city_storage.clear()
	_cdata.city_quality_detail.clear()
	_cdata.treasury = 1000
	_cdata.treasury_expense_accum.clear()
	# The plan of the towns lives one tick and is cleared by the reset; a fresh rig starts
	# without it, so a case never reads the leftovers of the previous one.
	_cdata.town_planned_production.clear()
	var town := {
		"id": "town_test",
		"name": "Testville",
		"row": 5,
		"col": 5,
		"treasury": 500,
		"sell_pool": [WOOD, PLANKS],
		"storage": {WOOD: 100, PLANKS: 100},
		"quality": {WOOD: "fine", PLANKS: "fine"},
	}
	var fake := FakeMap.new()
	if speed > 0.0:
		fake.set_route(5, 5, length, speed)
	_tm = load("res://scripts/town_manager.gd").new()
	_tm.towns = [town]
	_dm = load("res://scripts/delivery_manager.gd").new()
	_dm.initialize(fake)
	_trade = load("res://scripts/town_trade_manager.gd").new()
	_trade.initialize(_tm, _dm)
	return town

# The record of one source in the plan of the tick (the map the tab "Resources" reads).
func _planned_entry(pid: String, source_id: String) -> Dictionary:
	return _cdata.get_planned_production_map().get(pid, {}).get(source_id, {})

# The per-second amount the plan promises for one product and source — the same reading
# the green label of the tab "Resources" makes (resources_tab._format_prod_label).
func _planned_amount(pid: String, source_id: String) -> int:
	var entry := _planned_entry(pid, source_id)
	if entry.is_empty():
		return 0
	var amount := float(entry.get("amount", 0))
	var interval := float(entry.get("interval", 0))
	if interval > 0.0:
		return int(round(amount * _cdata.SIMULATION_TICK / interval))
	return int(round(amount))

func _free_rig() -> void:
	for node in [_tm, _dm, _trade]:
		if node != null and is_instance_valid(node):
			node.free()
	_tm = null
	_dm = null
	_trade = null

# The order of the window (see town_ui._on_confirm_pressed): the town sells to the
# city. A unit_price of 0 means "the order carries no price" — the manager must
# recompute it by the rule of the row.
func _order(amount: int, permanent: bool, unit_price: int) -> Dictionary:
	return {
		"town_id": "town_test",
		"town_name": "Testville",
		"row": 5,
		"col": 5,
		"side": "sell",
		"product_id": WOOD,
		"product_name": "Wood",
		"amount": amount,
		"permanent": permanent,
		"route_capacity": 10.0,
		"unit_price": unit_price,
	}

# The price of one unit the way the sale row of the window shows it: the current
# market price with the multiplier of the level the town holds.
func _unit_price() -> int:
	return _price_of(WOOD)

func _price_of(product_id: String) -> int:
	var market := float(_gdata.get_price(product_id))
	return int(round(market * float(_gdata.get_quality_price_multiplier("fine"))))

# The same order for another good of the town: the "one contract per good" rule is per
# good, so a case needs a second good to tell "the same good" from "another good".
func _order_of(product_id: String, amount: int, permanent: bool, unit_price: int) -> Dictionary:
	var order := _order(amount, permanent, unit_price)
	order["product_id"] = product_id
	order["product_name"] = str(_gdata.get_resource_data(product_id).get("name", product_id))
	return order

# The order of the purchase column of the window (see town_ui._on_confirm_pressed): the
# town buys, so the city sells. The goods are a concrete id or an "@group".
func _sell_order(product_id: String, amount: int, permanent: bool, unit_price: int) -> Dictionary:
	var order := _order_of(product_id, amount, permanent, unit_price)
	order["side"] = "buy"
	return order

# Runs a standing contract of the given amount for the given number of ticks on a fresh
# rig and returns how many units the warehouse of the town lost. It stops early if the
# contract tears (the town ran dry), so the number never counts past the tear.
func _measure_drain(amount: int, ticks: int, price: int) -> int:
	var town := _rig(10.0, 10)
	_cdata.treasury = 1000000
	var start: int = _tm.get_town_goods(town, WOOD)
	if not bool(_trade.submit_order(_order(amount, true, price)).get("ok", false)):
		return 0
	for i in range(ticks):
		if _trade._contracts.is_empty():
			break
		_trade.tick_contracts()
	return start - _tm.get_town_goods(town, WOOD)

# Advance only the arrivals by seconds of game time in steps of SHIP_STEP: the
# shipment is NOT called — the caller decides when the tick ships.
func _advance(dm, seconds: float) -> void:
	var left := seconds
	while left > 0.0001:
		var step: float = minf(dm.SHIP_STEP, left)
		dm.advance(step)
		left -= step

func _delivered(pid: String) -> int:
	return int(_cdata.city_storage.get(pid, 0))

func check(condition: bool, message: String, state: Dictionary) -> void:
	if condition:
		return
	state["failed"] = true
	print("FAILED: %s" % message)
	push_error("ASSERT: %s" % message)
