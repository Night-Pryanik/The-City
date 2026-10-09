# road_manager.gd
extends Node

# The default level of a road: a trail. The segments without an explicit level (for example,
# lifted from an old save, where road_level was not yet there) are considered trails -
# this is the weakest level, that is a safe default.
const DEFAULT_ROAD_LEVEL := 1

# It is emitted when the city is connected by a road to a town for the first time: the segments
# of the road network of the city have reached the road network of this town. On this
# event the trade will be opened in the future (for now - only the icon
# over the hex of the town and the status in its window, see town_manager.is_trade_available).
signal town_link_established(row: int, col: int)

# We store the roads as a Set of the strings in the format "row1,col1|row2,col2" (the canonical direction)
# Canonical = with the smaller sum row+col, or if they are equal, then with the smaller col
#
# The VALUE is NOT true, but the LEVEL of the segment (an int, see data/roads.json). Initially
# there was a Set here, and it worked while all the roads were identical. With the appearance of
# the levels the value became a payload: a segment remembers which level it is,
# and nowhere is a separate list "which segment of which level" needed - it would
# diverge from this dictionary at the first change of the network.
# The default level is a trail (DEFAULT_ROAD_LEVEL), it is also the base of the price: see
# GameData.get_road_by_level.
var road_segments: Dictionary = {}

# The list of the "connected" hexes (those to which a road already exists)
var connected_hexes: Dictionary = {}
var city_row: int = 0
var city_col: int = 0

# The version of the road network of the city. It grows on ANY change of it and by it
# the cache of the planning of the roads is reset (see _plan_cache): the control panel
# asks for the plan on EVERY tick, and the search of the path is a Dijkstra over the whole map, so
# without a cache this would be a heavy work in the game loop.
var _network_version: int = 0
# The version of the KNOWLEDGE of the map by the player: how many times "what is known" changed (a scouting
# completed, a chunk was bought, the epoch changed, a debug opening of the map). The plan
# of a road depends on it as well - the route to a town goes only over the scouted land,
# - therefore the version enters the key of the cache on a par with the version of the network of the roads.
var _knowledge_version: int = 0
# The cache of the plans: "the version of the network:the version of the knowledge:filter|row,col" ->
# { ok, reason, path, segments, is_town }.
var _plan_cache: Dictionary = {}

# === The road networks of the towns ===
# Each town has its own independent network: from the centre of the town - to its
# improvements in the influence ring (they are placed by
# town_manager._place_decorative_town_improvements). The networks are NOT merged: neither with
# the network of the city of the player, nor with each other. This is the responsibility of
# town_connected_hexes - each town has its own set of the connected hexes, and
# the search of a road stops only on a hex of ITS OWN network. Otherwise the "roads from
# a town" would become the roads from the city of the player, and all the towns would also be
# connected to each other by one web of a road through it.
#
# town_road_segments - all the segments of the roads of the towns in one flat dictionary
# (the canonical key of a segment -> the level): for the drawing the set is one anyway,
# and a segment which coincided with a segment of another town is simply drawn once.
# The automatic roads of the towns are always trails (DEFAULT_ROAD_LEVEL): they are built by
# the town itself from its centre, and the town network itself is never improved. When the
# player's road to a town runs along such a trail, the player's own segment (of the chosen
# level) lies in road_segments on the same key - the route and the display take the level from
# the city network then (see _segment_level_by_key and get_hex_road_level).
# town_connected_hexes is keyed by the coordinates of the CENTRE of the town ("row,col"), and not by
# the index in towns: such a key will not "shift" if the towns in the list swap
# places.
var town_road_segments: Dictionary = {}
var town_connected_hexes: Dictionary = {}

# === The roads which the player builds (the special action "Build a road") ===
#
# The special action build_road (action_type "road") builds a segment of the road NETWORK
# of the CITY up to the specified hex - from the nearest already built road, by the same
# search as build_road_from, but IN STAGES: the queue of the segments is led by
# main_map._start_road_project_steps, and each segment is added by one call
# build_road_step. The segments fall into road_segments, and their hexes - into
# connected_hexes, that is a new road becomes a part of the network of the city and
# shortens all the next routes.
#
# town_link_segments is a subset of road_segments: those which lead to a TOWN
# (the target is the town centre itself, see plan_road_to). They are stored separately only
# for the sake of the drawing: such a road can go through the unexplored territory, therefore it is drawn
# with the same gates of the fog as the roads of the towns (map_renderer.
# is_town_road_segment_visible) - otherwise it would give away the contents of the fog.
var town_link_segments: Dictionary = {}

# The cache of the ROUTES: "the version of the network|row,col|town_row,town_col" -> a route
# (see find_route_to_city). The control panel asks for the route of the chosen
# hex on every update, and the search is a traversal of the whole network, therefore without a cache
# this would be an extra work in the game loop. Unlike _plan_cache the key does not
# include the version of the knowledge about the map: the route goes along the ALREADY BUILT roads,
# and not along the terrain, therefore it does not depend on the scouting.
var _route_cache: Dictionary = {}

# The initialization after the generation of the map
func initialize(new_city_row: int, new_city_col: int):
    self.city_row = new_city_row
    self.city_col = new_city_col
    # A full reset of the networks: initialize() is called once at the start of a party (and both for
    # a new game, and for a load), therefore the state always starts from a clean
    # sheet - otherwise the old networks would leak into a new party.
    road_segments.clear()
    connected_hexes.clear()
    clear_town_roads()
    town_link_segments.clear()
    _invalidate_plan_cache()
    var key = _hex_key(new_city_row, new_city_col)
    connected_hexes[key] = true

