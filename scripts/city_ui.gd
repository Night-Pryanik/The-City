# city_ui.gd
extends Control

# Вкладки (панели)
@onready var resources_panel = $ContentPanel/ResourcesPanel
@onready var buildings_panel = $ContentPanel/BuildingsPanel
@onready var trade_panel = $ContentPanel/TradePanel
@onready var technologies_panel = $ContentPanel/TechnologiesPanel

# Кнопки вкладок
@onready var resources_tab_button = $TabBarPanel/TabBar/ResourcesTabButton
@onready var buildings_tab_button = $TabBarPanel/TabBar/BuildingsTabButton
@onready var trade_tab_button = $TabBarPanel/TabBar/TradeTabButton
@onready var technologies_tab_button = $TabBarPanel/TabBar/TechnologiesTabButton
@onready var close_button_top = $CloseButtonTop

# Верхняя полоса
# TopFoodLabel — контейнер HBox с тремя дочерними метками: еда / население /
# казна. Казна — отдельная метка с ховером, потому что тултип нужен только
# на ней (разбивка по источникам дохода/расхода казны).
@onready var top_food_label = $TabBarPanel/TopFoodLabel
@onready var top_food_value_label = $TabBarPanel/TopFoodLabel/FoodLabel
@onready var top_pop_value_label = $TabBarPanel/TopFoodLabel/PopLabel
@onready var top_treasury_value_label = $TabBarPanel/TopFoodLabel/TreasuryLabel
@onready var message_label = $BottomPanel/MessageLabel

# Состояние ховера на «Казна: N» в верхней полосе города. Снимок источников
# дохода/расхода обновляется раз в ресурсную эпоху через _refresh_light, чтобы
# счётчик «/сек» не мельтешил каждый тик.
var _treasury_display_epoch: int = -1
# Кеш значения казны, показываемого в TopFoodLabel и в тултипе разбивки.
# Оба потребителя ОБЯЗАНЫ показывать одно и то же значение: CityData.treasury
# меняется каждым тиком потребления, а TopFoodLabel обновляется с интервалом
# из настроек (см. _refresh_light). Кеш обновляется в _update_food_label
# (рядом с записью в TopFoodLabel); тултип читает кеш, не CityData напрямую.
var _displayed_treasury: int = 0

var active_tab = "resources"
var tab_buttons = []

var ui_helpers: Node
var worker_manager: Node # прокидывается из main_map (см. set_worker_manager)
var resources_tab: Node
var buildings_tab: Node
var tech_tree: Control
var trade_tab: Node

var data_cache: Dictionary = {}

# Последняя «эпоха» отображения ресурсов (см. CityData.resource_display_interval):
# значения вкладки «Ресурсы» и верхней строки города обновляются только когда
# эпоха изменилась, а не каждым тиком. Событийные пути (refresh при открытии,
# refresh_light по смене назначений, update_food_label по тумблеру еды)
# обновляются мгновенно и синхронизируют эпоху.
var _display_epoch: int = -1

# Отслеживание структурных изменений для лёгкого обновления (тик)
var _cached_built_count: int = -1
var _cached_research_id: String = ""

# Тултипы (таймеры)
var food_hover_timer: float = 0.0
var build_hover_timer: float = 0.0
var building_detail_hover_timer: float = 0.0
var building_detail_leave_timer: float = 0.0
var building_detail_locked: bool = false
var building_detail_locked_id: String = ""
var building_detail_delay: float = 0.5
# Ховер-таймер для тултипа разбивки казны (см. _process).
var treasury_hover_timer: float = 0.0
# Таймер grace при уходе курсора с метки/тултипа казны — защищает от
# мерцания при переходе курсора с метки на тултип и обратно (как в тултипе
# деталей здания, см. BUILDING_DETAIL_LEAVE_GRACE).
var treasury_hover_leave_timer: float = 0.0
const TOOLTIP_DELAY: float = 0.5
const BUILDING_DETAIL_LEAVE_GRACE: float = 0.35

signal build_requested(building_id: String)
signal research_requested(tech_id: String)
signal closed()

var building_panel

# Кэш ссылки на BuildManager для подключения сигналов завершения строительства
var _cached_build_manager = null

func set_building_detail_delay(value: float):
    building_detail_delay = maxf(0.0, value)

