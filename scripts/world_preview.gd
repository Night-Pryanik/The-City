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
# The rivers are schematic: the generator needs the mountains, the lakes and the terrain, and
# the picture has none of them. So a river starts at a random inland cell and runs downhill to
# the coast of the sea the picture shows. Only the main rivers are drawn, in the number the
# player chose, and a path never leaves the land — a river mouths at the shore and does not
# cross the water, and no two rivers cross each other.
#
# It is a SAMPLE of the settings and never the world the player is about to get. The caller
# picks the seed, so the same settings keep the same coast until the player rerolls the preview;
# the world generation rolls its own dice. The real world is kept out of here on purpose: a
# player who saw it would plan the first moves from the menu — "there is a town west of my start,
# I will grow that way" — and the map would be explored before it is built.
#
# The towns are schematic — a sunflower spiral rather than the placement of the generator —
# and a town stands only on land reachable from the city: one that would fall into the sea or
# on an island moves to the nearest free cell of that land, so the picture keeps the count of
# the setting. The gold point in the middle is the player's city: MainMap puts it at half the
# rows and half the columns, so that mark is exact. The numbers are printed under the square.
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
const RIVER_COLOR := Color(0.36, 0.62, 0.90)
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
# The river line keeps a visible width on a small map and a proportional one on a large map.
const RIVER_WIDTH_RATIO := 0.009
const RIVER_MIN_WIDTH := 1.5
# Town dots keep a gap, so a town moved off the sea does not land on one already drawn.
const MIN_TOWN_GAP := 7.0
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

# The world the settings describe, on a grid of the preview: the sea and the main rivers.
#
# The sea mask is built by the generator itself, so every setting that moves the coast in the
# game moves it here as well. A cell of the picture takes the kind of the majority of the hexes
# it covers; the shallow band and the beach are worked out on that grid, because at this size
# they are one or two cells wide whatever their depth in hexes.
#
# The rivers are generated on that same grid (see _build_rivers), so a river can only run
# through the cells the picture draws as land: it never crosses the sea it is drawn on, and it
# never crosses a river already drawn.
static func build(size: int, sea: Dictionary, preview_seed: int = 20261026,
        rivers: Dictionary = {}) -> Dictionary:
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

    # The city sits at the same row and column, so one number names its cell.
    var city_cell := clampi(int(float(city) * float(grid) / float(size)), 0, grid - 1)
    return {
        "grid": grid,
        "cells": cells,
        "reachable": _reachable_cells(cells, grid, city_cell * grid + city_cell),
        "sea_share": float(sea_cells) / float(maxi(size * size, 1)),
        "rivers": _build_rivers(grid, water, size, rivers, preview_seed),
    }

# The land a town can stand on: the cells of the picture connected to the cell of the city over
# land. The world places a town only where it can reach the player's city by land, so an island
# carries no town on the picture either.
static func _reachable_cells(cells: PackedByteArray, grid: int, city_cell: int) -> PackedByteArray:
    var reachable := PackedByteArray()
    reachable.resize(grid * grid)
    var start := _nearest_land_cell(cells, grid, city_cell)
    if start < 0:
        return reachable
    reachable[start] = 1
    var queue := PackedInt32Array([start])
    var head := 0
    while head < queue.size():
        var index := queue[head]
        head += 1
        for neighbour in _neighbours(grid, index):
            if reachable[neighbour] == 1 or not _is_land_cell(cells, neighbour):
                continue
            reachable[neighbour] = 1
            queue.append(neighbour)
    return reachable

# The land cell closest to the city over the picture. The city is drawn in the middle, but on a
# small map the sea can reach its cell, and the towns still belong to the shore it stands on.
static func _nearest_land_cell(cells: PackedByteArray, grid: int, from: int) -> int:
    var seen := PackedByteArray()
    seen.resize(cells.size())
    seen[from] = 1
    var queue := PackedInt32Array([from])
    var head := 0
    while head < queue.size():
        var index := queue[head]
        head += 1
        if _is_land_cell(cells, index):
            return index
        for neighbour in _neighbours(grid, index):
            if seen[neighbour] == 1:
                continue
            seen[neighbour] = 1
            queue.append(neighbour)
    return -1

static func _is_land_cell(cells: PackedByteArray, index: int) -> bool:
    return cells[index] == CELL_LAND or cells[index] == CELL_BEACH

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

