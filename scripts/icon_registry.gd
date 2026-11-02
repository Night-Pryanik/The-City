# icon_registry.gd (IconRegistry autoload)
#
# The SINGLE source of truth for icons: an index of the file names under res://icons,
# built once per game, and the table of replacements a tileset brings on top of it.
#
# The data (data/*.json) stores only the file name, therefore the basename is indexed,
# and not the path.
#
# A mod draws its own entities: the icons it ships in <mod folder>/icons are indexed on
# top of the vanilla ones (see set_mod_dirs), so a resource a mod adds is drawn from the
# mod folder without any data change.
#
# The TYPE of an icon is the folder it lies in. A tileset declares the types it is drawn
# for, and the type of a vanilla icon decides whether a replacement applies to it: a
# tileset for buildings changes the building icons and leaves the rest alone.
# See tilesets/README.md.
#
# @tool is mandatory: map_renderer.gd and main_map.gd are marked @tool and access the
# icons from the editor, and an autoload without @tool does not get into the editor
# tree — the scene would fall with "Identifier not found".
@tool
extends Node

# The root in which the icons are searched.
const ROOT := "res://icons"

# The icons of a mod: <mod folder>/icons, laid out like ROOT (a subfolder per type, the
# root of the folder itself for misc). GameData hands the folders of the running mods in
# when it loads the data.
const MOD_ICONS := "icons"

# The scale an SVG of a mod is rasterised with. 1.0 is what the importer of the project
# uses (svg/scale=1.0 in every *.import), so a mod picture keeps the size its author
# declared.
const SVG_SCALE := 1.0

# Service files that get into res://icons during the walk but are not icons: *.import
# lies next to the picture, *.remap appears in a build.
const SKIP_SUFFIXES := [".import", ".remap"]

# The type name used in a tileset manifest -> the folder under ROOT it owns. The names
# differ from the folder names where the folder is shorter (tech, terrain) or where the
# root itself holds the icons.
const TYPE_FOLDERS := {
    "resources": "resources",
    "buildings": "buildings",
    "technologies": "tech",
    "terrains": "terrain",
    "improvements": "improvements",
    "special_actions": "special_actions"
}

# The type of everything that is not covered by a folder of its own: the icons in the root
# of res://icons (coins, the pause of a building, the menu marks) and any folder a future
# set of icons does not name yet.
const MISC := "misc"

# Other names a folder of a type may carry: a mod lays out its icons the way its data reads,
# and a product is a resource record. The canonical folder stays the one in TYPE_FOLDERS, so
# the vanilla layout never depends on these.
const FOLDER_ALIASES := {
    "products": "resources",
    "terrains": "terrains",
    "technologies": "technologies"
}

# Emitted after the set of icons changed: the replacement table was installed, or the
# icons of the mods of the running game were indexed. The textures the interface already
# holds belong to the previous set, so a module that keeps its own copy of them reloads it
# on this signal (the map renderer, the tab buttons of the city window).
signal overrides_changed

# Emitted after a REBUILD of the index (not after the first, lazy build). The icons of the
# mods of the running game are indexed when the data is loaded, after the autoloads are up:
# anything that built a table of names against the vanilla index has to rebuild it.
signal index_changed

# Emitted after the entity -> pictures map of the data changed: a replacement table built
# before the data was read does not know the ids yet (see set_entity_pictures).
signal entity_pictures_changed

# The file name (basename) -> the full path of the file: a res:// one, or a user:// one for
# an icon of a mod installed by the player.
var paths: Dictionary = {}

# The bare name of an icon (the file name without the extension) -> its type. The bare
# name is what a tileset addresses its files by, so a replacement does not depend on the
# format the author draws in: "hand_mill.svg" stands for "hand_mill.png".
var types: Dictionary = {}

# The bare name of an icon -> the res:// path of the tileset file that replaces it. Filled
# by TilesetManager; empty when no tileset is installed.
var overrides: Dictionary = {}

# The bare name of a FAMILY -> the bare names of its variants, sorted. A terrain and a cover
# are drawn from a list of variants ("tundra_moss_1.png", "_2", "_3" in data/covers.json),
# so a tileset may draw the whole family with one picture (see tilesets/README.md). The
# family is the name without its trailing number; a name with no number belongs to none.
var families: Dictionary = {}

