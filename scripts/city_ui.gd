# city_ui.gd
extends Control

# Вкладки (панели)
@onready var resources_panel = $ContentPanel/ResourcesPanel
@onready var buildings_panel = $ContentPanel/BuildingsPanel
@onready var trade_panel = $ContentPanel/TradePanel
@onready var technologies_panel = $ContentPanel/TechnologiesPanel

# Кнопки вкладок
@onready var resources_tab_button = $LeftPanel/ResourcesTabButton
@onready var buildings_tab_button = $LeftPanel/BuildingsTabButton
@onready var trade_tab_button = $LeftPanel/TradeTabButton
@onready var technologies_tab_button = $LeftPanel/TechnologiesTabButton
@onready var close_button = $BottomPanel/CloseButton
@onready var close_button_top = $RightPanel/CloseButtonTop

# Верхняя панель
@onready var top_food_label = $TopPanel/TopFoodLabel
@onready var message_label = $BottomPanel/MessageLabel

var active_tab = "resources"
var tab_buttons = []

var ui_helpers: Node
var resources_tab: Node
var buildings_tab: Node
var technologies_tab: Node
var trade_tab: Node

var data_cache: Dictionary = {}

# Тултипы (таймеры)
var food_hover_timer: float = 0.0
var build_hover_timer: float = 0.0
const TOOLTIP_DELAY: float = 0.5

signal build_requested(building_id: String)
signal research_requested(tech_id: String)
signal closed()

func _ready():
    # Загружаем модули
    ui_helpers = load("res://scripts/ui_helpers.gd").new()
    ui_helpers.setup(self, message_label)
    add_child(ui_helpers)

    resources_tab = load("res://scripts/resources_tab.gd").new()
    resources_tab.setup($ContentPanel/ResourcesPanel/ScrollContainer/ResourcesList, ui_helpers)
    add_child(resources_tab)

    buildings_tab = load("res://scripts/buildings_tab.gd").new()
    buildings_tab.setup(
        $ContentPanel/BuildingsPanel/HSplitContainer/AvailableBuildingsPanel/VBoxContainer/BuildingsItemList,
        $ContentPanel/BuildingsPanel/HSplitContainer/BuildingDetailsPanel/VBoxContainer/BuildingNameLabel,
        $ContentPanel/BuildingsPanel/HSplitContainer/BuildingDetailsPanel/VBoxContainer/BuildingCostLabel,
        $ContentPanel/BuildingsPanel/HSplitContainer/BuildingDetailsPanel/VBoxContainer/BuildingRecipesLabel,
        $ContentPanel/BuildingsPanel/BuildButton,
        $RightPanel/VBoxContainer/BuiltBuildingsList,
        $ContentPanel/BuildingsPanel/FoodLabel,
        $ContentPanel/BuildingsPanel/HSplitContainer,
        ui_helpers
    )
    buildings_tab.build_requested.connect(_on_build_requested)
    add_child(buildings_tab)

    technologies_tab = load("res://scripts/technologies_tab.gd").new()
    technologies_tab.setup(
        $ContentPanel/TechnologiesPanel/CurrentResearch/VBoxContainer/TechCurrentLabel,
        $ContentPanel/TechnologiesPanel/CurrentResearch/VBoxContainer/TechProgressBar,
        $ContentPanel/TechnologiesPanel/ScrollContainer/AvailableTechList,
        $ContentPanel/TechnologiesPanel/UnlockedContainer/UnlockedTechList
    )
    technologies_tab.research_requested.connect(_on_research_requested)
    add_child(technologies_tab)

    trade_tab = load("res://scripts/trade_tab.gd").new()
    add_child(trade_tab)

    # Сигналы кнопок
    for btn in [resources_tab_button, buildings_tab_button, trade_tab_button, technologies_tab_button]:
        if not btn.pressed.is_connected(_on_tab_button_pressed):
            btn.pressed.connect(_on_tab_button_pressed.bind(btn))
    if not close_button.pressed.is_connected(_on_close_pressed):
        close_button.pressed.connect(_on_close_pressed)
    if not close_button_top.pressed.is_connected(_on_close_pressed):
        close_button_top.pressed.connect(_on_close_pressed)

    # Прозрачность панелей
    $LeftPanel.self_modulate = Color(1, 1, 1, 0.5)
    $TopPanel.self_modulate = Color(1, 1, 1, 0.8)
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

