# town_economy.gd
# The trade economy of a town (small settlement): what it can PRODUCE by itself
# and what it is ready to buy from outside.
#
# The trade pools are computed in town_manager._refresh_sell_pools, but the logic
# "what can be made out of what" is pure arithmetic over the recipe data
# (GameData.crafts) and the groups (GameData.product_groups). It depends neither on
# the map, nor on the influence rings, nor on the state of the city, therefore it lives here, in
# pure static functions — so that it can be checked by a headless test without
# the map generation (tests/test_town_economy.gd).
#
# --- THE PATH FROM RESOURCES TO SALE ---
#   1. The base pool — the PRODUCTION of the resources of the ring hexes (the produces field). The
#      resource itself — a field, a deposit, an animal, wild food, a nugget — does NOT go into
#      the pool: that is a description of the hex, and not a product. Wheat, feed, meat, hide and
#      ore are traded, and not "a wheat field" and not "a cow". The rule is exactly one, therefore
#      no separate exceptions are needed for the animals and the one-off finds
#      (see collect_base_resources).
#   2. CLOSURE (fixpoint) — while the pool expands, every recipe all
#      the ingredients of which are already available adds its result to the pool.
#      An ingredient is "available" if it is itself in the pool OR it is an @-group, any
#      member of which is in the pool (the semantics of GameData.get_storage_amount: "any
#      product from the group").
#   3. The import cascade. The recipes that did not close, but which have at least
#      ONE available ingredient, are the candidates for buying. The purchase probability
#      = the share of the closed ingredients, the amount of the resource is NOT taken into account:
#      the town extracts nothing and produces nothing in the buildings, its economy
#      is virtual, therefore for it "iron and coal are needed" means exactly the same as
#      "30 iron and 20 coal are needed". The volumes from data/crafts are not
#      read at all for this task.
#   4. The cascade repeats while a new import opens something: the bought ore
#      gives metal, the metal gives items, and so on. There is no fixed number of
#      passes; the cycle goes until the round in which NOT A SINGLE
#      new import appeared.
#   5. What is imported does NOT go into the SALE pool (a design requirement): the town
#      buys in order to organize production, and not in order to resell
#      the raw material. Only what it produced itself goes on sale.
#
# --- WHAT IS DELIBERATELY NOT CHECKED ---
#   - the unlock_tech of the recipe. The town has no tech tree of its own, and a gate by
#     the PLAYER's technologies would tie the trade pool to the progress of the player: a town at
#     the edge of the map would "freeze" at the level of the era the player has not grown into yet.
#   - the produced_in of the recipe. The town does not build city buildings; a forge,
#     which it does not have, is not a reason to deny it the production of copper.
#
# --- DETERMINISM ---
# The purchase decision is a probability roll, therefore it must be STABLE:
# _refresh_sell_pools is called twice in a row (from compute_all_town_influences and
# from _place_decorative_town_improvements) and both times on loading the save.
# A global randi() here would give the town a different buy_pool on every load,
# and "what it buys" would jump from save to save. Therefore all the rolls
# and the choice of the @-group representative go through local RandomNumberGenerator with
# a seed from (the town id, the recipe id, the ingredient index). The same trick as in
# _make_border_color: the value is derived from the identifier, and not from the state
# of the random number generator.
class_name TownEconomy
extends RefCounted

# Whether to take the production of a resource (the produces field in data/resources/*.json) into
# account when building the base pool. By default — the only way to get something
# into the pool: the raw material itself is not sold (collect_base_resources). The flag is left as
# an emergency switch for debugging: when false, the raw resource
# ids themselves get into the pool, although they are conceived as a source, and not as a product.
const INCLUDE_RESOURCE_YIELD := true

# The resource category for which ONE-TIMENESS does not mean "there is nothing
# to sell". A nugget (copper_nugget and so on) is ore on a hex, and not
# a find: once having picked up a nugget, the town will not stop smelting copper.
# Therefore the production of the one-off metals goes into the pool, but the production of the other
# one-off resources (wild plants wild_food -> foraged_food) does not: you cannot
# gather it every time, and such a product in the trade would be a fiction.
const ONE_TIME_YIELD_CATEGORY := "metals"