# The ID of an entity of the data -> the icon file names the data draws it with, for the
# entities drawn by SEVERAL pictures ("tundra_moss" -> tundra_moss_1..3.png). The data is the
# only thing that knows this list, so GameData publishes it (set_entity_pictures); a tileset
# file named after the id then draws the whole entity, whatever its pictures are called.
var entity_pictures: Dictionary = {}

# The same three tables, built from res://icons ONLY. A TILESET draws the game, not the mods
# of the player: it addresses the vanilla names, so a mod that shadows a vanilla name (a mod
# may redraw an icon, see set_mod_dirs) must not change what a file of a set means. A mod
# draws its own entities and says so in its own manifest; a set never sees them.
var vanilla_types: Dictionary = {}
var vanilla_families: Dictionary = {}

# The file name -> the loaded Texture2D. A common cache for the whole project.
var _textures: Dictionary = {}

# The folders of the mods of the running game, in the order they are applied. Their icons
# are indexed after the vanilla ones.
var _mod_dirs: Array = []

# The index is already built — protection against a repeated walk (lazy building).
var _built := false

func _ready() -> void:
    _ensure_built()

# Lazy building: guards against an access to the registry before _ready
# (for example, from an @tool scene in the editor or from a headless test).
func _ensure_built() -> void:
    if _built:
        return
    build()

# Rebuilds the index from scratch: the vanilla icons, then the icons of the running mods.
# Idempotent: a repeated call gives the same result.
func build() -> void:
    var was_built := _built
    paths.clear()
    types.clear()
    families.clear()
    vanilla_types.clear()
    vanilla_families.clear()
    var duplicates: Array = []
    _scan_folder(ROOT, duplicates)
    # The vanilla view is taken before a mod is laid over it: the tables of the tilesets are
    # built from it (see vanilla_type_of).
    vanilla_types = types.duplicate()
    _build_families(vanilla_types, vanilla_families)
    var owners := {}
    for mod_dir in _mod_dirs:
        _scan_mod(str(mod_dir), owners)
    _build_families(types, families)
    _built = true
    if not duplicates.is_empty():
        # A single warning for all duplicates.
        push_warning("IconRegistry: duplicate icon names (the first path is kept): %s"
            % ", ".join(PackedStringArray(duplicates)))
    # The first build is what everything starts from; a later one means the index changed
    # under the feet of its users.
    if was_built:
        index_changed.emit()

func _scan_folder(folder_path: String, duplicates: Array) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
    var type_name := _folder_type(folder_path)
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while not file_name.is_empty():
        if dir.current_is_dir():
            _scan_folder(folder_path.path_join(file_name), duplicates)
        else:
            var key := _index_key(file_name)
            if not key.is_empty():
                if paths.has(key):
                    # A duplicate does NOT overwrite the first path: otherwise a picture from
                    # a nested folder would silently replace the one in the root.
                    duplicates.append(key)
                else:
                    paths[key] = folder_path.path_join(file_name)
                    if not types.has(_bare_name(key)):
                        types[_bare_name(key)] = type_name
        file_name = dir.get_next()
    dir.list_dir_end()

# The icons of one mod. Unlike the vanilla ones, a mod icon MAY overwrite: a mod draws the
# entities it adds, and giving its picture the name of a vanilla icon is how it redraws
# that icon. Two mods drawing one name are reported — the later mod wins, but an icon lost
# silently is exactly the kind of bug that is hard to notice.
func _scan_mod(mod_dir: String, owners: Dictionary) -> void:
    var icons_root := mod_dir.path_join(MOD_ICONS)
    if not DirAccess.dir_exists_absolute(icons_root):
        return
    _scan_mod_folder(icons_root, icons_root, mod_dir, owners)

