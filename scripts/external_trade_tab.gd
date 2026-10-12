# external_trade_tab.gd
# The right column of the tab "Trade" — the foreign trade with the towns.
#
# The column is split into two sections: "Trade deals" (the deals with the towns) and
# "Trade partners" (the towns the city knows about). The sections are switched by a pair of
# small square buttons with icons and tooltips — the same look as the tab bar of the city.
# Every section has its own sorting, and the state of one section does not touch the other.
#
# The trade with the towns is NOT implemented yet, therefore the section "Trade deals" collects
# no rows and shows the empty state. Its sorting is nevertheless real: it works on the row shape
# documented in _collect_deals, so the day the trade appears only that source has to be filled in.
#
# The section "Trade partners" is filled with the towns the player has discovered: a town is
# known when its hex lies in the known territory or has been scouted — the same condition under
# which the town is drawn on the map (town_manager.is_town_discovered). A town without a road
# stays in the list: the road gates the trade itself (town_manager.is_trade_available) and is
# shown by a marker in the row, but a town the player has already found must be visible before
# it is connected as well — that is exactly what the list is for.
#
# The layout of the column lives in the scene CityUI.tscn
# (ContentPanel/TradePanel/Split/ExternalPanel): the buttons, the sort bars and the lists are
# there, and the script only fills the lists and the tooltips.
extends Node

# The shared helpers: the highlight of the active button of a toggle group is common for the
# tab bar of the city and for the section bar of this column.
const UiHelpers = preload("res://scripts/ui_helpers.gd")

signal town_focus_requested(row: int, col: int)

const SECTION_DEALS := "deals"
const SECTION_PARTNERS := "partners"

# The sorting keys. They name the data, and not the buttons: the buttons only point at them, and
# the comparators (_deal_sort_value / _partner_sort_value) switch on them.
const SORT_NAME := "name"
const SORT_PRICE := "price"
const SORT_TYPE := "type"
const SORT_DISTANCE := "distance"

# The type of a deal: the city buys the goods from the town or sells them to it.
const DEAL_TYPE_BUY := "buy"
const DEAL_TYPE_SELL := "sell"

# The icons of the column. The icons are taken from the common registry IconRegistry (autoload):
# the index of the file names and the cache of the textures there are common for the whole
# project, so the column does not need its own walk of res://icons and its own cache.
const ICON_SECTION_DEALS := "market.png"
const ICON_SECTION_PARTNERS := "city.png"
const ICON_SORT_NAME := "sort_name.svg"
const ICON_SORT_PRICE := "sort_price.svg"
const ICON_SORT_TYPE := "sort_type.svg"
const ICON_SORT_DISTANCE := "sort_distance.svg"
const ICON_GO_TO := "goto.svg"
const ICON_ROAD := "road.svg"

const ROW_HEIGHT := 26
const SWATCH_SIZE := 12
const GOTO_BUTTON_SIZE := 24
const ROAD_MARKER_SIZE := 18

const COLOR_CAPTION := Color(0.75, 0.75, 0.75, 1)
const COLOR_PRICE := Color(1.0, 0.507, 0.0, 1)
# The colours of the deal types: the same language as on the tab "Domestic trade" — what the
# treasury pays is red, what fills it is gold. A purchase spends the treasury, a sale fills it.
const COLOR_EXPENSE := Color(0.9, 0.3, 0.3, 1)
const COLOR_INCOME := Color(1.0, 0.807, 0.2, 1)

# The scene nodes of the column (filled in setup).
var external_panel: Control = null
var deals_section: Control = null
var partners_section: Control = null
var deals_list: Node = null
var partners_list: Node = null
# The groups of the buttons: [{ "button": Button, "id": section }] and
# [{ "button": Button, "key": sort key }].
var section_buttons: Array = []
var deals_sort_buttons: Array = []
var partners_sort_buttons: Array = []

var ui_helpers: Node = null
# The reference to MainMap (see set_map): the column reads the discovered towns and the distance
# to them from there.
var main_map: Node = null

