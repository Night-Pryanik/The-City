@tool
extends Node2D

const HEX_RADIUS = 55

# --- Размер карты: меняешь только эти два числа ---
const GRID_ROWS = 5
const GRID_COLS = 7
const REGION_PADDING = 2

const REGION_ROWS = GRID_ROWS + REGION_PADDING * 2
const REGION_COLS = GRID_COLS + REGION_PADDING * 2
const CITY_ROW = REGION_ROWS / 2
const CITY_COL = REGION_COLS / 2
const INFLUENCE_START_ROW = REGION_PADDING
const INFLUENCE_END_ROW = INFLUENCE_START_ROW + GRID_ROWS - 1
const INFLUENCE_START_COL = REGION_PADDING
const INFLUENCE_END_COL = INFLUENCE_START_COL + GRID_COLS - 1
const FORAGING_TIME: float = 3.0
const SCOUTING_TIME: float = 12.0

var tile_data = []
var offset_x: float = 0.0
var offset_y: float = 0.0
var scroll_offset = Vector2.ZERO

var _context_hex = null
var last_city_click_time = 0.0
var production_timer = 0.0
var foraging_timer: float = 0.0
var foraging_hex: Dictionary = {}
var is_foraging: bool = false
var scouting_timer: float = 0.0
var scouting_chunk: Array = []
var is_scouting: bool = false

var settings_config = ConfigFile.new()
var show_hex_borders = true
var use_edge_scrolling = true

@onready var popup_menu = $PopupMenu
@onready var city_ui = $CityUI
@onready var hex_tooltip = $HexTooltip
@onready var tooltip_panel = $HexTooltip
@onready var tooltip_text_label = $HexTooltip/TooltipVBox/TooltipTextLabel
@onready var tooltip_products_container = $HexTooltip/TooltipVBox/TooltipProductsContainer
@onready var hud = $HUD
@onready var city_button = $HUD/VBoxContainer/CityButton
@onready var expansion_button = $HUD/VBoxContainer/ExpansionButton
@onready var pause_menu = $PauseMenu
@onready var build_manager = $BuildManager
@onready var map_renderer = $MapRenderer
@onready var road_manager = $RoadManager
@onready var expansion_manager = $ExpansionManager
@onready var worker_manager = $WorkerManager
@onready var townsfolk_manager = $TownsfolkManager
@onready var settings_menu = preload("res://scenes/settings_menu.tscn").instantiate()
@onready var input_handler = $InputHandler

