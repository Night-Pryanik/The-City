# townsfolk_manager.gd
extends Node

signal assignment_changed()

# Словарь занятых зданий: "index" -> true
# index — это порядковый номер здания в CityData.city_built_buildings
var assigned_buildings = {}

# Поиск свободного здания (без горожанина)
func find_vacancy() -> int:
    var city_built = CityData.city_built_buildings
    for i in range(city_built.size()):
        if not assigned_buildings.has(str(i)):
            return i
    return -1

# Назначить горожанина на здание (по индексу или автоматически)
func assign_townsfolk(index: int = -1) -> bool:
    if index == -1:
        index = find_vacancy()
        if index == -1:
            return false

    if assigned_buildings.has(str(index)):
        return false
    if CityData.townsfolk <= 0:
        return false

    assigned_buildings[str(index)] = true
    CityData.townsfolk -= 1
    emit_signal("assignment_changed")
    return true

# Снять горожанина со здания
func remove_townsfolk(index: int):
    if assigned_buildings.has(str(index)):
        assigned_buildings.erase(str(index))
        CityData.townsfolk += 1
        emit_signal("assignment_changed")

# Проверить, есть ли горожанин на здании
func has_townsfolk(index: int) -> bool:
    return assigned_buildings.has(str(index))

# Количество занятых горожан
func get_assigned_count() -> int:
    return assigned_buildings.size()

# Сериализация для сохранения
func serialize_assignments() -> Array:
    var result = []
    for key in assigned_buildings.keys():
        result.append(int(key))
    return result

# Загрузка назначений из сохранения
func load_assignments(assignments: Array):
    assigned_buildings.clear()
    for idx in assignments:
        assigned_buildings[str(idx)] = true
    emit_signal("assignment_changed")
