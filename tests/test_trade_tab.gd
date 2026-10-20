# Test of the "Trade" tab: the internal market, the resource cards, the toggles
# of the consumption permission and the priority of the write-off by quality.
#   godot --headless --path . --script res://tests/test_trade_tab.gd
#
# The balance numbers (amount/interval, prices, the composition of the groups) are verified against the DATA
# themselves, and not against the constants of the test: the balance in the json changes, the test does not.
# Checks:
#
#  1. The CityData state of the market: by default everything is allowed, the priority is the
#     default from data/qualities.json; the toggle switches it, an unknown
#     priority from the save rolls back to the default, an empty key is a no-op.
#  2. The priority cycle: best → worst → random → best, the set and the order come from
#     the data (quality_priority_options).
#  3. The priority REALLY changes the write-off: a mixed storage (ordinary +
#     perfect) under "best" eats the perfect first, under "worst" —
#     the ordinary.
#  4. The prohibition (the toggle) really stops it: the city consumption does not
#     write off the storage and does not pay into the treasury; the plan has no source; the production
#     bonus is removed; the card stays in the map with enabled = false.
#  5. get_population_consumption_map: the row key is display_key, the group is NOT
#     expanded, consumers_total = max("All Citizens", Σ professions).
#  6. The fact of the market counter is filled on the write-off and cleared in
#     reset_counters (lives exactly one tick).
#  7. SaveManager: the market settings survive saving; in an old save without the
#     fields everything is allowed.
#  8. The live scene CityUI.tscn: the columns are built from the scene, the cards
#     are created, both toggle buttons show the same state.
extends SceneTree

# The hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")
# The shared formatting of the money readouts: the expected texts are assembled by the
# same helper the interface uses, icon included. The script is loaded at RUN time: a
# preloaded copy is compiled before the autoloads are registered, and the GameData
# identifier inside it does not resolve in a --script run.
var _money_fmt = null

func _money(text: String) -> String:
    if _money_fmt == null:
        _money_fmt = load("res://scripts/ui_helpers.gd")
    return _money_fmt.money(text)

func _money_rate(text: String) -> String:
    if _money_fmt == null:
        _money_fmt = load("res://scripts/ui_helpers.gd")
    return _money_fmt.money_rate(text)


