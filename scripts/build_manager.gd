@tool
extends Node

signal build_message(text: String)
signal build_completed(row: int, col: int, imp_id: String, target_res_id)
signal build_paused(row: int, col: int)
signal build_cancelled(row: int, col: int)
signal build_building_completed(building_id: String, build_key: String)
signal build_building_paused(build_key: String)
signal build_building_cancelled(build_key: String)

var active_builds: Dictionary = {} # улучшения на карте: ключ "row,col"
var active_building_builds: Dictionary = {} # стройка зданий: ключ "building_<индекс>"

# Кэш числа активных строек (улучшения + здания). Обновляется при каждом
# добавлении/удалении стройки, чтобы has_active_builds() мог бы работать за
# O(1), не сканируя словари каждый кадр (используется в main_map._process
# для решения о перерисовке слоя прогресс-баров).
var _active_build_count: int = 0

func _ready():
    set_process(not Engine.is_editor_hint())
    _recount_active_builds()

func _process(delta):
    if Engine.is_editor_hint():
        return

    # Собираем активные (не приостановленные) стройки улучшений и зданий
    var active_builds_list = []
    for key in active_builds.keys():
        var data = active_builds[key]
        if data.get("status", "active") == "active":
            active_builds_list.append(data)
    for key in active_building_builds.keys():
        var data = active_building_builds[key]
        if data.get("status", "active") == "active":
            active_builds_list.append(data)

    # Если нет активных строек — ничего не делаем
    if active_builds_list.is_empty():
        return

    # Распределяем общий труд между активными стройками поровну
    var total_labor = CityData.get_total_labor()
    var labor_per_build = total_labor / active_builds_list.size()

    var to_complete = []
    var to_complete_buildings = []
    for data in active_builds_list:
        data["progress"] += labor_per_build * delta
        data["allocated_labor"] = labor_per_build
        if data["progress"] >= data["work_cost"]:
            if data.has("row"):
                to_complete.append(data)
            else:
                to_complete_buildings.append(data)

    for data in to_complete:
        var key = str(data["row"]) + "," + str(data["col"])
        emit_signal("build_message", "Построено: %s" % data["imp_name"])
        emit_signal("build_completed", data["row"], data["col"], data["imp_id"], data.get("target_res_id"))
        active_builds.erase(key)

    for data in to_complete_buildings:
        var bkey = data.get("build_key", "")
        emit_signal("build_message", "Построено: %s" % data["building_name"])
        emit_signal("build_building_completed", data["building_id"], bkey)
        active_building_builds.erase(bkey)

    # После завершения строек в _process обновляем кэш счётчика.
    if not to_complete.is_empty() or not to_complete_buildings.is_empty():
        _recount_active_builds()

func start_build(row: int, col: int, imp_id: String, target_res_id = null) -> bool:
    var key = str(row) + "," + str(col)
    if active_builds.has(key):
        emit_signal("build_message", "Здесь уже идёт строительство")
        return false

    var imp_data = GameData.improvements.get(imp_id, {})
    var imp_name = imp_data.get("name", imp_id)
    # Спец-действия (вырубка леса, осушение болот и т.п.) не являются улучшениями —
    # имя берём из GameData.special_actions.
    if GameData.special_actions.has(imp_id):
        imp_name = GameData.special_actions[imp_id].get("name", imp_id)

    # Стоимость труда зависит от типа местности и расстояния до города.
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var work_cost = 0
    if main_map and main_map.has_method("get_improvement_work_cost"):
        work_cost = main_map.get_improvement_work_cost(imp_id, row, col)["cost"]
    else:
        work_cost = imp_data.get("work_cost", 0)

    # Строительство теперь требует труд, а не еду
    if work_cost <= 0:
        emit_signal("build_message", "Построено мгновенно: %s" % imp_name)
        emit_signal("build_completed", row, col, imp_id, target_res_id)
        return true

    # Общий лимит одновременных строек (здания + улучшения) равен числу жителей
    if get_total_active_builds() >= CityData.total_population:
        emit_signal("build_message", "Можно строить не более %d зданий или улучшений одновременно (лимит = число жителей)" % CityData.total_population)
        return false

    active_builds[key] = {
        "progress": 0.0,
        "work_cost": work_cost,
        "imp_id": imp_id,
        "target_res_id": target_res_id,
        "imp_name": imp_name,
        "row": row,
        "col": col,
        "status": "active",
        "allocated_labor": 0.0
    }
    _active_build_count += 1

    emit_signal("build_message", "Строительство %s начато (%.0f труда)" % [imp_name, work_cost])
    return true

func start_building_build(building_id: String) -> String:
    var work_cost = 0
    var building_name = building_id
    for b in GameData.buildings:
        if b["id"] == building_id:
            work_cost = b.get("work_cost", 0)
            building_name = b.get("name", building_id)
            break

    if work_cost <= 0:
        emit_signal("build_building_completed", building_id, "")
        return ""

    # Общий лимит одновременных строек (здания + улучшения) равен числу жителей
    if get_total_active_builds() >= CityData.total_population:
        emit_signal("build_message", "Можно строить не более %d зданий или улучшений одновременно (лимит = число жителей)" % CityData.total_population)
        return ""

    var build_key = "building_" + str(Time.get_ticks_usec())
    active_building_builds[build_key] = {
        "progress": 0.0,
        "work_cost": work_cost,
        "building_id": building_id,
        "building_name": building_name,
        "build_key": build_key,
        "status": "active",
        "allocated_labor": 0.0
    }
    _active_build_count += 1

    emit_signal("build_message", "Строительство %s начато (%.0f труда)" % [building_name, work_cost])
    return build_key

