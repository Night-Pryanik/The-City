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
const SCOUTING_TIME_PER_HEX: float = 3.0
# Спец-действия (вырубка леса, сбор дикоросов, снос улучшений и т.п.)
# загружаются из data/special_actions.json и реализуются через систему
# труда build_manager, но не являются улучшениями.

var tile_data = []
var offset_x: float = 0.0
var offset_y: float = 0.0
var scroll_offset = Vector2.ZERO

var _context_hex = null
var last_city_click_time = 0.0
var production_timer = 0.0
var scouting_timer: float = 0.0
var scouting_chunk: Array = []
var is_scouting: bool = false

var settings_config = ConfigFile.new()
var show_hex_borders = true
var use_edge_scrolling = true
var tooltip_delay: float = 0.5
var extended_tooltip_delay: float = 1.0

@onready var popup_menu = $PopupMenu
@onready var city_ui = $CityUI
@onready var hex_tooltip = $HexTooltip
@onready var tooltip_panel = $HexTooltip
@onready var tooltip_text_label = $HexTooltip/TooltipVBox/TooltipTextLabel
@onready var tooltip_products_container = $HexTooltip/TooltipVBox/TooltipProductsContainer
@onready var hud = $HUD
@onready var city_button = $HUD/VBoxContainer/CityButton
@onready var expansion_button = $HUD/VBoxContainer/ExpansionButton
@onready var menu_button = $TopRightLayer/TopRightPanel/MenuButton
@onready var pause_menu = $PauseMenu
@onready var build_manager = $BuildManager
@onready var map_renderer = $MapRenderer
@onready var road_manager = $RoadManager
@onready var expansion_manager = $ExpansionManager
@onready var river_manager = $RiverManager
@onready var worker_manager = $WorkerManager
@onready var townsfolk_manager = $TownsfolkManager
@onready var settings_menu = preload("res://scenes/settings_menu.tscn").instantiate()
@onready var input_handler = $InputHandler
@onready var debug_manager = $DebugManager

var tech_popup: Control
var research_hbox: HBoxContainer
var research_button: Button
var research_icon: TextureRect # дочерний TextureRect внутри research_button
var research_label: Label # дочерний Label внутри research_button
var research_progress_bar: ProgressBar
var _last_research_hud_tech: String = ""

func _make_tech_popup() -> Control:
    var popup_script = load("res://scripts/tech_popup.gd")
    var popup = Control.new()
    popup.set_script(popup_script)
    return popup

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
                var tile = {"terrain": "plain", "cover": "none", "resource": null, "improvement": null, "terrain_icon": "", "in_influence": false, "river_edges": []}
                if row < saved_tiles.size() and col < saved_tiles[row].size():
                    var saved = saved_tiles[row][col]
                    if not saved.is_empty():
                        # Миграция старых сейвов: раньше лес был отдельным типом
                        # местности, теперь это покров (cover) поверх terrain.
                        var saved_terrain = saved.get("terrain", "plain")
                        var saved_cover = saved.get("cover", "none")
                        if saved_terrain == "forest":
                            saved_terrain = "plain"
                            saved_cover = "forest"
                        tile["terrain"] = saved_terrain
                        tile["cover"] = saved_cover
                        tile["resource"] = saved.get("resource")
                        tile["improvement"] = saved.get("improvement")
                        tile["quality"] = saved.get("quality", "")
                        tile["terrain_icon"] = saved.get("terrain_icon", "")
                        tile["in_influence"] = saved.get("in_influence", false)
                        tile["is_explored"] = saved.get("is_explored", false)
                        tile["river_edges"] = saved.get("river_edges", [])
                col_array.append(tile)
            tile_data.append(col_array)

        # Восстанавливаем стройки улучшений и зданий
        build_manager.restore_builds(SaveManager.saved_data.get("active_builds", {}))
        build_manager.restore_building_builds(SaveManager.saved_data.get("active_building_builds", {}))

        # Восстанавливаем назначения рабочих и горожан
        worker_manager.load_assignments(SaveManager.saved_data.get("worker_assignments", []))
        townsfolk_manager.load_assignments(SaveManager.saved_data.get("townsfolk_assignments", []))

        # Для уже изученных технологий гарантируем спавн открытых ими ресурсов
        CityData.ensure_tech_resources_spawned()

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

        # Восстанавливаем реки из сохранения и помечаем river_edges в гексах
        river_manager.load_rivers(SaveManager.saved_data.get("rivers", []))
        river_manager.mark_river_edges(tile_data, REGION_ROWS, REGION_COLS, HEX_RADIUS)

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
    input_handler.set_tooltip_delay(tooltip_delay)
    input_handler.set_extended_tooltip_delay(extended_tooltip_delay)

    # Инициализация DebugManager
    debug_manager.initialize(self)

    _calc_offsets()
    map_renderer.queue_redraw()

    _update_population_hud()

    popup_menu.id_pressed.connect(_on_popup_menu_id_pressed)
    city_ui.closed.connect(_on_city_ui_close)
    city_button.pressed.connect(_on_city_button_pressed)
    expansion_button.pressed.connect(_on_expansion_button_pressed)
    city_ui.build_requested.connect(CityData.request_build)
    CityData.research_error.connect(_on_research_error)
    CityData.research_error.connect(hud.show_message)
    CityData.population_changed.connect(_on_population_changed)
    city_ui.research_requested.connect(CityData.start_research)
    CityData.research_completed.connect(_on_research_completed)
    expansion_manager.chunk_hovered.connect(_on_chunk_hovered)
    worker_manager.assignment_changed.connect(_on_assignment_changed)
    townsfolk_manager.assignment_changed.connect(_on_townsfolk_assignment_changed)

    tech_popup = _make_tech_popup()
    add_child(tech_popup)
    tech_popup.hide()
    if tech_popup.has_signal("go_to_technologies"):
        tech_popup.go_to_technologies.connect(_on_tech_popup_go_to_techs)

    if pause_menu:
        if not pause_menu.save_pressed.is_connected(_on_pause_save):
            pause_menu.save_pressed.connect(_on_pause_save)
        if not pause_menu.load_pressed.is_connected(_on_pause_load):
            pause_menu.load_pressed.connect(_on_pause_load)
        if not pause_menu.new_game_pressed.is_connected(_on_pause_new_game):
            pause_menu.new_game_pressed.connect(_on_pause_new_game)
        if not pause_menu.visibility_changed.is_connected(_on_pause_menu_visibility_changed):
            pause_menu.visibility_changed.connect(_on_pause_menu_visibility_changed)

    build_manager.build_message.connect(hud.show_message)
    build_manager.build_completed.connect(_on_build_completed)
    build_manager.build_building_completed.connect(_on_building_build_completed)
    city_button.gui_input.connect(_on_city_button_gui_input)

    # Сигналы от ExpansionManager
    expansion_manager.expansion_mode_changed.connect(_on_expansion_mode_changed)
    expansion_manager.territory_expanded.connect(_on_territory_expanded)

    menu_button.pressed.connect(_on_menu_button_pressed)

    _setup_research_hud()

