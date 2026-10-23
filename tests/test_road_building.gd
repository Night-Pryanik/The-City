# Headless test for the roads the player builds (special action "Build
# Road", action_type "road"), and for the connection of the city with a town.
#   godot --headless --path . --script res://tests/test_road_building.gd
#
# Checks (on a deterministic synthetic map + the live MainMap scene):
#   1. The cost of a road SECTION = base × terrain multiplier × distance
#      multiplier (MapHelpers.get_road_step_work_cost). Farther from the city
#      is more expensive; in difficult terrain it is more expensive. The road
#      distance coefficient is taken from game_balance.json and is SEPARATE
#      from the improvement coefficient: the distance multiplier is multiplied
#      by the route length, and at 0.25 a road to a distant town would become
#      unreachable. There is no surcharge for route length.
#   2. Planning a road changes nothing (the plan is a pure calculation for the
#      preview), and after build_road_to the hex is connected to the city
#      network and a chain of segments runs to the city (a check of the shape
#      of the network, not a flag).
#   3. A road is not built where it cannot be: water, an already connected
#      hex, a hex cut off from the city by water.
#   4. A road to a TOWN goes TO THE TOWN ITSELF (to its center) and at the
#      chosen level, not to the nearest road in the influence ring, where the
#      highway would run into the town's path; after building, the city and
#      town networks intersect (is_town_linked_to_city), and the link segments
#      are marked separately.
#   4a. The road the player builds goes ONLY over known territory (in the
#      Influence Ring or scouted): a scouted town without a scouted path to it
#      is unreachable, the reason calls for scouts, and after the corridor is
#      scouted the road appears. Automatic road networks do not get the filter.
#   4b. The road level reaches TO THE TOWN: every section of the route
#      (including the one entering the ring) is of the chosen level, and on the
#      town hex the level is the chosen one too. Previously the route broke off
#      at the ring road, and the last section was the town's path.
#   5. Restoring from a save: the road_built flag on the hex and road_linked in
#      the town record restore both the road and the link
#      (rebuild_player_roads), and serialization writes them.
#   6. Trade: the gate is a single function town_manager.is_trade_available;
#      the town window opens WITHOUT a road (access is free), but trade is
#      marked as unavailable and becomes available after the road is built.
#   7. The "ghost" road on the map: while the "Build Road" preview is open, the
#      route is drawn (only new plan segments) and disappears together with the
#      preview; at the town the route runs entirely over scouted land.
#   8. Road levels (the level is chosen in the preview, the free path is built
#      immediately and does not occupy the project queue). Dedicated checks of
#      levels, route and improvement are in tests/test_road_levels.gd.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const ROAD_ACTION_ID := "build_road"

var _rm = null
var _tm = null
# Autoloads are taken as scene-tree nodes: in --script mode the names GameData
# and CityData are not yet available when this file is compiled.
var _gdata = null
var _cdata = null
# MapHelpers and HexUtils must also NOT be referenced by class name: MapHelpers
# accesses the GameData autoload, and in --script mode such a dependency does
# not compile (workaround — load(), as in test_town_roads for HexUtils).
var _mh = null
var _hu = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken via the scene tree: in --script mode the names
    # GameData/CityData are unavailable when this file is compiled.
    # new_game() also loads all the data (special actions included).
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _mh = load("res://scripts/map_helpers.gd")
    _hu = load("res://scripts/HexUtils.gd")

    _rm = load("res://scripts/road_manager.gd").new()
    get_root().add_child(_rm)
    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    if WATCHDOG.wants_case("cost_per_hex"):
        _test_cost_per_hex(state)
    if WATCHDOG.wants_case("plan_and_build_hex"):
        _test_plan_and_build_hex(state)
    if WATCHDOG.wants_case("merge_adjacent_roads"):
        _test_merge_adjacent_roads(state)
    if WATCHDOG.wants_case("impossible_targets"):
        _test_impossible_targets(state)
    if WATCHDOG.wants_case("town_road_needs_known_territory"):
        _test_town_road_needs_known_territory(state)
    if WATCHDOG.wants_case("ghost_segments"):
        _test_ghost_segments(state)
    if WATCHDOG.wants_case("town_link"):
        _test_town_link(state)
    if WATCHDOG.wants_case("town_road_level"):
        _test_town_road_level(state)
    if WATCHDOG.wants_case("restore_from_save_flags"):
        _test_restore_from_save_flags(state)

    # The live scene is checked last and freed separately: MainMap
    # creates its own TownManager/RoadManager.
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
        print("ROAD BUILDING TEST FAILED")
        quit(1)
    else:
        print("ROAD BUILDING TEST OK")
        quit(0)

# -------------------------------------------------------
# Synthetic map: plain without resources, rivers and improvements
# -------------------------------------------------------

const ROWS := 20
const COLS := 20
const CITY_ROW := 10
const CITY_COL := 10
const TOWN_ROW := 4
const TOWN_COL := 4

# The first road level with a non-zero section cost. Level 1 (path) is free,
# while the cost-formula checks need a base that can be multiplied by the
# multipliers. If there are no paid levels in the data — the test fails here
# rather than silently checking zeros.
func _first_paid_road_level(state: Dictionary) -> int:
    for level in _gdata.get_road_levels():
        if _gdata.get_road_work_cost(int(level)) > 0:
            return int(level)
    check(false, "there must be at least one paid road level in roads.json",
            state)
    return 1

func _make_map() -> Array:
    var tile_data := []
    for r in range(ROWS):
        var row := []
        for c in range(COLS):
            row.append({
                "terrain": "steppe_plain", "cover": "none", "resource": null,
                "quality": "", "crop_bred": null, "improvement": null,
                "decorative": false, "terrain_icon": "", "fill_time": 0.0,
                "production_fractional_remainder": 0.0, "has_town": false,
                "river_edges": [], "in_influence": true, "is_explored": true,
                "in_town_influence": false, "road_built": false,
            })
        tile_data.append(row)
    return tile_data

# Influence ring of the synthetic town: all hexes at distance <= 3.
func _make_town_ring() -> Array:
    var ring: Array = []
    for r in range(ROWS):
        for c in range(COLS):
            if _hu.hex_distance(r, c, TOWN_ROW, TOWN_COL) <= 3:
                ring.append({"row": r, "col": c})
    return ring

# Town record sufficient for road networks and trade.
func _make_town() -> Dictionary:
    return {
        "id": "test_town", "row": TOWN_ROW, "col": TOWN_COL, "name": "Test",
        "influence_radius": 3, "influence_hexes": _make_town_ring(),
        "sell_pool": [], "buy_pool": [], "road_linked": false,
    }

# -------------------------------------------------------
# 1. Cost of a road SECTION: base × terrain × distance
# -------------------------------------------------------