var active_section: String = SECTION_DEALS

# The sorting of both sections. The keys and the directions are kept separately: the sections
# show different lists, and switching a section must not reshuffle the other one.
var deals_sort_key: String = SORT_NAME
var deals_descending: bool = false
var partners_sort_key: String = SORT_NAME
var partners_descending: bool = false

# The labels of the composition of the lists, used to tell "the rows have not changed" from
# "the rows have to be rebuilt". A rebuild resets the scrolling of the list and drops the
# tooltip under the cursor (an assignment of tooltip_text removes the shown window), therefore
# an unchanged list must cost nothing — exactly as the cards of the domestic trade do it
# (see trade_tab._signature_of).
var _deals_signature: String = ""
var _partners_signature: String = ""

func setup(panel: Control, helpers: Node) -> void:
    external_panel = panel
    ui_helpers = helpers
    if panel == null or not is_instance_valid(panel):
        return
    deals_section = panel.get_node_or_null("DealsSection")
    partners_section = panel.get_node_or_null("PartnersSection")
    deals_list = panel.get_node_or_null("DealsSection/DealsScroll/DealsList")
    partners_list = panel.get_node_or_null("PartnersSection/PartnersScroll/PartnersList")
    section_buttons = [
        {"button": panel.get_node_or_null("SectionsBar/DealsButton"), "id": SECTION_DEALS},
        {"button": panel.get_node_or_null("SectionsBar/PartnersButton"), "id": SECTION_PARTNERS},
    ]
    deals_sort_buttons = [
        {"button": panel.get_node_or_null("DealsSection/SortBar/NameSortButton"), "key": SORT_NAME},
        {"button": panel.get_node_or_null("DealsSection/SortBar/PriceSortButton"), "key": SORT_PRICE},
        {"button": panel.get_node_or_null("DealsSection/SortBar/TypeSortButton"), "key": SORT_TYPE},
    ]
    partners_sort_buttons = [
        {"button": panel.get_node_or_null("PartnersSection/SortBar/NameSortButton"), "key": SORT_NAME},
        {"button": panel.get_node_or_null("PartnersSection/SortBar/DistanceSortButton"), "key": SORT_DISTANCE},
    ]
    _setup_icons()
    _connect_buttons()
    _switch_section(active_section)

# The reference to MainMap. The column reads the towns discovered by the player and the distance
# to them from it; the jump to a town goes the other way — by the signal town_focus_requested,
# so that the column does not close the interface of the city behind the back of its owner.
func set_map(map_node: Node) -> void:
    main_map = map_node
    # The list of the towns is rebuilt from the new map: the signature of the old one must not
    # pass as "nothing has changed".
    _partners_signature = ""

# A full rebuild of the column: the sections, the sort buttons and both lists. It is called on
# opening the tab, on the structural changes of the city and on a change of the language (the
# tooltips and the labels of the rows are assembled in the code, and the engine does not
# translate them again).
func refresh() -> void:
    _switch_section(active_section)
    _update_sort_buttons()
    _refresh_deals()
    _refresh_partners()

# The light update of the resource display era (see city_ui._refresh_light). Both sections
# compare the composition of their list against the signature first, so an unchanged list costs
# nothing and does not lose its scrolling and its tooltips.
func update_values() -> void:
    _refresh_deals()
    _refresh_partners()

# --- THE SECTIONS ---

# The switch of the sections. The sections are ordinary panels with manual visibility — the same
# approach as with the tabs of the city (city_ui._switch_tab): a TabContainer would bring its own
# styling and would not let the switch buttons sit in the header row of the column.
func _switch_section(section_id: String) -> void:
    active_section = section_id
    if deals_section != null and is_instance_valid(deals_section):
        deals_section.visible = section_id == SECTION_DEALS
    if partners_section != null and is_instance_valid(partners_section):
        partners_section.visible = section_id == SECTION_PARTNERS
    _update_section_buttons()

