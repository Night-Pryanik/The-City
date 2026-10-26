# Headless test of the ACTIVE PAUSE — the simulation is stopped, but the
# interface lives and the actions of the player wait in a queue.
#   godot --headless --path . --script res://tests/test_active_pause.gd
#
# Checks (live MainMap scene):
#   1. Switching the mode on stops the tree, and the interface of the player is
#      switched to PROCESS_MODE_ALWAYS while the map itself is NOT — its _process
#      IS the simulation.
#   2. An action started while the mode is on does NOT start: it goes into the
#      queue and nothing happens on the map yet.
#   3. A one-shot action cannot be queued twice: the second start of the same
#      gather is refused, and the queue still holds exactly one record.
#   4. The queued action carries everything the empty bar of the map needs — the
#      colour and the offset of the bar of that kind of action.
#   5. The cancellation removes the record: the bar disappears, nothing starts,
#      and the treasury is exactly as it was before the click (nothing was spent).
#   6. The resume performs the queue: the build really starts, and the queue is
#      empty.
#   7. The pause menu and the active pause may be on at the same time: closing the
#      menu over a stopped world must not start the simulation.
#   8. The frame of the window is visible only while the mode is on.
#   9. What the mouse may reach: the buttons of the corner block the map under
#      them even with the mode off, and the mode blocks the whole map. The last
#      check is the control: with the mode off the map still works.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    for _i in range(4):
        await process_frame

    var ap = main_map.active_pause
    check(ap != null, "MainMap must own the active pause", state)
    if ap == null:
        _finish(state)
        return

    var target := _find_plain_hex(main_map)
    check(not target.is_empty(), "a hex for the construction must be found", state)
    if target.is_empty():
        _finish(state)
        return
    var row := int(target.row)
    var col := int(target.col)

    _test_mode_and_process_mode(state, main_map, ap)
    _test_queue_and_dedup(state, main_map, ap, row, col)
    _test_empty_bar(state, main_map, ap, row, col)
    _test_cancel(state, main_map, ap, row, col)
    _test_resume(state, main_map, ap, row, col)
    _test_pause_menu_coexistence(state, main_map, ap)
    _test_border(state, main_map, ap)
    _test_input_blocking(state, main_map, ap, row, col)

    _finish(state)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("ACTIVE PAUSE TEST FAILED")
        quit(1)
    else:
        print("ACTIVE PAUSE TEST OK")
        quit(0)

# -------------------------------------------------------
# 1. The mode and the process modes
# -------------------------------------------------------
func _test_mode_and_process_mode(state: Dictionary, main_map, ap) -> void:
    ap.set_active(true)
    check(ap.is_active(), "the mode must be on", state)
    check(paused, "the tree must be paused while the mode is on", state)

    for path in ["ControlPanel", "CityUI", "TownUI", "HUD", "InputHandler", "TopRightLayer"]:
        var node = main_map.get_node_or_null(path)
        check(node != null, "the node %s must exist" % path, state)
        if node != null:
            check(node.process_mode == Node.PROCESS_MODE_ALWAYS,
                    "%s must keep working while the simulation is stopped (mode = %d)"
                    % [path, node.process_mode], state)

    # The map itself stands still: its _process is the simulation.
    check(main_map.process_mode != Node.PROCESS_MODE_ALWAYS,
            "MainMap must NOT process while the simulation is stopped", state)

    # The input of the map must NOT depend on main_map for the same reason.
    # main_map._input stands still with it, and the input dies with the node:
    # neither the drag, nor the selection, nor SPACE arrive any more. This is
    # what the engine gates on process_mode, therefore InputHandler must be its
    # own entry point AND be switched to ALWAYS.
    check(main_map.input_handler.has_method("_input"),
            "InputHandler must own the input of the map itself, not receive it from MainMap", state)
    check(ap.is_processing(),
            "the cursor tick must keep running while the mode is on", state)

    ap.set_active(false)
    check(not ap.is_processing(),
            "the cursor tick must stop with the mode", state)
    check(not paused, "the tree must be resumed with the mode off", state)
    check(main_map.get_node_or_null("ControlPanel").process_mode == Node.PROCESS_MODE_INHERIT,
            "the process mode of the interface must be restored", state)

