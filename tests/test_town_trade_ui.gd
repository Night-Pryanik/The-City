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
#      buttons with the icons of a check mark and a cross and no text at all. The deal
#      cancellation button is shown only when a deal of the selected mode exists. No
#      heading row repeats the side and the name of the selected row, and the frames
#      of the buttons, of the checkbox and of the field are light enough to be seen
#      on the dark panel.
#   4. AMOUNT. Only whole positive numbers are accepted (anything else is dropped,
#      including on paste), the leading zeros are stripped, the step is 10 by default,
#      1 with Ctrl and 100 with Shift, and the amount never falls below 1.
#   5. WARNING. The route-capacity triangle appears exactly when the amount exceeds
#      the throughput of the route to the city, and its tooltip names the shortfall —
#      through the wrapping tooltip (see wrapped_tooltip.gd), because the hint is long.
#   6. ORDER. Confirm assembles the order (the town, the side, the goods, the amount,
#      the "permanent" flag and the unit price of the row) and hands it over by the
#      signal; the window itself claims nothing about the outcome — the panel carries
#      no message of its own, the reply of the mechanics is reported by the HUD.
#   7. NO TRADE. Without a road to the town the window still opens and the pools are
#      still listed, but the rows are inert — dimmed and not wired — and NO trade
#      settings panel can be opened: neither by a click nor by a direct call.
#   8. PRICE. Every row shows the price of ONE unit in coins: the market price with the
#      quality multiplier of the level the row shows (the sale column, where the stars
#      name that level) or the plain market price (the purchase column, where the
#      quality of what the city will deliver is not known).
#   9. TOTAL. The panel shows the sum of the order in the free space left of the
#      confirm/cancel buttons, and it follows the amount in REAL TIME — the field and
#      the "+"/"−" buttons both go through the same update. A sale column totals as a
#      cost (the city pays), a purchase column as an income (the city is paid).
#   10. DEAL STATUS. The panel names an existing contract or delivery for the selected
#       good, and hides the line when there is no deal of the selected type.
#  11. CONTRACT. A town carries one contract per good (see town_trade_manager), so a click
#      on the row of a good that already has one opens the settings of THAT contract: the
#      amount comes prefilled, the "Permanent" flag is on, the total is counted at the price
#      frozen at the signing, and the deal-cancel button appears in contract mode. Closing the contract
#      turns the panel back into a fresh order on the same row.
#  12. CONTRACT SYNC. The panel follows the contract of the good it shows: an order that has
#      just been signed turns into an edit of the new contract at once (the manager announces
#      the change and the window re-reads it), so the new deal can be closed or corrected
#      without closing and reopening the panel. A contract that has gone turns the panel back
#      into a fresh order, and a change to some OTHER good leaves the panel untouched.
#
# The test opens the window on its own (no map), and stubs the route with an inner
# class instead of generating a whole map: the window only asks the map for
# get_route_to_city(row, col) -> {ok, avg_speed}.
extends SceneTree

# The hang watchdog: without it a broken _run() coroutine looks like eternal silence.
const WATCHDOG = preload("res://tests/watchdog.gd")

const TOWN_UI_SCENE := "res://scenes/TownUI.tscn"

# The wrapping tooltip of the window's long hints. It is taken by path and not by the
# global class name: with --script the class cache may not be there yet (the same note
# as in watchdog.gd).
const WRAPPED_TOOLTIP = preload("res://scripts/wrapped_tooltip.gd")

# Real product ids (see test_town_economy): the rows are built from the common
# resource reference, so the ids must exist.
const WOOD := "wood"
const PLANKS := "planks"

# A stub of the map: the window reads the route throughput from it.
class StubMap extends Node:
    var speed := 0.0
    func get_route_to_city(_row: int, _col: int) -> Dictionary:
        return {"ok": speed > 0.0, "avg_speed": speed}