# The level a product falls back to when the map carries no usable quality (a
# broken save, a resource without a rolled level). It is the lowest level of the
# scale in data/qualities.json and the one the rest of the game treats as neutral.
const DEFAULT_QUALITY := "common"

# Whether the resource is one-off — that is, does it disappear from the hex after being gathered.
# The sign is exactly the same as the rest of the game uses for the special action
# "Gather resource" (control_panel.gd, main_map.gd): improved_by == null
# (it is not extracted by an improvement) and a non-empty produces (there is something to gather).
# On the data this is exactly 5 resources: four nuggets (copper_nugget,
# gold_nugget, silver_nugget, meteorite_iron_nugget) and wild_food. It is important that
# the category of wild_food is "plants", and not "metals": we must filter by category,
# and not by the "wild" group.
static func is_one_time(resource_id: String) -> bool:
    var data: Dictionary = GameData.raw_resources.get(resource_id, {})
    if data.get("improved_by", null) != null:
        return false
    return not data.get("produces", {}).is_empty()

# --- The base pool ---

# Builds the base pool of the town: the ids of the PRODUCTION of the resources lying on its hexes.
# The resource on the hex — natural (resource) OR breedable (crop_bred): the food
# field of the town must also give something, otherwise the town window looks empty.
#
# What and why gets into the pool (see the header of the file):
#   - ordinary raw materials (wheat_field, basalt_deposit): only produces — grain and
#     feed, stone. The field/deposit itself is not a product;
#   - animals (cows, ostrich, freshwater_fish): only produces — meat, hide,
#     eggs, catch. "Fish" and "Ostriches" in the sale list would read as "the town
#     sells fish out of the water", although it sells the catch;
#   - the one-off metals (copper_nugget): produces — ore. The forge needs ore,
#     and it can be extracted without limit;
#   - the other one-off (wild_food): nothing. Wild plants are gathered once, and
#     their "foraged_food" in the trade is a fiction;
#   - a resource that is NOT in the registry (a broken save) is added as is:
#     silently throwing it out of the pool is worse than showing it.
#
# The closure of the production does not suffer from this: not a single id from
# data/resources/** occurs as an ingredient of the recipes in data/crafts/** —
# the recipes operate only with products (hide, raw_meat, wheat, copper_ore).
#
# It returns an array of ids in a stable order (as the walk of the ring).
static func collect_base_resources(tiles: Array) -> Array:
    var result: Array = []
    var seen: Dictionary = {}
    for entry in tiles:
        var tile: Dictionary = entry if entry is Dictionary else {}
        if tile.is_empty():
            continue
        var resource_id := MapHelpers.get_effective_resource(tile).strip_edges()
        # The absence of a resource in the JSON/saves is null, and str(null) would give
        # a pseudo-resource "<null>", which would get into the pool first. An empty string and
        # "<null>" are discarded identically (as it was in town_manager).
        if resource_id.is_empty() or resource_id == "<null>" or seen.has(resource_id):
            continue
        seen[resource_id] = true
        var data: Dictionary = GameData.raw_resources.get(resource_id, {})
        if data.is_empty():
            result.append(resource_id)
            continue
        if not INCLUDE_RESOURCE_YIELD:
            result.append(resource_id)
            continue
        var produces: Dictionary = data.get("produces", {})
        if produces.is_empty():
            # There is no crop — there is nothing to sell, but we also cannot silently
            # throw the resource away: it still means something to the town.
            result.append(resource_id)
            continue
        if is_one_time(resource_id) \
                and str(data.get("category", "")) != ONE_TIME_YIELD_CATEGORY:
            continue
        # The production of the resource (cows -> raw_meat/hide, wheat_field -> wheat/feed):
        # the same economy, only a different output. The recipes eat exactly these
        # products, and not the animals themselves and not the fields themselves.
        for pid in produces:
            var produced := str(pid)
            if produced.is_empty() or seen.has(produced):
                continue
            seen[produced] = true
            result.append(produced)
    return result


