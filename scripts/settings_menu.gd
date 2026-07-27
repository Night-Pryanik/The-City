# scripts/settings_menu.gd
extends Control

@onready var hex_borders_checkbox: CheckBox = find_child("HexBordersCheckBox", true, false)
@onready var edge_scrolling_checkbox: CheckBox = find_child("EdgeScrollingCheckBox", true, false)
@onready var back_button: Button = find_child("BackButton", true, false)

var config = ConfigFile.new()

func _ready():
    if not hex_borders_checkbox or not edge_scrolling_checkbox or not back_button:
        print("Ошибка: не все элементы найдены в сцене настроек!")
        return

    hex_borders_checkbox.add_theme_color_override("font_color", Color.WHITE)
    edge_scrolling_checkbox.add_theme_color_override("font_color", Color.WHITE)

    load_settings()
    back_button.pressed.connect(_on_back_pressed)
    hex_borders_checkbox.toggled.connect(_on_hex_borders_toggled)
    edge_scrolling_checkbox.toggled.connect(_on_edge_scrolling_toggled)

func load_settings():
    var err = config.load("user://settings.cfg")
    if err == OK:
        hex_borders_checkbox.button_pressed = config.get_value("interface", "show_hex_borders", true)
        edge_scrolling_checkbox.button_pressed = config.get_value("interface", "edge_scrolling", true)
    else:
        hex_borders_checkbox.button_pressed = true
        edge_scrolling_checkbox.button_pressed = true

func save_settings():
    config.set_value("interface", "show_hex_borders", hex_borders_checkbox.button_pressed)
    config.set_value("interface", "edge_scrolling", edge_scrolling_checkbox.button_pressed)
    config.save("user://settings.cfg")

func _apply_to_game():
    # Находим главную сцену игры (MainMap) и обновляем её настройки
    var root = get_tree().root
    var main_map = root.find_child("MainMap", true, false)
    if main_map and main_map.has_method("apply_settings"):
        main_map.apply_settings()

func _on_hex_borders_toggled(_pressed: bool):
    save_settings()
    _apply_to_game()

func _on_edge_scrolling_toggled(_pressed: bool):
    save_settings()
    _apply_to_game()

func _on_back_pressed():
    hide()