# A stub of the map that knows the standing contracts of a town: the window reads the
# contract of the selected row through get_town_contract (see town_ui._sync_selected_contract)
# and asks to close it by the signal contract_close_requested.
class ContractMap extends Node:
    var contracts: Dictionary = {}
    var deliveries: Array = []
    var cancelled_deliveries: Array = []
    func get_route_to_city(_row: int, _col: int) -> Dictionary:
        return {"ok": false}
    func get_town_contract(town_id: String, product_id: String) -> Dictionary:
        var key := "%s|%s" % [town_id, product_id]
        return (contracts.get(key, {}) as Dictionary).duplicate()
    func get_town_deliveries() -> Array:
        return deliveries.duplicate(true)
    func close_contract(contract_id: String) -> void:
        for key in contracts.keys():
            if str((contracts[key] as Dictionary).get("id", "")) == contract_id:
                contracts.erase(key)
    func cancel_town_delivery(town_id: String, product_id: String) -> Dictionary:
        cancelled_deliveries.append({"town_id": town_id, "product_id": product_id})
        for index in range(deliveries.size() - 1, -1, -1):
            var delivery: Dictionary = deliveries[index]
            if str(delivery.get("town_id", "")) == town_id \
                    and str(delivery.get("product_id", "")) == product_id:
                deliveries.remove_at(index)
        return {"ok": true, "message": "delivery cancelled"}

var _failed := false
var _ui = null
var _captured_order: Dictionary = {}
# The data reference. Taken through the tree and not by the autoload name: with
# --script the test is compiled BEFORE the autoloads are registered (the same note as
# in test_icon_registry.gd).
var _gdata = null

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

    # The prices are read from the common data, so the reference must be alive. Nothing
    # loads the data in a --script run (the game does it from the main menu / the map,
    # and the watchdog only RELOADS it once it is loaded), so the test loads it itself.
    _gdata = get_root().get_node_or_null("GameData")
    _check(_gdata != null, "the GameData autoload must be registered")
    if _gdata != null and not _gdata.data_loaded:
        _gdata.load_all_data()
    _check(_gdata != null and _gdata.data_loaded, "the game data must be loaded")

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
    if WATCHDOG.wants_case("no_trade"):
        await _test_no_trade(town)
    if WATCHDOG.wants_case("price"):
        await _test_price(town)
    if WATCHDOG.wants_case("total"):
        await _test_total(town)
    if WATCHDOG.wants_case("deal_status"):
        await _test_deal_status(town)
    if WATCHDOG.wants_case("contract"):
        await _test_contract(town)
    if WATCHDOG.wants_case("deal_cancel"):
        await _test_deal_cancel(town)
    if WATCHDOG.wants_case("contract_sync"):
        await _test_contract_sync(town)

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
    _check(_ui._amount_step(false, false) == 1, "the default step must be 1")
    _check(_ui._amount_step(true, false) == 10, "Ctrl must switch the step to 10")
    _check(_ui._amount_step(false, true) == 100, "Shift must switch the step to 100")
    _check(_ui._amount_step(true, true) == 10, "Ctrl must win when both modifiers are held")

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
    var warn_tip = _tip_carrier(_ui._warning_badge)
    _check(warn_tip != null,
        "the warning must carry the wrapping tooltip (the hint is long)")
    if warn_tip != null:
        _check(warn_tip.tooltip_text.contains("100"),
            "the warning tooltip must name the route throughput (got \"%s\")"
                % warn_tip.tooltip_text)
        # The same rule as the supply line: the hint is long, so it must come out of the
        # wrapping mechanism instead of the single line the engine builds by itself.
        var warn_content: Label = WRAPPED_TOOLTIP.build(warn_tip.tooltip_text)
        _check(warn_content.autowrap_mode != TextServer.AUTOWRAP_OFF,
            "the route warning tooltip must be wrapping, otherwise it is a single unreadable line")
        # The hint is rebuilt on every change of the amount — and the badge must keep ONE
        # carrier: a second one would sit on top of the first and leak on every keystroke.
        _ui._set_amount(201)
        _check(_ui._warning_badge.get_child_count() == 1,
            "the warning badge must keep a single carrier when the hint is rebuilt (got %d children)"
                % _ui._warning_badge.get_child_count())

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
    _check(int(_captured_order.get("unit_price", 0)) > 0,
        "the order must carry the unit price the row showed (got %s)"
            % str(_captured_order.get("unit_price", 0)))
    _check(_ui._last_order == _captured_order,
        "the window must keep the last order it assembled")
    # The window itself makes no claim about the outcome: it hands the order over and
    # stays open. The reply of the mechanics is reported by the HUD (see
    # main_map._on_town_trade_order), so the panel carries no message of its own.
    _check(_ui._trade_panel != null
            and _ui._trade_panel.find_child("PanelNote", true, false) == null,
        "the trade panel must carry no message of its own — the outcome goes to the HUD")
    _check(not _ui.has_method("set_order_result"),
        "the window must not accept a trade result to display")

