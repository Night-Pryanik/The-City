# Headless test for splitting the hex tooltip into a basic and an extended one:
#   godot --headless --path . --script res://tests/test_hex_tooltip_split.gd
#
# The rule under test: the ordinary tooltip answers the question "what is on this
# hex" (terrain, resource, improvement), while the hex properties — quality, feed
# consumption, pasture occupancy, fresh water access — and all the production
# live in the extended block, which appears after a hover delay. The left
# column of the control panel shows everything at once and therefore keeps the
# properties.
#
# Checks:
#   1. BASIC TOOLTIP. There is a terrain, a resource and an improvement; not a single property.
#   2. LEFT PANEL COLUMN. The same properties are in place — otherwise the change would have
#      emptied the control panel.
#   3. EXTENDED BLOCK. The same properties are in it, and it does NOT contain the deleted
#      base block "Once built ... will produce".
#   4. The "whether to show" CHECK matches the non-emptiness of the block.
#   5. REFRESH. The periodic refresh of the contents (it runs over the pastures) does not
#      wipe the already shown extended block and does not append the properties to the basic one.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Markers of the property lines in the English source text. The test checks what
# the player sees.
const PROPERTY_MARKERS := ["Quality:", "Fresh water access", "Feed consumption",
        "Fill level", "Fill time", "Herd"]
# The pasture occupancy: which exact line appears depends on whether a worker is
# present (full / current percentage / time to full).
const FILL_MARKERS := ["Fill level", "Fill time", "Herd"]

var _gdata = null
var _mh = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    # The autoloads (GameData/MapHelpers) are unavailable at the compile stage of
    # this file in --script mode — we fetch them through the scene tree and load().
    _gdata = get_root().get_node("GameData")
    _mh = load("res://scripts/map_helpers.gd")

    var res_id := _find_pasture_resource_id()
    check(not res_id.is_empty(),
            "the data needs a resource with feed and gradual filling (a pasture)",
            state)
    if res_id.is_empty():
        _finish(main_map, state)
        return
    var res_data: Dictionary = _gdata.raw_resources.get(res_id, {})
    var quality_id := _pick_quality_id()

    # A hex in the Ring of Influence: the properties are shown only on claimed land.
    # First we look for a hex WITH water: otherwise the water line would not appear, and
    # there would be nothing to check it with.
    var spot := _find_hex_in_influence(main_map, true)
    var has_water := not spot.is_empty()
    if spot.is_empty():
        # On this map there is no hex with water in the ring: we take any hex and honestly
        # do not check the water line.
        spot = _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "a hex in the Ring of Influence is needed for the check", state)
    if spot.is_empty():
        _finish(main_map, state)
        return
    var row := int(spot.row)
    var col := int(spot.col)

    # We set up the scenario explicitly instead of waiting for a random map: the hex gets
    # an improvement, a resource and a quality — that is, exactly the case where the
    # basic tooltip used to grow to seven lines.
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["improvement"] = str(res_data.get("improved_by", "pasture"))
    tile["resource"] = res_id
    tile["quality"] = quality_id
    tile["fill_time"] = float(res_data.get("time_to_mature", 40.0)) * 0.5

    var tooltip = main_map.map_tooltip

    # --- 1. Basic tooltip: only terrain, resource, improvement ---
    main_map.update_tooltip_text(row, col)
    var tip_text: String = str(main_map.tooltip_text_label.text)
    check(tip_text.contains("Terrain:") and tip_text.contains("Resource:")
            and tip_text.contains("Improvement:"),
            "the basic tooltip must contain terrain, resource and improvement (got: %s)"
                    % tip_text, state)
    _check_no_properties(tip_text, "basic tooltip", state)

    # --- 2. Left column of the control panel: everything at once ---
    var panel_info: Dictionary = tooltip.build_hex_info(row, col, main_map.tile_data,
            main_map.city_row, main_map.city_col)
    var panel_text: String = str(panel_info.get("text", ""))
    check(panel_text.contains("Quality:"),
            "the resource quality must remain in the left column of the panel (got: %s)"
                    % panel_text, state)
    check(panel_text.contains("Feed consumption"),
            "the feed consumption must remain in the left column of the panel (got: %s)"
                    % panel_text, state)
    check(_has_any(panel_text, FILL_MARKERS),
            "the left column of the panel must have the pasture occupancy (got: %s)"
                    % panel_text, state)

    # --- 3. Extended block: the properties moved into it ---
    var rows: Array = tooltip._collect_extended_block(row, col, main_map.tile_data)
    var ext_text := _rows_text(rows)
    check(ext_text.contains("Quality:"),
            "the extended block must have the resource quality (got: %s)" % ext_text,
            state)
    check(ext_text.contains("Feed consumption"),
            "the extended block must have the feed consumption (got: %s)" % ext_text,
            state)
    check(_has_any(ext_text, FILL_MARKERS),
            "the extended block must have the pasture occupancy (got: %s)"
                    % ext_text, state)
    if has_water:
        check(ext_text.contains("Fresh water access"),
                "the extended block must have the fresh water access (got: %s)"
                        % ext_text, state)
    else:
        print("NOTE: the hex has no fresh water access — the water line was not checked")
    # The base production block is deleted: a move, not a copy-paste.
    check(not ext_text.contains("will produce"),
            "the deleted base block \"will produce\" must not return (got: %s)"
                    % ext_text, state)

    # --- 4. The "whether to show" check matches the non-emptiness of the block ---
    check(tooltip.has_extended_tooltip_info(row, col, main_map.tile_data) == (not rows.is_empty()),
            "has_extended_tooltip_info must match the non-emptiness of the extended block",
            state)

    # --- 5. The refresh does not wipe the extended block ---
    main_map.update_extended_tooltip(row, col)
    var shown := _collect_text(tooltip._tooltip_products_container)
    check(shown.contains("Quality:"),
            "after being shown, the extended block must contain the quality (got: %s)"
                    % shown, state)
    # We change the quality: the line changes, the content key changes, the container
    # redraws — exactly the path that runs over the pastures in the game.
    # Without a real change, the early exit "nothing changed" would trigger,
    # and the check would pass without checking anything.
    tile["quality"] = _next_quality_id(quality_id)
    main_map.update_tooltip_text(row, col)
    var after_refresh := _collect_text(tooltip._tooltip_products_container)
    check(after_refresh.contains("Quality:"),
            "after the refresh the extended block must remain (got: %s)" % after_refresh,
            state)
    check(_count_occurrences(after_refresh, "Quality:") == 1,
            "there must be exactly one quality line (got: %s)" % after_refresh, state)
    _check_no_properties(str(main_map.tooltip_text_label.text),
            "basic tooltip after the refresh", state)

    # Resetting the binding (changing the hex / hiding the tooltip) — the block is gone.
    main_map.clear_extended_tooltip()
    main_map.update_tooltip_text(row, col)
    check(not _collect_text(tooltip._tooltip_products_container).contains("Quality:"),
            "after resetting the extended block there must be no property line", state)

    _finish(main_map, state)

