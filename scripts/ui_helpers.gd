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
var detail_tooltip_scroll: ScrollContainer

# Тултип кнопок списка построенных зданий: состояния с цветовой кодировкой
# (обычный tooltip_text цветов не поддерживает). Контент собирает buildings_tab.
var built_tooltip_panel: Panel
var built_tooltip_content: VBoxContainer

# Тултип «Источники прихода/расхода» на вкладке «Ресурсы»
var flow_tooltip_panel: Panel
var flow_tooltip_vbox: VBoxContainer
var flow_tooltip_scroll: ScrollContainer

# Тултип разбивки казны по источникам дохода/расхода (HUD карты и
# верхняя полоса интерфейса города): показывает баланс, плановую скорость
# дохода (по источникам внутреннего рынка) и факт расходов за последнее окно
# отображения (разведка, освоение чанков).
var treasury_tooltip_panel: Panel
var treasury_tooltip_vbox: VBoxContainer
var treasury_tooltip_scroll: ScrollContainer

# Ограничение высоты «богатых» тултипов (детали здания, потоки ресурсов на
# вкладке «Ресурсы»): контент выше DETAIL_TOOLTIP_MAX_ROWS строк (по ROW_HEIGHT
# px каждая) обрезается, а внутри появляется вертикальный скроллбар.
const DETAIL_TOOLTIP_MAX_ROWS: int = 15
const DETAIL_TOOLTIP_ROW_HEIGHT: float = 24.0
const DETAIL_TOOLTIP_SCROLLBAR_WIDTH: float = 14.0

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

    # Скролл-контейнер: ограничивает высоту тултипа и показывает вертикальный
    # скроллбар, когда источников прихода/расхода слишком много.
    flow_tooltip_vbox = VBoxContainer.new()
    flow_tooltip_vbox.add_theme_constant_override("separation", 4)
    flow_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    flow_tooltip_scroll = ScrollContainer.new()
    flow_tooltip_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    flow_tooltip_scroll.offset_left = 6
    flow_tooltip_scroll.offset_top = 4
    flow_tooltip_scroll.offset_right = -6
    flow_tooltip_scroll.offset_bottom = -4
    flow_tooltip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    flow_tooltip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    flow_tooltip_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    flow_tooltip_panel.add_child(flow_tooltip_scroll)
    flow_tooltip_scroll.add_child(flow_tooltip_vbox)

    flow_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())

    # Тултип разбивки казны (по источникам дохода/расхода): один на оба
    # места (HUD карты и верхняя полоса CityUI) — структура одна и та же.
    treasury_tooltip_panel = Panel.new()
    treasury_tooltip_panel.visible = false
    treasury_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    treasury_tooltip_panel.z_index = 1000
    main_ui.add_child(treasury_tooltip_panel)

    # Скролл-контейнер: ограничивает высоту тултипа и показывает вертикальный
    # скроллбар, когда источников дохода/расхода слишком много (как в
    # flow_tooltip).
    treasury_tooltip_vbox = VBoxContainer.new()
    treasury_tooltip_vbox.add_theme_constant_override("separation", 4)
    treasury_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    treasury_tooltip_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    treasury_tooltip_scroll = ScrollContainer.new()
    treasury_tooltip_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    treasury_tooltip_scroll.offset_left = 6
    treasury_tooltip_scroll.offset_top = 4
    treasury_tooltip_scroll.offset_right = -6
    treasury_tooltip_scroll.offset_bottom = -4
    treasury_tooltip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    treasury_tooltip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    treasury_tooltip_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    treasury_tooltip_panel.add_child(treasury_tooltip_scroll)
    treasury_tooltip_scroll.add_child(treasury_tooltip_vbox)

    treasury_tooltip_panel.add_theme_stylebox_override("panel", _make_tooltip_style())
    # Тултип деталей выбранного здания (вкладка «Здания»).
    detail_tooltip_panel = Panel.new()
    detail_tooltip_panel.visible = false
    detail_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_STOP
    detail_tooltip_panel.z_index = 1000
    main_ui.add_child(detail_tooltip_panel)

    # Скролл-контейнер: ограничивает высоту тултипа 15 строками; при длинном
    # списке рецептов внутри появляется вертикальный скроллбар.
    detail_tooltip_content = VBoxContainer.new()
    detail_tooltip_content.add_theme_constant_override("separation", 4)
    detail_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    detail_tooltip_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    detail_tooltip_scroll = ScrollContainer.new()
    detail_tooltip_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    detail_tooltip_scroll.offset_left = 6
    detail_tooltip_scroll.offset_top = 4
    detail_tooltip_scroll.offset_right = -6
    detail_tooltip_scroll.offset_bottom = -4
    detail_tooltip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    detail_tooltip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    detail_tooltip_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
    detail_tooltip_panel.add_child(detail_tooltip_scroll)
    detail_tooltip_scroll.add_child(detail_tooltip_content)

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
    
    # Список продуктов (по ID, чтобы можно было найти данные продукта).
    # Названия собираем отдельно, чтобы выровнять special_yield по колонке
    # самого длинного названия ресурса.
    var product_labels: Array = []
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
        var special_yield = pdata.get("special_yield", {})
        label.text = pdata.get("name", prod_id)
        label.add_theme_color_override("font_color", Color.WHITE)
        label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(label)
        product_labels.append(label)

        for yield_id in special_yield:
            var separator = Label.new()
            separator.text = " - "
            separator.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
            row.add_child(separator)

            var yield_data = products_data.get(yield_id, {})
            var yield_icon_name = yield_data.get("icon", "")
            if not yield_icon_name.is_empty() and icon_index.has(yield_icon_name):
                var yield_tex = load(icon_index[yield_icon_name])
                if yield_tex:
                    var yield_icon_rect = TextureRect.new()
                    yield_icon_rect.texture = yield_tex
                    yield_icon_rect.custom_minimum_size = Vector2(20, 20)
                    yield_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                    yield_icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                    yield_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
                    row.add_child(yield_icon_rect)

            var yield_label = Label.new()
            yield_label.text = "%s: %d" % [
                yield_data.get("name", yield_id), int(special_yield[yield_id])]
            yield_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
            yield_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            row.add_child(yield_label)
        
        group_tooltip_content.add_child(row)

    var max_product_name_width := 0.0
    for product_label in product_labels:
        max_product_name_width = maxf(
            max_product_name_width, product_label.get_minimum_size().x)
    for product_label in product_labels:
        product_label.custom_minimum_size.x = max_product_name_width
    
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
    # Отступы от края панели до текста: 6 слева/справа, 4 сверху/снизу —
    # задаются якорями ScrollContainer (PRESET_FULL_RECT + offset_*), поэтому
    # позиционировать vbox вручную не нужно.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    # Ограничиваем высоту: не больше DETAIL_TOOLTIP_MAX_ROWS строк. При
    # переполнении ScrollContainer показывает вертикальный скроллбар, на
    # который закладываем ширину, чтобы контент не сжимался.
    var max_content_height = DETAIL_TOOLTIP_MAX_ROWS * DETAIL_TOOLTIP_ROW_HEIGHT
    var content_height = min(content_min_size.y, max_content_height)
    var scrollbar_width = 0.0
    if content_min_size.y > max_content_height:
        scrollbar_width = DETAIL_TOOLTIP_SCROLLBAR_WIDTH
    detail_tooltip_panel.size = Vector2(
        content_min_size.x + scrollbar_width + pad_left + pad_right,
        content_height + pad_top + pad_bottom
    )
    # Тултип только что показан — скролл наверх (между разными зданиями
    # контент целиком пересобирается в buildings_tab).
    if not detail_tooltip_panel.visible:
        detail_tooltip_scroll.scroll_vertical = 0.0
    # Если тултип выходит за границы экрана — рисуем его с другой стороны курсора.
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + detail_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - detail_tooltip_panel.size.x - 15
    if pos.y + detail_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - detail_tooltip_panel.size.y - 15
    # Зажимаем тултип внутри экрана полностью: после переноса вверх высокий
    # тултип не должен уходить за верхний край (как у built_tooltip).
    pos.x = max(0.0, min(pos.x, maxf(0.0, viewport_size.x - detail_tooltip_panel.size.x)))
    pos.y = max(0.0, min(pos.y, maxf(0.0, viewport_size.y - detail_tooltip_panel.size.y)))
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

