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
#      A missing ingredient that is an @-group is bought AS THE GROUP: the buy pool
#      carries the group key ("@fruits"), because the town accepts any member. The
#      concrete member is picked when the goods are actually delivered to the town
#      (town_trade_manager), not here; here a stable representative is drawn only to
#      feed the closure.
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

# The forest plot (the woodcutter's camp) and the product it yields on a BARE
# forest hex. The improvement carries no product of its own: a camp on a hex
# without a resource takes its output from the cover (wood_yield in
# data/covers.json), exactly as the city production tick does (main_map.gd).
const FOREST_PLOT_IMPROVEMENT := "lumberjack_hut"
const FOREST_PLOT_PRODUCT := "wood"

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

# The product a forest plot yields from the cover of its hex, or an empty string
# when the hex is not one. A camp on a bare forest hex has no resource to
# extract, so its output is the timber of the cover — a second source of the pool
# besides the resource of the hex (collect_base_resources).
static func forest_plot_product(tile: Dictionary) -> String:
    if str(tile.get("improvement", "")) != FOREST_PLOT_IMPROVEMENT:
        return ""
    if MapHelpers.get_cover_wood_yield(tile) <= 0.0:
        return ""
    return FOREST_PLOT_PRODUCT

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
        if resource_id.is_empty() or resource_id == "<null>":
            # A forest plot on a bare forest hex: there is no resource to name, but
            # the camp still puts its timber on sale.
            var wood := forest_plot_product(tile)
            if not wood.is_empty() and not seen.has(wood):
                seen[wood] = true
                result.append(wood)
            continue
        if seen.has(resource_id):
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


# --- The groups in the buy pool ---
#
# The buy pool can name a group instead of a concrete good. Such a row is a single
# demand ("the town wants fruit"), so it needs a single price and a single category —
# the window has no room for a per-member breakdown, and the town pays the same for
# whatever member it receives.

# The price of ONE unit of a group, in whole coins: the average market price of its
# members (with the dynamic multipliers of each). The average is the neutral reading of
# a group that has no price of its own: it does not follow the cheapest member, so a
# group row cannot be bought or sold at the price of its worst good. A group without a
# priced member costs nothing, and the trade refuses such an order.
static func get_group_price(group_key: String) -> int:
    var total := 0.0
    var count := 0
    for member in GameData.product_groups.get(group_key.trim_prefix("@"), []):
        var price := GameData.get_price(str(member))
        if price <= 0.0:
            continue
        total += price
        count += 1
    if count == 0:
        return 0
    return int(round(total / float(count)))


# The category a group row is filed under: the category of its first member that has
# one. The members of a group normally share a category (the fruits are fruits, the
# drinks are drinks); the first member is the tie-breaker of the data, not a rule of
# the game, and a group with no categorised member falls back to "other" — the same
# fallback a product without a category takes in the window.
static func get_group_category(group_key: String) -> String:
    for member in GameData.product_groups.get(group_key.trim_prefix("@"), []):
        var category := str(GameData.get_resource_data(str(member)).get("category", ""))
        if not category.is_empty():
            return category
    return "other"


# --- The warehouse (the storage of a town) ---
#
# The trade pools answer the question "what CAN the town trade", and the warehouse
# answers "how MUCH of it does the town have right now". The pools stay a set of
# product ids, and the warehouse is the quantity behind each of them.
#
# A town never goes into deficit: if it has decided to make something, it makes it,
# regardless of how many towns gather or import it. Therefore the INGREDIENTS of a
# recipe are never consumed and nothing is ever "out of stock" — the town's own
# production is not a real factory.
#
# The stock moves by daily TRADE: every town tick the town makes ONE trade per
# product — a purchase or a sale — and the size of that trade is drawn from a
# heavy-tailed distribution: an ordinary lot of a few units most days, occasionally a
# bulk caravan that strongly fills or drains the warehouse. That is what makes the
# number in the window go BOTH ways, like a real market, instead of climbing to the
# cap and stopping. The logic is tick_trade; the constants are town_trade_* in
# data/game_balance.json.

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
            # The timber of a forest plot is traded at the ordinary level — the
            # same one the production tick credits (main_map.gd).
            var wood := forest_plot_product(tile)
            if not wood.is_empty() \
                    and (not qualities.has(wood) or is_better_quality(DEFAULT_QUALITY, str(qualities[wood]))):
                qualities[wood] = DEFAULT_QUALITY
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


