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

# Кнопка выбранного здания и словарь id -> кнопка (для тултипа деталей).
var selected_button: Button = null
var _hovered_building_id: String = "" # здание под курсором (для тултипа деталей)
var building_buttons: Dictionary = {}

var resume_icon: Texture2D
var pause_icon: Texture2D
var info_icon: Texture2D

var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}

# Строки строящихся зданий: build_key -> { "row": HBoxContainer, "bar": ProgressBar, "pause_btn": Button }
var construction_rows: Dictionary = {}

signal build_requested(building_id: String)
signal building_detail_requested(building_id: String)

func setup(list: Node, btn: Button, built_list: Node, food_lbl: Label, helpers: Node):
    buildings_list = list as VBoxContainer
    build_button = btn
    built_buildings_list = built_list
    food_label = food_lbl
    ui_helpers = helpers

    set_process(true)

    _build_icon_index()

    # Единая радиогруппа для списка доступных построек: клик по одной кнопке
    # автоматически снимает остальные. allow_unpress=false запрещает «отжать»
    # уже выбранную кнопку — в любой момент выбрано ровно одно здание.
    buildings_group = ButtonGroup.new()
    buildings_group.allow_unpress = false

    if not build_button.pressed.is_connected(_on_build_pressed):
        build_button.pressed.connect(_on_build_pressed)
    build_button.disabled = true

func _process(delta):
    # Обновляем прогресс-бары строящихся зданий каждый кадр,
    # чтобы они были плавными (как прогресс-бары улучшений на карте).
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

func refresh_list():
    for child in buildings_list.get_children():
        buildings_list.remove_child(child)
        child.queue_free()
    selected_building_id = ""
    selected_button = null
    building_buttons.clear()
    build_button.disabled = true
    # Скрываем сообщения и тултипы при обновлении списка
    if ui_helpers:
        ui_helpers.set_message("")
        ui_helpers.hide_group_tooltip()
        ui_helpers.hide_building_detail_tooltip()
    food_label.visible = false
    for bld in buildings_data:
        # Фильтруем здания: показываем только те, что открыты изученными технологиями
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
        # Иконка здания перед названием (файл из buildings.json). Если файла
        # иконки пока не существует — просто выводим название без иконки;
        # при появлении файла иконка подхватится автоматически.
        var building_icon = _get_icon_texture_from_paths(bld.get("icon", ""))
        if building_icon:
            item_btn.icon = building_icon
            item_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
            item_btn.add_theme_constant_override("icon_max_width", 24)
        item_btn.pressed.connect(_on_building_list_pressed.bind(bld["id"]))
        item_btn.mouse_entered.connect(_on_building_hovered.bind(bld["id"]))
        item_btn.mouse_exited.connect(_on_building_unhovered.bind(bld["id"]))
        buildings_list.add_child(item_btn)
        building_buttons[bld["id"]] = item_btn

func update_built_status():
    # Лёгкое обновление: обновляем текст статуса без пересоздания строк.
    if built_buildings.size() != last_built_count or CityData.building_construction.size() != last_construction_count:
        refresh_built()
        return

    # Кнопка «Построить» остаётся активной даже при достижении лимита строек,
    # чтобы при нажатии можно было показать сообщение о причине отказа.
    # Блокируется только когда не выбрано здание.
    if build_button:
        build_button.disabled = (selected_building_id == "")

    # Обновляем прогресс-бары строящихся зданий
    _update_construction_rows()

    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null

    # Группируем здания по id
    var groups = _group_buildings()
    for g in range(groups.size()):
        var row = built_buildings_list.get_child(g + construction_rows.size())
        if row == null or row.get_child_count() < 2:
            continue
        var group = groups[g]
        var bdata = null
        for b in buildings_data:
            if b["id"] == group["id"]:
                bdata = b
                break
        var base_name = bdata["name"] if bdata else group["id"]
        var working = group["working"]
        var idle = group["idle"]

        var display_name = "%s x%d" % [base_name, group["total"]] if group["total"] > 1 else base_name
        var status = ""
        var status_color = Color.WHITE
        if idle > 0:
            # Есть простаивающие здания (работник есть, но все слоты пустые)
            if group["total"] > 1:
                if idle == group["total"]:
                    status = " (простаивает)"
                else:
                    status = " (работает: %d из %d, простаивает: %d)" % [working, group["total"], idle]
            else:
                status = " (простаивает)"
            status_color = Color.ORANGE
        elif group["total"] > 1:
            status = " (работает: %d из %d)" % [working, group["total"]]
            status_color = Color.GREEN if working == group["total"] else (Color.YELLOW if working > 0 else Color.RED)
        else:
            status = " (работает)" if working > 0 else " (не работает)"
            status_color = Color.GREEN if working > 0 else Color.RED

        var label = row.get_child(0)
        if label is Label:
            label.text = display_name + status
            label.add_theme_color_override("font_color", status_color)

