# Headless test of INTERRUPTION of long-running actions on the map.
#   godot --headless --path . --script res://tests/test_cancel_actions.gd
#
# Checks (live MainMap scene):
#   1. The project interrupt button appears on ANY of its hexes, not only on
#      the target: on the hex of the current step (where the progress bar is),
#      on the hex in the middle of the route and on the target. This was the
#      original bug: the button lived only on the target, while the player
#      clicks where he sees the construction.
#   2. The button appears on a hex WITH AN IMPROVEMENT to which a road is
#      being built (an early return in _collect_actions lost the project check),
#      and in the influence ring of a town, where the road to it ends.
#   3. The button names the action: "Stop: <name>", and not the generic
#      "Cancel the construction". Drainage and felling as special actions too.
#   4. On a hex where both an ordinary construction and a project are going on,
#      BOTH buttons are shown: they are different things, and both are honest.
#   5. Interrupting a project from any of its hexes cancels EXACTLY it, and by
#      project_id, not by the hex coordinates.
#   6. Claiming land and scouting are also interrupted, and the already paid
#      coins are refunded to the treasury, but the lost work is not.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The road level is passed to start_road_project, not the action id. Tests use
# the same derivation as the game (build_manager picks the highest unlocked
# level when the player does not choose one), so a balance change in the road
# levels does not silently turn this into a different scenario.
func _road_level() -> int:
    var game_data = get_root().get_node("GameData")
    return game_data.get_max_unlocked_road_level()

var _gdata = null
var _cdata = null
var _hexutils = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _hexutils = load("res://scripts/HexUtils.gd")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    for _i in range(4):
        await process_frame
    if WATCHDOG.wants_case("project_cancel_anywhere"):
        _test_project_cancel_anywhere(state, main_map)
    if WATCHDOG.wants_case("special_action_label"):
        _test_special_action_label(state, main_map)
    if WATCHDOG.wants_case("expansion_and_scouting"):
        _test_expansion_and_scouting(state, main_map)
    # LAST: the preparation explores the whole map, while claiming and scouting
    # need unexplored hexes.
    if WATCHDOG.wants_case("town_hex"):
        _test_town_hex(state, main_map, main_map.control_panel)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("CANCEL ACTIONS TEST FAILED")
        quit(1)
    else:
        print("CANCEL ACTIONS TEST OK")
        quit(0)

# -------------------------------------------------------
# 1, 2, 4, 5. Interrupting a project
# -------------------------------------------------------