# The schematic main rivers, one path per river in the chosen count. A river starts on land
# that lies far enough from the water to be as long as the setting asks and flows to the coast:
# the path is the cheapest way there, and the cost rises over the high ground the noise
# describes. A straight shortest path would read as a drawn line rather than a river, so the
# noise is what makes the route wander.
#
# The drawn rivers are recorded in a map of the cells they cover, and a later river keeps clear
# of it: no two rivers cross and no two mouths meet. A source whose course cannot stay clear is
# skipped, so a crowded map can end up with fewer rivers than asked.
#
# Only the main rivers are drawn: the tributaries depend on the main rivers and on the terrain
# the picture does not have, and the count of the setting that matters on the picture is the
# count of the rivers the player will look for.
static func _build_rivers(grid: int, water: PackedByteArray, size: int,
        cfg: Dictionary, seed_value: int) -> Array:
    var count := maxi(0, int(cfg.get("num_main_rivers", 3)))
    if count == 0 or grid <= 0 or water.size() != grid * grid:
        return []

    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value

    var distances := _water_distances(grid, water)
    var weights := _river_weights(grid, water, seed_value)
    # The setting counts hexes, the path counts cells of the picture: on a large map one cell
    # covers several hexes, so the same river is fewer cells long.
    var min_cells := maxi(2, ceili(float(maxi(1, int(cfg.get("min_river_length", 8))))
            * float(grid) / float(maxi(size, 1))))

    # A source at least min_cells from the water gives a river of that length or longer. When
    # the map has no such source — a narrow strip of land, a long minimum — the shore cells
    # themselves are still tried, and the rivers come out shorter than asked.
    var sources := PackedInt32Array()
    var any_sources := PackedInt32Array()
    for index in range(grid * grid):
        if water[index] == 1 or distances[index] < 2:
            continue
        any_sources.append(index)
        if distances[index] >= min_cells:
            sources.append(index)
    if sources.is_empty():
        sources = any_sources
    if sources.is_empty():
        return []

    var blocked := PackedByteArray()
    blocked.resize(grid * grid)
    var mouths := PackedByteArray()
    mouths.resize(grid * grid)
    var origins: Array[int] = []
    # Sources keep their distance from each other, so the rivers spread over the map instead of
    # gathering in one bay.
    var separation := maxi(1, roundi(float(grid) / 6.0))

    var result: Array = []
    # The rivers already drawn, each with its segments bucketed: an attempt compares its curve
    # with them, and the buckets are the same for every attempt.
    var drawn: Array = []
    for _i in range(count):
        var river := _next_river(grid, water, distances, weights, blocked, mouths, drawn,
                sources, origins, separation, seed_value, rng)
        if river.is_empty():
            break
        var path: PackedInt32Array = river["path"]
        origins.append(path[0])
        _ink_river(grid, blocked, mouths, water, river["points"], path)
        result.append(river["points"])
        drawn.append({"points": river["points"],
                "buckets": _segment_buckets(grid, river["points"])})
    return result

# One main river: a free source and the cheapest course to a free coast cell that stays clear
# of the rivers already drawn. Sources away from the ones taken are tried first; a source whose
# course cannot avoid the others is skipped and another one is tried.
static func _next_river(grid: int, water: PackedByteArray, distances: PackedInt32Array,
        weights: PackedFloat32Array, blocked: PackedByteArray, mouths: PackedByteArray,
        drawn: Array, sources: PackedInt32Array, origins: Array[int], separation: int,
        seed_value: int, rng: RandomNumberGenerator) -> Dictionary:
    for attempt in range(80):
        var source: int = sources[rng.randi() % sources.size()]
        if blocked[source] == 1:
            continue
        if attempt < 40 and _near_origin(source, origins, grid, separation):
            continue
        var path := _river_path(grid, water, distances, weights, blocked, mouths, source)
        if path.is_empty():
            continue
        var points := _river_points(grid, water, distances, path, seed_value, blocked, mouths,
                drawn)
        if points.is_empty():
            continue
        return {"path": path, "points": points}
    return {}

# Records a drawn river: the cells its line covers are blocked, and the water cell at its mouth
# is claimed, so no later river runs over it or mouths into the same spot.
static func _ink_river(grid: int, blocked: PackedByteArray, mouths: PackedByteArray,
        water: PackedByteArray, points: PackedVector2Array, path: PackedInt32Array) -> void:
    for index in range(points.size() - 1):
        var steps := maxi(1, ceili(points[index].distance_to(points[index + 1]) * 4.0))
        for step in range(steps + 1):
            var point := points[index].lerp(points[index + 1], float(step) / float(steps))
            blocked[clampi(int(floor(point.y)), 0, grid - 1) * grid
                    + clampi(int(floor(point.x)), 0, grid - 1)] = 1
    for neighbour in _neighbours(grid, path[path.size() - 1]):
        if water[neighbour] == 1:
            mouths[neighbour] = 1
            break

