# data_validator.gd
# The runtime validator of data/*.json: the cross-references between the entities and the
# shape of the records.
#
# It is run AFTER the loading of the data and BEFORE the start of the game (see main_menu.gd),
# so that the data author learns about the broken references not from the console, but from a window with
# an exact indication of the problematic entity.
#
# The REFERENCES between the entities are checked (and not the JSON syntax — this is what
# tools/validate_json.py does), and, on top of them, every key of the data against the field
# whitelist of the model (SCHEMA below), including the free keys of the dictionaries, which are
# identifiers themselves (unknown_key). A problem is stored in two layers:
#
#   1) the STRUCTURE — does not depend on the language: what is wrong, where and in which field.
#
#   {
#   2) the TEXT — is translated (see build_text below). It is assembled SEPARATELY from
#      the check exactly because the language can be switched without running the
#      check again: localize_problems() reassembles the texts in the new
#      language from the same structure.
#
#   }
#
# The checks:
#   unknown_field      — a field (or a whole collection) that the data model does not describe
#   unknown_key        — a key of a dictionary ({"produces": {"wheatt": 1}}) names nothing
#   blacklist          — a mod's blacklist names an entity that is neither in the data nor removed
#   id_charset         — an identifier outside ASCII (the Cyrillic in an id is indistinguishable from the Latin)
#   id_lookalike       — an identifier differs from another one only by the lookalike characters
#   produced_in        — a recipe refers to a non-existent building
#   result             — a recipe (result / display_result) gives a non-existent resource
#   improved_by        — a resource is improved by a non-existent improvement
#   unlock_improvement — a product is unlocked by a non-existent improvement
#   unlock_tech        — a building/improvement/product/recipe → a non-existent technology
#   profession         — a building/improvement → a non-existent profession
#   category           — a product → a non-existent category
#   product_source     — a product is produced NEITHER by the map, NOR by a recipe
#   group_member       — a non-existent product in an @-group
#   resource_group     — a recipe refers to a non-existent @-group
#   resource           — a recipe requires a non-existent resource
#   consumption_resource— a consumption rule → a non-existent product
#   consumption_group   — a consumption rule → a non-existent @-group
#   prerequisite       — a technology requires a non-existent technology
#   road_level         — a road level has an incorrect or duplicate number
#   road_max_speed     — a road level has a non-positive maximum speed
#   road_work_cost     — a road level has a negative price of a segment
#
# A record of a problem:
#     "kind":        String,  # the machine name of the check, e.g. "produced_in"
#     "check_title": String,  # the heading of the group of the check for the window
#     "target_title":String,  # "Building" — the kind of the entity being searched for ("" — none)
#     "ref_id":      String,  # the searched identifier ("x")
#     "source_kind": String,  # the kind of the owning entity ("recipe")
#     "source_name": String,  # its name from the data ("Grain Mill")
#     "source_id":   String,  # its identifier ("grind_grain_hand")
#     "field":       String,  # the field in which the reference was found
#     "file":        String,  # the file in which the owner of the reference is declared
#     "line":        int,     # the line of the declaration in this file (0 — unknown)
#     "headline":    String,  # the first line of the message
#     "where":       String,  # the second line: where exactly the reference was found
#     "location":    String,  # the third line: "File: …, line N." ("" — none)
#     "message":     String,  # all the lines together (for the logs and the tests)
#
# The class does NOT depend on the autoloads: the data being checked is passed as
# an argument, therefore the validator is run by a headless test on artificial
# data (tests/test_data_validation.gd).
extends RefCounted

# The service marker produced_in: "the recipe is produced in ANY building".
# It is handled in CityData.can_craft_in, therefore this is NOT a broken reference —
# we skip it, otherwise the validator would complain about the pseudo-recipe "empty".
const ANY_BUILDING_MARKER := "*"

# --- THE FOREST PLOT: the source of wood that is NOT in produces ---
#
# Wood has two kinds of source. The resources that give it list it in their
# produces ("oak_tree", "campeche_tree", "mulberry_tree"), and that source is
# visible to a naive cross-check. The second one
# is not: the forest plot on an EMPTY forest hex takes its output from the field
# wood_yield of the COVER (data/covers.json), not from a resource on the hex:
#
#   main_map.gd, the production tick → CityData.add_to_storage("wood", …)
#   MapHelpers.get_cover_wood_yield(tile) — cover → wood_yield
#
# The relation "cover → plot → product" is hardcoded, therefore it is not
# visible from the data. Here it is restored READABLY: the cover source exists if
# the plot is declared AND at least one cover has wood_yield > 0. If the author
# removes the plot or the output from the covers — the validator honestly says that
# the wood is unreachable from the covers (see the test tests/test_data_validation.gd).
# The check is kept alongside the produces one, and not replaced by it: a data set
# without the wood resources must still be able to produce wood on a forest hex.
#
# --- THE RULES OF THE IDENTIFIERS ---------------------------------------------
#
const LUMBERJACK_PRODUCT := "wood"
const LUMBERJACK_IMPROVEMENT := "lumberjack_hut"
const COVER_YIELD_FIELD := "wood_yield"

# The identifiers are the keys by which the data is stitched together between the files, and
# therefore because the author searches for them with their eyes in the editor. Both properties break
# silently, therefore they are checked separately.
#
#
# The ALLOWED ALPHABET: the Latin letters a-z, the digits and the underscore. Exactly
# this set is used in all 515 identifiers of data/, therefore the strict
# rule does not give a single false positive. Everything else — spaces,
# hyphens, uppercase, Cyrillic — is an error, and each of them is dangerous: the author does not see
# the difference between "carmine" and "сarmine" (the Cyrillic с) with their eyes.
#
# The characters that are indistinguishable from the Latin ones with the naked eye → their Latin look.
const IDENT_CHARS := "abcdefghijklmnopqrstuvwxyz0123456789_"
const IDENT_UPPER := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

# They are needed for the hint in the message: to print the "с" in the text is useless —
# the author will read it as a "c" and decide that everything is fine. Therefore the message
# contains the UNICODE CODE (U+0441) and the hint "in the Latin it is a c".
#
# The table is INcomplete and is NOT a mapping of all the lookalike characters: it
# covers the case that has actually occurred (the Cyrillic in the Russian
# layout when typing the Latin ids). If the character is not in the table — the hint
# is simply not output, and this is more honest than guessing the look "with the naked eye".
#
# The Unicode blocks in which the error is plausible. The name of the block is NOT
# stored here: a constant cannot call a translation, and the catalogue builder
# (tools/i18n_build_po.py) takes the msgid as a literal directly in the call
# of translate() — it cannot get it from a dictionary. The labels live in
# _block_label() below, and here only the boundaries of the ranges remain.
const IDENT_LOOKALIKES := {
    "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h",
    "о": "o", "р": "p", "с": "c", "т": "t", "у": "y", "х": "x",
    "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "һ": "h", "ӏ": "l",
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H",
    "О": "O", "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X",
}

# The Unicode blocks in which the error is plausible. The name of the block is NOT
# stored here: a constant cannot call a translation, and the catalogue builder
# (tools/i18n_build_po.py) takes the msgid as a literal directly in the call
# of translate() — it cannot get it from a dictionary. The labels live in
# _block_label() below, and here only the boundaries of the ranges remain.
const IDENT_BLOCKS := [
    {"from": 0x0400, "to": 0x04FF, "key": "cyrillic"},
    {"from": 0x0370, "to": 0x03FF, "key": "greek"},
    {"from": 0xFF10, "to": 0xFF19, "key": "fullwidth_latin"},
]

# The collections with identifiers: where to look for the declarations.
#
# A single list for the checks id_charset / id_lookalike: they are orthogonal
# to the other checks (those care about the VALUE of the references, these — about the text of the id itself), and
# keeping the list in one place is cheaper than adding it per call into each of the
# fifteen collections. The pairs "the field of GameData → the kind of the entity for the message":
# the second one is needed so that in the text of the problem it says "Product", and not "Resource".
const IDENT_COLLECTIONS := [
    {"field": "products", "kind": "product"},
    {"field": "raw_resources", "kind": "product"},
    {"field": "improvements", "kind": "improvement"},
    {"field": "professions", "kind": "profession"},
    {"field": "product_groups", "kind": "group"},
    {"field": "qualities", "kind": "quality_level"},
    {"field": "special_actions", "kind": "special_action"},
    {"field": "terrains", "kind": "terrain"},
    {"field": "covers", "kind": "cover"},
    {"field": "crafts", "kind": "recipe"},
    {"field": "buildings", "kind": "building"},
    {"field": "technologies", "kind": "technology"},
    {"field": "categories", "kind": "category"},
    {"field": "eras", "kind": "era"},
    {"field": "roads", "kind": "road"},
]

# The quality levels lie not in a dictionary, but in an array inside a dictionary
# (data/qualities.json → "quality_levels": [...]), therefore they are handled
# separately: the walk of the collections above goes through the fields of GameData and such a nested
# list will not see it.
const QUALITY_LEVELS_FIELD := "quality_levels"

# --- THE WHITELIST OF THE FIELDS ----------------------------------------------
#
# The data is addressed by key names: the loader picks the collections it knows, and every record
# is a dictionary whose fields are read by name. A key the model does not know is silently lost —
# a typo in "produces" leaves a resource that yields nothing, a typo in "unlock_tech" a building
# that is available from the start — and the file stays valid JSON the whole time, so neither
# tools/validate_json.py nor a reader of the diff notices anything.
#
# SCHEMA is the single list of what data/*.json may contain, and every key outside it is reported
# as unknown_field. The list describes the DATA MODEL, not the current reads of the code: a field
# the design keeps while no system reads it yet (covers.move_cost_bonus, professions.pseudo, the
# diversity-bonus registry of data/bonuses.json) is listed as well — otherwise a legitimate file
# would be reported as broken. The check exists for the opposite case: a field nobody planned, which
# the game will never read.
#
# A rule says what a value may hold:
#   LEAF              — a scalar or an array of scalars: there is nothing to descend into;
#   ID_MAP            — an object with free keys (ids) and scalar values: {"wheat": 1};
#   {"id_map": rule}  — the same, but every value follows the rule (terrain_config);
#   {"keys": name}    — the same, and every KEY has to be the id of a declared record of the
#                       registry "name" (see the KEY_* constants below);
#   {"array": rule}   — an array whose every element follows the rule;
#   {"any": [rule…]}  — the field accepts any of the listed forms;
#   {"blocks": {…}}   — named blocks of constants, a constant may also stand at the top level
#                       (data/game_balance.json, see data_loader._flatten_balance_blocks);
#   any other non-empty dictionary — the fixed set of the fields of an object, each with a rule.
#
# A value of a shape the rule does not expect is left alone: the check reports unknown KEYS. A wrong
# shape is a different kind of problem — the game reads such a field with a default, and the
# consequence is visible in the interface.
const LEAF := {}
const ID_MAP := {"id_map": LEAF}

# --- THE FREE KEYS OF THE DICTIONARIES -----------------------------------------
#
# An id map is the second way the data is addressed by name: {"wheat": 1} is not "a field named
# wheat", it is "the record with the identifier wheat". The whitelist cannot see a typo in such a
# key at all — the key name is free, so any spelling is a legal field — and the game, looking the
# key up in the dictionary of the declared records, finds nothing and silently produces nothing.
# Therefore a rule may name the registry its keys belong to, and a key outside it is reported as
# unknown_key.
#
# The registries are read from the same tree that is walked, i.e. from the declarations, and not
# from the assembled collections: a data set whose resources live in another file is one tree.
const KEY_RESOURCES := "resources"
const KEY_GROUP_REFS := "group_refs"
const KEY_COVERS := "covers"
const KEY_TERRAINS := "terrains"
# The terrain families (the field "family" of a terrain record): the keys of a zone's terrain map.
const KEY_TERRAIN_FAMILIES := "terrain_families"
const KEY_IMPROVEMENTS := "improvements"
const KEY_PRIORITIES := "priorities"

# The registries that are simply the ids of one collection of records: the name of the registry is
# the name of the collection. The other two are assembled from several places (_key_registries).
const PLAIN_REGISTRIES := [KEY_RESOURCES, KEY_COVERS, KEY_TERRAINS, KEY_IMPROVEMENTS]

# The kind of the entity a key of the registry has to name — for the text of the problem. The
# @-group reference of KEY_GROUP_REFS is decided per key: "planks" is a resource, "@planks" a group.
const REGISTRY_TARGETS := {
    KEY_RESOURCES: "product",
    KEY_COVERS: "cover",
    KEY_TERRAINS: "terrain",
    KEY_TERRAIN_FAMILIES: "terrain_family",
    KEY_IMPROVEMENTS: "improvement",
    KEY_PRIORITIES: "priority_option",
}

