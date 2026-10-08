extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# Autoloads and the helper modules are taken through load(): in the --script mode
# the names GameData, SeaManager, HexUtils and MapHelpers are not guaranteed to
# be in the global cache at compile time of this file (the same reason the other
# tests load HexUtils/MapHelpers by path).
var _gdata = null
var _sea = null
var _hu = null
var _mh = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    call_deferred("_run")

func _run() -> void:
    var state := {"failed": false}
    await process_frame
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _sea = load("res://scripts/sea_manager.gd")
    _hu = load("res://scripts/HexUtils.gd")
    _mh = load("res://scripts/map_helpers.gd")

    if WATCHDOG.wants_case("local_coast_width"):
        _test_local_coast_width(state)
    if WATCHDOG.wants_case("islands_do_not_add_shallows"):
        _test_islands_do_not_add_shallows(state)
    if WATCHDOG.wants_case("harbor_connectivity"):
        _test_harbor_connectivity(state)
    if WATCHDOG.wants_case("generated_sea_and_resources"):
        _test_generated_sea_and_resources(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("SEA COAST TEST FAILED")
        quit(1)
    else:
        print("SEA COAST TEST OK")
        quit(0)

func _test_local_coast_width(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var max_depth := 5
    var previous_sea: Dictionary = _gdata.map_config.get("sea", {}).duplicate(true)
    var test_sea := previous_sea.duplicate(true)
    test_sea["mode"] = "edge"
    test_sea["sides"] = [1, 1]
    test_sea["max_sea_depth"] = 20
    test_sea["coast_max_depth"] = max_depth
    test_sea["edge_width_min"] = 18
    test_sea["edge_width_max"] = 18
    test_sea["edge_envelope_strength"] = 0.0
    test_sea["edge_islands_enabled"] = false
    _gdata.map_config["sea"] = test_sea
    seed(31415)
    var tile_data := _make_tile_data(rows, cols)
    var sea_mask: Array = _sea.apply_sea(tile_data, rows, cols, 20, 20)
    for row in range(rows):
        for col in range(cols):
            tile_data[row][col]["terrain"] = "plain"
    _sea.reapply_sea_mask(tile_data)

    var shallow_mask := _make_mask(rows, cols)
    for row in range(rows):
        for col in range(cols):
            shallow_mask[row][col] = tile_data[row][col].get("terrain", "") == "shallow_sea"
    var distances := _coast_depths(sea_mask, rows, cols)
    var widths: Array[int] = []
    var edge_counts := _sea_edge_counts(sea_mask, rows, cols)
    var max_edge_count: int = edge_counts.values().max()
    var coast_side: String = edge_counts.keys()[edge_counts.values().find(max_edge_count)]
    for position in range(10, 30):
        var width := 0
        for row in range(rows):
            for col in range(cols):
                if not shallow_mask[row][col] or distances[row][col] <= width:
                    continue
                if _is_on_coast_segment(row, col, position, coast_side):
                    width = distances[row][col]
        widths.append(width)

    var distinct_widths := {}
    for row in range(rows):
        for col in range(cols):
            if shallow_mask[row][col]:
                check(sea_mask[row][col], "shallow water must remain inside the sea mask", state)
                check(distances[row][col] <= max_depth,
                    "shallow water must not exceed coast_max_depth", state)
    for width in widths:
        distinct_widths[width] = true
    check(distinct_widths.size() > 1,
        "shallow-water depth should vary along one coastline", state)
    for index in range(1, widths.size()):
        check(absi(widths[index] - widths[index - 1]) <= 2,
            "neighboring coast sections should not have abrupt depth changes", state)
    check(not shallow_mask[20][20], "deep sea should remain beyond the shallow belt", state)
    _gdata.map_config["sea"] = previous_sea

func _test_harbor_connectivity(state: Dictionary) -> void:
    var rows := 7
    var cols := 7
    var tile_data: Array = []
    for row in range(rows):
        var tile_row: Array = []
        for col in range(cols):
            tile_row.append({"terrain": "plain", "improvement": null})
        tile_data.append(tile_row)

    var start := {"row": 3, "col": 3}
    tile_data[start.row][start.col]["terrain"] = "shallow_sea"
    var start_neighbors: Array = _hu.get_neighbors_odd_r(start.row, start.col, rows, cols)
    var adjacent_keys := {}
    for neighbor in start_neighbors:
        adjacent_keys["%d,%d" % [neighbor.row, neighbor.col]] = true

    var deep_hex: Dictionary = {}
    var harbor_hex: Dictionary = {}
    for candidate in start_neighbors:
        for land in _hu.get_neighbors_odd_r(candidate.row, candidate.col, rows, cols):
            var key := "%d,%d" % [land.row, land.col]
            if land.row == start.row and land.col == start.col:
                continue
            if adjacent_keys.has(key):
                continue
            deep_hex = candidate
            harbor_hex = land
            break
        if not harbor_hex.is_empty():
            break

    check(not harbor_hex.is_empty(), "test map should fit a harbor beyond the shallow edge", state)
    if harbor_hex.is_empty():
        return
    tile_data[deep_hex.row][deep_hex.col]["terrain"] = "sea"
    tile_data[harbor_hex.row][harbor_hex.col]["improvement"] = "test_water_harbor"
    _gdata.improvements["test_water_harbor"] = {"water_body_harbor": true}
    check(_mh.has_harbor_access(tile_data, start.row, start.col, rows, cols),
        "a shallow-water resource should reach a harbor through deep sea", state)
    _gdata.improvements.erase("test_water_harbor")

func _test_islands_do_not_add_shallows(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var previous_sea: Dictionary = _gdata.map_config.get("sea", {}).duplicate(true)
    var test_sea := previous_sea.duplicate(true)
    test_sea["mode"] = "edge"
    test_sea["sides"] = [1, 1]
    test_sea["max_sea_depth"] = 20
    test_sea["coast_max_depth"] = 5
    test_sea["edge_width_min"] = 18
    test_sea["edge_width_max"] = 18
    test_sea["edge_envelope_strength"] = 0.0
    test_sea["edge_island_size"] = [1, 1]
    test_sea["edge_island_density"] = 0.2
    test_sea["edge_island_min_distance"] = 0
    test_sea["edge_island_max_attempts"] = 1000

    test_sea["edge_islands_enabled"] = false
    _gdata.map_config["sea"] = test_sea
    seed(987654)
    var mainland_only_tiles := _make_tile_data(rows, cols)
    _sea.apply_sea(mainland_only_tiles, rows, cols, 20, 20)

    test_sea["edge_islands_enabled"] = true
    _gdata.map_config["sea"] = test_sea
    seed(987654)
    var island_tiles := _make_tile_data(rows, cols)
    _sea.apply_sea(island_tiles, rows, cols, 20, 20)
    _gdata.map_config["sea"] = previous_sea

    var island_hexes := 0
    for row in range(rows):
        for col in range(cols):
            var mainland_tile: Dictionary = mainland_only_tiles[row][col]
            var island_tile: Dictionary = island_tiles[row][col]
            if mainland_tile.get("_is_sea", false) and not island_tile.get("_is_sea", false):
                island_hexes += 1
            if island_tile.get("_is_shallow_sea", false):
                check(mainland_tile.get("_is_shallow_sea", false),
                    "island generation must not add shallow-water hexes", state)
    check(island_hexes > 0, "the test setup should generate at least one island", state)

func _test_generated_sea_and_resources(state: Dictionary) -> void:
    var previous_sea: Dictionary = _gdata.map_config.get("sea", {}).duplicate(true)
    var test_sea := previous_sea.duplicate(true)
    test_sea["mode"] = "edge"
    test_sea["sides"] = [1, 1]
    test_sea["beach"] = true
    test_sea["max_sea_depth"] = 20
    test_sea["coast_max_depth"] = 5
    test_sea["edge_width_min"] = 18
    test_sea["edge_width_max"] = 18
    test_sea["edge_envelope_strength"] = 0.0
    test_sea["edge_islands_enabled"] = false
    _gdata.map_config["sea"] = test_sea

    seed(20261006)
    var rows := 40
    var cols := 40
    var city_row := rows >> 1
    var city_col := cols >> 1
    var generator = load("res://scripts/map_generator.gd").new()
    var tile_data: Array = generator.generate_map(
        rows, cols, city_row, city_col,
        _gdata.raw_resources,
        generator.make_terrain_counts(rows, cols))
    _gdata.map_config["sea"] = previous_sea

    var sea_mask := _make_mask(rows, cols)
    var shallow_count := 0
    var deep_count := 0
    var found_resources := {}
    var marine_ids := ["sea_fish", "murex", "cuttlefish"]
    for row in range(rows):
        for col in range(cols):
            var tile: Dictionary = tile_data[row][col]
            sea_mask[row][col] = tile.get("_is_sea", false)
            if tile.get("terrain", "") == "shallow_sea":
                shallow_count += 1
            elif tile.get("terrain", "") == "sea":
                deep_count += 1
            var resource_id := str(tile.get("resource", ""))
            if resource_id in marine_ids:
                found_resources[resource_id] = true
                check(tile.get("terrain", "") == "shallow_sea",
                    "%s must spawn only on shallow sea" % resource_id, state)

    var distances := _coast_depths(sea_mask, rows, cols)
    for row in range(rows):
        for col in range(cols):
            if tile_data[row][col].get("terrain", "") == "shallow_sea":
                check(distances[row][col] > 0 and distances[row][col] <= 5,
                    "generated shallow sea must stay within its configured coast depth", state)
    check(shallow_count > 0, "generated map should contain shallow sea", state)
    check(deep_count > 0, "generated map should retain deep sea", state)
    for resource_id in marine_ids:
        check(found_resources.has(resource_id),
            "%s should spawn on the generated shallow-water belt" % resource_id, state)
        var resource_data: Dictionary = _gdata.raw_resources.get(resource_id, {})
        check(resource_data.get("allowed_terrain", []) == ["shallow_sea"],
            "%s should allow shallow sea only" % resource_id, state)

func _make_mask(rows: int, cols: int) -> Array:
    var mask: Array = []
    for _row in range(rows):
        var row_mask: Array = []
        row_mask.resize(cols)
        row_mask.fill(false)
        mask.append(row_mask)
    return mask

func _make_tile_data(rows: int, cols: int) -> Array:
    var tile_data: Array = []
    for _row in range(rows):
        var tile_row: Array = []
        for _col in range(cols):
            tile_row.append({"terrain": "plain", "cover": "none", "resource": null})
        tile_data.append(tile_row)
    return tile_data

func _sea_edge_counts(sea_mask: Array, rows: int, cols: int) -> Dictionary:
    return {
        "west": _count_edge_sea(sea_mask, rows, cols, "west"),
        "east": _count_edge_sea(sea_mask, rows, cols, "east"),
        "north": _count_edge_sea(sea_mask, rows, cols, "north"),
        "south": _count_edge_sea(sea_mask, rows, cols, "south")
    }

func _count_edge_sea(sea_mask: Array, rows: int, cols: int, side: String) -> int:
    var count := 0
    for index in range(rows if side == "west" or side == "east" else cols):
        var row := index if side == "west" or side == "east" \
            else (0 if side == "north" else rows - 1)
        var col := index if side == "north" or side == "south" \
            else (0 if side == "west" else cols - 1)
        if sea_mask[row][col]:
            count += 1
    return count

func _is_on_coast_segment(row: int, col: int, position: int, side: String) -> bool:
    match side:
        "west": return row == position
        "east": return row == position
        "north": return col == position
        "south": return col == position
    return false

func _coast_depths(sea_mask: Array, rows: int, cols: int) -> Array:
    var distances: Array = []
    var queue: Array = []
    for row in range(rows):
        var distance_row: Array = []
        distance_row.resize(cols)
        distance_row.fill(-1)
        distances.append(distance_row)
        for col in range(cols):
            if not sea_mask[row][col]:
                continue
            for neighbor in _hu.get_neighbors_odd_r(row, col, rows, cols):
                if sea_mask[neighbor.row][neighbor.col]:
                    continue
                distances[row][col] = 1
                queue.append({"row": row, "col": col})
                break

    var queue_index := 0
    while queue_index < queue.size():
        var current: Dictionary = queue[queue_index]
        queue_index += 1
        for neighbor in _hu.get_neighbors_odd_r(current.row, current.col, rows, cols):
            if not sea_mask[neighbor.row][neighbor.col]:
                continue
            if distances[neighbor.row][neighbor.col] >= 0:
                continue
            distances[neighbor.row][neighbor.col] = distances[current.row][current.col] + 1
            queue.append(neighbor)
    return distances

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