func _ready():
    if Engine.is_editor_hint():
        _initialize_map()
        map_renderer.initialize(tile_data, self)
        map_renderer.queue_redraw()
        return

    if SaveManager.is_loaded:
        GameData.load_all_data()
        map_renderer.build_icon_index()
        map_renderer.load_icons()
        SaveManager.apply_loaded_data()

        tile_data = []
        road_manager.initialize(CITY_ROW, CITY_COL)
        var saved_tiles = SaveManager.saved_data.get("tile_data", [])
        for row in range(REGION_ROWS):
            var col_array = []
            for col in range(REGION_COLS):
                var tile = {"terrain": "plain", "resource": null, "improvement": null, "terrain_icon": "", "in_influence": false}
                if row < saved_tiles.size() and col < saved_tiles[row].size():
                    var saved = saved_tiles[row][col]
                    if not saved.is_empty():
                        tile["terrain"] = saved.get("terrain", "plain")
                        tile["resource"] = saved.get("resource")
                        tile["improvement"] = saved.get("improvement")
                        tile["terrain_icon"] = saved.get("terrain_icon", "")
                        tile["in_influence"] = saved.get("in_influence", false)
                        tile["is_explored"] = saved.get("is_explored", false)
                col_array.append(tile)
            tile_data.append(col_array)

        # Восстанавливаем назначения рабочих и горожан
        worker_manager.load_assignments(SaveManager.saved_data.get("worker_assignments", []))
        townsfolk_manager.load_assignments(SaveManager.saved_data.get("townsfolk_assignments", []))

        # Пересчитываем свободных жителей по фактически восстановленным назначениям
        var total_assigned = worker_manager.get_assigned_count() + townsfolk_manager.get_assigned_count()
        CityData.idle_population = max(0, CityData.total_population - total_assigned)

        # --- ПРОВЕРКА: если назначения горожан есть, но они не совпадают с количеством зданий, исправляем ---
        var current_buildings_count = CityData.city_built_buildings.size()
        var invalid_keys = []
        for key in townsfolk_manager.assigned_buildings.keys():
            var idx = int(key)
            if idx >= current_buildings_count:
                invalid_keys.append(key)
        for key in invalid_keys:
            townsfolk_manager.assigned_buildings.erase(key)

        if invalid_keys.size() > 0:
            total_assigned = worker_manager.get_assigned_count() + townsfolk_manager.get_assigned_count()
            CityData.idle_population = max(0, CityData.total_population - total_assigned)

        _update_population_hud()

        road_manager.rebuild_roads_from_existing(tile_data, REGION_ROWS, REGION_COLS)

        SaveManager.is_loaded = false
        SaveManager.saved_data.clear()
        map_renderer.initialize(tile_data, self)
    else:
        randomize()
        _initialize_map()
        road_manager.initialize(CITY_ROW, CITY_COL)
        map_renderer.initialize(tile_data, self)

    _load_settings()
    add_child(settings_menu)
    settings_menu.hide()

    # Инициализация InputHandler
    input_handler.initialize(self)

    _calc_offsets()
    map_renderer.queue_redraw()

    _update_population_hud()

    popup_menu.id_pressed.connect(_on_popup_menu_id_pressed)
    city_ui.closed.connect(_on_city_ui_close)
    city_button.pressed.connect(_on_city_button_pressed)
    expansion_button.pressed.connect(_on_expansion_button_pressed)
    city_ui.build_requested.connect(CityData.request_build)
    CityData.city_updated.connect(_on_city_data_updated)
    CityData.research_error.connect(_on_research_error)
    CityData.research_error.connect(hud.show_message)
    CityData.population_changed.connect(_on_population_changed)
    city_ui.research_requested.connect(CityData.start_research)
    CityData.research_completed.connect(_on_research_completed)
    expansion_manager.chunk_hovered.connect(_on_chunk_hovered)
    worker_manager.assignment_changed.connect(_on_assignment_changed)
    townsfolk_manager.assignment_changed.connect(_on_townsfolk_assignment_changed)

    if pause_menu:
        if not pause_menu.save_pressed.is_connected(_on_pause_save):
            pause_menu.save_pressed.connect(_on_pause_save)
        if not pause_menu.load_pressed.is_connected(_on_pause_load):
            pause_menu.load_pressed.connect(_on_pause_load)
        if not pause_menu.new_game_pressed.is_connected(_on_pause_new_game):
            pause_menu.new_game_pressed.connect(_on_pause_new_game)

    build_manager.build_message.connect(hud.show_message)
    build_manager.build_completed.connect(_on_build_completed)
    city_button.gui_input.connect(_on_city_button_gui_input)

    # Сигналы от ExpansionManager
    expansion_manager.expansion_mode_changed.connect(_on_expansion_mode_changed)
    expansion_manager.territory_expanded.connect(_on_territory_expanded)

func _input(event):
    input_handler.handle_input(event)