# A stub of the map for the inline panels of the "Trade deals" section: the column reads its
# deals through get_town_contracts and get_town_deliveries (see
# external_trade_tab._collect_deals), so a synthetic list can be unfolded by the toggle exactly
# as the live one is. The cancellation of a delivery goes the other way, through
# cancel_town_delivery — the stub records the call instead of turning to a manager.
class DealMap extends Node:
    var deals: Array = []
    var deliveries: Array = []
    var cancelled: Array = []
    var cancel_result: Dictionary = {"ok": true, "message": ""}
    func get_town_contracts() -> Array:
        return deals
    func get_town_deliveries() -> Array:
        return deliveries
    func cancel_town_delivery(town_id: String, product_id: String) -> Dictionary:
        cancelled.append("%s|%s" % [town_id, product_id])
        return cancel_result

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state: Dictionary = {"failed": false}
    var city = get_root().get_node("CityData")
    var gdata = get_root().get_node("GameData")
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    city.treasury = 0
    city.total_population = 3
    # The pseudo-profession "all" eats @fruits (10 units per citizen once a second).
    var all_key := _all_key(gdata)
    var all_members: Array = _all_members(gdata, all_key)
    check(not all_members.is_empty(), "the pseudo-profession all has no resource for the check", state)

    # ---- 1. The state of the market by default ----
    check(city.is_market_consumption_enabled(all_key),
        "by default the consumption must be allowed", state)
    var default_priority: String = gdata.get_quality_priority_default()
    check(city.get_consumption_priority(all_key) == default_priority,
        "the default priority must match qualities.json", state)
    check(city.toggle_market_consumption_enabled(all_key) == false,
        "the toggle must switch the consumption off", state)
    check(not city.is_market_consumption_enabled(all_key),
        "after the toggle the consumption must be forbidden", state)
    check(city.toggle_market_consumption_enabled(all_key) == true,
        "the second toggle must switch the consumption back on", state)
    # An unknown priority (a corrupted save) rolls back to the default.
    city.consumption_priority[all_key] = "some nonsense"
    check(city.get_consumption_priority(all_key) == default_priority,
        "an unknown priority must roll back to the default", state)
    # An empty key is a no-op (nothing to address).
    city.set_market_consumption_enabled("", false)
    check(city.is_market_consumption_enabled(""),
        "an empty key must be ignored", state)

    # ---- 2. The priority cycle ----
    var options: Array = gdata.get_quality_priority_options()
    check(options.size() >= 2, "at least two priority options are needed in the data", state)
    if options.size() >= 2:
        city.consumption_priority[all_key] = str(options[0])
        check(city.cycle_consumption_priority(all_key) == str(options[1]),
            "the priority cycle must follow the order of the data: %s" % str(options), state)
        # The cycle is circular: having passed the whole list, we return to the first.
        # We are already on options[1], there are size-2 transitions left.
        for i in range(1, options.size() - 1):
            city.cycle_consumption_priority(all_key)
        city.cycle_consumption_priority(all_key)
        check(city.get_consumption_priority(all_key) == str(options[0]),
            "the priority cycle must close on the first option: %s" % str(options), state)
        # An unknown current value starts the cycle from the first option.
        city.consumption_priority[all_key] = "garbage"
        check(city.cycle_consumption_priority(all_key) == str(options[1]),
            "with an unknown current value the cycle takes the next option", state)
        city.consumption_priority.erase(all_key)

    # ---- 3. The priority really changes the order of the write-off ----
    # A mixed storage: 10 ordinary + 10 perfect, write off 10.
    var first_member := str(all_members[0])
    _check_priority_order(city, first_member, "best", "perfect", state)
    _check_priority_order(city, first_member, "worst", "common", state)

    # ---- 4. The prohibition really stops the city consumption ----
    var wm = load("res://scripts/worker_manager.gd").new()
    city.total_population = 3
    city.treasury = 0
    for m in all_members:
        city.add_to_storage(str(m), 100, "common")
    # Allowed — it is written off and the treasury is paid.
    wm.tick_city_consumption(1.0)
    var spent_enabled := _total_storage(city, all_members)
    check(spent_enabled > 0, "with the consumption allowed the write-off must happen", state)
    check(city.treasury > 0, "with the consumption allowed the treasury must receive income", state)
    check(int(city.market_consumption_rates.get(first_member, 0)) > 0,
        "the market fact must accumulate on the write-off", state)
    # We forbid it — and repeat the tick.
    city.set_market_consumption_enabled(all_key, false)
    var stock_before := _total_storage(city, all_members)
    var treasury_before: int = city.treasury
    wm.tick_city_consumption(1.0)
    check(_total_storage(city, all_members) == stock_before,
        "with the prohibition the storage must not be written off", state)
    check(city.treasury == treasury_before,
        "with the prohibition the income to the treasury must not go", state)
    # The prohibition is visible in the plan: the members of the forbidden group have no source.
    # We check exactly the members of this group: the pseudo-profession "All Citizens"
    # may have several records (@fruits and @alcohol), and forbidding @fruits
    # must not throw @alcohol out of the plan.
    var plan: Dictionary = wm.get_planned_consumption_map(false)
    var plan_leak := ""
    # The source key is the profession identifier (GameData.get_source_display_name),
    # and not its label: the labels depend on the language, and the plan does not depend on it.
    var all_source_id: String = gdata.profession_source_id("all")
    for m in all_members:
        var member := str(m)
        if plan.has(member) and plan[member].has(all_source_id):
            plan_leak = member
            break
    check(plan_leak == "",
        "a forbidden resource must not get into the consumption plan (found %s)" % plan_leak, state)
    # The card stays in the market map, but with enabled = false.
    var pop_map: Dictionary = wm.get_population_consumption_map()
    check(pop_map.has(all_key),
        "a forbidden resource must stay in the market map (otherwise it cannot be enabled)", state)
    if pop_map.has(all_key):
        check(pop_map[all_key].get("enabled", true) == false,
            "in the market map a forbidden resource is marked enabled = false", state)
    # We return the permission — the expense has started again.
    city.set_market_consumption_enabled(all_key, true)
    wm.tick_city_consumption(1.0)
    check(_total_storage(city, all_members) < stock_before,
        "after the permission the write-off must resume", state)

    # ---- 4b. The prohibition removes the production bonus ----
    # We take the record of the fisherman (@boats): it has production_bonus +50%.
    var boats_key := "@boats"
    if gdata.product_groups.has("boats"):
        for m in gdata.product_groups["boats"]:
            city.add_to_storage(str(m), 100, "common")
        var cons_list: Array = gdata.get_profession_consumption("fisherman")
        var bonus_on := 0.0
        for e in cons_list:
            bonus_on += wm._aggregate_production_bonus([e])
        check(bonus_on > 0.0,
            "with the consumables in storage the production bonus must be credited", state)
        city.set_market_consumption_enabled(boats_key, false)
        var bonus_off := 0.0
        for e in cons_list:
            bonus_off += wm._aggregate_production_bonus([e])
        check(bonus_off == 0.0,
            "with the consumption forbidden the production bonus must be removed", state)
        city.set_market_consumption_enabled(boats_key, true)

    # ---- 5. The shape of the market map ----
    check(pop_map.has(all_key), "the market map must contain the resource of the pseudo-profession all", state)
    if pop_map.has(all_key):
        var row: Dictionary = pop_map[all_key]
        check(row.get("is_group", false) == true,
            "the resource of the pseudo-profession all is a group, is_group must be true", state)
        check((row.get("members", []) as Array).size() == all_members.size(),
            "the group must not be expanded: members = all the members", state)
        check(int(row.get("consumers_total", 0)) == 3,
            "consumers_total for \"All Citizens\" must equal the population: %d" % int(row.get("consumers_total", 0)), state)
        # The speed: amount per citizen / interval, multiplied by the population.
        # We count ONLY by the records of this card: the pseudo-profession all has
        # several of them (@fruits and @alcohol), and the speed of a row is its own.
        var expected := 0.0
        for e in gdata.get_profession_consumption("all"):
            if str(e.get("display_key", "")) != all_key:
                continue
            var amount := float(e.get("amount", 0))
            var iv := float(e.get("interval", 0))
            expected += (amount * 3.0 * city.SIMULATION_TICK / iv) if iv > 0.0 else amount * 3.0 * city.SIMULATION_TICK
        check(absf(float(row.get("per_sec", -1.0)) - expected) < 0.01,
            "the per_sec of the card is wrong: expected %.2f, got %.2f" % [expected, float(row.get("per_sec", 0.0))], state)
    # The map key is display_key, and not pid: for the fisherman it is "@boats", and not the pid.
    # We assign the fisherman to an improvement so that the profession appears in the map.
    var pop_map2: Dictionary = wm.get_population_consumption_map()
    var has_group_row := pop_map2.has("@boats")
    check(has_group_row or not pop_map2.has("reed_boat"),
        "the rows of the cards must be keyed by display_key, and not by pid", state)
    # The fisherman is also part of "All Citizens": consumers_total = max(3, 1) = 3.
    if has_group_row:
        var boats_row: Dictionary = pop_map2["@boats"]
        check(int(boats_row.get("consumers_total", 0)) == 1,
            "@boats must have one fisherman as a consumer: %d" % int(boats_row.get("consumers_total", 0)), state)

    # ---- 6. The norm per consumer (the "Consumption per 1" row) ----
    # The card shows the norm of ONE citizen from data/consumption.json, and not
    # the sum over the city: with a population of 3 the sum would be three times bigger, and the player
    # would not see his own numbers from the data.
    if pop_map.has(all_key):
        var unit_row: Dictionary = pop_map[all_key]
        var json_amount := 0
        var json_interval := 0.0
        for e in gdata.get_profession_consumption("all"):
            if str(e.get("display_key", "")) != all_key:
                continue
            json_amount = int(e.get("amount", 0))
            json_interval = float(e.get("interval", 0))
            break
        check(int(unit_row.get("per_consumer_amount", -1)) == json_amount,
            "the norm per consumer must match the amount from consumption.json: expected %d, got %d"
                % [json_amount, int(unit_row.get("per_consumer_amount", 0))], state)
        check(is_equal_approx(float(unit_row.get("per_consumer_interval", -1.0)), json_interval),
            "the interval of the norm must match consumption.json", state)
        var expected_unit_per_sec: float = (json_amount * city.SIMULATION_TICK / json_interval
            if json_interval > 0.0 else json_amount * city.SIMULATION_TICK)
        check(absf(float(unit_row.get("per_consumer_per_sec", -1.0)) - expected_unit_per_sec) < 0.01,
            "per_consumer_per_sec must be the norm per consumer, and not the sum: expected %.2f, got %.2f"
                % [expected_unit_per_sec, float(unit_row.get("per_consumer_per_sec", 0.0))], state)
        check(float(unit_row.get("per_consumer_per_sec", 0.0))
                < float(unit_row.get("per_sec", 0.0)),
            "the norm per consumer must be less than the sum over the city", state)
        # The norm is also stored in the source (amount without multiplication by count).
        var src_all: Dictionary = (unit_row.get("sources", {}) as Dictionary).get(
        gdata.profession_source_id("all"), {})
        check(int(src_all.get("unit_amount", -1)) == json_amount,
            "unit_amount in the source must be the amount from consumption.json", state)
        check(int(src_all.get("amount", 0)) == json_amount * int(city.total_population),
            "amount in the source must be the sum over all the citizens", state)

    # ---- 7. The income by the cards: the plan and the fact ----
    # The plan (demand × price) must agree with the plan "Population consumption"
    # in the treasury tooltip — both take the same formula (_planned_market_income_per_pid).
    var income_map: Dictionary = wm.get_population_income_map()
    check(not income_map.is_empty(),
        "the plan of the income by the cards must not be empty with a live population", state)
    var treasury_plan: Dictionary = wm.get_planned_treasury_income_map()
    var treasury_consumption: Dictionary = treasury_plan.get(city.POPULATION_INCOME_TYPE, {})
    var total_card_income := 0.0
    var total_treasury_market := 0.0
    for dkey in income_map:
        total_card_income += float(income_map[dkey].get("coins_per_sec", 0.0))
    for source_id in treasury_consumption:
        for pid in treasury_consumption[source_id]:
            total_treasury_market += float(treasury_consumption[source_id][pid].get("coins_per_sec", 0.0))
    check(absf(total_card_income - total_treasury_market) < 0.01,
        "the sum of the plan of the income of the cards (%.2f) must match the plan of the treasury tooltip (%.2f)"
            % [total_card_income, total_treasury_market], state)
    # The income keys are display_key, and not the pid of the members of the group.
    var income_group_key := ""
    for dkey in income_map:
        if str(dkey).begins_with("@"):
            income_group_key = str(dkey)
            break
    check(not income_group_key.is_empty(),
        "the income of a group resource must come under the key @group", state)
    # Verifying the fact requires a clean base: we zero the treasury window and make
    # exactly one write-off by THIS instance of worker_manager. Otherwise the treasury
    # may contain income from sources that are not in the plan of this
    # instance (for example, from the live worker_manager of the scene), and the sums
    # would diverge not because of the cards.
    city.treasury_income_accum.clear()
    city.treasury_income_product_accum.clear()
    city.treasury_income_snapshot.clear()
    city.treasury_income_product_snapshot.clear()
    wm.tick_city_consumption(1.0)
    city.rotate_treasury_window()
    # The FACT of the income in the cards is what the market has really brought. It must
    # agree with the "Population consumption" block of the treasury tooltip: it is the same
    # fact from which the row "Treasury: N [+X≈]" in the top bar is also taken.
    # Regression: the row "Income" showed the PLAN (demand × price), because of which
    # "Fruits" gave 2730 coins/sec with ten units in storage, and the figure
    # in the card did not agree with the treasury.
    var actual_map: Dictionary = wm.get_actual_market_income_map()
    var treasury_actual: Dictionary = wm.get_actual_treasury_income_map()
    # The key of the block in the map is the CONSTANT CityData.POPULATION_INCOME_TYPE (English),
    # and the render translates it into the label. Searching by the Russian name means never
    # finding the key: the check passed only when both sums happened to be zero, and fell
    # as soon as the market brought something.
    var actual_consumption: Dictionary = treasury_actual.get(
            city.POPULATION_INCOME_TYPE, {})
    var total_card_actual := 0.0
    var total_treasury_actual := 0.0
    for dkey in actual_map:
        total_card_actual += float(actual_map[dkey].get("coins_per_sec", 0.0))
    for source_name in actual_consumption:
        for pid in actual_consumption[source_name]:
            total_treasury_actual += float(actual_consumption[source_name][pid].get("coins_per_sec", 0.0))
    check(absf(total_card_actual - total_treasury_actual) < 0.01,
        "the sum of the fact of the income of the cards (%.2f) must match the fact of the treasury tooltip (%.2f)"
            % [total_card_actual, total_treasury_actual], state)
    # The breakdown of the fact by buyers must be present in the cards that have a
    # fact, and no one may have a negative speed.
    var actual_group_key := ""
    for dkey in actual_map:
        var arow: Dictionary = actual_map[dkey]
        check(float(arow.get("coins_per_sec", 0.0)) >= 0.0,
            "the fact of the income cannot be negative", state)
        if str(dkey).begins_with("@") and not (arow.get("by_source", {}) as Dictionary).is_empty():
            actual_group_key = str(dkey)
    check(not actual_group_key.is_empty(),
        "the fact of a group resource must come under the key @group with a breakdown by buyers", state)

    # ---- 8. The window of the consumption fact ----
    # The tick counter lives one tick, and the card needs a fact that survives the
    # display interval from the settings (1..5 sec).
    check(city.market_consumption_rates.size() > 0,
        "the market fact must be filled after the write-off", state)
    city.reset_counters()
    check(city.market_consumption_rates.is_empty(),
        "reset_counters must clear the tick fact of the market", state)
    check(not city.market_consumption_accum.is_empty(),
        "the window of the market fact must survive reset_counters", state)
    city.rotate_market_consumption_window()
    check(not city.market_consumption_snapshot.is_empty(),
        "after the rotation the snapshot of the window must not be empty", state)
    check(city.market_consumption_accum.is_empty(),
        "the rotation must zero the accumulator of the window", state)
    var per_sec_window: Dictionary = city.get_market_consumption_per_sec()
    check(not per_sec_window.is_empty(),
        "the window must give the fact in units/sec for the cards", state)
    var first_window_pid: String = str(per_sec_window.keys()[0])
    var expected_window: float = float(city.market_consumption_snapshot[first_window_pid]) \
        / city.resource_display_interval
    check(absf(float(per_sec_window[first_window_pid]) - expected_window) < 0.01,
        "the fact in units/sec must be the sum of the window divided by the display interval", state)

    # ---- 7. Saving the settings ----
    city.set_market_consumption_enabled(all_key, false)
    city.set_consumption_priority(all_key, "worst")
    var market_before: Dictionary = city.market_consumption_enabled.duplicate()
    var priority_before: Dictionary = city.consumption_priority.duplicate()
    # An old save without the market fields — everything must be allowed.
    save_manager.saved_data = {"city_food_pool": {}}
    save_manager.apply_loaded_data()
    check(city.is_market_consumption_enabled(all_key),
        "in an old save without the market fields the consumption must be allowed", state)
    # Restoration of the saved values.
    save_manager.saved_data = {
        "market_consumption_enabled": market_before,
        "consumption_priority": priority_before,
    }
    save_manager.apply_loaded_data()
    check(not city.is_market_consumption_enabled(all_key),
        "the prohibition setting must survive saving", state)
    check(city.get_consumption_priority(all_key) == "worst",
        "the priority must survive saving", state)
    city.market_consumption_enabled.clear()
    city.consumption_priority.clear()

    # ---- 8. The live scene CityUI ----
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    var city_ui = main_map.get_node_or_null("CityUI")
    check(city_ui != null, "CityUI not found in MainMap", state)
    if city_ui != null:
        # The columns of the "Trade" tab — from the scene, both in place.
        var internal_panel = city_ui.get_node_or_null("ContentPanel/TradePanel/Split/InternalPanel")
        var external_panel = city_ui.get_node_or_null("ContentPanel/TradePanel/Split/ExternalPanel")
        check(internal_panel != null,
            "the scene has no left column \"Domestic trade\"", state)
        check(external_panel != null,
            "the scene has no right column \"Foreign trade\"", state)
        if external_panel != null:
            var ext_title: Label = external_panel.get_node_or_null("TitleLabel")
            # The title of the column. The engine does NOT translate the text set directly in
            # the scene (checked with a probe: the Label stays "Foreign trade" in any
            # language), therefore we compare with the source string of the scene and with its
            # translation — demanding exactly the Russian text means forbidding the
            # game to work in English.
            var ext_source := "Foreign trade"
            check(ext_title != null and ext_title.text in [ext_source, tr(ext_source)],
                "the foreign trade must have a title: %s"
                        % (ext_title.text if ext_title != null else "no node"), state)
            _check_external_trade(city_ui, main_map, state)
        # We open the tab and look at the cards.
        city_ui.refresh()
        city_ui._switch_tab("trade")
        await process_frame
        var list = city_ui.get_node_or_null(
            "ContentPanel/TradePanel/Split/InternalPanel/InternalScroll/InternalList")
        check(list != null, "there is no list of the cards of the internal trade", state)
        # The available cards lie first, but with an empty storage there may be none at all —
        # then the first child of the list is the collapse toggle. We look for the card explicitly.
        var card: Node = null
        if list != null:
            for child in list.get_children():
                if child is PanelContainer:
                    card = child
                    break
        if card != null:
            # The toggle is ONE: the variant with two buttons (a rectangle +
            # a CheckBox) has been removed, and only the CheckBox remains in the card.
            check(card.get_node_or_null("Layout/Header/TradeToggleRect") == null,
                "the card must not have a rectangle button", state)
            check(card.get_node_or_null("Layout/Header/TradeCheckBox") != null,
                "the card has no checkbox", state)
            check(card.get_node_or_null("Layout/Header/PriorityButton") != null,
                "the card has no priority button", state)
            check(card.get_node_or_null("Layout/IncomeRow/IncomeValue") != null,
                "the card has no income row", state)
        if list != null and card != null:
            var tab = city_ui.trade_tab
            if tab != null and not tab.cards.is_empty():
                var key: String = str(tab.cards.keys()[0])
                var ctx: Dictionary = tab.cards[key]
                var box: CheckBox = ctx["checkbox"]
                var before: bool = city.is_market_consumption_enabled(key)
                check(box.button_pressed == before,
                    "the checkbox must show the state of the market", state)
                # A click on the checkbox switches the state of the market.
                box.button_pressed = not before
                box.toggled.emit(box.button_pressed)
                check(city.is_market_consumption_enabled(key) != before,
                    "a click on the checkbox must change the state of the market", state)
                # After the edit the checkbox shows the new state.
                tab.update_values()
                check(box.button_pressed == city.is_market_consumption_enabled(key),
                    "the checkbox must match the state of the market after the update", state)
                # A forbidden resource shows "—" in the expenses and the income.
                city.set_market_consumption_enabled(key, false)
                tab.update_values()
                var consumption: Label = ctx["consumption"]
                var income: RichTextLabel = ctx["income"]
                check(consumption.text == "—" and income.text == "—",
                    "a forbidden resource must show \"—\" in the expenses and the income, got \"%s\" / \"%s\""
                        % [consumption.text, income.text], state)
                city.set_market_consumption_enabled(key, true)
                tab.update_values()
                # The priority button cycles the setting.
                var priority_was: String = city.get_consumption_priority(key)
                tab._on_priority_pressed(key)
                check(city.get_consumption_priority(key) != priority_was,
                    "the priority button must change the consumption priority", state)
                # The nodes with tooltips MUST catch the mouse. A Label by default has
                # mouse_filter = IGNORE: the hover does not reach the node, and the standard
                # tooltip is shown NEVER. In this way half of the hints of the
                # card were lost: the price, the buyers, the expenses and the income.
                for node_key in ["price", "consumers", "consumption", "income"]:
                    var tip_node: Control = ctx[node_key]
                    check(tip_node.mouse_filter != Control.MOUSE_FILTER_IGNORE,
                        "the node \"%s\" must catch the mouse (mouse_filter != IGNORE), otherwise the tooltip will not show"
                        % node_key, state)
                # The tooltips are filled on the update of the card and survive it:
                # assigning tooltip_text removes the shown window, therefore
                # the unchanged text is not reassigned.
                tab.update_values()
                var consumers_tip: String = (ctx["consumers"] as Label).tooltip_text
                tab.update_values()
                tab.update_values()
                check((ctx["consumers"] as Label).tooltip_text == consumers_tip,
                    "the buyers tooltip must survive the update of the values", state)
                check(consumers_tip.contains(":"),
                    "the buyers tooltip must list the buyers, got \"%s\""
                        % consumers_tip, state)
                check((ctx["price"] as RichTextLabel).tooltip_text.contains("Price"),
                    "the price tooltip must explain the price calculation, got \"%s\""
                    % (ctx["price"] as RichTextLabel).tooltip_text, state)
                check((ctx["consumption"] as Label).tooltip_text.contains("Expenses"),
                    "the expenses tooltip must list the buyers' norms, got \"%s\""
                    % (ctx["consumption"] as Label).tooltip_text, state)
                check((ctx["income"] as RichTextLabel).tooltip_text.contains("Income"),
                    "the income tooltip must break down the sum, got \"%s\""
                    % (ctx["income"] as RichTextLabel).tooltip_text, state)
                # The MAIN regression: changing the VALUES must not recreate
                # the cards. Previously refresh() glued the composition label from
                # the sorted keys, and update_values() compared it with the
                # label in the order of insertion of the dictionary — the labels never
                # matched, and the whole list was rebuilt every tick. Hence there were
                # both the flickering of the numbers and the disappearing tooltips.
                var list2 = city_ui.get_node_or_null(
                    "ContentPanel/TradePanel/Split/InternalPanel/InternalScroll/InternalList")
                if list2 != null and list2.get_child_count() > 0:
                    # The regression on the reuse of the cards is checked by adding
                    # a supply to an ALREADY available resource: its availability does not change,
                    # therefore the composition of the column must not be rebuilt. Adding a supply
                    # to an unavailable resource is not allowed — it would become available and the card would legitimately
                    # move from the collapse into the working list (this is checked separately below),
                    # and then the regression about the reuse would stop checking anything.
                    # First we bring the target resources into the available ones (the supply is already there),
                    # then we measure the identity of the nodes.
                    for m in all_members:
                        city.add_to_storage(str(m), 1, "common")
                    tab.update_values()
                    await process_frame
                    var ids_before: Array = []
                    for node in list2.get_children():
                        ids_before.append(node.get_instance_id())
                    # We change the data so that the values of the cards update, but the availability
                    # of none of the cards switches.
                    for m in all_members:
                        city.add_to_storage(str(m), 1, "common")
                    tab.update_values()
                    tab.update_values()
                    var ids_after: Array = []
                    for node in list2.get_children():
                        ids_after.append(node.get_instance_id())
                    check(ids_before == ids_after,
                        "the cards must be reused when the values change, and not recreated", state)
                    check(tab._signature_of(tab._collect_data()) == tab._signature,
                        "the composition signature must match the actual set of the cards", state)
                    # The "phantom income" regression. The storage holds 1 unit of perfect
                    # quality, while the plan (the whole demand of the city × the price of the best quality) is
                    # many times more than what the market is able to earn. Previously the row
                    # "Income" showed exactly the plan — 2730 coins/sec, which were not
                    # in the treasury and could not be.
                    if tab.cards.has(all_key):
                        for m in all_members:
                            city.city_storage.erase(str(m))
                            city.city_quality_detail.erase(str(m))
                        city.add_to_storage(str(all_members[0]), 1, "perfect")
                        city.market_consumption_accum.clear()
                        city.market_consumption_snapshot.clear()
                        city.treasury_income_accum.clear()
                        city.treasury_income_product_accum.clear()
                        city.treasury_income_snapshot.clear()
                        city.treasury_income_product_snapshot.clear()
                        # We read the plan BEFORE the write-off: the single unit goes to the cash desk,
                        # the storage empties, and the plan is honestly zeroed.
                        var plan_value := float(wm.get_population_income_map()
                            .get(all_key, {}).get("coins_per_sec", 0.0))
                        wm.tick_city_consumption(1.0)
                        city.rotate_treasury_window()
                        var fact_value := float(wm.get_actual_market_income_map()
                            .get(all_key, {}).get("coins_per_sec", 0.0))
                        check(plan_value > fact_value * 10.0,
                            "the scenario must reproduce the discrepancy: the plan (%.1f) must be many times greater than the fact (%.1f)"
                            % [plan_value, fact_value], state)
                        tab.update_values()
                        var ghost_income: RichTextLabel = tab.cards[all_key]["income"]
                        var expected_income := _money_rate(tab._format_rate(fact_value))
                        check(ghost_income.text == expected_income,
                            "the \"Income\" row must show the fact \"%s\", got \"%s\""
                            % [expected_income, ghost_income.text], state)

        # ---- 8b. The composition of a group card ----
        # The name of a group is a reference: the standard dashed underline of a group, and the
        # composition of the group on hover — the same mark and the same panel the recipes and the
        # costs of a building use. The group is brought into the storage first: only an obtainable
        # resource gets a card in the working list.
        city.city_storage.clear()
        city.city_quality_detail.clear()
        for m in all_members:
            city.add_to_storage(str(m), 1, "common")
        city_ui.trade_tab.refresh()
        _check_group_card(city_ui, gdata, all_key, all_members, state)

    # ---- 9. The unavailable resources are hidden under a collapsible list ----
    # The city can obtain a resource only if it is extracted/produced or already
    # lies in storage. The remaining cards must not clutter the working column:
    # they move under the "Unavailable goods" toggle.
    var wm2 = load("res://scripts/worker_manager.gd").new()
    city.total_population = 3
    city.city_storage.clear()
    city.city_quality_detail.clear()
    # A resource without a supply and without production is unavailable.
    var bare_row := {"members": ["__no_such_product__"]}
    check(wm2.is_resource_obtainable(bare_row) == false,
        "a resource without a supply and without production must be unavailable", state)
    # A resource with a supply is available.
    city.add_to_storage("pottery", 5, "common")
    check(wm2.is_resource_obtainable({"members": ["pottery"]}) == true,
        "a resource with a storage must be available", state)
    # A group is available if at least one member is available.
    check(wm2.is_resource_obtainable({"members": ["__no_such_product__", "pottery"]}) == true,
        "a group is available when at least one member is available", state)
    check(wm2.is_resource_obtainable({"members": ["__a__", "__b__"]}) == false,
        "a group of unavailable members is unavailable", state)
    # The market map carries an available field for every row.
    var live_map: Dictionary = wm2.get_population_consumption_map()
    var all_have_flag := not live_map.is_empty()
    for dkey in live_map:
        if not live_map[dkey].has("available"):
            all_have_flag = false
            break
    check(all_have_flag, "every row of the market map must carry an available field", state)
    wm2.free()

    var main_map3 = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map3)
    await process_frame
    await process_frame
    var city_ui3 = main_map3.get_node_or_null("CityUI")
    if city_ui3 != null:
        city_ui3.refresh()
        city_ui3._switch_tab("trade")
        await process_frame
        var tab3 = city_ui3.trade_tab
        var ilist = city_ui3.get_node_or_null(
            "ContentPanel/TradePanel/Split/InternalPanel/InternalScroll/InternalList")
        check(ilist != null, "there is no list of the cards of the internal trade", state)
        if ilist != null and tab3 != null:
            # We empty the storage: everything the city does not produce will become unavailable.
            city.city_storage.clear()
            city.city_quality_detail.clear()
            tab3.refresh()
            check(tab3.unavailable_header != null,
                "when unavailable resources are present there must be a collapse toggle", state)
            check(tab3.unavailable_list != null,
                "when unavailable resources are present there must be a collapse container", state)
            if tab3.unavailable_header != null and tab3.unavailable_list != null:
                # Collapsed by default: the cards of the unavailable are not visible.
                check(not tab3.unavailable_open,
                    "by default the collapse of the unavailable must be closed", state)
                check(not tab3.unavailable_list.visible,
                    "by default the container of the unavailable must be hidden", state)
                check(tab3.unavailable_list.get_child_count() > 0,
                    "under the collapse there must lie the cards of the unavailable resources", state)
                # In the working list there must be no unavailable cards.
                var working_cards := 0
                for child in ilist.get_children():
                    if child is PanelContainer:
                        working_cards += 1
                check(working_cards == tab3.cards.size() - tab3.unavailable_list.get_child_count(),
                    "the working list must contain only the available cards", state)
                # The toggle opens and hides the container.
                tab3.unavailable_header.button_pressed = true
                tab3.unavailable_header.toggled.emit(true)
                check(tab3.unavailable_list.visible,
                    "the toggle must open the unavailable resources", state)
                tab3.unavailable_header.button_pressed = false
                tab3.unavailable_header.toggled.emit(false)
                check(not tab3.unavailable_list.visible,
                    "a repeated click must hide the unavailable resources", state)
                # The open state survives the rebuild of the list.
                tab3.unavailable_header.button_pressed = true
                tab3.unavailable_header.toggled.emit(true)
                tab3.refresh()
                check(tab3.unavailable_open and tab3.unavailable_list.visible,
                    "the open state must survive the rebuild of the list", state)
            # A resource that has gained a supply moves from the collapse into the working list.
            var hidden_key := ""
            if tab3.unavailable_list != null and tab3.unavailable_list.get_child_count() > 0:
                for dkey in tab3.cards:
                    if tab3.cards[dkey]["card"].get_parent() == tab3.unavailable_list:
                        hidden_key = str(dkey)
                        break
            if hidden_key != "":
                var hidden_members: Array = tab3._collect_data().get(hidden_key, {}).get("members", [])
                if not hidden_members.is_empty():
                    city.add_to_storage(str(hidden_members[0]), 10, "common")
                    tab3.update_values()
                    var now_row: Dictionary = tab3._collect_data().get(hidden_key, {})
                    check(bool(now_row.get("available", false)),
                        "a resource that has gained a supply must become available", state)
            # The width of the column must not "breathe" when a vertical scrollbar appears.
            # A ScrollContainer by default (SCROLL_MODE_AUTO) gives the content the width
            # minus the scrollbar, therefore when the collapse opens the cards become narrower,
            # and when it closes — wider again. The mode SHOW_ALWAYS reserves space for the
            # scrollbar permanently, and the width of the card does not depend on the overflow.
            var scroll = city_ui3.get_node_or_null(
                "ContentPanel/TradePanel/Split/InternalPanel/InternalScroll")
            check(scroll != null and scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_SHOW_ALWAYS,
                "the list must have a permanently reserved vertical scrollbar (SHOW_ALWAYS)", state)
            if scroll != null and ilist != null and tab3 != null and tab3.cards.size() > 0:
                var first_card = tab3.cards[tab3.cards.keys()[0]]["card"]
                # A tall area — the list fits, the scrollbar is not needed.
                scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
                scroll.custom_minimum_size = Vector2(0, 4000)
                for _i in range(6):
                    await process_frame
                var width_tall: float = first_card.size.x
                # A short area — the list overflows, the scrollbar is needed.
                scroll.custom_minimum_size = Vector2(0, 150)
                scroll.size.y = 150
                for _i in range(6):
                    await process_frame
                var width_short: float = first_card.size.x
                check(is_equal_approx(width_tall, width_short),
                    "the width of the cards must not change from the appearance of the scrollbar: %.1f → %.1f"
                        % [width_tall, width_short], state)
    main_map3.queue_free()

    # Cleanup of the state so that the test does not affect the following runs.
    city.total_population = 1
    city.city_storage.clear()
    city.city_quality_detail.clear()
    city.market_consumption_enabled.clear()
    city.consumption_priority.clear()
    city.market_consumption_rates.clear()
    wm.free()
    main_map.queue_free()

    if state["failed"]:
        print("TRADE TAB TEST FAILED")
        quit(1)
    else:
        print("TRADE TAB TEST OK")
        quit(0)

