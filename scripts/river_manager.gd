# river_manager.gd
# The river manager: generates the river system on the map.
#
# The generation scheme (the river system):
#   - Main rivers: the source in the mountains, the mouth in a lake or the sea. They do not intersect each other.
#   - Tributaries: the source in the mountains (or hills, if there are few mountains), flowing into the main
#     rivers or into other tributaries (a confluence point). The tributaries do not flow into the lakes and the seas.
#   - It is guaranteed that at least one river passes through the starting area
#     "Ring + Region" (for this, if necessary, an additional main river is generated
#     through an intermediate vertex inside the area).
#   - The rivers do not run along the edges of the lake/sea hexes and their neighbours (except
#     for the last step into the mouth/confluence point), so that the river does not flow along the shore.
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
const NUM_RIVER_ATTEMPTS := 40 # The attempts to build one river

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


# -------------------------------------------------------
# A minimal binary heap (priority queue) for A*.
# push/pop in O(log n) instead of sort_custom + pop_front in O(n log n) per step.
# -------------------------------------------------------
class PriorityQueue:
    var _keys: Array = []
    var _priorities: Array = []

    func push(key: String, priority: float) -> void:
        _keys.append(key)
        _priorities.append(priority)
        _sift_up(_keys.size() - 1)

    func pop_min() -> String:
        if _keys.is_empty():
            return ""
        var top: String = _keys[0]
        var last_idx: int = _keys.size() - 1
        _keys[0] = _keys[last_idx]
        _priorities[0] = _priorities[last_idx]
        _keys.resize(last_idx)
        _priorities.resize(last_idx)
        if _keys.size() > 1:
            _sift_down(0)
        return top

    func is_empty() -> bool:
        return _keys.is_empty()

    func _sift_up(idx: int) -> void:
        while idx > 0:
            var parent: int = (idx - 1) >> 1
            if _priorities[idx] < _priorities[parent]:
                var tk: String = _keys[idx]
                _keys[idx] = _keys[parent]
                _keys[parent] = tk
                var tp: float = _priorities[idx]
                _priorities[idx] = _priorities[parent]
                _priorities[parent] = tp
                idx = parent
            else:
                break

    func _sift_down(idx: int) -> void:
        var size: int = _keys.size()
        while true:
            var left: int = idx * 2 + 1
            var right: int = left + 1
            var smallest: int = idx
            if left < size and _priorities[left] < _priorities[smallest]:
                smallest = left
            if right < size and _priorities[right] < _priorities[smallest]:
                smallest = right
            if smallest == idx:
                break
            var tk: String = _keys[idx]
            _keys[idx] = _keys[smallest]
            _keys[smallest] = tk
            var tp: float = _priorities[idx]
            _priorities[idx] = _priorities[smallest]
            _priorities[smallest] = tp
            idx = smallest


