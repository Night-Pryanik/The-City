# data_loader.gd
@tool
extends Node

const JsonUtils = preload("res://scripts/json_utils.gd")

var terrains: Dictionary = {}
var covers: Dictionary = {}
var climate_zones: Dictionary = {}
var raw_resources: Dictionary = {}
var products: Dictionary = {}
var improvements: Dictionary = {}
var crafts: Array = []
var buildings: Array = []
var categories: Array = []
var technologies: Array = []
var groups: Array = []
var eras: Array = []
var product_groups: Dictionary = {} # id -> products
var product_group_names: Dictionary = {} # id -> human-readable name
var product_group_icons: Dictionary = {} # id -> icon file name ("" — not set)
var modifiers: Dictionary = {}
var special_actions: Dictionary = {} # id -> special action data
var qualities: Dictionary = {} # data about resource quality levels
var map_config: Dictionary = {} # the world map configuration (data/map_config.json)
var professions: Dictionary = {} # id -> profession data (data/professions.json)
var consumption_rules: Array = [] # consumption entries from data/consumption.json
var city_names: Array = [] # city name variants (data/city_names.json)
var game_balance: Dictionary = {} # the game balance (data/game_balance.json)
# The road levels (data/roads.json). roads_by_level — level -> level data:
# a road network segment stores a level number, so exactly such an index is needed.
var roads: Array = []
var roads_by_level: Dictionary = {}

# Where each entity came from: "collection:id" → { "file": String, "line": int }.
# It is filled in when reading the files (_remember_sources), because after merging
# the files into one dictionary the origin is no longer recoverable. It is needed by the runtime validator
# (scripts/data_validator.gd) in order to point at a problem to a specific file and
# line. The details are in the _remember_sources header.
var entity_sources: Dictionary = {}

# The merged tree of data/*.json exactly as it was read, before it is taken apart into the
# collections above. The assembled collections are lossy — a goods group keeps only its
# members (product_group_name/icon live in side dictionaries), the game balance is flattened
# out of its blocks — so the field whitelist of the validator (data_validator._validate_schema)
# walks this tree: it is the only place where every key the author wrote is still present.
var raw_data: Dictionary = {}

# What the blacklists of the mods removed: collection -> {id: true}. The entities are gone
# from the collections, and this is the only memory of them — the runtime validator needs it
# to tell "removed on purpose" from "a typo in the blacklist" (data_validator
# ._validate_blacklist).
var blacklisted: Dictionary = {}

# The data fields whose value the player sees. data/*.json holds the English
# source text, and the translation is applied here, when reading the files: the translation key
# is the English text itself. Thanks to this the rest of the code does
# not need to know about localization — it still reads "name"/"description".
const DISPLAY_FIELDS := ["name", "description", "flavor"]

# The dictionary fields where the player label is in the VALUE, and the key is a service
# identifier (see _localize_display_fields).
const VALUE_MAP_FIELDS := ["priority_names"]

# The collections whose records are addressed by a field other than "id" — the same
# addressing the validator uses (data_validator.ENTITY_ID_FIELDS). A mod overrides such a
# record by that field, exactly as by "id".
const ENTITY_ID_FIELDS := {
    "consumption": "resource",
}

# The collections a mod's blacklist may name (see _apply_blacklist): the entity
# collections addressed by an identifier — the very field the merge uses
# (ENTITY_ID_FIELDS). The config blocks (game_balance, modifiers, map_config,
# qualities) are not collections of entities, and the identifier-less arrays
# (city_names, the diversity bonuses) have nothing to address a record by, so
# neither can be blacklisted.
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

# The top-level keys whose elements have an "id" — by them we search
# for the entity declaration. The order and composition repeat what load_all_data parses.
const SOURCE_COLLECTIONS := [
    "resources",
    "crafts",
    "buildings",
    "improvements",
    "technologies",
    "categories",
    "professions",
    "product_groups",
    "roads",
    # The collections that no broken-reference check refers to, but
    # whose identifiers data_validator.gd checks for the alphabet and homoglyphs.
    # Without them the problem "carmine typed with a Cyrillic homoglyph s" would
    # point at an entity without
    # a file and a line — and the file and line are exactly the main value here.
    "terrains",
    "covers",
    "climate_zones",
    "eras",
    "groups",
    "quality_levels",
    "special_actions",
]