# Checks that the priority really determines WHICH quality is eaten
# first: we put 10 ordinary + 10 perfect and write off 10.
func _check_priority_order(city, pid: String, priority: String, expected_first: String, state: Dictionary) -> void:
    city.city_storage.clear()
    city.city_quality_detail.clear()
    city.set_consumption_priority(pid, priority)
    city.add_to_storage(pid, 10, "common")
    city.add_to_storage(pid, 10, "perfect")
    city.remove_from_storage(pid, 10, city.get_consumption_priority(pid))
    var detail: Dictionary = city.get_quality_breakdown(pid)
    check(int(detail.get(expected_first, 0)) == 0,
        "the priority \"%s\" must have eaten the quality \"%s\" first" % [priority, expected_first], state)
    city.consumption_priority.erase(pid)

# The sum of the supply over the members of the group.
func _total_storage(city, members: Array) -> int:
    var total := 0
    for m in members:
        total += city.get_storage_amount(str(m))
    return total

# display_key of the resource of the pseudo-profession "all" (we take it from the data, and do not hardcode it).
func _all_key(gdata) -> String:
    for e in gdata.get_profession_consumption("all"):
        var key := str(e.get("display_key", ""))
        if not key.is_empty():
            return key
    return ""

# The members of the resource group of the pseudo-profession "all".
func _all_members(gdata, key: String) -> Array:
    if key.begins_with("@"):
        return gdata.product_groups.get(key.trim_prefix("@"), [])
    return [key] if not key.is_empty() else []

