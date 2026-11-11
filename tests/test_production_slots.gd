extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

const TECH := "screw_press"
const GRANTED := ["winemaker_house", "oilmaker_house", "dairy", "paper_workshop", "jeweler_house"]

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
    _test_gate(cdata, state)
    _test_research_grants(cdata, state)
    _test_construction_grants(cdata, state)
    _test_new_build(cdata, state)
    _test_upgrade(cdata, state)
    _test_containers(cdata, state)
    _test_ui_rows(gdata, cdata, state)
    _test_absent_building_ignored(gdata, cdata, state)

    cdata.city_built_buildings.clear()
    cdata.building_construction.clear()
    cdata.unlocked_technologies.clear()

    if state["failed"]:
        print("PRODUCTION SLOTS TEST FAILED")
        quit(1)
    else:
        print("PRODUCTION SLOTS TEST OK")
        quit(0)

func _modifier_record(gdata: Node) -> Dictionary:
    for tm in gdata.modifiers.get("tech_modifiers", []):
        if str(tm.get("tech_id", "")) == TECH:
            return tm
    return {}

func _slot_grants(gdata: Node) -> Dictionary:
    return _modifier_record(gdata).get("building_production_slots", {})

# --- 1. The shape of the data -------------------------------------------------
func _test_data(gdata: Node, state: Dictionary) -> void:
    var tech: Dictionary = {}
    for t in gdata.technologies:
        if str(t.get("id", "")) == TECH:
            tech = t
    check(not tech.is_empty(), "the \"%s\" technology is missing" % TECH, state)
    if tech.is_empty():
        return
    check(str(tech.get("era", "")) == "antiquity",
            "the screw press belongs to the antiquity", state)
    var flat: Array = []
    for group in tech.get("prerequisites", []):
        for req in group:
            flat.append(str(req))
    check(flat.has("wheel") and flat.has("mathematics") and flat.size() == 2,
            "the screw press needs the wheel AND the mathematics, nothing else", state)

    var rec: Dictionary = _modifier_record(gdata)
    check(not rec.is_empty(), "the screw press modifier record is missing", state)
    var grants: Dictionary = _slot_grants(gdata)
    for building_id in GRANTED:
        check(int(grants.get(building_id, 0)) == 1,
                "\"%s\" must gain one slot from the screw press" % building_id, state)
    check(grants.size() == GRANTED.size(),
            "the grant names exactly the expected workshops (got %d)" % grants.size(), state)

# --- 2. The gate ---------------------------------------------------------------
func _test_gate(cdata: Node, state: Dictionary) -> void:
    for building_id in GRANTED:
        check(cdata.get_production_slot_count(building_id) == 1,
                "\"%s\" keeps its base slot before the research" % building_id, state)
    check(cdata.get_production_slot_count("hand_mill") == 1,
            "a building outside the grant table is untouched", state)

# --- 3. The research grants the slot to what already stands --------------------
func _test_research_grants(cdata: Node, state: Dictionary) -> void:
    cdata.city_built_buildings = [
        {"id": "dairy", "slots": ["cheese"]},
        {"id": "winemaker_house", "slots": ["empty"]},
    ]
    cdata.current_research_tech_id = TECH
    cdata.current_research_science_cost = 1
    cdata._complete_research()
    check(cdata.is_tech_unlocked(TECH), "the research completes", state)
    var dairy: Array = cdata.city_built_buildings[0].get("slots", [])
    check(dairy == ["cheese", "empty"],
            "the standing dairy gains an empty slot, its recipe stays (got %s)" % str(dairy),
            state)
    var winemaker: Array = cdata.city_built_buildings[1].get("slots", [])
    check(winemaker == ["empty", "empty"],
            "an idle winemaker's house gains a second empty slot (got %s)" % str(winemaker),
            state)
    for building_id in GRANTED:
        check(cdata.get_production_slot_count(building_id) == 2,
                "\"%s\" counts two slots after the research" % building_id, state)

    # The instant debug path grants the same way.
    cdata.unlocked_technologies.erase(TECH)
    cdata.city_built_buildings = [{"id": "paper_workshop", "slots": ["empty"]}]
    check(cdata._complete_tech_instantly(TECH), "the instant research completes", state)
    var paper: Array = cdata.city_built_buildings[0].get("slots", [])
    check(paper == ["empty", "empty"],
            "the instant path grants the slot as well (got %s)" % str(paper), state)