# -------------------------------------------------------
# The main method: generates the river system on the map.
# tile_data — a 2D array of the hexes (to determine the mountains/lakes/hills).
# region_* — the bounds of the starting area "Ring + Region" (inclusive),
# through which at least one river must pass.
# -------------------------------------------------------
func generate_rivers(rows: int, cols: int, radius: float, tile_data: Array,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> void:
    rivers = []
    if rows < 3 or cols < 3:
        return

    # The hexes along which the rivers CANNOT flow (the lakes and their neighbours, the swamps
    # themselves and the marsh hexes). They are built BEFORE the graph, so that the flags of the forbidden edges
    # are precomputed in the graph itself (an O(1) check during A*
    # instead of O(hexes^2) per neighbour).
    var restricted_hexes = _build_restricted_hexes(tile_data, rows, cols)

    var graph = _build_vertex_graph(rows, cols, radius, restricted_hexes)
    _cached_graph = graph

    # The candidates for the sources (the mountains) and the mouths of the main rivers (the lakes and the seas).
    var mountain_vertices = _find_terrain_vertices(graph, tile_data, "mountain")
    var lake_vertices = _find_terrain_vertices(graph, tile_data, "lake")
    var sea_vertices = _find_terrain_vertices(graph, tile_data, "sea") \
            + _find_terrain_vertices(graph, tile_data, "shallow_sea")
    var hill_vertices = _find_terrain_vertices(graph, tile_data, "hill")

    # The mouths of the main rivers: the lakes + the seas. If there are neither lakes nor seas — we do not build the rivers.
    var mouth_vertices: Array = lake_vertices + sea_vertices
    if mountain_vertices.is_empty() or mouth_vertices.is_empty():
        print("RIVER DEBUG: there are no mountains or mouths (lakes/seas), exiting")
        return

    # The parameters from the configuration.
    var cfg: Dictionary = GameData.map_config
    var num_main = int(cfg.get("num_main_rivers", 3))
    var num_trib = int(cfg.get("num_tributaries", 5))
    var min_main_len = int(cfg.get("min_river_length", 8))
    var min_trib_len = int(cfg.get("min_tributary_length", 4))

    var used_vertices: Dictionary = {} # The vertices already occupied by the rivers
    main_rivers = []

    # --- The generation of the main rivers (mountain -> lake/sea, they do not intersect) ---
    # _try_generate_main_river returns the best path found (a compromise),
    # even if it is shorter than min_river_length. Therefore we accept any non-empty
    # river: with 40 attempts the overwhelming majority of the paths is still longer than
    # min_len, and the fallback guarantees that we do not get 0 rivers because of
    # a random shortfall of the length (which was also the cause of the bug).
    for _i in range(num_main):
        var river = _try_generate_main_river(graph, mountain_vertices, mouth_vertices,
                restricted_hexes, used_vertices, min_main_len)
        if not river.is_empty():
            _mark_used(river, used_vertices)
            main_rivers.append(river)
    print("RIVER DEBUG: main rivers generated=", main_rivers.size())

    # --- The guarantee: at least one river passes through the starting area ---
    if not _any_river_in_region(main_rivers, graph,
            region_start_row, region_end_row, region_start_col, region_end_col):
        var forced = _try_generate_forced_river(graph, mountain_vertices, mouth_vertices,
                restricted_hexes, used_vertices, min_main_len,
                region_start_row, region_end_row, region_start_col, region_end_col)
        if forced.size() >= min_main_len:
            _mark_used(forced, used_vertices)
            main_rivers.append(forced)

    # --- The generation of the tributaries (mountain/hill -> an occupied vertex, a confluence) ---
    tributaries = []
    for _i in range(num_trib):
        var river = _try_generate_tributary(graph, mountain_vertices, hill_vertices,
                lake_vertices, sea_vertices, restricted_hexes, used_vertices, min_trib_len)
        if river.size() >= min_trib_len:
            _mark_used(river, used_vertices)
            tributaries.append(river)

    rivers = main_rivers + tributaries
    print("RIVER DEBUG: total rivers=", rivers.size())


# -------------------------------------------------------
# Tries to generate one main river: the source in the mountains, the mouth in a lake/sea.
# The main rivers do not intersect: A* goes with forbidden = used_vertices.
# -------------------------------------------------------
func _try_generate_main_river(graph: Dictionary, mountain_vertices: Array,
        mouth_vertices: Array, restricted_hexes: Dictionary,
        used_vertices: Dictionary, min_len: int) -> Array:
    var free_mountains: Array = []
    for vk in mountain_vertices:
        if not used_vertices.has(vk) and not mouth_vertices.has(vk) and not _vertex_in_hexes(vk, graph, restricted_hexes):
            free_mountains.append(vk)
    var free_mouths: Array = []
    for vk in mouth_vertices:
        if not used_vertices.has(vk):
            free_mouths.append(vk)
    if free_mountains.is_empty() or free_mouths.is_empty():
        return []

    var best_path_len := 0
    var best_path: Array = [] # The best path found (a compromise, if none reaches min_len)
    var best_attempt := -1
    # The pairs (start -> goal) already searched in THIS call. The inputs of the search
    # (graph/used_vertices/restricted_hexes) do not change between the attempts of one
    # _try_generate_main_river, so a pair that failed once fails identically again: a
    # repeated pair is skipped instead of re-running the same A*. The RNG is still drawn
    # for every attempt, so the stream and the outcome are unchanged - only the redundant
    # A* runs disappear (the repeated failures are exactly what burned tens of attempts
    # per river).
    var tried_pairs: Dictionary = {}
    for _attempt in range(NUM_RIVER_ATTEMPTS):
        var start = free_mountains[randi() % free_mountains.size()]
        var goal = free_mouths[randi() % free_mouths.size()]
        var pair_key: String = start + "|" + goal
        if tried_pairs.has(pair_key):
            continue
        tried_pairs[pair_key] = true
        var path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_DEG, {}, restricted_hexes)
        if path.is_empty():
            path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, {}, restricted_hexes)
        if path.size() > best_path_len:
            best_path_len = path.size()
            best_path = path
            best_attempt = _attempt
        if path.size() >= min_len:
            return _keys_to_positions(path, graph)
    if best_path_len > 0:
        print("    [RIVER] main: best=%d (need %d) at attempt %d, used_vertices=%d" % [best_path_len, min_len, best_attempt, used_vertices.size()])
        return _keys_to_positions(best_path, graph)
    return []


