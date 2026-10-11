# Headless test of the cascading-refinement town placement
# (scripts/town_manager.gd).
#   godot --headless --path . --script res://tests/test_town_priorities.gd
#
# Checks (on synthetic maps — deterministically, without a random map):
#   1. The base = the HIGHEST priority that has a valid hex ON THE WHOLE MAP:
#      while the map has a free spot with 2+ resources in the vicinity,
#      the town will not settle by water (river / lake / sea — lower priorities).
#   2. Moving to the next priority — ONLY when the current one is exhausted on the whole
#      map (all resource vicinities in the starting forbidden zone → river base).
#   3. The base search runs OVER THE WHOLE MAP: the single valid hex, lost
#      among thousands of candidate hexes, must be found.
#   4. Cascading refinement: the town relocates within REFINEMENT_RADIUS,
#      "picking up" lower priorities — up to the ideal "2+ resources AND
#      a strategic resource AND a river AND a lake shore AND a sea beach".
#   5. A failure on one priority does not break the cascade: "strategic" not found —
#      we still try the river and earn it.
#   6. An empty map (no resources, no rivers, no lakes, no beaches) → the town
#      is not placed (empty dictionary).
#   7. generate_towns(): on a synthetic map with an excess of resources,
#      ALL num_towns towns are placed, and each one actually satisfies the base
#      priority (2+ different resources within MAX_ATTRACTION_DISTANCE).
extends SceneTree

# Hang watchdog: without it, a broken _run() coroutine looks from the outside like an
# eternal silence. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Duplicate the town_manager.gd constant — the test verifies the behavior independently.
const MAX_ATTRACTION_DISTANCE := 3

var _tm = null
var _gdata = null
var _hex_utils = null

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at the compilation stage of this file.
    # new_game() also loads all the data (resources, terrain, city_names).
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    _gdata = get_root().get_node("GameData")
    # The global class is also taken through load(): in --script mode the name
    # HexUtils is not guaranteed at the compilation stage of the test.
    _hex_utils = load("res://scripts/HexUtils.gd")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    if WATCHDOG.wants_case("resources_beat_water"):
        _test_resources_beat_water(state)
    if WATCHDOG.wants_case("primary_exhausted_falls_through"):
        _test_primary_exhausted_falls_through(state)
    if WATCHDOG.wants_case("full_map_scan_finds_only_valid_hex"):
        _test_full_map_scan_finds_only_valid_hex(state)
    if WATCHDOG.wants_case("and_chain_reaches_ideal"):
        _test_and_chain_reaches_ideal(state)
    if WATCHDOG.wants_case("skipped_tier_does_not_break_cascade"):
        _test_skipped_tier_does_not_break_cascade(state)
    if WATCHDOG.wants_case("empty_map_places_nothing"):
        _test_empty_map_places_nothing(state)
    if WATCHDOG.wants_case("generate_towns_places_all"):
        _test_generate_towns_places_all(state)

    get_root().remove_child(_tm)
    _tm.free()

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TOWN PRIORITIES TEST FAILED")
        quit(1)
    else:
        print("TOWN PRIORITIES TEST OK")
        quit(0)


# -------------------------------------------------------
# Map and algorithm calls
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


# Direct call of "try to place one town" (as in the main pass of
# generate_towns: without the "required" area).
func _try_place(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int,
        exclusion_start_row: int = -1, exclusion_end_row: int = -1,
        exclusion_start_col: int = -1, exclusion_end_col: int = -1,
        require_start_row: int = -1, require_end_row: int = -1,
        require_start_col: int = -1, require_end_col: int = -1) -> Dictionary:
    return _tm._try_place_one_town(tile_data, rows, cols, city_row, city_col,
            exclusion_start_row, exclusion_end_row,
            exclusion_start_col, exclusion_end_col,
            require_start_row, require_end_row,
            require_start_col, require_end_col,
            false)


# Fills the map with a "carpet" of resources (including a strategic one if
# include_strategic): then the priority mask "2+ resources in the vicinity"
# covers the WHOLE map, and the only valid hexes left are the ones
# skipped in skip (they have no resource of their own, so they are not rejected
# as "resource hexes").
func _fill_resource_carpet(tile_data: Array, skip: Array, include_strategic: bool = true) -> void:
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


