# Headless test of the town trade interface — the interactive rows and the trade
# settings panel that is the foundation of the town trade:
#   godot --headless --path . --script res://tests/test_town_trade_ui.gd
#
# Checked:
#   1. CENTERING. The window panel is centered in the viewport by its anchors.
#   2. ROWS. A row is an interactive control: it highlights on hover (including the
#      hover over the quality stars) and a click selects it (a third state) and opens
#      the trade panel right under the row.
#   3. PANEL. The panel carries the amount field, the "+"/"−" buttons with the step
#      tooltips, the "Permanent" checkbox (off by default, its tooltip scoped to the
#      box and not to the caption) and the confirm/cancel buttons — small square
#      buttons with the icons of a check mark and a cross and no text at all. No
#      heading row repeats the side and the name of the selected row, and the frames
#      of the buttons, of the checkbox and of the field are light enough to be seen
#      on the dark panel.
#   4. AMOUNT. Only whole positive numbers are accepted (anything else is dropped,
#      including on paste), the leading zeros are stripped, the step is 10 by default,
#      1 with Ctrl and 100 with Shift, and the amount never falls below 1.
#   5. WARNING. The route-capacity triangle appears exactly when the amount exceeds
#      the throughput of the route to the city, and its tooltip names the shortfall.
#   6. ORDER. Confirm assembles the order (the town, the side, the goods, the amount,
#      the "permanent" flag) and hands it over by the signal; the trade itself is not
#      implemented, so nothing is spent.
#
# The test opens the window on its own (no map), and stubs the route with an inner
# class instead of generating a whole map: the window only asks the map for
# get_route_to_city(row, col) -> {ok, avg_speed}.
extends SceneTree

# The hang watchdog: without it a broken _run() coroutine looks like eternal silence.
const WATCHDOG = preload("res://tests/watchdog.gd")

const TOWN_UI_SCENE := "res://scenes/TownUI.tscn"

# Real product ids (see test_town_economy): the rows are built from the common
# resource reference, so the ids must exist.
const WOOD := "wood"
const PLANKS := "planks"

# A stub of the map: the window reads the route throughput from it.
class StubMap extends Node:
    var speed := 0.0
    func get_route_to_city(_row: int, _col: int) -> Dictionary:
        return {"ok": speed > 0.0, "avg_speed": speed}

var _failed := false
var _ui = null
var _captured_order: Dictionary = {}

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    # The window is parented to a Node2D, exactly as it is under MainMap: a Control
    # under a non-Control anchors against a zero-sized rect, which is the very trap
    # the centering has to survive (it is done in code, see town_ui._center_window).
    var host := Node2D.new()
    host.name = "Host"
    get_root().add_child(host)
    _ui = load(TOWN_UI_SCENE).instantiate()
    host.add_child(_ui)
    # Two frames: one for _ready (the @onready references), one for the layout to
    # settle (the centered window needs a resolved viewport size).
    await process_frame
    await process_frame

    var town := _make_town()

    if WATCHDOG.wants_case("centered"):
        _test_centered()
    if WATCHDOG.wants_case("rows"):
        await _test_rows(town)
    if WATCHDOG.wants_case("panel"):
        await _test_panel(town)
    if WATCHDOG.wants_case("amount"):
        await _test_amount(town)
    if WATCHDOG.wants_case("warning"):
        await _test_warning(town)
    if WATCHDOG.wants_case("order"):
        await _test_order(town)

    _finish()

func _make_town() -> Dictionary:
    return {
        "id": "town_test",
        "name": "Testville",
        "row": 5,
        "col": 5,
        "treasury": 500,
        "sell_pool": [WOOD, PLANKS],
        "buy_pool": [WOOD],
        "storage": {WOOD: 120, PLANKS: 40},
        "quality": {WOOD: "perfect", PLANKS: "fine"},
    }

# -------------------------------------------------------
# 1. The window is centered
# -------------------------------------------------------

