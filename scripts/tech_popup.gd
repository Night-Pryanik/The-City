# tech_popup.gd
# Окно, появляющееся после завершения исследования технологии.
# Показывает название технологии, список добавленных фич (description)
# и историческую справку (flavor). Кнопки: "Ок" и
# "Перейти к списку технологий".
#
# Окно работает и при get_tree().paused == true (PROCESS_MODE_ALWAYS),
# чтобы игрок не мог взаимодействовать с картой, пока попап открыт.
extends Control

var panel: Panel
var title_label: Label
var description_label: Label
var flavor_label: Label
var techs_btn: Button   # «Перейти к списку технологий» — скрываем, если игрок уже там
# Подписи, которые не зависят от изученной технологии: держат ссылки, чтобы
# переставить их на новом языке (см. _apply_static_text).
var desc_title: Label
var flavor_title: Label
var ok_btn: Button
# Что сейчас показано в окне — нужно, чтобы пересобрать его при смене языка.
var _current_tech_id: String = ""
var _current_found_resources: Array = []

signal go_to_technologies()

func _ready():
    process_mode = Node.PROCESS_MODE_ALWAYS

    # Затемнение фона
    var dim = ColorRect.new()
    dim.color = Color(0, 0, 0, 0.5)
    dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(dim)

    var center = CenterContainer.new()
    center.set_anchors_preset(Control.PRESET_FULL_RECT)
    add_child(center)

    panel = Panel.new()
    # Размеры — min. Panel вырастет по высоте, если контента много,
    # но никогда не сожмётся меньше этих значений. Ставим 560×520 вместо
    # 560×420, чтобы окно по умолчанию было чуть выше и вмещало типичный
    # длинный flavor-text без скролла.
    panel.custom_minimum_size = Vector2(560, 520)
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.13, 0.13, 0.13, 1.0)
    style.set_border_width_all(2)
    style.border_color = Color(0.4, 0.4, 0.4, 1.0)
    style.set_corner_radius_all(4)
    panel.add_theme_stylebox_override("panel", style)
    center.add_child(panel)

    var vbox = VBoxContainer.new()
    vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 24
    vbox.offset_top = 24
    vbox.offset_right = -24
    vbox.offset_bottom = -24
    vbox.add_theme_constant_override("separation", 10)
    panel.add_child(vbox)

    title_label = Label.new()
    title_label.add_theme_font_size_override("font_size", 22)
    title_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
    vbox.add_child(title_label)

    # Длинный текст (description + flavor + resources) заворачиваем в
    # ScrollContainer с size_flags_vertical = EXPAND_FILL: он займёт всё
    # свободное место между заголовком и кнопками, а если контента больше,
    # чем помещается — появится вертикальный скролл внутри. Кнопки при
    # этом всегда прижаты к низу и не вылазят.
    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    vbox.add_child(scroll)

    var scroll_body = VBoxContainer.new()
    scroll_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll_body.add_theme_constant_override("separation", 10)
    scroll.add_child(scroll_body)

    var desc_title_local = Label.new()
    desc_title = desc_title_local
    desc_title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    scroll_body.add_child(desc_title)

    description_label = Label.new()
    description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    description_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll_body.add_child(description_label)

    var flavor_title_local = Label.new()
    flavor_title = flavor_title_local
    flavor_title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    scroll_body.add_child(flavor_title)

    flavor_label = Label.new()
    flavor_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    flavor_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
    flavor_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll_body.add_child(flavor_label)

    var buttons = HBoxContainer.new()
    buttons.alignment = BoxContainer.ALIGNMENT_CENTER
    buttons.add_theme_constant_override("separation", 16)
    vbox.add_child(buttons)

    var ok_btn_local = Button.new()
    ok_btn = ok_btn_local
    ok_btn.custom_minimum_size = Vector2(140, 36)
    ok_btn.pressed.connect(_on_ok_pressed)
    buttons.add_child(ok_btn)

    var techs_btn_local = Button.new()
    techs_btn = techs_btn_local  # сохраняем ссылку для условного скрытия
    techs_btn.custom_minimum_size = Vector2(260, 36)
    techs_btn.pressed.connect(_on_techs_pressed)
    buttons.add_child(techs_btn)

    _apply_static_text()

# Подписи окна, не зависящие от технологии. Ставятся один раз при создании и
# ещё раз при смене языка: узлы, собранные в коде, Godot сам не переводит.
func _apply_static_text():
    if desc_title:
        desc_title.text = tr("What the technology gives:")
    if flavor_title:
        flavor_title.text = tr("Historical background:")
    if ok_btn:
        ok_btn.text = tr("OK")
    if techs_btn:
        techs_btn.text = tr("Go to the technology list")

# Пересобирает окно на новом языке. Вызывается из LocalizationManager
# (см. main_map._on_locale_changed); на скрытом окне ничего не делает.
func refresh() -> void:
    _apply_static_text()
    if visible and not _current_tech_id.is_empty():
        show_tech(_current_tech_id, _current_found_resources)

func show_tech(tech_id: String, found_resources: Array = []):
    var tech_data = null
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_data = t
            break
    if tech_data == null:
        return

    # Запоминаем, что показано: по этому окно пересобирается при смене языка.
    _current_tech_id = tech_id
    _current_found_resources = found_resources

    title_label.text = tr("Technology researched: %s") % tech_data.get("name", tech_id)
    description_label.text = tech_data.get("description", tr("No description."))
    flavor_label.text = tech_data.get("flavor", "")

    # Если игрок уже на вкладке Технологии — кнопка «Перейти к списку
    # технологий» бессмысленна, прячем её.
    if techs_btn:
        var main_map = get_tree().root.find_child("MainMap", true, false)
        var already_on_tab: bool = false
        if main_map and main_map.city_ui and main_map.city_ui.visible \
                and main_map.city_ui.active_tab == "technologies":
            already_on_tab = true
        techs_btn.visible = not already_on_tab

    # Задаём размер корневого Control = размер viewport, чтобы оверлей покрывал всё
    var vp_size = get_viewport_rect().size
    size = vp_size
    position = Vector2.ZERO
    show()

func _on_ok_pressed():
    hide()
    # Возобновляем игру после закрытия попапа технологии.
    get_tree().paused = false

func _on_techs_pressed():
    hide()
    emit_signal("go_to_technologies")

func _input(event):
    # Обрабатываем ESC только когда попап открыт.
    # Иначе скрытый попап перехватывает ESC и ломает меню паузы/настройки.
    if not is_visible_in_tree():
        return
    if event.is_action_pressed("ui_cancel"):
        _on_ok_pressed()
        get_viewport().set_input_as_handled()
