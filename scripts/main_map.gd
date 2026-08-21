@tool
extends Node2D

const HEX_RADIUS = 55

# --- Размеры и границы мира/окна ---
# Основные параметры (map_rows, map_cols, start_ring_rows, start_ring_cols,
# region_width) загружаются из data/map_config.json в _load_map_config().
# Они НЕ являются константами, потому что:
#   1) значения приходят из JSON;
#   2) при переходе в следующую эпоху Кольцо и Регион расширяются.
var map_rows: int = 60 # Вся карта: ряды (гексы)
var map_cols: int = 60 # Вся карта: колонки (гексы)
var start_ring_rows: int = 7 # Стартовое Кольцо Влияния: ряды
var start_ring_cols: int = 9 # Стартовое Кольцо Влияния: колонки
var region_width: int = 2 # Ширина Региона вокруг Кольца (в гексах)

# Текущее (динамически растущее) Кольцо Влияния.
var ring_rows: int = 7
var ring_cols: int = 9

# Текущее видимое окно: Кольцо + Регион.
var region_rows: int = 11
var region_cols: int = 13

# Положение города (центр всей карты).
var city_row: int = 30
var city_col: int = 30

# Абсолютные границы Кольца Влияния (инклюзивные) на всей карте.
var influence_start_row: int = 0
var influence_end_row: int = 0
var influence_start_col: int = 0
var influence_end_col: int = 0

# Абсолютные границы видимого окна «Кольцо + Регион» (инклюзивные).
# Всё за пределами этого окна скрыто туманом войны (не отрисовывается).
var region_start_row: int = 0
var region_end_row: int = 0
var region_start_col: int = 0
var region_end_col: int = 0

# Стартовые границы «Кольцо» и «Кольцо + Регион» на момент генерации карты.
# Сохраняются ОДИН раз в _initialize_map и далее НЕ меняются — нужны для
# гарантий спавна ресурсов, чтобы они работали по исходным, а не будущим
# расширенным границам. Например, _ensure_minimum_resource({"category": "metals"})
# опирается именно на эти поля, а не на текущие influence_* / region_*.
var start_influence_start_row: int = 0
var start_influence_end_row: int = 0
var start_influence_start_col: int = 0
var start_influence_end_col: int = 0
var start_region_start_row: int = 0
var start_region_end_row: int = 0
var start_region_start_col: int = 0
var start_region_end_col: int = 0

# Текущая эпоха (0 = стартовая). Используется инфраструктурой расширения.
var current_era: int = 0

const SCOUTING_TIME_PER_HEX: float = 3.0
# Спец-действия (вырубка леса, сбор дикоросов, снос улучшений и т.п.)
# загружаются из data/special_actions.json и реализуются через систему
# труда build_manager, но не являются улучшениями.

var tile_data = []
var offset_x: float = 0.0
var offset_y: float = 0.0
var scroll_offset = Vector2.ZERO

