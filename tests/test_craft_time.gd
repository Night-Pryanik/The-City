# Headless test of recipe time (the `time` field in data/crafts/*.json):
#   godot --headless --path . --script res://tests/test_craft_time.gd
#
# Checks:
#   1) get_craft_time() reads the time field and falls back to SIMULATION_TICK;
#   2) continuous crafting: CraftContainer accumulates ingredients at
#      resources/time and emits result at result/time, so with
#      time = 5 and a tick step of 1 sec bricks come out at 2 units/sec while
#      clay is consumed at 6 units/sec (30 clay -> 10 bricks), not "in batches
#      once every 5 seconds";
#   3) container state lives in the building record (key "slot_containers",
#      goes into the save) and is created lazily
#   4) when raw resources are lacking the container "freezes": it does NOT
#      accumulate a time debt, so after resources are delivered exactly one
#      portion of result is emitted per tick (not a volley for all the
#      accumulated seconds), and the cycle resets;
#   5) planned building demand and output carry interval = recipe time and
#      reach the worker_manager.get_planned_consumption_map() map (the tooltip
#      reads it).
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Autoloads get "into the tree" only after initialization, so the test starts
# from the first frame (_process), not from _initialize: otherwise get_tree()
# inside do_tick() would return null.
var _done := false

# The watchdog is armed in _initialize, while the test itself starts from the
# first _process — the timer doesn't care where it started. The point of the
# split is the same as in the other tests: any break inside _run() must lead to
# exit code 2, not hang.
func _initialize() -> void:
    WATCHDOG.arm(self)

func _process(_delta) -> bool:
    if _done:
        return true
    _done = true
    _run()
    return true

