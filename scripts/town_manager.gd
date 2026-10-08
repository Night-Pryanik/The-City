# town_manager.gd
# The manager of the towns (small settlements). At the start of the game it generates a given
# number of towns on random hexes near the points of attraction, so that
# they can be used for the trade later.
#
#
# --- The algorithm of the placement (cascade-refining, per the TZ) ---
# Five priorities (exactly in this order, from the top down):
#   1) multi_resource - "a pile of resources in the neighbourhood": the hex ITSELF has
#      MIN_RESOURCES_FOR_CLUSTER (2+) DIFFERENT resources in the radius of
#      MAX_ATTRACTION_DISTANCE (3 hexes); moreover, a resource within a radius of 3 from which
#      a town already stands does not participate in the count - the same
#      resource cluster does not attract several towns;
#   2) strategic - a strategic resource (resource.strategic == true) in the
#      radius of MAX_ATTRACTION_DISTANCE (3 hexes) from the hex of the town;
#   3) river - a hex along which a river flows (river_edges is non-empty);
#   4) lake_coast - a land hex adjacent to a lake (terrain == "lake");
#   5) sea_coast - a sea coast (terrain == "beach").
# The water priorities (a river / a lake / the sea) are strictly single hexes: a town
# by the water stands DIRECTLY on the river hex / the bank of the lake / the beach by the sea,
# and not "within 3 hexes of the water".
#
# --- The hard prerequisite: the land reachability from the city ---
# A town is placed ONLY on a hex which is reachable from the hex of the city of the player
# by land - without crossing water or an impassable terrain. This is not a "priority"
# of attractiveness, but a PREREQUISITE: an unreachable town cannot be connected with
# the city by a road (roads do not go over water - see MapHelpers.is_water_terrain), and
# without a road there is no trade (TownManager.is_trade_available requires road_linked).
# Therefore a hex on an island in the middle of the sea is NOT a valid place for a town,
# no matter how attractive its resources are.
# The reachable set is computed once per generate_towns (the city does not move during
# the generation) and is checked in _is_valid_town_hex; an empty mask = the check is
# disabled (the tests and the calls without a "starting point").
#
# STEP 0 - THE BASE. The priorities are iterated strictly from the top down, and for each
# a valid hex is searched over the WHOLE MAP (a full traversal, without a limit of the number of
# random attempts). The generator moves on to the next priority ONLY
# when there is not a single suitable hex for the current one left on the map.
# The first priority which gave a hex becomes the base one. Therefore the priorities are NOT
# equivalent: a town will not stand by a lake/the sea (a lower priority) while
# there is a single free place with a pile of resources on the map (an upper priority).
# If not a single priority gave not a single valid hex on the whole map -
# this town is not placed, we go to the next one.
#
# STEPS 1..N - THE REFINEMENT. Then we go down through the remaining priorities. At
# each step we try to IMPROVE the position: in the radius of REFINEMENT_RADIUS (2 hexes)
# from the current hex we search a hex which simultaneously satisfies ALL the already
# earned priorities AND the new one. Found - the town moves, the priority
# is added to the chain. Not found - the priority is SKIPPED, the position and the
# chain do not change, we go to the next priority (the cascade is not interrupted).
# In an ideal case the town occupies a hex with 2+ resources AND a strategic resource
# AND on a river AND on the bank of a lake/the sea - as far as the radius of the refinement allows.
#
# The check "a hex satisfies the priority" and "a hex satisfies all the
# already earned priorities AND the new one" goes by the MASKS of the priorities
# (a PackedByteArray of the size rows*cols) - see the block "The masks of the priorities" below.
#
# --- The secondary priority: the type of the terrain ---
# After the primary cascade the position is softly refined by the preference of the
# terrain: a plain/sand(beach) -> hills -> a marsh/swamp -> mountains. The primary
# attractions are preserved at the same time (the hex must satisfy all of them).
# If a suitable terrain was not found nearby - the town remains on the current
# valid hex.
#
# --- The restrictions on the hex of a town ---
#   - not water and not mountains/an impassable terrain;
#   - reachable from the hex of the city by land (see "the land reachability" above):
#     a town across water would never get a road, therefore it is not placed there;
#   - not a hex with a resource (including a strategic one): we are attracted to the resources, but
#     we stand nearby (in the radius of MAX_ATTRACTION_DISTANCE), and not on the resource itself;
#   - on a coastal beach by the sea - it is possible (the priority "a sea coast");
#   - not a hex of the city of the player;
#   - not a hex of another town and not closer than MIN_DISTANCE_BETWEEN_TOWNS, and
#     also not inside a foreign influence ring (the effective minimum =
#     max(MIN_DISTANCE_BETWEEN_TOWNS, influence_radius of the neighbour + 1));
#   - not inside the starting visible area (the Ring + the starting Region -
#     otherwise the town would be visible from the very beginning of the game);
#   - optionally: the hex must lie in the given "mandatory" area
#     (it is used for the guarantee "a town in era 2");
#   - there is still no construction on the hex.
#
# --- The starting area of the player (player_start_area) ---
# This is the same rectangle "the Ring + the starting Region", but the rule is stricter and
# concerns not only the CENTRE of the town, but the whole influence ring:
#   - the resources inside the area are not counted as the points of attraction
#     (_build_multi_resource_mask / _build_strategic_mask);
#   - every hex of the area is cut out of the influence ring
#     (compute_all_town_influences), therefore the territory of a town does not enter the starting
#     area of the player under ANY circumstances.
# The rule is the same for all the towns, including the guaranteed town of the 2nd era.
# --- The guarantee "at least 1 town in the area of the 2nd era" ---
# After the main pass we check whether there is at least one town in
# the era-2-visible area (the Ring_2 + the Region_2). If not - we try
# to place one additional town with the same restrictions, but
# with the "mandatory area" = the era-2-visible one. The exception of the starting area
# is preserved, so the new town falls into the new "strip" between
# era 1 and era 2 - that is, it appears for the player exactly on the transition to era 2.
# --- The configuration ---
#   data/map_config.json: "num_towns" - the target number of towns (moderately 8
#   for a map of 60x60). If 0 or negative - the towns are not generated.
# --- Save/load ---
# The list of the hexes is saved as [[row, col], ...] in SaveManager.saved_data["towns"]
# and is restored in main_map._ready (after the load of tile_data).
# In tile_data the hexes are marked with the flag has_town for the renderer and the control panel.
@tool
class_name TownManager
extends Node

# Emitted on every change of a town treasury, so that an open town window shows
# the balance immediately during a trade deal instead of waiting for a tick.
signal town_treasury_changed(town_id: String, treasury: int)
# Emitted when the warehouse of a town changes outside of the common tick — the
# trade deals write units off it and put them into it. The window of the town reads
# the signal and refreshes the quantities in the sale column.
signal town_storage_changed(town_id: String)
# The name of the file of the icon of a town. Per the TZ we use the same icon as the one of the city
# of the player (icons/city.png), but we draw it of a smaller size.
const TOWN_ICON_NAME := "city.png"
# The size of the icon of a town in the pixels. The city of the player is drawn 130, a town is
# smaller, so as not to compete visually with the city.
const TOWN_ICON_SIZE := 60
# The transparency of the icon of a town beyond the visible Region (the fog of war).
# The player must see "that something is there", but without the details.
const FOG_TOWN_ICON_ALPHA := 0.55
# The maximum distance from the point of attraction to the hex of a town (in the hexes).
const MAX_ATTRACTION_DISTANCE := 3
# The minimum number of DIFFERENT resources in the radius of MAX_ATTRACTION_DISTANCE from a hex,
# at which the hex is considered attractive for the priority "multi_resource"
# (2+ different resources = "a pile of resources in the neighbourhood").
const MIN_RESOURCES_FOR_CLUSTER := 2
# The secondary priority: a refinement by the types of the terrain (in the order of the decreasing attractiveness of the type of the terrain).
# The primary priorities (the resources / the river / the lake / the sea) remain MANDATORY;
# the type of the terrain is a soft refinement on top of them: after the main cascade
# we try to move to a hex with a more preferable terrain, without losing
# the already earned primary attractions.
const TERRAIN_PREFERENCE: Array = [
    ["plain", "beach"],
    ["hill"],
    ["rocky_desert"],
    ["swamp", "marsh"],
    ["sandy_desert", "mountain"],
]
# The radius of the search in the "refinement" of the position by the next priority (in the hexes).
# The refinement is local: a hex is searched within REFINEMENT_RADIUS of the current position and
# must satisfy ALL the already earned priorities + the new one. A priority
# which could not be "pulled through" in this radius is skipped - the position does not
# change and the cascade goes to the next priority.
const REFINEMENT_RADIUS := 2
# The base minimum distance between two towns (a spread).
# The actual minimum in _is_valid_town_hex is the MAXIMUM of this constant and
# (influence_radius of the neighbour + 1): the centre of a new town must not fall
# into a foreign influence ring.
const MIN_DISTANCE_BETWEEN_TOWNS := 3

# The terrains of the sea. A resource standing on one of them is a marine resource,
# and only such a resource makes the town build a harbour (see
# _place_town_sea_harbors): a lake with its own fish is a separate body of water
# and is not a reason for a harbour.
const SEA_TERRAINS := ["sea", "shallow_sea"]

# === The influence ring of a town ===
# Each town has an "influence ring" - a zone around itself, inside which
# the player cannot build anything. This reflects the fact that around a foreign
# settlement the land is actually "occupied" (fields, pastures, infrastructure).
# The rules:
# The rules:
#   1. The base disk: all the hexes at a distance of 0..INFLUENCE_MAX_RADIUS from the town.
#   2. The asymmetry: so that the ring does not look like a perfect circle, in one
#      random "side" (of 6) we drop 1-3 hexes at a distance of 3
#      (we form a "notch"). The side and the set of the hexes are chosen deterministically
#      from the coordinates of the town - the same result between the loads.
#   3. If there is a resource within the radius of INFLUENCE_MAX_RADIUS - the ring IS OBLIGED
#      to include the hex with the resource AND the shortest path from the town to the resource.
#      Without this the "notch" of step 2 could surround a resource, leaving it
#      a tiny "enclave" of the available land in the middle of the forbidden zone.
#
# The ring is recalculated from town_hexes on the load of a save, therefore
# we do NOT save it separately in the save - the input data (the towns and the resources)
# are already there.
const INFLUENCE_MAX_RADIUS := 3
# The chance that the notch at a distance of 3 will really "eat" a hex on the
# chosen side. 0.6 - on average ~2 hexes fall out of the disk, which
# gives a noticeable, but not aggressive asymmetry.
const INFLUENCE_NOTCH_PROBABILITY := 0.6
# The maximum number of the hexes which can be dropped in the notch at a distance of 3.
# 3 - we "eat" almost a whole sector of 6 hexes at the edge.
const INFLUENCE_NOTCH_MAX_DROPS := 3