func pause_build(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return false

    var data = active_builds[key]
    if data.get("status", "active") == "paused":
        return false

    data["status"] = "paused"
    data["allocated_labor"] = 0.0
    emit_signal("build_paused", row, col)
    emit_signal("build_message", "Строительство %s приостановлено" % data["imp_name"])
    return true

func resume_build(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return false

    var data = active_builds[key]
    if data.get("status", "active") == "active":
        return false

    data["status"] = "active"
    emit_signal("build_message", "Строительство %s возобновлено" % data["imp_name"])
    return true

func cancel_build(row: int, col: int):
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return

    var data = active_builds[key]
    var imp_name = data["imp_name"]
    var work_done = data["progress"]
    var work_total = data["work_cost"]

    active_builds.erase(key)
    _active_build_count -= 1
    emit_signal("build_cancelled", row, col)
    emit_signal("build_message", "Строительство %s отменено. Потрачено %.0f/%d труда" % [imp_name, work_done, work_total])

func pause_building_build(build_key: String) -> bool:
    if not active_building_builds.has(build_key):
        return false

    var data = active_building_builds[build_key]
    if data.get("status", "active") == "paused":
        return false

    data["status"] = "paused"
    data["allocated_labor"] = 0.0
    emit_signal("build_building_paused", build_key)
    emit_signal("build_message", "Строительство %s приостановлено" % data["building_name"])
    return true

func resume_building_build(build_key: String) -> bool:
    if not active_building_builds.has(build_key):
        return false

    var data = active_building_builds[build_key]
    if data.get("status", "active") == "active":
        return false

    data["status"] = "active"
    emit_signal("build_message", "Строительство %s возобновлено" % data["building_name"])
    return true

func cancel_building_build(build_key: String):
    if not active_building_builds.has(build_key):
        return

    var data = active_building_builds[build_key]
    var building_name = data["building_name"]
    var work_done = data["progress"]
    var work_total = data["work_cost"]

    active_building_builds.erase(build_key)
    _active_build_count -= 1
    emit_signal("build_building_cancelled", build_key)
    emit_signal("build_message", "Строительство %s отменено. Потрачено %.0f/%d труда" % [building_name, work_done, work_total])

# Возвращает общее количество активных строек (улучшения на карте + здания).
func get_total_active_builds() -> int:
    return active_builds.size() + active_building_builds.size()

# Возвращает true, если есть хотя бы одна активная стройка (улучшение ИЛИ здание).
# Работает за O(1) через кэшированный счётчик — используется в main_map._process
# для решения, нужно ли перерисовывать слой прогресс-баров каждый кадр.
func has_active_builds() -> bool:
    return _active_build_count > 0

# Пересчитывает кэш числа активных строек по фактическому размеру словарей.
# Вызывается при восстановлении строек из сохранения и в _ready.
func _recount_active_builds():
    _active_build_count = active_builds.size() + active_building_builds.size()

func is_building(row: int, col: int) -> bool:
    return active_builds.has(str(row) + "," + str(col))

func is_building_paused(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return false
    return active_builds[key].get("status", "active") == "paused"

func get_progress(row: int, col: int) -> Dictionary:
    var key = str(row) + "," + str(col)
    if active_builds.has(key):
        return active_builds[key]
    return {}

func remove_build(row: int, col: int):
    var key = str(row) + "," + str(col)
    if active_builds.erase(key):
        _active_build_count -= 1

# Восстанавливает стройки улучшений из сохранения.
func restore_builds(data: Dictionary):
    active_builds.clear()
    if data.is_empty():
        _recount_active_builds()
        return
    for key in data.keys():
        var build_data = data[key]
        if not (build_data is Dictionary):
            continue
        # Валидируем: стройка должна иметь координаты и imp_id
        if not build_data.has("row") or not build_data.has("col") or not build_data.has("imp_id"):
            continue
        active_builds[String(key)] = {
            "progress": float(build_data.get("progress", 0.0)),
            "work_cost": float(build_data.get("work_cost", 1.0)),
            "imp_id": String(build_data.get("imp_id", "")),
            "target_res_id": build_data.get("target_res_id"),
            "imp_name": String(build_data.get("imp_name", build_data.get("imp_id", ""))),
            "row": int(build_data.get("row", 0)),
            "col": int(build_data.get("col", 0)),
            "status": String(build_data.get("status", "active")),
            "allocated_labor": float(build_data.get("allocated_labor", 0.0))
        }
    _recount_active_builds()

# Восстанавливает стройки зданий из сохранения.
func restore_building_builds(data: Dictionary):
    active_building_builds.clear()
    if data.is_empty():
        _recount_active_builds()
        return
    for key in data.keys():
        var build_data = data[key]
        if not (build_data is Dictionary):
            continue
        # Валидируем: стройка должна иметь building_id
        if not build_data.has("building_id"):
            continue
        active_building_builds[String(key)] = {
            "progress": float(build_data.get("progress", 0.0)),
            "work_cost": float(build_data.get("work_cost", 1.0)),
            "building_id": String(build_data.get("building_id", "")),
            "building_name": String(build_data.get("building_name", build_data.get("building_id", ""))),
            "build_key": String(build_data.get("build_key", key)),
            "status": String(build_data.get("status", "active")),
            "allocated_labor": float(build_data.get("allocated_labor", 0.0))
        }
    _recount_active_builds()

func is_building_build_active(build_key: String) -> bool:
    return active_building_builds.has(build_key)

func is_building_build_paused(build_key: String) -> bool:
    if not active_building_builds.has(build_key):
        return false
    return active_building_builds[build_key].get("status", "active") == "paused"

func get_building_build_progress(build_key: String) -> Dictionary:
    if active_building_builds.has(build_key):
        return active_building_builds[build_key]
    return {}