# The distance in cells from every cell of the picture to the nearest water cell, -1 beyond
# the last one. The water is the goal, so the land next to it is 1 and every step inland adds 1.
static func _water_distances(grid: int, water: PackedByteArray) -> PackedInt32Array:
    var distances := PackedInt32Array()
    distances.resize(grid * grid)
    distances.fill(-1)
    var queue := PackedInt32Array()
    for index in range(grid * grid):
        if water[index] == 1:
            distances[index] = 0
            queue.append(index)
    var head := 0
    while head < queue.size():
        var index := queue[head]
        head += 1
        var next := distances[index] + 1
        for neighbour in _neighbours(grid, index):
            if distances[neighbour] >= 0:
                continue
            distances[neighbour] = next
            queue.append(neighbour)
    return distances

static func _near_origin(source: int, origins: Array[int], grid: int,
        separation: int) -> bool:
    var source_row := int(float(source) / float(grid))
    var source_col := source % grid
    for origin in origins:
        if absi(source_col - origin % grid) <= separation \
                and absi(source_row - int(float(origin) / float(grid))) <= separation:
            return true
    return false

# The cost of a cell in the river search. The noise is smooth rather than independent per cell:
# independent values only jitter the path, while ridges several cells wide make the cheapest way
# bend around them and the river gets a course instead of a straight line. The noise depends on
# the preview seed, so the same picture keeps the same rivers.
static func _river_weights(grid: int, water: PackedByteArray,
        seed_value: int) -> PackedFloat32Array:
    var noise := FastNoiseLite.new()
    noise.seed = seed_value
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    noise.frequency = 4.0 / float(maxi(grid, 1))
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = 2

    var weights := PackedFloat32Array()
    weights.resize(grid * grid)
    for index in range(grid * grid):
        if water[index] == 1:
            continue
        var row := index / grid
        var col := index % grid
        var value := (noise.get_noise_2d(float(col), float(row)) + 1.0) * 0.5
        weights[index] = 1.0 + 7.0 * value
    return weights

# The cheapest way from the source to a free coast cell. The cells of the rivers already drawn
# are walls, like the water, so a new river goes around them and finds another mouth — main
# rivers do not meet. A coast cell is a goal only while one of its water neighbours has no river
# mouthing into it. The distance field is a lower bound on the length of the path, so a source
# taken far enough from the water gives a river of at least that length.
static func _river_path(grid: int, water: PackedByteArray, distances: PackedInt32Array,
        weights: PackedFloat32Array, blocked: PackedByteArray, mouths: PackedByteArray,
        source: int) -> PackedInt32Array:
    var cell_count := grid * grid
    var best := PackedFloat32Array()
    best.resize(cell_count)
    best.fill(INF)
    var came_from := PackedInt32Array()
    came_from.resize(cell_count)
    came_from.fill(-1)
    best[source] = 0.0
    came_from[source] = source

    var settled := PackedByteArray()
    settled.resize(cell_count)
    var heap_cells: Array = [source]
    var heap_costs: Array = [0.0]
    var goal := -1
    while not heap_cells.is_empty():
        var index: int = _heap_pop(heap_cells, heap_costs)
        if settled[index] == 1:
            continue
        settled[index] = 1
        if distances[index] == 1 and _free_mouth(grid, index, mouths, water):
            goal = index
            break
        for neighbour in _neighbours(grid, index):
            if water[neighbour] == 1 or blocked[neighbour] == 1:
                continue
            var cost := best[index] + weights[neighbour] \
                    + 0.1 * float(distances[neighbour])
            if cost >= best[neighbour]:
                continue
            best[neighbour] = cost
            came_from[neighbour] = index
            _heap_push(heap_cells, heap_costs, neighbour, cost)
    if goal < 0:
        return PackedInt32Array()

    var path := PackedInt32Array()
    var current := goal
    while current != source:
        path.append(current)
        current = came_from[current]
    path.append(source)
    path.reverse()
    return path

# Whether a coast cell still has a water neighbour without a river mouthing into it.
static func _free_mouth(grid: int, cell: int, mouths: PackedByteArray,
        water: PackedByteArray) -> bool:
    for neighbour in _neighbours(grid, cell):
        if water[neighbour] == 1 and mouths[neighbour] == 0:
            return true
    return false