# Reads the vanilla data and lays the enabled mods on top of it.
#
# mod_dirs — the data folders of the active mods, in the order they must be applied
# (the mods are already sorted by dependency by ModManager). An empty list — a clean
# vanilla game.
func load_all_data(mod_dirs: Array = []):
    var merged_data = _load_all_json_files("res://data")
    if merged_data == null:
        print("Error: failed to load the data from the data folder.")
        return

    # The mods are merged into the RAW tree, before the collections are assembled:
    # everything below reads the assembled dictionaries, so a record replaced here is
    # indistinguishable from a vanilla one for the rest of the game.
    _apply_mods(merged_data, mod_dirs)

    raw_data = merged_data

    # The translation is applied BEFORE assembling the entities into dictionaries: further on, everyone who
    # reads GameData.products[id]["name"] already gets a ready-to-display
    # text in the current language. A language change re-reads the data from scratch
    # (LocalizationManager.set_locale → GameData.load_all_data).
    _localize_display_fields(merged_data)

    terrains = {}
    for t in merged_data.get("terrains", []):
        terrains[t["id"]] = t

    covers = {}
    for c in merged_data.get("covers", []):
        covers[c["id"]] = c

    climate_zones = {}
    for z in merged_data.get("climate_zones", []):
        climate_zones[z["id"]] = z

    raw_resources = {}
    products = {}
    for r in merged_data.get("resources", []):
        var res_type = r.get("type", "")
        if res_type == "raw":
            raw_resources[r["id"]] = r
        elif res_type == "product":
            products[r["id"]] = r

    improvements = {}
    for i in merged_data.get("improvements", []):
        improvements[i["id"]] = i

    crafts = merged_data.get("crafts", [])
    buildings = merged_data.get("buildings", [])
    categories = merged_data.get("categories", [])
    technologies = merged_data.get("technologies", [])
    groups = merged_data.get("groups", [])
    eras = merged_data.get("eras", [])

    # NEW: we load the product groups
    product_groups = {}
    product_group_names = {}
    product_group_icons = {}
    for pg in merged_data.get("product_groups", []):
        if pg is Dictionary:
            var group_id = pg.get("id", "")
            if not group_id.is_empty():
                product_groups[group_id] = pg.get("products", [])
                product_group_names[group_id] = pg.get("name", group_id)
                # The optional "icon" field: the group's own icon. An empty string
                # — the icon is not set, then GameData takes the icon of the first
                # member that has an icon (see GameData.get_product_group_icon).
                product_group_icons[group_id] = str(pg.get("icon", ""))

    # NEW: we load the global modifiers
    modifiers = merged_data.get("modifiers", {})

    # NEW: we load the special actions (logging, draining swamps, etc.)
    special_actions = {}
    for sa in merged_data.get("special_actions", []):
        if sa is Dictionary:
            var sa_id = sa.get("id", "")
            if not sa_id.is_empty():
                special_actions[sa_id] = sa

    # City names: in the file this is an object { "city_names": [...] }.
    var cn = merged_data.get("city_names", [])
    if cn is Array:
        city_names = cn

    # NEW: we load the road levels (data/roads.json). roads_by_level is needed
    # by a road network segment: it stores a level number, and not an id.
    roads = []
    roads_by_level = {}
    for road in merged_data.get("roads", []):
        if road is Dictionary:
            roads.append(road)
            roads_by_level[int(road.get("level", 0))] = road

    # NEW: we load the data about resource quality levels.
    # In data/qualities.json the keys are at the top level (quality_levels,
    # priority_default, etc.), therefore we assemble them manually. Additionally
    # we support the variant with a nested "qualities" dictionary.
    qualities = {}
    var nested_qualities = merged_data.get("qualities", {})
    if nested_qualities is Dictionary:
        for key in nested_qualities.keys():
            qualities[key] = nested_qualities[key]
    for key in ["quality_levels", "priority_default", "priority_options", "priority_names"]:
        if merged_data.has(key):
            qualities[key] = merged_data[key]

    # NEW: we load the world map configuration (dimensions, starting ring, region).
    # The data/map_config.json file contains the "map_config" key with the parameters:
    # map_rows / map_cols / start_ring_rows / start_ring_cols / region_width.
    map_config = merged_data.get("map_config", {})

    # NEW: we load the professions of workers at improvements (data/professions.json).
    # The profession fields:
    #   id          — a string identifier (snake_case);
    #   name        — singular nominative form ("Farmer");
    #   icon        — the icon file name;
    #   description — a short description.
    # The details of the profession resource consumption scheme — see docs.md, the
    # section "Professions and consumption".
    professions = {}
    for p in merged_data.get("professions", []):
        if p is Dictionary:
            var pid = p.get("id", "")
            if not pid.is_empty():
                professions[pid] = p

    # NEW: we load the registry of occupational consumption
    # (data/consumption.json). Each entry:
    #   resource          — the product id OR the group "@<id>" from product_groups.json;
    #   profession        — an array of the ids of the consuming professions;
    #   amount/interval/production_bonus — the parameters of the consumption tick.
    # The groups allow a profession to consume any suitable product from
    # the set (for example, "@boats" — "Boats"). The details — see docs.md,
    # the section "Professions and resource consumption".
    consumption_rules = []
    for cr in merged_data.get("consumption", []):
        if cr is Dictionary and not str(cr.get("resource", "")).is_empty():
            consumption_rules.append(cr)

    # NEW: we load the game balance (data/game_balance.json).
    # The numeric constants of the game. The "game_balance" key is at the top level,
    # and it is grouped into named blocks (city, expansion, towns) so that the file
    # stays readable as it grows. The blocks are a layout of the FILE only:
    # the constants are flattened back into one flat dictionary here, because every
    # reader addresses a key by name (game_balance.get("base_tax_per_citizen")), not
    # through its block. See _flatten_balance_blocks.
    game_balance = _flatten_balance_blocks(merged_data.get("game_balance", {}))

