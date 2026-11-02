# Headless test of the tilesets (TilesetManager autoload) and of the icon replacements
# they bring into IconRegistry:
#   godot --headless --path . --script res://tests/test_tilesets.gd
#
# The test runs on a bare tree — no map is generated, so it is fast. It covers:
#   1. The registry of the installed tilesets: a folder that starts with "_" is skipped, so
#      the shipped example does not replace the art of the game.
#   2. Reading a manifest: every field of res://tilesets/_example, the seven types, and the
#      images collected from the subfolders of the folder.
#   3. The type of a vanilla icon is the folder it lies in — all seven types, including
#      "misc" for the root of res://icons and for a bare name.
#   4. The replacement table: an icon is addressed by its bare name, so an SVG replaces a
#      PNG; a file of a type the tileset does not declare replaces nothing; a file that
#      names no vanilla icon replaces nothing.
#   5. One tileset per type: the folder that sorts last owns the type whole, two building
#      sets never mix, and a broken manifest is skipped.
#   6. The choice of the player: a chosen set draws its type whatever the folder order, the
#      vanilla icons are a choice too, a set that is gone falls back to the folder rule, and
#      the choice is read from user://settings.cfg at scan time.
#   7. Installing a table changes what the game shows (path and texture), and an empty
#      table gives the vanilla icons back.
#   8. The example itself is healthy: every file of it names a vanilla icon.
#
# The test does not create folders on disk: it reads the shipped example and feeds
# synthetic records to the table builder, so it cannot leave anything behind.
#
# IMPORTANT: the script is compiled BEFORE the autoloads are registered, so we get them
# through the scene tree, not by name.
extends SceneTree

# Hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const ROOT := "res://tilesets"
# The shipped example: a complete tileset whose folder name keeps it switched off.
const EXAMPLE := "res://tilesets/_example"
const EXAMPLE_ICONS := {
    "bread": "resources",
    "corn": "resources",
    "hand_mill": "buildings",
    "bakery": "buildings",
    "market": "buildings",
    "wheel": "technologies",
    "boreal_hill_1": "terrains",
    "farm": "improvements",
    "mine": "improvements",
    "clear_forest": "special_actions",
    "coin_stack": "misc",
    "building_pause": "misc",
    "building_upgrade": "misc",
    "city": "misc"
}
# The type of a vanilla icon: the folder it lies in, by the name the manifest uses.
const VANILLA_TYPES := {
    "bread.png": "resources",
    "bakery.png": "buildings",
    "wheel.png": "technologies",
    "beach_1.png": "terrains",
    "farm.png": "improvements",
    "clear_forest.png": "special_actions",
    "road.svg": "special_actions",
    "coin_stack.png": "misc",
    "dice.svg": "misc"
}

var _tilesets = null
var _registry = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    _tilesets = get_root().get_node("TilesetManager")
    _registry = get_root().get_node("IconRegistry")
    check(_tilesets != null, "TilesetManager autoload is not registered", state)
    check(_registry != null, "IconRegistry autoload is not registered", state)
    if _tilesets == null or _registry == null:
        _finish(state)
        return

    _check_disabled_folders(state)
    _check_reading(state)
    _check_types(state)
    _check_table(state)
    _check_one_tileset_per_type(state)
    _check_choices(state)
    _check_installing(state)
    _check_example_health(state)

    _finish(state)

# --- 1. A folder whose name starts with "_" is not a tileset ---
func _check_disabled_folders(state: Dictionary) -> void:
    var found: Array = _tilesets.scan()
    check(found.is_empty(),
        "a folder starting with \"_\" was taken for a tileset: %s" % str(found), state)
    check(_tilesets.get_tileset("_example").is_empty(),
        "the disabled example is in the registry of the tilesets", state)
    # The game itself keeps its own art.
    check(_registry.overrides.is_empty(),
        "the overrides are not empty with no tileset installed: %s" % str(_registry.overrides), state)
    check(_registry.icon_path("bakery.png") == str(_registry.paths["bakery.png"]),
        "a vanilla icon does not point at its own file with no tileset installed", state)

