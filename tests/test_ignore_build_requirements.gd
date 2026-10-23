# Headless test of the debug toggle "Ignore build requirements"
# (CityData.ignore_build_requirements) on ALL actions that spend time or
# resources:
#   godot --headless --path . --script res://tests/test_ignore_build_requirements.gd
#
# The flag covers city buildings and improvements on the map, as well as
# scouting, claiming land and special actions (foraging, draining
# marsh), which all obey the toggle.
#
# Checks (live MainMap scene, new game, each on its own hex):
#   1. SCOUTING. Flag off: the expedition starts, exactly the chunk price
#      is deducted from the treasury. Flag on: the chunk is scouted IN THE SAME
#      call (is_scouting == false, all hexes is_explored), the treasury is untouched.
#   2. CLAIMING. Flag off: coins are deducted, the claiming construction goes
#      into the pool. Flag on: the chunk joins the Ring of Influence immediately,
#      the treasury is untouched, no active claiming constructions remain.
#   3. FORAGING (forage). Flag off: the action is queued as a
#      construction, the resource stays on the hex. Flag on: the resource is gathered
#      and removed from the hex in the same call, the product arrives at the storage.
#   4. DRAINING MARSH (terrain). Flag off: the terrain does not change until
#      the construction finishes. Flag on: the marsh becomes plain immediately.
#   5. CONSTRUCTION LIMIT GATE. When the limit is exhausted, the special action
#      button is disabled; with the flag on it is active, because an instant
#      action does not enter the queue.
#   6. CONSTRUCTION STARTED BEFORE THE FLAG. Enabling the flag does not leave
#      already started constructions hanging: _process brings them to 100%,
#      including claiming land.
extends SceneTree