# The collection → the kind of the entity that owns a dictionary in it. The kind is needed by the
# text of unknown_key ("A reference to this product is present in the resource …"): a collection the
# game reads as a config block (map_config, modifiers, priority_names) has no kind, and its problems
# name the field instead of an owner.
const OWNER_KINDS := {
    "resources": "product",
    "buildings": "building",
    "terrains": "terrain",
    "covers": "cover",
    "climate_zones": "climate_zone",
    "improvements": "improvement",
}

# The id maps of the model, by the registry of their keys.
#   produces / special_yield / additional_yield — what a resource or a building gives out;
#   additional_cost — a resource OR an @-group of products;
#   cover_chance — the covers that may grow on a terrain;
#   production_multiplier — the improvement whose output is multiplied;
#   priority_names — the labels of the quality priority options.
const RESOURCE_MAP := {"id_map": LEAF, "keys": KEY_RESOURCES}
const COST_MAP := {"id_map": LEAF, "keys": KEY_GROUP_REFS}
const COVER_MAP := {"id_map": LEAF, "keys": KEY_COVERS}
const IMPROVEMENT_MAP := {"id_map": LEAF, "keys": KEY_IMPROVEMENTS}
const PRIORITY_MAP := {"id_map": LEAF, "keys": KEY_PRIORITIES}

# The field that identifies a record, where it is not "id": a consumption rule is addressed by the
# resource it spends (data_loader._remember_consumption_sources).
const ENTITY_ID_FIELDS := {
    "consumption": "resource",
}

# A resource on the map, and a product of the city — one collection, split by the "type" field.
# A raw resource carries the fields of the map generation, a product the ones of the warehouse.
const RESOURCE_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "type": LEAF,
    "category": LEAF,
    "icon": LEAF,
    "price": LEAF,
    "color": LEAF,
    "group": LEAF,
    "subgroup": LEAF,
    "improved_by": LEAF,
    "unlock_improvement": LEAF,
    "unlock_tech": LEAF,
    "tech_required": LEAF,
    "tech_reveal": LEAF,
    "allowed_terrain": LEAF,
    "allowed_cover": LEAF,
    "allowed_climate_zones": LEAF,
    "produces": RESOURCE_MAP,
    "special_yield": RESOURCE_MAP,
    "strategic": LEAF,
    "breedable": LEAF,
    "breeding": {"array": {"array": {"terrain": LEAF, "cover": LEAF}}},
    "spawn_conditions": {"array": {"array": {"type": LEAF, "chance": LEAF, "terrain_id": LEAF}}},
    "spawn_count": LEAF,
    "feed_consumption": LEAF,
    "time_to_mature": LEAF,
    # The legacy consumption "from the resource" (see GameData.get_consumption_consumers): the
    # product is the owner, so the rule has no "resource" field of its own.
    "consumption": {"profession": LEAF, "amount": LEAF, "interval": LEAF, "production_bonus": LEAF},
}

const BUILDING_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "description": LEAF,
    "icon": LEAF,
    "work_cost": LEAF,
    "additional_cost": {"any": [COST_MAP, {"array": COST_MAP}]},
    "additional_req": LEAF,
    "additional_yield": RESOURCE_MAP,
    "production_slots": LEAF,
    "default_recipes": LEAF,
    "profession": LEAF,
    "unlock_tech": LEAF,
    "upgrades_into": LEAF,
}

const IMPROVEMENT_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "icon": LEAF,
    "color": LEAF,
    "work_cost": LEAF,
    "unlock_tech": LEAF,
    "profession": LEAF,
    "no_worker": LEAF,
    "no_road": LEAF,
    "is_canal": LEAF,
    "conducts_water": LEAF,
    "water_body_harbor": LEAF,
    "requires_harbor": LEAF,
}

# The ingredients of a recipe allow the alternative forms (GameData.parse_craft_resources):
# an object, or an array of terms where a term is an object or an array of objects (OR).
const CRAFT_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "description": LEAF,
    "produced_in": LEAF,
    "resources": {"any": [ID_MAP, {"array": {"any": [ID_MAP, {"array": ID_MAP}]}}]},
    "result": ID_MAP,
    "display_result": ID_MAP,
    "time": LEAF,
    "unlock_tech": LEAF,
}

const TECHNOLOGY_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "description": LEAF,
    "flavor": LEAF,
    "era": LEAF,
    "science_cost": LEAF,
    "icon": LEAF,
    "prerequisites": LEAF,
    "unlock_effects": {"array": {"icon": LEAF, "name": LEAF}},
}

const CATEGORY_FIELDS := {
    "id": LEAF,
    "name": LEAF,
}

# data/groups.json — the groups for the diversity bonuses, and not the goods groups of
# data/product_groups.json.
const GROUP_FIELDS := {
    "id": LEAF,
    "name": LEAF,
}

const ERA_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "region_width": LEAF,
}

const PRODUCT_GROUP_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "products": LEAF,
    "icon": LEAF,
}

const PROFESSION_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "icon": LEAF,
    "description": LEAF,
    "pseudo": LEAF,
}

const QUALITY_LEVEL_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "color": LEAF,
    "value": LEAF,
    "stars": LEAF,
    "price_multiplier": LEAF,
    "spawn_weight": LEAF,
}

const ROAD_FIELDS := {
    "id": LEAF,
    "level": LEAF,
    "name": LEAF,
    "description": LEAF,
    "color": LEAF,
    "width": LEAF,
    "work_cost": LEAF,
    "max_speed": LEAF,
    "unlock_tech": LEAF,
}

const TERRAIN_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "description": LEAF,
    "color": LEAF,
    # The terrain family of a terrain: the climate turns every hex of a family into the variety of
    # its belt (a plain becomes a tundra plain, a boreal plain, a steppe, a prairie, a savanna or a
    # tropical plain; a swamp becomes the bog of its belt; a marsh becomes the mudflat of its
    # belt). The water and the deserts have no family.
    "family": LEAF,
    "icons": LEAF,
    "move_cost": LEAF,
    "expansion_cost": LEAF,
    "work_cost_mult": LEAF,
    "unique": LEAF,
    "cluster_size": LEAF,
    "cover_chance": COVER_MAP,
    "fresh_water_source": LEAF,
}

const COVER_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "color": LEAF,
    "alpha": LEAF,
    "icons": LEAF,
    "move_cost_bonus": LEAF,
    "wood_yield": LEAF,
    "fresh_water_source": LEAF,
}

# A climate zone is a pair of the climate axes plus what the relief of its region becomes. The two
# axes are enumerated by _validate_climate_zones: a value outside the list is a zone that never
# appears on the map.
const ZONE_FIELDS := {
    "id": LEAF,
    "temperature": LEAF,
    "humidity": LEAF,
    # The variety of every family of the zone: {"plain": "boreal_plain", …}. The keys are the
    # families (KEY_TERRAIN_FAMILIES), the values — the terrains that carry that family.
    "terrain": {"id_map": {"keys": KEY_TERRAINS}, "keys": KEY_TERRAIN_FAMILIES},
    # The vegetation of the zone: it applies to the relief families of the zone at once. The
    # wetland keeps its own pool (the terrain record of the swamp variety).
    "cover_chance": COVER_MAP,
    # true — the deserts may stand in the zone (the hot dry belts).
    "deserts": LEAF,
}

const SPECIAL_ACTION_FIELDS := {
    "id": LEAF,
    "name": LEAF,
    "action_type": LEAF,
    "icon": LEAF,
    "source_terrain": LEAF,
    "source_terrains": LEAF,
    "source_cover": LEAF,
    "result_terrain": LEAF,
    "result_cover": LEAF,
    "work_cost": LEAF,
    "unlock_tech": LEAF,
}

const CONSUMPTION_FIELDS := {
    "resource": LEAF,
    "profession": LEAF,
    "amount": LEAF,
    "interval": LEAF,
    "production_bonus": LEAF,
}

const GROUP_BONUS_FIELDS := {
    "group_id": LEAF,
    "bonus_type": LEAF,
    "tiers": {"array": {"min_subgroups": LEAF, "value": LEAF}},
}

const SUBGROUP_BONUS_FIELDS := {
    "subgroup_id": LEAF,
    "bonus_type": LEAF,
    "tiers": {"array": {"min_species": LEAF, "value": LEAF}},
}

const MODIFIER_FIELDS := {
    "fresh_water": {"production_multiplier": IMPROVEMENT_MAP},
    "tech_modifiers": {"array": {
        "tech_id": LEAF,
        "icon": LEAF,
        "name": LEAF,
        "production_multiplier": IMPROVEMENT_MAP,
        "modifiers": {"array": {"target": LEAF, "type": LEAF, "value": LEAF}},
    }},
    "terrain_modifiers": {"array": {
        "terrain_id": LEAF,
        "resource_id": LEAF,
        "production_multiplier": LEAF,
    }},
}

const SEA_CONFIG_FIELDS := {
    "mode": LEAF,
    "sides": LEAF,
    "beach": LEAF,
    "max_sea_depth": LEAF,
    "coast_max_depth": LEAF,
    "edge_width_min": LEAF,
    "edge_width_max": LEAF,
    "edge_envelope_strength": LEAF,
    "edge_islands_enabled": LEAF,
    "edge_island_size": LEAF,
    "edge_island_density": LEAF,
    "edge_island_min_distance": LEAF,
    "edge_island_max_attempts": LEAF,
    "noise_sea_level": LEAF,
    "noise_strength": LEAF,
    "noise_edge_gradient": LEAF,
    "noise_city_bump": LEAF,
    "noise_city_bump_radius": LEAF,
}

# The climate block: the belts of the temperature, the moisture field and the cleanup of the zones
# (see map_generator._apply_climate).
const CLIMATE_FIELDS := {
    "equator_min": LEAF,
    "equator_max": LEAF,
    "tropical_half_rows": LEAF,
    "subtropical_rows": LEAF,
    "mild_rows": LEAF,
    "polar_share": LEAF,
    "warp_rows": LEAF,
    "warp_scale": LEAF,
    "moisture_scale": LEAF,
    "moisture_threshold": LEAF,
    "min_zone_size": LEAF,
    "cover_smoothing": LEAF,
}

const MAP_CONFIG_FIELDS := {
    "start_ring_rows": LEAF,
    "start_ring_cols": LEAF,
    "region_width": LEAF,
    "target_cluster": LEAF,
    "terrain_config": {"id_map": {"density": LEAF, "target_cluster": LEAF}, "keys": KEY_TERRAINS},
    "climate": CLIMATE_FIELDS,
    "sea": SEA_CONFIG_FIELDS,
    "num_main_rivers": LEAF,
    "num_tributaries": LEAF,
    "min_river_length": LEAF,
    "min_tributary_length": LEAF,
}

# The balance is grouped into blocks by the system that owns the constants; the block names are a
# layout of the file only (data_loader._flatten_balance_blocks).
const GAME_BALANCE_BLOCKS := {
    "city": {
        "base_tax_per_citizen": LEAF,
        "food_per_citizen": LEAF,
        "food_for_new_settler": LEAF,
        "initial_treasury": LEAF,
        "internal_market_price_multiplier": LEAF,
    },
    "expansion": {
        "expansion_cost_per_hex": LEAF,
        "distance_cost_modifier_per_hex": LEAF,
        "road_distance_cost_modifier_per_hex": LEAF,
        "scouting_cost_per_hex": LEAF,
    },
    "logistics": {
        "transit_time_per_hex": LEAF,
    },
    "towns": {
        "town_storage_limit": LEAF,
        "town_storage_initial_min": LEAF,
        "town_storage_initial_max": LEAF,
        "town_tick_ticks": LEAF,
        "town_contract_comfort": LEAF,
        "town_contract_drain": LEAF,
        "town_contract_drain_curve": LEAF,
        "town_initial_treasury": LEAF,
        "town_trade_min": LEAF,
        "town_trade_max": LEAF,
        "town_trade_inertia": LEAF,
        "town_trade_bias_strength": LEAF,
        "town_trade_bulk_chance": LEAF,
        "town_trade_bulk_min": LEAF,
        "town_trade_bulk_max": LEAF,
        "town_treasury_trade_min": LEAF,
        "town_treasury_trade_max": LEAF,
        "town_treasury_inertia": LEAF,
        "town_treasury_bias_strength": LEAF,
        "town_treasury_bulk_chance": LEAF,
        "town_treasury_bulk_min": LEAF,
        "town_treasury_bulk_max": LEAF,
        "town_treasury_recovery_threshold": LEAF,
        "town_treasury_recovery_step": LEAF,
    },
}