func _test_centered() -> void:
    var viewport_size: Vector2 = _ui.get_viewport().get_visible_rect().size
    var panel: Control = _ui.window_panel
    var expected := (viewport_size - panel.size) * 0.5
    _check(absf(panel.position.x - expected.x) <= 1.0
            and absf(panel.position.y - expected.y) <= 1.0,
        "the window must be centered in the viewport (position %s, expected %s, viewport %s)"
            % [str(panel.position), str(expected), str(viewport_size)])
    # The window must fit into the viewport at the default size (otherwise "centered"
    # would mean "sticking out on both sides").
    _check(panel.size.x <= viewport_size.x and panel.size.y <= viewport_size.y,
        "the window must fit into the viewport (size %s, viewport %s)"
            % [str(panel.size), str(viewport_size)])
    # And it must be inside the viewport, not pushed off its top-left corner (the
    # regression that made the whole window land outside the screen).
    _check(panel.position.x >= 0.0 and panel.position.y >= 0.0,
        "the window must not be pushed off the top-left corner (position %s)"
            % str(panel.position))
    _check(panel.position.x + panel.size.x <= viewport_size.x + 1.0
            and panel.position.y + panel.size.y <= viewport_size.y + 1.0,
        "the window must stay inside the viewport (rect %s, viewport %s)"
            % [str(Rect2(panel.position, panel.size)), str(viewport_size)])

# -------------------------------------------------------
# 2. Interactive rows
# -------------------------------------------------------

func _test_rows(town: Dictionary) -> void:
    _ui.open_town(town, true)
    await process_frame
    var rows := _rows_of(_ui.sell_list)
    _check(rows.size() == 2, "two sell rows are expected (got %d)" % rows.size())
    if rows.is_empty():
        return
    var row: Control = rows[0]
    _check(row.has_meta("town_resource_row"), "a row must be marked as a resource row")
    _check(not str(row.get_meta("town_row_name", "")).is_empty(),
        "a row must carry the display name of the resource")
    _check(row.mouse_filter == Control.MOUSE_FILTER_STOP,
        "a row must catch the mouse, otherwise it cannot react to hover and click")

    # Hover: the background changes and changes back.
    var normal: Color = row.get_theme_stylebox("panel").bg_color
    row.mouse_entered.emit()
    var hovered: Color = row.get_theme_stylebox("panel").bg_color
    _check(hovered != normal, "hover must change the background of the row")
    row.mouse_exited.emit()
    _check(row.get_theme_stylebox("panel").bg_color == normal,
        "leaving the row must return the normal background")

    # The quality stars are not a dead zone: hovering them highlights the row too.
    var display_name := str(row.get_meta("town_row_name", ""))
    var stars: Label = _ui._sell_quality_labels.get(display_name, null)
    _check(stars != null, "the sell row must have the quality stars")
    if stars != null:
        _check(stars.mouse_filter == Control.MOUSE_FILTER_STOP,
            "the quality stars must keep catching the mouse for their own tooltip")
        stars.mouse_entered.emit()
        _check(row.get_theme_stylebox("panel").bg_color != normal,
            "hovering the quality stars must highlight the row as well")
        stars.mouse_exited.emit()

    # Click: the row becomes selected and the panel opens under it.
    _click(row)
    _check(_ui._selected_key == str(row.get_meta("town_row_key", "")),
        "a click must select the row (selected key \"%s\")" % _ui._selected_key)
    _check(row.get_theme_stylebox("panel").bg_color == _ui.ROW_SELECTED_COLOR,
        "the selected row must keep the selected background")
    _check(_ui._trade_panel != null and is_instance_valid(_ui._trade_panel),
        "a click on a row must open the trade panel")
    if _ui._trade_panel != null:
        _check(_ui._trade_panel.get_parent() == row.get_parent(),
            "the trade panel must live in the same column as its row")
        _check(_ui._trade_panel.get_index() == row.get_index() + 1,
            "the trade panel must sit right under its row (panel %d, row %d)"
                % [_ui._trade_panel.get_index(), row.get_index()])

    # A repeated click on the selected row closes the panel.
    _click(row)
    _check(_ui._trade_panel == null, "a repeated click must close the trade panel")
    _check(_ui._selected_key.is_empty(), "a repeated click must clear the selection")
    _check(row.get_theme_stylebox("panel").bg_color == normal,
        "the deselected row must return the normal background")

# -------------------------------------------------------
# 3. The panel composition
# -------------------------------------------------------

