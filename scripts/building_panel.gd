# building_panel.gd
# The details panel of a building: shows the information about a building
# (possibly several of the same type) and about their slots, allows changing
# the recipe in every slot, and pausing/resuming the individual buildings.
extends Control

var building_id: String = ""
var products: Dictionary = {}
var raw_resources: Dictionary = {}
var buildings_data: Array = []
var crafts_data: Array = []
var ui_helpers: Node

var panel: Panel
var title_label: Label
var info_label: Label
var slots_container: VBoxContainer
# The "Consumes:" section — the professional consumption of the profession of a
# citizen in the buildings of this type. It lives between "Buildings: N" and the
# list of the slots, and is rebuilt in _refresh() (the container itself is
# created once in _ready()).
var consumption_box: VBoxContainer

var popups_list: Array = []
var popup_map: Dictionary = {}
var open_popup = null

# The snapshot of the state at which _refresh() was last done.
# It holds the number of buildings, the recipes in the slots, the presence of a
# worker and the quality priority for every index. It is used in order NOT to
# rebuild the panel of the slots on every game tick: city_updated is emitted
# once per SIMULATION_TICK by do_tick(), and without this _refresh() would
# destroy the header buttons (toggle_btn, quality_btn) together with their OS
# tooltips (the pause/resume one and the quality priority one) on every tick.
# Format: {"count": int, "items": {b_index: {"slots": [..], "priority": String, "has_worker": bool, "can_upgrade": bool}}}
var _last_panel_state: Dictionary = {}

# The progress bars of the building upgrades that are under way: b_index ->
# ProgressBar. They are updated every frame in _process() WITHOUT rebuilding
# the UI (otherwise the tooltips would die).
var _upgrade_progress_bars: Dictionary = {}

# The progress bars of the crafting of the slots: "b_index:slot_idx" ->
# ProgressBar. They show how much of the time of the recipe (data/crafts, the
# "time" field) the slot has already accumulated
# (CityData.get_slot_progress_ratio). These are updated in _process() as well,
# without rebuilding the UI. A bar is created only for the recipes whose time
# is longer than one tick — for the rest the crafting happens on every
# simulation tick anyway.
var _slot_progress_bars: Dictionary = {}

# The tooltip of the "Upgrade" button: a panel of its own with rich content
# (the icons of the building and of the materials — the plain tooltip_text
# cannot show pictures). A panel of its own, and not
# ui_helpers.detail_tooltip_panel: that one is shared with the "Buildings" tab,
# and the panel of the building is drawn on top of the CityUi.
var upgrade_tooltip_panel: Panel = null
var upgrade_tooltip_content: VBoxContainer = null

func _ready():
    # We subscribe to the changes of the worker assignments, so that the panel
    # is updated in real time (for example, on the birth of a resident who
    # automatically takes a job).
    call_deferred("_setup_assignments_listener")
    # We create the overlay panel on top of the CityUI.
    # IMPORTANT: the CityUI is a child node of a Node2D scene, therefore it has
    # no rect of its own. The sizes of the root Control are set by hand in open().
    var dim = ColorRect.new()
    dim.color = Color(0, 0, 0, 0.5)
    dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(dim)

    var center = CenterContainer.new()
    center.set_anchors_preset(Control.PRESET_FULL_RECT)
    add_child(center)

    panel = Panel.new()
    panel.custom_minimum_size = Vector2(460, 400)
    # An opaque dark background for the panel
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.13, 0.13, 0.13, 1.0)
    style.set_border_width_all(2)
    style.border_color = Color(0.4, 0.4, 0.4, 1.0)
    style.set_corner_radius_all(4)
    panel.add_theme_stylebox_override("panel", style)
    center.add_child(panel)

    var vbox = VBoxContainer.new()
    vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 20
    vbox.offset_top = 20
    vbox.offset_right = -20
    vbox.offset_bottom = -20
    vbox.add_theme_constant_override("separation", 10)
    panel.add_child(vbox)

    title_label = Label.new()
    title_label.add_theme_font_size_override("font_size", 20)
    vbox.add_child(title_label)

    info_label = Label.new()
    vbox.add_child(info_label)

    # The section of the professional consumption of the building ("Consumes:").
    # Its content is assembled by _refresh() — that way the section does not
    # depend on the slots being rebuilt.
    consumption_box = VBoxContainer.new()
    consumption_box.add_theme_constant_override("separation", 4)
    consumption_box.visible = false
    vbox.add_child(consumption_box)

    var slots_title = Label.new()
    slots_title.text = tr("Production slots:")
    vbox.add_child(slots_title)

    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    vbox.add_child(scroll)

    slots_container = VBoxContainer.new()
    slots_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(slots_container)

    var close_btn = Button.new()
    close_btn.text = tr("Close")
    close_btn.pressed.connect(_on_close_pressed)
    vbox.add_child(close_btn)

    # The tooltip of the "Upgrade" button: a panel with icons (the building, the
    # materials). mouse_filter IGNORE — the tooltip does not intercept the input;
    # z_index is lower than the one of group_tooltip (1100), so that on hovering
    # a group resource the composition of the group is drawn on top of it.
    upgrade_tooltip_panel = Panel.new()
    upgrade_tooltip_panel.visible = false
    upgrade_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    upgrade_tooltip_panel.z_index = 1050
    upgrade_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())
    add_child(upgrade_tooltip_panel)

    upgrade_tooltip_content = VBoxContainer.new()
    upgrade_tooltip_content.add_theme_constant_override("separation", 4)
    upgrade_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    upgrade_tooltip_panel.add_child(upgrade_tooltip_content)

# The style of the background of the tooltip — the same as the tooltips of
# ui_helpers: an opaque dark background with a light frame of 1px.
func _make_tooltip_style() -> StyleBoxFlat:
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.2, 0.2, 0.2, 1.0)
    style.border_width_left = 1
    style.border_width_top = 1
    style.border_width_right = 1
    style.border_width_bottom = 1
    style.border_color = Color(0.6, 0.6, 0.6)
    return style