func rebuild_roads_from_existing(tile_data: Array, region_rows: int, region_cols: int,
        skip_if: Callable = Callable()):
    # The recalculation of the roads to the improvements by the data of the save. The segments are not written into the save,
    # therefore the input data is the improvements themselves on the hexes: the improvement is there, so
    # the road to it was.
    #
    # The EXCEPTION - the hexes with road_staged: their road is built by a staged
    # project (see main_map.start_improvement_road_project), and its state
    # lies in road_built/road_level on the connected hexes plus in the queue
    # of the projects. The road there may be not finished or cancelled altogether, and
    # to finish it here would mean to give it for free. Such hexes
    # are restored by rebuild_player_roads + the restored project - the same
    # path as that of a road built by the special action.
    #
    # skip_if is a Callable(row, col) -> bool; it is passed by main_map, because
    # road_manager knows nothing about the flags of the hexes, and the load should decide by them.
    for row in range(region_rows):
        for col in range(region_cols):
            var tile = tile_data[row][col]
            if skip_if.is_valid() and bool(skip_if.call(row, col)):
                continue
            # The decorative improvements (tile.decorative) belong to the TOWNS, and
            # not to the player: their roads are built by the town itself from its centre
            # (build_town_road_from). There was no check earlier, and on the load of a
            # save the road network of the CITY OF THE PLAYER grew with the roads to all the fields,
            # the forest plots and the quarries of all the towns on the map (the call
            # rebuild_roads_from_existing goes before the load of the towns, and in the tile_data
            # of the save the improvements of the towns lie together with the improvements of the player).
            if tile != null and tile.get("improvement", null) != null \
                    and not bool(tile.get("decorative", false)):
                build_road_from(row, col, tile_data, region_rows, region_cols)

# Lays a road from an improvement to the nearest connected hex
# in the network of the CITY OF THE PLAYER - ENTIRELY, by one call, without a queue of the steps.
#
# this is the weakest level, that is a safe default.
# together with the improvement goes by a staged project (main_map.
# start_improvement_road_project) and is paid by the segments, like any road.
# The function remained for the RESTORATION from the save and for the tests: there the network is not
# built, but recalculated by the input data, therefore the queue and the payment are not
# needed - the result must be the same.
#
# road_level is the level of the road being laid (by default a trail). On
# the restoration it is passed by the caller: the level lies in tile["road_level"]
# and without it the restored network would be a continuous trail.
func build_road_from(
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    road_level: int = DEFAULT_ROAD_LEVEL
):
    var start_key = _hex_key(start_row, start_col)
    if connected_hexes.has(start_key):
        return

    var best_path = _find_connect_path(start_row, start_col, connected_hexes,
            tile_data, region_rows, region_cols)
    if best_path.is_empty():
        return

    # We add all the segments of the road
    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        _add_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col, road_level)
        connected_hexes[_hex_key(from_hex.row, from_hex.col)] = true
        connected_hexes[_hex_key(to_hex.row, to_hex.col)] = true
    _invalidate_plan_cache()

# A search of a path common for the city and the towns from (start_row, start_col) to
# the nearest hex from `connected`. It returns the path (an Array of {row, col}) from
# the start to the found target, or an empty array if there is no path.
#
# The rules are the same for both networks, therefore they live here:
#   - the water improvements (for example, the fishing boats) do not lay a road over the
#     water: the access to a water resource is provided by a pier (harbor), standing on the
#     bank, to which a road is built in the standard way as to an ordinary land
#     improvement;
#   - the improvements with the flag no_road do not get a road (the irrigation channels are
#     infrastructure, to which there is no need to lay a road);
#   - the path must consist of adjacent hexes.
#
# There are no side effects: `connected` is NOT replenished - that is done by the calling code,
# and only for ITS OWN network (for the city - connected_hexes, for a town - the set from
# town_connected_hexes). Thanks to this the networks of the towns stay independent,
# see build_town_road_from.
func _find_connect_path(
    start_row: int,
    start_col: int,
    connected: Dictionary,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable = Callable()
) -> Array:
    if start_row >= 0 and start_row < tile_data.size() \
            and start_col >= 0 and start_col < tile_data[start_row].size():
        var start_tile = tile_data[start_row][start_col]
        if start_tile != null and MapHelpers.is_water_terrain(start_tile.get("terrain", "")):
            return []
        var start_imp_id = start_tile.get("improvement", null)
        if start_imp_id != null and GameData.improvements.has(start_imp_id) \
                and GameData.improvements[start_imp_id].get("no_road", false):
            return []

    var best_path = _find_path_between(
        {_hex_key(start_row, start_col): true}, connected,
        tile_data, region_rows, region_cols, hex_allowed
    )
    if best_path.is_empty():
        return []

    # We guarantee that the path consists only of the adjacent hexes
    if not _validate_path(best_path):
        printerr("Error: the path contains non-adjacent hexes!")
        return []
    return best_path

# === The roads of the towns ===

