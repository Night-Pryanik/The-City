# Headless test for territory costs: scouting and claiming are paid for with COINS
# from the city treasury, the price of a hex grows with distance from the city
# (the universal modifier from data/game_balance.json), while food is NOT spent.
#   godot --headless --path . --script res://tests/test_territory_costs.gd
#
# Checks:
#   1. The universal field distance_cost_modifier_per_hex is really read:
#      substituting the value changes both the labor of improvements and the
#      scouting/claiming coins (that is, no hardcoded 0.25 is left in the formulas).
#   2. Hex price = ceil(base × (1 + distance × modifier)), chunk price =
#      the sum of hex prices; farther from the city is more expensive.
#   3. start_scouting() deducts exactly the chunk price in coins and does NOT touch food.
#   4. With an empty treasury, scouting does not start and the treasury does not go negative.
#   5. handle_action(): when coins are insufficient — a refusal with no treasury change and no
#      construction started; when sufficient — deducting exactly the chunk price and starting
#      the claiming construction.
extends SceneTree

# Hang watchdog: without it, an aborted _run() coroutine looks from the outside like eternal
# silence. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Autoloads are fetched through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at this file's compile time.
    # new_game() also loads all the data and resets the city state.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")
    var gdata = get_root().get_node("GameData")
    # Global classes are also fetched through load(): in --script mode the names
    # HexUtils/MapHelpers are not guaranteed at the test's compile time.
    var hex_utils = load("res://scripts/HexUtils.gd")
    var map_helpers = load("res://scripts/map_helpers.gd")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    check(main_map.tile_data.size() == main_map.map_rows,
            "the map is not initialized (tile_data is empty)", state)
    var em = main_map.expansion_manager

    # --- Values from data/game_balance.json ---
    var balance: Dictionary = gdata.game_balance
    var base_scout: int = int(balance.get("scouting_cost_per_hex", -1))
    var base_expansion: int = int(balance.get("expansion_cost_per_hex", -1))
    var distance_modifier: float = float(balance.get("distance_cost_modifier_per_hex", -1.0))
    check(base_scout > 0, "scouting_cost_per_hex must be > 0 in game_balance.json", state)
    check(base_expansion > 0, "expansion_cost_per_hex must be > 0 in game_balance.json", state)
    check(distance_modifier > 0.0,
            "distance_cost_modifier_per_hex must be > 0 in game_balance.json", state)

    var city_row: int = main_map.city_row
    var city_col: int = main_map.city_col

    # --- 2. Hex price formula ---
    # City hex: distance 0 → multiplier 1 → price equals the base.
    check(em.get_hex_scout_cost(city_row, city_col) == base_scout,
            "the scouting price of the city hex must equal the base (%d)" % base_scout, state)
    check(em.get_hex_money_cost(city_row, city_col) == base_expansion,
            "the claiming price of the city hex must equal the base (%d)" % base_expansion, state)

    # Hex 4 columns to the side: for odd-r with equal rows the distance = 4.
    var probe_row: int = city_row
    var probe_col: int = min(city_col + 4, main_map.map_cols - 1)
    var probe_dist: int = hex_utils.hex_distance(probe_row, probe_col, city_row, city_col)
    check(probe_dist > 0, "the probe hex must be at distance > 0 from the city", state)

    var expected_scout: int = int(ceil(float(base_scout) * (1.0 + float(probe_dist) * distance_modifier)))
    var expected_money: int = int(ceil(float(base_expansion) * (1.0 + float(probe_dist) * distance_modifier)))
    check(em.get_hex_scout_cost(probe_row, probe_col) == expected_scout,
            "the scouting price of the hex at distance %d must be %d (got %d)"
                    % [probe_dist, expected_scout, em.get_hex_scout_cost(probe_row, probe_col)], state)
    check(em.get_hex_money_cost(probe_row, probe_col) == expected_money,
            "the claiming price of the hex at distance %d must be %d (got %d)"
                    % [probe_dist, expected_money, em.get_hex_money_cost(probe_row, probe_col)], state)
    check(em.get_hex_scout_cost(probe_row, probe_col) > em.get_hex_scout_cost(city_row, city_col),
            "the far hex must cost more than the near one (distance modifier)", state)

    # --- 1. Universality of the modifier: substituting the value changes all calculations ---
    var original_modifier: float = distance_modifier
    balance["distance_cost_modifier_per_hex"] = 1.0
    var imp_id: String = ""
    for id in gdata.improvements.keys():
        if float(gdata.improvements[id].get("work_cost", 0)) > 0.0:
            imp_id = id
            break
    check(imp_id != "", "no improvement with work_cost > 0 found for the labor check", state)
    if imp_id != "":
        var cost_data: Dictionary = map_helpers.get_improvement_work_cost(
                imp_id, probe_row, probe_col, main_map.tile_data, city_row, city_col)
        var expected_dist_mult: float = 1.0 + float(probe_dist) * 1.0
        var actual_dist_mult: float = float(cost_data.get("distance_mult_base", 0.0))
        check(abs(actual_dist_mult - expected_dist_mult) < 0.0001,
                "the labor of an improvement must take the distance modifier from game_balance.json (expected ×%.2f, got ×%.2f)"
                        % [expected_dist_mult, actual_dist_mult], state)
    check(em.get_hex_scout_cost(probe_row, probe_col)
                    == int(ceil(float(base_scout) * (1.0 + float(probe_dist) * 1.0))),
            "the scouting price must follow the value from game_balance.json", state)
    check(em.get_hex_money_cost(probe_row, probe_col)
                    == int(ceil(float(base_expansion) * (1.0 + float(probe_dist) * 1.0))),
            "the claiming price must follow the value from game_balance.json", state)
    balance["distance_cost_modifier_per_hex"] = original_modifier

    # --- 3. Scouting: coins are deducted, food is not spent ---
    var region_hex = _find_unexplored_region_hex(main_map)
    check(region_hex != null, "no unexplored hex found in the Region", state)
    if region_hex == null:
        _finish(main_map, state)
        return
    var scout_chunk: Array = em.get_chunk_hexes(region_hex.row, region_hex.col)
    check(scout_chunk.size() > 0, "the scouting chunk in the Region must not be empty", state)
    var per_hex_sum := 0
    for hex in scout_chunk:
        per_hex_sum += em.get_hex_scout_cost(hex.row, hex.col)
    var scout_cost: int = em.get_chunk_scout_cost(scout_chunk)
    check(scout_cost == per_hex_sum,
            "the scouting chunk price must be the sum of the hex prices (%d versus %d)" % [scout_cost, per_hex_sum], state)
    check(scout_cost > 0, "the scouting chunk price must be > 0", state)

    var food_before: int = _food_total(city)
    var treasury_before: int = city.treasury
    if treasury_before < scout_cost:
        city.add_treasury(scout_cost - treasury_before)
        treasury_before = city.treasury
    main_map.start_scouting(scout_chunk)
    check(main_map.is_scouting, "scouting must start when there are enough coins in the treasury", state)
    check(city.treasury == treasury_before - scout_cost,
            "the treasury must decrease by exactly the chunk price (%d): was %d, became %d"
                    % [scout_cost, treasury_before, city.treasury], state)
    check(_food_total(city) == food_before, "scouting must NOT deduct food", state)
    main_map.is_scouting = false
    main_map.scouting_chunk = []

    # --- 6. Tooltips must not depend on values that change every tick ---
    # Otherwise _build_actions() recreates the buttons every tick (tooltip comparison
    # in _actions_equal) and the hovered tooltip is reset.
    var cp = main_map.control_panel
    var probe_tile: Dictionary = main_map.tile_data[region_hex.row][region_hex.col]
    var actions_before: Array = cp._collect_actions(region_hex.row, region_hex.col, probe_tile)
    check(actions_before.size() > 0, "there must be actions for an unexplored hex", state)
    city.add_treasury(1) # the treasury changed — the tooltips must NOT change
    var actions_after: Array = cp._collect_actions(region_hex.row, region_hex.col, probe_tile)
    check(cp._actions_equal(actions_before, actions_after),
            "the scouting/claiming tooltips must not change with the treasury (the panel recreates the buttons and resets the tooltip)", state)

    # --- 4. Empty treasury: scouting does not start, no negative balance ---
    var treasury_saved: int = city.treasury
    city.treasury = 0
    main_map.start_scouting(scout_chunk)
    check(not main_map.is_scouting, "with an empty treasury, scouting must not start", state)
    check(city.treasury == 0, "the treasury must not go negative", state)
    city.treasury = treasury_saved

    # --- 5. Claiming: coins from the treasury + starting construction ---
    var expansion_chunk: Array = _find_region_hexes(main_map, em, 2)
    check(expansion_chunk.size() == 2, "2 Region hexes not found for the claiming check", state)
    if expansion_chunk.size() == 2:
        var money_cost: int = em.get_chunk_money_cost(expansion_chunk)
        var work_cost: int = em.get_chunk_cost(expansion_chunk)
        check(money_cost > 0 and work_cost > 0,
                "the claiming price (%d coins) and labor (%d) must be > 0" % [money_cost, work_cost], state)
        var builds_before: int = main_map.build_manager.get_total_active_builds()
        # Insufficient coins: refusal with no deduction and no construction.
        city.treasury = money_cost - 1
        var ok_poor: bool = em.handle_action(expansion_chunk, money_cost, work_cost)
        check(not ok_poor, "with insufficient coins handle_action() must return false", state)
        check(city.treasury == money_cost - 1, "with insufficient coins the treasury must not change", state)
        check(main_map.build_manager.get_total_active_builds() == builds_before,
                "with insufficient coins the claiming construction must not start", state)
        # Sufficient coins: deducting exactly the chunk price and starting construction.
        city.treasury = money_cost + 7
        var ok_rich: bool = em.handle_action(expansion_chunk, money_cost, work_cost)
        check(ok_rich, "with sufficient coins handle_action() must return true", state)
        check(city.treasury == 7, "the treasury must decrease by exactly the chunk price (%d)" % money_cost, state)
        check(main_map.build_manager.get_total_active_builds() == builds_before + 1,
                "the claiming construction must be started", state)

    _finish(main_map, state)

