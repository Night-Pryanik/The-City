# resources_tab.gd
extends Node

var ui_helpers: Node
var products: Dictionary = {}
var categories: Array = []
var city_storage: Dictionary = {}
var city_quality_detail: Dictionary = {}
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var production_sources: Dictionary = {}
var consumption_sources: Dictionary = {}
var city_food_pool: Dictionary = {}
var food_toggles: Dictionary = {}
var amount_labels: Dictionary = {}
var prod_labels: Dictionary = {}
var cons_labels: Dictionary = {}
var quality_labels: Dictionary = {}
var displayed_products: Dictionary = {}
var row_flow_labels: Dictionary = {}
var diversity_label: Label = null
var icon_textures: Dictionary = {}
var icon_paths: Dictionary = {}

# Активный тултип качества (продукт, имя) — для обновления в реальном времени.
var active_quality_product: String = ""
var active_quality_name: String = ""
# Активный тултип источников прихода/расхода (продукт, имя) — для обновления в реальном времени.
var active_flow_product: String = ""
var active_flow_name: String = ""

# Ссылка на WorkerManager (прокидывается из main_map через city_ui.set_worker_manager).
# По нему считается плановое потребление ресурсов (см. _update_planned_consumption_map).
var worker_manager: Node = null
# Кэш карты планового потребления: product_id -> { "Имя источника" -> {...} }.
# Пересчитывается при каждом update_data()/refresh() (раз в тик при открытом городе).
var planned_consumption_map: Dictionary = {}

var resources_list: Node

func setup(res_list: Node, helpers: Node):
    resources_list = res_list
    ui_helpers = helpers
    _build_icon_index()

# Ссылка на WorkerManager прокидывается из main_map через
# city_ui.set_worker_manager() (вызывается в _ready main_map — позже _ready
# city_ui, где создаётся вкладка). До прокидывания planned_consumption_map
# пуста: вкладка работает по-старому, только по фактической динамике за тик.
func set_worker_manager(wm: Node):
    worker_manager = wm

func update_data(data: Dictionary):
    products = data.get("products", {})
    categories = data.get("categories", [])
    city_storage = data.get("city_storage", {})
    city_quality_detail = data.get("city_quality_detail", {})
    production_rates = data.get("production_rates", {})
    consumption_rates = data.get("consumption_rates", {})
    production_sources = data.get("production_sources", {})
    consumption_sources = data.get("consumption_sources", {})
    city_food_pool = data.get("city_food_pool", {})
    _update_planned_consumption_map()

# Пересчитывает кэш планового потребления по worker_manager. Если ссылка ещё не
# прокинута (ранние вызовы до инициализации main_map) — карта пустая, вкладка
# работает как раньше (только фактическая динамика за тик).
func _update_planned_consumption_map():
    planned_consumption_map.clear()
    if worker_manager != null and is_instance_valid(worker_manager) \
            and worker_manager.has_method("get_planned_consumption_map"):
        planned_consumption_map = worker_manager.get_planned_consumption_map()

# Плановое потребление конкретного ресурса: { "Имя источника" -> {...} }.
func _get_planned_for(prod_id: String) -> Dictionary:
    return planned_consumption_map.get(prod_id, {})

