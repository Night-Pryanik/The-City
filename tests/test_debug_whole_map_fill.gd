# Headless test: the debug action "Open the whole map" draws the influence rings
# of the towns even in the 1st era.
#   godot --headless --path . --script res://tests/test_debug_whole_map_fill.gd
#
# Checked on the live data of the real MainMap scene (a new game):
#   1. In the 1st era the rings are not drawn before the reveal (the era gate of the renderer).
#   2. After main_map.debug_open_whole_map() in the 1st era the fill covers every ring hex
#      of every town: the reveal removes the fog of war from the whole map, so no ring hex
#      may be filtered out, and the fill contains nothing outside the rings.
#   3. The outlines of the rings are built as well, and none of their hexes is in the fog.
#   4. The roads of the towns are visible (they share the gate of the fill).
#   5. The reveal flag is stored in map_state and restored by _apply_saved_map_state,
#      otherwise a loaded game would hide the rings behind the era gate again.
extends SceneTree

# A watchdog against hangs: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var r = main_map.map_renderer

    # --- 1: in the 1st era the rings are not drawn ---
    check(main_map.current_era < 1,
        "the test must start in the 1st era, got era %d" % main_map.current_era, state)
    r.invalidate_town_influence_cache()
    _rebuild(r)
    check(r.get_town_fill_hexes().is_empty(),
        "in the 1st era the rings must not be drawn before the reveal (got %d hexes)"
            % r.get_town_fill_hexes().size(), state)

    # --- 2: the reveal draws the rings ---
    main_map.debug_open_whole_map()
    check(main_map.debug_whole_map_revealed,
        "the reveal must set main_map.debug_whole_map_revealed", state)
    var expected: Dictionary = {}
    for t in main_map.towns:
        for h in t.get("influence_hexes", []):
            expected["%d,%d" % [int(h.row), int(h.col)]] = true
    check(not expected.is_empty(),
        "a live map must have at least one town ring", state)
    _rebuild(r)
    var drawn := _key_set(r.get_town_fill_hexes())
    check(_keys_only_in(expected, drawn).is_empty(),
        "after the reveal every ring hex must be drawn (missing: %s)"
            % str(_keys_only_in(expected, drawn)), state)
    check(_keys_only_in(drawn, expected).is_empty(),
        "the fill must contain no hexes outside the rings (extra: %s)"
            % str(_keys_only_in(drawn, expected)), state)
    check(_fill_in_fog(main_map, r).is_empty(),
        "no ring hex may stay in the fog after the reveal (violators: %s)"
            % str(_fill_in_fog(main_map, r)), state)

    # --- 3: the outlines ---
    check(not r.get_town_border_hexes().is_empty(),
        "after the reveal the outlines of the rings must be built", state)
    check(_borders_in_fog(main_map, r).is_empty(),
        "no outline hex may stay in the fog after the reveal (violators: %s)"
            % str(_borders_in_fog(main_map, r)), state)

    # --- 4: the roads of the towns share the gate of the fill ---
    check(r.are_town_roads_visible(),
        "after the reveal the roads of the towns must be visible in the 1st era", state)

    # --- 5: the reveal is stored in the save ---
    var map_state: Dictionary = main_map.get_map_state()
    check(bool(map_state.get("debug_whole_map_revealed", false)),
        "get_map_state() must store the reveal flag", state)
    save_manager.saved_data = {"map_state": map_state}
    main_map.debug_whole_map_revealed = false
    main_map._apply_saved_map_state()
    check(main_map.debug_whole_map_revealed,
        "_apply_saved_map_state() must restore the reveal flag", state)
    save_manager.saved_data.clear()

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("DEBUG WHOLE MAP FILL TEST FAILED")
        quit(1)
    else:
        print("DEBUG WHOLE MAP FILL TEST OK")
        quit(0)

# Rebuilds the render cache by force (as a drawing frame does).
func _rebuild(r) -> void:
    r._ensure_town_influence_cache(r._get_visible_hex_range())

# The fill hexes that lie in the fog of war.
func _fill_in_fog(main_map, r) -> Array:
    var bad: Array = []
    for h in r.get_town_fill_hexes():
        if main_map.is_hex_in_fog(int(h.row), int(h.col)):
            bad.append([int(h.row), int(h.col)])
    return bad

# The outline hexes that lie in the fog of war.
func _borders_in_fog(main_map, r) -> Array:
    var bad: Array = []
    for h in r.get_town_border_hexes():
        if main_map.is_hex_in_fog(int(h.row), int(h.col)):
            bad.append([int(h.row), int(h.col)])
    return bad

func _key_set(hexes: Array) -> Dictionary:
    var out: Dictionary = {}
    for h in hexes:
        out["%d,%d" % [int(h.row), int(h.col)]] = true
    return out

# The keys that are in a but not in b.
func _keys_only_in(a: Dictionary, b: Dictionary) -> Array:
    var out: Array = []
    for k in a.keys():
        if not b.has(k):
            out.append(k)
    return out

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true