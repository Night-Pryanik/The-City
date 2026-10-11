# Headless test of road levels and routes (data/roads.json, road_manager,
# main_map, control_panel, map_renderer).
#   godot --headless --path . --script res://tests/test_road_levels.gd
#
# Checks:
#   1. DATA. The levels go consecutively from 1, each has a positive
#      "maximum speed", level 1 is free. The "Wheel" unlocks
#      exactly level 2, and its max_speed = 30 (a design requirement).
#   2. UNLOCK. Without the "Wheel" only level 1 is available; after
#      the research — level 2, and it becomes the suggested default.
#   3. LEVEL IN THE NETWORK. A built segment remembers its level; the neighbouring
#      segment does not change because of it, and a non-existent one gives 0, not a trail.
#   4. ROUTE AND SPEED. From an improvement to the city a route along the
#      roads is found; the average speed = the average max_speed of the segments, the minimum =
#      the narrowest spot. On a mixed route both values are counted
#      differently — this catches the error "take the minimum instead of the average".
#   5. ROAD UPGRADE. A segment is upgraded, but is not downgraded and is not
#      upgraded again to the same level.
#   6. LIVE SCENE. On an improvement with a road there is an "Upgrade road" button
#      and a route row; a click highlights the route on the map; the preview
#      shows a ghost of the segments being upgraded; the level affects the price.
#   7. ROAD LEVEL ON A HEX. The rule "the hex level = the maximum over the
#      adjacent segments": at a crossroad of two trails and one cart
#      road the hex shows the cart road, and the trails stay trails.
#      The level row is shown in the extended tooltip and in the left column
#      of the control panel; it is absent from the ordinary tooltip.
#   8. UPGRADE BUTTON. It remains on a partially upgraded route: one
#      segment out of several is upgraded — the button must be there while trails remain.
#      The road upgrade preview does not contain the production block: the player pressed
#      the button for the road's sake, and "Will produce" has no
#      relation to the road upgrade (and the block pushed the level selection down).
#   9. REFRESH AND THE EXTENDED BLOCK. The periodic refresh of the content (it
#      runs only for "growing" resources, that is, for pastures) does not wipe
#      the road level row: the extended block lives longer than one call.
#  10. BUTTON ON AN EMPTY HEX. "Upgrade road" is also present on a hex WITHOUT
#      an improvement: the button is determined by the route to the city, not by the presence of
#      an improvement.
extends SceneTree

# Hang watchdog: without it a break of the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const ROAD_ACTION_ID := "build_road"

const ROWS := 20
const COLS := 20
const CITY_ROW := 10
const CITY_COL := 10

var _rm = null
var _gdata = null
var _cdata = null
var _mh = null
# We load HexUtils via load(): the class name in --script mode is not yet in the
# compilation cache (the same reason MapHelpers is also taken via load()).
var _hu = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # We take the autoloads as scene-tree nodes: in --script mode the names GameData and
    # CityData are not yet available at the compilation stage of this file.
    # new_game() also loads all the data, including roads.json.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _mh = load("res://scripts/map_helpers.gd")
    _hu = load("res://scripts/HexUtils.gd")

    _rm = load("res://scripts/road_manager.gd").new()
    get_root().add_child(_rm)

    if WATCHDOG.wants_case("road_data"):
        _test_road_data(state)
    if WATCHDOG.wants_case("unlock_by_wheel"):
        _test_unlock_by_wheel(state)
    if WATCHDOG.wants_case("segment_level"):
        _test_segment_level(state)
    if WATCHDOG.wants_case("route_and_speeds"):
        _test_route_and_speeds(state)
    if WATCHDOG.wants_case("upgrade"):
        _test_upgrade(state)

    get_root().remove_child(_rm)
    _rm.free()
    _rm = null

    if WATCHDOG.wants_case("live_scene"):
        await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("ROAD LEVELS TEST FAILED")
        quit(1)
    else:
        print("ROAD LEVELS TEST OK")
        quit(0)


# -------------------------------------------------------
# Synthetic map: a plain without resources, rivers and improvements
# -------------------------------------------------------

func _make_map() -> Array:
    var tile_data := []
    for r in range(ROWS):
        var row := []
        for c in range(COLS):
            row.append({
                "terrain": "plain", "cover": "none", "resource": null,
                "quality": "", "crop_bred": null, "improvement": null,
                "decorative": false, "terrain_icon": "", "fill_time": 0.0,
                "production_fractional_remainder": 0.0, "has_town": false,
                "river_edges": [], "in_influence": true, "is_explored": true,
                "in_town_influence": false, "road_built": false, "road_level": 1,
            })
        tile_data.append(row)
    return tile_data

# Unlock the technology that opens the level (currently the "Wheel").
# The unlock_tech field can be null, so we skip null explicitly: `null or ""`
# in GDScript does not give an empty string.
func _unlock_level(level: int) -> void:
    var raw = _gdata.get_road_by_level(level).get("unlock_tech", null)
    if not (raw is String) or str(raw).is_empty():
        return
    if str(raw) not in _cdata.unlocked_technologies:
        _cdata.unlocked_technologies.append(str(raw))