# Прокидывает WorkerManager (из main_map) в городские вкладки: вкладке
# «Ресурсы» он нужен для расчёта планового потребления (тултип ресурсов
# и динамика с маркером «≈», см. resources_tab.gd).
func set_worker_manager(wm: Node):
    worker_manager = wm
    if resources_tab != null:
        resources_tab.set_worker_manager(wm)

func _ready():
    # Загружаем модули
    ui_helpers = load("res://scripts/ui_helpers.gd").new()
    ui_helpers.setup(self, message_label)
    add_child(ui_helpers)

    # Иконки кнопок вкладок (левый верхний угол) и раскладка панелей на всю
    # ширину окна. CityUi имеет anchors_preset=0 и размер 0×0 (как в
    # оригинальной сцене), поэтому панели позиционируются вручную, а при
    # изменении размера окна раскладка пересчитывается заново.
    _setup_tab_bar_icons()
    _layout_ui()
    get_viewport().size_changed.connect(_layout_ui)

    resources_tab = load("res://scripts/resources_tab.gd").new()
    resources_tab.setup($ContentPanel/ResourcesPanel/ScrollContainer/ResourcesList, ui_helpers)
    add_child(resources_tab)

    buildings_tab = load("res://scripts/buildings_tab.gd").new()
    buildings_tab.setup(
        $ContentPanel/BuildingsPanel/PanelsLayout/AvailableBuildingsPanel/VBoxContainer/AvailableBuildingsScroll/BuildingsList,
        $ContentPanel/BuildingsPanel/BuildButton,
        $RightPanel/VBoxContainer/BuiltBuildingsList,
        $ContentPanel/BuildingsPanel/FoodLabel,
        ui_helpers
    )
    buildings_tab.build_requested.connect(_on_build_requested)
    buildings_tab.building_detail_requested.connect(_on_building_detail_requested)
    add_child(buildings_tab)

    building_panel = load("res://scripts/building_panel.gd").new()
    add_child(building_panel)
    building_panel.hide()

    # Дерево технологий в стиле Civ: горизонтальная прокрутка, вертикальные
    # колонки по «слоям зависимостей», стрелки от предка к наследнику.
    # Создаём отдельный Control внутри TreeRoot, чтобы он заполнил панель.
    tech_tree = load("res://scripts/tech_tree.gd").new()
    tech_tree.setup(
        $ContentPanel/TechnologiesPanel/TreeRoot,
        $ContentPanel/TechnologiesPanel/CurrentResearch/VBoxContainer/TechCurrentLabel,
        $ContentPanel/TechnologiesPanel/CurrentResearch/VBoxContainer/SciencePoolLabel
    )
    tech_tree.research_requested.connect(_on_research_requested)
    $ContentPanel/TechnologiesPanel/TreeRoot.add_child(tech_tree)

    trade_tab = load("res://scripts/trade_tab.gd").new()
    add_child(trade_tab)

    # Сигналы кнопок
    for btn in [resources_tab_button, buildings_tab_button, trade_tab_button, technologies_tab_button]:
        if not btn.pressed.is_connected(_on_tab_button_pressed):
            btn.pressed.connect(_on_tab_button_pressed.bind(btn))
    if not close_button_top.pressed.is_connected(_on_close_pressed):
        close_button_top.pressed.connect(_on_close_pressed)

    # Прозрачность панелей
    $TabBarPanel.self_modulate = Color(1, 1, 1, 0.8)
    $RightPanel.self_modulate = Color(1, 1, 1, 0.8)
    $ContentPanel.self_modulate = Color(1, 1, 1, 0.8)
    $BottomPanel.self_modulate = Color(1, 1, 1, 0.8)

    tab_buttons = [
        {"button": resources_tab_button, "id": "resources"},
        {"button": buildings_tab_button, "id": "buildings"},
        {"button": trade_tab_button, "id": "trade"},
        {"button": technologies_tab_button, "id": "technologies"}
    ]
    _highlight_active_tab_button()

    if not CityData.city_updated.is_connected(_on_city_data_updated):
        CityData.city_updated.connect(_on_city_data_updated)

    # Начальное значение кеша казны — первое же открытие тултипа должно
    # показать актуальную казну, а не «0» из дефолта. Дальше кеш обновляется
    # в _update_food_label на каждой ресурсной эпохе.
    _displayed_treasury = CityData.treasury

    # Ховер на метке «Казна: N» в верхней полосе — показ тултипа разбивки
    # казны по источникам дохода/расхода. Подход polling + grace-таймер
    # (см. building_detail_tooltip ниже) — он работает независимо от
    # mouse_filter и сам корректно «переживает» переход курсора с метки на
    # тултип.

    # Казна в верхней полосе города обновляется через тиковый путь
    # (city_updated → _refresh_light) с проверкой эпохи отображения ресурсов —
    # синхронно с остальной верхней строкой и ресурсами вкладки «Ресурсы».
    # Прямой сигнал treasury_changed здесь не нужен: доход внутреннего рынка
    # меняет казну каждый тик, и без сдерживания верхняя полоса обновлялась
    # бы каждый тик (мельтешение значений).

    # Население в верхней строке города («… | Население: N …») обновляется по
    # событию (рост/гибель), не дожидаясь интервала отображения ресурсов.
    if not CityData.population_changed.is_connected(_on_population_changed_label):
        CityData.population_changed.connect(_on_population_changed_label)

    # Подключаем сигнал завершения строительства здания для показа сообщения
    # в нижней панели CityUI (build_message сигнал выводит в HUD карты,
    # который скрыт, когда открыт интерфейс города).
    var bm = _get_build_manager()
    if bm and not bm.build_building_completed.is_connected(_on_building_build_completed):
        bm.build_building_completed.connect(_on_building_build_completed)

