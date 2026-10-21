# Headless test of the mods:
#   godot --headless --path . --script res://tests/test_mods.gd
#
# The test runs on a bare tree — no map is generated, so it is fast. It covers:
#   1. The registry: the shipped mods/test_mod is found with every manifest field.
#   2. The merge: a new identifier is added, an existing one is overridden field by
#      field, and neither is duplicated.
#   3. The blacklist: the entities a mod lists are removed, the same identifier may be
#      named in several collections, and the references to a removed entity are the
#      mod's own business.
#   4. The set belongs to the save: a slot that names a mod restores it on loading.
#   5. Dependencies and conflicts: a dependency comes along with its dependent and is
#      applied before it; a conflicting pair cannot be switched on; a dependency cannot
#      be switched off under its dependent.
#   6. The data of a mod is checked when the mod is switched on, and the check points at
#      the mod's own file; a clean mod produces no problems.
#   7. The list: one row per mod, the checkbox drives the set, the change is reported to
#      the host.
#   8. The "New game" path: the city naming dialog comes first, the list is folded under
#      it, and unfolding it and switching a mod on applies the set at once.
#
# The test creates its own mods in user://mods and removes them afterwards, and it leaves
# the game without mods, as it found it.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal silence
# from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const SHIPPED_MOD := "test_mod"
# The mods of the test. They live in user:// and are removed at the end.
const DEP_MOD := "test_dep"
const CHILD_MOD := "test_dep_child"
const RIVAL_MOD := "test_dep_rival"
const BROKEN_MOD := "test_broken"
const BLACKLIST_MOD := "test_blacklist"
const SYNTHETIC_MODS := [DEP_MOD, CHILD_MOD, RIVAL_MOD, BROKEN_MOD, BLACKLIST_MOD]

const VANILLA_FLOUR_PRICE := 4
const MOD_FLOUR_PRICE := 12
const VANILLA_HAND_MILL_COST := 10
const MOD_HAND_MILL_COST := 5

var _mod_manager = null
var _game_data = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    _mod_manager = get_root().get_node("ModManager")
    _game_data = get_root().get_node("GameData")
    var save_manager = get_root().get_node("SaveManager")

    _remove_synthetic_mods()
    _write_synthetic_mods()

    _test_registry(state)
    _test_merge(state)
    _test_blacklist(state)
    _test_save_set(state, save_manager)
    _test_dependencies(state)
    _test_validation(state)
    await _test_list(state)
    await _test_new_game_flow(state)

    _remove_synthetic_mods()
    _mod_manager.set_active([])
    _game_data.load_all_data()
    _finish(state)

# --- 1. The registry --------------------------------------------------------------

func _test_registry(state: Dictionary) -> void:
    _mod_manager.scan()
    var manifest = _mod_manager.get_mod(SHIPPED_MOD)
    check(not manifest.is_empty(), "the shipped test mod is found", state)
    if manifest.is_empty():
        return
    check(str(manifest["name"]) == "Test Mod", "the manifest name is read", state)
    check(str(manifest["version"]) == "1.0.0", "the manifest version is read", state)
    check(manifest["authors"] == ["The City team"], "the manifest authors are read", state)
    check(not str(manifest["description"]).is_empty(), "the manifest description is read", state)
    check((manifest["dependencies"] as Array).is_empty(), "no dependencies", state)
    check((manifest["conflicts"] as Array).is_empty(), "no conflicts", state)
    check(str(manifest["error"]).is_empty(), "the manifest is usable", state)
    check(_mod_manager.is_known(DEP_MOD), "a mod put into user://mods is found", state)

# --- 2. The merge -----------------------------------------------------------------

