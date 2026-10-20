# Headless test of BUILDING CONSUMPTION — both display and actual:
#   godot --headless --path . --script res://tests/test_building_consumption_ui.gd
#
# Checks:
#   1. ConsumptionUi.build_rows_for_building(): the expense rows of a building profession —
#      row composition, the "units/sec" rate, the bonus, multiplication by the number of
#      WORKING buildings, the case with no working buildings and a building without a
#      profession (empty list).
#   2. The building details tooltip (the "Buildings" tab): the "Consumes:" section with
#      the expense rate — shown before construction, like "Cost".
#   3. The consumption marker: the reverse index GameData.get_consumption_consumers()
#      finds the consumers of a resource in both directions (including when a rule
#      addresses a @-group while the row names a specific good), the resource in the RECIPE
#      ROW is underlined with a dotted line, while the "Consumes:" section row gets no
#      marker — its norm and bonus are already printed in the row itself.
#   4. The building details window: the total over two working buildings, then the marker
#      "(no working buildings)" when the building slots are empty (the building is idle and
#      spends no supplies).
#   5. ACTUAL consumption: a working building with a profession and the resource in storage
#      writes off exactly amount per interval; with an empty storage there is no expense,
#      and the production multiplier falls to the base (1.0); an idle building
#      (no townsfolk or all slots empty) spends no resource.
#
# IMPORTANT ABOUT THE DATA DEPENDENCY. The balance numbers (the supply id, amount,
# interval, production_bonus) live in data/consumption.json and in
# data/buildings.json and are CHANGED by the balance author. The test must NOT hardcode
# them: otherwise a json edit breaks the test even though the system works correctly.
# Therefore all expectations are derived from the same data (GameData.get_profession_consumption /
# get_profession_for_building / products / product_groups), and the checks are
# INVARIANTS: "the row is built from the data", "exactly amount is written off", "without
# the resource there is no bonus" — and not specific numbers.
#
# IMPORTANT: the script is compiled BEFORE the autoloads are registered, so we take them
# through the scene tree, and the shared helper via load() by path (the same trick as with
# HexUtils in test_territory_costs and with underlined_label in ui_helpers).
extends SceneTree

# The hang watchdog: without it, a broken _run() coroutine looks from the outside like
# eternal silence. See tests/watchdog.gd for details.
const WATCHDOG = preload("res://tests/watchdog.gd")

# A building with a profession is the subject of the check. The building itself may change
# in the data, so the choice is made by the helper _pick_profession_building(), not by a constant.
const SIMULATION_TICK := 1.0

var _gdata = null
var _cdata = null
var _wm = null
var _tm = null
var _consumption_ui = null

func _initialize():
    WATCHDOG.arm(self)
    _run()


func _run() -> void:
    var state = {"failed": false}
    _consumption_ui = load("res://scripts/consumption_ui.gd")

    # --- Live scene: new game, city, interface ---
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    main_map.open_city()
    await process_frame
    var city_ui = main_map.city_ui
    check(city_ui != null and city_ui.visible, "city interface is open", state)
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _wm = main_map.get_node("WorkerManager")
    _tm = main_map.get_node("TownsfolkManager")

    # A building with a profession and its supply — from the data, not from a constant.
    var building_id := _pick_profession_building()
    check(not building_id.is_empty(),
        "data/buildings.json must contain a building with a profession and consumption", state)
    if building_id.is_empty():
        _finish(main_map, state)
        return

    if WATCHDOG.wants_case("ui_rows"):
        _test_ui_rows(state, building_id)
    if WATCHDOG.wants_case("details_tooltip"):
        _test_details_tooltip(state, city_ui, building_id)
    if WATCHDOG.wants_case("consumption_marker"):
        _test_consumption_marker(state, city_ui, building_id)
    if WATCHDOG.wants_case("recipe_result_marker"):
        _test_recipe_result_marker(state, city_ui, building_id)
    if WATCHDOG.wants_case("building_panel"):
        _test_building_panel(state, city_ui, building_id)
    if WATCHDOG.wants_case("actual_consumption"):
        _test_actual_consumption(state, building_id)

    _finish(main_map, state)


# -------------------------------------------------------
# 1. The expense rows of a building profession (ConsumptionUi)
# -------------------------------------------------------