func _get_build_manager():
    if _cached_build_manager == null or not is_instance_valid(_cached_build_manager):
        var main_map = get_tree().root.find_child("MainMap", true, false)
        _cached_build_manager = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
    return _cached_build_manager

# Обработчик завершения строительства здания: показывает сообщение
# "Строительство <здание> завершено" в нижней панели CityUI.
func _on_building_build_completed(building_id: String, build_key: String):
    if ui_helpers and visible:
        var building_name = CityData.get_building_name(building_id)
        ui_helpers.set_message("Строительство %s завершено" % building_name)

func _on_city_data_updated():
    if visible:
        _refresh_light()

func _update_data_cache():
    data_cache = {
        "city_storage": CityData.city_storage,
        "city_quality_detail": CityData.city_quality_detail,
        "production_rates": CityData.production_rates,
        "consumption_rates": CityData.consumption_rates,
        "city_food_pool": CityData.city_food_pool,
        "buildings_data": GameData.buildings,
        "crafts_data": GameData.crafts,
        "built_buildings": CityData.city_built_buildings,
        "products": GameData.products,
        "raw_resources": GameData.raw_resources,
        "categories": GameData.categories,
    }
    resources_tab.update_data(data_cache)
    buildings_tab.update_data(data_cache)

func refresh():
    # Полное обновление: пересоздаём списки (открытие города, структурные изменения).
    # Это событие (игрок открыл город / построено здание) — обновляем всё сразу
    # и синхронизируем эпоху отображения ресурсов.
    _update_data_cache()
    _cached_built_count = CityData.city_built_buildings.size()
    _cached_research_id = CityData.current_research_tech_id
    _refresh_all()
    _display_epoch = CityData.resource_display_epoch