# ===== The data structure: the list of the towns =====
# The SINGLE source of truth about the towns is the array of the records `towns`. Each record
# is a Dictionary with the full data:
#   id                  - a unique stable id ("town_N");
#   row, col            - the coordinates of the hex-centre;
#   name                - the name (still empty, the generator of the names will appear later);
#   is_era2_guaranteed  - a reference mark "added for the guarantee of the visibility
#                         in era 2";
#   border_color        - [r, g, b, a] the colour of the borders of the ring (generated
#                         deterministically on the spawn and SAVED in the save);
#   influence_radius    - the radius of the influence ring (a number, and not a constant:
#                         the ring can grow/shrink for the different towns);
#   influence_hexes     - the PERSONAL ring of the town: an Array of {row, col};
#   sell_pool, buy_pool - the (future) trade pools: what the town sells and
#                         what it wants to buy;
#   treasury            - the coins of the town (an integer). The starting value is
#                         town_initial_treasury from data/game_balance.json; it is
#                         changed only via add_town_treasury / spend_town_treasury.
#   storage             - THE WAREHOUSE of the town: product id -> units currently on
#                         the stock (the numbers behind the sell_pool). Filled in by
#                         TownEconomy.refresh_town and changed only via
#                         add_town_goods / take_town_goods, so that the trade deals
#                         and the simulation tick write through one place.
#   quality             - the quality level of every product of the warehouse:
#                         product id -> quality id. A town NEVER holds mixed quality:
#                         the whole stock of a product carries exactly one level,
#                         taken from the resource on the map (the ring yields) or
#                         computed by the standard craft rule (the crafted goods).
#                         Filled in together with the pools (TownEconomy.refresh_town)
#                         and derived data: it is not restored from the save.
#   production          - the per-tick rate of the warehouse: product id -> units per
#                         tick of a town. It is recomputed from the ring together with
#                         the pools (TownEconomy.refresh_town) and is derived data:
#                         it is not restored from the save. It is the PRODUCTION PLAN
#                         (what the town is capable of making); the warehouse itself
#                         is moved by the daily trade (see below).
#   trade_signs         - the direction of the LAST trade of every product of the
#                         warehouse: product id -> (+1 buy / -1 sell / 0 none). It is
#                         the inertia input of the trade model (TownEconomy.tick_trade)
#                         and, unlike "production", it is REAL WORLD STATE: it must
#                         survive a save, otherwise a reload would flip the direction
#                         of the next trade.
#   trade_counter       - how many trade ticks this town has made. It seeds the town's
#                         trade RNG together with the town id, so a reload replays the
#                         same sequence rather than reshuffling the warehouse.
#   production_started  - whether the town has already started to produce (see
#                         _is_town_production_started). Until the player has seen the
#                         hex of the town, the warehouse does not fill on its own:
#                         otherwise it would already stand at the limit by the time
#                         the player comes to the town.
#
# The whole record is saved in the save (serialize_towns) and is restored
# from it (load_towns), therefore any future fields of a town are simply added
# to the dictionary without a change of the formats of the other entities.
var towns: Array = []
var _used_town_names: Dictionary = {}

# The derived lists - the flat mirrors of `towns` for the backward compatibility
# (the renderer and main_map). They are not edited directly, they are rebuilt from `towns`.
#   town_hexes            - an Array of {row, col};
#   town_influence_hexes  - a flat list of the hexes of the rings of ALL the towns.
var town_hexes: Array = []
var town_influence_hexes: Array = []

# The starting area of the player: the Influence Ring + the Region of the 1st era (the very same as
# what the player sees and builds in from the first second of the game). It is stored as
# {"start_row", "end_row", "start_col", "end_col"}; an empty dictionary - the area is
# not set (the tests, the calls without a restriction).
#
# This is TWO restrictions in one rectangle, and it is not a coincidence:
#   1) _is_valid_town_hex does not put the CENTRE of a town here (otherwise a foreign settlement
#      would be visible from the very beginning of the game);
#   2) compute_all_town_influences cuts out of the influence ring EVERY hex of this
#      area - the territory of a town must not enter the land of the player under
#      any circumstances.
# The area is filled ONCE at the generation (generate_towns) and on the load of a
# save (main_map before compute_all_town_influences) and does not change any more.
# Therefore the clip does not "freeze" the ring dead, as the clip by
# the growing Region did: with the growth of the Region on a change of the epoch, exactly that
# which already belongs to the player remains cut out. The rule is the same for all the towns,
# including the guaranteed town of the 2nd era.
var player_start_area: Dictionary = {}

# The land reachability from the city of the player: reachable_hexes[row * cols + col] == 1,
# if the hex can be reached from the hex of the city without crossing water or an impassable
# terrain. It is computed once per generate_towns (the city does not move) and works as a
# hard prerequisite for the place of a town: a town on an island in the middle of the sea
# could never be connected with the city by a road, and without a road there is no trade.
# An empty array = the check is disabled (the tests and the calls without a "starting point").
var reachable_hexes: PackedByteArray = []
# The dimensions of the map for which reachable_hexes was built. Kept next to the mask,
# so that a repeated generation on a map of another size does not return a stale mask.
var _reachable_rows := 0
var _reachable_cols := 0

# ===== The caches of the priority masks of the town placement =====
# The placement of a town iterates the priorities (multi_resource, strategic, river,
# lake_coast, sea_coast) and the previous implementation rebuilt ALL five masks on EVERY
# _try_place_one_town call - that is, once per town, over the WHOLE map. On a 60x60 map
# the multi_resource mask alone (~176k hex_distance calls) cost ~2.8 s of the ~3.1 s of
# the placement. The three water masks and the base of the two resource masks depend only
# on the terrain/cover/rivers of the map (they do not change during the placement), and
# the towns claim resources only in a small disk around themselves. So we build the
# immutable parts ONCE per generate_towns and then update the resource masks incrementally
# (only the hexes whose neighbourhood gained/lost a claimed resource).
#
# _tier_masks["river"/"lake_coast"/"sea_coast"] - built once, never change.
# _resource_radius  - per-hex Dictionary { resource_id -> count } of the resources within
#                     MAX_ATTRACTION_DISTANCE, EXCLUDING the starting area of the player.
#                     A town claims a resource hex -> the count of that resource is
#                     decremented in every hex whose radius contains it (see
#                     _claim_resource_hex_for_masks).
# _strategic_count - per-hex COUNTER of the strategic resources within
#                    MAX_ATTRACTION_DISTANCE (excluding the starting area of the player),
#                    kept incremental for the same reason as _resource_radius.
# _mask_rows/_mask_cols - the dimensions the caches were built for.
var _tier_masks: Dictionary = {}
var _resource_radius: Array = []
var _strategic_count: Array = []
var _mask_rows := 0
var _mask_cols := 0
# true while the caches above describe the CURRENT map and may be reused across
# consecutive _try_place_one_town calls. generate_towns sets it under its placement loop
# (and keeps the resource tables up to date incrementally); a direct call outside that loop
# (the tests, the debug tools) sees false and rebuilds the caches for its own map.
var _mask_cache_valid := false


# Builds the map of the land reachability from (start_row, start_col): a BFS over the hexes
# which can be walked through, with water and impassable terrains as the walls. The result is
# a PackedByteArray of the size rows*cols (1 = reachable), so that the check in
# _is_valid_town_hex is O(1), and the flood fill itself is done once for the whole generation.
func _build_reachable_mask(tile_data: Array, rows: int, cols: int,
        start_row: int, start_col: int) -> PackedByteArray:
    var reachable := PackedByteArray()
    reachable.resize(rows * cols)
    reachable.fill(0)
    if rows <= 0 or cols <= 0:
        return reachable
    if start_row < 0 or start_row >= rows or start_col < 0 or start_col >= cols:
        return reachable
    var start_tile = tile_data[start_row][start_col]
    if start_tile == null or not _is_land_passable(start_tile):
        return reachable

    reachable[start_row * cols + start_col] = 1
    var queue: Array = [Vector2i(start_row, start_col)]
    var head := 0
    while head < queue.size():
        var cur: Vector2i = queue[head]
        head += 1
        for n in HexUtils.get_neighbors_odd_r(cur.x, cur.y, rows, cols):
            var idx: int = int(n.row) * cols + int(n.col)
            if reachable[idx] == 1:
                continue
            var tile = tile_data[n.row][n.col]
            if tile == null or not _is_land_passable(tile):
                continue
            reachable[idx] = 1
            queue.append(Vector2i(int(n.row), int(n.col)))
    return reachable


# A hex over which a road can physically pass: not water and not an impassable terrain.
# A town on such a hex can be connected with the city by a road; a town beyond water cannot.
func _is_land_passable(tile) -> bool:
    if tile == null:
        return false
    var terrain: String = str(tile.get("terrain", "plain"))
    if MapHelpers.is_water_terrain(terrain):
        return false
    return not _is_impassable_terrain(terrain)


# Is the hex reachable from the city by land. An empty reachable_hexes = the check is
# disabled (the tests and the calls without a "starting point").
func _is_reachable_hex(row: int, col: int) -> bool:
    if reachable_hexes.is_empty():
        return true
    if row < 0 or row >= _reachable_rows or col < 0 or col >= _reachable_cols:
        return false
    return reachable_hexes[row * _reachable_cols + col] == 1


# Sets the map of the land reachability for the current generation. An empty mask
# (the city stands on water/an impassable hex, or the map is empty) disables the check:
# "not a single hex is reachable" is indistinguishable from "the check is off", but the
# first situation means that the towns cannot trade with such a city anyway.
func _set_reachable(reachable: PackedByteArray, rows: int, cols: int) -> void:
    if reachable.is_empty():
        reachable_hexes = []
        _reachable_rows = 0
        _reachable_cols = 0
        return
    reachable_hexes = reachable
    _reachable_rows = rows
    _reachable_cols = cols


# Sets the starting area of the player. An empty rectangle (start > end) and any
# negative values disable the restriction - just as exclusion_* in
# generate_towns.
func set_player_start_area(start_row: int, end_row: int,
        start_col: int, end_col: int) -> void:
    if start_row < 0 or start_col < 0 or end_row < start_row or end_col < start_col:
        player_start_area = {}
        return
    player_start_area = {
        "start_row": start_row, "end_row": end_row,
        "start_col": start_col, "end_col": end_col,
    }


# Does the hex (row, col) lie in the starting area of the player.
func _is_in_player_start_area(row: int, col: int) -> bool:
    if player_start_area.is_empty():
        return false
    return row >= int(player_start_area["start_row"]) \
        and row <= int(player_start_area["end_row"]) \
        and col >= int(player_start_area["start_col"]) \
        and col <= int(player_start_area["end_col"])


# Creates a new record of a town with a unique name from city_names.json.
# The personal ring influence_hexes is filled by compute_all_town_influences().
func _make_town_record(town_index: int, row: int, col: int,
        is_era2_guaranteed: bool) -> Dictionary:
    return {
        "id": "town_%d" % town_index,
        "row": row,
        "col": col,
        "name": _take_unique_town_name(),
        "is_era2_guaranteed": is_era2_guaranteed,
        "border_color": _make_border_color(town_index),
        "influence_radius": INFLUENCE_MAX_RADIUS,
        "influence_hexes": [],
        "sell_pool": [],
        "buy_pool": [],
        "treasury": get_town_initial_treasury(),
        "storage": {},
        # The trade state: the last direction of every product (for inertia) and how
        # many trade ticks the town has made (for the RNG stream). Both are saved
        # with the record — see the field notes above the towns array.
        "trade_signs": {},
        "trade_counter": 0,
        "production_started": false,
    }


# The starting treasury of a town (data/game_balance.json, town_initial_treasury).
static func get_town_initial_treasury() -> int:
    return int(GameData.game_balance.get("town_initial_treasury", 1000))


func get_town_treasury(town: Dictionary) -> int:
    return int(town.get("treasury", 0))


# Credits coins to a town treasury (for example, the town sold goods to the city).
func add_town_treasury(town: Dictionary, amount: int) -> void:
    if amount <= 0:
        return
    town["treasury"] = get_town_treasury(town) + amount
    emit_signal("town_treasury_changed", str(town.get("id", "")), int(town["treasury"]))


# Writes coins off a town treasury (for example, the town bought goods from the city).
# A town cannot go into debt: if the coins are not enough, nothing is written off
# and false is returned.
func spend_town_treasury(town: Dictionary, amount: int) -> bool:
    if amount < 0:
        return false
    var current := get_town_treasury(town)
    if current < amount:
        return false
    if amount == 0:
        return true
    town["treasury"] = current - amount
    emit_signal("town_treasury_changed", str(town.get("id", "")), int(town["treasury"]))
    return true


# --- THE WAREHOUSE OF A TOWN ---

