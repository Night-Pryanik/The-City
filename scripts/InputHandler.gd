# InputHandler.gd
extends Node

var main_map: Node
var map_renderer: Node
var progress_bar_layer: Node
var hud: Node
var hex_tooltip: Node
var tooltip_text_label: RichTextLabel
var tooltip_products_container: Node
var worker_manager: Node
var city_ui: Node
var town_ui: Node
var pause_menu: Node
var expansion_manager: Node
var debug_manager: Node

var _hovered_hex = null
var _hover_start_time: float = 0.0
var _tooltip_visible: bool = false
var _tooltip_visible_time: float = 0.0
var _extended_tooltip_shown: bool = false
# Период обновления СОДЕРЖИМОГО тултипа без движения мыши. Нужен для
# динамических данных (заполенность пастбища, производство), которые меняются
# со временем. Период равен настройке «Интервал обновления данных о ресурсах»
# (CityData.resource_display_interval, меню «Настройки → Игра») — тултип на
# карте обновляется тем же ритмом, что и остальные места с ресурсами.
# Первая отрисовка при смене гекса остаётся мгновенной.
var _tooltip_content_refresh_timer: float = 0.0
var is_dragging: bool = false
var drag_start_scroll_offset: Vector2 = Vector2.ZERO
var drag_start_mouse: Vector2 = Vector2.ZERO

var tooltip_delay: float = 0.5
var extended_tooltip_delay: float = 1.0
const SCROLL_SPEED: float = 300.0
const SCROLL_MARGIN: float = 30

func initialize(main_node: Node):
    main_map = main_node
    map_renderer = main_node.map_renderer
    progress_bar_layer = main_node.progress_bar_layer
    hud = main_node.hud
    hex_tooltip = main_node.hex_tooltip
    tooltip_text_label = main_node.tooltip_text_label
    tooltip_products_container = main_node.tooltip_products_container
    worker_manager = main_node.worker_manager
    city_ui = main_node.city_ui
    town_ui = main_node.town_ui
    pause_menu = main_node.pause_menu
    expansion_manager = main_node.expansion_manager
    debug_manager = main_node.debug_manager

func set_tooltip_delay(value: float):
    tooltip_delay = value

func set_extended_tooltip_delay(value: float):
    extended_tooltip_delay = value

func handle_input(event: InputEvent):
    if Engine.is_editor_hint():
        return

    if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
        # ESC: если открыт интерфейс городка — закрываем именно его, даже если
        # на карте выделен гекс или активно превью действия (окно городка
        # поверх карты).
        if town_ui.visible:
            town_ui.close_town()
            get_viewport().set_input_as_handled()
            return
        # ESC: если открыт интерфейс города — закрываем именно его, даже если
        # на карте выделен гекс или активно превью действия (интерфейс города
        # поверх карты). Иначе сбрасываем превью действия в панели управления,
        # затем снимаем выделение гекса, и только потом — обычное поведение ESC.
        if city_ui.visible:
            city_ui.close_city()
            get_viewport().set_input_as_handled()
            return
        if main_map.control_panel.has_preview():
            main_map.control_panel.clear_preview()
            get_viewport().set_input_as_handled()
            return
        if main_map.control_panel.has_selection():
            main_map.clear_selection()
            get_viewport().set_input_as_handled()
            return
        _handle_esc()
        # Помечаем событие обработанным, чтобы оно не распространилось
        # на _unhandled_input (иначе меню паузы, став видимым, сразу закроется)
        get_viewport().set_input_as_handled()
        return

    if town_ui.visible or city_ui.visible or pause_menu.visible or (main_map.settings_menu and main_map.settings_menu.visible):
        return

    # Взаимодействие с картой недоступно, когда курсор находится над панелью
    # управления: клики, перетаскивание, тултипы и скролл не должны проходить
    # сквозь панель к карте. Клавиатурные события (ESC и т.п.) при этом
    # продолжают обрабатываться ниже.
    # Взаимодействие с картой также недоступно, когда курсор находится над
    # HUD (левый верхний угол): иначе движение мыши через HUD подсвечивает
    # чанки Региона и всплывают тултипы, а клик по HUD выделяет гекс под ним.
    # Кнопки HUD при этом продолжают работать: они обрабатываются через GUI-
    # фазу (pressed / gui_input), независимо от этого обработчика.
    if event is InputEventMouse:
        var over_hud = hud != null and hud.get_global_rect().has_point(event.global_position)
        var over_panel = main_map.control_panel != null \
                and main_map.control_panel.get_global_rect().has_point(event.global_position)
        if over_panel or over_hud:
            _hide_tooltip()
            # Убираем подсветку чанка Региона, оставшуюся от наведения
            # до захода курсора на панель/HUD.
            expansion_manager.clear_hovered_chunk()
            return

    # Дебаг-меню открыто — блокируем взаимодействие с картой
    if debug_manager and debug_manager.is_open:
        # В режиме ожидания клика по гексу разрешаем только клики мыши
        if debug_manager.waiting_for_hex:
            if event is InputEventMouseButton:
                _handle_mouse_button(event)
        return

    # Обработка общих событий мыши
    if event is InputEventMouseButton:
        _handle_mouse_button(event)
    elif event is InputEventMouseMotion:
        _handle_mouse_motion(event)
        # Обновляем подсветку чанка при наведении на гексы вне Кольца Влияния.
        # Гекс берём через _interactive_hex_at(): до изучения Картографии
        # гексы тумана войны (вне Региона) недоступны, и выделение
        # чанка на них не рисуется.
        var h = _interactive_hex_at(event.global_position.x, event.global_position.y)
        if h != null and not main_map.tile_data[h.row][h.col].get("in_influence", false):
            expansion_manager.update_hovered_chunk(h.row, h.col)
        else:
            expansion_manager.clear_hovered_chunk()

