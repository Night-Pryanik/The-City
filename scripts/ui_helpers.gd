# ui_helpers.gd
extends Node

const UI_THEME = preload("res://scripts/ui_theme.gd")

var tooltip_panel: Panel
var tooltip_label: Label

var build_tooltip_panel: Panel
var build_tooltip_label: Label

var group_tooltip_panel: Panel
var group_tooltip_content: VBoxContainer

# The tooltip "who consumes this resource" of a row marked with a consumption
# underline. A panel of its own, and not a reuse of group_tooltip_panel: for a
# group resource the composition of the group and the list of the consumers are
# two different facts, and a row can need both at once.
var consumption_tooltip_panel: Panel
var consumption_tooltip_content: VBoxContainer

var progress_tooltip_panel: Panel
var progress_tooltip_label: Label

# The tooltip for the breakdown of a storage by quality
var quality_tooltip_panel: Panel
var quality_tooltip_vbox: VBoxContainer

# The details tooltip of the selected building (the "Buildings" tab): rich
# content (the cost, the slots, the recipes), assembled in buildings_tab.
var detail_tooltip_panel: Panel
var detail_tooltip_content: VBoxContainer
var detail_tooltip_scroll: ScrollContainer

# The tooltip of the buttons of the list of the built buildings: the states with
# a colour coding (the plain tooltip_text does not support the colours). The
# content is assembled by buildings_tab.
var built_tooltip_panel: Panel
var built_tooltip_content: VBoxContainer

# The "Sources of the income/expense" tooltip on the "Resources" tab
var flow_tooltip_panel: Panel
var flow_tooltip_vbox: VBoxContainer
var flow_tooltip_scroll: ScrollContainer

# The tooltip of the breakdown of the treasury by the sources of the
# income/expense (the HUD of the map and the top bar of the city interface): it
# shows the balance, the planned rate of the income (by the sources of the
# internal market) and the actual expenses over the last display window
# (scouting, development of the chunks).
var treasury_tooltip_panel: Panel
var treasury_tooltip_vbox: VBoxContainer
var treasury_tooltip_scroll: ScrollContainer

# The height limit of the "rich" tooltips (the details of a building, the flows of
# the resources on the "Resources" tab): the content taller than
# DETAIL_TOOLTIP_MAX_ROWS rows (ROW_HEIGHT px each) is cut off, and a vertical
# scrollbar appears inside.
const DETAIL_TOOLTIP_MAX_ROWS: int = 15
const DETAIL_TOOLTIP_ROW_HEIGHT: float = 24.0
const DETAIL_TOOLTIP_SCROLLBAR_WIDTH: float = 14.0

# The colour of the money in the tooltips: the row "Base price: N" and the tails of the
# rows of the price ladder by quality ("= x1.30 = 5"). A single accessor, so that the
# price in a row tooltip is of one shade everywhere, while the stars still keep the
# colour of THEIR level (data/qualities.json) — the colour does not replace the money.
static func price_text_color() -> Color:
    return UI_THEME.color("price")

# The icon that marks a sum of coins in a line of text. It follows the number —
# "130 [icon]/sec" — because the number alone does not say what it counts, and the word
# "coins" does not fit into a narrow column of a card. The icon is the same everywhere:
# the treasury of the city and of a town, the income, the price, the cost of a deal.
const COIN_ICON := "coin_stack.png"
const COIN_ICON_PATH := "res://icons/coin_stack.png"
# The height of the icon in a line of the body font. It is a little lower than the font
# size, so that a line with a sum in it keeps the height of a line without one.
const COIN_ICON_SIZE := 28

# The BBCode of the coin icon for a RichTextLabel. The registry is asked first, so that
# the icon moves and gets renamed together with the rest of the icons; the constant path
# is the fallback for a run without the autoloads in the tree (a headless --script run).
static func coin_icon(size: int = COIN_ICON_SIZE) -> String:
    var path := COIN_ICON_PATH
    var tree := Engine.get_main_loop() as SceneTree
    if tree != null and tree.root != null:
        var registry := tree.root.get_node_or_null("IconRegistry")
        if registry != null:
            var registered: String = registry.icon_path(COIN_ICON)
            if not registered.is_empty():
                path = registered
    return "[img=%d]%s[/img]" % [size, path]

# A sum of coins: "500 [icon]".
static func money(amount_text: String, size: int = COIN_ICON_SIZE) -> String:
    return "%s%s" % [amount_text, coin_icon(size)]

# A rate of coins: "500 [icon]/sec". The unit stays glued to the icon, and the whole
# string is translated at once, so that a language can put the unit elsewhere.
static func money_rate(amount_text: String, size: int = COIN_ICON_SIZE) -> String:
    return TranslationServer.translate("%s%s/sec") % [amount_text, coin_icon(size)]

# A label that can hold a sum of coins: BBCode is rendered by a RichTextLabel only.
# The settings are the ones an inline icon needs — the content is fitted and does not
# scroll, and the line does not wrap (a wrapping RichTextLabel reports a 1 px minimum
# width to its container, and the row it sits in collapses).
static func make_money_label() -> RichTextLabel:
    var label := RichTextLabel.new()
    label.bbcode_enabled = true
    label.fit_content = true
    label.scroll_active = false
    label.autowrap_mode = TextServer.AUTOWRAP_OFF
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return label

# --- The saves -------------------------------------------------------------------
#
# The description of a saved game in the two forms the interface needs: a line for the
# list of the saves and a block for the tooltip of "Continue game". Both live here so
# that the list and the tooltip cannot describe one save differently.

# The moment of a save as the player reads it: "21.10.2026 12:03". The moment is stored
# as UTC; the player thinks in the time of their own clock.
static func save_date(unix_time: int) -> String:
    var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
    var date := Time.get_datetime_dict_from_unix_time(unix_time + bias)
    return "%02d.%02d.%04d %02d:%02d" % [
        int(date["day"]), int(date["month"]), int(date["year"]),
        int(date["hour"]), int(date["minute"])]

# The name of the era of a save; empty for an index the data does not know.
static func save_era(era_index: int) -> String:
    if era_index < 0 or era_index >= GameData.eras.size():
        return ""
    return str(GameData.eras[era_index].get("name", ""))

# The second line of a row in the list of the saves: what tells two saves of one city apart.
static func save_details(meta: Dictionary) -> String:
    var parts: Array = []
    var city := str(meta.get("city_name", ""))
    if not city.is_empty():
        parts.append(city)
    var era := save_era(int(meta.get("era_index", 0)))
    if not era.is_empty():
        parts.append(era)
    parts.append(save_date(int(meta.get("saved_at", 0))))
    return " · ".join(parts)

# The tooltip of "Continue game": the save the button will load, fact by fact.
static func save_tooltip(meta: Dictionary) -> String:
    if meta.is_empty():
        return ""
    var lines: Array = [str(meta.get("name", ""))]
    var city := str(meta.get("city_name", ""))
    if not city.is_empty():
        lines.append(TranslationServer.translate("City: %s") % city)
    var era := save_era(int(meta.get("era_index", 0)))
    if not era.is_empty():
        lines.append(TranslationServer.translate("Era: %s") % era)
    lines.append(TranslationServer.translate("Population: %d") % int(meta.get("population", 0)))
    # The mods belong to the save, not to the game: a slot may run a completely
    # different set, and the player must see which one a click will start.
    var mods: Array = meta.get("mods", [])
    if not mods.is_empty():
        lines.append(TranslationServer.translate("Mods: %s") % ", ".join(PackedStringArray(mods)))
    lines.append(TranslationServer.translate("Saved: %s") % save_date(int(meta.get("saved_at", 0))))
    return "\n".join(lines)

# The colour of the quality marker at the start of the quality label (the "Resources"
# tab and the cards of the "Trade"). It lives here next to price_text_color(), because
# both of them are elements of the FORMATTING shared by several tabs, and they cannot
# be split into two files: a divergence of the colours between the tabs is visible at
# once.
static func quality_marker_color() -> Color:
    return UI_THEME.color("quality")

# The colours of the name of a category header and of the side lines around it. The
# header is shared formatting of the resource lists (the "Resources" tab of the city
# and the trade window of a town), so it lives here next to the other shared colours.
static func category_header_name_color() -> Color:
    return UI_THEME.color("text_secondary")

static func category_header_line_color() -> Color:
    return UI_THEME.color("hairline")

# The markers of a category header and of its name label. The header is a composite
# row (a line, the name, a line), so its parts cannot be told apart by the node type;
# these markers are the contract for reading the layout back (see the tests).
const META_CATEGORY_HEADER := "category_header"
const META_CATEGORY_NAME := "category_name"

# The highlight of the active button of a toggle group. The groups of the interface that
# switch a view (the tab bar of the city, the sections of the foreign trade) must look alike,
# so both of them take the colours from here: a divergence of two copies of these rules is
# visible at once.
static func highlight_toggle_button(button: Button, active: bool) -> void:
    if button == null or not is_instance_valid(button):
        return
    # The accent family paints every state of the button and overrides the project theme:
    # the theme answers a hover with a plain control plate, so an active button would lose
    # its mark exactly while the cursor is over it.
    if active:
        var lifted := UI_THEME.color("accent_hover")
        # A held button keeps the hover colour — the accent has no fourth state of its own.
        _set_toggle_states(button, UI_THEME.color("accent"), lifted, lifted)
    else:
        # A hint of the accent, dimmed: the inactive buttons of one group still read as a
        # family with the active one, and a hover deepens that hint instead of jumping to
        # the generic control colours.
        var hint := UI_THEME.color("accent").darkened(0.4)
        _set_toggle_states(button, _faded(hint, 0.3), _faded(hint, 0.45), _faded(hint, 0.6))
    var caption := UI_THEME.color("accent_text") if active else UI_THEME.color("text")
    for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
        button.add_theme_color_override(state, caption)

