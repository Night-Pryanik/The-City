@tool
extends "res://scripts/main_map/state.gd"

# This link — the camera: the offsets, the zoom, the scroll and the mapping of the screen to the
# world. The map is drawn in the world coordinates, so a change of the view only moves the
# transform of the renderer (see apply_view_transform).

func _calc_offsets():
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size
    # The offsets centre the Region in the LOCAL pixels of the map, and the zoom magnifies
    # them: at a zoom other than 1 the same window holds viewport / zoom of them. Without
    # the division a zoom restored from the settings would push the map into the top left
    # corner instead of centring it.
    var offsets = MapHelpers.calc_offsets(
        region_start_row, region_end_row,
        region_start_col, region_end_col,
        HEX_RADIUS, viewport_size / zoom
    )
    offset_x = offsets.x
    offset_y = offsets.y
    apply_view_transform()

# Applies the current camera (the offset and the scroll) to the renderer. The map is drawn in
# the world coordinates, so this transform IS the pan and the zoom: no drawing is re-recorded.
func apply_view_transform() -> void:
    if map_renderer == null:
        return
    map_renderer.scale = Vector2(zoom, zoom)
    map_renderer.position = _view_position(zoom)

# Where the renderer must sit for the camera of scroll_offset read through offsets at `value`.
func _view_position(value: float) -> Vector2:
    return _view_position_for(scroll_offset, value)

func _view_position_for(scroll: Vector2, value: float) -> Vector2:
    return Vector2(offset_x + scroll.x, offset_y + scroll.y) * value

func _on_city_button_gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        center_on_hex(city_row, city_col)

# Centers the map on a hex. The clamp by get_max_scroll is the same as in the edge scrolling
# (InputHandler): without it a hex at the border of the Region would ask for a scroll the map
# cannot make, and the hex would stay off screen. The half of the screen is taken in LOCAL
# pixels, hence the division by the zoom: the hex has to land in the middle of the SCREEN.
func center_on_hex(row: int, col: int) -> void:
    # A running zoom would keep correcting the offset towards its anchor and drag the
    # map away from the hex we are about to centre.
    finish_zoom()
    var max_scroll = get_max_scroll()
    scroll_offset = - (HexUtils.hex_center(row, col, HEX_RADIUS) + Vector2(offset_x, offset_y)
            - get_viewport_rect().size / (2.0 * zoom))
    scroll_offset.x = clamp(scroll_offset.x, -max_scroll.x, max_scroll.x)
    scroll_offset.y = clamp(scroll_offset.y, -max_scroll.y, max_scroll.y)
    apply_view_transform()
    if progress_bar_layer:
        progress_bar_layer.queue_redraw()

# The entry point of the zoom gestures: `anchor` is the SCREEN point that must stay in
# place, `factor` multiplies the current TARGET (so a spin of the wheel accumulates
# instead of restarting from the value the animation has reached so far).
func zoom_by(factor: float, anchor: Vector2) -> void:
    # The anchor is re-read from the CURRENT visual state, so a spin in the middle of an
    # animation continues from where the map actually is on the screen.
    _zoom_anchor = anchor
    _zoom_world = screen_to_local(anchor)
    zoom_target = clampf(zoom_target * factor, ZOOM_MIN, ZOOM_MAX)

# Sets the zoom without an animation. Used when the value comes from the settings.
func set_zoom(value: float) -> void:
    zoom = clampf(value, ZOOM_MIN, ZOOM_MAX)
    zoom_target = zoom
    apply_view_transform()
    _redraw_view_layers()

# Snaps a running animation to its target. The drag and the jump of the camera must not
# fight the animation: both write scroll_offset, and the loser would make the map twitch.
func finish_zoom() -> void:
    if is_equal_approx(zoom, zoom_target):
        return
    zoom = zoom_target
    _apply_zoom_view()
    _settle_zoom()
    _save_zoom_level()

