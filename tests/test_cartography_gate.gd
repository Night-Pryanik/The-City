# Headless test for the rule "Scouting outside the Region — only after Cartography":
#   godot --headless --path . --script res://tests/test_cartography_gate.gd
#
# The test boots the REAL MainMap scene (a new game on the real map) and
# checks the rule against live data:
#
#   1. BEFORE Cartography:
#      - the chunk of an unexplored hex in the Region is assembled and stays inside the Region;
#      - the chunk of a hex in the fog of war (outside the Region) is EMPTY — so the highlight
#        and the "Send scouts" button do not appear there;
#      - main_map.is_hex_interactive() forbids hover/click outside the Region;
#      - start_scouting() does not start scouting a chunk in the fog (a safeguard at the
#        public entry point), but does start it in the Region.
#
#   2. AFTER researching Cartography:
#      - the chunk in the fog of war is assembled and includes the starting hex;
#      - is_hex_interactive() allows interaction;
#      - start_scouting() starts scouting.
#
# Additional rule (checked in full in tools/test_scouting_frontier.gd):
# scouting can only be sent to a chunk adjacent to known territory
# (main_map.is_chunk_adjacent_to_known). Therefore here both the Region hex and the
# fog hex are taken at the border of the known world: before checking scouting in the fog
# the neighboring Region hex is marked as explored.
extends SceneTree

