# town_ui.gd
# The town (small settlement) interface — the trade window.
# It is opened from the control panel (the action button on a town hex)
# or by a double click on the town hex on the map (see InputHandler).
#
# The window is centered in the viewport in code (see _center_window): the town
# interface is a child of the map (a Node2D), and a Control under a non-Control
# anchors against a zero-sized rect, so anchor-based centering would place the panel
# at minus half its size — off-screen. The panel is therefore positioned from the
# viewport size, and re-centered when the viewport changes.
#
# Two columns "Buying" and "Selling". The lists are inside ScrollContainers
# (BuyScroll/SellScroll): the sell pool of a town is dozens of rows, and without
# scrolling they spilled past the bottom edge of the window right onto the map.
# A vertical rule separates the two pools (see _build_pool_separator).
#
# The vertical scrollbar of both columns is reserved permanently (vertical_scroll_mode =
# SHOW_ALWAYS in the scene), so the width of the rows never depends on whether the list
# overflows: with SCROLL_MODE_AUTO the ScrollContainer hands its content the width MINUS the
# bar, and a column that starts to overflow — a pool of dozens of goods, or the trade panel
# opening under a row — narrows every row by the width of the bar and the price column jumps
# to the left. An idle bar is hidden (see _wire_scroll_gutter), so a short list does not carry
# a bright rail of a grabber that fills the whole track.
#
# Both columns are grouped by the resource category, exactly like the "Resources"
# tab of the city (see _fill_resource_list): a header of a solid line, the category
# name centred in its column, then a line again; the rows of that category follow.
#
# The purchase column may carry a GROUP instead of a single good ("Fruits", "Alcohol"):
# the town buys any member of it (see town_economy.build_pools). A group row is named
# after the group and underlined with the standard dashed line of a group reference; on
# hover it shows the standard group tooltip with the members. The concrete member is
# chosen at the settlement, from what the city has in stock (town_trade_manager), so the
# row carries the group price — the average price of its members (town_economy.get_group_price).
#
# A row of the purchase column is tradable only while the city actually holds the goods: the
# town buys what the city can deliver, so a good the warehouse cannot give up is listed as
# information and not as an offer (see _row_tradable). A group row is satisfied by any ONE of
# its members, because that is what the settlement will pick. The rule is re-applied while the
# window is open, so a row comes alive the moment the goods appear in the warehouse.
#
# A row is INTERACTIVE: it highlights on hover and, on a click, opens the trade
# settings of the resource right under itself (see _open_trade_panel). The highlight
# is a stylebox on the row's PanelContainer — a transparent normal, a light hover and
# a stronger "selected" state — so the row reacts like a button without turning every
# label of the row into a button. The interaction is only wired when the trade with the
# town is available at all: without a road the rows are pure information (see
# _can_trade). A row that is not tradable right now — no road, or nothing of the goods in
# the warehouse of the city — is dimmed and refuses the cursor and the click
# (see _set_row_active).
#
# Every row of the sale column carries the stock of the town and its quality: the
# stars of the level in its own colour (data/qualities.json). A town never holds
# mixed quality, so there is nothing to break down and nothing to show in
# percentages — the stars ARE the quality of the row (see town_economy).
#
# Every row, of either column, carries the price of ONE unit of the goods (in coins),
# to the right of the name — see _unit_price.
#
# The trade settings panel identifies an existing deal for the selected good: a standing
# contract in permanent mode or a one-time delivery in transit. The line stays hidden when
# there is no active deal of the selected type.
#
# The trade settings panel is the FOUNDATION of the trade: it assembles the
# order (the goods, the amount, the "permanent" flag) and hands it over by the
# signal trade_order_submitted. The mechanics that spend the treasury and move the
# goods live behind that signal (main_map._on_town_trade_order ->
# town_trade_manager), and their answer is reported by the HUD, which stays visible
# while the window is open (see hud_message.gd).
#
# The panel EDITS an existing contract instead of signing a second one. A town carries
# one contract per good (see town_trade_manager), so the row of a good that already has
# a contract opens the settings of THAT contract: the amount is prefilled with it, the
# total is counted at the price frozen at its signing (a new price is a new deal), and a
# "close the contract" button appears next to confirm/cancel. The window reads the
# contract of the selected row from the map (main_map.get_town_contract); a row without
# one is an ordinary fresh order.
extends Control

# The shared UI helpers: the category header of a resource list (a line, the name, a
# line) is built there, so the town window and the "Resources" tab of the city cannot
# drift apart. Only the static members are used — no instance is needed.
const UiHelpers = preload("res://scripts/ui_helpers.gd")
const UI_THEME = preload("res://scripts/ui_theme.gd")

# The red "!" triangle of the route-capacity warning. It is drawn by its own Control
# (see the script), so the window does not need an icon asset for it.
const WarningBadge = preload("res://scripts/warning_badge.gd")

signal closed()

# The foundation of the town trade: the window has assembled a buy/sell order and
# hands it to the map. The order carries the unit price the panel showed (the same
# number the total of the order is made of), so that the charge of the treasury and
# the sum the player saw cannot diverge. The mechanics behind the signal live in
# main_map._on_town_trade_order -> town_trade_manager.submit_order.
signal trade_order_submitted(order: Dictionary)

# The window asked to close the standing contract it is editing. Like the order, the
# window only asks: the mechanics live in town_trade_manager and the answer is reported
# by the HUD (see main_map._on_town_contract_close_requested). The good becomes free for
# a new deal — with the same terms or with different ones.
signal contract_close_requested(contract_id: String)

signal delivery_cancel_requested(town_id: String, product_id: String)

# The two sides of the trade. The value is part of the order and of the row key, so
# it must stay stable.
const SIDE_BUY := "buy"
const SIDE_SELL := "sell"

# The minimum height of a list row. It equals the icon height (28 px): a label with
# a line wrap should not squeeze the icon and the next row.
const ROW_HEIGHT := 28

# The amount step of the "+"/"−" buttons: units by default, tens with Ctrl held,
# hundreds with Shift held. The values are shown in the button tooltips.
const STEP_UNITS := 1
const STEP_TENS := 10
const STEP_HUNDREDS := 100

# The amount a freshly opened trade panel starts with. It is independent of the
# button step: the panel opens on a round number even though a plain click moves
# the amount by one unit.
const DEFAULT_AMOUNT := 10

# The digit cap of the amount field: a number longer than the town warehouse is
# meaningless, and the cap keeps a paste of a whole paragraph out of the field.
const MAX_AMOUNT_LENGTH := 7

# The background of a row in its three states. The normal one is fully transparent:
# a column of dozens of rows must not look like a wall of boxes, the background
# appears only on hover and on the selected row. The two painted states are the row
# tokens of the palette, because a row fill is judged against the plate the list stands on.
static func row_normal_color() -> Color:
    return Color.TRANSPARENT

static func row_hover_color() -> Color:
    return UI_THEME.color("row_hover")

static func row_selected_color() -> Color:
    return UI_THEME.color("row_selected")

# The width of the price column of a row. Fixed, so that the prices of the rows line up
# in one column instead of every row placing its number by the length of its own name.
const PRICE_COLUMN_WIDTH := 44

# The colours of the money. The price of one unit is the same gold the "Trade" tab
# already paints its prices with (UiHelpers.price_text_color()). The total of an order is
# red when the city PAYS and gold when the city IS PAID — the same pair the deal rows of
# the "Foreign trade" column use (external_trade_tab.color_expense / color_income), so a
# purchase and a sale are read the same way in both windows.
static func color_expense() -> Color:
    return UI_THEME.color("expense")

static func color_income() -> Color:
    return UI_THEME.color("warning")

# The markers that let the layout be read back: a row of a trade column and the key
# of the resource behind it (the tests and the trade panel both use them), and whether
# the row can be traded from at all (see _set_row_active).
const META_RESOURCE_ROW := "town_resource_row"
const META_ROW_KEY := "town_row_key"
const META_ROW_NAME := "town_row_name"
const META_ROW_ACTIVE := "town_row_active"
# Marks a scrollbar whose gutter is already wired to the metrics of its list (see
# _wire_scroll_gutter). The bar is an internal child of the ScrollContainer and outlives a
# rebuild of the list, so the signal must not be connected twice.
const META_GUTTER_WIRED := "town_gutter_wired"
@onready var window_panel = $WindowPanel
@onready var title_label = $WindowPanel/TitleLabel
@onready var status_label = $WindowPanel/StatusLabel
@onready var treasury_label = $WindowPanel/TreasuryLabel
@onready var close_button = $WindowPanel/CloseButton
@onready var columns_hbox = $WindowPanel/ColumnsHBox
@onready var buy_scroll = $WindowPanel/ColumnsHBox/BuyColumn/BuyScroll
@onready var sell_scroll = $WindowPanel/ColumnsHBox/SellColumn/SellScroll
@onready var buy_list = $WindowPanel/ColumnsHBox/BuyColumn/BuyScroll/BuyList
@onready var sell_list = $WindowPanel/ColumnsHBox/SellColumn/SellScroll/SellList

# The current town (an entry from town_manager.towns). null — the window is closed.
var _town = null
# Whether trade with this town is available (town_manager.is_trade_available — there is
# a road from the city to it). The window opens either way: without a road the player
# still sees what the town has for sale and what it wants to buy, and the status row
# under the name says why there is no trade. What the flag DOES gate is the trade
# settings: with no road the rows are inert (dimmed, not wired) and no trade panel can
# be opened — see _can_trade, _build_resource_row, _toggle_selection.
var _trade_available := true
# Whether the window is open on a town at all. main_map checks it before asking
# for a refresh of the quantities on every town tick.
var has_town: bool = false

# The rows of the sale column that are currently on the screen, by the product id:
# display name -> the label of the quantity. They are refreshed in place on every
# town tick, because rebuilding the whole column would reset its scrolling.
var _sell_quantity_labels: Dictionary = {}
# As above, but for the quality of the row: display name -> the Label with the
# stars. The stars of a town never change while the row is on the screen (unlike
# the city, a town holds exactly one quality of a product, see town_economy), but
# the refresh goes through the same place so that the two labels of a row cannot
# drift apart.
var _sell_quality_labels: Dictionary = {}
# The price labels of the rows that are currently on the screen, by the row key:
#   row_key -> { "label": RichTextLabel, "id": String, "side": String }
# Both columns have prices, so the map is NOT cleared per column — it is cleared once
# per rebuild, in _refresh (unlike the two maps above, which only the sale column uses).
# The market price of a product moves with the dynamic multipliers, and the number is
# refreshed in place on every town tick together with the stock (see refresh_storage).
var _price_labels: Dictionary = {}

