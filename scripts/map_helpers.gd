class_name MapHelpers

## Returns the common multiplier of the construction cost from the researched
## technologies. Reads data/modifiers.json, the "tech_modifiers" block,
## target = "construction_cost" (for example, "Mathematics" reduces the
## construction cost by 10%).
## The value is interpreted as a percentage: -10 → the multiplier 0.9.
## The multipliers of different technologies are multiplied together.
static func get_construction_cost_mult() -> float:
    var construction_tech_mult := 1.0
    for tm in GameData.modifiers.get("tech_modifiers", []):
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not CityData.is_tech_unlocked(tech_id):
            continue
        for mod in tm.get("modifiers", []):
            if mod.get("target", "") != "construction_cost":
                continue
            if mod.get("type", "percent") != "percent":
                continue
            var value = float(mod.get("value", 0))
            construction_tech_mult *= 1.0 + value / 100.0
    return construction_tech_mult

## The universal distance modifier: an addition to the cost of an action for every
## hex of the distance from the city (a share; 0.25 = +25% per hex). The source —
## data/game_balance.json, the field "distance_cost_modifier_per_hex".
## A SINGLE value for all the costs that depend on the distance: the labour of the
## construction of the improvements and of the special actions
## (get_improvement_work_cost), the coins of the scouting and of the development of
## a chunk (expansion_manager). Do NOT hardcode it locally — otherwise the balance
## drifts apart from file to file.
static func get_distance_cost_modifier() -> float:
    return float(GameData.game_balance.get("distance_cost_modifier_per_hex", 0.25))

## The tech multipliers that affect the CONTRIBUTION of the distance to the labour
## cost: reads data/modifiers.json, the "tech_modifiers" block,
## target = "improvement_distance_cost" (for example, "The Wheel" reduces it by
## 30%). The multipliers of different technologies are multiplied together. The
## value is interpreted as a percentage: -30 → 0.7.
##
## It is a separate function because the contribution of the distance exists both
## for the improvements and for the segments of a road (see
## get_road_step_work_cost). Two copies of this loop would drift apart at the very
## first edit: a technology would reduce the price of an improvement, but not of a
## road, and the rule "the distance gets cheaper thanks to the technologies"
## would stop holding.
static func get_distance_tech_mult() -> float:
    var mult := 1.0
    for tm in GameData.modifiers.get("tech_modifiers", []):
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not CityData.is_tech_unlocked(tech_id):
            continue
        for mod in tm.get("modifiers", []):
            if mod.get("target", "") != "improvement_distance_cost":
                continue
            var value = float(mod.get("value", 0))
            mult *= 1.0 + value / 100.0
    return mult

## The multiplier of the cost from the distance to the city (in hexes) WITHOUT the
## tech modifiers: 1 + the distance × get_distance_cost_modifier().
static func get_distance_mult(distance: int) -> float:
    return 1.0 + float(distance) * get_distance_cost_modifier()

## Returns the actual labour cost of building the improvement imp_id on the hex
## (row, col). The cost depends on the base work_cost of the improvement, on the
## type of the terrain (move_cost) and on the distance from the city. Returns a
## dictionary with the resulting cost and the details of the calculation (for the
## extended tooltip).
static func get_improvement_work_cost(
    imp_id: String,
    row: int,
    col: int,
    tile_data: Array,
    city_row: int,
    city_col: int
) -> Dictionary:
    # The special actions are not improvements — we use their base cost from the data.
    var base_cost := 0.0
    if GameData.special_actions.has(imp_id):
        base_cost = float(GameData.special_actions[imp_id].get("work_cost", 0))
    else:
        var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
        base_cost = float(imp_data.get("work_cost", 0))

    # The multiplier from the type of the terrain: the higher the move_cost, the
    # harder it is to build.
    var terrain_id := "plain"
    if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
        terrain_id = tile_data[row][col].get("terrain", "plain")

    var move_cost := 1.0
    if GameData.terrains.has(terrain_id):
        move_cost = float(GameData.terrains[terrain_id].get("move_cost", 1))

    # The multiplier of the construction difficulty. If the terrain explicitly has
    # work_cost_mult (for example, for the lakes with move_cost=999, where
    # move_cost means "impassable" for the units and not a difficulty of the
    # construction), we use it.
    # Otherwise we calculate by the formula based on move_cost.
    var terrain_mult := 1.0 + (move_cost - 1.0) * 0.35
    if GameData.terrains.has(terrain_id):
        var work_cost_mult_override: float = GameData.terrains[terrain_id].get("work_cost_mult", -1.0)
        if work_cost_mult_override >= 0.0:
            terrain_mult = float(work_cost_mult_override)

    # The multiplier from the distance to the city (in hexes).
    var distance := HexUtils.hex_distance(row, col, city_row, city_col)

    # The tech modifiers that affect the contribution of the distance to the labour
    # cost (for example, "The Wheel" reduces it by 30%). The shared function is the
    # very same one as for the segments of a road (see get_distance_tech_mult).
    var distance_tech_mult := get_distance_tech_mult()

    # The original distance multiplier (the UNIVERSAL value from
    # data/game_balance.json — the field distance_cost_modifier_per_hex) and the
    # resulting one taking the tech modifiers into account. The value is the same
    # for the improvements, the special actions, the scouting and the development —
    # see get_distance_cost_modifier().
    var distance_modifier := get_distance_cost_modifier()
    var distance_mult_base := get_distance_mult(distance)
    var distance_mult := 1.0 + float(distance) * distance_modifier * distance_tech_mult

    var final_cost := int(ceil(base_cost * terrain_mult * distance_mult * get_construction_cost_mult()))

    return {
        "cost": final_cost,
        "base_cost": int(base_cost),
        "terrain_id": terrain_id,
        "terrain_name": GameData.terrains.get(terrain_id, {}).get("name", terrain_id),
        "move_cost": move_cost,
        "terrain_mult": terrain_mult,
        "distance": distance,
        "distance_mult_base": distance_mult_base,
        "distance_tech_mult": distance_tech_mult,
        "distance_mult": distance_mult,
        "construction_tech_mult": get_construction_cost_mult()
    }

## The multiplier of the construction difficulty by the TERRAIN of the hex. The
## source — data/terrains/terrains.json, the field "work_cost_mult" (a plain 1.0,
## a swamp 2.0, the mountains 2.5). If the field is not set, the multiplier is
## calculated from move_cost as 1 + (move_cost − 1) × 0.35 — the same formula as
## for the improvements (see get_improvement_work_cost), so that the "hills" cost
## the same everywhere.
##
## The same field as for the improvements: the "difficulty of the construction"
## does not depend on what exactly is being built. A road that goes through the
## mountains is precisely the case where there is no way around (a town beyond the
## ridge, a river), and the planner (road_manager._find_path_between — a Dijkstra
## over move_cost) chooses the detour itself when there is one.
static func get_terrain_work_mult(terrain_id: String) -> float:
    if not GameData.terrains.has(terrain_id):
        return 1.0
    var override = float(GameData.terrains[terrain_id].get("work_cost_mult", -1.0))
    if override >= 0.0:
        return override
    var move_cost = float(GameData.terrains[terrain_id].get("move_cost", 1))
    return 1.0 + (move_cost - 1.0) * 0.35

