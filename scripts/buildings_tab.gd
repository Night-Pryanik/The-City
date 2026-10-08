# buildings_tab.gd
extends Node

var ui_helpers: Node
var products: Dictionary = {}
var raw_resources: Dictionary = {}
var buildings_data: Array = []
var crafts_data: Array = []
var city_storage: Dictionary = {}
var city_food_pool: Dictionary = {}
var built_buildings: Array = []
var selected_building_id: String = ""

var buildings_list: VBoxContainer
var buildings_group: ButtonGroup
var build_button: Button
var built_buildings_list: Node
var food_label: Label
var last_built_count: int = -1
var last_construction_count: int = -1
var _cached_build_manager = null

# The button of the selected building and the dictionary id -> button (for the details tooltip).
var selected_button: Button = null
var _hovered_building_id: String = "" # the building under the cursor (for the details tooltip)
var building_buttons: Dictionary = {}
var _detail_material_rows: Array = []
var _detail_requirement_label: Label = null
# The last "era" of the resource display (CityData.resource_display_interval):
# the live update of the "Required/in storage" row in the building details tooltip waits
# for the era to come, and does not run every tick. The initial building of the tooltip
# (_show_building_details, on hover) remains instantaneous.
var _display_epoch: int = -1

var resume_icon: Texture2D
var pause_icon: Texture2D
var info_icon: Texture2D

# The rows of the buildings under construction: build_key -> { "row": HBoxContainer, "bar": ProgressBar, "pause_btn": Button }
var construction_rows: Dictionary = {}

# The last signature of the grouping of the built buildings ("id:total|id:total").
# A building upgrade replaces its id without changing the total number of buildings, — by the signature
# update_built_status understands that the list has to be rebuilt.
var _last_groups_signature: String = ""

# The tooltip of the built building under the cursor: the button and the index of its group in the list.
# The tooltip panel itself lives in ui_helpers (built_tooltip_panel).
var _hovered_built_btn: Button = null
var _hovered_built_group_index: int = -1

signal build_requested(building_id: String)
signal building_detail_requested(building_id: String)

func setup(list: Node, btn: Button, built_list: Node, food_lbl: Label, helpers: Node):
    buildings_list = list as VBoxContainer
    build_button = btn
    built_buildings_list = built_list
    food_label = food_lbl
    ui_helpers = helpers

    set_process(true)

    # A single radio group for the list of available builds: clicking one button
    # automatically unpresses the others. allow_unpress=false forbids "unpressing"
    # the already selected button — exactly one building is selected at any moment.
    buildings_group = ButtonGroup.new()
    buildings_group.allow_unpress = false

    if not build_button.pressed.is_connected(_on_build_pressed):
        build_button.pressed.connect(_on_build_pressed)
    build_button.disabled = true

func _process(delta):
    # We update the progress bars of the buildings under construction every frame,
    # so that they are smooth (like the progress bars of the improvements on the map).
    if construction_rows.size() > 0:
        _update_construction_rows()

func _get_build_manager():
    if _cached_build_manager == null or not is_instance_valid(_cached_build_manager):
        var main_map = get_tree().root.find_child("MainMap", true, false)
        _cached_build_manager = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
    return _cached_build_manager

func update_data(data: Dictionary):
    products = data.get("products", {})
    raw_resources = data.get("raw_resources", {})
    buildings_data = data.get("buildings_data", [])
    crafts_data = data.get("crafts_data", [])
    city_storage = data.get("city_storage", {})
    city_food_pool = data.get("city_food_pool", {})
    built_buildings = data.get("built_buildings", [])
    # The live update of the "Required/in storage" row in the open details tooltip —
    # with the resource display interval, and not every tick.
    if CityData.resource_display_due(_display_epoch):
        _display_epoch = CityData.resource_display_epoch
        refresh_building_detail_tooltip()

func refresh_list():
    for child in buildings_list.get_children():
        buildings_list.remove_child(child)
        child.queue_free()
    selected_building_id = ""
    selected_button = null
    building_buttons.clear()
    build_button.disabled = true
    # We hide the messages and the tooltips when updating the list
    if ui_helpers:
        ui_helpers.set_message("")
        ui_helpers.hide_group_tooltip()
        ui_helpers.hide_building_detail_tooltip()
    food_label.visible = false
    for bld in buildings_data:
        # We filter the buildings: we show only those unlocked by the researched technologies
        if not CityData.is_building_unlocked(bld["id"]):
            continue
        var item_btn = Button.new()
        item_btn.text = bld["name"]
        item_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
        item_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        item_btn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
        item_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        item_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        item_btn.toggle_mode = true
        item_btn.button_group = buildings_group
        item_btn.tooltip_text = ""
        # The building icon before the name (the file from buildings.json). If the icon file
        # does not exist yet — we simply output the name without the icon;
        # when the file appears, the icon will be picked up automatically.
        var building_icon = _get_icon_texture_from_paths(bld.get("icon", ""))
        if building_icon:
            item_btn.icon = building_icon
            item_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
            item_btn.add_theme_constant_override("icon_max_width", 40)
        item_btn.pressed.connect(_on_building_list_pressed.bind(bld["id"]))
        item_btn.mouse_entered.connect(_on_building_hovered.bind(bld["id"]))
        item_btn.mouse_exited.connect(_on_building_unhovered.bind(bld["id"]))
        buildings_list.add_child(item_btn)
        building_buttons[bld["id"]] = item_btn