# --- 4. A building under construction gains the slot too -----------------------
func _test_construction_grants(cdata: Node, state: Dictionary) -> void:
    cdata.unlocked_technologies.erase(TECH)
    cdata.building_construction = {
        "key1": {"building_id": "oilmaker_house", "build_key": "key1",
                "slots": ["vegetable_oil"]}
    }
    cdata.unlocked_technologies.append(TECH)
    cdata.sync_production_slots()
    var slots: Array = cdata.building_construction["key1"].get("slots", [])
    check(slots == ["vegetable_oil", "empty"],
            "the unfinished oilmaker's house gains the slot (got %s)" % str(slots), state)
    cdata.building_construction.clear()

# --- 5. A building born after the research -------------------------------------
func _test_new_build(cdata: Node, state: Dictionary) -> void:
    var slots: Array = cdata._auto_assign_slots("oilmaker_house")
    check(slots == ["vegetable_oil", "empty"],
            "a new oilmaker's house is born with two slots (got %s)" % str(slots), state)
    var mill: Array = cdata._auto_assign_slots("hand_mill")
    check(mill == ["grind_grain_hand"],
            "a building outside the grant table is born with its base slots", state)

# --- 6. An upgrade reads the same resolver -------------------------------------
func _test_upgrade(cdata: Node, state: Dictionary) -> void:
    cdata.city_built_buildings = [
        {"id": "hand_mill", "slots": ["grind_grain_hand"], "quality_priority": "best"}
    ]
    check(cdata.complete_building_upgrade(0, "animal_mill"), "the upgrade completes", state)
    var bld: Dictionary = cdata.city_built_buildings[0]
    check(str(bld.get("id", "")) == "animal_mill", "the mill became the animal mill", state)
    var slots: Array = bld.get("slots", [])
    check(slots.size() == 1,
            "the animal mill is outside the grant table: one slot (got %d)" % slots.size(),
            state)
    check(str(bld.get("quality_priority", "")) == "best",
            "the upgrade keeps the quality priority", state)

# --- 7. The containers follow the grown array ----------------------------------
func _test_containers(cdata: Node, state: Dictionary) -> void:
    cdata.city_built_buildings = [{"id": "dairy", "slots": ["cheese", "empty"]}]
    var containers: Array = cdata.get_slot_containers(0)
    check(containers.size() == 2,
            "the container array fits the granted slots (got %d)" % containers.size(), state)
    # The container type is deliberately not named: mentioning CraftContainer
    # would force craft_container.gd to be compiled, and it references the
    # GameData autoload, which is not yet registered in --script mode.
    check(containers[0] != null and str(containers[0].recipe_id) == "cheese",
            "the working slot holds a container of its recipe", state)

    # A save holds flat dicts, not objects: the lazy restore must size itself to
    # the granted slots as well.
    cdata.city_built_buildings = [{
        "id": "dairy",
        "slots": ["cheese", "empty"],
        "slot_containers": [containers[0].serialize(), null],
    }]
    var restored: Array = cdata.get_slot_containers(0)
    check(restored.size() == 2 and restored[0] != null \
            and str(restored[0].recipe_id) == "cheese",
            "the restore from the save rebuilds both slots", state)

