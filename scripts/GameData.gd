@tool
extends Node

var terrains: Dictionary = {}
var covers: Dictionary = {}
var raw_resources: Dictionary = {}
var products: Dictionary = {}
var improvements: Dictionary = {}
var crafts: Array = []
var buildings: Array = []
var categories: Array = []
var technologies: Array = []
var groups: Array = []
var eras: Array = []
var product_groups: Dictionary = {}
var product_group_names: Dictionary = {}
var product_group_icons: Dictionary = {} # id -> the icon file name of the group ("" — not set)
var modifiers: Dictionary = {}
var price_modifiers: Dictionary = {} # resource_id -> { factor: the price multiplier }
var special_actions: Dictionary = {} # id -> special action data
var qualities: Dictionary = {} # data about resource quality levels
var map_config: Dictionary = {} # the world map configuration (data/map_config.json)
var professions: Dictionary = {} # id -> profession data (data/professions.json)
var consumption_rules: Array = [] # consumption entries (data/consumption.json)
var city_names: Array = [] # city name variants (data/city_names.json)
var game_balance: Dictionary = {} # the game balance (data/game_balance.json)
# The road levels (data/roads.json). roads_by_level — level -> level data:
# a road network segment stores a level number, therefore exactly such an index is needed.
var roads: Array = []
var roads_by_level: Dictionary = {}
# The fact that the data is already loaded. It is needed so as not to read data/*.json
# twice in a row: the main menu checks the data with the validator
# (scripts/data_validator.gd) on entry, and a new game loads them again.
# An analogue of SaveManager.is_loaded.
var data_loaded: bool = false
# Where each entity came from: "collection:id" → { "file": String, "line": int }.
# It is read by the runtime validator (scripts/data_validator.gd) in order to point a problem
# at a specific file and line, and not make it look for the typo manually.
var entity_sources: Dictionary = {}

func load_all_data():
    var loader = load("res://scripts/data_loader.gd").new()
    loader.load_all_data()
    terrains = loader.terrains
    covers = loader.covers
    raw_resources = loader.raw_resources
    products = loader.products
    improvements = loader.improvements
    crafts = loader.crafts
    buildings = loader.buildings
    categories = loader.categories
    technologies = loader.technologies
    groups = loader.groups
    eras = loader.eras
    product_groups = loader.product_groups
    product_group_names = loader.product_group_names
    product_group_icons = loader.product_group_icons
    modifiers = loader.modifiers
    special_actions = loader.special_actions
    qualities = loader.qualities
    map_config = loader.map_config
    professions = loader.professions
    consumption_rules = loader.consumption_rules
    city_names = loader.city_names
    game_balance = loader.game_balance
    roads = loader.roads
    roads_by_level = loader.roads_by_level
    entity_sources = loader.entity_sources
    data_loaded = true

# === ROAD LEVELS (data/roads.json) ===
#
# The level is an integer, starting from 1. A road network segment stores exactly
# the level number, therefore roads_by_level is the working index.

# The data of the level by its number. An empty dictionary — if the level is not in the data:
# the caller decides itself what to do (usually this is a data error, and it is caught by
# data_validator.gd, and not by a silent substitution "to the level below").
func get_road_by_level(level: int) -> Dictionary:
    return roads_by_level.get(level, {})

# The name of the level for the player (already translated by data_loader).
func get_road_name(level: int) -> String:
    var road: Dictionary = get_road_by_level(level)
    if road.is_empty():
        return str(level)
    return str(road.get("name", level))

# The base price of ONE segment of this level in labour, before the multipliers.
func get_road_work_cost(level: int) -> int:
    return int(get_road_by_level(level).get("work_cost", 0))

# The "maximum speed" of the level: how many units of resource per second this
# segment is able to carry (NOT the speed of units — see the header of data/roads.json).
func get_road_max_speed(level: int) -> int:
    return int(get_road_by_level(level).get("max_speed", 0))

# Is the level unlocked for the player. A level without unlock_tech is always available; otherwise
# the corresponding technology is needed. An unknown level is considered locked:
# showing the player a road that is not in the data is worse than not showing it.
#
# The unlock_tech field in JSON is sometimes null (the trail has no technology), therefore
# the value is read via _road_unlock_tech: `null or ""` in GDScript does NOT give
# a string, and a naive is_empty() check would let null into CityData.
func is_road_level_unlocked(level: int) -> bool:
    var road: Dictionary = get_road_by_level(level)
    if road.is_empty():
        return false
    var tech_id := _road_unlock_tech(level)
    if tech_id.is_empty():
        return true
    return CityData.is_tech_unlocked(tech_id)

# The id of the technology that unlocks the level; "" — the level is available from the start.
func _road_unlock_tech(level: int) -> String:
    var raw = get_road_by_level(level).get("unlock_tech", null)
    if raw == null or not (raw is String):
        return ""
    return str(raw)

# All the levels by ascending number — the order of selection in the control panel.
# The sorting is needed, because in the JSON the levels go in order, and one cannot rely
# on the order of the keys of a dictionary.
func get_road_levels() -> Array:
    var levels: Array = roads_by_level.keys()
    levels.sort()
    return levels

# The researched levels by ascending — exactly those the player can choose.
func get_unlocked_road_levels() -> Array:
    var result: Array = []
    for level in get_road_levels():
        if is_road_level_unlocked(int(level)):
            result.append(int(level))
    return result

