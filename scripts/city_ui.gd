# city_ui.gd
extends Control

# The tabs (panels)
@onready var resources_panel = $ContentPanel/ResourcesPanel
@onready var buildings_panel = $ContentPanel/BuildingsPanel
@onready var trade_panel = $ContentPanel/TradePanel
@onready var technologies_panel = $ContentPanel/TechnologiesPanel

# The tab buttons
@onready var resources_tab_button = $TabBarPanel/TabBar/ResourcesTabButton
@onready var buildings_tab_button = $TabBarPanel/TabBar/BuildingsTabButton
@onready var trade_tab_button = $TabBarPanel/TabBar/TradeTabButton
@onready var technologies_tab_button = $TabBarPanel/TabBar/TechnologiesTabButton
@onready var close_button_top = $CloseButtonTop

# The top bar
# TopFoodLabel — an HBox container with three child labels: food / population /
# treasury. The treasury is a separate label with a hover, because the tooltip is needed only
# on it (the breakdown by the sources of income/expense of the treasury).
@onready var top_food_label = $TabBarPanel/TopFoodLabel
@onready var top_food_value_label = $TabBarPanel/TopFoodLabel/FoodLabel
@onready var top_pop_value_label = $TabBarPanel/TopFoodLabel/PopLabel
@onready var top_treasury_value_label = $TabBarPanel/TopFoodLabel/TreasuryLabel
@onready var message_label = $BottomPanel/MessageLabel

# The hover state on "Treasury: N" in the top bar of the city. The snapshot of the sources
# of income/expense is updated once per resource era through _refresh_light, so that
# the "/sec" counter does not flicker every tick.
var _treasury_display_epoch: int = -1
# The cache of the treasury value shown in TopFoodLabel and in the breakdown tooltip.
# Both consumers are REQUIRED to show the same value: CityData.treasury
# changes on every consumption tick, and TopFoodLabel is updated with the interval
# from the settings (see _refresh_light). The cache is updated in _update_food_label
# (next to the write to TopFoodLabel); the tooltip reads the cache, not CityData directly.
var _displayed_treasury: int = 0

var active_tab = "resources"
var tab_buttons = []

var ui_helpers: Node
var worker_manager: Node # it is passed from main_map (see set_worker_manager)
var resources_tab: Node
var buildings_tab: Node
var tech_tree: Control
var trade_tab: Node

var data_cache: Dictionary = {}

# The last "era" of the resource display (see CityData.resource_display_interval):
# the values of the "Resources" tab and of the top row of the city are updated only when
# the era has changed, and not every tick. The event-driven paths (refresh on opening,
# refresh_light on a change of the assignments, update_food_label on the food toggle)
# are updated instantly and synchronise the era.
var _display_epoch: int = -1

# The tracking of the structural changes for a light refresh (a tick)
var _cached_built_count: int = -1
var _cached_research_id: String = ""

# The tooltips (timers)
var food_hover_timer: float = 0.0
var build_hover_timer: float = 0.0
var building_detail_hover_timer: float = 0.0
var building_detail_leave_timer: float = 0.0
var building_detail_locked: bool = false
var building_detail_locked_id: String = ""
var building_detail_delay: float = 0.5
# The hover timer for the treasury breakdown tooltip (see _process).
var treasury_hover_timer: float = 0.0
# The grace timer on leaving the label/the treasury tooltip — protects against
# the flickering when moving the cursor from the label to the tooltip and back (as in the tooltip
# of the building details, see BUILDING_DETAIL_LEAVE_GRACE).
var treasury_hover_leave_timer: float = 0.0
# The "stuck" treasury breakdown tooltip: the player held the cursor on the label for the delay
# (building_detail_delay) — the panel is fixed in place, and the cursor can be
# moved to the tooltip itself. It is removed by the grace timer of leaving (an analogue
# of building_detail_locked in the tooltip of the building details).
var treasury_locked: bool = false
const TOOLTIP_DELAY: float = 0.5
const BUILDING_DETAIL_LEAVE_GRACE: float = 0.35

signal build_requested(building_id: String)
signal research_requested(tech_id: String)
signal closed()

var building_panel

# The cache of the reference to BuildManager for connecting the signals of the construction completion
var _cached_build_manager = null

