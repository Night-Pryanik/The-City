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
#   - the types that are not listed in terrain_config (the marshes) — they are created
#     only by the post-processing (_apply_marshes).
# The participation in the Voronoi is now set explicitly through the config: adding a new
# type to terrains.json no longer makes it automatically spread
# over the whole map.
static func _get_base_terrain_ids() -> Array:
    var cfg: Dictionary = GameData.map_config.get("terrain_config", {})
    var ids: Array = []
    for tid in GameData.terrains.keys():
        var t: Dictionary = GameData.terrains[tid]
        if t.get("unique", false):
            continue
        if not cfg.has(tid):
            continue
        ids.append(tid)
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
# _get_base_terrain_ids): the others (the marshes) are created by the post-processing.
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

    var t_cover = Time.get_ticks_msec()
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            tile_data[row][col]["cover"] = _roll_cover(terrain_id)

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

# Возвращает true, если тип местности непроходим (move_cost >= 999).
# Такие типы (озёра: lake, soda_lake, asphalt_lake, salt_lake) блокируют
# перемещение города наружу.
func _is_impassable_terrain_id(terrain_id: String) -> bool:
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    return int(t.get("move_cost", 1)) >= 999

# Возвращает true, если гекс (row, col) непроходим.
func _is_impassable_hex(tile_data: Array, row: int, col: int) -> bool:
    var terrain_id = tile_data[row][col].get("terrain", "plain")
    return _is_impassable_terrain_id(terrain_id)

# Принудительно превращает все гексы в радиусе `radius` вокруг города
# в равнину (plain) без покрова. Сбрасывает временный флаг _is_marsh.
# Вызывается ПОСЛЕ размещения уникальных террейнов и ДО генерации покрова
# и ресурсов, чтобы зона была полностью «чистой».
func _ensure_plain_zone(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int, radius: int) -> void:
    for r in range(rows):
        for c in range(cols):
            if HexUtils.hex_distance(r, c, city_row, city_col) <= radius:
                var tile = tile_data[r][c]
                tile["terrain"] = "plain"
                # Покров генерируется как у обычной равнины (могут появиться
                # леса), чтобы безопасный двор не выглядел голым.
                tile["cover"] = _roll_cover("plain")
                tile["_is_marsh"] = false
                tile["_is_sea"] = false
                tile["_is_beach"] = false

# Гарантирует, что у города есть путь к краю карты (к «внешнему миру»).
# Если город оказался изолирован непроходимым террейном (озером или морем),
# функция BFS по непроходимым гексам прокладывает кратчайший коридор от
# достижимой области города к ближайшему внешнему проходимому гексу и
# превращает этот коридор в равнину. Море — не препятствие для пробивки
# (как и озеро), а побережье (beach, move_cost: 1) — валидный выход.
# Повторяется до тех пор, пока город не получит выход к краю карты
# (или не упрётся в лимит итераций).
func _ensure_outward_corridor(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int) -> void:
    for _iter in range(10):
        # 1) Достижимая из города область по проходимым гексам.
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

        # 2) Если город достиг проходимого края карты — выход есть.
        if _has_exit_to_edge(reachable, rows, cols):
            return

        # 3) Ищем водный путь от достижимой области к ближайшему внешнему
        #    проходимому гексу. BFS стартует со всех непроходимых соседей A.
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
            # Не нашли внешний проходимый гекс (весь мир — вода/острова).
            # Пробиваем коридор напрямую к краю карты сквозь воду.
            if not _punch_corridor_to_edge(tile_data, rows, cols, city_row, city_col, reachable):
                return

        # 4) Восстанавливаем путь: непроходимые гексы превращаем в равнину.
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

# Возвращает true, если хоть один гекс достижимой области лежит на краю карты.
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

# Превращает гекс (key "r,c") в равнину без покрова.
# Используется для пробивки коридора выхода сквозь непроходимые гексы
# (озёра и моря). Сбрасывает временные флаги _is_marsh и _is_sea.
func _punch_hex(tile_data: Array, key: String) -> void:
    var parts = key.split(",")
    var r = int(parts[0])
    var c = int(parts[1])
    var tile = tile_data[r][c]
    tile["terrain"] = "plain"
    # Покров генерируется как у обычной равнины для естественного вида.
    tile["cover"] = _roll_cover("plain")
    tile["_is_marsh"] = false
    tile["_is_sea"] = false

# Пробивает коридор от достижимой области напрямую к краю карты через
# непроходимые гексы. Возвращает true, если коридор удалось проложить.
func _punch_corridor_to_edge(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int, reachable: Dictionary) -> bool:
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
    # Пробиваем путь от целевой краевой непроходимой клетки обратно к A.
    var step = target_key
    while true:
        _punch_hex(tile_data, step)
        var prev = from.get(step, "")
        if prev == "" or reachable.has(prev):
            break
        step = prev
    return true