func _input(event):
    # Дебаг-меню: открытие/закрытие по F9
    if event is InputEventKey and event.pressed and event.keycode == KEY_F9:
        debug_manager.toggle()
        get_viewport().set_input_as_handled()
        return

    # ESC закрывает дебаг-меню, если оно открыто
    if debug_manager.is_open:
        if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
            debug_manager.close()
            get_viewport().set_input_as_handled()
            return
        input_handler.handle_input(event)
        return

    input_handler.handle_input(event)

func _process(delta):
    if Engine.is_editor_hint():
        return

    # Блокируем кнопки HUD, если игра на паузе.
    var is_paused = get_tree().paused
    if research_button:
        research_button.disabled = is_paused
    if city_button:
        city_button.disabled = is_paused
    if expansion_button:
        expansion_button.disabled = is_paused

    # Наука копится каждый кадр, а не привязана к production-тику.
    # Без этого прогресс-бар исследования прыгал скачками раз в 2 секунды.
    if not is_paused:
        CityData.tick_research_science_continuous(delta)

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
                var production_multiplier = 1.0
                if tile.improvement != null:
                    production_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, _is_hex_irrigated(row, col))

                # Качество ресурса на гексе передаётся в производство.
                var tile_quality = tile.get("quality", "common")
                if feed_needed > 0:
                    var available_feed = CityData.city_storage.get("feed", 0)
                    if available_feed >= feed_needed:
                        CityData.remove_from_storage("feed", feed_needed, "best")
                        CityData.add_raw_production(tile.resource, production_multiplier, tile_quality)
                    else:
                        CityData.add_raw_production(tile.resource, 0.25, tile_quality)
                else:
                    CityData.add_raw_production(tile.resource, production_multiplier, tile_quality)

        CityData.do_tick()
        # tick_research_science вызывается каждый кадр ниже (см. _process),
        # а не привязан к production-тику. Это даёт плавный progress-bar.

    _update_research_progress()
    if CityData.current_research_tech_id != "" or build_manager.active_builds.size() > 0:
        map_renderer.queue_redraw()

    input_handler.handle_process(delta)

    if is_scouting:
        scouting_timer += delta
        if scouting_timer >= _get_scouting_time(scouting_chunk.size()):
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
        "mountain": 2
    }
    tile_data = generator.generate_map(REGION_ROWS, REGION_COLS, CITY_ROW, CITY_COL, GameData.raw_resources, terrain_counts)
    print("Регион сгенерирован. Гексов: ", REGION_ROWS * REGION_COLS)

    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var tile = tile_data[row][col]
            tile["in_influence"] = (row >= INFLUENCE_START_ROW and row <= INFLUENCE_END_ROW and col >= INFLUENCE_START_COL and col <= INFLUENCE_END_COL)
            tile["is_explored"] = false

    _ensure_food_plant()
    generator.place_wild_food(tile_data, REGION_ROWS, REGION_COLS, CITY_ROW, CITY_COL)

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

    # --- Пост-обработка: гарантируем достаточное количество СВОБОДНЫХ гексов ---
    # После размещения всех ресурсов у каждого типа местности в Кольце Влияния
    # должно остаться минимум FREE_TERRAIN_HEXES свободных (resource == null)
    # гексов. Это исключает софт-лок: если ресурс (например, киноа — только горы)
    # попал в кольцо, у игрока всегда будет место для дополнительных ферм/пастбищ.
    # Метод конвертирует ТОЛЬКО свободные гексы и НИКОГДА не уничтожает ресурсы.
    generator.ensure_free_terrain_hexes(tile_data, terrain_counts,
            INFLUENCE_START_ROW, INFLUENCE_END_ROW, INFLUENCE_START_COL, INFLUENCE_END_COL)

    # Используем ЛОКАЛЬНЫЙ генератор случайных чисел для выбора иконки ландшафта.
    # Ни в коем случае нельзя вызывать seed()/randomize() на глобальном RNG внутри
    # этого цикла — это разрушило бы случайность всех последующих randf()/randi()
    # (например, при спавне ресурсов после изучения технологий).
    var icon_rng = RandomNumberGenerator.new()
    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var tile = tile_data[row][col]
            var terrain_id = tile.terrain
            if GameData.terrains.has(terrain_id):
                var t = GameData.terrains[terrain_id]
                if t.has("icons"):
                    var icons_array = t.icons
                    if icons_array.size() > 0:
                        icon_rng.seed = row * 1000 + col
                        var idx = icon_rng.randi() % icons_array.size()
                        tile["terrain_icon"] = icons_array[idx]
                elif t.has("icon"):
                    tile["terrain_icon"] = t.icon
                else:
                    tile["terrain_icon"] = ""

    # Генерируем реки (визуальные) и помечаем рёбра реки в данных гексов
    river_manager.generate_rivers(REGION_ROWS, REGION_COLS, HEX_RADIUS)
    river_manager.mark_river_edges(tile_data, REGION_ROWS, REGION_COLS, HEX_RADIUS)

func _is_hex_adjacent_to_canal(row: int, col: int) -> bool:
    if row < 0 or row >= REGION_ROWS or col < 0 or col >= REGION_COLS:
        return false
    var neighbors = HexUtils.get_neighbors_odd_r(row, col, REGION_ROWS, REGION_COLS)
    for n in neighbors:
        var tile = tile_data[n.row][n.col]
        if tile == null:
            continue
        var imp_id = tile.improvement
        if imp_id == "canal":
            return true
        var imp_data = GameData.improvements.get(imp_id, {})
        if imp_data.get("is_canal", false):
            return true
    return false

