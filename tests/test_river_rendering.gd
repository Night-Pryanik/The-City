# Headless test for river rendering (map_renderer, PHASE 2.75):
#   godot --headless --path . --script res://tests/test_river_rendering.gd
#
# The regression this test catches: river points get shifted by offset and from
# that moment live in SCREEN coordinates, but they were clipped against the
# rectangle Rect2(Vector2(-offset_x, -offset_y), ...), that is, against the
# WORLD window. When the map is centered (offset_x ~ -2280) the window drifted
# far off screen, and _clip_river_to_rect returned [] for every river — the
# rivers stayed in the data (river_edges, access to fresh water) but were not
# drawn.
#
# Checked against live data of the real MainMap scene (new game):
#   1. River data is intact: there are main rivers/tributaries and hexes with
#      river_edges.
#   2. The screen rectangle starts at zero screen coordinates — it must be in
#      the same system as the shifted points.
#   3. On the live map at least one river actually yields non-empty lines, and
#      all their points lie inside the screen (clipping to the screen, not
#      discarding).
#   4. Scrolling the map (scroll_offset) does not "kill" rendering: the same
#      river stays visible.
#   5. A river entirely off screen is not drawn (culling still works).
#
# The whole map is revealed before the rendering checks: the rivers are clipped by
# the fog of war (see _collect_river_segments), and the explored area of a fresh
# game covers only the vicinity of the city. Whether a river flows through it
# depends on the random seed of the generated map — on some seeds no river point
# is visible at all, and the checks below would fail on a correctly working
# renderer. The fog itself is covered by test_river_fog, so here the reveal only
# makes the precondition ("a river is on screen") deterministic.
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

    # --- 2. The screen rectangle — in screen coordinates ---
    var screen_rect: Rect2 = r._get_screen_rect()
    check(screen_rect.position == Vector2.ZERO,
        "the screen rectangle must start at zero screen coordinates", state)
    check(screen_rect.size.x > 0.0 and screen_rect.size.y > 0.0,
        "the screen size must be positive (got %s)" % str(screen_rect.size),
        state)

    # --- 3. At least one river is visible and clipped to the screen ---
    # The screen rectangle is padded by main_map.MAP_CACHE_MARGIN (as is the
    # render cache), so the loop iterates over scroll probes until the map is
    # positioned so that rivers fall into the frame.
    var all_rivers: Array = main_rivers + tributaries
    var visible_rivers: int = 0
    var outside: Array = []
    var probes: Array = _candidate_scrolls(main_map, all_rivers)
    for probe in probes:
        var visible_in_probe: int = 0
        var outside_in_probe: Array = []
        for river in all_rivers:
            var lines: Array = _lines(r, river, main_map, probe)
            if lines.is_empty():
                continue
            visible_in_probe += 1
            outside_in_probe.append_array(_points_outside(
                lines, screen_rect, main_map.MAP_CACHE_MARGIN))
        if visible_in_probe > visible_rivers:
            visible_rivers = visible_in_probe
            outside = outside_in_probe
    check(visible_rivers > 0,
        "at least one river must cross the screen (polylines: %d)" % visible_rivers, state)
    check(outside.is_empty(),
        "points of a drawn river must not go off screen (violators: %s)"
            % str(outside), state)

    # --- 4. Scrolling does not break rendering ---
    # The standard way of scrolling in the game is right-clicking a city button; we take
    # the same shift, but centered on a river instead of the city: the city is not
    # guaranteed to stand next to water, while the point of the check is the scroll
    # itself (a large non-zero offset), not the target of the camera.
    var scroll_target: Vector2 = Vector2.ZERO
    for river in all_rivers:
        if river.size() >= 2:
            scroll_target = river[river.size() / 2]
            break
    var scroll = - (scroll_target
        + Vector2(main_map.offset_x, main_map.offset_y) - r._get_viewport_size() / 2.0)
    var visible_after_scroll: int = 0
    for river in all_rivers:
        if not _lines(r, river, main_map, scroll).is_empty():
            visible_after_scroll += 1
    check(visible_after_scroll > 0,
        "after scrolling the rivers must stay visible (polylines: %d)"
            % visible_after_scroll, state)

    # --- 5. Culling still works ---
    # A river entirely off screen (in world coordinates far beyond the right
    # edge) must not yield a single line.
    var far_river: Array = []
    var far_x: float = screen_rect.size.x - main_map.offset_x + 5000.0
    for i in range(6):
        far_river.append(Vector2(far_x + i * 100.0, 500.0 + i * 40.0))
    check(_lines(r, far_river, main_map).is_empty(),
        "a river entirely off screen must not be drawn", state)

    # --- 6. The geometry cache is not rebuilt on every scroll frame ---
    # Rebuilding the cache (smoothing + clipping) is the most expensive part of
    # river rendering: it used to run on EVERY scroll frame. Now the geometry
    # lives until the map moves away from the remembered shift by more than
    # MAP_CACHE_MARGIN. We count the real rebuilds via the renderer counter and
    # compare with the number of frames: there must be MANY TIMES fewer
    # rebuilds.
    main_map.scroll_offset = Vector2.ZERO
    r.queue_redraw_for_scroll()
    r._flush_scroll_cache_invalidation()
    r._build_river_frame_cache(radius)          # build the cache for zero shift
    var rebuilds_before: int = r._river_frame_rebuilds
    # The step is deliberately smaller than the margin, the frames suffice for
    # several margins of scrolling: without the cache there would be a rebuild
    # on EVERY frame (= steps).
    var steps: int = 20
    var step_px: float = main_map.MAP_CACHE_MARGIN / 3.0
    for i in range(1, steps + 1):
        main_map.scroll_offset = Vector2(float(i) * step_px, 0.0)
        r.queue_redraw_for_scroll()
        r._flush_scroll_cache_invalidation()
        r._build_river_frame_cache(radius)
    var rebuilds: int = r._river_frame_rebuilds - rebuilds_before
    check(rebuilds < steps,
        "the river geometry cache must not be rebuilt on every scroll frame (rebuilds %d over %d frames)"
            % [rebuilds, steps], state)
    # Scrolling several margins forward must rebuild the cache (otherwise at the
    # new position rivers would be drawn using the old, already departed
    # clipping rectangle).
    var before_far: int = r._river_frame_rebuilds
    main_map.scroll_offset = Vector2(main_map.MAP_CACHE_MARGIN * 4.0, 0.0)
    r.queue_redraw_for_scroll()
    r._flush_scroll_cache_invalidation()
    r._build_river_frame_cache(radius)
    check(r._river_frame_rebuilds > before_far,
        "scrolling beyond the margin must rebuild the river geometry", state)

    # --- 7. The cache points are world-space, the shift is applied at draw time ---
    # Otherwise scrolling within the margin would show the river not where it is.
    r._river_frame_cache.clear()
    main_map.scroll_offset = Vector2.ZERO
    r.queue_redraw_for_scroll()
    r._flush_scroll_cache_invalidation()
    r._build_river_frame_cache(radius)
    var cache_offset_zero = r._river_frame_cache_offset
    check(cache_offset_zero.x == main_map.offset_x and cache_offset_zero.y == main_map.offset_y,
        "the cache must remember the shift it was built for (got %s, expected %s)"
            % [str(cache_offset_zero), str(Vector2(main_map.offset_x, main_map.offset_y))],
        state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("RIVER RENDERING TEST FAILED")
        quit(1)
    else:
        print("RIVER RENDERING TEST OK")
        quit(0)

# Probe map shifts: center the camera on the middle of each river. The render
# cache covers the screen with a MAP_CACHE_MARGIN pad, and outside it rivers are
# drawn only after a rebuild — the probes guarantee that at least one river
# falls into the frame.
func _candidate_scrolls(main_map, rivers: Array) -> Array:
    var out: Array = [Vector2.ZERO]
    for river in rivers:
        if river.is_empty():
            continue
        var mid: Vector2 = river[river.size() / 2]
        out.append(- (mid + Vector2(main_map.offset_x, main_map.offset_y)
            - main_map.map_renderer._get_viewport_size() / 2.0))
    return out

# Screen polylines for one river — exactly the path used by rendering
# (_draw_river_list -> _build_river_frame_cache. The result is reduced to the
# screen coordinates of the same shift as in the test.
func _lines(r, river: Array, main_map, extra_scroll: Vector2 = Vector2.ZERO) -> Array:
    var offset_x: float = main_map.offset_x + main_map.scroll_offset.x + extra_scroll.x
    var offset_y: float = main_map.offset_y + main_map.scroll_offset.y + extra_scroll.y
    var segments: Array = r._collect_river_segments(river, offset_x, offset_y, main_map.HEX_RADIUS)
    var out: Array = []
    for seg in segments:
        var line: PackedVector2Array = seg["points"]
        var shifted := PackedVector2Array()
        shifted.resize(line.size())
        for i in range(line.size()):
            shifted[i] = line[i] + Vector2(offset_x, offset_y)
        out.append(shifted)
    return out

# Polyline points that went beyond the render cache. The finished river lines
# are clipped by the screen rectangle WITH a PAD of main_map.MAP_CACHE_MARGIN
# (cache of screen size), so that is what is checked, not the bare screen. The
# tolerance is the width of the drawn line: it is drawn with an outline and
# mentally goes slightly beyond the clipped rectangle.
func _points_outside(lines: Array, screen_rect: Rect2, cache_margin: float) -> Array:
    var margin: float = 16.0 + cache_margin
    var grown := Rect2(
        screen_rect.position - Vector2(margin, margin),
        screen_rect.size + Vector2(margin, margin) * 2.0
    )
    var bad: Array = []
    for line in lines:
        for pt in line:
            if not grown.has_point(pt):
                bad.append(pt)
    return bad

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