# A full recalculation of the roads of the towns: for each town a road is built from its
# centre to each improvement in its INFLUENCE RING. It must be called AFTER
# town_manager._place_decorative_town_improvements - before it there are no improvements in the ring
# yet, and there will be nothing to build.
#
# The roads are not written into the save - exactly as the city ones: the input data (the towns and their
# improvements) is already in the save, therefore the network is counted from scratch every time, and on
# the screen there is always one and the same picture. Each town gets its OWN independent
# network (see town_connected_hexes).
func rebuild_town_roads(towns: Array, tile_data: Array,
        region_rows: int, region_cols: int) -> void:
    clear_town_roads()
    if towns == null:
        return
    for town in towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        if town_row < 0 or town_col < 0:
            continue
        # The centre of a town is the root of its own network: all the roads are drawn to it.
        _town_connected(town_row, town_col)[_hex_key(town_row, town_col)] = true
        for h in town.get("influence_hexes", []):
            var row := int(h.get("row", -1))
            var col := int(h.get("col", -1))
            if row < 0 or col < 0 or row >= region_rows or col >= region_cols:
                continue
            var tile = tile_data[row][col]
            if tile == null or tile.get("improvement", null) == null:
                continue
            build_town_road_from(town_row, town_col, row, col,
                    tile_data, region_rows, region_cols)

# Lays a road from an improvement (start_row, start_col) to the network of THIS
# town - a full analogue of build_road_from, but in the network of the town. The path is searched
# only up to the hexes connected to THIS town, therefore the road of a town
# logically cannot become a part of the roads of the city of the player or of another town.
# Geometrically the route can go through the hexes of a neighbour (the path is searched over the whole
# map, the water is impassable) - the set of the segments for the drawing of the towns is common,
# and a "common route" is simply drawn once.
func build_town_road_from(
    town_row: int,
    town_col: int,
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int
) -> void:
    var connected := _town_connected(town_row, town_col)
    if connected.has(_hex_key(start_row, start_col)):
        return

    var best_path = _find_connect_path(start_row, start_col, connected,
            tile_data, region_rows, region_cols)
    if best_path.is_empty():
        return

    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        _add_town_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col)
        connected[_hex_key(from_hex.row, from_hex.col)] = true
        connected[_hex_key(to_hex.row, to_hex.col)] = true

# The set of the connected hexes of the NETWORK OF THE TOWN (it is created on the first request).
func _town_connected(town_row: int, town_col: int) -> Dictionary:
    var key := _hex_key(town_row, town_col)
    if not town_connected_hexes.has(key):
        town_connected_hexes[key] = {}
    return town_connected_hexes[key]

# Resets all the networks of the roads of the towns (the start of a party and a full recalculation).
func clear_town_roads() -> void:
    town_road_segments.clear()
    town_connected_hexes.clear()
    _invalidate_plan_cache()

# Checks whether a hex is connected by the roads to the centre of THIS town.
func is_town_connected(town_row: int, town_col: int, row: int, col: int) -> bool:
    var connected = town_connected_hexes.get(_hex_key(town_row, town_col), null)
    if connected == null:
        return false
    return connected.has(_hex_key(row, col))

# Adds a segment of a road of a town in the canonical direction (without the duplicates).
# The roads of the towns are always trails: they are built by the town itself from its centre,
# and the level is not chosen for them (see the header of the file).
func _add_town_road_segment(row1: int, col1: int, row2: int, col2: int):
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    town_road_segments[key] = DEFAULT_ROAD_LEVEL

# All the segments of the roads of the towns (for the drawing).
func get_all_town_road_segments() -> Dictionary:
    return town_road_segments.duplicate()

# === The roads which the player builds ===

# Resets the cache of the plans. It is called on ANY change of the networks (see
# _network_version), because the plan depends on what is already connected.
func _invalidate_plan_cache() -> void:
    _network_version += 1
    _plan_cache.clear()
    _route_cache.clear()

# Reports to the manager that on the map what is KNOWN to the player has changed: a scouting
# completed, a chunk was bought, the epoch changed, the whole map is opened in the debug. The plan
# of a road of the player is built by the scouted territory, therefore without this version
# the cache would give an outdated route (for example, "there is no road" right after
# the player scouted a passage to a town).
# It is called from main_map - there, where is_explored / in_influence changes.
func bump_map_knowledge() -> void:
    _knowledge_version += 1
    _plan_cache.clear()

# Is a hex connected to the network of the roads of the CITY (a road is already laid through it -
# either it is the hex of the city, or a route went through it). This is exactly the check
# "there is no road on this hex yet" for the button of the special action.
func is_hex_connected(row: int, col: int) -> bool:
    return connected_hexes.has(_hex_key(row, col))

# Is the city connected to THIS town by roads. The check is computed, and not
# saved: the networks of the city and of the town are connected if at least one hex
# of the network of the town is connected to the network of the city. Exactly this sign opens
# the trade (see town_manager.is_trade_available) and draws the icon over the town.
# The saved flag town["road_linked"] is another thing: it remembers that the player did THIS,
# and by it the connection is restored from the save (see rebuild_player_roads).
func is_town_linked_to_city(town_row: int, town_col: int) -> bool:
    var town_net = town_connected_hexes.get(_hex_key(town_row, town_col), null)
    if town_net == null or town_net.is_empty():
        return false
    for key in town_net.keys():
        if connected_hexes.has(key):
            return true
    return false