func _is_hex_irrigated(row: int, col: int) -> bool:
    if row < 0 or row >= REGION_ROWS or col < 0 or col >= REGION_COLS:
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false

    if tile.get("river_edges", []).size() > 0:
        return true
    if _is_hex_adjacent_to_canal(row, col):
        return true
    if tile.improvement != "farm":
        return false

    var visited := {}
    var queue = [ {"row": row, "col": col, "dist": 0}]
    visited["%d_%d" % [row, col]] = true

    while queue.size() > 0:
        var item = queue.pop_front()
        var crow = item.row
        var ccol = item.col
        var dist = item.dist
        var current_tile = tile_data[crow][ccol]
        if current_tile == null:
            continue

        if current_tile.get("river_edges", []).size() > 0:
            return true
        if _is_hex_adjacent_to_canal(crow, ccol):
            return true
        if dist >= 3:
            continue

        var neighbors = HexUtils.get_neighbors_odd_r(crow, ccol, REGION_ROWS, REGION_COLS)
        for n in neighbors:
            var key = "%d_%d" % [n.row, n.col]
            if visited.has(key):
                continue
            var neighbor_tile = tile_data[n.row][n.col]
            if neighbor_tile == null:
                continue
            if neighbor_tile.improvement == "farm":
                visited[key] = true
                queue.append({"row": n.row, "col": n.col, "dist": dist + 1})
    return false

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
            var cover_id = tile_data[row][col].get("cover", "none")
            for res_id in GameData.raw_resources:
                if GameData.raw_resources[res_id].get("category", "") != category:
                    continue
                # Ресурсы, требующие технологию, не размещаются при генерации
                # (они спавнятся после изучения технологии).
                var rdata = GameData.raw_resources[res_id]
                if terrain_id in rdata.get("allowed_terrain", []) and cover_id in rdata.get("allowed_cover", []):
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
            var cover = tile_data[row][col].get("cover", "none")
            for res_id in GameData.raw_resources:
                var res = GameData.raw_resources[res_id]
                if res.get("group") != "food_plants":
                    continue
                if not (terrain in res.get("allowed_terrain", []) and cover in res.get("allowed_cover", [])):
                    continue
                # Не берём ресурсы, требующие НЕизученную технологию:
                # они спавнятся только после её изучения.
                var tech_required = res.get("tech_required", "")
                if tech_required != "" and not CityData.is_tech_unlocked(tech_required):
                    continue
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
    var cover_id = tile.get("cover", "none")

    # Ресурсы вне Кольца Влияния скрыты, пока область не разведана.
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)

    var res_id = tile.resource
    var res_name = "нет"
    if res_id != null:
        res_name = GameData.raw_resources.get(res_id, {}).get("name", res_id)

    # Формируем строку «Местность»: если на гексе есть лес, добавляем его
    # через запятую (например, «равнина, лес»).
    var cover_name_lower = ""
    if cover_id != "none":
        cover_name_lower = "Лес".to_lower()
    var terrain_with_cover = terrain_name
    if cover_name_lower != "":
        terrain_with_cover = "%s, %s" % [terrain_name, cover_name_lower]

    # Регион ещё не разведан — не раскрываем информацию о ресурсе.
    # Показываем «неизвестно» на ВСЕХ неразведанных гексах, чтобы игрок
    # не мог заранее определить, где находятся скрытые ресурсы.
    if not is_revealed:
        var unknown_text = "Местность: %s\nРесурс: неизвестно (проведите разведку)" % terrain_with_cover
        tooltip_text_label.text = unknown_text
        return

    var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", "нет") if tile.improvement != null else "нет"

    var text = "Местность: %s\nРесурс: %s" % [terrain_with_cover, res_name]

    # Качество ресурса становится видно после постройки улучшения.
    var tile_quality = tile.get("quality", "")
    if tile_quality != "" and tile.improvement != null:
        var q_stars = GameData.get_quality_stars(tile_quality)
        var q_name = GameData.get_quality_name(tile_quality)
        text += "\nКачество: %s (%s)" % [q_stars, q_name]

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
                    _add_production_info(row, col, res_id, "  Производит:")
    else:
        if res_id != null:
            var res_data = GameData.raw_resources.get(res_id, {})
            if res_data.has("improved_by") and res_data.has("produces"):
                var improvement_id = res_data["improved_by"]
                var imp_data = GameData.improvements.get(improvement_id, {})
                var imp_name_display = imp_data.get("name", improvement_id)
                _add_production_info(row, col, res_id, "  При постройке %s будет давать:" % imp_name_display)
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
    if tile.improvement == "farm" and _is_hex_irrigated(row, col):
        text += "\nДоступ к пресной воде"

    # Если улучшение ещё не построено и его можно возвести на этом гексе —
    # показываем итоговую стоимость труда (финальную цифру).
    if tile.improvement == null:
        var buildable_imp = _get_buildable_improvement(row, col)
        if buildable_imp != "":
            var cost_data = get_improvement_work_cost(buildable_imp, row, col)
            text += "\nТруд на постройку: %d" % cost_data["cost"]

    tooltip_text_label.text = text

# Возвращает id улучшения, которое можно построить на гексе (row, col),
# или пустую строку, если постройка невозможна.
func _get_buildable_improvement(row: int, col: int) -> String:
    var tile = tile_data[row][col]
    if tile.improvement != null:
        return ""

    if tile.resource != null:
        var raw = GameData.raw_resources.get(tile.resource, {})
        if "improved_by" in raw and raw.improved_by != null and raw.improved_by != "":
            var imp_id = raw.improved_by
            if CityData.is_improvement_unlocked(imp_id):
                return imp_id
        return ""

    # Пустой гекс: можно построить пастбище или ферму, если есть одомашненные виды.
    var tile_cover = tile.get("cover", "none")
    if CityData.domesticated_animals.size() > 0 and CityData.is_improvement_unlocked("pasture"):
        for animal_id in CityData.domesticated_animals:
            var animal_data = GameData.raw_resources.get(animal_id, {})
            if tile.terrain in animal_data.get("allowed_terrain", []) and tile_cover in animal_data.get("allowed_cover", []):
                return "pasture"
    if CityData.domesticated_plants.size() > 0 and CityData.is_improvement_unlocked("farm"):
        for plant_id in CityData.domesticated_plants:
            var plant_data = GameData.raw_resources.get(plant_id, {})
            if tile.terrain in plant_data.get("allowed_terrain", []) and tile_cover in plant_data.get("allowed_cover", []):
                return "farm"
    return ""

func _add_production_info(row: int, col: int, res_id: String, prefix: String):
    if res_id == null or res_id == "":
        return
    var res_data = GameData.raw_resources.get(res_id, {})
    if not res_data.has("produces"):
        return

    var tile = tile_data[row][col]
    var has_worker = worker_manager.has_worker(row, col)

    # Определяем бонусы (универсальная система)
    var bonus_multiplier = 1.0
    if tile.improvement != null and has_worker:
        bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, _is_hex_irrigated(row, col))

    # Фильтруем и вычисляем продукты с бонусами
    var final_amounts = {}
    for prod_id in res_data["produces"]:
        if not CityData.is_product_available(prod_id):
            continue
        var base_amount = float(res_data["produces"][prod_id])
        var final_amount = ceili(base_amount * bonus_multiplier)
        final_amounts[prod_id] = {"base": base_amount, "final": final_amount}

    if final_amounts.is_empty():
        return

    var label = Label.new()
    label.text = prefix
    label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    tooltip_products_container.add_child(label)

    for prod_id in final_amounts:
        var amount = final_amounts[prod_id].final
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
        # Обычный тултип: показываем только итоговое округлённое значение
        label_item.text = "%s: %d" % [prod_name, amount]
        label_item.add_theme_color_override("font_color", Color.WHITE)
        hbox.add_child(label_item)
        tooltip_products_container.add_child(hbox)