# data/qualities.json keeps the quality scale at the top level; the loader also accepts it nested
# under a "qualities" key (data_loader.load_all_data), therefore the four fields are listed twice.
const QUALITY_SCALE_FIELDS := {
    "quality_levels": {"array": QUALITY_LEVEL_FIELDS},
    "priority_default": LEAF,
    "priority_options": LEAF,
    "priority_names": PRIORITY_MAP,
}

# --- THE BLACKLIST ---------------------------------------------------------------
#
# A mod may remove vanilla entities (data_loader._apply_blacklist). Its "blacklist" key is
# a dictionary { "<collection>": ["id", …] }, and the whitelist below is what keeps the
# shape of it honest: the keys are the collections of data_loader.BLACKLIST_COLLECTIONS
# (the same list, the two must agree), and an unknown one — "building" for "buildings" —
# is reported like any other unknown field, with the list of the allowed ones. The value
# is a list of identifiers; a single identifier is accepted as well, the same forgiveness
# as the manifest's authors/author.
#
# The shape is all the whitelist can say: a blacklisted entity is REMOVED from the tree,
# so the walk cannot tell a removed one from a typo. That is the business of
# _validate_blacklist below.
const BLACKLIST_ENTRY := {"any": [{"array": LEAF}, LEAF]}
const BLACKLIST_COLLECTIONS := [
    "resources",
    "crafts",
    "buildings",
    "improvements",
    "technologies",
    "categories",
    "groups",
    "eras",
    "product_groups",
    "professions",
    "quality_levels",
    "roads",
    "terrains",
    "covers",
    "climate_zones",
    "special_actions",
    "consumption",
]
const BLACKLIST_FIELDS := {
    "resources": BLACKLIST_ENTRY,
    "crafts": BLACKLIST_ENTRY,
    "buildings": BLACKLIST_ENTRY,
    "improvements": BLACKLIST_ENTRY,
    "technologies": BLACKLIST_ENTRY,
    "categories": BLACKLIST_ENTRY,
    "groups": BLACKLIST_ENTRY,
    "eras": BLACKLIST_ENTRY,
    "product_groups": BLACKLIST_ENTRY,
    "professions": BLACKLIST_ENTRY,
    "quality_levels": BLACKLIST_ENTRY,
    "roads": BLACKLIST_ENTRY,
    "terrains": BLACKLIST_ENTRY,
    "covers": BLACKLIST_ENTRY,
    "climate_zones": BLACKLIST_ENTRY,
    "special_actions": BLACKLIST_ENTRY,
    "consumption": BLACKLIST_ENTRY,
}

# The kind of the entity a blacklisted identifier names — for the text of the problem of
# _validate_blacklist. The whitelist reports an unknown COLLECTION, that check an unknown
# ENTITY inside a known one, and the author has to read which of the two it is.
const BLACKLIST_KINDS := {
    "resources": "product",
    "crafts": "recipe",
    "buildings": "building",
    "improvements": "improvement",
    "technologies": "technology",
    "categories": "category",
    "groups": "group",
    "eras": "era",
    "product_groups": "group",
    "professions": "profession",
    "quality_levels": "quality_level",
    "roads": "road",
    "terrains": "terrain",
    "covers": "cover",
    "climate_zones": "climate_zone",
    "special_actions": "special_action",
    "consumption": "consumption_rule",
}

# The root of data/*.json: every top-level key of every file, merged into one tree. A key outside
# this list is an unknown collection — the loader skips it, and everything under it is lost.
const SCHEMA := {
    "resources": {"array": RESOURCE_FIELDS},
    "crafts": {"array": CRAFT_FIELDS},
    "buildings": {"array": BUILDING_FIELDS},
    "improvements": {"array": IMPROVEMENT_FIELDS},
    "technologies": {"array": TECHNOLOGY_FIELDS},
    "categories": {"array": CATEGORY_FIELDS},
    "groups": {"array": GROUP_FIELDS},
    "eras": {"array": ERA_FIELDS},
    "product_groups": {"array": PRODUCT_GROUP_FIELDS},
    "professions": {"array": PROFESSION_FIELDS},
    "quality_levels": {"array": QUALITY_LEVEL_FIELDS},
    "roads": {"array": ROAD_FIELDS},
    "terrains": {"array": TERRAIN_FIELDS},
    "covers": {"array": COVER_FIELDS},
    "climate_zones": {"array": ZONE_FIELDS},
    "special_actions": {"array": SPECIAL_ACTION_FIELDS},
    "consumption": {"array": CONSUMPTION_FIELDS},
    "group_bonuses": {"array": GROUP_BONUS_FIELDS},
    "subgroup_bonuses": {"array": SUBGROUP_BONUS_FIELDS},
    "modifiers": MODIFIER_FIELDS,
    "map_config": MAP_CONFIG_FIELDS,
    "game_balance": {"blocks": GAME_BALANCE_BLOCKS},
    "city_names": {"array": LEAF},
    "priority_default": LEAF,
    "priority_options": LEAF,
    "priority_names": PRIORITY_MAP,
    "qualities": QUALITY_SCALE_FIELDS,
    "blacklist": BLACKLIST_FIELDS,
}

# The kinds of the entities that occur in the text of the problem.
#
# This is a list for the substitution of the fallback kind, and not a source of the labels: the
# labels themselves live in entity_forms() below. A dictionary with the names would stand exactly
# for the reason that its values would not get into the translation catalogue — see the note
# to entity_forms() about how the builder reads them.
const ENTITIES := [
    "building", "product", "improvement", "technology", "profession",
    "category", "group", "recipe", "road", "terrain", "terrain_family", "cover", "climate_zone", "era",
    "quality_level", "priority_option", "special_action", "consumption_rule",
]


# The names of the kind of the entity in three grammatical forms:
#   title  — the genitive case ("There is no building with the identifier "x"");
#   ref    — the accusative case ("A reference to this building is present in…");
#   source — the prepositional case ("…is present in the recipe "…"").
#
# English does not know the cases, therefore the three forms are three different msgids
# ("Building", "this building", "building"), and in Russian they correspond to
# "здания", "это здание", "здании". At that time msgctxt is not needed: the English
# texts are different anyway, and the difference goes into the very wording. Exactly the same
# trick as with the plural forms in consumption_ui.gd.
#
# The labels are listed EXPLICITLY, as literals directly in the calls of translate(), and not
# taken from the dictionary of the constant. This is a requirement of the catalogue builder:
# tools/i18n_build_po.py parses the code line by line and takes the msgid as a literal in
# this call. A dictionary would hide the msgid from the scanner, and in locale/<code>.po
# there simply would be no translations of these labels — they would remain
# English in any language.
#
# fallback — the kind for the case of an unknown key: "product" for the searched
# entity, "recipe" for the owner of the reference (see _add).
static func entity_forms(kind: String, fallback: String = "product") -> Dictionary:
    if not ENTITIES.has(kind):
        kind = fallback
    match kind:
        "building":
            return {"title": TranslationServer.translate("Building", "validator_entity_title_building"),
                "ref": TranslationServer.translate("this building", "validator_entity_ref_building"),
                "source": TranslationServer.translate("building", "validator_entity_source_building")}
        "product":
            return {"title": TranslationServer.translate("Product", "validator_entity_title_product"),
                "ref": TranslationServer.translate("this product", "validator_entity_ref_product"),
                "source": TranslationServer.translate("product", "validator_entity_source_product")}
        "improvement":
            return {"title": TranslationServer.translate("Improvement", "validator_entity_title_improvement"),
                "ref": TranslationServer.translate("this improvement", "validator_entity_ref_improvement"),
                "source": TranslationServer.translate("improvement", "validator_entity_source_improvement")}
        "technology":
            return {"title": TranslationServer.translate("Technology", "validator_entity_title_technology"),
                "ref": TranslationServer.translate("this technology", "validator_entity_ref_technology"),
                "source": TranslationServer.translate("technology", "validator_entity_source_technology")}
        "profession":
            return {"title": TranslationServer.translate("Profession", "validator_entity_title_profession"),
                "ref": TranslationServer.translate("this profession", "validator_entity_ref_profession"),
                "source": TranslationServer.translate("profession", "validator_entity_source_profession")}
        "category":
            return {"title": TranslationServer.translate("Category", "validator_entity_title_category"),
                "ref": TranslationServer.translate("this category", "validator_entity_ref_category"),
                "source": TranslationServer.translate("category", "validator_entity_source_category")}
        "group":
            return {"title": TranslationServer.translate("Goods group", "validator_entity_title_group"),
                "ref": TranslationServer.translate("this goods group", "validator_entity_ref_group"),
                "source": TranslationServer.translate("goods group", "validator_entity_source_group")}
        "recipe":
            return {"title": TranslationServer.translate("Recipe", "validator_entity_title_recipe"),
                "ref": TranslationServer.translate("this recipe", "validator_entity_ref_recipe"),
                "source": TranslationServer.translate("recipe", "validator_entity_source_recipe")}
        "road":
            return {"title": TranslationServer.translate("Road level", "validator_entity_title_road"),
                "ref": TranslationServer.translate("this road level", "validator_entity_ref_road"),
                "source": TranslationServer.translate("road level", "validator_entity_source_road")}
        "terrain":
            return {"title": TranslationServer.translate("Terrain", "validator_entity_title_terrain"),
                "ref": TranslationServer.translate("this terrain", "validator_entity_ref_terrain"),
                "source": TranslationServer.translate("terrain", "validator_entity_source_terrain")}
        "cover":
            return {"title": TranslationServer.translate("Terrain cover", "validator_entity_title_cover"),
                "ref": TranslationServer.translate("this terrain cover", "validator_entity_ref_cover"),
                "source": TranslationServer.translate("terrain cover", "validator_entity_source_cover")}
        "terrain_family":
            return {"title": TranslationServer.translate("Terrain family", "validator_entity_title_terrain_family"),
                "ref": TranslationServer.translate("this terrain family", "validator_entity_ref_terrain_family"),
                "source": TranslationServer.translate("terrain family", "validator_entity_source_terrain_family")}
        "climate_zone":
            return {"title": TranslationServer.translate("Climate zone", "validator_entity_title_climate_zone"),
                "ref": TranslationServer.translate("this climate zone", "validator_entity_ref_climate_zone"),
                "source": TranslationServer.translate("climate zone", "validator_entity_source_climate_zone")}
        "era":
            return {"title": TranslationServer.translate("Era", "validator_entity_title_era"),
                "ref": TranslationServer.translate("this era", "validator_entity_ref_era"),
                "source": TranslationServer.translate("era", "validator_entity_source_era")}
        "quality_level":
            return {"title": TranslationServer.translate("Quality level", "validator_entity_title_quality_level"),
                "ref": TranslationServer.translate("this quality level", "validator_entity_ref_quality_level"),
                "source": TranslationServer.translate("quality level", "validator_entity_source_quality_level")}
        "consumption_rule":
            return {"title": TranslationServer.translate("Consumption rule", "validator_entity_title_consumption_rule"),
                "ref": TranslationServer.translate("this consumption rule", "validator_entity_ref_consumption_rule"),
                "source": TranslationServer.translate("consumption rule", "validator_entity_source_consumption_rule")}
        "priority_option":
            return {"title": TranslationServer.translate("Quality priority option", "validator_entity_title_priority_option"),
                "ref": TranslationServer.translate("this quality priority option", "validator_entity_ref_priority_option"),
                "source": TranslationServer.translate("quality priority option", "validator_entity_source_priority_option")}
        _:
            # A special action closes the list: an unknown kind substitutes
            # the fallback above, one can only get here with a typo in the code.
            return {"title": TranslationServer.translate("Special action", "validator_entity_title_special_action"),
                "ref": TranslationServer.translate("this special action", "validator_entity_ref_special_action"),
                "source": TranslationServer.translate("special action", "validator_entity_source_special_action")}