# Гексы уникальной местности (например, содовое озеро soda_lake),
# которые всегда отображаются на карте даже за пределами видимого Региона.
var unique_terrain_hexes: Array = []

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
@onready var progress_bar_layer = $MapRenderer/ProgressBarLayer
@onready var road_manager = $RoadManager
@onready var expansion_manager = $ExpansionManager
@onready var river_manager = $RiverManager
@onready var worker_manager = $WorkerManager
@onready var townsfolk_manager = $TownsfolkManager
@onready var settings_menu = preload("res://scenes/settings_menu.tscn").instantiate()
@onready var input_handler = $InputHandler
@onready var debug_manager = $DebugManager
var map_tooltip: MapTooltip

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
        progress_bar_layer.initialize(tile_data, self)
        map_renderer.queue_redraw()
        return

    _load_map_config()

    if SaveManager.is_loaded:
        GameData.load_all_data()
        map_renderer.build_icon_index()
        map_renderer.load_icons()
        SaveManager.apply_loaded_data()

        # Восстанавливаем состояние мира/окна из сохранения ДО построения tile_data.
        _apply_saved_map_state()

        tile_data = []
        road_manager.initialize(city_row, city_col)
        var saved_tiles = SaveManager.saved_data.get("tile_data", [])
        for row in range(map_rows):
            var col_array = []
            for col in range(map_cols):
                # crop_bred — id одомашненного животного/растения, разводимого
                # на пустом гексе (см. docs.md, раздел «Разведение животных/растений»).
                # Для природных ресурсов остаётся tile.resource.
                var tile = {"terrain": "plain", "cover": "none", "resource": null, "crop_bred": null, "improvement": null, "terrain_icon": "", "in_influence": false, "is_explored": false, "river_edges": []}
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
                        # crop_bred добавился в схеме разведения; в старых сейвах
                        # его нет, но тогда и нечего мигрировать — поле просто null.
                        tile["crop_bred"] = saved.get("crop_bred")
                        tile["improvement"] = saved.get("improvement")
                        tile["quality"] = saved.get("quality", "")
                        tile["terrain_icon"] = saved.get("terrain_icon", "")
                        tile["in_influence"] = saved.get("in_influence", false)
                        tile["is_explored"] = saved.get("is_explored", false)
                        tile["river_edges"] = saved.get("river_edges", [])
                col_array.append(tile)
            tile_data.append(col_array)

        # Гарантируем, что город находится на разрешённой местности при загрузке сохранения
        _ensure_city_valid_terrain()

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

        road_manager.rebuild_roads_from_existing(tile_data, map_rows, map_cols)

        # Восстанавливаем реки из сохранения и помечаем river_edges в гексах
        river_manager.load_rivers(SaveManager.saved_data.get("rivers", []))
        river_manager.mark_river_edges(tile_data, map_rows, map_cols, HEX_RADIUS)

        # Собираем гексы уникальной местности (например, содовое озеро) после загрузки.
        unique_terrain_hexes = []
        for row in range(map_rows):
            for col in range(map_cols):
                var terrain_id = tile_data[row][col].get("terrain", "plain")
                var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
                if t_data.get("unique", false):
                    unique_terrain_hexes.append({"row": row, "col": col})

        SaveManager.is_loaded = false
        SaveManager.saved_data.clear()
        map_renderer.initialize(tile_data, self)
        progress_bar_layer.initialize(tile_data, self)
    else:
        randomize()
        _initialize_map()
        road_manager.initialize(city_row, city_col)
        map_renderer.initialize(tile_data, self)
        progress_bar_layer.initialize(tile_data, self)

    _load_settings()

    tooltip_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    tooltip_text_label.custom_minimum_size = Vector2(300, 0)

    add_child(settings_menu)
    settings_menu.hide()

    # Инициализация InputHandler
    input_handler.initialize(self)

    map_tooltip = MapTooltip.new(tooltip_text_label, tooltip_products_container, map_renderer, worker_manager)

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
        for row in range(region_start_row, region_end_row + 1):
            for col in range(region_start_col, region_end_col + 1):
                var tile = tile_data[row][col]
                if tile.improvement == null or not worker_manager.has_worker(row, col):
                    continue
                # Производство идёт и с природного ресурса (tile.resource), и с
                # разводимого (tile.crop_bred, см. схему разведения). Если оба
                # null — гекс нечего производить.
                var eff_res = MapHelpers.get_effective_resource(tile)
                if eff_res == "":
                    continue

                var res_data = GameData.raw_resources.get(eff_res, {})
                var feed_needed = res_data.get("feed_consumption", 0)
                var production_multiplier = 1.0
                if tile.improvement != null:
                    # Передаём terrain_id и resource_id для модификаторов по
                    # местности (например, битум на асфальтовом озере x2).
                    production_multiplier = CityData.get_improvement_production_multiplier(
                        tile.improvement, _is_hex_irrigated(row, col),
                        tile.get("terrain", ""), eff_res)

                # Качество ресурса на гексе передаётся в производство.
                var tile_quality = tile.get("quality", "common")
                if feed_needed > 0:
                    var available_feed = CityData.city_storage.get("feed", 0)
                    if available_feed >= feed_needed:
                        CityData.remove_from_storage("feed", feed_needed, "best")
                        CityData.add_raw_production(eff_res, production_multiplier, tile_quality)
                    else:
                        CityData.add_raw_production(eff_res, 0.25, tile_quality)
                else:
                    CityData.add_raw_production(eff_res, production_multiplier, tile_quality)

        CityData.do_tick()
        # tick_research_science вызывается каждый кадр ниже (см. _process),
        # а не привязан к production-тику. Это даёт плавный progress-bar.

    _update_research_progress()
    # Перерисовываем слой прогресс-баров ТОЛЬКО когда есть что показывать:
    # идёт исследование, есть активные стройки или идёт разведка. В противном
    # случае слой лёгкий и его _draw() ничего не рисует — нет смысла вызывать
    # queue_redraw() каждый кадр. Когда строительство/исследование/разведка
    # завершились/начались, соответствующие обработчики вызывают
    # _redraw_progress_layer() (см. ниже), чтобы слой гарантированно
    # обновился и не оставался висеть на 100% или показывать устаревшие бары.
    if CityData.current_research_tech_id != "" \
            or build_manager.has_active_builds() \
            or is_scouting:
        progress_bar_layer.queue_redraw()

    input_handler.handle_process(delta)

    if is_scouting:
        scouting_timer += delta
        if scouting_timer >= _get_scouting_time(scouting_chunk.size()):
            _complete_scouting()

