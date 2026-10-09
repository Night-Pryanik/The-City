@tool
extends Node2D

const HEX_RADIUS = 55

# --- The dimensions and the boundaries of the world/window ---

# The main parameters (map_rows, map_cols, start_ring_rows, start_ring_cols,
# region_width) are loaded from data/map_config.json in _load_map_config().
# They are NOT constants, because:
#   1) the values come from the JSON;
#   2) on the transition to the next era the Ring and the Region expand.
var map_rows: int = 60 # The whole map: the rows (hexes)
var map_cols: int = 60 # The whole map: the columns (hexes)
var start_ring_rows: int = 7 # The starting Influence Ring: the rows
var start_ring_cols: int = 9 # The starting Influence Ring: the columns
var region_width: int = 2 # The width of the Region around the Ring (in hexes)
var ring_rows: int = 7
var ring_cols: int = 9

# The current visible window: the Ring + the Region.
var region_rows: int = 11
var region_cols: int = 13

# The current (dynamically growing) Influence Ring.
var city_row: int = 30
var city_col: int = 30

# The absolute boundaries of the Influence Ring (inclusive) over the whole map.
var influence_start_row: int = 0
var influence_end_row: int = 0
var influence_start_col: int = 0
var influence_end_col: int = 0

# The current visible window: the Ring + the Region.
var region_start_row: int = 0
var region_end_row: int = 0
var region_start_col: int = 0
var region_end_col: int = 0

# The starting boundaries of "Ring" and "Ring + Region" at the moment of the generation of the map.
# They are saved ONCE in _initialize_map and further do NOT change — they are needed for
# the guarantees of the spawn of the resources, so that they work by the original, and not the future
# expanded boundaries. For example, _ensure_minimum_resource({"category": "metals"})
# relies exactly on these fields, and not on the current influence_* / region_*.
var start_influence_start_row: int = 0
var start_influence_end_row: int = 0
var start_influence_start_col: int = 0
var start_influence_end_col: int = 0
var start_region_start_row: int = 0
var start_region_end_row: int = 0
var start_region_start_col: int = 0
var start_region_end_col: int = 0

# The position of the city (the centre of the whole map).
var current_era: int = 0

# The debug action "Open the whole map" has revealed the whole map (debug_open_whole_map).
# The renderer lifts the era gate of the rings and of the roads of the towns on such a map
# (map_renderer._ensure_town_influence_cache / are_town_roads_visible): the reveal is
# deliberate, there is nothing left to hide. Stored in the save together with the tiles.
var debug_whole_map_revealed: bool = false

const SCOUTING_TIME_PER_HEX: float = 3.0

# The technology that opens the scouting beyond the Region (the fog of war and
# the territory of the towns). Before it is learned the scouts can be sent only
# into the unexplored part of the Region, and the hexes outside the Region are inaccessible for
# the hover and the click (see is_hex_interactive). The data of the technology —
# data/technologies/antiquity.json, id "cartography".
const CARTOGRAPHY_TECH_ID := "cartography"
# The absolute boundaries of the Influence Ring (inclusive) over the whole map.

var tile_data = []
var offset_x: float = 0.0
var offset_y: float = 0.0
var scroll_offset = Vector2.ZERO

# The absolute boundaries of the visible window "Ring + Region" (inclusive).
# The Region is the only zone where the chunks can be BOUGHT (claimed).
# The scouting of the Region is not limited ONLY after the learning of the technology
# "Cartography": before it the scouts can be sent only into the unexplored
# part of the Region (see is_cartography_researched / expansion_manager).
# After the Cartography the scouts can be sent to any point reachable by
# the scrolling of the map (see get_scout_reach_bounds). The unexplored hexes beyond
# the window are drawn as the fog of war (they are not drawn at all) without the contents.
var unique_terrain_hexes: Array = []

# The starting boundaries of "Ring" and "Ring + Region" at the moment of the generation of the map.
# They are saved ONCE in _initialize_map and further do NOT change — they are needed for
# the guarantees of the spawn of the resources, so that they work by the original, and not the future
# expanded boundaries. For example, _ensure_minimum_resource({"category": "metals"})
# relies exactly on these fields, and not on the current influence_* / region_*.
var town_hexes: Array = []

# The current era (0 = the starting one). It is used by the infrastructure of the expansion.
# read it directly, without a search through the list. It is not saved,
# it is recalculated/mirrored from town_manager.towns.
var town_influence_hexes: Array = []

# The full records of the towns (the master list lives in town_manager.towns; here —
# a REFERENCE to it, and not a snapshot). The renderer reads from this variable the per-town
# data: the personal ring (town["influence_hexes"]) and the colour of the borders
# (town["border_color"]). The reference nature guarantees that any edits
# of the rings/fields in town_manager are immediately visible on the map without a repeated mirroring.
var towns: Array = []

var last_city_click_time = 0.0
# The last moment of the click on the hex of a town (for the detection of a double click).
var last_town_click_time = 0.0
var production_timer = 0.0
# The accumulator of the tick of the simulation of the towns. The towns run on
# their own, slower clock (TownManager.get_town_tick_seconds — town_tick_ticks
# common ticks), therefore the timer is separate from production_timer.
var town_timer = 0.0
var scouting_timer: float = 0.0
# Whether there are pastures which are being filled right now (0% < fill < 100%).
# It is used as the condition of the redrawing of the layer of the progress bars: while the herd is growing,
# the layer is updated; when everything is full — the layer "sleeps" again.
var _has_growing_pastures := false
# The pastures growing right now (the key "row,col" → {"row", "col"}).
# It is assembled on the production tick, it advances frame by frame in _tick_pasture_fill().
var _growing_pastures := {}

var scouting_chunk: Array = []
var is_scouting: bool = false

var settings_config = ConfigFile.new()
var show_hex_borders = true
var use_edge_scrolling = true
# The margin (in pixels) of the pre-render of the screen-sized layers of the map. The layers
# that are cached by the renderer as a screen-sized texture (the influence rings of the towns)
# are rendered into a rectangle larger than the viewport by this margin on each side. While the
# scroll stays within the margin, the texture is reused as is and only its position in the world
# changes - therefore a pan does not rebuild the cache every frame.
const MAP_CACHE_MARGIN := 512.0
var tooltip_delay: float = 0.5
var extended_tooltip_delay: float = 1.0
var building_detail_delay: float = 0.5
# The interval of the update of the data about the resources in the UI (sec, 1..5 with a step of 1; the key
# game/resource_display_interval in user://settings.cfg). It is also stored in
# CityData.resource_display_interval — there is also the accumulator and the "era" of the display.
var resource_display_interval: float = 1.0

# The last "era" of the display on which the HUD label of the treasury has been updated.
# The tick path (city_updated → _on_city_data_updated) redraws the label
# only when the era has changed — synchronously with the other places which
# are subordinated to the interval of the resources (the tab "Resources", the top bar of the city,
# the tooltips).
var _treasury_display_epoch: int = -1

# The hover state on "Treasury: N" in the HUD of the map and the UI-helpers for the HUD tooltips.
# A separate instance of ui_helpers (in parallel with city_ui) — each root of the UI
# has its own hierarchy of the tooltip panels, because they are added as the children
# of the passed Control-parent. Its own CanvasLayer guarantees that the tooltips
# are drawn over the HUD and the map, regardless of city_ui.
var _map_ui_helpers: Node = null
var _treasury_hover_timer: float = 0.0
var _treasury_hover_leave_timer: float = 0.0
# The tooltip of the breakdown of the treasury "stuck": the player held the cursor on the HUD label for the delay
# (building_detail_delay) — the panel is fixed in place, and the cursor can be
# moved to the tooltip itself. It is removed by the grace timer of leaving (an analogue
# of building_detail_locked at the tooltip of the building details, see city_ui.gd).
var _treasury_locked: bool = false
var _treasury_tooltip_display_epoch: int = -1
# The cache of the value of the treasury, shown in the HUD label and in the tooltip of the breakdown. Both
# of a consumer are REQUIRED to show one and the same value — otherwise in the tooltip
# it "runs ahead" by 1+ ticks because CityData.treasury changes
# on every consumption tick, and the HUD/TopBar are updated with the interval from
# the settings. The cache is updated in _update_treasury_hud() (the same point as
# the update of the label itself); the tooltip reads the cache, not CityData directly.
var _displayed_treasury: int = 0

# The grace timer of leaving the cursor (a common value with city_ui — a single rhythm
# of the tooltips, equally responsive). BUILDING_DETAIL_LEAVE_GRACE is used
# without a direct reference to city_ui — a literal of 0.35 sec (see city_ui.gd).
# The delay of the showing of the tooltip of the breakdown of the treasury is taken from building_detail_delay
# (the setting "Interface → the delay of the hint about the details of a building"): the tooltip
# of the details of a building uses the same delay — their rhythm is common.
const MAP_TOOLTIP_LEAVE_GRACE: float = 0.35

@onready var city_ui = $CityUI
@onready var town_ui = $TownUI
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
@onready var project_manager = $ProjectManager
@onready var expansion_manager = $ExpansionManager
@onready var river_manager = $RiverManager
@onready var town_manager = $TownManager
@onready var worker_manager = $WorkerManager
@onready var townsfolk_manager = $TownsfolkManager
@onready var settings_menu = preload("res://scenes/settings_menu.tscn").instantiate()
@onready var input_handler = $InputHandler
@onready var debug_manager = $DebugManager
@onready var control_panel = $ControlPanel
var map_tooltip: MapTooltip

var tech_popup: Control
var research_hbox: HBoxContainer
var research_button: Button
var research_icon: TextureRect # the child TextureRect inside research_button
var research_label: Label # the child Label inside research_button
var research_progress_bar: ProgressBar
var _last_research_hud_tech: String = ""

# --- The natural transition to the next era ---
var era_dialog: ConfirmationDialog
var era_advance_button: Button

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
        map_renderer.load_icons()
        SaveManager.apply_loaded_data()

        # We restore the state of the world/window from the save BEFORE the building of tile_data.
        _apply_saved_map_state()

        tile_data = []
        road_manager.initialize(city_row, city_col)
        var saved_tiles = SaveManager.saved_data.get("tile_data", [])
        for row in range(map_rows):
            var col_array = []
            for col in range(map_cols):
                # crop_bred — the id of a domesticated animal/plant which is bred
                # on an empty hex (see docs.md, the section "Breeding of animals/plants").
                # For the natural resources tile.resource remains.
                var tile = {"terrain": "plain", "cover": "none", "resource": null, "crop_bred": null, "improvement": null, "decorative": false, "production_fractional_remainder": 0.0, "feed_fractional_remainder": 0.0, "terrain_icon": "", "in_influence": false, "is_explored": false, "river_edges": [], "in_town_influence": false, "has_town": false, "road_built": false, "road_level": 1, "road_staged": false}
                if row < saved_tiles.size() and col < saved_tiles[row].size():
                    var saved = saved_tiles[row][col]
                    if not saved.is_empty():
                        # The forest is a cover (cover) over the terrain.
                        var saved_terrain = saved.get("terrain", "plain")
                        var saved_cover = saved.get("cover", "none")
                        tile["terrain"] = saved_terrain
                        tile["cover"] = saved_cover
                        tile["resource"] = saved.get("resource")
                        tile["crop_bred"] = saved.get("crop_bred")
                        # The occupancy of the livestock
                        tile["fill_time"] = float(saved.get("fill_time", 0.0))
                        # The fractional remainder of the continuous production of an improvement.
                        # The obsolete production_progress is not used; if it is present
                        # we simply ignore it and start from zero.
                        if saved.has("production_progress"):
                            tile["production_fractional_remainder"] = 0.0
                            tile["feed_fractional_remainder"] = 0.0
                        else:
                            tile["production_fractional_remainder"] = float(saved.get("production_fractional_remainder", 0.0))
                            tile["feed_fractional_remainder"] = float(saved.get("feed_fractional_remainder", 0.0))
                        tile["improvement"] = saved.get("improvement")
                        tile["decorative"] = bool(saved.get("decorative", false))
                        tile["quality"] = saved.get("quality", "")
                        tile["terrain_icon"] = saved.get("terrain_icon", "")
                        tile["in_influence"] = saved.get("in_influence", false)
                        tile["is_explored"] = saved.get("is_explored", false)
                        tile["river_edges"] = saved.get("river_edges", [])
                        # road_built — a road is laid on the hex, built by
                        # the player (the special action "Build a road"). The segments are not
                        # written to the save, therefore only the fact is saved:
                        # by it the network is recalculated on loading (see
                        # road_manager.rebuild_player_roads).
                        tile["road_built"] = bool(saved.get("road_built", false))
                        # road_level — the road level to this hex (see
                        # SaveManager._serialize_tile_data).
                        tile["road_level"] = int(saved.get("road_level", 1))
                        # road_staged — the road to an improvement on this hex is going
                        # by a phased project, its state is stored by the flags
                        # road_built/road_level and the queue of the projects. Such a hex
                        # the recalculation rebuild_roads_from_existing must skip,
                        # otherwise it would finish the unpaid (or the cancelled) road
                        # for free.
                        tile["road_staged"] = bool(saved.get("road_staged", false))
                col_array.append(tile)
            tile_data.append(col_array)

        # We guarantee that the city is on a permitted terrain on loading a save
        _ensure_city_valid_terrain()
        _mark_city_hex()

        # We restore the builds of the improvements, the buildings and the claiming of the territory
        build_manager.restore_builds(SaveManager.saved_data.get("active_builds", {}))
        build_manager.restore_building_builds(SaveManager.saved_data.get("active_building_builds", {}))
        build_manager.restore_expansion_builds(SaveManager.saved_data.get("active_expansion_builds", {}))

        # We restore the unfinished phased projects (the road by the hexes).
        # Their segments are not written to the save: the already laid part is restored
        # by the flags road_built, set on each connected hex
        # of the step (see _on_project_step_completed), and the queue of the remaining
        # segments continues to be completed.
        project_manager.restore_projects(SaveManager.saved_data.get("active_projects", {}))

        # We restore the assignments of the workers and the citizens
        worker_manager.load_assignments(SaveManager.saved_data.get("worker_assignments", []))
        # The timers of the occupational consumption — after the assignments, so that
        # the interval for each hex is recalculated by the current profession.
        worker_manager.load_consumption_timers(SaveManager.saved_data.get("profession_consumption_timers", []))
        # The timers of the consumption of the city ("all", all the citizens of the city) — the interval
        # is recalculated from the data on loading, we store only elapsed.
        worker_manager.load_city_consumption_timers(SaveManager.saved_data.get("city_consumption_timers", []))
        townsfolk_manager.load_assignments(SaveManager.saved_data.get("townsfolk_assignments", []))
        # The timers of the occupational consumption of the CITY BUILDINGS — after
        # the assignments of the citizens: the profession is determined by the building (data/buildings.json),
        # the fractional remainders are stored in the save, the intervals are recalculated from the data.
        worker_manager.load_building_consumption_timers(SaveManager.saved_data.get("building_profession_consumption_timers", []))

        # For the already researched technologies we guarantee the spawn of the resources opened by them
        CityData.ensure_tech_resources_spawned()

        # We recalculate the free citizens by the actually restored assignments
        var total_assigned = worker_manager.get_assigned_count() + townsfolk_manager.get_assigned_count()
        CityData.idle_population = max(0, CityData.total_population - total_assigned)

        # --- THE CHECK: if there are assignments of the citizens, but they do not coincide with the number of the buildings, we fix it ---
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

        road_manager.rebuild_roads_from_existing(tile_data, map_rows, map_cols,
                Callable(self, "_skip_improvement_road_restore"))

        # We restore the rivers from the save and mark river_edges in the hexes
        river_manager.load_rivers(SaveManager.saved_data.get("rivers", []))
        river_manager.mark_river_edges(tile_data, map_rows, map_cols, HEX_RADIUS)

        # We collect the hexes of a unique terrain (for example, a soda lake) after the loading.
        unique_terrain_hexes = []
        for row in range(map_rows):
            for col in range(map_cols):
                var terrain_id = tile_data[row][col].get("terrain", "plain")
                var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
                if t_data.get("unique", false):
                    unique_terrain_hexes.append({"row": row, "col": col})

        # We restore the towns from the save and mirror them into town_hexes for the renderer.
        # town_manager.load_towns fills the master list towns, and the derived
        # town_hexes — inside the manager; plus we manually set tile.has_town
        town_manager.load_towns(SaveManager.saved_data.get("towns", []))
        towns = town_manager.towns
        town_hexes = []
        for h in town_manager.town_hexes:
            tile_data[h.row][h.col]["has_town"] = true
            town_hexes.append({"row": h.row, "col": h.col})

        # The personal rings of the towns are rebuilt by the radius from the record
        # (compute_all_town_influences). It also sets the flags
        # in_town_influence on the tiles and collects the flat mirror
        # town_influence_hexes for the renderer. The ring is built WHOLLY (without
        # a clip by the current Region); what of the ring
        # is visible to the player is decided by the renderer (the fog of war + the era).
        #
        # BEFORE the recalculation we give the manager the starting area of the player: its
        # boundaries are restored from the save, and on the generation it is set in
        # generate_towns. The territory of the towns is cut out of it — over the whole map
        # (including the hexes under the fog) the hexes of the player remain his.
        town_manager.set_player_start_area(start_region_start_row, start_region_end_row,
                start_region_start_col, start_region_end_col)
        town_manager.compute_all_town_influences(tile_data, map_rows, map_cols)
        # We fill the rings of the towns with the decorative improvements and also for the old
        # saves, where these marks were still absent.
        town_manager._place_decorative_town_improvements(tile_data, map_rows, map_cols)
        # We build the roads of the towns ONLY HERE: the improvements in the rings already stand
        # (the call above), and the towns themselves are already loaded from the save. Up to this point
        # there were no networks of the towns on the map.
        _rebuild_town_roads()
        town_influence_hexes = []
        for h in town_manager.town_influence_hexes:
            town_influence_hexes.append({"row": h.row, "col": h.col})

        SaveManager.is_loaded = false
        SaveManager.saved_data.clear()
        map_renderer.initialize(tile_data, self)
        progress_bar_layer.initialize(tile_data, self)
    else:
        randomize()
        _initialize_map()
        road_manager.initialize(city_row, city_col)
        # The road network of the city of the player is ready — it is possible to build the networks of the towns
        # (the towns and their improvements are already placed in _initialize_map).
        _rebuild_town_roads()
        map_renderer.initialize(tile_data, self)
        progress_bar_layer.initialize(tile_data, self)

    _load_settings()

    tooltip_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    tooltip_text_label.custom_minimum_size = Vector2(300, 0)
    tooltip_text_label.bbcode_enabled = true

    add_child(settings_menu)
    settings_menu.hide()

    # The initialization of InputHandler
    input_handler.initialize(self)

    map_tooltip = MapTooltip.new(tooltip_text_label, tooltip_products_container, map_renderer, worker_manager)

    # The initialization of the panel of the hex (the bottom panel).
    control_panel.initialize(self)

    input_handler.set_tooltip_delay(tooltip_delay)
    input_handler.set_extended_tooltip_delay(extended_tooltip_delay)
    city_ui.set_building_detail_delay(building_detail_delay)
    CityData.set_resource_display_interval(resource_display_interval)
    # The planned consumption on the tab "Resources" (the tooltip and the dynamics "≈") is counted
    # by the workers worker_manager — we pass the reference into the UI of the city.
    city_ui.set_worker_manager(worker_manager)

    # The initialization of DebugManager
    debug_manager.initialize(self)

    # The UI-helpers for the HUD tooltips (the breakdown of the treasury, and potentially the future
    # tooltips on the elements of the HUD). Its own CanvasLayer and Control-host, so that
    # the tooltips lie over the HUD and the map; the detailed list of the panels is inside
    # ui_helpers.setup() — see the corresponding script. We pass null into
    # message_label: the HUD of the map shows its own message through hud_message.gd,
    # there is no need to duplicate the channel.
    _setup_hud_tooltip_layer()

    _calc_offsets()
    map_renderer.queue_redraw()

    _update_population_hud()
    _update_treasury_hud()

    city_ui.closed.connect(_on_city_ui_close)
    town_ui.closed.connect(_on_town_ui_close)
    town_manager.town_treasury_changed.connect(town_ui.on_town_treasury_changed)
    town_manager.town_storage_changed.connect(town_ui.on_town_storage_changed)
    city_button.pressed.connect(_on_city_button_pressed)
    expansion_button.pressed.connect(_on_expansion_button_pressed)
    city_ui.build_requested.connect(CityData.request_build)
    CityData.research_error.connect(_on_research_error)
    CityData.research_error.connect(hud.show_message)
    CityData.population_changed.connect(_on_population_changed)
    # The treasury in the HUD is updated via the tick path (city_updated) with the check of
    # the era of the display of the resources — synchronously with the other resources. The direct
    # signal treasury_changed is not needed here: the income of the internal market changes
    # the treasury on every tick, and without throttling the HUD label would flicker every tick.
    CityData.city_updated.connect(_on_city_data_updated)
    city_ui.research_requested.connect(CityData.start_research)
    CityData.research_completed.connect(_on_research_completed)
    expansion_manager.chunk_hovered.connect(_on_chunk_hovered)
    worker_manager.assignment_changed.connect(_on_assignment_changed)
    townsfolk_manager.assignment_changed.connect(_on_townsfolk_assignment_changed)
    # The control panel must react to the external changes: the assignment
    # of the workers, the completion/cancellation of the builds, the update of the city, the learning of the technologies,
    # the expansion of the territory. Otherwise it would show the outdated information.
    worker_manager.assignment_changed.connect(control_panel.refresh)
    build_manager.build_completed.connect(_on_control_panel_build_changed)
    build_manager.build_cancelled.connect(_on_control_panel_build_changed)
    build_manager.build_paused.connect(_on_control_panel_build_changed)
    # The tick update (and not refresh): the info column with the resources and the preview
    # are updated with the display interval (see control_panel.on_city_updated).
    CityData.city_updated.connect(control_panel.on_city_updated)
    CityData.research_completed.connect(control_panel.refresh)

    # The change of the language on the fly: the text set in the scenes is translated by Godot itself, and
    # everything assembled in the code (the lists of the tabs, the panel of the hex, the HUD) has to be
    # rebuilt. By this moment the data has already been re-read by the language manager.
    LocalizationManager.locale_changed.connect(_on_locale_changed)

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
    build_manager.building_upgrade_completed.connect(_on_building_upgrade_completed)
    build_manager.expansion_build_completed.connect(expansion_manager.on_expansion_build_completed)
    # The phased projects (the road by the hexes): the distribution of the labour is done by build_manager itself,
    # and the effect of each completed segment is applied by main_map.
    build_manager.project_manager = project_manager
    project_manager.step_completed.connect(_on_project_step_completed)
    project_manager.project_completed.connect(_on_project_completed)
    project_manager.project_cancelled.connect(_on_project_cancelled)
    city_button.gui_input.connect(_on_city_button_gui_input)

    # The signals from ExpansionManager
    expansion_manager.expansion_mode_changed.connect(_on_expansion_mode_changed)
    expansion_manager.territory_expanded.connect(_on_territory_expanded)

    menu_button.pressed.connect(_on_menu_button_pressed)

    _setup_research_hud()
    _setup_era_advance_ui()

