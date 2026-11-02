# icon_registry.gd (IconRegistry autoload)
#
# The SINGLE source of truth for icons: an index of the file names under res://icons,
# built once per game, and the table of replacements a tileset brings on top of it.
#
# The data (data/*.json) stores only the file name, therefore the basename is indexed,
# and not the path.
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

# Emitted after the replacement table is installed. The textures the interface already
# holds belong to the previous table, so a module that keeps its own copy of them reloads
# it on this signal (the map renderer, the tab buttons of the city window).
signal overrides_changed

# The file name (basename) -> the full res:// path.
var paths: Dictionary = {}

# The bare name of an icon (the file name without the extension) -> its type. The bare
# name is what a tileset addresses its files by, so a replacement does not depend on the
# format the author draws in: "hand_mill.svg" stands for "hand_mill.png".
var types: Dictionary = {}

# The bare name of an icon -> the res:// path of the tileset file that replaces it. Filled
# by TilesetManager; empty when no tileset is installed.
var overrides: Dictionary = {}

# The file name -> the loaded Texture2D. A common cache for the whole project.
var _textures: Dictionary = {}

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

# Rebuilds the index from scratch. Idempotent: a repeated call gives the same result.
func build() -> void:
    paths.clear()
    types.clear()
    var duplicates: Array = []
    _scan_folder(ROOT, duplicates)
    _built = true
    if not duplicates.is_empty():
        # A single warning for all duplicates.
        push_warning("IconRegistry: duplicate icon names (the first path is kept): %s"
            % ", ".join(PackedStringArray(duplicates)))

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

# The type of the icons in a folder: the one of the folder of ROOT it lies in, or MISC for
# the root itself and for every folder no type names.
func _folder_type(folder_path: String) -> String:
    var relative := folder_path.trim_prefix(ROOT).trim_prefix("/")
    if relative.is_empty():
        return MISC
    var folder := relative.get_slice("/", 0)
    for type_name in TYPE_FOLDERS:
        if TYPE_FOLDERS[type_name] == folder:
            return type_name
    return MISC

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

# Whether there is an icon with such a file name.
func has(icon_name: String) -> bool:
    _ensure_built()
    return paths.has(icon_name)

# The type of an icon, by its file name or by its bare name; "" if no such icon exists.
func type_of(icon_name: String) -> String:
    _ensure_built()
    return str(types.get(_bare_name(icon_name), ""))

# The file that holds the icon now: the one of the tileset if a tileset replaces it, the
# vanilla one otherwise; "" if there is no such icon.
func path_of(icon_name: String) -> String:
    _ensure_built()
    var replacement := str(overrides.get(_bare_name(icon_name), ""))
    if not replacement.is_empty():
        return replacement
    return str(paths.get(icon_name, ""))

# The full res:// path of the icon; "" if the file does not exist. It is needed where the
# engine expects a path and not a texture: the [img=…] tag in BBCode. The name is NOT
# get_path(): for Node this method is already taken by returning NodePath.
func icon_path(icon_name: String) -> String:
    return path_of(icon_name)

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
    var tex: Texture2D = load(path)
    if tex == null:
        return null
    _textures[icon_name] = tex
    return tex

# Installs the replacement table of the tilesets (see TilesetManager). The texture cache is
# dropped: a texture loaded before the table was installed belongs to the vanilla file.
func set_overrides(table: Dictionary) -> void:
    overrides = table.duplicate()
    _textures.clear()
    overrides_changed.emit()

# How many icons are in the index — for the test.
func count() -> int:
    _ensure_built()
    return paths.size()