func _initialize_map():
    GameData.load_all_data()
    CityData.setup()
    map_renderer.build_icon_index()
    map_renderer.load_icons()

    # Устанавливаем стартовые размеры Кольца и Региона из конфигурации.
    ring_rows = start_ring_rows
    ring_cols = start_ring_cols
    region_rows = ring_rows + region_width * 2
    region_cols = ring_cols + region_width * 2
    _recalculate_bounds()

    # Запоминаем стартовые границы (Кольцо + видимое окно). Они нужны для
    # гарантий спавна ресурсов, чтобы металл и food_plant НЕ появлялись за
    # пределами изначально видимой области даже после расширения в новой эпохе.
    start_influence_start_row = influence_start_row
    start_influence_end_row = influence_end_row
    start_influence_start_col = influence_start_col
    start_influence_end_col = influence_end_col
    start_region_start_row = region_start_row
    start_region_end_row = region_end_row
    start_region_start_col = region_start_col
    start_region_end_col = region_end_col

    # Генерируем ВСЮ карту мира сразу (рельеф, покров, реки).
    var generator = load("res://scripts/map_generator.gd").new()
    # Количество центров Вороного для каждого типа местности вычисляется
    # из конфигурации terrain_config (density + target_cluster),
    # заданной в data/map_config.json.
    var terrain_counts = generator.make_terrain_counts(map_rows, map_cols)
    tile_data = generator.generate_map(map_rows, map_cols, city_row, city_col, GameData.raw_resources, terrain_counts)
    print("Карта мира сгенерирована. Гексов: ", map_rows * map_cols)

    # Гарантируем, что город находится на разрешённой местности (равнина или холмы)
    _ensure_city_valid_terrain()

    # Помечаем стартовое Кольцо Влияния и сбрасываем исследование.
    # Флаги ставим для ВСЕЙ карты, т.к. генераторы (place_wild_food и др.)
    # итерируют по всем гексам и обращаются к "in_influence".
    var t_influence = Time.get_ticks_msec()
    for row in range(map_rows):
        for col in range(map_cols):
            var tile = tile_data[row][col]
            tile["in_influence"] = is_in_influence(row, col)
            tile["is_explored"] = false
    print("этап in_influence: ", Time.get_ticks_msec() - t_influence, " ms")

    # Собираем гексы уникальной местности (например, содовое озеро).
    # Они отображаются на карте даже за пределами видимого Региона
    # (см. map_renderer._draw), поэтому храним их отдельным списком.
    unique_terrain_hexes = []
    for row in range(map_rows):
        for col in range(map_cols):
            var terrain_id = tile_data[row][col].get("terrain", "plain")
            var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
            if t_data.get("unique", false):
                unique_terrain_hexes.append({"row": row, "col": col})

    # Дикоросы и гарантированный food_plant спавнятся ТОЛЬКО один раз при
    # старте новой игры и ТОЛЬКО внутри стартового Кольца Влияния.
    # Передаём явные границы стартового Кольца, чтобы эти функции никогда
    # не выходили за его пределы (даже если Кольцо позже расширится).
    _ensure_food_plant(influence_start_row, influence_end_row, influence_start_col, influence_end_col, city_row, city_col)
    generator.place_wild_food(tile_data,
            influence_start_row, influence_end_row, influence_start_col, influence_end_col,
            city_row, city_col)

    # Ресурсы, которые встречаются в Кольце Влияния, не дублируются в Регионе.
    var influence_resource_types = {}
    for row in range(influence_start_row, influence_end_row + 1):
        for col in range(influence_start_col, influence_end_col + 1):
            var res = tile_data[row][col]["resource"]
            if res != null:
                influence_resource_types[res] = true

    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            if not tile_data[row][col]["in_influence"]:
                var res = tile_data[row][col]["resource"]
                if res != null and influence_resource_types.has(res):
                    tile_data[row][col]["resource"] = null

    # --- Гарантии для стартовой области «Кольцо + Регион» ---
    # Используем стартовые границы (не текущие), чтобы при будущем
    # расширении в новую эпоху не срабатывало повторно. Сейчас в игре
    # единственный металл — железо; при добавлении новых функция выберет
    # один из них случайно. Аналогично для остальных категорий ниже.
    #
    # Пищевое растение гарантируется отдельно (см. _ensure_food_plant выше)
    # и остаётся ТОЛЬКО в стартовом Кольце — игрок должен иметь возможность
    # сразу поставить ферму без разведки/покупки региона.
    _ensure_minimum_resource({"category": "metals"})
    _ensure_minimum_resource({"category": "animals", "group": "meat_animals"})
    _ensure_minimum_resource({"category": "minerals", "subgroup": "construction_materials"})

    # --- Пост-обработка: гарантируем достаточное количество СВОБОДНЫХ гексов ---
    # После размещения всех ресурсов у каждого типа местности в Кольце Влияния
    # должно остаться минимум FREE_TERRAIN_HEXES свободных (resource == null)
    # гексов. Это исключает софт-лок: если ресурс (например, киноа — только горы)
    # попал в кольцо, у игрока всегда будет место для дополнительных ферм/пастбищ.
    # Метод конвертирует ТОЛЬКО свободные гексы и НИКОГДА не уничтожает ресурсы.
    generator.ensure_free_terrain_hexes(tile_data, terrain_counts,
            influence_start_row, influence_end_row, influence_start_col, influence_end_col,
            city_row, city_col)

    # Используем ЛОКАЛЬНЫЙ генератор случайных чисел для выбора иконки ландшафта.
    # Ни в коем случае нельзя вызывать seed()/randomize() на глобальном RNG внутри
    # этого цикла — это разрушило бы случайность всех последующих randf()/randi()
    # (например, при спавне ресурсов после изучения технологий).
    var t_terrain_icon = Time.get_ticks_msec()
    var icon_rng = RandomNumberGenerator.new()
    for row in range(map_rows):
        for col in range(map_cols):
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
    print("этап terrain_icon: ", Time.get_ticks_msec() - t_terrain_icon, " ms")

    # Генерируем речную систему (главные реки + притоки) по всей карте
    # и помечаем рёбра реки в данных гексов. Передаём tile_data (для гор/озёр)
    # и границы стартовой области «Кольцо + Регион» (гарантия пересечения).
    var t_rivers = Time.get_ticks_msec()
    river_manager.generate_rivers(map_rows, map_cols, HEX_RADIUS, tile_data,
            region_start_row, region_end_row, region_start_col, region_end_col)
    print("этап generate_rivers: ", Time.get_ticks_msec() - t_rivers, " ms")
    var t_river_edges = Time.get_ticks_msec()
    river_manager.mark_river_edges(tile_data, map_rows, map_cols, HEX_RADIUS, river_manager.get_cached_graph())
    print("этап mark_river_edges: ", Time.get_ticks_msec() - t_river_edges, " ms")

    # Финальная гарантия: на гексе города не должно быть ресурса, и террейн
    # должен быть допустимым (plain или hill). Это safety-net на случай,
    # если какая-либо функция спавна ресурсов или конвертации террейна
    # пропустила проверку координат города.
    _ensure_city_hex_clean()