static func _set_toggle_states(button: Button, normal: Color, hover: Color, pressed: Color) -> void:
    button.add_theme_stylebox_override("normal", _toggle_style(normal))
    button.add_theme_stylebox_override("hover", _toggle_style(hover))
    button.add_theme_stylebox_override("pressed", _toggle_style(pressed))

static func _toggle_style(bg: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    return style

static func _faded(color: Color, alpha: float) -> Color:
    var tint := color
    tint.a = alpha
    return tint

# The header of a category group in a resource list: a solid line, the name centred,
# a line again. The lines are stretched nodes that reach both edges of the column at
# any width — unlike a run of dashes, and the default font has no box-drawing U+2500
# to build a continuous line out of.
static func build_category_header(category_name: String) -> HBoxContainer:
    var header := HBoxContainer.new()
    header.add_theme_constant_override("separation", 6)
    header.set_meta(META_CATEGORY_HEADER, true)
    header.add_child(_make_category_line())
    var name_label := Label.new()
    name_label.text = category_name
    name_label.add_theme_color_override("font_color", category_header_name_color())
    name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    name_label.set_meta(META_CATEGORY_NAME, true)
    header.add_child(name_label)
    header.add_child(_make_category_line())
    return header

# One side of a category header. A rectangle, not a glyph: a stretched node is the
# only thing that can touch the column edge exactly at any width.
static func _make_category_line() -> ColorRect:
    var line := ColorRect.new()
    line.color = category_header_line_color()
    line.custom_minimum_size = Vector2(0, hairline_thickness())
    line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    line.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return line

# The thickness of a hairline — a category line, a separator — in the units of the canvas it
# is laid out in.
#
# The interface is drawn on a canvas of a fixed height (768) that the engine stretches to the
# window, so one canvas unit is not one screen pixel: a one-unit rect covers one or two screen
# rows depending on where it happens to land, and the very same separator then reads thicker in
# one place of the list than in another. A rect of 1 / scale screen pixels covers exactly one
# row everywhere, whatever the stretch is.
#
# The value never exceeds one canvas unit: a hairline must not grow thicker than the canvas
# pixel it is measured in, and on a canvas that is DOWNSCALED a one-unit line already thins out
# by itself.
#
# along_x — the hairline runs vertically, so its thickness lies along the X axis. The two axes
# are stretched by slightly different factors when the window does not divide evenly into the
# canvas, and a thickness taken from the wrong axis overshoots a pixel by a fraction — enough to
# cover two screen columns instead of one.
static func hairline_thickness(along_x: bool = false) -> float:
    return hairline_thickness_for(device_scale(along_x))

# The rule above for a known stretch — the pure form, so that it can be checked without a window.
static func hairline_thickness_for(scale: float) -> float:
    return 1.0 if scale <= 1.0 else 1.0 / scale

# The scale the canvas is drawn at along one axis: how many screen pixels one canvas unit covers
# (see Viewport.get_final_transform). A viewport that is not attached to a window yet — a
# headless run with a stub window — reports 1.0, which keeps a hairline one canvas unit thick.
static func device_scale(along_x: bool = false) -> float:
    var tree := Engine.get_main_loop() as SceneTree
    if tree == null or tree.root == null:
        return 1.0
    var scale := tree.root.get_final_transform().get_scale()
    var value := scale.x if along_x else scale.y
    return value if value > 0.0 else 1.0

var message_label: Label

func setup(main_ui: Control, message_lbl: Label):
    message_label = message_lbl
    # The tooltip for the food switches
    tooltip_panel = Panel.new()
    tooltip_panel.visible = false
    tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main_ui.add_child(tooltip_panel)

    tooltip_label = Label.new()
    tooltip_label.text = tr("Toggle using this product as food")
    tooltip_label.add_theme_font_size_override("font_size", 14)
    tooltip_panel.add_child(tooltip_label)

    tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The tooltip for the "Build" button
    build_tooltip_panel = Panel.new()
    build_tooltip_panel.visible = false
    build_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main_ui.add_child(build_tooltip_panel)

    build_tooltip_label = Label.new()
    build_tooltip_label.add_theme_font_size_override("font_size", 14)
    build_tooltip_panel.add_child(build_tooltip_label)

    build_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The tooltip for the group resources
    group_tooltip_panel = Panel.new()
    group_tooltip_panel.visible = false
    group_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_panel.z_index = 1100 # On top of the details tooltip of a building
    main_ui.add_child(group_tooltip_panel)

    group_tooltip_content = VBoxContainer.new()
    group_tooltip_content.add_theme_constant_override("separation", 4)
    group_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_panel.add_child(group_tooltip_content)

    group_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The tooltip "who consumes the resource" of the rows drawn with the
    # consumption underline (see make_resource_entry). It lives on the same layer
    # as the group tooltip: the two of them never describe the same fact at once,
    # and a higher z_index would only cover the details tooltip of a building.
    consumption_tooltip_panel = Panel.new()
    consumption_tooltip_panel.visible = false
    consumption_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    consumption_tooltip_panel.z_index = 1100
    main_ui.add_child(consumption_tooltip_panel)

    consumption_tooltip_content = VBoxContainer.new()
    consumption_tooltip_content.add_theme_constant_override("separation", 4)
    consumption_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    consumption_tooltip_panel.add_child(consumption_tooltip_content)

    consumption_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The tooltip for the progress bars of the buildings under construction
    progress_tooltip_panel = Panel.new()
    progress_tooltip_panel.visible = false
    progress_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    progress_tooltip_panel.z_index = 1000 # On top of all the other elements
    main_ui.add_child(progress_tooltip_panel)

    progress_tooltip_label = Label.new()
    progress_tooltip_label.add_theme_font_size_override("font_size", 14)
    progress_tooltip_panel.add_child(progress_tooltip_label)

    progress_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The tooltip for the breakdown of a storage by quality
    quality_tooltip_panel = Panel.new()
    quality_tooltip_panel.visible = false
    quality_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    quality_tooltip_panel.z_index = 1000
    main_ui.add_child(quality_tooltip_panel)

    quality_tooltip_vbox = VBoxContainer.new()
    quality_tooltip_vbox.add_theme_constant_override("separation", 4)
    quality_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    quality_tooltip_panel.add_child(quality_tooltip_vbox)

    quality_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The "Sources of the income/expense of a resource" tooltip (the "Resources" tab)
    flow_tooltip_panel = Panel.new()
    flow_tooltip_panel.visible = false
    flow_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_panel.z_index = 1000
    main_ui.add_child(flow_tooltip_panel)

    # The scroll container: it limits the height of the tooltip and shows a
    # vertical scrollbar when there are too many sources of the income/expense.
    flow_tooltip_vbox = VBoxContainer.new()
    flow_tooltip_vbox.add_theme_constant_override("separation", 4)
    flow_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    flow_tooltip_scroll = ScrollContainer.new()
    flow_tooltip_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    flow_tooltip_scroll.offset_left = 6
    flow_tooltip_scroll.offset_top = 4
    flow_tooltip_scroll.offset_right = -6
    flow_tooltip_scroll.offset_bottom = -4
    flow_tooltip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    flow_tooltip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    flow_tooltip_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    flow_tooltip_panel.add_child(flow_tooltip_scroll)
    flow_tooltip_scroll.add_child(flow_tooltip_vbox)

    flow_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The tooltip of the breakdown of the treasury (by the sources of the
    # income/expense): one for both places (the HUD of the map and the top bar of
    # the CityUI) — the structure is the same.
    treasury_tooltip_panel = Panel.new()
    treasury_tooltip_panel.visible = false
    treasury_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    treasury_tooltip_panel.z_index = 1000
    main_ui.add_child(treasury_tooltip_panel)

    # The scroll container: it limits the height of the tooltip and shows a
    # vertical scrollbar when there are too many sources of the income/expense
    # (as in flow_tooltip).
    treasury_tooltip_vbox = VBoxContainer.new()
    treasury_tooltip_vbox.add_theme_constant_override("separation", 4)
    treasury_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    treasury_tooltip_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    treasury_tooltip_scroll = ScrollContainer.new()
    treasury_tooltip_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    treasury_tooltip_scroll.offset_left = 6
    treasury_tooltip_scroll.offset_top = 4
    treasury_tooltip_scroll.offset_right = -6
    treasury_tooltip_scroll.offset_bottom = -4
    treasury_tooltip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    treasury_tooltip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    treasury_tooltip_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    treasury_tooltip_panel.add_child(treasury_tooltip_scroll)
    treasury_tooltip_scroll.add_child(treasury_tooltip_vbox)

    treasury_tooltip_panel.theme_type_variation = &"SurfaceTooltip"
    # The details tooltip of the selected building (the "Buildings" tab).
    detail_tooltip_panel = Panel.new()
    detail_tooltip_panel.visible = false
    detail_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_STOP
    detail_tooltip_panel.z_index = 1000
    main_ui.add_child(detail_tooltip_panel)

    # The scroll container: it limits the height of the tooltip to 15 rows; with a
    # long list of the recipes a vertical scrollbar appears inside.
    detail_tooltip_content = VBoxContainer.new()
    detail_tooltip_content.add_theme_constant_override("separation", 4)
    detail_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    detail_tooltip_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    detail_tooltip_scroll = ScrollContainer.new()
    detail_tooltip_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    detail_tooltip_scroll.offset_left = 6
    detail_tooltip_scroll.offset_top = 4
    detail_tooltip_scroll.offset_right = -6
    detail_tooltip_scroll.offset_bottom = -4
    detail_tooltip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    detail_tooltip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    detail_tooltip_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    detail_tooltip_panel.add_child(detail_tooltip_scroll)
    detail_tooltip_scroll.add_child(detail_tooltip_content)

    detail_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

    # The tooltip of the buttons of the list of the built buildings. mouse_filter
    # IGNORE — the tooltip is "transparent" for the hover/clicks (as
    # upgrade_tooltip_panel in building_panel.gd): the list of the buttons under it
    # stays clickable, and moving the cursor to a neighbouring button smoothly
    # switches the tooltip.
    built_tooltip_panel = Panel.new()
    built_tooltip_panel.visible = false
    built_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    built_tooltip_panel.z_index = 1000
    main_ui.add_child(built_tooltip_panel)

    built_tooltip_content = VBoxContainer.new()
    built_tooltip_content.add_theme_constant_override("separation", 4)
    built_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    built_tooltip_panel.add_child(built_tooltip_content)

    built_tooltip_panel.theme_type_variation = &"SurfaceTooltip"

func show_food_tooltip(mouse_pos: Vector2):
    tooltip_panel.position = mouse_pos + Vector2(15, 15)
    var text_size = tooltip_label.get_minimum_size()
    tooltip_panel.size = text_size + Vector2(12, 8)
    tooltip_label.position = Vector2(6, 4)

func show_build_tooltip(mouse_pos: Vector2):
    build_tooltip_panel.position = mouse_pos + Vector2(15, 15)
    var text_size = build_tooltip_label.get_minimum_size()
    build_tooltip_panel.size = text_size + Vector2(12, 8)
    build_tooltip_label.position = Vector2(6, 4)

    # If the tooltip goes beyond the edges of the screen — we draw it on the other
    # side of the cursor (similarly to the tooltips on the map in InputHandler.gd)
    var viewport_size = get_viewport().get_visible_rect().size
    if build_tooltip_panel.position.y + build_tooltip_panel.size.y > viewport_size.y:
        build_tooltip_panel.position.y = mouse_pos.y - build_tooltip_panel.size.y - 15
    if build_tooltip_panel.position.x + build_tooltip_panel.size.x > viewport_size.x:
        build_tooltip_panel.position.x = mouse_pos.x - build_tooltip_panel.size.x - 15
    build_tooltip_panel.position.x = max(0, build_tooltip_panel.position.x)
    build_tooltip_panel.position.y = max(0, build_tooltip_panel.position.y)

func show_group_tooltip(mouse_pos: Vector2, group_key: String, products_data: Dictionary,
        city_storage: Dictionary = {}, city_quality_detail: Dictionary = {}):
    # We clear the previous content (remove_child + queue_free, so that the nodes
    # are removed from the tree at once and do not affect the calculation of the
    # size)
    for child in group_tooltip_content.get_children():
        group_tooltip_content.remove_child(child)
        child.queue_free()
    
    var group_clean = group_key.trim_prefix("@")
    var member_ids = GameData.product_groups.get(group_clean, [])
    var group_name = GameData.get_product_group_name(group_key)
    
    # The header
    var title = Label.new()
    title.text = group_name
    title.add_theme_font_size_override("font_size", 16)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_content.add_child(title)
    
    # The list of the products (by the ID, so that the data of the product can be
    # found).
    # We assemble the names separately, in order to align the special_yield to the
    # column of the longest name of a resource.
    var product_labels: Array = []
    for prod_id in member_ids:
        var pdata = products_data.get(prod_id, {})
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 6)
        # The tooltip must not intercept the clicks, so that it is possible to
        # select the recipes in the production slots under it.
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        
        # The icon
        var icon_name = pdata.get("icon", "")
        if not icon_name.is_empty():
            var tex = IconRegistry.get_texture(icon_name)
            if tex:
                var icon_rect = TextureRect.new()
                icon_rect.texture = tex
                icon_rect.custom_minimum_size = Vector2(24, 24)
                icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
                row.add_child(icon_rect)
        
        var label = Label.new()
        var special_yield = pdata.get("special_yield", {})
        label.text = pdata.get("name", prod_id)
        label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(label)
        product_labels.append(label)

        # Price, quality and quantity for members that are actually on the city warehouse.
        # A member without stock is silent — the tooltip does not write "0 units" for it.
        if not city_storage.is_empty():
            var amount := int(GameData.get_storage_amount(prod_id, city_storage))
            if amount > 0:
                var price := GameData.get_price(prod_id)
                if price > 0:
                    var price_label = Label.new()
                    price_label.text = str(price)
                    price_label.add_theme_color_override("font_color", price_text_color())
                    price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                    row.add_child(price_label)

                # The best quality on the warehouse: levels are ordered worst → best,
                # the first level with count > 0 wins. The stock is summed by the level of the
                # good, so a row with an additional ingredient shows up on the ladder of the
                # level it has.
                var breakdown: Dictionary = city_quality_detail.get(prod_id, {})
                var totals: Dictionary = GameData.quality_level_totals(breakdown)
                var quality_id := ""
                for qid in GameData.get_quality_levels():
                    if int(totals.get(str(qid), 0)) > 0:
                        quality_id = str(qid)
                        break
                if not quality_id.is_empty():
                    var stars_label = Label.new()
                    stars_label.text = GameData.get_quality_stars(quality_id)
                    stars_label.add_theme_color_override("font_color",
                            GameData.get_quality_color(quality_id))
                    stars_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                    row.add_child(stars_label)

                var qty_label = Label.new()
                qty_label.text = tr("%d units") % amount
                qty_label.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
                qty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                row.add_child(qty_label)

        for yield_id in special_yield:
            var separator = Label.new()
            separator.text = " - "
            separator.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
            separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
            row.add_child(separator)

            var yield_data = products_data.get(yield_id, {})
            var yield_icon_name = yield_data.get("icon", "")
            if not yield_icon_name.is_empty():
                var yield_tex = IconRegistry.get_texture(yield_icon_name)
                if yield_tex:
                    var yield_icon_rect = TextureRect.new()
                    yield_icon_rect.texture = yield_tex
                    yield_icon_rect.custom_minimum_size = Vector2(20, 20)
                    yield_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                    yield_icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                    yield_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
                    row.add_child(yield_icon_rect)

            var yield_label = Label.new()
            yield_label.text = "%s: %d" % [
                yield_data.get("name", yield_id), int(special_yield[yield_id])]
            yield_label.add_theme_color_override("font_color", UI_THEME.color("warning"))
            yield_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            row.add_child(yield_label)
        
        group_tooltip_content.add_child(row)

    var max_product_name_width := 0.0
    for product_label in product_labels:
        max_product_name_width = maxf(
            max_product_name_width, product_label.get_minimum_size().x)
    for product_label in product_labels:
        product_label.custom_minimum_size.x = max_product_name_width
    
    # We explicitly recalculate the size of the panel for the content
    group_tooltip_content.reset_size()
    var content_min_size = group_tooltip_content.get_minimum_size()
    group_tooltip_panel.size = content_min_size + Vector2(12, 12)

    # We position the tooltip next to the cursor and shift it inside the screen if
    # the cursor is close to the right or the bottom edge.
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + group_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - group_tooltip_panel.size.x - 15
    if pos.y + group_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - group_tooltip_panel.size.y - 15
    pos.x = max(0, min(pos.x, viewport_size.x - group_tooltip_panel.size.x))
    pos.y = max(0, min(pos.y, viewport_size.y - group_tooltip_panel.size.y))
    group_tooltip_panel.position = pos
    group_tooltip_panel.show()

func hide_group_tooltip():
    group_tooltip_panel.hide()

# Shows the tooltip "who consumes this resource": the consumers of a resource that
# is marked with the consumption underline in make_resource_entry.
# The rows come from GameData.get_consumption_consumers — the reverse index of
# data/consumption.json (plus the legacy products[*].consumption), therefore the
# list cannot diverge from the mechanics: it is the same data that the write-off
# uses.
#
# The structure: the header with the name of the resource (and, for a group, the
# composition on the row below — a group reference stays readable without leaving
# the row), then one row per consumer:
#   "• All citizens: 10 ед./сек (no bonus)"
#   "• Fisherman: 1 ед./сек (+50% to production)"
# The rate is per one worker/citizen and is given by the same format as in the row
# of the expense of a profession (ConsumptionUi.format_rate_with_unit), so that the
# two places cannot show a different number for one and the same rule.
func show_consumption_tooltip(mouse_pos: Vector2, res_key: String, _products_data: Dictionary):
    if consumption_tooltip_panel == null:
        return
    # We clear the previous content (remove_child + queue_free — as in
    # show_group_tooltip, so that the size is recalculated correctly).
    for child in consumption_tooltip_content.get_children():
        consumption_tooltip_content.remove_child(child)
        child.queue_free()

    var consumers: Array = GameData.get_consumption_consumers(res_key)

    var title = Label.new()
    title.text = tr("Consumed by: %s") % GameData.format_resource_name(res_key)
    title.add_theme_font_size_override("font_size", 16)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    consumption_tooltip_content.add_child(title)

    # A group reference: the consumption refers to any member of the group, and the
    # player is told as much before reading the consumers — just as the row
    # "(group \"Fruits\")" does in show_flow_tooltip.
    if GameData.is_group_key(res_key):
        var note = Label.new()
        note.text = tr("Any product from the group")
        note.add_theme_font_size_override("font_size", 13)
        note.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
        note.mouse_filter = Control.MOUSE_FILTER_IGNORE
        consumption_tooltip_content.add_child(note)

    # The resource is named after one of its groups the rule speaks about: the row is
    # a concrete product, and without this line the player would not connect the
    # consumers below with the rule that spends the product.
    var groups_seen := {}
    for consumer in consumers:
        var via := str(consumer.get("via_group", ""))
        if via.is_empty() or groups_seen.has(via):
            continue
        groups_seen[via] = true
        var group_note = Label.new()
        group_note.text = tr("Consumed as part of the group \"%s\"") % GameData.format_resource_name(via)
        group_note.add_theme_font_size_override("font_size", 13)
        group_note.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
        group_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
        consumption_tooltip_content.add_child(group_note)

    for consumer in consumers:
        var amount := int(consumer.get("amount", 0))
        var interval := float(consumer.get("interval", 0))
        var bonus := float(consumer.get("production_bonus", 0.0))
        # The rate per one consumer: the same formula as in ConsumptionUi
        # (amount / interval; interval = 0 means "per tick", and a tick equals a
        # second).
        var per_sec := float(amount) if interval <= 0.0 else float(amount) / interval
        var row_text := "%s: %s" % [
            str(consumer.get("profession_name", "")),
            ConsumptionUi.format_rate_with_unit(per_sec)
        ]
        if bonus > 0.0:
            row_text += tr(" (+%d%% to production)") % int(round(bonus * 100.0))
        consumption_tooltip_content.add_child(
            _make_bullet_row("•", row_text, UI_THEME.color("text")))

    consumption_tooltip_content.reset_size()
    var content_min_size = consumption_tooltip_content.get_minimum_size()
    consumption_tooltip_panel.size = content_min_size + Vector2(12, 12)

    # We position the tooltip next to the cursor and shift it inside the screen if
    # the cursor is close to the right or the bottom edge.
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + consumption_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - consumption_tooltip_panel.size.x - 15
    if pos.y + consumption_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - consumption_tooltip_panel.size.y - 15
    pos.x = max(0, min(pos.x, viewport_size.x - consumption_tooltip_panel.size.x))
    pos.y = max(0, min(pos.y, viewport_size.y - consumption_tooltip_panel.size.y))
    consumption_tooltip_panel.position = pos
    consumption_tooltip_panel.show()

func hide_consumption_tooltip():
    if consumption_tooltip_panel != null:
        consumption_tooltip_panel.hide()

# Builds the row "icon + name" for a resource/product of a recipe or of a
# construction cost. For the group keys (@...) it automatically attaches a
# tooltip with the composition of the group (it reveals which products are part
# of the group) — by analogy with the recipes and the window of the production
# slots.
#   products_data — the dictionary {id: {name, icon}} (the products + the raw
#                   materials).
#   amount        — if > 0, the amount is added after the name.
#   amount_style  — "x" → "Name xN", "colon" → "Name: N", otherwise no amount.
#   icon_size     — the size of the icon in pixels.
#   show_consumers — mark the row when the resource is consumed by a profession
#                   (an entry of data/consumption.json or of the legacy
#                   products[*].consumption): the name is underlined with a finer
#                   line and a tooltip lists the consumers. The flag is opt-in,
#                   because in most places the row is a cost or an ingredient,
#                   and there the consumption of a profession is not what the
#                   player reads the row for.
# The icons are taken from the IconRegistry — the icon registry of the project is
# a shared one (autoload); before, the dictionary with the paths had to be passed
# here as an argument from every module, and eight different modules were building
# a copy of it.
# Returns an HBoxContainer, which can be added to the containers of the lists.
func make_resource_entry(res_id: String, products_data: Dictionary, amount: int = -1, amount_style: String = "x", icon_size: int = 20, show_consumers: bool = false) -> HBoxContainer:
    var entry = HBoxContainer.new()
    entry.add_theme_constant_override("separation", 4)
    entry.mouse_filter = Control.MOUSE_FILTER_IGNORE

    # The icon (only for the single resources, a group has no image of its own)
    var pdata = products_data.get(res_id, {})
    var icon_name = pdata.get("icon", "")
    if not icon_name.is_empty():
        var tex = IconRegistry.get_texture(icon_name)
        if tex:
            var icon_rect = TextureRect.new()
            icon_rect.texture = tex
            icon_rect.custom_minimum_size = Vector2(icon_size, icon_size)
            icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
            icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
            entry.add_child(icon_rect)

    # Whether a profession spends this resource. It is asked for a single product
    # ("feathers") and for a group ("@boats") alike — the display_key is the key of
    # both the registry and the group reference.
    var consumers: Array = []
    if show_consumers:
        consumers = GameData.get_consumption_consumers(res_id)
    var is_group := GameData.is_group_key(res_id)

    if is_group:
        # A group resource — we format it as a "link": an underlined name (in a
        # light blue colour), in order to attract the attention of the player to
        # the row.
        # Only the name of the group is underlined, the amount is in a normal
        # typeface.
        # On hover a tooltip with the composition of the group is shown, but the
        # clicks are NOT intercepted (MOUSE_FILTER_PASS) — the button of the
        # recipe/slot works.
        var group_name := GameData.format_resource_name(res_id)
        var amount_text := ""
        if amount > 0:
            if amount_style == "colon":
                amount_text = ": %d" % amount
            else:
                amount_text = " x%d" % amount

        # We connect the UnderlinedLabel through load(): a class_name may not be
        # registered in the cache of the global classes yet (for example, in the
        # headless tests via --script), and load is reliable in any mode.
        var link_label = load("res://scripts/underlined_label.gd").new()
        link_label.text = "%s%s" % [group_name, amount_text]
        link_label.underline_text = group_name
        if not consumers.is_empty():
            # The group IS consumed: the finer underline marks the expense, and if
            # the group is built from several resources the product group is split
            # only for the chosen member — no single member is marked here.
            link_label.dot_style = true
        link_label.mouse_filter = Control.MOUSE_FILTER_PASS
        if not consumers.is_empty():
            link_label.mouse_entered.connect(_on_resource_consumption_hover.bind(
                link_label, res_id, products_data))
        else:
            link_label.mouse_entered.connect(_on_resource_group_hover.bind(
                link_label, res_id, products_data))
        link_label.mouse_exited.connect(_on_resource_entry_exit)
        entry.add_child(link_label)
        return entry

    var text := GameData.format_resource_name(res_id)
    if amount > 0:
        if amount_style == "colon":
            text = "%s: %d" % [text, amount]
        else:
            text = "%s x%d" % [text, amount]

    if consumers.is_empty():
        var label = Label.new()
        label.text = text
        entry.add_child(label)
        return entry

    # A single resource spent by a profession: the same underline, but finer than
    # the one of a group reference, and the consumers are shown on hover.
    var consumed_label = load("res://scripts/underlined_label.gd").new()
    consumed_label.text = text
    consumed_label.underline_text = GameData.format_resource_name(res_id)
    consumed_label.dot_style = true
    consumed_label.mouse_filter = Control.MOUSE_FILTER_PASS
    consumed_label.mouse_entered.connect(_on_resource_consumption_hover.bind(
        consumed_label, res_id, products_data))
    consumed_label.mouse_exited.connect(_on_resource_entry_exit)
    entry.add_child(consumed_label)
    return entry

# Shows the tooltip with the composition of the group on hovering the row of a
# resource
func _on_resource_group_hover(_control: Control, res_id: String, products_data: Dictionary):
    show_group_tooltip(get_viewport().get_mouse_position(), res_id, products_data)

# Shows the tooltip with the consumers of the resource on hovering a row marked
# with the consumption underline.
func _on_resource_consumption_hover(_control: Control, res_id: String, products_data: Dictionary):
    show_consumption_tooltip(get_viewport().get_mouse_position(), res_id, products_data)

# Hides the hover tooltips of a resource row when the cursor is moved away
func _on_resource_entry_exit():
    hide_group_tooltip()
    hide_consumption_tooltip()

func show_progress_tooltip(mouse_pos: Vector2):
    progress_tooltip_panel.position = mouse_pos + Vector2(15, 15)
    var text_size = progress_tooltip_label.get_minimum_size()
    progress_tooltip_panel.size = text_size + Vector2(12, 8)
    progress_tooltip_label.position = Vector2(6, 4)

    # If the tooltip goes beyond the edges of the screen — we draw it on the other
    # side of the cursor
    var viewport_size = get_viewport().get_visible_rect().size
    if progress_tooltip_panel.position.y + progress_tooltip_panel.size.y > viewport_size.y:
        progress_tooltip_panel.position.y = mouse_pos.y - progress_tooltip_panel.size.y - 15
    if progress_tooltip_panel.position.x + progress_tooltip_panel.size.x > viewport_size.x:
        progress_tooltip_panel.position.x = mouse_pos.x - progress_tooltip_panel.size.x - 15
    progress_tooltip_panel.position.x = max(0, progress_tooltip_panel.position.x)
    progress_tooltip_panel.position.y = max(0, progress_tooltip_panel.position.y)

func hide_progress_tooltip():
    progress_tooltip_panel.hide()

# Shows the tooltip with the breakdown of a product by the levels of quality.
# quality_breakdown — the dictionary {quality_id: count}, for example
# {"common": 50, "fine": 30}.
# There are deliberately no prices here: every level has its own price, and a
# full list of the prices would take as much space as the tooltip itself (the
# price ladder lives in the row tooltip — see show_flow_tooltip). Here there is
# only the composition of the storage: how many units of which quality, and which
# share of each level.
func show_quality_tooltip(mouse_pos: Vector2, prod_name: String, quality_breakdown: Dictionary):
    # We clear the content
    for child in quality_tooltip_vbox.get_children():
        quality_tooltip_vbox.remove_child(child)
        child.queue_free()

    var header = Label.new()
    header.text = tr("Resource quality levels: %s") % prod_name
    header.add_theme_font_size_override("font_size", 15)
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    quality_tooltip_vbox.add_child(header)

    var levels = GameData.get_quality_levels()
    # The stock is summed by the level of the good itself: a row with an additional ingredient
    # carries two levels, and the player reads the storage by the level of the good
    # (GameData.quality_level_totals).
    var totals: Dictionary = GameData.quality_level_totals(quality_breakdown)
    # We output the levels from the worst to the best (as in data/qualities.json).
    for qid in levels:
        var count = int(totals.get(qid, 0))
        if count <= 0:
            continue
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 6)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE

        # The stars — in the colour of the level (data/qualities.json, color), so
        # that the level is read by its colour just like the price ladder in the
        # row tooltip.
        var stars_label = Label.new()
        stars_label.text = GameData.get_quality_stars(qid)
        stars_label.add_theme_color_override("font_color", GameData.get_quality_color(str(qid)))
        stars_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(stars_label)

        # The amount and the share of the level in the storage. The share — of the total
        # amount of the product, therefore the row is read as "how much of the
        # storage is good".
        var name_label = Label.new()
        name_label.text = "%s: %d (%d%%)" % [
            GameData.get_quality_name(qid), count,
            GameData.get_quality_share_percent(count, totals)
        ]
        name_label.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
        name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(name_label)

        quality_tooltip_vbox.add_child(row)

    quality_tooltip_vbox.reset_size()
    var content_size = quality_tooltip_vbox.get_minimum_size()
    quality_tooltip_panel.size = content_size + Vector2(12, 12)
    quality_tooltip_panel.position = mouse_pos + Vector2(15, 15)
    quality_tooltip_panel.show()