func _process(delta):
    if Engine.is_editor_hint():
        return

    production_timer += delta
    if production_timer >= CityData.PRODUCTION_INTERVAL:
        production_timer -= CityData.PRODUCTION_INTERVAL
        CityData.reset_counters()
        for row in range(REGION_ROWS):
            for col in range(REGION_COLS):
                var tile = tile_data[row][col]
                if tile.improvement == null or tile.resource == null or not worker_manager.has_worker(row, col):
                    continue

                var res_data = GameData.raw_resources.get(tile.resource, {})
                var feed_needed = res_data.get("feed_consumption", 0)

                if feed_needed > 0:
                    var available_feed = CityData.city_storage.get("feed", 0)
                    if available_feed >= feed_needed:
                        CityData.city_storage["feed"] -= feed_needed
                        CityData.add_raw_production(tile.resource)
                    else:
                        CityData.add_raw_production(tile.resource, 0.25)
                else:
                    CityData.add_raw_production(tile.resource)

        CityData.do_tick()

    CityData.tick_research(delta)
    if CityData.current_research_tech_id != "" or build_manager.active_builds.size() > 0:
        map_renderer.queue_redraw()

    input_handler.handle_process(delta)
    
    if is_foraging:
        foraging_timer += delta
        if foraging_timer >= FORAGING_TIME:
            _complete_foraging()
        map_renderer.queue_redraw()
        
    if is_scouting:
        scouting_timer += delta
        if scouting_timer >= SCOUTING_TIME:
            _complete_scouting()
        map_renderer.queue_redraw()

func _initialize_map():
    GameData.load_all_data()
    CityData.setup()
    map_renderer.build_icon_index()
    map_renderer.load_icons()

    var generator = load("res://scripts/map_generator.gd").new()
    var terrain_counts = {
        "plain": 4,
        "hill": 3,
        "forest": 3,
        "mountain": 2
    }
    tile_data = generator.generate_map(REGION_ROWS, REGION_COLS, CITY_ROW, CITY_COL, GameData.raw_resources, terrain_counts)
    print("Регион сгенерирован. Гексов: ", REGION_ROWS * REGION_COLS)

    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var tile = tile_data[row][col]
            tile["in_influence"] = (row >= INFLUENCE_START_ROW and row <= INFLUENCE_END_ROW and col >= INFLUENCE_START_COL and col <= INFLUENCE_END_COL)
            tile["is_explored"] = false

    _ensure_minimum_resource("animals")
    _ensure_food_plant()
    _ensure_minimum_resource("minerals")
    generator._place_wild_food(tile_data, REGION_ROWS, REGION_COLS, CITY_ROW, CITY_COL)

    var influence_resource_types = {}
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            var res = tile_data[row][col]["resource"]
            if res != null:
                influence_resource_types[res] = true

    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            if not tile_data[row][col]["in_influence"]:
                var res = tile_data[row][col]["resource"]
                if res != null and influence_resource_types.has(res):
                    tile_data[row][col]["resource"] = null

    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var tile = tile_data[row][col]
            var terrain_id = tile.terrain
            if GameData.terrains.has(terrain_id):
                var t = GameData.terrains[terrain_id]
                if t.has("icons"):
                    var icons_array = t.icons
                    if icons_array.size() > 0:
                        seed(row * 1000 + col)
                        var idx = randi() % icons_array.size()
                        tile["terrain_icon"] = icons_array[idx]
                elif t.has("icon"):
                    tile["terrain_icon"] = t.icon
                else:
                    tile["terrain_icon"] = ""

func _ensure_minimum_resource(category: String):
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            var res = tile_data[row][col]["resource"]
            if res != null and GameData.raw_resources[res].get("category", "") == category:
                return
    var possible = []
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            if tile_data[row][col]["resource"] != null:
                continue
            var terrain_id = tile_data[row][col]["terrain"]
            for res_id in GameData.raw_resources:
                if GameData.raw_resources[res_id].get("category", "") != category:
                    continue
                if terrain_id in GameData.raw_resources[res_id].get("allowed_terrains", []):
                    possible.append({"row": row, "col": col, "id": res_id})
                    break
    if possible.size() > 0:
        var chosen = possible[randi() % possible.size()]
        tile_data[chosen.row][chosen.col]["resource"] = chosen.id

