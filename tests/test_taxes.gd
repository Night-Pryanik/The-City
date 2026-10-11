# Headless test of the population taxes (poll tax to the treasury):
#   godot --headless --path . --script res://tests/test_taxes.gd
#
# Every citizen pays a base tax to the treasury (base_tax_per_citizen from
# data/game_balance.json) for EVERY simulation tick. Checks:
#
#   1. The rate is read from data/game_balance.json and equals 2;
#      CityData.get_base_tax_per_citizen() returns the same rate.
#   2. Income per tick = rate × population (CityData.get_tax_income_per_tick).
#   3. collect_taxes() puts exactly rate × population into the treasury and writes
#      the source into the FLAT breakdown accumulator (CityData.TAX_INCOME_SOURCE).
#   4. Nobody to pay (population 0) — no-op: the treasury does not change.
#   5. Live tick: do_tick() increases the treasury by the tax (+ the income of the
#      domestic market, which is measured separately via the product accumulator).
#   6. Treasury breakdown (worker_manager): the "Taxes" type is "flat"
#      (CityData.TREASURY_FLAT_TYPE_KEY) with rate = rate × population and
#      label = "2 × 3 people"; the tax is visible even when there is no market income yet.
#   7. Tooltip render (ui_helpers.show_treasury_tooltip): a single row
#      "• Taxes: 2 × 3 people = 6 / sec", the profit section total includes the tax.
#   8. The "Treasury: N [+X≈ / -Y≈]" row in the map HUD and in the city top bar:
#      the dynamics of the actual profit/expenses reached both labels, matched
#      CityData.get_treasury_flow_text() and fit into the width of the HUD panel.
extends SceneTree