# A binary min-heap over two parallel arrays: the search pops the cheapest cell first.
static func _heap_push(cells: Array, costs: Array, cell: int, cost: float) -> void:
    cells.append(cell)
    costs.append(cost)
    var index := cells.size() - 1
    while index > 0:
        var parent := (index - 1) / 2
        if costs[parent] <= costs[index]:
            break
        _heap_swap(cells, costs, parent, index)
        index = parent

static func _heap_pop(cells: Array, costs: Array) -> int:
    var top: int = cells[0]
    var last := cells.size() - 1
    cells[0] = cells[last]
    costs[0] = costs[last]
    cells.remove_at(last)
    costs.remove_at(last)
    var index := 0
    while true:
        var left := index * 2 + 1
        var right := left + 1
        var smallest := index
        if left < cells.size() and costs[left] < costs[smallest]:
            smallest = left
        if right < cells.size() and costs[right] < costs[smallest]:
            smallest = right
        if smallest == index:
            break
        _heap_swap(cells, costs, index, smallest)
        index = smallest
    return top

static func _heap_swap(cells: Array, costs: Array, first: int, second: int) -> void:
    var cell: int = cells[first]
    cells[first] = cells[second]
    cells[second] = cell
    var cost: float = costs[first]
    costs[first] = costs[second]
    costs[second] = cost

# The path as a curve on the picture. The last point stops just short of the first water cell,
# so the mouth touches the shore and the line stays on the land it was drawn on.
#
# The cell path is a staircase, and a staircase does not read as a river. Every point of the path
# is pushed aside across the course, by a wave that holds its side for a few cells and by an
# amount the distance to the water allows: the river keeps to the shore near the mouth and may
# swing wider inland. Corner cutting then smooths the staircase into a course. The bend is cut
# down when the curve would cross a water cell or a river already drawn, so the line never
# leaves the land and never crosses another river. An empty result means no course was clear.
static func _river_points(grid: int, water: PackedByteArray, distances: PackedInt32Array,
        path: PackedInt32Array, seed_value: int, blocked: PackedByteArray,
        mouths: PackedByteArray, drawn: Array) -> PackedVector2Array:
    var mouth := _cell_center(grid, path[path.size() - 1])
    for neighbour in _neighbours(grid, path[path.size() - 1]):
        if water[neighbour] == 1 and mouths[neighbour] == 0:
            mouth = mouth.lerp(_cell_center(grid, neighbour), 0.45)
            break

    for factor in [1.0, 0.55, 0.25]:
        var bent := PackedVector2Array()
        for index in range(path.size()):
            bent.append(_bent_point(grid, path, index, distances, seed_value, factor))
        bent.append(mouth)
        var curve := _smooth_curve(bent)
        if _clear_of(grid, water, curve) and _clear_of(grid, blocked, curve) \
                and _self_clear(grid, curve) and _clear_of_drawn(grid, drawn, curve):
            return curve

    var plain := PackedVector2Array()
    for index in range(path.size()):
        plain.append(_cell_center(grid, path[index]))
    plain.append(mouth)
    if _clear_of(grid, water, plain) and _clear_of(grid, blocked, plain) \
            and _clear_of_drawn(grid, drawn, plain):
        return plain
    return PackedVector2Array()

static func _bent_point(grid: int, path: PackedInt32Array, index: int,
        distances: PackedInt32Array, seed_value: int, factor: float) -> Vector2:
    var point := _cell_center(grid, path[index])
    var capacity := clampf(float(distances[path[index]] - 1) * 0.45, 0.0, 2.0)
    if capacity <= 0.0 or index == 0:
        return point
    var previous := _cell_center(grid, path[maxi(index - 1, 0)])
    var next := _cell_center(grid, path[mini(index + 1, path.size() - 1)])
    var direction := next - previous
    if direction.length() < 0.001:
        return point
    var side := _hash01(seed_value, index / 4) * 2.0 - 1.0
    return point + Vector2(-direction.y, direction.x).normalized() * capacity * side * factor

# Three rounds of corner cutting: every segment is replaced by its quarter points, so the
# corners of the staircase become curves and the line keeps the general course of the path.
static func _smooth_curve(points: PackedVector2Array) -> PackedVector2Array:
    if points.size() < 3:
        return points
    var smoothed := points
    for _iteration in range(3):
        var next := PackedVector2Array([smoothed[0]])
        for index in range(smoothed.size() - 1):
            next.append(smoothed[index].lerp(smoothed[index + 1], 0.25))
            next.append(smoothed[index].lerp(smoothed[index + 1], 0.75))
        next.append(smoothed[smoothed.size() - 1])
        smoothed = next
    return smoothed

