extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The picture of the new game window is the world itself: the preview runs the generator's stages
# from the seed it shows, and the world runs them again from that seed (CityData.world_seed).
# Here the world's order is run in full — the covers and the resources included — and every hex is
# compared with the hexes the picture is built from. The terrain, the zone and the belt must agree,
# so the coast, the relief and the belts the player saw are the ones the player gets.
#
#   godot --headless --path . --script res://tests/test_preview_world.gd

const SEED := 20261111

var _gdata = null
var _cdata = null
var _preview = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    call_deferred("_run")

func _run() -> void:
    var state := {"failed": false}
    await process_frame
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _preview = load("res://scripts/world_preview.gd")

    if WATCHDOG.wants_case("coasts_and_islands"):
        _test_world_agrees(state, 60, _sea("edge", [1, 2], true), "mild")
    if WATCHDOG.wants_case("four_edges"):
        _test_world_agrees(state, 40, _sea("edge", [4, 4], true), "tropical")
    if WATCHDOG.wants_case("noise_sea"):
        _test_world_agrees(state, 40, _sea("noise", [1, 4], false), "random")
    if WATCHDOG.wants_case("dry_world"):
        _test_world_agrees(state, 30, _sea("none", [0, 0], false), "cold")

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("PREVIEW WORLD TEST FAILED")
        quit(1)
    else:
        print("PREVIEW WORLD TEST OK")
        quit(0)

# A sea configuration as the menu hands it over: the edges are already rolled from the seed, so
# the world reads the same coast without rolling it again.
func _sea(mode: String, sides: Array, islands: bool) -> Dictionary:
    var cfg: Dictionary = _cdata.DEFAULT_SEA.duplicate(true)
    cfg["mode"] = mode
    cfg["sides"] = sides
    cfg["edge_islands_enabled"] = islands
    var sea_manager = load("res://scripts/sea_manager.gd")
    cfg["sides"] = sea_manager.resolve_sides(cfg, SEED)
    return cfg

# The world's own order, in full: generate_map rolls the covers and the resources the picture
# skips, and lays the exit corridor last of all.
func _world_tiles(size: int, sea: Dictionary, climate: String) -> Array:
    var saved_sea: Dictionary = _cdata.world_sea
    var saved_climate: String = _cdata.world_climate
    _cdata.world_sea = sea.duplicate(true)
    _cdata.world_climate = climate
    var generator = load("res://scripts/map_generator.gd").new()
    seed(SEED)
    var counts = generator.make_terrain_counts(size, size)
    var tiles: Array = generator.generate_map(size, size, int(size / 2.0), int(size / 2.0),
            _gdata.raw_resources, counts)
    generator.free()
    _cdata.world_sea = saved_sea
    _cdata.world_climate = saved_climate
    return tiles

func _test_world_agrees(state: Dictionary, size: int, sea: Dictionary, climate: String) -> void:
    var world := _world_tiles(size, sea, climate)
    var pictured: Array = _preview.relief_tiles(size, sea, SEED, climate)
    var differences: Array[String] = []
    for row in range(size):
        for col in range(size):
            for field in ["terrain", "climate", "temperature"]:
                var w := str(world[row][col].get(field, ""))
                var p := str(pictured[row][col].get(field, ""))
                if w != p and differences.size() < 5:
                    differences.append("%s (%d,%d): the world has %s, the picture %s"
                            % [field, row, col, w, p])
    check(differences.is_empty(),
            "the %s sea in the %s climate is the world hex for hex (%s)"
                    % [str(sea["mode"]), climate, "; ".join(differences)], state)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)