# Hang watchdog: without it, an aborted _run() coroutine looks from the outside like eternal
# silence. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are fetched through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at this file's compile time.
    # new_game() also loads all the data (GameData.load_all_data) and
    # resets the city state (CityData.setup) — Cartography is not researched.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    check(main_map.tile_data.size() == main_map.map_rows,
            "the map is not initialized (tile_data is empty)", state)
    check(not city.is_tech_unlocked("cartography"),
            "Cartography must not be researched at the start of a new game", state)
    check(not main_map.is_cartography_researched(),
            "is_cartography_researched() must be false before the technology is researched", state)

    # --- Find unexplored hexes: one in the Region at the border of the Ring of Influence,
    #     one in the fog of war at the border of the Region ---
    # The Region hex must be adjacent to known territory (otherwise its chunk is not
    # suitable for scouting — see main_map.is_chunk_adjacent_to_known and
    # tools/test_scouting_frontier.gd). The fog hex needs a "bridge" — a Region
    # hex that itself touches the fog: with region_width = 2, the hexes at the Ring
    # of Influence do not touch the fog. In the "AFTER Cartography" section this bridge
    # is marked as explored, and scouting into the adjacent fog becomes available.
    var region_hex = null
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if not main_map.is_valid_hex(row, col):
                continue
            if not _hex_has_known_neighbor(main_map, row, col):
                continue
            region_hex = {"row": row, "col": col}
            break
        if region_hex != null:
            break
    var bridge_hex = _find_region_hex_near_fog(main_map)
    var fog_hex = null
    if bridge_hex != null:
        fog_hex = _find_fog_neighbor(main_map, bridge_hex.row, bridge_hex.col)
    check(region_hex != null, "no unexplored Region hex found at the border of the Ring of Influence", state)
    check(bridge_hex != null, "no Region hex bordering the fog of war found", state)
    check(fog_hex != null, "no unexplored fog-of-war hex found at the border of the Region", state)
    if region_hex == null or bridge_hex == null or fog_hex == null:
        _finish(main_map, state)
        return

    # ======================= BEFORE Cartography =======================
    check(main_map.is_hex_interactive(region_hex.row, region_hex.col),
            "a hex in the Region must be available for hover/click", state)
    check(not main_map.is_hex_interactive(fog_hex.row, fog_hex.col),
            "without Cartography a hex in the fog of war must NOT be available", state)

    var region_chunk = main_map.expansion_manager.get_chunk_hexes(region_hex.row, region_hex.col)
    check(region_chunk.size() > 0, "the scouting chunk in the Region must not be empty", state)
    var region_chunk_inside = true
    for hex in region_chunk:
        if not main_map.is_valid_hex(hex.row, hex.col):
            region_chunk_inside = false
    check(region_chunk_inside, "without Cartography the scouting chunk must lie inside the Region", state)

    var fog_chunk = main_map.expansion_manager.get_chunk_hexes(fog_hex.row, fog_hex.col)
    check(fog_chunk.is_empty(),
            "without Cartography the chunk for a hex in the fog of war must be empty (got %d)" % fog_chunk.size(),
            state)

    # Safeguard at the public entry point main_map.start_scouting():
    # scouting a chunk in the fog without Cartography must not start at all.
    main_map.start_scouting([fog_hex])
    check(not main_map.is_scouting,
            "start_scouting() must not start for a chunk in the fog without Cartography", state)
    # But in the Region scouting does start. Payment is made with coins from the treasury, so
    # we top up the treasury in advance by the chunk's price: this test checks the gate on
    # Cartography, not the abundance of coins (the economy is checked by
    # tools/test_territory_costs.gd).
    city.add_treasury(main_map.expansion_manager.get_chunk_scout_cost(region_chunk))
    main_map.start_scouting(region_chunk)
    check(main_map.is_scouting,
            "start_scouting() must start for a chunk in the Region", state)
    main_map.is_scouting = false
    main_map.scouting_chunk = []

    # ==================== AFTER Cartography ====================
    city.unlocked_technologies.append("cartography")
    check(main_map.is_cartography_researched(),
            "is_cartography_researched() must become true after the technology is researched", state)
    check(main_map.is_hex_interactive(fog_hex.row, fog_hex.col),
            "with Cartography a hex in the fog of war must become available", state)

    var fog_chunk_after = main_map.expansion_manager.get_chunk_hexes(fog_hex.row, fog_hex.col)
    check(fog_chunk_after.size() > 0,
            "with Cartography the scouting chunk in the fog of war must not be empty", state)
    var contains_start = false
    for hex in fog_chunk_after:
        if hex.row == fog_hex.row and hex.col == fog_hex.col:
            contains_start = true
    check(contains_start, "the scouting chunk must include the starting hex", state)

    # Scouting is available only into a chunk adjacent to known territory
    # (the Ring of Influence or explored hexes) — see
    # main_map.is_chunk_adjacent_to_known. The chunk in the fog itself is assembled in any
    # case (highlight + disabled button with a reason), but scouting can be
    # started only at the border of the known world. Therefore: we find a Region
    # hex bordering the fog, mark it as explored (a "bridge" into the fog) and
    # check that scouting starts on the chunk of the neighboring fog hex.
    # A "bridge" into the fog: we mark as explored the Region hex touching the fog —
    # the border of the known world reaches fog_hex, and scouting there is allowed
    # (see main_map.is_chunk_adjacent_to_known). Without such a bridge the fog chunk
    # is detached from the known world, and start_scouting() must refuse
    # (checked in tools/test_scouting_frontier.gd).
    main_map.tile_data[bridge_hex.row][bridge_hex.col]["is_explored"] = true
    check(main_map.is_chunk_adjacent_to_known(fog_chunk_after),
            "after the bridge is explored the fog chunk must be adjacent to known territory", state)

    # Payment is made with coins from the treasury: we top it up by the price of the chunk in the fog.
    city.add_treasury(main_map.expansion_manager.get_chunk_scout_cost(fog_chunk_after))
    main_map.start_scouting(fog_chunk_after)
    check(main_map.is_scouting,
            "with Cartography start_scouting() must also start for a chunk in the fog", state)
    main_map.is_scouting = false
    main_map.scouting_chunk = []

    _finish(main_map, state)

func _hex_has_known_neighbor(main_map, row: int, col: int) -> bool:
    # Territory known to the player: the Ring of Influence (in_influence) or
    # an explored hex (is_explored) — see main_map.is_hex_known.
    for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
        if main_map.is_hex_known(n.row, n.col):
            return true
    return false

# The first unexplored Region hex that has a neighbor BEYOND the
# Region (the fog of war): through it the border of the known world reaches
# the fog. Important: with region_width = 2, the hexes adjacent to the Ring of Influence
# do not touch the fog themselves — the "bridge" into the fog is searched for separately.
func _find_region_hex_near_fog(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if _find_fog_neighbor(main_map, row, col) != null:
                return {"row": row, "col": col}
    return null

# The first neighbor of hex (row, col) lying in the fog of war (outside the Region).
func _find_fog_neighbor(main_map, row: int, col: int):
    for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
        if main_map.is_valid_hex(n.row, n.col):
            continue
        return {"row": n.row, "col": n.col}
    return null

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("CARTOGRAPHY GATE TEST FAILED")
        quit(1)
    else:
        print("CARTOGRAPHY GATE TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