# The map (MainMap), set by main_map.set_map. The window asks it for the route to the
# city to know the throughput the route can carry (see _route_capacity). null in a
# test that opens the window on its own — the capacity is then taken as zero.
var _map = null

# The tooltip instance of the window, used only when the map cannot lend its own (see
# _get_ui_helpers): the group tooltip of the purchase column must be the standard one,
# and the map already owns a standard instance for its HUD.
var _own_ui_helpers: Node = null

# The rows that are currently on the screen, by the row key ("buy:grain"). The trade
# panel is inserted right after its row, and the highlight is applied through these
# references, so a rebuild only has to refresh the map.
var _row_nodes: Dictionary = {}
# The rows of the purchase column, by the row key: row key -> { "row": Control, "id": String }.
# Their tradability depends on the warehouse of the city, which moves while the window is open,
# so they are kept apart to be re-read without rebuilding the column (see _refresh_row_gates).
var _buy_rows: Dictionary = {}
# The quantity labels of the purchase rows, by the row key: row key -> { "label": Label, "id": String }.
# Shown only when the city warehouse actually holds the goods (never "0 units").
var _buy_quantity_labels: Dictionary = {}
# The quality markers of the purchase rows, by the row key: row key -> { "label": Label, "id": String }.
# A blue star marker; visible only when the city warehouse has a quality breakdown for the goods.
var _buy_quality_labels: Dictionary = {}
# The active quality tooltip of a purchase row (product id, display name) — for the real-time
# update while the cursor stays on the star (the same pattern as the "Resources" tab of the city).
var _active_buy_quality_product: String = ""
var _active_buy_quality_name: String = ""
# The epoch of the last update of the purchase column numbers (quantity / quality of the
# goods on the city warehouse). They are updated with the resource display interval from
# the settings (CityData.resource_display_interval), and not on every town tick: the data
# comes from the city warehouse (CityData.city_storage), which moves on the city tick,
# not on the town tick (see refresh_storage).
var _buy_display_epoch: int = 0
# The vertical rule between the two pools (see _build_pool_separator). null before _ready.
var _pool_separator: ColorRect = null
# The row the cursor is over. Only one row is hovered at a time; the field is needed
# because the signals of a row and of its labels (the quality stars) arrive as
# separate enter/exit pairs and must not fight over the same row.
var _hovered_row: Control = null

# The resource whose trade settings are open: the row key, the side, the product id
# and its display name. An empty key means no panel is open.
var _selected_key := ""
var _selected_side := ""
var _selected_id := ""
var _selected_name := ""
# The standing contract the open panel is EDITING, or an empty dictionary when the panel
# is a fresh order. A town carries one contract per good (see town_trade_manager), so the
# settings of a good that already has a contract open as an edit of it: the amount is
# prefilled with the contract and the total is counted at the price frozen at its signing.
var _selected_contract: Dictionary = {}
var _selected_delivery: Dictionary = {}

# The trade settings panel and its controls (null while it is closed).
var _trade_panel: Control = null
var _amount_edit: LineEdit = null
var _permanent_check: CheckBox = null
var _warning_badge: Control = null
var _confirm_button: Button = null
var _total_label: RichTextLabel = null
var _cancel_deal_button: Button = null
# The line that names the active contract or delivery for the selected good.
var _deal_status_label: Label = null

# Guards the text_changed handler from re-entering when the field is sanitized
# programmatically (a programmatic assignment does not emit the signal, but the
# guard keeps the handler safe to call from a test as well).
var _suppress_edit := false

# The last state of the "Permanent" checkbox of the open panel. It is restored when
# the panel is rebuilt on a refresh (the town tick or an era change), so the player
# does not lose the flag while the window stays open. A new resource selection resets
# it to false.
var _panel_permanent := false

# The last order the window assembled. It is kept for the tests and as the handover
# point to the future trade mechanics.
var _last_order: Dictionary = {}


func _ready():
    if close_button:
        close_button.pressed.connect(close_town)
    _build_pool_separator()
    _wire_scroll_gutter(buy_scroll)
    _wire_scroll_gutter(sell_scroll)
    _center_window()
    if not CityData.city_updated.is_connected(_on_buy_city_updated):
        CityData.city_updated.connect(_on_buy_city_updated)
    var viewport := get_viewport()
    if viewport != null:
        if not viewport.size_changed.is_connected(_center_window):
            viewport.size_changed.connect(_center_window)
        # The rule between the pools is a hairline of the SCREEN, so its width has to be
        # recomputed when the stretch of the canvas changes (see UiHelpers.hairline_thickness).
        if not viewport.size_changed.is_connected(_layout_pool_separator):
            viewport.size_changed.connect(_layout_pool_separator)
    # The rows, the trade panel and the rule between the pools carry their colours as
    # per-node overrides, and an override wins over the project theme: a new palette has to
    # be pushed through the window by hand.
    ThemeManager.theme_applied.connect(_on_theme_applied)

# Repaints the window from the palette that is current now. The rows are rebuilt rather than
# touched in place, which is also what a change of the town does.
func _on_theme_applied() -> void:
    if _pool_separator != null and is_instance_valid(_pool_separator):
        _pool_separator.color = UiHelpers.category_header_line_color()
    _refresh()

# The vertical rule between the two pools. It is built here and not declared in the scene:
# its width is a hairline of the screen and follows the stretch of the canvas, which only the
# running window knows. The colour is the one of the category lines, so the rule and the
# headers of the columns cannot drift apart.
func _build_pool_separator() -> void:
    if columns_hbox == null or _pool_separator != null:
        return
    _pool_separator = ColorRect.new()
    _pool_separator.name = "PoolSeparator"
    _pool_separator.color = UiHelpers.category_header_line_color()
    _pool_separator.size_flags_vertical = Control.SIZE_FILL
    _pool_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
    columns_hbox.add_child(_pool_separator)
    columns_hbox.move_child(_pool_separator, 1)
    _layout_pool_separator()

func _layout_pool_separator() -> void:
    if _pool_separator == null or not is_instance_valid(_pool_separator):
        return
    _pool_separator.custom_minimum_size = Vector2(UiHelpers.hairline_thickness(true), 0)

# The gutter of a column's scrollbar is reserved permanently (see the header). A bar that has
# nothing to scroll, however, paints its grabber over the whole track — a bright rail next to a
# short list. It is therefore made invisible and transparent to the mouse while the content fits,
# which costs no layout: the space is taken by the BAR being laid out, not by it being drawn.
# The state follows the metrics of the bar, so a list that grows (a pool of dozens of goods, the
# trade panel opening under a row) brings the bar back on its own.
func _wire_scroll_gutter(scroll: ScrollContainer) -> void:
    if scroll == null:
        return
    var bar := scroll.get_v_scroll_bar()
    if bar == null or bar.has_meta(META_GUTTER_WIRED):
        return
    bar.set_meta(META_GUTTER_WIRED, true)
    bar.changed.connect(_on_scroll_metrics_changed.bind(bar))
    _on_scroll_metrics_changed(bar)

func _on_scroll_metrics_changed(bar: VScrollBar) -> void:
    if bar == null or not is_instance_valid(bar):
        return
    var idle := bar.max_value <= bar.page
    bar.modulate.a = 0.0 if idle else 1.0
    bar.mouse_filter = Control.MOUSE_FILTER_IGNORE if idle else Control.MOUSE_FILTER_STOP

# Centers the window panel in the viewport. The interface of a town lives on the map
# (MainMap is a Node2D), and a Control under a non-Control is anchored to a zero-sized
# rect — the usual anchors cannot center it. The panel is therefore placed from the
# viewport size; the position is clamped to zero so that on a viewport smaller than
# the window at least its top-left corner stays reachable.
func _center_window() -> void:
    if window_panel == null:
        return
    var viewport_size: Vector2 = get_viewport_rect().size
    var panel_size: Vector2 = window_panel.size
    var centered: Vector2 = ((viewport_size - panel_size) * 0.5).floor()
    window_panel.position = Vector2(maxf(centered.x, 0.0), maxf(centered.y, 0.0))

# The reference to the map: the window reads the route to the city from it to compare
# the entered amount with the throughput of the route.
func set_map(map_node) -> void:
    _map = map_node

# Opens the interface window for a town.
# town — a town entry from town_manager.towns (the row, col, name, ... fields).
# trade_available — whether trade with it is available (true by default: the window
# always opens, see the _trade_available field).
func open_town(town: Dictionary, trade_available: bool = true):
    _town = town
    _trade_available = trade_available
    has_town = true
    # A new town starts with no resource selected: the panel of the previous town must
    # not stay open over the rows of another town.
    _clear_selection()
    _refresh()
    _center_window()
    show()

# Updates the window contents for the current town.
func _refresh():
    if _town == null:
        return
    # The rows are rebuilt from scratch: a group tooltip of a row that is about to be
    # freed must not stay over the fresh list.
    _hide_group_tooltip()
    title_label.text = str(_town.get("name", tr("Town")))
    _update_treasury_label()
    if status_label:
        # The trade status — for now only a label. An empty row when trade is
        # available: "everything is fine, there is nothing to report".
        status_label.text = "" if _trade_available \
                else tr("Trade unavailable: there is no road from the city to this town")
        status_label.visible = not status_label.text.is_empty()
    _row_nodes.clear()
    _buy_rows.clear()
    _price_labels.clear()
    _fill_resource_list(buy_list, _town.get("buy_pool", []), tr("The town buys nothing"),
            SIDE_BUY, false)
    _fill_resource_list(sell_list, _town.get("sell_pool", []),
            tr("No resources in the influence ring"), SIDE_SELL, true)
    # The lists were rebuilt from scratch, so the open trade panel (if any) and the
    # highlight of its row have to be put back on top of the fresh rows. The contract of
    # the selected row is re-read first: the panel of a good that carries one must come
    # back as an EDIT of it and not as a fresh order.
    #
    # A selection that can no longer be traded from — the goods left the warehouse of the
    # city while the column was being rebuilt — is dropped together with its panel: there is
    # nothing to trade, so there is nothing to show (see _row_tradable).
    if not _selected_key.is_empty() and not _row_tradable(_selected_side, _selected_id):
        _clear_selection()
    if not _selected_key.is_empty():
        var keep_amount := _current_amount()
        _sync_selected_contract()
        _open_trade_panel(keep_amount)
        _refresh_row_styles()

