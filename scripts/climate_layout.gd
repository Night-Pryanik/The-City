class_name ClimateLayout
extends RefCounted

# The temperature belts of the world and the arithmetic that places them.
#
# The belts are the latitude of the map: they run from the poles to the equator, and a belt chosen
# in the world settings puts the city of the new game into it. Two readers share this module: the
# generator, which gives every hex of the world its belt, and the map preview of the new game
# window, which draws the belts of the chosen climate on its picture. They read the same geometry
# here, so the picture cannot promise a belt the world does not have.
#
# The whole of the arithmetic hangs on one geometry: the heights of the belts along the height of
# the grid, the amplitude of the meander of their boundaries, the share of the cold region that
# belongs to the polar belt and the row of the equator. Everything else follows from it.
#
# The grid the arithmetic works on is not necessarily the world. The generator works on the map
# itself, the preview on its own coarse picture. The scale tells how many rows of the grid one row
# of the world covers: every length the config gives in rows of the world is multiplied by it, and
# the fractions of the map height stay as they are, because a belt is a share of the height and not
# a number of rows.

# The belts from the pole to the equator. The order is the order of the belts on a map: two
# neighbouring belts are always neighbours in this list.
const TEMPERATURE_POLAR := "polar"
const TEMPERATURE_COLD := "cold"
const TEMPERATURE_MILD := "mild"
const TEMPERATURE_SUBTROPICAL := "subtropical"
const TEMPERATURE_TROPICAL := "tropical"
const BELTS: Array[String] = [TEMPERATURE_POLAR, TEMPERATURE_COLD, TEMPERATURE_MILD,
        TEMPERATURE_SUBTROPICAL, TEMPERATURE_TROPICAL]

# The climate setting of a new game that rolls the latitude of the city instead of fixing it.
const CLIMATE_RANDOM := "random"

# The meander of a chosen belt stops this far from its edges: the monotone clamp of the
# temperature rows can carry a row slightly past the warp amplitude itself.
const CLIMATE_MEANDER_MARGIN := 0.75

# The largest growth of the temperature row from one row to the next. It has to stay below the
# height of the narrowest belt, otherwise one step could jump over it and put a cold hex next to
# a tropical one.
const MAX_TEMPERATURE_STEP := 1.5

# The cold belt that the climate meander may never eat: the map keeps a polar edge on both sides.
const MIN_COLD_ROWS := 3.0

# The scratch buffer of the four corners of a lattice cell of the noise. The noise is evaluated
# cell by cell, and a buffer of its own keeps the field free of allocations.
static var _corner_values: PackedFloat32Array = PackedFloat32Array()

# The code of a belt by its name, and the name of a belt by its code. The codes are what the
# picture of the preview carries: a name per cell would be a string per cell.
static func belt_code(name: String) -> int:
    match name:
        TEMPERATURE_COLD:
            return 1
        TEMPERATURE_MILD:
            return 2
        TEMPERATURE_SUBTROPICAL:
            return 3
        TEMPERATURE_TROPICAL:
            return 4
    return 0

static func belt_name(code: int) -> String:
    return BELTS[clampi(code, 0, BELTS.size() - 1)]

# The geometry of the belts on a grid of `rows` rows.
#
# `scale` is how many rows of the grid one row of the world covers: the generator works on the
# world itself (1.0), the preview on its own picture (a row of the picture covers several rows of
# the world). The heights of the belts are shares of the height of the grid, so they are the same
# shares on any grid; the rest of the lengths are given in rows of the world and are scaled.
static func geometry(cfg: Dictionary, rows: int, scale: float) -> Dictionary:
    var height := float(rows)
    var tropical_half := maxf(2.0 * scale, height * float(cfg.get("tropical_half_rows", 0.08)))
    var subtropical := maxf(2.0 * scale, height * float(cfg.get("subtropical_rows", 0.06)))
    var mild := maxf(2.0 * scale, height * float(cfg.get("mild_rows", 0.10)))
    return {
        "scale": scale,
        "tropical_half": tropical_half,
        "subtropical": subtropical,
        "mild": mild,
        "belt": tropical_half + subtropical + mild,
        "warp_scale": float(cfg.get("warp_scale", 0.2)),
        "amplitude": float(cfg.get("warp_rows", 3.0)) * scale,
        "step": MAX_TEMPERATURE_STEP * scale,
        "min_cold": MIN_COLD_ROWS * scale,
        "polar_share": clampf(float(cfg.get("polar_share", 0.3)), 0.0, 1.0),
    }

