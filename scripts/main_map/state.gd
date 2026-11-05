@tool
extends Node2D

# MainMap is one node assembled from a chain of scripts in this folder: every link extends the
# previous one, so the node keeps a single state and a single API (the rest of the game talks to
# MainMap, never to a part of it). The chain ends in scripts/main_map.gd, which holds the engine
# callbacks and the order of the assembly.
#
# The order of the links is the order of their dependencies, not the order of the gameplay: a
# link calls the methods of the links below it, and GDScript resolves those calls at compile
# time. A call upwards does not compile, therefore a function belongs to the link where its
# callers are, and a function that moves must be moved far enough down the chain.
#
# This link — the state: the dimensions of the world and of the visible window, the tiles, the
# camera offsets, the settings of the interface, the references to the nodes of the scene and
# the trivial questions about the hexes and the towns.

# The shared formatting of the interface: the colours and the text of the readouts
# ("Treasury: N [icon]"), assembled the same way on the map and in the city.
const UiHelpers = preload("res://scripts/ui_helpers.gd")
const UI_THEME = preload("res://scripts/ui_theme.gd")

const HEX_RADIUS = 55

# --- The zoom of the map ---
# The map is always drawn at HEX_RADIUS in the local pixels of MapRenderer; the zoom is a
# CanvasItem scale on that node, therefore ONE transform magnifies everything it draws —
# the hexes, the icons, the rivers, the town rings and the progress bars.
# ZOOM_MIN still fits the Region of the first era (11x13 hexes = 1239x907 local pixels)
# into the 1152x768 window; ZOOM_MAX stops where the upscaled icons start to look soft.
const ZOOM_MIN: float = 0.6
const ZOOM_MAX: float = 1.5
# One notch of the mouse wheel.
const ZOOM_STEP: float = 1.15
# The rate of the exponential approach to the target zoom (1/s): a notch settles in ~0.2 s.
const ZOOM_SMOOTHING: float = 14.0
# The distance to the target below which the animation snaps: without it the exponential
# approach would keep redrawing the whole map for a vanishing remainder.
const ZOOM_SETTLE_EPS: float = 0.001

# --- The dimensions and the boundaries of the world/window ---

# The main parameters (map_rows, map_cols, start_ring_rows, start_ring_cols,
# region_width) are set in _load_map_config(). The map size comes from the
# world settings of a new game; the ring region region come from data/map_config.json.
# They are NOT constants, because:
#   1) the map size is chosen by the player;
#   2) on the transition to the next era the Ring and the Region expand.
var map_rows: int = 60 # The whole map: the rows (hexes)
var map_cols: int = 60 # The whole map: the columns (hexes)
var start_ring_rows: int = 7 # The starting Influence Ring: the rows
var start_ring_cols: int = 9 # The starting Influence Ring: the columns
var region_width: int = 2 # The width of the Region around the Ring (in hexes)
# The current (dynamically growing) Influence Ring: the size the boundaries below are built from.
var ring_rows: int = 7
var ring_cols: int = 9

# The current visible window: the Ring + the Region (the size, see _recalculate_bounds).
var region_rows: int = 11
var region_cols: int = 13

# The position of the city (the centre of the whole map).
var city_row: int = 30
var city_col: int = 30

# The absolute boundaries of the Influence Ring (inclusive) over the whole map.
var influence_start_row: int = 0
var influence_end_row: int = 0
var influence_start_col: int = 0
var influence_end_col: int = 0

# The absolute boundaries of the visible window — the Ring + the Region (inclusive).
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

# The current era (0 = the starting one). It is saved with the map state and mirrored into
# CityData.current_era_index, which gates the technologies and sets the width of the Region of
# the next era (data/eras.json).
var current_era: int = 0

# The debug action "Open the whole map" has revealed the whole map (debug_open_whole_map).
# The renderer lifts the era gate of the rings and of the roads of the towns on such a map
# (map_renderer._ensure_town_influence_cache / are_town_roads_visible): the reveal is
# deliberate, there is nothing left to hide. Stored in the save together with the tiles.
var debug_whole_map_revealed: bool = false

const SCOUTING_TIME_PER_HEX: float = 3.0

# The logistics of the goods on their way to the city (see delivery_manager.gd). It is
# created in code rather than placed in the scene: it has no visual part, and a scene
# node would only have to be kept in sync with the script for no gain.
const DELIVERY_MANAGER_SCRIPT := preload("res://scripts/delivery_manager.gd")

# The trade of the city with the towns (see town_trade_manager.gd). Created in code
# for the same reason as the logistics: no visual part, no scene node.
const TOWN_TRADE_MANAGER_SCRIPT := preload("res://scripts/town_trade_manager.gd")