# All expectations come from GameData.get_profession_consumption(profession), not from
# the numbers in consumption.json: a balance change must not break the test.
func _test_ui_rows(state: Dictionary, building_id: String) -> void:
    var prof: String = _gdata.get_profession_for_building(building_id)
    check(not prof.is_empty(),
        "the building \"%s\" must have a profession (got: \"%s\")" % [building_id, prof], state)
    var entries: Array = _gdata.get_profession_consumption(prof)
    check(not entries.is_empty(),
        "the profession \"%s\" must have consumption in consumption.json" % prof, state)
    if entries.is_empty():
        return

    var rows = _consumption_ui.build_rows_for_building(building_id)
    check(rows.size() == entries.size(),
        "the number of expense rows must match the number of registry entries (rows %d, entries %d)"
            % [rows.size(), entries.size()], state)

    # Match each row with its registry entry by display_key.
    for entry in entries:
        var key := str(entry.get("display_key", entry.get("product_id", "")))
        var row := _row_by_key(rows, key)
        check(not row.is_empty(), "no expense row for \"%s\"" % key, state)
        if row.is_empty():
            continue
        var amount := int(entry.get("amount", 0))
        var interval := float(entry.get("interval", 0.0))
        var expected_per_sec := float(amount) if interval <= 0.0 else float(amount) / interval
        var expected_name := str(entry.get("product_name", entry.get("product_id", "")))
        var expected_bonus := float(entry.get("production_bonus", 0.0))

        check(str(row.get("name", "")) == expected_name,
            "the supply name \"%s\" must come from the data (got: \"%s\")"
                % [expected_name, str(row.get("name", ""))], state)
        check(is_equal_approx(float(row.get("per_sec", 0.0)), expected_per_sec),
            "the rate \"%s\": amount/interval = %s units/sec (got: %s)"
                % [key, str(expected_per_sec), str(row.get("per_sec", 0.0))], state)
        check(is_equal_approx(float(row.get("production_bonus", 0.0)), expected_bonus),
            "the bonus \"%s\" must match the data (got: %s)"
                % [key, str(row.get("production_bonus", 0.0))], state)
        check(str(row.get("display_key", "")) == key,
            "the row display_key did not match the registry entry (got: \"%s\")"
                % str(row.get("display_key", "")), state)
        # The label = "Name: rate_label", and rate_label is itself assembled from the data.
        check(str(row.get("label", "")) == "%s: %s" % [expected_name, str(row.get("rate_label", ""))],
            "the row label must be \"Name: rate_label\" (got: \"%s\")"
                % str(row.get("label", "")), state)

    # Multiplication by the number of WORKING buildings: the rate = base × N, plus the marker.
    var rows2 = _consumption_ui.build_rows_for_building(building_id, 2)
    for entry in entries:
        var key2 := str(entry.get("display_key", entry.get("product_id", "")))
        var row2 := _row_by_key(rows2, key2)
        if row2.is_empty():
            check(false, "with two buildings there is no expense row for \"%s\"" % key2, state)
            continue
        var base_per_sec := _base_per_sec(entry)
        check(is_equal_approx(float(row2.get("per_sec", 0.0)), base_per_sec * 2.0),
            "two working buildings double the rate \"%s\" (got: %s)"
                % [key2, str(row2.get("per_sec", 0.0))], state)
        check(_has_text([str(row2.get("label", ""))], "2"),
            "the label of two buildings must contain a marker with the number 2 (got: \"%s\")"
                % str(row2.get("label", "")), state)

    # No working buildings: the rate stays "per one building", but the label is different.
    var rows0 = _consumption_ui.build_rows_for_building(building_id, 0)
    for entry in entries:
        var key0 := str(entry.get("display_key", entry.get("product_id", "")))
        var row0 := _row_by_key(rows0, key0)
        if row0.is_empty():
            check(false, "without working buildings there is no expense row for \"%s\"" % key0, state)
            continue
        check(is_equal_approx(float(row0.get("per_sec", 0.0)), _base_per_sec(entry)),
            "without working buildings the rate \"%s\" stays per one building (got: %s)"
                % [key0, str(row0.get("per_sec", 0.0))], state)
        check(str(row0.get("label", "")) != str(_row_by_key(rows, key0).get("label", "")),
            "the label without working buildings must differ from the usual one (\"%s\")"
                % str(row0.get("label", "")), state)

    # A building without a profession and an empty id: nothing to show.
    check(_consumption_ui.build_rows_for_building("bakery").is_empty(),
        "the bakery (without a profession) has no expense rows", state)
    check(_consumption_ui.build_rows_for_building("").is_empty(),
        "for an empty building id there are no expense rows", state)


