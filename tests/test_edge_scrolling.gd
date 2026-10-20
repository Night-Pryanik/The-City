# Headless test of the EDGE SCROLLING of the map — the cursor standing at the edge
# of the screen moves the map.
#   godot --headless --path . --script res://tests/test_edge_scrolling.gd
#
# Checks (live MainMap scene):
#   1. The cursor at the BOTTOM edge of the screen scrolls the map down. The control
#      panel is anchored there and covers the whole bottom edge, therefore this case
#      pins that the panel does not gate the scrolling: with the gate the downward
#      direction has no way to be reached at all.
#   2. The top edge still scrolls the map up (the other directions are not affected).
#   3. The interior of the panel is not a scroll zone: away from the screen edge the
#      panel only blocks the map, it does not move it.
#   4. The cursor in the middle of the screen does not move the map — the control of
#      the experiment: not every call of handle_process scrolls.
#   5. The setting switches the edge scrolling off.
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
    # The cursor of a headless run sits at (0,0), which is inside the margin of the
    # top left corner: the map would scroll while the scene is coming up.
    main_map.use_edge_scrolling = false
    for _i in range(4):
        await process_frame

    var ih = main_map.input_handler
    var panel = main_map.control_panel
    var vp_size: Vector2 = get_root().get_visible_rect().size

    # The panel is anchored to the BOTTOM edge of the screen; the offsets in the scene
    # are authored for the 1152x768 window of the project. The viewport of a headless
    # run is square (the 64x64 window of the run against the "expand" stretch), so the
    # panel is put back onto the bottom edge by hand — otherwise it would hang in the
    # middle of the screen and the case below would not reproduce the layout of the game.
    panel.offset_top = vp_size.y - panel.size.y
    panel.offset_bottom = vp_size.y
    await process_frame

    if WATCHDOG.wants_case("bottom_edge"):
        await _test_bottom_edge(state, main_map, ih, panel, vp_size)
    if WATCHDOG.wants_case("top_edge"):
        await _test_top_edge(state, main_map, ih, vp_size)
    if WATCHDOG.wants_case("panel_interior"):
        await _test_panel_interior(state, main_map, ih, panel, vp_size)
    if WATCHDOG.wants_case("middle"):
        await _test_middle(state, main_map, ih, vp_size)
    if WATCHDOG.wants_case("setting_off"):
        await _test_setting_off(state, main_map, ih, vp_size)

    _finish(state)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("EDGE SCROLLING TEST FAILED")
        quit(1)
    else:
        print("EDGE SCROLLING TEST OK")
        quit(0)

# -------------------------------------------------------
# 1. The bottom edge, over the control panel
# -------------------------------------------------------
func _test_bottom_edge(state: Dictionary, main_map, ih, panel, vp_size: Vector2) -> void:
    main_map.use_edge_scrolling = true
    await _set_cursor(Vector2(vp_size.x * 0.5, vp_size.y - 1.0))

    # The setup of the case: the cursor is really over the panel, and the panel really
    # reaches the bottom edge of the screen. Without this the case would be about an
    # ordinary screen edge and would prove nothing about the panel.
    var mouse_pos: Vector2 = main_map.get_global_mouse_position()
    check(panel.get_global_rect().has_point(mouse_pos),
            "the cursor must be over the control panel (cursor %s, panel %s)"
            % [str(mouse_pos), str(panel.get_global_rect())], state)
    check(is_equal_approx(panel.get_global_rect().end.y, vp_size.y),
            "the panel must reach the bottom edge of the screen (panel %s, viewport %s)"
            % [str(panel.get_global_rect()), str(vp_size)], state)

    var before: Vector2 = main_map.scroll_offset
    ih.handle_process(0.1)
    var after: Vector2 = main_map.scroll_offset
    check(after.y < before.y,
            "the bottom edge must scroll the map down (%s -> %s)" % [str(before), str(after)], state)
    check(is_equal_approx(after.x, before.x),
            "the bottom edge must not scroll the map sideways (%s -> %s)" % [str(before), str(after)], state)

# -------------------------------------------------------
# 2. The top edge
# -------------------------------------------------------
func _test_top_edge(state: Dictionary, main_map, ih, vp_size: Vector2) -> void:
    await _set_cursor(Vector2(vp_size.x * 0.5, 1.0))

    var before: Vector2 = main_map.scroll_offset
    ih.handle_process(0.1)
    var after: Vector2 = main_map.scroll_offset
    check(after.y > before.y,
            "the top edge must scroll the map up (%s -> %s)" % [str(before), str(after)], state)
    check(is_equal_approx(after.x, before.x),
            "the top edge must not scroll the map sideways (%s -> %s)" % [str(before), str(after)], state)

# -------------------------------------------------------
# 3. The interior of the panel
# -------------------------------------------------------
func _test_panel_interior(state: Dictionary, main_map, ih, panel, vp_size: Vector2) -> void:
    var rect: Rect2 = panel.get_global_rect()
    await _set_cursor(Vector2(vp_size.x * 0.5, rect.position.y + 5.0))

    var mouse_pos: Vector2 = main_map.get_global_mouse_position()
    check(rect.has_point(mouse_pos),
            "the cursor must be over the panel but away from the screen edge (cursor %s)" % str(mouse_pos), state)

    var before: Vector2 = main_map.scroll_offset
    ih.handle_process(0.1)
    check(main_map.scroll_offset == before,
            "the panel itself must not move the map (%s -> %s)"
            % [str(before), str(main_map.scroll_offset)], state)

# -------------------------------------------------------
# 4. The middle of the screen
# -------------------------------------------------------
func _test_middle(state: Dictionary, main_map, ih, vp_size: Vector2) -> void:
    await _set_cursor(vp_size * 0.5)

    var before: Vector2 = main_map.scroll_offset
    ih.handle_process(0.1)
    check(main_map.scroll_offset == before,
            "the middle of the screen must not move the map (%s -> %s)"
            % [str(before), str(main_map.scroll_offset)], state)

# -------------------------------------------------------
# 5. The setting
# -------------------------------------------------------
func _test_setting_off(state: Dictionary, main_map, ih, vp_size: Vector2) -> void:
    await _set_cursor(Vector2(vp_size.x * 0.5, vp_size.y - 1.0))

    main_map.use_edge_scrolling = false
    var before: Vector2 = main_map.scroll_offset
    ih.handle_process(0.1)
    check(main_map.scroll_offset == before,
            "with the setting off the screen edge must not move the map (%s -> %s)"
            % [str(before), str(main_map.scroll_offset)], state)
    main_map.use_edge_scrolling = true

# The cursor of a headless run does not move by itself, so it is fed through the input
# system. The position of an InputEvent is in WINDOW coordinates, and the window of a
# headless run is a scaled-down copy of the viewport (64x64 against 1152x1152), hence
# the conversion by the final transform of the root.
func _set_cursor(pos: Vector2) -> void:
    var ev = InputEventMouseMotion.new()
    ev.position = pos * get_root().get_final_transform().get_scale()
    ev.global_position = ev.position
    Input.parse_input_event(ev)
    await process_frame

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)