func _ensure_city_valid_terrain() -> void:
    MapHelpers.ensure_city_valid_terrain(tile_data, city_row, city_col, map_rows, map_cols)

func _is_hex_adjacent_to_canal(row: int, col: int) -> bool:
    return MapHelpers.is_hex_adjacent_to_canal(row, col, tile_data, map_rows, map_cols)

func _is_hex_irrigated(row: int, col: int) -> bool:
    return MapHelpers.is_hex_irrigated(row, col, tile_data, map_rows, map_cols)

func _ensure_minimum_resource(filter: Dictionary):
    # Гарантия работает по СТАРТОВЫМ границам «Кольцо + Регион», а не по
    # текущим (которые могут быть расширены переходом в новую эпоху).
    # Используется при инициализации карты, чтобы в стартовой области
    # всегда был хотя бы один ресурс, удовлетворяющий фильтру.
    # Примеры фильтров:
    #   { "category": "metals" }                                          — любой металл
    #   { "category": "animals", "group": "meat_animals" }                — мясное животное
    #   { "category": "minerals", "subgroup": "construction_materials" }  — стройматериал
    MapHelpers.ensure_minimum_resource(
        tile_data, filter,
        start_influence_start_row, start_influence_end_row,
        start_influence_start_col, start_influence_end_col,
        city_row, city_col
    )

