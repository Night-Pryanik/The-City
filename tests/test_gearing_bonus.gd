# Headless test of the gear production bonuses:
#   godot --headless --path . --script res://tests/test_gearing_bonus.gd
#
# The gears are a mechanic of their own: they PASS A ROTATION ON to the working
# tool, and they need no water at all — a water wheel, an animal, a treadle or a
# human arm may turn the same gears. The effect belongs to the "Cog Wheel"
# technology, so it lives in the record of that technology in the block
# "tech_modifiers" of data/modifiers.json — and unlike the record of the
# "Water Wheel" technology, it is NOT marked "requires_water".
#
# Checks:
#   1. The shape of the data: the record of the technology, its two id maps and
#      the targets it must not have.
#   2. The technology: it exists, it belongs to the antiquity, and it needs the
#      wheel and the mathematics.
#   3. The gate: without the technology there is no gear bonus at all; with it
#      the bonus comes even on a DRY hex.
#   4. The two mechanics do not mix: the water bonus still needs the water and
#      the Water Wheel, the gear bonus needs neither.
#   5. The buildings: the animal mill is driven by the gears, the hand mill is
#      driven by hands, and the water mill pays for its wheel through its own
#      recipe.
#   6. The Effects tab lists the gear bonus of a built workshop.
#   7. BOTH production paths — the planned "≈" and the actual tick — apply the
#      gear bonus, so the plan never promises more than the craft gives.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

const GEAR_TECH := "cogwheel"
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
    _test_technology(gdata, state)
    _test_gate(gdata, cdata, state)
    _test_mechanics_do_not_mix(gdata, cdata, state)
    _test_buildings(gdata, cdata, state)
    _test_city_effects(gdata, cdata, state)
    _test_production_pipeline(cdata, state)

    if state["failed"]:
        print("GEARING PRODUCTION BONUS TEST FAILED")
        quit(1)
    else:
        print("GEARING PRODUCTION BONUS TEST OK")
        quit(0)

# The record of a technology in the block "tech_modifiers" of data/modifiers.json.
func _tech_record(gdata: Node, tech_id: String) -> Dictionary:
    for mod in gdata.modifiers.get("tech_modifiers", []):
        if str(mod.get("tech_id", "")) == tech_id:
            return mod
    return {}

# The rows of the UI that come from one technology.
func _tech_rows(rows: Array, tech_id: String) -> Array:
    var result: Array = []
    for row in rows:
        if str(row.get("tech", "")) == tech_id:
            result.append(row)
    return result

# --- 1. The shape of the data -------------------------------------------------
func _test_data(gdata: Node, state: Dictionary) -> void:
    var gear: Dictionary = _tech_record(gdata, GEAR_TECH)
    check(not gear.is_empty(),
            "the \"%s\" technology has no record in tech_modifiers" % GEAR_TECH, state)
    check(not bool(gear.get("requires_water", false)),
            "the gears need no water: the record must not ask for it", state)
    check(str(gear.get("icon", "")) != "",
            "the record needs an icon for the Effects tab", state)
    check(str(gear.get("name", "")) != "",
            "the record needs a caption for the Effects tab", state)
    for field in ["production_multiplier", "building_production_multiplier"]:
        check(gear.get(field, {}) is Dictionary and not gear.get(field, {}).is_empty(),
                "the record of the \"%s\" technology must fill %s" % [GEAR_TECH, field],
                state)

    var imp: Dictionary = gear.get("production_multiplier", {})
    for imp_id in ["mine", "quarry"]:
        check(imp.has(imp_id),
                "\"%s\" must get the gear bonus (the ratchet and the geared winch)" % imp_id,
                state)
    var bld: Dictionary = gear.get("building_production_multiplier", {})
    for building_id in ["animal_mill", "hand_oil_press", "weaver_house",
            "silk_maker_house", "mason_workshop", "jeweler_house", "carpenter_workshop"]:
        check(bld.has(building_id),
                "\"%s\" must get the gear bonus" % building_id, state)
    check(not bld.has("hand_mill"),
            "the hand mill is turned by hands, not by gears", state)
    check(not bld.has("water_mill"),
            "the water mill pays for its wheel through its own recipe", state)

# --- 2. The technology --------------------------------------------------------
func _test_technology(gdata: Node, state: Dictionary) -> void:
    var tech: Dictionary = {}
    for t in gdata.technologies:
        if str(t.get("id", "")) == GEAR_TECH:
            tech = t
    check(not tech.is_empty(), "the \"%s\" technology is missing" % GEAR_TECH, state)
    if tech.is_empty():
        return
    check(str(tech.get("era", "")) == "antiquity",
            "the cog wheel belongs to the antiquity", state)
    var groups: Array = tech.get("prerequisites", [])
    var flat: Array = []
    for group in groups:
        for req in group:
            flat.append(str(req))
    check(flat.has("wheel"), "the cog wheel needs the wheel", state)
    check(flat.has("mathematics"), "the cog wheel needs the mathematics", state)
    check(flat.size() == 2,
            "the cog wheel needs the wheel AND the mathematics, nothing else", state)

