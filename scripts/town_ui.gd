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
#
# Both columns are grouped by the resource category, exactly like the "Resources"
# tab of the city (see _fill_resource_list): a header of a solid line, the category
# name centred in its column, then a line again; the rows of that category follow.
#
# A row is INTERACTIVE: it highlights on hover and, on a click, opens the trade
# settings of the resource right under itself (see _open_trade_panel). The highlight
# is a stylebox on the row's PanelContainer — a transparent normal, a light hover and
# a stronger "selected" state — so the row reacts like a button without turning every
# label of the row into a button. The interaction is only wired when the trade with the
# town is available at all: without a road the rows are pure information (see
# _can_trade).
#
# Every row of the sale column carries the stock of the town and its quality: the
# stars of the level in its own colour (data/qualities.json). A town never holds
# mixed quality, so there is nothing to break down and nothing to show in
# percentages — the stars ARE the quality of the row (see town_economy).
#
# Every row, of either column, carries the price of ONE unit of the goods (in coins),
# to the right of the name — see _unit_price.
#
# The trade settings panel is the FOUNDATION of the trade: it assembles the
# order (the goods, the amount, the "permanent" flag) and hands it over by the
# signal trade_order_submitted. The mechanics that spend the treasury and move the
# goods live behind that signal (main_map._on_town_trade_order ->
# town_trade_manager), and their answer is reported by the HUD, which stays visible
# while the window is open (see hud_message.gd).
extends Control

# The shared UI helpers: the category header of a resource list (a line, the name, a
# line) is built there, so the town window and the "Resources" tab of the city cannot
# drift apart. Only the static members are used — no instance is needed.
const UiHelpers = preload("res://scripts/ui_helpers.gd")

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
# appears only on hover and on the selected row.
const ROW_NORMAL_COLOR := Color(1, 1, 1, 0)
const ROW_HOVER_COLOR := Color(1, 1, 1, 0.10)
const ROW_SELECTED_COLOR := Color(0.30, 0.55, 0.85, 0.35)

# The dimming of a row of a town whose trade is not available (there is no road to it):
# the pool is still shown — the player reads what the town has and what it lacks — but
# the row is inert, and the dimming is what says so before the click (see
# _build_resource_row).
const ROW_DISABLED_MODULATE := Color(0.62, 0.62, 0.62, 1.0)

# The width of the price column of a row. Fixed, so that the prices of the rows line up
# in one column instead of every row placing its number by the length of its own name.
const PRICE_COLUMN_WIDTH := 44

# The colours of the money. The price of one unit is the same gold the "Trade" tab
# already paints its prices with (UiHelpers.PRICE_TEXT_COLOR). The total of an order is
# red when the city PAYS and gold when the city IS PAID — the same pair the deal rows of
# the "Foreign trade" column use (external_trade_tab.COLOR_EXPENSE / COLOR_INCOME), so a
# purchase and a sale are read the same way in both windows.
const COLOR_EXPENSE := Color(0.9, 0.3, 0.3, 1)
const COLOR_INCOME := Color(1.0, 0.807, 0.2, 1)

# The markers that let the layout be read back: a row of a trade column and the key
# of the resource behind it (the tests and the trade panel both use them).
const META_RESOURCE_ROW := "town_resource_row"
const META_ROW_KEY := "town_row_key"
const META_ROW_NAME := "town_row_name"

@onready var window_panel = $WindowPanel
@onready var title_label = $WindowPanel/TitleLabel
@onready var status_label = $WindowPanel/StatusLabel
@onready var treasury_label = $WindowPanel/TreasuryLabel
@onready var close_button = $WindowPanel/CloseButton
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
#   row_key -> { "label": Label, "id": String, "side": String }
# Both columns have prices, so the map is NOT cleared per column — it is cleared once
# per rebuild, in _refresh (unlike the two maps above, which only the sale column uses).
# The market price of a product moves with the dynamic multipliers, and the number is
# refreshed in place on every town tick together with the stock (see refresh_storage).
var _price_labels: Dictionary = {}

# The map (MainMap), set by main_map.set_map. The window asks it for the route to the
# city to know the throughput the route can carry (see _route_capacity). null in a
# test that opens the window on its own — the capacity is then taken as zero.
var _map = null

