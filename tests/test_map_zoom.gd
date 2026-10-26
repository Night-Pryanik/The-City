# Headless test for the smooth zoom of the map.
#   godot --headless --path . --script res://tests/test_map_zoom.gd
#
# The map keeps drawing at HEX_RADIUS in its own LOCAL pixels; the zoom is a CanvasItem
# scale on MapRenderer. Everything that converts between the screen and the world has to
# know about it, and this test pins exactly those conversions:
#   1. The wheel moves the TARGET zoom and the animation reaches it, frame by frame.
#   2. The hex under the cursor stays under the cursor for the whole gesture.
#   3. The zoom stops at ZOOM_MIN / ZOOM_MAX.
#   4. Picking a hex works at a zoom other than 1 (the screen is local * zoom).
#   5. The culling rectangle grows when zoomed out (viewport / zoom), otherwise the map
#      would end in a dead band at the right and the bottom edge.
#   6. The scroll speed is set in SCREEN pixels: a zoomed-out map travels further in the
#      world for the same cursor distance.
#   7. A gesture at the border of the reachable area keeps the clamp of the scroll: the
#      shift the animation carries never leaves the boundary, so the settle cannot jump.
#   8. A zoom-out gesture draws the strip the animation is about to uncover: the transform
#      moves the screen away from the position the drawing was baked for, so the culling
#      rectangle must include the endpoint of the gesture.
#
# The viewport of a headless run is square and much smaller than the game window, so the
# checks use the zoom-independent invariants and never the absolute layout of the map.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    for _i in range(4):
        await process_frame
    # The cursor of a headless run sits at (0,0), inside the edge-scroll margin, so the
    # map would crawl on every handle_process() call. It is switched off AFTER the frames:
    # in --script mode _ready() (and with it _load_settings) runs on the FIRST frame and
    # would otherwise put the setting back.
    main_map.use_edge_scrolling = false

    if WATCHDOG.wants_case("wheel"):
        await _test_wheel(state, main_map)
    if WATCHDOG.wants_case("anchor"):
        await _test_anchor(state, main_map)
    if WATCHDOG.wants_case("clamp"):
        _test_clamp(state, main_map)
    if WATCHDOG.wants_case("picking"):
        await _test_picking(state, main_map)
    if WATCHDOG.wants_case("culling"):
        _test_culling(state, main_map)
    if WATCHDOG.wants_case("centering"):
        _test_centering(state, main_map)
    if WATCHDOG.wants_case("scroll_speed"):
        _test_scroll_speed(state, main_map)
    if WATCHDOG.wants_case("edge_clamp"):
        await _test_edge_clamp(state, main_map)
    if WATCHDOG.wants_case("coverage"):
        await _test_zoom_out_coverage(state, main_map)

    _finish(state)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("MAP ZOOM TEST FAILED")
        quit(1)
    else:
        print("MAP ZOOM TEST OK")
        quit(0)

# -------------------------------------------------------
# 1. The wheel drives the target, the animation catches up
# -------------------------------------------------------
func _test_wheel(state: Dictionary, main_map) -> void:
    main_map.set_zoom(1.0)
    var ih = main_map.input_handler
    var anchor: Vector2 = main_map.map_renderer._get_viewport_size() / 2.0

    var wheel := InputEventMouseButton.new()
    wheel.button_index = MOUSE_BUTTON_WHEEL_UP
    wheel.pressed = true
    wheel.position = anchor
    wheel.global_position = anchor
    ih._handle_mouse_button(wheel)

    check(is_equal_approx(main_map.zoom_target, main_map.ZOOM_STEP),
        "one notch of the wheel must move the target zoom by ZOOM_STEP (got %.4f)"
            % main_map.zoom_target, state)
    check(is_equal_approx(main_map.zoom, 1.0),
        "the wheel must not snap the zoom, the animation owns the current value (got %.4f)"
            % main_map.zoom, state)

    # A single frame must not cover the whole distance: that would be a snap, not a smooth
    # zoom, and the eye would see a jump.
    ih.handle_process(1.0 / 60.0)
    check(main_map.zoom > 1.0 and main_map.zoom < main_map.zoom_target,
        "one frame must move the zoom part of the way (%.4f -> %.4f)"
            % [1.0, main_map.zoom], state)

    for _i in range(60):
        ih.handle_process(1.0 / 60.0)
    check(is_equal_approx(main_map.zoom, main_map.zoom_target),
        "the animation must reach the target (%.4f vs %.4f)"
            % [main_map.zoom, main_map.zoom_target], state)
    check(is_equal_approx(main_map.map_renderer.scale.x, main_map.zoom)
            and is_equal_approx(main_map.map_renderer.scale.y, main_map.zoom),
        "the renderer must be scaled by the zoom (scale %s, zoom %.4f)"
            % [str(main_map.map_renderer.scale), main_map.zoom], state)

    # A second notch accumulates on the target, not on the value the animation has reached.
    var before: float = main_map.zoom_target
    ih._handle_mouse_button(wheel)
    check(main_map.zoom_target > before,
        "a second notch must accumulate on the target (%.4f -> %.4f)"
            % [before, main_map.zoom_target], state)

