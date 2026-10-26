# Headless test of the KEYBOARD SCROLLING of the map — the arrow keys move the map.
#   godot --headless --path . --script res://tests/test_keyboard_scrolling.gd
#
# The edge scrolling of the screen is switched off for the whole run: the cursor of a
# headless run sits in the top left corner, inside the margin, and would move the map
# behind the back of every measurement. The keyboard is a separate control and must work
# with the setting off (case 5), so the whole run doubles as that check.
#
# Checks (live MainMap scene):
#   1. Every arrow key moves the map in its direction.
#   2. The distance is scroll_speed * delta — the movement is continuous, not per frame.
#   3. The speed is the one of the edge scrolling: the value comes from the same setting
#      (main_map.edge_scroll_speed -> InputHandler.scroll_speed).
#   4. A diagonal moves as fast as a single key: the direction is normalised.
#   5. The keys are an independent control — they work with the edge scrolling off.
#   6. A focused text field owns the arrow keys: the map stands still.
#   7. The clamp of the reachable area is respected.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The starting offset of every measurement: away from the zero corner, so that a key
# moving the map towards the negative side is not stopped by the clamp at once.
var _start: Vector2 = Vector2.ZERO

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    main_map.use_edge_scrolling = false
    for _i in range(4):
        await process_frame

    var ih = main_map.input_handler
    # The speed of the keyboard is the speed of the edge scrolling: apply_settings() pushes
    # interface/edge_scroll_speed into the handler. The value of the machine's own
    # settings.cfg is not touched — whatever it is, both sides must agree on it.
    main_map.apply_settings()
    main_map.use_edge_scrolling = false
    # The scroll offset is measured in world units: pin the zoom that converts the screen
    # speed into them, so the saved zoom of the machine does not shape the result.
    main_map.set_zoom(1.0)
    var speed: float = ih.scroll_speed
    check(is_equal_approx(speed, clampf(main_map.edge_scroll_speed, 100.0, 1000.0)),
            "the keyboard must take the speed of the edge scrolling (handler %.1f, setting %.1f)"
            % [speed, main_map.edge_scroll_speed], state)

    var max_scroll: Vector2 = main_map.get_max_scroll()
    _start = Vector2(minf(200.0, max_scroll.x * 0.5), minf(200.0, max_scroll.y * 0.5))
    main_map.scroll_offset = _start

    if WATCHDOG.wants_case("directions"):
        await _test_directions(state, main_map, ih)
    if WATCHDOG.wants_case("speed"):
        await _test_speed(state, main_map, ih, speed)
    if WATCHDOG.wants_case("diagonal"):
        await _test_diagonal(state, main_map, ih, speed)
    if WATCHDOG.wants_case("edge_off"):
        await _test_edge_off(state, main_map, ih)
    if WATCHDOG.wants_case("text_focus"):
        await _test_text_focus(state, main_map, ih)
    if WATCHDOG.wants_case("clamp"):
        await _test_clamp(state, main_map, ih)

    _finish(state)

func _finish(state: Dictionary) -> void:
    _release_all()
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("KEYBOARD SCROLLING TEST FAILED")
        quit(1)
    else:
        print("KEYBOARD SCROLLING TEST OK")
        quit(0)

# -------------------------------------------------------
# 1. The direction of every key
# -------------------------------------------------------
func _test_directions(state: Dictionary, main_map, ih) -> void:
    # A key moves the VIEW, therefore the offset of the map goes the other way: LEFT
    # increases the offset exactly like the cursor at the left edge of the screen.
    await _expect_move(state, main_map, ih, KEY_LEFT, Vector2(1, 0), "LEFT")
    await _expect_move(state, main_map, ih, KEY_RIGHT, Vector2(-1, 0), "RIGHT")
    await _expect_move(state, main_map, ih, KEY_UP, Vector2(0, 1), "UP")
    await _expect_move(state, main_map, ih, KEY_DOWN, Vector2(0, -1), "DOWN")

# -------------------------------------------------------
# 2. Continuous movement at the speed of the edge scrolling
# -------------------------------------------------------
func _test_speed(state: Dictionary, main_map, ih, speed: float) -> void:
    # The movement is continuous: a held key covers speed * delta, and not a step per frame.
    main_map.scroll_offset = _start
    var moved: Vector2 = await _hold_and_measure(main_map, ih, [KEY_LEFT], 0.2)
    check(is_equal_approx(moved.x, speed * 0.2),
            "0.2 s at %.0f px/s must move the map by %.1f px (got %.1f)"
            % [speed, speed * 0.2, moved.x], state)

    # A change of the speed is picked up at once: the value is read on every frame.
    ih.set_scroll_speed(1000.0)
    main_map.scroll_offset = _start
    moved = await _hold_and_measure(main_map, ih, [KEY_LEFT], 0.1)
    check(is_equal_approx(moved.x, 100.0),
            "0.1 s at 1000 px/s must move the map by 100 px (got %.1f)" % moved.x, state)
    ih.set_scroll_speed(speed)