# A resource that has BOTH feed, AND gradual filling, AND an improvement.
# We take it from the data instead of hardcoding "cows": the check must survive a rename.
func _find_pasture_resource_id() -> String:
    for id in _gdata.raw_resources.keys():
        var data: Dictionary = _gdata.raw_resources.get(id, {})
        if not data.has("produces"):
            continue
        if str(data.get("improved_by", "")) == "":
            continue
        if not _mh.is_growing_resource(data):
            continue
        if int(data.get("feed_consumption", 0)) <= 0:
            continue
        # A resource hidden behind a technology is not suitable: the player does not see it.
        if str(data.get("tech_reveal", "")) != "":
            continue
        return str(id)
    return ""

func _pick_quality_id() -> String:
    var levels: Array = _gdata.get_quality_levels()
    if levels.is_empty():
        return ""
    return str(levels[levels.size() - 1])

func _next_quality_id(current: String) -> String:
    var levels: Array = _gdata.get_quality_levels()
    for i in range(levels.size()):
        if str(levels[i]) == current:
            return str(levels[(i + levels.size() - 1) % levels.size()])
    return str(levels[0])

# The first free hex in the Ring of Influence: dry, known, without an improvement,
# a town or someone else's territory.
func _find_hex_in_influence(main_map, prefer_water: bool = false) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if prefer_water and str(_mh.get_hex_water_access(row, col,
                    main_map.tile_data, main_map.map_rows, main_map.map_cols)) == "":
                continue
            if tile.get("has_town", false) or tile.get("in_town_influence", false):
                continue
            if not main_map.is_hex_known(row, col):
                continue
            if _mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if row == main_map.city_row and col == main_map.city_col:
                continue
            return {"row": row, "col": col}
    return {}

func _rows_text(rows: Array) -> String:
    var parts: Array[String] = []
    for item in rows:
        if not (item is Dictionary):
            continue
        if item.has("text"):
            parts.append(str(item["text"]))
        if item.has("name"):
            parts.append(str(item["name"]))
    return "\n".join(parts)

func _collect_text(node: Node) -> String:
    if node == null:
        return ""
    var parts: Array[String] = []
    if node is Label:
        parts.append((node as Label).text)
    elif node is RichTextLabel:
        parts.append(str((node as RichTextLabel).text))
    for child in node.get_children():
        parts.append(_collect_text(child))
    return "\n".join(parts)

func _check_no_properties(text: String, where: String, state: Dictionary) -> void:
    for marker in PROPERTY_MARKERS:
        check(not text.contains(marker),
                "in the %s there must be no property line \"%s\" (got: %s)"
                        % [where, marker, text], state)

func _has_any(text: String, markers: Array) -> bool:
    for marker in markers:
        if text.contains(marker):
            return true
    return false

func _count_occurrences(text: String, sub: String) -> int:
    if sub.is_empty():
        return 0
    var count := 0
    var pos := text.find(sub)
    while pos != -1:
        count += 1
        pos = text.find(sub, pos + sub.length())
    return count

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("HEX TOOLTIP SPLIT TEST FAILED")
        quit(1)
    else:
        print("HEX TOOLTIP SPLIT TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
