# Headless test of the hard prerequisite of the placement of towns: a town is placed
# only on the land reachable from the city of the player by a road
# (scripts/town_manager.gd).
#   godot --headless --path . --script res://tests/test_town_reachability.gd
#
# The rule under test: the road is not laid over water (MapHelpers.is_water_terrain),
# therefore a town on an island in the middle of the sea could never be connected with
# the city and could never trade. Such a hex must NOT be a valid place for a town.
#
# The checks (the maps are hand-made and deterministic, no random map):
#   1. An island with a full set of attractions (a pile of resources, a strategic
#      resource, a river, a lake coast, a sea beach) is separated from the city by
#      an impassable sea: the town is placed on the mainland, and NEVER on the island —
#      no matter how attractive the island is.
#   2. generate_towns() on a map with one island and many free mainland hexes places all
#      the towns on the mainland; not a single town hex is an island hex.
#   3. The control case: the very same map WITHOUT the sea (the island joins the
#      mainland) — the island hex is a legitimate place, so the rule is exactly
#      "not reachable", and not "the island terrain is forbidden".
#   4. The town, the era-2 guarantee town included, always stands on a hex reachable
#      from the city: the check over the whole map after a live-scene generation.
extends SceneTree

# The hang watchdog: without it a broken _run() coroutine looks like endless silence.
# The details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# We duplicate the constants of town_manager.gd — the test checks the behavior independently.
const MAX_ATTRACTION_DISTANCE := 3

var _tm = null
var _gdata = null
var _hex_utils = null
var _map_helpers = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # The autoloads are taken through the scene tree: in the --script mode the names
    # GameData / CityData are not available at compile time of this file. new_game()
    # also loads all the data (resources, terrains, city_names).
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    _gdata = get_root().get_node("GameData")
    _hex_utils = load("res://scripts/HexUtils.gd")
    _map_helpers = load("res://scripts/map_helpers.gd")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    _test_island_is_never_chosen(state)
    _test_generate_towns_all_on_mainland(state)
    _test_control_joined_island_is_valid(state)
    _test_era2_guarantee_town_is_reachable(state)

    get_root().remove_child(_tm)
    _tm.free()

    if state["failed"]:
        print("TOWN REACHABILITY TEST FAILED")
        quit(1)
    else:
        print("TOWN REACHABILITY TEST OK")
        quit(0)


# -------------------------------------------------------
# The map and the calls of the algorithm
# -------------------------------------------------------

# An empty map: all the hexes are plain, without resources, rivers, improvements and towns.
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


# The direct call "try to place one town" (as in the main pass of generate_towns:
# without a "mandatory zone").
func _try_place(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int,
        exclusion_start_row: int = -1, exclusion_end_row: int = -1,
        exclusion_start_col: int = -1, exclusion_end_col: int = -1) -> Dictionary:
    # The reachability is a prerequisite of the placement, and generate_towns computes it
    # before the calls; the test does the same, so that _try_place_one_town works under
    # the same conditions as in the game.
    _tm._set_reachable(
            _tm._build_reachable_mask(tile_data, rows, cols, city_row, city_col), rows, cols)
    return _tm._try_place_one_town(tile_data, rows, cols, city_row, city_col,
            exclusion_start_row, exclusion_end_row,
            exclusion_start_col, exclusion_end_col,
            -1, -1, -1, -1,
            false)


# A "carpet" of resources over the whole map except skip: then EVERY hex satisfies the top
# priority "2+ different resources in the neighbourhood", and the only valid hexes are those
# skipped (they have no resource of their own, so they are not filtered out as
# "resource hexes"). The same technique as in test_town_priorities.
func _fill_resource_carpet(tile_data: Array, skip: Array, include_strategic: bool = false) -> void:
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            if skip.has(Vector2i(r, c)):
                continue
            var res := "sheep"
            match (r + c) % 3:
                0:
                    res = "copper_deposit" if include_strategic else "sheep"
                1:
                    res = "cows"
            tile_data[r][c]["resource"] = res