# -------------------------------------------------------
# 3. The diagonal
# -------------------------------------------------------
func _test_diagonal(state: Dictionary, main_map, ih, speed: float) -> void:
    main_map.scroll_offset = _start
    var moved: Vector2 = await _hold_and_measure(main_map, ih, [KEY_LEFT, KEY_UP], 0.2)
    check(moved.x > 0.0 and moved.y > 0.0,
            "LEFT+UP must move the map along both axes (%s)" % str(moved), state)
    # Normalised: the length of the diagonal is the length of a single-key move,
    # otherwise the map would run sqrt(2) times faster.
    check(is_equal_approx(moved.length(), speed * 0.2),
            "the diagonal must be as fast as a single key (length %.1f)" % moved.length(), state)

# -------------------------------------------------------
# 4. The edge scrolling setting does not gate the keys
# -------------------------------------------------------
func _test_edge_off(state: Dictionary, main_map, ih) -> void:
    check(not main_map.use_edge_scrolling, "the edge scrolling must be off in this run", state)
    main_map.scroll_offset = _start
    var moved: Vector2 = await _hold_and_measure(main_map, ih, [KEY_LEFT], 0.1)
    check(moved.x > 0.0,
            "the arrow keys must move the map with the edge scrolling off (%s)" % str(moved), state)

# -------------------------------------------------------
# 5. A focused text field
# -------------------------------------------------------
func _test_text_focus(state: Dictionary, main_map, ih) -> void:
    var field := LineEdit.new()
    get_root().add_child(field)
    field.grab_focus()
    await process_frame
    check(get_root().gui_get_focus_owner() == field,
            "the text field must hold the focus", state)

    main_map.scroll_offset = _start
    var moved: Vector2 = await _hold_and_measure(main_map, ih, [KEY_LEFT], 0.2)
    check(moved == Vector2.ZERO,
            "a focused text field must keep the arrow keys (%s)" % str(moved), state)

    field.release_focus()
    get_root().remove_child(field)
    field.free()
    await process_frame

# -------------------------------------------------------
# 6. The clamp of the reachable area
# -------------------------------------------------------
func _test_clamp(state: Dictionary, main_map, ih) -> void:
    var max_scroll: Vector2 = main_map.get_max_scroll()
    main_map.scroll_offset = Vector2(max_scroll.x - 5.0, max_scroll.y - 5.0)
    await _hold_and_measure(main_map, ih, [KEY_LEFT, KEY_UP], 0.5)
    check(is_equal_approx(main_map.scroll_offset.x, max_scroll.x)
            and is_equal_approx(main_map.scroll_offset.y, max_scroll.y),
            "the keyboard must stop at the edge of the reachable area (%s vs %s)"
            % [str(main_map.scroll_offset), str(max_scroll)], state)
    main_map.scroll_offset = _start

# Presses the keys, measures the movement of the map over the given time and releases
# the keys. The frames that pass while the keys are being pressed are not part of the
# measurement: the start point is taken after them.
func _hold_and_measure(main_map, ih, keys: Array, seconds: float) -> Vector2:
    for key in keys:
        await _set_key(key, true)
    var before: Vector2 = main_map.scroll_offset
    ih.handle_process(seconds)
    var moved: Vector2 = main_map.scroll_offset - before
    _release_all()
    return moved

func _expect_move(state: Dictionary, main_map, ih, key, expected: Vector2, label: String) -> void:
    main_map.scroll_offset = _start
    var moved: Vector2 = await _hold_and_measure(main_map, ih, [key], 0.1)
    check(moved.x * expected.x > 0.0 or moved.y * expected.y > 0.0,
            "%s must move the map towards %s (got %s)" % [label, str(expected), str(moved)], state)
    # The other axis must stay untouched: a key moves the map along one axis only.
    if expected.x != 0.0:
        check(is_zero_approx(moved.y),
                "%s must not move the map vertically (got %s)" % [label, str(moved)], state)
    else:
        check(is_zero_approx(moved.x),
                "%s must not move the map sideways (got %s)" % [label, str(moved)], state)

func _release_all() -> void:
    for key in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
        _set_key_now(key, false)

# The keyboard state is fed through the input system: the handler polls Input, and a
# headless run has no real keyboard.
func _set_key(key, pressed: bool) -> void:
    _set_key_now(key, pressed)
    await process_frame

func _set_key_now(key, pressed: bool) -> void:
    var ev := InputEventKey.new()
    ev.keycode = key
    ev.physical_keycode = key
    ev.pressed = pressed
    Input.parse_input_event(ev)

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)
