# debug_manager.gd
# The debug menu: opened/closed with F9.
# The window can be dragged by its title. Interaction with the map
# under the window is blocked while the menu is open.
extends Control

var main_map: Node
var is_open: bool = false

# The debug menu is open and shows the main menu (and not the resource selection submenu).
# It is used so that the number hotkeys fire only on the main menu items,
# without conflicting with the sub-screens.
var _in_main_menu: bool = true
# The "Toggle food consumption" button — it is kept in order to update its
# text when the state changes (otherwise the list is redrawn on the hotkey
# and the button is lost).
var _food_toggle_btn: Button
# The "Ignore technology requirements" button — similarly, it is kept for
# updating the text (the ON/OFF state) without a full redraw of the menu.
var _ignore_tech_btn: Button
# The "Ignore building requirements" button — it is kept so that we can update
# its text when the state changes (ON/OFF) without a full redraw of the menu.
var _ignore_build_btn: Button

# The mode of waiting for a click on a hex to place a resource.
var waiting_for_hex: bool = false
var pending_resource_id: String = ""

# UI elements
var _panel: Panel
var _title_bar: Panel
var _title_label: Label
var _content_vbox: VBoxContainer
var _status_label: Label

# Dragging the window by its title
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

const WINDOW_SIZE := Vector2(350, 500)
const TITLE_HEIGHT := 32

func initialize(main_node: Node):
    main_map = main_node
    # The menu is built in code, so Godot's auto-translation does not reach it:
    # an open menu is re-labelled on a language change (see _on_locale_changed).
    LocalizationManager.locale_changed.connect(_on_locale_changed)
    _build_ui()
    hide()

func _build_ui():
    # The root Control occupies the whole screen and intercepts the input,
    # blocking interaction with the map under the window.
    set_anchors_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP

    # The window panel
    _panel = Panel.new()
    _panel.position = Vector2(180, 0)
    _panel.size = WINDOW_SIZE
    _panel.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(_panel)

    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.15, 0.15, 0.15, 0.95)
    style.border_width_left = 2
    style.border_width_top = 2
    style.border_width_right = 2
    style.border_width_bottom = 2
    style.border_color = Color(0.5, 0.5, 0.5)
    _panel.add_theme_stylebox_override("panel", style)

    # The title (dragging)
    _title_bar = Panel.new()
    _title_bar.position = Vector2(0, 0)
    _title_bar.size = Vector2(WINDOW_SIZE.x, TITLE_HEIGHT)
    _title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
    _panel.add_child(_title_bar)

    var title_style = StyleBoxFlat.new()
    title_style.bg_color = Color(0.25, 0.25, 0.25, 1.0)
    _title_bar.add_theme_stylebox_override("panel", title_style)

    _title_label = Label.new()
    _title_label.text = tr("Debug menu")
    _title_label.position = Vector2(8, 6)
    _title_label.add_theme_color_override("font_color", Color.WHITE)
    _title_label.add_theme_font_size_override("font_size", 16)
    _title_bar.add_child(_title_label)

    # Dragging the window by its title
    _title_bar.gui_input.connect(_on_title_bar_gui_input)

    # The scrollable content container
    var scroll = ScrollContainer.new()
    scroll.position = Vector2(10, TITLE_HEIGHT + 10)
    scroll.size = Vector2(WINDOW_SIZE.x - 20, WINDOW_SIZE.y - TITLE_HEIGHT - 20)
    scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    _panel.add_child(scroll)

    _content_vbox = VBoxContainer.new()
    _content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _content_vbox.add_theme_constant_override("separation", 6)
    _content_vbox.mouse_filter = Control.MOUSE_FILTER_STOP
    scroll.add_child(_content_vbox)

    # The status row (hints)
    _status_label = Label.new()
    _status_label.text = ""
    _status_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _content_vbox.add_child(_status_label)

    _show_main_menu()