# -------------------------------------------------------
# 2. The building details tooltip on the "Buildings" tab
# -------------------------------------------------------

func _test_details_tooltip(state: Dictionary, city_ui, building_id: String) -> void:
    var prof := str(_gdata.get_profession_for_building(building_id))
    if prof.is_empty():
        return
    var entries: Array = _gdata.get_profession_consumption(prof)
    if entries.is_empty():
        return

    var btab = city_ui.buildings_tab
    var building = null
    for b in btab.buildings_data:
        if b.get("id", "") == building_id:
            building = b
            break
    check(building != null,
        "the building data \"%s\" is present in the \"Buildings\" tab" % building_id, state)
    if building == null:
        return

    btab._hovered_building_id = building_id
    btab._show_building_details(building)
    var tip_texts := _collect_texts(city_ui.ui_helpers.detail_tooltip_content)
    check(_has_line(tip_texts, "Consumes:"),
        "the details tooltip has the \"Consumes:\" heading (got: %s)" % str(tip_texts), state)
    # The rate and bonus in the tooltip come from the data, not hardcoded.
    var entry: Dictionary = entries[0]
    var expected_per_sec := _base_per_sec(entry)
    check(_has_text(tip_texts, "%s units/sec" % _consumption_ui.format_rate(expected_per_sec)),
        "the details tooltip has the expense rate \"%s units/sec\" (got: %s)"
            % [_consumption_ui.format_rate(expected_per_sec), str(tip_texts)], state)
    var bonus := float(entry.get("production_bonus", 0.0))
    if bonus > 0.0:
        check(_has_text(tip_texts, "+%d%% to production" % int(round(bonus * 100.0))),
            "the details tooltip has the bonus \"+%d%% to production\" (got: %s)"
                % [int(round(bonus * 100.0)), str(tip_texts)], state)

    # A building without a profession must have no such section.
    var bakery = null
    for b in btab.buildings_data:
        if b.get("id", "") == "bakery":
            bakery = b
            break
    if bakery != null:
        btab._show_building_details(bakery)
        var bakery_texts := _collect_texts(city_ui.ui_helpers.detail_tooltip_content)
        check(not _has_line(bakery_texts, "Consumes:"),
            "the bakery (without a profession) has no \"Consumes:\" section", state)


# -------------------------------------------------------
# 3. The consumption marker in the building details tooltip
# -------------------------------------------------------

