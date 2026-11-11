# Headless test of the hoisting and the mechanics bonuses:
#   godot --headless --path . --script res://tests/test_hoisting_bonus.gd
#
# Two technologies of the antiquity:
#   * "Hoisting Mechanisms" — the winch and the pulley that lift the ore out of
#     the mine and the quarry (+10%). The gears pass the turn on, the water
#     washes the ore, but the hoist is a machine of its own.
#   * "Mechanics" — the craft of the machine: a second set of stones in the
#     animal mill and the water mill (+1 production slot) and the saw of the
#     woodcutter's camp (+10%).
#
# Checks:
#   1. The shape of the data: the records of the two technologies and their
#      id maps.
#   2. The technologies themselves: the era, the icons and the predecessors.
#   3. The predecessors: the hoist needs the rope making AND the wheel; the
#      mechanics need the screw press OR the cog wheel OR the hoist.
#   4. The gate: without the technology there is no bonus; with it there is.
#   5. The slots: the mills get a second one, the hand mill does not.
#   6. The Effects tab lists both bonuses and the granted slot.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

const HOIST_TECH := "hoisting_mechanisms"
const MECHANICS_TECH := "mechanics"


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
    _test_technologies(gdata, state)
    _test_prerequisites(gdata, cdata, state)
    _test_hoisting_bonus(cdata, state)
    _test_mechanics_bonus(cdata, state)
    _test_city_effects(cdata, state)

    if state["failed"]:
        print("HOISTING AND MECHANICS TEST FAILED")
        quit(1)
    else:
        print("HOISTING AND MECHANICS TEST OK")
        quit(0)


# The record of a technology in the block "tech_modifiers" of data/modifiers.json.
func _tech_record(gdata: Node, tech_id: String) -> Dictionary:
    for mod in gdata.modifiers.get("tech_modifiers", []):
        if str(mod.get("tech_id", "")) == tech_id:
            return mod
    return {}


# The technology itself.
func _tech(gdata: Node, tech_id: String) -> Dictionary:
    for t in gdata.technologies:
        if str(t.get("id", "")) == tech_id:
            return t
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
    for tech_id in [HOIST_TECH, MECHANICS_TECH]:
        var record := _tech_record(gdata, tech_id)
        check(not record.is_empty(),
                "the \"%s\" technology has no record in tech_modifiers" % tech_id, state)
        if record.is_empty():
            continue
        check(str(record.get("icon", "")) != "",
                "the record of the \"%s\" technology needs an icon" % tech_id, state)
        check(str(record.get("name", "")) != "",
                "the record of the \"%s\" technology needs a caption" % tech_id, state)
        check(not bool(record.get("requires_water", false)),
                "the \"%s\" technology must not ask for the water" % tech_id, state)

    var hoist: Dictionary = _tech_record(gdata, HOIST_TECH).get("production_multiplier", {})
    for imp_id in ["mine", "quarry"]:
        check(hoist.has(imp_id),
                "the hoist must speed up the \"%s\"" % imp_id, state)
    check(not hoist.has("lumberjack_hut"),
            "the woodcutter's camp is not a hoist", state)

    var mechanics: Dictionary = _tech_record(gdata, MECHANICS_TECH)
    var slots: Dictionary = mechanics.get("building_production_slots", {})
    for building_id in ["animal_mill", "water_mill"]:
        check(int(slots.get(building_id, 0)) == 1,
                "the \"%s\" must get one slot from the mechanics" % building_id, state)
    check(not slots.has("hand_mill"),
            "the hand mill is turned by hands, not by the mechanics", state)
    var camp: Dictionary = mechanics.get("production_multiplier", {})
    check(camp.has("lumberjack_hut"),
            "the woodcutter's camp must get the bonus of the mechanics", state)
    check(not camp.has("mine"),
            "the mine is not a part of the mechanics", state)


# --- 2. The technologies ------------------------------------------------------
func _test_technologies(gdata: Node, state: Dictionary) -> void:
    for tech_id in [HOIST_TECH, MECHANICS_TECH]:
        var tech := _tech(gdata, tech_id)
        check(not tech.is_empty(), "the \"%s\" technology is missing" % tech_id, state)
        if tech.is_empty():
            continue
        check(str(tech.get("era", "")) == "antiquity",
                "the \"%s\" technology belongs to the antiquity" % tech_id, state)
        check(str(tech.get("icon", "")) != "",
                "the \"%s\" technology needs an icon" % tech_id, state)
        check(str(tech.get("description", "")) != "",
                "the \"%s\" technology needs a description" % tech_id, state)
        check(str(tech.get("flavor", "")) != "",
                "the \"%s\" technology needs a flavor" % tech_id, state)


