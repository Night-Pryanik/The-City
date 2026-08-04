# building_panel.gd
# Панель деталей здания: отображает информацию о здании и его слотах,
# позволяет менять рецепт в каждом слоте.
extends Control

var building_index: int = -1
var products: Dictionary = {}
var buildings_data: Array = []
var crafts_data: Array = []

var panel: Panel
var title_label: Label
var info_label: Label
var slots_container: VBoxContainer

var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}
var popups_list: Array = []

func _ready():
    _build_icon_index()
    # Создаём оверлей-панель поверх CityUI.
    # ВАЖНО: CityUI — дочерний узел Node2D-сцены, поэтому у него нет собственного rect.
    # Задаём размеры корневого Control вручную в open().
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
    # Непрозрачный тёмный фон для панели
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

    var slots_title = Label.new()
    slots_title.text = "Слоты производства:"
    vbox.add_child(slots_title)

    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vbox.add_child(scroll)

    slots_container = VBoxContainer.new()
    slots_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(slots_container)

    var close_btn = Button.new()
    close_btn.text = "Закрыть"
    close_btn.pressed.connect(_on_close_pressed)
    vbox.add_child(close_btn)

func open(index: int, data: Dictionary):
    building_index = index
    products = data.get("products", {})
    crafts_data = data.get("crafts_data", [])
    # Сбрасываем ширину панели к базовой, чтобы она не оставалась широкой от предыдущего здания
    panel.custom_minimum_size.x = 460
    # Задаём размер корневого Control = размер viewport, чтобы оверлей покрывал всё
    var vp_size = get_viewport_rect().size
    size = vp_size
    position = Vector2.ZERO
    _refresh()
    show()

func _refresh():
    if building_index < 0 or building_index >= CityData.city_built_buildings.size():
        return
    # Гарантируем, что у здания есть слоты (на случай старых сейвов/сессий)
    CityData.migrate_old_save_format()
    var bld = CityData.city_built_buildings[building_index]
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == bld["id"]:
            bdata = b
            break

    var building_name = bdata["name"] if bdata else bld["id"]
    title_label.text = building_name

    var info_text = "Слотов: %d" % bld.get("slots", []).size()
    if bdata:
        info_text += "\nСтоимость в еде: %d" % bdata.get("cost_food", 0)
        if bdata.has("additional_cost"):
            info_text += "\nДополнительно:"
            for res_id in bdata["additional_cost"]:
                var res_name = products.get(res_id, {}).get("name", res_id)
                info_text += "\n  %s: %d" % [res_name, bdata["additional_cost"][res_id]]
    info_label.text = info_text

    # Очищаем старые слоты
    for child in slots_container.get_children():
        child.queue_free()

    # Удаляем старые попапы
    for p in popups_list:
        if is_instance_valid(p):
            p.queue_free()
    popups_list.clear()

    var slots = bld.get("slots", [])
    var all_item_texts = []
    var max_item_icons = 0
    var popups = []
    for i in range(slots.size()):
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 8)

        var slot_label = Label.new()
        slot_label.text = "Слот %d:" % (i + 1)
        slot_label.custom_minimum_size = Vector2(70, 0)
        row.add_child(slot_label)

        # Собираем доступные рецепты: "empty" + все, что можно исполнять в этом здании
        var available = []
        available.append("empty")
        for craft in crafts_data:
            if craft["id"] == "empty":
                continue
            if CityData.can_craft_in(craft["id"], bld["id"]):
                available.append(craft["id"])

        var current = slots[i]

        # Кнопка выбора рецепта
        var select_btn = Button.new()
        select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        select_btn.add_theme_constant_override("icon_max_width", 24)
        select_btn.clip_text = true
        _update_slot_button(select_btn, current)

        # Кастомный попап со списком рецептов (поддерживает несколько иконок результата)
        # ВАЖНО: попап (Window) нужно добавить в дерево ДО добавления содержимого,
        # иначе layout не пересчитывается.
        var popup = PopupPanel.new()
        # Непрозрачный тёмный фон попапа, чтобы текст под ним не просвечивал
        var popup_style = StyleBoxFlat.new()
        popup_style.bg_color = Color(0.15, 0.15, 0.15, 1.0)
        popup_style.set_border_width_all(1)
        popup_style.border_color = Color(0.4, 0.4, 0.4, 1.0)
        popup_style.set_corner_radius_all(4)
        popup.add_theme_stylebox_override("panel", popup_style)
        add_child(popup)
        popup.hide()

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
            var craft_result = {}
            for c in crafts_data:
                if c["id"] == craft_id:
                    craft_name = c.get("name", craft_id)
                    craft_result = c.get("result", {})
                    break
            # Формируем текст пункта для расчёта ширины
            var item_text = craft_name
            if not craft_result.is_empty():
                var result_names = []
                for prod_id in craft_result:
                    var pdata = products.get(prod_id, {})
                    result_names.append(pdata.get("name", prod_id))
                item_text = "%s -> %s" % [craft_name, ", ".join(result_names)]
            all_item_texts.append(item_text)
            if craft_result.size() > max_item_icons:
                max_item_icons = craft_result.size()

            # Пункт списка — Button с содержимым и встроенной подсветкой при наведении
            var item_btn = Button.new()
            item_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
            item_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            item_btn.custom_minimum_size.y = 30
            item_btn.focus_mode = Control.FOCUS_NONE

            # Прозрачный фон в обычном состоянии, подсветка при наведении
            var normal_style = StyleBoxFlat.new()
            normal_style.bg_color = Color(0, 0, 0, 0)
            var hover_style = StyleBoxFlat.new()
            hover_style.bg_color = Color(0.35, 0.35, 0.35, 1.0)
            item_btn.add_theme_stylebox_override("normal", normal_style)
            item_btn.add_theme_stylebox_override("hover", hover_style)
            item_btn.add_theme_stylebox_override("pressed", hover_style)
            item_btn.add_theme_stylebox_override("focus", hover_style)

            var content = _make_craft_content(craft_name, craft_result)
            content.set_anchors_preset(Control.PRESET_FULL_RECT)
            content.offset_left = 8
            content.offset_right = -8
            item_btn.add_child(content)
            item_btn.pressed.connect(_on_craft_item_selected.bind(i, craft_id, popup, select_btn))
            popup_vbox.add_child(item_btn)

        select_btn.pressed.connect(_on_slot_button_pressed.bind(popup, select_btn))
        row.add_child(select_btn)

        slots_container.add_child(row)
        popups.append(popup)
        popups_list.append(popup)

    # Динамически расширяем панель, если текст пунктов не помещается
    var max_text_width = 0
    var font = get_theme_default_font()
    var font_size = get_theme_default_font_size()
    for t in all_item_texts:
        var w = font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
        if w > max_text_width:
            max_text_width = w
    # Ширина панели = текст + иконка (24) + отступы (40) + метка слота (70) + запас (40)
    var needed_width = max_text_width + 24 + 40 + 70 + 40
    # Не даём панели выйти за пределы viewport
    var max_panel_width = get_viewport_rect().size.x - 40
    if needed_width > max_panel_width:
        needed_width = max_panel_width
    if needed_width > panel.custom_minimum_size.x:
        panel.custom_minimum_size.x = needed_width

    # Приводим ширину попапов в соответствие с шириной панели
    var popup_width = panel.custom_minimum_size.x - 70 - 40
    for popup in popups:
        popup.min_size.x = popup_width