func _test_merge(state: Dictionary) -> void:
    _mod_manager.set_active([])
    _game_data.load_all_data()

    var vanilla_products = _game_data.products.size()
    var vanilla_buildings = _game_data.buildings.size()
    check(not _game_data.products.has("glazed_tile"), "the new product is absent without the mod", state)
    check(int(_game_data.products["flour"]["price"]) == VANILLA_FLOUR_PRICE, "the vanilla price of flour", state)
    check(_find_building("hand_mill")["work_cost"] == VANILLA_HAND_MILL_COST, "the vanilla cost of the hand mill", state)
    check(not _has_craft("fire_glazed_tile"), "the new recipe is absent without the mod", state)
    check(not _find_building("alchemist_house").is_empty(), "the vanilla alchemist house is there without the mod", state)
    check(_has_craft("papyrus"), "the vanilla papyrus recipe is there without the mod", state)
    check(_game_data.products.has("papyrus"), "the vanilla papyrus product is there without the mod", state)
    _mod_manager.set_active([SHIPPED_MOD])
    _game_data.load_all_data()

    # A new identifier is added.
    check(_game_data.products.has("glazed_tile"), "the new product is added", state)
    check(int(_game_data.products["glazed_tile"]["price"]) == 18, "the new product carries its own fields", state)
    check(not _find_building("tile_kiln").is_empty(), "the new building is added", state)
    check(_has_craft("fire_glazed_tile"), "the new recipe is added", state)

    # An existing identifier is overridden, field by field.
    check(int(_game_data.products["flour"]["price"]) == MOD_FLOUR_PRICE, "the price of flour is overridden", state)
    check(str(_game_data.products["flour"]["name"]) == "Flour (Test Mod)", "the name of flour is overridden", state)
    check(str(_game_data.products["flour"]["category"]) == "material", "a field the mod does not write keeps its value", state)
    check(int(_find_building("hand_mill")["work_cost"]) == MOD_HAND_MILL_COST, "the cost of the hand mill is overridden", state)
    check(not str(_find_building("hand_mill")["description"]).is_empty(), "the description of the hand mill survives", state)

    # Nothing is duplicated: the collections grew exactly by the new identifiers and
    # shrank by the blacklisted ones (see _test_blacklist).
    check(_game_data.products.size() == vanilla_products - 2,
            "one new product, three blacklisted, the overridden one is not added twice", state)
    check(_game_data.buildings.size() == vanilla_buildings,
            "one new building, one blacklisted", state)
    check(_count_buildings("hand_mill") == 1, "the overridden building stays single", state)

# --- 3. The blacklist --------------------------------------------------------------

func _test_blacklist(state: Dictionary) -> void:
    _mod_manager.set_active([SHIPPED_MOD])
    _game_data.load_all_data()

    # The entities the blacklist names are gone, from every collection they were named in.
    check(not _game_data.products.has("papyrus"), "the blacklisted product is removed", state)
    check(not _has_craft("papyrus"), "the blacklisted recipe is removed", state)
    check(not _game_data.products.has("glass_bottle"), "the second blacklisted product is removed", state)
    check(not _has_craft("glass_bottle"), "the second blacklisted recipe is removed", state)
    check(not _game_data.products.has("green_vitriol"), "the third blacklisted product is removed", state)
    check(not _has_craft("green_vitriol"), "the third blacklisted recipe is removed", state)
    check(not _has_craft("ink_from_green_vitriol_galls"), "the recipe that spent the removed product is removed", state)
    check(_find_building("alchemist_house").is_empty(), "the blacklisted building is removed", state)
    check(_count_buildings("alchemist_house") == 0, "the blacklisted building leaves no trace", state)

    # The same identifier in two collections is two entities: the recipe and the product
    # "papyrus" are both gone, and neither took the other's place.
    var removed = _game_data.blacklisted
    check((removed.get("resources", {}) as Dictionary).has("papyrus"),
            "the removed product is recorded", state)
    check((removed.get("crafts", {}) as Dictionary).has("papyrus"),
            "the removed recipe is recorded", state)

    # The references to a removed entity are the mod's own business: the mod drops
    # "papyrus" from the two goods groups that listed it, and they keep working.
    var rope_fibers = _game_data.product_groups.get("rope_fibers", [])
    check(not (rope_fibers as Array).has("papyrus"),
            "the removed product is dropped from the goods group", state)
    check((rope_fibers as Array).has("hemp"), "the rest of the group survives", state)
    var writing = _game_data.product_groups.get("writing_materials", [])
    check(not (writing as Array).has("papyrus"),
            "the removed product is dropped from the second group too", state)

    # A neighbour that nothing was removed from stays as it was.
    check(_has_craft("reed_boat"), "a recipe of the same workshop survives", state)
    check(_game_data.products.has("papyrus_plant"), "the ingredient of the removed recipe survives", state)
    check(_has_craft("ink_from_iron_galls_vinegar"),
            "the second recipe of the same product survives", state)
    check(_game_data.products.has("ink"), "the product of the removed recipe keeps its second source", state)

# --- 4. The set belongs to the save -----------------------------------------------

