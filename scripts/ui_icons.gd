# ui_icons.gd
#
# The few glyphs of the interface that the engine draws as textures rather than as
# styleboxes: the box of a checkbox, the switch of a check button, the knob of a slider.
# A texture cannot follow a palette on its own, so the shapes are rasterised from the
# palette every time one is applied.
#
# The engine's own glyphs are drawn in near-white, which disappears on a light theme, and
# the one SVG the project shipped was tuned for the old grey.
#
# The sizes match the engine defaults exactly (16×16, and 32×16 for the switch), so no
# control changes its minimum size when the icons are replaced.
class_name UiIcons
extends RefCounted

const BOX_SIZE := Vector2i(16, 16)
const SWITCH_SIZE := Vector2i(32, 16)

# Supersamples per edge of a pixel: a shape is either inside a sample or outside it, and
# the fraction of the samples inside is the coverage, which is what smooths the edge.
const SS := 4

# The square a checkbox marks. Empty it is the control surface with its frame; checked,
# the accent tick sits on the same surface, so the glyph reads the same on any background.
static func checkbox(checked: bool) -> ImageTexture:
    var layers: Array = [
        {"color": UiTheme.color("control_bg"), "sd": _rounded_rect(Vector2(8, 8), Vector2(6.5, 6.5), 2.5), "w": -1.0},
        {"color": UiTheme.color("control_border"), "sd": _rounded_rect(Vector2(8, 8), Vector2(6.5, 6.5), 2.5), "w": 1.5},
    ]
    if checked:
        layers.append({"color": UiTheme.color("accent"),
            "sd": _polyline([Vector2(4.2, 8.4), Vector2(7.0, 11.0), Vector2(12.0, 5.4)]), "w": 2.0})
    return _render(BOX_SIZE, layers)

# The round mark of a radio button: the surface and the frame of the checkbox, and the accent
# dot instead of the tick. A CheckBox inside a ButtonGroup draws exactly these glyphs, so the
# two have to agree in size and framing.
static func radio(checked: bool, muted: bool = false) -> ImageTexture:
    var frame := UiTheme.color("text_muted") if muted else UiTheme.color("control_border")
    var layers: Array = [
        {"color": UiTheme.color("control_bg"), "sd": _disc(Vector2(8, 8), 6.5), "w": -1.0},
        {"color": frame, "sd": _disc(Vector2(8, 8), 6.5), "w": 1.5},
    ]
    if checked:
        var dot := UiTheme.color("text_muted") if muted else UiTheme.color("accent")
        layers.append({"color": dot, "sd": _disc(Vector2(8, 8), 3.6), "w": -1.0})
    return _render(BOX_SIZE, layers)

# The switch of a check button: the knob moves across the track and both change role, so
# the on state is legible without reading its colour against the surface behind it.
static func switch_button(on: bool) -> ImageTexture:
    var track := UiTheme.color("track") if not on else UiTheme.color("fill")
    var knob := UiTheme.color("text_secondary") if not on else UiTheme.color("text")
    var centre_x := 8.0 if not on else 24.0
    var layers: Array = [
        {"color": track, "sd": _rounded_rect(Vector2(16, 8), Vector2(15.5, 7.5), 7.5), "w": -1.0},
        {"color": knob, "sd": _disc(Vector2(centre_x, 8), 5.5), "w": -1.0},
    ]
    return _render(SWITCH_SIZE, layers)

# The round handle of a slider, drawn in one flat colour.
static func knob(tint: Color) -> ImageTexture:
    var layers: Array = [
        {"color": tint, "sd": _disc(Vector2(8, 8), 5.5), "w": -1.0},
    ]
    return _render(BOX_SIZE, layers)

# --- the rasteriser ---

# A layer is {color, sd, w}: `sd` maps a point to its signed distance to the shape, and
# a negative `w` asks for the whole interior while a positive one asks for a band of that
# width drawn along the outline.
static func _render(size: Vector2i, layers: Array) -> ImageTexture:
    var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
    for y in range(size.y):
        for x in range(size.x):
            var out := Color(0, 0, 0, 0)
            for layer in layers:
                var covered := _coverage(x, y, layer["sd"], layer["w"])
                if covered <= 0.0:
                    continue
                out = _over(out, _faded(layer["color"], covered))
            image.set_pixel(x, y, out)
    return ImageTexture.create_from_image(image)

static func _coverage(px: int, py: int, sd: Callable, width: float) -> float:
    var inside := 0
    for sy in range(SS):
        for sx in range(SS):
            var p := Vector2(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS)
            var d: float = sd.call(p)
            var hit := d <= 0.0 if width < 0.0 else absf(d) <= width * 0.5
            if hit:
                inside += 1
    return float(inside) / float(SS * SS)

# Straight-alpha source over straight-alpha destination.
static func _over(dst: Color, src: Color) -> Color:
    var a := src.a + dst.a * (1.0 - src.a)
    if a <= 0.0:
        return Color(0, 0, 0, 0)
    var behind := 1.0 - src.a
    return Color(
        (src.r * src.a + dst.r * dst.a * behind) / a,
        (src.g * src.a + dst.g * dst.a * behind) / a,
        (src.b * src.a + dst.b * dst.a * behind) / a, a)

static func _faded(tint: Color, covered: float) -> Color:
    var c := tint
    c.a = tint.a * covered
    return c

# --- the shapes, as signed distance fields in icon pixels ---

static func _rounded_rect(centre: Vector2, half: Vector2, radius: float) -> Callable:
    return func(p: Vector2) -> float:
        var q := (p - centre).abs() - half + Vector2(radius, radius)
        return minf(maxf(q.x, q.y), 0.0) + q.max(Vector2.ZERO).length() - radius

static func _disc(centre: Vector2, radius: float) -> Callable:
    return func(p: Vector2) -> float:
        return (p - centre).length() - radius

static func _polyline(points: PackedVector2Array) -> Callable:
    return func(p: Vector2) -> float:
        var nearest := INF
        for i in range(points.size() - 1):
            nearest = minf(nearest, _distance_to_segment(p, points[i], points[i + 1]))
        return nearest

static func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
    var span := b - a
    var length_sq := span.length_squared()
    if length_sq <= 0.0001:
        return (p - a).length()
    var t := clampf((p - a).dot(span) / length_sq, 0.0, 1.0)
    return (p - (a + span * t)).length()
