# The map preview of a new game.
#
# The square IS the world: its AREA is proportional to the chosen map size against the
# largest allowed one, so a map twice as large reads as twice as much map. The side therefore
# follows the square root of that ratio. That is the whole point of the control — a number in
# a dropdown says nothing about how much map it is.
#
# The dots are a hex lattice and the bright points are the towns. Both are schematic: the
# lattice shows a few hexes per dot, and the towns are spread evenly rather than placed by
# the generator, which has not run yet. The gold point in the middle is the player's city —
# MainMap puts it at half the rows and half the columns, so that mark is exact. The numbers
# are printed under the square.
extends Control

const PANEL_COLOR := Color(0.12, 0.12, 0.12)
const PANEL_BORDER_COLOR := Color(0.28, 0.28, 0.28)
const FRAME_COLOR := Color(0.16, 0.16, 0.16)
const FRAME_BORDER_COLOR := Color(0.26, 0.26, 0.26)
const MAP_COLOR := Color(0.20, 0.20, 0.20)
const MAP_BORDER_COLOR := Color(0.32, 0.37, 0.41)
const LATTICE_COLOR := Color(0.33, 0.40, 0.45)
const TOWN_COLOR := Color(0.52, 0.72, 0.92)
const CITY_COLOR := Color(0.95, 0.78, 0.35)
const TITLE_COLOR := Color(0.90, 0.90, 0.90)
const CAPTION_COLOR := Color(0.62, 0.62, 0.62)

const PADDING := 14.0
const CAPTION_HEIGHT := 46.0
const MIN_SIDE := 30.0
const LATTICE_DOTS_ACROSS := 24.0
const TITLE_FONT_SIZE := 17
const CAPTION_FONT_SIZE := 12
const TOWN_RADIUS := 3.0
const CITY_RADIUS := 4.5
# The city keeps a ring of its own: the nearest town stands clear of it instead of touching
# the gold point, whatever the count.
const CITY_CLEAR := CITY_RADIUS + TOWN_RADIUS + 2.0
const GOLDEN_ANGLE := 2.399963229

# The largest map the preview can show. The game hands its own limit over, so the picture
# and the dropdown cannot drift apart.
var max_map_size := 200

var map_size := 60
var town_count := 16

var _panel := StyleBoxFlat.new()

func _init() -> void:
    _panel.bg_color = PANEL_COLOR
    _panel.border_color = PANEL_BORDER_COLOR
    _panel.set_border_width_all(1)
    _panel.set_corner_radius_all(6)

func set_world(size: int, towns: int) -> void:
    if size == map_size and towns == town_count:
        return
    map_size = size
    town_count = towns
    queue_redraw()

func _draw() -> void:
    draw_style_box(_panel, Rect2(Vector2.ZERO, size))

    var area := Rect2(PADDING, PADDING,
            size.x - PADDING * 2.0, size.y - PADDING * 2.0 - CAPTION_HEIGHT)
    if area.size.x <= 0.0 or area.size.y <= 0.0:
        return

    # The frame is the largest map the game can build. The chosen world sits inside it, so
    # the empty room around a small map is the measure of how much smaller it is.
    var frame := _square(area, max_map_size)
    draw_rect(frame, FRAME_COLOR)
    draw_rect(frame, FRAME_BORDER_COLOR, false, 1.0)

    var square := _square(area, map_size)
    draw_rect(square, MAP_COLOR)
    _draw_lattice(square)
    draw_rect(square, MAP_BORDER_COLOR, false, 1.0)
    _draw_towns(square)
    _draw_city(square)
    _draw_caption()

func _square(area: Rect2, side_in_hexes: int) -> Rect2:
    var full := minf(area.size.x, area.size.y)
    var side := maxf(full * sqrt(float(side_in_hexes) / float(max_map_size)), MIN_SIDE)
    return Rect2(area.position + (area.size - Vector2(side, side)) * 0.5, Vector2(side, side))

# The step follows the square: a small world would otherwise be a handful of lonely dots
# and a large one a solid block of colour.
func _draw_lattice(square: Rect2) -> void:
    var step := clampf(square.size.x / LATTICE_DOTS_ACROSS, 4.0, 10.0)
    var radius := clampf(step * 0.17, 0.7, 1.6)
    var row := 0
    var y := square.position.y + step * 0.5
    while y < square.end.y - radius:
        var x := square.position.x + step * (0.5 if row % 2 == 0 else 1.0)
        while x < square.end.x - radius:
            draw_circle(Vector2(x, y), radius, LATTICE_COLOR)
            x += step
        y += step * 0.866
        row += 1

# The towns are spread on a sunflower spiral: even density without a random seed, so the
# picture does not change while the player drags the number up and down. The spiral starts
# outside the city, which is why the middle of the map stays clear.
func _draw_towns(square: Rect2) -> void:
    if town_count <= 0:
        return
    var centre := square.get_center()
    var reach := maxf(square.size.x * 0.5 - TOWN_RADIUS * 2.0, CITY_CLEAR)
    var span := reach - CITY_CLEAR
    for index in town_count:
        var distance := CITY_CLEAR + sqrt((float(index) + 0.5) / float(town_count)) * span
        var angle := float(index) * GOLDEN_ANGLE
        draw_circle(centre + Vector2(cos(angle), sin(angle)) * distance, TOWN_RADIUS, TOWN_COLOR)

# The player's city stands in the middle of the map. A dark ring behind it keeps the gold
# readable on the lattice, and the towns around it stay blue.
func _draw_city(square: Rect2) -> void:
    var centre := square.get_center()
    draw_circle(centre, CITY_RADIUS + 1.5, Color(0.0, 0.0, 0.0, 0.5))
    draw_circle(centre, CITY_RADIUS, CITY_COLOR)

func _draw_caption() -> void:
    var font := get_theme_font("font", "Label")
    var top := size.y - CAPTION_HEIGHT
    var title_y := top + float(TITLE_FONT_SIZE) + 6.0
    draw_string(font, Vector2(0.0, title_y), "%d × %d" % [map_size, map_size],
            HORIZONTAL_ALIGNMENT_CENTER, size.x, TITLE_FONT_SIZE, TITLE_COLOR)
    var caption := tr("Hexes: %s · Towns: %d") % [_grouped(map_size * map_size), town_count]
    draw_string(font, Vector2(0.0, title_y + float(CAPTION_FONT_SIZE) + 7.0), caption,
            HORIZONTAL_ALIGNMENT_CENTER, size.x, CAPTION_FONT_SIZE, CAPTION_COLOR)

# A thin space between the thousands, so that a huge map does not read as one long number.
static func _grouped(value: int) -> String:
    var text := str(value)
    var result := ""
    var digits := 0
    for index in range(text.length() - 1, -1, -1):
        result = text[index] + result
        digits += 1
        if digits % 3 == 0 and index > 0:
            result = "\u00A0" + result
    return result