func _on_section_pressed(section_id: String) -> void:
    _switch_section(section_id)

func _update_section_buttons() -> void:
    for entry in section_buttons:
        var button: Button = entry["button"]
        if button == null or not is_instance_valid(button):
            continue
        UiHelpers.highlight_toggle_button(button, str(entry["id"]) == active_section)

# --- THE SORTING ---

# A click on a sort button. Another key — the section switches to it and sorts in the ascending
# order; the same key — the order reverses. The same idiom as the priority button of the
# consumption (see trade_tab._on_priority_pressed): the pair "key + direction" is reachable with
# a single row of buttons.
func _on_deals_sort_pressed(key: String) -> void:
    if deals_sort_key == key:
        deals_descending = not deals_descending
    else:
        deals_sort_key = key
        deals_descending = false
    _update_sort_buttons()
    _refresh_deals()

func _on_partners_sort_pressed(key: String) -> void:
    if partners_sort_key == key:
        partners_descending = not partners_descending
    else:
        partners_sort_key = key
        partners_descending = false
    _update_sort_buttons()
    _refresh_partners()

# The state of the buttons: the active key is highlighted (the same accent as the tab bar of the
# city), and the tooltip says what the button sorts by, in which direction the list stands now
# and what a click will do.
func _update_sort_buttons() -> void:
    for entry in deals_sort_buttons:
        _apply_sort_button(entry["button"], _deal_sort_label(str(entry["key"])),
                str(entry["key"]) == deals_sort_key, deals_descending)
    for entry in partners_sort_buttons:
        _apply_sort_button(entry["button"], _partner_sort_label(str(entry["key"])),
                str(entry["key"]) == partners_sort_key, partners_descending)

func _apply_sort_button(button: Button, label: String, active: bool, descending: bool) -> void:
    if button == null or not is_instance_valid(button):
        return
    UiHelpers.highlight_toggle_button(button, active)
    var lines: Array = [label]
    if active:
        lines.append(tr("Descending") if descending else tr("Ascending"))
    lines.append(tr("Click: sort the list; a repeated click reverses the order"))
    button.tooltip_text = "\n".join(lines)

func _deal_sort_label(key: String) -> String:
    match key:
        SORT_PRICE:
            return tr("By resource price")
        SORT_TYPE:
            return tr("By deal type")
        _:
            return tr("By resource name")

func _partner_sort_label(key: String) -> String:
    return tr("By distance to the town") if key == SORT_DISTANCE else tr("By town name")

# The comparison of two rows by the key of the section. The tie-breaker is always the name:
# without it the order of the rows with an equal key depended on the order of the source list,
# which is not defined, and the list would reshuffle between the refreshes.
func _row_less(left_value: Variant, right_value: Variant,
        left_name: String, right_name: String, descending: bool) -> bool:
    if left_value == right_value:
        return left_name.to_lower() < right_name.to_lower()
    if descending:
        return left_value > right_value
    return left_value < right_value

func _sorted_deals(deals: Array) -> Array:
    var result: Array = deals.duplicate()
    result.sort_custom(func(a, b): return _row_less(
            _deal_sort_value(a), _deal_sort_value(b),
            str(a.get("name", "")), str(b.get("name", "")), deals_descending))
    return result

func _sorted_partners(partners: Array) -> Array:
    var result: Array = partners.duplicate()
    result.sort_custom(func(a, b): return _row_less(
            _partner_sort_value(a), _partner_sort_value(b),
            str(a.get("name", "")), str(b.get("name", "")), partners_descending))
    return result

# The value a deal is sorted by. The type is sorted by its place in the order "buy → sell" and
# not by its text: the names of the types are translated, and the order of the list must not
# depend on the language.
func _deal_sort_value(deal: Dictionary) -> Variant:
    match deals_sort_key:
        SORT_PRICE:
            return int(deal.get("price", 0))
        SORT_TYPE:
            return 1 if str(deal.get("type", DEAL_TYPE_BUY)) == DEAL_TYPE_SELL else 0
        _:
            return str(deal.get("name", "")).to_lower()