func update_built_status():
    # A light refresh: we update the status text without recreating the rows.
    if built_buildings.size() != last_built_count \
            or _get_active_building_construction_count() != last_construction_count:
        refresh_built()
        return

    # The "Build" button stays active even when the build limit is reached,
    # so that on a click it could show the message with the reason for the refusal.
    # It is blocked only when no building is selected.
    if build_button:
        build_button.disabled = (selected_building_id == "")

    # We update the progress bars of the buildings under construction
    _update_construction_rows()

    # We group the buildings by id and update the text, the colour and the tooltip of the buttons.
    var groups = _group_buildings()
    # An upgrade changes the id of a building without changing their total number (a hand mill
    # is replaced by a mill with animal traction) — we catch this by the signature
    # of the grouping and rebuild the list, otherwise stale buttons would remain.
    var groups_signature = _groups_signature(groups)
    if groups_signature != _last_groups_signature:
        _last_groups_signature = groups_signature
        refresh_built()
        return
    for g in range(groups.size()):
        var item_btn = built_buildings_list.get_child(g + construction_rows.size())
        if item_btn == null or not (item_btn is Button):
            continue
        var group = groups[g]
        var bdata = null
        for b in buildings_data:
            if b["id"] == group["id"]:
                bdata = b
                break
        var base_name = bdata["name"] if bdata else group["id"]

        var display_name = "%s x%d" % [base_name, group["total"]] if group["total"] > 1 else base_name
        var status_info = _get_built_status_info(group["working"], group["idle"], group["total"])

        item_btn.text = display_name
        _apply_built_status_color(item_btn, status_info["color"])

    # The tooltip of the built building under the cursor is updated live: the states
    # change on the ticks (the assignment of workers, the start/completion of an upgrade),
    # while the user keeps the cursor on the button and reads the list.
    if _hovered_built_btn != null and is_instance_valid(_hovered_built_btn) \
            and ui_helpers != null and ui_helpers.built_tooltip_panel != null \
            and ui_helpers.built_tooltip_panel.visible:
        _show_built_tooltip(_hovered_built_btn, _hovered_built_group_index)

func refresh_built():
    for child in built_buildings_list.get_children():
        child.queue_free()
    construction_rows.clear()
    # The list buttons are recreated — the tooltip could remain hanging over a removed
    # button (its mouse_exited will no longer fire), so we hide it explicitly.
    _hide_built_tooltip()
    last_built_count = built_buildings.size()
    last_construction_count = _get_active_building_construction_count()

    # First the rows of the buildings under construction
    _refresh_construction_rows()

    # We group the buildings of the same type
    var groups = _group_buildings()

    for group_index in range(groups.size()):
        var g = groups[group_index]
        var bdata = null
        for b in buildings_data:
            if b["id"] == g["id"]:
                bdata = b
                break
        var base_name = bdata["name"] if bdata else g["id"]
        var display_name = "%s x%d" % [base_name, g["total"]] if g["total"] > 1 else base_name
        var status_info = _get_built_status_info(g["working"], g["idle"], g["total"])

        # A group of built buildings of the same type — a button-row in the style of the list
        # of available builds. A click opens the building details panel
        # (the functionality of the former separate "More" button).
        var item_btn = Button.new()
        item_btn.text = display_name
        item_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
        item_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        item_btn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
        item_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        item_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        _apply_built_status_color(item_btn, status_info["color"])

        # The tooltip with coloured states — its own panel (the ordinary
        # tooltip_text does not support colours), it is shown on hover.
        item_btn.mouse_entered.connect(_on_built_btn_hovered.bind(item_btn, group_index))
        item_btn.mouse_exited.connect(_on_built_btn_unhovered)

        # The building icon before the name (as in the list of available builds).
        var building_icon = _get_icon_texture_from_paths(bdata.get("icon", "")) if bdata else null
        if building_icon:
            item_btn.icon = building_icon
            item_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
            item_btn.add_theme_constant_override("icon_max_width", 40)

        item_btn.pressed.connect(_on_building_slots_pressed.bind(g["id"]))

        built_buildings_list.add_child(item_btn)
    last_built_count = built_buildings.size()
    _last_groups_signature = _groups_signature(groups)

    # The "Build" button stays active even when the build limit is reached,
    # so that on a click it could show the message with the reason for the refusal.
    # It is blocked only when no building is selected.
    if build_button:
        build_button.disabled = (selected_building_id == "")