func _run() -> void:
    var state = {"failed": false}

    # First frame: the scene tree is already up (autoloads inside the tree),
    # so do_tick()/planned maps see MainMap through get_tree().root.
    # Before the first frame get_tree() would return null.

    # The GameData/CityData/SaveManager autoloads are already in the tree, but
    # the GameData registries are loaded by the menu/map — in headless mode we
    # load them ourselves. The autoload name can't be used in this script: it
    # compiles BEFORE they are registered, so we get the singletons through the
    # scene tree.
    var gd = get_root().get_node("GameData")
    gd.load_all_data()
    var city = get_root().get_node("CityData")

    # do_tick() looks for MainMap/TownsfolkManager on the map — we make stubs.
    var main_map := Node.new()
    main_map.name = "MainMap"
    get_root().add_child(main_map)
    var tm = load("res://scripts/townsfolk_manager.gd").new()
    tm.name = "TownsfolkManager"
    main_map.add_child(tm)

    # --- 1. Data: recipe time and the get_craft_time fallback ---
    var no_time: Array = []
    for c in gd.crafts:
        if str(c.get("id", "")) == "empty":
            continue # "Empty" — a pseudo-recipe: time = 0, the slot doesn't run it
        if float(c.get("time", 0.0)) <= 0.0:
            no_time.append(str(c.get("id", "?")))
    check(no_time.is_empty(), "all recipes have time > 0 (missing for: %s)" % str(no_time), state)
    check(is_equal_approx(city.get_craft_time({"id": "t"}), city.SIMULATION_TICK),
        "without a time field the period = tick step", state)
    check(is_equal_approx(city.get_craft_time({"id": "t", "time": 0}), city.SIMULATION_TICK),
        "time = 0 is treated as \"per tick\"", state)
    check(is_equal_approx(city.get_craft_time({"id": "t", "time": 7.5}), 7.5),
        "time = 7.5 is returned as is", state)

    var craft_time := 5.0 # time of the bricks recipe (pottery workshop, 30 clay -> 10 bricks)
    var recipe = city.get_craft_by_id("bricks")
    check(not recipe.is_empty(), "the bricks recipe is found in data/crafts", state)
    if not recipe.is_empty():
        check(is_equal_approx(city.get_craft_time(recipe), craft_time),
            "time of the bricks recipe = %s" % str(craft_time), state)

    # --- 2. Continuous crafting: constant rates, not batches ---
    # The bricks recipe: 30 clay -> 10 bricks, time = 5. So per tick (1 sec)
    # the container accumulates 30/5 = 6 clay and emits 10/5 = 2 bricks. Both
    # numbers are integers, so sub-unit accumulators produce no drift or output
    # "tail".
    city.add_to_storage("clay", 60, "common")
    city.total_population = 1
    city.idle_population = 0
    city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks"], "quality_priority": "best"}]
    tm.assigned_buildings = {"0": true} # a citizen is assigned to the building

    city.do_tick() # 1 sec
    check(city.get_storage_amount("clay") == 54, "tick 1: 6 clay consumed (30/5 = 6 units/sec)", state)
    check(city.get_storage_amount("bricks") == 2, "tick 1: 2 bricks emitted (10/5 = 2 units/sec)", state)
    check(is_equal_approx(city.get_slot_progress_ratio(0, 0), 0.2),
        "tick 1: ratio = min(6/30, 1/5) = 0.2 (actual %.2f)" % city.get_slot_progress_ratio(0, 0), state)

    for _i in range(3): # 2, 3 and 4 sec — the rates are the same
        city.do_tick()
    check(city.get_storage_amount("clay") == 36, "ticks 2-4: 18 more clay consumed (24 of 60)", state)
    check(city.get_storage_amount("bricks") == 8, "ticks 2-4: 6 more bricks emitted (8 total)", state)
    check(is_equal_approx(city.get_slot_progress_ratio(0, 0), 0.8),
        "ticks 2-4: ratio = min(24/30, 4/5) = 0.8 (actual %.2f)" % city.get_slot_progress_ratio(0, 0), state)

    city.do_tick() # 5 sec — the cycle is complete, the container is reset
    check(city.get_storage_amount("bricks") == 10, "tick 5: exactly 10 bricks emitted over a full cycle", state)
    check(city.get_storage_amount("clay") == 30, "tick 5: exactly 30 clay consumed", state)
    check(is_zero_approx(city.get_slot_progress_ratio(0, 0)),
        "after the cycle completes the container is reset (ratio = 0)", state)

    for _i in range(4): # 6, 7, 8 and 9 sec — the second cycle
        city.do_tick()
    city.do_tick() # 10 sec — the second cycle is complete
    check(city.get_storage_amount("bricks") == 20, "over 10 ticks (10 sec) 20 bricks emitted (2 cycles)", state)
    check(city.get_storage_amount("clay") == 0, "all 60 clay consumed", state)
    check(is_zero_approx(city.get_slot_progress_ratio(0, 0)),
        "after the second cycle the container is reset (ratio = 0)", state)

    # --- 3. The slot container lives in the building record (goes into the save) ---
    # The continuous crafting state is stored in a CraftContainer per slot —
    # key "slot_containers" in city_built_buildings[i].
    var bld: Dictionary = city.city_built_buildings[0]
    check(bld.has("slot_containers"), "slot containers are written into the building record", state)
    check(bld.get("slot_containers", []).size() == 1, "one container per slot", state)

    # A building with more slots than containers: the array is adjusted lazily.
    city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks", "bricks"]}]
    city.get_slot_containers(0)
    check(city.city_built_buildings[0].get("slot_containers", []).size() == 2,
        "containers are added to match the current number of slots", state)
    check(is_zero_approx(city.get_slot_progress_value(0, 1)), "a new slot in an old save starts at 0 sec", state)

