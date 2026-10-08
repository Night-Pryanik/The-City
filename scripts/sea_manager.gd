# sea_manager.gd
# All the logic of sea generation, coastline and the post-processing related to them,
# moved out of map_generator.gd. A purely utility module: static functions,
# without any state of its own.
#
# Public API:
#   - sea_config()                                     : Dictionary
#   - is_sea_hex(tile_data, row, col)                  : bool
#   - apply_sea(tile_data, rows, cols, city_row,
#               city_col)                              : Array   (2D bool mask)
#   - reapply_sea_mask(tile_data)                      : void    (after Voronoi)
#   - replace_island_lakes(tile_data, sea_mask,
#                          rows, cols)                 : void
#   - apply_sea_coast_marshes(tile_data, rows, cols)   : void
#
# It uses temporary flags on the hexes:
#   - tile._is_sea    : bool — the hex is part of the sea mask
#   - tile._is_shallow_sea : bool — the hex belongs to the coastal shallows
#   - tile._is_beach  : bool — the hex has been turned into a beach (beach)
#   - tile._is_marsh  : bool — the hex has been turned into a marsh (marsh) [shared with the lakes]
#
# The temporary flags are reset by map_generator._ensure_plain_zone and
# map_generator._punch_hex after their work is done.
@tool
class_name SeaManager

# --- Constants ---
# The chance to turn a beach hex into a marsh. The same as for the lake marshes
# in map_generator.gd (MARSH_CHANCE). It is duplicated on purpose: the modules are isolated
# from each other, and the chance can be changed globally with one point refactoring.
const MARSH_CHANCE := 0.15


# Returns the sea configuration from data/map_config.json (the "sea" block).
static func sea_config() -> Dictionary:
    return GameData.map_config.get("sea", {})


# Returns true if the hex (row, col) is marked as sea (the temporary flag _is_sea).
static func is_sea_hex(tile_data: Array, row: int, col: int) -> bool:
    return tile_data[row][col].get("_is_sea", false)


# Generates the sea mask on the map BEFORE the Voronoi algorithm.
# It returns a 2D bool array: true = the hex is sea.
# Two modes are supported (see data/map_config.json, the "sea" block):
#   - "noise" (variant A): elevation = the gradient from the edge + noise + city_bump;
#     land = elevation > sea_level.
#   - "edge" (variant B): a sea strip at the chosen edges, the width is a smooth 1D noise.
#   - "none": the sea is not generated.
# The sea hexes are marked with the temporary flag _is_sea, so that after the Voronoi
# the mask can be re-applied on top of the result.
static func apply_sea(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> Array:
    var cfg := sea_config()
    var mode: String = cfg.get("mode", "none")
    var sea_mask: Array = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(false)
        sea_mask.append(row_arr)

    if mode == "none":
        return sea_mask

    var max_sea_depth: int = int(cfg.get("max_sea_depth", 8))
    var coast_max_depth: int = maxi(1, int(cfg.get("coast_max_depth", 5)))
    var beach_enabled: bool = cfg.get("beach", true)

    # sides — the range [min, max] of the number of randomly chosen map edges
    # that will have the sea. [0,0] — the sea is not generated.
    # The parsing and validation of the format ("a number" or "[min, max] of numbers", swap on
    # swapped bounds) is delegated to RangeUtils.parse_range.
    # With invalid data the sea is not generated (safe behaviour).
    var parsed_sides: Dictionary = RangeUtils.parse_range(cfg.get("sides", []))
    if not parsed_sides.ok:
        print("map_generator: warning — the sea.sides field is set incorrectly, the sea is not generated. A number or [min, max] (0..4) is expected.")
        return sea_mask
    var sides: Array = []
    var min_sides: int = clampi(parsed_sides["min"], 0, 4)
    var max_sides: int = clampi(parsed_sides["max"], 0, 4)
    # If the minimum = 0 — the sea may not be generated at all.
    if max_sides <= 0:
        return sea_mask
    var all_sides: Array = ["east", "west", "north", "south"]
    var count: int = randi_range(min_sides, max_sides)
    all_sides.shuffle()
    for i in range(count):
        sides.append(all_sides[i])

    if mode == "noise":
        _apply_sea_noise(sea_mask, rows, cols, city_row, city_col, cfg, max_sea_depth, sides)
    elif mode == "edge":
        _apply_sea_edge(sea_mask, rows, cols, cfg, max_sea_depth, sides)

    var shallow_mask := _build_shallow_sea_mask(sea_mask, rows, cols, coast_max_depth)

    if mode == "edge":
        # Islands in the seas — only for the "edge" mode. They are placed BEFORE the _is_sea
        # marking and BEFORE _apply_beach, so that the beach later correctly outlines the new
        # islands (as well as any other land next to the sea).
        if bool(cfg.get("edge_islands_enabled", true)):
            _apply_sea_islands(sea_mask, rows, cols, cfg, city_row, city_col)

    # We mark the sea hexes with the temporary flag _is_sea.
    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c]:
                tile_data[r][c]["_is_sea"] = true
                if shallow_mask[r][c]:
                    tile_data[r][c]["_is_shallow_sea"] = true

    # The beach: land adjacent to the sea becomes a beach (beach).
    if beach_enabled:
        _apply_beach(tile_data, sea_mask, rows, cols)

    return sea_mask


