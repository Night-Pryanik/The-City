extends Control

# The cross-reference validator for data/*.json. It is declared via preload, and
# not as an autoload: it does not keep state between calls, and it is needed only by
# the main menu. An autoload for a single call would keep a set of
# rules in memory with no consumer at all.
const DataValidator = preload("res://scripts/data_validator.gd")
const DataProblemsWindow = preload("res://scripts/data_problems_window.gd")
const UiHelpers = preload("res://scripts/ui_helpers.gd")
const ModListScene = preload("res://scenes/mod_list.tscn")
const WorldPreview = preload("res://scripts/world_preview.gd")

# The width of the city name field. It does not follow anything else: the name column is
# sized to it.
const NAME_FIELD_WIDTH := 340

# The content of the new game window. The width comes from the mod list, which is the
# widest of the tabs; the height is chosen for the settings list and the map preview, and
# the window keeps it on every tab.
const DIALOG_CONTENT_WIDTH := 860
const DIALOG_CONTENT_HEIGHT := 520
const DIALOG_MIN_CONTENT_HEIGHT := 360
const DIALOG_EDGE_MARGIN := 24

# The room the map preview takes on the right of the City and World tabs, and the height of
# one line of the settings list.
const PREVIEW_WIDTH := 360
const SETTING_ROW_HEIGHT := 32
const SETTING_CONTROL_HEIGHT := 30
const STEP_FIELD_WIDTH := 58

const TAB_CITY := 0
const TAB_WORLD := 1
const TAB_MODS := 2

# The map size presets offered in the world settings (the square side in hexes), and the
# bounds of the custom size. The player chooses one for a new game; the default is medium.
const MAP_SIZE_PRESETS: Array[int] = [30, 60, 100, 150, 200]
const MIN_MAP_SIZE := 10
const MAX_MAP_SIZE := 200
const DEFAULT_MAP_SIZE := 60

# The number of towns a new world is generated with, and the lower bound of the field. The
# generator places as many as the map allows: a crowded map simply ends up with fewer.
const DEFAULT_TOWN_COUNT := 16
const MIN_TOWN_COUNT := 0
# The ceiling follows the map: one town per this many hexes, which is 40 on the medium map and
# 111 on a 100×100 one. A fixed ceiling would either choke a giant map or flood a small one.
const HEXES_PER_TOWN := 90

# The sea generation modes, in the order of the dropdown. The values are the "mode" field of
# the sea configuration (CityData.world_sea); "none" leaves the map without a sea.
const SEA_MODES: Array[String] = ["none", "edge", "noise"]
const SEA_MODE_EDGE := "edge"
const SEA_MODE_NOISE := "noise"

# The kinds of the controls of the "Seas" section: a whole number, a fraction, a pair of
# whole numbers ("from" and "to") and a checkbox.
const SEA_INT := "int"
const SEA_FLOAT := "float"
const SEA_PAIR := "pair"
const SEA_CHECK := "check"

const SEA_FIELD_WIDTH := 86

@onready var continue_button = $VBoxContainer/ContinueButton
@onready var new_game_button = $VBoxContainer/NewGameButton
@onready var load_game_button = $VBoxContainer/LoadGameButton
@onready var settings_button = $VBoxContainer/SettingsButton
@onready var quit_button = $VBoxContainer/QuitButton

# The window of the saves, created on the first click on "Load game".
var save_load_window: CanvasLayer = null
# The dialog of a new game: one window with a tab per question (the city, the world, the
# mods). It is built once and kept — the choice of mods survives a "Back".
var new_game_dialog: ConfirmationDialog = null
var tab_container: TabContainer = null
var city_name_edit: LineEdit = null
# The world settings of a new game (the map size and the number of towns). They are read
# once, when the game starts.
var map_size_option: OptionButton = null
var custom_size_row: HBoxContainer = null
var custom_size_edit: LineEdit = null
var town_count_edit: LineEdit = null
var town_count_minus: Button = null
var town_count_plus: Button = null
# The count of towns can follow the map size instead of being chosen. While it does, the
# field is read-only and the step buttons are off.
var proportional_check: CheckBox = null
# The "Seas" section of the world settings: the mode dropdown, one entry per sea setting
# (keyed by its field in CityData.world_sea) and the rows with the modes they belong to.
var sea_mode_option: OptionButton = null
var sea_controls: Dictionary = {}
var sea_rows: Array = []
# The map previews, one on the City tab and one on the World tab. Both show the same world,
# so they are refreshed together.
var world_previews: Array = []
var mod_list = null
# The preview seed stays fixed while settings change, keeping those changes comparable. The
# player can reroll it explicitly with the button beside either preview.
var _preview_seed: int = 0

func _ready():
    # The data comes first: the tooltip of "Continue game" names the era of the save,
    # and on a cold start the menu is the first scene — GameData is not loaded yet.
    _check_game_data()
    _refresh_save_buttons()

    continue_button.pressed.connect(_on_continue_game)
    new_game_button.pressed.connect(_on_new_game)
    load_game_button.pressed.connect(_on_load_game)
    settings_button.pressed.connect(_on_settings)
    quit_button.pressed.connect(_on_quit)

# Both items that need a save are gated by the same fact. The tooltip of "Continue game"
# names the save the click will take, so the button cannot promise one game and load
# another. The state is re-read after the window is closed as well: the last save can be
# deleted from its list.
func _refresh_save_buttons():
    var resume := SaveManager.get_resume_save()
    continue_button.disabled = resume.is_empty()
    continue_button.tooltip_text = UiHelpers.save_tooltip(resume)
    load_game_button.disabled = not SaveManager.has_save()