# Invariants:
#   * the reverse index GameData.get_consumption_consumers(display_key) finds the
#     entry that addresses the same resource from the other side;
#   * the "Consumes:" section row does NOT get a marker — the norm and bonus are already
#     printed in the row itself, and the tooltip would duplicate the row (the marker lives
#     in the recipe rows, the recipe_result_marker case);
#   * the consumers tooltip (ui_helpers.show_consumption_tooltip) lists
#     consumers by profession names.
# Expectations are derived from the same data, not from specific balance numbers.
func _test_consumption_marker(state: Dictionary, city_ui, building_id: String) -> void:
    var prof := str(_gdata.get_profession_for_building(building_id))
    var entries: Array = _gdata.get_profession_consumption(prof)
    if entries.is_empty():
        return

    var btab = city_ui.buildings_tab
    var building = null
    for b in btab.buildings_data:
        if b.get("id", "") == building_id:
            building = b
            break
    if building == null:
        return

    btab._show_building_details(building)
    var content = city_ui.ui_helpers.detail_tooltip_content

    # 1. Each expense entry is addressed by the reverse index in both directions.
    var checked_any := false
    for entry in entries:
        var key := str(entry.get("display_key", entry.get("product_id", "")))
        if key.is_empty():
            continue
        var consumers: Array = _gdata.get_consumption_consumers(key)
        check(not consumers.is_empty(),
            "the reverse index must find the consumers of the resource \"%s\"" % key, state)
        for consumer in consumers:
            if str(consumer.get("profession_id", "")) == prof:
                checked_any = true
        # The consumer's norm and bonus match the profession entry (the data is the same).
        check(int(consumers[0].get("amount", 0)) == int(entry.get("amount", 0)),
            "the consumer's norm must match the profession entry \"%s\"" % key, state)
        # 2. In the "Consumes:" section there is NO marker: the row already states the norm
        #    and bonus, and the consumers tooltip would duplicate the same thing. The marker
        #    lives where the norm is not visible — in the recipe rows (the
        #    recipe_result_marker case).
        var marked: Label = _find_underlined_label(content, str(entry.get("product_name", "")))
        check(marked == null,
            "the \"Consumes:\" section row (\"%s\") must not get the consumers marker: "
                % key + "the norm and bonus are already printed in the row itself", state)
        # 3. The consumers tooltip itself works: the recipe row shows it.
        city_ui.ui_helpers.show_consumption_tooltip(Vector2(10, 10), key, btab.products)
        var tip_texts := _collect_texts(city_ui.ui_helpers.consumption_tooltip_content)
        check(_has_text(tip_texts, str(consumers[0].get("profession_name", ""))),
            "the consumers tooltip \"%s\" must name \"%s\" (got: %s)"
                % [key, str(consumers[0].get("profession_name", "")), str(tip_texts)], state)
        check(_has_text(tip_texts, "units/sec"),
            "the consumers tooltip \"%s\" must show the expense rate (got: %s)"
                % [key, str(tip_texts)], state)
        city_ui.ui_helpers.hide_consumption_tooltip()

    check(checked_any, "the building profession must be found among the consumers", state)

    # 4. A resource without a consumer profession gets no marker.
    var plain: Array = _gdata.get_consumption_consumers("__no_such_resource__")
    check(plain.is_empty(),
        "a nonexistent resource must have no consumers", state)

    _test_group_membership(state, city_ui)


# A recipe row names a SPECIFIC product, while a consumption rule most often speaks about
# a group. We check that the reverse index walks the group composition: without this the
# marker would not appear where the player expects it (for example, "Reed Boats" in the
# papyrus workshop recipe — the rule addresses the "@boats" group).
# Expectations are derived from the data: the group and its composition come from
# product_groups, not from a specific identifier.
func _test_group_membership(state: Dictionary, city_ui) -> void:
    var found_member := false
    for group_id in _gdata.product_groups:
        var group_key := "@%s" % str(group_id)
        var group_rules: Array = _gdata.get_consumption_consumers(group_key)
        if group_rules.is_empty():
            continue
        # The group itself is consumed, but its members are not addressed by their own
        # rules: each member must find exactly the same consumers through the group
        # composition.
        var member := ""
        for candidate in _gdata.product_groups[group_id]:
            var candidate_rules: Array = _gdata.get_consumption_consumers(str(candidate))
            if candidate_rules.is_empty():
                continue
            member = str(candidate)
            found_member = true
            var expected := str(group_rules[0].get("profession_id", ""))
            var got := str(candidate_rules[0].get("profession_id", ""))
            check(got == expected,
                "the group member \"%s\" must find the consumer \"%s\", got \"%s\""
                    % [member, expected, got], state)
            check(str(candidate_rules[0].get("via_group", "")) == group_key,
                "the consumer of the member \"%s\" must be marked as a group one (%s)"
                    % [member, group_key], state)
            check(int(candidate_rules[0].get("amount", 0)) == int(group_rules[0].get("amount", 0)),
                "the expense norm of the member \"%s\" must match the group norm" % member, state)
            break

        # A group rule addresses only the group: for a query by the @-key via_group is empty.
        for rule in group_rules:
            check(str(rule.get("via_group", "")).is_empty(),
                "a query by the @-key itself must not mark itself as a group one (%s)" % group_key,
                state)
        break

    check(found_member,
        "a group with consumption must be found whose member is located by the reverse index", state)

    # The parent case: a product that is in no consumed group and has no rule of its own
    # stays without a marker — "absolutely any resource" must not be underlined.
    var lonely := ""
    for prod_id in _gdata.products:
        if not _gdata.get_consumption_consumers(str(prod_id)).is_empty():
            continue
        var in_consumed_group := false
        for group_id in _gdata.product_groups:
            if _gdata.product_groups[group_id].has(str(prod_id)) \
                    and not _gdata.get_consumption_consumers("@%s" % str(group_id)).is_empty():
                in_consumed_group = true
                break
        if in_consumed_group:
            continue
        lonely = str(prod_id)
        break
    if not lonely.is_empty():
        var entry = city_ui.ui_helpers.make_resource_entry(lonely, city_ui.buildings_tab.products,
            -1, "x", 20, true)
        check(_find_underlined_label(entry, _gdata.format_resource_name(lonely)) == null,
            "the resource \"%s\" without a consumer must not get an underline" % lonely, state)
        entry.free()


