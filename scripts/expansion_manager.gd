# expansion_manager.gd
extends Node

# The territory costs (scouting and claiming) — in COINS from the city treasury.
# The base price of one hex and the universal distance modifier are taken from
# data/game_balance.json (see get_scout_cost_per_hex / get_expansion_cost_per_hex
# and MapHelpers.get_distance_mult), that is, there is no hardcoded price here.
# The claiming additionally requires LABOUR (see expansion_cost in terrains.json),
# which accumulates through the build in build_manager. The balance decision:
# the labour remains FLAT and is NOT scaled by distance — further from the city
# only the money part gets more expensive (logistics), and not the work itself.

var is_expansion_mode = false
var hexes_bought = 0
var current_chunk = [] # an array of {"row": int, "col": int}
var current_hover_hex = null # {"row": int, "col": int}

signal expansion_mode_changed(active: bool)
signal territory_expanded(row: int, col: int, cost: int)
signal chunk_hovered(chunk: Array) # to notify the renderer

@onready var main_map = get_parent()

func toggle():
    is_expansion_mode = !is_expansion_mode
    current_chunk = []
    emit_signal("expansion_mode_changed", is_expansion_mode)
    return is_expansion_mode

func is_active() -> bool:
    return is_expansion_mode

# Returns the LABOUR cost for claiming one hex.
# The base value is taken from the expansion_cost of the terrain (it is labour now).
# The multiplier for the number of bought hexes is removed: the labour should remain
# "moderate" and should not inflate as the city grows.
func get_hex_cost(row: int, col: int) -> int:
    var tile = main_map.tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    var base_cost = 2
    if GameData.terrains.has(terrain_id):
        base_cost = GameData.terrains[terrain_id].get("expansion_cost", 2)
    # The technology modifiers (target = "construction_cost", see data/modifiers.json)
    # also reduce the cost of claiming the territory (the labour accumulates through the build).
    return int(ceil(float(base_cost) * MapHelpers.get_construction_cost_mult()))

# The base price of scouting one hex in treasury coins (data/game_balance.json).
func get_scout_cost_per_hex() -> int:
    return int(GameData.game_balance.get("scouting_cost_per_hex", 3))

# The base price of claiming one hex in treasury coins (data/game_balance.json).
# The labour is counted separately — see get_hex_cost().
func get_expansion_cost_per_hex() -> int:
    return int(GameData.game_balance.get("expansion_cost_per_hex", 5))

# The price of SCOUTING one hex: the base × the universal distance modifier
# (MapHelpers.get_distance_mult — the value from game_balance.json). By analogy
# with building improvements (MapHelpers.get_improvement_work_cost) the distant
# hexes are more expensive, but WITHOUT the tech modifiers: "Wheel" is about
# transporting cargo, while the scouts go on foot or ride horses.
func get_hex_scout_cost(row: int, col: int) -> int:
    var distance := HexUtils.hex_distance(row, col, main_map.city_row, main_map.city_col)
    return int(ceil(float(get_scout_cost_per_hex()) * MapHelpers.get_distance_mult(distance)))

# The price of CLAIMING one hex in coins: the base × the universal distance
# modifier. It is written off immediately at the start of the claim (the labour — separately, see get_hex_cost).
func get_hex_money_cost(row: int, col: int) -> int:
    var distance := HexUtils.hex_distance(row, col, main_map.city_row, main_map.city_col)
    return int(ceil(float(get_expansion_cost_per_hex()) * MapHelpers.get_distance_mult(distance)))