# Re-applies the sea/beach mask on top of the Voronoi result. The Voronoi
# filled the whole map with its own relief, therefore by the flags _is_sea / _is_beach
# we restore the original terrain types, so that they are not overwritten.
static func reapply_sea_mask(tile_data: Array) -> void:
    for row in range(tile_data.size()):
        var data_row: Array = tile_data[row]
        for col in range(data_row.size()):
            var tile = data_row[col]
            if tile.get("_is_sea", false):
                tile["terrain"] = "shallow_sea" if tile.get("_is_shallow_sea", false) else "sea"
                tile["cover"] = "none"
            elif tile.get("_is_beach", false):
                tile["terrain"] = "beach"
                tile["cover"] = "none"


static func _build_shallow_sea_mask(sea_mask: Array, rows: int, cols: int, max_depth: int) -> Array:
    var shallow_mask: Array = []
    for r in range(rows):
        var row_arr: Array = []
        row_arr.resize(cols)
        row_arr.fill(false)
        shallow_mask.append(row_arr)

    var coast_noise := FastNoiseLite.new()
    coast_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    coast_noise.seed = randi()
    coast_noise.frequency = 0.08

    for r in range(rows):
        for c in range(cols):
            if not sea_mask[r][c]:
                continue
            var is_coast := false
            for neighbor in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                if not sea_mask[neighbor.row][neighbor.col]:
                    is_coast = true
                    break
            if not is_coast:
                continue

            var noise_value := 0.5 + 0.5 * coast_noise.get_noise_2d(float(r), float(c))
            var local_depth := 1 + int(round(noise_value * float(max_depth - 1)))
            var queue: Array = [ {"row": r, "col": c, "depth": 1}]
            var visited := {"%d,%d" % [r, c]: true}
            var queue_index := 0
            while queue_index < queue.size():
                var current: Dictionary = queue[queue_index]
                queue_index += 1
                shallow_mask[current.row][current.col] = true
                if current.depth >= local_depth:
                    continue
                for neighbor in HexUtils.get_neighbors_odd_r(current.row, current.col, rows, cols):
                    if not sea_mask[neighbor.row][neighbor.col]:
                        continue
                    var key := "%d,%d" % [neighbor.row, neighbor.col]
                    if visited.has(key):
                        continue
                    visited[key] = true
                    queue.append({
                        "row": neighbor.row,
                        "col": neighbor.col,
                        "depth": current.depth + 1
                    })

    return shallow_mask


