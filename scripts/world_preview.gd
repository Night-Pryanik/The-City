# The map preview of a new game.
#
# The square IS the world: its AREA is proportional to the chosen map size against the
# largest allowed one, so a map twice as large reads as twice as much map. The side therefore
# follows the square root of that ratio. That is the whole point of the control — a number in
# a dropdown says nothing about how much map it is.
#
# Inside the square is the water the settings describe, drawn by the generator itself rather
# than by a second, hand-written rule: SeaManager builds the sea mask on the real map grid, and
# the mask is averaged down to the cells of the picture.
#
# It is a SAMPLE of the settings and never the world the player is about to get. The caller
# picks the seed, so the same settings keep the same coast until the player rerolls the preview;
# the world generation rolls its own dice. The real world is kept out of here on purpose: a
# player who saw it would plan the first moves from the menu — "there is a town west of my start,
# I will grow that way" — and the map would be explored before it is built.
#
# The towns are schematic — a sunflower spiral rather than the placement of the generator —
# and a town stands only where there is land. The gold point in the middle is the player's
# city: MainMap puts it at half the rows and half the columns, so that mark is exact. The
# numbers are printed under the square.
extends Control

const PANEL_COLOR := Color(0.12, 0.12, 0.12)
const PANEL_BORDER_COLOR := Color(0.28, 0.28, 0.28)
const FRAME_COLOR := Color(0.16, 0.16, 0.16)
const FRAME_BORDER_COLOR := Color(0.26, 0.26, 0.26)
const MAP_BORDER_COLOR := Color(0.32, 0.37, 0.41)
const LAND_COLOR := Color(0.30, 0.33, 0.29)
const DEEP_SEA_COLOR := Color(0.10, 0.20, 0.32)
const SHALLOW_SEA_COLOR := Color(0.18, 0.36, 0.50)
const BEACH_COLOR := Color(0.60, 0.54, 0.38)
const TOWN_COLOR := Color(0.92, 0.92, 0.90)
const CITY_COLOR := Color(0.95, 0.78, 0.35)
const TITLE_COLOR := Color(0.90, 0.90, 0.90)
const CAPTION_COLOR := Color(0.62, 0.62, 0.62)

# The kinds of a cell of the picture. The codes are what build() puts into the byte array and
# what the palette above turns into colours.
const CELL_LAND := 0
const CELL_DEEP_SEA := 1
const CELL_SHALLOW_SEA := 2
const CELL_BEACH := 3

const PADDING := 14.0
const CAPTION_HEIGHT := 64.0
const MIN_SIDE := 30.0
const TITLE_FONT_SIZE := 17
const CAPTION_FONT_SIZE := 12
const TOWN_RADIUS := 3.0
const CITY_RADIUS := 4.5
# The city keeps a ring of its own: the nearest town stands clear of it instead of touching
# the gold point, whatever the count.
const CITY_CLEAR := CITY_RADIUS + TOWN_RADIUS + 2.0
const GOLDEN_ANGLE := 2.399963229

# The picture is drawn on a grid of its own: one cell of the picture is a block of hexes of
# the world. Beyond this many cells a cell of the picture is thinner than the pixel it lands
# on, so a finer grid would cost time and show nothing.
const GRID_MAX := 120

# The largest map the preview can show. The game hands its own limit over, so the picture
# and the dropdown cannot drift apart.
var max_map_size := 200

var map_size := 60
var town_count := 16

var _picture: Dictionary = {}
var _texture: ImageTexture = null
var _panel := StyleBoxFlat.new()

func _init() -> void:
    _panel.bg_color = PANEL_COLOR
    _panel.border_color = PANEL_BORDER_COLOR
    _panel.set_border_width_all(1)
    _panel.set_corner_radius_all(6)
    # The picture is a grid of cells of the world, not a photograph: a smoothed cell would
    # blur the coast into a gradient and the bays would be lost.
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

