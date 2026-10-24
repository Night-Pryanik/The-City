# map_generator.gd
@tool
extends Node

# The minimum number of FREE (without a resource) hexes of each terrain type,
# which must remain inside the Influence Ring after the placement of all the resources.
# It guarantees that the player will always have enough space to build
# several farms/pastures of one resource (for example, quinoa grows only
# in the mountains — at least 2 free mountain hexes are needed to build at least 2 farms).
const FREE_TERRAIN_HEXES := 2

# The threshold of the "excess" of a terrain type: if there are more than this
# number of a type inside the Influence Ring, its free hexes can be converted
# into the missing types.
const OVER_REP_THRESHOLD := 3

# The radius of the "safe yard" around the city: all the hexes within this radius
# forcibly become a plain (plain). The cover is generated as that of
# an ordinary plain (forests may appear), so that the yard does not look bare.
# It guarantees that the city always has a free passable space
# for the starting construction and that the city does not "sink" in a lake. It is applied
# AFTER the placement of the unique terrains and BEFORE the generation of the cover/resources.
const PLAIN_ZONE_RADIUS := 2

# The radius within which placing the Voronoi centres of impassable
# terrain types (move_cost >= 999, for example the lakes) is FORBIDDEN. Thanks to the property
# of the Voronoi diagram this mathematically guarantees that in this area
# an impassable terrain cannot appear (a "sunken yard" around the city).
const CENTER_EXCLUSION_RADIUS := 6

# Returns the list of the terrain types that take part in the Voronoi algorithm
# (the base relief). They do NOT include:
#   - the unique types (unique: true) — they are placed by place_unique_terrains;
#   - the types that are not listed in terrain_config (the marsh family) — they are created
#     only by the post-processing (_apply_marshes).
# The participation in the Voronoi is now set explicitly through the config: adding a new
# type to terrains.json no longer makes it automatically spread
# over the whole map.
# The types of the Voronoi: the keys of terrain_config. A key is either a family — the relief or
# the wetland (the climate turns every hex of it into the variety of its belt) — or a terrain the
# climate leaves alone (a lake, a desert). The unique terrains are placed separately, by
# place_unique_terrains.
static func _get_base_terrain_ids() -> Array:
    var cfg: Dictionary = GameData.map_config.get("terrain_config", {})
    var ids: Array = []
    for tid in cfg.keys():
        var t: Dictionary = GameData.terrains.get(str(tid), {})
        if t.get("unique", false):
            continue
        ids.append(str(tid))
    return ids

# Returns the list of the unique terrain types (unique: true), which are
# placed by the universal function place_unique_terrains. This allows
# adding new unique terrain types to data/terrains.json without changing
# this code — the function itself iterates over all such types.
static func _get_unique_terrain_ids() -> Array:
    var unique_ids = []
    for terrain_id in GameData.terrains.keys():
        var t: Dictionary = GameData.terrains[terrain_id]
        if t.get("unique", false):
            unique_ids.append(terrain_id)
    return unique_ids

# Computes the number of Voronoi centres for each terrain type based on
# the terrain_config configuration (density + target_cluster) from data/map_config.json.
# density is the priority; target_cluster is an upper bound (the number of centres cannot
# be more than area / target_cluster). The excess of total is redistributed
# to the types without a target_cluster bound in proportion to their density.
# ONLY the types explicitly listed in terrain_config take part (see
# _get_base_terrain_ids): the others (the marsh family) are created by the post-processing.
func make_terrain_counts(rows: int, cols: int) -> Dictionary:
    var cfg: Dictionary = GameData.map_config
    var area := rows * cols

    # The global target_cluster — a fallback value for total.
    var global_cluster: int = int(cfg.get("target_cluster", 22))
    var total := maxi(12, int(round(float(area) / global_cluster)))

    var terrain_config: Dictionary = cfg.get("terrain_config", {})
    var base_ids := _get_base_terrain_ids()

    var counts: Dictionary = {}
    var weights: Dictionary = {}
    var has_cluster: Dictionary = {}

    for terrain_id in base_ids:
        var tc: Dictionary = terrain_config.get(terrain_id, {})
        var w := float(tc.get("density", 0.0))
        if w <= 0.0:
            w = _default_density(terrain_id)

        var cluster_limit := -1 # -1 = no bound is set
        if tc.has("target_cluster"):
            cluster_limit = int(tc.get("target_cluster", 0))

        weights[terrain_id] = w

        # The lower bound of "at least 1 centre" — only for the types with a positive
        # density: an explicit zero must not produce orphan centres.
        var count := int(round(total * w))
        if w > 0.0:
            count = maxi(1, count)

        if cluster_limit > 0:
            var limit := maxi(1, int(round(float(area) / cluster_limit)))
            count = mini(count, limit)
            has_cluster[terrain_id] = true
        else:
            has_cluster[terrain_id] = false
        counts[terrain_id] = count

    # Redistribution of the excess: if the sum is < total, the excess is distributed
    # to the types WITHOUT a target_cluster bound in proportion to their density.
    var sum_counts := 0
    for tid in counts.keys():
        sum_counts += counts[tid]
    if sum_counts < total:
        var deficit = total - sum_counts
        var free_types: Array = []
        var free_weight := 0.0
        for tid in base_ids:
            if not has_cluster[tid]:
                free_types.append(tid)
                free_weight += weights[tid]
        if free_weight > 0.0 and not free_types.is_empty():
            for tid in free_types:
                var add := int(round(deficit * (weights[tid] / free_weight)))
                counts[tid] += add
                deficit -= add
                if deficit <= 0:
                    break
            # We distribute the remainder one by one, until it is exhausted.
            var i := 0
            while deficit > 0:
                counts[free_types[i % free_types.size()]] += 1
                deficit -= 1
                i += 1

    return counts

# The default density for the types that are not listed in map_config.json.
func _default_density(terrain_id: String) -> float:
    match terrain_id:
        "plain":
            return 0.45
        "hill":
            return 0.25
        "lake":
            return 0.10
        "mountain":
            return 0.20
        "swamp":
            return 0.05
        _:
            return 0.05

# The post-processing after the Voronoi: it turns part of the plain hexes around
# the lakes and the seas into marshes. A ring of 1 hex wide — we iterate only
# the immediate neighbours of each lake/sea. Each such neighbour-plain
# becomes a marsh with a chance of 15% (MARSH_CHANCE). The hexes are marked
# with the temporary flag _is_marsh, so that the cover generation can then set a cover for them.
const MARSH_CHANCE := 0.15

func _apply_marshes(tile_data: Array, rows: int, cols: int) -> void:
    var lake_hexes: Array = []
    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c].get("terrain", "plain") == "lake":
                lake_hexes.append({"row": r, "col": c})

    # At the lakes: the marshes are formed on the surrounding plain (a ring around the lake).
    for water in lake_hexes:
        var neighbors = HexUtils.get_neighbors_odd_r(water.row, water.col, rows, cols)
        for n in neighbors:
            var t = tile_data[n.row][n.col]
            if t.get("terrain", "plain") != "plain":
                continue
            if randf() < MARSH_CHANCE:
                t["terrain"] = "marsh"
                t["_is_marsh"] = true

    # At the seas: the marshes on the coast (beach) are done by SeaManager — it knows
    # about its mask and flags and should not depend on the internal state
    # of map_generator. It is called AFTER the application of the sea/beach mask.
    SeaManager.apply_sea_coast_marshes(tile_data, rows, cols)