func _capture_order(order: Dictionary) -> void:
    _captured_order = order

# -------------------------------------------------------
# 7. No road — no trade settings
# -------------------------------------------------------

func _test_no_trade(town: Dictionary) -> void:
    _ui.open_town(town, false)
    await process_frame

    # The window itself opens and the pools stay readable: without a road the player
    # still sees what the town has and what it lacks.
    var rows := _rows_of(_ui.sell_list)
    _check(rows.size() == 2, "the rows must be listed even without a road (got %d)" % rows.size())
    _check(not _ui._can_trade(), "_can_trade must report the trade as unavailable")
    if rows.is_empty():
        return

    var row: Control = rows[0]
    _check(row.modulate == _ui.ROW_DISABLED_MODULATE,
        "a row of a town without a road must be dimmed (got %s)" % str(row.modulate))

    # Not wired at all: the hover does not highlight the row.
    var normal: Color = row.get_theme_stylebox("panel").bg_color
    row.mouse_entered.emit()
    _check(row.get_theme_stylebox("panel").bg_color == normal,
        "a row of a town without a road must not react to hover")
    row.mouse_exited.emit()

    # And a click opens nothing at all.
    _click(row)
    await process_frame
    _check(_ui._selected_key.is_empty(),
        "a click must not select a row when the trade is unavailable (got \"%s\")"
            % _ui._selected_key)
    _check(_ui._trade_panel == null, "no trade panel may be opened without a road")

    # The guard is a second lock: even a direct call cannot open the panel.
    _ui._open_trade_panel(10)
    _check(_ui._trade_panel == null, "_open_trade_panel must be a no-op without a road")
    _ui._toggle_selection("sell", WOOD, "Wood")
    _check(_ui._selected_key.is_empty(),
        "_toggle_selection must be a no-op without a road (got \"%s\")" % _ui._selected_key)

    # With the road the very same town becomes interactive.
    _ui.open_town(town, true)
    await process_frame
    _check(_ui._can_trade(), "_can_trade must report the trade as available")
    var live: Control = _rows_of(_ui.sell_list)[0]
    _check(live.modulate == Color(1, 1, 1, 1),
        "a row of a town with a road must not be dimmed (got %s)" % str(live.modulate))
    _click(live)
    await process_frame
    _check(_ui._trade_panel != null, "with a road a click must open the trade panel")

# -------------------------------------------------------
# 8. The price of one unit in the rows
# -------------------------------------------------------