# The heading of the group of the check for the window of the problems. The order of the blocks is set by
# CHECK_ORDER, and not by this list.
#
# As well as the labels of the entities, the headings are listed as literals directly in the calls
# of translate() — otherwise the catalogue builder will not see them (see entity_forms).
static func check_title(kind: String) -> String:
    match kind:
        "unknown_field":
            return TranslationServer.translate("Field is not part of the data model")
        "unknown_key":
            return TranslationServer.translate("Key of a dictionary names a nonexistent entity")
        "blacklist":
            return TranslationServer.translate("Blacklist names a nonexistent entity")
        "id_charset":
            return TranslationServer.translate("Disallowed characters in an identifier")
        "id_lookalike":
            return TranslationServer.translate("Identifier is indistinguishable from another by eye")
        "produced_in":
            return TranslationServer.translate("Recipe is produced in a nonexistent building")
        "result":
            return TranslationServer.translate("Recipe yields a nonexistent resource")
        "improved_by":
            return TranslationServer.translate("Resource is improved by a nonexistent improvement")
        "unlock_improvement":
            return TranslationServer.translate("Product is unlocked by a nonexistent improvement")
        "unlock_tech":
            return TranslationServer.translate("Reference to a nonexistent technology")
        "profession":
            return TranslationServer.translate("Reference to a nonexistent profession")
        "category":
            return TranslationServer.translate("Reference to a nonexistent category")
        "product_source":
            return TranslationServer.translate("Product has no source (neither the map nor a recipe produces it)")
        "group_member":
            return TranslationServer.translate("Nonexistent product in a goods group")
        "resource_group":
            return TranslationServer.translate("Recipe references a nonexistent goods group")
        "resource":
            return TranslationServer.translate("Recipe references a nonexistent resource")
        "consumption_resource":
            return TranslationServer.translate("Consumption rule references a nonexistent product")
        "consumption_group":
            return TranslationServer.translate("Consumption rule references a nonexistent goods group")
        "prerequisite":
            return TranslationServer.translate("Technology requires a nonexistent technology")
        "road_level":
            return TranslationServer.translate("Road level: wrong or duplicate number")
        "road_max_speed":
            return TranslationServer.translate("Road max speed must be greater than zero")
        "road_work_cost":
            return TranslationServer.translate("Road work cost cannot be negative")
        "zone_axes":
            return TranslationServer.translate("Climate zone: unknown climate axis value")
        "zone_terrain":
            return TranslationServer.translate("Climate zone: the family is not mapped to a terrain of that family")
        _:
            # An unknown kind of the check: we show the machine name — by it one can see
            # what is missing in CHECK_ORDER, and it survives any language.
            return kind

# The index of the origin of the entities of the current run: "collection:id" → file+line.
# It is filled in in validate(), and is read in _add(). It is empty, if the data has come
# from somewhere without the index (the synthetic data in the test) — then the problem
# simply does not get the rows with the file, and does not crash.
var _sources: Dictionary = {}

# The registries of the free keys of the dictionaries for the current run (see KEY_* above). They
# are built by the walk of the tree, once per run, and are read by _check_dict_key — the same
# reason as for _sources: passing them through a dozen signatures would only add noise.
var _registries: Dictionary = {}

# The data object of the current run: it is needed by gd_craft_alternatives to normalize
# the alternative ingredients. It is set in validate().
var _game_data = null

# The kind of the owning entity → the top-level collection in data/*.json, in which
# it is declared. It is needed in order to find its file: the key of the index of the origin
# is built as "<collection>:<id>".
#
# The owner "product" is a resource, and it lies in the common collection "resources"
# (the raw materials and the products in one list, the type is distinguished by the field "type"). Therefore
# SOURCE_COLLECTIONS differs from ENTITIES: there "product" is an ENTITY
# (an object being referred to), here — the kind of the OWNER (an object which
# refers).
const SOURCE_COLLECTIONS := {
    "recipe": "crafts",
    "building": "buildings",
    "improvement": "improvements",
    "technology": "technologies",
    "product": "resources",
    "group": "product_groups",
    "road": "roads",
    # The consumption rule does not declare itself by the field "id" (see data_loader
    # _remember_consumption_sources), therefore its "resource" serves as the identifier of the record in the index
    # of the origin.
    "consumption_rule": "consumption",
    # The kinds that are needed only by the checks of the identifiers: they are declared in
    # their collections, but no other check refers to them.
    "terrain": "terrains",
    "cover": "covers",
    "climate_zone": "climate_zones",
    "era": "eras",
    "quality_level": "quality_levels",
    "special_action": "special_actions",
}

# The order of the output of the blocks of problems in the window.
const CHECK_ORDER := [
    "unknown_field",
    "unknown_key",
    "blacklist",
    "id_charset",
    "id_lookalike",
    "produced_in",
    "result",
    "product_source",
    "improved_by",
    "unlock_improvement",
    "unlock_tech",
    "profession",
    "category",
    "group_member",
    "resource_group",
    "resource",
    "consumption_resource",
    "consumption_group",
    "prerequisite",
    "road_level",
    "road_max_speed",
    "road_work_cost",
    "zone_axes",
    "zone_terrain",
]


# The main entry point. gd is any object with the fields of GameData
# (the autoload GameData or a separate instance in the test).
# It returns an array of the records of the problems (see the header of the file), empty — if everything is clean.
func validate(gd: Object) -> Array:
    var problems: Array = []
    # The index of the origin of the entities (the file + the line of the declaration) is needed by all
    # the checks at once, and passing it through every function would mean
    # adding an extra parameter to a dozen signatures. Therefore it lives on
    # the instance and is filled in once per run.
    _sources = _source_index(gd)
    _game_data = gd

    var buildings := _index_by_id(gd.buildings)
    var technologies := _index_by_id(gd.technologies)
    var categories := _index_by_id(gd.categories)
    # All three are already id -> data dictionaries in GameData (data_loader.gd).
    var improvements: Dictionary = gd.improvements
    var professions: Dictionary = gd.professions
    var products: Dictionary = gd.products
    var raw_resources: Dictionary = gd.raw_resources
    var product_groups: Dictionary = gd.product_groups
    var group_names: Dictionary = gd.product_group_names
    # These three are already the dictionaries id -> data in GameData (data_loader.gd).
    var terrains: Dictionary = gd.terrains
    var all_resources: Dictionary = {}
    all_resources.merge(raw_resources)
    all_resources.merge(products)

    _validate_schema(gd, problems)
    _validate_identifiers(gd, problems)
    _validate_blacklist(gd, problems)
    _validate_crafts(gd.crafts, buildings, technologies, all_resources, product_groups, problems)
    _validate_buildings(gd.buildings, technologies, professions, problems)
    _validate_improvements(improvements, technologies, professions, problems)
    _validate_resources(products, raw_resources, categories, technologies, improvements, problems)
    _validate_product_sources(products, _produced_ids(gd, all_resources), problems)
    _validate_product_groups(product_groups, group_names, products, problems)
    _validate_consumption(gd.consumption_rules, products, product_groups, professions, problems)
    _validate_technologies(technologies, problems)
    _validate_roads(gd.roads, technologies, problems)
    _validate_climate_zones(gd.climate_zones, terrains, _climate_families(terrains, gd.map_config), problems)

    _sort_problems(problems)
    return problems


# --- THE WHITELIST OF THE FIELDS: THE WALK -------------------------------------
#
# The walk goes over the merged tree of data/*.json (GameData.raw_data), and not over the assembled
# collections: a goods group keeps only its members in GameData (the name and the icon live in side
# dictionaries), the balance is flattened out of its blocks, and a collection the loader does not know
# is dropped altogether — in the assembled data there is nothing left to point at. The tree is the only
# place where every key the author wrote is still present, with its own file and line.
#
# The same walk checks the free keys of the dictionaries (unknown_key): they are identifiers, and the
# registries they are checked against are read from this very tree (see _key_registries).
#
# Data without the tree (the synthetic set of the test, a GameData assembled by hand) skips the check:
# there is nothing to walk, and the cross-reference checks above do not depend on it.
func _validate_schema(gd: Object, problems: Array) -> void:
    var data = gd.get("raw_data")
    if not (data is Dictionary) or data.is_empty():
        return
    _registries = _key_registries(data)
    for key in data.keys():
        var collection := str(key)
        var rule = SCHEMA.get(collection, null)
        if not (rule is Dictionary):
            _add_unknown_field(problems, {"collection": collection, "id": "", "name": "", "path": ""},
                    collection, "", [], {"root": true})
            continue
        var value = data[key]
        # A collection of records: every element is an entity of its own, and the path of a problem
        # starts at the record, not at the collection.
        if rule.has("array") and value is Array:
            for entity in value:
                _walk_schema(entity, rule["array"], _entity_context(collection, entity), problems)
        else:
            _walk_schema(value, rule, {"collection": collection, "id": "", "name": "", "path": ""},
                    problems)


# The context of one record: which collection it belongs to, how it is addressed in the origin index
# ("collection:id") and how it is named in the message.
func _entity_context(collection: String, entity) -> Dictionary:
    var context := {"collection": collection, "id": "", "name": "", "path": ""}
    if not (entity is Dictionary):
        return context
    var id_field := str(ENTITY_ID_FIELDS.get(collection, "id"))
    var id := _as_id(entity.get(id_field, ""))
    context["id"] = id
    context["name"] = _entity_name(entity, id)
    return context


# One value against its rule. A rule the walker does not recognise as a marker is the set of the
# fields of an object (see the vocabulary above SCHEMA).
func _walk_schema(value, rule, context: Dictionary, problems: Array) -> void:
    if not (rule is Dictionary) or rule.is_empty():
        return
    if rule.has("id_map"):
        _walk_id_map(value, rule, context, problems)
        return
    if rule.has("any"):
        for alternative in rule["any"]:
            if _rule_accepts(alternative, value):
                _walk_schema(value, alternative, context, problems)
                return
        return
    if rule.has("array"):
        if not (value is Array):
            return
        var index := 0
        for item in value:
            _walk_schema(item, rule["array"], _child_context(context, "[%d]" % index), problems)
            index += 1
        return
    if rule.has("blocks"):
        _walk_blocks(value, rule["blocks"], context, problems)
        return
    _walk_fields(value, rule, context, problems)


# An object whose keys are ids (the resources of a "produces", the improvements of a multiplier).
#
# The keys are the data, not the model: the field whitelist knows nothing about them, and the value
# under a wrong key is lost without a trace. Therefore a rule may name the registry its keys have to
# belong to ("keys"), and every key outside it is reported. A rule without "keys" (a recipe's
# ingredients — the check of the recipes already walks them) leaves the keys alone.
#
# The values are descended into only when the rule describes them.
func _walk_id_map(value, rule, context: Dictionary, problems: Array) -> void:
    if not (value is Dictionary):
        return
    var inner = rule.get("id_map", LEAF)
    var registry := str(rule.get("keys", ""))
    for key in value.keys():
        var name := str(key)
        if not registry.is_empty():
            _check_dict_key(problems, context, registry, name)
        _walk_schema(value[key], inner, _child_context(context, name), problems)


# One key of a dictionary against its registry.
#
# An empty registry is not a broken key: it means the tree has no such collection at all (the name
# of the collection is misspelled, the file is not loaded). That is a problem of its own — reported
# once by the walk of the root — and reporting every key of every map here would bury it under
# hundreds of records pointing at the same cause.
func _check_dict_key(problems: Array, context: Dictionary, registry: String, key: String) -> void:
    var known: Dictionary = _registries.get(registry, {})
    if known.is_empty() or known.has(key):
        return
    var target := str(REGISTRY_TARGETS.get(registry, "product"))
    # The reference to an @-group is written with the "@", and it is the group that is missing.
    if registry == KEY_GROUP_REFS and key.begins_with("@"):
        target = "group"
    # The field is the path of the MAP, and not of the key: the key itself goes into ref_id, where
    # the window highlights it.
    var field := str(context.get("path", ""))
    if field.is_empty():
        field = str(context.get("collection", ""))
    var collection := str(context.get("collection", ""))
    # The owner is an entity only when the collection is one AND the record has an identifier: a
    # config block has neither, and the message names the field instead (see build_text).
    var owner_kind := str(OWNER_KINDS.get(collection, ""))
    if owner_kind.is_empty() or str(context.get("id", "")).is_empty():
        owner_kind = ""
    _push(problems, "unknown_key", target, key, owner_kind,
            str(context.get("name", "")), str(context.get("id", "")), field,
            {}, _origin_key(context))


