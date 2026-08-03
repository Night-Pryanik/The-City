extends CanvasLayer

signal save_pressed
signal load_pressed
signal new_game_pressed

var settings_menu_instance: Control = null
var settings_canvas: CanvasLayer = null

func _ready():
    var resume_btn = find_child("ResumeButton", true, false)
    var save_btn = find_child("SaveButton", true, false)
    var load_btn = find_child("LoadButton", true, false)
    var new_game_btn = find_child("NewGameButton", true, false)
    var exit_btn = find_child("ExitButton", true, false)
    var settings_btn = find_child("SettingsButton", true, false)

    if resume_btn: resume_btn.pressed.connect(_on_resume)
    else: printerr("ResumeButton not found in PauseMenu")

    if save_btn: save_btn.pressed.connect(_on_save)
    else: printerr("SaveButton not found in PauseMenu")

    if load_btn: load_btn.pressed.connect(_on_load)
    else: printerr("LoadButton not found in PauseMenu")

    if new_game_btn: new_game_btn.pressed.connect(_on_new_game)
    else: printerr("NewGameButton not found in PauseMenu")

    if exit_btn: exit_btn.pressed.connect(_on_exit)
    else: printerr("ExitButton not found in PauseMenu")

    if settings_btn: settings_btn.pressed.connect(_on_settings)
    else: printerr("SettingsButton not found in PauseMenu")

func _on_resume():
    hide()

func _on_save():
    emit_signal("save_pressed")
    hide()

func _on_load():
    emit_signal("load_pressed")

func _on_new_game():
    emit_signal("new_game_pressed")

func _on_exit():
    get_tree().quit()

func _on_settings():
    if not settings_menu_instance:
        settings_canvas = CanvasLayer.new()
        add_child(settings_canvas)
        settings_menu_instance = load("res://scenes/settings_menu.tscn").instantiate()
        settings_canvas.add_child(settings_menu_instance)
        settings_menu_instance.visibility_changed.connect(_on_settings_menu_visibility_changed)

    # Передаём ссылку на этот экземпляр в main_map.gd
    var main = get_parent()
    main.settings_menu = settings_menu_instance

    hide()  # прячем паузу
    settings_menu_instance.show()

func _on_settings_menu_visibility_changed():
    if settings_menu_instance and not settings_menu_instance.visible:
        # Меню настроек закрыли – показываем меню паузы снова
        show()