# Checks the integrity of the game data before the start of a game.
#
# The main menu is the first scene (run/main_scene in project.godot), therefore
# the check fires immediately after the game starts and before the player begins
# building: the MainMap scene with map generation has not been created yet.
#
# The problems found are shown in a WINDOW, and not just written to the console: the
# data author needs to see which identifier is missing and in which field it was
# referenced. Only a short summary is duplicated to the console — so that
# the error is not lost when running in headless mode.
func _check_game_data():
    # The validator needs the full set of data. Usually it is already loaded
    # (for example, when returning from a game), but on a cold start — it is not.
    if not GameData.data_loaded:
        GameData.load_all_data()

    var problems: Array = DataValidator.new().validate(GameData)
    if problems.is_empty():
        return

    # We hang the window on the window root, and not on the main menu: the anchors of
    # the menu Control are not set to the screen edges (scenes/main_menu.tscn), and the overlay
    # would cover only part of the screen.
    #
    # The addition is deferred: this code runs inside the _ready() of the main
    # menu, which means the tree root is still setting up its children
    # at that moment (it is adding the main_menu scene) — a direct add_child() on the root
    # is rejected with "Parent node is busy setting up children". We fill
    # the contents on the ready signal: before it the _ready() of the window has not built
    # the layout yet, and show_problems() would fall on null nodes.
    var window = Control.new()
    window.set_script(DataProblemsWindow)
    window.ready.connect(window.show_problems.bind(problems), CONNECT_ONE_SHOT)
    get_tree().root.add_child.call_deferred(window)

    var counts := DataValidator.new().count_by_kind(problems)
    print("Game data check: found %d problems (%s)" % [
        problems.size(), str(counts)])
    for problem in problems:
        print("  - ", problem["message"])

# The fast path: no window and no questions. The tooltip has already told the player
# which save the click takes.
func _on_continue_game():
    if SaveManager.load_game():
        get_tree().change_scene_to_file("res://scenes/MainMap.tscn")
    else:
        # The save vanished between the refresh and the click: the menu must not keep
        # offering a game that cannot be loaded.
        _refresh_save_buttons()

# A new game is one window with three tabs: the city, the world, the mods. The tab that
# opens is the city, because the name is the only thing the player has to type; the other
# two have working defaults.
func _on_new_game():
    if new_game_dialog == null:
        _build_new_game_dialog()
    mod_list.open(ModManager.active_ids)
    _refresh_mods_tab()
    city_name_edit.text = tr("City")
    tab_container.current_tab = TAB_CITY
    _popup_new_game_dialog()
    _refresh_town_row()
    _refresh_sea_rows()
    _preview_seed = randi()
    _refresh_preview()
    city_name_edit.grab_focus()
    city_name_edit.select_all()

# The window keeps ONE size on all three tabs. The width comes from the mod list, the
# widest of them; a window that resized itself when the player switched tabs would jump
# under the cursor.
#
# The frame of a window (the title bar and the shadow) is drawn OUTSIDE the rect this
# node reports, and the frame is what the player sees, so the margins are kept for the
# decorated rect: a window sized by the bare rect alone would touch the screen edge.
func _popup_new_game_dialog():
    var screen := Vector2i(get_viewport().get_visible_rect().size)
    tab_container.custom_minimum_size = Vector2(DIALOG_CONTENT_WIDTH, DIALOG_CONTENT_HEIGHT)
    new_game_dialog.popup_centered()

    # A screen too short for the full window takes the height from the content instead of
    # pushing the buttons off the edge.
    if screen.y > 0:
        var frame := new_game_dialog.get_size_with_decorations().y - new_game_dialog.size.y
        var room := float(screen.y - DIALOG_EDGE_MARGIN * 2) - frame
        if room < float(DIALOG_CONTENT_HEIGHT):
            tab_container.custom_minimum_size.y = maxf(room, float(DIALOG_MIN_CONTENT_HEIGHT))
            new_game_dialog.reset_size()
            new_game_dialog.popup_centered()

    if screen.x <= 0 or screen.y <= 0:
        return
    var deco := new_game_dialog.get_size_with_decorations()
    var target := (screen - deco) / 2
    new_game_dialog.position += target - new_game_dialog.get_position_with_decorations()

func _build_new_game_dialog():
    var dialog = ConfirmationDialog.new()
    dialog.title = tr("New game")
    dialog.ok_button_text = tr("Start")
    dialog.cancel_button_text = tr("Back")

    # AcceptDialog stretches its single child to the content area, so the tabs own the
    # whole window. The tab container paints no background of its own: the pages would
    # otherwise sit on a darker plate than the buttons under them.
    tab_container = TabContainer.new()
    tab_container.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
    dialog.add_child(tab_container)

    tab_container.add_child(_page_margin(_build_city_tab()))
    tab_container.add_child(_page_margin(_build_world_tab()))
    tab_container.add_child(_build_mods_tab())
    tab_container.set_tab_title(TAB_CITY, tr("City"))
    tab_container.set_tab_title(TAB_WORLD, tr("World"))
    tab_container.set_tab_title(TAB_MODS, tr("Mods"))

    city_name_edit.text_submitted.connect(func(_text): dialog.get_ok_button().pressed.emit())
    dialog.confirmed.connect(func(): _start_new_game(city_name_edit.text))
    add_child(dialog)
    new_game_dialog = dialog

