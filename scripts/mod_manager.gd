# mod_manager.gd (Autoload)
#
# The registry of the installed mods and the set the current game runs with.
#
# A MOD is a folder with a manifest and an optional data folder:
#
#   <mod folder>/mod.json        the manifest (see MANIFEST_FIELDS below)
#   <mod folder>/data/*.json     the game data, the same format as res://data
#
# The mods are searched in res://mods (shipped with the game) and in user://mods (put
# there by the player). A user mod with the same identifier as a shipped one replaces it
# — that is how a shipped mod is patched without touching the game files.
#
# THE SET OF MODS BELONGS TO THE SAVE. ModManager only keeps the set of the running game:
# the mod list in the city naming dialog fills it before a new game, SaveManager restores
# it from a slot, and GameData reads it when it assembles the data (see
# GameData.active_mod_dirs).
#
# The data of a mod is merged by data_loader: a new identifier is added to the vanilla
# entities, an existing one is overwritten field by field.
extends Node

const DataValidator = preload("res://scripts/data_validator.gd")
const JsonUtils = preload("res://scripts/json_utils.gd")

const MOD_ROOTS := ["res://mods", "user://mods"]
const MANIFEST := "mod.json"
# The characters an identifier may consist of. A Cyrillic letter in an identifier is
# indistinguishable from a Latin one by eye — the same rule the data validator applies.
const IDENT_CHARS := "abcdefghijklmnopqrstuvwxyz0123456789_"

# The manifests of the installed mods, sorted by identifier. Each record:
#   id, name, authors (Array), description, version, dependencies (Array),
#   conflicts (Array), dir, error ("" — the manifest is usable).
var mods: Array = []
# The identifiers of the mods of the running game, in the order they are applied:
# a dependency always comes before the mod that requires it.
var active_ids: Array = []

# The problems of the vanilla data. The check of a mod reports only what the mod adds to
# them, so a game whose own data is broken does not blame every mod that is switched on.
var _vanilla_problems: Array = []
var _baseline_ready := false

func _ready() -> void:
    scan()
    _push_to_game_data()

# --- The installed mods ----------------------------------------------------------

# Reads the manifests. Called once at startup and again when the mod list is opened, so a
# mod put into user://mods while the game is running shows up without a restart.
func scan() -> Array:
    mods.clear()
    var by_id := {}
    for root in MOD_ROOTS:
        for dir_name in _subdirectories(root):
            var manifest := _read_manifest(str(root).path_join(dir_name))
            if manifest.is_empty():
                continue
            # A later root wins: user:// overrides res://.
            by_id[str(manifest["id"])] = manifest
    var ids: Array = by_id.keys()
    ids.sort()
    for id in ids:
        mods.append(by_id[id])
    return mods

func get_mod(mod_id: String) -> Dictionary:
    for manifest in mods:
        if str(manifest.get("id", "")) == mod_id:
            return manifest
    return {}

func is_known(mod_id: String) -> bool:
    return not get_mod(mod_id).is_empty()

# The folders of the mods, in the order they are applied. These are the mod folders and
# not their "data" subfolders: data_loader knows where the game data of a mod lives.
func mod_dirs_for(ids: Array) -> Array:
    var dirs: Array = []
    for id in ids:
        var manifest := get_mod(str(id))
        if not manifest.is_empty():
            dirs.append(str(manifest["dir"]))
    return dirs

# --- The set of the running game --------------------------------------------------

# Sets the mods of the running game. The list is sanitized: unknown identifiers are
# dropped (a save may outlive a deleted mod), missing dependencies are added, and the
# order is rebuilt so that a dependency is applied before its dependent.
func set_active(ids: Array) -> void:
    active_ids = resolve(ids)
    _push_to_game_data()

# The identifiers in the order they must be applied: every dependency before the mod
# that requires it.
func resolve(ids: Array) -> Array:
    var wanted := {}
    for id in ids:
        wanted[str(id)] = true
    var ordered: Array = []
    var visiting := {}
    for id in wanted.keys():
        _visit(str(id), wanted, visiting, ordered)
    return ordered