func generate_map(rows: int, cols: int, city_row: int, city_col: int, raw_res: Dictionary, terrain_counts: Dictionary) -> Array:
    var t0 = Time.get_ticks_msec()
    var tile_data = []
    for row in range(rows):
        var col_array = []
        for col in range(cols):
            col_array.append({"terrain": "plain", "cover": "none", "resource": null, "improvement": null})
        tile_data.append(col_array)

    # --- THE SEAS (the mask BEFORE Voronoi) ---
    # The sea does not take part in the Voronoi algorithm (it is not in terrain_config).
    # The sea mask is generated here and is remembered in the temporary flag _is_sea,
    # and after the Voronoi it is re-applied on top of the result (see below),
    # so that the Voronoi does not overwrite the sea/beach. The logic is entirely in SeaManager.
    var sea_mask = SeaManager.apply_sea(tile_data, rows, cols, city_row, city_col)

    # We generate the centres for the Voronoi. For the impassable terrain types
    # (the lakes and so on, move_cost >= 999) the centres must NOT get into the
    # CENTER_EXCLUSION_RADIUS around the city: thanks to the property of the diagram
    # of the Voronoi this mathematically guarantees that in this area no
    # impassable terrain will appear (the city will not end up on an island).
    var centers = []
    for terrain_id in terrain_counts.keys():
        var count = terrain_counts[terrain_id]
        var exclude_center = _is_impassable_terrain_id(terrain_id)
        for _i in range(count):
            var r = randi() % rows
            var c = randi() % cols
            if exclude_center and HexUtils.hex_distance(r, c, city_row, city_col) <= CENTER_EXCLUSION_RADIUS:
                # We iterate over the positions until we find a place outside the exclusion
                # zone (or the attempts are exhausted — then we leave it as is).
                for _try in range(50):
                    r = randi() % rows
                    c = randi() % cols
                    if HexUtils.hex_distance(r, c, city_row, city_col) > CENTER_EXCLUSION_RADIUS:
                        break
            centers.append({"r": r, "c": c, "terrain": terrain_id})

    # Jump Flood Algorithm (JFA): we build the Voronoi diagram in O(n log n)
    # instead of the naive O(n * centers). For a 200x200 map this is ~2.5 million operations
    # instead of ~73 million, which speeds up the relief generation by tens of times.
    var t_jfa = Time.get_ticks_msec()
    var voronoi = _jump_flood_voronoi(rows, cols, centers)
    print("JFA stage: ", Time.get_ticks_msec() - t_jfa, " ms")
    for row in range(rows):
        for col in range(cols):
            tile_data[row][col]["terrain"] = voronoi[row][col]

    # --- THE REPEATED APPLICATION OF THE SEA/BEACH MASK ---
    # The Voronoi filled the whole map with its relief, therefore on top of it
    # we re-apply the sea (by the flag _is_sea) and the beach (by the flag _is_beach),
    # so that they are not overwritten. It is done by SeaManager according to the flags set
    # at the apply_sea stage BEFORE the Voronoi.
    SeaManager.reapply_sea_mask(tile_data)

    # The sea islands must not consist of lakes: we replace the lakes in the land components
    # enclosed by the sea with a plain before the check of the minimum number of lakes.
    SeaManager.replace_island_lakes(tile_data, sea_mask, rows, cols)

    # We guarantee a minimum amount of lakes on the map: a lake should not disappear
    # on the too small maps or on the rare accidents of the generation of the centres.
    var lake_tiles := 0
    for row in range(rows):
        for col in range(cols):
            if tile_data[row][col]["terrain"] == "lake":
                lake_tiles += 1
    if lake_tiles < 3:
        for row in range(rows):
            for col in range(cols):
                if lake_tiles >= 3:
                    break
                if tile_data[row][col]["resource"] != null:
                    continue
                if tile_data[row][col]["terrain"] == "lake":
                    continue
                tile_data[row][col]["terrain"] = "lake"
                tile_data[row][col]["cover"] = "none"
                lake_tiles += 1
            if lake_tiles >= 3:
                break

    # --- THE MARSHES (the post-processing after the Voronoi) ---
    # Around each lake with a chance of ~40-50% the neighbouring plain hexes
    # turn into marshes — a ring 1 hex wide. Such hexes
    # are marked with the temporary flag _is_marsh, so that during the cover generation
    # they get a cover.
    _apply_marshes(tile_data, rows, cols)

    # --- THE UNIQUE TERRAIN TYPES ---
    # They are placed AFTER the Voronoi, but BEFORE the generation of the cover and the resources.
    # The universal function place_unique_terrains itself iterates over all
    # the unique terrain types (unique: true) from data/terrains.json and reads
    # the maximum cluster size (cluster_size) for each one. Each type
    # is placed once, as a cluster of 1..cluster_size hexes, outside
    # the starting Influence Ring. Adding a new unique type to
    # terrains.json does not require any change to this code.
    place_unique_terrains(tile_data, rows, cols, city_row, city_col)

    # --- THE SAFE YARD AROUND THE CITY ---
    # We forcibly turn the hexes within PLAIN_ZONE_RADIUS around the city
    # into a plain; the cover is generated as that of an ordinary plain. This guarantees
    # a free passable space for the starting construction and covers
    # the possible marshes/unique lakes that could have got into this zone.
    # It is performed AFTER the placement of the unique terrains and BEFORE the generation
    # of the cover and the resources.
    _ensure_plain_zone(tile_data, rows, cols, city_row, city_col, PLAIN_ZONE_RADIUS)

    # --- THE CLIMATE ---
    # The climate is built AFTER the relief, because the water hexes have no zone: the sea and
    # the lakes break the climate regions at the coasts. The deserts are pruned right after, while
    # the covers are still empty, and the small zone patches are dissolved before the vegetation
    # is rolled — so that the cover of a hex always belongs to the zone it ends up in.
    var climate_cfg: Dictionary = GameData.map_config.get("climate", {})
    var t_climate = Time.get_ticks_msec()
    _apply_climate(tile_data, rows, cols)
    # The zone patches are settled BEFORE the relief is turned into the varieties of the zones: a
    # dissolved patch takes the zone of its neighbours, and its terrain has to follow the new zone.
    _remove_small_zone_islands(tile_data, rows, cols, int(climate_cfg.get("min_zone_size", 3)))
    _limit_deserts(tile_data, rows, cols)
    _convert_families(tile_data, rows, cols)
    print("climate stage: ", Time.get_ticks_msec() - t_climate, " ms")

    var t_cover = Time.get_ticks_msec()
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            var zone_id := str(tile_data[row][col].get("climate", ""))
            tile_data[row][col]["cover"] = _roll_cover(terrain_id, zone_id)
    if bool(climate_cfg.get("cover_smoothing", true)):
        _smooth_covers(tile_data, rows, cols)

    # The multi-index of the free hexes by (terrain, cover) — for a fast
    # placement of the resources without a full scan of the map for each resource.
    var hex_index = _build_hex_index(tile_data, rows, cols, city_row, city_col)
    print("cover + hex_index stage: ", Time.get_ticks_msec() - t_cover, " ms")

    # --- The ordinary resources ---
    # The category is only a classification of the resource and does not determine
    # whether it should appear on the map. All the resources extracted by an improvement
    # go through a single pool and are filtered only by their allowed_* and
    # spawn_conditions.
    var regular_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("improved_by", null) == null or r.get("improved_by", "") == "":
            continue
        regular_resources[rid] = r
    _place_resources(tile_data, regular_resources, rows, cols, city_row, city_col, hex_index)

    # --- The one-off (gatherable) resources ---
    # The metal nuggets and the analogous resources with improved_by == null:
    # they spawn across the WHOLE map at the start of the game, like the wild plants. The number
    # of specimens is taken from spawn_count, the output on gathering — from produces.
    # The wild plants (wild_food) are placed separately (see place_wild_food).
    place_one_time_resources(tile_data, raw_res, rows, cols, city_row, city_col, hex_index)

    # --- All the resources spawn at the start, including tech_required and tech_reveal ---
    # Previously the resources with tech_required were filtered here and spawned
    # lazily through CityData.spawn_resource_on_tech_research. Now they
    # appear on the map right away, and the visibility/extraction is regulated by the fields
    # tech_reveal (visibility) and tech_required (the building of the improvement).
    # See docs.md, the section "tech_reveal: hidden resources".

    # --- THE GUARANTEE OF A WAY OUT ---
    # A safety check: if despite the ban on the lake centres the city has still
    # been isolated by an impassable terrain, we lay a corridor of a plain
    # to the outside world. It is performed at the very end, so as to take into account all the already
    # placed marshes and unique lakes.
    _ensure_outward_corridor(tile_data, rows, cols, city_row, city_col)

    print("generate_map stage: ", Time.get_ticks_msec() - t0, " ms")
    return tile_data

