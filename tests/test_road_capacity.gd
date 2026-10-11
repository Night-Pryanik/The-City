# Headless test of road capacity: the route to the city limits
# how fast the improvement's resources reach the storage (road_manager.find_route_to_city,
# main_map._emit_continuous_production, delivery_manager, map_tooltip, map_renderer).
#   godot --headless --path . --script res://tests/test_road_capacity.gd
#
# Checks:
#   1. PER RESOURCE. For one improvement, different products are compared with the
#      route's speed INDEPENDENTLY: at a route speed of 10 units/sec a product of 10 units/sec
#      passes, while a product of 20 units/sec does not. This is the case for which the note
#      is emitted separately for each product.
#   2. FLAG AND TOOLTIP. For an improvement with route overload, tile.road_capacity_short
#      is set, and the extended tooltip and the left column of the panel show the red
#      note only on the overloaded product.
#   3. A ROAD UPGRADE REMOVES THE OVERLOAD. After raising the whole route to
#      level 2 (30 units/sec) the note disappears and the flag is reset.
#   4. PRODUCTS ARE NOT LOST. Production with a route no longer appears in the storage
#      instantly and is not cut: it enters the delivery queue in full (the full
#      queue mechanics are in tests/test_delivery_logistics.gd).
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null
var _mh = null
var _hu = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are fetched as tree nodes: in --script mode the names GameData and CityData
    # are not yet available at the compilation stage of this file.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _mh = load("res://scripts/map_helpers.gd")
    _hu = load("res://scripts/HexUtils.gd")

    await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("ROAD CAPACITY TEST FAILED")
        quit(1)
    else:
        print("ROAD CAPACITY TEST OK")
        quit(0)


# -------------------------------------------------------
# 1-4. Live scene: per resource, flag, tooltip, road upgrade
# -------------------------------------------------------