# Variant A: elevation = the gradient from the edge + noise + city_bump; land = elevation > sea_level.
# sides — the list of edges that may have the sea ("east", "west", "north", "south").
# If sides is empty — the sea is generated from all the edges (the default behaviour).
static func _apply_sea_noise(sea_mask: Array, rows: int, cols: int,
        city_row: int, city_col: int, cfg: Dictionary, max_sea_depth: int, sides: Array) -> void:
    var sea_level: float = float(cfg.get("noise_sea_level", 0.0))
    var noise_strength: float = float(cfg.get("noise_strength", 0.35))
    var edge_gradient: float = float(cfg.get("noise_edge_gradient", 0.4))
    var city_bump: float = float(cfg.get("noise_city_bump", 0.5))
    var city_bump_radius: float = float(cfg.get("noise_city_bump_radius", 8))

    # Normalized coordinates: 0 in the centre of the map, 1 at the edge.
    var half_rows = float(rows - 1) / 2.0
    var half_cols = float(cols - 1) / 2.0

    for r in range(rows):
        for c in range(cols):
            # The distance to the nearest edge of the map (in hexes).
            var edge_dist_hex = min(
                min(r, rows - 1 - r),
                min(c, cols - 1 - c)
            )
            # The sea width limit: hexes further than max_sea_depth from the edge — land.
            if edge_dist_hex > max_sea_depth:
                continue

            # If the edges are set — we check that the hex is at one of them.
            # Otherwise (sides is empty) — the sea from all the edges.
            if not sides.is_empty():
                var near_allowed_side := false
                for side in sides:
                    var dist_to_side := -1
                    if side == "east":
                        dist_to_side = cols - 1 - c
                    elif side == "west":
                        dist_to_side = c
                    elif side == "north":
                        dist_to_side = r
                    elif side == "south":
                        dist_to_side = rows - 1 - r
                    # The hex is at the chosen edge, if it is within max_sea_depth of it.
                    if dist_to_side >= 0 and dist_to_side <= max_sea_depth:
                        near_allowed_side = true
                        break
                if not near_allowed_side:
                    continue

            # The normalized distance to the edge (0 at the edge, 1 in the centre).
            var edge_dist = min(
                min(float(r) / half_rows, float(rows - 1 - r) / half_rows),
                min(float(c) / half_cols, float(cols - 1 - c) / half_cols)
            )
            # The gradient: centred around 0. At the edge (edge_dist=0) — negative
            # (sea), in the centre (edge_dist=1) — positive (land).
            var gradient = (edge_dist - 0.5) * 2.0 * edge_gradient

            # The elevation noise (deterministic by the coordinates), centred around 0:
            # from -noise_strength to +noise_strength.
            var noise = (_hash_noise(r, c) * 2.0 - 1.0) * noise_strength

            # City bump: a "hill" around the city, guaranteeing the starting continent.
            var dist_to_city = HexUtils.hex_distance(r, c, city_row, city_col)
            var bump = 0.0
            if dist_to_city <= city_bump_radius:
                var t = 1.0 - float(dist_to_city) / city_bump_radius
                bump = city_bump * t * t

            var elevation = gradient + noise + bump
            if elevation <= sea_level:
                sea_mask[r][c] = true


# Variant B: a sea strip at the chosen edges, the width is a smooth 1D noise.
static func _apply_sea_edge(sea_mask: Array, rows: int, cols: int,
        cfg: Dictionary, max_sea_depth: int, sides: Array) -> void:
    if sides.is_empty():
        return

    var width_min: float = float(cfg.get("edge_width_min", 1))
    var width_max: float = float(cfg.get("edge_width_max", 7))
    var envelope_strength: float = float(cfg.get("edge_envelope_strength", 0.0))

    # A large-scale 1D noise for the naturalness of the coast
    var envelope_noise: FastNoiseLite = FastNoiseLite.new()
    envelope_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    envelope_noise.seed = randi()
    envelope_noise.frequency = 0.08

    for side in sides:
        var len: int = rows if (side == "east" or side == "west") else cols
        var arr: Array = []
        var seg: int = 8
        var i0: int = -1
        var v0: float = 0.0
        var v1: float = randf()

        # The centre of the edge for the parabolic envelope
        var center_pos: float = float(len) / 2.0
        var half_len: float = float(len) / 2.0

        for coord in range(len):
            if coord / seg != i0:
                i0 = coord / seg
                v0 = v1
                v1 = randf()
            var t: float = 0.5 - 0.5 * cos(float(coord % seg) / float(seg) * PI)
            var base_width: float = lerpf(width_min, width_max, lerpf(v0, v1, t))

            # The parabolic envelope: 1 in the centre, 0 at the edges
            var dist_from_center: float = abs(float(coord) - center_pos)
            var parabola: float = 1.0 - pow(dist_from_center / half_len, 2.0)
            parabola = max(0.0, parabola)

            # We combine the parabola with the noise
            if envelope_strength > 0.0:
                var noise_val: float = 0.5 + 0.5 * envelope_noise.get_noise_1d(float(coord))
                var env: float = lerp(parabola, parabola * noise_val, envelope_strength)
                base_width *= env

            arr.append(int(round(base_width)))

        # We apply the width to the hexes
        for coord in range(len):
            var width: int = arr[coord]
            if width <= 0:
                continue
            for depth in range(width):
                if depth >= max_sea_depth:
                    break
                var r: int = 0
                var c: int = 0
                match side:
                    "east": r = coord; c = cols - 1 - depth
                    "west": r = coord; c = depth
                    "south": r = rows - 1 - depth; c = coord
                    "north": r = depth; c = coord
                if r >= 0 and r < rows and c >= 0 and c < cols:
                    sea_mask[r][c] = true