# --- 2. Reading a manifest ---
func _check_reading(state: Dictionary) -> void:
    # A folder without a manifest is not a tileset at all.
    check(_tilesets.read_tileset(ROOT).is_empty(),
        "a folder without tileset.json was read as a tileset", state)

    var record: Dictionary = _tilesets.read_tileset(EXAMPLE)
    check(not record.is_empty(), "the example tileset was not read", state)
    if record.is_empty():
        return
    check(str(record["error"]).is_empty(),
        "the example tileset is not usable: %s" % str(record["error"]), state)
    check(record["id"] == "_example", "the id of the tileset is not its folder name", state)
    check(str(record["name"]) == "Placeholder Set",
        "the name of the example is wrong: %s" % str(record["name"]), state)
    check(not str(record["description"]).is_empty(), "the description of the example is empty", state)
    check((record["authors"] as Array) == ["The City"],
        "the author of the example is wrong: %s" % str(record["authors"]), state)
    check(str(record["version"]) == "1.0.0",
        "the version of the example is wrong: %s" % str(record["version"]), state)

    var types: Array = record["types"]
    check(types.size() == 7, "the example must declare all seven types, got %d" % types.size(), state)
    for type_name in types:
        check(_tilesets.TYPES.has(type_name), "unknown type in the example: %s" % type_name, state)

    var icons: Dictionary = record["icons"]
    check(icons.size() == EXAMPLE_ICONS.size(),
        "the example has %d images, expected %d — the scan is recursive and skips non-images"
            % [icons.size(), EXAMPLE_ICONS.size()], state)
    for bare_name in EXAMPLE_ICONS:
        check(icons.has(bare_name), "the image \"%s\" was not collected" % bare_name, state)
        if icons.has(bare_name):
            check(FileAccess.file_exists(str(icons[bare_name])),
                "the collected path of \"%s\" does not exist: %s" % [bare_name, icons[bare_name]], state)

# --- 3. The type of a vanilla icon ---
func _check_types(state: Dictionary) -> void:
    for icon_name in VANILLA_TYPES:
        check(_registry.type_of(icon_name) == VANILLA_TYPES[icon_name],
            "the type of %s is \"%s\", expected \"%s\""
                % [icon_name, _registry.type_of(icon_name), VANILLA_TYPES[icon_name]], state)
    # A tileset addresses its files by the bare name.
    check(_registry.type_of("bakery") == "buildings",
        "a bare name gives no type: \"%s\"" % _registry.type_of("bakery"), state)
    check(_registry.type_of("definitely_missing_icon") == "",
        "an unknown name gives a type", state)

# --- 4. The replacement table ---
func _check_table(state: Dictionary) -> void:
    var record: Dictionary = _tilesets.read_tileset(EXAMPLE)
    var table: Dictionary = _tilesets.build_overrides([record])
    check(table.size() == EXAMPLE_ICONS.size(),
        "the table has %d entries, expected %d" % [table.size(), EXAMPLE_ICONS.size()], state)
    for bare_name in EXAMPLE_ICONS:
        var path := str(table.get(bare_name, ""))
        check(path.begins_with(EXAMPLE),
            "the table does not take \"%s\" from the example: \"%s\"" % [bare_name, path], state)

    # Only the declared types are replaced: a building set that ships a coin icon and a
    # misnamed file replaces neither of them.
    var buildings_only := {
        "id": "synthetic_buildings",
        "name": "Synthetic",
        "description": "A set for the test.",
        "types": ["buildings"],
        "icons": {
            "bakery": EXAMPLE + "/icons/buildings/bakery.svg",
            "coin_stack": EXAMPLE + "/icons/misc/coin_stack.svg",
            "definitely_missing_icon": EXAMPLE + "/icons/misc/city.svg"
        },
        "error": ""
    }
    var narrowed: Dictionary = _tilesets.build_overrides([buildings_only])
    check(narrowed.size() == 1,
        "a set for buildings replaced %d icons, expected 1: %s" % [narrowed.size(), str(narrowed)], state)
    check(narrowed.has("bakery"), "a declared building icon was not replaced", state)
    check(not narrowed.has("coin_stack"),
        "an icon of an undeclared type was replaced", state)
    check(not narrowed.has("definitely_missing_icon"),
        "a file that names no vanilla icon got into the table", state)