func _test_cost_per_hex(state: Dictionary) -> void:
    check(_gdata.special_actions.has(ROAD_ACTION_ID),
            "data/special_actions.json must have the special action \"Build Road\"",
            state)
    var sa: Dictionary = _gdata.special_actions.get(ROAD_ACTION_ID, {})
    check(str(sa.get("action_type", "")) == "road",
            "the road special action must have action_type == \"road\"", state)
    check(not sa.has("work_cost"),
            "the section cost must not be held in the special action: it is a property of the road level",
            state)

    # The base section cost is taken from the road LEVEL (data/roads.json), not
    # from the special action. We check on base level 1 (path): it is not free,
    # so it has both a base and multipliers. A road to an improvement costs
    # exactly the same — it must not be zeroed for the sake of building an improvement.
    var paid_level := _first_paid_road_level(state)
    var per_hex: int = _gdata.get_road_work_cost(paid_level)
    check(per_hex > 0, "the cost per road section must be set in roads.json", state)
    check(_gdata.get_road_work_cost(1) > 0,
            "the base path must also be paid: a road to an improvement is not free",
            state)

    # The section distance coefficient — from game_balance.json and WITHOUT tech modifiers.
    var road_mod: float = float(_gdata.game_balance.get("road_distance_cost_modifier_per_hex", -1.0))
    check(road_mod > 0.0,
            "game_balance.json must have road_distance_cost_modifier_per_hex", state)
    check(absf(_mh.get_road_distance_cost_modifier() - road_mod) < 0.0001,
            "MapHelpers must take the road distance coefficient from the data", state)
    # The formula is the same as for improvements, but with its own coefficient: 1 + d × value
    check(absf(_mh.get_road_distance_mult(0) - 1.0) < 0.0001,
            "the distance multiplier on the city's own hex must be 1.0", state)
    check(absf(_mh.get_road_distance_mult(5) - (1.0 + 5.0 * road_mod)) < 0.0001,
            "the section distance multiplier must be 1 + distance × coefficient", state)

    # The section cost on a plain 1 hex from the city: base × 1.0 (terrain)
    # × distance multiplier. No surcharge for route length.
    var near_price: Dictionary = _mh.get_road_step_work_cost(
            paid_level, CITY_ROW, CITY_COL + 1, CITY_ROW, CITY_COL, "steppe_plain")
    var near_expected := int(ceil(per_hex * 1.0 * _mh.get_road_distance_mult(1) \
            * float(near_price.get("construction_tech_mult", 1.0))))
    check(int(near_price.get("cost", -1)) == near_expected,
            "section cost near the city = base × distance multiplier (expected %d, got %d)"
                    % [near_expected, int(near_price.get("cost", -1))], state)
    check(int(near_price.get("base_cost", -1)) == per_hex,
            "the base in the calculation must match the work_cost of the road level", state)

    # The path is also charged by the common formula: multipliers on a non-zero
    # base give a positive cost even in difficult terrain. Previously there was
    # maxi(1, …) here and the base was 0 — because of this a road to an
    # improvement was both free and instantaneous.
    var trail_price: Dictionary = _mh.get_road_step_work_cost(
            1, CITY_ROW, CITY_COL + 1, CITY_ROW, CITY_COL, "steppe_mountain")
    check(int(trail_price.get("cost", -1)) > 0,
            "a path section must cost work even in the mountains", state)

    # FARTHER FROM THE CITY IS MORE EXPENSIVE, on the same terrain.
    var far_price: Dictionary = _mh.get_road_step_work_cost(
            paid_level, CITY_ROW - 6, CITY_COL, CITY_ROW, CITY_COL, "steppe_plain")
    check(int(far_price.get("cost", 0)) > int(near_price.get("cost", 0)),
            "a section farther from the city must cost more on the same terrain", state)

    # DIFFICULT TERRAIN IS MORE EXPENSIVE, at the same distance.
    var mountain_price: Dictionary = _mh.get_road_step_work_cost(
            paid_level, CITY_ROW, CITY_COL + 1, CITY_ROW, CITY_COL, "steppe_mountain")
    check(int(mountain_price.get("cost", 0)) > int(near_price.get("cost", 0)),
            "a section in the mountains must cost more than a section on a plain", state)
    # The terrain multiplier is the same work_cost_mult as for improvements.
    check(absf(float(mountain_price.get("terrain_mult", 0.0)) \
            - float(_gdata.terrains.get("steppe_mountain", {}).get("work_cost_mult", -1.0))) < 0.0001,
            "the section terrain multiplier must be taken from work_cost_mult in the data", state)
    check(absf(_mh.get_terrain_work_mult("steppe_plain") - 1.0) < 0.0001,
            "a plain must cost exactly the base", state)
    # Unknown terrain must not break the calculation.
    check(_mh.get_terrain_work_mult("no_such_terrain") == 1.0,
            "unknown terrain must give a neutral multiplier", state)

    # The "Wheel" reduces the DISTANCE CONTRIBUTION — both in improvements and
    # in roads. The formula is the same for both cases, so we check the
    # equality of the results.
    check(absf(_mh.get_distance_tech_mult() - 1.0) < 0.0001,
            "without technologies the distance contribution multiplier must be 1.0", state)

# -------------------------------------------------------
# 2. Planning does not change the network, building connects the hex
# -------------------------------------------------------