func refresh_built():
    for child in built_buildings_list.get_children():
        child.queue_free()
    construction_rows.clear()
    last_built_count = built_buildings.size()
    last_construction_count = CityData.building_construction.size()

    # Сначала строки строящихся зданий
    _refresh_construction_rows()

    # Группируем однотипные здания
    var groups = _group_buildings()

    for g in groups:
        var bdata = null
        for b in buildings_data:
            if b["id"] == g["id"]:
                bdata = b
                break
        var base_name = bdata["name"] if bdata else g["id"]
        var display_name = "%s x%d" % [base_name, g["total"]] if g["total"] > 1 else base_name

        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 10)

        var working = g["working"]
        var idle = g["idle"]
        var status = ""
        var status_color = Color.WHITE
        if idle > 0:
            # Есть простаивающие здания (работник есть, но все слоты пустые)
            if g["total"] > 1:
                if idle == g["total"]:
                    status = " (простаивает)"
                else:
                    status = " (работает: %d из %d, простаивает: %d)" % [working, g["total"], idle]
            else:
                status = " (простаивает)"
            status_color = Color.ORANGE
        elif g["total"] > 1:
            status = " (работает: %d из %d)" % [working, g["total"]]
            status_color = Color.GREEN if working == g["total"] else (Color.YELLOW if working > 0 else Color.RED)
        else:
            status = " (работает)" if working > 0 else " (не работает)"
            status_color = Color.GREEN if working > 0 else Color.RED

        var label = Label.new()
        label.text = display_name + status
        label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        label.add_theme_color_override("font_color", status_color)
        row.add_child(label)

        # Кнопка открытия панели деталей здания (сгруппированные здания этого типа)
        var slots_btn = Button.new()
        slots_btn.custom_minimum_size = Vector2(28, 28)
        slots_btn.expand_icon = true
        slots_btn.icon = _get_icon("info")
        slots_btn.tooltip_text = "Дополнительно"
        slots_btn.pressed.connect(_on_building_slots_pressed.bind(g["id"]))
        row.add_child(slots_btn)

        built_buildings_list.add_child(row)
    last_built_count = built_buildings.size()

    # Кнопка «Построить» остаётся активной даже при достижении лимита строек,
    # чтобы при нажатии можно было показать сообщение о причине отказа.
    # Блокируется только когда не выбрано здание.
    if build_button:
        build_button.disabled = (selected_building_id == "")

# Создаёт строки строящихся зданий в панели построенных зданий.
func _refresh_construction_rows():
    for build_key in CityData.building_construction.keys():
        var construction_data = CityData.building_construction[build_key]
        var building_id = construction_data.get("building_id", "")
        var bdata = null
        for b in buildings_data:
            if b["id"] == building_id:
                bdata = b
                break
        var base_name = bdata["name"] if bdata else building_id

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

        # Кнопка приостановки/возобновления строительства
        var pause_btn = Button.new()
        pause_btn.custom_minimum_size = Vector2(28, 28)
        pause_btn.expand_icon = true
        pause_btn.icon = _get_icon("pause")
        pause_btn.tooltip_text = "Приостановить строительство"
        pause_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        pause_btn.pressed.connect(_on_construction_pause_pressed.bind(build_key))
        row.add_child(pause_btn)

        # Кнопка отмены строительства
        var cancel_btn = Button.new()
        cancel_btn.custom_minimum_size = Vector2(28, 28)
        cancel_btn.text = "✕"
        cancel_btn.tooltip_text = "Отменить строительство"
        cancel_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        cancel_btn.pressed.connect(_on_construction_cancel_pressed.bind(build_key))
        row.add_child(cancel_btn)

        built_buildings_list.add_child(row)
        construction_rows[build_key] = {
            "row": row,
            "bar": bar,
            "pause_btn": pause_btn,
            "cancel_btn": cancel_btn
        }

