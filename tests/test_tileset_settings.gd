# Headless test of the choice of a tileset in the settings window:
#   godot --headless --path . --script res://tests/test_tileset_settings.gd
#
# The settings window is instantiated for real, so the rows are the ones the player sees.
# The test installs the shipped example into the manager by hand (the folder is named
# "_example", which the scan skips), so no file on disk is created or removed.
#
# Checked:
#   1. The section is built: one row per type of icons, and each row is a label and a
#      dropdown that offers the vanilla icons and every set drawn for that type.
#   2. A type nobody has chosen shows the set the folder rule gave it — an installed set
#      works without a visit to the settings.
#   3. Choosing the vanilla icons puts the original picture back and stores the choice.
#   4. Choosing a set applies it at once: IconRegistry answers with the tileset file, which
#      is what makes the whole interface follow.
#   5. The choice survives a reopen of the window, and a set that is not there any more
#      falls back to the folder rule instead of leaving the type empty.
#   6. With no tileset installed the section is still there: every type has a row, the
#      dropdown of the row holds the vanilla icons alone and is not clickable.
extends SceneTree

# Hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const SETTINGS_SCENE := "res://scenes/settings_menu.tscn"
const EXAMPLE := "res://tilesets/_example"
const EXAMPLE_ID := "_example"
const EXAMPLE_NAME := "Placeholder Set"
# A building icon of the example: the vanilla file and the replacement.
const ICON := "bakery.png"
# The order of the rows the section builds: the types of icons as the manager lists them.
const TYPES := ["resources", "buildings", "technologies", "terrains", "improvements",
    "special_actions", "misc"]

