# Headless test: town territory NEVER intrudes onto the player's start area
# (Ring of Influence + 1st era Region).
#   godot --headless --path . --script res://tests/test_town_start_area.gd
#
# The invariant is checked from two sides:
#   A. Generation — the player's resources are not attraction points. Previously a
#      town was placed for the resources of the start area, and its ring (radius 3)
#      intruded onto the player's land: a resource in the Ring of Influence was
#      marked in_town_influence, build_manager blocked its improvement, and the
#      town placed its decorative construction there.
#   B. Rings — every hex of the start area is clipped from the influence ring, for
#      all towns without exception (including the guaranteed 2nd-era town).
#      Clipped hexes do not get the in_town_influence flag, do not enter the sell
#      pool or decorative improvements.
#
# Checks (on synthetic maps — deterministically):
#   1. Resources lying ONLY in the start area do not give a hex the base
#      priority "2+ resources in the vicinity"; the same resources placed next
#      to the hex but OUTSIDE the area do give it (the rule does not switch the
#      mask off entirely).
#   2. The player's strategic resource does not attract towns: the "strategic"
#      mask does not go beyond the start area.
#   3. A town ring right at the area border is clipped; the player's resource
#      next to the town does not enter the sell pool or decorative improvements.
#   4. Towns restored from a save (load_towns) are clipped the same way —
#      old games must not load with towns on the player's land.
#   5. generate_towns() remembers the passed exclusion zone as the player's start
#      area, and no town stands on it.
#   6. Live MainMap scene (new game): the start area has neither ring hexes,
#      nor towns, nor decorative improvements; after advancing the era, in the
#      territory assigned to the player no "dead zones" remain
#      (in_influence ∩ in_town_influence = ∅).
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal silence
# from the outside. See tests/watchdog.gd for details.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Identifiers from data/resources: two different ordinary resources for the
# "2+ different resources" priority and one strategic (metals.json, strategic: true).
const RES_A := "sheep"
const RES_B := "cows"
const RES_STRATEGIC := "hematite_deposit"

# The player's start area on synthetic maps: the central 6x6 square.
const AREA_R0 := 9
const AREA_R1 := 14
const AREA_C0 := 9
const AREA_C1 := 14

var _tm = null
var _gdata = null
var _cdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    if WATCHDOG.wants_case("player_resources_are_not_attraction"):
        _test_player_resources_are_not_attraction(state)
    if WATCHDOG.wants_case("player_strategic_is_not_attraction"):
        _test_player_strategic_is_not_attraction(state)
    if WATCHDOG.wants_case("ring_is_clipped_by_player_area"):
        _test_ring_is_clipped_by_player_area(state)
    if WATCHDOG.wants_case("loaded_towns_are_clipped"):
        _test_loaded_towns_are_clipped(state)
    if WATCHDOG.wants_case("generate_towns_remembers_player_area"):
        _test_generate_towns_remembers_player_area(state)

    # Live scene — last and separately: MainMap creates its own TownManager,
    # there is no need to keep a second instance around.
    get_root().remove_child(_tm)
    _tm.free()
    _tm = null

    if WATCHDOG.wants_case("live_scene"):
        await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TOWN START AREA TEST FAILED")
        quit(1)
    else:
        print("TOWN START AREA TEST OK")
        quit(0)


# -------------------------------------------------------
# Synthetic maps
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


# Places two alternating resource types in the player's start area.
func _fill_player_area_with_resources(tile_data: Array) -> void:
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            tile_data[r][c]["resource"] = RES_A if (r + c) % 2 == 0 else RES_B


# Whether the hex lies in the synthetic player start area.
func _in_player_area(row: int, col: int) -> bool:
    return row >= AREA_R0 and row <= AREA_R1 and col >= AREA_C0 and col <= AREA_C1

