# Headless test for the alternative ingredients in crafting recipes
# (arrays of dictionaries in the "resources" field, see GameData.gd):
#   godot --headless --path . --script res://tests/test_craft_alternatives.gd
#
# Checks:
#   1) parse_craft_resources() normalizes all the admissible forms into an
#      array of OR-groups; the classical dictionary stays compatible;
#   2) the container consumes an OR-group from ONE variant only (no mixing),
#      while the AND-terms are accumulated in parallel;
#   3) the AND+OR recipe "[iron 20 OR meteorite_iron 20] AND charcoal 10"
#      completes on any of the alternatives, with the base ingredient intact;
#   4) the trade pools of the towns (town_economy) treat an OR-group as closed
#      by one member and read the readiness by OR-groups, not by raw keys.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _done := false

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

    var gd = get_root().get_node("GameData")
    gd.load_all_data()
    var city = get_root().get_node("CityData")

    _test_normalization(gd, state)
    _test_container_consumes_one_variant(gd, city, state)
    _test_recipe_completes_on_alternative(city, state)
    _test_town_economy_or_group(state)

    if state["failed"]:
        print("CRAFT ALTERNATIVES TEST FAILED")
        quit(1)
    else:
        print("CRAFT ALTERNATIVES TEST OK")
        quit(0)


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true


# --- 1. Normalization of the "resources" field ---
func _test_normalization(gd, state: Dictionary) -> void:
    # The classical dictionary: each key is a separate one-variant OR-group.
    var classic = gd.parse_craft_resources({"iron": 20, "charcoal": 10})
    check(classic.size() == 2, "the dictionary form gives one OR-group per key", state)
    check(classic[0][0]["key"] == "iron" and int(classic[0][0]["amount"]) == 20,
        "the first OR-group keeps the key and the amount", state)

    # The explicit OR-group: [ { iron: 20 }, { meteorite_iron: 20 } ] — one term.
    var or_form = gd.parse_craft_resources([
        [ {"iron": 20}, {"meteorite_iron": 20}],
        {"charcoal": 10}
    ])
    check(or_form.size() == 2, "the AND+OR form keeps both terms", state)
    check(or_form[0].size() == 2, "the first term is a two-variant OR-group", state)
    var keys := [str(or_form[0][0]["key"]), str(or_form[0][1]["key"])]
    check("iron" in keys and "meteorite_iron" in keys,
        "both alternatives are kept in the OR-group", state)
    check(or_form[1][0]["key"] == "charcoal" and int(or_form[1][0]["amount"]) == 10,
        "the AND-term (charcoal) stays a one-variant group", state)

    # The alternative ingredient of the real data: iron_tools / iron_weapons.
    var recipe = gd.craft_alternatives(gd.crafts.filter(
        func(c): return str(c.get("id", "")) == "iron_tools")[0])
    check(recipe.size() == 2, "iron_tools has two AND-terms", state)
    check(recipe[0].size() == 2, "the first term of iron_tools is an OR-group", state)

    # A non-positive and a missing amount are dropped.
    var filtered = gd.parse_craft_resources({"iron": 0, "charcoal": 10})
    check(filtered.size() == 1, "an amount of 0 does not create an ingredient", state)

    # The flat ids in a term are not supported (an id without an amount is
    # unusable) — they are silently skipped.
    var bare = gd.parse_craft_resources([["iron"], {"charcoal": 5}])
    check(bare.size() == 1, "a bare id without an amount is skipped", state)


# --- 2. The container takes an OR-group from ONE variant only ---
func _test_container_consumes_one_variant(_gd, city, state: Dictionary) -> void:
    var recipe = {
        "id": "test_alternatives",
        "time": 2.0,
        "resources": [
            [ {"iron": 10}, {"meteorite_iron": 10}],
            {"charcoal": 4}
        ],
        "result": {"iron_tools": 5}
    }
    var container = load("res://scripts/craft_container.gd").new(recipe)
    check(container.ingredient_slots.size() == 2,
        "two AND-terms give two slots", state)
    var or_slot: Dictionary = container.ingredient_slots[0]
    check(str(or_slot.get("kind", "")) == "alternatives",
        "the first slot is an OR-group of the variants", state)
    check(or_slot.get("variants", []).size() == 2, "two variants in the OR-slot", state)
    var and_slot: Dictionary = container.ingredient_slots[1]
    check(str(and_slot.get("kind", "")) == "single" and str(and_slot.get("pid", "")) == "charcoal",
        "the AND-term is an ordinary single slot", state)

    # Both alternatives in the storage at once: the first variant (iron) must
    # be consumed, meteorite_iron must remain untouched.
    city.city_storage.clear()
    city.add_to_storage("iron", 20, "common")
    city.add_to_storage("meteorite_iron", 20, "common")
    city.add_to_storage("charcoal", 10, "common")
    container.tick(2.0, true, "best")
    check(int(city.city_storage.get("iron", 0)) == 10,
        "the consumed amount of the first variant = the required 10", state)
    check(int(city.city_storage.get("meteorite_iron", 0)) == 20,
        "the second alternative is not touched while the first is available", state)
    check(int(city.city_storage.get("charcoal", 0)) == 6,
        "the AND-term (charcoal) is consumed in parallel", state)

    # After the reset the OR-slot fills again from the first variant.
    container.reset()
    city.city_storage.clear()
    city.add_to_storage("iron", 5, "common")
    city.add_to_storage("meteorite_iron", 15, "common")
    city.add_to_storage("charcoal", 10, "common")
    container.tick(2.0, true, "best")
    check(int(city.city_storage.get("iron", 0)) == 0,
        "without enough of the first variant it is consumed first (5 of 10)", state)
    check(int(city.city_storage.get("meteorite_iron", 0)) == 10,
        "the deficit of the first variant is covered by the second (OR semantics)", state)


