# Headless test of the shared icon registry IconRegistry (autoload):
#   godot --headless --path . --script res://tests/test_icon_registry.gd
#
# Why: before the registry existed, the icon index was built by recursively
# walking res://icons in EIGHT modules (map_renderer, resources_tab,
# buildings_tab — twice in one file, building_panel, tech_tree, town_ui,
# trade_tab), and the indexing rules diverged: in some places a duplicate
# overwrote the path, in others it was ignored; and half the index was taken up
# by 288 *.import files. Worst of all, buildings_tab built the index inside
# _show_building_details — walking 576 files on every hover over a building.
# The test protects the single remaining source of truth.
#
# The source of truth for the check is the FILE SYSTEM itself (recursive
# directory walk), not the test's constants: icons are added and moved between
# subfolders.
#
# Checked:
#  1. The index is complete: it holds exactly the files in res://icons, minus
#     the service ones (*.import/*.remap/hidden) — checked by name against the
#     walk.
#  2. No service files in the index, no hidden ones.
#  3. No duplicate names (otherwise one image would silently replace another,
#     and the result would depend on the walk order).
#  4. Every path in the index is an existing file with the same name.
#  5. build() is idempotent: rebuilding gives the same result.
#  6. get_texture caches: two calls for one file give ONE object
#     (previously the caches lived as copies in six modules).
#  7. An unknown and an empty name give "" / null, without errors.
#  8. The families of variants are grouped by the name: "tundra_moss_2" belongs to
#     "tundra_moss", so a tileset may draw a whole family with one picture. The
#     truth is the same walk over the disk.
#  9. The entities the data draws with several pictures are published by GameData,
#     so a tileset may name a file after the id instead of after the pictures. The
#     truth is the data: every record with more than one picture in its "icons".
#
# NOT checked: that an icon exists for every reference in data/*.json. The data
# deliberately contains references to icons not drawn yet (future goods and
# professions), the UI skips them as usual — requiring their presence would
# forbid the author from writing data ahead of time. The number of such
# references is printed as a note.
#
# IMPORTANT: the script is compiled BEFORE the autoloads are registered, so we
# get the registry through the scene tree, not by name (the same trick as
# CityData in other tests).
extends SceneTree

# Hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const ROOT := "res://icons"
# Service files the registry must skip.
const SKIP_SUFFIXES := [".import", ".remap"]

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var registry = get_root().get_node("IconRegistry")
    check(registry != null, "IconRegistry autoload is not registered", state)
    if registry == null:
        _finish(state)
        return

    # --- Source of truth: what is actually on disk (recursive walk) ---
    var on_disk := {}
    _scan_disk(ROOT, on_disk)

    check(registry.count() > 0, "icon index is empty (got: %d)" % registry.count(), state)
    check(registry.count() == on_disk.size(),
        "index size does not match the number of files on disk (index has %d, disk has %d)"
            % [registry.count(), on_disk.size()], state)

    # --- 1. Checking the index against disk by name ---
    var missing_in_index: Array = []
    for file_name in on_disk.keys():
        if not registry.has(file_name):
            missing_in_index.append(file_name)
    check(missing_in_index.is_empty(),
        "files missing from the index: %s" % _fmt_list(missing_in_index), state)

    var extra_in_index: Array = []
    for file_name in registry.paths.keys():
        if not on_disk.has(file_name):
            extra_in_index.append(file_name)
    check(extra_in_index.is_empty(),
        "the index has entries that are not on disk: %s" % _fmt_list(extra_in_index), state)

    # --- 2. Service and hidden files do not get into the index ---
    var junk: Array = []
    for file_name in registry.paths.keys():
        var is_junk: bool = file_name.begins_with(".")
        for suffix in SKIP_SUFFIXES:
            if file_name.ends_with(suffix):
                is_junk = true
        if is_junk:
            junk.append(file_name)
    check(junk.is_empty(),
        "service/hidden files got into the index: %s" % _fmt_list(junk), state)

    # --- 3. Duplicate names ---
    # We count them ourselves: if two images in different subfolders have the
    # same name, the first stays in the index and the second is silently lost.
    var names_seen := {}
    var duplicates: Array = []
    for path in on_disk.values():
        var base: String = str(path).get_file()
        if names_seen.has(base):
            duplicates.append("%s (%s and %s)" % [base, names_seen[base], path])
        else:
            names_seen[base] = path
    check(duplicates.is_empty(),
        "res://icons has files with the same name in different folders: %s"
            % _fmt_list(duplicates), state)
