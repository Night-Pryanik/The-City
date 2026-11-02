# tileset_manager.gd (TilesetManager autoload)
#
# The registry of the installed tilesets, the choice of the player and the icon
# replacements they bring.
#
# A TILESET is a folder with a manifest and images:
#
#   <tileset folder>/tileset.json     the manifest (see read_tileset below)
#   <tileset folder>/**/*.png|svg     the icons, in any layout inside the folder
#
# A set draws the VANILLA game: the names it uses are the names of res://icons and of the
# vanilla data. What a mod adds or redraws is the mod's own business — a mod brings its data
# and its icons together (see mods/README.md §4.5), a set never sees them.
#
# The tilesets are searched in res://tilesets, one level deep. A folder whose name starts
# with "_" is skipped: the shipped example lives in res://tilesets/_example and must not
# replace the art of the game itself.
#
# A tileset replaces the vanilla icons of the TYPES it declares and touches nothing else.
# An icon is addressed by its bare name, so the author may draw an SVG where the vanilla
# set has a PNG: "hand_mill.svg" replaces "hand_mill.png".
#
# WHICH SET OWNS A TYPE is the player's choice, one per type, made in the settings and
# kept in user://settings.cfg: the types of one game may come from different sets. Until
# a type is chosen the folder rule decides (the set that sorts last wins it whole), so an
# installed set starts working without a visit to the settings.
#
# The type of a vanilla icon is the folder it lies in (see IconRegistry.TYPE_FOLDERS), so
# the manifest names the types of the game, not the folders of res://icons.
extends Node

const JsonUtils = preload("res://scripts/json_utils.gd")

const ROOT := "res://tilesets"
const MANIFEST := "tileset.json"

# The types a tileset may declare. "misc" is everything without a folder of its own: coins,
# the pause and the upgrade of a building, the marks of the menu.
const TYPES := ["resources", "buildings", "technologies", "terrains", "improvements",
    "special_actions", "misc"]

# What is taken for an image. The engine imports each of these into a texture; anything
# else in a tileset folder (a readme, a palette, a source file) is left alone.
const IMAGE_SUFFIXES := [".png", ".svg", ".webp", ".jpg", ".jpeg", ".bmp", ".tga"]
const SKIP_SUFFIXES := [".import", ".remap", ".uid"]

# A folder whose name starts with this is not a tileset: the shipped example carries it so
# that the game keeps its own art until the folder is renamed.
const DISABLED_PREFIX := "_"

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "interface"
# The type -> the id of the chosen set; "" means the vanilla icons. A type that is not in
# the dictionary is decided by the folder rule (see resolve()).
const SETTINGS_KEY := "tilesets"

# The manifests of the installed tilesets, sorted by folder name. Each record:
#   id, name, description, authors (Array), version, types (Array), icons (Dictionary),
#   dir, error ("" — the tileset is usable).
# `icons` is the bare name of an icon -> the res:// path of the file.
var tilesets: Array = []

# The type -> the id of the set the player chose ("" — the vanilla icons).
var choices: Dictionary = {}

func _ready() -> void:
    scan()
    var registry = _icon_registry()
    if registry != null:
        # The icons of the mods of the running game are indexed later, when the data is
        # loaded: a tileset that redraws an icon a mod adds has to be rebuilt against the
        # complete index.
        registry.index_changed.connect(_on_icons_indexed)
        # The pictures of the entities of the data come with the same load: a tileset file
        # named after an entity draws it whole, and the entity is known only then.
        registry.entity_pictures_changed.connect(_on_icons_indexed)

# Reads the manifests and installs their replacements into IconRegistry. Called once at
# startup: the set of tilesets is fixed by the files of the game.
func scan() -> Array:
    tilesets.clear()
    for dir_name in _subdirectories(ROOT):
        var record := read_tileset(str(ROOT).path_join(dir_name))
        if not record.is_empty():
            tilesets.append(record)
    # A set that cannot be used is reported once, when it is read: apply() runs again
    # whenever the index of the icons changes, and a repeated warning says nothing new.
    for record in tilesets:
        if not str(record.get("error", "")).is_empty():
            push_warning("TilesetManager: \"%s\" is not applied: %s"
                % [record["id"], record["error"]])
    choices = _load_choices()
    apply()
    return tilesets

func get_tileset(tileset_id: String) -> Dictionary:
    for record in tilesets:
        if str(record.get("id", "")) == tileset_id:
            return record
    return {}

# --- The choice of the player ------------------------------------------------------

# The sets that may be chosen: a broken manifest is not offered, it can replace nothing.
func available_tilesets() -> Array:
    var out: Array = []
    for record in tilesets:
        if str(record.get("error", "")).is_empty():
            out.append(record)
    return out

