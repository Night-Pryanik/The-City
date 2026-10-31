# river_manager.gd
# The river manager: generates the river system on the map.
#
# The generation scheme (the river system):
#   - Main rivers: the source in the mountains, the mouth in a lake or the sea. They do not intersect each other.
#   - Tributaries: the source in the mountains (or hills, if there are few mountains), flowing into the main
#     rivers or into other tributaries (a confluence point). The tributaries do not flow into the lakes and the seas.
#   - The rivers do not run along the edges of the lake/sea hexes and their neighbours (except
#     for the last step into the mouth/confluence point), so that the river does not flow along the shore.
#
# The search is one multi-goal A* per attempt instead of one search per random (source, goal) pair:
# a main river searches for the nearest free mouth, a tributary — for the nearest existing river vertex.
# The heuristic is the exact graph distance to the nearest goal (a multi-source BFS over the vertex
# graph), so the search expands close to the path corridor. All hex edges have the same length,
# therefore the number of edges is proportional to the path length.
#
# The number of rivers and the minimum lengths are taken from data/map_config.json:
#   num_main_rivers, num_tributaries, min_river_length, min_tributary_length.
#
# The rivers and the lakes give production bonuses to the resources by the improvements
# that have access to fresh water.
@tool
extends Node

# --- Constants ---
const MAX_TURN_ANGLE_DEG := 60.0 # The maximum turn angle per step
const MAX_TURN_ANGLE_SOFT_DEG := 90.0 # The fallback angle when getting stuck.
const NUM_RIVER_ATTEMPTS := 8 # The attempts to build one river
const SOFT_ANGLE_BONUS_DEG := 30.0 # A node relaxes the angle limit by this much when no candidate fits

# The vertices of the odd-r hex grid form a triangular lattice. In units of a sixth of
# the lattice step a vertex of hex (row, col) at index vidx is
#   x = 6 * col + 3 * (row & 1) + VDX[vidx]
#   y = 6 * row + VDY[vidx]
# These integer coordinates are exact: the shared vertices of adjacent hexes always get
# the same key, independent of the floating-point position.
const VDX := [3, 0, -3, -3, 0, 3]
const VDY := [2, 4, 2, -2, -4, -2]

# The spatial buckets for looking up a vertex by a world position (loaded rivers).
const POS_BUCKET := 64.0
const POS_SNAP := 1.0

# The bits of the per-vertex terrain mask.
const TERRAIN_MOUNTAIN := 1
const TERRAIN_HILL := 2
const TERRAIN_LAKE := 4
const TERRAIN_SEA := 8
const TERRAIN_SHALLOW_SEA := 16
const TERRAIN_WATER := 32

const RIVER_COLOR := Color(26.0 / 255.0, 95.0 / 255.0, 180.0 / 255.0, 0.9) # The dark blue body of the river (#1a5fb4)
const RIVER_WIDTH := 10.0 # The thickness of the body of the river
const RIVER_SHORE_COLOR := Color(98.0 / 255.0, 160.0 / 255.0, 234.0 / 255.0, 0.25) # A light tint of the shores
const RIVER_SHORE_WIDTH := 10.0 # The thickness of the shore underlay
const RIVER_HIGHLIGHT_COLOR := Color(98.0 / 255.0, 160.0 / 255.0, 234.0 / 255.0, 0.95) # The light blue highlight (#62a0ea)
const RIVER_HIGHLIGHT_WIDTH := 6.0 # The thickness of the highlight on the water

# The style of the tributaries: thinner and lighter, so as to be visually distinct from the main rivers.
const TRIBUTARY_COLOR := Color(70.0 / 255.0, 140.0 / 255.0, 210.0 / 255.0, 0.85) # The light blue body of the tributary
const TRIBUTARY_WIDTH := 6.0 # The thickness of the body of the tributary
const TRIBUTARY_SHORE_COLOR := Color(120.0 / 255.0, 180.0 / 255.0, 240.0 / 255.0, 0.2) # A light tint of the shores of the tributary
const TRIBUTARY_SHORE_WIDTH := 6.0 # The thickness of the shore underlay of the tributary
const TRIBUTARY_HIGHLIGHT_COLOR := Color(130.0 / 255.0, 190.0 / 255.0, 245.0 / 255.0, 0.9) # The light blue highlight of the tributary
const TRIBUTARY_HIGHLIGHT_WIDTH := 4.0 # The thickness of the highlight of the tributary