# Refreshes ONLY the live numbers of the rows — the stock and the stars of the sale
# column and the price of every row of both columns — without touching the rows
# themselves. It is called on every town tick while the window is open: the warehouse of
# the town grows several times a second and the market price moves with the dynamic
# multipliers, and a full rebuild would throw away the scroll position of the list and
# the highlight of the cursor.
# Handles the city tick (CityData.city_updated). The purchase column numbers — quantity
# and quality of the goods on the city warehouse — are updated with the resource display
# interval from the settings (CityData.resource_display_interval), and not on every city
# tick: the city warehouse moves on the city tick, and the UI must follow the configured
# interval, exactly like the "Resources" tab of the city.
func _on_buy_city_updated() -> void:
    if _town == null or not visible:
        return
    if CityData.resource_display_due(_buy_display_epoch):
        _buy_display_epoch = CityData.resource_display_epoch
        refresh_buy_stock_labels()

# Refreshes ONLY the quantity and quality markers of the purchase rows — the stock
# of the city warehouse for each buy row. It is called with the resource display
# interval from the settings (CityData.resource_display_interval): the data comes
# from the city warehouse, which moves on the city tick, not on the town tick, so
# the update must follow the city interval, not the town tick (see refresh_storage).
func refresh_buy_stock_labels() -> void:
    if _town == null or not visible:
        return
    for key in _buy_quantity_labels:
        var entry: Dictionary = _buy_quantity_labels[key]
        var label: Label = entry.get("label", null)
        if label is Label and is_instance_valid(label):
            _apply_buy_row_quantity(label, str(entry.get("id", "")))
    for key in _buy_quality_labels:
        var entry: Dictionary = _buy_quality_labels[key]
        var label: Label = entry.get("label", null)
        if label is Label and is_instance_valid(label):
            _apply_buy_row_quality(label, str(entry.get("id", "")))
    # Live refresh of the open quality tooltip of a purchase row, exactly like the
    # "Resources" tab of the city does: while the cursor stays on the star the tooltip
    # shows the actual storage, not the snapshot from the moment the cursor entered.
    var helpers := _get_ui_helpers()
    if _active_buy_quality_product != "" and helpers != null and is_instance_valid(helpers):
        if helpers.quality_tooltip_panel.visible:
            var fresh_detail = CityData.get_quality_breakdown(_active_buy_quality_product)
            if fresh_detail.is_empty():
                helpers.hide_quality_tooltip()
                _active_buy_quality_product = ""
                _active_buy_quality_name = ""
            else:
                helpers.show_quality_tooltip(get_viewport().get_mouse_position(),
                        _active_buy_quality_name, fresh_detail)

func refresh_storage():
    if _town == null or not visible:
        return
    # The warehouse of the CITY moves as well: it is what the purchase column trades from, so
    # the rows that became tradable (or stopped being so) are re-read here, without a rebuild.
    _refresh_row_gates()
    for display_name in _sell_quantity_labels:
        var label: Label = _sell_quantity_labels[display_name]
        if is_instance_valid(label):
            label.text = _format_stock(_stock_of(display_name))
    for display_name in _sell_quality_labels:
        var quality_label: Label = _sell_quality_labels[display_name]
        if is_instance_valid(quality_label):
            _apply_row_quality(quality_label, str(display_name))
    if not _selected_id.is_empty():
        _sync_selected_delivery()
        _update_deal_status_label()
        _update_cancel_deal_button()
    for key in _price_labels:
        var entry: Dictionary = _price_labels[key]
        var price_label = entry.get("label", null)
        if price_label is RichTextLabel and is_instance_valid(price_label):
            _apply_row_price(price_label, str(entry.get("id", "")), str(entry.get("side", "")))
    _update_treasury_label()
    # The total of an open order is the amount times the price of a unit, so it has to
    # follow the price as well — otherwise the sum would go stale under the player.
    if _trade_panel != null and is_instance_valid(_trade_panel):
        # The tick moved the warehouse: a town that sold goods of its own (or backed a
        # standing contract) may have dropped below the number sitting in the field. The
        # amount is clamped here as well, so an order assembled after the tick cannot ask
        # for more than the town has, no matter how long the panel has been open.
        _commit_amount_clamp()
        _update_total_label(_current_amount())

# The units of a good that the town has on the stock. The rows are keyed by the
# display name (two different ids are sometimes called the same, see
# _fill_resource_list), therefore the whole warehouse is summed for the name: the
# player sees one row "Papyrus" and one number, and the number is all he has.
func _stock_of(display_name: String) -> int:
    var total := 0
    var storage: Dictionary = _town.get("storage", {})
    for pid in storage:
        if _get_resource_display_name(str(pid)) == display_name:
            total += int(storage[pid])
    return total

# The quality id of the product behind a row. A town holds one quality of a product,
# and the row is keyed by the display name, so the first id behind the name wins —
# exactly the same rule as _stock_of uses to sum the quantities.
func _quality_of(display_name: String) -> String:
    var storage: Dictionary = _town.get("storage", {})
    for pid in storage:
        if _get_resource_display_name(str(pid)) == display_name:
            return TownManager.get_town_goods_quality(_town, str(pid))
    return TownEconomy.DEFAULT_QUALITY

# Whether the trade with the current town is available at all: there must be a road
# from the city to it (town_manager.is_trade_available). The WINDOW opens either way —
# without a road the player still sees what the town has for sale and what it wants to
# buy — but the trade SETTINGS do not: the rows are inert and no panel opens
# (see _build_resource_row and _toggle_selection).
func _can_trade() -> bool:
    return _trade_available

# The price of ONE unit of a row, in whole coins: the current market price of the
# product (GameData.get_price — the base price with the dynamic market multipliers, the
# same number the "Trade" tab of the city works with), multiplied by the quality
# multiplier of the level the row shows.
#
# side — the column, and it decides whether there is a quality at all. The SALE column
# holds the goods the town itself has, and the stars of the row name their level, so the
# price carries the multiplier of exactly that level: the price and the stars of a row
# cannot tell different stories. The PURCHASE column is about the goods the town LACKS —
# the quality of what the city will deliver is not known at the row (and the row has no
# stars), so the plain market price is shown there.
#
# A GROUP row has no single product and no quality: it is priced as the average of its
# members (TownEconomy.get_group_price), which is the one number a group can carry.
func _unit_price(resource_id: String, side: String) -> int:
    if _is_group_id(resource_id):
        return TownEconomy.get_group_price(resource_id)
    var quality_id := _town_quality_of(resource_id) if side == SIDE_SELL else ""
    return int(round(GameData.get_price_for_quality(resource_id, quality_id)))

# The price of ONE unit the open panel works with. While the panel edits an existing
# contract, the price is the one frozen at the signing of that deal: an edit changes the
# amount only, and a different price is a different deal — the player closes the contract
# and signs a new one (see town_trade_manager). A fresh order uses the price of the row.
func _selected_unit_price() -> int:
    if not _selected_contract.is_empty():
        return int(_selected_contract.get("unit_price", 0))
    return _unit_price(_selected_id, _selected_side)

# The quality level the town holds of a product, or "" when it does not hold it at all.
# An empty id is a meaningful answer for _unit_price: the multiplier of an unknown level
# is 1.0 (see GameData.get_quality_price_multiplier), which is exactly the plain market
# price of a row of the purchase column.
func _town_quality_of(resource_id: String) -> String:
    if _town == null:
        return ""
    var quality: Dictionary = _town.get("quality", {})
    var quality_id := str(quality.get(resource_id, ""))
    if quality_id.is_empty() or quality_id == "<null>":
        return ""
    return quality_id

# Paints the stars of a row in the colour of their level and writes the text.
# The stars are the WHOLE story of the quality of a town row: there is no breakdown
# and no percentages, because a town never holds mixed quality (see town_economy).
# The colour comes from data/qualities.json, the same palette the city uses.
#
# The stars carry a small tooltip with the name of the level: a row of a town has no
# room for the word next to the number, and a player who does not know the palette
# by heart can read what the colour means without leaving the window.
func _apply_row_quality(quality_label: Label, display_name: String) -> void:
    var quality_id := _quality_of(display_name)
    quality_label.text = GameData.get_quality_stars(quality_id)
    quality_label.add_theme_color_override("font_color",
            GameData.get_quality_color(quality_id))
    quality_label.tooltip_text = tr("Quality: %s") % GameData.get_quality_name(quality_id)

# Writes the price of one unit into the label of a row, together with its tooltip. The
# bare number does not say what it is, and a row has no room for the words "price per
# unit" next to it — so the words live in the tooltip, and the coin icon marks the
# number itself.
func _apply_row_price(price_label: RichTextLabel, resource_id: String, side: String) -> void:
    var price := _unit_price(resource_id, side)
    price_label.text = UiHelpers.money(str(price))
    price_label.tooltip_text = tr("Price per unit: %d coins") % price

func _format_stock(amount: int) -> String:
    return tr("%d units") % amount

# Paints the quality marker of a purchase row: a blue star (the same marker the
# "Resources" tab uses to say "this good has a quality breakdown"). Visible only
# when the city warehouse holds a quality breakdown for the goods — if nothing is
# on the warehouse, there is nothing to break down and the star stays hidden.
# Hovering the star opens the breakdown tooltip (see _on_buy_quality_hover).
func _apply_buy_row_quality(quality_label: Label, resource_id: String) -> void:
    var breakdown = CityData.get_quality_breakdown(resource_id)
    if breakdown.is_empty():
        quality_label.visible = false
        return
    quality_label.visible = true
    quality_label.text = "★"
    quality_label.add_theme_color_override("font_color", UiHelpers.quality_marker_color())

# Writes the quantity of the goods on the city warehouse into the label of a
# purchase row. Only goods that are actually on the warehouse are shown — the
# label stays hidden (never "0 units") for goods the city does not hold. The decorated
# variants of a good count: they are what the town will accept in its place.
func _apply_buy_row_quantity(quantity_label: Label, resource_id: String) -> void:
    var amount := GameData.get_good_stock(resource_id, CityData.city_storage)
    if amount > 0:
        quantity_label.text = _format_stock(amount)
        quantity_label.visible = true
    else:
        quantity_label.visible = false

# Opens the quality breakdown tooltip over the quality star of a purchase row,
# exactly like the "Resources" tab of the city does.
func _on_buy_quality_hover(resource_id: String) -> void:
    var helpers := _get_ui_helpers()
    if helpers == null:
        return
    var breakdown = CityData.get_quality_breakdown(resource_id)
    if breakdown.is_empty():
        return
    _active_buy_quality_product = resource_id
    _active_buy_quality_name = _get_resource_display_name(resource_id)
    helpers.show_quality_tooltip(get_viewport().get_mouse_position(),
            _active_buy_quality_name, breakdown)

# Hides the quality breakdown tooltip when the cursor leaves the star.
func _on_buy_quality_exit() -> void:
    _active_buy_quality_product = ""
    _active_buy_quality_name = ""
    var helpers := _get_ui_helpers()
    if helpers != null:
        helpers.hide_quality_tooltip()

