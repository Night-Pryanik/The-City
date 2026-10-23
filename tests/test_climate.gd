extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The climate is checked on a full-size map: the belts, the moisture and the cleanup all work on
# fractions of the map height, so a small map would exercise only the edge cases.
const ROWS := 60
const COLS := 60
const SEED := 20261023

# The order of the temperature belts from the pole to the equator. The generator never inverts it,
# therefore the difference between two neighbouring hexes can only be 0 or 1.
const TEMPERATURES := ["cold", "mild", "subtropical", "tropical"]

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

    if WATCHDOG.wants_case("all_varieties"):
        _test_all_varieties(state)
    if WATCHDOG.wants_case("no_raw_families"):
        _test_no_raw_families(state)
    if WATCHDOG.wants_case("terrain_matches_zone"):
        _test_terrain_matches_zone(state)
    if WATCHDOG.wants_case("neighbouring_belts"):
        _test_neighbouring_belts(state)
    if WATCHDOG.wants_case("min_size"):
        _test_min_size(state)
    if WATCHDOG.wants_case("cold_edges"):
        _test_cold_edges(state)
    if WATCHDOG.wants_case("deserts_hot_dry"):
        _test_deserts_hot_dry(state)
    if WATCHDOG.wants_case("covers_from_zone"):
        _test_covers_from_zone(state)
    if WATCHDOG.wants_case("city_terrain"):
        _test_city_terrain(state)
    if WATCHDOG.wants_case("tooltip_terrain"):
        _test_tooltip_terrain(state)
    if WATCHDOG.wants_case("family_rules"):
        _test_family_rules(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("CLIMATE TEST FAILED")
        quit(1)
    else:
        print("CLIMATE TEST OK")
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

func _zone_id(row: int, col: int) -> String:
    return str(_tiles[row][col].get("climate", ""))

func _zone(row: int, col: int) -> Dictionary:
    return _gdata.climate_zones.get(_zone_id(row, col), {})

func _terrain_id(row: int, col: int) -> String:
    return str(_tiles[row][col].get("terrain", ""))

func _family(row: int, col: int) -> String:
    return _gdata.terrain_family(_terrain_id(row, col))

func _temperature_index(row: int, col: int) -> int:
    return TEMPERATURES.find(str(_zone(row, col).get("temperature", "")))

func _has_zone(row: int, col: int) -> bool:
    return _zone_id(row, col) != "" and _gdata.climate_zones.has(_zone_id(row, col))

# --- the checks --------------------------------------------------------------

# Every variety of every relief family exists somewhere on the map: a zone that never appears would
# silently remove one of the five plains, and the player would never see it.
func _test_all_varieties(state: Dictionary) -> void:
    _generate()
    var seen := {}
    for r in range(ROWS):
        for c in range(COLS):
            seen[_terrain_id(r, c)] = true
    for terrain_id in _gdata.terrains.keys():
        if _gdata.terrain_family(terrain_id) == "":
            continue
        check(seen.has(terrain_id), "the terrain %s never appears on the map" % terrain_id, state)

# The Voronoi places the relief families; the climate turns every one of them into a variety. A hex
# that still carries a family name has no terrain record: no icon, no yields, no vegetation.
func _test_no_raw_families(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            var terrain_id := _terrain_id(r, c)
            check(not ["plain", "hill", "mountain"].has(terrain_id),
                    "the raw relief family %s is left at (%d,%d)" % [terrain_id, r, c], state)

func _test_terrain_matches_zone(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            var family := _family(r, c)
            if family == "":
                continue
            check(_has_zone(r, c), "the hex (%d,%d) has a family but no zone" % [r, c], state)
            var expected: String = _gdata.zone_terrain(_zone_id(r, c), family)
            check(expected == _terrain_id(r, c),
                    "the hex (%d,%d) is %s, but the zone %s makes a %s out of %s" %
                    [r, c, _terrain_id(r, c), _zone_id(r, c), expected, family], state)

func _test_neighbouring_belts(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            if not _has_zone(r, c):
                continue
            var here := _temperature_index(r, c)
            for neighbour in HexUtils.get_neighbors_odd_r(r, c, ROWS, COLS):
                if not _has_zone(neighbour.row, neighbour.col):
                    continue
                var there := _temperature_index(neighbour.row, neighbour.col)
                check(absi(here - there) <= 1,
                        "two belts meet at (%d,%d)-(%d,%d): %s and %s" % [r, c, neighbour.row,
                        neighbour.col, _zone_id(r, c), _zone_id(neighbour.row, neighbour.col)], state)

# The zone patches are large regions: a patch of land smaller than min_zone_size is dissolved into
# the zone around it. An island with no land neighbours has nothing to merge with and stays.
func _test_min_size(state: Dictionary) -> void:
    _generate()
    var min_size := int(_gdata.map_config.get("climate", {}).get("min_zone_size", 3))
    var visited := {}
    for r in range(ROWS):
        for c in range(COLS):
            if visited.has(Vector2i(r, c)) or not _has_zone(r, c):
                continue
            var zone_id := _zone_id(r, c)
            var cells: Array = []
            var stack: Array = [Vector2i(r, c)]
            visited[Vector2i(r, c)] = true
            var touches_land := false
            while not stack.is_empty():
                var cell: Vector2i = stack.pop_back()
                cells.append(cell)
                for neighbour in HexUtils.get_neighbors_odd_r(cell.x, cell.y, ROWS, COLS):
                    var key := Vector2i(neighbour.row, neighbour.col)
                    if not _has_zone(neighbour.row, neighbour.col):
                        continue
                    if _zone_id(neighbour.row, neighbour.col) != zone_id:
                        touches_land = true
                        continue
                    if visited.has(key):
                        continue
                    visited[key] = true
                    stack.append(key)
            if not touches_land:
                continue
            check(cells.size() >= min_size,
                    "the zone %s has a patch of %d hexes at (%d,%d)" % [zone_id, cells.size(), r, c],
                    state)

# The map keeps a polar edge on both sides: the belts never reach the very top or the very bottom.
func _test_cold_edges(state: Dictionary) -> void:
    _generate()
    var cold := TEMPERATURES.find("cold")
    for r in range(3):
        for c in range(COLS):
            if not _has_zone(r, c):
                continue
            check(_temperature_index(r, c) == cold,
                    "the northern edge is not cold at (%d,%d): %s" % [r, c, _terrain_id(r, c)], state)
    for r in range(ROWS - 3, ROWS):
        for c in range(COLS):
            if not _has_zone(r, c):
                continue
            check(_temperature_index(r, c) == cold,
                    "the southern edge is not cold at (%d,%d): %s" % [r, c, _terrain_id(r, c)], state)

func _test_deserts_hot_dry(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            var terrain_id := _terrain_id(r, c)
            if terrain_id != "sandy_desert" and terrain_id != "rocky_desert":
                continue
            check(bool(_zone(r, c).get("deserts", false)),
                    "a desert outside the hot dry zone at (%d,%d): %s" % [r, c, _zone_id(r, c)], state)

# The vegetation of a hex belongs to its zone: the whole region shares one pool, and the pool
# applies to the plains, the hills and the mountains alike.
func _test_covers_from_zone(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            if _family(r, c) == "":
                continue
            if not _has_zone(r, c):
                continue
            var pool: Dictionary = _zone(r, c).get("cover_chance", {})
            var cover_id := str(_tiles[r][c].get("cover", "none"))
            check(pool.has(cover_id),
                    "the cover %s is not in the pool of %s at (%d,%d)" % [cover_id, _zone_id(r, c), r, c],
                    state)

func _test_city_terrain(state: Dictionary) -> void:
    _generate()
    var row := int(ROWS / 2.0)
    var col := int(COLS / 2.0)
    check(_has_zone(row, col), "the city hex has no climate zone", state)
    var family := _family(row, col)
    check(family == "plain" or family == "hill",
            "the city stands on %s (%s)" % [_terrain_id(row, col), family], state)

# The variety reaches the player: the tooltip names the terrain, and there is no separate climate
# line any more — the terrain itself is the climate of the hex.
func _test_tooltip_terrain(state: Dictionary) -> void:
    _generate()
    var label := RichTextLabel.new()
    var container := VBoxContainer.new()
    get_root().add_child(label)
    get_root().add_child(container)
    var tooltip = load("res://scripts/map_tooltip.gd").new(label, container, null, null)

    var found := Vector2i(-1, -1)
    for r in range(ROWS):
        for c in range(COLS):
            if _has_zone(r, c) and _tiles[r][c].get("improvement", null) == null:
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
    var terrain_name := str(_gdata.terrains.get(_terrain_id(found.x, found.y), {}).get("name", ""))
    check(text.contains("Terrain: "), "the tooltip does not name the terrain: %s" % text, state)
    check(text.contains(terrain_name),
            "the tooltip does not name the terrain %s: %s" % [terrain_name, text], state)
    check(not text.contains("Biome: "), "the tooltip still has the biome line: %s" % text, state)

    label.queue_free()
    container.queue_free()

# A rule of the data may name a terrain or its relief family: "plain" reaches every variety of the
# plain, and a family name never matches a terrain of another family.
func _test_family_rules(state: Dictionary) -> void:
    for terrain_id in _gdata.terrains.keys():
        var family: String = _gdata.terrain_family(terrain_id)
        check(_gdata.terrain_matches(terrain_id, terrain_id),
                "%s does not match itself" % terrain_id, state)
        if family != "":
            check(_gdata.terrain_matches(terrain_id, family),
                    "%s does not match its family %s" % [terrain_id, family], state)
            for other in ["plain", "hill", "mountain"]:
                if other == family:
                    continue
                check(not _gdata.terrain_matches(terrain_id, other),
                        "%s matches the foreign family %s" % [terrain_id, other], state)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