# The city tab: the one thing the player has to type, next to the preview of the world the
# city will be founded in.
func _build_city_tab() -> Control:
    var page := HBoxContainer.new()
    page.name = "CityTab"
    page.add_theme_constant_override("separation", 16)

    var column := VBoxContainer.new()
    column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    column.add_theme_constant_override("separation", 10)
    page.add_child(column)

    var name_row = HBoxContainer.new()
    name_row.custom_minimum_size = Vector2(0, SETTING_CONTROL_HEIGHT)
    name_row.add_theme_constant_override("separation", 4)
    city_name_edit = LineEdit.new()
    city_name_edit.text = tr("City")
    # The field keeps its own width: a name field stretched across the tab reads as a text
    # area, not as a name.
    city_name_edit.custom_minimum_size = Vector2(NAME_FIELD_WIDTH, SETTING_CONTROL_HEIGHT)
    city_name_edit.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    city_name_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    city_name_edit.select_all_on_focus = true
    name_row.add_child(city_name_edit)

    var random_button = Button.new()
    random_button.custom_minimum_size = Vector2(SETTING_CONTROL_HEIGHT, SETTING_CONTROL_HEIGHT)
    random_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    random_button.expand_icon = true
    random_button.icon = load("res://icons/dice.svg")
    random_button.tooltip_text = tr("Suggest another name")
    random_button.pressed.connect(func():
        _ensure_game_data()
        city_name_edit.text = GameData.get_random_city_name()
        city_name_edit.select_all()
        city_name_edit.grab_focus()
    )
    name_row.add_child(random_button)
    column.add_child(name_row)

    var hint := Label.new()
    hint.text = tr("An empty name gives the city a random one.")
    hint.add_theme_font_size_override("font_size", 12)
    hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    # A wrapped label reports its minimum height at its minimum width, which would be the
    # height of its longest word.
    hint.custom_minimum_size = Vector2(300, 0)
    column.add_child(hint)

    page.add_child(_make_preview())
    return page

# The world tab: the settings, one line each, and the preview of what they produce. The
# list scrolls, so the tab takes any number of settings without growing the window.
func _build_world_tab() -> Control:
    var page := HBoxContainer.new()
    page.name = "WorldTab"
    page.add_theme_constant_override("separation", 16)

    var scroll := ScrollContainer.new()
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    page.add_child(scroll)

    # A scroll container clips at its own edge, and a control that ends exactly there loses
    # the border the focus ring draws on it. The padding keeps every row off the edge.
    var padding := MarginContainer.new()
    padding.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    padding.add_theme_constant_override("margin_right", 6)
    scroll.add_child(padding)

    var column := VBoxContainer.new()
    column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    column.add_theme_constant_override("separation", 8)
    padding.add_child(column)

    _build_world_settings(column)
    page.add_child(_make_preview())
    return page

# The mods tab. The list IS the tab: it is 860 px wide, and that is what sets the width of
# the whole window. It takes no margins — it was laid out for a window of its own.
func _build_mods_tab() -> Control:
    mod_list = ModListScene.instantiate()
    mod_list.selection_changed.connect(_on_mods_changed)
    return mod_list

# The room between the settings of a tab and its edges. The mod list is the one page that
# does without it: it is a window's worth of content on its own.
func _page_margin(page: Control) -> Control:
    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_bottom", 12)
    margin.add_child(page)
    return margin

# One line of the settings list: the name of the setting on the left, its control on the
# right. The controls keep their own width, so their right edges line up.
#
# The hint of a row is long enough to need breaking, and the engine's own tooltip never
# breaks a line (see scripts/wrapped_tooltip.gd), so it is wrapped.
func _add_setting_row(column: VBoxContainer, text: String, control: Control,
        tooltip: String = "") -> HBoxContainer:
    var row := HBoxContainer.new()
    row.custom_minimum_size = Vector2(0, SETTING_ROW_HEIGHT)
    row.add_theme_constant_override("separation", 12)

    var label := Label.new()
    label.text = text
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    if not tooltip.is_empty():
        WrappedTooltip.attach(label, tooltip)
    row.add_child(label)

    control.size_flags_horizontal = Control.SIZE_SHRINK_END
    control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    row.add_child(control)

    column.add_child(row)
    return row

# The map preview of a tab. Both tabs that have room for one get their own copy: the tabs
# are separate subtrees, and a node cannot be in two of them at once.
func _make_preview() -> Control:
    var column := VBoxContainer.new()
    column.custom_minimum_size = Vector2(PREVIEW_WIDTH, 0)
    column.size_flags_horizontal = Control.SIZE_SHRINK_END
    column.add_theme_constant_override("separation", 6)

    var preview = WorldPreview.new()
    preview.name = "WorldPreview"
    preview.custom_minimum_size = Vector2(PREVIEW_WIDTH, 240)
    preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
    preview.max_map_size = MAX_MAP_SIZE
    world_previews.append(preview)
    column.add_child(preview)

    var regenerate_button := Button.new()
    regenerate_button.name = "RegeneratePreviewButton"
    regenerate_button.text = tr("Regenerate")
    regenerate_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    regenerate_button.pressed.connect(_regenerate_preview)
    column.add_child(regenerate_button)

    var disclaimer := Label.new()
    disclaimer.name = "PreviewDisclaimerLabel"
    disclaimer.text = tr("This map is only an approximate preview; the actual world will be generated separately and may differ.")
    disclaimer.custom_minimum_size = Vector2(PREVIEW_WIDTH - 24, 0)
    disclaimer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    disclaimer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    disclaimer.add_theme_font_size_override("font_size", 12)
    disclaimer.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
    column.add_child(disclaimer)
    return column

# The previews show the world the current settings describe, so they are refreshed from one
# place instead of each control knowing about them. The picture of the water is built once and
# handed to both: the two tabs show the same world, and building the sea mask twice would
# double the cost of every change of a setting.
func _resolved_sea_config(seed_value: int = 0) -> Dictionary:
    var cfg := _selected_sea_config()
    cfg["sides"] = SeaManager.resolve_sides(cfg, seed_value)
    return cfg

