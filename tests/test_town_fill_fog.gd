# Headless test: town ring fill does not leak into the fog of war.
#   godot --headless --path . --script res://tests/test_town_fill_fog.gd
#
# Verified against live data of the real MainMap scene (new game):
#   1. In the 1st era no rings are visible at all — otherwise a foreign town
#      would reveal itself in an unexplored Region area from the very start of
#      the game.
#   2. No fill hex (render cache) lies in the fog of war.
#   3. No ring border has an endpoint in the fog of war (a neighbor with a fill
#      hex outside the fog).
#   4. After scouting a fogged hex the fill appears on it, and the cache is
#      rebuilt (without invalidation scouting would have no effect).
#   5. The same holds after an era change: the cache is rebuilt, no new fill
#      hexes appear in the fog.
#
# Items 2-5 are checked starting from the Antiquity era (current_era >= 1): only
# from then are towns visible to the player at all, and thus their rings (see
# map_renderer._ensure_town_influence_cache). In the 1st era rings are NEVER
# drawn — regardless of the fog, so fog checks require an era change.
extends SceneTree

# Watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var r = main_map.map_renderer

    # --- 1: in the 1st era no rings are visible ---
    r.invalidate_town_influence_cache()
    _rebuild(r)
    check(r.get_town_fill_hexes().is_empty(),
        "in the 1st era town rings must not be drawn (hexes received: %d)"
            % r.get_town_fill_hexes().size(), state)

    # From the Antiquity era towns are visible — next we check the fog itself.
    main_map.advance_to_next_era()
    await process_frame

    # --- 2 and 3: fill and borders do not enter the fog ---
    _rebuild(r)
    check(_fill_in_fog(main_map, r).is_empty(),
        "town fill must not be drawn on fog-of-war hexes (violations: %s)"
            % str(_fill_in_fog(main_map, r)), state)
    check(_borders_in_fog(main_map, r).is_empty(),
        "town ring borders must not extend into the fog of war (violations: %s)"
            % str(_borders_in_fog(main_map, r)), state)

    # --- 4: scouting reveals the fill and rebuilds the cache ---
    var fog_hexes: Array = []
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile != null and main_map.is_hex_in_fog(row, col) \
                    and bool(tile.get("in_town_influence", false)):
                fog_hexes.append({"row": row, "col": col})
    check(not fog_hexes.is_empty(),
        "the live map must contain at least one town ring hex in the fog", state)
    if not fog_hexes.is_empty():
        var h: Dictionary = fog_hexes[0]
        # Scouting the normal way: a chunk of one hex. The fill cache must
        # rebuild BY ITSELF (see invalidate_town_influence_cache in
        # _complete_scouting) — we do not touch it manually.
        main_map.scouting_chunk = [h]
        main_map.is_scouting = true
        main_map._complete_scouting()
        _rebuild(r)
        check(not main_map.is_hex_in_fog(h.row, h.col),
            "a scouted hex cannot be in the fog of war", state)
        var now_drawn: bool = _is_filled(r, h.row, h.col)
        check(now_drawn,
            "after scouting the town fill must appear on the hex (%d,%d)"
                % [int(h.row), int(h.col)], state)

    # --- 5: era change ---
    main_map.advance_to_next_era()
    await process_frame
    _rebuild(r)
    check(_fill_in_fog(main_map, r).is_empty(),
        "after an era change the fill must not extend into the fog of war (violations: %s)"
            % str(_fill_in_fog(main_map, r)), state)
    check(_borders_in_fog(main_map, r).is_empty(),
        "after an era change the ring borders must not extend into the fog (violations: %s)"
            % str(_borders_in_fog(main_map, r)), state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("TOWN FILL FOG TEST FAILED")
        quit(1)
    else:
        print("TOWN FILL FOG TEST OK")
        quit(0)

# Force-rebuilds the render cache (as a render frame does).
func _rebuild(r) -> void:
    r._ensure_town_influence_cache(r._get_visible_hex_range())

func _is_filled(r, row: int, col: int) -> bool:
    for h in r.get_town_fill_hexes():
        if int(h.row) == row and int(h.col) == col:
            return true
    return false

# Fill hexes that fall into the fog of war.
func _fill_in_fog(main_map, r) -> Array:
    var bad: Array = []
    for h in r.get_town_fill_hexes():
        if main_map.is_hex_in_fog(int(h.row), int(h.col)):
            bad.append([int(h.row), int(h.col)])
    return bad

# Border segments with at least one endpoint hex in the fog of war.
func _borders_in_fog(main_map, r) -> Array:
    var bad: Array = []
    for h in r.get_town_border_hexes():
        if main_map.is_hex_in_fog(int(h.row), int(h.col)):
            bad.append([int(h.row), int(h.col)])
    return bad

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