func _test_panel(town: Dictionary) -> void:
    _ui.open_town(town, true)
    await process_frame
    var row: Control = _rows_of(_ui.sell_list)[0]
    _click(row)
    await process_frame

    # No heading of the kind "Selling: Wood": the highlighted row the panel hangs
    # under already names the resource and the side, so a heading only repeated it.
    var display_name := str(row.get_meta("town_row_name", ""))
    _check(_find_label(_ui._trade_panel, "Selling: " + display_name) == null
            and _find_label(_ui._trade_panel, "Buying: " + display_name) == null,
        "the panel must not repeat the side and the name in a heading")

    _check(_ui._amount_edit != null and is_instance_valid(_ui._amount_edit),
        "the panel must have the amount field")
    _check(_ui._amount_edit.text.is_valid_int() and int(_ui._amount_edit.text) == 10,
        "the amount field must start at the default step (got \"%s\")" % _ui._amount_edit.text)

    var plus: Button = _ui._trade_panel.find_child("PlusButton", true, false)
    var minus: Button = _ui._trade_panel.find_child("MinusButton", true, false)
    _check(plus != null, "the panel must have the \"+\" button")
    _check(minus != null, "the panel must have the \"−\" button")
    if plus != null:
        _check(plus.tooltip_text.contains("Ctrl") and plus.tooltip_text.contains("Shift")
                and plus.tooltip_text.contains("10"),
            "the \"+\" tooltip must explain the steps (got \"%s\")" % plus.tooltip_text)
    if minus != null:
        _check(minus.tooltip_text.contains("Ctrl") and minus.tooltip_text.contains("Shift")
                and minus.tooltip_text.contains("100"),
            "the \"−\" tooltip must explain the steps (got \"%s\")" % minus.tooltip_text)

    # The "Permanent" checkbox: off by default, and the tooltip of the contract
    # belongs to the box, not to the caption next to it.
    _check(_ui._permanent_check != null and is_instance_valid(_ui._permanent_check),
        "the panel must have the \"Permanent\" checkbox")
    if _ui._permanent_check != null:
        _check(not _ui._permanent_check.button_pressed,
            "the \"Permanent\" checkbox must be off by default")
        _check(not _ui._permanent_check.tooltip_text.is_empty(),
            "the \"Permanent\" checkbox must explain itself in a tooltip")
        _check(_ui._permanent_check.text.is_empty(),
            "the checkbox must be textless, otherwise its tooltip would cover the caption too")
    var permanent_label: Label = _ui._trade_panel.find_child("PermanentLabel", true, false)
    _check(permanent_label != null,
        "the \"Permanent\" caption must be a label of its own, not the text of the checkbox")
    if permanent_label != null:
        _check(permanent_label.text == "Permanent",
            "the caption must read \"Permanent\" (got \"%s\")" % permanent_label.text)
        _check(permanent_label.tooltip_text.is_empty(),
            "the caption of the checkbox must not carry the tooltip (got \"%s\")"
                % permanent_label.tooltip_text)

    # Confirm / cancel: small square buttons with an icon and no text.
    var confirm: Button = _ui._trade_panel.find_child("ConfirmButton", true, false)
    _check(confirm != null, "the panel must have the confirm button")
    var cancel: Button = _ui._trade_panel.find_child("CancelButton", true, false)
    _check(cancel != null, "the panel must have the cancel button")
    for entry in [["confirm", confirm], ["cancel", cancel]]:
        var what: String = entry[0]
        var button: Button = entry[1]
        if button == null:
            continue
        _check(button.text.is_empty(),
            "the %s button must have no text (got \"%s\")" % [what, button.text])
        _check(absf(button.custom_minimum_size.x - button.custom_minimum_size.y) <= 0.01,
            "the %s button must be square (size %s)" % [what, str(button.custom_minimum_size)])
        _check(button.icon != null, "the %s button must carry its icon" % what)
        _check(not button.tooltip_text.is_empty(),
            "the %s button must explain itself in a tooltip" % what)
        _check_visible_frame(button, what)

    # The frames of the other controls of the panel are just as visible.
    if _ui._permanent_check != null:
        _check_visible_frame(_ui._permanent_check, "the \"Permanent\" checkbox")
    if _ui._amount_edit != null:
        _check_visible_frame(_ui._amount_edit, "the amount field")

    if cancel != null:
        cancel.pressed.emit()
        _check(_ui._trade_panel == null, "cancel must close the panel")
        _check(_ui._selected_key.is_empty(), "cancel must clear the selection")

