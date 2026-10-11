# Headless test for the food dynamics of the population:
#   godot --headless --path . --script res://tests/test_food_population_dynamics.gd
#
# Two rules are covered, both of which used to be broken:
#
#   1. The population eats ONE city-wide ration of (population - 1) × food_per_citizen per tick,
#      drawn from the shared food pool. The plan stores that demand under EVERY food product
#      (any of them can satisfy it), so a per-product sum would multiply it by the number of
#      the foods. The top bar sums the plan (city_ui._planned_food_per_sec) and must count the
#      demand once: 32 foods × 10 units is 320, not 10.
#
#   2. A city that feeds itself through a road must not starve. The road-delivered production is
#      credited to production_rates on ARRIVAL, and reset_counters() clears those arrivals before
#      _check_population_change() runs, so the ACTUAL production reads as zero. The famine falls
#      back to the planned output (the same fallback the top bar uses), so the newborn survives
#      the tick that empties the warehouse.
extends SceneTree

# Without the watchdog a broken coroutine inside _run() looks like a silent hang
# from the outside. See tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const SRC_POP_FOOD := "@pop_food"

var _city = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    get_root().get_node("SaveManager").new_game()
    _city = get_root().get_node("CityData")
    var game_data = get_root().get_node("GameData")

    # The autoloads join the tree on the first frames; _check_population_change() reaches the
    # tree through get_tree() (it looks the map up for the removal of the dead), so it needs
    # the node to be inside the tree already.
    await process_frame
    await process_frame

    # --- 1. The population demand is counted once, not once per food product ---
    var food_products: Array = []
    for pid in game_data.products.keys():
        if game_data.products[pid].get("category") == "food":
            food_products.append(str(pid))
    check(food_products.size() > 1, "the data must have several foods for this check", state)

    var eaters := 1
    var per_citizen := int(_city.food_per_citizen)
    var demand := eaters * per_citizen

    # The plan as resources_tab._update_planned_consumption_map builds it: the full demand
    # written under every food product.
    var plan: Dictionary = {}
    var pool: Dictionary = {}
    for pid in food_products:
        pool[pid] = true
        plan[pid] = {
            SRC_POP_FOOD: {
                "amount": demand,
                "interval": _city.SIMULATION_TICK,
                "count": eaters,
                "is_group": false,
                "group_name": "",
                "is_population": true,
            }
        }

    var city_ui = load("res://scripts/city_ui.gd").new()
    var planned_cons: int = city_ui._planned_food_per_sec(plan, pool)
    check(planned_cons == demand,
            "the planned food expense must be the single ration %d, got %d" % [demand, planned_cons],
            state)
    city_ui.free()

    # --- 2a. A road-fed city: the actual production was wiped, the plan carries it ---
    _city.city_food_pool = {"wheat": true}
    _city.city_storage = {"wheat": 0}
    _city.consumption_rates = {"wheat": demand}
    _city.production_rates = {} # the arrivals were cleared by reset_counters()
    _city.improvement_planned_production = {
        "wheat": {"@farm": {"amount": demand, "count": 1, "interval": 0.0}}
    }
    _city.total_population = 2
    _city.idle_population = 1
    _city._check_population_change()
    check(_city.total_population == 2,
            "a city that produces food through a road must not starve", state)
    check(_city.idle_population == 1, "nobody must die while the city produces food", state)

    # --- 2b. No producer at all: the famine must still fire on a drained warehouse ---
    _city.improvement_planned_production = {}
    _city.total_population = 2
    _city.idle_population = 1
    _city._check_population_change()
    check(_city.total_population == 1,
            "a city without any food production must lose exactly one resident", state)

    if state["failed"]:
        print("FOOD POPULATION DYNAMICS TEST FAILED")
        quit(1)
    else:
        print("FOOD POPULATION DYNAMICS TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    push_error("ASSERT: " + message)
    print("ASSERT FAILED: ", message)
    state["failed"] = true