# --- 3. The predecessors ------------------------------------------------------
func _test_prerequisites(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var hoist_groups: Array = _tech(gdata, HOIST_TECH).get("prerequisites", [])
    var hoist_flat: Array = []
    for group in hoist_groups:
        for req in group:
            hoist_flat.append(str(req))
    check(hoist_flat.size() == 2 and hoist_flat.has("rope_making") and hoist_flat.has("wheel"),
            "the hoist needs the rope making AND the wheel, nothing else", state)

    # The rope making and the wheel together.
    cdata.unlocked_technologies = ["wheel"]
    check(not cdata.are_prerequisites_met(HOIST_TECH),
            "the wheel alone is not enough for the hoist", state)
    cdata.unlocked_technologies = ["rope_making"]
    check(not cdata.are_prerequisites_met(HOIST_TECH),
            "the ropes alone are not enough for the hoist", state)
    cdata.unlocked_technologies = ["rope_making", "wheel"]
    check(cdata.are_prerequisites_met(HOIST_TECH),
            "the rope making and the wheel must open the hoist", state)

    # The mechanics: any one of the three.
    var alternatives: Array = []
    for group in _tech(gdata, MECHANICS_TECH).get("prerequisites", []):
        alternatives.append(str(group[0]))
    check(alternatives.size() == 3 and alternatives.has("screw_press")
            and alternatives.has("cogwheel") and alternatives.has(HOIST_TECH),
            "the mechanics need the screw press OR the cog wheel OR the hoist", state)
    cdata.unlocked_technologies = []
    check(not cdata.are_prerequisites_met(MECHANICS_TECH),
            "the mechanics need a predecessor", state)
    for tech_id in ["screw_press", "cogwheel", HOIST_TECH]:
        cdata.unlocked_technologies = [tech_id]
        check(cdata.are_prerequisites_met(MECHANICS_TECH),
                "\"%s\" alone must open the mechanics" % tech_id, state)


# --- 4. The hoist -------------------------------------------------------------
func _test_hoisting_bonus(cdata: Node, state: Dictionary) -> void:
    cdata.unlocked_technologies = []
    check(_tech_rows(cdata.get_tech_production_modifiers("mine", false, true),
            HOIST_TECH).is_empty(),
            "the hoist must give nothing before it is researched", state)

    cdata.unlocked_technologies = [HOIST_TECH]
    for imp_id in ["mine", "quarry"]:
        var rows: Array = _tech_rows(cdata.get_tech_production_modifiers(imp_id, false, true),
                HOIST_TECH)
        check(rows.size() == 1,
                "\"%s\": the researched hoist must show exactly one row (got %d)"
                        % [imp_id, rows.size()], state)
        if not rows.is_empty():
            check(is_equal_approx(float(rows[0].get("multiplier", 0.0)), 1.1),
                    "\"%s\": the hoist must give +10%% (got %s)"
                            % [imp_id, str(rows[0].get("multiplier"))], state)
    check(_tech_rows(cdata.get_tech_production_modifiers("lumberjack_hut", false, true),
            HOIST_TECH).is_empty(),
            "the hoist must not touch the woodcutter's camp", state)


# --- 5. The mechanics ---------------------------------------------------------
func _test_mechanics_bonus(cdata: Node, state: Dictionary) -> void:
    cdata.unlocked_technologies = []
    check(cdata.get_production_slot_count("animal_mill") == 1,
            "the animal mill has one slot before the mechanics", state)
    check(cdata.get_production_slot_count("water_mill") == 1,
            "the water mill has one slot before the mechanics", state)

    cdata.unlocked_technologies = [MECHANICS_TECH]
    check(cdata.get_production_slot_count("animal_mill") == 2,
            "the mechanics must give the animal mill a second slot", state)
    check(cdata.get_production_slot_count("water_mill") == 2,
            "the mechanics must give the water mill a second slot", state)
    check(cdata.get_production_slot_count("hand_mill") == 1,
            "the hand mill is turned by hands and gets no slot", state)

    var rows: Array = _tech_rows(cdata.get_tech_production_modifiers("lumberjack_hut",
            false, true), MECHANICS_TECH)
    check(rows.size() == 1,
            "the woodcutter's camp must show exactly one row (got %d)" % rows.size(), state)
    if not rows.is_empty():
        check(is_equal_approx(float(rows[0].get("multiplier", 0.0)), 1.1),
                "the woodcutter's camp must get +10%% (got %s)"
                        % str(rows[0].get("multiplier")), state)


# --- 6. The Effects tab -------------------------------------------------------
func _test_city_effects(cdata: Node, state: Dictionary) -> void:
    cdata.unlocked_technologies = [HOIST_TECH, MECHANICS_TECH]
    var hoist_name := str(cdata.get_tech_name(HOIST_TECH))
    var mechanics_name := str(cdata.get_tech_name(MECHANICS_TECH))
    var hoist_rows := 0
    var mechanics_rows := 0
    var slot_rows := 0
    for effect in cdata.get_city_effects():
        if str(effect.get("group", "")) != "technologies":
            continue
        var source := str(effect.get("source", ""))
        if source == hoist_name:
            hoist_rows += 1
        elif source == mechanics_name:
            if str(effect.get("icon", "")) == "production_slot.png":
                slot_rows += 1
            else:
                mechanics_rows += 1
    check(hoist_rows == 1,
            "the Effects tab must list the hoist once (got %d)" % hoist_rows, state)
    check(mechanics_rows == 1,
            "the Effects tab must list the mechanics once (got %d)" % mechanics_rows, state)
    check(slot_rows == 1,
            "the Effects tab must list the granted slot once (got %d)" % slot_rows, state)


func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
