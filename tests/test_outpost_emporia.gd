# Headless test of the "Emporia" mechanic — an outpost: an improvement built outside
# the Region on a scouted resource hex.
#   godot --headless --path . --script res://tests/test_outpost_emporia.gd
#
# Cases (each on the REAL MainMap scene of a new game):
#   1. The derivation of a target hex: outside the Region, explored, free of anyone
#      else's structures, with a revealed resource whose improvement is served by a
#      road. Everything else — a Region hex, an unexplored hex, a hex in the ring of
#      a foreign town, a road-exempt improvement — is NOT a target.
#   2. The gates of build_manager.start_build(): without "Emporia" the build is
#      refused, an improvement that does not match the resource is refused, a missing
#      coin fee is refused. No gate may move the treasury.
#   3. The fee: base + the per-hex distance charge, and it grows with the distance.
#   4. The money trail of a real build: the fee is written off when the
#      "road → improvement" project starts and returns when it is cancelled.
#   5. The route gating of production: an outpost without a road stands idle and is
#      flagged road_missing; once the road reaches it, it produces.
#   6. The panel of the hex: an outpost target offers the construction (disabled before
#      "Emporia", with the study button of the next missing technology), never the
#      scouting or the claiming; the price preview names the coin fee; a built outpost
#      is operated as an ordinary improvement.
extends SceneTree