func handle_process(delta: float):
    if Engine.is_editor_hint():
        return

    if town_ui.visible or city_ui.visible or pause_menu.visible or (main_map.settings_menu and main_map.settings_menu.visible):
        _hide_tooltip()
        return

    # Дебаг-меню открыто — блокируем обработку процесса (скролл, тултипы)
    if debug_manager and debug_manager.is_open:
        _hide_tooltip()
        return

    # Скрываем тултип и отключаем скролл краями окна, когда курсор находится
    # над панелью управления (взаимодействие с картой сквозь неё запрещено).
    if main_map.control_panel \
            and main_map.control_panel.get_global_rect().has_point(main_map.get_global_mouse_position()):
        _hide_tooltip()
        return

    # Скролл краями
    if not is_dragging and main_map.use_edge_scrolling:
        var mouse_pos = main_map.get_viewport().get_mouse_position()
        var viewport_size = main_map.get_viewport_rect().size
        var inside = mouse_pos.x >= 0 and mouse_pos.x <= viewport_size.x and mouse_pos.y >= 0 and mouse_pos.y <= viewport_size.y
        var scroll = Vector2.ZERO
        if inside:
            if mouse_pos.x < SCROLL_MARGIN:
                scroll.x = SCROLL_SPEED * delta
            elif mouse_pos.x > viewport_size.x - SCROLL_MARGIN:
                scroll.x = - SCROLL_SPEED * delta
            if mouse_pos.y < SCROLL_MARGIN:
                scroll.y = SCROLL_SPEED * delta
            elif mouse_pos.y > viewport_size.y - SCROLL_MARGIN:
                scroll.y = - SCROLL_SPEED * delta

        if scroll != Vector2.ZERO:
            main_map.scroll_offset += scroll
            # Максимальная дистанция скролла карты — единый источник истины
            # (main_map.get_max_scroll). Тем же значением ограничивается и
            # досягаемость гексов: разведку можно отправить только туда,
            # куда игрок может проскроллить (main_map.get_scout_reach_bounds).
            var max_scroll = main_map.get_max_scroll()
            main_map.scroll_offset.x = clamp(main_map.scroll_offset.x, -max_scroll.x, max_scroll.x)
            main_map.scroll_offset.y = clamp(main_map.scroll_offset.y, -max_scroll.y, max_scroll.y)
            map_renderer.queue_redraw()
            if progress_bar_layer:
                progress_bar_layer.queue_redraw()

    # Тултип
    if hud.get_global_rect().has_point(main_map.get_global_mouse_position()):
        _hide_tooltip()
    if _hovered_hex != null:
        _hover_start_time += delta
        if _hover_start_time >= tooltip_delay and not _tooltip_visible:
            _tooltip_visible = true
            _tooltip_visible_time = 0.0
            hex_tooltip.visible = true
        if _tooltip_visible:
            _tooltip_visible_time += delta
            var tip_pos = main_map.get_viewport().get_mouse_position() + Vector2(15, 15)
            var vbox = hex_tooltip.get_node("TooltipVBox")
            var total_height = 0.0
            for child in vbox.get_children():
                total_height += child.get_combined_minimum_size().y + 4
            var total_width = 0.0
            for child in vbox.get_children():
                if child.get_combined_minimum_size().x > total_width:
                    total_width = child.get_combined_minimum_size().x
            hex_tooltip.size = Vector2(total_width + 12, total_height + 12)
            tooltip_text_label.position = Vector2(6, 4)
            if tip_pos.x + hex_tooltip.size.x > main_map.get_viewport_rect().size.x:
                tip_pos.x = main_map.get_viewport().get_mouse_position().x - hex_tooltip.size.x - 15
            if tip_pos.y + hex_tooltip.size.y > main_map.get_viewport_rect().size.y:
                tip_pos.y = main_map.get_viewport().get_mouse_position().y - hex_tooltip.size.y - 15
            tip_pos.x = max(0, tip_pos.x)
            tip_pos.y = max(0, tip_pos.y)
            hex_tooltip.position = tip_pos
            # Расширенный тултип: показываем, если есть бонусы производства
            # или можно построить улучшение (тогда показываем расчёт труда)
            if _tooltip_visible_time >= extended_tooltip_delay and not _extended_tooltip_shown and main_map.has_method("has_extended_tooltip_info") and main_map.has_method("update_extended_tooltip"):
                if main_map.has_extended_tooltip_info(_hovered_hex.row, _hovered_hex.col):
                    _extended_tooltip_shown = true
                    main_map.update_extended_tooltip(_hovered_hex.row, _hovered_hex.col)

            # Обновляем содержимое тултипа без движения мыши — только для
            # «растущих» ресурсов (пастбища с time_to_mature > 0): их заполенность
            # и эффективный выход меняются со временем. Для остальных гексов
            # контент статичен, дёргать перерисовку смысла нет.
            if _is_hovered_tile_growing():
                _tooltip_content_refresh_timer += delta
                if _tooltip_content_refresh_timer >= CityData.resource_display_interval:
                    _tooltip_content_refresh_timer = 0.0
                    main_map.update_tooltip_text(_hovered_hex.row, _hovered_hex.col)
    else:
        _hide_tooltip()