# The fame of a good and the challenges of the era (see challenge_manager.gd). Created in code for
# the same reason as the trade: no visual part, and it reads the era and the claiming of the Region
# from the map it lives on.
const CHALLENGE_MANAGER_SCRIPT := preload("res://scripts/challenge_manager.gd")

# The active pause (see active_pause.gd): it draws the frame around the window and
# holds the queue of the waiting actions, therefore it is created in code together
# with its own layer.
const ACTIVE_PAUSE_SCRIPT := preload("res://scripts/active_pause.gd")

# The journal of the important messages (see journal.gd): the history itself has no
# visual part and is created in code, the window over the map is a scene.
const JOURNAL_SCRIPT := preload("res://scripts/journal.gd")
const JOURNAL_UI_SCENE := preload("res://scenes/journal.tscn")
const SAVE_LOAD_WINDOW_SCENE := preload("res://scenes/save_load_window.tscn")

# The technology that opens the scouting beyond the Region (the fog of war and
# the territory of the towns). Before it is learned the scouts can be sent only
# into the unexplored part of the Region, and the hexes outside the Region are inaccessible for
# the hover and the click (see is_hex_interactive). The data of the technology —
# data/technologies/antiquity.json, id "cartography".
const CARTOGRAPHY_TECH_ID := "cartography"
# The technology that allows building improvements on scouted resource hexes
# outside the Region (outposts). The data of the technology —
# data/technologies/antiquity.json, id "emporia".
const EMPORIA_TECH_ID := "emporia"

var tile_data = []
# The world is being built right now (a new game). The generation runs in stages with
# a frame between them so that the loading bar can advance, and those frames must not
# run the simulation, the drawing of a half-built map or the input of the map.
var world_generating := false
# The loading screen of the new game, put on the root by the main menu (see
# main_menu._show_loading_overlay). While it is absent — a test, the editor, a direct
# scene run — the world is built in one go, exactly as before.
var _loading_overlay: CanvasLayer = null
var offset_x: float = 0.0
var offset_y: float = 0.0
var scroll_offset = Vector2.ZERO
# The current zoom and the value the animation is heading to. The scroll offset stays in
# LOCAL pixels: the zoom only changes how they map to the screen, so the existing clamp
# (get_max_scroll) and every reader of the offset keep their meaning.
var zoom: float = 1.0
var zoom_target: float = 1.0
# The SCREEN point that stays in place while the zoom changes — the cursor that turned
# the wheel. The scroll offset is corrected around it when the gesture ends.
var _zoom_anchor: Vector2 = Vector2.ZERO
# The world point under the anchor, fixed for the whole gesture.
var _zoom_world: Vector2 = Vector2.ZERO

# The hexes of a unique terrain (for example, a soda lake). They are drawn even beyond the visible
# Region, therefore the list is kept apart from the tiles (see map_renderer).
var unique_terrain_hexes: Array = []

# The hexes of the centres of the towns — a mirror of town_manager.town_hexes for the renderer.
var town_hexes: Array = []

# The flat mirror of the rings of the towns (town_manager.town_influence_hexes) for the renderer.
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
# The speed of the scrolling of the map by the cursor standing at the edge of the screen
# (pixels per second, 100..1000 with a step of 50; the key interface/edge_scroll_speed in
# user://settings.cfg). The clamp itself lives in InputHandler — this value is passed
# through as it is.
var edge_scroll_speed: float = 300.0
var tooltip_delay: float = 0.5
var extended_tooltip_delay: float = 1.0
var building_detail_delay: float = 0.5
# The interval of the update of the data about the resources in the UI (sec, 1..5 with a step of 1; the key
# game/resource_display_interval in user://settings.cfg). It is also stored in
# CityData.resource_display_interval — there is also the accumulator and the "era" of the display.
var resource_display_interval: float = 1.0
# How long a message stays in the map HUD before it hides (sec, 1..10 with a step of 0.5;
# the key interface/hud_message_duration in user://settings.cfg). The clamp itself lives in
# hud_message.gd — this value is passed through as it is.
var hud_message_duration: float = 3.0
# Whether the wall clock is shown in the top right corner of the HUD (the key
# interface/show_clock in user://settings.cfg, on by default).
var show_clock: bool = true
# Whether the frame rate counter is shown next to the Menu button (the key
# interface/show_fps in user://settings.cfg, on by default).
var show_fps: bool = true

# The top right panel is anchored to the right edge of the screen with this margin.
const TOP_RIGHT_MARGIN := 40.0
# The panel is never lower than the buttons of the scene.
const TOP_RIGHT_PANEL_MIN_HEIGHT := 31.0

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