# Обновляет прогресс-бары и кнопки строящихся зданий.
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
        var status_text = "Строится"
        if status == "paused":
            status_text = "Приостановлено"

        var bar = row_data["bar"]
        bar.value = percent

        var pause_btn = row_data["pause_btn"]
        if status == "paused":
            pause_btn.icon = _get_icon("resume")
            pause_btn.tooltip_text = "Возобновить строительство"
        else:
            pause_btn.icon = _get_icon("pause")
            pause_btn.tooltip_text = "Приостановить строительство"

# Возвращает данные о прогресс-баре строящегося здания под курсором.
# Возвращает пустой словарь, если курсор не над ни одним баром.
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
            var status_text = "Строится"
            if status == "paused":
                status_text = "Приостановлено"
            return {
                "bar": bar,
                "status_text": status_text,
                "percent": percent
            }
    return {}

# Группирует построенные здания по id и считает работающие.
# idle — здания, у которых есть работник, но все слоты пустые (простаивают).
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
            groups.append({"id": bld_id, "total": 0, "working": 0, "idle": 0})
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
    return groups

# Возвращает текстуру иконки по имени файла (из icon_paths), кэшируя её.
# Если файла нет или имя пустое — возвращает null (тогда иконка не ставится).
func _get_icon_texture_from_paths(icon_file: String) -> Texture2D:
    if icon_file.is_empty():
        return null
    if icon_textures.has(icon_file):
        return icon_textures[icon_file]
    if icon_paths.has(icon_file):
        var tex = load(icon_paths[icon_file])
        icon_textures[icon_file] = tex
        return tex
    return null

func _get_icon(icon_name: String) -> Texture2D:
    if icon_name == "resume" and resume_icon:
        return resume_icon
    if icon_name == "pause" and pause_icon:
        return pause_icon
    if icon_name == "info" and info_icon:
        return info_icon

    match icon_name:
        "resume":
            resume_icon = load("res://icons/building_resume.png")
            return resume_icon
        "pause":
            pause_icon = load("res://icons/building_pause.png")
            return pause_icon
        "info":
            info_icon = load("res://icons/additional_info.png")
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

# --- Тултип деталей по наведению (любая кнопка здания, не только выбранная) ---
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
    # Возвращает кнопку здания под курсором, если она ещё существует.
    if _hovered_building_id == "":
        return null
    var btn = building_buttons.get(_hovered_building_id, null)
    if btn and is_instance_valid(btn):
        return btn
    return null

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
    # Очищаем предыдущее содержимое тултипа.
    for child in content.get_children():
        content.remove_child(child)
        child.queue_free()

    if bdata.is_empty():
        ui_helpers.hide_building_detail_tooltip()
        return

    # Заголовок — название здания
    var title = Label.new()
    title.text = bdata["name"]
    title.add_theme_font_size_override("font_size", 18)
    title.add_theme_color_override("font_color", Color.WHITE)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(title)

    # Описание здания
    var desc = bdata.get("description", "")
    if desc != "":
        var desc_label = Label.new()
        desc_label.text = desc
        desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        # Фиксированная ширина: без неё min-высота текста с автопереносом
        # считается при ширине ~0 (огромная), тултип прыгает к верхнему краю
        # и «падает» к курсору на следующих кадрах раскладки.
        desc_label.custom_minimum_size = Vector2(420, 0)
        desc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        content.add_child(desc_label)

    # Заголовок стоимости
    var cost_header = Label.new()
    cost_header.text = "Стоимость:"
    cost_header.add_theme_font_size_override("font_size", 14)
    cost_header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    cost_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(cost_header)

    var products_data = {}
    for pid in products:
        products_data[pid] = products[pid]
    for rid in raw_resources:
        products_data[rid] = raw_resources[rid]
    var icon_paths = {}
    _build_icon_index_local(icon_paths)

    var has_costs := false
    var work_cost = bdata.get("work_cost", 0)
    if work_cost > 0:
        var labor = CityData.get_total_labor()
        var build_time = work_cost / max(1.0, labor)
        content.add_child(_make_bullet_row("•", "Труд: %d (%.0f сек)" % [int(work_cost), build_time]))
        has_costs = true

    if bdata.has("additional_cost"):
        # Нужны ресурсы из каждой пачки (AND-логика сохранена на уровне данных)
        var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
        var mat_rows = []
        for bundle in bundles:
            for res_id in bundle:
                mat_rows.append([res_id, int(bundle[res_id])])
        if not mat_rows.is_empty():
            has_costs = true
            content.add_child(_make_bullet_row("•", "Дополнительные материалы:"))
            for entry in mat_rows:
                var row = HBoxContainer.new()
                row.add_theme_constant_override("separation", 6)
                row.mouse_filter = Control.MOUSE_FILTER_IGNORE
                var indent = Control.new()
                indent.custom_minimum_size = Vector2(18, 0)
                var sub_bullet = _make_bullet("◦")
                row.add_child(indent)
                row.add_child(sub_bullet)
                row.add_child(ui_helpers.make_resource_entry(entry[0], products_data, icon_paths, entry[1], "colon"))
                content.add_child(row)

    if not has_costs:
        content.add_child(_make_bullet_row("•", "0"))

    # Количество слотов производства
    var slots = bdata.get("production_slots", 0)
    var slots_label = Label.new()
    slots_label.text = "Слотов производства: %d" % int(slots)
    slots_label.add_theme_font_size_override("font_size", 14)
    slots_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    slots_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(slots_label)

    build_button.disabled = false
    _refresh_recipes_list(bdata)

