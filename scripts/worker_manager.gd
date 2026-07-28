# worker_manager.gd
extends Node

# Словарь занятых гексов: "row,col" -> true
var assigned_hexes = {}

func assign_worker(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    if assigned_hexes.has(key):
        return false  # уже есть рабочий
    if CityData.workers <= 0:
        return false  # нет свободных рабочих
    assigned_hexes[key] = true
    CityData.workers -= 1
    return true

func remove_worker(row: int, col: int):
    var key = str(row) + "," + str(col)
    if assigned_hexes.has(key):
        assigned_hexes.erase(key)
        CityData.workers += 1

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
