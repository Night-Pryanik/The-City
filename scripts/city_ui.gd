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
@onready var top_food_label = $TabBarPanel/TopFoodLabel
@onready var message_label = $BottomPanel/MessageLabel

var active_tab = "resources"
var tab_buttons = []

var ui_helpers: Node
var resources_tab: Node
var buildings_tab: Node
var tech_tree: Control
var trade_tab: Node

var data_cache: Dictionary = {}

# Отслеживание структурных изменений для лёгкого обновления (тик)
var _cached_built_count: int = -1
var _cached_research_id: String = ""

# Тултипы (таймеры)
var food_hover_timer: float = 0.0
var build_hover_timer: float = 0.0
var building_detail_hover_timer: float = 0.0
const TOOLTIP_DELAY: float = 0.5

signal build_requested(building_id: String)
signal research_requested(tech_id: String)
signal closed()

var building_panel

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

func _on_city_data_updated():
    if visible:
        _refresh_light()

func _update_data_cache():
    data_cache = {
        "city_storage": CityData.city_storage,
        "city_quality_detail": CityData.city_quality_detail,
        "production_rates": CityData.production_rates,
        "production_sources": CityData.production_sources,
        "consumption_rates": CityData.consumption_rates,
        "consumption_sources": CityData.consumption_sources,
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
    # Полное обновление: пересоздаём списки (открытие города, структурные изменения)
    _update_data_cache()
    _cached_built_count = CityData.city_built_buildings.size()
    _cached_research_id = CityData.current_research_tech_id
    _refresh_all()

func _refresh_light():
    # Лёгкое обновление: обновляем значения без пересоздания узлов.
    # Это не сбрасывает тултипы (узлы, на которых висит курсор, сохраняются).
    if not visible:
        return
    _update_data_cache()

    if _needs_full_refresh():
        _cached_built_count = CityData.city_built_buildings.size()
        _cached_research_id = CityData.current_research_tech_id
        _refresh_all()
        return

    resources_tab.update_values()
    buildings_tab.update_built_status()
    # Прогресс исследования обновляем только когда вкладка Технологии
    # активна — иначе лишняя работа на каждом тике. Стоимость минимальна,
    # но привычка «не делать лишнего, если не нужно» важна.
    if active_tab == "technologies":
        tech_tree.update_progress()
    _update_food_label()

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
    _refresh_light()

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

    var food_str = "Еда: %d [+%d / -%d]" % [food_sum, total_prod, total_cons]
    var pop_str = "Население: %d (свободных: %d)" % [CityData.total_population, CityData.idle_population]

    if top_food_label:
        top_food_label.text = food_str + " | " + pop_str

    # Обновляем метку еды на вкладке «Здания» (без населения)
    if buildings_tab.has_method("update_food_label"):
        buildings_tab.update_food_label()

    # Дополнительные ресурсы теперь отображаются в панели деталей здания

func update_food_label():
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
    if buildings_panel.visible and buildings_tab.has_method("get_hovered_button"):
        var hov_btn = buildings_tab.get_hovered_button()
        if hov_btn and hov_btn.get_global_rect().has_point(mouse_pos):
            hovered_detail = true
    if hovered_detail:
        building_detail_hover_timer += delta
        if building_detail_hover_timer >= TOOLTIP_DELAY:
            ui_helpers.show_building_detail_tooltip(mouse_pos)
    else:
        building_detail_hover_timer = 0.0
        ui_helpers.hide_building_detail_tooltip()

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