func _update_treasury_label() -> void:
    if treasury_label == null or _town == null:
        return
    treasury_label.text = tr("Treasury: %s") % UiHelpers.money(str(int(_town.get("treasury", 0))))

# Connected to TownManager.town_treasury_changed. Only the treasury label is
# updated: rebuilding the resource lists on every deal would reset their scrolling.
func on_town_treasury_changed(town_id: String, _treasury: int) -> void:
    if _town == null or not visible:
        return
    if str(_town.get("id", "")) != town_id:
        return
    _update_treasury_label()

# Connected to TownManager.town_storage_changed: the trade deals write the units
# off the warehouse and put them into it, and the sale column must show the result
# immediately instead of on the next tick.
func on_town_storage_changed(town_id: String) -> void:
    if _town == null or not visible:
        return
    if str(_town.get("id", "")) != town_id:
        return
    refresh_storage()

# Fills the column with one row per resource of the trade pool, grouped by category.
# The grouping mirrors the "Resources" tab of the city (resources_tab.gd): the header
# of a category is a solid line, the name centred in the column, then a line again,
# and the rows of that category follow. The order of the categories follows
# GameData.categories (data/categories.json); a category that is not in the reference
# is appended at the end under its raw id, so no row is lost.
#
# The sell pool contains resource ids, therefore the name is taken from the
# common reference.
#
# Rows with the same display name are shown only once. The main
# protection lives in the data: the pool is built from the PRODUCTION of resources
# (see TownEconomy.collect_base_resources), therefore "two wheats" due to a field and
# grain are already impossible there. But in the data there is exactly one pair where different ids
# are called the same: papyrus_plant (grown on papyrus_field) and
# papyrus (crafted from it) are both called "Papyrus" — and both can get into
# the pool of one town. Showing "Papyrus" to the player twice is not allowed.
#
# side — which column this is (SIDE_BUY/SIDE_SELL): it goes into the row key and into
# the order the trade panel assembles.
# with_stock — whether to append the units on the stock of the town to the row.
# It is only the sale column: the town buys the goods it lacks, and there is
# nothing of its own to count.
func _fill_resource_list(container: VBoxContainer, pool, empty_text: String,
        side: String, with_stock: bool = false) -> void:
    if container == null:
        return
    if with_stock:
        _sell_quantity_labels.clear()
        _sell_quality_labels.clear()
    else:
        _buy_quantity_labels.clear()
        _buy_quality_labels.clear()
    # The old rows are detached before the free so that the container holds exactly
    # the fresh rows already in the same frame (queue_free alone would keep the old
    # ones as children until the end of the frame).
    for child in container.get_children():
        container.remove_child(child)
        child.queue_free()
    if pool == null or pool.is_empty():
        var empty_label := Label.new()
        empty_label.text = empty_text
        empty_label.modulate = UI_THEME.color("text_muted")
        container.add_child(empty_label)
        return
    # One entry per display name, grouped by the category of the id behind it. The
    # first id behind a name wins (see the note above), and it also decides the
    # category the row lands in. A group row is deduplicated by its ID and not by its
    # name: two different groups can carry the same name ("Fruits" and the wine fruits
    # are both "Fruits"), and they are two different demands.
    var grouped: Dictionary = {}
    var shown_names: Dictionary = {}
    for resource_id in pool:
        if resource_id == null:
            continue
        var id := str(resource_id).strip_edges()
        if id.is_empty() or id == "<null>":
            continue
        var display_name := _get_resource_display_name(id)
        var dedupe_key := id if _is_group_id(id) else display_name
        if shown_names.has(dedupe_key):
            continue
        shown_names[dedupe_key] = true
        var category := _get_resource_category(id)
        if not grouped.has(category):
            grouped[category] = []
        grouped[category].append({"id": id, "name": display_name})
    for category_id in _ordered_categories(grouped):
        var items: Array = grouped[category_id]
        if items.is_empty():
            continue
        container.add_child(UiHelpers.build_category_header(_get_category_name(category_id)))
        for item in items:
            container.add_child(_build_resource_row(
                    item["id"], item["name"], side, with_stock))

# Builds one row of a trade column: the icon, the name, the price of one unit and —
# for the sale column — the quality stars and the units on the stock of the town.
#
# The row is a PanelContainer with a stylebox background that carries the three
# states of the row (normal, hover, selected). The children of the row ignore the
# mouse EXCEPT the quality stars and the price, which keep their own tooltips; the row
# and those two labels are wired to the same hover and click handlers, so the whole row
# reacts as one control and neither of them is a dead zone.
#
# Without a road the trade is unavailable: the row is still built (the player reads the
# pool), but it is dimmed and NOT wired at all — it is pure information, and no trade
# panel can be opened from it (see _can_trade, _toggle_selection).
func _build_resource_row(resource_id: String, display_name: String,
        side: String, with_stock: bool) -> PanelContainer:
    var row := PanelContainer.new()
    row.mouse_filter = Control.MOUSE_FILTER_STOP
    row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
    var row_key := "%s:%s" % [side, resource_id]
    row.set_meta(META_RESOURCE_ROW, true)
    row.set_meta(META_ROW_KEY, row_key)
    row.set_meta(META_ROW_NAME, display_name)
    row.add_theme_stylebox_override("panel", _make_row_style(row_normal_color()))

    var content := HBoxContainer.new()
    content.add_theme_constant_override("separation", 6)
    content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(content)

    var icon_name := _get_resource_icon_name(resource_id)
    var icon_tex := IconRegistry.get_texture(icon_name)
    if icon_tex != null:
        var resource_icon := TextureRect.new()
        resource_icon.texture = icon_tex
        resource_icon.custom_minimum_size = Vector2(28, 28)
        resource_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        resource_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        resource_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(resource_icon)

    var resource_label: Label = _make_name_label(resource_id, display_name)
    content.add_child(resource_label)

    # The price of ONE unit of the goods, right after the name: the number the player
    # compares the rows by. It keeps its own tooltip (the bare number does not say that
    # it is the price of a single unit) and is wired to the row, exactly like the
    # quality stars — otherwise it would be a dead zone in the middle of the row.
    var price_label := UiHelpers.make_money_label()
    price_label.name = "PriceLabel"
    price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    price_label.custom_minimum_size = Vector2(PRICE_COLUMN_WIDTH, 0)
    price_label.add_theme_color_override("default_color", UiHelpers.price_text_color())
    price_label.mouse_filter = Control.MOUSE_FILTER_STOP
    _apply_row_price(price_label, resource_id, side)
    content.add_child(price_label)
    _price_labels[row_key] = {"label": price_label, "id": resource_id, "side": side}

    var quality_label: Label = null
    if with_stock:
        # The quality of the goods comes BEFORE the quantity: the stars read as
        # a property of the product ("what it is"), and the number as its amount.
        # The label takes the mouse (unlike the plain labels of the row), because
        # it carries the tooltip with the name of its level; the row wires it to its
        # own hover/click so that hovering the stars still highlights the row.
        quality_label = Label.new()
        quality_label.mouse_filter = Control.MOUSE_FILTER_STOP
        _apply_row_quality(quality_label, display_name)
        content.add_child(quality_label)
        _sell_quality_labels[display_name] = quality_label

        var stock_label := Label.new()
        stock_label.text = _format_stock(_stock_of(display_name))
        stock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        stock_label.modulate = UI_THEME.color("text_secondary")
        stock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(stock_label)
        _sell_quantity_labels[display_name] = stock_label

    # PURCHASE column: quality and quantity of the goods on the CITY warehouse,
    # right after the price. A GROUP has no single quality — nothing is shown.
    # Quantity is written only when the warehouse actually holds the goods
    # (never "0 units"). The quality star opens the breakdown tooltip on hover.
    var buy_quality_label: Label = null
    if side == SIDE_BUY and not _is_group_id(resource_id):
        buy_quality_label = Label.new()
        buy_quality_label.name = "BuyQualityLabel"
        buy_quality_label.mouse_filter = Control.MOUSE_FILTER_STOP
        _apply_buy_row_quality(buy_quality_label, resource_id)
        buy_quality_label.mouse_entered.connect(_on_buy_quality_hover.bind(resource_id))
        buy_quality_label.mouse_exited.connect(_on_buy_quality_exit)
        content.add_child(buy_quality_label)
        _buy_quality_labels[row_key] = {"label": buy_quality_label, "id": resource_id}

        var buy_quantity_label = Label.new()
        buy_quantity_label.name = "BuyQuantityLabel"
        buy_quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        buy_quantity_label.modulate = UI_THEME.color("text_secondary")
        buy_quantity_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _apply_buy_row_quantity(buy_quantity_label, resource_id)
        content.add_child(buy_quantity_label)
        _buy_quantity_labels[row_key] = {"label": buy_quantity_label, "id": resource_id}

    # No road — no trade: the row stays on the screen as information, but it is dimmed
    # and not wired at all, so it neither highlights nor opens the trade panel. The
    # status row above the columns says why (see _refresh).
    _row_nodes[row_key] = row
    if not _can_trade():
        _set_row_active(row, false)
        return row

    # The interaction is wired even for a row that cannot be traded from RIGHT NOW: the
    # warehouse of the city moves while the window is open, and a row comes alive without a
    # rebuild (see _refresh_row_gates). What an inactive row refuses is the reaction — the
    # highlight and the click (see _on_row_hover, _toggle_selection).
    # The quality label to wire: the sell stars for the sale column, the buy star marker
    # for the purchase column (null for group rows).
    var row_quality_label := quality_label
    if side == SIDE_BUY:
        row_quality_label = buy_quality_label
    _wire_row_interaction(row, [price_label, row_quality_label], side, resource_id, display_name)
    _set_row_active(row, _row_tradable(side, resource_id))
    if side == SIDE_BUY:
        _buy_rows[row_key] = {"row": row, "id": resource_id}
    return row

# Whether the row can be traded from right now. The trade must exist at all (see _can_trade),
# and the goods must be there to trade: the sale column is capped by the town's own stock, while
# the purchase column needs the goods in the warehouse of the city — the town buys what the city
# can deliver, and a row of a good the warehouse does not hold is an entry of the pool, not an
# offer.
func _row_tradable(side: String, resource_id: String) -> bool:
    if not _can_trade():
        return false
    return _has_city_stock(resource_id) if side == SIDE_BUY else true

# Whether the warehouse of the city holds at least one unit of the goods. A GROUP is satisfied
# by any ONE of its members, and the sum over the members is exactly what tells "at least one"
# (GameData.get_good_stock reads both forms, and counts the decorated variants of a good) — the
# member that is actually shipped is picked at the settlement (town_trade_manager._take_from_city).
func _has_city_stock(resource_id: String) -> bool:
    return GameData.get_good_stock(resource_id, CityData.city_storage) > 0

