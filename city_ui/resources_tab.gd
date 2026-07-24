# resources_tab.gd
extends Node

var ui_helpers: Node
var products: Dictionary = {}
var categories: Array = []
var city_storage: Dictionary = {}
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var city_food_pool: Dictionary = {}
var food_toggles: Dictionary = {}

var resources_list: Node

func setup(res_list: Node, helpers: Node):
    resources_list = res_list
    ui_helpers = helpers

func update_data(data: Dictionary):
    products = data.get("products", {})
    categories = data.get("categories", [])
    city_storage = data.get("city_storage", {})
    production_rates = data.get("production_rates", {})
    consumption_rates = data.get("consumption_rates", {})
    city_food_pool = data.get("city_food_pool", {})

func _get_subgroup_name(subgroup_id: String) -> String:
    for g in GameData.groups:
        if g["id"] == subgroup_id:
            return g["name"]
    return subgroup_id

func refresh():
    for child in resources_list.get_children():
        child.queue_free()
    food_toggles.clear()

    # --- Одомашненные животные по подгруппам ---
    if CityData.domesticated_animals.size() > 0:
        var title = Label.new()
        title.text = "Одомашненные животные:"
        title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        resources_list.add_child(title)

        var animal_subgroups = {}
        for animal_id in CityData.domesticated_animals:
            var data = GameData.raw_resources.get(animal_id, {})
            var subgroup = data.get("subgroup", "other")
            if not animal_subgroups.has(subgroup):
                animal_subgroups[subgroup] = []
            animal_subgroups[subgroup].append({"id": animal_id, "name": data.get("name", animal_id)})

        for subgroup in animal_subgroups.keys():
            var subgroup_label = Label.new()
            subgroup_label.text = "  Подгруппа: " + _get_subgroup_name(subgroup)
            subgroup_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            resources_list.add_child(subgroup_label)

            for animal in animal_subgroups[subgroup]:
                var animal_label = Label.new()
                animal_label.text = "    - " + animal["name"]
                animal_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
                resources_list.add_child(animal_label)

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
            var subgroup = data.get("subgroup", "other")
            if not plant_subgroups.has(subgroup):
                plant_subgroups[subgroup] = []
            plant_subgroups[subgroup].append({"id": plant_id, "name": data.get("name", plant_id)})

        for subgroup in plant_subgroups.keys():
            var subgroup_label = Label.new()
            subgroup_label.text = "  Подгруппа: " + _get_subgroup_name(subgroup)
            subgroup_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            resources_list.add_child(subgroup_label)

            for plant in plant_subgroups[subgroup]:
                var plant_label = Label.new()
                plant_label.text = "    - " + plant["name"]
                plant_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
                resources_list.add_child(plant_label)

        var spacer = Label.new()
        spacer.text = ""
        resources_list.add_child(spacer)

    # --- Товары по категориям (как раньше) ---
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
            resources_list.add_child(row)

            if is_food:
                var toggle = ColorRect.new()
                toggle.custom_minimum_size = Vector2(14, 14)
                var enabled = city_food_pool.get(prod_id, true)
                toggle.color = Color.GREEN if enabled else Color.RED
                toggle.mouse_filter = Control.MOUSE_FILTER_STOP
                toggle.gui_input.connect(_on_food_toggle_input.bind(prod_id, toggle))
                row.add_child(toggle)
                food_toggles[prod_id] = toggle

            var name_label = Label.new()
            name_label.text = "%s: %d  " % [product_name, amount]
            name_label.add_theme_color_override("font_color", Color.WHITE)
            row.add_child(name_label)

            var prod_val = production_rates.get(prod_id, 0)
            var cons_val = consumption_rates.get(prod_id, 0)

            var green_label = Label.new()
            green_label.text = "[+%d" % prod_val
            green_label.add_theme_color_override("font_color", Color.GREEN)
            row.add_child(green_label)

            var slash_label = Label.new()
            slash_label.text = " / "
            slash_label.add_theme_color_override("font_color", Color.WHITE)
            row.add_child(slash_label)

            var red_label = Label.new()
            red_label.text = "-%d]" % cons_val
            red_label.add_theme_color_override("font_color", Color.RED)
            row.add_child(red_label)

    # --- Бонусы за разнообразие (заглушка) ---
    var animal_subgroups_count = 0
    var plant_subgroups_count = 0
    var animal_subgroup_map = {}
    for animal_id in CityData.domesticated_animals:
        var data = GameData.raw_resources.get(animal_id, {})
        var subgroup = data.get("subgroup", "other")
        animal_subgroup_map[subgroup] = true
    animal_subgroups_count = animal_subgroup_map.size()

    var plant_subgroup_map = {}
    for plant_id in CityData.domesticated_plants:
        var data = GameData.raw_resources.get(plant_id, {})
        var subgroup = data.get("subgroup", "other")
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

        var bonus_label = Label.new()
        bonus_label.text = "Активные бонусы: (будут позже)"
        bonus_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.3))
        resources_list.add_child(bonus_label)

func _on_food_toggle_input(event, prod_id, toggle):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        city_food_pool[prod_id] = not city_food_pool.get(prod_id, true)
        toggle.color = Color.GREEN if city_food_pool[prod_id] else Color.RED
        get_parent()._update_food_label()

func get_food_pool() -> Dictionary:
    return city_food_pool

func get_food_toggles() -> Dictionary:
    return food_toggles