func hide_quality_tooltip():
    quality_tooltip_panel.hide()

func show_building_detail_tooltip(mouse_pos: Vector2):
    if detail_tooltip_panel == null:
        return
    # We reset the size of the panel, so that the reset_size() below takes the
    # actual minimum width of the content (otherwise the panel could stay the
    # previous one).
    detail_tooltip_panel.size = Vector2.ZERO
    # We recalculate the size of the panel for the assembled content.
    detail_tooltip_content.reset_size()
    var content_min_size = detail_tooltip_content.get_minimum_size()
    # The indents from the edge of the panel to the text: 6 on the left/right, 4
    # at the top/bottom — they are set by the anchors of the ScrollContainer
    # (PRESET_FULL_RECT + offset_*), therefore there is no need to position the
    # vbox by hand.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    # We limit the height: no more than DETAIL_TOOLTIP_MAX_ROWS rows. On overflow
    # the ScrollContainer shows a vertical scrollbar, for which we reserve the
    # width, so that the content does not shrink.
    var max_content_height = DETAIL_TOOLTIP_MAX_ROWS * DETAIL_TOOLTIP_ROW_HEIGHT
    var content_height = min(content_min_size.y, max_content_height)
    var scrollbar_width = 0.0
    if content_min_size.y > max_content_height:
        scrollbar_width = DETAIL_TOOLTIP_SCROLLBAR_WIDTH
    detail_tooltip_panel.size = Vector2(
        content_min_size.x + scrollbar_width + pad_left + pad_right,
        content_height + pad_top + pad_bottom
    )
    # The tooltip has just been shown — the scroll to the top (between different
    # buildings the content is rebuilt entirely in buildings_tab).
    if not detail_tooltip_panel.visible:
        detail_tooltip_scroll.scroll_vertical = 0
    # If the tooltip goes beyond the edges of the screen — we draw it on the other
    # side of the cursor.
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + detail_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - detail_tooltip_panel.size.x - 15
    if pos.y + detail_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - detail_tooltip_panel.size.y - 15
    # We clamp the tooltip inside the screen completely: after the shift upwards a
    # tall tooltip must not go past the top edge (as in built_tooltip).
    pos.x = max(0.0, min(pos.x, maxf(0.0, viewport_size.x - detail_tooltip_panel.size.x)))
    pos.y = max(0.0, min(pos.y, maxf(0.0, viewport_size.y - detail_tooltip_panel.size.y)))
    detail_tooltip_panel.position = pos
    detail_tooltip_panel.show()