# Plans a road from the network of the CITY to the hex (row, col) - WITHOUT the side effects
# (the network does not change: it is a pure calculation for the preview in the control panel).
#
# Two cases by the type of the hex:
#   - an ordinary hex - the target is the hex itself, the route is searched to the nearest hex of the network
#     of the city by the ordinary algorithm (_find_connect_path);
#   - a hex of a TOWN - the target is the town CENTRE (the hex itself). The player chooses
#     the road level, and that level must reach the town, not stop at the nearest road of the
#     influence ring and drop to the town's own trail from there.
#
# hex_allowed (an optional Callable) limits the route by the territory known to the player
# to the player; it is passed by main_map.get_road_plan (is_hex_known). The sign of the
# filter enters the key of the cache: a plan without a filter and a plan with a filter are different
# routes, and they must not be confused.
#
# It returns { ok, reason, path, segments, is_town }. segments is the number of the segments
# of the WHOLE path (path.size() - 1), including the already built ones. It must not be multiplied by the price
# of a segment: there is no need to pay for the already laid segments, and they are filtered
# by main_map._build_road_steps. The price of a road is the sum of the prices of its STEPS
# (main_map.get_road_cost_breakdown), each has its own terrain and distance.
# The result is cached by the versions of the network of the roads and the knowledge about the map: the panel
# asks for the plan on every tick, and the search of the path is a Dijkstra over the map.
func plan_road_to(
    row: int,
    col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable = Callable()
) -> Dictionary:
    var cache_key := "%d:%d:%d|%s" % [
        _network_version, _knowledge_version,
        int(hex_allowed.is_valid()), _hex_key(row, col)]
    if _plan_cache.has(cache_key):
        return _plan_cache[cache_key]
    var plan := _compute_road_plan(
        row, col, tile_data, region_rows, region_cols, hex_allowed)
    _plan_cache[cache_key] = plan
    return plan

func _compute_road_plan(
    row: int,
    col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable
) -> Dictionary:
    if row < 0 or row >= tile_data.size() or col < 0 or col >= tile_data[row].size():
        return _road_plan(false, tr("Hex outside the map"), [], 0, false)
    var tile = tile_data[row][col]
    if tile == null:
        return _road_plan(false, tr("Hex outside the map"), [], 0, false)
    var is_town := bool(tile.get("has_town", false))

    # --- A hex of a TOWN: the road goes all the way to the town itself ---
    if is_town:
        if is_town_linked_to_city(row, col):
            return _road_plan(false, tr("The town is already connected by a road"), [], 0, true)
        # The target is the town CENTRE, and not the nearest road of its influence ring:
        # the level chosen by the player must reach the town itself instead of dropping to
        # the town's own trail at the ring boundary (see the class header of the file).
        # The route goes ONLY over the known territory (see hex_allowed): it is impossible
        # even to approach a town without scouting the road to it.
        var town_target := {_hex_key(row, col): true}
        var town_path = _find_path_between(town_target, connected_hexes,
                tile_data, region_rows, region_cols, hex_allowed)
        if town_path.is_empty():
            return _road_plan(false, _town_road_failure_reason(town_target, tile_data,
                    region_rows, region_cols, hex_allowed), [], 0, true)
        if not _validate_path(town_path):
            printerr("Error: the route of a road to a town contains non-adjacent hexes!")
            return _road_plan(false, tr("Could not find a path to the town"), [], 0, true)
        return _road_plan(true, "", town_path, town_path.size() - 1, true)

    # --- An ordinary hex: a road to it from the nearest road of the city ---
    if is_hex_connected(row, col):
        return _road_plan(false, tr("A road to the hex already exists"), [], 0, false)
    if MapHelpers.is_water_terrain(tile.get("terrain", "plain")):
        return _road_plan(false, tr("Roads cannot be built over water"), [], 0, false)
    var hex_path = _find_connect_path(row, col, connected_hexes,
            tile_data, region_rows, region_cols, hex_allowed)
    if hex_path.is_empty():
        return _road_plan(false, tr("There is no land route from the city to this hex"), [], 0, false)
    return _road_plan(true, "", hex_path, hex_path.size() - 1, false)

# Why it was not possible to get to the town, and what the player should do about it. There are two
# cases, and the advices must be different:
#   - a land path EXISTS, but it goes over the unexplored land -> a scout is needed;
#     "the town is visible, but there is nothing to approach it by";
#   - a land path does NOT exist at all (the town is behind the water) -> the scouts will not help,
#     here another town is needed (the sea trade is not in the game yet).
# The second case is checked by the same search, but without the restriction by the knownness.
# The extra work is one Dijkstra, and only on a failed plan, and the result of the plan
# is cached, so it does not repeat on every tick.
func _town_road_failure_reason(
        targets: Dictionary,
        tile_data: Array,
        region_rows: int,
        region_cols: int,
        hex_allowed: Callable) -> String:
    if not hex_allowed.is_valid():
        return tr("There is no land route from the city to the town")
    var any_path := _find_path_between(targets, connected_hexes,
            tile_data, region_rows, region_cols)
    if any_path.is_empty():
        return tr("There is no land route from the city to the town (the town is across water)")
    return tr("No scouted route from the city to the town — send scouts there")

func _road_plan(ok: bool, reason: String, path: Array, segments: int, is_town: bool) -> Dictionary:
    return {
        "ok": ok,
        "reason": reason,
        "path": path,
        "segments": segments,
        "is_town": is_town
    }

# Builds a road by the plan from plan_road_to: the segments and the connected hexes
# are added into the NETWORK of the CITY, therefore a new road immediately shortens all
# the next routes. segments_to_build is how many new segments are paid for
# (-1 = the whole route): see the call from main_map._on_build_completed.
func build_road_to(
    row: int,
    col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    segments_to_build: int = -1,
    hex_allowed: Callable = Callable(),
    road_level: int = DEFAULT_ROAD_LEVEL
) -> bool:
    var plan := plan_road_to(row, col, tile_data, region_rows, region_cols, hex_allowed)
    if not plan.get("ok", false):
        return false
    var is_town := bool(plan.get("is_town", false))
    var road_path: Array = plan.get("path", [])
    # The route can be longer than the paid part: the unpaid segments
    # are simply not built (the build will not finish until the labour is collected).
    var limit := road_path.size() - 1
    if segments_to_build >= 0:
        limit = mini(limit, segments_to_build)
    if limit <= 0:
        return false

    for i in range(mini(road_path.size() - 1, limit)):
        var from_hex = road_path[i]
        var to_hex = road_path[i + 1]
        _add_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col, road_level)
        connected_hexes[_hex_key(from_hex.row, from_hex.col)] = true
        connected_hexes[_hex_key(to_hex.row, to_hex.col)] = true
        if is_town:
            # Such a road connects the city with a town - it is drawn with
            # the gates of the fog (see town_link_segments), and on the full payment of
            # the route the signal of the opening of the connection is emitted.
            town_link_segments[_get_canonical_road_key(
                from_hex.row, from_hex.col, to_hex.row, to_hex.col)] = true
    _invalidate_plan_cache()

    if is_town and limit >= road_path.size() - 1:
        emit_signal("town_link_established", row, col)
    return true