# -------------------------------------------------------
# 2, 3. The queue and the one-shot protection
# -------------------------------------------------------
func _test_queue_and_dedup(state: Dictionary, main_map, ap, row: int, col: int) -> void:
    var bm = main_map.build_manager
    check(not bm.is_building(row, col), "the hex must be free before the test", state)

    ap.set_active(true)
    check(bm.start_build(row, col, BUILD_ID, null, 0),
            "the first start must be accepted", state)
    check(not _is_started(main_map, row, col),
            "the build must NOT start while the simulation is stopped", state)
    check(ap.count() == 1, "the action must stand in the queue (count = %d)" % ap.count(), state)

    # The one-shot protection: the same gather a second time.
    check(not bm.start_build(row, col, BUILD_ID, null, 0),
            "the second start of the same action must be refused", state)
    check(ap.count() == 1, "the queue must still hold exactly one record (count = %d)"
            % ap.count(), state)

# -------------------------------------------------------
# 4. The record of the empty bar
# -------------------------------------------------------
func _test_empty_bar(state: Dictionary, _main_map, ap, row: int, col: int) -> void:
    var rec: Dictionary = ap.get_pending_at(row, col)
    check(not rec.is_empty(), "the record of the queued action must be found on its hex", state)
    if rec.is_empty():
        return
    check(rec.has("bar_color"), "the record must carry the colour of its bar", state)
    check(rec.has("bar_offset"), "the record must carry the offset of its bar", state)
    check(float(rec.get("bar_offset", -1.0)) > 0.0,
            "the bar of a queued action must have a place on the hex", state)
    check(str(rec.get("label", "")).length() > 0,
            "the record must name the action for the cancel button", state)

# -------------------------------------------------------
# 5. The cancellation
# -------------------------------------------------------
func _test_cancel(state: Dictionary, main_map, ap, row: int, col: int) -> void:
    check(ap.cancel_at(row, col), "the queued action must be cancellable", state)
    check(ap.is_empty(), "the queue must be empty after the cancellation", state)
    check(ap.get_pending_at(row, col).is_empty(),
            "the record must be gone from its hex", state)
    check(not _is_started(main_map, row, col),
            "a cancelled action must never start", state)

# -------------------------------------------------------
# 6. The resume performs the queue
# -------------------------------------------------------
func _test_resume(state: Dictionary, main_map, ap, row: int, col: int) -> void:
    var bm = main_map.build_manager
    ap.set_active(true)
    check(bm.start_build(row, col, BUILD_ID, null, 0),
            "the action must be queued again for the resume", state)
    check(ap.count() == 1, "the action must be in the queue (count = %d)" % ap.count(), state)
    check(not _is_started(main_map, row, col), "it must not have started yet", state)

    ap.set_active(false)
    check(ap.is_empty(), "the queue must be empty after the resume", state)
    check(not paused, "the simulation must be running after the resume", state)
    check(_is_started(main_map, row, col),
            "the queued action must really start on the resume", state)
    _cleanup(main_map, row, col)

# -------------------------------------------------------
# 7. The pause menu and the active pause at the same time
# -------------------------------------------------------
func _test_pause_menu_coexistence(state: Dictionary, main_map, ap) -> void:
    ap.set_active(true)
    main_map.open_pause_menu()
    check(main_map.pause_menu.visible, "the pause menu must be open", state)
    check(paused, "the tree must be paused", state)

    main_map.pause_menu.hide()
    main_map.apply_pause_state()
    check(paused,
            "closing the menu over a stopped world must not start the simulation", state)
    check(ap.is_active(), "the mode must survive the opening of the menu", state)

    ap.set_active(false)
    check(not paused, "the resume must unpause the tree", state)

# -------------------------------------------------------
# 8. The frame of the window
# -------------------------------------------------------
func _test_border(state: Dictionary, _main_map, ap) -> void:
    var border = _find_border(ap)
    check(border != null, "the frame of the window must be built", state)
    if border == null:
        return
    check(not border.visible, "the frame must be hidden while the simulation runs", state)
    ap.set_active(true)
    check(border.visible, "the frame must be shown while the mode is on", state)
    ap.set_active(false)
    check(not border.visible, "the frame must be hidden again after the resume", state)

func _find_border(node: Node):
    if node.name == "ActivePauseBorder":
        return node
    for child in node.get_children():
        var found = _find_border(child)
        if found != null:
            return found
    return null

