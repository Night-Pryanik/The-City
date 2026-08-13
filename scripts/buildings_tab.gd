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

var buildings_item_list: ItemList
var building_name_label: Label
var building_cost_label: Label
var building_recipes_label: Label
var build_button: Button
var built_buildings_list: Node
var food_label: Label
var hsplit: HSplitContainer
var last_built_count: int = -1
var last_construction_count: int = -1
var _cached_build_manager = null

var recipes_scroll: ScrollContainer
var recipes_container: VBoxContainer
var recipes_title: Label

var resume_icon: Texture2D
var pause_icon: Texture2D
var info_icon: Texture2D

var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}

# Строки строящихся зданий: build_key -> { "row": HBoxContainer, "bar": ProgressBar, "pause_btn": Button }
var construction_rows: Dictionary = {}

signal build_requested(building_id: String)
signal building_detail_requested(building_id: String)

func setup(item_list: ItemList, name_lbl: Label, cost_lbl: Label, recipes_lbl: Label, btn: Button, built_list: Node, food_lbl: Label, splitter: HSplitContainer, helpers: Node):
    buildings_item_list = item_list
    building_name_label = name_lbl
    building_cost_label = cost_lbl
    building_recipes_label = recipes_lbl
    build_button = btn
    built_buildings_list = built_list
    food_label = food_lbl
    hsplit = splitter
    ui_helpers = helpers

    set_process(true)

    _build_icon_index()

    if not buildings_item_list.item_selected.is_connected(_on_building_selected):
        buildings_item_list.item_selected.connect(_on_building_selected)
    if not build_button.pressed.is_connected(_on_build_pressed):
        build_button.pressed.connect(_on_build_pressed)
    build_button.disabled = true

    # BuildingRecipesLabel становится заголовком "Слотов производства:"
    building_recipes_label.text = "Слотов производства:"
    building_recipes_label.add_theme_font_size_override("font_size", 16)

    # Создаём контейнер для списка рецептов (вертикальный скролл под заголовком слотов)
    var parent = building_recipes_label.get_parent()

    # Заголовок списка рецептов (добавляем ПЕРЕД скроллом, чтобы он был сверху)
    recipes_title = Label.new()
    recipes_title.text = "Доступные рецепты:"
    recipes_title.add_theme_font_size_override("font_size", 16)
    recipes_title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    recipes_title.visible = false
    parent.add_child(recipes_title)

    recipes_scroll = ScrollContainer.new()
    recipes_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    parent.add_child(recipes_scroll)

    recipes_container = VBoxContainer.new()
    recipes_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    recipes_container.add_theme_constant_override("separation", 6)
    recipes_scroll.add_child(recipes_container)

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
    buildings_item_list.clear()
    selected_building_id = ""
    build_button.disabled = true
    # Скрываем тултип и очищаем заголовок/детали здания при обновлении списка
    if ui_helpers:
        ui_helpers.set_message("")
        ui_helpers.hide_group_tooltip()
    food_label.visible = false
    building_name_label.text = ""
    building_cost_label.text = ""
    building_recipes_label.visible = false
    recipes_title.visible = false
    recipes_scroll.visible = false
    _clear_recipes_list()
    for bld in buildings_data:
        # Фильтруем здания: показываем только те, что открыты изученными технологиями
        if not CityData.is_building_unlocked(bld["id"]):
            continue
        var item_text = bld["name"]
        buildings_item_list.add_item(item_text)
    center_split_offset()

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

func center_split_offset():
    if hsplit:
        # Находим VBoxContainer внутри AvailableBuildingsPanel
        var available_panel = hsplit.get_node("AvailableBuildingsPanel")
        if available_panel:
            var vbox = available_panel.get_node("VBoxContainer")
            if vbox:
                # Устанавливаем разделитель по ширине VBoxContainer
                hsplit.split_offset = vbox.size.x
                return
        # Fallback: если не нашли VBoxContainer, используем половину ширины
        hsplit.split_offset = hsplit.size.x / 2