func _on_build_pressed():
    if selected_building_id == "":
        if ui_helpers:
            ui_helpers.set_message("Не выбрано здание")
        return

    if _has_active_building_construction():
        if ui_helpers:
            ui_helpers.set_message("Можно строить не более %d зданий или улучшений одновременно (лимит = число жителей)" % CityData.total_population)
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
    
    # Проверяем, достаточно ли населения для строительства
    if work_cost > 0 and CityData.get_total_labor() <= 0:
        missing_parts.append("нужен хотя бы 1 житель для строительства")

    if bdata.has("additional_cost"):
        # Каждая пачка (или единственный словарь) проверяется отдельно —
        # для постройки нужны ресурсы из КАЖДОЙ пачки. Групповые ключи
        # (@xxx) учитываются как «любой продукт из группы» — сумма по членам.
        var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
        for bundle in bundles:
            for res_id in bundle:
                var required = bundle[res_id]
                var available = GameData.get_storage_amount(res_id, city_storage)
                if available < required:
                    missing_parts.append("%s %d" % [GameData.format_resource_name(res_id), int(required)])

    if missing_parts.size() > 0:
        if ui_helpers:
            ui_helpers.set_message("Не хватает: " + ", ".join(missing_parts))
        return

    emit_signal("build_requested", selected_building_id)
    
    # Если это здание с стоимостью в труде - показываем сообщение о начале стройки
    if work_cost > 0 and ui_helpers:
        var labor = CityData.get_total_labor()
        var build_time = work_cost / max(1.0, labor)
        ui_helpers.set_message("Начато строительство %s (%.0f труда, %.0f сек)" % [bdata.get("name", selected_building_id), work_cost, build_time])

# Очищает список рецептов
func _has_active_building_construction() -> bool:
    # Общий лимит одновременных строек (здания + улучшения) равен числу жителей
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
                ui_helpers.set_message("Строительство возобновлено")
    else:
        if bm.pause_building_build(build_key):
            if ui_helpers:
                ui_helpers.set_message("Строительство приостановлено")

    _update_construction_rows()

func _on_construction_cancel_pressed(build_key: String):
    _confirm_cancel_construction(build_key)

