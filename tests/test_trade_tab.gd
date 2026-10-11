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
            # The foreign trade is a stub: apart from the title there is nothing.
            check(external_panel.get_child_count() == 1,
                "the foreign trade column must for now contain only the title", state)
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
                var income: Label = ctx["income"]
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
                check((ctx["price"] as Label).tooltip_text.contains("Price"),
                    "the price tooltip must explain the price calculation, got \"%s\""
                    % (ctx["price"] as Label).tooltip_text, state)
                check((ctx["consumption"] as Label).tooltip_text.contains("Expenses"),
                    "the expenses tooltip must list the buyers' norms, got \"%s\""
                    % (ctx["consumption"] as Label).tooltip_text, state)
                check((ctx["income"] as Label).tooltip_text.contains("Income"),
                    "the income tooltip must break down the sum, got \"%s\""
                    % (ctx["income"] as Label).tooltip_text, state)
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
                        var ghost_income: Label = tab.cards[all_key]["income"]
                        var expected_income := "%s/sec" % tab._format_rate(fact_value)
                        check(ghost_income.text == expected_income,
                            "the \"Income\" row must show the fact \"%s\", got \"%s\""
                            % [expected_income, ghost_income.text], state)

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

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("OK: ", message)
    else:
        state["failed"] = true
        push_error("FALL: " + message)
