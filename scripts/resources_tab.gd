# resources_tab.gd
extends Node

var ui_helpers: Node
var products: Dictionary = {}
var categories: Array = []
var city_storage: Dictionary = {}
var city_quality_detail: Dictionary = {}
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var city_food_pool: Dictionary = {}
var food_toggles: Dictionary = {}
var amount_labels: Dictionary = {}
var prod_labels: Dictionary = {}
var cons_labels: Dictionary = {}
var quality_labels: Dictionary = {}
var displayed_products: Dictionary = {}
var diversity_label: Label = null
var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}

# Активный тултип качества (продукт, имя) — для обновления в реальном времени.
var active_quality_product: String = ""
var active_quality_name: String = ""

var resources_list: Node

func setup(res_list: Node, helpers: Node):
    resources_list = res_list
    ui_helpers = helpers
    _build_icon_index()

func update_data(data: Dictionary):
    products = data.get("products", {})
    categories = data.get("categories", [])
    city_storage = data.get("city_storage", {})
    city_quality_detail = data.get("city_quality_detail", {})
    production_rates = data.get("production_rates", {})
    consumption_rates = data.get("consumption_rates", {})
    city_food_pool = data.get("city_food_pool", {})

func _get_subgroup_name(subgroup_id: String) -> String:
    for g in GameData.groups:
        if g["id"] == subgroup_id:
            return g["name"]
    return subgroup_id

# Возвращает массив подгрупп ресурса. Поддерживает как строку, так и массив.
func _get_subgroups(data: Dictionary) -> Array:
    var subgroup = data.get("subgroup", "other")
    if subgroup is Array:
        return subgroup
    return [subgroup]

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