func _refresh_light(force_resources := false):
    # Лёгкое обновление: обновляем значения без пересоздания узлов.
    # Это не сбрасывает тултипы (узлы, на которых висит курсор, сохраняются).
    #
    # Значения ресурсов (запас, динамика, качество) и верхняя строка «Еда: N»
    # обновляются с интервалом из настроек (CityData.resource_display_interval):
    # тиковый путь (city_updated) ждёт наступления эпохи, событийные пути
    # (force_resources=true) обновляются мгновенно.
    if not visible:
        return
    _update_data_cache()

    if _needs_full_refresh():
        # Структурные изменения (новое здание, начало/завершение исследования) —
        # событие: обновляем сразу, включая значения ресурсов, и синхронизируем
        # эпоху отображения.
        _cached_built_count = CityData.city_built_buildings.size()
        _cached_research_id = CityData.current_research_tech_id
        _refresh_all()
        _display_epoch = CityData.resource_display_epoch
        return

    if force_resources or CityData.resource_display_due(_display_epoch):
        _display_epoch = CityData.resource_display_epoch
        resources_tab.update_values()
        _update_food_label()
        # На смене ресурсной эпохи обновляем открытый тултип разбивки казны
        # свежими данными (плановый доход пересчитан, снимок расходов
        # обновлён, см. CityData.tick_resource_display → rotate_treasury_window).
        if ui_helpers and is_instance_valid(ui_helpers) \
                and ui_helpers.treasury_tooltip_panel \
                and ui_helpers.treasury_tooltip_panel.visible:
            _show_treasury_tooltip(get_viewport().get_mouse_position())
            _treasury_display_epoch = CityData.resource_display_epoch
    buildings_tab.update_built_status()
    # Прогресс исследования обновляем только когда вкладка Технологии
    # активна — иначе лишняя работа на каждом тике. Стоимость минимальна,
    # но привычка «не делать лишнего, если не нужно» важна.
    if active_tab == "technologies":
        tech_tree.update_progress()

func _needs_full_refresh() -> bool:
    # Полное обновление требуется только при структурных изменениях:
    # постройка здания или начало/завершение исследования.
    if CityData.city_built_buildings.size() != _cached_built_count:
        return true
    if CityData.current_research_tech_id != _cached_research_id:
        return true
    return false

func show_resources_tab():
    _switch_tab("resources")

func show_technologies_tab():
    _switch_tab("technologies")

func refresh_light():
    # Публичный метод для лёгкого обновления при изменении назначений.
    # Смена назначений — действие игрока: значения ресурсов обновляются
    # мгновенно, не дожидаясь интервала отображения (force_resources=true).
    _refresh_light(true)

func _refresh_all():
    resources_tab.refresh()
    buildings_tab.refresh_built()
    tech_tree.refresh()
    _update_food_label()

func _switch_tab(tab_id: String):
    active_tab = tab_id
    resources_panel.visible = (tab_id == "resources")
    buildings_panel.visible = (tab_id == "buildings")
    trade_panel.visible = (tab_id == "trade")
    technologies_panel.visible = (tab_id == "technologies")

    # Правая панель «Построенные здания» показывается только на вкладках
    # «Ресурсы» и «Здания» (когда окно делится поровну); на «Торговле» и
    # «Технологиях» контент занимает всю ширину окна. Расчёт смещений — в
    # общем _layout_ui().
    _layout_ui()

    if ui_helpers:
        ui_helpers.hide_group_tooltip()
        ui_helpers.hide_progress_tooltip()
        ui_helpers.hide_quality_tooltip()
        ui_helpers.hide_built_tooltip()

    if tab_id == "buildings":
        buildings_tab.refresh_list()
    elif tab_id == "technologies":
        tech_tree.refresh()

    ui_helpers.set_message("")
    _highlight_active_tab_button()
    _update_food_label()

func _on_tab_button_pressed(btn: Button):
    for tab in tab_buttons:
        if tab["button"] == btn:
            _switch_tab(tab["id"])
            break

func _on_close_pressed():
    _close_ui()

func _highlight_active_tab_button():
    var active_style = StyleBoxFlat.new()
    active_style.bg_color = Color(0.784, 0.784, 0.784, 1.0)
    var inactive_style = StyleBoxFlat.new()
    inactive_style.bg_color = Color(0.471, 0.471, 0.471, 0.3)

    for tab in tab_buttons:
        var btn: Button = tab["button"]
        if tab["id"] == active_tab:
            btn.add_theme_stylebox_override("normal", active_style)
            btn.add_theme_color_override("font_color", Color.BLACK)
        else:
            btn.add_theme_stylebox_override("normal", inactive_style)
            btn.add_theme_color_override("font_color", Color.WHITE)