func _test_save_set(state: Dictionary, save_manager) -> void:
    var slot = "test_mods_slot"
    save_manager.write_slot(slot, {
        "city_name": "Modsville",
        "mods": [SHIPPED_MOD],
        "_meta": {"id": slot, "name": "Modsville", "city_name": "Modsville",
                "saved_at": int(Time.get_unix_time_from_system()), "era_index": 0,
                "population": 0, "mods": [SHIPPED_MOD]}
    })
    check(save_manager.load_game(slot), "the slot with mods is loaded", state)
    check(_mod_manager.active_ids == [SHIPPED_MOD], "the mods of the save are restored", state)
    check(not _game_data.active_mod_dirs.is_empty(), "the data folders of the set are pushed to the game", state)

    var meta = save_manager.list_saves()
    var found = {}
    for slot_meta in meta:
        if str(slot_meta.get("id", "")) == slot:
            found = slot_meta
    check(found.get("mods", []) == [SHIPPED_MOD], "the save list knows the mods of the slot", state)

    save_manager.delete_save(slot)
    check(not save_manager.has_slot(slot), "the test slot is removed", state)

    # A slot written without mods runs vanilla.
    _mod_manager.set_active([SHIPPED_MOD])
    save_manager.write_slot(slot, {"city_name": "Plain", "_meta": {"id": slot, "name": "Plain"}})
    check(save_manager.load_game(slot), "the slot without mods is loaded", state)
    check(_mod_manager.active_ids.is_empty(), "a save without mods restores an empty set", state)
    save_manager.delete_save(slot)

# --- 5. Dependencies and conflicts ------------------------------------------------

func _test_dependencies(state: Dictionary) -> void:
    var plan = _mod_manager.enable_plan(CHILD_MOD, [])
    check(plan["ok"], "a mod with a dependency can be switched on", state)
    check(plan["add"] == [DEP_MOD], "the missing dependency comes with it", state)

    var ordered = _mod_manager.resolve([CHILD_MOD])
    check(ordered == [DEP_MOD, CHILD_MOD], "a dependency is applied before its dependent", state)

    var rival = _mod_manager.enable_plan(RIVAL_MOD, [CHILD_MOD])
    check(not rival["ok"], "a conflicting mod is refused", state)
    check(not str(rival["reason"]).is_empty(), "the refusal explains itself", state)

    check(_mod_manager.required_by(DEP_MOD, [DEP_MOD, CHILD_MOD]) == [CHILD_MOD],
            "a dependency is held by its dependent", state)
    check(_mod_manager.required_by(DEP_MOD, [DEP_MOD]).is_empty(),
            "a dependency nobody needs can be switched off", state)

# --- 6. The check on switching on --------------------------------------------------

func _test_validation(state: Dictionary) -> void:
    check(_mod_manager.validate_selection([]).is_empty(), "the vanilla data is clean", state)

    var clean = _mod_manager.validate_selection([SHIPPED_MOD])
    check(clean.is_empty(), "a clean mod adds no problems", state)

    var broken = _mod_manager.validate_selection([BROKEN_MOD])
    check(not broken.is_empty(), "a broken mod is caught on switching on", state)
    var kinds = {}
    var files = {}
    for problem in broken:
        kinds[str(problem.get("kind", ""))] = true
        files[str(problem.get("file", ""))] = true
    check(kinds.has("result"), "the nonexistent product of a recipe is reported", state)
    check(kinds.has("unknown_field"), "an unknown field of a mod is reported", state)
    var points_at_mod = false
    for file in files:
        if str(file).contains("user://mods/" + BROKEN_MOD):
            points_at_mod = true
    check(points_at_mod, "the problem points at the file of the mod", state)

    # A blacklist that names nothing is a typo, and a blacklist key that is not a
    # collection is one too. Both are reported instead of silently doing nothing.
    var typo = _mod_manager.validate_selection([BLACKLIST_MOD])
    check(not typo.is_empty(), "a broken blacklist is caught on switching on", state)
    var typo_kinds := {}
    var typo_files := {}
    for problem in typo:
        typo_kinds[str(problem.get("kind", ""))] = true
        typo_files[str(problem.get("file", ""))] = true
    check(typo_kinds.has("blacklist"), "a blacklist entry that names nothing is reported", state)
    check(typo_kinds.has("unknown_field"), "a blacklist collection that does not exist is reported", state)
    var typo_points_at_mod = false
    for file in typo_files:
        if str(file).contains("user://mods/" + BLACKLIST_MOD):
            typo_points_at_mod = true
    check(typo_points_at_mod, "the blacklist problems point at the file of the mod", state)