func _visit(mod_id: String, wanted: Dictionary, visiting: Dictionary, ordered: Array) -> void:
    if ordered.has(mod_id) or visiting.has(mod_id) or not is_known(mod_id):
        return
    visiting[mod_id] = true
    for dependency in get_mod(mod_id).get("dependencies", []):
        wanted[str(dependency)] = true
        _visit(str(dependency), wanted, visiting, ordered)
    visiting.erase(mod_id)
    ordered.append(mod_id)

func _push_to_game_data() -> void:
    var game_data = _game_data()
    if game_data == null:
        return
    var dirs := mod_dirs_for(active_ids)
    # The loaded data is thrown away only when the set really differs from the one it
    # was built with. At startup nothing is loaded yet, and pushing the empty set must
    # not claim that the vanilla data on screen is stale.
    var changed: bool = game_data.active_mod_ids != active_ids or game_data.active_mod_dirs != dirs
    game_data.active_mod_ids = active_ids.duplicate()
    game_data.active_mod_dirs = dirs
    if changed:
        game_data.data_loaded = false

# The autoload is looked up through the tree root rather than by its global name: an
# autoload declared before this one is not always resolved in this script (the same
# reason the tests address the autoloads by node path).
func _game_data():
    var loop := Engine.get_main_loop()
    if not (loop is SceneTree):
        return null
    return (loop as SceneTree).root.get_node_or_null("GameData")

# --- Switching a mod on and off ---------------------------------------------------

# What switching `mod_id` on would do: which dependencies come with it and whether it
# clashes with the selected set. The list asks BEFORE it changes anything, so a
# refused switch leaves the list untouched.
#
# Returns {"ok": bool, "reason": String, "add": Array} — `add` lists the dependencies
# that are not selected yet and would be switched on together with the mod.
func enable_plan(mod_id: String, selected: Array) -> Dictionary:
    var manifest := get_mod(mod_id)
    if manifest.is_empty():
        return {"ok": false, "reason": tr("The mod was not found."), "add": []}
    if not str(manifest.get("error", "")).is_empty():
        return {"ok": false, "reason": str(manifest["error"]), "add": []}

    var add := _missing_dependencies(mod_id, selected)
    var next: Array = selected.duplicate()
    next.append(mod_id)
    next.append_array(add)
    var clash := conflict_reason(next)
    if not clash.is_empty():
        return {"ok": false, "reason": clash, "add": []}
    return {"ok": true, "reason": "", "add": add}

# The selected mods that would lose their dependency if `mod_id` were switched off.
func required_by(mod_id: String, selected: Array) -> Array:
    var out: Array = []
    for id in selected:
        if str(id) == mod_id:
            continue
        if _dependencies_of(str(id)).has(mod_id):
            out.append(str(id))
    return out

# Why the given set cannot run together, or "" if it can. Both directions are checked:
# a mod may declare a conflict and may be declared as one.
func conflict_reason(ids: Array) -> String:
    for id in ids:
        var manifest := get_mod(str(id))
        if manifest.is_empty():
            continue
        for other in manifest.get("conflicts", []):
            if ids.has(str(other)):
                return tr("\"%s\" conflicts with \"%s\".") % [
                    str(manifest.get("name", id)), _display_name(str(other))]
    return ""

func _missing_dependencies(mod_id: String, selected: Array) -> Array:
    var out: Array = []
    for dependency in _dependencies_of(mod_id):
        if selected.has(dependency) or out.has(dependency):
            continue
        out.append(dependency)
        out.append_array(_missing_dependencies(dependency, selected))
    return out

# All the dependencies of a mod, direct and indirect.
func _dependencies_of(mod_id: String) -> Array:
    var out: Array = []
    var queue: Array = get_mod(mod_id).get("dependencies", []).duplicate()
    while not queue.is_empty():
        var dependency := str(queue.pop_front())
        if out.has(dependency) or dependency == mod_id:
            continue
        out.append(dependency)
        queue.append_array(get_mod(dependency).get("dependencies", []))
    return out

func _display_name(mod_id: String) -> String:
    var manifest := get_mod(mod_id)
    return str(manifest.get("name", mod_id)) if not manifest.is_empty() else mod_id

