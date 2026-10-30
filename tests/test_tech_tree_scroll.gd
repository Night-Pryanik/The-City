# Test of the scroll bars of the technology tree.
#   godot --headless --path . --script res://tests/test_tech_tree_scroll.gd
#
# The tree of all the technologies is wider and taller than its panel, so both bars have to be
# present and usable. Two details decide it:
#   - a bar takes its thickness from the margins of the theme's track: the vertical bar its
#     width from the left/right margins, the horizontal one its height from the top/bottom ones;
#   - the ScrollContainer takes the range of its bars from a minimum-size query, and the
#     anchored TreeRoot above it never makes one on its own, so the tree asks for it itself.
#
# Checks:
#   1. The content of the tree overflows the panel in both directions.
#   2. Both bars are shown as soon as the tab is opened, without a window resize.
#   3. Both bars have a thickness, so the grabber is not squeezed out of them.
#   4. The range of both bars covers the content.
#   5. Scrolling moves the tree by the same amount.
extends SceneTree

# The hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")
# Enough frames for the deferred layout of the freshly built tree.
const SETTLE_FRAMES := 4

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state: Dictionary = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    for _i in range(SETTLE_FRAMES):
        await process_frame
    main_map.open_city()
    for _i in range(SETTLE_FRAMES):
        await process_frame
    var city_ui = main_map.get_node_or_null("CityUI")
    check(city_ui != null, "CityUI is found", state)
    if city_ui == null:
        _finish(state)
        return

    # The tab is opened the way the player opens it, from the city window, and the bars must be
    # in place without a window resize.
    city_ui.show_technologies_tab()
    for _i in range(SETTLE_FRAMES):
        await process_frame

    var tree = city_ui.tech_tree
    var scroll: ScrollContainer = tree._scroll
    var hbar := scroll.get_h_scroll_bar()
    var vbar := scroll.get_v_scroll_bar()
    var content: Vector2 = tree._inner.custom_minimum_size

    check(scroll.is_visible_in_tree(), "the scroll area of the tree is shown", state)
    check(content.x > scroll.size.x,
        "the tree is wider than the panel (%.0f of %.0f)" % [content.x, scroll.size.x], state)
    check(content.y > scroll.size.y,
        "the tree is taller than the panel (%.0f of %.0f)" % [content.y, scroll.size.y], state)

    check(hbar.visible, "the horizontal bar is shown", state)
    check(vbar.visible, "the vertical bar is shown", state)
    check(hbar.size.y > 0.0,
        "the horizontal bar has a thickness (%.0f)" % hbar.size.y, state)
    check(vbar.size.x > 0.0,
        "the vertical bar has a thickness (%.0f)" % vbar.size.x, state)
    check(hbar.max_value >= content.x and hbar.page > 0.0,
        "the horizontal bar covers the width of the tree (%.0f of %.0f)"
            % [hbar.max_value, content.x], state)
    check(vbar.max_value >= content.y and vbar.page > 0.0,
        "the vertical bar covers the height of the tree (%.0f of %.0f)"
            % [vbar.max_value, content.y], state)

    var tree_position: Vector2 = tree._inner.position
    scroll.scroll_horizontal = 120
    await process_frame
    await process_frame
    check(is_equal_approx(tree._inner.position.x, tree_position.x - 120.0),
        "the horizontal bar scrolls the tree (%.0f of %.0f)"
            % [tree._inner.position.x, tree_position.x - 120.0], state)
    scroll.scroll_vertical = 90
    await process_frame
    await process_frame
    check(is_equal_approx(tree._inner.position.y, tree_position.y - 90.0),
        "the vertical bar scrolls the tree (%.0f of %.0f)"
            % [tree._inner.position.y, tree_position.y - 90.0], state)

    _finish(state)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TECH TREE SCROLL TEST FAILED")
        quit(1)
    else:
        print("TECH TREE SCROLL TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("OK: ", message)
    else:
        state["failed"] = true
        push_error("ASSERT FAILED: " + message)