# -------------------------------------------------------
# Tries to generate a tributary: the source in the mountains (or hills, if there are few mountains),
# the mouth — an occupied vertex (the confluence point with any river). The tributaries do not flow
# into the lakes and the seas: their vertices are excluded from merge_keys.
# -------------------------------------------------------
func _try_generate_tributary(graph: Dictionary, mountain_vertices: Array,
        hill_vertices: Array, lake_vertices: Array, sea_vertices: Array,
        restricted_hexes: Dictionary, used_vertices: Dictionary, min_len: int) -> Array:
    if used_vertices.is_empty():
        return []

    # The source: the free mountain vertices; if there are too few — we add the hilly ones.
    var free_sources: Array = []
    for vk in mountain_vertices:
        if not used_vertices.has(vk) and not lake_vertices.has(vk) and not sea_vertices.has(vk) and not _vertex_in_hexes(vk, graph, restricted_hexes):
            free_sources.append(vk)
    if free_sources.size() < 3:
        for vk in hill_vertices:
            if not used_vertices.has(vk) and not lake_vertices.has(vk) and not sea_vertices.has(vk) and not _vertex_in_hexes(vk, graph, restricted_hexes):
                free_sources.append(vk)
    if free_sources.is_empty():
        return []

    # The mouths: the occupied vertices, excluding the lake and sea ones (the tributaries do not flow into them).
    var merge_keys: Dictionary = used_vertices.duplicate()
    for vk in lake_vertices:
        merge_keys.erase(vk)
    for vk in sea_vertices:
        merge_keys.erase(vk)
    if merge_keys.is_empty():
        return []
    var merge_list: Array = merge_keys.keys()

    for _attempt in range(NUM_RIVER_ATTEMPTS):
        var start = free_sources[randi() % free_sources.size()]
        var goal = merge_list[randi() % merge_list.size()]
        var path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_DEG, merge_keys, restricted_hexes)
        if path.is_empty():
            path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, merge_keys, restricted_hexes)
        if path.size() >= min_len:
            return _keys_to_positions(path, graph)
    return []