# The canonical key of a segment of a road is the same format as in road_segments
# ("row1,col1|row2,col2" in the canonical direction). A thin wrapper over
# the internal _get_canonical_road_key: the keys of the segments are needed not only by
# road_manager itself, but also by the owner of a staged project (main_map collects from them
# the "ghost" of the unbuilt segments on the map).
func get_road_segment_key(row1: int, col1: int, row2: int, col2: int) -> String:
    return _get_canonical_road_key(row1, col1, row2, col2)

# Builds ONE segment of a staged road: the segment goes into the NETWORK of the CITY, both
# of its hexes are connected, the cache of the plans is reset. The main difference from
# build_road_to, which lays the whole route by one call, is that here
# exactly one segment is added, because the queue of the steps of the project
# (project_manager) is parsed one by one.
#
# is_town - the route goes to a town: such a segment additionally falls into
# town_link_segments, in order to be drawn with the gates of the fog (see
# get_all_town_link_segments). The event of the opening of the connection is NOT emitted at this point:
# it will come when the LAST segment is finished, and it is emitted by the owner
# of the project (main_map) - here there is no such knowledge yet.
func build_road_step(
    from_row: int,
    from_col: int,
    to_row: int,
    to_col: int,
    is_town: bool = false,
    road_level: int = DEFAULT_ROAD_LEVEL
) -> bool:
    if has_road_between(from_row, from_col, to_row, to_col):
        return false
    _add_road_segment(from_row, from_col, to_row, to_col, road_level)
    connected_hexes[_hex_key(from_row, from_col)] = true
    connected_hexes[_hex_key(to_row, to_col)] = true
    if is_town:
        town_link_segments[_get_canonical_road_key(
                from_row, from_col, to_row, to_col)] = true
    _invalidate_plan_cache()
    return true

# The new, NOT YET BUILT segments of the route of the plan - in the same format of the keys
# as road_segments (see _get_canonical_road_key), therefore the renderer draws them
# by the same code as the real roads, but with its own style. There are no side effects:
# the plan is already computed and cached, a repeated search of the path is not performed. The already
# existing segments are skipped - there is no need to draw them in the preview, the player
# does not pay for them.
func get_plan_new_segments(plan: Dictionary) -> Dictionary:
    var segments: Dictionary = {}
    if not plan.get("ok", false):
        return segments
    var road_path: Array = plan.get("path", [])
    for i in range(maxi(road_path.size() - 1, 0)):
        var from_hex = road_path[i]
        var to_hex = road_path[i + 1]
        if has_road_between(from_hex.row, from_hex.col, to_hex.row, to_hex.col):
            continue
        segments[_get_canonical_road_key(
                from_hex.row, from_hex.col, to_hex.row, to_hex.col)] = true
    return segments

# Restores the roads built by the player through the special action
# "Build a road". As with the roads to the improvements, the save does not contain
# the segments, but the input data: the tile has the flag tile["road_built"], and the
# record of the town has the flag town["road_linked"]; the network is counted from scratch.
#
# It must be called AFTER rebuild_roads_from_existing (the network of the city) and
# rebuild_town_roads (the road networks of the towns). A hex of a town is a target
# like any other: the road to a town reaches its centre (see plan_road_to), therefore
# towns is not needed here - road_manager knows nothing about it.
# hex_allowed is the same Callable "is the territory known" as in the ordinary
# planning (it is passed by main_map): a restored road must go
# over the scouted land exactly as it was built.
func rebuild_player_roads(
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable = Callable()
) -> void:
    for row in range(region_rows):
        for col in range(region_cols):
            var tile = tile_data[row][col]
            if tile == null or not bool(tile.get("road_built", false)):
                continue
            build_road_to(row, col, tile_data, region_rows, region_cols, -1,
                    hex_allowed, _tile_road_level(tile))

# The level of a road of a hex is the input data for the restoration from the save (the segments
func _tile_road_level(tile: Dictionary) -> int:
    return int(tile.get("road_level", DEFAULT_ROAD_LEVEL))

# === THE ROUTE TO THE CITY AND THE SPEED ===