func _ensure_food_plant():
    # Проверяем, есть ли в Кольце Влияния хоть один ресурс из food_plants
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            var res = tile_data[row][col]["resource"]
            if res != null:
                var res_data = GameData.raw_resources.get(res, {})
                if res_data.get("group") == "food_plants":
                    return # уже есть
    # Если нет — добавляем принудительно
    var possible = []
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            if tile_data[row][col]["resource"] != null:
                continue
            var terrain = tile_data[row][col]["terrain"]
            for res_id in GameData.raw_resources:
                var res = GameData.raw_resources[res_id]
                if res.get("group") == "food_plants" and terrain in res.get("allowed_terrains", []):
                    possible.append({"row": row, "col": col, "id": res_id})
    if possible.size() > 0:
        var chosen = possible[randi() % possible.size()]
        tile_data[chosen.row][chosen.col]["resource"] = chosen.id

func _calc_offsets():
    var min_x = INF
    var max_x = - INF
    var min_y = INF
    var max_y = - INF
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            var center = HexUtils.hex_center(row, col, HEX_RADIUS)
            min_x = min(min_x, center.x - HEX_RADIUS)
            max_x = max(max_x, center.x + HEX_RADIUS)
            min_y = min(min_y, center.y - HEX_RADIUS)
            max_y = max(max_y, center.y + HEX_RADIUS)
    var grid_width = max_x - min_x
    var grid_height = max_y - min_y
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size
    offset_x = (viewport_size.x - grid_width) / 2.0 - min_x
    offset_y = (viewport_size.y - grid_height) / 2.0 - min_y

func update_tooltip_text(row: int, col: int):
    # Эта функция остаётся здесь, потому что она используется из InputHandler
    for child in tooltip_products_container.get_children():
        child.queue_free()

    var tile = tile_data[row][col]
    var terrain_name = GameData.terrains.get(tile.terrain, {}).get("name", tile.terrain)

    # Ресурсы вне Кольца Влияния скрыты, пока область не разведана.
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)

    var res_id = tile.resource
    var res_name = "нет"
    if res_id != null:
        res_name = GameData.raw_resources.get(res_id, {}).get("name", res_id)

    # Регион ещё не разведан — не раскрываем информацию о ресурсе.
    # Показываем «неизвестно» на ВСЕХ неразведанных гексах, чтобы игрок
    # не мог заранее определить, где находятся скрытые ресурсы.
    if not is_revealed:
        tooltip_text_label.text = "Местность: %s\nРесурс: неизвестно (проведите разведку)" % terrain_name
        return

    var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", "нет") if tile.improvement != null else "нет"
    var locked = ""
    if res_id != null:
        var res_data = GameData.raw_resources.get(res_id, {})
        if res_data.has("tech_required") and not CityData.is_tech_unlocked(res_data["tech_required"]):
            locked = " (заблокировано)"

    var text = "Местность: %s\nРесурс: %s%s" % [terrain_name, res_name, locked]

    var imp_status = ""
    if tile.improvement != null:
        var has_worker = worker_manager.has_worker(row, col)
        if not has_worker:
            imp_status = " (неактивно: нет рабочего)"
        else:
            imp_status = " (работает)"
            if res_id != null:
                var res_data = GameData.raw_resources.get(res_id, {})
                if res_data.has("produces"):
                    _add_production_info(res_id, "  Производит:")
    else:
        if res_id != null:
            var res_data = GameData.raw_resources.get(res_id, {})
            if res_data.has("improved_by") and res_data.has("produces"):
                var improvement_id = res_data["improved_by"]
                var imp_data = GameData.improvements.get(improvement_id, {})
                var imp_name_display = imp_data.get("name", improvement_id)
                _add_production_info(res_id, "  При постройке %s будет давать:" % imp_name_display)
        imp_status = " (не построено)"

    if res_id != null:
        var res_data = GameData.raw_resources.get(res_id, {})
        var feed_consumption = res_data.get("feed_consumption", 0)
        if feed_consumption > 0:
            text += "\nПотребляет корма: %d за цикл" % feed_consumption
        var time_to_mature = res_data.get("time_to_mature", 0)
        if time_to_mature > 0:
            text += "\nВремя заполнения: %.0f сек" % time_to_mature

    text += "\nУлучшение: %s%s" % [imp_name, imp_status]
    tooltip_text_label.text = text