# -------------------------------------------------------
# 2. The point under the cursor stays under the cursor
# -------------------------------------------------------
func _test_anchor(state: Dictionary, main_map) -> void:
    main_map.set_zoom(1.0)
    var ih = main_map.input_handler
    var row: int = main_map.city_row
    var col: int = main_map.city_col
    main_map.center_on_hex(row, col)
    await process_frame

    var anchor: Vector2 = _hex_screen(main_map, row, col)
    main_map.zoom_by(1.25, anchor)
    for _i in range(60):
        ih.handle_process(1.0 / 60.0)

    var moved: Vector2 = _hex_screen(main_map, row, col)
    check(moved.distance_to(anchor) < 0.5,
        "the hex under the cursor must not slide away (was %s, became %s, zoom %.4f)"
            % [str(anchor), str(moved), main_map.zoom], state)
    check(main_map.zoom > 1.0,
        "the gesture must actually zoom in (got %.4f)" % main_map.zoom, state)

# -------------------------------------------------------
# 3. The limits
# -------------------------------------------------------
func _test_clamp(state: Dictionary, main_map) -> void:
    main_map.set_zoom(1.0)
    for _i in range(20):
        main_map.zoom_by(0.5, Vector2.ZERO)
    check(is_equal_approx(main_map.zoom_target, main_map.ZOOM_MIN),
        "the target must stop at ZOOM_MIN (got %.4f, expected %.4f)"
            % [main_map.zoom_target, main_map.ZOOM_MIN], state)

    for _i in range(20):
        main_map.zoom_by(2.0, Vector2.ZERO)
    check(is_equal_approx(main_map.zoom_target, main_map.ZOOM_MAX),
        "the target must stop at ZOOM_MAX (got %.4f, expected %.4f)"
            % [main_map.zoom_target, main_map.ZOOM_MAX], state)

    main_map.set_zoom(0.01)
    check(is_equal_approx(main_map.zoom, main_map.ZOOM_MIN),
        "set_zoom must clamp a value below the range (got %.4f)" % main_map.zoom, state)
    main_map.set_zoom(99.0)
    check(is_equal_approx(main_map.zoom, main_map.ZOOM_MAX),
        "set_zoom must clamp a value above the range (got %.4f)" % main_map.zoom, state)

# -------------------------------------------------------
# 4. Picking a hex at a zoom other than 1
# -------------------------------------------------------
func _test_picking(state: Dictionary, main_map) -> void:
    var ih = main_map.input_handler
    main_map.set_zoom(0.7)
    var row: int = main_map.city_row
    var col: int = main_map.city_col
    main_map.center_on_hex(row, col)
    await process_frame

    # The centre of the hex and a NEIGHBOUR: a wrong conversion usually keeps the middle
    # of the screen right and drifts towards the edges, so one hex is not enough.
    var probes := [Vector2i(row, col), Vector2i(row, col + 1), Vector2i(row + 1, col)]
    for probe in probes:
        var screen: Vector2 = _hex_screen(main_map, probe.x, probe.y)
        var hex = ih._pixel_to_hex(screen.x, screen.y)
        check(hex != null,
            "the centre of the hex (%d,%d) must hit a hex at zoom %.2f"
                % [probe.x, probe.y, main_map.zoom], state)
        if hex == null:
            continue
        check(hex.row == probe.x and hex.col == probe.y,
            "the centre of the hex (%d,%d) must hit itself, got (%d,%d) at zoom %.2f"
                % [probe.x, probe.y, hex.row, hex.col, main_map.zoom], state)

