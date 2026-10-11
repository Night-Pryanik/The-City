# Headless test of the live refresh of the hex extended tooltip:
#   godot --headless --path . --script res://tests/test_tooltip_live_refresh.gd
#
# The rule under test: the extended tooltip must refresh WITHOUT mouse
# movement while the hex holds something that changes over time. Previously the periodic
# refresh ran only for growing resources (pastures), while the delivery lines added
# to the extended block received no updates — the delivery state froze at
# the moment the tooltip appeared. The "whether to refresh" decision is made by a SINGLE point —
# map_tooltip.has_live_content (a growing resource OR cargo on the route).
#
# Checks:
#   1. HEX WITHOUT CARGO. No goods, the resource is not growing → the hex is not "live", there is no refresh.
#   2. HEX WITH CARGO. As soon as cargo is put on the route, the hex becomes "live" —
#      exactly this was missing, and because of it the tooltip froze (the defect).
#   3. THE REFRESH CHANGES THE PICTURE. After a delivery step part of the cargo goes on its way,
#      and showing the block again gives a different picture: to "waiting to ship" is added
#      the "in transit" line. This is the "current state" that was missing.
#   4. CARGO IS GONE. When the route is empty, the hex is static again — the refresh stops.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _mh = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken as tree nodes: in --script mode the names GameData and CityData
    # are not yet available at the compilation stage of this file.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _mh = load("res://scripts/map_helpers.gd")

    await _test_live_refresh(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TOOLTIP LIVE REFRESH TEST FAILED")
        quit(1)
    else:
        print("TOOLTIP LIVE REFRESH TEST OK")
        quit(0)


func _test_live_refresh(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var tooltip = main_map.map_tooltip
    var dm = main_map.delivery_manager

    # A synthetic NON-growing resource: it has no time_to_mature, so what makes the hex
    # "live" is exactly the cargo on the route, not the filling of the pasture. This way the check
    # does not depend on where the hex landed or on the real water bonuses.
    _gdata.raw_resources["test_grain"] = {
        "id": "test_grain", "name": "Test Grain", "type": "raw",
        "improved_by": "farm", "produces": {"wheat": 10},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(),
            "a free hex in influence with a road plan must be found on the live map", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_grain"
    tile["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)

    var route: Dictionary = main_map.get_route_to_city(row, col)
    check(route.get("ok", false), "an improvement with a road must have a route", state)
    if not route.get("ok", false):
        _free(main_map)
        return

    # --- 1. A hex without cargo and without a growing resource is static. ---
    dm.clear()
    check(not dm.has_cargo(row, col), "the route must be empty before the check", state)
    check(not main_map.has_live_content(row, col),
            "a hex without cargo and without a growing resource must not count as \"live\"", state)

    # --- 2. Cargo is put on the route — the hex must become "live". ---
    var queued: bool = dm.create_cargo(row, col, "wheat", "common", 20, "test_source")
    check(queued, "the cargo must be put on the route", state)
    check(dm.has_cargo(row, col), "cargo must appear on the route", state)
    check(main_map.has_live_content(row, col),
            "a hex with cargo on the route must count as \"live\" (otherwise the tooltip freezes)", state)

    # The tooltip is shown: the extended block is bound to the hex (as after a hover delay).
    main_map.update_extended_tooltip(row, col)
    var lines_shown: Array = tooltip.delivery_lines(row, col)
    check(lines_shown.size() == 2,
            "right after the cargo is put on the route 2 lines are expected (header + waiting), got %d"
                    % lines_shown.size(), state)
    var shown_before := _collect_text(tooltip._tooltip_products_container)

    # --- 3. A delivery step changes the state — and the block must show it. ---
    var status_before: Dictionary = dm.get_route_status(row, col)
    check(int(status_before.get("pending", 0)) == 20,
            "all the cargo must be waiting to ship (got %d)"
                    % int(status_before.get("pending", 0)), state)

    dm.advance(1.0)
    dm.ship()

    var status_after: Dictionary = dm.get_route_status(row, col)
    check(int(status_after.get("pending", 0)) < 20 and int(status_after.get("in_transit", 0)) > 0,
            "after the delivery step the cargo must partially go on its way (pending=%d, in_transit=%d)"
                    % [int(status_after.get("pending", 0)), int(status_after.get("in_transit", 0))],
            state)

    # This is exactly the path used by InputHandler on the periodic refresh.
    main_map.update_tooltip_text(row, col)
    var lines_after: Array = tooltip.delivery_lines(row, col)
    check(lines_after.size() == 3,
            "after shipping the \"in transit\" line must be added (3 lines expected, got %d)"
                    % lines_after.size(), state)
    var shown_after := _collect_text(tooltip._tooltip_products_container)
    check(shown_after != shown_before,
            "the shown block must change after the delivery step — otherwise the tooltip froze at appearance",
            state)

    # --- 4. Cargo is removed — the hex is static again, the refresh stops. ---
    dm.clear()
    check(not dm.has_cargo(row, col), "after clearing the route must be empty", state)
    check(not main_map.has_live_content(row, col),
            "after all the cargo is delivered the hex is static again — the refresh stops", state)

    _free(main_map)


# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

# The first free hex in the Influence Ring: dry, known, without an improvement,
# town or road, WITHOUT access to fresh water — AND with a reachable road plan.
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
