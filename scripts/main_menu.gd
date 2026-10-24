extends Control

# The cross-reference validator for data/*.json. It is declared via preload, and
# not as an autoload: it does not keep state between calls, and it is needed only by
# the main menu. An autoload for a single call would keep a set of
# rules in memory with no consumer at all.
const DataValidator = preload("res://scripts/data_validator.gd")
const DataProblemsWindow = preload("res://scripts/data_problems_window.gd")
const UiHelpers = preload("res://scripts/ui_helpers.gd")
const ModListScene = preload("res://scenes/mod_list.tscn")

# The width of the city name field. It does not follow anything else: the name window is
# sized to it and keeps that width.
const NAME_FIELD_WIDTH := 340

@onready var continue_button = $VBoxContainer/ContinueButton
@onready var new_game_button = $VBoxContainer/NewGameButton
@onready var load_game_button = $VBoxContainer/LoadGameButton
@onready var settings_button = $VBoxContainer/SettingsButton
@onready var quit_button = $VBoxContainer/QuitButton

# The window of the saves, created on the first click on "Load game".
var save_load_window: CanvasLayer = null
# The dialog of a new game: the city name, and the way into the window of the mods. It is
# built once and kept — the choice of mods survives a "Back".
var new_game_dialog: ConfirmationDialog = null
var city_name_edit: LineEdit = null
var mods_button: Button = null
# The window of the mods. A window of its own: the list is 860 px wide and the name is not,
# and one window that changes its width under the cursor is worse than two that keep theirs.
var mods_window: AcceptDialog = null
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

# A new game starts with the city name. The mods of that game are a separate window behind
# a button: they are a detail of the game being created, not its first question, and most
# games are started without any.
func _on_new_game():
    if new_game_dialog == null:
        _build_new_game_dialog()
    if mods_window == null:
        _build_mods_window()
    mod_list.open(ModManager.active_ids)
    _refresh_mods_button()
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
    content.add_theme_constant_override("separation", 8)
    dialog.add_child(content)

    var name_row = HBoxContainer.new()
    name_row.custom_minimum_size = Vector2(0, 30)
    name_row.add_theme_constant_override("separation", 4)
    city_name_edit = LineEdit.new()
    city_name_edit.text = tr("City")
    # The field keeps its own width. The mod list is 860 px wide when it is unfolded, and
    # a name field stretched to that width reads as a text area, not as a name.
    city_name_edit.custom_minimum_size = Vector2(NAME_FIELD_WIDTH, 30)
    city_name_edit.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
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

    # The name is one question and the mods are another, with a window of their own: the
    # line keeps the button of the second window apart from the name of the first.
    var separator := HSeparator.new()
    content.add_child(separator)

    mods_button = Button.new()
    mods_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
    mods_button.pressed.connect(_open_mods_window)
    content.add_child(mods_button)

    city_name_edit.text_submitted.connect(func(_text): dialog.get_ok_button().pressed.emit())
    dialog.confirmed.connect(func(): _start_new_game(city_name_edit.text))
    dialog.canceled.connect(_on_new_game_canceled)
    add_child(dialog)
    new_game_dialog = dialog

# The list fills its window: an AcceptDialog stretches its child to the content area, so
# the window is exactly as wide as the list and keeps that width.
func _build_mods_window():
    var window := AcceptDialog.new()
    window.title = tr("Mods")
    window.ok_button_text = tr("Close")
    window.confirmed.connect(_on_mods_window_closed)
    window.canceled.connect(_on_mods_window_closed)

    mod_list = ModListScene.instantiate()
    mod_list.selection_changed.connect(_on_mods_changed)
    mod_list.layout_changed.connect(_on_mod_list_layout_changed)
    window.add_child(mod_list)
    add_child(window)
    mods_window = window

# One window at a time: a window of the mods is exclusive, so the dialog of the name steps
# aside and comes back when the mods are closed. Neither of the two ever changes its width.
func _open_mods_window():
    new_game_dialog.hide()
    mods_window.popup_centered()
    _refit_mods_window()

func _on_mods_window_closed():
    _refresh_mods_button()
    if new_game_dialog != null:
        new_game_dialog.popup_centered()
        city_name_edit.grab_focus()

# The mods window belongs to the dialog of a new game: a game that is not started leaves
# no window behind it.
func _on_new_game_canceled():
    if mods_window != null:
        mods_window.hide()

# The problems panel takes room only while it has something to say, so the window is
# refitted when the list reports that its room has changed. The width does not change: the
# panel spans the list, it does not widen it.
func _on_mod_list_layout_changed():
    _refit_mods_window()

# The minimum size of the list is known only after its container has been sorted, so the
# refit waits a frame. It is also what puts the window in the middle of the screen: the
# size a fresh popup computes may be the one of a list that has not been laid out yet.
func _refit_mods_window():
    if mods_window == null or not mods_window.visible:
        return
    await get_tree().process_frame
    if not mods_window.visible:
        return
    mods_window.reset_size()
    var screen: Vector2 = get_viewport().get_visible_rect().size
    if screen.x > 0.0 and screen.y > 0.0:
        mods_window.position = Vector2i((screen - Vector2(mods_window.size)) * 0.5)

# The set is handed over at once, so the game that starts runs exactly the data the
# player has chosen. The data itself is rebuilt later, when something really reads it:
# a full rebuild on every checkbox makes the list feel slow, and the set of the game is
# known without it.
func _on_mods_changed(mod_ids: Array):
    ModManager.set_active(mod_ids)
    _refresh_mods_button()

# The random name is the only thing inside this dialog that reads the data, and the data
# is stale as soon as the set changes (ModManager drops it). The start of the game
# reloads it on its own.
func _ensure_game_data():
    if not GameData.data_loaded:
        GameData.load_all_data()

# The caption tells at a glance that a game is about to start with mods, without opening
# the window of the mods.
func _refresh_mods_button():
    var count: int = mod_list.selected_ids().size()
    mods_button.text = tr("Mods") if count == 0 else "%s (%d)" % [tr("Mods"), count]

func _start_new_game(city_name: String):
    # Empty input — we substitute a random name.
    if city_name.strip_edges().is_empty():
        city_name = GameData.get_random_city_name()
    SaveManager.new_game()
    CityData.city_name = city_name.strip_edges()
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
