# unread_dot.gd
#
# The small blue dot on the journal button of the HUD: there is at least one unread
# message. The dot is drawn and not loaded from a file — a circle of a few pixels
# needs no asset, and it keeps its shape at any scale, exactly like the warning
# triangle of the town window (warning_badge.gd).
extends Control

const FILL_COLOR := Color(0.29, 0.62, 1.0, 1.0)
# A dark rim keeps the dot visible on the light "hovered" face of the button.
const RIM_COLOR := Color(0.07, 0.07, 0.07, 0.9)
const RIM_WIDTH := 1.0

func _ready() -> void:
    # The dot must not take the click of the button it sits on.
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    queue_redraw()

func _draw() -> void:
    var radius := minf(size.x, size.y) * 0.5
    if radius <= 0.0:
        return
    var center := size * 0.5
    draw_circle(center, radius, RIM_COLOR)
    draw_circle(center, radius - RIM_WIDTH, FILL_COLOR)