# The predicate for rebuild_roads_from_existing: this hex is skipped
# on the restoration of the road network.
#
# The reason is one — the road to an improvement, built by a phased project. Its
# state lies in road_built/road_level on the already connected hexes and in
# the queue of the projects, and the recalculation "by the fact of the improvement" (rebuild_
# roads_from_existing) would finish the rest for free, and after the cancellation of the road
# would return it entirely. Such hexes are restored by rebuild_player_roads by
# the flags — exactly the same way as the road built by the special action
# "Build a road".
func _skip_improvement_road_restore(row: int, col: int) -> bool:
    if row < 0 or row >= tile_data.size() or col < 0 or col >= tile_data[row].size():
        return false
    var tile = tile_data[row][col]
    return tile != null and bool(tile.get("road_staged", false))

# Builds the road networks of the towns: from the centre of each town — to its improvements
# in the influence ring, by the same rules as the roads of the city of the player (see
# road_manager.rebuild_town_roads). The networks of the towns are NOT connected to the network of
# the city of the player and to each other.
#
# It is called from two places, and both — strictly after the improvements stand in the rings
# (they are placed by town_manager._place_decorative_town_improvements):
#   - a new game: after road_manager.initialize() in _ready;
#   - loading a save: after the restoration of the towns and their improvements.
# The roads are not saved — the network is recalculated, as well as the city ones.
func _rebuild_town_roads() -> void:
    road_manager.rebuild_town_roads(town_manager.towns, tile_data, map_rows, map_cols)
    # The roads built by the player through the special action "Build a road"
    # (including the connections with the towns) are restored last: their target is the
    # road network of the city, which must already exist. The input data (the flags
    # road_built / road_linked) lie in the save, the segments are counted anew — as for all the other roads.
    road_manager.rebuild_player_roads(tile_data, map_rows, map_cols,
            _road_hex_allowed())

func _input(event):
    # The debug menu: opening/closing on F9
    if event is InputEventKey and event.pressed and event.keycode == KEY_F9:
        debug_manager.toggle()
        get_viewport().set_input_as_handled()
        return

    # ESC closes the debug menu, if it is open
    if debug_manager.is_open:
        if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
            debug_manager.close()
            get_viewport().set_input_as_handled()
            return
        # The hotkeys of the items of the debug menu: the digit 1..9, 0 calls
        # the corresponding item of the main menu (see debug_manager.trigger_hotkey).
        if event is InputEventKey and event.pressed:
            var num = _debug_hotkey_number(event.keycode)
            if num >= 0:
                debug_manager.trigger_hotkey(num)
                get_viewport().set_input_as_handled()
                return
        input_handler.handle_input(event)
        return

    input_handler.handle_input(event)

# Returns the digit for the debug hotkey by the key code, or -1, if the key
# is not a digit (the main row + the keyboard digit 0).
func _debug_hotkey_number(keycode: Key) -> int:
    match keycode:
        KEY_1: return 1
        KEY_2: return 2
        KEY_3: return 3
        KEY_4: return 4
        KEY_5: return 5
        KEY_6: return 6
        KEY_7: return 7
        KEY_8: return 8
        KEY_9: return 9
        KEY_0: return 0
    return -1

func _process(delta):
    if Engine.is_editor_hint():
        return

    # We block the buttons of the HUD, if the game is paused.
    var is_paused = get_tree().paused
    if research_button:
        research_button.disabled = is_paused
    if city_button:
        city_button.disabled = is_paused
    if expansion_button:
        expansion_button.disabled = is_paused

    # The science accumulates every frame, and is not bound to the tick of the simulation.
    # Without this the progress bar of the research jumped by jerks.
    if not is_paused:
        CityData.tick_research_science_continuous(delta)
        # The occupancy of the pastures — the same thing: it accumulates every frame, so that
        # the progress bar of the occupancy moves smoothly, and not by a jump once per tick.
        _tick_pasture_fill(delta)

    # We advance the "era" of the display of the resources: the places where the resources are shown
    # (the tab "Resources", the top bar, the resource tooltips) are updated with
    # the interval from the settings, and not on every tick. On the pause of the tree _process does
    # not go — the interval is counted in the game time (see CityData).
    CityData.tick_resource_display(delta)

    # The tooltip of the breakdown of the treasury by the sources of income/expense: polling + the sticking
    # (the logic repeats city_ui.gd — there the same thing for the tooltip over
    # TopFoodLabel; a single rhythm, a single delay building_detail_delay).
    var mouse_pos_now: Vector2 = get_viewport().get_mouse_position()
    var hovered_treasury := _is_treasury_hovered(mouse_pos_now)
    var hovered_treasury_label := _is_treasury_label_hovered(mouse_pos_now)
    if hovered_treasury:
        _treasury_hover_leave_timer = 0.0
        if hovered_treasury_label and not _treasury_locked:
            _treasury_hover_timer += delta
            if _treasury_hover_timer >= building_detail_delay:
                _treasury_locked = _show_treasury_tooltip(mouse_pos_now)
    else:
        _treasury_hover_timer = 0.0
        # The cursor has left the label and the tooltip: we hold the "stuck" panel for
        # the grace window (the transition of the cursor onto the tooltip itself must not blink), then
        # we remove the sticking and hide it. NOT return — below is the tick of the simulation.
        _treasury_hover_leave_timer += delta
        if not _treasury_locked or _treasury_hover_leave_timer >= MAP_TOOLTIP_LEAVE_GRACE:
            _treasury_hover_leave_timer = 0.0
            _treasury_locked = false
            _map_ui_helpers.hide_treasury_tooltip()

    # The tick of the simulation of the towns: every discovered town adds its per-tick
    # rate to its warehouse. It runs on its OWN clock, several times slower than the
    # one of the city (town_tick_ticks × CityData.SIMULATION_TICK), therefore the
    # accumulator lives here, outside the block of the city tick below, and not inside
    # it — the town would otherwise only tick while the city happens to tick.
    var town_tick := TownManager.get_town_tick_seconds()
    town_timer += delta
    if town_timer >= town_tick:
        town_timer -= town_tick
        town_manager.tick_towns(tile_data)
        # The open window shows the stock of the sale column. It is refreshed HERE
        # and not from town_storage_changed, because the tick writes units off every
        # town on the map at once, and only one of them can be on screen.
        if town_ui.visible and town_ui.has_town:
            town_ui.refresh_storage()

    production_timer += delta
    if production_timer >= CityData.SIMULATION_TICK:
        production_timer -= CityData.SIMULATION_TICK
        # We rebuild from scratch: the tick below will fill the list with the actual growing
        # pastures, and the frame-by-frame advance goes on in _tick_pasture_fill().
        _growing_pastures = {}
        _has_growing_pastures = false
        CityData.reset_counters()
        for row in range(region_start_row, region_end_row + 1):
            for col in range(region_start_col, region_end_col + 1):
                var tile = tile_data[row][col]
                if tile.improvement == null:
                    continue
                if bool(tile.get("decorative", false)) or not worker_manager.has_worker(row, col):
                    # A decorative or a paused improvement transports nothing: there is no
                    # road-capacity problem to warn about.
                    tile["road_capacity_short"] = false
                    continue
                # The road to the city caps the throughput (see the clamp in the production
                # below). The warning triangle over the improvement is driven by the SAME check
                # as the red "(route X units/sec)" note in the tooltip and the panel, so the
                # badge and the note cannot disagree.
                tile["road_capacity_short"] = not map_tooltip.road_capacity_shortfall(
                        row, col, tile_data).is_empty()
                var route_avg_speed := _route_avg_speed(row, col)
                # The production goes both from the natural resource (tile.resource), and from
                # the bred one (tile.crop_bred, see the breeding scheme). If both are
                # null — there is nothing to produce on the hex.
                var eff_res = MapHelpers.get_effective_resource(tile)
                if eff_res == "":
                    # A forest plot on an empty forest hex: there is no resource, but
                    # the cover gives wood (wood_yield > 0 in covers.json).
                    # The output = wood_yield × the multipliers of the improvement and the profession.
                    # The future covers with wood_yield > 0 will be picked up automatically.
                    if tile.improvement == "lumberjack_hut":
                        var wood_yield: float = MapHelpers.get_cover_wood_yield(tile)
                        if wood_yield > 0.0:
                            var lj_consumption_mult: float = worker_manager.tick_consumption(
                                row, col, CityData.SIMULATION_TICK)
                            var lj_imp_mult: float = CityData.get_improvement_production_multiplier(
                                "lumberjack_hut", _is_hex_irrigated(row, col),
                                tile.get("terrain", ""), "lumberjack_hut")
                            # The identifier of the improvement — the source of the income/expense (the label
                            # is resolved by ui_helpers by the id, see
                            # GameData.get_source_display_name).
                            var lj_source = GameData.improvement_source_id("lumberjack_hut")
                            # --- THE CONTINUOUS PRODUCTION OF THE FOREST PLOT ---
                            # Instead of the batch release once per production_interval,
                            # on every tick we add to the storage (wood_yield ×
                            # the multipliers) / production_interval units. The fractional
                            # remainder accumulates in tile.production_fractional_remainder,
                            # so that the average rate does not drift.
                            var lj_interval := CityData.get_improvement_production_interval("lumberjack_hut")
                            var lj_per_sec: float = 0.0
                            if lj_interval > 0.0:
                                lj_per_sec = (wood_yield * lj_imp_mult * lj_consumption_mult) / lj_interval
                            # The road to the city caps the throughput: only what the route's
                            # average speed allows arrives, the excess is lost.
                            if route_avg_speed >= 0.0 and lj_per_sec > route_avg_speed:
                                lj_per_sec = route_avg_speed
                            var lj_remainder: float = float(tile.get("production_fractional_remainder", 0.0)) + lj_per_sec * CityData.SIMULATION_TICK
                            var lj_floor: int = int(floor(lj_remainder))
                            tile["production_fractional_remainder"] = lj_remainder - float(lj_floor)
                            if lj_floor > 0:
                                CityData.add_to_storage("wood", lj_floor)
                                CityData.record_production_source("wood", lj_source, lj_floor)
                            # The planned release of the cycle: it is visible on every tick, while
                            # the worker is in place (it closes the gaps between the cycles).
                            CityData.record_planned_improvement_production("wood", lj_source,
                                int(ceil(wood_yield * lj_imp_mult * lj_consumption_mult)), lj_interval)
                    continue

                # The occupational consumption: the improvements which have a consumption
                # through a profession (the consumption of the product) write off
                # the resource by their own interval. The timer advances BY THE STEP OF THE TICK
                # of the simulation on every tick (a departure from "one tick, to rule
                # over all"): the accuracy is ±1 sec on the intervals of 10+ sec. The call
                # is OBLIGATORY for any hex with a worker — otherwise the timer of the
                # consumption does not advance and the bonus of the profession "freezes".
                
                # It returns the total multiplier of the production: 1.0 without the bonus,
                # 1.0+bonus while the resource is there. The improvement does NOT stop on a shortage —
                # it simply works at the base.
                var consumption_multiplier: float = worker_manager.tick_consumption(
                    row, col, CityData.SIMULATION_TICK)

                var res_data = GameData.raw_resources.get(eff_res, {})
                var feed_needed = res_data.get("feed_consumption", 0)
                var production_multiplier = 1.0
                if tile.improvement != null:
                    # We pass terrain_id and resource_id for the modifiers by
                    # the terrain (for example, the bitumen on the asphalt lake x2).
                    production_multiplier = CityData.get_improvement_production_multiplier(
                        tile.improvement, _is_hex_irrigated(row, col),
                        tile.get("terrain", ""), eff_res)

                # We apply the bonus of the occupational consumption (for example,
                # +50% to the production of fish, while there are reed boats).
                # The multiplier comes from worker_manager.tick_consumption();
                # it is equal to 1.0 without the bonus or with a shortage of the supplies.
                production_multiplier *= consumption_multiplier

                # The growing resources (time_to_mature > 0): while the pasture is filling up,
                # the output is proportional to the degree of the occupancy. The filling itself
                # is advanced FRAME BY FRAME in _tick_pasture_fill() (a smooth bar),
                # here we only collect the list of the growing pastures and cut the output.
                if MapHelpers.is_growing_resource(res_data):
                    if float(tile.get("fill_time", 0.0)) < float(res_data["time_to_mature"]):
                        # The key "row,col" — so that the duplicates do not accumulate between the ticks.
                        _growing_pastures[str(row) + "," + str(col)] = {"row": row, "col": col}
                    production_multiplier *= MapHelpers.get_fill_fraction(tile, res_data)

                # The quality of the resource on the hex is passed into the production.
                var tile_quality = tile.get("quality", "common")
                # The identifier of the improvement — the source of the income/expense in the plan
                # (the label is resolved by ui_helpers, see
                # GameData.get_source_display_name).
                var improvement_source = GameData.improvement_source_id(str(tile.improvement))
                # --- THE CONTINUOUS PRODUCTION OF AN IMPROVEMENT ---
                # Instead of the batch release once per production_interval, on every
                # tick we add to the storage (amount_per_cycle × production_multiplier)
                # / production_interval units of the product. The fractional remainder
                # accumulates in tile.production_fractional_remainder, so that the average
                # rate does not drift.
                #
                # The feed (feed_consumption) was previously written off for a WHOLE cycle
                # (once per production_interval). In the continuous model — a little
                # bit on every tick: feed_per_sec = feed_needed / production_interval.
                # If there is not enough feed, the production is cut to 25% on this
                # tick (an analogue of the old logic "no feed → 0.25×").
                var imp_interval := CityData.get_improvement_production_interval(tile.improvement)
                var produces: Dictionary = res_data.get("produces", {})
                var feed_per_sec: float = 0.0
                if feed_needed > 0 and imp_interval > 0.0:
                    feed_per_sec = float(feed_needed) / imp_interval

                if feed_needed > 0:
                    var feed_consumed: int = _consume_feed_continuous(tile, feed_per_sec, improvement_source)
                    var actual_mult: float = production_multiplier if feed_consumed >= feed_per_sec * CityData.SIMULATION_TICK else 0.25
                    _emit_continuous_production(tile, produces, actual_mult, imp_interval, tile_quality, improvement_source, route_avg_speed)
                else:
                    _emit_continuous_production(tile, produces, production_multiplier, imp_interval, tile_quality, improvement_source, route_avg_speed)

                # The planned release/consumption of the cycle: they are visible on EVERY tick, while
                # the worker is in place (they close the gaps between the cycles on the tab
                # "Resources" — the same "blind windows" as for the recipes of the buildings).
                for planned_pid in GameData.raw_resources.get(eff_res, {}).get("produces", {}):
                    if not CityData.is_product_available(planned_pid):
                        continue
                    var planned_amount := 0
                    if feed_needed > 0 and CityData.city_storage.get("feed", 0) < feed_needed:
                        planned_amount = int(ceil(float(RangeUtils.get_min_value(res_data["produces"][planned_pid], 1)) * 0.25))
                    else:
                        planned_amount = int(ceil(float(RangeUtils.get_min_value(res_data["produces"][planned_pid], 1)) * production_multiplier))
                    CityData.record_planned_improvement_production(planned_pid, improvement_source, planned_amount, imp_interval)
                if feed_needed > 0:
                    CityData.record_planned_improvement_consumption("feed", improvement_source, feed_needed, imp_interval)

        CityData.do_tick()
        # The consumption of the city of the pseudo-profession "all" (all the citizens of the city,
        # including the employed ones): it writes off the resources per head by total_population
        # by the common city timer (see worker_manager.tick_city_consumption).
        # It gives no bonus to the production — a test of the infrastructure.
        worker_manager.tick_city_consumption(CityData.SIMULATION_TICK)
        # tick_research_science is called every frame below (see _process),
        # and not bound to the tick of the simulation. This gives a smooth progress bar.

    _update_research_progress()
    # We redraw the layer of the progress bars ONLY when there is something to show:
    # a research is going, there are active builds (including the steps of the phased
    # projects — they are counted by has_active_builds) or the scouting is going. Otherwise
    # the layer is light and its _draw() draws nothing — there is no reason to call
    # queue_redraw() every frame. When the construction/research/scouting
    # has finished/started, the corresponding handlers call
    # _redraw_progress_layer() (see below), so that the layer is guaranteed to be
    # updated and does not remain hanging at 100% or showing the outdated bars.
    if CityData.current_research_tech_id != "" \
            or build_manager.has_active_builds() \
            or is_scouting \
            or _has_growing_pastures:
        progress_bar_layer.queue_redraw()

    input_handler.handle_process(delta)

    if is_scouting:
        scouting_timer += delta
        if scouting_timer >= _get_scouting_time(scouting_chunk.size()):
            _complete_scouting()