# -------------------------------------------------------
# 4. The amount: input, steps, validation
# -------------------------------------------------------

func _test_amount(town: Dictionary) -> void:
    _ui.open_town(town, true)
    await process_frame
    _click(_rows_of(_ui.sell_list)[0])
    await process_frame

    # Only digits survive, the leading zeros and the signs are dropped.
    _type("12a3-4")
    _check(_ui._amount_edit.text == "1234",
        "letters and signs must be dropped (got \"%s\")" % _ui._amount_edit.text)
    _type("007")
    _check(_ui._amount_edit.text == "7",
        "the leading zeros must be stripped (got \"%s\")" % _ui._amount_edit.text)
    _type("-5")
    _check(_ui._amount_edit.text == "5",
        "a negative input must not survive (got \"%s\")" % _ui._amount_edit.text)
    _type("3.5")
    _check(_ui._amount_edit.text == "35",
        "the fractional part must not survive as a fraction (got \"%s\")" % _ui._amount_edit.text)
    _check(_ui._amount_edit.max_length > 0,
        "the amount field must have a digit cap")

    # The steps by the modifiers.
    _check(_ui._amount_step(false, false) == 10, "the default step must be 10")
    _check(_ui._amount_step(true, false) == 1, "Ctrl must switch the step to 1")
    _check(_ui._amount_step(false, true) == 100, "Shift must switch the step to 100")
    _check(_ui._amount_step(true, true) == 1, "Ctrl must win when both modifiers are held")

    # "+"/"−" change the amount; it never falls below 1.
    _ui._set_amount(10)
    _ui._add_amount(10)
    _check(_ui._current_amount() == 20, "the \"+\" button must add the step")
    _ui._add_amount(-100)
    _check(_ui._current_amount() == 1, "the amount must never fall below 1")

    # An empty field is not a valid order: the confirm button is disabled.
    _type("")
    _check(_ui._amount_edit.text == "", "an empty input must stay empty")
    _check(_ui._confirm_button.disabled, "confirm must be disabled without a positive amount")
    _type("5")
    _check(not _ui._confirm_button.disabled, "confirm must be enabled for a positive amount")

# -------------------------------------------------------
# 5. The route-capacity warning
# -------------------------------------------------------

func _test_warning(town: Dictionary) -> void:
    _ui.open_town(town, true)
    await process_frame
    _click(_rows_of(_ui.sell_list)[0])
    await process_frame
    _check(_ui._warning_badge != null, "the panel must have the warning badge")

    # No map: the capacity is taken as zero, so any amount warns.
    _ui._map = null
    _ui._set_amount(10)
    _check(_ui._warning_badge.visible,
        "without a route any positive amount must warn")

    # A stub route with a throughput of 100 units/sec.
    var stub := StubMap.new()
    stub.speed = 100.0
    get_root().add_child(stub)
    _ui._map = stub
    _check(is_equal_approx(_ui._route_capacity(), 100.0),
        "the capacity must be the average speed of the route (got %s)" % str(_ui._route_capacity()))

    _ui._set_amount(10)
    _check(not _ui._warning_badge.visible,
        "an amount within the route throughput must not warn")
    _ui._set_amount(100)
    _check(not _ui._warning_badge.visible,
        "an amount exactly at the route throughput must not warn")
    _ui._set_amount(200)
    _check(_ui._warning_badge.visible,
        "an amount above the route throughput must warn")
    _check(_ui._warning_badge.tooltip_text.contains("100"),
        "the warning tooltip must name the route throughput (got \"%s\")"
            % _ui._warning_badge.tooltip_text)

    _check(not _ui._exceeds_capacity(0, 100.0), "a zero amount must never warn")
    _check(_ui._exceeds_capacity(101, 100.0), "the rule must be \"strictly above\"")
    _check(not _ui._exceeds_capacity(100, 100.0), "the rule must not warn at the limit")

    _ui._map = null
    stub.queue_free()

