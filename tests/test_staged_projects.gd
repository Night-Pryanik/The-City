# Headless test of the universal STAGED construction system
# (scripts/project_manager.gd) and of how the road is built on it.
#   godot --headless --path . --script res://tests/test_staged_projects.gd
#
# Checks (the manager alone + the live MainMap scene):
#   1. A project is processed ONE step at a time: no matter how much labor is
#      supplied, exactly one segment is completed per frame, the next one
#      starts, and the bar moves to its hex.
#   2. The ghost = the segments of the not-yet-built steps, and it shrinks by
#      one segment with every completed step.
#   3. The manager does NOT know what a road is: the same mechanism runs a
#      project of another kind (an "aqueduct" in the test) without a single
#      change to the manager's code.
#   4. Cancel: what is built stays, what is not built disappears from the ghost.
#   5. Save/load: the queue and the position are preserved, the counter does not
#      overlap.
#   6. Live scene: exactly one segment is added per frame, the road goes from
#      the network to the target, and the road_built flag is set on every
#      connected hex.
extends SceneTree

# A hang watchdog: without it, a broken _run() coroutine looks like eternal
# silence from the outside. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _pm = null
var _cdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

# The road level is what start_road_project takes as its third argument (the
# action id is not). The level is derived the way the game derives it when the
# player has not picked one, so a road-level balance change does not silently
# turn this into a different scenario.
func _road_level() -> int:
    var game_data = get_root().get_node("GameData")
    return game_data.get_max_unlocked_road_level()

func _run() -> void:
    var state = {"failed": false}

    # We take the autoloads as scene-tree nodes: in --script mode the names
    # GameData and CityData are not yet available at the compile stage of this
    # file. new_game() also loads all the data.
    get_root().get_node("SaveManager").new_game()
    _cdata = get_root().get_node("CityData")

    _pm = load("res://scripts/project_manager.gd").new()
    get_root().add_child(_pm)

    if WATCHDOG.wants_case("one_step_at_a_time"):
        _test_one_step_at_a_time(state)
    if WATCHDOG.wants_case("ghost_shrinks"):
        _test_ghost_shrinks(state)
    if WATCHDOG.wants_case("other_project_kind"):
        _test_other_project_kind(state)
    if WATCHDOG.wants_case("cancel"):
        _test_cancel(state)
    if WATCHDOG.wants_case("save_restore"):
        _test_save_restore(state)

    get_root().remove_child(_pm)
    _pm.free()
    _pm = null

    if WATCHDOG.wants_case("live_road"):
        await _test_live_road(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("STAGED PROJECTS TEST FAILED")
        quit(1)
    else:
        print("STAGED PROJECTS TEST OK")
        quit(0)

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# Builds a queue step: the hex (row, col) is where the progress bar is drawn and
# which ghost segment this step "answers for".
func _make_step(row: int, col: int, work_cost: float, seg: String) -> Dictionary:
    return {
        "label": "Segment %d,%d" % [row, col],
        "work_cost": work_cost,
        "hex": {"row": row, "col": col},
        "ghost": {seg: true},
        "data": {"row": row, "col": col, "segment": seg},
    }

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)


# -------------------------------------------------------
# 1. One step at a time
# -------------------------------------------------------

