# icon_registry.gd (IconRegistry autoload)
#
# The SINGLE source of truth for icons: an index of file names from res://icons
# is built ONCE per game, and not separately in every module.
#
# WHY IT IS LIKE THIS. Previously the recursive walk of res://icons was duplicated
# in eight places (map_renderer, resources_tab, buildings_tab — twice in one file,
# building_panel, tech_tree, town_ui, trade_tab). The indexing rules meanwhile
# diverged: somewhere a duplicate overwrote the path, somewhere it was ignored,
# somewhere a warning was printed, and somewhere not; and half of the index is
# 288 *.import files, which are useless in the index. Worst of all, buildings_tab
# built a local index inside _show_building_details, that is, it walked 576
# files on every hover over a building.
#
# @tool is mandatory: map_renderer.gd and main_map.gd are marked @tool and access
# the icons from the editor, and an autoload without @tool does not get
# into the editor tree — the scene would fall with "Identifier not found".
@tool
extends Node

# The root in which the icons are searched. The data (data/*.json) stores only the
# file name, therefore the basename is indexed, and not the path.
const ROOT := "res://icons"

# Service files that get into res://icons during the walk but are not
# icons: *.import lies next to the picture, *.remap appears in a build.
# Previously they took up half of the index (288 of 576 entries).
const SKIP_SUFFIXES := [".import", ".remap"]

# The file name (basename) -> the full res:// path.
var paths: Dictionary = {}
# The file name -> the loaded Texture2D. A common cache for the whole project:
# previously identical texture cache dictionaries lived in six modules.
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

# Rebuilds the index from scratch. Idempotent: a repeated call gives the same
# result (checked by a test). It is needed both for repairing and for the test.
func build() -> void:
    paths.clear()
    var duplicates: Array = []
    _scan_folder(ROOT, duplicates)
    _built = true
    if not duplicates.is_empty():
        # A single warning for all duplicates: previously each of the eight copies
        # of the walk printed its own, and three of them were silent.
        push_warning("IconRegistry: duplicate icon names (the first path is kept): %s"
            % ", ".join(PackedStringArray(duplicates)))

func _scan_folder(folder_path: String, duplicates: Array) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
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
        file_name = dir.get_next()
    dir.list_dir_end()

# The name under which a file gets into the index; "" — the file is a service one,
# it is not an icon. The data stores only the file name, therefore the basename is indexed.
func _index_key(file_name: String) -> String:
    if file_name.begins_with("."):
        return ""
    for suffix in SKIP_SUFFIXES:
        if file_name.ends_with(suffix):
            return ""
    return file_name

# Whether there is an icon with such a file name.
func has(icon_name: String) -> bool:
    return paths.has(icon_name)

# The full res:// path of the icon; "" if the file does not exist. It is needed
# where the engine expects a path and not a texture: the [img=…] tag in BBCode.
# The name is NOT get_path(): for Node this method is already taken by returning NodePath.
func icon_path(icon_name: String) -> String:
    _ensure_built()
    return paths.get(icon_name, "")

# The icon texture with a shared cache; null if the name is empty or the file does
# not exist (then the icon is simply not set).
func get_texture(icon_name: String) -> Texture2D:
    if icon_name.is_empty():
        return null
    _ensure_built()
    if _textures.has(icon_name):
        return _textures[icon_name]
    var path: String = paths.get(icon_name, "")
    if path.is_empty():
        return null
    var tex: Texture2D = load(path)
    if tex == null:
        return null
    _textures[icon_name] = tex
    return tex

# How many icons are in the index — for the test.
func count() -> int:
    _ensure_built()
    return paths.size()