func _partner_sort_value(partner: Dictionary) -> Variant:
    if partners_sort_key == SORT_DISTANCE:
        return int(partner.get("distance", 0))
    return str(partner.get("name", "")).to_lower()

# --- THE SECTION "TRADE DEALS" ---

# The deals with the towns — the source of the section. The trade with the towns is NOT
# implemented yet, therefore the list is empty and the section shows the empty state; the
# sorting above it is real and works on the shape below, so the day the trade appears this
# method is the only thing to fill in.
#
# The shape of a row (the contract of _build_deal_row):
#
#   town_id     the id of the town from town_manager (service: it is not shown)
#   town_name   the name of the town the deal is made with
#   product_id  the id of the goods
#   name        the display name of the goods — the row shows it
#   icon        the file name of the icon of the goods (see IconRegistry)
#   type        "buy" — the city buys the goods from the town, "sell" — the city sells them
#   price       coins per unit
func _collect_deals() -> Array:
    return []

# The signature of the deals list: everything a row shows plus the sorting in force. Any change
# rebuilds the rows — the rows of this section have no in-place update, and a rebuild is exactly
# what shows the fresh prices.
func _deals_signature_of(deals: Array) -> String:
    var parts: Array = [deals_sort_key, "1" if deals_descending else "0"]
    for deal in deals:
        parts.append("%s|%s|%s|%s|%d" % [
            str(deal.get("product_id", "")), str(deal.get("town_id", "")),
            str(deal.get("type", "")), str(deal.get("name", "")), int(deal.get("price", 0))])
    return ";".join(PackedStringArray(parts))

func _refresh_deals() -> void:
    var deals: Array = _sorted_deals(_collect_deals())
    var signature := _deals_signature_of(deals)
    if signature == _deals_signature:
        return
    _deals_signature = signature
    _fill_deals(deals)

func _fill_deals(deals: Array) -> void:
    var rows: Array = []
    for deal in deals:
        rows.append(_build_deal_row(deal))
    _fill_list(deals_list, rows, tr("No trade deals yet"))

