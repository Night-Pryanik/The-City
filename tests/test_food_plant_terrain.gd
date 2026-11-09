# Headless test for the food-plant terrain-scarcity repair:
#   godot --headless --path . --script res://tests/test_food_plant_terrain.gd
#
# ensure_free_terrain_hexes repairs an ACTUAL soft-lock only: it tops the guaranteed
# food plant's terrain up to FOOD_PLANT_TERRAIN_HEXES inside the starting Ring when
# the random relief left too few of it, and does nothing when there is enough. It
# never destroys a resource and never touches the city hex or its neighbours.
# ensure_food_plant hands back the terrain of the plant it guaranteed (an existing
# one or the forcibly spawned one) so the caller can run that repair.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

const ROWS := 11
const COLS := 11
const CITY_ROW := 5
const CITY_COL := 5
# The plant sits outside the city 3x3, with two resource-bearing neighbours of its
# own to prove the conversion walks around a resource instead of over it.
const PLANT_ROW := 2
const PLANT_COL := 2

var _gdata = null
var _city = null
var _generator = null
var _helpers = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    call_deferred("_run")

func _run() -> void:
    var state := {"failed": false}
    await process_frame
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _city = get_root().get_node("CityData")
    _generator = load("res://scripts/map_generator.gd").new()
    _helpers = load("res://scripts/map_helpers.gd")

    if WATCHDOG.wants_case("deficit_repair"):
        _test_deficit_repair(state)
    if WATCHDOG.wants_case("abundant_no_change"):
        _test_abundant_no_change(state)
    if WATCHDOG.wants_case("empty_terrain_no_change"):
        _test_empty_terrain_no_change(state)
    if WATCHDOG.wants_case("variant_family"):
        _test_variant_family(state)
    if WATCHDOG.wants_case("food_plant_returns_terrain"):
        _test_food_plant_returns_terrain(state)

    WATCHDOG.report_skipped()
    _generator.free()
    if state["failed"]:
        print("FOOD PLANT TERRAIN TEST FAILED")
        quit(1)
    else:
        print("FOOD PLANT TERRAIN TEST OK")
        quit(0)

# --- the scenarios -----------------------------------------------------------

# A single mountain hex carries the plant: the relief left a deficit, so the repair
# grows the cluster to FOOD_PLANT_TERRAIN_HEXES with the nearest free hexes, walking
# around the resources and leaving the city yard alone.
func _test_deficit_repair(state: Dictionary) -> void:
    var grid := _grid("plain")
    grid[PLANT_ROW][PLANT_COL]["terrain"] = "mountain"
    grid[PLANT_ROW][PLANT_COL]["resource"] = "wheat_field"
    grid[PLANT_ROW][PLANT_COL + 1]["resource"] = "iron"
    grid[PLANT_ROW - 1][PLANT_COL]["resource"] = "stone"
    var resources_before := _resource_count(grid)
    var city_before := _city_signature(grid)

    _generator.ensure_free_terrain_hexes(grid, "mountain",
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)

    var target: int = _generator.FOOD_PLANT_TERRAIN_HEXES
    check(_count_family(grid, "mountain") == target,
            "a deficit mountain terrain is topped up to %d hexes" % target, state)
    check(grid[PLANT_ROW][PLANT_COL]["resource"] == "wheat_field",
            "the plant itself is kept", state)
    check(str(grid[PLANT_ROW][PLANT_COL]["terrain"]) == "mountain",
            "the plant's hex keeps its terrain", state)
    check(grid[PLANT_ROW][PLANT_COL + 1]["resource"] == "iron"
            and str(grid[PLANT_ROW][PLANT_COL + 1]["terrain"]) == "plain",
            "a resource-bearing neighbour is not converted", state)
    check(grid[PLANT_ROW - 1][PLANT_COL]["resource"] == "stone"
            and str(grid[PLANT_ROW - 1][PLANT_COL]["terrain"]) == "plain",
            "the other resource-bearing neighbour is not converted", state)
    check(_resource_count(grid) == resources_before,
            "no resource is destroyed by the conversion", state)
    check(_city_signature(grid) == city_before,
            "the city hex and its neighbours are untouched", state)
    # The addition grows onto the existing hex, not onto a far corner of the Ring.
    for r in range(ROWS):
        for c in range(COLS):
            if str(grid[r][c]["terrain"]) != "mountain" or (r == PLANT_ROW and c == PLANT_COL):
                continue
            check(HexUtils.hex_distance(r, c, PLANT_ROW, PLANT_COL) == 1,
                    "the added mountain hex (%d,%d) is not adjacent to the cluster" % [r, c], state)

# Enough hexes of the plant's terrain already: the guarantee must not fire, the map
# stays exactly as it was.
func _test_abundant_no_change(state: Dictionary) -> void:
    var grid := _grid("plain")
    grid[PLANT_ROW][PLANT_COL]["terrain"] = "mountain"
    grid[PLANT_ROW][PLANT_COL]["resource"] = "wheat_field"
    grid[PLANT_ROW][PLANT_COL + 1]["terrain"] = "mountain"
    grid[PLANT_ROW + 1][PLANT_COL]["terrain"] = "mountain"
    var before := _signature(grid)
    _generator.ensure_free_terrain_hexes(grid, "mountain",
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)
    check(_signature(grid) == before,
            "an abundant terrain is left unchanged", state)

