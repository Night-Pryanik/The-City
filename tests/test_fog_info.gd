# Headless test for the rule "a hex in the fog of war gives away no information":
#   godot --headless --path . --script res://tests/test_fog_info.gd
#
# Checked against the live data of the real MainMap scene (a new game):
#   1. main_map.is_hex_in_fog(): the city hex and the scouted hexes are not fog;
#      an unexplored hex of the Region is not fog (the Region is visible on the
#      map, its terrain is known, and scouting reveals the resources); an
#      unexplored hex outside the Region is fog, and "Cartography" alone does not
#      lift it.
#   2. The left column of the control panel for a fog hex shows the placeholder
#      "Area not scouted" and does NOT show the terrain; after scouting the
#      information appears.
#   3. main_map.update_tooltip_text() writes nothing for a fog hex (a safety net
#      for the public entry point; the main gate is in InputHandler).
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like an eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var cp = main_map.control_panel
    # The autoloads (GameData/CityData) are not available at the compile time of
    # this file in --script mode — they are read through the scene tree at runtime.
    var game_data = get_root().get_node("GameData")

    # --- 1. The fog predicate ---
    check(not main_map.is_hex_in_fog(main_map.city_row, main_map.city_col),
        "the city hex cannot be in the fog of war", state)

    var region_hex = _find_hex(main_map, true)
    check(region_hex != null, "no unexplored hex of the Region was found", state)
    if region_hex != null:
        check(not main_map.is_hex_in_fog(region_hex.row, region_hex.col),
            "an unexplored hex of the Region is not fog of war (the Region is visible on the map)", state)

    var fog_hex = _find_hex(main_map, false)
    check(fog_hex != null, "no fog-of-war hex was found", state)
    if fog_hex == null:
        _finish(main_map, state)
        return

    check(main_map.is_hex_in_fog(fog_hex.row, fog_hex.col),
        "an unexplored hex outside the Region must be fog of war", state)
    city.unlocked_technologies.append("cartography")
    check(main_map.is_hex_in_fog(fog_hex.row, fog_hex.col),
        "\"Cartography\" must not lift the fog from a hex — scouting reveals it", state)

    # --- 2. The left column of the panel: a placeholder instead of information ---
    main_map.select_hex(fog_hex.row, fog_hex.col)
    cp._refresh()
    var info_text: String = cp._info_label.text
    check(info_text.contains("not scouted"),
        "the left column of the panel must show a placeholder for a fog hex (got: %s)"
            % info_text, state)
    var tile: Dictionary = main_map.tile_data[fog_hex.row][fog_hex.col]
    var terrain_name: String = game_data.terrains.get(tile.terrain, {}).get("name", tile.terrain)
    check(not info_text.contains(terrain_name),
        "the placeholder must not reveal the terrain type (%s)" % terrain_name, state)
    check(not info_text.contains("Terrain:"),
        "the placeholder must not contain the \"Terrain:\" line", state)

    # Scout the hex — the information appears.
    main_map.tile_data[fog_hex.row][fog_hex.col]["is_explored"] = true
    check(not main_map.is_hex_in_fog(fog_hex.row, fog_hex.col),
        "a scouted hex cannot be in the fog of war", state)
    main_map.select_hex(fog_hex.row, fog_hex.col)
    cp._refresh()
    var revealed_text: String = cp._info_label.text
    check(revealed_text.contains("Terrain:"),
        "after scouting the left column must show the terrain", state)

    # --- 3. The update_tooltip_text safety net: it writes nothing for fog ---
    main_map.tile_data[fog_hex.row][fog_hex.col]["is_explored"] = false
    var tooltip_label = main_map.tooltip_text_label
    tooltip_label.text = "SENTINEL"
    main_map.update_tooltip_text(fog_hex.row, fog_hex.col)
    check(tooltip_label.text == "SENTINEL",
        "update_tooltip_text() must not change the tooltip content for a fog hex", state)

    _finish(main_map, state)

# The first unexplored hex: in the Region (in_region = true) or in the fog of war
# (in_region = false). The influence rings of foreign towns are skipped, to take
# an "ordinary" hex.
func _find_hex(main_map, in_region: bool):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("is_explored", false)):
                continue
            if main_map.is_valid_hex(row, col) != in_region:
                continue
            return {"row": row, "col": col}
    return null

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("FOG INFO TEST FAILED")
        quit(1)
    else:
        print("FOG INFO TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