# The latitude of a city with a chosen climate: its distance from the equator (x) and the room
# from that distance to the edges of the belt (y). The distance is the middle of the belt, so the
# meander has the most room. The cold belt also keeps the near map edge beyond the warm belts
# while the half map on that side of the equator is tall enough for them; a map too short for
# that keeps the city in the cold belt and lets the near edge be warmer.
static func city_latitude_target(rows: int, chosen: String, geo: Dictionary) -> Vector2:
    var tropical_half: float = geo["tropical_half"]
    var subtropical: float = geo["subtropical"]
    var mild: float = geo["mild"]
    var belt: float = geo["belt"]
    match chosen:
        TEMPERATURE_TROPICAL:
            return Vector2(tropical_half / 2.0, tropical_half / 2.0)
        TEMPERATURE_SUBTROPICAL:
            return Vector2(tropical_half + subtropical / 2.0, subtropical / 2.0)
        TEMPERATURE_MILD:
            return Vector2(tropical_half + subtropical + mild / 2.0, mild / 2.0)
    var middle := float(int(rows / 2.0))
    var far_limit := middle - 1.0 - belt
    if far_limit > belt:
        return Vector2((belt + far_limit) / 2.0, (far_limit - belt) / 2.0)
    return Vector2(belt + 1.0, 0.0)

# The row of the equator of a world with a chosen climate: the city stands in the middle of its
# belt, and `side` says on which side of the city the equator falls.
static func equator_of(rows: int, geo: Dictionary, chosen: String, side: float) -> float:
    var target := city_latitude_target(rows, chosen, geo)
    return float(int(rows / 2.0)) + target.x * side

# The row of the equator of a world with a random climate. The range of the roll keeps the full
# sequence of the belts on the map: with the equator too close to an edge, the cold belt of that
# side would disappear.
static func roll_equator_row(rows: int, cfg: Dictionary) -> float:
    var low := clampf(float(cfg.get("equator_min", 0.33)), 0.0, 1.0)
    var high := clampf(float(cfg.get("equator_max", 0.67)), low, 1.0)
    return float(rows - 1) * randf_range(low, high)

# The belts of a grid: the belt of every cell of it.
#
# `salt` is the salt of the meander noise and `equator` the row of the equator. Both are rolled by
# the caller: the generator rolls its own and the preview rolls its own, so the two never share a
# field and the picture never becomes a promise about the world.
static func layout(rows: int, cols: int, geo: Dictionary, chosen: String, salt: int,
        equator: float) -> Dictionary:
    var fixed := chosen != CLIMATE_RANDOM
    var warp_cap := INF
    if fixed:
        var target := city_latitude_target(rows, chosen, geo)
        warp_cap = maxf(0.0, target.y - CLIMATE_MEANDER_MARGIN)
    var temperature_rows := temperature_rows(rows, cols, geo, equator, salt, warp_cap, fixed)
    if fixed:
        pin_city_belt(temperature_rows, rows, cols, int(rows / 2.0), equator, chosen, geo)
    var bounds := polar_bounds(rows, cols, temperature_rows, geo, equator)

    # The belt of every cell. The geometry is read into locals first: the picture of the preview
    # is a grid of thousands of cells, and a dictionary lookup in every one of them costs more
    # than the arithmetic it serves.
    var tropical_half: float = geo["tropical_half"]
    var subtropical: float = geo["subtropical"]
    var belt: float = geo["belt"]
    var belts := PackedByteArray()
    belts.resize(rows * cols)
    for row in range(rows):
        var line: Array = temperature_rows[row]
        for col in range(cols):
            var temperature_row := float(line[col])
            var distance := absf(temperature_row - equator)
            var temperature := TEMPERATURE_TROPICAL
            if distance > tropical_half:
                if distance <= tropical_half + subtropical:
                    temperature = TEMPERATURE_SUBTROPICAL
                elif distance <= belt:
                    temperature = TEMPERATURE_MILD
                else:
                    temperature = TEMPERATURE_COLD
            var polar: Array = bounds[col]
            if temperature_row <= float(polar[0]) or temperature_row >= float(polar[1]):
                temperature = TEMPERATURE_POLAR
            belts[row * cols + col] = belt_code(temperature)
    return {"equator": equator, "belts": belts}