# The registries of the keys, built from the declarations of the same tree that is walked.
#
#   resources    — every record of the "resources" collection: the raw materials of the map and the
#                  products of the city lie in one list (they differ by the field "type"), and the
#                  game looks both of them up in one space (GameData.products + raw_resources);
#   group_refs   — the same plus "@<group>": additional_cost accepts both;
#   covers, terrains, improvements — the ids of the collections of the same name;
#   priorities   — the VALUES of priority_options, not ids: the options are declared by a list.
func _key_registries(data: Dictionary) -> Dictionary:
    var sets := {}
    for registry in PLAIN_REGISTRIES:
        sets[registry] = _declared_ids(data.get(registry, []))

    var refs: Dictionary = (sets[KEY_RESOURCES] as Dictionary).duplicate()
    for group_id in _declared_ids(data.get("product_groups", [])):
        refs["@" + str(group_id)] = true
    sets[KEY_GROUP_REFS] = refs

    # The terrain families: the field "family" of the terrain records. A key of terrain_config names
    # either a family (the climate turns every hex of it into the variety of its belt) or a terrain
    # the climate leaves alone (a lake, a desert), so the terrain registry takes both.
    var families := {}
    for record in data.get(KEY_TERRAINS, []):
        if record is Dictionary:
            var family := str(record.get("family", ""))
            if family != "":
                families[family] = true
    sets[KEY_TERRAIN_FAMILIES] = families
    var terrain_names: Dictionary = sets[KEY_TERRAINS]
    for family in families.keys():
        terrain_names[family] = true
    sets[KEY_TERRAINS] = terrain_names

    var priorities := {}
    for option in _as_string_list(data.get("priority_options", [])):
        priorities[option] = true
    # data/qualities.json keeps the scale at the top level; the loader also accepts it nested under
    # "qualities" (see QUALITY_SCALE_FIELDS).
    var qualities = data.get("qualities", null)
    if qualities is Dictionary:
        for option in _as_string_list(qualities.get("priority_options", [])):
            priorities[option] = true
    sets[KEY_PRIORITIES] = priorities

    return sets


# The identifiers declared by a collection of records: {"id": …} → {id: true}.
#
# id_field is the field the records are addressed by, where it is not "id" (the
# consumption rules — "resource", see ENTITY_ID_FIELDS).
func _declared_ids(records, id_field: String = "id") -> Dictionary:
    var out := {}
    if not (records is Array):
        return out
    for record in records:
        if not (record is Dictionary):
            continue
        var id := _as_id(record.get(id_field, ""))
        if not id.is_empty():
            out[id] = true
    return out


# --- THE BLACKLIST ---------------------------------------------------------------
#
# A blacklisted entity is REMOVED from the merged tree, so the tree can no longer tell a
# removed one from an entity that never existed: both are simply absent. The loader
# therefore keeps what it removed (GameData.blacklisted, filled by data_loader
# ._apply_blacklist), and an entry that is neither present in its collection nor removed
# is a typo — a silent no-op the author believes works.
#
# The blacklist of the tree is the union of the mods' blacklists (a top-level dictionary
# is merged like any other), so an entity a later mod brought back is present and passes;
# the record of the removed ones covers the rest. The shape of the blacklist itself —
# an unknown collection, a value that is not a list — is the whitelist's business
# (BLACKLIST_FIELDS), and this check skips what the whitelist already reports.
func _validate_blacklist(gd: Object, problems: Array) -> void:
    var data = gd.get("raw_data")
    if not (data is Dictionary) or data.is_empty():
        return
    var blacklist = data.get("blacklist", null)
    if not (blacklist is Dictionary) or blacklist.is_empty():
        return
    var removed: Dictionary = gd.get("blacklisted")
    if not (removed is Dictionary):
        removed = {}
    for collection in blacklist.keys():
        var name := str(collection)
        if not BLACKLIST_COLLECTIONS.has(name):
            continue
        var declared := _declared_ids(data.get(name, []),
                str(ENTITY_ID_FIELDS.get(name, "id")))
        var gone: Dictionary = removed.get(name, {})
        if not (gone is Dictionary):
            gone = {}
        for id in _as_string_list(blacklist[collection]):
            if declared.has(id) or gone.has(id):
                continue
            _push(problems, "blacklist", str(BLACKLIST_KINDS.get(name, "product")), id,
                    "", "", "", name, {}, "@key:blacklist")


func _walk_fields(value, fields: Dictionary, context: Dictionary, problems: Array) -> void:
    if not (value is Dictionary):
        return
    for key in value.keys():
        var field := str(key)
        var child := _child_context(context, field)
        if not fields.has(field):
            _add_unknown_field(problems, context, field, str(child["path"]), fields.keys(), {})
            continue
        _walk_schema(value[key], fields[field], child, problems)


# The balance of data/game_balance.json: the constants are grouped into named blocks, and the loader
# accepts a constant both inside its block and at the top level (data_loader._flatten_balance_blocks),
# therefore the top level allows the block names AND any constant of any block.
func _walk_blocks(value, blocks: Dictionary, context: Dictionary, problems: Array) -> void:
    if not (value is Dictionary):
        return
    var flat := {}
    for block in blocks.values():
        if block is Dictionary:
            for field in block.keys():
                flat[field] = true
    for key in value.keys():
        var field := str(key)
        var child := _child_context(context, field)
        if blocks.has(field):
            # The block is not an entity of the data, but it is the owner of the constants in it,
            # and the message has to name it: "in the city block" is what the author is looking for.
            var block_context := context.duplicate()
            block_context["name"] = field
            block_context["path"] = field
            _walk_schema(value[key], blocks[field], block_context, problems)
        elif not flat.has(field):
            _add_unknown_field(problems, context, field, str(child["path"]), blocks.keys(), {})


# Whether a rule expects this container at all. A field of another shape is not a key problem and is
# left alone: the model is checked, not the types.
static func _rule_accepts(rule, value) -> bool:
    if not (rule is Dictionary) or rule.is_empty():
        return true
    if rule.has("array"):
        return value is Array
    return value is Dictionary


# The context of a nested value: the same record, one step deeper in the path.
static func _child_context(context: Dictionary, segment: String) -> Dictionary:
    var child := context.duplicate()
    var path := str(context.get("path", ""))
    if segment.begins_with("["):
        child["path"] = path + segment
    elif path.is_empty():
        child["path"] = segment
    else:
        child["path"] = path + "." + segment
    return child


# The record of one unknown key.
#
# ref_id is the key itself — the window highlights exactly it. field is the path inside the record
# ("breeding[2].terrain"): a nested key has to be findable, and "terrain" alone would read as a field
# of the record itself. The allowed list goes into the message: a typo is fixed by looking at the right
# spelling, and the record with 26 fields is not something to guess.
func _add_unknown_field(problems: Array, context: Dictionary, field: String, path: String,
        allowed: Array, extra: Dictionary) -> void:
    var collection := str(context.get("collection", ""))
    var entity_id := str(context.get("id", ""))
    var source_name := str(context.get("name", ""))
    if source_name.is_empty():
        source_name = collection
    var payload := extra.duplicate()
    payload["allowed"] = allowed
    _push(problems, "unknown_field", "", field, collection, source_name, entity_id, path,
            payload, _origin_key(context))


# The key of the origin index for a record: its own declaration ("crafts:bread") when the index knows
# it, otherwise the file where the collection itself is declared ("@key:group_bonuses"). A collection
# without an indexed id — the diversity bonuses of data/bonuses.json have no "id" field — still gets a
# file, only a coarser one: the first line of the collection instead of the line of the record.
func _origin_key(context: Dictionary) -> String:
    var collection := str(context.get("collection", ""))
    var entity_id := str(context.get("id", ""))
    if not entity_id.is_empty():
        var exact := "%s:%s" % [collection, entity_id]
        if _sources.has(exact):
            return exact
    return "@key:%s" % collection


    # The raw materials and the products in one space for the references to the resources:
    # a recipe is allowed to require both "clay" (a raw material) and "flour" (a product).
    #
    # --- THE IDENTIFIERS: THE ALPHABET AND THE LOOKALIKES ----------------------------------
    #
    # ONLY the declarations are checked (the field "id"), and not the references to them. This is not
    # a simplification, but a consequence of the structure of the other checks: if a reference
    # contains the same non-ASCII character as the declaration, — this check will find
    # the problem; if it points to a Latin identifier — it will be found by any of
    # the checks of the broken references. A separate pass over the references would not find a single
    # new case.
func _validate_identifiers(gd: Object, problems: Array) -> void:
    # All the declared identifiers: id → the details about the declaration.
    # It is filled in by one pass over the collections, because the lookalikes are searched
    # over ALL the declarations at once: "сarmine" by itself is a typo in one
    # line, and next to the already existing "carmine" — also a dead duplicate.
    var declared := {}

    for entry in IDENT_COLLECTIONS:
        var field := str(entry["field"])
        var kind := str(entry["kind"])
        var collection = gd.get(field)

        if collection is Dictionary:
            for key in collection:
                var entity = collection[key]
                # The key of the dictionary is the same id as in the field "id". We take the id from
                # the data, but even if the field has been lost — the key is still known.
                var id := _as_id(entity.get("id", "")) if entity is Dictionary else ""
                if id.is_empty():
                    id = str(key)
                _collect_identifier(declared, problems, field, kind, id,
                        entity if entity is Dictionary else {})
            # The quality levels lie not in a dictionary, but in an array INSIDE it
            # (data/qualities.json → "quality_levels": [...]) — a pass over the
            # fields of GameData will not see such a nested list.
            _collect_quality_levels(declared, problems, collection)
        elif collection is Array:
            for entity in collection:
                if not (entity is Dictionary):
                    continue
                _collect_identifier(declared, problems, field, kind,
                        _as_id(entity.get("id", "")), entity)

    _check_lookalikes(declared, problems)


func _collect_quality_levels(declared: Dictionary, problems: Array,
        collection: Dictionary) -> void:
    var levels = collection.get(QUALITY_LEVELS_FIELD, null)
    if not (levels is Array):
        return
    for level in levels:
        if not (level is Dictionary):
            continue
        _collect_identifier(declared, problems, QUALITY_LEVELS_FIELD,
                "quality_level", _as_id(level.get("id", "")), level)


# Remembers the declaration and checks its alphabet.
func _collect_identifier(declared: Dictionary, problems: Array, collection: String,
        kind: String, id: String, entity: Dictionary) -> void:
    if id.is_empty():
        return
    declared[id] = {"collection": collection, "kind": kind, "entity": entity}
    _check_ident_charset(problems, id, kind, entity)


# The positions of the characters outside the allowed alphabet:
# [{ "pos": int, "char": String, "code": int, "block": String, "lookalike": String }, …]
#
# block — the ORIGINAL name of the block (the English msgid), and not a ready-made label:
# it only becomes a translation at the moment the text is assembled (build_text), otherwise
# a language change would not rebuild the message that has already been assembled.
func _bad_ident_chars(id: String) -> Array:
    var bad: Array = []
    var index := 0
    for ch in id:
        if not IDENT_CHARS.contains(ch) and not IDENT_UPPER.contains(ch):
            bad.append({
                "pos": index,
                "char": ch,
                "code": ch.unicode_at(0),
                "block": _ident_block_name(ch.unicode_at(0)),
                "lookalike": str(IDENT_LOOKALIKES.get(ch, "")),
            })
        index += 1
    return bad


# block is the ORIGINAL name of the block (the English msgid), and not a ready label:
# it becomes a translation only at the building of the text (build_text), otherwise a change of
# the language would not reassemble the already built message.
func _ident_block_name(code: int) -> String:
    for block in IDENT_BLOCKS:
        if code >= int(block["from"]) and code <= int(block["to"]):
            return str(block["key"])
    return ""


# The key of the Unicode block in which the character has got. An empty string — the block is not
# listed: labelling it at random is less honest than not labelling it at all.
# which block it is from — this is the second half of the value of the hint (the first one is the
# code itself).
#
# msgid as literals directly in the calls — for the same reason as in
# entity_forms(): otherwise the catalogue builder will not see these three words.
static func _block_label(key: String) -> String:
    match key:
        "cyrillic":
            return TranslationServer.translate("Cyrillic")
        "greek":
            return TranslationServer.translate("Greek")
        "fullwidth_latin":
            return TranslationServer.translate("Fullwidth Latin")
        _:
            return ""


# One problem per identifier with ALL the bad characters at once: in "cоal"
# there are two of them, and one line has to be fixed — two rows in the window about the same
# fix only annoy. The list of the bad characters goes into the structure of the
# problem ("bad_chars"), the text is assembled by build_text.
func _check_ident_charset(problems: Array, id: String, kind: String,
        entity: Dictionary) -> void:
    var bad := _bad_ident_chars(id)
    if bad.is_empty():
        return

    _push(problems, "id_charset", kind, id, kind,
            _entity_name(entity, id), id, "id", {"bad_chars": bad})