func _refresh_preview():
    var side := _selected_map_size()
    var towns := _selected_town_count()
    var picture := WorldPreview.build(side, _resolved_sea_config(_preview_seed), _preview_seed)
    for preview in world_previews:
        preview.set_world(side, towns, picture)

func _regenerate_preview():
    var next_seed := randi()
    if next_seed == _preview_seed:
        next_seed += 1
    _preview_seed = next_seed
    _refresh_preview()

# The world settings of a new game: the map size, the number of towns and the seas. Every
# setting is one line of the list, and the list grows downwards.
func _build_world_settings(column: VBoxContainer):
    # The map size: a preset dropdown and a custom side field that appears only when
    # "Custom size" is chosen. The map is square, so one side applies to width and height.
    map_size_option = OptionButton.new()
    map_size_option.add_item(tr("Small (30×30)"))
    map_size_option.add_item(tr("Medium (60×60)"))
    map_size_option.add_item(tr("Large (100×100)"))
    map_size_option.add_item(tr("Huge (150×150)"))
    map_size_option.add_item(tr("Giant (200×200)"))
    map_size_option.add_item(tr("Custom size"))
    map_size_option.select(MAP_SIZE_PRESETS.find(DEFAULT_MAP_SIZE))
    map_size_option.item_selected.connect(_on_map_size_selected)
    map_size_option.custom_minimum_size = Vector2(200, SETTING_CONTROL_HEIGHT)
    _add_setting_row(column, tr("Map size"), map_size_option,
            tr("The side of the square map, in hexes."))

    custom_size_edit = LineEdit.new()
    custom_size_edit.custom_minimum_size = Vector2(90, SETTING_CONTROL_HEIGHT)
    custom_size_edit.max_length = 3
    custom_size_edit.tooltip_text = tr("A whole number from %d to %d.") % [MIN_MAP_SIZE, MAX_MAP_SIZE]
    custom_size_edit.text_changed.connect(_on_custom_size_text_changed)
    custom_size_edit.focus_exited.connect(_normalize_custom_size)
    custom_size_row = _add_setting_row(column, tr("Side length"), custom_size_edit)
    custom_size_row.visible = false

    # The towns: a number that can be typed or stepped with the buttons beside it. The map
    # size decides how many of them fit, so the field is not tied to the presets above it.
    town_count_edit = LineEdit.new()
    town_count_edit.custom_minimum_size = Vector2(STEP_FIELD_WIDTH, SETTING_CONTROL_HEIGHT)
    town_count_edit.max_length = 3
    town_count_edit.text = str(DEFAULT_TOWN_COUNT)
    town_count_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
    town_count_edit.text_changed.connect(_on_town_count_text_changed)
    town_count_edit.focus_exited.connect(_normalize_town_count)

    var stepper := HBoxContainer.new()
    stepper.add_theme_constant_override("separation", 4)
    town_count_minus = _make_step_button("−", -1)
    town_count_plus = _make_step_button("+", 1)
    stepper.add_child(town_count_minus)
    stepper.add_child(town_count_edit)
    stepper.add_child(town_count_plus)

    # The checkbox ties the count to the map size. The number is then computed, and neither
    # the field nor the buttons take input.
    proportional_check = CheckBox.new()
    proportional_check.text = tr("Proportional")
    proportional_check.tooltip_text = tr("Proportional to the map size")
    proportional_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    proportional_check.toggled.connect(_on_proportional_toggled)

    var towns_control := HBoxContainer.new()
    towns_control.add_theme_constant_override("separation", 8)
    towns_control.add_child(proportional_check)
    towns_control.add_child(stepper)
    _add_setting_row(column, tr("Number of towns"), towns_control)

    _build_sea_settings(column)