# The right column of the tab "Trade" (the foreign trade): the pair of the section buttons, the
# sorting of both sections and the list of the towns discovered by the player.
func _check_external_trade(city_ui, main_map, state: Dictionary) -> void:
    var panel = city_ui.get_node_or_null("ContentPanel/TradePanel/Split/ExternalPanel")
    check(panel != null, "the scene has no right column \"Foreign trade\"", state)
    if panel == null:
        return
    var tab = city_ui.external_trade_tab
    check(tab != null, "the right column of \"Trade\" has no script", state)
    if tab == null:
        return
    # The tooltips and the highlighting of the buttons are assembled in the code, and the column
    # fills them on a refresh (the same path as on opening the tab).
    city_ui.refresh()

    # ---- The pair of the section buttons ----
    var deals_button: Button = panel.get_node_or_null("SectionsBar/DealsButton")
    var partners_button: Button = panel.get_node_or_null("SectionsBar/PartnersButton")
    check(deals_button != null and partners_button != null,
        "the foreign trade must have two section buttons", state)
    if deals_button == null or partners_button == null:
        return
    # The tooltips are compared with the source string of the scene and with its translation: the
    # engine does not translate the text set in the scene itself (see the check of the title).
    check(deals_button.tooltip_text in ["Trade deals", tr("Trade deals")],
        "the button of the deals must carry a tooltip, got \"%s\"" % deals_button.tooltip_text, state)
    check(partners_button.tooltip_text in ["Trade partners", tr("Trade partners")],
        "the button of the partners must carry a tooltip, got \"%s\"" % partners_button.tooltip_text, state)
    check(deals_button.icon != null and partners_button.icon != null,
        "both section buttons must carry an icon", state)
    check(deals_button.custom_minimum_size.x >= 28.0 and deals_button.custom_minimum_size.y >= 28.0,
        "the section buttons must be small square buttons", state)

    var deals_section = panel.get_node_or_null("DealsSection")
    var partners_section = panel.get_node_or_null("PartnersSection")
    check(deals_section != null and partners_section != null,
        "the foreign trade must have both sections", state)
    if deals_section == null or partners_section == null:
        return
    # The sections are switched by the buttons and are never shown together.
    check(deals_section.visible and not partners_section.visible,
        "the section \"Trade deals\" must be open by default", state)
    partners_button.pressed.emit()
    check(partners_section.visible and not deals_section.visible,
        "the button must switch to the section \"Trade partners\"", state)
    deals_button.pressed.emit()
    check(deals_section.visible and not partners_section.visible,
        "the button must switch back to the section \"Trade deals\"", state)

    # The width of the rows must not "breathe" when the vertical scrollbar appears — the same
    # reason as at the column of the domestic trade (see the SHOW_ALWAYS check below).
    for scroll_name in ["DealsSection/DealsScroll", "PartnersSection/PartnersScroll"]:
        var scroll = panel.get_node_or_null(scroll_name)
        check(scroll != null and scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_SHOW_ALWAYS,
            "the list \"%s\" must have a permanently reserved vertical scrollbar" % scroll_name, state)

    # ---- The sorting of the deals ----
    # The sort buttons of the section: one per key, with an icon and a tooltip.
    var deals_sort_bar = panel.get_node_or_null("DealsSection/SortBar")
    check(deals_sort_bar != null and deals_sort_bar.get_child_count() == 3,
        "the section \"Trade deals\" must have three sort buttons", state)
    var partners_sort_bar = panel.get_node_or_null("PartnersSection/SortBar")
    check(partners_sort_bar != null and partners_sort_bar.get_child_count() == 2,
        "the section \"Trade partners\" must have two sort buttons", state)
    for bar in [deals_sort_bar, partners_sort_bar]:
        if bar == null:
            continue
        for button in bar.get_children():
            check(button is Button and button.icon != null and not button.tooltip_text.is_empty(),
                "every sort button must carry an icon and a tooltip: \"%s\" has icon=%s, tooltip=\"%s\""
                    % [button.name, str(button.icon != null), button.tooltip_text], state)
    # The state of the sorting: a click on another key switches the section to it in the
    # ascending order, a repeated click on the same key reverses the order.
    tab.partners_sort_key = tab.SORT_NAME
    tab.partners_descending = false
    tab._on_partners_sort_pressed(tab.SORT_DISTANCE)
    check(tab.partners_sort_key == tab.SORT_DISTANCE and not tab.partners_descending,
        "a click on another key must switch the sorting to it", state)
    tab._on_partners_sort_pressed(tab.SORT_DISTANCE)
    check(tab.partners_descending, "a repeated click must reverse the order", state)
    tab.partners_sort_key = tab.SORT_NAME
    tab.partners_descending = false

    # The rows of the section are the standing contracts with the towns (see
    # external_trade_tab._collect_deals): the goods and the volume, the town, the type,
    # the payment per second and the delivery time. The shape of a deal is the one
    # town_trade_manager.get_contracts produces.
    var deals: Array = [
        {"town_id": "town_1", "town_name": "Roma", "product_id": "beer", "name": "Beer",
            "icon": "", "type": "buy", "price": 30, "amount": 10, "cost": 300,
            "delivery_time": 6.4, "row": 4, "col": 4},
        {"town_id": "town_2", "town_name": "Ostia", "product_id": "ale", "name": "Ale",
            "icon": "", "type": "buy", "price": 10, "amount": 10, "cost": 100,
            "delivery_time": 6.4, "row": 2, "col": 3},
        {"town_id": "town_3", "town_name": "Capua", "product_id": "mead", "name": "Mead",
            "icon": "", "type": "sell", "price": 10, "amount": 10, "cost": 100,
            "delivery_time": 6.4, "row": 6, "col": 7},
        {"town_id": "town_4", "town_name": "Neapolis", "product_id": "wine", "name": "Wine",
            "icon": "", "type": "buy", "price": 20, "amount": 10, "cost": 200,
            "delivery_time": 6.4, "row": 8, "col": 9},
    ]
    # The expected orders are built from the data of the rows themselves, and not from the
    # constants of the test: the keys of the sorting are exactly the fields of a deal.
    tab.deals_sort_key = tab.SORT_NAME
    tab.deals_descending = false
    check(_deal_names(tab._sorted_deals(deals)) == ["Ale", "Beer", "Mead", "Wine"],
        "the deals must be sorted by the name of the goods", state)
    tab.deals_descending = true
    check(_deal_names(tab._sorted_deals(deals)) == ["Wine", "Mead", "Beer", "Ale"],
        "the reversed sorting must turn the list around", state)
    # The price: the two goods of the same price keep the alphabetical order of the names — the
    # tie-breaker, without which the rows would swap places between the refreshes.
    tab.deals_sort_key = tab.SORT_PRICE
    tab.deals_descending = false
    check(_deal_names(tab._sorted_deals(deals)) == ["Ale", "Mead", "Wine", "Beer"],
        "the deals must be sorted by the price, and the equal prices — by the name", state)
    tab.deals_descending = true
    check(_deal_names(tab._sorted_deals(deals)) == ["Beer", "Wine", "Ale", "Mead"],
        "the reversed sorting by the price must start with the most expensive", state)
    # The type: the purchases first, and then the sales. The order of the types does not depend on
    # their names — the names are translated.
    tab.deals_sort_key = tab.SORT_TYPE
    tab.deals_descending = false
    check(_deal_names(tab._sorted_deals(deals)) == ["Ale", "Beer", "Wine", "Mead"],
        "the purchases must come before the sales", state)
    tab.deals_descending = true
    check(_deal_names(tab._sorted_deals(deals)) == ["Mead", "Ale", "Beer", "Wine"],
        "the reversed sorting by the type must start with the sales", state)

    # The rows of the section: the empty source gives the empty state, the deals give one row each.
    tab.deals_sort_key = tab.SORT_NAME
    tab.deals_descending = false
    tab._deals_signature = ""
    tab._refresh_deals()
    var deals_list = panel.get_node_or_null("DealsSection/DealsScroll/DealsList")
    check(deals_list != null, "the section \"Trade deals\" has no list", state)
    if deals_list != null:
        check(deals_list.get_child_count() == 1 and deals_list.get_child(0) is Label,
            "with no deals the section must show the empty state", state)
        tab._fill_deals(tab._sorted_deals(deals))
        check(deals_list.get_child_count() == deals.size(),
            "every deal must get a row: %d of %d" % [deals_list.get_child_count(), deals.size()], state)
        var first_row: Node = deals_list.get_child(0)
        var texts := _row_texts(first_row)
        check(texts.has("Ale") and texts.has("Ostia")
                and texts.has(tab._deal_type_name("buy")) and texts.has("\u00d710")
                and texts.has(tab.tr("Cost: %s") % _money_rate("100"))
                and texts.has("Delivery: 6.40 sec"),
            "the row of a deal must show the goods, the volume, the town, the type, the "
                + "payment and the delivery time, got %s" % str(texts), state)

        # The edit action of a deal row: a town carries one contract per good (see
        # town_trade_manager), so a deal can be edited from here — the button unfolds an
        # INLINE editor right under the row (the amount and the payment at the frozen price,
        # an "Update" action and a "Close the contract" action).
        var edit_button: Button = first_row.find_child("DealEditButton", true, false)
        check(edit_button != null, "the row of a deal must offer an edit action", state)
        if edit_button != null:
            check(edit_button.icon != null and not edit_button.tooltip_text.is_empty(),
                "the edit action must carry an icon and a tooltip: icon=%s, tooltip=\"%s\""
                    % [str(edit_button.icon != null), edit_button.tooltip_text], state)
            var edited_deal: Dictionary = tab._sorted_deals(deals)[0]
            # The column reads its deals through the map (external_trade_tab._collect_deals),
            # so the toggle is driven over a stub that hands the synthetic list over — the
            # very path the live column takes.
            var deal_map := DealMap.new()
            deal_map.deals = tab._sorted_deals(deals)
            var saved_map = tab.main_map
            tab.main_map = deal_map
            # The toggle: a press on the edit action of a deal unfolds the editor of THAT
            # deal, and a repeated press folds it back — the pair (town, good) is what tells
            # one deal from another.
            tab._editing_deal_key = ""
            tab._on_deal_panel_toggled(tab.KIND_CONTRACT,
                    str(edited_deal.get("town_id", "")), str(edited_deal.get("product_id", "")))
            check(tab._editing_deal_key == tab._deal_key(edited_deal),
                "the edit action must unfold the editor of its own deal (got \"%s\")"
                    % tab._editing_deal_key, state)

            # The editor itself, unfolded right under the row of the deal it edits.
            var editor: Node = deals_list.find_child("DealEditor", true, false)
            check(editor != null, "the unfolded editor must be a child of the list", state)
            if editor != null:
                var amount_field: LineEdit = editor.find_child("DealAmountEdit", true, false)
                check(amount_field != null and amount_field.text == str(edited_deal.get("amount", 0)),
                    "the editor must start from the amount of the contract (got \"%s\")"
                        % (amount_field.text if amount_field != null else "<no field>"), state)
                var total_label: RichTextLabel = editor.find_child("DealTotalLabel", true, false)
                var frozen_price: int = tab._deal_unit_price(edited_deal)
                check(total_label != null
                        and total_label.text == tab.tr("Cost: %s")
                            % _money_rate(str(int(edited_deal.get("amount", 0)) * frozen_price)),
                    "the editor must total at the frozen price of the deal (got \"%s\")"
                        % (total_label.text if total_label != null else "<no label>"), state)
                var update_button: Button = editor.find_child("DealUpdateButton", true, false)
                check(update_button != null and update_button.icon != null
                        and not update_button.tooltip_text.is_empty(),
                    "the editor must offer an update action with an icon and a tooltip", state)
                var close_contract_button: Button = editor.find_child("DealCloseButton", true, false)
                check(close_contract_button != null and close_contract_button.icon != null
                        and not close_contract_button.tooltip_text.is_empty(),
                    "the editor must offer to close the contract, with an icon and a tooltip", state)
                # The "+" button moves the amount and the total follows it.
                if amount_field != null:
                    var plus_button: Button = editor.find_child("DealPlusButton", true, false)
                    check(plus_button != null, "the editor must offer a \"+\" button", state)
                    if plus_button != null:
                        plus_button.pressed.emit()
                        var bumped: int = int(edited_deal.get("amount", 0)) + int(tab.STEP_UNITS)
                        check(amount_field.text == str(bumped),
                            "a click on \"+\" must step the amount up (got \"%s\")"
                                % amount_field.text, state)
                        check(total_label != null
                                and total_label.text == tab.tr("Cost: %s")
                                    % _money_rate(str(bumped * frozen_price)),
                            "the total must follow the amount (got \"%s\")"
                                % (total_label.text if total_label != null else "<no label>"), state)
            # A repeated press folds the editor back.
            tab._on_deal_panel_toggled(tab.KIND_CONTRACT,
                    str(edited_deal.get("town_id", "")), str(edited_deal.get("product_id", "")))
            check(tab._editing_deal_key.is_empty()
                    and deals_list.find_child("DealEditor", true, false) == null,
                "a repeated press must fold the editor back", state)
            tab.main_map = saved_map
            deal_map.free()
        # A deal without a town (a hand-made record) must not pretend to be editable.
        var orphan: Node = tab._build_deal_row({"product_id": "beer", "name": "Beer", "type": "buy"})
        check(orphan.find_child("DealEditButton", true, false) == null,
            "a deal without a town must not carry the edit action", state)
        orphan.free()
        # The wiring of the live map: the manager announces every change of the contracts and
        # the trade panel of the town window follows the contract of the good it shows
        # (main_map._ready). This is what turns a contract that has just been signed into an
        # editable one on the spot — without it the close button appeared only after the
        # panel had been closed and reopened.
        check(main_map.town_trade_manager.contracts_changed.is_connected(
                Callable(main_map.town_ui, "on_contracts_changed")),
            "the change of the contracts must reach the trade panel of the town window", state)
        # The delivery manager feeds the ledger of the one-time purchases: the shipments of
        # the queue are what tell the ledger how much of a purchase has left the town and is
        # therefore no longer cancellable (see town_trade_manager._on_cargo_shipped).
        check(main_map.delivery_manager.cargo_shipped.is_connected(
                Callable(main_map.town_trade_manager, "_on_cargo_shipped")),
            "the shipments of the delivery manager must feed the ledger of the trade manager", state)
        # The column returns to its own state: the synthetic rows were shown only for the check.
        tab._deals_signature = ""
        tab._refresh_deals()
        check(deals_list.get_child_count() == 1 and deals_list.get_child(0) is Label,
            "the section must come back to the empty state", state)

    # ---- The delivery row and its cancellation ----
    var delivery_deals: Array = [
        {"town_id": "town_1", "town_name": "Roma", "product_id": "beer", "name": "Beer",
            "icon": "", "type": "buy", "price": 30, "amount": 40, "cost": 1200,
            "ordered": 100, "delivery_time": 6.4, "row": 4, "col": 4,
            "kind": tab.KIND_DELIVERY},
    ]
    var delivery_map := DealMap.new()
    delivery_map.deliveries = delivery_deals
    var saved_map2 = tab.main_map
    tab.main_map = delivery_map
    tab._deals_signature = ""
    tab._fill_deals(tab._sorted_deals(delivery_deals))
    var delivery_list = panel.get_node_or_null("DealsSection/DealsScroll/DealsList")
    check(delivery_list != null, "the delivery list must exist", state)
    if delivery_list != null:
        check(delivery_list.get_child_count() == 1,
            "one delivery must give one row, got %d" % delivery_list.get_child_count(), state)
        var d_row: Node = delivery_list.get_child(0)
        var d_texts := _row_texts(d_row)
        check(d_texts.has("Beer") and d_texts.has("Roma")
                and d_texts.has(tab._deal_type_name("buy"))
                and d_texts.has("40 of 100 on the way")
                and d_texts.has("Delivery: 6.40 sec"),
            "the delivery row must show the goods, the town, the type, the amount still on the way and the delivery time, got %s"
                % str(d_texts), state)
        var cancel_button: Button = d_row.find_child("DeliveryCancelButton", true, false)
        check(cancel_button != null, "the delivery row must offer a cancel action", state)
        if cancel_button != null:
            # The toggle: a press on the cancel action of a delivery unfolds the confirmation
            # of THAT delivery, and a repeated press folds it back.
            tab._editing_deal_key = ""
            tab._on_deal_panel_toggled(tab.KIND_DELIVERY,
                    str(delivery_deals[0].get("town_id", "")), str(delivery_deals[0].get("product_id", "")))
            check(tab._editing_deal_key == tab._deal_key(delivery_deals[0]),
                "the cancel action must unfold the confirmation of its own delivery", state)
            var confirm_panel: Node = delivery_list.find_child("DeliveryCancelPanel", true, false)
            check(confirm_panel != null, "the unfolded confirmation must be a child of the list", state)
            if confirm_panel != null:
                var warning: Label = confirm_panel.find_child("DeliveryCancelWarning", true, false)
                check(warning != null and warning.text.find("Cancel the deal") >= 0,
                    "the confirmation must ask whether to cancel the deal", state)
                var confirm_btn: Button = confirm_panel.find_child("DeliveryCancelConfirmButton", true, false)
                check(confirm_btn != null, "the confirmation must offer a confirm action", state)
                var dismiss_btn: Button = confirm_panel.find_child("DeliveryCancelDismissButton", true, false)
                check(dismiss_btn != null, "the confirmation must offer a dismiss action", state)
                # A dismiss folds the panel back.
                if dismiss_btn != null:
                    dismiss_btn.pressed.emit()
                    check(tab._editing_deal_key.is_empty()
                            and delivery_list.find_child("DeliveryCancelPanel", true, false) == null,
                        "a dismiss must fold the confirmation back", state)
            # A repeated press folds the confirmation back.
            tab._on_deal_panel_toggled(tab.KIND_DELIVERY,
                    str(delivery_deals[0].get("town_id", "")), str(delivery_deals[0].get("product_id", "")))
            check(tab._editing_deal_key == tab._deal_key(delivery_deals[0]),
                "the second toggle must unfold the confirmation again", state)
            tab._on_deal_panel_toggled(tab.KIND_DELIVERY,
                    str(delivery_deals[0].get("town_id", "")), str(delivery_deals[0].get("product_id", "")))
            check(tab._editing_deal_key.is_empty(),
                "a repeated press must fold the confirmation back", state)
        # A delivery without a town must not pretend to be cancellable.
        var orphan2: Node = tab._build_deal_row({"product_id": "beer", "name": "Beer",
                "type": "buy", "kind": tab.KIND_DELIVERY})
        check(orphan2.find_child("DeliveryCancelButton", true, false) == null,
            "a delivery without a town must not carry the cancel action", state)
        orphan2.free()
    tab.main_map = saved_map2
    delivery_map.free()

    # ---- The list of the towns discovered by the player ----
    var partners_list = panel.get_node_or_null("PartnersSection/PartnersScroll/PartnersList")
    check(partners_list != null, "the section \"Trade partners\" has no list", state)
    var towns: Array = main_map.town_manager.towns
    check(towns.size() >= 3, "the live map must have towns for the check", state)
    if partners_list == null or towns.size() < 3:
        return
    # On a fresh map the towns stand outside of the starting area, therefore none of them is
    # discovered yet — the list must be empty.
    for town in towns:
        main_map.tile_data[int(town["row"])][int(town["col"])]["is_explored"] = false
        main_map.tile_data[int(town["row"])][int(town["col"])]["in_influence"] = false
    tab._partners_signature = ""
    tab.refresh()
    check(_partner_row_names(partners_list).is_empty(),
        "an undiscovered town must not get into the list of the partners", state)
    check(partners_list.get_child_count() == 1 and partners_list.get_child(0) is Label,
        "with no discovered towns the section must show the empty state", state)
    # We open three towns: they must appear in the list, and only they.
    var opened: Array = []
    for i in range(3):
        var town = towns[i]
        main_map.tile_data[int(town["row"])][int(town["col"])]["is_explored"] = true
        opened.append(str(town.get("name", "")))
    tab._partners_signature = ""
    tab.refresh()
    var shown := _partner_row_names(partners_list)
    check(shown.size() == 3, "every discovered town must get a row: %s" % str(shown), state)
    var expected_names := opened.duplicate()
    expected_names.sort()
    check(shown == expected_names,
        "by default the towns must be sorted by the name: expected %s, got %s"
            % [str(expected_names), str(shown)], state)
    # The distance of a row is the distance from the city, and the sorting by it must really
    # reorder the list.
    var partners: Array = main_map.get_trade_partners()
    check(partners.size() == 3, "the map must give the discovered towns: %d" % partners.size(), state)
    var distance_by_name: Dictionary = {}
    for partner in partners:
        var expected_distance := HexUtils.hex_distance(main_map.city_row, main_map.city_col,
                int(partner["row"]), int(partner["col"]))
        check(int(partner["distance"]) == expected_distance,
            "the distance of the town \"%s\" must be the distance from the city" % partner["name"], state)
        distance_by_name[str(partner["name"])] = int(partner["distance"])
    tab.partners_sort_key = tab.SORT_DISTANCE
    tab.partners_descending = false
    tab._partners_signature = ""
    tab._refresh_partners()
    var by_distance := _partner_row_names(partners_list)
    check(by_distance.size() == 3 and distance_by_name[by_distance[0]] <= distance_by_name[by_distance[1]]
            and distance_by_name[by_distance[1]] <= distance_by_name[by_distance[2]],
        "the towns must be sorted by the distance: %s" % str(by_distance), state)
    tab.partners_descending = true
    tab._partners_signature = ""
    tab._refresh_partners()
    by_distance = _partner_row_names(partners_list)
    check(by_distance.size() == 3 and distance_by_name[by_distance[0]] >= distance_by_name[by_distance[2]],
        "the reversed sorting by the distance must start with the farthest town: %s" % str(by_distance), state)

    # The rows carry the button of the jump to the town and the marker of a missing road.
    var first_partner_row: Node = null
    for child in partners_list.get_children():
        if child is HBoxContainer:
            first_partner_row = child
            break
    check(first_partner_row != null, "a discovered town must get a row", state)
    if first_partner_row == null:
        return
    var goto_button: Button = null
    var road_marker: TextureRect = null
    for node in first_partner_row.get_children():
        if node is Button:
            goto_button = node
        elif node is TextureRect:
            road_marker = node
    check(goto_button != null, "every row of a partner must have the button of the jump to the town", state)
    if goto_button != null:
        check(goto_button.tooltip_text == tr("Go to the town"),
            "the button of the jump must carry a tooltip, got \"%s\"" % goto_button.tooltip_text, state)
    # The marker of the missing road: the trade with a town is gated by the road, and the row must
    # say it — but the town itself must stay in the list.
    var without_road := 0
    for partner in partners:
        if not bool(partner["trade_available"]):
            without_road += 1
    var rows_with_marker := 0
    for child in partners_list.get_children():
        if child is HBoxContainer and _has_road_marker(child):
            rows_with_marker += 1
    check(rows_with_marker == without_road,
        "the marker of the missing road must stand in exactly the rows without a road: %d of %d"
            % [rows_with_marker, without_road], state)

    # ---- The jump to a town ----
    # The centering itself: a hex of the Region must land in the middle of the screen. The scroll
    # of the map is limited (main_map.get_max_scroll — the same limit the edge scrolling and the
    # scouting obey), therefore a hex far outside of the Region cannot be centered; a town the
    # player has discovered is always inside the reachable area, and the jump brings it on screen.
    var middle_row := int((main_map.region_start_row + main_map.region_end_row) / 2)
    var middle_col := int((main_map.region_start_col + main_map.region_end_col) / 2)
    main_map.center_on_hex(middle_row, middle_col)
    var hex_center: Vector2 = HexUtils.hex_center(middle_row, middle_col, main_map.HEX_RADIUS) \
            + Vector2(main_map.offset_x, main_map.offset_y) + main_map.scroll_offset
    var screen_center: Vector2 = main_map.get_viewport_rect().size / 2.0
    check(hex_center.distance_to(screen_center) < 2.0,
        "the map must be centered on the hex: the hex is at %s, the center of the screen at %s"
            % [str(hex_center), str(screen_center)], state)
    # The button asks the map for the jump, and the map closes the city window and centers itself.
    var jump_requests: Array = []
    city_ui.town_focus_requested.connect(func(row, col): jump_requests.append([row, col]))
    # The target is the first row of the list — with the sorting by the distance in the descending
    # order it is the farthest town, so the jump has to move the map noticeably.
    var first_name: String = str(_partner_row_names(partners_list)[0])
    var target: Dictionary = {}
    for partner in partners:
        if str(partner["name"]) == first_name:
            target = partner
            break
    if goto_button != null and not target.is_empty():
        # The starting point of the check is the map centered on the city: from there the town is
        # not in the middle of the screen, and the jump must bring it closer to it.
        main_map.center_on_hex(main_map.city_row, main_map.city_col)
        var scroll_before: Vector2 = main_map.scroll_offset
        var town_before := _town_screen_pos(main_map, int(target["row"]), int(target["col"]))
        city_ui.show()
        goto_button.pressed.emit()
        check(jump_requests.size() == 1 and jump_requests[0] == [int(target["row"]), int(target["col"])],
            "the button must ask for the jump to its own town: %s" % str(jump_requests), state)
        check(not city_ui.visible, "the jump must close the interface of the city", state)
        # The jump lands the player on the town with its window already open: going to the town in
        # order to trade and having to find the hex again would defeat the button.
        check(main_map.town_ui.visible, "the jump must open the window of the town", state)
        check(str(main_map.town_ui._town.get("id", "")) == str(target.get("id", "")),
            "the window must show exactly the town of the pressed row", state)
        check(main_map.scroll_offset != scroll_before,
            "the jump must move the map: the scroll stayed at %s" % str(scroll_before), state)
        var town_after := _town_screen_pos(main_map, int(target["row"]), int(target["col"]))
        check((town_after - screen_center).length() <= (town_before - screen_center).length(),
            "the jump must bring the town closer to the middle of the screen: %s → %s (the center is %s)"
                % [str(town_before), str(town_after), str(screen_center)], state)
        # The window of the town is put away again so the rest of the checks run on a clean map.
        main_map.town_ui.hide()

    # The column comes back to its own state: the rows of the check must not stay in the list.
    tab.partners_sort_key = tab.SORT_NAME
    tab.partners_descending = false
    tab._partners_signature = ""
    tab.refresh()

