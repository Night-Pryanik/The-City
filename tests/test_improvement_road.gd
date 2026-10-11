# Headless test for the road that is built TOGETHER with an improvement.
#   godot --headless --path . --script res://tests/test_improvement_road.gd
#
# Checks (live MainMap scene):
#   1. CHAIN. Confirming construction of an improvement starts ONE staged
#      project and occupies ONE slot: first the road segments go, the last
#      step is the construction of the improvement itself.
#   2. STAGING AND COST. The road segments and the improvement are each paid
#      for separately; the road cost is not part of the improvement cost
#      (otherwise labor would be charged twice). Base level 1 (trail) is paid
#      too.
#   3. ONE SLOT. An improvement with a road fits within the one-construction
#      limit, and a hex with a running chain cannot be taken by a second
#      construction.
#   4. PREVIEW. Shows both the improvement cost and the road cost (with its
#      level and the number of new segments), and the total.
#   5. SAVE. Recalculating roads after an improvement (rebuild_roads_from_existing)
#      skips hexes with road_staged — otherwise it would finish an unfinished or
#      canceled road for free.
extends SceneTree

# Watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Road level for all checks: the base trail. It used to be free, so the check
# must use it — paid level 2 is charged anyway, and the bug would not show on it.
const TRAIL_LEVEL := 1