# The "Seas" section: how the seas of the world are generated. The rows follow the modes of
# the generator (CityData.world_sea): the coastal strips own the island settings, the
# elevation field owns its own, and the common settings are shared by the two. A row is
# shown only while its mode is chosen, so the list never offers a setting the chosen mode
# would ignore.
func _build_sea_settings(column: VBoxContainer):
    _add_section_header(column, tr("Seas"))

    sea_mode_option = OptionButton.new()
    sea_mode_option.add_item(tr("None"))
    sea_mode_option.add_item(tr("Coasts"))
    sea_mode_option.add_item(tr("Noise"))
    sea_mode_option.custom_minimum_size = Vector2(200, SETTING_CONTROL_HEIGHT)
    sea_mode_option.select(maxi(0, SEA_MODES.find(str(_sea_default("mode")))))
    sea_mode_option.item_selected.connect(_on_sea_mode_selected)
    var mode_tooltip := tr("Coasts — strips with bays along the map edges; Noise — the sea comes from an elevation field; None — no sea at all.")
    WrappedTooltip.attach(sea_mode_option, mode_tooltip)
    _add_setting_row(column, tr("Mode"), sea_mode_option, mode_tooltip)

    var both: Array = [SEA_MODE_EDGE, SEA_MODE_NOISE]
    var edge: Array = [SEA_MODE_EDGE]
    var noise: Array = [SEA_MODE_NOISE]

    _add_sea_pair_row(column, "sides", tr("Edges with sea"),
            tr("How many map edges get a sea: from the minimum to the maximum. Zero leaves the map without a sea."),
            0, 4, both)
    _add_sea_check_row(column, "beach", tr("Beaches"),
            tr("Land next to the sea becomes a beach."), both)
    _add_sea_int_row(column, "max_sea_depth", tr("Maximum sea depth"),
            tr("How far the sea may reach from the map edge, in hexes, so that it does not eat the map."),
            1, 100, both)
    _add_sea_int_row(column, "coast_max_depth", tr("Shallow water depth"),
            tr("The deepest shallow water off the coast, in hexes; the depth varies smoothly along the shore."),
            1, 20, both)

    _add_sea_int_row(column, "edge_width_min", tr("Narrowest coast"),
            tr("The narrowest coastal strip, in hexes. Zero lets the shore break into bays."),
            0, 100, edge)
    _add_sea_int_row(column, "edge_width_max", tr("Widest coast"),
            tr("The widest coastal strip, in hexes."), 0, 100, edge)
    _add_sea_float_row(column, "edge_envelope_strength", tr("Bays"),
            tr("0 — a solid strip from edge to edge, about 0.7 — a bay in the middle of a side with land at its ends, 1 — only the peak of the bay."),
            0.0, 1.0, edge)

    # The island settings belong to the island checkbox: while it is off there is nothing to
    # set up, so they leave the list with their heading.
    var islands_header: Dictionary = _add_sea_subheader(column, tr("Islands in the seas"), edge)
    var islands_check: CheckBox = _add_sea_check_row(column, "edge_islands_enabled",
            tr("Generate islands"), tr("Grow islands inside the seas."), edge)
    islands_header["gate"] = islands_check
    islands_check.toggled.connect(_on_sea_islands_toggled)
    _add_sea_pair_row(column, "edge_island_size", tr("Island size"),
            tr("The smallest and the largest island, in hexes."), 1, 50, edge, islands_check)
    _add_sea_float_row(column, "edge_island_density", tr("Island density"),
            tr("The number of islands follows the area of the sea: the area times this share, plus a random spread. A small sea often gets none, a large one may get many."),
            0.0, 1.0, edge, islands_check)
    _add_sea_int_row(column, "edge_island_min_distance", tr("Distance between islands"),
            tr("The least distance between two islands, in hexes, so that they do not stick together."),
            0, 50, edge, islands_check)
    _add_sea_int_row(column, "edge_island_max_attempts", tr("Island search attempts"),
            tr("How many times the generator tries to find a free spot for an island before it gives up."),
            1, 1000, edge, islands_check)
    _add_sea_float_row(column, "noise_sea_level", tr("Sea level"),
            tr("The land/sea threshold: a hex at or below it is sea."), -1.0, 1.0, noise)
    _add_sea_float_row(column, "noise_strength", tr("Coast raggedness"),
            tr("The amplitude of the elevation noise: how ragged the coast is and how many islands it makes."),
            0.0, 2.0, noise)
    _add_sea_float_row(column, "noise_edge_gradient", tr("Continentality"),
            tr("0 — islands everywhere, 1 — the sea strictly at the edges of the map."),
            0.0, 1.0, noise)
    _add_sea_float_row(column, "noise_city_bump", tr("Land around the city"),
            tr("The elevation hill around the city: it guarantees that the city starts on a continent."),
            0.0, 5.0, noise)
    _add_sea_int_row(column, "noise_city_bump_radius", tr("Guaranteed land radius"),
            tr("The radius around the city that is always land, in hexes."), 0, 50, noise)

# A heading of the settings list, with a line above it: the sections of a long list read
# apart, and the line tells where the next one starts.
func _add_section_header(column: VBoxContainer, text: String):
    var separator := HSeparator.new()
    separator.custom_minimum_size = Vector2(0, 14)
    column.add_child(separator)

    var label := Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 16)
    column.add_child(label)

# A heading inside a section, one size below it. The returned entry is the line itself: a
# heading that introduces a group gated by a checkbox takes the gate after the checkbox is
# built (see _add_sea_row).
func _add_sea_subheader(column: VBoxContainer, text: String, modes: Array) -> Dictionary:
    var label := Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 13)
    column.add_child(label)
    var entry := {"row": label, "modes": modes}
    sea_rows.append(entry)
    return entry

# A whole-number row of the "Seas" section.
func _add_sea_int_row(column: VBoxContainer, key: String, label: String, tooltip: String,
        lo: int, hi: int, modes: Array, gate: BaseButton = null):
    var edit := _make_sea_field(str(int(_sea_default(key))), false, tooltip)
    _add_sea_row(column, key, label, edit, tooltip, modes,
            {"kind": SEA_INT, "control": edit, "lo": lo, "hi": hi,
                    "default": int(_sea_default(key))}, gate)

# A fractional row of the "Seas" section.
func _add_sea_float_row(column: VBoxContainer, key: String, label: String, tooltip: String,
        lo: float, hi: float, modes: Array, gate: BaseButton = null):
    var edit := _make_sea_field(_format_number(float(_sea_default(key))), true, tooltip)
    _add_sea_row(column, key, label, edit, tooltip, modes,
            {"kind": SEA_FLOAT, "control": edit, "lo": lo, "hi": hi,
                    "default": float(_sea_default(key))}, gate)

# A row of two whole numbers — the bounds of a range. The two fields read as one value, so
# they stand together in one control.
func _add_sea_pair_row(column: VBoxContainer, key: String, label: String, tooltip: String,
        lo: int, hi: int, modes: Array, gate: BaseButton = null):
    var default: Array = _sea_default(key)
    var from_edit := _make_sea_field(str(int(default[0])), false, tooltip)
    var to_edit := _make_sea_field(str(int(default[1])), false, tooltip)

    var box := HBoxContainer.new()
    box.add_theme_constant_override("separation", 6)
    box.add_child(from_edit)
    var dash := Label.new()
    dash.text = "–"
    box.add_child(dash)
    box.add_child(to_edit)

    _add_sea_row(column, key, label, box, tooltip, modes,
            {"kind": SEA_PAIR, "from": from_edit, "to": to_edit, "lo": lo, "hi": hi,
                    "default": [int(default[0]), int(default[1])]}, gate)

