# underlined_label.gd
# A Label with an underlined part of the text (for example, a product group name).
# It is used in ui_helpers.make_resource_entry() so that group rows look
# like clickable links, although in fact they only show a tooltip
# of the group contents with them. A group is NOT a real link and leads nowhere.
class_name UnderlinedLabel
extends Label

# The part of the text to be underlined (the rest of the line — in the normal typeface).
var underline_text: String = "":
    set(value):
        underline_text = value
        queue_redraw()

func _draw() -> void:
    if underline_text.is_empty():
        return
    var f: Font = get_theme_font("font")
    if f == null:
        return
    var fs: int = get_theme_font_size("font_size")
    var width: float = f.get_string_size(
        underline_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
    if width <= 0.0:
        return
    # The line runs along the lower bound of the main typeface of the font
    # (the upper bound of the descent — descent), below the text.
    var y: float = get_size().y - f.get_descent(fs)
    var line_color := get_theme_color("font_color")
    line_color.a = 0.75
    # A dashed line: a dash and a space of 2 px each (dash=2). The aligned=true
    # parameter aligns the phase so that the line starts with a dash (and not with a space).
    draw_dashed_line(Vector2(0.0, y + 2), Vector2(width, y + 2), line_color, 1.0, 2.0, true, true)