static func _cell_center(grid: int, cell: int) -> Vector2:
    return Vector2(float(cell % grid) + 0.5, float(cell / grid) + 0.5)

static func _hash01(seed_value: int, value: int) -> float:
    var hash := (value * 73856093) ^ (seed_value * 19349663)
    hash = (hash ^ (hash >> 13)) * 1274126177
    hash = hash ^ (hash >> 16)
    return float(hash & 0xFFFF) / 65535.0

# The segments of a line grouped by the cell of their middle. Comparing two lines segment by
# segment would cost the square of their length, while two segments can meet only if they lie
# in the same cell or in neighbouring ones.
static func _segment_buckets(grid: int, points: PackedVector2Array) -> Dictionary:
    var buckets: Dictionary = {}
    for index in range(points.size() - 1):
        var middle := (points[index] + points[index + 1]) * 0.5
        var key := clampi(int(floor(middle.y)), 0, grid - 1) * grid \
                + clampi(int(floor(middle.x)), 0, grid - 1)
        if buckets.has(key):
            buckets[key].append(index)
        else:
            buckets[key] = PackedInt32Array([index])
    return buckets

# Whether any segment of `points` meets the bucketed line. The curves are sampled finer than a
# cell and a crossing slips between the samples, so the segments themselves are compared. The
# segments of one line meet at their shared ends, hence `skip`: the segments that follow the
# tested one within a few samples are the same line, not a crossing.
static func _meets(grid: int, buckets: Dictionary, line: PackedVector2Array,
        points: PackedVector2Array, skip: int) -> bool:
    for index in range(points.size() - 1):
        var middle := (points[index] + points[index + 1]) * 0.5
        var row := clampi(int(floor(middle.y)), 0, grid - 1)
        var col := clampi(int(floor(middle.x)), 0, grid - 1)
        for offset_row in range(-1, 2):
            for offset_col in range(-1, 2):
                var r := row + offset_row
                var c := col + offset_col
                if r < 0 or r >= grid or c < 0 or c >= grid:
                    continue
                var key := r * grid + c
                if not buckets.has(key):
                    continue
                for other in buckets[key]:
                    if skip > 0 and other < index + skip:
                        continue
                    if Geometry2D.segment_intersects_segment(points[index],
                            points[index + 1], line[other], line[other + 1]) != null:
                        return true
    return false

# A bend that turns the river on itself reads as a crossing as well, so the river is compared
# with itself.
static func _self_clear(grid: int, points: PackedVector2Array) -> bool:
    return not _meets(grid, _segment_buckets(grid, points), points, points, 3)

# Whether the curve runs into a river already drawn. The blocked cells keep the courses apart
# as well, but they are a sampled mask, and the lines themselves are what the player sees.
static func _clear_of_drawn(grid: int, drawn: Array, points: PackedVector2Array) -> bool:
    for river in drawn:
        if _meets(grid, river["buckets"], river["points"], points, 0):
            return false
    return true

# Whether the whole polyline lies outside the masked cells. The segments are sampled finer than
# a cell, because a corner cut can pass over a cell without touching its centre.
static func _clear_of(grid: int, mask: PackedByteArray,
        points: PackedVector2Array) -> bool:
    for index in range(points.size() - 1):
        var steps := maxi(1, ceili(points[index].distance_to(points[index + 1]) * 4.0))
        for step in range(steps + 1):
            var point := points[index].lerp(points[index + 1],
                    float(step) / float(steps))
            var cell := clampi(int(floor(point.y)), 0, grid - 1) * grid \
                    + clampi(int(floor(point.x)), 0, grid - 1)
            if mask[cell] == 1:
                return false
    return true

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
    _draw_rivers(square)
    _draw_towns(square)
    _draw_city(square)
    _draw_caption()

func _square(area: Rect2, side_in_hexes: int) -> Rect2:
    var full := minf(area.size.x, area.size.y)
    var side := maxf(full * sqrt(float(side_in_hexes) / float(max_map_size)), MIN_SIDE)
    return Rect2(area.position + (area.size - Vector2(side, side)) * 0.5, Vector2(side, side))