# The temperature row of every cell: its own row shifted by the climate meander.
# Down a column the value only grows and never jumps by more than the step of the geometry, so the
# belts keep their order; the horizontal average that follows cannot break it either, because an
# average of monotone columns is monotone itself. A chosen climate caps the meander so the city
# stays in its belt and leaves the edges as they fall: the edge shift of the random climate would
# drag the city out of the belt it was placed in.
static func temperature_rows(rows: int, cols: int, geo: Dictionary, equator: float, salt: int,
        warp_cap: float, fixed: bool) -> Array:
    var amplitude := minf(float(geo["amplitude"]), warp_cap)
    var scale := maxf(2.0 * float(geo["scale"]),
            float(mini(rows, cols)) * float(geo["warp_scale"]))
    var belt: float = geo["belt"]
    var step: float = geo["step"]

    # The meander must not eat the cold belt of the near side: with the equator pushed towards an
    # edge, the shift is reduced, so that at least the minimum of cold rows stay above (below) it.
    var room := minf(equator, float(rows - 1) - equator) - belt - float(geo["min_cold"])
    amplitude = clampf(amplitude, 0.0, maxf(0.0, room))

    var grid: Array = []
    for r in range(rows):
        var line: Array = []
        for c in range(cols):
            var warp := (fbm(float(r) / scale, float(c) / scale, salt, 2) - 0.5) * 2.0 * amplitude
            line.append(float(r) + warp)
        grid.append(line)

    for c in range(cols):
        for r in range(1, rows):
            var previous: float = grid[r - 1][c]
            grid[r][c] = clampf(grid[r][c], previous, previous + step)

    var smoothed: Array = []
    for r in range(rows):
        var line: Array = []
        for c in range(cols):
            var sum := 0.0
            var count := 0
            for offset in range(-1, 2):
                var cc: int = c + offset
                if cc < 0 or cc >= cols:
                    continue
                sum += float(grid[r][cc])
                count += 1
            line.append(sum / float(count))
        smoothed.append(line)

    # The polar edges are guaranteed: if the meander has brought the warm belt too close to an edge,
    # the whole column is shifted. A uniform shift keeps the column monotone and cannot create a
    # jump between the neighbouring columns.
    if fixed:
        return smoothed
    var edge := maxi(1, int(float(geo["min_cold"])))
    var top_limit := equator - belt - 1.0
    var bottom_limit := equator + belt + 1.0
    for c in range(cols):
        var top_max := -INF
        for r in range(mini(edge, rows)):
            top_max = maxf(top_max, float(smoothed[r][c]))
        var bottom_min := INF
        for r in range(maxi(0, rows - edge), rows):
            bottom_min = minf(bottom_min, float(smoothed[r][c]))
        var shift := 0.0
        if top_max > top_limit:
            shift += top_limit - top_max
        if bottom_min < bottom_limit:
            shift += bottom_limit - bottom_min
        if shift != 0.0:
            for r in range(rows):
                smoothed[r][c] = float(smoothed[r][c]) + shift
    return smoothed

# The polar belt of every column: the outer share of its cold region. It is measured from the
# edge row of the column, so the meander of the boundary can never pull the tundra off the pole.
# A cold region thinner than the minimum keeps no polar share: the tundra would sit next to a
# warm belt with no taiga between them. The random climate always keeps its edges thicker; a
# chosen cold climate on a short map can end up with a cold edge instead of a polar one.
static func polar_bounds(rows: int, cols: int, temperature_rows: Array, geo: Dictionary,
        equator: float) -> Array:
    var belt: float = geo["belt"]
    var min_cold: float = geo["min_cold"]
    var polar_share: float = geo["polar_share"]
    var bounds: Array = []
    for c in range(cols):
        var top := float(temperature_rows[0][c])
        var bottom := float(temperature_rows[rows - 1][c])
        var cold_top := maxf(0.0, equator - belt - top)
        var cold_bottom := maxf(0.0, bottom - equator - belt)
        var polar_top := top + cold_top * polar_share if cold_top >= min_cold else top - 1.0
        var polar_bottom := bottom - cold_bottom * polar_share if cold_bottom >= min_cold else bottom + 1.0
        bounds.append([polar_top, polar_bottom])
    return bounds