# The RESULT row of a recipe in the pinned building details tooltip (for the papyrus
# workshop recipe that is "Reed Boats") must be marked if the product is consumed —
# including when the rule addresses a group rather than the product itself.
func _test_recipe_result_marker(state: Dictionary, city_ui, _building_id: String) -> void:
    var btab = city_ui.buildings_tab
    var content = city_ui.ui_helpers.detail_tooltip_content

    # A building with a recipe whose result someone consumes. The recipes are addressed the
    # same way as the tab itself assembles them (crafts_data + CityData.can_craft_in), so
    # the test will not diverge from the filtering of available recipes. No identifier
    # is hardcoded here.
    var tested := false
    for building in btab.buildings_data:
        var b_id = str(building.get("id", ""))
        var expected_prod := ""
        var expected_craft: Dictionary = {}
        for craft in btab.crafts_data:
            if str(craft.get("id", "")) == "empty":
                continue
            if not _cdata.can_craft_in(str(craft.get("id", "")), b_id):
                continue
            var result = craft.get("display_result", craft.get("result", {}))
            for prod_id in result:
                if not _gdata.get_consumption_consumers(str(prod_id)).is_empty():
                    expected_prod = str(prod_id)
                    expected_craft = craft
                    break
            if not expected_prod.is_empty():
                break
        if expected_prod.is_empty():
            continue

        # A recipe enters the list only when its technology is unlocked, so it must be
        # unlocked — otherwise the "Available recipes" section will not be built and there
        # will be nothing to check. We unlock exactly the one the recipe itself requires.
        var unlock_tech := str(expected_craft.get("unlock_tech", ""))
        if not unlock_tech.is_empty() and not _cdata.is_tech_unlocked(unlock_tech):
            _cdata.unlocked_technologies.append(unlock_tech)

        btab._show_building_details(building)
        var marked = _find_underlined_label(content, _gdata.format_resource_name(expected_prod))
        check(marked != null,
            "the recipe result \"%s\" of the building \"%s\" must be marked with an underline"
                % [expected_prod, b_id], state)
        if marked == null:
            continue
        tested = true
        check(marked.dot_style,
            "the underline of the recipe result \"%s\" must be dotted" % expected_prod, state)

        # And hovering over it reveals the consumers.
        city_ui.ui_helpers.show_consumption_tooltip(Vector2(10, 10), expected_prod, btab.products)
        var tip_texts := _collect_texts(city_ui.ui_helpers.consumption_tooltip_content)
        var consumers: Array = _gdata.get_consumption_consumers(expected_prod)
        check(_has_text(tip_texts, str(consumers[0].get("profession_name", ""))),
            "the recipe result tooltip \"%s\" must name the consumer (got: %s)"
                % [expected_prod, str(tip_texts)], state)
        # The product is consumed as a group member — the player is told about it.
        if not str(consumers[0].get("via_group", "")).is_empty():
            var group_name: String = _gdata.format_resource_name(str(consumers[0]["via_group"]))
            check(_has_text(tip_texts, group_name),
                "the tooltip \"%s\" must name the group \"%s\" (got: %s)"
                    % [expected_prod, group_name, str(tip_texts)], state)
        city_ui.ui_helpers.hide_consumption_tooltip()
        break

    check(tested,
        "a building must be found whose recipe result someone consumes", state)