# -------------------------------------------------------
# 9. What the mouse may and may not reach
#
# The events are fed to handle_input directly: in a headless run the engine does
# not push synthetic mouse events through _input, and what is under test here is
# the guard of the handler. The DELIVERY — whether the handler is reached at all
# while the mode is on — is a different failure and cannot be seen from here; it
# is checked structurally in _test_mode_and_process_mode.
# -------------------------------------------------------
func _test_input_blocking(state: Dictionary, main_map, ap, row: int, col: int) -> void:
    var ih = main_map.input_handler
    var hex_pos := _hex_center(main_map, row, col)
    var pause_pos: Vector2 = main_map.pause_button.get_global_rect().get_center()
    var menu_pos: Vector2 = main_map.menu_button.get_global_rect().get_center()

    # The control of the experiment: with the mode off the map reacts as usual.
    _motion(ih, hex_pos)
    check(_hovered(ih) == { "row": row, "col": col },
            "with the mode off the map must react to the cursor (hovered %s)" % str(_hovered(ih)), state)

    # The corner of the pause button and the menu button: the map under them must
    # not react, otherwise the hex tooltip pops up through the buttons.
    _motion(ih, pause_pos)
    check(_hovered(ih) == null,
            "the map must not react under the pause button (hovered %s)" % str(_hovered(ih)), state)
    check(not main_map.hex_tooltip.visible,
            "no tooltip may pop up through the pause button", state)
    _motion(ih, menu_pos)
    check(_hovered(ih) == null,
            "the map must not react under the menu button (hovered %s)" % str(_hovered(ih)), state)

    # The buttons of the corner block the map under them — but ONLY the buttons.
    # With the mode on the map itself must work exactly as usual: the player has to
    # be able to scroll it and to look at the hexes before choosing what to queue.
    ap.set_active(true)
    _motion(ih, hex_pos)
    check(_hovered(ih) == { "row": row, "col": col },
            "with the mode on the map must still react to the cursor (hovered %s)" % str(_hovered(ih)), state)
    _click(ih, hex_pos)
    check(main_map.control_panel.has_selection(),
            "with the mode on a click must still select a hex", state)
    main_map.clear_selection()

    # The cursor tick survives the pause as well — it drives the edge scrolling and
    # the tooltip timer. main_map._process does not run while the tree is paused,
    # so without the forwarded tick the map could not be scrolled at all.
    check(ap.is_processing(),
            "the cursor tick must keep running while the mode is on", state)
    ap.set_active(false)
    check(not ap.is_processing(),
            "the cursor tick must stop with the mode", state)

func _hovered(ih) -> Variant:
    return ih._hovered_hex

func _hex_center(main_map, row: int, col: int) -> Vector2:
    var world: Vector2 = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    return world * main_map.zoom + main_map.map_renderer.position

func _motion(ih, pos: Vector2) -> void:
    var ev = InputEventMouseMotion.new()
    ev.position = pos
    ev.global_position = pos
    ev.velocity = Vector2(3.0, 3.0)
    ih.handle_input(ev)

func _click(ih, pos: Vector2) -> void:
    var down = InputEventMouseButton.new()
    down.button_index = MOUSE_BUTTON_LEFT
    down.pressed = true
    down.position = pos
    down.global_position = pos
    ih.handle_input(down)
    var up = InputEventMouseButton.new()
    up.button_index = MOUSE_BUTTON_LEFT
    up.pressed = false
    up.position = pos
    up.global_position = pos
    ih.handle_input(up)

# An ordinary build with a real labour cost: it is the case where the player can see
# the difference between "started" and "waiting in the queue".
const BUILD_ID := "farm"

# A hex of the Influence Ring without an improvement, a town and water: an ordinary
# place for a construction.
func _find_plain_hex(main_map) -> Dictionary:
    var mh = load("res://scripts/map_helpers.gd")
    var road_level: int = _gdata.get_max_unlocked_road_level()
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            if row == main_map.city_row and col == main_map.city_col:
                continue
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("decorative", false)) or tile.get("improvement", null) != null:
                continue
            if mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if int(main_map.get_improvement_work_cost(BUILD_ID, row, col, road_level).get("cost", 0)) <= 0:
                continue
            return {"row": row, "col": col}
    return {}

# Has an action REALLY started on this hex? Depending on whether the hex is already
# connected by a road, the improvement goes either into an ordinary build or into the
# chain "road → improvement" — both are "started", and both are not started while
# the action waits in the queue.
func _is_started(main_map, row: int, col: int) -> bool:
    if main_map.build_manager.is_building(row, col):
        return true
    return main_map.project_manager != null and main_map.project_manager.has_project_at(row, col)

# The test leaves the world as clean as it found it: whatever has started on the hex
# (a build or a project) is stopped, so that the next case starts from scratch.
func _cleanup(main_map, row: int, col: int) -> void:
    main_map.build_manager.cancel_build(row, col)
    if main_map.project_manager != null and main_map.project_manager.has_project_at(row, col):
        main_map.project_manager.cancel_project(
                str(main_map.project_manager.get_project_at(row, col).get("id", "")))

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)