func _add_production_info(res_id: String, prefix: String):
    if res_id == null or res_id == "":
        return
    var res_data = GameData.raw_resources.get(res_id, {})
    if not res_data.has("produces"):
        return

    # Фильтруем продукты: оставляем только те, которые доступны (по технологии)
    var available_products = {}
    for prod_id in res_data["produces"]:
        if CityData.is_product_available(prod_id):
            available_products[prod_id] = res_data["produces"][prod_id]

    if available_products.is_empty():
        return

    var label = Label.new()
    label.text = prefix
    label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    tooltip_products_container.add_child(label)

    for prod_id in available_products:
        var amount = available_products[prod_id]
        var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
        var icon_path = ""
        var prod_data = GameData.products.get(prod_id, {})
        if prod_data.has("icon"):
            var icon_name = prod_data["icon"]
            icon_path = map_renderer.get_icon_path(icon_name)

        var hbox = HBoxContainer.new()
        if icon_path != "":
            var tex_rect = TextureRect.new()
            tex_rect.texture = load(icon_path)
            tex_rect.custom_minimum_size = Vector2(20, 20)
            tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
            hbox.add_child(tex_rect)
        var label_item = Label.new()
        label_item.text = "%s: %d" % [prod_name, amount]
        label_item.add_theme_color_override("font_color", Color.WHITE)
        hbox.add_child(label_item)
        tooltip_products_container.add_child(hbox)