# Makes the whole map the given terrain, except for the hexes in skip.
func _fill_terrain(tile_data: Array, terrain: String, skip: Array) -> void:
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            if skip.has(Vector2i(r, c)):
                continue
            tile_data[r][c]["terrain"] = terrain


# -------------------------------------------------------
# Priority condition checks (computed independently of town_manager)
# -------------------------------------------------------

func _hexes_in_radius(tile_data: Array, row: int, col: int) -> Array:
    var result := []
    var rows: int = tile_data.size()
    var cols: int = tile_data[row].size()
    for r in range(maxi(0, row - MAX_ATTRACTION_DISTANCE),
            mini(rows, row + MAX_ATTRACTION_DISTANCE + 1)):
        for c in range(maxi(0, col - MAX_ATTRACTION_DISTANCE),
                mini(cols, col + MAX_ATTRACTION_DISTANCE + 1)):
            if _hex_utils.hex_distance(row, col, r, c) <= MAX_ATTRACTION_DISTANCE:
                result.append(Vector2i(r, c))
    return result


# Number of DISTINCT resources within MAX_ATTRACTION_DISTANCE of the hex.
func _distinct_resources_near(tile_data: Array, row: int, col: int) -> int:
    var distinct := {}
    for p in _hexes_in_radius(tile_data, row, col):
        var res = tile_data[p.x][p.y].get("resource", null)
        if res != null and res != "":
            distinct[res] = true
    return distinct.size()


# Whether there is a strategic resource within MAX_ATTRACTION_DISTANCE of the hex.
func _has_strategic_near(tile_data: Array, row: int, col: int) -> bool:
    for p in _hexes_in_radius(tile_data, row, col):
        var res = tile_data[p.x][p.y].get("resource", null)
        if res == null or res == "":
            continue
        var res_data: Dictionary = _gdata.raw_resources.get(res, {})
        if bool(res_data.get("strategic", false)):
            return true
    return false


func _has_lake_neighbor(tile_data: Array, row: int, col: int) -> bool:
    var rows: int = tile_data.size()
    var cols: int = tile_data[row].size()
    for n in _hex_utils.get_neighbors_odd_r(row, col, rows, cols):
        if tile_data[n.row][n.col].get("terrain", "") == "lake":
            return true
    return false


func _has_river(tile_data: Array, row: int, col: int) -> bool:
    var edges: Array = tile_data[row][col].get("river_edges", [])
    return edges.size() > 0


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true


# -------------------------------------------------------
# 1. Resource vicinities beat water (base — top priority)
# -------------------------------------------------------
func _test_resources_beat_water(state: Dictionary) -> void:
    var rows := 30
    var cols := 30
    var tile_data := _make_map(rows, cols)
    # A cluster of resources (2 different) — top priority. Water (river, lake, beach) —
    # lower priorities, but noticeably farther away. If the base were chosen "by
    # convenience", the town could settle on water.
    tile_data[5][5]["resource"] = "cows"
    tile_data[6][6]["resource"] = "sheep"
    tile_data[25][10]["river_edges"] = [0]
    tile_data[25][25]["terrain"] = "lake"
    tile_data[24][25]["terrain"] = "beach"

    var placed = _try_place(tile_data, rows, cols, 0, 0)
    check(not placed.is_empty(),
            "the town must be placed: there are resource vicinities", state)
    if placed.is_empty():
        return
    var r: int = placed.row
    var c: int = placed.col
    check(_distinct_resources_near(tile_data, r, c) >= 2,
            ("the base must be a resource one: expected 2+ different resources within %d, " +
                    "got %d at (%d,%d)")
                    % [MAX_ATTRACTION_DISTANCE, _distinct_resources_near(tile_data, r, c), r, c],
            state)
    check(tile_data[r][c].get("terrain", "") != "beach",
            "the town must not settle on a sea beach while there are resource spots", state)
    check(not _has_river(tile_data, r, c),
            "the town must not settle on a river hex while there are resource spots", state)
    check(not _has_lake_neighbor(tile_data, r, c),
            "the town must not settle on a lake shore while there are resource spots", state)