func _test_one_step_at_a_time(state: Dictionary) -> void:
    var steps := [
        _make_step(1, 1, 10.0, "1,1|1,2"),
        _make_step(1, 2, 10.0, "1,2|1,3"),
        _make_step(1, 3, 10.0, "1,3|1,4"),
    ]
    var completed: Array = []
    var started: Array = []
    _pm.step_completed.connect(func(_id, _kind, step):
        completed.append(step.get("label", "")))
    _pm.step_started.connect(func(_id, _kind, step):
        started.append(step.get("label", "")))

    var pid: String = _pm.start_project("demo", "Demo", 1, 4, steps)
    check(pid != "", "the project should start", state)
    check(_pm.get_active_step_count() == 1,
            "an active project occupies exactly one slot in the labor pool", state)
    check(started.size() == 1 and str(started[0]) == "Segment 1,1",
            "the first step should start immediately", state)

    # We supply labor SIGNIFICANTLY greater than the step's cost: in one call
    # EXACTLY ONE segment should still be completed, not the whole queue.
    _pm.receive_labor(10000.0, 1.0)
    check(completed.size() == 1,
            "exactly one segment is completed per frame, not the whole queue", state)
    check(str(completed[0]) == "Segment 1,1",
            "it must be exactly the current, first segment that is completed", state)
    check(started.size() == 2 and str(started[1]) == "Segment 1,2",
            "after the first segment the second one should start", state)

    # The progress bar has moved to the second segment's hex, and is no longer
    # on the first one.
    check(_pm.get_step_progress_at(1, 1).is_empty(),
            "there should be no progress bar on the hex of a completed segment", state)
    var bar: Dictionary = _pm.get_step_progress_at(1, 2)
    check(not bar.is_empty(), "there should be a progress bar on the hex of the second segment", state)
    check(int(bar.get("step_index", -1)) == 1,
            "the progress bar should correspond to the second step", state)
    check(int(bar.get("steps_left", 0)) == 2,
            "two segments should remain in the progress", state)

    # Labor accumulates rather than being spent: half a step is not enough to
    # complete it.
    _pm.receive_labor(3.0, 1.0)
    check(completed.size() == 1, "an unfinished step should not be completed", state)
    var bar_after: Dictionary = _pm.get_step_progress_at(1, 2)
    check(float(bar_after.get("progress", 0.0)) > 0.0,
            "the progress of the current step should accumulate", state)

    # Topping up to the end: the step is completed, and so on until the last one.
    for _i in range(3):
        _pm.receive_labor(1000.0, 1.0)
    check(completed.size() == 3, "all three segments should be completed", state)
    check(_pm.get_active_step_count() == 0,
            "after the last step the project no longer occupies a slot", state)
    check(_pm.get_project(pid).is_empty(),
            "a finished project should disappear from the queue", state)
    check(_pm.get_step_progress_at(1, 2).is_empty(),
            "after completion the progress bar disappears", state)

# -------------------------------------------------------
# 2. The ghost shrinks with every completed segment
# -------------------------------------------------------

func _test_ghost_shrinks(state: Dictionary) -> void:
    check(_pm.get_pending_ghost_segments().is_empty(),
            "finished projects leave no ghost", state)
    var steps := [
        _make_step(2, 1, 5.0, "2,1|2,2"),
        _make_step(2, 2, 5.0, "2,2|2,3"),
    ]
    var pid: String = _pm.start_project("demo", "Ghost", 2, 3, steps)
    var ghost: Dictionary = _pm.get_pending_ghost_segments()
    check(ghost.size() == 2,
            "the ghost of a new project equals the number of unbuilt segments", state)
    check(ghost.has("2,1|2,2") and ghost.has("2,2|2,3"),
            "the ghost contains the segments of both", state)

    _pm.receive_labor(1000.0, 1.0)
    ghost = _pm.get_pending_ghost_segments()
    check(ghost.size() == 1,
            "after completing a segment the ghost should shrink by one", state)
    check(not ghost.has("2,1|2,2"),
            "a built segment should disappear from the ghost", state)
    check(ghost.has("2,2|2,3"),
            "an unbuilt segment should remain in the ghost", state)

    _pm.receive_labor(1000.0, 1.0)
    check(_pm.get_pending_ghost_segments().is_empty(),
            "after the project ends the ghost should disappear entirely", state)
    _pm.cancel_project(pid)


# -------------------------------------------------------
# 3. Universality: the same manager — another kind of project
# -------------------------------------------------------

func _test_other_project_kind(state: Dictionary) -> void:
    # The same manager, the same order of calls — but a project of another kind.
    # If the manager had been written for a road, the "aqueduct" step would not
    # have gone through.
    var aqueduct_steps := [
        _make_step(5, 5, 20.0, "5,5|5,6"),
        _make_step(5, 6, 20.0, "5,6|5,7"),
    ]
    var done: Array = []
    _pm.step_completed.connect(func(_id, kind, _step):
        if kind == "aqueduct":
            done.append(kind))
    var pid: String = _pm.start_project("aqueduct", "Aqueduct from the mountain", 5, 7,
            aqueduct_steps)
    check(pid != "", "a project of another kind should start the same way", state)
    check(str(_pm.get_step_progress_at(5, 5).get("kind", "")) == "aqueduct",
            "the progress bar should know the kind of project", state)
    _pm.receive_labor(1000.0, 1.0)
    check(done.size() == 1,
            "a step of another kind of project is likewise completed one at a time", state)
    _pm.receive_labor(1000.0, 1.0)
    check(_pm.get_active_step_count() == 0, "a project of another kind finishes too", state)