func _test_price(town: Dictionary) -> void:
    _ui.open_town(town, true)
    await process_frame

    var quality: Dictionary = town.get("quality", {})
    var market := float(_gdata.get_price(WOOD))
    var expected_sell := int(round(
            market * _gdata.get_quality_price_multiplier(str(quality.get(WOOD, "")))))
    var expected_buy := int(round(market))

    # The sale column: the town holds the goods, the row shows their stars, and the
    # price carries the multiplier of exactly that level.
    var row: Control = _rows_of(_ui.sell_list)[0]
    var price_label := _find_price_label(row)
    _check(price_label != null, "a row of the sale column must carry the price of a unit")
    if price_label == null:
        return
    _check(price_label.text == str(expected_sell),
        "the sale row must show the market price with the quality of the town (got \"%s\", expected \"%d\")"
            % [price_label.text, expected_sell])
    _check(price_label.tooltip_text.contains(str(expected_sell)),
        "the price must explain itself in a tooltip (got \"%s\")" % price_label.tooltip_text)
    _check(price_label.mouse_filter == Control.MOUSE_FILTER_STOP,
        "the price must keep catching the mouse for its own tooltip")

    # The price is not a dead zone: hovering it highlights the row, like the stars.
    var normal: Color = row.get_theme_stylebox("panel").bg_color
    price_label.mouse_entered.emit()
    _check(row.get_theme_stylebox("panel").bg_color != normal,
        "hovering the price must highlight the row as well")
    price_label.mouse_exited.emit()
    _check(row.get_theme_stylebox("panel").bg_color == normal,
        "leaving the price must return the normal background")

    # A row of the purchase column has no stars, and the quality of what the city will
    # deliver is not known at the row: the plain market price.
    var buy_row: Control = _rows_of(_ui.buy_list)[0]
    var buy_price := _find_price_label(buy_row)
    _check(buy_price != null, "a row of the purchase column must carry the price as well")
    if buy_price != null:
        _check(buy_price.text == str(expected_buy),
            "the purchase row must show the plain market price (got \"%s\", expected \"%d\")"
                % [buy_price.text, expected_buy])
    _check(expected_sell >= expected_buy,
        "a better quality must not make a unit cheaper (quality %d, market %d)"
            % [expected_sell, expected_buy])

# -------------------------------------------------------
# 9. The live total of the order
# -------------------------------------------------------

func _test_total(town: Dictionary) -> void:
    _ui.open_town(town, true)
    await process_frame

    var quality: Dictionary = town.get("quality", {})
    var market := float(_gdata.get_price(WOOD))
    var sell_price := int(round(
            market * _gdata.get_quality_price_multiplier(str(quality.get(WOOD, "")))))
    var buy_price := int(round(market))

    # --- The sale column: the town sells, so the city pays ---
    _click(_rows_of(_ui.sell_list)[0])
    await process_frame
    _check(_ui._total_label != null and is_instance_valid(_ui._total_label),
        "the panel must show the total of the order")
    if _ui._total_label == null:
        return

    # It lives in the free space LEFT of the confirm/cancel buttons.
    var buttons_row: Node = _ui._confirm_button.get_parent()
    var cancel_btn: Button = _ui._trade_panel.find_child("CancelButton", true, false)
    _check(_ui._total_label.get_parent() == buttons_row,
        "the total must share the row with the confirm/cancel buttons")
    _check(buttons_row.get_child(0) == _ui._total_label,
        "the total must be the first control of that row, left of the buttons")
    _check(cancel_btn != null and cancel_btn.get_parent() == buttons_row,
        "the cancel button must share the row with the total")
    _check(_ui._total_label.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
        "the total must take the free space, which is what pushes the buttons right")

    _ui._set_amount(25)
    _check(_ui._total_label.text == "Cost: %d" % (25 * sell_price),
        "the sale column must total as a cost (got \"%s\", expected \"Cost: %d\")"
            % [_ui._total_label.text, 25 * sell_price])

    # Real time: the "+"/"−" buttons and the field go through the same update.
    _ui._add_amount(10)
    _check(_ui._total_label.text == "Cost: %d" % (35 * sell_price),
        "the total must follow the \"+\" button (got \"%s\")" % _ui._total_label.text)
    _ui._add_amount(-100)
    _check(_ui._total_label.text == "Cost: %d" % sell_price,
        "the total must follow the \"−\" button (got \"%s\")" % _ui._total_label.text)
    _type("7")
    _check(_ui._total_label.text == "Cost: %d" % (7 * sell_price),
        "the total must follow the typing (got \"%s\")" % _ui._total_label.text)
    _type("")
    _check(_ui._total_label.text == "Cost: 0",
        "an empty amount must total 0 (got \"%s\")" % _ui._total_label.text)

    # --- Permanent contract: the total is shown per second ---
    _ui._set_amount(25)
    var permanent_check: CheckBox = _ui._trade_panel.find_child("PermanentCheck", true, false)
    _check(permanent_check != null, "the panel must have the Permanent checkbox")
    if permanent_check != null:
        permanent_check.button_pressed = true
        await process_frame
        _check(_ui._total_label.text == "Cost: %d/sec" % (25 * sell_price),
            "permanent sale must show cost per second (got \"%s\")"
                % _ui._total_label.text)
        permanent_check.button_pressed = false
        await process_frame
        _check(_ui._total_label.text == "Cost: %d" % (25 * sell_price),
            "disabling permanent must revert to plain cost (got \"%s\")"
                % _ui._total_label.text)

    # --- The purchase column: the town buys, so the city is paid ---
    _click(_rows_of(_ui.buy_list)[0])
    await process_frame
    _ui._set_amount(4)
    _check(_ui._total_label.text == "Income: %d" % (4 * buy_price),
        "the purchase column must total as an income (got \"%s\", expected \"Income: %d\")"
            % [_ui._total_label.text, 4 * buy_price])

    # A new row selection resets the permanent flag, so the total is plain again.
    var buy_permanent: CheckBox = _ui._trade_panel.find_child("PermanentCheck", true, false)
    if buy_permanent != null:
        buy_permanent.button_pressed = true
        await process_frame
        _check(_ui._total_label.text == "Income: %d/sec" % (4 * buy_price),
            "permanent purchase must show income per second (got \"%s\")"
                % _ui._total_label.text)