# Writes the tradability of a row into it: the dimming the player sees and the mark the handlers
# and the tests read back. An inactive row is still built and still readable — the player must see
# what the town wants — it just cannot be traded from.
#
# It carries no hint of its own: the dimming says the row is not offered, and a tooltip on the row
# would cover the standard group tooltip that a group row shows on hover — the one place where the
# composition of a group is read from this window.
func _set_row_active(row: Control, active: bool) -> void:
    if row == null or not is_instance_valid(row):
        return
    row.set_meta(META_ROW_ACTIVE, active)
    # A row of a town that cannot be traded with (no road) is still shown — the player
    # reads what the town has and what it lacks — but it is inert, and the dimming is
    # what says so before the click.
    row.modulate = Color.WHITE if active else UI_THEME.color("row_dim")

func _is_row_active(row: Control) -> bool:
    return bool(row.get_meta(META_ROW_ACTIVE, true))

# Re-reads the tradability of the purchase rows against the warehouse of the city. The window is
# refreshed on every town tick (see refresh_storage), while the city keeps producing: a row of a
# good that has just appeared in the warehouse must become tradable without the player closing
# and reopening the window, and a row whose goods have run out must stop pretending otherwise.
#
# The selection follows: a trade panel left open over a good the city can no longer deliver has
# nothing to trade, so it is put away with the row.
func _refresh_row_gates() -> void:
    for key in _buy_rows:
        var entry: Dictionary = _buy_rows[key]
        var row = entry.get("row", null)
        if row == null or not is_instance_valid(row):
            continue
        var active := _row_tradable(SIDE_BUY, str(entry.get("id", "")))
        if active == _is_row_active(row):
            continue
        _set_row_active(row, active)
        if not active and str(key) == _selected_key:
            _clear_selection()

# The name of a row. A single good is a plain label. A GROUP is a reference: the name
# carries the standard dashed underline of a group, and hovering it shows the standard
# group tooltip with the members of the group — the same mark and the same tooltip the
# recipes and the costs of a building use (ui_helpers.make_resource_entry).
func _make_name_label(resource_id: String, display_name: String) -> Label:
    if not _is_group_id(resource_id):
        var plain := Label.new()
        plain.text = display_name
        plain.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        plain.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        plain.mouse_filter = Control.MOUSE_FILTER_IGNORE
        return plain
    # The script is taken by path: the global class cache may not be there yet in a
    # headless --script run (the same note as in ui_helpers.make_resource_entry).
    var link = load("res://scripts/underlined_label.gd").new()
    link.text = display_name
    link.underline_text = display_name
    link.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    # PASS and not STOP: the row must still receive the hover and the click that open
    # the trade panel, while the label itself needs the hover for the group tooltip.
    link.mouse_filter = Control.MOUSE_FILTER_PASS
    link.mouse_entered.connect(_on_group_name_hover.bind(resource_id))
    link.mouse_exited.connect(_on_group_name_exit)
    return link

# The standard group tooltip of a group row: the name of the group and the list of its
# members. It is the same panel the rest of the game uses (ui_helpers.show_group_tooltip),
# so the composition of a group is read the same way everywhere.
func _on_group_name_hover(resource_id: String) -> void:
    var helpers := _get_ui_helpers()
    if helpers == null:
        return
    helpers.show_group_tooltip(get_viewport().get_mouse_position(), resource_id,
            GameData.products, CityData.city_storage, CityData.city_quality_detail)

func _on_group_name_exit() -> void:
    _hide_group_tooltip()

# The tooltip instance of the window: the one of the map when it has one (the normal
# case — the map owns a standard instance for its HUD), otherwise a private one created
# on the first hover (a window opened on its own in a test).
func _get_ui_helpers() -> Node:
    if _map != null and is_instance_valid(_map) and _map.has_method("get_ui_helpers"):
        var shared = _map.get_ui_helpers()
        if shared != null and is_instance_valid(shared):
            return shared
    if _own_ui_helpers == null or not is_instance_valid(_own_ui_helpers):
        _own_ui_helpers = load("res://scripts/ui_helpers.gd").new()
        _own_ui_helpers.setup(self, null)
        add_child(_own_ui_helpers)
    return _own_ui_helpers

func _hide_group_tooltip() -> void:
    if _own_ui_helpers != null and is_instance_valid(_own_ui_helpers):
        _own_ui_helpers.hide_group_tooltip()
    if _map != null and is_instance_valid(_map) and _map.has_method("get_ui_helpers"):
        var shared = _map.get_ui_helpers()
        if shared != null and is_instance_valid(shared):
            shared.hide_group_tooltip()

# Connects the row and its interactive children (the price and the quality stars) to
# the common hover/click handlers. The row is the argument of both handlers, so an
# enter of a child after the exit of the row does not clear the highlight of the same
# row.
func _wire_row_interaction(row: Control, children: Array,
        side: String, resource_id: String, display_name: String) -> void:
    row.mouse_entered.connect(_on_row_hover.bind(row, true))
    row.mouse_exited.connect(_on_row_hover.bind(row, false))
    row.gui_input.connect(_on_row_gui_input.bind(side, resource_id, display_name))
    for child in children:
        if child == null or not is_instance_valid(child):
            continue
        child.mouse_entered.connect(_on_row_hover.bind(row, true))
        child.mouse_exited.connect(_on_row_hover.bind(row, false))
        child.gui_input.connect(_on_row_gui_input.bind(side, resource_id, display_name))

func _on_row_hover(row: Control, hovered: bool) -> void:
    if row == null or not is_instance_valid(row):
        return
    # A row that cannot be traded from does not react to the cursor: the dimming already says
    # so, and a highlight would promise an action the click refuses (see _toggle_selection).
    if hovered and not _is_row_active(row):
        return
    if hovered:
        _hovered_row = row
    elif _hovered_row == row:
        _hovered_row = null
    _apply_row_style(row)

func _on_row_gui_input(event: InputEvent, side: String,
        resource_id: String, display_name: String) -> void:
    if event is InputEventMouseButton and event.pressed \
            and event.button_index == MOUSE_BUTTON_LEFT:
        _toggle_selection(side, resource_id, display_name)

# A click on a row selects the resource and opens its trade panel under the row; a
# repeated click on the selected row closes the panel. Only one resource is selected
# at a time, so selecting in one column closes the panel of the other.
#
# A row that cannot be traded from opens nothing: without a road the trade is unavailable
# altogether, and in the purchase column a good the city cannot deliver has nothing to sell.
# The rows of a town without a road are not even wired to this handler (see
# _build_resource_row); the guard here is the second lock — no caller can open the trade
# settings of a deal that cannot be made.
func _toggle_selection(side: String, resource_id: String, display_name: String) -> void:
    if not _row_tradable(side, resource_id):
        return
    var key := "%s:%s" % [side, resource_id]
    if _selected_key == key:
        _clear_selection()
        return
    _selected_key = key
    _selected_side = side
    _selected_id = resource_id
    _selected_name = display_name
    _hovered_row = null
    # The row of a good that already carries a standing contract opens the settings of
    # THAT contract: the amount comes prefilled and the "Permanent" flag is already on.
    _sync_selected_contract()
    _panel_permanent = not _selected_contract.is_empty()
    _open_trade_panel(_default_panel_amount())
    _refresh_row_styles()

# The amount a freshly opened panel starts with: the volume of the contract being edited,
# or the default step for a fresh order.
func _default_panel_amount() -> int:
    if _selected_contract.is_empty():
        return DEFAULT_AMOUNT
    return maxi(int(_selected_contract.get("amount", DEFAULT_AMOUNT)), 1)

# Reads the standing contract of the selected row from the map. The pair (town, good) is
# the identity of a deal (see town_trade_manager), so this is what tells "sign a contract"
# from "edit the current one". A map that cannot answer (a test stub) means "no contract".
func _sync_selected_contract() -> void:
    _selected_contract = {}
    if _town == null or _selected_id.is_empty():
        return
    if _map == null or not is_instance_valid(_map) or not _map.has_method("get_town_contract"):
        return
    var contract = _map.get_town_contract(str(_town.get("id", "")), _selected_id)
    if contract is Dictionary and not (contract as Dictionary).is_empty():
        _selected_contract = contract

func _sync_selected_delivery() -> void:
    _selected_delivery = {}
    if _town == null or _selected_side != SIDE_SELL or _selected_id.is_empty():
        return
    if _map == null or not is_instance_valid(_map) or not _map.has_method("get_town_deliveries"):
        return
    var town_id := str(_town.get("id", ""))
    for delivery in _map.get_town_deliveries():
        if delivery is Dictionary \
                and str(delivery.get("town_id", "")) == town_id \
                and str(delivery.get("product_id", "")) == _selected_id \
                and int(delivery.get("remaining", delivery.get("amount", 0))) > 0:
            _selected_delivery = delivery
            return

# The list of the standing contracts changed — a contract was signed, updated or torn
# (see town_trade_manager.contracts_changed). The panel of the selected good follows the
# contract of that good, whatever changed it: an order that has just been signed turns the
# panel into an EDIT of the new contract at once, so the deal can be closed or corrected
# right away instead of only after the panel is closed and reopened; a contract that has
# gone (torn by the tick, or closed) turns the panel back into a fresh order.
#
# A change that does not flip the state of the panel is ignored on purpose: the amount the
# player is typing must not be thrown away because some OTHER deal moved.
func on_contracts_changed() -> void:
    if _town == null or not visible or _selected_id.is_empty():
        return
    var was_editing := not _selected_contract.is_empty()
    _sync_selected_contract()
    if (not _selected_contract.is_empty()) == was_editing:
        _update_deal_status_label()
        return
    _panel_permanent = not _selected_contract.is_empty()
    _open_trade_panel(_default_panel_amount())
    _refresh_row_styles()

func _clear_selection() -> void:
    _selected_key = ""
    _selected_side = ""
    _selected_id = ""
    _selected_name = ""
    _selected_contract = {}
    _selected_delivery = {}
    _hovered_row = null
    _free_trade_panel()
    _refresh_row_styles()

func _free_trade_panel() -> void:
    if _trade_panel != null and is_instance_valid(_trade_panel):
        var parent := _trade_panel.get_parent()
        if parent != null:
            parent.remove_child(_trade_panel)
        _trade_panel.queue_free()
    _trade_panel = null
    _amount_edit = null
    _permanent_check = null
    _warning_badge = null
    _confirm_button = null
    _total_label = null
    _deal_status_label = null
    _cancel_deal_button = null