var rivers: Array = [] # Array of Array of Vector2 (the world coordinates of the points of each river)
var main_rivers: Array = [] # Only the main rivers (the source in the mountains, the mouth in a lake)
var tributaries: Array = [] # Only the tributaries (flowing into the main rivers or other tributaries)

# The last built graph of the vertices. It is reused in mark_river_edges(),
# so as not to build the graph (thousands of vertices) twice per map generation.
var _cached_graph: Dictionary = {}

# The working copies of the graph arrays: the hot loops of A* read them without dictionary lookups.
var _graph_positions := PackedVector2Array()
var _graph_nbr := PackedInt32Array()
var _graph_forb := PackedByteArray()
var _graph_degree := PackedByteArray()
var _graph_edge_len := 1.0
var _vertex_restricted := PackedByteArray()

# The vertices occupied by the accepted rivers, and their list for the merge candidates.
var _used := PackedByteArray()
var _used_ids: Array = []

# The water vertices: the tributaries do not merge into them.
var _water := PackedByteArray()

# The distance in edges from every vertex to the nearest goal of the current search.
var _dist_field := PackedInt32Array()

# The per-search state. The epoch stamps replace clearing the arrays before every search:
# a value is valid only when its stamp equals the current epoch.
var _g_score := PackedFloat32Array()
var _came_from := PackedInt32Array()
var _seen_stamp := PackedInt32Array()
var _closed_stamp := PackedInt32Array()
var _heap_stamp := PackedInt32Array()
var _goal_stamp := PackedInt32Array()
var _approach_stamp := PackedInt32Array()
var _goal_epoch := 0
var _path_epoch := 0


# -------------------------------------------------------
# A minimal binary heap (priority queue) for A*.
# -------------------------------------------------------
class PriorityQueue:
    var _keys := PackedInt32Array()
    var _priorities := PackedFloat32Array()

    func push(key: int, priority: float) -> void:
        _keys.append(key)
        _priorities.append(priority)
        var idx := _keys.size() - 1
        while idx > 0:
            var parent := (idx - 1) >> 1
            if _priorities[idx] >= _priorities[parent]:
                break
            var tk := _keys[idx]
            _keys[idx] = _keys[parent]
            _keys[parent] = tk
            var tp := _priorities[idx]
            _priorities[idx] = _priorities[parent]
            _priorities[parent] = tp
            idx = parent

    func pop_min() -> int:
        var top := _keys[0]
        var last := _keys.size() - 1
        _keys[0] = _keys[last]
        _priorities[0] = _priorities[last]
        _keys.resize(last)
        _priorities.resize(last)
        var size := _keys.size()
        if size > 1:
            var idx := 0
            while true:
                var left := idx * 2 + 1
                var right := left + 1
                var smallest := idx
                if left < size and _priorities[left] < _priorities[smallest]:
                    smallest = left
                if right < size and _priorities[right] < _priorities[smallest]:
                    smallest = right
                if smallest == idx:
                    break
                var tk := _keys[idx]
                _keys[idx] = _keys[smallest]
                _keys[smallest] = tk
                var tp := _priorities[idx]
                _priorities[idx] = _priorities[smallest]
                _priorities[smallest] = tp
                idx = smallest
        return top

    func is_empty() -> bool:
        return _keys.is_empty()