# Generates islands inside the sea mask (the "edge" mode): some of the sea hexes
# are turned into land in groups (BFS growth from random seed points).
# The number of islands "smartly" adjusts to the area of the sea: target = sea_area *
# edge_island_density, the actual number is randi_range(0, target + 1). In
# a small sea this often gives 0 islands, in a big one — it may give many.
# It is called BEFORE _apply_beach, so that the beach correctly outlines the new islands.
static func _apply_sea_islands(sea_mask: Array, rows: int, cols: int,
        cfg: Dictionary, city_row: int, city_col: int) -> void:
    # --- Reading the parameters with defaults ---
    var size_range: Array = cfg.get("edge_island_size", [1, 5])
    var size_min: int = 1
    var size_max: int = 5
    if size_range is Array and size_range.size() >= 2:
        size_min = maxi(1, int(size_range[0]))
        size_max = maxi(size_min, int(size_range[1]))
    var density: float = float(cfg.get("edge_island_density", 0.003))
    var min_distance: int = maxi(0, int(cfg.get("edge_island_min_distance", 3)))
    var max_attempts: int = maxi(1, int(cfg.get("edge_island_max_attempts", 60)))

    # --- We compute the sea area and the target number of islands ---
    var sea_area := 0
    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c]:
                sea_area += 1
    # Without the sea (or a very tiny one) — we exit, there is nothing to do.
    if sea_area < size_min:
        return

    var target: int = int(round(float(sea_area) * density))
    # The spread: 0..target+1. If target=0, it gives 0..1 (a rare single island);
    # if target=10, it gives 0..11. That is exactly the "may be, but not necessarily".
    var actual_count: int = randi_range(0, target + 1)
    if actual_count <= 0:
        return

    # --- The list of all sea hexes (for a fast random choice of a seed) ---
    var sea_cells: Array = []
    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c]:
                sea_cells.append({"row": r, "col": c})
    if sea_cells.is_empty():
        return
    sea_cells.shuffle()

    # --- The occupied points (the centres of the already placed islands) — for min_distance ---
    var occupied: Array = []

    var islands_placed := 0
    var island_index := 0
    while island_index < actual_count and not sea_cells.is_empty():
        # The size of the particular island in this placement.
        var island_size: int = randi_range(size_min, size_max)
        # We search for a seed point: we iterate over sea_cells in a random order, until we
        # find a suitable one (in the sea + not too close to the city/other islands).
        var seed_index := -1
        var attempts := 0
        while attempts < max_attempts and sea_cells.size() > 0:
            var idx: int = randi() % sea_cells.size()
            var candidate = sea_cells[idx]
            # Too close to the city (the starting zone) — we skip it. 2 hexes —
            # because _ensure_plain_zone clears a radius of 2 around the city;
            # even if the island is on the border of that radius, its hexes will go into
            # the plain and it will "disappear", which would break the "island in the sea" invariant.
            if HexUtils.hex_distance(candidate.row, candidate.col, city_row, city_col) <= 2:
                attempts += 1
                # We remove it from the pool, so as not to iterate forever.
                sea_cells.remove_at(idx)
                continue
            # Too close to another island — we skip it.
            var too_close := false
            for occ in occupied:
                if HexUtils.hex_distance(candidate.row, candidate.col, occ.row, occ.col) < min_distance:
                    too_close = true
                    break
            if too_close:
                attempts += 1
                sea_cells.remove_at(idx)
                continue
            # We have found a suitable seed point.
            seed_index = idx
            break
        if seed_index < 0:
            # We did not find a place in max_attempts attempts — we exit, the remaining
            # islands are not placed (fewer is better than an infinite loop).
            break
        var seed = sea_cells[seed_index]
        sea_cells.remove_at(seed_index)

        # --- BFS growth of the cluster: we add the neighbours one by one, until we get island_size ---
        var cluster: Array = [seed]
        var cluster_set := {}
        cluster_set["%d,%d" % [seed.row, seed.col]] = true
        var frontier: Array = [seed]
        while cluster.size() < island_size and not frontier.is_empty():
            var next_frontier: Array = []
            for cell in frontier:
                if cluster.size() >= island_size:
                    break
                var neighbors = HexUtils.get_neighbors_odd_r(cell.row, cell.col, rows, cols)
                neighbors.shuffle()
                for n in neighbors:
                    if cluster.size() >= island_size:
                        break
                    var nk := "%d,%d" % [n.row, n.col]
                    if cluster_set.has(nk):
                        continue
                    # We grow only over the sea — we do not "jump" onto land/islands.
                    if not sea_mask[n.row][n.col]:
                        continue
                    cluster_set[nk] = true
                    cluster.append(n)
                    next_frontier.append(n)
                    if cluster.size() >= island_size:
                        break
            frontier = next_frontier
        if cluster.is_empty():
            continue

        # --- We turn the hexes of the cluster from sea into land (resetting sea_mask) ---
        for cell in cluster:
            sea_mask[cell.row][cell.col] = false
        # We remember the seed as an occupied point for the future min_distance checks.
        occupied.append(seed)
        islands_placed += 1
        island_index += 1

    if islands_placed > 0:
        print("map_generator: islands placed in the sea: %d (the target number was %d, the sea area is %d)" %
                [islands_placed, target, sea_area])