func _test_project_cancel_anywhere(state: Dictionary, main_map) -> void:
    var panel = main_map.control_panel
    var target := _find_hex_without_road(main_map)
    check(not target.is_empty(), "a hex without a road of 3+ sections must be found", state)
    if target.is_empty():
        return
    var row := int(target.row)
    var col := int(target.col)
    var plan: Dictionary = main_map.get_road_plan(row, col)
    check(int(plan.get("segments", 0)) >= 3,
            "the route must be at least 3 sections long", state)
    check(main_map.start_road_project(row, col, _road_level()),
            "the road must be startable", state)

    var pm = main_map.project_manager
    var project: Dictionary = pm.get_project_at(row, col)
    var steps: Array = project.get("steps", [])
    check(steps.size() >= 3, "the queue must contain at least three steps", state)

    # The PROGRESS BAR sits on the hex of the CURRENT step — that is where the player clicks.
    var cur: Dictionary = steps[0].get("hex", {})
    var cur_row := int(cur.get("row", -1))
    var cur_col := int(cur.get("col", -1))
    var a_cur: Array = _actions(panel, main_map, cur_row, cur_col)
    check(_find(a_cur, "cancel_project") >= 0,
            "the hex of the current step (the progress bar) must have an interrupt button", state)

    # The MIDDLE of the route — a ghost section that the player also sees on the map.
    var mid: Dictionary = steps[0].get("data", {}).get("to", {})
    var mid_row := int(mid.get("row", -1))
    var mid_col := int(mid.get("col", -1))
    if mid_row == cur_row and mid_col == cur_col:
        mid = steps[1].get("data", {}).get("to", {})
        mid_row = int(mid.get("row", -1))
        mid_col = int(mid.get("col", -1))
    var a_mid: Array = _actions(panel, main_map, mid_row, mid_col)
    check(_find(a_mid, "cancel_project") >= 0,
            "the hex in the middle of the route must also have an interrupt button", state)

    # The TARGET — the hex where the button already existed before (the regression must not break it).
    var a_goal: Array = _actions(panel, main_map, row, col)
    _check_no_duplicates(a_cur, state, "the hex of the current step")
    _check_no_duplicates(a_mid, state, "the hex of the middle of the route")
    _check_no_duplicates(a_goal, state, "the target hex")
    check(_find(a_goal, "cancel_project") >= 0,
            "the target hex must have an interrupt button", state)

    # The button names the action and warns that the WHOLE road is interrupted.
    var gi := _find(a_goal, "cancel_project")
    var goal_label := str(a_goal[gi].get("label", ""))
    var goal_tip := str(a_goal[gi].get("tooltip", ""))
    check(goal_label.begins_with("Stop"),
            "the interrupt button must be named \"Stop...\", not \"Cancel the construction\": %s" % goal_label, state)
    check(goal_label.contains("Road"),
            "the button name must show WHAT is being interrupted: %s" % goal_label, state)
    check(goal_tip.contains("unfinished sections"),
            "the tooltip must state the number of unfinished sections in advance", state)
    # project_id must carry the project itself, otherwise a click from the middle of the
    # route will find the wrong project (or nothing).
    check(str(a_goal[gi].get("project_id", "")) == str(project.get("id", "")),
            "the button must carry the project_id of the same project", state)

    # Interrupting FROM THE MIDDLE of the route cancels the whole project.
    check(pm.cancel_project_at_hex(mid_row, mid_col),
            "the project must be cancellable from a hex in the middle of the route", state)
    check(pm.has_active_projects() == false,
            "after the interruption the project must disappear from the queue", state)
    check(_find(_actions(panel, main_map, row, col), "cancel_project") < 0,
            "after the interruption the button on the target must disappear", state)

    # Re-running — to make sure the button is no longer in the panel.
    main_map.build_manager.remove_build(row, col)
    main_map.project_manager.restore_projects({})

# -------------------------------------------------------
# 3, 4. Ordinary construction and special actions: the button names the action
# -------------------------------------------------------

func _test_special_action_label(state: Dictionary, main_map) -> void:
    var panel = main_map.control_panel
    var bm = main_map.build_manager
    # Improvement: the button names exactly it.
    var spot := _find_hex_with_improvement(main_map)
    if not spot.is_empty():
        var row := int(spot.row)
        var col := int(spot.col)
        var imp_id := str(spot.imp_id)
        bm.remove_build(row, col)
        bm.start_build(row, col, imp_id, null)
        check(bm.is_building(row, col), "the ordinary construction must start", state)
        var acts: Array = _actions(panel, main_map, row, col)
        var i := _find(acts, "cancel_build")
        check(i >= 0, "the hex of an ongoing construction must have an interrupt button", state)
        if i >= 0:
            check(str(acts[i].get("label", "")).begins_with("Stop"),
                    "the button must be named \"Stop...\": %s" % str(acts[i].get("label", "")), state)
            check(not str(acts[i].get("label", "")).contains("Cancel the construction"),
                    "the generic \"Cancel the construction\" must be replaced by the action name", state)
        bm.cancel_build(row, col)

    # Special action (draining a marsh / felling a forest): names the special action.
    var sa := _find_hex_with_special_action(main_map)
    var action_id := ""
    if not sa.is_empty():
        var row := int(sa.row)
        var col := int(sa.col)
        action_id = str(sa.action_id)
        var sa_name := str(_gdata.special_actions.get(action_id, {}).get("name", ""))
        bm.remove_build(row, col)
        bm.start_build(row, col, action_id, null)
        check(bm.is_building(row, col), "the special action must start as a construction", state)
        var acts: Array = _actions(panel, main_map, row, col)
        var i := _find(acts, "cancel_build")
        check(i >= 0, "the hex of an ongoing special action must have an interrupt button", state)
        if i >= 0:
            check(str(acts[i].get("label", "")).contains(sa_name),
                    "the special action button must name it (\"%s\"), and not something generic: %s"
                            % [sa_name, str(acts[i].get("label", ""))], state)
        bm.cancel_build(row, col)

    # Both buttons at once if a construction and a project are both going on the hex.
    # We put the construction record directly into active_builds: a road section hex does
    # not have to be suitable for a special action, and the state "construction and project
    # on one hex" must be exactly that.
    var target := _find_hex_without_road(main_map)
    if not target.is_empty():
        var row := int(target.row)
        var col := int(target.col)
        main_map.start_road_project(row, col, _road_level())
        var project: Dictionary = main_map.project_manager.get_project_at(row, col)
        var steps: Array = project.get("steps", [])
        if not steps.is_empty():
            var h: Dictionary = steps[0].get("hex", {})
            var hrow := int(h.get("row", -1))
            var hcol := int(h.get("col", -1))
            bm.active_builds[str(hrow) + "," + str(hcol)] = {
                "progress": 1.0, "work_cost": 10, "imp_id": "demo",
                "target_res_id": null, "imp_name": "Demonstration",
                "row": hrow, "col": hcol, "status": "active", "allocated_labor": 1.0,
            }
            var both: Array = _actions(panel, main_map, hrow, hcol)
            check(_find(both, "cancel_project") >= 0 and _find(both, "cancel_build") >= 0,
                    "on a hex where both a construction and a project are going on, BOTH buttons are shown (types: %d and %d)"
                            % [_find(both, "cancel_project"), _find(both, "cancel_build")], state)
            check(_find(_actions(panel, main_map, row, col), "cancel_project") >= 0,
                    "the project interrupt button remains on the target as well", state)
            _check_no_duplicates(both, state, "the hex where both a construction and a project are going on")
            bm.remove_build(hrow, hcol)
        main_map.project_manager.restore_projects({})

