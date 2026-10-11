# Headless test for the rule "A scouting chunk must border known territory":
#   godot --headless --path . --script res://tests/test_scouting_frontier.gd
#
# The test boots the REAL MainMap scene (a new game on the real map) and
# verifies the rule against live data:
#
#   1. Positive case: an unexplored Region hex at the border of the Ring of
#      Influence → the chunk is non-empty, borders known territory, the
#      "Send scouts" button is enabled, start_scouting() spends coins and
#      starts scouting.
#   2. Invariant across the whole map (before Cartography — over the Region,
#      after — also over the fog of war): the scouting button's enabled state
#      EQUALS whether the chunk borders known territory, and the tooltip of an
#      unavailable chunk explains the reason.
#   3. Negative case: a chunk in the fog of war, detached from the known
#      world (there are thousands of them on the map) → the button is disabled
#      with a reason, start_scouting() does not start and does NOT spend coins.
#   4. Frontier dynamics: mark a neighbouring hex as explored — the same
#      chunk becomes available and scouting starts (the border "creeps").
#   5. Public entry point safety net: an empty chunk does not start scouting
#      and does not spend coins.
#
# Known territory = the Ring of Influence (in_influence) OR explored hexes
# (is_explored) — see main_map.is_hex_known / is_chunk_adjacent_to_known.
extends SceneTree

# Hang watchdog: without it, an interrupted _run() coroutine looks like eternal
# silence from the outside. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const FRONTIER_TOOLTIP := "The area does not border explored territory"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are fetched through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at this file's compile time.
    # new_game() loads the game data and resets the city state —
    # Cartography is not researched at the start.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var em = main_map.expansion_manager
    var cp = main_map.control_panel

    check(main_map.tile_data.size() == main_map.map_rows,
            "the map is not initialized (tile_data is empty)", state)
    check(not main_map.is_cartography_researched(),
            "Cartography must not be researched at the start of a new game", state)
    check(not main_map.is_chunk_adjacent_to_known([]),
            "an empty chunk cannot border known territory", state)

    # ============ 1. Scouting at the border of the Ring of Influence ============
    var front_hex = _find_region_hex_near_known(main_map)
    check(front_hex != null, "no unexplored Region hex found at the border of the Ring", state)
    if front_hex == null:
        _finish(main_map, state)
        return

    var front_chunk: Array = em.get_chunk_hexes(front_hex.row, front_hex.col)
    check(front_chunk.size() > 0, "the scouting chunk at the border of the Ring must not be empty", state)
    check(main_map.is_chunk_adjacent_to_known(front_chunk),
            "the chunk at the border of the Ring must border known territory", state)

    var front_action = _find_action(cp._collect_actions(front_hex.row, front_hex.col,
            main_map.tile_data[front_hex.row][front_hex.col]), "scout_chunk")
    check(front_action != null, "the hex at the border of the Ring must have a scouting button", state)
    if front_action != null:
        check(front_action.get("enabled", false),
                "the scouting button at the border of the Ring must be enabled", state)

    city.add_treasury(em.get_chunk_scout_cost(front_chunk))
    var front_treasury_before: int = city.treasury
    var front_cost: int = em.get_chunk_scout_cost(front_chunk)
    main_map.start_scouting(front_chunk)
    check(main_map.is_scouting, "scouting of the chunk at the border of the Ring must start", state)
    check(city.treasury == front_treasury_before - front_cost,
            "scouting must charge exactly the chunk cost (%d): was %d, now %d"
                    % [front_cost, front_treasury_before, city.treasury], state)
    # Simulate the completion of the expedition: the chunk's hexes become
    # explored, the border of the known world moves forward.
    _mark_explored(main_map, front_chunk)
    main_map.is_scouting = false
    main_map.scouting_chunk = []

    # ============ 2. Invariant across the whole map BEFORE Cartography ============
    check(not main_map.is_scouting, "scouting must be finished before checking the invariant", state)
    var stats_before: Dictionary = _check_frontier_invariant(main_map, state)
    check(int(stats_before["available"]) > 0,
            "before Cartography there must be at least one available scouting chunk in the Region", state)
    print("FRONTIER STATS (before Cartography): ", stats_before)

    # ============ 3. Negative case: a detached chunk in the fog ============
    city.unlocked_technologies.append("cartography")
    check(main_map.is_cartography_researched(),
            "is_cartography_researched() must become true after researching the technology", state)

    var stats_after: Dictionary = _check_frontier_invariant(main_map, state)
    check(int(stats_after["detached"]) > 0,
            "there must be chunks detached from the known world in the fog of war", state)
    print("FRONTIER STATS (with Cartography): ", stats_after)

    var fog_hex = _find_detached_fog_hex(main_map, em)
    check(fog_hex != null, "no fog-of-war hex detached from the known world found", state)
    if fog_hex == null:
        _finish(main_map, state)
        return

    var fog_chunk: Array = em.get_chunk_hexes(fog_hex.row, fog_hex.col)
    check(fog_chunk.size() > 0,
            "the chunk in the fog of war must be gathered — the highlight stays visible", state)
    check(not main_map.is_chunk_adjacent_to_known(fog_chunk),
            "a detached chunk must not border known territory", state)

    var fog_action = _find_action(cp._collect_actions(fog_hex.row, fog_hex.col,
            main_map.tile_data[fog_hex.row][fog_hex.col]), "scout_chunk")
    check(fog_action != null, "an unavailable chunk must also have a scouting button (with a reason)", state)
    if fog_action != null:
        check(not fog_action.get("enabled", true),
                "the scouting button of a detached chunk must be disabled", state)
        check(str(fog_action.get("tooltip", "")) == FRONTIER_TOOLTIP,
                "the tooltip of a detached chunk must explain the reason (got: \"%s\")"
                        % str(fog_action.get("tooltip", "")), state)

    var fog_treasury_saved: int = city.treasury
    main_map.start_scouting(fog_chunk)
    check(not main_map.is_scouting,
            "start_scouting() must not start for a detached chunk", state)
    check(city.treasury == fog_treasury_saved,
            "coins must NOT be charged on refusal: was %d, now %d"
                    % [fog_treasury_saved, city.treasury], state)

    # ============ 4. Dynamics of the border of the known world ============
    var frontier_hex = _first_neighbor(main_map, fog_hex.row, fog_hex.col)
    check(frontier_hex != null, "a fog hex must have at least one neighbour on the map", state)
    if frontier_hex != null:
        # Mark a neighbouring hex as explored: the border of the known world
        # reaches the chunk, and it must become available without restarting
        # anything.
        main_map.tile_data[frontier_hex.row][frontier_hex.col]["is_explored"] = true
        check(main_map.is_chunk_adjacent_to_known(fog_chunk),
                "after exploring a neighbouring hex the chunk must become available", state)
        var fog_action_after = _find_action(cp._collect_actions(fog_hex.row, fog_hex.col,
                main_map.tile_data[fog_hex.row][fog_hex.col]), "scout_chunk")
        check(fog_action_after != null, "the scouting button must remain on an available chunk", state)
        if fog_action_after != null:
            check(fog_action_after.get("enabled", false),
                    "after an explored neighbour appears the scouting button must become enabled", state)

        var fog_cost: int = em.get_chunk_scout_cost(fog_chunk)
        city.add_treasury(fog_cost)
        var fog_treasury_before: int = city.treasury
        main_map.start_scouting(fog_chunk)
        check(main_map.is_scouting,
                "after an explored neighbour appears scouting must start", state)
        check(city.treasury == fog_treasury_before - fog_cost,
                "scouting a frontier chunk must charge exactly the chunk cost (%d)" % fog_cost, state)
        main_map.is_scouting = false
        main_map.scouting_chunk = []

    # ============ 5. Safety net: an empty chunk ============
    var empty_treasury_saved: int = city.treasury
    main_map.start_scouting([])
    check(not main_map.is_scouting, "an empty chunk does not start scouting", state)
    check(city.treasury == empty_treasury_saved, "an empty chunk does not spend coins", state)

    _finish(main_map, state)

