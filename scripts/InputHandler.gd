# InputHandler.gd
extends Node

var main_map: Node
var map_renderer: Node
var hud: Node
var hex_tooltip: Node
var tooltip_text_label: Label
var tooltip_products_container: Node
var worker_manager: Node
var popup_menu: Node
var city_ui: Node
var pause_menu: Node
var expansion_manager: Node

var _hovered_hex = null
var _hover_start_time: float = 0.0
var _tooltip_visible: bool = false
var is_dragging: bool = false
var drag_start_scroll_offset: Vector2 = Vector2.ZERO
var drag_start_mouse: Vector2 = Vector2.ZERO

var tooltip_delay: float = 0.5
const SCROLL_SPEED: float = 300.0
const SCROLL_MARGIN: float = 30

func initialize(main_node: Node):
    main_map = main_node
    map_renderer = main_node.map_renderer
    hud = main_node.hud
    hex_tooltip = main_node.hex_tooltip
    tooltip_text_label = main_node.tooltip_text_label
    tooltip_products_container = main_node.tooltip_products_container
    worker_manager = main_node.worker_manager
    popup_menu = main_node.popup_menu
    city_ui = main_node.city_ui
    pause_menu = main_node.pause_menu
    expansion_manager = main_node.expansion_manager

func set_tooltip_delay(value: float):
    tooltip_delay = value

func handle_input(event: InputEvent):
    # --- ОТЛАДОЧНАЯ КОМАНДА: Ctrl+Shift+F = +100 пшеницы ---
    if Engine.is_editor_hint() or OS.is_debug_build():
        if event is InputEventKey and event.pressed:
            if event.keycode == KEY_F and event.ctrl_pressed and event.shift_pressed:
                CityData.city_storage["wheat"] = CityData.city_storage.get("wheat", 0) + 100
                if hud and hud.has_method("show_message"):
                    hud.show_message("Добавлено 100 пшеницы")
                if city_ui.visible:
                    city_ui.update_data(
                        CityData.city_storage,
                        CityData.production_rates,
                        CityData.consumption_rates,
                        CityData.city_food_pool,
                        GameData.buildings,
                        GameData.crafts,
                        CityData.city_built_buildings,
                        GameData.products,
                        GameData.categories
                    )
                    city_ui.update_food_label()
                map_renderer.queue_redraw()
                return # не обрабатываем другие события после этого
    
    if Engine.is_editor_hint():
        return

    if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
        _handle_esc()
        return

    if city_ui.visible or pause_menu.visible or (main_map.settings_menu and main_map.settings_menu.visible):
        return

    # Обработка режима "Развитие" для кликов и подсветки
    if expansion_manager.is_active():
        if event is InputEventMouseButton:
            if _handle_expansion_mode_input(event):
                return
        elif event is InputEventMouseMotion:
            _handle_expansion_mode_motion(event)
            # Не возвращаемся, чтобы _handle_mouse_motion также мог обработать движение

    # Обработка общих событий мыши
    if event is InputEventMouseButton:
        _handle_mouse_button(event)
    elif event is InputEventMouseMotion:
        _handle_mouse_motion(event)

func handle_process(delta: float):
    if Engine.is_editor_hint():
        return

    if city_ui.visible or popup_menu.visible or pause_menu.visible or (main_map.settings_menu and main_map.settings_menu.visible):
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
            var max_scroll_x = (main_map.REGION_COLS * main_map.HEX_RADIUS)
            var max_scroll_y = (main_map.REGION_ROWS * main_map.HEX_RADIUS)
            main_map.scroll_offset.x = clamp(main_map.scroll_offset.x, -max_scroll_x, max_scroll_x)
            main_map.scroll_offset.y = clamp(main_map.scroll_offset.y, -max_scroll_y, max_scroll_y)
            map_renderer.queue_redraw()

    # Тултип
    if hud.get_global_rect().has_point(main_map.get_global_mouse_position()):
        _hide_tooltip()
    if _hovered_hex != null:
        _hover_start_time += delta
        if _hover_start_time >= tooltip_delay and not _tooltip_visible:
            _tooltip_visible = true
            hex_tooltip.visible = true
        if _tooltip_visible:
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
    else:
        _hide_tooltip()

func _handle_esc():
    if city_ui.visible:
        city_ui.close_city()
    elif pause_menu.visible:
        pause_menu.hide()
        main_map.city_button.disabled = false
        main_map.expansion_button.disabled = false
    elif main_map.settings_menu and main_map.settings_menu.visible:
        # Закрываем настройки — pause_menu.gd снова покажет меню паузы
        main_map.settings_menu.hide()
    elif expansion_manager.is_active():
        var active = expansion_manager.toggle()
        if active:
            hud.show_message("Режим освоения включён. ПКМ по выделенной области для освоения.")
        else:
            hud.show_message("Режим освоения выключен.")
    else:
        main_map.open_pause_menu()