func _update_food_label():
    var pool = resources_tab.get_food_pool()
    var storage = resources_tab.city_storage
    var prod_rates = resources_tab.get_production_rates()
    var cons_rates = resources_tab.get_consumption_rates()

    var food_sum = 0
    var total_prod = 0
    var total_cons = 0
    for pid in pool:
        if pool[pid]:
            food_sum += storage.get(pid, 0)
            total_prod += prod_rates.get(pid, 0)
            total_cons += cons_rates.get(pid, 0)

    # Циклические производства/потребления (улучшения с production_interval,
    # профессии с интервалом) выдают/списывают еду «пачками», поэтому в тик
    # без события факт равен 0. Чтобы метка не мигала «+0», при нулевом факте
    # показываем среднюю скорость из плановых карт (как динамика «≈» на
    # вкладке «Ресурсы»).
    var prod_mark := ""
    var cons_mark := ""
    if total_prod <= 0:
        total_prod = _planned_food_per_sec(resources_tab.planned_production_map, pool)
        if total_prod > 0:
            prod_mark = "≈"
    if total_cons <= 0:
        total_cons = _planned_food_per_sec(resources_tab.planned_consumption_map, pool)
        if total_cons > 0:
            cons_mark = "≈"

    var food_str = "Еда: %d [+%d%s / -%d%s]" % [food_sum, total_prod, prod_mark, total_cons, cons_mark]
    var pop_str = "Население: %d (свободных: %d)" % [CityData.total_population, CityData.idle_population]
    # Захватываем значение казны в кеш — этот же кеш читает тултип разбивки
    # казны (см. _show_treasury_tooltip). Синхронизация важна, иначе при
    # интервале отображения > 1 сек метка TopFoodLabel показывает старое
    # значение, а тултип — каждый тик свежее (визуальный регресс «убегает
    # вперёд», см. developer_diary).
    _displayed_treasury = CityData.treasury
    var treasury_str = "Казна: %d" % _displayed_treasury

    # TopFoodLabel — HBoxContainer с тремя дочерними метками
    # (FoodLabel/PopLabel/TreasuryLabel), см. сцену CityUI.tscn. Разделитель
    # «|» рисуется между ними отдельной меткой в сцене.
    if top_food_value_label:
        top_food_value_label.text = food_str
    if top_pop_value_label:
        top_pop_value_label.text = pop_str
    if top_treasury_value_label:
        top_treasury_value_label.text = treasury_str

# Курсор сейчас над меткой казны или над активным тултипом разбивки казны.
    # Если да — тултип удерживается открытым, ухода с grace-таймером не
    # происходит (это нужно, чтобы при переходе курсора с метки на тултип
    # тултип не моргал). Аналогично логике building_detail_tooltip ниже.
func _is_treasury_hovered(mouse_pos: Vector2) -> bool:
    if not visible:
        return false
    if top_treasury_value_label and top_treasury_value_label.get_global_rect().has_point(mouse_pos):
        return true
    if ui_helpers and is_instance_valid(ui_helpers) \
            and ui_helpers.treasury_tooltip_panel \
            and ui_helpers.treasury_tooltip_panel.visible \
            and ui_helpers.treasury_tooltip_panel.get_global_rect().has_point(mouse_pos):
        return true
    return false

# Показывает тултип разбивки казны под курсором. Данные — из worker_manager
    # (плановый доход по источникам) и CityData (снимок расходов за окно).
    # Вызывается из _process по истечении TOOLTIP_DELAY и при смене эпохи
    # отображения ресурсов (см. _refresh_light).
func _show_treasury_tooltip(mouse_pos: Vector2):
    if not (ui_helpers and is_instance_valid(ui_helpers) and worker_manager):
        return
    var planned_income: Dictionary = {}
    if worker_manager.has_method("get_planned_treasury_income_map"):
        planned_income = worker_manager.get_planned_treasury_income_map()
    # Берём _displayed_treasury (кеш TopFoodLabel), а не CityData.treasury —
    # иначе в тултипе будет видно «свежее» значение казны, обгоняющее метку
    # TopFoodLabel на 1+ тиков потребления (см. developer_diary).
    ui_helpers.show_treasury_tooltip(
        mouse_pos,
        _displayed_treasury,
        planned_income,
        CityData.treasury_expense_snapshot,
        CityData.treasury_window_length_sec
    )

