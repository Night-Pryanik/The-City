# building_panel.gd
# Панель деталей здания: отображает информацию о здании (возможно, нескольких
# однотипных) и их слотах, позволяет менять рецепт в каждом слоте,
# а также приостанавливать/запускать отдельные здания.
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
var costs_label: Label
var costs_container: VBoxContainer
var slots_container: VBoxContainer

var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}
var popups_list: Array = []
var popup_map: Dictionary = {}
var open_popup = null

# Снимок состояния, при котором в последний раз был сделан _refresh().
# Хранит количество зданий, рецепты в слотах, наличие работника и приоритет
# качества по каждому индексу. Используется, чтобы НЕ пересоздавать панель
# слотов на каждом игровом тике: city_updated эмитится раз в PRODUCTION_INTERVAL
# из do_tick(), и без этого _refresh() каждый тик уничтожает кнопки заголовков
# (toggle_btn, quality_btn) вместе с их ОС-тултипами "Запустить/Приостановить"
# и "Приоритет качества: ...".
# Формат: {"count": int, "items": {b_index: {"slots": [..], "priority": String, "has_worker": bool}}}
var _last_panel_state: Dictionary = {}

func _ready():
    _build_icon_index()
    # Подписываемся на изменение назначений работников, чтобы панель
    # обновлялась в реальном времени (например, при рождении жителя,
    # который автоматически встаёт на работу).
    call_deferred("_setup_assignments_listener")
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

    # Блок "Затраты" — отдельный узел, чтобы тултип для групповых ресурсов
    # срабатывал только при наведении на конкретную кнопку.
    costs_label = Label.new()
    costs_label.text = "Затраты:"
    costs_label.add_theme_font_size_override("font_size", 16)
    vbox.add_child(costs_label)

    costs_container = VBoxContainer.new()
    costs_container.add_theme_constant_override("separation", 4)
    vbox.add_child(costs_container)

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

func open(building_id_arg: String, data: Dictionary):
    # Очищаем старые попапы при открытии (контент мог устареть, например,
    # после изучения новых технологий). При периодическом _refresh() попапы
    # будут переиспользованы и не закроются.
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
    # Сбрасываем ширину панели к базовой, чтобы она не оставалась широкой от предыдущего здания
    panel.custom_minimum_size.x = 460
    # Задаём размер корневого Control = размер viewport, чтобы оверлей покрывал всё
    var vp_size = get_viewport_rect().size
    size = vp_size
    position = Vector2.ZERO
    # Сбрасываем кэш состояния, чтобы _refresh() гарантированно отработал
    # при открытии панели (иначе он бы сразу же вышел по «состояние не изменилось»).
    _last_panel_state = {}
    _refresh()
    show()