## The distance modifier FOR A SEGMENT OF A ROAD. A separate field of
## game_balance.json ("road_distance_cost_modifier_per_hex"), and NOT the common
## distance_cost_modifier_per_hex of the improvements, and this is why.
##
## The common multiplier is applied to ONE building, where the player chooses the
## hex himself. A road is a chain of segments, and the formula is applied to each
## of them: the price grows along with the distance of every hex. At 0.25 the
## distance multiplier of the segment #20 equals 6.0, and the sum over the route
## comes out several times more expensive than the base one. The coefficient 0.1
## gives 1.1, 1.2, …, 2.0 — the multiplier is read in the tooltip and calculated
## in one's head without a calculator. Both values live in game_balance.json, so
## the balance is turned by the data, and not by an edit of the code.
static func get_road_distance_cost_modifier() -> float:
    return float(GameData.game_balance.get("road_distance_cost_modifier_per_hex", 0.1))

## The distance multiplier of a segment of a road WITHOUT the tech modifiers:
## 1 + the distance × get_road_distance_cost_modifier().
static func get_road_distance_mult(distance: int) -> float:
    return 1.0 + float(distance) * get_road_distance_cost_modifier()

## The labour cost for ONE segment of a road. A segment connects two neighbouring
## hexes, and the price depends on the hex that the step JOINS to the network
## (to_hex): `from` is already in the network and it has been paid for when the
## road reached it.
##
## road_level — the level of the road (data/roads.json). The base is the
## work_cost of the level. The difference is not cosmetic: a segment belongs to a
## level, and the level also determines how much such a segment carries
## (max_speed). Two different files with the same price would drift apart at the
## first balance edit, and "Build road" would show the price of a trail instead of
## the one the player chose.
##
## The multipliers, in the order of application:
##   the work_cost of the level (data/roads.json) — the base for a segment. The
##     level 1 (a trail) is a paid one: a road that is built together with an
##     improvement costs exactly as much as the same road built separately; there
##     is no zero base in the data at the moment, and the guard below stays for
##     the case of its appearance;
##   work_cost_mult (the terrain of to_hex) — more expensive in the mountains, and
##     in the swamps too;
##   the distance from the city (to_hex) — to haul the materials further;
##   "The Wheel" (improvement_distance_cost) — reduces the contribution of the
##     distance;
##   "Mathematics" (construction_cost) — reduces the whole construction cost.
##
## There is no separate multiplier for the length of the route and there is no
## need for one: a long road takes longer to build because it has more segments,
## and not because a surcharge is charged for the "length". Every segment is paid
## for on its own merits — its price is visible on its progress bar.
static func get_road_step_work_cost(
    road_level: int,
    to_row: int,
    to_col: int,
    city_row: int,
    city_col: int,
    terrain_id: String
) -> Dictionary:
    var base_cost := float(GameData.get_road_work_cost(road_level))

    var distance := HexUtils.hex_distance(to_row, to_col, city_row, city_col)
    var terrain_mult := get_terrain_work_mult(terrain_id)
    var distance_mult := get_road_distance_mult(distance)
    var distance_tech_mult := get_distance_tech_mult()
    var construction_tech_mult := get_construction_cost_mult()

    # Does distance_mult already include "The Wheel"? No: it is "pure", and the
    # tech multiplier is applied to the CONTRIBUTION of the distance, therefore
    # the resulting distance multiplier has the same form as for the improvements:
    # 1 + d × the coefficient × tech.
    var distance_mult_total := 1.0 + float(distance) \
            * get_road_distance_cost_modifier() * distance_tech_mult

    var final_cost := int(ceil(base_cost * terrain_mult * distance_mult_total \
            * construction_tech_mult))

    # A free level is charged as a zero and not as a one: `maxi(1, …)` would turn a
    # road that costs nothing to build into a paid one. At the moment there is no
    # zero base in the data (a trail costs work_cost = 5), and the guard stays for
    # the case of such a level being added after all: otherwise a step without any
    # work would never finish on its own and would hold a slot in the queue of the
    # project forever.
    var cost := 0 if base_cost <= 0.0 else maxi(1, final_cost)

    return {
        "cost": cost,
        "road_level": road_level,
        "base_cost": int(base_cost),
        "terrain_id": terrain_id,
        "terrain_name": GameData.terrains.get(terrain_id, {}).get("name", terrain_id),
        "terrain_mult": terrain_mult,
        "distance": distance,
        "distance_mult_base": distance_mult,
        "distance_tech_mult": distance_tech_mult,
        "distance_mult": distance_mult_total,
        "construction_tech_mult": construction_tech_mult
    }

## --- The forest clearing (lumberjack_hut) ---

## The yield of the wood of the cover of a hex (the field wood_yield in
## data/covers.json). ANY cover with wood_yield > 0 is taken into account: the
## future types of a cover (the jungles, the taiga, etc.) only have to be
## described in covers.json — there is no need to edit the code. A missing field,
## the cover "none" or an unknown id = a yield of 0.
static func get_cover_wood_yield(tile: Dictionary) -> float:
    var cover_id: String = tile.get("cover", "none")
    if not GameData.covers.has(cover_id):
        return 0.0
    return float(GameData.covers[cover_id].get("wood_yield", 0.0))

## Whether a forest clearing can be built on a hex: the hex is empty (there is no
## improvement, no resource and no cultivated crop), it is a dry land — not a
## mountain, not a water, not a swamp/marsh, not an impassable terrain (the
## salt/soda/bitumen lakes and any future type with move_cost >= 999) — and the
## cover gives the wood (wood_yield > 0).
static func can_build_lumberjack_hut(tile: Dictionary) -> bool:
    if tile.improvement != null:
        return false
    if tile.resource != null or tile.get("crop_bred", null) != null:
        return false
    if tile.get("has_town", false):
        return false
    # It cannot be built in the ring of influence of another town (see
    # build_manager.start_build); here — a UI filter, so that the button is not
    # shown on the hexes where the construction would be rejected anyway.
    if tile.get("in_town_influence", false):
        return false
    var terrain_id: String = tile.get("terrain", "")
    if terrain_id == "mountain" or terrain_id == "swamp" or terrain_id == "marsh":
        return false
    if is_water_terrain(terrain_id):
        return false
    # An impassable terrain: move_cost >= 999 in data/terrains/terrains.json means
    # "impassable" (the soda/bitumen lakes are marked that way, etc.).
    # The condition is universal — the new impassable types are taken into account
    # automatically.
    if GameData.terrains.has(terrain_id) \
            and float(GameData.terrains[terrain_id].get("move_cost", 1)) >= 999.0:
        return false
    return get_cover_wood_yield(tile) > 0.0

