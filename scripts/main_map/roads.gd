@tool
extends "res://scripts/main_map/world.gd"

# This link — the roads: the plan of a road to a hex, its price and its steps, the route the
# goods travel to the city, and the road networks of the city and of the towns. The projects
# that build these roads are one link above (builds.gd).

# The predicate for rebuild_roads_from_existing: this hex is skipped
# on the restoration of the road network.
#
# The reason is one — the road to an improvement, built by a phased project. Its
# state lies in road_built/road_level on the already connected hexes and in
# the queue of the projects, and the recalculation "by the fact of the improvement" (rebuild_
# roads_from_existing) would finish the rest for free, and after the cancellation of the road
# would return it entirely. Such hexes are restored by rebuild_player_roads by
# the flags — exactly the same way as the road built by the special action
# "Build a road".
func _skip_improvement_road_restore(row: int, col: int) -> bool:
    if row < 0 or row >= tile_data.size() or col < 0 or col >= tile_data[row].size():
        return false
    var tile = tile_data[row][col]
    return tile != null and bool(tile.get("road_staged", false))

# Builds the road networks of the towns: from the centre of each town — to its improvements
# in the influence ring, by the same rules as the roads of the city of the player (see
# road_manager.rebuild_town_roads). The networks of the towns are NOT connected to the network of
# the city of the player and to each other.
#
# It is called from two places, and both — strictly after the improvements stand in the rings
# (they are placed by town_manager._place_decorative_town_improvements):
#   - a new game: after road_manager.initialize() in _ready;
#   - loading a save: after the restoration of the towns and their improvements.
# The roads are not saved — the network is recalculated, as well as the city ones.
func _rebuild_town_roads() -> void:
    road_manager.rebuild_town_roads(town_manager.towns, tile_data, map_rows, map_cols)
    # The roads built by the player through the special action "Build a road"
    # (including the connections with the towns) are restored last: their target is the
    # road network of the city, which must already exist. The input data (the flags
    # road_built / road_linked) lie in the save, the segments are counted anew — as for all the other roads.
    road_manager.rebuild_player_roads(tile_data, map_rows, map_cols,
            _road_hex_allowed())

# The price and the steps of the improvement of the road to the hex (row, col) up to the level road_level.
# The SINGLE source for the preview and for the real start — as for a new road.
#
# Only those segments of the route which are below the target level are improved: a segment
# of a higher level is left as is (a road cannot be lowered).
func get_road_upgrade_breakdown(row: int, col: int, road_level: int) -> Dictionary:
    var route: Dictionary = get_route_to_city(row, col)
    if not route.get("ok", false):
        return {"ok": false, "reason": route.get("reason", ""), "cost": 0, "steps": []}
    var segments: Array = route.get("segments", [])
    var levels: Array = route.get("levels", [])
    var steps: Array = []
    var total := 0
    # The steps FROM THE CITY to the target: the path of the route goes from the hex to the city, therefore
    # the indices go in the reverse order.
    for i in range(segments.size() - 1, -1, -1):
        var seg_key: String = str(segments[i])
        if int(levels[i]) >= road_level:
            continue
        var ends := _split_segment_key(seg_key)
        if ends.is_empty():
            continue
        var from_row := int(ends[0])
        var from_col := int(ends[1])
        var to_row := int(ends[2])
        var to_col := int(ends[3])
        # The price of the segment of the improvement is counted by THAT SAME hex, which the step
        # connects to the network during the construction, — that is, by the far end from the city:
        # the route goes from the city, and that end carries the materials further.
        var far_row := to_row
        var far_col := to_col
        if HexUtils.hex_distance(from_row, from_col, city_row, city_col) \
                > HexUtils.hex_distance(to_row, to_col, city_row, city_col):
            far_row = from_row
            far_col = from_col
        var terrain_id := "plain"
        if far_row >= 0 and far_row < tile_data.size() and far_col >= 0 \
                and far_col < tile_data[far_row].size() and tile_data[far_row][far_col] != null:
            terrain_id = str(tile_data[far_row][far_col].get("terrain", "plain"))
        var price := MapHelpers.get_road_step_work_cost(
                road_level, far_row, far_col, city_row, city_col, terrain_id)
        var cost := int(price.get("cost", 0))
        total += cost
        steps.append({
            "label": tr("Upgrade section %d/%d") % [steps.size() + 1, segments.size()],
            "work_cost": cost,
            "price": price,
            "hex": {"row": far_row, "col": far_col},
            # The ghost of the improvement — the same segment: it is already drawn by the road,
            # and the highlighting shows which exactly segment is being improved.
            "ghost": {seg_key: true},
            "data": {
                "from": {"row": from_row, "col": from_col},
                "to": {"row": to_row, "col": to_col},
                "is_upgrade": true,
                "road_level": road_level,
            },
        })
    if steps.is_empty():
        return {"ok": false, "cost": 0, "steps": [],
                "reason": tr("the route is already at this level")}
    return {"ok": true, "reason": "", "cost": total, "steps": steps,
            "segments": steps.size(), "road_level": road_level}

