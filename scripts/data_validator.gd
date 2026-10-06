# data_validator.gd
# The runtime validator of the cross-references in data/*.json.
#
# It is run AFTER the loading of the data and BEFORE the start of the game (see main_menu.gd),
# so that the data author learns about the broken references not from the console, but from a window with
# an exact indication of the problematic entity.
#
# The REFERENCES between the entities are checked (and not the JSON syntax — this is what
# tools/validate_json.py does). A problem is stored in two layers:
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
#     "target_title":String,  # "Building" — the kind of the entity being searched for
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
# #
# The checks:
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

# --- THE FOREST PLOT: the only producer that is NOT in produces ---
#
# The product "Wood" does not take part in any produces: it is made by the forest
# plot on an EMPTY forest hex, and the output is taken from the field wood_yield
# of the COVER (data/covers.json), and not from the resource on the hex:
#
#   main_map.gd, the production tick → CityData.add_to_storage("wood", …)
#   MapHelpers.get_cover_wood_yield(tile) — cover → wood_yield
#
# The relation "cover → plot → product" is hardcoded, therefore it is not
# visible from the data, and a naive cross-check would declare the wood a product without
# a source. Here the relation is restored READABLY: the source exists, if
# the plot is declared AND at least one cover has wood_yield > 0. If the author
# removes the plot or the output from the covers — the validator honestly says that
# the wood is unreachable (see the test tests/test_data_validation.gd).
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

# The kinds of the entities that occur in the text of the problem.
#
# This is a list for the substitution of the fallback kind, and not a source of the labels: the
# labels themselves live in entity_forms() below. A dictionary with the names would stand exactly
# for the reason that its values would not get into the translation catalogue — see the note
# to entity_forms() about how the builder reads them.
const ENTITIES := [
    "building", "product", "improvement", "technology", "profession",
    "category", "group", "recipe", "road", "terrain", "cover", "era",
    "quality_level", "special_action", "consumption_rule",
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
        _:
            # An unknown kind of the check: we show the machine name — by it one can see
            # what is missing in CHECK_ORDER, and it survives any language.
            return kind

# The index of the origin of the entities of the current run: "collection:id" → file+line.
# It is filled in in validate(), and is read in _add(). It is empty, if the data has come
# from somewhere without the index (the synthetic data in the test) — then the problem
# simply does not get the rows with the file, and does not crash.
var _sources: Dictionary = {}

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
    "era": "eras",
    "quality_level": "quality_levels",
    "special_action": "special_actions",
}

# The order of the output of the blocks of problems in the window.
const CHECK_ORDER := [
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
    var all_resources: Dictionary = {}
    all_resources.merge(raw_resources)
    all_resources.merge(products)

    _validate_identifiers(gd, problems)
    _validate_crafts(gd.crafts, buildings, technologies, all_resources, product_groups, problems)
    _validate_buildings(gd.buildings, technologies, professions, problems)
    _validate_improvements(improvements, technologies, professions, problems)
    _validate_resources(products, raw_resources, categories, technologies, improvements, problems)
    _validate_product_sources(products, _produced_ids(gd, all_resources), problems)
    _validate_product_groups(product_groups, group_names, products, problems)
    _validate_consumption(gd.consumption_rules, products, product_groups, professions, problems)
    _validate_technologies(technologies, problems)
    _validate_roads(gd.roads, technologies, problems)

    _sort_problems(problems)
    return problems


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
                            "recipe", craft_name, craft_id, "resources")
            elif not all_resources.has(res_key):
                _add(problems, "resource", "product", res_key,
                        "recipe", craft_name, craft_id, "resources")

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
# wood_yield makes the wood unreachable, and the validator must say so.
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
                        "consumption_rule", res_key, res_key, "resource")
        elif not products.has(res_key):
            _add(problems, "consumption_resource", "product", res_key,
                    "consumption_rule", res_key, res_key, "resource")

        # profession → a profession. The kind of the check is common with the buildings and the improvements:
        # the message "a reference to a non-existent profession" is equally true here.
        _check_profession_ref(rule.get("profession", []), professions, problems,
                "consumption_rule", res_key, res_key, "profession")


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

func _add(problems: Array, kind: String, target: String, ref_id: String,
        source_kind: String, source_name: String, source_id: String, field: String) -> void:
    _push(problems, kind, target, ref_id,
            source_kind, source_name, source_id, field)


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
        extra: Dictionary = {}) -> void:
    # An empty string, if the origin is unknown (the data without the index) —
    # then the row with the file simply adds nothing.
    var file_path := ""
    var line := 0
    var source_key := "%s:%s" % [str(SOURCE_COLLECTIONS.get(source_kind, "")), source_id]
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
        _:
            # The other checks are a broken REFERENCE: "There is no X with the identifier …
            # exists" + where exactly it was referred to.
            var target_forms := entity_forms(str(problem.get("target", "")))
            var source_forms := entity_forms(str(problem.get("source_kind", "")), "recipe")
            headline = TranslationServer.translate("%s with the identifier \"%s\" does not exist.") % [str(target_forms["title"]), str(problem.get("ref_id", ""))]
            where = TranslationServer.translate("A reference to %s is present in %s %s, field %s.") % [str(target_forms["ref"]), str(source_forms["source"]), _quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", ""))), str(problem.get("field", ""))]

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
    problem["target_title"] = str(entity_forms(str(problem.get("target", "")))["title"])
    problem["headline"] = headline
    problem["where"] = where
    problem["location"] = location
    problem["message"] = headline + " " + where + (
        " " + location if not location.is_empty() else "")


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


# The owner of the reference in the brackets: "Grain Mill" (grind_grain_hand). If there is
# no name — only the identifier, so that the row does not look like "in  (), the field …".
static func _quote_owner(source_name: String, source_id: String) -> String:
    if source_name.is_empty() or source_name == source_id:
        return "«%s»" % source_id
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