# Two identifiers differing only by the lookalike characters ("carmine" and
# "сarmine") — for the engine these are TWO different resources. A reference to the Latin
# "carmine" passes any check, because it exists, and the Cyrillic one lies dead weight. The real
# checks of the references skip this case entirely — therefore it is caught here.
func _check_lookalikes(declared: Dictionary, problems: Array) -> void:
    # The normalized id → ALL the declarations giving such a form.
    var groups := {}
    for id in declared:
        var key := _ascii_fold(id)
        if not groups.has(key):
            groups[key] = []
        (groups[key] as Array).append(id)

    for key in groups:
        var members: Array = groups[key]
        if members.size() < 2:
            # A loner. If it is the Cyrillic, id_charset has already caught it: there is
            # nothing to compare with.
            continue
            # A loner. If it is the Cyrillic, id_charset has already caught it: there is
            # nothing to compare with.
        var latin := ""
        for id in members:
            if _ascii_fold(id) == id:
                latin = id
                break

        # We report one problem per group: several participants are
        # the same typo, and there is no reason to list it twice.
        for id in members:
            if id == latin:
                continue
            var info: Dictionary = declared[id]
            var latin_info: Dictionary = declared[latin]

        # In a group of two or more participants the Latin spelling is necessarily present:
        # two DIFFERENT purely Latin ids cannot normalize into one
        # string (for the Latin the fold is an identity mapping).
        # Therefore all the "extra" ones are those where fold has replaced something.
            _push(problems, "id_lookalike", str(latin_info["kind"]), latin,
                    str(info["kind"]), _entity_name(info["entity"], id), id, "id",
                    {"latin": latin})


# Brings the characters that are indistinguishable from the Latin ones to the Latin look. It serves
# ONLY for the comparison of the ids with each other, and never — for the editing of the data.
func _ascii_fold(id: String) -> String:
    var result := ""
    for ch in id:
        result += str(IDENT_LOOKALIKES.get(ch, ch))
    return result
        #
        # We report one problem per group: several participants are
        # the same typo, and there is no reason to list it twice.
func _validate_roads(roads, technologies: Dictionary, problems: Array) -> void:
    if not (roads is Array):
        return
    var seen_levels := {}
    for road in roads:
        if not (road is Dictionary):
            continue
        var road_id := str(road.get("id", ""))
        var rname := _entity_name(road, road_id)

        _check_tech_ref(road.get("unlock_tech", null), technologies, problems,
                "road", rname, road_id, "unlock_tech")

        var level := int(road.get("level", 0))
        if level <= 0:
            _add(problems, "road_level", "road", road_id,
                    "road", rname, road_id, "level")
        elif seen_levels.has(level):
            _add(problems, "road_level", "road", road_id,
                    "road", rname, road_id, "level")
        else:
            seen_levels[level] = true

        if int(road.get("max_speed", 0)) <= 0:
            _add(problems, "road_max_speed", "road", road_id,
                    "road", rname, road_id, "max_speed")
        if int(road.get("work_cost", 0)) < 0:
            _add(problems, "road_work_cost", "road", road_id,
                    "road", rname, road_id, "work_cost")


# --- THE CLIMATE ZONES ------------------------------------------------------------
# The two axes are enumerated, and the generator compares them with its own constants: any other
# spelling would silently remove the zone from the map (the pair stays empty and the generator
# falls back to another zone of the same temperature).
const ZONE_TEMPERATURES := ["polar", "cold", "mild", "subtropical", "tropical"]
const ZONE_HUMIDITIES := ["wet", "dry"]

# The families the climate turns into varieties: the keys of terrain_config that are not a terrain
# of their own (a lake or a desert is placed as it is). These are exactly the families every zone
# has to map, otherwise the hexes of the family keep a raw family name on the map instead of a
# terrain.
func _climate_families(terrains: Dictionary, map_config: Dictionary) -> Array:
    var declared := {}
    for terrain_id in terrains.keys():
        var family := str(terrains[terrain_id].get("family", ""))
        if family != "":
            declared[family] = true
    var result: Array = []
    for key in map_config.get("terrain_config", {}).keys():
        var name := str(key)
        if declared.has(name) and not result.has(name):
            result.append(name)
    result.sort()
    return result

func _validate_climate_zones(zones, terrains: Dictionary, families: Array, problems: Array) -> void:
    if zones == null:
        return
    var records: Array = []
    if zones is Dictionary:
        records = zones.values()
    elif zones is Array:
        records = zones
    for zone in records:
        if not (zone is Dictionary):
            continue
        var zone_id := str(zone.get("id", ""))
        var zname := _entity_name(zone, zone_id)

        var temperature := str(zone.get("temperature", ""))
        if not ZONE_TEMPERATURES.has(temperature):
            _add(problems, "zone_axes", "climate_zone", temperature, "climate_zone", zname, zone_id, "temperature")
        var humidity := str(zone.get("humidity", ""))
        if not ZONE_HUMIDITIES.has(humidity):
            _add(problems, "zone_axes", "climate_zone", humidity, "climate_zone", zname, zone_id, "humidity")

        var mapping: Variant = zone.get("terrain", {})
        if not (mapping is Dictionary):
            continue
        for family in families:
            var terrain_id := str(mapping.get(family, ""))
            if terrain_id == "":
                # A missing mapping: the field names the family, the reference stays empty.
                _add(problems, "zone_terrain", "climate_zone", "", "climate_zone", zname, zone_id, family)
                continue
            if not terrains.has(terrain_id):
                _add(problems, "zone_terrain", "climate_zone", terrain_id, "climate_zone", zname, zone_id, family)
                continue
            if str(terrains[terrain_id].get("family", "")) != family:
                _add(problems, "zone_terrain", "climate_zone", terrain_id, "climate_zone", zname, zone_id, family)


# --- THE RECIPES ---------------------------------------------------------------
# produced_in, result / display_result, the resources (including the @-groups), unlock_tech.
func _validate_crafts(crafts, buildings: Dictionary, technologies: Dictionary,
        all_resources: Dictionary, product_groups: Dictionary, problems: Array) -> void:
    for craft in crafts:
        if not (craft is Dictionary):
            continue
        var craft_id := str(craft.get("id", ""))
        var craft_name := _entity_name(craft, craft_id)

            # The owner of the problem is the corrupted declaration (it is the one that has to be deleted),
            # therefore it is in the source_id, and not the Latin spelling. The texts
            # are assembled by build_text from this structure.
        for building_id in _as_string_list(craft.get("produced_in", [])):
            if building_id == ANY_BUILDING_MARKER:
                continue
            if not buildings.has(building_id):
                _add(problems, "produced_in", "building", building_id,
                        "recipe", craft_name, craft_id, "produced_in")

        # Brings the characters that are indistinguishable from the Latin ones to the Latin look. It serves
        # ONLY for the comparison of the ids with each other, and never — for the editing of the data.
        for field in ["result", "display_result"]:
            for product_id in _as_dict(craft.get(field, {})).keys():
                if not all_resources.has(str(product_id)):
                    _add(problems, "result", "product", str(product_id),
                            "recipe", craft_name, craft_id, field)

        # The reference to a technology (common with the other entities) and the level
        # numbers themselves are checked. We check the numbers because they hit the gameplay silently:
        # max_speed = 0 will give a segment that carries nothing, and this is visible only in the
        # game; work_cost with a fraction will be rounded up and will "eat" a coin for no reason.
        # The resources in both admissible forms: the classical object { key: amount }
        # and the array of OR-groups (the alternative ingredients, see GameData.gd).
        # Every variant of every OR-group is checked the same way as a classical key.
        for variant in _craft_resource_variants(craft):
            var res_key := str(variant.get("key", ""))
            if res_key.is_empty():
                continue
            if res_key.begins_with("@"):
                if not product_groups.has(res_key.substr(1)):
                    _add(problems, "resource_group", "group", res_key,
                            "recipe", craft_name, craft_id, "resources",
                            _at_sign_hint(res_key, all_resources, product_groups))
            elif not all_resources.has(res_key):
                _add(problems, "resource", "product", res_key,
                        "recipe", craft_name, craft_id, "resources",
                        _at_sign_hint(res_key, all_resources, product_groups))

        # --- THE RECIPES ---------------------------------------------------------------
        # produced_in, result / display_result, the resources (including the @-groups), unlock_tech.
        _check_tech_ref(craft.get("unlock_tech", ""), technologies, problems,
                "recipe", craft_name, craft_id, "unlock_tech")


        # produced_in → a building. "*" is the service marker "in any building".
        # unlock_tech, profession.
func _validate_buildings(buildings, technologies: Dictionary, professions: Dictionary,
        problems: Array) -> void:
    for building in buildings:
        if not (building is Dictionary):
            continue
        var building_id := str(building.get("id", ""))
        var building_name := _entity_name(building, building_id)

        _check_tech_ref(building.get("unlock_tech", ""), technologies, problems,
                "building", building_name, building_id, "unlock_tech")
        _check_profession_ref(building.get("profession", ""), professions, problems,
                "building", building_name, building_id, "profession")


        # result (and its displayable variant) → a resource.
        # unlock_tech, profession.
func _validate_improvements(improvements: Dictionary, technologies: Dictionary,
        professions: Dictionary, problems: Array) -> void:
    for improvement_id in improvements:
        var improvement = improvements[improvement_id]
        if not (improvement is Dictionary):
            continue
        var imp_id := str(improvement_id)
        var imp_name := _entity_name(improvement, imp_id)

        _check_tech_ref(improvement.get("unlock_tech", ""), technologies, problems,
                "improvement", imp_name, imp_id, "unlock_tech")
        _check_profession_ref(improvement.get("profession", ""), professions, problems,
                "improvement", imp_name, imp_id, "profession")


        # resources → a resource or an @-group of products.
        # improved_by, unlock_improvement, unlock_tech, category.
func _validate_resources(products: Dictionary, raw_resources: Dictionary,
        categories: Dictionary, technologies: Dictionary, improvements: Dictionary,
        problems: Array) -> void:
    for res_id in products:
        _validate_resource(res_id, products[res_id], categories, technologies,
                improvements, problems, true)
    for res_id in raw_resources:
        _validate_resource(res_id, raw_resources[res_id], categories, technologies,
                improvements, problems, false)


func _validate_resource(res_id, resource, categories: Dictionary, technologies: Dictionary,
        improvements: Dictionary, problems: Array, is_product: bool) -> void:
    if not (resource is Dictionary):
        return
    var rid := str(res_id)
    var rname := _entity_name(resource, rid)

        # unlock_tech → a technology.
    var improved_by := _as_id(resource.get("improved_by", ""))
    if not improved_by.is_empty() and not improvements.has(improved_by):
        _add(problems, "improved_by", "improvement", improved_by,
                "product", rname, rid, "improved_by")

    # --- THE BUILDINGS ---------------------------------------------------------------
    var unlock_improvement := _as_id(resource.get("unlock_improvement", ""))
    if not unlock_improvement.is_empty() and not improvements.has(unlock_improvement):
        _add(problems, "unlock_improvement", "improvement", unlock_improvement,
                "product", rname, rid, "unlock_improvement")

    _check_tech_ref(resource.get("unlock_tech", ""), technologies, problems,
            "product", rname, rid, "unlock_tech")

    # --- THE IMPROVEMENTS ------------------------------------------------------------
    var category := _as_id(resource.get("category", ""))
    if is_product and not category.is_empty() and not categories.has(category):
        _add(problems, "category", "category", category,
                "product", rname, rid, "category")


    # --- THE RESOURCES (the raw materials + the products) -------------------------------------------
    #
    # improved_by → an improvement (the field of the raw material: "by which improvement it is grown").
    #
    # ONLY the products are checked. The raw materials (gd.raw_resources) by definition
    # are taken from the map by the generation, therefore their source always exists; the check of
    # the raw materials would give false positives on each of the 112 resources.
func _validate_product_sources(products: Dictionary, produced_ids: Dictionary,
        problems: Array) -> void:
    for product_id in products:
        var pid := str(product_id)
        if produced_ids.has(pid):
            continue
        var product = products[product_id]
        if not (product is Dictionary):
            continue
        _add_missing_source(problems, _entity_name(product, pid), pid)


# The set of the ids which are released somewhere at least.
#
# Four paths of the appearance of a product — all four are needed, otherwise the check is noisy:
#   result of a recipe        — the ordinary output of the crafting;
#   display_result            — a pseudo-output: it does not create a real product, but
#                              is drawn as a result ("Science", science);
#   produces of a resource    — the production by an improvement on the map. Any resource
#                              (a raw material or a product): the mechanism is the same one;
#   additional_yield          — the fixed output of a building per second (the science of
#                              the library and the scriptorium), i.e. such a same source.
#
#
# The fifth path — the forest plot — is not visible in produces at all and is added
# separately (see the constants LUMBERJACK_* in the header of the file).
func _produced_ids(gd: Object, all_resources: Dictionary) -> Dictionary:
    var produced := {}

    for craft in gd.crafts:
        if not (craft is Dictionary):
            continue
        for field in ["result", "display_result"]:
            for produced_id in _as_dict(craft.get(field, {})).keys():
                produced[str(produced_id)] = true

    for res_id in all_resources:
        var resource = all_resources[res_id]
        if not (resource is Dictionary):
            continue
        for produced_id in _as_dict(resource.get("produces", {})).keys():
            produced[str(produced_id)] = true

    for building in gd.buildings:
        if not (building is Dictionary):
            continue
        for produced_id in _as_dict(building.get("additional_yield", {})).keys():
            produced[str(produced_id)] = true

    if _lumberjack_produces(gd.improvements, gd.covers):
        produced[LUMBERJACK_PRODUCT] = true

    return produced