# The id of the set that is drawing this type now; "" for the vanilla icons. The answer is
# what the game does, not what the settings file says: a chosen set that was deleted falls
# back to the folder rule.
func get_choice(type_name: String) -> String:
    if choices.has(type_name):
        var id := str(choices[type_name])
        if id.is_empty():
            return ""
        if _declares(id, type_name):
            return id
    var owner: Dictionary = _folder_rule(type_name, tilesets)
    return "" if owner.is_empty() else str(owner["id"])

# Makes `tileset_id` draw the icons of `type_name`; "" puts the vanilla icons back. Returns
# false when the set does not exist or is not drawn for this type.
func set_choice(type_name: String, tileset_id: String) -> bool:
    if not TYPES.has(type_name):
        return false
    if not tileset_id.is_empty() and not _declares(tileset_id, type_name):
        return false
    choices[type_name] = tileset_id
    _save_choices()
    apply()
    return true

func _declares(tileset_id: String, type_name: String) -> bool:
    var record := get_tileset(tileset_id)
    if record.is_empty() or not str(record.get("error", "")).is_empty():
        return false
    return (record["types"] as Array).has(type_name)

func _load_choices() -> Dictionary:
    var config := ConfigFile.new()
    if config.load(SETTINGS_PATH) != OK:
        return {}
    var stored = config.get_value(SETTINGS_SECTION, SETTINGS_KEY, {})
    if not (stored is Dictionary):
        return {}
    var out := {}
    for type_name in stored:
        if TYPES.has(str(type_name)):
            out[str(type_name)] = str(stored[type_name])
    return out

func _save_choices() -> void:
    var config := ConfigFile.new()
    # The file is re-read: the settings menu, FontManager, ThemeManager and
    # LocalizationManager write it too, and their in-memory copies do not know this key.
    config.load(SETTINGS_PATH)
    config.set_value(SETTINGS_SECTION, SETTINGS_KEY, choices)
    config.save(SETTINGS_PATH)

# --- Applying ---------------------------------------------------------------------

# The replacement table of the installed tilesets: the bare name of an icon -> the res://
# path of the file that replaces it.
#
# A table identical to the installed one is left alone: the icons of the mods of the running
# game are indexed after the first apply, and a rebuild that changes nothing must not reload
# every texture of the interface.
func apply() -> void:
    var registry = _icon_registry()
    if registry == null:
        return
    var table := build_overrides(tilesets, choices)
    if table == registry.overrides:
        return
    registry.set_overrides(table)
    _warn_unmatched(tilesets)
    _warn_partial_entities(tilesets)

func _on_icons_indexed() -> void:
    apply()

# The replacement table of a set of tileset records under a set of choices.
#
# A type is drawn by ONE tileset: two building sets would mix two drawing styles. A chosen
# set is used as chosen; a type the player has not chosen is given to the folder rule, and
# a file whose type the tileset does not declare, or that names no icon at all, is not a
# replacement.
#
# A SET DRAWS THE VANILLA GAME. Its names are resolved against res://icons and the vanilla
# data only (IconRegistry.vanilla_type_of), so what a mod adds or changes never moves the
# meaning of a file of a set — the mod draws its own entities through its own data and icons.
#
# A file named after a FAMILY draws every variant of it with one picture: "tundra_moss.svg"
# replaces tundra_moss_1, tundra_moss_2 and tundra_moss_3, which the data of a cover lists
# as three variants of the same art. The author draws one picture instead of three copies.
#
# A file named after an ENTITY draws every picture the data gives that entity: the list of
# the pictures belongs to the data, not to a naming convention, so the author may name the
# file after the id and forget what the files of the entity are called. A family file and an
# entity file say the same thing when the data names its pictures after the id; either
# spelling is read.
#
# The DECLARED TYPES are the namespace of a name. An entity and an icon of another type may
# carry one name, and the name alone says nothing: a name that is an icon of a type this set
# does not draw is read as the id of the entity of a type it DOES draw. A set that declares
# both types means both with one name, which is what it asked for.
func build_overrides(records: Array, chosen: Dictionary = {}) -> Dictionary:
    var registry = _icon_registry()
    var table := {}
    if registry == null:
        return table
    var owners := resolve(records, chosen)
    # The exact names first: a file that names an icon of its own wins over a family file or
    # an entity file that would draw the same icon.
    for type_name in owners:
        var record: Dictionary = owners[type_name]
        for bare_name in record["icons"]:
            if registry.vanilla_type_of(bare_name) == type_name:
                table[bare_name] = record["icons"][bare_name]
    # Then the entities of the data: the whole entity, whatever its pictures are called. A
    # name that is an icon of ANOTHER type is not skipped here: that icon belongs to a type
    # this set does not draw, so the name is free for an entity of a type it does.
    for type_name in owners:
        var record: Dictionary = owners[type_name]
        var declared: Array = record.get("types", [])
        for bare_name in record["icons"]:
            if declared.has(registry.vanilla_type_of(bare_name)):
                continue
            for picture in registry.pictures_of(bare_name):
                var icon_name := str(picture).get_basename()
                if registry.vanilla_type_of(icon_name) == type_name and not table.has(icon_name):
                    table[icon_name] = record["icons"][bare_name]
    # Then the families of the icon names: the same thing for the entities whose pictures
    # are named after a family the data does not call an entity.
    for type_name in owners:
        var record: Dictionary = owners[type_name]
        var declared: Array = record.get("types", [])
        for bare_name in record["icons"]:
            if declared.has(registry.vanilla_type_of(bare_name)):
                continue
            for variant in registry.vanilla_variants(bare_name):
                if registry.vanilla_type_of(variant) == type_name and not table.has(variant):
                    table[variant] = record["icons"][bare_name]
    return table

