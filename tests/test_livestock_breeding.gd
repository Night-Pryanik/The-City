# Headless test of the livestock breeding link:
#   godot --headless --path . --script res://tests/test_livestock_breeding.gd
#
# The rule being checked: the breeding of a herd on an empty hex takes a seed herd
# (livestock_breeding_cost heads of the live_* product) from the storage; the first
# heads come from the domestication grant or from a purchase in a town.
#
# Checks:
#   1. THE GRANT. The first build on a species (the domestication) grants the seed
#      herd to the storage; the second build of the same species grants nothing.
#   2. THE PURCHASE. The arrival of a live product of an unknown species registers
#      the species as domesticated, without an extra grant on top of the purchase.
#   3. TAKE/RETURN. take_livestock_for writes off exactly the cost and fails when
#      the storage is short; return_livestock_for brings the heads back. Species
#      without a live product (the plants) always pass.
#   4. THE FAIL-FAST. start_build rejects the breeding of a species without heads
#      and accepts it with them (the instant build consumes the heads and places
#      the herd).
#   5. THE CANCELLATIONS. The cancellation of an unfinished build returns the
#      heads; the handler of the cancelled project returns them as well.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null
var _bm = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    # Autoloads are taken as tree nodes: in --script mode the names GameData/CityData
    # are not yet available at the compile stage of this file.
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    _bm = main_map.build_manager

    var spot_a := _find_free_hex(main_map)
    var spot_b := _find_free_hex(main_map, [spot_a])
    var spot_c := _find_free_hex(main_map, [spot_a, spot_b])
    var spot_d := _find_free_hex(main_map, [spot_a, spot_b, spot_c])
    var spot_e := _find_free_hex(main_map, [spot_a, spot_b, spot_c, spot_d])
    check(not spot_a.is_empty() and not spot_b.is_empty()
            and not spot_c.is_empty() and not spot_d.is_empty() and not spot_e.is_empty(),
            "five free hexes are needed for the check", state)
    if spot_a.is_empty() or spot_b.is_empty() or spot_c.is_empty() \
            or spot_d.is_empty() or spot_e.is_empty():
        _finish(main_map, state)
        return

    # The starting hexes have no roads, so an ordinary build normally goes through the
    # "road -> improvement" project. For the checks of the ORDINARY path the road is laid
    # right away; spot_e stays unconnected and exercises the project path.
    for spot in [spot_c, spot_d]:
        main_map.road_manager.build_road_from(int(spot.row), int(spot.col),
                main_map.tile_data, main_map.map_rows, main_map.map_cols)

    # --- 0. The mapping: both directions are derived from the data ---
    check(_gdata.live_product_of("cows") == "live_cows",
            "cows must map to the live product live_cows (got \"%s\")"
                    % _gdata.live_product_of("cows"), state)
    check(_gdata.raw_of_live_product("live_cows") == "cows",
            "live_cows must map back to the raw resource cows (got \"%s\")"
                    % _gdata.raw_of_live_product("live_cows"), state)

    # --- 1. The grant on the first domestication ---
    var cost: int = _cdata.livestock_breeding_cost()
    check(cost > 0, "the breeding cost must be positive", state)
    main_map._apply_improvement(int(spot_a.row), int(spot_a.col), "pasture", "cows")
    var tile_a: Dictionary = main_map.tile_data[int(spot_a.row)][int(spot_a.col)]
    check(str(tile_a.get("crop_bred", "")) == "cows",
            "the breeding must place the herd in crop_bred (got \"%s\")"
                    % str(tile_a.get("crop_bred", "")), state)
    check("cows" in _cdata.domesticated_resources,
            "the build on a natural herd must register the species as domesticated", state)
    check(_cdata.get_storage_amount("live_cows") == cost,
            "the first domestication must grant exactly the cost of one herd (%d, got %d)"
                    % [cost, _cdata.get_storage_amount("live_cows")], state)

    # The second build of the same species grants nothing.
    main_map._apply_improvement(int(spot_b.row), int(spot_b.col), "pasture", "cows")
    check(_cdata.get_storage_amount("live_cows") == cost,
            "the second build of a known species must grant nothing (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)

    # --- 2. The purchase registers the species, without an extra grant ---
    _cdata.add_to_storage("live_pigs", 3)
    check("pigs" in _cdata.domesticated_resources,
            "the arrival of a purchased herd must register the species as domesticated", state)
    check(_cdata.get_storage_amount("live_pigs") == 3,
            "a purchase must not grant extra heads on top of the bought ones (got %d)"
                    % _cdata.get_storage_amount("live_pigs"), state)

    # --- 3. take/return ---
    check(_cdata.take_livestock_for("cows"), "the take of the granted herd must succeed", state)
    check(_cdata.get_storage_amount("live_cows") == 0,
            "the take must write off exactly the cost (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    check(not _cdata.take_livestock_for("cows"),
            "the take without heads must fail", state)
    check(not _cdata.has_livestock_for("cows"),
            "has_livestock_for must be false with an empty storage", state)
    _cdata.return_livestock_for("cows")
    check(_cdata.get_storage_amount("live_cows") == cost,
            "the return must bring the heads back (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    check(_cdata.has_livestock_for("wheat_field") and _cdata.take_livestock_for("wheat_field"),
            "a species without a live product (the plants) must breed without heads", state)

    # --- 4. The fail-fast and the instant build ---
    _cdata.remove_from_storage("live_cows", 100000)
    check(_cdata.get_storage_amount("live_cows") == 0,
            "the drain before the fail-fast check must empty the storage", state)
    var started: bool = _bm.start_build(int(spot_c.row), int(spot_c.col), "pasture", "cows")
    check(not started,
            "the breeding without heads must be rejected at the start", state)
    check(not _bm.is_building(int(spot_c.row), int(spot_c.col)),
            "the rejected breeding must not leave an active build", state)

    _cdata.add_to_storage("live_cows", cost)
    _cdata.ignore_build_requirements = true
    started = _bm.start_build(int(spot_c.row), int(spot_c.col), "pasture", "cows")
    check(started, "the breeding with heads must be accepted", state)
    var tile_c: Dictionary = main_map.tile_data[int(spot_c.row)][int(spot_c.col)]
    check(str(tile_c.get("crop_bred", "")) == "cows",
            "the instant breeding must place the herd (got \"%s\")"
                    % str(tile_c.get("crop_bred", "")), state)
    check(_cdata.get_storage_amount("live_cows") == 0,
            "the instant breeding must consume the seed herd (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    _cdata.ignore_build_requirements = false

    # --- 5. The cancellation of an ordinary build ---
    _cdata.add_to_storage("live_cows", cost)
    started = _bm.start_build(int(spot_d.row), int(spot_d.col), "pasture", "cows")
    check(started, "the ordinary breeding build must start", state)
    check(_cdata.get_storage_amount("live_cows") == 0,
            "the start of the build must consume the seed herd (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    _bm.cancel_build(int(spot_d.row), int(spot_d.col))
    check(_cdata.get_storage_amount("live_cows") == cost,
            "the cancellation of the build must return the seed herd (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)

    # --- 6. The project path: the "road -> breeding" chain consumes and refunds ---
    # spot_e is unconnected: start_build delegates to the staged project, the herd is
    # written off at the start of the project and returns on its cancellation.
    started = _bm.start_build(int(spot_e.row), int(spot_e.col), "pasture", "cows")
    check(started, "the breeding as a staged project must start", state)
    check(_cdata.get_storage_amount("live_cows") == 0,
            "the start of the project must consume the seed herd (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)
    main_map.project_manager.cancel_project_at(int(spot_e.row), int(spot_e.col))
    check(_cdata.get_storage_amount("live_cows") == cost,
            "the cancellation of the project must return the seed herd (got %d)"
                    % _cdata.get_storage_amount("live_cows"), state)

    _finish(main_map, state)

func _find_free_hex(main_map, taken: Array = []) -> Dictionary:
    for r in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for c in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var skip := false
            for t in taken:
                if int(t.row) == r and int(t.col) == c:
                    skip = true
                    break
            if skip:
                continue
            var tile = main_map.tile_data[r][c]
            if tile == null or tile.get("improvement", null) != null:
                continue
            # The breeding needs an EMPTY hex: with a natural resource the build
            # becomes an ordinary extraction and consumes no heads.
            if tile.get("resource", null) != null or tile.get("crop_bred", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("in_town_influence", false):
                continue
            if r == main_map.city_row and c == main_map.city_col:
                continue
            return {"row": r, "col": c}
    return {}

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("LIVESTOCK BREEDING TEST FAILED")
        quit(1)
    else:
        print("LIVESTOCK BREEDING TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