# The forest plot gives the wood only if BOTH conditions from the code are met:
# the improvement is declared AND the cover of the hex has an output. The condition is not a
# "declaration of intent", but a real reachability: a demolished plot or a zeroed
# wood_yield closes the cover source of the wood, and the validator must say so.
func _lumberjack_produces(improvements: Dictionary, covers: Dictionary) -> bool:
    if not improvements.has(LUMBERJACK_IMPROVEMENT):
        return false
    for cover_id in covers:
        var cover = covers[cover_id]
        if not (cover is Dictionary):
            continue
        if float(cover.get(COVER_YIELD_FIELD, 0.0)) > 0.0:
            return true
    return false


# --- THE PRODUCT GROUPS -----------------------------------------------------
# The members of an @-group → a product. It is exactly this check that catches "@oil_crops" with
# the non-existent sunflower / rapeseed / peanut.
func _validate_product_groups(product_groups: Dictionary, group_names: Dictionary,
        products: Dictionary, problems: Array) -> void:
    for group_id in product_groups:
        var members = product_groups[group_id]
        if not (members is Array):
            continue
        var gid := str(group_id)
        var gname := str(group_names.get(gid, gid))
        for member in members:
            var product_id := str(member)
            if not products.has(product_id):
                _add(problems, "group_member", "product", product_id,
                        "group", gname, gid, "products")


# --- THE CONSUMPTION RULES (data/consumption.json) ---------------------------
#
# resource → a product OR an @-group of products; profession → a profession.
#
# The check mirrors the RESOLVER GameData._build_consumption_entry, and not the common
# references of the recipes: a key without "@" is searched exactly in GameData.products. The consumption
# takes the goods from the storage, and not the raw materials from the hex, therefore "raw material" does not fit here.
#
# The most frequent breakage here is a forgotten "@": the author writes the id of a group where a
# resource is needed. Before the check such a record did not break anything: the resolver substituted
# products.get(id, {}) and a label-identifier, and there was nothing to write off, therefore
# the consumption row silently hung in the interface and was never written off.
#
# Therefore the message of a broken reference is not enough here: the name that was written is very
# often the name of a group that exists (see _at_sign_hint). The hint is passed to the problem as an
# extra field, and build_text turns it into the last sentence of the message.
func _validate_consumption(rules, products: Dictionary, product_groups: Dictionary,
        professions: Dictionary, problems: Array) -> void:
    if not (rules is Array):
        return
    for rule in rules:
        if not (rule is Dictionary):
            continue
        var res_key := _as_id(rule.get("resource", ""))
        if res_key.is_empty():
            continue
        # The "resource" of the rule serves as its identifier — it also marks
        # the row of the declaration (see SOURCE_COLLECTIONS and data_loader).
        if res_key.begins_with("@"):
            if not product_groups.has(res_key.substr(1)):
                _add(problems, "consumption_group", "group", res_key,
                        "consumption_rule", res_key, res_key, "resource",
                        _at_sign_hint(res_key, products, product_groups))
        elif not products.has(res_key):
            _add(problems, "consumption_resource", "product", res_key,
                    "consumption_rule", res_key, res_key, "resource",
                    _at_sign_hint(res_key, products, product_groups))

        # profession → a profession. The kind of the check is common with the buildings and the improvements:
        # the message "a reference to a non-existent profession" is equally true here.
        _check_profession_ref(rule.get("profession", []), professions, problems,
                "consumption_rule", res_key, res_key, "profession")


# --- THE HINT OF A FORGOTTEN "@" ------------------------------------------------
#
# The products and the goods groups live in two different namespaces: "jewelry" is looked up among
# the products, "@jewelry" — among the groups. A name that exists in the other namespace is the
# most frequent breakage of a resource reference, and a broken reference alone does not say which
# of the two the author meant: "jewelry does not exist" is technically true, but the record IS
# there, only under another name. The hint is therefore not a typo correction but a statement about
# the other namespace — "the name is taken, the sign is missing".
#
# The check of the recipes (resources) and of the consumption rules both accept a product and an
# @-group, therefore both ask for the hint; the plain registries of the two differ (a recipe takes
# raw materials too), so the registry of the valid keys is a parameter.
#
# An empty dictionary — there is nothing to suggest: no record with this name in either namespace.
# Then the message stays a plain broken reference.
static func _at_sign_hint(key: String, products: Dictionary, groups: Dictionary) -> Dictionary:
    if key.begins_with("@"):
        var bare := key.substr(1)
        # An extra "@": the author wrote "@tools", and "tools" is a product, not a group.
        if not groups.has(bare) and products.has(bare):
            return {"suggest": "product", "suggest_id": bare}
    elif not products.has(key) and groups.has(key):
        # The forgotten "@": the author wrote "jewelry", and only the group "@jewelry" exists.
        return {"suggest": "group", "suggest_id": key}
    return {}


# --- THE TECHNOLOGIES -----------------------------------------------------------
func _validate_technologies(technologies: Dictionary, problems: Array) -> void:
    for tech_id in technologies:
        var tech = technologies[tech_id]
        if not (tech is Dictionary):
            continue
        var tid := str(tech_id)
        var tname := _entity_name(tech, tid)
        for required in _flatten_prerequisites(tech.get("prerequisites", null)):
            if not technologies.has(required):
                _add(problems, "prerequisite", "technology", required,
                        "technology", tname, tid, "prerequisites")


# prerequisites → a technology. The format accepts both a flat list and a list
# of OR-groups: [[ "a", "b" ], [ "c" ]] — any one of the groups has to be researched.

func _check_tech_ref(value, technologies: Dictionary, problems: Array,
        source_kind: String, source_name: String, source_id: String, field: String) -> void:
    var tech_id := _as_id(value)
    if tech_id.is_empty() or technologies.has(tech_id):
        return
    _add(problems, "unlock_tech", "technology", tech_id,
            source_kind, source_name, source_id, field)


# --- THE CHECKS OF A SINGLE VALUE --------------------------------------------
func _check_profession_ref(value, professions: Dictionary, problems: Array,
        source_kind: String, source_name: String, source_id: String, field: String) -> void:
    for prof_id in _as_string_list(value):
        if professions.has(prof_id):
            continue
        _add(problems, "profession", "profession", prof_id,
                source_kind, source_name, source_id, field)


# --- THE ASSEMBLY OF THE RECORD OF A PROBLEM ----------------------------------------------
#
# profession is sometimes a string ("farmer") and, in some data, a list —
# we accept both formats.
#
# --- THE ASSEMBLY OF THE RECORD OF A PROBLEM ----------------------------------------------
#

# extra is the data needed only by the text of a particular check (see _push): the reference
# checks use it for the hint of a forgotten "@".
func _add(problems: Array, kind: String, target: String, ref_id: String,
        source_kind: String, source_name: String, source_id: String, field: String,
        extra: Dictionary = {}) -> void:
    _push(problems, kind, target, ref_id,
            source_kind, source_name, source_id, field, extra)


# Here and further the record is divided in two:
#   * _add / _add_missing_source / _push — the STRUCTURE (what, where, in which field);
#   * build_text — the TEXT in the current language.
#
# Previously the wordings lived in _add, and this was connected: change the language — and the already
# built messages remained on the old one. Now the text is assembled separately and
# is reassembled by the function localize_problems() (the window calls it on the signal
# LocalizationManager.locale_changed), and the check itself is NOT restarted.
#
# The owner of the problem is the product itself, therefore its id gets into both the ref_id (so that
# the window highlights it, like the other identifiers) and the source_id (so that
# the row of the declaration in the file is found). The field field is empty: there is nothing
# to point at — there is no field in which it would be worth adding the source.
func _add_missing_source(problems: Array, product_name: String, product_id: String) -> void:
    _push(problems, "product_source", "product", product_id,
            "product", product_name, product_id, "")


# The problem "the product exists, but there is nowhere to take it from".
#
# the row of the declaration of the owner. It is moved out separately from _add(), because
# the wordings of the problems of the different checks are different, while the format of the record, on the contrary,
# is the same one: both data_problems_window.gd and the test depend on it.
#
# extra is the data needed only by the text of a particular check ("bad_chars" for
# id_charset, "latin" for id_lookalike). It is the building material for
# build_text, and not a part of the structure of the problem.
func _push(problems: Array, kind: String, target: String, ref_id: String,
        source_kind: String, source_name: String, source_id: String, field: String,
        extra: Dictionary = {}, origin_key: String = "") -> void:
    # An empty string, if the origin is unknown (the data without the index) —
    # then the row with the file simply adds nothing.
    var file_path := ""
    var line := 0
    # origin_key overrides the standard "<collection>:<id>" lookup: the whitelist check addresses
    # a collection itself ("@key:<name>"), which no kind in SOURCE_COLLECTIONS stands for.
    var source_key := origin_key if not origin_key.is_empty() \
            else "%s:%s" % [str(SOURCE_COLLECTIONS.get(source_kind, "")), source_id]
    var origin = _sources.get(source_key, null)
    if origin is Dictionary:
        file_path = str(origin.get("file", ""))
        line = int(origin.get("line", 0))

    var problem := {
        "kind": kind,
        "target": target,
        "ref_id": ref_id,
        "source_kind": source_kind,
        "source_name": source_name,
        "source_id": source_id,
        "field": field,
        "file": file_path,
        "line": line,
    }
    for key in extra:
        problem[key] = extra[key]

    build_text(problem)
    problems.append(problem)


# Reassembles the text fields of problems in the CURRENT language.
#
# The check is not restarted: the structure of the problem does not depend on the language, the text
# is output from it. It is needed by the window of the problems — a change of the language in the settings happens when
# the window is already on the screen, and without this reassembly the headings and the descriptions would remain
# in the old language.
static func localize_problems(problems: Array) -> void:
    for problem in problems:
        if problem is Dictionary:
            build_text(problem)


