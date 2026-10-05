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
# The refresh period of the tooltip CONTENT without mouse movement. It is needed for
# dynamic data (the pasture fill, production), which changes
# over time. The period equals the "Resource data refresh interval" setting
# (CityData.resource_display_interval, the "Settings → Game" menu) — the tooltip on the
# map is refreshed at the same rhythm as the other places with resources.
# The first drawing on a hex change remains instantaneous.
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
        # ESC: if the town interface is open — we close exactly it, even if
        # a hex is selected on the map or an action preview is active (the town window
        # is over the map).
        if town_ui.visible:
            town_ui.close_town()
            get_viewport().set_input_as_handled()
            return
        # ESC: if the city interface is open — we close exactly it, even if
        # a hex is selected on the map or an action preview is active (the city interface
        # is over the map). Otherwise we reset the action preview in the control panel,
        # then clear the hex selection, and only then — the usual ESC behaviour.
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
        # We mark the event as handled, so that it does not spread
        # to _unhandled_input (otherwise the pause menu, having become visible, would close right away)
        get_viewport().set_input_as_handled()
        return

    if town_ui.visible or city_ui.visible or pause_menu.visible or (main_map.settings_menu and main_map.settings_menu.visible):
        return

    # Interaction with the map is unavailable when the cursor is over the control
    # panel: clicks, dragging, tooltips and scrolling must not pass
    # through the panel to the map. Keyboard events (ESC and so on) meanwhile
    # continue to be handled below.
    # Interaction with the map is also unavailable when the cursor is over the
    # HUD (the top left corner): otherwise the mouse movement across the HUD highlights
    # the Region chunks and the tooltips pop up, and a click on the HUD selects the hex under it.
    # And over the "sticky" treasury breakdown tooltip: the tooltip covers the map, and
    # the hex tooltip should not pop up through it, nor should a chunk be
    # highlighted or a hex be selected under it.
    # The HUD buttons meanwhile keep working: they are handled via the GUI
    # phase (pressed / gui_input), independently of this handler.
    if event is InputEventMouse:
        var over_hud = hud != null and hud.get_global_rect().has_point(event.global_position)
        var over_panel = main_map.control_panel != null \
                and main_map.control_panel.get_global_rect().has_point(event.global_position)
        var over_treasury_tooltip = _is_mouse_over_treasury_tooltip(event.global_position)
        if over_panel or over_hud or over_treasury_tooltip:
            _hide_tooltip()
            # We remove the Region chunk highlight left over from hovering
            # before the cursor entered the panel/HUD/tooltip.
            expansion_manager.clear_hovered_chunk()
            return

    # The debug menu is open — we block the interaction with the map
    if debug_manager and debug_manager.is_open:
        # In the mode of waiting for a click on a hex we allow only the mouse clicks
        if debug_manager.waiting_for_hex:
            if event is InputEventMouseButton:
                _handle_mouse_button(event)
        return

    # Handling of the common mouse events
    if event is InputEventMouseButton:
        _handle_mouse_button(event)
    elif event is InputEventMouseMotion:
        _handle_mouse_motion(event)
        # We update the chunk highlight when hovering over the hexes outside the Influence Ring.
        # The hex is taken via _interactive_hex_at(): before researching Cartography
        # the fog of war hexes (outside the Region) are unavailable, and the chunk
        # highlight is not drawn on them.
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

    # The debug menu is open — we block the process handling (scrolling, tooltips)
    if debug_manager and debug_manager.is_open:
        _hide_tooltip()
        return

    # We hide the tooltip and disable the edge scrolling when the cursor is
    # over the control panel (interaction with the map through it is forbidden).
    if main_map.control_panel \
            and main_map.control_panel.get_global_rect().has_point(main_map.get_global_mouse_position()):
        _hide_tooltip()
        return

    # The same — when the cursor is on the "sticky" treasury breakdown tooltip: while it is there,
    # the map does not react (the hex tooltip does not pop up through the tooltip and the
    # chunk is not highlighted, and there is no edge scrolling either). _hide_tooltip() kills
    # the hover state as well, so the hex tooltip will not appear on the delay either.
    var mouse_pos_ui: Vector2 = main_map.get_global_mouse_position()
    if _is_mouse_over_treasury_tooltip(mouse_pos_ui):
        _hide_tooltip()
        # We remove the chunk highlight as well: the tooltip could have "stuck"
        # under an already stationary cursor (the panel at the screen edge shifts inwards).
        expansion_manager.clear_hovered_chunk()
        return

    # Edge scrolling
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
            # The maximum scroll distance of the map — the single source of truth
            # (main_map.get_max_scroll). The same value also limits
            # the reachability of the hexes: the scouting can be sent only where
            # the player can scroll to (main_map.get_scout_reach_bounds).
            var max_scroll = main_map.get_max_scroll()
            main_map.scroll_offset.x = clamp(main_map.scroll_offset.x, -max_scroll.x, max_scroll.x)
            main_map.scroll_offset.y = clamp(main_map.scroll_offset.y, -max_scroll.y, max_scroll.y)
            map_renderer.queue_redraw()
            if progress_bar_layer:
                progress_bar_layer.queue_redraw()

    # The tooltip
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
            # The extended tooltip: the hex properties (quality, feed, fill,
            # access to fresh water), production, consumption, road level.
            if _tooltip_visible_time >= extended_tooltip_delay and not _extended_tooltip_shown and main_map.has_method("has_extended_tooltip_info") and main_map.has_method("update_extended_tooltip"):
                if main_map.has_extended_tooltip_info(_hovered_hex.row, _hovered_hex.col):
                    _extended_tooltip_shown = true
                    main_map.update_extended_tooltip(_hovered_hex.row, _hovered_hex.col)

            # We update the tooltip contents without mouse movement — only for
            # the "growing" resources (pastures with time_to_mature > 0): their fill
            # and effective output change over time. For the other hexes
            # the content is static, there is no point in triggering a redraw.
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
        # We close the settings — pause_menu.gd will show the pause menu again
        main_map.settings_menu.hide()
    else:
        main_map.open_pause_menu()