func _add_extended_production_info(row: int, col: int):
    var tile = tile_data[row][col]
    if tile.resource == null:
        return
    var res_data = GameData.raw_resources.get(tile.resource, {})
    if not res_data.has("produces"):
        return

    # Определяем активные модификаторы (универсальная система).
    # Бонусы применяются только если улучшение построено и есть рабочий.
    var modifiers = []
    var bonus_multiplier = 1.0
    if tile.improvement != null and worker_manager.has_worker(row, col):
        modifiers = CityData.get_improvement_production_modifiers(tile.improvement, _is_hex_irrigated(row, col))
        bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, _is_hex_irrigated(row, col))

    # Фильтруем продукты: оставляем только доступные
    var available_products = {}
    for prod_id in res_data["produces"]:
        if CityData.is_product_available(prod_id):
            available_products[prod_id] = res_data["produces"][prod_id]

    if available_products.is_empty():
        return

    var header_label = Label.new()
    if tile.improvement != null:
        header_label.text = "Производит:"
    else:
        var improvement_id = res_data.get("improved_by", "")
        var imp_name_display = GameData.improvements.get(improvement_id, {}).get("name", improvement_id)
        header_label.text = "При постройке %s будет давать:" % imp_name_display
    header_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    tooltip_products_container.add_child(header_label)

    var base_amount = 0.0
    var final_amount = 0
    for prod_id in available_products:
        base_amount = float(available_products[prod_id])
        final_amount = ceili(base_amount * bonus_multiplier)
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
        label_item.text = "%s: %d" % [prod_name, final_amount]
        label_item.add_theme_color_override("font_color", Color.WHITE)
        hbox.add_child(label_item)
        tooltip_products_container.add_child(hbox)

    # Ниже — список всех активных модификаторов и расчёт
    if modifiers.size() > 0:
        var base_label = Label.new()
        base_label.text = "  База: %d" % int(base_amount)
        base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        tooltip_products_container.add_child(base_label)
        for mod in modifiers:
            var mod_label = Label.new()
            mod_label.text = "  %s" % mod.get("label", "")
            mod_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
            tooltip_products_container.add_child(mod_label)
        var total_label = Label.new()
        total_label.text = "  Итого: %.1f → %d" % [base_amount * bonus_multiplier, final_amount]
        total_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        tooltip_products_container.add_child(total_label)

# Возвращает true, если для гекса нужно показывать расширенный тултип:
# есть бонусы производства ИЛИ можно построить улучшение (тогда показываем расчёт труда).
func has_extended_tooltip_info(row: int, col: int) -> bool:
    var tile = tile_data[row][col]

    # Бонусы производства (улучшение построено и работает)
    if tile.improvement != null and tile.resource != null and worker_manager.has_worker(row, col):
        var res_data = GameData.raw_resources.get(tile.resource, {})
        if res_data.has("produces"):
            var bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, _is_hex_irrigated(row, col))
            if bonus_multiplier > 1.0:
                return true

    # Можно построить улучшение — показываем расчёт труда
    if tile.improvement == null:
        if _get_buildable_improvement(row, col) != "":
            return true

    return false

func update_extended_tooltip(row: int, col: int):
    # Очищаем контейнер и показываем расширенную информацию с расчётом
    for child in tooltip_products_container.get_children():
        child.queue_free()

    var tooltip_lines = tooltip_text_label.text.split("\n")
    var filtered_lines = []
    for line in tooltip_lines:
        if not line.begins_with("Труд на постройку:"):
            filtered_lines.append(line)
    tooltip_text_label.text = "\n".join(filtered_lines)

    var tile = tile_data[row][col]
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    if not is_revealed:
        return

    # Расчёт стоимости труда для постройки улучшения (если его можно построить)
    if tile.improvement == null:
        var buildable_imp = _get_buildable_improvement(row, col)
        if buildable_imp != "":
            var cost_data = get_improvement_work_cost(buildable_imp, row, col)
            var imp_name = GameData.improvements.get(buildable_imp, {}).get("name", buildable_imp)

            var header = Label.new()
            header.text = "Строительство: %d труда (%s)" % [cost_data["cost"], imp_name]
            header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
            tooltip_products_container.add_child(header)

            var base_label = Label.new()
            base_label.text = "  База: %d труда" % cost_data["base_cost"]
            base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            tooltip_products_container.add_child(base_label)

            var terrain_label = Label.new()
            terrain_label.text = "  Местность: %s (стоимость передвижения: %d) ×%.2f" % [cost_data["terrain_name"], int(cost_data["move_cost"]), cost_data["terrain_mult"]]
            terrain_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
            tooltip_products_container.add_child(terrain_label)

            var dist_label = Label.new()
            dist_label.text = "  Расстояние до города: %d → ×%.2f" % [cost_data["distance"], cost_data["distance_mult"]]
            dist_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
            tooltip_products_container.add_child(dist_label)

            var total_label = Label.new()
            total_label.text = "  Итого: %d труда" % cost_data["cost"]
            total_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            tooltip_products_container.add_child(total_label)

    var res_id = tile.resource
    if res_id == null:
        return
    var res_data = GameData.raw_resources.get(res_id, {})
    if not res_data.has("produces"):
        return

    _add_extended_production_info(row, col)

