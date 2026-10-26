# Headless test for river rendering (map_renderer, PHASE 2.75):
#   godot --headless --path . --script res://tests/test_river_rendering.gd
#
# The map is drawn in world coordinates and the view is applied by the transform of the
# renderer, so the river geometry does not depend on the scroll offset: it is built once for
# the whole scrollable area (main_map.get_scout_reach_bounds) and replayed while the map pans.
#
# Checked against live data of the real MainMap scene (new game):
#   1. River data is intact: there are main rivers/tributaries and hexes with
#      river_edges.
#   2. The drawn rectangle is in world coordinates, has a positive size and covers the city.
#   3. On the live map at least one river actually yields non-empty lines, and all their
#      points lie inside the drawn rectangle (clipping, not discarding).
#   4. Scrolling does not rebuild the geometry and does not change it.
#   5. A river entirely outside the drawn rectangle is not collected (culling still works).
#   6. The drawn rectangle covers the whole reachable map.
#   7. A fog change (invalidate_town_influence_cache) rebuilds the geometry once.
#
# The whole map is revealed before the rendering checks: the rivers are clipped by
# the fog of war (see _collect_river_segments), and the explored area of a fresh
# game covers only the vicinity of the city. Whether a river flows through it
# depends on the random seed of the generated map — on some seeds no river point
# is visible at all, and the checks below would fail on a correctly working
# renderer. The fog itself is covered by test_river_fog, so here the reveal only
# makes the precondition ("a river is drawn") deterministic.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
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

    # --- 1. River data is in place (otherwise the rendering checks are meaningless) ---
    var main_rivers: Array = river_manager.get_main_rivers()
    var tributaries: Array = river_manager.get_tributaries()
    check(not main_rivers.is_empty(),
        "the live map must have at least one main stream", state)
    check(not main_rivers.is_empty() or not tributaries.is_empty(),
        "the live map must have rivers", state)

    var edge_hexes: int = 0
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile != null and not tile.get("river_edges", []).is_empty():
                edge_hexes += 1
    check(edge_hexes > 0,
        "rivers must leave river_edges in hexes (an indirect sign of water)", state)

    # --- 1a. The whole map is revealed (see the header) ---
    main_map.debug_open_whole_map()

    # --- 2. The drawn rectangle is in world coordinates ---
    var draw_rect: Rect2 = r._get_draw_rect()
    check(draw_rect.size.x > 0.0 and draw_rect.size.y > 0.0,
        "the drawn rectangle must have a positive size (got %s)" % str(draw_rect.size), state)
    var city_center = HexUtils.hex_center(main_map.city_row, main_map.city_col, radius)
    check(draw_rect.has_point(city_center),
        "the drawn rectangle must cover the city (rect %s, city %s)"
            % [str(draw_rect), str(city_center)], state)

    # --- 3. At least one river is drawn, clipped to the drawn rectangle ---
    var all_rivers: Array = main_rivers + tributaries
    var drawn_rivers: int = 0
    var outside: Array = []
    var total_points: int = 0
    for river in all_rivers:
        var segments: Array = _segments(r, river, radius)
        if segments.is_empty():
            continue
        drawn_rivers += 1
        for seg in segments:
            total_points += seg["points"].size()
            outside.append_array(_points_outside([seg["points"]], draw_rect, radius))
    check(drawn_rivers > 0,
        "at least one river must be drawn (rivers with segments: %d)" % drawn_rivers, state)
    check(total_points > 0, "the drawn rivers must have points (got %d)" % total_points, state)
    check(outside.is_empty(),
        "points of a drawn river must lie inside the drawn rectangle (violators: %s)"
            % str(outside), state)

    # --- 4. Scrolling neither rebuilds nor changes the geometry ---
    r._river_frame_cache.clear()
    r._build_river_frame_cache(radius)
    var signature_before: Array = _signature(r)
    var rebuilds_before: int = r._river_frame_rebuilds
    var max_scroll: Vector2 = main_map.get_max_scroll()
    for i in range(12):
        var t: float = float(i) / 11.0
        main_map.scroll_offset = Vector2(
            lerpf(-max_scroll.x, max_scroll.x, t) * 0.9,
            lerpf(max_scroll.y, -max_scroll.y, t) * 0.9)
        main_map.apply_view_transform()
        r._build_river_frame_cache(radius)
    check(r._river_frame_rebuilds == rebuilds_before,
        "panning must not rebuild the river geometry (rebuilds %d)"
            % (r._river_frame_rebuilds - rebuilds_before), state)
    check(_signature(r) == signature_before,
        "panning must not change the drawn river geometry", state)
    main_map.scroll_offset = Vector2.ZERO
    main_map.apply_view_transform()

    # --- 5. Culling still works ---
    # A river entirely outside the scrollable area is not collected at all.
    var far_river: Array = []
    var far_x: float = draw_rect.end.x + 5000.0
    for i in range(6):
        far_river.append(Vector2(far_x + i * 100.0, 500.0 + i * 40.0))
    check(_segments(r, far_river, radius).is_empty(),
        "a river outside the drawn area must not be collected", state)

    # --- 6. The drawn rectangle covers the whole reachable map ---
    # With the whole map revealed and the scroll allowed over the whole map, the recorded
    # drawing must contain every hex: a pan to any reachable position shows no bare strip.
    var corners: Array = [
        Vector2i(0, 0),
        Vector2i(0, main_map.map_cols - 1),
        Vector2i(main_map.map_rows - 1, 0),
        Vector2i(main_map.map_rows - 1, main_map.map_cols - 1),
    ]
    var uncovered: Array = []
    for corner in corners:
        var center = HexUtils.hex_center(corner.x, corner.y, radius)
        if not draw_rect.has_point(center):
            uncovered.append(center)
    check(uncovered.is_empty(),
        "the drawn rectangle must cover every corner of the map (uncovered: %s)"
            % str(uncovered), state)

    # --- 7. A fog change drops the geometry, the next draw rebuilds it once ---
    r.invalidate_town_influence_cache()
    var before_rebuild: int = r._river_frame_rebuilds
    r._build_river_frame_cache(radius)
    check(r._river_frame_rebuilds == before_rebuild + 1,
        "a fog change must rebuild the river geometry once (rebuilds %d)"
            % (r._river_frame_rebuilds - before_rebuild), state)
    r._build_river_frame_cache(radius)
    check(r._river_frame_rebuilds == before_rebuild + 1,
        "a second draw with the same state must not rebuild again", state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("RIVER RENDERING TEST FAILED")
        quit(1)
    else:
        print("RIVER RENDERING TEST OK")
        quit(0)

func _segments(r, river: Array, radius: float) -> Array:
    return r._collect_river_segments(river, radius)

# The drawn geometry in a comparable form: the runs and their points.
func _signature(r) -> Array:
    var out: Array = []
    for key in r._river_frame_cache.keys():
        var runs: Array = []
        for seg in r._river_frame_cache[key]["segments"]:
            var pts: Array = []
            for pt in seg["points"]:
                pts.append(pt)
            runs.append(pts)
        out.append([key, runs])
    return out

# Polyline points that went beyond the drawn rectangle. The tolerance is the width of the
# drawn line: it has an outline and mentally goes slightly beyond the clipped rectangle.
func _points_outside(runs: Array, draw_rect: Rect2, radius: float) -> Array:
    var margin: float = 16.0 + radius
    var grown := Rect2(
        draw_rect.position - Vector2(margin, margin),
        draw_rect.size + Vector2(margin, margin) * 2.0
    )
    var bad: Array = []
    for run in runs:
        for pt in run:
            if not grown.has_point(pt):
                bad.append(pt)
    return bad

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