# One row of the section: the goods, the town the deal is made with, the type of the deal and the
# price. The type is painted in the colours of the interface (a purchase spends the treasury, a
# sale fills it), so the row is read at a glance.
func _build_deal_row(deal: Dictionary) -> HBoxContainer:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    row.custom_minimum_size = Vector2(0, ROW_HEIGHT)

    var icon_tex := IconRegistry.get_texture(str(deal.get("icon", "")))
    if icon_tex != null:
        var icon := TextureRect.new()
        icon.texture = icon_tex
        icon.custom_minimum_size = Vector2(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
        icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(icon)

    var name_label := Label.new()
    name_label.text = str(deal.get("name", ""))
    name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    name_label.mouse_filter = Control.MOUSE_FILTER_STOP
    row.add_child(name_label)

    var town_label := Label.new()
    town_label.text = str(deal.get("town_name", ""))
    town_label.add_theme_color_override("font_color", COLOR_CAPTION)
    town_label.mouse_filter = Control.MOUSE_FILTER_STOP
    row.add_child(town_label)

    var deal_type := str(deal.get("type", DEAL_TYPE_BUY))
    var type_label := Label.new()
    type_label.text = _deal_type_name(deal_type)
    type_label.add_theme_color_override("font_color", _deal_type_color(deal_type))
    type_label.mouse_filter = Control.MOUSE_FILTER_STOP
    row.add_child(type_label)

    var price_label := Label.new()
    price_label.text = str(int(deal.get("price", 0)))
    price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    price_label.custom_minimum_size = Vector2(44, 0)
    price_label.add_theme_color_override("font_color", COLOR_PRICE)
    price_label.mouse_filter = Control.MOUSE_FILTER_STOP
    row.add_child(price_label)
    return row

func _deal_type_name(deal_type: String) -> String:
    return tr("Sale") if deal_type == DEAL_TYPE_SELL else tr("Purchase")

func _deal_type_color(deal_type: String) -> Color:
    return COLOR_INCOME if deal_type == DEAL_TYPE_SELL else COLOR_EXPENSE

# --- THE SECTION "TRADE PARTNERS" ---

# The towns discovered by the player, with the distance from the city and the state of the road
# link — see main_map.get_trade_partners.
func _collect_partners() -> Array:
    if main_map == null or not is_instance_valid(main_map) \
            or not main_map.has_method("get_trade_partners"):
        return []
    return main_map.get_trade_partners()

# The signature of the partners list: the towns in the order in which they are shown, with the
# state of their road. The name, the colour and the distance of a town never change, therefore
# they are not in the signature: the list must not be rebuilt because of them.
func _partners_signature_of(partners: Array) -> String:
    var parts: Array = [partners_sort_key, "1" if partners_descending else "0"]
    for partner in partners:
        parts.append("%s:%s" % [str(partner.get("id", "")),
                "1" if bool(partner.get("trade_available", true)) else "0"])
    return ";".join(PackedStringArray(parts))

func _refresh_partners() -> void:
    var partners: Array = _sorted_partners(_collect_partners())
    var signature := _partners_signature_of(partners)
    if signature == _partners_signature:
        return
    _partners_signature = signature
    _fill_partners(partners)

func _fill_partners(partners: Array) -> void:
    var rows: Array = []
    for partner in partners:
        rows.append(_build_partner_row(partner))
    _fill_list(partners_list, rows, tr("No towns discovered yet"))

# One row of the section: the colour of the borders of the town on the map, its name, the
# distance from the city in hexes, the marker of a missing road and the button of the jump to the
# town.
func _build_partner_row(partner: Dictionary) -> HBoxContainer:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    row.custom_minimum_size = Vector2(0, ROW_HEIGHT)

    # The colour of the borders of the town on the map: it is by this colour that the row and the
    # ring around the town are matched (the colour is written into the record of the town, see
    # town_manager._make_border_color).
    var swatch := ColorRect.new()
    swatch.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
    swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    swatch.color = _border_color(partner)
    swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(swatch)

    var name_label := Label.new()
    name_label.text = str(partner.get("name", ""))
    name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    name_label.mouse_filter = Control.MOUSE_FILTER_STOP
    row.add_child(name_label)

    var distance := int(partner.get("distance", 0))
    var distance_label := Label.new()
    distance_label.text = str(distance)
    distance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    distance_label.custom_minimum_size = Vector2(28, 0)
    distance_label.modulate = Color(0.8, 0.8, 0.8)
    distance_label.mouse_filter = Control.MOUSE_FILTER_STOP
    distance_label.tooltip_text = tr(" Distance to city: %d hex(es)") % distance
    row.add_child(distance_label)

    # A town without a road stays in the list: the road gates the trade, not the knowledge of the
    # town (town_manager.is_trade_available). The marker explains why the town cannot be traded
    # with yet, and the tooltip says how to fix it.
    if not bool(partner.get("trade_available", true)):
        var road_marker := TextureRect.new()
        road_marker.texture = IconRegistry.get_texture(ICON_ROAD)
        road_marker.custom_minimum_size = Vector2(ROAD_MARKER_SIZE, ROAD_MARKER_SIZE)
        road_marker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        road_marker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        road_marker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        road_marker.modulate = Color(1, 1, 1, 0.45)
        road_marker.mouse_filter = Control.MOUSE_FILTER_STOP
        road_marker.tooltip_text = tr("Trade unavailable: there is no road from the city to this town")
        row.add_child(road_marker)

    var goto_button := Button.new()
    goto_button.custom_minimum_size = Vector2(GOTO_BUTTON_SIZE, GOTO_BUTTON_SIZE)
    goto_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    _set_button_icon(goto_button, ICON_GO_TO, ROAD_MARKER_SIZE)
    goto_button.tooltip_text = tr("Go to the town")
    goto_button.pressed.connect(_on_goto_pressed.bind(
            int(partner.get("row", -1)), int(partner.get("col", -1))))
    row.add_child(goto_button)
    return row

# The jump to the town: the column only announces the intention, and the interface of the city is
# closed by its owner (city_ui forwards the signal to main_map), so the column does not have to
# know how the city interface is put away.
func _on_goto_pressed(row: int, col: int) -> void:
    if row < 0 or col < 0:
        return
    emit_signal("town_focus_requested", row, col)

# The colour of the borders of a town (town["border_color"], four floats written by town_manager).
# A broken record falls back to a neutral grey: the row must not disappear because of the colour.
func _border_color(partner: Dictionary) -> Color:
    var stored = partner.get("color", [])
    if stored is Array and stored.size() >= 3:
        return Color(float(stored[0]), float(stored[1]), float(stored[2]))
    return COLOR_CAPTION

# --- THE COMMON ---

# Replaces the contents of a list with the passed rows, or with the empty state when there is
# nothing to show. The rows are built by the caller: the sections differ in what a row is.
func _fill_list(container: Node, rows: Array, empty_text: String) -> void:
    if container == null or not is_instance_valid(container):
        return
    for child in container.get_children():
        container.remove_child(child)
        child.queue_free()
    if rows.is_empty():
        var empty := Label.new()
        empty.text = empty_text
        empty.add_theme_color_override("font_color", COLOR_CAPTION)
        container.add_child(empty)
        return
    for row in rows:
        container.add_child(row)

func _setup_icons() -> void:
    var icons := [
        {"button": _button_of(section_buttons, SECTION_DEALS), "icon": ICON_SECTION_DEALS, "size": 30},
        {"button": _button_of(section_buttons, SECTION_PARTNERS), "icon": ICON_SECTION_PARTNERS, "size": 30},
    ]
    for entry in deals_sort_buttons:
        icons.append({"button": entry["button"], "icon": _sort_icon(str(entry["key"])), "size": 22})
    for entry in partners_sort_buttons:
        icons.append({"button": entry["button"], "icon": _sort_icon(str(entry["key"])), "size": 22})
    for entry in icons:
        _set_button_icon(entry["button"], entry["icon"], int(entry["size"]))

func _sort_icon(key: String) -> String:
    match key:
        SORT_PRICE:
            return ICON_SORT_PRICE
        SORT_TYPE:
            return ICON_SORT_TYPE
        SORT_DISTANCE:
            return ICON_SORT_DISTANCE
        _:
            return ICON_SORT_NAME

func _button_of(group: Array, id: String):
    for entry in group:
        if str(entry["id"]) == id:
            return entry["button"]
    return null

func _set_button_icon(button: Button, icon_name: String, max_size: int) -> void:
    if button == null or not is_instance_valid(button):
        return
    var tex := IconRegistry.get_texture(icon_name)
    if tex == null:
        return
    button.icon = tex
    button.expand_icon = true
    button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    button.add_theme_constant_override("icon_max_width", max_size)
    button.add_theme_constant_override("icon_max_height", max_size)

func _connect_buttons() -> void:
    for entry in section_buttons:
        var button: Button = entry["button"]
        if button != null and not button.pressed.is_connected(_on_section_pressed):
            button.pressed.connect(_on_section_pressed.bind(str(entry["id"])))
    for entry in deals_sort_buttons:
        var button: Button = entry["button"]
        if button != null and not button.pressed.is_connected(_on_deals_sort_pressed):
            button.pressed.connect(_on_deals_sort_pressed.bind(str(entry["key"])))
    for entry in partners_sort_buttons:
        var button: Button = entry["button"]
        if button != null and not button.pressed.is_connected(_on_partners_sort_pressed):
            button.pressed.connect(_on_partners_sort_pressed.bind(str(entry["key"])))