# --- The warehouse (the storage of a town) ---
#
# The trade pools answer the question "what CAN the town trade", and the warehouse
# answers "how MUCH of it does the town have right now". The pools stay a set of
# product ids, and the warehouse is the quantity behind each of them.
#
# A town never goes into deficit: if it has decided to make something, it makes it,
# regardless of how many towns gather or import it. Therefore the production plan of
# a town is a flat per-tick rate and not a real factory: the ingredients are not
# consumed, and nothing is ever "out of stock" — only the limit of the warehouse
# (town_storage_limit) stops the accumulation.

# The per-tick rate of the raw materials of the ring: product id -> units per ONE town
# tick. The source is the produces field of the resources — the very same source as the
# base pool (collect_base_resources), so the warehouse fills with exactly what the
# town is able to trade.
#
# The minimum of a range ([min, max] -> min) is taken, the same deterministic
# convention as the production of the city (CityData.add_raw_production): a roll here
# would refill the warehouse differently on every recalculation of the pools and on
# every load of the save.
#
# A resource that produces nothing tradable (a one-off find of wild_food, a resource
# with an empty produces) gives nothing here: its id may still appear in the pool as
# itself (collect_base_resources keeps it as "something meaningful to the town"), but
# the warehouse has no rate for it and the stock stays at its starting value.
static func collect_base_yields(tiles: Array) -> Dictionary:
    var yields: Dictionary = {}
    var seen: Dictionary = {}
    for entry in tiles:
        var tile: Dictionary = entry if entry is Dictionary else {}
        if tile.is_empty():
            continue
        var resource_id := MapHelpers.get_effective_resource(tile).strip_edges()
        if resource_id.is_empty() or resource_id == "<null>" or seen.has(resource_id):
            continue
        seen[resource_id] = true
        var data: Dictionary = GameData.raw_resources.get(resource_id, {})
        if data.is_empty():
            continue
        var produces: Dictionary = data.get("produces", {})
        if produces.is_empty():
            continue
        if is_one_time(resource_id) \
                and str(data.get("category", "")) != ONE_TIME_YIELD_CATEGORY:
            continue
        for pid in produces:
            var produced := str(pid)
            if produced.is_empty():
                continue
            var amount := RangeUtils.get_min_value(produces[pid], 0)
            if amount <= 0:
                continue
            yields[produced] = yields.get(produced, 0) + amount
    return yields


# The quality of every product the ring yields: product id -> quality id.
#
# The rule is deliberately simpler than in the city: a town warehouse never holds
# MIXED quality. Every product carries exactly one level. When the ring holds the
# same product at several levels (common cows and exceptional cows), the level of
# the warehouse is the HIGHEST one: the town sells its best goods, and the lesser
# ones are simply not what it is known for. This is the same "the best raw material
# wins" reading the design doc gives for breeding ("exceptional cows bear exceptional
# calves"), only applied across the whole ring instead of a single hex.
#
# The town is a virtual economy of a handful of hexes; a breakdown by quality would
# be a fiction there, and the player only ever sees stars.
#
# The tile quality is rolled once when the resource is spawned (map_generator) or
# bred (main_map), so the level is stable across a save.
static func collect_base_qualities(tiles: Array) -> Dictionary:
    var qualities: Dictionary = {}
    for entry in tiles:
        var tile: Dictionary = entry if entry is Dictionary else {}
        if tile.is_empty():
            continue
        var resource_id := MapHelpers.get_effective_resource(tile).strip_edges()
        if resource_id.is_empty() or resource_id == "<null>":
            continue
        var data: Dictionary = GameData.raw_resources.get(resource_id, {})
        if data.is_empty():
            continue
        var produces: Dictionary = data.get("produces", {})
        if produces.is_empty():
            continue
        if is_one_time(resource_id) \
                and str(data.get("category", "")) != ONE_TIME_YIELD_CATEGORY:
            continue
        # A resource without a rolled quality (a broken save) yields the ordinary
        # level: the stars must never point at a level that is not in the scale.
        var quality := str(tile.get("quality", ""))
        if quality.is_empty() or quality == "<null>":
            quality = DEFAULT_QUALITY
        for pid in produces:
            var produced := str(pid)
            if produced.is_empty():
                continue
            # The best level among all the hexes of the ring wins, whatever the
            # order of the walk is.
            if qualities.has(produced) and not is_better_quality(quality, str(qualities[produced])):
                continue
            qualities[produced] = quality
    return qualities