# -------------------------------------------------------
# 10. Current deal status in the panel
# -------------------------------------------------------

func _test_deal_status(town: Dictionary) -> void:
    var local: Dictionary = town.duplicate(true)
    var map := ContractMap.new()
    _ui.set_map(map)
    _ui.open_town(local, true)
    await process_frame
    _click(_rows_of(_ui.sell_list)[0])
    await process_frame
    _check(_ui._deal_status_label != null, "the panel must have the deal status line")
    if _ui._deal_status_label == null:
        return
    _check(not _ui._deal_status_label.visible,
        "the status line must stay hidden when the selected good has no deal")
    _check(_ui._deal_status_label.tooltip_text.is_empty(),
        "the deal status line must not carry a tooltip")

    map.contracts["town_test|%s" % WOOD] = {
        "id": "contract_status_test", "amount": 7,
    }
    _ui.on_contracts_changed()
    await process_frame
    _check(_ui._deal_status_label.visible
            and _ui._deal_status_label.text == _ui.tr("Contract: %d units/sec") % 7,
        "an existing contract must be shown with its amount (got \"%s\")"
            % _ui._deal_status_label.text)

    map.deliveries.append({
        "town_id": "town_test", "product_id": WOOD, "remaining": 4,
    })
    _ui.refresh_storage()
    _ui._permanent_check.set_pressed_no_signal(false)
    _ui._on_permanent_toggled(false)
    await process_frame
    _check(_ui._deal_status_label.visible
            and _ui._deal_status_label.text == _ui.tr("One-time deal: %d units in transit") % 4,
        "an existing one-time deal must show its remaining amount (got \"%s\")"
            % _ui._deal_status_label.text)

    map.deliveries[0]["remaining"] = 0
    _ui._sync_selected_delivery()
    _ui._update_deal_status_label()
    _check(not _ui._deal_status_label.visible,
        "a completed delivery must not be shown as an active deal")

# -------------------------------------------------------
# 11. Editing an existing contract
# -------------------------------------------------------