# -------------------------------------------------------
# 1. Level data
# -------------------------------------------------------

func _test_road_data(state: Dictionary) -> void:
    check(_gdata.get_road_levels().size() >= 2,
            "roads.json must have at least two road levels", state)

    # The levels go consecutively from 1: a segment stores the level number, and a gap
    # would mean that some numbers correspond to no entry.
    var levels: Array = _gdata.get_road_levels()
    for i in range(levels.size()):
        check(int(levels[i]) == i + 1,
                "road levels must go consecutively from 1 (expected %d, got %d)"
                        % [i + 1, int(levels[i])], state)

    for level in levels:
        check(_gdata.get_road_max_speed(int(level)) > 0,
                "level %d must have a positive maximum speed" % int(level),
                state)

    # The trail is paid: a road built together with an improvement costs exactly
    # the same as the same road built separately.
    check(_gdata.get_road_work_cost(1) > 0,
            "level 1 (the trail) must be paid", state)
    check(_gdata.get_road_max_speed(1) > 0,
            "the trail must still have a positive speed", state)


# -------------------------------------------------------
# 2. The "Wheel" unlocks the second level with a speed of 30
# -------------------------------------------------------

func _test_unlock_by_wheel(state: Dictionary) -> void:
    var level2: Dictionary = _gdata.get_road_by_level(2)
    check(not level2.is_empty(), "roads.json must have level 2", state)
    check(str(level2.get("unlock_tech", "")) == "wheel",
            "level 2 must be unlocked by the \"Wheel\" technology (wheel)", state)
    # A value from the design: a trail carries 10 units/sec, a cart road — 30.
    check(_gdata.get_road_max_speed(2) == 30,
            "the maximum speed of level 2 must be 30 units/sec (got %d)"
                    % _gdata.get_road_max_speed(2), state)

    check(_cdata.is_tech_unlocked("wheel") == false,
            "at the start of the game the \"Wheel\" must not be researched", state)
    check(_gdata.is_road_level_unlocked(1), "the trail is available without technologies", state)
    check(not _gdata.is_road_level_unlocked(2),
            "the second level is unavailable before the \"Wheel\"", state)
    check(_gdata.get_unlocked_road_levels() == [1],
            "before the \"Wheel\" only the trail is available", state)
    # By default the BEST available level is offered.
    check(_gdata.get_max_unlocked_road_level() == 1,
            "before the \"Wheel\" the trail is offered by default", state)

    _unlock_level(2)
    check(_gdata.is_road_level_unlocked(2),
            "after the \"Wheel\" the second level must be available", state)
    check(_gdata.get_max_unlocked_road_level() == 2,
            "after the \"Wheel\" the second level is offered by default", state)
    # The trail stays available: the player can choose any previous level.
    check(_gdata.is_road_level_unlocked(1),
            "after the \"Wheel\" the trail must stay available", state)


# -------------------------------------------------------
# 3. A segment remembers its level
# -------------------------------------------------------

func _test_segment_level(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)

    # A trail from the city: the default level is 1.
    _rm.build_road_step(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL)
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL) == 1,
            "a segment without an explicit level must be a trail", state)

    # A cart road with the same call, but with a level.
    _rm.build_road_step(CITY_ROW + 1, CITY_COL, CITY_ROW + 2, CITY_COL, false, 2)
    check(_rm.get_segment_level(CITY_ROW + 1, CITY_COL, CITY_ROW + 2, CITY_COL) == 2,
            "a segment must remember the chosen level", state)
    # The neighbouring segment must not change: the level belongs to the segment,
    # not to "the road in general".
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL) == 1,
            "the level of the neighbouring segment must not change", state)
    # There is no segment — 0, not a trail: otherwise a non-existent segment would count as a
    # road with throughput.
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 9, CITY_COL) == 0,
            "a non-existent segment must give level 0", state)

    # The automatic road to an improvement is a trail. We check ALL its segments,
    # not one particular one: the planner walks by Dijkstra and may choose a
    # detour, and then "the first segment to the city" is not the one next to
    # the hex in a straight line.
    _rm.initialize(CITY_ROW, CITY_COL)
    tile_data[CITY_ROW + 3][CITY_COL]["improvement"] = "farm"
    _rm.build_road_from(CITY_ROW + 3, CITY_COL, tile_data, ROWS, COLS)
    var trail_segments: Dictionary = _rm.get_all_road_segments()
    check(not trail_segments.is_empty(), "a road must be laid to the improvement", state)
    for key in trail_segments.keys():
        check(int(trail_segments[key]) == 1,
                "the road to the improvement must be a trail by default: %s" % key, state)

    # An explicitly chosen level reaches the network.
    _rm.initialize(CITY_ROW, CITY_COL)
    _rm.build_road_from(CITY_ROW + 4, CITY_COL, tile_data, ROWS, COLS, 2)
    var cart_segments: Dictionary = _rm.get_all_road_segments()
    check(not cart_segments.is_empty(), "a road must be laid to the improvement", state)
    for key in cart_segments.keys():
        check(int(cart_segments[key]) == 2,
                "the chosen road level for the improvement must reach the network: %s" % key,
                state)