func _tick_pasture_fill(delta: float):
    if _growing_pastures.is_empty():
        return
    var had_growing := true
    var still_growing := {}
    for key in _growing_pastures:
        var entry: Dictionary = _growing_pastures[key]
        var row: int = entry["row"]
        var col: int = entry["col"]
        # We check the actuality: the improvement may have been demolished, the worker — removed.
        var tile = tile_data[row][col]
        if tile.improvement == null or bool(tile.get("decorative", false)) \
                or not worker_manager.has_worker(row, col):
            continue
        var res_data = GameData.raw_resources.get(MapHelpers.get_effective_resource(tile), {})
        if not MapHelpers.is_growing_resource(res_data):
            continue
        var ttm = float(res_data["time_to_mature"])
        var fill_time = float(tile.get("fill_time", 0.0))
        if fill_time >= ttm:
            continue
        tile["fill_time"] = minf(fill_time + delta, ttm)
        still_growing[key] = entry
    _growing_pastures = still_growing
    _has_growing_pastures = not still_growing.is_empty()
    # We redraw while it is growing; the final frame — so as to erase the bar,
    # when the last pasture has filled up (otherwise the bar hangs on the screen).
    if _has_growing_pastures or had_growing:
        progress_bar_layer.queue_redraw()

# --- THE CONTINUOUS PRODUCTION: THE HELPERS ---
# The functions moved out for the block "THE CONTINUOUS PRODUCTION OF AN IMPROVEMENT" in _process.
# These functions encapsulate the work with the sub-unit accumulator and with the write-off of the feed,
# so that the main cycle of the production stays compact and readable.

# Writes off the feed continuously: feed_per_sec units/sec. The fractional remainder
# accumulates in tile.feed_fractional_remainder. It returns how many units
# of the feed managed to be written off for the tick (0, if there is nothing in the storage).
#
# On a shortage of the feed: EVERYTHING that is in the storage is written off (within the
# limits of the accumulated remainder). If even partially it was not enough — the production
# is cut to 0.25 in the calling code.
func _consume_feed_continuous(tile: Dictionary, feed_per_sec: float, improvement_source: String) -> int:
    if feed_per_sec <= 0.0:
        return 0
    var remainder: float = float(tile.get("feed_fractional_remainder", 0.0)) + feed_per_sec * CityData.SIMULATION_TICK
    var floor_amount: int = int(floor(remainder))
    tile["feed_fractional_remainder"] = remainder - float(floor_amount)
    if floor_amount <= 0:
        return 0
    var available := int(CityData.city_storage.get("feed", 0))
    if available <= 0:
        return 0
    var take = mini(available, floor_amount)
    CityData.remove_from_storage("feed", take, "best")
    CityData.record_consumption_source("feed", improvement_source, take)
    return take

# The continuous production of an improvement: on every tick it adds to the storage
# (amount_per_cycle × production_multiplier) / production_interval units
# of the product. The fractional remainder accumulates in tile.production_fractional_remainder,
# so that the average rate does not drift.
#
# production_multiplier can be < 1.0 (for example, 0.25 on a shortage of the feed)
# or > 1.0 (the bonus of the profession). The zero values are skipped, so as not to
# breed the zero records in the sources.
#
# route_avg_speed is the average speed of the route to the city, or -1.0 when there is no
# route. It is the throughput of the road in units/sec: each product is capped by it, and the
# excess above the cap is LOST (the road simply cannot carry more). The products of one
# improvement are capped independently, because the improvement may output different products
# at different rates.
func _emit_continuous_production(tile: Dictionary, produces: Dictionary, production_multiplier: float, imp_interval: float, tile_quality: String, improvement_source: String, route_avg_speed: float = -1.0) -> void:
    if produces.is_empty() or imp_interval <= 0.0:
        return
    var tick := float(CityData.SIMULATION_TICK)
    for pid in produces:
        if not CityData._is_product_available(pid):
            continue
        var per_cycle_amt := float(RangeUtils.get_min_value(produces[pid], 1))
        var per_sec_amt: float = per_cycle_amt * production_multiplier / imp_interval
        if route_avg_speed >= 0.0 and per_sec_amt > route_avg_speed:
            per_sec_amt = route_avg_speed
        var remainder: float = float(tile.get("production_fractional_remainder", 0.0)) + per_sec_amt * tick
        var floor_amount: int = int(floor(remainder))
        tile["production_fractional_remainder"] = remainder - float(floor_amount)
        if floor_amount > 0:
            CityData.add_to_storage(pid, floor_amount, tile_quality)
            CityData.record_production_source(pid, improvement_source, floor_amount)

func _initialize_map():
    GameData.load_all_data()
    var selected_city_name = CityData.city_name
    CityData.setup()
    CityData.city_name = selected_city_name
    map_renderer.load_icons()

    # We set the starting sizes of the Ring and the Region from the configuration.
    ring_rows = start_ring_rows
    ring_cols = start_ring_cols
    region_rows = ring_rows + region_width * 2
    region_cols = ring_cols + region_width * 2
    _recalculate_bounds()

    # We remember the starting boundaries (the Ring + the visible window). They are needed for
    # the guarantees of the spawn of the resources, so that the metal and food_plant do NOT appear beyond
    # the initially visible area even after the expansion to a new era.
    start_influence_start_row = influence_start_row
    start_influence_end_row = influence_end_row
    start_influence_start_col = influence_start_col
    start_influence_end_col = influence_end_col
    start_region_start_row = region_start_row
    start_region_end_row = region_end_row
    start_region_start_col = region_start_col
    start_region_end_col = region_end_col

    # We generate the WHOLE map of the world at once (the relief, the cover, the rivers).
    var generator = load("res://scripts/map_generator.gd").new()
    # The number of the Voronoi centres for each terrain type is computed
    # from the configuration terrain_config (density + target_cluster),
    # set in data/map_config.json.
    var terrain_counts = generator.make_terrain_counts(map_rows, map_cols)
    tile_data = generator.generate_map(map_rows, map_cols, city_row, city_col, GameData.raw_resources, terrain_counts)
    print("The map of the world has been generated. Hexes: ", map_rows * map_cols)

    # We guarantee that the city is on a permitted terrain (a plain or the hills)
    _ensure_city_valid_terrain()

    # We mark the starting Influence Ring and reset the research.
    # The flags are set for the WHOLE map, because the generators (place_wild_food and so on)
    # iterate over all the hexes and refer to "in_influence".
    for row in range(map_rows):
        for col in range(map_cols):
            var tile = tile_data[row][col]
            tile["in_influence"] = is_in_influence(row, col)
            tile["is_explored"] = false

    # We collect the hexes of a unique terrain (for example, a soda lake).
    # They are displayed on the map even beyond the visible Region
    # (see map_renderer._draw), therefore we store them in a separate list.
    unique_terrain_hexes = []
    for row in range(map_rows):
        for col in range(map_cols):
            var terrain_id = tile_data[row][col].get("terrain", "plain")
            var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
            if t_data.get("unique", false):
                unique_terrain_hexes.append({"row": row, "col": col})

    # The hexes of the towns and of the influence ring are mirrored AFTER town_manager.generate_towns
    # below (it itself calls compute_all_town_influences at the end, see the script town_manager).
    # Here we do not mirror anything yet: the master copies are still empty.

    # The wild plants and the guaranteed food_plant spawn ONLY once at the
    # start of a new game and ONLY inside the starting Influence Ring.
    # We pass the explicit boundaries of the starting Ring, so that these functions never
    # go beyond its limits (even if the Ring expands later).
    _ensure_food_plant(influence_start_row, influence_end_row, influence_start_col, influence_end_col, city_row, city_col)
    generator.place_wild_food(tile_data,
            influence_start_row, influence_end_row, influence_start_col, influence_end_col,
            city_row, city_col)

    # The resources which occur in the Influence Ring are not duplicated in the Region.
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

    # --- The guarantees for the starting area "Ring + Region" ---
    # We use the starting boundaries (and not the current ones), so that on a future
    # expansion to a new era it does not fire again. At the moment in the game
    # the only metal is the iron; when adding a new one the function will choose
    # one of them at random. The same for the other categories below.
    #
    # The food plant is guaranteed separately (see _ensure_food_plant above)
    # and remains ONLY in the starting Ring — the player must have the possibility
    # to put a farm immediately without the scouting/buying of the region.
    _ensure_minimum_resource({"category": "metals"})
    _ensure_minimum_resource({"category": "minerals", "subgroup": "construction_materials"})

    # --- The post-processing: we guarantee a sufficient number of FREE hexes ---
    # After the placement of all the resources of each terrain type in the Influence Ring
    # there must remain at least FREE_TERRAIN_HEXES free (resource == null)
    # hexes. This excludes a soft-lock: if a resource (for example, quinoa — only the mountains)
    # has got into the ring, the player will always have a place for the additional farms/pastures.
    # The method converts ONLY the free hexes and NEVER destroys the resources.
    generator.ensure_free_terrain_hexes(tile_data, terrain_counts,
            influence_start_row, influence_end_row, influence_start_col, influence_end_col,
            city_row, city_col)

    # We use a LOCAL generator of random numbers for the choice of the icon of the landscape.
    # Under no circumstances may seed()/randomize() be called on the global RNG inside
    # this loop — it would destroy the randomness of all the subsequent randf()/randi()
    # (for example, on the spawn of the resources after the learning of the technologies).
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

    # We generate the river system (the main rivers + the tributaries) over the whole map
    # and mark the river edges in the data of the hexes. We pass tile_data (for the mountains/lakes)
    # and the boundaries of the starting area "Ring + Region" (the guarantee of the intersection).
    river_manager.generate_rivers(map_rows, map_cols, HEX_RADIUS, tile_data,
            region_start_row, region_end_row, region_start_col, region_end_col)
    river_manager.mark_river_edges(tile_data, map_rows, map_cols, HEX_RADIUS, river_manager.get_cached_graph())

    # --- The towns (the small settlements) ---
    # They are placed AFTER the rivers, so that river_edges have already been set and
    # are used as the points of attraction (priority 2). The number and the priorities
    # of the points of attraction are in data/map_config.json, the section "num_towns".
    # The details are in scripts/town_manager.gd.
    #
    # We pass two areas:
    #   exclusion_* — the starting visible area (the Ring + the starting Region).
    #     Inside it the towns do NOT spawn, otherwise they would be visible from the very
    #     beginning of the game and the sense of "the small unknown settlements" would be lost.
    #   era2_region_* — the visible area of the 2nd era (Ring_2 + Region_2).
    #     This is the "mandatory zone" for the guarantee: at least 1 town must
    #     get there, so that on the transition to the 2nd era the player can immediately
    #     see someone and start trading.
    var era2_region_bounds: Dictionary = _compute_era2_region_bounds()
    town_manager.generate_towns(tile_data, map_rows, map_cols, city_row, city_col,
            start_region_start_row, start_region_end_row,
            start_region_start_col, start_region_end_col,
            era2_region_bounds.start_row, era2_region_bounds.end_row,
            era2_region_bounds.start_col, era2_region_bounds.end_col)

    # The mirrors town_hexes / town_influence_hexes are built ONLY AFTER generate_towns:
    # town_manager calls compute_all_town_influences at the end of generate_towns,
    # and only after that both master copies contain the data. Previously the mirror
    # stood higher (around the line 650), but in that place town_manager.town_hexes
    # was still empty — and the mirror silently copied the emptiness. Because of this the rings
    # of influence were not displayed at all on a new game.
    town_hexes = []
    for h in town_manager.town_hexes:
        town_hexes.append({"row": h.row, "col": h.col})
    town_influence_hexes = []
    for h in town_manager.town_influence_hexes:
        town_influence_hexes.append({"row": h.row, "col": h.col})
    # The full records of the towns — a reference to the master list of the manager (and not a snapshot):
    # the renderer reads the per-town rings and the colours, and any future edits in
    # town_manager are immediately reflected on the map without a repeated mirroring.
    towns = town_manager.towns

    # The final guarantee: on the hex of the city there should be no resource, and the terrain
    # must be a permitted one (plain or hill). It is a safety-net for the case,
    # if some function of the spawn of the resources or of the conversion of the terrain
    # has missed the check of the coordinates of the city.
    _ensure_city_hex_clean()
    # We mark the hex of the city with the flag is_city — the logic of the water (MapHelpers) counts
    # it as a conductor/source, when the water is really brought to the city.
    _mark_city_hex()

func _mark_city_hex() -> void:
    if city_row >= 0 and city_row < map_rows and city_col >= 0 and city_col < map_cols:
        tile_data[city_row][city_col]["is_city"] = true

func _ensure_city_valid_terrain() -> void:
    MapHelpers.ensure_city_valid_terrain(tile_data, city_row, city_col, map_rows, map_cols)

func _is_hex_irrigated(row: int, col: int) -> bool:
    return MapHelpers.is_hex_irrigated(row, col, tile_data, map_rows, map_cols)

func _ensure_minimum_resource(filter: Dictionary):
    # The guarantee works by the STARTING boundaries "Ring + Region", and not by the
    # current ones (which can be expanded by a transition to a new era).
    # It is used on the initialization of the map, so that in the starting area
    # there is always at least one resource satisfying the filter.
    # Examples of the filters:
    #   { "category": "metals" }                                          — any metal
    #   { "category": "animals", "group": "meat_animals" }                — a meat animal
    #   { "category": "minerals", "subgroup": "construction_materials" }  — a construction material
    MapHelpers.ensure_minimum_resource(
        tile_data, filter,
        start_influence_start_row, start_influence_end_row,
        start_influence_start_col, start_influence_end_col,
        city_row, city_col
    )

# Guarantees the presence of at least one resource from food_plants in the starting Ring.
# It is called ONLY once at the start of a new game (from _initialize_map).
# The boundaries (min_row..max_row, min_col..max_col) are the starting Ring,
# therefore the food_plant is guaranteed not to appear beyond its limits
# and is not recreated after the start.
func _ensure_food_plant(min_row: int, max_row: int, min_col: int, max_col: int, city_row: int = -1, city_col: int = -1):
    MapHelpers.ensure_food_plant(tile_data, min_row, max_row, min_col, max_col, city_row, city_col)

# The final safety-check: it guarantees that on the hex of the city there is no resource
# and the terrain is valid. It is called after all the stages of the generation of the map.
func _ensure_city_hex_clean() -> void:
    var city_tile = tile_data[city_row][city_col]
    if city_tile.get("resource", null) != null:
        print("WARNING: a resource was standing on the hex of the city '", city_tile["resource"], "' — it has been removed.")
        city_tile["resource"] = null
    _ensure_city_valid_terrain()

# Looks on the map for an already domesticated instance of the resource res_id (a hex with this resource
# and a built improvement — a farm/pasture) and returns its quality.
# It is used on the breeding of a new animal/plant on an empty hex:
# the quality is inherited from the already domesticated specimen
# ("exceptional produces exceptional"). If there is no such specimen —
# it returns an empty string, and the calling code generates the quality through roll.
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
    # The insurance of the public entry point: for a hex in the fog of war the tooltip is not
    # filled in at all (the main gate is in InputHandler._handle_mouse_motion,
    # where the foggy hex does not become "hovered" at all). Otherwise after
    # the hover delay a tooltip with the contents of the previous hex would float up.
    if is_hex_in_fog(row, col):
        return
    map_tooltip.update_tooltip_text(row, col, tile_data, city_row, city_col)

# Returns the id of the improvement which can be built on the hex (row, col),
# or an empty string, if the construction is impossible.
func _get_buildable_improvement(row: int, col: int) -> String:
    return MapHelpers.get_buildable_improvement(tile_data[row][col])