# Applies the state stylebox to one row: the selected state wins over the hover, so
# the selected row stays highlighted while the cursor is elsewhere.
func _apply_row_style(row: Control) -> void:
    if row == null or not is_instance_valid(row):
        return
    var color := row_normal_color()
    if str(row.get_meta(META_ROW_KEY, "")) == _selected_key:
        color = row_selected_color()
    elif row == _hovered_row:
        color = row_hover_color()
    row.add_theme_stylebox_override("panel", _make_row_style(color))

func _refresh_row_styles() -> void:
    for key in _row_nodes:
        _apply_row_style(_row_nodes[key])

func _make_row_style(color: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color
    style.content_margin_left = 4.0
    style.content_margin_right = 4.0
    style.content_margin_top = 0.0
    style.content_margin_bottom = 0.0
    return style

# --- The trade settings panel ---

# Builds the panel for the selected resource and inserts it right under its row. The
# panel is the FOUNDATION of the trade: it validates the amount, shows the route
# warning and hands the assembled order over by the signal.
#
# amount — the amount to show in the field (the previous one when the panel is rebuilt
# on a refresh, the default step when a row is opened).
#
# The panel is the trade settings of a town, so it does not exist without a trade: with
# no road to the town, or over a good the city cannot deliver, the call is a no-op (see
# _can_trade, _row_tradable).
func _open_trade_panel(amount: int) -> void:
    if not _row_tradable(_selected_side, _selected_id):
        return
    _free_trade_panel()
    var row: Control = _row_nodes.get(_selected_key, null)
    if row == null or not is_instance_valid(row):
        return
    var container := row.get_parent()
    if container == null:
        return
    _sync_selected_delivery()
    _trade_panel = _build_trade_panel()
    container.add_child(_trade_panel)
    container.move_child(_trade_panel, row.get_index() + 1)
    _set_amount(amount if amount > 0 else DEFAULT_AMOUNT)
    _update_amount_feedback()
    _update_confirm_tooltip()
    var scroll := _scroll_for_side(_selected_side)
    if scroll != null:
        scroll.ensure_control_visible(_trade_panel)

func _scroll_for_side(side: String) -> ScrollContainer:
    return sell_scroll if side == SIDE_SELL else buy_scroll

# Builds the panel that sits under the selected row: the amount field with its
# "+"/"−" buttons and the route warning, the "Permanent" checkbox and the pair of
# the confirm/cancel buttons.
#
# There is deliberately NO heading row of the kind "Selling: Wood": the row the panel
# hangs under is highlighted, so the resource and the side are already read from it,
# and the heading only repeated the highlighted row and took a line off the panel.
#
# The confirm/cancel buttons are small square buttons with the icons of a check mark
# and a cross and no text at all — the same look as the buttons of the preview panel
# of the control panel (control_panel._show_preview_header); the words "Confirm" and
# "Cancel" live in their tooltips.
func _build_trade_panel() -> PanelContainer:
    var panel := PanelContainer.new()
    panel.add_theme_stylebox_override("panel", _make_panel_style())
    # The panel itself catches the clicks that land on its empty space (the padding, the
    # caption, the free space of the buttons row) so they clamp the amount like a focus
    # loss does (see _on_panel_gui_input). The children keep their own filters: a click on
    # a button or on the field never reaches the panel.
    panel.mouse_filter = Control.MOUSE_FILTER_STOP
    panel.gui_input.connect(_on_panel_gui_input)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 6)
    # The containers pass the clicks on their empty space down to the panel, so a click
    # between the rows reaches _on_panel_gui_input instead of being swallowed here.
    vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.add_child(vbox)

    var amount_row := HBoxContainer.new()
    amount_row.add_theme_constant_override("separation", 6)
    amount_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var amount_caption := Label.new()
    amount_caption.text = tr("Amount:")
    amount_caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    amount_row.add_child(amount_caption)

    var minus_button := Button.new()
    minus_button.name = "MinusButton"
    minus_button.text = "−"
    minus_button.custom_minimum_size = Vector2(32, 0)
    minus_button.tooltip_text = tr("−%d (Ctrl: −10, Shift: −100)") % STEP_UNITS
    _style_panel_button(minus_button)
    minus_button.pressed.connect(_on_minus_pressed)
    amount_row.add_child(minus_button)

    _amount_edit = LineEdit.new()
    _amount_edit.name = "AmountEdit"
    _amount_edit.custom_minimum_size = Vector2(90, 0)
    _amount_edit.max_length = MAX_AMOUNT_LENGTH
    _amount_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
    _amount_edit.tooltip_text = tr("Only whole positive numbers are accepted")
    _style_amount_field(_amount_edit)
    _amount_edit.text_changed.connect(_on_amount_text_changed)
    _amount_edit.focus_exited.connect(_on_amount_focus_exited)
    amount_row.add_child(_amount_edit)

    var plus_button := Button.new()
    plus_button.name = "PlusButton"
    plus_button.text = "+"
    plus_button.custom_minimum_size = Vector2(32, 0)
    plus_button.tooltip_text = tr("+%d (Ctrl: +10, Shift: +100)") % STEP_UNITS
    _style_panel_button(plus_button)
    plus_button.pressed.connect(_on_plus_pressed)
    amount_row.add_child(plus_button)

    _warning_badge = WarningBadge.new()
    _warning_badge.name = "WarningBadge"
    _warning_badge.visible = false
    amount_row.add_child(_warning_badge)

    vbox.add_child(amount_row)

    _deal_status_label = Label.new()
    _deal_status_label.name = "DealStatusLabel"
    _deal_status_label.visible = false
    vbox.add_child(_deal_status_label)

    # The "Permanent" checkbox. The explanation of the contract belongs to the BOX
    # and not to the whole row: a CheckBox with a text shows its tooltip over the box
    # AND over the caption, so the box is left textless (it carries the tooltip) and
    # the caption becomes a Label of its own. The caption stays clickable — a click on
    # the word toggles the box as well — but it deliberately carries no tooltip.
    var permanent_row := HBoxContainer.new()
    permanent_row.add_theme_constant_override("separation", 4)
    permanent_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _permanent_check = CheckBox.new()
    _permanent_check.name = "PermanentCheck"
    _permanent_check.text = ""
    _permanent_check.tooltip_text = tr("Turn a one-time deal into a standing contract")
    _style_check_box(_permanent_check)
    _permanent_check.button_pressed = _panel_permanent
    _permanent_check.toggled.connect(_on_permanent_toggled)
    permanent_row.add_child(_permanent_check)

    var permanent_label := Label.new()
    permanent_label.name = "PermanentLabel"
    permanent_label.text = tr("Permanent")
    permanent_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    permanent_label.mouse_filter = Control.MOUSE_FILTER_STOP
    permanent_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    permanent_label.gui_input.connect(_on_permanent_label_input)
    permanent_row.add_child(permanent_label)

    vbox.add_child(permanent_row)

    # Confirm / dismiss / deal cancellation: square icon-only buttons, right-aligned. The free space left of
    # them is taken by the total of the order — the label expands, which is what pushes
    # the two buttons to the right edge (see _update_total_label).
    var buttons_row := HBoxContainer.new()
    buttons_row.add_theme_constant_override("separation", 6)
    buttons_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _total_label = UiHelpers.make_money_label()
    _total_label.name = "TotalLabel"
    _total_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _total_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    buttons_row.add_child(_total_label)
    _confirm_button = _make_icon_button(
            "ConfirmButton", "check.svg", "✓", tr("Confirm"))
    _confirm_button.pressed.connect(_on_confirm_pressed)
    buttons_row.add_child(_confirm_button)
    var cancel_button := _make_icon_button(
            "CancelButton", "cross.svg", "✕", tr("Cancel"))
    cancel_button.pressed.connect(_on_cancel_pressed)
    buttons_row.add_child(cancel_button)
    _cancel_deal_button = _make_icon_button(
            "CancelDealButton", "contract_off.svg", "⊘", tr("Cancel the deal"))
    _cancel_deal_button.pressed.connect(_on_cancel_deal_pressed)
    buttons_row.add_child(_cancel_deal_button)
    _update_cancel_deal_button()
    vbox.add_child(buttons_row)

    return panel

func _make_panel_style() -> StyleBoxFlat:
    return UI_THEME.panel()