var _tilesets = null
var _registry = null
# The hint the scene itself carries, i.e. the one about an installed set.
var _scene_hint := ""

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    _tilesets = get_root().get_node("TilesetManager")
    _registry = get_root().get_node("IconRegistry")
    check(_tilesets != null and _registry != null, "the autoloads are registered", state)
    if _tilesets == null or _registry == null:
        _finish(state)
        return

    # A known starting point: no choice stored, no set installed. The file is removed rather
    # than emptied — an empty one is a settings file that answers nothing, and the autoloads
    # read their keys from it before this test starts.
    if FileAccess.file_exists("user://settings.cfg"):
        DirAccess.remove_absolute("user://settings.cfg")
    _tilesets.tilesets = []
    _tilesets.choices = {}
    _tilesets.apply()

    # --- 1. The section of the settings ---
    # The hint is read from a node that never entered the tree: _ready() has not run on it,
    # so the text is the one the scene was saved with.
    var bare = load(SETTINGS_SCENE).instantiate()
    _scene_hint = str(bare.find_child("TilesetHint", true, false).text)
    bare.free()
    var settings = load(SETTINGS_SCENE).instantiate()
    get_root().add_child(settings)
    await process_frame
    var section = settings.find_child("TilesetSection", true, false)
    var grid = settings.find_child("TilesetGrid", true, false)
    check(section != null and grid != null, "the tileset section of the scene is found", state)
    if section == null or grid == null:
        settings.queue_free()
        _finish(state)
        return

    check(section.visible, "with no tileset installed the section is not shown", state)
    check(grid.get_child_count() == TYPES.size() * 2,
        "with no tileset installed the grid does not hold a row per type (%d children)"
            % grid.get_child_count(), state)
    var alone = _dropdown(settings, "buildings", state)
    check(alone != null and alone.item_count == 1 and alone.disabled,
        "the dropdown of a type no set is drawn for is not a disabled list of the vanilla icons",
        state)

    # The shipped example, installed as the scan would install a live one.
    var record: Dictionary = _tilesets.read_tileset(EXAMPLE)
    check(not record.is_empty() and str(record["error"]).is_empty(),
        "the example is readable: %s" % str(record.get("error", "")), state)
    _tilesets.tilesets = [record]
    _tilesets.apply()
    settings._setup_tileset_options()

    check(section.visible, "with a tileset installed the section is not shown", state)
    check(grid.get_child_count() == TYPES.size() * 2,
        "the grid has a label and a dropdown per type (%d children for %d types)"
            % [grid.get_child_count(), TYPES.size()], state)
    var hint: Label = settings.find_child("TilesetHint", true, false)
    check(hint != null and hint.text == _scene_hint,
        "the hint of the scene is not back with a set installed: \"%s\""
            % str(hint.text if hint else ""), state)

    var buildings = _dropdown(settings, "buildings", state)
    check(buildings != null, "the row of the buildings is found", state)
    if buildings == null:
        settings.queue_free()
        _finish(state)
        return
    check(buildings.item_count == 2,
        "the buildings dropdown offers the vanilla icons and the set (got %d items)"
            % buildings.item_count, state)
    check(not buildings.disabled,
        "the dropdown of a type a set is drawn for is still greyed out", state)
    check(buildings.get_item_text(0) == "Original icons",
        "the first item is the vanilla icons: \"%s\"" % buildings.get_item_text(0), state)
    check(buildings.get_item_text(1) == EXAMPLE_NAME,
        "the second item is the name of the set: \"%s\"" % buildings.get_item_text(1), state)

    # --- 2. An installed set works without a choice ---
    check(_tilesets.get_choice("buildings") == EXAMPLE_ID,
        "an unchosen type does not follow the folder rule: \"%s\""
            % _tilesets.get_choice("buildings"), state)
    check(buildings.selected == 1,
        "the dropdown does not show the applied set (selected %d)" % buildings.selected, state)
    check(_registry.icon_path(ICON).begins_with(EXAMPLE),
        "the applied set does not replace the icon: %s" % _registry.icon_path(ICON), state)

    # --- 3. The vanilla icons back ---
    buildings.select(0)
    buildings.item_selected.emit(0)
    check(_tilesets.get_choice("buildings").is_empty(),
        "choosing the vanilla icons did not clear the choice: \"%s\""
            % _tilesets.get_choice("buildings"), state)
    check(_registry.icon_path(ICON) == str(_registry.paths[ICON]),
        "the vanilla icon did not come back: %s" % _registry.icon_path(ICON), state)
    check(_stored().get("buildings", "x") == "",
        "the vanilla choice is not stored: %s" % str(_stored()), state)
    # The other types are untouched: a choice is per type.
    check(_tilesets.get_choice("misc") == EXAMPLE_ID,
        "a choice for one type changed another type", state)

    # --- 4. A set chosen explicitly ---
    buildings.select(1)
    buildings.item_selected.emit(1)
    check(_tilesets.get_choice("buildings") == EXAMPLE_ID,
        "the chosen set is not applied", state)
    check(_registry.icon_path(ICON).begins_with(EXAMPLE),
        "the chosen set does not replace the icon: %s" % _registry.icon_path(ICON), state)
    check(_stored().get("buildings", "") == EXAMPLE_ID,
        "the choice is not stored: %s" % str(_stored()), state)

    # --- 5. The choice survives a reopen ---
    settings.queue_free()
    await process_frame
    var settings2 = load(SETTINGS_SCENE).instantiate()
    get_root().add_child(settings2)
    await process_frame
    var buildings2 = _dropdown(settings2, "buildings", state)
    check(buildings2 != null and buildings2.selected == 1,
        "the reopened window does not show the stored choice", state)
    settings2.queue_free()
    await process_frame

    # A set that is gone: the type falls back to the folder rule instead of going empty.
    _tilesets.choices = {"buildings": "deleted_set"}
    check(_tilesets.get_choice("buildings") == EXAMPLE_ID,
        "a missing set does not fall back to the folder rule: \"%s\""
            % _tilesets.get_choice("buildings"), state)

    # --- 6. Nothing installed ---
    _tilesets.tilesets = []
    _tilesets.choices = {}
    _tilesets.apply()
    var settings3 = load(SETTINGS_SCENE).instantiate()
    get_root().add_child(settings3)
    await process_frame
    var section3 = settings3.find_child("TilesetSection", true, false)
    var grid3 = settings3.find_child("TilesetGrid", true, false)
    check(section3 != null and section3.visible,
        "the section is not shown again with no tileset installed", state)
    check(grid3 != null and grid3.get_child_count() == TYPES.size() * 2,
        "the rows are not built with no tileset installed", state)
    var buildings3 = _dropdown(settings3, "buildings", state)
    check(buildings3 != null and buildings3.item_count == 1 and buildings3.disabled,
        "the vanilla icons alone do not leave the row unclickable", state)
    var hint3: Label = settings3.find_child("TilesetHint", true, false)
    check(hint3 != null and not hint3.text.is_empty() and hint3.text != _scene_hint,
        "the hint of an empty folder is the hint of an installed set: \"%s\""
            % str(hint3.text if hint3 else ""), state)
    settings3.queue_free()
    await process_frame

    _finish(state)

# The dropdown of one type: the row is label + dropdown, so the dropdown is the second child
# of the pair the grid built.
func _dropdown(settings, type_name: String, state: Dictionary):
    var grid: GridContainer = settings.find_child("TilesetGrid", true, false)
    if grid == null:
        check(false, "the grid is gone", state)
        return null
    var row := TYPES.find(type_name)
    if row < 0:
        check(false, "the type \"%s\" has no row" % type_name, state)
        return null
    var option = grid.get_child(row * 2 + 1)
    check(option is OptionButton, "the second child of a row is not a dropdown", state)
    return option

func _stored() -> Dictionary:
    var config := ConfigFile.new()
    if config.load("user://settings.cfg") != OK:
        return {}
    var stored = config.get_value("interface", "tilesets", {})
    return stored if stored is Dictionary else {}

func _finish(state: Dictionary) -> void:
    # The game as the test found it: no set installed, no choice stored.
    if _tilesets != null:
        _tilesets.tilesets = []
        _tilesets.choices = {}
        _tilesets.apply()
    if state["failed"]:
        print("TILESET SETTINGS TEST FAILED")
        quit(1)
    else:
        print("TILESET SETTINGS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