# -------------------------------------------------------
# The main method: generates the river system on the map.
# tile_data — a 2D array of the hexes (to determine the mountains/lakes/hills).
# -------------------------------------------------------
func generate_rivers(rows: int, cols: int, radius: float, tile_data: Array) -> void:
    rivers = []
    if rows < 3 or cols < 3:
        return

    # The hexes along which the rivers CANNOT flow (the lakes and their neighbours, the swamps
    # themselves and the marsh hexes). They are built BEFORE the graph, so that the flags of the forbidden
    # edges and vertices are precomputed once instead of being checked per neighbour.
    var restricted_hexes := _build_restricted_hexes(tile_data, rows, cols)
    var graph := _build_vertex_graph(rows, cols, radius, restricted_hexes)
    _cached_graph = graph
    _alloc_search_buffers(graph)

    var vertex_terrain := _build_terrain_vertex_mask(graph, tile_data, rows, cols)
    var mountain_ids := _vertices_with_bit(vertex_terrain, TERRAIN_MOUNTAIN)
    var hill_ids := _vertices_with_bit(vertex_terrain, TERRAIN_HILL)
    var lake_ids := _vertices_with_bit(vertex_terrain, TERRAIN_LAKE)
    var mouth_ids := _vertices_with_bit(vertex_terrain, TERRAIN_SEA | TERRAIN_SHALLOW_SEA)

    var n := _graph_positions.size()
    _water.resize(n)
    _used.resize(n)
    _used_ids = []
    for id in range(n):
        var is_water := (vertex_terrain[id] & TERRAIN_WATER) != 0
        _water[id] = 1 if is_water else 0
        _used[id] = 0

    mouth_ids = lake_ids + mouth_ids
    # The mouths of the main rivers: the lakes + the seas. If there are neither lakes nor seas — we do not build the rivers.
    if mountain_ids.is_empty() or mouth_ids.is_empty():
        print("RIVER DEBUG: there are no mountains or mouths (lakes/seas), exiting")
        return

    # The distance to the nearest mouth is shared by all the main river searches.
    _dist_field = _build_distance_field(graph, mouth_ids)

    # The parameters from the configuration.
    var cfg: Dictionary = GameData.map_config
    var num_main = int(cfg.get("num_main_rivers", 3))
    var num_trib = int(cfg.get("num_tributaries", 5))
    var min_main_len = int(cfg.get("min_river_length", 8))
    var min_trib_len = int(cfg.get("min_tributary_length", 4))

    # --- The generation of the main rivers (mountain -> lake/sea, they do not intersect) ---
    main_rivers = []
    for _i in range(num_main):
        var river = _try_generate_main_river(mountain_ids, mouth_ids, min_main_len)
        if not river.is_empty():
            _mark_used(river)
            main_rivers.append(_ids_to_positions(river))
    print("RIVER DEBUG: main rivers generated=", main_rivers.size())

    # --- The generation of the tributaries (mountain/hill -> an occupied vertex, a confluence) ---
    tributaries = []
    for _i in range(num_trib):
        var river = _try_generate_tributary(graph, mountain_ids, hill_ids, min_trib_len)
        if not river.is_empty():
            _mark_used(river)
            tributaries.append(_ids_to_positions(river))

    rivers = main_rivers + tributaries
    print("RIVER DEBUG: total rivers=", rivers.size())


# -------------------------------------------------------
# Tries to generate one main river: the source in the mountains, the mouth in a lake/sea.
# A single search reaches the nearest free mouth; the attempts pick different sources.
# -------------------------------------------------------
func _try_generate_main_river(mountain_ids: Array,
        mouth_ids: Array, min_len: int) -> PackedInt32Array:
    var free_mountains: Array = []
    for id in mountain_ids:
        if _used[id] == 0 and _vertex_restricted[id] == 0:
            free_mountains.append(id)
    var free_mouths: Array = []
    for id in mouth_ids:
        if _used[id] == 0:
            free_mouths.append(id)
    if free_mountains.is_empty() or free_mouths.is_empty():
        return PackedInt32Array()

    _prepare_search(free_mouths)

    var best_path := PackedInt32Array()
    var tried: Dictionary = {}
    for _attempt in range(NUM_RIVER_ATTEMPTS):
        var start: int = free_mountains[randi() % free_mountains.size()]
        if tried.has(start):
            continue
        tried[start] = true
        var path := _find_path_astar(start, MAX_TURN_ANGLE_DEG)
        if path.is_empty():
            path = _find_path_astar(start, MAX_TURN_ANGLE_SOFT_DEG)
        if path.size() > best_path.size():
            best_path = path
        if path.size() >= min_len:
            return path

    # A compromise: the best path found may be shorter than min_len, but the river is still built.
    return best_path


