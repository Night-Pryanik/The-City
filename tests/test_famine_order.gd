# Headless test for the famine death order (CityData._check_population_change):
#   godot --headless --path . --script res://tests/test_famine_order.gd
#
# The famine fires when the food pool holds exactly zero units AND the food
# consumption exceeds the food production. Exactly one resident dies per tick, in a
# fixed order:
#   1. the free residents (the unemployed) first;
#   2. then the residents of the city buildings;
#   3. then the workers on the map hexes.
# The order is a design rule rather than a traversal detail: an unemployed citizen
# costs the city nothing, so the workplaces lose people last.
#
# Checks:
#   1. A free resident is available -> the free resident dies, both workplaces stay.
#   2. Nobody is free -> a city-building resident dies, the map worker stays.
#   3. Nobody is free and no townsfolk -> a map worker dies.
#   4. Food is left in the storage -> nobody dies (the famine needs EXACTLY zero).
extends SceneTree

# Without the watchdog a broken coroutine inside _run() looks like a silent hang
# from the outside. See tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _city = null
var _map = null
var _tm = null
var _wm = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # The autoloads are read through the tree: in --script mode their names are not
    # available at the compile time of this file.
    get_root().get_node("SaveManager").new_game()
    _city = get_root().get_node("CityData")

    _map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(_map)
    await process_frame
    await process_frame
    await process_frame

    _tm = _map.get_node("TownsfolkManager")
    _wm = _map.get_node("WorkerManager")

    # The map auto-assigns workers while it starts up. The order under test depends on
    # the exact contents of the assignment dictionaries, so the test starts clean.
    _wm.assigned_hexes.clear()
    _tm.assigned_buildings.clear()

    var spot_a := _find_hex([])
    check(not spot_a.is_empty(), "a free hex must exist on the live map", state)
    if spot_a.is_empty():
        _finish(state)
        return
    var row_a := int(spot_a["row"])
    var col_a := int(spot_a["col"])
    _map.tile_data[row_a][col_a]["improvement"] = "farm"

    var spot_b := _find_hex([str(row_a) + "," + str(col_a)])
    check(not spot_b.is_empty(), "a second free hex must exist on the live map", state)
    if spot_b.is_empty():
        _finish(state)
        return
    var row_b := int(spot_b["row"])
    var col_b := int(spot_b["col"])
    _map.tile_data[row_b][col_b]["improvement"] = "farm"

    _city.city_built_buildings = [
        {"id": "bakery", "slots": ["bread"], "quality_priority": "best"},
        {"id": "bakery", "slots": ["bread"], "quality_priority": "best"},
    ]

    # --- 1. The free residents are taken first ---
    _city.idle_population = 10
    check(_tm.assign_townsfolk(0), "a townsfolk must take the first building", state)
    check(_wm.assign_worker(row_a, col_a), "a worker must take the first hex", state)
    _city.total_population = 3
    _city.idle_population = 1
    _arm_famine()
    _city._check_population_change()
    check(_city.total_population == 2, "exactly one resident must die per famine tick", state)
    check(_city.idle_population == 0, "the free resident must be the one who dies", state)
    check(_tm.has_townsfolk(0),
            "the building resident must survive while a free resident remains", state)
    check(_wm.has_worker(row_a, col_a),
            "the map worker must survive while a free resident remains", state)

    # --- 2. Nobody is free: the city buildings lose a resident ---
    _city.total_population = 2
    _city.idle_population = 0
    _arm_famine()
    _city._check_population_change()
    check(_city.total_population == 1, "exactly one resident must die per famine tick", state)
    check(not _tm.has_townsfolk(0), "the building resident must die when nobody is free", state)
    check(_wm.has_worker(row_a, col_a),
            "the map worker must survive while a building resident is left", state)

    # --- 3. Nobody is free and no townsfolk: the map hexes lose a worker ---
    _tm.assigned_buildings.clear()
    _wm.assigned_hexes.clear()
    _city.idle_population = 10
    check(_wm.assign_worker(row_a, col_a), "a worker must take the first hex", state)
    check(_wm.assign_worker(row_b, col_b), "a worker must take the second hex", state)
    _city.total_population = 2
    _city.idle_population = 0
    _arm_famine()
    _city._check_population_change()
    check(_city.total_population == 1, "exactly one resident must die per famine tick", state)
    check(_wm.get_assigned_count() == 1, "exactly one worker must be removed", state)
    check(not _wm.has_worker(row_a, col_a),
            "the first assigned worker must be the one who dies", state)
    check(_wm.has_worker(row_b, col_b), "the second worker must survive", state)

    # --- 4. No famine while the storage still holds food ---
    _city.total_population = 2
    _city.idle_population = 1
    _arm_famine()
    _city.city_storage["wheat"] = 5
    _city._check_population_change()
    check(_city.total_population == 2,
            "a positive stock of food must not kill anybody", state)
    check(_city.idle_population == 1,
            "nobody must die while the storage is not empty", state)

    WATCHDOG.report_skipped()
    _finish(state)

# The famine condition in isolation: an empty food storage and a negative food balance.
# The products themselves are irrelevant — _check_population_change() only sums the
# rates over the food pool.
func _arm_famine() -> void:
    _city.city_food_pool = {"wheat": true}
    _city.city_storage.clear()
    _city.production_rates = {"wheat": 0}
    _city.consumption_rates = {"wheat": 10}

# The first free hex of the influence ring: no town, not decorative, no improvement —
# the only conditions worker_manager.assign_worker() imposes on a direct call.
func _find_hex(exclude: Array) -> Dictionary:
    for row in range(_map.influence_start_row, _map.influence_end_row + 1):
        for col in range(_map.influence_start_col, _map.influence_end_col + 1):
            var tile = _map.tile_data[row][col]
            if tile == null or tile.get("decorative", false):
                continue
            if tile.get("has_town", false):
                continue
            if tile.get("improvement", null) != null:
                continue
            if exclude.has(str(row) + "," + str(col)):
                continue
            return {"row": row, "col": col}
    return {}

func _finish(state: Dictionary) -> void:
    if _map != null and is_instance_valid(_map):
        get_root().remove_child(_map)
        _map.free()
    if state["failed"]:
        print("FAMINE ORDER TEST FAILED")
        quit(1)
    else:
        print("FAMINE ORDER TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    push_error("ASSERT: " + message)
    print("ASSERT FAILED: ", message)
    state["failed"] = true
