# scripts/settings_menu.gd
extends Control

@onready var tab_container = $TabContainer
@onready var hex_borders_checkbox = $TabContainer/Интерфейс/VBoxContainer/HexBordersCheckBox
@onready var edge_scrolling_checkbox = $TabContainer/Интерфейс/VBoxContainer/EdgeScrollingCheckBox
@onready var back_button = $BackButton

var config = ConfigFile.new()

func _ready():
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
        # Значения по умолчанию
        hex_borders_checkbox.button_pressed = true
        edge_scrolling_checkbox.button_pressed = true

func save_settings():
    config.set_value("interface", "show_hex_borders", hex_borders_checkbox.button_pressed)
    config.set_value("interface", "edge_scrolling", edge_scrolling_checkbox.button_pressed)
    config.save("user://settings.cfg")

func _on_hex_borders_toggled(_pressed: bool):
    save_settings()

func _on_edge_scrolling_toggled(_pressed: bool):
    save_settings()

func _on_back_pressed():
    hide()
