# Headless test of the RECIPE ALIGNMENT in the building detail tooltip:
#   godot --headless --path . --script res://tests/test_recipe_alignment.gd
#
# A building may have several recipes with names of different length ("Pапирус"
# and "Тростниковые лодки" in the screenshot). The tooltip must lay them out so
# that the name column is as wide as the longest recipe name, and the icons of
# the ingredients of every recipe start at the same X — one vertical line.
#
# The test takes a real building from data/buildings.json that has at least two
# available recipes with different name lengths, so it does not depend on any
# particular balance value.
extends SceneTree

# Hang watchdog: without it a broken coroutine _run() looks like eternal silence
# from the outside. See tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    main_map.open_city()
    await process_frame
    var city_ui = main_map.city_ui
    check(city_ui != null and city_ui.visible, "city UI is open", state)

    # The alignment of the recipe name column is independent of the tech tree, so
    # we unlock everything: the recipes of one building may sit behind different
    # technologies (as "Papyrus" and "Reed Boats" behind "writing"/"fishing").
    for t in _gdata.technologies:
        var tech_id := str(t.get("id", ""))
        if tech_id != "" and not _cdata.is_tech_unlocked(tech_id):
            _cdata.unlocked_technologies.append(tech_id)

    var btab = city_ui.buildings_tab

    # A building with >= 2 available recipes whose names differ in length.
    var building = _pick_multi_recipe_building(btab)
    check(not building.is_empty(),
        "data/buildings.json must have a building with two recipes of different name length", state)
    if building.is_empty():
        _finish(main_map, state)
        return

    btab._hovered_building_id = str(building.get("id", ""))
    btab._show_building_details(building)
    await process_frame
    await process_frame

    var rows := _recipe_rows(city_ui.ui_helpers.detail_tooltip_content)
    check(rows.size() >= 2,
        "the tooltip must show at least two recipe rows (got %d)" % rows.size(), state)

    # 1. All recipe name labels must have the same width — the width of the
    # longest name. Since the same width is applied to every label, the icon of
    # the first ingredient automatically starts at the same X in every row.
    var widths: Array = []
    for row in rows:
        var label = row.get_child(1)
        if label is Label:
            widths.append((label as Label).custom_minimum_size.x)

    var first_width: float = widths[0] if not widths.is_empty() else 0.0
    var same_width := true
    for w in widths:
        if not is_equal_approx(float(w), first_width):
            same_width = false
    check(same_width,
        "recipe name labels must share one width (got %s)" % str(widths), state)

    # The column must be as wide as the longest recipe name, not a fixed 130.
    var longest := 0.0
    for row in rows:
        var label = row.get_child(1)
        if label is Label:
            longest = maxf(longest, _measure(label))
    check(first_width >= longest - 0.5,
        "the column must fit the longest recipe name (column %.1f, longest %.1f)"
            % [first_width, longest], state)

    # 2. The icons of the ingredients must lie on one vertical line.
    var icon_xs: Array = []
    for row in rows:
        var content = row.get_child(row.get_child_count() - 1)
        var icon = _first_icon(content)
        if icon != null:
            icon_xs.append(icon.get_global_rect().position.x)
    check(icon_xs.size() >= 2,
        "at least two recipe rows must have an ingredient icon (got %d)" % icon_xs.size(), state)
    if icon_xs.size() >= 2:
        var aligned := true
        for x in icon_xs:
            if absf(float(x) - float(icon_xs[0])) > 0.5:
                aligned = false
        check(aligned,
            "ingredient icons must share one vertical line (got X %s)" % str(icon_xs), state)

    if state["failed"]:
        print("RECIPE ALIGNMENT TEST FAILED")
        _finish(main_map, state, 1)
    else:
        print("RECIPE ALIGNMENT TEST OK")
        _finish(main_map, state, 0)

# A building from the tab data with at least two available recipes of different
# name length — the exact case from the screenshot ("Papyrus" vs "Reed Boats" in
# the papyrus workshop). The papyrus workshop is preferred when it qualifies;
# otherwise the first suitable building is used, so the test does not depend on
# any particular balance value.
func _pick_multi_recipe_building(btab) -> Dictionary:
    var fallback := {}
    for b in btab.buildings_data:
        var bld_id := str(b.get("id", ""))
        if bld_id.is_empty():
            continue
        var names: Array = []
        for craft in btab.crafts_data:
            if str(craft.get("id", "")) == "empty":
                continue
            if not _cdata.can_craft_in(str(craft.get("id", "")), bld_id):
                continue
            var tech := str(craft.get("unlock_tech", ""))
            if tech != "" and not _cdata.is_tech_unlocked(tech):
                continue
            names.append(str(craft.get("name", "")))
        if names.size() < 2:
            continue
        var shortest: int = int(names[0].length())
        var longest: int = shortest
        for n in names:
            shortest = mini(shortest, int(str(n).length()))
            longest = maxi(longest, int(str(n).length()))
        if longest <= shortest:
            continue
        if bld_id == "papyrus_workshop":
            return b
        if fallback.is_empty():
            fallback = b
    return fallback

# The recipe rows are the HBoxContainers of the tooltip: the bullet + the name
# label + the "resources -> result" entry. Other bulleted rows of the tooltip
# ("Consumes:", "Extra materials:") have only two children and are skipped.
func _recipe_rows(content: Node) -> Array:
    var rows: Array = []
    for child in content.get_children():
        if not (child is HBoxContainer) or child.get_child_count() != 3:
            continue
        var second = child.get_child(1)
        var third = child.get_child(2)
        if second is Label and (second as Label).text.ends_with(":") and third is HBoxContainer:
            rows.append(child)
    return rows

# The first TextureRect (icon) under the node, or null.
func _first_icon(node: Node) -> TextureRect:
    for child in node.get_children():
        if child is TextureRect:
            return child
        var nested := _first_icon(child)
        if nested != null:
            return nested
    return null

# The width of the label text in pixels for the font it is drawn with — the same
# measurement the tooltip uses to size the name column.
func _measure(label: Label) -> float:
    var font = label.get_theme_font("font")
    if font == null:
        font = ThemeDB.fallback_font
    return font.get_string_size(
        label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x

func _finish(main_map, state: Dictionary, code: int = -1) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    quit(code if code >= 0 else (1 if state["failed"] else 0))

func check(cond: bool, msg: String, state: Dictionary):
    if cond:
        print("OK: ", msg)
    else:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