func set_building_detail_delay(value: float):
    building_detail_delay = maxf(0.0, value)

# Passes WorkerManager (from main_map) into the city tabs: the
# "Resources" tab needs it to compute the planned consumption (the tooltip of the resources
# and the dynamics with the "≈" marker, see resources_tab.gd).
func set_worker_manager(wm: Node):
    worker_manager = wm
    if resources_tab != null:
        resources_tab.set_worker_manager(wm)
    # The "Trade" tab needs WorkerManager for the cards of the internal
    # trade: it computes who consumes how much (the professions +
    # the pseudo-profession "All citizens").
    if trade_tab != null:
        trade_tab.set_worker_manager(wm)

func _ready():
    # We load the modules
    ui_helpers = load("res://scripts/ui_helpers.gd").new()
    ui_helpers.setup(self, message_label)
    add_child(ui_helpers)

    # The icons of the tab buttons (the top left corner) and the layout of the panels over the whole
    # width of the window. CityUi has anchors_preset=0 and the size 0×0 (as in
    # the original scene), therefore the panels are positioned manually, and when
    # the window size changes the layout is recalculated from scratch.
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

    # The technology tree in the Civ style: horizontal scrolling, vertical
    # columns by the "dependency layers", arrows from the ancestor to the descendant.
    # We create a separate Control inside TreeRoot, so that it fills the panel.
    tech_tree = load("res://scripts/tech_tree.gd").new()
    tech_tree.setup(
        $ContentPanel/TechnologiesPanel/TreeRoot,
        $ContentPanel/TechnologiesPanel/CurrentResearch/VBoxContainer/TechCurrentLabel,
        $ContentPanel/TechnologiesPanel/CurrentResearch/VBoxContainer/SciencePoolLabel
    )
    tech_tree.research_requested.connect(_on_research_requested)
    $ContentPanel/TechnologiesPanel/TreeRoot.add_child(tech_tree)

    trade_tab = load("res://scripts/trade_tab.gd").new()
    trade_tab.setup(
        $ContentPanel/TradePanel/Split/InternalPanel/InternalScroll/InternalList,
        ui_helpers
    )
    add_child(trade_tab)

    # The signals of the buttons
    for btn in [resources_tab_button, buildings_tab_button, trade_tab_button, technologies_tab_button]:
        if not btn.pressed.is_connected(_on_tab_button_pressed):
            btn.pressed.connect(_on_tab_button_pressed.bind(btn))
    if not close_button_top.pressed.is_connected(_on_close_pressed):
        close_button_top.pressed.connect(_on_close_pressed)

    # The transparency of the panels
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

    # The initial value of the treasury cache — the very first opening of the tooltip should
    # show the current treasury, and not the "0" of the default. Further on the cache is updated
    # in _update_food_label on every resource era.
    _displayed_treasury = CityData.treasury

    # Hovering over the "Treasury: N" label in the top bar — showing the tooltip of the breakdown
    # of the treasury by the sources of income/expense. The approach is polling + the grace timer
    # (see building_detail_tooltip below) — it works independently of
    # mouse_filter and correctly "survives" the transition of the cursor from the label to
    # the tooltip.

    # The treasury in the top bar of the city is updated via the tick path
    # (city_updated → _refresh_light) with a check of the resource display era —
    # in sync with the rest of the top row and with the resources of the "Resources" tab.
    # The direct signal treasury_changed is not needed here: the income of the internal market
    # changes the treasury every tick, and without throttling the top bar would
    # be updated every tick (the values would flicker).

    # The population in the top row of the city ("… | Population: N …") is updated by
    # the event (growth/death), without waiting for the resource display interval.
    if not CityData.population_changed.is_connected(_on_population_changed_label):
        CityData.population_changed.connect(_on_population_changed_label)

    # We connect the signal of the completion of the building construction to show the message
    # in the bottom panel of CityUI (the build_message signal goes to the map HUD,
    # which is hidden when the city interface is open).
    var bm = _get_build_manager()
    if bm and not bm.build_building_completed.is_connected(_on_building_build_completed):
        bm.build_building_completed.connect(_on_building_build_completed)