# -------------------------------------------------------
# 4. Cancel: what is built stays, what is not built does not
# -------------------------------------------------------

func _test_cancel(state: Dictionary) -> void:
    var steps := [
        _make_step(7, 1, 5.0, "7,1|7,2"),
        _make_step(7, 2, 5.0, "7,2|7,3"),
        _make_step(7, 3, 5.0, "7,3|7,4"),
    ]
    var pid: String = _pm.start_project("demo", "To cancel", 7, 4, steps)
    _pm.receive_labor(1000.0, 1.0)
    check(_pm.get_pending_ghost_segments().size() == 2,
            "before the cancel there are two segments in the ghost", state)

    var cancelled := {"hit": 0}
    _pm.project_cancelled.connect(func(_id, _kind, _meta):
        cancelled["hit"] = int(cancelled["hit"]) + 1)
    check(_pm.cancel_project(pid), "cancelling an active project should work", state)
    check(int(cancelled["hit"]) == 1, "cancelling should emit project_cancelled", state)
    check(_pm.get_project(pid).is_empty(), "a cancelled project disappears from the queue", state)
    check(_pm.get_active_step_count() == 0,
            "a cancelled project no longer occupies a slot in the labor pool", state)
    check(_pm.get_pending_ghost_segments().is_empty(),
            "after a cancel the unbuilt segments disappear from the ghost", state)
    check(not _pm.cancel_project(pid), "a repeated cancel does nothing", state)

# -------------------------------------------------------
# 5. Saving and loading the queue
# -------------------------------------------------------

func _test_save_restore(state: Dictionary) -> void:
    var steps := [
        _make_step(9, 1, 5.0, "9,1|9,2"),
        _make_step(9, 2, 5.0, "9,2|9,3"),
        _make_step(9, 3, 5.0, "9,3|9,4"),
    ]
    var pid: String = _pm.start_project("demo", "To save", 9, 4, steps)
    _pm.receive_labor(1000.0, 1.0)
    var saved: Dictionary = _pm.serialize_projects()
    check(saved.has(pid), "the project's queue should get into the save", state)
    check(int(saved[pid].get("step_index", -1)) == 1,
            "the queue position is written to the save: the first segment is already built", state)

    _pm.cancel_project(pid)
    _pm.restore_projects(saved)
    var restored: Dictionary = _pm.get_project(pid)
    check(not restored.is_empty(), "the project should be restored from the save", state)
    check(int(restored.get("step_index", -1)) == 1,
            "after loading the queue continues from the same place", state)
    check(_pm.get_pending_ghost_segments().size() == 2,
            "after loading only the unbuilt segments are in the ghost", state)
    check(not _pm.get_step_progress_at(9, 2).is_empty(),
            "after loading the progress bar sits on the current step", state)
    check(_pm.get_step_progress_at(9, 1).is_empty(),
            "there should be no bar on the segment built before the load", state)

    # A new project after loading should not get an occupied key.
    var next_id: String = _pm.start_project("demo", "After loading", 9, 6, [
        _make_step(9, 6, 5.0, "9,6|9,7")])
    check(next_id != pid, "a new project after loading gets a free key", state)
    _pm.restore_projects({})
    check(_pm.get_active_step_count() == 0,
            "restoring an empty save clears the queue", state)

# -------------------------------------------------------
# 6. Live scene: the road is built one hex at a time
# -------------------------------------------------------