# The most advanced researched level — the one that is offered by default.
# There should not be a level in the data, but if the data files are not loaded yet,
# we return 1: the trail is always available and nothing breaks.
func get_max_unlocked_road_level() -> int:
    var levels: Array = get_unlocked_road_levels()
    if levels.is_empty():
        return 1
    return int(levels.back())

# Returns a random city name from data/city_names.json.
# If the list is empty or not loaded — it returns a neutral default name.
func get_random_city_name() -> String:
    if city_names.is_empty():
        return tr("City")
    return city_names[randi() % city_names.size()]

# Returns the name of the group by its key (with or without the "@" symbol).
# If the key is not a group, it returns an empty string.
func get_product_group_name(key: String) -> String:
    var gkey = key.trim_prefix("@")
    if product_group_names.has(gkey):
        return product_group_names[gkey]
    return ""

# The icon of the product group for the "Trade" card + the source of this icon.
# The priority of the choice:
#   1. the own "icon" field of the group (data/product_groups.json) — the data
#      author has explicitly chosen a pictogram for the group;
#   2. the icon of the FIRST member of the group that has an icon set (the old order,
#      backward compatibility for the groups without their own "icon").
# The second branch is needed, because the first member of a group is often not a
# representative of the group: for "Alcohol" it is beer, although the group is grain
# beverages.
#
# It returns { "icon": String, "source_pid": String, "own": bool }:
#   icon      — the icon file name ("" — there is no icon, the caller hides the node);
#   source_pid — the id of the product whose icon is used ("" for the own icon of the group);
#   own       — true, if the icon is set by the group itself. The card shows
#               the source in the tooltip: without it the player does not understand why
#               a jug is drawn for "Alcohol".
func get_product_group_icon_info(key: String) -> Dictionary:
    var gkey = key.trim_prefix("@")
    if not product_groups.has(gkey):
        return {"icon": "", "source_pid": "", "own": false}
    var own_icon: String = str(product_group_icons.get(gkey, ""))
    if not own_icon.is_empty():
        return {"icon": own_icon, "source_pid": "", "own": true}
    for pid in product_groups[gkey]:
        var icon: String = str(products.get(pid, {}).get("icon", ""))
        if not icon.is_empty():
            return {"icon": icon, "source_pid": str(pid), "own": false}
    return {"icon": "", "source_pid": "", "own": false}

# Only the icon file name of the group — for the places where the source of the icon is not needed.
func get_product_group_icon(key: String) -> String:
    return str(get_product_group_icon_info(key).get("icon", ""))


# Returns the list of the human-readable names of the products that are members of the group.
# If the key is not a group, it returns an empty array.
func get_product_group_member_names(key: String) -> Array:
    var gkey = key.trim_prefix("@")
    if not product_groups.has(gkey):
        return []
    var names = []
    for prod_id in product_groups[gkey]:
        names.append(products.get(prod_id, {}).get("name", prod_id))
    return names

# Is the resource key a group one (does it start with "@")?
func is_group_key(key: String) -> bool:
    return key.begins_with("@")

# Formats the resource entry of a recipe: for the group keys it returns
# "Group name - amount", otherwise "Product name - amount".
func format_resource_input(key: String, amount: float) -> String:
    if is_group_key(key):
        var group_name = get_product_group_name(key)
        if group_name != "":
            return "%s - %d" % [group_name, int(amount)]
        # The group was not found — we show the key without the "@"
        return "%s - %d" % [key.trim_prefix("@"), int(amount)]
    return "%s - %d" % [products.get(key, {}).get("name", key), int(amount)]

# Formats the name of the resource for display in the interface (the costs, the stocks).
# For the group resources it returns only the name of the group (without the list of members).
func format_resource_name(key: String) -> String:
    if is_group_key(key):
        var group_name = get_product_group_name(key)
        if group_name != "":
            return group_name
        return key.trim_prefix("@")
    # The sale pool can contain both the products and the raw resources.
    var resource_data := get_resource_data(key)
    return str(resource_data.get("name", key))

func get_special_yield(product_id: String) -> Dictionary:
    return products.get(product_id, {}).get("special_yield", {})

# --- THE PRICES OF THE RESOURCES ---
# The base price is set in the JSON (the "price" field of the resource/product). The final price
# can change dynamically through the multipliers: for example, the famine raises the prices
# of the food, an excess supply or an erosion of the market — lowers them. The multipliers
# are multiplied by each other, the total = base × the product of all the active ones.
# The details are in docs.md, the section "Resource prices".

# Returns the data of the resource/product (raw material or product) by id.
func get_resource_data(res_id: String) -> Dictionary:
    if raw_resources.has(res_id):
        return raw_resources[res_id]
    if products.has(res_id):
        return products[res_id]
    return {}

# The base price from the JSON (the "price" field). If the field is absent — 0.
func get_base_price(res_id: String) -> float:
    return float(get_resource_data(res_id).get("price", 0.0))

# The product of all the active price multipliers of the resource (with no active ones — 1.0).
func get_price_multiplier(res_id: String) -> float:
    var total := 1.0
    var mods: Dictionary = price_modifiers.get(res_id, {})
    for factor in mods:
        total *= float(mods[factor])
    return total

# The final price of the resource at the current moment: base × the active multipliers.
func get_price(res_id: String) -> float:
    return get_base_price(res_id) * get_price_multiplier(res_id)

# Enables the price multiplier (factor — the name of the factor, e.g. "famine" or
# "market_glut"). The effect is applied to a particular resource by its id; in order to
# spread it to a group, apply it to all the members of the group.
func apply_price_modifier(res_id: String, factor: String, multiplier: float):
    if not price_modifiers.has(res_id):
        price_modifiers[res_id] = {}
    price_modifiers[res_id][factor] = multiplier

