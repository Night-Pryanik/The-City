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
# Кэш карты планового производства (рецепты зданий с горожанином + улучшения
# на карте с их production_interval): product_id ->
# { "Имя источника" -> { "amount": N, "interval": S, "count": M } }.
# Пересчитывается там же.
var planned_production_map: Dictionary = {}

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
    city_food_pool = data.get("city_food_pool", {})
    _update_planned_consumption_map()
    planned_production_map = CityData.get_planned_production_map()

# Пересчитывает кэш планового потребления по worker_manager. Если ссылка ещё не
# прокинута (ранние вызовы до инициализации main_map) — карта пустая, вкладка
# работает как раньше (только фактическая динамика за тик).
func _update_planned_consumption_map():
    planned_consumption_map.clear()
    if worker_manager != null and is_instance_valid(worker_manager) \
            and worker_manager.has_method("get_planned_consumption_map"):
        planned_consumption_map = worker_manager.get_planned_consumption_map()
    # Плановое потребление улучшений (корм пастбищ за цикл) лежит в CityData:
    # worker_manager знает только профессии, городское «all» и спрос зданий.
    var improvement_demand = CityData.get_improvement_planned_consumption()
    for pid in improvement_demand:
        for source_name in improvement_demand[pid]:
            var e: Dictionary = improvement_demand[pid][source_name]
            if not planned_consumption_map.has(pid):
                planned_consumption_map[pid] = {}
            var by_source: Dictionary = planned_consumption_map[pid]
            if not by_source.has(source_name):
                by_source[source_name] = {"amount": 0, "interval": float(e.get("interval", 0.0)), "count": 0, "is_group": false, "group_name": "", "is_population": false}
            var entry: Dictionary = by_source[source_name]
            entry["amount"] = int(entry.get("amount", 0)) + int(e.get("amount", 0))
            entry["count"] = int(entry.get("count", 0)) + int(e.get("count", 1))
            entry["interval"] = minf(float(entry.get("interval", 0.0)), float(e.get("interval", 0.0)))
    # Питание населения: добавляется плановым потреблением для всех продуктов
    # из city_food_pool. Суммарный расход в секунду = (total_population - 1) ×
    # food_per_citizen (один житель — основатель, не ест), интервал SIMULATION_TICK.
    # После коммита 5790016 тултип показывает только плановое потребление —
    # поэтому фактическое «Питание населения» теперь присутствует здесь как
    # план (consumption_sources больше не ведётся). count = число едящих
    # жителей, чтобы UI тултипа показал «(N чел.)» рядом с источником.
    var eaters := int(max(0, CityData.total_population - 1))
    if eaters > 0:
        var pop_food_demand := eaters * int(CityData.food_per_citizen)
        for pid in CityData.city_food_pool:
            if not CityData.city_food_pool.get(pid, false):
                continue
            if not planned_consumption_map.has(pid):
                planned_consumption_map[pid] = {}
            var by_source_pop: Dictionary = planned_consumption_map[pid]
            by_source_pop["Питание населения"] = {
                "amount": pop_food_demand,
                "interval": CityData.SIMULATION_TICK,
                "count": eaters,
                "is_group": false,
                "group_name": "",
                "is_population": true
            }

# Плановое потребление конкретного ресурса: { "Имя источника" -> {...} }.
func _get_planned_for(prod_id: String) -> Dictionary:
    return planned_consumption_map.get(prod_id, {})