# Whether the quality level a is BETTER than the level b (a higher value in the
# scale of data/qualities.json). A level neither is in the scale counts as the
# ordinary one, so broken data cannot win by accident.
static func is_better_quality(a: String, b: String) -> bool:
    return GameData.get_quality_value(a) > GameData.get_quality_value(b)


# The capacity of the warehouse of one town, in units PER product id
# (town_storage_limit in data/game_balance.json).
static func get_storage_limit() -> int:
    return int(GameData.game_balance.get("town_storage_limit", 1000))


# The starting stock of ONE product of ONE town: a stable integer in
# [town_storage_initial_min, town_storage_initial_max] from data/game_balance.json.
#
# The value is derived from (the town id, the product id) through _seed_for, and not
# from the global RNG: the pools are recalculated twice on a new game and on every
# load of a save (see the determinism note in the header), and a roll would give the
# warehouse a different starting stock each time. Two towns differ, and the same town
# is always the same.
static func get_initial_stock(town_id: String, product_id: String) -> int:
    var low := int(GameData.game_balance.get("town_storage_initial_min", 100))
    var high := int(GameData.game_balance.get("town_storage_initial_max", 500))
    if high < low:
        high = low
    if high == low:
        return maxi(0, low)
    var rng := RandomNumberGenerator.new()
    rng.seed = _seed_for(town_id, "stock:" + product_id)
    return rng.randi_range(low, high)


# The starting warehouse of a town: every product of its sell_pool gets a stock of
# its own within the configured bounds.
static func build_initial_storage(town_id: String, sell_ids: Array) -> Dictionary:
    var storage: Dictionary = {}
    for pid in sell_ids:
        var id := str(pid)
        if id.is_empty() or id == "<null>":
            continue
        storage[id] = get_initial_stock(town_id, id)
    return storage


# Adds the production of ONE town tick to the warehouse, product by product.
#
# The limit is per product: a town at the cap on one good keeps accumulating all its
# others. The units that did not fit are simply discarded — the town keeps making
# them, and they are stored again as soon as some of the stock is sold.
#
# storage    — the warehouse of the town (it is edited in place);
# production — product id -> units per tick;
# limit      — the capacity per product (town_storage_limit).
static func store_production(storage: Dictionary, production: Dictionary, limit: int) -> void:
    for pid in production:
        var id := str(pid)
        var amount := int(production[pid])
        if id.is_empty() or amount <= 0:
            continue
        storage[id] = mini(int(storage.get(id, 0)) + amount, limit)

# --- CHECKING THE AVAILABILITY OF AN INGREDIENT ---

# Whether the ingredient key is available for the pool pool.
# An ordinary key — it is itself in the pool. An "@" group — at least ONE of its members is in the
# pool: the groups are treated the same way in the rest of the game (GameData.get_storage_amount, CityData
# on a consumption write-off). It also makes a recipe like "bread from
# @millable_grains" doable if there is at least one wheat.
static func is_available(key: String, pool: Dictionary) -> bool:
    return GameData.is_key_available(key, pool)

