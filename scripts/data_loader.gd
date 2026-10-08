# data_loader.gd
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

# The data fields whose value the player sees. data/*.json holds the English
# source text, and the translation is applied here, when reading the files: the translation key
# is the English text itself. Thanks to this the rest of the code does
# not need to know about localization — it still reads "name"/"description".
const DISPLAY_FIELDS := ["name", "description", "flavor"]

# The dictionary fields where the player label is in the VALUE, and the key is a service
# identifier (see _localize_display_fields).
const VALUE_MAP_FIELDS := ["priority_names"]

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
    "eras",
    "groups",
    "quality_levels",
    "special_actions",
]

func load_all_data():
    var merged_data = _load_all_json_files("res://data")
    if merged_data == null:
        print("Error: failed to load the data from the data folder.")
        return

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
                # We clean the text of comments
                var cleaned = _strip_json_comments(text)
                var data = JSON.parse_string(cleaned)
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
    # comments: _strip_json_comments
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

func _strip_json_comments(json_string: String) -> String:
    var result = ""
    var in_string = false
    var in_single_line_comment = false
    var in_multi_line_comment = false
    var i = 0
    while i < json_string.length():
        var c = json_string[i]
        var next_c = json_string[i + 1] if i + 1 < json_string.length() else ""
        var prev_c = json_string[i - 1] if i > 0 else ""

        if not in_string and not in_single_line_comment and not in_multi_line_comment:
            if c == '"':
                in_string = true
                result += c
                i += 1
                continue
            elif c == '/' and next_c == '/':
                in_single_line_comment = true
                i += 2
                continue
            elif c == '/' and next_c == '*':
                in_multi_line_comment = true
                i += 2
                continue

        if in_string:
            if c == '"' and prev_c != '\\':
                in_string = false
            result += c
            i += 1
            continue

        if in_single_line_comment:
            if c == '\n':
                in_single_line_comment = false
                result += c # we keep the line break
            i += 1
            continue

        if in_multi_line_comment:
            if c == '*' and next_c == '/':
                in_multi_line_comment = false
                i += 2
                continue
            i += 1
            continue

        result += c
        i += 1

    return result