func _refresh():
    # Гарантируем, что у зданий есть слоты (на случай старых сейвов/сессий)
    CityData.migrate_old_save_format()

    # Собираем все индексы построенных зданий с нужным id
    var indices = []
    for idx in range(CityData.city_built_buildings.size()):
        if CityData.city_built_buildings[idx].get("id", "") == building_id:
            indices.append(idx)

    if indices.is_empty():
        return

    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break

    var building_name = bdata["name"] if bdata else building_id
    title_label.text = building_name

    info_label.text = "Зданий: %d" % indices.size()

    # Заполняем блок "Затраты"
    _refresh_costs(bdata)

    # Очищаем старые слоты
    for child in slots_container.get_children():
        child.queue_free()

    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null

    var all_item_texts = []
    var max_item_icons = 0
    var popups = []
    var new_popup_map = {}
    var building_number = 0
    for b_index in indices:
        building_number += 1
        var bld = CityData.city_built_buildings[b_index]
        var slots = bld.get("slots", [])

        # Заголовок отдельного здания с кнопкой приостановки/запуска
        var header = HBoxContainer.new()
        header.add_theme_constant_override("separation", 8)

        var has_worker = tm.has_townsfolk(b_index) if tm else false
        var is_idle = has_worker and CityData.are_all_slots_empty(b_index)
        var status = " (простаивает)" if is_idle else (" (работает)" if has_worker else " (не работает)")

        var header_label = Label.new()
        header_label.text = "Здание %d%s" % [building_number, status]
        if is_idle:
            header_label.add_theme_color_override("font_color", Color.ORANGE)
        else:
            header_label.add_theme_color_override("font_color", Color.GREEN if has_worker else Color.RED)
        header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        header.add_child(header_label)

        var toggle_btn = Button.new()
        toggle_btn.custom_minimum_size = Vector2(28, 28)
        toggle_btn.expand_icon = true
        if has_worker:
            toggle_btn.icon = _get_toggle_icon("pause")
            toggle_btn.tooltip_text = "Приостановить"
            toggle_btn.pressed.connect(_on_toggle_pressed.bind(b_index, false))
        else:
            toggle_btn.icon = _get_toggle_icon("resume")
            toggle_btn.tooltip_text = "Запустить"
            toggle_btn.pressed.connect(_on_toggle_pressed.bind(b_index, true))
        header.add_child(toggle_btn)

        # Кнопка приоритета качества: best (лучшее) / worst (худшее)
        var quality_btn = Button.new()
        quality_btn.custom_minimum_size = Vector2(28, 28)
        quality_btn.expand_icon = true
        quality_btn.tooltip_text = "Приоритет качества: используйте лучшее/худшее"
        quality_btn.pressed.connect(_on_quality_priority_pressed.bind(b_index))
        _update_quality_button(quality_btn, b_index)
        header.add_child(quality_btn)

        slots_container.add_child(header)

        for i in range(slots.size()):
            var row = HBoxContainer.new()
            row.add_theme_constant_override("separation", 8)

            var slot_label = Label.new()
            slot_label.text = "Слот %d:" % (i + 1)
            slot_label.custom_minimum_size = Vector2(70, 0)
            row.add_child(slot_label)

            # Собираем доступные рецепты: "empty" + все, что можно исполнять в этом здании
            # (с фильтрацией по изученным технологиям)
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

            # Кнопка выбора рецепта
            var select_btn = Button.new()
            select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
            select_btn.add_theme_constant_override("icon_max_width", 24)
            select_btn.clip_text = true
            _update_slot_button(select_btn, current)

            var popup_key = "%d:%d" % [b_index, i]
            var popup = null
            # Переиспользуем существующий попап, если он есть
            if popup_map.has(popup_key) and is_instance_valid(popup_map[popup_key]):
                popup = popup_map[popup_key]
                # Попап существует — заменяем его содержимое с актуальной кнопкой
                for child in popup.get_children():
                    popup.remove_child(child)
                    child.free()
                var fill_data = _fill_popup_content(popup, b_index, i, available, select_btn)
                for t in fill_data["item_texts"]:
                    all_item_texts.append(t)
                if int(fill_data["max_icons"]) > max_item_icons:
                    max_item_icons = int(fill_data["max_icons"])
            else:
                # Кастомный попап со списком рецептов (поддерживает несколько иконок результата)
                # ВАЖНО: попап (Window) нужно добавить в дерево ДО добавления содержимого,
                # иначе layout не пересчитывается.
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
                # Заполняем содержимое попапа и получаем данные для расчёта ширины
                var fill_data = _fill_popup_content(popup, b_index, i, available, select_btn)
                for t in fill_data["item_texts"]:
                    all_item_texts.append(t)
                if int(fill_data["max_icons"]) > max_item_icons:
                    max_item_icons = int(fill_data["max_icons"])
            popups.append(popup)
            popups_list.append(popup)
            new_popup_map[popup_key] = popup
            select_btn.pressed.connect(_on_slot_button_pressed.bind(b_index, i, popup, select_btn))
            row.add_child(select_btn)
            slots_container.add_child(row)

    # Динамически расширяем панель, если текст пунктов не помещается
    var max_text_width = 0
    var font = get_theme_default_font()
    var font_size = get_theme_default_font_size()
    for t in all_item_texts:
        var w = font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
        if w > max_text_width:
            max_text_width = w
    # Ширина панели = текст + иконки (24 каждая) + отступы (40) + метка слота (70) + запас (40)
    var needed_width = max_text_width + max_item_icons * 24 + 40 + 70 + 40
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

    # Обновляем popup_map и удаляем попапы, которые больше не нужны
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

    # Фиксируем снимок состояния, чтобы последующие _on_assignments_changed()
    # на пустых тиках не делали повторный _refresh() и не убивали ОС-тултипы
    # на кнопках заголовков (toggle_btn, quality_btn).
    _last_panel_state = _collect_panel_state(tm)