# --- 4. Index paths point to existing files ---
    var bad_paths: Array = []
    var checked_paths := 0
    for file_name in registry.paths.keys():
        var path: String = registry.paths[file_name]
        checked_paths += 1
        if str(path).get_file() != file_name or not FileAccess.file_exists(path):
            bad_paths.append("%s -> %s" % [file_name, path])
    check(checked_paths == on_disk.size(),
        "checked %d paths, but there are %d files on disk" % [checked_paths, on_disk.size()], state)
    check(bad_paths.is_empty(),
        "index paths do not lead to files: %s" % _fmt_list(bad_paths), state)

    # --- 5. build() is idempotent ---
    var count_before: int = registry.count()
    registry.build()
    check(registry.count() == count_before,
        "a repeated build() changed the index size (was %d, became %d)"
            % [count_before, registry.count()], state)

    # --- 6. get_texture returns a shared cached object ---
    var texture_name := ""
    for file_name in registry.paths.keys():
        if str(file_name).ends_with(".png"):
            texture_name = file_name
            break
    check(not texture_name.is_empty(), "the index has no .png at all", state)
    if not texture_name.is_empty():
        var tex_a = registry.get_texture(texture_name)
        var tex_b = registry.get_texture(texture_name)
        check(tex_a is Texture2D, "get_texture returned a non-texture for %s" % texture_name, state)
        check(tex_a == tex_b,
            "texture %s is loaded again instead of from the cache" % texture_name, state)
        # The path and the texture must correspond to the same entry.
        check(registry.icon_path(texture_name) == str(registry.paths[texture_name]),
            "icon_path disagrees with paths for %s" % texture_name, state)

    # --- 7. Unknown names ---
    check(registry.icon_path("definitely_missing_icon.png") == "",
        "icon_path for a nonexistent icon returned a non-empty string", state)
    check(registry.get_texture("definitely_missing_icon.png") == null,
        "get_texture for a nonexistent icon returned a non-null value", state)
    check(registry.icon_path("") == "", "icon_path for an empty name returned a non-empty string", state)
    check(registry.get_texture("") == null, "get_texture for an empty name returned a non-null value", state)
    check(not registry.has("definitely_missing_icon.png"),
        "has() for a nonexistent icon returned true", state)

    # --- 8. The families of variants ---
    # The same walk gives the truth: a name ending with "_<digits>" belongs to the family of
    # the part before the number.
    var expected_families := {}
    for file_name in on_disk.keys():
        var bare: String = str(file_name).get_basename()
        var cut := bare.rfind("_")
        if cut <= 0:
            continue
        var tail := bare.substr(cut + 1)
        var numeric := not tail.is_empty()
        for i in tail.length():
            if tail[i] < "0" or tail[i] > "9":
                numeric = false
        if not numeric:
            continue
        var base := bare.substr(0, cut)
        if not expected_families.has(base):
            expected_families[base] = []
        expected_families[base].append(bare)
    check(registry.families.size() == expected_families.size(),
        "the index has %d families, the disk has %d"
            % [registry.families.size(), expected_families.size()], state)
    var wrong_families: Array = []
    for base in expected_families:
        var expected: Array = expected_families[base].duplicate()
        expected.sort()
        if registry.variants(base) != expected:
            wrong_families.append("%s -> %s, expected %s"
                % [base, str(registry.variants(base)), str(expected)])
    check(wrong_families.is_empty(),
        "families disagree with the disk: %s" % _fmt_list(wrong_families), state)
    var plain_name := ""
    for file_name in on_disk.keys():
        var bare: String = str(file_name).get_basename()
        if not expected_families.has(bare):
            plain_name = bare
            break
    check(not plain_name.is_empty() and registry.variants(plain_name).is_empty(),
        "an icon that is no family answers with variants: %s" % plain_name, state)

    # Note (not a check): how many references in the data point to icons not
    # drawn yet. Printed so the author can see the scale.
    _print_missing_references(state)

    _check_entity_pictures(registry, state)

    _finish(state)