# -------------------------------------------------------
# Forcefully generates a main river guaranteed to pass through
# the starting area. It picks a mountain on one side of the area and a lake/sea on
# the other, takes a free vertex inside the area as an intermediate point
# (waypoint) and builds the path "mountain -> waypoint -> lake/sea".
# -------------------------------------------------------
func _try_generate_forced_river(graph: Dictionary, mountain_vertices: Array,
        mouth_vertices: Array, restricted_hexes: Dictionary,
        used_vertices: Dictionary, min_len: int,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> Array:
    # The pairs of sides: [source, mouth]. We try all the combinations.
    var side_pairs: Array = [
        ["top", "bottom"], ["bottom", "top"],
        ["left", "right"], ["right", "left"]
    ]

    for side_pair in side_pairs:
        var src_side = _vertices_on_side(mountain_vertices, graph, side_pair[0],
                region_start_row, region_end_row, region_start_col, region_end_col)
        var dst_side = _vertices_on_side(mouth_vertices, graph, side_pair[1],
                region_start_row, region_end_row, region_start_col, region_end_col)

        var free_src: Array = []
        for vk in src_side:
            if not used_vertices.has(vk) and not mouth_vertices.has(vk) and not _vertex_in_hexes(vk, graph, restricted_hexes):
                free_src.append(vk)
        var free_dst: Array = []
        for vk in dst_side:
            if not used_vertices.has(vk):
                free_dst.append(vk)
        if free_src.is_empty() or free_dst.is_empty():
            continue

        # Finds the free vertices inside the area as the intermediate points.
        var region_vertices = _vertices_in_region(graph,
                region_start_row, region_end_row, region_start_col, region_end_col)
        var free_waypoints: Array = []
        for vk in region_vertices:
            if not used_vertices.has(vk) and not _vertex_in_hexes(vk, graph, restricted_hexes):
                free_waypoints.append(vk)
        if free_waypoints.is_empty():
            continue

        for _attempt in range(NUM_RIVER_ATTEMPTS):
            var start = free_src[randi() % free_src.size()]
            var goal = free_dst[randi() % free_dst.size()]
            var wp = free_waypoints[randi() % free_waypoints.size()]

            var path1 = _find_path_astar(start, wp, graph, used_vertices, MAX_TURN_ANGLE_DEG, {}, restricted_hexes)
            if path1.is_empty():
                path1 = _find_path_astar(start, wp, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, {}, restricted_hexes)
            if path1.is_empty():
                continue

            var path2 = _find_path_astar(wp, goal, graph, used_vertices, MAX_TURN_ANGLE_DEG, {}, restricted_hexes)
            if path2.is_empty():
                path2 = _find_path_astar(wp, goal, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, {}, restricted_hexes)
            if path2.is_empty():
                continue

            # We merge the paths (the waypoint is not duplicated).
            var combined: Array = path1.duplicate()
            for i in range(1, path2.size()):
                combined.append(path2[i])
            if combined.size() >= min_len:
                return _keys_to_positions(combined, graph)
    return []


# -------------------------------------------------------
# Finds the vertices at which at least one hex has the given relief.
# -------------------------------------------------------
func _find_terrain_vertices(graph: Dictionary, tile_data: Array, terrain_id: String) -> Array:
    var vertex_hexes: Dictionary = graph["hexes"]
    var result: Array = []
    for vk in vertex_hexes.keys():
        for hex_info in vertex_hexes[vk]:
            if tile_data[hex_info.row][hex_info.col]["terrain"] == terrain_id:
                result.append(vk)
                break
    return result


# -------------------------------------------------------
# Finds the hexes along which the rivers CANNOT flow:
#   - the lake and sea hexes and their neighbours (so that the river does not flow along the shore);
#   - the swamp (swamp) and marsh (marsh) hexes themselves — the rivers do not pass through them.
# It returns a dictionary with the keys "row_col" -> true.
# -------------------------------------------------------
func _build_restricted_hexes(tile_data: Array, rows: int, cols: int) -> Dictionary:
    var result: Dictionary = {}

    # We collect the lake and sea hexes.
    var water_hexes: Array = []
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            if terrain_id == "lake" or terrain_id == "sea" or terrain_id == "shallow_sea":
                water_hexes.append({"row": row, "col": col})

    # We mark the water hexes and their neighbours.
    for wh in water_hexes:
        result["%d_%d" % [wh.row, wh.col]] = true
        for n in HexUtils.get_neighbors_odd_r(wh.row, wh.col, rows, cols):
            result["%d_%d" % [n.row, n.col]] = true

    # The swamp and marsh hexes themselves — the rivers do not pass through them (their neighbours
    # are not marked: that would be too restrictive).
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            if terrain_id == "swamp" or terrain_id == "marsh":
                result["%d_%d" % [row, col]] = true

    return result


# -------------------------------------------------------
# Returns true if the vertex belongs to at least one hex from the dictionary.
# -------------------------------------------------------
func _vertex_in_hexes(vk: String, graph: Dictionary, hexes_dict: Dictionary) -> bool:
    var vertex_hexes: Dictionary = graph["hexes"]
    if not vertex_hexes.has(vk):
        return false
    for hex_info in vertex_hexes[vk]:
        if hexes_dict.has("%d_%d" % [hex_info.row, hex_info.col]):
            return true
    return false


# -------------------------------------------------------
# Returns true if the edge (a_key -> b_key) belongs to at least one
# forbidden hex (a lake or its neighbour).
# -------------------------------------------------------
func _edge_in_forbidden_hexes(a_key: String, b_key: String, vertex_hexes: Dictionary, forbidden_hexes: Dictionary) -> bool:
    if forbidden_hexes.is_empty():
        return false
    if not vertex_hexes.has(a_key) or not vertex_hexes.has(b_key):
        return false
    var a_hexes = vertex_hexes[a_key]
    var b_hexes = vertex_hexes[b_key]
    for ha in a_hexes:
        for hb in b_hexes:
            if ha.row == hb.row and ha.col == hb.col:
                if forbidden_hexes.has("%d_%d" % [ha.row, ha.col]):
                    return true
    return false


# -------------------------------------------------------
# Returns the vertices from the list at which there is a hex on the specified side
# of the starting area (top/bottom/left/right).
# -------------------------------------------------------
func _vertices_on_side(vertices: Array, graph: Dictionary, side: String,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> Array:
    var vertex_hexes: Dictionary = graph["hexes"]
    var result: Array = []
    for vk in vertices:
        for hex_info in vertex_hexes[vk]:
            var ok := false
            if side == "top" and hex_info.row < region_start_row:
                ok = true
            elif side == "bottom" and hex_info.row > region_end_row:
                ok = true
            elif side == "left" and hex_info.col < region_start_col:
                ok = true
            elif side == "right" and hex_info.col > region_end_col:
                ok = true
            if ok:
                result.append(vk)
                break
    return result


# -------------------------------------------------------
# Returns all the vertices at which there is a hex inside the starting area.
# -------------------------------------------------------
func _vertices_in_region(graph: Dictionary,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> Array:
    var vertex_hexes: Dictionary = graph["hexes"]
    var result: Array = []
    for vk in vertex_hexes.keys():
        for hex_info in vertex_hexes[vk]:
            if hex_info.row >= region_start_row and hex_info.row <= region_end_row and \
               hex_info.col >= region_start_col and hex_info.col <= region_end_col:
                result.append(vk)
                break
    return result


# -------------------------------------------------------
# Checks whether at least one river passes through the starting area.
# -------------------------------------------------------
func _any_river_in_region(rivers_list: Array, graph: Dictionary,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> bool:
    var vertex_hexes: Dictionary = graph["hexes"]
    for river in rivers_list:
        for pt in river:
            var key = _vertex_key(pt)
            if vertex_hexes.has(key):
                for hex_info in vertex_hexes[key]:
                    if hex_info.row >= region_start_row and hex_info.row <= region_end_row and \
                       hex_info.col >= region_start_col and hex_info.col <= region_end_col:
                        return true
    return false


# -------------------------------------------------------
# Marks all the vertices of the river as occupied.
# -------------------------------------------------------
func _mark_used(river: Array, used_vertices: Dictionary) -> void:
    for pt in river:
        used_vertices[_vertex_key(pt)] = true


# -------------------------------------------------------
# Converts an array of vertex keys into an array of world coordinates.
# -------------------------------------------------------
func _keys_to_positions(path_keys: Array, graph: Dictionary) -> Array:
    var positions: Dictionary = graph["positions"]
    var path: Array = []
    for k in path_keys:
        path.append(positions[k])
    return path


# -------------------------------------------------------
# Builds the "graph of the vertices": the nodes = the unique points of the world coordinates,
# the edges = the connections through the neighbouring vertices inside the hexes.
#
# The optimisation: the flag "forb" (the edge belongs to a forbidden hex by a lake)
# is precomputed here ONCE for all the edges, therefore A* checks
# the prohibition in O(1) per neighbour instead of iterating over the hexes of both vertices.
# -------------------------------------------------------
func _build_vertex_graph(rows: int, cols: int, radius: float, forbidden_hexes: Dictionary = {}) -> Dictionary:
    var vertex_positions: Dictionary = {} # key -> Vector2
    var vertex_hexes: Dictionary = {} # key -> Array of {row, col, vidx}

    for row in range(rows):
        for col in range(cols):
            for vidx in range(6):
                var pos = HexUtils.hex_vertex(row, col, vidx, radius)
                var key = _vertex_key(pos)
                if not vertex_positions.has(key):
                    vertex_positions[key] = pos
                    vertex_hexes[key] = []
                vertex_hexes[key].append({"row": row, "col": col, "vidx": vidx})

    # The adjacency graph: for each vertex the neighbours are
    # the vertices (vidx-1)%6 and (vidx+1)%6 in each hex containing the vertex.
    # The representation — PARALLEL ARRAYS (important for the speed of A*):
    #   neighbors[vkey] = Array of String (the keys of the neighbours)
    #   forb_mask[vkey] = Array of bool  (true = the edge lies in a hex by a lake)
    # This gives an O(1) check of a forbidden edge without allocating a dictionary per edge.
    var neighbors: Dictionary = {}
    var forb_mask: Dictionary = {}
    var forbidden_empty := forbidden_hexes.is_empty()
    for vkey in vertex_positions.keys():
        var nbrs: Array = []
        var forbs: Array = []
        var nbr_set: Dictionary = {} # the deduplication of the neighbours
        var hex_list = vertex_hexes[vkey]
        for hex_info in hex_list:
            for delta in [-1, 1]:
                var nvi = (hex_info.vidx + delta) % 6
                var npos = HexUtils.hex_vertex(hex_info.row, hex_info.col, nvi, radius)
                var nkey = _vertex_key(npos)
                if nkey != vkey and not nbr_set.has(nkey):
                    nbr_set[nkey] = true
                    nbrs.append(nkey)
                    forbs.append(false if forbidden_empty else _edge_in_forbidden_hexes(vkey, nkey, vertex_hexes, forbidden_hexes))
        neighbors[vkey] = nbrs
        forb_mask[vkey] = forbs

    return {
        "positions": vertex_positions,
        "neighbors": neighbors,
        "hexes": vertex_hexes,
        "forb": forb_mask
    }


# -------------------------------------------------------
# The rounding of the position for creating a stable vertex key
# -------------------------------------------------------
func _vertex_key(pos: Vector2) -> String:
    return "%d_%d" % [roundi(pos.x * 100.0), roundi(pos.y * 100.0)]


# -------------------------------------------------------
# The A* search of a path between two vertices of the graph with a filtering
# by the turn angle. It returns an array of the vertex keys or an empty array.
#
# forbidden_keys — the vertices occupied by other rivers (it is not allowed to pass through,
# except goal_key and merge_keys).
# forbidden_hexes — the hexes by the lakes (the lake + the neighbours). The flags of the forbidden edges
# are precomputed in the graph (the "forb" field — a parallel bool array).
# The river cannot pass along the EDGES by the lakes, except for the last step into the mouth/
# confluence point. So that the river can enter the lake, one step
# outside to the vertex neighbouring the mouth (approach) is allowed, after which the path must
# finish at the mouth.
# merge_keys — the vertices at which the path can end (the confluence points).
#
# The key optimisations (the replacement of sort_custom + pop_front of the original code):
#   - the open list — a binary heap (PriorityQueue): push/pop in O(log n);
#   - in_heap + closed_set: the stale entries of the heap are skipped, the heap does not
#     grow, each vertex is processed exactly once;
#   - the check of the forbidden edges — O(1) by the precomputed flag forb;
#   - angle_to does not require normalized vectors — normalized() is removed.
# -------------------------------------------------------
func _find_path_astar(start_key: String, goal_key: String, graph: Dictionary, forbidden_keys: Dictionary, max_turn_angle_deg: float, merge_keys: Dictionary = {}, forbidden_hexes: Dictionary = {}) -> Array:
    var vertex_positions: Dictionary = graph["positions"]
    var neighbors_map: Dictionary = graph["neighbors"]
    var forb_mask: Dictionary = graph.get("forb", {})

    # We limit the search area by the bbox around start and goal.
    # This speeds up A* many times over on large maps, without changing the data format of the rivers:
    # the path is still built along the hex vertices, therefore mark_river_edges
    # and all the functionality (the bonuses at the rivers, near_river) work as before.
    var start_pos = vertex_positions[start_key]
    var goal_pos = vertex_positions[goal_key]
    var min_x = minf(start_pos.x, goal_pos.x)
    var max_x = maxf(start_pos.x, goal_pos.x)
    var min_y = minf(start_pos.y, goal_pos.y)
    var max_y = maxf(start_pos.y, goal_pos.y)
    # The margin: 25% of the sum of the sides of the bbox, but not less than a fixed minimum,
    # so that the river can bend naturally and flow into the merge vertices.
    var margin = maxf((max_x - min_x + max_y - min_y) * 0.25, 200.0)
    min_x -= margin
    max_x += margin
    min_y -= margin
    max_y += margin

    # The vertices through which the river can approach the mouth/confluence:
    # the mouth itself and its immediate neighbours. Entering such a vertex from outside
    # is allowed (one step), after which the path must finish at the mouth.
    var approach_keys: Dictionary = {}
    approach_keys[goal_key] = true
    var goal_nbrs: Array = neighbors_map.get(goal_key, [])
    for n in goal_nbrs:
        approach_keys[n] = true
    for mk in merge_keys.keys():
        approach_keys[mk] = true
        var mk_nbrs: Array = neighbors_map.get(mk, [])
        for n in mk_nbrs:
            approach_keys[n] = true

    var open_set = PriorityQueue.new()
    open_set.push(start_key, _heuristic(start_key, goal_key, vertex_positions))
    var came_from: Dictionary = {}
    var g_score: Dictionary = {start_key: 0.0}
    var closed_set: Dictionary = {}
    var in_heap: Dictionary = {start_key: true}

    var has_merge := not merge_keys.is_empty()
    var has_forbidden := not forbidden_keys.is_empty()
    var has_forb := not forb_mask.is_empty()
    var max_angle_rad = deg_to_rad(max_turn_angle_deg)
    var soft_angle_rad = deg_to_rad(max_turn_angle_deg + 30.0)

    while not open_set.is_empty():
        var current = open_set.pop_min()
        # The lazy deletion: we skip the stale entries of the heap.
        if not in_heap.has(current):
            continue
        in_heap.erase(current)
        # closed_set — each vertex is processed exactly once.
        if closed_set.has(current):
            continue
        closed_set[current] = true

        if current == goal_key or (has_merge and merge_keys.has(current)):
            return _reconstruct_path(came_from, current)

        var current_pos = vertex_positions[current]
        var dir = Vector2.ZERO
        if came_from.has(current):
            dir = current_pos - vertex_positions[came_from[current]]
        else:
            # For the starting vertex the direction to the goal
            dir = vertex_positions[goal_key] - current_pos

        # The neighbours:
        # 1) The vertices occupied by other rivers are forbidden (except the mouth/confluence).
        # 2) The edges with the flag forb are forbidden, EXCEPT:
        #    - the last step into the mouth/confluence point;
        #    - one step from outside to the approach vertex (to enter the lake).
        #    A transition between two approach vertices is forbidden — that prevents
        #    the river from flowing along the shore of the lake.
        # We discard the neighbours outside the bbox — that is the main speedup.
        var current_is_approach = approach_keys.has(current)
        var candidates: Array = []
        var current_nbrs: Array = neighbors_map[current]
        var current_forbs: Array = forb_mask.get(current, [])
        for i in range(current_nbrs.size()):
            var n: String = current_nbrs[i]
            if has_forbidden and forbidden_keys.has(n) and n != goal_key and not merge_keys.has(n):
                continue
            if has_forb and i < current_forbs.size() and current_forbs[i]:
                if n == goal_key or merge_keys.has(n):
                    pass # the last step into the mouth/confluence is allowed
                elif approach_keys.has(n) and not current_is_approach:
                    pass # entering from outside to the approach vertex is allowed
                else:
                    continue
            var npos = vertex_positions[n]
            if npos.x < min_x or npos.x > max_x or npos.y < min_y or npos.y > max_y:
                continue
            candidates.append(n)

        # We filter by the angle
        var valid: Array = _filter_by_angle(candidates, current_pos, dir, vertex_positions, max_angle_rad)
        if valid.is_empty():
            valid = _filter_by_angle(candidates, current_pos, dir, vertex_positions, soft_angle_rad)
            if valid.is_empty():
                continue

        var g_current = g_score[current]
        for neighbor in valid:
            var tentative_g = g_current + current_pos.distance_to(vertex_positions[neighbor])
            if tentative_g < g_score.get(neighbor, INF):
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                open_set.push(neighbor, tentative_g + _heuristic(neighbor, goal_key, vertex_positions))
                in_heap[neighbor] = true
    return []


func _heuristic(a_key: String, b_key: String, vertex_positions: Dictionary) -> float:
    return vertex_positions[a_key].distance_to(vertex_positions[b_key])


func _reconstruct_path(came_from: Dictionary, current: String) -> Array:
    var total_path: Array = [current]
    while came_from.has(current):
        current = came_from[current]
        total_path.append(current)
    total_path.reverse()
    return total_path


# -------------------------------------------------------
# Filters the candidates by the turn angle relative to dir.
# max_angle_rad is passed in radians (it is computed once in A*).
# angle_to does not require normalized vectors — normalized() is not needed.
# -------------------------------------------------------
func _filter_by_angle(candidates: Array, current_pos: Vector2, dir: Vector2,
        vertex_positions: Dictionary, max_angle_rad: float) -> Array:
    var valid: Array = []
    for n in candidates:
        var ndir = vertex_positions[n] - current_pos
        var angle = abs(ndir.angle_to(dir))
        if angle <= max_angle_rad + 0.02:
            valid.append(n)
    return valid


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
# The new format is a dictionary { "main": [...], "tributaries": [...] },
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
        # The new format: a dictionary with the separation into main rivers and tributaries.
        main_rivers = _deserialize_list(river_data.get("main", []))
        tributaries = _deserialize_list(river_data.get("tributaries", []))
    else:
        # An array instead of a dictionary — we consider all the rivers main.
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
# or is empty — the graph is rebuilt. This removes the double building of the graph
# (thousands of vertices) when generating a new map.
func mark_river_edges(tile_data: Array, rows: int, cols: int, radius: float, graph: Dictionary = {}) -> void:
    if tile_data == null or tile_data.size() == 0:
        return

    var use_graph = graph if not graph.is_empty() else _build_vertex_graph(rows, cols, radius)
    var vertex_hexes = use_graph["hexes"]

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
        var prev_key = _vertex_key(prev_pos)
        for i in range(1, river.size()):
            var cur_pos = river[i]
            var cur_key = _vertex_key(cur_pos)
            if not vertex_hexes.has(prev_key) or not vertex_hexes.has(cur_key):
                prev_pos = cur_pos
                prev_key = cur_key
                continue
            var prev_hexes = vertex_hexes[prev_key]
            var cur_hexes = vertex_hexes[cur_key]
            var common_hexes = []
            for prev_hex in prev_hexes:
                for cur_hex in cur_hexes:
                    if prev_hex.row == cur_hex.row and prev_hex.col == cur_hex.col:
                        common_hexes.append({"row": prev_hex.row, "col": prev_hex.col, "v1": prev_hex.vidx, "v2": cur_hex.vidx})
            for info in common_hexes:
                var row = info.row
                var col = info.col
                var v1 = info.v1
                var v2 = info.v2
                var edge_index = -1
                if (v1 + 1) % 6 == v2:
                    edge_index = v1
                elif (v2 + 1) % 6 == v1:
                    edge_index = v2
                if edge_index >= 0:
                    var tile = tile_data[row][col]
                    if tile != null:
                        var edges = tile.get("river_edges", [])
                        if edge_index not in edges:
                            edges.append(edge_index)
                            tile["river_edges"] = edges
            prev_pos = cur_pos
            prev_key = cur_key