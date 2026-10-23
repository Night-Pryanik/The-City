extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The climate is checked on a full-size map: the belts, the moisture and the cleanup all work on
# fractions of the map height, so a small map would exercise only the edge cases.
const ROWS := 60
const COLS := 60
const SEED := 20261023

# The order of the temperature belts from the pole to the equator. The generator never inverts it,
# therefore the difference between two neighbouring hexes can only be 0 or 1.
const TEMPERATURES := ["cold", "mild", "hot"]

var _gdata = null
var _tiles: Array = []
var _generated := false

func _initialize() -> void:
    WATCHDOG.arm(self)
    call_deferred("_run")

func _run() -> void:
    var state := {"failed": false}
    await process_frame
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")

    if WATCHDOG.wants_case("all_six_biomes"):
        _test_all_six_biomes(state)
    if WATCHDOG.wants_case("neighbouring_belts"):
        _test_neighbouring_belts(state)
    if WATCHDOG.wants_case("min_size"):
        _test_min_size(state)
    if WATCHDOG.wants_case("cold_edges"):
        _test_cold_edges(state)
    if WATCHDOG.wants_case("deserts_hot_dry"):
        _test_deserts_hot_dry(state)
    if WATCHDOG.wants_case("covers_from_biome"):
        _test_covers_from_biome(state)
    if WATCHDOG.wants_case("city_has_biome"):
        _test_city_has_biome(state)
    if WATCHDOG.wants_case("tooltip_line"):
        _test_tooltip_line(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("BIOMES TEST FAILED")
        quit(1)
    else:
        print("BIOMES TEST OK")
        quit(0)

# --- the map under test ------------------------------------------------------

func _generate() -> void:
    if _generated:
        return
    _generated = true
    var generator = load("res://scripts/map_generator.gd").new()
    seed(SEED)
    var counts = generator.make_terrain_counts(ROWS, COLS)
    _tiles = generator.generate_map(ROWS, COLS, int(ROWS / 2.0), int(COLS / 2.0),
            _gdata.raw_resources, counts)
    generator.free()

func _biome_id(row: int, col: int) -> String:
    return str(_tiles[row][col].get("biome", ""))

func _biome(row: int, col: int) -> Dictionary:
    return _gdata.biomes.get(_biome_id(row, col), {})

func _temperature_index(row: int, col: int) -> int:
    return TEMPERATURES.find(str(_biome(row, col).get("temperature", "")))

func _is_water(row: int, col: int) -> bool:
    var terrain_id: String = str(_tiles[row][col].get("terrain", "plain"))
    var terrain: Dictionary = _gdata.terrains.get(terrain_id, {})
    return int(terrain.get("move_cost", 1)) >= 999

func _has_biome(row: int, col: int) -> bool:
    return _biome_id(row, col) != "" and _gdata.biomes.has(_biome_id(row, col))

# --- the checks --------------------------------------------------------------

func _test_all_six_biomes(state: Dictionary) -> void:
    _generate()
    var seen := {}
    for r in range(ROWS):
        for c in range(COLS):
            if _has_biome(r, c):
                seen[_biome_id(r, c)] = true
    for biome_id in _gdata.biomes.keys():
        check(seen.has(biome_id), "the biome %s never appears on the map" % biome_id, state)

func _test_neighbouring_belts(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            if not _has_biome(r, c):
                continue
            var here := _temperature_index(r, c)
            for neighbour in HexUtils.get_neighbors_odd_r(r, c, ROWS, COLS):
                if not _has_biome(neighbour.row, neighbour.col):
                    continue
                var there := _temperature_index(neighbour.row, neighbour.col)
                check(absi(here - there) <= 1,
                        "two belts meet at (%d,%d)-(%d,%d): %s and %s" % [r, c, neighbour.row,
                        neighbour.col, _biome_id(r, c), _biome_id(neighbour.row, neighbour.col)], state)

# The biome patches are large regions: a patch of land smaller than min_biome_size is dissolved
# into the biome around it. An island with no land neighbours has nothing to merge with and stays.
func _test_min_size(state: Dictionary) -> void:
    _generate()
    var min_size := int(_gdata.map_config.get("climate", {}).get("min_biome_size", 3))
    var visited := {}
    for r in range(ROWS):
        for c in range(COLS):
            if visited.has(Vector2i(r, c)) or not _has_biome(r, c):
                continue
            var biome_id := _biome_id(r, c)
            var cells: Array = []
            var stack: Array = [Vector2i(r, c)]
            visited[Vector2i(r, c)] = true
            var touches_land := false
            while not stack.is_empty():
                var cell: Vector2i = stack.pop_back()
                cells.append(cell)
                for neighbour in HexUtils.get_neighbors_odd_r(cell.x, cell.y, ROWS, COLS):
                    var key := Vector2i(neighbour.row, neighbour.col)
                    if not _has_biome(neighbour.row, neighbour.col):
                        continue
                    if _biome_id(neighbour.row, neighbour.col) != biome_id:
                        touches_land = true
                        continue
                    if visited.has(key):
                        continue
                    visited[key] = true
                    stack.append(key)
            if not touches_land:
                continue
            check(cells.size() >= min_size,
                    "the biome %s has a patch of %d hexes at (%d,%d)" % [biome_id, cells.size(), r, c],
                    state)

# The map keeps a polar edge on both sides: the belts never reach the very top or the very bottom.
func _test_cold_edges(state: Dictionary) -> void:
    _generate()
    var cold := TEMPERATURES.find("cold")
    for r in range(3):
        for c in range(COLS):
            if not _has_biome(r, c):
                continue
            check(_temperature_index(r, c) == cold,
                    "the northern edge is not cold at (%d,%d): %s" % [r, c, _biome_id(r, c)], state)
    for r in range(ROWS - 3, ROWS):
        for c in range(COLS):
            if not _has_biome(r, c):
                continue
            check(_temperature_index(r, c) == cold,
                    "the southern edge is not cold at (%d,%d): %s" % [r, c, _biome_id(r, c)], state)

func _test_deserts_hot_dry(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            var terrain_id := str(_tiles[r][c].get("terrain", ""))
            if terrain_id != "sandy_desert" and terrain_id != "rocky_desert":
                continue
            var biome := _biome(r, c)
            check(str(biome.get("temperature", "")) == "hot" and str(biome.get("humidity", "")) == "dry",
                    "a desert outside the hot dry belt at (%d,%d): %s" % [r, c, _biome_id(r, c)], state)

# The vegetation of the plains and hills belongs to the biome: the whole region shares one pool.
func _test_covers_from_biome(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            var terrain_id := str(_tiles[r][c].get("terrain", ""))
            if terrain_id != "plain" and terrain_id != "hill":
                continue
            if not _has_biome(r, c):
                continue
            var pool: Dictionary = _biome(r, c).get("cover_chance", {})
            var cover_id := str(_tiles[r][c].get("cover", "none"))
            check(pool.has(cover_id),
                    "the cover %s is not in the pool of %s at (%d,%d)" % [cover_id, _biome_id(r, c), r, c],
                    state)

func _test_city_has_biome(state: Dictionary) -> void:
    _generate()
    var row := int(ROWS / 2.0)
    var col := int(COLS / 2.0)
    check(_has_biome(row, col), "the city hex has no biome", state)

# The biome reaches the player: the tooltip names it next to the terrain.
func _test_tooltip_line(state: Dictionary) -> void:
    _generate()
    var label := RichTextLabel.new()
    var container := VBoxContainer.new()
    get_root().add_child(label)
    get_root().add_child(container)
    var tooltip = load("res://scripts/map_tooltip.gd").new(label, container, null, null)

    var found := Vector2i(-1, -1)
    for r in range(ROWS):
        for c in range(COLS):
            if _has_biome(r, c) and _tiles[r][c].get("improvement", null) == null:
                found = Vector2i(r, c)
                break
        if found.x >= 0:
            break
    check(found.x >= 0, "no land hex to build the tooltip for", state)
    if found.x < 0:
        label.queue_free()
        container.queue_free()
        return

    tooltip.update_tooltip_text(found.x, found.y, _tiles, int(ROWS / 2.0), int(COLS / 2.0))
    var text: String = label.text
    var biome_name := str(_biome(found.x, found.y).get("name", ""))
    check(text.contains("Biome: "), "the tooltip does not name the biome: %s" % text, state)
    check(text.contains(biome_name), "the tooltip does not name the biome %s: %s" % [biome_name, text], state)

    label.queue_free()
    container.queue_free()

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