# --- 5. One tileset per type ---
func _check_one_tileset_per_type(state: Dictionary) -> void:
    var first := {
        "id": "a_first",
        "name": "First",
        "description": "A set for the test.",
        "types": ["buildings"],
        "icons": {"bakery": "res://tilesets/_example/icons/buildings/bakery.svg"},
        "error": ""
    }
    var second := {
        "id": "b_second",
        "name": "Second",
        "description": "A set for the test.",
        "types": ["buildings", "misc"],
        "icons": {
            "bakery": "res://tilesets/_example/icons/buildings/market.svg",
            "coin_stack": "res://tilesets/_example/icons/misc/coin_stack.svg"
        },
        "error": ""
    }
    var table: Dictionary = _tilesets.build_overrides([first, second])
    check(str(table.get("bakery", "")) == str(second["icons"]["bakery"]),
        "the set that sorts last does not own the type whole: %s" % str(table.get("bakery", "")), state)
    check(table.has("coin_stack"), "the winner of a shared type lost its other types", state)

    # A broken manifest is skipped instead of being applied half-way.
    var broken := {
        "id": "c_broken",
        "name": "Broken",
        "description": "",
        "types": ["buildings"],
        "icons": {"bakery": "res://tilesets/_example/icons/buildings/market.svg"},
        "error": "The manifest has no \"description\" field."
    }
    var with_broken: Dictionary = _tilesets.build_overrides([broken])
    check(with_broken.is_empty(),
        "a tileset with an error got into the table: %s" % str(with_broken), state)

# --- 6. The choice of the player: one set per type ---
func _check_choices(state: Dictionary) -> void:
    var first := {
        "id": "a_first",
        "name": "First",
        "description": "A set for the test.",
        "types": ["buildings"],
        "icons": {"bakery": "res://tilesets/_example/icons/buildings/bakery.svg"},
        "error": ""
    }
    var second := {
        "id": "b_second",
        "name": "Second",
        "description": "A set for the test.",
        "types": ["buildings", "misc"],
        "icons": {
            "bakery": "res://tilesets/_example/icons/buildings/market.svg",
            "coin_stack": "res://tilesets/_example/icons/misc/coin_stack.svg"
        },
        "error": ""
    }
    var records := [first, second]

    # Nothing chosen: the folder rule answers for every type.
    var auto: Dictionary = _tilesets.resolve(records)
    check(str(auto.get("buildings", {}).get("id", "")) == "b_second",
        "the folder rule does not give the type to the last set", state)
    check(str(auto.get("misc", {}).get("id", "")) == "b_second",
        "the folder rule does not give the second type to the last set", state)

    # A chosen set wins over the folder rule, and only for its own type.
    var chosen: Dictionary = _tilesets.resolve(records, {"buildings": "a_first"})
    check(str(chosen.get("buildings", {}).get("id", "")) == "a_first",
        "the chosen set does not draw its type", state)
    check(str(chosen.get("misc", {}).get("id", "")) == "b_second",
        "a choice for one type changed another type", state)

    # The vanilla icons for a type: the type has no owner at all.
    var vanilla: Dictionary = _tilesets.resolve(records, {"buildings": ""})
    check(not vanilla.has("buildings"), "the vanilla icons still have an owner", state)
    var table: Dictionary = _tilesets.build_overrides(records, {"buildings": ""})
    check(not table.has("bakery"), "a type on the vanilla icons was replaced", state)
    check(table.has("coin_stack"), "a type left alone lost its set", state)

    # A chosen set that is gone: the folder rule answers, the type is not left empty.
    var missing: Dictionary = _tilesets.resolve(records, {"buildings": "deleted_set"})
    check(str(missing.get("buildings", {}).get("id", "")) == "b_second",
        "a missing set does not fall back to the folder rule", state)

    # A set chosen for a type it is not drawn for is not applied to it.
    var wrong: Dictionary = _tilesets.resolve(records, {"misc": "a_first"})
    check(str(wrong.get("misc", {}).get("id", "")) == "b_second",
        "a set that does not declare the type draws it", state)

    # The stored choice is read at scan time.
    var config := ConfigFile.new()
    config.set_value("interface", "tilesets", {"buildings": "a_first", "misc": ""})
    config.save("user://settings.cfg")
    _tilesets.scan()
    check(str(_tilesets.choices.get("buildings", "")) == "a_first",
        "the stored choice is not read: %s" % str(_tilesets.choices), state)
    check(_tilesets.choices.get("misc", "x") == "",
        "the stored vanilla choice is not read: %s" % str(_tilesets.choices), state)
    check(not _tilesets.choices.has("resources"),
        "a type that was not chosen got into the choices", state)
    DirAccess.remove_absolute("user://settings.cfg")
    _tilesets.scan()
    check(_tilesets.choices.is_empty(), "the choices were not dropped with the settings", state)