func _show_context_menu(row: int, col: int, click_pos: Vector2):
    var tile = tile_data[row][col]
    
    # --- Сбор дикоросов ---
    if tile.resource == "wild_food":
        popup_menu.clear()
        popup_menu.add_item("Собрать дикоросы (%.0f сек)" % FORAGING_TIME)
        popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "forage_food", "row": row, "col": col})
        popup_menu.position = click_pos
        popup_menu.popup()
        return
    
    # --- Разведка Региона ---
    if not tile.get("in_influence", false):
        var chunk = expansion_manager.get_chunk_hexes(row, col)
        var unexplored_count = 0
        var all_explored = true
        for hex in chunk:
            if not tile_data[hex.row][hex.col].get("is_explored", false):
                all_explored = false
                unexplored_count += 1
        if not all_explored:
            if is_scouting:
                hud.show_message("Разведка уже идёт!")
                return
            popup_menu.clear()
            # Стоимость зависит от количества фактически исследуемых гексов: 3 еды за гекс
            var cost = unexplored_count * 3
            popup_menu.add_item("Отправить разведку (%d еды, %.0f сек)" % [cost, SCOUTING_TIME])
            popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "scout_chunk", "chunk": chunk, "cost": cost})
            popup_menu.position = click_pos
            popup_menu.popup()
            return
    
    if tile.improvement != null:
        _context_hex = {"row": row, "col": col, "resource": tile.resource}
        popup_menu.clear()

        var has_worker = worker_manager.has_worker(row, col)
        var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", "Улучшение")

        if has_worker:
            popup_menu.add_item("Приостановить работу (%s)" % imp_name)
            popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "pause_improvement", "row": row, "col": col})
        else:
            popup_menu.add_item("Запустить работу (%s)" % imp_name)
            popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "resume_improvement", "row": row, "col": col})

        popup_menu.position = click_pos
        popup_menu.popup()
        return

    var available_food = 0
    if CityData:
        for pid in CityData.city_food_pool:
            if CityData.city_food_pool[pid]:
                available_food += CityData.city_storage.get(pid, 0)

    _context_hex = {"row": row, "col": col, "resource": tile.resource}
    popup_menu.clear()

    if tile.resource != null:
        var raw = GameData.raw_resources.get(tile.resource, {})
        if "improved_by" in raw:
            if map_renderer.is_resource_locked(tile.resource):
                var tech_id = raw["tech_required"]
                var tech_name = tech_id
                var tech_cost = 0
                for tech in GameData.technologies:
                    if tech["id"] == tech_id:
                        tech_name = tech["name"]
                        tech_cost = tech.get("cost_food", 0)
                        break
                var label = "Изучить %s [еды: %d/%d]" % [tech_name, available_food, tech_cost]
                popup_menu.add_item(label)
                var last_idx = popup_menu.item_count - 1
                popup_menu.set_item_metadata(last_idx, {"action": "research_tech", "tech_id": tech_id})
            else:
                var imp_id = raw.improved_by
                var imp_data = GameData.improvements.get(imp_id, {})
                var imp_name = imp_data.get("name", imp_id)
                var cost = imp_data.get("cost_food", 0)
                var time = imp_data.get("build_time", 0)
                var label = "Построить %s (%s) [еды: %d/%d, %d сек.]" % [imp_name, raw.get("name", tile.resource), available_food, cost, int(time)]
                popup_menu.add_item(label)
                var last_idx = popup_menu.item_count - 1
                popup_menu.set_item_metadata(last_idx, {"action": "build_improvement", "imp_id": imp_id, "animal_id": tile.resource})

    if tile.resource == null and CityData:
        if CityData.domesticated_animals.size() > 0:
            for animal_id in CityData.domesticated_animals:
                var animal_data = GameData.raw_resources.get(animal_id, {})
                if tile.terrain in animal_data.get("allowed_terrains", []):
                    var animal_name = animal_data.get("name", animal_id)
                    var imp_data = GameData.improvements.get("pasture", {})
                    var cost = imp_data.get("cost_food", 0)
                    var time = imp_data.get("build_time", 0)
                    var label = "Построить пастбище (%s) [еды: %d/%d, %d сек.]" % [animal_name, available_food, cost, int(time)]
                    popup_menu.add_item(label)
                    var last_idx = popup_menu.item_count - 1
                    popup_menu.set_item_metadata(last_idx, {"action": "build_pasture", "animal_id": animal_id})
        if CityData.domesticated_plants.size() > 0:
            for plant_id in CityData.domesticated_plants:
                var plant_data = GameData.raw_resources.get(plant_id, {})
                if tile.terrain in plant_data.get("allowed_terrains", []):
                    var plant_name = plant_data.get("name", plant_id)
                    var imp_data = GameData.improvements.get("farm", {})
                    var cost = imp_data.get("cost_food", 0)
                    var time = imp_data.get("build_time", 0)
                    var label = "Построить ферму (%s) [еды: %d/%d, %d сек.]" % [plant_name, available_food, cost, int(time)]
                    popup_menu.add_item(label)
                    var last_idx = popup_menu.item_count - 1
                    popup_menu.set_item_metadata(last_idx, {"action": "build_farm", "plant_id": plant_id})

    if popup_menu.item_count > 0:
        popup_menu.position = click_pos
        popup_menu.popup()

func _on_popup_menu_id_pressed(id: int):
    var meta = popup_menu.get_item_metadata(id)
    var action = meta.get("action", "")

    if action == "expand_territory":
        var chunk = meta.get("chunk", [])
        if chunk.is_empty():
            return
        var success = expansion_manager.handle_action(chunk, meta["cost"])
        if success:
            map_renderer.queue_redraw()
            if city_ui.visible:
                city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)
        return

    if action == "pause_improvement":
        var r = meta["row"]
        var c = meta["col"]
        worker_manager.remove_worker(r, c)
        map_renderer.queue_redraw()
        return

    if action == "resume_improvement":
        var r = meta["row"]
        var c = meta["col"]
        if not worker_manager.assign_worker(r, c):
            hud.show_message("Нет свободных рабочих!")
        map_renderer.queue_redraw()
        return
        
    if action == "forage_food":
        var r = meta["row"]
        var c = meta["col"]
        _start_foraging(r, c)
        return

    if action == "scout_chunk":
        var chunk = meta["chunk"]
        var cost = meta["cost"]
        _start_scouting(chunk, cost)
        return
    
    if _context_hex == null:
        return
    var row = _context_hex.row
    var col = _context_hex.col

    if action == "build_improvement":
        var imp_id = meta.imp_id
        var animal_id = meta.get("animal_id", null)
        build_manager.start_build(row, col, imp_id, animal_id)
    elif action == "build_pasture":
        var animal_id = meta.animal_id
        build_manager.start_build(row, col, "pasture", animal_id)
    elif action == "build_farm":
        var plant_id = meta.plant_id
        build_manager.start_build(row, col, "farm", plant_id)
    elif action == "research_tech":
        var tech_id = meta.tech_id
        CityData.start_research(tech_id)

    _context_hex = null
    map_renderer.queue_redraw()

