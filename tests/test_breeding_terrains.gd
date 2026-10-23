# Headless test for additional breeding locations (`breeding`):
#   godot --headless --path . --script res://tests/test_breeding_terrains.gd
#
# Checks the real JSON data and the shared MapHelpers.can_breed_resource_on_tile:
# base locations are preserved, breeding groups work with AND/OR semantics,
# invalid combinations do not pass, breedable=false takes priority, and
# get_buildable_improvement offers an improvement on an additional terrain.
extends SceneTree

# Hang watchdog: without it, an interrupted _run() coroutine looks from the
# outside like eternal silence. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # new_game() loads all the real data/*.json and resets CityData.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var gdata = get_root().get_node("GameData")
    var city = get_root().get_node("CityData")
    var map_helpers = load("res://scripts/map_helpers.gd")

    if WATCHDOG.wants_case("base_locations"):
        _test_base_locations(map_helpers, state)
    if WATCHDOG.wants_case("oasis_resources"):
        _test_oasis_resources(map_helpers, gdata, state)
    if WATCHDOG.wants_case("animal_locations"):
        _test_animal_locations(map_helpers, state)
    if WATCHDOG.wants_case("negative_and_invalid_cases"):
        _test_negative_and_invalid_cases(map_helpers, gdata, state)
    if WATCHDOG.wants_case("buildable_improvement"):
        _test_buildable_improvement(map_helpers, city, state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("BREEDING TERRAINS TEST FAILED")
        quit(1)
    else:
        print("BREEDING TERRAINS TEST OK")
        quit(0)

func _test_base_locations(map_helpers, state: Dictionary) -> void:
    check(map_helpers.can_breed_resource_on_tile("grapes_plant", _tile("plain", "none")),
            "grapes_plant must still breed on plains without cover", state)
    check(map_helpers.can_breed_resource_on_tile("cows", _tile("plain", "temperate_rainforest_sparse")),
            "cows must still breed on plains with sparse forest", state)
    check(not map_helpers.can_breed_resource_on_tile("grapes_plant", _tile("plain", "temperate_rainforest")),
            "grapes_plant must not breed on a disallowed cover", state)

func _test_oasis_resources(map_helpers, gdata, state: Dictionary) -> void:
    var oasis_resource_ids := [
        # Fruits.
        "grapes_plant", "olives_plant", "fig_plant",
        # Food plants.
        "wheat_field", "barley_field", "rice_field", "corn_field", "millet_field",
        "sorghum_field", "amaranth_field", "bean_field", "cowpea_field",
        "lentil_field", "chickpea_field"
    ]
    for res_id in oasis_resource_ids:
        var data: Dictionary = gdata.raw_resources.get(res_id, {})
        check(not data.is_empty(), "resource %s must exist in the data" % res_id, state)
        check(data.has("breeding"), "resource %s must have a breeding field" % res_id, state)
        check(map_helpers.can_breed_resource_on_tile(res_id, _tile("sandy_desert", "oasis")),
                "%s must breed in a sandy desert oasis" % res_id, state)
        check(map_helpers.can_breed_resource_on_tile(res_id, _tile("rocky_desert", "oasis")),
                "%s must breed in a rocky desert oasis" % res_id, state)
        check(not map_helpers.can_breed_resource_on_tile(res_id, _tile("sandy_desert", "none")),
                "%s must not automatically breed on bare sandy desert" % res_id, state)

func _test_negative_and_invalid_cases(map_helpers, gdata, state: Dictionary) -> void:
    check(not map_helpers.can_breed_resource_on_tile("grapes_plant", _tile("plain", "oasis")),
            "grapes_plant must not breed on plains with oasis cover", state)
    check(not map_helpers.can_breed_resource_on_tile("sheep", _tile("sandy_desert", "none")),
            "sheep must not breed on bare sandy desert", state)
    check(not map_helpers.can_breed_resource_on_tile("buffalo", _tile("swamp", "none")),
            "buffalo must not automatically breed on marsh without reeds", state)
    check(not map_helpers.can_breed_resource_on_tile("freshwater_fish", _tile("lake", "none")),
            "fish with breedable=false must not breed even in a suitable water terrain", state)

    # Check the strict handling of malformed/unknown conditions.
    var invalid_id := "__test_invalid_breeding_resource"
    var valid_data := {
        "id": invalid_id,
        "breedable": true,
        "improved_by": "pasture",
        "allowed_terrain": [],
        "allowed_cover": [],
        "breeding": [ [ { "terrain": "mountain" } ] ]
    }
    gdata.raw_resources[invalid_id] = valid_data
    check(map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "temperate_rainforest")),
            "a terrain-only condition must work", state)
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("plain", "none")),
            "an empty base location must not be accidentally allowed", state)

    var array_data := valid_data.duplicate(true)
    array_data["breeding"] = [ [ { "terrain": [ "mountain", "hill" ] },
                                 { "cover": [ "temperate_rainforest", "none" ] } ] ]
    gdata.raw_resources[invalid_id] = array_data
    check(map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "temperate_rainforest")),
            "terrain and cover arrays must be supported at the same time", state)
    check(map_helpers.can_breed_resource_on_tile(invalid_id, _tile("hill", "none")),
            "the second variant of terrain and cover arrays must match", state)

    var invalid_type := valid_data.duplicate(true)
    invalid_type["breeding"] = [ [ { "terrain": 123 } ] ]
    gdata.raw_resources[invalid_id] = invalid_type
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "none")),
            "a numeric value in a breeding condition must not match", state)

    var invalid_empty := valid_data.duplicate(true)
    invalid_empty["breeding"] = [ [] ]
    gdata.raw_resources[invalid_id] = invalid_empty
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "none")),
            "an empty breeding group must not allow breeding", state)

    var invalid_unknown := valid_data.duplicate(true)
    invalid_unknown["breeding"] = [ [ { "unknown": "value" } ] ]
    gdata.raw_resources[invalid_id] = invalid_unknown
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "none")),
            "an unknown breeding key must not allow breeding", state)
    gdata.raw_resources.erase(invalid_id)