# The rows that are currently on the screen, by the row key ("buy:grain"). The trade
# panel is inserted right after its row, and the highlight is applied through these
# references, so a rebuild only has to refresh the map.
var _row_nodes: Dictionary = {}
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

# The trade settings panel and its controls (null while it is closed).
var _trade_panel: Control = null
var _amount_edit: LineEdit = null
var _permanent_check: CheckBox = null
var _warning_badge: Control = null
var _confirm_button: Button = null
var _total_label: Label = null

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
    _center_window()
    var viewport := get_viewport()
    if viewport != null and not viewport.size_changed.is_connected(_center_window):
        viewport.size_changed.connect(_center_window)

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
    title_label.text = str(_town.get("name", tr("Town")))
    _update_treasury_label()
    if status_label:
        # The trade status — for now only a label. An empty row when trade is
        # available: "everything is fine, there is nothing to report".
        status_label.text = "" if _trade_available \
                else tr("Trade unavailable: there is no road from the city to this town")
        status_label.visible = not status_label.text.is_empty()
    _row_nodes.clear()
    _price_labels.clear()
    _fill_resource_list(buy_list, _town.get("buy_pool", []), tr("The town buys nothing"),
            SIDE_BUY, false)
    _fill_resource_list(sell_list, _town.get("sell_pool", []),
            tr("No resources in the influence ring"), SIDE_SELL, true)
    # The lists were rebuilt from scratch, so the open trade panel (if any) and the
    # highlight of its row have to be put back on top of the fresh rows.
    if not _selected_key.is_empty():
        var keep_amount := _current_amount()
        _open_trade_panel(keep_amount)
        _refresh_row_styles()

# Refreshes ONLY the live numbers of the rows — the stock and the stars of the sale
# column and the price of every row of both columns — without touching the rows
# themselves. It is called on every town tick while the window is open: the warehouse of
# the town grows several times a second and the market price moves with the dynamic
# multipliers, and a full rebuild would throw away the scroll position of the list and
# the highlight of the cursor.
func refresh_storage():
    if _town == null or not visible:
        return
    for display_name in _sell_quantity_labels:
        var label: Label = _sell_quantity_labels[display_name]
        if is_instance_valid(label):
            label.text = _format_stock(_stock_of(display_name))
    for display_name in _sell_quality_labels:
        var quality_label: Label = _sell_quality_labels[display_name]
        if is_instance_valid(quality_label):
            _apply_row_quality(quality_label, str(display_name))
    for key in _price_labels:
        var entry: Dictionary = _price_labels[key]
        var price_label = entry.get("label", null)
        if price_label is Label and is_instance_valid(price_label):
            _apply_row_price(price_label, str(entry.get("id", "")), str(entry.get("side", "")))
    _update_treasury_label()
    # The total of an open order is the amount times the price of a unit, so it has to
    # follow the price as well — otherwise the sum would go stale under the player.
    if _trade_panel != null and is_instance_valid(_trade_panel):
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
func _unit_price(resource_id: String, side: String) -> int:
    var quality_id := _town_quality_of(resource_id) if side == SIDE_SELL else ""
    return int(round(GameData.get_price_for_quality(resource_id, quality_id)))

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
# unit" next to it — so the words live in the tooltip.
func _apply_row_price(price_label: Label, resource_id: String, side: String) -> void:
    var price := _unit_price(resource_id, side)
    price_label.text = str(price)
    price_label.tooltip_text = tr("Price per unit: %d coins") % price

func _format_stock(amount: int) -> String:
    return tr("%d units") % amount