# Parses the key of a segment "row1,col1|row2,col2" into [row1, col1, row2, col2].
# An empty array — the key is damaged; we skip such a segment: improving and
# charging for it is impossible anyway.
func _split_segment_key(key: String) -> Array:
    var ends := key.split("|")
    if ends.size() != 2:
        return []
    var a := ends[0].split(",")
    var b := ends[1].split(",")
    if a.size() != 2 or b.size() != 2:
        return []
    if not (a[0].is_valid_int() and a[1].is_valid_int()
            and b[0].is_valid_int() and b[1].is_valid_int()):
        return []
    return [int(a[0]), int(a[1]), int(b[0]), int(b[1])]

# The public wrapper over the search of the route: it is needed by the control panel (the block
# "Route to the city") and by the renderer (the highlighting of the route on the map). The hex of the town
# is routed by ITS OWN road network, therefore the town is passed to the manager
# separately (see road_manager.find_route_to_city).
func get_route_to_city(row: int, col: int) -> Dictionary:
    var town = find_town_at(row, col)
    if town != null:
        return road_manager.find_route_to_city(row, col,
                int(town.get("row", -1)), int(town.get("col", -1)))
    return road_manager.find_route_to_city(row, col)

# The average speed of the route from the hex to the city, or -1.0 when there is no route.
# -1.0 (and not 0.0) marks "no route": the road does not limit the transport then, and the
# caller must tell the two cases apart (a road with a zero speed does not exist).
func _route_avg_speed(row: int, col: int) -> float:
    var route: Dictionary = get_route_to_city(row, col)
    if not route.get("ok", false):
        return -1.0
    return float(route.get("avg_speed", 0.0))

# Turns the plan of the road into the queue of the steps — one per new segment.
#
# This is the SINGLE source of the price of the road. Both the preview in the panel and the real
# start of the project take the steps from here, therefore "how much was shown" and "how much is
# taken" cannot diverge: the steps are the only place where a segment is priced.
#
# The order of the steps is FROM THE NETWORK TO THE TARGET, although plan_road_to returns the path from the target
# to the city (that is how the search builds it). This is not cosmetics: each step has two hexes,
# and building from the network means that the segment is always connected to the already finished
# road, and does not hang in the air until the end of the build. For the same reason
# the progress bar travels from the city to the target, and the ghost is "eaten" from the city.
#
# The price of the step (MapHelpers.get_road_step_work_cost) depends on the hex to_hex:
# the terrain, the distance from the city, the technologies. There is no separate surcharge for the length of
# the route — a long road takes longer to build because there are more segments.
func _build_road_steps(plan: Dictionary, road_level: int) -> Array:
    var road_path: Array = plan.get("path", [])
    var is_town := bool(plan.get("is_town", false))
    if road_path.size() < 2:
        return []

    # Only the NEW segments: the already laid ones do not need to be paid for (there will be
    # no step for them in the queue, and they will not appear in the ghost either). The path goes from
    # the target to the city, therefore we reverse the new segments — step by step from
    # the network.
    var pairs: Array = []
    for i in range(road_path.size() - 2, -1, -1):
        var from_hex: Dictionary = road_path[i + 1]
        var to_hex: Dictionary = road_path[i]
        var f_row := int(from_hex.get("row", -1))
        var f_col := int(from_hex.get("col", -1))
        var t_row := int(to_hex.get("row", -1))
        var t_col := int(to_hex.get("col", -1))
        if f_row < 0 or t_row < 0:
            continue
        if road_manager.has_road_between(f_row, f_col, t_row, t_col):
            continue
        pairs.append({
            "from": {"row": f_row, "col": f_col},
            "to": {"row": t_row, "col": t_col},
            "ghost": {road_manager.get_road_segment_key(f_row, f_col, t_row, t_col): true},
        })
    if pairs.is_empty():
        return []

    var steps: Array = []
    for i in range(pairs.size()):
        var pair: Dictionary = pairs[i]
        var to_hex: Dictionary = pair["to"]
        var t_row := int(to_hex["row"])
        var t_col := int(to_hex["col"])
        # The terrain of the hex to: it is exactly its step that connects it to the network, and the price
        # is already counted by it. The hex from is already in the network, it has been paid for earlier.
        var terrain_id := "plain"
        if t_row >= 0 and t_row < tile_data.size() and t_col >= 0 \
                and t_col < tile_data[t_row].size() and tile_data[t_row][t_col] != null:
            terrain_id = str(tile_data[t_row][t_col].get("terrain", "plain"))
        var price := MapHelpers.get_road_step_work_cost(
                road_level, t_row, t_col, city_row, city_col, terrain_id)
        steps.append({
            "label": tr("Section %d/%d") % [i + 1, pairs.size()],
            "work_cost": int(price.get("cost", 0)),
            # The details of the calculation — for the tooltip on the progress bar and for the preview.
            "price": price,
            # The progress bar is drawn on the hex which the step connects to the network.
            "hex": {"row": t_row, "col": t_col},
            "ghost": pair["ghost"],
            "data": {
                "from": pair["from"],
                "to": pair["to"],
                "is_town": is_town,
                # The level of the segment travels in the step, and is not taken in the handler of
                # the completion: there the level chosen by the player is already gone, there is
                # only the signal "the step is ready".
                "road_level": road_level,
            },
        })
    return steps