func _test_live_road(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var pm = main_map.project_manager
    # Manual frame stepping instead of automatic: otherwise the engine will run
    # several frames by itself between the start of the road and the checks, and
    # "one segment was completed in one frame" could not be checked at all.
    main_map.build_manager.set_process(false)

    # A hex of the Influence Ring to which a road longer than one segment can
    # actually be extended (otherwise there is nothing to check the staging on).
    var target := _find_hex_without_road(main_map)
    check(not target.is_empty(),
            "on the live map there should be a hex without a road 2+ segments away", state)
    if target.is_empty():
        get_root().remove_child(main_map)
        main_map.free()
        return
    var row := int(target.row)
    var col := int(target.col)

    var plan: Dictionary = main_map.get_road_plan(row, col)
    check(plan.get("ok", false), "there should be a route to the selected hex: %s"
            % plan.get("reason", ""), state)
    var total_segments := int(plan.get("segments", 0))

    var previous_flag: bool = bool(_cdata.ignore_build_requirements)
    _cdata.ignore_build_requirements = false
    check(main_map.start_road_project(row, col, _road_level()),
            "the road should be startable on the live scene", state)
    var project: Dictionary = pm.get_project_at(row, col)
    var step_count: int = project.get("steps", []).size()
    check(step_count == total_segments,
            "the queue should have as many steps as there are new segments: %d and %d"
                    % [step_count, total_segments], state)
    check(pm.get_pending_ghost_segments().size() == step_count,
            "the project's ghost equals the whole queue", state)

    # One frame of labor distribution — and EXACTLY ONE road segment. The delta
    # is picked to match the step's price: in headless the population = 1
    # citizen, so labor comes at a speed of 1 unit per second, and a road
    # segment costs 3. We supply with a margin for ONE segment, but certainly
    # less than two — otherwise "one hex at a time" could not be checked.
    var first_cost: float = float(project.get("steps", [{}])[0].get("work_cost", 1.0))
    var labor_per_build: float = maxf(0.001, _cdata.get_total_labor())
    var delta: float = first_cost * 1.5 / labor_per_build
    main_map.build_manager._process(delta)
    var built: Dictionary = rm.get_all_road_segments()
    check(built.size() == 1,
            "exactly one road segment should be completed per frame", state)
    var ghost_after: Dictionary = pm.get_pending_ghost_segments()
    check(ghost_after.size() == step_count - 1,
            "after completing a segment the ghost should shrink by one", state)
    check(int(pm.get_project_at(row, col).get("step_index", -1)) == 1,
            "the queue should move to the second segment", state)

    # The road_built flag is set on the hex that the segment JOINS to the
    # network: the network is restored from the save by these flags, so a
    # half-built road is not lost. The first step connects a hex of the city
    # that already has a road (it has no flag — the road there comes from an
    # improvement), so exactly one is marked.
    var flagged := 0
    for key in built.keys():
        for endpoint in str(key).split("|"):
            var xy := str(endpoint).split(",")
            if xy.size() == 2 \
                    and bool(main_map.tile_data[int(xy[0])][int(xy[1])].get("road_built", false)):
                flagged += 1
    check(flagged == 1,
            "the hex joined by the segment should be marked road_built", state)
    var first_step: Dictionary = project.get("steps", [{}])[0]
    var joined: Dictionary = first_step.get("data", {}).get("to", {})
    check(bool(main_map.tile_data[int(joined.get("row", 0))][int(joined.get("col", 0))]
            .get("road_built", false)),
            "road_built should be set on the hex the road has reached", state)

    # Finish the remainder one segment per frame. The per-frame labour is sized for the
    # MOST EXPENSIVE segment of the queue, and not for the first one: the price of a
    # segment grows with the distance from the city and the terrain
    # (MapHelpers.get_road_step_work_cost), and the labour left over from a finished step
    # is NOT carried over to the next one. A rate sized for the first segment can fall
    # short of a later segment's price, and then the queue does not finish in the
    # allotted frames — which is exactly what made this test flaky.
    var max_cost: float = first_cost
    for step in project.get("steps", []):
        max_cost = maxf(max_cost, float(step.get("work_cost", 0.0)))
    var finish_delta: float = max_cost * 1.5 / labor_per_build
    for _i in range(step_count + 2):
        if not pm.has_active_projects():
            break
        main_map.build_manager._process(finish_delta)
    check(rm.is_hex_connected(row, col),
            "after the whole queue is built the hex should get a road", state)
    check(bool(main_map.tile_data[row][col].get("road_built", false)),
            "the road_built flag should be set on the target hex", state)
    check(pm.get_pending_ghost_segments().is_empty(),
            "after the project finishes the ghost should disappear", state)
    check(main_map.map_renderer._project_ghost_segments.is_empty(),
            "the renderer should also remove the project's ghost", state)

    _cdata.ignore_build_requirements = previous_flag
    get_root().remove_child(main_map)
    main_map.free()

# A hex of the Influence Ring without a road that a route of 2+ segments reaches.
func _find_hex_without_road(main_map) -> Dictionary:
    var rm = main_map.road_manager
    var mh = load("res://scripts/map_helpers.gd")
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
            if rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols)
            if not plan.get("ok", false) or int(plan.get("segments", 0)) < 2:
                continue
            return {"row": row, "col": col}
    return {}