# The universal function that places all the unique terrain types on the map.
# It iterates over all the types with "unique": true in data/terrains.json and for each one
# places ONE connected cluster of 1..cluster_size hexes outside
# the limits of the starting Influence Ring. The maximum cluster size is read
# from the "cluster_size" field of the terrain data (the default is 3, if the field is not set).
# Adding a new unique type to terrains.json does not require any change to the code.
func place_unique_terrains(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> void:
    # The bounds of the starting Influence Ring from the configuration.
    var cfg: Dictionary = GameData.map_config
    var ring_rows: int = int(cfg.get("start_ring_rows", 5))
    var ring_cols: int = int(cfg.get("start_ring_cols", 7))
    var inf_start_row: int = int(floor(city_row - ring_rows / 2.0))
    var inf_end_row: int = inf_start_row + ring_rows - 1
    var inf_start_col: int = int(floor(city_col - ring_cols / 2.0))
    var inf_end_col: int = inf_start_col + ring_cols - 1

    # We collect all the hexes outside the Ring that are not occupied by the city.
    var candidates: Array = []
    for r in range(rows):
        for c in range(cols):
            if r >= inf_start_row and r <= inf_end_row and c >= inf_start_col and c <= inf_end_col:
                continue
            if r == city_row and c == city_col:
                continue
            candidates.append({"row": r, "col": c})
    if candidates.is_empty():
        print("ERROR place_unique_terrains: there are no hexes outside the Influence Ring!")
        return

    for terrain_type in _get_unique_terrain_ids():
        var t: Dictionary = GameData.terrains[terrain_type]
        var max_cluster_size: int = int(t.get("cluster_size", 3))

        # A random cluster size from 1 to max_cluster_size.
        var cluster_size: int = randi_range(1, maxi(1, max_cluster_size))

        # A random start point within the allowed area.
        var start = candidates[randi() % candidates.size()]

        # BFS: we build a connected cluster of cluster_size hexes adjacent to the start.
        var cluster: Array = [start]
        var visited := {}
        visited["%d,%d" % [start.row, start.col]] = true
        var frontier: Array = [start]
        while cluster.size() < cluster_size and frontier.size() > 0:
            var next_frontier: Array = []
            for hex in frontier:
                var neighbors = HexUtils.get_neighbors_odd_r(hex.row, hex.col, rows, cols)
                neighbors.shuffle()
                for n in neighbors:
                    var key = "%d,%d" % [n.row, n.col]
                    if visited.has(key):
                        continue
                    if n.row >= inf_start_row and n.row <= inf_end_row and n.col >= inf_start_col and n.col <= inf_end_col:
                        continue
                    if n.row == city_row and n.col == city_col:
                        continue
                    visited[key] = true
                    cluster.append(n)
                    next_frontier.append(n)
                    if cluster.size() >= cluster_size:
                        break
                if cluster.size() >= cluster_size:
                    break
            frontier = next_frontier

        # We change the terrain to the unique one for the chosen hexes (only if there is no improvement there).
        for hex in cluster:
            var tile = tile_data[hex.row][hex.col]
            if tile.get("improvement", null) == null:
                tile["terrain"] = terrain_type
                tile["cover"] = _roll_cover(terrain_type)

        print("The unique terrain type %s is placed: %d hexes" % [terrain_type, cluster.size()])

# The Jump Flood Algorithm (JFA) for building the Voronoi diagram on
# a hexagonal grid (odd-r). The complexity is O(rows * cols * log2(max(rows, cols)))
# instead of the naive O(rows * cols * centers.size()).
# It returns a 2D array of terrain_id for each cell.
func _jump_flood_voronoi(rows: int, cols: int, centers: Array) -> Array:
    # The grid of the indices of the nearest centres (-1 = empty).
    var grid = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(-1)
        grid.append(row_arr)

    # We precompute the q-coordinates of the centres (for a fast hex_distance).
    var center_q = []
    for ci in range(centers.size()):
        var center = centers[ci]
        center_q.append(center.c - ((center.r - (center.r & 1)) >> 1))

    # We place the centres on the grid.
    for ci in range(centers.size()):
        var center = centers[ci]
        grid[center.r][center.c] = ci

    # The initial step: the largest power of two not exceeding max(rows, cols).
    var max_dim = maxi(rows, cols)
    var step = 1
    while step * 2 <= max_dim:
        step *= 2

    # The 8 directions of the JFA (a rectangular template).
    var dirs = [
        Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1),
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1)
    ]

    # Double buffering (ping-pong), so that the information spreads
    # exactly by one "jump" per iteration.
    var read_grid = grid
    var write_grid = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(-1)
        write_grid.append(row_arr)

    while step >= 1:
        for r in range(rows):
            var q_base = (r - (r & 1)) >> 1
            for c in range(cols):
                var q = c - q_base
                var best_ci = read_grid[r][c]
                var best_dist = INF
                if best_ci >= 0:
                    var cr = centers[best_ci].r
                    var cq = center_q[best_ci]
                    best_dist = (abs(q - cq) + abs(r - cr) + abs((q + r) - (cq + cr))) >> 1
                for d in dirs:
                    var nr = r + d.x * step
                    var nc = c + d.y * step
                    if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
                        continue
                    var neighbor_ci = read_grid[nr][nc]
                    if neighbor_ci < 0:
                        continue
                    var ncr = centers[neighbor_ci].r
                    var ncq = center_q[neighbor_ci]
                    var dist3 = (abs(q - ncq) + abs(r - ncr) + abs((q + r) - (ncq + ncr))) >> 1
                    if dist3 < best_dist:
                        best_dist = dist3
                        best_ci = neighbor_ci
                write_grid[r][c] = best_ci
        # We swap the buffers.
        var tmp = read_grid
        read_grid = write_grid
        write_grid = tmp
        step >>= 1

    # The final pass over the 6 hexagonal neighbours: it removes the artefacts
    # of the rectangular JFA template and brings the boundaries to the hexagonal metric.
    var even_dirs = [
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(-1, -1), Vector2i(-1, 0),
        Vector2i(1, -1), Vector2i(1, 0)
    ]
    var odd_dirs = [
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(-1, 0), Vector2i(-1, 1),
        Vector2i(1, 0), Vector2i(1, 1)
    ]
    for r in range(rows):
        var rdirs = even_dirs if r % 2 == 0 else odd_dirs
        var q_base = (r - (r & 1)) >> 1
        for c in range(cols):
            var q = c - q_base
            var best_ci = read_grid[r][c]
            var best_dist = INF
            if best_ci >= 0:
                var cr = centers[best_ci].r
                var cq = center_q[best_ci]
                best_dist = (abs(q - cq) + abs(r - cr) + abs((q + r) - (cq + cr))) >> 1
            for d in rdirs:
                var nr = r + d.x
                var nc = c + d.y
                if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
                    continue
                var nb_ci = read_grid[nr][nc]
                if nb_ci < 0:
                    continue
                var nc_r = centers[nb_ci].r
                var nc_q = center_q[nb_ci]
                var dist4 = (abs(q - nc_q) + abs(r - nc_r) + abs((q + r) - (nc_q + nc_r))) >> 1
                if dist4 < best_dist:
                    best_dist = dist4
                    best_ci = nb_ci
            read_grid[r][c] = best_ci

    # We turn the centre indices into terrain_id.
    var result = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        for c in range(cols):
            var ci = read_grid[r][c]
            row_arr[c] = centers[ci].terrain if ci >= 0 else "plain"
        result.append(row_arr)
    return result

# Returns true if the terrain type is impassable (move_cost >= 999).
# Such types (the lakes: lake, soda_lake, asphalt_lake, salt_lake) block
# the movement of the city outwards.
func _is_impassable_terrain_id(terrain_id: String) -> bool:
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    return int(t.get("move_cost", 1)) >= 999

# Returns true if the hex (row, col) is impassable.
func _is_impassable_hex(tile_data: Array, row: int, col: int) -> bool:
    var terrain_id = tile_data[row][col].get("terrain", "plain")
    return _is_impassable_terrain_id(terrain_id)

# Forcibly turns all the hexes within the radius `radius` around the city
# into a plain without a cover. It resets the temporary flag _is_marsh.
# It is called AFTER the placement of the unique terrains and BEFORE the climate, so that the zone
# is completely "clean": the hex becomes the plain of the climate belt it stands in, and its cover
# is rolled later, together with the cover of every other hex.
func _ensure_plain_zone(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int, radius: int) -> void:
    for r in range(rows):
        for c in range(cols):
            if HexUtils.hex_distance(r, c, city_row, city_col) <= radius:
                var tile = tile_data[r][c]
                tile["terrain"] = "plain"
                tile["_is_marsh"] = false
                tile["_is_sea"] = false
                tile["_is_shallow_sea"] = false
                tile["_is_beach"] = false