# Форматирует цену для тултипа: целые значения без дробной части,
# дробные (после динамических множителей цены) — с одним знаком.
func _format_price(value: float) -> String:
    if value == floor(value):
        return str(int(value))
    return "%.1f" % value

# Форматирует интервал потребления для тултипа: целые секунды без дробной
# части («10 сек»), дробные — с одним знаком («0.5 сек»).
func _format_interval(interval: float) -> String:
    if interval == floor(interval):
        return str(int(interval))
    return "%.1f" % interval

# Форматирует скорость (ед./сек): целые значения без дробной части,
# дробные — с одним знаком («0.5»).
func _format_rate(value: float) -> String:
    if value == floor(value):
        return str(int(value))
    return "%.1f" % value

# Средняя скорость записи за секунду: amount × SIMULATION_TICK / interval
# для циклических записей (рецепты зданий со своим time, профессии, «все
# жители», улучшения с production_interval); interval = 0 — «за тик», а тик
# симуляции равен SIMULATION_TICK сек, поэтому это amount × SIMULATION_TICK.
func _planned_per_sec(amount: float, interval: float) -> float:
    if interval > 0.0:
        return amount * CityData.SIMULATION_TICK / interval
    return amount * CityData.SIMULATION_TICK

# Текстовое представление плановой скорости для тултипа. Сохраняем исходную
# пару «amount за interval» — так игрок видит ровно то, что объявлено в
# данных (например, «10 / 10 сек» для профессионального потребления
# «10 ед./10 сек»), а не производное per_sec.
#
#   amount = 10, interval = 10 → "10 / 10 сек"   (циклическое потребление)
#   amount = 5,  interval = 0  → "5 / сек"      (непрерывный расход за тик)
#   amount = 0               → "0"
func _format_planned_rate(amount: float, interval: float) -> String:
    var amt_int := int(round(amount))
    if amt_int <= 0:
        return "0"
    if interval > 0.0:
        var iv := interval
        # Целый интервал — без дробной части.
        if abs(iv - round(iv)) < 0.001:
            return "%d / %d сек" % [amt_int, int(round(iv))]
        return "%d / %.1f сек" % [amt_int, iv]
    return "%d / сек" % amt_int