# Searches the nodes for an underlined label (underlined_label.gd) with the given
# name text. Returns the node or null.
func _find_underlined_label(node: Node, resource_name: String):
    for child in node.get_children():
        if child is Label and child.get("underline_text") != null \
                and (child as Label).text.begins_with(resource_name):
            return child
        var found = _find_underlined_label(child, resource_name)
        if found != null:
            return found
    return null


# -------------------------------------------------------
# 4. The building details window: the total over working buildings
# -------------------------------------------------------

func _test_building_panel(state: Dictionary, city_ui, building_id: String) -> void:
    var prof := str(_gdata.get_profession_for_building(building_id))
    if prof.is_empty():
        return
    var entries: Array = _gdata.get_profession_consumption(prof)
    if entries.is_empty():
        return

    # We take the slot from the building itself in the data — which recipe counts as working.
    var slot := _default_slot_for_building(building_id)
    _cdata.city_built_buildings = [
        {"id": building_id, "slots": [slot], "quality_priority": "best"},
        {"id": building_id, "slots": [slot], "quality_priority": "best"},
    ]
    _cdata.idle_population = maxi(_cdata.idle_population, 4)
    check(_tm.assign_townsfolk(0), "a townsfolk is assigned to the first building", state)
    check(_tm.assign_townsfolk(1), "a townsfolk is assigned to the second building", state)
    city_ui._on_building_detail_requested(building_id)
    await process_frame
    var panel = city_ui.building_panel
    check(panel != null and panel.visible, "the building details window is open", state)
    if panel == null:
        return

    check(panel.consumption_box != null and panel.consumption_box.visible,
        "the \"Consumes:\" section is shown in the building window", state)
    var entry: Dictionary = entries[0]
    var base_per_sec := _base_per_sec(entry)
    var panel_texts := _collect_texts(panel.consumption_box)
    check(_has_text(panel_texts, "%s units/sec" % _consumption_ui.format_rate(base_per_sec * 2.0)),
        "the building window shows the total over two workers (got: %s)" % str(panel_texts), state)
    var bonus := float(entry.get("production_bonus", 0.0))
    if bonus > 0.0:
        check(_has_text(panel_texts, "+%d%% to production" % int(round(bonus * 100.0))),
            "the building window shows the production bonus (got: %s)" % str(panel_texts), state)

    # One building is idle (empty slots) — no supply is spent.
    _cdata.city_built_buildings[1]["slots"] = ["empty"]
    panel._refresh()
    var idle_texts := _collect_texts(panel.consumption_box)
    check(_has_text(idle_texts, "%s units/sec" % _consumption_ui.format_rate(base_per_sec)),
        "with an idle building the rate is for one building (got: %s)" % str(idle_texts), state)
    check(not _has_text(idle_texts, "(2 buildings)"),
        "an idle building does not enter the total (got: %s)" % str(idle_texts), state)

    # Both buildings without townsfolk — there is no expense, but the "per building" rate is visible.
    _tm.remove_townsfolk(0)
    _tm.remove_townsfolk(1)
    panel._refresh()
    var no_worker_texts := _collect_texts(panel.consumption_box)
    check(_has_text(no_worker_texts, "no working buildings"),
        "without townsfolk there is the \"no working buildings\" marker (got: %s)" % str(no_worker_texts), state)

    # A building without a profession: the section is hidden.
    _cdata.city_built_buildings = [{"id": "bakery", "slots": ["bread"], "quality_priority": "best"}]
    var bakery_data = city_ui.data_cache.duplicate()
    bakery_data["ui_helpers"] = city_ui.ui_helpers
    panel.open("bakery", bakery_data)
    check(panel.consumption_box.get_child_count() == 0 and not panel.consumption_box.visible,
        "for a building without a profession the \"Consumes:\" section is hidden", state)


# -------------------------------------------------------
# 5. ACTUAL consumption by a building
# -------------------------------------------------------