func hide_building_detail_tooltip():
    if detail_tooltip_panel:
        detail_tooltip_panel.hide()

# Shows the tooltip of a built building at the point pos (usually under the button
# of the list), with a shift inside the screen at the edges. The content is filled
# by buildings_tab in _fill_built_tooltip() before the call.
func show_built_tooltip(pos: Vector2):
    if built_tooltip_panel == null:
        return
    built_tooltip_content.reset_size()
    var content_min_size = built_tooltip_content.get_minimum_size()
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    built_tooltip_content.position = Vector2(pad_left, pad_top)
    built_tooltip_panel.size = content_min_size + Vector2(pad_left + pad_right, pad_top + pad_bottom)
    var viewport_size = get_viewport().get_visible_rect().size
    pos.x = max(0.0, min(pos.x, viewport_size.x - built_tooltip_panel.size.x))
    pos.y = max(0.0, min(pos.y, viewport_size.y - built_tooltip_panel.size.y))
    built_tooltip_panel.position = pos
    built_tooltip_panel.show()

func hide_built_tooltip():
    if built_tooltip_panel:
        built_tooltip_panel.hide()

# Creates a row of the tooltip "bullet + text". It is used in show_flow_tooltip and
# follows the same pattern as _make_bullet_row in buildings_tab.gd (the "Cost" and
# "Available recipes" blocks of the tooltip of a building).
# text_color — the colour of the text of the row; the bullet is drawn in a light
# grey, so that it stands out on the background of a coloured text (as in the
# tooltip of a building).
func _make_bullet_row(symbol: String, text: String, text_color: Color) -> HBoxContainer:
    var row = HBoxContainer.new()
    row.add_theme_constant_override("separation", 3)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var bullet = Label.new()
    bullet.text = symbol
    bullet.add_theme_color_override("font_color", UI_THEME.color("text"))
    bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(bullet)
    var label = Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 14)
    label.add_theme_color_override("font_color", text_color)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(label)
    return row