# --- 3. The full cycle "[iron OR meteorite_iron] AND charcoal" through do_tick ---
func _test_recipe_completes_on_alternative(city, state: Dictionary) -> void:
    var main_map := Node.new()
    main_map.name = "MainMap"
    get_root().add_child(main_map)
    var tm = load("res://scripts/townsfolk_manager.gd").new()
    tm.name = "TownsfolkManager"
    main_map.add_child(tm)

    city.city_built_buildings = [ {"id": "forge", "slots": ["iron_tools"], "quality_priority": "best"}]
    city.total_population = 1
    city.idle_population = 0
    tm.assigned_buildings = {"0": true}

    # Only meteorite iron: the first alternative is empty, the craft must go
    # through the second one. iron_tools: 20 units per 5 sec = 4/sec, charcoal 20/5 = 4/sec.
    city.city_storage.clear()
    city.add_to_storage("meteorite_iron", 20, "common")
    city.add_to_storage("charcoal", 20, "common")
    for _i in range(5):
        city.do_tick()
    check(int(city.get_storage_amount("meteorite_iron")) == 0,
        "all 20 units of meteorite_iron are consumed in 5 sec (4/sec)", state)
    check(int(city.get_storage_amount("charcoal")) == 0,
        "all 20 units of charcoal are consumed in 5 sec", state)
    check(int(city.get_storage_amount("iron_tools")) == 10,
        "the craft is completed on the second alternative: 10 iron_tools per cycle", state)

    # The second cycle on the ordinary iron: adding the materials without
    # clearing the storage (clearing would also wipe the produced iron_tools).
    city.add_to_storage("iron", 20, "common")
    city.add_to_storage("charcoal", 20, "common")
    for _i in range(5):
        city.do_tick()
    check(int(city.get_storage_amount("iron_tools")) == 20,
        "the second cycle consumed the ordinary iron and gave 10 more iron_tools", state)

    # The AND-logic: the slots fill independently, so without charcoal the
    # metal is reserved by the container but no result is ever released and the
    # cycle never completes (this is the same "freeze" as in test_craft_time).
    city.city_storage.clear()
    city.add_to_storage("iron", 20, "common")
    for _i in range(15):
        city.do_tick()
    check(int(city.get_storage_amount("iron_tools")) == 0,
        "without the AND-term (charcoal) the result is not released", state)

    main_map.queue_free()


# --- 4. The trade pools of the towns ---
func _test_town_economy_or_group(state: Dictionary) -> void:
    var te = load("res://scripts/town_economy.gd")

    # A pool with one of the alternatives closes the OR-term.
    var craft := {
        "id": "test_or",
        "resources": [[ {"iron": 10}, {"meteorite_iron": 10}], {"charcoal": 5}],
        "result": {"iron_tools": 5}
    }
    check(te.is_recipe_ready({
        "id": "test_or",
        "resources": [[ {"iron": 10}, {"meteorite_iron": 10}]]
    }, {"meteorite_iron": true}),
        "an OR-group closes with any one variant", state)
    check(not te.is_recipe_ready({
        "id": "test_or",
        "resources": [[ {"iron": 10}, {"meteorite_iron": 10}]]
    }, {"copper": true}),
        "an OR-group does not close with an outside product", state)

    # The readiness is counted by the OR-groups: one closed group out of two = 50.
    # (_readiness_of and _missing_representatives are the module's internals,
    # but the tests in this project verify exactly the module logic through them.)
    var half_pool := {"meteorite_iron": true}
    check(te._readiness_of(craft, half_pool) == 50,
        "the readiness of a two-term recipe with one closed OR-group = 50", state)

    # The missing representative of an unclosed OR-group — its first variant.
    var missing: Array = te._missing_representatives(craft, {"charcoal": true})
    check(missing == ["iron"],
        "the first variant of the OR-group is chosen as the missing one", state)