# Returns true, if for the hex the extended tooltip has to be shown (the properties of
# the hex, the production, the consumption, the road level). The conditions are not listed
# here: they are asked of the same assembler, which builds the block itself, — see
# MapTooltip.has_extended_tooltip_info.
func has_extended_tooltip_info(row: int, col: int) -> bool:
    return map_tooltip.has_extended_tooltip_info(row, col, tile_data)

func update_extended_tooltip(row: int, col: int):
    map_tooltip.update_extended_tooltip(row, col, tile_data, city_row, city_col)

# Resets the binding of the extended block of the tooltip to the hex (see
# MapTooltip.clear_extended_tooltip). It is called on a change of the hex and on the hiding of
# the tooltip — otherwise the return to the same hex would draw the extended block immediately,
# bypassing the hover delay.
func clear_extended_tooltip():
    map_tooltip.clear_extended_tooltip()

# Chooses the icon of the landscape for the hex (row, col) based on its terrain.
func _assign_terrain_icon(row: int, col: int) -> void:
    tile_data[row][col]["terrain_icon"] = MapHelpers.get_terrain_icon(row, col, tile_data)

# Requests the redrawing of the layer of the progress bars. It is called at the start/completion of
# the construction, the research and the scouting, when the layer may change, but
# _process (_active) will no longer trigger the redraw (for example, because of
# the completion of the last build). Otherwise the last frame with a bar filled to 100%
# would remain on the screen forever.
func _redraw_progress_layer():
    if progress_bar_layer:
        progress_bar_layer.queue_redraw()

# The public wrapper for the redrawing of the layer of the progress bars (it is used by
# by the control panel control_panel.gd after the confirmation of the construction).
func redraw_progress_layer():
    _redraw_progress_layer()

# Selects the hex (row, col) on a click of the LMB: it highlights it on the map and
# shows the information/actions in the control panel.
func select_hex(row: int, col: int):
    control_panel.select_hex(row, col)
    map_renderer.queue_redraw()

# Removes the selection from the hex and clears the control panel.
func clear_selection():
    control_panel.clear_selection()
    map_renderer.queue_redraw()

# The handler of the completion/cancellation/pause of a build: it updates the control panel,
# so that it does not show the outdated state (for example, the "Build" button
# on the hex where the build has already finished).
func _on_control_panel_build_changed(_a = null, _b = null, _c = null, _d = null):
    control_panel.refresh()

# The public wrapper over _confirm_cancel_build for the control panel.
func confirm_cancel_build(row: int, col: int):
    _confirm_cancel_build(row, col)

# The cancellation of a phased project to the hex (row, col) — for example, an unfinished
# road. The confirmation dialog is the same as for an ordinary build: the cancellation
# is irreversible, and the already laid segments of the road remain on the map.
# The cancellation of a phased project. It is called from ANY of its hexes, therefore the project
# is passed by project_id, and not searched by the coordinates: the hex on which
# the player clicked may be the middle of the route, and not the target.
#
# The cancellation of a phased project to the hex (row, col) — for example, an unfinished
# road. The confirmation dialog is the same as for an ordinary build: the cancellation
# is irreversible, and the already laid segments of the road remain on the map.
# The cancellation of a phased project. It is called from ANY of its hexes, therefore the project
# is passed by project_id, and not searched by the coordinates: the hex on which
# the player clicked may be the middle of the route, and not the target.
func confirm_cancel_project(project_id: String):
    if project_manager == null or project_id == "":
        return
    var project: Dictionary = project_manager.get_project(project_id)
    if project.is_empty():
        return
    var steps: Array = project.get("steps", [])
    var done := int(project.get("step_index", 0))
    var left := maxi(0, steps.size() - done)
    var title := str(project.get("title", tr("Construction")))

    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel construction")
    var text := tr("Cancel \"%s\"?\n\n") % title
    if left > 0:
        # The confirmation dialog is the same as for an ordinary build: the cancellation is irreversible,
        # and the already laid segments of the road remain on the map.
        var progress := 0.0
        var step_cost := 0.0
        if done < steps.size():
            var cur: Dictionary = steps[done]
            progress = float(cur.get("progress", 0.0))
            step_cost = float(cur.get("work_cost", 0.0))
        text += tr("Unfinished sections: %d. Work spent on them (%.0f/%.0f) will be lost.\n\n") % [
            left, progress, step_cost,
        ]
    if done > 0:
        text += tr("Already built sections (%d) will stay on the map.") % done
    dialog.dialog_text = text
    dialog.get_ok_button().text = tr("Yes")
    var was_paused = get_tree().paused
    get_tree().paused = true
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS

    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        if project_manager.cancel_project(str(project.get("id", ""))):
            hud.show_message(tr("Construction cancelled"))
        _refresh_project_ghost()
        _redraw_progress_layer()
    )
    add_child(dialog)
    dialog.popup_centered()
        # We take the labour from the CURRENT step of the project, and not from get_step_progress_at by
        # the clicked hex: there an empty dictionary is returned, if the player did not click
        # on the hex of the progress bar, and the lost labour would come out as zero.
    dialog.visibility_changed.connect(func():
        if not dialog.visible and not was_paused:
            get_tree().paused = false
    )

func _on_build_completed(row: int, col: int, imp_id: String, target_res_id = null):
    var tile = tile_data[row][col]

    # The AcceptDialog has no signal canceled: the closing of the window by the cross simply
    # hides the dialog. We unpause in this case as well.
    if GameData.special_actions.has(imp_id):
        var sa = GameData.special_actions[imp_id]
        var action_type = sa.get("action_type", "terrain")
        # A special action (the felling of the forest, the gathering of the wild plants, the demolition of the improvements and so on)
        if worker_manager.has_worker(row, col):
            worker_manager.remove_worker(row, col)

        if action_type == "cover":
        # We free the worker, if it has been assigned
            var result_cover = sa.get("result_cover", "none")
            tile.cover = result_cover
        elif action_type == "forage":
            # The felling of the forest: we change only the cover (cover), terrain/resource is not touched.
            # The gathering of a one-off resource (the wild plants, the metal nuggets and so on):
            # we remove the resource from the hex and add the harvest to the storage.
            # The quality of the gathered harvest = the quality of the resource on the hex.
            # The output of the product is taken from the produces field of the RESOURCE (a number or
            # [min, max]) — the parsing/validation is done by RangeUtils.roll_value.
            # The safety-guard: only the one-off resources can be gathered
            # (improved_by == null). If the action somehow got onto
            # an ordinary resource — we give nothing (the resource remains in place).
            var harvest_res_id: String = str(tile.get("resource", ""))
            var harvest_data: Dictionary = {}
            if harvest_res_id != "" and GameData.raw_resources.has(harvest_res_id):
                harvest_data = GameData.raw_resources[harvest_res_id]
            if harvest_res_id != "" and harvest_data.get("improved_by", null) == null:
                var forage_quality = tile.get("quality", "common")
                var res_produces: Dictionary = harvest_data.get("produces", {})
                for prod_id in res_produces:
                    var amount = RangeUtils.roll_value(res_produces[prod_id],
                            tr("produces goods '%s' from resource '%s'") % [prod_id, harvest_res_id], 0)
                    if amount <= 0:
                        continue
                    CityData.add_to_storage(prod_id, amount, forage_quality)
                    hud.show_message(tr("Collected %d %s!") % [amount, GameData.products.get(prod_id, {}).get("name", prod_id)])
                # The resource disappears from the map after the gathering.
                tile.resource = null
        elif action_type == "demolish":
            # The demolition of an improvement: we remove the improvement. The natural tile.resource
            # remains (if it was), and tile.crop_bred is reset —
            # the breeding lives exactly as long as the improvement costs.
            # Otherwise after the demolition the production cycle would start to "produce" a resource,
            # for which there is no improvement any more.
            tile.improvement = null
            tile.crop_bred = null
            # The herd disappears on the demolition — the accumulated occupancy is reset.
            tile["fill_time"] = 0.0
            # The fractional remainder of the production cycle of the demolished improvement — as well.
            tile["production_fractional_remainder"] = 0.0
            tile["feed_fractional_remainder"] = 0.0
        elif action_type == "road":
            # The road is a phased project (project_manager), and not an ordinary build
            # on this hex: its segments are added to the network one by one, until
            # project_manager brings the queue to the end. It cannot get here — the start
            # of the road is intercepted in
            # build_manager.start_build and goes into start_road_project.
            # The branch is left as "do nothing": if the road somehow
            # has got to an ordinary build, the completion
            # simply does not touch the map, and does not fix whatever it is.
            build_manager.remove_build(row, col)
            return
        else:
            # The terrain action (for example, the drainage): we reset the resources and
            # the improvement, clear the cover and crop_bred, so that the hex becomes
            # a clean plain (without the marsh cover).
            tile.resource = null
            tile.improvement = null
            tile.crop_bred = null
            tile.cover = "none"
            tile["fill_time"] = 0.0
            # The fractional remainder of the production cycle of the removed improvement — as well.
            tile["production_fractional_remainder"] = 0.0
            tile["feed_fractional_remainder"] = 0.0

        # We change the terrain type only if result_terrain is set and is not equal to "dont_change".
        var result_terrain = sa.get("result_terrain", "")
        if result_terrain != "" and result_terrain != "dont_change":
            tile.terrain = result_terrain
            _assign_terrain_icon(row, col)

        build_manager.remove_build(row, col)
        map_renderer.queue_redraw()
        _redraw_progress_layer()
        return

    # The improvement is the only thing that has remained after the branch of the special actions. The
    # construction itself is applied by _apply_improvement: the same code is needed by the last step of
    # the project "road → improvement", where the record of the build in build_manager does not
    # exist at all (the improvement lies in the queue of the project, and not in active_builds).
    build_manager.remove_build(row, col)
    _apply_improvement(row, col, imp_id, target_res_id)


# Places the improvement on the hex (row, col): the construction itself, the breeding, the worker and
# the redrawing. It is moved out of _on_build_completed, because the same is done by
# the step of a phased project (see _on_project_step_completed) — the rule "the improvement
# has appeared" must not exist in two forms.
#
# We do NOT build the road here: by this moment its segments have already been passed by the queue (or
# the road is not needed at all). Building it here would mean returning the old scheme
# "the road as a whole and for free".
func _apply_improvement(row: int, col: int, imp_id: String, target_res_id = null) -> void:
    var tile = tile_data[row][col]
    tile.improvement = imp_id
    tile["fill_time"] = 0.0
    # The production cycle of the new improvement starts from zero.
    tile["production_fractional_remainder"] = 0.0
    tile["feed_fractional_remainder"] = 0.0
    if target_res_id != null:
        # Two scenarios:
        # 1) There was ALREADY a natural resource on the hex (tile.resource != null) — we
        #    place the improvement in order to extract it. tile.resource is preserved,
        #    crop_bred remains null. The quality is the current quality of the resource.
        # 2) The hex was empty (tile.resource == null) — this is the breeding. We write
        #    the id of the bred animal/plant into tile.crop_bred, and tile.resource
        #    is NOT touched (it remains null). The quality is inherited from the already
        #    domesticated instance of this same resource, otherwise we throw a roll.
        var was_existing_resource = tile.resource != null
        if was_existing_resource:
            tile.resource = target_res_id
            # The quality of the resource is determined like this:
            # - If there was ALREADY a resource on the hex (an improvement of the existing one) — we preserve
            #   its quality. Otherwise any construction of a farm/mine would reset
            #   quality to "common", because there is no quality field in the JSON of the resources.
            var existing_q = tile.get("quality", "")
            if existing_q == "" or existing_q == null:
                tile["quality"] = GameData.roll_quality()
        else:
            # The breeding on an empty hex: the id of the resource lives in crop_bred.
            # - If this is the breeding of a NEW animal/plant (the hex was empty) —
            #   we look on the map for the already domesticated instance of this resource and
            #   inherit its quality ("exceptional produces exceptional").
            #   If there is none yet — we generate it at random.
            var inherited_quality = _find_domesticated_quality(target_res_id)
            if inherited_quality != "" and inherited_quality != null:
                tile["quality"] = inherited_quality
            else:
                tile["quality"] = GameData.roll_quality()
        if CityData:
            CityData.register_domesticated_resource(target_res_id)
    if not worker_manager.assign_worker(row, col):
        pass
    map_renderer.queue_redraw()
    _redraw_progress_layer()

# === THE PHASED CONSTRUCTION OF THE ROAD (the special action build_road) ===
#
# The road is a project of separate segments, and not one build over the whole route:
# the player confirms the route, it entirely enters the queue (project_manager) and
# is completed one hex at a time. The "ghost" of the route remains on the map until
# of the end, and the built segments disappear from it and become a real
# road.
#
# Previously there was one build over the whole length of the route and a partial payment:
# the player could pay for a part of the route, and the road was completed by adding
# the rest. With the phased approach this has disappeared — for each segment a separate
# step pays, and the unpaid segment simply does not start.

# The special action "Build a road" on the hex (row, col). It is called from
# build_manager.start_build, therefore it returns a bool in its sense.
#
# Here there is only the parsing of the refusal for the player (there is no route, the level is not scouted,
# the limit of the builds is exhausted). The construction itself lives in the common function
# _start_road_project_steps, which is also used by the road to an improvement: the rules of
# them are the same by construction, and not by agreement.
func start_road_project(row: int, col: int, road_level: int) -> bool:
    # The route may disappear between the click of the button and the confirmation (for example,
    # the player managed to build another road) — then we simply report the reason.
    # The steps and the price are taken from get_road_cost_breakdown — the same source as
    # the preview, therefore the start cannot take a different price than what was shown.
    var breakdown: Dictionary = get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        hud.show_message(tr("Failed to build the road: %s") % breakdown.get("reason", tr("no path")))
        return false
    var plan := get_road_plan(row, col)
    var is_town := bool(plan.get("is_town", false))

    # We check the level HERE, and not in the panel: the panel is a display, and
    # the only place where it is decided whether anything can be built at all.
    # The rule itself "the level is unlocked by its own technology" lives in the data and in
    # GameData.is_road_level_unlocked, here we only refuse to build
    # an unscouted level.
    if not GameData.is_road_level_unlocked(road_level):
        hud.show_message(tr("Road level %d requires a technology") % road_level)
        return false

    # The common limit of the simultaneous builds is equal to the number of the citizens. The road takes
    # one slot, and not one per hex: one segment is built at the same time.
    if not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        hud.show_message(tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)")
                % CityData.total_population)
        return false

    var title := tr("Road")
    if is_town:
        var town = find_town_at(row, col)
        if town != null:
            title = tr("Road to town \"%s\"") % str(town.get("name", ""))

    return _start_road_project_steps(row, col, breakdown.get("steps", []),
            int(breakdown.get("cost", 0)), is_town, title, {})

# THE CHAIN ROAD-TO-IMPROVEMENT on the hex (row, col).
#
# It is started from build_manager.start_build, when the improvement is due a road.
# This is ONE phased project and ONE slot: first go the segments of the road, the last
# step — the construction of the improvement itself. The sequence here is not a decoration:
# the materials to the distant hex are carried by the road, and building the improvement while the road
# is not there yet would mean carrying its worker and the construction materials off the roads.
#
# The level of the road the player has chosen in the preview of the construction of the improvement; imp_id and
# target_res_id are needed by the last step (target_res_id — the breeding: the id of the animal
# or the plant which has to be planted on the hex).
#
# A refusal here means the improvement is built in an ordinary way: if the road is not
# needed (the hex is already connected, the improvement with the flag no_road, there is no
# land route), the calling code will not pass the control here, and the improvement will stand as an ordinary
# build. The errors of the level and the limit, on the contrary, are shown by the same rows as
# the other builds.
func start_improvement_road_project(row: int, col: int, imp_id: String, imp_name: String,
        target_res_id, road_level: int) -> bool:
    if project_manager == null or road_level <= 0:
        return false
    if row < 0 or row >= tile_data.size() or col < 0 or col >= tile_data[row].size():
        return false
    if not GameData.is_road_level_unlocked(road_level):
        hud.show_message(tr("Road level %d requires a technology") % road_level)
        return false
    # The road to the hex is already being built: a second project would mean a second payment for
    # one and the same route.
    if project_manager.has_project_at(row, col):
        return false
    var breakdown: Dictionary = get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        return false
    var steps: Array = breakdown.get("steps", [])
    if steps.is_empty():
        return false
    if not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        hud.show_message(tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)")
                % CityData.total_population)
        return false

    # The last step of the chain — the construction of the improvement itself. It has no price of its own:
    # it is exactly MapHelpers.get_improvement_work_cost, the same calculation that the
    # preview takes. The ghost segments of the step are absent: the road by this moment already stands,
    # and drawing anything in its place would be a lie.
    var improvement_cost := int(MapHelpers.get_improvement_work_cost(
            imp_id, row, col, tile_data, city_row, city_col).get("cost", 0))
    steps.append({
        "label": tr("Build %s") % imp_name,
        "work_cost": improvement_cost,
        "hex": {"row": row, "col": col},
        "ghost": {},
        "data": {
            # step_type distinguishes the improvement step in the handler and in the colour of
            # the progress bar: yellow was the colour of the build of an improvement, blue —
            # of a segment of the road.
            "step_type": "improvement",
            "improvement": imp_id,
            "imp_name": imp_name,
            "target_res_id": target_res_id,
        },
    })
    var total_cost := int(breakdown.get("cost", 0)) + improvement_cost
    var title := tr("Road")
    if not imp_name.is_empty():
        title = tr("Road to %s") % imp_name

    # The input data for the save: the road of this hex is going by a phased
    # project. While the flag is absent, the recalculation of the network "by the fact of the improvement"
    # (road_manager.rebuild_roads_from_existing) would count the hex as ready and
    # would finish the rest of the route for free. We set the flag BEFORE the start and remove it,
    # if the project has not started after all, — otherwise the hex would remain forever
    # an "improvement without a road" in the data of the save.
    tile_data[row][col]["road_staged"] = true
    if not _start_road_project_steps(row, col, steps, total_cost, false, title,
            {"improvement": imp_name, "improvement_id": imp_id}):
        tile_data[row][col]["road_staged"] = false
        return false
    return true