# Returns the chunk (the list of hexes) that includes the starting hex.
# The chunk is homogeneous by the exploration status of the starting hex, and
# this status determines its purpose:
#   - the starting hex is NOT explored → a chunk for SCOUTING. The BFS bounds depend
#     on the "Cartography" technology:
#       · Cartography is researched → the whole area reachable by scrolling the map
#         (main_map.get_scout_reach_bounds), the influence rings of other towns
#         are PASSABLE (scouts are allowed to be sent into the fog of war and to the
#         town territories);
#       · Cartography is NOT researched → only the Region (main_map.get_region_bounds):
#         scouts can be sent only to the unexplored part of the Region.
#     The Influence Ring of the player is skipped in both cases.
#   - the starting hex is explored → a chunk for BUYING (claiming). The BFS is limited
#     by the Region (main_map.is_valid_hex), and the in_town_influence hexes are skipped:
#     only your own future territory inside the Region can be claimed.
# If the starting hex is explored and lies in the influence ring of another town or
# outside the Region — an empty array is returned: there is nothing to buy there, and claiming
# someone else's territory is forbidden. This is consistent with build_manager
# rejecting the construction on the hexes in the ring.
# If the starting hex is NOT explored and lies outside the Region, and Cartography is not yet
# researched — an empty array is returned as well: before Cartography the fog of war
# is unavailable for scouting (otherwise a chunk of one starting hex would give
# a highlight in the fog and the "Send scouts" button).
# IMPORTANT: "adjacency to the known territory" (main_map.is_chunk_adjacent_to_known)
# is NOT checked here — the chunk is always assembled, so that the player sees the highlight
# and the inactive "Send scouts" button with the reason
# ("The chunk does not border the explored territory"). The gate is applied by
# control_panel (enabled/tooltip) and main_map.start_scouting (a safety net).
func get_chunk_hexes(start_row: int, start_col: int) -> Array:
    var chunk = []
    var start_tile = main_map.tile_data[start_row][start_col]
    if start_tile == null:
        return chunk
    var start_explored: bool = bool(start_tile.get("is_explored", false))
    # The purchase is possible only on an explored hex inside the Region and not on
    # the territory of another town. The checks go BEFORE the BFS: otherwise it would add
    # the starting hex to the chunk, and the panel would show "Claim the area" there where
    # claiming is not allowed. For scouting (an unexplored hex) its own
    # rule applies: inside the Region — always, outside the Region — only with Cartography.
    if start_explored:
        if bool(start_tile.get("in_town_influence", false)):
            return chunk
        if not main_map.is_valid_hex(start_row, start_col):
            return chunk
    elif not main_map.is_valid_hex(start_row, start_col) \
            and not main_map.is_cartography_researched():
        return chunk
    var visited = {}
    var queue = [ {"row": start_row, "col": start_col}]
    var key = str(start_row) + "," + str(start_col)
    visited[key] = true
    # The bounds of the area in which the SCOUTING chunk is assembled:
    #   Cartography is researched  → all the hexes reachable by scrolling the map
    #                          (the bounds are already clipped to the map edges);
    #   Cartography is not researched → only the Region (its unexplored part).
    # For the BUYING chunk the limit is the Region (the check via is_valid_hex below).
    var scout_reach: Dictionary = {}
    if not start_explored:
        if main_map.is_cartography_researched():
            scout_reach = main_map.get_scout_reach_bounds()
        else:
            scout_reach = main_map.get_region_bounds()

    while queue.size() > 0 and chunk.size() < 5:
        var current = queue.pop_front()
        chunk.append(current)
        var neighbors = _get_neighbors(current.row, current.col)
        for n in neighbors:
            var n_key = str(n.row) + "," + str(n.col)
            if visited.has(n_key):
                continue
            if start_explored:
                # The purchase (claiming): only the Region.
                if not main_map.is_valid_hex(n.row, n.col):
                    continue
            else:
                # Scouting: the Region (without Cartography) or the whole area
                # reachable by scrolling the map (with Cartography).
                if n.row < scout_reach.row_start or n.row > scout_reach.row_end \
                        or n.col < scout_reach.col_start or n.col > scout_reach.col_end:
                    continue
            var tile = main_map.tile_data[n.row][n.col]
            if tile == null:
                continue
            if tile.get("in_influence", false):
                continue
            # The hexes in the influence ring of another town do NOT get into the buying chunk:
            # we skip them just as in_influence above. The ring hexes become
            # an "impassable barrier" for the BFS, and the chunk is naturally limited
            # by the ring boundary (but it does not "go around" it from the other side, because
            # the BFS has a limit of 5 and there are no bypasses around a whole ring).
            # For SCOUTING someone else's ring is passable: scouts can be sent
            # to the town territory as well.
            if start_explored and bool(tile.get("in_town_influence", false)):
                continue
            # We exclude the hexes with a different exploration status,
            # so as not to include the already explored hexes into the scouting chunk
            if bool(tile.get("is_explored", false)) != start_explored:
                continue
            visited[n_key] = true
            queue.append(n)
    return chunk