# Заполняет содержимое попапа списком доступных рецептов.
# Возвращает словарь с текстами пунктов и максимальным количеством иконок
# (нужно для расчёта ширины панели в _refresh()).
func _fill_popup_content(popup, b_index: int, slot_idx: int, available: Array, button) -> Dictionary:
    var result = {"item_texts": [], "max_icons": 0}

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
                craft_result = c.get("result", {})
                break
        # Формируем текст пункта для расчёта ширины
        var item_text = ""
        if not craft_resources.is_empty():
            var res_names = []
            for res_id in craft_resources:
                res_names.append(GameData.format_resource_name(res_id))
            item_text = ", ".join(res_names)
        if not craft_result.is_empty():
            var result_names = []
            for prod_id in craft_result:
                var pdata = products.get(prod_id, {})
                result_names.append(pdata.get("name", prod_id))
            if item_text != "":
                item_text += " -> "
            item_text += ", ".join(result_names)
        result["item_texts"].append(item_text)
        var icon_count = craft_resources.size() + craft_result.size()
        if icon_count > int(result["max_icons"]):
            result["max_icons"] = icon_count

        # Пункт списка — Button с содержимым и встроенной подсветкой при наведении
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
        item_btn.pressed.connect(_on_craft_item_selected.bind(b_index, slot_idx, craft_id, popup, button))
        popup_vbox.add_child(item_btn)

    return result

# Заполняет блок "Затраты" — отдельные строки для еды и каждого ресурса.
# Групповые ресурсы (@...) становятся кнопками с тултипом.
func _refresh_costs(bdata):
    # Очищаем старые строки
    for child in costs_container.get_children():
        child.queue_free()

    if not bdata:
        costs_label.visible = false
        return

    var has_costs = false

    # Стоимость в еде
    var cost_food = bdata.get("cost_food", 0)
    if cost_food > 0:
        var food_row = HBoxContainer.new()
        food_row.add_theme_constant_override("separation", 6)
        var food_label = Label.new()
        food_label.text = "В еде: %d" % cost_food
        food_row.add_child(food_label)
        costs_container.add_child(food_row)
        has_costs = true

    # Дополнительные ресурсы. Поддерживают AND-логику: каждая пачка требует
    # все свои ресурсы, и нужны ВСЕ пачки одновременно. Между пачками
    # вставляется разделитель «И».
    if bdata.has("additional_cost"):
        var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
        for bi in bundles.size():
            var bundle: Dictionary = bundles[bi]
            var row = HBoxContainer.new()
            row.add_theme_constant_override("separation", 6)

            var first_in_row := true
            for res_id in bundle:
                var amount = bundle[res_id]
                if not first_in_row:
                    var sep = Label.new()
                    sep.text = ", "
                    row.add_child(sep)
                first_in_row = false

                if GameData.is_group_key(res_id):
                    # Групповой ресурс — строка с тултипом, раскрывающим состав группы
                    row.add_child(ui_helpers.make_resource_entry(res_id, _get_all_resources(), icon_paths, int(amount), "colon"))
                else:
                    # Обычный ресурс — "иконка + название: количество"
                    row.add_child(ui_helpers.make_resource_entry(res_id, _get_all_resources(), icon_paths, int(amount), "colon"))

            costs_container.add_child(row)
            has_costs = true

            # Между пачками вставляем разделитель «И»
            if bi < bundles.size() - 1:
                var and_label = Label.new()
                and_label.text = "И"
                and_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
                costs_container.add_child(and_label)

    costs_label.visible = has_costs

func _setup_assignments_listener():
    # Подключаемся к сигналу изменения назначений горожан, чтобы обновлять
    # панель в реальном времени (например, когда новый житель автоматически
    # встаёт на работу).
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    if tm and not tm.assignment_changed.is_connected(_on_assignments_changed):
        tm.assignment_changed.connect(_on_assignments_changed)
    # Подписываемся на обновление города, чтобы панель обновлялась при
    # смене рецептов (статус "простаивает" появляется/исчезает сразу).
    if not CityData.city_updated.is_connected(_on_assignments_changed):
        CityData.city_updated.connect(_on_assignments_changed)