# Watchdog against hangs: without it, an aborted _run() coroutine looks like an endless
# silence from the outside. See tests/watchdog.gd for details.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # We get the autoloads through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at the compile stage of this file.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")
    var gdata = get_root().get_node("GameData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    check(main_map.tile_data.size() == main_map.map_rows,
            "the map is not initialized (tile_data is empty)", state)

    # --- 1. The rate from data/game_balance.json ---
    var base_tax: int = int(gdata.game_balance.get("base_tax_per_citizen", -1))
    check(base_tax > 0, "base_tax_per_citizen must be > 0 in game_balance.json", state)
    check(base_tax == 2, "base_tax_per_citizen: expected 2, got %d" % base_tax, state)
    check(city.get_base_tax_per_citizen() == base_tax,
            "get_base_tax_per_citizen() must read the rate from game_balance.json", state)

    # --- 2. Income per tick = rate × population ---
    city.total_population = 1
    check(city.get_tax_income_per_tick() == base_tax,
            "with 1 citizen the tax per tick must be %d" % base_tax, state)
    city.total_population = 3
    check(city.get_tax_income_per_tick() == base_tax * 3,
            "with 3 citizens the tax per tick must be %d" % (base_tax * 3), state)

    # --- 3. collect_taxes(): the treasury grows exactly by the tax + a record in the breakdown ---
    city.treasury = 0
    city.treasury_income_accum.clear()
    city.treasury_income_product_accum.clear()
    var collected: int = city.collect_taxes()
    check(collected == base_tax * 3,
            "collect_taxes() returned %d, expected %d" % [collected, base_tax * 3], state)
    check(city.treasury == base_tax * 3,
            "treasury after collection: expected %d, got %d" % [base_tax * 3, city.treasury], state)
    check(int(city.treasury_income_accum.get(city.TAX_INCOME_SOURCE, 0)) == base_tax * 3,
            "the flat accumulator must contain the tax under the source \"%s\""
                    % city.TAX_INCOME_SOURCE, state)

    # --- 4. Nobody to pay — no-op ---
    city.treasury = 0
    city.total_population = 0
    check(city.collect_taxes() == 0, "with zero population no tax must be collected", state)
    check(city.treasury == 0, "with zero population the treasury must not change", state)

    # --- 5. Live tick: the tax comes from do_tick() ---
    # Inside do_tick() the tax is collected BEFORE _check_population_change, so
    # we compute it from the population at the start of the tick. The domestic market income (buildings
    # with professions, etc.) is measured separately — via the product accumulator,
    # so that the check does not depend on what exactly was sold in this tick.
    city.total_population = 3
    city.treasury = 0
    city.treasury_income_accum.clear()
    city.treasury_income_product_accum.clear()
    city.do_tick()
    var market_income: int = _sum_accum(city.treasury_income_product_accum)
    check(city.treasury == base_tax * 3 + market_income,
            "per tick the treasury must receive the tax %d + market %d (got %d)"
                    % [base_tax * 3, market_income, city.treasury], state)
    check(int(city.treasury_income_accum.get(city.TAX_INCOME_SOURCE, 0)) == base_tax * 3,
            "per tick the breakdown must include the tax %d" % (base_tax * 3), state)


    # --- 6. Treasury breakdown: the "Taxes" type is a flat row ---
    city.total_population = 3
    var actual: Dictionary = main_map.worker_manager.get_actual_treasury_income_map()
    check(actual.has(city.TAX_INCOME_TYPE),
            "the treasury breakdown must contain the type \"%s\"" % city.TAX_INCOME_TYPE, state)
    var flat_row: Dictionary = actual.get(city.TAX_INCOME_TYPE, {}).get(city.TREASURY_FLAT_TYPE_KEY, {})
    check(not flat_row.is_empty(),
            "the type \"%s\" must be \"flat\" (key %s)"
                    % [city.TAX_INCOME_TYPE, city.TREASURY_FLAT_TYPE_KEY], state)
    check(abs(float(flat_row.get("rate", 0.0)) - float(base_tax * 3)) < 0.0001,
            "tax rate in the breakdown: expected %d, got %s"
                    % [base_tax * 3, str(flat_row.get("rate", 0.0))], state)
    check(str(flat_row.get("label", "")) == "%d × 3 people" % base_tax,
            "tax label: expected \"%d × 3 people\", got \"%s\""
                    % [base_tax, str(flat_row.get("label", ""))], state)

    # The tax is visible even when there is no market income yet (start of a new game,
    # the first window after loading, an empty storage).
    city.treasury_income_product_accum.clear()
    city.treasury_income_product_snapshot.clear()
    var taxes_only: Dictionary = main_map.worker_manager.get_actual_treasury_income_map()
    check(taxes_only.has(city.TAX_INCOME_TYPE),
            "taxes must be in the breakdown even without market income", state)
    check(not taxes_only.has(city.POPULATION_INCOME_TYPE),
            "without market income the \"Population consumption\" type must not be shown", state)
    check(main_map.worker_manager.get_planned_treasury_income_map().has(city.TAX_INCOME_TYPE),
            "the planned breakdown generator must also know about taxes", state)

    # --- 7. Tooltip render: a single row "• Taxes: 2 × 3 people = 6 / sec" ---
    var holder := Control.new()
    root.add_child(holder)
    var ui = load("res://scripts/ui_helpers.gd").new()
    ui.setup(holder, Label.new())
    holder.add_child(ui)
    await process_frame
    await process_frame

    # The type key in the map is the English CityData.TAX_INCOME_TYPE, but it is drawn
    # AFTER translation (ui_helpers.show_treasury_tooltip wraps it in tr()),
    # so the expected row is assembled from the translated label.
    var tax_line: String = "%s: %d × 3 people = %s / sec" % [
        tr(city.TAX_INCOME_TYPE), base_tax, _fmt_rate(float(base_tax * 3))
    ]
    ui.show_treasury_tooltip(Vector2(80, 80), city.treasury, taxes_only, {}, 3.0)
    await process_frame
    var texts: Array = []
    _collect_label_texts(ui.treasury_tooltip_vbox, texts)
    check(texts.has(tax_line),
            "the tax row \"%s\" was not found among the tooltip rows: %s" % [tax_line, str(texts)], state)
    check(texts.has("Profit (actual, average): %s / sec" % _fmt_rate(float(base_tax * 3))),
            "the profit section total must include the tax: %s" % str(texts), state)
    check(not texts.has("All Citizens"),
            "a flat type must not expand into sources/products", state)

    # Market + tax: the section total = the sum of the rows, the tax is still a single row.
    var mixed: Dictionary = taxes_only.duplicate(true)
    mixed[city.POPULATION_INCOME_TYPE] = {
        gdata.profession_source_id("all"): {
            "fish": {"coins_per_sec": 2.5, "product_name": "Fish"}
        }
    }
    ui.show_treasury_tooltip(Vector2(80, 80), city.treasury, mixed, {}, 3.0)
    await process_frame
    texts.clear()
    _collect_label_texts(ui.treasury_tooltip_vbox, texts)
    check(texts.has(tax_line), "the tax row must remain next to the market too: %s" % str(texts), state)
    check(texts.has("Fish: 2.5 / sec"), "the market rows must be drawn as before: %s" % str(texts), state)
    var expected_total: float = _sum_map_rates(mixed, city.TREASURY_FLAT_TYPE_KEY)
    check(texts.has("Profit (actual, average): %s / sec" % _fmt_rate(expected_total)),
            "the profit section total: expected \"%s\"" % _fmt_rate(expected_total), state)

    # --- 8. The "Treasury" row in the HUD and the top bar: profit/expense dynamics ---
    # The labels assemble the text from CityData.get_treasury_flow_text() — we check that
    # the dynamics actually reached both rows and matches the calculation (without
    # the autoloads this cannot be checked: a live MainMap is needed).
    var flow: Dictionary = city.get_treasury_flow_per_sec()
    var flow_text: String = city.get_treasury_flow_text()
    check(flow_text.contains("[+") and flow_text.contains("≈]"),
            "the treasury dynamics must look like [+X≈ / -Y≈], got \"%s\"" % flow_text, state)
    var hud_label = main_map.hud.get_node_or_null("VBoxContainer/TreasuryLabel")
    check(hud_label != null, "the treasury label in the HUD was not found", state)
    if hud_label != null:
        check(hud_label.text == "Treasury: %d %s" % [city.treasury, flow_text],
                "the HUD must show \"Treasury: N %s\", got \"%s\"" % [flow_text, hud_label.text], state)
    # The city top bar is updated from city_ui._update_food_label — we call it
    # directly (in the test the city interface is not open, the tick path will not fire).
    main_map.city_ui._update_food_label()
    var city_treasury_label = main_map.city_ui.get_node_or_null("TabBarPanel/TopFoodLabel/TreasuryLabel")
    check(city_treasury_label != null, "the treasury label in the city top bar was not found", state)
    if city_treasury_label != null:
        check(city_treasury_label.text == "Treasury: %d %s" % [city.treasury, flow_text],
                "the top bar must show \"Treasury: N %s\", got \"%s\""
                        % [flow_text, city_treasury_label.text], state)
    # Fitting the HUD size to a long row: the panel must not be narrower than the label,
    # otherwise the text will spill onto the map, and hovering the "tail" of the row will not work.
    check(main_map.hud.size.x >= hud_label.get_combined_minimum_size().x,
            "the HUD width (%d) must cover the treasury label (%d)"
                    % [main_map.hud.size.x, hud_label.get_combined_minimum_size().x], state)
    # The tax income must reach the dynamics: in this tick
    # base_tax × 3 was collected, window 3 sec → base_tax / sec.
    check(float(flow.get("income", 0.0)) > 0.0,
            "the income in the dynamics must be non-zero, got %s" % str(flow.get("income", 0.0)), state)

    _finish(main_map, state)