# A checkbox row of the "Seas" section. It is returned, because the rows it switches may
# hang on it.
func _add_sea_check_row(column: VBoxContainer, key: String, label: String, tooltip: String,
        modes: Array, gate: BaseButton = null) -> CheckBox:
    var check := CheckBox.new()
    check.button_pressed = bool(_sea_default(key))
    WrappedTooltip.attach(check, tooltip)
    check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    check.toggled.connect(func(_pressed): _refresh_preview())
    _add_sea_row(column, key, label, check, tooltip, modes,
            {"kind": SEA_CHECK, "control": check, "default": bool(_sea_default(key))}, gate)
    return check

# Registers a line of the "Seas" section: it is drawn like every other setting, and it is
# remembered with the modes it belongs to and the checkbox that switches it on (see
# _refresh_sea_rows), and with the control that holds its value (see _selected_sea_config).
func _add_sea_row(column: VBoxContainer, key: String, label: String, control: Control,
        tooltip: String, modes: Array, spec: Dictionary, gate: BaseButton = null):
    var row := _add_setting_row(column, label, control, tooltip)
    sea_rows.append({"row": row, "modes": modes, "gate": gate})
    spec["row"] = row
    sea_controls[key] = spec

# A field of the "Seas" section. A whole number keeps the digits, a fraction also keeps a
# single decimal point and a leading minus. The field is rewritten only when the input
# really holds something else, so the caret does not jump on every keystroke.
func _make_sea_field(value: String, fractional: bool, tooltip: String) -> LineEdit:
    var edit := LineEdit.new()
    edit.custom_minimum_size = Vector2(SEA_FIELD_WIDTH, SETTING_CONTROL_HEIGHT)
    edit.max_length = 6
    edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
    edit.text = value
    WrappedTooltip.attach(edit, tooltip)
    edit.text_changed.connect(func(text): _keep_number(edit, text, fractional))
    # The picture follows the number while it is being typed, not only when the field loses
    # focus: the sea is the one part of the world a setting changes by a visible amount.
    edit.text_changed.connect(func(_text): _refresh_preview())
    edit.focus_exited.connect(_normalize_sea_fields)
    return edit

# The value of a sea setting a new game starts from (CityData.DEFAULT_SEA).
func _sea_default(key: String):
    return CityData.DEFAULT_SEA.get(key)

# The rows of the "Seas" section follow the chosen mode, and the rows of a group follow the
# checkbox that switches the group on. A row that is not shown keeps its value: switching
# back and forth does not lose it.
func _refresh_sea_rows():
    if sea_mode_option == null:
        return
    var mode: String = SEA_MODES[maxi(0, sea_mode_option.selected)]
    for entry in sea_rows:
        var shown: bool = mode in entry["modes"]
        var gate: BaseButton = entry.get("gate")
        if shown and gate != null:
            shown = gate.button_pressed
        entry["row"].visible = shown

func _on_sea_mode_selected(_index: int):
    _refresh_sea_rows()
    _refresh_preview()

# The island checkbox refreshes the rows it switches. The picture follows the checkbox on its
# own: every check box of the section is wired to the preview (see _add_sea_check_row).
func _on_sea_islands_toggled(_pressed: bool):
    _refresh_sea_rows()

# The sea configuration the world will be generated with. Every row is read, including the
# rows of a mode that is not chosen: the generator ignores the fields of the other mode, and
# the values are then kept while the player compares the two.
func _selected_sea_config() -> Dictionary:
    var cfg: Dictionary = CityData.DEFAULT_SEA.duplicate(true)
    if sea_mode_option == null:
        return cfg
    cfg["mode"] = SEA_MODES[maxi(0, sea_mode_option.selected)]
    for key in sea_controls.keys():
        var spec: Dictionary = sea_controls[key]
        match spec["kind"]:
            SEA_CHECK:
                cfg[key] = spec["control"].button_pressed
            SEA_INT:
                cfg[key] = _read_whole(spec["control"], spec["lo"], spec["hi"], spec["default"])
            SEA_FLOAT:
                cfg[key] = _read_fraction(spec["control"], spec["lo"], spec["hi"], spec["default"])
            SEA_PAIR:
                cfg[key] = _read_pair(spec)
    return cfg

# A whole number of a sea setting. An empty or a malformed field is read as the default of
# the setting: the game must never be started with a number that cannot be parsed.
func _read_whole(edit: LineEdit, lo: int, hi: int, fallback: int) -> int:
    var raw := edit.text.strip_edges()
    if not raw.is_valid_int():
        return clampi(fallback, lo, hi)
    return clampi(int(raw), lo, hi)

func _read_fraction(edit: LineEdit, lo: float, hi: float, fallback: float) -> float:
    var raw := edit.text.strip_edges()
    if not raw.is_valid_float():
        return clampf(fallback, lo, hi)
    return clampf(float(raw), lo, hi)

# The bounds of a range, kept in order: the "from" never rises above the "to".
func _read_pair(spec: Dictionary) -> Array:
    var lo: int = spec["lo"]
    var hi: int = spec["hi"]
    var from_value := _read_whole(spec["from"], lo, hi, int(spec["default"][0]))
    var to_value := _read_whole(spec["to"], lo, hi, int(spec["default"][1]))
    return [from_value, maxi(from_value, to_value)]