# Creates the rows of the buildings under construction in the built buildings panel.
func _refresh_construction_rows():
    var constructions: Dictionary = {}
    for build_key in CityData.building_construction.keys():
        constructions[build_key] = CityData.building_construction[build_key]

    # The upgrades do not add an entry to CityData.building_construction: they
    # live in the same BuildManager pool as the ordinary building builds.
    var bm = _get_build_manager()
    if bm:
        for build_key in bm.active_building_builds.keys():
            if not constructions.has(build_key):
                constructions[build_key] = bm.active_building_builds[build_key]

    for build_key in constructions.keys():
        var construction_data = constructions[build_key]
        var building_id = construction_data.get("building_id", "")
        var is_upgrade = construction_data.get("is_upgrade", false)
        var display_id = construction_data.get("upgrade_to", building_id) \
            if is_upgrade else building_id
        var bdata = null
        for b in buildings_data:
            if b["id"] == display_id:
                bdata = b
                break
        var base_name = bdata["name"] if bdata else display_id
        if is_upgrade:
            base_name = tr("Improvement: ") + base_name

        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 6)
        row.alignment = BoxContainer.ALIGNMENT_CENTER

        var label = Label.new()
        label.text = base_name
        label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
        label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        row.add_child(label)

        var bar = ProgressBar.new()
        bar.custom_minimum_size = Vector2(80, 14)
        bar.max_value = 100.0
        bar.show_percentage = false
        bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        row.add_child(bar)

        # The pause/resume button of the construction or the upgrade.
        var pause_btn = Button.new()
        pause_btn.custom_minimum_size = Vector2(28, 28)
        pause_btn.expand_icon = true
        pause_btn.icon = _get_icon("pause")
        pause_btn.tooltip_text = tr("Pause upgrade") \
            if is_upgrade else tr("Pause construction")
        pause_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        pause_btn.pressed.connect(_on_construction_pause_pressed.bind(build_key))
        row.add_child(pause_btn)

        # The cancel button of the construction or the upgrade.
        var cancel_btn = Button.new()
        cancel_btn.custom_minimum_size = Vector2(28, 28)
        cancel_btn.text = "✕"
        cancel_btn.tooltip_text = tr("Cancel upgrade") if is_upgrade else tr("Cancel construction")
        cancel_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        cancel_btn.pressed.connect(_on_construction_cancel_pressed.bind(build_key))
        row.add_child(cancel_btn)

        built_buildings_list.add_child(row)
        construction_rows[build_key] = {
            "row": row,
            "bar": bar,
            "pause_btn": pause_btn,
            "cancel_btn": cancel_btn,
            "is_upgrade": is_upgrade
        }

# Updates the progress bars and the buttons of the buildings and upgrades under construction.
func _update_construction_rows():
    var bm = _get_build_manager()
    if not bm:
        return
    for build_key in construction_rows.keys():
        var row_data = construction_rows[build_key]
        if not is_instance_valid(row_data["row"]):
            continue
        var progress_data = bm.get_building_build_progress(build_key)
        if progress_data.is_empty():
            continue

        var work_cost = progress_data.get("work_cost", 1)
        var progress_value = min(progress_data.get("progress", 0.0), work_cost)
        var percent = 0.0
        if work_cost > 0:
            percent = progress_value / work_cost * 100.0
        var status = progress_data.get("status", "active")
        var bar = row_data["bar"]
        bar.value = percent

        var pause_btn = row_data["pause_btn"]
        var action_name = tr("upgrade") if row_data.get("is_upgrade", false) else tr("construction")
        if status == "paused":
            pause_btn.icon = _get_icon("resume")
            pause_btn.tooltip_text = tr("Resume ") + action_name
        else:
            pause_btn.icon = _get_icon("pause")
            pause_btn.tooltip_text = tr("Pause ") + action_name

func _get_active_building_construction_count() -> int:
    var bm = _get_build_manager()
    if bm:
        return bm.active_building_builds.size()
    return CityData.building_construction.size()

# Returns the data about the progress bar of the building under construction under the cursor.
# It returns an empty dictionary if the cursor is not over any of the bars.
func get_hovered_construction_bar(mouse_pos: Vector2) -> Dictionary:
    var bm = _get_build_manager()
    if not bm:
        return {}
    for build_key in construction_rows.keys():
        var row_data = construction_rows[build_key]
        if not is_instance_valid(row_data["bar"]):
            continue
        var bar = row_data["bar"]
        if bar.get_global_rect().has_point(mouse_pos):
            var progress_data = bm.get_building_build_progress(build_key)
            if progress_data.is_empty():
                continue
            var work_cost = progress_data.get("work_cost", 1)
            var progress_value = min(progress_data.get("progress", 0.0), work_cost)
            var percent = 0.0
            if work_cost > 0:
                percent = progress_value / work_cost * 100.0
            var status = progress_data.get("status", "active")
            var status_text = tr("Under construction")
            if status == "paused":
                status_text = tr("Paused")
            return {
                "bar": bar,
                "status_text": status_text,
                "percent": percent
            }
    return {}

# Returns the status of the group of built buildings: the text and the colour for the button.
# idle — the buildings that have a worker, but all the slots are empty (they are idle).
# The colour coding is preserved: green = working, red = not working,
# yellow = part of the group is working, orange = idle.
func _get_built_status_info(working: int, idle: int, total: int) -> Dictionary:
    var text = ""
    var color = Color.WHITE
    if idle > 0:
        # There are idle buildings (there is a worker, but all the slots are empty)
        if total > 1:
            if idle == total:
                text = tr("idle")
            else:
                text = tr("%d of %d working, %d idle") % [working, total, idle]
        else:
            text = tr("idle")
        color = Color.ORANGE
    elif total > 1:
        text = tr("%d of %d working") % [working, total]
        color = Color.GREEN if working == total else (Color.YELLOW if working > 0 else Color.RED)
    else:
        text = tr("working") if working > 0 else tr("not working")
        color = Color.GREEN if working > 0 else Color.RED
    return {"text": text, "color": color}

