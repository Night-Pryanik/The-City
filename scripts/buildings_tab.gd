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

# Блок "Затраты" — отдельные строки для еды и каждого ресурса
var costs_title: Label
var costs_container: VBoxContainer

# Блок "Рецепты" — отдельные строки для каждого рецепта
var recipes_container: VBoxContainer

var resume_icon: Texture2D
var pause_icon: Texture2D
var info_icon: Texture2D

var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}

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

    _build_icon_index()

    if not buildings_item_list.item_selected.is_connected(_on_building_selected):
        buildings_item_list.item_selected.connect(_on_building_selected)
    if not build_button.pressed.is_connected(_on_build_pressed):
        build_button.pressed.connect(_on_build_pressed)
    build_button.disabled = true

    # Создаём отдельный блок "Затраты" между BuildingCostLabel и BuildingRecipesLabel
    # ВАЖНО: все три лейбла находятся в одном VBoxContainer (BuildingDetailsPanel/VBoxContainer)
    var parent_vbox = cost_lbl.get_parent()
    if parent_vbox is VBoxContainer:
        costs_title = Label.new()
        costs_title.text = "Затраты:"
        costs_title.add_theme_font_size_override("font_size", 16)
        parent_vbox.add_child(costs_title)
        # Перемещаем заголовок сразу после BuildingCostLabel
        parent_vbox.move_child(costs_title, cost_lbl.get_index() + 1)

        costs_container = VBoxContainer.new()
        costs_container.add_theme_constant_override("separation", 4)
        parent_vbox.add_child(costs_container)
        parent_vbox.move_child(costs_container, costs_title.get_index() + 1)

        # BuildingRecipesLabel становится заголовком "Рецепты:"
        building_recipes_label.text = "Рецепты:"
        building_recipes_label.add_theme_font_size_override("font_size", 16)

        # Создаём контейнер для рецептов сразу после BuildingRecipesLabel
        recipes_container = VBoxContainer.new()
        recipes_container.add_theme_constant_override("separation", 6)
        parent_vbox.add_child(recipes_container)
        parent_vbox.move_child(recipes_container, recipes_lbl.get_index() + 1)
    else:
        costs_title = null
        costs_container = null
        recipes_container = null

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
    food_label.text = ""
    building_name_label.text = ""
    building_cost_label.text = ""
    _clear_costs()
    _clear_recipes()
    for bld in buildings_data:
        # Фильтруем здания: показываем только те, что открыты изученными технологиями
        if not CityData.is_building_unlocked(bld["id"]):
            continue
        var item_text = bld["name"]
        var cost_food = bld.get("cost_food", 0)
        item_text += " (еда: %d" % cost_food
        if bld.has("additional_cost"):
            for res_id in bld["additional_cost"]:
                var res_name = GameData.format_resource_name(res_id)
                var amount = bld["additional_cost"][res_id]
                item_text += ", %s: %d" % [res_name, amount]
        item_text += ")"
        buildings_item_list.add_item(item_text)
    center_split_offset()

func _clear_costs():
    if costs_container:
        for child in costs_container.get_children():
            costs_container.remove_child(child)
            child.queue_free()
    if costs_title:
        costs_title.visible = false

func _clear_recipes():
    if recipes_container:
        for child in recipes_container.get_children():
            recipes_container.remove_child(child)
            child.queue_free()
    if building_recipes_label:
        building_recipes_label.visible = false

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

        var display_name = "%s x%d" % [base_name, group["total"]] if group["total"] > 1 else base_name
        var status = ""
        var status_color = Color.WHITE
        if group["total"] > 1:
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
        var status = ""
        var status_color = Color.WHITE
        if g["total"] > 1:
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
            groups.append({"id": bld_id, "total": 0, "working": 0})
        var g = null
        for grp in groups:
            if grp["id"] == bld_id:
                g = grp
                break
        g["total"] += 1
        if has_worker:
            g["working"] += 1
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
        building_cost_label.text = "Стоимость в еде: " + str(bdata.get("cost_food", 0))
        _refresh_costs(bdata)

        if bdata.has("additional_cost"):
            var res_texts = []
            for res_id in bdata["additional_cost"]:
                var required = bdata["additional_cost"][res_id]
                var available = city_storage.get(res_id, 0)
                var res_name = GameData.format_resource_name(res_id)
                res_texts.append("%s: %d/%d" % [res_name, available, required])
            food_label.text = "Доп. ресурсы: " + ", ".join(res_texts)
        else:
            food_label.text = ""

        _refresh_recipes(bdata)
        build_button.disabled = false
        get_parent().update_food_label()
    else:
        selected_building_id = ""
        build_button.disabled = true
        food_label.text = ""
        _clear_costs()
        _clear_recipes()

