# Headless test of the production display in the extended tooltip:
#   godot --headless --path . --script res://tests/test_production_display.gd
#
# The rule being checked: the production row shows the rate per second, which IS the
# resource's "produces" value. The player receives a continuous flow (main_map adds
# produces × multiplier × SIMULATION_TICK to storage every tick), so the number from
# the data is exactly what the player actually receives per second. There is no
# "per cycle" base and no production interval to divide by.
#
# Checks:
#   1. NON-GROWING RESOURCE. The rate equals the resource's produces value
#      (limestone: 10 → 10 units/sec), and the row has no base.
#   2. GROWING RESOURCE WITHOUT IMPROVEMENT. The "once built" hint shows the
#      FULL rate (the produces value), not 0: the herd only starts filling after
#      construction, so a zero fraction must not suppress the hint.
#   3. SINGLE FORMAT. Both resources have a row of the same structure — name and
#      rate, without the base.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    # Autoloads are taken as tree nodes: in --script mode the names GameData/CityData
    # are not yet available at the compile stage of this file.
    _gdata = get_root().get_node("GameData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var tooltip = main_map.map_tooltip
    var spot := _find_free_hex(main_map)
    check(not spot.is_empty(), "a free hex is needed for the check", state)
    if spot.is_empty():
        _finish(main_map, state)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["quality"] = "common"

    # --- 1. Non-growing resource: the rate is the produces value ---
    _gdata.raw_resources["test_stone"] = {
        "id": "test_stone", "name": "Test Stone", "type": "raw",
        "improved_by": "quarry", "produces": {"limestone": 10},
    }
    tile["resource"] = "test_stone"
    tile["improvement"] = null
    var stone_item := _product_item(tooltip, row, col, main_map, "limestone")
    check(not stone_item.is_empty(), "the limestone row must be in the production block", state)
    if not stone_item.is_empty():
        check(absf(float(stone_item.get("amount", 0.0)) - 10.0) < 0.001,
                "limestone rate = produces = 10 units/sec (got %.1f)"
                        % float(stone_item.get("amount", 0.0)), state)
        check(not _has_base_label(str(stone_item.get("name", ""))),
                "the limestone row must not have a base (got: %s)"
                        % stone_item.get("name", ""), state)

    # --- 2. Growing resource without improvement: hint = full rate ---
    _gdata.raw_resources["test_herd"] = {
        "id": "test_herd", "name": "Test Herd", "type": "raw",
        "improved_by": "pasture", "produces": {"raw_meat": 20},
        "feed_consumption": 50, "time_to_mature": 40.0,
    }
    tile["resource"] = "test_herd"
    tile["improvement"] = null
    tile["fill_time"] = 0.0
    var herd_item := _product_item(tooltip, row, col, main_map, "raw_meat")
    check(not herd_item.is_empty(), "the meat row must be in the production tooltip", state)
    if not herd_item.is_empty():
        check(float(herd_item.get("amount", 0.0)) > 0.0,
                "the \"once built\" hint must show the full rate, not 0 (got %.1f)"
                        % float(herd_item.get("amount", 0.0)), state)
        check(absf(float(herd_item.get("amount", 0.0)) - 20.0) < 0.001,
                "meat rate = produces = 20 units/sec (got %.1f)"
                        % float(herd_item.get("amount", 0.0)), state)
        check(not _has_base_label(str(herd_item.get("name", ""))),
                "the meat row must not have a base (got: %s)"
                        % herd_item.get("name", ""), state)

    # --- 3. Single format: neither resource has a base ---
    if not stone_item.is_empty() and not herd_item.is_empty():
        check(not _has_base_label(str(stone_item.get("name", "")))
                and not _has_base_label(str(herd_item.get("name", ""))),
                "both resources must show a row of the same format — without a base", state)

    _finish(main_map, state)

# The product row prod_id from the "Produces:" / "Once built ... will
# produce:" block for the hex (row, col). An empty dictionary means no row.
func _product_item(tooltip, row: int, col: int, main_map, prod_id: String) -> Dictionary:
    var label := str(_gdata.products.get(prod_id, {}).get("name", prod_id))
    var products: Array = tooltip._collect_extended_production(row, col, main_map.tile_data)
    for item in products:
        if str(item.get("type", "")) != "product":
            continue
        if str(item.get("name", "")).begins_with(label):
            return item
    return {}

# The row name still contains the base label.
func _has_base_label(item_name: String) -> bool:
    return item_name.contains("base ")

func _find_free_hex(main_map) -> Dictionary:
    for r in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for c in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[r][c]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("in_town_influence", false):
                continue
            if r == main_map.city_row and c == main_map.city_col:
                continue
            return {"row": r, "col": c}
    return {}

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("PRODUCTION DISPLAY TEST FAILED")
        quit(1)
    else:
        print("PRODUCTION DISPLAY TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