# Creates a row of the price ladder for the row tooltip: the stars of a quality level
# (data/qualities.json, get_quality_color) and the calculation behind them.
#   marker       — "★★" (the indent of 2 spaces is set here)
#   tail         — " = x1.30 = 5", the tail of the row without the marker
#   marker_color — the colour of the marker: the level colour from the data
# The stars are a Label, the tail is a RichTextLabel: the ladder row ends with the price of the
# level, and the coin icon after it needs BBCode. The tail is created by make_money_label, whose
# autowrap is off, so fit_content does not collapse it (see resources_tab._add_quality_label).
func _make_price_row(marker: String, tail: String, marker_color: Color) -> HBoxContainer:
    var row = HBoxContainer.new()
    row.add_theme_constant_override("separation", 4)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    # The indent of 2 spaces separates the rows of the ladder from the base
    # "Base price: N" above them.
    var marker_label = Label.new()
    marker_label.text = "  " + marker
    marker_label.add_theme_color_override("font_color", marker_color)
    marker_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(marker_label)
    var tail_label = make_money_label()
    tail_label.text = tail
    tail_label.add_theme_color_override("default_color", price_text_color())
    row.add_child(tail_label)
    return row

# Adds one row of the price build-up to the grid: the name of the stage with the stars of its level,
# the colon and the calculation. A grid, and not a row of boxes, because the build-up is read as a
# table: the names differ in length and the badges differ in width ("★", "★★★"), so in separate
# boxes the colons and the calculations would start in their own columns in every row.
# The name and the stars share one cell: the name stands at its left, the stars are right-aligned
# inside it, so every badge ends at the same edge and the colon stands right after the longest name
# rather than after a column as wide as the widest badge. The name of the stage is muted: the stage
# is named by the word, the level — by the colour of the stars, and the money must stay the
# brightest thing in the row. The calculation is a RichTextLabel: the total row carries the coin
# icon after the price, and only a RichTextLabel renders the icon tag.
func _add_price_grid_row(grid: GridContainer, label: String, marker: String, tail: String, marker_color: Color) -> void:
    var stage_cell = HBoxContainer.new()
    stage_cell.add_theme_constant_override("separation", 0)
    stage_cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    stage_cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var stage_label = Label.new()
    stage_label.text = "  " + label
    stage_label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    stage_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    stage_cell.add_child(stage_label)
    var marker_label = Label.new()
    marker_label.text = marker
    marker_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    marker_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    marker_label.add_theme_color_override("font_color", marker_color)
    marker_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    stage_cell.add_child(marker_label)
    grid.add_child(stage_cell)
    var colon_label = Label.new()
    colon_label.text = ":"
    colon_label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    colon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    grid.add_child(colon_label)
    var tail_label = make_money_label()
    tail_label.text = tail
    tail_label.add_theme_color_override("default_color", price_text_color())
    grid.add_child(tail_label)

# Separates the blocks of the build-up (one per quality key): without the gap the next block reads
# as a repetition of the previous one.
func _add_price_grid_gap(grid: GridContainer) -> void:
    for _i in range(grid.columns):
        var gap := Control.new()
        gap.custom_minimum_size.y = 6
        gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
        grid.add_child(gap)

# The name of a stage of the price build-up (see GameData.format_price_build_up_rows).
func _price_stage_label(kind: String) -> String:
    match kind:
        "quality":
            return tr("Quality")
        "additions":
            return tr("Addition")
        "synergy":
            return tr("Workmanship")
        "total":
            return tr("Total")
    return ""

# Formats a consumption interval for a tooltip: the whole seconds without a
# fractional part ("10 sec"), the fractional ones — with one digit ("0.5 sec").
func _format_interval(interval: float) -> String:
    if interval == floor(interval):
        return str(int(interval))
    return "%.1f" % interval

# Formats a rate (units/sec): the whole values without a fractional part, the
# fractional ones — with one digit ("0.5").
func _format_rate(value: float) -> String:
    if value == floor(value):
        return str(int(value))
    return "%.1f" % value

# The average rate of the record per second: amount × SIMULATION_TICK / interval
# for the cyclic records (the recipes of the buildings with their own time, the
# professions, "all the residents"); interval = 0 — "per tick" (the improvements),
# and a tick of the simulation equals SIMULATION_TICK sec, therefore it is
# amount × SIMULATION_TICK.
func _planned_per_sec(amount: float, interval: float) -> float:
    if interval > 0.0:
        return amount * CityData.SIMULATION_TICK / interval
    return amount * CityData.SIMULATION_TICK

