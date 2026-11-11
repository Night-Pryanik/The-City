extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")
const TECH := "limestone_burning"
const KILN := "lime_kilns"
const DEPOSIT := "alunite_deposit"
const ALLOWED_TERRAINS := ["hill", "mountain", "rocky_desert"]
const ALLOWED_COVERS := [
    "none", "temperate_rainforest_sparse", "temperate_dry_forest_sparse",
    "temperate_rainforest", "temperate_dry_forest",
]
const TANNING_AGENTS := [
    "oak_bark", "chestnut_bark", "walnuts", "galls", "campeche_wood",
    "sumac_leaves", "quebracho_wood", "alum",
]
const FIELD_SIZE := 7
const CITY_COORD := 3

var _done := false
var _failed := false

func _initialize() -> void:
    WATCHDOG.arm(self)

func _process(_delta: float) -> bool:
    if not _done:
        _done = true
        _run()
    return true

func _run() -> void:
    # Pin only the runtime locale; never write the player's language setting.
    TranslationServer.set_locale("en")
    var gd = root.get_node("GameData")
    gd.load_all_data()
    var city = root.get_node("CityData")
    city.setup()
    city.unlocked_technologies.clear()
    city.ignore_tech_requirements = false

    _test_records(gd, city)
    _test_placement(gd)
    # Research runs before the production-only MainMap fixture exists.
    _test_availability(gd, city)
    _test_production(city)

    if _failed:
        print("MINERAL FIRING TEST FAILED")
        quit(1)
    else:
        print("MINERAL FIRING TEST OK")
        quit(0)

func _record(records: Array, id: String) -> Dictionary:
    for record in records:
        if str(record.get("id", "")) == id:
            return record
    return {}

func _test_records(gd: Node, city: Node) -> void:
    var deposit: Dictionary = gd.raw_resources.get(DEPOSIT, {})
    _check(not deposit.is_empty(), "alunite_deposit exists in the raw-resource registry")
    _check(str(deposit.get("type", "")) == "raw", "the deposit is a raw resource")
    _check(str(deposit.get("improved_by", "")) == "quarry", "the deposit is worked by quarry")
    _check(not gd.improvements.get("quarry", {}).is_empty(), "the referenced quarry exists")
    _check(str(deposit.get("tech_required", "")) == "mining", "the deposit requires mining")
    _check(not _record(gd.technologies, "mining").is_empty(), "the referenced mining technology exists")
    var produces: Dictionary = deposit.get("produces", {})
    _check(produces.keys() == ["alunite"] and float(produces.get("alunite", 0)) > 0.0,
        "quarrying the deposit yields alunite")
    _check_same_members(deposit.get("allowed_terrain", []), ALLOWED_TERRAINS, "deposit terrains")
    _check_same_members(deposit.get("allowed_cover", []), ALLOWED_COVERS, "deposit covers")
    for cover in ALLOWED_COVERS:
        _check(gd.covers.has(cover), "allowed cover exists: " + cover)

    for pid in ["alunite", "alum", "lime"]:
        var product: Dictionary = gd.products.get(pid, {})
        _check(not product.is_empty(), "product exists: " + pid)
        _check(str(product.get("type", "")) == "product", "product type: " + pid)
        _check(str(product.get("category", "")) == "material", "material category: " + pid)
    _check(str(gd.products.get("alunite", {}).get("unlock_tech", "")) == "",
        "alunite has no technology gate")
    _check(str(gd.products.get("alum", {}).get("unlock_tech", "")) == TECH,
        "alum is gated by the existing technology id")

    var tech := _record(gd.technologies, TECH)
    _check(not tech.is_empty(), "limestone_burning technology exists")
    _check(str(tech.get("name", "")) == "Mineral Firing", "technology source name is Mineral Firing")
    var kiln := _record(gd.buildings, KILN)
    _check(not kiln.is_empty(), "lime_kilns building exists")
    _check(str(kiln.get("name", "")) == "Kiln", "building source name is Kiln")
    _check(str(kiln.get("unlock_tech", "")) == TECH, "the kiln shares the technology gate")
    _check(kiln.get("default_recipes", []) == ["lime"], "the kiln defaults to lime")

    for recipe_id in ["alum", "lime"]:
        var recipe: Dictionary = city.get_craft_by_id(recipe_id)
        _check(not recipe.is_empty(), "real recipe exists: " + recipe_id)
        _check(recipe.get("produced_in", []) == [KILN], "recipe belongs only to kiln: " + recipe_id)
        _check(str(recipe.get("unlock_tech", "")) == TECH, "recipe technology gate: " + recipe_id)
        var ingredient := "alunite" if recipe_id == "alum" else "limestone"
        var inputs: Dictionary = recipe.get("resources", {})
        var outputs: Dictionary = recipe.get("result", {})
        _check(inputs.keys() == [ingredient] and float(inputs.get(ingredient, 0)) > 0.0,
            "recipe consumes only " + ingredient)
        _check(outputs.keys() == [recipe_id] and float(outputs.get(recipe_id, 0)) > 0.0,
            "recipe produces only " + recipe_id)
        _check(float(recipe.get("time", 0.0)) > 0.0, "recipe has a positive cycle time: " + recipe_id)
        _check(city.can_craft_in(recipe_id, KILN), "kiln accepts " + recipe_id)
    _check(not _record(gd.buildings, "pottery_workshop").is_empty(), "the other workshop exists")
    _check(not city.can_craft_in("alum", "pottery_workshop"), "pottery workshop rejects alum")

    var leather: Dictionary = city.get_craft_by_id("leather")
    _check(not leather.is_empty(), "leather recipe exists")
    _check(leather.get("resources", {}).keys() == ["hide"], "leatherworking consumes hides without tanning agents")
    _check(leather.get("result", {}).keys() == ["leather"], "leatherworking produces leather")
    _check(leather.get("produced_in", []) == ["leatherworker_house"], "leather keeps its workshop")
    _check(str(leather.get("unlock_tech", "")) == "leatherworking", "leather keeps its technology gate")

    _check(gd.product_groups.has("tannins"), "tannins group exists under its internal id")
    _check(gd.get_product_group_name("@tannins") == "Tanning Agents", "group source name is Tanning Agents")
    var members: Array = gd.product_groups.get("tannins", [])
    for pid in TANNING_AGENTS:
        _check(members.has(pid), "tanning agents include " + pid)
        _check(not gd.products.get(pid, {}).is_empty(), "tanning agent product exists: " + pid)