# Заполняет блок "Затраты" — отдельные строки для еды и каждого ресурса.
# Групповые ресурсы (@...) становятся кнопками с тултипом.
func _refresh_costs(bdata):
    _clear_costs()
    if not bdata or costs_container == null:
        return

    var has_costs = false

    # Дополнительные ресурсы
    if bdata.has("additional_cost"):
        for res_id in bdata["additional_cost"]:
            var amount = bdata["additional_cost"][res_id]
            var row = HBoxContainer.new()
            row.add_theme_constant_override("separation", 6)

            if GameData.is_group_key(res_id):
                # Групповой ресурс — кнопка с тултипом
                var group_btn = Button.new()
                group_btn.text = "%s: %d" % [GameData.format_resource_name(res_id), amount]
                group_btn.flat = true
                group_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
                group_btn.mouse_filter = Control.MOUSE_FILTER_STOP
                group_btn.mouse_entered.connect(_on_group_hover.bind(group_btn, res_id))
                group_btn.mouse_exited.connect(_on_group_exit)
                row.add_child(group_btn)
            else:
                # Обычный ресурс — просто текст
                var res_label = Label.new()
                res_label.text = "%s: %d" % [GameData.format_resource_name(res_id), amount]
                row.add_child(res_label)

            costs_container.add_child(row)
            has_costs = true

    if costs_title:
        costs_title.visible = has_costs

# Заполняет блок "Рецепты" — отдельные строки для каждого рецепта.
# Затраты рецепта выводятся в отдельный узел, где групповые ресурсы (@...)
# становятся кнопками с тултипом.
func _refresh_recipes(bdata):
    _clear_recipes()
    if not bdata or recipes_container == null:
        return

    var found = false
    for craft in crafts_data:
        if craft["id"] == "empty":
            continue
        if not CityData.can_craft_in(craft["id"], selected_building_id):
            continue
        # Фильтруем рецепты: показываем только те, что открыты изученными технологиями
        var craft_unlock_tech = craft.get("unlock_tech", "")
        if craft_unlock_tech != "" and not CityData.is_tech_unlocked(craft_unlock_tech):
            continue

        var recipe_box = VBoxContainer.new()
        recipe_box.add_theme_constant_override("separation", 2)

        # Производит
        var outputs = []
        for res in craft["result"]:
            outputs.append(GameData.format_resource_input(res, craft["result"][res]))
        var produce_label = Label.new()
        produce_label.text = "Производит: " + ", ".join(outputs)
        recipe_box.add_child(produce_label)

        # Затраты — отдельный узел с кнопками-тултипами для групповых ресурсов
        var costs_row = HBoxContainer.new()
        costs_row.add_theme_constant_override("separation", 6)
        var costs_caption = Label.new()
        costs_caption.text = "Затраты:"
        costs_row.add_child(costs_caption)
        for res in craft["resources"]:
            var amount = craft["resources"][res]
            if GameData.is_group_key(res):
                # Групповой ресурс — кнопка с тултипом
                var group_btn = Button.new()
                group_btn.text = "%s: %d" % [GameData.format_resource_name(res), amount]
                group_btn.flat = true
                group_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
                group_btn.mouse_filter = Control.MOUSE_FILTER_STOP
                group_btn.mouse_entered.connect(_on_group_hover.bind(group_btn, res))
                group_btn.mouse_exited.connect(_on_group_exit)
                costs_row.add_child(group_btn)
            else:
                # Обычный ресурс — просто текст
                var res_label = Label.new()
                res_label.text = "%s: %d" % [GameData.format_resource_name(res), amount]
                costs_row.add_child(res_label)
        recipe_box.add_child(costs_row)

        # Время
        var time_label = Label.new()
        time_label.text = "Время: " + str(craft.get("time", 0))
        recipe_box.add_child(time_label)

        recipes_container.add_child(recipe_box)
        found = true

    if building_recipes_label:
        building_recipes_label.visible = found

# Показывает тултип для группового ресурса при наведении на кнопку
func _on_group_hover(button: Button, res_id: String):
    if ui_helpers:
        ui_helpers.show_group_tooltip(
            get_viewport().get_mouse_position(),
            res_id,
            _get_all_resources(),
            icon_paths
        )

# Скрывает тултип при отводе курсора
func _on_group_exit():
    if ui_helpers:
        ui_helpers.hide_group_tooltip()

func _on_build_pressed():
    if selected_building_id == "":
        if ui_helpers:
            ui_helpers.set_message("Не выбрано здание")
        return

    var bdata = null
    for b in buildings_data:
        if b["id"] == selected_building_id:
            bdata = b
            break
    if not bdata:
        return

    var missing_parts = []
    var cost_food = bdata.get("cost_food", 0)
    var available_food = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            available_food += city_storage.get(pid, 0)
    if available_food < cost_food:
        missing_parts.append("еды %d" % cost_food)

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

# Возвращает объединённый словарь всех ресурсов (сырьё + товары)
func _get_all_resources() -> Dictionary:
    var all = {}
    for key in raw_resources:
        all[key] = raw_resources[key]
    for key in products:
        all[key] = products[key]
    return all

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