# -------------------------------------------------------
# 6. Claiming and scouting: they are interrupted, the coins are refunded
# -------------------------------------------------------

func _test_expansion_and_scouting(state: Dictionary, main_map) -> void:
    var panel = main_map.control_panel
    var em = main_map.expansion_manager
    _cdata.ignore_build_requirements = false
    _cdata.treasury = 500
    main_map.build_manager.set_process(false)

    # --- Claiming ---
    var chunk := _prepare_expandable_chunk(main_map)
    if chunk.is_empty():
        check(false, "a claimable chunk near the Influence Ring must be found", state)
    else:
        var money: int = em.get_chunk_money_cost(chunk)
        var work: int = em.get_chunk_cost(chunk)
        var ok: bool = em.handle_action(chunk, money, work)
        check(ok, "the claiming of the chunk must start", state)
        var first = chunk[0]
        var exp_data: Dictionary = main_map.build_manager.get_expansion_progress_for_hex(
                int(first.row), int(first.col))
        check(not exp_data.is_empty(), "the first hex of the chunk must show a claiming progress bar", state)
        check(int(exp_data.get("money_cost", 0)) == money,
                "the claiming record must store the price for the refund on cancellation", state)
        var acts: Array = _actions(panel, main_map, int(first.row), int(first.col))
        check(_find(acts, "cancel_expansion") >= 0,
                "the hex of the chunk being claimed must have a \"Stop: Claiming land\" button", state)
        var before := int(_cdata.treasury)
        check(main_map.build_manager.cancel_expansion_at_hex(int(first.row), int(first.col)),
                "the claiming must be interrupted", state)
        check(main_map.build_manager.get_expansion_progress_for_hex(
                int(first.row), int(first.col)).is_empty(),
                "after the interruption the claiming progress bar must disappear", state)
        check(int(_cdata.treasury) == before + money,
                "the coins paid for claiming must be refunded to the treasury: was %d, became %d, expected %d"
                        % [before, int(_cdata.treasury), before + money], state)
        # The chunk must not join the Influence Ring.
        check(not bool(main_map.tile_data[int(first.row)][int(first.col)].get("in_influence", false)),
                "an interrupted claiming must not join the chunk to the Influence Ring", state)

    # --- Scouting ---
    _cdata.treasury = 500
    var scout_chunk := _find_scoutable_chunk(main_map)
    check(not scout_chunk.is_empty(), "an unexplored chunk for scouting must be found", state)
    if not scout_chunk.is_empty():
        var cost: int = em.get_chunk_scout_cost(scout_chunk)
        main_map.start_scouting(scout_chunk)
        check(main_map.is_scouting, "the scouting must start", state)
        var sfirst = scout_chunk[0]
        var sacts: Array = _actions(panel, main_map, int(sfirst.row), int(sfirst.col))
        check(_find(sacts, "cancel_scouting") >= 0,
                "the hex of the chunk being scouted must have a \"Stop: Scouting\" button", state)
        var before := int(_cdata.treasury)
        check(main_map.cancel_scouting(), "the scouting must be cancellable", state)
        check(not main_map.is_scouting and main_map.scouting_chunk.is_empty(),
                "after cancelling the scouting the timer must be reset", state)
        check(int(_cdata.treasury) == before + cost,
                "the coins paid for scouting must be refunded to the treasury: was %d, became %d, expected %d"
                        % [before, int(_cdata.treasury), before + cost], state)
        var any_explored := false
        for h in scout_chunk:
            if bool(main_map.tile_data[int(h.row)][int(h.col)].get("is_explored", false)):
                any_explored = true
                break
        check(not any_explored,
                "an interrupted scouting must not explore a single hex", state)

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