# The text of the problem in the current language. It writes directly into the passed dictionary.
#
# The single point where ALL the user-facing wordings of the validator live: they are
# visible as a list, and the translator finds them in the catalogue as ordinary messages.
# The checks themselves (higher up in the file) do not contain a single user-facing
# text — only the structure.
#
# Each call of translate() takes ONE line and contains EXACTLY one
# string literal. This is not a matter of taste, but a requirement of the catalogue
# builder: tools/i18n_build_po.py parses the code line by line, and a multi-line
# call it would not see. A second literal it would take for msgctxt, therefore
# gluing the strings inside the call is also impossible — hence the long strings.
static func build_text(problem: Dictionary) -> void:
    var kind := str(problem.get("kind", ""))
    var headline := ""
    var where := ""

    match kind:
        "unknown_field":
            # A field the model does not describe, or a collection the loader does not read. The
            # allowed list is the point of the message: the author sees the right spelling instead
            # of guessing it from a 26-field record.
            if bool(problem.get("root", false)):
                headline = TranslationServer.translate("Unknown collection \"%s\" in the data root.") % str(problem.get("ref_id", ""))
                where = TranslationServer.translate("The loader does not read this key, so everything under it is ignored. Check the spelling of the collection name.")
            else:
                headline = TranslationServer.translate("Unknown field \"%s\" in %s.") % [str(problem.get("ref_id", "")), _quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", "")))]
                where = TranslationServer.translate("The game does not read this field: its value is silently lost. Fields allowed here: %s.") % _allowed_fields_text(problem.get("allowed", []))
        "unknown_key":
            # The second half of the same story: the field is right, but its KEY is not the id of
            # anything. The headline is the one of a broken reference — the key IS the identifier
            # that is missing — and the second line says that the key is a dictionary key, because
            # that is where the value disappears without a trace.
            var key_forms := entity_forms(str(problem.get("target", "")))
            headline = TranslationServer.translate("%s with the identifier \"%s\" does not exist.") % [str(key_forms["title"]), str(problem.get("ref_id", ""))]
            if str(problem.get("source_kind", "")).is_empty():
                # The owner is a config block (map_config, priority_names): it has no kind and no
                # name to be quoted, and the field is the only thing to point at.
                where = TranslationServer.translate("It is a key of the dictionary %s: the game looks it up by name, finds nothing and silently ignores the value under the key. Check the spelling.") % str(problem.get("field", ""))
            else:
                var owner_forms := entity_forms(str(problem.get("source_kind", "")), "recipe")
                where = TranslationServer.translate("A reference to %s is present in %s %s, field %s.") % [str(key_forms["ref"]), str(owner_forms["source"]), _quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", ""))), str(problem.get("field", ""))]
                where += " " + TranslationServer.translate("It is a key of a dictionary: the game looks it up by name, finds nothing and silently ignores the value under the key. Check the spelling.")
        "blacklist":
            # The headline is the one of an ordinary broken reference — the identifier
            # is just as absent — and the second line says where the name came from: a
            # blacklisted entity is absent BY DESIGN, the loader keeps what it removed
            # (GameData.blacklisted), and only what is in neither place gets here. The
            # collection is named: "there is no such product" and "there is no such
            # collection" are different mistakes, and the whitelist owns the second one.
            var banned_forms := entity_forms(str(problem.get("target", "")))
            headline = TranslationServer.translate("%s with the identifier \"%s\" does not exist.") % [str(banned_forms["title"]), str(problem.get("ref_id", ""))]
            where = TranslationServer.translate("It is named by the blacklist of a mod, and nothing was removed: the collection %s has no such identifier, and no mod declared it. Check the spelling — a blacklist entry that names nothing does nothing.") % str(problem.get("field", ""))
        "id_charset":
            headline = TranslationServer.translate("Identifier \"%s\" contains disallowed characters.") % str(problem.get("ref_id", ""))
            where = TranslationServer.translate("Only Latin letters a-z, digits and \"_\" are allowed. Disallowed: %s Such characters are indistinguishable from Latin ones by eye — fix this identifier and ALL references to it at once.") % _bad_chars_text(problem.get("bad_chars", []))
        "id_lookalike":
            var latin := str(problem.get("latin", ""))
            headline = TranslationServer.translate("Identifier \"%s\" is indistinguishable from \"%s\" by eye.") % [str(problem.get("source_id", "")), latin]
            where = TranslationServer.translate("There is no difference in spelling, but for the game these are DIFFERENT identifiers: everything that references \"%s\" will not reach \"%s\" and vice versa. Note that a reference to \"%s\" does NOT break anything — it is declared and looks correct, so the regular broken-reference checks did not see this typo either. Keep one identifier and rename the other in all files.") % [latin, str(problem.get("source_id", "")), latin]
        "product_source":
            headline = TranslationServer.translate("Product \"%s\" is not produced anywhere.") % str(problem.get("ref_id", ""))
            where = TranslationServer.translate("Source not found: product \"%s\" (%s) appears neither in produces of any map resource, nor in result/display_result of any recipe, nor in additional_yield of any building. Add a data source or remove the product from the file.") % [str(problem.get("source_name", "")), str(problem.get("source_id", ""))]
        "zone_axes":
            headline = TranslationServer.translate("Climate zone %s has an unknown %s \"%s\".") % [_quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", ""))), str(problem.get("field", "")), str(problem.get("ref_id", ""))]
            where = TranslationServer.translate("The temperature is one of: polar, cold, mild, subtropical, tropical; the humidity — one of: wet, dry. The generator compares the values literally, so a zone with any other spelling never appears on the map: its pair of axes stays empty and the climate falls back to another zone of the same temperature.")
        "zone_terrain":
            var family := str(problem.get("field", ""))
            var mapped := str(problem.get("ref_id", ""))
            if mapped == "":
                headline = TranslationServer.translate("Climate zone %s does not map the family \"%s\" to a terrain.") % [_quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", ""))), family]
            else:
                headline = TranslationServer.translate("Climate zone %s maps the family \"%s\" to \"%s\", which is not a terrain of that family.") % [_quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", ""))), family, mapped]
            where = TranslationServer.translate("Every zone maps each family the generator places — plain, hill, mountain, swamp, the keys of terrain_config — to a terrain that carries the same \"family\" field. Otherwise the hexes of that family keep the raw family name on the map instead of a terrain: no icon, no yields, no vegetation.")
        _:
            # The other checks are a broken REFERENCE: "There is no X with the identifier …
            # exists" + where exactly it was referred to.
            var target_forms := entity_forms(str(problem.get("target", "")))
            var source_forms := entity_forms(str(problem.get("source_kind", "")), "recipe")
            headline = TranslationServer.translate("%s with the identifier \"%s\" does not exist.") % [str(target_forms["title"]), str(problem.get("ref_id", ""))]
            where = TranslationServer.translate("A reference to %s is present in %s %s, field %s.") % [str(target_forms["ref"]), str(source_forms["source"]), _quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", ""))), str(problem.get("field", ""))]

    # The hint of the "@" is added to the message of ANY check that carries it: the check states the
    # breakage, the hint names the record the author most likely meant (see _at_sign_hint). It is a
    # separate sentence at the end, so that the window can be read in the order "what — where — why".
    if not str(problem.get("suggest", "")).is_empty():
        where += " " + _at_sign_suggestion(str(problem.get("suggest", "")), str(problem.get("suggest_id", "")))

    # «File: res://data/crafts/crafts.json, line 7.»
    var location := ""
    var file_path := str(problem.get("file", ""))
    if not file_path.is_empty():
        location = TranslationServer.translate("File: %s") % file_path
        var line := int(problem.get("line", 0))
        if line > 0:
            location += TranslationServer.translate(", line %d") % line
        location += "."

    problem["check_title"] = check_title(kind)
    # A problem that searches for no entity (an unknown field) has no target title either: the
    # fallback kind would name a product that nobody was looking for.
    var target := str(problem.get("target", ""))
    problem["target_title"] = str(entity_forms(target)["title"]) if not target.is_empty() else ""
    problem["headline"] = headline
    problem["where"] = where
    problem["location"] = location
    problem["message"] = headline + " " + where + (
        " " + location if not location.is_empty() else "")


# The allowed fields of a record on one line: "id, name, produces".
static func _allowed_fields_text(allowed) -> String:
    var parts: Array = []
    if allowed is Array:
        for field in allowed:
            parts.append(str(field))
    return ", ".join(parts)


# The list of the bad characters of the identifier on one line:
# "position 1: "с" (U+0441, Cyrillic), looks like "c" in Latin;".
#
# The name of the block is translated here, and not in _bad_ident_chars: there it is still msgid,
# and the translation must be applied at the moment of the building of the text.
static func _bad_chars_text(bad) -> String:
    var parts: Array = []
    for item in bad:
        if not (item is Dictionary):
            continue
        var part := TranslationServer.translate("position %d: \"%s\" (U+%04X") % [int(item.get("pos", 0)) + 1, str(item.get("char", "")), int(item.get("code", 0))]
        var block := str(item.get("block", ""))
        if not block.is_empty():
            part += ", %s" % _block_label(block)
        part += ")"
        # In the Latin this character looks the same. Without the hint the author
        # will read the "с" as a "c" and will not understand what the matter is.
        var lookalike := str(item.get("lookalike", ""))
        if not lookalike.is_empty():
            part += TranslationServer.translate(", looks like \"%s\" in Latin") % lookalike
        parts.append(part + ";")
    return " ".join(parts)


# The sentence of the hint of a forgotten (or an extra) "@". Two wordings, and no case forms: the
# sentence is whole, and the placeholder is only the name (see _at_sign_hint).
static func _at_sign_suggestion(kind: String, id: String) -> String:
    match kind:
        "group":
            return TranslationServer.translate("Maybe you meant the goods group \"@%s\"?") % id
        "product":
            return TranslationServer.translate("Maybe you meant the product \"%s\"?") % id
    return ""


# The owner of the reference in the brackets: "Grain Mill" (grind_grain_hand). If there is
# no name — only the identifier, so that the row does not look like "in  (), the field …".
static func _quote_owner(source_name: String, source_id: String) -> String:
    if source_id.is_empty() or source_name.is_empty() or source_name == source_id:
        return "«%s»" % (source_name if not source_name.is_empty() else source_id)
    return "«%s» (%s)" % [source_name, source_id]


# --- THE HELPERS ------------------------------------------------------------

# The index of the origin from an object with the data. The absence of the field is not an error:
# the validator must work also with the data without the index (the synthetic data
# of the test), only then the problems will remain without an indication of the file.
func _source_index(gd: Object) -> Dictionary:
    if gd == null:
        return {}
    var sources = gd.get("entity_sources")
    return sources if sources is Dictionary else {}


func _entity_name(data: Dictionary, fallback_id: String) -> String:
    var name := _as_id(data.get("name", ""))
    return name if not name.is_empty() else fallback_id


# The identifier from the field of the data.
#
# The field can be EXPLICITLY empty: in data/*.json there is "improved_by": null —
# this is "there is no improvement", and not "a reference to a non-existent improvement". A direct
# str(null) in GDScript gives the string "<null>", which is why the validator would declare
# a broken reference by every empty field and would shower false positives. Therefore
# null is brought to an empty string — as well as an absent field.
func _as_id(value) -> String:
    if value == null:
        return ""
    return str(value)


# An array of records → a dictionary id -> record (for the checks "whether it exists").
func _index_by_id(entries) -> Dictionary:
    var index := {}
    if not (entries is Array):
        return index
    for entry in entries:
        if not (entry is Dictionary):
            continue
        var id := str(entry.get("id", ""))
        if not id.is_empty():
            index[id] = entry
    return index


# Brings a field-reference to a list of strings: a string → [string], an array → as is.
# The empty values are silently discarded — an unfilled field is not an error.
func _as_string_list(value) -> Array:
    var result: Array = []
    if value == null:
        return result
    if value is String:
        var single := str(value)
        if not single.is_empty():
            result.append(single)
        return result
    if value is Array:
        for item in value:
            var item_str := str(item)
            if not item_str.is_empty():
                result.append(item_str)
    return result


func _as_dict(value) -> Dictionary:
    return value if value is Dictionary else {}


# All the ingredient variants of a recipe as the normalized OR-groups (see GameData,
# the alternative ingredients). Everything that cannot be normalized (a bare string
# without an amount, a foreign type) turns into an EMPTY variant — the check of the
# broken references must be silent on it: it is a data format error, and the game will
# skip such a variant anyway.
func _craft_resource_variants(craft: Dictionary) -> Array:
    var out: Array = []
    for or_group in gd_craft_alternatives(craft):
        for variant in or_group:
            out.append(variant)
    return out

# A wrapper over GameData.craft_alternatives for the synthetic data of the test: there
# the "GameData" is an arbitrary Node with the fields, and the method may be absent.
# In that case the recipe is treated as a classical dictionary, without the alternatives.
func gd_craft_alternatives(craft: Dictionary) -> Array:
    var game_data = _game_data
    if game_data != null and game_data.has_method("craft_alternatives"):
        return game_data.craft_alternatives(craft)
    var raw = craft.get("resources", null)
    if not (raw is Dictionary):
        return []
    var out: Array = []
    for key in raw.keys():
        var amount := int(raw[key])
        if amount <= 0:
            continue
        out.append([{"key": str(key), "amount": amount}])
    return out


# prerequisites allows [[ "a", "b" ], "c"] and [ "a", "b" ] — in both
# cases a flat list of the identifiers is needed.
func _flatten_prerequisites(value) -> Array:
    var result: Array = []
    if value is String:
        if not str(value).is_empty():
            result.append(str(value))
        return result
    if value is Array:
        for entry in value:
            if entry is Array:
                for nested in entry:
                    result.append(str(nested))
            else:
                result.append(str(entry))
    return result


# The sorting: first the order of the blocks CHECK_ORDER, inside — by the owner of the
# reference and its id. Without it the list would depend on the order of the walk of the data.
func _sort_problems(problems: Array) -> void:
    problems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var ka := str(a.get("kind", ""))
        var kb := str(b.get("kind", ""))
        var ia := CHECK_ORDER.find(ka)
        var ib := CHECK_ORDER.find(kb)
        if ia != ib:
            return ia < ib
        var sa := "%s|%s" % [str(a.get("source_id", "")), str(a.get("ref_id", ""))]
        var sb := "%s|%s" % [str(b.get("source_id", "")), str(b.get("ref_id", ""))]
        return sa < sb
    )


# How many problems there are for each kind of the check — for the heading of the window and the tests.
func count_by_kind(problems: Array) -> Dictionary:
    var counts := {}
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        counts[kind] = int(counts.get(kind, 0)) + 1
    return counts