# -------------------------------------------------------
# Tries to generate a tributary: the source in the mountains (or hills, if there are few mountains),
# the mouth — a vertex occupied by any river except the lake/sea ones (a confluence point).
# -------------------------------------------------------
func _try_generate_tributary(graph: Dictionary, mountain_ids: Array,
        hill_ids: Array, min_len: int) -> PackedInt32Array:
    var used_merge: Array = []
    for id in _used_ids:
        if _water[id] == 0:
            used_merge.append(id)
    if used_merge.is_empty():
        return PackedInt32Array()

    # The source: the free mountain vertices; if there are too few — we add the hilly ones.
    var free_sources: Array = []
    for id in mountain_ids:
        if _used[id] == 0 and _vertex_restricted[id] == 0:
            free_sources.append(id)
    if free_sources.size() < 3:
        for id in hill_ids:
            if _used[id] == 0 and _vertex_restricted[id] == 0:
                free_sources.append(id)
    if free_sources.is_empty():
        return PackedInt32Array()

    _prepare_search(used_merge)
    _dist_field = _build_distance_field(graph, used_merge)

    var tried: Dictionary = {}
    for _attempt in range(NUM_RIVER_ATTEMPTS):
        var start: int = free_sources[randi() % free_sources.size()]
        if tried.has(start):
            continue
        tried[start] = true
        var path := _find_path_astar(start, MAX_TURN_ANGLE_DEG)
        if path.is_empty():
            path = _find_path_astar(start, MAX_TURN_ANGLE_SOFT_DEG)
        if path.size() >= min_len:
            return path
    return PackedInt32Array()


# -------------------------------------------------------
# Finds the hexes along which the rivers CANNOT flow:
#   - the lake and sea hexes and their neighbours (so that the river does not flow along the shore);
#   - the wetland hexes themselves (a swamp of any belt and a marsh) — the rivers do not pass
#     through them.
# Returns a flag array indexed by row * cols + col.
# -------------------------------------------------------
func _build_restricted_hexes(tile_data: Array, rows: int, cols: int) -> PackedByteArray:
    var result := PackedByteArray()
    result.resize(rows * cols)

    # We mark the water hexes and their neighbours.
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            if terrain_id == "lake" or terrain_id == "sea" or terrain_id == "shallow_sea":
                result[row * cols + col] = 1
                for n in HexUtils.get_neighbors_odd_r(row, col, rows, cols):
                    result[n.row * cols + n.col] = 1

    # The wetland hexes themselves — the rivers do not pass through them (their neighbours
    # are not marked: that would be too restrictive).
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            if MapHelpers.is_wetland_terrain(terrain_id):
                result[row * cols + col] = 1

    return result