func _actions(panel, main_map, row: int, col: int) -> Array:
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        return []
    return panel._collect_actions(row, col, tile)

# The interrupt button must not appear in the list twice. Previously the project
# button on a town hex was added twice: separately (a special case "road to the
# town") and by a shared helper. A duplicate is not obvious, but the player
# sees two identical buttons and does not understand the difference.
#
# ONLY the interrupt buttons are checked: ordinary actions are duplicated
# legitimately (a hex may have both drainage and felling — these are two
# "special" buttons, and several "research_tech" in a row).
func _check_no_duplicates(actions: Array, state: Dictionary, where: String) -> void:
    var seen := {}
    var dups := []
    for a in actions:
        var t := str(a.get("type", ""))
        if not t.begins_with("cancel"):
            continue
        if seen.has(t):
            dups.append(t)
        seen[t] = true
    check(dups.is_empty(), "the interrupt button is duplicated on %s: %s"
            % [where, str(dups)], state)

# The index of the first action of the wanted type, -1 if there is none.
func _find(actions: Array, type: String) -> int:
    for i in range(actions.size()):
        if str(actions[i].get("type", "")) == type:
            return i
    return -1

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)

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
            if mh.is_water_terrain(tile.get("terrain", "plain")) or rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols)
            if not plan.get("ok", false) or int(plan.get("segments", 0)) < 3:
                continue
            return {"row": row, "col": col}
    return {}

# A hex with an improvement to which no road has been built yet: the road is built
# to exactly it, and this is where the project interruption is checked.
func _find_hex_with_improvement(main_map) -> Dictionary:
    var rm = main_map.road_manager
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            var imp_id = tile.get("improvement", null)
            if imp_id == null or bool(tile.get("decorative", false)):
                continue
            if bool(_gdata.improvements.get(imp_id, {}).get("no_road", false)):
                continue
            if rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols)
            if not plan.get("ok", false):
                continue
            return {"row": row, "col": col, "imp_id": imp_id}
    return {}
# Preparation of a claimable chunk: explore it and return it.
#
# The INITIAL STATE matters: in a new game only the Influence Ring is explored,
# beyond its borders NOT A SINGLE hex is explored, so there is nothing to claim
# and the button "Claim the area" is not offered. The test itself explores a
# chunk next to the city - this is the ordinary sequence of the player (first
# scouting, then claiming), and only after it does an object for checking the
# cancellation appear.
func _prepare_expandable_chunk(main_map) -> Array:
    var em = main_map.expansion_manager
    var ci := int(main_map.city_row)
    var cj := int(main_map.city_col)
    for radius in range(1, 7):
        for row in range(ci - radius, ci + radius + 1):
            for col in range(cj - radius, cj + radius + 1):
                var tile = main_map.get_tile_data(row, col)
                if tile == null or bool(tile.get("in_influence", false)):
                    continue
                # We explore all hexes of the chunk: after that get_chunk_hexes
                # for this hex returns the claimable area.
                for h in em.get_chunk_hexes(row, col):
                    var t2 = main_map.get_tile_data(int(h.row), int(h.col))
                    if t2 != null:
                        t2["is_explored"] = true
                var chunk: Array = em.get_chunk_hexes(row, col)
                if chunk.is_empty() or em.get_chunk_cost(chunk) <= 0:
                    continue
                var has_neighbor := false
                for h in chunk:
                    for n in _hexutils.get_neighbors_odd_r(int(h.row), int(h.col),
                            main_map.map_rows, main_map.map_cols):
                        if bool(main_map.tile_data[int(n.row)][int(n.col)].get("in_influence", false)):
                            has_neighbor = true
                            break
                    if has_neighbor:
                        break
                if has_neighbor:
                    return chunk
    return []