# --- The daily trade of a town ---
#
# Every town tick the town makes ONE TRADE per product — a purchase (the stock grows)
# or a sale (the stock shrinks) — so the stock moves both ways, like a real market.
#
# The DESIGN intent (agreed with the design owner):
#   * the player does not audit the income/expense curve. He walks into a town,
#     sees from the window that trade is happening, and looks at the STOCK and its
#     quantity to decide what to buy. So the curve only has to look alive and the
#     stock has to move at a believable rate;
#   * ordinary trades are small and predictable (the same few units most days);
#   * occasionally a BULK trade (a caravan) multiplies the lot several times over,
#     which is what visibly fills or drains the warehouse;
#   * the town is its OWN market and is NOT bound by the game-wide "10" floor the
#     recipes use — a lot of 3..6 units is normal for a town.
#
# Everything here is derived from the town record so that it is stable across a
# save: the RNG is seeded from (the town id, the trade counter), the counter is
# stored in the record, and the last direction is stored in the record too. A
# reload therefore replays the same sequence rather than reshuffling the warehouse.

# The stock the town treats as a healthy reserve — the level its buying/selling
# bias pulls it back toward, and the level at which buying and selling are equally
# likely.
#
# It is DERIVED, not a constant of its own: it is the midpoint of the range a town
# is born with (town_storage_initial_min .. town_storage_initial_max, 100..500 by
# default -> 300). The reasoning is that the range a town is GENERATED at is, by
# definition, what "a healthy reserve" means for this game, so the town drifts back
# toward the level it was born at rather than toward some invented number.
static func get_trade_comfort() -> float:
    var low := float(GameData.game_balance.get("town_storage_initial_min", 100))
    var high := float(GameData.game_balance.get("town_storage_initial_max", 500))
    if high < low:
        high = low
    return (low + high) * 0.5


# The bounds of an ORDINARY trade, in units. Floored at 0 so broken data cannot
# produce a negative lot.
static func get_trade_min() -> float:
    return maxf(0.0, float(GameData.game_balance.get("town_trade_min", 3)))


static func get_trade_max() -> float:
    var low := get_trade_min()
    var high := float(GameData.game_balance.get("town_trade_max", 15))
    return maxf(low, high)


# The size of ONE trade, in units. An ordinary lot is a flat draw from
# [min, max]; on a bulk day the SAME lot is multiplied by a factor from
# [town_trade_bulk_min, town_trade_bulk_max]. Multiplying the drawn lot (rather
# than drawing the bulk lot independently) is what keeps the two regimes tied
# together: a bulk trade is "the same day's trade, but a caravan".
static func roll_trade_size(rng: RandomNumberGenerator) -> float:
    var size := rng.randf_range(get_trade_min(), get_trade_max())
    var bulk_chance := clampf(
            float(GameData.game_balance.get("town_trade_bulk_chance", 0.06)), 0.0, 1.0)
    if rng.randf() < bulk_chance:
        var bulk_low := maxf(1.0, float(GameData.game_balance.get("town_trade_bulk_min", 3)))
        var bulk_high := maxf(bulk_low, float(GameData.game_balance.get("town_trade_bulk_max", 8)))
        size *= rng.randf_range(bulk_low, bulk_high)
    return size


# The next day's direction (+1 buy, -1 sell), given the current stock and the last
# direction. Two forces shape it:
#   * a shortage tilts the town toward buying, a full warehouse toward selling —
#     without this the stock is a PURE RANDOM WALK and, over a long game, half the
#     towns end up pinned at zero or at the cap for good;
#   * inertia repeats yesterday's direction, so rises and falls come in short runs
#     instead of alternating every single day.
static func roll_trade_sign(stock: float, last_sign: int,
        rng: RandomNumberGenerator) -> int:
    var comfort := get_trade_comfort()
    var fill := 0.5
    if comfort > 0.0:
        fill = clampf(stock / (comfort * 2.0), 0.0, 1.0)
    var bias := float(GameData.game_balance.get("town_trade_bias_strength", 0.6))
    # At fill = 0.5 (the comfort level) buying and selling are equally likely; the
    # empty warehouse pushes buy_chance up, the full one pushes it down.
    var buy_chance := clampf(0.5 + (0.5 - fill) * bias, 0.05, 0.95)
    var inertia := clampf(float(GameData.game_balance.get("town_trade_inertia", 0.65)),
            0.0, 1.0)
    if last_sign != 0 and rng.randf() < inertia:
        return last_sign
    return 1 if rng.randf() < buy_chance else -1