func _show_main_menu():
    _clear_content()
    _status_label.text = ""
    _in_main_menu = true

    var add_resource_btn = _make_button(tr("[1] Add a resource to the map"))
    add_resource_btn.pressed.connect(_on_add_resource_pressed)
    _content_vbox.add_child(add_resource_btn)

    var next_era_btn = _make_button(tr("[2] Go to the next era"))
    next_era_btn.pressed.connect(_on_next_era_pressed)
    _content_vbox.add_child(next_era_btn)

    var open_map_btn = _make_button(tr("[3] Open the whole map"))
    open_map_btn.pressed.connect(_on_open_whole_map_pressed)
    _content_vbox.add_child(open_map_btn)

    # Toggling food consumption: the 1st click — the citizens stop eating,
    # a repeated one — they start eating again. The button text reflects the
    # current state.
    _food_toggle_btn = _make_button(_food_toggle_label())
    _food_toggle_btn.pressed.connect(_on_toggle_food_consumption_pressed)
    _content_vbox.add_child(_food_toggle_btn)

    var add_food_btn = _make_button(tr("[5] Add 100 food"))
    add_food_btn.pressed.connect(_on_add_food_pressed)
    _content_vbox.add_child(add_food_btn)

    # Toggling the accounting of technology requirements: when enabled — the
    # research checks neither the prerequisites nor the era restriction.
    _ignore_tech_btn = _make_button(_ignore_tech_label())
    _ignore_tech_btn.pressed.connect(_on_toggle_ignore_tech_requirements_pressed)
    _content_vbox.add_child(_ignore_tech_btn)

    # Toggling the ignoring of building requirements: when enabled — all
    # buildings in the city and all improvements on the map are built
    # instantly, and for buildings the checks of additional materials and
    # conditions are skipped.
    _ignore_build_btn = _make_button(_ignore_build_label())
    _ignore_build_btn.pressed.connect(_on_toggle_ignore_build_requirements_pressed)
    _content_vbox.add_child(_ignore_build_btn)

    # A stub for future actions (can be extended)
    var close_btn = _make_button(tr("[0] Close (F9)"))
    close_btn.pressed.connect(toggle)
    _content_vbox.add_child(close_btn)

func _show_resource_list():
    _clear_content()
    _status_label.text = tr("Select a resource:")
    _in_main_menu = false

    var back_btn = _make_button(tr("← Back"))
    back_btn.pressed.connect(_show_main_menu)
    _content_vbox.add_child(back_btn)

    # The list of all resources from GameData.raw_resources,
    # sorted alphabetically by the display name
    var entries = []
    for res_id in GameData.raw_resources.keys():
        var res_name = GameData.raw_resources[res_id].get("name", res_id)
        entries.append([res_name.to_lower(), res_id])
    entries.sort()

    for entry in entries:
        var res_id = entry[1]
        var res_name = GameData.raw_resources[res_id].get("name", res_id)
        var btn = _make_button("%s (%s)" % [res_name, res_id])
        btn.pressed.connect(_on_resource_selected.bind(res_id))
        _content_vbox.add_child(btn)

func _on_next_era_pressed():
    # The expansion infrastructure: the whole current Region is explored
    # and joined for free, the former Ring+Region becomes the new Ring,
    # and a new Region of the same width is formed around it.
    if main_map and main_map.has_method("advance_to_next_era"):
        main_map.advance_to_next_era()

func _on_add_resource_pressed():
    _show_resource_list()

func _on_open_whole_map_pressed():
    if main_map and main_map.has_method("debug_open_whole_map"):
        main_map.debug_open_whole_map()

# Called from main_map._input by the number hotkey 1..9, 0.
# It fires only on the debug main menu (and not on the resource selection
# sub-screens and not while waiting for a click on a hex).
func trigger_hotkey(num: int):
    if not is_open or waiting_for_hex or not _in_main_menu:
        return
    match num:
        1:
            _on_add_resource_pressed()
        2:
            _on_next_era_pressed()
        3:
            _on_open_whole_map_pressed()
        4:
            _on_toggle_food_consumption_pressed()
        5:
            _on_add_food_pressed()
        6:
            _on_toggle_ignore_tech_requirements_pressed()
        7:
            _on_toggle_ignore_build_requirements_pressed()
        0:
            close()