# The textual representation of the planned rate for a tooltip. We keep the
# original pair "amount per interval" — that way the player sees exactly what is
# declared in the data (for example, "10 / 10 sec" for the professional
# consumption "10 units/10 sec"), and not a derived per_sec.
#
#   amount = 10, interval = 10 → "10 / 10 sec"   (the cyclic consumption)
#   amount = 5,  interval = 0  → "5 / sec"       (the continuous expense per tick)
#   amount = 0               → "0"
func _format_planned_rate(amount: float, interval: float) -> String:
    var amt_int := int(round(amount))
    if amt_int <= 0:
        return "0"
    if interval > 0.0:
        var iv := interval
        # A whole interval — without a fractional part.
        if abs(iv - round(iv)) < 0.001:
            return tr("%d / %d sec") % [amt_int, int(round(iv))]
        return tr("%d / %.1f sec") % [amt_int, iv]
    return tr("%d / sec") % amt_int

# Shows the tooltip "the sources of the planned income/expense" of a resource (the
# "Resources" tab).
# resource_id — the id of the resource/product: if it is given, its price at the ordinary
# quality level (GameData.get_price) is output at the top as "Base price: N" (a good with an
# addition — as "Base prices: good: X, addition: Y", see below), and under it —
# the price of the levels of quality that are REALLY in the storage (quality_breakdown), in the
# format "★★ = x1.30 = 5" (the rows with an indent of 2 spaces). The row of the
# ladder has two colours: the stars in the colour of their level
# (data/qualities.json), the price calculation — in the price colour of the palette
# (price_text_color(), as the row "Base price: N"). The base price and the price at the end of
# every ladder row carry the coin icon.
# An empty breakdown or a product without a price — there are no rows.
# quality_breakdown — the breakdown of the storage by quality
# ({quality_id: count}, see CityData.get_quality_breakdown). It is what decides
# which levels are shown: the price of a level that is not in the storage is not
# needed by the player and only misleads.
# A good with an additional ingredient ("Wool Clothes (+Woad)") gets the formula of its price
# instead of the ladder (GameData.format_price_build_up_rows) and a base line of both prices — "Base
# prices: good: 16, addition: 5" — one block of four aligned rows per quality key that lies in the
# storage:
#   Quality        ★★    : x1.30
#   Addition       ★★★   : x2.30
#   Workmanship          : x1.15
#   Total          ★★★   : (16 x 1.30 + 5 x 2.30) x 1.15 ≈ 37
# The prices of the base line and of the total row carry the coin icon; the coefficients do not.
# A fine garment with a common dye and the same garment with a fine dye are two different units at
# two different prices, and each gets its own block. The addition is a factor of its own: the price
# of the generated good already includes it, so the chain starts from the price of the plain base
# and from the price of the addition, and the blocks show how they add up.
# The tooltip is shown even when the production/consumption is empty, as long as
# the price of the resource is > 0.
# planned_consumption — the planned consumption:
# { source -> { amount, interval, count, is_group, group_name, is_population } }.
# The rows are shown as the pair "amount / interval sec" (see
# _format_planned_rate).
# The block "Consumption (planned):" is shown when there is a plan.
# planned_production — the planned production:
# { source -> { amount, interval, count } } — the output of the recipes of the
# buildings and of the cycles of the improvements; the format of the rows is the
# same.
# The block "Production (planned):" is shown when a producer exists, but it has
# produced nothing for a tick (for example, the furnace did not have enough wood).
# The order of the sections of the tooltip: the price / "Production (planned):" /
# "Consumption (planned):" / the footnote "≈".
func show_flow_tooltip(mouse_pos: Vector2, prod_name: String, special_yield: Dictionary = {}, resource_id: String = "", planned_consumption: Dictionary = {}, planned_production: Dictionary = {}, quality_breakdown: Dictionary = {}):
    if flow_tooltip_panel == null:
        return
    # We clear the previous content.
    for child in flow_tooltip_vbox.get_children():
        flow_tooltip_vbox.remove_child(child)
        child.queue_free()
    var price := 0.0
    if not resource_id.is_empty():
        price = GameData.get_price(resource_id)
    if special_yield.is_empty() and price <= 0.0 \
            and planned_consumption.is_empty() \
            and planned_production.is_empty():
        flow_tooltip_panel.hide()
        return
    var header = Label.new()
    header.text = prod_name
    header.add_theme_font_size_override("font_size", 15)
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_vbox.add_child(header)
    # The price of the resource at its ORDINARY level (taking the dynamic multipliers into
    # account). It is called the base price because it is what every stage below is counted from:
    # the units in the storage may all be of a better level and cost more (the rows below show how
    # much more), so a bare "Price" would be read as the price of what the player has.
    # A good with an addition has TWO base prices: the price of the plain good and the price of the
    # addition per unit of the result. The chain below starts from both, so the addition is not a
    # number out of nowhere in its formula.
    if price > 0.0:
        var parsed := GameData.parse_generated_id(resource_id)
        if parsed.is_empty():
            var price_label = make_money_label()
            price_label.text = tr("Base price: ") + money(GameData.format_coins(price))
            price_label.add_theme_color_override("default_color", price_text_color())
            flow_tooltip_vbox.add_child(price_label)
        else:
            # Both sums of the line carry the coin icon: the line names two prices at once, and
            # without it the player has to guess which numbers are coins and which are coefficients.
            var price_label = make_money_label()
            price_label.text = tr("Base prices: good: %s, addition: %s") % [
                money(GameData.format_coins(GameData.get_price(str(parsed["base"])))),
                money(GameData.format_coins(GameData.get_extra_base_price_part(
                        str(parsed["base"]), str(parsed["extra"])))),
            ]
            price_label.add_theme_color_override("default_color", price_text_color())
            flow_tooltip_vbox.add_child(price_label)
        # A good with an addition is explained by the ladder of its formula (see
        # GameData.format_price_build_up_rows): the coefficient of every factor of the price, and
        # the total row with the formula itself. A plain good has a single factor, and its ladder
        # row IS the price at that level.
        var build_up := GameData.format_price_build_up_rows(resource_id, quality_breakdown)
        if build_up.is_empty():
            # The prices by quality that are REALLY in the storage: the internal market
            # takes every unit at the price of ITS level, therefore under the base
            # price we show what a product of each quality from the breakdown of the
            # storage (quality_breakdown) costs — as a ladder from the worst level to
            # the best.
            # No row is created for the levels that are not in the storage: there is no
            # point in showing the price of a product that is not in the storage. A
            # product without a price (science) has no rows at all. Every row has two
            # colours: the stars — in the colour of THEIR level (data/qualities.json,
            # color), by them it is visible which quality is where even without reading
            # the text, and the price calculation itself ("= x1.75 = 7") — in gold,
            # just like the row "Base price: N" above the ladder.
            for quality_row in GameData.format_quality_price_scale_rows(resource_id, quality_breakdown):
                flow_tooltip_vbox.add_child(_make_price_row(
                    str(quality_row["stars"]), money(str(quality_row["tail"])),
                    GameData.get_quality_color(str(quality_row["qid"]))))
        else:
            var ladder := GridContainer.new()
            ladder.columns = 3
            ladder.add_theme_constant_override("h_separation", 6)
            ladder.add_theme_constant_override("v_separation", 0)
            ladder.mouse_filter = Control.MOUSE_FILTER_IGNORE
            for stage in build_up:
                if str(stage["kind"]) == "quality" and ladder.get_child_count() > 0:
                    _add_price_grid_gap(ladder)
                var stage_qid := str(stage["qid"])
                var stage_color: Color = price_text_color() if stage_qid.is_empty() \
                        else GameData.get_quality_color(stage_qid)
                var stage_tail := str(stage["tail"])
                # The total is the price the unit really costs: it is the only row of the
                # build-up that carries a sum of coins, so only it gets the coin icon.
                if str(stage["kind"]) == "total":
                    stage_tail = money(stage_tail)
                _add_price_grid_row(ladder, _price_stage_label(str(stage["kind"])),
                        str(stage["marker"]), stage_tail, stage_color)
            flow_tooltip_vbox.add_child(ladder)
    for yield_id in special_yield:
        var yield_label = Label.new()
        yield_label.text = "%s: %d" % [
            GameData.products.get(yield_id, {}).get("name", yield_id),
            int(special_yield[yield_id])
        ]
        yield_label.add_theme_color_override("font_color", quality_marker_color())
        yield_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(yield_label)
    # The planned production: what WILL be produced by the current producers (the
    # recipes of the buildings with a citizen + the improvements on the map). It is
    # shown also when there is no actual production for the tick — for example,
    # the furnace did not have enough wood, or the cycle of the production of an
    # improvement has not reached its output yet.
    # The rows show the pair "amount / interval" through _format_planned_rate: for
    # the interval records — "10 / 10 sec", for the continuous ones — "5 / sec".
    if not planned_production.is_empty():
        var planned_prod_title = Label.new()
        planned_prod_title.text = tr("Production (planned):")
        planned_prod_title.add_theme_font_size_override("font_size", 14)
        planned_prod_title.add_theme_color_override("font_color",
                UI_THEME.color("income").lightened(0.4))
        planned_prod_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(planned_prod_title)
        var planned_prod_lines: Array = []
        for src in planned_production:
            var e: Dictionary = planned_production[src]
            planned_prod_lines.append({
                "name": GameData.get_source_display_name(str(src)),
                "amount": int(e.get("amount", 0)),
                "count": int(e.get("count", 1)),
                "interval": float(e.get("interval", 0))
            })
        planned_prod_lines.sort_custom(func(a, b): return a.amount > b.amount)
        for row in planned_prod_lines:
            var line_text = str(row.name)
            if int(row.count) > 1:
                line_text += tr(" x%d") % int(row.count)
            line_text += ": %s" % _format_planned_rate(float(row.amount), float(row.interval))
            flow_tooltip_vbox.add_child(_make_bullet_row("•", line_text, UI_THEME.color("income")))
    # The planned consumption: who and how much WILL be written off the storage —
    # regardless of the phase of the consumption timers and of the fact of the last
    # tick.
    # The rows show the average expense PER SECOND ("units/sec"): interval > 0 —
    # the cyclic consumption (the professions, "all the residents", the recipes of
    # the buildings with their own `time`), interval = 0 — the demand of the
    # buildings for a tick. The group records apply to any member of the group and
    # are marked with its name.
    if not planned_consumption.is_empty():
        var planned_title = Label.new()
        planned_title.text = tr("Consumption (planned):")
        planned_title.add_theme_font_size_override("font_size", 14)
        planned_title.add_theme_color_override("font_color",
                UI_THEME.color("expense").lightened(0.35))
        planned_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(planned_title)
        var planned_lines: Array = []
        for src in planned_consumption:
            var e: Dictionary = planned_consumption[src]
            planned_lines.append({
                "name": GameData.get_source_display_name(str(src)),
                "amount": int(e.get("amount", 0)),
                "count": int(e.get("count", 1)),
                "interval": float(e.get("interval", 0)),
                "is_group": bool(e.get("is_group", false)),
                "group_name": str(e.get("group_name", "")),
                "is_population": bool(e.get("is_population", false))
            })
        planned_lines.sort_custom(func(a, b): return a.amount > b.amount)
        for row in planned_lines:
            var line_text = str(row.name)
            if bool(row.is_population):
                # The consumption of "all the residents": the multiplier of the
                # population — in the brackets.
                if int(row.count) > 1:
                    line_text += tr(" (%d people)") % int(row.count)
            elif int(row.count) > 1:
                line_text += tr(" x%d") % int(row.count)
            if bool(row.is_group) and not str(row.group_name).is_empty():
                line_text += tr(" (group \"%s\")") % str(row.group_name)
            line_text += ": %s" % _format_planned_rate(float(row.amount), float(row.interval))
            flow_tooltip_vbox.add_child(_make_bullet_row("•", line_text, UI_THEME.color("expense")))
    # The explanation of the marker "≈" in the dynamics of the "Resources" tab — for
    # both plans: the production and the consumption. It is shown for any non-empty
    # plan, regardless of which section of the plan has actually been drawn.
    if not planned_consumption.is_empty() or not planned_production.is_empty():
        var planned_note = Label.new()
        planned_note.text = tr("≈ in the live view — the planned value per second")
        planned_note.add_theme_font_size_override("font_size", 12)
        planned_note.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
        planned_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(planned_note)
    flow_tooltip_vbox.reset_size()
    var content_size = flow_tooltip_vbox.get_minimum_size()
    # The indents from the edge of the panel to the text: 6 on the left/right, 4
    # at the top/bottom — they are set by the anchors of the ScrollContainer
    # (PRESET_FULL_RECT + offset_*), therefore there is no need to position the
    # vbox by hand.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    # We limit the height: no more than DETAIL_TOOLTIP_MAX_ROWS rows. On overflow
    # the ScrollContainer shows a vertical scrollbar, for which we reserve the
    # width, so that the content does not shrink.
    var max_content_height = DETAIL_TOOLTIP_MAX_ROWS * DETAIL_TOOLTIP_ROW_HEIGHT
    var content_height = min(content_size.y, max_content_height)
    var scrollbar_width = 0.0
    if content_size.y > max_content_height:
        scrollbar_width = DETAIL_TOOLTIP_SCROLLBAR_WIDTH
    flow_tooltip_panel.size = Vector2(
        content_size.x + scrollbar_width + pad_left + pad_right,
        content_height + pad_top + pad_bottom
    )
    # The tooltip has just been shown — the scroll to the top (the content is
    # rebuilt from scratch on every showing).
    if not flow_tooltip_panel.visible:
        flow_tooltip_scroll.scroll_vertical = 0
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + flow_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - flow_tooltip_panel.size.x - 15
    if pos.y + flow_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - flow_tooltip_panel.size.y - 15
    # We clamp the tooltip inside the screen completely (including at the top), as
    # in the tooltip of the details of a building and of the list of the built
    # buildings.
    pos.x = max(0.0, min(pos.x, maxf(0.0, viewport_size.x - flow_tooltip_panel.size.x)))
    pos.y = max(0.0, min(pos.y, maxf(0.0, viewport_size.y - flow_tooltip_panel.size.y)))
    flow_tooltip_panel.position = pos
    flow_tooltip_panel.show()