func _test_plan_and_build_hex(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    check(_rm.is_hex_connected(CITY_ROW, CITY_COL),
            "after initialize the city hex must be the root of the road network", state)
    check(_rm.get_all_road_segments().is_empty(),
            "after initialize there must be no road segments", state)

    var target := {"row": CITY_ROW - 4, "col": CITY_COL}
    var plan: Dictionary = _rm.plan_road_to(target.row, target.col,
            tile_data, ROWS, COLS)
    check(plan.get("ok", false), "a road to a hex 4 hexes from the city is built: %s"
            % plan.get("reason", ""), state)
    check(int(plan.get("segments", 0)) > 0, "the plan must have the number of new sections", state)
    check(not bool(plan.get("is_town", true)), "an ordinary hex is not a town", state)
    check(not _rm.is_hex_connected(target.row, target.col),
            "planning must not change the road network", state)
    check(_rm.get_all_road_segments().is_empty(),
            "planning must not add segments", state)

    # A repeated plan gives the same result: it is cached by network version.
    var plan2: Dictionary = _rm.plan_road_to(target.row, target.col,
            tile_data, ROWS, COLS)
    check(int(plan2.get("segments", -1)) == int(plan.get("segments", -2)),
            "repeated planning must give the same route length", state)

    check(_rm.build_road_to(target.row, target.col, tile_data, ROWS, COLS),
            "the road to the hex must be built", state)
    check(_rm.is_hex_connected(target.row, target.col),
            "after building the hex must be connected to the city network", state)
    var segments: Dictionary = _rm.get_all_road_segments()
    check(segments.size() == int(plan.get("segments", -1)),
            "the number of segments must match the plan: plan=%d, segments=%d"
                    % [int(plan.get("segments", -1)), segments.size()], state)
    # The shape of the network, not just a flag: a chain must run from the hex to the city.
    check(_has_segment_chain(segments, target.row, target.col, CITY_ROW, CITY_COL),
            "no chain of segments runs from the hex to the city", state)
    # No segment passes over water.
    for key in segments.keys():
        var s := _parse_segment(key)
        check(not _is_water(tile_data[s[0]][s[1]]) and not _is_water(tile_data[s[2]][s[3]]),
                "a road segment must not pass over water: %s" % key, state)
    # An already connected hex does not get a road again.
    check(not _rm.plan_road_to(target.row, target.col, tile_data, ROWS, COLS).get("ok", true),
            "there is nothing to build again at a hex with a road", state)
    check(_rm.get_all_road_segments().size() == segments.size(),
            "repeated planning must not add segments", state)

# -------------------------------------------------------
# 2b. A new road that has come RIGHT UP against its own network merges with it
# -------------------------------------------------------

# The player cannot close such a gap by hand: the "Build Road" button appears
# only on a hex WITHOUT a road, and both hexes of the gap already have a road.
# Previously the route connected to the FIRST reached hex of the network and
# the segment to the second neighboring hex of the network did not appear at
# all — that is how on the screenshot the vineyard with a road and the road to
# the southeast of it did not connect.
#
# Synthetic: a city branch city -> R -> P. Hex Q is adjacent to both R and P,
# but cannot be shorter than one of these links — the pathfinding arrives at
# EITHER of the two (both have entry cost 1, it picks the traversal order), and
# exactly one segment remains unbuilt. After the fix, BOTH are built.
func _test_merge_adjacent_roads(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)

    # City (CITY_ROW, CITY_COL) is even, therefore: E = (0,+1), NE = (-1,0).
    var r_hex := {"row": CITY_ROW, "col": CITY_COL + 1}      # city's neighbor to the east
    var p_hex := {"row": CITY_ROW, "col": CITY_COL + 2}      # R's neighbor to the east
    # Q is a neighbor of BOTH R AND P (R and P share a diagonal neighbor):
    #   (CITY_ROW, CITY_COL+1) -> NE -> (CITY_ROW-1, CITY_COL+1);
    #   (CITY_ROW, CITY_COL+2) -> NW -> (CITY_ROW-1, CITY_COL+1).
    var q_hex := {"row": CITY_ROW - 1, "col": CITY_COL + 1}

    # City branch: city -> R -> P. Both hexes are connected, but are NOT yet
    # neighbors of each other — the gap is left on purpose.
    check(_rm.build_road_to(r_hex.row, r_hex.col, tile_data, ROWS, COLS),
            "preparation: the road to R is built", state)
    check(_rm.build_road_to(p_hex.row, p_hex.col, tile_data, ROWS, COLS),
            "preparation: the road to P is built", state)
    check(_rm.has_road_between(CITY_ROW, CITY_COL, r_hex.row, r_hex.col),
            "preparation: the city is connected to R", state)
    check(_rm.has_road_between(r_hex.row, r_hex.col, p_hex.row, p_hex.col),
            "preparation: R is connected to P", state)
    check(not _rm.is_hex_connected(q_hex.row, q_hex.col),
            "preparation: Q is not yet connected", state)

    # We build the road to Q. It comes right up against TWO hexes of the network at once.
    check(_rm.build_road_to(q_hex.row, q_hex.col, tile_data, ROWS, COLS),
            "the road to Q must be built", state)
    check(_rm.is_hex_connected(q_hex.row, q_hex.col),
            "after building Q must be connected to the city network", state)

    # BOTH neighboring segments must appear: otherwise a gap would remain that
    # the player has no way to close.
    check(_rm.has_road_between(q_hex.row, q_hex.col, r_hex.row, r_hex.col),
            "the new hex must merge with the neighboring hex R of the same network", state)
    check(_rm.has_road_between(q_hex.row, q_hex.col, p_hex.row, p_hex.col),
            "the new hex must also merge with the second neighboring hex P of the same network", state)

    # The merge segment runs over land and at the level of the just-laid road
    # (build_road_to lays a path by default, level 1).
    for key in _rm.get_all_road_segments().keys():
        var s := _parse_segment(key)
        check(not _is_water(tile_data[s[0]][s[1]]) and not _is_water(tile_data[s[2]][s[3]]),
                "a merge segment must not pass over water: %s" % key, state)
    check(_rm.get_segment_level(q_hex.row, q_hex.col, p_hex.row, p_hex.col) == 1,
            "the merge segment must be of the level of the laid road (path)", state)

# -------------------------------------------------------
# 3. A road is not built where it cannot be
# -------------------------------------------------------

func _test_impossible_targets(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)

    # Water hex: a road is not built over water (as with water improvements).
    tile_data[CITY_ROW - 2][CITY_COL]["terrain"] = "lake"
    var water_plan: Dictionary = _rm.plan_road_to(CITY_ROW - 2, CITY_COL,
            tile_data, ROWS, COLS)
    check(not water_plan.get("ok", true),
            "a road must not be built to a water hex", state)

    # A hex cut off from the city by water: there is no land path.
    var island := Vector2i(5, 5)
    for n in _hu.get_neighbors_odd_r(island.y, island.x, ROWS, COLS):
        tile_data[n.row][n.col]["terrain"] = "lake"
    var island_plan: Dictionary = _rm.plan_road_to(island.x, island.y,
            tile_data, ROWS, COLS)
    check(not island_plan.get("ok", true),
            "there can be no road to a hex cut off by water", state)
    check(not str(island_plan.get("reason", "")).is_empty(),
            "an impossible road must have a reason in the hint", state)

    # An improvement with the no_road flag (irrigation canal) does not get a road.
    var canal := {"row": CITY_ROW - 3, "col": CITY_COL}
    tile_data[canal.row][canal.col]["improvement"] = "irrigation_canal"
    var canal_plan: Dictionary = _rm.plan_road_to(canal.row, canal.col,
            tile_data, ROWS, COLS)
    check(not canal_plan.get("ok", true),
            "no road is built to an irrigation canal (no_road)", state)

# -------------------------------------------------------
# 3b. A road to a town goes only over scouted territory
# -------------------------------------------------------

func _test_town_road_needs_known_territory(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    _setup_town(tile_data)

    # Without a knowledge restriction the route exists — these are the "old" rules.
    var open_plan: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL,
            tile_data, ROWS, COLS)
    check(open_plan.get("ok", false),
            "without a knowledge restriction the road to the town is built", state)

    # Game rule: you can interact with a town only on a scouted hex, and you
    # can approach it only over scouted land. Here the player scouted the town
    # itself, but there is no path to it yet — we cut the "corridor" with a
    # strip of unscouted hexes between the city and the town.
    _set_corridor_known(tile_data, false)
    var filtered: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL,
            tile_data, ROWS, COLS, _known_hex_filter(tile_data))
    check(not filtered.get("ok", true),
            "through unscouted territory a road to the town must not be built", state)
    # The reason is a TRANSLATABLE interface string, so we compare it with the
    # same tr() that builds it in road_manager. The language at the time of
    # this check can be anything: LocalizationManager applies it on the first
    # frame, while this block of _run() runs before the first await. We check
    # the BRANCH (it calls for scouts), not the presence of a particular word
    # in the text.
    var scouting_reason := "No scouted route from the city to the town — send scouts there"
    check(str(filtered.get("reason", "")) == _rm.tr(scouting_reason),
            "the reason must call for scouts, not say \"there is no route at all\": %s"
                    % filtered.get("reason", ""), state)

    # As soon as the player has scouted the passage — the road appears. The plan
    # cache must be reset at the same time (bump_map_knowledge), otherwise the
    # old answer would remain.
    _set_corridor_known(tile_data, true)
    _rm.bump_map_knowledge()
    var after_scouting: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL,
            tile_data, ROWS, COLS, _known_hex_filter(tile_data))
    check(after_scouting.get("ok", false),
            "after scouting the passage the road to the town must appear: %s"
                    % after_scouting.get("reason", ""), state)
    check(_rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS, -1,
            _known_hex_filter(tile_data)),
            "the road along the scouted path is built", state)
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "the town is connected to the city", state)