# The tick of the wall clock in the top right corner of the HUD. A Timer with
# PROCESS_MODE_ALWAYS, and not the _process below: _process does not run while the tree
# is paused, and the pause menu and the settings window are open exactly over a stopped
# world — a wall clock must keep showing the real time there.
var _clock_timer: Timer = null

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
@onready var journal_button = $HUD/VBoxContainer/JournalButton
@onready var menu_button = $TopRightLayer/TopRightPanel/TopRightBox/MenuButton
@onready var pause_button = $TopRightLayer/TopRightPanel/TopRightBox/PauseButton
@onready var clock_label = $TopRightLayer/TopRightPanel/TopRightBox/ClockLabel
@onready var fps_label = $TopRightLayer/TopRightPanel/TopRightBox/FpsLabel
@onready var top_right_panel = $TopRightLayer/TopRightPanel
@onready var top_right_box = $TopRightLayer/TopRightPanel/TopRightBox
@onready var pause_menu = $PauseMenu
@onready var build_manager = $BuildManager
@onready var map_renderer = $MapRenderer
@onready var highlight_layer = $MapRenderer/HighlightLayer
@onready var progress_bar_layer = $MapRenderer/ProgressBarLayer
@onready var improvement_state_layer = $MapRenderer/ImprovementStateLayer
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
# The logistics of the goods on the way to the city (see delivery_manager.gd). Created
# in _ready, before any production can be queued.
var delivery_manager: Node = null

# The trade with the towns: the orders of the town window, the standing contracts
# and their payments (see town_trade_manager.gd).
var town_trade_manager: Node = null

# The fame of a good and the challenges of the era: the counters of what the city gave away, the
# tiers the city has been paid for, and the tasks of data/challenges.json (see challenge_manager.gd).
var challenge_manager: Node = null

# The active pause: the queue of the actions, which wait for the resume of the
# simulation (see active_pause.gd). This node owns the flag of the pause of the
# tree — the pause menu and the active pause may be on at the same time.
var active_pause: Node = null

# The journal of the important messages (see journal.gd) and its window. The HUD
# pushes into the history, the window draws it, the save writes it out.
var journal: Node = null
@onready var journal_ui = JOURNAL_UI_SCENE.instantiate()

# The window of the saves: the place and the name of a save, or the list of the saved
# games (see save_load_window.gd). Opened by the pause menu, which stays behind it.
@onready var save_load_window = SAVE_LOAD_WINDOW_SCENE.instantiate()

var tech_popup: Control
# The window of the specialization: it is offered when the population reaches a milestone of
# data/specializations.json and holds the simulation stopped until the pick is made (see
# specialization_popup.gd).
var specialization_popup: Control
var research_hbox: HBoxContainer
var research_button: Button
var research_icon: TextureRect # the child TextureRect inside research_button
var research_label: Label # the child Label inside research_button
var research_progress_bar: ProgressBar
var _last_research_hud_tech: String = ""

# --- The natural transition to the next era ---
var era_dialog: ConfirmationDialog
var era_advance_button: Button

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
    highlight_layer.queue_redraw()

# Removes the selection from the hex and clears the control panel.
func clear_selection():
    control_panel.clear_selection()
    highlight_layer.queue_redraw()

# The handler of the completion/cancellation/pause of a build: it updates the control panel,
# so that it does not show the outdated state (for example, the "Build" button
# on the hex where the build has already finished).
func _on_control_panel_build_changed(_a = null, _b = null, _c = null, _d = null):
    control_panel.refresh()

# Returns the record of the town on the hex (row, col) or null.
func find_town_at(row: int, col: int):
    if town_manager == null:
        return null
    return town_manager.find_town_at(row, col)

func get_tile_data(row: int, col: int):
    if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
        return tile_data[row][col]
    return null

func is_valid_hex(row: int, col: int) -> bool:
    # Is the hex valid WITHIN the Region (the Ring + the Region).
    # It is used where the belonging to the Region is exactly what matters: the purchase
    # (claiming) of the chunks, the check of the composition of the chunk, the scouting before the learning of
    # the Cartography (see get_region_bounds). After the Cartography the scouting is not
    # limited by this — see get_scout_reach_bounds().
    return row >= region_start_row and row <= region_end_row and col >= region_start_col and col <= region_end_col

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

# Returns true, if the hex (row, col) enters the current Influence Ring.
func is_in_influence(row: int, col: int) -> bool:
    return row >= influence_start_row and row <= influence_end_row \
        and col >= influence_start_col and col <= influence_end_col