func _on_build_completed(row: int, col: int, imp_id: String, animal_id = null):
    var tile = tile_data[row][col]
    tile.improvement = imp_id
    if animal_id != null:
        tile.resource = animal_id
        if CityData:
            if GameData.raw_resources.has(animal_id) and GameData.raw_resources[animal_id].get("category") == "animals":
                CityData.add_animal(animal_id)
            elif GameData.raw_resources.has(animal_id) and GameData.raw_resources[animal_id].get("category") == "plants":
                CityData.add_plant(animal_id)
    build_manager.remove_build(row, col)
    road_manager.build_road_from(row, col, tile_data, REGION_ROWS, REGION_COLS)
    if not worker_manager.assign_worker(row, col):
        pass
    map_renderer.queue_redraw()

func pixel_to_hex(mx: float, my: float):
    # Эта функция используется InputHandler, поэтому оставляем её публичной
    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var center = HexUtils.hex_center(row, col, HEX_RADIUS)
            center.x += offset_x + scroll_offset.x
            center.y += offset_y + scroll_offset.y
            var verts = HexUtils.hex_vertices(center.x, center.y, HEX_RADIUS)
            if HexUtils.point_in_polygon(mx, my, verts):
                return {"row": row, "col": col}
    return null

func open_city():
    city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)
    city_ui.show()
    city_ui.show_resources_tab()
    hud.hide()

func _on_city_button_pressed():
    if pause_menu.visible:
        return
    city_button.disabled = false
    open_city()

func _on_city_ui_close():
    city_ui.hide()
    hud.show()

func _on_city_data_updated():
    if city_ui.visible:
        city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)

func _on_research_error(message: String):
    if city_ui.visible:
        city_ui.set_message(message)
    else:
        hud.show_message(message)

func _on_research_completed(_tech_id: String):
    if city_ui.visible:
        city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)
    map_renderer.queue_redraw()

func _on_pause_save():
    SaveManager.save_game()
    hud.show_message("Игра сохранена.")

func _on_pause_load():
    if SaveManager.load_game():
        get_tree().reload_current_scene()
    else:
        print("Ошибка загрузки сохранения")

func _on_pause_new_game():
    SaveManager.new_game()
    get_tree().change_scene_to_file("res://scenes/MainMap.tscn")

func get_tile_data(row: int, col: int):
    if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
        return tile_data[row][col]
    return null

func _on_city_button_gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        scroll_offset = - (HexUtils.hex_center(CITY_ROW, CITY_COL, HEX_RADIUS) + Vector2(offset_x, offset_y) - get_viewport_rect().size / 2.0)
        map_renderer.queue_redraw()

func _on_expansion_button_pressed():
    var active = expansion_manager.toggle()
    if active:
        hud.show_message("Режим освоения включён. ПКМ по выделенной области для освоения.")
    else:
        hud.show_message("Режим освоения выключен.")

func _on_expansion_mode_changed(_active: bool):
    map_renderer.queue_redraw()

func _on_territory_expanded(_row: int, _col: int, cost: int):
    hud.show_message("Территория расширена! (%d еды)" % cost)
    map_renderer.queue_redraw()
    if city_ui.visible:
        city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)

func is_expansion_mode_active() -> bool:
    return expansion_manager.is_active()

func is_valid_hex(row: int, col: int) -> bool:
    return row >= 0 and row < REGION_ROWS and col >= 0 and col < REGION_COLS

