# Headless test of the water production bonuses:
#   godot --headless --path . --script res://tests/test_water_production_bonus.gd
#
# data/modifiers.json holds two branches of the water mechanic. Each branch has
# two id maps — production_multiplier for IMPROVEMENTS of the map and
# building_production_multiplier for BUILDINGS of the city — and CityData reads
# both through one resolver (get_water_production_modifiers). The result feeds
# the improvement preview/tooltip, the building tooltip, the Effects tab,
# get_building_planned_production() and do_tick().
#
#   fresh_water — irrigation / water as a material, gated by water access only;
#   water_power — water-driven machinery, gated by water AND the Water Wheel.
#
# Checks:
#   1. Cultivated plants are irrigated (farm, plantation); the vineyard stays
#      dry-farmed and appears in NO water table. The vineyard is a deliberate
#      design exception, not an omission.
#   2. Every improvement's UI rows agree with the data; a dry hex shows none.
#   3. The mine/quarry bonus appears only with a wet hex AND water_wheel.
#   4. City buildings resolve their own id map: the tanner takes fresh water,
#      metallurgy takes the water wheel, the Water Mill takes neither (its
#      recipe already pays for the wheel).
#   5. The city hex is the single source of water for buildings: the
#      requirement, the Effects tab and the bonuses agree.
#   6. BOTH production paths — the planned "≈" and the actual tick — apply the
#      building bonus, so the plan never promises more than the craft gives.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

const WATER_LABEL := "Fresh water access"
const WATER_TECH := "water_wheel"

# A synthetic map: the water access of the city is derived from tile_data, so a
# small grid is enough. No live map is loaded — the test stays in the fast suite.
class MapStub extends Node:
    var tile_data: Array = []
    var city_row: int = 0
    var city_col: int = 0
    var map_rows: int = 0
    var map_cols: int = 0

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    # In --script mode the autoload names are unavailable at compile time.
    var gdata = get_root().get_node("GameData")
    var cdata = get_root().get_node("CityData")
    cdata.unlocked_technologies.clear()
    await process_frame

    _test_data(gdata, state)
    _test_improvements(gdata, cdata, state)
    _test_water_power(gdata, cdata, state)
    _test_buildings(gdata, cdata, state)
    _test_city_water(gdata, cdata, state)
    _test_production_pipeline(cdata, state)

    if state["failed"]:
        print("WATER PRODUCTION BONUS TEST FAILED")
        quit(1)
    else:
        print("WATER PRODUCTION BONUS TEST OK")
        quit(0)

# --- 1. The shape of the data -------------------------------------------------
func _test_data(gdata: Node, state: Dictionary) -> void:
    var fw: Dictionary = gdata.modifiers.get("fresh_water", {})
    var wp: Dictionary = gdata.modifiers.get("water_power", {})
    check(not fw.is_empty(), "the fresh_water block is missing", state)
    check(not wp.is_empty(), "the water_power block is missing", state)
    check(str(wp.get("requires_tech", "")) == WATER_TECH,
            "water_power must be gated by the \"%s\" technology" % WATER_TECH, state)
    for field in ["production_multiplier", "building_production_multiplier"]:
        var fw_map = fw.get(field, {})
        var wp_map = wp.get(field, {})
        check(fw_map is Dictionary and not fw_map.is_empty(),
                "fresh_water.%s must not be empty" % field, state)
        check(wp_map is Dictionary and not wp_map.is_empty(),
                "water_power.%s must not be empty" % field, state)

    var fw_imp: Dictionary = fw.get("production_multiplier", {})
    var wp_imp: Dictionary = wp.get("production_multiplier", {})
    check(not fw_imp.has("vineyard") and not wp_imp.has("vineyard"),
            "the vineyard is dry-farmed: it must appear in no water table", state)
    check(fw_imp.has("farm") and fw_imp.has("plantation"),
            "both kinds of cultivated plants must be irrigated", state)
    for imp_id in ["mine", "quarry"]:
        check(not fw_imp.has(imp_id),
                "\"%s\" must not get IRRIGATION (it belongs to water_power)" % imp_id, state)
        check(wp_imp.has(imp_id),
                "\"%s\" must get the water wheel bonus" % imp_id, state)
    var fw_bld: Dictionary = fw.get("building_production_multiplier", {})
    var wp_bld: Dictionary = wp.get("building_production_multiplier", {})
    check(fw_bld.has("leatherworker_house"),
            "the tanner must get the fresh-water bonus", state)
    for building_id in ["bloomery", "smelter", "forge"]:
        check(wp_bld.has(building_id),
                "\"%s\" must get the water-driven bellows bonus" % building_id, state)
    check(not fw_bld.has("water_mill") and not wp_bld.has("water_mill"),
            "the Water Mill must not be paid twice for its wheel", state)

