# ui_helpers.gd
extends Node

var tooltip_panel: Panel
var tooltip_label: Label

var build_tooltip_panel: Panel
var build_tooltip_label: Label

var group_tooltip_panel: Panel
var group_tooltip_content: VBoxContainer

var progress_tooltip_panel: Panel
var progress_tooltip_label: Label

# Тултип для разбивки склада по качеству
var quality_tooltip_panel: Panel
var quality_tooltip_vbox: VBoxContainer

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

    # Тултип для прогресс-баров строящихся зданий
    progress_tooltip_panel = Panel.new()
    progress_tooltip_panel.visible = false
    progress_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    progress_tooltip_panel.z_index = 1000 # Поверх всех остальных элементов
    main_ui.add_child(progress_tooltip_panel)

    progress_tooltip_label = Label.new()
    progress_tooltip_label.add_theme_color_override("font_color", Color.WHITE)
    progress_tooltip_label.add_theme_font_size_override("font_size", 14)
    progress_tooltip_panel.add_child(progress_tooltip_label)

    var progress_style = StyleBoxFlat.new()
    progress_style.bg_color = Color(0.2, 0.2, 0.2, 0.9)
    progress_style.border_width_left = 1
    progress_style.border_width_top = 1
    progress_style.border_width_right = 1
    progress_style.border_width_bottom = 1
    progress_style.border_color = Color(0.6, 0.6, 0.6)
    progress_tooltip_panel.add_theme_stylebox_override("panel", progress_style)

    # Тултип для разбивки склада по качеству
    quality_tooltip_panel = Panel.new()
    quality_tooltip_panel.visible = false
    quality_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    quality_tooltip_panel.z_index = 1000
    main_ui.add_child(quality_tooltip_panel)

    quality_tooltip_vbox = VBoxContainer.new()
    quality_tooltip_vbox.add_theme_constant_override("separation", 4)
    quality_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    quality_tooltip_panel.add_child(quality_tooltip_vbox)

    var quality_style = StyleBoxFlat.new()
    quality_style.bg_color = Color(0.2, 0.2, 0.2, 0.9)
    quality_style.border_width_left = 1
    quality_style.border_width_top = 1
    quality_style.border_width_right = 1
    quality_style.border_width_bottom = 1
    quality_style.border_color = Color(0.6, 0.6, 0.6)
    quality_tooltip_panel.add_theme_stylebox_override("panel", quality_style)

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

# Строит строку "иконка + название" для ресурса/продукта рецепта или стоимости
# строительства. Для групповых ключей (@...) автоматически вешает тултип с
# составом группы (раскрывает, какие продукты входят в группу) — по аналогии с
# рецептами и окном слотов производства.
#   products_data — словарь {id: {name, icon}} (продукты + сырьё).
#   icon_paths    — словарь {имя_иконки: путь} для загрузки текстур.
#   amount        — если > 0, добавляется количество после названия.
#   amount_style  — "x" → "Имя xN", "colon" → "Имя: N", иначе без количества.
#   icon_size     — размер иконки в пикселях.
# Возвращает HBoxContainer, который можно добавлять в контейнеры списков.
func make_resource_entry(res_id: String, products_data: Dictionary, icon_paths: Dictionary, amount: int = -1, amount_style: String = "x", icon_size: int = 20) -> HBoxContainer:
    var entry = HBoxContainer.new()
    entry.add_theme_constant_override("separation", 4)
    entry.mouse_filter = Control.MOUSE_FILTER_IGNORE

    # Иконка (только для одиночных ресурсов, у групп своего изображения нет)
    var pdata = products_data.get(res_id, {})
    var icon_name = pdata.get("icon", "")
    if not icon_name.is_empty() and icon_paths.has(icon_name):
        var tex = load(icon_paths[icon_name])
        if tex:
            var icon_rect = TextureRect.new()
            icon_rect.texture = tex
            icon_rect.custom_minimum_size = Vector2(icon_size, icon_size)
            icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
            icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
            entry.add_child(icon_rect)

    var text = GameData.format_resource_name(res_id)
    if amount > 0:
        if amount_style == "colon":
            text = "%s: %d" % [text, amount]
        else:
            text = "%s x%d" % [text, amount]

    var label = Label.new()
    label.text = text
    if GameData.is_group_key(res_id):
        # Групповой ресурс — наведение показывает тултип, но не перехватывает клики
        label.mouse_filter = Control.MOUSE_FILTER_PASS
        label.mouse_entered.connect(_on_resource_group_hover.bind(label, res_id, products_data, icon_paths))
        label.mouse_exited.connect(_on_resource_group_exit)
    entry.add_child(label)
    return entry