## Returns the index of the edge of the hex (row, col) that is common with the
## neighbour (neighbor_row, neighbor_col). It is used to check whether a river
## touches exactly the common edge between two hexes (for example, when building a
## canal).
##
## The hexes are oriented with a point up (pointy-top), the indices of the edges
## (0..5) go clockwise starting from the lower-right one:
##   0 — lower-right, 1 — lower-left, 2 — left,
##   3 — upper-left,  4 — upper-right, 5 — right.
## For a pointy-top with the offset odd-r the neighbours W/E give the edges 2/5,
## the upper/lower diagonals (NW,NE,SW,SE) — the edges 3,4,1,0 respectively; the
## direction is determined GEOMETRICALLY (where the neighbour is shifted), and not
## by the name in directions[].
##
## Returns -1 if (neighbor_row, neighbor_col) is NOT a neighbour on the grid (for
## example, in odd-r the offset (-1, +1) is invalid for an even row).
static func get_shared_edge_index(row: int, col: int, neighbor_row: int, neighbor_col: int) -> int:
    var dr = neighbor_row - row
    var dc = neighbor_col - col
    if dr == 0 and dc == -1:
        return 2 # W
    if dr == 0 and dc == 1:
        return 5 # E
    var is_odd = (row % 2) == 1
    if dr == -1:
        # The upper row: for an even row dc=-1 (NW) and dc=0 (N) are valid, for an
        # odd one — dc=0 (N) and dc=+1 (NE). The other dc — are not neighbours.
        if is_odd:
            if dc == 0: return 3
            if dc == 1: return 4
        else:
            if dc == -1: return 3
            if dc == 0: return 4
        return -1
    if dr == 1:
        # The lower row: for an even row dc=-1 (SW) and dc=0 (S) are valid, for an
        # odd one — dc=0 (S) and dc=+1 (SE). The other dc — are not neighbours.
        if is_odd:
            if dc == 0: return 1
            if dc == 1: return 0
        else:
            if dc == -1: return 1
            if dc == 0: return 0
        return -1
    return -1

static func get_water_chain_length() -> int:
    var best := 0
    for tm in GameData.modifiers.get("tech_modifiers", []):
        if not (tm is Dictionary):
            continue
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not CityData.is_tech_unlocked(tech_id):
            continue
        for mod in tm.get("modifiers", []):
            if not (mod is Dictionary):
                continue
            if mod.get("target", "") != "water_chain_length":
                continue
            var v = int(mod.get("value", 0))
            if v > best:
                best = v
    return best