# The price of the road and its steps for the preview in the control panel. It returns
# {ok, reason, cost, steps}, where cost is the EXACT sum of the prices of the steps.
#
# The invariant "the sum of the steps = the price in the preview" holds by construction: each
# step is rounded up separately, and the total is simply summed up.
func get_road_cost_breakdown(row: int, col: int, road_level: int) -> Dictionary:
    var plan := get_road_plan(row, col)
    if not plan.get("ok", false):
        return {"ok": false, "reason": plan.get("reason", tr("Cannot build a road")),
                "cost": 0, "steps": []}
    var steps := _build_road_steps(plan, road_level)
    if steps.is_empty():
        return {"ok": false, "reason": tr("No new sections on this route"),
                "cost": 0, "steps": []}
    var total := 0
    # The minimums start from -1, and NOT from INF: mini()/maxi() lower the type to int, and
    # INF becomes INT64_MIN, on which the minimum "sticks" forever
    # (it showed up as the distance -9223372036854775808 in the preview).
    var min_cost := -1
    var max_cost := 0
    var min_dist := -1
    var max_dist := 0
    var terrains: Dictionary = {}
    for step in steps:
        var c := int(step.get("work_cost", 0))
        total += c
        min_cost = c if min_cost < 0 else mini(min_cost, c)
        max_cost = maxi(max_cost, c)
        var price: Dictionary = step.get("price", {})
        var d := int(price.get("distance", 0))
        min_dist = d if min_dist < 0 else mini(min_dist, d)
        max_dist = maxi(max_dist, d)
        var tid := str(price.get("terrain_id", ""))
        if tid != "":
            terrains[tid] = true
    return {
        "ok": true,
        "reason": "",
        "cost": total,
        "steps": steps,
        "segments": steps.size(),
        "road_level": road_level,
        "min_step_cost": min_cost,
        "max_step_cost": max_cost,
        "min_distance": maxi(min_dist, 0),
        "max_distance": max_dist,
        "terrains": terrains.keys(),
    }

# Returns the actual cost of the labour for the construction of the improvement imp_id on the hex (row, col).
# The cost depends on the base work_cost of the improvement, the type of the terrain (move_cost) and
# the distance from the city. It returns a dictionary with the total cost and the details of the calculation
# (for the extended tooltip).
#
# About the improvement the keys are like this:
#   cost          — the price of the IMPROVEMENT itself (it is what build_manager takes);
#   road_applicable— whether the road is built together with it (for the special actions — no);
#   road_cost     — the price of the road to the hex, of the chosen level;
#   road_segments — how many new segments this road will add;
#   total_cost    — the sum, that is, how much everything will cost together.
# The road is NOT included in cost: it is a separate phased construction and is paid by its own
# steps (see start_improvement_road_project).
func get_improvement_work_cost(imp_id: String, row: int, col: int,
        road_level: int = road_manager.DEFAULT_ROAD_LEVEL) -> Dictionary:
    # The road (the special action build_road) is the exception: it has no improvements and no hex
    # of the construction, it has a WHOLE ROUTE of separate segments. The price
    # of each segment depends on its terrain and the distance, therefore the total
    # price is the sum of the steps (main_map._build_road_steps, the single source with
    # the preview). build_manager calls this function only for the check "price > 0".
    var special_action: Dictionary = GameData.special_actions.get(imp_id, {})
    if str(special_action.get("action_type", "")) == "road":
        var breakdown: Dictionary = get_road_cost_breakdown(row, col, road_level)
        return {
            "cost": int(breakdown.get("cost", 0)),
            "base_cost": GameData.get_road_work_cost(road_level),
            "road_level": road_level,
            "segments": int(breakdown.get("segments", 0)),
            "ok": bool(breakdown.get("ok", false)),
            "reason": str(breakdown.get("reason", "")),
            "min_step_cost": int(breakdown.get("min_step_cost", 0)),
            "max_step_cost": int(breakdown.get("max_step_cost", 0)),
            "min_distance": int(breakdown.get("min_distance", 0)),
            "max_distance": int(breakdown.get("max_distance", 0)),
            "terrains": breakdown.get("terrains", []),
        }
    var cost_data := MapHelpers.get_improvement_work_cost(imp_id, row, col, tile_data, city_row, city_col)
    # The special actions (the gathering of the wild plants, the felling of the forest, the drainage, the demolition of an improvement)
    # do NOT build a road: build_manager.start_build sends them into an ordinary build
    # bypassing start_improvement_road_project, and executes their _on_build_completed,
    # which does not touch the road network. Therefore the parsing of the road for them is
    # not counted at all: otherwise the preview would show the player the price and the number of the segments
    # of a construction which will not happen, and the "Total" — a sum with it.
    if GameData.special_actions.has(imp_id):
        cost_data["road_applicable"] = false
        cost_data["road_cost"] = 0
        cost_data["road_level"] = road_level
        cost_data["road_segments"] = 0
        cost_data["road_pending"] = false
        cost_data["total_cost"] = int(cost_data.get("cost", 0))
        return cost_data
    # The road to an improvement is a SEPARATE construction: a phased project, which
    # is started together with the construction of the improvement and is paid by the segments
    # (main_map.start_improvement_road_project). Therefore its price is NOT included in the
    # price of the improvement: otherwise the labour for the road would be written off twice. The panels need
    # both numbers (see control_panel._build_preview), build_manager takes
    # only `cost` — the improvement.
    var road_bd := get_road_cost_breakdown_for_improvement(row, col, road_level)
    var road_cost := int(road_bd.get("cost", 0))
    cost_data["road_applicable"] = true
    cost_data["road_cost"] = road_cost
    cost_data["road_level"] = road_level
    cost_data["road_segments"] = int(road_bd.get("segments", 0))
    cost_data["road_pending"] = bool(road_bd.get("pending", false))
    cost_data["total_cost"] = int(cost_data.get("cost", 0)) + road_cost
    return cost_data