# --- 2. Irrigation rows of the improvements -----------------------------------
func _test_improvements(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var fw_imp: Dictionary = gdata.modifiers.get("fresh_water", {}).get(
            "production_multiplier", {})
    for imp_id in ["farm", "plantation"]:
        var expected := float(fw_imp.get(imp_id, 1.0))
        check(expected > 1.0,
                "the irrigation bonus of \"%s\" must be greater than 1" % imp_id, state)
        var dry: float = cdata.get_improvement_production_multiplier(imp_id, false)
        var wet: float = cdata.get_improvement_production_multiplier(imp_id, true)
        check(is_equal_approx(wet, dry * expected),
                "\"%s\": a wet hex multiplies the output by the data value (%.2f -> %.2f)"
                        % [imp_id, dry, wet], state)

    # No technology is researched here, so the only water rows are irrigation.
    for imp_id in gdata.improvements.keys():
        var wet_rows: Array = cdata.get_water_production_modifiers(imp_id, false, true)
        var dry_rows: Array = cdata.get_water_production_modifiers(imp_id, false, false)
        check(dry_rows.is_empty(),
                "\"%s\": a dry hex must not show any water row" % imp_id, state)
        var irrigated := _rows(wet_rows, WATER_LABEL)
        if fw_imp.has(imp_id):
            check(irrigated.size() == 1,
                    "\"%s\": a wet hex must show exactly one fresh-water row (got %d)"
                            % [imp_id, irrigated.size()], state)
            if not irrigated.is_empty():
                check(is_equal_approx(float(irrigated[0].get("multiplier", 0.0)),
                            float(fw_imp[imp_id])),
                        "\"%s\": the row must carry the multiplier from the data" % imp_id,
                        state)
            check(wet_rows.size() == 1,
                    "\"%s\": no irrigation means no other water row before the wheel" % imp_id,
                    state)
        else:
            check(wet_rows.is_empty(),
                    "\"%s\": an improvement outside the water tables must get no bonus"
                            % imp_id, state)

# --- 3. The Water Wheel gate --------------------------------------------------
func _test_water_power(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var wp_imp: Dictionary = gdata.modifiers.get("water_power", {}).get(
            "production_multiplier", {})
    # Water without the technology is irrigation, not motive power.
    for imp_id in ["mine", "quarry"]:
        check(cdata.get_water_production_modifiers(imp_id, false, true).is_empty(),
                "\"%s\": water alone must not turn a wheel" % imp_id, state)

    cdata.unlocked_technologies.append(WATER_TECH)
    # cdata is a Node here, so its methods return Variant: the type is explicit.
    var tech_name: String = str(cdata.get_tech_name(WATER_TECH))
    for imp_id in ["mine", "quarry"]:
        var wet: Array = cdata.get_water_production_modifiers(imp_id, false, true)
        check(wet.size() == 1,
                "\"%s\": a wet hex with the wheel must show exactly one row (got %d)"
                        % [imp_id, wet.size()], state)
        if not wet.is_empty():
            check(is_equal_approx(float(wet[0].get("multiplier", 0.0)), float(wp_imp[imp_id])),
                    "\"%s\": the row must carry the water_power multiplier" % imp_id, state)
            check(str(wet[0].get("label", "")).contains(tech_name),
                    "\"%s\": the row must name the technology that unlocked it" % imp_id, state)
            check(str(wet[0].get("bonus", "")) == tech_name,
                    "\"%s\": the Effects tab must see the name of the bonus" % imp_id, state)
        check(cdata.get_water_production_modifiers(imp_id, false, false).is_empty(),
                "\"%s\": a dry hex gets no water power even with the wheel" % imp_id, state)

    # The panel/tooltip of the hex uses the same rows as the production tick.
    var mine_rows: Array = cdata.get_improvement_production_modifiers("mine", true)
    check(_rows(mine_rows, tech_name).size() == 1,
            "the mine tooltip must show the water wheel row", state)
    var wet_mult: float = cdata.get_improvement_production_multiplier("mine", true)
    var dry_mult: float = cdata.get_improvement_production_multiplier("mine", false)
    check(is_equal_approx(wet_mult, dry_mult * float(wp_imp["mine"])),
            "the mine output must be multiplied by the water_power value", state)

# --- 4. City buildings use their own id map -----------------------------------
func _test_buildings(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var fw_bld: Dictionary = gdata.modifiers.get("fresh_water", {}).get(
            "building_production_multiplier", {})
    var wp_bld: Dictionary = gdata.modifiers.get("water_power", {}).get(
            "building_production_multiplier", {})

    # The tanner works with water; no technology is needed.
    var tanner: Array = cdata.get_building_production_modifiers("leatherworker_house", true)
    check(tanner.size() == 1,
            "a tanner with water must show exactly one bonus row (got %d)" % tanner.size(),
            state)
    if not tanner.is_empty():
        check(str(tanner[0].get("label", "")).contains(WATER_LABEL),
                "the tanner's row must be the fresh-water row", state)
        check(is_equal_approx(float(tanner[0].get("multiplier", 0.0)),
                    float(fw_bld["leatherworker_house"])),
                "the tanner's row must carry the multiplier from the data", state)
    check(is_equal_approx(
                cdata.get_building_production_multiplier("leatherworker_house", true),
                float(fw_bld["leatherworker_house"])),
            "the tanner's production multiplier must come from fresh_water", state)
    check(cdata.get_building_production_modifiers("leatherworker_house", false).is_empty(),
            "a tanner without water must have no water bonus", state)

    # Metallurgy needs the wheel. The technology is unlocked by the previous part.
    var bloomery: Array = cdata.get_building_production_modifiers("bloomery", true)
    check(bloomery.size() == 1,
            "a bloomery with water and the wheel must show exactly one row (got %d)"
                    % bloomery.size(), state)
    if not bloomery.is_empty():
        check(is_equal_approx(float(bloomery[0].get("multiplier", 0.0)),
                    float(wp_bld["bloomery"])),
                "the bloomery's row must carry the water_power multiplier", state)
    cdata.unlocked_technologies.erase(WATER_TECH)
    check(cdata.get_building_production_modifiers("bloomery", true).is_empty(),
            "water without the wheel must not drive the bellows", state)
    cdata.unlocked_technologies.append(WATER_TECH)

    # The Water Mill pays for its wheel through its own recipe, not a multiplier.
    check(cdata.get_building_production_modifiers("water_mill", true).is_empty(),
            "the Water Mill must not receive a second bonus for the same wheel", state)
    check(cdata.get_building_production_modifiers("pottery_workshop", true).is_empty(),
            "a building outside the water tables must get no water bonus", state)

# --- 5. The city hex is the source of water for the buildings -----------------
func _test_city_water(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var stub := MapStub.new()
    stub.name = "MainMap"
    var tiles: Array = []
    for _r in 5:
        var row: Array = []
        for _c in 7:
            row.append({"terrain": "boreal_plain", "cover": "none"})
        tiles.append(row)
    tiles[2][2]["is_city"] = true
    stub.tile_data = tiles
    stub.city_row = 2
    stub.city_col = 2
    stub.map_rows = 5
    stub.map_cols = 7
    get_root().add_child(stub)

    check(not cdata.has_city_fresh_water(),
            "a city on a dry hex must have no water", state)
    check(not bool(cdata.check_building_additional_req("water_mill").get("ok", true)),
            "the Water Mill must not be buildable without water", state)

    tiles[2][3]["terrain"] = "lake" # a direct source next to the city
    check(cdata.get_city_water_access() == "direct",
            "a lake next to the city must give direct access", state)
    check(cdata.has_city_fresh_water(), "the city must see the lake", state)
    check(bool(cdata.check_building_additional_req("water_mill").get("ok", false)),
            "the Water Mill must be buildable with city water", state)

    # The Effects tab lists only bonuses on BUILT buildings, one row per bonus.
    cdata.city_built_buildings = [
        {"id": "leatherworker_house", "slots": ["leather"]},
        {"id": "bloomery", "slots": ["iron"]},
        {"id": "pottery_workshop", "slots": ["bricks"]},
    ]
    var env: Array = []
    for effect in cdata.get_city_effects():
        if str(effect.get("group", "")) == "environment":
            env.append(effect)
    check(env.size() == 3,
            "the Effects tab must list the water access, the tanner and the bloomery (got %d)"
                    % env.size(), state)
    var named := 0
    for effect in env:
        var effect_name := str(effect.get("name", ""))
        if effect_name == gdata.get_building_display_name("leatherworker_house") \
                or effect_name == gdata.get_building_display_name("bloomery"):
            named += 1
            check(str(effect.get("value", "")) == "+25%",
                    "the effect must show the size of the bonus (got \"%s\")"
                            % str(effect.get("value", "")), state)
    check(named == 2, "both built workshops must appear in the Effects tab", state)

    cdata.city_built_buildings.clear()
    # Remove it at once: do_tick() resolves "MainMap" by name and would find a
    # queued-but-still-alive stub first, with no TownsfolkManager under it.
    stub.free()

# --- 6. Both production paths apply the building bonus ------------------------
func _test_production_pipeline(cdata: Node, state: Dictionary) -> void:
    var stub := MapStub.new()
    stub.name = "MainMap"
    var tiles: Array = []
    for _r in 5:
        var row: Array = []
        for _c in 7:
            row.append({"terrain": "boreal_plain", "cover": "none"})
        tiles.append(row)
    tiles[2][2]["is_city"] = true
    stub.tile_data = tiles
    stub.city_row = 2
    stub.city_col = 2
    stub.map_rows = 5
    stub.map_cols = 7
    get_root().add_child(stub)
    var tm = load("res://scripts/townsfolk_manager.gd").new()
    tm.name = "TownsfolkManager"
    stub.add_child(tm)
    tm.assigned_buildings = {"0": true}
    cdata.total_population = 1
    cdata.idle_population = 0

    _prepare_tanner(cdata)
    var dry_plan := _planned_leather(cdata)
    tiles[2][3]["terrain"] = "lake"
    var wet_plan := _planned_leather(cdata)
    check(wet_plan > dry_plan,
            "the planned output of a tanner with water must be higher (%d -> %d)"
                    % [dry_plan, wet_plan], state)
    check(wet_plan == int(round(float(dry_plan) * 1.25)),
            "the planned output must use the fresh_water multiplier (dry %d, wet %d)"
                    % [dry_plan, wet_plan], state)

    # The actual tick must not promise less than the plan: four seconds is one
    # full cycle of the leather recipe (10 hides -> 10 leather).
    var wet_amount := _run_tanner(cdata)
    tiles[2][3]["terrain"] = "boreal_plain"
    var dry_amount := _run_tanner(cdata)
    check(wet_amount > dry_amount,
            "do_tick() must apply the same water bonus as the plan (%d -> %d)"
                    % [dry_amount, wet_amount], state)

    cdata.city_built_buildings.clear()
    # Remove it at once: do_tick() resolves "MainMap" by name and would find a
    # queued-but-still-alive stub first, with no TownsfolkManager under it.
    stub.free()

func _prepare_tanner(cdata: Node) -> void:
    cdata.city_storage.clear()
    cdata.add_to_storage("hide", 200, "common")
    cdata.city_built_buildings = [
        {"id": "leatherworker_house", "slots": ["leather"], "quality_priority": "best"}
    ]

func _planned_leather(cdata: Node) -> int:
    var plan: Dictionary = cdata.get_building_planned_production()
    var total := 0
    for entry in plan.get("leather", {}).values():
        total += int(entry.get("amount", 0))
    return total

func _run_tanner(cdata: Node) -> int:
    _prepare_tanner(cdata)
    for _i in 4:
        cdata.do_tick()
    return cdata.get_storage_amount("leather")

# The rows of the UI whose label mentions a source (the fresh-water caption or
# the name of a technology).
func _rows(rows: Array, needle: String) -> Array:
    var result: Array = []
    for row in rows:
        if str(row.get("label", "")).contains(needle):
            result.append(row)
    return result

func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