# Flattens the named blocks of the game balance into one flat dictionary.
#
# A block is a nested dictionary of constants. One level is enough — the blocks group
# the fields by the system that owns them, they do not nest further — so a plain
# one-level flatten keeps the lookup simple: any key of any block becomes a top-level
# key. The names must therefore stay unique across the whole file, which the blocks
# guarantee by construction.
#
# A non-dictionary value is a constant that was not grouped; it is carried over as
# is, so a field may live either inside a block or at the top level while the file is
# being reorganised.
func _flatten_balance_blocks(blocks: Dictionary) -> Dictionary:
    var flat: Dictionary = {}
    for key in blocks.keys():
        var value: Variant = blocks[key]
        if value is Dictionary:
            for field in value.keys():
                flat[field] = value[field]
        else:
            flat[key] = value
    return flat

# Translates the values of the fields the player sees (DISPLAY_FIELDS) into the current
# game language. The walk is recursive: one function covers both the flat lists
# of entities and the nested ones (technologies[].unlock_effects[].name).
#
# The translation key is a pair (english text, context): the context is the path of the
# JSON keys from the file root to the field ("technologies.name" for the technology
# names, "product_groups.name" for the product groups). Objects of different types
# share the same display text ("Jewelry" in both technologies and product groups),
# but they must be translated independently. The context is built by exactly the
# same rule as tools/i18n_build_po.py (scan_data): the two implementations
# are required to produce the same keys, or the game would look up keys missing
# from the catalog (this is caught by the smoke test: tools/i18n_smoke.gd).
#
# A separate case — qualities.json: there "priority_names" is a dictionary
# {priority_code: the player label}, that is, the label is in the VALUE, and the
# key remains a service one. Such dictionaries are listed in VALUE_MAP_FIELDS.
func _localize_display_fields(node: Variant, context: String = "") -> void:
    if node is Dictionary:
        for key in node.keys():
            var value: Variant = node[key]
            var key_context = key if context == "" else context + "." + key
            if DISPLAY_FIELDS.has(key) and value is String:
                node[key] = tr(str(value), key_context)
            elif VALUE_MAP_FIELDS.has(key) and value is Dictionary:
                for option_key in value.keys():
                    if value[option_key] is String:
                        value[option_key] = tr(str(value[option_key]), key_context)
            else:
                _localize_display_fields(value, key_context)
    elif node is Array:
        for item in node:
            _localize_display_fields(item, context)