# --- 7. The list -------------------------------------------------------------------

func _test_list(state: Dictionary) -> void:
    _mod_manager.scan()
    var mod_list = load("res://scenes/mod_list.tscn").instantiate()
    get_root().add_child(mod_list)
    # The rows are built in _ready, and _ready of a node added to the root during
    # _initialize runs on the next frame.
    await process_frame
    mod_list.open([])

    var rows = mod_list.list.get_child_count()
    check(rows == _mod_manager.mods.size(), "one row per installed mod", state)

    var emitted = {"ids": []}
    mod_list.selection_changed.connect(func(ids: Array) -> void: emitted["ids"] = ids)

    var checkbox = mod_list._checkboxes.get(SHIPPED_MOD, null)
    check(checkbox != null, "the shipped mod has a checkbox", state)
    if checkbox == null:
        mod_list.free()
        return
    check(not checkbox.button_pressed, "the checkbox starts off", state)

    # The checkbox is the switch: pressing it puts the mod into the set and tells the host.
    checkbox.button_pressed = true
    check(mod_list._selected.has(SHIPPED_MOD), "switching the checkbox on adds the mod", state)
    check(emitted["ids"].has(SHIPPED_MOD), "the new set is reported to the host", state)
    check(mod_list.selected_ids() == mod_list._selected, "the list hands out its set", state)

    # A dependency comes along with its dependent.
    var child = mod_list._checkboxes.get(CHILD_MOD, null)
    if child != null:
        child.button_pressed = true
        check(mod_list._selected.has(DEP_MOD), "the dependency is switched on with its dependent", state)
        # A dependency cannot be switched off under its dependent.
        var dependency = mod_list._checkboxes.get(DEP_MOD, null)
        dependency.button_pressed = false
        check(dependency.button_pressed, "the checkbox of a needed dependency stays on", state)
        check(mod_list.problems_panel.visible, "the refusal is explained in the list", state)

    # A broken mod does not stay switched on, and the list says why.
    var broken = mod_list._checkboxes.get(BROKEN_MOD, null)
    if broken != null:
        broken.button_pressed = true
        check(not broken.button_pressed, "a broken mod is switched back off", state)
        check(not mod_list._selected.has(BROKEN_MOD), "a broken mod is not part of the set", state)
        check(mod_list.problems_panel.visible, "the problems of the mod are shown", state)

    mod_list.free()

# --- 8. The "New game" path -------------------------------------------------------

# "New game" opens the city naming dialog at once, and the mods of the game are folded
# away under the name field. Unfolding them and switching a mod on applies the set
# immediately — the dialog offers a random city name, and a mod may bring its own names.
func _test_new_game_flow(state: Dictionary) -> void:
    _mod_manager.set_active([])
    _game_data.load_all_data()

    var menu = load("res://scenes/main_menu.tscn").instantiate()
    get_root().add_child(menu)
    await process_frame

    var new_game_button = menu.get_node("VBoxContainer/NewGameButton")
    new_game_button.pressed.emit()
    await process_frame

    var dialog = menu.new_game_dialog
    check(dialog != null, "New game opens the city naming dialog", state)
    if dialog == null:
        menu.free()
        return
    check(dialog.visible, "the dialog is shown", state)
    check(menu.mod_list != null, "the dialog carries the mod list", state)
    check(not menu.mod_list.visible, "the list starts collapsed", state)
    check(not menu.mods_toggle.button_pressed, "the toggle starts off", state)
    check(menu.mods_toggle.text == tr("Mods"), "a game without mods says so on the toggle", state)

    menu.mods_toggle.button_pressed = true
    check(menu.mod_list.visible, "the toggle unfolds the list", state)

    var checkbox = menu.mod_list._checkboxes.get(SHIPPED_MOD, null)
    check(checkbox != null, "the mod has a checkbox in the dialog", state)
    if checkbox != null:
        checkbox.button_pressed = true
        check(_mod_manager.active_ids.has(SHIPPED_MOD),
                "the set is applied without leaving the dialog", state)
        # The data is not rebuilt on every click: it is marked stale and rebuilt when the
        # dialog really reads it (the random name) or when the game starts.
        check(not _game_data.data_loaded, "a click marks the data stale instead of rebuilding it", state)
        menu._ensure_game_data()
        check(_game_data.products.has("glazed_tile"), "the data is rebuilt when it is needed", state)
        check(menu.mods_toggle.text == "%s (1)" % tr("Mods"), "the toggle counts the mods", state)

    # Folding the list back does not undo the choice.
    menu.mods_toggle.button_pressed = false
    check(not menu.mod_list.visible, "the toggle folds the list back", state)
    check(_mod_manager.active_ids.has(SHIPPED_MOD), "the choice survives folding", state)

    menu.free()
    _mod_manager.set_active([])
    _game_data.load_all_data()