# How many units of a product the town has on the stock.
func get_town_goods(town: Dictionary, product_id: String) -> int:
    return int(town.get("storage", {}).get(product_id, 0))


# The quality level of a product in the warehouse of a town.
# A town never holds mixed quality, so a product has exactly one level; an unknown
# product falls back to the ordinary level, so the window never shows a row without
# stars (see the quality field of the town record).
static func get_town_goods_quality(town: Dictionary, product_id: String) -> String:
    var quality: Dictionary = town.get("quality", {})
    return str(quality.get(product_id, TownEconomy.DEFAULT_QUALITY))


# Puts units of a product onto the warehouse of a town (for example, the city has
# sold goods to it). The stock never exceeds the capacity of one product
# (town_storage_limit): the units that did not fit are discarded, and a deal that asks
# for more than the free space can physically store reports how much was accepted.
#
# The quality of the product is NOT taken from the deal: a town holds exactly one
# level of a product, that of the resource on the map (see the quality field of the
# town record), and a bought unit joins that level. The trade deals that would put
# goods into a town are not wired yet — when they are, they must not introduce a
# second level, or the "no mixed quality" rule breaks.
#
# It returns the number of the units actually stored.
func add_town_goods(town: Dictionary, product_id: String, amount: int) -> int:
    if product_id.is_empty() or amount <= 0:
        return 0
    var limit := TownEconomy.get_storage_limit()
    var storage: Dictionary = town.get("storage", {})
    var current := int(storage.get(product_id, 0))
    var stored := mini(amount, maxi(0, limit - current))
    if stored <= 0:
        return 0
    storage[product_id] = current + stored
    town["storage"] = storage
    emit_signal("town_storage_changed", str(town.get("id", "")))
    return stored


# Writes units of a product off the warehouse of a town (for example, the town has
# sold goods to the city). A town cannot sell what it does not have: if the stock is
# not enough, nothing is written off and false is returned.
func take_town_goods(town: Dictionary, product_id: String, amount: int) -> bool:
    if product_id.is_empty() or amount < 0:
        return false
    var storage: Dictionary = town.get("storage", {})
    var current := int(storage.get(product_id, 0))
    if current < amount:
        return false
    if amount == 0:
        return true
    storage[product_id] = current - amount
    town["storage"] = storage
    emit_signal("town_storage_changed", str(town.get("id", "")))
    return true


# The duration of ONE tick of the simulation of the towns: town_tick_ticks common
# ticks from data/game_balance.json (4 by default), so a town accumulates its
# production four times slower than the city does.
static func get_town_tick_seconds() -> float:
    var ticks := int(GameData.game_balance.get("town_tick_ticks", 4))
    return CityData.SIMULATION_TICK * float(maxi(1, ticks))


# Has the town already started to produce. A town fills its warehouse from the
# moment the player has seen its hex: an unrevealed town would accumulate for the
# whole game unseen and stand at the limit by the time the player arrives.
#
# "Seen" is the same condition under which the town is drawn on the map (see
# map_renderer): the hex is either in the known territory of the player, or it has
# been scouted. It is latched into the record, so that a town which has been
# discovered once keeps producing even if the flags of the hex change.
func _is_town_production_started(town: Dictionary, tile_data: Array) -> bool:
    if bool(town.get("production_started", false)):
        return true
    var row := int(town.get("row", -1))
    var col := int(town.get("col", -1))
    if row < 0 or col < 0 or row >= tile_data.size() or tile_data[row] == null:
        return false
    if col >= tile_data[row].size():
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    if not (bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false))):
        return false
    town["production_started"] = true
    return true


# ONE tick of the simulation of ALL the towns: every town that has been discovered
# makes one TRADE per product of its warehouse — the stock goes both up and down,
# like a real market (TownEconomy.tick_trade). A sale never takes more than the
# warehouse holds, so the stock cannot go negative or past the cap.
#
# The notification of the window is deliberately NOT emitted here. The towns trade
# every few seconds and most of them are not open, and the signal is emitted for
# every changed town on every tick; the window of a town reads the warehouse of its
# own record on opening and on a trade deal, and the sale column is refreshed by
# the caller (main_map) through town_ui.refresh_storage().
func tick_towns(tile_data: Array) -> void:
    if towns.is_empty():
        return
    var limit := TownEconomy.get_storage_limit()
    for town in towns:
        if not _is_town_production_started(town, tile_data):
            continue
        var storage: Dictionary = town.get("storage", {})
        if storage.is_empty():
            continue
        # The trade state is part of the record: the signs for the inertia and the
        # counter for the RNG stream. They are read, passed to the model and written
        # straight back, so a save taken at any moment resumes the same sequence.
        var signs: Dictionary = town.get("trade_signs", {})
        var counter := int(town.get("trade_counter", 0))
        counter = TownEconomy.tick_trade(storage, signs, counter,
                str(town.get("id", "")), limit)
        town["storage"] = storage
        town["trade_signs"] = signs
        town["trade_counter"] = counter


func _take_unique_town_name(preferred_name: String = "") -> String:
    if preferred_name != "" and not _used_town_names.has(preferred_name):
        _used_town_names[preferred_name] = true
        return preferred_name

    var available_names: Array = []
    for city_name in GameData.city_names:
        var candidate_name := str(city_name)
        if candidate_name != "" and not _used_town_names.has(candidate_name):
            available_names.append(candidate_name)
    if not available_names.is_empty():
        var selected_name: String = available_names[randi() % available_names.size()]
        _used_town_names[selected_name] = true
        return selected_name

    var fallback_index := towns.size() + 1
    var fallback_name := tr("Town %d") % fallback_index
    while _used_town_names.has(fallback_name):
        fallback_index += 1
        fallback_name = tr("Town %d") % fallback_index
    _used_town_names[fallback_name] = true
    return fallback_name


# The deterministic colour of the borders of a town by its index. The golden angle
# (phi-1 ~ 0.618) gives an even spread of the hues over the circle - so even the towns neighbouring
# by index look different. The colour is written into the record of the town
# and is saved in the save, therefore it will not "shift" if a town is removed/moved.
# We round the components: a 32-bit Color loses the precision on a JSON round-trip,
# and the values rounded to 3 decimals are serialized and restored
# bit-for-bit.
func _make_border_color(town_index: int) -> Array:
    var hue := fposmod(float(town_index) * 0.618033988749895, 1.0)
    var c := Color.from_hsv(hue, 0.85, 0.95, 1.0)
    return [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001), 1.0]


# Rebuilds the derived town_hexes from the master list towns.
func _rebuild_derived_town_hexes() -> void:
    town_hexes = []
    for t in towns:
        town_hexes.append({
            "row": int(t.row),
            "col": int(t.col),
            "is_era2_guaranteed": bool(t.get("is_era2_guaranteed", false)),
        })

# Returns the record of a town on the hex (row, col), or null if there is no town there.
# It is used by the control panel (the button of the transition to the interface of the town) and by
# main_map.open_town_ui (a double click on the hex of a town).
func find_town_at(row: int, col: int):
    for t in towns:
        if int(t.get("row", -1)) == row and int(t.get("col", -1)) == col:
            return t
    return null

# === The road requirement for the trade with a town (A STUB) ===
#
# The trade with the towns is not implemented yet: the window of a town (town_ui) only
# shows what it has for sale and for purchase, and opens ALWAYS,
# no matter what the roads are. The road does not block anything for now - its role is
# currently that the player sees: whether the town is connected (an icon over the hex) or not
# (a label in the window of the town).
#
# When the real trade appears, the requirement becomes a real one: the value of
# the constant changes to false (the trade without a road), or the function itself
# is rewritten under the real rules. The point of the removal of the stub is ONE:
# this function; everything that asks about the trade asks exactly it.
const TOWN_TRADE_REQUIRES_ROAD := true

# Is the trade with this town available.
func is_trade_available(town: Dictionary) -> bool:
    if not TOWN_TRADE_REQUIRES_ROAD:
        return true
    return bool(town.get("road_linked", false))


# Restores the list of the hexes of the ring from the format [[row, col], ...].
func _restore_hex_list(entries: Array) -> Array:
    var result: Array = []
    for e in entries:
        if e is Array and e.size() >= 2:
            result.append({"row": int(e[0]), "col": int(e[1])})
    return result


# Generates the towns. It is called from main_map._initialize_map AFTER
# the generation of the rivers (so that river_edges are already set in tile_data).
#
# The parameters:
#   tile_data            - a 2D array of the hexes.
#   rows, cols           - the dimensions of the map.
#   city_row, city_col   - the coordinates of the city of the player.
#
#   exclusion_start_row/col, exclusion_end_row/col - the zone INSIDE which
#                          the towns are NOT placed. This is the starting visible
#                          area (the Ring + the starting Region): otherwise
#                          the towns would be visible from the very beginning.
#
#   era2_region_start_row/col, era2_region_end_row/col - the borders of the visible
#                          area of the SECOND era (the Ring_2 + the Region_2).
#                          It is used as the "mandatory zone" for the
#                          guarantee of "at least 1 town in era 2".
func generate_towns(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        era2_region_start_row: int, era2_region_end_row: int,
        era2_region_start_col: int, era2_region_end_col: int) -> void:
    # We clear the previous state (in case of a repeated call) and
    # remove the flag has_town from all the hexes - a repeated generation must not
    # "accumulate" the old marks. We reset both the master list towns, and the
    # derived mirrors. NOTE: we use clear(), and not `=` - so that
    # the reference main_map.towns to this array is not broken on a repeated generation.
    towns.clear()
    _used_town_names.clear()
    if not CityData.city_name.is_empty():
        _used_town_names[CityData.city_name] = true
    town_hexes = []
    town_influence_hexes = []

    # We remember the starting area of the player: exclusion_* is exactly it
    # (the Ring + the starting Region). The area is needed not only for the ban on the CENTRE of a
    # town (this is done by _is_valid_town_hex), but also for two things during the
    # generation: the resources inside the area are not counted as the points of attraction
    # (see _build_multi_resource_mask / _build_strategic_mask), and it is cut out of the rings
    # of the influence (see compute_all_town_influences).
    set_player_start_area(exclusion_start_row, exclusion_end_row,
            exclusion_start_col, exclusion_end_col)

    # The hard prerequisite of the whole generation: the towns are placed only on the land
    # reachable from the city by a road. The city does not move, and the terrain does not
    # change during the generation, so the flood fill is done once for all the towns.
    _set_reachable(_build_reachable_mask(tile_data, rows, cols, city_row, city_col),
            rows, cols)

    # The immutable part of the priority masks (the water masks + the resource
    # neighbourhood tables) is built ONCE here, after player_start_area is set: the
    # resource masks exclude the starting area of the player, and they only change
    # incrementally while the towns are placed (see _claim_disk_resources).
    _build_tier_mask_caches(tile_data, rows, cols)

    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c] != null:
                tile_data[r][c]["has_town"] = false

    var num_towns: int = int(GameData.map_config.get("num_towns", 8))
    if num_towns <= 0:
        print("town_manager: num_towns=", num_towns, " — the towns are not generated")
        _mask_cache_valid = false
        return
    if rows < 3 or cols < 3:
        print("town_manager: the map is too small for the towns")
        _mask_cache_valid = false
        return

    # --- The main pass: we place num_towns towns by the cascade algorithm ---
    for _i in range(num_towns):
        var placed = _try_place_one_town(tile_data, rows, cols,
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                -1, -1, -1, -1, # without a "mandatory zone" on the main pass
                false)
        if placed.is_empty():
            print("town_manager: failed to place town #", towns.size() + 1,
                    " (no valid places in any of the priorities)")
            continue
        var new_town := _make_town_record(towns.size(), placed.row, placed.col, false)
        towns.append(new_town)
        town_hexes.append({"row": placed.row, "col": placed.col})
        tile_data[placed.row][placed.col]["has_town"] = true
        # The newly placed town claims the resources in its radius: they stop attracting
        # the next town. The update is incremental (see _build_tier_mask_caches).
        _claim_disk_resources(tile_data, rows, cols, placed.row, placed.col)

    # --- The guarantee ">=1 town in the area of the 2nd era" ---
    # If among the placed towns there is not a single one in the era-2 area, we make
    # one more attempt - we place a "guaranteed" town with the "mandatory
    # zone" = the era-2 area. The exception of the starting area is preserved,
    # so the town falls into the new strip which is visible only in era 2.
    var has_era2_town := false
    for h in town_hexes:
        if h.row >= era2_region_start_row and h.row <= era2_region_end_row \
                and h.col >= era2_region_start_col and h.col <= era2_region_end_col:
            has_era2_town = true
            break
    if not has_era2_town:
        var forced = _try_place_one_town(tile_data, rows, cols,
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                era2_region_start_row, era2_region_end_row,
                era2_region_start_col, era2_region_end_col,
                false)
        if not forced.is_empty():
            # The flag is_era2_guaranteed - a reference metadata ("this town
            # was added specially for the guarantee of the visibility in era 2").
            # In compute_town_influence it is not used at the moment: the clip on
            # the starting Region is applied to ALL the towns equally.
            # The flag is saved in the save and in the record of the town in case of the future
            # mechanics which will need to distinguish the "ordinary" and the
            # "guaranteed" towns.
            var forced_town := _make_town_record(towns.size(), forced.row, forced.col, true)
            towns.append(forced_town)
            town_hexes.append({"row": forced.row, "col": forced.col, "is_era2_guaranteed": true})
            tile_data[forced.row][forced.col]["has_town"] = true
            _claim_disk_resources(tile_data, rows, cols, forced.row, forced.col)
            print("town_manager: the era-2 guarantee — a town was added at (",
                    forced.row, ",", forced.col, ")")
        else:
            print("town_manager: the era-2 guarantee is NOT fulfilled — there is no valid ",
                    "hex in the new strip (probably it is all water/impassable)")

    # The influence rings are built AFTER the placement of all the towns (including
    # the guaranteed one for era 2), because when iterating the resources within a radius of 3
    # from each town the final positions AND all the resources on the map are needed.
    # The borders of the current Region are NOT needed here: the ring is built entirely by
    # the radius, only the starting area of the player is cut out of it (which never
    # changes) and the rings of the neighbouring towns, and what of the ring is visible
    # to the player is decided by the renderer (the fog of war + the epoch).
    compute_all_town_influences(tile_data, rows, cols)

    # After the building of the rings we fill them with the decorative improvements. They
    # belong to the towns, do not require the workers and never participate in the
    # production of the player (see tile.decorative). The food fields are the only
    # exception in the sense of the trade: the sown crop falls into the pool of the sale
    # of the town, but it does not go to the warehouse of the player.
    _place_decorative_town_improvements(tile_data, rows, cols)

    print("town_manager: the total number of the placed towns=", town_hexes.size(),
            " (target=", num_towns, ")")
    # The caches described the map during the placement only: a later direct call (a debug
    # tool, a test) must not reuse them for another map.
    _mask_cache_valid = false