func refresh():
    _build_icon_index()
    
    for child in resources_list.get_children():
        child.queue_free()
    food_toggles.clear()
    amount_labels.clear()
    prod_labels.clear()
    cons_labels.clear()
    displayed_products.clear()
    diversity_label = null

    # --- Одомашненные животные по подгруппам ---
    if CityData.domesticated_animals.size() > 0:
        var title = Label.new()
        title.text = "Одомашненные животные:"
        title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        resources_list.add_child(title)

        var animal_subgroups = {}
        for animal_id in CityData.domesticated_animals:
            var data = GameData.raw_resources.get(animal_id, {})
            for subgroup in _get_subgroups(data):
                if not animal_subgroups.has(subgroup):
                    animal_subgroups[subgroup] = []
                animal_subgroups[subgroup].append({"id": animal_id, "name": data.get("name", animal_id), "icon": data.get("icon", "")})

        for subgroup in animal_subgroups.keys():
            var subgroup_label = Label.new()
            subgroup_label.text = "  Подгруппа: " + _get_subgroup_name(subgroup)
            subgroup_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            resources_list.add_child(subgroup_label)

            for animal in animal_subgroups[subgroup]:
                var row = HBoxContainer.new()
                row.add_theme_constant_override("separation", 6) # расстояние между иконкой и текстом
                if not animal["icon"].is_empty():
                    var tex = _get_icon_texture(animal["icon"])
                    if tex:
                        var icon_rect = TextureRect.new()
                        icon_rect.texture = tex
                        icon_rect.custom_minimum_size = Vector2(24, 24)
                        icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                        icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                        row.add_child(icon_rect)
                var animal_label = Label.new()
                animal_label.text = animal["name"]
                animal_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
                row.add_child(animal_label)
                resources_list.add_child(row)

        var spacer = Label.new()
        spacer.text = ""
        resources_list.add_child(spacer)

    # --- Одомашненные растения по подгруппам ---
    if CityData.domesticated_plants.size() > 0:
        var title = Label.new()
        title.text = "Одомашненные растения:"
        title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        resources_list.add_child(title)

        var plant_subgroups = {}
        for plant_id in CityData.domesticated_plants:
            var data = GameData.raw_resources.get(plant_id, {})
            for subgroup in _get_subgroups(data):
                if not plant_subgroups.has(subgroup):
                    plant_subgroups[subgroup] = []
                plant_subgroups[subgroup].append({"id": plant_id, "name": data.get("name", plant_id), "icon": data.get("icon", "")})

        for subgroup in plant_subgroups.keys():
            var subgroup_label = Label.new()
            subgroup_label.text = "  Подгруппа: " + _get_subgroup_name(subgroup)
            subgroup_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            resources_list.add_child(subgroup_label)

            for plant in plant_subgroups[subgroup]:
                var row = HBoxContainer.new()
                row.add_theme_constant_override("separation", 6)
                if not plant["icon"].is_empty():
                    var tex = _get_icon_texture(plant["icon"])
                    if tex:
                        var icon_rect = TextureRect.new()
                        icon_rect.texture = tex
                        icon_rect.custom_minimum_size = Vector2(24, 24)
                        icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                        icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                        row.add_child(icon_rect)
                var plant_label = Label.new()
                plant_label.text = plant["name"]
                plant_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
                row.add_child(plant_label)
                resources_list.add_child(row)

        var spacer = Label.new()
        spacer.text = ""
        resources_list.add_child(spacer)

    # --- Товары по категориям ---
    var grouped = {}
    for prod_id in city_storage:
        var amount = city_storage[prod_id]
        var prod_val = production_rates.get(prod_id, 0)
        if amount <= 0 and prod_val <= 0:
            continue
        var pdata = products.get(prod_id, {})
        var cat = pdata.get("category", "other")
        if not grouped.has(cat):
            grouped[cat] = []
        grouped[cat].append(prod_id)

    var ordered_cats = []
    for cat_entry in categories:
        var cat_id = cat_entry["id"]
        if grouped.has(cat_id):
            ordered_cats.append({"id": cat_id, "name": cat_entry["name"]})
    for cat_id in grouped.keys():
        var already = false
        for entry in ordered_cats:
            if entry["id"] == cat_id:
                already = true
                break
        if not already:
            ordered_cats.append({"id": cat_id, "name": cat_id})

    for cat_info in ordered_cats:
        var cat_id = cat_info["id"]
        var items = grouped[cat_id]
        if items.is_empty():
            continue
        var cat_label = Label.new()
        cat_label.text = "--- " + cat_info["name"] + " ---"
        cat_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        resources_list.add_child(cat_label)

        for prod_id in items:
            var amount = city_storage[prod_id]
            var pdata = products.get(prod_id, {})
            var product_name = pdata.get("name", prod_id)
            var is_food = pdata.get("category") == "food"
            var row = HBoxContainer.new()
            row.add_theme_constant_override("separation", 6)
            resources_list.add_child(row)

            # Чекбокс (только для еды)
            if is_food:
                var toggle = ColorRect.new()
                toggle.custom_minimum_size = Vector2(14, 14)
                var enabled = city_food_pool.get(prod_id, true)
                toggle.color = Color.GREEN if enabled else Color.RED
                toggle.mouse_filter = Control.MOUSE_FILTER_STOP
                toggle.gui_input.connect(_on_food_toggle_input.bind(prod_id, toggle))
                row.add_child(toggle)
                food_toggles[prod_id] = toggle

            # Иконка
            var icon_name = ""
            if GameData.raw_resources.has(prod_id):
                icon_name = GameData.raw_resources[prod_id].get("icon", "")
            elif GameData.products.has(prod_id):
                icon_name = GameData.products[prod_id].get("icon", "")
            if not icon_name.is_empty():
                var tex = _get_icon_texture(icon_name)
                if tex:
                    var icon_rect = TextureRect.new()
                    icon_rect.texture = tex
                    icon_rect.custom_minimum_size = Vector2(24, 24)
                    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                    icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                    row.add_child(icon_rect)

            var name_label = Label.new()
            name_label.text = "%s: %d  " % [product_name, amount]
            name_label.add_theme_color_override("font_color", Color.WHITE)
            row.add_child(name_label)
            amount_labels[prod_id] = name_label

            # Динамика
            var prod_val = production_rates.get(prod_id, 0)
            var cons_val = consumption_rates.get(prod_id, 0)

            var green_label = Label.new()
            green_label.text = "[+%d" % prod_val
            green_label.add_theme_color_override("font_color", Color.GREEN)
            row.add_child(green_label)
            prod_labels[prod_id] = green_label

            var slash_label = Label.new()
            slash_label.text = " / "
            slash_label.add_theme_color_override("font_color", Color.WHITE)
            row.add_child(slash_label)

            var red_label = Label.new()
            red_label.text = "-%d]" % cons_val
            red_label.add_theme_color_override("font_color", Color.RED)
            row.add_child(red_label)
            cons_labels[prod_id] = red_label

            # Разбивка по качеству для этого продукта
            _add_quality_label(row, prod_id, product_name)

            displayed_products[prod_id] = true

    # --- Бонусы за разнообразие (заглушка) ---
    var animal_subgroups_count = 0
    var plant_subgroups_count = 0
    var animal_subgroup_map = {}
    for animal_id in CityData.domesticated_animals:
        var data = GameData.raw_resources.get(animal_id, {})
        for subgroup in _get_subgroups(data):
            animal_subgroup_map[subgroup] = true
    animal_subgroups_count = animal_subgroup_map.size()

    var plant_subgroup_map = {}
    for plant_id in CityData.domesticated_plants:
        var data = GameData.raw_resources.get(plant_id, {})
        for subgroup in _get_subgroups(data):
            plant_subgroup_map[subgroup] = true
    plant_subgroups_count = plant_subgroup_map.size()

    var total_subgroups = animal_subgroups_count + plant_subgroups_count
    if total_subgroups > 0:
        var spacer = Label.new()
        spacer.text = ""
        resources_list.add_child(spacer)
        var div_label = Label.new()
        div_label.text = "Разнообразие: %d подгрупп" % total_subgroups
        div_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
        resources_list.add_child(div_label)
        diversity_label = div_label

        var bonus_label = Label.new()
        bonus_label.text = "Активные бонусы: (будут позже)"
        bonus_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.3))
        resources_list.add_child(bonus_label)

