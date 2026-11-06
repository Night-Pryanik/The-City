# debug_manager.gd
# The debug menu: opened/closed with F9.
# The window can be dragged by its title. Interaction with the map
# under the window is blocked while the menu is open.
extends Control

const UI_THEME = preload("res://scripts/ui_theme.gd")

var main_map: Node
var is_open: bool = false

# The screen the menu shows now. The number hotkeys fire only on the main screen,
# and a rebuild (a theme or a language change) has to return to the same place.
const VIEW_MAIN := "main"
const VIEW_RAW_LIST := "raw_list"
const VIEW_PRODUCT_LIST := "product_list"
const VIEW_PRODUCT_FORM := "product_form"
var _view: String = VIEW_MAIN

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

# The state of the "add a product to storage" screen. It lives in the manager and not
# in the widgets, so a rebuild of the menu keeps what the player has already chosen,
# and the next product starts with the amount and the quality of the previous one.
const DEFAULT_AMOUNT_TEXT := "100"
const DEFAULT_QUALITY := "common"
const MAX_AMOUNT_LENGTH := 9
var _pending_product_id: String = ""
var _pending_amount: String = DEFAULT_AMOUNT_TEXT
var _pending_quality: String = DEFAULT_QUALITY
# The search text of each list, keyed by the view it belongs to.
var _pending_filters := {VIEW_RAW_LIST: "", VIEW_PRODUCT_LIST: ""}
var _amount_edit: LineEdit

# UI elements
var _panel: Panel
var _title_bar: Panel
var _title_label: Label
var _content_vbox: VBoxContainer
var _header_vbox: VBoxContainer
var _status_label: Label

# Dragging the window by its title
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

const WINDOW_SIZE := Vector2(350, 500)
const TITLE_HEIGHT := 32
const LIST_ICON_SIZE := 24

func initialize(main_node: Node):
    main_map = main_node
    # The menu is called up to look at a stopped world, so it has to stay alive in
    # every pause of the tree: both its keys (see _input) and its clicks reach it
    # while the simulation stands still. The children inherit the mode.
    process_mode = Node.PROCESS_MODE_ALWAYS
    # The menu is built in code, so Godot's auto-translation does not reach it:
    # an open menu is re-labelled on a language change (see _on_locale_changed).
    LocalizationManager.locale_changed.connect(_on_locale_changed)
    _build_ui()
    hide()

# The keys of the menu live here and not in the map: this node keeps working during
# the pause, main_map does not. InputHandler stands earlier in the tree and takes the
# ESC chain of the windows, so it lets the key go while the menu is open.
func _input(event: InputEvent) -> void:
    if not (event is InputEventKey) or not event.pressed:
        return
    if event.keycode == KEY_F9:
        toggle()
        get_viewport().set_input_as_handled()
        return
    if not is_open:
        return
    if event.keycode == KEY_ESCAPE:
        close()
        get_viewport().set_input_as_handled()
        return
    # A digit calls the item of the main menu with that number. A sub-screen returns
    # false: the number belongs to the amount field there and must reach the widget.
    if _trigger_hotkey(_hotkey_number(event.keycode)):
        get_viewport().set_input_as_handled()

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

    # The title (dragging)
    _title_bar = Panel.new()
    _title_bar.position = Vector2(0, 0)
    _title_bar.size = Vector2(WINDOW_SIZE.x, TITLE_HEIGHT)
    _title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
    _panel.add_child(_title_bar)

    _title_label = Label.new()
    _title_label.text = tr("Debug menu")
    _title_label.position = Vector2(8, 6)
    _title_label.add_theme_font_size_override("font_size", 16)
    _title_bar.add_child(_title_label)

    # Dragging the window by its title
    _title_bar.gui_input.connect(_on_title_bar_gui_input)

    # The body of the window: the hints and the "back" button stand above the scrolling
    # list, so a long list never takes them out of reach.
    var body := VBoxContainer.new()
    body.set_anchors_preset(Control.PRESET_FULL_RECT)
    body.offset_left = 10
    body.offset_top = TITLE_HEIGHT + 10
    body.offset_right = -10
    body.offset_bottom = -10
    body.add_theme_constant_override("separation", 6)
    body.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _panel.add_child(body)

    # The status row (hints)
    _status_label = Label.new()
    _status_label.text = ""
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    body.add_child(_status_label)

    _header_vbox = VBoxContainer.new()
    _header_vbox.add_theme_constant_override("separation", 6)
    _header_vbox.visible = false
    body.add_child(_header_vbox)

    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    body.add_child(scroll)

    _content_vbox = VBoxContainer.new()
    _content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _content_vbox.add_theme_constant_override("separation", 6)
    _content_vbox.mouse_filter = Control.MOUSE_FILTER_STOP
    scroll.add_child(_content_vbox)

    _apply_theme_colors()
    # The plate, the title bar and the status line carry per-node overrides, which win over
    # the project theme: a new palette has to be written into them by hand.
    ThemeManager.theme_applied.connect(_apply_theme_colors)

    _show_main_menu()