# --- 7. Installing a table ---
func _check_installing(state: Dictionary) -> void:
    var vanilla_path = _registry.icon_path("bakery.png")
    var vanilla_texture = _registry.get_texture("bakery.png")
    var replacement := EXAMPLE + "/icons/buildings/bakery.svg"

    # The interface holds textures of its own: it is told that they are stale.
    var notified := [0]
    var counter := func() -> void: notified[0] += 1
    _registry.overrides_changed.connect(counter)
    _registry.set_overrides({"bakery": replacement})
    check(notified[0] == 1, "the interface is not told that the icons changed", state)
    check(_registry.icon_path("bakery.png") == replacement,
        "icon_path does not follow the installed table: %s" % _registry.icon_path("bakery.png"), state)
    check(_registry.icon_path("bakery") == replacement,
        "icon_path does not follow the installed table by a bare name", state)
    # An icon the table does not name keeps its vanilla file.
    check(_registry.icon_path("market.png") == str(_registry.paths["market.png"]),
        "an icon the table does not name changed its file", state)
    var replaced_texture = _registry.get_texture("bakery.png")
    check(replaced_texture is Texture2D,
        "the replacement texture was not loaded (is the SVG imported?)", state)
    check(replaced_texture != vanilla_texture,
        "the replacement texture is the vanilla one (the cache was not dropped)", state)
    check(_registry.type_of("bakery.png") == "buildings",
        "the type of an icon changed with the table", state)

    _registry.set_overrides({})
    check(notified[0] == 2, "clearing the table does not notify the interface", state)
    check(_registry.icon_path("bakery.png") == vanilla_path,
        "the vanilla path did not come back after the table was cleared", state)
    check(_registry.get_texture("bakery.png") == vanilla_texture,
        "the vanilla texture did not come back after the table was cleared", state)
    _registry.overrides_changed.disconnect(counter)

# --- 8. The example is healthy ---
func _check_example_health(state: Dictionary) -> void:
    var record: Dictionary = _tilesets.read_tileset(EXAMPLE)
    var unknown: Array = []
    for bare_name in record.get("icons", {}):
        if _registry.type_of(bare_name).is_empty():
            unknown.append(bare_name)
    check(unknown.is_empty(),
        "the example ships files that name no vanilla icon (a typo?): %s" % str(unknown), state)
    # Every image of the example must belong to a type the example declares.
    var declared: Array = record.get("types", [])
    for bare_name in record.get("icons", {}):
        var type_name: String = _registry.type_of(bare_name)
        if type_name.is_empty():
            continue
        check(declared.has(type_name),
            "the example ships \"%s\" of type \"%s\" but does not declare it" % [bare_name, type_name], state)

func _finish(state: Dictionary) -> void:
    # The real set of the installed tilesets, as the game has it.
    if _tilesets != null:
        _tilesets.apply()
    if state["failed"]:
        print("TILESETS TEST FAILED")
        quit(1)
    else:
        print("TILESETS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