func _get_build_manager():
    if _cached_build_manager == null or not is_instance_valid(_cached_build_manager):
        var main_map = get_tree().root.find_child("MainMap", true, false)
        _cached_build_manager = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
    return _cached_build_manager

# The handler of the completion of the building construction: shows the message
# "Construction of <building> complete" in the bottom panel of CityUI.
func _on_building_build_completed(building_id: String, build_key: String):
    if ui_helpers and visible:
        var building_name = CityData.get_building_name(building_id)
        ui_helpers.set_message(tr("Construction of %s complete") % building_name)

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
    # A full refresh: we recreate the lists (opening the city, structural changes).
    # This is an event (the player opened the city / a building was built) — we update everything at once
    # and synchronise the era of the resource display.
    _update_data_cache()
    _cached_built_count = CityData.city_built_buildings.size()
    _cached_research_id = CityData.current_research_tech_id
    _refresh_all()
    _display_epoch = CityData.resource_display_epoch

func _refresh_light(force_resources := false):
    # A light refresh: we update the values without recreating the nodes.
    # This does not reset the tooltips (the nodes on which the cursor hangs are preserved).
    #
    # The resource values (the stock, the dynamics, the quality) and the top row "Food: N"
    # are updated with the interval from the settings (CityData.resource_display_interval):
    # the tick path (city_updated) waits for the era to come, the event-driven paths
    # (force_resources=true) are updated instantly.
    if not visible:
        return
    _update_data_cache()

    if _needs_full_refresh():
        # The structural changes (a new building, the start/completion of a research) —
        # an event: we update at once, including the resource values, and synchronise the
        # era of the display.
        _cached_built_count = CityData.city_built_buildings.size()
        _cached_research_id = CityData.current_research_tech_id
        _refresh_all()
        _display_epoch = CityData.resource_display_epoch
        return

    if force_resources or CityData.resource_display_due(_display_epoch):
        _display_epoch = CityData.resource_display_epoch
        resources_tab.update_values()
        _update_food_label()
        # The cards of the internal trade are updated with the same interval from
        # the settings: previously they were recalculated every tick, which made the
        # numbers flicker, and the open tooltip disappeared (the composition of the list
        # did not match the label, and the cards were recreated entirely). A recalculation for the sake of
        # an invisible tab is extra work, therefore only when the tab
        # is active.
        if active_tab == "trade":
            trade_tab.update_values()
        # On a change of the resource era we update the open tooltip of the treasury breakdown
        # with the fresh data (the planned income is recalculated, the snapshot of the expenses
        # is updated, see CityData.tick_resource_display → rotate_treasury_window).
        # keep_position=true: the "stuck" panel stays in place — otherwise
        # the live-update would drag it out from under the cursor.
        if ui_helpers and is_instance_valid(ui_helpers) \
                and ui_helpers.treasury_tooltip_panel \
                and ui_helpers.treasury_tooltip_panel.visible:
            _show_treasury_tooltip(get_viewport().get_mouse_position(), true)
            _treasury_display_epoch = CityData.resource_display_epoch
        # The quality breakdown tooltip in the "Trade" card — by the same
        # rule: it stays in place, the contents are updated.
        if active_tab == "trade" and trade_tab != null \
                and trade_tab.has_method("refresh_open_tooltip"):
            trade_tab.refresh_open_tooltip()
    buildings_tab.update_built_status()
    # We update the open quality breakdown tooltip of the card with the fresh data
    # on a change of the era (see trade_tab.refresh_open_tooltip): the panel stays
    # under the cursor, but its numbers stop becoming outdated.
    # We update the research progress only when the Technologies tab
    # is active — otherwise it is extra work on every tick. The cost is minimal,
    # but the habit of "not doing anything extra if it is not needed" matters.
    if active_tab == "technologies":
        tech_tree.update_progress()

func _needs_full_refresh() -> bool:
    # A full refresh is required only on structural changes:
    # the construction of a building or the start/completion of a research.
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
    # A public method for a light refresh on a change of the assignments.
    # A change of the assignments is an action of the player: the resource values are updated
    # instantly, without waiting for the display interval (force_resources=true).
    _refresh_light(true)