func _is_hovered_tile_growing() -> bool:
    if _hovered_hex == null:
        return false
    var tile = main_map.tile_data[_hovered_hex.row][_hovered_hex.col]
    var eff_res = MapHelpers.get_effective_resource(tile)
    if eff_res == "" or tile.get("improvement", null) == null:
        return false
    return MapHelpers.is_growing_resource(GameData.raw_resources.get(eff_res, {}))

func _handle_esc():
    if town_ui.visible:
        town_ui.close_town()
    elif city_ui.visible:
        city_ui.close_city()
    elif pause_menu.visible:
        pause_menu.hide()
        main_map.city_button.disabled = false
        main_map.expansion_button.disabled = false
    elif main_map.settings_menu and main_map.settings_menu.visible:
        # Закрываем настройки — pause_menu.gd снова покажет меню паузы
        main_map.settings_menu.hide()
    else:
        main_map.open_pause_menu()

func _handle_mouse_button(event: InputEventMouseButton):
    # Дебаг-меню: ожидание клика по гексу для размещения ресурса
    if debug_manager and debug_manager.waiting_for_hex:
        if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
            var hex = _pixel_to_hex(event.global_position.x, event.global_position.y)
            if hex != null:
                debug_manager.handle_hex_click(hex.row, hex.col)
        return

    if event.button_index == MOUSE_BUTTON_LEFT:
        if event.pressed:
            drag_start_scroll_offset = main_map.scroll_offset
            drag_start_mouse = event.global_position
            is_dragging = false
        else:
            if is_dragging:
                is_dragging = false
                return

    # Выделение гекса выполняется при ОТПУСКАНИИ ЛКМ, а не при нажатии —
    # чтобы зажатие и перетаскивание карты не выделяло и не сбрасывало гекс.
    # При перетаскивании обработка уже прервана выше (return при is_dragging).
    if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
        var mouse_pos = event.global_position
        var hex = _interactive_hex_at(mouse_pos.x, mouse_pos.y)
        if hex != null:
            # ЛКМ выделяет любой ДОСТУПНЫЙ гекс, который видно на экране:
            # внутри Кольца Влияния — информация/действия, вне Кольца —
            # разведка или покупка чанка (см. control_panel.
            # _collect_region_actions). До изучения Картографии гексы тумана
            # войны недоступны (см. main_map.is_hex_interactive): выделить их
            # нельзя, разведчиков туда не отправить.
            main_map.select_hex(hex.row, hex.col)
            if main_map.tile_data[hex.row][hex.col].get("in_influence", false) \
                    and hex.row == main_map.city_row and hex.col == main_map.city_col:
                var cur_time = Time.get_ticks_msec() / 1000.0
                if cur_time - main_map.last_city_click_time < 0.5:
                    main_map.open_city()
                main_map.last_city_click_time = cur_time
            # Двойной клик по гексу городка — переход в его интерфейс (торговля).
            # Только для РАСКРЫТОГО гекса: в тумане войны городок виден лишь
            # намёком (полупрозрачная иконка), и торговля с ним невозможна.
            var click_tile = main_map.tile_data[hex.row][hex.col]
            if click_tile.get("has_town", false) \
                    and (click_tile.get("in_influence", false) or click_tile.get("is_explored", false)):
                var town_click_time = Time.get_ticks_msec() / 1000.0
                if town_click_time - main_map.last_town_click_time < 0.5:
                    main_map.open_town_ui(hex.row, hex.col)
                main_map.last_town_click_time = town_click_time
        else:
            # Клик ЛКМ по недоступному месту: либо пустота за пределами
            # карты, либо гекс тумана войны до изучения Картографии.
            # В последнем случае объясняем игроку, чего не хватает, — иначе
            # клик «молча» ничего не делает.
            var blocked_hex = _pixel_to_hex(mouse_pos.x, mouse_pos.y)
            if blocked_hex != null and not main_map.is_cartography_researched():
                main_map.hud.show_message("Для разведки за пределами Региона нужна технология «%s»"
                        % main_map.get_cartography_tech_name())
            if main_map.control_panel.has_selection():
                main_map.clear_selection()