# Searches a route from the hex (row, col) to the hex of the city BY THE ALREADY BUILT roads
# and returns it together with the speed.
#
# The difference from plan_road_to is fundamental: there a path is searched over the TERRAIN (where
# a new road can be laid), here - over the network (how to actually get there). Therefore
# the search is different (a traversal of the network, and not a Dijkstra over the map) and the filter of the knownness is not
# needed: the road already stands there, where it is visible.
#
# town_row/town_col - if the starting point belongs to a town, the route goes over
# the network of THIS town, then over the segment of the connection (town_link_segments) and further over
# the network of the city.
#
# ABOUT avg_speed: it is the arithmetic mean of max_speed of the segments - "how
# fast on average the cargo goes over the whole route". Exactly the mean, and NOT the minimum
# over the route: a route of nine cart roads and one trail gives
# (9*30 + 1*10)/10 = 28 units/sec, and not 10. One bad pothole on a highway must not
# suddenly reduce the speed of the whole highway.
#
# A separate value of the "bottleneck" (min_speed) is deliberately absent here: it was
# introduced without a request and was removed at the request of the author.
func find_route_to_city(
    row: int,
    col: int,
    town_row: int = -1,
    town_col: int = -1
) -> Dictionary:
    var cache_key := "%d|%d,%d|%d,%d" % [_network_version, row, col, town_row, town_col]
    if _route_cache.has(cache_key):
        return _route_cache[cache_key]
    var route := _compute_route_to_city(row, col, town_row, town_col)
    _route_cache[cache_key] = route
    return route

func _compute_route_to_city(
    row: int,
    col: int,
    town_row: int,
    town_col: int
) -> Dictionary:
    var start_key := _hex_key(row, col)
    var city_key := _hex_key(city_row, city_col)
    var no_route := tr("No road connects this hex to the city")
    if start_key == city_key:
        # The city itself: the route is empty. The speed is 0, and not an "infinity":
        # there are no segments, it is impossible to divide by their number, and to show
        # the player an infinite speed of the city is dishonest - the delivery starts
        # on the approach to the city, and not on its hex.
        return _route(false, tr("This is the city itself"), [], [], [], 0, 0.0)

    # The network over which we go: the segments of the city + (for a town) the segments of its
    # own network. The networks of the towns are not merged with each other, therefore
    # the segments of a foreign town do not fall into the route (see the header of the file).
    var segments: Dictionary = {}
    for key in road_segments.keys():
        segments[key] = true
    if town_row >= 0 and town_col >= 0:
        var town_net = town_connected_hexes.get(_hex_key(town_row, town_col), null)
        if town_net != null:
            for key in town_road_segments.keys():
                segments[key] = true

    # The adjacency list: "row,col" -> [{"key": String, "to": "row,col"}].
    var adjacency: Dictionary = {}
    for key in segments.keys():
        var ends := _parse_segment_key(key)
        if ends.is_empty():
            continue
        var a_key := _hex_key(int(ends[0]), int(ends[1]))
        var b_key := _hex_key(int(ends[2]), int(ends[3]))
        if not adjacency.has(a_key):
            adjacency[a_key] = []
        if not adjacency.has(b_key):
            adjacency[b_key] = []
        adjacency[a_key].append({"key": key, "to": b_key})
        adjacency[b_key].append({"key": key, "to": a_key})

    if not adjacency.has(start_key):
        return _route(false, no_route, [], [], [], 0, 0.0)

    # A traversal in width: a route with the smallest number of the segments. All the segments cost
    # the same, therefore it is not needed to weigh the distances - and there are none of them.
    var parent: Dictionary = {start_key: null}
    var visited: Dictionary = {start_key: true}
    var queue: Array = [start_key]
    var found := false
    while not queue.is_empty():
        var current: String = queue.pop_front()
        if current == city_key:
            found = true
            break
        for edge in adjacency.get(current, []):
            var next_key: String = str(edge["to"])
            if visited.has(next_key):
                continue
            visited[next_key] = true
            parent[next_key] = {"from": current, "key": str(edge["key"])}
            queue.append(next_key)

    if not found:
        return _route(false, no_route, [], [], [], 0, 0.0)

    # We restore the route FROM THE IMPROVEMENT TO THE CITY. The traversal went in the reverse
    # direction (from a hex to the city), therefore the restored list is reversed
    # by push_front - thus path, segments and levels go in one order.
    #
    # The invariant of the order: segments[i] connects path[i] and path[i + 1]. Both the
    # highlighting of the route on the map and the queue of the improvement depend on it (the steps go
    # in the reverse order - from the city to the target), therefore an "almost the reverse" is
    # here inadmissible.
    var path: Array = []
    var segment_keys: Array = []
    var levels: Array = []
    var speed_sum := 0
    var current_key: String = city_key
    while current_key != start_key:
        var step = parent.get(current_key, null)
        if step == null:
            return _route(false, no_route, [], [], [], 0, 0.0)
        var hex_parts := str(current_key).split(",")
        path.push_front({"row": int(hex_parts[0]), "col": int(hex_parts[1])})
        var seg_key: String = str(step["key"])
        segment_keys.push_front(seg_key)
        var level := _segment_level_by_key(seg_key)
        levels.push_front(level)
        speed_sum += GameData.get_road_max_speed(level)
        current_key = str(step["from"])
    path.push_front({"row": row, "col": col})

    var length := segment_keys.size()
    var avg_speed := 0.0 if length == 0 else float(speed_sum) / float(length)
    return _route(true, "", path, segment_keys, levels, length, avg_speed)

func _route(ok: bool, reason: String, path: Array, segments: Array, levels: Array,
        length: int, avg_speed: float) -> Dictionary:
    return {
        "ok": ok,
        "reason": reason,
        "path": path,
        "segments": segments,
        "levels": levels,
        "length": length,
        "avg_speed": avg_speed
    }

# The level of a segment by its string key. There is no segment in the network of the city - we do
# not return 0: the segment may belong to the network of a town (town_road_segments), and
# for a route from a town such a segment is an ordinary trail.
func _segment_level_by_key(key: String) -> int:
    if road_segments.has(key):
        return int(road_segments[key])
    return DEFAULT_ROAD_LEVEL