# Показывает тултип с составом группы при наведении на строку ресурса
func _on_resource_group_hover(control: Control, res_id: String, products_data: Dictionary, icon_paths: Dictionary):
    show_group_tooltip(get_viewport().get_mouse_position(), res_id, products_data, icon_paths)

# Скрывает тултип состава группы при отводе курсора
func _on_resource_group_exit():
    hide_group_tooltip()

func show_progress_tooltip(mouse_pos: Vector2):
    progress_tooltip_panel.position = mouse_pos + Vector2(15, 15)
    var text_size = progress_tooltip_label.get_minimum_size()
    progress_tooltip_panel.size = text_size + Vector2(12, 8)
    progress_tooltip_label.position = Vector2(6, 4)

    # Если тултип выходит за границы экрана — рисуем его с другой стороны курсора
    var viewport_size = get_viewport().get_visible_rect().size
    if progress_tooltip_panel.position.y + progress_tooltip_panel.size.y > viewport_size.y:
        progress_tooltip_panel.position.y = mouse_pos.y - progress_tooltip_panel.size.y - 15
    if progress_tooltip_panel.position.x + progress_tooltip_panel.size.x > viewport_size.x:
        progress_tooltip_panel.position.x = mouse_pos.x - progress_tooltip_panel.size.x - 15
    progress_tooltip_panel.position.x = max(0, progress_tooltip_panel.position.x)
    progress_tooltip_panel.position.y = max(0, progress_tooltip_panel.position.y)

func hide_progress_tooltip():
    progress_tooltip_panel.hide()

# Показывает тулитп с разбивкой продукта по качеству.
# quality_breakdown — словарь {quality_id: count}, например {"common": 50, "fine": 30}.
func show_quality_tooltip(mouse_pos: Vector2, prod_name: String, quality_breakdown: Dictionary):
    # Очищаем содержимое
    for child in quality_tooltip_vbox.get_children():
        quality_tooltip_vbox.remove_child(child)
        child.queue_free()

    var header = Label.new()
    header.text = "Разборка: %s" % prod_name
    header.add_theme_font_size_override("font_size", 15)
    header.add_theme_color_override("font_color", Color.WHITE)
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    quality_tooltip_vbox.add_child(header)

    var levels = GameData.get_quality_levels()
    # Выводим уровни от худшего к лучшему (как в data/qualities.json).
    for qid in levels:
        var count = quality_breakdown.get(qid, 0)
        if count <= 0:
            continue
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 6)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE

        var stars_label = Label.new()
        stars_label.text = GameData.get_quality_stars(qid)
        stars_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 1.0))
        stars_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(stars_label)

        var name_label = Label.new()
        name_label.text = "%s: %d" % [GameData.get_quality_name(qid), count]
        name_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(name_label)

        quality_tooltip_vbox.add_child(row)

    quality_tooltip_vbox.reset_size()
    var content_size = quality_tooltip_vbox.get_minimum_size()
    quality_tooltip_panel.size = content_size + Vector2(12, 12)
    quality_tooltip_panel.position = mouse_pos + Vector2(15, 15)
    quality_tooltip_panel.show()

func hide_quality_tooltip():
    quality_tooltip_panel.hide()

func set_message(text: String):
    if message_label:
        message_label.text = text