# Whether the recipe is fully assembled by the pool: EVERY OR-group of the
# ingredients must have at least one available variant (see the alternative
# ingredients in GameData.gd). A recipe without the ingredients is trivially closed.
static func is_recipe_ready(craft: Dictionary, pool: Dictionary) -> bool:
    var alternatives: Array = GameData.craft_alternatives(craft)
    for or_group in alternatives:
        var ready := false
        for variant in or_group:
            if is_available(str(variant.get("key", "")), pool):
                ready = true
                break
        if not ready:
            return false
    return true

# The readable ingredient keys of the recipe for the "missing" lists of the import
# cascade: for every OR-group the FIRST not yet closed variant is chosen — it is
# exactly the one the town will "buy".
static func _missing_representatives(craft: Dictionary, pool: Dictionary) -> Array:
    var missing: Array = []
    for or_group in GameData.craft_alternatives(craft):
        var closed := false
        var first_open := ""
        for variant in or_group:
            var key := str(variant.get("key", ""))
            if is_available(key, pool):
                closed = true
                break
            if first_open.is_empty():
                first_open = key
        if not closed and not first_open.is_empty():
            missing.append(first_open)
    return missing

# --- Closure ---

# Recursively supplements pool with everything that can be made from what is already known.
#
# made       — a Dictionary set: the ids PRODUCED by crafting are put here (in
#              contrast to the base pool, which also includes the natural resources).
# production — the PER-TICK rate of the warehouse: the amount of the result of the
#              recipe, because the town actually produces it (see the warehouse
#              section above). It is filled here, at the same moment the product
#              enters the pool, so that the rate and the membership of the pool
#              cannot disagree.
#
# The fixpoint is safe: the pool only grows, and the set of possible ids is finite,
# therefore the cycle completes. A safety pass counter — in case
# of a cycle due to an error in the data: it is better to stop with an incomplete pool than
# to hang at the start of the game.
static func _close_pool(pool: Dictionary, made: Dictionary, production: Dictionary,
        qualities: Dictionary = {}) -> void:
    var guard := 0
    while guard < 1000:
        guard += 1
        var grew := false
        for craft in GameData.crafts:
            var result: Dictionary = craft.get("result", {})
            # The pseudo-recipes (empty, science) have no result — there is nothing
            # to add for them to the pool, and their ingredients do not describe a production.
            if result.is_empty():
                continue
            if not is_recipe_ready(craft, pool):
                continue
            # The quality of the result is the standard craft rule of the city
            # (a weighted average of the ingredients), see craft_result_quality.
            var result_quality := craft_result_quality(craft, pool, qualities)
            for pid in result:
                var produced := str(pid)
                if pool.has(produced):
                    continue
                pool[produced] = true
                made[produced] = true
                # The recipe is executed once per town tick, therefore its full
                # output lands in the warehouse on that tick (10 silk per tick
                # for a recipe of "silk: 10").
                production[produced] = maxi(0, int(result[pid]))
                qualities[produced] = result_quality
                grew = true
        if not grew:
            return


# The quality of the result of a recipe by the standard craft rule — the same one
# the city applies to its buildings (CityData.quality_from_breakdown): every
# ingredient contributes its quality weight (data/qualities.json, value), the
# average is rounded to the nearest level.
#
# The town keeps no breakdown: an ingredient of a town is present at exactly one
# level, so here the "breakdown" is one unit per ingredient — the weighting by
# counts degenerates, and the rule reads as "the average level of the ingredients".
# The quantities from data/crafts are still not read (the town economy is virtual,
# see the header), therefore one ingredient one vote is the honest reading.
#
# An ingredient whose quality is unknown (a broken registry, a pseudo-resource)
# counts as the ordinary level, so the stars never point outside the scale.
static func craft_result_quality(craft: Dictionary, pool: Dictionary,
        qualities: Dictionary) -> String:
    var total := 0
    var weighted := 0.0
    for or_group in GameData.craft_alternatives(craft):
        var picked := ""
        for variant in or_group:
            var key := str(variant.get("key", ""))
            if not is_available(key, pool):
                continue
            picked = key
            break
        if picked.is_empty():
            continue
        var qid := _ingredient_quality(picked, pool, qualities)
        total += 1
        weighted += float(GameData.get_quality_value(qid))
    if total <= 0:
        return DEFAULT_QUALITY
    return _round_quality_to_level(weighted / float(total))