# -------------------------------------------------------
# Builds the "graph of the vertices": the nodes are the unique points of the world coordinates,
# the edges are the sides of the hexes. The representation is flat arrays indexed by an integer
# vertex id:
#   positions      — the world coordinates of the vertices;
#   nbr / forb     — up to 3 neighbours per vertex and the "edge lies in a restricted hex" flags;
#   degree         — the number of the neighbours;
#   hex_off/hex_data — the CSR list of the hexes containing each vertex (for mark_river_edges);
#   pos_buckets    — the spatial buckets for looking up a vertex by a world position.
# -------------------------------------------------------
func _build_vertex_graph(rows: int, cols: int, radius: float, restricted_hexes: PackedByteArray = PackedByteArray()) -> Dictionary:
    var hex_count := rows * cols
    var has_restricted := restricted_hexes.size() == hex_count
    var x_spacing := radius * sqrt(3.0)
    var y_spacing := radius * 1.5

    # The six vertex offsets of a hex are the same for every hex: the trigonometry runs once.
    var offsets := PackedVector2Array()
    offsets.resize(6)
    for i in range(6):
        var angle := deg_to_rad(60.0 * i + 30.0)
        offsets[i] = Vector2(radius * cos(angle), radius * sin(angle))

    var positions := PackedVector2Array()
    var key_ids: Dictionary = {}
    var counts := PackedInt32Array()
    var hex_vertex_ids := PackedInt32Array()
    hex_vertex_ids.resize(hex_count * 6)

    for row in range(rows):
        var center_y := row * y_spacing
        var row_shift := x_spacing * 0.5 if row % 2 == 1 else 0.0
        for col in range(cols):
            var center := Vector2(col * x_spacing + row_shift, center_y)
            var base := (row * cols + col) * 6
            for vidx in range(6):
                var key := Vector2i(6 * col + 3 * (row & 1) + VDX[vidx], 6 * row + VDY[vidx])
                var id: int = key_ids.get(key, -1)
                if id < 0:
                    id = positions.size()
                    key_ids[key] = id
                    positions.append(center + offsets[vidx])
                    counts.append(1)
                else:
                    counts[id] += 1
                hex_vertex_ids[base + vidx] = id

    var n := positions.size()
    var hex_off := PackedInt32Array()
    hex_off.resize(n + 1)
    for id in range(n):
        hex_off[id + 1] = hex_off[id] + counts[id]
    var hex_data := PackedInt32Array()
    hex_data.resize(hex_off[n])
    var cursor := hex_off.duplicate()
    var vertex_restricted := PackedByteArray()
    vertex_restricted.resize(n)

    for row in range(rows):
        for col in range(cols):
            var hex_index := row * cols + col
            var base := hex_index * 6
            var restr := has_restricted and restricted_hexes[hex_index] != 0
            for vidx in range(6):
                var id := hex_vertex_ids[base + vidx]
                hex_data[cursor[id]] = base + vidx
                cursor[id] += 1
                if restr:
                    vertex_restricted[id] = 1

    var nbr := PackedInt32Array()
    nbr.resize(n * 3)
    nbr.fill(-1)
    var forb := PackedByteArray()
    forb.resize(n * 3)
    forb.fill(0)
    var degree := PackedByteArray()
    degree.resize(n)
    degree.fill(0)

    for hex_index in range(hex_count):
        var base := hex_index * 6
        var restr := has_restricted and restricted_hexes[hex_index] != 0
        for vidx in range(6):
            var id := hex_vertex_ids[base + vidx]
            var slot_base := id * 3
            for delta in [-1, 1]:
                var nvi: int = (vidx + delta + 6) % 6
                var nid := hex_vertex_ids[base + nvi]
                if nid == id:
                    continue
                var found := false
                for k in range(degree[id]):
                    if nbr[slot_base + k] == nid:
                        if restr:
                            forb[slot_base + k] = 1
                        found = true
                        break
                if not found:
                    var k := int(degree[id])
                    nbr[slot_base + k] = nid
                    forb[slot_base + k] = 1 if restr else 0
                    degree[id] = k + 1

    var edge_len := radius
    for id in range(n):
        if degree[id] > 0:
            edge_len = positions[id].distance_to(positions[nbr[id * 3]])
            break

    var pos_buckets: Dictionary = {}
    for id in range(n):
        var bucket := Vector2i(floori(positions[id].x / POS_BUCKET), floori(positions[id].y / POS_BUCKET))
        if not pos_buckets.has(bucket):
            pos_buckets[bucket] = []
        pos_buckets[bucket].append(id)

    return {
        "positions": positions,
        "nbr": nbr,
        "forb": forb,
        "degree": degree,
        "hex_off": hex_off,
        "hex_data": hex_data,
        "pos_buckets": pos_buckets,
        "vertex_restricted": vertex_restricted,
        "edge_len": edge_len
    }


# -------------------------------------------------------
# Builds the per-vertex mask of the terrain families the rivers care about.
# -------------------------------------------------------
func _build_terrain_vertex_mask(graph: Dictionary, tile_data: Array, rows: int, cols: int) -> PackedByteArray:
    var hex_bits := PackedByteArray()
    hex_bits.resize(rows * cols)
    for row in range(rows):
        for col in range(cols):
            var terrain_id := str(tile_data[row][col]["terrain"])
            var family := GameData.terrain_family(terrain_id)
            var bits := 0
            if terrain_id == "mountain" or family == "mountain":
                bits |= TERRAIN_MOUNTAIN
            if terrain_id == "hill" or family == "hill":
                bits |= TERRAIN_HILL
            if terrain_id == "lake":
                bits |= TERRAIN_LAKE
            if terrain_id == "sea":
                bits |= TERRAIN_SEA
            if terrain_id == "shallow_sea":
                bits |= TERRAIN_SHALLOW_SEA
            if bits & (TERRAIN_LAKE | TERRAIN_SEA | TERRAIN_SHALLOW_SEA):
                bits |= TERRAIN_WATER
            hex_bits[row * cols + col] = bits

    var hex_off: PackedInt32Array = graph["hex_off"]
    var hex_data: PackedInt32Array = graph["hex_data"]
    var n: int = graph["positions"].size()
    var mask := PackedByteArray()
    mask.resize(n)
    for id in range(n):
        var bits := 0
        for k in range(hex_off[id], hex_off[id + 1]):
            bits |= hex_bits[hex_data[k] / 6]
        mask[id] = bits
    return mask