func show_context_menu(row: int, col: int, click_pos: Vector2):
    var tile = tile_data[row][col]

    var available_food = 0

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
            available_food = 0
            if CityData:
                for pid in CityData.city_food_pool:
                    if CityData.city_food_pool[pid]:
                        available_food += CityData.city_storage.get(pid, 0)
            popup_menu.clear()
            # Стоимость зависит от количества фактически исследуемых гексов: 3 еды за гекс
            var cost = unexplored_count * 3
            popup_menu.add_item("Отправить разведчиков [еды: %d/%d, %.0f сек.]" % [available_food, cost, _get_scouting_time(unexplored_count)])
            popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "scout_chunk", "chunk": chunk, "cost": cost})
            popup_menu.position = click_pos
            popup_menu.popup()
            return
        else:
            # Чанк полностью исследован — показываем меню покупки территории
            available_food = 0
            if CityData:
                for pid in CityData.city_food_pool:
                    if CityData.city_food_pool[pid]:
                        available_food += CityData.city_storage.get(pid, 0)
            expansion_manager.show_context_menu(chunk, click_pos, available_food)
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

        # Спец-действия, применимые к гексу с улучшением (например, снос)
        _add_special_actions_to_menu(tile, row, col)

        # Если идёт строительство — добавляем опцию отмены
        if build_manager.is_building(row, col):
            popup_menu.add_item("Отменить стройку")
            popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "cancel_build", "row": row, "col": col})

        popup_menu.position = click_pos
        popup_menu.popup()
        return

    available_food = 0
    if CityData:
        for pid in CityData.city_food_pool:
            if CityData.city_food_pool[pid]:
                available_food += CityData.city_storage.get(pid, 0)

    _context_hex = {"row": row, "col": col, "resource": tile.resource}
    popup_menu.clear()

    if tile.resource != null:
        var raw = GameData.raw_resources.get(tile.resource, {})
        # У ресурсов без улучшения (например, дикоросы) improved_by отсутствует
        # или равен null — пропускаем блок, чтобы не было ошибок при проверке
        # is_improvement_unlocked.
        if "improved_by" in raw and raw.improved_by != null and raw.improved_by != "":
            var imp_id = raw.improved_by
            var imp_data = GameData.improvements.get(imp_id, {})
            var imp_name = imp_data.get("name", imp_id)
            var work_cost_calc = get_improvement_work_cost(imp_id, row, col)
            var work_cost = work_cost_calc["cost"]
            if map_renderer.is_resource_locked(tile.resource):
                var tech_id = raw["tech_required"]
                var tech_name = tech_id
                var tech_cost = 3
                for tech in GameData.technologies:
                    if tech["id"] == tech_id:
                        tech_name = tech["name"]
                        tech_cost = int(tech.get("science_cost", 3))
                        break
                var label = "Изучить %s (наука: %d)" % [tech_name, tech_cost]
                popup_menu.add_item(label)
                var last_idx = popup_menu.item_count - 1
                popup_menu.set_item_metadata(last_idx, {"action": "research_tech", "tech_id": tech_id})
            elif not CityData.is_improvement_unlocked(imp_id):
                # Ресурс открыт, но улучшение для него требует отдельной технологии
                var unlock_tech_id = CityData.get_improvement_unlock_tech(imp_id)
                var unlock_tech_name = unlock_tech_id
                var unlock_tech_cost = 3
                for tech in GameData.technologies:
                    if tech["id"] == unlock_tech_id:
                        unlock_tech_name = tech["name"]
                        unlock_tech_cost = int(tech.get("science_cost", 3))
                        break
                var label = "Изучить %s (наука: %d)" % [unlock_tech_name, unlock_tech_cost]
                popup_menu.add_item(label)
                var last_idx = popup_menu.item_count - 1
                popup_menu.set_item_metadata(last_idx, {"action": "research_tech", "tech_id": unlock_tech_id})
            else:
                # Показываем только улучшения, открытые изученными технологиями
                if CityData.is_improvement_unlocked(imp_id):
                    if build_manager.is_building(row, col):
                        var prog = build_manager.get_progress(row, col)
                        var prog_text = ""
                        if not prog.is_empty():
                            var wc = prog.get("work_cost", 0)
                            var p = prog.get("progress", 0.0)
                            if wc > 0:
                                prog_text = " [%.0f/%.0f труда]" % [p, wc]
                        var status_text = "Возобновить строительство" if build_manager.is_building_paused(row, col) else "Приостановить стройку"
                        popup_menu.add_item("%s %s%s" % [status_text, imp_name, prog_text])
                        popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "build_improvement", "imp_id": imp_id, "animal_id": tile.resource})
                    else:
                        var labor = CityData.get_total_labor()
                        var build_time = work_cost / max(1.0, labor)
                        var label = "Построить %s (%s) [%d труда, %.0f сек.]" % [imp_name, raw.get("name", tile.resource), work_cost, build_time]
                        popup_menu.add_item(label)
                        var last_idx = popup_menu.item_count - 1
                        popup_menu.set_item_metadata(last_idx, {"action": "build_improvement", "imp_id": imp_id, "animal_id": tile.resource})

    var tile_cover = tile.get("cover", "none")
    if tile.resource == null and CityData:
        if CityData.domesticated_animals.size() > 0 and CityData.is_improvement_unlocked("pasture"):
            for animal_id in CityData.domesticated_animals:
                var animal_data = GameData.raw_resources.get(animal_id, {})
                if tile.terrain in animal_data.get("allowed_terrain", []) and tile_cover in animal_data.get("allowed_cover", []):
                    var animal_name = animal_data.get("name", animal_id)
                    var imp_data = GameData.improvements.get("pasture", {})
                    var work_cost_calc = get_improvement_work_cost("pasture", row, col)
                    var work_cost = work_cost_calc["cost"]
                    if build_manager.is_building(row, col):
                        var prog = build_manager.get_progress(row, col)
                        var prog_text = ""
                        if not prog.is_empty():
                            var wc = prog.get("work_cost", 0)
                            var p = prog.get("progress", 0.0)
                            if wc > 0:
                                prog_text = " [%.0f/%.0f труда]" % [p, wc]
                        var status_text = "Возобновить строительство" if build_manager.is_building_paused(row, col) else "Приостановить стройку"
                        popup_menu.add_item("%s пастбище (%s)%s" % [status_text, animal_name, prog_text])
                        popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "build_pasture", "animal_id": animal_id})
                    else:
                        var labor = CityData.get_total_labor()
                        var build_time = work_cost / max(1.0, labor)
                        var label = "Построить пастбище (%s) [%d труда, %.0f сек.]" % [animal_name, work_cost, build_time]
                        popup_menu.add_item(label)
                        var last_idx = popup_menu.item_count - 1
                        popup_menu.set_item_metadata(last_idx, {"action": "build_pasture", "animal_id": animal_id})
        if CityData.domesticated_plants.size() > 0 and CityData.is_improvement_unlocked("farm"):
            for plant_id in CityData.domesticated_plants:
                var plant_data = GameData.raw_resources.get(plant_id, {})
                if tile.terrain in plant_data.get("allowed_terrain", []) and tile_cover in plant_data.get("allowed_cover", []):
                    var plant_name = plant_data.get("name", plant_id)
                    var imp_data = GameData.improvements.get("farm", {})
                    var work_cost_calc = get_improvement_work_cost("farm", row, col)
                    var work_cost = work_cost_calc["cost"]
                    if build_manager.is_building(row, col):
                        var prog = build_manager.get_progress(row, col)
                        var prog_text = ""
                        if not prog.is_empty():
                            var wc = prog.get("work_cost", 0)
                            var p = prog.get("progress", 0.0)
                            if wc > 0:
                                prog_text = " [%.0f/%.0f труда]" % [p, wc]
                        var status_text = "Возобновить строительство" if build_manager.is_building_paused(row, col) else "Приостановить стройку"
                        popup_menu.add_item("%s ферму (%s)%s" % [status_text, plant_name, prog_text])
                        popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "build_farm", "plant_id": plant_id})
                    else:
                        var labor = CityData.get_total_labor()
                        var build_time = work_cost / max(1.0, labor)
                        var label = "Построить ферму (%s) [%d труда, %.0f сек.]" % [plant_name, work_cost, build_time]
                        popup_menu.add_item(label)
                        var last_idx = popup_menu.item_count - 1
                        popup_menu.set_item_metadata(last_idx, {"action": "build_farm", "plant_id": plant_id})

    # --- Спец-действия (вырубка леса, сбор дикоросов и т.п.) ---
    _add_special_actions_to_menu(tile, row, col)

    if build_manager.is_building(row, col):
        popup_menu.add_item("Отменить стройку")
        popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "cancel_build", "row": row, "col": col})

    if popup_menu.item_count > 0:
        popup_menu.position = click_pos
        popup_menu.popup()