# Disables one factor-multiplier of the price of the resource.
func remove_price_modifier(res_id: String, factor: String):
    if price_modifiers.has(res_id):
        price_modifiers[res_id].erase(factor)
        if price_modifiers[res_id].is_empty():
            price_modifiers.erase(res_id)

# Resets ALL the dynamic price multipliers (the prices return to the base ones).
func clear_price_modifiers():
    price_modifiers.clear()

func get_building_additional_yield(building_id: String) -> Dictionary:
    for building in buildings:
        if building.get("id", "") == building_id:
            return building.get("additional_yield", {})
    return {}

# Normalizes the additional_cost field into an array of dictionaries {resource: amount}.
# It supports two forms:
#   1) an object:         { "flour": 3.0, "wood": 10.0 }        → [ { "flour": 3.0, "wood": 10.0 } ]
#   2) an array of batches: [ { "flour": 3.0 }, { "gold": 50.0 } ]  → as is
# The logic of the AND-combination of the batches: the resources from EACH batch are needed at the same time.
# It returns an empty array for null/invalid values.
func parse_additional_cost(raw) -> Array:
    var result: Array = []
    if raw == null:
        return result
    if raw is Dictionary:
        if raw.is_empty():
            return result
        return [raw]
    if raw is Array:
        for item in raw:
            if item is Dictionary and not item.is_empty():
                result.append(item)
        return result
    return result

# --- ALTERNATIVE INGREDIENTS IN RECIPES ---
#
# The "resources" field of a recipe (data/crafts/*.json) allows a variant of the
# ingredient slot by analogy with the prerequisites of the technologies and the
# additional spawn conditions of the resources:
#
#   1) an object (the classical form):       { "iron": 20, "coal": 10 }
#   2) an array of terms:                    [ {"iron": 20}, {"coal": 10} ]
#   3) a term as an array of objects (OR):   [ [ {"iron": 20}, {"meteorite_iron": 20} ], {"coal": 10} ]
#
# A term is ALWAYS a dictionary (one key) or an array of dictionaries. An array of
# dictionaries within one term means OR: ANY of the listed variants is enough.
# The terms of the outer level (the element of the array) are joined by AND —
# all of them are needed simultaneously. The keys of the dictionaries are allowed the
# same as in the classical form: a product, a raw material, or an @-group.
#
# The normalized form is ALWAYS an array of OR-groups: [ [ {"iron": 20} ], [ {"coal": 10} ] ] —
# the terms with one alternative remain one-element arrays, therefore the consumer
# does not need to distinguish the forms. An empty array (a recipe without the
# ingredients) is returned as an empty array.
#
# parse_craft_resources() — the normalizer itself; craft_alternatives() — a convenience
# wrapper for the places where the OR-logic has to be applied manually (the container of
# the craft, the planned demand, the trade pools of the towns).
#
# The amounts within an OR-group are deliberately NOT required to be equal: the chosen
# variant is consumed in full, and which one — is decided by the availability in the storage.
# Within a tick the variants are consumed greedily in the order of the list: if the
# first variant has less than the tick asks, the remainder is taken from the next one,
# so a partial stock is never wasted.
#
# The normalization is deliberately in GameData and not in CraftContainer: besides the
# container the alternatives are read by the planned demand, the trade pools of the
# towns and the UI of the recipes — a single source of the form guarantees that they all
# understand the data identically.

# Brings the "resources" field of a recipe to the normalized form: an array of OR-groups.
# See the comment above the function for the admissible forms.
func parse_craft_resources(raw) -> Array:
    var out: Array = []
    if raw is Dictionary:
        # The classical form: every key is an independent term.
        for res_key in raw.keys():
            var amount := int(raw[res_key])
            if amount <= 0:
                continue
            out.append([_ingredient_variant(str(res_key), amount)])
        return out
    if not (raw is Array):
        return out
    for term in raw:
        var variants: Array = []
        if term is Dictionary:
            variants = _ingredient_variants_of_dict(term)
        elif term is Array:
            # A term as an array: an explicit OR of the dictionaries.
            # (A bare string in a term is unusable: it has no amount of its own;
            # it is shown by the validator as a data format problem and is
            # silently skipped here.)
            for variant in term:
                if variant is Dictionary:
                    variants.append_array(_ingredient_variants_of_dict(variant))
                    # A bare string has no amount of its own — we show it in the
                    # validator window (see data_validator, kind "resource"), and
                    # here we skip: a variant without the amount is unusable.
                    pass
        if variants.is_empty():
            continue
        out.append(variants)
    return out

# One dictionary of the term → an array of single-key variants (usually one element).
# The empty/non-positive amounts are discarded: they are not an ingredient.
func _ingredient_variants_of_dict(dict_term: Dictionary) -> Array:
    var variants: Array = []
    for res_key in dict_term.keys():
        var amount := int(dict_term[res_key])
        if amount <= 0:
            continue
        variants.append(_ingredient_variant(str(res_key), amount))
    return variants

# A single variant of the ingredient: { "key": "pid|@group", "amount": N }.
func _ingredient_variant(key: String, amount: int) -> Dictionary:
    return { "key": key, "amount": amount }

# The alternatives of the ingredients of the recipe (the normalized form).
# A convenience wrapper over parse_craft_resources for the consumers of the logic.
func craft_alternatives(recipe: Dictionary) -> Array:
    return parse_craft_resources(recipe.get("resources", null))

