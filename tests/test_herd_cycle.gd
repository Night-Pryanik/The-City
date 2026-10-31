# Headless test of the herd breeding cycle:
#   godot --headless --path . --script res://tests/test_herd_cycle.gd
#
# The rule under test: the herd of a species lives in the city storage — the
# live_* units there are the whole population. The pasture breeds in cycles:
# one batch of heads (the live_* value of produces) per
# breeding_cycle_multiplier × time_to_mature seconds. An extinct species (zero
# heads) freezes the breeding until the herd is re-purchased. The slaughterhouse
# never butchers the breeding core (livestock_breeding_cost heads): automatic
# butchering cannot extinct a species.
#
# Checks:
#   1. An extinct herd breeds nothing and the pasture stays registered.
#   2. After the re-purchase the cycles resume: one batch per period, the first
#      maturation establishes the herd (herd_mature).
#   3. The breeding core: the slaughterhouse takes only the heads ABOVE
#      livestock_breeding_cost and releases nothing while only the core remains.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null
var _mh = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    # Autoloads are taken as tree nodes: in --script mode the names GameData/CityData
    # are not yet available at the compile stage of this file.
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _mh = load("res://scripts/map_helpers.gd")

    _test_cycle(state)
    _test_slaughter_core(state)

    if state["failed"]:
        print("HERD CYCLE TEST FAILED")
        quit(1)
    print("HERD CYCLE TEST OK")
    quit(0)