# Resource output (sheep -> raw_meat/raw_milk/wool). It is exactly this that
# lies in a town's sell pool, not the resource itself (see
# TownEconomy.collect_base_resources), so the leak checks look here.
func _produces(resource_id: String) -> Array:
    var ids: Array = []
    var data: Dictionary = _gdata.raw_resources.get(resource_id, {})
    for product_id in data.get("produces", {}):
        ids.append(str(product_id))
    return ids


# Same for arbitrary borders — needed in the generate_towns check, where the
# start area is set by the call, not by the map constants.
func _in_area(row: int, col: int,
        r0: int, r1: int, c0: int, c1: int) -> bool:
    return row >= r0 and row <= r1 and col >= c0 and col <= c1


# -------------------------------------------------------
# 1. The player's resources are not counted as attraction points
# -------------------------------------------------------
func _test_player_resources_are_not_attraction(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    _fill_player_area_with_resources(tile_data)

    # Probe hex — just outside the start area (row 9, column 15). All resources
    # in its vicinity (radius 3) lie INSIDE the player's area: two different
    # types, i.e. without the new rule it would get the base priority
    # "2+ different resources in the vicinity".
    var probe := Vector2i(AREA_R0, AREA_C1 + 1)
    var mask: PackedByteArray = _tm._build_multi_resource_mask(tile_data, rows, cols)
    check(mask[probe.x * cols + probe.y] == 0,
        "player start area resources must not give a town base priority (hex %s landed in the multi_resource mask)" % str(probe), state)

    # Control: the same two types placed OUTSIDE the area, in the vicinity of
    # the probe hex, do give priority. So the rule cuts off exactly the player's
    # territory and does not break the mask itself.
    tile_data[probe.x][probe.y + 2]["resource"] = RES_A
    tile_data[probe.x + 1][probe.y + 2]["resource"] = RES_B
    mask = _tm._build_multi_resource_mask(tile_data, rows, cols)
    check(mask[probe.x * cols + probe.y] == 1,
        "resources OUTSIDE the start area must still attract a town (hex %s did not land in the multi_resource mask)" % str(probe), state)


# -------------------------------------------------------
# 2. The player's strategic resource does not attract towns
# -------------------------------------------------------
func _test_player_strategic_is_not_attraction(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    tile_data[AREA_R0][AREA_C0]["resource"] = RES_STRATEGIC

    var mask: PackedByteArray = _tm._build_strategic_mask(tile_data, rows, cols)
    var outside: Array = []
    for r in range(rows):
        for c in range(cols):
            if mask[r * cols + c] == 0:
                continue
            if not _in_player_area(r, c):
                outside.append([r, c])
    check(outside.is_empty(),
        "the player's strategic resource must not attract towns beyond the start area (violators: %s)" % str(outside), state)

    # Control: a strategic resource OUTSIDE the area works as before.
    var probe := Vector2i(AREA_R0, AREA_C1 + 1)
    tile_data[probe.x][probe.y + 1]["resource"] = RES_STRATEGIC
    mask = _tm._build_strategic_mask(tile_data, rows, cols)
    check(mask[probe.x * cols + probe.y] == 1,
        "a strategic resource outside the start area must attract a town (hex %s did not land in the strategic mask)" % str(probe), state)


# -------------------------------------------------------
# 3. The ring is clipped by the start area (including the era-2 town)
# -------------------------------------------------------
func _test_ring_is_clipped_by_player_area(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    # The PLAYER's resource in the ring zone but inside the start area (hex
    # (12,14) — exactly 3 hexes from the town (12,17)): previously it entered
    # both the ring and the sell pool and the decorative improvement, becoming
    # unavailable to the player.
    tile_data[12][AREA_C1]["resource"] = RES_A

    # Two towns right at the border: an ordinary one and a "guaranteed" one for
    # the 2nd era. The rule must be the same — otherwise the guaranteed town
    # would again end up intruding onto the player's start territory.
    var town: Dictionary = _tm._make_town_record(0, 12, AREA_C1 + 3, false)
    var era2_town: Dictionary = _tm._make_town_record(1, 18, 12, true)
    _tm.towns.append(town)
    _tm.towns.append(era2_town)
    tile_data[12][AREA_C1 + 3]["has_town"] = true
    tile_data[18][12]["has_town"] = true

    _tm.compute_all_town_influences(tile_data, rows, cols)

    check(_tm.towns.size() == 2,
        "the test must have 2 towns (ordinary and era-2 guaranteed)", state)
    for t in _tm.towns:
        var leaked: Array = []
        for h in t.get("influence_hexes", []):
            if _in_player_area(int(h.row), int(h.col)):
                leaked.append([int(h.row), int(h.col)])
        check(leaked.is_empty(),
            "town ring (%d,%d) must not contain hexes of the player start area (clipped: %s, is_era2_guaranteed=%s)"
                % [int(t.row), int(t.col), str(leaked), str(bool(t.get("is_era2_guaranteed", false)))], state)
        # The ring does not degenerate into emptiness: the center and nearest
        # hexes remain.
        var keeps_center := false
        for h in t.get("influence_hexes", []):
            if int(h.row) == int(t.row) and int(h.col) == int(t.col):
                keeps_center = true
                break
        check(keeps_center,
            "after clipping, the town ring (%d,%d) must keep at least its center" % [int(t.row), int(t.col)], state)

    # The in_town_influence flag is not set on the player's hexes.
    var flagged: Array = []
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            if bool(tile_data[r][c].get("in_town_influence", false)):
                flagged.append([r, c])
    check(flagged.is_empty(),
        "the player start area must not have the in_town_influence flag (violators: %s)" % str(flagged), state)

    # The player's resource output did not enter the town's sell pool.
    # It is exactly the OUTPUT (a sheep's wool/raw_meat/raw_milk) that is
    # checked, not "sheep" itself: the sell pool holds crops and goods, not
    # animals (see TownEconomy.collect_base_resources), so "sheep in the pool"
    # cannot happen in principle and the check would be forever green.
    var player_products := _produces(RES_A)
    check(not player_products.is_empty(),
        "resource \"%s\" must have output, otherwise the leak check is meaningless" % RES_A, state)
    var sold_player_output: Array = []
    for t in _tm.towns:
        for res_id in t.get("sell_pool", []):
            if player_products.has(str(res_id)):
                sold_player_output.append([int(t.row), int(t.col), str(res_id)])
    check(sold_player_output.is_empty(),
        "a town must not sell the output of resources lying in the player start area (leaks: %s)"
            % str(sold_player_output), state)

    # Decorative improvements are not built on the player's land.
    _tm._place_decorative_town_improvements(tile_data, rows, cols)
    var built_on_player_area: Array = []
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            if tile_data[r][c].get("improvement", null) != null:
                built_on_player_area.append([r, c])
    check(built_on_player_area.is_empty(),
        "a town must not place improvements on the player start area (hexes: %s)" % str(built_on_player_area), state)




# -------------------------------------------------------
# 4. Towns loaded from a save are clipped the same way
# -------------------------------------------------------
# Exactly the path main_map takes when loading a game: towns are restored from
# save records (load_towns), the player start area borders come from map_state
# (set_player_start_area), and only after that the rings are recomputed. An old
# game must not load with towns intruding onto the player's land.
func _test_loaded_towns_are_clipped(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    # Save format [[row, col], ...] — it has no ring, it is rebuilt.
    _tm.load_towns([[12, AREA_C1 + 3], [18, 12]])
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    _tm.compute_all_town_influences(tile_data, rows, cols)

    check(_tm.towns.size() == 2,
        "both towns must be restored from the save, got %d" % _tm.towns.size(), state)
    for t in _tm.towns:
        var leaked: Array = []
        for h in t.get("influence_hexes", []):
            if _in_player_area(int(h.row), int(h.col)):
                leaked.append([int(h.row), int(h.col)])
        check(leaked.is_empty(),
            "a loaded town (%d,%d) must not intrude with its ring onto the player start area (hexes: %s)"
                % [int(t.row), int(t.col), str(leaked)], state)
    var flagged := 0
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            if bool(tile_data[r][c].get("in_town_influence", false)):
                flagged += 1
    check(flagged == 0,
        "after loading, the player start area must not keep the in_town_influence flag (hexes: %d)" % flagged, state)


# -------------------------------------------------------
# 5. generate_towns() remembers the start area
# -------------------------------------------------------
func _test_generate_towns_remembers_player_area(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    # Resource carpet, except for free hexes — as in test_town_priorities: then
    # the top priority is available everywhere and towns get placed.
    for r in range(rows):
        for c in range(cols):
            if r % 2 == 0 and c % 2 == 0:
                continue
            tile_data[r][c]["resource"] = RES_A if (r + c) % 2 == 0 else RES_B

    var saved_town_count: int = _cdata.world_town_count
    _cdata.world_town_count = 4
    # The start area is the central 13x13 hexes, "era-2" is the whole map.
    _tm.generate_towns(tile_data, rows, cols, 20, 20,
            14, 26, 14, 26,
            0, rows - 1, 0, cols - 1)
    _cdata.world_town_count = saved_town_count

    check(_tm.player_start_area == {
            "start_row": 14, "end_row": 26, "start_col": 14, "end_col": 26},
        "generate_towns must remember the exclusion zone as the player start area, got: %s" % str(_tm.player_start_area), state)
    check(_tm.towns.size() > 0,
        "on this map towns must get placed (otherwise there is nothing to check)", state)
    for t in _tm.towns:
        check(not _in_area(int(t.row), int(t.col), 14, 26, 14, 26),
            "a town center must not stand in the player start area (%d,%d)" % [int(t.row), int(t.col)], state)
        for h in t.get("influence_hexes", []):
            if _in_area(int(h.row), int(h.col), 14, 26, 14, 26):
                check(false,
                    "a town ring (%d,%d) intrudes onto the player start area at (%d,%d)"
                        % [int(t.row), int(t.col), int(h.row), int(h.col)], state)
                break


# -------------------------------------------------------
# 6. Live MainMap scene (new game)
# -------------------------------------------------------
func _test_live_scene(state: Dictionary) -> void:
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var tile_data = main_map.tile_data
    # 1. The player start area has neither rings, nor towns, nor their improvements.
    var intruders: Array = []
    for row in range(main_map.start_region_start_row, main_map.start_region_end_row + 1):
        for col in range(main_map.start_region_start_col, main_map.start_region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_town_influence", false)) \
                    or bool(tile.get("has_town", false)) \
                    or bool(tile.get("decorative", false)):
                intruders.append([row, col])
    check(intruders.is_empty(),
        "on the live map the player start area is free of towns and their territories (violators: %s)" % str(intruders), state)

    # 2. No individual ring (including that of the era-2 guaranteed town)
    #    contains hexes of the start area.
    var ring_leaks: Array = []
    for t in main_map.towns:
        for h in t.get("influence_hexes", []):
            if _in_main_map_start_area(main_map, int(h.row), int(h.col)):
                ring_leaks.append([int(t.row), int(t.col), int(h.row), int(h.col)])
    check(ring_leaks.is_empty(),
        "town rings must not contain hexes of the player start area (violators: %s)" % str(ring_leaks), state)

    # 3. After advancing the era, the territory assigned to the player does not
    #    contain "dead zones": an assigned hex cannot belong to a town at the
    #    same time.
    main_map.advance_to_next_era()
    await process_frame
    var dead_zones: Array = []
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_influence", false)) \
                    and bool(tile.get("in_town_influence", false)):
                dead_zones.append([row, col])
    check(dead_zones.is_empty(),
        "after advancing the era the player's Ring of Influence must not keep town hexes (dead zones: %s)" % str(dead_zones), state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


func _in_main_map_start_area(main_map, row: int, col: int) -> bool:
    return row >= main_map.start_region_start_row \
        and row <= main_map.start_region_end_row \
        and col >= main_map.start_region_start_col \
        and col <= main_map.start_region_end_col


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: " + msg)
        state["failed"] = true