# Where a hex lands on the screen with the current scroll of the map: the same arithmetic the
# renderer uses (world + offset + scroll).
func _town_screen_pos(main_map, row: int, col: int) -> Vector2:
    return HexUtils.hex_center(row, col, main_map.HEX_RADIUS) \
            + Vector2(main_map.offset_x, main_map.offset_y) + main_map.scroll_offset

# The names of the goods of the rows, in the order in which they are shown.
func _deal_names(deals: Array) -> Array:
    var names: Array = []
    for deal in deals:
        names.append(str(deal.get("name", "")))
    return names

# The names of the towns in the rows of the list of the partners, in the order in which they are shown.
func _partner_row_names(list: Node) -> Array:
    var names: Array = []
    if list == null:
        return names
    for child in list.get_children():
        if child is HBoxContainer:
            names.append(_first_label_text(child))
    return names

# Whether the row carries the marker of a missing road.
func _has_road_marker(row: Node) -> bool:
    for node in row.get_children():
        if node is TextureRect:
            return true
    return false

func _first_label_text(row: Node) -> String:
    for node in row.get_children():
        if node is Label:
            return node.text
    return ""

# The texts of all the labels of a row — what the player reads in it.
func _row_texts(row: Node) -> Array:
    var texts: Array = []
    for node in row.get_children():
        if node is Label:
            texts.append(node.text)
        elif node is RichTextLabel:
            # The readouts of coins are RichTextLabels (they carry the coin icon).
            texts.append((node as RichTextLabel).text)
    return texts