func open(building_id_arg: String, data: Dictionary):
    # We clear the old popups on opening (the content may have become stale, for
    # example after a new technology has been researched). On a periodic
    # _refresh() the popups are reused and stay open.
    for key in popup_map.keys():
        var old_popup = popup_map[key]
        if is_instance_valid(old_popup):
            old_popup.queue_free()
    popup_map.clear()
    popups_list.clear()
    open_popup = null
    building_id = building_id_arg
    products = data.get("products", {})
    raw_resources = data.get("raw_resources", {})
    crafts_data = data.get("crafts_data", [])
    ui_helpers = data.get("ui_helpers", null)
    # We reset the width of the panel to the base one, so that it does not stay wide from the previous building
    panel.custom_minimum_size.x = 460
    # We set the size of the root Control = the size of the viewport, so that the overlay covers everything
    var vp_size = get_viewport_rect().size
    size = vp_size
    position = Vector2.ZERO
    # We reset the state cache, so that _refresh() is guaranteed to do its work
    # when the panel opens (otherwise it would return right away on "the state
    # has not changed").
    _last_panel_state = {}
    _refresh()
    show()

func _refresh():
    # We collect the indices of the built buildings with the required id
    var indices = []
    for idx in range(CityData.city_built_buildings.size()):
        if CityData.city_built_buildings[idx].get("id", "") == building_id:
            indices.append(idx)

    if indices.is_empty():
        # All the buildings of this type have been upgraded (an upgrade changes
        # the id) or demolished — we clear the panel, so that it does not show
        # the stale slots.
        for child in slots_container.get_children():
            child.queue_free()
        info_label.text = tr("Buildings: 0")
        _clear_consumption_section()
        _upgrade_progress_bars.clear()
        _slot_progress_bars.clear()
        return

    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break

    var building_name = bdata["name"] if bdata else building_id
    title_label.text = building_name

    info_label.text = tr("Buildings: %d") % indices.size()

    # We clear the old slots
    for child in slots_container.get_children():
        child.queue_free()
    _upgrade_progress_bars.clear()
    _slot_progress_bars.clear()
    # The header buttons are recreated — the tooltip of the upgrade may have
    # stayed hanging (the mouse_exited of a button being removed will not fire),
    # so we hide it explicitly.
    _hide_upgrade_tooltip()

    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null

    # The professional consumption of the buildings of this type: the sum over
    # the WORKING buildings (there is a citizen and at least one non-empty slot —
    # the supplies of an idle building are not spent, see
    # CityData.get_townsfolk_professions_count).
    # The width of the section takes part in fitting the width of the panel below.
    var consumption_width := _fill_consumption_section(tm, indices)

    var max_popup_content_width = 0.0
    var max_slot_row_width = 0.0
    var popups = []
    var new_popup_map = {}
    var building_number = 0
    for b_index in indices:
        building_number += 1
        var bld = CityData.city_built_buildings[b_index]
        var slots = bld.get("slots", [])

        # The header of a single building, with the pause/resume button
        var header = HBoxContainer.new()
        header.add_theme_constant_override("separation", 8)

        var has_worker = tm.has_townsfolk(b_index) if tm else false
        var is_idle = has_worker and CityData.are_all_slots_empty(b_index)
        var status = tr(" (idle)") if is_idle else (tr(" (working)") if has_worker else tr(" (not working)"))

        var header_label = Label.new()
        header_label.text = tr("Building %d%s") % [building_number, status]
        if is_idle:
            header_label.add_theme_color_override("font_color", Color.ORANGE)
        else:
            header_label.add_theme_color_override("font_color", Color.GREEN if has_worker else Color.RED)
        header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        header.add_child(header_label)

        # The "Upgrade" button — next to a building that has an improved version
        # (the upgrades_into field in buildings.json). It appears after the
        # technology that opens the improved version has been researched. The
        # tooltip shows the cost of building the improved version. While the
        # upgrade is under way the building works as usual, and a progress bar
        # is displayed instead of the button.
        var upgrade_data = CityData.get_building_upgrade_data(b_index)
        if not upgrade_data.is_empty():
            # The upgrade of this building is already under way — we show the
            # progress (it is updated in _process() without rebuilding the UI).
            var upgrade_bar = ProgressBar.new()
            upgrade_bar.custom_minimum_size = Vector2(90, 18)
            upgrade_bar.show_percentage = false
            upgrade_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
            upgrade_bar.max_value = maxf(1.0, float(upgrade_data.get("work_cost", 1)))
            upgrade_bar.value = float(upgrade_data.get("progress", 0.0))
            upgrade_bar.tooltip_text = tr("Upgrading to \"%s\"") % upgrade_data.get("upgrade_name", upgrade_data.get("upgrade_to", ""))
            header.add_child(upgrade_bar)
            _upgrade_progress_bars[b_index] = upgrade_bar
        elif CityData.can_upgrade_building(b_index):
            var upgrade_btn = Button.new()
            upgrade_btn.custom_minimum_size = Vector2(28, 28)
            upgrade_btn.expand_icon = true
            upgrade_btn.icon = _get_toggle_icon("upgrade")
            # The tooltip with the icons is drawn by a panel of its own on hover
            # (see _on_upgrade_btn_hovered) — the plain tooltip_text is not able
            # to show pictures.
            upgrade_btn.pressed.connect(_on_upgrade_pressed.bind(b_index))
            upgrade_btn.mouse_entered.connect(_on_upgrade_btn_hovered.bind(upgrade_btn, b_index))
            upgrade_btn.mouse_exited.connect(_hide_upgrade_tooltip)
            header.add_child(upgrade_btn)

        var toggle_btn = Button.new()
        toggle_btn.custom_minimum_size = Vector2(28, 28)
        toggle_btn.expand_icon = true
        if has_worker:
            toggle_btn.icon = _get_toggle_icon("pause")
            toggle_btn.tooltip_text = tr("Pause")
            toggle_btn.pressed.connect(_on_toggle_pressed.bind(b_index, false))
        else:
            toggle_btn.icon = _get_toggle_icon("resume")
            toggle_btn.tooltip_text = tr("Start")
            toggle_btn.pressed.connect(_on_toggle_pressed.bind(b_index, true))
        header.add_child(toggle_btn)

        # The quality priority button: best (the best) / worst (the worst)
        var quality_btn = Button.new()
        quality_btn.custom_minimum_size = Vector2(28, 28)
        quality_btn.expand_icon = true
        quality_btn.tooltip_text = tr("Quality priority: use best/worst")
        quality_btn.pressed.connect(_on_quality_priority_pressed.bind(b_index))
        _update_quality_button(quality_btn, b_index)
        header.add_child(quality_btn)

        slots_container.add_child(header)

        for i in range(slots.size()):
            var row = HBoxContainer.new()
            row.add_theme_constant_override("separation", 8)

            var slot_label = Label.new()
            slot_label.text = tr("Slot %d:") % (i + 1)
            slot_label.custom_minimum_size = Vector2(70, 0)
            row.add_child(slot_label)

            # We collect the available recipes: "empty" + all the ones that can
            # be crafted in this building (filtered by the researched technologies)
            var available = []
            available.append("empty")
            for craft in crafts_data:
                if craft["id"] == "empty":
                    continue
                if not CityData.can_craft_in(craft["id"], building_id):
                    continue
                var craft_unlock_tech = craft.get("unlock_tech", "")
                if craft_unlock_tech != "" and not CityData.is_tech_unlocked(craft_unlock_tech):
                    continue
                available.append(craft["id"])

            var current = slots[i]

            # The recipe selection button
            var select_btn = Button.new()
            select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            select_btn.add_theme_constant_override("icon_max_width", 24)
            select_btn.clip_text = true

            var popup_key = "%d:%d" % [b_index, i]
            var popup = null
            # We reuse the existing popup, if there is one
            if popup_map.has(popup_key) and is_instance_valid(popup_map[popup_key]):
                popup = popup_map[popup_key]
                # The popup exists — we replace its content with the actual button
                for child in popup.get_children():
                    popup.remove_child(child)
                    child.free()
            else:
                # A custom popup with the list of the recipes (it supports several
                # result icons)
                # IMPORTANT: the popup (Window) has to be added to the tree BEFORE
                # the content is added, otherwise the layout is not recalculated.
                popup = PopupPanel.new()
                var popup_style = StyleBoxFlat.new()
                popup_style.bg_color = Color(0.15, 0.15, 0.15, 1.0)
                popup_style.set_border_width_all(1)
                popup_style.border_color = Color(0.4, 0.4, 0.4, 1.0)
                popup_style.set_corner_radius_all(4)
                popup.add_theme_stylebox_override("panel", popup_style)
                popup.set_meta("popup_key", popup_key)
                add_child(popup)
                popup.hide()
            # The content is filled after the popup is in the tree: the project
            # theme (project.godot: theme/custom) applies its font to controls
            # only in the tree, and the widths measured out of the tree
            # underestimate long recipe rows.
            var fill_data = _fill_popup_content(popup, b_index, i, available, select_btn)
            if float(fill_data["max_content_width"]) > max_popup_content_width:
                max_popup_content_width = float(fill_data["max_content_width"])
            popups.append(popup)
            popups_list.append(popup)
            new_popup_map[popup_key] = popup
            select_btn.pressed.connect(_on_slot_button_pressed.bind(b_index, i, popup, select_btn))
            row.add_child(select_btn)

            # The progress bar of the crafting of a slot: how much of the time of
            # the recipe (time) has already been accumulated. It is shown only for
            # the recipes that last longer than a simulation tick (for an instant
            # recipe the progress is always "full").
            # It is updated in _process() without rebuilding the UI.
            # In the continuous model the progress bar shows the completion_ratio
            # (0..1): min(the filling of the ingredients, time/craft_time). When
            # there is a shortage of the raw materials the bar still grows while
            # the time accumulates, but it does not exceed 1.0 — that is the "real
            # degree of readiness taking the shortage into account".
            var craft_time = CityData.get_slot_craft_time(b_index, i)
            if craft_time > CityData.SIMULATION_TICK:
                var craft_bar = ProgressBar.new()
                craft_bar.custom_minimum_size = Vector2(70, 14)
                craft_bar.show_percentage = false
                craft_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
                craft_bar.max_value = 1.0
                craft_bar.value = CityData.get_slot_progress_ratio(b_index, i)
                # The name of the recipe is in the label of the bar: the tooltip is
                # updated in _process() without a lookup in the recipe registry on
                # every frame.
                craft_bar.set_meta("craft_name", _get_craft_name(str(current)))
                craft_bar.tooltip_text = ""
                craft_bar.mouse_entered.connect(_on_craft_bar_mouse_entered.bind(craft_bar))
                craft_bar.mouse_exited.connect(_on_craft_bar_mouse_exited)
                row.add_child(craft_bar)
                _slot_progress_bars["%d:%d" % [b_index, i]] = craft_bar
            # The button content is filled when the row is already in the tree:
            # the project theme (project.godot: theme/custom) applies its font
            # to controls only in the tree, and an out-of-tree measurement
            # underestimates the width of long recipe names.
            slots_container.add_child(row)
            _update_slot_button(select_btn, current)
            var slot_row_width = slot_label.get_combined_minimum_size().x + 8.0
            slot_row_width += select_btn.get_combined_minimum_size().x
            if craft_time > CityData.SIMULATION_TICK:
                slot_row_width += 8.0 + 70.0
            max_slot_row_width = maxf(max_slot_row_width, slot_row_width)

    # The base width of the panel: the actual width of the slot rows (they grow
    # with the recipe button, which is sized from the real content in
    # _update_slot_button), plus a margin for the paddings of the header and the
    # "Consumes:" section.
    var needed_width = maxf(max_slot_row_width + 40 + 16, 460.0)
    # The "Consumes:" section is one more row of content: its label would
    # otherwise stick out past the edge of the panel, which is calculated from
    # the slots and the popups alone.
    needed_width = maxf(needed_width, consumption_width + 40 + 16)
    # The widest recipe row of the popups (measured from the real content at
    # fill time): the popups must fit it already when the panel opens, and not
    # only after a recipe is selected in the slot.
    needed_width = maxf(needed_width, max_popup_content_width + 70 + 40 + 16)
    # We do not let the panel go beyond the limits of the viewport
    var max_panel_width = get_viewport_rect().size.x - 40
    if needed_width > max_panel_width:
        needed_width = max_panel_width
    if needed_width > panel.custom_minimum_size.x:
        panel.custom_minimum_size.x = needed_width

    # We bring the width of the popups in line with the width of the panel
    var popup_width = panel.custom_minimum_size.x - 70 - 40
    for popup in popups:
        popup.min_size.x = popup_width

    # We update popup_map and remove the popups that are no longer needed
    for key in popup_map.keys():
        if not new_popup_map.has(key):
            var old_popup = popup_map[key]
            if is_instance_valid(old_popup):
                old_popup.queue_free()
    popup_map = new_popup_map
    popups_list.clear()
    for key in popup_map.keys():
        if is_instance_valid(popup_map[key]):
            popups_list.append(popup_map[key])

    # We record the state snapshot, so that the subsequent
    # _on_assignments_changed() on the idle ticks does not do a repeated
    # _refresh() and does not kill the OS tooltips of the header buttons
    # (toggle_btn, quality_btn).
    _last_panel_state = _collect_panel_state(tm)