# Tries to place one town by the cascade-refining algorithm (per the TZ):
# STEP 0 - the base (the first from the top priority, for which there is a
# valid hex on the WHOLE map), STEPS 1..N - a local refinement by the lower priorities.
# Returns the coordinates {row, col}, or an empty dictionary {} if on the whole map
# not a single valid hex was found in any of the priorities.
#
# The parameter require_in_region_* sets the "mandatory zone" (for example,
# the era-2 area for the guaranteed town): if it is set, the final hex
# must lie inside it. If it is set as -1 - the restriction is disabled.
func _try_place_one_town(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool) -> Dictionary:
    # The caches of the priority masks must describe the map we are working with. Inside
    # generate_towns they are built once and kept up to date across the placements; a direct
    # call (the tests, the debug tools) finds them stale and rebuilds them for this map.
    if not _mask_cache_valid or _mask_rows != rows or _mask_cols != cols:
        _build_tier_mask_caches(tile_data, rows, cols)
        _mask_cache_valid = false
    # The masks of all the five priorities (see the block "The masks of the priorities" below):
    # mask[row * cols + col] == 1, if a hex satisfies this priority.
    # The water masks come from the cache built once in generate_towns (they do not change
    # during the placement); the two resource masks are read from the incrementally updated
    # neighbourhood tables (see _build_tier_mask_caches).
    var tiers: Array = [
        {"name": "multi_resource", "mask": _build_multi_resource_mask(tile_data, rows, cols)},
        {"name": "strategic", "mask": _build_strategic_mask(tile_data, rows, cols)},
        {"name": "river", "mask": _tier_masks["river"]},
        {"name": "lake_coast", "mask": _tier_masks["lake_coast"]},
        {"name": "sea_coast", "mask": _tier_masks["sea_coast"]},
    ]

    # STEP 0: the base. We iterate the priorities strictly from the top down and for each
    # we search a valid hex over the WHOLE map (a full traversal of the map). We move on to the next
    # priority ONLY when for the current one there is
    # not a single suitable hex left on the map, - therefore the priorities are not
    # equivalent: a town will not stand by a lake/the sea, while there is a
    # free place with a pile of resources on the map.
    var base_tier_idx := -1
    var best: Dictionary = {}
    for i in range(tiers.size()):
        var hex: Dictionary = _find_hex_in_mask(tile_data, rows, cols, tiers[i]["mask"],
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                require_in_region_start_row, require_in_region_end_row,
                require_in_region_start_col, require_in_region_end_col,
                ignore_exclusion)
        if not hex.is_empty():
            base_tier_idx = i
            best = hex
            break
    if base_tier_idx == -1:
        # On the whole map there is not a single valid hex in any of the priorities.
        return {}

    # STEPS 1..N: the cascade refinement. We go down through the remaining priorities.
    # At each step we search within the radius of REFINEMENT_RADIUS of the current hex a hex
    # which simultaneously satisfies ALL the already earned priorities
    # (their masks) AND the new one. Found - the town moves, the priority is added to the
    # chain. Not found - the priority is SKIPPED, the position and the chain do not
    # change, we go to the next one: the cascade is NOT interrupted by a failure.
    var satisfied_names: Array = [str(tiers[base_tier_idx]["name"])]
    var skipped_names: Array = []
    var required_masks: Array = [tiers[base_tier_idx]["mask"]]
    for tier_idx in range(base_tier_idx + 1, tiers.size()):
        var new_mask: PackedByteArray = tiers[tier_idx]["mask"]
        var refined: Dictionary = _find_hex_in_radius_satisfying(tile_data, rows, cols,
                best, REFINEMENT_RADIUS, required_masks + [new_mask],
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                require_in_region_start_row, require_in_region_end_row,
                require_in_region_start_col, require_in_region_end_col,
                ignore_exclusion)
        if refined.is_empty():
            skipped_names.append(str(tiers[tier_idx]["name"]))
            continue
        best = refined
        required_masks.append(new_mask)
        satisfied_names.append(str(tiers[tier_idx]["name"]))

    # --- The secondary priority: a refinement by the types of the terrain ---
    # The already earned priorities must be preserved: we search a hex with a more
    # preferable terrain which still satisfies ALL of them.
    # We iterate the groups in the order of the preference; if not a single one fits -
    # we stay on the current (valid) hex.
    var cur_terrain: String = tile_data[best.row][best.col].get("terrain", "")
    var terrain_label := ""
    for group in TERRAIN_PREFERENCE:
        if group.has(cur_terrain):
            terrain_label = str(group[0])
            break
        var moved: Dictionary = _find_hex_in_radius_satisfying(tile_data, rows, cols,
                best, REFINEMENT_RADIUS, required_masks,
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                require_in_region_start_row, require_in_region_end_row,
                require_in_region_start_col, require_in_region_end_col,
                ignore_exclusion,
                group)
        if not moved.is_empty():
            best = moved
            terrain_label = str(group[0])
            break

    print("town_manager: town (", best.row, ",", best.col, ") — the priorities: ",
            " + ".join(satisfied_names),
            "" if skipped_names.is_empty() else ("; skipped: " + ", ".join(skipped_names)),
            "" if terrain_label == "" else ("; terrain: " + terrain_label))
    return best


# Searches a valid hex of a town over the WHOLE map among the hexes marked in mask
# (the mask of a priority). This is the primary search ("the base"), it has no
# "near something" restrictions. Of all the suitable hexes a random one is returned
# (reservoir sampling: the memory of O(1), the full list of the candidates is not stored).
# Returns {row, col}, or {} if not a single place was found on the map.
func _find_hex_in_mask(tile_data: Array, rows: int, cols: int, mask: PackedByteArray,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool) -> Dictionary:
    var chosen: Dictionary = {}
    var found := 0
    for r in range(rows):
        for c in range(cols):
            if mask[r * cols + c] == 0:
                continue
            if not _is_valid_town_hex(tile_data, r, c, city_row, city_col,
                    exclusion_start_row, exclusion_end_row,
                    exclusion_start_col, exclusion_end_col,
                    require_in_region_start_row, require_in_region_end_row,
                    require_in_region_start_col, require_in_region_end_col,
                    ignore_exclusion):
                continue
            found += 1
            if randi() % found == 0:
                chosen = {"row": r, "col": c}
    return chosen


# Checks that the hex (row, col) satisfies ALL the passed masks
# of the priorities (that is, it lies in each of them) - this is the "AND" over the
# already earned priorities + the new one.
func _hex_satisfies_all_masks(masks: Array, cols: int, row: int, col: int) -> bool:
    var idx: int = row * cols + col
    for mask in masks:
        if mask[idx] == 0:
            return false
    return true


# Searches a valid hex of a town within the radius max_dist_from_near of near_hex. This is
# the step of the REFINEMENT, therefore the search is local: the hex must lie in ALL the masks
# from masks (the already earned priorities + the new one). allowed_terrains is a soft
# filter by the type of the terrain (an empty list = any). Of the suitable hexes
# a random one is returned (reservoir sampling). Returns {row, col}, or {}
# if nothing was found.
func _find_hex_in_radius_satisfying(tile_data: Array, rows: int, cols: int,
        near_hex: Dictionary, max_dist_from_near: int,
        masks: Array,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool,
        allowed_terrains: Array = []) -> Dictionary:
    var chosen: Dictionary = {}
    var found := 0
    var r_min: int = maxi(0, near_hex.row - max_dist_from_near)
    var r_max: int = mini(rows - 1, near_hex.row + max_dist_from_near)
    var c_min: int = maxi(0, near_hex.col - max_dist_from_near)
    var c_max: int = mini(cols - 1, near_hex.col + max_dist_from_near)
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if HexUtils.hex_distance(r, c, near_hex.row, near_hex.col) > max_dist_from_near:
                continue
            # The hex must satisfy all the already earned priorities AND the new one.
            if not _hex_satisfies_all_masks(masks, cols, r, c):
                continue
            # The secondary filter by the type of the terrain (an empty list = any).
            if not allowed_terrains.is_empty():
                var terr: String = tile_data[r][c].get("terrain", "")
                if not allowed_terrains.has(terr):
                    continue
            if not _is_valid_town_hex(tile_data, r, c, city_row, city_col,
                    exclusion_start_row, exclusion_end_row,
                    exclusion_start_col, exclusion_end_col,
                    require_in_region_start_row, require_in_region_end_row,
                    require_in_region_start_col, require_in_region_end_col,
                    ignore_exclusion):
                continue
            found += 1
            if randi() % found == 0:
                chosen = {"row": r, "col": c}
    return chosen