# Guarantees that the city has a path to the edge of the map (to the "outside world").
# If the city has turned out to be isolated by an impassable terrain (a lake or the sea),
# the BFS function over the impassable hexes lays the shortest corridor from
# the reachable area of the city to the nearest outer passable hex and
# turns this corridor into a plain. The sea is not an obstacle for the breakthrough
# (as is a lake), and the coast (beach, move_cost: 1) is a valid exit.
# It repeats until the city gets an exit to the edge of the map
# (or until it hits the limit of the iterations).
func _ensure_outward_corridor(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int) -> void:
    for _iter in range(10):
        # 1) The area reachable from the city over the passable hexes.
        var reachable := {}
        var key_city = "%d,%d" % [city_row, city_col]
        reachable[key_city] = true
        var queue: Array = [ {"row": city_row, "col": city_col}]
        while queue.size() > 0:
            var cur = queue.pop_front()
            for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, rows, cols):
                var nk = "%d,%d" % [n.row, n.col]
                if reachable.has(nk):
                    continue
                if _is_impassable_hex(tile_data, n.row, n.col):
                    continue
                reachable[nk] = true
                queue.append(n)

        # 2) If the city has reached a passable edge of the map — the exit exists.
        if _has_exit_to_edge(reachable, rows, cols):
            return

        # 3) We look for a water way from the reachable area to the nearest outer
        #    passable hex. The BFS starts from all the impassable neighbours of A.
        var from := {}
        var water_queue: Array = []
        for key in reachable:
            var parts = key.split(",")
            var r = int(parts[0])
            var c = int(parts[1])
            for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                var nk = "%d,%d" % [n.row, n.col]
                if reachable.has(nk):
                    continue
                if not _is_impassable_hex(tile_data, n.row, n.col):
                    continue
                if not from.has(nk):
                    from[nk] = key
                    water_queue.append({"row": n.row, "col": n.col})

        var target_key := ""
        var qi := 0
        while qi < water_queue.size() and target_key == "":
            var cur = water_queue[qi]
            qi += 1
            var ck = "%d,%d" % [cur.row, cur.col]
            for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, rows, cols):
                var nk = "%d,%d" % [n.row, n.col]
                if from.has(nk):
                    continue
                if _is_impassable_hex(tile_data, n.row, n.col):
                    from[nk] = ck
                    water_queue.append({"row": n.row, "col": n.col})
                else:
                    if not reachable.has(nk):
                        target_key = nk
                        from[nk] = ck
                        break

        if target_key == "":
            # We have not found an outer passable hex (the whole world is water/islands).
            # We lay a corridor directly to the edge of the map through the water.
            if not _punch_corridor_to_edge(tile_data, rows, cols, city_row, city_col, reachable):
                return

        # 4) We restore the path: the impassable hexes are turned into a plain.
        if target_key != "":
            var step = target_key
            while true:
                var prev = from.get(step, "")
                if prev == "":
                    break
                if reachable.has(prev):
                    break
                _punch_hex(tile_data, prev)
                step = prev

# Returns true if at least one hex of the reachable area is on the edge of the map.
func _has_exit_to_edge(reachable: Dictionary, rows: int, cols: int) -> bool:
    for r in [0, rows - 1]:
        for c in range(cols):
            if reachable.has("%d,%d" % [r, c]):
                return true
    for c in [0, cols - 1]:
        for r in range(rows):
            if reachable.has("%d,%d" % [r, c]):
                return true
    return false

# Turns the hex (key "r,c") into a plain without a cover.
# It is used for laying the exit corridor through the impassable hexes
# (the lakes and the seas). It resets the temporary flags _is_marsh and _is_sea.
# The corridor is laid after the climate, so the plain is resolved through the zone of the hex:
# a corridor through the boreal zone is a boreal plain, not a green plain in the middle of the north.
func _punch_hex(tile_data: Array, key: String) -> void:
    var parts = key.split(",")
    var r = int(parts[0])
    var c = int(parts[1])
    var tile = tile_data[r][c]
    var zone_id := str(tile.get("climate", ""))
    var terrain_id := GameData.zone_terrain(zone_id, "plain")
    tile["terrain"] = terrain_id if terrain_id != "" else "plain"
    # The cover is generated as that of an ordinary plain for a natural look.
    tile["cover"] = _roll_cover(tile["terrain"], zone_id)
    tile["_is_marsh"] = false
    tile["_is_sea"] = false
    tile["_is_shallow_sea"] = false

# Lays a corridor from the reachable area directly to the edge of the map through
# the impassable hexes. It returns true if the corridor has been laid.
func _punch_corridor_to_edge(tile_data: Array, rows: int, cols: int,
        _city_row: int, _city_col: int, reachable: Dictionary) -> bool:
    var from := {}
    var queue: Array = []
    for key in reachable:
        var parts = key.split(",")
        var r = int(parts[0])
        var c = int(parts[1])
        for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
            var nk = "%d,%d" % [n.row, n.col]
            if reachable.has(nk):
                continue
            if not _is_impassable_hex(tile_data, n.row, n.col):
                continue
            if not from.has(nk):
                from[nk] = key
                queue.append({"row": n.row, "col": n.col})
    var qi := 0
    var target_key := ""
    while qi < queue.size() and target_key == "":
        var cur = queue[qi]
        qi += 1
        var ck = "%d,%d" % [cur.row, cur.col]
        if cur.row == 0 or cur.row == rows - 1 or cur.col == 0 or cur.col == cols - 1:
            target_key = ck
            break
        for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, rows, cols):
            var nk = "%d,%d" % [n.row, n.col]
            if from.has(nk):
                continue
            if not _is_impassable_hex(tile_data, n.row, n.col):
                continue
            from[nk] = ck
            queue.append({"row": n.row, "col": n.col})
    if target_key == "":
        return false
    # We lay the path from the target edge impassable cell back to A.
    var step = target_key
    while true:
        _punch_hex(tile_data, step)
        var prev = from.get(step, "")
        if prev == "" or reachable.has(prev):
            break
        step = prev
    return true

# --- CLIMATE ---
#
# The climate decides what a hex is made of and what grows on it. There is no separate "biome"
# layer: a plain is never a plain on the map, it is one of its VARIETIES — a tundra plain, a boreal
# plain, a steppe, a prairie, a savanna or a tropical plain (data/terrains/terrains.json) — and the
# vegetation is a cover on top of it (data/covers.json). The wetland is divided the same way, only
# into fewer varieties: a swamp is a family whose zones name a shared record wherever the bogs of
# two belts do not differ.
#
# Two independent fields decide the variety:
#
#   temperature — belts running from the poles to the equator. The equator sits on a random row
#     (the "climate" block of data/map_config.json), so the city in the middle of the map lands
#     on a different latitude from game to game and the belts are built around it. The belts are
#     ordered polar → cold → mild → subtropical → tropical → subtropical → mild → cold → polar,
#     and the order is never broken: the temperature row of a hex is shifted by a smooth noise
#     field, but the shift is clamped so that the row never decreases down a column and never
#     grows faster than MAX_TEMPERATURE_STEP rows per row. Therefore two hexes of the same
#     latitude are never more than one belt apart — a tropical plain and a tundra plain cannot
#     meet sideways.
#
#   moisture — a smooth noise field that does not follow the latitudes at all. Wet and dry regions
#     lie anywhere, curve and surround each other, and they split every temperature belt in two
#     (the steppe and the prairie, the dry and the wet savanna, …).
#
# The polar belt is measured not from the equator but from the map edge: it is the outer part of
# the cold region of every column ("polar_share" of data/map_config.json), so the tundra reaches
# the pole whatever latitude the equator was rolled on, and the taiga keeps the inner part of the
# cold region. No wooded cover grows in the tundra, so the taiga never spreads into it.
#
# A pair (temperature, humidity) selects a climate zone (data/climate.json), and the zone says
# which variety every family becomes and what grows on it. The zone id is stored in the
# tile ("climate"): the runtime asks it whenever it has to turn a family into a terrain after the
# generation (a drained swamp, a corridor). The player never sees the zone — only the terrain and
# the cover.