# -------------------------------------------------------
# 6. The order the panel assembles
# -------------------------------------------------------

func _test_order(town: Dictionary) -> void:
    _ui.open_town(town, true)
    await process_frame
    var row: Control = _rows_of(_ui.sell_list)[0]
    _click(row)
    await process_frame

    _ui._set_amount(25)
    _ui._permanent_check.button_pressed = true
    _captured_order = {}
    if not _ui.trade_order_submitted.is_connected(_capture_order):
        _ui.trade_order_submitted.connect(_capture_order)
    _ui._confirm_button.pressed.emit()

    _check(not _captured_order.is_empty(),
        "confirm must hand the order over by the signal")
    if _captured_order.is_empty():
        return
    _check(str(_captured_order.get("town_id", "")) == "town_test",
        "the order must carry the town id (got \"%s\")" % str(_captured_order.get("town_id", "")))
    _check(str(_captured_order.get("side", "")) == "sell",
        "the order must carry the side (got \"%s\")" % str(_captured_order.get("side", "")))
    _check(not str(_captured_order.get("product_id", "")).is_empty(),
        "the order must carry the product id")
    _check(int(_captured_order.get("amount", 0)) == 25,
        "the order must carry the amount (got %s)" % str(_captured_order.get("amount", 0)))
    _check(bool(_captured_order.get("permanent", false)),
        "the order must carry the \"permanent\" flag")
    _check(_captured_order.has("route_capacity"),
        "the order must carry the route capacity")
    _check(_ui._last_order == _captured_order,
        "the window must keep the last order it assembled")
    # The trade is not implemented: the panel says so and stays open.
    _check(_ui._panel_note != null and _ui._panel_note.visible
            and not _ui._panel_note.text.is_empty(),
        "the panel must report that the trade is not implemented yet")

func _capture_order(order: Dictionary) -> void:
    _captured_order = order

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# The resource rows of a column (the rows carry the row marker; the category headers
# and the trade panel do not).
func _rows_of(container: Node) -> Array:
    var rows: Array = []
    for child in container.get_children():
        if child.has_meta("town_resource_row"):
            rows.append(child)
    return rows

# Simulates a left click on a row: the engine delivers it as the gui_input signal.
func _click(row: Control) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = MOUSE_BUTTON_LEFT
    event.pressed = true
    row.gui_input.emit(event)

# Simulates typing into the amount field: the engine sets the text first and then
# emits text_changed, so the test mirrors that order.
func _type(raw: String) -> void:
    _ui._amount_edit.text = raw
    _ui._on_amount_text_changed(raw)

# The first Label of the subtree whose text is exactly `text` (null if there is none).
func _find_label(root: Node, text: String) -> Label:
    if root == null:
        return null
    for child in root.get_children():
        if child is Label and str(child.text) == text:
            return child
        var found := _find_label(child, text)
        if found != null:
            return found
    return null

# The control must carry an explicit frame that is actually visible on the dark panel:
# a border on all four sides and a LIGHT border colour (the default theme draws a dark
# frame on a dark fill — the "dark on dark" the frame is there to fix).
func _check_visible_frame(control: Control, what: String) -> void:
    var frame := control.get_theme_stylebox("normal") as StyleBoxFlat
    _check(frame != null, "%s must carry an explicit stylebox" % what)
    if frame == null:
        return
    _check(frame.border_width_left > 0 and frame.border_width_top > 0
            and frame.border_width_right > 0 and frame.border_width_bottom > 0,
        "%s must have a border on all four sides" % what)
    _check(frame.border_color.get_luminance() > 0.4,
        "%s must have a light border against the dark panel (luminance %.2f)"
            % [what, frame.border_color.get_luminance()])

func _finish() -> void:
    if _ui != null and is_instance_valid(_ui):
        var host: Node = _ui.get_parent()
        if host != null:
            host.remove_child(_ui)
        _ui.free()
        if host != null and is_instance_valid(host):
            host.free()
    WATCHDOG.report_skipped()
    if _failed:
        print("TOWN TRADE UI TEST FAILED")
        quit(1)
    else:
        print("TOWN TRADE UI TEST OK")
        quit(0)

func _check(cond: bool, msg: String) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        _failed = true