func _vertices_with_bit(mask: PackedByteArray, required: int) -> Array:
    var result: Array = []
    for id in range(mask.size()):
        if mask[id] & required:
            result.append(id)
    return result


# -------------------------------------------------------
# Allocates the reusable per-search buffers and binds the graph arrays to the hot-loop copies.
# -------------------------------------------------------
func _alloc_search_buffers(graph: Dictionary) -> void:
    var n: int = graph["positions"].size()
    _graph_positions = graph["positions"]
    _graph_nbr = graph["nbr"]
    _graph_forb = graph["forb"]
    _graph_degree = graph["degree"]
    _graph_edge_len = graph["edge_len"]
    _vertex_restricted = graph["vertex_restricted"]

    _g_score.resize(n)
    _came_from.resize(n)
    _seen_stamp.resize(n)
    _closed_stamp.resize(n)
    _heap_stamp.resize(n)
    _goal_stamp.resize(n)
    _approach_stamp.resize(n)

    _goal_stamp.fill(0)
    _approach_stamp.fill(0)
    _seen_stamp.fill(0)
    _closed_stamp.fill(0)
    _heap_stamp.fill(0)
    _goal_epoch = 0
    _path_epoch = 0


# -------------------------------------------------------
# Marks the goals of the next searches and the vertices from which a river may approach them.
# The approach set includes the goal and its neighbours: entering an approach vertex from outside
# is allowed, but a transition between two approach vertices is not.
# -------------------------------------------------------
func _prepare_search(goal_ids: Array) -> void:
    _goal_epoch += 1
    var epoch := _goal_epoch
    for gid in goal_ids:
        _goal_stamp[gid] = epoch
    for gid in goal_ids:
        _approach_stamp[gid] = epoch
        var base: int = gid * 3
        for k in range(_graph_degree[gid]):
            _approach_stamp[_graph_nbr[base + k]] = epoch


# -------------------------------------------------------
# The distance in edges from every vertex to the nearest source, or -1 if unreachable.
# -------------------------------------------------------
func _build_distance_field(graph: Dictionary, source_ids: Array) -> PackedInt32Array:
    var n: int = graph["positions"].size()
    var field := PackedInt32Array()
    field.resize(n)
    field.fill(-1)
    var nbr: PackedInt32Array = graph["nbr"]
    var degree: PackedByteArray = graph["degree"]
    var queue := PackedInt32Array()
    queue.resize(n)
    var head := 0
    var tail := 0
    for sid in source_ids:
        if field[sid] == -1:
            field[sid] = 0
            queue[tail] = sid
            tail += 1
    while head < tail:
        var current: int = queue[head]
        head += 1
        var next_dist: int = field[current] + 1
        var base: int = current * 3
        for k in range(degree[current]):
            var nb: int = nbr[base + k]
            if field[nb] == -1:
                field[nb] = next_dist
                queue[tail] = nb
                tail += 1
    return field


