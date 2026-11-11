# Headless test of the "Effects" tab of the city:
#   godot --headless --path . --script res://tests/test_effects_tab.gd
#
# The tab shows what acts on the city right now. The source of truth is
# CityData.get_city_effects(); the test checks the rules of the list, not its wording:
#
#  1. Only ACTIVE effects are listed: a modifier record of a technology that is not researched
#     is absent, a researched one is listed once.
#  2. A row repeats the data record (icon and caption) instead of wording the effect again.
#  3. What a technology UNLOCKS is not an effect: a technology with unlock_effects only adds
#     nothing to the list.
#  4. The fresh water row appears only when the city hex really has access, and it tells a
#     direct access from a chain of conductors.
#  5. The live scene: the tab button is in the tab bar and switches the panel, the sections of
#     the tab are the effects and the diversity, the title follows the section, and the
#     diversity section is no longer on the "Resources" tab.
extends SceneTree

# The hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# A map stub for CityData.get_city_effects: the row about the city hex is built from the tile
# grid, and a synthetic grid is the only way to check the water access without a generated
# world.
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
    var state: Dictionary = {"failed": false}
    var city = get_root().get_node("CityData")
    var gdata = get_root().get_node("GameData")
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    city.unlocked_technologies.clear()
    # The autoloads join the tree on the first frame, and get_city_effects looks the map up
    # through get_tree(): before that frame the lookup has nothing to search in.
    await process_frame

    # ---- 1-4. The list of the effects on a synthetic map ----
    var stub := MapStub.new()
    stub.name = "MainMap"
    var tiles: Array = []
    for r in 5:
        var row: Array = []
        for c in 7:
            row.append({"terrain": "boreal_plain", "cover": "none"})
        tiles.append(row)
    tiles[2][2]["is_city"] = true
    stub.tile_data = tiles
    stub.city_row = 2
    stub.city_col = 2
    stub.map_rows = 5
    stub.map_cols = 7
    get_root().add_child(stub)

    # A dry city with no research: the list is empty, not "empty rows".
    var effects: Array = city.get_city_effects()
    check(effects.is_empty(), "a city without water and without research lists effects", state)

    # A lake next to the city — a direct access.
    tiles[2][3]["terrain"] = "lake"
    effects = city.get_city_effects()
    var env: Array = _rows_of(effects, "environment")
    check(env.size() == 1,
        "a city next to a lake does not get exactly one environment effect (%d)" % env.size(),
        state)
    if env.size() == 1:
        check(str(env[0].get("value", "")) == tr("direct access"),
            "a neighbouring lake is not reported as a direct access (got \"%s\")"
                % str(env[0].get("value", "")), state)
        check(str(env[0].get("icon", "")) == "water_chain.png",
            "the fresh water row does not carry the water icon", state)

    # The lake is gone; a chain of two farms closes on a lake three hexes away, and it works
    # only after "Irrigation" is researched.
    tiles[2][3]["terrain"] = "boreal_plain"
    tiles[2][3]["improvement"] = "farm"
    tiles[2][4]["improvement"] = "farm"
    tiles[2][5]["terrain"] = "lake"
    effects = city.get_city_effects()
    check(_rows_of(effects, "environment").is_empty(),
        "a chain gives the water before the technology is researched", state)
    city.unlocked_technologies.append("irrigation")
    effects = city.get_city_effects()
    env = _rows_of(effects, "environment")
    check(env.size() == 1,
        "a researched chain of conductors does not give the city the water", state)
    if env.size() == 1:
        check(str(env[0].get("value", "")) == tr("by a chain of conductors"),
            "a chain is not reported as a chain (got \"%s\")" % str(env[0].get("value", "")),
            state)

    # ---- 2-3. The technologies ----
    city.unlocked_technologies.clear()
    effects = city.get_city_effects()
    check(_rows_of(effects, "technologies").is_empty(),
        "the technologies group is not empty without research", state)

    city.unlocked_technologies.append("plow")
    effects = city.get_city_effects()
    var tech_rows: Array = _rows_of(effects, "technologies")
    check(tech_rows.size() == 1,
        "one researched modifier does not give exactly one row (%d)" % tech_rows.size(), state)
    var plow_record: Dictionary = _tech_modifier(gdata, "plow")
    if tech_rows.size() == 1:
        check(str(tech_rows[0].get("name", "")) == str(plow_record.get("name", "")),
            "the row does not repeat the caption of the record", state)
        check(str(tech_rows[0].get("icon", "")) == str(plow_record.get("icon", "")),
            "the row does not repeat the icon of the record", state)
        check(str(tech_rows[0].get("source", "")) == city.get_tech_name("plow"),
            "the row does not name the technology it comes from", state)

    # A technology that only unlocks something is not an effect of the city.
    city.unlocked_technologies.clear()
    city.unlocked_technologies.append("native_metals")
    effects = city.get_city_effects()
    check(_rows_of(effects, "technologies").is_empty(),
        "an unlock (unlock_effects) became an effect row", state)

    var original_locale := TranslationServer.get_locale()
    TranslationServer.set_locale("ru")
    check(tr("Mine, quarry, bloomery, smelter, forge: +25% production", "modifiers.tech_modifiers.name")
            == "Шахта, каменоломня, сыродутная печь, плавильня, кузница: +25% к производству",
        "the Russian water wheel caption names all five distinct recipients", state)
    TranslationServer.set_locale(original_locale)

    var production_buildings := {"water_wheel": "forge", "cogwheel": "animal_mill"}
    for tech_id in production_buildings:
        var building_id: String = production_buildings[tech_id]
        city.unlocked_technologies.clear()
        city.city_built_buildings = [
            {"id": building_id}, {"id": building_id}, {"id": "pottery_workshop"},
        ]
        tiles[2][3]["terrain"] = "lake"
        check(_rows_of(city.get_city_effects(), "technologies").is_empty(),
            "%s: no production effects before research" % tech_id, state)
        city.unlocked_technologies.append(tech_id)
        tech_rows = _rows_of(city.get_city_effects(), "technologies")
        var record := _tech_modifier(gdata, tech_id)
        check(tech_rows.size() == 1,
            "%s: one technology summary without per-building duplicates (%d)"
                % [tech_id, tech_rows.size()], state)
        if tech_rows.size() == 1:
            check(str(tech_rows[0].get("name", "")) == str(record.get("name", "")),
                "%s: the effect retains the full recipient list" % tech_id, state)
            check(str(tech_rows[0].get("icon", "")) == str(record.get("icon", "")),
                "%s: the effect retains the modifier icon" % tech_id, state)
            check(str(tech_rows[0].get("source", "")) == city.get_tech_name(tech_id),
                "%s: the effect names its technology" % tech_id, state)
        tiles[2][3]["terrain"] = "boreal_plain"
        check(_rows_of(city.get_city_effects(), "technologies") == tech_rows,
            "%s: the city water supply does not hide the technology recipient list" % tech_id, state)
        city.city_built_buildings.clear()
        tiles[2][3]["terrain"] = "lake"
        check(_rows_of(city.get_city_effects(), "technologies") == tech_rows,
            "%s: unbuilt recipients remain in the technology summary" % tech_id, state)
    tiles[2][3]["terrain"] = "boreal_plain"

    # One researched modifier stays on the city for the live check of the list below.
    city.unlocked_technologies.clear()
    city.unlocked_technologies.append("plow")

    stub.queue_free()
    await process_frame

    # ---- 5. The live scene ----
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    # CityData.setup() runs in the _ready of the map and resets the city to a new game, so the
    # research is granted after the map is in place and before the tab is opened.
    city.unlocked_technologies.clear()
    city.unlocked_technologies.append("plow")
    var city_ui = main_map.get_node_or_null("CityUI")
    check(city_ui != null, "CityUI not found in MainMap", state)
    if city_ui != null:
        var tab_button = city_ui.get_node_or_null("TabBarPanel/TabBar/EffectsTabButton")
        check(tab_button != null, "the tab button of the effects is missing", state)
        check(city_ui.get_node_or_null("ContentPanel/EffectsPanel") != null,
            "the panel of the effects is missing", state)
        check(city_ui.get_node_or_null("ContentPanel/ResourcesPanel/DiversitySection") == null,
            "the diversity section is still on the Resources tab", state)
        check(city_ui.get_node_or_null("ContentPanel/EffectsPanel/DiversitySection") != null,
            "the diversity section is not on the Effects tab", state)

        var bar = city_ui.get_node_or_null("ContentPanel/EffectsPanel/SectionsBar")
        check(bar != null and bar.get_child_count() == 2,
            "the Effects tab does not have exactly two sections", state)

        if tab_button != null:
            check(tab_button.icon != null, "the tab button does not carry an icon", state)
            tab_button.pressed.emit()
        check(city_ui.active_tab == "effects", "the tab button did not switch to the effects",
            state)
        check(city_ui.effects_panel.visible, "the effects panel is not shown", state)
        check(not city_ui.resources_panel.visible, "the resources panel is not hidden", state)
        await process_frame

        var effects_tab = city_ui.effects_tab
        check(effects_tab != null, "the effects tab script is not attached", state)
        if effects_tab != null:
            check(str(effects_tab.title_label.text) == tr("City effects"),
                "the title does not name the open section (got \"%s\")"
                    % str(effects_tab.title_label.text), state)

            # The list is built from CityData: a header per non-empty group, a row per effect and
            # a gap between two groups. One modifier is researched, so the list cannot be empty.
            var list = city_ui.get_node_or_null(
                "ContentPanel/EffectsPanel/EffectsSection/ScrollContainer/EffectsList")
            var groups: Dictionary = {}
            for effect in city.get_city_effects():
                groups[str(effect.get("group", ""))] = true
            var expected: int = city.get_city_effects().size() + groups.size()
            if groups.size() > 1:
                expected += groups.size() - 1
            check(expected > 1, "the live list is empty: nothing to draw", state)
            check(list != null and list.get_child_count() == expected,
                "the list does not hold %d rows (got %d)"
                    % [expected, list.get_child_count() if list != null else -1], state)

            # The source follows the effect in the same line: a separate label placed after a
            # wrapping name is pushed to the far edge of the row, which reads as two unrelated
            # columns.
            var plow_caption := "%s (%s)" % [str(plow_record.get("name", "")),
                city.get_tech_name("plow")]
            var same_line := false
            if list != null:
                for child in list.get_children():
                    if not (child is HBoxContainer) or child.get_child_count() != 2:
                        continue
                    var body = child.get_child(1)
                    if body is RichTextLabel and str(body.get_parsed_text()) == plow_caption:
                        same_line = true
            check(same_line, "the source of an effect is not appended to its name in the same line",
                state)

            effects_tab._switch_section("diversity")
            check(str(effects_tab.title_label.text) == tr("Diversity"),
                "the title does not follow the section switch", state)
            check(city_ui.get_node("ContentPanel/EffectsPanel/DiversitySection").visible,
                "the diversity section is not shown", state)
            check(not city_ui.get_node("ContentPanel/EffectsPanel/EffectsSection").visible,
                "the effects section is not hidden", state)
            effects_tab._switch_section("effects")

        main_map.queue_free()

    if state["failed"]:
        print("EFFECTS TAB TEST FAILED")
        quit(1)
    else:
        print("EFFECTS TAB TEST OK")
        quit(0)

func _rows_of(effects: Array, group: String) -> Array:
    var rows: Array = []
    for effect in effects:
        if str(effect.get("group", "")) == group:
            rows.append(effect)
    return rows

func _tech_modifier(gdata, tech_id: String) -> Dictionary:
    for mod in gdata.modifiers.get("tech_modifiers", []):
        if str(mod.get("tech_id", "")) == tech_id:
            return mod
    return {}

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("OK: ", message)
    else:
        state["failed"] = true
        push_error("FALL: " + message)