# The strip of hexes strictly between the city and the town: known=true makes
# it scouted, false — unscouted (a corridor that does not exist yet).
func _set_corridor_known(tile_data: Array, known: bool) -> void:
    for row in range(mini(TOWN_ROW, CITY_ROW) + 1, maxi(TOWN_ROW, CITY_ROW)):
        for col in range(COLS):
            tile_data[row][col]["in_influence"] = false
            tile_data[row][col]["is_explored"] = known

# The predicate "is the hex known to the player" — the same logic as main_map.is_hex_known.
func _known_hex_filter(tile_data: Array) -> Callable:
    return func(row: int, col: int) -> bool:
        var tile = tile_data[row][col]
        if tile == null:
            return false
        return bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false))

# -------------------------------------------------------
# 3c. Data for the "ghost" road: new plan segments
# -------------------------------------------------------

# The preview on the map draws the NEW segments of the plan (road_manager
# .get_plan_new_segments). We check exactly what the player pays for: the same
# number of segments as in the plan, each between neighboring hexes, none of
# them yet built, and the route ends at the already finished city network.
func _test_ghost_segments(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    var target := {"row": CITY_ROW - 4, "col": CITY_COL}
    var plan: Dictionary = _rm.plan_road_to(target.row, target.col,
            tile_data, ROWS, COLS)
    check(plan.get("ok", false), "the preview check needs a successful route: %s"
            % plan.get("reason", ""), state)

    var ghost: Dictionary = _rm.get_plan_new_segments(plan)
    check(not ghost.is_empty(), "the plan must have new segments for the preview", state)
    check(ghost.size() == int(plan.get("segments", -1)),
            "the ghost road shows as many segments as there are in the plan: %d and %d"
                    % [ghost.size(), int(plan.get("segments", -1))], state)
    var built: Dictionary = _rm.get_all_road_segments()
    for key in ghost.keys():
        check(not built.has(key),
                "the preview must not contain an already built segment: %s" % key, state)
        var s := _parse_segment(key)
        check(_hu.hex_distance(s[0], s[1], s[2], s[3]) == 1,
                "a preview segment must connect neighboring hexes: %s" % key, state)
    check(_ghost_reaches_network(ghost, _rm, target.row, target.col),
            "the preview route must reach the already built city network", state)
    # The preview builds nothing — it is a pure sample from the cached plan.
    check(_rm.get_all_road_segments().is_empty(),
            "getting the preview segments must not build the road", state)

    _rm.build_road_to(target.row, target.col, tile_data, ROWS, COLS)
    var after: Dictionary = _rm.plan_road_to(target.row, target.col, tile_data, ROWS, COLS)
    check(_rm.get_plan_new_segments(after).is_empty(),
            "after building there is nothing to show: there are no new segments", state)

# Does the preview route reach the already built city network: we walk over the
# segments of the preview from the target hex and wait for a hex that the
# network already covers. We must not check the chain all the way to the city
# hex — the last section to it is ALREADY built, and it is not in the preview
# (this is the difference between preview and build).
func _ghost_reaches_network(ghost: Dictionary, rm, start_row: int, start_col: int) -> bool:
    if ghost.is_empty():
        return false
    var seen := {"%d,%d" % [start_row, start_col]: true}
    var queue: Array = [{"row": start_row, "col": start_col}]
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if (cur.row != start_row or cur.col != start_col) \
                and rm.is_hex_connected(int(cur.row), int(cur.col)):
            return true
        for key in ghost.keys():
            var s := _parse_segment(key)
            var other = null
            if s[0] == cur.row and s[1] == cur.col:
                other = {"row": s[2], "col": s[3]}
            elif s[2] == cur.row and s[3] == cur.col:
                other = {"row": s[0], "col": s[1]}
            if other == null:
                continue
            var k := "%d,%d" % [int(other.row), int(other.col)]
            if not seen.has(k):
                seen[k] = true
                queue.append(other)
    return false

# Are all hexes of the preview route known to the player (in the Influence Ring or scouted).
func _ghost_is_known(main_map, ghost: Dictionary) -> bool:
    for key in ghost.keys():
        var s := _parse_segment(key)
        if not main_map.is_hex_known(s[0], s[1]) or not main_map.is_hex_known(s[2], s[3]):
            return false
    return true

# -------------------------------------------------------
# 4. Road to a town: to the nearest road in the influence ring
# -------------------------------------------------------

# Places a town with ONE improvement in the influence ring and builds its road network.
func _setup_town(tile_data: Array) -> Dictionary:
    var town := _make_town()
    for h in town["influence_hexes"]:
        tile_data[h.row][h.col]["in_town_influence"] = true
    tile_data[TOWN_ROW][TOWN_COL]["has_town"] = true
    # An improvement at distance 3 from the center — in the ring: the town gets
    # its own road network, which the city's road will then reach for.
    # decorative = true — required: by this flag rebuild_roads_from_existing
    # distinguishes the TOWN's improvements (their roads are built by the town
    # itself) from the player's improvements (their roads run to the city).
    tile_data[TOWN_ROW][TOWN_COL + 3]["improvement"] = "farm"
    tile_data[TOWN_ROW][TOWN_COL + 3]["decorative"] = true
    _rm.rebuild_town_roads([town], tile_data, ROWS, COLS)
    return town

func _test_town_link(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    var town := _setup_town(tile_data)
    _tm.towns = [town]

    check(_rm.is_town_connected(TOWN_ROW, TOWN_COL, TOWN_ROW, TOWN_COL + 3),
            "the town must have its own road network (center — improvement)", state)
    check(not _rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "initially the town is not connected to the city", state)

    var plan: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS)
    check(plan.get("ok", false), "a road to the town must be buildable: %s"
            % plan.get("reason", ""), state)
    check(bool(plan.get("is_town", false)), "the road plan to the town is marked as a town plan", state)
    check(int(plan.get("segments", 0)) > 0, "the road to the town has new sections", state)

    # Key rule: the route goes TO THE TOWN ITSELF (to its center), and does not
    # break off at the nearest road of the influence ring, and ends at a road
    # of the CITY network. Otherwise the chosen level would not reach the town,
    # and the highway would turn into a path at the edge of the ring.
    var road_path: Array = plan.get("path", [])
    check(road_path.size() >= 2, "the plan must have a path of at least two hexes", state)
    if road_path.size() >= 2:
        var town_side: Dictionary = road_path[0]
        var city_side: Dictionary = road_path[road_path.size() - 1]
        check(town_side.row == TOWN_ROW and town_side.col == TOWN_COL,
                "the route must start in the CENTER of the town (%d,%d), got (%d,%d)"
                        % [TOWN_ROW, TOWN_COL, town_side.row, town_side.col], state)
        check(_rm.is_hex_connected(city_side.row, city_side.col),
                "the route must end at a road of the city network (%d,%d)"
                        % [city_side.row, city_side.col], state)

    var linked := {"hit": false}
    _rm.town_link_established.connect(func(_r, _c):
        linked["hit"] = int(_r) == TOWN_ROW and int(_c) == TOWN_COL)
    check(_rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS),
            "the road to the town must be built", state)
    check(bool(linked.get("hit", false)),
            "after building the link the town_link_established signal must arrive", state)
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "after building the town must be connected to the city", state)

    # The link segments are marked separately: they are used to draw the city
    # with fog gates (the road to the town may pass through unexplored hexes).
    var link_segments: Dictionary = _rm.get_all_town_link_segments()
    check(not link_segments.is_empty(), "the link segments with the town must be marked", state)
    for key in link_segments.keys():
        check(_rm.get_all_road_segments().has(key),
                "a link segment must also be in the city network: %s" % key, state)
        var s := _parse_segment(key)
        check(not _is_water(tile_data[s[0]][s[1]]) and not _is_water(tile_data[s[2]][s[3]]),
                "a link segment must not pass over water: %s" % key, state)

    # A connected town does not get a road a second time.
    check(not _rm.plan_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS).get("ok", true),
            "a road must not be built again to a connected town", state)

    # --- Trade gate: a single function shared by the UI and future mechanics ---
    check(not _tm.is_trade_available(town),
            "without a road trade with the town is unavailable", state)
    town["road_linked"] = true
    check(_tm.is_trade_available(town),
            "with a road trade with the town is available", state)