# --- The synthetic mods ------------------------------------------------------------

func _write_synthetic_mods() -> void:
    _write_mod(DEP_MOD, {
        "id": DEP_MOD, "name": "Dependency", "authors": ["Test"],
        "description": "A mod others depend on.", "version": "1.0.0"
    })
    _write_mod(CHILD_MOD, {
        "id": CHILD_MOD, "name": "Child", "authors": ["Test"],
        "description": "A mod with a dependency.", "version": "1.0.0",
        "dependencies": [DEP_MOD]
    })
    _write_mod(RIVAL_MOD, {
        "id": RIVAL_MOD, "name": "Rival", "authors": ["Test"],
        "description": "A mod that conflicts with the child.", "version": "1.0.0",
        "conflicts": [CHILD_MOD]
    })
    # A mod whose data is broken: a recipe yields a product that does not exist, and the
    # record carries a field the data model does not describe.
    _write_mod(BROKEN_MOD, {
        "id": BROKEN_MOD, "name": "Broken", "authors": ["Test"],
        "description": "A mod with broken data.", "version": "1.0.0"
    })
    var data_dir = "user://mods/%s/data" % BROKEN_MOD
    DirAccess.make_dir_recursive_absolute(data_dir)
    _write_text(data_dir.path_join("crafts.json"), """{
  "crafts": [
    {
      "id": "broken_craft",
      "name": "Broken Craft",
      "produced_in": [ "hand_mill" ],
      "resources": { "bricks": 1 },
      "result": { "nonexistent_product": 1 },
      "time": 1,
      "bogus_field": 1
    }
  ]
}
""")
    # A mod whose blacklist is broken twice: an identifier that names nothing, and a
    # key that is not a collection at all. Both must be reported, and neither removes
    # anything.
    _write_mod(BLACKLIST_MOD, {
        "id": BLACKLIST_MOD, "name": "Blacklist", "authors": ["Test"],
        "description": "A mod with a broken blacklist.", "version": "1.0.0"
    })
    data_dir = "user://mods/%s/data" % BLACKLIST_MOD
    DirAccess.make_dir_recursive_absolute(data_dir)
    _write_text(data_dir.path_join("blacklist.json"), """{
  "blacklist": {
    "buildings": [ "no_such_building" ],
    "recipe": [ "papyrus" ]
  }
}
""")

func _write_mod(mod_id: String, manifest: Dictionary) -> void:
    var dir = "user://mods/%s" % mod_id
    DirAccess.make_dir_recursive_absolute(dir)
    _write_text(dir.path_join("mod.json"), JSON.stringify(manifest, "\t"))

func _write_text(path: String, text: String) -> void:
    var file = FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("the test cannot write " + path)
        return
    file.store_string(text)
    file.close()

func _remove_synthetic_mods() -> void:
    for mod_id in SYNTHETIC_MODS:
        var dir = "user://mods/%s" % mod_id
        var data_dir = dir.path_join("data")
        for path in [data_dir.path_join("crafts.json"), data_dir.path_join("blacklist.json"),
                data_dir.path_join("mod.json"), dir.path_join("mod.json")]:
            if FileAccess.file_exists(path):
                DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
        for path in [data_dir, dir]:
            if DirAccess.open(path) != null:
                DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

# --- Helpers -----------------------------------------------------------------------

func _find_building(building_id: String) -> Dictionary:
    for building in _game_data.buildings:
        if str(building.get("id", "")) == building_id:
            return building
    return {}

func _count_buildings(building_id: String) -> int:
    var count = 0
    for building in _game_data.buildings:
        if str(building.get("id", "")) == building_id:
            count += 1
    return count

func _has_craft(craft_id: String) -> bool:
    for craft in _game_data.crafts:
        if str(craft.get("id", "")) == craft_id:
            return true
    return false

func _finish(state: Dictionary) -> void:
    if state["failed"]:
        print("MODS TEST FAILED")
        quit(1)
    else:
        print("MODS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
