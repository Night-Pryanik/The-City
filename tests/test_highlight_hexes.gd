# Headless test of hex hover/selection highlighting (map_renderer, PHASES 2.5 and 3.5):
#   godot --headless --path . --script res://tests/test_highlight_hexes.gd
#
# The renderer highlights the set of hexes returned by
# expansion_manager.get_highlight_hexes(row, col):
#   - a hex in the Influence Ring → only itself;
#   - outside the Ring → the whole scouting/purchase chunk (get_chunk_hexes);
#   - if there is no chunk, and the hex is EXPLORED (explored area outside the Region) →
#     a highlight chunk of up to 5 hexes, built by BFS outward from the hex under the cursor
#     (_get_explored_chunk_hexes);
#   - if there is no chunk and the hex is in a foreign town's influence ring → the hex itself:
#     click and hover must not be "silent".
# Change detection in update_hovered_chunk is also checked: it works on
# the HIGHLIGHT set (otherwise moving between explored clusters yielded
# [] == [], the chunk_hovered signal was not emitted, and the highlight "froze" at
# the previous cursor position).
# Checked on live data of the real MainMap scene (new game).
extends SceneTree

# Hang watchdog: without it, a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    var em = main_map.expansion_manager

    # --- 1. City hex (Influence Ring): only itself is highlighted ---
    var city_hl: Array = em.get_highlight_hexes(main_map.city_row, main_map.city_col)
    check(city_hl.size() == 1
        and city_hl[0].row == main_map.city_row and city_hl[0].col == main_map.city_col,
        "a hex in the Influence Ring must highlight only itself", state)

    # --- 2. Hex outside the map: no highlight ---
    check(em.get_highlight_hexes(-5, -5).is_empty(),
        "a hex outside the map must not produce a highlight", state)

    # --- 3. Unexplored Region hex: the whole chunk is highlighted ---
    var region_hex = _find_unexplored_region_hex(main_map)
    check(region_hex != null, "no unexplored Region hex found", state)
    if region_hex != null:
        var chunk: Array = em.get_chunk_hexes(region_hex.row, region_hex.col)
        check(chunk.size() > 0, "the chunk of an unexplored Region hex must not be empty", state)
        var hl: Array = em.get_highlight_hexes(region_hex.row, region_hex.col)
        check(hl.size() == chunk.size(),
            "for an unexplored hex the whole chunk must be highlighted (%d vs %d)"
                % [hl.size(), chunk.size()], state)

    # --- 4. Unexplored fog-of-war hex (with Cartography): a highlight exists ---
    city.unlocked_technologies.append("cartography")
    var fog_hex = _find_fog_hex(main_map)
    check(fog_hex != null, "no unexplored fog-of-war hex found", state)
    if fog_hex != null:
        var hl_fog: Array = em.get_highlight_hexes(fog_hex.row, fog_hex.col)
        check(hl_fog.size() >= 1,
            "an unexplored fog hex must be highlighted (chunk or the hex itself)", state)
        check(_contains_hex(hl_fog, fog_hex.row, fog_hex.col),
            "the highlight must include the hovered hex", state)

    # --- 5. EXPLORED hex outside the Region: a chunk of up to 5 hexes is highlighted ---
    # This was the "silent" click: get_chunk_hexes() returns an
    # empty array for such a hex (purchase is only possible in the Region). The fallback builds a BFS from
    # the hex under the cursor over explored hexes (for a lone hex the chunk consists
    # of itself).
    var explored_fog = _find_fog_hex(main_map)
    if explored_fog != null:
        main_map.tile_data[explored_fog.row][explored_fog.col]["is_explored"] = true
        check(em.get_chunk_hexes(explored_fog.row, explored_fog.col).is_empty(),
            "an explored hex outside the Region has no chunk (the cause of the \"silent\" click)", state)
        var hl_explored: Array = em.get_highlight_hexes(explored_fog.row, explored_fog.col)
        check(hl_explored.size() >= 1 and hl_explored.size() <= 5,
            "an explored hex outside the Region is highlighted by a chunk of up to 5 hexes (got %d)"
                % hl_explored.size(), state)
        check(_contains_hex(hl_explored, explored_fog.row, explored_fog.col),
            "the highlight must include the hovered hex", state)
        for h in hl_explored:
            check(bool(main_map.tile_data[h.row][h.col].get("is_explored", false)),
                "the cluster consists only of explored hexes", state)
            check(not bool(main_map.tile_data[h.row][h.col].get("in_influence", false)),
                "the cluster does not include the Influence Ring", state)
            check(not bool(main_map.tile_data[h.row][h.col].get("in_town_influence", false)),
                "the cluster does not cross foreign towns' rings", state)

    # --- 5a. A cluster of several hexes: fully highlighted from any ---
    # --- point, different hexes of one cluster yield an IDENTICAL set ----------
    # We mark a fog hex adjacent to the explored one as explored — the cluster grows.
    var neighbor = null
    var isolated = null
    for n in em._get_neighbors(explored_fog.row, explored_fog.col):
        if not main_map.is_hex_on_map(n.row, n.col):
            continue
        var nt = main_map.tile_data[n.row][n.col]
        if nt == null or bool(nt.get("in_influence", false)) or bool(nt.get("in_town_influence", false)):
            continue
        if main_map.is_valid_hex(n.row, n.col):
            continue
        neighbor = n
        break
    check(neighbor != null, "an explored hex must have a neighbor in the fog", state)
    if neighbor != null:
        main_map.tile_data[neighbor.row][neighbor.col]["is_explored"] = true
        var hl_from_first: Array = em.get_highlight_hexes(explored_fog.row, explored_fog.col)
        var hl_from_second: Array = em.get_highlight_hexes(neighbor.row, neighbor.col)
        check(hl_from_first.size() == 2 and hl_from_second.size() == 2,
            "a cluster of two explored hexes is highlighted in full (%d and %d)"
                % [hl_from_first.size(), hl_from_second.size()], state)
        check(em._chunk_equals(hl_from_first, hl_from_second),
            "the same cluster from different hexes yields an identical set", state)
        # --- 5b. Isolated explored hex: the cluster is only itself ---
        if fog_hex != null:
            # Take a fog hex that is not adjacent to any already explored one.
            for cand_row in range(main_map.map_rows):
                if isolated != null:
                    break
                for cand_col in range(main_map.map_cols):
                    if not main_map.is_hex_on_map(cand_row, cand_col):
                        continue
                    var ct = main_map.tile_data[cand_row][cand_col]
                    if ct == null or bool(ct.get("is_explored", false)) \
                            or bool(ct.get("in_influence", false)) \
                            or bool(ct.get("in_town_influence", false)):
                        continue
                    if main_map.is_valid_hex(cand_row, cand_col):
                        continue
                    var has_explored_neighbor := false
                    for cn in em._get_neighbors(cand_row, cand_col):
                        if main_map.is_hex_on_map(cn.row, cn.col):
                            var cnt = main_map.tile_data[cn.row][cn.col]
                            if cnt != null and bool(cnt.get("is_explored", false)):
                                has_explored_neighbor = true
                                break
                    if not has_explored_neighbor:
                        isolated = {"row": cand_row, "col": cand_col}
                        break
        check(isolated != null, "no isolated fog hex found for a cluster of 1", state)
        if isolated != null:
            main_map.tile_data[isolated.row][isolated.col]["is_explored"] = true
            var hl_iso: Array = em.get_highlight_hexes(isolated.row, isolated.col)
            check(hl_iso.size() == 1 and _contains_hex(hl_iso, isolated.row, isolated.col),
                "an isolated explored hex highlights itself", state)

    # --- 5c. Regression of the "frozen" highlight (bug 2) via the signal ---
    # Previously update_hovered_chunk compared the ACTION chunk (get_chunk_hexes):
    # for explored hexes outside the Region it is always empty, so moving between two
    # such clusters yielded [] == [] — the signal was not emitted, and the renderer
    # kept showing the highlight of the previous cursor position. Now
    # detection works on the highlight set.
    var signal_events: Array = []
    var handler = func(chunk: Array): signal_events.append(chunk.duplicate(true))
    em.chunk_hovered.connect(handler)
    # Hovering the first hex of the cluster → 1 emit with a cluster of 2 hexes.
    em.update_hovered_chunk(explored_fog.row, explored_fog.col)
    check(signal_events.size() == 1 and signal_events[0].size() == 2,
        "hovering a cluster emits a signal with 2 hexes", state)
    # Moving to the second hex of the SAME cluster → 0 emits (the set did not change).
    em.update_hovered_chunk(neighbor.row, neighbor.col)
    check(signal_events.size() == 1,
        "moving within a cluster does not emit the signal again", state)
    # Moving to the isolated hex → 1 emit with a set of 1 hex.
    em.update_hovered_chunk(isolated.row, isolated.col)
    check(signal_events.size() == 2 and signal_events[1].size() == 1,
        "moving to another cluster emits a signal with a new set", state)
    check(_contains_hex(signal_events[1], isolated.row, isolated.col)
        and not _contains_hex(signal_events[1], explored_fog.row, explored_fog.col),
        "the new highlight is on the new cluster, not on the previous one", state)
    # The cursor leaving the map → 1 emit with an empty set.
    em.clear_hovered_chunk()
    check(signal_events.size() == 3 and signal_events[2].is_empty(),
        "the cursor leaving emits a signal with an empty set", state)
    em.chunk_hovered.disconnect(handler)

    # --- 6. Hex in a foreign town's influence ring: also the hex itself ---
    var town_ring = _find_town_ring_hex(main_map)
    check(town_ring != null, "no hex found in a foreign town's influence ring", state)
    if town_ring != null:
        # For an UNexplored ring hex a scouting chunk is built — scouts
        # can be sent there (this is allowed by the rules). The chunk is empty for an
        # EXPLORED ring hex: purchase on a foreign town's territory
        # is forbidden, and without the fallback a click on such a hex highlighted nothing.
        main_map.tile_data[town_ring.row][town_ring.col]["is_explored"] = true
        check(em.get_chunk_hexes(town_ring.row, town_ring.col).is_empty(),
            "an explored hex in a foreign town's ring has no chunk", state)
        var hl_ring: Array = em.get_highlight_hexes(town_ring.row, town_ring.col)
        check(hl_ring.size() == 1,
            "a hex in a foreign town's ring must highlight itself (got %d)"
                % hl_ring.size(), state)

    # --- 7. Invariant: for a hex on the map the highlight is never empty ---
    var empty_highlights := 0
    var checked_hexes := 0
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if main_map.tile_data[row][col] == null:
                continue
            checked_hexes += 1
            if em.get_highlight_hexes(row, col).is_empty():
                empty_highlights += 1
    check(empty_highlights == 0,
        "for every hex on the map the highlight must not be empty (empty: %d of %d)"
            % [empty_highlights, checked_hexes], state)
    print("HIGHLIGHT STATS: hexes checked %d, empty highlights %d" % [checked_hexes, empty_highlights])

    _finish(main_map, state)# First unexplored Region hex.
func _find_unexplored_region_hex(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if main_map.is_valid_hex(row, col):
                return {"row": row, "col": col}
    return null

# First unexplored fog-of-war hex (outside the Region, outside the Influence Ring and
# outside a foreign town's ring).
func _find_fog_hex(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            return {"row": row, "col": col}
    return null

# First hex in a foreign town's influence ring (outside the player's Influence Ring and outside
# the Region — there get_chunk_hexes is guaranteed to be empty).
func _find_town_ring_hex(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile == null:
                continue
            if not bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("in_influence", false)) or main_map.is_valid_hex(row, col):
                continue
            return {"row": row, "col": col}
    return null

func _contains_hex(hexes: Array, row: int, col: int) -> bool:
    for hex in hexes:
        if hex.row == row and hex.col == col:
            return true
    return false

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("HIGHLIGHT HEXES TEST FAILED")
        quit(1)
    else:
        print("HIGHLIGHT HEXES TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