# Fills the tooltip panel of the built building: the heading, the bulleted
# list of the states with the colour coding, the footer. The content is assembled in
# ui_helpers.built_tooltip_content; the positioning is in show_built_tooltip().
func _fill_built_tooltip(group: Dictionary):
    var content: VBoxContainer = ui_helpers.built_tooltip_content
    # We clear the previous contents (remove_child + queue_free — as in
    # ui_helpers.show_group_tooltip, so that the size is recalculated correctly).
    for child in content.get_children():
        content.remove_child(child)
        child.queue_free()

    var title = Label.new()
    title.text = _built_group_title(group)
    title.add_theme_font_size_override("font_size", 16)
    title.add_theme_color_override("font_color", Color.WHITE)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(title)

    var states = _get_built_states(group)
    for state in states:
        var name: String = state[0]
        var detail: String = state[1]
        var state_color: Color = state[2]
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 6)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var indent = Control.new()
        indent.custom_minimum_size = Vector2(14, 0)
        indent.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(indent)
        var bullet = Label.new()
        bullet.text = "•"
        bullet.add_theme_color_override("font_color", state_color)
        bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(bullet)
        var value_label = Label.new()
        value_label.text = name if detail == "" else "%s: %s" % [name, detail]
        value_label.add_theme_color_override("font_color", state_color)
        value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(value_label)
        content.add_child(row)

    var footer = Label.new()
    footer.text = tr("Click — building control panel")
    footer.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(footer)

# The heading of the group for the tooltip: "Hand mill x2" / "Hand mill".
func _built_group_title(group: Dictionary) -> String:
    var bdata = null
    for b in buildings_data:
        if b["id"] == group["id"]:
            bdata = b
            break
    var base_name = bdata.get("name", group["id"]) if bdata else group["id"]
    return "%s x%d" % [base_name, group["total"]] if group["total"] > 1 else base_name

# Shows the tooltip of the built building under the list button (with a live
# update of the content on every call, while the cursor is on the button).
func _show_built_tooltip(btn: Button, group_index: int):
    if ui_helpers == null:
        return
    var groups = _group_buildings()
    if group_index < 0 or group_index >= groups.size():
        _hide_built_tooltip()
        return
    _fill_built_tooltip(groups[group_index])
    var btn_rect = btn.get_global_rect()
    ui_helpers.show_built_tooltip(btn_rect.position + Vector2(0, btn_rect.size.y + 4))

# Hovering over the button of a built building: we remember it and show the tooltip.
func _on_built_btn_hovered(btn: Button, group_index: int):
    _hovered_built_btn = btn
    _hovered_built_group_index = group_index
    _show_built_tooltip(btn, group_index)

# The cursor leaves the button of a built building: we hide the tooltip.
func _on_built_btn_unhovered():
    _hide_built_tooltip()

# Hides the tooltip of the built building and resets the hovered button.
func _hide_built_tooltip():
    _hovered_built_btn = null
    _hovered_built_group_index = -1
    if ui_helpers != null:
        ui_helpers.hide_built_tooltip()

# Assembles the list of the states of the group of built buildings for the tooltip: each
# state — a triple [name, detail, colour]. Only the non-zero ones are output.
#   working — the buildings with a worker and non-empty slots (working − idle);
#     the detail — just the number of such buildings ("Working: 1");
#   idle — with a worker, but all the slots are empty (idle);
#   not working — without a worker (total − working);
#   can upgrade — the instances available for an upgrade (upgradeable; the
#     fact of availability already includes the check "the target is unlocked by a technology".
# For a single building (total == 1) the detail-counter is omitted —
# "1 of 1" is redundant. The colours are from the button/label palette of the project.
func _get_built_states(group: Dictionary) -> Array:
    var working = int(group.get("working", 0))
    var idle = int(group.get("idle", 0))
    var total = int(group.get("total", 0))
    var upgradeable = int(group.get("upgradeable", 0))

    const COLOR_WORKS := Color(0.35, 1.0, 0.35)
    const COLOR_IDLE := Color.YELLOW
    const COLOR_OFF := Color(1.0, 0.35, 0.35)
    const COLOR_UPGRADE := Color(0.6, 0.8, 1.0)

    var states = []
    if total > 1:
        var properly_working = working - idle
        if properly_working > 0:
            states.append([tr("working"), "%d" % properly_working, COLOR_WORKS])
        if idle > 0:
            states.append([tr("idle"), "%d" % idle, COLOR_IDLE])
        var not_working = total - working
        if not_working > 0:
            states.append([tr("not working"), "%d" % not_working, COLOR_OFF])
    else:
        if idle > 0:
            states.append([tr("idle"), "", COLOR_IDLE])
        elif working > 0:
            states.append([tr("working"), "", COLOR_WORKS])
        else:
            states.append([tr("not working"), "", COLOR_OFF])

    if upgradeable > 0:
        states.append([tr("upgradeable"), "%d" % upgradeable, COLOR_UPGRADE])
    return states

# Sets the text colour of the button in all the states (normal, hover, pressed,
# focus), so that the colour coding of the state does not disappear on hover.
func _apply_built_status_color(btn: Button, color: Color):
    btn.add_theme_color_override("font_color", color)
    btn.add_theme_color_override("font_hover_color", color)
    btn.add_theme_color_override("font_pressed_color", color)
    btn.add_theme_color_override("font_focus_color", color)

