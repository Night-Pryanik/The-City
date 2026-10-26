# Headless test of the WRAPPING tooltip (scripts/wrapped_tooltip.gd):
#   godot --headless --path . --script res://tests/test_wrapped_tooltip.gd
#
# The built-in tooltip of the engine draws its text in ONE line and never breaks it, so a
# long hint runs off the edge of the window. The project answers with a mechanism of its
# own: a carrier control is laid over the control being described, it OWNS the text, and it
# hands the engine a wrapping label (Control._make_custom_tooltip).
#
# Checked:
#   1. BUILD. A hint wider than the limit is constrained to it and wraps; a SHORT hint
#      keeps its natural width (a limit given to every tooltip would turn a two-word hint
#      into a wide empty bar), and the width of the text is measured over its widest line.#   2. ATTACH. The carrier covers the whole control and follows it on resize, it catches
#      the mouse for the tooltip but lets the clicks through to the control below
#      (MOUSE_FILTER_PASS), and the control itself is made hoverable.
#   3. ONE CARRIER. attach() is idempotent: a hint rebuilt on every change (the route
#      warning follows the amount) keeps a single carrier and only replaces the text.
#   4. THE ENGINE REALLY ASKS. On a live tree the engine picks the CARRIER as the control
#      under the mouse and shows OUR wrapping label inside its popup, at the wrap width —
#      and not the single-line label it would build by itself.
#   5. THE CLICK SURVIVES. A button under a carrier still receives its press.
#
# Case 4 is the only one that needs the real tooltip machinery: the engine shows a tooltip
# only for the control the hover actually reaches, so the test pushes a mouse motion into
# the viewport and waits out the tooltip delay (gui/timers/tooltip_delay_sec, 0.5 s).
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The mechanism is taken by path and not by the global class name: with --script the class
# cache may not be there yet (the same note as in watchdog.gd).
const WT = preload("res://scripts/wrapped_tooltip.gd")

# A hint that is wider than the wrap width in any font.
const LONG_HINT := "The rate the town serves a contract with for free. A larger order strains it: it keeps up less and less, and its warehouse falls behind."
const SHORT_HINT := "Short hint"

var _failed := false
var _presses := 0

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    # The headless window is tiny (64x64) and the viewport is scaled into it, so a mouse
    # pushed in WINDOW coordinates would land far away from the control. The window is
    # given a real size, and the events are pushed in LOCAL (viewport) coordinates.
    root.size = Vector2i(1280, 720)
    await process_frame

    _test_build()
    await _test_attach()
    await _test_live_tooltip()

    WATCHDOG.report_skipped()
    if _failed:
        print("WRAPPED TOOLTIP TEST FAILED")
        quit(1)
    else:
        print("WRAPPED TOOLTIP TEST OK")
        quit(0)

# -------------------------------------------------------
# 1. The content of a tooltip
# -------------------------------------------------------

func _test_build() -> void:
    var long_content: Label = WT.build(LONG_HINT)
    _check(long_content.text == LONG_HINT,
        "the content must carry the text as it was given")
    _check(long_content.autowrap_mode != TextServer.AUTOWRAP_OFF,
        "the content of a tooltip must wrap")
    _check(long_content.custom_minimum_size.x == WT.DEFAULT_MAX_WIDTH,
        "a hint wider than the limit must be constrained to it, otherwise it comes out as one line off the window (got %s)"
            % str(long_content.custom_minimum_size))
    _check(long_content.mouse_filter == Control.MOUSE_FILTER_IGNORE,
        "the content must not take the mouse from the carrier (got %d)"
            % long_content.mouse_filter)

    # A short hint must keep its own width: it is neither stretched to the limit nor left
    # without one, which would collapse the popup into a column one letter wide.
    var short_content: Label = WT.build(SHORT_HINT)
    var short_natural: float = WT.natural_width(short_content, SHORT_HINT)
    _check(short_content.custom_minimum_size.x < WT.DEFAULT_MAX_WIDTH,
        "a short hint must not be stretched to the limit (got %s)"
            % str(short_content.custom_minimum_size))
    _check(is_equal_approx(short_content.get_combined_minimum_size().x, short_natural),
        "a short hint must be as wide as its text (got %.1f px for a text of %.1f px)"
            % [short_content.get_combined_minimum_size().x, short_natural])

    # The width of the text is the width of its WIDEST line: a hint may carry line breaks
    # of its own (the route-capacity warning does).
    var multiline := "one two three\nfour five six seven eight nine ten eleven twelve thirteen fourteen fifteen"
    _check(WT.natural_width(long_content, multiline)
            > WT.natural_width(long_content, "one two three"),
        "the natural width must be measured over the widest line of the text")

    # The caller may pass a narrower limit (a column of a panel).
    var narrow: Label = WT.build(LONG_HINT, 120.0)
    _check(narrow.custom_minimum_size.x == 120.0,
        "the wrap width of the caller must be used (got %s)"
            % str(narrow.custom_minimum_size))

    long_content.free()
    short_content.free()
    narrow.free()

# -------------------------------------------------------
# 2. Laying the carrier over a control, 3. keeping one carrier
# -------------------------------------------------------