func _test_placement(gd: Node) -> void:
    var deposit: Dictionary = gd.raw_resources.get(DEPOSIT, {})
    if deposit.is_empty():
        return
    var generator = load("res://scripts/map_generator.gd").new()
    var resources := {DEPOSIT: deposit}
    seed(7319)
    # Real terrain variants exercise the family index, not nonexistent generic terrain ids.
    for terrain in ["prairie_hill", "prairie_mountain", "rocky_desert"]:
        _check(gd.terrains.has(terrain), "placement terrain exists: " + terrain)
        for cover in ALLOWED_COVERS:
            var tiles := _field(generator, "steppe_plain", "none")
            tiles[0][0]["terrain"] = terrain
            tiles[0][0]["cover"] = cover
            generator.place_all_resources(tiles, resources, FIELD_SIZE, FIELD_SIZE, CITY_COORD, CITY_COORD)
            _check(tiles[0][0].get("resource") == DEPOSIT,
                "deposit spawns on the only eligible hex: %s / %s" % [terrain, cover])
            _check(_resource_count(tiles) == 1, "no deposit leaks onto the surrounding plains")

    for terrain in ["steppe_plain", "lake", "sandy_desert", "temperate_swamp"]:
        _check(gd.terrains.has(terrain), "ineligible terrain exists: " + terrain)
        var tiles := _field(generator, terrain, "none")
        generator.place_all_resources(tiles, resources, FIELD_SIZE, FIELD_SIZE, CITY_COORD, CITY_COORD)
        _check(_resource_count(tiles) == 0, "deposit never spawns on " + terrain)
    for cover in ["taiga", "tropical_rainforest"]:
        _check(gd.covers.has(cover), "ineligible cover exists: " + cover)
        var tiles := _field(generator, "prairie_hill", cover)
        generator.place_all_resources(tiles, resources, FIELD_SIZE, FIELD_SIZE, CITY_COORD, CITY_COORD)
        _check(_resource_count(tiles) == 0, "deposit never spawns under " + cover)
    generator.free()

func _field(generator: Node, terrain: String, cover: String) -> Array:
    var tiles: Array = generator.init_tile_data(FIELD_SIZE, FIELD_SIZE)
    for row in tiles:
        for tile in row:
            tile["terrain"] = terrain
            tile["cover"] = cover
    return tiles

func _resource_count(tiles: Array) -> int:
    var count := 0
    for row in tiles:
        for tile in row:
            if tile.get("resource") != null:
                _check(tile["resource"] == DEPOSIT, "placement uses only the real alunite resource")
                count += 1
    return count