# A smooth strip width of the sea along an edge (1D noise).
# At the moment it is not called (the real _apply_sea_edge uses its own
# 1D noise via FastNoiseLite). It is kept for future experiments with
# the coastline generation.
static func _smooth_width(row: int, col: int, side: String, width_min: int, width_max: int) -> float:
    var t := 0.0
    if side == "east" or side == "west":
        t = float(row) / 10.0
    else:
        t = float(col) / 10.0
    # The sum of the sines gives a smooth change of the width along the coast.
    var v = 0.5 + 0.5 * sin(t * 6.283 + _hash_noise(row, col) * 6.283)
    return lerpf(float(width_min), float(width_max), v)


# A deterministic pseudo-random noise by the coordinates (0..1).
# The offset constant 1013904223 guarantees that for (0,0) the noise is not 0.0
# (otherwise with sea_level = 0.0 the hex (0,0) would always become the sea).
static func _hash_noise(row: int, col: int) -> float:
    var h = row * 374761393 + col * 668265263 + 1013904223
    h = (h ^ (h >> 13)) * 1274126177
    h = h ^ (h >> 16)
    return float((h & 0x7fffffff) % 10000) / 10000.0


# Turns land adjacent to the sea into a beach (beach).
static func _apply_beach(tile_data: Array, sea_mask: Array, rows: int, cols: int) -> void:
    # The beach is formed only on land connected to the edge of the map. The areas
    # enclosed by the sea keep the Voronoi relief and do not turn into marshes.
    var edge_connected_land := []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(false)
        edge_connected_land.append(row_arr)

    var queue: Array = []
    for r in range(rows):
        for c in range(cols):
            if r != 0 and r != rows - 1 and c != 0 and c != cols - 1:
                continue
            if sea_mask[r][c] or edge_connected_land[r][c]:
                continue
            edge_connected_land[r][c] = true
            queue.append({"row": r, "col": c})

    var queue_index := 0
    while queue_index < queue.size():
        var current = queue[queue_index]
        queue_index += 1
        for n in HexUtils.get_neighbors_odd_r(current.row, current.col, rows, cols):
            if sea_mask[n.row][n.col] or edge_connected_land[n.row][n.col]:
                continue
            edge_connected_land[n.row][n.col] = true
            queue.append(n)

    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c] or not edge_connected_land[r][c]:
                continue
            # A land hex: we check whether there is a sea neighbour.
            var has_sea_neighbor := false
            for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                if sea_mask[n.row][n.col]:
                    has_sea_neighbor = true
                    break
            if has_sea_neighbor:
                tile_data[r][c]["terrain"] = "beach"
                tile_data[r][c]["_is_beach"] = true