# -------------------------------------------------------
# 4. Route and speed
# -------------------------------------------------------

func _test_route_and_speeds(state: Dictionary) -> void:
    _rm.initialize(CITY_ROW, CITY_COL)
    # A route of 4 segments: city -> 1 -> 2 -> 3 -> 4.
    _rm.build_road_step(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL)
    _rm.build_road_step(CITY_ROW + 1, CITY_COL, CITY_ROW + 2, CITY_COL)
    _rm.build_road_step(CITY_ROW + 2, CITY_COL, CITY_ROW + 3, CITY_COL)
    _rm.build_road_step(CITY_ROW + 3, CITY_COL, CITY_ROW + 4, CITY_COL)

    var route: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    check(route.get("ok", false),
            "a route from the improvement to the city must be found", state)
    check(int(route.get("length", 0)) == 4,
            "the route must consist of 4 segments (got %d)"
                    % int(route.get("length", 0)), state)
    check(route.get("path", []).size() == 5,
            "a route of 4 segments contains 5 hexes", state)

    # A solid trail: the average equals the speed of the trail.
    var trail_speed: int = _gdata.get_road_max_speed(1)
    var cart_speed: int = _gdata.get_road_max_speed(2)
    check(absf(float(route.get("avg_speed", 0.0)) - float(trail_speed)) < 0.01,
            "on a route of a single trail the average speed equals the speed of the trail",
            state)
    check(not route.has("min_speed"),
            "the route must not contain a \"bottleneck\": the route speed is the average",
            state)

    # A mixed route: three trails and one cart road. The average is higher than
    # the trail's speed — a single bad pothole must not drag down the speed of the whole highway.
    _rm.upgrade_road_segment(CITY_ROW + 3, CITY_COL, CITY_ROW + 4, CITY_COL, 2)
    var mixed: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    var expected_avg := (3.0 * float(trail_speed) + float(cart_speed)) / 4.0
    check(absf(float(mixed.get("avg_speed", 0.0)) - expected_avg) < 0.01,
            "average speed = the average max_speed over the segments (expected %.2f, got %.2f)"
                    % [expected_avg, float(mixed.get("avg_speed", 0.0))], state)
    check(float(mixed.get("avg_speed", 0.0)) > float(trail_speed),
            "one cart road must raise the average, not lower it to the minimum",
            state)

    # The author's key example: nine cart roads and one trail = 28 units/sec,
    # not 10. A separate instance of the manager — otherwise the long route would overwrite the
    # network on which the levels and the order of the segments above are checked.
    var rm2 = load("res://scripts/road_manager.gd").new()
    get_root().add_child(rm2)
    rm2.initialize(CITY_ROW, CITY_COL)
    for i in range(10):
        rm2.build_road_step(CITY_ROW + i, CITY_COL, CITY_ROW + i + 1, CITY_COL,
                false, 2)
    var long_route: Dictionary = rm2.find_route_to_city(CITY_ROW + 10, CITY_COL)
    check(long_route.get("ok", false),
            "a route of 10 segments must be found", state)
    check(int(long_route.get("length", 0)) == 10,
            "the route must consist of 10 segments (got %d)"
                    % int(long_route.get("length", 0)), state)
    check(absf(float(long_route.get("avg_speed", 0.0)) - 30.0) < 0.01,
            "ten cart roads give an average of 30 units/sec", state)

    # One trail over ten segments: (9*30 + 1*10)/10 = 28.
    #
    # The configuration is built at once, not by lowering the level: upgrade_road_segment
    # can only RAISE (a segment is not below the level — false), so building a
    # mixed route by lowering is impossible in principle.
    var rm3 = load("res://scripts/road_manager.gd").new()
    get_root().add_child(rm3)
    rm3.initialize(CITY_ROW, CITY_COL)
    for i in range(9):
        rm3.build_road_step(CITY_ROW + i, CITY_COL, CITY_ROW + i + 1, CITY_COL,
                false, 2)
    rm3.build_road_step(CITY_ROW + 9, CITY_COL, CITY_ROW + 10, CITY_COL, false, 1)
    var mixed_long: Dictionary = rm3.find_route_to_city(CITY_ROW + 10, CITY_COL)
    check(int(mixed_long.get("length", 0)) == 10,
            "the mixed route must consist of 10 segments", state)
    check(absf(float(mixed_long.get("avg_speed", 0.0)) - 28.0) < 0.01,
            "nine cart roads and one trail = (9*30 + 1*10)/10 = 28 units/sec"
                    + " (got %.2f)" % float(mixed_long.get("avg_speed", 0.0)), state)
    # The main point: this is NOT 10 units/sec. One bad pothole does not drag down the whole highway.
    check(float(mixed_long.get("avg_speed", 0.0)) > 25.0,
            "one trail must not drag the route down to its speed of 10 units/sec", state)
    get_root().remove_child(rm2)
    rm2.free()
    get_root().remove_child(rm3)
    rm3.free()

    # The levels of the route go in the same order as the segments: from the improvement to
    # the city. The segment adjacent to the improvement was upgraded — it is first.
    var levels: Array = mixed.get("levels", [])
    check(levels.size() == 4, "the route must have the level of every segment", state)
    check(int(levels[0]) == 2 and int(levels[3]) == 1,
            "the route levels must go from the improvement to the city", state)

    # The speed is recomputed after a segment is upgraded: the route is a
    # derivative of the network, and the cache must be reset together with it.
    # Two cart roads and two trails: (2*30 + 2*10)/4 = 20.
    _rm.upgrade_road_segment(CITY_ROW + 2, CITY_COL, CITY_ROW + 3, CITY_COL, 2)
    var mixed2: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    check(absf(float(mixed2.get("avg_speed", 0.0)) - 20.0) < 0.01,
            "after the upgrade the average was recomputed: (2*30 + 2*10)/4 = 20 units/sec"
                    + " (got %.2f)" % float(mixed2.get("avg_speed", 0.0)), state)

    # A hex without a road has no route; the city itself does not count as a route.
    check(not _rm.find_route_to_city(CITY_ROW, CITY_COL - 3).get("ok", true),
            "a hex without a road must not have a route to the city", state)
    check(not _rm.find_route_to_city(CITY_ROW, CITY_COL).get("ok", true),
            "the city itself must not count as a hex with a route", state)