# Гарантирует наличие хотя бы одного ресурса из food_plants в стартовом Кольце.
# Вызывается ТОЛЬКО один раз при старте новой игры (из _initialize_map).
# Границы (min_row..max_row, min_col..max_col) — это стартовое Кольцо,
# поэтому food_plant гарантированно не появляется за его пределами
# и не пересоздаётся после старта.
func _ensure_food_plant(min_row: int, max_row: int, min_col: int, max_col: int, city_row: int = -1, city_col: int = -1):
    MapHelpers.ensure_food_plant(tile_data, min_row, max_row, min_col, max_col, city_row, city_col)

# Финальная safety-проверка: гарантирует, что на гексе города нет ресурса
# и террейн валиден. Вызывается после всех этапов генерации карты.
func _ensure_city_hex_clean() -> void:
    var city_tile = tile_data[city_row][city_col]
    if city_tile.get("resource", null) != null:
        print("ВНИМАНИЕ: на гексе города стоял ресурс «", city_tile["resource"], "» — удален.")
        city_tile["resource"] = null
    _ensure_city_valid_terrain()

# Ищет на карте уже одомашненный экземпляр ресурса res_id (гекс с этим ресурсом
# и построенным улучшением — ферма/пастбище) и возвращает его качество.
# Используется при разведении нового животного/растения на пустом гексе:
# качество наследуется от уже одомашненного образца
# ("исключительное порождает исключительное"). Если такого образца нет —
# возвращает пустую строку, и вызывающий код генерирует качество через roll.
func _find_domesticated_quality(res_id: String) -> String:
    return MapHelpers.find_domesticated_quality(
        res_id, tile_data,
        region_start_row, region_end_row,
        region_start_col, region_end_col
    )

func _calc_offsets():
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size
    var offsets = MapHelpers.calc_offsets(
        region_start_row, region_end_row,
        region_start_col, region_end_col,
        HEX_RADIUS, viewport_size
    )
    offset_x = offsets.x
    offset_y = offsets.y

func update_tooltip_text(row: int, col: int):
    map_tooltip.update_tooltip_text(row, col, tile_data, city_row, city_col)

# Возвращает id улучшения, которое можно построить на гексе (row, col),
# или пустую строку, если постройка невозможна.
func _get_buildable_improvement(row: int, col: int) -> String:
    return MapHelpers.get_buildable_improvement(tile_data[row][col])

# Возвращает true, если для гекса нужно показывать расширенный тултип:
# есть бонусы производства ИЛИ можно построить улучшение (тогда показываем расчёт труда).
func has_extended_tooltip_info(row: int, col: int) -> bool:
    return map_tooltip.has_extended_tooltip_info(row, col, tile_data)