# --- 8. The tree and the Effects tab show the grant ----------------------------
func _test_ui_rows(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var tree = load("res://scripts/tech_tree.gd").new()
    var items: Array = tree._get_unlock_items(TECH)
    var grants: Dictionary = _slot_grants(gdata)
    var found := false
    for item in items:
        if str(item.get("icon", "")) != "production_slot.png":
            continue
        found = true
        var tip: String = str(item.get("tip", ""))
        check(tip.begins_with(tr("Extra production slots:")),
                "the unlock icon tooltip names the grant (got \"%s\")" % tip, state)
        for building_id in grants:
            check(tip.contains(gdata.get_building_display_name(str(building_id))),
                    "the tooltip names \"%s\"" % building_id, state)
    check(found, "the technology tree shows the icon of the extra slot", state)
    tree.free()

    var rows := 0
    for effect in cdata.get_city_effects():
        if str(effect.get("group", "")) != "technologies" \
                or str(effect.get("icon", "")) != "production_slot.png":
            continue
        rows += 1
        check(str(effect.get("value", "")) == tr("+%d production slot") % 1,
                "the effect row shows the amount of the grant (got \"%s\")"
                        % str(effect.get("value", "")), state)
        check(str(effect.get("source", "")) == str(cdata.get_tech_name(TECH)),
                "the Effects tab names the technology of the grant", state)
        check(grants.has(str(effect.get("name", ""))) \
                or _names_building(gdata, grants, str(effect.get("name", ""))),
                "the effect row names a granted workshop (got \"%s\")"
                        % str(effect.get("name", "")), state)
    check(rows == grants.size(),
            "the Effects tab lists one row per granted workshop (got %d)" % rows, state)

# The row carries the display name of the building, the grant map carries its id.
func _names_building(gdata: Node, grants: Dictionary, display_name: String) -> bool:
    for building_id in grants:
        if gdata.get_building_display_name(str(building_id)) == display_name:
            return true
    return false

func _test_absent_building_ignored(gdata: Node, cdata: Node, state: Dictionary) -> void:
    var buildings: Array = gdata.buildings
    var grants: Dictionary = _slot_grants(gdata).duplicate()
    var removed_name: String = gdata.get_building_display_name("winemaker_house")
    gdata.buildings = buildings.filter(func(b): return b.get("id", "") != "winemaker_house")
    check(cdata.get_production_slot_count("winemaker_house") == 0,
            "a removed building has no production slots", state)
    for building_id in GRANTED:
        if building_id != "winemaker_house":
            check(cdata.get_production_slot_count(building_id) == 2,
                    "the remaining buildings keep their slot bonus", state)

    var rows := 0
    for effect in cdata.get_city_effects():
        if str(effect.get("icon", "")) != "production_slot.png":
            continue
        rows += 1
        check(not ["winemaker_house", removed_name].has(str(effect.get("name", ""))),
                "the Effects tab omits the removed building", state)
    check(rows == GRANTED.size() - 1, "only existing slot recipients appear in Effects", state)

    var tree = load("res://scripts/tech_tree.gd").new()
    var badges := 0
    for item in tree._get_unlock_items(TECH):
        if str(item.get("icon", "")) != "production_slot.png":
            continue
        badges += 1
        var tip := str(item.get("tip", ""))
        check(not tip.contains(removed_name) and not tip.contains("winemaker_house"),
                "the unlock tooltip omits the removed building", state)
        for building_id in GRANTED:
            if building_id != "winemaker_house":
                check(tip.contains(gdata.get_building_display_name(building_id)),
                        "the unlock tooltip retains existing recipients", state)
    check(badges == 1, "a partially applicable grant keeps its badge", state)

    gdata.buildings = buildings.filter(func(b): return not GRANTED.has(b.get("id", "")))
    for building_id in GRANTED:
        check(cdata.get_production_slot_count(building_id) == 0,
                "no removed building receives slots", state)
    cdata.unlocked_technologies.append("cogwheel")
    check(cdata.get_tech_production_modifiers("jeweler_house", true, false).is_empty(),
            "production multipliers also ignore removed buildings", state)
    for item in tree._get_unlock_items(TECH):
        check(str(item.get("icon", "")) != "production_slot.png",
                "a grant with no remaining recipients has no unlock badge", state)
    for effect in cdata.get_city_effects():
        check(str(effect.get("icon", "")) != "production_slot.png",
                "a grant with no remaining recipients has no Effects rows", state)
    check(_slot_grants(gdata) == grants, "ignoring absent buildings never rewrites the modifier", state)
    gdata.buildings = buildings
    for building_id in GRANTED:
        check(cdata.get_production_slot_count(building_id) == 2,
                "a restored building receives its bonus again", state)
    tree.free()

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true