# The surfaces and the text colour of the window, one place for the build and for every
# later palette. An open menu also rebuilds its list, so the buttons of the current view
# take the new theme too.
func _apply_theme_colors() -> void:
    _panel.add_theme_stylebox_override("panel", UI_THEME.window_plate())
    var title_style := StyleBoxFlat.new()
    title_style.bg_color = UI_THEME.color("control_bg")
    _title_bar.add_theme_stylebox_override("panel", title_style)
    _status_label.add_theme_color_override("font_color", UI_THEME.color("warning"))
    if is_open:
        _redraw_current_view()

# Rebuilds the screen the menu was showing. Every view setter assigns _view, so the
# menu returns to the same place after a palette or a language change.
func _redraw_current_view() -> void:
    if waiting_for_hex and pending_resource_id != "":
        _on_resource_selected(pending_resource_id)
    elif _view == VIEW_PRODUCT_FORM:
        _show_product_form()
    elif _view == VIEW_PRODUCT_LIST:
        _show_product_list()
    elif _view == VIEW_RAW_LIST:
        _show_resource_list()
    else:
        _show_main_menu()

func _show_main_menu():
    _clear_content()
    _status_label.text = ""
    _view = VIEW_MAIN

    var add_resource_btn = _make_button(tr("[1] Add a resource to the map"))
    add_resource_btn.pressed.connect(_on_add_resource_pressed)
    _content_vbox.add_child(add_resource_btn)

    # The two ways of adding stand together: one puts a resource on a hex, the other
    # sends a good to the storage.
    var add_product_btn = _make_button(tr("[2] Add a resource to storage"))
    add_product_btn.pressed.connect(_show_product_list)
    _content_vbox.add_child(add_product_btn)

    var next_era_btn = _make_button(tr("[3] Go to the next era"))
    next_era_btn.pressed.connect(_on_next_era_pressed)
    _content_vbox.add_child(next_era_btn)

    var open_map_btn = _make_button(tr("[4] Open the whole map"))
    open_map_btn.pressed.connect(_on_open_whole_map_pressed)
    _content_vbox.add_child(open_map_btn)

    # Toggling food consumption: the 1st click — the citizens stop eating,
    # a repeated one — they start eating again. The button text reflects the
    # current state.
    _food_toggle_btn = _make_button(_food_toggle_label())
    _food_toggle_btn.pressed.connect(_on_toggle_food_consumption_pressed)
    _content_vbox.add_child(_food_toggle_btn)

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

    var add_coins_btn = _make_button(tr("[8] Add 100000 coins"))
    add_coins_btn.pressed.connect(_on_add_coins_pressed)
    _content_vbox.add_child(add_coins_btn)

    # A stub for future actions (can be extended)
    var close_btn = _make_button(tr("[0] Close (F9)"))
    close_btn.pressed.connect(toggle)
    _content_vbox.add_child(close_btn)

func _show_resource_list():
    _clear_content()
    _status_label.text = tr("Select a resource:")
    _view = VIEW_RAW_LIST

    _add_back_button(_show_main_menu)
    _add_filter_field(_fill_resource_rows, VIEW_RAW_LIST)
    _fill_resource_rows()

# The raw resources, sorted by the display name. The names are localized when the data
# is read, so the search works in the language the player chose.
func _fill_resource_rows() -> void:
    _clear_rows()
    var entries := []
    for res_id in GameData.raw_resources.keys():
        var res_name := str(GameData.raw_resources[res_id].get("name", res_id))
        entries.append([res_name.to_lower(), res_name, str(res_id)])
    _add_filtered_rows(entries, _on_resource_selected, VIEW_RAW_LIST)