func _test_contract(town: Dictionary) -> void:
    var map := ContractMap.new()
    get_root().add_child(map)
    _ui._map = map
    # The window closes the contract through its signal; the stub answers it, exactly as the
    # map does in the game (main_map._on_town_contract_close_requested).
    _ui.contract_close_requested.connect(map.close_contract)

    var frozen_price := 7
    map.contracts["town_test|%s" % WOOD] = {
        "id": "contract_3",
        "town_id": "town_test",
        "town_name": "Testville",
        "product_id": WOOD,
        "amount": 40,
        "unit_price": frozen_price,
        "cost_per_tick": 40 * frozen_price,
    }

    # A click on the good of the contract opens the panel as an EDIT of that contract: the
    # pair (town, good) is the identity of a deal (see town_trade_manager), so a row that
    # already carries a contract never opens a fresh signing.
    _ui.open_town(town, true)
    await process_frame
    var wood_row := _row_by_key(_ui.sell_list, "sell:%s" % WOOD)
    _check(wood_row != null, "the town must have a row for the good of the contract")
    if wood_row == null:
        return
    _click(wood_row)
    await process_frame
    _check(_ui._selected_key == "sell:%s" % WOOD,
        "a click on the good of the contract must select its row (got \"%s\")" % _ui._selected_key)
    _check(_ui._trade_panel != null and is_instance_valid(_ui._trade_panel),
        "a click on the good of the contract must open the trade panel")
    if _ui._trade_panel == null:
        return
    _check(_ui._amount_edit.text == "40",
        "the panel must start from the amount of the contract (got \"%s\")" % _ui._amount_edit.text)
    _check(_ui._permanent_check.button_pressed,
        "the panel of an existing contract must have the \"Permanent\" flag on")
    # The total is counted at the price FROZEN at the signing and not at the current market:
    # an edit changes the amount only.
    _ui._set_amount(40)
    _check(_ui._total_label.text == "Cost: %d/sec" % (40 * frozen_price),
        "an edit must total at the frozen price (got \"%s\", expected \"Cost: %d/sec\")"
            % [_ui._total_label.text, 40 * frozen_price])
    var close_button: Button = _ui._trade_panel.find_child("CancelDealButton", true, false)
    _check(close_button != null and close_button.visible,
        "the panel of an existing contract must offer to close it")
    if close_button != null:
        _check(close_button.tooltip_text == _ui.tr("Close the contract"),
            "the close button must identify contract cancellation")
        _check(close_button.icon != null, "the close button must carry its icon")

    # The order carries the frozen price as well, so the treasury is charged exactly the sum
    # the panel showed.
    _captured_order = {}
    if not _ui.trade_order_submitted.is_connected(_capture_order):
        _ui.trade_order_submitted.connect(_capture_order)
    _ui._confirm_button.pressed.emit()
    _check(int(_captured_order.get("unit_price", 0)) == frozen_price,
        "the edit order must carry the frozen price (got %s)"
            % str(_captured_order.get("unit_price", 0)))
    _check(int(_captured_order.get("amount", 0)) == 40,
        "the edit order must carry the amount of the panel (got %s)"
            % str(_captured_order.get("amount", 0)))
    _check(bool(_captured_order.get("permanent", false)),
        "the edit order must be a standing contract")

    # The confirm button says what it will do: update the contract, or — with the
    # "Permanent" flag off — place an ordinary order and leave the contract alone.
    _check(_ui._confirm_button.tooltip_text == _ui.tr("Update the contract"),
        "confirm must promise an update while a contract is edited (got \"%s\")"
            % _ui._confirm_button.tooltip_text)
    _ui._permanent_check.button_pressed = false
    await process_frame
    _check(_ui._confirm_button.tooltip_text == _ui.tr("Confirm"),
        "with the \"Permanent\" flag off confirm must not promise an update (got \"%s\")"
            % _ui._confirm_button.tooltip_text)
    _ui._permanent_check.button_pressed = true
    await process_frame
    _check(_ui._confirm_button.tooltip_text == _ui.tr("Update the contract"),
        "turning the flag back on must promise an update again (got \"%s\")"
            % _ui._confirm_button.tooltip_text)

    # Closing: the contract goes away, and the panel turns back into a FRESH order on the
    # very same row.
    if close_button == null:
        return
    close_button.pressed.emit()
    await process_frame
    _check(map.contracts.is_empty(), "the close must reach the map")
    _check(_ui._selected_contract.is_empty(),
        "the panel must leave the edit mode after the close")
    _check(_ui._selected_key == "sell:%s" % WOOD,
        "the row must stay selected after the close")
    _check(_ui._trade_panel != null and is_instance_valid(_ui._trade_panel),
        "the panel must stay open after the close")
    _check(_ui._amount_edit.text == "10",
        "a fresh order must start from the default step (got \"%s\")" % _ui._amount_edit.text)
    _check(not _ui._permanent_check.button_pressed,
        "a fresh order must have the \"Permanent\" flag off")
    close_button = _ui._trade_panel.find_child("CancelDealButton", true, false)
    _check(close_button != null and not close_button.visible,
        "a fresh order without a delivery must not offer deal cancellation")

    # A row without a contract stays a fresh order.
    var planks_row := _row_by_key(_ui.sell_list, "sell:%s" % PLANKS)
    _check(planks_row != null, "the town must have a row for the second good")
    if planks_row != null:
        _click(planks_row)
        await process_frame
        _check(_ui._selected_contract.is_empty(),
            "a row without a contract must be a fresh order")
        var deal_cancel_button: Button = _ui._trade_panel.find_child("CancelDealButton", true, false)
        _check(deal_cancel_button != null and not deal_cancel_button.visible,
            "a row without a contract or delivery must not offer deal cancellation")

    _ui._map = null
    map.queue_free()