# Is the ingredient key available in the pool set (Dictionary of the id → true)?
# The mirror of TownEconomy.is_available — in GameData, so that the normalization of the
# alternatives does not depend on the trade module. The group key is available, if at least
# ONE member is in the pool (the same semantics as in get_storage_amount).
func is_key_available(key: String, pool: Dictionary) -> bool:
    if pool.has(key):
        return true
    if not is_group_key(key):
        return false
    for member in product_groups.get(key.substr(1), []):
        if pool.has(str(member)):
            return true
    return false

# How many units of the resource/group are there in the storage?
# For an ordinary key (for example, "flour") it returns storage.get(key, 0).
# For a group key (for example, "@millable_grains") — the sum over all the members
# of the group from product_groups. This is "any product from the group", as in the recipes.
# If the group is not found — it returns 0.
func get_storage_amount(key: String, storage: Dictionary) -> float:
    if is_group_key(key):
        var group_key = key.trim_prefix("@")
        var group_products = product_groups.get(group_key, [])
        if group_products.is_empty():
            return 0.0
        var total := 0.0
        for prod_id in group_products:
            total += float(storage.get(prod_id, 0))
        return total
    return float(storage.get(key, 0))

# --- THE HELPERS FOR WORKING WITH THE QUALITY OF THE RESOURCES ---
# The data is loaded from data/qualities.json into the qualities field.

# Returns the list of the ids of the quality levels in the order from the worst to the best.
func get_quality_levels() -> Array:
    var levels = []
    for q in qualities.get("quality_levels", []):
        if q is Dictionary and q.has("id"):
            levels.append(q["id"])
    return levels

# Returns the data of the quality level by id (or an empty dictionary).
func get_quality_data(quality_id: String) -> Dictionary:
    for q in qualities.get("quality_levels", []):
        if q is Dictionary and q.get("id", "") == quality_id:
            return q
    return {}

# Returns the human-readable name of the quality level.
func get_quality_name(quality_id: String) -> String:
    return get_quality_data(quality_id).get("name", quality_id)

# Returns the numeric weight of the quality level (for the weighted average).
func get_quality_value(quality_id: String) -> int:
    return int(get_quality_data(quality_id).get("value", 1))

# Returns the string of stars for the quality level (for example, "★★★").
func get_quality_stars(quality_id: String) -> String:
    return get_quality_data(quality_id).get("stars", "")

# --- THE COLOUR OF THE QUALITY LEVEL (data/qualities.json, the color field) ---
# The colour is set as an [R, G, B] array in the range 0…255 — the same entry format as for
# the covers (data/covers.json), the improvements and the resources. It paints the stars in the tooltip
# of the quality breakdown, the rows of the price ladder in the row tooltip, and the percentages of the share
# of the level in the row of the list (resources_tab._update_quality_label).
# A soft default: the color field is absent (old data) or it is not an array of three
# numbers — a light grey, so that the interface does not go haywire on broken data.
const QUALITY_COLOR_FALLBACK := Color(0.8, 0.8, 0.8)

func get_quality_color(quality_id: String) -> Color:
    var c = get_quality_data(quality_id).get("color", null)
    if c is Array and c.size() == 3:
        return Color(float(c[0]) / 255.0, float(c[1]) / 255.0, float(c[2]) / 255.0)
    return QUALITY_COLOR_FALLBACK

# --- THE PRICE BY QUALITY (data/qualities.json, the price_multiplier field) ---
# The multiplier is multiplied by the price of one unit of the product: the better quality is more expensive.
# A multiplier, and not a fixed addition in coins — so that the markup is
# proportional over the whole price scale (1…150), see the header of qualities.json.

# The price multiplier of the quality level. For "common", an unknown id and any
# level without the field — 1.0 (a soft default: the quality does not break the price, even
# if the field was forgotten or the data is old).
func get_quality_price_multiplier(quality_id: String) -> float:
    var m = float(get_quality_data(quality_id).get("price_multiplier", 1.0))
    if m <= 0.0:
        return 1.0
    return m

# The current price of one unit of the product taking the quality into account: the price (base × the dynamic
# market multipliers) × the quality multiplier. The fractional result — the rounding
# is done by the caller (WHOLE coins are needed, see get_price_breakdown_for_quality).
func get_price_for_quality(res_id: String, quality_id: String) -> float:
    return get_price(res_id) * get_quality_price_multiplier(quality_id)

# The breakdown of the price of one unit of the product by quality for the tooltip:
#   { "base": int, "multiplier": float, "total": int }
# The base (the current price with the dynamic market multipliers) is rounded to a
# whole number ONCE, the total is round(base × the quality multiplier). All the numbers in
# the tooltip are whole, except for the multiplier itself — it is shown as a separate
# addend: "Price: 4 * 1.30 (★★) = 5".
# For a product without a price (for example, the pseudo-resource science) — zeros.
func get_price_breakdown_for_quality(res_id: String, quality_id: String) -> Dictionary:
    var mult := get_quality_price_multiplier(quality_id)
    var base := int(round(get_price(res_id)))
    if base <= 0:
        return {"base": 0, "multiplier": mult, "total": 0}
    return {"base": base, "multiplier": mult, "total": int(round(float(base) * mult))}