func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var wm = main_map.worker_manager
    # No type is specified: in --script mode the class name MapTooltip is
    # not yet in the cache at the compilation stage.
    var tooltip = main_map.map_tooltip
    var panel = main_map.control_panel

    # A synthetic resource with controllable speeds: the real data put a fresh-water
    # bonus on the farm (×1.5), and the test would depend on where the hex landed.
    # The products are the always-available wheat and clay (without unlock_tech).
    _gdata.raw_resources["test_grain"] = {
        "id": "test_grain", "name": "Test Grain", "type": "raw",
        "improved_by": "farm", "produces": {"wheat": 10, "clay": 20},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(),
            "a free hex in the influence without water must be found on the live map", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_grain"
    tile["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    check(rm.get_hex_road_level(row, col) == 1,
            "a trail must be built to the improvement", state)

    # Production happens only with a worker.
    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    check(wm.assign_worker(row, col), "a worker must be assigned to the improvement", state)

    # Precondition: the production multiplier must be 1.0, otherwise 10 and 20
    # shift relative to the threshold 10 and the "per resource" check becomes fuzzy.
    var mult: float = _cdata.get_improvement_production_multiplier("farm",
            _mh.is_hex_irrigated(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols),
            tile.get("terrain", ""), "test_grain")
    check(absf(mult - 1.0) < 0.01,
            "the check needs a hex without production bonuses (multiplier %.2f)" % mult, state)
    if absf(mult - 1.0) >= 0.01:
        _free(main_map)
        return

    var route: Dictionary = main_map.get_route_to_city(row, col)
    check(route.get("ok", false), "an improvement with a road must have a route", state)
    check(absf(float(route.get("avg_speed", 0.0)) - 10.0) < 0.01,
            "a route made of trails must have an average speed of 10 units/sec", state)

    # Product speeds: wheat 10, clay 20.
    var rates: Dictionary = tooltip.production_rates(row, col, main_map.tile_data)
    check(rates.has("wheat") and rates.has("clay"),
            "the speeds of both products must be computed (got %s)" % str(rates.keys()), state)
    if rates.has("wheat") and rates.has("clay"):
        check(absf(float(rates["wheat"]["rate"]) - 10.0) < 0.01,
                "wheat must be produced at 10 units/sec", state)
        check(absf(float(rates["clay"]["rate"]) - 20.0) < 0.01,
                "clay must be produced at 20 units/sec", state)

    # Overload is PER RESOURCE: clay (20 > 10) is overloaded, wheat (10 = 10) is not.
    var shortfall: Dictionary = tooltip.road_capacity_shortfall(row, col, main_map.tile_data)
    check(shortfall.has("clay"),
            "clay at 20 units/sec does not fit along the trail of 10 units/sec", state)
    check(not shortfall.has("wheat"),
            "wheat at 10 units/sec fits along the trail — it must not be overloaded", state)

    # The flag for drawing the triangle is set on the production tick.
    _run_production_tick(main_map)
    check(bool(tile.get("road_capacity_short", false)),
            "an overloaded improvement must have the road_capacity_short flag set", state)

    # Extended tooltip: the red route note only on the overloaded product.
    # The word "route" is replaced by the road icon, so for the note we check both the text
    # (number + unit) and the icon path.
    var products: Array = tooltip._collect_extended_production(row, col, main_map.tile_data)
    var clay_route := _route_text_for(products, "clay")
    var wheat_route := _route_text_for(products, "wheat")
    check(clay_route != "", "the overloaded clay must have a route note", state)
    check(clay_route.contains("10"),
            "the route note must name the average speed of 10 units/sec (got: %s)"
                    % clay_route, state)
    check(wheat_route == "",
            "wheat, which has enough speed, must have no note (got: %s)"
                    % wheat_route, state)
    check(_route_icon_for(products, "clay") != "",
            "the route note must have a road icon", state)
    check(_route_icon_for(products, "wheat") == "",
            "wheat without a note must have no road icon", state)

    # The left column of the panel is built from the same "Produces:" block — the note
    # must be there too. The word "route" is replaced by the icon, so we compare against
    # the text of the note itself (number + unit of measurement), not against the word.
    panel.select_hex(row, col)
    var panel_text := _collect_text(panel)
    check(panel_text.contains(clay_route.strip_edges()),
            "the left column of the panel must contain the route note (got: %s)" % panel_text,
            state)

    # Upgrading the WHOLE route to level 2 (30 units/sec): clay 20 fits,
    # the overload is removed, the flag is reset.
    for seg_key in route.get("segments", []):
        var parts := str(seg_key).split("|")
        var a := parts[0].split(",")
        var b := parts[1].split(",")
        rm.upgrade_road_segment(int(a[0]), int(a[1]), int(b[0]), int(b[1]), 2)
    var after: Dictionary = main_map.get_route_to_city(row, col)
    check(absf(float(after.get("avg_speed", 0.0)) - 30.0) < 0.01,
            "after the upgrade the route's average speed must become 30 units/sec (got %.2f)"
                    % float(after.get("avg_speed", 0.0)), state)
    var short_after: Dictionary = tooltip.road_capacity_shortfall(row, col, main_map.tile_data)
    check(short_after.is_empty(),
            "after the road upgrade there must be no overload (got %s)"
                    % str(short_after.keys()), state)

    # A flag change must request a map redraw: the map is drawn on demand,
    # and without a request the "!" triangle would hang on screen until the mouse moved.
    # We turn off edge auto-scrolling — with it the map redraws every frame, and
    # the draw counter would prove nothing.
    main_map.use_edge_scrolling = false
    # Drain deferred redraws from previous actions (hex selection, etc.):
    # the counter must count only the redraw caused by the flag change.
    await process_frame
    await process_frame

    # The tick on which the road is already upgraded resets the flag — and must request a redraw.
    var draws_before: int = main_map.map_renderer.draw_calls
    _run_production_tick(main_map)
    await process_frame
    check(not bool(tile.get("road_capacity_short", false)),
            "after the road upgrade the overload flag must be reset", state)
    check(main_map.map_renderer.draw_calls > draws_before,
            "resetting the overload flag must request a map redraw", state)

    # Control: a tick without a flag change does not redraw the map — otherwise the check
    # above would prove nothing (the map could redraw on its own).
    var draws_steady: int = main_map.map_renderer.draw_calls
    _run_production_tick(main_map)
    await process_frame
    check(main_map.map_renderer.draw_calls == draws_steady,
            "a tick without an overload flag change must not redraw the map", state)

    # Output is no longer cut and no longer disappears: with a route the products enter the
    # delivery queue IN FULL, rather than appearing in the storage instantly.
    # We clear the queue: the production ticks above have already put something in it.
    main_map.delivery_manager.clear()
    _cdata.city_storage["clay"] = 0
    var queued_tile := {"production_fractional_remainder": 0.0}
    main_map._emit_continuous_production(queued_tile, {"clay": 20}, 1.0, 1.0,
            "common", "test_source", row, col, float(after.get("avg_speed", 0.0)))
    var queued_status: Dictionary = main_map.delivery_manager.get_route_status(row, col)
    var queued_total := int(queued_status.get("pending", 0)) + int(queued_status.get("in_transit", 0))
    check(int(_cdata.city_storage.get("clay", 0)) == 0,
            "products with a route must not appear in the storage instantly (got %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)
    check(queued_total == 20,
            "all 20 clay must enter the delivery queue without loss (got %d)"
                    % queued_total, state)

    # Without a route (avg_speed < 0) there is nothing to limit with: the products go to the storage at once.
    _cdata.city_storage["clay"] = 0
    var no_route_tile := {"production_fractional_remainder": 0.0}
    main_map._emit_continuous_production(no_route_tile, {"clay": 20}, 1.0, 1.0,
            "common", "test_source", row, col, -1.0)
    check(int(_cdata.city_storage.get("clay", 0)) == 20,
            "without a route all 20 clay must reach the storage at once (got %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)

    _free(main_map)


# Runs one simulation tick: the production cycle sets
# tile.road_capacity_short. We call _process directly — in headless the frame
# delta is too small to accumulate SIMULATION_TICK on its own.
func _run_production_tick(main_map) -> void:
    for i in range(3):
        main_map._process(1.0)


# The route note of the product with the given id: "" if the product or the note is absent.
func _route_text_for(products: Array, prod_id: String) -> String:
    var label := str(_gdata.products.get(prod_id, {}).get("name", prod_id))
    for item in products:
        if str(item.get("type", "")) != "product":
            continue
        if str(item.get("name", "")).begins_with(label):
            return str(item.get("route_text", ""))
    return ""


# The road icon path of the route note of the product with the given id: "" if there is no note.
func _route_icon_for(products: Array, prod_id: String) -> String:
    var label := str(_gdata.products.get(prod_id, {}).get("name", prod_id))
    for item in products:
        if str(item.get("type", "")) != "product":
            continue
        if str(item.get("name", "")).begins_with(label):
            return str(item.get("route_icon_path", ""))
    return ""


# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# The first free hex in the Influence Ring: dry, known, without an improvement,
# town or road, WITHOUT access to fresh water (otherwise the farm gets a ×1.5 bonus
# and the overload threshold shifts) — AND with a reachable road plan.
func _find_hex_in_influence(main_map) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("decorative", false):
                continue
            if tile.get("in_town_influence", false):
                continue
            if not main_map.is_hex_known(row, col):
                continue
            if _mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if _mh.get_hex_water_access(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols) != "":
                continue
            if main_map.road_manager.get_hex_road_level(row, col) > 0:
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
                continue
            return {"row": row, "col": col}
    return {}


func _free(main_map) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


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


func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
