# townsfolk_manager.gd
extends Node

signal assignment_changed()

var assigned_buildings = {}

func find_vacancy() -> int:
    var city_built = CityData.city_built_buildings
    for i in range(city_built.size()):
        if not assigned_buildings.has(str(i)):
            return i
    return -1

func assign_townsfolk(index: int = -1) -> bool:
    if index == -1:
        index = find_vacancy()
        if index == -1:
            return false

    if assigned_buildings.has(str(index)):
        return false
    if CityData.idle_population <= 0:
        return false

    assigned_buildings[str(index)] = true
    CityData.idle_population -= 1
    emit_signal("assignment_changed")
    return true

func remove_townsfolk(index: int):
    if assigned_buildings.has(str(index)):
        assigned_buildings.erase(str(index))
        CityData.idle_population += 1
        emit_signal("assignment_changed")

func has_townsfolk(index: int) -> bool:
    return assigned_buildings.has(str(index))

func get_assigned_count() -> int:
    return assigned_buildings.size()

func serialize_assignments() -> Array:
    var result = []
    for key in assigned_buildings.keys():
        result.append(int(key))
    return result

func load_assignments(assignments: Array):
    assigned_buildings.clear()
    for idx in assignments:
        var index = int(idx)
        if index >= 0 and index < CityData.city_built_buildings.size():
            assigned_buildings[str(index)] = true
    emit_signal("assignment_changed")