# The price and the number of the segments of the road which the player has chosen during the construction of the improvement on the
# hex (row, col). It is the same parsing as in the preview "Build a road"
# (get_road_cost_breakdown), therefore the numbers in the panel and at the start coincide.
#
# The road which is not needed by the improvement (the hex is already connected, the improvement with the flag
# no_road, there is no land route) does not get here: it has no new segments,
# and the price is 0. In this way the preview does not show "road: 0" where there is no road to build.
func get_road_cost_breakdown_for_improvement(row: int, col: int,
        road_level: int) -> Dictionary:
    # A road project is already going to the hex (for example, the player has separately built
    # a road here by the special action). Its segments are already paid by that queue,
    # therefore it is not allowed to show their price again — otherwise the player will see a sum,
    # which will not be written off. The construction of the improvement on such a hex will not
    # start either: the hex is busy.
    if project_manager != null and project_manager.has_project_at(row, col):
        return {"ok": false, "pending": true, "reason": "", "cost": 0,
                "segments": 0, "road_level": road_level}
    var breakdown := get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        return {"ok": false, "reason": breakdown.get("reason", ""), "cost": 0,
                "segments": 0, "road_level": road_level}
    return breakdown

# The cost of the road to an improvement as a single number — for the places where the parsing is
# not needed.
#
# The road to an improvement costs exactly as much as the same road built by the special action —
# the formula of the level from data/roads.json.
#
# The zero remains where there is no road at all: the hex is already connected, the improvement
# with the flag no_road, there is no land route.
func get_road_cost_for_improvement(row: int, col: int, road_level: int) -> int:
    return int(get_road_cost_breakdown_for_improvement(row, col, road_level)
            .get("cost", 0))

# The plan of the road from the network of the city to the hex (row, col) — the same object that
# road_manager.plan_road_to returns. It is needed by the control panel (the preview of
# the price) and by main_map.get_improvement_work_cost.
#
# hex_allowed = is_hex_known — the road which the player builds goes ONLY over the
# known territory (the Influence Ring or scouted). In the first place this
# concerns the road to a town: you can interact with a town only on
# a scouted hex, and you can approach it only over the scouted land as well.
# The automatic road networks do not get the filter (see road_manager
# ._find_path_between).
func get_road_plan(row: int, col: int) -> Dictionary:
    return road_manager.plan_road_to(row, col, tile_data, map_rows, map_cols,
            _road_hex_allowed())

# The predicate "a road of the player can be built on this hex". A separate function,
# so that all the calls (planning, construction, restoration from the save) look up
# by one and the same reference to the method, and not a Callable created anew every time.
func _road_hex_allowed() -> Callable:
    return Callable(self, "is_hex_known")

# Is the hex connected to the city by an already built road network.
func has_road_route(row: int, col: int) -> bool:
    return bool(get_route_to_city(row, col).get("ok", false))