func _test_attach() -> void:
    var host := Control.new()
    host.position = Vector2(0, 0)
    host.size = Vector2(200, 40)
    # A Label catches nothing by default — exactly the case the mechanism must survive.
    host.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.add_child(host)
    await process_frame

    var carrier = WT.attach(host, LONG_HINT)
    await process_frame

    _check(carrier != null, "attach must return the carrier")
    _check(WT.find_carrier(host) == carrier,
        "the carrier must be findable on the control it describes")
    _check(carrier.tooltip_text == LONG_HINT, "the carrier must own the text")
    _check(host.mouse_filter != Control.MOUSE_FILTER_IGNORE,
        "attach must make the control itself hoverable (got %d)" % host.mouse_filter)
    _check(carrier.mouse_filter == Control.MOUSE_FILTER_PASS,
        "the carrier must let the clicks through to the control below (got %d)"
            % carrier.mouse_filter)
    _check(carrier.size == host.size,
        "the carrier must cover the whole control (got %s for a control of %s)"
            % [str(carrier.size), str(host.size)])

    # Idempotence: a hint rebuilt on every change keeps ONE carrier.
    var again = WT.attach(host, SHORT_HINT)
    _check(again == carrier,
        "a repeated attach must reuse the carrier and not lay a second one on top")
    _check(host.get_child_count() == 1,
        "the control must keep a single carrier (got %d children)" % host.get_child_count())
    _check(carrier.tooltip_text == SHORT_HINT,
        "a repeated attach must replace the text (got \"%s\")" % carrier.tooltip_text)

    # The carrier follows the control: it is a child of it, so the containers around that
    # control never lay the carrier out and its anchors stay its own.
    host.size = Vector2(300, 60)
    await process_frame
    _check(carrier.size == host.size,
        "the carrier must follow the control on resize (got %s for a control of %s)"
            % [str(carrier.size), str(host.size)])

    host.free()
    await process_frame

# -------------------------------------------------------
# 4. The engine picks the carrier, 5. the click survives
# -------------------------------------------------------

func _test_live_tooltip() -> void:
    var button := Button.new()
    button.text = "Press me"
    button.position = Vector2(0, 0)
    button.size = Vector2(200, 40)
    button.pressed.connect(func() -> void: _presses += 1)
    root.add_child(button)
    await process_frame

    var carrier = WT.attach(button, LONG_HINT)
    await process_frame

    _hover(Vector2(100, 20))
    await process_frame
    var hovered: Control = root.gui_get_hovered_control()
    _check(hovered == carrier,
        "the engine must pick the CARRIER as the control under the mouse, otherwise the tooltip it shows is not ours (got %s)"
            % str(hovered))

    # The engine shows the tooltip after gui/timers/tooltip_delay_sec.
    var delay: float = float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5))
    await create_timer(delay + 0.3).timeout
    await process_frame

    var content := _find_tooltip_content(carrier)
    _check(content != null, "the engine must show the tooltip of the carrier")
    if content != null:
        _check(content.text == LONG_HINT, "the shown tooltip must carry our text")
        _check(content.autowrap_mode != TextServer.AUTOWRAP_OFF,
            "the shown tooltip must be OUR wrapping label and not the single-line default")
        _check(content.size.x <= WT.DEFAULT_MAX_WIDTH + 0.5,
            "the shown tooltip must fit the wrap width (got %.1f px)" % content.size.x)
        var line_height := float(content.get_theme_font_size("font_size"))
        _check(float(content.size.y) > line_height,
            "the long hint must really be broken into several lines (height %.1f px for a line of %.1f px)"
                % [content.size.y, line_height])

    # The click must survive the carrier: PASS and not STOP.
    _click(Vector2(100, 20))
    await process_frame
    _check(_presses == 1,
        "the click must reach the button under the carrier (got %d presses)" % _presses)

    button.free()
    await process_frame

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# The label the engine shows inside the tooltip popup of `owner`. The popup is a
# PopupPanel: it carries the themed panel background, and the content sits beside it (see
# docs.md, "Tooltips"). The popup is an INTERNAL child of the control it belongs to, hence
# get_children(true) on the way down.
func _find_tooltip_content(owner: Node) -> Label:
    for node in _walk(owner):
        if node is PopupPanel:
            for child in node.get_children():
                if child is Label:
                    return child
    return null

func _walk(node: Node) -> Array:
    var found: Array = [node]
    for child in node.get_children(true):
        found.append_array(_walk(child))
    return found

# The engine receives the mouse in LOCAL coordinates: the window of a headless run is tiny
# and the viewport is scaled into it, so a position in window coordinates would land far
# away from the control.
func _hover(pos: Vector2) -> void:
    var event := InputEventMouseMotion.new()
    event.position = pos
    event.global_position = pos
    event.relative = Vector2(1, 1)
    event.device = 0
    root.push_input(event, true)

func _click(pos: Vector2) -> void:
    _hover(pos)
    for pressed in [true, false]:
        var event := InputEventMouseButton.new()
        event.button_index = MOUSE_BUTTON_LEFT
        event.pressed = pressed
        event.position = pos
        event.global_position = pos
        event.device = 0
        root.push_input(event, true)

func _check(cond: bool, msg: String) -> void:
    if cond:
        return
    _failed = true
    print("FAILED: %s" % msg)
    push_error("ASSERT: %s" % msg)