# The quality of one ingredient of the pool. An "@" group is resolved to the first
# member present in the pool (deterministic: the closure itself treats the group
# that way, see is_available).
static func _ingredient_quality(key: String, pool: Dictionary,
        qualities: Dictionary) -> String:
    if key.begins_with("@"):
        for member in GameData.product_groups.get(key.substr(1), []):
            var m := str(member)
            if pool.has(m):
                return str(qualities.get(m, DEFAULT_QUALITY))
        return DEFAULT_QUALITY
    return str(qualities.get(key, DEFAULT_QUALITY))


# Rounds an average quality value to the nearest level of the scale.
# The mirror of CityData.quality_from_breakdown, kept here so that the town
# economy stays a pure static module without the state of the city.
static func _round_quality_to_level(avg: float) -> String:
    var levels: Array = GameData.get_quality_levels()
    if levels.is_empty():
        return DEFAULT_QUALITY
    var best_qid: String = str(levels[0])
    var best_diff := 1e9
    for qid in levels:
        var diff := absf(float(GameData.get_quality_value(str(qid))) - avg)
        if diff < best_diff:
            best_diff = diff
            best_qid = str(qid)
    return best_qid

# --- Readiness and the roll ---

# The share of the closed ingredients in percent: how "almost assembled" the recipe is.
# The amount of the resource is deliberately NOT taken into account (see the header of the file). The values
# for the recipes of 2–3 ingredients: 1 of 2 -> 50, 1 of 3 -> 33, 2 of 3 -> 67.
#
# It is exactly the ROUNDING, and not the integer division: 2/3 = 66.67 -> 67, whereas with
# discarding the fractional part it would be 66, and "two of three" would read worse
# than "one of two" (50), although more is closed. The purchase probability must be
# not less for a more ready recipe.
static func readiness_percent(recipe_id: String, pool: Dictionary) -> int:
    for craft in GameData.crafts:
        if str(craft.get("id", "")) != recipe_id:
            continue
        return _readiness_of(craft, pool)
    return 0

static func _readiness_of(craft: Dictionary, pool: Dictionary) -> int:
    var alternatives: Array = GameData.craft_alternatives(craft)
    var total := alternatives.size()
    if total == 0:
        return 0
    var available := 0
    for or_group in alternatives:
        for variant in or_group:
            if is_available(str(variant.get("key", "")), pool):
                available += 1
                break
    return roundi(float(available) * 100.0 / float(total))

# The roll is made ONCE per recipe (the result is remembered in rolls) — "the town
# has decided", and not "the town rolls the dice again on every round". A recipe may
# appear in several rounds of the cascade, and rerolling it every time
# would mean a lottery with an unlimited number of attempts.
static func _roll_import(town_id: String, recipe_id: String, percent: int,
        rolls: Dictionary) -> bool:
    if rolls.has(recipe_id):
        return bool(rolls[recipe_id])
    var rng := RandomNumberGenerator.new()
    rng.seed = _seed_for(town_id, recipe_id)
    var success := rng.randi_range(1, 100) <= percent
    rolls[recipe_id] = success
    return success

# The @-group representative: a RANDOM member (the price does not matter — the economy is virtual).
# It is deterministic for the same reason as the roll: the choice must be stable against
# a reload of the save, otherwise the buying pool would be reconsidered on every read.
static func _pick_group_member(town_id: String, recipe_id: String,
        index: int, group_key: String) -> String:
    var members: Array = GameData.product_groups.get(group_key, [])
    if members.is_empty():
        return ""
    var rng := RandomNumberGenerator.new()
    rng.seed = _seed_for(town_id, recipe_id) + index
    return str(members[rng.randi_range(0, members.size() - 1)])