func _find_unexplored_region_hex(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if not main_map.is_valid_hex(row, col):
                continue
            # Scouting is available only into a chunk adjacent to known
            # territory (the Ring of Influence or explored hexes) — see
            # main_map.is_chunk_adjacent_to_known. We take a hex at the Ring's border,
            # otherwise start_scouting() will refuse and the test will check the wrong thing.
            if not _hex_has_known_neighbor(main_map, row, col):
                continue
            return {"row": row, "col": col}
    return null

func _hex_has_known_neighbor(main_map, row: int, col: int) -> bool:
    for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
        if main_map.is_hex_known(n.row, n.col):
            return true
    return false

func _find_region_hexes(main_map, em, count: int) -> Array:
    # Region hexes suitable for claiming: not inside another town's ring and with
    # non-zero labor. For water and "impassable" terrains expansion_cost = 0 —
    # such hexes are not suitable: start_expansion_build() requires work_cost > 0,
    # and the claiming labor does not depend on distance (a balance decision).
    var result := []
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_town_influence", false)):
                continue
            if em.get_hex_cost(row, col) <= 0:
                continue
            result.append({"row": row, "col": col})
            if result.size() >= count:
                return result
    return result

func _food_total(city) -> int:
    var total := 0
    for pid in city.city_food_pool:
        if city.city_food_pool[pid]:
            total += city.city_storage.get(pid, 0)
    return total

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("TERRITORY COSTS TEST FAILED")
        quit(1)
    else:
        print("TERRITORY COSTS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
