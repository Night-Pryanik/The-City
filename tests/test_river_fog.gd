# Headless test for clipping rivers by the fog of war (map_renderer, PHASE 2.75):
#   godot --headless --path . --script res://tests/test_river_fog.gd
#
# Regression the test catches: rivers were drawn through the fog of war. A hex
# in the fog is not drawn at all (see _draw_hex), so a river on it
# hung in black emptiness. A river must break at the border of the explored
# area.
#
# Checked on the live MainMap (new game):
#   1. The clipping really triggers: for at least one river the fog discards
#      part of the smoothed points (otherwise the checks below are meaningless).
#   2. All surviving points lie over explored territory. The check is
#      INDEPENDENT of the local estimator _nearest_hex: the nearest hex
#      is found by a full scan of the map.
#   3. A point in explored territory is visible, a point far from it (in the fog)
#      is not.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks from the outside like
# eternal silence. Details in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var r = main_map.map_renderer
    var river_manager = main_map.get_node("RiverManager")
    var radius: float = main_map.HEX_RADIUS
    var all_rivers: Array = river_manager.get_main_rivers() + river_manager.get_tributaries()

    # --- 1. The fog really discards points for at least one river ---
    var dropped_total: int = 0
    var kept_total: int = 0
    for river in all_rivers:
        if river.size() < 2:
            continue
        var world_points = PackedVector2Array()
        for pt in river:
            world_points.append(Vector2(pt.x, pt.y))
        var smooth: PackedVector2Array = r._generate_natural_river(world_points, radius)
        var runs: Array = r._split_line_by_fog(smooth, radius)
        var kept: int = 0
        for run in runs:
            kept += run.size()
        dropped_total += smooth.size() - kept
        kept_total += kept
    check(dropped_total > 0,
        "the fog of war must discard part of the river points (discarded %d)" % dropped_total, state)
    check(kept_total > 0,
        "part of the rivers must remain visible (kept %d)" % kept_total, state)

    # --- 2. Surviving points lie over explored territory (independent check) ---
    var sample_step: int = max(1, kept_total / 200)
    var checked: int = 0
    var violations: Array = []
    for river in all_rivers:
        if river.size() < 2:
            continue
        var world_points = PackedVector2Array()
        for pt in river:
            world_points.append(Vector2(pt.x, pt.y))
        var smooth: PackedVector2Array = r._generate_natural_river(world_points, radius)
        var runs: Array = r._split_line_by_fog(smooth, radius)
        var counter: int = 0
        for run in runs:
            for pt in run:
                counter += 1
                if counter % sample_step != 0:
                    continue
                checked += 1
                if not _over_explored(main_map, pt, radius):
                    violations.append(pt)
    check(checked > 0, "at least a few points must be checked", state)
    check(violations.is_empty(),
        "surviving river points must not lie in the fog of war (violations: %d of %d)"
            % [violations.size(), checked], state)

    # --- 3. A point in the explored area is visible, a point deep in the fog is not ---
    var city_center: Vector2 = HexUtils.hex_center(main_map.city_row, main_map.city_col, radius)
    check(r._is_river_point_visible(city_center, radius),
        "a point at the map center (in the Region) must be visible", state)

    # A hex deep in the fog: itself in the fog and all its neighbours too (otherwise a point on its
    # edge would legitimately count as visible — a river flows along hex edges).
    var deep_fog: Vector2i = Vector2i(-1, -1)
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_hex_in_fog(row, col):
                continue
            var all_fog: bool = true
            for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
                if not main_map.is_hex_in_fog(n.row, n.col):
                    all_fog = false
                    break
            if all_fog:
                deep_fog = Vector2i(row, col)
                break
        if deep_fog.x >= 0:
            break
    check(deep_fog.x >= 0, "the map must contain a hex deep in the fog", state)
    if deep_fog.x >= 0:
        var fog_center: Vector2 = HexUtils.hex_center(deep_fog.x, deep_fog.y, radius)
        check(not r._is_river_point_visible(fog_center, radius),
            "a point deep in the fog must be hidden", state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("RIVER FOG TEST FAILED")
        quit(1)
    else:
        print("RIVER FOG TEST OK")
        quit(0)

# Independent check "a point over explored territory": the nearest hex
# is found by a FULL scan of the map (not the renderer's local _nearest_hex),
# then the hex itself and its neighbours are checked — a river flows along hex
# edges, so it is visible if it touches at least one drawn hex.
func _over_explored(main_map, pos: Vector2, radius: float) -> bool:
    var best_row: int = -1
    var best_col: int = -1
    var best_d: float = INF
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var d: float = HexUtils.hex_center(row, col, radius).distance_squared_to(pos)
            if d < best_d:
                best_d = d
                best_row = row
                best_col = col
    if not main_map.is_hex_in_fog(best_row, best_col):
        return true
    for n in HexUtils.get_neighbors_odd_r(best_row, best_col, main_map.map_rows, main_map.map_cols):
        if not main_map.is_hex_in_fog(n.row, n.col):
            return true
    return false

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