# The goods the city can keep on its shelves: only the records of type "product" are
# listed, a raw resource is what a hex of the map carries, not what the town owns.
# The goods of an additional ingredient are not here — they arrive through the recipe
# that makes them, and an id with the separator is not a thing the player picks.
func _show_product_list():
    _clear_content()
    _status_label.text = tr("Select a product:")
    _view = VIEW_PRODUCT_LIST

    _add_back_button(_show_main_menu)
    _add_filter_field(_fill_product_rows, VIEW_PRODUCT_LIST)
    _fill_product_rows()

func _fill_product_rows() -> void:
    _clear_rows()
    var entries := []
    for res_id in GameData.products.keys():
        if str(res_id).find(GameData.GENERATED_SEPARATOR) >= 0:
            continue
        var res_name := GameData.get_product_name(str(res_id))
        entries.append([res_name.to_lower(), res_name, str(res_id)])
    _add_filtered_rows(entries, _show_product_form, VIEW_PRODUCT_LIST)

# One row per entry that matches the search of its own list: an entry is [the lowercased
# name, the name, the id]. The prefix is what the player sees typed — "Ам" leaves амарант
# and амфора, not everything with an "ам" inside. Only the rows are rebuilt on a keystroke,
# never the field, so the caret and the focus stay where the typing happens.
func _add_filtered_rows(entries: Array, on_pick: Callable, slot: String) -> void:
    var needle := str(_pending_filters[slot]).to_lower()
    var rows := []
    for entry in entries:
        if needle == "" or str(entry[0]).begins_with(needle):
            rows.append(entry)
    rows.sort()

    if rows.is_empty():
        var hint := Label.new()
        hint.text = tr("Nothing found")
        hint.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
        _content_vbox.add_child(hint)
        return

    for row in rows:
        var res_id := str(row[2])
        var btn = _make_button("%s (%s)" % [row[1], res_id])
        _set_item_icon(btn, res_id)
        btn.pressed.connect(on_pick.bind(res_id))
        _content_vbox.add_child(btn)

# The field of the search, fixed above the list together with the "back" button. Each
# list keeps its own text: what was typed to find a good on the shelf does not hide the
# stones of the map when the player goes back.
func _add_filter_field(fill: Callable, slot: String) -> void:
    var edit := LineEdit.new()
    edit.placeholder_text = tr("Search by name")
    edit.text = str(_pending_filters[slot])
    edit.clear_button_enabled = true
    edit.custom_minimum_size = Vector2(0, 30)
    edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    edit.tooltip_text = tr("Only the names that begin with the typed text stay in the list")
    edit.text_changed.connect(_on_filter_text_changed.bind(fill, slot))
    _header_vbox.add_child(edit)
    _header_vbox.visible = true

func _on_filter_text_changed(new_text: String, fill: Callable, slot: String) -> void:
    _pending_filters[slot] = new_text
    fill.call()

# The form of one delivery: how much of the good and of which quality arrives.
func _show_product_form(product_id: String = ""):
    if product_id != "":
        _pending_product_id = product_id
    _clear_content()
    _view = VIEW_PRODUCT_FORM
    _status_label.text = tr("Product: %s") % GameData.get_product_name(_pending_product_id)

    _add_back_button(_show_product_list)

    var amount_row := HBoxContainer.new()
    amount_row.add_theme_constant_override("separation", 6)
    var amount_caption := Label.new()
    amount_caption.text = tr("Amount:")
    amount_caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    amount_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
    amount_row.add_child(amount_caption)

    _amount_edit = LineEdit.new()
    _amount_edit.text = _pending_amount
    _amount_edit.max_length = MAX_AMOUNT_LENGTH
    _amount_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
    _amount_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _amount_edit.custom_minimum_size = Vector2(0, 32)
    _amount_edit.tooltip_text = tr("Only whole positive numbers are accepted")
    _amount_edit.text_changed.connect(_on_amount_text_changed)
    _amount_edit.text_submitted.connect(_on_amount_submitted)
    amount_row.add_child(_amount_edit)
    _content_vbox.add_child(amount_row)

    var quality_caption := Label.new()
    quality_caption.text = tr("Quality:")
    quality_caption.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    _content_vbox.add_child(quality_caption)

    # A CheckBox of a ButtonGroup is the engine's radio button: the group makes the
    # choice single, allow_unpress = false keeps one of the levels always selected.
    var buttons := ButtonGroup.new()
    buttons.allow_unpress = false
    for qid in GameData.get_quality_levels():
        var radio := CheckBox.new()
        radio.button_group = buttons
        radio.text = "%s %s" % [GameData.get_quality_stars(qid), GameData.get_quality_name(qid)]
        radio.focus_mode = Control.FOCUS_NONE
        radio.custom_minimum_size = Vector2(0, 28)
        # The state is set BEFORE the connection: assigning button_pressed emits
        # toggled, and the listener would rewrite the choice while the form is built.
        radio.button_pressed = str(qid) == _pending_quality
        radio.toggled.connect(_on_quality_toggled.bind(str(qid)))
        _content_vbox.add_child(radio)

    var add_btn = _make_button(tr("Add to storage"))
    add_btn.pressed.connect(_on_add_to_storage_pressed)
    _content_vbox.add_child(add_btn)

    _amount_edit.grab_focus()