# The tail of the row of the price of the quality level for the row tooltip of the "Resources" tab —
#   " = x1.30 = 5", that is, everything EXCEPT the stars.
# The stars are returned separately not for the sake of beauty, but because of the design
# requirement: in the row tooltip the stars are painted in the colour of the level (data/qualities.json, color), and
# the price calculation itself — in gold (ui_helpers.PRICE_TEXT_COLOR), and by one Label with
# one colour for the whole row this cannot be expressed.
# An empty string if there is nothing to show: the product has no price or the level
# is not in the scale (without the stars there is nothing to assemble the row from).
func format_quality_price_tail(res_id: String, quality_id: String) -> String:
    if quality_id.is_empty() or not get_quality_levels().has(quality_id):
        return ""
    var d = get_price_breakdown_for_quality(res_id, quality_id)
    if int(d["total"]) <= 0:
        return ""
    return " = x%s = %d" % [
        "%.2f" % float(d["multiplier"]), int(d["total"])
    ]

# The row of the price of the quality level for the row tooltip of the "Resources" tab:
#   "★★ = x1.30 = 5"
# It is assembled from the stars of the level and the tail above — both parts are taken from the data, so
# that the text of the row and its parts (the stars separately, the calculation separately) cannot
# diverge.
# The "Price:" label in the row is not needed: the level is already named by the stars, and above
# the block of the ladder there is already the base "Price: N" of the same product.
# The row is assembled for ANY level of the scale, including the lowest one
# ("★ = x1.00 = 4"): the ladder is read as one table, where the multiplier is visible
# for each level, and not starting from the middle. Previously the bottom level
# was discarded, and for a storage where only the common quality lies, there was no block
# at all — it was not visible that the multiplier 1.0 is also a multiplier.
# An empty string if there is nothing to show: the product has no price or the level
# is not in the scale (without the stars there is nothing to assemble the row from).
func format_quality_price_line(res_id: String, quality_id: String) -> String:
    var tail := format_quality_price_tail(res_id, quality_id)
    if tail == "":
        return ""
    return get_quality_stars(quality_id) + tail

# The prices by the quality levels that are REALLY in the storage, for the row tooltip
# of the "Resources" tab. Only the levels that are present in
# quality_breakdown ({quality_id: count} — the breakdown of the storage from
# CityData.city_quality_detail, see CityData.get_quality_breakdown): the price of the
# "exceptional" level, which is not in the storage, is pointless to show — that
# is misleading.
# The levels are output from the worst to the best (the order of data/qualities.json).
# It returns an array of records:
#   { "qid":   quality_id,
#     "stars": "★★",        ← the stars of the level, painted in its colour
#     "tail":  " = x1.30 = 5" ← the price calculation itself, painted in gold,
#     "text":  "★★ = x1.30 = 5" }
# The stars and the tail are returned SEPARATELY, because the row tooltip paints them in different
# colours (the stars — the colour of the level from data/qualities.json, the calculation — gold), and
# text remains a whole ready row for those whom one colour is enough.
# The caller needs qid in order to paint the stars in the colour of the level
# (get_quality_color) — in this way the text of the row and its colour cannot diverge.
# An empty array: the product has no price (for example, science) or the id is not set.
func format_quality_price_scale_rows(res_id: String, quality_breakdown: Dictionary = {}) -> Array:
    var rows: Array = []
    if res_id.is_empty() or get_base_price(res_id) <= 0.0:
        return rows
    for qid in get_quality_levels():
        # The level is not in the storage — the price is not shown (including count == 0).
        if int(quality_breakdown.get(qid, 0)) <= 0:
            continue
        var tail := format_quality_price_tail(res_id, str(qid))
        if tail == "":
            continue
        var stars := get_quality_stars(str(qid))
        rows.append({"qid": str(qid), "stars": stars, "tail": tail, "text": stars + tail})
    return rows

# --- THE SHARE OF THE LEVEL IN THE STORAGE (the percentages in the row of the list and in the breakdown tooltip) ---
# The percent of count from the sum of the whole breakdown: the shares are computed from the TOTAL amount
# of the product in the storage, therefore in the sum they show ~100% (and not the share of the best
# level from the others — which is why the row "★ (67%)" was read as "two thirds
# of the storage is good").
# The percentages are rounded separately, therefore the sum may differ by
# one unit (33%/33%/33%): "patching" them up to exactly 100% would mean lying about
# the fractional shares. With an empty or zero breakdown — 0.
func get_quality_share_percent(count: int, quality_breakdown: Dictionary) -> int:
    var total := 0
    for qid in quality_breakdown:
        total += int(quality_breakdown[qid])
    if total <= 0:
        return 0
    return int(round(float(count) / float(total) * 100.0))

# The breakdown of the storage as a string for the row of the resource list:
#   "(33%/67%)" — the share of each level that is really in the storage, in the colour
# of that level (data/qualities.json, color). The levels from the worst to the best, as
# in data/qualities.json; the levels with a zero count are skipped.
# It returns BBCode (the [color=…] tags) for a Label with bbcode_enabled:
# in one text all the levels are visible, and each percentage is painted in the colour of its
# level. An empty string if the breakdown is empty or contains only zeros.
func format_quality_share_text(quality_breakdown: Dictionary) -> String:
    var parts: Array = []
    for qid in get_quality_levels():
        var count := int(quality_breakdown.get(qid, 0))
        if count <= 0:
            continue
        parts.append("[color=#%s]%d%%[/color]" % [
            get_quality_color(str(qid)).to_html(false),
            get_quality_share_percent(count, quality_breakdown)
        ])
    if parts.is_empty():
        return ""
    return "(" + "/".join(parts) + ")"