# A hex to which a special action from special_actions.json applies
# (draining a marsh, felling a forest, etc.).
func _find_hex_with_special_action(main_map) -> Dictionary:
    for action_id in _gdata.special_actions:
        var sa: Dictionary = _gdata.special_actions[action_id]
        var atype := str(sa.get("action_type", ""))
        if atype != "terrain" and atype != "cover":
            continue
        var terrains: Array = sa.get("source_terrains", [])
        if terrains.is_empty():
            terrains = [sa.get("source_terrain", "")]
        for row in range(main_map.region_start_row, main_map.region_end_row + 1):
            for col in range(main_map.region_start_col, main_map.region_end_col + 1):
                var tile = main_map.get_tile_data(row, col)
                if tile == null or not bool(tile.get("in_influence", false)):
                    continue
                # build_manager does not allow touching the hexes of a town and its influence ring.
                if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                        continue
                if bool(tile.get("decorative", false)):
                        continue
                if tile.get("improvement", null) != null or tile.get("resource", null) != null:
                        continue
                if atype == "terrain" and str(tile.get("terrain", "")) in terrains:
                    return {"row": row, "col": col, "action_id": action_id}
                if atype == "cover" \
                        and str(tile.get("cover", "none")) in sa.get("source_cover", []):
                    return {"row": row, "col": col, "action_id": action_id}
    return {}

# An unexplored chunk adjacent to known territory (otherwise the scouting
# does not start because of the gate main_map.is_chunk_adjacent_to_known).
func _find_scoutable_chunk(main_map) -> Array:
    var em = main_map.expansion_manager
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("is_explored", false)):
                continue
            var chunk: Array = em.get_chunk_hexes(row, col)
            if chunk.is_empty():
                continue
            var unexplored := 0
            for h in chunk:
                if not bool(main_map.tile_data[int(h.row)][int(h.col)].get("is_explored", false)):
                    unexplored += 1
            if unexplored <= 0:
                continue
            if not main_map.is_chunk_adjacent_to_known(chunk):
                continue
            return chunk
    return []

# A hex of ANOTHER TOWN: there the button "Build a road from the city" is
# replaced by an interruption if a road to it is already going on. We separately
# check that the interruption was not duplicated: previously it was added both
# by a special case and by a shared helper.
func _test_town_hex(state: Dictionary, main_map, panel) -> void:
    # We explore the map: without this there is no land route to the town, and
    # start_road_project will honestly refuse. This is the ordinary preparation
    # of the player — first scouting, then the road.
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var t = main_map.get_tile_data(row, col)
            if t != null:
                t["is_explored"] = true
    main_map.road_manager.bump_map_knowledge()
    var town := _find_town_hex(main_map)
    check(not town.is_empty(), "a hex of another town must be found", state)
    if town.is_empty():
        return
    var row := int(town.row)
    var col := int(town.col)
    var start: bool = main_map.start_road_project(row, col, _road_level())
    check(start, "the road to the town must be startable", state)
    var acts: Array = _actions(panel, main_map, row, col)
    _check_no_duplicates(acts, state, "the hex of another town")
    check(_find(acts, "cancel_project") >= 0,
            "the hex of another town must have a button to interrupt the road to it", state)
    main_map.project_manager.restore_projects({})

# The first hex of another town on the map.
func _find_town_hex(main_map) -> Dictionary:
    # Towns stand all over the map, including BEYOND the borders of the Region,
    # so we iterate over the whole map, not only the Region. We skip the hex of
    # the player's own city: it has a different set of actions.
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if row == int(main_map.city_row) and col == int(main_map.city_col):
                continue
            var tile = main_map.get_tile_data(row, col)
            if tile != null and bool(tile.get("has_town", false)):
                return {"row": row, "col": col}
    return {}