# Fills (or hides) the "Consumes:" section — the professional consumption of the
# profession of a citizen in the buildings of THIS type. The sum over the working
# buildings is shown: the rate of the row is multiplied by their number, and the
# label gains a "(2 buildings)"; with a single working building the row is the
# same as in the tooltip of the hex.
# The format of the rows is given by the shared ConsumptionUi — the same one as
# in the extended tooltip of the hex, in the left column of the control panel and
# in the details tooltip of the building.
# Returns the width of the content of the section: it takes part in fitting the
# width of the panel together with the slots and the popups.
func _fill_consumption_section(tm, indices: Array) -> float:
    _clear_consumption_section()
    var rows = ConsumptionUi.build_rows_for_building(
        building_id, _count_working_buildings(tm, indices))
    if rows.is_empty():
        return 0.0

    var header = Label.new()
    header.text = tr("Consumes:")
    header.add_theme_font_size_override("font_size", 16)
    header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    consumption_box.add_child(header)

    var all_resources := _get_all_resources()
    var font = get_theme_default_font()
    var font_size = get_theme_default_font_size()
    var content_width := 0.0
    for row in rows:
        var line = HBoxContainer.new()
        line.add_theme_constant_override("separation", 6)
        line.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var indent = Control.new()
        indent.custom_minimum_size.x = 18
        indent.mouse_filter = Control.MOUSE_FILTER_IGNORE
        line.add_child(indent)
        var bullet = Label.new()
        bullet.text = "◦"
        bullet.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
        line.add_child(bullet)
        # The name of the resource with the icon is drawn by the shared helper
        # (for an @-group it is an underlined name with the composition on
        # hover), the rate and the bonus are appended to the right.
        line.add_child(ui_helpers.make_resource_entry(
            str(row.get("display_key", "")), all_resources))
        var rate_label = Label.new()
        rate_label.text = ": %s" % str(row.get("rate_label", ""))
        rate_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        rate_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        line.add_child(rate_label)
        consumption_box.add_child(line)
        # The width of the row: the name of the resource + ": " + the tail of the
        # label, plus the indent, the marker, the icon (20 px) and the separators
        # of the HBox.
        var row_width := font.get_string_size(
                str(row.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x \
            + font.get_string_size(" " + str(row.get("rate_label", "")),
                HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x \
            + 18.0 + 12.0 + 20.0 + 24.0
        content_width = maxf(content_width, row_width)
    consumption_box.visible = true
    return content_width

# The number of the buildings of this type that really spend the supplies: there
# is a citizen and at least one non-empty slot. When there are no such buildings,
# the section shows the rate "per one building" with the note
# "(there are no working buildings)".
func _count_working_buildings(tm, indices: Array) -> int:
    var result := 0
    if tm == null:
        return result
    for b_index in indices:
        if not tm.has_townsfolk(b_index):
            continue
        if CityData.are_all_slots_empty(b_index):
            continue
        result += 1
    return result

# Clears the "Consumes:" section and hides it: for a building without a profession
# (or without any supplies for it) there is nothing to show.
func _clear_consumption_section():
    if consumption_box == null:
        return
    for child in consumption_box.get_children():
        consumption_box.remove_child(child)
        child.queue_free()
    consumption_box.visible = false

# Fills the content of the popup with the list of the available recipes.
# Returns the real minimum width of the widest recipe row — it participates in
# fitting the width of the panel in _refresh(), so that the recipe rows fit
# already when the panel opens, and not only after a recipe is selected.
func _fill_popup_content(popup, b_index: int, slot_idx: int, available: Array, button) -> Dictionary:
    var result = {"max_content_width": 0.0}

    var popup_vbox = VBoxContainer.new()
    popup_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    popup_vbox.offset_left = 6
    popup_vbox.offset_top = 6
    popup_vbox.offset_right = -6
    popup_vbox.offset_bottom = -6
    popup_vbox.add_theme_constant_override("separation", 2)
    popup.add_child(popup_vbox)

    for craft_id in available:
        var craft_name = craft_id
        var craft_resources = {}
        var craft_result = {}
        for c in crafts_data:
            if c["id"] == craft_id:
                craft_name = c.get("name", craft_id)
                craft_resources = c.get("resources", {})
                # display_result — a UI hint for the "non-material" outputs
                # (science and the future pseudo-resources): it is not read by
                # the mechanics.
                craft_result = c.get("display_result", c.get("result", {}))
                break
        # An item of the list — a Button with the content and a built-in highlight on hover
        var item_btn = Button.new()
        item_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
        item_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        item_btn.custom_minimum_size.y = 30
        item_btn.focus_mode = Control.FOCUS_NONE

        var normal_style = StyleBoxFlat.new()
        normal_style.bg_color = Color(0, 0, 0, 0)
        var hover_style = StyleBoxFlat.new()
        hover_style.bg_color = Color(0.35, 0.35, 0.35, 1.0)
        item_btn.add_theme_stylebox_override("normal", normal_style)
        item_btn.add_theme_stylebox_override("hover", hover_style)
        item_btn.add_theme_stylebox_override("pressed", hover_style)
        item_btn.add_theme_stylebox_override("focus", hover_style)

        var content = _make_craft_content(craft_name, craft_resources, craft_result)
        content.set_anchors_preset(Control.PRESET_FULL_RECT)
        content.offset_left = 8
        content.offset_right = -8
        item_btn.add_child(content)
        # The width is measured after the item is added to the tree: the project
        # theme (project.godot: theme/custom) applies its font to controls only
        # in the tree, and an out-of-tree measurement underestimates the width
        # of long recipe rows (icons + names + "xN" amounts).
        item_btn.pressed.connect(_on_craft_item_selected.bind(b_index, slot_idx, craft_id, popup, button))
        popup_vbox.add_child(item_btn)
        var content_min_width = content.get_combined_minimum_size().x + 16.0
        if content_min_width > float(result["max_content_width"]):
            result["max_content_width"] = content_min_width

    return result

func _setup_assignments_listener():
    # We connect to the signal of the change of the assignments of the citizens,
    # in order to update the panel in real time (for example, when a new resident
    # automatically takes a job).
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    if tm and not tm.assignment_changed.is_connected(_on_assignments_changed):
        tm.assignment_changed.connect(_on_assignments_changed)
    # We subscribe to the update of the city, so that the panel is updated when
    # the recipes change (the "idle" status appears/disappears at once).
    if not CityData.city_updated.is_connected(_on_assignments_changed):
        CityData.city_updated.connect(_on_assignments_changed)

func _on_assignments_changed():
    if not visible:
        return
    # If the popup with the list of the recipes is open — we do NOT call
    # _refresh(), so that the popup is not rebuilt and does not close on every
    # game tick.
    # (city_updated is emitted on every simulation tick — SIMULATION_TICK — by
    # do_tick.)
    if open_popup != null:
        return
    # If the tooltip of the list of the products (of a group resource) is open —
    # we do not call _refresh() either, so that it does not disappear when the
    # rows of the costs are rebuilt.
    if ui_helpers != null and is_instance_valid(ui_helpers):
        var gtp = ui_helpers.group_tooltip_panel
        if is_instance_valid(gtp) and gtp.visible:
            return

    # We compare the current state with the one at which the last _refresh() was
    # done. If nothing has changed (and on an ordinary tick of do_tick() only the
    # content of the storages changes, not the composition of the
    # buildings/slots/workers) — we return without rebuilding the UI. Otherwise
    # the header buttons and their OS tooltips die on every tick.
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    var current_state = _collect_panel_state(tm)
    if _panel_state_equal(_last_panel_state, current_state):
        return
    _last_panel_state = current_state
    _refresh()

# Assembles a snapshot of the data that the look of the panel of the slots
# depends on.
func _collect_panel_state(tm) -> Dictionary:
    var state = {"count": 0, "items": {}}
    for idx in range(CityData.city_built_buildings.size()):
        if CityData.city_built_buildings[idx].get("id", "") != building_id:
            continue
        var bld = CityData.city_built_buildings[idx]
        state["count"] += 1
        var has_worker = tm.has_townsfolk(idx) if tm else false
        state["items"][idx] = {
            "slots": (bld.get("slots", []) as Array).duplicate(),
            "priority": bld.get("quality_priority", GameData.get_quality_priority_default()),
            "has_worker": has_worker,
            # The availability of the upgrade: the start of the upgrade and the
            # research of the technology that opens it have to rebuild the panel
            # (the "Upgrade" button <-> the progress bar). During the upgrade
            # can_upgrade == false.
            "can_upgrade": CityData.can_upgrade_building(idx),
        }
    return state

# Compares two snapshots of the state of the panel. It ignores the quantitative
# changes of the storages/production — they must not cause a rebuild of the UI of
# the slots.
func _panel_state_equal(a: Dictionary, b: Dictionary) -> bool:
    if a.get("count", 0) != b.get("count", 0):
        return false
    var a_items: Dictionary = a.get("items", {})
    var b_items: Dictionary = b.get("items", {})
    if a_items.size() != b_items.size():
        return false
    for idx in a_items:
        if not b_items.has(idx):
            return false
        var ai: Dictionary = a_items[idx]
        var bi: Dictionary = b_items[idx]
        if ai.get("priority", "") != bi.get("priority", ""):
            return false
        if ai.get("has_worker", false) != bi.get("has_worker", false):
            return false
        if ai.get("can_upgrade", false) != bi.get("can_upgrade", false):
            return false
        var a_slots: Array = ai.get("slots", [])
        var b_slots: Array = bi.get("slots", [])
        if a_slots.size() != b_slots.size():
            return false
        for i in a_slots.size():
            if a_slots[i] != b_slots[i]:
                return false
    return true

func _on_toggle_pressed(b_index: int, enable: bool):
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    if not tm:
        return

    if enable:
        if CityData.idle_population <= 0:
            # We show the message through the city UI, if it is available
            var city_ui = get_tree().root.find_child("CityUi", true, false)
            if city_ui and city_ui.has_method("set_message"):
                city_ui.set_message(tr("No free citizens!"))
            return
        tm.assign_townsfolk(b_index)
    else:
        tm.remove_townsfolk(b_index)

    # We hide the open popups before rebuilding the slots, so that they do not
    # refer to the elements being removed and do not stay hanging.
    for p in popups_list:
        if is_instance_valid(p) and p.visible:
            p.hide()
    _refresh()

# Switches the quality priority of the building and updates the button.
func _on_quality_priority_pressed(b_index: int):
    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return
    var bld = CityData.city_built_buildings[b_index]
    var current = bld.get("quality_priority", GameData.get_quality_priority_default())
    var options = GameData.get_quality_priority_options()
    var new_priority = options[0] if not options.is_empty() else "best"
    # We switch cyclically: best → worst → random → best
    if not options.is_empty():
        var idx = options.find(current)
        if idx < 0:
            idx = 0
        idx = (idx + 1) % options.size()
        new_priority = options[idx]
    bld["quality_priority"] = new_priority
    # We show the message
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map and main_map.has_node("HUD"):
        var hud = main_map.get_node("HUD")
        if hud and hud.has_method("show_message"):
            var label = bld.get("id", "")
            var bdata = null
            for b in GameData.buildings:
                if b["id"] == label:
                    bdata = b
                    break
            var bname = bdata.get("name", label) if bdata else label
            var priority_text = GameData.get_quality_priority_name(new_priority)
            hud.show_message(tr("%s: quality priority — %s") % [bname, priority_text])
    # We update the button in the interface
    _refresh()
    CityData.emit_signal("city_updated")

# Updates the text/tooltip of the quality priority button.
func _update_quality_button(button: Button, b_index: int):
    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return
    var bld = CityData.city_built_buildings[b_index]
    var priority = bld.get("quality_priority", GameData.get_quality_priority_default())
    var levels = GameData.get_quality_levels()
    # The indication of the priority: the stars of the best/worst quality, or 🎲 for random.
    if priority == "best" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.back())
    elif priority == "worst" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.front())
    elif priority == "random":
        button.text = "🎲"
    else:
        button.text = "★"
    button.tooltip_text = tr("Quality priority: %s (click to switch)") % GameData.get_quality_priority_name(priority)

func _get_toggle_icon(icon_name: String) -> Texture2D:
    if icon_name == "resume":
        return IconRegistry.get_texture("building_resume.png")
    if icon_name == "upgrade":
        return IconRegistry.get_texture("building_upgrade.png")
    return IconRegistry.get_texture("building_pause.png")

# Updates the progress bars of the building upgrades that are under way on every
# frame, WITHOUT rebuilding the UI of the slots (a full rebuild of the panel would
# kill the tooltips; the progress changes continuously, and not only on the ticks
# of city_updated).
func _process(delta):
    if _upgrade_progress_bars.is_empty() and _slot_progress_bars.is_empty():
        return
    var finished: Array = []
    for b_index in _upgrade_progress_bars:
        var bar = _upgrade_progress_bars[b_index]
        if not is_instance_valid(bar):
            finished.append(b_index)
            continue
        var upgrade_data = CityData.get_building_upgrade_data(b_index)
        if upgrade_data.is_empty():
            # The upgrade is finished — the next rebuild of the panel will remove the bar.
            finished.append(b_index)
            continue
        bar.max_value = maxf(1.0, float(upgrade_data.get("work_cost", 1)))
        bar.value = float(upgrade_data.get("progress", 0.0))
    for b_index in finished:
        _upgrade_progress_bars.erase(b_index)

    # The progress bars of the crafting of the slots: the value is recalculated
    # from the completion_ratio (CityData.get_slot_progress_ratio), also without
    # rebuilding the UI. In the continuous model it is
    # min(the filling, time/craft_time) — that is the real degree of readiness
    # taking the shortage of the raw materials into account.
    var stale: Array = []
    for key in _slot_progress_bars:
        var craft_bar = _slot_progress_bars[key]
        if not is_instance_valid(craft_bar):
            stale.append(key)
            continue
        var parts = str(key).split(":", false)
        if parts.size() != 2:
            stale.append(key)
            continue
        var craft_time = CityData.get_slot_craft_time(int(parts[0]), int(parts[1]))
        if craft_time <= 0.0:
            # The slot is emptied or the recipe is removed — the next rebuild will remove the bar.
            stale.append(key)
            continue
        craft_bar.max_value = 1.0
        craft_bar.value = CityData.get_slot_progress_ratio(int(parts[0]), int(parts[1]))
        # We keep the tooltip fresh: "X/Y (T sec)" — the filling of the
        # ingredients and how many seconds have passed since the start of the
        # crafting.
        var status_text = CityData.get_slot_status_text(int(parts[0]), int(parts[1]))
        if get_viewport().gui_get_hovered_control() == craft_bar:
            _update_craft_bar_tooltip(craft_bar, status_text)
    for key in stale:
        _slot_progress_bars.erase(key)

func _on_craft_bar_mouse_entered(craft_bar: ProgressBar):
    _update_craft_bar_tooltip(craft_bar, CityData.get_slot_status_text(
        _get_craft_bar_index(craft_bar), _get_craft_bar_slot(craft_bar)))

func _on_craft_bar_mouse_exited():
    if ui_helpers != null and is_instance_valid(ui_helpers):
        ui_helpers.hide_progress_tooltip()

func _update_craft_bar_tooltip(craft_bar: ProgressBar, status_text: String):
    if ui_helpers == null or not is_instance_valid(ui_helpers):
        return
    ui_helpers.progress_tooltip_label.text = tr("Crafting \"%s\": %s") % [
        str(craft_bar.get_meta("craft_name", "")),
        status_text if not status_text.is_empty() else "—"
    ]
    ui_helpers.show_progress_tooltip(get_viewport().get_mouse_position())
    ui_helpers.progress_tooltip_panel.visible = true

func _get_craft_bar_index(craft_bar: ProgressBar) -> int:
    for key in _slot_progress_bars:
        if _slot_progress_bars[key] == craft_bar:
            return int(str(key).split(":", false)[0])
    return -1

func _get_craft_bar_slot(craft_bar: ProgressBar) -> int:
    for key in _slot_progress_bars:
        if _slot_progress_bars[key] == craft_bar:
            return int(str(key).split(":", false)[1])
    return -1

# Hovering the "Upgrade" button: we fill the tooltip with the icons and show it
# next to the button. The plain tooltip_text is not able to show pictures,
# therefore a panel of its own, upgrade_tooltip_panel, is used.
func _on_upgrade_btn_hovered(btn: Button, b_index: int):
    if upgrade_tooltip_panel == null or ui_helpers == null:
        return
    if not _fill_upgrade_tooltip_content(b_index):
        _hide_upgrade_tooltip()
        return
    _show_upgrade_tooltip_panel(btn)

# Fills the content of the upgrade tooltip: the header "Upgrade to <icon>
# "Name"", the labour, the materials line by line ("<icon> Planks x8"), the
# additional_req condition.
# Returns false if there is nothing to show.
func _fill_upgrade_tooltip_content(b_index: int) -> bool:
    # We clear the previous content (remove_child + queue_free — as in
    # ui_helpers.show_group_tooltip, so that the size is recalculated correctly).
    for child in upgrade_tooltip_content.get_children():
        upgrade_tooltip_content.remove_child(child)
        child.queue_free()

    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return false
    var from_id: String = CityData.city_built_buildings[b_index].get("id", "")
    var upgrade_to: String = CityData.get_building_upgrade_target(from_id)
    if upgrade_to == "":
        return false
    var up_data = null
    for b in GameData.buildings:
        if b["id"] == upgrade_to:
            up_data = b
            break
    if up_data == null:
        return false

    # The header: "Upgrade to" + the icon of the improved building + the name in
    # quotes.
    var header = HBoxContainer.new()
    header.add_theme_constant_override("separation", 6)
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var header_label = Label.new()
    header_label.text = tr("Upgrade to")
    header_label.add_theme_font_size_override("font_size", 16)
    header_label.add_theme_color_override("font_color", Color.WHITE)
    header_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    header.add_child(header_label)
    var icon_name = String(up_data.get("icon", ""))
    if not icon_name.is_empty():
        var tex = IconRegistry.get_texture(icon_name)
        if tex:
            var icon_rect = TextureRect.new()
            icon_rect.texture = tex
            icon_rect.custom_minimum_size = Vector2(24, 24)
            icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
            icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
            header.add_child(icon_rect)
    var name_label = Label.new()
    name_label.text = "«%s»" % up_data.get("name", upgrade_to)
    name_label.add_theme_font_size_override("font_size", 16)
    name_label.add_theme_color_override("font_color", Color.WHITE)
    name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    header.add_child(name_label)
    upgrade_tooltip_content.add_child(header)

    # The labour — the same as for the actual upgrade (with the construction
    # modifier).
    var work_cost = int(ceil(float(up_data.get("work_cost", 0)) * MapHelpers.get_construction_cost_mult()))
    if work_cost > 0:
        var labor_label = Label.new()
        labor_label.text = tr("Work: %d") % work_cost
        labor_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        labor_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        upgrade_tooltip_content.add_child(labor_label)

    # The materials: a row "<icon> Name xN" for every resource of every batch of
    # additional_cost. The icons and the group references are given by
    # ui_helpers.make_resource_entry.
    if up_data.has("additional_cost"):
        var bundles = GameData.parse_additional_cost(up_data["additional_cost"])
        var products_data = _get_all_resources()
        for bundle in bundles:
            for res_id in bundle:
                upgrade_tooltip_content.add_child(ui_helpers.make_resource_entry(
                    res_id, products_data, int(bundle[res_id])))

    var additional_req = String(up_data.get("additional_req", ""))
    if additional_req != "":
        var req_label = Label.new()
        req_label.text = tr("Requirement: city access to fresh water") if additional_req == "running_water" else tr("Requirement: ") + additional_req
        req_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        req_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        upgrade_tooltip_content.add_child(req_label)

    return true

# The size, the position and the showing of the tooltip: under the button (as the
# popups of the recipe selection), with a shift inside the screen at the edges.
func _show_upgrade_tooltip_panel(btn: Button):
    upgrade_tooltip_content.reset_size()
    var content_min_size = upgrade_tooltip_content.get_minimum_size()
    var pad_left = 6
    var pad_top = 6
    var pad_right = 6
    var pad_bottom = 6
    upgrade_tooltip_content.position = Vector2(pad_left, pad_top)
    upgrade_tooltip_panel.size = content_min_size + Vector2(pad_left + pad_right, pad_top + pad_bottom)
    var btn_rect = btn.get_global_rect()
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = btn_rect.position + Vector2(0, btn_rect.size.y + 4)
    pos.x = clampf(pos.x, 0.0, maxf(0.0, viewport_size.x - upgrade_tooltip_panel.size.x))
    pos.y = clampf(pos.y, 0.0, maxf(0.0, viewport_size.y - upgrade_tooltip_panel.size.y))
    upgrade_tooltip_panel.position = pos
    upgrade_tooltip_panel.show()

func _hide_upgrade_tooltip():
    if upgrade_tooltip_panel != null:
        upgrade_tooltip_panel.hide()

# The handler of the "Upgrade" button: it starts the upgrade of the building; on
# failure it shows the reason in the message line of the city interface.
func _on_upgrade_pressed(b_index: int):
    var result = CityData.start_building_upgrade(b_index)
    if not result.get("ok", false):
        var city_ui = get_tree().root.find_child("CityUi", true, false)
        if city_ui and city_ui.has_method("set_message"):
            city_ui.set_message(String(result.get("reason", "")))
        return
    # We rebuild the panel: instead of the button the progress bar of the upgrade
    # will appear.
    # We hide the open popups before rebuilding the slots, so that they do not
    # refer to the elements being removed.
    for p in popups_list:
        if is_instance_valid(p) and p.visible:
            p.hide()
    _refresh()

func _on_slot_button_pressed(b_index: int, slot_idx: int, popup, button):
    # We close the other open popups
    for p in popups_list:
        if is_instance_valid(p) and p != popup and p.visible:
            p.hide()
    # We recalculate the size of the window for the content
    popup.reset_size()
    # We position the popup right under the button
    popup.position = button.global_position + Vector2(0, button.size.y)
    popup.popup()
    open_popup = popup

func _on_craft_item_selected(b_index: int, slot_idx: int, craft_id: String, popup, button):
    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return
    var bld = CityData.city_built_buildings[b_index]
    var slots = bld.get("slots", [])
    if slot_idx < slots.size():
        slots[slot_idx] = craft_id
        bld["slots"] = slots
        # The new recipe may have a different time (time) — the accumulated
        # progress of the slot is reset, so that the old crafting is not
        # "finished off".
        CityData.reset_slot_progress(b_index, slot_idx)
        _update_slot_button(button, craft_id)
    popup.hide()
    open_popup = null
    if ui_helpers:
        ui_helpers.hide_group_tooltip()
    CityData.emit_signal("city_updated")

# Builds the content of the row: "[icon] Required resource [xN] -> [icon] Product
# [xN]"
# For the group resources (@...) it is a label with a tooltip.
# If the resources and the result are empty (the recipe "Empty"), we show the name
# of the recipe.
# Builds the contents of the recipe row. craft_resources may be a Dictionary
# (the classical form) or an Array (the alternative ingredients): both are
# normalized by GameData.craft_alternatives().
func _make_craft_content(craft_name: String, craft_resources, craft_result: Dictionary) -> HBoxContainer:
    var content = HBoxContainer.new()
    content.add_theme_constant_override("separation", 6)
    content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    content.mouse_filter = Control.MOUSE_FILTER_IGNORE

    # A recipe without resources and result (for example, "Empty") — we show only
    # the name
    if craft_resources.is_empty() and craft_result.is_empty():
        var empty_label = Label.new()
        empty_label.text = craft_name
        empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(empty_label)
        return content

    # The required resources in the normalized form: an array of OR-groups (see
    # the alternative ingredients in GameData). A group with one variant is drawn
    # as an ordinary ingredient; with several — the variants are separated by "/"
    # ("any of the listed is enough").
    var first_res = true
    for or_group in GameData.craft_alternatives({"resources": craft_resources}):
        if or_group.is_empty():
            continue
        if not first_res:
            var sep_label = Label.new()
            sep_label.text = "+"
            sep_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            sep_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(sep_label)
        first_res = false

        var first_variant = true
        for variant in or_group:
            if not first_variant:
                var or_label = Label.new()
                or_label.text = "/"
                or_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4))
                or_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(or_label)
            first_variant = false

            # A group resource — a label with a tooltip (through the single helper).
            # We use MOUSE_FILTER_PASS, so that the hover shows the tooltip and the
            # click passes through to the parent button (the recipe selection).
            content.add_child(ui_helpers.make_resource_entry(str(variant.get("key", "")), _get_all_resources()))
            var amount = int(variant.get("amount", 0))
            if amount >= 1:
                var amount_label = Label.new()
                amount_label.text = "x%d" % amount
                amount_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
                amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(amount_label)

    # The arrow
    if not craft_resources.is_empty() and not craft_result.is_empty():
        var arrow_label = Label.new()
        arrow_label.text = "->"
        arrow_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
        arrow_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(arrow_label)

    # The producible products
    var first_prod = true
    for prod_id in craft_result:
        if not first_prod:
            var sep_label = Label.new()
            sep_label.text = ","
            sep_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            sep_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(sep_label)
        first_prod = false

        var pdata = products.get(prod_id, {})
        var icon_name = pdata.get("icon", "")
        var tex = _get_icon_texture(icon_name)
        if tex:
            var icon_rect = TextureRect.new()
            icon_rect.texture = tex
            icon_rect.custom_minimum_size = Vector2(24, 24)
            icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
            icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(icon_rect)
        var prod_label = Label.new()
        prod_label.text = pdata.get("name", prod_id)
        prod_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(prod_label)
        var amount = craft_result[prod_id]
        if amount >= 1:
            var amount_label = Label.new()
            amount_label.text = "x%d" % amount
            amount_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(amount_label)

    return content