func update_extended_tooltip(row: int, col: int):
    map_tooltip.update_extended_tooltip(row, col, tile_data, city_row, city_col)

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
            # Если ресурс скрыт tech_reveal-гейтом — игрок о нём не знает, и
            # контекстное меню не должно предлагать ни «Изучить X», ни
            # «Построить Y» (иначе пункт «Изучить Обработка металлов» появится
            # на невидимом железе и собьёт с толку). Меню остаётся пустым
            # для блока «ресурс» — игрок увидит только общие пункты ниже
            # (спец-действия, отмена стройки и т.п.).
            if not MapHelpers.is_resource_revealed(tile):
                pass # ресурс скрыт, никаких опций
            elif map_renderer.is_resource_locked(tile.resource):
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
                        popup_menu.set_item_metadata(popup_menu.item_count - 1, {"action": "build_improvement", "imp_id": imp_id, "target_res_id": tile.resource})
                    else:
                        var labor = CityData.get_total_labor()
                        var build_time = work_cost / max(1.0, labor)
                        var label = "Построить %s (%s) [%d труда, %.0f сек.]" % [imp_name, raw.get("name", tile.resource), work_cost, build_time]
                        popup_menu.add_item(label)
                        var last_idx = popup_menu.item_count - 1
                        popup_menu.set_item_metadata(last_idx, {"action": "build_improvement", "imp_id": imp_id, "target_res_id": tile.resource})

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
        var target_res_id = meta.get("target_res_id", null)
        # Если строительство уже идёт — переключаем паузу/возобновление
        if build_manager.is_building(row, col):
            if build_manager.is_building_paused(row, col):
                build_manager.resume_build(row, col)
            else:
                build_manager.pause_build(row, col)
        else:
            build_manager.start_build(row, col, imp_id, target_res_id)
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
    # При старте стройки/исследования появляется/пропадает прогресс-бар —
    # вызываем перерисовку слоя баров явно, чтобы не ждать следующего кадра
    # (когда has_active_builds() может снова стать true).
    _redraw_progress_layer()

# Выбирает иконку ландшафта для гекса (row, col) на основе его террейна.
func _assign_terrain_icon(row: int, col: int) -> void:
    tile_data[row][col]["terrain_icon"] = MapHelpers.get_terrain_icon(row, col, tile_data)

# Запрашивает перерисовку слоя прогресс-баров. Вызывается при старте/завершении
# строительства, исследования и разведки, когда слой может измениться, но
# _process (_active) больше не будет триггерить перерисовку (например, из-за
# завершения последней стройки). Иначе последний кадр с заполненным на 100%
# баром навсегда остался бы на экране.
func _redraw_progress_layer():
    if progress_bar_layer:
        progress_bar_layer.queue_redraw()

func _on_build_completed(row: int, col: int, imp_id: String, target_res_id = null):
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
            # Снос улучшения: убираем улучшение. Природный tile.resource
            # остаётся (если он был), а tile.crop_bred сбрасывается —
            # разведение живёт ровно столько, сколько стоит улучшение.
            # Иначе после сноса прод-цикл начал бы «производить» ресурс,
            # для которого больше нет улучшения.
            tile.improvement = null
            tile.crop_bred = null
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
        _redraw_progress_layer()
        return

    tile.improvement = imp_id
    if target_res_id != null:
        # Два сценария:
        # 1) На гексе УЖЕ был природный ресурс (tile.resource != null) — мы
        #    ставим улучшение, чтобы его добывать. tile.resource сохраняется,
        #    crop_bred остаётся null. Качество — текущее качество ресурса.
        # 2) Гекс был пустой (tile.resource == null) — это разведение. Пишем
        #    id разводимого животного/растения в tile.crop_bred, а tile.resource
        #    НЕ трогаем (остаётся null). Качество наследуется от уже
        #    одомашненного экземпляра этого же ресурса, иначе бросаем roll.
        var was_existing_resource = tile.resource != null
        if was_existing_resource:
            tile.resource = target_res_id
            # Качество ресурса определяется так:
            # - Если на гексе УЖЕ был ресурс (улучшение существующего) — сохраняем
            #   его качество. Иначе любая постройка фермы/шахты сбрасывала бы
            #   quality на "common", потому что в JSON ресурсов нет поля quality.
            var existing_q = tile.get("quality", "")
            if existing_q == "" or existing_q == null:
                tile["quality"] = GameData.roll_quality()
        else:
            # Разведение на пустом гексе: id ресурса живёт в crop_bred.
            tile.crop_bred = target_res_id
            # - Если это разведение НОВОГО животного/растения (гекс был пустой) —
            #   ищем на карте уже одомашненный экземпляр этого ресурса и
            #   наследуем его качество ("исключительное порождает исключительное").
            #   Если такого ещё нет — генерируем случайно.
            var inherited_quality = _find_domesticated_quality(target_res_id)
            if inherited_quality != "" and inherited_quality != null:
                tile["quality"] = inherited_quality
            else:
                tile["quality"] = GameData.roll_quality()
        if CityData:
            if GameData.raw_resources.has(target_res_id) and GameData.raw_resources[target_res_id].get("category") == "animals":
                CityData.add_animal(target_res_id)
            elif GameData.raw_resources.has(target_res_id) and GameData.raw_resources[target_res_id].get("category") == "plants":
                CityData.add_plant(target_res_id)
    build_manager.remove_build(row, col)
    road_manager.build_road_from(row, col, tile_data, map_rows, map_cols)
    if not worker_manager.assign_worker(row, col):
        pass
    map_renderer.queue_redraw()
    _redraw_progress_layer()

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
    _redraw_progress_layer()