# Returns the HIGHLIGHT chunk (up to 5 hexes) for an EXPLORED hex that has
# no action chunk (outside the Region buying is impossible). It is built by a BFS
# outwards from the hex under the cursor (as the scouting/buying chunks — the limit is 5), over
# the explored hexes; in_influence and in_town_influence do not get into the chunk.
# The result is sorted canonically (row, col), therefore the same set,
# built from different hexes of the area, gives an identical array — the change
# detection in update_hovered_chunk does not consider it a new chunk.
func _get_explored_chunk_hexes(start_row: int, start_col: int) -> Array:
    var chunk = []
    if not main_map.is_hex_on_map(start_row, start_col):
        return chunk
    var start_tile = main_map.tile_data[start_row][start_col]
    if start_tile == null or not bool(start_tile.get("is_explored", false)):
        return chunk
    var visited = {}
    var queue = [{"row": start_row, "col": start_col}]
    visited[str(start_row) + "," + str(start_col)] = true
    while queue.size() > 0 and chunk.size() < 5:
        var current = queue.pop_front()
        chunk.append(current)
        for n in _get_neighbors(current.row, current.col):
            var n_key = str(n.row) + "," + str(n.col)
            if visited.has(n_key):
                continue
            if not main_map.is_hex_on_map(n.row, n.col):
                continue
            var tile = main_map.tile_data[n.row][n.col]
            if tile == null:
                continue
            if not bool(tile.get("is_explored", false)):
                continue
            if bool(tile.get("in_influence", false)) \
                    or bool(tile.get("in_town_influence", false)):
                continue
            visited[n_key] = true
            queue.append(n)
    # The canonical order: the highlight of one area should not depend on
    # which of its hexes the BFS started from.
    chunk.sort_custom(func(a, b):
        if a.row != b.row:
            return a.row < b.row
        return a.col < b.col)
    return chunk

# Returns the hexes that need to be highlighted when hovering or selecting the hex
# (row, col) — the single source of truth for the renderer (PHASE 2.5 hover and PHASE 3.5
# selection), so that the highlight does not diverge from the chunk the panel
# actions work with:
#   - a hex in the Influence Ring — only it itself;
#   - otherwise — the scouting/buying chunk (get_chunk_hexes);
#   - if there is no chunk and the hex is EXPLORED (an explored area outside the Region —
#     buying there is not allowed) → a highlight chunk of up to 5 hexes, built outwards
#     from the hex under the cursor (_get_explored_chunk_hexes): hovering and clicking
#     must not be "silent";
#   - if there is no chunk and the hex is in the influence ring of another town (or in
#     the fog without Cartography) → the hex itself.
func get_highlight_hexes(row: int, col: int) -> Array:
    var single := [{"row": row, "col": col}]
    if not main_map.is_hex_on_map(row, col):
        return []
    var tile = main_map.tile_data[row][col]
    if tile == null:
        return []
    if bool(tile.get("in_influence", false)):
        return single
    var chunk = get_chunk_hexes(row, col)
    if chunk.is_empty():
        # An explored hex outside the Region → a highlight chunk. A hex in the ring of
        # another town is an exception: buying there is always forbidden, and
        # we highlight only the hex itself (the BFS must not "exit" the ring
        # onto the neighbouring explored hexes).
        if bool(tile.get("is_explored", false)) \
                and not bool(tile.get("in_town_influence", false)):
            return _get_explored_chunk_hexes(row, col)
        return single
    return chunk

# Updates the currently highlighted chunk. The change detection and the storage go by
# the HIGHLIGHT SET (get_highlight_hexes), and not by the action chunk: for
# the explored hexes outside the Region the action chunk is always empty, and the comparison
# [] == [] gave no signal — the highlight "froze" at the previous cursor position
# when moving between such areas.
func update_hovered_chunk(row: int, col: int):
    current_hover_hex = {"row": row, "col": col}
    var highlight = get_highlight_hexes(row, col)
    if _chunk_equals(highlight, current_chunk):
        return
    current_chunk = highlight
    emit_signal("chunk_hovered", current_chunk)

func clear_hovered_chunk():
    current_hover_hex = null
    if current_chunk.is_empty():
        return
    current_chunk = []
    emit_signal("chunk_hovered", current_chunk)

# The LABOUR cost of the whole chunk = the sum of the labour over the hexes.
func get_chunk_cost(chunk: Array) -> int:
    var total = 0
    for hex in chunk:
        total += get_hex_cost(hex.row, hex.col)
    return total

# The price of SCOUTING the whole chunk in treasury coins = the sum of the prices over
# the hexes (each hex with its own distance modifier from the city).
func get_chunk_scout_cost(chunk: Array) -> int:
    var total = 0
    for hex in chunk:
        total += get_hex_scout_cost(hex.row, hex.col)
    return total

# The price of CLAIMING the whole chunk in treasury coins = the sum of the prices
# over the hexes. The labour of the chunk is counted separately — get_chunk_cost().
func get_chunk_money_cost(chunk: Array) -> int:
    var total = 0
    for hex in chunk:
        total += get_hex_money_cost(hex.row, hex.col)
    return total