# Randomly chooses the quality level by the spawn_weight weights.
func roll_quality() -> String:
    var levels = get_quality_levels()
    if levels.is_empty():
        return "common"
    var total := 0.0
    for qid in levels:
        total += float(get_quality_data(qid).get("spawn_weight", 1))
    if total <= 0.0:
        return levels[0]
    var roll = randf() * total
    var accum := 0.0
    var chosen: String = levels[levels.size() - 1]
    for qid in levels:
        accum += float(get_quality_data(qid).get("spawn_weight", 1))
        if roll < accum:
            chosen = qid
            break
    return chosen

# Returns the default priority of choosing raw materials (from qualities.json).
func get_quality_priority_default() -> String:
    return qualities.get("priority_default", "best")

# Returns the list of the available priorities of choosing raw materials.
func get_quality_priority_options() -> Array:
    return qualities.get("priority_options", ["best", "worst", "random"])

# Returns the human-readable name of the priority of choosing raw materials.
func get_quality_priority_name(priority: String) -> String:
    var names: Dictionary = qualities.get("priority_names", {})
    return names.get(priority, priority)

# --- THE PROFESSIONS AND THE CONSUMPTION ---

# Returns the data of the profession by id (or an empty dictionary).
func get_profession(prof_id: String) -> Dictionary:
    return professions.get(prof_id, {})

# Returns the name of the profession in the singular nominative form ("Farmer").
# If the id is not found — it returns the id itself as a fallback.
func get_profession_name(prof_id: String) -> String:
    if prof_id.is_empty():
        return ""
    return professions.get(prof_id, {}).get("name", prof_id)

# Returns the profession associated with the improvement (the id from data/improvements.json).
# If the improvement is not set or it has no profession — it returns "".
# The label is derived from the improvement and is not displayed in the interface as a
# separate row: it is used by the consumption calculation and by the planned map of
# the "Resources" tab.
func get_profession_for_improvement(imp_id: String) -> String:
    if imp_id.is_empty() or imp_id == null:
        return ""
    return improvements.get(imp_id, {}).get("profession", "")

# Returns the data of the building by id (or an empty dictionary, if the building is not found).
func get_building_data(building_id: String) -> Dictionary:
    if building_id.is_empty() or building_id == null:
        return {}
    for b in buildings:
        if b.get("id", "") == building_id:
            return b
    return {}

# Returns the profession of the citizen working in the building (the "profession" field in
# data/buildings.json). Empty — the building has no profession: it works by the general
# slot model, without the expense of supplies and without a bonus (see docs.md,
# "Professions and resource consumption").
func get_profession_for_building(building_id: String) -> String:
    return get_building_data(building_id).get("profession", "")

# Returns true if the improvement is infrastructure one — it does not require a worker
# to perform its functions. The flag is set by the "no_worker": true field in
# data/improvements.json (for example, a harbor, the harbor_access scheme).
# It is used by worker_manager (an exception from the auto-assignment), by the control
# panel (without the start/pause buttons) and by the tooltip (a special status).
func is_no_worker_improvement(imp_id: String) -> bool:
    if imp_id.is_empty() or imp_id == null:
        return false
    return improvements.get(imp_id, {}).get("no_worker", false)

# The human-readable name of the improvement by id (or the id itself, if the improvement is not
# in the registry). The name is already translated by the data loader (data_loader.
# _localize_display_fields), therefore an additional tr() is not needed here.
func get_improvement_display_name(imp_id: String) -> String:
    if imp_id.is_empty():
        return ""
    return improvements.get(imp_id, {}).get("name", imp_id)

# The human-readable name of the building by id (or the id itself, if the building is not in the registry).
func get_building_display_name(building_id: String) -> String:
    if building_id.is_empty():
        return ""
    return get_building_data(building_id).get("name", building_id)

# --- THE SOURCES OF THE FLOW: IDENTIFIER → LABEL ---
#
# The sources of income/expense (the professions, the buildings, the improvements, the service rows)
# are addressed in the planned maps and the accumulators of the treasury by an IDENTIFIER, and not by
# a name. The name is only a label in the interface, and it is resolved here, at the point
# of the drawing. In this way the keys do not depend on the language (LocalizationManager.set_locale
# re-reads the data, but does not reset the accumulators — a change of language in the middle
# of the accumulation window should not split one source in two) and do not merge when
# the names coincide.
#
# The prefix separates the namespaces: the id "smelter" exists both for a profession
# (data/professions.json) and for a building (data/buildings.json), and in the planned
# maps both go into one dictionary — without the prefix the rows would merge.
#   "@prof:<id>" — a profession (including the pseudo-profession "all");
#   "@bld:<id>"  — a city building;
#   "@imp:<id>"  — an improvement on a hex;
#   "@pop_food"  — the feeding of the population (there is no separate entity in the data);
#   "@scouting" / "@claim" — the one-off treasury costs (scouting, claiming a chunk).
# The service sources store the English text in the key, like TAX_INCOME_TYPE:
# tr() cannot be called in a constant expression, the translation is applied by the resolver.
const SRC_PREFIX_PROFESSION := "@prof:"
const SRC_PREFIX_BUILDING := "@bld:"
const SRC_PREFIX_IMPROVEMENT := "@imp:"
const SRC_POP_FOOD := "@pop_food"
const SRC_SCOUTING := "@scouting"
const SRC_CLAIMING := "@claim"

    # The source identifier for a data entity. An empty id gives an empty key —
    # a record without a source does not go into the plans (the callers check this before writing).