# Checks whether the hex (row, col) is suitable for the placement of a town.
# The arguments exclude_* are the rectangle "must not place" (the starting area);
# require_in_region_* is the rectangle "must lie in" (for
# the guarantee of era 2). If exclude is set as start>end - it is skipped.
# Similarly for require_in_region: -1 - the restriction is disabled.
# ignore_exclusion=true skips the check of exclude (for the emergency cases,
# it is not used at the moment, it is left "for the future").
#
# The land reachability from the city (reachable_hexes) is a HARD prerequisite and is NOT
# bypassed by ignore_exclusion: an unreachable town cannot be connected with the city by a road.
func _is_valid_town_hex(tile_data: Array, row: int, col: int,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool) -> bool:
    if row < 0 or row >= tile_data.size():
        return false
    if col < 0 or col >= tile_data[row].size():
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false

    # The hex of the city of the player - never.
    if row == city_row and col == city_col:
        return false

    var terrain: String = tile.get("terrain", "plain")
    # The impassable types of the terrain (the sea, the lakes, a soda/salt/asphalt
    # lake) - you will not place a town there.
    if _is_impassable_terrain(terrain):
        return false
# A beach is allowed: the priority "a sea coast" requires placing the town
# DIRECTLY on the coastal hex (terrain == "beach"), and not inland.

    # The hard prerequisite: the hex must be reachable from the city by land. An island
    # in the middle of the sea is attractive, but a road cannot be laid to it, and without
    # a road there is no trade; therefore such a hex is not a valid place for a town at all.
    if not _is_reachable_hex(row, col):
        return false

    # There is already a construction (from another system) - not allowed.
    if tile.get("improvement", null) != null:
        return false
    # A hex with a resource - not allowed: a town must not occupy a resource directly
    # (including a strategic one - we are attracted to it, but we stand NEARBY, in the radius of
    # MAX_ATTRACTION_DISTANCE, and not on the hex itself). Such a hex simply does not
    # fall into the set of the candidates (_find_hex_in_mask /
    # _find_hex_in_radius_satisfying); if there are no valid places left at all,
    # the priority is skipped (and for the base - a transition to the next priority).
    var res = tile.get("resource", null)
    if res != null and res != "":
        return false
    # A town already stands here (just in case - the flag could have remained).
    if tile.get("has_town", false):
        return false

    # The starting area (the Ring + the starting Region) - not allowed. Otherwise
    # the town would be visible from the very beginning, and the sense of "the small
    # unknown settlements on the edge" is lost.
    if not ignore_exclusion \
            and exclusion_start_row <= exclusion_end_row \
            and exclusion_start_col <= exclusion_end_col \
            and row >= exclusion_start_row and row <= exclusion_end_row \
            and col >= exclusion_start_col and col <= exclusion_end_col:
        return false

    # The mandatory zone (if it is set) - the hex must lie inside it.
    if require_in_region_start_row >= 0 and require_in_region_end_row >= 0 \
            and require_in_region_start_col >= 0 and require_in_region_end_col >= 0:
        if not (row >= require_in_region_start_row and row <= require_in_region_end_row \
                and col >= require_in_region_start_col and col <= require_in_region_end_col):
            return false

    # The centre of a new town must not fall into a foreign influence ring:
    # the minimum distance = the influence radius of the neighbour + 1. The base
    # spread MIN_DISTANCE_BETWEEN_TOWNS also remains in force -
    # we take the MAXIMUM of the two restrictions. We iterate towns (the master list
    # with influence_radius), and not the derived town_hexes: under the future
    # mechanics of the growth/shrinkage of the rings the rule will adjust automatically.
    for t in towns:
        var eff_min: int = maxi(MIN_DISTANCE_BETWEEN_TOWNS,
                int(t.get("influence_radius", INFLUENCE_MAX_RADIUS)) + 1)
        if HexUtils.hex_distance(row, col, int(t.row), int(t.col)) < eff_min:
            return false
    return true


func _is_impassable_terrain(terrain_id: String) -> bool:
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    return int(t.get("move_cost", 1)) >= 999


func _is_sea_terrain(terrain_id: String) -> bool:
    return terrain_id in SEA_TERRAINS

# The id of the sea body the hex (row, col) belongs to: the smallest cell index of
# the connected area of sea/shallow_sea. A single id lets us tell "these two coastal
# hexes stand on the same water" without comparing the sets of the hexes, and the
# flood-fill itself is remembered in body_cache (a cell -> id entry per sea hex), so
# a sea is watered through once per pass over the map and not once per town.
func _sea_body_id(tile_data: Array, rows: int, cols: int, row: int, col: int,
        body_cache: Dictionary) -> int:
    if row < 0 or row >= rows or col < 0 or col >= cols:
        return -1
    var first = tile_data[row][col]
    if first == null or not _is_sea_terrain(str(first.get("terrain", ""))):
        return -1
    var start_key := row * cols + col
    if body_cache.has(start_key):
        return int(body_cache[start_key])

    var cells: Array = [Vector2i(row, col)]
    var visited: Dictionary = {}
    visited[start_key] = true
    var body_id := start_key
    var head := 0
    while head < cells.size():
        var cur: Vector2i = cells[head]
        head += 1
        body_id = mini(body_id, cur.x * cols + cur.y)
        for n in HexUtils.get_neighbors_odd_r(cur.x, cur.y, rows, cols):
            var key: int = n.row * cols + n.col
            if visited.has(key):
                continue
            var nt = tile_data[n.row][n.col]
            if nt == null or not _is_sea_terrain(str(nt.get("terrain", ""))):
                continue
            visited[key] = true
            cells.append(Vector2i(n.row, n.col))
    for cell in cells:
        body_cache[cell.x * cols + cell.y] = body_id
    return body_id


# The closer hex to the centre of the town wins; the ties are broken by the
# coordinates, so that the same save always gives the same harbour.
func _is_better_harbor_hex(row: int, col: int, dist: int, best_hex: Dictionary) -> bool:
    if dist != int(best_hex.get("dist", -1)):
        return dist < int(best_hex.get("dist", -1))
    if row != int(best_hex.get("row", -1)):
        return row < int(best_hex.get("row", -1))
    return col < int(best_hex.get("col", -1))


# --- The harbours of the towns ---
#
# A town whose ring contains a marine resource (a resource on a sea hex) gets one
# harbour per connected sea body holding such a resource: the boats are stood on the
# resource itself by the improved_by pass, and the harbour is the mooring of the
# body of water they work. A ring with a sea but without marine resources gets
# nothing: there is nothing to catch, so there is nothing to moor.
#
# The harbour stands on a FREE coastal hex of the RING: no resource, no improvement,
# no bred culture, the land (not a mountain, not an impassable terrain) adjacent to
# that very body of water. A coast occupied by a resource or by an earlier
# improvement is not a place for the harbour - such a town simply stays without one.
#
# The pass is idempotent: a body which already has a harbour of THIS town in the ring
# is skipped, so the load of a save does not add a second one.
func _place_town_sea_harbors(tile_data: Array, rows: int, cols: int, town: Dictionary,
        candidates: Array, body_cache: Dictionary) -> void:
    if not GameData.improvements.has("harbor"):
        return

    # The bodies of water which hold a marine resource of the ring.
    var wanted: Dictionary = {}
    for h in town.get("influence_hexes", []):
        var row := int(h.get("row", -1))
        var col := int(h.get("col", -1))
        if row < 0 or row >= rows or col < 0 or col >= cols:
            continue
        var tile = tile_data[row][col]
        if tile == null or tile.get("resource", null) == null:
            continue
        if not _is_sea_terrain(str(tile.get("terrain", ""))):
            continue
        var body_id := _sea_body_id(tile_data, rows, cols, row, col, body_cache)
        if body_id >= 0:
            wanted[body_id] = true
    if wanted.is_empty():
        return

    # The bodies which this town has already moored at.
    for h in town.get("influence_hexes", []):
        var row := int(h.get("row", -1))
        var col := int(h.get("col", -1))
        if row < 0 or row >= rows or col < 0 or col >= cols:
            continue
        var tile = tile_data[row][col]
        if tile == null or str(tile.get("improvement", "")) != "harbor":
            continue
        for n in HexUtils.get_neighbors_odd_r(row, col, rows, cols):
            var nt = tile_data[n.row][n.col]
            if nt == null or not _is_sea_terrain(str(nt.get("terrain", ""))):
                continue
            wanted.erase(_sea_body_id(tile_data, rows, cols, n.row, n.col, body_cache))
    if wanted.is_empty():
        return

    # The best free coastal hex of the ring for every body still waiting for a harbour.
    var best: Dictionary = {}
    var town_row := int(town.get("row", -1))
    var town_col := int(town.get("col", -1))
    for candidate in candidates:
        var tile: Dictionary = candidate.tile
        if tile.get("improvement", null) != null or tile.get("resource", null) != null \
                or tile.get("crop_bred", null) != null:
            continue
        var terrain_id := str(tile.get("terrain", ""))
        if terrain_id == "mountain" or _is_sea_terrain(terrain_id) \
                or _is_impassable_terrain(terrain_id):
            continue
        var dist := HexUtils.hex_distance(candidate.row, candidate.col, town_row, town_col)
        for n in HexUtils.get_neighbors_odd_r(candidate.row, candidate.col, rows, cols):
            var nt = tile_data[n.row][n.col]
            if nt == null or not _is_sea_terrain(str(nt.get("terrain", ""))):
                continue
            var body_id := _sea_body_id(tile_data, rows, cols, n.row, n.col, body_cache)
            if not wanted.has(body_id):
                continue
            var prev = best.get(body_id, null)
            if prev == null or _is_better_harbor_hex(candidate.row, candidate.col, dist, prev):
                best[body_id] = {"row": candidate.row, "col": candidate.col,
                        "tile": tile, "dist": dist}

    for body_id in best:
        _set_decorative_improvement(best[body_id].tile, "harbor")