# The human-readable name of a recipe by its id (for the tooltips; an unknown id is
# left as is).
func _get_craft_name(craft_id: String) -> String:
    for c in crafts_data:
        if c.get("id", "") == craft_id:
            return str(c.get("name", craft_id))
    return craft_id

# Updates the content of the recipe selection button: the icons are drawn next to
# the products, and not at the left edge
func _update_slot_button(button, craft_id: String):
    var craft_name = craft_id
    var craft_resources = {}
    var craft_result = {}
    for c in crafts_data:
        if c["id"] == craft_id:
            craft_name = c.get("name", craft_id)
            craft_resources = c.get("resources", {})
            # display_result — a UI hint for the "non-material" outputs
            # (science and the future pseudo-resources): it is not read by the
            # mechanics.
            craft_result = c.get("display_result", c.get("result", {}))
            break
    # We remove the old content of the button
    for child in button.get_children():
        child.queue_free()
    var content = _make_craft_content(craft_name, craft_resources, craft_result)
    content.set_anchors_preset(Control.PRESET_FULL_RECT)
    content.offset_left = 8
    content.offset_right = -8
    # We pass the minimum width of the content to the button, so that a long
    # recipe is taken into account by the parent row when the width of the panel
    # is calculated.
    button.custom_minimum_size.x = content.get_minimum_size().x + 16
    button.add_child(content)