func _refresh_all():
    resources_tab.refresh()
    buildings_tab.refresh_built()
    tech_tree.refresh()
    trade_tab.refresh()
    _update_food_label()

func _switch_tab(tab_id: String):
    active_tab = tab_id
    resources_panel.visible = (tab_id == "resources")
    buildings_panel.visible = (tab_id == "buildings")
    trade_panel.visible = (tab_id == "trade")
    technologies_panel.visible = (tab_id == "technologies")

    # The right panel "Built buildings" is shown only on the tabs
    # "Resources" and "Buildings" (when the window is divided in half); on "Trade" and
    # "Technologies" the content occupies the whole width of the window. The calculation of the offsets is in
    # the common _layout_ui().
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
    elif tab_id == "trade":
        # The composition of the cards depends on the assignments and the population, therefore on
        # opening the tab the list is rebuilt entirely.
        trade_tab.refresh()

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

    # The cyclic productions/consumptions (the improvements with production_interval,
    # the professions with an interval) issue/write off the food in "batches", therefore in a tick
    # without an event the fact equals 0. So that the label does not flicker "+0", with a zero fact
    # we show the average rate from the planned maps (as the "≈" dynamics on
    # the "Resources" tab).
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

    var food_str = tr("Food: %d [+%d%s / -%d%s]") % [food_sum, total_prod, prod_mark, total_cons, cons_mark]
    var pop_str = tr("Population: %d (free: %d)") % [CityData.total_population, CityData.idle_population]
    # We capture the value of the treasury in the cache — this same cache is read by the breakdown tooltip
    # of the treasury (see _show_treasury_tooltip). The synchronisation is important, otherwise with
    # a display interval > 1 sec the TopFoodLabel label shows the old
    # value, and the tooltip — a fresher one every tick (a visual regression "runs
    # ahead", see developer_diary).
    _displayed_treasury = CityData.treasury
    # The dynamics of the profit/expense of the treasury — by the same window data as the breakdown
    # tooltip (CityData.get_treasury_flow_text), but per second. Exactly the same
    # text as in the HUD label of the map: both rows are assembled from one method,
    # therefore they cannot diverge.
    var treasury_str = tr("Treasury: %d %s") % [
        _displayed_treasury, CityData.get_treasury_flow_text()
    ]

    # TopFoodLabel — an HBoxContainer with three child labels
    # (FoodLabel/PopLabel/TreasuryLabel), see the scene CityUI.tscn. The "|" separator
    # is drawn between them by a separate label in the scene.
    if top_food_value_label:
        top_food_value_label.text = food_str
    if top_pop_value_label:
        top_pop_value_label.text = pop_str
    if top_treasury_value_label:
        top_treasury_value_label.text = treasury_str

# The cursor is now over the treasury label — exactly and only this starts
# the hover timer of "sticking" the treasury breakdown tooltip.
func _is_treasury_label_hovered(mouse_pos: Vector2) -> bool:
    if not visible:
        return false
    return is_instance_valid(top_treasury_value_label) \
        and top_treasury_value_label.get_global_rect().has_point(mouse_pos)

# The cursor is now over the treasury label OR over the active (including "stuck")
# treasury breakdown tooltip. If yes — the tooltip is kept open, and there is no leaving via
# the grace timer (this is needed so that when moving the cursor from the label to
# the tooltip the tooltip does not blink). Analogously to the logic of building_detail_tooltip below.
func _is_treasury_hovered(mouse_pos: Vector2) -> bool:
    if _is_treasury_label_hovered(mouse_pos):
        return true
    if ui_helpers and is_instance_valid(ui_helpers) \
            and ui_helpers.treasury_tooltip_panel \
            and ui_helpers.treasury_tooltip_panel.visible \
            and ui_helpers.treasury_tooltip_panel.get_global_rect().has_point(mouse_pos):
        return true
    return false

