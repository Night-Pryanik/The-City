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
