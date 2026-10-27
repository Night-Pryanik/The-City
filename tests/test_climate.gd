extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The climate is checked on a full-size map: the belts, the moisture and the cleanup all work on
# fractions of the map height, so a small map would exercise only the edge cases.
const ROWS := 60
const COLS := 60
const SEED := 20261023

# The order of the temperature belts from the pole to the equator. The generator never inverts it,
# therefore the difference between two neighbouring hexes can only be 0 or 1.
const TEMPERATURES := ["polar", "cold", "mild", "subtropical", "tropical"]

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
    if WATCHDOG.wants_case("polar_edges"):
        _test_polar_edges(state)
    if WATCHDOG.wants_case("pole_under_sea"):
        _test_pole_under_sea(state)
    if WATCHDOG.wants_case("tundra_has_no_woods"):
        _test_tundra_has_no_woods(state)
    if WATCHDOG.wants_case("deserts_hot_dry"):
        _test_deserts_hot_dry(state)
    if WATCHDOG.wants_case("covers_from_zone"):
        _test_covers_from_zone(state)
    if WATCHDOG.wants_case("city_terrain"):
        _test_city_terrain(state)
    if WATCHDOG.wants_case("tooltip_terrain"):
        _test_tooltip_terrain(state)
    if WATCHDOG.wants_case("terrain_names"):
        _test_terrain_names(state)
    if WATCHDOG.wants_case("family_rules"):
        _test_family_rules(state)
    if WATCHDOG.wants_case("swamp_reeds_warm"):
        _test_swamp_reeds_warm(state)
    if WATCHDOG.wants_case("marsh_reeds_warm"):
        _test_marsh_reeds_warm(state)

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
    _tiles = _build_map([])

# A map of the same seed, optionally with the sea on the given map edges. The sea is a world
# setting, so the second map has to be asked for through CityData like a new game does.
func _build_map(sides: Array) -> Array:
    var city_data = get_root().get_node("CityData")
    var saved_sea: Dictionary = city_data.world_sea
    if not sides.is_empty():
        city_data.world_sea = city_data.DEFAULT_SEA.duplicate(true)
        city_data.world_sea["sides"] = sides
    var generator = load("res://scripts/map_generator.gd").new()
    seed(SEED)
    var counts = generator.make_terrain_counts(ROWS, COLS)
    var tiles: Array = generator.generate_map(ROWS, COLS, int(ROWS / 2.0), int(COLS / 2.0),
            _gdata.raw_resources, counts)
    generator.free()
    city_data.world_sea = saved_sea
    return tiles

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

# Whether a patch of hexes reaches the pole row of the map.
func _touches_pole(cells: Array) -> bool:
    for cell in cells:
        if cell.x == 0 or cell.x == ROWS - 1:
            return true
    return false

# --- the checks --------------------------------------------------------------

# Every variety of every relief family exists somewhere on the map: a zone that never appears would
# silently remove one of the six plains, and the player would never see it. The swamps are not
# checked this way: there are only a few swamp hexes on the map and no belt is obliged to get one,
# so a missing bog proves nothing. That every swamp hex is the bog of its own zone is checked by
# _test_terrain_matches_zone.
func _test_all_varieties(state: Dictionary) -> void:
    _generate()
    var seen := {}
    for r in range(ROWS):
        for c in range(COLS):
            seen[_terrain_id(r, c)] = true
    for terrain_id in _gdata.terrains.keys():
        if not _gdata.RELIEF_FAMILIES.has(_gdata.terrain_family(terrain_id)):
            continue
        check(seen.has(terrain_id), "the terrain %s never appears on the map" % terrain_id, state)