func _on_toggle_ignore_tech_requirements_pressed():
    # We invert the debug flag CityData.ignore_tech_requirements: it removes
    # the check of the prerequisites AND the era restriction. The flag is not saved
    # in the save (see CityData). The enabled mode requires the availability of the
    # recalculated tree buttons, therefore we emit city_updated to update the UI.
    CityData.ignore_tech_requirements = not CityData.ignore_tech_requirements

    var msg := tr("Technology requirements are taken into account: the prerequisites and eras are accounted for again.")
    if CityData.ignore_tech_requirements:
        msg = tr("Technology requirements are ignored: all prerequisites and era restrictions are removed.")
    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(msg)

    if _ignore_tech_btn:
        _ignore_tech_btn.text = _ignore_tech_label()
    CityData.emit_signal("city_updated")

func _ignore_tech_label() -> String:
    return tr("[6] Ignore technology requirements (now: %s)") % _on_off(CityData.ignore_tech_requirements)

func _on_toggle_ignore_build_requirements_pressed():
    # We invert the debug flag CityData.ignore_build_requirements: it enables
    # the instant and free execution of ALL actions that spend time or
    # resources — buildings and their upgrades, improvements and special
    # actions on the map (logging, foraging, draining swamps, demolition,
    # road), scouting
    # and territory claim; for buildings the checks of
    # materials (additional_cost) and conditions (additional_req) are also
    # removed. It does not cancel the technological
    # requirements (unlock_tech) — that is a separate switch.
    # The flag is not saved in the save (see CityData).
    CityData.ignore_build_requirements = not CityData.ignore_build_requirements

    var msg := tr("Building requirements are taken into account: the actions take time and resources.")
    if CityData.ignore_build_requirements:
        msg = tr("Building requirements are ignored: everything is executed instantly and for free.")
    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(msg)

    if _ignore_build_btn:
        _ignore_build_btn.text = _ignore_build_label()
    CityData.emit_signal("city_updated")

func _ignore_build_label() -> String:
    return tr("[7] Ignore building requirements (now: %s)") % _on_off(CityData.ignore_build_requirements)

func _on_add_food_pressed():
    # We add 100 units of food to storage (wheat is a product of the food category,
    # it is included in city_food_pool and is counted as Food). We use the public
    # helper so that the storage quality breakdown stays consistent.
    CityData.add_to_storage("wheat", 100)
    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(tr("Added 100 food"))
    if main_map.city_ui and main_map.city_ui.visible:
        main_map.city_ui.refresh()
    if main_map.map_renderer:
        main_map.map_renderer.queue_redraw()

func _on_toggle_food_consumption_pressed():
    # We invert the flag of food consumption by the population (CityData.do_tick reads
    # it before writing off food from storage). The flag itself is not saved in the save.
    var now_enabled = not CityData.food_consumption_enabled
    CityData.food_consumption_enabled = now_enabled

    var msg := tr("Food consumption is disabled: the citizens have stopped eating.")
    if now_enabled:
        msg = tr("Food consumption is enabled: the citizens are eating again.")
    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(msg)

    # We update the button text in place (without a full redraw of the menu)
    if _food_toggle_btn:
        _food_toggle_btn.text = _food_toggle_label()

func _food_toggle_label() -> String:
    return tr("[4] Toggle food consumption (now: %s)") % _on_off(CityData.food_consumption_enabled)