# Shows the breakdown tooltip of the treasury under the cursor. The data is from worker_manager
# (the planned income by sources) and CityData (a snapshot of the expenses over the window).
# It is called from _process after building_detail_delay has expired (the sticking) and on
# a change of the resource display era (see _refresh_light) — then with
# keep_position=true: the panel stays in place, only the contents are updated.
# It returns true if the tooltip is visible in the end: an empty breakdown hides
# the panel, and the caller must not consider the tooltip "stuck".
func _show_treasury_tooltip(mouse_pos: Vector2, keep_position: bool = false) -> bool:
    if not (ui_helpers and is_instance_valid(ui_helpers) and worker_manager):
        return false
    var planned_income: Dictionary = {}
    if worker_manager.has_method("get_actual_treasury_income_map"):
        planned_income = worker_manager.get_actual_treasury_income_map()
    # We take _displayed_treasury (the cache of TopFoodLabel), and not CityData.treasury —
    # otherwise the tooltip would show a "fresh" value of the treasury, getting ahead of the
    # TopFoodLabel label by 1+ consumption ticks (see developer_diary).
    ui_helpers.show_treasury_tooltip(
        mouse_pos,
        _displayed_treasury,
        planned_income,
        CityData.treasury_expense_snapshot,
        CityData.treasury_window_length_sec,
        keep_position
    )
    var panel = ui_helpers.treasury_tooltip_panel
    return is_instance_valid(panel) and panel.visible

# The total per-second rate of the entries of the plan (production or consumption)
# by the products from the food pool. The format of the maps — product_id -> { source -> { amount,
# interval, ... } }; interval = 0 — "per tick" (tick = SIMULATION_TICK = 1 sec).
func _planned_food_per_sec(map: Dictionary, pool: Dictionary) -> int:
    var total := 0.0
    for pid in pool:
        if not pool[pid]:
            continue
        for source_id in map.get(pid, {}):
            var entry: Dictionary = map[pid][source_id]
            var amount = float(entry.get("amount", 0))
            var interval = float(entry.get("interval", 0))
            if interval > 0.0:
                total += amount * CityData.SIMULATION_TICK / interval
            else:
                total += amount
    return int(round(total))

    # We update the food label on the "Buildings" tab (without the population)
    if buildings_tab.has_method("update_food_label"):
        buildings_tab.update_food_label()

    # The additional resources are now displayed in the panel of the building details

func update_food_label():
    _update_food_label()

# The population has changed (growth/death) — the top row of the city shows it
# next to the food and the treasury; we update it at once, bypassing the resource display interval.
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

    # The tooltip for the food toggles (only on the "Resources" tab — otherwise the
    # hidden toggles "leak" into the other tabs through get_global_rect,
    # which returns the coordinates even for hidden panels).
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

    # The tooltip for the "Build" button
    var hovered_build = false
    if buildings_panel.visible and buildings_tab.build_button:
        if buildings_tab.build_button.get_global_rect().has_point(mouse_pos):
            hovered_build = true

    if hovered_build:
        build_hover_timer += delta
        if build_hover_timer >= TOOLTIP_DELAY:
            var hint = ""
            if buildings_tab.selected_building_id == "":
                hint = tr("No building selected")
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
                        hint = tr("Construction: %d work, %.0f sec.\n") % [work_cost, build_time]
                        hint += tr("Available work: %.0f/sec (%d citizens)") % [labor, CityData.total_population]
                    else:
                        hint = tr("Build instantly (free)")
                    # The information about the limit of simultaneous builds (buildings + improvements).
                    # The limit equals the total number of citizens.
                    var construction_count = CityData.building_construction.size()
                    var main_map = get_tree().root.find_child("MainMap", true, false)
                    var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
                    if bm:
                        construction_count = bm.get_total_active_builds()
                    var construction_limit = CityData.total_population
                    if construction_count >= construction_limit:
                        hint += tr("\nConcurrent construction limit reached (%d/%d, limit = number of citizens)") % [construction_count, construction_limit]
                    elif construction_count > 0:
                        hint += tr("\nConstructions: %d/%d (limit = number of citizens)") % [construction_count, construction_limit]
            if hint != "":
                ui_helpers.build_tooltip_label.text = hint
                ui_helpers.show_build_tooltip(mouse_pos)
                ui_helpers.build_tooltip_panel.visible = true
            else:
                ui_helpers.build_tooltip_panel.visible = false
    else:
        build_hover_timer = 0.0
        ui_helpers.build_tooltip_panel.visible = false

    # The tooltip for the progress bars of the buildings under construction (updated in real time)
    var hovered_bar = {}
    if buildings_panel.visible:
        hovered_bar = buildings_tab.get_hovered_construction_bar(mouse_pos)
    if not hovered_bar.is_empty():
        var status_text = hovered_bar.get("status_text", tr("Under construction"))
        var percent = hovered_bar.get("percent", 0.0)
        ui_helpers.progress_tooltip_label.text = "%s: %.0f%%" % [status_text, percent]
        ui_helpers.show_progress_tooltip(mouse_pos)
        ui_helpers.progress_tooltip_panel.visible = true
    else:
        ui_helpers.hide_progress_tooltip()

    # The building details tooltip (the "Buildings" tab): we show it on hovering
    # over any building button; the contents are assembled in buildings_tab.
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

    # The breakdown tooltip of the treasury by the sources of income/expense: polling + the sticking
    # (the same pattern as the building details tooltip above, and the same delay
    # building_detail_delay). While the cursor is on the label and the tooltip is not yet stuck —
    # we accumulate the delay and show it ONCE; further on the panel stands in place, and
    # the cursor can be moved onto the tooltip itself. An empty breakdown does not show
    # the tooltip — then there is no "sticking" and the polling continues (the income may
    # appear on the next tick, without moving the cursor).
    # The live-update of the contents is in _refresh_light (with keep_position).
    var hovered_treasury := _is_treasury_hovered(mouse_pos)
    var hovered_treasury_label := _is_treasury_label_hovered(mouse_pos)
    if hovered_treasury:
        treasury_hover_leave_timer = 0.0
        if hovered_treasury_label and not treasury_locked:
            treasury_hover_timer += delta
            if treasury_hover_timer >= building_detail_delay:
                treasury_locked = _show_treasury_tooltip(mouse_pos)
    else:
        if treasury_locked:
            treasury_hover_leave_timer += delta
            if treasury_hover_leave_timer < BUILDING_DETAIL_LEAVE_GRACE:
                return
        treasury_hover_timer = 0.0
        treasury_hover_leave_timer = 0.0
        treasury_locked = false
        ui_helpers.hide_treasury_tooltip()