func _handle_mouse_motion(event: InputEventMouseMotion):
    if town_ui.visible or city_ui.visible or pause_menu.visible:
        return

    if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        var mouse_pos = event.global_position
        if not is_dragging:
            if (mouse_pos - drag_start_mouse).length() > 1.0:
                is_dragging = true
        if is_dragging:
            var delta = mouse_pos - drag_start_mouse
            main_map.scroll_offset = drag_start_scroll_offset + delta
            # Клэмп скролла — единый источник истины (main_map.get_max_scroll).
            # Та же формула, что и для скролла краями экрана выше; иначе при
            # перетаскивании карта упиралась бы в границы Региона и нельзя было
            # бы проскроллить туман войны для разведки.
            var max_scroll = main_map.get_max_scroll()
            main_map.scroll_offset.x = clamp(main_map.scroll_offset.x, -max_scroll.x, max_scroll.x)
            main_map.scroll_offset.y = clamp(main_map.scroll_offset.y, -max_scroll.y, max_scroll.y)
            map_renderer.queue_redraw()
            if progress_bar_layer:
                progress_bar_layer.queue_redraw()
            return

    var hex = _interactive_hex_at(event.global_position.x, event.global_position.y)
    # Гекс в тумане войны не участвует в тултипе: местность, ресурсы и
    # улучшения игроку не известны (см. main_map.is_hex_in_fog). Наведение
    # обнуляем ДО логики тултипа — тултип не появится даже после задержки.
    # Подсветка чанка и клик при этом работают: они содержимое гекса не
    # раскрывают (ниже отдельный вызов _interactive_hex_at).
    if hex != null and main_map.is_hex_in_fog(hex.row, hex.col):
        hex = null
    if hex != _hovered_hex:
        _hovered_hex = hex
        _hover_start_time = 0.0
        _extended_tooltip_shown = false
        if _tooltip_visible:
            hex_tooltip.visible = false
            _tooltip_visible = false
        if hex != null:
            main_map.update_tooltip_text(hex.row, hex.col)

    # Обновляем подсветку чанка при наведении на гексы вне Кольца Влияния.
    # Прямой queue_redraw() здесь НЕ вызываем: expansion_manager.update_hovered_chunk()
    # / clear_hovered_chunk() эмитят сигнал chunk_hovered ТОЛЬКО при реальном
    # изменении чанка, а этот сигнал подключён к main_map._on_chunk_hovered(),
    # который вызывает map_renderer.queue_redraw(). Так мы убираем лишние
    # перерисовки всей карты при каждом движении мыши.
    var h = _interactive_hex_at(event.global_position.x, event.global_position.y)
    if h != null and not main_map.tile_data[h.row][h.col].get("in_influence", false):
        expansion_manager.update_hovered_chunk(h.row, h.col)
    else:
        expansion_manager.clear_hovered_chunk()