func _on_resource_selected(res_id: String):
    pending_resource_id = res_id
    waiting_for_hex = true
    _clear_content()
    var res_name = GameData.raw_resources.get(res_id, {}).get("name", res_id)
    _status_label.text = tr("Left-click on a hex to place: %s") % res_name

    var cancel_btn = _make_button(tr("Cancel"))
    cancel_btn.pressed.connect(_cancel_waiting)
    _content_vbox.add_child(cancel_btn)

func _cancel_waiting():
    waiting_for_hex = false
    pending_resource_id = ""
    _show_main_menu()

func handle_hex_click(row: int, col: int):
    if not waiting_for_hex or pending_resource_id == "":
        return
    if not main_map.is_valid_hex(row, col):
        return

    var tile = main_map.tile_data[row][col]
    var old_res = tile.get("resource", null)
    tile["resource"] = pending_resource_id
    tile["quality"] = GameData.roll_quality()
    # If there was a breedable animal/plant on the hex (crop_bred), it
    # conflicts with the new natural resource — we reset it. Otherwise under the old
    # improvement the production cycle could mix two different resources.
    var old_crop = tile.get("crop_bred", null)
    if old_crop != null:
        tile["crop_bred"] = null

    var res_name = GameData.raw_resources.get(pending_resource_id, {}).get("name", pending_resource_id)
    var msg = tr("Resource %s placed on the hex (%d, %d)") % [res_name, row, col]
    if old_res != null:
        var old_name = GameData.raw_resources.get(old_res, {}).get("name", old_res)
        msg += tr(" (replaced: %s)") % old_name
    if old_crop != null:
        var crop_name = GameData.raw_resources.get(old_crop, {}).get("name", old_crop)
        msg += tr(" (breeding reset: %s)") % crop_name

    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(msg)

    main_map.map_renderer.queue_redraw()

    # Return to the main menu
    waiting_for_hex = false
    pending_resource_id = ""
    _show_main_menu()

func toggle():
    if is_open:
        close()
    else:
        open()

func open():
    is_open = true
    waiting_for_hex = false
    pending_resource_id = ""
    _show_main_menu()
    show()

func close():
    is_open = false
    waiting_for_hex = false
    pending_resource_id = ""
    hide()

func _clear_content():
    for child in _content_vbox.get_children():
        if child == _status_label:
            continue
        _content_vbox.remove_child(child)
        child.queue_free()

func _make_button(text: String) -> Button:
    var btn = Button.new()
    btn.text = text
    # We align the text to the left edge and allow word wrapping, so that
    # long labels do not go beyond the menu window (the buttons are stretched
    # to the container width, therefore the wrapping happens inside the window).
    btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
    btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    btn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
    btn.custom_minimum_size = Vector2(0, 32)
    btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    return btn

# --- Dragging the window by its title ---
func _on_title_bar_gui_input(event: InputEvent):
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if event.pressed:
                _dragging = true
                _drag_offset = _panel.position - event.global_position
            else:
                _dragging = false
    elif event is InputEventMouseMotion:
        if _dragging:
            _panel.position = event.global_position + _drag_offset
            # We limit the window within the screen bounds
            var viewport_size = get_viewport_rect().size
            _panel.position.x = clamp(_panel.position.x, 0, max(0, viewport_size.x - _panel.size.x))
            _panel.position.y = clamp(_panel.position.y, 0, max(0, viewport_size.y - _panel.size.y))

# The menu is built in code: Godot re-translates only the text set in the
# scene, so the visible screen is rebuilt on a language change. The rebuild
# keeps the current place — the submenu or the pending hex click.
func _on_locale_changed(_locale: String) -> void:
    if _title_label == null:
        return
    _title_label.text = tr("Debug menu")
    if waiting_for_hex and pending_resource_id != "":
        _on_resource_selected(pending_resource_id)
    elif _in_main_menu:
        _show_main_menu()
    else:
        _show_resource_list()

# The state word of a toggle row — the only part of the label that changes
# when the toggle is pressed.
func _on_off(value: bool) -> String:
    return tr("ON") if value else tr("OFF")