# Parses the key of a segment "row1,col1|row2,col2" into [row1, col1, row2, col2].
# An empty array - the key is broken; the caller skips it, because
# such a segment cannot be drawn or priced anyway.
func _parse_segment_key(key: String) -> Array:
    var ends := key.split("|")
    if ends.size() != 2:
        return []
    var a := ends[0].split(",")
    var b := ends[1].split(",")
    if a.size() != 2 or b.size() != 2:
        return []
    if not (a[0].is_valid_int() and a[1].is_valid_int()
            and b[0].is_valid_int() and b[1].is_valid_int()):
        return []
    return [int(a[0]), int(a[1]), int(b[0]), int(b[1])]

# The segments of the roads connecting the city with the towns (for the drawing with the gates
# of the fog - see town_link_segments).
func get_all_town_link_segments() -> Dictionary:
    return town_link_segments.duplicate()

# The key of a hex "row,col" is a single format of the keys in all the dictionaries of the manager.
func _hex_key(row: int, col: int) -> String:
    return str(row) + "," + str(col)

# Adds a segment of a road in the canonical direction (without the duplicates).
# The level is passed explicitly: a segment remembers its level (see the header of the file).
func _add_road_segment(row1: int, col1: int, row2: int, col2: int,
        road_level: int = DEFAULT_ROAD_LEVEL):
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    road_segments[key] = road_level

# The level of a road on a hex = the MAXIMUM over the adjacent segments of ALL the networks:
# the city of the player and the towns. 0 - not a single segment adjoins the hex, that is
# there is no road.
#
# This is a DERIVED value, and not a stored one. The level of a SEGMENT is stored
# (road_segments / town_road_segments: "row,col|row,col" -> level), and it remains the single
# source of truth: a hex simply does not have a level of its own.
#
# The roads of the TOWNS are counted on a par with the roads of the city: they are drawn on the map
# (map_renderer._draw_all_roads), and the row must describe what the player sees on the hex.
# Without them a hex with a drawn town road, but without a player road, gives an empty row - and the
# criterion ("whose road is this") is invisible to the player, who sees a road and reads nothing
# about it. The level of the roads of the towns is always a trail (see _add_town_road_segment) and
# the player cannot improve them, but the row answers the question "what is drawn on this hex",
# and not "what can be done here".
#
# That is why the rule reads as "a hex has one road", and not as
# "all the segments of a hex have one level". The difference is significant: if we
# stored the level of a hex and required all the adjoining segments to be
# of its level, then the upgrade of one segment would require raising all
# the others adjoining the same hex, and those - all the ones adjoining them,
# and so on: the level would spread over the whole connected network of the roads. The rule of the
# maximum requires nothing of the sort: an orange trail through an intersection
# remains a trail, and the best road reaching the hex is shown.
func get_hex_road_level(row: int, col: int) -> int:
    var best := 0
    for neighbor in _get_neighbors(row, col, 999, 999):
        # 0 - there is no segment: it cannot be counted as a road.
        best = maxi(best, _any_segment_level(row, col,
                int(neighbor.row), int(neighbor.col)))
    return best

# The level of a segment in ANY network: the city of the player or a town. 0 - the segment
# does not exist.
#
# It differs from get_segment_level, which sees ONLY the network of the city and answers 0 for
# a town segment. The route search needs exactly that (see _segment_level_by_key): the roads of
# the towns do not belong to the player. The display of the level on a hex needs both networks:
# the roads of the towns are drawn on the map.
func _any_segment_level(row1: int, col1: int, row2: int, col2: int) -> int:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    if road_segments.has(key):
        return int(road_segments[key])
    if town_road_segments.has(key):
        return int(town_road_segments[key])
    return 0

# The level of a segment of a road. There is no segment - 0 (and not a trail!): the caller must
# distinguish "there is no segment" from "the segment is a trail", otherwise a non-existent segment
# would silently be counted as a road with a throughput capacity.
func get_segment_level(row1: int, col1: int, row2: int, col2: int) -> int:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    if not road_segments.has(key):
        return 0
    return int(road_segments[key])

# Raises the level of an already built segment (the special action "Improve the road").
# It returns false if there is no segment or it is already not lower than the level: there is
# nothing to improve, and an empty step of the project would be a step without work.
func upgrade_road_segment(row1: int, col1: int, row2: int, col2: int,
        road_level: int) -> bool:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    if not road_segments.has(key):
        return false
    if int(road_segments[key]) >= road_level:
        return false
    road_segments[key] = road_level
    # The network has changed by the composition of the levels: the routes and their average speed
    # are now different, we reset the cache of the routes.
    _invalidate_plan_cache()
    return true

# Gets the canonical key for a pair of hexes
func _get_canonical_road_key(row1: int, col1: int, row2: int, col2: int) -> String:
    var sum1 = row1 + col1
    var sum2 = row2 + col2
    if sum1 < sum2 or (sum1 == sum2 and col1 < col2):
        return "%d,%d|%d,%d" % [row1, col1, row2, col2]
    return "%d,%d|%d,%d" % [row2, col2, row1, col1]

# Validates that all the adjacent elements of the path are neighbours
func _validate_path(path: Array) -> bool:
    for i in range(path.size() - 1):
        var curr = path[i]
        var next = path[i + 1]
        if not _are_neighbors(curr.row, curr.col, next.row, next.col):
            return false
    return true

