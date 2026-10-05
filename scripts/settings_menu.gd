# scripts/settings_menu.gd
extends Control

@onready var hex_borders_checkbox: CheckBox = find_child("HexBordersCheckBox", true, false)
@onready var edge_scrolling_checkbox: CheckBox = find_child("EdgeScrollingCheckBox", true, false)
@onready var back_button: Button = find_child("BackButton", true, false)
@onready var language_option_button: OptionButton = find_child("LanguageOptionButton", true, false)
@onready var tab_container: TabContainer = find_child("TabContainer", true, false)
@onready var tooltip_delay_slider: HSlider = find_child("TooltipDelaySlider", true, false)
@onready var tooltip_delay_value_label: Label = find_child("TooltipDelayValueLabel", true, false)
@onready var extended_tooltip_delay_slider: HSlider = find_child("ExtendedTooltipDelaySlider", true, false)
@onready var extended_tooltip_delay_value_label: Label = find_child("ExtendedTooltipDelayValueLabel", true, false)
@onready var building_detail_delay_slider: HSlider = find_child(
    "BuildingDetailDelaySlider", true, false)
@onready var building_detail_delay_value_label: Label = find_child(
    "BuildingDetailDelayValueLabel", true, false)
@onready var resource_display_interval_slider: HSlider = find_child(
    "ResourceDisplayIntervalSlider", true, false)
@onready var resource_display_interval_value_label: Label = find_child(
    "ResourceDisplayIntervalValueLabel", true, false)

var config = ConfigFile.new()

func _ready():
    var missing_controls = not hex_borders_checkbox or not edge_scrolling_checkbox \
            or not back_button or not tooltip_delay_slider \
            or not tooltip_delay_value_label \
            or not extended_tooltip_delay_slider \
            or not extended_tooltip_delay_value_label \
            or not building_detail_delay_slider \
            or not building_detail_delay_value_label \
            or not resource_display_interval_slider \
            or not resource_display_interval_value_label \
            or not language_option_button
    if missing_controls:
        print("Error: not all elements found in the settings scene!")
        return

    hex_borders_checkbox.add_theme_color_override("font_color", Color.WHITE)
    edge_scrolling_checkbox.add_theme_color_override("font_color", Color.WHITE)
    language_option_button.add_theme_color_override("font_color", Color.WHITE)
    tooltip_delay_value_label.add_theme_color_override("font_color", Color.WHITE)
    extended_tooltip_delay_value_label.add_theme_color_override("font_color", Color.WHITE)
    building_detail_delay_value_label.add_theme_color_override("font_color", Color.WHITE)
    resource_display_interval_value_label.add_theme_color_override("font_color", Color.WHITE)

    _apply_tab_titles()
    load_settings()
    _setup_language_option()
    back_button.pressed.connect(_on_back_pressed)
    hex_borders_checkbox.toggled.connect(_on_hex_borders_toggled)
    edge_scrolling_checkbox.toggled.connect(_on_edge_scrolling_toggled)
    tooltip_delay_slider.value_changed.connect(_on_tooltip_delay_changed)
    extended_tooltip_delay_slider.value_changed.connect(_on_extended_tooltip_delay_changed)
    building_detail_delay_slider.value_changed.connect(_on_building_detail_delay_changed)
    resource_display_interval_slider.value_changed.connect(_on_resource_display_interval_changed)
    language_option_button.item_selected.connect(_on_language_selected)

# The tab titles are set manually: Godot takes them from the node NAMES, and node
# names are not translated. The titles are translated here by tr() calls with
# literals — otherwise neither the catalog builder nor the .pot generation
# in the editor would see them. The function is called both when opening the
# window and on a language change.
func _apply_tab_titles():
    if not tab_container:
        return
    var titles := [
        tr("Game"),
        tr("Video"),
        tr("Audio"),
        tr("Interface"),
    ]
    for i in min(titles.size(), tab_container.get_tab_count()):
        tab_container.set_tab_title(i, titles[i])

# Fills in the language dropdown and sets the saved choice in it.
# The value of an item is a language code; the "system language" item is stored as "system".
func _setup_language_option():
    var languages: Array = LocalizationManager.available_languages()
    var selected := LocalizationManager.get_stored_locale()
    var selected_index := 0
    language_option_button.clear()
    for i in languages.size():
        var code := str(languages[i]["code"])
        if code == selected:
            selected_index = i
        language_option_button.add_item(LocalizationManager.get_language_label(code), i)
        language_option_button.set_item_metadata(i, code)
    language_option_button.select(selected_index)
    # The signal is connected in _ready, and select() does not send it: when the settings
    # window opens the language is not re-chosen, but simply shown as the current one.

