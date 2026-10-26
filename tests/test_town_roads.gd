# Headless test for town roads (scripts/road_manager.gd, scripts/main_map.gd).
#   godot --headless --path . --script res://tests/test_town_roads.gd
#
# Checks (on synthetic maps — deterministic, without a random map):
#   1. Every town has a road laid to EACH of its improvements: the hex of
#      the improvement ends up in its network (is_town_connected), and a
#      chain of segments really runs from it to the town center (BFS over
#      town_road_segments — a check of the network's shape, not just a flag).
#   2. Town networks are isolated: the player's city network contains only its
#      hex and not a single segment (all improvements on the map are town ones),
#      no town segment ends up in the city's road set, and the town centers
#      are the roots of their own networks. The logical isolation rests on the
#      fact that the road search stops only at hexes of its OWN town.
#   3. Decorative (town) improvements do NOT end up in the player's city
#      network when rebuilding from a save: rebuild_roads_from_existing is
#      called BEFORE the towns are loaded, and the improvements sit together in
#      tile_data. Without this check the city's roads would grow towards the
#      fields and forest plots of ALL towns on the map.
#   4. A water improvement (fishing boats on a lake) gets no road — just like
#      the player's city.
#   5. On the live MainMap scene (new game) the RULE is checked, not the
#      outcome: an improvement is connected by a road if and only if there is a
#      land path to the town center; plus visibility gates — era 0 not visible,
#      from the Antiquity era visible, a segment with an end in the fog is
#      hidden, scouting reveals it (the same gates as for ring fill).
#   6. The road level on a hex (get_hex_road_level) also accounts for the town
#      network: on a hex with a town road (and without a player road) it is 1,
#      not 0 — the "Road: …" line in the tooltip describes what is drawn on
#      the map.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks from the
# outside like eternal silence. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _tm = null
var _rm = null
var _cdata = null
var _hex_utils = null
var _map_helpers = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken via the scene tree: in --script mode the names
    # GameData/CityData are unavailable at the compile stage of this file.
    # new_game() also loads all the data (improvements, resources, city_names).
    get_root().get_node("SaveManager").new_game()
    _cdata = get_root().get_node("CityData")
    _hex_utils = load("res://scripts/HexUtils.gd")
    _map_helpers = load("res://scripts/map_helpers.gd")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)
    _rm = load("res://scripts/road_manager.gd").new()
    get_root().add_child(_rm)

    if WATCHDOG.wants_case("every_town_improvement_has_road"):
        _test_every_town_improvement_has_road(state)
    if WATCHDOG.wants_case("networks_are_separate"):
        _test_networks_are_separate(state)
    if WATCHDOG.wants_case("decorative_improvements_not_in_player_network"):
        _test_decorative_improvements_not_in_player_network(state)
    if WATCHDOG.wants_case("water_improvement_has_no_road"):
        _test_water_improvement_has_no_road(state)
    if WATCHDOG.wants_case("town_road_level_on_hex"):
        _test_town_road_level_on_hex(state)

    # The live scene is checked last and freed separately: MainMap
    # creates its own TownManager/RoadManager, and there is no reason to
    # keep second instances around.
    get_root().remove_child(_tm)
    _tm.free()
    get_root().remove_child(_rm)
    _rm.free()
    _tm = null
    _rm = null

    if WATCHDOG.wants_case("live_scene"):
        await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TOWN ROADS TEST FAILED")
        quit(1)
    else:
        print("TOWN ROADS TEST OK")
        quit(0)


# -------------------------------------------------------
# Map and placement (deterministic synthetic)
# -------------------------------------------------------

# Empty map: all hexes are plain with no resources, rivers, improvements or towns.
func _make_map(rows: int, cols: int) -> Array:
    var tile_data := []
    for r in range(rows):
        var row := []
        for c in range(cols):
            row.append({
                "terrain": "plain",
                "cover": "none",
                "resource": null,
                "quality": "",
                "crop_bred": null,
                "improvement": null,
                "decorative": false,
                "terrain_icon": "",
                "fill_time": 0.0,
                "production_fractional_remainder": 0.0,
                "feed_fractional_remainder": 0.0,
                "has_town": false,
                "river_edges": [],
                "in_influence": false,
                "is_explored": false,
                "in_town_influence": false,
            })
        tile_data.append(row)
    return tile_data