func update_data(storage, prod_rates, cons_rates, food_pool, blds_data, cfts_data, built_blds, products_dict, categories_list):
    data_cache = {
        "city_storage": storage,
        "production_rates": prod_rates,
        "consumption_rates": cons_rates,
        "city_food_pool": food_pool,
        "buildings_data": blds_data,
        "crafts_data": cfts_data,
        "built_buildings": built_blds,
        "products": products_dict,
        "categories": categories_list
    }
    resources_tab.update_data(data_cache)
    buildings_tab.update_data(data_cache)
    _refresh_all()

func show_resources_tab():
    _switch_tab("resources")

func _refresh_all():
    resources_tab.refresh()
    buildings_tab.refresh_built()
    technologies_tab.refresh()
    _update_food_label()

func _switch_tab(tab_id: String):
    active_tab = tab_id
    resources_panel.visible = (tab_id == "resources")
    buildings_panel.visible = (tab_id == "buildings")
    trade_panel.visible = (tab_id == "trade")
    technologies_panel.visible = (tab_id == "technologies")

    if tab_id == "buildings":
        buildings_tab.refresh_list()
    elif tab_id == "technologies":
        technologies_tab.refresh()

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

    # Обновляем food_label для дополнительных ресурсов
    if buildings_tab.selected_building_id != "":
        var bdata = null
        for b in data_cache.get("buildings_data", []):
            if b["id"] == buildings_tab.selected_building_id:
                bdata = b
                break
        if bdata and bdata.has("additional_cost"):
            var res_texts = []
            for res_id in bdata["additional_cost"]:
                var required = bdata["additional_cost"][res_id]
                var available = storage.get(res_id, 0)
                var res_name = data_cache.get("products", {}).get(res_id, {}).get("name", res_id)
                res_texts.append("%s: %d/%d" % [res_name, available, required])
            buildings_tab.food_label.text = "Доп. ресурсы: " + ", ".join(res_texts)
        else:
            buildings_tab.food_label.text = ""
    else:
        buildings_tab.food_label.text = ""

func update_food_label():
    _update_food_label()

func refresh_buildings_tab():
    if buildings_tab and buildings_tab.has_method("refresh_built"):
        buildings_tab.refresh_built()

func _on_build_requested(building_id: String):
    emit_signal("build_requested", building_id)

func _on_research_requested(tech_id: String):
    emit_signal("research_requested", tech_id)

func _process(delta):
    var mouse_pos = get_global_mouse_position()

    # Тултип для переключателей еды
    var hovered_food = false
    for pid in resources_tab.get_food_toggles():
        var toggle = resources_tab.get_food_toggles()[pid]
        if toggle.get_global_rect().has_point(mouse_pos):
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
                    var cost = bdata.get("cost_food", 0)
                    var food_sum = 0
                    var food_pool = resources_tab.get_food_pool()
                    var storage = data_cache.get("city_storage", {})
                    for pid in food_pool:
                        if food_pool[pid]:
                            food_sum += storage.get(pid, 0)
                    if food_sum < cost:
                        hint = "Недостаточно еды (нужно %d)" % cost
            if hint != "":
                ui_helpers.build_tooltip_label.text = hint
                ui_helpers.show_build_tooltip(mouse_pos)
                ui_helpers.build_tooltip_panel.visible = true
            else:
                ui_helpers.build_tooltip_panel.visible = false
    else:
        build_hover_timer = 0.0
        ui_helpers.build_tooltip_panel.visible = false

func set_message(text: String):
    if ui_helpers:
        ui_helpers.set_message(text)

func _input(event: InputEvent):
    if not visible:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        var click_pos = event.global_position
        var hit_panel = false
        for panel in [$LeftPanel, $TopPanel, $RightPanel, $ContentPanel, $BottomPanel]:
            if panel.get_global_rect().has_point(click_pos):
                hit_panel = true
                break
        if not hit_panel:
            _close_ui()
            accept_event()

func _close_ui():
    ui_helpers.set_message("")
    hide()
    emit_signal("closed")

func close_city():
    _close_ui()