func _on_building_selected(idx: int):
    if ui_helpers:
        ui_helpers.set_message("")
        ui_helpers.hide_group_tooltip()
    # idx — индекс в отфильтрованном списке ItemList, поэтому нужно найти
    # соответствующее здание, пропуская скрытые (недоступные по технологиям).
    var filtered_buildings = []
    for b in buildings_data:
        if CityData.is_building_unlocked(b["id"]):
            filtered_buildings.append(b)
    if idx >= 0 and idx < filtered_buildings.size():
        selected_building_id = filtered_buildings[idx]["id"]
        var bdata = filtered_buildings[idx]
        building_name_label.text = bdata["name"]

        # Стоимость: каждый ресурс на отдельной строке.
        # Труд идёт первым, потом все элементы additional_cost. Групповые ресурсы
        # (@...) выводятся через format_resource_name (только название группы).
        # AND-логика additional_cost (нужны ресурсы из КАЖДОЙ пачки одновременно)
        # сохранена на уровне данных — на UI все ресурсы просто перечисляются
        # списком, потому что «нужны все» и так подразумевается в блоке стоимости.
        var cost_lines: Array = []
        var work_cost = bdata.get("work_cost", 0)
        if work_cost > 0:
            var labor = CityData.get_total_labor()
            var build_time = work_cost / max(1.0, labor)
            cost_lines.append("труд: %d (%.0f сек)" % [int(work_cost), build_time])
        if bdata.has("additional_cost"):
            var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
            for bundle in bundles:
                for res_id in bundle:
                    cost_lines.append("%s: %d" % [GameData.format_resource_name(res_id), int(bundle[res_id])])
        if cost_lines.is_empty():
            building_cost_label.text = "Стоимость: 0"
        else:
            building_cost_label.text = "Стоимость:\n" + "\n".join(cost_lines)

        # Показываем количество слотов производства
        var slots = bdata.get("production_slots", 0)
        building_recipes_label.text = "Слотов производства: %d" % int(slots)
        building_recipes_label.visible = true

        build_button.disabled = (selected_building_id == "")
        _refresh_recipes_list(bdata)
    else:
        selected_building_id = ""
        build_button.disabled = true
        building_recipes_label.visible = false
        _clear_recipes_list()

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
func _clear_recipes_list():
    for child in recipes_container.get_children():
        child.queue_free()

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
    add_child(dialog)
    dialog.popup_centered()
    dialog.confirmed.connect(func(): _cancel_construction(build_key))

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
    _clear_recipes_list()

    if not bdata:
        recipes_title.visible = false
        recipes_scroll.visible = false
        return

    recipes_title.visible = true
    recipes_scroll.visible = true
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

    var icon_textures = {}
    var icon_paths = {}
    _build_icon_index_local(icon_paths)

    for craft in available_recipes:
        var craft_name = craft.get("name", craft["id"])
        var craft_resources = craft.get("resources", {})
        var craft_result = craft.get("result", {})

        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 4)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE

        # Название рецепта
        var name_label = Label.new()
        name_label.text = craft_name + ":"
        name_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
        name_label.custom_minimum_size = Vector2(130, 0)
        name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(name_label)

        # Ресурсы -> результат в одну строку
        var content = _make_craft_content_local("", craft_resources, craft_result, products_data, icon_paths, icon_textures)
        content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        content.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(content)

        recipes_container.add_child(row)

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

            var pdata = products_data.get(res_id, {})
            var icon_name = pdata.get("icon", "")
            var tex = _get_icon_texture_local(icon_name, icon_paths, icon_textures)
            if tex:
                var icon_rect = TextureRect.new()
                icon_rect.texture = tex
                icon_rect.custom_minimum_size = Vector2(20, 20)
                icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(icon_rect)

            var res_label = Label.new()
            res_label.text = GameData.format_resource_name(res_id)
            res_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            content.add_child(res_label)

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

            var pdata = products_data.get(prod_id, {})
            var icon_name = pdata.get("icon", "")
            var tex = _get_icon_texture_local(icon_name, icon_paths, icon_textures)
            if tex:
                var icon_rect = TextureRect.new()
                icon_rect.texture = tex
                icon_rect.custom_minimum_size = Vector2(20, 20)
                icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
                content.add_child(icon_rect)

            var prod_label = Label.new()
            prod_label.text = GameData.format_resource_name(prod_id)
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

func _get_icon_texture_local(icon_file: String, icon_paths: Dictionary, icon_textures: Dictionary) -> Texture2D:
    if icon_file.is_empty():
        return null
    if icon_textures.has(icon_file):
        return icon_textures[icon_file]
    if icon_paths.has(icon_file):
        var tex = load(icon_paths[icon_file])
        icon_textures[icon_file] = tex
        return tex
    return null

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