# Starts the claiming of the chunk. The coins (the price of the chunk, see get_chunk_money_cost)
# are written off from the treasury immediately, and the labour accumulates through the build in
# build_manager (progress over time).
func handle_action(chunk: Array, money_cost: int, work_cost: int) -> bool:
    # --- A safety repeat: the chunk must not contain the hexes from the influence ring
    # of another town. get_chunk_hexes does not allow this, but handle_action is
    # a public entry point: chunks from other paths
    # (for example, from a test or from the future UI) can come here. We refuse silently: the logic
    # "it cannot be bought" is already explained in control_panel (there are no actions).
    for hex in chunk:
        if hex.row < 0 or hex.row >= main_map.map_rows or hex.col < 0 or hex.col >= main_map.map_cols:
            return false
        var h_tile = main_map.tile_data[hex.row][hex.col]
        if h_tile == null:
            return false
        if bool(h_tile.get("in_town_influence", false)):
            main_map.hud.show_message(tr("The chunk overlaps another town's influence ring — purchase impossible"))
            return false

    # --- The check and write-off of the coins from the treasury ---
    # Debug: with "Ignore building requirements" enabled the claiming
    # is free — the coins are neither checked nor written off (the expense rows
    # are not written either, otherwise the treasury breakdown would show a non-existent
    # expense). The same principle as for the additional materials of buildings.
    if not CityData.ignore_build_requirements:
        if not CityData.spend_treasury(money_cost):
            main_map.hud.show_message(tr("Not enough coins in the treasury! Need %d, treasury has %d")
                    % [money_cost, CityData.treasury])
            return false
        # The expense source for the "Treasury" tooltip (see show_treasury_tooltip).
        # The one-time costs of claiming a chunk are event-based, they are not in the plan, therefore
        # the expense breakdown shows the fact for the last display window.
        if money_cost > 0:
            CityData.record_treasury_expense(GameData.SRC_CLAIMING, money_cost)

    # --- Starting the claiming build (the labour accumulates over time) ---
    var bm = main_map.build_manager
    if bm and bm.has_method("start_expansion_build"):
        if bm.start_expansion_build(chunk, work_cost, money_cost):
            return true
        # The build did not start (for example, the limit of simultaneous
        # builds is exhausted) — we return the coins, so that they do not disappear.
        CityData.add_treasury(money_cost)
        if money_cost > 0:
            # The refund goes to THE SAME expense source "Claiming chunks"
            # as a negative record: record_treasury_expense accepts a
            # signed amount, a negative number is subtracted from the accumulated
            # expense for this source. The net over the window matches the fact
            # of the treasury change (paid Y → got Y back → 0 over the window).
            # Previously the refund went as a separate income source "… (refund)",
            # but with the hierarchical breakdown of the treasury it does not fit into any
            # type ("Population consumption" is not a refund), therefore
            # we note it inside the expense.
            CityData.record_treasury_expense(GameData.SRC_CLAIMING, -money_cost)
        return false
    # Fallback: if build_manager is unavailable — we claim instantly.
    _complete_expansion(chunk)
    return true

# The handler of the completion of the claiming build: the labour is accumulated — we join the chunk.
# It is connected in main_map._ready() to the signal build_manager.expansion_build_completed.
func on_expansion_build_completed(chunk: Array):
    _complete_expansion(chunk)

# Completes the claiming of the chunk: marks the hexes as belonging to the Influence Ring.
func _complete_expansion(chunk: Array):
    for hex in chunk:
        if hex.row >= 0 and hex.row < main_map.map_rows and hex.col >= 0 and hex.col < main_map.map_cols:
            main_map.tile_data[hex.row][hex.col]["in_influence"] = true
            hexes_bought += 1
    current_chunk = []
    emit_signal("territory_expanded", chunk[0].row, chunk[0].col, get_chunk_cost(chunk))

func _chunk_equals(a: Array, b: Array) -> bool:
    if a.size() != b.size():
        return false
    for i in range(a.size()):
        if a[i].row != b[i].row or a[i].col != b[i].col:
            return false
    return true

func _get_neighbors(row: int, col: int) -> Array:
    var neighbors = []
    var directions = []
    if row % 2 == 0:
        directions = [
            {"r": 0, "c": - 1}, {"r": 0, "c": 1},
            {"r": - 1, "c": - 1}, {"r": - 1, "c": 0},
            {"r": 1, "c": - 1}, {"r": 1, "c": 0}
        ]
    else:
        directions = [
            {"r": 0, "c": - 1}, {"r": 0, "c": 1},
            {"r": - 1, "c": 0}, {"r": - 1, "c": 1},
            {"r": 1, "c": 0}, {"r": 1, "c": 1}
        ]
    for d in directions:
        neighbors.append({"row": row + d.r, "col": col + d.c})
    return neighbors

func is_hovering_region() -> bool:
    return current_hover_hex != null
