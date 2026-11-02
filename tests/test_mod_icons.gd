# Headless test of the icons a mod ships for its own entities:
#   godot --headless --path . --script res://tests/test_mod_icons.gd
#
# A mod draws the entities it adds with its own pictures: <mod folder>/icons, laid out like
# res://icons (a subfolder per type, the root of the folder itself for misc). GameData hands
# the folders of the running mods to IconRegistry when it loads the data, so the registry is
# driven here directly — no game data is loaded and nothing in res:// is touched.
#
# The probe mods are built in user:// (that is where a player puts a mod) and removed at the
# end. They are raw files the engine never imported: this is what the loading path of the
# registry has to cope with.
#
# Checked:
#   1. An icon of a mod is indexed by its file name and answers with its own path.
#   2. Its type comes from the folder under icons/ — an icon in the root of icons/ is misc,
#      and the names of the types of the manifest work as folders as well (products/).
#   3. get_texture decodes a raw PNG and a raw SVG (an imported resource cannot be made of
#      them), and puts the texture into the ResourceLoader cache: the [img=<path>] tag of the
#      tooltips finds it there.
#   4. A mod icon wins over a vanilla one of the same name, and the later mod wins over the
#      earlier one.
#   5. The set of mods is the save's: without the mod the icon is gone and the vanilla
#      picture is back.
#   6. A tileset draws the vanilla game only: a file that names an icon of a mod replaces
#      nothing, and the vanilla view of the types does not move with the mods.
extends SceneTree

# Hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const PROBE_A := "user://_mod_icons_a"
const PROBE_B := "user://_mod_icons_b"
# The sizes the probe pictures are drawn with: a texture of another size means another file.
const HOUSE_SIZE := Vector2i(32, 24)
const HOUSE_SIZE_B := Vector2i(16, 16)
const GRAIN_SIZE := Vector2i(40, 24)
const MISC_SIZE := Vector2i(10, 10)
# A vanilla icon the probe mods redraw by name.
const VANILLA_ICON := "bakery.png"
# What a synthetic tileset draws the mod icon with.
const TILESET_ICON := "res://icons/buildings/bakery.png"