# --- 4. The container freezes when raw resources are lacking ---
    # In the continuous model the container does NOT accumulate a time debt:
    # without resources the ingredient is not accumulated, so progress is
    # limited by fullness, not by time (completion_ratio = min(fullness,
    # time/craft_time)). Therefore after resources are delivered the container
    # does not "catch up" the accumulated seconds in a volley: exactly one
    # portion of result is emitted per tick (10/5 = 2 bricks), and the cycle
    # still needs its five working ticks to be complete.
    city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks"], "quality_priority": "best"}]
    for _i in range(8): # 8 sec without resources — noticeably longer than the cycle time (5 s)
        city.do_tick()
    # The container type is deliberately not specified here: mentioning
    # CraftContainer would force craft_container.gd to be compiled, and it
    # references the GameData autoload, which is not yet registered in --script
    # mode (the same reason the singletons are taken from the scene tree).
    var starved = city.get_slot_container(0, 0)
    check(city.get_storage_amount("clay") == 0, "without resources there is no consumption", state)
    check(is_zero_approx(starved.completion_ratio()),
        "without resources progress = 0 (limited by fullness, not by time)", state)
    check(int(starved.ingredient_slots[0].get("filled", 0)) == 0,
        "the ingredient is not accumulated without resources", state)
    check(starved.elapsed >= craft_time,
        "time in the container runs (%.1f s >= %.1f), but does not cancel the freeze" % [starved.elapsed, craft_time], state)

    var bricks_before: int = city.get_storage_amount("bricks")
    city.add_to_storage("clay", 30, "common")
    city.do_tick()
    check(city.get_storage_amount("clay") == 24, "after resources are delivered 6 clay consumed per tick (30/5)", state)
    check(city.get_storage_amount("bricks") == bricks_before + 2,
        "output per tick = 2 bricks, there was no volley of 10 (was %d, became %d)"
            % [bricks_before, city.get_storage_amount("bricks")], state)
    # The clock ran during the freeze, but that does not finish the cycle: the fill has the last
    # word, and one supplied tick covers 6 of the 30 clay. The completion needs the whole recipe.
    check(is_equal_approx(city.get_slot_progress_ratio(0, 0), 0.2),
        "one supplied tick is 1/5 of the cycle (ratio = 0.2), not a completion (actual %.2f)"
            % city.get_slot_progress_ratio(0, 0), state)
    for _i in range(4): # the remaining four ticks of the cycle
        city.do_tick()
    check(city.get_storage_amount("bricks") - bricks_before == 10,
        "the whole cycle yields 10 bricks (%d of 10)" % (city.get_storage_amount("bricks") - bricks_before), state)
    check(city.get_storage_amount("clay") == 0, "the whole cycle spends 30 clay", state)
    check(is_zero_approx(city.get_slot_progress_ratio(0, 0)),
        "after the cycle completes the container is reset (ratio = 0)", state)

    # --- 5. Planned demand/output carry the recipe time ---
    var demand: Dictionary = city.get_building_planned_consumption()
    check(not demand.get("clay", {}).is_empty(), "planned demand for clay exists", state)
    for src in demand.get("clay", {}):
        var e: Dictionary = demand["clay"][src]
        check(int(e.get("amount", 0)) == 30, "demand per craft = 30 clay", state)
        check(is_equal_approx(float(e.get("interval", 0.0)), craft_time),
            "demand interval = recipe time (%s sec)" % str(craft_time), state)

    var supply: Dictionary = city.get_building_planned_production()
    check(not supply.get("bricks", {}).is_empty(), "planned brick output exists", state)
    for src in supply.get("bricks", {}):
        var e2: Dictionary = supply["bricks"][src]
        check(int(e2.get("amount", 0)) == 10, "output per craft = 10 bricks", state)
        check(is_equal_approx(float(e2.get("interval", 0.0)), craft_time),
            "output interval = recipe time (%s sec)" % str(craft_time), state)

    # The planned consumption map (read by the "Resources" tab tooltip) must
    # receive the same interval from the building demand.
    var wm = load("res://scripts/worker_manager.gd").new()
    var wm_clay: Dictionary = wm.get_planned_consumption_map().get("clay", {})
    var found_building := false
    for src in wm_clay:
        var e3: Dictionary = wm_clay[src]
        if int(e3.get("amount", 0)) == 30:
            found_building = true
            check(is_equal_approx(float(e3.get("interval", 0.0)), craft_time),
                "the planned consumption map carries interval = recipe time", state)
    check(found_building, "the building demand made it into the planned consumption map", state)
    wm.free()

    # --- 6. Slot progress helpers ---
    city.city_built_buildings[0]["slots"] = ["bricks"]
    # The state is set directly in the container: get_slot_progress() is a
    # COMPUTED getter (ratio * craft_time), so writing to its result would land
    # in a fresh temporary Array and silently vanish. So we prepare the
    # half-full container (15 of 30 clay, 2.5 of 5 sec) explicitly.
    var cont = city.get_slot_container(0, 0)
    cont.elapsed = 2.5
    cont.ingredient_slots[0]["filled"] = 15
    check(abs(city.get_slot_progress_ratio(0, 0) - 0.5) < 0.001,
        "ratio = min(fullness, time/craft_time) = min(15/30, 2.5/5) = 0.5", state)
    check(abs(city.get_slot_progress_value(0, 0) - 2.5) < 0.001,
        "legacy get_slot_progress_value = ratio * craft_time = 2.5", state)
    city.reset_slot_progress(0, 0)
    check(is_zero_approx(city.get_slot_progress_value(0, 0)),
        "reset_slot_progress zeroes the value accumulated by the container", state)
    city.city_built_buildings[0]["slots"] = ["empty"]
    check(is_equal_approx(city.get_slot_craft_time(0, 0), 0.0),
        "an empty slot has no craft time", state)
    check(is_equal_approx(city.get_slot_progress_ratio(0, 0), 0.0),
        "ratio of an empty slot = 0", state)

    main_map.queue_free()

    if state["failed"]:
        print("CRAFT TIME TEST FAILED")
        quit(1)
    else:
        print("CRAFT TIME TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