# Суммарная посекундная скорость записей плана (производства или потребления)
# по продуктам из пула еды. Формат карт — product_id -> { источник -> { amount,
# interval, ... } }; interval = 0 — «за тик» (tick = SIMULATION_TICK = 1 сек).
func _planned_food_per_sec(map: Dictionary, pool: Dictionary) -> int:
    var total := 0.0
    for pid in pool:
        if not pool[pid]:
            continue
        for source_name in map.get(pid, {}):
            var entry: Dictionary = map[pid][source_name]
            var amount = float(entry.get("amount", 0))
            var interval = float(entry.get("interval", 0))
            if interval > 0.0:
                total += amount * CityData.SIMULATION_TICK / interval
            else:
                total += amount
    return int(round(total))

    # Обновляем метку еды на вкладке «Здания» (без населения)
    if buildings_tab.has_method("update_food_label"):
        buildings_tab.update_food_label()

    # Дополнительные ресурсы теперь отображаются в панели деталей здания

func update_food_label():
    _update_food_label()

# Население изменилось (рост/гибель) — верхняя строка города показывает его
# рядом с едой и казной; обновляем сразу, мимо интервала отображения ресурсов.
func _on_population_changed_label(_new_pop: int):
    _update_food_label()

func refresh_buildings_tab():
    if buildings_tab and buildings_tab.has_method("refresh_built"):
        buildings_tab.refresh_built()

func _on_build_requested(building_id: String):
    emit_signal("build_requested", building_id)

func _on_building_detail_requested(building_id: String):
    var panel_data = data_cache.duplicate()
    panel_data["ui_helpers"] = ui_helpers
    building_panel.open(building_id, panel_data)

func _on_research_requested(tech_id: String):
    emit_signal("research_requested", tech_id)