# -------------------------------------------------------
# The multi-goal A* on the vertex graph with a filtering by the turn angle.
# It returns the vertex ids of the path or an empty array.
#
# The goals and their approach vertices are prepared by _prepare_search();
# _dist_field holds the exact distance to the nearest goal.
# The vertices occupied by other rivers are forbidden, except the goals themselves.
# An edge inside a restricted hex is forbidden, except the last step into a goal
# and one step from outside into an approach vertex.
# -------------------------------------------------------
func _find_path_astar(start_id: int, max_turn_angle_deg: float) -> PackedInt32Array:
    _path_epoch += 1
    var epoch := _path_epoch
    var goal_epoch := _goal_epoch
    var positions := _graph_positions
    var nbr := _graph_nbr
    var forb := _graph_forb
    var degree := _graph_degree
    var edge_len := _graph_edge_len
    var max_angle := deg_to_rad(max_turn_angle_deg)
    var soft_angle := deg_to_rad(max_turn_angle_deg + SOFT_ANGLE_BONUS_DEG)

    var open_set := PriorityQueue.new()
    _seen_stamp[start_id] = epoch
    _g_score[start_id] = 0.0
    _came_from[start_id] = -1
    _heap_stamp[start_id] = epoch
    var start_h := _dist_field[start_id]
    open_set.push(start_id, float(maxi(start_h, 0)) * edge_len)

    while not open_set.is_empty():
        var current := open_set.pop_min()
        # The lazy deletion: a stale entry of the heap is skipped.
        if _heap_stamp[current] != epoch:
            continue
        _heap_stamp[current] = 0
        if _closed_stamp[current] == epoch:
            continue
        _closed_stamp[current] = epoch

        if _goal_stamp[current] == goal_epoch:
            return _reconstruct_path(current)

        var current_pos := positions[current]
        var came := _came_from[current]
        var has_dir := came >= 0
        var dir := Vector2.ZERO
        if has_dir:
            dir = current_pos - positions[came]
        var current_is_approach := _approach_stamp[current] == goal_epoch
        var base := current * 3
        var valid: Array = []
        for iteration in range(2):
            if iteration == 1:
                if not has_dir or not valid.is_empty():
                    break
            var angle_limit := (max_angle if iteration == 0 else soft_angle) + 0.02
            for k in range(degree[current]):
                var n := nbr[base + k]
                if _used[n] and _goal_stamp[n] != goal_epoch:
                    continue
                if forb[base + k]:
                    if _goal_stamp[n] != goal_epoch \
                            and not (_approach_stamp[n] == goal_epoch and not current_is_approach):
                        continue
                if has_dir and abs((positions[n] - current_pos).angle_to(dir)) > angle_limit:
                    continue
                valid.append(n)
            if not has_dir:
                break

        var g_current := _g_score[current]
        for n in valid:
            var tentative := g_current + edge_len
            if _seen_stamp[n] != epoch or tentative < _g_score[n]:
                _seen_stamp[n] = epoch
                _g_score[n] = tentative
                _came_from[n] = current
                _heap_stamp[n] = epoch
                var h := _dist_field[n]
                open_set.push(n, tentative + (float(h) * edge_len if h >= 0 else 0.0))
    return PackedInt32Array()


func _reconstruct_path(current: int) -> PackedInt32Array:
    var total: Array = []
    while current >= 0:
        total.append(current)
        current = _came_from[current]
    total.reverse()
    return PackedInt32Array(total)


# -------------------------------------------------------
# Marks all the vertices of the river as occupied.
# -------------------------------------------------------
func _mark_used(path: PackedInt32Array) -> void:
    for id in path:
        if _used[id] == 0:
            _used[id] = 1
            _used_ids.append(id)


# -------------------------------------------------------
# Converts an array of vertex ids into an array of world coordinates.
# -------------------------------------------------------
func _ids_to_positions(path: PackedInt32Array) -> Array:
    var positions := _graph_positions
    var result: Array = []
    for id in path:
        result.append(positions[id])
    return result


# -------------------------------------------------------
# Finds the vertex id by a world position. A saved river keeps only the coordinates,
# so the lookup is spatial: the nearest vertex within POS_SNAP.
# -------------------------------------------------------
func _find_vertex_id(pos: Vector2, graph: Dictionary) -> int:
    var buckets: Dictionary = graph["pos_buckets"]
    var positions: PackedVector2Array = graph["positions"]
    var bx := floori(pos.x / POS_BUCKET)
    var by := floori(pos.y / POS_BUCKET)
    var best := -1
    var best_dist := POS_SNAP * POS_SNAP
    for dx in [-1, 0, 1]:
        for dy in [-1, 0, 1]:
            var ids = buckets.get(Vector2i(bx + dx, by + dy))
            if ids == null:
                continue
            for id in ids:
                var dist := positions[id].distance_squared_to(pos)
                if dist < best_dist:
                    best_dist = dist
                    best = id
    return best


# -------------------------------------------------------
# Returns the list of the rivers (an array of points) — for the rendering and the saving
# -------------------------------------------------------
func get_rivers() -> Array:
    return rivers


# -------------------------------------------------------
# Returns only the main rivers (for a different drawing)
# -------------------------------------------------------
func get_main_rivers() -> Array:
    return main_rivers


# -------------------------------------------------------
# Returns only the tributaries (for a different drawing)
# -------------------------------------------------------
func get_tributaries() -> Array:
    return tributaries