# Fills the map with a "carpet" of resources, except for the hexes in skip:
# then ALL hexes satisfy the top priority "2+ different resources in the
# surroundings", and the towns land on the remaining free hexes. Exactly the
# same trick as in test_town_priorities.
func _fill_resource_carpet(tile_data: Array, skip: Array) -> void:
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            if skip.has(Vector2i(r, c)):
                continue
            tile_data[r][c]["resource"] = "sheep" if (r + c) % 2 == 0 else "cows"

# Places num_towns towns on a fresh map and returns it.
func _make_town_map(rows: int, cols: int, city_row: int, city_col: int,
        num_towns: int) -> Array:
    var tile_data := _make_map(rows, cols)
    # Hexes free of resources — every other one along both axes: each has
    # 2+ DIFFERENT resources in the surroundings, and the distances suffice
    # for spreading the towns out.
    var free_hexes := []
    for r in range(rows):
        for c in range(cols):
            if r % 2 == 0 and c % 2 == 0:
                free_hexes.append(Vector2i(r, c))
    _fill_resource_carpet(tile_data, free_hexes)

    var saved_town_count: int = _cdata.world_town_count
    _cdata.world_town_count = num_towns
    # The forbidden zone around the city is 3 hexes in each direction, not the
    # city hex itself. In the real game the towns are excluded from the starting
    # area (Ring + Region), so a town's influence ring (radius 3) never
    # covers the city hex. With only the city hex this was not achieved:
    # a town 4 hexes from the city was placed, and its ring reached the city
    # hex — then the checks about the city network imitated a situation that
    # does not occur in the game.
    _tm.generate_towns(tile_data, rows, cols, city_row, city_col,
            city_row - 3, city_row + 3, city_col - 3, city_col + 3,
            0, rows - 1, 0, cols - 1)                # "era-2" = the whole map
    _cdata.world_town_count = saved_town_count
    return tile_data

# Places improvements in the town rings — just as the game itself does
# (town_manager._place_decorative_town_improvements is called at the very end
# of generate_towns, and separately in main_map when loading a save).
func _place_town_improvements(tile_data: Array, rows: int, cols: int) -> void:
    _tm._place_decorative_town_improvements(tile_data, rows, cols)

# Ring hexes of a town that have an improvement on them.
func _town_improvement_hexes(town: Dictionary, tile_data: Array) -> Array:
    var result: Array = []
    for h in town.get("influence_hexes", []):
        var row := int(h.get("row", -1))
        var col := int(h.get("col", -1))
        if row < 0 or col < 0 or row >= tile_data.size() or col >= tile_data[row].size():
            continue
        if tile_data[row][col] == null:
            continue
        if tile_data[row][col].get("improvement", null) == null:
            continue
        result.append({"row": row, "col": col})
    return result