# -------------------------------------------------------
# 4b. A road to a town reaches the town itself at the CHOSEN level
# -------------------------------------------------------

# Requirement: the level chosen in the preview must reach the town, and not
# break off at the nearest road of the influence ring, where the highway would
# run into the town's own path. We check on the synthetic: we build the road to
# the town at a level above the path and make sure that EVERY section of the
# route (including the one that enters the ring and leads to the center) is of
# this level, and on the town hex the road level equals the chosen one. Before
# the fix the last section would have been the town's path (level 1).
func _test_town_road_level(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    _setup_town(tile_data)

    var level := _highest_road_level()
    check(level > 1,
            "roads.json must have a level above the path, otherwise there is nothing to check", state)
    if level <= 1:
        return

    var plan: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS)
    check(plan.get("ok", false), "the level check needs a successful route: %s"
            % plan.get("reason", ""), state)
    if not plan.get("ok", false):
        return

    check(_rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS, -1,
            Callable(), level),
            "the road to the town must be built at the chosen level", state)

    var road_path: Array = plan.get("path", [])
    for i in range(road_path.size() - 1):
        var a: Dictionary = road_path[i]
        var b: Dictionary = road_path[i + 1]
        check(_rm.get_segment_level(a.row, a.col, b.row, b.col) == level,
                "the section (%d,%d)-(%d,%d) of the road to the town must be of level %d"
                        % [a.row, a.col, b.row, b.col, level], state)

    # The road level on a hex is the maximum over the adjoining sections of both
    # networks: on the town hex there are both the player's section (of the
    # chosen level) and a section of the town network (path). The maximum must
    # be the chosen level — otherwise the highway would visually and along the
    # route turn into a path right at the town.
    var hex_level: int = _rm.get_hex_road_level(TOWN_ROW, TOWN_COL)
    check(hex_level == level,
            "on the town hex the road level must be %d (the chosen one), got %d"
                    % [level, hex_level], state)

# The highest road level in the data. Needed where a check needs a level
# DIFFERENT from the town's road level (path, 1): tech unlocking in a headless
# run is not guaranteed, while planning and building do not check the level.
func _highest_road_level() -> int:
    var level := 0
    for l in _gdata.get_road_levels():
        level = maxi(level, int(l))
    return level

# -------------------------------------------------------
# 5. Restoring roads from save flags
# -------------------------------------------------------

func _test_restore_from_save_flags(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    var town := _setup_town(tile_data)
    _tm.towns = [town]

    # We build a road to an ordinary hex and to the town and set the flags —
    # exactly what main_map._mark_road_built does.
    var plain := {"row": CITY_ROW - 4, "col": CITY_COL}
    _rm.build_road_to(plain.row, plain.col, tile_data, ROWS, COLS)
    tile_data[plain.row][plain.col]["road_built"] = true
    _rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS)
    tile_data[TOWN_ROW][TOWN_COL]["road_built"] = true
    town["road_linked"] = true
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL), "preparation: town connected", state)

    # The town record serializes the link flag, and loading reads it — including
    # an old save where there is no such field.
    var serialized: Array = _tm.serialize_towns()
    check(serialized.size() == 1 and bool(serialized[0].get("road_linked", false)),
            "the road_linked flag must get into the town save", state)
    _tm.towns.clear()
    _tm.load_towns(serialized)
    check(_tm.towns.size() == 1 and bool(_tm.towns[0].get("road_linked", false)),
            "the road_linked flag must be restored from the save", state)
    _tm.load_towns([{"row": TOWN_ROW, "col": TOWN_COL, "name": "Old"}])
    check(not bool(_tm.towns[0].get("road_linked", true)),
            "an old save without the link flag must be false", state)

    # Recomputing the networks from scratch — exactly as when loading a game.
    _rm.initialize(CITY_ROW, CITY_COL)
    check(_rm.get_all_road_segments().is_empty(),
            "after recomputation the road network starts empty", state)
    _rm.rebuild_roads_from_existing(tile_data, ROWS, COLS)
    _rm.rebuild_town_roads([town], tile_data, ROWS, COLS)
    check(not _rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "roads built by the player are not restored by improvements on their own", state)
    _rm.rebuild_player_roads(tile_data, ROWS, COLS)
    check(_rm.is_hex_connected(plain.row, plain.col),
            "the road to an ordinary hex must be restored by the road_built flag", state)
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "the road to the town must be restored by the flags", state)
    check(not _rm.get_all_town_link_segments().is_empty(),
            "the link segments must be restored together with the road", state)