# Фактическое потребление для секции «Потребление (текущее)» тултипа.
# Обычно — списание за последний тик. Если в этом тике списания не было, но у
# ресурса есть плановое потребление — показываем последнее фактическое
# (CityData.last_consumption_sources): секция не мигает между тиками списания
# при интервальном потреблении (доход +2/тик, списание 20 раз в 10 тиков).
# Когда планового потребления нет (потребитель удалён), устаревшее значение
# не показывается.
func _get_current_cons_sources(prod_id: String) -> Dictionary:
    var cons_src = consumption_sources.get(prod_id, {})
    if cons_src.is_empty():
        var planned = _get_planned_for(prod_id)
        if not planned.is_empty():
            cons_src = CityData.last_consumption_sources.get(prod_id, {})
    return cons_src

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
    _update_planned_consumption_map()
    
    for child in resources_list.get_children():
        child.queue_free()
    food_toggles.clear()
    amount_labels.clear()
    prod_labels.clear()
    cons_labels.clear()
    quality_labels.clear()
    displayed_products.clear()
    diversity_label = null
    row_flow_labels.clear()
    active_flow_product = ""
    active_flow_name = ""
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.hide_flow_tooltip()

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
                # Ховер на иконке/названии показывает цену ресурса
                var animal_flow_labels: Array = []
                if not animal["icon"].is_empty():
                    var tex = _get_icon_texture(animal["icon"])
                    if tex:
                        var icon_rect = TextureRect.new()
                        icon_rect.texture = tex
                        icon_rect.custom_minimum_size = Vector2(24, 24)
                        icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                        icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                        icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
                        icon_rect.mouse_entered.connect(_on_flow_hover.bind(animal["id"], animal["name"]))
                        icon_rect.mouse_exited.connect(_on_flow_exit.bind(animal["id"]))
                        row.add_child(icon_rect)
                        animal_flow_labels.append(icon_rect)
                var animal_label = Label.new()
                animal_label.text = animal["name"]
                animal_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
                animal_label.mouse_filter = Control.MOUSE_FILTER_PASS
                animal_label.mouse_entered.connect(_on_flow_hover.bind(animal["id"], animal["name"]))
                animal_label.mouse_exited.connect(_on_flow_exit.bind(animal["id"]))
                row.add_child(animal_label)
                animal_flow_labels.append(animal_label)
                resources_list.add_child(row)
                row_flow_labels[animal["id"]] = animal_flow_labels

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
                # Ховер на иконке/названии показывает цену ресурса
                var plant_flow_labels: Array = []
                if not plant["icon"].is_empty():
                    var tex = _get_icon_texture(plant["icon"])
                    if tex:
                        var icon_rect = TextureRect.new()
                        icon_rect.texture = tex
                        icon_rect.custom_minimum_size = Vector2(24, 24)
                        icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                        icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                        icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
                        icon_rect.mouse_entered.connect(_on_flow_hover.bind(plant["id"], plant["name"]))
                        icon_rect.mouse_exited.connect(_on_flow_exit.bind(plant["id"]))
                        row.add_child(icon_rect)
                        plant_flow_labels.append(icon_rect)
                var plant_label = Label.new()
                plant_label.text = plant["name"]
                plant_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
                plant_label.mouse_filter = Control.MOUSE_FILTER_PASS
                plant_label.mouse_entered.connect(_on_flow_hover.bind(plant["id"], plant["name"]))
                plant_label.mouse_exited.connect(_on_flow_exit.bind(plant["id"]))
                row.add_child(plant_label)
                plant_flow_labels.append(plant_label)
                resources_list.add_child(row)
                row_flow_labels[plant["id"]] = plant_flow_labels

        var spacer = Label.new()
        spacer.text = ""
        resources_list.add_child(spacer)

    # --- Товары по категориям ---
    var grouped = {}
    for prod_id in city_storage:
        # Наука не показывается на вкладке «Ресурсы» (общий пул, см. docs.md).
        if prod_id == "science":
            continue
        var amount = city_storage[prod_id]
        var prod_val = production_rates.get(prod_id, 0)
        # Общее правило списка: показываем ресурс только при наличии источника
        # поступления (запас на складе или производство за тик). Плановое
        # потребление НЕ добавляет строки: члены @-группы без своего
        # прихода (просо при расходуемой группе «Зерновые культуры», где есть
        # только пшеница) в список не попадают и метку плана не показывают.
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
            # Явный MOUSE_FILTER_PASS — иначе Label по умолчанию STOP, и при
            # перетаскивании/прокрутке родительского контейнера события мыши
            # могут «проглатываться» строкой, и mouse_entered не сработает.
            name_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(name_label)
            amount_labels[prod_id] = name_label

            # Динамика. Красная метка — факт за тик, а при нуле факта —
            # плановое потребление с маркером «≈» (см. _format_cons_label).
            var prod_val = production_rates.get(prod_id, 0)

            var green_label = Label.new()
            green_label.text = "[+%d" % prod_val
            green_label.add_theme_color_override("font_color", Color.GREEN)
            green_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(green_label)
            prod_labels[prod_id] = green_label

            var slash_label = Label.new()
            slash_label.text = " / "
            slash_label.add_theme_color_override("font_color", Color.WHITE)
            slash_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(slash_label)

            var red_label = Label.new()
            red_label.text = _format_cons_label(prod_id)
            red_label.add_theme_color_override("font_color", Color.RED)
            red_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(red_label)
            cons_labels[prod_id] = red_label
            # Ховер на названии или динамике показывает тултип источников
            var flow_row_labels_arr: Array = []
            for flow_lbl in [name_label, green_label, slash_label, red_label]:
                flow_lbl.mouse_entered.connect(_on_flow_hover.bind(prod_id, product_name))
                flow_lbl.mouse_exited.connect(_on_flow_exit.bind(prod_id))
                flow_row_labels_arr.append(flow_lbl)
            row_flow_labels[prod_id] = flow_row_labels_arr

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
        # Наука хранится в city_storage, но на складе скрыта — отображается
        # отдельным пулом на вкладке «Технологии» (см. docs.md).
        if prod_id == "science":
            continue
        var amount = city_storage[prod_id]
        var prod_val = production_rates.get(prod_id, 0)
        if amount <= 0 and prod_val <= 0:
            continue
        if not displayed_products.has(prod_id):
            refresh()
            return
        var amount_label = amount_labels.get(prod_id)
        if amount_label != null and is_instance_valid(amount_label):
            var pdata = products.get(prod_id, {})
            var prod_name = pdata.get("name", prod_id)
            amount_label.text = "%s: %d  " % [prod_name, city_storage.get(prod_id, 0)]
        var prod_label = prod_labels.get(prod_id)
        if prod_label != null and is_instance_valid(prod_label):
            prod_label.text = "[+%d" % production_rates.get(prod_id, 0)
        var cons_label = cons_labels.get(prod_id)
        if cons_label != null and is_instance_valid(cons_label):
            cons_label.text = _format_cons_label(prod_id)
        var toggle = food_toggles.get(prod_id)
        if toggle != null and is_instance_valid(toggle):
            var enabled = city_food_pool.get(prod_id, true)
            toggle.color = Color.GREEN if enabled else Color.RED
        var q_label = quality_labels.get(prod_id)
        if q_label != null and is_instance_valid(q_label):
            _update_quality_label(q_label, prod_id)

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

    # Обновляем открытый тултип источников прихода/расхода свежими данными.
    # Данные берутся за последний завершённый тик (словари сбрасываются в
    # reset_counters() и наполняются заново при следующем тике). Плановое
    # потребление не зависит от тика — берётся из кэша planned_consumption_map;
    # фактическое при отсутствии списания в этом тике — последнее известное
    # (см. _get_current_cons_sources).
    if active_flow_product != "" and ui_helpers and is_instance_valid(ui_helpers):
        if ui_helpers.flow_tooltip_panel.visible:
            var fresh_prod_src = production_sources.get(active_flow_product, {})
            var fresh_cons_src = _get_current_cons_sources(active_flow_product)
            var special_yield = GameData.get_special_yield(active_flow_product)
            var fresh_planned = _get_planned_for(active_flow_product)
            if fresh_prod_src.is_empty() and fresh_cons_src.is_empty() \
                    and special_yield.is_empty() and fresh_planned.is_empty() \
                    and GameData.get_price(active_flow_product) <= 0.0:
                ui_helpers.hide_flow_tooltip()
            else:
                ui_helpers.show_flow_tooltip(
                    get_viewport().get_mouse_position(),
                    active_flow_name,
                    fresh_prod_src,
                    fresh_cons_src,
                    special_yield,
                    active_flow_product,
                    fresh_planned
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
    var levels = GameData.get_quality_levels()
    # Лучший уровень, который РЕАЛЬНО есть на складе, а не вершина шкалы.
    var shown_qid = ""
    for i in range(levels.size() - 1, -1, -1):
        if int(detail.get(levels[i], 0)) > 0:
            shown_qid = levels[i]
            break
    if shown_qid == "":
        label.hide()
        return
    label.show()
    var shown_count = int(detail.get(shown_qid, 0))
    var shown_pct = int(round(float(shown_count) / float(total) * 100.0))
    label.text = " %s (%d%%)" % [GameData.get_quality_stars(shown_qid), shown_pct]

# Показывает тултип с разбивкой по качеству при наведении.
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

# Текст красной метки динамики. При наличии списания за тик — факт ("-10]");
# иначе, если есть плановое потребление, — план, приведённый к тику, с маркером
# «≈» ("-2≈]"): amount × PRODUCTION_INTERVAL / interval для интервальных
# записей и amount как есть для «за тик» (рецепты зданий). Приведение честно
# показывает средний расход: 10 ед./10 сек = 2 ед. за тик.
func _format_cons_label(prod_id: String) -> String:
    var cons_val = consumption_rates.get(prod_id, 0)
    if cons_val > 0:
        return "-%d]" % cons_val
    var planned = _get_planned_for(prod_id)
    if planned.is_empty():
        return "-0]"
    var per_tick := 0.0
    for source_name in planned:
        var entry: Dictionary = planned[source_name]
        var amount = float(entry.get("amount", 0))
        var interval = float(entry.get("interval", 0))
        if interval > 0.0:
            per_tick += amount * CityData.PRODUCTION_INTERVAL / interval
        else:
            per_tick += amount
    if per_tick <= 0.0:
        return "-0]"
    return "-%d≈]" % maxi(1, int(round(per_tick)))

# Показывает тултип ресурса (цена + источники прихода/расхода + плановое
# потребление) при наведении на название или динамику на вкладке «Ресурсы».
func _on_flow_hover(prod_id: String, product_name: String):
    var prod_src = production_sources.get(prod_id, {})
    var cons_src = _get_current_cons_sources(prod_id)
    var special_yield = GameData.get_special_yield(prod_id)
    var planned = _get_planned_for(prod_id)
    active_flow_product = prod_id
    active_flow_name = product_name
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.show_flow_tooltip(
            get_viewport().get_mouse_position(), product_name, prod_src, cons_src,
            special_yield, prod_id, planned)

# Скрывает тултип источников; при переходе на другую метку той же строки не мерцает.
func _on_flow_exit(prod_id: String):
    var mouse_pos = get_viewport().get_mouse_position()
    var labels: Array = row_flow_labels.get(prod_id, [])
    for lbl in labels:
        if is_instance_valid(lbl) and lbl.get_global_rect().has_point(mouse_pos):
            return
    active_flow_product = ""
    active_flow_name = ""
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.hide_flow_tooltip()

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