# -------------------------------------------------------
# 5. Road upgrade
# -------------------------------------------------------

func _test_upgrade(state: Dictionary) -> void:
    _rm.initialize(CITY_ROW, CITY_COL)
    _rm.build_road_step(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL)

    # An upgrade of a non-existent segment is impossible — it returns false, and there will be no
    # step without work in the project.
    check(not _rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 5, CITY_COL, 2),
            "upgrading a non-existent segment must return false", state)
    check(_rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL, 2),
            "a segment must be upgradeable", state)
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL) == 2,
            "after the upgrade the segment level must be 2", state)
    # A repeated upgrade to the same level is empty work.
    check(not _rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL, 2),
            "a repeated upgrade to the same level must return false", state)
    # The level must not be lowered: a segment must not degrade on a click.
    check(not _rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL, 1),
            "the segment level must not be lowered", state)


# -------------------------------------------------------
# 6. Live scene: button, route row, highlighting, level selection
# -------------------------------------------------------

func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var panel = main_map.control_panel
    var rm = main_map.road_manager

    # We research the "Wheel": without it there is no road upgrade button from a trail.
    if "wheel" not in _cdata.unlocked_technologies:
        _cdata.unlocked_technologies.append("wheel")
    check(_gdata.get_max_unlocked_road_level() == 2,
            "after the \"Wheel\" the second level must be offered by default", state)

    # We place an improvement on a hex in the influence: a road is laid to it.
    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "a hex in the influence must be found on the live map", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    main_map.tile_data[row][col]["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)

    # A route exists, and it consists of trails only.
    var route: Dictionary = main_map.get_route_to_city(row, col)
    check(route.get("ok", false), "an improvement with a road must have a route", state)
    check(int(route.get("length", 0)) >= 1,
            "the route must consist of at least one segment", state)
    check(absf(float(route.get("avg_speed", 0.0)) - float(_gdata.get_road_max_speed(1))) < 0.01,
            "initially the route goes along trails only, and the average equals their speed",
            state)

    # A click on the improvement: the panel has a route row, and the map highlights
    # the existing segments of the route.
    panel.select_hex(row, col)
    check(_collect_text(panel).contains("Route to the city"),
            "the panel must have a route row to the city", state)

    var route_segments: Dictionary = main_map.map_renderer._route_segments
    check(not route_segments.is_empty(),
            "after the click the route must be highlighted on the map", state)
    check(route_segments.size() == int(route.get("length", 0)),
            "the highlighting must contain all the segments of the route", state)

    # The "Upgrade road" button is present: the route is of trails, and level 2 is unlocked.
    var actions: Array = panel._collect_actions(row, col, main_map.tile_data[row][col])
    check(_has_action(actions, panel.UPGRADE_ROAD_TYPE),
            "an improvement with a road must have an \"Upgrade road\" button", state)

    # The improvement preview: a ghost of the segments being upgraded and the price.
    panel._preview_action = {"type": panel.UPGRADE_ROAD_TYPE, "imp_id": "",
            "target_res_id": null, "action_id": "", "label": "Upgrade road",
            "eff_res": "", "selected_culture_id": null, "road_level": 2}
    panel._refresh()
    check(_collect_text(panel._preview_container).contains("Cost"),
            "the improvement preview must show the cost", state)
    check(main_map.map_renderer._road_preview_segments.size() == int(route.get("length", 0)),
            "the preview ghost of the improvement must cover all the segments of the route", state)

    var breakdown: Dictionary = main_map.get_road_upgrade_breakdown(row, col, 2)
    check(breakdown.get("ok", false), "the improvement breakdown must be available", state)
    check(int(breakdown.get("cost", 0)) > 0,
            "an upgrade to a paid level must cost something", state)
    check(int(breakdown.get("segments", 0)) == int(route.get("length", 0)),
            "all the segments of the route must be upgraded", state)

    # We upgrade the route: the segment levels grow, the bottleneck rises.
    check(main_map.start_road_upgrade_project(row, col, 2),
            "the road upgrade must start", state)
    var project = main_map.project_manager.get_project_at(row, col)
    check(not project.is_empty(), "the upgrade must become a staged project", state)
    await _finish_build(main_map, state)
    for key in rm.get_all_road_segments().keys():
        check(int(rm.road_segments[key]) == 2,
                "all the segments of the route must become level 2", state)
    var after: Dictionary = main_map.get_route_to_city(row, col)
    check(absf(float(after.get("avg_speed", 0.0)) - float(_gdata.get_road_max_speed(2))) < 0.01,
            "after the upgrade the route average must grow to the cart road's speed",
            state)

    # A repeated upgrade to the same level has nothing to offer.
    check(not _has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
            panel.UPGRADE_ROAD_TYPE),
            "after the upgrade the \"Upgrade road\" button must disappear", state)
    check(not main_map.get_road_upgrade_breakdown(row, col, 2).get("ok", true),
            "there is nothing to upgrade the route to its current level", state)

    # The level affects the price of a new road: a trail is cheaper than a cart road, but both
    # cost work — including the one built together with an improvement.
    var road_target := _find_hex_without_road(main_map)
    if not road_target.is_empty():
        var r2 := int(road_target.row)
        var c2 := int(road_target.col)
        check(main_map.get_road_cost_breakdown(r2, c2, 1).get("cost", 0) > 0,
                "a trail route must cost work", state)
        check(main_map.get_road_cost_breakdown(r2, c2, 2).get("cost", 0)
                > main_map.get_road_cost_breakdown(r2, c2, 1).get("cost", 0),
                "a cart road route must cost more than a trail", state)

    if WATCHDOG.wants_case("road_level_in_hex_info"):
        await _test_road_level_in_hex_info(main_map, state)
    if WATCHDOG.wants_case("extended_tooltip_survives_refresh"):
        await _test_extended_tooltip_survives_refresh(main_map, state)
    if WATCHDOG.wants_case("upgrade_button_on_partial_route"):
        await _test_upgrade_button_on_partial_route(main_map, state)
    if WATCHDOG.wants_case("upgrade_button_on_empty_hex"):
        await _test_upgrade_button_on_empty_hex(main_map, state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


# -------------------------------------------------------
# 7. Road level in the tooltip and in the left column of the panel
# -------------------------------------------------------
#
# Both points take THE SAME hex text (MapTooltip._build_text), therefore
# both the tooltip text and what the left column assembles from it are checked.
func _test_road_level_in_hex_info(main_map, state: Dictionary) -> void:
    var rm = main_map.road_manager
    # We do not specify the type: in --script mode the class name MapTooltip is not yet in the
    # compilation cache (the same reason the tests do not mention
    # MapHelpers and GameData directly).
    var tooltip = main_map.map_tooltip
    var panel = main_map.control_panel

    # A hex in the influence on which there is no road yet: the level row must be absent.
    var empty_hex := _find_hex_without_road(main_map)
    check(not empty_hex.is_empty(), "a hex without a road is needed for the check", state)
    if not empty_hex.is_empty():
        var e_row := int(empty_hex.row)
        var e_col := int(empty_hex.col)
        var empty_text: String = tooltip._build_text(e_row, e_col,
                main_map.tile_data, main_map.city_row, main_map.city_col)
        check(not empty_text.contains("Road"),
                "a hex without a road must not have the level row", state)

    # A hex with a trail: the row is present, and the extended tooltip is shown on it.
    # We take a hex WITHOUT a road (and not the first free one): by this moment the test has already
    # set up the network, and the first free hex could have turned out connected to
    # an upgraded road from the previous steps — then the wrong thing would be checked.
    var spot := _find_hex_without_road(main_map)
    check(not spot.is_empty(), "a hex without a road is needed for the check", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    # build_road_from, not build_road_step: it really LAYS a path to
    # the network, while build_road_step only marks one segment — between the city and
    # the hex there may be several hexes, and the segment "city → hex" may not
    # exist at all.
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    check(rm.get_hex_road_level(row, col) == 1,
            "the road to the hex is a trail by default", state)
    check(tooltip.has_extended_tooltip_info(row, col, main_map.tile_data),
            "on a hex with a road the extended tooltip must be shown", state)

    # The extended tooltip: the level row is added BEFORE the early exits of
    # update_extended_tooltip, so we check it on a hex without an improvement.
    tooltip.update_extended_tooltip(row, col, main_map.tile_data,
            main_map.city_row, main_map.city_col)
    var extended_text := _collect_text(tooltip._tooltip_products_container)
    check(extended_text.contains("Road: %s (level 1, up to 10 units/sec per section)"
            % _gdata.get_road_name(1)),
            "the extended tooltip must have the road level (got: %s)" % extended_text,
            state)

    # The ordinary tooltip does NOT show the road level: the level is not a property of the hex,
    # but of its connection to the city, and for that there is the extended block and the left column.
    var text: String = tooltip._build_text(row, col, main_map.tile_data,
            main_map.city_row, main_map.city_col)
    check(not text.contains("Road"),
            "the ordinary tooltip must not have the road level row (got: %s)" % text,
            state)

    # A crossroad of two trails and one cart road — exactly the case
# for which the rule "the hex level = the maximum" was introduced: the hex shows
# the cart road (level 2), as it also looks on the map, although two trails
# pass through it and stay trails.
    #
    # The scheme (see _test_crossroad_* below): the hex is connected to the city by a trail,
    # and two more neighbours adjoin it — with a trail and with a cart road.
    var edge1 := _hex_in_direction(main_map, row, col)
    if not edge1.is_empty():
        # A neighbour with a trail: we build a level-1 segment.
        rm.build_road_step(row, col, int(edge1.row), int(edge1.col))
        var edge2 := _hex_in_direction(main_map, row, col, int(edge1.row), int(edge1.col))
        if not edge2.is_empty():
            # A neighbour with a cart road: the same segment is built as a trail and
            # upgraded — this checks that the hex level is taken by the
            # maximum, not by the "first encountered" segment.
            if rm.build_road_step(row, col, int(edge2.row), int(edge2.col)):
                rm.upgrade_road_segment(row, col, int(edge2.row), int(edge2.col), 2)
                check(rm.get_hex_road_level(row, col) == 2,
                        "at a crossroad of 2 trails + a cart road the hex level must be 2",
                        state)
                # The trails stay trails: the hex level is a
                # derived value, not a strut to "raise everything at once".
                check(rm.get_segment_level(row, col, int(edge1.row), int(edge1.col)) == 1,
                        "a trail segment through the crossroad must stay a trail",
                        state)
                var mixed_text: String = tooltip.road_level_line(row, col)
                check(mixed_text.contains("level 2") and mixed_text.contains(_gdata.get_road_name(2)),
                        "the level row at the crossroad must name the cart road (got: %s)"
                                % mixed_text, state)

    # The left column of the panel is assembled from the same text — the row must be
    # there too, and not only in the tooltip under the cursor.
    panel.select_hex(row, col)
    check(_collect_text(panel).contains("level"),
            "the left column of the panel must show the road level", state)

    # The road upgrade preview does NOT contain the production block: the player pressed
    # the road upgrade button for the road's sake, and "Will produce" refers
    # to an improvement he is not building. The block also pushed the road
    # level selector down and made the preview scroll.
    if _gdata.get_max_unlocked_road_level() <= 1:
        return
    panel._preview_action = {"type": panel.UPGRADE_ROAD_TYPE, "imp_id": "",
            "target_res_id": null, "action_id": "", "label": "Upgrade road",
            "eff_res": "", "selected_culture_id": null, "road_level": 2}
    panel._refresh()
    var upgrade_preview_text := _collect_text(panel._preview_container)
    check(not upgrade_preview_text.contains("Will produce"),
            "the road upgrade preview must not have the production block (got: %s)"
                    % upgrade_preview_text, state)
    check(upgrade_preview_text.contains("Road level:"),
            "the road upgrade preview must have a level selection (got: %s)"
                    % upgrade_preview_text, state)
    check(upgrade_preview_text.contains("Cost"),
            "the road upgrade preview must have a price (got: %s)"
                    % upgrade_preview_text, state)


# The first free hex in the Ring of Influence at a distance of at least min_dist
# from the city. Needed where the LENGTH of the route matters: a route of one segment
# cannot be partially upgraded, and the check "the button stayed" on it is meaningless.
func _find_hex_far_from_city(main_map, min_dist: int) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if _hex_is_busy(main_map, row, col, tile):
                continue
            if main_map.road_manager.is_hex_connected(row, col):
                continue
            if _hu.hex_distance(row, col, main_map.city_row, main_map.city_col) < min_dist:
                continue
            return {"row": row, "col": col}
    return {}

# A free neighbour of the hex (row, col) in the given direction — for building
# the crossroad scheme. We cannot exclude an already used neighbour: otherwise the second
# segment may land on an already built one, and build_road_step will return false.
func _hex_in_direction(main_map, row: int, col: int,
        exclude_row: int = -1, exclude_col: int = -1) -> Dictionary:
    var main_map_ref = main_map
    var candidates := [
        {"row": row - 1, "col": col},
        {"row": row + 1, "col": col},
        {"row": row, "col": col - 1},
        {"row": row, "col": col + 1},
    ]
    for candidate in candidates:
        var t_row := int(candidate.row)
        var t_col := int(candidate.col)
        if t_row == exclude_row and t_col == exclude_col:
            continue
        if t_row < 0 or t_col < 0 or t_row >= main_map_ref.map_rows \
                or t_col >= main_map_ref.map_cols:
            continue
        var tile = main_map_ref.tile_data[t_row][t_col]
        if tile == null or tile.get("has_town", false):
            continue
        if _mh.is_water_terrain(tile.get("terrain", "plain")):
            continue
        return {"row": t_row, "col": t_col}
    return {}


# -------------------------------------------------------
# 8. The "Upgrade road" button on a partially upgraded route
# -------------------------------------------------------
#
# The button must stay while there are trails on the route: one segment out of
# four is upgraded, the rest stay trails — and the button must remain, because
# the route is not yet fully upgraded.
func _test_upgrade_button_on_partial_route(main_map, state: Dictionary) -> void:
    var panel = main_map.control_panel
    var rm = main_map.road_manager

    var spot := _find_hex_far_from_city(main_map, 4)
    check(not spot.is_empty(),
            "a hex far from the city is needed for the check (a route of several segments)",
            state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    main_map.tile_data[row][col]["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    if _gdata.get_max_unlocked_road_level() <= 1:
        # The "Wheel" is not researched: there is nothing to upgrade, there is no button — and that is correct.
        check(not _has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
                panel.UPGRADE_ROAD_TYPE),
                "without a researched technology there must be no upgrade button", state)
        return
    check(_has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
            panel.UPGRADE_ROAD_TYPE),
            "on a route of trails the upgrade button must be present", state)

    # We upgrade ONE segment of the route — not all of it. The remaining segments stay
    # trails, and the button must remain: the route is not yet upgraded to the end.
    var route: Dictionary = main_map.get_route_to_city(row, col)
    var segments: Array = route.get("segments", [])
    check(segments.size() >= 2,
            "a route of at least two segments is needed for the check (got %d)"
                    % segments.size(), state)
    if segments.size() < 2:
        return
    var first: String = str(segments[0])
    var parts := first.split("|")
    var a := parts[0].split(",")
    var b := parts[1].split(",")
    check(rm.upgrade_road_segment(int(a[0]), int(a[1]), int(b[0]), int(b[1]), 2),
            "one segment of the route must be upgradeable", state)

    var after: Dictionary = main_map.get_route_to_city(row, col)
    var still_trails := 0
    for level in after.get("levels", []):
        if int(level) < _gdata.get_max_unlocked_road_level():
            still_trails += 1
    check(still_trails > 0,
            "after upgrading one segment the route must not become entirely the best", state)
    check(_has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
            panel.UPGRADE_ROAD_TYPE),
            "on a partially upgraded route the upgrade button must remain", state)


# -------------------------------------------------------
# 9. A content refresh does not wipe the extended block
# -------------------------------------------------------
#
# The "Road: …" row in the extended tooltip must survive the periodic refresh of
# the content. The extended block is drawn once per hover, but the
# InputHandler at the resource_display_interval calls update_tooltip_text
# for "growing" resources (time_to_mature > 0 — that is, only for pastures), and
# it rebuilds the container from scratch and replaces the block with the basic list. The row must
# not disappear before the cursor leaves. Farms and forest plots are not
# affected: they have no time_to_mature, so the refresh is not called.
func _test_extended_tooltip_survives_refresh(main_map, state: Dictionary) -> void:
    var rm = main_map.road_manager
    # We do not specify the type — as in _test_road_level_in_hex_info: the class name
    # MapTooltip is not yet in the compilation cache of this file.
    var tooltip = main_map.map_tooltip

    var res_id := _find_growing_resource_id()
    check(not res_id.is_empty(),
            "the data needs a growing resource (time_to_mature > 0) for the refresh check",
            state)
    if res_id.is_empty():
        return

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(),
            "a hex in the influence is needed for the refresh check", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["improvement"] = str(_gdata.raw_resources.get(res_id, {}).get("improved_by", "pasture"))
    tile["resource"] = res_id
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    check(not tooltip.road_level_line(row, col).is_empty(),
            "a road must be laid to the hex with a pasture", state)

    # Hover: first the basic tooltip, then, after a delay, the extended block.
    main_map.update_tooltip_text(row, col)
    check(tooltip.has_extended_tooltip_info(row, col, main_map.tile_data),
            "on a hex with a road the extended tooltip must be shown", state)
    main_map.update_extended_tooltip(row, col)
    var extended_text := _collect_text(tooltip._tooltip_products_container)
    check(extended_text.contains("Road:"),
            "the extended tooltip must contain the road level row (got: %s)"
                    % extended_text, state)

    # Refresh. We change fill_time so that the fullness text really changes:
    # otherwise the early exit "nothing changed" would trigger, the container would not be
    # touched — and the check would pass without checking anything. It is the changed
    # text that triggers the refresh in the game.
    var ttm: float = float(_gdata.raw_resources.get(res_id, {}).get("time_to_mature", 60.0))
    tile["fill_time"] = ttm * 0.5
    main_map.update_tooltip_text(row, col)
    var after_refresh := _collect_text(tooltip._tooltip_products_container)
    check(after_refresh.contains("Road:"),
            "after the content refresh the road level row must remain (got: %s)"
                    % after_refresh, state)
    # Exactly once: the row must neither be doubled nor be lost.
    check(_count_occurrences(after_refresh, "Road:") == 1,
            "the road level row must be exactly one (got: %s)" % after_refresh, state)

    # A second tick in a row — on a pasture the refresh runs every interval, not once.
    tile["fill_time"] = ttm * 0.75
    main_map.update_tooltip_text(row, col)
    var after_second := _collect_text(tooltip._tooltip_products_container)
    check(after_second.contains("Road:"),
            "after the second refresh the road level row must remain (got: %s)"
                    % after_second, state)

    # After the binding is reset (a hex change / the tooltip is hidden) the extended block
    # is no longer drawn: the basic tooltip still does not show the road level.
    main_map.clear_extended_tooltip()
    main_map.update_tooltip_text(row, col)
    var after_clear := _collect_text(tooltip._tooltip_products_container)
    check(not after_clear.contains("Road:"),
            "after the extended block is reset the road level row must be absent (got: %s)"
                    % after_clear, state)

# The resource id with time_to_mature > 0 (growing — it is refreshed on pastures).
# We take it from the data, and do not hardcode "cows": the check must survive a rename
# or a replacement of the resource in animals.json.
func _find_growing_resource_id() -> String:
    for id in _gdata.raw_resources.keys():
        var data: Dictionary = _gdata.raw_resources.get(id, {})
        if not data.has("produces"):
            continue
        if not _mh.is_growing_resource(data):
            continue
        if str(data.get("improved_by", "")) == "":
            continue
        return str(id)
    return ""


# -------------------------------------------------------
# 10. The "Upgrade road" button on a hex WITHOUT an improvement
# -------------------------------------------------------
#
# The button must be present on a hex with a road even without an improvement:
# the criterion is the route to the city, which consists of trails.
func _test_upgrade_button_on_empty_hex(main_map, state: Dictionary) -> void:
    var panel = main_map.control_panel
    var rm = main_map.road_manager

    # Without a researched second level there is nothing to upgrade — there is no button
    # anywhere, and there is nothing to check.
    if _gdata.get_max_unlocked_road_level() <= 1:
        return

    # _find_hex_in_influence skips hexes with an improvement: that is exactly what we need —
    # we check a hex WITHOUT an improvement.
    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(),
            "a free hex in the influence with a reachable road plan is needed for the check",
            state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    check(main_map.tile_data[row][col].get("improvement", null) == null,
            "the hex for the check must be without an improvement", state)

    # A trail road: the route is of trails, and level 2 is unlocked.
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    var route: Dictionary = main_map.get_route_to_city(row, col)
    check(route.get("ok", false), "an empty hex with a road must have a route", state)
    if not route.get("ok", false):
        return

    var actions: Array = panel._collect_actions(row, col, main_map.tile_data[row][col])
    check(_has_action(actions, panel.UPGRADE_ROAD_TYPE),
            "an empty hex with a road must have an \"Upgrade road\" button", state)


# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# How many times the substring occurs in the text — to check that the row is not
# doubled. The tooltip strings are joined by "\n", so a plain contains()
# (the check "is it there at least once") is not enough for this.
func _count_occurrences(text: String, sub: String) -> int:
    if sub.is_empty():
        return 0
    var count := 0
    var pos := text.find(sub)
    while pos != -1:
        count += 1
        pos = text.find(sub, pos + sub.length())
    return count

func _has_action(actions: Array, type: String) -> bool:
    for action in actions:
        if str(action.get("type", "")) == type:
            return true
    return false

func _collect_text(node: Node) -> String:
    if node == null:
        return ""
    var parts: Array[String] = []
    if node is Label:
        parts.append((node as Label).text)
    elif node is RichTextLabel:
        parts.append(str((node as RichTextLabel).text))
    for child in node.get_children():
        parts.append(_collect_text(child))
    return "\n".join(parts)

# The first free hex in the Ring of Influence: dry, known, without an improvement,
# a town and a road — AND with a road that can really be reached.
#
# The plan check is mandatory: the callers then build a road to the hex, and on some
# randomly generated maps the free hex turns out cut off by a river, and
# the road to it is not built. Then the check would fail because of the map, and not because of the
# rule. If there is no suitable hex at all — we return empty, and the caller
# honestly reports that the scenario is skipped.
func _find_hex_in_influence(main_map) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if _hex_is_busy(main_map, row, col, tile):
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
                continue
            return {"row": row, "col": col}
    return {}

# A hex in the Ring of Influence without a road — the target of the special action "Build road".
# There may be any number of improvements here: a tile with an improvement has already
# received a road automatically.
func _find_hex_without_road(main_map) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or _hex_is_busy(main_map, row, col, tile):
                continue
            # The level of the hex, and not is_hex_connected: a hex may not have a city
            # road, but a TOWN road may pass through it (its route
            # is searched over the whole map and may go outside the ring). The level row
            # now describes it too, therefore "a hex without a road" is exactly
            # get_hex_road_level == 0.
            if main_map.road_manager.get_hex_road_level(row, col) > 0:
                continue
            return {"row": row, "col": col}
    return {}

# Common "the hex does not fit" checks: a town, someone else's territory, fog, water.
func _hex_is_busy(main_map, row: int, col: int, tile: Dictionary) -> bool:
    if tile.get("has_town", false) or tile.get("decorative", false):
        return true
    if tile.get("in_town_influence", false):
        return true
    if not main_map.is_hex_known(row, col):
        return true
    return _mh.is_water_terrain(tile.get("terrain", "plain"))

# Runs the work to completion so that the project finishes.
func _finish_build(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var labor: float = maxf(1.0, float(_cdata.get_total_labor()))
    for i in range(400):
        bm._process(labor * 2.0)
        if main_map.project_manager.projects.is_empty():
            return
    check(false, "the road upgrade project did not finish within the allotted number of frames", state)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