func _hide_tooltip():
    hex_tooltip.visible = false
    _tooltip_visible = false
    _tooltip_visible_time = 0.0
    _tooltip_content_refresh_timer = 0.0
    _hovered_hex = null
    _hover_start_time = 0.0
    for child in tooltip_products_container.get_children():
        child.queue_free()

func _pixel_to_hex(mx: float, my: float):
    # Быстрое обратное преобразование координат: вычисляем приблизительный гекс,
    # затем проверяем его и соседей в небольшом радиусе — вместо итерации по
    # всей карте. Проверяются гексы ВСЕЙ КАРТЫ: функция отвечает только за
    # геометрию и не знает игровых правил. Доступность гекса для наведения и
    # клика проверяется отдельно — см. _interactive_hex_at().
    # Отдельный предел для всей карты не нужен: скролл ограничен
    # main_map.get_max_scroll(), поэтому недостижимые гексы физически не могут
    # оказаться под курсором.
    var radius = main_map.HEX_RADIUS
    var x_spacing = radius * sqrt(3.0)
    var y_spacing = radius * 1.5

    var world_x = mx - (main_map.offset_x + main_map.scroll_offset.x)
    var world_y = my - (main_map.offset_y + main_map.scroll_offset.y)

    var approx_row = int(round(world_y / y_spacing))
    var approx_col = int(round(world_x / x_spacing))

    # Проверяем приблизительный гекс и соседей в радиусе 2
    # (покрывает смещение нечётных рядов и неточность обратного преобразования).
    for row in range(approx_row - 2, approx_row + 3):
        if row < 0 or row >= main_map.map_rows:
            continue
        for col in range(approx_col - 2, approx_col + 3):
            if col < 0 or col >= main_map.map_cols:
                continue
            var center = HexUtils.hex_center(row, col, radius)
            center.x += main_map.offset_x + main_map.scroll_offset.x
            center.y += main_map.offset_y + main_map.scroll_offset.y
            var verts = HexUtils.hex_vertices(center.x, center.y, radius)
            if HexUtils.point_in_polygon(mx, my, verts):
                return {"row": row, "col": col}
    return null

# Гекс под курсором, если с ним МОЖНО взаимодействовать: наведение
# (тултип), подсветка чанка разведки/покупки, выделение кликом ЛКМ.
# Вне Региона гексы доступны только после изучения технологии
# «Картография» (туман войны): без неё разведка ограничена Регионом,
# а гексы тумана войны не реагируют ни на наведение, ни на клик
# (см. main_map.is_hex_interactive). _pixel_to_hex() остаётся чистой
# геометрией и используется напрямую там, где правила не нужны
# (например, дебаг-режим размещения ресурса).
func _interactive_hex_at(mx: float, my: float):
    var hex = _pixel_to_hex(mx, my)
    if hex == null:
        return null
    if not main_map.is_hex_interactive(hex.row, hex.col):
        return null
    return hex