# Добавляет в контекстное меню спец-действия, применимые к гексу (row, col).
# Применимость определяется по action_type:
#   "terrain"  — гекс имеет source_terrain и на нём нет улучшения;
#   "cover"    — гекс имеет source_cover и на нём нет ресурса и улучшения;
#   "forage"   — на гексе есть ресурс target_resource;
#   "demolish" — на гексе есть улучшение.
func _add_special_actions_to_menu(tile: Dictionary, row: int, col: int):
    for sa_id in GameData.special_actions:
        var sa = GameData.special_actions[sa_id]
        var action_type = sa.get("action_type", "terrain")
        var applicable = false
        if action_type == "terrain":
            applicable = tile.terrain == sa.get("source_terrain", "") and tile.improvement == null
        elif action_type == "cover":
            # Вырубка леса применима только если есть подходящий покров (cover)
            # и на гексе нет ресурса и улучшения.
            var cover_id = tile.get("cover", "none")
            applicable = cover_id in sa.get("source_cover", []) and tile.improvement == null and tile.resource == null
        elif action_type == "forage":
            applicable = tile.resource == sa.get("target_resource", "")
        elif action_type == "demolish":
            applicable = tile.improvement != null
        if not applicable:
            continue

        var sa_name = sa.get("name", sa_id)
        var unlock_tech = sa.get("unlock_tech", "")
        if unlock_tech != "" and not CityData.is_tech_unlocked(unlock_tech):
            var tech_name = unlock_tech
            var tech_cost = 3
            for tech in GameData.technologies:
                if tech["id"] == unlock_tech:
                    tech_name = tech["name"]
                    tech_cost = int(tech.get("science_cost", 3))
                    break
            popup_menu.add_item("%s (требуется изучить %s, наука: %d)" % [sa_name, tech_name, tech_cost])
            popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "research_tech", "tech_id": unlock_tech})
        else:
            var sa_cost_calc = get_improvement_work_cost(sa_id, row, col)
            var sa_cost = sa_cost_calc["cost"]
            if build_manager.is_building(row, col):
                var prog = build_manager.get_progress(row, col)
                var prog_text = ""
                if not prog.is_empty():
                    var wc = prog.get("work_cost", 0)
                    var p = prog.get("progress", 0.0)
                    if wc > 0:
                        prog_text = " [%.0f/%.0f труда]" % [p, wc]
                var status_text = "Возобновить %s" % sa_name.to_lower() if build_manager.is_building_paused(row, col) else "Приостановить %s" % sa_name.to_lower()
                popup_menu.add_item("%s%s" % [status_text, prog_text])
                popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": sa_id, "row": row, "col": col})
            else:
                var labor = CityData.get_total_labor()
                var build_time = sa_cost / max(1.0, labor)
                var label = "%s [%d труда, %.0f сек.]" % [sa_name, sa_cost, build_time]
                popup_menu.add_item(label)
                popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": sa_id, "row": row, "col": col})

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
                city_ui.refresh()
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

    if action == "cancel_build":
        var r = meta["row"]
        var c = meta["col"]
        _confirm_cancel_build(r, c)
        return

    if action == "scout_chunk":
        var chunk = meta.get("chunk", [])
        var cost = meta.get("cost", 0)
        _start_scouting(chunk, cost)
        return

    if _context_hex == null:
        return
    var row = _context_hex.row
    var col = _context_hex.col

    if action == "build_improvement":
        var imp_id = meta.imp_id
        var animal_id = meta.get("animal_id", null)
        # Если строительство уже идёт — переключаем паузу/возобновление
        if build_manager.is_building(row, col):
            if build_manager.is_building_paused(row, col):
                build_manager.resume_build(row, col)
            else:
                build_manager.pause_build(row, col)
        else:
            build_manager.start_build(row, col, imp_id, animal_id)
    elif action == "build_pasture":
        var animal_id = meta.animal_id
        build_manager.start_build(row, col, "pasture", animal_id)
    elif action == "build_farm":
        var plant_id = meta.plant_id
        build_manager.start_build(row, col, "farm", plant_id)
    elif GameData.special_actions.has(action):
        # Спец-действие: если стройка уже идёт — переключаем паузу/возобновление,
        # иначе запускаем новую через систему труда.
        if build_manager.is_building(row, col):
            if build_manager.is_building_paused(row, col):
                build_manager.resume_build(row, col)
            else:
                build_manager.pause_build(row, col)
        else:
            build_manager.start_build(row, col, action)
    elif action == "research_tech":
        var tech_id = meta.tech_id
        CityData.start_research(tech_id)

    _context_hex = null
    map_renderer.queue_redraw()

# Выбирает иконку ландшафта для гекса (row, col) на основе его террейна.
func _assign_terrain_icon(row: int, col: int):
    var tile = tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    if GameData.terrains.has(terrain_id):
        var t = GameData.terrains[terrain_id]
        if t.has("icons"):
            var icons_array = t.icons
            if icons_array.size() > 0:
                var icon_rng = RandomNumberGenerator.new()
                icon_rng.seed = row * 1000 + col
                var idx = icon_rng.randi() % icons_array.size()
                tile["terrain_icon"] = icons_array[idx]
                return
        elif t.has("icon"):
            tile["terrain_icon"] = t.icon
            return
    tile["terrain_icon"] = ""

func _on_build_completed(row: int, col: int, imp_id: String, animal_id = null):
    var tile = tile_data[row][col]

    # Спец-действие (вырубка леса, сбор дикоросов, снос улучшений и т.п.)
    if GameData.special_actions.has(imp_id):
        var sa = GameData.special_actions[imp_id]
        var action_type = sa.get("action_type", "terrain")
        # Освобождаем рабочего, если он был назначен
        if worker_manager.has_worker(row, col):
            worker_manager.remove_worker(row, col)

        if action_type == "cover":
            # Вырубка леса: меняем только покров (cover), terrain/resource не трогаем.
            var result_cover = sa.get("result_cover", "none")
            tile.cover = result_cover
        elif action_type == "forage":
            # Сбор дикоросов: убираем ресурс и добавляем урожай на склад.
            # Качество собранного урожая = качество ресурса на гексе.
            var forage_quality = tile.get("quality", "common")
            var yield_data = sa.get("yield", {})
            for prod_id in yield_data:
                var range_arr = yield_data[prod_id]
                var amount = range_arr[0] if range_arr.size() == 1 else randi_range(int(range_arr[0]), int(range_arr[1]))
                CityData.add_to_storage(prod_id, amount, forage_quality)
                hud.show_message("Собрано %d %s!" % [amount, GameData.products.get(prod_id, {}).get("name", prod_id)])
            tile.resource = null
        elif action_type == "demolish":
            # Снос улучшения: убираем улучшение, ресурс остаётся.
            tile.improvement = null
        else:
            # Террейн-действие: сбрасываем ресурс и улучшение.
            tile.resource = null
            tile.improvement = null

        # Меняем тип местности только если result_terrain задан и не равен "dont_change".
        var result_terrain = sa.get("result_terrain", "")
        if result_terrain != "" and result_terrain != "dont_change":
            tile.terrain = result_terrain
            _assign_terrain_icon(row, col)

        build_manager.remove_build(row, col)
        map_renderer.queue_redraw()
        return

    tile.improvement = imp_id
    if animal_id != null:
        tile.resource = animal_id
        # Качество ресурса берётся из данных самого ресурса (animal_id/plant_id),
        # а не генерируется случайно — разведение исключительных животных
        # порождает исключительных животных.
        var res_data = GameData.raw_resources.get(animal_id, {})
        var res_quality = res_data.get("quality", "common")
        if res_quality == "" or res_quality == null:
            res_quality = "common"
        tile["quality"] = res_quality
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