# -------------------------------------------------------
# 2. Priority exhausted on the WHOLE map → move to the next one
# -------------------------------------------------------
func _test_primary_exhausted_falls_through(state: Dictionary) -> void:
    var rows := 30
    var cols := 30
    var tile_data := _make_map(rows, cols)
    # Resources (including a strategic one) — only in the upper half of the map, which
    # the starting forbidden zone covers entirely: the resource priorities
    # are exhausted on the WHOLE map, and only then must the generator go lower.
    tile_data[5][5]["resource"] = "cows"
    tile_data[6][6]["resource"] = "sheep"
    tile_data[7][7]["resource"] = "copper_deposit"
    # Below the forbidden zone — the only river hex.
    tile_data[25][10]["river_edges"] = [0]

    var placed = _try_place(tile_data, rows, cols, 0, 0, 0, 19, 0, cols - 1)
    check(not placed.is_empty(),
            "the town must move to the next priority, not get lost", state)
    if placed.is_empty():
        return
    check(placed.row == 25 and placed.col == 10,
            "expected the \"river\" base at (25,10), got (%d,%d)" % [placed.row, placed.col], state)
    check(_has_river(tile_data, placed.row, placed.col),
            "the base must be a river hex", state)
    check(_distinct_resources_near(tile_data, placed.row, placed.col) == 0,
            "there must be no resources near the base — they are all in the forbidden zone", state)
    check(not _has_strategic_near(tile_data, placed.row, placed.col),
            "there must be no strategic resource near the base", state)