# ONE trade of ONE product of ONE town.
#
# It returns { "stock", "delta", "sign", "traded" }: the new stock (an integer,
# clamped to [0, limit]), the real movement, the direction of the day and the size
# of the lot. "sign" 0 means the day was a no-op, which can only happen at the cap —
# a forced sale is always possible while there is stock.
#
# stock / limit — the warehouse cell to move; the function does NOT write anything
#   (the caller owns the dictionary), it only computes;
# last_sign — the direction of the previous day, for inertia;
# rng       — the town's stream (seeded and advanced by the caller, see tick_trade).
#
# A sale can never take more than the warehouse holds: the lot is reduced to what is
# actually there, so the stock never goes negative and the player never sees a
# number that contradicts the log. A reduced lot below the ordinary minimum is FINE
# — the town's own floor is its 3..15 range, and clearing out the last few units is
# a normal end-of-day sale.
static func trade_once(stock: int, limit: int, last_sign: int,
        rng: RandomNumberGenerator) -> Dictionary:
    var current := clampi(stock, 0, limit)
    # An empty shelf has nothing to sell and a full one has no room to buy, so at the
    # edges the direction is forced instead of rolled. That keeps the rng stream free
    # of draws the warehouse could not honour, so the run lengths reflect trades that
    # actually happened.
    var direction := 0
    if current <= 0:
        direction = 1
    elif current >= limit:
        direction = -1
    else:
        direction = roll_trade_sign(float(current), last_sign, rng)
    if direction > 0:
        # A purchase cannot make the warehouse exceed the cap: the town only buys
        # what fits. At the cap there is nothing to buy.
        var room := limit - current
        if room <= 0:
            return {"stock": current, "delta": 0, "sign": 0, "traded": 0.0}
        var bought := minf(roll_trade_size(rng), float(room))
        var new_stock := current + int(round(bought))
        return {"stock": new_stock, "delta": new_stock - current,
                "sign": 1, "traded": bought}
    # A sale: never more than there is. An empty warehouse has nothing to sell.
    if current <= 0:
        return {"stock": 0, "delta": 0, "sign": 0, "traded": 0.0}
    var sold := minf(roll_trade_size(rng), float(current))
    var after := current - int(round(sold))
    return {"stock": after, "delta": after - current, "sign": -1, "traded": sold}


# ONE trade tick of the whole warehouse of a town: every product on the shelf is
# traded once, each with its own lot and its own direction.
#
# The per-product state lives in the record under "trade_signs" (product id -> last
# direction) and "trade_counter" (how many ticks this town has traded). Both are
# SAVED with the town — unlike the sell pool and the quality, which are recomputed
# from the ring — so that a reload replays the same sequence instead of reshuffling
# the warehouse.
#
# The stream: each tick builds a RandomNumberGenerator seeded from
# (the town id, the counter). It is NOT one long-lived generator, because a
# generator's position cannot be reconstructed from a seed alone after a reload —
# but (town, N) reproduces tick N exactly, so the trade is stable across a save and
# still advances from tick to tick.
#
# It returns the town's trade counter, so the caller can store it back.
static func tick_trade(storage: Dictionary, signs: Dictionary, counter: int,
        town_id: String, limit: int) -> int:
    var rng := RandomNumberGenerator.new()
    rng.seed = _seed_for(town_id, "trade:%d" % counter)
    for pid in storage.keys():
        var id := str(pid)
        if id.is_empty() or id == "<null>":
            continue
        var last_sign := int(signs.get(id, 0))
        var result := trade_once(int(storage[id]), limit, last_sign, rng)
        storage[id] = int(result["stock"])
        signs[id] = int(result["sign"])
    return counter + 1


static func tick_treasury(treasury: int, last_sign: int, counter: int,
        town_id: String) -> Dictionary:
    var rng := RandomNumberGenerator.new()
    rng.seed = _seed_for(town_id, "treasury:%d" % counter)
    var current := maxi(0, treasury)
    var comfort := float(GameData.game_balance.get("town_initial_treasury", 1000))
    if comfort <= 0.0:
        return {"treasury": current, "sign": 0, "counter": counter + 1}

    var recovery_threshold := comfort * clampf(
            float(GameData.game_balance.get("town_treasury_recovery_threshold", 0.15)),
            0.0, 1.0)
    var direction := _roll_treasury_trade_sign(float(current), comfort, last_sign, rng)
    var amount := roundi(_roll_treasury_trade_size(rng))
    if float(current) <= recovery_threshold:
        direction = 1
        var recovery_cap := maxf(1.0, comfort * maxf(0.0,
                float(GameData.game_balance.get("town_treasury_recovery_step", 0.02))))
        amount = mini(amount, roundi(recovery_cap))

    var delta := amount if direction > 0 else -mini(current, amount)
    return {"treasury": current + delta, "sign": direction if delta != 0 else 0,
            "counter": counter + 1}