# Mechanics: CityData.do_tick() for each WORKING building (there is a townsfolk and
# at least one non-empty slot) calls worker_manager.tick_building_consumption(i,
# SIMULATION_TICK). Here we call it directly — deterministically, without a race of game
# ticks. We check INVARIANTS, not numbers: as much amount as is in the registry is
# written off per interval; without the resource there is no bonus.
func _test_actual_consumption(state: Dictionary, building_id: String) -> void:
    var prof := str(_gdata.get_profession_for_building(building_id))
    var entries: Array = _gdata.get_profession_consumption(prof)
    if entries.is_empty():
        return
    var entry: Dictionary = entries[0]
    var product_key := str(entry.get("display_key", entry.get("product_id", "")))
    var amount := int(entry.get("amount", 0))
    var interval := float(entry.get("interval", 0.0))
    var bonus := float(entry.get("production_bonus", 0.0))
    if amount <= 0 or interval <= 0.0:
        check(false, "the entry \"%s\" must have positive amount/interval" % product_key, state)
        return

    # A fresh timer: the test must not depend on previously accumulated fractions.
    _wm.building_consumption_timers.clear()

    var slot := _default_slot_for_building(building_id)
    _cdata.city_built_buildings = [
        {"id": building_id, "slots": [slot], "quality_priority": "best"},
    ]
    _cdata.idle_population = maxi(_cdata.idle_population, 2)
    # We add a townsfolk exactly the way the game does.
    _tm.assign_townsfolk(0)
    check(_tm.has_townsfolk(0), "a townsfolk must be assigned to the building", state)

    # We fill the storage with a margin: exactly amount per interval must be written off.
    var storage_before := _fill_storage(product_key, amount * 4)
    check(storage_before >= amount,
        "the storage \"%s\" must have at least one portion amount=%d" % [product_key, amount], state)

    # One consumption interval: we expect exactly amount to be written off (plus, possibly,
    # a side consumption of the recipe — so we compare only by this resource
    # and with the precision "not more than amount", and separately check that the bonus is on).
    var before := _storage_of(product_key)
    _tick_interval(interval)
    var after := _storage_of(product_key)
    var spent := before - after
    check(spent == amount,
        "per interval=%s a working building must write off exactly amount=%d \"%s\" (written off %d)"
            % [str(interval), amount, product_key, spent], state)

    # While the resource lasted — the production multiplier = 1 + bonus (the bonus is on).
    if bonus > 0.0:
        var mult_with: float = _wm.tick_building_consumption(0, 0.0)
        check(is_equal_approx(mult_with, 1.0 + bonus),
            "with the resource present the production multiplier = 1+bonus (got: %s, expected %s)"
                % [str(mult_with), str(1.0 + bonus)], state)

    # We empty the storage: there is no expense, the multiplier falls to the base.
    _clear_storage(product_key)
    # A short run so the timer tries to write off with an empty storage.
    _tick_interval(interval)
    check(_storage_of(product_key) == 0,
        "with an empty storage the resource \"%s\" cannot go negative" % product_key, state)
    var mult_without: float = _wm.tick_building_consumption(0, 0.0)
    check(is_equal_approx(mult_without, 1.0),
        "without the resource the production multiplier must return to 1.0 (got: %s)"
            % str(mult_without), state)

    # An idle building: no townsfolk — no expense, even if the resource is present.
    _tm.remove_townsfolk(0)
    _wm.building_consumption_timers.clear()
    var restored := _fill_storage(product_key, amount * 2)
    _tick_interval(interval)
    check(_storage_of(product_key) == restored,
        "without a townsfolk the building must not spend \"%s\" (was %d, became %d)"
            % [product_key, restored, _storage_of(product_key)], state)

    # A townsfolk is present, but all slots are empty: do_tick skips consumption.
    _tm.assign_townsfolk(0)
    _cdata.city_built_buildings[0]["slots"] = ["empty"]
    _wm.building_consumption_timers.clear()
    var restored2 := _fill_storage(product_key, amount * 2)
    _tick_interval(interval)
    check(_storage_of(product_key) == restored2,
        "with empty slots no expense is made (was %d, became %d)"
            % [restored2, _storage_of(product_key)], state)