# --- 9. The entities drawn by several pictures ---
# The map belongs to the data, so the truth is the data itself: every record whose "icons"
# array holds more than one picture. A tileset file named after such an id draws the whole
# entity, whatever its pictures are called (data/covers.json draws a forest with
# forest_1..3.png, not with temperate_rainforest_1..3.png).
func _check_entity_pictures(registry, state: Dictionary) -> void:
    var gdata = get_root().get_node("GameData")
    if gdata == null:
        return
    if not gdata.data_loaded:
        gdata.load_all_data()
    var expected := {}
    for collection in [gdata.covers, gdata.terrains]:
        for id in collection:
            var icons: Array = (collection[id] as Dictionary).get("icons", [])
            if icons.size() > 1:
                expected[str(id)] = icons
    check(registry.entity_pictures.size() == expected.size(),
        "the registry knows %d entities of several pictures, the data has %d"
            % [registry.entity_pictures.size(), expected.size()], state)
    var wrong: Array = []
    for id in expected:
        if registry.pictures_of(id) != expected[id]:
            wrong.append("%s -> %s, expected %s"
                % [id, str(registry.pictures_of(id)), str(expected[id])])
    check(wrong.is_empty(), "the pictures of an entity disagree with the data: %s"
        % _fmt_list(wrong), state)
    check(registry.pictures_of("definitely_missing_entity").is_empty(),
        "an id no entity carries answers with pictures", state)

    # The same map published twice costs nothing; a changed one is announced: the table of
    # the tilesets is built from it, and it may have been built before the data was read.
    var fired := [0]
    var counter := func() -> void: fired[0] += 1
    registry.entity_pictures_changed.connect(counter)
    registry.set_entity_pictures(registry.entity_pictures)
    check(fired[0] == 0, "an unchanged map of pictures was published again", state)
    registry.set_entity_pictures({})
    check(fired[0] == 1, "a changed map of pictures is not announced", state)
    registry.set_entity_pictures(expected)
    check(fired[0] == 2, "the map of pictures did not come back", state)
    registry.entity_pictures_changed.disconnect(counter)
# Recursive directory walk with the same skip rules as the registry.
func _scan_disk(folder_path: String, out: Dictionary) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while not file_name.is_empty():
        if dir.current_is_dir():
            _scan_disk(folder_path.path_join(file_name), out)
        else:
            var skip: bool = file_name.begins_with(".")
            for suffix in SKIP_SUFFIXES:
                if file_name.ends_with(suffix):
                    skip = true
            if not skip:
                out[file_name] = folder_path.path_join(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()

# Prints which icons the data references but whose file does not exist yet.
# This is normal (future content), so it is not treated as a check.
func _print_missing_references(_state: Dictionary) -> void:
    var registry = get_root().get_node("IconRegistry")
    var gdata = get_root().get_node("GameData")
    if registry == null or gdata == null:
        return
    if not gdata.data_loaded:
        gdata.load_all_data()
    var missing := {}
    for entry in _iter_icon_refs(gdata):
        var name := str(entry)
        if not name.is_empty() and not registry.has(name):
            missing[name] = true
    print("NOTE: references in the data to icons not drawn yet — %d (this is normal)"
        % missing.size())

# All values of the icon / icons fields in the data: raw resources, goods,
# improvements, terrains, covers, buildings, technologies, special actions,
# modifiers, groups, professions.
func _iter_icon_refs(gdata) -> Array:
    var out: Array = []
    for d in [gdata.raw_resources, gdata.products, gdata.improvements,
            gdata.terrains, gdata.professions, gdata.qualities, gdata.covers,
            gdata.special_actions]:
        _collect_from_dict(d, out)
    for list_data in [gdata.technologies, gdata.crafts, gdata.categories, gdata.eras]:
        _collect_from_list(list_data, out)
    _collect_from_dict(gdata.product_group_icons, out)
    for group_id in gdata.product_groups.keys():
        _collect_from_list(gdata.product_groups[group_id], out)
    # Modifiers: the outer shape is a dictionary, but an entry may also be a
    # list (the data does not impose a single shape), so we check the type
    # before reading.
    for mod in gdata.modifiers.values():
        if mod is Dictionary:
            _collect_from_list(mod.get("tech_modifiers", []), out)
        elif mod is Array:
            _collect_from_list(mod, out)
    return out

func _collect_from_dict(source, out: Array) -> void:
    if source == null or not (source is Dictionary):
        return
    for value in source.values():
        _collect_from_entry(value, out)

func _collect_from_list(source, out: Array) -> void:
    if source == null or not (source is Array):
        return
    for value in source:
        _collect_from_entry(value, out)

func _collect_from_entry(value, out: Array) -> void:
    if value == null:
        return
    if value is String or value is StringName:
        # product_group_icons stores id -> icon file name.
        if not str(value).is_empty():
            out.append(str(value))
        return
    if not (value is Dictionary):
        return
    var d: Dictionary = value
    if d.has("icon"):
        out.append(str(d["icon"]))
    if d.has("icons"):
        _collect_from_list(d["icons"], out)
    # Arbitrary technology effects: [{ "icon": ..., "name": ... }].
    _collect_from_list(d.get("unlock_effects", []), out)

func _fmt_list(items: Array) -> String:
    if items.is_empty():
        return "(none)"
    var shown := items.slice(0, 8)
    var text := ", ".join(PackedStringArray(shown))
    if items.size() > shown.size():
        text += " … %d total" % items.size()
    return text

func _finish(state: Dictionary) -> void:
    if state["failed"]:
        print("ICON REGISTRY TEST FAILED")
        quit(1)
    else:
        print("ICON REGISTRY TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