static func _roll_treasury_trade_sign(treasury: float, comfort: float,
        last_sign: int, rng: RandomNumberGenerator) -> int:
    var fill := clampf(treasury / (comfort * 2.0), 0.0, 1.0)
    var bias := clampf(float(GameData.game_balance.get("town_treasury_bias_strength", 0.6)),
            0.0, 1.0)
    var income_chance := clampf(0.5 + (0.5 - fill) * bias, 0.05, 0.95)
    var inertia := clampf(float(GameData.game_balance.get("town_treasury_inertia", 0.65)),
            0.0, 1.0)
    if last_sign != 0 and rng.randf() < inertia:
        return last_sign
    return 1 if rng.randf() < income_chance else -1


static func _roll_treasury_trade_size(rng: RandomNumberGenerator) -> float:
    var low := maxf(0.0, float(GameData.game_balance.get("town_treasury_trade_min", 20)))
    var high := maxf(low, float(GameData.game_balance.get("town_treasury_trade_max", 120)))
    var size := rng.randf_range(low, high)
    var bulk_chance := clampf(
            float(GameData.game_balance.get("town_treasury_bulk_chance", 0.06)), 0.0, 1.0)
    if rng.randf() < bulk_chance:
        var bulk_low := maxf(1.0,
                float(GameData.game_balance.get("town_treasury_bulk_min", 3)))
        var bulk_high := maxf(bulk_low,
                float(GameData.game_balance.get("town_treasury_bulk_max", 8)))
        size *= rng.randf_range(bulk_low, bulk_high)
    return size


# --- The supply of a standing contract ---
#
# A standing contract draws goods from the warehouse of a town every tick, and the
# warehouse ALONE would run dry in seconds: the daily trade moves a few units a town
# tick, while a contract moves `amount` every tick of the city (four times faster). What
# backs a contract is therefore the town's own gathering and production, not the stock it
# happens to hold. The stock is only the buffer behind the delivery lag.
#
# The output of a town is virtual and has no building behind it: a town has no population
# limit and can raise as many workshops as it needs, so its rate is a design number and
# NOT "one building of every kind". It is bounded from above by the size of its own
# warehouse: a town that keeps a warehouse of a good can also restock it in a second, and
# nothing it does can outrun that (get_contract_ceiling).
#
# A town serves an order up to its COMFORT rate for free: the whole draw is covered, the
# warehouse is untouched and only breathes with the daily trade. Asked for more, the town
# strains — its output follows the order but always falls short of it, and the shortfall
# drains the stock. The larger the order, the faster the stock falls behind, until the
# warehouse runs dry and the contract is torn (get_contract_drain). That is how a player
# can still buy a town out, and why a huge contract tears in minutes while a modest one
# holds for a long time.

# The absolute ceiling of the rate of a town, in units per second: the average starting
# stock of a good read as a rate. Every town is capped by it, whatever the order.
static func get_contract_ceiling() -> float:
    var lo := float(GameData.game_balance.get("town_storage_initial_min", 100))
    var hi := float(GameData.game_balance.get("town_storage_initial_max", 500))
    return maxf(0.0, (lo + hi) * 0.5)


# The rate every town serves a standing contract with for free, in units per second: the
# comfort share of the ceiling (town_contract_comfort). Up to it the warehouse is not
# touched at all.
static func get_contract_comfort() -> float:
    var share := maxf(0.0, float(GameData.game_balance.get("town_contract_comfort", 0.1)))
    return get_contract_ceiling() * share


# How many units per second the warehouse of a town falls behind at a given order: the
# drain curve of the strain, anchored at twice the comfort rate (town_contract_drain) and
# grown by a power of the excess over the comfort rate (town_contract_drain_curve). It is
# never larger than the excess itself, so the town never supplies less than its comfort
# rate, and it is zero for an order that fits under the comfort rate.
static func get_contract_drain(demand_per_tick: float) -> float:
    var comfort := get_contract_comfort()
    if comfort <= 0.0:
        return 0.0
    var excess := demand_per_tick - comfort
    if excess <= 0.0:
        return 0.0
    var anchor := maxf(0.0, float(GameData.game_balance.get("town_contract_drain", 0.75)))
    var curve := maxf(0.0, float(GameData.game_balance.get("town_contract_drain_curve", 0.3)))
    return minf(anchor * pow(excess / comfort, curve), excess)