# Groups the built buildings by id and counts the working ones.
# idle — the buildings that have a worker, but all the slots are empty (they are idle).
# upgradeable — how many instances of the group can be upgraded right now
# (can_upgrade_building checks both that the target is unlocked by a technology and that
# the upgrade of this instance is not already going).
func _group_buildings() -> Array:
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null

    var groups = []
    var order = []
    for i in range(built_buildings.size()):
        var bld = built_buildings[i]
        var bld_id = bld.get("id", "")
        var has_worker = tm.has_townsfolk(i) if tm else false
        if not order.has(bld_id):
            order.append(bld_id)
            groups.append({"id": bld_id, "total": 0, "working": 0, "idle": 0, "upgradeable": 0})
        var g = null
        for grp in groups:
            if grp["id"] == bld_id:
                g = grp
                break
        g["total"] += 1
        if has_worker:
            g["working"] += 1
            if CityData.are_all_slots_empty(i):
                g["idle"] += 1
        if CityData.can_upgrade_building(i):
            g["upgradeable"] += 1
    return groups

# Assembles the signature of the grouping of the built buildings: "id:total|id:total".
# It is used to track the changes of the grouping without a change of the total
# number of buildings (an upgrade replaces the building id: hand_mill -> animal_mill).
func _groups_signature(groups: Array) -> String:
    var parts = []
    for grp in groups:
        parts.append("%s:%d" % [grp.get("id", ""), int(grp.get("total", 0))])
    return "|".join(parts)

# Returns the texture of the icon by the file name (the common IconRegistry registry).
# If there is no file or the name is empty — it returns null (then the icon is not set).
func _get_icon_texture_from_paths(icon_file: String) -> Texture2D:
    return IconRegistry.get_texture(icon_file)

func _get_icon(icon_name: String) -> Texture2D:
    if icon_name == "resume" and resume_icon:
        return resume_icon
    if icon_name == "pause" and pause_icon:
        return pause_icon
    if icon_name == "info" and info_icon:
        return info_icon

    match icon_name:
        "resume":
            resume_icon = IconRegistry.get_texture("building_resume.png")
            return resume_icon
        "pause":
            pause_icon = IconRegistry.get_texture("building_pause.png")
            return pause_icon
        "info":
            info_icon = IconRegistry.get_texture("additional_info.png")
            return info_icon
    return null

func _on_building_slots_pressed(building_id: String):
    emit_signal("building_detail_requested", building_id)

func _on_building_list_pressed(building_id: String):
    selected_button = building_buttons.get(building_id, null)
    selected_building_id = building_id
    if ui_helpers:
        ui_helpers.set_message("")
        ui_helpers.hide_group_tooltip()

    var bdata = null
    for b in buildings_data:
        if b["id"] == building_id:
            bdata = b
            break
    if bdata:
        _show_building_details(bdata)

func get_selected_button() -> Button:
    return selected_button

# --- The details tooltip on hover (any building button, not only the selected one) ---
func _on_building_hovered(building_id: String):
    if _hovered_building_id == building_id:
        return
    _hovered_building_id = building_id
    for b in buildings_data:
        if b["id"] == building_id:
            _show_building_details(b)
            break

func _on_building_unhovered(building_id: String):
    if _hovered_building_id == building_id:
        _hovered_building_id = ""

func get_hovered_button() -> Button:
    # Returns the button of the building under the cursor, if it still exists.
    if _hovered_building_id == "":
        return null
    var btn = building_buttons.get(_hovered_building_id, null)
    if btn and is_instance_valid(btn):
        return btn
    return null

func get_hovered_building_id() -> String:
    return _hovered_building_id

func refresh_building_detail_tooltip():
    if _hovered_building_id == "" or ui_helpers == null:
        return
    if not ui_helpers.detail_tooltip_panel.visible:
        return
    for material in _detail_material_rows:
        var available_amount = int(GameData.get_storage_amount(
            material["resource_id"], city_storage))
        material["amount_label"].text = "%d/%d" % [
            material["required_amount"], available_amount]
        if available_amount >= material["required_amount"]:
            material["amount_label"].modulate = Color(0.35, 1.0, 0.35)
        else:
            material["amount_label"].modulate = Color(1.0, 0.35, 0.35)

    if is_instance_valid(_detail_requirement_label):
        var requirement_check = CityData.check_building_additional_req(
            _hovered_building_id)
        if requirement_check["ok"]:
            _detail_requirement_label.modulate = Color(0.35, 1.0, 0.35)
        else:
            _detail_requirement_label.modulate = Color(1.0, 0.35, 0.35)

func _make_bullet(symbol: String) -> Label:
    var bullet = Label.new()
    bullet.text = symbol
    bullet.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return bullet

func _make_bullet_row(symbol: String, text: String) -> HBoxContainer:
    var row = HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(_make_bullet(symbol))
    var label = Label.new()
    label.text = text
    label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(label)
    return row