# The same resource can have a contract and a one-time delivery at once. The checkbox
# selects which of those deals the panel's cancellation button acts on.
func _test_deal_cancel(town: Dictionary) -> void:
    var map := ContractMap.new()
    get_root().add_child(map)
    map.contracts["town_test|%s" % WOOD] = {
        "id": "contract_cancel_test", "town_id": "town_test", "town_name": "Testville",
        "product_id": WOOD, "amount": 8, "unit_price": 6, "cost_per_tick": 48,
    }
    map.deliveries = [{
        "town_id": "town_test", "product_id": WOOD, "remaining": 12, "amount": 12,
    }]
    _ui._map = map
    _ui.contract_close_requested.connect(map.close_contract)
    _ui.delivery_cancel_requested.connect(map.cancel_town_delivery)

    _ui.open_town(town, true)
    await process_frame
    var wood_row := _row_by_key(_ui.sell_list, "sell:%s" % WOOD)
    _check(wood_row != null, "the town must have a row for both deal types")
    if wood_row == null:
        return
    _click(wood_row)
    await process_frame
    var button: Button = _ui._trade_panel.find_child("CancelDealButton", true, false)
    _check(button != null and button.visible,
        "the permanent mode must expose cancellation when a contract exists")
    if button == null:
        return

    _ui._permanent_check.button_pressed = false
    await process_frame
    _check(button.visible and button.tooltip_text == _ui.tr("Cancel the deal"),
        "the one-time mode must expose delivery cancellation")
    button.pressed.emit()
    _check(map.contracts.has("town_test|%s" % WOOD),
        "cancelling a one-time deal must leave the contract untouched")
    _check(map.deliveries.is_empty() and map.cancelled_deliveries.size() == 1,
        "the one-time mode must cancel the selected town delivery")

    _ui._permanent_check.button_pressed = true
    await process_frame
    _check(button.visible and button.tooltip_text == _ui.tr("Close the contract"),
        "the permanent mode must select contract cancellation")
    button.pressed.emit()
    _check(not map.contracts.has("town_test|%s" % WOOD),
        "the permanent mode must cancel the contract")
    _check(map.cancelled_deliveries.size() == 1,
        "cancelling a contract must not cancel a one-time deal")

    _ui._map = null
    map.queue_free()

# -------------------------------------------------------
# 12. The panel follows the contract of the good it shows
# -------------------------------------------------------