# A stable seed from a string. We do not need a specific hash algorithm — only
# that different (town, recipe, index) give different numbers, and the identical ones —
# the identical ones.
static func _seed_for(town_id: String, recipe_id: String) -> int:
    var raw := "%s|%s" % [town_id, recipe_id]
    var h := 17
    for i in range(raw.length()):
        h = (h * 31 + raw.unicode_at(i)) & 0x7FFFFFFF
    return h

# --- Assembling the pools ---

# The full calculation of the trade pools of the town.
#
# town_id   — the town identifier ("town_3"); it is part of the seed of all the rolls.
# base_ids  — the base pool from collect_base_resources.
#
# It returns { "sell_pool": Array, "buy_pool": Array, "production": Dictionary,
# "quality": Dictionary }; both arrays are sorted, so that the same state gives the
# same result in printing and in the tests. "production" is the per-tick rate of the
# CRAFTED goods (product id -> units per town tick), and it holds only the ids of
# the sell_pool: the town stores what it trades, and the imported raw material is an
# input, not a stock. "quality" is the single level of every traded product
# (product id -> quality id): the ring yields carry the quality of the map hex,
# the crafted goods the weighted average of their ingredients. The yield of the raw
# materials of the ring is added by refresh_town, which alone has the hexes.
static func build_pools(town_id: String, base_ids: Array,
        base_qualities: Dictionary = {}) -> Dictionary:
    var made: Dictionary = {}
    var imports: Dictionary = {}
    var production: Dictionary = {}
    # The base pool — a simple set: id -> true. The duplicates collapse.
    var pool: Dictionary = {}
    # The base qualities are seeded first: the closure reads them to compute the
    # quality of the crafted goods (craft_result_quality).
    var qualities: Dictionary = {}
    for pid in base_qualities:
        var qid := str(base_qualities[pid])
        if qid.is_empty():
            qid = DEFAULT_QUALITY
        qualities[str(pid)] = qid
    for base_id in base_ids:
        var id := str(base_id)
        if id.is_empty():
            continue
        pool[id] = true
    _close_pool(pool, made, production, qualities)

    # The import cascade: round by round, while a new import opens something.
    var rolls: Dictionary = {}
    var guard := 0
    while guard < 200:
        guard += 1
        var bought: Dictionary = {}
        for craft in GameData.crafts:
            var recipe_id := str(craft.get("id", ""))
            if recipe_id.is_empty():
                continue
            # A recipe without ingredients and a pseudo-recipe without a result in the purchase
            # do not participate: there is nothing to buy or nothing to produce.
            var alternatives: Array = GameData.craft_alternatives(craft)
            if alternatives.is_empty() or craft.get("result", {}).is_empty():
                continue
            var missing: Array = _missing_representatives(craft, pool)
            # A fully closed recipe is not a candidate. A recipe without a single
            # available ingredient — neither: buying EVERYTHING at once is meaningless,
            # the town is interested in production, and not in reselling the raw material.
            if missing.is_empty() or missing.size() == alternatives.size():
                continue
            if not _roll_import(town_id, recipe_id, _readiness_of(craft, pool), rolls):
                continue
            var index := 0
            for key in missing:
                var missing_key := str(key)
                var concrete := missing_key
                if missing_key.begins_with("@"):
                    concrete = _pick_group_member(town_id, recipe_id, index,
                            missing_key.substr(1))
                index += 1
                if concrete.is_empty() or imports.has(concrete):
                    continue
                imports[concrete] = true
                bought[concrete] = true
        if bought.is_empty():
            break
        for id in bought:
            pool[id] = true
        _close_pool(pool, made, production, qualities)

    # The sale pool: the base resources + everything produced, MINUS the imported.
    # The import does not get here on purpose (the header of the file, point 5). The subset
    # "the imported that at the same time turned out to be craftable" on the real data
    # is empty, but the rule is stated explicitly: the bought is not sold.
    var sell: Dictionary = {}
    for id in pool:
        if imports.has(id):
            continue
        sell[id] = true
    var sell_ids: Array = sell.keys()
    sell_ids.sort()
    var buy_ids: Array = imports.keys()
    buy_ids.sort()
    # The rate of the warehouse keeps only the goods on sale: an imported raw
    # material is consumed by the town, and it is never put on the stock.
    var sell_production: Dictionary = {}
    var sell_quality: Dictionary = {}
    for id in production:
        if sell.has(id):
            sell_production[id] = production[id]
            sell_quality[id] = str(qualities.get(id, DEFAULT_QUALITY))
    return {
        "sell_pool": sell_ids, "buy_pool": buy_ids,
        "production": sell_production, "quality": sell_quality,
    }

