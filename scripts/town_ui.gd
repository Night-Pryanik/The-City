# town_ui.gd
# The town (small settlement) interface — the trade window.
# It is opened from the control panel (the action button on a town hex)
# or by a double click on the town hex on the map (see InputHandler).
#
# Initial stage: a window with a heading (the town name) and two columns
# "Buy" and "Sell". The window is not fullscreen — the fixed layout
# is set right in the TownUI.tscn scene, without any code at runtime.
#
# The lists are inside ScrollContainers (see BuyScroll/SellScroll in the scene):
# the sell pool of a town is dozens of rows, and without scrolling they spilled
# past the bottom edge of the window right onto the map.
#
# Every row of the sale column carries the stock of the town and its quality: the
# stars of the level in its own colour (data/qualities.json). A town never holds
# mixed quality, so there is nothing to break down and nothing to show in
# percentages — the stars ARE the quality of the row (see town_economy).
extends Control

signal closed()

# The minimum height of a list row. It equals the icon height (28 px): a label with
# a line wrap should not squeeze the icon and the next row.
const ROW_HEIGHT := 28

@onready var window_panel = $WindowPanel
@onready var title_label = $WindowPanel/TitleLabel
@onready var status_label = $WindowPanel/StatusLabel
@onready var treasury_label = $WindowPanel/TreasuryLabel
@onready var close_button = $WindowPanel/CloseButton
@onready var buy_scroll = $WindowPanel/ColumnsHBox/BuyColumn/BuyScroll
@onready var sell_scroll = $WindowPanel/ColumnsHBox/SellColumn/SellScroll
@onready var buy_list = $WindowPanel/ColumnsHBox/BuyColumn/BuyScroll/BuyList
@onready var sell_list = $WindowPanel/ColumnsHBox/SellColumn/SellScroll/SellList
# The resource icons are taken from the common IconRegistry registry (autoload):
# the index is built once per game, and not on every window opening.
# The current town (an entry from town_manager.towns). null — the window is closed.
var _town = null
# Whether trade with this town is available (town_manager.is_trade_available).
# While the trade itself is not implemented, this is only a status row under the name:
# the window opens even without a road — you can see what the town has for sale and
# what it wants to buy. When real trade appears, this flag will decide
# whether buying and selling are possible (see town_manager.is_trade_available).
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
func _ready():
    if close_button:
        close_button.pressed.connect(close_town)

# Opens the interface window for a town.
# town — a town entry from town_manager.towns (the row, col, name, ... fields).
# trade_available — whether trade with it is available (true by default: the window
# always opens, see the _trade_available field).
func open_town(town: Dictionary, trade_available: bool = true):
    _town = town
    _trade_available = trade_available
    has_town = true
    _refresh()
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
    _fill_resource_list(buy_list, _town.get("buy_pool", []), tr("The town buys nothing"))
    _fill_resource_list(sell_list, _town.get("sell_pool", []),
            tr("No resources in the influence ring"), true)

# Refreshes ONLY the numbers of the stock in the sale column, without touching the
# rows themselves. It is called on every town tick while the window is open: the
# warehouse of the town grows several times a second, and a full rebuild would throw
# away the scroll position of the list and the highlight of the cursor.
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
    _update_treasury_label()

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

# Fills the column with one row per resource of the trade pool.
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
# with_stock — whether to append the units on the stock of the town to the row.
# It is only the sale column: the town buys the goods it lacks, and there is
# nothing of its own to count.
func _fill_resource_list(container: VBoxContainer, pool, empty_text: String,
        with_stock: bool = false) -> void:
    if container == null:
        return
    if with_stock:
        _sell_quantity_labels.clear()
        _sell_quality_labels.clear()
    for child in container.get_children():
        child.queue_free()
    if pool == null or pool.is_empty():
        var empty_label := Label.new()
        empty_label.text = empty_text
        empty_label.modulate = Color(0.65, 0.65, 0.65)
        container.add_child(empty_label)
        return
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
        var resource_row := HBoxContainer.new()
        resource_row.add_theme_constant_override("separation", 6)
        # The row must not collapse, even if the label did not fit into one
        # line and wrapped: without the row height minimum they overlapped each
        # other (see autowrap on resource_label below).
        resource_row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
        var icon_name := _get_resource_icon_name(id)
        var icon_tex := IconRegistry.get_texture(icon_name)
        if icon_tex != null:
            var resource_icon := TextureRect.new()
            resource_icon.texture = icon_tex
            resource_icon.custom_minimum_size = Vector2(28, 28)
            resource_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            resource_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
            resource_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
            resource_row.add_child(resource_icon)

        var resource_label := Label.new()
        resource_label.text = display_name
        resource_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        resource_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        resource_row.add_child(resource_label)

        if with_stock:
            # The quality of the goods comes BEFORE the quantity: the stars read as
            # a property of the product ("what it is"), and the number as its amount.
            # The label takes the mouse (unlike the plain labels of the row), because
            # it carries the tooltip with the name of its level.
            var quality_label := Label.new()
            quality_label.mouse_filter = Control.MOUSE_FILTER_STOP
            _apply_row_quality(quality_label, display_name)
            resource_row.add_child(quality_label)
            _sell_quality_labels[display_name] = quality_label

            var stock_label := Label.new()
            stock_label.text = _format_stock(_stock_of(display_name))
            stock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
            stock_label.modulate = Color(0.8, 0.8, 0.8)
            resource_row.add_child(stock_label)
            _sell_quantity_labels[display_name] = stock_label

        container.add_child(resource_row)

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

# Closes the town interface window. It emits closed — main_map will return
# the HUD and the control panel (see main_map._on_town_ui_close).
# The display names of the rows that are currently shown in the container.
# Service access for tests: the "two identical names in the list" check
# reads exactly what the player sees (see tests/test_town_economy.gd).
func _visible_row_names(container: VBoxContainer) -> Array:
    var names: Array = []
    if container == null:
        return names
    for child in container.get_children():
        if child is HBoxContainer:
            for node in child.get_children():
                if node is Label:
                    names.append(node.text)
                    break
    return names

func close_town():
    if not visible:
        return
    _town = null
    has_town = false
    hide()
    emit_signal("closed")