const TEMPERATURE_POLAR := "polar"
const TEMPERATURE_COLD := "cold"
const TEMPERATURE_MILD := "mild"
const TEMPERATURE_SUBTROPICAL := "subtropical"
const TEMPERATURE_TROPICAL := "tropical"
const HUMIDITY_WET := "wet"
const HUMIDITY_DRY := "dry"

# The families the climate turns into the varieties of its zone: the relief (a plain becomes a
# tundra plain, a boreal plain, a steppe, a prairie, a savanna, a tropical plain) and the wetlands
# (a swamp becomes the bog of its belt, a marsh becomes the mudflat of its belt). The water and
# the deserts have no family and the climate leaves them alone.
const CLIMATE_FAMILIES := ["plain", "hill", "mountain", "swamp", "marsh"]

# The largest growth of the temperature row from one row to the next. It has to stay below the
# height of the narrowest belt, otherwise one step could jump over it and put a cold hex next to
# a tropical one.
const MAX_TEMPERATURE_STEP := 1.5

# The cold belt that the climate meander may never eat: the map keeps a polar edge on both sides.
const MIN_COLD_ROWS := 3.0

# The noise is hashed from the integer lattice: the field depends only on its own salt, so it does
# not consume the global RNG and does not shift the random sequence of the rest of the generation.
static func _hash01(ix: int, iy: int, salt: int) -> float:
    var h: int = (ix * 73856093) ^ (iy * 19349663) ^ (salt * 83492791)
    h = h & 0x7FFFFFFF
    h = (h ^ (h >> 13)) * 1274126177
    h = h & 0x7FFFFFFF
    h = h ^ (h >> 16)
    return float(h & 0xFFFF) / 65535.0

static func _value_noise(x: float, y: float, salt: int) -> float:
    var x0 := int(floor(x))
    var y0 := int(floor(y))
    var fx := x - float(x0)
    var fy := y - float(y0)
    var sx := fx * fx * (3.0 - 2.0 * fx)
    var sy := fy * fy * (3.0 - 2.0 * fy)
    var top := lerpf(_hash01(x0, y0, salt), _hash01(x0 + 1, y0, salt), sx)
    var bottom := lerpf(_hash01(x0, y0 + 1, salt), _hash01(x0 + 1, y0 + 1, salt), sx)
    return lerpf(top, bottom, sy)

# Fractal noise: a few octaves of the value noise, each one weaker (persistence) and twice as fine.
# A lower persistence keeps the field smooth, which the moisture needs: the fine octaves alone
# would tear the boundary between a wet and a dry region into specks.
static func _fbm(x: float, y: float, salt: int, octaves: int, persistence: float = 0.5) -> float:
    var total := 0.0
    var weight := 0.0
    var amplitude := 1.0
    var frequency := 1.0
    for octave in range(octaves):
        total += _value_noise(x * frequency, y * frequency, salt + octave * 101) * amplitude
        weight += amplitude
        amplitude *= persistence
        frequency *= 2.0
    return total / weight if weight > 0.0 else 0.0

# Builds the climate of the map: the zone of every land hex and the terrain of its relief.
# The water (the sea, the shallow sea and the lakes) gets no zone: it has no vegetation and no
# climate of its own, and it breaks the climate regions at the coasts.
func _apply_climate(tile_data: Array, rows: int, cols: int) -> void:
    for r in range(rows):
        for c in range(cols):
            tile_data[r][c]["climate"] = ""

    if GameData.climate_zones.is_empty():
        return
    var cfg: Dictionary = GameData.map_config.get("climate", {})
    if cfg.is_empty():
        return

    var tropical_half := maxf(2.0, float(rows) * float(cfg.get("tropical_half_rows", 0.08)))
    var subtropical := maxf(2.0, float(rows) * float(cfg.get("subtropical_rows", 0.06)))
    var mild := maxf(2.0, float(rows) * float(cfg.get("mild_rows", 0.10)))
    var belt := tropical_half + subtropical + mild
    var equator := _roll_equator_row(rows, cfg)
    var temperature_rows := _temperature_rows(rows, cols, cfg, equator, belt)

    var moisture_scale := maxf(2.0, float(mini(rows, cols)) * float(cfg.get("moisture_scale", 0.26)))
    var moisture_threshold := float(cfg.get("moisture_threshold", 0.5))
    var moisture_salt := randi()

    # The polar belt of every column: the outer share of its cold region. It is measured from the
    # edge row of the column, so the meander of the boundary can never pull the tundra off the pole.
    var polar_share := clampf(float(cfg.get("polar_share", 0.3)), 0.0, 1.0)
    var polar_bounds: Array = []
    for c in range(cols):
        var top := float(temperature_rows[0][c])
        var bottom := float(temperature_rows[rows - 1][c])
        var cold_top := maxf(0.0, equator - belt - top)
        var cold_bottom := maxf(0.0, bottom - equator - belt)
        polar_bounds.append([top + cold_top * polar_share, bottom - cold_bottom * polar_share])

    var lookup := _zone_lookup()
    for r in range(rows):
        for c in range(cols):
            if _is_impassable_terrain_id(tile_data[r][c].get("terrain", "")):
                continue
            var temperature_row := float(temperature_rows[r][c])
            var distance: float = absf(temperature_row - equator)
            var temperature := TEMPERATURE_TROPICAL
            if distance > tropical_half:
                if distance <= tropical_half + subtropical:
                    temperature = TEMPERATURE_SUBTROPICAL
                elif distance <= belt:
                    temperature = TEMPERATURE_MILD
                else:
                    temperature = TEMPERATURE_COLD
            var polar: Array = polar_bounds[c]
            if temperature_row <= float(polar[0]) or temperature_row >= float(polar[1]):
                temperature = TEMPERATURE_POLAR
            var moisture := _fbm(float(r) / moisture_scale, float(c) / moisture_scale, moisture_salt, 2, 0.35)
            var humidity := HUMIDITY_WET if moisture >= moisture_threshold else HUMIDITY_DRY
            tile_data[r][c]["climate"] = _pick_zone(lookup, temperature, humidity)

# Turns the families the Voronoi placed into the varieties of their climate zone: every plain
# becomes the plain of its belt (a tundra plain, a boreal plain, a steppe, a prairie, a savanna, a
# tropical plain), the same for the hills and the mountains, the swamp becomes the bog of its
# belt and the marsh becomes the mudflat of its belt. The water and the deserts have no family
# and stay as they are.
func _convert_families(tile_data: Array, rows: int, cols: int) -> void:
    for r in range(rows):
        for c in range(cols):
            var tile = tile_data[r][c]
            var family := str(tile.get("terrain", ""))
            if not CLIMATE_FAMILIES.has(family):
                continue
            var terrain_id := GameData.zone_terrain(str(tile.get("climate", "")), family)
            if terrain_id != "":
                tile["terrain"] = terrain_id

# The row of the equator. The range of the roll keeps the full sequence of the belts on the map:
# with the equator too close to an edge, the cold belt of that side would disappear.
func _roll_equator_row(rows: int, cfg: Dictionary) -> float:
    var low := clampf(float(cfg.get("equator_min", 0.33)), 0.0, 1.0)
    var high := clampf(float(cfg.get("equator_max", 0.67)), low, 1.0)
    return float(rows - 1) * randf_range(low, high)

# The temperature row of every hex: its own row shifted by the climate meander.
# Down a column the value only grows and never jumps by more than MAX_TEMPERATURE_STEP, so the
# belts keep their order; the horizontal average that follows cannot break it either, because
# an average of monotone columns is monotone itself.
func _temperature_rows(rows: int, cols: int, cfg: Dictionary, equator: float, belt: float) -> Array:
    var amplitude := float(cfg.get("warp_rows", 3.0))
    var scale := maxf(2.0, float(mini(rows, cols)) * float(cfg.get("warp_scale", 0.2)))
    var salt := randi()

    # The meander must not eat the cold belt of the near side: with the equator pushed towards an
    # edge, the shift is reduced, so that at least MIN_COLD_ROWS cold rows stay above (below) it.
    var room := minf(equator, float(rows - 1) - equator) - belt - MIN_COLD_ROWS
    amplitude = clampf(amplitude, 0.0, maxf(0.0, room))

    var grid: Array = []
    for r in range(rows):
        var line: Array = []
        for c in range(cols):
            var warp := (_fbm(float(r) / scale, float(c) / scale, salt, 2) - 0.5) * 2.0 * amplitude
            line.append(float(r) + warp)
        grid.append(line)

    for c in range(cols):
        for r in range(1, rows):
            var previous: float = grid[r - 1][c]
            grid[r][c] = clampf(grid[r][c], previous, previous + MAX_TEMPERATURE_STEP)

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
    var edge := maxi(1, int(MIN_COLD_ROWS))
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

