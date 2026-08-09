# ui_helpers.gd
extends Node

var tooltip_panel: Panel
var tooltip_label: Label

var build_tooltip_panel: Panel
var build_tooltip_label: Label

var group_tooltip_panel: Panel
var group_tooltip_content: VBoxContainer

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

    # Тултип для групповых ресурсов
    group_tooltip_panel = Panel.new()
    group_tooltip_panel.visible = false
    group_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_panel.z_index = 1000 # Поверх всех остальных элементов
    main_ui.add_child(group_tooltip_panel)

    group_tooltip_content = VBoxContainer.new()
    group_tooltip_content.add_theme_constant_override("separation", 4)
    group_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_panel.add_child(group_tooltip_content)

    var group_style = StyleBoxFlat.new()
    group_style.bg_color = Color(0.2, 0.2, 0.2, 0.9)
    group_style.border_width_left = 1
    group_style.border_width_top = 1
    group_style.border_width_right = 1
    group_style.border_width_bottom = 1
    group_style.border_color = Color(0.6, 0.6, 0.6)
    group_tooltip_panel.add_theme_stylebox_override("panel", group_style)

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

    # Если тултип выходит за границы экрана — рисуем его с другой стороны курсора
    # (аналогично тултипам на карте в InputHandler.gd)
    var viewport_size = get_viewport().get_visible_rect().size
    if build_tooltip_panel.position.y + build_tooltip_panel.size.y > viewport_size.y:
        build_tooltip_panel.position.y = mouse_pos.y - build_tooltip_panel.size.y - 15
    if build_tooltip_panel.position.x + build_tooltip_panel.size.x > viewport_size.x:
        build_tooltip_panel.position.x = mouse_pos.x - build_tooltip_panel.size.x - 15
    build_tooltip_panel.position.x = max(0, build_tooltip_panel.position.x)
    build_tooltip_panel.position.y = max(0, build_tooltip_panel.position.y)

func show_group_tooltip(mouse_pos: Vector2, group_key: String, products_data: Dictionary, icon_index: Dictionary):
    # Очищаем предыдущее содержимое (remove_child + queue_free, чтобы узлы
    # удалялись из дерева немедленно и не влияли на расчёт размера)
    for child in group_tooltip_content.get_children():
        group_tooltip_content.remove_child(child)
        child.queue_free()
    
    var group_clean = group_key.trim_prefix("@")
    var member_ids = GameData.product_groups.get(group_clean, [])
    var group_name = GameData.get_product_group_name(group_key)
    
    # Заголовок
    var title = Label.new()
    title.text = group_name
    title.add_theme_font_size_override("font_size", 16)
    title.add_theme_color_override("font_color", Color.WHITE)
    title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_content.add_child(title)
    
    # Список продуктов (по ID, чтобы можно было найти данные продукта)
    for prod_id in member_ids:
        var pdata = products_data.get(prod_id, {})
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 6)
        # Тултип не должен перехватывать клики, чтобы можно было
        # выбирать рецепты в слотах производства под ним.
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        
        # Иконка
        var icon_name = pdata.get("icon", "")
        if not icon_name.is_empty() and icon_index.has(icon_name):
            var tex = load(icon_index[icon_name])
            if tex:
                var icon_rect = TextureRect.new()
                icon_rect.texture = tex
                icon_rect.custom_minimum_size = Vector2(24, 24)
                icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
                row.add_child(icon_rect)
        
        var label = Label.new()
        label.text = pdata.get("name", prod_id)
        label.add_theme_color_override("font_color", Color.WHITE)
        label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(label)
        
        group_tooltip_content.add_child(row)
    
    # Позиционируем и показываем
    group_tooltip_panel.position = mouse_pos + Vector2(15, 15)
    group_tooltip_panel.show()
    # Явно пересчитываем размер панели под содержимое
    group_tooltip_content.reset_size()
    var content_min_size = group_tooltip_content.get_minimum_size()
    group_tooltip_panel.size = content_min_size + Vector2(12, 12)

func hide_group_tooltip():
    group_tooltip_panel.hide()

func set_message(text: String):
    if message_label:
        message_label.text = text