# The water of the world the settings describe, on a grid of the preview.
#
# The mask is built by the generator itself, so every setting that moves the coast in the game
# moves it here as well. A cell of the picture takes the kind of the majority of the hexes it
# covers; the shallow band and the beach are worked out on that grid, because at this size
# they are one or two cells wide whatever their depth in hexes.
static func build(size: int, sea: Dictionary, preview_seed: int = 20261026) -> Dictionary:
    var grid := mini(maxi(size, 1), GRID_MAX)
    var city := int(size / 2.0)

    # The generator draws the coasts at random. The seed is pinned for the build and the global
    # generator is randomized again right after it: the same settings always draw the same
    # picture, and the world the player gets is a different roll of the same dice. Nothing may
    # depend on the state the preview leaves — the world generation reseeds the generator before
    # it starts anyway, and that is the second of the two guards against handing over the map.
    seed(preview_seed)
    var mask: Array = SeaManager.build_sea_mask(size, size, city, city, sea)
    SeaManager.grow_sea_islands(mask, size, size, city, city, sea, false)
    randomize()

    var water := PackedByteArray()
    water.resize(grid * grid)
    var sea_cells := 0
    for cell_y in range(grid):
        var row_from := int(float(cell_y) * float(size) / float(grid))
        var row_to := maxi(row_from + 1, int(float(cell_y + 1) * float(size) / float(grid)))
        for cell_x in range(grid):
            var col_from := int(float(cell_x) * float(size) / float(grid))
            var col_to := maxi(col_from + 1, int(float(cell_x + 1) * float(size) / float(grid)))
            var wet := 0
            var total := 0
            for row in range(row_from, row_to):
                for col in range(col_from, col_to):
                    total += 1
                    if mask[row][col]:
                        wet += 1
            sea_cells += wet
            if wet * 2 >= total:
                water[cell_y * grid + cell_x] = 1

    var depths := _coast_depths(water, grid, size, sea)
    var beach: bool = bool(sea.get("beach", true))
    var cells := PackedByteArray()
    cells.resize(grid * grid)
    for index in range(grid * grid):
        if water[index] == 1:
            cells[index] = CELL_SHALLOW_SEA if depths[index] > 0 else CELL_DEEP_SEA
        elif beach and _touches(water, grid, index, 1):
            cells[index] = CELL_BEACH
        else:
            cells[index] = CELL_LAND

    return {
        "grid": grid,
        "cells": cells,
        "sea_share": float(sea_cells) / float(maxi(size * size, 1)),
    }

# How far every water cell of the picture lies from the coast, in cells, up to the depth the
# shallow band reaches. The band is set in hexes, so it is scaled to the grid: the shallows of
# a 200×200 world are thinner than one cell of its picture, and the picture shows them one
# cell wide instead of not at all.
static func _coast_depths(water: PackedByteArray, grid: int, size: int,
        sea: Dictionary) -> PackedByteArray:
    var depths := PackedByteArray()
    depths.resize(grid * grid)
    var depth_limit := clampi(roundi(float(sea.get("coast_max_depth", 3))
            * float(grid) / float(maxi(size, 1))), 1, grid)
    var queue := PackedInt32Array()
    for index in range(grid * grid):
        if water[index] == 0 or not _touches(water, grid, index, 0):
            continue
        depths[index] = 1
        queue.append(index)
    var head := 0
    while head < queue.size():
        var index := queue[head]
        head += 1
        if depths[index] >= depth_limit:
            continue
        for neighbour in _neighbours(grid, index):
            if water[neighbour] == 0 or depths[neighbour] > 0:
                continue
            depths[neighbour] = depths[index] + 1
            queue.append(neighbour)
    return depths

# The four cells around a cell of the picture. The picture is a square grid of blocks of
# hexes, so the sides of a block are what a neighbour means here.
static func _neighbours(grid: int, index: int) -> PackedInt32Array:
    var result := PackedInt32Array()
    var x := index % grid
    var y := int(float(index) / float(grid))
    if x > 0:
        result.append(index - 1)
    if x < grid - 1:
        result.append(index + 1)
    if y > 0:
        result.append(index - grid)
    if y < grid - 1:
        result.append(index + grid)
    return result

# Whether a cell of the picture has a neighbour of the given kind (0 — land, 1 — water). The
# beach and the shallow band are both a rim along the coast, so both ask this question: the
# beach about the water next to the land, the shallows about the land next to the water.
static func _touches(water: PackedByteArray, grid: int, index: int, kind: int) -> bool:
    for neighbour in _neighbours(grid, index):
        if water[neighbour] == kind:
            return true
    return false