func _process(delta):
    var mouse_pos = get_viewport().get_mouse_position()

    # Тултип для переключателей еды (только на вкладке «Ресурсы» — иначе
    # скрытые тумблеры «просачиваются» в другие вкладки через get_global_rect,
    # который возвращает координаты даже у скрытых панелей).
    var hovered_food = false
    if resources_panel.visible:
        for pid in resources_tab.get_food_toggles():
            var toggle = resources_tab.get_food_toggles()[pid]
            if toggle.is_visible_in_tree() and toggle.get_global_rect().has_point(mouse_pos):
                hovered_food = true
                break

    if hovered_food:
        food_hover_timer += delta
        if food_hover_timer >= TOOLTIP_DELAY:
            ui_helpers.show_food_tooltip(mouse_pos)
            ui_helpers.tooltip_panel.visible = true
    else:
        food_hover_timer = 0.0
        ui_helpers.tooltip_panel.visible = false

    # Тултип для кнопки "Построить"
    var hovered_build = false
    if buildings_panel.visible and buildings_tab.build_button:
        if buildings_tab.build_button.get_global_rect().has_point(mouse_pos):
            hovered_build = true

    if hovered_build:
        build_hover_timer += delta
        if build_hover_timer >= TOOLTIP_DELAY:
            var hint = ""
            if buildings_tab.selected_building_id == "":
                hint = "Не выбрано здание"
            else:
                var bdata = null
                for b in data_cache.get("buildings_data", []):
                    if b["id"] == buildings_tab.selected_building_id:
                        bdata = b
                        break
                if bdata:
                    var work_cost = bdata.get("work_cost", 0)
                    if work_cost > 0:
                        work_cost = int(ceil(float(work_cost) * MapHelpers.get_construction_cost_mult()))
                    var labor = CityData.get_total_labor()
                    if work_cost > 0:
                        var build_time = work_cost / max(1.0, labor)
                        hint = "Строительство: %d труда, %.0f сек.\n" % [work_cost, build_time]
                        hint += "Доступный труд: %.0f/сек (%d жителей)" % [labor, CityData.total_population]
                    else:
                        hint = "Построить мгновенно (бесплатно)"
                    # Информация о лимите одновременных строек (здания + улучшения).
                    # Лимит равен общему числу жителей.
                    var construction_count = CityData.building_construction.size()
                    var main_map = get_tree().root.find_child("MainMap", true, false)
                    var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
                    if bm:
                        construction_count = bm.get_total_active_builds()
                    var construction_limit = CityData.total_population
                    if construction_count >= construction_limit:
                        hint += "\nЛимит одновременных строек достигнут (%d/%d, лимит = число жителей)" % [construction_count, construction_limit]
                    elif construction_count > 0:
                        hint += "\nСтроек: %d/%d (лимит = число жителей)" % [construction_count, construction_limit]
            if hint != "":
                ui_helpers.build_tooltip_label.text = hint
                ui_helpers.show_build_tooltip(mouse_pos)
                ui_helpers.build_tooltip_panel.visible = true
            else:
                ui_helpers.build_tooltip_panel.visible = false
    else:
        build_hover_timer = 0.0
        ui_helpers.build_tooltip_panel.visible = false

    # Тултип для прогресс-баров строящихся зданий (обновляется в реальном времени)
    var hovered_bar = {}
    if buildings_panel.visible:
        hovered_bar = buildings_tab.get_hovered_construction_bar(mouse_pos)
    if not hovered_bar.is_empty():
        var status_text = hovered_bar.get("status_text", "Строится")
        var percent = hovered_bar.get("percent", 0.0)
        ui_helpers.progress_tooltip_label.text = "%s: %.0f%%" % [status_text, percent]
        ui_helpers.show_progress_tooltip(mouse_pos)
        ui_helpers.progress_tooltip_panel.visible = true
    else:
        ui_helpers.hide_progress_tooltip()

    # Тултип деталей здания (вкладка «Здания»): показываем при наведении
    # на любую кнопку здания; содержимое собирается в buildings_tab.
    var hovered_detail = false
    var hovered_detail_button = false
    if buildings_panel.visible and buildings_tab.has_method("get_hovered_button"):
        var hov_btn = buildings_tab.get_hovered_button()
        if hov_btn and hov_btn.get_global_rect().has_point(mouse_pos):
            hovered_detail = true
            hovered_detail_button = true
            if building_detail_locked \
                    and buildings_tab.get_hovered_building_id() != building_detail_locked_id:
                building_detail_locked = false
                building_detail_locked_id = ""
                building_detail_hover_timer = 0.0
                ui_helpers.hide_building_detail_tooltip()
    if ui_helpers.detail_tooltip_panel.visible \
            and ui_helpers.detail_tooltip_panel.get_global_rect().has_point(mouse_pos):
        hovered_detail = true
    if hovered_detail:
        building_detail_leave_timer = 0.0
        if hovered_detail_button and not building_detail_locked:
            building_detail_hover_timer += delta
        if hovered_detail_button and not building_detail_locked \
            and building_detail_hover_timer >= building_detail_delay:
            ui_helpers.show_building_detail_tooltip(mouse_pos)
            building_detail_locked = true
            building_detail_locked_id = buildings_tab.get_hovered_building_id()
    else:
        if building_detail_locked:
            building_detail_leave_timer += delta
            if building_detail_leave_timer < BUILDING_DETAIL_LEAVE_GRACE:
                return
        building_detail_hover_timer = 0.0
        building_detail_leave_timer = 0.0
        building_detail_locked = false
        building_detail_locked_id = ""
        ui_helpers.hide_building_detail_tooltip()

    # Тултип разбивки казны по источникам дохода/расхода: polling + grace
    # (по образцу тултипа деталей здания выше). Задержка та же TOOLTIP_DELAY.
    # live-update контента в реальном времени делается в _refresh_light — там
    # пересчитываем тултип на смене ресурсной эпохи, если он видим.
    if _is_treasury_hovered(mouse_pos):
        treasury_hover_leave_timer = 0.0
        treasury_hover_timer += delta
        if treasury_hover_timer >= TOOLTIP_DELAY:
            _show_treasury_tooltip(mouse_pos)
    else:
        treasury_hover_timer = 0.0
        if ui_helpers and is_instance_valid(ui_helpers) \
                and ui_helpers.treasury_tooltip_panel \
                and ui_helpers.treasury_tooltip_panel.visible:
            treasury_hover_leave_timer += delta
            if treasury_hover_leave_timer >= BUILDING_DETAIL_LEAVE_GRACE:
                ui_helpers.hide_treasury_tooltip()
                treasury_hover_leave_timer = 0.0

func set_message(text: String):
    if ui_helpers:
        ui_helpers.set_message(text)

