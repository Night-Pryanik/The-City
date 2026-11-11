# Test of the tooltip of the buttons of the technology tree.
#   godot --headless --path . --script res://tests/test_tech_tooltip.gd
#
# The description of a technology does not fit in one line, and the built-in tooltip of the
# engine draws its text in ONE line — it runs off the edge of the screen. The tree therefore
# uses the wrapping tooltip of the project (scripts/wrapped_tooltip.gd): a carrier is laid
# over the button, it owns the text, and it hands the engine a wrapping label.
#
# Checks:
#   1. Every technology of the tree has a carrier with the text of the technology.
#   2. The button itself has NO tooltip_text — the one-line tooltip of the engine must not
#      be able to show itself.
#   3. The carrier catches the mouse for the tooltip, but the click still reaches the button.
#   4. The carrier stops ABOVE the row of the unlock icons: those have tooltips of their own
#      and the row needs the mouse for the wheel that scrolls it.
#   5. The content of the tooltip really wraps: a long description is broken into lines.
#   6. The text follows the state of the technology.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")
const WT = preload("res://scripts/wrapped_tooltip.gd")

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
    city_ui.show_technologies_tab()
    for _i in range(SETTLE_FRAMES):
        await process_frame

    var tree = city_ui.tech_tree
    var nodes: Dictionary = tree._tech_nodes
    check(nodes.size() > 0, "the tree has technologies", state)

    var with_carrier := 0
    var with_text := 0
    var long_text := ""
    for tech_id in nodes:
        var btn: Button = nodes[tech_id]["button"]
        var carrier = WT.find_carrier(btn)
        if carrier == null:
            continue
        with_carrier += 1
        check(str(btn.tooltip_text).is_empty(),
            "the button of \"%s\" must not carry a tooltip_text of its own — the engine would draw it in one line"
                % tech_id, state)
        check(carrier.mouse_filter == Control.MOUSE_FILTER_PASS,
            "the carrier of \"%s\" must let the click through to the button" % tech_id, state)
        var text := str(carrier.tooltip_text)
        if not text.is_empty():
            with_text += 1
            var cost := int(_tech_data(tech_id).get("science_cost", 3))
            check(text.contains(str(cost)),
                "the tooltip of \"%s\" must carry the cost of the research" % tech_id, state)
            if text.length() > long_text.length():
                long_text = text
        # The carrier must not cover the row of the unlock icons.
        if btn.get_node_or_null("UnlockIconsScroll") != null:
            check(carrier.offset_bottom <= -43.0,
                "the carrier of \"%s\" must stop above the row of the unlock icons (offset_bottom %.1f)"
                    % [tech_id, carrier.offset_bottom], state)
    check(with_carrier == nodes.size(),
        "every technology of the tree must have a carrier (%d of %d)" % [with_carrier, nodes.size()],
        state)
    check(with_text == nodes.size(),
        "every carrier must carry a text (%d of %d)" % [with_text, nodes.size()], state)

    # The content of the tooltip really wraps.
    check(long_text.length() > 100,
        "the tree must have a technology with a long description (got %d characters)"
            % long_text.length(), state)
    var content := WT.build(long_text)
    var line_height := float(content.get_theme_font_size("font_size"))
    var wrapped := content.get_minimum_size()
    check(wrapped.x <= WT.DEFAULT_MAX_WIDTH + 0.5,
        "the tooltip must fit the wrap width (got %.1f px)" % wrapped.x, state)
    check(wrapped.y > line_height,
        "the long description must really be broken into several lines (height %.1f px for a line of %.1f px)"
            % [wrapped.y, line_height], state)

    # The text follows the state of the technology.
    var wheel_button: Button = null
    for tech_id in nodes:
        if str(tech_id) == "wheel":
            wheel_button = nodes[tech_id]["button"]
            break
    check(wheel_button != null, "the tree must have the wheel", state)
    if wheel_button != null:
        var carrier = WT.find_carrier(wheel_button)
        var before := str(carrier.tooltip_text)
        get_root().get_node("CityData").unlocked_technologies.append("wheel")
        # The tree is rebuilt from scratch, so the button of the wheel is a new one.
        tree.refresh()
        for _i in range(SETTLE_FRAMES):
            await process_frame
        var rebuilt: Button = tree._tech_nodes["wheel"]["button"]
        var after := str(WT.find_carrier(rebuilt).tooltip_text)
        check(after != before,
            "the text of the tooltip must follow the state of the technology", state)
        check(after.contains(before.split("\n")[0]),
            "the description must stay in the tooltip after the change", state)

    _finish(state)

# The data of a technology. In --script mode the autoload names are unavailable at
# compile time, so the node is taken from the tree.
func _tech_data(tech_id: String) -> Dictionary:
    var gdata = get_root().get_node("GameData")
    for t in gdata.technologies:
        if str(t.get("id", "")) == tech_id:
            return t
    return {}

func _finish(state: Dictionary) -> void:
    if state["failed"]:
        print("TECH TOOLTIP TEST FAILED")
        quit(1)
    else:
        print("TECH TOOLTIP TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