# -------------------------------------------------------
# 1. A road is laid from the town itself to each of its improvements
# -------------------------------------------------------
func _test_every_town_improvement_has_road(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    check(_tm.towns.size() == 5,
            "expected 5 towns, placed %d" % _tm.towns.size(), state)
    _place_town_improvements(tile_data, rows, cols)

    var improvements_total := 0
    for town in _tm.towns:
        improvements_total += _town_improvement_hexes(town, tile_data).size()
    check(improvements_total > 0,
            "the map must have at least one town improvement (otherwise there is nothing to check)",
            state)

    # The player's city network (the city hex) + the town networks.
    _rm.initialize(city_row, city_col)
    _rm.rebuild_town_roads(_tm.towns, tile_data, rows, cols)

    var town_segments: Dictionary = _rm.get_all_town_road_segments()
    for town in _tm.towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        for imp in _town_improvement_hexes(town, tile_data):
            check(_rm.is_town_connected(town_row, town_col, imp.row, imp.col),
                    "improvement (%d,%d) of town (%d,%d) must be connected to it by a road"
                            % [imp.row, imp.col, town_row, town_col], state)
            check(_has_segment_chain(town_segments, imp.row, imp.col, town_row, town_col),
                    "no chain of segments runs from improvement (%d,%d) to town (%d,%d)"
                            % [imp.row, imp.col, town_row, town_col], state)
            # A road is not built over water: neither end of a segment at a
            # water hex may be water.
            for seg in _segments_touching(town_segments, imp.row, imp.col):
                check(not _is_water(tile_data[seg[0]][seg[1]])
                        and not _is_water(tile_data[seg[2]][seg[3]]),
                        "a town road segment runs over water: (%d,%d)-(%d,%d)"
                                % [seg[0], seg[1], seg[2], seg[3]], state)

# -------------------------------------------------------
# 2. Town networks are isolated from the city network and from each other
# -------------------------------------------------------
func _test_networks_are_separate(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    _place_town_improvements(tile_data, rows, cols)
    _rm.initialize(city_row, city_col)
    _rm.rebuild_town_roads(_tm.towns, tile_data, rows, cols)

    # The player's city network: only the city hex is connected, there are no
    # segments — all improvements on this map belong to the towns.
    check(_rm.connected_hexes.size() == 1
            and _rm.connected_hexes.has("%d,%d" % [city_row, city_col]),
            "the player's city network must contain only its hex, but the hex count reached: %d"
                    % _rm.connected_hexes.size(), state)
    check(_rm.get_all_road_segments().is_empty(),
            "the player's city roads must not be built to town improvements", state)

    # Town segments live in their OWN set: none of them ends up in the
    # player's city segments. Note: geometrically a town road MAY
    # pass near the city (the road is physical, the path is searched across the whole map,
    # as for the player's city), but logically it is not joined to the city network:
    # the city's connected_hexes stayed at a single hex, and the town's road search
    # stops only at hexes of its OWN town. That is why we check the
    # separation of the sets, not "does not touch the city hex".
    var town_segments: Dictionary = _rm.get_all_town_road_segments()
    check(not town_segments.is_empty(),
            "a road network must be built on a map with town improvements", state)
    for seg in town_segments.keys():
        check(not _rm.get_all_road_segments().has(seg),
                "a town road segment must not end up in the city's road set: %s" % seg,
                state)

    # Every town has its own network root and its own improvements, to which
    # a road is built FROM ITS OWN center.
    #
    # What is deliberately absent here: a check that "an improvement of a
    # foreign town must not end up in a neighbor's network". The road is physical: the path is searched across the whole
    # map, and one town's route may well PASS through a hex with a neighbor's
    # field (a hex on the route, like a hex with a building on the player's city route,
    # is simply connected by a road). Forbidding that is impossible: the ring may be
    # cut off by a neighboring town, and then the only detour is past its
    # hexes. The logical isolation is guaranteed and is checked above: the search
    # stops only at hexes of its OWN town, and a foreign town
    # connects to its own network only from its own center.
    for town in _tm.towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        check(_rm.is_town_connected(town_row, town_col, town_row, town_col),
                "the town center (%d,%d) must be the root of its road network"
                        % [town_row, town_col], state)

# -------------------------------------------------------
# 3. Decorative improvements do not end up in the player's city network
#    (regression: the rebuild from a save runs BEFORE the towns are loaded)
# -------------------------------------------------------
func _test_decorative_improvements_not_in_player_network(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    _place_town_improvements(tile_data, rows, cols)

    # A PLAYER improvement near the city: it must get into the city network —
    # otherwise the "town ones do not end up" check would pass on an empty network. The hex
    # is taken where there are no improvements yet and which does not belong to a
    # town's ring: otherwise there would be a match with a town improvement, and the check
    # "town ones do not end up in the city network" would fail on it itself.
    var player_hex := _free_hex_near_city(city_row, city_col, rows, cols, tile_data)
    check(not player_hex.is_empty(),
            "a free hex for a player improvement must be found near the city", state)
    if player_hex.is_empty():
        return
    tile_data[player_hex.row][player_hex.col]["improvement"] = "farm"
    tile_data[player_hex.row][player_hex.col]["decorative"] = false

    # Exactly what main_map does when loading a save: the towns are not loaded
    # yet at that moment, all improvements sit together in tile_data.
    _rm.initialize(city_row, city_col)
    _rm.rebuild_roads_from_existing(tile_data, rows, cols)

    check(_rm.connected_hexes.has("%d,%d" % [int(player_hex.row), int(player_hex.col)]),
            "the player's improvement must be connected to the city network", state)
    for town in _tm.towns:
        for imp in _town_improvement_hexes(town, tile_data):
            check(not _rm.connected_hexes.has("%d,%d" % [imp.row, imp.col]),
                    "town improvement (%d,%d) must not end up in the player's city network"
                            % [imp.row, imp.col], state)
            check(not _has_segment_touching(_rm.get_all_road_segments(), imp.row, imp.col),
                    "the player's city roads must not reach the town improvement (%d,%d)"
                            % [imp.row, imp.col], state)

# -------------------------------------------------------
# 4. A water improvement gets no road (just like the player's city)
# -------------------------------------------------------
func _test_water_improvement_has_no_road(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    _place_town_improvements(tile_data, rows, cols)

    # A lake with fishing boats and a land improvement in the ring of the first
    # town: the first must not get a road, the second (control) must.
    var town: Dictionary = _tm.towns[0]
    var town_row := int(town.get("row", -1))
    var town_col := int(town.get("col", -1))
    var water_hex = _free_ring_hex(town, tile_data, 1)
    var land_hex = _free_ring_hex(town, tile_data, 1,
            ["%d,%d" % [int(water_hex.row), int(water_hex.col)]] if water_hex != null else [])
    check(water_hex != null and land_hex != null,
            "free hexes for water and for land must be found in the town ring", state)
    if water_hex == null or land_hex == null:
        return
    tile_data[water_hex.row][water_hex.col]["terrain"] = "lake"
    tile_data[water_hex.row][water_hex.col]["improvement"] = "fishing_boats"
    tile_data[water_hex.row][water_hex.col]["decorative"] = true
    tile_data[land_hex.row][land_hex.col]["improvement"] = "farm"
    tile_data[land_hex.row][land_hex.col]["decorative"] = true

    _rm.initialize(city_row, city_col)
    _rm.rebuild_town_roads(_tm.towns, tile_data, rows, cols)

    check(not _rm.is_town_connected(town_row, town_col, water_hex.row, water_hex.col),
            "fishing boats on a lake must not get a road (water)", state)
    check(_rm.is_town_connected(town_row, town_col, land_hex.row, land_hex.col),
            "a land improvement in the town ring must get a road (control)",
            state)

# -------------------------------------------------------
# 5. Live MainMap scene: networks are built, visible from the Antiquity era
#    and do not enter the fog of war
# -------------------------------------------------------
func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var r = main_map.map_renderer
    var towns: Array = main_map.towns

    # The rule, not the outcome: a road exists if and only if there is a LAND
    # path from the improvement hex to the town center. On the live (random) map
    # improvements stand both on water hexes of the ring (fish lakes) and on hexes
    # cut off from the town by water — such ones get no road, and that is correct
    # (water is impassable, exactly as for the player's city). Checking "everyone has
    # a road" is not possible here: half of such hexes are water.
    var improvements_total := 0
    var improvements_with_road := 0
    for town in towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        for imp in _town_improvement_hexes(town, main_map.tile_data):
            improvements_total += 1
            var tile = main_map.tile_data[imp.row][imp.col]
            var expected: bool = not _is_water(tile) and _land_path_exists(
                    main_map.tile_data, main_map.map_rows, main_map.map_cols,
                    imp.row, imp.col, town_row, town_col)
            var actual: bool = rm.is_town_connected(town_row, town_col, imp.row, imp.col)
            if actual:
                improvements_with_road += 1
            check(actual == expected,
                    "improvement (%d,%d) of town (%d,%d): road %s, but expected %s (water: %s)"
                            % [imp.row, imp.col, town_row, town_col,
                                "yes" if actual else "no",
                                "yes" if expected else "no",
                                "yes" if _is_water(tile) else "no"], state)
    check(improvements_total > 0,
            "on the live map the towns must have improvements", state)
    check(improvements_with_road > 0,
            "on the live map at least some of the town improvements must get a road",
            state)

    # --- Era gate: in the 1st era town roads are not drawn ---
    check(main_map.current_era < 1,
            "the test starts in the 1st era, but era=%d" % main_map.current_era, state)
    check(not r.are_town_roads_visible(),
            "in the 1st era town roads must not be visible", state)
    main_map.advance_to_next_era()
    await process_frame
    check(r.are_town_roads_visible(),
            "from the Antiquity era town roads must be visible", state)

    # --- Fog gate: the RULE is checked on all segments at once, not
    # "at least one foggy one will be found, at least one visible one will be found": on a random
    # map either of the two may not occur (the towns stand outside the Region), and
    # such a check would be flaky. ---
    var checked_segments := 0
    for seg in rm.get_all_town_road_segments().keys():
        var s := _parse_segment(seg)
        var expected: bool = not main_map.is_hex_in_fog(s[0], s[1]) \
                and not main_map.is_hex_in_fog(s[2], s[3])
        check(r.is_town_road_segment_visible(s[0], s[1], s[2], s[3]) == expected,
                "the visibility of a town road segment did not match the fog rule: %s" % seg,
                state)
        checked_segments += 1
    check(checked_segments > 0,
            "the live map must have town road segments", state)

    # Scouting reveals the road just as it reveals the ring fill: an explored hex
    # stops being fog, and a segment with it becomes visible; a hex that has returned
    # to fog hides the road again.
    var fog_pair: Array = _fog_segment(main_map, rm)
    if not fog_pair.is_empty():
        var p := _parse_segment(fog_pair[0])
        check(not r.is_town_road_segment_visible(p[0], p[1], p[2], p[3]),
                "a town road segment with an end in the fog of war must not be drawn: %s"
                        % fog_pair[0], state)
        var t1 = main_map.tile_data[p[0]][p[1]]
        var t2 = main_map.tile_data[p[2]][p[3]]
        t1["is_explored"] = true
        t2["is_explored"] = true
        check(r.is_town_road_segment_visible(p[0], p[1], p[2], p[3]),
                "after scouting a town road segment must become visible: %s"
                        % fog_pair[0], state)
        t1["is_explored"] = false
        t2["is_explored"] = false
        check(not r.is_town_road_segment_visible(p[0], p[1], p[2], p[3]),
                "a town road segment that has returned to fog is hidden again: %s"
                        % fog_pair[0], state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

# -------------------------------------------------------
# 6. The road level on a hex also accounts for the town networks
# -------------------------------------------------------
#
# Town roads are drawn on the map (map_renderer._draw_all_roads), so the
# "Road: …" line in the extended tooltip and in the left column of the panel must
# describe them: otherwise a road is visible on the hex while the tooltip stays silent about it. Previously
# get_hex_road_level looked only into the PLAYER's city network, and on a hex with a town
# road (and without a player road) the line silently disappeared — even though the
# route itself (find_route_to_city) already counted the town sections as a trail.
func _test_town_road_level_on_hex(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    _place_town_improvements(tile_data, rows, cols)
    _rm.initialize(city_row, city_col)
    _rm.rebuild_town_roads(_tm.towns, tile_data, rows, cols)

    var town_segments: Dictionary = _rm.get_all_town_road_segments()
    check(not town_segments.is_empty(),
            "a road network must exist on a map with town improvements", state)
    if town_segments.is_empty():
        return

    var city_segments: Dictionary = _rm.get_all_road_segments()
    var checked_hexes := 0
    for seg in town_segments.keys():
        var s := _parse_segment(seg)
        for end in [[s[0], s[1]], [s[2], s[3]]]:
            var row := int(end[0])
            var col := int(end[1])
            # Skip the player's city hex: it has its own network.
            if row == city_row and col == city_col:
                continue
            # The networks are isolated (see _test_networks_are_separate), so these
            # hexes have no CITY road — the level comes only from the town.
            # Without this check the test would prove nothing: it would also pass on
            # a hex with a player road.
            check(_segments_touching(city_segments, row, col).is_empty(),
                    "hex (%d,%d) must not have a city road — otherwise the check is about the wrong thing"
                            % [row, col], state)
            var level: int = _rm.get_hex_road_level(row, col)
            check(level == 1,
                    "on hex (%d,%d) with a town road the level must be a trail (1), got %d"
                            % [row, col, level], state)
            checked_hexes += 1
    check(checked_hexes > 0,
            "at least one hex outside the city with a town road must be found", state)


# -------------------------------------------------------
# Segment parsing helpers
# -------------------------------------------------------

# "r1,c1|r2,c2" -> [r1, c1, r2, c2]
func _parse_segment(key: String) -> Array:
    var parts := key.split("|")
    if parts.size() != 2:
        return [-1, -1, -1, -1]
    var a := parts[0].split(",")
    var b := parts[1].split(",")
    if a.size() != 2 or b.size() != 2:
        return [-1, -1, -1, -1]
    return [int(a[0]), int(a[1]), int(b[0]), int(b[1])]

# All segments that have the given hex at either end.
func _segments_touching(segments: Dictionary, row: int, col: int) -> Array:
    var result: Array = []
    for key in segments.keys():
        var s := _parse_segment(key)
        if (s[0] == row and s[1] == col) or (s[2] == row and s[3] == col):
            result.append(s)
    return result

func _has_segment_touching(segments: Dictionary, row: int, col: int) -> bool:
    return not _segments_touching(segments, row, col).is_empty()

# Whether the segment set contains a chain from (from_row, from_col) to
# (to_row, to_col). This checks the SHAPE of the network, not just the is_town_connected flag:
# BFS over the segments in both directions (a road is two-way).
func _has_segment_chain(segments: Dictionary, from_row: int, from_col: int,
        to_row: int, to_col: int) -> bool:
    var visited := {"%d,%d" % [from_row, from_col]: true}
    var queue: Array = [{"row": from_row, "col": from_col}]
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if int(cur.row) == to_row and int(cur.col) == to_col:
            return true
        for seg in _segments_touching(segments, int(cur.row), int(cur.col)):
            var other := [seg[2], seg[3]] if (seg[0] == int(cur.row) and seg[1] == int(cur.col)) \
                    else [seg[0], seg[1]]
            var key := "%d,%d" % [int(other[0]), int(other[1])]
            if visited.has(key):
                continue
            visited[key] = true
            queue.append({"row": int(other[0]), "col": int(other[1])})
    return false

# A free neighbor hex of the city: without improvements and outside the town rings. Needed for
# a PLAYER improvement so that the check "town improvements do not end up in the city
# network" does not cover a hex that is itself a town improvement.
func _free_hex_near_city(city_row: int, city_col: int, rows: int, cols: int,
        tile_data: Array) -> Dictionary:
    for n in _hex_utils.get_neighbors_odd_r(city_row, city_col, rows, cols):
        var tile = tile_data[n.row][n.col]
        if tile == null:
            continue
        if tile.get("improvement", null) != null:
            continue
        if bool(tile.get("in_town_influence", false)):
            continue
        return {"row": int(n.row), "col": int(n.col)}
    return {}

# A free ring hex of a town at a distance of at least min_dist from the center
# (the town itself stands at the very center, so it does not count as its improvement).
# exclude — already occupied hexes ["row,col", ...]: needed when several DIFFERENT
# hexes must be taken from the ring for different improvements.
func _free_ring_hex(town: Dictionary, tile_data: Array, min_dist: int,
        exclude: Array = []):
    for h in town.get("influence_hexes", []):
        var row := int(h.get("row", -1))
        var col := int(h.get("col", -1))
        if row < 0 or col < 0 or row >= tile_data.size() or col >= tile_data[row].size():
            continue
        if bool(tile_data[row][col].get("has_town", false)):
            continue
        if exclude.has("%d,%d" % [row, col]):
            continue
        if _hex_utils.hex_distance(row, col, int(town.get("row", -1)),
                int(town.get("col", -1))) < min_dist:
            continue
        return {"row": row, "col": col}
    return null

func _is_water(tile) -> bool:
    if tile == null:
        return false
    # The water test lives in MapHelpers (WATER_TERRAINS: lake, sea, shallow_sea).
    # The shallows are water for the road logic too: a road is not built over them,
    # exactly as over the deep sea.
    return _map_helpers.is_water_terrain(str(tile.get("terrain", "")))

# Whether there is a LAND path between two hexes (water is impassable). This is an independent
# check of the rule "a road is built whenever it is physically reachable", not
# a call into road_manager: this way the test does not repeat itself.
func _land_path_exists(tile_data: Array, rows: int, cols: int,
        from_row: int, from_col: int, to_row: int, to_col: int) -> bool:
    var visited := {"%d,%d" % [from_row, from_col]: true}
    var queue: Array = [{"row": from_row, "col": from_col}]
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if int(cur.row) == to_row and int(cur.col) == to_col:
            return true
        for n in _hex_utils.get_neighbors_odd_r(int(cur.row), int(cur.col), rows, cols):
            var key := "%d,%d" % [int(n.row), int(n.col)]
            if visited.has(key):
                continue
            visited[key] = true
            if _is_water(tile_data[n.row][n.col]):
                continue
            queue.append({"row": int(n.row), "col": int(n.col)})
    return false

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true

# A town road segment that has at least one end in the fog of war.
func _fog_segment(main_map, rm) -> Array:
    for seg in rm.get_all_town_road_segments().keys():
        var s := _parse_segment(seg)
        if main_map.is_hex_in_fog(s[0], s[1]) or main_map.is_hex_in_fog(s[2], s[3]):
            return [seg]
    return []
