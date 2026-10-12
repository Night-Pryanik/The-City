# warning_badge.gd
# The red "!" triangle — the marker that an entered amount is larger than the
# throughput of the route between the town and the city.
#
# It repeats the triangle the map draws over an over-producing improvement
# (map_renderer._draw_warning_triangle): the same warning reads the same way in the
# town window and on the map. A Control (and not a Node2D), so that it can sit in a
# row of the town window; the tooltip carries the numbers of the shortfall.
#
# The badge is drawn with the engine fallback font and no external assets, exactly
# like the map triangle, so it needs neither a texture nor a font in the project.
extends Control

const TRI_SIZE := 18.0
const FILL_COLOR := Color(0.85, 0.15, 0.15, 0.95)

func _init() -> void:
    custom_minimum_size = Vector2(TRI_SIZE, TRI_SIZE)
    # The tooltip of a Control shows only when the control catches the mouse.
    mouse_filter = Control.MOUSE_FILTER_STOP

func _draw() -> void:
    var center := size * 0.5
    var half := minf(size.x, size.y) * 0.5
    if half <= 0.0:
        return
    # An equilateral triangle pointing up, inscribed in the control.
    var points := PackedVector2Array([
        center + Vector2(0.0, -half * 0.85),
        center + Vector2(-half * 0.9, half * 0.7),
        center + Vector2(half * 0.9, half * 0.7),
    ])
    draw_colored_polygon(points, FILL_COLOR)
    var border := PackedVector2Array(points)
    border.append(points[0])
    draw_polyline(border, Color.WHITE, 1.5, true)
    var font := ThemeDB.fallback_font
    if font == null:
        return
    var font_size := int(round(half * 1.4))
    var text := "!"
    var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
    var text_pos := Vector2(center.x - text_size.x * 0.5, center.y + text_size.y * 0.5 - 1.0)
    draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)