func _on_slot_button_pressed(popup, button):
    # Закрываем другие открытые попапы
    for p in popups_list:
        if is_instance_valid(p) and p != popup and p.visible:
            p.hide()
    # Пересчитываем размер окна под содержимое
    popup.reset_size()
    # Позиционируем попап сразу под кнопкой
    popup.position = button.global_position + Vector2(0, button.size.y)
    popup.popup()

func _on_craft_item_selected(slot_idx: int, craft_id: String, popup, button):
    if building_index < 0 or building_index >= CityData.city_built_buildings.size():
        return
    var bld = CityData.city_built_buildings[building_index]
    var slots = bld.get("slots", [])
    if slot_idx < slots.size():
        slots[slot_idx] = craft_id
        bld["slots"] = slots
        _update_slot_button(button, craft_id)
    popup.hide()
    CityData.emit_signal("city_updated")

# Строит содержимое строки: "Название рецепта -> [иконка] Продукт, [иконка] Продукт"
func _make_craft_content(craft_name: String, craft_result: Dictionary) -> HBoxContainer:
    var content = HBoxContainer.new()
    content.add_theme_constant_override("separation", 6)
    content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    content.mouse_filter = Control.MOUSE_FILTER_IGNORE

    var craft_label = Label.new()
    craft_label.text = craft_name
    craft_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    if not craft_result.is_empty():
        craft_label.text += " ->"
    content.add_child(craft_label)

    var first_prod = true
    for prod_id in craft_result:
        var pdata = products.get(prod_id, {})
        if not first_prod:
            var sep_label = Label.new()
            sep_label.text = ","
            sep_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            sep_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(sep_label)
        first_prod = false

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
        if amount > 1:
            var amount_label = Label.new()
            amount_label.text = "x%d" % amount
            amount_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(amount_label)

    return content

# Обновляет содержимое кнопки выбора рецепта: иконки рисуются рядом с продуктами, а не у левого края
func _update_slot_button(button, craft_id: String):
    var craft_name = craft_id
    var craft_result = {}
    for c in crafts_data:
        if c["id"] == craft_id:
            craft_name = c.get("name", craft_id)
            craft_result = c.get("result", {})
            break
    # Удаляем старое содержимое кнопки
    for child in button.get_children():
        child.queue_free()
    var content = _make_craft_content(craft_name, craft_result)
    content.set_anchors_preset(Control.PRESET_FULL_RECT)
    content.offset_left = 8
    content.offset_right = -8
    button.add_child(content)

func _input(event: InputEvent):
    if not visible:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        # Если открыт какой-либо попап, клик вне панели закрывает только попап
        var open_popup = null
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
        # Клик вне панели (по затемнению) закрывает её
        if not panel.get_global_rect().has_point(event.global_position):
            hide()
            get_viewport().set_input_as_handled()

func _build_icon_index():
    icon_paths.clear()
    _scan_folder("res://icons")

func _scan_folder(folder_path: String):
    var dir = DirAccess.open(folder_path)
    if dir == null: return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            _scan_folder(folder_path.path_join(file_name))
        else:
            var full_path = folder_path.path_join(file_name)
            if icon_paths.has(file_name):
                print("Предупреждение: дубликат иконки ", file_name)
            icon_paths[file_name] = full_path
        file_name = dir.get_next()
    dir.list_dir_end()

func _get_icon_texture(icon_file: String) -> Texture2D:
    if icon_file.is_empty():
        return null
    if icon_textures.has(icon_file):
        return icon_textures[icon_file]
    if icon_paths.has(icon_file):
        var tex = load(icon_paths[icon_file])
        icon_textures[icon_file] = tex
        return tex
    return null

func _on_close_pressed():
    hide()