## Whether the canal built on the hex (row, col) will have access to the fresh
## water. It uses get_hex_water_access with phantom_conductor=true (the BFS
## considers the hex as a conductor of a canal and looks for a path to a direct
## source — a lake or a river — through a chain of the existing conductors within
## chain_length (irrigation=3, canals=4). It does not depend on the technology
## "Canals". It is used in can_build_canal and in control_panel.gd.
static func would_canal_have_water(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
    return get_hex_water_access(row, col, tile_data, map_rows, map_cols, true) != ""

static func can_build_canal(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> Dictionary:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return {"ok": false, "reason": TranslationServer.translate("Hex outside the map")}
    var tile = tile_data[row][col]
    if tile == null:
        return {"ok": false, "reason": TranslationServer.translate("Hex does not exist")}
    if not tile.get("in_influence", false):
        return {"ok": false, "reason": TranslationServer.translate("Hex outside the Influence Ring")}
    if tile.get("has_town", false):
        return {"ok": false, "reason": TranslationServer.translate("Another town stands here")}
    # A canal cannot be built in the ring of influence of another town either — the
    # paired check with build_manager.start_build for the consistency of the UI.
    if tile.get("in_town_influence", false):
        return {"ok": false, "reason": TranslationServer.translate("Inside another town's influence ring")}
    if tile.get("improvement", null) != null:
        return {"ok": false, "reason": TranslationServer.translate("Hex is already occupied by an improvement")}
    if tile.get("resource", null) != null or tile.get("crop_bred", null) != null:
        return {"ok": false, "reason": TranslationServer.translate("Hex is not empty")}
    var terrain_id: String = tile.get("terrain", "plain")
    if is_water_terrain(terrain_id):
        return {"ok": false, "reason": TranslationServer.translate("Cannot build on water")}
    if terrain_id == "mountain":
        return {"ok": false, "reason": TranslationServer.translate("Cannot build in the mountains")}
    if terrain_id == "swamp" or terrain_id == "marsh":
        return {"ok": false, "reason": TranslationServer.translate("Cannot build on a marsh")}
    # The ban of the "impassable" custom terrains: move_cost >= 999 — that is
    # already a water by the move_cost logic (is_water_terrain catches the
    # sea/lake, but the custom lakes like asphalt_lake/salt_lake/soda_lake do not
    # pass it either).
    var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
    if int(t_data.get("move_cost", 1)) >= 999:
        return {"ok": false, "reason": TranslationServer.translate("Cannot build on impassable terrain")}
    if not CityData.is_improvement_unlocked("irrigation_canal"):
        return {"ok": false, "reason": TranslationServer.translate("Requires the \"Canals\" technology")}
    if not would_canal_have_water(row, col, tile_data, map_rows, map_cols):
        return {"ok": false, "reason": TranslationServer.translate("No water access within the chain's reach (irrigation/canals: 3/4 hops from a river/lake)")}
    return {"ok": true, "reason": ""}


## Whether a terrain (by its id) is a source of the fresh water. It reads the flag
## `fresh_water_source: true` from data/terrains.json. At the moment — "lake", but
## it is enough to give the new fresh water terrains this field.
static func _is_fresh_water_source_terrain(terrain_id: String) -> bool:
    if terrain_id == "":
        return false
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    return bool(t.get("fresh_water_source", false))

## Whether a cover (by its id) is a source of the fresh water. It reads the flag
## `fresh_water_source: true` from data/covers.json. At the moment — "oasis".
static func _is_fresh_water_source_cover(cover_id: String) -> bool:
    if cover_id == "":
        return false
    var c: Dictionary = GameData.covers.get(cover_id, {})
    return bool(c.get("fresh_water_source", false))

## Whether a hex is a direct source of the fresh water by its own terrain/cover.
## The rivers are NOT taken into account here: the river_edges — a separate source
## (see `_is_direct_water_source`), and an oasis can lie on a terrain of the
## sand/stone of a desert, which in itself does not give any fresh water.
static func _is_fresh_water_source_tile(tile: Dictionary) -> bool:
    if tile == null:
        return false
    if _is_fresh_water_source_terrain(tile.get("terrain", "")):
        return true
    if _is_fresh_water_source_cover(tile.get("cover", "none")):
        return true
    return false

## Whether the hex (row, col) is a DIRECT source of the fresh water:
## ONLY the hex with the water itself — a terrain/cover with
## fresh_water_source=true (a lake, an oasis) or a river (the river_edges on the
## common edges). No "neighbour of a canal", "neighbour of a lake", "the canal
## itself" — the transfer of the water in any direction goes through the chain-BFS
## and obeys the limit of the distance (irrigation/canals). This is the base for
## the scheme water_access: a source hex (a lake/an oasis/a river) gives "direct",
## everything else — "chain" or "".
static func _is_direct_water_source(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    if _is_fresh_water_source_tile(tile):
        return true
    if tile.get("river_edges", []).size() > 0:
        return true
    return false

## Checks whether the hex (row, col) is a neighbour of a direct fresh water source
## (a lake/an oasis): it has a neighbour with a terrain/cover that has
## `fresh_water_source: true`. Such a coastal hex is considered to have DIRECT
## access to the fresh water, regardless of the researched technologies.
static func _is_adjacent_to_fresh_water_source(
    row: int,
    col: int,
    tile_data: Array,
    map_rows: int,
    map_cols: int
) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    var neighbors_local = HexUtils.get_neighbors_odd_r(row, col, map_rows, map_cols)
    for n in neighbors_local:
        var neighbor_tile = tile_data[n.row][n.col]
        if neighbor_tile == null:
            continue
        if _is_fresh_water_source_tile(neighbor_tile):
            return true
    return false

## Whether a hex is a "conductor" of the fresh water: its improvement has
## conducts_water = true (a farm, a plantation), or it is a canal (is_canal), or it
## is the hex of the city to which the water has actually been brought. Such hexes
## are able to spread the water along a chain (the scheme water_access: chain).
static func _is_water_conductor(
    row: int,
    col: int,
    tile_data: Array,
    map_rows: int,
    map_cols: int
) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    # City hex conducts water like a canal when it has water.
    if bool(tile.get("is_city", false)):
        return true
    var imp_id = tile.get("improvement", null)
    if imp_id == null or imp_id == "":
        return false
    var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
    return bool(imp_data.get("conducts_water", false) or imp_data.get("is_canal", false))


## Returns the type of the access of the hex (row, col) to the fresh water:
##   - "direct" — a direct access: a hex with a terrain/cover that has
##                `fresh_water_source: true` (a lake/an oasis), a river by the
##                common edge, the canal itself (`is_canal: true` of the
##                improvement) or a neighbour of such a source/canal;
##   - "chain"  — an access through a chain of conductors (farms/plantations/canals),
##                which fires ONLY after the technology "Irrigation" has been
##                researched (tech_id: "irrigation");
##   - ""       — there is no access to the fresh water.
##
## THE RULES OF THE CHAIN: the water is passed ONLY between the conductors (the
## farms/plantations/canals). Every intermediate link of the chain must be a
## conductor, and the chain ends with a conductor that has a direct access to the
## water. The empty coastal hexes of the rivers and the lakes do NOT pass the
## water: a farm next to a river that touches no river edge and has no conductor
## neighbours does not get the bonus "by the chain".
## The function — the single source of truth for the bonuses of the fresh water,
## the tooltips and the drawing of the drops. The length of the chain is taken
## dynamically from tech_modifiers (see get_water_chain_length): "Irrigation" = 3,
## "Canals" = 4. Without the researched technologies the length = 0 and the chain
## does not work.
static func get_hex_water_access(
    row: int,
    col: int,
    tile_data: Array,
    map_rows: int,
    map_cols: int,
    phantom_conductor: bool = false
) -> String:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return ""
    var tile = tile_data[row][col]
    if tile == null:
        return ""

    # A direct access — only a hex with the water (a lake/an oasis/a river).
    if _is_direct_water_source(row, col, tile_data, map_rows, map_cols):
        return "direct"
    # A hex on the shore of a fresh water source has DIRECT access to the water
    # (without the technologies): a neighbour with a terrain/cover that has
    # `fresh_water_source: true`.
    if _is_adjacent_to_fresh_water_source(row, col, tile_data, map_rows, map_cols):
        return "direct"

    # The chain of the conductors: the length is taken from the modifiers of the
    # technologies (irrigation/canals). Without the researched "Irrigation" the
    # length = 0 and the chain does not work; phantom_conductor=true is used only
    # by the validation of the construction of a canal (the hex does not have an
    # improvement yet, but if a canal were built it would be considered a
    # conductor).
    var chain_length = get_water_chain_length()
    if chain_length <= 0:
        return ""
    # The starting hex is a candidate if it:
    #   - has a conductor improvement (farm/plantation/canal) — the usual case;
    #   - has phantom_conductor=true — the validation of the construction of a canal
    #     (the hex does not have an improvement yet, but if a canal were built it
    #     would be considered a conductor);
    #   - city hex is a conductor like a canal: passes water onward
    #     when water is actually supplied (a source reachable through it).
    var start_tile = tile_data[row][col]
    var start_is_candidate = phantom_conductor \
            or _is_water_conductor(row, col, tile_data, map_rows, map_cols) \
            or bool(start_tile.get("is_city", false))
    if not start_is_candidate:
        return ""

    var visited := {}
    var queue = [ {"row": row, "col": col, "dist": 0}]
    visited["%d_%d" % [row, col]] = true

    while queue.size() > 0:
        var item = queue.pop_front()
        var crow: int = item.row
        var ccol: int = item.col
        var dist: int = item.dist
        if dist >= chain_length:
            continue

        var neighbors_local = HexUtils.get_neighbors_odd_r(crow, ccol, map_rows, map_cols)
        for n in neighbors_local:
            var key = "%d_%d" % [n.row, n.col]
            if visited.has(key):
                continue
            var neighbor_tile = tile_data[n.row][n.col]
            if neighbor_tile == null:
                continue
            # A direct source — a terrain/cover with fresh_water_source=true
            # (a lake/an oasis) or a river by the COMMON edge (the river must flow
            # exactly along the boundary between the current hex and the neighbour;
            # a river on a "foreign" edge of the neighbour does not give the water
            # to the current hex).
            if _is_fresh_water_source_tile(neighbor_tile):
                return "chain"
            var n_edges: Array = neighbor_tile.get("river_edges", [])
            if n_edges.size() > 0:
                var shared_in_neighbor = get_shared_edge_index(n.row, n.col, crow, ccol)
                if shared_in_neighbor >= 0 and shared_in_neighbor in n_edges:
                    return "chain"
                # A river on another edge — is not a source for the current hex,
                # but the neighbour can still be a conductor (a farm/a canal/...).
                # City hex conducts water like a canal when it has water.
            if not _is_water_conductor(n.row, n.col, tile_data, map_rows, map_cols):
                continue
            visited[key] = true
            queue.append({"row": n.row, "col": n.col, "dist": dist + 1})
    return ""


## Checks whether the hex (row, col) is irrigated: it has any access to the fresh
## water — direct ("direct") or by a chain ("chain"). This is a wrapper over
## get_hex_water_access for the compatibility: all the previous calls (the
## production bonuses, the tooltips, the drawing) keep working.
static func is_hex_irrigated(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
    return get_hex_water_access(row, col, tile_data, map_rows, map_cols) != ""

## Returns the name of the icon of the landscape for the hex (row, col) on the
## basis of its terrain.
## It uses a deterministic RNG (seed = row * 1000 + col) for the stability between
## the saves/loads.
static func get_terrain_icon(row: int, col: int, tile_data: Array) -> String:
    var tile = tile_data[row][col]
    var terrain_id: String = tile.get("terrain", "plain")
    if not GameData.terrains.has(terrain_id):
        return ""
    var t: Dictionary = GameData.terrains[terrain_id]
    if t.has("icons"):
        var icons_array: Array = t.icons
        if icons_array.size() > 0:
            var icon_rng = RandomNumberGenerator.new()
            icon_rng.seed = row * 1000 + col
            var idx = icon_rng.randi() % icons_array.size()
            return icons_array[idx]
    elif t.has("icon"):
        return t.icon
    return ""


## Returns the "effective" resource of a hex: either a natural resource
## (tile.resource, set by the generator of the map or by a spawn of a technology),
## or a bred one (tile.crop_bred, set when a pasture/farm/apiary is built on an
## empty hex). If both fields are empty — it returns an empty string.
##
## It is used all over the game: the production, the tooltips, the drawing, the
## progress bars of the research, the inheritance of the quality. These subsystems
## must "not know" whether the resource on the hex is a natural one or a bred one
## — they only need the id.
static func get_effective_resource(tile: Dictionary) -> String:
    var r = tile.get("resource", null)
    if r != null and r != "":
        return r
    var b = tile.get("crop_bred", null)
    if b != null and b != "":
        return b
    return ""

## --- The breeding of the domesticated species (the scheme crop_bred) ---
## NOT all the domesticated species can be bred: the water resources (the fish and
## the like) live only in their own bodies of water — the field tile.crop_bred is
## not used for them.
## The possibility of breeding is set in the JSON of the resource
## (data/resources/*.json) by the field breedable; when the field is absent it is
## considered true. The check is needed in all the places where the options of
## breeding on an empty hex are formed (a pasture/farm).
static func can_breed_resource(res_id: String) -> bool:
    var raw = GameData.raw_resources.get(res_id, {})
    return bool(raw.get("breedable", true))

## The value of a breeding condition can be one string or an array of strings.
## For a string the equality is checked; for an array — the presence of the actual
## value of the hex. The other types and the empty arrays do not match.
static func _breeding_value_matches(actual: String, expected: Variant) -> bool:
    if expected is String:
        return actual == expected
    if expected is Array:
        for value in expected:
            if value is String and actual == value:
                return true
    return false

## Checks whether the resource res_id can be bred on a particular hex.
## The base places of breeding are set by the pairs allowed_terrain/allowed_cover.
## The optional field breeding adds the additional groups of conditions: the outer
## array is combined with OR, the conditions inside a group — with AND. The
## conditions with terrain and/or cover are checked as strings or arrays of
## strings; an empty, unknown or incorrect group does not allow breeding. The
## breedable has the priority: even a resource that fits breeding with
## breedable=false cannot be bred.
static func can_breed_resource_on_tile(res_id: String, tile: Dictionary) -> bool:
    if not can_breed_resource(res_id):
        return false

    var raw: Dictionary = GameData.raw_resources.get(res_id, {})
    if raw.is_empty():
        return false

    var terrain_id: String = str(tile.get("terrain", ""))
    var cover_id: String = str(tile.get("cover", "none"))
    var allowed_terrain: Variant = raw.get("allowed_terrain", [])
    var allowed_cover: Variant = raw.get("allowed_cover", [])
    if allowed_terrain is Array and allowed_cover is Array \
            and terrain_id in allowed_terrain and cover_id in allowed_cover:
        return true

    var breeding_value: Variant = raw.get("breeding", [])
    if not (breeding_value is Array):
        return false
    var breeding_groups: Array = breeding_value
    for group in breeding_groups:
        if not (group is Array) or group.is_empty():
            continue

        var group_met := true
        for condition in group:
            if not (condition is Dictionary):
                group_met = false
                break

            var has_supported_condition := false
            for key in condition.keys():
                if key != "terrain" and key != "cover":
                    group_met = false
                    break
            if not group_met:
                break

            if condition.has("terrain"):
                has_supported_condition = true
                if not _breeding_value_matches(terrain_id, condition.get("terrain")):
                    group_met = false
                    break
            if condition.has("cover"):
                has_supported_condition = true
                if not _breeding_value_matches(cover_id, condition.get("cover")):
                    group_met = false
                    break
            if not has_supported_condition:
                group_met = false
                break

        if group_met:
            return true
    return false

## Returns the improvement through which a resource can be bred on an empty hex.
## It uses the same improvement as for its natural resource.
static func get_breeding_improvement(res_id: String) -> String:
    var raw: Dictionary = GameData.raw_resources.get(res_id, {})
    var improved_by = raw.get("improved_by", null)
    if improved_by != null and improved_by != "":
        return str(improved_by)
    return ""

static func can_breed_resource_by(res_id: String, improvement_id: String) -> bool:
    return can_breed_resource(res_id) and get_breeding_improvement(res_id) == improvement_id

## --- The fullness of the livestock (time_to_mature) ---
## The resources with time_to_mature > 0 (the animals on the pastures) reach the
## full population gradually. While the herd is not full, the yield of the resource
## is proportional to the degree of the fullness. The accumulated time is stored in
## tile.fill_time (sec).

## Returns true if the resource res_data is a "growing" one (it has time_to_mature > 0).
static func is_growing_resource(res_data: Dictionary) -> bool:
    return float(res_data.get("time_to_mature", 0)) > 0.0


## The degree of the fullness of the herd: tile.fill_time / time_to_mature, clamped
## to [0, 1].
## For the ordinary (not growing) resources it is always 1.0 — the yield is not cut.
static func get_fill_fraction(tile: Dictionary, res_data: Dictionary) -> float:
    var ttm = float(res_data.get("time_to_mature", 0))
    if ttm <= 0.0:
        return 1.0
    return clampf(float(tile.get("fill_time", 0.0)) / ttm, 0.0, 1.0)


## How many seconds are left until the full population (0 — if it is already full).
static func get_time_to_full(tile: Dictionary, res_data: Dictionary) -> float:
    var ttm = float(res_data.get("time_to_mature", 0))
    if ttm <= 0.0:
        return 0.0
    return maxf(0.0, ttm - float(tile.get("fill_time", 0.0)))


## Looks on the map for an already domesticated instance of the resource res_id (a hex with this resource

## Looks on the map for an already domesticated instance of the resource res_id (a
## hex with this resource and a built improvement) and returns its quality.
## The search goes through both fields — tile.resource (a natural one) and
## tile.crop_bred (a bred one): any hex where the required resource is already
## processed by an improvement is considered domesticated.
## If there is none — it returns an empty string.
static func find_domesticated_quality(
    res_id: String,
    tile_data: Array,
    region_start_row: int,
    region_end_row: int,
    region_start_col: int,
    region_end_col: int
) -> String:
    for r in range(region_start_row, region_end_row + 1):
        for c in range(region_start_col, region_end_col + 1):
            var t = tile_data[r][c]
            if t.get("improvement") == null:
                continue
            var matches := false
            if t.get("resource", null) == res_id:
                matches = true
            elif t.get("crop_bred", null) == res_id:
                matches = true
            if not matches:
                continue
            var q = t.get("quality", "")
            if q != "" and q != null:
                return q
    return ""


## Checks whether the resource on the hex tile is visible from the point of view of
## the player.
## It takes into account:
##   1) in_influence / is_explored — the hex is developed or explored;
##   2) the tech_reveal of the resource — if it is set and the technology has not
##      been researched, the resource is hidden even in a bought zone (see docs.md,
##      the section "tech_reveal").
## It returns true if the resource must be displayed on the map and in the tooltip.
## If there is nothing on the hex (eff_res == "") — it returns true according to
## the zone: the hex itself may be visible, and its "no resource" is a correct
## display.
static func is_resource_revealed(tile: Dictionary) -> bool:
    var eff_res = get_effective_resource(tile)
    if eff_res != "":
        var res_data: Dictionary = GameData.raw_resources.get(eff_res, {})
        var reveal_tech: String = res_data.get("tech_reveal", "")
        if reveal_tech != "" and not CityData.is_tech_unlocked(reveal_tech):
            return false
    if tile.get("in_influence", false):
        return true
    return tile.get("is_explored", false)


## Returns the information about the conflict "a tech_reveal resource under a foreign
## improvement" on the hex tile, or {} if there is no conflict.
##
## The conflict exists if ALL the conditions are met:
##   - there is an IMPROVEMENT on the hex;
##   - there is a natural resource with a tech_reveal on the hex, whose technology
##     has already been researched;
##   - the standing improvement does NOT correspond to the improved_by of this
##     resource.
## The wild ones (improved_by == null) and the already correct improvements (a
## mine on an ore) are not considered a conflict.
##
## It is used in map_renderer for drawing the red triangle with a "!" and in
## map_tooltip for the corresponding message. A single source of truth.
##
## The format of the result:
##   { "res_id": ..., "res_name": ..., "improved_by": ..., "imp_name": ... }
static func get_tech_reveal_conflict(tile: Dictionary) -> Dictionary:
    if tile.get("improvement", null) == null:
        return {}
    var natural_res = tile.get("resource", null)
    if natural_res == null or natural_res == "":
        return {}
    var res_data: Dictionary = GameData.raw_resources.get(natural_res, {})
    if res_data.is_empty():
        return {}
    var reveal_tech: String = res_data.get("tech_reveal", "")
    if reveal_tech == "" or not CityData.is_tech_unlocked(reveal_tech):
        return {}
    var expected_imp: String = res_data.get("improved_by", "")
    if expected_imp == null or expected_imp == "":
        return {}
    if tile.get("improvement") == expected_imp:
        return {}
    var imp_name: String = GameData.improvements.get(expected_imp, {}).get("name", expected_imp)
    return {
        "res_id": natural_res,
        "res_name": res_data.get("name", natural_res),
        "improved_by": expected_imp,
        "imp_name": imp_name
    }


## Guarantees that the city is on an allowed terrain (a plain or the hills).
## If the city was generated/loaded on a mountain, a lake, the sea or a beach — it
## is changed to a plain.
static func ensure_city_valid_terrain(
    tile_data: Array,
    city_row: int,
    city_col: int,
    map_rows: int,
    map_cols: int
) -> void:
    if city_row < 0 or city_row >= map_rows or city_col < 0 or city_col >= map_cols:
        return
    var city_tile = tile_data[city_row][city_col]
    var current_terrain: String = city_tile.get("terrain", "plain")
    var allowed_terrains: Array[String] = ["plain", "hill"]
    if current_terrain not in allowed_terrains:
        city_tile["terrain"] = "plain"
        city_tile["cover"] = "none"
        city_tile["_is_sea"] = false
        city_tile["_is_beach"] = false
        city_tile["_is_marsh"] = false

## The hit test: which hex (row, col) is under the pixel coordinates (mx, my).
## It iterates only the visible window (the Ring + the Region) for the performance.
static func pixel_to_hex(
    mx: float, my: float,
    region_start_row: int, region_end_row: int,
    region_start_col: int, region_end_col: int,
    offset_x: float, offset_y: float,
    scroll_offset: Vector2,
    hex_radius: float
):
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var center = HexUtils.hex_center(row, col, hex_radius)
            center.x += offset_x + scroll_offset.x
            center.y += offset_y + scroll_offset.y
            var verts = HexUtils.hex_vertices(center.x, center.y, hex_radius)
            if HexUtils.point_in_polygon(mx, my, verts):
                return {"row": row, "col": col}
    return null

## Returns the id of the improvement that can be built on the hex, or an empty
## string if the construction is impossible.
static func get_buildable_improvement(tile: Dictionary) -> String:
    if tile.improvement != null:
        return ""

    # A hidden resource (the tech_reveal is not researched): no hint about the
    # construction — otherwise the player would learn that there is something on the
    # hex.
    if tile.resource != null and not is_resource_revealed(tile):
        return ""

    if tile.resource != null:
        var raw: Dictionary = GameData.raw_resources.get(tile.resource, {})
        if "improved_by" in raw and raw.improved_by != null and raw.improved_by != "":
            var imp_id: String = raw.improved_by
            if CityData.is_improvement_unlocked(imp_id):
                return imp_id
        return ""

    # An empty hex: the improvement for breeding a domesticated species.
    var domesticated_ids: Array = CityData.domesticated_resources.duplicate()
    for res_id in domesticated_ids:
        if not can_breed_resource_on_tile(res_id, tile):
            continue
        var improvement_id = get_breeding_improvement(res_id)
        if improvement_id != "" and CityData.is_improvement_unlocked(improvement_id):
            return improvement_id
    return ""


## Builds the string of the description of a chunk after the scouting.
static func get_chunk_info(chunk: Array, tile_data: Array) -> String:
    var terrain_types := {}
    var cover_forests := false
    var resources := []
    for hex in chunk:
        var tile = tile_data[hex.row][hex.col]
        var terrain: String = tile.get("terrain", "plain")
        terrain_types[terrain] = terrain_types.get(terrain, 0) + 1
        var cover_id: String = tile.get("cover", "none")
        if cover_id != "none":
            cover_forests = true
        # The scouts do not recognise the tech_reveal resources until the
        # corresponding technology has been researched. This is a feature and not a
        # bug: a hidden ore under the hooves of a horse is normal if the player does
        # not know how to tell an ore from a stone yet.
        # is_resource_revealed takes both conditions into account (the zone +
        # tech_reveal).
        if is_resource_revealed(tile):
            var eff_res = get_effective_resource(tile)
            if eff_res != "":
                var res_name: String = GameData.raw_resources.get(eff_res, {}).get("name", eff_res)
                resources.append(res_name)

    var terrain_names: Array[String] = []
    for terrain_id in terrain_types.keys():
        terrain_names.append(GameData.terrains.get(terrain_id, {}).get("name", terrain_id))
    var terrain_str := ", ".join(terrain_names)
    if cover_forests:
        terrain_str += TranslationServer.translate(", forest")
    # The type is given explicitly: tr() is not available in a static function, and
    # the compiler does not consider TranslationServer.translate() a String for
    # sure, so the output via := would give a Variant (in this project that is a
    # warning-as-error).
    var resource_str: String = ", ".join(resources) if resources.size() > 0 else TranslationServer.translate("none")
    return TranslationServer.translate("Terrain: %s. Resources: %s") % [terrain_str, resource_str]

## Recalculates the absolute borders of the Ring of Influence and of the visible
## window (the Ring + the Region) around the city.
static func recalculate_bounds(
    city_row: int, city_col: int,
    ring_rows: int, ring_cols: int,
    region_rows: int, region_cols: int,
    map_rows: int, map_cols: int
) -> Dictionary:
    var influence_start_row = city_row - ring_rows / 2
    var influence_end_row = influence_start_row + ring_rows - 1
    var influence_start_col = city_col - ring_cols / 2
    var influence_end_col = influence_start_col + ring_cols - 1

    var region_start_row = city_row - region_rows / 2
    var region_end_row = region_start_row + region_rows - 1
    var region_start_col = city_col - region_cols / 2
    var region_end_col = region_start_col + region_cols - 1

    region_start_row = max(0, region_start_row)
    region_end_row = min(map_rows - 1, region_end_row)
    region_start_col = max(0, region_start_col)
    region_end_col = min(map_cols - 1, region_end_col)

    return {
        "influence_start_row": influence_start_row,
        "influence_end_row": influence_end_row,
        "influence_start_col": influence_start_col,
        "influence_end_col": influence_end_col,
        "region_start_row": region_start_row,
        "region_end_row": region_end_row,
        "region_start_col": region_start_col,
        "region_end_col": region_end_col,
    }


## Calculates offset_x/offset_y for centering the visible window of the map in the
## viewport.
static func calc_offsets(
    region_start_row: int, region_end_row: int,
    region_start_col: int, region_end_col: int,
    hex_radius: float,
    viewport_size: Vector2
) -> Vector2:
    var min_x = INF
    var max_x = - INF
    var min_y = INF
    var max_y = - INF
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var center = HexUtils.hex_center(row, col, hex_radius)
            min_x = min(min_x, center.x - hex_radius)
            max_x = max(max_x, center.x + hex_radius)
            min_y = min(min_y, center.y - hex_radius)
            max_y = max(max_y, center.y + hex_radius)
    var grid_width = max_x - min_x
    var grid_height = max_y - min_y
    var offset_x = (viewport_size.x - grid_width) / 2.0 - min_x
    var offset_y = (viewport_size.y - grid_height) / 2.0 - min_y
    return Vector2(offset_x, offset_y)

## Guarantees the presence of at least one resource from food_plants in the given
## area. If there is none — it forcibly adds one on a suitable empty hex.
## city_row / city_col (optional) — the coordinates of the city: the hex of the city
## and its neighbours (3×3) are excluded from the search, so that the resource does
## not spawn on the city.
## This agrees with the exclusion in _build_hex_index / _place_resources.
static func ensure_food_plant(
    tile_data: Array,
    min_row: int, max_row: int,
    min_col: int, max_col: int,
    city_row: int = -1, city_col: int = -1
) -> void:
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if city_row >= 0 and abs(row - city_row) <= 1 and abs(col - city_col) <= 1:
                continue
            var res = tile_data[row][col]["resource"]
            if res != null:
                var res_data: Dictionary = GameData.raw_resources.get(res, {})
                if res_data.get("group") == "food_plants":
                    return
    var possible := []
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if city_row >= 0 and abs(row - city_row) <= 1 and abs(col - city_col) <= 1:
                continue
            if tile_data[row][col]["resource"] != null:
                continue
            var terrain: String = tile_data[row][col]["terrain"]
            var cover: String = tile_data[row][col].get("cover", "none")
            for res_id in GameData.raw_resources:
                var res: Dictionary = GameData.raw_resources[res_id]
                if res.get("group") != "food_plants":
                    continue
                if not (terrain in res.get("allowed_terrain", []) and cover in res.get("allowed_cover", [])):
                    continue
                var tech_required: String = res.get("tech_required", "")
                if tech_required != "" and not CityData.is_tech_unlocked(tech_required):
                    continue
                possible.append({"row": row, "col": col, "id": res_id})
    if possible.size() > 0:
        var chosen = possible[randi() % possible.size()]
        tile_data[chosen.row][chosen.col]["resource"] = chosen.id
        tile_data[chosen.row][chosen.col]["quality"] = GameData.roll_quality()


## Guarantees the presence of at least one resource that matches the filter in the
## given rectangular area (for example, the starting "Ring + Region").
##
## `filter` — a dictionary with the fields for the matching by the data of the
## resource (all the matches are checked for equality). The required field is
## `category`. The fields `group` and `subgroup` — the optional additional filters
## for the detailed categories (the bonuses for the variety). The fields
## `group`/`subgroup` of a resource can be both a string and an array of strings
## (several subgroups at once); the filter is considered matched if the required
## value is in the list. The examples:
##
##   { "category": "metals" }                                          — any metal
##   { "category": "animals", "group": "meat_animals" }                — the meat animals
##   { "category": "minerals", "subgroup": "construction_materials" }  — the building materials
##   { "category": "plants", "group": "food_plants" }                 — the food plants
##
## The behaviour:
##   1. If the area already has a resource that matches the filter — we return.
##   2. Otherwise we choose **one** random id among the available ones that match the
##      filter and the spawn_conditions (the chance and the geometry). Not every type
##      at once — otherwise the addition of the new metals/minables in the future
##      would turn into a mandatory spawn of all the suitable ones at once.
##   3. We spawn it on a suitable empty hex taking into account the allowed_terrain,
##      the allowed_cover and the geometric spawn_conditions.
##
## The parameters `min_row..max_row` / `min_col..max_col` — the inclusive borders.
## `city_row` / `city_col` — the coordinates of the city (the resource is not put on
## it).
static func ensure_minimum_resource(
    tile_data: Array,
    filter: Dictionary,
    min_row: int, max_row: int,
    min_col: int, max_col: int,
    city_row: int = -1, city_col: int = -1
) -> void:
    var required_category: String = filter.get("category", "")
    if required_category == "":
        # Without a category the filter is meaningless — we return without any action.
        return
    var required_group: String = filter.get("group", "")
    var required_subgroup: String = filter.get("subgroup", "")

    # Helper: do the data of the resource fit the filter? The fields group/subgroup of
    # a resource can be both a string and an array of strings (for example, the lapis
    # lazuli and the malachite belong at once to two subgroups) — we compare through a
    # list.
    var matches_filter = func(rdata: Dictionary) -> bool:
        if rdata.get("category", "") != required_category:
            return false
        if required_group != "" and required_group not in _as_string_list(rdata.get("group", "")):
            return false
        if required_subgroup != "" and required_subgroup not in _as_string_list(rdata.get("subgroup", "")):
            return false
        return true

    # 1. There is already a suitable resource in the area — we do nothing.
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if row < 0 or row >= tile_data.size():
                continue
            if col < 0 or col >= tile_data[row].size():
                continue
            var res = tile_data[row][col].get("resource", null)
            if res != null and GameData.raw_resources.has(res):
                if matches_filter.call(GameData.raw_resources[res]):
                    return

    # 2. We collect the ids of the resources that match the filter and the
    #    spawn_conditions.
    #    Availability = the chance in the spawn_conditions has fired.
    var candidates := []
    for res_id in GameData.raw_resources:
        var rdata: Dictionary = GameData.raw_resources[res_id]
        if not matches_filter.call(rdata):
            continue
        if not HexUtils.spawn_conditions_met(rdata):
            continue
        candidates.append(res_id)
    if candidates.is_empty():
        return
    var chosen_id: String = candidates[randi() % candidates.size()]
    var chosen_data: Dictionary = GameData.raw_resources[chosen_id]

    # 3. We look for a suitable empty hex within the borders.
    var allowed_terrain: Array = chosen_data.get("allowed_terrain", [])
    var allowed_cover: Array = chosen_data.get("allowed_cover", [])
    var possible := []
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if row < 0 or row >= tile_data.size():
                continue
            if col < 0 or col >= tile_data[row].size():
                continue
            if row == city_row and col == city_col:
                continue
            var t = tile_data[row][col]
            if t.get("resource", null) != null:
                continue
            if t.get("improvement", null) != null:
                continue
            var terrain_id: String = t.get("terrain", "plain")
            var cover_id: String = t.get("cover", "none")
            if not (terrain_id in allowed_terrain and cover_id in allowed_cover):
                continue
            # The geometric conditions of the spawn_conditions (for example, "by a river").
            if not HexUtils.is_hex_conditions_met(tile_data, row, col, chosen_data):
                continue
            possible.append({"row": row, "col": col})
    if possible.is_empty():
        return
    var hex = possible[randi() % possible.size()]
    tile_data[hex.row][hex.col]["resource"] = chosen_id
    tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()


## Normalizes the value of `group`/`subgroup` of a resource into a list of strings:
## a string -> [the string], an array -> as is (several subgroups), null/empty -> [].
static func _as_string_list(value) -> Array:
    if value is Array:
        return value
    if value == null:
        return []
    return [value]


## --- The water resources and the harbours (the scheme harbor_access) ---
##
## The water resources (the fresh water and the marine fish) are available for the
## exploitation ONLY after the improvement "Harbour" (harbor, see
## improvements.json, the flag water_body_harbor) is built on a coastal hex of a
## particular body of water. Each body of water (a connected area of the water of
## one type — a lake or the sea) requires ITS OWN harbour: the access is calculated
## by a flood-fill (BFS) over the water from the hex of the resource.

# The types of the terrain that are considered water for the scheme harbor_access.
const WATER_TERRAINS := ["lake", "sea"]

## Whether a type of the terrain is a water one (a lake/the sea).
static func is_water_terrain(terrain_id: String) -> bool:
    return terrain_id in WATER_TERRAINS

## Whether the hex (row, col) has a neighbour that is water (a lake/the sea). The
## hex itself can be any: checking the type of the hex is the concern of the calling
## code.
static func is_coastal_hex(tile_data: Array, row: int, col: int, map_rows: int, map_cols: int) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    for n in HexUtils.get_neighbors_odd_r(row, col, map_rows, map_cols):
        var nt = tile_data[n.row][n.col]
        if nt == null:
            continue
        if is_water_terrain(nt.get("terrain", "")):
            return true
    return false

## Whether the water resource on the hex (row, col) has an access to the harbour of
## ITS body of water.
## The logic: a BFS/flood-fill from the hex of the resource over the connected
## water hexes of the SAME type (a lake is not connected with the sea — they are
## different bodies of water). If among the neighbours of any visited water hex
## there is a land with a harbour improvement (water_body_harbor == true in
## improvements.json) — the path exists, the resource is available.
## It is calculated dynamically, without a cache: the demolition of a harbour closes
## the access at once, no invalidation of the state is required.
static func has_harbor_access(tile_data: Array, row: int, col: int, map_rows: int, map_cols: int) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    var start = tile_data[row][col]
    if start == null:
        return false
    var terrain_id: String = start.get("terrain", "")
    # We work only from the water hexes (the fish lies on a lake/the sea).
    if not is_water_terrain(terrain_id):
        return false

    var visited := {}
    var queue := [ {"row": row, "col": col}]
    visited[row * map_cols + col] = true
    while not queue.is_empty():
        var cur = queue.pop_front()
        for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, map_rows, map_cols):
            var key: int = n.row * map_cols + n.col
            if visited.has(key):
                continue
            var nt = tile_data[n.row][n.col]
            if nt == null:
                continue
            if is_water_terrain(nt.get("terrain", "")):
                # The same body of water continues — we go further only if the type
                # matches (we do not flow from a lake into the sea).
                if nt.get("terrain", "") == terrain_id:
                    visited[key] = true
                    queue.push_back(n)
                continue
            # Land: we check whether the harbour of this body of water stands on it.
            var imp_id = nt.get("improvement", null)
            if imp_id != null and imp_id != "":
                var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
                if bool(imp_data.get("water_body_harbor", false)):
                    return true
    return false
