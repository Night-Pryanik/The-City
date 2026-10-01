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
        print("Ошибка: не все элементы найдены в сцене настроек!")
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

# Заголовки вкладок ставятся вручную: Godot берёт их из ИМЁН узлов, а имена
# узлов не переводятся. Заголовки переводятся здесь вызовами tr() с
# литералами — иначе их не увидит ни сборщик каталогов, ни генерация .pot
# в редакторе. Функция вызывается и при открытии окна, и при смене языка.
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

# Заполняет выпадающий список языков и ставит в него сохранённый выбор.
# Значение пункта — код языка; пункт «язык системы» хранится как "system".
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
    # Сигнал подключается в _ready, а select() его не шлёт: при открытии окна
    # настроек язык заново не выбирается, а просто показывается текущий.

func _on_language_selected(index: int):
    var code := str(language_option_button.get_item_metadata(index))
    if LocalizationManager.set_locale(code):
        # Подписи вкладок и текст сцен Godot переведёт сам по уведомлению
        # TranslationServer, а список языков и подпись выбранного пункта
        # зависят от LocalizationManager — обновляем их вручную.
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
    # Минимальное значение расширенного тултипа не может быть меньше основного
    extended_tooltip_delay_slider.min_value = tooltip_delay_slider.value
    _update_tooltip_delay_label()
    _update_extended_tooltip_delay_label()
    _update_building_detail_delay_label()
    _update_resource_display_interval_label()

func save_settings():
    # Перечитываем файл перед записью: язык сюда пишет LocalizationManager,
    # и без перечитывания его ключ был бы затёрт нашими значениями.
    config.load("user://settings.cfg")
    config.set_value("interface", "show_hex_borders", hex_borders_checkbox.button_pressed)
    config.set_value("interface", "edge_scrolling", edge_scrolling_checkbox.button_pressed)
    config.set_value("interface", "tooltip_delay", tooltip_delay_slider.value)
    config.set_value("interface", "extended_tooltip_delay", extended_tooltip_delay_slider.value)
    config.set_value("interface", "building_detail_delay", building_detail_delay_slider.value)
    config.set_value("game", "resource_display_interval", resource_display_interval_slider.value)
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

func _on_tooltip_delay_changed(_value: float):
    _update_tooltip_delay_label()
    # Минимальное значение расширенного тултипа не может быть меньше основного
    if extended_tooltip_delay_slider.value < tooltip_delay_slider.value:
        extended_tooltip_delay_slider.value = tooltip_delay_slider.value
    save_settings()
    _apply_to_game()

func _on_extended_tooltip_delay_changed(_value: float):
    # Не позволяем опускаться ниже основного delay
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
    # Шаг слайдера — 1 секунда, дробных значений не бывает (см. CityData:
    # тик симуляции = 1 сек, дробный интервал дал бы неравномерный ритм).
    var seconds = int(round(resource_display_interval_slider.value))
    resource_display_interval_value_label.text = tr("%d sec") % seconds

func _on_back_pressed():
    hide()