# The towns are spread on a sunflower spiral: even density without a random seed, so the
# picture does not change while the player drags the number up and down. The spiral starts
# outside the city, which is why the middle of the map stays clear. A town stands on land the
# city reaches; one that would fall into the sea or on an island moves to the nearest free cell
# of that land, so the picture keeps the count of the setting.
func _draw_towns(square: Rect2) -> void:
    if town_count <= 0:
        return
    var centre := square.get_center()
    var reach := maxf(square.size.x * 0.5 - TOWN_RADIUS * 2.0, CITY_CLEAR)
    var span := reach - CITY_CLEAR
    var placed: Array[Vector2] = []
    for index in town_count:
        var distance := CITY_CLEAR + sqrt((float(index) + 0.5) / float(town_count)) * span
        var angle := float(index) * GOLDEN_ANGLE
        var point := centre + Vector2(cos(angle), sin(angle)) * distance
        if _is_town_land(square, point) and _clear_of_towns(point, placed):
            placed.append(point)
            draw_circle(point, TOWN_RADIUS, TOWN_COLOR)
            continue
        var cell := _nearest_free_cell(square, point, placed)
        if cell < 0:
            continue
        var spot := _cell_point(square, cell)
        placed.append(spot)
        draw_circle(spot, TOWN_RADIUS, TOWN_COLOR)

func _clear_of_towns(point: Vector2, placed: Array[Vector2]) -> bool:
    for other in placed:
        if point.distance_to(other) < MIN_TOWN_GAP:
            return false
    return true

# The nearest cell of the city's land that can take a town: clear of the city's ring and of the
# towns already placed. The search crosses water, because the point it starts from may lie in
# the sea or on an island.
func _nearest_free_cell(square: Rect2, point: Vector2, placed: Array[Vector2]) -> int:
    var grid: int = _picture.get("grid", 0)
    var reachable: PackedByteArray = _picture.get("reachable", PackedByteArray())
    if grid <= 0 or reachable.size() != grid * grid or square.size.x <= 0.0:
        return -1
    var centre := square.get_center()
    var start := _cell_at(square, point, grid)
    var seen := PackedByteArray()
    seen.resize(grid * grid)
    seen[start] = 1
    var queue := PackedInt32Array([start])
    var head := 0
    while head < queue.size():
        var index := queue[head]
        head += 1
        if reachable[index] == 1:
            var spot := _cell_point(square, index)
            if spot.distance_to(centre) >= CITY_CLEAR and _clear_of_towns(spot, placed):
                return index
        for neighbour in _neighbours(grid, index):
            if seen[neighbour] == 1:
                continue
            seen[neighbour] = 1
            queue.append(neighbour)
    return -1

# Whether a point of the square stands on land a town can stand on. The picture is a grid of
# blocks of the world, so the answer is the reachable mask built with the picture.
func _is_town_land(square: Rect2, point: Vector2) -> bool:
    var grid: int = _picture.get("grid", 0)
    var reachable: PackedByteArray = _picture.get("reachable", PackedByteArray())
    if grid <= 0 or reachable.size() != grid * grid:
        return true
    if square.size.x <= 0.0 or square.size.y <= 0.0:
        return true
    return reachable[_cell_at(square, point, grid)] == 1

static func _cell_at(square: Rect2, point: Vector2, grid: int) -> int:
    var x := clampi(int((point.x - square.position.x) / square.size.x * float(grid)), 0, grid - 1)
    var y := clampi(int((point.y - square.position.y) / square.size.y * float(grid)), 0, grid - 1)
    return y * grid + x

func _cell_point(square: Rect2, index: int) -> Vector2:
    var grid: int = _picture.get("grid", 1)
    var cell := Vector2(float(index % grid) + 0.5, float(int(float(index) / float(grid))) + 0.5)
    return square.position + cell * (square.size / float(grid))

# The rivers go under the towns and the city, so a settlement stays readable on the bank it
# stands on.
func _draw_rivers(square: Rect2) -> void:
    var grid: int = _picture.get("grid", 0)
    var rivers: Array = _picture.get("rivers", [])
    if grid <= 0 or rivers.is_empty() or square.size.x <= 0.0:
        return
    var width := maxf(RIVER_MIN_WIDTH, square.size.x * RIVER_WIDTH_RATIO)
    for path in rivers:
        if path.size() < 2:
            continue
        var points := PackedVector2Array()
        for point in path:
            points.append(square.position + point * (square.size / float(grid)))
        draw_polyline(points, RIVER_COLOR, width, true)

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