# Sea islands must not consist of lakes: we replace the lakes in the land components
# enclosed by the sea with a plain. It is called BEFORE the check of the minimum
# number of lakes on the map.
static func replace_island_lakes(tile_data: Array, sea_mask: Array, rows: int, cols: int) -> void:
    var edge_connected_land := []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(false)
        edge_connected_land.append(row_arr)

    var queue: Array = []
    for r in range(rows):
        for c in range(cols):
            if r != 0 and r != rows - 1 and c != 0 and c != cols - 1:
                continue
            if sea_mask[r][c] or edge_connected_land[r][c]:
                continue
            edge_connected_land[r][c] = true
            queue.append({"row": r, "col": c})

    var queue_index := 0
    while queue_index < queue.size():
        var current = queue[queue_index]
        queue_index += 1
        for n in HexUtils.get_neighbors_odd_r(current.row, current.col, rows, cols):
            if sea_mask[n.row][n.col] or edge_connected_land[n.row][n.col]:
                continue
            edge_connected_land[n.row][n.col] = true
            queue.append(n)

    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c] or edge_connected_land[r][c]:
                continue
            if tile_data[r][c].get("terrain", "plain") == "lake":
                tile_data[r][c]["terrain"] = "plain"
                tile_data[r][c]["cover"] = _roll_cover("plain")


# The marshes on the coast (beach): part of the beach hexes around the sea with a
# MARSH_CHANCE chance turns into a marsh. The inner land of the sea islands
# is NOT affected — only the coastal zone. It is called AFTER the
# sea/beach mask is applied (when terrain == "sea" and "beach" are already set).
static func apply_sea_coast_marshes(tile_data: Array, rows: int, cols: int) -> void:
    var sea_hexes: Array = []
    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c].get("terrain", "plain") in ["sea", "shallow_sea"]:
                sea_hexes.append({"row": r, "col": c})

    # For the seas: the marshes are formed ONLY on the coast (the beach beach), and not on
    # the inner land of the islets. The beach is the coastal swamp zone.
    for water in sea_hexes:
        var neighbors = HexUtils.get_neighbors_odd_r(water.row, water.col, rows, cols)
        for n in neighbors:
            var t = tile_data[n.row][n.col]
            if t.get("terrain", "plain") != "beach":
                continue
            if randf() < MARSH_CHANCE:
                t["terrain"] = "marsh"
                t["_is_marsh"] = true
                t["_is_beach"] = false


# A local copy of `_roll_cover` from map_generator.gd: it is needed for
# replace_island_lakes (we turn a lake in a sea island into a plain, which
# must have a cover according to the weights of terrains.json). When map_generator
# also becomes a purely utility module, the cover logic can be moved into
# a separate module. For now — we duplicate it minimally.
static func _roll_cover(terrain_type: String) -> String:
    var t: Dictionary = GameData.terrains.get(terrain_type, {})
    var chances: Dictionary = t.get("cover_chance", {})
    if chances.is_empty():
        return "none"
    var total := 0.0
    total = 0.0
    for cid in chances.keys():
        total += float(chances[cid])
    if total <= 0.0:
        return "none"
    var roll = randf() * total
    var accum := 0.0
    for cid in chances.keys():
        accum += float(chances[cid])
        if roll < accum:
            return cid
    return "none"