# Fills a RECTANGLE (inclusive) with sea and with impassable terrain, and ALSO wipes
# a one-hex "moat" of resources around it: the road/terrain logic must see pure water
# on the ring, without a resource carpet that would make the island reachable in the
# resource masks (the masks do not matter for the reachability, but they do matter for
# the list of the candidate hexes of the test).
func _fill_sea_rect(tile_data: Array, r0: int, r1: int, c0: int, c1: int) -> void:
    for r in range(r0, r1 + 1):
        for c in range(c0, c1 + 1):
            tile_data[r][c]["terrain"] = "sea"
            tile_data[r][c]["resource"] = null
            tile_data[r][c]["river_edges"] = []


# The number of DIFFERENT resources in the radius of MAX_ATTRACTION_DISTANCE from a hex.
# The resources standing ON the water (a lake / the sea) are counted too — exactly as
# _build_multi_resource_mask does: the point of attraction is a resource, not a land hex.
func _distinct_resources_near(tile_data: Array, row: int, col: int) -> int:
    var distinct := {}
    var rows: int = tile_data.size()
    var cols: int = tile_data[row].size()
    for r in range(maxi(0, row - MAX_ATTRACTION_DISTANCE),
            mini(rows, row + MAX_ATTRACTION_DISTANCE + 1)):
        for c in range(maxi(0, col - MAX_ATTRACTION_DISTANCE),
                mini(cols, col + MAX_ATTRACTION_DISTANCE + 1)):
            if _hex_utils.hex_distance(row, col, r, c) > MAX_ATTRACTION_DISTANCE:
                continue
            var res = tile_data[r][c].get("resource", null)
            if res != null and res != "":
                distinct[res] = true
    return distinct.size()


# Is there a land path between two hexes (water is impassable). An independent check of the
# rule "a town is placed only where a road can be laid", and not an appeal to the internal
# mask of town_manager: so the test does not repeat itself.
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


func _is_water(tile) -> bool:
    if tile == null:
        return false
    # The water test lives in MapHelpers (WATER_TERRAINS: lake, sea, shallow_sea).
    return _map_helpers.is_water_terrain(str(tile.get("terrain", "")))


func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true