# Общее правило списка ресурсов: строка видна только при наличии у игрока
# источника поступления — запас на складе, производство за тик или плановое
# производство (существующий производитель-здание с горожанином).
# Плановое ПОТРЕБЛЕНИЕ строки НЕ добавляет: члены @-группы без своего прихода
# (финики и инжир, когда производится только виноград из «Фруктов»; просо,
# когда добывается только пшеница из «Зерновых культур») в списке не
# появляются и метку плана не показывают. Импорт, когда он появится, даст
# строке приход через производство/запас и сработает по тому же правилу.
# Единственный источник истины для видимости строки — этот метод (и refresh(),
# и update_values()).
func _is_displayable(prod_id: String) -> bool:
    var amount = city_storage.get(prod_id, 0)
    if amount > 0:
        return true
    var prod_val = production_rates.get(prod_id, 0)
    if prod_val > 0:
        return true
    return not planned_production_map.get(prod_id, {}).is_empty()

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

    # --- Одомашненные ресурсы по подгруппам ---
    if CityData.domesticated_resources.size() > 0:
        var title = Label.new()
        title.text = "Одомашненные ресурсы:"
        title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        resources_list.add_child(title)

        var animal_subgroups = {}
        for resource_id in CityData.domesticated_resources:
            var data = GameData.raw_resources.get(resource_id, {})
            for subgroup in _get_subgroups(data):
                if not animal_subgroups.has(subgroup):
                    animal_subgroups[subgroup] = []
                animal_subgroups[subgroup].append({"id": resource_id, "name": data.get("name", resource_id), "icon": data.get("icon", "")})

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
                        icon_rect.custom_minimum_size = Vector2(40, 40)
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

    # --- Товары по категориям ---
    var grouped = {}
    for prod_id in city_storage:
        # Наука не показывается на вкладке «Ресурсы»: это не складской товар,
        # а скорость исследований (см. docs.md). Пропуск оставлен и для
        # инертных остатков «science» в старых сейвах.
        if prod_id == "science":
            continue
        # Общее правило списка — см. _is_displayable: ресурс виден только при
        # наличии источника поступления (запас на складе, производство за тик
        # или существующий производитель-здание). Плановое ПОТРЕБЛЕНИЕ строки
        # не добавляет: члены @-группы без своего прихода (финики и инжир, когда
        # производится только виноград из «Фруктов») в список не попадают и
        # метку плана не показывают.
        if not _is_displayable(prod_id):
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
                    icon_rect.custom_minimum_size = Vector2(40, 40)
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

            # Динамика показывает только плановые показатели.
            var green_label = Label.new()
            green_label.text = _format_prod_label(prod_id)
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
    for resource_id in CityData.domesticated_resources:
        var data = GameData.raw_resources.get(resource_id, {})
        for subgroup in _get_subgroups(data):
            animal_subgroup_map[subgroup] = true
    animal_subgroups_count = animal_subgroup_map.size()

    var plant_subgroup_map = {}
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
    # Если состав списка изменился (появился источник поступления или пропал
    # последний) — вызываем полный refresh.
    for prod_id in city_storage:
        # Наука хранится в city_storage, но на складе скрыта — отображается
        # отдельным пулом на вкладке «Технологии» (см. docs.md).
        if prod_id == "science":
            continue
        # Общее правило видимости строки — см. _is_displayable: источник
        # поступления (запас, производство за тик или производитель-здание).
        # Плановое потребление строки не добавляет.
        var should_show = _is_displayable(prod_id)
        # Состав списка изменился (появился приход или пропал последний
        # источник) — пересобираем список, как и при появлении нового продукта.
        if should_show != displayed_products.has(prod_id):
            refresh()
            return
        if not should_show:
            continue
        var amount_label = amount_labels.get(prod_id)
        if amount_label != null and is_instance_valid(amount_label):
            var pdata = products.get(prod_id, {})
            var prod_name = pdata.get("name", prod_id)
            amount_label.text = "%s: %d  " % [prod_name, city_storage.get(prod_id, 0)]
        var prod_label = prod_labels.get(prod_id)
        if prod_label != null and is_instance_valid(prod_label):
            prod_label.text = _format_prod_label(prod_id)
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
        for resource_id in CityData.domesticated_resources:
            var data = GameData.raw_resources.get(resource_id, {})
            for subgroup in _get_subgroups(data):
                animal_subgroup_map[subgroup] = true
        var plant_subgroup_map = {}
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
                    fresh_detail,
                    active_quality_product
                )

    # Обновляем открытый тултип источников прихода/расхода свежими данными.
    # Плановые потребление и производство не зависят от тика — берутся из кэшей
    # planned_consumption_map / planned_production_map. Фактическое производство/
    # потребление в тултипе больше не показывается (см. коммит 5790016).
    if active_flow_product != "" and ui_helpers and is_instance_valid(ui_helpers):
        if ui_helpers.flow_tooltip_panel.visible:
            var special_yield = GameData.get_special_yield(active_flow_product)
            var fresh_planned = _get_planned_for(active_flow_product)
            var fresh_planned_prod = planned_production_map.get(active_flow_product, {})
            if special_yield.is_empty() and fresh_planned.is_empty() \
                    and fresh_planned_prod.is_empty() \
                    and GameData.get_price(active_flow_product) <= 0.0:
                ui_helpers.hide_flow_tooltip()
            else:
                ui_helpers.show_flow_tooltip(
                    get_viewport().get_mouse_position(),
                    active_flow_name,
                    special_yield,
                    active_flow_product,
                    fresh_planned,
                    fresh_planned_prod,
                    # Разбивка по качеству — свежая: пока товар списывается,
                    # уровни в тултипе должны исчезать вместе с запасом.
                    CityData.get_quality_breakdown(active_flow_product)
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
        ui_helpers.show_quality_tooltip(
            get_viewport().get_mouse_position(), product_name, detail, prod_id)

# Скрывает тулитп качества.
func _on_quality_exit():
    active_quality_product = ""
    active_quality_name = ""
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.hide_quality_tooltip()

# Текст красной метки динамики. При наличии списания за тик — факт ("-10]")
# (тик симуляции = SIMULATION_TICK = 1 сек, поэтому факт за тик — это и есть
# расход за секунду); иначе, если есть плановое потребление, — средний расход
# в пересчёте НА СЕКУНДУ с маркером «≈» ("-1≈]"):
# amount × SIMULATION_TICK / interval для интервальных записей и amount как
# есть для «за тик» (рецепты зданий). Приведение честно показывает средний
# расход: 10 ед./100 сек = 0.1 ед./сек.
func _format_cons_label(prod_id: String) -> String:
    var planned = _get_planned_for(prod_id)
    if planned.is_empty():
        return "-0]"
    var per_sec := 0.0
    for source_name in planned:
        var entry: Dictionary = planned[source_name]
        var amount = float(entry.get("amount", 0))
        var interval = float(entry.get("interval", 0))
        if interval > 0.0:
            per_sec += amount * CityData.SIMULATION_TICK / interval
        else:
            per_sec += amount
    if per_sec <= 0.0:
        return "-0]"
    var rate_text = str(int(round(per_sec))) if is_equal_approx(per_sec, round(per_sec)) else "%.1f" % per_sec
    return "-%s≈]" % rate_text

# Текст зелёной метки динамики. При наличии производства за тик — факт
# ("[+10") (тик симуляции = SIMULATION_TICK = 1 сек, факт за тик — это и есть
# выпуск за секунду); иначе, если есть плановое производство, — средний выпуск
# в пересчёте НА СЕКУНДУ со знаком «≈»: рецепты зданий исполняются раз в `time`
# секунд (см. CityData.get_craft_time), улучшения — раз в production_interval,
# поэтому amount × SIMULATION_TICK / interval (запись без интервала — «за
# тик», interval = 0 → amount).
func _format_prod_label(prod_id: String) -> String:
    var planned = planned_production_map.get(prod_id, {})
    if planned.is_empty():
        return "[+0"
    var per_sec := 0.0
    for source_name in planned:
        var entry: Dictionary = planned[source_name]
        var amount = float(entry.get("amount", 0))
        var interval = float(entry.get("interval", 0))
        if interval > 0.0:
            per_sec += amount * CityData.SIMULATION_TICK / interval
        else:
            per_sec += amount
    if per_sec <= 0.0:
        return "[+0"
    var rate_text = str(int(round(per_sec))) if is_equal_approx(per_sec, round(per_sec)) else "%.1f" % per_sec
    return "[+%s≈" % rate_text

# Показывает тултип ресурса (цена + источники прихода/расхода + плановое
# потребление) при наведении на название или динамику на вкладке «Ресурсы».
func _on_flow_hover(prod_id: String, product_name: String):
    var special_yield = GameData.get_special_yield(prod_id)
    var planned = _get_planned_for(prod_id)
    var planned_prod = planned_production_map.get(prod_id, {})
    active_flow_product = prod_id
    active_flow_name = product_name
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.show_flow_tooltip(
            get_viewport().get_mouse_position(), product_name,
            special_yield, prod_id, planned, planned_prod,
            CityData.get_quality_breakdown(prod_id))

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
