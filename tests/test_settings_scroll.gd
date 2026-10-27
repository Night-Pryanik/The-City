# Headless test of the settings window scrolling:
#   godot --headless --path . --script res://tests/test_settings_scroll.gd
#
# The window holds more settings than a short screen can show. A tab page that
# keeps its settings in a plain container anchored to the top grows past the
# window: everything below the fold is drawn outside the panel and cannot be
# reached. Each populated page therefore keeps its settings in a ScrollContainer.
#
# Checks, in a frame short enough that both populated pages overflow:
#   1) every populated page keeps its settings inside a ScrollContainer that
#      stays within the page, and the page itself stays within the window;
#   2) the settings take the width of the scroll area and never widen it, so a
#      wrapped hint cannot push the page sideways;
#   3) the content is taller than the scroll area, a vertical scrollbar appears,
#      and the wheel over the page moves it;
#   4) scrolled to the end, the last control of the page is inside the visible
#      area — it used to hang below the window bottom;
#   5) the "Edge scrolling speed" block finds its controls through the new
#      NodePaths (they point inside the scroll area now).
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")
const SETTINGS_SCENE := "res://scenes/settings_menu.tscn"
# Short enough for both populated pages to overflow, wide enough for the sliders:
# a window this short is what a small screen gives.
const FRAME_SIZE := Vector2(900, 230)
const POPULATED_PAGES := ["Игра", "Интерфейс"]

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    var frame := Control.new()
    frame.name = "Frame"
    frame.size = FRAME_SIZE
    get_root().add_child(frame)
    var settings: Control = load(SETTINGS_SCENE).instantiate()
    frame.add_child(settings)
    await process_frame
    await process_frame

    var tabs: TabContainer = settings.find_child("TabContainer", true, false)
    check(tabs != null, "the tab container is found", state)
    if tabs == null:
        _finish(state)
        return
    check(tabs.size.y <= settings.size.y,
        "the tabs stay within the window (%.0f of %.0f)" % [tabs.size.y, settings.size.y], state)

    var populated := 0
    for page_index in tabs.get_tab_count():
        var page: Control = tabs.get_child(page_index)
        var scroll: ScrollContainer = page.get_node_or_null("Scroll")
        if scroll == null:
            # An empty page has nothing to scroll; a page with settings has to.
            check(page.get_child_count() == 0,
                "%s: a page without a scroll area is empty" % page.name, state)
            continue
        populated += 1
        tabs.current_tab = page_index
        await process_frame
        await process_frame
        await _check_page(settings, page, scroll, state)

    check(populated == POPULATED_PAGES.size(),
        "both populated pages scroll (%d found)" % populated, state)

    # --- 5. The setting block still reaches its controls ---
    var slider: HSlider = settings.find_child("EdgeScrollSpeedSlider", true, false)
    var interface_scroll: ScrollContainer = settings.get_node_or_null(
        "TabContainer/Интерфейс/Scroll")
    check(slider != null and interface_scroll != null
            and interface_scroll.is_ancestor_of(slider),
        "the edge scrolling speed block points inside the scroll area", state)

    frame.queue_free()
    await process_frame
    _finish(state)

func _check_page(settings: Control, page: Control, scroll: ScrollContainer,
        state: Dictionary) -> void:
    var where := str(page.name)
    var box: VBoxContainer = scroll.get_child(0) as VBoxContainer
    check(box != null, where + ": the settings live in a box inside the scroll", state)
    if box == null:
        return

    # --- 1. The scroll area fits the page, the page fits the window ---
    var page_rect := page.get_global_rect()
    var scroll_rect := scroll.get_global_rect()
    check(scroll_rect.end.x <= page_rect.end.x + 1.0 and scroll_rect.end.y <= page_rect.end.y + 1.0,
        where + ": the scroll area does not leave its page", state)
    check(page_rect.end.y <= settings.get_global_rect().end.y + 1.0,
        where + ": the page does not leave the window", state)

    # --- 2. Width: the settings follow the scroll area, never widen it ---
    check(box.size.x <= scroll.size.x + 1.0,
        where + ": the settings fit the width of the scroll area (%.0f of %.0f)"
            % [box.size.x, scroll.size.x], state)

    # --- 3. Height: the content overflows, so the bar appears and the wheel works ---
    check(box.size.y > scroll.size.y,
        where + ": the settings are taller than the scroll area (%.0f of %.0f)"
            % [box.size.y, scroll.size.y], state)
    check(scroll.get_v_scroll_bar().visible,
        where + ": a vertical scrollbar appears", state)

    var before := scroll.scroll_vertical
    _wheel(page_rect.get_center(), MOUSE_BUTTON_WHEEL_DOWN)
    await process_frame
    await process_frame
    check(scroll.scroll_vertical > before,
        where + ": the wheel scrolls the page (%d -> %d)" % [before, scroll.scroll_vertical], state)

    # --- 4. The end of the list can be brought into view ---
    scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
    await process_frame
    await process_frame
    var last: Control = box.get_child(box.get_child_count() - 1)
    var last_rect := last.get_global_rect()
    var visible_rect := scroll.get_global_rect()
    check(last_rect.end.y <= visible_rect.end.y + 1.0 and last_rect.position.y >= visible_rect.position.y - 1.0,
        where + ": the last setting (%.0f..%.0f) is inside the visible area (%.0f..%.0f)"
            % [last_rect.position.y, last_rect.end.y,
                visible_rect.position.y, visible_rect.end.y], state)

    # --- 4b. The keyboard brings a control of its own accord: the focus follows ---
    # A control reached with Tab would otherwise take the focus below the fold, where
    # the player cannot see what the keys are about to change.
    var focusable := _last_focusable(box)
    check(focusable != null, where + ": the page has a focusable control", state)
    if focusable != null:
        scroll.scroll_vertical = 0
        await process_frame
        focusable.grab_focus()
        await process_frame
        await process_frame
        check(scroll.scroll_vertical > 0,
            where + ": the scroll follows the focused control (%d)" % scroll.scroll_vertical, state)
        focusable.release_focus()

# The last control of a page that can take the keyboard focus: a row or a box in
# between cannot, and grabbing the focus on one is an error.
func _last_focusable(node: Node) -> Control:
    var found: Control = null
    for child in node.get_children():
        var deeper := _last_focusable(child)
        if deeper != null:
            found = deeper
        elif child is Control and (child as Control).focus_mode != Control.FOCUS_NONE:
            found = child
    return found

func _wheel(pos: Vector2, button: int) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = button
    event.pressed = true
    event.position = pos
    event.global_position = pos
    event.device = 0
    get_root().push_input(event, true)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("SETTINGS SCROLL TEST FAILED")
        quit(1)
    else:
        print("SETTINGS SCROLL TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if cond:
        print("OK: ", msg)
    else:
        state["failed"] = true
        push_error("ASSERT FAILED: " + msg)
        print("ASSERT FAILED: ", msg)