# Places the "fillers" of the world in the ring of the town. Such improvements are needed
# only for the appearance: they are not the buildings of the player, they do not receive the workers and
# they do not give the resources. For the resources the source of the improvement is taken exclusively from
# improved_by, therefore the addition of the new types of the resources does not require the edits.
#
# The harbours are the one exception from "any free hex will do": they need a coastal
# hex of the sea which holds the marine resources of the ring (see
# _place_town_sea_harbors), therefore they are placed BEFORE the passes below - a
# filler farm must not be able to take the only free hex of the coast.
#
# The EXCEPTION - the food fields of the town (see the block with the farms below). If in the ring
# there is not a single food plant, the decorative farms are sown with the domesticated
# crops - by their own one for each field, - and all of them fall into the pool of the sale.
# This does not give any production to the player (the prod cycle of main_map and worker_manager
# skip tile.decorative) - it is needed exactly for the sake of which all of this was conceived:
# so that the town looks and trades as a living one, and the player does not think "how do they not
# starve?".
func _place_decorative_town_improvements(tile_data: Array, rows: int, cols: int) -> void:
    # The sea bodies are flood-filled once for the whole pass, see _sea_body_id.
    var sea_body_cache: Dictionary = {}
    for town in towns:
        var candidates: Array = []
        for h in town.get("influence_hexes", []):
            var row := int(h.get("row", -1))
            var col := int(h.get("col", -1))
            if row < 0 or row >= rows or col < 0 or col >= cols:
                continue
            var tile: Dictionary = tile_data[row][col]
            if tile == null or bool(tile.get("has_town", false)):
                continue
            candidates.append({"row": row, "col": col, "tile": tile})

        _place_town_sea_harbors(tile_data, rows, cols, town, candidates, sea_body_cache)

        var has_food_plant := false
        # The filler farms - the improvements farm without a natural resource. A town
        # gets them because there are no food plants in the ring, and in total
        # it is 1-2 fields. We collect ALL such ones (both bare and already sown): they are
        # a sign that the pass over the ring has already been.
        var filler_farms: Array = []
        # The bare ones among them are those which are still without a crop. We sow them: both the
        # just placed ones, and those left from the previous passes (a party saved
        # before the food fields appeared). The already sown fields do not fall here,
        # therefore on the load of a save the town is not re-sown.
        var bare_farms: Array = []
        for candidate in candidates:
            var resource_id = candidate.tile.get("resource", null)
            var resource_data: Dictionary = GameData.raw_resources.get(str(resource_id), {})
            if resource_data.get("group", "") == "food_plants":
                has_food_plant = true
            if resource_id == null and str(candidate.tile.get("improvement", "")) == "farm":
                filler_farms.append(candidate.tile)
                var crop = candidate.tile.get("crop_bred", null)
                if crop == null or crop == "":
                    bare_farms.append(candidate.tile)
            var imp_id := str(resource_data.get("improved_by", ""))
            if imp_id != "" and GameData.improvements.has(imp_id) \
                    and candidate.tile.get("improvement", null) == null:
                _set_decorative_improvement(candidate.tile, imp_id)

        # If there are no food plants in the ring, we add 1-2
        # decorative farms on the free plains without a cover.
        if not has_food_plant:
            # ... but only ONCE per party. Its own fields are already there - it means,
            # the pass over the ring was earlier (for example, on the load of a save), and
            # we must not top up: otherwise every reload would add another two
            # farms, and the ring would gradually overgrow with them.
            if filler_farms.is_empty():
                var farm_candidates: Array = []
                for candidate in candidates:
                    var tile: Dictionary = candidate.tile
                    if tile.get("improvement", null) == null \
                            and tile.get("resource", null) == null \
                            and tile.get("terrain", "") == "plain" \
                            and tile.get("cover", "none") == "none":
                        farm_candidates.append(candidate)
                farm_candidates.shuffle()
                var farm_count: int = mini(2, farm_candidates.size())
                for i in range(farm_count):
                    _set_decorative_improvement(farm_candidates[i].tile, "farm")
                    bare_farms.append(farm_candidates[i].tile)
            # ... and we sow each one with ITS OWN crop. The bare farms are a showcase without
            # of the goods: the player sees the fields, and there is nothing to sell, and the question "how do they
            # not starve?" remains unanswered. Two different crops in a row are
            # a household, and not a one-kind wedge, and the town immediately has two goods
            # for sale instead of one.
            for tile in bare_farms:
                _seed_decorative_field(tile, _pick_town_field_crop(tile))

        # One decorative object on a forest cover and on a mountain/hill.
        var forest_done := false
        var quarry_done := false
        for candidate in candidates:
            var tile: Dictionary = candidate.tile
            if tile.get("improvement", null) != null:
                continue
            if not forest_done and float(GameData.covers.get(tile.get("cover", "none"), {}).get("wood_yield", 0)) > 0.0 \
                    and GameData.improvements.has("lumberjack_hut"):
                _set_decorative_improvement(tile, "lumberjack_hut")
                forest_done = true
            elif not quarry_done and tile.get("terrain", "") in ["mountain", "hill"] \
                    and GameData.improvements.has("quarry"):
                _set_decorative_improvement(tile, "quarry")
                quarry_done = true

    # We rebuild the trade pools AFTER the placement of the improvements: a part of the rings
    # has been replenished with the fields with a crop (tile.crop_bred), and a town which
    # has no resources left must get it for sale. Earlier the pool
    # was collected before this step, and the fields remained mute.
    #
    # The recalculation takes into account not only the resources of the hexes, but also what the town
    # is able to produce itself (scripts/town_economy.gd), therefore here it is
    # mandatory even where the improvements were not placed: the buy pools too
    # are counted from the whole ring.
    _refresh_sell_pools(tile_data)


func _set_decorative_improvement(tile: Dictionary, imp_id: String) -> void:
    tile["improvement"] = imp_id
    tile["decorative"] = true
    tile["crop_bred"] = null
    tile["fill_time"] = 0.0
    tile["production_fractional_remainder"] = 0.0
    tile["feed_fractional_remainder"] = 0.0


# Selects a random food crop which can be bred on the hex
# of the town. We take ONLY the group "food_plants": the wild plants (wild_food, the group
# "wild") do not fall here - they cannot be grown on a farm, they are gathered
# by a special action, and a "town which chews the wild plants" does not answer the question
# of the player about the hunger. The breedability is checked by exactly the same rule as at
# the construction of a farm by the player (MapHelpers.can_breed_resource_on_tile), therefore
# the crop always fits its hex, and the new fields in JSON will not have to be
# edited. An empty string - not a single kind fitted.
func _pick_town_field_crop(tile: Dictionary) -> String:
    var options: Array = []
    for res_id in GameData.raw_resources:
        var res_data: Dictionary = GameData.raw_resources[res_id]
        if res_data.get("group", "") != "food_plants":
            continue
        if MapHelpers.can_breed_resource_on_tile(str(res_id), tile):
            options.append(str(res_id))
    if options.is_empty():
        return ""
    return str(options[randi() % options.size()])


# Sows a decorative farm of the town with a domesticated food crop.
# The crop is chosen for EACH field separately (_pick_town_field_crop), so
# that two fields of a town are two different goods, and not a one-kind wedge.
#
# It is specifically crop_bred, and not resource: a farm on an empty hex is a breeding
# (the scheme crop_bred), and not a natural deposit. Thanks to this:
#   - on the hex one honestly sees "its own field", and not a found deposit;
#   - the crop falls into the pool of the sale of the town (refresh_sell_pools reads
#     the effective resource - the natural OR the bred one);
#   - the logic of the "natural" resources (the debugging, the purchase of the chunks, the tools by
#     the deposits) stays uninvolved with the fields of a foreign town.
# The quality is as at the breeding by the player: its own for each field. The already sown
# field is not re-sown.
func _seed_decorative_field(tile: Dictionary, crop_id: String) -> void:
    if tile == null or crop_id == "":
        return
    if str(tile.get("improvement", "")) != "farm":
        return
    if not MapHelpers.can_breed_resource_on_tile(crop_id, tile):
        return
    tile["crop_bred"] = crop_id
    if str(tile.get("quality", "")) == "":
        tile["quality"] = GameData.roll_quality()


# --- The masks of the priorities ---
# A mask is a PackedByteArray of the length rows*cols: mask[row * cols + col] == 1, if
# a hex satisfies the priority. The masks replace the lists of the "points of attraction":
# the step of the refinement ("a hex satisfies AND all the already earned priorities, AND
# the new one") becomes an AND over the masks at O(1) per hex, and the obligatory
# transition to the next priority - a traversal of the WHOLE map - becomes one linear
# pass, without a recalculation of the distances to the points of attraction.

func _new_tier_mask(rows: int, cols: int) -> PackedByteArray:
    var mask := PackedByteArray()
    mask.resize(rows * cols)
    mask.fill(0)
    return mask


# -------------------------------------------------------
# The caches of the priority masks (see the header of _tier_masks).
# -------------------------------------------------------

# Builds the immutable part of the masks ONCE per generate_towns: the three water masks
# (they depend only on the terrain/cover/rivers) and the per-hex resource neighbourhood
# tables (multi_resource: the count of the DISTINCT resources within MAX_ATTRACTION_DISTANCE,
# excluding the starting area of the player; strategic: how many strategic resources are
# within the same radius). The resource tables are then kept up to date incrementally by
# _claim_resource_hex_for_masks as the towns are placed.
func _build_tier_mask_caches(tile_data: Array, rows: int, cols: int) -> void:
    _mask_rows = rows
    _mask_cols = cols
    _mask_cache_valid = true
    _tier_masks = {
        "river": _build_river_mask(tile_data, rows, cols),
        "lake_coast": _build_lake_coast_mask(tile_data, rows, cols),
        "sea_coast": _build_sea_coast_mask(tile_data, rows, cols),
    }

    # The resource-neighbourhood tables. Instead of scanning the 7x7 window of every hex
    # (rows*cols*49 hex_distance calls), we stamp the influence of each RESOURCE hex into
    # its radius: the resources are sparse, therefore this is far cheaper.
    _resource_radius = []
    _resource_radius.resize(rows * cols)
    for i in range(rows * cols):
        _resource_radius[i] = null
    _strategic_count = []
    _strategic_count.resize(rows * cols)
    _strategic_count.fill(0)

    for r in range(rows):
        for c in range(cols):
            var tile = tile_data[r][c]
            if tile == null:
                continue
            var res = tile.get("resource", null)
            if res == null or res == "":
                continue
            if _is_in_player_start_area(r, c):
                continue
            var res_id := str(res)
            var is_strategic: bool = bool(GameData.raw_resources.get(res_id, {}).get("strategic", false))
            for nr in range(maxi(0, r - MAX_ATTRACTION_DISTANCE),
                    mini(rows - 1, r + MAX_ATTRACTION_DISTANCE) + 1):
                for nc in range(maxi(0, c - MAX_ATTRACTION_DISTANCE),
                        mini(cols - 1, c + MAX_ATTRACTION_DISTANCE) + 1):
                    if HexUtils.hex_distance(r, c, nr, nc) > MAX_ATTRACTION_DISTANCE:
                        continue
                    var idx: int = nr * cols + nc
                    var counts = _resource_radius[idx]
                    if counts == null:
                        counts = {}
                        _resource_radius[idx] = counts
                    counts[res_id] = int(counts.get(res_id, 0)) + 1
                    if is_strategic:
                        _strategic_count[idx] = int(_strategic_count[idx]) + 1


# Removes a resource hex from the neighbourhood tables when a town claims it: every hex
# within MAX_ATTRACTION_DISTANCE of the claimed resource loses one unit of that resource
# (and one unit of the strategic counter, if the resource is strategic). This is the
# incremental equivalent of the previous "rebuild the claimed mask and rescan everything".
func _claim_resource_hex_for_masks(tile_data: Array, res_row: int, res_col: int) -> void:
    var tile = tile_data[res_row][res_col]
    if tile == null:
        return
    var res = tile.get("resource", null)
    if res == null or res == "":
        return
    var res_id := str(res)
    var is_strategic: bool = bool(GameData.raw_resources.get(res_id, {}).get("strategic", false))
    var rows := _mask_rows
    var cols := _mask_cols
    for nr in range(maxi(0, res_row - MAX_ATTRACTION_DISTANCE),
            mini(rows - 1, res_row + MAX_ATTRACTION_DISTANCE) + 1):
        for nc in range(maxi(0, res_col - MAX_ATTRACTION_DISTANCE),
                mini(cols - 1, res_col + MAX_ATTRACTION_DISTANCE) + 1):
            if HexUtils.hex_distance(res_row, res_col, nr, nc) > MAX_ATTRACTION_DISTANCE:
                continue
            var idx: int = nr * cols + nc
            var counts = _resource_radius[idx]
            if counts != null and counts.has(res_id):
                var left: int = int(counts[res_id]) - 1
                if left <= 0:
                    counts.erase(res_id)
                else:
                    counts[res_id] = left
            if is_strategic and int(_strategic_count[idx]) > 0:
                _strategic_count[idx] = int(_strategic_count[idx]) - 1


# Marks a claimed disk around a newly placed town: every resource hex inside the disk is
# removed from the neighbourhood tables. This is the incremental replacement for rebuilding
# _build_claimed_resource_mask from the whole towns list on every placement.
func _claim_disk_resources(tile_data: Array, rows: int, cols: int, center_row: int, center_col: int) -> void:
    for r in range(maxi(0, center_row - MAX_ATTRACTION_DISTANCE),
            mini(rows - 1, center_row + MAX_ATTRACTION_DISTANCE) + 1):
        for c in range(maxi(0, center_col - MAX_ATTRACTION_DISTANCE),
                mini(cols - 1, center_col + MAX_ATTRACTION_DISTANCE) + 1):
            if HexUtils.hex_distance(r, c, center_row, center_col) > MAX_ATTRACTION_DISTANCE:
                continue
            _claim_resource_hex_for_masks(tile_data, r, c)