# A Dijkstra with a priority queue for the search of the shortest path
# from ANY hex of `sources` to the nearest hex of `targets`.
# Both sets are the dictionaries "row,col" -> true, therefore one and the same search
# serves both the ordinary road (sources = {the start}, targets = connected_hexes
# of the city), and the road to a town (sources = {the town centre},
# targets = connected_hexes) - see plan_road_to.
#
# hex_allowed (optional) is a Callable(row, col) -> bool: which hexes at all
# can be used in the route. It limits ONLY the roads which the
# player builds: they go over the territory known to the player (main_map.is_hex_known -
# in the Influence Ring or scouted), because it is possible to interact with a town
# only on a scouted hex, and the road to it must go by the same
# by the same scouted path. The automatic networks (the roads to the improvements of the city and
# of the towns) do not pass the filter and behave as before: the improvements stand in the
# Influence Ring, and a town scouts the surroundings by itself.
#
# The starting hex itself is not counted as a target by itself (as before, before the generalization):
# if the source already lies in targets, a road is not built "into itself".
func _find_path_between(
    sources: Dictionary,
    targets: Dictionary,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable = Callable()
) -> Array:
    var visited = {}
    var parent = {}
    var cost_so_far = {}

    # The initialization: all the sources start with a zero cost. The sources
    # which are forbidden to pass (the fog of war) are dropped: otherwise the route
    # would start from a hex which the player does not know, and the very first segment would go
    # into the unexplored land.
    for source_key in sources.keys():
        if hex_allowed.is_valid() \
                and not bool(hex_allowed.call(
                        int(source_key.split(",")[0]), int(source_key.split(",")[1]))):
            continue
        cost_so_far[source_key] = 0
        parent[source_key] = null
    if cost_so_far.is_empty():
        return []

    var current_key = _cheapest_open_node(cost_so_far, visited)

    while true:
        # We have reached the target - we restore the path from the source to it
        if targets.has(current_key) and not sources.has(current_key):
            return _reconstruct_path(current_key, parent)

        visited[current_key] = true

        var cur_row = int(current_key.split(",")[0])
        var cur_col = int(current_key.split(",")[1])

        var neighbors = _get_neighbors(cur_row, cur_col, region_rows, region_cols)
        for n in neighbors:
            var n_key = _hex_key(n.row, n.col)

            if visited.has(n_key):
                continue

            var tile = tile_data[n.row][n.col]
            if tile == null or MapHelpers.is_water_terrain(tile.get("terrain", "plain")):
                continue
            # The territory over which a road cannot be built (the fog of war):
            # it is checked BEFORE the calculation of the cost, so that such hexes do not get
            # into the search at all.
            if hex_allowed.is_valid() and not bool(hex_allowed.call(n.row, n.col)):
                continue
            var terrain_id = tile.get("terrain", "plain")
            var move_cost = 1
            if GameData.terrains.has(terrain_id):
                move_cost = GameData.terrains[terrain_id].get("move_cost", 1)

            var new_cost = cost_so_far[current_key] + move_cost
            if not cost_so_far.has(n_key) or new_cost < cost_so_far[n_key]:
                cost_so_far[n_key] = new_cost
                parent[n_key] = current_key

        current_key = _cheapest_open_node(cost_so_far, visited)
        if current_key == null:
            # The path is not found
            return []

    # It should never reach this point
    return []

# Returns the key of a not yet visited hex with the minimal accumulated
# cost (or null, if there are no more of them).
func _cheapest_open_node(cost_so_far: Dictionary, visited: Dictionary):
    var min_cost = INF
    var next_key = null
    for key in cost_so_far.keys():
        if not visited.has(key) and cost_so_far[key] < min_cost:
            min_cost = cost_so_far[key]
            next_key = key
    return next_key

# Restores the path from the end to the beginning
func _reconstruct_path(end_key: String, parent: Dictionary) -> Array:
    var path = []
    var current_key = end_key
    
    while current_key != null:
        var parts = current_key.split(",")
        path.push_front({"row": int(parts[0]), "col": int(parts[1])})
        current_key = parent.get(current_key, null)
    
    return path

# Checks whether two hexes are neighbours
func _are_neighbors(row1: int, col1: int, row2: int, col2: int) -> bool:
    var neighbors = _get_neighbors(row1, col1, 999, 999)
    for n in neighbors:
        if n.row == row2 and n.col == col2:
            return true
    return false

# Getting the neighbours for an odd-r hexagonal grid
func _get_neighbors(row: int, col: int, max_rows: int, max_cols: int) -> Array:
    var neighbors = []
    var directions = []
    
    # For the even rows (row % 2 == 0)
    if row % 2 == 0:
        directions = [
            {"r": 0, "c": - 1}, # W
            {"r": 0, "c": 1}, # E
            {"r": - 1, "c": - 1}, # NW
            {"r": - 1, "c": 0}, # NE
            {"r": 1, "c": - 1}, # SW
            {"r": 1, "c": 0} # SE
        ]
    else:
        # For the odd rows (row % 2 == 1)
        directions = [
            {"r": 0, "c": - 1}, # W
            {"r": 0, "c": 1}, # E
            {"r": - 1, "c": 0}, # NW
            {"r": - 1, "c": 1}, # NE
            {"r": 1, "c": 0}, # SW
            {"r": 1, "c": 1} # SE
        ]

    for d in directions:
        var nr = row + d.r
        var nc = col + d.c
        if nr >= 0 and nr < max_rows and nc >= 0 and nc < max_cols:
            neighbors.append({"row": nr, "col": nc})
    return neighbors

# Checks whether there is a road between two hexes
func has_road_between(row1: int, col1: int, row2: int, col2: int) -> bool:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    return road_segments.has(key)

# Gets all the segments of the roads (for the debugging)
func get_all_road_segments() -> Dictionary:
    return road_segments.duplicate()