func _test_buildable_improvement(map_helpers, city, state: Dictionary) -> void:
    var old_domesticated: Array = city.domesticated_resources.duplicate()
    var old_unlocked: Array = city.unlocked_technologies.duplicate()
    city.domesticated_resources = ["grapes_plant"]
    city.unlocked_technologies.append("winegrowing")

    var oasis_tile := _tile("sandy_desert", "oasis")
    var plain_tile := _tile("plain", "none")
    var wrong_tile := _tile("sandy_desert", "none")
    check(map_helpers.get_buildable_improvement(oasis_tile) == "vineyard",
            "a vineyard must be offered on the oasis for breeding grapes", state)
    check(map_helpers.get_buildable_improvement(plain_tile) == "vineyard",
            "the usual vineyard offer must be preserved on plains", state)
    check(map_helpers.get_buildable_improvement(wrong_tile) == "",
            "no improvement must be offered on an unsuitable terrain", state)

    city.domesticated_resources = old_domesticated
    city.unlocked_technologies = old_unlocked

func _tile(terrain: String, cover: String) -> Dictionary:
    return {
        "terrain": terrain,
        "cover": cover,
        "resource": null,
        "crop_bred": null,
        "improvement": null
    }

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        push_error("ASSERT: " + message)
        print("ASSERT FAILED: ", message)
        state["failed"] = true

func _test_animal_locations(map_helpers, state: Dictionary) -> void:
    # Mountains are an additional location for sheep and goats.
    check(map_helpers.can_breed_resource_on_tile("sheep", _tile("mountain", "none")),
            "sheep must breed in the mountains", state)
    check(map_helpers.can_breed_resource_on_tile("goats", _tile("mountain", "temperate_rainforest")),
            "goats must breed in the mountains", state)

    # Oases are additional locations for sheep, goats and bees.
    check(map_helpers.can_breed_resource_on_tile("sheep", _tile("sandy_desert", "oasis")),
            "sheep must breed in the oasis", state)
    check(map_helpers.can_breed_resource_on_tile("goats", _tile("rocky_desert", "oasis")),
            "goats must breed in the oasis", state)
    check(map_helpers.can_breed_resource_on_tile("bee", _tile("sandy_desert", "oasis")),
            "bees must breed in the oasis", state)

    # Desert and marsh additional groups.
    check(map_helpers.can_breed_resource_on_tile("ostrich", _tile("sandy_desert", "none")),
            "ostriches must breed on sandy desert", state)
    check(map_helpers.can_breed_resource_on_tile("buffalo", _tile("swamp", "reeds")),
            "buffalo must breed in marsh with reeds", state)
    check(map_helpers.can_breed_resource_on_tile("duck", _tile("marsh", "reeds")),
            "ducks must breed on marsh with reeds", state)
    check(map_helpers.can_breed_resource_on_tile("goose", _tile("swamp", "reeds")),
            "geese must breed in marsh with reeds", state)
    check(map_helpers.can_breed_resource_on_tile("goose", _tile("swamp", "none")),
            "the cover array must allow geese marsh without reeds", state)
    check(map_helpers.can_breed_resource_on_tile("goose", _tile("marsh", "none")),
            "the cover array must allow geese marsh without reeds", state)
