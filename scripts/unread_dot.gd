# unread_dot.gd
#
# The small blue dot on the journal button of the HUD: there is at least one unread
# message. The dot is drawn and not loaded from a file — a circle of a few pixels
# needs no asset, and it keeps its shape at any scale, exactly like the warning
# triangle of the town window (warning_badge.gd).
extends Control

const UI_THEME = preload("res://scripts/ui_theme.gd")

const RIM_WIDTH := 1.0

static func fill_color() -> Color:
    return UI_THEME.color("info")

# A dark rim keeps the dot visible on the light "hovered" face of the button.
static func rim_color() -> Color:
    var rim := UI_THEME.color("panel_bg")
    rim.a = 0.9
    return rim

func _ready() -> void:
    # The dot must not take the click of the button it sits on.
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    queue_redraw()

func _draw() -> void:
    var radius := minf(size.x, size.y) * 0.5
    if radius <= 0.0:
        return
    var center := size * 0.5
    draw_circle(center, radius, rim_color())
    draw_circle(center, radius - RIM_WIDTH, fill_color())
