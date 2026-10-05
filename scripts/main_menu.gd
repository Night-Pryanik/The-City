extends Control

# The cross-reference validator for data/*.json. It is declared via preload, and
# not as an autoload: it does not keep state between calls, and it is needed only by
# the main menu. An autoload for a single call would keep a set of
# rules in memory with no consumer at all.
const DataValidator = preload("res://scripts/data_validator.gd")
const DataProblemsWindow = preload("res://scripts/data_problems_window.gd")

@onready var new_game_button = $VBoxContainer/NewGameButton
@onready var load_game_button = $VBoxContainer/LoadGameButton
@onready var settings_button = $VBoxContainer/SettingsButton
@onready var quit_button = $VBoxContainer/QuitButton

func _ready():
    if SaveManager.has_save():
        load_game_button.disabled = false
    else:
        load_game_button.disabled = true

    new_game_button.pressed.connect(_on_new_game)
    load_game_button.pressed.connect(_on_load_game)
    settings_button.pressed.connect(_on_settings)
    quit_button.pressed.connect(_on_quit)

    _check_game_data()

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

func _on_new_game():
    # We load the data in advance: it is needed for a random name suggestion
    # in the city naming dialog.
    GameData.load_all_data()
    _show_city_name_dialog()

func _show_city_name_dialog():
    var dialog = ConfirmationDialog.new()
    dialog.title = tr("Choose a city name")
    dialog.ok_button_text = tr("OK")
    dialog.cancel_button_text = tr("Back")

    var name_row = HBoxContainer.new()
    name_row.custom_minimum_size = Vector2(0, 30)
    name_row.add_theme_constant_override("separation", 4)
    var line_edit = LineEdit.new()
    line_edit.text = tr("City")
    line_edit.custom_minimum_size = Vector2(260, 30)
    line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    line_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    line_edit.select_all_on_focus = true
    name_row.add_child(line_edit)

    var random_button = Button.new()
    random_button.custom_minimum_size = Vector2(30, 30)
    random_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    random_button.expand_icon = true
    random_button.icon = load("res://icons/dice.svg")
    random_button.tooltip_text = tr("Suggest another name")
    random_button.pressed.connect(func():
        line_edit.text = GameData.get_random_city_name()
        line_edit.select_all()
        line_edit.grab_focus()
    )
    name_row.add_child(random_button)
    dialog.add_child(name_row)

    line_edit.text_submitted.connect(func(_text): dialog.get_ok_button().pressed.emit())
    dialog.confirmed.connect(func():
        _start_new_game(line_edit.text)
        dialog.queue_free()
    )
    dialog.canceled.connect(dialog.queue_free)
    add_child(dialog)
    dialog.popup_centered()
    line_edit.grab_focus()
    line_edit.select_all()

func _start_new_game(city_name: String):
    # Empty input — we substitute a random name.
    if city_name.strip_edges().is_empty():
        city_name = GameData.get_random_city_name()
    SaveManager.new_game()
    CityData.city_name = city_name.strip_edges()
    get_tree().change_scene_to_file("res://scenes/MainMap.tscn")

func _on_load_game():
    if SaveManager.load_game():
        get_tree().change_scene_to_file("res://scenes/MainMap.tscn")
    else:
        print("Save loading error")

func _on_settings():
    var settings_menu = load("res://scenes/settings_menu.tscn").instantiate()
    add_child(settings_menu)
    settings_menu.show()

func _on_quit():
    get_tree().quit()