func _on_assignments_changed():
    if not visible:
        return
    # Если открыт попап со списком рецептов — НЕ вызываем _refresh(), чтобы
    # попап не перестраивался и не закрывался при каждом игровом тике.
    # (city_updated эмитится каждые PRODUCTION_INTERVAL секунд из do_tick.)
    if open_popup != null:
        return
    # Если открыт tooltip списка продуктов (группового ресурса) - тоже не вызываем
    # _refresh(), чтобы он не исчезал при пересоздании строк затрат.
    if ui_helpers != null and is_instance_valid(ui_helpers):
        var gtp = ui_helpers.group_tooltip_panel
        if is_instance_valid(gtp) and gtp.visible:
            return

    # Сравниваем текущее состояние с тем, при котором был последний _refresh().
    # Если ничего не изменилось (а на обычном тике do_tick() меняется только
    # содержимое складов, не состав зданий/слотов/работников) — выходим без
    # пересоздания UI. Иначе каждый тик умирают кнопки заголовков и их ОС-тултипы.
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    var current_state = _collect_panel_state(tm)
    if _panel_state_equal(_last_panel_state, current_state):
        return
    _last_panel_state = current_state
    _refresh()

# Собирает снимок данных, от которых зависит внешний вид панели слотов.
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
        }
    return state

# Сравнивает два снимка состояния панели. Игнорирует количественные изменения
# складов/производства — они не должны вызывать пересоздание UI слотов.
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
            # Показываем сообщение через городской UI, если доступен
            var city_ui = get_tree().root.find_child("CityUi", true, false)
            if city_ui and city_ui.has_method("set_message"):
                city_ui.set_message("Нет свободных жителей!")
            return
        tm.assign_townsfolk(b_index)
    else:
        tm.remove_townsfolk(b_index)

    # Скрываем открытые попапы перед пересозданием слотов, чтобы они
    # не ссылались на удаляемые элементы и не оставались висячими.
    for p in popups_list:
        if is_instance_valid(p) and p.visible:
            p.hide()
    _refresh()

# Переключает приоритет качества здания и обновляет кнопку.
func _on_quality_priority_pressed(b_index: int):
    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return
    var bld = CityData.city_built_buildings[b_index]
    var current = bld.get("quality_priority", GameData.get_quality_priority_default())
    var options = GameData.get_quality_priority_options()
    var new_priority = options[0] if not options.is_empty() else "best"
    # Циклически переключаем: best → worst → random → best
    if not options.is_empty():
        var idx = options.find(current)
        if idx < 0:
            idx = 0
        idx = (idx + 1) % options.size()
        new_priority = options[idx]
    bld["quality_priority"] = new_priority
    # Показываем сообщение
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
            hud.show_message("%s: приоритет качества — %s" % [bname, priority_text])
    # Обновляем кнопку в интерфейсе
    _refresh()
    CityData.emit_signal("city_updated")

# Обновляет текст/подсказку кнопки приоритета качества.
func _update_quality_button(button: Button, b_index: int):
    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return
    var bld = CityData.city_built_buildings[b_index]
    var priority = bld.get("quality_priority", GameData.get_quality_priority_default())
    var levels = GameData.get_quality_levels()
    # Индикация приоритета: звёздочки лучшего/худшего качества или 🎲 для random.
    if priority == "best" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.back())
    elif priority == "worst" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.front())
    elif priority == "random":
        button.text = "🎲"
    else:
        button.text = "★"
    button.tooltip_text = "Приоритет качества: %s (нажмите чтобы переключить)" % GameData.get_quality_priority_name(priority)

func _get_toggle_icon(icon_name: String) -> Texture2D:
    if icon_name == "resume":
        return load("res://icons/building_resume.png")
    return load("res://icons/building_pause.png")