# Verifies the rule's invariant across the whole map: for every unexplored hex
# the scouting button's enabled state equals whether its chunk borders known
# territory, and an unavailable chunk explains the reason in the tooltip.
# Returns counters for diagnostics (how many chunks are available / detached /
# not gathered at all).
func _check_frontier_invariant(main_map, state: Dictionary) -> Dictionary:
    var cp = main_map.control_panel
    var em = main_map.expansion_manager
    var available := 0
    var detached := 0
    var empty_chunks := 0
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            var chunk: Array = em.get_chunk_hexes(row, col)
            if chunk.is_empty():
                empty_chunks += 1
                continue
            var adjacent: bool = main_map.is_chunk_adjacent_to_known(chunk)
            if adjacent:
                available += 1
            else:
                detached += 1
            var action = _find_action(cp._collect_actions(row, col, tile), "scout_chunk")
            if action == null:
                continue
            check(bool(action.get("enabled", false)) == adjacent,
                    "(%d,%d): the scouting button's enabled state must match whether the chunk borders (borders=%s)"
                            % [row, col, str(adjacent)], state)
            if not adjacent:
                check(str(action.get("tooltip", "")) == FRONTIER_TOOLTIP,
                        "(%d,%d): the tooltip of an unavailable chunk must explain the reason (got: \"%s\")"
                                % [row, col, str(action.get("tooltip", ""))], state)
    return {"available": available, "detached": detached, "empty_chunks": empty_chunks}

# The first unexplored Region hex that has a known neighbour
# (the border of the known world passes nearby).
func _find_region_hex_near_known(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if _hex_has_known_neighbor(main_map, row, col):
                return {"row": row, "col": col}
    return null

# The first fog-of-war hex whose chunk does not border known territory.
func _find_detached_fog_hex(main_map, em):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            var chunk: Array = em.get_chunk_hexes(row, col)
            if chunk.is_empty():
                continue
            if not main_map.is_chunk_adjacent_to_known(chunk):
                return {"row": row, "col": col}
    return null

func _hex_has_known_neighbor(main_map, row: int, col: int) -> bool:
    for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
        if main_map.is_hex_known(n.row, n.col):
            return true
    return false

func _first_neighbor(main_map, row: int, col: int):
    var neighbors: Array = HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols)
    if neighbors.is_empty():
        return null
    return neighbors[0]

func _mark_explored(main_map, chunk: Array) -> void:
    for hex in chunk:
        main_map.tile_data[hex.row][hex.col]["is_explored"] = true

func _find_action(actions: Array, type: String):
    for action in actions:
        if action.get("type", "") == type:
            return action
    return null

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("SCOUTING FRONTIER TEST FAILED")
        quit(1)
    else:
        print("SCOUTING FRONTIER TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
