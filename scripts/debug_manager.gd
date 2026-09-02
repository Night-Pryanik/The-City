# debug_manager.gd
# Дебаг-меню: открывается/закрывается по F9.
# Окно можно перетаскивать за заголовок. Взаимодействие с картой
# под окном блокируется, пока меню открыто.
extends Control

var main_map: Node
var is_open: bool = false

# Режим ожидания клика по гексу для размещения ресурса.
var waiting_for_hex: bool = false
var pending_resource_id: String = ""

# UI-элементы
var _panel: Panel
var _title_bar: Panel
var _title_label: Label
var _content_vbox: VBoxContainer
var _status_label: Label

# Перетаскивание окна за заголовок
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

const WINDOW_SIZE := Vector2(320, 420)
const TITLE_HEIGHT := 32

func initialize(main_node: Node):
    main_map = main_node
    _build_ui()
    hide()

func _build_ui():
    # Корневой Control занимает весь экран и перехватывает ввод,
    # блокируя взаимодействие с картой под окном.
    set_anchors_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP

    # Панель окна
    _panel = Panel.new()
    _panel.position = Vector2(80, 80)
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

    # Заголовок (перетаскивание)
    _title_bar = Panel.new()
    _title_bar.position = Vector2(0, 0)
    _title_bar.size = Vector2(WINDOW_SIZE.x, TITLE_HEIGHT)
    _title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
    _panel.add_child(_title_bar)

    var title_style = StyleBoxFlat.new()
    title_style.bg_color = Color(0.25, 0.25, 0.25, 1.0)
    _title_bar.add_theme_stylebox_override("panel", title_style)

    _title_label = Label.new()
    _title_label.text = "Дебаг-меню"
    _title_label.position = Vector2(8, 6)
    _title_label.add_theme_color_override("font_color", Color.WHITE)
    _title_label.add_theme_font_size_override("font_size", 16)
    _title_bar.add_child(_title_label)

    # Перетаскивание окна за заголовок
    _title_bar.gui_input.connect(_on_title_bar_gui_input)

    # Прокручиваемый контейнер содержимого
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

    # Статусная строка (подсказки)
    _status_label = Label.new()
    _status_label.text = ""
    _status_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _content_vbox.add_child(_status_label)

    _show_main_menu()

func _show_main_menu():
    _clear_content()
    _status_label.text = ""

    var add_resource_btn = _make_button("Добавить ресурс на карту")
    add_resource_btn.pressed.connect(_on_add_resource_pressed)
    _content_vbox.add_child(add_resource_btn)

    var next_era_btn = _make_button("Перейти в следующую эпоху")
    next_era_btn.pressed.connect(_on_next_era_pressed)
    _content_vbox.add_child(next_era_btn)

    var open_map_btn = _make_button("Открыть всю карту")
    open_map_btn.pressed.connect(_on_open_whole_map_pressed)
    _content_vbox.add_child(open_map_btn)

    # Заглушка для будущих действий (можно расширять)
    var close_btn = _make_button("Закрыть (F9)")
    close_btn.pressed.connect(toggle)
    _content_vbox.add_child(close_btn)

func _show_resource_list():
    _clear_content()
    _status_label.text = "Выберите ресурс:"

    var back_btn = _make_button("← Назад")
    back_btn.pressed.connect(_show_main_menu)
    _content_vbox.add_child(back_btn)

    # Список всех ресурсов из GameData.raw_resources,
    # отсортированный по алфавиту по отображаемому названию
    var entries = []
    for res_id in GameData.raw_resources.keys():
        var res_name = GameData.raw_resources[res_id].get("name", res_id)
        entries.append([res_name.to_lower(), res_id])
    entries.sort()

    for entry in entries:
        var res_id = entry[1]
        var btn = _make_button(GameData.raw_resources[res_id].get("name", res_id))
        btn.pressed.connect(_on_resource_selected.bind(res_id))
        _content_vbox.add_child(btn)

func _on_next_era_pressed():
    # Инфраструктура расширения: весь текущий Регион бесплатно исследуется
    # и присоединяется, бывшее Кольцо+Регион становится новым Кольцом,
    # вокруг него формируется новый Регион той же ширины.
    if main_map and main_map.has_method("advance_to_next_era"):
        main_map.advance_to_next_era()

func _on_add_resource_pressed():
    _show_resource_list()

func _on_open_whole_map_pressed():
    if main_map and main_map.has_method("debug_open_whole_map"):
        main_map.debug_open_whole_map()

func _on_resource_selected(res_id: String):
    pending_resource_id = res_id
    waiting_for_hex = true
    _clear_content()
    var res_name = GameData.raw_resources.get(res_id, {}).get("name", res_id)
    _status_label.text = "Кликните ЛКМ по гексу, чтобы разместить: %s" % res_name

    var cancel_btn = _make_button("Отмена")
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
    # Если на гексе было разводимое животное/растение (crop_bred), оно
    # конфликтует с новым природным ресурсом — сбрасываем. Иначе под старым
    # улучшением production-цикл мог бы смешать два разных ресурса.
    var old_crop = tile.get("crop_bred", null)
    if old_crop != null:
        tile["crop_bred"] = null

    var res_name = GameData.raw_resources.get(pending_resource_id, {}).get("name", pending_resource_id)
    var msg = "Ресурс %s размещён на гексе (%d, %d)" % [res_name, row, col]
    if old_res != null:
        var old_name = GameData.raw_resources.get(old_res, {}).get("name", old_res)
        msg += " (заменён: %s)" % old_name
    if old_crop != null:
        var crop_name = GameData.raw_resources.get(old_crop, {}).get("name", old_crop)
        msg += " (сброшено разведение: %s)" % crop_name

    if main_map.hud and main_map.hud.has_method("show_message"):
        main_map.hud.show_message(msg)

    main_map.map_renderer.queue_redraw()

    # Возврат в главное меню
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
    btn.custom_minimum_size = Vector2(0, 32)
    btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    btn.mouse_filter = Control.MOUSE_FILTER_STOP
    return btn

# --- Перетаскивание окна за заголовок ---
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
            # Ограничиваем окно в пределах экрана
            var viewport_size = get_viewport_rect().size
            _panel.position.x = clamp(_panel.position.x, 0, max(0, viewport_size.x - _panel.size.x))
            _panel.position.y = clamp(_panel.position.y, 0, max(0, viewport_size.y - _panel.size.y))