func _confirm_cancel_construction(build_key: String):
    var dialog = ConfirmationDialog.new()
    dialog.title = "Подтверждение"
    dialog.dialog_text = "Отменить стройку? Потраченный труд сгорит."
    # Локализуем стандартные кнопки диалога (по умолчанию Godot показывает
    # английские «OK» / «Cancel» — проект без файлов переводов).
    dialog.get_ok_button().text = "Да"
    dialog.get_cancel_button().text = "Отмена"
    add_child(dialog)

    # Ставим игру на паузу, пока открыт диалог подтверждения отмены.
    var was_paused = get_tree().paused
    get_tree().paused = true
    # Диалог должен принимать ввод, когда дерево приостановлено.
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS

    dialog.popup_centered()
    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        _cancel_construction(build_key)
    )
    # Крестик окна и кнопка «Отмена» тоже снимают паузу.
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
        ui_helpers.set_message("Стройка отменена")
    CityData.emit_signal("city_updated")
    refresh_built()

# Заполняет список доступных рецептов для выбранного здания
func _refresh_recipes_list(bdata: Dictionary):
    if not ui_helpers or bdata.is_empty():
        return
    var content: VBoxContainer = ui_helpers.detail_tooltip_content

    var building_id = bdata.get("id", "")
    var available_recipes = []

    # Собираем рецепты, доступные для этого здания (с учётом технологий)
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

    # Сортируем по имени
    available_recipes.sort_custom(func(a, b):
        return a.get("name", "") < b.get("name", "")
    )

    # Для отображения иконок ресурсов/продуктов нужен словарь products + raw_resources
    var products_data = {}
    for pid in products:
        products_data[pid] = products[pid]
    for rid in raw_resources:
        products_data[rid] = raw_resources[rid]
    var icon_paths = {}
    _build_icon_index_local(icon_paths)

    var header = Label.new()
    header.text = "Доступные рецепты:"
    header.add_theme_font_size_override("font_size", 14)
    header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_child(header)

    for craft in available_recipes:
        var craft_name = craft.get("name", craft["id"])
        var craft_resources = craft.get("resources", {})
        var craft_result = craft.get("result", {})

        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 4)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE

        # Маркер маркированного списка
        var bullet = Label.new()
        bullet.text = "•"
        bullet.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(bullet)

        # Название рецепта (прежний формат: "название: ресурсы -> результат")
        var name_label = Label.new()
        name_label.text = craft_name + ":"
        name_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        name_label.custom_minimum_size = Vector2(130, 0)
        name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(name_label)

        # Ресурсы -> результат в одну строку
        var content_entry = _make_craft_content_local("", craft_resources, craft_result, products_data, icon_paths, {})
        content_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        content_entry.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(content_entry)

        content.add_child(row)

# Строит содержимое строки рецепта: "[иконка] ресурс [xN] + ... -> [иконка] продукт [xN]"
func _make_craft_content_local(craft_name: String, craft_resources: Dictionary, craft_result: Dictionary, products_data: Dictionary, icon_paths: Dictionary, icon_textures: Dictionary) -> HBoxContainer:
    var content = HBoxContainer.new()
    content.add_theme_constant_override("separation", 4)
    content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    content.mouse_filter = Control.MOUSE_FILTER_IGNORE

    if not craft_resources.is_empty():
        var first = true
        for res_id in craft_resources:
            if not first:
                var sep = Label.new()
                sep.text = "+"
                sep.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
                sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(sep)
            first = false

            content.add_child(ui_helpers.make_resource_entry(res_id, products_data, icon_paths))

            var amount = craft_resources[res_id]
            if amount > 1:
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

            content.add_child(ui_helpers.make_resource_entry(prod_id, products_data, icon_paths))

            var amount = craft_result[prod_id]
            if amount > 1:
                var amount_label = Label.new()
                amount_label.text = "x%d" % amount
                amount_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
                amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(amount_label)

    return content

func _build_icon_index_local(out_paths: Dictionary):
    out_paths.clear()
    _scan_folder_local("res://icons", out_paths)

func _scan_folder_local(folder_path: String, out_paths: Dictionary):
    var dir = DirAccess.open(folder_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            _scan_folder_local(folder_path.path_join(file_name), out_paths)
        else:
            var full_path = folder_path.path_join(file_name)
            if not out_paths.has(file_name):
                out_paths[file_name] = full_path
        file_name = dir.get_next()
    dir.list_dir_end()

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
            if not icon_paths.has(file_name):
                icon_paths[file_name] = full_path
        file_name = dir.get_next()
    dir.list_dir_end()
