# worker_manager.gd
extends Node

signal assignment_changed()

var assigned_hexes = {}

func find_vacancy() -> Dictionary:
    var main_map = get_parent()
    var tile_data = main_map.tile_data
    var region_rows = main_map.REGION_ROWS
    var region_cols = main_map.REGION_COLS

    var candidates = []
    for row in range(region_rows):
        for col in range(region_cols):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            var improvement = tile.get("improvement")
            if improvement == null:
                continue
            if assigned_hexes.has(str(row) + "," + str(col)):
                continue

            var priority = 0
            if improvement == "farm" or improvement == "pasture" or improvement == "mine":
                priority = 1
            else:
                priority = 2

            candidates.append({
                "row": row,
                "col": col,
                "priority": priority,
                "improvement": improvement
            })

    candidates.sort_custom(func(a, b): return a.priority < b.priority)
    if candidates.size() > 0:
        return {"row": candidates[0].row, "col": candidates[0].col}
    return {}

func assign_worker(row: int = -1, col: int = -1) -> bool:
    if row == -1 or col == -1:
        var vacancy = find_vacancy()
        if vacancy.is_empty():
            return false
        row = vacancy.row
        col = vacancy.col

    var key = str(row) + "," + str(col)
    if assigned_hexes.has(key):
        return false
    if CityData.idle_population <= 0:
        return false

    assigned_hexes[key] = true
    CityData.idle_population -= 1
    emit_signal("assignment_changed")
    return true

func remove_worker(row: int, col: int):
    var key = str(row) + "," + str(col)
    if assigned_hexes.has(key):
        assigned_hexes.erase(key)
        CityData.idle_population += 1
        emit_signal("assignment_changed")

func has_worker(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    return assigned_hexes.has(key)

func get_assigned_count() -> int:
    return assigned_hexes.size()

func serialize_assignments() -> Array:
    var result = []
    for key in assigned_hexes.keys():
        var parts = key.split(",", false)
        if parts.size() == 2:
            result.append({"row": int(parts[0]), "col": int(parts[1])})
    return result

func load_assignments(assignments: Array):
    assigned_hexes.clear()
    for item in assignments:
        if item is Dictionary and item.has("row") and item.has("col"):
            var row = int(item.get("row", -1))
            var col = int(item.get("col", -1))
            if row >= 0 and col >= 0:
                assigned_hexes[str(row) + "," + str(col)] = true
    emit_signal("assignment_changed")