# Выбирает покоры (cover) для гекса с указанным типом местности по весам
# из terrains.json (cover_chance). Если поле отсутствует или пустое —
# возвращает "none".
func _roll_cover(terrain_type: String) -> String:
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

# Строит мультиииндекс свободных гексов по (terrain, cover).
# Ключ: "terrain|cover" -> Array словарей {"row", "col"}.
# Гексы рядом с городом (abs <= 1) исключаются, чтобы не мешать
# стартовому строительству (как в исходном _place_resources).
func _build_hex_index(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> Dictionary:
    var index: Dictionary = {}
    for r in range(rows):
        for c in range(cols):
            if abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var terrain_id = tile.get("terrain", "plain")
            var cover_id = tile.get("cover", "none")
            var key = "%s|%s" % [terrain_id, cover_id]
            if not index.has(key):
                index[key] = []
            index[key].append({"row": r, "col": c})
    return index

# Удалявляет гекс из мультиииндекса после занятия его ресурсом.
func _remove_hex_from_index(hex_index: Dictionary, row: int, col: int, terrain_id: String, cover_id: String) -> void:
    var key = "%s|%s" % [terrain_id, cover_id]
    if not hex_index.has(key):
        return
    var arr: Array = hex_index[key]
    for i in range(arr.size()):
        if arr[i].row == row and arr[i].col == col:
            arr.remove_at(i)
            break
    if arr.is_empty():
        hex_index.erase(key)

# Разбирает поле spawn_count ресурса и возвращает количество экземпляров для
# спавна. Допустимые форматы: число >= 0 или массив [min, max] из чисел >= 0.
#   * число N          -> всегда N экземпляров (N=0 — не спавнить, N=1 — старое поведение);
#   * массив [min,max] -> случайное число из диапазона;
#   * min/max перепутаны -> форсированно меняем местами;
#   * некорректные данные (не число/не массив из 2 чисел, отрицательные числа)
#     -> предупреждение и дефолт 1 (старое поведение).
# Парсинг и валидация вынесены в RangeUtils.roll_value — единая проверка
# «число или [min, max]» для spawn_count и produces (см. scripts/range_utils.gd).
func _resolve_spawn_count(data: Dictionary) -> int:
    var res_id: String = str(data.get("id", "?"))
    return RangeUtils.roll_value(data.get("spawn_count", 1),
            tr("spawn_count of resource '%s'") % res_id, 1)

func _place_resources(tile_data: Array, res_dict: Dictionary, rows: int, cols: int, city_row: int, city_col: int, hex_index: Dictionary):
    if res_dict.size() == 0:
        return
    # Спавним ВСЕ ресурсы категории на карте, а не 1-3 случайных (как было
    # раньше). Ресурс размещается на случайном подходящем гексе, если
    # выполняются:
    #   * tech_required (если есть) — на старте все уже считаются доступными,
    #     т.к. это поле гейтит только постройку улучшения, а не появление;
    #   * spawn_conditions — шанс активации и геометрические условия
    #     (например, «у реки», «на содовом озере»); если не выпал/не подходит —
    #     ресурс пропускается;
    #   * allowed_terrain / allowed_cover — обычные биомные ограничения.
    #
    # Если у ресурса есть tech_reveal (подземные ископаемые) — он появляется
    # на карте СРАЗУ, но скрыт от игрока до изучения соответствующей технологии.
    # См. docs.md, раздел «tech_reveal: скрытые ресурсы».
    #
    # Перемешиваем ключи, чтобы порядок размещения был случайным — иначе
    # первые в словаре всегда занимают лучшие гексы, а последние рискуют
    # не найти подходящего места.
    var ids = res_dict.keys()
    ids.shuffle()
    for res_id in ids:
        var data = res_dict[res_id]
        if not HexUtils.spawn_conditions_met(data):
            continue
        # spawn_count: сколько экземпляров ресурса спавнить (число или [min, max]).
        # 0 — ресурс не спавнится вовсе.
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
                        if HexUtils.is_hex_conditions_met(tile_data, hex.row, hex.col, data):
                            possible.append(hex)
            if possible.size() > 0:
                var hex = possible[randi() % possible.size()]
                tile_data[hex.row][hex.col]["resource"] = res_id
                tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()
                _remove_hex_from_index(hex_index, hex.row, hex.col,
                        tile_data[hex.row][hex.col]["terrain"], tile_data[hex.row][hex.col].get("cover", "none"))

# Размещает дикоросы ТОЛЬКО внутри стартового Кольца Влияния.
# Количество экземпляров берётся из поля spawn_count ресурса (число или
# [min, max]) — как у всех остальных ресурсов на карте (см.
# _resolve_spawn_count). Дикоросы собираются спец-действием «Собрать дикоросы»
# (action_type "forage") и после сбора исчезают с карты.
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
            if terrain_id in wild_data.get("allowed_terrain", []) and cover_id in wild_data.get("allowed_cover", []):
                possible.append({"row": r, "col": c})
    possible.shuffle()
    for i in range(min(count, possible.size())):
        var hex = possible[i]
        tile_data[hex.row][hex.col]["resource"] = wild_id
        tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()

# Размещает «одноразовые» (собираемые) ресурсы по всей карте.
# Одноразовым считается ресурс, у которого improved_by == null (нельзя
# разрабатывать улучшением) и задан produces (есть что собрать). Такие ресурсы
# (самородки металлов, дикоросы) спавнятся при старте игры по всей карте и
# исчезают после сбора спец-действием (см. main_map.gd, ветка
# action_type == "forage"). Количество экземпляров — из spawn_count, выход
# продукции — из produces ресурса.
# Дикоросы (wild_food) в этой функции НЕ участвуют: их размещает отдельная
# функция place_wild_food строго внутри стартового Кольца Влияния.
# Параметры размещения стандартные (см. _place_resources): allowed_terrain /
# allowed_cover и spawn_conditions.
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
            # Гекс города и его соседи (3×3) исключаются из подсчёта и
            # конвертации — террейн города не должен меняться после
            # _ensure_city_valid_terrain, а соседи нужны для стартового строительства.
            if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var terrain_id = tile.get("terrain", "plain")
            if free_count.has(terrain_id):
                free_count[terrain_id] += 1

    for terrain_id in terrain_counts.keys():
        var deficit = FREE_TERRAIN_HEXES - free_count.get(terrain_id, 0)
        if deficit <= 0:
            continue
        var converted = _convert_free_terrain_near_cluster(tile_data, terrain_id, deficit,
                min_row, max_row, min_col, max_col, free_count, terrain_counts,
                city_row, city_col)
        free_count[terrain_id] += converted

func _convert_free_terrain_near_cluster(tile_data: Array, terrain_id: String, deficit: int,
        min_row: int, max_row: int, min_col: int, max_col: int,
        free_count: Dictionary, terrain_counts: Dictionary,
        city_row: int = -1, city_col: int = -1) -> int:
    var converted = 0
    var cluster: Array = []
    var visited := {}
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            # Гекс города и его соседи (3×3) не входят в кластер и не
            # конвертируются — террейн города фиксирован.
            if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            if tile.get("terrain", "plain") == terrain_id:
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
                # Гекс города и его соседи не посещаются и не становятся кандидатами.
                if city_row >= 0 and abs(n.row - city_row) <= 1 and abs(n.col - city_col) <= 1:
                    continue
                var key = "%d_%d" % [n.row, n.col]
                if visited.has(key):
                    continue
                visited[key] = true
                if tile_data[n.row][n.col].get("resource", null) != null:
                    continue
                var n_terrain = tile_data[n.row][n.col].get("terrain", "plain")
                if n_terrain == terrain_id:
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
                if tile_data[r][c].get("terrain", "plain") != terrain_id:
                    candidates.append({"row": r, "col": c,
                            "terrain": tile_data[r][c].get("terrain", "plain"), "dist": 0})

    candidates.sort_custom(func(a, b):
        var a_over = free_count.get(a.terrain, 0) > OVER_REP_THRESHOLD
        var b_over = free_count.get(b.terrain, 0) > OVER_REP_THRESHOLD
        if a.dist != b.dist:
            return a.dist < b.dist
        if a_over != b_over:
            return a_over and not b_over
        return a.terrain < b.terrain)

    for cand in candidates:
        if converted >= deficit:
            break
        # Гекс города и его соседи не конвертируются террейном.
        if city_row >= 0 and abs(cand.row - city_row) <= 1 and abs(cand.col - city_col) <= 1:
            continue
        var old_terrain = cand.terrain
        var row = cand.row
        var col = cand.col
        var tile = tile_data[row][col]
        if tile.get("terrain", "plain") != old_terrain:
            continue
        if tile.get("resource", null) != null:
            continue
        var donor_min = FREE_TERRAIN_HEXES
        if cluster.size() == 0:
            donor_min = FREE_TERRAIN_HEXES - 1
        if free_count.get(old_terrain, 0) <= donor_min:
            continue
        tile["terrain"] = terrain_id
        tile["cover"] = _roll_cover(terrain_id)
        if free_count.has(old_terrain):
            free_count[old_terrain] = max(0, free_count[old_terrain] - 1)
        free_count[terrain_id] = free_count.get(terrain_id, 0) + 1
        converted += 1

    return converted