func _scan_mod_folder(folder_path: String, icons_root: String, mod_dir: String,
        owners: Dictionary) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
    var type_name := _folder_type(folder_path, icons_root)
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while not file_name.is_empty():
        if dir.current_is_dir():
            _scan_mod_folder(folder_path.path_join(file_name), icons_root, mod_dir, owners)
        else:
            var key := _index_key(file_name)
            if not key.is_empty():
                var bare := _bare_name(key)
                var previous := str(owners.get(bare, ""))
                if not previous.is_empty() and previous != mod_dir:
                    push_warning(("IconRegistry: \"%s\" is drawn by both \"%s\" and \"%s\"; "
                        + "the later mod wins.") % [key, previous, mod_dir])
                owners[bare] = mod_dir
                paths[key] = folder_path.path_join(file_name)
                types[bare] = type_name
        file_name = dir.get_next()
    dir.list_dir_end()

# The type of the icons in a folder: the one of the folder of `root` it lies in, or MISC for
# the root itself and for every folder no type names. `root` is res://icons for the vanilla
# icons and <mod folder>/icons for the icons of a mod.
func _folder_type(folder_path: String, root: String = ROOT) -> String:
    var relative := folder_path.trim_prefix(root).trim_prefix("/")
    if relative.is_empty():
        return MISC
    var folder := relative.get_slice("/", 0)
    for type_name in TYPE_FOLDERS:
        if TYPE_FOLDERS[type_name] == folder:
            return type_name
    return str(FOLDER_ALIASES.get(folder, MISC))

# The name under which a file gets into the index; "" — the file is a service one,
# it is not an icon.
func _index_key(file_name: String) -> String:
    if file_name.begins_with("."):
        return ""
    for suffix in SKIP_SUFFIXES:
        if file_name.ends_with(suffix):
            return ""
    return file_name

# The file name without the extension: the name a tileset uses for its own files.
func _bare_name(file_name: String) -> String:
    return file_name.get_basename()

# Groups the indexed names into families: "tundra_moss_2" goes to "tundra_moss". The same walk
# fills the vanilla families and the full ones, so a set and the game never disagree on what a
# family is.
func _build_families(names: Dictionary, into: Dictionary) -> void:
    for bare_name in names:
        var base := _family_base(str(bare_name))
        if base.is_empty():
            continue
        if not into.has(base):
            into[base] = []
        (into[base] as Array).append(bare_name)
    for base in into:
        (into[base] as Array).sort()

# The family of a name: "tundra_moss_2" -> "tundra_moss"; "" when the name does not end with
# a number, so it is not a variant of anything.
func _family_base(bare_name: String) -> String:
    var cut := bare_name.rfind("_")
    if cut <= 0:
        return ""
    var tail := bare_name.substr(cut + 1)
    if tail.is_empty():
        return ""
    for i in tail.length():
        var letter := tail[i]
        if letter < "0" or letter > "9":
            return ""
    return bare_name.substr(0, cut)

# The bare names of the variants of a family, sorted: "tundra_moss" ->
# ["tundra_moss_1", "tundra_moss_2", "tundra_moss_3"]. Empty when the name is no family —
# a tileset file that matches no icon itself may still draw a whole family this way.
func variants(bare_name: String) -> Array:
    _ensure_built()
    return families.get(bare_name, [])

# The type of a VANILLA icon, by its file name or by its bare name; "" if res://icons has no
# such icon. What a tileset file means: a mod that shadows a vanilla name does not move it.
func vanilla_type_of(icon_name: String) -> String:
    _ensure_built()
    return str(vanilla_types.get(_bare_name(icon_name), ""))

# The variants of a VANILLA family — the same list as variants(), without the names a mod adds.
func vanilla_variants(bare_name: String) -> Array:
    _ensure_built()
    return vanilla_families.get(bare_name, [])

# Whether there is an icon with such a file name.
func has(icon_name: String) -> bool:
    _ensure_built()
    return paths.has(icon_name)

# The type of an icon, by its file name or by its bare name; "" if no such icon exists.
func type_of(icon_name: String) -> String:
    _ensure_built()
    return str(types.get(_bare_name(icon_name), ""))

