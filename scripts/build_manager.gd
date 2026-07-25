@tool
extends Node

signal build_message(text: String)
signal build_completed(row: int, col: int, imp_id: String, animal_id)

var active_builds: Dictionary = {}

func _ready():
    set_process(not Engine.is_editor_hint())

func _process(delta):
    if Engine.is_editor_hint():
        return

    var to_complete = []
    for key in active_builds.keys():
        var data = active_builds[key]
        data["progress"] += delta
        if data["progress"] >= data["target_time"]:
            to_complete.append(key)

    for key in to_complete:
        var data = active_builds[key]
        emit_signal("build_message", "Построено: %s" % data["imp_name"])
        emit_signal("build_completed", data["row"], data["col"], data["imp_id"], data.get("animal_id"))
        active_builds.erase(key)

func start_build(row: int, col: int, imp_id: String, animal_id = null) -> bool:
    var key = str(row) + "," + str(col)
    if active_builds.has(key):
        emit_signal("build_message", "Здесь уже идёт строительство")
        return false

    var imp_data = GameData.improvements.get(imp_id, {})
    var cost = imp_data.get("cost_food", 0)
    var build_time = imp_data.get("build_time", 3.0)
    var imp_name = imp_data.get("name", imp_id)

    var available_food = 0
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid]:
            available_food += CityData.city_storage.get(pid, 0)

    if available_food < cost:
        emit_signal("build_message", "Недостаточно еды! Нужно %d, есть %d" % [cost, available_food])
        return false

    var remaining = cost
    var active_food = []
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid] and CityData.city_storage.get(pid, 0) > 0:
            active_food.append(pid)
    while remaining > 0 and active_food.size() > 0:
        var pid = active_food[randi() % active_food.size()]
        CityData.city_storage[pid] -= 1
        remaining -= 1
        if CityData.city_storage[pid] <= 0:
            active_food.erase(pid)

    active_builds[key] = {
        "progress": 0.0,
        "target_time": build_time,
        "imp_id": imp_id,
        "animal_id": animal_id,
        "imp_name": imp_name,
        "row": row,
        "col": col
    }

    emit_signal("build_message", "Строительство %s начато (%.0f сек)" % [imp_name, build_time])
    return true

func is_building(row: int, col: int) -> bool:
    return active_builds.has(str(row) + "," + str(col))

func get_progress(row: int, col: int) -> Dictionary:
    var key = str(row) + "," + str(col)
    if active_builds.has(key):
        return active_builds[key]
    return {}

func remove_build(row: int, col: int):
    var key = str(row) + "," + str(col)
    active_builds.erase(key)