# -------------------------------------------------------
# Returns the last built graph of the vertices (for a repeated
# use in mark_river_edges without rebuilding it).
# -------------------------------------------------------
func get_cached_graph() -> Dictionary:
    return _cached_graph


# -------------------------------------------------------
# Serializes the rivers for the save (Vector2 -> [x, y]).
# The format is a dictionary { "main": [...], "tributaries": [...] },
# so that on loading the difference between the main rivers and the tributaries is preserved.
# -------------------------------------------------------
func serialize_rivers():
    return {
        "main": _serialize_list(main_rivers),
        "tributaries": _serialize_list(tributaries)
    }


# -------------------------------------------------------
# An auxiliary method: serializes the list of the rivers to [x, y]
# -------------------------------------------------------
func _serialize_list(river_list: Array) -> Array:
    var result: Array = []
    for river in river_list:
        var pts: Array = []
        for pt in river:
            pts.append([pt.x, pt.y])
        result.append(pts)
    return result


# -------------------------------------------------------
# Loads the rivers from the saved data.
# Both formats are supported:
#   - the new one: a dictionary { "main": [...], "tributaries": [...] };
#   - the old one: a simple array of arrays (all the rivers are considered main).
# -------------------------------------------------------
func load_rivers(river_data) -> void:
    # If there is no data to load — we do NOT clear, so as not to erase
    # the rivers generated in _initialize_map() for a new game
    if river_data == null or river_data.is_empty():
        return

    main_rivers = []
    tributaries = []

    if river_data is Dictionary:
        main_rivers = _deserialize_list(river_data.get("main", []))
        tributaries = _deserialize_list(river_data.get("tributaries", []))
    else:
        main_rivers = _deserialize_list(river_data)

    rivers = main_rivers + tributaries


# -------------------------------------------------------
# An auxiliary method: deserializes the list of the rivers from [x, y]
# -------------------------------------------------------
func _deserialize_list(river_list: Array) -> Array:
    var result: Array = []
    for river_pts in river_list:
        var river: Array = []
        for pt in river_pts:
            river.append(Vector2(float(pt[0]), float(pt[1])))
        result.append(river)
    return result

# Marks the edges of the rivers in the hex data.
# graph — an optional ready graph (from get_cached_graph()); if it is not passed
# or is empty — the graph is rebuilt.
func mark_river_edges(tile_data: Array, rows: int, cols: int, radius: float, graph: Dictionary = {}) -> void:
    if tile_data == null or tile_data.size() == 0:
        return

    var use_graph = graph if not graph.is_empty() else _build_vertex_graph(rows, cols, radius)
    var hex_off: PackedInt32Array = use_graph["hex_off"]
    var hex_data: PackedInt32Array = use_graph["hex_data"]

    # We clear the existing river_edges, if there are any
    for row in range(rows):
        for col in range(cols):
            var tile = tile_data[row][col]
            if tile != null:
                tile["river_edges"] = []

    for river in rivers:
        if river.size() < 2:
            continue
        var prev_pos = river[0]
        var prev_id := _find_vertex_id(prev_pos, use_graph)
        for i in range(1, river.size()):
            var cur_pos = river[i]
            var cur_id := _find_vertex_id(cur_pos, use_graph)
            if prev_id < 0 or cur_id < 0:
                prev_pos = cur_pos
                prev_id = cur_id
                continue
            for a in range(hex_off[prev_id], hex_off[prev_id + 1]):
                var ma := hex_data[a]
                var hex_a := ma / 6
                var v1 := ma % 6
                for b in range(hex_off[cur_id], hex_off[cur_id + 1]):
                    var mb := hex_data[b]
                    if mb / 6 != hex_a:
                        continue
                    var v2 := mb % 6
                    var edge_index := -1
                    if (v1 + 1) % 6 == v2:
                        edge_index = v1
                    elif (v2 + 1) % 6 == v1:
                        edge_index = v2
                    if edge_index >= 0:
                        var tile = tile_data[hex_a / cols][hex_a % cols]
                        if tile != null:
                            var edges = tile.get("river_edges", [])
                            if edge_index not in edges:
                                edges.append(edge_index)
                                tile["river_edges"] = edges
            prev_pos = cur_pos
            prev_id = cur_id