# Advances the zoom animation. It lives in the input handler (handle_process), not in
# _process of the map: the latter is the simulation and stands still while the active
# pause is on, and the player must be able to zoom a paused map.
#
# A frame of the gesture does NOT redraw the map. The recorded draw commands are reused and
# only the transform of the renderer changes, so the cost of the animation is the same on a
# starting Region and on a fully revealed map.
func process_zoom(delta: float) -> void:
    if is_equal_approx(zoom, zoom_target):
        return
    zoom = lerpf(zoom, zoom_target, 1.0 - exp(-ZOOM_SMOOTHING * delta))
    if absf(zoom - zoom_target) < ZOOM_SETTLE_EPS:
        zoom = zoom_target
    _apply_zoom_view()
    if zoom == zoom_target:
        _settle_zoom()
        _save_zoom_level()

# Places the map on the screen for the current zoom without touching the drawing:
# `screen = position + local * zoom`, and the position is chosen so that the world point of
# the anchor lands exactly on the anchor.
#
# The shift is limited by the same scroll clamp the drag obeys: without it a gesture at the
# edge of the reachable area would carry the map beyond the boundary for the whole animation
# and snap it back at the end. Here the ANCHOR slides instead, exactly as it did when the
# clamp was applied to the scroll on every frame.
func _apply_zoom_view() -> void:
    if map_renderer == null:
        return
    map_renderer.scale = Vector2(zoom, zoom)
    map_renderer.position = _zoom_view_position(zoom)

# The position of the renderer for a zoom of the running gesture (see _apply_zoom_view).
# The scroll the gesture will settle on is clamped by the same limit the drag obeys: without
# it a gesture at the edge of the reachable area would carry the map beyond the boundary for
# the whole animation and snap it back at the end. Here the ANCHOR slides instead.
func _zoom_view_position(value: float) -> Vector2:
    var shift: Vector2 = _zoom_anchor - (_zoom_world + Vector2(offset_x, offset_y)
            + scroll_offset) * value
    var max_scroll = get_max_scroll()
    var settled: Vector2 = scroll_offset + shift / value
    var clamped := Vector2(
            clampf(settled.x, -max_scroll.x, max_scroll.x),
            clampf(settled.y, -max_scroll.y, max_scroll.y))
    return _view_position_for(clamped, value)

# Ends the gesture: the shift accumulated by the animation is folded into the scroll offset,
# so the map returns to its usual state. The drawing is in the world coordinates, therefore
# only the transform changes.
func _settle_zoom() -> void:
    if map_renderer == null:
        return
    scroll_offset = map_renderer.position / zoom - Vector2(offset_x, offset_y)
    var max_scroll = get_max_scroll()
    scroll_offset = Vector2(
            clampf(scroll_offset.x, -max_scroll.x, max_scroll.x),
            clampf(scroll_offset.y, -max_scroll.y, max_scroll.y))
    apply_view_transform()
    _redraw_view_layers()

# The rectangle in the WORLD coordinates that the screen shows now. During a zoom-out gesture
# it is merged with the endpoint of the animation: the layer of the progress bars is culled by
# this rectangle and must already cover the strip the transform is about to uncover.
func get_draw_screen_rect(viewport_size: Vector2) -> Rect2:
    var rect := Rect2(-map_renderer.position / zoom, viewport_size / zoom)
    if zoom_target < zoom:
        var end_position: Vector2 = _zoom_view_position(zoom_target)
        rect = rect.merge(Rect2(-end_position / zoom_target, viewport_size / zoom_target))
    return rect

# The map draws in the WORLD coordinates; the renderer applies the camera (the position and
# the zoom), so a screen point maps to the world as (pos - position) / zoom.
func screen_to_local(pos: Vector2) -> Vector2:
    if map_renderer == null:
        return pos / zoom
    return (pos - map_renderer.position) / zoom

