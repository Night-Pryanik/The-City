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

# Тултип деталей выбранного здания (вкладка «Здания»): богатый контент
# (стоимость, слоты, рецепты), собирается в buildings_tab.
var detail_tooltip_panel: Panel
var detail_tooltip_content: VBoxContainer

# Тултип кнопок списка построенных зданий: состояния с цветовой кодировкой
# (обычный tooltip_text цветов не поддерживает). Контент собирает buildings_tab.
var built_tooltip_panel: Panel
var built_tooltip_content: VBoxContainer

# Тултип «Источники прихода/расхода» на вкладке «Ресурсы»
var flow_tooltip_panel: Panel
var flow_tooltip_vbox: VBoxContainer

var message_label: Label
# Общий стиль фона для всех тултипов: полностью непрозрачный тёмный фон
# со светлой рамкой в 1px.
func _make_tooltip_style() -> StyleBoxFlat:
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.2, 0.2, 0.2, 1.0)
    style.border_width_left = 1
    style.border_width_top = 1
    style.border_width_right = 1
    style.border_width_bottom = 1
    style.border_color = Color(0.6, 0.6, 0.6)
    return style

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

    tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

    # Тултип для кнопки "Построить"
    build_tooltip_panel = Panel.new()
    build_tooltip_panel.visible = false
    build_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main_ui.add_child(build_tooltip_panel)

    build_tooltip_label = Label.new()
    build_tooltip_label.add_theme_color_override("font_color", Color.WHITE)
    build_tooltip_label.add_theme_font_size_override("font_size", 14)
    build_tooltip_panel.add_child(build_tooltip_label)

    build_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

    # Тултип для групповых ресурсов
    group_tooltip_panel = Panel.new()
    group_tooltip_panel.visible = false
    group_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_panel.z_index = 1100 # Поверх тултипа деталей здания
    main_ui.add_child(group_tooltip_panel)

    group_tooltip_content = VBoxContainer.new()
    group_tooltip_content.add_theme_constant_override("separation", 4)
    group_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    group_tooltip_panel.add_child(group_tooltip_content)

    group_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

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

    progress_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

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

    quality_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

    # Тултип «Источники прихода/расхода ресурса» (вкладка «Ресурсы»)
    flow_tooltip_panel = Panel.new()
    flow_tooltip_panel.visible = false
    flow_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_panel.z_index = 1000
    main_ui.add_child(flow_tooltip_panel)

    flow_tooltip_vbox = VBoxContainer.new()
    flow_tooltip_vbox.add_theme_constant_override("separation", 4)
    flow_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_panel.add_child(flow_tooltip_vbox)

    flow_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())
    # Тултип деталей выбранного здания (вкладка «Здания»).
    detail_tooltip_panel = Panel.new()
    detail_tooltip_panel.visible = false
    detail_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_STOP
    detail_tooltip_panel.z_index = 1000
    main_ui.add_child(detail_tooltip_panel)

    detail_tooltip_content = VBoxContainer.new()
    detail_tooltip_content.add_theme_constant_override("separation", 4)
    detail_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    detail_tooltip_panel.add_child(detail_tooltip_content)

    detail_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

    # Тултип кнопок списка построенных зданий. mouse_filter IGNORE — тултип
    # «прозрачен» для наведения/кликов (как upgrade_tooltip_panel в
    # building_panel.gd): список кнопок под ним остаётся кликабельным, а
    # перемещение курсора на соседнюю кнопку плавно переключает тултип.
    built_tooltip_panel = Panel.new()
    built_tooltip_panel.visible = false
    built_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    built_tooltip_panel.z_index = 1000
    main_ui.add_child(built_tooltip_panel)

    built_tooltip_content = VBoxContainer.new()
    built_tooltip_content.add_theme_constant_override("separation", 4)
    built_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    built_tooltip_panel.add_child(built_tooltip_content)

    built_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

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
    
    # Явно пересчитываем размер панели под содержимое
    group_tooltip_content.reset_size()
    var content_min_size = group_tooltip_content.get_minimum_size()
    group_tooltip_panel.size = content_min_size + Vector2(12, 12)

    # Позиционируем тултип рядом с курсором и переносим его внутрь экрана,
    # если курсор находится близко к правому или нижнему краю.
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + group_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - group_tooltip_panel.size.x - 15
    if pos.y + group_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - group_tooltip_panel.size.y - 15
    pos.x = max(0, min(pos.x, viewport_size.x - group_tooltip_panel.size.x))
    pos.y = max(0, min(pos.y, viewport_size.y - group_tooltip_panel.size.y))
    group_tooltip_panel.position = pos
    group_tooltip_panel.show()

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

    if GameData.is_group_key(res_id):
        # Групповой ресурс — оформляем как «ссылку»: подчёркнутое название
        # (и светло-голубой цвет), чтобы привлечь внимание игрока к строке.
        # Подчёркнуто только имя группы, количество — обычным начертанием.
        # По наведению показывается тултип с составом группы, но клики НЕ
        # перехватываются (MOUSE_FILTER_PASS) — кнопка рецепта/слота работает.
        var group_name := GameData.format_resource_name(res_id)
        var amount_text := ""
        if amount > 0:
            if amount_style == "colon":
                amount_text = ": %d" % amount
            else:
                amount_text = " x%d" % amount

        # UnderlinedLabel подключаем через load(): class_name может быть ещё
        # не зарегистрирован в кеше глобальных классов (например, при
        # headless-тестах через --script), а load надёжен в любом режиме.
        var link_label = load("res://scripts/underlined_label.gd").new()
        link_label.text = "%s%s" % [group_name, amount_text]
        link_label.underline_text = group_name
        link_label.mouse_filter = Control.MOUSE_FILTER_PASS
        link_label.mouse_entered.connect(_on_resource_group_hover.bind(
            link_label, res_id, products_data, icon_paths))
        link_label.mouse_exited.connect(_on_resource_group_exit)
        entry.add_child(link_label)
        return entry

    var text := GameData.format_resource_name(res_id)
    if amount > 0:
        if amount_style == "colon":
            text = "%s: %d" % [text, amount]
        else:
            text = "%s x%d" % [text, amount]

    var label = Label.new()
    label.text = text
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

