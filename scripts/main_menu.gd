extends Control

# The cross-reference validator for data/*.json. It is declared via preload, and
# not as an autoload: it does not keep state between calls, and it is needed only by
# the main menu. An autoload for a single call would keep a set of
# rules in memory with no consumer at all.
const DataValidator = preload("res://scripts/data_validator.gd")
const DataProblemsWindow = preload("res://scripts/data_problems_window.gd")
const UiHelpers = preload("res://scripts/ui_helpers.gd")
const ModListScene = preload("res://scenes/mod_list.tscn")

@onready var continue_button = $VBoxContainer/ContinueButton
@onready var new_game_button = $VBoxContainer/NewGameButton
@onready var load_game_button = $VBoxContainer/LoadGameButton
@onready var settings_button = $VBoxContainer/SettingsButton
@onready var quit_button = $VBoxContainer/QuitButton

# The window of the saves, created on the first click on "Load game".
var save_load_window: CanvasLayer = null
# The dialog of a new game: the city name, and the mods of that game folded away under
# it. It is built once and kept — the choice of mods survives a "Back".
var new_game_dialog: ConfirmationDialog = null
var city_name_edit: LineEdit = null
var mods_toggle: Button = null
var mods_holder: Control = null
var mod_list = null

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

# A new game starts with the city name. The mods of that game are folded away under the
# name field: they are a detail of the game being created, not its first question, and
# most games are started without any.
func _on_new_game():
    if new_game_dialog == null:
        _build_new_game_dialog()
    mod_list.open(ModManager.active_ids)
    _refresh_mods_toggle()
    _set_mods_expanded(false)
    city_name_edit.text = tr("City")
    new_game_dialog.popup_centered()
    city_name_edit.grab_focus()
    city_name_edit.select_all()

func _build_new_game_dialog():
    var dialog = ConfirmationDialog.new()
    dialog.title = tr("Choose a city name")
    dialog.ok_button_text = tr("OK")
    dialog.cancel_button_text = tr("Back")

    # An AcceptDialog does not arrange its children: every direct child is put at the
    # content origin, on top of the others. The rows live in a column of their own.
    var content = VBoxContainer.new()
    content.add_theme_constant_override("separation", 6)
    dialog.add_child(content)

    var name_row = HBoxContainer.new()
    name_row.custom_minimum_size = Vector2(0, 30)
    name_row.add_theme_constant_override("separation", 4)
    city_name_edit = LineEdit.new()
    city_name_edit.text = tr("City")
    city_name_edit.custom_minimum_size = Vector2(260, 30)
    city_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    city_name_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    city_name_edit.select_all_on_focus = true
    name_row.add_child(city_name_edit)

    var random_button = Button.new()
    random_button.custom_minimum_size = Vector2(30, 30)
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
    content.add_child(name_row)

    mods_toggle = Button.new()
    mods_toggle.toggle_mode = true
    mods_toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    mods_toggle.toggled.connect(_set_mods_expanded)
    content.add_child(mods_toggle)

    # The dialog sizes itself to its children and does not care whether they are
    # visible, so the room for the list is reserved by a holder of its own: a plain
    # Control asks for exactly what it is told to ask for.
    mods_holder = Control.new()
    mods_holder.clip_contents = true
    content.add_child(mods_holder)

    mod_list = ModListScene.instantiate()
    mod_list.visible = false
    mod_list.selection_changed.connect(_on_mods_changed)
    mod_list.layout_changed.connect(_on_mod_list_layout_changed)
    mods_holder.add_child(mod_list)
    mod_list.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    city_name_edit.text_submitted.connect(func(_text): dialog.get_ok_button().pressed.emit())
    dialog.confirmed.connect(func(): _start_new_game(city_name_edit.text))
    add_child(dialog)
    new_game_dialog = dialog

# The list is unfolded by the toggle, and it starts folded on every new game: the player
# who does not care about mods never has to scroll past them.
func _set_mods_expanded(expanded: bool):
    mods_toggle.set_pressed_no_signal(expanded)
    mod_list.visible = expanded
    _fit_dialog()

func _fit_dialog():
    var list_size: Vector2 = mod_list.get_combined_minimum_size()
    mods_holder.custom_minimum_size = Vector2(list_size.x, list_size.y if mod_list.visible else 0.0)
    # An AcceptDialog keeps the size it was shown with, so the window is refitted to its
    # content and put back into the middle — otherwise the window would hang in a corner
    # of the screen after it grows or shrinks.
    new_game_dialog.reset_size()
    var screen: Vector2 = get_viewport().get_visible_rect().size
    if screen.x > 0.0 and screen.y > 0.0:
        new_game_dialog.position = Vector2i((screen - Vector2(new_game_dialog.size)) * 0.5)

# The minimum size of the list is known only after its container has been sorted, so the
# refit after a change inside the list waits a frame.
func _on_mod_list_layout_changed():
    await get_tree().process_frame
    _fit_dialog()

# The set is handed over at once, so the game that starts runs exactly the data the
# player has chosen. The data itself is rebuilt later, when something really reads it:
# a full rebuild on every checkbox makes the list feel slow, and the set of the game is
# known without it.
func _on_mods_changed(mod_ids: Array):
    ModManager.set_active(mod_ids)
    _refresh_mods_toggle()

# The random name is the only thing inside this dialog that reads the data, and the data
# is stale as soon as the set changes (ModManager drops it). The start of the game
# reloads it on its own.
func _ensure_game_data():
    if not GameData.data_loaded:
        GameData.load_all_data()

# The caption tells at a glance that a game is about to start with mods, even while the
# list is folded.
func _refresh_mods_toggle():
    var count: int = mod_list.selected_ids().size()
    mods_toggle.text = tr("Mods") if count == 0 else "%s (%d)" % [tr("Mods"), count]

func _start_new_game(city_name: String):
    # Empty input — we substitute a random name.
    if city_name.strip_edges().is_empty():
        city_name = GameData.get_random_city_name()
    SaveManager.new_game()
    CityData.city_name = city_name.strip_edges()
    get_tree().change_scene_to_file("res://scenes/MainMap.tscn")

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