# Collects the texts of all Labels in the tree (including the _make_bullet_row "bullets", where
# the symbol and the text are separate labels in an HBox).
func _collect_label_texts(node: Node, out: Array) -> void:
    for child in node.get_children():
        if child is Label:
            out.append((child as Label).text)
        _collect_label_texts(child, out)

# Sum of the product accumulator: { source -> { pid -> amount } }.
func _sum_accum(by_source: Dictionary) -> int:
    var total := 0
    for source in by_source:
        for pid in by_source[source]:
            total += int(by_source[source][pid])
    return total

# Total breakdown rate: regular types — by products, the "flat" one — by its
# rate (the same rule as in the tooltip render).
func _sum_map_rates(income: Dictionary, flat_key: String) -> float:
    var total := 0.0
    for income_type in income:
        var type_dict: Dictionary = income[income_type]
        var flat: Dictionary = type_dict.get(flat_key, {})
        if not flat.is_empty():
            total += float(flat.get("rate", 0.0))
            continue
        for source in type_dict:
            for pid in type_dict[source]:
                total += float(type_dict[source][pid].get("coins_per_sec", 0.0))
    return total

# Rate format — like ui_helpers._format_rate (whole numbers without a fractional part).
func _fmt_rate(value: float) -> String:
    if value == floor(value):
        return str(int(value))
    return "%.1f" % value

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("TAXES TEST FAILED")
        quit(1)
    else:
        print("TAXES TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