# --- The frames of the controls of the panel ---
#
# The panel and the window behind it are dark (0.11), and the default theme draws a
# button and a checkbox in a dark grey with a barely visible frame: on the dark
# background they read as "dark on dark" and the player cannot see where a button
# ends and the panel begins. Every control of the panel therefore gets an explicit
# stylebox with a LIGHT frame, so that it is visible without hovering it.
# One stylebox of a control: the same light frame in every state, only the fill and
# the frame colour differ.
func _make_control_style(bg: Color, border: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.border_width_left = 1
    style.border_width_top = 1
    style.border_width_right = 1
    style.border_width_bottom = 1
    style.border_color = border
    style.corner_radius_top_left = 3
    style.corner_radius_top_right = 3
    style.corner_radius_bottom_left = 3
    style.corner_radius_bottom_right = 3
    style.content_margin_left = 4.0
    style.content_margin_right = 4.0
    style.content_margin_top = 2.0
    style.content_margin_bottom = 2.0
    return style

# The frame of a Button of the panel ("+", "−", confirm, cancel). A disabled button
# (the confirm one without a positive amount) gets a dimmed frame, so that "cannot be
# pressed" is visible and not only felt.
#
# The focus state reuses the NORMAL fill: Godot draws exactly one stylebox per state
# (disabled > pressed > hover > focus > normal), so an empty focus box would leave the
# button frameless, and the hover fill would leave it looking hovered after a click
# until the focus moves away.
func _style_panel_button(button: Button) -> void:
    button.add_theme_stylebox_override("normal",
            _make_control_style(UI_THEME.color("control_bg"),
            UI_THEME.color("control_border")))
    button.add_theme_stylebox_override("hover",
            _make_control_style(UI_THEME.color("control_hover"),
            UI_THEME.color("control_border")))
    button.add_theme_stylebox_override("pressed",
            _make_control_style(UI_THEME.color("control_pressed"),
            UI_THEME.color("control_border")))
    button.add_theme_stylebox_override("focus",
            _make_control_style(UI_THEME.color("control_bg"),
            UI_THEME.color("control_border")))
    button.add_theme_stylebox_override("disabled",
            _make_control_style(UI_THEME.color("control_disabled"),
            UI_THEME.color("control_border_disabled")))
    button.add_theme_color_override("font_color", UI_THEME.color("text"))
    button.add_theme_color_override("font_disabled_color", UI_THEME.color("text_muted"))

# The frame of the "Permanent" checkbox. The stylebox of a CheckBox covers the whole
# control, and the box itself is drawn by the theme icon — so the frame goes around
# the box (the caption is a separate Label, see _build_trade_panel).
func _style_check_box(check: CheckBox) -> void:
    check.add_theme_stylebox_override("normal",
            _make_control_style(UI_THEME.color("control_bg"),
            UI_THEME.color("control_border")))
    check.add_theme_stylebox_override("hover",
            _make_control_style(UI_THEME.color("control_hover"),
            UI_THEME.color("control_border")))
    check.add_theme_stylebox_override("pressed",
            _make_control_style(UI_THEME.color("control_pressed"),
            UI_THEME.color("control_border")))
    check.add_theme_stylebox_override("focus",
            _make_control_style(UI_THEME.color("control_bg"),
            UI_THEME.color("control_border")))
    check.add_theme_stylebox_override("disabled",
            _make_control_style(UI_THEME.color("control_disabled"),
            UI_THEME.color("control_border_disabled")))

# The frame of the amount field: the same light border as the buttons have. The field
# stands between them in one row, and without the frame it would read as a hole in
# the panel.
func _style_amount_field(field: LineEdit) -> void:
    field.add_theme_stylebox_override("normal",
            _make_control_style(UI_THEME.color("field_bg"),
            UI_THEME.color("control_border")))
    field.add_theme_stylebox_override("focus",
            _make_control_style(UI_THEME.color("field_bg"),
            UI_THEME.color("control_border")))
    field.add_theme_color_override("font_color", UI_THEME.color("text"))
    field.add_theme_color_override("caret_color", UI_THEME.color("text"))

# A small square button with an icon and no text — the look of the "Start"/"Cancel"
# buttons of the preview panel (control_panel._show_preview_header). The icon comes
# from the common registry; if the file is missing, the button falls back to a glyph
# so that it is never blank.
func _make_icon_button(button_name: String, icon_name: String, fallback_text: String,
        tooltip: String) -> Button:
    var button := Button.new()
    button.name = button_name
    button.custom_minimum_size = Vector2(36, 36)
    button.tooltip_text = tooltip
    button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var tex := IconRegistry.get_texture(icon_name)
    if tex != null:
        button.icon = tex
        button.expand_icon = true
        button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    else:
        button.text = fallback_text
    _style_panel_button(button)
    return button

# A click on the caption of the "Permanent" checkbox toggles it, exactly as a click on
# the box would. The caption carries no tooltip of its own (see _build_trade_panel):
# the explanation of the contract is shown over the box only.
func _on_permanent_label_input(event: InputEvent) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse := event as InputEventMouseButton
    if mouse.button_index != MOUSE_BUTTON_LEFT or not mouse.pressed:
        return
    if _permanent_check != null and is_instance_valid(_permanent_check):
        _permanent_check.button_pressed = not _permanent_check.button_pressed

# The checkbox changed its state: the total must be rewritten — in the permanent
# mode the amount is shown per second ("/sec") — and the confirm button must say what it
# will do: update the contract being edited, or place an ordinary order.
func _on_permanent_toggled(pressed: bool) -> void:
    _panel_permanent = pressed
    _update_total_label(_current_amount())
    _update_deal_status_label()
    _update_confirm_tooltip()
    _update_cancel_deal_button()

func _update_cancel_deal_button() -> void:
    if _cancel_deal_button == null or not is_instance_valid(_cancel_deal_button):
        return
    var permanent := _permanent_check != null and is_instance_valid(_permanent_check) \
            and _permanent_check.button_pressed
    var has_deal := not _selected_contract.is_empty() if permanent \
            else not _selected_delivery.is_empty()
    _cancel_deal_button.visible = has_deal
    _cancel_deal_button.tooltip_text = tr("Close the contract") if permanent \
            else tr("Cancel the deal")

# The confirm button explains itself by what it will actually do. While the panel edits a
# standing contract AND the "Permanent" flag is on, confirm updates that contract; with the
# flag off the same click places a one-time purchase and leaves the contract alone, so the
# hint must not promise an update.
func _update_confirm_tooltip() -> void:
    if _confirm_button == null or not is_instance_valid(_confirm_button):
        return
    var permanent := _permanent_check != null and is_instance_valid(_permanent_check) \
            and _permanent_check.button_pressed
    if not _selected_contract.is_empty() and permanent:
        _confirm_button.tooltip_text = tr("Update the contract")
    else:
        _confirm_button.tooltip_text = tr("Confirm")

# --- The amount field ---

# The step of the "+"/"−" buttons by the modifiers held at the moment of the click:
# units by default, tens with Ctrl, hundreds with Shift. Ctrl wins when both are
# held, so a click always has one well-defined step.
func _amount_step(ctrl: bool, shift: bool) -> int:
    if ctrl:
        return STEP_TENS
    if shift:
        return STEP_HUNDREDS
    return STEP_UNITS

func _step_from_modifiers() -> int:
    return _amount_step(Input.is_key_pressed(KEY_CTRL), Input.is_key_pressed(KEY_SHIFT))

func _on_plus_pressed() -> void:
    _add_amount(_step_from_modifiers())

func _on_minus_pressed() -> void:
    _add_amount(-_step_from_modifiers())

# Changes the amount by delta and writes the result back into the field. The amount
# never falls below 1 when there is something to decrease: an empty field is allowed
# while typing, but "−" is not meant to produce a zero order.
func _add_amount(delta: int) -> void:
    var current := _current_amount()
    if current <= 0:
        if delta < 0:
            return
        _set_amount(_clamp_to_stock(delta))
        return
    _set_amount(maxi(1, _clamp_to_stock(current + delta)))

# The largest amount the open panel may order: what the town actually holds, or 0 when the
# amount is unbounded (the city selling to the town — the panel does not track the storage
# of the city).
#
# Buying from a town (the sale column) is limited by its stock: the manager refuses more
# than that (see town_trade_manager._buy_once), so the field must not offer the surplus in
# the first place. The ceiling is the stock of the SPECIFIC id behind the row and not the
# summed number the row shows, because that sum can cover several ids that share a display
# name while the manager checks one id only.
func _max_order_amount() -> int:
    if _town == null or _selected_side != SIDE_SELL or _selected_id.is_empty():
        return 0
    return maxi(int(_town.get("storage", {}).get(_selected_id, 0)), 1)

# Brings an amount down to the stock of the town when the amount is bounded. It is the one
# place the ceiling is applied, so the "+" button, the amount typed by hand and the order
# itself cannot disagree about how much the town has.
func _clamp_to_stock(amount: int) -> int:
    var limit := _max_order_amount()
    if limit <= 0:
        return amount
    return mini(amount, limit)

func _set_amount(amount: int) -> void:
    if _amount_edit == null or not is_instance_valid(_amount_edit):
        return
    _suppress_edit = true
    _amount_edit.text = str(amount)
    _amount_edit.caret_column = _amount_edit.text.length()
    _suppress_edit = false
    _update_amount_feedback()

func _current_amount() -> int:
    if _amount_edit == null or not is_instance_valid(_amount_edit):
        return 0
    var text := _amount_edit.text.strip_edges()
    if text.is_empty() or not text.is_valid_int():
        return 0
    return int(text)

# The amount field accepts whole positive numbers only. Everything that is not a
# digit is dropped right in the handler (so a paste is filtered too), and the leading
# zeros are removed so that the field never shows "007" or a lone "0".
func _on_amount_text_changed(new_text: String) -> void:
    if _suppress_edit:
        return
    var clean := _sanitize_amount(new_text)
    if clean != new_text and _amount_edit != null and is_instance_valid(_amount_edit):
        _suppress_edit = true
        _amount_edit.text = clean
        _amount_edit.caret_column = clean.length()
        _suppress_edit = false
    _update_amount_feedback()

# A number typed by hand is not held back while the player is still typing (he may be on
# his way to a smaller number), so the amount is brought down to the stock of the town the
# moment the field loses focus. That covers the confirm click as well: the button takes the
# focus, the field gives it up and the amount is clamped BEFORE the order is assembled.
func _on_amount_focus_exited() -> void:
    _commit_amount_clamp()

# A click on the empty space of the panel — the padding between the rows, the caption,
# the free space of the buttons row — takes the focus away from the amount field, the
# same way a click on the confirm button does. The field must not keep a number above
# the stock in it just because the click did not land on a control: the amount is clamped
# right here, so the "+" button, the focus loss and the click on the panel all agree.
func _on_panel_gui_input(event: InputEvent) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse := event as InputEventMouseButton
    if mouse.button_index != MOUSE_BUTTON_LEFT or not mouse.pressed:
        return
    _commit_amount_clamp()

# Brings the amount down to the stock of the town when it is above the ceiling. The single
# action behind the three moments the ceiling is applied at once — the focus loss, the
# click on the empty space of the panel and the order itself — so they cannot diverge.
func _commit_amount_clamp() -> void:
    if _amount_edit == null or not is_instance_valid(_amount_edit):
        return
    var amount := _current_amount()
    var clamped := _clamp_to_stock(amount)
    if clamped != amount:
        _set_amount(clamped)

func _sanitize_amount(text: String) -> String:
    var digits := ""
    for i in range(text.length()):
        var ch := text[i]
        if ch >= "0" and ch <= "9":
            digits += ch
    return digits.lstrip("0")

# Re-evaluates the whole panel after the amount changed: the confirm button is
# enabled only for a valid (positive) amount, and the route warning follows the
# amount against the throughput of the route.
func _update_amount_feedback() -> void:
    var amount := _current_amount()
    if _confirm_button != null and is_instance_valid(_confirm_button):
        _confirm_button.disabled = amount <= 0
    _update_warning_badge(amount)
    _update_deal_status_label()
    _update_total_label(amount)

# The sum of the order, in the free space left of the confirm/cancel buttons. It is
# recomputed on EVERY change of the amount — the field and the "+"/"−" buttons both go
# through _update_amount_feedback — so the number follows the typing in real time and
# the player sees what the deal costs (or brings) before he confirms it.
#
# The direction is read from the side. The sale column holds the goods the TOWN sells,
# so the city PAYS for them (red); the buy column holds the goods the town wants, so the
# city IS PAID for them (gold). The amount and the price of a unit are whole numbers, so
# the total is a whole number of coins — exactly what the treasury will move. While the
# panel edits a contract the total is counted at the price frozen at its signing (see
# _selected_unit_price): an edit changes the amount only.
func _update_total_label(amount: int) -> void:
    if _total_label == null or not is_instance_valid(_total_label):
        return
    var total := amount * _selected_unit_price()
    var permanent := _permanent_check != null and is_instance_valid(_permanent_check) \
            and _permanent_check.button_pressed
    var total_text := UiHelpers.money_rate(str(total)) if permanent else UiHelpers.money(str(total))
    if _selected_side == SIDE_SELL:
        _total_label.text = tr("Cost: %s") % total_text
        _total_label.add_theme_color_override("default_color", color_expense())
    else:
        _total_label.text = tr("Income: %s") % total_text
        _total_label.add_theme_color_override("default_color", color_income())

# The warning triangle is shown when the entered amount is larger than the route can
# carry: the surplus is not lost, it queues on the road and arrives later (see
# delivery_manager.gd), but the player must know the road is the bottleneck.
func _update_warning_badge(amount: int) -> void:
    if _warning_badge == null or not is_instance_valid(_warning_badge):
        return
    var capacity := _route_capacity()
    var over := _exceeds_capacity(amount, capacity)
    _warning_badge.visible = over
    if over:
        # The hint names the numbers and is therefore rebuilt on every change of the
        # amount. The engine draws a tooltip in a single line and never breaks it, so the
        # text goes through the wrapping carrier (see wrapped_tooltip.gd); attach() is
        # idempotent, so the badge keeps ONE carrier and only the text is replaced.
        WrappedTooltip.attach(_warning_badge,
                tr("The amount %d exceeds the route throughput (%s units/sec).\nThe surplus will queue on the road and arrive later.") % [amount, _format_speed(capacity)])

# Whether the amount is larger than what the route can carry. The rule is a pure
# function so that it can be checked without a map.
func _exceeds_capacity(amount: int, capacity: float) -> bool:
    return amount > 0 and float(amount) > capacity

# The throughput of the route from the town to the city, in units/sec — the average
# speed of its segments (see road_manager.find_route_to_city). A town without a road
# has no route and therefore no throughput: it is taken as zero, so any amount warns
# about the shortfall (the status row already says the trade is unavailable).
func _route_capacity() -> float:
    if _map == null or not is_instance_valid(_map) or _town == null:
        return 0.0
    if not _map.has_method("get_route_to_city"):
        return 0.0
    var route: Dictionary = _map.get_route_to_city(
            int(_town.get("row", -1)), int(_town.get("col", -1)))
    if not bool(route.get("ok", false)):
        return 0.0
    return float(route.get("avg_speed", 0.0))

func _format_speed(value: float) -> String:
    if is_equal_approx(value, roundf(value)):
        return str(int(roundf(value)))
    return "%.1f" % value

func _update_deal_status_label() -> void:
    if _deal_status_label == null or not is_instance_valid(_deal_status_label):
        return
    var permanent := _permanent_check != null and is_instance_valid(_permanent_check) \
            and _permanent_check.button_pressed
    var deal: Dictionary = _selected_contract if permanent else _selected_delivery
    if deal.is_empty():
        _deal_status_label.visible = false
        return
    _deal_status_label.visible = true
    if permanent:
        _deal_status_label.text = tr("Contract: %d units/sec") % int(deal.get("amount", 0))
    else:
        _deal_status_label.text = tr("One-time deal: %d units in transit") % int(
                deal.get("remaining", deal.get("amount", 0)))
    _deal_status_label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))