func hide_flow_tooltip():
    if flow_tooltip_panel:
        flow_tooltip_panel.hide()

# Shows the tooltip with the breakdown of the treasury by the types of
# profit/expense on hovering "Treasury: N" in the HUD of the map or in the top bar
# of the CityUI.
#   balance            — the current balance of the treasury (a whole number of
#                        coins).
#   planned_income     — the HIERARCHICAL map of the planned rate of the income:
#                        {
#                          "Population consumption": {         # the type
#                            "All the residents": {             # the source
#                              "fruit": {coins_per_sec: 2.5, product_name: "Fruit"},
#                              ...
#                            },
#                            ...
#                          },
#                          # A "flat" type — an income without a breakdown by
#                          # goods (the tax is the only one for now, there is
#                          # nothing to divide it by): under the key
#                          # CityData.TREASURY_FLAT_TYPE_KEY there is
#                          # { rate, label }, and the type is drawn as ONE row:
#                          #   • Taxes: 2 × 3 citizens = 6 / sec
#                          "Taxes": {
#                            CityData.TREASURY_FLAT_TYPE_KEY: {
#                              rate: 6.0, label: "2 × 3 citizens"
#                            }
#                          }
#                        }
#                        From worker_manager.get_actual_treasury_income_map()
#                        (get_planned_treasury_income_map has the same format).
#                        The types and the sources are drawn in the descending order
#                        of their total rate (at the top — the main earnings); the
#                        products inside a source too. The empty types/sources are
#                        hidden.
#   expense_snapshot   — a snapshot of the actual expenses over the last completed
#                        window, a flat dictionary
#                        { "Name of the source" -> signed_amount }.
#                        Positive = spent, negative = a refund (the refund is netted
#                        in the same source, see expansion_manager.handle_action).
#                        The sources with a negative or zero net are hidden,
#                        otherwise a sum with the sign "−" is shown.
#                        From CityData.treasury_expense_snapshot.
#   window_sec         — the length of the window (for the label in the tooltip,
#                        usually CityData.treasury_window_length_sec).
#
# The structure of the sections:
#   * The header: "Treasury: N".
#   * "Profit (actual, average): X / sec" — the TOTAL average profit (the sum over
#     all the types/sources/products), then three levels of nesting
#     (type → source → product), see the example in the comment of the parameter
#     planned_income. The total in the header equals the sum of the rows of the
#     section.
#   * "Expenses (actual, over the last N sec):" — a flat list of the sources with
#     their net sums for the window (plus the type "Actions on the map" as the
#     header).
#   * The explanation of "≈" at the bottom: in the row "Treasury: N [+X≈ / -Y≈]"
#     (the HUD of the map and the top bar of the city) the marker means the profit
#     and the expenses averaged over the last window and recalculated per second
#     (CityData.get_treasury_flow_text). As the "≈" stands on both sides, the
#     bottom is drawn whenever the tooltip is drawn.
#   * If there are no expenses in the game — the note "No one-off expenses…".
# keep_position = true — this is a redraw of an ALREADY shown ("stuck") tooltip:
# the panel stays where it is, only its content and size change (a live update on
# a change of the resource era). Otherwise a live update would move the panel away
# from the cursor and the "sticking" would be impossible (see city_ui/main_map:
# the sticking follows the pattern of building_detail_tooltip).
func show_treasury_tooltip(mouse_pos: Vector2, balance: int, planned_income: Dictionary, expense_snapshot: Dictionary, window_sec: float, keep_position: bool = false):
    if treasury_tooltip_panel == null:
        return
    # We clear the previous content.
    for child in treasury_tooltip_vbox.get_children():
        treasury_tooltip_vbox.remove_child(child)
        child.queue_free()

    # The precalculation of the net expenses: only the sources with amount > 0 (a
    # negative one — is a pure refund without a compensating expense; we do not
    # show it). We sum by the types at the same time as the grouping for the
    # render: at the moment there is only the type "Actions on the map", but the
    # structure of the snapshot is flat — the type is added here, in the render.
    var expense_by_type: Dictionary = {tr("Map actions"): {}}
    for src in expense_snapshot:
        var amt: int = int(expense_snapshot[src])
        if amt <= 0:
            continue
        expense_by_type[tr("Map actions")][src] = amt

    var has_income: bool = not planned_income.is_empty()
    var has_expense: bool = false
    for t in expense_by_type:
        if not expense_by_type[t].is_empty():
            has_expense = true
            break

    # We hide an empty tooltip (neither a plan nor the actual expenses): there is
    # no sense in showing just "Treasury: N" without a breakdown — the cursor arrow
    # is already next to the number in the HUD/TopBar.
    if not has_income and not has_expense:
        treasury_tooltip_panel.hide()
        return

    # --- The header: the current balance ---
    var header = make_money_label()
    header.text = tr("Treasury: %s") % money(str(balance))
    header.add_theme_font_size_override("normal_font_size", 15)
    header.add_theme_color_override("default_color", UI_THEME.color("warning"))
    treasury_tooltip_vbox.add_child(header)

    # --- Profit (actual, average): the types, one of which is "flat" ---
    if has_income:
        # We sort the types by the total rate (descending). Among the types there
        # is a "flat" type — instead of the hierarchy "type → source → product" it
        # is drawn as one row of the kind
        #   • Taxes: 2 × 3 citizens = 6 / sec
        # (the field CityData.TREASURY_FLAT_TYPE_KEY under the key of the type
        # contains {rate, label}).
        # The other types are drawn in three levels: type → source → product.
        # The total over all the types is accumulated by the same loop (including
        # the flat type) and goes into the header of the section; the "flat" type
        # is part of that same total.
        var type_lines: Array = []
        var total_income: float = 0.0
        for income_type in planned_income:
            var type_dict: Dictionary = planned_income[income_type]
            # A "flat" type (for example "Taxes"): instead of the hierarchy
            # "source → product" — one row, the income is not broken down by the
            # goods (the tax is the only one for now, see
            # CityData.TREASURY_FLAT_TYPE_KEY).
            var flat_row: Dictionary = type_dict.get(CityData.TREASURY_FLAT_TYPE_KEY, {})
            if not flat_row.is_empty():
                var flat_rate: float = float(flat_row.get("rate", 0.0))
                if flat_rate > 0.0:
                    type_lines.append({
                        "name": income_type,
                        "total": flat_rate,
                        "flat_label": str(flat_row.get("label", "")),
                        "sources": {}
                    })
                    total_income += flat_rate
                continue
            var type_total: float = 0.0
            for source_id in type_dict:
                for pid in type_dict[source_id]:
                    type_total += float(type_dict[source_id][pid].get("coins_per_sec", 0.0))
            if type_total > 0.0:
                type_lines.append({
                    "name": income_type,
                    "total": type_total,
                    "sources": type_dict
                })
                total_income += type_total
        type_lines.sort_custom(func(a, b): return a.total > b.total)
        # The header of the section with the total average profit. The unit "/ sec"
        # — the same as in the rows of the sources and the products below (the same
        # _format_rate format).
        var income_title = make_money_label()
        income_title.text = tr("Profit (actual, average): %s / sec") % money(
                _format_rate(total_income))
        income_title.add_theme_font_size_override("normal_font_size", 14)
        income_title.add_theme_color_override("default_color",
                UI_THEME.color("income").lightened(0.4))
        treasury_tooltip_vbox.add_child(income_title)
        for type_row in type_lines:
            # A "flat" type (the tax) — ONE row instead of the hierarchy:
            # "• Taxes: 2 × 3 citizens = 6 / sec". On the left — the rate × the
            # number of the payers (a ready label from worker_manager), on the
            # right — the rate in the same _format_rate format as in the sources and
            # the products.
            if type_row.has("flat_label"):
                # The key of the type comes from CityData as a constant and holds the English
                # text (tr() cannot be called in a constant) — we translate it here.
                var flat_text: String = tr(str(type_row.name))
                var flat_label: String = str(type_row.get("flat_label", ""))
                if not flat_label.is_empty():
                    flat_text += ": " + flat_label
                flat_text += tr(" = %s / sec") % _format_rate(float(type_row.total))
                treasury_tooltip_vbox.add_child(
                    _make_bullet_row("•", flat_text, UI_THEME.color("income").lightened(0.55)))
                continue
            # The first level of the breakdown: "• Population consumption:"
            var type_header = Label.new()
            type_header.text = "• " + tr(str(type_row.name)) + ":"
            type_header.add_theme_font_size_override("font_size", 13)
            type_header.add_theme_color_override("font_color",
                    UI_THEME.color("income").lightened(0.55))
            type_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
            treasury_tooltip_vbox.add_child(type_header)
            # The sources inside a type — we sort them by the sum per source.
            var source_lines: Array = []
            for src in type_row.sources:
                var src_total: float = 0.0
                for pid in type_row.sources[src]:
                    src_total += float(type_row.sources[src][pid].get("coins_per_sec", 0.0))
                if src_total > 0.0:
                    source_lines.append({
                        "name": GameData.get_source_display_name(str(src)),
                        "total": src_total,
                        "products": type_row.sources[src]
                    })
            source_lines.sort_custom(func(a, b): return a.total > b.total)
            for src_row in source_lines:
                # The second level of the breakdown:
                # "  ◦ All the residents (3.0 / sec):"
                # src_row.name — already a label, resolved from the id of the source
                # when the rows are sorted below.
                var src_header = Label.new()
                src_header.text = tr("  ◦ %s (%s / sec):") % [
                    str(src_row.name), _format_rate(float(src_row.total))
                ]
                src_header.add_theme_font_size_override("font_size", 13)
                src_header.add_theme_color_override("font_color",
                        UI_THEME.color("income").lightened(0.2))
                src_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
                treasury_tooltip_vbox.add_child(src_header)
                # The products inside a source — we sort them in the descending order.
                var product_lines: Array = []
                for pid in src_row.products:
                    product_lines.append({
                        "name": str(src_row.products[pid].get("product_name", pid)),
                        "rate": float(src_row.products[pid].get("coins_per_sec", 0.0))
                    })
                product_lines.sort_custom(func(a, b): return a.rate > b.rate)
                for prod_row in product_lines:
                    var prod_name: String = str(prod_row.name)
                    var prod_rate: float = float(prod_row.rate)
                    var line_text := tr("%s: %s / sec") % [
                        prod_name, _format_rate(prod_rate)
                    ]
                    treasury_tooltip_vbox.add_child(
                        _make_bullet_row("    ▪", line_text, UI_THEME.color("income")))

    # --- Expenses (actual, over the last N sec): type → source → net sum ---
    if has_expense:
        var window_str: String = "%d" % int(round(window_sec))
        if absf(window_sec - round(window_sec)) > 0.001:
            window_str = "%.1f" % window_sec
        var expense_title = Label.new()
        expense_title.text = tr("Expenses (actual, over the last %s sec):") % window_str
        expense_title.add_theme_font_size_override("font_size", 14)
        expense_title.add_theme_color_override("font_color",
                UI_THEME.color("expense").lightened(0.35))
        expense_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        treasury_tooltip_vbox.add_child(expense_title)
        for expense_type in expense_by_type:
            if expense_by_type[expense_type].is_empty():
                continue
            var expense_type_label = Label.new()
            expense_type_label.text = "  " + str(expense_type) + ":"
            expense_type_label.add_theme_font_size_override("font_size", 13)
            expense_type_label.add_theme_color_override("font_color",
                    UI_THEME.color("expense").lightened(0.55))
            expense_type_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            treasury_tooltip_vbox.add_child(expense_type_label)
            var expense_lines: Array = []
            for src in expense_by_type[expense_type]:
                expense_lines.append({
                    "name": GameData.get_source_display_name(str(src)),
                    "amount": int(expense_by_type[expense_type][src])
                })
            expense_lines.sort_custom(func(a, b): return a.amount > b.amount)
            for row in expense_lines:
                var amt: int = int(row.amount)
                # The sign: only amount > 0 reaches here (see the precalculation
                # above), a refund is netted in the same source.
                var sign_char: String = "−" if amt > 0 else "+"
                var mag: int = abs(amt)
                var line_text := "%s: %s%d" % [str(row.name), sign_char, mag]
                treasury_tooltip_vbox.add_child(
                    _make_bullet_row("•", line_text, UI_THEME.color("expense")))

    # --- The bottom: a reference to the dynamics "≈" (as in the tooltip of the
    #     resources) ---
    # The explanation is needed both for the section of the profit and for the
    # section of the expenses: the marker "≈" stands on both sides of the row
    # "Treasury: N [+X≈ / -Y≈]" (the HUD of the map and the top bar of the city, see
    # CityData.get_treasury_flow_text). Therefore the row is shown whenever the
    # tooltip is drawn at all.
    var note = Label.new()
    note.text = tr("≈ in the \"Treasury\" row — average profit and expenses over the last window, per second")
    note.add_theme_font_size_override("font_size", 12)
    note.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    note.mouse_filter = Control.MOUSE_FILTER_IGNORE
    treasury_tooltip_vbox.add_child(note)

    # --- The bottom: a note, if there are no expenses in the game yet ---
    if not has_expense:
        var no_expense_note = Label.new()
        no_expense_note.text = tr("No one-off treasury expenses in the last window")
        no_expense_note.add_theme_font_size_override("font_size", 12)
        no_expense_note.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
        no_expense_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
        treasury_tooltip_vbox.add_child(no_expense_note)

    treasury_tooltip_vbox.reset_size()
    var content_size = treasury_tooltip_vbox.get_minimum_size()
    # The indents from the edge of the panel: the same 6/4/6/4 pixels as in
    # flow_tooltip - a scroll container with PRECEDE_FULL_RECT + offset_*.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    var max_content_height = DETAIL_TOOLTIP_MAX_ROWS * DETAIL_TOOLTIP_ROW_HEIGHT
    var content_height = min(content_size.y, max_content_height)
    var scrollbar_width = 0.0
    if content_size.y > max_content_height:
        scrollbar_width = DETAIL_TOOLTIP_SCROLLBAR_WIDTH
    treasury_tooltip_panel.size = Vector2(
        content_size.x + scrollbar_width + pad_left + pad_right,
        content_height + pad_top + pad_bottom
    )
    # The tooltip has just been shown — the scroll to the top (as in flow_tooltip_panel).
    if not treasury_tooltip_panel.visible:
        treasury_tooltip_scroll.scroll_vertical = 0
    var viewport_size = get_viewport().get_visible_rect().size
    # A "stuck" tooltip is redrawn IN PLACE (the panel already stands where the
    # cursor of the player moved it) — otherwise the panel would run away from
    # under the cursor.
    # The recalculation of the size above is done anyway: the content may have
    # grown a little.
    var pos: Vector2
    if keep_position and treasury_tooltip_panel.visible:
        pos = treasury_tooltip_panel.position
    else:
        pos = mouse_pos + Vector2(15, 15)
        if pos.x + treasury_tooltip_panel.size.x > viewport_size.x:
            pos.x = mouse_pos.x - treasury_tooltip_panel.size.x - 15
        if pos.y + treasury_tooltip_panel.size.y > viewport_size.y:
            pos.y = mouse_pos.y - treasury_tooltip_panel.size.y - 15
    pos.x = max(0.0, min(pos.x, maxf(0.0, viewport_size.x - treasury_tooltip_panel.size.x)))
    pos.y = max(0.0, min(pos.y, maxf(0.0, viewport_size.y - treasury_tooltip_panel.size.y)))
    treasury_tooltip_panel.position = pos
    treasury_tooltip_panel.show()

func hide_treasury_tooltip():
    if treasury_tooltip_panel:
        treasury_tooltip_panel.hide()

func set_message(text: String):
    if message_label:
        message_label.text = text