# The share of ONE tick of a standing contract the town covers from its own output, in
# units:
#
#   supply = order - drain, never above the ceiling of the town
#
# It follows the order exactly while the order fits under the comfort rate (the town keeps
# up and the warehouse is untouched) and falls behind it above, by get_contract_drain. A
# demand of zero is covered by nothing.
static func get_contract_supply(demand_per_tick: float) -> float:
    if demand_per_tick <= 0.0:
        return 0.0
    var supply := demand_per_tick - get_contract_drain(demand_per_tick)
    return minf(supply, get_contract_ceiling())


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
# made — a Dictionary set: the ids PRODUCED by crafting are put here (in
#        contrast to the base pool, which also includes the natural resources).
#
# The fixpoint is safe: the pool only grows, and the set of possible ids is finite,
# therefore the cycle completes. A safety pass counter — in case
# of a cycle due to an error in the data: it is better to stop with an incomplete pool than
# to hang at the start of the game.
static func _close_pool(pool: Dictionary, made: Dictionary,
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

# The buy keys to show, in a stable order. A concrete good that belongs to a group the
# town buys anyway is dropped: the group row already covers it, because the town accepts
# any member. Without this the window would show "Fruits" and "Grapes" beside it as two
# demands that are in fact one.
static func _buy_keys_without_covered(wanted: Dictionary) -> Array:
    var covered: Dictionary = {}
    for key in wanted:
        var group_key := str(key)
        if not group_key.begins_with("@"):
            continue
        for member in GameData.product_groups.get(group_key.substr(1), []):
            covered[str(member)] = true
    var result: Array = []
    for key in wanted:
        var id := str(key)
        if not id.begins_with("@") and covered.has(id):
            continue
        result.append(id)
    result.sort()
    return result

# The full calculation of the trade pools of the town.
#
# town_id   — the town identifier ("town_3"); it is part of the seed of all the rolls.
# base_ids  — the base pool from collect_base_resources.
#
# It returns { "sell_pool": Array, "buy_pool": Array, "quality": Dictionary }; both
# arrays are sorted, so that the same state gives the same result in printing and in
# the tests. The buy pool may carry @-group keys ("@fruits"): the town accepts any
# member of such a group, and the concrete goods are picked at the settlement. "quality"
# is the single level of every traded product (product id -> quality id): the ring yields
# carry the quality of the map hex, the crafted goods the weighted average of their
# ingredients.
static func build_pools(town_id: String, base_ids: Array,
        base_qualities: Dictionary = {}) -> Dictionary:
    var made: Dictionary = {}
    var imports: Dictionary = {}
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
    _close_pool(pool, made, qualities)

    # The import cascade: round by round, while a new import opens something.
    var rolls: Dictionary = {}
    # The keys the window shows in the purchase column: a direct import by its own id, a
    # group import by the GROUP key. The concrete member behind a group is a matter of the
    # settlement (town_trade_manager), not of the pool.
    var wanted: Dictionary = {}
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
                var is_group := missing_key.begins_with("@")
                var concrete := missing_key
                if is_group:
                    concrete = _pick_group_member(town_id, recipe_id, index,
                            missing_key.substr(1))
                index += 1
                if concrete.is_empty():
                    continue
                # The group is what the town wants; the representative exists only so the
                # closure can go on with a concrete id, and it is excluded from the sale
                # below as an imported good.
                wanted[missing_key if is_group else concrete] = true
                if imports.has(concrete):
                    continue
                imports[concrete] = true
                bought[concrete] = true
        if bought.is_empty():
            break
        for id in bought:
            pool[id] = true
        _close_pool(pool, made, qualities)

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
    var buy_ids: Array = _buy_keys_without_covered(wanted)
    # The quality of the CRAFTED goods on sale: an imported raw material is consumed by
    # the town and is never put on the stock, so only the made ids are read here. The
    # quality of the raw goods of the ring is filled by refresh_town, which alone has the
    # hexes (see the note there).
    var sell_quality: Dictionary = {}
    for id in made:
        if sell.has(id):
            sell_quality[id] = str(qualities.get(id, DEFAULT_QUALITY))
    return {
        "sell_pool": sell_ids, "buy_pool": buy_ids, "quality": sell_quality,
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

    # The trade state is pruned in step with the warehouse: the sign of a product
    # that is no longer for sale must go with it, otherwise a product that returns
    # to the pool later would inherit a stale direction. The counter is kept as is —
    # it is the town's stream position, not a per-product value.
    var signs: Dictionary = town.get("trade_signs", {})
    for id in signs.keys():
        if not for_sale.has(str(id)):
            signs.erase(id)
    town["trade_signs"] = signs