# -------------------------------------------------------
# 3. Base search — OVER THE WHOLE MAP (without cutting off after N random attempts)
# -------------------------------------------------------
func _test_full_map_scan_finds_only_valid_hex(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    # A resource "carpet" over the whole map: the top-priority mask covers the WHOLE
    # map, and the only valid hex left is (35,35) — it has no resource
    # of its own, so it is not rejected as a "resource hex".
    _fill_resource_carpet(tile_data, [Vector2i(35, 35)])

    var placed = _try_place(tile_data, rows, cols, 0, 0)
    check(not placed.is_empty(),
            "the single valid hex on the map must be found (full-map scan)", state)
    if placed.is_empty():
        return
    check(placed.row == 35 and placed.col == 35,
            "expected (35,35), got (%d,%d)" % [placed.row, placed.col], state)
    check(_distinct_resources_near(tile_data, placed.row, placed.col) >= 2,
            "the found hex must satisfy the top priority", state)


# -------------------------------------------------------
# 4. Cascading refinement picks up the WHOLE priority chain
# -------------------------------------------------------
func _test_and_chain_reaches_ideal(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    var base_r := 20
    var base_c := 20
    var hero_r := 20
    var hero_c := 21
    # The whole map is a lake (impassable), except for two valid hexes:
    #   base — a "merely resource" hex;
    #   hero — the ideal: 2+ resources AND a strategic resource AND a river AND a lake shore
    #          AND a sea beach. It is 1 hex from base, i.e. within the refinement
    #          radius REFINEMENT_RADIUS.
    _fill_terrain(tile_data, "lake", [Vector2i(base_r, base_c), Vector2i(hero_r, hero_c)])
    _fill_resource_carpet(tile_data, [Vector2i(base_r, base_c), Vector2i(hero_r, hero_c)])
    tile_data[hero_r][hero_c]["terrain"] = "beach"
    tile_data[hero_r][hero_c]["river_edges"] = [0]

    check(_distinct_resources_near(tile_data, hero_r, hero_c) >= 2,
            "the ideal hex must have 2+ resources in the vicinity", state)
    check(_has_strategic_near(tile_data, hero_r, hero_c),
            "the ideal hex must have a strategic resource in the vicinity", state)
    check(_has_lake_neighbor(tile_data, hero_r, hero_c),
            "the ideal hex must be on a lake shore", state)

    # The base is chosen randomly from the two valid hexes, so we run it
    # several times — both paths are checked (the base is already ideal and a move to the ideal).
    for _i in range(25):
        var placed = _try_place(tile_data, rows, cols, 0, 0)
        if placed.is_empty():
            check(false, "the town must be placed (the map has valid hexes)", state)
            return
        check(placed.row == hero_r and placed.col == hero_c,
                "the cascade must pick up the whole chain: expected (%d,%d), got (%d,%d)"
                        % [hero_r, hero_c, placed.row, placed.col],
                state)
        check(_distinct_resources_near(tile_data, placed.row, placed.col) >= 2,
                "the final hex must have 2+ resources in the vicinity", state)
        check(_has_strategic_near(tile_data, placed.row, placed.col),
                "the final hex must have a strategic resource in the vicinity", state)
        check(_has_river(tile_data, placed.row, placed.col),
                "the final hex must stand on a river", state)
        check(tile_data[placed.row][placed.col].get("terrain", "") == "beach",
                "the final hex must be on a sea shore", state)


# -------------------------------------------------------
# 5. A priority failure does not break the cascade
# -------------------------------------------------------
func _test_skipped_tier_does_not_break_cascade(state: Dictionary) -> void:
    var rows := 36
    var cols := 36
    var tile_data := _make_map(rows, cols)
    var base_r := 18
    var base_c := 18
    var river_r := 18
    var river_c := 19
    # The whole map is a lake, except for base and a river hex nearby. The "carpet" is only of
    # NON-strategic resources, and the only strategic resource lies in
    # the far corner among impassable water: the strategic-priority mask
    # is non-empty, but it has no reachable valid hex.
    _fill_terrain(tile_data, "lake", [Vector2i(base_r, base_c), Vector2i(river_r, river_c)])
    _fill_resource_carpet(tile_data, [Vector2i(base_r, base_c), Vector2i(river_r, river_c)], false)
    tile_data[2][2]["resource"] = "copper_deposit"
    tile_data[river_r][river_c]["river_edges"] = [0]

    for _i in range(25):
        var placed = _try_place(tile_data, rows, cols, 0, 0)
        if placed.is_empty():
            check(false, "the town must be placed without fail", state)
            return
        check(placed.row == river_r and placed.col == river_c,
                ("the cascade must continue after skipping a priority: " +
                        "expected (%d,%d), got (%d,%d)")
                        % [river_r, river_c, placed.row, placed.col],
                state)
        check(_has_river(tile_data, placed.row, placed.col),
                "the earned \"river\" priority must be preserved", state)
        check(_distinct_resources_near(tile_data, placed.row, placed.col) >= 2,
                "the base priority \"2+ resources\" must be preserved", state)
        check(not _has_strategic_near(tile_data, placed.row, placed.col),
                "the skipped strategic priority must not appear", state)


# -------------------------------------------------------
# 6. Empty map → the town is not placed
# -------------------------------------------------------
func _test_empty_map_places_nothing(state: Dictionary) -> void:
    var rows := 20
    var cols := 20
    var tile_data := _make_map(rows, cols)
    var placed = _try_place(tile_data, rows, cols, 0, 0)
    check(placed.is_empty(),
            "on a map without resources, rivers, lakes and beaches there is nowhere to place a town", state)


# -------------------------------------------------------
# 7. generate_towns(): all towns are placed, each one's base is a resource base
# -------------------------------------------------------
func _test_generate_towns_places_all(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    # Resource-free hexes — every second one along both axes: around each of them
    # there are 2+ different resources, and the distances are enough to spread the towns out.
    var free_hexes := []
    for r in range(rows):
        for c in range(cols):
            if r % 2 == 0 and c % 2 == 0:
                free_hexes.append(Vector2i(r, c))
    _fill_resource_carpet(tile_data, free_hexes)

    var map_config: Dictionary = _gdata.map_config
    var saved_num_towns = map_config.get("num_towns", 8)
    map_config["num_towns"] = 5
    _tm.generate_towns(tile_data, rows, cols, 20, 20,
            0, 0, 0, 0,                # starting forbidden zone (the city hex)
            0, rows - 1, 0, cols - 1)  # "era-2" = the whole map: no extra town needed
    map_config["num_towns"] = saved_num_towns

    check(_tm.town_hexes.size() == 5,
            "expected 5 towns, placed %d" % _tm.town_hexes.size(), state)
    for h in _tm.town_hexes:
        check(_distinct_resources_near(tile_data, h.row, h.col) >= 2,
                "town (%d,%d) must have 2+ resources in the vicinity"
                        % [h.row, h.col],
                state)
    for i in range(_tm.town_hexes.size()):
        for j in range(i + 1, _tm.town_hexes.size()):
            var a: Dictionary = _tm.town_hexes[i]
            var b: Dictionary = _tm.town_hexes[j]
            check(_hex_utils.hex_distance(a.row, a.col, b.row, b.col) >= 3,
                    "towns (%d,%d) and (%d,%d) are too close"
                            % [a.row, a.col, b.row, b.col],
                    state)