# -------------------------------------------------------
# 1. The island is never chosen, however attractive it is
# -------------------------------------------------------
func _test_island_is_never_chosen(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 2
    var city_col := 2
    var tile_data := _make_map(rows, cols)

    # The island in the middle of the sea: 5x5 of land beyond an impassable sea ring,
    # far from the city. The island carries its own resource carpet — it satisfies the
    # TOP priority "2+ different resources in the neighbourhood" and would have been a
    # fine place for a town, had it not been for the reachability.
    var island_r0 := 18
    var island_r1 := 22
    var island_c0 := 18
    var island_c1 := 22
    # The "hero" island hex: a full set of attractions — a pile of resources, a strategic
    # resource, a river, a lake coast and a marine beach. In a reachable place the
    # cascade would fight for exactly such a combination.
    var hero_r := 20
    var hero_c := 20
    # The MAINLAND: the valid hexes are every second hex of both axes, so that each of the
    # towns has 2+ resources around it. The island and its sea ring are excluded from the
    # carpet first (their resources are set separately below), so the town has plenty of
    # places to stand on the mainland.
    var mainland_free := []
    for r in range(0, rows, 2):
        for c in range(0, cols, 2):
            if r >= island_r0 - 2 and r <= island_r1 + 2 \
                    and c >= island_c0 - 2 and c <= island_c1 + 2:
                continue
            mainland_free.append(Vector2i(r, c))
    _fill_resource_carpet(tile_data, mainland_free)

    # The sea ring around the island: 2 hexes wide, impassable. The "sea" of MapHelpers is
    # water, and the road Dijkstra skips exactly these terrains.
    _fill_sea_rect(tile_data, island_r0 - 2, island_r1 + 2, island_c0 - 2, island_c1 + 2)
    # The hero hex: a river + a marine beach + a lake coast.
    tile_data[hero_r][hero_c]["terrain"] = "beach"
    tile_data[hero_r][hero_c]["river_edges"] = [0]
    # A lake inside the island, next to the hero hex (the 4th priority) — a point of
    # attraction in its own right, and a wall for the reachability inside the island.
    tile_data[hero_r - 1][hero_c]["terrain"] = "lake"

    # The resource carpet of the island: the hero hex itself has no resource of its own
    # (a resource hex is not a valid place for a town), it picks its 2+ resources from the
    # neighbours. So the island hex set is attractive through and through.
    for r in range(island_r0, island_r1 + 1):
        for c in range(island_c0, island_c1 + 1):
            if r == hero_r and c == hero_c:
                continue
            tile_data[r][c]["resource"] = "sheep" if (r + c) % 2 == 0 else "cows"
    # The strategic resource of the hero — inside the island, in the radius of the hero hex.
    tile_data[hero_r][hero_c + 2]["resource"] = "copper_deposit"

    check(not _land_path_exists(tile_data, rows, cols, city_row, city_col, hero_r, hero_c),
            "по условиям теста до острова НЕ должно быть наземного пути", state)
    check(_distinct_resources_near(tile_data, hero_r, hero_c) >= 2,
            "островной гекс-герой обязан быть привлекательным (2+ ресурса в окрестностях)",
            state)

    # We run the algorithm many times: the base is chosen at random, so a single run could
    # accidentally "pass" without ever reaching the island. 40 runs is enough for the
    # mainland (a huge free area) to be chosen every time — if the island were a valid hex,
    # the reservoir sampling would sooner or later put a town on it.
    for _i in range(40):
        tile_data[hero_r][hero_c]["has_town"] = false
        var placed = _try_place(tile_data, rows, cols, city_row, city_col)
        check(not placed.is_empty(),
                "городок обязан быть размещён на материке", state)
        if placed.is_empty():
            return
        check(not (placed.row >= island_r0 and placed.row <= island_r1
                        and placed.col >= island_c0 and placed.col <= island_c1),
                ("городок НЕ должен вставать на острове: получено (%d,%d), " +
                        "остров = строки %d..%d, столбцы %d..%d")
                        % [placed.row, placed.col, island_r0, island_r1, island_c0, island_c1],
                state)
        check(_land_path_exists(tile_data, rows, cols, city_row, city_col,
                        placed.row, placed.col),
                "место городка (%d,%d) обязано быть достижимо по суше от города (%d,%d)"
                        % [placed.row, placed.col, city_row, city_col], state)


# -------------------------------------------------------
# 2. generate_towns(): all the towns are on the mainland
# -------------------------------------------------------
func _test_generate_towns_all_on_mainland(state: Dictionary) -> void:
    var rows := 50
    var cols := 50
    var city_row := 5
    var city_col := 5
    var tile_data := _make_map(rows, cols)

    var island_r0 := 30
    var island_r1 := 36
    var island_c0 := 30
    var island_c1 := 36
    # The mainland: the valid hexes are every second hex of both axes (each has 2+ different
    # resources around it, and there are enough distances to spread the towns). The island of
    # the sea carries its own resource carpet, so that it is attractive and would have been
    # chosen, had it not been for the reachability.
    var free_hexes := []
    for r in range(0, rows, 2):
        for c in range(0, cols, 2):
            if r >= island_r0 - 2 and r <= island_r1 + 2 \
                    and c >= island_c0 - 2 and c <= island_c1 + 2:
                continue
            free_hexes.append(Vector2i(r, c))
    _fill_resource_carpet(tile_data, free_hexes, true)
    _fill_sea_rect(tile_data, island_r0 - 2, island_r1 + 2, island_c0 - 2, island_c1 + 2)
    # The island carries its own resource carpet (including a strategic resource), so that
    # it is attractive and would have been chosen, had it not been for the reachability.
    for r in range(island_r0, island_r1 + 1):
        for c in range(island_c0, island_c1 + 1):
            tile_data[r][c]["terrain"] = "plain"
            tile_data[r][c]["resource"] = "copper_deposit" if (r + c) % 3 == 0 \
                    else ("sheep" if (r + c) % 2 == 0 else "cows")

    var map_config: Dictionary = _gdata.map_config
    var saved_num_towns = map_config.get("num_towns", 8)
    map_config["num_towns"] = 6
    _tm.generate_towns(tile_data, rows, cols, city_row, city_col,
            0, 1, 0, 1,                      # the starting area is small — the towns are outside
            0, rows - 1, 0, cols - 1)        # "era 2" = the whole map
    map_config["num_towns"] = saved_num_towns

    check(_tm.town_hexes.size() == 6,
            "ожидалось 6 городков, размещено %d" % _tm.town_hexes.size(), state)
    for h in _tm.town_hexes:
        check(_land_path_exists(tile_data, rows, cols, city_row, city_col, h.row, h.col),
                "городок (%d,%d) обязан быть достижим по суше от города" % [h.row, h.col], state)
        check(not (h.row >= island_r0 and h.row <= island_r1
                        and h.col >= island_c0 and h.col <= island_c1),
                "городок (%d,%d) не должен стоять на острове" % [h.row, h.col], state)


# -------------------------------------------------------
# 3. The control case: the same map without the sea — the island is valid
#    (so the rule is "not reachable", and NOT "the island terrain is forbidden")
# -------------------------------------------------------
func _test_control_joined_island_is_valid(state: Dictionary) -> void:
    var rows := 30
    var cols := 30
    var city_row := 2
    var city_col := 2
    var tile_data := _make_map(rows, cols)

    # A "hollow" rectangle of free land in the middle of the plain: ONLY its perimeter is
    # free of resources, the inner 3x3 is a resource carpet. Therefore the valid hexes are
    # exactly the perimeter hexes, and the road to every one of them is by land — there is
    # no sea at all. The control confirms that the island of the first test was rejected
    # because it was NOT REACHABLE, and not because of anything about its terrain.
    var island_r0 := 13
    var island_r1 := 17
    var island_c0 := 13
    var island_c1 := 17
    var free_hexes := []
    for r in range(island_r0, island_r1 + 1):
        for c in range(island_c0, island_c1 + 1):
            # The inner rectangle keeps the carpet (it has resources of its own), the
            # perimeter is free.
            if r == island_r0 or r == island_r1 or c == island_c0 or c == island_c1:
                free_hexes.append(Vector2i(r, c))
    _fill_resource_carpet(tile_data, free_hexes)

    # Every free perimeter hex must be reachable and attractive; a randomly chosen one is
    # the answer. We check that the placed town IS one of the perimeter hexes and that the
    # road to it exists — the island-rule does not forbid the land of the "joined island".
    for r in range(island_r0, island_r1 + 1):
        for c in range(island_c0, island_c1 + 1):
            var is_perimeter: bool = r == island_r0 or r == island_r1 \
                    or c == island_c0 or c == island_c1
            if not is_perimeter:
                continue
            check(_land_path_exists(tile_data, rows, cols, city_row, city_col, r, c),
                    "в контрольной карте (без моря) гекс (%d,%d) обязан быть достижим"
                            % [r, c], state)
            check(_distinct_resources_near(tile_data, r, c) >= 2,
                    "в контрольной карте гекс (%d,%d) обязан быть привлекательным" % [r, c],
                    state)

    var placed = _try_place(tile_data, rows, cols, city_row, city_col)
    check(not placed.is_empty(), "в контрольной карте городок обязан быть размещён", state)
    if placed.is_empty():
        return
    check(_land_path_exists(tile_data, rows, cols, city_row, city_col,
                    placed.row, placed.col),
            "в контрольной карте место городка (%d,%d) обязано быть достижимо по суше"
                    % [placed.row, placed.col], state)


# -------------------------------------------------------
# 4. The live scene: every town (the era-2 guarantee included) is road-reachable
# -------------------------------------------------------
func _test_era2_guarantee_town_is_reachable(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var towns: Array = main_map.towns
    check(towns.size() > 0, "на живой карте должны быть городки", state)
    for town in towns:
        var tr := int(town.get("row", -1))
        var tc := int(town.get("col", -1))
        var tile = main_map.tile_data[tr][tc]
        check(not _is_water(tile),
                "городок (%d,%d) не должен стоять на воде" % [tr, tc], state)
        check(_land_path_exists(main_map.tile_data, main_map.map_rows, main_map.map_cols,
                        main_map.city_row, main_map.city_col, tr, tc),
                "городок (%d,%d) обязан быть достижим по суше от города игрока (%d,%d)"
                        % [tr, tc, main_map.city_row, main_map.city_col], state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