# Every field of the "Seas" section shows the value the game will use: a number outside the
# allowed range is pulled to the nearest bound when the field loses focus.
func _normalize_sea_fields():
    for spec in sea_controls.values():
        match spec["kind"]:
            SEA_INT:
                spec["control"].text = str(_read_whole(spec["control"], spec["lo"],
                        spec["hi"], spec["default"]))
            SEA_FLOAT:
                spec["control"].text = _format_number(_read_fraction(spec["control"],
                        spec["lo"], spec["hi"], spec["default"]))
            SEA_PAIR:
                var pair := _read_pair(spec)
                spec["from"].text = str(pair[0])
                spec["to"].text = str(pair[1])

# A fraction of a sea setting, without the trailing zeros of a longer number.
func _format_number(value: float) -> String:
    return String.num(value, 3)

# The fields of the "Seas" section take digits only; a fraction also takes a decimal point
# and a minus sign at the front.
func _keep_number(edit: LineEdit, text: String, fractional: bool):
    var filtered := ""
    var has_point := false
    for ch in text:
        if ch.is_valid_int():
            filtered += ch
        elif ch == "-" and filtered.is_empty():
            filtered += ch
        elif ch == "." and fractional and not has_point:
            has_point = true
            filtered += ch
    if filtered != text:
        edit.text = filtered

# A square button with a sign on it. The two of them and the field between them read as one
# control, so they share the height of the field.
func _make_step_button(sign: String, step: int) -> Button:
    var button := Button.new()
    button.text = sign
    button.custom_minimum_size = Vector2(SETTING_CONTROL_HEIGHT, SETTING_CONTROL_HEIGHT)
    button.pressed.connect(_on_town_count_step.bind(step))
    return button

# The custom row is shown only when the player picked "Custom size" (the last item).
func _on_map_size_selected(index: int):
    var custom := index == MAP_SIZE_PRESETS.size()
    custom_size_row.visible = custom
    if custom and custom_size_edit.text.strip_edges().is_empty():
        custom_size_edit.text = str(DEFAULT_MAP_SIZE)
    _refresh_town_row()
    _refresh_preview()
    if not custom:
        return
    custom_size_edit.grab_focus()
    custom_size_edit.select_all()

# The side input accepts only digits: the map size is a whole positive number.
func _on_custom_size_text_changed(text: String):
    _keep_digits(custom_size_edit, text)
    # A half-typed number is clamped to the nearest bound, and the preview would jump to
    # that bound on every keystroke: it follows only a value that is already valid.
    var raw := custom_size_edit.text.strip_edges()
    if not raw.is_empty() and int(raw) >= MIN_MAP_SIZE and int(raw) <= MAX_MAP_SIZE:
        _refresh_town_row()
        _refresh_preview()

# A number outside the allowed range is pulled to the nearest bound when the field loses
# focus, so the player sees the value the game is about to use.
func _normalize_custom_size():
    custom_size_edit.text = str(_selected_map_size())
    _refresh_town_row()
    _refresh_preview()

# The town count is a whole number of the same kind.
func _on_town_count_text_changed(text: String):
    _keep_digits(town_count_edit, text)
    var raw := town_count_edit.text.strip_edges()
    if not raw.is_empty() and int(raw) <= _max_town_count(_selected_map_size()):
        _refresh_preview()

func _normalize_town_count():
    town_count_edit.text = str(_selected_town_count())
    _refresh_preview()

# The buttons step the number and stop at the bounds, so a click never produces a value the
# field would have to clamp on the next focus change.
func _on_town_count_step(step: int):
    var value := clampi(_selected_town_count() + step, MIN_TOWN_COUNT,
            _max_town_count(_selected_map_size()))
    town_count_edit.text = str(value)
    _refresh_preview()

func _on_proportional_toggled(_pressed: bool):
    _refresh_town_row()
    _refresh_preview()

# Brings the town row in line with the rest of the settings. The ceiling follows the map, so a
# count typed for a bigger world comes down when the map shrinks; the computed count replaces
# the typed one while the checkbox is on, and the field then takes no input — a number the
# player cannot change must not look editable.
func _refresh_town_row():
    if proportional_check == null:
        return
    var side := _selected_map_size()
    var ceiling := _max_town_count(side)
    var proportional := proportional_check.button_pressed

    town_count_edit.max_length = str(ceiling).length()
    town_count_edit.tooltip_text = tr("A whole number from %d to %d. Zero leaves the map without towns.") \
            % [MIN_TOWN_COUNT, ceiling]

    town_count_edit.editable = not proportional
    town_count_minus.disabled = proportional
    town_count_plus.disabled = proportional

    if proportional:
        # A field that cannot be typed into must not keep the caret of the keyboard focus.
        if town_count_edit.has_focus():
            town_count_edit.release_focus()
        town_count_edit.text = str(_proportional_town_count(side))
    else:
        town_count_edit.text = str(_selected_town_count())

# The most towns a map of this size may hold. The ceiling is a density, not a number: it is
# what makes the same field usable on a 30×30 village map and on a 200×200 world.
func _max_town_count(side: int) -> int:
    return maxi(1, roundi(float(side) * float(side) / float(HEXES_PER_TOWN)))

# The count that matches the map. It keeps the default 16 towns on the medium map and follows
# the SIDE of the map rather than its area: an area-proportional 200×200 world would be 178
# towns, and the density thins out as the map grows instead.
func _proportional_town_count(side: int) -> int:
    return clampi(roundi(DEFAULT_TOWN_COUNT * float(side) / float(DEFAULT_MAP_SIZE)),
            MIN_TOWN_COUNT, _max_town_count(side))