# The type -> the record that draws it. A type resolved to the vanilla icons is absent from
# the result.
#
# A type the player has not chosen goes to the set that sorts last among those declaring
# it: the records come in the order of their folder names, and two sets for one type are
# worth a warning, because the winner is not something the player picked.
func resolve(records: Array, chosen: Dictionary = {}) -> Dictionary:
    var owners := {}
    for type_name in TYPES:
        if chosen.has(type_name):
            var id := str(chosen[type_name])
            if id.is_empty():
                continue
            var picked: Dictionary = {}
            for record in records:
                if str(record.get("id", "")) == id and _usable(record) \
                        and (record["types"] as Array).has(type_name):
                    picked = record
                    break
            if not picked.is_empty():
                owners[type_name] = picked
                continue
            # The chosen set is gone: the folder rule answers for this type.
        var owner := _folder_rule(type_name, records)
        if not owner.is_empty():
            owners[type_name] = owner
    return owners

# The set that draws this type when nobody chose: the last of the usable candidates, in the
# order the records come in.
func _folder_rule(type_name: String, records: Array) -> Dictionary:
    var candidates: Array = []
    for record in records:
        if _usable(record) and (record["types"] as Array).has(type_name):
            candidates.append(record)
    if candidates.size() > 1:
        var names := PackedStringArray()
        for record in candidates:
            names.append(str(record["id"]))
        push_warning("TilesetManager: \"%s\" is drawn by several sets (%s) — \"%s\" wins. "
            % [type_name, ", ".join(names), candidates[-1]["id"]]
            + "Choose one in the settings.")
    return {} if candidates.is_empty() else candidates[-1]

func _usable(record: Dictionary) -> bool:
    return str(record.get("error", "")).is_empty()

# --- Reading the manifests --------------------------------------------------------

# The record of one tileset folder; an empty dictionary if the folder has no manifest.
# A broken manifest is still returned, with `error` filled in: the tileset is there, and
# the author has to see why it does nothing.
func read_tileset(dir: String) -> Dictionary:
    var path := dir.path_join(MANIFEST)
    if not FileAccess.file_exists(path):
        return {}
    var record := {
        "id": dir.get_file(),
        "name": dir.get_file(),
        "description": "",
        "authors": [],
        "version": "",
        "types": [],
        "icons": {},
        "dir": dir,
        "error": ""
    }
    var parsed = JsonUtils.parse(FileAccess.get_file_as_string(path))
    if not (parsed is Dictionary):
        record["error"] = "The manifest is not readable JSON."
        return record

    record["name"] = str(parsed.get("name", "")).strip_edges()
    record["description"] = str(parsed.get("description", "")).strip_edges()
    record["version"] = str(parsed.get("version", "")).strip_edges()
    record["authors"] = _string_list(parsed.get("authors", parsed.get("author", [])))
    record["types"] = _string_list(parsed.get("type", []))
    _collect_icons(dir, record["icons"])

    record["error"] = _record_error(record)
    return record

func _record_error(record: Dictionary) -> String:
    if str(record["name"]).is_empty():
        return "The manifest has no \"name\" field."
    if str(record["description"]).is_empty():
        return "The manifest has no \"description\" field."
    var types: Array = record["types"]
    if types.is_empty():
        return "The manifest has no \"type\" field."
    for type_name in types:
        if not TYPES.has(type_name):
            return "The type \"%s\" is unknown. The types are: %s." % [type_name, ", ".join(
                PackedStringArray(TYPES))]
    if (record["icons"] as Dictionary).is_empty():
        return "The tileset folder holds no images (%s)." % ", ".join(
            PackedStringArray(IMAGE_SUFFIXES))
    return ""

