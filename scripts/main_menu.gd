extends Control

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

func _on_new_game():
    # Загружаем данные заранее: нужно для случайного названия-предложения
    # в диалоге именования города.
    GameData.load_all_data()
    _show_city_name_dialog()

func _show_city_name_dialog():
    var dialog = ConfirmationDialog.new()
    dialog.title = "Выберите название города"
    dialog.ok_button_text = "Ок"
    dialog.cancel_button_text = "Назад"

    var name_row = HBoxContainer.new()
    name_row.custom_minimum_size = Vector2(0, 30)
    name_row.add_theme_constant_override("separation", 4)
    var line_edit = LineEdit.new()
    line_edit.text = "Город"
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
    random_button.tooltip_text = "Предложить другое название"
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
    # Пустой ввод — подставляем случайное название.
    if city_name.strip_edges().is_empty():
        city_name = GameData.get_random_city_name()
    SaveManager.new_game()
    CityData.city_name = city_name.strip_edges()
    get_tree().change_scene_to_file("res://scenes/MainMap.tscn")

func _on_load_game():
    if SaveManager.load_game():
        get_tree().change_scene_to_file("res://scenes/MainMap.tscn")
    else:
        print("Ошибка загрузки сохранения")

func _on_settings():
    var settings_menu = load("res://scenes/settings_menu.tscn").instantiate()
    add_child(settings_menu)
    settings_menu.show()

func _on_quit():
    get_tree().quit()