# Redraws the layers that are drawn per frame or per interaction. The map itself is not
# touched: its drawing is in the world coordinates and covers the whole reachable area, so a
# change of the view only moves the transform of the renderer.
func _redraw_view_layers() -> void:
    if progress_bar_layer:
        progress_bar_layer.queue_redraw()
    if highlight_layer:
        highlight_layer.queue_redraw()

# The zoom is a view preference, not a part of the game state: it lives in settings.cfg
# next to the scroll speed. Written when a gesture settles, so a spin of the wheel does
# not rewrite the file on every frame.
func _save_zoom_level() -> void:
    var config := ConfigFile.new()
    config.load("user://settings.cfg")
    config.set_value("interface", "zoom", zoom)
    config.save("user://settings.cfg")

# The maximum distance of the scrolling of the map by the axes (in pixels). The SINGLE source of
# truth: the panning in InputHandler is limited by the same value, and
# as a consequence, the reachability of the hexes for the scouting (get_scout_reach_bounds).
#
# It is counted from the dimensions of the Region (the Ring + the Region), and not of the whole map: this
# limits the area visible by the scrolling to the nearest surroundings of the Region —
# a scout must reach there (including the fog of war and the territory of the
# towns near the Region), but the WHOLE map must NOT be available from
# the start. With the growth of the Region (a change of the era) the distance of the scrolling increases
# together with it.
func get_max_scroll() -> Vector2:
    return Vector2(
        float(region_end_col - region_start_col + 1) * HEX_RADIUS,
        float(region_end_row - region_start_row + 1) * HEX_RADIUS
    )

# Returns the inclusive hex-boundaries of the area which the player can see
# by the scrolling of the map: further the clamp of get_max_scroll() does not let. Beyond these
# boundaries there is neither the drawing of the fog, nor the possibility of a click. It is exactly this
# area by which the sending of the scouts is limited (including the territory of the towns
# and the hexes in the fog of war) — but ONLY after the learning of the Cartography: before it
# the scouting is limited by the Region (see get_region_bounds). The purchase of the chunks
# is still limited only by the Region (is_valid_hex).
func get_scout_reach_bounds() -> Dictionary:
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size
    var max_scroll = get_max_scroll()
    var x_spacing = HEX_RADIUS * sqrt(3.0)
    var y_spacing = HEX_RADIUS * 1.5
    # We unite the screen rectangle at both extreme positions
    # of the scrolling: world = -offset - scroll .. -offset - scroll + viewport.
    # The viewport is taken in LOCAL pixels: a zoom below 1 shows more of the world than
    # the window itself, and the hexes of that extra strip must stay drawable and
    # clickable, otherwise the zoomed-out map would end in a dead band. The widest zoom is
    # assumed: the drawing must cover every zoom the game allows, then no change of the
    # zoom ever has to re-record it.
    var visible_size: Vector2 = viewport_size / ZOOM_MIN
    var world_left = - (offset_x + max_scroll.x)
    var world_right = - offset_x + max_scroll.x + visible_size.x
    var world_top = - (offset_y + max_scroll.y)
    var world_bottom = - offset_y + max_scroll.y + visible_size.y
    # The margin of 2 hexes: the offset of the odd rows and the partially visible hexes
    # at the edges of the screen (otherwise the extreme reachable hexes would "fall out" of
    # the chunks of the scouting, although one can click on them).
    var margin = 2
    var col_start = int(floor(world_left / x_spacing)) - margin
    var col_end = int(ceil(world_right / x_spacing)) + margin
    var row_start = int(floor(world_top / y_spacing)) - margin
    var row_end = int(ceil(world_bottom / y_spacing)) + margin
    return {
        "row_start": max(row_start, 0),
        "row_end": min(row_end, map_rows - 1),
        "col_start": max(col_start, 0),
        "col_end": min(col_end, map_cols - 1)
    }

func _on_chunk_hovered(_chunk: Array):
    highlight_layer.queue_redraw()