# The common part of the start of the road: the steps and the price are already counted, it remains to put
# the queue in project_manager. Both entries go through it — the road by the special action
# and the road to an improvement, — therefore the rules of the construction of them coincide by
# construction: one queue of the steps, one formula of the price of a segment
# (MapHelpers.get_road_step_work_cost), one handler of the step
# (_on_project_step_completed).
func _start_road_project_steps(row: int, col: int, steps: Array, cost: int,
        is_town: bool, title: String, extra_meta: Dictionary) -> bool:
    if steps.is_empty():
        return false

    # A free road cannot wait: a step without the work in the queue of the project is
    # a step which will not finish by itself and will hold the slot forever. For
    # such a road we immediately pass all the steps: there is nothing to pay, nothing to wait for.
    if cost <= 0:
        return _finish_free_road_project(row, col, steps, is_town)

    # We put the target in meta: the event project_completed comes already AFTER
    # the project has been thrown out of the manager, and there is nowhere else to take the hex which
    # has to be marked with the input data for the save.
    var meta := {
        "mode": "build",
        "is_town": is_town,
        "target_row": row,
        "target_col": col,
    }
    meta.merge(extra_meta)
    var project_id: String = project_manager.start_project("road", title, row, col, steps, meta)
    if project_id == "":
        return false
    hud.show_message(tr("%s: %d sections, built one at a time") % [title, steps.size()])
    # The ghost of the route appears immediately after the confirmation and lives until the end of
    # the build: from this moment the panel is closed, and the player must nevertheless
    # see the whole project on the map and understand how much is still left.
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    return true

# A free road is built entirely and at once: there is nothing to pay for it, therefore
# there is no reason to wait in the queue of the project. The effects of the steps are the same and in the same
# order (from the network to the target), as in an ordinary project, — the common function of the effect of the
# step (_on_project_step_completed) is called from both paths, so that the rule
# "a segment has appeared — the hex is connected" does not exist in two forms.
func _finish_free_road_project(row: int, col: int, steps: Array,
        is_town: bool) -> bool:
    for step in steps:
        _on_project_step_completed("", "road", step)
    _mark_road_built(row, col, {"is_town": is_town})
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()
    return true

# The improvement of the already built road from the city to the hex (row, col).
#
# The difference from the building of a new road: the segments ALREADY EXIST, therefore the step of the project does not
# add a segment, but raises its level (road_manager.upgrade_road_segment).
# The queue itself and the "ghost" — the same as for the building: the player sees the route to
# the target and understands how many segments are still to be improved.
#
# The steps go FROM THE CITY to the target, as during the construction: in this way the progress bar travels in the same
# direction as the ghost, and the player sees where the road has already been improved.
func start_road_upgrade_project(row: int, col: int, road_level: int) -> bool:
    if not GameData.is_road_level_unlocked(road_level):
        hud.show_message(tr("Road level %d requires a technology") % road_level)
        return false
    var breakdown := get_road_upgrade_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        hud.show_message(tr("Nothing to upgrade: %s")
                % breakdown.get("reason", tr("no route to the city")))
        return false
    var steps: Array = breakdown.get("steps", [])

    if not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        hud.show_message(tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)")
                % CityData.total_population)
        return false

    var project_id: String = project_manager.start_project(
            "road_upgrade", tr("Upgrade road"), row, col, steps, {
        "mode": "upgrade",
        "target_row": row,
        "target_col": col,
        "road_level": road_level,
    })
    if project_id == "":
        return false
    hud.show_message(tr("Upgrading the road to the city: %d sections") % steps.size())
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    return true

# The price and the steps of the improvement of the road to the hex (row, col) up to the level road_level.
# The SINGLE source for the preview and for the real start — as for a new road.
#
# Only those segments of the route which are below the target level are improved: a segment
# of a higher level is left as is (a road cannot be lowered).
func get_road_upgrade_breakdown(row: int, col: int, road_level: int) -> Dictionary:
    var route: Dictionary = get_route_to_city(row, col)
    if not route.get("ok", false):
        return {"ok": false, "reason": route.get("reason", ""), "cost": 0, "steps": []}
    var segments: Array = route.get("segments", [])
    var levels: Array = route.get("levels", [])
    var steps: Array = []
    var total := 0
    # The steps FROM THE CITY to the target: the path of the route goes from the hex to the city, therefore
    # the indices go in the reverse order.
    for i in range(segments.size() - 1, -1, -1):
        var seg_key: String = str(segments[i])
        if int(levels[i]) >= road_level:
            continue
        var ends := _split_segment_key(seg_key)
        if ends.is_empty():
            continue
        var from_row := int(ends[0])
        var from_col := int(ends[1])
        var to_row := int(ends[2])
        var to_col := int(ends[3])
        # The price of the segment of the improvement is counted by THAT SAME hex, which the step
        # connects to the network during the construction, — that is, by the far end from the city:
        # the route goes from the city, and that end carries the materials further.
        var far_row := to_row
        var far_col := to_col
        if HexUtils.hex_distance(from_row, from_col, city_row, city_col) \
                > HexUtils.hex_distance(to_row, to_col, city_row, city_col):
            far_row = from_row
            far_col = from_col
        var terrain_id := "plain"
        if far_row >= 0 and far_row < tile_data.size() and far_col >= 0 \
                and far_col < tile_data[far_row].size() and tile_data[far_row][far_col] != null:
            terrain_id = str(tile_data[far_row][far_col].get("terrain", "plain"))
        var price := MapHelpers.get_road_step_work_cost(
                road_level, far_row, far_col, city_row, city_col, terrain_id)
        var cost := int(price.get("cost", 0))
        total += cost
        steps.append({
            "label": tr("Upgrade section %d/%d") % [steps.size() + 1, segments.size()],
            "work_cost": cost,
            "price": price,
            "hex": {"row": far_row, "col": far_col},
            # The ghost of the improvement — the same segment: it is already drawn by the road,
            # and the highlighting shows which exactly segment is being improved.
            "ghost": {seg_key: true},
            "data": {
                "from": {"row": from_row, "col": from_col},
                "to": {"row": to_row, "col": to_col},
                "is_upgrade": true,
                "road_level": road_level,
            },
        })
    if steps.is_empty():
        return {"ok": false, "cost": 0, "steps": [],
                "reason": tr("the route is already at this level")}
    return {"ok": true, "reason": "", "cost": total, "steps": steps,
            "segments": steps.size(), "road_level": road_level}

# Parses the key of a segment "row1,col1|row2,col2" into [row1, col1, row2, col2].
# An empty array — the key is damaged; we skip such a segment: improving and
# charging for it is impossible anyway.
func _split_segment_key(key: String) -> Array:
    var ends := key.split("|")
    if ends.size() != 2:
        return []
    var a := ends[0].split(",")
    var b := ends[1].split(",")
    if a.size() != 2 or b.size() != 2:
        return []
    if not (a[0].is_valid_int() and a[1].is_valid_int()
            and b[0].is_valid_int() and b[1].is_valid_int()):
        return []
    return [int(a[0]), int(a[1]), int(b[0]), int(b[1])]

# The public wrapper over the search of the route: it is needed by the control panel (the block
# "Route to the city") and by the renderer (the highlighting of the route on the map). The hex of the town
# is routed by ITS OWN road network, therefore the town is passed to the manager
# separately (see road_manager.find_route_to_city).
func get_route_to_city(row: int, col: int) -> Dictionary:
    var town = find_town_at(row, col)
    if town != null:
        return road_manager.find_route_to_city(row, col,
                int(town.get("row", -1)), int(town.get("col", -1)))
    return road_manager.find_route_to_city(row, col)

# The average speed of the route from the hex to the city, or -1.0 when there is no route.
# -1.0 (and not 0.0) marks "no route": the road does not limit the transport then, and the
# caller must tell the two cases apart (a road with a zero speed does not exist).
func _route_avg_speed(row: int, col: int) -> float:
    var route: Dictionary = get_route_to_city(row, col)
    if not route.get("ok", false):
        return -1.0
    return float(route.get("avg_speed", 0.0))

# Turns the plan of the road into the queue of the steps — one per new segment.
#
# This is the SINGLE source of the price of the road. Both the preview in the panel, and the real start of the
# project take the steps from here, therefore "how much was shown" and "how much is taken" cannot
# diverge. Previously the price was counted separately in three places, and the preview
# showed the price of ALL the segments of the path (plan.segments = path.size() − 1),
# whereas the steps already filtered the built ones: on a route going along
# a partially built road, the player saw an inflated price.
#
# The order of the steps is FROM THE NETWORK TO THE TARGET, although plan_road_to returns the path from the target
# to the city (that is how the search builds it). This is not cosmetics: each step has two hexes,
# and building from the network means that the segment is always connected to the already finished
# road, and does not hang in the air until the end of the build. For the same reason
# the progress bar travels from the city to the target, and the ghost is "eaten" from the city.
#
# The price of the step (MapHelpers.get_road_step_work_cost) depends on the hex to_hex:
# the terrain, the distance from the city, the technologies. There is no separate surcharge for the length of
# the route — a long road takes longer to build because there are more segments.
func _build_road_steps(plan: Dictionary, road_level: int) -> Array:
    var road_path: Array = plan.get("path", [])
    var is_town := bool(plan.get("is_town", false))
    if road_path.size() < 2:
        return []

    # Only the NEW segments: the already laid ones do not need to be paid for (there will be
    # no step for them in the queue, and they will not appear in the ghost either). The path goes from
    # the target to the city, therefore we reverse the new segments — step by step from
    # the network.
    var pairs: Array = []
    for i in range(road_path.size() - 2, -1, -1):
        var from_hex: Dictionary = road_path[i + 1]
        var to_hex: Dictionary = road_path[i]
        var f_row := int(from_hex.get("row", -1))
        var f_col := int(from_hex.get("col", -1))
        var t_row := int(to_hex.get("row", -1))
        var t_col := int(to_hex.get("col", -1))
        if f_row < 0 or t_row < 0:
            continue
        if road_manager.has_road_between(f_row, f_col, t_row, t_col):
            continue
        pairs.append({
            "from": {"row": f_row, "col": f_col},
            "to": {"row": t_row, "col": t_col},
            "ghost": {road_manager.get_road_segment_key(f_row, f_col, t_row, t_col): true},
        })
    if pairs.is_empty():
        return []

    var steps: Array = []
    for i in range(pairs.size()):
        var pair: Dictionary = pairs[i]
        var to_hex: Dictionary = pair["to"]
        var t_row := int(to_hex["row"])
        var t_col := int(to_hex["col"])
        # The terrain of the hex to: it is exactly its step that connects it to the network, and the price
        # is already counted by it. The hex from is already in the network, it has been paid for earlier.
        var terrain_id := "plain"
        if t_row >= 0 and t_row < tile_data.size() and t_col >= 0 \
                and t_col < tile_data[t_row].size() and tile_data[t_row][t_col] != null:
            terrain_id = str(tile_data[t_row][t_col].get("terrain", "plain"))
        var price := MapHelpers.get_road_step_work_cost(
                road_level, t_row, t_col, city_row, city_col, terrain_id)
        steps.append({
            "label": tr("Section %d/%d") % [i + 1, pairs.size()],
            "work_cost": int(price.get("cost", 0)),
            # The details of the calculation — for the tooltip on the progress bar and for the preview.
            "price": price,
            # The progress bar is drawn on the hex which the step connects to the network.
            "hex": {"row": t_row, "col": t_col},
            "ghost": pair["ghost"],
            "data": {
                "from": pair["from"],
                "to": pair["to"],
                "is_town": is_town,
                # The level of the segment travels in the step, and is not taken in the handler of
                # the completion: there the level chosen by the player is already gone, there is
                # only the signal "the step is ready".
                "road_level": road_level,
            },
        })
    return steps

# The price of the road and its steps for the preview in the control panel. It returns
# {ok, reason, cost, steps}, where cost is the EXACT sum of the prices of the steps.
#
# The invariant "the sum of the steps = the price in the preview" holds by construction: each
# step is rounded up separately, and the total is simply summed up. Previously the price
# was taken as ceil(base × segments), and the last step "made up the remainder" — with
# the different prices of the steps such a scheme would give an overpayment or a shortfall.
func get_road_cost_breakdown(row: int, col: int, road_level: int) -> Dictionary:
    var plan := get_road_plan(row, col)
    if not plan.get("ok", false):
        return {"ok": false, "reason": plan.get("reason", tr("Cannot build a road")),
                "cost": 0, "steps": []}
    var steps := _build_road_steps(plan, road_level)
    if steps.is_empty():
        return {"ok": false, "reason": tr("No new sections on this route"),
                "cost": 0, "steps": []}
    var total := 0
    # The minimums start from -1, and NOT from INF: mini()/maxi() lower the type to int, and
    # INF becomes INT64_MIN, on which the minimum "sticks" forever
    # (it showed up as the distance -9223372036854775808 in the preview).
    var min_cost := -1
    var max_cost := 0
    var min_dist := -1
    var max_dist := 0
    var terrains: Dictionary = {}
    for step in steps:
        var c := int(step.get("work_cost", 0))
        total += c
        min_cost = c if min_cost < 0 else mini(min_cost, c)
        max_cost = maxi(max_cost, c)
        var price: Dictionary = step.get("price", {})
        var d := int(price.get("distance", 0))
        min_dist = d if min_dist < 0 else mini(min_dist, d)
        max_dist = maxi(max_dist, d)
        var tid := str(price.get("terrain_id", ""))
        if tid != "":
            terrains[tid] = true
    return {
        "ok": true,
        "reason": "",
        "cost": total,
        "steps": steps,
        "segments": steps.size(),
        "road_level": road_level,
        "min_step_cost": min_cost,
        "max_step_cost": max_cost,
        "min_distance": maxi(min_dist, 0),
        "max_distance": max_dist,
        "terrains": terrains.keys(),
    }

# The effect of one segment of the road: the segment goes into the network of the city, both of its hexes
# become connected. The flag road_built is set on EVERY connected
# hex, and not only on the target of the project: the segments are not written to the save, and by these
# the flags the network is recalculated on loading (road_manager.rebuild_player_roads).
# In this way a half-built road survives the restart, and does not disappear.
#
# The same handler also serves the improvement of the road (kind "road_upgrade"):
# the segment already exists, therefore instead of adding a segment its level
# is raised. Both modes in one place — the rule "the step has been applied to the hex"
# must not exist in two forms.
func _on_project_step_completed(_project_id: String, kind: String, step: Dictionary) -> void:
    var data: Dictionary = step.get("data", {})

    # The last step of the chain "road → improvement": we place the improvement. Its data
    # travels in the step (imp_id, the bred animal/plant), because the records
    # of the build in build_manager on this hex are absent — the improvement lies in the queue
    # of the project. The effect is applied by the same _apply_improvement as an ordinary
    # build from active_builds.
    if str(data.get("step_type", "")) == "improvement":
        var imp_id := str(data.get("improvement", ""))
        if imp_id.is_empty():
            return
        var t_row := int(step.get("hex", {}).get("row", -1))
        var t_col := int(step.get("hex", {}).get("col", -1))
        if t_row < 0 or t_col < 0:
            return
        _apply_improvement(t_row, t_col, imp_id, data.get("target_res_id", null))
        hud.show_message(tr("Completed: %s") % str(data.get("imp_name", imp_id)))
        control_panel.refresh()
        return

    if kind != "road" and kind != "road_upgrade":
        return
    var from_hex: Dictionary = data.get("from", {})
    var to_hex: Dictionary = data.get("to", {})
    var f_row := int(from_hex.get("row", -1))
    var f_col := int(from_hex.get("col", -1))
    var t_row := int(to_hex.get("row", -1))
    var t_col := int(to_hex.get("col", -1))
    if f_row < 0 or t_row < 0:
        return
    var road_level := int(data.get("road_level", road_manager.DEFAULT_ROAD_LEVEL))
    if bool(data.get("is_upgrade", false)):
        road_manager.upgrade_road_segment(f_row, f_col, t_row, t_col, road_level)
        if t_row < tile_data.size() and t_col < tile_data[t_row].size() \
                and tile_data[t_row][t_col] != null:
            tile_data[t_row][t_col]["road_level"] = road_level
        return
    road_manager.build_road_step(f_row, f_col, t_row, t_col,
            bool(data.get("is_town", false)), road_level)
    if t_row < tile_data.size() and t_col < tile_data[t_row].size() \
            and tile_data[t_row][t_col] != null:
        tile_data[t_row][t_col]["road_built"] = true
        # The level of the segment is the input data for the save on a par with road_built:
        # without it the restored network would be a solid trail.
        tile_data[t_row][t_col]["road_level"] = road_level
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

# The road is completed entirely: we mark the target with the input data for the save and
# open the trade, if the road was going to a town.
func _on_project_completed(project_id: String, kind: String, meta: Dictionary) -> void:
    _refresh_project_ghost()
    if kind == "road":
        # The project has already been thrown out of the manager by this moment, therefore we take the target
        # from meta, filled in at the start (see start_road_project).
        var row := int(meta.get("target_row", -1))
        var col := int(meta.get("target_col", -1))
        if row >= 0 and col >= 0:
            # For the chain "road → improvement" the message of the finished road would be
            # in vain: the improvement has already worked as the last step and has spoken about itself
            # (_on_project_step_completed). The flag road_built is set in any case.
            _mark_road_built(row, col, meta, not meta.has("improvement"))
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

func _on_project_cancelled(_project_id: String, _kind: String, _meta: Dictionary) -> void:
    # The laid segments remain (the cancellation does not roll back the road), only
    # the ghost of what could not be completed disappears.
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

# The ghost on the map = the segments of the steps of the active projects that are not built yet.
# It is updated on every event of the project, therefore the built segment disappears
# from the route by itself.
func _refresh_project_ghost() -> void:
    if map_renderer == null:
        return
    map_renderer.set_project_ghost_segments(project_manager.get_pending_ghost_segments())

# Marks the target of the road as built — this is the input data for the restoration of the
# road from the save (the segments are not written to the save, see road_manager).
# An ordinary hex gets the flag on the hex itself; a town gets it on the hex (the road
# reaches the town centre, so the flag lies there) and in the record of the town (by it
# the availability of the trade is read, see town_manager.is_trade_available).
func _mark_road_built(row: int, col: int, plan: Dictionary,
        show_message: bool = true) -> void:
    tile_data[row][col]["road_built"] = true
    if not bool(plan.get("is_town", false)):
        if show_message:
            hud.show_message(tr("Road built!"))
        return
    var town = find_town_at(row, col)
    if town == null:
        return
    town["road_linked"] = true
    if show_message:
        hud.show_message(tr("Road to town \"%s\" built — trade available!")
                % str(town.get("name", tr("Town"))))