# A manifest field that is either a list of strings or a single string.
func _string_list(value) -> Array:
    var out: Array = []
    if value is Array:
        for item in value:
            var text := str(item).strip_edges()
            if not text.is_empty():
                out.append(text)
    elif value is String and not value.strip_edges().is_empty():
        out.append(value.strip_edges())
    return out

# The images of the tileset folder, in any subfolder. A repeated bare name keeps the first
# file: one icon has one replacement.
func _collect_icons(folder_path: String, out: Dictionary) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while not file_name.is_empty():
        if dir.current_is_dir():
            _collect_icons(folder_path.path_join(file_name), out)
        elif _is_image(file_name):
            var bare_name := file_name.get_basename()
            if not out.has(bare_name):
                out[bare_name] = folder_path.path_join(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()

func _is_image(file_name: String) -> bool:
    if file_name.begins_with("."):
        return false
    var lower := file_name.to_lower()
    for suffix in SKIP_SUFFIXES:
        if lower.ends_with(suffix):
            return false
    for suffix in IMAGE_SUFFIXES:
        if lower.ends_with(suffix):
            return true
    return false

# Tells the author about the files that replace nothing: a misnamed picture is invisible in
# the game otherwise. The names are the vanilla ones — an icon a mod adds is not a target.
func _warn_unmatched(records: Array) -> void:
    var registry = _icon_registry()
    if registry == null:
        return
    for record in records:
        if not _usable(record):
            continue
        var unknown: Array = []
        for bare_name in record["icons"]:
            if not _draws_anything(registry, record, bare_name):
                unknown.append(bare_name)
        if not unknown.is_empty():
            unknown.sort()
            push_warning("TilesetManager: \"%s\": no icon is named %s — the files are ignored."
                % [record["id"], ", ".join(PackedStringArray(unknown))])

# Whether a file of a set replaces at least one icon of a type the set declares: the icon it
# is named after, the entity of the data it is named after, or the family when it is named
# after one. A name that is an icon of ANOTHER type draws nothing here — see build_overrides.
func _draws_anything(registry, record: Dictionary, bare_name: String) -> bool:
    var declared: Array = record.get("types", [])
    var own: String = registry.vanilla_type_of(bare_name)
    if declared.has(own):
        return true
    for picture in registry.pictures_of(bare_name):
        if declared.has(registry.vanilla_type_of(str(picture).get_basename())):
            return true
    for variant in registry.vanilla_variants(bare_name):
        if declared.has(registry.vanilla_type_of(variant)):
            return true
    return false

# A set that draws only some pictures of an entity is not an error — one variant may be meant
# to differ. It is, however, the case where a cover comes out patched from two drawings, so
# the author is told the way out: a file named after the entity (or after its family) draws
# all of it at once.
func _warn_partial_entities(records: Array) -> void:
    var registry = _icon_registry()
    if registry == null:
        return
    for record in records:
        if not _usable(record):
            continue
        var icons: Dictionary = record["icons"]
        var declared: Array = record.get("types", [])
        var hints: Array = []
        for entity_id in registry.entity_pictures:
            var pictures: Array = registry.pictures_of(str(entity_id))
            var targets: Array = []
            for picture in pictures:
                var icon_name := str(picture).get_basename()
                if declared.has(registry.vanilla_type_of(icon_name)):
                    targets.append(icon_name)
            if targets.size() < 2:
                continue
            # A file named after the entity draws all of its pictures; the exact files draw
            # the ones they name.
            var drawn := targets.size() if icons.has(entity_id) else 0
            if not icons.has(entity_id):
                for target in targets:
                    if icons.has(target):
                        drawn += 1
            if drawn > 0 and drawn < targets.size():
                hints.append("%s (%d of %d pictures)" % [entity_id, drawn, targets.size()])
        if not hints.is_empty():
            hints.sort()
            push_warning(("TilesetManager: \"%s\": %s — a file named after the entity draws "
                + "all of them at once.") % [record["id"],
                    ", ".join(PackedStringArray(hints))])

func _subdirectories(root: String) -> Array:
    var out: Array = []
    var dir := DirAccess.open(root)
    if dir == null:
        return out
    for name in dir.get_directories():
        if name.begins_with(DISABLED_PREFIX) or name.begins_with("."):
            continue
        out.append(name)
    out.sort()
    return out

# The registry is looked up through the tree root rather than by its global name: an
# autoload declared before this one is not always resolved in this script (the same reason
# the tests address the autoloads by node path).
func _icon_registry():
    var loop := Engine.get_main_loop()
    if not (loop is SceneTree):
        return null
    return (loop as SceneTree).root.get_node_or_null("IconRegistry")