# -------------------------------------------------------
# 5. The culling area follows the zoom
# -------------------------------------------------------
func _test_culling(state: Dictionary, main_map) -> void:
    var renderer = main_map.map_renderer
    var viewport_size: Vector2 = renderer._get_viewport_size()

    main_map.set_zoom(1.0)
    var normal: Rect2 = renderer._get_screen_rect()
    check(is_equal_approx(normal.size.x, viewport_size.x)
            and is_equal_approx(normal.size.y, viewport_size.y),
        "at zoom 1 the culling rectangle must equal the viewport (got %s, viewport %s)"
            % [str(normal.size), str(viewport_size)], state)

    main_map.set_zoom(main_map.ZOOM_MIN)
    var wide: Rect2 = renderer._get_screen_rect()
    check(wide.size.x > normal.size.x and wide.size.y > normal.size.y,
        "zoomed out the culling rectangle must grow (%s -> %s)"
            % [str(normal.size), str(wide.size)], state)
    check(is_equal_approx(wide.size.x, viewport_size.x / main_map.ZOOM_MIN),
        "the culling rectangle must be viewport / zoom (got %.2f, expected %.2f)"
            % [wide.size.x, viewport_size.x / main_map.ZOOM_MIN], state)
    main_map.set_zoom(1.0)

# -------------------------------------------------------
# 6. A zoom restored from the settings still centres the Region
# -------------------------------------------------------
# The offsets centre the Region in the LOCAL pixels of the map, so at a zoom other than 1
# they must be computed for a viewport / zoom window — otherwise a saved zoom opens with
# the map pressed into the top left corner.
func _test_centering(state: Dictionary, main_map) -> void:
    var viewport_size: Vector2 = main_map.map_renderer._get_viewport_size()

    # The bounding box of the Region the way MapHelpers.calc_offsets builds it: a square
    # of the hex radius around every centre.
    var min_x: float = INF
    var max_x: float = -INF
    var min_y: float = INF
    var max_y: float = -INF
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var center: Vector2 = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
            min_x = minf(min_x, center.x)
            max_x = maxf(max_x, center.x)
            min_y = minf(min_y, center.y)
            max_y = maxf(max_y, center.y)
    var region_center: Vector2 = Vector2((min_x + max_x) / 2.0, (min_y + max_y) / 2.0)

    for zoom in [1.0, main_map.ZOOM_MIN, main_map.ZOOM_MAX]:
        main_map.set_zoom(zoom)
        main_map._calc_offsets()
        main_map.scroll_offset = Vector2.ZERO
        var on_screen: Vector2 = (region_center
                + Vector2(main_map.offset_x, main_map.offset_y)) * zoom
        check(on_screen.distance_to(viewport_size / 2.0) < 0.5,
            "at zoom %.2f the Region must stay in the middle of the screen (got %s, expected %s)"
                % [zoom, str(on_screen), str(viewport_size / 2.0)], state)

    main_map.set_zoom(1.0)
    main_map._calc_offsets()

# -------------------------------------------------------
# 7. The scroll speed is a SCREEN speed
# -------------------------------------------------------
func _test_scroll_speed(state: Dictionary, main_map) -> void:
    var ih = main_map.input_handler

    main_map.set_zoom(1.0)
    main_map.scroll_offset = Vector2.ZERO
    ih._apply_scroll(Vector2(100.0, 0.0))
    check(is_equal_approx(main_map.scroll_offset.x, 100.0),
        "at zoom 1 a screen scroll of 100 px must move the map by 100 (got %.2f)"
            % main_map.scroll_offset.x, state)

    main_map.set_zoom(main_map.ZOOM_MIN)
    main_map.scroll_offset = Vector2.ZERO
    ih._apply_scroll(Vector2(100.0, 0.0))
    check(is_equal_approx(main_map.scroll_offset.x, 100.0 / main_map.ZOOM_MIN),
        "zoomed out the same screen scroll must cover more of the world (got %.2f, expected %.2f)"
            % [main_map.scroll_offset.x, 100.0 / main_map.ZOOM_MIN], state)
    main_map.set_zoom(1.0)

