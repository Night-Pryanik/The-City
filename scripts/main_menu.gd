extends Control

@onready var new_game_button = $VBoxContainer/NewGameButton
@onready var load_game_button = $VBoxContainer/LoadGameButton
@onready var quit_button = $VBoxContainer/QuitButton

func _ready():
    if SaveManager.has_save():
        load_game_button.disabled = false
    else:
        load_game_button.disabled = true

    new_game_button.pressed.connect(_on_new_game)
    load_game_button.pressed.connect(_on_load_game)
    quit_button.pressed.connect(_on_quit)

func _on_new_game():
    SaveManager.new_game()
    get_tree().change_scene_to_file("res://scenes/MainMap.tscn")

func _on_load_game():
    if SaveManager.load_game():
        get_tree().change_scene_to_file("res://scenes/MainMap.tscn")
    else:
        print("Ошибка загрузки сохранения")

func _on_quit():
    get_tree().quit()