# The city of a chosen climate stays in its belt: if the meander has carried its temperature row
# across a belt edge, the whole column is shifted back. A uniform shift keeps the column monotone,
# so the order of the belts survives it.
static func pin_city_belt(temperature_rows: Array, rows: int, cols: int, city_row: int,
        equator: float, chosen: String, geo: Dictionary) -> void:
    var lo := 0.0
    var hi := float(geo["tropical_half"])
    match chosen:
        TEMPERATURE_SUBTROPICAL:
            lo = float(geo["tropical_half"])
            hi = float(geo["tropical_half"]) + float(geo["subtropical"])
        TEMPERATURE_MILD:
            lo = float(geo["tropical_half"]) + float(geo["subtropical"])
            hi = float(geo["belt"])
        TEMPERATURE_COLD:
            lo = float(geo["belt"])
            hi = INF
    var city_col := int(cols / 2.0)
    var distance := float(temperature_rows[city_row][city_col]) - equator
    var inside := absf(distance) <= hi and (lo == 0.0 or absf(distance) > lo)
    if inside:
        return
    var magnitude := clampf(absf(distance), lo + 0.5 if lo > 0.0 else 0.0, hi)
    var shift := (magnitude if distance >= 0.0 else -magnitude) - distance
    for r in range(rows):
        temperature_rows[r][city_col] = float(temperature_rows[r][city_col]) + shift

# Fractal noise: a few octaves of the value noise, each one weaker (persistence) and twice as fine.
# A lower persistence keeps the field smooth, which the moisture needs: the fine octaves alone
# would tear the boundary between a wet and a dry region into specks.
static func fbm(x: float, y: float, salt: int, octaves: int, persistence: float = 0.5) -> float:
    var total := 0.0
    var weight := 0.0
    var amplitude := 1.0
    var frequency := 1.0
    for octave in range(octaves):
        var px := x * frequency
        var py := y * frequency
        var x0 := int(floor(px))
        var y0 := int(floor(py))
        var fx := px - float(x0)
        var fy := py - float(y0)
        var sx := fx * fx * (3.0 - 2.0 * fx)
        var sy := fy * fy * (3.0 - 2.0 * fy)
        var corners := _corners(x0, y0, salt + octave * 101)
        var top := lerpf(corners[0], corners[1], sx)
        var bottom := lerpf(corners[2], corners[3], sx)
        total += lerpf(top, bottom, sy) * amplitude
        weight += amplitude
        amplitude *= persistence
        frequency *= 2.0
    return total / weight if weight > 0.0 else 0.0

# The four corners of the lattice cell around a point of the noise.
#
# The hash is written out four times instead of being called: the noise is evaluated for every
# cell of the map and of the picture of the preview, and a call per corner of every cell costs
# more than the arithmetic it saves. The field depends only on its own salt, so it does not
# consume the global RNG and does not shift the random sequence of the rest of the generation.
static func _corners(x0: int, y0: int, salt: int) -> PackedFloat32Array:
    if _corner_values.size() != 4:
        _corner_values.resize(4)
    var h := (x0 * 73856093) ^ (y0 * 19349663) ^ (salt * 83492791)
    h = h & 0x7FFFFFFF
    h = (h ^ (h >> 13)) * 1274126177
    h = h & 0x7FFFFFFF
    _corner_values[0] = float((h ^ (h >> 16)) & 0xFFFF) / 65535.0
    h = ((x0 + 1) * 73856093) ^ (y0 * 19349663) ^ (salt * 83492791)
    h = h & 0x7FFFFFFF
    h = (h ^ (h >> 13)) * 1274126177
    h = h & 0x7FFFFFFF
    _corner_values[1] = float((h ^ (h >> 16)) & 0xFFFF) / 65535.0
    h = (x0 * 73856093) ^ ((y0 + 1) * 19349663) ^ (salt * 83492791)
    h = h & 0x7FFFFFFF
    h = (h ^ (h >> 13)) * 1274126177
    h = h & 0x7FFFFFFF
    _corner_values[2] = float((h ^ (h >> 16)) & 0xFFFF) / 65535.0
    h = ((x0 + 1) * 73856093) ^ ((y0 + 1) * 19349663) ^ (salt * 83492791)
    h = h & 0x7FFFFFFF
    h = (h ^ (h >> 13)) * 1274126177
    h = h & 0x7FFFFFFF
    _corner_values[3] = float((h ^ (h >> 16)) & 0xFFFF) / 65535.0
    return _corner_values