# The field accepts whole positive numbers only: everything that is not a digit is
# dropped right in the handler (so a paste is filtered too), and the leading zeros go
# away, so the field never shows "007" or a lone "0".
func _on_amount_text_changed(new_text: String) -> void:
    var clean := _sanitize_amount(new_text)
    if clean != new_text and is_instance_valid(_amount_edit):
        _amount_edit.text = clean
        _amount_edit.caret_column = clean.length()
    _pending_amount = clean

func _sanitize_amount(text: String) -> String:
    var digits := ""
    for i in range(text.length()):
        var ch := text[i]
        if ch >= "0" and ch <= "9":
            digits += ch
    return digits.lstrip("0")

# Enter in the amount field is the click on "Add to storage": the player types the
# number and confirms it without looking for the button.
func _on_amount_submitted(_text: String) -> void:
    _on_add_to_storage_pressed()

func _on_quality_toggled(pressed: bool, quality_id: String) -> void:
    if pressed:
        _pending_quality = quality_id

func _on_add_to_storage_pressed():
    if _pending_product_id == "":
        return
    # An empty field is not "nothing": the smallest delivery is one unit, so the debug
    # fill never silently does nothing. The public helper keeps the breakdown by quality
    # consistent with the total of the storage.
    var amount := maxi(_amount_value(), 1)
    CityData.add_to_storage(_pending_product_id, amount, _pending_quality)

    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(tr("Added %d %s (%s)") % [
                amount,
                GameData.get_product_name(_pending_product_id),
                GameData.get_quality_name(_pending_quality)],
                GameData.HUD_MESSAGE_NORMAL)
    if main_map.city_ui and main_map.city_ui.visible:
        main_map.city_ui.refresh()
    if main_map.map_renderer:
        main_map.map_renderer.queue_redraw()
    # The click took the keyboard away from the field; a debug fill is usually a series of
    # deliveries, so the next number goes where the player is already looking.
    if is_instance_valid(_amount_edit):
        _amount_edit.grab_focus()

func _amount_value() -> int:
    return int(_pending_amount) if _pending_amount.is_valid_int() else 0

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

# The digit of a hotkey by the key code, or -1 for any other key.
func _hotkey_number(keycode: Key) -> int:
    match keycode:
        KEY_1: return 1
        KEY_2: return 2
        KEY_3: return 3
        KEY_4: return 4
        KEY_5: return 5
        KEY_6: return 6
        KEY_7: return 7
        KEY_8: return 8
        KEY_9: return 9
        KEY_0: return 0
    return -1

# Runs the main-menu item with the given number and reports whether the key belongs
# to the menu. A sub-screen, the wait for a click on a hex and an unknown digit all
# answer false, so the keystroke goes on to the widget under it — the amount field
# of the storage form is typed with exactly these digits.
func _trigger_hotkey(num: int) -> bool:
    if num < 0 or not is_open or waiting_for_hex or _view != VIEW_MAIN:
        return false
    match num:
        1:
            _on_add_resource_pressed()
        2:
            _show_product_list()
        3:
            _on_next_era_pressed()
        4:
            _on_open_whole_map_pressed()
        5:
            _on_toggle_food_consumption_pressed()
        6:
            _on_toggle_ignore_tech_requirements_pressed()
        7:
            _on_toggle_ignore_build_requirements_pressed()
        8:
            _on_add_coins_pressed()
        0:
            close()
        _:
            return false
    return true

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
        main_map.hud.show_message(msg, GameData.HUD_MESSAGE_NORMAL)

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
        main_map.hud.show_message(msg, GameData.HUD_MESSAGE_NORMAL)

    if _ignore_build_btn:
        _ignore_build_btn.text = _ignore_build_label()
    CityData.emit_signal("city_updated")