func _load_all_json_files(folder_path: String) -> Dictionary:
    var result = {}
    var dir = DirAccess.open(folder_path)
    if dir == null:
        print("Error: failed to open the folder ", folder_path)
        return result

    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            var sub_result = _load_all_json_files(folder_path.path_join(file_name))
            _merge_dictionaries(result, sub_result)
        elif file_name.ends_with(".json"):
            var file_path = folder_path.path_join(file_name)
            var file = FileAccess.open(file_path, FileAccess.READ)
            if file == null:
                print("Error: failed to open the file ", file_path)
            else:
                var text = file.get_as_text()
                # The files allow comments, which JSON does not (see json_utils.gd).
                var data = JsonUtils.parse(text)
                if data == null:
                    print("Error: failed to parse JSON from ", file_path)
                else:
                    _remember_sources(file_path, text, data)
                    _merge_dictionaries(result, data)
        file_name = dir.get_next()
    dir.list_dir_end()
    return result

# --- THE ORIGIN OF ENTITIES (file + line) -------------------------------
#
# _merge_dictionaries merges the files into one dictionary and erases the place of
# each entity: after loading it is impossible to say whether "Wheat" is declared in
# data/products/food.json or in data/products/products.json. The runtime validator
# (scripts/data_validator.gd) stumbles on this: it can name the problem
# ("The product 'sunflower' does not exist"), but without the file the author would
# have to look for the typo manually across all the files in data/.
#
# That is why an index is recorded in parallel with the merging: "collection:id" →
# the file and the declaration line. Exactly the declarations, and not the mentions:
# an id can occur in a file both as a group member and as a recipe result, and the
# line number would then point at the wrong place.
func _remember_sources(file_path: String, raw_text: String, data: Dictionary):
    if not (data is Dictionary):
        return
    _remember_key_sources(file_path, raw_text, data)
    for collection in SOURCE_COLLECTIONS:
        var entries = data.get(collection, null)
        if not (entries is Array):
            continue
        for entry in entries:
            if not (entry is Dictionary):
                continue
            var id := str(entry.get("id", ""))
            if id.is_empty():
                continue
            entity_sources["%s:%s" % [collection, id]] = {
                "file": file_path,
                "line": _find_decl_line(raw_text, id),
            }
    _remember_consumption_sources(file_path, raw_text, data)

# The origin of the TOP-LEVEL keys — the collections themselves ("resources", "crafts",
# "game_balance"), indexed as "@key:<name>". A collection has no entity of its own to hang
# the index on, while the field whitelist of the validator needs a file for two cases: an
# unknown collection in the data root, and a record whose own origin is not indexed (the
# diversity bonuses of data/bonuses.json have no "id" field to be indexed by).
#
# A key that several files share (crafts, resources) keeps the first file it was seen in:
# any of them is a fair pointer, and the first one is at least stable.
func _remember_key_sources(file_path: String, raw_text: String, data: Dictionary):
    for key in data.keys():
        var index_key := "@key:%s" % str(key)
        if entity_sources.has(index_key):
            continue
        entity_sources[index_key] = {
            "file": file_path,
            "line": _find_key_line(raw_text, str(key)),
        }

# The line of a top-level key — the one where it is written as `"name":`, and not merely
# mentioned inside a comment or in the value of another field.
func _find_key_line(raw_text: String, key: String) -> int:
    var needle := "\"%s\"" % key
    var lines := raw_text.split("\n")
    for i in lines.size():
        var line: String = lines[i]
        var at := line.find(needle)
        while at >= 0:
            if line.substr(at + needle.length()).lstrip(" \t").begins_with(":"):
                return i + 1
            at = line.find(needle, at + 1)
    return 0