# The pairs (temperature, humidity) → the zone id. The first zone of a pair wins, so a mod that
# adds a second zone for an occupied pair has to override the vanilla record instead.
func _zone_lookup() -> Dictionary:
    var lookup: Dictionary = {}
    for zone_id in GameData.climate_zones.keys():
        var zone: Dictionary = GameData.climate_zones[zone_id]
        var key := "%s|%s" % [str(zone.get("temperature", "")), str(zone.get("humidity", ""))]
        if not lookup.has(key):
            lookup[key] = zone_id
    return lookup

# A pair with no zone is a data problem (data_validator reports it): the generator falls back to
# any zone of the same temperature, so that a mod that removes a record does not strip the map of
# its climate.
func _pick_zone(lookup: Dictionary, temperature: String, humidity: String) -> String:
    var key := "%s|%s" % [temperature, humidity]
    if lookup.has(key):
        return lookup[key]
    for other_key in lookup.keys():
        if str(other_key).begins_with(temperature + "|"):
            return lookup[other_key]
    return str(lookup.values()[0]) if not lookup.is_empty() else ""

# The deserts are a relief of the zones that allow them (data/climate.json → "deserts": the hot dry
# belts). Outside them the deserts are levelled into the plain of their zone: a sandy desert in the
# middle of the boreal zone would contradict the climate the player sees.
func _limit_deserts(tile_data: Array, rows: int, cols: int) -> void:
    if GameData.climate_zones.is_empty():
        return
    for r in range(rows):
        for c in range(cols):
            var tile = tile_data[r][c]
            var terrain_id := str(tile.get("terrain", ""))
            if terrain_id != "sandy_desert" and terrain_id != "rocky_desert":
                continue
            var zone_id := str(tile.get("climate", ""))
            if bool(GameData.get_climate_zone(zone_id).get("deserts", false)):
                continue
            var plain := GameData.zone_terrain(zone_id, "plain")
            if plain != "":
                tile["terrain"] = plain

# Dissolves the zone patches smaller than min_size land hexes into the zone that dominates their
# boundary, so that the map reads as large regions instead of a scatter of cells. The specks are
# taken in CLUSTERS: two touching specks of different zones are merged into the zone around them
# together, otherwise they would only exchange zones and stay specks. An island with no land
# neighbours keeps a single zone of its own: there is nothing to merge it with.
func _remove_small_zone_islands(tile_data: Array, rows: int, cols: int, min_size: int) -> void:
    if min_size <= 1:
        return

    var visited: Array = []
    for _r in range(rows):
        var line: Array = []
        line.resize(cols)
        line.fill(false)
        visited.append(line)

    var small: Dictionary = {}
    for r in range(rows):
        for c in range(cols):
            if visited[r][c]:
                continue
            var zone_id := str(tile_data[r][c].get("climate", ""))
            if zone_id == "":
                visited[r][c] = true
                continue

            var cells: Array = []
            var stack: Array = [Vector2i(r, c)]
            visited[r][c] = true
            while not stack.is_empty():
                var cell: Vector2i = stack.pop_back()
                cells.append(cell)
                for neighbour in HexUtils.get_neighbors_odd_r(cell.x, cell.y, rows, cols):
                    if visited[neighbour.row][neighbour.col]:
                        continue
                    if str(tile_data[neighbour.row][neighbour.col].get("climate", "")) != zone_id:
                        continue
                    visited[neighbour.row][neighbour.col] = true
                    stack.append(Vector2i(neighbour.row, neighbour.col))

            if cells.size() >= min_size:
                continue
            for cell in cells:
                small[cell] = true

    var merged: Dictionary = {}
    for r in range(rows):
        for c in range(cols):
            var start := Vector2i(r, c)
            if not small.has(start) or merged.has(start):
                continue
            var cluster: Array = []
            var members: Dictionary = {}
            var stack: Array = [start]
            merged[start] = true
            members[start] = true
            while not stack.is_empty():
                var cell: Vector2i = stack.pop_back()
                cluster.append(cell)
                for neighbour in HexUtils.get_neighbors_odd_r(cell.x, cell.y, rows, cols):
                    var key := Vector2i(neighbour.row, neighbour.col)
                    if not small.has(key) or merged.has(key):
                        continue
                    merged[key] = true
                    members[key] = true
                    stack.append(key)
            var target := _dominant_neighbour_zone(tile_data, rows, cols, members, cluster)
            if target == "":
                # An island: nothing around it to merge into, so it keeps one zone instead of
                # being split between the specks it is made of.
                target = _dominant_zone_of_cells(tile_data, cluster)
            if target != "":
                for cell in cluster:
                    tile_data[cell.x][cell.y]["climate"] = target

# The zone that surrounds a cluster of specks: the most frequent one among the land neighbours of
# its hexes that are not a part of the cluster. Ties are broken by the id, so that the result does
# not depend on the dictionary order.
func _dominant_neighbour_zone(tile_data: Array, rows: int, cols: int, members: Dictionary,
        cells: Array) -> String:
    var counts: Dictionary = {}
    for cell in cells:
        for neighbour in HexUtils.get_neighbors_odd_r(cell.x, cell.y, rows, cols):
            if members.has(Vector2i(neighbour.row, neighbour.col)):
                continue
            var zone_id := str(tile_data[neighbour.row][neighbour.col].get("climate", ""))
            if zone_id == "":
                continue
            counts[zone_id] = int(counts.get(zone_id, 0)) + 1
    return _most_frequent(counts)

# The most frequent zone of the hexes themselves — for an island, which has no zone around it.
func _dominant_zone_of_cells(tile_data: Array, cells: Array) -> String:
    var counts: Dictionary = {}
    for cell in cells:
        var zone_id := str(tile_data[cell.x][cell.y].get("climate", ""))
        if zone_id == "":
            continue
        counts[zone_id] = int(counts.get(zone_id, 0)) + 1
    return _most_frequent(counts)

func _most_frequent(counts: Dictionary) -> String:
    var best := ""
    var best_count := 0
    for zone_id in counts.keys():
        var count: int = counts[zone_id]
        if count > best_count or (count == best_count and str(zone_id) < best):
            best = str(zone_id)
            best_count = count
    return best

# The wooded cover a zone fills the holes in its woods with: the heaviest cover of its pool that
# yields timber. An empty string means the zone has no woods at all.
func _wooded_cover_of_zone(zone_id: String) -> String:
    var chances: Dictionary = GameData.get_climate_zone(zone_id).get("cover_chance", {})
    var best := ""
    var best_weight := 0.0
    for cover_id in chances.keys():
        var cover: Dictionary = GameData.covers.get(cover_id, {})
        if float(cover.get("wood_yield", 0)) <= 0.0:
            continue
        var weight := float(chances[cover_id])
        if weight > best_weight:
            best = str(cover_id)
            best_weight = weight
    return best

# Clears the lone wooded hexes and fills the lone holes in the woods of the plains and hills.
# The cover of every hex is rolled on its own, which gives a scatter of cells; this pass makes the
# woods read as groves. Both changes are computed from the same snapshot and applied afterwards,
# so the result does not depend on the traversal order.
func _smooth_covers(tile_data: Array, rows: int, cols: int) -> void:
    var wooded: Array = []
    for r in range(rows):
        var line: Array = []
        for c in range(cols):
            line.append(_is_wooded_hex(tile_data[r][c]))
        wooded.append(line)

    var changes: Array = []
    for r in range(rows):
        for c in range(cols):
            var tile = tile_data[r][c]
            var family := GameData.terrain_family(str(tile.get("terrain", "")))
            if family != "plain" and family != "hill":
                continue
            var wooded_neighbours := 0
            var land_neighbours := 0
            for neighbour in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                if _is_impassable_terrain_id(tile_data[neighbour.row][neighbour.col].get("terrain", "")):
                    continue
                land_neighbours += 1
                if wooded[neighbour.row][neighbour.col]:
                    wooded_neighbours += 1
            if land_neighbours == 0:
                continue
            if wooded[r][c] and wooded_neighbours == 0:
                changes.append({"row": r, "col": c, "cover": "none"})
            elif not wooded[r][c] and wooded_neighbours >= land_neighbours - 1 and land_neighbours >= 5:
                var filler := _wooded_cover_of_zone(str(tile.get("climate", "")))
                if filler != "":
                    changes.append({"row": r, "col": c, "cover": filler})

    for change in changes:
        tile_data[change.row][change.col]["cover"] = change.cover