func profession_source_id(prof_id: String) -> String:
    return SRC_PREFIX_PROFESSION + prof_id

func building_source_id(building_id: String) -> String:
    return SRC_PREFIX_BUILDING + building_id

func improvement_source_id(imp_id: String) -> String:
    return SRC_PREFIX_IMPROVEMENT + imp_id

# The source label for the interface: identifier → human-readable name.
# An unknown source is returned as is — a missing entry in the data
# should be visible as "smelter", and not to be silent with an empty string.
func get_source_display_name(source_id: String) -> String:
    if source_id.is_empty():
        return ""
    if source_id == SRC_POP_FOOD:
        return tr("Population food")
    if source_id == SRC_SCOUTING:
        return tr("Scouting")
    if source_id == SRC_CLAIMING:
        return tr("Claiming land chunks")
    if source_id.begins_with(SRC_PREFIX_PROFESSION):
        return get_profession_name(source_id.substr(SRC_PREFIX_PROFESSION.length()))
    if source_id.begins_with(SRC_PREFIX_BUILDING):
        return get_building_display_name(source_id.substr(SRC_PREFIX_BUILDING.length()))
    if source_id.begins_with(SRC_PREFIX_IMPROVEMENT):
        return get_improvement_display_name(source_id.substr(SRC_PREFIX_IMPROVEMENT.length()))
    return source_id

# Assembles the consumption record from the rule of data/consumption.json.
# res_key — the "resource" field of the rule ("product_id" or "@group_id").
# For a group the members are resolved through product_groups; if the group is not found
# or amount <= 0 — an empty dictionary is returned (the record is skipped).
func _build_consumption_entry(res_key: String, rule: Dictionary) -> Dictionary:
    var amount := int(rule.get("amount", 0))
    if amount <= 0:
        print("GameData: a consumption rule without a correct amount is skipped: ", rule)
        return {}
    var entry := {
        "amount": amount,
        "interval": float(rule.get("interval", 0)),
        "production_bonus": float(rule.get("production_bonus", 0.0))
    }
    if is_group_key(res_key):
        var gkey = res_key.trim_prefix("@")
        # The key of an "@"-group is always the id from data/product_groups.json. A search by
        # the human-readable name is intentionally absent here: such a fallback would silently
        # substitute the data of a similar group and would break the addressing.
        var members: Array = product_groups.get(gkey, [])
        if members.is_empty():
            print("GameData: the group '", res_key, "' from data/consumption.json was not found — the record is skipped.")
            return {}
        entry["product_id"] = "" # a group record is not bound to a product
        entry["product_name"] = get_product_group_name(res_key)
        entry["is_group"] = true
        entry["group_members"] = members.duplicate()
        entry["display_key"] = res_key
        # The icon of the group — its own, if it is set in data/product_groups.json,
        # otherwise the first icon among the members (GameData.get_product_group_icon_info).
        # Previously there was a separate walk of the members here, duplicating the rule.
        entry["icon"] = get_product_group_icon(res_key)
    else:
        # A non-existent product: previously the record was created anyway, with
        # an identifier as the label and an empty icon, and it quietly hung in the
        # interface without ever writing anything off. Now it is visible in the console —
        # plus the same error is shown by data_validator as a data problem.
        if not products.has(res_key):
            print("GameData: the product '", res_key, "' from data/consumption.json was not found — the record is skipped.")
            return {}
        entry["product_id"] = res_key
        entry["product_name"] = products.get(res_key, {}).get("name", res_key)
        entry["is_group"] = false
        entry["group_members"] = []
        entry["display_key"] = res_key
        entry["icon"] = products.get(res_key, {}).get("icon", "")
    return entry

# Returns the consumption records that CONSUME the given resource — the reverse of
# get_profession_consumption.
#
# The argument may be either form of the address of a resource:
#   * the id of a product ("reed_boat") — the form a row of a recipe or of a cost
#     names the resource by;
#   * "@<group_id>" ("@boats") — the group reference itself.
# A rule of the registry that names a group consumes ANY member of it, so a product
# query also matches the group rules whose group contains the product. This is what
# makes the marking visible in the recipes: a recipe lists concrete products, while
# the rule that spends them most often speaks about the group.
#
# A group query matches only the rules that name the group itself. Its members are
# deliberately NOT expanded into their own rules: the question "can this row be spent
# by somebody" is answered for the row the player sees, and a group row stands for
# the group, not for every product that happens to share a rule with it.
#
# Every row:
#   { "profession_id": String, "profession_name": String, — who consumes it
#     "amount": int, "interval": float,                — the norm per one consumer
#     "production_bonus": float,
#     "via_group": String }                             — "@<group_id>" when the
#                                                         resource is consumed as a
#                                                         member of a group, else ""
# The pseudo-profession "all" is a legitimate consumer here: it is what the player
# sees as "the whole city" (the name is taken from professions.json).
func get_consumption_consumers(res_key: String) -> Array:
    var result: Array = []
    if res_key.is_empty():
        return result

    # The addresses a query stands for: the key itself, plus, for a single product,
    # every group that contains it.
    var queries: Array = [res_key]
    var via_group := {}
    if not is_group_key(res_key):
        for group_id in product_groups:
            var members: Array = product_groups[group_id]
            if not members.has(res_key):
                continue
            var group_key := "@%s" % str(group_id)
            queries.append(group_key)
            via_group[group_key] = group_key

    # The pairs already listed. The resource is consumed by the same profession only
    # once: the rule of the registry wins over the legacy record of the resource, and
    # among the equal ones the own rule wins over the group one (the concrete case is
    # more informative than the general one).
    var covered := {}
    for query in queries:
        for rule in consumption_rules:
            if not (rule is Dictionary):
                continue
            if str(rule.get("resource", "")) != query:
                continue
            var amount := int(rule.get("amount", 0))
            if amount <= 0:
                continue
            var interval := float(rule.get("interval", 0))
            var bonus := float(rule.get("production_bonus", 0.0))
            for prof_id in rule.get("profession", []):
                var pair := str(prof_id)
                if covered.has(pair):
                    continue
                covered[pair] = true
                result.append({
                    "profession_id": pair,
                    "profession_name": get_profession_name(pair),
                    "amount": amount,
                    "interval": interval,
                    "production_bonus": bonus,
                    "via_group": str(via_group.get(query, ""))
                })

    # The legacy records "from the resource": a product carries its own consumption
    # inline. A single product has no group rule of its own, so it is queried for the
    # product key only.
    if products.has(res_key):
        var prod: Dictionary = products[res_key]
        if prod.has("consumption"):
            var cons: Dictionary = prod["consumption"]
            var amount2 := int(cons.get("amount", 0))
            var interval2 := float(cons.get("interval", 0))
            var bonus2 := float(cons.get("production_bonus", 0.0))
            if amount2 > 0:
                for prof_id in cons.get("profession", []):
                    var pair2 := str(prof_id)
                    if covered.has(pair2):
                        continue
                    covered[pair2] = true
                    result.append({
                        "profession_id": pair2,
                        "profession_name": get_profession_name(pair2),
                        "amount": amount2,
                        "interval": interval2,
                        "production_bonus": bonus2,
                        "via_group": ""
                    })
    return result