var _registry = null
var _tilesets = null
# The set of the tilesets the game really has, to put it back at the end.
var _installed: Array = []
var _changed := 0

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    # The autoloads connect to each other on their first frame (TilesetManager listens to the
    # index of the icons), so the test starts after it.
    await process_frame
    _registry = get_root().get_node("IconRegistry")
    _tilesets = get_root().get_node("TilesetManager")
    check(_registry != null and _tilesets != null,
        "the IconRegistry and TilesetManager autoloads are registered", state)
    if _registry == null or _tilesets == null:
        _finish(state)
        return
    # The real set of the installed tilesets, to put it back at the end.
    _installed = _tilesets.tilesets.duplicate()
    # The test works from the icons as the mods and the game draw them: a set the author has
    # put into res://tilesets must not decide what the checks see.
    _registry.set_overrides({})
    _registry.set_mod_dirs([])
    _registry.overrides_changed.connect(_on_icons_changed)

    check(_registry.has(VANILLA_ICON), "the vanilla icon %s is not indexed" % VANILLA_ICON, state)
    var vanilla_path: String = str(_registry.paths[VANILLA_ICON])
    check(not _registry.has("probe_house.png"),
        "an icon nobody ships is indexed before any mod is set", state)

    # --- The probe mods ---
    _make_probe_a()
    _make_probe_b()

    # --- 1. The icons of a mod ---
    var changed_before := _changed
    _registry.set_mod_dirs([PROBE_A])
    check(_changed > changed_before,
        "the change of the mod set is not announced to the interface", state)

    var house_path := PROBE_A.path_join("icons/buildings/probe_house.png")
    check(_registry.has("probe_house.png"), "the icon of the mod is not indexed", state)
    check(_registry.path_of("probe_house.png") == house_path,
        "the icon of the mod points elsewhere: %s" % _registry.path_of("probe_house.png"), state)
    check(_registry.type_of("probe_house.png") == "buildings",
        "the type of a mod icon does not come from its folder: \"%s\""
            % _registry.type_of("probe_house.png"), state)
    # A tooltip asks for the PATH only and puts it into a [img=…] tag: the path has to be
    # loadable even though nothing has asked for the texture before.
    check(_registry.icon_path("probe_house.png") == house_path,
        "icon_path does not answer with the file of the mod", state)
    check(ResourceLoader.load(house_path) is Texture2D,
        "the path of a mod icon cannot be loaded by the [img=…] tag", state)

    # --- 3. A raw PNG and a raw SVG ---
    var house_tex: Texture2D = _registry.get_texture("probe_house.png")
    check(house_tex != null, "the raw PNG of the mod is not loaded", state)
    if house_tex != null:
        check(house_tex.get_size() == Vector2(HOUSE_SIZE),
            "the raw PNG is decoded with the wrong size: %s" % house_tex.get_size(), state)
        check(ResourceLoader.load(house_path) == house_tex,
            "the texture is not in the ResourceLoader cache: [img=<path>] would not find it",
            state)

    # The data names the file exactly, extension included: the picture of the mod is an SVG,
    # so the icon field says "probe_grain.svg".
    var grain_tex: Texture2D = _registry.get_texture("probe_grain.svg")
    check(grain_tex != null, "the raw SVG of the mod is not loaded", state)
    if grain_tex != null:
        check(grain_tex.get_size() == Vector2(GRAIN_SIZE),
            "the raw SVG is rasterised with the wrong size: %s" % grain_tex.get_size(), state)
    check(_registry.type_of("probe_grain.svg") == "resources",
        "the type of the SVG is not resources: \"%s\"" % _registry.type_of("probe_grain.svg"),
        state)

    var misc_tex: Texture2D = _registry.get_texture("probe_misc.png")
    check(misc_tex != null and misc_tex.get_size() == Vector2(MISC_SIZE),
        "an icon in the root of the icons folder of a mod is not loaded", state)
    check(_registry.type_of("probe_misc.png") == "misc",
        "an icon in the root of the icons folder of a mod is not misc: \"%s\""
            % _registry.type_of("probe_misc.png"), state)

    # --- 4. A mod may redraw a vanilla icon, and the later mod wins ---
    check(_registry.path_of(VANILLA_ICON) == PROBE_A.path_join("icons/buildings/bakery.png"),
        "a mod does not win over the vanilla icon of the same name: %s"
            % _registry.path_of(VANILLA_ICON), state)

    _registry.set_mod_dirs([PROBE_A, PROBE_B])
    var second_path := PROBE_B.path_join("icons/buildings/probe_house.png")
    check(_registry.path_of("probe_house.png") == second_path,
        "the later mod does not win: %s" % _registry.path_of("probe_house.png"), state)
    var second_tex: Texture2D = _registry.get_texture("probe_house.png")
    check(second_tex != null and second_tex.get_size() == Vector2(HOUSE_SIZE_B),
        "the texture of the winning mod is not the one loaded", state)

    # --- 5. The names of the types of the manifest work as folders ---
    # A mod lays out its icons the way its data reads: a product is a resource record, so
    # icons/products/ is the same type as icons/resources/.
    check(_registry.type_of("probe_glaze.png") == "resources",
        "a folder named after a type of the manifest gives no type: \"%s\""
            % _registry.type_of("probe_glaze.png"), state)

    # --- 6. The set of mods belongs to the save ---
    _registry.set_mod_dirs([])
    check(not _registry.has("probe_house.png"),
        "the icon of a mod outlives the mod set", state)
    check(_registry.path_of(VANILLA_ICON) == vanilla_path,
        "the vanilla icon did not come back: %s" % _registry.path_of(VANILLA_ICON), state)
    check(_registry.has("hand_mill.png"), "the vanilla icons are gone after the mod set", state)

    # --- 7. A tileset draws the vanilla game, not the mods of the player ---
    # A mod brings its data and its pictures together; a set addresses the game itself. So a
    # file named after an icon a mod adds replaces nothing, whether the mod is on or off, and
    # the type of a vanilla name does not move when a mod shadows it.
    _tilesets.tilesets = [_synthetic_tileset()]
    _tilesets.choices = {}
    _registry.set_mod_dirs([PROBE_A])
    _tilesets.apply()
    check(not _registry.overrides.has("probe_house"),
        "a tileset replaced the icon of a mod: %s" % str(_registry.overrides), state)
    check(_registry.path_of("probe_house.png") == house_path,
        "the icon of the mod is not drawn by the mod: %s"
            % _registry.path_of("probe_house.png"), state)
    # The vanilla view of the types: the mod redraws bakery.png, but for a set the name is
    # still a building icon of the game.
    check(_registry.vanilla_type_of(VANILLA_ICON) == "buildings",
        "the vanilla view of a type moved with the mod: \"%s\""
            % _registry.vanilla_type_of(VANILLA_ICON), state)
    check(_registry.type_of(VANILLA_ICON) == "buildings",
        "the mod icon changed the type of the vanilla name: \"%s\""
            % _registry.type_of(VANILLA_ICON), state)
    _registry.set_mod_dirs([])
    _tilesets.tilesets = _installed
    _tilesets.apply()

    _remove_tree(PROBE_A)
    _remove_tree(PROBE_B)
    _finish(state)