func pixel_to_hex(mx: float, my: float):
    return MapHelpers.pixel_to_hex(mx, my,
        region_start_row, region_end_row,
        region_start_col, region_end_col,
        offset_x, offset_y,
        scroll_offset, HEX_RADIUS)

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
    _redraw_progress_layer()
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
    return MapHelpers.get_improvement_work_cost(imp_id, row, col, tile_data, city_row, city_col)

func _on_city_button_gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        scroll_offset = - (HexUtils.hex_center(city_row, city_col, HEX_RADIUS) + Vector2(offset_x, offset_y) - get_viewport_rect().size / 2.0)
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
    # Валиден гекс в пределах ВИДИМОГО окна (Кольцо + Регион).
    return row >= region_start_row and row <= region_end_row and col >= region_start_col and col <= region_end_col

func _on_chunk_hovered(_chunk: Array):
    map_renderer.queue_redraw()

# Загружает параметры карты/окна из data/map_config.json (через GameData).
# Значения используются как стартовые для новой игры.
func _load_map_config():
    var cfg: Dictionary = GameData.map_config
    if cfg.is_empty():
        # Конфиг не найден — используем значения по умолчанию.
        map_rows = 200
        map_cols = 200
        start_ring_rows = 7
        start_ring_cols = 5
        region_width = 2
    else:
        map_rows = int(cfg.get("map_rows", 200))
        map_cols = int(cfg.get("map_cols", 200))
        start_ring_rows = int(cfg.get("start_ring_rows", 7))
        start_ring_cols = int(cfg.get("start_ring_cols", 5))
        region_width = int(cfg.get("region_width", 2))

    # Город — всегда в центре всей карты.
    city_row = map_rows / 2
    city_col = map_cols / 2

# Пересчитывает АБСОЛЮТНЫЕ границы Кольца Влияния и видимого окна
# (Кольцо + Регион) вокруг города. Вызывается после изменения
# ring_rows/ring_cols/region_rows/region_cols (новая игра, загрузка, эпоха).
func _recalculate_bounds():
    var bounds = MapHelpers.recalculate_bounds(
        city_row, city_col,
        ring_rows, ring_cols,
        region_rows, region_cols,
        map_rows, map_cols
    )
    influence_start_row = bounds.influence_start_row
    influence_end_row = bounds.influence_end_row
    influence_start_col = bounds.influence_start_col
    influence_end_col = bounds.influence_end_col
    region_start_row = bounds.region_start_row
    region_end_row = bounds.region_end_row
    region_start_col = bounds.region_start_col
    region_end_col = bounds.region_end_col

# Возвращает true, если гекс (row, col) входит в текущее Кольцо Влияния.
func is_in_influence(row: int, col: int) -> bool:
    return row >= influence_start_row and row <= influence_end_row \
        and col >= influence_start_col and col <= influence_end_col

# Возвращает словарь с текущим состоянием мира/окна для сохранения.
func get_map_state() -> Dictionary:
    return {
        "map_rows": map_rows,
        "map_cols": map_cols,
        "start_ring_rows": start_ring_rows,
        "start_ring_cols": start_ring_cols,
        "region_width": region_width,
        "ring_rows": ring_rows,
        "ring_cols": ring_cols,
        "region_rows": region_rows,
        "region_cols": region_cols,
        "current_era": current_era
    }