func set_world(size: int, towns: int, picture: Dictionary) -> void:
    map_size = size
    town_count = towns
    _picture = picture
    _texture = _make_texture(picture)
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
    draw_rect(square, LAND_COLOR)
    if _texture != null:
        draw_texture_rect(_texture, square, false)
    draw_rect(square, MAP_BORDER_COLOR, false, 1.0)
    _draw_towns(square)
    _draw_city(square)
    _draw_caption()

func _square(area: Rect2, side_in_hexes: int) -> Rect2:
    var full := minf(area.size.x, area.size.y)
    var side := maxf(full * sqrt(float(side_in_hexes) / float(max_map_size)), MIN_SIDE)
    return Rect2(area.position + (area.size - Vector2(side, side)) * 0.5, Vector2(side, side))

# The towns are spread on a sunflower spiral: even density without a random seed, so the
# picture does not change while the player drags the number up and down. The spiral starts
# outside the city, which is why the middle of the map stays clear. A town stands on land, so
# a point that falls into the sea is not drawn — the sea takes the room the town would need.
func _draw_towns(square: Rect2) -> void:
    if town_count <= 0:
        return
    var centre := square.get_center()
    var reach := maxf(square.size.x * 0.5 - TOWN_RADIUS * 2.0, CITY_CLEAR)
    var span := reach - CITY_CLEAR
    for index in town_count:
        var distance := CITY_CLEAR + sqrt((float(index) + 0.5) / float(town_count)) * span
        var angle := float(index) * GOLDEN_ANGLE
        var point := centre + Vector2(cos(angle), sin(angle)) * distance
        if not _is_land(square, point):
            continue
        draw_circle(point, TOWN_RADIUS, TOWN_COLOR)

# Whether a point of the square stands on land. The picture is a grid of blocks of the world,
# so the answer is the kind of the block the point falls into.
func _is_land(square: Rect2, point: Vector2) -> bool:
    var grid: int = _picture.get("grid", 0)
    if grid <= 0 or square.size.x <= 0.0 or square.size.y <= 0.0:
        return true
    var x := int((point.x - square.position.x) / square.size.x * float(grid))
    var y := int((point.y - square.position.y) / square.size.y * float(grid))
    if x < 0 or y < 0 or x >= grid or y >= grid:
        return false
    var code: int = _picture["cells"][y * grid + x]
    return code == CELL_LAND or code == CELL_BEACH

# The player's city stands in the middle of the map. A dark ring behind it keeps the gold
# readable on the water, and the towns around it stay pale.
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
    draw_string(font, Vector2(0.0, title_y + float(CAPTION_FONT_SIZE) * 2.0 + 13.0),
            _sea_caption(), HORIZONTAL_ALIGNMENT_CENTER, size.x, CAPTION_FONT_SIZE,
            CAPTION_COLOR)

# The share of the map the water takes: the one number that says what the sea settings do to
# the world before the world is built.
func _sea_caption() -> String:
    var share: float = _picture.get("sea_share", 0.0)
    if share <= 0.0:
        return tr("No sea")
    # A sea thinner than half a percent still takes room on the picture: the number must not
    # read 0 while there is water.
    return tr("Sea: %d%%") % maxi(1, roundi(share * 100.0))

func _make_texture(picture: Dictionary) -> ImageTexture:
    var grid: int = picture.get("grid", 0)
    var cells: PackedByteArray = picture.get("cells", PackedByteArray())
    if grid <= 0 or cells.size() != grid * grid:
        return null
    var rgb := PackedByteArray()
    rgb.resize(grid * grid * 3)
    for index in range(cells.size()):
        var color := _cell_color(cells[index])
        rgb[index * 3] = int(color.r * 255.0)
        rgb[index * 3 + 1] = int(color.g * 255.0)
        rgb[index * 3 + 2] = int(color.b * 255.0)
    return ImageTexture.create_from_image(
            Image.create_from_data(grid, grid, false, Image.FORMAT_RGB8, rgb))

static func _cell_color(code: int) -> Color:
    match code:
        CELL_DEEP_SEA:
            return DEEP_SEA_COLOR
        CELL_SHALLOW_SEA:
            return SHALLOW_SEA_COLOR
        CELL_BEACH:
            return BEACH_COLOR
    return LAND_COLOR

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