# The consumption rules (data/consumption.json) have no identifier of their own:
# a rule is declared by the resource/profession/amount/interval fields, and there is
# no "id" field in it, therefore the common pass above skips them. Without a separate
# pass the "resource does not exist" problem would be left without indicating a file —
# and the file and
# line here are exactly the main value of the message.
#
# The key is the "resource" value itself (with "@" for groups). In this way the index
# key matches what the validator passes as source_id
# (data_validator._validate_consumption), and both sides agree.
#
# A key collision for two rules with the same resource is impossible: the registry
# forbids it (GameData.get_profession_consumption discards a duplicate by
# display_key), therefore an index overwrite does not happen here.
func _remember_consumption_sources(file_path: String, raw_text: String, data: Dictionary):
    var rules = data.get("consumption", null)
    if not (rules is Array):
        return
    for rule in rules:
        if not (rule is Dictionary):
            continue
        var res_key := str(rule.get("resource", ""))
        if res_key.is_empty():
            continue
        entity_sources["consumption:%s" % res_key] = {
            "file": file_path,
            "line": _find_resource_decl_line(raw_text, res_key),
        }

    # The declaration line of a consumption rule — the one where the "resource" field
    # with this value stands.
    #
    # Its own _find_decl_line does not work here: it looks for the first occurrence of
    # the value in the RAW text, does not strip comments, and the declaration is preceded
    # by any comment of the form // ... "resource" with a value about which the author
    # writes an explanation. The pointer
    # then points at the explanation, and not at the rule — exactly what the origin
    # index was made for.
func _find_resource_decl_line(raw_text: String, res_key: String) -> int:
    var needle := "\"%s\"" % res_key
    var lines := raw_text.split("\n")
    for i in lines.size():
        var line: String = lines[i]
        # The field name and the value on one line — a compact record
        # { "resource": "@boats", ... }. A multi-line record does not occur,
        # but even in that case 0 will be returned, and it will not point at someone else's line.
        if line.contains("\"resource\"") and line.contains(needle):
            return i + 1
    return 0

    # The line on which an entity with such an id is DECLARED, — or 0 if it was not found.
    #
    # We search in the ORIGINAL text of the file, and not in the one cleaned of
    # comments: JsonUtils.strip_comments
    # discards the line breaks inside /* … */, therefore the line numbering of the cleaned
    # text would not match what the author sees in the editor (in data/improvements.json
    # the comment header takes up half the screen).
    #
    # First we search for the line where the id stands next to an "id" (a compact record
    # { "id": "salt", "price": 6 }) — that is the declaration itself. If there is no such one, we take
    # the first line where the id occurs at all: for multi-line records like
    # product_groups.json (id on one line, "products" — on the next ones) it still
    # leads to the declaration line.
func _find_decl_line(raw_text: String, id: String) -> int:
    var needle := "\"%s\"" % id
    var lines := raw_text.split("\n")
    var fallback := 0
    for i in lines.size():
        var line: String = lines[i]
        if not line.contains(needle):
            continue
        if line.contains("\"id\""):
            return i + 1
        if fallback == 0:
            fallback = i + 1
    return fallback

func _merge_dictionaries(target: Dictionary, source: Dictionary):
    for key in source.keys():
        if target.has(key) and typeof(target[key]) == TYPE_ARRAY and typeof(source[key]) == TYPE_ARRAY:
            target[key].append_array(source[key])
        elif target.has(key) and typeof(target[key]) == TYPE_DICTIONARY and typeof(source[key]) == TYPE_DICTIONARY:
            for subkey in source[key]:
                target[key][subkey] = source[key][subkey]
        else:
            target[key] = source[key]

# --- MODS ----------------------------------------------------------------------
#
# A mod ships the same kind of files as data/*.json, in its own "data" folder. Two rules
# cover the whole merge:
#
#   1. A record whose identifier the vanilla data does not have is simply added.
#   2. A record whose identifier the vanilla data already has OVERRIDES it field by
#      field: the fields the mod writes replace the vanilla values, the fields it does
#      not write keep theirs. An overridden record is never duplicated.
#
# The value of an overridden field is taken as a whole: a mod that writes "produces"
# replaces that dictionary, it does not add entries to the vanilla one. Only the
# top-level dictionaries that are not collections of entities (game_balance, modifiers,
# map_config, qualities) are merged recursively, because their blocks are a layout of
# the file: a mod changing one constant must not erase its neighbours.
#
# The mods are applied in the order of mod_dirs, so a later mod overrides an earlier
# one. ModManager orders them by dependency.
func _apply_mods(target: Dictionary, mod_dirs: Array) -> void:
    for mod_dir in mod_dirs:
        var folder := str(mod_dir).path_join("data")
        if DirAccess.open(folder) == null:
            continue
        var mod_data = _load_all_json_files(folder)
        if mod_data.is_empty():
            continue
        _merge_mod_data(target, mod_data)
        _apply_blacklist(target, mod_data)