func _on_building_build_completed(building_id: String, build_key: String):
    # Стройка здания завершена - добавляем его в город
    var slots = []
    if CityData.building_construction.has(build_key):
        var construction_data = CityData.building_construction[build_key]
        slots = construction_data.get("slots", [])
        CityData.building_construction.erase(build_key)
    
    CityData.city_built_buildings.append({"id": building_id, "slots": slots})
    
    # Назначаем горожанина
    if has_node("TownsfolkManager"):
        var tm = get_node("TownsfolkManager")
        tm.assign_townsfolk()
    
    CityData.emit_signal("city_updated")
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

func _setup_research_hud():
    # Создаём панель исследования: кнопка с иконкой технологии + прогресс-бар.
    # Размещаем между меткой даты и кнопкой "Город".
    var vbox = hud.get_node("VBoxContainer")
    research_hbox = HBoxContainer.new()
    research_hbox.add_theme_constant_override("separation", 4)

    research_button = Button.new()
    research_button.custom_minimum_size = Vector2(36, 24)
    research_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_button.text = ""
    # Иконку кладём как дочерний TextureRect, а не через Button.icon.
    # Причина: PNG 64×64 в кнопке 36×24 растягивается/вылезает, а в Godot
    # 4.7 нет ни icon_scale, ни icon_max_width, ни нормального способа
    # ограничить размер Button.icon. Свой TextureRect с custom_minimum_size
    # = 24×24 решает проблему раз и навсегда.
    var inner = HBoxContainer.new()
    inner.name = "InnerBox"
    inner.set_anchors_preset(Control.PRESET_FULL_RECT)
    inner.alignment = BoxContainer.ALIGNMENT_CENTER
    inner.add_theme_constant_override("separation", 2)
    inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
    research_button.add_child(inner)

    research_icon = TextureRect.new()
    research_icon.name = "TechIcon"
    research_icon.custom_minimum_size = Vector2(24, 24)
    research_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    research_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    research_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
    research_icon.visible = false
    inner.add_child(research_icon)

    research_label = Label.new()
    research_label.name = "TechLabel"
    research_label.text = "?"
    research_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    research_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    research_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    research_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    research_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    inner.add_child(research_label)

    research_button.tooltip_text = "Выберите технологию для изучения"
    research_button.pressed.connect(_on_research_hud_button_pressed)
    research_hbox.add_child(research_button)

    research_progress_bar = ProgressBar.new()
    research_progress_bar.custom_minimum_size = Vector2(120, 12)
    research_progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_progress_bar.max_value = 100.0
    research_progress_bar.value = 0.0
    research_progress_bar.show_percentage = false
    research_hbox.add_child(research_progress_bar)

    # Вставляем после YearLabel (даты), перед CityButton.
    var year_label = vbox.get_node("YearLabel")
    vbox.add_child(research_hbox)
    vbox.move_child(research_hbox, year_label.get_index() + 1)

    _update_research_progress()

func _update_research_progress():
    if research_button == null or research_progress_bar == null:
        return
    var tech_id = CityData.current_research_tech_id
    if tech_id == "":
        # Ничего не изучается — привлекаем внимание красным.
        # Иконку обязательно прячем, иначе старая технология торчит на кнопке.
        if research_icon:
            research_icon.visible = false
            research_icon.texture = null
        if research_label:
            research_label.visible = true
            research_label.text = "!"
        research_button.tooltip_text = "Никакая технология не изучается. Нажмите, чтобы выбрать технологию"
        research_progress_bar.value = 0.0
        research_progress_bar.modulate = Color(1, 1, 1, 1)
        _apply_research_button_warning(true)
        _last_research_hud_tech = ""
        return

    # Изучается технология — показываем иконку (если есть) и прогресс.
    var tech_data = null
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_data = t
            break
    if tech_data:
        research_button.tooltip_text = "Изучается: %s" % tech_data.get("name", tech_id)
        var icon_name: String = tech_data.get("icon", "")
        if icon_name != "" and research_icon:
            var path = map_renderer.get_icon_path(icon_name)
            if path != "":
                var tex = load(path)
                if tex:
                    research_icon.texture = tex
                    research_icon.visible = true
                    # Скрываем Label, чтобы HBox не резервировал под него
                    # место. Иначе иконка «прилипает» к левому краю кнопки,
                    # а справа — пустая область под скрытый label.
                    if research_label:
                        research_label.visible = false
                else:
                    research_icon.visible = false
                    if research_label:
                        research_label.visible = true
                        research_label.text = "?"
            else:
                research_icon.visible = false
                if research_label:
                    research_label.visible = true
                    research_label.text = "?"
        else:
            if research_icon:
                research_icon.visible = false
            if research_label:
                research_label.visible = true
                research_label.text = "?"
    else:
        if research_icon:
            research_icon.visible = false
        if research_label:
            research_label.visible = true
            research_label.text = "?"
        research_button.tooltip_text = "Изучается технология"
    _apply_research_button_warning(false)

    if CityData.current_research_science_cost > 0:
        research_progress_bar.value = CityData.research_progress * 100.0
    else:
        research_progress_bar.value = 0.0
    research_progress_bar.modulate = Color(1, 1, 1, 1)
    _last_research_hud_tech = tech_id

func _apply_research_button_warning(warning: bool):
    # Красная рамка/подсветка при отсутствии исследования.
    var normal = StyleBoxFlat.new()
    normal.bg_color = Color(0.3, 0.3, 0.3, 1.0)
    normal.set_border_width_all(2)
    if warning:
        normal.border_color = Color(1.0, 0.2, 0.2, 1.0)
    else:
        normal.border_color = Color(0.4, 0.4, 0.4, 1.0)
    research_button.add_theme_stylebox_override("normal", normal)
    # Переопределяем hover/pressed/focus тем же стилем, чтобы при наведении
    # не менялись content margins и размер кнопки оставался прежним.
    research_button.add_theme_stylebox_override("hover", normal)
    research_button.add_theme_stylebox_override("pressed", normal)
    research_button.add_theme_stylebox_override("focus", normal)
    if warning:
        research_button.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
    else:
        research_button.add_theme_color_override("font_color", Color.WHITE)

func _on_research_hud_button_pressed():
    # Переход в интерфейс города на вкладку "Технологии".
    if pause_menu.visible:
        return
    city_ui.refresh()
    city_ui.show_technologies_tab()
    city_ui.show()
    hud.hide()

func open_city():
    city_ui.refresh()
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
    _update_research_progress()

func _on_research_error(message: String):
    if city_ui.visible:
        city_ui.set_message(message)
    else:
        hud.show_message(message)