func _on_building_build_completed(building_id: String, build_key: String):
    # The construction of the building is complete - we add it to the city
    var slots = []
    if CityData.building_construction.has(build_key):
        var construction_data = CityData.building_construction[build_key]
        slots = construction_data.get("slots", [])
        CityData.building_construction.erase(build_key)
    
    CityData.city_built_buildings.append({"id": building_id, "slots": slots})
    
    # We assign the citizen
    if has_node("TownsfolkManager"):
        var tm = get_node("TownsfolkManager")
        tm.assign_townsfolk()
    
    CityData.emit_signal("city_updated")
    map_renderer.queue_redraw()
    _redraw_progress_layer()

    # The natural trigger of the transition to the next era: the Market has been built.
    if building_id == "market":
        _on_market_built()

func _on_building_upgrade_completed(build_key: String, idx: int, upgrade_to: String, building_name: String):
    # The upgrade of the building is complete — we replace the building under this index with the improved
    # version with the transfer of the settings (the recipes of the slots, the priority of the quality; the worker
    # remains bound to the index of the building, therefore the state "working/
    # paused" is transferred by itself). The signal city_updated is emitted inside
    # CityData.complete_building_upgrade, the panel of the city will update itself.
    CityData.complete_building_upgrade(idx, upgrade_to)

func pixel_to_hex(mx: float, my: float):
    return MapHelpers.pixel_to_hex(mx, my,
        region_start_row, region_end_row,
        region_start_col, region_end_col,
        offset_x, offset_y,
        scroll_offset, HEX_RADIUS)

func _setup_research_hud():
    # We create the panel of the research: a button with the icon of the technology + a progress bar.
    # We place it between the label of the date and the "City" button.
    var vbox = hud.get_node("VBoxContainer")
    research_hbox = HBoxContainer.new()
    research_hbox.add_theme_constant_override("separation", 4)

    research_button = Button.new()
    research_button.custom_minimum_size = Vector2(36, 24)
    research_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_button.text = ""
    # We put the icon as a child TextureRect, and not through Button.icon.
    # The reason: a PNG 64×64 in a button 36×24 is stretched/crops, and in Godot
    # 4.7 there is neither icon_scale, nor icon_max_width, nor a normal way
    # to limit the size of Button.icon. Its own TextureRect with custom_minimum_size
    # = 24×24 solves the problem once and for all.
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

    research_button.tooltip_text = tr("Select a technology to research")
    research_button.pressed.connect(_on_research_hud_button_pressed)
    research_hbox.add_child(research_button)

    research_progress_bar = ProgressBar.new()
    research_progress_bar.custom_minimum_size = Vector2(120, 12)
    research_progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_progress_bar.max_value = 100.0
    research_progress_bar.value = 0.0
    research_progress_bar.show_percentage = false
    research_hbox.add_child(research_progress_bar)

    # We insert after YearLabel (the date), before CityButton.
    var year_label = vbox.get_node("YearLabel")
    vbox.add_child(research_hbox)
    vbox.move_child(research_hbox, year_label.get_index() + 1)

    _update_research_progress()

func _update_research_progress():
    if research_button == null or research_progress_bar == null:
        return
    var tech_id = CityData.current_research_tech_id
    if tech_id == "":
        # Nothing is being researched — we attract the attention with red.
        # We must definitely hide the icon, otherwise the old technology sticks out on the button.
        if research_icon:
            research_icon.visible = false
            research_icon.texture = null
        if research_label:
            research_label.visible = true
            research_label.text = "!"
        research_button.tooltip_text = tr("No technology is being researched. Click to select a technology")
        research_progress_bar.value = 0.0
        research_progress_bar.modulate = Color(1, 1, 1, 1)
        _apply_research_button_warning(true)
        _last_research_hud_tech = ""
        return

    # The technology is being researched — we show the icon (if there is one) and the progress.
    var tech_data = null
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_data = t
            break
    if tech_data:
        research_button.tooltip_text = tr("Researching: %s") % tech_data.get("name", tech_id)
        var icon_name: String = tech_data.get("icon", "")
        if icon_name != "" and research_icon:
            var path = IconRegistry.icon_path(icon_name)
            if path != "":
                var tex = load(path)
                if tex:
                    research_icon.texture = tex
                    research_icon.visible = true
                    # We hide the Label, so that the HBox does not reserve a place for it.
                    # Otherwise the icon "sticks" to the left edge of the button,
                    # and on the right — an empty area under the hidden label.
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
        research_button.tooltip_text = tr("A technology is being researched")
    _apply_research_button_warning(false)

    if CityData.current_research_science_cost > 0:
        research_progress_bar.value = CityData.research_progress * 100.0
    else:
        research_progress_bar.value = 0.0
    research_progress_bar.modulate = Color(1, 1, 1, 1)
    _last_research_hud_tech = tech_id

func _apply_research_button_warning(warning: bool):
    # The red frame/highlighting in the absence of a research.
    var normal = StyleBoxFlat.new()
    normal.bg_color = Color(0.3, 0.3, 0.3, 1.0)
    normal.set_border_width_all(2)
    if warning:
        normal.border_color = Color(1.0, 0.2, 0.2, 1.0)
    else:
        normal.border_color = Color(0.4, 0.4, 0.4, 1.0)
    research_button.add_theme_stylebox_override("normal", normal)
    # We override hover/pressed/focus with the same style, so that on hover
    # the content margins do not change and the size of the button remains the same.
    research_button.add_theme_stylebox_override("hover", normal)
    research_button.add_theme_stylebox_override("pressed", normal)
    research_button.add_theme_stylebox_override("focus", normal)
    if warning:
        research_button.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
    else:
        research_button.add_theme_color_override("font_color", Color.WHITE)

func _on_research_hud_button_pressed():
    # The transition to the interface of the city on the tab "Technologies".
    if pause_menu.visible:
        return
    city_ui.refresh()
    city_ui.show_technologies_tab()
    city_ui.show()
    hud.hide()
    # The control panel of the hex is not needed while the interface of the city is open.
    control_panel.hide()

func open_city():
    city_ui.refresh()
    city_ui.show()
    city_ui.show_resources_tab()
    hud.hide()
    # The control panel of the hex is not needed while the interface of the city is open.
    control_panel.hide()

func _on_city_button_pressed():
    if pause_menu.visible:
        return
    city_button.disabled = false
    open_city()

func _on_city_ui_close():
    city_ui.hide()
    hud.show()
    # We return the control panel of the hex on the exit from the interface of the city.
    control_panel.show()
    _update_research_progress()

# Opens the interface of the town (the window of the trade) for the hex (row, col).
# It is called from the control panel (the action button on the hex of the town) and
# from InputHandler (a double click on the hex of the town).
#
# The access to the interface does NOT depend on the road: a scouted town can
# always be opened — there one can see what it has for sale and for purchase.
# The road gates only the trade (see town_manager.is_trade_available), and
# its availability is passed into the window by the status, and not by a blocking.
func open_town_ui(row: int, col: int):
    var town = find_town_at(row, col)
    if town == null:
        return
    town_ui.open_town(town, town_manager.is_trade_available(town))
    hud.hide()
    # The control panel of the hex is not needed while the interface of the town is open.
    control_panel.hide()

# Returns the record of the town on the hex (row, col) or null.
func find_town_at(row: int, col: int):
    if town_manager == null:
        return null
    return town_manager.find_town_at(row, col)

func _on_town_ui_close():
    town_ui.hide()
    hud.show()
    # We return the control panel of the hex on the exit from the interface of the town.
    control_panel.show()

func _on_research_error(message: String):
    if city_ui.visible:
        city_ui.set_message(message)
    else:
        hud.show_message(message)

func _on_research_completed(tech_id: String):
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    # We show the window of the learned technology and pause the game,
    # so that the player cannot interact with the map and the HUD while the window is open.
    if tech_popup and tech_popup.has_method("show_tech"):
        get_tree().paused = true
        tech_popup.show_tech(tech_id, CityData.last_research_messages)
    # The messages are passed into the popup — we clear them.
    CityData.last_research_messages = []

func _on_tech_popup_go_to_techs():
    # We unpause and open the interface of the city on the tab "Technologies"
    city_ui.refresh()
    city_ui.show_technologies_tab()
    city_ui.show()
    hud.hide()
    # The control panel of the hex is not needed while the interface of the city is open.
    control_panel.hide()

func _on_pause_save():
    SaveManager.save_game()
    hud.show_message(tr("Game saved."))

func _on_pause_menu_visibility_changed():
    var menu_visible = pause_menu.visible
    city_button.disabled = menu_visible
    expansion_button.disabled = menu_visible
    menu_button.visible = not menu_visible

func open_pause_menu():
    pause_menu.show()
    city_button.disabled = true
    expansion_button.disabled = true
    # We pause the game while the menu of the pause is open
    get_tree().paused = true

func _on_menu_button_pressed():
    if pause_menu.visible:
        return
    open_pause_menu()

func _on_pause_load():
    if SaveManager.load_game():
        get_tree().reload_current_scene()
    else:
        print("Error of the loading of the save")

func _on_pause_new_game():
    # The item of the menu of the pause does not create a new game, but returns to the main menu.
    get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func get_tile_data(row: int, col: int):
    if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
        return tile_data[row][col]
    return null

# Returns the actual cost of the labour for the construction of the improvement imp_id on the hex (row, col).
# The cost depends on the base work_cost of the improvement, the type of the terrain (move_cost) and
# the distance from the city. It returns a dictionary with the total cost and the details of the calculation
# (for the extended tooltip).
#
# About the improvement the keys are like this:
#   cost          — the price of the IMPROVEMENT itself (it is what build_manager takes);
#   road_applicable— whether the road is built together with it (for the special actions — no);
#   road_cost     — the price of the road to the hex, of the chosen level;
#   road_segments — how many new segments this road will add;
#   total_cost    — the sum, that is, how much everything will cost together.
# The road is NOT included in cost: it is a separate phased construction and is paid by its own
# steps (see start_improvement_road_project).
func get_improvement_work_cost(imp_id: String, row: int, col: int,
        road_level: int = road_manager.DEFAULT_ROAD_LEVEL) -> Dictionary:
    # The road (the special action build_road) is the exception: it has no improvements and no hex
    # of the construction, it has a WHOLE ROUTE of separate segments. The price
    # of each segment depends on its terrain and the distance, therefore the total
    # price is the sum of the steps (main_map._build_road_steps, the single source with
    # the preview). build_manager calls this function only for the check "price > 0".
    var special_action: Dictionary = GameData.special_actions.get(imp_id, {})
    if str(special_action.get("action_type", "")) == "road":
        var breakdown: Dictionary = get_road_cost_breakdown(row, col, road_level)
        return {
            "cost": int(breakdown.get("cost", 0)),
            "base_cost": GameData.get_road_work_cost(road_level),
            "road_level": road_level,
            "segments": int(breakdown.get("segments", 0)),
            "ok": bool(breakdown.get("ok", false)),
            "reason": str(breakdown.get("reason", "")),
            "min_step_cost": int(breakdown.get("min_step_cost", 0)),
            "max_step_cost": int(breakdown.get("max_step_cost", 0)),
            "min_distance": int(breakdown.get("min_distance", 0)),
            "max_distance": int(breakdown.get("max_distance", 0)),
            "terrains": breakdown.get("terrains", []),
        }
    var cost_data := MapHelpers.get_improvement_work_cost(imp_id, row, col, tile_data, city_row, city_col)
    # The special actions (the gathering of the wild plants, the felling of the forest, the drainage, the demolition of an improvement)
    # do NOT build a road: build_manager.start_build sends them into an ordinary build
    # bypassing start_improvement_road_project, and executes their _on_build_completed,
    # which does not touch the road network. Therefore the parsing of the road for them is
    # not counted at all: otherwise the preview would show the player the price and the number of the segments
    # of a construction which will not happen, and the "Total" — a sum with it.
    if GameData.special_actions.has(imp_id):
        cost_data["road_applicable"] = false
        cost_data["road_cost"] = 0
        cost_data["road_level"] = road_level
        cost_data["road_segments"] = 0
        cost_data["road_pending"] = false
        cost_data["total_cost"] = int(cost_data.get("cost", 0))
        return cost_data
    # The road to an improvement is a SEPARATE construction: a phased project, which
    # is started together with the construction of the improvement and is paid by the segments
    # (main_map.start_improvement_road_project). Therefore its price is NOT included in the
    # price of the improvement: otherwise the labour for the road would be written off twice. The panels need
    # both numbers (see control_panel._build_preview), build_manager takes
    # only `cost` — the improvement.
    var road_bd := get_road_cost_breakdown_for_improvement(row, col, road_level)
    var road_cost := int(road_bd.get("cost", 0))
    cost_data["road_applicable"] = true
    cost_data["road_cost"] = road_cost
    cost_data["road_level"] = road_level
    cost_data["road_segments"] = int(road_bd.get("segments", 0))
    cost_data["road_pending"] = bool(road_bd.get("pending", false))
    cost_data["total_cost"] = int(cost_data.get("cost", 0)) + road_cost
    return cost_data

# The price and the number of the segments of the road which the player has chosen during the construction of the improvement on the
# hex (row, col). It is the same parsing as in the preview "Build a road"
# (get_road_cost_breakdown), therefore the numbers in the panel and at the start coincide.
#
# The road which is not needed by the improvement (the hex is already connected, the improvement with the flag
# no_road, there is no land route) does not get here: it has no new segments,
# and the price is 0. In this way the preview does not show "road: 0" where there is no road to build.
func get_road_cost_breakdown_for_improvement(row: int, col: int,
        road_level: int) -> Dictionary:
    # A road project is already going to the hex (for example, the player has separately built
    # a road here by the special action). Its segments are already paid by that queue,
    # therefore it is not allowed to show their price again — otherwise the player will see a sum,
    # which will not be written off. The construction of the improvement on such a hex will not
    # start either: the hex is busy.
    if project_manager != null and project_manager.has_project_at(row, col):
        return {"ok": false, "pending": true, "reason": "", "cost": 0,
                "segments": 0, "road_level": road_level}
    var breakdown := get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        return {"ok": false, "reason": breakdown.get("reason", ""), "cost": 0,
                "segments": 0, "road_level": road_level}
    return breakdown

# The cost of the road to an improvement as a single number — for the places where the parsing is not needed.
#
# There is no free trail here any more: the road to an improvement costs exactly as much
# as the same road built by the special action, — by the formula of the level from
# data/roads.json. Previously the level 1 returned 0 without the calculation, which is why the road
# to an improvement was free and not payable: the player did not see its price, and
# in phases it was not built.
#
# The zero remains where there is no road at all: the hex is already connected, the improvement with the
# flag no_road, there is no land route.
func get_road_cost_for_improvement(row: int, col: int, road_level: int) -> int:
    return int(get_road_cost_breakdown_for_improvement(row, col, road_level)
            .get("cost", 0))

# The plan of the road from the network of the city to the hex (row, col) — the same object that
# road_manager.plan_road_to returns. It is needed by the control panel (the preview of
# the price) and by main_map.get_improvement_work_cost.
#
# hex_allowed = is_hex_known — the road which the player builds goes ONLY over the
# known territory (the Influence Ring or scouted). In the first place this
# concerns the road to a town: you can interact with a town only on
# a scouted hex, and you can approach it only over the scouted land as well.
# The automatic road networks do not get the filter (see road_manager
# ._find_path_between).
func get_road_plan(row: int, col: int) -> Dictionary:
    return road_manager.plan_road_to(row, col, tile_data, map_rows, map_cols,
            _road_hex_allowed())

# The predicate "a road of the player can be built on this hex". A separate function,
# so that all the calls (planning, construction, restoration from the save) look up
# by one and the same reference to the method, and not a Callable created anew every time.
func _road_hex_allowed() -> Callable:
    return Callable(self, "is_hex_known")

func _on_city_button_gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        scroll_offset = - (HexUtils.hex_center(city_row, city_col, HEX_RADIUS) + Vector2(offset_x, offset_y) - get_viewport_rect().size / 2.0)
        map_renderer.queue_redraw()

func _on_expansion_button_pressed():
    # The "Development" button no longer has any functionality
    pass

func _on_expansion_mode_changed(_active: bool):
    map_renderer.queue_redraw()

func _on_territory_expanded(_row: int, _col: int, cost: int):
    # cost is the labour spent on the claiming (see expansion_manager).
    hud.show_message(tr("Territory expanded! (%d work spent)") % cost)
    # The claiming removes the fog from the hexes (in_influence = true) — the cache of the fill of the rings of
    # the towns is rebuilt, otherwise the new territory would remain without the fill.
    # The cache of the plans of the roads is also reset: the bought hex has become known.
    road_manager.bump_map_knowledge()
    map_renderer.invalidate_town_influence_cache()
    map_renderer.queue_redraw()
    # The control panel is redrawn here, and not by a direct subscription to the signal:
    # territory_expanded carries three arguments, and control_panel.refresh() does not
    # accept a single one — on a direct connection Godot broke the call, and the panel
    # after the claiming remained with the old actions and the highlighting.
    control_panel.refresh()
    if city_ui.visible:
        city_ui.refresh()

func is_expansion_mode_active() -> bool:
    return expansion_manager.is_active()

func is_valid_hex(row: int, col: int) -> bool:
    # Is the hex valid WITHIN the Region (the Ring + the Region).
    # It is used where the belonging to the Region is exactly what matters: the purchase
    # (claiming) of the chunks, the check of the composition of the chunk, the scouting before the learning of
    # the Cartography (see get_region_bounds). After the Cartography the scouting is not
    # limited by this — see get_scout_reach_bounds().
    return row >= region_start_row and row <= region_end_row and col >= region_start_col and col <= region_end_col

# Is the technology "Cartography" learned. It opens the scouting beyond the
# Region: the fog of war and the territory of the towns. Before it the scouts can be
# sent only into the unexplored part of the Region, and the hexes outside the Region
# are inaccessible for the hover and the click (see is_hex_interactive).
func is_cartography_researched() -> bool:
    return CityData.is_tech_unlocked(CARTOGRAPHY_TECH_ID)

# The name of the technology "Cartography" for the messages to the player (the single source of
# the id — CARTOGRAPHY_TECH_ID; if the technology is renamed in the JSON, the message
# will update automatically).
func get_cartography_tech_name() -> String:
    return CityData.get_tech_name(CARTOGRAPHY_TECH_ID)