func _is_wooded_hex(tile: Dictionary) -> bool:
    var cover: Dictionary = GameData.covers.get(tile.get("cover", "none"), {})
    return float(cover.get("wood_yield", 0)) > 0.0

# Rolls the cover of a hex. A terrain that carries a cover_chance of its own rolls on it — the
# wetlands and the deserts keep their own vegetation, so a swamp of the tropics is a reed bed and a
# swamp of the tundra is moss, whatever grows around them. Every other terrain is a variety of a
# family, and the varieties of a family share the vegetation of their climate zone, so a whole
# region gets one coherent character (a prairie region is mostly grass with groves, a tropical one
# is mostly forest with clearings).
func _roll_cover(terrain_id: String, zone_id: String = "") -> String:
    var chances: Dictionary = GameData.terrains.get(terrain_id, {}).get("cover_chance", {})
    if chances.is_empty() and zone_id != "":
        chances = GameData.get_climate_zone(zone_id).get("cover_chance", {})
    if chances.is_empty():
        return "none"
    var total := 0.0
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

# Builds a multi-index of the free hexes by (terrain, cover).
# The key: "terrain|cover" -> Array of dictionaries {"row", "col"}.
# A hex is indexed TWICE when its terrain belongs to a family: under its own id
# ("boreal_plain|taiga") and under the family ("plain|taiga"). A rule of the data may therefore
# name either the exact terrain or the family — allowed_terrain ["plain"] finds all six varieties
# of the plain, allowed_terrain ["swamp"] every swamp, allowed_terrain ["boreal_plain"] only the
# boreal plain (see GameData.terrain_matches).
# The hexes near the city (abs <= 1) are excluded, so as not to interfere with
# the starting construction (as in the original _place_resources).
func _build_hex_index(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> Dictionary:
    var index: Dictionary = {}
    for r in range(rows):
        for c in range(cols):
            if abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var terrain_id = str(tile.get("terrain", ""))
            var cover_id = tile.get("cover", "none")
            for name in _index_names(terrain_id):
                var key = "%s|%s" % [name, cover_id]
                if not index.has(key):
                    index[key] = []
                index[key].append({"row": r, "col": c})
    return index

# The names a hex is indexed by: its terrain and, for a variety of a family, its family.
func _index_names(terrain_id: String) -> Array:
    var names: Array = [terrain_id]
    var family := GameData.terrain_family(terrain_id)
    if family != "" and family != terrain_id:
        names.append(family)
    return names

# Whether the terrain of a hex satisfies the allowed_terrain list of a rule. The list may name the
# exact terrain ("boreal_plain") or a family ("plain" — all six varieties of the plain, "swamp" —
# every swamp).
func _terrain_allowed(terrain_id: String, data: Dictionary) -> bool:
    for reference in data.get("allowed_terrain", []):
        if GameData.terrain_matches(terrain_id, str(reference)):
            return true
    return false

# Whether the climate zone of a hex satisfies the allowed_climate_zones list of a rule.
# An empty or missing list means "any zone".
func _climate_allowed(tile: Dictionary, data: Dictionary) -> bool:
    var zones: Array = data.get("allowed_climate_zones", [])
    if zones.is_empty():
        return true
    return str(tile.get("climate", "")) in zones

# Removes a hex from the multi-index after it has been occupied by a resource.
func _remove_hex_from_index(hex_index: Dictionary, row: int, col: int, terrain_id: String, cover_id: String) -> void:
    for name in _index_names(terrain_id):
        _remove_hex_from_index_key(hex_index, row, col, "%s|%s" % [name, cover_id])

func _remove_hex_from_index_key(hex_index: Dictionary, row: int, col: int, key: String) -> void:
    if not hex_index.has(key):
        return
    var arr: Array = hex_index[key]
    for i in range(arr.size()):
        if arr[i].row == row and arr[i].col == col:
            arr.remove_at(i)
            break
    if arr.is_empty():
        hex_index.erase(key)

# Parses the spawn_count field of a resource and returns the number of specimens to
# spawn. The acceptable formats: a number >= 0 or an array [min, max] of numbers >= 0.
#   * a number N          -> always N specimens (N=0 — do not spawn, N=1 — the old behaviour);
#   * an array [min,max]  -> a random number from the range;
#   * min/max swapped     -> we forcibly swap them;
#   * incorrect data (not a number/not an array of 2 numbers, negative numbers)
#     -> a warning and the default 1 (the old behaviour).
# The parsing and validation are moved out to RangeUtils.roll_value — a single check
# of "a number or [min, max]" for spawn_count and produces (see scripts/range_utils.gd).
func _resolve_spawn_count(data: Dictionary) -> int:
    var res_id: String = str(data.get("id", "?"))
    return RangeUtils.roll_value(data.get("spawn_count", 1),
            tr("spawn_count of resource '%s'") % res_id, 1)

func _place_resources(tile_data: Array, res_dict: Dictionary, _rows: int, _cols: int, _city_row: int, _city_col: int, hex_index: Dictionary):
    if res_dict.size() == 0:
        return
    # We spawn ALL the resources of the category on the map, and not 1-3 random ones (as it
    # was before). A resource is placed on a random suitable hex, if
    # the following hold:
    #   * tech_required (if there is one) — at the start everything is already considered available,
    #     because this field gates only the construction of the improvement, and not the appearance;
    #   * spawn_conditions — the activation chance and the geometric conditions
    #     (for example, "by a river", "on a soda lake"); if it did not roll out / does not fit —
    #     the resource is skipped;
    #   * allowed_terrain / allowed_cover — the ordinary terrain and cover restrictions. A terrain
    #     may be named exactly or by its family (see _build_hex_index).
    # If the resource has tech_reveal (the underground minerals) — it appears
    # on the map IMMEDIATELY, but is hidden from the player until the corresponding technology
    # is learned.
    # See docs.md, the section "tech_reveal: hidden resources".
    #
    # We shuffle the keys, so that the order of the placement is random — otherwise
    # the first ones in the dictionary always take the best hexes, and the last ones risk
    # not finding a suitable place.
    var ids = res_dict.keys()
    ids.shuffle()
    for res_id in ids:
        var data = res_dict[res_id]
        if not MapHelpers.spawn_conditions_met(data):
            continue
        # spawn_count: how many specimens of the resource to spawn (a number or [min, max]).
        # 0 — the resource is not spawned at all.
        var spawn_total = _resolve_spawn_count(data)
        for i in range(spawn_total):
            var possible = []
            for terrain_id in data.get("allowed_terrain", []):
                for cover_id in data.get("allowed_cover", []):
                    var key = "%s|%s" % [terrain_id, cover_id]
                    if not hex_index.has(key):
                        continue
                    var arr: Array = hex_index[key]
                    for hex in arr:
                        if not _climate_allowed(tile_data[hex.row][hex.col], data):
                            continue
                        if MapHelpers.is_hex_conditions_met(tile_data, hex.row, hex.col, data):
                            possible.append(hex)
            if possible.size() > 0:
                var hex = possible[randi() % possible.size()]
                tile_data[hex.row][hex.col]["resource"] = res_id
                tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()
                _remove_hex_from_index(hex_index, hex.row, hex.col,
                        tile_data[hex.row][hex.col]["terrain"], tile_data[hex.row][hex.col].get("cover", "none"))

# Places the wild plants ONLY inside the starting Influence Ring.
# The number of specimens is taken from the spawn_count field of the resource (a number or
# [min, max]) — as for all the other resources on the map (see
# _resolve_spawn_count). The wild plants are gathered by the special action "Gather the wild plants"
# (action_type "forage") and disappear from the map after being gathered.
func place_wild_food(tile_data: Array, min_row: int, max_row: int, min_col: int, max_col: int, city_row: int, city_col: int):
    var wild_id = "wild_food"
    if not GameData.raw_resources.has(wild_id):
        return
    var wild_data = GameData.raw_resources[wild_id]
    var count = _resolve_spawn_count(wild_data)
    var possible = []
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            if abs(r - city_row) <= 2 and abs(c - city_col) <= 2:
                continue
            if tile_data[r][c]["resource"] != null:
                continue
            var terrain_id = tile_data[r][c]["terrain"]
            var cover_id = tile_data[r][c].get("cover", "none")
            if _terrain_allowed(terrain_id, wild_data) and cover_id in wild_data.get("allowed_cover", []):
                if _climate_allowed(tile_data[r][c], wild_data):
                    possible.append({"row": r, "col": c})
    possible.shuffle()
    for i in range(min(count, possible.size())):
        var hex = possible[i]
        tile_data[hex.row][hex.col]["resource"] = wild_id
        tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()

# Places the "one-off" (gatherable) resources over the whole map.
# A resource is considered one-off if it has improved_by == null (it cannot be
# developed by an improvement) and has produces set (there is something to gather). Such resources
# (the metal nuggets, the wild plants) spawn at the start of the game over the whole map and
# disappear after being gathered by a special action (see main_map.gd, the branch
# action_type == "forage"). The number of specimens is from spawn_count, the output
# of the product is from produces of the resource.
# The wild plants (wild_food) do NOT take part in this function: they are placed by the separate
# function place_wild_food strictly inside the starting Influence Ring.
# The placement parameters are standard (see _place_resources): allowed_terrain /
# allowed_cover and spawn_conditions.
func place_one_time_resources(tile_data: Array, raw_res: Dictionary, rows: int, cols: int,
        city_row: int, city_col: int, hex_index: Dictionary):
    var one_time: Dictionary = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if rid == "wild_food":
            continue
        if r.get("improved_by", null) != null:
            continue
        if not r.has("produces"):
            continue
        one_time[rid] = r
    _place_resources(tile_data, one_time, rows, cols, city_row, city_col, hex_index)

func ensure_free_terrain_hexes(tile_data: Array, terrain_counts: Dictionary,
        min_row: int, max_row: int, min_col: int, max_col: int,
        city_row: int = -1, city_col: int = -1) -> void:
    var free_count: Dictionary = {}
    for terrain_id in terrain_counts.keys():
        free_count[terrain_id] = 0
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            # The hex of the city and its neighbours (3×3) are excluded from the counting and
            # the conversion — the terrain of the city must not change after
            # _ensure_city_valid_terrain, and the neighbours are needed for the starting construction.
            if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var bucket := _count_bucket(str(tile.get("terrain", "")), terrain_counts)
            if bucket != "":
                free_count[bucket] += 1

    for terrain_id in terrain_counts.keys():
        var deficit = FREE_TERRAIN_HEXES - free_count.get(terrain_id, 0)
        if deficit <= 0:
            continue
        var converted = _convert_free_terrain_near_cluster(tile_data, terrain_id, deficit,
                min_row, max_row, min_col, max_col, free_count, terrain_counts,
                city_row, city_col)
        free_count[terrain_id] += converted

# The key of terrain_counts a hex belongs to: the exact terrain (a lake, a desert), or the family of
# it — a tundra plain, a boreal plain, a steppe, a savanna … all count as the plain they are, and a
# bog of any belt counts as the swamp.
func _count_bucket(terrain_id: String, terrain_counts: Dictionary) -> String:
    if terrain_counts.has(terrain_id):
        return terrain_id
    var family := GameData.terrain_family(terrain_id)
    if family != "" and terrain_counts.has(family):
        return family
    return ""

# The terrain a key of terrain_counts becomes in this hex: the key itself, or the variety of the
# family in the climate zone the hex stands in (the plain of the boreal zone is a boreal plain).
func _terrain_for_key(key: String, tile: Dictionary) -> String:
    var zone_id := str(tile.get("climate", ""))
    if zone_id != "":
        var variant := GameData.zone_terrain(zone_id, key)
        if variant != "":
            return variant
    return key

func _convert_free_terrain_near_cluster(tile_data: Array, terrain_id: String, deficit: int,
        min_row: int, max_row: int, min_col: int, max_col: int,
        free_count: Dictionary, terrain_counts: Dictionary,
        city_row: int = -1, city_col: int = -1) -> int:
    var converted = 0
    var cluster: Array = []
    var visited := {}
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            # The hex of the city and its neighbours (3×3) do not enter the cluster and are not
            # converted — the terrain of the city is fixed.
            if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            if _count_bucket(str(tile.get("terrain", "")), terrain_counts) == terrain_id:
                cluster.append({"row": r, "col": c})
                visited["%d_%d" % [r, c]] = true

    var candidates: Array = []
    var frontier = cluster.duplicate()
    var distance = 0
    var max_distance = (max_row - min_row + 1) + (max_col - min_col + 1)
    while frontier.size() > 0 and distance < max_distance:
        distance += 1
        var next_frontier: Array = []
        for hex in frontier:
            var neighbors = HexUtils.get_neighbors_odd_r(hex.row, hex.col, max_row + 1, max_col + 1)
            for n in neighbors:
                if n.row < min_row or n.row > max_row or n.col < min_col or n.col > max_col:
                    continue
                # The hex of the city and its neighbours are not visited and do not become candidates.
                if city_row >= 0 and abs(n.row - city_row) <= 1 and abs(n.col - city_col) <= 1:
                    continue
                var key = "%d_%d" % [n.row, n.col]
                if visited.has(key):
                    continue
                visited[key] = true
                if tile_data[n.row][n.col].get("resource", null) != null:
                    continue
                var n_terrain = str(tile_data[n.row][n.col].get("terrain", ""))
                if _count_bucket(n_terrain, terrain_counts) == terrain_id:
                    next_frontier.append(n)
                else:
                    candidates.append({"row": n.row, "col": n.col, "terrain": n_terrain, "dist": distance})
        frontier = next_frontier

    if cluster.size() == 0 and candidates.size() == 0:
        for r in range(min_row, max_row + 1):
            for c in range(min_col, max_col + 1):
                if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                    continue
                if tile_data[r][c].get("resource", null) != null:
                    continue
                var terrain_here := str(tile_data[r][c].get("terrain", ""))
                if _count_bucket(terrain_here, terrain_counts) != terrain_id:
                    candidates.append({"row": r, "col": c,
                            "terrain": terrain_here, "dist": 0})

    candidates.sort_custom(func(a, b):
        var a_over = free_count.get(_count_bucket(a.terrain, terrain_counts), 0) > OVER_REP_THRESHOLD
        var b_over = free_count.get(_count_bucket(b.terrain, terrain_counts), 0) > OVER_REP_THRESHOLD
        if a.dist != b.dist:
            return a.dist < b.dist
        if a_over != b_over:
            return a_over and not b_over
        return a.terrain < b.terrain)

    for cand in candidates:
        if converted >= deficit:
            break
        # The hex of the city and its neighbours are not converted into a terrain.
        if city_row >= 0 and abs(cand.row - city_row) <= 1 and abs(cand.col - city_col) <= 1:
            continue
        var old_terrain = cand.terrain
        var row = cand.row
        var col = cand.col
        var tile = tile_data[row][col]
        if str(tile.get("terrain", "")) != old_terrain:
            continue
        if tile.get("resource", null) != null:
            continue
        var donor_min = FREE_TERRAIN_HEXES
        if cluster.size() == 0:
            donor_min = FREE_TERRAIN_HEXES - 1
        var old_bucket := _count_bucket(old_terrain, terrain_counts)
        if free_count.get(old_bucket, 0) <= donor_min:
            continue
        var target := _terrain_for_key(terrain_id, tile)
        tile["terrain"] = target
        tile["cover"] = _roll_cover(target, str(tile.get("climate", "")))
        if free_count.has(old_bucket):
            free_count[old_bucket] = max(0, free_count[old_bucket] - 1)
        free_count[terrain_id] = free_count.get(terrain_id, 0) + 1
        converted += 1

    return converted