# Hang watchdog: without it, a broken _run() coroutine looks from the outside
# like eternal silence. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const FORAGE_ACTION := "forage_resource"
const DRAIN_ACTION := "drain_water"
const BUILD_LIMIT_TOOLTIP := "No work available: construction limit (number of citizens) reached"
const WILD_FOOD := "wild_food"
const FORAGED_FOOD := "foraged_food"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken as scene tree nodes: in --script mode the names GameData
    # and CityData are not yet available at the compilation stage of this file.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")
    var gdata = get_root().get_node("GameData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var em = main_map.expansion_manager
    var bm = main_map.build_manager
    var cp = main_map.control_panel

    check(main_map.tile_data.size() == main_map.map_rows,
            "map is not initialized (tile_data is empty)", state)
    check(not city.ignore_build_requirements,
            "the toggle must be off by default", state)

    if WATCHDOG.wants_case("scouting"):
        _test_scouting(main_map, em, city, state)
    if WATCHDOG.wants_case("expansion"):
        _test_expansion(main_map, em, bm, city, state)
    if WATCHDOG.wants_case("forage"):
        _test_forage(main_map, bm, city, state)
    if WATCHDOG.wants_case("drain"):
        _test_drain(main_map, bm, city, state)
    if WATCHDOG.wants_case("build_limit_gate"):
        _test_build_limit_gate(main_map, bm, cp, city, gdata, state)
    if WATCHDOG.wants_case("inflight_expansion"):
        _test_inflight_expansion(main_map, em, bm, city, state)

    _finish(main_map, state)

# --- 1. Scouting ---------------------------------------------------------

func _test_scouting(main_map, em, city, state: Dictionary) -> void:
    print("--- Scouting ---")
    city.ignore_build_requirements = false

    var hex = _find_region_hex_near_known(main_map)
    check(hex != null, "no unexplored Region hex found at the Ring border", state)
    if hex == null:
        return
    var chunk: Array = em.get_chunk_hexes(hex.row, hex.col)
    check(chunk.size() > 0, "the scouting chunk at the Ring border must not be empty", state)

    # Flag OFF: normal behavior — money is spent, the expedition proceeds.
    var cost: int = em.get_chunk_scout_cost(chunk)
    city.add_treasury(cost)
    var before: int = city.treasury
    main_map.start_scouting(chunk)
    check(main_map.is_scouting, "without the flag scouting must start and run over time", state)
    check(city.treasury == before - cost,
            "without the flag scouting must deduct exactly the chunk price (%d): was %d, now %d"
                    % [cost, before, city.treasury], state)
    # Bring the expedition to completion manually to prepare the map further.
    _force_finish_scouting(main_map, chunk)

    # Flag ON: scouting is instant and free.
    city.ignore_build_requirements = true
    var hex2 = _find_region_hex_near_known(main_map)
    check(hex2 != null, "after the first scouting the next Region hex must be found", state)
    if hex2 == null:
        return
    var chunk2: Array = em.get_chunk_hexes(hex2.row, hex2.col)
    check(chunk2.size() > 0, "the second scouting chunk must not be empty", state)
    var before2: int = city.treasury
    main_map.start_scouting(chunk2)
    check(not main_map.is_scouting,
            "with the flag scouting must not run over time (is_scouting)", state)
    check(main_map.scouting_chunk.is_empty(),
            "with the flag scouting must close the chunk in the same call", state)
    check(_chunk_all_explored(main_map, chunk2),
            "with the flag all chunk hexes must become explored immediately", state)
    check(city.treasury == before2,
            "with the flag scouting must be free: was %d, now %d"
                    % [before2, city.treasury], state)
    city.ignore_build_requirements = false

# --- 2. Claiming land ---------------------------------------------

func _test_expansion(main_map, em, bm, city, state: Dictionary) -> void:
    print("--- Claiming land ---")
    city.ignore_build_requirements = false

    var chunk: Array = _open_buy_chunk(main_map, em)
    check(chunk.size() > 0, "no hex with a non-empty purchase chunk found for claiming", state)
    if chunk.is_empty():
        return
    var work_cost: int = em.get_chunk_cost(chunk)
    check(work_cost > 0, "the claiming work of the chunk must be greater than zero", state)
    var money_cost: int = em.get_chunk_money_cost(chunk)

    city.add_treasury(money_cost)
    var before: int = city.treasury
    var ok: bool = em.handle_action(chunk, money_cost, work_cost)
    check(ok, "without the flag claiming must start", state)
    check(city.treasury == before - money_cost,
            "without the flag claiming must deduct exactly %d coins: was %d, now %d"
                    % [money_cost, before, city.treasury], state)
    check(bm.active_expansion_builds.size() == 1,
            "without the flag claiming must wait for work in the construction pool", state)
    # Finish manually via the same path as when work accumulates.
    em.on_expansion_build_completed(chunk)
    check(_chunk_all_in_influence(main_map, chunk),
            "claiming must attach the chunk to the Ring of Influence", state)
    # build_manager itself removes the record from active_expansion_builds in its
    # _process. The test runs without await between steps, no frames pass, and the
    # leftover would disturb the construction limit of the following checks — we clear the pool explicitly.
    _reset_build_pool(bm)

    # Flag ON: claiming is instant and free.
    city.ignore_build_requirements = true
    var chunk2: Array = _open_buy_chunk(main_map, em)
    check(chunk2.size() > 0, "no hex with a purchase chunk found for the second claiming", state)
    if chunk2.is_empty():
        return
    var before2: int = city.treasury
    var ok2: bool = em.handle_action(chunk2,
            em.get_chunk_money_cost(chunk2), em.get_chunk_cost(chunk2))
    check(ok2, "with the flag claiming must start", state)
    check(_chunk_all_in_influence(main_map, chunk2),
            "with the flag the chunk must join the Ring of Influence immediately", state)
    check(bm.active_expansion_builds.is_empty(),
            "with the flag claiming must not remain in the construction pool", state)
    check(city.treasury == before2,
            "with the flag claiming must be free: was %d, now %d"
                    % [before2, city.treasury], state)
    city.ignore_build_requirements = false

# --- 3. Foraging (special action forage) -----------------------------

func _test_forage(main_map, bm, city, state: Dictionary) -> void:
    print("--- Foraging ---")
    city.ignore_build_requirements = false

    var hex = _find_empty_influence_hex(main_map)
    check(hex != null, "no empty Ring of Influence hex found for foraging", state)
    if hex == null:
        return
    var tile = main_map.tile_data[hex.row][hex.col]
    tile["resource"] = WILD_FOOD
    tile["quality"] = "common"

    var started: bool = bm.start_build(hex.row, hex.col, FORAGE_ACTION)
    check(started, "without the flag foraging must start", state)
    check(bm.is_building(hex.row, hex.col),
            "without the flag foraging must wait for work in the construction pool", state)
    check(str(tile.get("resource", "")) == WILD_FOOD,
            "without the flag the resource must not disappear before the construction finishes", state)
    bm.cancel_build(hex.row, hex.col)
    tile["resource"] = WILD_FOOD

    city.ignore_build_requirements = true
    var hex2 = _find_empty_influence_hex(main_map)
    check(hex2 != null, "no second empty Ring of Influence hex found", state)
    if hex2 == null:
        return
    var tile2 = main_map.tile_data[hex2.row][hex2.col]
    tile2["resource"] = WILD_FOOD
    tile2["quality"] = "common"
    var food_before: int = _storage_amount(city, FORAGED_FOOD)

    var started2: bool = bm.start_build(hex2.row, hex2.col, FORAGE_ACTION)
    check(started2, "with the flag foraging must start", state)
    check(not bm.is_building(hex2.row, hex2.col),
            "with the flag foraging must not enter the construction queue", state)
    check(tile2.get("resource", null) == null,
            "with the flag the one-time resource must disappear from the hex immediately", state)
    check(_storage_amount(city, FORAGED_FOOD) > food_before,
            "with the flag the foraged food must arrive at the storage immediately (%d -> %d)"
                    % [food_before, _storage_amount(city, FORAGED_FOOD)], state)
    city.ignore_build_requirements = false

# --- 4. Draining marsh (special action terrain) ----------------------------

func _test_drain(main_map, bm, city, state: Dictionary) -> void:
    print("--- Draining marsh ---")
    city.ignore_build_requirements = false

    var hex = _find_empty_influence_hex(main_map)
    check(hex != null, "no empty Ring of Influence hex found for draining", state)
    if hex == null:
        return
    var tile = main_map.tile_data[hex.row][hex.col]
    tile["terrain"] = "swamp"
    tile["cover"] = "none"
    tile["resource"] = null
    tile["improvement"] = null

    var started: bool = bm.start_build(hex.row, hex.col, DRAIN_ACTION)
    check(started, "without the flag draining must start", state)
    check(bm.is_building(hex.row, hex.col),
            "without the flag draining must wait for work in the construction pool", state)
    check(str(tile.get("terrain", "")) == "swamp",
            "without the flag the terrain must not change before the construction finishes", state)
    bm.cancel_build(hex.row, hex.col)

    city.ignore_build_requirements = true
    var hex2 = _find_empty_influence_hex(main_map)
    check(hex2 != null, "no second empty Ring of Influence hex found", state)
    if hex2 == null:
        return
    var tile2 = main_map.tile_data[hex2.row][hex2.col]
    tile2["terrain"] = "swamp"
    tile2["cover"] = "none"
    tile2["resource"] = null
    tile2["improvement"] = null

    var started2: bool = bm.start_build(hex2.row, hex2.col, DRAIN_ACTION)
    check(started2, "with the flag draining must start", state)
    check(not bm.is_building(hex2.row, hex2.col),
            "with the flag draining must not enter the construction queue", state)
    # The drained hex becomes the plain of its climate belt: a tundra, a steppe, a savanna … —
    # the family is what matters here, not the variety.
    check(get_root().get_node("GameData").terrain_family(str(tile2.get("terrain", ""))) == "plain",
            "with the flag the marsh must become a plain immediately (got: \"%s\")"
                    % str(tile2.get("terrain", "")), state)
    city.ignore_build_requirements = false

# --- 5. Gate of the simultaneous construction limit ---------------------------------

func _test_build_limit_gate(main_map, bm, cp, city, gdata, state: Dictionary) -> void:
    print("--- Construction limit gate for special actions ---")
    var sa: Dictionary = gdata.special_actions.get(FORAGE_ACTION, {})
    check(not sa.is_empty(), "special action \"%s\" must be in the data" % FORAGE_ACTION, state)
    if sa.is_empty():
        return

    var hex = _find_empty_influence_hex(main_map)
    check(hex != null, "no hex found for checking the limit gate", state)
    if hex == null:
        return
    var tile = main_map.tile_data[hex.row][hex.col]
    tile["resource"] = WILD_FOOD
    tile["quality"] = "common"

    # Occupy the slot of a construction in progress: population = 1, so the limit
    # is one construction. The construction stays ACTIVE during both checks — the
    # gate triggers exactly when the limit is exhausted, not when the construction is cancelled.
    _reset_build_pool(bm)
    city.total_population = 1
    var queued: bool = bm.start_build(hex.row, hex.col, FORAGE_ACTION)
    check(queued, "for the limit gate check the construction must start", state)
    check(bm.get_total_active_builds() >= city.total_population,
            "the construction limit must be exhausted (in the pool %d, limit %d)"
                    % [bm.get_total_active_builds(), city.total_population], state)

    city.ignore_build_requirements = false
    var actions_off := []
    cp._append_special_action(actions_off, FORAGE_ACTION, sa)
    var off_action = _find_action(actions_off, FORAGE_ACTION)
    check(off_action != null, "without the flag the special action button must be assembled", state)
    if off_action != null:
        check(not off_action.get("enabled", true),
                "without the flag the exhausted construction limit must block the special action", state)
        check(str(off_action.get("tooltip", "")) == BUILD_LIMIT_TOOLTIP,
                "the tooltip must explain the limit blocking (got: \"%s\")"
                        % str(off_action.get("tooltip", "")), state)

    city.ignore_build_requirements = true
    var actions_on := []
    cp._append_special_action(actions_on, FORAGE_ACTION, sa)
    var on_action = _find_action(actions_on, FORAGE_ACTION)
    check(on_action != null, "with the flag the special action button must be assembled", state)
    if on_action != null:
        check(on_action.get("enabled", false),
                "with the flag the construction limit must not block the instant special action", state)
        check(str(on_action.get("tooltip", "")) != BUILD_LIMIT_TOOLTIP,
                "with the flag the construction limit tooltip must not be shown", state)

    city.ignore_build_requirements = false
    city.total_population = 1
    tile["resource"] = null
    _reset_build_pool(bm)

# --- 6. Construction started before the flag is enabled ------------------------------

func _test_inflight_expansion(main_map, em, bm, city, state: Dictionary) -> void:
    print("--- Construction started before the flag is enabled ---")
    city.ignore_build_requirements = false

    var chunk: Array = _open_buy_chunk(main_map, em)
    check(chunk.size() > 0, "no hex with a purchase chunk found for the check", state)
    if chunk.is_empty():
        return
    var work_cost: int = em.get_chunk_cost(chunk)
    check(work_cost > 0, "the claiming work must be greater than zero", state)
    city.add_treasury(em.get_chunk_money_cost(chunk))
    var ok: bool = em.handle_action(chunk, em.get_chunk_money_cost(chunk), work_cost)
    check(ok, "claiming must start before the flag is enabled", state)
    check(bm.active_expansion_builds.size() == 1,
            "claiming must wait in the construction pool", state)
    check(not _chunk_all_in_influence(main_map, chunk),
            "before the flag is enabled the chunk must not be claimed", state)

    # Enable the flag mid-flight: a started construction must finish in the same
    # frame.
    city.ignore_build_requirements = true
    bm._process(0.05)
    check(bm.active_expansion_builds.is_empty(),
            "with the flag the already started claiming must finish immediately", state)
    check(_chunk_all_in_influence(main_map, chunk),
            "with the flag the already started claiming must attach the chunk", state)
    city.ignore_build_requirements = false

# --- Helpers ------------------------------------------------------------

# The first unexplored Region hex that has a known neighbor.
func _find_region_hex_near_known(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
                if main_map.is_hex_known(n.row, n.col):
                    return {"row": row, "col": col}
    return null

# The first Ring of Influence hex on which nothing stands and nothing
# grows: suitable for both foraging and draining.
func _find_empty_influence_hex(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            if row == main_map.city_row and col == main_map.city_col:
                continue
            var tile = main_map.tile_data[row][col]
            if not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("decorative", false)):
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            if tile.get("resource", null) != null or tile.get("improvement", null) != null:
                continue
            return {"row": row, "col": col}
    return null

func _chunk_all_explored(main_map, chunk: Array) -> bool:
    for hex in chunk:
        if not bool(main_map.tile_data[hex.row][hex.col].get("is_explored", false)):
            return false
    return true

func _chunk_all_in_influence(main_map, chunk: Array) -> bool:
    for hex in chunk:
        if not bool(main_map.tile_data[hex.row][hex.col].get("in_influence", false)):
            return false
    return true

func _mark_explored(main_map, chunk: Array) -> void:
    for hex in chunk:
        main_map.tile_data[hex.row][hex.col]["is_explored"] = true

# Fully clears the construction pool. Needed between checks: the test runs without await,
# so build_manager._process (which removes finished records) does not have time
# to run, and the construction leftover would shift the limit in the next check.
func _reset_build_pool(bm) -> void:
    bm.active_builds.clear()
    bm.active_building_builds.clear()
    bm.active_expansion_builds.clear()
    bm._recount_active_builds()

# Opens a hex and its scouting chunk, then returns the PURCHASE CHUNK.
# The order matters: get_chunk_hexes for an unexplored hex builds the scouting
# BFS (it includes both the town's influence ring and already claimed hexes),
# while for an explored one it builds the purchase BFS. handle_action refuses a chunk that
# crosses the town's ring, so rebuilding the chunk after scouting
# is mandatory — exactly what the control panel does in the game.
func _open_and_get_buy_chunk(main_map, em, row: int, col: int) -> Array:
    var scout_chunk: Array = em.get_chunk_hexes(row, col)
    _mark_explored(main_map, scout_chunk)
    return em.get_chunk_hexes(row, col)

# Finds a NON-EMPTY purchase chunk: iterates Region hexes near known
# territory and takes the first whose chunk is actually assembled. A single
# `_find_region_hex_near_known` is not enough for this purpose — a hex at the
# Ring border may fall inside the town's influence ring, and then the purchase BFS is empty.
# Candidates whose chunk was not assembled simply stay explored: the map
# does not break from this, the next check looks for its own chunk itself.
func _open_buy_chunk(main_map, em) -> Array:
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            if not _hex_has_influence_neighbor(main_map, row, col):
                continue
            var chunk: Array = _open_and_get_buy_chunk(main_map, em, row, col)
            if not chunk.is_empty() and em.get_chunk_cost(chunk) > 0:
                return chunk
    return []

# Whether the hex has a neighbor in the Ring of Influence — the condition for buying a chunk (see
# control_panel._collect_region_actions, has_neighbor).
func _hex_has_influence_neighbor(main_map, row: int, col: int) -> bool:
    for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
        if bool(main_map.tile_data[n.row][n.col].get("in_influence", false)):
            return true
    return false

# Brings scouting to completion manually: in a headless test one cannot wait real
# seconds of game time.
func _force_finish_scouting(main_map, chunk: Array) -> void:
    main_map.scouting_chunk = chunk
    main_map._complete_scouting()

func _storage_amount(city, product_id: String) -> int:
    return int(city.city_storage.get(product_id, 0))

func _find_action(actions: Array, action_id: String):
    for action in actions:
        if action.get("action_id", "") == action_id:
            return action
    return null

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("IGNORE BUILD REQUIREMENTS TEST FAILED")
        quit(1)
    else:
        print("IGNORE BUILD REQUIREMENTS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