# Runs the building consumption for the length of the interval in SIMULATION_TICK steps —
# just like the game loop does (one tick at a time).
#
# IMPORTANT: tick_building_consumption() itself knows nothing about townsfolk/slots —
# the "building works" condition is checked by the caller CityData.do_tick()
# (there is a townsfolk AND not all slots are empty). Here this condition is reproduced,
# otherwise the test would call consumption on an idle building, which never happens in the game.
func _tick_interval(interval: float) -> void:
    if not _is_building_working(0):
        return
    var steps := maxi(1, int(ceil(interval / SIMULATION_TICK)))
    for _i in range(steps):
        _wm.tick_building_consumption(0, SIMULATION_TICK)


# The same "building works" condition as in CityData.do_tick().
func _is_building_working(b_index: int) -> bool:
    if not _tm.has_townsfolk(b_index):
        return false
    return not _cdata.are_all_slots_empty(b_index)


# Fills the storage with the resource and a margin, returns the resulting amount.
func _fill_storage(product_key: String, wanted: int) -> int:
    if product_key.begins_with("@"):
        # A group: we fill the first MEMBER so the write-off goes greedily.
        var members: Array = _gdata.product_groups.get(product_key.substr(1), [])
        if members.is_empty():
            return 0
        var pid := str(members[0])
        _cdata.add_to_storage(pid, wanted, "common")
        return _cdata.get_storage_amount(pid)
    _cdata.add_to_storage(product_key, wanted, "common")
    return _cdata.get_storage_amount(product_key)


func _clear_storage(product_key: String) -> void:
    if product_key.begins_with("@"):
        for m in _gdata.product_groups.get(product_key.substr(1), []):
            var amt: int = _cdata.get_storage_amount(str(m))
            if amt > 0:
                _cdata.remove_from_storage(str(m), amt, "best")
        return
    var amt2: int = _cdata.get_storage_amount(product_key)
    if amt2 > 0:
        _cdata.remove_from_storage(product_key, amt2, "best")


func _storage_of(product_key: String) -> int:
    if product_key.begins_with("@"):
        var members: Array = _gdata.product_groups.get(product_key.substr(1), [])
        if members.is_empty():
            return 0
        return _cdata.get_storage_amount(str(members[0]))
    return _cdata.get_storage_amount(product_key)


# -------------------------------------------------------
# Choosing data for the check
# -------------------------------------------------------

# A building with a profession that has at least one consumption rule.
# We do not hardcode "library": if the set of buildings/professions changes, the test will
# find another suitable building rather than fail.
func _pick_profession_building() -> String:
    for b in _gdata.buildings:
        var bld_id := str(b.get("id", ""))
        if bld_id.is_empty():
            continue
        var prof := str(_gdata.get_profession_for_building(bld_id))
        if prof.is_empty():
            continue
        if not _gdata.get_profession_consumption(prof).is_empty():
            return bld_id
    return ""


# The default recipe of a building (the first non-empty slot from the data) — so the
# building window counts the building as working, as in the game.
func _default_slot_for_building(building_id: String) -> String:
    var b: Dictionary = _gdata.get_building_data(building_id)
    var recipes: Array = b.get("default_recipes", [])
    if not recipes.is_empty():
        return str(recipes[0])
    return "empty"


# The consumption rate of an entry without a multiplier: amount / interval (units/sec).
func _base_per_sec(entry: Dictionary) -> float:
    var amount := int(entry.get("amount", 0))
    var interval := float(entry.get("interval", 0.0))
    return float(amount) if interval <= 0.0 else float(amount) / interval


# The expense row by the resource/group key.
func _row_by_key(rows: Array, key: String) -> Dictionary:
    for r in rows:
        if str(r.get("display_key", "")) == key:
            return r
    return {}


# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# Collects the texts of all labels under a node (Label and RichTextLabel at any depth).
func _collect_texts(node: Node) -> Array:
    var result: Array = []
    for child in node.get_children():
        if child is Label:
            result.append(str((child as Label).text))
        elif child is RichTextLabel:
            result.append(str((child as RichTextLabel).text))
        else:
            result.append_array(_collect_texts(child))
    return result

func _has_text(texts: Array, needle: String) -> bool:
    for t in texts:
        if str(t).contains(needle):
            return true
    return false

func _has_line(texts: Array, line: String) -> bool:
    for t in texts:
        if str(t) == line:
            return true
    return false

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("BUILDING CONSUMPTION TEST FAILED")
        quit(1)
    else:
        print("BUILDING CONSUMPTION TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