# An order that BECOMES a standing contract turns the panel into an EDIT of it at once: the
# manager announces the change (contracts_changed) and the window re-reads the contract of
# the selected good (town_ui.on_contracts_changed). Without this the close button appeared
# only after the panel had been closed and reopened — the bug this case guards.
func _test_contract_sync(town: Dictionary) -> void:
    var map := ContractMap.new()
    get_root().add_child(map)
    _ui._map = map

    _ui.open_town(town, true)
    await process_frame
    var wood_row := _row_by_key(_ui.sell_list, "sell:%s" % WOOD)
    _check(wood_row != null, "the town must have a row for the good")
    if wood_row == null:
        return
    _click(wood_row)
    await process_frame
    # A fresh order: there is no contract yet, so there is nothing to close.
    _check(_ui._selected_contract.is_empty(), "the row must start as a fresh order")
    _check(_ui._trade_panel != null and is_instance_valid(_ui._trade_panel),
        "a click on the row must open the trade panel")
    if _ui._trade_panel == null:
        return
    var cancel_button: Button = _ui._trade_panel.find_child("CancelDealButton", true, false)
    _check(cancel_button != null and not cancel_button.visible,
        "a fresh order without a delivery must not offer cancellation")

    # The player confirms with the "Permanent" flag on. The manager signs the contract and
    # announces it; the stub signs by hand and then the window is told, exactly as the map
    # does (main_map wires town_trade_manager.contracts_changed to town_ui.on_contracts_changed).
    _ui._permanent_check.button_pressed = true
    _ui._set_amount(35)
    await process_frame
    map.contracts["town_test|%s" % WOOD] = {
        "id": "contract_9", "town_id": "town_test", "town_name": "Testville",
        "product_id": WOOD, "amount": 35, "unit_price": 6, "cost_per_tick": 210,
    }
    _ui.on_contracts_changed()
    await process_frame
    _check(not _ui._selected_contract.is_empty(),
        "the signed contract must turn the panel into an edit of it")
    _check(_ui._trade_panel != null and is_instance_valid(_ui._trade_panel),
        "the panel must stay open over the signed contract")
    if _ui._trade_panel == null:
        return
    _check(_ui._amount_edit.text == "35",
        "the panel must show the amount of the new contract (got \"%s\")" % _ui._amount_edit.text)
    _check(_ui._permanent_check.button_pressed,
        "the panel of the new contract must have the \"Permanent\" flag on")
    cancel_button = _ui._trade_panel.find_child("CancelDealButton", true, false)
    _check(cancel_button != null and cancel_button.visible,
        "the panel of the new contract must offer cancellation WITHOUT a reopening")
    _check(_ui._total_label.text == "Cost: %d/sec" % (35 * 6),
        "the total must be counted at the frozen price of the new contract (got \"%s\")"
            % _ui._total_label.text)

    # A contract that has gone (torn by the tick) turns the panel back into a fresh order.
    map.contracts.erase("town_test|%s" % WOOD)
    _ui.on_contracts_changed()
    await process_frame
    _check(_ui._selected_contract.is_empty(),
        "a contract that has gone must turn the panel back into a fresh order")
    cancel_button = _ui._trade_panel.find_child("CancelDealButton", true, false)
    _check(_ui._trade_panel != null and is_instance_valid(_ui._trade_panel)
            and cancel_button != null and not cancel_button.visible,
        "a fresh order without a delivery must not offer cancellation")
    _check(not _ui._permanent_check.button_pressed,
        "a fresh order must have the \"Permanent\" flag off")

    # A change that does not touch the selected good leaves the panel alone: the amount the
    # player is typing must survive it.
    _ui._set_amount(77)
    await process_frame
    map.contracts["town_test|%s" % PLANKS] = {
        "id": "contract_10", "town_id": "town_test", "town_name": "Testville",
        "product_id": PLANKS, "amount": 5, "unit_price": 3, "cost_per_tick": 15,
    }
    _ui.on_contracts_changed()
    await process_frame
    _check(_ui._amount_edit.text == "77",
        "an unrelated change must not reset the amount being typed (got \"%s\")"
            % _ui._amount_edit.text)
    _check(_ui._selected_contract.is_empty(),
        "an unrelated change must not put the panel into the edit mode")

    _ui._map = null
    map.queue_free()

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

# The row of a column by its key ("sell:wood") — null when the column has no such row.
func _row_by_key(container: Node, key: String) -> Control:
    for child in container.get_children():
        if child.has_meta("town_resource_row") \
                and str(child.get_meta("town_row_key", "")) == key:
            return child
    return null

# The control that OWNS the tooltip of `control`. The long hints of the window go
# through the wrapping tooltip, which keeps the text on a carrier laid over the control
# (see wrapped_tooltip.gd): it is the carrier the engine picks as the owner, so it is
# the carrier that carries the text. null — the control has no tooltip of its own.
func _tip_carrier(control: Control):
    return WRAPPED_TOOLTIP.find_carrier(control)

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

# The price label of a row: the named label inside the content of the row (the row is a
# PanelContainer, so the label lives in its inner box).
func _find_price_label(row: Control) -> Label:
    return row.find_child("PriceLabel", true, false) as Label

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