# The first Label with exactly this text in the subtree: the content of a tooltip is assembled
# from the labels of its rows.
func _find_label(node: Node, text: String) -> Label:
    if node == null:
        return null
    if node is Label and (node as Label).text == text:
        return node
    for child in node.get_children():
        var found := _find_label(child, text)
        if found != null:
            return found
    return null

# The name of a group card is a reference, not a plain label: it carries the standard dashed
# underline of a group and unfolds the composition on hover — the same mark and the same panel the
# recipes and the costs of a building use (ui_helpers.show_group_tooltip).
func _check_group_card(city_ui, gdata, group_key: String, members: Array, state: Dictionary) -> void:
    var tab = city_ui.trade_tab
    if tab == null or not tab.cards.has(group_key):
        check(false, "the group card must be built to check the composition tooltip", state)
        return
    var name_label: Label = tab.cards[group_key]["name"]
    var script_obj = name_label.get_script()
    check(script_obj != null \
            and str(script_obj.resource_path) == "res://scripts/underlined_label.gd",
        "the name of a group card must be the standard underlined label (got \"%s\")"
            % (str(script_obj.resource_path) if script_obj != null else "<no script>"), state)
    var group_name := str(gdata.get_product_group_name(group_key))
    check(not group_name.is_empty(), "the group under test must have a name", state)
    check(str(name_label.underline_text) == group_name,
        "the group name must carry the standard dashed underline (got \"%s\")"
            % str(name_label.underline_text), state)
    # PASS and not STOP: the title shows the tooltip on hover and does not intercept the clicks
    # of the card (the checkbox, the priority button).
    check(name_label.mouse_filter == Control.MOUSE_FILTER_PASS,
        "the name of a group card must let the clicks through (filter %d)"
            % name_label.mouse_filter, state)

    name_label.mouse_entered.emit()
    var helpers = city_ui.ui_helpers
    check(helpers != null and helpers.group_tooltip_panel.visible,
        "hovering the name of a group card must show the standard group tooltip", state)
    if helpers == null:
        return
    var listed := 0
    for m in members:
        var member_name := str(
                (gdata.products.get(str(m), {}) as Dictionary).get("name", str(m)))
        if _find_label(helpers.group_tooltip_content, member_name) != null:
            listed += 1
    check(listed == members.size(),
        "the group tooltip must list every member of the group (%d of %d)"
            % [listed, members.size()], state)
    # The update of the display epoch touches the tooltip of the quality only: the open composition
    # must not be taken down by it (otherwise the panel would flicker under the cursor).
    tab.refresh_open_tooltip()
    check(helpers.group_tooltip_panel.visible,
        "the open composition must not be closed by the refresh of the display epoch", state)
    name_label.mouse_exited.emit()
    check(not helpers.group_tooltip_panel.visible,
        "leaving the name of a group card must hide the group tooltip", state)

    # A single resource has nothing to unfold: the underline belongs to the group reference only.
    # It is checked on the same card — the row is fed as a single resource and then the card is
    # restored by the regular update, so no second card has to be built for the check.
    var single_row: Dictionary = tab._collect_data().get(group_key, {}).duplicate()
    single_row["is_group"] = false
    tab._update_card(tab.cards[group_key], single_row)
    check(str(name_label.underline_text) == "",
        "a single resource must not carry the group underline (got \"%s\")"
            % str(name_label.underline_text), state)
    tab.update_values()
    check(str(name_label.underline_text) == group_name,
        "the group underline must come back with the group row (got \"%s\")"
            % str(name_label.underline_text), state)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("OK: ", message)
    else:
        state["failed"] = true
        push_error("FALL: " + message)