func _on_research_completed(tech_id: String):
    map_renderer.queue_redraw()
    # Показываем окно изученной технологии и ставим игру на паузу,
    # чтобы игрок не мог взаимодействовать с картой и HUD, пока окно открыто.
    if tech_popup and tech_popup.has_method("show_tech"):
        get_tree().paused = true
        tech_popup.show_tech(tech_id, CityData.last_research_messages)
    # Сообщения переданы в попап — очищаем их.
    CityData.last_research_messages = []

func _on_tech_popup_go_to_techs():
    # Снимаем паузу и открываем интерфейс города на вкладке "Технологии"
    get_tree().paused = false
    city_ui.refresh()
    city_ui.show_technologies_tab()
    city_ui.show()
    hud.hide()

func _on_pause_save():
    SaveManager.save_game()
    hud.show_message("Игра сохранена.")

func _on_pause_menu_visibility_changed():
    var menu_visible = pause_menu.visible
    city_button.disabled = menu_visible
    expansion_button.disabled = menu_visible
    menu_button.visible = not menu_visible

func open_pause_menu():
    pause_menu.show()
    city_button.disabled = true
    expansion_button.disabled = true
    # Приостанавливаем игру, пока открыто меню паузы
    get_tree().paused = true

func _on_menu_button_pressed():
    if pause_menu.visible:
        return
    open_pause_menu()

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

# Возвращает фактическую стоимость труда для постройки улучшения imp_id на гексе (row, col).
# Стоимость зависит от базового work_cost улучшения, типа местности (move_cost) и
# расстояния от города. Возвращает словарь с итоговой стоимостью и деталями расчёта
# (для расширенного тултипа).
func get_improvement_work_cost(imp_id: String, row: int, col: int) -> Dictionary:
    # Спец-действия не являются улучшениями — используем их базовую стоимость из данных.
    var base_cost = 0.0
    if GameData.special_actions.has(imp_id):
        base_cost = float(GameData.special_actions[imp_id].get("work_cost", 0))
    else:
        var imp_data = GameData.improvements.get(imp_id, {})
        base_cost = float(imp_data.get("work_cost", 0))
    # Множитель от типа местности: чем выше move_cost, тем труднее строить.
    var terrain_id = "plain"
    if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
        terrain_id = tile_data[row][col].get("terrain", "plain")
    var move_cost = 1.0
    if GameData.terrains.has(terrain_id):
        move_cost = float(GameData.terrains[terrain_id].get("move_cost", 1))
    var terrain_mult = 1.0 + (move_cost - 1.0) * 0.35

    # Множитель от расстояния до города (в гексах).
    var distance = HexUtils.hex_distance(row, col, CITY_ROW, CITY_COL)
    var distance_mult = 1.0 + float(distance) * 0.25

    var final_cost = int(ceil(base_cost * terrain_mult * distance_mult))
    return {
        "cost": final_cost,
        "base_cost": int(base_cost),
        "terrain_id": terrain_id,
        "terrain_name": GameData.terrains.get(terrain_id, {}).get("name", terrain_id),
        "move_cost": move_cost,
        "terrain_mult": terrain_mult,
        "distance": distance,
        "distance_mult": distance_mult
    }

func _on_city_button_gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        scroll_offset = - (HexUtils.hex_center(CITY_ROW, CITY_COL, HEX_RADIUS) + Vector2(offset_x, offset_y) - get_viewport_rect().size / 2.0)
        map_renderer.queue_redraw()

func _on_expansion_button_pressed():
    # Кнопка "Развитие" больше не имеет функционала
    pass

func _on_expansion_mode_changed(_active: bool):
    map_renderer.queue_redraw()

func _on_territory_expanded(_row: int, _col: int, cost: int):
    hud.show_message("Территория расширена! (%d еды)" % cost)
    map_renderer.queue_redraw()
    if city_ui.visible:
        city_ui.refresh()

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
        tooltip_delay = settings_config.get_value("interface", "tooltip_delay", 0.5)
        extended_tooltip_delay = settings_config.get_value("interface", "extended_tooltip_delay", 1.0)
    else:
        show_hex_borders = true
        use_edge_scrolling = true
        tooltip_delay = 0.5
        extended_tooltip_delay = 1.0

func apply_settings():
    _load_settings()
    input_handler.set_tooltip_delay(tooltip_delay)
    input_handler.set_extended_tooltip_delay(extended_tooltip_delay)
    map_renderer.queue_redraw()

func _on_population_changed(_new_pop: int):
    _update_population_hud()

func _update_population_hud():
    var pop_label = hud.get_node_or_null("VBoxContainer/PopulationLabel")
    if pop_label:
        pop_label.text = "Население: %d" % CityData.total_population

func _on_assignment_changed():
    map_renderer.queue_redraw()
    if city_ui.visible:
        city_ui.refresh_light()

func _on_townsfolk_assignment_changed():
    if city_ui.visible:
        city_ui.refresh_light()

func _get_scouting_time(hex_count: int) -> float:
    return hex_count * SCOUTING_TIME_PER_HEX

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
        CityData.remove_from_storage(pid, 1, "best")
        remaining -= 1
        if CityData.city_storage.get(pid, 0) <= 0:
            active_food.erase(pid)
    scouting_chunk = chunk
    scouting_timer = 0.0
    is_scouting = true
    hud.show_message("Разведчики отправлены...")

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
    var cover_forests = false
    var resources = []
    for hex in chunk:
        var tile = tile_data[hex.row][hex.col]
        var terrain = tile.get("terrain", "plain")
        terrain_types[terrain] = terrain_types.get(terrain, 0) + 1
        var cover_id = tile.get("cover", "none")
        if cover_id != "none":
            cover_forests = true
        if tile.resource != null:
            var res_name = GameData.raw_resources.get(tile.resource, {}).get("name", tile.resource)
            resources.append(res_name)
    var terrain_names = []
    for terrain_id in terrain_types.keys():
        terrain_names.append(GameData.terrains.get(terrain_id, {}).get("name", terrain_id))
    var terrain_str = ", ".join(terrain_names)
    if cover_forests:
        terrain_str += ", лес"
    var resource_str = ", ".join(resources) if resources.size() > 0 else "нет"
    return "Ландшафт: %s. Ресурсы: %s" % [terrain_str, resource_str]

func _confirm_cancel_build(row: int, col: int):
    var prog = build_manager.get_progress(row, col)
    if prog.is_empty():
        return
    var imp_name = prog.get("imp_name", "Улучшение")
    var work_done = prog.get("progress", 0.0)
    var work_total = prog.get("work_cost", 0)

    # Создаём диалог подтверждения
    var dialog = AcceptDialog.new()
    dialog.title = "Отмена строительства"
    dialog.dialog_text = "Отменить строительство «%s»?\n\nПотраченный труд (%.0f/%d) будет потерян." % [imp_name, work_done, work_total]
    dialog.confirmed.connect(func(): build_manager.cancel_build(row, col))
    add_child(dialog)
    dialog.popup_centered()