func _show_building_details(bdata: Dictionary):
    if not ui_helpers:
        return
    var content: VBoxContainer = ui_helpers.detail_tooltip_content
    _detail_material_rows.clear()
    _detail_requirement_label = null
    # We clear the previous contents of the tooltip.
    for child in content.get_children():
        content.remove_child(child)
        child.queue_free()

    if bdata.is_empty():
        ui_helpers.hide_building_detail_tooltip()
        return

    # The heading — the name of the building
    var title = Label.new()
    title.text = bdata["name"]
    title.add_theme_font_size_override("font_size", 18)
    title.add_theme_color_override("font_color", Color.WHITE)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(title)

    # The description of the building
    var desc = bdata.get("description", "")
    if desc != "":
        var desc_label = Label.new()
        desc_label.text = desc
        desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        # The fixed width: without it the min-height of the text with autowrap
        # is computed at a width of ~0 (huge), the tooltip jumps to the top edge
        # and "falls" to the cursor on the following frames of the layout.
        desc_label.custom_minimum_size = Vector2(420, 0)
        desc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(desc_label)

    # The heading of the cost
    var cost_header = Label.new()
    cost_header.text = tr("Cost:")
    cost_header.add_theme_font_size_override("font_size", 14)
    cost_header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    cost_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(cost_header)

    var products_data = {}
    for pid in products:
        products_data[pid] = products[pid]
    for rid in raw_resources:
        products_data[rid] = raw_resources[rid]

    var has_costs := false
    var work_cost = bdata.get("work_cost", 0)
    if work_cost > 0:
        # The cost taking the technology modifiers into account (target = "construction_cost").
        var actual_work_cost = int(ceil(float(work_cost) * MapHelpers.get_construction_cost_mult()))
        var labor = CityData.get_total_labor()
        var build_time = actual_work_cost / max(1.0, labor)
        content.add_child(_make_bullet_row("•", tr("Work: %d (%.0f sec)") % [actual_work_cost, build_time]))
        has_costs = true

    if bdata.has("additional_cost"):
        # The resources of each batch are needed (the AND logic is preserved at the data level)
        var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
        var mat_rows = []
        for bundle in bundles:
            for res_id in bundle:
                mat_rows.append([res_id, int(bundle[res_id])])
        if not mat_rows.is_empty():
            has_costs = true
            content.add_child(_make_bullet_row("•", tr("Extra materials:")))
            for entry in mat_rows:
                var required_amount: int = int(entry[1])
                var available_amount: int = int(GameData.get_storage_amount(entry[0], city_storage))
                var row = HBoxContainer.new()
                row.add_theme_constant_override("separation", 6)
                row.mouse_filter = Control.MOUSE_FILTER_IGNORE
                var indent = Control.new()
                indent.custom_minimum_size = Vector2(18, 0)
                var sub_bullet = _make_bullet("◦")
                row.add_child(indent)
                row.add_child(sub_bullet)
                var resource_entry = ui_helpers.make_resource_entry(
                    entry[0], products_data)
                row.add_child(resource_entry)
                var amount_label = Label.new()
                amount_label.text = "%d/%d" % [required_amount, available_amount]
                amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                if available_amount >= required_amount:
                    amount_label.modulate = Color(0.35, 1.0, 0.35)
                else:
                    amount_label.modulate = Color(1.0, 0.35, 0.35)
                row.add_child(amount_label)
                _detail_material_rows.append({
                    "resource_id": entry[0],
                    "required_amount": required_amount,
                    "amount_label": amount_label
                })
                content.add_child(row)

    var additional_req = String(bdata.get("additional_req", ""))
    if additional_req != "":
        has_costs = true
        var requirement_text = tr("city access to fresh water") \
                if additional_req == "running_water" else additional_req
        var requirement_row = HBoxContainer.new()
        requirement_row.add_theme_constant_override("separation", 6)
        requirement_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        requirement_row.add_child(_make_bullet("•"))
        var requirement_prefix = Label.new()
        requirement_prefix.text = tr("Requirement:")
        requirement_prefix.mouse_filter = Control.MOUSE_FILTER_IGNORE
        requirement_row.add_child(requirement_prefix)
        var requirement_label = Label.new()
        requirement_label.text = requirement_text
        requirement_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        requirement_row.add_child(requirement_label)
        var requirement_check = CityData.check_building_additional_req(bdata.get("id", ""))
        if requirement_check["ok"]:
            requirement_label.modulate = Color(0.35, 1.0, 0.35)
        else:
            requirement_label.modulate = Color(1.0, 0.35, 0.35)
        _detail_requirement_label = requirement_label
        content.add_child(requirement_row)

    if not has_costs:
        content.add_child(_make_bullet_row("•", "0"))

    # The occupational consumption of the building: the supplies that the profession
    # of a citizen in it spends (the "profession" field in data/buildings.json). It is shown
    # as a property of the building type — next to "Cost:" and before "Additional
    # output": this is a constant part of the work of the building, and not a one-off
    # expense on the construction, therefore it is visible even before the build. The format of
    # the rows is given by the common
    # ConsumptionUi — the same as in the "Consumes:" section of the hex tooltip
    # and in the left column of the control panel (see docs.md).
    var cons_rows = ConsumptionUi.build_rows_for_building(bdata.get("id", ""))
    if not cons_rows.is_empty():
        content.add_child(_make_bullet_row("•", tr("Consumes:")))
        for cons in cons_rows:
            var cons_row = HBoxContainer.new()
            cons_row.add_theme_constant_override("separation", 6)
            cons_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
            var cons_indent = Control.new()
            cons_indent.custom_minimum_size.x = 18
            cons_indent.mouse_filter = Control.MOUSE_FILTER_IGNORE
            cons_row.add_child(cons_indent)
            cons_row.add_child(_make_bullet("◦"))
            # The resource name is drawn by the common helper (the icon + for an @-group
            # the underlined name with the contents on hover), and the rate of the expense and
            # the production bonus are appended to the right.
            cons_row.add_child(ui_helpers.make_resource_entry(
                str(cons.get("display_key", "")), products_data))
            var cons_rate_label = Label.new()
            cons_rate_label.text = ": %s" % str(cons.get("rate_label", ""))
            cons_rate_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
            cons_rate_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            cons_row.add_child(cons_rate_label)
            content.add_child(cons_row)

    var additional_yield = bdata.get("additional_yield", {})
    if not additional_yield.is_empty():
        content.add_child(_make_bullet_row("•", tr("Extra output:")))
        for yield_id in additional_yield:
            var yield_row = HBoxContainer.new()
            yield_row.add_theme_constant_override("separation", 6)
            yield_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
            var yield_indent = Control.new()
            yield_indent.custom_minimum_size.x = 18
            yield_row.add_child(yield_indent, false, 0)
            yield_row.add_child(_make_bullet("◦"))
            yield_row.add_child(ui_helpers.make_resource_entry(
                yield_id, products_data,
                int(additional_yield[yield_id]), "colon"))
            content.add_child(yield_row)

    # The number of production slots
    var slots = bdata.get("production_slots", 0)
    var slots_label = Label.new()
    slots_label.text = tr("Production slots: %d") % int(slots)
    slots_label.add_theme_font_size_override("font_size", 14)
    slots_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    slots_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(slots_label)

    build_button.disabled = false
    _refresh_recipes_list(bdata)