func _on_language_selected(index: int):
    var code := str(language_option_button.get_item_metadata(index))
    if LocalizationManager.set_locale(code):
        # The tab titles and the scene text are translated by Godot itself on the
        # TranslationServer notification, while the language list and the label of
        # the selected item depend on LocalizationManager — we update them manually.
        _apply_tab_titles()
        _setup_language_option()

func load_settings():
    var err = config.load("user://settings.cfg")
    if err == OK:
        hex_borders_checkbox.button_pressed = config.get_value("interface", "show_hex_borders", true)
        edge_scrolling_checkbox.button_pressed = config.get_value("interface", "edge_scrolling", true)
        tooltip_delay_slider.value = config.get_value("interface", "tooltip_delay", 0.5)
        extended_tooltip_delay_slider.value = config.get_value("interface", "extended_tooltip_delay", 1.0)
        building_detail_delay_slider.value = config.get_value(
            "interface", "building_detail_delay", 0.5)
        resource_display_interval_slider.value = config.get_value(
            "game", "resource_display_interval", 1.0)
    else:
        hex_borders_checkbox.button_pressed = true
        edge_scrolling_checkbox.button_pressed = true
        tooltip_delay_slider.value = 0.5
        extended_tooltip_delay_slider.value = 1.0
        building_detail_delay_slider.value = 0.5
        resource_display_interval_slider.value = 1.0
    # The minimum value of the extended tooltip cannot be less than the main one
    extended_tooltip_delay_slider.min_value = tooltip_delay_slider.value
    _update_tooltip_delay_label()
    _update_extended_tooltip_delay_label()
    _update_building_detail_delay_label()
    _update_resource_display_interval_label()

func save_settings():
    # We re-read the file before writing: LocalizationManager writes the language here,
    # and without re-reading its key would be overwritten by our values.
    config.load("user://settings.cfg")
    config.set_value("interface", "show_hex_borders", hex_borders_checkbox.button_pressed)
    config.set_value("interface", "edge_scrolling", edge_scrolling_checkbox.button_pressed)
    config.set_value("interface", "tooltip_delay", tooltip_delay_slider.value)
    config.set_value("interface", "extended_tooltip_delay", extended_tooltip_delay_slider.value)
    config.set_value("interface", "building_detail_delay", building_detail_delay_slider.value)
    config.set_value("game", "resource_display_interval", resource_display_interval_slider.value)
    config.save("user://settings.cfg")

func _apply_to_game():
    # We find the main game scene (MainMap) and update its settings
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

func _on_tooltip_delay_changed(_value: float):
    _update_tooltip_delay_label()
    # The minimum value of the extended tooltip cannot be less than the main one
    if extended_tooltip_delay_slider.value < tooltip_delay_slider.value:
        extended_tooltip_delay_slider.value = tooltip_delay_slider.value
    save_settings()
    _apply_to_game()

func _on_extended_tooltip_delay_changed(_value: float):
    # We do not allow it to go below the main delay
    if extended_tooltip_delay_slider.value < tooltip_delay_slider.value:
        extended_tooltip_delay_slider.value = tooltip_delay_slider.value
    _update_extended_tooltip_delay_label()
    save_settings()
    _apply_to_game()

func _on_building_detail_delay_changed(_value: float):
    _update_building_detail_delay_label()
    save_settings()
    _apply_to_game()

func _on_resource_display_interval_changed(_value: float):
    _update_resource_display_interval_label()
    save_settings()
    _apply_to_game()

func _update_tooltip_delay_label():
    var seconds = snappedf(tooltip_delay_slider.value, 0.25)
    tooltip_delay_value_label.text = tr("%.2f sec") % seconds

func _update_extended_tooltip_delay_label():
    var seconds = snappedf(extended_tooltip_delay_slider.value, 0.25)
    extended_tooltip_delay_value_label.text = tr("%.2f sec") % seconds

func _update_building_detail_delay_label():
    var seconds = snappedf(building_detail_delay_slider.value, 0.25)
    building_detail_delay_value_label.text = tr("%.2f sec") % seconds

func _update_resource_display_interval_label():
    # The slider step is 1 second, fractional values do not happen (see CityData:
    # the simulation tick = 1 sec, a fractional interval would give an uneven rhythm).
    var seconds = int(round(resource_display_interval_slider.value))
    resource_display_interval_value_label.text = tr("%d sec") % seconds

func _on_back_pressed():
    hide()
