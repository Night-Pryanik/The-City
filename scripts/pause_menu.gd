extends CanvasLayer

signal save_pressed
signal load_pressed
signal new_game_pressed

func _ready():
    # Ищем кнопки по имени во всех вложенных узлах (рекурсивно)
    var save_btn = find_child("SaveButton", true, false)
    var load_btn = find_child("LoadButton", true, false)
    var new_game_btn = find_child("NewGameButton", true, false)
    var exit_btn = find_child("ExitButton", true, false)

    if save_btn: save_btn.pressed.connect(_on_save)
    else: printerr("SaveButton not found in PauseMenu")

    if load_btn: load_btn.pressed.connect(_on_load)
    else: printerr("LoadButton not found in PauseMenu")

    if new_game_btn: new_game_btn.pressed.connect(_on_new_game)
    else: printerr("NewGameButton not found in PauseMenu")

    if exit_btn: exit_btn.pressed.connect(_on_exit)
    else: printerr("ExitButton not found in PauseMenu")

func _on_save():
    emit_signal("save_pressed")
    # hide()

func _on_load():
    emit_signal("load_pressed")

func _on_new_game():
    emit_signal("new_game_pressed")

func _on_exit():
    get_tree().quit()