# --- The check of the mod data ----------------------------------------------------

# The problems a set of mods brings into the game data, or an empty array if it is clean.
# The check is run on the merged data (vanilla plus these mods), exactly as the game will
# see it, and only the problems the mods ADD to the vanilla ones are reported.
#
# The mod data is checked when the player switches the mod on, and not at startup: the
# startup check covers the game itself, and a mod that is not part of any save must not
# break the menu.
func validate_selection(ids: Array) -> Array:
    var merged := _problems_for(mod_dirs_for(ids))
    var baseline := _vanilla_baseline()
    if baseline.is_empty():
        return merged
    var known := {}
    for problem in baseline:
        known[str(problem.get("message", ""))] = true
    var out: Array = []
    for problem in merged:
        if not known.has(str(problem.get("message", ""))):
            out.append(problem)
    return out

func _problems_for(dirs: Array) -> Array:
    var game_data = _game_data()
    if game_data == null:
        return []
    var probe = game_data.build_probe(dirs)
    var problems: Array = DataValidator.new().validate(probe)
    probe.free()
    return problems

func _vanilla_baseline() -> Array:
    if not _baseline_ready:
        _vanilla_problems = _problems_for([])
        _baseline_ready = true
    return _vanilla_problems

# --- Reading the manifests --------------------------------------------------------

# The manifest of one mod folder. An unreadable or incomplete manifest is still returned,
# with `error` filled in: the player has to see that the folder is there and why it cannot
# be used, otherwise a broken mod simply vanishes from the list.
func _read_manifest(dir: String) -> Dictionary:
    var path := dir.path_join(MANIFEST)
    if not FileAccess.file_exists(path):
        return {}
    var manifest := {
        "id": dir.get_file(),
        "name": dir.get_file(),
        "authors": [],
        "description": "",
        "version": "",
        "dependencies": [],
        "conflicts": [],
        "dir": dir,
        "error": ""
    }
    var parsed = JsonUtils.parse(FileAccess.get_file_as_string(path))
    if not (parsed is Dictionary):
        manifest["error"] = tr("The manifest is not readable JSON.")
        return manifest

    manifest["id"] = str(parsed.get("id", "")).strip_edges()
    manifest["name"] = str(parsed.get("name", "")).strip_edges()
    manifest["version"] = str(parsed.get("version", "")).strip_edges()
    manifest["description"] = str(parsed.get("description", "")).strip_edges()
    manifest["authors"] = _string_list(parsed.get("authors", parsed.get("author", [])))
    manifest["dependencies"] = _string_list(parsed.get("dependencies", []))
    manifest["conflicts"] = _string_list(parsed.get("conflicts", []))

    manifest["error"] = _manifest_error(manifest, dir)
    return manifest

func _manifest_error(manifest: Dictionary, dir: String) -> String:
    var id := str(manifest["id"])
    if id.is_empty():
        return tr("The manifest has no identifier.")
    if not _ident_ok(id):
        return tr("The identifier \"%s\" may consist of latin letters, digits and underscores only.") % id
    for field in ["name", "version"]:
        if str(manifest[field]).is_empty():
            return tr("The manifest has no \"%s\" field.") % field
    if (manifest["authors"] as Array).is_empty():
        return tr("The manifest has no author.")
    for dependency in manifest["dependencies"]:
        if not _ident_ok(str(dependency)):
            return tr("The dependency \"%s\" is not a valid identifier.") % str(dependency)
    if manifest["dependencies"].has(id):
        return tr("The mod depends on itself.")
    if manifest["conflicts"].has(id):
        return tr("The mod conflicts with itself.")
    return ""

func _ident_ok(id: String) -> bool:
    if id.is_empty():
        return false
    for i in id.length():
        if not IDENT_CHARS.contains(id[i]):
            return false
    return true

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

func _subdirectories(root: String) -> Array:
    var out: Array = []
    var dir := DirAccess.open(root)
    if dir == null:
        return out
    for name in dir.get_directories():
        out.append(name)
    out.sort()
    return out