# A tileset that redraws the building the probe mod adds.
func _synthetic_tileset() -> Dictionary:
    return {
        "id": "probe_tileset",
        "name": "Probe",
        "description": "A set for the test.",
        "types": ["buildings"],
        "icons": {"probe_house": TILESET_ICON},
        "error": ""
    }

func _on_icons_changed() -> void:
    _changed += 1

# A mod that draws a building, a resource (as SVG), a misc icon and redraws a vanilla one.
func _make_probe_a() -> void:
    _remove_tree(PROBE_A)
    _save_png(PROBE_A.path_join("icons/buildings/probe_house.png"), HOUSE_SIZE, Color.RED)
    _save_png(PROBE_A.path_join("icons/buildings/" + VANILLA_ICON), Vector2i(8, 8), Color.BLUE)
    _save_png(PROBE_A.path_join("icons/probe_misc.png"), MISC_SIZE, Color.YELLOW)
    # A product is a resource record, so the folder may say "products" as well.
    _save_png(PROBE_A.path_join("icons/products/probe_glaze.png"), MISC_SIZE, Color.WHITE)
    var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' \
        % [GRAIN_SIZE.x, GRAIN_SIZE.y] \
        + '<rect width="100%" height="100%" fill="#3a7"/></svg>'
    _save_text(PROBE_A.path_join("icons/resources/probe_grain.svg"), svg)

# A second mod that draws the same building: the later one has to win.
func _make_probe_b() -> void:
    _remove_tree(PROBE_B)
    _save_png(PROBE_B.path_join("icons/buildings/probe_house.png"), HOUSE_SIZE_B, Color.GREEN)

func _save_png(path: String, size: Vector2i, color: Color) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
    image.fill(color)
    image.save_png(path)

func _save_text(path: String, text: String) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(text)
    file.close()

# A folder of the probe is removed with everything inside it: user:// must not keep the
# pictures of a test.
func _remove_tree(path: String) -> void:
    var dir := DirAccess.open(path)
    if dir == null:
        return
    for name in dir.get_files():
        dir.remove(name)
    for name in dir.get_directories():
        _remove_tree(path.path_join(name))
    DirAccess.remove_absolute(path)

func _finish(state: Dictionary) -> void:
    if _registry != null:
        _registry.set_mod_dirs([])
    if _tilesets != null:
        # The real table of the installed tilesets goes back into the registry.
        _tilesets.tilesets = _installed
        _tilesets.apply()
    if state["failed"]:
        print("MOD ICONS TEST FAILED")
        quit(1)
    else:
        print("MOD ICONS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
