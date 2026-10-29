# ui_theme.gd
#
# The one place where the surface of the interface is built from the palette: panels,
# frames of the controls, rows, progress bars, tooltips. A screen calls these factories
# instead of writing a colour literal, otherwise it keeps its own colours after the
# player changes the theme.
#
# The fallback palette repeats theme/presets/classic.json. It is used when the autoloads
# are not in the tree (a headless --script run) and by tests that build a style without
# starting the game; tests/test_theme_manager.gd keeps the two in step.
class_name UiTheme
extends RefCounted

const FALLBACK := {
    "panel_bg": "#1C1C1CF5",
    "panel_border": "#737373",
    "control_bg": "#333338",
    "control_hover": "#4D4D57",
    "control_pressed": "#212126",
    "control_disabled": "#262626",
    "control_border": "#9E9EA8",
    "control_border_disabled": "#545454",
    "text": "#FFFFFF",
    "text_secondary": "#CCCCCC",
    "text_muted": "#A6A6A6",
    "info": "#73BFFF",
    "accent": "#C8C8C8",
    "accent_hover": "#DCDCDC",
    "accent_text": "#000000",
    "field_bg": "#26262A",
    "field_border": "#4D4D57",
    "focus_border": "#9E9EA8",
    "track": "#262626",
    "fill": "#4D7FBF",
    "tab_active_bg": "#2B2B2B",
    "tab_active_text": "#FFFFFF",
    "tooltip_bg": "#333333",
    "tooltip_border": "#999999",
    "scrollbar": "#4D4D4D",
    "scrollbar_hover": "#7A7A7A",
    "hairline": "#8C8C8C",
    "row_hover": "#3F3F3F",
    "row_selected": "#4D4D4D",
    "scrim": "#00000099",
    "row_dim": "#9E9E9E",
    "price": "#FF8100",
    "price_amount": "#FFFFFF",
    "quality": "#4DFFEA",
    "income": "#4DD94D",
    "expense": "#E64D4D",
    "warning": "#FFD933",
}

const FALLBACK_METRICS := {
    "panel_radius": 4,
    "control_radius": 3,
}

static func color(token: String) -> Color:
    var manager := _manager()
    if manager != null:
        return manager.color(token, _fallback_color(token))
    return _fallback_color(token)

static func metric(token: String) -> float:
    var manager := _manager()
    if manager != null:
        return manager.metric(token, float(FALLBACK_METRICS.get(token, 0.0)))
    return float(FALLBACK_METRICS.get(token, 0.0))

# A panel of a window or a tooltip surface: the border marks where the panel ends over
# the map, the margins keep the text off the frame.
static func panel() -> StyleBoxFlat:
    return _surface(color("panel_bg"), color("panel_border"), 1)

# A strip raised over the panel — a tab bar, a top bar. It uses the control colour, so a
# bar and the buttons on it read as one family.
static func panel_raised() -> StyleBoxFlat:
    return _surface(color("control_bg"), color("panel_border"), 1)

# A well cut into the panel: the frame of a list, a region that holds other surfaces.
static func panel_inset() -> StyleBoxFlat:
    return _surface(color("track"), color("panel_border"), 1)

# A plate over the map rather than over a window: the bars of the world screen let the
# terrain read through them, so the surface is the panel colour at a reduced alpha. The
# palette still decides the hue — a light theme gets a light veil, and the text on it stays
# the text colour of that palette.
static func panel_veil() -> StyleBoxFlat:
    var tint := color("panel_bg")
    tint.a = 0.72
    return _surface(tint, color("panel_border"), 1)

# The plate of a standalone window, with the heavier frame that marks it as a window
# rather than a panel of the screen behind it.
static func window_plate() -> StyleBoxFlat:
    return _surface(color("panel_bg"), color("panel_border"), 2)

# A surface that carries a warning, tinted with the expense colour so that a problem
# region is recognisable without reading its text.
static func problem() -> StyleBoxFlat:
    var tint := color("expense")
    return _surface(color("panel_bg").lerp(tint, 0.18), tint.darkened(0.35), 1)

static func _surface(bg: Color, border: Color, border_width: int) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.border_color = border
    style.set_border_width_all(border_width)
    style.set_corner_radius_all(int(metric("panel_radius")))
    style.content_margin_left = 8.0
    style.content_margin_right = 8.0
    style.content_margin_top = 6.0
    style.content_margin_bottom = 6.0
    return style

static func tooltip() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color("tooltip_bg")
    style.border_color = color("tooltip_border")
    style.set_border_width_all(1)
    style.content_margin_left = 6.0
    style.content_margin_right = 6.0
    style.content_margin_top = 4.0
    style.content_margin_bottom = 4.0
    return style

# One frame of a control. The state is passed by the caller, because Godot draws exactly
# one stylebox per state: a control needs one per state, not one shared.
static func control(bg: Color, border: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.border_color = border
    style.set_border_width_all(1)
    style.set_corner_radius_all(int(metric("control_radius")))
    style.content_margin_left = 4.0
    style.content_margin_right = 4.0
    style.content_margin_top = 4.0
    style.content_margin_bottom = 4.0
    return style

static func control_normal() -> StyleBoxFlat:
    return control(color("control_bg"), color("control_border"))

static func control_hover() -> StyleBoxFlat:
    return control(color("control_hover"), color("control_border"))

static func control_pressed() -> StyleBoxFlat:
    return control(color("control_pressed"), color("control_border"))

static func control_disabled() -> StyleBoxFlat:
    return control(color("control_disabled"), color("control_border_disabled"))

# A row of a list. The fill carries the state (plain, hovered, selected); the frame and
# the corners belong to the container around the rows.
static func row(bg: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.content_margin_left = 4.0
    style.content_margin_right = 4.0
    return style

# ProgressBar draws these two: "background" under the track and "fill" over it. The
# margins only size the control: the boxes themselves are drawn over the full rect.
static func bar_background() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color("track")
    style.set_corner_radius_all(3)
    set_content_margins(style, 2.0)
    return style

static func bar_fill() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color("fill")
    style.set_corner_radius_all(3)
    set_content_margins(style, 2.0)
    return style

# The same margin on all four sides of a box. The margins do not move the paint of a
# StyleBox; they only set the size the control asks the layout for.
static func set_content_margins(style: StyleBox, margin: float) -> void:
    style.content_margin_left = margin
    style.content_margin_right = margin
    style.content_margin_top = margin
    style.content_margin_bottom = margin

static func _manager() -> Node:
    var tree := Engine.get_main_loop() as SceneTree
    if tree == null or tree.root == null:
        return null
    return tree.root.get_node_or_null("ThemeManager")

static func _fallback_color(token: String) -> Color:
    return Color.html(str(FALLBACK.get(token, "#FFFFFF")))