# --- Confirm / cancel ---

# Assembles the order and hands it over. The unit price is the same number the
# total of the panel is made of, so the treasury is charged exactly the sum the
# player saw. The panel claims nothing about the outcome: the reply of the mechanics
# is reported by the HUD (see main_map._on_town_trade_order).
#
# When the panel edits a standing contract, the order carries the frozen price of that
# contract and the manager updates it in place instead of signing a second one (one town
# carries one contract per good, see town_trade_manager).
#
# An order that BECOMES a standing contract turns the panel into an edit of it by itself:
# the manager announces the change (contracts_changed) and the window re-reads the contract
# of the selected good (see on_contracts_changed).
func _on_confirm_pressed() -> void:
    var amount := _clamp_to_stock(_current_amount())
    if amount <= 0:
        return
    # The field is brought in line with the order as well: the stock may have moved between
    # the typing and the click, and the number on the screen must be the number that is sent.
    _set_amount(amount)
    _last_order = {
        "town_id": str(_town.get("id", "")),
        "town_name": str(_town.get("name", "")),
        "row": int(_town.get("row", -1)),
        "col": int(_town.get("col", -1)),
        "side": _selected_side,
        "product_id": _selected_id,
        "product_name": _selected_name,
        "amount": amount,
        "permanent": _permanent_check != null and _permanent_check.button_pressed,
        "route_capacity": _route_capacity(),
        "unit_price": _selected_unit_price(),
    }
    emit_signal("trade_order_submitted", _last_order)
    _sync_selected_delivery()
    _update_deal_status_label()
    _update_cancel_deal_button()

func _on_cancel_pressed() -> void:
    _clear_selection()

# Closes the contract the panel is editing and turns the panel back into a fresh order:
# the good becomes free for a new deal — with the same terms or with different ones. The
# window only asks (the signal); the mechanics and the report are the map's business.
#
# The panel resets right away instead of waiting for the answer: closing a contract that
# exists always succeeds, and the player then sees the "new contract" state on the very
# same row (the amount back at the default, the "Permanent" flag off, the close button
# gone). The reset goes BEFORE the signal, so the change the manager announces
# (contracts_changed, see on_contracts_changed) finds the panel already fresh and does not
# rebuild it a second time.
func _on_close_contract_pressed() -> void:
    if _selected_contract.is_empty():
        return
    var contract_id := str(_selected_contract.get("id", ""))
    _selected_contract = {}
    _panel_permanent = false
    _open_trade_panel(DEFAULT_AMOUNT)
    emit_signal("contract_close_requested", contract_id)

func _on_cancel_deal_pressed() -> void:
    var permanent := _permanent_check != null and is_instance_valid(_permanent_check) \
            and _permanent_check.button_pressed
    if permanent:
        _on_close_contract_pressed()
        return
    if _selected_delivery.is_empty():
        return
    emit_signal("delivery_cancel_requested", str(_town.get("id", "")), _selected_id)
    _sync_selected_delivery()
    _update_deal_status_label()
    _update_cancel_deal_button()

# --- The categories ---

# Whether the key of a row is a group ("@fruits") rather than a concrete good.
func _is_group_id(resource_id: String) -> bool:
    return resource_id.begins_with("@")

# The category of a trade-pool resource — the same field the "Resources" tab groups
# by. A town pool may hold a raw resource id as itself (a resource with no
# production), so the lookup goes through the common reference, which covers both the
# raw resources and the products. A group is filed under the category of its members
# (TownEconomy.get_group_category). An id without a category falls back to "other".
func _get_resource_category(resource_id: String) -> String:
    if _is_group_id(resource_id):
        return TownEconomy.get_group_category(resource_id)
    var category := str(GameData.get_resource_data(resource_id).get("category", ""))
    return category if not category.is_empty() else "other"

# The display name of a category id from data/categories.json. An id that is not in
# the reference (for example the raw "animals" or "plants" of a hex resource) is shown
# as is.
func _get_category_name(category_id: String) -> String:
    for entry in GameData.categories:
        if str(entry.get("id", "")) == category_id:
            return str(entry.get("name", category_id))
    return category_id

# The category ids of the groups, ordered by data/categories.json; a group that is
# not in the reference is appended in the order it was encountered.
func _ordered_categories(grouped: Dictionary) -> Array:
    var ordered: Array = []
    for entry in GameData.categories:
        var category_id := str(entry.get("id", ""))
        if grouped.has(category_id):
            ordered.append(category_id)
    for category_id in grouped.keys():
        if not ordered.has(category_id):
            ordered.append(category_id)
    return ordered

# The icon of a row: the icon of the product, or the icon of the group (its own one, or
# the one of its first member that has an icon — see GameData.get_product_group_icon).
func _get_resource_icon_name(resource_id: String) -> String:
    if _is_group_id(resource_id):
        return GameData.get_product_group_icon(resource_id)
    var resource_data := GameData.get_resource_data(resource_id)
    return str(resource_data.get("icon", ""))

func _get_resource_display_name(resource_id: String) -> String:
    if _is_group_id(resource_id):
        return GameData.format_resource_name(resource_id)
    var resource_data := GameData.get_resource_data(resource_id)
    var display_name := str(resource_data.get("name", ""))
    if not display_name.is_empty():
        return display_name
    # A guard for opening the window at the moment when the common loader has not yet
    # filled GameData: we still show not the ID but the available name.
    var raw_data: Dictionary = GameData.raw_resources.get(resource_id, {})
    if not raw_data.is_empty():
        return str(raw_data.get("name", resource_id))
    var product_data: Dictionary = GameData.products.get(resource_id, {})
    return str(product_data.get("name", resource_id))

# --- Service access for tests ---

# The display names of the rows that are currently shown in the container.
# Service access for tests: the "two identical names in the list" check
# reads exactly what the player sees (see tests/test_town_economy.gd).
func _visible_row_names(container: VBoxContainer) -> Array:
    var names: Array = []
    for entry in _visible_list_entries(container):
        if entry["kind"] == "row":
            names.append(entry["text"])
    return names

# The column exactly as the player reads it: a sequence of entries, each
# {"kind": "header"|"row", "text": String}; a header also carries "lined" — whether
# its name is flanked by a line on both sides. Service access for tests, so a test
# does not have to know the composite structure of a header or of a row.
func _visible_list_entries(container: VBoxContainer) -> Array:
    var entries: Array = []
    if container == null:
        return entries
    for child in container.get_children():
        if child.has_meta(UiHelpers.META_CATEGORY_HEADER):
            entries.append({
                "kind": "header",
                "text": _category_header_text(child),
                "lined": _category_header_line_count(child) == 2,
            })
        elif child.has_meta(META_RESOURCE_ROW):
            entries.append({"kind": "row", "text": str(child.get_meta(META_ROW_NAME, ""))})
    return entries

# The name of a category header — the label marked as the name, not a side line.
func _category_header_text(header: Node) -> String:
    for part in header.get_children():
        if part.has_meta(UiHelpers.META_CATEGORY_NAME):
            return part.text
    return ""

# How many side lines a category header carries (0, 1 or 2).
func _category_header_line_count(header: Node) -> int:
    var count := 0
    for part in header.get_children():
        if part is ColorRect:
            count += 1
    return count

# The display name of a resource row. The row keeps its name in its metadata (the
# name label is a descendant of the row's content box, not a direct child).
func _resource_row_name(row: Node) -> String:
    return str(row.get_meta(META_ROW_NAME, ""))

func close_town():
    if not visible:
        return
    _hide_group_tooltip()
    _clear_selection()
    _town = null
    has_town = false
    hide()
    emit_signal("closed")