# Is the hex available for the interaction of the player: the tooltip on hover,
# the highlighting of the chunk of the scouting/purchase, the selection by a click of the LMB. The Region is available
# always (including its unexplored part — the scouting works there),
# the fog of war — only after the learning of the Cartography. The hexes beyond
# the edge of the map are unavailable always.
func is_hex_interactive(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col):
        return false
    if is_valid_hex(row, col):
        return true
    return is_cartography_researched()

# Is the hex already known to the player: its own Influence Ring (in_influence) or
# a scouted hex (is_explored). This is the "border of the known world" — only from
# it the scouts can be sent further (see is_chunk_adjacent_to_known).
# The influence rings of the other towns do NOT enter here: their territory is not ours.
# The flag is_explored of the Influence Ring is deliberately not set (see
# _initialize_map: the whole world, including the Ring, starts with is_explored = false),
# therefore in_influence is checked separately — otherwise at the start of a new game
# there would be nothing to scout at all (a soft-lock).
func is_hex_known(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col):
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    return bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false))

# Does the chunk have at least one hex bordering the territory known to the player
# (see is_hex_known). The scouting can be sent only into an
# "adjacent" chunk: otherwise the scouts would jump over the fog of war and
# uncover the islets far away from the border of the known world.
# The CHUNK is checked, and not the clicked hex: the BFS-chunk (up to 5 hexes), which has reached
# the border of the known world, is allowed, even if the click itself was made on a hex
# one step deeper. This agrees with the fact that the chunk is the unit of the action.
# The neighbours are taken through HexUtils.get_neighbors_odd_r (it also clips them by the edges of
# the map), that is, going out of the map is impossible here.
func is_chunk_adjacent_to_known(chunk: Array) -> bool:
    for hex in chunk:
        for n in HexUtils.get_neighbors_odd_r(hex.row, hex.col, map_rows, map_cols):
            if is_hex_known(n.row, n.col):
                return true
    return false

# Is the hex hidden by the fog of war: the information about it (the terrain, the resources,
# the improvements) is not known to the player, therefore the tooltip on hover and the left column
# of the control panel must not show it. The fog is a hex on the map which is NOT
# a part of the Influence Ring, is NOT scouted and lies outside the Region: the Ring+Region are visible
# on the map (there the player knows the terrain, and the resources are opened by the scouting —
# see map_tooltip._build_text), beyond them nothing is visible.
# The gate is used by the tooltip (InputHandler and update_tooltip_text) and by the left column
# of the panel (control_panel._refresh); the highlighting of the chunk and the button of the scouting remain —
# they do not disclose the contents of the hex.
func is_hex_in_fog(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col):
        return false
    if is_valid_hex(row, col):
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    return not (bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)))

# The inclusive hex-boundaries of the Region — in the same format as
# get_scout_reach_bounds(). They are needed by the BFS of the chunk of the scouting: before the learning of
# the Cartography the chunk is collected only inside the Region.
func get_region_bounds() -> Dictionary:
    return {
        "row_start": region_start_row,
        "row_end": region_end_row,
        "col_start": region_start_col,
        "col_end": region_end_col
    }

# Returns true, if the hex exists on the map (within its boundaries). It is needed by the
# actions available beyond the Region, — in the first place the scouting
# (see expansion_manager.get_chunk_hexes).
func is_hex_on_map(row: int, col: int) -> bool:
    return row >= 0 and row < map_rows and col >= 0 and col < map_cols

# The maximum distance of the scrolling of the map by the axes (in pixels). The SINGLE source of
# truth: the panning in InputHandler is limited by the same value, and
# as a consequence, the reachability of the hexes for the scouting (get_scout_reach_bounds).
#
# It is counted from the dimensions of the Region (the Ring + the Region), and not of the whole map: this
# limits the area visible by the scrolling to the nearest surroundings of the Region —
# a scout must reach there (including the fog of war and the territory of the
# towns near the Region), but the WHOLE map must NOT be available from
# the start. With the growth of the Region (a change of the era) the distance of the scrolling increases
# together with it.
func get_max_scroll() -> Vector2:
    return Vector2(
        float(region_end_col - region_start_col + 1) * HEX_RADIUS,
        float(region_end_row - region_start_row + 1) * HEX_RADIUS
    )

# Returns the inclusive hex-boundaries of the area which the player can see
# by the scrolling of the map: further the clamp of get_max_scroll() does not let. Beyond these
# boundaries there is neither the drawing of the fog, nor the possibility of a click. It is exactly this
# area by which the sending of the scouts is limited (including the territory of the towns
# and the hexes in the fog of war) — but ONLY after the learning of the Cartography: before it
# the scouting is limited by the Region (see get_region_bounds). The purchase of the chunks
# is still limited only by the Region (is_valid_hex).
func get_scout_reach_bounds() -> Dictionary:
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size
    var max_scroll = get_max_scroll()
    var x_spacing = HEX_RADIUS * sqrt(3.0)
    var y_spacing = HEX_RADIUS * 1.5
    # We unite the screen rectangle at both extreme positions
    # of the scrolling: world = -offset - scroll .. -offset - scroll + viewport.
    var world_left = - (offset_x + max_scroll.x)
    var world_right = - offset_x + max_scroll.x + viewport_size.x
    var world_top = - (offset_y + max_scroll.y)
    var world_bottom = - offset_y + max_scroll.y + viewport_size.y
    # The margin of 2 hexes: the offset of the odd rows and the partially visible hexes
    # at the edges of the screen (otherwise the extreme reachable hexes would "fall out" of
    # the chunks of the scouting, although one can click on them).
    var margin = 2
    var col_start = int(floor(world_left / x_spacing)) - margin
    var col_end = int(ceil(world_right / x_spacing)) + margin
    var row_start = int(floor(world_top / y_spacing)) - margin
    var row_end = int(ceil(world_bottom / y_spacing)) + margin
    return {
        "row_start": max(row_start, 0),
        "row_end": min(row_end, map_rows - 1),
        "col_start": max(col_start, 0),
        "col_end": min(col_end, map_cols - 1)
    }

func _on_chunk_hovered(_chunk: Array):
    map_renderer.queue_redraw()

# Loads the parameters of the map/window from data/map_config.json (through GameData).
# The values are used as the starting ones for a new game.
func _load_map_config():
    var cfg: Dictionary = GameData.map_config
    if cfg.is_empty():
        # The config is not found — we use the default values.
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

    # The city is always at the centre of the whole map.
    city_row = map_rows / 2
    city_col = map_cols / 2

# Recalculates the ABSOLUTE boundaries of the Influence Ring and of the visible window
# (the Ring + the Region) around the city. It is called after a change of
# ring_rows/ring_cols/region_rows/region_cols (a new game, a loading, an era).
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

# Returns true, if the hex (row, col) enters the current Influence Ring.
func is_in_influence(row: int, col: int) -> bool:
    return row >= influence_start_row and row <= influence_end_row \
        and col >= influence_start_col and col <= influence_end_col

# Returns a dictionary with the current state of the world/window for the save.
#
# start_region_* — the boundaries of the STARTING area of the player (the Ring + the Region of the 1st era)
# at the moment of the generation. They do not change during the whole game, but they are needed after the loading:
# by them the territory of the towns is cut out of the starting area (see
# town_manager.set_player_start_area), otherwise the loaded game would get
# towns creeping onto the land of the player. It is impossible to recalculate them from start_ring_* and
# region_width: region_width in the save may have already changed on the transition to
# the next era.
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
        "current_era": current_era,
        "debug_whole_map_revealed": debug_whole_map_revealed,
        "start_region_start_row": start_region_start_row,
        "start_region_end_row": start_region_end_row,
        "start_region_start_col": start_region_start_col,
        "start_region_end_col": start_region_end_col,
    }

# Computes the absolute boundaries of the VISIBLE area of the 2nd era
# (Ring_2 + Region_2). It is used by town_manager as the "mandatory
# zone" for the guarantee "≥1 town in the era-2".
#
#
# The scheme (see advance_to_next_era):
#   1) everything current (the Ring + the Region) is scouted for free and joined;
#   2) the old (the Ring + the Region) becomes the new Ring;
#   3) around the new Ring a new Region of the width era2_region_width is formed.
#
# The dimensions:
#   ring_2  = region_1   = (start_ring + start_region_width*2)
#   region_2 = ring_2 + era2_region_width*2
# The absolute boundaries are counted from the centre of the city and are clipped by the map.
func _compute_era2_region_bounds() -> Dictionary:
    # The width of the Region of the second era. By default — the current region_width
    # (for the old eras.json without the field region_width). If in data/eras.json
    # the era with the index 1 (the second by count, counting the ancient one as 0) has
    # its own value — we take it.
    var era2_region_width: int = region_width
    if GameData.eras.size() >= 2:
        var era2_data: Dictionary = GameData.eras[1]
        if era2_data.has("region_width"):
            era2_region_width = int(era2_data.get("region_width", region_width))

    # The Ring of the 2nd era = the Region of the 1st era (the starting visible area).
    var era2_ring_rows: int = region_rows
    var era2_ring_cols: int = region_cols
    # The Region of the 2nd era = Ring_2 + era2_region_width*2 in each direction.
    var era2_region_rows: int = era2_ring_rows + era2_region_width * 2
    var era2_region_cols: int = era2_ring_cols + era2_region_width * 2

    var start_row: int = maxi(0, city_row - era2_region_rows / 2)
    var end_row: int = mini(map_rows - 1, start_row + era2_region_rows - 1)
    var start_col: int = maxi(0, city_col - era2_region_cols / 2)
    var end_col: int = mini(map_cols - 1, start_col + era2_region_cols - 1)
    return {
        "start_row": start_row,
        "end_row": end_row,
        "start_col": start_col,
        "end_col": end_col,
    }

# Restores the state of the world/window from the save.
# It is called BEFORE the building of tile_data on loading.
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
    # We synchronise the era with CityData (the restriction of the learning of the technologies by the eras).
    if st.has("current_era"):
        CityData.current_era_index = current_era
    # The reveal belongs to the save and not to the session: the tiles (is_explored/in_influence)
    # are restored from it, and without this flag a loaded game would hide the rings of the towns
    # behind the era gate again.
    debug_whole_map_revealed = bool(st.get("debug_whole_map_revealed", false))
    city_row = map_rows / 2
    city_col = map_cols / 2
    _recalculate_bounds()
    _restore_start_region_bounds(st)

# Restores the boundaries of the STARTING area of the player (the Ring + the Region of the 1st era).
# In the save they lie as separate fields of map_state — they cannot be recalculated from
# start_ring_* and region_width, because region_width changes on a change of the era
# and there we recalculate from the starting ring and the current width of the region (for a game
# which started in the 1st era it is the exact value; for a later one — an approximation
# "better than no boundaries at all").
func _restore_start_region_bounds(st: Dictionary) -> void:
    if st.has("start_region_start_row") and st.has("start_region_end_row") \
            and st.has("start_region_start_col") and st.has("start_region_end_col"):
        start_region_start_row = int(st["start_region_start_row"])
        start_region_end_row = int(st["start_region_end_row"])
        start_region_start_col = int(st["start_region_start_col"])
        start_region_end_col = int(st["start_region_end_col"])
        return
    var start_ring_rows_ := start_ring_rows + region_width * 2
    var start_ring_cols_ := start_ring_cols + region_width * 2
    start_region_start_row = maxi(0, city_row - start_ring_rows_ / 2)
    start_region_end_row = mini(map_rows - 1, start_region_start_row + start_ring_rows_ - 1)
    start_region_start_col = maxi(0, city_col - start_ring_cols_ / 2)
    start_region_end_col = mini(map_cols - 1, start_region_start_col + start_ring_cols_ - 1)

# --- DEBUG: OPEN THE WHOLE MAP ---
# The whole map at once becomes the Influence Ring: all the hexes are marked
# as belonging to the Ring and as scouted, the boundaries of the Ring/Region
# are expanded to the dimensions of the whole map. After that one can build/improve
# on any hex without the scouting and the purchase of the territory.
# debug_whole_map_revealed lifts the era gate of the rings and of the roads of the towns:
# the reveal is deliberate, so there is nothing left to hide in the 1st era.
func debug_open_whole_map():
    if tile_data.is_empty():
        return

    debug_whole_map_revealed = true

    # We mark each hex as a part of the Influence Ring and as scouted.
    for row in range(map_rows):
        for col in range(map_cols):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            tile["in_influence"] = true
            tile["is_explored"] = true

    # The whole map is open — the knownness has changed, the plans of the roads are recalculated.
    road_manager.bump_map_knowledge()

    # We expand the Ring and the Region to the dimensions of the whole map — is_in_influence()
    # and is_valid_hex() will return true for any coordinates.
    ring_rows = map_rows
    ring_cols = map_cols
    region_rows = map_rows
    region_cols = map_cols

    _recalculate_bounds()
    _calc_offsets()
    # The fill of the rings is filtered by the fog of war, and the reveal changes the fog:
    # the render cache must be dropped explicitly, the Region bounds do not always change.
    map_renderer.invalidate_town_influence_cache()
    map_renderer.queue_redraw()

    if hud:
        hud.show_message(tr("Debug: whole map revealed and inside the Influence Ring (%d×%d)") % [map_rows, map_cols])

# --- THE TRANSITION TO THE NEXT ERA ---
# The infrastructure of the expansion of the world:
#   1. The whole current (not bought) Region is scouted instantly and for free.
#   2. The whole current Region is instantly and for free bought/joined.
#   3. The former Ring + Region become the new Influence Ring.
#   4. Around the new Ring a new Region of the same width is formed.
#   5. The hexes beyond the new Ring + Region are still hidden (the fog of war).
func advance_to_next_era():
    if tile_data.is_empty():
        return

    # 1-2. We scout and join the whole current Region for free.
    # The hexes in the influence ring of a foreign town are NOT joined: they must not
    # blocks by in_town_influence), nor to buy a chunk (expansion_manager
    # blocks by the same flag) — this is a "dead zone" in the Region near
    # someone else's town.
    #
    # Such hexes are nevertheless SCOUTED: otherwise they would remain fog
    # and would be drawn as a black hole in the middle of the just claimed territory.
    # A scouted hex is visible (the terrain, the resources) and is marked with the fill of the ring of
    # the town — the player immediately sees whose land it is and why it cannot be bought.
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_town_influence", false)):
                tile["is_explored"] = true
                continue
            tile["is_explored"] = true
            tile["in_influence"] = true

    # The whole Region has become known — the plans of the roads are recalculated (the route to
    # the town goes over the scouted land).
    road_manager.bump_map_knowledge()

    # 3. The former Ring + Region become the new Ring.
    ring_rows = region_rows
    ring_cols = region_cols

    # 4. The new Region: the width is taken from the configurable field region_width
    # of that era, into which we transition (data/eras.json). If the field is not set —
    # the current value remains (backward compatibility with the old eras.json).
    var next_era_index: int = current_era + 1
    if next_era_index >= 0 and next_era_index < GameData.eras.size():
        var era_data: Dictionary = GameData.eras[next_era_index]
        if era_data.has("region_width"):
            region_width = int(era_data.get("region_width", region_width))

    region_rows = ring_rows + region_width * 2
    region_cols = ring_cols + region_width * 2

    # 5. We recalculate the boundaries; the hexes of the new Region are not scouted and not in the influence.
    # The hexes of the rings of the other towns are not touched: we scouted them in the step 1-2 (see
    # there the comment about the "dead zone"), we cannot reset them back to the fog.
    _recalculate_bounds()
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            if not is_in_influence(row, col):
                tile["in_influence"] = false
                tile["is_explored"] = false

    current_era += 1
    # The boundaries of the Region have grown: a part of the formerly foggy hexes now enters the
    # Region, therefore the cache of the fill/boundaries of the rings of the towns has become outdated.
    # We synchronise the current era in CityData — the restriction
    # on the learning of the technologies depends on it (only the current and the previous eras).
    map_renderer.invalidate_town_influence_cache()
    # --- THE NATURAL TRANSITION TO THE NEXT ERA ---
    # The Market is the condition of the transition from the first era. After its construction the game
    # is paused and a dialog with a Yes/No choice is shown.
    # In case of a refusal a small button appears in the HUD, opening the same dialog.
    # No timers, no prohibitions and no reminders: the player can play in the current
    # era as long as he wants.
    CityData.current_era_index = current_era
    CityData.emit_signal("city_updated")
    _calc_offsets()
    map_renderer.queue_redraw()
    if hud:
        hud.show_message(tr("New era! City borders expanded. Influence ring: %d×%d") % [ring_rows, ring_cols])

    # If the Market has already been built, and the era has not been changed (the player refused and left)
    # - we show the button in the HUD again.
func _setup_era_advance_ui():
    era_advance_button = Button.new()
    era_advance_button.text = tr("New era")
    era_advance_button.tooltip_text = tr("Advance requirement met. Click to advance to the next era.")
    era_advance_button.visible = false
    era_advance_button.pressed.connect(_show_era_advance_offer)
    hud.get_node("VBoxContainer").add_child(era_advance_button)

    era_dialog = ConfirmationDialog.new()
    era_dialog.title = tr("New era")
    era_dialog.dialog_text = tr("Congratulations, your city has reached the next level of development!\nDo you want to transition to the next era?")
    era_dialog.ok_button_text = tr("Yes")
    era_dialog.cancel_button_text = tr("No")
    era_dialog.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
    era_dialog.confirmed.connect(_on_era_dialog_confirmed)
    era_dialog.canceled.connect(_on_era_dialog_declined)
    add_child(era_dialog)
    era_dialog.hide()

    # The player remains in the current era: we unpause, we leave the button in the HUD.
    if current_era == 0 and _is_market_built():
        era_advance_button.visible = true

func _is_market_built() -> bool:
    for b in CityData.city_built_buildings:
        if b.get("id", "") == "market":
            return true
    return false

func _on_market_built():
    if current_era == 0:
        _show_era_advance_offer()

func _show_era_advance_offer():
    get_tree().paused = true
    era_dialog.popup_centered()

func _on_era_dialog_confirmed():
    get_tree().paused = false
    era_advance_button.visible = false
    advance_to_next_era()

func _on_era_dialog_declined():
    # The player remains in the current era: we unpause, we leave the button in the HUD.
    get_tree().paused = false
    era_advance_button.visible = (current_era == 0)