func _on_slot_button_pressed(b_index: int, slot_idx: int, popup, button):
    # Закрываем другие открытые попапы
    for p in popups_list:
        if is_instance_valid(p) and p != popup and p.visible:
            p.hide()
    # Пересчитываем размер окна под содержимое
    popup.reset_size()
    # Позиционируем попап сразу под кнопкой
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
        _update_slot_button(button, craft_id)
    popup.hide()
    open_popup = null
    if ui_helpers:
        ui_helpers.hide_group_tooltip()
    CityData.emit_signal("city_updated")

# Строит содержимое строки: "[иконка] Требуемый ресурс [xN] -> [иконка] Продукт [xN]"
# Для групповых ресурсов (@...) — подпись с тултипом.
# Если ресурсы и результат пусты (рецепт "Пусто"), показываем название рецепта.
func _make_craft_content(craft_name: String, craft_resources: Dictionary, craft_result: Dictionary) -> HBoxContainer:
    var content = HBoxContainer.new()
    content.add_theme_constant_override("separation", 6)
    content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    content.mouse_filter = Control.MOUSE_FILTER_IGNORE

    # Рецепт без ресурсов и результата (например, "Пусто") — показываем только название
    if craft_resources.is_empty() and craft_result.is_empty():
        var empty_label = Label.new()
        empty_label.text = craft_name
        empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(empty_label)
        return content

    # Требуемые ресурсы
    var first_res = true
    for res_id in craft_resources:
        if not first_res:
            var sep_label = Label.new()
            sep_label.text = "+"
            sep_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            sep_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(sep_label)
        first_res = false

        # Групповой ресурс — подпись с тултипом (через единый хелпер).
        # Используем MOUSE_FILTER_PASS, чтобы наведение показывало тултип,
        # а клик проходил к родительской кнопке (выбор рецепта).
        content.add_child(ui_helpers.make_resource_entry(res_id, _get_all_resources(), icon_paths))
        var amount = craft_resources[res_id]
        if amount >= 1:
            var amount_label = Label.new()
            amount_label.text = "x%d" % amount
            amount_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(amount_label)

    # Стрелка
    if not craft_resources.is_empty() and not craft_result.is_empty():
        var arrow_label = Label.new()
        arrow_label.text = "->"
        arrow_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
        arrow_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(arrow_label)

    # Производимые продукты
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

# Обновляет содержимое кнопки выбора рецепта: иконки рисуются рядом с продуктами, а не у левого края
func _update_slot_button(button, craft_id: String):
    var craft_name = craft_id
    var craft_resources = {}
    var craft_result = {}
    for c in crafts_data:
        if c["id"] == craft_id:
            craft_name = c.get("name", craft_id)
            craft_resources = c.get("resources", {})
            craft_result = c.get("result", {})
            break
    # Удаляем старое содержимое кнопки
    for child in button.get_children():
        child.queue_free()
    var content = _make_craft_content(craft_name, craft_resources, craft_result)
    content.set_anchors_preset(Control.PRESET_FULL_RECT)
    content.offset_left = 8
    content.offset_right = -8
    button.add_child(content)

func _input(event: InputEvent):
    if not visible:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        # Если открыт какой-либо попап, клик вне панели закрывает только попап
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
        # Клик вне панели (по затемнению) закрывает её
        if not panel.get_global_rect().has_point(event.global_position):
            if ui_helpers:
                ui_helpers.hide_group_tooltip()
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
    if ui_helpers:
        ui_helpers.hide_group_tooltip()
    hide()

# Возвращает объединённый словарь всех ресурсов (сырьё + товары)
func _get_all_resources() -> Dictionary:
    var all = {}
    for key in raw_resources:
        all[key] = raw_resources[key]
    for key in products:
        all[key] = products[key]
    return all

# Возвращает имя иконки ресурса (из товаров или сырья)
func _get_resource_icon(res_id: String) -> String:
    if products.has(res_id):
        return products[res_id].get("icon", "")
    if raw_resources.has(res_id):
        return raw_resources[res_id].get("icon", "")
    return ""

# Возвращает человекочитаемое имя ресурса (из товаров или сырья)
func _get_resource_name(res_id: String) -> String:
    if products.has(res_id):
        return products[res_id].get("name", res_id)
    if raw_resources.has(res_id):
        return raw_resources[res_id].get("name", res_id)
    return res_id