# -------------------------------------------------------
# 8. A gesture at the edge of the reachable area
# -------------------------------------------------------
# The animation moves the map with the transform of the renderer and folds the shift into
# the scroll offset only at the end. The shift has to obey the same clamp as the drag,
# otherwise a gesture started at the border would carry the map past the boundary for the
# whole animation and snap it back on the settle — a jump the eye catches at once.
func _test_edge_clamp(state: Dictionary, main_map) -> void:
    var ih = main_map.input_handler
    main_map.set_zoom(1.0)
    main_map._calc_offsets()
    var max_scroll: Vector2 = main_map.get_max_scroll()
    # The corner of the reachable area: there is nowhere to scroll to.
    main_map.scroll_offset = max_scroll
    await process_frame

    var row: int = main_map.region_end_row
    var col: int = main_map.region_end_col
    var anchor: Vector2 = _hex_screen(main_map, row, col)
    main_map.zoom_by(main_map.ZOOM_MIN / main_map.zoom, anchor)

    # The middle of the gesture: the shift the animation is carrying must already respect
    # the boundary, the scroll offset itself stays untouched until the settle.
    for _i in range(6):
        ih.handle_process(1.0 / 60.0)
    check(not is_equal_approx(main_map.zoom, main_map.zoom_target),
        "the gesture must still be running in the middle of the check", state)
    var carried: Vector2 = main_map.map_renderer.position / main_map.zoom \
            - Vector2(main_map.offset_x, main_map.offset_y)
    check(absf(carried.x) <= max_scroll.x + 0.5 and absf(carried.y) <= max_scroll.y + 0.5,
        "the animation must not carry the map beyond the reachable area (%s, limit %s)"
            % [str(carried), str(max_scroll)], state)

    # The settle folds the carried shift into the scroll offset: the map must not move.
    var before: Vector2 = _hex_screen(main_map, row, col)
    main_map._settle_zoom()
    var after: Vector2 = _hex_screen(main_map, row, col)
    check(after.distance_to(before) < 0.5,
        "the settle must not move the map (%.2f px)" % after.distance_to(before), state)

    for _i in range(120):
        ih.handle_process(1.0 / 60.0)
    check(is_equal_approx(main_map.zoom, main_map.ZOOM_MIN),
        "the gesture must reach ZOOM_MIN (got %.4f)" % main_map.zoom, state)
    check(absf(main_map.scroll_offset.x) <= max_scroll.x + 0.5
            and absf(main_map.scroll_offset.y) <= max_scroll.y + 0.5,
        "the scroll must stay inside the reachable area (%s, limit %s)"
            % [str(main_map.scroll_offset), str(max_scroll)], state)

    main_map.set_zoom(1.0)
    main_map._calc_offsets()
    main_map.scroll_offset = Vector2.ZERO

# -------------------------------------------------------
# 8. The drawing covers the strip a zoom-out uncovers
# -------------------------------------------------------
# The map is recorded once for the whole reachable area of the widest zoom (ZOOM_MIN),
# therefore the visible world rectangle stays inside the drawn one on every animation frame,
# and neither the animation nor the settle re-records the map.
func _test_zoom_out_coverage(state: Dictionary, main_map) -> void:
    var renderer = main_map.map_renderer
    var ih = main_map.input_handler
    var viewport: Vector2 = renderer._get_viewport_size()

    main_map.set_zoom(1.0)
    main_map._calc_offsets()
    main_map.scroll_offset = Vector2.ZERO
    await process_frame

    # A big jump: every notch in one frame, straight to ZOOM_MIN, with the cursor away
    # from the origin so the transform carries the map by a large shift.
    var anchor: Vector2 = viewport * 0.85
    var draw_calls_before: int = renderer.draw_calls
    for _i in range(20):
        main_map.zoom_by(1.0 / main_map.ZOOM_STEP, anchor)
    check(is_equal_approx(main_map.zoom_target, main_map.ZOOM_MIN),
        "the gesture must reach ZOOM_MIN before the check (got %.4f)"
            % main_map.zoom_target, state)

    var drawn: Rect2 = renderer._get_draw_rect().grow(1.0)
    var frames: int = 0
    for _i in range(120):
        ih.handle_process(1.0 / 60.0)
        if is_equal_approx(main_map.zoom, main_map.zoom_target):
            break
        frames += 1
        var visible := Rect2(
                -renderer.position / main_map.zoom,
                viewport / main_map.zoom)
        check(drawn.encloses(visible),
            "the drawing of the gesture must cover the screen on every animation frame "
                + "(frame %d, zoom %.3f, position %s, visible %s, drawn %s)"
                % [frames, main_map.zoom, str(renderer.position), str(visible), str(drawn)],
            state)
        if not drawn.encloses(visible):
            break
    check(frames > 0, "the animation must have run at least one frame after the drawing",
        state)
    check(renderer.draw_calls == draw_calls_before,
        "the zoom gesture must not re-record the map (draws during the gesture: %d)"
            % (renderer.draw_calls - draw_calls_before), state)

    main_map.set_zoom(1.0)
    main_map._calc_offsets()
    main_map.scroll_offset = Vector2.ZERO

# The screen position of the centre of a hex: the map is drawn in world coordinates and the
# renderer places them, so screen = world * zoom + position.
func _hex_screen(main_map, row: int, col: int) -> Vector2:
    var world: Vector2 = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    return world * main_map.zoom + main_map.map_renderer.position

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)