func _update_treasury_label() -> void:
    if treasury_label == null or _town == null:
        return
    treasury_label.text = tr("Treasury: %d") % int(_town.get("treasury", 0))

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
    # The old rows are detached before the free so that the container holds exactly
    # the fresh rows already in the same frame (queue_free alone would keep the old
    # ones as children until the end of the frame).
    for child in container.get_children():
        container.remove_child(child)
        child.queue_free()
    if pool == null or pool.is_empty():
        var empty_label := Label.new()
        empty_label.text = empty_text
        empty_label.modulate = Color(0.65, 0.65, 0.65)
        container.add_child(empty_label)
        return
    # One entry per display name, grouped by the category of the id behind it. The
    # first id behind a name wins (see the note above), and it also decides the
    # category the row lands in.
    var grouped: Dictionary = {}
    var shown_names: Dictionary = {}
    for resource_id in pool:
        if resource_id == null:
            continue
        var id := str(resource_id).strip_edges()
        if id.is_empty() or id == "<null>":
            continue
        var display_name := _get_resource_display_name(id)
        if shown_names.has(display_name):
            continue
        shown_names[display_name] = true
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
    row.add_theme_stylebox_override("panel", _make_row_style(ROW_NORMAL_COLOR))

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

    var resource_label := Label.new()
    resource_label.text = display_name
    resource_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    resource_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    resource_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(resource_label)

    # The price of ONE unit of the goods, right after the name: the number the player
    # compares the rows by. It keeps its own tooltip (the bare number does not say that
    # it is the price of a single unit) and is wired to the row, exactly like the
    # quality stars — otherwise it would be a dead zone in the middle of the row.
    var price_label := Label.new()
    price_label.name = "PriceLabel"
    price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    price_label.custom_minimum_size = Vector2(PRICE_COLUMN_WIDTH, 0)
    price_label.add_theme_color_override("font_color", UiHelpers.PRICE_TEXT_COLOR)
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
        stock_label.modulate = Color(0.8, 0.8, 0.8)
        stock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(stock_label)
        _sell_quantity_labels[display_name] = stock_label

    # No road — no trade: the row stays on the screen as information, but it is dimmed
    # and not wired at all, so it neither highlights nor opens the trade panel. The
    # status row above the columns says why (see _refresh).
    if not _can_trade():
        row.modulate = ROW_DISABLED_MODULATE
        _row_nodes[row_key] = row
        return row

    _wire_row_interaction(row, [price_label, quality_label], side, resource_id, display_name)
    _row_nodes[row_key] = row
    return row

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
# Without a road the trade is unavailable and nothing happens at all: the rows of such
# a town are not even wired to this handler (see _build_resource_row), and the guard
# here is the second lock — no caller can open the trade settings of a town the trade
# is not available with.
func _toggle_selection(side: String, resource_id: String, display_name: String) -> void:
    if not _can_trade():
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
    _panel_permanent = false
    _open_trade_panel(DEFAULT_AMOUNT)
    _refresh_row_styles()

func _clear_selection() -> void:
    _selected_key = ""
    _selected_side = ""
    _selected_id = ""
    _selected_name = ""
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

# Applies the state stylebox to one row: the selected state wins over the hover, so
# the selected row stays highlighted while the cursor is elsewhere.
func _apply_row_style(row: Control) -> void:
    if row == null or not is_instance_valid(row):
        return
    var color := ROW_NORMAL_COLOR
    if str(row.get_meta(META_ROW_KEY, "")) == _selected_key:
        color = ROW_SELECTED_COLOR
    elif row == _hovered_row:
        color = ROW_HOVER_COLOR
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
# no road to the town the call is a no-op (see _can_trade).
func _open_trade_panel(amount: int) -> void:
    if not _can_trade():
        return
    _free_trade_panel()
    var row: Control = _row_nodes.get(_selected_key, null)
    if row == null or not is_instance_valid(row):
        return
    var container := row.get_parent()
    if container == null:
        return
    _trade_panel = _build_trade_panel()
    container.add_child(_trade_panel)
    container.move_child(_trade_panel, row.get_index() + 1)
    _set_amount(amount if amount > 0 else DEFAULT_AMOUNT)
    _update_amount_feedback()
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

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 6)
    panel.add_child(vbox)

    var amount_row := HBoxContainer.new()
    amount_row.add_theme_constant_override("separation", 6)
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

    # The "Permanent" checkbox. The explanation of the contract belongs to the BOX
    # and not to the whole row: a CheckBox with a text shows its tooltip over the box
    # AND over the caption, so the box is left textless (it carries the tooltip) and
    # the caption becomes a Label of its own. The caption stays clickable — a click on
    # the word toggles the box as well — but it deliberately carries no tooltip.
    var permanent_row := HBoxContainer.new()
    permanent_row.add_theme_constant_override("separation", 4)
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

    # Confirm / cancel: square icon-only buttons, right-aligned. The free space left of
    # them is taken by the total of the order — the label expands, which is what pushes
    # the two buttons to the right edge (see _update_total_label).
    var buttons_row := HBoxContainer.new()
    buttons_row.add_theme_constant_override("separation", 6)
    _total_label = Label.new()
    _total_label.name = "TotalLabel"
    _total_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _total_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    _total_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    buttons_row.add_child(_total_label)
    _confirm_button = _make_icon_button(
            "ConfirmButton", "check.svg", "✓", tr("Confirm"))
    _confirm_button.pressed.connect(_on_confirm_pressed)
    buttons_row.add_child(_confirm_button)
    var cancel_button := _make_icon_button(
            "CancelButton", "cross.svg", "✕", tr("Cancel"))
    cancel_button.pressed.connect(_on_cancel_pressed)
    buttons_row.add_child(cancel_button)
    vbox.add_child(buttons_row)

    return panel