# Returns the array of the consumption records for a profession. The sources (in the order of
# priority):
#   1) the registry data/consumption.json — the records of the kind
#      { "resource": "<id>|@<group>", "profession": ["<id>"],
#        "amount": N, "interval": S, "production_bonus": B }.
#      It supports the product groups: any suitable product is consumed
#      from the group (see worker_manager.tick_consumption()).
#   2) the deprecated "from the resource" scheme: the consumption field of the product in
#      data/products/*.json (left for the single cases — when the resource
#      has no analogue for the group). The infrastructure is not changed.
# The duplicates are cut off by display_key: the same resource will not get into
# the result twice (the record from the registry takes priority). Each record:
#   { "product_id": String, "product_name": String,
#     "amount": int, "interval": float, "production_bonus": float,
#     "is_group": bool, "group_members": Array[String],
#     "display_key": String, "icon": String }
# product_id is empty for the group records; product_name — the name of the group.
# production_bonus — an addition to the production multiplier, while the resource is
# in the storage (0.5 = +50%, that is, the multiplier x1.5). 0 = no bonus.
# If the profession is unknown or has no consumers — an empty array.
func get_profession_consumption(prof_id: String) -> Array:
    var result: Array = []
    if prof_id.is_empty():
        return result
    # Source 1: the registry data/consumption.json.
    var covered := {} # display_key -> true (protection from a double write-off)
    for rule in consumption_rules:
        if not (rule is Dictionary):
            continue
        var target_list: Array = rule.get("profession", [])
        if not (prof_id in target_list):
            continue
        var res_key = str(rule.get("resource", ""))
        if res_key.is_empty():
            continue
        var entry = _build_consumption_entry(res_key, rule)
        if entry.is_empty():
            continue
        if covered.has(entry["display_key"]):
            continue
        covered[entry["display_key"]] = true
        result.append(entry)
    # Source 2: the consumption "from the resource" (products[*].consumption).
    # The records already covered by the registry are skipped, so that the resource
    # is not written off twice by one profession.
    for pid in products:
        var prod = products[pid]
        if not prod.has("consumption"):
            continue
        if covered.has(pid):
            continue
        var cons: Dictionary = prod["consumption"]
        var target_list: Array = cons.get("profession", [])
        if not (prof_id in target_list):
            continue
        result.append({
            "product_id": pid,
            "product_name": prod.get("name", pid),
            "amount": int(cons.get("amount", 0)),
            "interval": float(cons.get("interval", 0)),
            "production_bonus": float(cons.get("production_bonus", 0.0)),
            "is_group": false,
            "group_members": [],
            "display_key": pid,
            "icon": prod.get("icon", "")
        })
    return result

# Returns all the resources that are consumed by a profession (without the details of
# amount/interval) — it is used to count "how many such and such resources a profession
# needs" in the summary tooltips.
# It returns a dictionary: display_key -> { "name": String, "is_group": bool,
#   "group_members": Array, "amount": int, "interval": float,
#   "production_bonus": float }.
# The key of a single product is its id; of a group resource it is "@<group_id>".
# If different resources are required with a different frequency, the first encountered one is taken.
func get_profession_consumption_summary(prof_id: String) -> Dictionary:
    var result: Dictionary = {}
    for entry in get_profession_consumption(prof_id):
        var dkey = entry.get("display_key", entry.get("product_id", ""))
        if result.has(dkey):
            continue
        result[dkey] = {
            "name": entry.get("product_name", ""),
            "is_group": bool(entry.get("is_group", false)),
            "group_members": entry.get("group_members", []),
            "amount": int(entry.get("amount", 0)),
            "interval": float(entry.get("interval", 0)),
            "production_bonus": float(entry.get("production_bonus", 0.0))
        }
    return result