var _cdata = null
var _gdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken as scene-tree nodes: in --script mode the names
    # GameData and CityData are not yet available when this file is compiled.
    # new_game() also loads all data, including roads.json.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    if WATCHDOG.wants_case("chain"):
        _test_chain(main_map, state)
    if WATCHDOG.wants_case("single_slot"):
        _test_single_slot(main_map, state)
    if WATCHDOG.wants_case("instant_debug_flag"):
        _test_instant_debug_flag(main_map, state)
    if WATCHDOG.wants_case("preview"):
        _test_preview(main_map, state)
    if WATCHDOG.wants_case("save_restore"):
        _test_save_restore(main_map, state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("IMPROVEMENT ROAD TEST FAILED")
        quit(1)
    else:
        print("IMPROVEMENT ROAD TEST OK")
        quit(0)
# -------------------------------------------------------
# 1, 2. The "road → improvement" chain: order, staging, separate costs
# -------------------------------------------------------

func _test_chain(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var pm = main_map.project_manager
    var rm = main_map.road_manager
    # No spare slots are needed: the whole chain occupies exactly one slot, so
    # the check runs with a limit of one citizen, as in a new game.
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(),
            "the check needs a hex under influence that a route reaches", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    check(not imp_id.is_empty(), "the data must contain an improvement without no_road", state)
    if imp_id.is_empty():
        return

    var plan: Dictionary = main_map.get_road_plan(row, col)
    var plan_segments := int(plan.get("segments", 0))
    var road_cost := int(main_map.get_road_cost_breakdown(
            row, col, TRAIL_LEVEL).get("cost", 0))

    # The trail is not free: the road to an improvement used to be not charged
    # at all, and building an improvement on a distant hex was "free with a road".
    check(road_cost > 0,
            "the road to an improvement must cost labor even at the base level", state)
    check(main_map.get_road_cost_for_improvement(row, col, TRAIL_LEVEL) == road_cost,
            "the road cost to an improvement must match the road preview", state)

    # The improvement cost and the road cost are different numbers.
    var cost_data: Dictionary = main_map.get_improvement_work_cost(
            imp_id, row, col, TRAIL_LEVEL)
    var imp_cost := int(cost_data.get("cost", 0))
    var cost_road := int(cost_data.get("road_cost", 0))
    var total := int(cost_data.get("total_cost", 0))
    check(imp_cost > 0, "the improvement must have its own cost", state)
    check(cost_road == road_cost,
            "the improvement's road_cost must match the road cost", state)
    check(total == imp_cost + cost_road,
            "the total must be the sum of the improvement and the road", state)
    check(int(cost_data.get("road_segments", 0)) == plan_segments,
            "the improvement must know how many segments the road will add", state)

    # One confirmation — one chain and EXACTLY one slot. There must be no
    # separate construction entry for the improvement in build_manager: the
    # improvement sits in the project queue as the last step, not in parallel
    # with the road.
    check(bm.start_build(row, col, imp_id, null, TRAIL_LEVEL),
            "the improvement construction must be startable", state)
    check(not bm.is_building(row, col),
            "the improvement must not be a separate construction — it is in the project queue",
            state)
    var project: Dictionary = pm.get_project_at(row, col)
    check(not project.is_empty(),
            "the road to an improvement must run as a staged project", state)
    var steps: Array = project.get("steps", [])
    check(steps.size() == plan_segments + 1,
            "the queue must contain the road segments PLUS the improvement step: %d and %d"
                    % [steps.size(), plan_segments + 1], state)
    check(bm.get_total_active_builds() == 1,
            "the chain must occupy exactly one slot (got: %d)"
                    % bm.get_total_active_builds(), state)

    # The last step is the improvement, and its cost equals the improvement cost from the preview.
    var last_step: Dictionary = steps[steps.size() - 1]
    var last_data: Dictionary = last_step.get("data", {})
    check(str(last_data.get("step_type", "")) == "improvement",
            "the improvement must be the last step of the chain", state)
    check(str(last_data.get("improvement", "")) == imp_id,
            "the improvement step must carry the improvement id", state)
    check(int(last_step.get("work_cost", 0)) == imp_cost,
            "the improvement step must cost exactly the improvement cost: %d and %d"
                    % [int(last_step.get("work_cost", 0)), imp_cost], state)
    var step_sum := 0
    for step in steps:
        step_sum += int(step.get("work_cost", 0))
    check(step_sum == total,
            "the sum of the chain steps must match the preview total: %d and %d"
                    % [step_sum, total], state)

    # The hex has no road and no improvement yet: the road is ahead, segment by segment.
    check(not rm.is_hex_connected(row, col),
            "the hex must not get the road instantly", state)
    check(main_map.tile_data[row][col].get("improvement", null) == null,
            "the improvement must not appear before the road", state)
    check(bool(main_map.tile_data[row][col].get("road_staged", false)),
            "the hex must have the road_staged flag (input data for the save)", state)

    # One frame of labor — exactly one road segment, and the improvement has not
    # started yet: the road and the construction run SEQUENTIALLY. We take the
    # same rate that build_manager hands out: the share of one of all active
    # constructions, not the whole city's labor.
    var step_cost := float(steps[0].get("work_cost", 1.0))
    var labor: float = maxf(0.001, _cdata.get_total_labor())
    var labor_per_build: float = labor / maxf(1.0, float(bm.get_total_active_builds()))
    bm._process(step_cost * 1.5 / labor_per_build)
    check(rm.get_all_road_segments().size() == 1,
            "exactly one road segment must be completed per frame", state)
    check(main_map.tile_data[row][col].get("improvement", null) == null,
            "while the road is being built, the improvement is not placed", state)
    # The bar on the improvement hex belongs to the road segment, not to the
    # construction: while the road is ahead, the current step is a segment.
    check(str(pm.get_step_progress_at(row, col).get("step_type", "")) != "improvement",
            "on the improvement hex the bar must belong to the road segment", state)

    # Finish off the queue: after the last segment the improvement step must run.
    # The rate is for the current step, not for the first segment: the improvement
    # cost may be greater than the segment cost, and a frame sized for a segment
    # would not close the step.
    var guard := 0
    while not pm.get_project_at(row, col).is_empty() and guard < 400:
        var cur: Dictionary = pm.get_project_at(row, col)
        var cur_steps: Array = cur.get("steps", [])
        var idx := int(cur.get("step_index", 0))
        var cur_cost := 1.0
        if idx >= 0 and idx < cur_steps.size():
            cur_cost = maxf(1.0, float((cur_steps[idx] as Dictionary).get("work_cost", 1.0)))
        bm._process(cur_cost * 2.0 / labor_per_build)
        guard += 1
    check(guard < 400, "the queue must finish within a reasonable number of frames", state)
    check(rm.is_hex_connected(row, col),
            "after the queue finishes the hex must get the road", state)
    check(str(main_map.tile_data[row][col].get("improvement", "")) == imp_id,
            "after the road the improvement must be built too", state)
    check(pm.get_project_at(row, col).is_empty(),
            "after the improvement the queue must be empty", state)
    check(bool(main_map.tile_data[row][col].get("road_built", false)),
            "the target hex must have the road_built flag", state)

# -------------------------------------------------------
# 3. The chain fits in one slot, and an occupied hex is not reused
# -------------------------------------------------------

func _test_single_slot(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var pm = main_map.project_manager
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "the limit check needs a hex without a road", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    if imp_id.is_empty():
        return

    # Limit of one construction — as in a new game (one citizen). The
    # "improvement + road" chain used to occupy TWO slots and did not fit such
    # a limit: priority had to go to the road and the improvement had to be
    # refused. Now there is one queue, and one slot is enough for everything.
    var previous_population := int(_cdata.total_population)
    _cdata.total_population = 1
    var started: bool = bm.start_build(row, col, imp_id, null, TRAIL_LEVEL)

    check(started, "an improvement with a road must fit in one slot", state)
    check(bm.get_total_active_builds() == 1,
            "the chain must take the only slot (got: %d)"
                    % bm.get_total_active_builds(), state)
    check(not pm.get_project_at(row, col).is_empty(),
            "the hex must run a road chain with an improvement", state)

    # A hex occupied by the chain cannot be taken again: the queued improvement
    # is not in active_builds, and without this check a second construction would
    # start on the hex.
    check(not bm.start_build(row, col, imp_id, null, TRAIL_LEVEL),
            "a second construction must not start on a hex with a running chain", state)

    pm.cancel_project_at(row, col)
    _cdata.total_population = previous_population

# -------------------------------------------------------
# 4. The "instant" debug flag resolves the whole chain at once
# -------------------------------------------------------

func _test_instant_debug_flag(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var rm = main_map.road_manager
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "the flag check needs a hex without a road", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    if imp_id.is_empty():
        return

    var previous := bool(_cdata.ignore_build_requirements)
    _cdata.ignore_build_requirements = true
    check(bm.start_build(row, col, imp_id, null, TRAIL_LEVEL),
            "with the flag the chain must start", state)
    # One frame of labor distribution: receive_labor(instant) resolves the whole
    # queue, so both the road and the improvement must appear at once.
    bm._process(0.1)
    check(rm.is_hex_connected(row, col),
            "with the flag the road must be laid at once", state)
    check(str(main_map.tile_data[row][col].get("improvement", "")) == imp_id,
            "with the flag the improvement must be built at once", state)
    _cdata.ignore_build_requirements = previous

# -------------------------------------------------------
# 5. The preview shows both costs
# -------------------------------------------------------

func _test_preview(main_map, state: Dictionary) -> void:
    var panel = main_map.control_panel
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "the preview needs a hex without a road", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    if imp_id.is_empty():
        return

    var cost_data: Dictionary = main_map.get_improvement_work_cost(
            imp_id, row, col, TRAIL_LEVEL)
    var imp_cost := int(cost_data.get("cost", 0))
    var road_cost := int(cost_data.get("road_cost", 0))
    var total := int(cost_data.get("total_cost", 0))
    var segments := int(cost_data.get("road_segments", 0))
    check(road_cost > 0 and segments > 0,
            "the preview must count the road to the improvement", state)
    if road_cost <= 0:
        return

    panel.select_hex(row, col)
    panel._preview_action = {
        "type": "build_improvement", "imp_id": imp_id, "action_id": "",
        "target_res_id": null, "label": imp_id, "eff_res": "",
        "selected_culture_id": null, "road_level": TRAIL_LEVEL,
    }
    panel._refresh()
    var text: String = _collect_text(panel._preview_container)
    check(text.contains(str(imp_cost)),
            "the preview must show the improvement cost (%d)" % imp_cost, state)
    check(text.contains(str(road_cost)),
            "the preview must show the road cost (%d)" % road_cost, state)
    check(text.contains(str(total)),
            "the preview must show the total of the improvement and road costs (%d)" % total, state)
    check(text.contains(str(segments)),
            "the preview must show the number of new road segments (%d)" % segments, state)
    # The level name comes from the data and is translated, so it is searched in
    # any language: the road line must name the level it was calculated for.
    check(text.contains(str(_gdata.get_road_name(TRAIL_LEVEL))),
            "the road line must name the selected road level", state)
    panel.clear_preview()

# -------------------------------------------------------
# 5. Restore: a hex with road_staged is not finished for free
# -------------------------------------------------------

func _test_save_restore(main_map, state: Dictionary) -> void:
    var rm = main_map.road_manager
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "the save check needs a hex without a road", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    check(not rm.is_hex_connected(row, col),
            "the source hex must be without a road", state)

    tile["improvement"] = "farm"
    tile["road_staged"] = true
    check(bool(main_map._skip_improvement_road_restore(row, col)),
            "a hex with road_staged must be skipped when recalculating the network", state)
    rm.rebuild_roads_from_existing(main_map.tile_data, main_map.map_rows,
            main_map.map_cols, Callable(main_map, "_skip_improvement_road_restore"))
    check(not rm.is_hex_connected(row, col),
            "the recalculation must not finish a staged road for free", state)

    # Old save: no flag — the road is restored as before.
    tile["road_staged"] = false
    check(not bool(main_map._skip_improvement_road_restore(row, col)),
            "a hex without road_staged is recalculated as before", state)
    rm.rebuild_roads_from_existing(main_map.tile_data, main_map.map_rows,
            main_map.map_cols, Callable(main_map, "_skip_improvement_road_restore"))
    check(rm.is_hex_connected(row, col),
            "the improvement of an old save must get its road again", state)
    tile["improvement"] = null

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# The first improvement that is entitled to a road: with no_road (irrigation
# canal, boats) there is no road by the rules, so such an id is not suitable for
# the check.
func _pick_improvement() -> String:
    for id in _gdata.improvements.keys():
        if not bool(_gdata.improvements[id].get("no_road", false)):
            return str(id)
    return ""

# A hex of the Influence Ring that a route reaches: this is how we look for a
# hex that can still be taken and to which a road really exists.
#
# First we look for a hex with a route of 2+ segments (on it you can see that
# the chain runs segment by segment), and if there is none on the map we take
# any hex with at least one segment. We cannot require two segments: on part of
# the maps the influence ring does not reach the city farther than one hex, and
# the check would fail not because of the rule but because of a randomly
# generated map.
func _find_hex_with_road_plan(main_map) -> Dictionary:
    var rm = main_map.road_manager
    var mh = load("res://scripts/map_helpers.gd")
    var fallback := {}
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("decorative", false)) or tile.get("improvement", null) != null:
                continue
            if mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if main_map.build_manager.is_building(row, col):
                continue
            if not main_map.project_manager.get_project_at(row, col).is_empty():
                continue
            if rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
                continue
            if int(plan.get("segments", 0)) >= 2:
                return {"row": row, "col": col}
            if fallback.is_empty():
                fallback = {"row": row, "col": col}
    return fallback

func _collect_text(node: Node) -> String:
    var out: String = ""
    if node == null:
        return out
    if node is Label or node is RichTextLabel:
        out += str(node.get("text")) + "\n"
    for child in node.get_children():
        out += _collect_text(child)
    return out

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)