# No plant could be guaranteed ("" terrain): nothing to repair.
func _test_empty_terrain_no_change(state: Dictionary) -> void:
    var grid := _grid("plain")
    var before := _signature(grid)
    _generator.ensure_free_terrain_hexes(grid, "",
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)
    check(_signature(grid) == before,
            "an empty plant terrain changes nothing", state)

# The plant stands on a climate variety: the counting and the repair work on the whole
# family, so a variety on an abundant family does not fire, and a lone variety on a
# foreign relief is topped up with hexes of that family.
func _test_variant_family(state: Dictionary) -> void:
    var variety := _plain_variant()

    var abundant := _grid("plain")
    abundant[PLANT_ROW][PLANT_COL]["terrain"] = variety
    abundant[PLANT_ROW][PLANT_COL]["resource"] = "wheat_field"
    var before := _signature(abundant)
    _generator.ensure_free_terrain_hexes(abundant, variety,
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)
    check(_signature(abundant) == before,
            "a plant variety on an abundant plain family does not fire", state)

    var scarce := _grid("mountain")
    scarce[PLANT_ROW][PLANT_COL]["terrain"] = variety
    scarce[PLANT_ROW][PLANT_COL]["resource"] = "wheat_field"
    var resources_before := _resource_count(scarce)
    _generator.ensure_free_terrain_hexes(scarce, variety,
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)
    check(_count_family(scarce, "plain") == _generator.FOOD_PLANT_TERRAIN_HEXES,
            "a lone plant variety is topped up to the family minimum", state)
    check(_resource_count(scarce) == resources_before,
            "the variety repair destroys no resource", state)

# ensure_food_plant returns the terrain of the plant it guarantees: an existing one,
# a forcibly spawned one, or "" when nothing can be placed.
func _test_food_plant_returns_terrain(state: Dictionary) -> void:
    # Existing plant: the terrain of its hex comes back, no second plant is added.
    var existing := _grid("plain")
    existing[3][3]["resource"] = "wheat_field"
    var returned: String = _helpers.ensure_food_plant(existing,
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)
    check(returned == "plain",
            "an existing food plant returns its terrain (got '%s')" % returned, state)
    check(_food_plant_count(existing) == 1,
            "an existing food plant is not duplicated", state)

    # Forced spawn: a food plant appears and its terrain comes back.
    if not _city.is_tech_unlocked("farming"):
        _city.unlocked_technologies.append("farming")
    var empty := _grid("plain")
    returned = _helpers.ensure_food_plant(empty,
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)
    check(returned == "plain",
            "a spawned food plant returns its terrain (got '%s')" % returned, state)
    check(_food_plant_count(empty) == 1,
            "exactly one food plant is spawned on an empty Ring", state)

    # No suitable hex: nothing is guaranteed and the return is empty.
    var barren := _grid("lake")
    returned = _helpers.ensure_food_plant(barren,
            0, ROWS - 1, 0, COLS - 1, CITY_ROW, CITY_COL)
    check(returned == "",
            "a Ring with no suitable hex returns an empty terrain (got '%s')" % returned, state)
    check(_food_plant_count(barren) == 0,
            "no food plant is forced onto an unsuitable terrain", state)

# --- the helpers -------------------------------------------------------------

func _grid(terrain: String) -> Array:
    var grid: Array = []
    for r in range(ROWS):
        var row: Array = []
        for c in range(COLS):
            row.append({"terrain": terrain, "cover": "none", "resource": null})
        grid.append(row)
    return grid

# A terrain+resource fingerprint of the whole grid, to assert "nothing changed".
func _signature(grid: Array) -> Array:
    var sig: Array = []
    for r in range(ROWS):
        for c in range(COLS):
            sig.append("%s|%s" % [str(grid[r][c]["terrain"]), str(grid[r][c]["resource"])])
    return sig

func _city_signature(grid: Array) -> Array:
    var sig: Array = []
    for r in range(CITY_ROW - 1, CITY_ROW + 2):
        for c in range(CITY_COL - 1, CITY_COL + 2):
            sig.append("%s|%s" % [str(grid[r][c]["terrain"]), str(grid[r][c]["resource"])])
    return sig

func _count_family(grid: Array, key: String) -> int:
    var n := 0
    for r in range(ROWS):
        for c in range(COLS):
            if _gdata.terrain_matches(str(grid[r][c].get("terrain", "")), key):
                n += 1
    return n

func _resource_count(grid: Array) -> int:
    var n := 0
    for r in range(ROWS):
        for c in range(COLS):
            if grid[r][c]["resource"] != null:
                n += 1
    return n

func _food_plant_count(grid: Array) -> int:
    var n := 0
    for r in range(ROWS):
        for c in range(COLS):
            var res = grid[r][c]["resource"]
            if res != null and _gdata.raw_resources.get(res, {}).get("group") == "food_plants":
                n += 1
    return n

# A real climate variety of the plain, so the family test is not pinned to a raw name.
func _plain_variant() -> String:
    for tid in _gdata.terrains:
        if tid != "plain" and _gdata.terrain_family(tid) == "plain":
            return tid
    return "plain"

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)