# A hang watchdog: without it, a broken _run() coroutine looks like eternal silence.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _cdata = null
var _gdata = null
var _maph = null
var _cases_planned := 0
var _cases_done := 0

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken as scene-tree nodes: in --script mode the names
    # GameData/CityData are not available at the compile stage of this file. The same
    # holds for the global classes: a compile-time MapHelpers reference makes Godot
    # rebuild that script outside the autoload context, and every call of its
    # functions then fails at runtime.
    # new_game() loads all the data and resets the city.
    get_root().get_node("SaveManager").new_game()
    _cdata = get_root().get_node("CityData")
    _gdata = get_root().get_node("GameData")
    _maph = load("res://scripts/map_helpers.gd")

    if WATCHDOG.wants_case("target_derivation"):
        _cases_planned += 1
        await _test_target_derivation(state)
        _cases_done += 1
    if WATCHDOG.wants_case("build_gates"):
        _cases_planned += 1
        await _test_build_gates(state)
        _cases_done += 1
    if WATCHDOG.wants_case("fee_formula"):
        _cases_planned += 1
        await _test_fee_formula(state)
        _cases_done += 1
    if WATCHDOG.wants_case("fee_charge_refund"):
        _cases_planned += 1
        await _test_fee_charge_and_refund(state)
        _cases_done += 1
    if WATCHDOG.wants_case("route_gated_production"):
        _cases_planned += 1
        await _test_route_gated_production(state)
        _cases_done += 1
    if WATCHDOG.wants_case("panel_and_preview"):
        _cases_planned += 1
        await _test_panel_and_preview(state)
        _cases_done += 1

    # A case that broke in the middle would otherwise print a verdict over the
    # assertions it never reached.
    check(_cases_done == _cases_planned,
            "only %d of %d planned cases reached their end" % [_cases_done, _cases_planned], state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("OUTPOST EMPORIA TEST FAILED")
        quit(1)
    else:
        print("OUTPOST EMPORIA TEST OK")
        quit(0)

# -------------------------------------------------------
# 1. The derivation of a target hex
# -------------------------------------------------------

func _test_target_derivation(state: Dictionary) -> void:
    var main_map = await _new_map()
    _explore_all(main_map)

    var hex = _make_target_hex(main_map)
    check(not hex.is_empty(), "no hex outside the Region is available for the test", state)
    if hex.is_empty():
        _free(main_map)
        return
    var row := int(hex.row)
    var col := int(hex.col)
    var tile: Dictionary = main_map.tile_data[row][col]

    check(main_map.is_outpost_build_target(row, col),
            "an explored resource hex outside the Region must be an outpost target", state)

    # An unexplored hex of the same kind is not a target: the resource is not revealed.
    tile["is_explored"] = false
    check(not main_map.is_outpost_build_target(row, col),
            "an unexplored hex must NOT be an outpost target", state)
    tile["is_explored"] = true

    # Someone else's land: the ring of a foreign town.
    tile["in_town_influence"] = true
    check(not main_map.is_outpost_build_target(row, col),
            "a hex in the influence ring of a town must NOT be an outpost target", state)
    tile["in_town_influence"] = false

    # A hex inside the Region is the ordinary construction site, not an outpost.
    var inside = _find_region_hex_with_land(main_map)
    check(not inside.is_empty(), "no free hex inside the Region found on the live map", state)
    if not inside.is_empty():
        var in_tile: Dictionary = main_map.tile_data[int(inside.row)][int(inside.col)]
        in_tile["resource"] = "test_outpost_clay"
        check(not main_map.is_outpost_build_target(int(inside.row), int(inside.col)),
                "a hex inside the Region must NOT be an outpost target", state)

    # A road-exempt improvement (a pier, a canal) opens nothing outside: the rule
    # "an outpost needs a road" is exactly what the flag marks.
    var exempt := _exempt_improvement_id()
    check(exempt != "", "the data must keep at least one road-exempt improvement", state)
    if exempt != "":
        _gdata.raw_resources["test_outpost_exempt"] = {
            "id": "test_outpost_exempt", "name": "Test Exempt", "type": "raw",
            "improved_by": exempt, "produces": {},
        }
        var other = _make_target_hex(main_map, [hex])
        check(not other.is_empty(), "no second free hex outside the Region found", state)
        if not other.is_empty():
            var o_tile: Dictionary = main_map.tile_data[int(other.row)][int(other.col)]
            o_tile["resource"] = "test_outpost_exempt"
            check(not main_map.is_outpost_build_target(int(other.row), int(other.col)),
                    "a resource improved by a road-exempt structure must NOT be a target", state)

    _free(main_map)

# -------------------------------------------------------
# 2. The gates of the build
# -------------------------------------------------------

func _test_build_gates(state: Dictionary) -> void:
    var main_map = await _new_map()
    _explore_all(main_map)
    var hex = _pick_buildable_target(main_map)
    check(not hex.is_empty(), "no outpost target reachable by a road found", state)
    if hex.is_empty():
        _free(main_map)
        return
    var row := int(hex.row)
    var col := int(hex.col)

    _cdata.total_population = 50
    _cdata.add_treasury(1000)
    var fee := int(main_map.get_outpost_fee(row, col))
    var bm = main_map.build_manager
    var messages: Array = []
    bm.build_message.connect(func(msg, _level): messages.append(msg))

    # Without "Emporia" — a refusal that names the technology.
    check(not _cdata.is_tech_unlocked("emporia"),
            "Emporia must not be researched at the start of a new game", state)
    messages.clear()
    var treasury_before := int(_cdata.treasury)
    check(not bm.start_build(row, col, "farm"),
            "without Emporia a build outside the Region must be refused", state)
    check(int(_cdata.treasury) == treasury_before,
            "a refused build must not touch the treasury", state)
    check(messages.size() == 1 and messages[0].contains(_cdata.get_tech_name("emporia")),
            "the refusal must name the technology (got %s)" % str(messages), state)

    _cdata.unlocked_technologies.append("emporia")
    check(main_map.is_emporia_researched(),
            "is_emporia_researched() must be true once the technology is researched", state)

    # An improvement that does not match the resource.
    messages.clear()
    check(not bm.start_build(row, col, "pasture"),
            "an improvement other than the one of the resource must be refused", state)
    check(int(_cdata.treasury) == treasury_before,
            "a refusal must not touch the treasury", state)
    check(messages.size() == 1
            and messages[0].contains(_gdata.get_improvement_display_name("farm")),
            "the refusal must name the improvement of this resource (got %s)" % str(messages), state)

    # Not enough coins for the fee.
    messages.clear()
    _cdata.spend_treasury(int(_cdata.treasury) - (fee - 1))
    check(int(_cdata.treasury) == fee - 1,
            "the test must leave exactly one coin short of the fee (got %d)" % int(_cdata.treasury), state)
    check(not bm.start_build(row, col, "farm"),
            "a fee the treasury cannot cover must be refused", state)
    check(int(_cdata.treasury) == fee - 1,
            "a refusal for the fee must not spend coins", state)
    check(messages.size() == 1 and messages[0].contains(str(fee)),
            "the refusal must state the fee (got %s)" % str(messages), state)

    _free(main_map)

# -------------------------------------------------------
# 3. The fee by the distance
# -------------------------------------------------------

func _test_fee_formula(state: Dictionary) -> void:
    var base := int(_gdata.game_balance.get("outpost_fee_base", 0))
    var per_hex := float(_gdata.game_balance.get("outpost_fee_per_hex", 0.0))
    check(base > 0 and per_hex > 0.0,
            "the fee constants must be configured in game_balance.json", state)

    var main_map = await _new_map()
    _explore_all(main_map)

    # The fee of the city hex itself: the base sum, no distance charge.
    check(int(_maph.get_outpost_fee(main_map.city_row, main_map.city_col,
            main_map.city_row, main_map.city_col)) == base,
            "the fee at distance 0 must be the base sum", state)

    var previous := -1
    for distance in range(1, 9):
        var fee := int(_maph.get_outpost_fee(main_map.city_row + distance,
                main_map.city_col, main_map.city_row, main_map.city_col))
        check(fee == base + int(ceil(float(distance) * per_hex)),
                "the fee at distance %d must follow base + ceil(distance x per_hex) (got %d)"
                        % [distance, fee], state)
        check(fee > previous, "the fee must grow with the distance (%d after %d)" % [fee, previous], state)
        previous = fee

    # The map entry point reads the very same formula.
    var hex = _make_target_hex(main_map)
    check(not hex.is_empty(), "no outpost target found for the fee check", state)
    if not hex.is_empty():
        var row := int(hex.row)
        var col := int(hex.col)
        check(int(main_map.get_outpost_fee(row, col))
                == int(_maph.get_outpost_fee(row, col, main_map.city_row, main_map.city_col)),
                "main_map.get_outpost_fee() must be the helper applied to the hex", state)

    _free(main_map)

# -------------------------------------------------------
# 4. The coins of a real build
# -------------------------------------------------------

func _test_fee_charge_and_refund(state: Dictionary) -> void:
    var main_map = await _new_map()
    _explore_all(main_map)
    var hex = _pick_buildable_target(main_map)
    check(not hex.is_empty(), "no outpost target reachable by a road found", state)
    if hex.is_empty():
        _free(main_map)
        return
    var row := int(hex.row)
    var col := int(hex.col)

    _cdata.total_population = 50
    _cdata.unlocked_technologies.append("emporia")
    _cdata.add_treasury(1000)
    var fee := int(main_map.get_outpost_fee(row, col))
    var before := int(_cdata.treasury)

    check(main_map.build_manager.start_build(row, col, "farm"),
            "with Emporia and coins the outpost build must start", state)
    check(int(_cdata.treasury) == before - fee,
            "the fee must be written off once at the start (before %d, after %d, fee %d)"
                    % [before, int(_cdata.treasury), fee], state)
    check(int(_cdata.treasury_expense_accum.get(_gdata.SRC_OUTPOST, 0)) == fee,
            "the fee must be recorded as an expense of the outposts", state)
    check(main_map.project_manager.has_project_at(row, col),
            "the build must go by the staged road-to-improvement project", state)
    check(main_map.tile_data[row][col].get("improvement", null) == null,
            "the improvement is not built yet: the project has just started", state)

    check(main_map.project_manager.cancel_project_at_hex(row, col),
            "the project of the outpost must be cancellable", state)
    check(int(_cdata.treasury) == before,
            "cancelling the project must return the fee (before %d, after %d)"
                    % [before, int(_cdata.treasury)], state)
    check(int(_cdata.treasury_expense_accum.get(_gdata.SRC_OUTPOST, 0)) == 0,
            "a refunded fee must leave no net expense", state)

    _free(main_map)

# -------------------------------------------------------
# 5. Production needs a road
# -------------------------------------------------------

func _test_route_gated_production(state: Dictionary) -> void:
    var main_map = await _new_map()
    _explore_all(main_map)

    # The hex must be reachable by a road AND still unconnected: the case lays the route by
    # hand, and a target the plan cannot reach (behind water) would leave the improvement
    # without a route for a reason the case does not check.
    var hex = _pick_unconnected_reachable_hex(main_map)
    check(not hex.is_empty(),
            "no unconnected hex reachable by a road found for the production case", state)
    if hex.is_empty():
        _free(main_map)
        return
    var row := int(hex.row)
    var col := int(hex.col)
    var tile: Dictionary = main_map.tile_data[row][col]

    # An outpost already built, with a worker and WITHOUT a road.
    tile["improvement"] = "farm"
    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    check(main_map.worker_manager.assign_worker(row, col),
            "a worker must be assigned to the outpost", state)
    check(main_map.is_outpost_improvement(row, col),
            "a built improvement outside the Region is an outpost", state)
    check(not main_map.has_road_route(row, col),
            "the hex must start without a route to the city", state)

    _cdata.city_storage["clay"] = 0
    main_map.delivery_manager.clear()
    main_map._process(1.0)
    check(bool(tile.get("road_missing", false)),
            "an improvement due a road and having none must be flagged road_missing", state)
    check(int(_cdata.city_storage.get("clay", 0)) == 0,
            "an outpost without a road must not produce (got %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)
    var status: Dictionary = main_map.delivery_manager.get_route_status(row, col)
    check(int(status.get("pending", 0)) + int(status.get("in_transit", 0)) == 0,
            "an outpost without a road must not fill any queue", state)

    # The road reaches the hex — the same improvement starts carrying at once.
    main_map.road_manager.build_road_from(row, col, main_map.tile_data,
            main_map.map_rows, main_map.map_cols)
    check(main_map.has_road_route(row, col),
            "the road must connect the outpost to the city", state)
    main_map._process(1.0)
    check(not bool(tile.get("road_missing", false)),
            "the flag must clear once the route exists", state)
    status = main_map.delivery_manager.get_route_status(row, col)
    var delivered := int(_cdata.city_storage.get("clay", 0)) \
            + int(status.get("pending", 0)) + int(status.get("in_transit", 0))
    check(delivered > 0,
            "an outpost with a road must produce (got %d units)" % delivered, state)

    main_map.worker_manager.remove_worker(row, col)
    _free(main_map)

# -------------------------------------------------------
# 6. The panel of the hex and the preview of the price
# -------------------------------------------------------

func _test_panel_and_preview(state: Dictionary) -> void:
    var main_map = await _new_map()
    _explore_all(main_map)
    # The city is set up so that one study away from "Emporia" stands "Cartography": with
    # the target picked afterwards, the road level the case checks is the level the panel
    # itself uses.
    _prepare_emporia_one_hop_away()
    _cdata.total_population = 50
    _cdata.add_treasury(1000)
    var hex = _pick_buildable_target(main_map)
    check(not hex.is_empty(), "no outpost target reachable by a road found", state)
    if hex.is_empty():
        _free(main_map)
        return
    var row := int(hex.row)
    var col := int(hex.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    var panel = main_map.control_panel

    # Before "Emporia": the construction is offered but locked, the button of the study names
    # the next missing step, and the scouting and the claiming never reach an explored hex
    # outside the Region.
    var actions: Array = panel._collect_actions(row, col, tile)
    var build = _find_action(actions, "build_improvement")
    check(build != null, "an outpost target must offer the construction", state)
    check(_find_action(actions, "scout_chunk") == null
            and _find_action(actions, "buy_chunk") == null,
            "an explored hex outside the Region must not offer scouting or claiming", state)
    if build == null:
        _free(main_map)
        return
    check(str(build["imp_id"]) == "farm",
            "the button must offer the improvement of the resource of this hex", state)
    check(not bool(build["enabled"]), "without Emporia the button must be disabled", state)
    # The panel follows the rule it applies to every improvement blocked by a technology: the
    # study button appears only while at most TECH_HOPS_MAX technologies are left to the target.
    var research = _find_action(actions, "research_tech")
    check((research != null) == _emporia_within_study_reach(),
            "the study button must follow the rule of the hops limit", state)
    check(research != null and str(research["tech_id"]) == "cartography",
            "one hop from Emporia the panel must offer the missing technology", state)

    _cdata.unlocked_technologies.append("emporia")
    actions = panel._collect_actions(row, col, tile)
    build = _find_action(actions, "build_improvement")
    check(build != null and bool(build["enabled"]),
            "with Emporia, coins and a free slot the button must be enabled", state)

    # The fee is paid in coins, so it appears in the preview next to the labour.
    panel._preview_action = build
    panel._build_preview(row, col, tile)
    check(_preview_has(panel, "Outpost fee"),
            "the preview of the price must name the outpost fee", state)

    # A built outpost is operated by the ordinary rules of an improvement.
    tile["improvement"] = "farm"
    actions = panel._collect_actions(row, col, tile)
    check(_find_action(actions, "resume_improvement") != null
            or _find_action(actions, "pause_improvement") != null,
            "an outpost must offer its start or its pause", state)
    check(_find_action(actions, "build_improvement") == null,
            "a hex that already carries an improvement must not offer the construction", state)

    _free(main_map)

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

func _new_map():
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame
    # The synthetic resource of the test: a farm product the city never consumes, so
    # the storage of the production case is not "eaten" while the test runs. It goes
    # in AFTER the map is up: the map boots through GameData.load_all_data(), which
    # rebuilds the resource tables from the data files.
    _gdata.raw_resources["test_outpost_clay"] = {
        "id": "test_outpost_clay", "name": "Test Outpost Clay", "type": "raw",
        "improved_by": "farm", "produces": {"clay": 3},
    }
    return main_map

func _free(main_map) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

# The whole map is scouted: the test is about the outpost rules, not about the fog,
# and a road plan may only cross known territory.
func _explore_all(main_map) -> void:
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile != null:
                tile["is_explored"] = true

# A hex outside the Region, free and dry, turned into an outpost target of the test
# resource. `skip` lists hexes to avoid.
func _make_target_hex(main_map, skip: Array = []):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if bool(tile.get("in_influence", false)) or bool(tile.get("in_town_influence", false)) \
                    or bool(tile.get("has_town", false)) or bool(tile.get("decorative", false)):
                continue
            if _maph.is_water_terrain(str(tile.get("terrain", ""))):
                continue
            if _is_skipped(row, col, skip):
                continue
            tile["resource"] = "test_outpost_clay"
            if not main_map.is_outpost_build_target(row, col):
                continue
            return {"row": row, "col": col}
    return {}

# The first target hex that the road plan can actually reach: the build cases need
# a place where the "road -> improvement" project is possible.
func _pick_buildable_target(main_map):
    var tried: Array = []
    while true:
        var hex = _make_target_hex(main_map, tried)
        if hex.is_empty():
            return {}
        var row := int(hex.row)
        var col := int(hex.col)
        tried.append(hex)
        var level: int = _gdata.get_max_unlocked_road_level()
        var breakdown: Dictionary = main_map.get_road_cost_breakdown_for_improvement(row, col, level)
        if bool(breakdown.get("ok", false)):
            return {"row": row, "col": col}

# The first target hex that a road plan can reach and that has no route yet: the production
# case lays the route itself, so the hex must be reachable but still disconnected.
func _pick_unconnected_reachable_hex(main_map):
    var tried: Array = []
    while true:
        var hex = _make_target_hex(main_map, tried)
        if hex.is_empty():
            return {}
        var row := int(hex.row)
        var col := int(hex.col)
        tried.append(hex)
        if main_map.has_road_route(row, col):
            continue
        var level: int = _gdata.get_max_unlocked_road_level()
        var breakdown: Dictionary = main_map.get_road_cost_breakdown_for_improvement(row, col, level)
        if bool(breakdown.get("ok", false)):
            return {"row": row, "col": col}

func _is_skipped(row: int, col: int, skip: Array) -> bool:
    for hex in skip:
        if int(hex.row) == row and int(hex.col) == col:
            return true
    return false

func _find_region_hex_with_land(main_map):
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if bool(tile.get("in_town_influence", false)) or bool(tile.get("has_town", false)):
                continue
            if _maph.is_water_terrain(str(tile.get("terrain", ""))):
                continue
            return {"row": row, "col": col}
    return {}

# The id of any improvement the data marks as not served by a land road (a pier, an
# irrigation channel): the exemption is exactly what keeps such a hex out of the
# outpost rules.
func _exempt_improvement_id() -> String:
    for imp_id in _gdata.improvements.keys():
        if _maph.improvement_needs_road(str(imp_id)):
            continue
        if _gdata.improvements[imp_id].has("no_road") \
                or _gdata.is_no_worker_improvement(str(imp_id)):
            return str(imp_id)
    return ""

# The first action of the given type, or null.
func _find_action(actions: Array, type: String):
    for action in actions:
        if str(action.get("type", "")) == type:
            return action
    return null

# Everything but "Cartography" studied and the era allowed: "Emporia" is then one
# study away, which is what the panel needs to offer the button of the learning.
func _prepare_emporia_one_hop_away() -> void:
    _cdata.current_era_index = maxi(int(_cdata.current_era_index),
            int(_cdata.get_tech_era_index("emporia")))
    for tech_id in ["pottery", "writing", "wheel"]:
        if not _cdata.is_tech_unlocked(tech_id):
            _cdata.unlocked_technologies.append(tech_id)

# Whether the panel rule of the hops limit currently allows the study button for an
# improvement blocked by "Emporia".
func _emporia_within_study_reach() -> bool:
    var chain: Array = _cdata.get_tech_study_chain("emporia")
    return not chain.is_empty() \
            and int(_cdata.get_tech_hops("emporia")) <= int(_cdata.TECH_HOPS_MAX)

# Whether the price preview shows a row containing `needle` — the labels of the
# preview are rebuilt on every call, so the text of the whole subtree is what the
# player reads.
func _preview_has(panel, needle: String) -> bool:
    var container = panel.get("_preview_container")
    if container == null:
        return false
    return _node_text_contains(container, needle)

func _node_text_contains(node: Node, needle: String) -> bool:
    if node is Label and str(node.text).contains(needle):
        return true
    for child in node.get_children():
        if _node_text_contains(child, needle):
            return true
    return false

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