func show_building_detail_tooltip(mouse_pos: Vector2):
    if detail_tooltip_panel == null:
        return
    # Сбрасываем размер панели, чтобы reset_size() ниже взял актуальную
    # минимальную ширину контента (иначе панель могла остаться прежней).
    detail_tooltip_panel.size = Vector2.ZERO
    # Пересчитываем размер панели под собранное содержимое.
    detail_tooltip_content.reset_size()
    var content_min_size = detail_tooltip_content.get_minimum_size()
    # Отступы от края панели до текста: 6 слева/справа, 4 сверху/снизу.
    # vbox прижат к (0, 0), поэтому добавляем padding через position и size панели.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    detail_tooltip_content.position = Vector2(pad_left, pad_top)
    detail_tooltip_panel.size = content_min_size + Vector2(pad_left + pad_right, pad_top + pad_bottom)
    # Если тултип выходит за границы экрана — рисуем его с другой стороны курсора.
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + detail_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - detail_tooltip_panel.size.x - 15
    if pos.y + detail_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - detail_tooltip_panel.size.y - 15
    detail_tooltip_panel.position = pos
    detail_tooltip_panel.show()

func hide_building_detail_tooltip():
    if detail_tooltip_panel:
        detail_tooltip_panel.hide()

# Показывает тултип построенного здания в точке pos (обычно под кнопкой
# списка), с переносом внутрь экрана у краёв. Контент заполняет buildings_tab
# в _fill_built_tooltip() перед вызовом.
func show_built_tooltip(pos: Vector2):
    if built_tooltip_panel == null:
        return
    built_tooltip_content.reset_size()
    var content_min_size = built_tooltip_content.get_minimum_size()
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    built_tooltip_content.position = Vector2(pad_left, pad_top)
    built_tooltip_panel.size = content_min_size + Vector2(pad_left + pad_right, pad_top + pad_bottom)
    var viewport_size = get_viewport().get_visible_rect().size
    pos.x = max(0.0, min(pos.x, viewport_size.x - built_tooltip_panel.size.x))
    pos.y = max(0.0, min(pos.y, viewport_size.y - built_tooltip_panel.size.y))
    built_tooltip_panel.position = pos
    built_tooltip_panel.show()

func hide_built_tooltip():
    if built_tooltip_panel:
        built_tooltip_panel.hide()