# The Voronoi places the families; the climate turns every one of them into a variety. A hex that
# still carries a family name has no terrain record: no icon, no yields, no vegetation.
func _test_no_raw_families(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            var terrain_id := _terrain_id(r, c)
            check(not ["plain", "hill", "mountain", "swamp", "marsh"].has(terrain_id),
                    "the raw family %s is left at (%d,%d)" % [terrain_id, r, c], state)

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
# the zone around it. An island with no land neighbours has nothing to merge with and stays, and
# neither is a patch that reaches the pole row: the belt of those hexes is pinned by the latitude,
# and the sea cuts the polar band into specks often enough to leave one behind.
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
            if _touches_pole(cells):
                continue
            check(cells.size() >= min_size,
                    "the zone %s has a patch of %d hexes at (%d,%d)" % [zone_id, cells.size(), r, c],
                    state)

# The map keeps a polar edge on both sides: the tundra reaches the very pole, and no belt warmer
# than the taiga comes near the edge.
func _test_polar_edges(state: Dictionary) -> void:
    _generate()
    var polar := TEMPERATURES.find("polar")
    var cold := TEMPERATURES.find("cold")
    for r in range(ROWS):
        var edge := mini(r, ROWS - 1 - r)
        for c in range(COLS):
            if not _has_zone(r, c):
                continue
            var here := _temperature_index(r, c)
            if edge == 0:
                check(here == polar, "the pole is not tundra at (%d,%d): %s" % [r, c, _zone_id(r, c)], state)
            elif edge < 3:
                check(here <= cold,
                        "the edge is too warm at (%d,%d): %s" % [r, c, _zone_id(r, c)], state)

# The same two rules on a map whose sea eats both poles: a strip along the north and along the
# south leaves a corner of the pole behind the water, one or two hexes large. Those hexes are
# still the pole, so they stay tundra and are not merged into the taiga by the cleanup of the
# small patches — which is exactly what the strip along both edges used to do.
func _test_pole_under_sea(state: Dictionary) -> void:
    _generate()
    var main_tiles: Array = _tiles
    _tiles = _build_map(["north", "south"])

    var pole_land := 0
    for r in range(ROWS):
        if mini(r, ROWS - 1 - r) != 0:
            continue
        for c in range(COLS):
            if _has_zone(r, c):
                pole_land += 1
    check(pole_land > 0, "the sea left no land on the pole rows to check", state)

    _test_polar_edges(state)
    _test_min_size(state)
    _tiles = main_tiles

# The tundra lies beyond the taiga: the pool of the polar zone has no woods, so no forest grows on
# the relief of the tundra. The bog of the tundra keeps its own pool, which has no woods either.
func _test_tundra_has_no_woods(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            if _family(r, c) == "":
                continue
            if _temperature_index(r, c) != TEMPERATURES.find("polar"):
                continue
            var cover: Dictionary = _gdata.covers.get(_tiles[r][c].get("cover", "none"), {})
            check(float(cover.get("wood_yield", 0)) <= 0.0,
                    "a wooded cover %s grows in the tundra at (%d,%d)" % [cover.get("id", ""), r, c],
                    state)

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
# applies to the plains, the hills and the mountains alike. The swamp is the exception — its
# vegetation is the pool of its own record, and _test_swamp_reeds_warm guards the part of it that
# matters.
func _test_covers_from_zone(state: Dictionary) -> void:
    _generate()
    for r in range(ROWS):
        for c in range(COLS):
            if not _gdata.RELIEF_FAMILIES.has(_family(r, c)):
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
    var terrain_name := str(_gdata.terrain_display_name(_terrain_id(found.x, found.y),
            str(_tiles[found.x][found.y].get("cover", "none"))))
    check(text.contains("Terrain: "), "the tooltip does not name the terrain: %s" % text, state)
    check(text.contains(terrain_name),
            "the tooltip does not name the terrain %s: %s" % [terrain_name, text], state)
    check(not text.contains("Biome: "), "the tooltip still has the biome line: %s" % text, state)

    label.queue_free()
    container.queue_free()

# The name of a variety carries its climate zone — "Boreal, Plain", "Tropical, Hills" — and the
# mountains and the swamps are the same in every zone, so they are just "Mountains" and "Swamps".
func _test_terrain_names(state: Dictionary) -> void:
    for terrain_id in _gdata.terrains.keys():
        var family: String = _gdata.terrain_family(terrain_id)
        if family == "":
            continue
        var terrain_name := str(_gdata.terrains[terrain_id].get("name", ""))
        if family == "mountain":
            check(terrain_name == "Mountains",
                    "the mountain %s is named %s, not Mountains" % [terrain_id, terrain_name], state)
        elif family == "swamp":
            check(terrain_name == "Swamps",
                    "the swamp %s is named %s, not Swamps" % [terrain_id, terrain_name], state)
        elif family == "marsh":
            check(terrain_name == "Marsh",
                    "the marsh %s is named %s, not Marsh" % [terrain_id, terrain_name], state)
        else:
            check(terrain_name.contains(", "),
                    "the name of %s (%s) carries no climate zone" % [terrain_id, terrain_name], state)

# A rule of the data may name a terrain or its family: "plain" reaches every variety of the plain,
# "swamp" every variety of the wetland, and a family name never matches a terrain of another family.
func _test_family_rules(state: Dictionary) -> void:
    for terrain_id in _gdata.terrains.keys():
        var family: String = _gdata.terrain_family(terrain_id)
        check(_gdata.terrain_matches(terrain_id, terrain_id),
                "%s does not match itself" % terrain_id, state)
        if family != "":
            check(_gdata.terrain_matches(terrain_id, family),
                    "%s does not match its family %s" % [terrain_id, family], state)
            for other in ["plain", "hill", "mountain", "swamp", "marsh"]:
                if other == family:
                    continue
                check(not _gdata.terrain_matches(terrain_id, other),
                        "%s matches the foreign family %s" % [terrain_id, other], state)

# The reed bed is the vegetation of the warm swamp, and the papyrus grows in it: no reed may appear
# in the bog of the polar or the cold belt. The cover of a swamp comes from its own pool, so this is
# the one thing the climate of a zone must not decide.
func _test_swamp_reeds_warm(state: Dictionary) -> void:
    _generate()
    var cold_belts := [TEMPERATURES.find("polar"), TEMPERATURES.find("cold")]
    var checked := 0
    for r in range(ROWS):
        for c in range(COLS):
            if _family(r, c) != "swamp":
                continue
            if _temperature_index(r, c) not in cold_belts:
                continue
            checked += 1
            check(str(_tiles[r][c].get("cover", "none")) != "reeds",
                    "a reed bed grows in the cold swamp at (%d,%d), zone %s" %
                    [r, c, _zone_id(r, c)], state)
    check(checked > 0, "the map under test has no cold swamp to check", state)

# The reed bed is the vegetation of the warm marsh too: no reed may appear in the frozen mudflat
# of the polar or the cold belt. The cover of a marsh comes from its own pool, just like the swamp.
func _test_marsh_reeds_warm(state: Dictionary) -> void:
    _generate()
    var cold_belts := [TEMPERATURES.find("polar"), TEMPERATURES.find("cold")]
    var checked := 0
    for r in range(ROWS):
        for c in range(COLS):
            if _family(r, c) != "marsh":
                continue
            if _temperature_index(r, c) not in cold_belts:
                continue
            checked += 1
            check(str(_tiles[r][c].get("cover", "none")) != "reeds",
                    "a reed bed grows in the cold marsh at (%d,%d), zone %s" %
                    [r, c, _zone_id(r, c)], state)
    check(checked > 0, "the map under test has no cold marsh to check", state)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