# Показывает тултип «источники планового прихода/расхода» ресурса (вкладка
# «Ресурсы»). Фактическое производство/потребление (текущее) из тултипа
# убрано (см. коммит 5790016).
# resource_id — id ресурса/продукта: если задан, сверху выводится его текущая
# цена (GameData.get_price). Тултип показывается, даже когда производство/
# потребление пусты, но цена ресурса > 0.
# planned_consumption — плановое потребление:
# { источник -> { amount, interval, count, is_group, group_name, is_population } }.
# Строки показываются как пара «amount / interval сек» (см. _format_planned_rate).
# Блок «Потребление (плановое):» показывается, когда план есть.
# planned_production — плановое производство: { источник -> { amount, interval, count } } —
# выпуск рецептов зданий и циклов улучшений; формат строк аналогичный.
# Блок «Производство (плановое):» показывается, когда производитель существует,
# но за тик ничего не произвёл (например, печи не хватило дерева).
# После коммита 5790016 фактическое (текущее) производство/потребление из
# тултипа убрано: остались только плановые показатели (что БУДЕТ произведено/
# потреблено при текущем состоянии производителей).
# Порядок секций тултипа: цена / «Производство (плановое):» / «Потребление
# (плановое):» / сноска «≈».
func show_flow_tooltip(mouse_pos: Vector2, prod_name: String, special_yield: Dictionary = {}, resource_id: String = "", planned_consumption: Dictionary = {}, planned_production: Dictionary = {}):
    if flow_tooltip_panel == null:
        return
    # Очищаем предыдущее содержимое.
    for child in flow_tooltip_vbox.get_children():
        flow_tooltip_vbox.remove_child(child)
        child.queue_free()
    var price := 0.0
    if not resource_id.is_empty():
        price = GameData.get_price(resource_id)
    if special_yield.is_empty() and price <= 0.0 \
            and planned_consumption.is_empty() \
            and planned_production.is_empty():
        flow_tooltip_panel.hide()
        return
    var header = Label.new()
    header.text = prod_name
    header.add_theme_font_size_override("font_size", 15)
    header.add_theme_color_override("font_color", Color.WHITE)
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flow_tooltip_vbox.add_child(header)
    # Текущая цена ресурса (с учётом динамических множителей).
    if price > 0.0:
        var price_label = Label.new()
        price_label.text = "Цена: " + _format_price(price)
        price_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
        price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(price_label)
    for yield_id in special_yield:
        var yield_label = Label.new()
        yield_label.text = "%s: %d" % [
            GameData.products.get(yield_id, {}).get("name", yield_id),
            int(special_yield[yield_id])
        ]
        yield_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.918, 1.0))
        yield_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(yield_label)
    # Плановое производство: что БУДЕТ произведено текущими производителями
    # (рецепты зданий с горожанином + улучшения на карте). Показывается и когда
    # фактического производства за тик нет — например, печи не хватило дерева
    # или цикл производства улучшения ещё не вышел.
    # Строки показывают пару «amount / interval» через _format_planned_rate:
    # для интервальных записей — «10 / 10 сек», для непрерывных — «5 / сек».
    if not planned_production.is_empty():
        var planned_prod_title = Label.new()
        planned_prod_title.text = "Производство (плановое):"
        planned_prod_title.add_theme_font_size_override("font_size", 14)
        planned_prod_title.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
        planned_prod_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(planned_prod_title)
        var planned_prod_lines: Array = []
        for src in planned_production:
            var e: Dictionary = planned_production[src]
            planned_prod_lines.append({
                "name": src,
                "amount": int(e.get("amount", 0)),
                "count": int(e.get("count", 1)),
                "interval": float(e.get("interval", 0))
            })
        planned_prod_lines.sort_custom(func(a, b): return a.amount > b.amount)
        for row in planned_prod_lines:
            var line_text = str(row.name)
            if int(row.count) > 1:
                line_text += " х%d" % int(row.count)
            line_text += ": %s" % _format_planned_rate(float(row.amount), float(row.interval))
            flow_tooltip_vbox.add_child(_make_bullet_row("•", line_text, Color(0.3, 0.85, 0.3)))
    # Плановое потребление: кто и сколько БУДЕТ списывать со склада —
    # независимо от фазы таймеров потребления и факта последнего тика.
    # Строки показывают средний расход В ПЕРЕСЧЁТЕ НА СЕКУНДУ («ед./сек»):
    # interval > 0 — циклическое потребление (профессии, «все жители», рецепты
    # зданий со своим `time`), interval = 0 — спрос зданий за тик. Групповые
    # записи относятся к любому члену группы и помечаются её именем.
    if not planned_consumption.is_empty():
        var planned_title = Label.new()
        planned_title.text = "Потребление (плановое):"
        planned_title.add_theme_font_size_override("font_size", 14)
        planned_title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.6))
        planned_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(planned_title)
        var planned_lines: Array = []
        for src in planned_consumption:
            var e: Dictionary = planned_consumption[src]
            planned_lines.append({
                "name": src,
                "amount": int(e.get("amount", 0)),
                "count": int(e.get("count", 1)),
                "interval": float(e.get("interval", 0)),
                "is_group": bool(e.get("is_group", false)),
                "group_name": str(e.get("group_name", "")),
                "is_population": bool(e.get("is_population", false))
            })
        planned_lines.sort_custom(func(a, b): return a.amount > b.amount)
        for row in planned_lines:
            var line_text = str(row.name)
            if bool(row.is_population):
                # Потребление «всех жителей»: множитель населения — в скобках.
                if int(row.count) > 1:
                    line_text += " (%d чел.)" % int(row.count)
            elif int(row.count) > 1:
                line_text += " х%d" % int(row.count)
            if bool(row.is_group) and not str(row.group_name).is_empty():
                line_text += " (группа «%s»)" % str(row.group_name)
            line_text += ": %s" % _format_planned_rate(float(row.amount), float(row.interval))
            flow_tooltip_vbox.add_child(_make_bullet_row("•", line_text, Color(0.9, 0.3, 0.3)))
    # Пояснение к маркеру «≈» в динамике вкладки «Ресурсы» — для обоих
    # планов: производства и потребления. Показывается при любом непустом
    # плане, независимо от того, какая именно секция плана отрисовалась.
    if not planned_consumption.is_empty() or not planned_production.is_empty():
        var planned_note = Label.new()
        planned_note.text = "≈ в динамике — плановое значение в пересчёте на секунду"
        planned_note.add_theme_font_size_override("font_size", 12)
        planned_note.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
        planned_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
        flow_tooltip_vbox.add_child(planned_note)
    flow_tooltip_vbox.reset_size()
    var content_size = flow_tooltip_vbox.get_minimum_size()
    # Отступы от края панели до текста: 6 слева/справа, 4 сверху/снизу —
    # задаются якорями ScrollContainer (PRESET_FULL_RECT + offset_*), поэтому
    # позиционировать vbox вручную не нужно.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    # Ограничиваем высоту: не больше DETAIL_TOOLTIP_MAX_ROWS строк. При
    # переполнении ScrollContainer показывает вертикальный скроллбар, на
    # который закладываем ширину, чтобы контент не сжимался.
    var max_content_height = DETAIL_TOOLTIP_MAX_ROWS * DETAIL_TOOLTIP_ROW_HEIGHT
    var content_height = min(content_size.y, max_content_height)
    var scrollbar_width = 0.0
    if content_size.y > max_content_height:
        scrollbar_width = DETAIL_TOOLTIP_SCROLLBAR_WIDTH
    flow_tooltip_panel.size = Vector2(
        content_size.x + scrollbar_width + pad_left + pad_right,
        content_height + pad_top + pad_bottom
    )
    # Тултип только что показан — скролл наверх (контент при каждом показе
    # пересобирается заново).
    if not flow_tooltip_panel.visible:
        flow_tooltip_scroll.scroll_vertical = 0.0
    var viewport_size = get_viewport().get_visible_rect().size
    var pos = mouse_pos + Vector2(15, 15)
    if pos.x + flow_tooltip_panel.size.x > viewport_size.x:
        pos.x = mouse_pos.x - flow_tooltip_panel.size.x - 15
    if pos.y + flow_tooltip_panel.size.y > viewport_size.y:
        pos.y = mouse_pos.y - flow_tooltip_panel.size.y - 15
    # Зажимаем тултип внутри экрана полностью (в т.ч. сверху), как у тултипа
    # деталей здания и списка построенных зданий.
    pos.x = max(0.0, min(pos.x, maxf(0.0, viewport_size.x - flow_tooltip_panel.size.x)))
    pos.y = max(0.0, min(pos.y, maxf(0.0, viewport_size.y - flow_tooltip_panel.size.y)))
    flow_tooltip_panel.position = pos
    flow_tooltip_panel.show()

