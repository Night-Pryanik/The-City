# ui_helpers.gd
extends Node

var tooltip_panel: Panel
var tooltip_label: Label

var build_tooltip_panel: Panel
var build_tooltip_label: Label

var message_label: Label

func setup(main_ui: Control, message_lbl: Label):
    message_label = message_lbl
    # Тултип для переключателей еды
    tooltip_panel = Panel.new()
    tooltip_panel.visible = false
    tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main_ui.add_child(tooltip_panel)

    tooltip_label = Label.new()
    tooltip_label.text = "Вкл/выкл использование этого продукта как еды"
    tooltip_label.add_theme_color_override("font_color", Color.WHITE)
    tooltip_label.add_theme_font_size_override("font_size", 14)
    tooltip_panel.add_child(tooltip_label)

    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.2, 0.2, 0.2, 0.9)
    style.border_width_left = 1
    style.border_width_top = 1
    style.border_width_right = 1
    style.border_width_bottom = 1
    style.border_color = Color(0.6, 0.6, 0.6)
    tooltip_panel.add_theme_stylebox_override("panel", style)

    # Тултип для кнопки "Построить"
    build_tooltip_panel = Panel.new()
    build_tooltip_panel.visible = false
    build_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main_ui.add_child(build_tooltip_panel)

    build_tooltip_label = Label.new()
    build_tooltip_label.add_theme_color_override("font_color", Color.WHITE)
    build_tooltip_label.add_theme_font_size_override("font_size", 14)
    build_tooltip_panel.add_child(build_tooltip_label)

    var build_style = StyleBoxFlat.new()
    build_style.bg_color = Color(0.2, 0.2, 0.2, 0.9)
    build_style.border_width_left = 1
    build_style.border_width_top = 1
    build_style.border_width_right = 1
    build_style.border_width_bottom = 1
    build_style.border_color = Color(0.6, 0.6, 0.6)
    build_tooltip_panel.add_theme_stylebox_override("panel", build_style)

func show_food_tooltip(mouse_pos: Vector2):
    tooltip_panel.position = mouse_pos + Vector2(15, 15)
    var text_size = tooltip_label.get_minimum_size()
    tooltip_panel.size = text_size + Vector2(12, 8)
    tooltip_label.position = Vector2(6, 4)

func show_build_tooltip(mouse_pos: Vector2):
    build_tooltip_panel.position = mouse_pos + Vector2(15, 15)
    var text_size = build_tooltip_label.get_minimum_size()
    build_tooltip_panel.size = text_size + Vector2(12, 8)
    build_tooltip_label.position = Vector2(6, 4)

func set_message(text: String):
    if message_label:
        message_label.text = text