# Both numeric fields of the world settings take digits only. The field is rewritten only
# when the input really holds something else, so the caret does not jump on every keystroke.
func _keep_digits(edit: LineEdit, text: String):
    var filtered := ""
    for ch in text:
        if ch.is_valid_int():
            filtered += ch
    if filtered != text:
        edit.text = filtered

# The side of the square map chosen in the world settings. For a preset it is its fixed
# value; for "Custom size" it is the clamped number in the input field. Falls back to the
# default when the settings have not been built (a direct start of a new game).
func _selected_map_size() -> int:
    if map_size_option == null:
        return DEFAULT_MAP_SIZE
    var index := map_size_option.selected
    if index >= 0 and index < MAP_SIZE_PRESETS.size():
        return MAP_SIZE_PRESETS[index]
    var raw := custom_size_edit.text.strip_edges()
    if raw.is_empty():
        return DEFAULT_MAP_SIZE
    return clampi(int(raw), MIN_MAP_SIZE, MAX_MAP_SIZE)

# The number of towns the map will be generated with. While the count follows the map size
# it is computed, not read. Falls back to the default when the settings have not been built
# (a direct start of a new game).
func _selected_town_count() -> int:
    if proportional_check != null and proportional_check.button_pressed:
        return _proportional_town_count(_selected_map_size())
    if town_count_edit == null:
        return DEFAULT_TOWN_COUNT
    var raw := town_count_edit.text.strip_edges()
    if raw.is_empty():
        return DEFAULT_TOWN_COUNT
    return clampi(int(raw), MIN_TOWN_COUNT, _max_town_count(_selected_map_size()))

# The set is handed over at once, so the game that starts runs exactly the data the
# player has chosen. The data itself is rebuilt later, when something really reads it:
# a full rebuild on every checkbox makes the list feel slow, and the set of the game is
# known without it.
func _on_mods_changed(mod_ids: Array):
    ModManager.set_active(mod_ids)
    _refresh_mods_tab()

# The random name is the only thing inside this dialog that reads the data, and the data
# is stale as soon as the set changes (ModManager drops it). The start of the game
# reloads it on its own.
func _ensure_game_data():
    if not GameData.data_loaded:
        GameData.load_all_data()

# The title of the tab tells at a glance that a game is about to start with mods, without
# opening the tab.
func _refresh_mods_tab():
    if tab_container == null or mod_list == null:
        return
    var count: int = mod_list.selected_ids().size()
    tab_container.set_tab_title(TAB_MODS,
            tr("Mods") if count == 0 else "%s (%d)" % [tr("Mods"), count])

func _start_new_game(city_name: String):
    # Empty input — we substitute a random name.
    if city_name.strip_edges().is_empty():
        city_name = GameData.get_random_city_name()
    SaveManager.new_game()
    CityData.city_name = city_name.strip_edges()
    CityData.world_map_size = _selected_map_size()
    CityData.world_town_count = _selected_town_count()
    CityData.world_sea = _resolved_sea_config(_preview_seed)
    # The overlay is hung on the ROOT, not on the menu: the scene change frees the
    # menu, and the world generation runs inside MainMap. MainMap updates the very
    # same bar and removes it when the world is ready.
    _show_loading_overlay()
    await get_tree().process_frame
    get_tree().change_scene_to_file("res://scenes/MainMap.tscn")

# The loading screen of a new game: a dimmed background, a caption, a progress bar and
# the name of the current stage of the generation. It lives on a high CanvasLayer,
# because MainMap draws its own HUD layers while the world is being built.
func _show_loading_overlay() -> CanvasLayer:
    var overlay = CanvasLayer.new()
    overlay.name = "LoadingOverlay"
    overlay.layer = 128

    var bg = ColorRect.new()
    bg.color = Color(0, 0, 0, 0.7)
    bg.set_anchors_preset(Control.PRESET_FULL_RECT)
    overlay.add_child(bg)

    var vbox = VBoxContainer.new()
    vbox.name = "VBoxContainer"
    vbox.set_anchors_preset(Control.PRESET_CENTER)
    # The preset alone puts the top left corner at the centre of the screen and the box
    # would grow down and to the right of it. Growing around the anchor point is what
    # actually centres it.
    vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
    vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
    vbox.alignment = BoxContainer.ALIGNMENT_CENTER
    vbox.add_theme_constant_override("separation", 12)
    overlay.add_child(vbox)

    var title = Label.new()
    title.name = "TitleLabel"
    title.text = tr("Creating a new world...")
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 28)
    vbox.add_child(title)

    var bar = ProgressBar.new()
    bar.name = "ProgressBar"
    bar.custom_minimum_size = Vector2(400, 24)
    bar.min_value = 0.0
    bar.max_value = 1.0
    bar.value = 0.0
    vbox.add_child(bar)

    var status = Label.new()
    status.name = "StatusLabel"
    status.text = tr("Preparing...")
    status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    status.add_theme_font_size_override("font_size", 16)
    vbox.add_child(status)

    get_tree().root.add_child(overlay)
    return overlay

func _on_load_game():
    if not SaveManager.has_save():
        return
    if save_load_window == null:
        save_load_window = load("res://scenes/save_load_window.tscn").instantiate()
        add_child(save_load_window)
        save_load_window.load_requested.connect(_on_load_requested)
        save_load_window.closed.connect(_refresh_save_buttons)
    save_load_window.open_load()

func _on_load_requested(slot_id: String):
    if SaveManager.load_game(slot_id):
        save_load_window.close()
        get_tree().change_scene_to_file("res://scenes/MainMap.tscn")
    else:
        print("Save loading error")

func _on_settings():
    var settings_menu = load("res://scenes/settings_menu.tscn").instantiate()
    add_child(settings_menu)
    settings_menu.show()

func _on_quit():
    get_tree().quit()