func _ignore_build_label() -> String:
    return tr("[7] Ignore building requirements (now: %s)") % _on_off(CityData.ignore_build_requirements)

func _on_add_coins_pressed():
    # add_treasury emits treasury_changed, but the HUD label is throttled to the
    # resource display interval and does not subscribe to that signal, so we refresh
    # it explicitly for an instant update.
    CityData.add_treasury(100000)
    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(tr("Added 100000 coins"), GameData.HUD_MESSAGE_NORMAL)
    if main_map.has_method("_update_treasury_hud"):
        main_map._update_treasury_hud()
    if main_map.city_ui and main_map.city_ui.visible:
        main_map.city_ui.refresh()

func _on_toggle_food_consumption_pressed():
    # We invert the flag of food consumption by the population (CityData.do_tick reads
    # it before writing off food from storage). The flag itself is not saved in the save.
    var now_enabled = not CityData.food_consumption_enabled
    CityData.food_consumption_enabled = now_enabled

    var msg := tr("Food consumption is disabled: the citizens have stopped eating.")
    if now_enabled:
        msg = tr("Food consumption is enabled: the citizens are eating again.")
    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(msg, GameData.HUD_MESSAGE_NORMAL)

    # We update the button text in place (without a full redraw of the menu)
    if _food_toggle_btn:
        _food_toggle_btn.text = _food_toggle_label()

func _food_toggle_label() -> String:
    return tr("[5] Toggle food consumption (now: %s)") % _on_off(CityData.food_consumption_enabled)

func _on_resource_selected(res_id: String):
    pending_resource_id = res_id
    waiting_for_hex = true
    _clear_content()
    var res_name = GameData.get_product_name(res_id)
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

    var res_name = GameData.get_product_name(pending_resource_id)
    var msg = tr("Resource %s placed on the hex (%d, %d)") % [res_name, row, col]
    if old_res != null:
        var old_name = GameData.get_product_name(old_res)
        msg += tr(" (replaced: %s)") % old_name
    if old_crop != null:
        var crop_name = GameData.get_product_name(old_crop)
        msg += tr(" (breeding reset: %s)") % crop_name

    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(msg, GameData.HUD_MESSAGE_NORMAL)

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
    _clear_rows()
    for child in _header_vbox.get_children():
        _header_vbox.remove_child(child)
        child.queue_free()
    _header_vbox.visible = false

# The rows only: a keystroke in the search field rebuilds the list, and the field with
# the "back" button has to survive it.
func _clear_rows():
    for child in _content_vbox.get_children():
        _content_vbox.remove_child(child)
        child.queue_free()

# The button that returns to the previous screen: it stands outside the scroll, so the
# way back stays on screen however far the list was scrolled down.
func _add_back_button(target: Callable) -> void:
    var btn = _make_button(tr("← Back"))
    btn.pressed.connect(target)
    _header_vbox.add_child(btn)
    _header_vbox.visible = true

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

# The picture of an item of a selection list: the same icon the city windows draw for
# this resource, taken from the shared registry. An entry without an icon field in the
# data (a specialization, not a thing the city holds) stays text-only, and a name the
# registry does not know returns null, so nothing is set either way.
func _set_item_icon(btn: Button, res_id: String) -> void:
    var tex := IconRegistry.get_texture(str(GameData.get_resource_data(res_id).get("icon", "")))
    if tex == null:
        return
    btn.icon = tex
    btn.expand_icon = true
    btn.add_theme_constant_override("icon_max_width", LIST_ICON_SIZE)
    btn.add_theme_constant_override("icon_max_height", LIST_ICON_SIZE)

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
# keeps the current place and the values typed into the storage form.
func _on_locale_changed(_locale: String) -> void:
    if _title_label == null:
        return
    _title_label.text = tr("Debug menu")
    _redraw_current_view()

# The state word of a toggle row — the only part of the label that changes
# when the toggle is pressed.
func _on_off(value: bool) -> String:
    return tr("ON") if value else tr("OFF")