# -------------------------------------------------------
# 6. Live scene: button, full build cycle, town window, save
# -------------------------------------------------------

func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var panel = main_map.control_panel
    var bm = main_map.build_manager

    # We research the technologies of all road levels (currently the "Wheel").
    # The build checked below is STAGED, and staging only makes sense for a
    # paid level: the path (work_cost = 0) is built immediately and does not
    # enter the project queue. Without the technology the best available level
    # is the path, and the whole scenario below would check instant building
    # instead of the queue of sections.
    for level in _gdata.get_road_levels():
        var raw = _gdata.get_road_by_level(int(level)).get("unlock_tech", null)
        # The field can be null (the path has no technology), and `null or ""`
        # in GDScript does NOT give an empty string — without this check the
        # list of technologies would get the string "<null>" and the loop would break.
        if not (raw is String) or str(raw).is_empty():
            continue
        if not _cdata.is_tech_unlocked(str(raw)):
            _cdata.unlocked_technologies.append(str(raw))
    var default_level: int = _gdata.get_max_unlocked_road_level()
    check(_gdata.get_road_work_cost(default_level) > 0,
            "after researching the technology the best road level must be paid",
            state)

    # --- Base path: paid and staged, like any road ---
# Previously level 1 was free, and then it could not have a "step that
# accumulates work": such a step would not accumulate work and would hold the
# slot forever. Now the path has a base too, so it goes through the ordinary
# project queue.
    var trail_target := _find_hex_without_road(main_map)
    if not trail_target.is_empty():
        var t_row2 := int(trail_target.row)
        var t_col2 := int(trail_target.col)
        var trail_breakdown: Dictionary = main_map.get_road_cost_breakdown(
                t_row2, t_col2, 1)
        if trail_breakdown.get("ok", false):
            check(int(trail_breakdown.get("cost", 0)) > 0,
                    "the path route must cost something", state)
            check(bm.start_build(t_row2, t_col2, ROAD_ACTION_ID, null, 1),
                    "the path must be buildable", state)
            check(not main_map.project_manager.get_project_at(t_row2, t_col2).is_empty(),
                    "the path must enter the project queue, not be built instantly",
                    state)
            check(not rm.is_hex_connected(t_row2, t_col2),
                    "before building the hex must not be connected to the network", state)
            main_map.project_manager.cancel_project_at(t_row2, t_col2)

    # --- "Build Road" button on a hex where there is no road yet ---
    var target := _find_hex_without_road(main_map)
    check(not target.is_empty(), "there must be a hex without a road on the live map", state)
    if not target.is_empty():
        var row := int(target.row)
        var col := int(target.col)
        var actions: Array = panel._collect_actions(row, col, main_map.tile_data[row][col])
        check(_has_action(actions, "special", ROAD_ACTION_ID),
                "a hex without a road must have the \"Build Road\" button", state)

        # The preview cost and the real build cost — the same calculation, from
        # a SINGLE source of steps. The main thing here is the invariant: the
        # sum of the step costs equals the displayed cost. Previously this
        # relied on "the last step picks up the remainder", but now it holds by
        # construction.
        var plan: Dictionary = main_map.get_road_plan(row, col)
        check(plan.get("ok", false), "a hex without a road must have a route: %s"
                % plan.get("reason", ""), state)
        # We compute the cost breakdown for a PAID level: for the path all steps
        # cost 0, and the invariant "sum of steps = cost" would be checked on
        # zeros, not noticing a rounding error. We choose the paid level
        # explicitly, not "by default": in a live game the "Wheel" may not be
        # researched, and then the best available level is the free path.
        var paid_level := _first_paid_road_level(state)
        var breakdown: Dictionary = main_map.get_road_cost_breakdown(row, col, paid_level)
        check(breakdown.get("ok", false), "the road cost breakdown must be available", state)
        var steps: Array = breakdown.get("steps", [])
        check(steps.size() > 0, "a road must have at least one step", state)
        var sum_steps := 0
        for step in steps:
            sum_steps += int(step.get("work_cost", 0))
        check(sum_steps == int(breakdown.get("cost", -1)),
                "the road cost must be the EXACT sum of the costs of its steps (sum %d, cost %d)"
                        % [sum_steps, int(breakdown.get("cost", -1))], state)
        # There are exactly as many steps as there are new sections on the map:
        # already built segments do not enter the queue and are not charged.
        check(steps.size() == main_map.road_manager.get_plan_new_segments(plan).size(),
                "there must be exactly as many steps as there are new sections on the map",
                state)
        # Each step costs at least the base and takes its own distance into account.
        for step in steps:
            var w: int = int(step.get("work_cost", 0))
            var price: Dictionary = step.get("price", {})
            check(w >= int(price.get("base_cost", 0)) and w > 0,
                    "a step cost cannot be zero or less than the base", state)

        # The same thing via get_improvement_work_cost — it is used by
        # build_manager to check "cost > 0".
        var cost: Dictionary = main_map.get_improvement_work_cost(ROAD_ACTION_ID, row, col, paid_level)
        check(int(cost.get("cost", -1)) == int(breakdown.get("cost", -2)) \
                and int(cost.get("cost", 0)) > 0,
                "build_manager must see the same cost as the preview", state)

        # Preview in the preview column: road cost and route length.
        panel.select_hex(row, col)
        panel._preview_action = {"type": "special", "action_id": ROAD_ACTION_ID,
                "imp_id": "", "target_res_id": null, "label": "Build Road",
                "eff_res": "", "selected_culture_id": null,
                "road_level": paid_level}
        panel._refresh()
        var preview_text := _collect_text(panel._preview_container)
        check(preview_text.contains("Cost: %d work" % int(breakdown.get("cost", 0))),
                "the preview must show the final road cost", state)
        check(preview_text.contains("Per section"),
                "the preview must show the cost per section", state)
        check(preview_text.contains("Distance to city"),
                "the preview must show how distance affects the cost", state)
        check(preview_text.contains("Terrain on the route"),
                "the preview must show how terrain affects the cost", state)
        check(preview_text.contains("New route sections: %d" % steps.size()),
                "the preview must show the number of new route sections", state)

        # The "ghost" road: while the preview is open, the route is drawn on the
        # map, and it contains no already built segments (there is no need to
        # draw them).
        var ghost: Dictionary = main_map.map_renderer._road_preview_segments
        check(not ghost.is_empty() and ghost.size() == int(plan.get("segments", -1)),
                "the preview must draw a route of as many segments as there are in the plan: %d and %d"
                        % [ghost.size(), int(plan.get("segments", -1))], state)
        var built_now: Dictionary = rm.get_all_road_segments()
        for key in ghost.keys():
            check(not built_now.has(key),
                    "the preview route must not contain already built segments: %s" % key, state)
        panel.clear_preview()
        check(main_map.map_renderer._road_preview_segments.is_empty(),
                "after closing the preview the route must disappear from the map", state)

        # Full cycle: button -> STAGED project -> road segments on the map.
        # The road is no longer an ordinary build on this hex, but a queue of
        # sections, so a project runs, not an entry in active_builds.
        check(bm.start_build(row, col, ROAD_ACTION_ID, null, paid_level),
                "the road build must be startable", state)
        var project = main_map.project_manager.get_project_at(row, col)
        check(not project.is_empty(),
                "after starting, a staged road project must run on the hex", state)
        var step_count: int = project.get("steps", []).size()
        check(step_count > 0, "the project must have at least one section", state)
        check(not bm.is_building(row, col),
                "road sections must not be an ordinary build on the hex", state)

        # The project ghost lives on the map until the end of the build and
        # equals the number of unbuilt sections.
        var ghost_during: Dictionary = main_map.map_renderer._project_ghost_segments
        check(ghost_during.size() == step_count,
                "the project ghost must show all unbuilt sections: %d and %d"
                        % [ghost_during.size(), step_count], state)
        check(not rm.is_hex_connected(row, col),
                "until the road project is complete there is no road to the target yet", state)

        # The "Build Road" button is not shown on a hex under construction —
        # instead the project cancellation is offered.
        var during_actions: Array = panel._collect_actions(row, col, main_map.tile_data[row][col])
        check(not _has_action(during_actions, "special", ROAD_ACTION_ID),
                "on a hex under construction the \"Build Road\" button is not shown", state)
        check(_has_action(during_actions, "cancel_project", ""),
                "on a hex under construction there must be a project cancel button", state)

        await _finish_build(state)
        check(main_map.project_manager.get_project_at(row, col).is_empty(),
                "after the project completes it must disappear from the queue", state)
        check(rm.is_hex_connected(row, col),
                "after the build completes the hex must get a road", state)
        check(main_map.map_renderer._project_ghost_segments.is_empty(),
                "after the project completes the route ghost must disappear", state)
        check(bool(main_map.tile_data[row][col].get("road_built", false)),
                "the hex must have the road_built flag (input data for the save)", state)
        check(not _has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
                "special", ROAD_ACTION_ID),
                "the \"Build Road\" button is not shown again at a hex with a road", state)

    # --- Road to the town with the full cycle, trade and its gate ---
    var town = _find_unlinked_town(main_map)
    check(town != null, "the live map must have a town not yet connected", state)
    if town != null:
        var t_row := int(town.get("row", -1))
        var t_col := int(town.get("col", -1))
        # Scouting opened the TOWN ITSELF, but not the path to it: there is no corridor yet.
        main_map.tile_data[t_row][t_col]["is_explored"] = true
        main_map.road_manager.bump_map_knowledge()
        var tile = main_map.tile_data[t_row][t_col]

        # The town window opens WITHOUT a road: access is free, only trade is gated.
        check(not main_map.town_manager.is_trade_available(town),
                "town without a road: trade unavailable", state)
        main_map.open_town_ui(t_row, t_col)
        check(main_map.town_ui.visible, "a scouted town opens even without a road", state)
        check(not main_map.town_ui.status_label.text.is_empty(),
                "in a window without a road there must be a caption about unavailable trade", state)
        main_map.town_ui.close_town()

        var town_actions: Array = panel._collect_actions(t_row, t_col, tile)
        check(_has_action(town_actions, "special", ROAD_ACTION_ID),
                "the town hex must have the \"Build Road\" button", state)
        var open_action := _find_action(town_actions, "open_town")
        check(not open_action.is_empty() and bool(open_action.get("enabled", false)),
                "the \"Open town\" button is active even without a road", state)

        await _test_town_road_cycle(main_map, bm, panel, town, state)

    # --- The road flag gets into the save ---
    var save_manager = get_root().get_node("SaveManager")
    var serialized_tiles: Array = save_manager._serialize_tile_data(main_map)
    var saved_roads := 0
    for r in range(serialized_tiles.size()):
        for c in range(serialized_tiles[r].size()):
            if not serialized_tiles[r][c].is_empty() \
                    and bool(serialized_tiles[r][c].get("road_built", false)):
                saved_roads += 1
    check(saved_roads > 0, "flags of built roads must get into the hex save", state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

# -------------------------------------------------------
# 6b. Town road scenario on the live scene
# -------------------------------------------------------

# Full cycle: first there is NO road (the town is scouted, but there is no path
# to it), then scouting opens the corridor, then the road is built and links
# the towns. A separate function because the scenario is asynchronous (await)
# and must be able to exit early: a town not connected to the city by land at
# all (an island) is not a mechanic bug, and such a case is more honest to skip
# than to adjust the map.
func _test_town_road_cycle(main_map, bm, panel, town, state: Dictionary) -> void:
    var rm = main_map.road_manager
    var t_row := int(town.get("row", -1))
    var t_col := int(town.get("col", -1))
    var tile = main_map.tile_data[t_row][t_col]

    # The check "is there a land path at all" — a plan WITHOUT the knowledge
    # restriction (the game code itself does not do this, but for choosing the
    # scenario it is fine: plan_road_to has no side effects).
    var open_plan: Dictionary = rm.plan_road_to(t_row, t_col, main_map.tile_data,
            main_map.map_rows, main_map.map_cols)
    if not open_plan.get("ok", false):
        print("SKIPPED: the selected town is not connected to the city by land")
        return

    # While there is no scouted path to the town, there will be no road: only
    # the town itself is known, and there is nothing to go to it through. This
    # is the main rule — previously the route went directly through unexplored land.
    var no_route: Dictionary = main_map.get_road_plan(t_row, t_col)
    check(not no_route.get("ok", true),
            "without a scouted path the road to the town must not be built", state)
    check(str(no_route.get("reason", "")).contains("scouted"),
            "the reason must call for scouts: %s" % no_route.get("reason", ""), state)
    check(not bm.start_build(t_row, t_col, ROAD_ACTION_ID),
            "a road build without a scouted path must be rejected", state)

    # A scout reaches by land from the town to the city — the corridor is open.
    var opened := _explore_corridor(main_map, t_row, t_col)
    check(opened > 0, "scouting must open a corridor to the town", state)
    var town_plan: Dictionary = main_map.get_road_plan(t_row, t_col)
    check(town_plan.get("ok", false), "after scouting the path the road is available: %s"
            % town_plan.get("reason", ""), state)
    check(_path_is_known(main_map, town_plan.get("path", [])),
            "no hex of the route must be unscouted", state)

    # The preview of the road to the town draws the whole route — and all of it
    # over scouted land (the panel caption warns about this: the high price is
    # not due to a glitch, but due to a detour over scouted territory).
    panel.select_hex(t_row, t_col)
    panel._preview_action = {"type": "special", "action_id": ROAD_ACTION_ID,
            "imp_id": "", "target_res_id": null, "label": "Build Road",
            "eff_res": "", "selected_culture_id": null}
    panel._refresh()
    var ghost: Dictionary = main_map.map_renderer._road_preview_segments
    check(not ghost.is_empty(), "the preview of the road to the town must draw a route", state)
    check(_ghost_is_known(main_map, ghost),
            "the route to the town must not contain unscouted hexes", state)
    panel.clear_preview()
    check(main_map.map_renderer._road_preview_segments.is_empty(),
            "after closing the preview the route to the town must disappear", state)

    # Building a road on the town hex is allowed: the prohibitions "town here"
    # and "influence ring here" do not concern it (see build_manager.start_build).
    check(bm.start_build(t_row, t_col, ROAD_ACTION_ID),
            "the road to the town must be buildable", state)
    await _finish_build(state)
    check(rm.is_town_linked_to_city(t_row, t_col),
            "after the build the town must be connected to the city", state)
    check(bool(town.get("road_linked", false)),
            "the town record must have the road_linked flag", state)
    check(main_map.town_manager.is_trade_available(town),
            "with a road trade with the town is available", state)
    check(not _has_action(panel._collect_actions(t_row, t_col, tile),
            "special", ROAD_ACTION_ID),
            "the road button is no longer shown to a connected town", state)
    main_map.open_town_ui(t_row, t_col)
    check(main_map.town_ui.visible, "the town window opens with a road too", state)
    check(main_map.town_ui.status_label.text.is_empty(),
            "with a road the caption about unavailable trade disappears", state)
    main_map.town_ui.close_town()

    # The trade icon is drawn only for a connected and revealed town.
    check(main_map.map_renderer._is_town_trade_connected(t_row, t_col),
            "the renderer must consider the town connected", state)
    # Link segments are drawn with the same gates as the town roads:
    # first era, then fog.
    var link_segments: Dictionary = rm.get_all_town_link_segments()
    check(not link_segments.is_empty(), "a built link must have segments", state)
    check(not main_map.map_renderer.are_town_roads_visible(),
            "in the 1st era roads to towns are not drawn", state)
    for key in link_segments.keys():
        check(not main_map.map_renderer.is_town_road_segment_visible(
                _parse_segment(key)[0], _parse_segment(key)[1],
                _parse_segment(key)[2], _parse_segment(key)[3]),
                "in the 1st era a link segment must not be drawn: %s" % key, state)
    # From the Antiquity era the link is visible, but still does not reveal fog.
    main_map.advance_to_next_era()
    await process_frame
    for key in link_segments.keys():
        var s := _parse_segment(key)
        var visible_by_rule: bool = not main_map.is_hex_in_fog(s[0], s[1]) \
                and not main_map.is_hex_in_fog(s[2], s[3])
        check(main_map.map_renderer.is_town_road_segment_visible(s[0], s[1], s[2], s[3])
                == visible_by_rule,
                "the visibility of a link segment did not match the fog rule: %s" % key, state)

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# Waits for all active builds to finish: in the test work accumulates in game
# time, so the debug mode "Ignore construction requirements" is used — it
# brings builds to 100% in a frame.
func _finish_build(_state: Dictionary) -> void:
    var previous: bool = _cdata.ignore_build_requirements
    _cdata.ignore_build_requirements = true
    for _i in range(6):
        await process_frame
    _cdata.ignore_build_requirements = previous

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

# All segments with at least one end at the given hex.
func _segments_touching(segments: Dictionary, row: int, col: int) -> Array:
    var result: Array = []
    for key in segments.keys():
        var s := _parse_segment(key)
        if (s[0] == row and s[1] == col) or (s[2] == row and s[3] == col):
            result.append(s)
    return result

# Is there a chain from one hex to another in the set of segments (BFS in both
# directions: the road is two-way). Checks the SHAPE of the network, not just flags.
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

func _is_water(tile: Dictionary) -> bool:
    return _mh.is_water_terrain(str(tile.get("terrain", "plain")))

# All the text from the preview container — as one string (for content checks).
func _collect_text(node: Node) -> String:
    var text := ""
    for child in node.get_children():
        if child is Label:
            text += str((child as Label).text) + "\n"
        text += _collect_text(child)
    return text

# Is there an action of type `type` with id action_id in the panel's action list.
func _has_action(actions: Array, type: String, action_id: String) -> bool:
    return not _find_action(actions, type, action_id).is_empty()

func _find_action(actions: Array, type: String, action_id: String = "") -> Dictionary:
    for a in actions:
        if not a is Dictionary:
            continue
        if str(a.get("type", "")) != type:
            continue
        if action_id == "" or str(a.get("action_id", "")) == action_id:
            return a
    return {}

# An Influence Ring hex to which there is no road yet (land, without an improvement).
func _find_hex_without_road(main_map) -> Dictionary:
    var rm = main_map.road_manager
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("decorative", false)) or tile.get("improvement", null) != null:
                continue
            if _is_water(tile) or rm.is_hex_connected(row, col):
                continue
            if not rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols).get("ok", false):
                continue
            return {"row": row, "col": col}
    return {}

