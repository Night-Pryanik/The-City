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
var pause_button: Button
var cancel_button: Button
var built_buildings_list: Node
var food_label: Label
var hsplit: HSplitContainer
var last_built_count: int = -1
var building_progress_label: Label
var building_progress_bar: ProgressBar
var _cached_build_manager = null

var recipes_scroll: ScrollContainer
var recipes_container: VBoxContainer
var recipes_title: Label

var resume_icon: Texture2D
var pause_icon: Texture2D
var info_icon: Texture2D

var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}

signal build_requested(building_id: String)
signal building_detail_requested(building_id: String)

func setup(item_list: ItemList, name_lbl: Label, cost_lbl: Label, recipes_lbl: Label, btn: Button, built_list: Node, food_lbl: Label, splitter: HSplitContainer, helpers: Node, pause_btn: Button, cancel_btn: Button, progress_lbl: Label, progress_bar: ProgressBar):
    buildings_item_list = item_list
    building_name_label = name_lbl
    building_cost_label = cost_lbl
    building_recipes_label = recipes_lbl
    build_button = btn
    pause_button = pause_btn
    cancel_button = cancel_btn
    built_buildings_list = built_list
    food_label = food_lbl
    hsplit = splitter
    ui_helpers = helpers
    building_progress_label = progress_lbl
    building_progress_bar = progress_bar
    if building_progress_label:
        building_progress_label.visible = false
    if building_progress_bar:
        building_progress_bar.visible = false
    if pause_button:
        pause_button.visible = false
        if not pause_button.pressed.is_connected(_on_toggle_build_pause_pressed):
            pause_button.pressed.connect(_on_toggle_build_pause_pressed)
    if cancel_button:
        cancel_button.visible = false
        if not cancel_button.pressed.is_connected(_on_cancel_build_pressed):
            cancel_button.pressed.connect(_on_cancel_build_pressed)

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
    # Обновляем прогресс-бар строительства зданий каждый кадр,
    # чтобы он был плавным (как прогресс-бары улучшений на карте).
    # Работаем только когда прогресс-бар реально виден на экране.
    if building_progress_bar and building_progress_bar.is_visible_in_tree():
        update_construction_progress()

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
    _hide_construction_progress()
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
    if built_buildings.size() != last_built_count:
        refresh_built()
        return

    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null

    # Группируем здания по id
    var groups = _group_buildings()
    for g in range(groups.size()):
        var row = built_buildings_list.get_child(g)
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
    last_built_count = built_buildings.size()

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

        # Собираем стоимость: труд + дополнительные ресурсы
        var cost_parts = []
        var work_cost = bdata.get("work_cost", 0)
        if work_cost > 0:
            var labor = CityData.get_total_labor()
            var build_time = work_cost / max(1.0, labor)
            cost_parts.append("труд: %d (%.0f сек)" % [work_cost, build_time])
        if bdata.has("additional_cost"):
            for res_id in bdata["additional_cost"]:
                var amount = bdata["additional_cost"][res_id]
                var res_name = GameData.format_resource_name(res_id)
                cost_parts.append("%s: %d" % [res_name, amount])
        building_cost_label.text = "Стоимость: " + ", ".join(cost_parts)

        # Показываем количество слотов производства
        var slots = bdata.get("production_slots", 0)
        building_recipes_label.text = "Слотов производства: %d" % int(slots)
        building_recipes_label.visible = true

        build_button.disabled = _has_active_building_construction()
        _refresh_recipes_list(bdata)
        update_construction_progress()
        update_construction_controls()
    else:
        selected_building_id = ""
        build_button.disabled = true
        building_recipes_label.visible = false
        _clear_recipes_list()
        _hide_construction_progress()
        _hide_construction_controls()

func _on_build_pressed():
    if selected_building_id == "":
        if ui_helpers:
            ui_helpers.set_message("Не выбрано здание")
        return

    if _has_active_building_construction():
        if ui_helpers:
            ui_helpers.set_message("Можно строить только одно здание одновременно")
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
        var additional = bdata["additional_cost"]
        for res_id in additional:
            var required = additional[res_id]
            var available = city_storage.get(res_id, 0)
            if available < required:
                var res_name = GameData.format_resource_name(res_id)
                missing_parts.append("%s %d" % [res_name, required])

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
    return CityData.building_construction.size() > 0

func _hide_construction_progress():
    if building_progress_label:
        building_progress_label.visible = false
    if building_progress_bar:
        building_progress_bar.visible = false

func _hide_construction_controls():
    if pause_button:
        pause_button.visible = false
    if cancel_button:
        cancel_button.visible = false

func _get_selected_build_key() -> String:
    for key in CityData.building_construction.keys():
        var construction_data = CityData.building_construction[key]
        if construction_data.get("building_id", "") == selected_building_id:
            return key
    return ""

func update_construction_controls():
    var build_key = _get_selected_build_key()
    if build_key == "":
        _hide_construction_controls()
        if build_button:
            build_button.disabled = _has_active_building_construction()
        return

    var bm = _get_build_manager()
    if not bm:
        _hide_construction_controls()
        if build_button:
            build_button.disabled = _has_active_building_construction()
        return

    var paused = bm.is_building_build_paused(build_key)
    if pause_button:
        pause_button.visible = true
        if paused:
            pause_button.text = "Возобновить"
        else:
            pause_button.text = "Приостановить"
    if cancel_button:
        cancel_button.visible = true
    if build_button:
        build_button.disabled = _has_active_building_construction()

func _on_toggle_build_pause_pressed():
    var build_key = _get_selected_build_key()
    if build_key == "":
        return

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

    update_construction_progress()
    update_construction_controls()

func _on_cancel_build_pressed():
    var build_key = _get_selected_build_key()
    if build_key == "":
        return
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
    update_construction_progress()
    update_construction_controls()

func update_construction_progress():
    if selected_building_id == "":
        _hide_construction_progress()
        return

    var bm = _get_build_manager()
    if not bm:
        _hide_construction_progress()
        return

    var build_key = ""
    for key in CityData.building_construction.keys():
        var construction_data = CityData.building_construction[key]
        if construction_data.get("building_id", "") == selected_building_id:
            build_key = key
            break

    if build_key == "":
        _hide_construction_progress()
        return

    var progress_data = bm.get_building_build_progress(build_key)
    if progress_data.is_empty():
        _hide_construction_progress()
        return

    var work_cost = progress_data.get("work_cost", 1)
    var progress_value = min(progress_data.get("progress", 0.0), work_cost)
    var percent = 0.0
    if work_cost > 0:
        percent = progress_value / work_cost * 100.0
    var status = progress_data.get("status", "active")
    var status_text = "Строится"
    if status == "paused":
        status_text = "Приостановлено"

    if building_progress_label:
        building_progress_label.text = "%s: %.0f%%" % [status_text, percent]
        building_progress_label.visible = true
    if building_progress_bar:
        building_progress_bar.visible = true
        building_progress_bar.value = percent

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