func _make_panel_style() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.11, 0.11, 0.11, 0.96)
    style.border_width_left = 1
    style.border_width_top = 1
    style.border_width_right = 1
    style.border_width_bottom = 1
    style.border_color = Color(0.45, 0.45, 0.45, 1)
    style.content_margin_left = 8.0
    style.content_margin_right = 8.0
    style.content_margin_top = 6.0
    style.content_margin_bottom = 6.0
    return style

# --- The frames of the controls of the panel ---
#
# The panel and the window behind it are dark (0.11), and the default theme draws a
# button and a checkbox in a dark grey with a barely visible frame: on the dark
# background they read as "dark on dark" and the player cannot see where a button
# ends and the panel begins. Every control of the panel therefore gets an explicit
# stylebox with a LIGHT frame, so that it is visible without hovering it.
const CONTROL_BG_COLOR := Color(0.20, 0.20, 0.22, 1.0)
const CONTROL_BG_HOVER_COLOR := Color(0.30, 0.30, 0.34, 1.0)
const CONTROL_BG_PRESSED_COLOR := Color(0.13, 0.13, 0.15, 1.0)
const CONTROL_BG_DISABLED_COLOR := Color(0.15, 0.15, 0.15, 1.0)
const CONTROL_BORDER_COLOR := Color(0.62, 0.62, 0.66, 1.0)
const CONTROL_BORDER_DISABLED_COLOR := Color(0.33, 0.33, 0.33, 1.0)

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
            _make_control_style(CONTROL_BG_COLOR, CONTROL_BORDER_COLOR))
    button.add_theme_stylebox_override("hover",
            _make_control_style(CONTROL_BG_HOVER_COLOR, CONTROL_BORDER_COLOR))
    button.add_theme_stylebox_override("pressed",
            _make_control_style(CONTROL_BG_PRESSED_COLOR, CONTROL_BORDER_COLOR))
    button.add_theme_stylebox_override("focus",
            _make_control_style(CONTROL_BG_COLOR, CONTROL_BORDER_COLOR))
    button.add_theme_stylebox_override("disabled",
            _make_control_style(CONTROL_BG_DISABLED_COLOR, CONTROL_BORDER_DISABLED_COLOR))
    button.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
    button.add_theme_color_override("font_disabled_color", Color(0.5, 0.5, 0.5))

# The frame of the "Permanent" checkbox. The stylebox of a CheckBox covers the whole
# control, and the box itself is drawn by the theme icon — so the frame goes around
# the box (the caption is a separate Label, see _build_trade_panel).
func _style_check_box(check: CheckBox) -> void:
    check.add_theme_stylebox_override("normal",
            _make_control_style(CONTROL_BG_COLOR, CONTROL_BORDER_COLOR))
    check.add_theme_stylebox_override("hover",
            _make_control_style(CONTROL_BG_HOVER_COLOR, CONTROL_BORDER_COLOR))
    check.add_theme_stylebox_override("pressed",
            _make_control_style(CONTROL_BG_PRESSED_COLOR, CONTROL_BORDER_COLOR))
    check.add_theme_stylebox_override("focus",
            _make_control_style(CONTROL_BG_COLOR, CONTROL_BORDER_COLOR))
    check.add_theme_stylebox_override("disabled",
            _make_control_style(CONTROL_BG_DISABLED_COLOR, CONTROL_BORDER_DISABLED_COLOR))