func _on_build_pressed():
    if selected_building_id == "":
        if ui_helpers:
            ui_helpers.set_message(tr("No building selected"))
        return

    if _has_active_building_construction() and not CityData.ignore_build_requirements:
        if ui_helpers:
            ui_helpers.set_message(tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)") % CityData.total_population)
        return

    var bdata = null
    for b in buildings_data:
        if b["id"] == selected_building_id:
            bdata = b
            break
    if not bdata:
        return

    var missing_parts = []
    var work_cost = bdata.get("work_cost", 0)

    var additional_req_check = CityData.check_building_additional_req(selected_building_id)
    if not additional_req_check["ok"]:
        if ui_helpers:
            ui_helpers.set_message(additional_req_check["reason"])
        return
    
    # We check whether there is enough population for the construction
    if work_cost > 0 and not CityData.ignore_build_requirements and CityData.get_total_labor() <= 0:
        missing_parts.append(tr("at least 1 citizen is needed to build"))

    # The check of the additional materials (additional_cost) is not performed with
    # "Ignore building requirements" enabled.
    if bdata.has("additional_cost") and not CityData.ignore_build_requirements:
        # Each batch (or the single dictionary) is checked separately —
        # for the construction the resources of EACH batch are needed. The group keys
        # (@xxx) are counted as "any product from the group" — the sum over the members.
        var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
        for bundle in bundles:
            for res_id in bundle:
                var required = bundle[res_id]
                var available = GameData.get_storage_amount(res_id, city_storage)
                if available < required:
                    missing_parts.append("%s %d" % [GameData.format_resource_name(res_id), int(required)])

    if missing_parts.size() > 0:
        if ui_helpers:
            ui_helpers.set_message(tr("Missing: ") + ", ".join(missing_parts))
        return

    emit_signal("build_requested", selected_building_id)
    
    # If this building has a cost in labour - we show the message about the start of
    # the build. With "Ignore building requirements" enabled the building
    # has already been built instantly — we report that.
    if ui_helpers:
        if CityData.ignore_build_requirements:
            ui_helpers.set_message(tr("Built instantly: %s") % bdata.get("name", selected_building_id))
        elif work_cost > 0:
            var actual_work_cost = int(ceil(float(work_cost) * MapHelpers.get_construction_cost_mult()))
            var labor = CityData.get_total_labor()
            var build_time = actual_work_cost / max(1.0, labor)
            ui_helpers.set_message(tr("Construction of %s started (%.0f work, %.0f sec)") % [bdata.get("name", selected_building_id), actual_work_cost, build_time])

# Clears the list of recipes
func _has_active_building_construction() -> bool:
    # The general limit of simultaneous builds (buildings + improvements) equals the number of citizens
    var bm = _get_build_manager()
    if bm:
        return bm.get_total_active_builds() >= CityData.total_population
    return CityData.building_construction.size() >= CityData.total_population

func _on_construction_pause_pressed(build_key: String):
    var bm = _get_build_manager()
    if not bm:
        return

    if bm.is_building_build_paused(build_key):
        if bm.resume_building_build(build_key):
            if ui_helpers:
                ui_helpers.set_message(tr("Construction resumed"))
    else:
        if bm.pause_building_build(build_key):
            if ui_helpers:
                ui_helpers.set_message(tr("Construction paused"))

    _update_construction_rows()

func _on_construction_cancel_pressed(build_key: String):
    _confirm_cancel_construction(build_key)

func _confirm_cancel_construction(build_key: String):
    var dialog = ConfirmationDialog.new()
    dialog.title = tr("Confirm")
    dialog.dialog_text = tr("Cancel the construction? Spent work will be lost.")
    # We localize the standard dialog buttons (by default Godot shows
    # the English "OK" / "Cancel" — a project without translation files).
    dialog.get_ok_button().text = tr("Yes")
    dialog.get_cancel_button().text = tr("Cancel")
    add_child(dialog)

    # We pause the game while the cancel confirmation dialog is open.
    var was_paused = get_tree().paused
    get_tree().paused = true
    # The dialog must accept the input while the tree is paused.
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS

    dialog.popup_centered()
    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        _cancel_construction(build_key)
    )
    # The cross of the window and the "Cancel" button also unpause.
    dialog.canceled.connect(func():
        if not was_paused:
            get_tree().paused = false
    )