func update_values():
    # Лёгкое обновление: не пересоздаём узлы, а обновляем тексты существующих.
    # Если появились новые продукты (структурное изменение) — вызываем полный refresh.
    for prod_id in city_storage:
        var amount = city_storage[prod_id]
        var prod_val = production_rates.get(prod_id, 0)
        if amount <= 0 and prod_val <= 0:
            continue
        if not displayed_products.has(prod_id):
            refresh()
            return
        if amount_labels.has(prod_id):
            var pdata = products.get(prod_id, {})
            var prod_name = pdata.get("name", prod_id)
            amount_labels[prod_id].text = "%s: %d  " % [prod_name, city_storage.get(prod_id, 0)]
        if prod_labels.has(prod_id):
            prod_labels[prod_id].text = "[+%d" % production_rates.get(prod_id, 0)
        if cons_labels.has(prod_id):
            cons_labels[prod_id].text = "-%d]" % consumption_rates.get(prod_id, 0)
        if food_toggles.has(prod_id):
            var enabled = city_food_pool.get(prod_id, true)
            food_toggles[prod_id].color = Color.GREEN if enabled else Color.RED
        if quality_labels.has(prod_id):
            _update_quality_label(quality_labels[prod_id], prod_id)

    if diversity_label != null and is_instance_valid(diversity_label):
        var animal_subgroup_map = {}
        for animal_id in CityData.domesticated_animals:
            var data = GameData.raw_resources.get(animal_id, {})
            for subgroup in _get_subgroups(data):
                animal_subgroup_map[subgroup] = true
        var plant_subgroup_map = {}
        for plant_id in CityData.domesticated_plants:
            var data = GameData.raw_resources.get(plant_id, {})
            for subgroup in _get_subgroups(data):
                plant_subgroup_map[subgroup] = true
        var total_subgroups = animal_subgroup_map.size() + plant_subgroup_map.size()
        diversity_label.text = "Разнообразие: %d подгрупп" % total_subgroups

    # Обновляем открытый тултип качества свежими данными (в реальном времени).
    if active_quality_product != "" and ui_helpers and is_instance_valid(ui_helpers):
        if ui_helpers.quality_tooltip_panel.visible:
            var fresh_detail = city_quality_detail.get(active_quality_product, {})
            if fresh_detail.is_empty():
                ui_helpers.hide_quality_tooltip()
            else:
                ui_helpers.show_quality_tooltip(
                    get_viewport().get_mouse_position(),
                    active_quality_name,
                    fresh_detail
                )

# Добавляет метку с разбивкой по качеству в строку ресурса.
# Только если для продукта есть данные о качестве (city_quality_detail).
func _add_quality_label(row: HBoxContainer, prod_id: String, product_name: String):
    var detail = city_quality_detail.get(prod_id, {})
    var total = 0
    for qid in detail:
        total += int(detail[qid])
    if total <= 0:
        return

    var quality_label = Label.new()
    quality_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 0.9))
    quality_label.mouse_filter = Control.MOUSE_FILTER_PASS # пропускаем клики к родительской кнопке
    # Показ звёздочек с наведением — тулитп с разбором по качеству
    quality_label.mouse_entered.connect(_on_quality_hover.bind(prod_id, product_name))
    quality_label.mouse_exited.connect(_on_quality_exit)
    _update_quality_label(quality_label, prod_id)
    row.add_child(quality_label)
    quality_labels[prod_id] = quality_label

# Обновляет текст метки качества.
func _update_quality_label(label: Label, prod_id: String):
    var detail = city_quality_detail.get(prod_id, {})
    var total = 0
    for qid in detail:
        total += int(detail[qid])
    if total <= 0:
        label.hide()
        return
    label.show()
    # Вычисляем процент лучшего доступного качества
    var levels = GameData.get_quality_levels()
    var best_count = 0
    if levels.size() > 0:
        best_count = int(detail.get(levels.back(), 0))
    var best_pct = int(round(float(best_count) / float(total) * 100.0))
    label.text = " %s (%d%%)" % [GameData.get_quality_stars(levels.back()) if levels.size() > 0 else "★", best_pct]

# Показывает тулитп с разбивкой по качеству при наведении.
func _on_quality_hover(prod_id: String, product_name: String):
    var detail = city_quality_detail.get(prod_id, {})
    if detail.is_empty():
        return
    active_quality_product = prod_id
    active_quality_name = product_name
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.show_quality_tooltip(get_viewport().get_mouse_position(), product_name, detail)

# Скрывает тулитп качества.
func _on_quality_exit():
    active_quality_product = ""
    active_quality_name = ""
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.hide_quality_tooltip()

func _on_food_toggle_input(event, prod_id, toggle):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        city_food_pool[prod_id] = not city_food_pool.get(prod_id, true)
        toggle.color = Color.GREEN if city_food_pool[prod_id] else Color.RED
        if get_parent().has_method("update_food_label"):
            get_parent().update_food_label()

func get_food_pool() -> Dictionary:
    return city_food_pool

func get_food_toggles() -> Dictionary:
    return food_toggles

func get_production_rates() -> Dictionary:
    return production_rates

func get_consumption_rates() -> Dictionary:
    return consumption_rates