# --- THE BLACKLIST ---------------------------------------------------------------
#
# A mod may REMOVE vanilla entities, not only add and override them. The "blacklist"
# key of its data is a dictionary { "<collection>": ["id", …] }: the collection is one of
# BLACKLIST_COLLECTIONS, the value lists the identifiers to remove from it.
#
# The identifiers belong to their collection. The same id may be blacklisted as a recipe
# and as a product — those are different entities that happen to share a name, and both
# go. Inside one collection a repeated id changes nothing.
#
# The blacklist is applied right after the mod's own merge, so the rule between the mods
# stays the one of the overrides: a mod applied later (a dependent, or one the dependency
# order put after it) may declare a blacklisted entity again, and it will be back.
#
# A removed entity leaves its references behind: a goods group that lists a removed
# product, a recipe that spends a removed resource. They are NOT cleaned up
# automatically — the runtime validator reports them, and the author removes the referrers
# the same way (a blacklist entry or an override). An entry that names nothing is a
# problem of its own (data_validator._validate_blacklist): what was removed is recorded
# in `blacklisted`, so the check can tell it from a typo.
func _apply_blacklist(target: Dictionary, mod_data: Dictionary) -> void:
    var blacklist = mod_data.get("blacklist", null)
    if not (blacklist is Dictionary) or blacklist.is_empty():
        return
    for collection in blacklist.keys():
        var name := str(collection)
        if not BLACKLIST_COLLECTIONS.has(name):
            # The shape of the blacklist is the validator's business: an unknown
            # collection is reported by the whitelist, with the list of the allowed ones.
            continue
        var banned := _string_set(blacklist[collection])
        if banned.is_empty():
            continue
        var entries = target.get(name, null)
        if not (entries is Array):
            continue
        var id_field := str(ENTITY_ID_FIELDS.get(name, "id"))
        var removed: Dictionary = blacklisted.get(name, {})
        if not (removed is Dictionary):
            removed = {}
        var kept: Array = []
        for entry in entries:
            if not (entry is Dictionary):
                kept.append(entry)
                continue
            var id := str(entry.get(id_field, ""))
            if banned.has(id):
                removed[id] = true
                continue
            kept.append(entry)
        target[name] = kept
        blacklisted[name] = removed

# A value that is either a list of identifiers or a single identifier — the same
# forgiveness as the manifest's authors/author (mod_manager._string_list).
func _string_set(value) -> Dictionary:
    var out := {}
    if value is Array:
        for item in value:
            var text := str(item)
            if not text.is_empty():
                out[text] = true
    elif value is String and not value.is_empty():
        out[value] = true
    return out

func _merge_mod_data(target: Dictionary, mod: Dictionary) -> void:
    for key in mod.keys():
        var value = mod[key]
        if not target.has(key):
            target[key] = value
        elif target[key] is Array and value is Array:
            _merge_entity_array(target[key], value, str(key))
        elif target[key] is Dictionary and value is Dictionary:
            _deep_merge_dict(target[key], value)
        else:
            target[key] = value

func _merge_entity_array(base: Array, records: Array, collection: String) -> void:
    var id_field := str(ENTITY_ID_FIELDS.get(collection, "id"))
    var positions := {}
    for i in base.size():
        var record = base[i]
        if record is Dictionary and record.has(id_field):
            positions[str(record[id_field])] = i
    for record in records:
        if not (record is Dictionary) or not record.has(id_field):
            # A record without an identifier (a city name) has nothing to override.
            base.append(record)
            continue
        var id := str(record[id_field])
        if positions.has(id):
            var existing = base[positions[id]]
            for field in record.keys():
                existing[field] = record[field]
        else:
            positions[id] = base.size()
            base.append(record)

func _deep_merge_dict(target: Dictionary, source: Dictionary) -> void:
    for key in source.keys():
        var value = source[key]
        if target.has(key) and target[key] is Dictionary and value is Dictionary:
            _deep_merge_dict(target[key], value)
        else:
            target[key] = value