func set_message(text: String):
    if ui_helpers:
        ui_helpers.set_message(text)

func _input(event: InputEvent):
    if not visible:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        var click_pos = event.global_position

        # If the building panel is open — its handler has already closed it, we exit
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
        ui_helpers.hide_treasury_tooltip()
    # A reset of the state of "sticking" of the treasury: on the next opening of the city the tooltip
    # should appear anew after the delay, and not "pop up" already open
    # (the panel lives together with CityUi and inherits its hiding).
    treasury_hover_timer = 0.0
    treasury_hover_leave_timer = 0.0
    treasury_locked = false
    if building_panel:
        building_panel.hide()
    hide()
    emit_signal("closed")

func close_city():
    _close_ui()

func _position_close_button_top() -> void:
    # It pins CloseButtonTop to the top right corner of the viewport. It is done
    # manually, because CityUi has anchors_preset=0 (size 0×0) and
    # anchor_right=1.0 of the button would not give a binding to the edge of the screen.
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
    # The icons for the small tab buttons in the top left corner.
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
    # The layout of the panels of the city interface over the whole width of the window.
    var w: float = get_viewport_rect().size.x
    var h: float = get_viewport_rect().size.y

    # The tabs — at the top left in the top bar over the whole width of the window.
    var tab_bar_panel = $TabBarPanel
    if tab_bar_panel:
        tab_bar_panel.offset_left = 0
        tab_bar_panel.offset_right = w
        tab_bar_panel.offset_top = 0.0
        tab_bar_panel.offset_bottom = 50.0
    var tab_bar = $TabBarPanel/TabBar
    if tab_bar:
        tab_bar.position = Vector2(8, 8)

    # The bottom panel of messages — over the whole width of the window.
    $BottomPanel.offset_left = 0
    $BottomPanel.offset_right = w
    $BottomPanel.offset_top = h - 50.0
    $BottomPanel.offset_bottom = h

    # The right panel "Built buildings" — on the tabs "Resources" and "Buildings"
    # (the window is divided into two equal parts), on the other tabs it is hidden.
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

    # The close button — in the top right corner over everything.
    _position_close_button_top()