func _handle_mouse_button(event: InputEventMouseButton):
    # The debug menu: waiting for a click on a hex to place a resource
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

    # The hex selection is performed on the RELEASE of the LMB, and not on the press —
    # so that pressing and dragging the map does not select and reset the hex.
    # When dragging, the handling is already interrupted above (a return on is_dragging).
    if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
        var mouse_pos = event.global_position
        var hex = _interactive_hex_at(mouse_pos.x, mouse_pos.y)
        if hex != null:
            # The LMB selects any AVAILABLE hex that is visible on the screen:
            # inside the Influence Ring — information/actions, outside the Ring —
            # scouting or buying a chunk (see control_panel.
            # _collect_region_actions). Before researching Cartography the fog of
            # war hexes are unavailable (see main_map.is_hex_interactive): they cannot
            # be selected, and scouts cannot be sent there.
            main_map.select_hex(hex.row, hex.col)
            if main_map.tile_data[hex.row][hex.col].get("in_influence", false) \
                    and hex.row == main_map.city_row and hex.col == main_map.city_col:
                var cur_time = Time.get_ticks_msec() / 1000.0
                if cur_time - main_map.last_city_click_time < 0.5:
                    main_map.open_city()
                main_map.last_city_click_time = cur_time
            # A double click on a town hex — go to its interface (trade).
            # Only for an OPENED hex: in the fog of war the town is visible only
            # as a hint (a semi-transparent icon), and trading with it is impossible.
            var click_tile = main_map.tile_data[hex.row][hex.col]
            if click_tile.get("has_town", false) \
                    and (click_tile.get("in_influence", false) or click_tile.get("is_explored", false)):
                var town_click_time = Time.get_ticks_msec() / 1000.0
                if town_click_time - main_map.last_town_click_time < 0.5:
                    main_map.open_town_ui(hex.row, hex.col)
                main_map.last_town_click_time = town_click_time
        else:
            # An LMB click on an unavailable place: either the emptiness beyond
            # the edges of the map, or a fog of war hex before researching Cartography.
            # In the latter case we explain to the player what is missing — otherwise
            # the click would "silently" do nothing.
            var blocked_hex = _pixel_to_hex(mouse_pos.x, mouse_pos.y)
            if blocked_hex != null and not main_map.is_cartography_researched():
                main_map.hud.show_message(tr("Scouting beyond the Region requires the technology \"%s\"")
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
            # The scroll clamp — the single source of truth (main_map.get_max_scroll).
            # The same formula as for the edge scrolling of the screen above; otherwise on
            # dragging the map would run into the Region bounds and it would be impossible to
            # scroll to the fog of war for scouting.
            var max_scroll = main_map.get_max_scroll()
            main_map.scroll_offset.x = clamp(main_map.scroll_offset.x, -max_scroll.x, max_scroll.x)
            main_map.scroll_offset.y = clamp(main_map.scroll_offset.y, -max_scroll.y, max_scroll.y)
            map_renderer.queue_redraw()
            if progress_bar_layer:
                progress_bar_layer.queue_redraw()
            return

    var hex = _interactive_hex_at(event.global_position.x, event.global_position.y)
    # A hex in the fog of war does not take part in the tooltip: the terrain, resources and
    # improvements are not known to the player (see main_map.is_hex_in_fog). We reset the hover
    # BEFORE the tooltip logic — the tooltip will not appear even after the delay.
    # The chunk highlight and the click work meanwhile: they do not reveal
    # the contents of the hex (there is a separate _interactive_hex_at call below).
    if hex != null and main_map.is_hex_in_fog(hex.row, hex.col):
        hex = null
    if hex != _hovered_hex:
        _hovered_hex = hex
        _hover_start_time = 0.0
        _extended_tooltip_shown = false
        # We reset the binding of the extended block right here: while it is alive,
        # update_tooltip_text below would draw the extended block on the new hex
        # without the hover delay.
        if main_map.has_method("clear_extended_tooltip"):
            main_map.clear_extended_tooltip()
        if _tooltip_visible:
            hex_tooltip.visible = false
            _tooltip_visible = false
        if hex != null:
            main_map.update_tooltip_text(hex.row, hex.col)

    # We update the chunk highlight when hovering over the hexes outside the Influence Ring.
    # We do NOT call queue_redraw() directly here: expansion_manager.update_hovered_chunk()
    # / clear_hovered_chunk() emit the chunk_hovered signal ONLY on a real
    # chunk change, and that signal is connected to main_map._on_chunk_hovered(),
    # which calls map_renderer.queue_redraw(). In this way we get rid of the extra
    # redraws of the whole map on every mouse movement.
    var h = _interactive_hex_at(event.global_position.x, event.global_position.y)
    if h != null and not main_map.tile_data[h.row][h.col].get("in_influence", false):
        expansion_manager.update_hovered_chunk(h.row, h.col)
    else:
        expansion_manager.clear_hovered_chunk()

# The cursor is now over the shown ("sticky") treasury breakdown tooltip of the HUD layer.
# Such a tooltip covers the map, and the map under it should not react to the
# cursor: neither the hex tooltip, nor the chunk highlight, nor clicks/selection, nor the edge
# scrolling. The check is owned by main_map — here there is only delegation (with
# a soft has_method check: InputHandler works with scenes without the HUD layer as well).
func _is_mouse_over_treasury_tooltip(pos: Vector2) -> bool:
    if main_map == null or not main_map.has_method("is_mouse_over_treasury_tooltip"):
        return false
    return bool(main_map.is_mouse_over_treasury_tooltip(pos))

func _hide_tooltip():
    hex_tooltip.visible = false
    _tooltip_visible = false
    _tooltip_visible_time = 0.0
    _tooltip_content_refresh_timer = 0.0
    _hovered_hex = null
    _hover_start_time = 0.0
    # Just as the flag above — here too: the tooltip is hidden, the extended block is not shown.
    if main_map != null and main_map.has_method("clear_extended_tooltip"):
        main_map.clear_extended_tooltip()
    for child in tooltip_products_container.get_children():
        child.queue_free()

func _pixel_to_hex(mx: float, my: float):
    # A fast inverse coordinate conversion: we compute an approximate hex,
    # then check it and its neighbours within a small radius — instead of iterating over
    # the whole map. The hexes of the WHOLE MAP are checked: the function is responsible only for
    # the geometry and does not know the game rules. The availability of the hex for hovering and
    # clicking is checked separately — see _interactive_hex_at().
    # A separate limit for the whole map is not needed: the scroll is limited
    # by main_map.get_max_scroll(), therefore the unreachable hexes physically cannot
    # end up under the cursor.
    var radius = main_map.HEX_RADIUS
    var x_spacing = radius * sqrt(3.0)
    var y_spacing = radius * 1.5

    var world_x = mx - (main_map.offset_x + main_map.scroll_offset.x)
    var world_y = my - (main_map.offset_y + main_map.scroll_offset.y)

    var approx_row = int(round(world_y / y_spacing))
    var approx_col = int(round(world_x / x_spacing))

    # We check the approximate hex and its neighbours within a radius of 2
    # (it covers the offset of the odd rows and the inaccuracy of the inverse conversion).
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

# The hex under the cursor, if it CAN be interacted with: hovering
# (the tooltip), the scouting/buying chunk highlight, selection by an LMB click.
# Outside the Region the hexes are available only after researching the
# "Cartography" technology (the fog of war): without it the scouting is limited to the Region,
# and the fog of war hexes react neither to hovering nor to clicking
# (see main_map.is_hex_interactive). _pixel_to_hex() remains pure
# geometry and is used directly where the rules are not needed
# (for example, the debug mode of placing a resource).
func _interactive_hex_at(mx: float, my: float):
    var hex = _pixel_to_hex(mx, my)
    if hex == null:
        return null
    if not main_map.is_hex_interactive(hex.row, hex.col):
        return null
    return hex