# Восстанавливает состояние мира/окна из сохранения.
# Вызывается ДО построения tile_data при загрузке.
func _apply_saved_map_state():
    var st: Dictionary = SaveManager.saved_data.get("map_state", {})
    if not st.is_empty():
        map_rows = int(st.get("map_rows", map_rows))
        map_cols = int(st.get("map_cols", map_cols))
        start_ring_rows = int(st.get("start_ring_rows", start_ring_rows))
        start_ring_cols = int(st.get("start_ring_cols", start_ring_cols))
        region_width = int(st.get("region_width", region_width))
        ring_rows = int(st.get("ring_rows", ring_rows))
        ring_cols = int(st.get("ring_cols", ring_cols))
        region_rows = int(st.get("region_rows", region_rows))
        region_cols = int(st.get("region_cols", region_cols))
        current_era = int(st.get("current_era", 0))
    city_row = map_rows / 2
    city_col = map_cols / 2
    _recalculate_bounds()

# --- ДЕБАГ: ОТКРЫТЬ ВСЮ КАРТУ ---
# Вся карта целиком становится Кольцом Влияния: все гексы помечаются
# как принадлежащие Кольцу и исследованные, границы Кольца/Региона
# расширяются до размеров всей карты. После этого можно строить/улучшать
# на любом гексе без разведки и покупки территории.
func debug_open_whole_map():
    if tile_data.is_empty():
        return

    # Помечаем каждый гекс как часть Кольца Влияния и исследованный.
    for row in range(map_rows):
        for col in range(map_cols):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            tile["in_influence"] = true
            tile["is_explored"] = true

    # Расширяем Кольцо и Регион до размеров всей карты — is_in_influence()
    # и is_valid_hex() будут возвращать true для любых координат.
    ring_rows = map_rows
    ring_cols = map_cols
    region_rows = map_rows
    region_cols = map_cols

    _recalculate_bounds()
    _calc_offsets()
    map_renderer.queue_redraw()

    if hud:
        hud.show_message("Дебаг: вся карта открыта и в Кольце Влияния (%d×%d)" % [map_rows, map_cols])

# --- ПЕРЕХОД В СЛЕДУЮЩУЮ ЭПОХУ ---
# Инфраструктура расширения мира:
#   1. Весь текущий (некупленный) Регион моментально и бесплатно исследуется.
#   2. Весь текущий Регион моментально и бесплатно покупается/присоединяется.
#   3. Бывшие Кольцо + Регион становятся новым Кольцом Влияния.
#   4. Вокруг нового Кольца формируется новый Регион той же ширины.
#   5. Гексы за пределами нового Кольца + Региона по-прежнему скрыты (туман войны).
func advance_to_next_era():
    if tile_data.is_empty():
        return

    # 1-2. Исследуем и присоединяем весь текущий Регион бесплатно.
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            tile["is_explored"] = true
            tile["in_influence"] = true

    # 3. Бывшие Кольцо + Регион становятся новым Кольцом.
    ring_rows = region_rows
    ring_cols = region_cols

    # 4. Новый Регион той же ширины вокруг нового Кольца.
    region_rows = ring_rows + region_width * 2
    region_cols = ring_cols + region_width * 2

    # 5. Пересчитываем границы; гексы нового Региона не исследованы и не в влиянии.
    _recalculate_bounds()
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if not is_in_influence(row, col):
                tile["in_influence"] = false
                tile["is_explored"] = false

    current_era += 1
    _calc_offsets()
    map_renderer.queue_redraw()
    if hud:
        hud.show_message("Новая эпоха! Границы города расширены. Кольцо влияния: %d×%d" % [ring_rows, ring_cols])

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
    _redraw_progress_layer()
    hud.show_message("Разведчики отправлены...")

func _complete_scouting():
    for hex in scouting_chunk:
        tile_data[hex.row][hex.col]["is_explored"] = true
    var info = _get_chunk_info(scouting_chunk)
    hud.show_message("Разведка завершена! %s" % info)
    is_scouting = false
    scouting_chunk = []
    map_renderer.queue_redraw()
    _redraw_progress_layer()

func _get_chunk_info(chunk: Array) -> String:
    return MapHelpers.get_chunk_info(chunk, tile_data)

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
    dialog.confirmed.connect(func():
        build_manager.cancel_build(row, col)
        # После отмены стройки прогресс-бар на гексе исчезает — перерисовываем
        # слой явно, т.к. если это была последняя активная стройка, _process
        # больше не будет вызывать queue_redraw() для слоя баров.
        _redraw_progress_layer()
    )
    add_child(dialog)
    dialog.popup_centered()