# Priority 1: "a pile of resources in the neighbourhood" - the hex ITSELF has
# MIN_RESOURCES_FOR_CLUSTER (2+) DIFFERENT resources in the radius of
# MAX_ATTRACTION_DISTANCE. Are not taken into account:
#   - the resources claimed by the towns (see _claim_disk_resources);
#   - the resources in the STARTING AREA OF THE PLAYER - it is already his, to attract a town
#     to it is meaningless: the ring will not be able to use it anyway
#     (see the cut out of the starting area in compute_all_town_influences).
#
# The per-hex tables were prepared once by _build_tier_mask_caches and are kept up to date
# incrementally, so here we only read the distinct-resource count of every hex.
#
# The builder is self-sufficient: if the cache does not describe (rows, cols) - for example
# when it is called directly, outside generate_towns - it is rebuilt first.
func _build_multi_resource_mask(tile_data: Array, rows: int, cols: int) -> PackedByteArray:
    if not _mask_cache_valid or _mask_rows != rows or _mask_cols != cols:
        _build_tier_mask_caches(tile_data, rows, cols)
        _mask_cache_valid = false
    var mask: PackedByteArray = _new_tier_mask(rows, cols)
    for r in range(rows):
        for c in range(cols):
            var counts = _resource_radius[r * cols + c]
            if counts != null and counts.size() >= MIN_RESOURCES_FOR_CLUSTER:
                mask[r * cols + c] = 1
    return mask


# Priority 2: a strategic resource (resource.strategic == true) in the radius of
# MAX_ATTRACTION_DISTANCE from the hex of the town. The resources claimed by the towns
# are not taken into account (see _claim_disk_resources) and the resources in the starting area
# of the player (see the explanation in _build_multi_resource_mask).
func _build_strategic_mask(tile_data: Array, rows: int, cols: int) -> PackedByteArray:
    if not _mask_cache_valid or _mask_rows != rows or _mask_cols != cols:
        _build_tier_mask_caches(tile_data, rows, cols)
        _mask_cache_valid = false
    var mask: PackedByteArray = _new_tier_mask(rows, cols)
    for i in range(rows * cols):
        if int(_strategic_count[i]) > 0:
            mask[i] = 1
    return mask


# Priority 3: the hexes through which the rivers flow (river_edges is non-empty).
# The water priorities are strictly single hexes (without a "radius of attraction"):
# a town by the water stands DIRECTLY on the river hex / the bank / the beach.
func _build_river_mask(tile_data: Array, rows: int, cols: int) -> PackedByteArray:
    var mask: PackedByteArray = _new_tier_mask(rows, cols)
    for r in range(rows):
        for c in range(cols):
            var edges: Array = tile_data[r][c].get("river_edges", [])
            if edges.size() > 0:
                mask[r * cols + c] = 1
    return mask


# Priority 4: the sea coast. The beach hexes are the land next to the sea
# (see SeaManager._apply_beach), exactly what we need.
func _build_sea_coast_mask(tile_data: Array, rows: int, cols: int) -> PackedByteArray:
    var mask: PackedByteArray = _new_tier_mask(rows, cols)
    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c].get("terrain", "") == "beach":
                mask[r * cols + c] = 1
    return mask


# Priority 5: the coast of the lakes. The lakes are surrounded by land, and we need exactly
# the land hexes which are adjacent to a lake.
func _build_lake_coast_mask(tile_data: Array, rows: int, cols: int) -> PackedByteArray:
    var mask: PackedByteArray = _new_tier_mask(rows, cols)
    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c].get("terrain", "") != "lake":
                continue
            for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                var n_tile = tile_data[n.row][n.col]
                if n_tile == null:
                    continue
                if n_tile.get("terrain", "") == "lake":
                    continue
                if _is_impassable_terrain(n_tile.get("terrain", "")):
                    continue
                mask[n.row * cols + n.col] = 1
    return mask


# --- Save/load ---
# The towns are serialized as an array of dictionaries - one record of towns per
# town. Thus ALL the data of a town goes into the save: id, name, colour of the borders,
# the radius and the personal ring of the influence, the trade pools. The dictionary is saved in JSON
# directly (for the colour we use an array [r,g,b,a]).
# Thanks to the full record the future fields of a town are added to serialize/load
# symmetrically, without a change of the formats of the other entities.

func serialize_towns() -> Array:
    var result: Array = []
    for t in towns:
        var hexes: Array = []
        for h in t.get("influence_hexes", []):
            hexes.append([int(h.row), int(h.col)])
        result.append({
            "id": str(t.get("id", "")),
            "row": int(t.row),
            "col": int(t.col),
            "name": str(t.get("name", "")),
            "is_era2_guaranteed": bool(t.get("is_era2_guaranteed", false)),
            "border_color": t.get("border_color", [1.0, 1.0, 1.0, 1.0]),
            "influence_radius": int(t.get("influence_radius", INFLUENCE_MAX_RADIUS)),
            "influence_hexes": hexes,
            "sell_pool": t.get("sell_pool", []),
            "buy_pool": t.get("buy_pool", []),
            "treasury": get_town_treasury(t),
            # The warehouse of the town. The per-tick rate ("production") is NOT
            # written into the save: it is derived from the ring of the town and is
            # recalculated on the load by compute_all_town_influences ->
            # _refresh_sell_pools, so it cannot go stale against the pools.
            "storage": t.get("storage", {}),
            # The trade state — REAL WORLD STATE, not derived: the last direction of
            # every product (the inertia input) and the town's trade counter (the RNG
            # stream). They must survive the save, otherwise a reload would flip the
            # next trade and reshuffle the warehouse.
            "trade_signs": t.get("trade_signs", {}),
            "trade_counter": int(t.get("trade_counter", 0)),
            "production_started": bool(t.get("production_started", false)),
            # road_linked - the player has built a road from the city to this town.
            # As with the other roads, the segments are not written into the save: by this
            # flag the connection is recalculated on the load (main_map._rebuild_town_roads
            # -> road_manager.rebuild_player_roads), and the availability of the trade
            # is read from it as well (is_trade_available).
            "road_linked": bool(t.get("road_linked", false)),
        })
    return result


# Restores towns from the save. Understands two formats:
#   - NEW: a dictionary of the record of a town (id, name, radius, personal ring, colour...);
#     the personal ring will be recalculated in compute_all_town_influences().
# If there is no data / the array is empty (a new game) - we do not touch towns (usually it is already
# filled by generate_towns, called from _initialize_map).
func load_towns(data) -> void:
    if data == null:
        return
    if not (data is Array):
        return
    if data.is_empty():
        return

    towns.clear()
    _used_town_names.clear()
    if not CityData.city_name.is_empty():
        _used_town_names[CityData.city_name] = true
    town_hexes = []
    town_influence_hexes = []
    for entry in data:
        if entry is Dictionary:
            # The new format: the full record of a town.
            var t := {
                "id": str(entry.get("id", "")),
                "row": int(entry.get("row", 0)),
                "col": int(entry.get("col", 0)),
                "name": _take_unique_town_name(str(entry.get("name", ""))),
                "is_era2_guaranteed": bool(entry.get("is_era2_guaranteed", false)),
                "border_color": entry.get("border_color", [1.0, 1.0, 1.0, 1.0]),
                "influence_radius": int(entry.get("influence_radius", INFLUENCE_MAX_RADIUS)),
                # The personal ring from the save is the source of truth for the loaded
                # party (the ring could have been changed by the mechanics).
                "influence_hexes": _restore_hex_list(entry.get("influence_hexes", [])),
                "sell_pool": entry.get("sell_pool", []),
                "buy_pool": entry.get("buy_pool", []),
                # Saves without a town treasury get the starting value, as in a new game.
                "treasury": int(entry.get("treasury", get_town_initial_treasury())),
                # The warehouse and the flag of the production (see serialize_towns).
                "storage": entry.get("storage", {}),
                # The trade state: the last direction of every product (the inertia
                # input) and the town's trade counter (the RNG stream). See
                # serialize_towns.
                "trade_signs": entry.get("trade_signs", {}),
                "trade_counter": int(entry.get("trade_counter", 0)),
                "production_started": bool(entry.get("production_started", false)),
                # road_linked is a road from the city to the town (see serialize_towns).
                "road_linked": bool(entry.get("road_linked", false)),
            }
            towns.append(t)
        elif entry is Array and entry.size() >= 2:
            # There is no ring - it will be computed in compute_all_town_influences.
            var is_era2_guaranteed: bool = entry.size() >= 3 and bool(entry[2])
            var t := _make_town_record(towns.size(), int(entry[0]), int(entry[1]),
                    is_era2_guaranteed)
            towns.append(t)
        else:
            printerr("town_manager: a broken record of a town in the save is skipped: ", entry)
    _rebuild_derived_town_hexes()
    print("town_manager: the number of the towns restored from the save=", towns.size())


# === The influence ring of a town ===