# --- Recalculation by the influence rings ---

# Rebuilds the trade pools of ALL the towns. It is moved out of town_manager, so that
# the latter deals with the placement and the rings, and the pools are computed here.
static func refresh_all_towns(town_list: Array, tile_data: Array) -> void:
    for town in town_list:
        refresh_town(town, tile_data)

static func refresh_town(town: Dictionary, tile_data: Array) -> void:
    var town_id := str(town.get("id", ""))
    var tiles: Array = []
    for hex in town.get("influence_hexes", []):
        var row := int(hex.get("row", -1))
        var col := int(hex.get("col", -1))
        if row < 0 or row >= tile_data.size() or tile_data[row] == null \
                or col >= tile_data[row].size():
            continue
        var tile = tile_data[row][col]
        if tile == null:
            continue
        tiles.append(tile)
    var base_ids := collect_base_resources(tiles)
    var base_qualities := collect_base_qualities(tiles)
    var pools := build_pools(town_id, base_ids, base_qualities)
    town["sell_pool"] = pools["sell_pool"]
    town["buy_pool"] = pools["buy_pool"]

    # The per-tick rate of the warehouse: what the hexes of the ring yield PLUS what
    # the recipes of the closure produce. A product that the ring already yields is
    # not produced by any recipe as well (the closure skips the ids that are already
    # in the pool), therefore the two parts never fight over one product id.
    var production: Dictionary = pools["production"]
    var base_yields := collect_base_yields(tiles)
    for pid in base_yields:
        var id := str(pid)
        if not production.has(id):
            production[id] = base_yields[pid]
    town["production"] = production

    # The single quality level of every traded product. The pool guarantees that
    # every id of the sell pool is covered: the raw materials come from the ring
    # (base_qualities), and the crafted goods were given a level by the closure.
    # A product that somehow slipped through (a resource without a quality) falls
    # back to the ordinary level rather than leaving the row without stars.
    var quality: Dictionary = pools["quality"]
    for pid in pools["sell_pool"]:
        var id := str(pid)
        if quality.has(id):
            continue
        quality[id] = str(base_qualities.get(id, DEFAULT_QUALITY))
    town["quality"] = quality

    # The warehouse holds exactly the goods of the sell pool.
    #
    # A product that has just entered the pool gets a starting stock, and a product
    # that is no longer for sale is dropped. The pruning is not cosmetic: the pools
    # are recalculated twice on a new game, and the ring gains its decorative fields
    # in between, so a product seeded on the first pass can turn into an import on the
    # second. Without the pruning it would sit on the warehouse forever as goods the
    # town neither gathered nor made.
    #
    # The stock of a product that stays in the pool is kept: the recalculation happens
    # twice on a new game and on every load of a save, and the units a town has sold
    # must not come back on every reload.
    var storage: Dictionary = town.get("storage", {})
    var for_sale: Dictionary = {}
    for pid in pools["sell_pool"]:
        var id := str(pid)
        if id.is_empty():
            continue
        for_sale[id] = true
        if not storage.has(id):
            storage[id] = get_initial_stock(town_id, id)
    for id in storage.keys():
        if not for_sale.has(id):
            storage.erase(id)
    town["storage"] = storage