func _cancel_construction(build_key: String):
    var bm = _get_build_manager()
    if bm:
        bm.cancel_building_build(build_key)
    CityData.building_construction.erase(build_key)
    if ui_helpers:
        ui_helpers.set_message(tr("Construction cancelled"))
    CityData.emit_signal("city_updated")
    refresh_built()

# Fills the list of the available recipes for the selected building
func _refresh_recipes_list(bdata: Dictionary):
    if not ui_helpers or bdata.is_empty():
        return
    var content: VBoxContainer = ui_helpers.detail_tooltip_content

    var building_id = bdata.get("id", "")
    var available_recipes = []

    # We collect the recipes available for this building (taking the technologies into account)
    for craft in crafts_data:
        if craft["id"] == "empty":
            continue
        if not CityData.can_craft_in(craft["id"], building_id):
            continue
        var craft_unlock_tech = craft.get("unlock_tech", "")
        if craft_unlock_tech != "" and not CityData.is_tech_unlocked(craft_unlock_tech):
            continue
        available_recipes.append(craft)

    if available_recipes.is_empty():
        return

    # We sort by name
    available_recipes.sort_custom(func(a, b):
        return a.get("name", "") < b.get("name", "")
    )

    # To display the icons of resources/products we need the dictionary products + raw_resources
    # (the icons themselves are taken by ui_helpers through the common IconRegistry).
    var products_data = {}
    for pid in products:
        products_data[pid] = products[pid]
    for rid in raw_resources:
        products_data[rid] = raw_resources[rid]

    var header = Label.new()
    header.text = tr("Available recipes:")
    header.add_theme_font_size_override("font_size", 14)
    header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(header)

    # The name column is sized to the longest recipe name of the building, so that
    # the icons of the ingredients and of the products form a single vertical line
    # across all recipe rows.
    var name_column_width = 0.0
    var name_labels: Array[Label] = []

    for craft in available_recipes:
        var craft_name = craft.get("name", craft["id"])
        var craft_resources = craft.get("resources", {})
        # display_result — a UI hint for the "non-material" outputs (science and
        # future pseudo-resources): it is not read by the mechanics.
        var craft_result = craft.get("display_result", craft.get("result", {}))

        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 4)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE

        # The marker of a bulleted list
        var bullet = Label.new()
        bullet.text = "•"
        bullet.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(bullet)

        # The name of the recipe (the former format: "name: resources -> result")
        var name_label = Label.new()
        name_label.text = craft_name + ":"
        name_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(name_label)

        name_column_width = maxf(name_column_width, _measure_label_width(name_label))
        name_labels.append(name_label)

        # Resources -> result on one line
        var content_entry = _make_craft_content_local("", craft_resources, craft_result, products_data)
        content_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        content_entry.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(content_entry)

        content.add_child(row)

    # The width is applied after the whole list is scanned: only then is the
    # longest name of the building known.
    for label in name_labels:
        label.custom_minimum_size.x = name_column_width

# Returns the width of the label text in pixels for the font/size it will be drawn with.
func _measure_label_width(label: Label) -> float:
    var font = label.get_theme_font("font")
    if font == null:
        font = ThemeDB.fallback_font
    var font_size = label.get_theme_font_size("font_size")
    return font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

# Builds the contents of the recipe row: "[icon] resource [xN] + ... -> [icon] product [xN]"
# craft_resources may be a Dictionary (the classical form) or an Array (the
# alternative ingredients): both are normalized by GameData.craft_alternatives().
func _make_craft_content_local(craft_name: String, craft_resources, craft_result: Dictionary, products_data: Dictionary) -> HBoxContainer:
    var content = HBoxContainer.new()
    content.add_theme_constant_override("separation", 4)
    content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    content.mouse_filter = Control.MOUSE_FILTER_IGNORE

    if not craft_resources.is_empty():
        var first = true
        for or_group in GameData.craft_alternatives({"resources": craft_resources}):
            if or_group.is_empty():
                continue
            if not first:
                var sep = Label.new()
                sep.text = "+"
                sep.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
                sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(sep)
            first = false

            var first_variant = true
            for variant in or_group:
                if not first_variant:
                    var or_sep = Label.new()
                    or_sep.text = "/"
                    or_sep.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4))
                    or_sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
                    content.add_child(or_sep)
                first_variant = false

                content.add_child(ui_helpers.make_resource_entry(str(variant.get("key", "")), products_data))

                var amount = int(variant.get("amount", 0))
                if amount >= 1:
                    var amount_label = Label.new()
                    amount_label.text = "x%d" % amount
                    amount_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
                    amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                    content.add_child(amount_label)

    if not craft_resources.is_empty() and not craft_result.is_empty():
        var arrow = Label.new()
        arrow.text = "->"
        arrow.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
        arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(arrow)

    if not craft_result.is_empty():
        var first = true
        for prod_id in craft_result:
            if not first:
                var sep = Label.new()
                sep.text = ","
                sep.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
                sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(sep)
            first = false

            content.add_child(ui_helpers.make_resource_entry(prod_id, products_data))

            var amount = craft_result[prod_id]
            if amount >= 1:
                var amount_label = Label.new()
                amount_label.text = "x%d" % amount
                amount_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
                amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(amount_label)

    return content