func _on_chunk_hovered(_chunk: Array):
    map_renderer.queue_redraw()

func _load_settings():
    var err = settings_config.load("user://settings.cfg")
    if err == OK:
        show_hex_borders = settings_config.get_value("interface", "show_hex_borders", true)
        use_edge_scrolling = settings_config.get_value("interface", "edge_scrolling", true)
    else:
        show_hex_borders = true
        use_edge_scrolling = true

func apply_settings():
    _load_settings()
    map_renderer.queue_redraw()

func _on_population_changed(new_pop: int):
    _update_population_hud()
    if city_ui.visible:
        city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)

func _update_population_hud():
    var pop_label = hud.get_node_or_null("VBoxContainer/PopulationLabel")
    if pop_label:
        pop_label.text = "Население: %d" % CityData.total_population

func _on_assignment_changed():
    map_renderer.queue_redraw()
    city_ui.update_food_label()

func _on_townsfolk_assignment_changed():
    if city_ui.visible:
        city_ui.update_data(
            CityData.city_storage,
            CityData.production_rates,
            CityData.consumption_rates,
            CityData.city_food_pool,
            GameData.buildings,
            GameData.crafts,
            CityData.city_built_buildings,
            GameData.products,
            GameData.categories
        )
        city_ui.refresh_buildings_tab()
        city_ui.update_food_label()

func _start_foraging(row: int, col: int):
    if is_foraging:
        hud.show_message("Уже идёт сбор!")
        return
    foraging_hex = {"row": row, "col": col}
    foraging_timer = 0.0
    is_foraging = true
    hud.show_message("Сбор дикоросов начался...")

func _complete_foraging():
    var row = foraging_hex.row
    var col = foraging_hex.col
    var yield_amount = randi_range(5, 10)
    CityData.city_storage["foraged_food"] = CityData.city_storage.get("foraged_food", 0) + yield_amount
    tile_data[row][col]["resource"] = null
    is_foraging = false
    foraging_hex = {}
    hud.show_message("Собрано %d еды!" % yield_amount)
    map_renderer.queue_redraw()

func _start_scouting(chunk: Array, cost: int):
    if is_scouting:
        hud.show_message("Разведка уже идёт!")
        return
    var available_food = 0
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid]:
            available_food += CityData.city_storage.get(pid, 0)
    if available_food < cost:
        hud.show_message("Недостаточно еды! Нужно %d" % cost)
        return
    # Списываем еду
    var remaining = cost
    var active_food = []
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid] and CityData.city_storage.get(pid, 0) > 0:
            active_food.append(pid)
    while remaining > 0 and active_food.size() > 0:
        var pid = active_food[randi() % active_food.size()]
        CityData.city_storage[pid] -= 1
        remaining -= 1
        if CityData.city_storage[pid] <= 0:
            active_food.erase(pid)
    scouting_chunk = chunk
    scouting_timer = 0.0
    is_scouting = true
    hud.show_message("Разведка отправлена...")

func _complete_scouting():
    for hex in scouting_chunk:
        tile_data[hex.row][hex.col]["is_explored"] = true
    var info = _get_chunk_info(scouting_chunk)
    hud.show_message("Разведка завершена! %s" % info)
    is_scouting = false
    scouting_chunk = []
    map_renderer.queue_redraw()

func _get_chunk_info(chunk: Array) -> String:
    var terrain_types = {}
    var resources = []
    for hex in chunk:
        var tile = tile_data[hex.row][hex.col]
        var terrain = tile.get("terrain", "plain")
        terrain_types[terrain] = terrain_types.get(terrain, 0) + 1
        if tile.resource != null:
            var res_name = GameData.raw_resources.get(tile.resource, {}).get("name", tile.resource)
            resources.append(res_name)
    var terrain_str = ", ".join(terrain_types.keys())
    var resource_str = ", ".join(resources) if resources.size() > 0 else "нет"
    return "Ландшафт: %s. Ресурсы: %s" % [terrain_str, resource_str]