func _input(event: InputEvent):
    if not visible:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        var click_pos = event.global_position

        # Если панель здания открыта — её обработчик уже закрыл её, выходим
        if building_panel and building_panel.visible:
            return

        var hovered_control = get_viewport().gui_get_hovered_control()
        if is_instance_valid(hovered_control) and hovered_control != self:
            if hovered_control.get_global_rect().has_point(click_pos):
                return

        var hit_panel = false
        for panel in [$TabBarPanel, $TabBar, $RightPanel, $ContentPanel, $BottomPanel, $CloseButtonTop]:
            if panel.get_global_rect().has_point(click_pos):
                hit_panel = true
                break
        if not hit_panel and building_panel and building_panel.visible:
            if building_panel.get_global_rect().has_point(click_pos):
                hit_panel = true
        if not hit_panel:
            _close_ui()

func _close_ui():
    ui_helpers.set_message("")
    if ui_helpers:
        ui_helpers.hide_group_tooltip()
        ui_helpers.hide_progress_tooltip()
        ui_helpers.hide_quality_tooltip()
        ui_helpers.hide_building_detail_tooltip()
        ui_helpers.hide_flow_tooltip()
        ui_helpers.hide_built_tooltip()
    if building_panel:
        building_panel.hide()
    hide()
    emit_signal("closed")

func close_city():
    _close_ui()

func _position_close_button_top() -> void:
    # Закрепляет CloseButtonTop в правом верхнем углу viewport. Сделано
    # вручную, потому что CityUi имеет anchors_preset=0 (размер 0×0) и
    # anchor_right=1.0 у кнопки не дал бы привязки к краю экрана.
    if close_button_top == null:
        return
    var w: float = get_viewport_rect().size.x
    close_button_top.anchor_left = 0
    close_button_top.anchor_top = 0
    close_button_top.anchor_right = 0
    close_button_top.anchor_bottom = 0
    close_button_top.size = Vector2(37, 31)
    close_button_top.position = Vector2(w - 37, 0)

func _setup_tab_bar_icons() -> void:
    # Иконки для маленьких кнопок вкладок в левом верхнем углу.
    var icons = {
        resources_tab_button: "res://icons/resources/products/bread.png",
        buildings_tab_button: "res://icons/buildings/market.png",
        trade_tab_button: "res://icons/resources/products/pottery.png",
        technologies_tab_button: "res://icons/tech/wheel.png"
    }
    for btn in icons:
        if btn == null:
            continue
        var tex = load(icons[btn])
        if tex:
            btn.icon = tex
            btn.expand_icon = true
            btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
            btn.add_theme_constant_override("icon_max_width", 32)
            btn.add_theme_constant_override("icon_max_height", 32)

func _layout_ui() -> void:
    # Раскладка панелей интерфейса города на всю ширину окна.
    var w: float = get_viewport_rect().size.x
    var h: float = get_viewport_rect().size.y

    # Вкладки — слева сверху в верхней полосе на всю ширину окна.
    var tab_bar_panel = $TabBarPanel
    if tab_bar_panel:
        tab_bar_panel.offset_left = 0
        tab_bar_panel.offset_right = w
        tab_bar_panel.offset_top = 0.0
        tab_bar_panel.offset_bottom = 50.0
    var tab_bar = $TabBarPanel/TabBar
    if tab_bar:
        tab_bar.position = Vector2(8, 8)

    # Нижняя панель сообщений — на всю ширину окна.
    $BottomPanel.offset_left = 0
    $BottomPanel.offset_right = w
    $BottomPanel.offset_top = h - 50.0
    $BottomPanel.offset_bottom = h

    # Правая панель «Построенные здания» — на вкладках «Ресурсы» и «Здания»
    # (окно делится на две равные части), на остальных вкладках скрыта.
    var show_right: bool = (active_tab == "resources" or active_tab == "buildings")
    if $RightPanel.visible != show_right:
        $RightPanel.visible = show_right
    $ContentPanel.offset_left = 0
    if show_right:
        var half: float = w / 2.0
        $ContentPanel.offset_right = half
        $ContentPanel.offset_top = 50.0
        $ContentPanel.offset_bottom = h - 50.0
        $RightPanel.offset_left = half
        $RightPanel.offset_right = w
        $RightPanel.offset_top = 50.0
        $RightPanel.offset_bottom = h
    else:
        $ContentPanel.offset_right = w
        $ContentPanel.offset_top = 50.0
        $ContentPanel.offset_bottom = h - 50.0

    # Кнопка закрытия — в правом верхнем углу поверх всего.
    _position_close_button_top()