# Computes the influence ring for ALL the placed towns. It fills
# town_influence_hexes (the flat mirror) and the PERSONAL ring of each town
# (town["influence_hexes"]). It is called:
#   - from generate_towns after the placement of all the towns (including the guaranteed
#     one for era 2) - the start of a new game;
#   - from main_map on the load of a save - the rings are restored.
#
# The composition of the ring is ALWAYS recalculated from the radius of the town record
# (influence_radius) — it is the single source of its size.
# The flag in_town_influence is set on the tiles.
#
# The rings of the different towns do NOT intersect. The towns are processed in the order
# of the array towns (the order of the placement; for a save - the order of the records): a hex which has
# already fallen into the ring of an earlier town is excluded from the ring of the current one -
# the principle of "whoever stood first, has the priority". The "latecomer" town keeps
# a ring which is cut on the side of the neighbour. The cut composition of the ring is saved
# into the record of the town (and into the save), therefore a repeated recalculation is idempotent.
#
# THE CUT OUT BY THE STARTING AREA OF THE PLAYER (player_start_area = the Ring + the Region of the 1st
# era). The rule is strict: the territory of a town does not enter the starting
# area under ANY circumstances, for all the towns without an exception
# (including the guaranteed town of the 2nd era). The cut out hexes do not get the flag
# in_town_influence, do not fall into influence_hexes, into the pool of the sale, and into
# the decorative improvements - that is, the player on his own initial land can
# build, improve the resources and buy the chunks without looking back at the towns.
#
# IMPORTANT: the ring is NOT clipped by the CURRENT Region. Earlier the hexes of the ring
# which fell into the Region were thrown out - so that a foreign town would not "give away"
# itself in the unexplored zone of the 1st era. But such a cut FROZE the ring at the borders
# of the 1st era forever: with the growth of the Region (a change of the epoch) the fill of the town remained
# a scrap - only the part of the ring which fell into the NEW Region was drawn, and the cut
# part did not return (the measured losses are up to 18% of the hexes of the fill, a town at
# the left border of the Region lost 5 hexes out of 18). Now the ring is stored entirely
# (minus the starting area of the player, which never changes, and minus the rings
# of the neighbouring towns), and the visibility is decided by the renderer: the fill and the outline are drawn
# only on the hexes outside the fog (main_map.is_hex_in_fog) and not before the era
# of the Antiquity - exactly there where the town itself is (see
# map_renderer._ensure_town_influence_cache).
func compute_all_town_influences(tile_data: Array, map_rows: int, map_cols: int) -> void:
    # Before the recalculation we remove the old flags in_town_influence from ALL the hexes -
    # otherwise on a change of the composition of the towns (for example, a deletion/an addition)
    # the old marks will remain on the hexes which no longer belong to any
    # ring. The flag has_town is NOT touched - it is managed in generate_towns.
    for r in range(map_rows):
        for c in range(map_cols):
            if tile_data[r] != null and c < tile_data[r].size() \
                    and tile_data[r][c] != null:
                tile_data[r][c]["in_town_influence"] = false

    town_influence_hexes = []
    # The counter of the hexes cut out by the starting area of the player - only for the printing
    # at the end (the diagnostics of "a town at the edge of the Region lost half a ring").
    var clipped_by_player := 0
    # The table of the "claimed" hexes: the key "r,c" -> true. The towns are iterated in
    # the order of the array towns (the order of the placement; for a save - the order of the records),
    # therefore a hex which is claimed for the first time by one town cannot fall into
    # the ring of another. This is the principle of "whoever stood first, has the priority": the rings
    # NEVER intersect, and the ring of a later town is simply
    # cut on the side of the neighbour.
    var claimed: Dictionary = {}
    for t in towns:
        # The ring is always recomputed by the radius of this town from scratch (see above):
        # the composition saved in the save may be cut by the starting Region.
        var ring: Array = compute_town_influence(tile_data, map_rows, map_cols,
                int(t.row), int(t.col), t,
                int(t.get("influence_radius", INFLUENCE_MAX_RADIUS)))
        # The clip of the personal ring, in the order of significance:
        #   1) THE STARTING AREA OF THE PLAYER (the Ring + the Region of the 1st era) - the hexes
        #      are thrown out ALWAYS and for ALL the towns, including the guaranteed
        #      town of the 2nd era. There the player builds, buys and scouts
        #      initially, therefore a foreign territory there would mean
        #      a "dead zone" in the middle of his own land (and the impossibility to improve
        #      a resource which by the story is already his). The check goes BEFORE the table
        #      claimed: the player is stronger than any neighbouring town.
        #   2) the hexes which are already claimed by an earlier town, - we drop them and do NOT
        #      write them into the ring of this town. The fill and the borders (the renderer
        #      builds them by influence_hexes) therefore at the different towns
        #      are guaranteed not to intersect. The cut ring falls into
        #      the record of the town and then into the save (serialize_towns).
        var clipped: Array = []
        for rh in ring:
            var hex_row := int(rh.row)
            var hex_col := int(rh.col)
            if _is_in_player_start_area(hex_row, hex_col):
                clipped_by_player += 1
                continue
            var key := "%d,%d" % [hex_row, hex_col]
            if claimed.has(key):
                continue
            claimed[key] = true
            clipped.append(rh)
            # We set the flag on the tile - build_manager and the validators read
            # it directly, without a search over the list.
            if hex_row >= 0 and hex_row < map_rows \
                    and hex_col >= 0 and hex_col < map_cols \
                    and tile_data[hex_row] != null and hex_col < tile_data[hex_row].size() \
                    and tile_data[hex_row][hex_col] != null:
                tile_data[hex_row][hex_col]["in_town_influence"] = true
            town_influence_hexes.append(rh)
        t["influence_hexes"] = clipped
    # The trade pools of a town (the sale + the purchase) are rebuilt after the clip of the rings,
    # so that the neighbouring towns do not get a resource which remained in the ring of another
    # town. The calculation of the closure of the production and of the import is in
    # scripts/town_economy.gd (the pure functions over the data of the recipes).
    _refresh_sell_pools(tile_data)
    print("town_manager: the total number of the hexes in the rings of the influence=",
            town_influence_hexes.size(), " (the towns=", towns.size(), ")")
    if clipped_by_player > 0:
        print("town_manager: the number of the hexes of the rings cut out by the starting area of the player=",
                clipped_by_player, " (the rings of the towns at the edge of the Region are cut)")

# Rebuilds the trade pools of EACH town: what it sells (sell_pool) and
# what it is ready to buy (buy_pool).
#
# The source is its personal ring of the influence, but the calculation itself lives in
# scripts/town_economy.gd: there is the closure of the production by the recipes (a town
# sells not only what lies on the hexes, but also what it is able to make)
# and the cascade import with a throw of the probability.
#
# The same type of a resource in several hexes is displayed by one line:
# the trade pool contains a list of the available TYPES of the resources, and not each
# deposit separately. The order of the traversal of the ring is stable and coincides with
# with the order of the hexes in the saved ring.
#
# BOTH kinds of the resources on a hex are taken into account: the natural one (tile.resource) and
# the bred one (tile.crop_bred - for example, the crop on a food field of a town).
# The second contribution gives to the pool exactly that for which the field is sown: a town without
# the other resources gets something to sell and does not look extinct.
#
# The throw of the probability is deterministic (see the header of town_economy.gd), therefore
# a repeated call - and on the load of a save it happens twice - gives the same
# pools, and "what the town buys" does not jump from a save to a save.
func _refresh_sell_pools(tile_data: Array) -> void:
    TownEconomy.refresh_all_towns(towns, tile_data)
# Computes the influence ring for ONE town. It returns an Array of
# {row, col} - a list of the hexes in the ring. The details of the algorithm (the base,
# the asymmetry, the paths to the resources) are in the comment to INFLUENCE_MAX_RADIUS.
#
# The parameters:
#   tile_data - a 2D array of the hexes. It is needed for the check of tile.resource (step 3).
#   map_rows, map_cols - the dimensions of the map (for the traversal of the neighbours in the path function).
#   town_row, town_col - the coordinates of the town around which the ring is built.
#   town_dict - the record of the town (a dictionary) from towns. The parameter is left for
#     the future mechanics which will need to distinguish the towns.
#   radius - the radius of the ring for THIS town (per-town). By default
#     INFLUENCE_MAX_RADIUS; the future mechanics of the growth/shrinkage of the ring pass
#     here the radius from the record of the town.
#
# The ring is built ENTIRELY by the radius (without a clip by the Region): what of it
# is visible to the player is decided by the renderer. The cut out by the starting area of the player and by
# the rings of the neighbouring towns is done by the calling side -
# compute_all_town_influences.
func compute_town_influence(tile_data: Array, map_rows: int, map_cols: int,
        town_row: int, town_col: int, town_dict: Dictionary = {},
        radius: int = INFLUENCE_MAX_RADIUS) -> Array:
    var ring: Dictionary = {} # the key "r,c" -> true for a quick check of the membership
    var rng := RandomNumberGenerator.new()
    # A stable seed: each combination (row, col) gives a unique,
    # but reproducible between the sessions seed. Simple prime numbers - so that
    # the towns neighbouring on the map get the maximally different notches.
    rng.seed = town_row * 1009 + town_col * 7919

    # --- Step 1: the base disk (the distance 0..radius) ---
    var r_min: int = maxi(0, town_row - radius)
    var r_max: int = mini(map_rows - 1, town_row + radius)
    var c_min: int = maxi(0, town_col - radius)
    var c_max: int = mini(map_cols - 1, town_col + radius)
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if HexUtils.hex_distance(r, c, town_row, town_col) <= radius:
                ring["%d,%d" % [r, c]] = true

    # --- Step 2: the asymmetry - we drop 1-3 hexes at a distance of 3
    # in one "side" (of 6). The side is chosen randomly, but
    # deterministically from the seed.
    var notch_side: int = rng.randi_range(0, 5)
    var outer_dropped: int = 0
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if outer_dropped >= INFLUENCE_NOTCH_MAX_DROPS:
                break
            if not ring.has("%d,%d" % [r, c]):
                continue
            var d: int = HexUtils.hex_distance(r, c, town_row, town_col)
            if d != radius:
                continue
            if _hex_side(town_row, town_col, r, c) != notch_side:
                continue
            if rng.randf() < INFLUENCE_NOTCH_PROBABILITY:
                ring.erase("%d,%d" % [r, c])
                outer_dropped += 1
        if outer_dropped >= INFLUENCE_NOTCH_MAX_DROPS:
            break

    # --- Step 3: for each resource within the radius radius
    # we add the hex with the resource and the shortest path from the town.
    # The protection from the "enclaves": if the notch of step 2 surrounded a resource, the player
    # could get a small "island" of the available land in the middle of
    # the forbidden zone. The path "sews" the resource back to the ring.
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if HexUtils.hex_distance(r, c, town_row, town_col) > radius:
                continue
            var tile = tile_data[r][c]
            if tile == null:
                continue
            var res = tile.get("resource", null)
            if res == null or res == "":
                continue
            # We do NOT take crop_bred into account: a domesticated resource appears AFTER
            # of how the player built a farm/pasture, and at this point the ring
            # has long been computed. We take into account only the "natural" resources.
            var path: Array = _path_between(town_row, town_col, r, c, map_rows, map_cols)
            for ph in path:
                ring["%d,%d" % [ph.row, ph.col]] = true

    # --- The conversion of a dictionary into an Array of {row, col} ---
    # There is NO clip by the Region here deliberately (see the header of the function): the ring is stored
    # entirely, otherwise with the growth of the Region the fill of the town would remain
    # a scrap forever - only the part of the ring which fell into the Region
    # AFTER the change of the epoch would be drawn.
    var result: Array = []
    for key in ring.keys():
        var parts: PackedStringArray = key.split(",")
        result.append({"row": int(parts[0]), "col": int(parts[1])})
    return result


# Returns the "side" (0..5) of a hex (r, c) relative to the centre (tr, tc).
# It is used for the grouping of the hexes around a town into 6 sectors of 60 degrees,
# so that the asymmetric notch of compute_town_influence "eats" the hexes
# in ONE direction, and not scattered.
#
# The sides are numbered clockwise from the "east" (0=E, 1=SE, 2=S,
# 3=W, 4=NW, 5=NE). The neighbouring sides differ by 60 degrees, which coincides
# with the angles between the neighbours of a hex - therefore the hexes of one sector lie
# "approximately" in one direction from the centre.
func _hex_side(tr: int, tc: int, r: int, c: int) -> int:
    var tr_pos: Vector2 = HexUtils.hex_center(tr, tc, 1.0)
    var h_pos: Vector2 = HexUtils.hex_center(r, c, 1.0)
    # atan2 in Godot: Y grows downwards, therefore the standard "mathematical" angles
    # are counted COUNTERCLOCKWISE from the east. This suits us -
    # what matters to us is not the sign of the turn, but the division of the plane into 6 equal sectors.
    var angle_rad: float = atan2(h_pos.y - tr_pos.y, h_pos.x - tr_pos.x)
    var angle_deg: float = rad_to_deg(angle_rad)
    if angle_deg < 0.0:
        angle_deg += 360.0
    # +30 degrees shifts the borders of the sectors so that the "east" (angle ~ 0)
    # falls exactly into the centre of the sector 0, and not onto its border.
    return int((angle_deg + 30.0) / 60.0) % 6


# Returns the shortest "greedy" path from (fr, fc) to (tr, tc) through
# the hexagonal neighbours, INCLUDING both end points.
#
# The algorithm: at each step we choose the neighbour with the minimal hex_distance
# to the goal (the tie-break is the order from get_neighbors_odd_r, i.e. deterministic).
# This gives ONE OF the shortest paths; its length == hex_distance + 1,
# which for the distances <= 3 (the radius of our ring) does not go beyond
# the disk. If the map is small and the path "bottoms out" at the edge, get_neighbors_odd_r
# will return less than 6 neighbours and the loop will stop (a safety of 16 steps -
# an insurance from the degenerate case, in a normal situation it does not fire).
func _path_between(fr: int, fc: int, tr: int, tc: int,
        map_rows: int, map_cols: int) -> Array:
    var path: Array = [ {"row": fr, "col": fc}]
    var cur_r: int = fr
    var cur_c: int = fc
    var safety: int = 0
    while (cur_r != tr or cur_c != tc) and safety < 16:
        safety += 1
        var neighbors: Array = HexUtils.get_neighbors_odd_r(cur_r, cur_c, map_rows, map_cols)
        var best: Dictionary = {}
        var best_dist: int = 999999
        for n in neighbors:
            var d: int = HexUtils.hex_distance(n.row, n.col, tr, tc)
            if d < best_dist:
                best_dist = d
                best = n
        if best.is_empty():
            break
        cur_r = int(best.row)
        cur_c = int(best.col)
        path.append({"row": cur_r, "col": cur_c})
    return path