# The first town not yet connected to the city by roads.
func _find_unlinked_town(main_map):
    var rm = main_map.road_manager
    for town in main_map.town_manager.towns:
        if not rm.is_town_linked_to_city(int(town.get("row", -1)), int(town.get("col", -1))):
            return town
    return null

# Simulates scouting a path from the town to the city: the player opens hexes
# along the land path until they meet already known land. This is how a
# scouted corridor looks in the real game — scouting chunks always adjoin
# known territory. Returns the number of opened hexes.
func _explore_corridor(main_map, from_row: int, from_col: int) -> int:
    var queue: Array = [{"row": from_row, "col": from_col}]
    var visited := {"%d,%d" % [from_row, from_col]: true}
    var opened := 0
    # Scouting goes FROM the town, which is already scouted, so the first hex
    # does not stop the scouting — the exception is made only for it.
    var first := true
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if not first and main_map.is_hex_known(int(cur.row), int(cur.col)):
            continue
        first = false
        main_map.tile_data[cur.row][cur.col]["is_explored"] = true
        opened += 1
        for n in _hu.get_neighbors_odd_r(int(cur.row), int(cur.col),
                main_map.map_rows, main_map.map_cols):
            var key := "%d,%d" % [n.row, n.col]
            if visited.has(key):
                continue
            visited[key] = true
            if _is_water(main_map.tile_data[n.row][n.col]):
                continue
            queue.append({"row": n.row, "col": n.col})
    main_map.road_manager.bump_map_knowledge()
    return opened

# Are all hexes of the route known to the player (in the Influence Ring or scouted).
func _path_is_known(main_map, path: Array) -> bool:
    for hex in path:
        if not main_map.is_hex_known(int(hex.row), int(hex.col)):
            return false
    return true

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