func _test_availability(gd: Node, city: Node) -> void:
    var recipe: Dictionary = city.get_craft_by_id("alum")
    var tech := _record(gd.technologies, TECH)
    if recipe.is_empty() or tech.is_empty():
        return
    var prerequisites: Array = tech.get("prerequisites", [])
    if not prerequisites.is_empty():
        for prerequisite in prerequisites[0]:
            city.unlocked_technologies.append(str(prerequisite))
    _check(not city.is_tech_unlocked(TECH), "mineral firing starts unresearched")
    _check(city.is_product_available("alunite"), "alunite is available before mineral firing")
    _check(not city.is_product_available("alum"), "alum product is locked before research")
    _check(not city.is_craft_available(recipe), "alum recipe is locked before research")
    _check(not city.is_building_unlocked(KILN), "kiln is locked before research")
    var started: bool = city.start_research(TECH)
    _check(started, "mineral firing research starts with its data prerequisites")
    if not started:
        return
    var science_rate: float = city.get_science_rate_per_sec()
    _check(science_rate > 0.0, "research has a positive science rate")
    if science_rate <= 0.0:
        return
    city.tick_research_science_continuous(ceil(float(city.current_research_science_cost) / science_rate))
    _check(city.is_tech_unlocked(TECH), "mineral firing research completes")
    _check(city.is_product_available("alum"), "alum product is available after research")
    _check(city.is_craft_available(recipe), "alum recipe is available after research")
    _check(city.is_building_unlocked(KILN), "kiln is available after research")
    _check(city.is_craft_available(city.get_craft_by_id("lime")), "lime remains available after research")

func _test_production(city: Node) -> void:
    var recipe: Dictionary = city.get_craft_by_id("alum")
    var input_amount := int(recipe.get("resources", {}).get("alunite", 0))
    var output_amount := int(recipe.get("result", {}).get("alum", 0))
    var cycle_time := float(recipe.get("time", 0.0))
    if input_amount <= 0 or output_amount <= 0 or cycle_time <= 0.0:
        return
    var ticks := ceili(cycle_time / float(city.SIMULATION_TICK))
    var main_map := Node.new()
    main_map.name = "MainMap"
    root.add_child(main_map)
    var tm = load("res://scripts/townsfolk_manager.gd").new()
    tm.name = "TownsfolkManager"
    main_map.add_child(tm)
    city.city_storage.clear()
    city.city_quality_detail.clear()
    city.total_population = 1
    city.idle_population = 1
    city.city_built_buildings = [{"id": KILN, "slots": ["alum"], "quality_priority": "best"}]
    city.add_to_storage("alunite", input_amount, "common")

    for _tick in range(ticks):
        city.do_tick()
    _check(city.get_storage_amount("alunite") == input_amount, "unassigned kiln does not consume alunite")
    _check(city.get_storage_amount("alum") == 0, "unassigned kiln does not produce alum")

    tm.assigned_buildings = {"0": true}
    city.idle_population = 0
    _check(tm.has_townsfolk(0), "a worker is assigned to the kiln")
    var input_before: int = city.get_storage_amount("alunite")
    var output_before: int = city.get_storage_amount("alum")
    for _tick in range(ticks):
        city.do_tick()
    _check(input_before - city.get_storage_amount("alunite") == input_amount,
        "one full cycle consumes the recipe's alunite amount")
    _check(city.get_storage_amount("alum") - output_before == output_amount,
        "one full cycle produces the recipe's alum amount")
    _check(is_zero_approx(city.get_slot_progress_ratio(0, 0)), "completed alum cycle resets its progress")

    var alum_before_starvation: int = city.get_storage_amount("alum")
    _check(city.get_storage_amount("alunite") == 0, "the full cycle exhausted the input")
    for _tick in range(ticks + 1):
        city.do_tick()
        _check(city.get_storage_amount("alum") == alum_before_starvation,
            "assigned kiln produces no further alum without raw material")
    _check(is_zero_approx(city.get_slot_progress_ratio(0, 0)), "starved kiln makes no progress")
    city.city_built_buildings.clear()
    tm.assigned_buildings.clear()
    main_map.free()

func _check_same_members(actual: Array, expected: Array, label: String) -> void:
    _check(actual.size() == expected.size(), label + " have the expected size")
    for member in expected:
        _check(actual.has(member), "%s include %s" % [label, member])

func _check(condition: bool, message: String) -> void:
    if not condition:
        _failed = true
        push_error("ASSERT: " + message)
        print("ASSERT FAILED: ", message)