func _test_cycle(state: Dictionary) -> void:
    # The real cows resource: GameData.live_product_of() is built from the real
    # data, so the test shortens the real resource instead of inventing a new one.
    var cows: Dictionary = _gdata.raw_resources.get("cows", {})
    check(not cows.is_empty(), "the data needs the cows resource", state)
    if cows.is_empty():
        return
    check(_gdata.live_product_of("cows") == "live_cows",
            "cows must map to the live product live_cows", state)
    var batch: int = int(cows.get("produces", {}).get("live_cows", 0))
    check(batch > 0, "the cows must produce a live_* batch (got %d)" % batch, state)
    # A short cycle for the test: 10 sec to mature × multiplier 1 = 10 sec period.
    cows["time_to_mature"] = 10.0
    check(is_equal_approx(_mh.get_breeding_cycle_period(cows), 10.0),
            "the period = time_to_mature × the multiplier (got %.1f)"
                    % _mh.get_breeding_cycle_period(cows), state)

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var spot := _find_free_hex(main_map)
    check(not spot.is_empty(), "a free hex in the influence is needed for the check", state)
    if spot.is_empty():
        _free_map(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "cows"
    tile["improvement"] = "pasture"
    tile["quality"] = "common"
    tile["fill_time"] = 0.0
    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    check(main_map.worker_manager.assign_worker(row, col),
            "a worker must be assigned to the pasture", state)

    # The pasture is registered by the production loop of _process; the test
    # seeds the registry directly and drives the fill synchronously, so the
    # engine frames between the awaits cannot interfere with the counts.
    var key := "%d,%d" % [row, col]
    main_map._growing_pastures[key] = {"row": row, "col": col}

    # --- 1. Extinct species: the fill is frozen, nothing breeds ---
    check(_cdata.get_storage_amount("live_cows") == 0,
            "a new game must start without heads (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    main_map._tick_pasture_fill(10.0)
    check(_cdata.get_storage_amount("live_cows") == 0,
            "an extinct herd must breed nothing (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    check(main_map._growing_pastures.has(key),
            "the extinct pasture must stay registered for the breeding", state)

    # --- 2. Re-purchase: the cycles resume, the first maturation sets herd_mature ---
    _cdata.add_to_storage("live_cows", 10, "common")
    main_map._tick_pasture_fill(10.0)
    check(_cdata.get_storage_amount("live_cows") == 10 + batch,
            "one full period must breed one batch of heads (got %d, expected %d)"
                    % [_cdata.get_storage_amount("live_cows"), 10 + batch], state)
    check(bool(tile.get("herd_mature", false)),
            "the first maturation must establish the herd (herd_mature)", state)

    main_map._tick_pasture_fill(5.0)
    check(_cdata.get_storage_amount("live_cows") == 10 + batch,
            "half a period must not breed a batch (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    main_map._tick_pasture_fill(5.0)
    check(_cdata.get_storage_amount("live_cows") == 10 + batch * 2,
            "the second period must breed the second batch (got %d, expected %d)"
                    % [_cdata.get_storage_amount("live_cows"), 10 + batch * 2], state)

    # --- 3. Extinction again and the recovery ---
    _cdata.remove_from_storage("live_cows", 100000)
    main_map._tick_pasture_fill(10.0)
    check(_cdata.get_storage_amount("live_cows") == 0,
            "after the extinction the breeding must freeze again (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    _cdata.add_to_storage("live_cows", 10, "common")
    main_map._tick_pasture_fill(10.0)
    check(_cdata.get_storage_amount("live_cows") == 10 + batch,
            "after the re-purchase the cycles must resume (got %d, expected %d)"
                    % [_cdata.get_storage_amount("live_cows"), 10 + batch], state)
    check(bool(tile.get("herd_mature", false)),
            "an established herd must stay established after the re-purchase", state)

    _free_map(main_map)

func _test_slaughter_core(state: Dictionary) -> void:
    var recipe: Dictionary = _cdata.get_craft_by_id("beef")
    check(not recipe.is_empty(), "the beef recipe is found in data/crafts", state)
    if recipe.is_empty():
        return
    var core: int = _cdata.livestock_breeding_cost()
    var heads: int = int(recipe.get("resources", {}).get("@bovines", 0))
    check(heads == 20, "the beef recipe must butcher 20 heads (got %d)" % heads, state)
    check(heads > core,
            "a slaughter cycle must take heads above the breeding core (heads %d, core %d)"
                    % [heads, core], state)
    check(is_equal_approx(float(recipe.get("time", 0.0)), 5.0),
            "the slaughter must take 5 s (got %.1f)" % float(recipe.get("time", 0.0)), state)

    # The class is loaded at runtime, not referenced by name: in --script mode
    # the global classes that depend on the autoloads compile only after the
    # autoloads are registered (the first frame).
    var container = load("res://scripts/craft_container.gd").new(recipe)

    # 12 heads: only 2 above the core. One second of the 5-second cycle owes 4 heads.
    _cdata.add_to_storage("live_cows", 12, "common")
    var res1: Dictionary = container.tick(1.0, true, "best", 1.0)
    check(_cdata.get_storage_amount("live_cows") == core,
            "the slaughterhouse must stop at the breeding core (got %d, core %d)"
                    % [_cdata.get_storage_amount("live_cows"), core], state)
    var taken1: int = int(res1.get("consumed_breakdown", {}).get("live_cows", {}).get("common", 0))
    check(taken1 == 2, "only the heads above the core were butchered (got %d)" % taken1, state)
    check(res1.get("releases", []).is_empty(),
            "with only the core left the craft must release nothing", state)
    check(not res1.get("missing", []).is_empty(),
            "the craft must report the missing heads while the core blocks it", state)

    # 18 more heads: the remaining 18 of the 20 arrive over the rest of the cycle.
    _cdata.add_to_storage("live_cows", 18, "common")
    var beef_out := 0
    var hide_out := 0
    var completed := false
    for delta in [4.0, 1.0]:
        var res: Dictionary = container.tick(delta, true, "best", 1.0)
        completed = completed or bool(res.get("completed", false))
        for rel in res.get("releases", []):
            var pid := str(rel.get("pid", ""))
            var amount := int(rel.get("amount", 0))
            if pid == "beef":
                beef_out += amount
            elif pid == "hide":
                hide_out += amount
    check(_cdata.get_storage_amount("live_cows") == core,
            "after the cycle the core must be intact (got %d, core %d)"
                    % [_cdata.get_storage_amount("live_cows"), core], state)
    check(beef_out == 120 and hide_out == 20,
            "a full cycle of 20 heads must release 120 beef and 20 hide (got %d beef, %d hide)"
                    % [beef_out, hide_out], state)
    check(completed, "the cycle must complete once the heads above the core arrived", state)

func _find_free_hex(main_map) -> Dictionary:
    for r in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for c in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[r][c]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("in_town_influence", false):
                continue
            if r == main_map.city_row and c == main_map.city_col:
                continue
            return {"row": r, "col": c}
    return {}

func _free_map(main_map) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