func _handle_expansion_mode_input(event: InputEventMouseButton) -> bool:
    if hud.get_global_rect().has_point(event.global_position):
        return true

    if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        if popup_menu.visible:
            popup_menu.hide()
            return true
        var mouse_pos = event.global_position
        var hex = _pixel_to_hex(mouse_pos.x, mouse_pos.y)
        if hex != null and not main_map.tile_data[hex.row][hex.col]["in_influence"]:
            var chunk = expansion_manager.get_chunk_hexes(hex.row, hex.col)
            if chunk.is_empty():
                return true
            # Если чанк ещё не исследован — показываем меню разведки вместо покупки
            var all_explored = true
            for h in chunk:
                if not main_map.tile_data[h.row][h.col].get("is_explored", false):
                    all_explored = false
                    break
            if not all_explored:
                main_map._show_context_menu(hex.row, hex.col, mouse_pos)
                return true
            var available_food = 0
            if CityData:
                for pid in CityData.city_food_pool:
                    if CityData.city_food_pool[pid]:
                        available_food += CityData.city_storage.get(pid, 0)
            expansion_manager.show_context_menu(chunk, mouse_pos, available_food)
        return true

    if event.button_index == MOUSE_BUTTON_LEFT:
        if event.pressed:
            drag_start_scroll_offset = main_map.scroll_offset
            drag_start_mouse = event.global_position
            is_dragging = false
        else:
            if is_dragging:
                is_dragging = false
        return true

    return false

func _handle_expansion_mode_motion(event: InputEventMouseMotion):
    var hex = _pixel_to_hex(event.global_position.x, event.global_position.y)
    if hex != null and not main_map.tile_data[hex.row][hex.col]["in_influence"]:
        expansion_manager.update_hovered_chunk(hex.row, hex.col)
    else:
        expansion_manager.clear_hovered_chunk()
    if _tooltip_visible:
        _hide_tooltip()

func _handle_mouse_button(event: InputEventMouseButton):
    # В режиме "Развитие" левый клик не должен ничего делать (кроме перетаскивания)
    if expansion_manager.is_active() and event.button_index == MOUSE_BUTTON_LEFT:
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

    if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        if popup_menu.visible:
            popup_menu.hide()
            _hide_tooltip()
            return
        var mouse_pos = event.global_position
        var hex = _pixel_to_hex(mouse_pos.x, mouse_pos.y)
        if hex != null and main_map.tile_data[hex.row][hex.col]["in_influence"]:
            main_map._show_context_menu(hex.row, hex.col, mouse_pos)
            _hide_tooltip()

    if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        if popup_menu.visible:
            popup_menu.hide()
            _hide_tooltip()
            return
        var mouse_pos = event.global_position
        var hex = _pixel_to_hex(mouse_pos.x, mouse_pos.y)
        if hex != null and main_map.tile_data[hex.row][hex.col]["in_influence"]:
            if hex.row == main_map.CITY_ROW and hex.col == main_map.CITY_COL:
                var cur_time = Time.get_ticks_msec() / 1000.0
                if cur_time - main_map.last_city_click_time < 0.5:
                    main_map.open_city()
                main_map.last_city_click_time = cur_time

func _handle_mouse_motion(event: InputEventMouseMotion):
    if city_ui.visible or popup_menu.visible or pause_menu.visible:
        return

    if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        var mouse_pos = event.global_position
        if not is_dragging:
            if (mouse_pos - drag_start_mouse).length() > 1.0:
                is_dragging = true
        if is_dragging:
            var delta = mouse_pos - drag_start_mouse
            main_map.scroll_offset = drag_start_scroll_offset + delta
            var max_scroll_x = (main_map.REGION_COLS * main_map.HEX_RADIUS)
            var max_scroll_y = (main_map.REGION_ROWS * main_map.HEX_RADIUS)
            main_map.scroll_offset.x = clamp(main_map.scroll_offset.x, -max_scroll_x, max_scroll_x)
            main_map.scroll_offset.y = clamp(main_map.scroll_offset.y, -max_scroll_y, max_scroll_y)
            map_renderer.queue_redraw()
            return

    var hex = _pixel_to_hex(event.global_position.x, event.global_position.y)
    if hex != _hovered_hex:
        _hovered_hex = hex
        _hover_start_time = 0.0
        if _tooltip_visible:
            hex_tooltip.visible = false
            _tooltip_visible = false
        if hex != null:
            main_map.update_tooltip_text(hex.row, hex.col)

func _hide_tooltip():
    hex_tooltip.visible = false
    _tooltip_visible = false
    _hovered_hex = null
    _hover_start_time = 0.0
    for child in tooltip_products_container.get_children():
        child.queue_free()

func _pixel_to_hex(mx: float, my: float):
    for row in range(main_map.REGION_ROWS):
        for col in range(main_map.REGION_COLS):
            var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
            center.x += main_map.offset_x + main_map.scroll_offset.x
            center.y += main_map.offset_y + main_map.scroll_offset.y
            var verts = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
            if HexUtils.point_in_polygon(mx, my, verts):
                return {"row": row, "col": col}
    return null