# The file that holds the icon now: the one of the tileset if a tileset replaces it, the
# indexed one otherwise (the vanilla picture, or the one a mod draws it with); "" if there
# is no such icon.
func path_of(icon_name: String) -> String:
    _ensure_built()
    var replacement := str(overrides.get(_bare_name(icon_name), ""))
    if not replacement.is_empty():
        return replacement
    return str(paths.get(icon_name, ""))

# The full path of the icon; "" if the file does not exist. It is needed where the engine
# expects a path and not a texture: the [img=…] tag in BBCode. The path is a res:// one,
# except for an icon of a mod in user://, which the registry has put into the cache of the
# ResourceLoader (see _decode_texture). The name is NOT get_path(): for Node this method is
# already taken by returning NodePath.
func icon_path(icon_name: String) -> String:
    var path := path_of(icon_name)
    if path.is_empty():
        return ""
    if not path.begins_with("res://") or not ResourceLoader.exists(path):
        # A raw file of a mod: the tag is resolved through ResourceLoader, which knows
        # nothing of such a file until the registry has decoded it (see _decode_texture).
        get_texture(icon_name)
    return path

# The icon texture with a shared cache; null if the name is empty or the file does
# not exist (then the icon is simply not set).
func get_texture(icon_name: String) -> Texture2D:
    if icon_name.is_empty():
        return null
    _ensure_built()
    if _textures.has(icon_name):
        return _textures[icon_name]
    var path := path_of(icon_name)
    if path.is_empty():
        return null
    var tex := _load_texture(path)
    if tex == null:
        return null
    _textures[icon_name] = tex
    return tex

# The texture of a file. A vanilla icon (and a mod shipped inside the project) is an
# imported resource; a mod in user:// is a raw file the engine has never imported, so it is
# decoded here. ResourceLoader.exists() tells the two apart without an error in the log.
func _load_texture(path: String) -> Texture2D:
    if ResourceLoader.exists(path):
        return load(path)
    return _decode_texture(path)

func _decode_texture(path: String) -> Texture2D:
    if not FileAccess.file_exists(path):
        return null
    var image: Image = null
    if path.get_extension().to_lower() == "svg":
        var bytes := FileAccess.get_file_as_bytes(path)
        if bytes.is_empty():
            return null
        image = Image.new()
        if image.load_svg_from_buffer(bytes, SVG_SCALE) != OK:
            return null
    else:
        image = Image.load_from_file(path)
    if image == null or image.is_empty():
        return null
    var texture := ImageTexture.create_from_image(image)
    # The tooltips insert icons as [img=<path>], and that tag is resolved through
    # ResourceLoader, which knows nothing of a texture made here. Taking the path over puts
    # the texture into the loader's cache under it, so the tag finds it.
    texture.take_over_path(path)
    return texture

# The folders of the mods of the running game, in the order they are applied: their icons
# are indexed after the vanilla ones. Called by GameData when it loads the data, because
# the set of mods belongs to the save. The texture cache is dropped: a texture loaded
# before belongs to the previous set.
func set_mod_dirs(dirs: Array) -> void:
    var next: Array = []
    for dir in dirs:
        next.append(str(dir))
    if next == _mod_dirs:
        return
    _mod_dirs = next
    _textures.clear()
    build()
    overrides_changed.emit()

# Installs the replacement table of the tilesets (see TilesetManager). The texture cache is
# dropped: a texture loaded before the table was installed belongs to the vanilla file.
func set_overrides(table: Dictionary) -> void:
    overrides = table.duplicate()
    _textures.clear()
    overrides_changed.emit()

# The entities of the data drawn by several pictures: id -> the icon file names. Published
# by GameData, which is the only place that reads the data. The map is compared before it
# is installed, so a reload of the same data costs nothing; a table built before the data
# was read has to be rebuilt, which is what the signal is for.
func set_entity_pictures(map: Dictionary) -> void:
    if map == entity_pictures:
        return
    entity_pictures = map.duplicate(true)
    entity_pictures_changed.emit()

# The icon file names the data draws this entity with; empty when no entity carries the id
# or when one picture is enough for it.
func pictures_of(entity_id: String) -> Array:
    return entity_pictures.get(entity_id, [])

# How many icons are in the index — for the test.
func count() -> int:
    _ensure_built()
    return paths.size()