func _load_settings():
    var err = settings_config.load("user://settings.cfg")
    if err == OK:
        show_hex_borders = settings_config.get_value("interface", "show_hex_borders", true)
        use_edge_scrolling = settings_config.get_value("interface", "edge_scrolling", true)
        tooltip_delay = settings_config.get_value("interface", "tooltip_delay", 0.5)
        extended_tooltip_delay = settings_config.get_value("interface", "extended_tooltip_delay", 1.0)
        building_detail_delay = settings_config.get_value("interface", "building_detail_delay", 0.5)
        resource_display_interval = settings_config.get_value("game", "resource_display_interval", 1.0)
    else:
        show_hex_borders = true
        use_edge_scrolling = true
        tooltip_delay = 0.5
        extended_tooltip_delay = 1.0
        building_detail_delay = 0.5
        resource_display_interval = 1.0

func apply_settings():
    _load_settings()
    input_handler.set_tooltip_delay(tooltip_delay)
    input_handler.set_extended_tooltip_delay(extended_tooltip_delay)
    city_ui.set_building_detail_delay(building_detail_delay)
    # set_resource_display_interval raises the era on a change of the value — we immediately
    # pick it up and update the HUD label of the treasury, so that the player sees the effect
    # of the new interval without waiting for the nearest city_updated.
    CityData.set_resource_display_interval(resource_display_interval)
    _treasury_display_epoch = CityData.resource_display_epoch
    _update_treasury_hud()

# The rebuild of the interface after a change of the language.
#
#
# LocalizationManager has already translated the scenes by this moment (Godot does it itself
# on the notification of TranslationServer) and RE-READ the data of the game — therefore here
# it is enough to call the refresh() of each screen: they rebuild the nodes
# with their own text and take the names from the already translated data.
#
# The research button and the HUD labels assemble the text in the code, therefore they are updated
# explicitly. The panel of the hex and of the town know how to update even in the closed form.
func _on_locale_changed(_locale: String) -> void:
    if city_ui:
        city_ui.refresh()
    if control_panel:
        control_panel.refresh()
    if town_ui and town_ui.has_method("_refresh"):
        town_ui._refresh()
    if tech_popup and tech_popup.has_method("refresh"):
        tech_popup.refresh()
    _update_research_progress()
    _update_population_hud()
    _update_treasury_hud()
    map_renderer.queue_redraw()

func _on_population_changed(_new_pop: int):
    _update_population_hud()

func _update_population_hud():
    var pop_label = hud.get_node_or_null("VBoxContainer/PopulationLabel")
    if pop_label:
        pop_label.text = tr("Population: %d") % CityData.total_population

# Updates the label of the treasury in the HUD (below the block of the game time). It is called
# from _ready (the start/loading), from apply_settings (a change of the interval) and from
# _on_city_data_updated (the tick path with the check of the era of the display).
# It captures CityData.treasury into _displayed_treasury — this same cache
# is used by the tooltip of the breakdown of the treasury (see _show_treasury_tooltip), so that
# the label and the tooltip show one value, without "running ahead" by 1+ ticks.
func _update_treasury_hud():
    _displayed_treasury = CityData.treasury
    var treasury_label = hud.get_node_or_null("VBoxContainer/TreasuryLabel")
    if treasury_label:
        # The dynamics of the profit/expense — the same fact as in the tooltip of the breakdown
        # (CityData.get_treasury_flow_text), but per second. It is counted at the same
        # rate of the update as the balance, — the numbers do not flicker every tick.
        treasury_label.text = tr("Treasury: %d %s") % [
            _displayed_treasury, CityData.get_treasury_flow_text()
        ]
        # The panel of the HUD in the scene is of a fixed width, and the row grows together with
        # balance — we recalculate the width under the new text, otherwise a long row
        # would crawl out onto the map and the hover on the "tail" would stop working.
        if hud.has_method("refresh_size"):
            hud.refresh_size()

# Creates a CanvasLayer + the Control-host and instantiates ui_helpers for the
# HUD tooltips (the breakdown of the treasury and the future ones). It is added to the tree once in
# _ready; the repeated calls are a no-op. It is moved out into a separate method, so as not to
# overload _ready.
func _setup_hud_tooltip_layer():
    if _map_ui_helpers != null and is_instance_valid(_map_ui_helpers):
        return
    var layer := CanvasLayer.new()
    layer.name = "HUDTooltipLayer"
    layer.layer = 100 # over the HUD (the HUD as a Panel on the main scene)
    add_child(layer)
    var host := Control.new()
    host.name = "HUDTooltipHost"
    host.set_anchors_preset(Control.PRESET_FULL_RECT)
    host.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(host)
    _map_ui_helpers = load("res://scripts/ui_helpers.gd").new()
    _map_ui_helpers.setup(host, null)
    layer.add_child(_map_ui_helpers)

# The cursor is now over the label of the treasury of the HUD — exactly and only this starts
# the hover timer of "sticking" the tooltip of the breakdown. If the HUD is hidden (the interface of the
# city is open), the label is not considered hovered, even if its rectangle coincided with
# the position of the cursor.
func _is_treasury_label_hovered(mouse_pos: Vector2) -> bool:
    if not (hud and is_instance_valid(hud)) or not hud.visible:
        return false
    var treasury_label = hud.get_node_or_null("VBoxContainer/TreasuryLabel")
    return is_instance_valid(treasury_label) \
        and treasury_label.get_global_rect().has_point(mouse_pos)

# Returns true, if the cursor is now over the label of the treasury or over the active
# (including "stuck") tooltip of the breakdown (this is needed, so that on the transition of the
# cursor from the label to the tooltip the tooltip does not blink — the leave fires only by
# grace).
func _is_treasury_hovered(mouse_pos: Vector2) -> bool:
    if _is_treasury_label_hovered(mouse_pos):
        return true
    if _map_ui_helpers and is_instance_valid(_map_ui_helpers) \
            and _map_ui_helpers.treasury_tooltip_panel \
            and _map_ui_helpers.treasury_tooltip_panel.visible \
            and _map_ui_helpers.treasury_tooltip_panel.get_global_rect().has_point(mouse_pos):
        return true
    return false

# The cursor is now over the shown ("stuck") tooltip of the breakdown of the treasury of the HUD layer.
# The tooltip covers the map, and the map under it must not react to the cursor:
# neither the tooltip of the hex, nor the highlighting of the chunk, nor the clicks/selection, nor the scrolling by the edges
# (see InputHandler.handle_input / handle_process). The treasury label is not
# checked here: it lies inside the HUD, and it is covered by the check "the cursor is over the HUD".
func is_mouse_over_treasury_tooltip(pos: Vector2) -> bool:
    if not (_map_ui_helpers and is_instance_valid(_map_ui_helpers)):
        return false
    var panel: Panel = _map_ui_helpers.treasury_tooltip_panel
    if not is_instance_valid(panel) or not panel.visible:
        return false
    return panel.get_global_rect().has_point(pos)

# Shows the tooltip of the breakdown of the treasury under the cursor (the HUD variant). The data is from
# worker_manager (the planned income by the sources) and CityData (a snapshot of the expenses
# over the window). It is analogous to the method in city_ui.gd (see _show_treasury_tooltip there).
# keep_position=true — the live-update of the already shown ("stuck") tooltip:
# the panel stays in place. It returns true if the tooltip is visible in the end
# (an empty breakdown hides the panel — then there is no "sticking").
func _show_treasury_tooltip(mouse_pos: Vector2, keep_position: bool = false) -> bool:
    if not worker_manager:
        return false
    var planned_income: Dictionary = {}
    if worker_manager.has_method("get_actual_treasury_income_map"):
        planned_income = worker_manager.get_actual_treasury_income_map()
    # We take _displayed_treasury (the cache of the label of the HUD), and not CityData.treasury —
    # otherwise in the tooltip the "fresh" value of the treasury would be visible, which gets ahead of
    # the label of the HUD by 1+ consumption ticks (see developer_diary, the regression
    # "runs ahead").
    _map_ui_helpers.show_treasury_tooltip(
        mouse_pos,
        _displayed_treasury,
        planned_income,
        CityData.treasury_expense_snapshot,
        CityData.treasury_window_length_sec,
        keep_position
    )
    var panel = _map_ui_helpers.treasury_tooltip_panel if is_instance_valid(_map_ui_helpers) else null
    return is_instance_valid(panel) and panel.visible

# The tick handler: it updates the label of the treasury in the HUD with the display interval of the
# resources. It is analogous to control_panel.on_city_updated and city_ui._refresh_light —
# everything is subordinated to one era (CityData.resource_display_epoch), so that all
# the resource places are updated simultaneously, by one "jerk" per interval.
func _on_city_data_updated():
    if CityData.resource_display_due(_treasury_display_epoch):
        _treasury_display_epoch = CityData.resource_display_epoch
        _update_treasury_hud()
        # On a change of the era we update the open tooltip of the breakdown of the treasury with the fresh
        # data (the planned income is recalculated, the snapshot of the expenses is updated). This is
        # a "live" update — the player sees the actual numbers while the cursor is on the
        # label or on the tooltip. keep_position=true: the "stuck" panel
        # remains in place, and does not run away from the cursor.
        if _map_ui_helpers and is_instance_valid(_map_ui_helpers) \
                and _map_ui_helpers.treasury_tooltip_panel \
                and _map_ui_helpers.treasury_tooltip_panel.visible \
                and CityData.resource_display_due(_treasury_tooltip_display_epoch):
            _treasury_tooltip_display_epoch = CityData.resource_display_epoch
            _show_treasury_tooltip(get_viewport().get_mouse_position(), true)

func _on_assignment_changed():
    map_renderer.queue_redraw()
    if city_ui.visible:
        city_ui.refresh_light()

func _on_townsfolk_assignment_changed():
    if city_ui.visible:
        city_ui.refresh_light()

func _get_scouting_time(hex_count: int) -> float:
    return hex_count * SCOUTING_TIME_PER_HEX

func start_scouting(chunk: Array):
    if is_scouting:
        hud.show_message(tr("Scouting already in progress!"))
        return
    # An empty chunk — there is nothing to scout. A control check for the public
    # entry point: otherwise the treasury would be "written off" for 0 coins, and is_scouting
    # would hang on an empty chunk (the bar of the scouting without hexes).
    if chunk.is_empty():
        return
    # A safety repetition of the rule: before the learning of the Cartography the scouting
    # is limited by the unexplored part of the Region. The chunk comes from
    # expansion_manager.get_chunk_hexes (it already observes this), but
    # start_scouting is a public entry point: the chunk can come here by another
    # way, and sending the scouts into the fog of war without the Cartography is not allowed.
    if not is_cartography_researched():
        for hex in chunk:
            if not is_valid_hex(hex.row, hex.col):
                hud.show_message(tr("Scouting beyond the Region requires the technology \"%s\"")
                        % get_cartography_tech_name())
                return
    # A safety repetition of the rule "the scouting only into a chunk, adjacent to
    # the known territory" (see is_chunk_adjacent_to_known). The UI does not activate such a button,
    # but the refusal must be here as well — BEFORE the write-off of the coins and the start of
    # the timer, so that the price and the actual action do not diverge.
    if not is_chunk_adjacent_to_known(chunk):
        hud.show_message(tr("The chunk does not border explored territory — scout the neighbouring hexes first"))
        return
    # The price of the expedition is NOT accepted as a parameter: the single source of truth is
    # expansion_manager.get_chunk_scout_cost() (the base and the modifier of the distance
    # from data/game_balance.json). Otherwise the UI and the actual write-off could
    # diverge. The payment is by the coins of the treasury of the city, at once.
    # Debug: with "Ignore building requirements" enabled the scouting
    # is free and instant — the coins are not written off, the timer is not started,
    # the chunk is opened by the same _complete_scouting() as at an ordinary finish.
    var expedition_cost: int = expansion_manager.get_chunk_scout_cost(chunk)
    if not CityData.ignore_build_requirements:
        if not CityData.spend_treasury(expedition_cost):
            hud.show_message(tr("Not enough coins in the treasury! Need %d, treasury has %d")
                    % [expedition_cost, CityData.treasury])
            return
        # The source of the expense for the tooltip "Treasury" (see show_treasury_tooltip).
        # The one-off costs of the scouting are event-based, they are not in the plan, therefore the breakdown
        # of the expenses shows the fact over the last display window.
        if expedition_cost > 0:
            CityData.record_treasury_expense(GameData.SRC_SCOUTING, expedition_cost)
    scouting_chunk = chunk
    scouting_timer = 0.0
    if CityData.ignore_build_requirements:
        # The instant finish: we do not even turn on is_scouting, otherwise for one frame
        # the progress bar of the scouting would flash, which the player does not have time to see.
        _complete_scouting()
        return
    is_scouting = true
    _redraw_progress_layer()
    hud.show_message(tr("Scouts sent... (%d coins paid from the treasury)") % expedition_cost)

func _complete_scouting():
    for hex in scouting_chunk:
        tile_data[hex.row][hex.col]["is_explored"] = true
    # The scouting has opened the new hexes — the plans of the roads could have changed (the route to the
    # town goes only over the scouted land), therefore the cache of the plans is reset.
    road_manager.bump_map_knowledge()
    var info = _get_chunk_info(scouting_chunk)
    hud.show_message(tr("Scouting complete! %s") % info)
    is_scouting = false
    scouting_chunk = []
    # The scouting removes the fog of war from the hexes, therefore the fill of the rings of the towns
    # on the opened territory must appear — the cache of the renderer is rebuilt.
    map_renderer.invalidate_town_influence_cache()
    map_renderer.queue_redraw()
    _redraw_progress_layer()

# The common part of the dialogs of the cancellation: the pause for the time of the question, the localized button
# of the confirmation and the obligatory unpause, if the window was closed by the cross
# (an AcceptDialog has no signal canceled).
func _show_cancel_dialog(dialog: AcceptDialog, on_confirm: Callable) -> void:
    var was_paused = get_tree().paused
    get_tree().paused = true
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS
    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        on_confirm.call()
    )
    add_child(dialog)
    dialog.popup_centered()
    dialog.visibility_changed.connect(func():
        if not dialog.visible and not was_paused:
            get_tree().paused = false
    )

# The cancellation of the claiming of the territory from the hex (row, col) — exactly that one, where
# the progress bar of the claiming is drawn (the first hex of the chunk). The coins written off at the start
# are returned: they paid for the joining of the chunk to the Influence Ring, and it did not
# happen. The labour is lost — that is the price of the refusal.
func confirm_cancel_expansion(row: int, col: int):
    if build_manager == null:
        return
    var data: Dictionary = build_manager.get_expansion_progress_for_hex(row, col)
    if data.is_empty():
        return
    var chunk: Array = data.get("chunk", [])
    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel claiming")
    var text := tr("Stop claiming land (%d tiles)?\n\n") % chunk.size()
    text += tr("Spent work (%.0f/%d) will be lost.") % [
        float(data.get("progress", 0.0)), int(data.get("work_cost", 0))]
    var money_cost := int(data.get("money_cost", 0))
    if money_cost > 0:
        text += tr("\n\nThe %d coins already paid will be returned to the treasury.") % money_cost
    else:
        text += tr("\n\nNo coins were deducted for the claim.")
    dialog.dialog_text = text
    dialog.get_ok_button().text = tr("Yes")
    _show_cancel_dialog(dialog, func():
        if build_manager.cancel_expansion_at_hex(row, col):
            _after_cancel_long_action())

# The cancellation of the scouting. The expedition in the game is one for the whole time (main_map.is_scouting),
# therefore the button appears on the hex of its chunk, and the timer itself is reset.
# As with the claiming: the money for the start is returned, the time of the expedition — no.
func confirm_cancel_scouting(row: int, col: int):
    if not is_scouting or scouting_chunk.is_empty():
        return
    var first = scouting_chunk[0]
    if first == null or int(first.row) != row or int(first.col) != col:
        return
    var chunk: Array = scouting_chunk
    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel scouting")
    var text := tr("Recall the scouts?\n\nNone of the %d tiles will be surveyed.") % chunk.size()
    if not CityData.ignore_build_requirements:
        text += tr("\n\nThe %d coins paid will be returned to the treasury.") % expansion_manager.get_chunk_scout_cost(chunk)
    dialog.dialog_text = text
    dialog.get_ok_button().text = tr("Yes")
    _show_cancel_dialog(dialog, func():
        cancel_scouting())

# Interrupts the scouting: the timer is zeroed, the chunk is forgotten, the money for the start
# is returned. The fog is NOT removed from the chunk — the scouting is applied entirely in
# _complete_scouting, it has no intermediate state.
func cancel_scouting() -> bool:
    if not is_scouting or scouting_chunk.is_empty():
        return false
    var chunk: Array = scouting_chunk.duplicate()
    is_scouting = false
    scouting_chunk = []
    scouting_timer = 0.0
    if not CityData.ignore_build_requirements:
        var cost: int = expansion_manager.get_chunk_scout_cost(chunk)
        if cost > 0:
            CityData.add_treasury(cost)
            CityData.record_treasury_expense(GameData.SRC_SCOUTING, -cost)
    hud.show_message(tr("Scouting cancelled"))
    _after_cancel_long_action()
    return true

# The actions after the cancellation of the claiming/scouting: in both of them the progress bar disappears, and
# _process will no longer redraw the layer, if it was the last
# active build.
func _after_cancel_long_action() -> void:
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

func _get_chunk_info(chunk: Array) -> String:
    return MapHelpers.get_chunk_info(chunk, tile_data)

func _confirm_cancel_build(row: int, col: int):
    var prog = build_manager.get_progress(row, col)
    if prog.is_empty():
        return
    var imp_name = prog.get("imp_name", tr("Upgrade"))
    var work_done = prog.get("progress", 0.0)
    var work_total = prog.get("work_cost", 0)

    # We create the confirmation dialog
    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel construction")
    dialog.dialog_text = tr("Cancel construction of \"%s\"?\n\nSpent work (%.0f/%d) will be lost.") % [imp_name, work_done, work_total]
    # We localize the button of the confirmation (by default Godot shows "OK" —
    # a project without translation files).
    dialog.get_ok_button().text = tr("Yes")
    # We pause the game while the confirmation dialog of the cancellation is open.
    var was_paused = get_tree().paused
    get_tree().paused = true
    # The dialog must accept the input while the tree is paused.
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS

    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        build_manager.cancel_build(row, col)
        # After the cancellation of the build the progress bar on the hex disappears — we redraw
        # the layer explicitly, because if it was the last active build, _process
        # will no longer call queue_redraw() for the layer of the bars.
        _redraw_progress_layer()
    )
    add_child(dialog)
    dialog.popup_centered()
    # The AcceptDialog has no signal canceled: the closing of the window by the cross simply
    # hides the dialog. We unpause in this case as well.
    dialog.visibility_changed.connect(func():
        if not dialog.visible and not was_paused:
            get_tree().paused = false
    )