# The frame of the amount field: the same light border as the buttons have. The field
# stands between them in one row, and without the frame it would read as a hole in
# the panel.
func _style_amount_field(field: LineEdit) -> void:
    field.add_theme_stylebox_override("normal",
            _make_control_style(CONTROL_BG_PRESSED_COLOR, CONTROL_BORDER_COLOR))
    field.add_theme_stylebox_override("focus",
            _make_control_style(CONTROL_BG_PRESSED_COLOR, CONTROL_BORDER_COLOR))
    field.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
    field.add_theme_color_override("caret_color", Color(0.95, 0.95, 0.95))

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
# mode the amount is shown per second ("/sec").
func _on_permanent_toggled(pressed: bool) -> void:
    _panel_permanent = pressed
    _update_total_label(_current_amount())

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
        _set_amount(delta)
        return
    _set_amount(maxi(1, current + delta))

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
    _update_total_label(amount)

# The sum of the order, in the free space left of the confirm/cancel buttons. It is
# recomputed on EVERY change of the amount — the field and the "+"/"−" buttons both go
# through _update_amount_feedback — so the number follows the typing in real time and
# the player sees what the deal costs (or brings) before he confirms it.
#
# The direction is read from the side. The sale column holds the goods the TOWN sells,
# so the city PAYS for them (red); the buy column holds the goods the town wants, so the
# city IS PAID for them (gold). The amount and the price of a unit are whole numbers, so
# the total is a whole number of coins — exactly what the treasury will move.
func _update_total_label(amount: int) -> void:
    if _total_label == null or not is_instance_valid(_total_label):
        return
    var total := amount * _unit_price(_selected_id, _selected_side)
    var permanent := _permanent_check != null and is_instance_valid(_permanent_check) \
            and _permanent_check.button_pressed
    if _selected_side == SIDE_SELL:
        if permanent:
            _total_label.text = tr("Cost: %d/sec") % total
        else:
            _total_label.text = tr("Cost: %d") % total
        _total_label.add_theme_color_override("font_color", COLOR_EXPENSE)
    else:
        if permanent:
            _total_label.text = tr("Income: %d/sec") % total
        else:
            _total_label.text = tr("Income: %d") % total
        _total_label.add_theme_color_override("font_color", COLOR_INCOME)

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
        _warning_badge.tooltip_text = tr("The amount %d exceeds the route throughput (%s units/sec). The surplus will queue on the road and arrive later.") % [amount, _format_speed(capacity)]

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

# --- Confirm / cancel ---

# Assembles the order and hands it over. The unit price is the same number the
# total of the panel is made of, so the treasury is charged exactly the sum the
# player saw. The panel claims nothing about the outcome: the reply of the mechanics
# is reported by the HUD (see main_map._on_town_trade_order).
func _on_confirm_pressed() -> void:
    var amount := _current_amount()
    if amount <= 0:
        return
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
        "unit_price": _unit_price(_selected_id, _selected_side),
    }
    emit_signal("trade_order_submitted", _last_order)

func _on_cancel_pressed() -> void:
    _clear_selection()

# --- The categories ---

# The category of a trade-pool resource — the same field the "Resources" tab groups
# by. A town pool may hold a raw resource id as itself (a resource with no
# production), so the lookup goes through the common reference, which covers both the
# raw resources and the products. An id without a category falls back to "other".
func _get_resource_category(resource_id: String) -> String:
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

func _get_resource_icon_name(resource_id: String) -> String:
    var resource_data := GameData.get_resource_data(resource_id)
    return str(resource_data.get("icon", ""))

func _get_resource_display_name(resource_id: String) -> String:
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
    _clear_selection()
    _town = null
    has_town = false
    hide()
    emit_signal("closed")