# Создаёт строку тултипа «буллет + текст». Используется в show_flow_tooltip
# и по тому же паттерну, что _make_bullet_row в buildings_tab.gd (блоки
# «Стоимость» и «Доступные рецепты» в тултипе здания).
# text_color — цвет текста строки; буллет рисуется светло-серым, чтобы
# выделялся на фоне цветного текста (как в тултипе здания).
func _make_bullet_row(symbol: String, text: String, text_color: Color) -> HBoxContainer:
    var row = HBoxContainer.new()
    row.add_theme_constant_override("separation", 3)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var bullet = Label.new()
    bullet.text = symbol
    bullet.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
    bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(bullet)
    var label = Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 14)
    label.add_theme_color_override("font_color", text_color)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(label)
    return row

# Показывает тултип «источники прихода/расхода» ресурса (вкладка «Ресурсы»).
# prod_sources / cons_sources: { источник -> { count, amount } }.
# Строки сортируются по убыванию вклада; «хN» показывается при count > 1.
func show_flow_tooltip(mouse_pos: Vector2, prod_name: String, prod_sources: Dictionary, cons_sources: Dictionary):
    if flow_tooltip_panel == null:
        return
    # Очищаем предыдущее содержимое.
    for child in flow_tooltip_vbox.get_children():
        flow_tooltip_vbox.remove_child(child)
        child.queue_free()
    var prod_lines: Array = []
    for src in prod_sources:
        prod_lines.append({"name": src, "amount": int(prod_sources[src].get("amount", 0)), "count": int(prod_sources[src].get("count", 1))})
    prod_lines.sort_custom(func(a, b): return a.amount > b.amount)
    var cons_lines: Array = []
    for src in cons_sources:
        cons_lines.append({"name": src, "amount": int(cons_sources[src].get("amount", 0)), "count": int(cons_sources[src].get("count", 1))})
    cons_lines.sort_custom(func(a, b): return a.amount > b.amount)
    if prod_lines.is_empty() and cons_lines.is_empty():
        flow_tooltip_panel.hide()
        return
    var header = Label.new()
    header.text = prod_name
    header.add_theme_font_size_override("font_size", 15)
    header.add_theme_color_override("font_color", Color.WHITE)
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_vbox.add_child(header)
    if not prod_lines.is_empty():
        var prod_title = Label.new()
        prod_title.text = "Производство:"
        prod_title.add_theme_font_size_override("font_size", 14)
        prod_title.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
        prod_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(prod_title)
        for row in prod_lines:
            var mult = ""
            if int(row.count) > 1:
                mult = " х%d" % int(row.count)
            var line_text = "%s%s: +%d" % [row.name, mult, int(row.amount)]
            flow_tooltip_vbox.add_child(_make_bullet_row("•", line_text, Color(0.3, 0.85, 0.3)))
    if not cons_lines.is_empty():
        var cons_title = Label.new()
        cons_title.text = "Потребление:"
        cons_title.add_theme_font_size_override("font_size", 14)
        cons_title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.6))
        cons_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(cons_title)
        for row in cons_lines:
            var mult = ""
            if int(row.count) > 1:
                mult = " х%d" % int(row.count)
            var line_text = "%s%s: -%d" % [row.name, mult, int(row.amount)]
            flow_tooltip_vbox.add_child(_make_bullet_row("•", line_text, Color(0.9, 0.3, 0.3)))
    flow_tooltip_vbox.reset_size()
    var content_size = flow_tooltip_vbox.get_minimum_size()
    # Отступы от края панели до текста: 6 слева/справа, 4 сверху/снизу.
    # vbox прижат к (0, 0), поэтому добавляем padding через position и size панели.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    flow_tooltip_vbox.position = Vector2(pad_left, pad_top)
    flow_tooltip_panel.size = content_size + Vector2(pad_left + pad_right, pad_top + pad_bottom)
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + flow_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - flow_tooltip_panel.size.x - 15
    if pos.y + flow_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - flow_tooltip_panel.size.y - 15
    flow_tooltip_panel.position = pos
    flow_tooltip_panel.show()

func hide_flow_tooltip():
    if flow_tooltip_panel:
        flow_tooltip_panel.hide()

func set_message(text: String):
    if message_label:
        message_label.text = text