# --- 3. The gate of the technology --------------------------------------------
func _test_gate(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var imp: Dictionary = _tech_record(gdata, GEAR_TECH).get(
            "production_multiplier", {})
    # Without the technology the gears are not there yet.
    check(_tech_rows(cdata.get_tech_production_modifiers("mine", false, true),
                GEAR_TECH).is_empty(),
            "the gears must give nothing before the technology is researched", state)

    cdata.unlocked_technologies.append(GEAR_TECH)
    var tech_name: String = str(cdata.get_tech_name(GEAR_TECH))
    for imp_id in ["mine", "quarry"]:
        var rows: Array = _tech_rows(cdata.get_tech_production_modifiers(imp_id, false, true),
                GEAR_TECH)
        check(rows.size() == 1,
                "\"%s\": the researched gears must show exactly one row (got %d)"
                        % [imp_id, rows.size()], state)
        if not rows.is_empty():
            check(is_equal_approx(float(rows[0].get("multiplier", 0.0)), float(imp[imp_id])),
                    "\"%s\": the row must carry the multiplier from the data" % imp_id, state)
            check(str(rows[0].get("label", "")).contains(tech_name),
                    "\"%s\": the row must name the technology that unlocked it" % imp_id, state)
            check(str(rows[0].get("bonus", "")) == tech_name,
                    "\"%s\": the Effects tab must see the name of the bonus" % imp_id, state)

    # The tooltip of the hex shows the same rows as the production tick.
    var mine_rows: Array = cdata.get_improvement_production_modifiers("mine", false)
    check(_rows(mine_rows, tech_name).size() == 1,
            "the mine tooltip must show the gear row", state)

# --- 4. The gear bonus and the water bonus are two mechanics -------------------
func _test_mechanics_do_not_mix(gdata: Node, cdata: Node, state: Dictionary) -> void:
    # The water-driven machinery asks for the water; the gears do not.
    check(bool(_tech_record(gdata, WATER_TECH).get("requires_water", false)),
            "the water wheel needs the running water", state)
    check(not bool(_tech_record(gdata, GEAR_TECH).get("requires_water", false)),
            "the cog wheel needs no water", state)

    # A dry hex with the gears: the gear row is there, the water row is not.
    var dry: Array = cdata.get_improvement_production_modifiers("mine", false)
    var tech_name: String = str(cdata.get_tech_name(GEAR_TECH))
    check(_rows(dry, tech_name).size() == 1,
            "a dry mine must still get the gear bonus", state)
    check(_tech_rows(cdata.get_tech_production_modifiers("mine", false, false),
                WATER_TECH).is_empty(),
            "a dry mine must not get the water bonus", state)

    # A wet hex with the gears but without the Water Wheel: the water power is
    # still locked, the gears are not.
    cdata.unlocked_technologies.append(WATER_TECH)
    var wet: Array = cdata.get_improvement_production_modifiers("mine", true)
    check(_rows(wet, tech_name).size() == 1,
            "a wet mine must keep the gear row", state)
    check(_rows(wet, str(cdata.get_tech_name(WATER_TECH))).size() == 1,
            "a wet mine with the wheel must show the water power row as well", state)

    # Both mechanics multiply: the mine gets the water and the gears.
    var gear: float = float(_tech_record(gdata, GEAR_TECH).get(
            "production_multiplier", {}).get("mine", 1.0))
    var water: float = float(_tech_record(gdata, WATER_TECH).get(
            "production_multiplier", {}).get("mine", 1.0))
    var mult: float = cdata.get_improvement_production_multiplier("mine", true)
    check(is_equal_approx(mult, gear * water),
            "the mine must multiply the gear bonus and the water bonus (%.4f vs %.4f)"
                    % [mult, gear * water], state)

# --- 5. City buildings use their own id map -----------------------------------
func _test_buildings(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var bld: Dictionary = _tech_record(gdata, GEAR_TECH).get(
            "building_production_multiplier", {})
    var tech_name: String = str(cdata.get_tech_name(GEAR_TECH))

    var mill: Array = _tech_rows(cdata.get_building_production_modifiers("animal_mill", false),
            GEAR_TECH)
    check(mill.size() == 1,
            "an animal mill with the gears must show exactly one row (got %d)" % mill.size(),
            state)
    if not mill.is_empty():
        check(is_equal_approx(float(mill[0].get("multiplier", 0.0)),
                    float(bld["animal_mill"])),
                "the animal mill's row must carry the multiplier from the data", state)
        check(str(mill[0].get("label", "")).contains(tech_name),
                "the animal mill's row must name the technology", state)

    # The gears need no water: the same row without a drop of water.
    check(is_equal_approx(
                cdata.get_building_production_multiplier("animal_mill", false),
                float(bld["animal_mill"])),
            "the animal mill's production multiplier must come from the gears", state)

    check(cdata.get_building_production_modifiers("hand_mill", false).is_empty(),
            "the hand mill is turned by hands, not by gears", state)
    check(cdata.get_building_production_modifiers("water_mill", false).is_empty(),
            "the water mill must not receive a second bonus for the same wheel", state)
    check(cdata.get_building_production_modifiers("pottery_workshop", false).is_empty(),
            "a building outside the gear table must get no gear bonus", state)

# --- 6. The Effects tab -------------------------------------------------------
func _test_city_effects(gdata: Node, cdata: Node, state: Dictionary) -> void:
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

    cdata.city_built_buildings = [
        {"id": "animal_mill", "slots": ["grind_grain_animal"]},
        {"id": "pottery_workshop", "slots": ["bricks"]},
    ]
    var tech_name: String = str(cdata.get_tech_name(GEAR_TECH))
    var found := 0
    for effect in cdata.get_city_effects():
        if str(effect.get("group", "")) != "technologies":
            continue
        if str(effect.get("name", "")) != gdata.get_building_display_name("animal_mill"):
            continue
        found += 1
        check(str(effect.get("value", "")) == "+25%",
                "the effect must show the size of the bonus (got \"%s\")"
                        % str(effect.get("value", "")), state)
        check(str(effect.get("source", "")) == tech_name,
                "the effect must name the technology that causes it", state)
        check(str(effect.get("icon", "")) == str(cdata.get_tech_icon(GEAR_TECH)),
                "the effect must carry the icon of the technology", state)
    check(found == 1,
            "the Effects tab must list the animal mill once (got %d)" % found, state)

    cdata.city_built_buildings.clear()
    # Remove it at once: do_tick() resolves "MainMap" by name and would find a
    # queued-but-still-alive stub first, with no TownsfolkManager under it.
    stub.free()

# --- 7. Both production paths apply the gear bonus ----------------------------
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

    _prepare_mill(cdata)
    # The gears are not researched yet: the earlier checks left the technology
    # unlocked, and the plain mill must be measured without it.
    cdata.unlocked_technologies.erase(GEAR_TECH)
    var plain_plan := _planned_flour(cdata)
    cdata.unlocked_technologies.append(GEAR_TECH)
    var geared_plan := _planned_flour(cdata)
    check(geared_plan > plain_plan,
            "the planned output of a geared mill must be higher (%d -> %d)"
                    % [plain_plan, geared_plan], state)
    check(geared_plan == int(round(float(plain_plan) * 1.25)),
            "the planned output must use the gear multiplier (plain %d, geared %d)"
                    % [plain_plan, geared_plan], state)

    # The actual tick must not promise less than the plan.
    cdata.unlocked_technologies.erase(GEAR_TECH)
    var plain_amount := _run_mill(cdata)
    cdata.unlocked_technologies.append(GEAR_TECH)
    var geared_amount := _run_mill(cdata)
    check(geared_amount > plain_amount,
            "do_tick() must apply the same gear bonus as the plan (%d -> %d)"
                    % [plain_amount, geared_amount], state)

    cdata.city_built_buildings.clear()
    # Remove it at once: do_tick() resolves "MainMap" by name and would find a
    # queued-but-still-alive stub first, with no TownsfolkManager under it.
    stub.free()

func _prepare_mill(cdata: Node) -> void:
    cdata.city_storage.clear()
    cdata.add_to_storage("wheat", 200, "common")
    cdata.add_to_storage("feed", 200, "common")
    cdata.city_built_buildings = [
        {"id": "animal_mill", "slots": ["grind_grain_animal"], "quality_priority": "best"}
    ]

func _planned_flour(cdata: Node) -> int:
    var plan: Dictionary = cdata.get_building_planned_production()
    var total := 0
    for entry in plan.get("flour", {}).values():
        total += int(entry.get("amount", 0))
    return total

func _run_mill(cdata: Node) -> int:
    _prepare_mill(cdata)
    for _i in 6:
        cdata.do_tick()
    return cdata.get_storage_amount("flour")

# The rows of the UI whose label mentions a source (the name of a technology).
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