func hide_flow_tooltip():
    if flow_tooltip_panel:
        flow_tooltip_panel.hide()

# Показывает тултип с разбивкой казны по типам прибыли/расхода при наведении
# на «Казна: N» в HUD карты или в верхней полосе CityUI.
#   balance            — текущий баланс казны (целое число монет).
#   planned_income     — ИЕРАРХИЧЕСКАЯ карта плановой скорости дохода:
#                        {
#                          "Потребление населения": {                # тип
#                            "Все жители": {                          # источник
#                              "fruit": {coins_per_sec: 2.5, product_name: "Фрукты"},
#                              ...
#                            },
#                            ...
#                          },
#                          # будущие: "Налоги": { ... }, "Торговля": { ... }
#                        }
#                        Из worker_manager.get_planned_treasury_income_map().
#                        Типы и источники рисуются по убыванию итоговой скорости
#                        (наверху — основной заработок); продукты внутри источника
#                        тоже по убыванию. Пустые типы/источники скрываются.
#   expense_snapshot   — снимок факта расходов за последнее завершённое окно,
#                        flat-словарь { "Имя источника" -> signed_amount }.
#                        Положительное = потрачено, отрицательное = возврат
#                        (refund netted в том же источнике, см.
#                        expansion_manager.handle_action). Источники с
#                        отрицательным или нулевым нетто скрываются, иначе
#                        показывается сумма со знаком «−».
#                        Из CityData.treasury_expense_snapshot.
#   window_sec         — длина окна (для подписи в тултипе, обычно
#                        CityData.treasury_window_length_sec).
#
# Структура секций:
#   * Заголовок: «Казна: N».
#   * «Прибыль (планируемая, /сек):» — три уровня вложенности (тип → источник →
#     продукт), см. пример в комментарии параметра planned_income.
#   * «Расходы (факт, за последние N сек):» — плоский список источников
#     с нетто-суммой за окно (плюс тип «Действия на карте» как заголовок).
#   * Пояснение «≈» в подвале секции прибыли (как в тултипе ресурсов).
#   * Если расходов в игре нет — ремарка «Нет разовых расходов…» (как раньше).
# keep_position = true — это перерисовка УЖЕ показанного («залипшего»)
# тултипа: панель остаётся на прежнем месте, меняется только содержимое и
# размер (live-update на смене ресурсной эпохи). Иначе live-update уводил бы
# панель за курсором и «залипание» было бы невозможным (см. city_ui/main_map:
# залипание по образцу building_detail_tooltip).
func show_treasury_tooltip(mouse_pos: Vector2, balance: int, planned_income: Dictionary, expense_snapshot: Dictionary, window_sec: float, keep_position: bool = false):
    if treasury_tooltip_panel == null:
        return
    # Очищаем предыдущее содержимое.
    for child in treasury_tooltip_vbox.get_children():
        treasury_tooltip_vbox.remove_child(child)
        child.queue_free()

    # Предрасчёт нетто-расходов: только источники с amount > 0 (отрицательные
    # — чистые возвраты без компенсирующей траты; не показываем). Суммируем
    # по типам заодно с группировкой для рендера: сейчас есть только тип
    # «Действия на карте», но структура snapshot-а flat — тип добавляется
    # здесь, в рендере.
    var expense_by_type: Dictionary = {"Действия на карте": {}}
    for src in expense_snapshot:
        var amt: int = int(expense_snapshot[src])
        if amt <= 0:
            continue
        expense_by_type["Действия на карте"][src] = amt

    var has_income: bool = not planned_income.is_empty()
    var has_expense: bool = false
    for t in expense_by_type:
        if not expense_by_type[t].is_empty():
            has_expense = true
            break

    # Пустой тултип (нет ни плана, ни факта расходов) скрываем: показывать
    # только «Казна: N» без разбивки не имеет смысла — стрелка-курсор уже
    # рядом с цифрой в HUD/TopBar.
    if not has_income and not has_expense:
        treasury_tooltip_panel.hide()
        return

    # --- Заголовок: текущий баланс ---
    var header = Label.new()
    header.text = "Казна: %d" % balance
    header.add_theme_font_size_override("font_size", 15)
    header.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
    header.mouse_filter = Control.MOUSE_FILTER_IGNORE
    treasury_tooltip_vbox.add_child(header)

    # --- Прибыль (планируемая, /сек): иерархия тип → источник → продукт ---
    if has_income:
        var income_title = Label.new()
        income_title.text = "Прибыль (фактическая, средняя):"
        income_title.add_theme_font_size_override("font_size", 14)
        income_title.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
        income_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        treasury_tooltip_vbox.add_child(income_title)
        # Сортируем типы по суммарной скорости (убывание): «Потребление населения»
        # vs будущие «Налоги» — кто больше приносит, тот наверху.
        var type_lines: Array = []
        for income_type in planned_income:
            var type_total: float = 0.0
            for source_name in planned_income[income_type]:
                for pid in planned_income[income_type][source_name]:
                    type_total += float(planned_income[income_type][source_name][pid].get("coins_per_sec", 0.0))
            if type_total > 0.0:
                type_lines.append({
                    "name": income_type,
                    "total": type_total,
                    "sources": planned_income[income_type]
                })
        type_lines.sort_custom(func(a, b): return a.total > b.total)
        for type_row in type_lines:
            # Первый уровень разбивки: «• Потребление населения:»
            var type_header = Label.new()
            type_header.text = "• " + str(type_row.name) + ":"
            type_header.add_theme_font_size_override("font_size", 13)
            type_header.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
            type_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
            treasury_tooltip_vbox.add_child(type_header)
            # Источники внутри типа — сортируем по сумме по источнику.
            var source_lines: Array = []
            for src in type_row.sources:
                var src_total: float = 0.0
                for pid in type_row.sources[src]:
                    src_total += float(type_row.sources[src][pid].get("coins_per_sec", 0.0))
                if src_total > 0.0:
                    source_lines.append({
                        "name": src,
                        "total": src_total,
                        "products": type_row.sources[src]
                    })
            source_lines.sort_custom(func(a, b): return a.total > b.total)
            for src_row in source_lines:
                # Второй уровень разбивки: «  ◦ Все жители (3.0 / сек):»
                var src_header = Label.new()
                src_header.text = "  ◦ %s (%s / сек):" % [
                    str(src_row.name), _format_rate(float(src_row.total))
                ]
                src_header.add_theme_font_size_override("font_size", 13)
                src_header.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))
                src_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
                treasury_tooltip_vbox.add_child(src_header)
                # Продукты внутри источника — сортируем по убыванию.
                var product_lines: Array = []
                for pid in src_row.products:
                    product_lines.append({
                        "name": str(src_row.products[pid].get("product_name", pid)),
                        "rate": float(src_row.products[pid].get("coins_per_sec", 0.0))
                    })
                product_lines.sort_custom(func(a, b): return a.rate > b.rate)
                for prod_row in product_lines:
                    var prod_name: String = str(prod_row.name)
                    var prod_rate: float = float(prod_row.rate)
                    var line_text := "%s: %s / сек" % [
                        prod_name, _format_rate(prod_rate)
                    ]
                    treasury_tooltip_vbox.add_child(
                        _make_bullet_row("    ▪", line_text, Color(0.3, 0.85, 0.3)))

    # --- Расходы (факт, за последние N сек): тип → источник → нетто-сумма ---
    if has_expense:
        var window_str: String = "%d" % int(round(window_sec))
        if absf(window_sec - round(window_sec)) > 0.001:
            window_str = "%.1f" % window_sec
        var expense_title = Label.new()
        expense_title.text = "Расходы (факт, за последние %s сек):" % window_str
        expense_title.add_theme_font_size_override("font_size", 14)
        expense_title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.6))
        expense_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
        treasury_tooltip_vbox.add_child(expense_title)
        for expense_type in expense_by_type:
            if expense_by_type[expense_type].is_empty():
                continue
            var expense_type_label = Label.new()
            expense_type_label.text = "  " + str(expense_type) + ":"
            expense_type_label.add_theme_font_size_override("font_size", 13)
            expense_type_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.85))
            expense_type_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
            treasury_tooltip_vbox.add_child(expense_type_label)
            var expense_lines: Array = []
            for src in expense_by_type[expense_type]:
                expense_lines.append({
                    "name": src,
                    "amount": int(expense_by_type[expense_type][src])
                })
            expense_lines.sort_custom(func(a, b): return a.amount > b.amount)
            for row in expense_lines:
                var amt: int = int(row.amount)
                # Знак: сюда проходят только amount > 0 (см. предрасчёт выше),
                # возврат ноттирован в том же источнике.
                var sign: String = "−" if amt > 0 else "+"
                var mag: int = abs(amt)
                var line_text := "%s: %s%d" % [str(row.name), sign, mag]
                treasury_tooltip_vbox.add_child(
                    _make_bullet_row("•", line_text, Color(0.9, 0.3, 0.3)))

    # --- Подвал: ссылка на динамику «≈» (как в тултипе ресурсов) ---
    if has_income:
        var note = Label.new()
        note.text = "≈ средняя скорость дохода; фактический баланс меняется по тикам"
        note.add_theme_font_size_override("font_size", 12)
        note.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
        note.mouse_filter = Control.MOUSE_FILTER_IGNORE
        treasury_tooltip_vbox.add_child(note)

    # --- Подвал: ремарка, если расходов в игре пока нет ---
    if not has_expense:
        var no_expense_note = Label.new()
        no_expense_note.text = "Нет разовых расходов в казну за последнее окно"
        no_expense_note.add_theme_font_size_override("font_size", 12)
        no_expense_note.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
        no_expense_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
        treasury_tooltip_vbox.add_child(no_expense_note)

    treasury_tooltip_vbox.reset_size()
    var content_size = treasury_tooltip_vbox.get_minimum_size()
    # Отступы от края панели: те же 6/4/6/4 пикселя, что в flow_tooltip —
    # скролл-контейнер с PRECEDE_FULL_RECT + offset_*.
    var pad_left = 6
    var pad_top = 4
    var pad_right = 6
    var pad_bottom = 4
    var max_content_height = DETAIL_TOOLTIP_MAX_ROWS * DETAIL_TOOLTIP_ROW_HEIGHT
    var content_height = min(content_size.y, max_content_height)
    var scrollbar_width = 0.0
    if content_size.y > max_content_height:
        scrollbar_width = DETAIL_TOOLTIP_SCROLLBAR_WIDTH
    treasury_tooltip_panel.size = Vector2(
        content_size.x + scrollbar_width + pad_left + pad_right,
        content_height + pad_top + pad_bottom
    )
    # Тултип только что показан — скролл наверх (как в flow_tooltip_panel).
    if not treasury_tooltip_panel.visible:
        treasury_tooltip_scroll.scroll_vertical = 0.0
    var viewport_size = get_viewport().get_visible_rect().size
    # «Залипший» тултип перерисовывается НА МЕСТЕ (панель уже стоит там, куда
    # её перевёл курсор игрока) — иначе панель убегала бы из-под курсора.
    # Пересчёт размера выше всё равно выполняется: контент мог подрасти.
    var pos: Vector2
    if keep_position and treasury_tooltip_panel.visible:
        pos = treasury_tooltip_panel.position
    else:
        pos = mouse_pos + Vector2(15, 15)
        if pos.x + treasury_tooltip_panel.size.x > viewport_size.x:
            pos.x = mouse_pos.x - treasury_tooltip_panel.size.x - 15
        if pos.y + treasury_tooltip_panel.size.y > viewport_size.y:
            pos.y = mouse_pos.y - treasury_tooltip_panel.size.y - 15
    pos.x = max(0.0, min(pos.x, maxf(0.0, viewport_size.x - treasury_tooltip_panel.size.x)))
    pos.y = max(0.0, min(pos.y, maxf(0.0, viewport_size.y - treasury_tooltip_panel.size.y)))
    treasury_tooltip_panel.position = pos
    treasury_tooltip_panel.show()

func hide_treasury_tooltip():
    if treasury_tooltip_panel:
        treasury_tooltip_panel.hide()

func set_message(text: String):
    if message_label:
        message_label.text = text