func _input(event: InputEvent):
    if not visible:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        # If any popup is open, a click outside the panel closes only the popup
        open_popup = null
        for p in popups_list:
            if is_instance_valid(p) and p.visible:
                open_popup = p
                break
        if open_popup != null:
            var popup_rect = Rect2(open_popup.position, open_popup.size)
            if not panel.get_global_rect().has_point(event.global_position) and not popup_rect.has_point(event.global_position):
                open_popup.hide()
                get_viewport().set_input_as_handled()
            return
        # A click outside the panel (on the dimming) closes it
        if not panel.get_global_rect().has_point(event.global_position):
            if ui_helpers:
                ui_helpers.hide_group_tooltip()
            hide()
            get_viewport().set_input_as_handled()

func _get_icon_texture(icon_file: String) -> Texture2D:
    return IconRegistry.get_texture(icon_file)

func _on_close_pressed():
    if ui_helpers:
        ui_helpers.hide_group_tooltip()
    _hide_upgrade_tooltip()
    hide()

# Returns the merged dictionary of all the resources (the raw materials + the goods)
func _get_all_resources() -> Dictionary:
    var all = {}
    for key in raw_resources:
        all[key] = raw_resources[key]
    for key in products:
        all[key] = products[key]
    return all

# Returns the icon name of a resource (from the goods or from the raw materials)
func _get_resource_icon(res_id: String) -> String:
    if products.has(res_id):
        return products[res_id].get("icon", "")
    if raw_resources.has(res_id):
        return raw_resources[res_id].get("icon", "")
    return ""

# Returns the human-readable name of a resource (from the goods or from the raw materials)
func _get_resource_name(res_id: String) -> String:
    if products.has(res_id):
        return products[res_id].get("name", res_id)
    if raw_resources.has(res_id):
        return raw_resources[res_id].get("name", res_id)
    return res_id
