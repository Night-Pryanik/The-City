# worker_manager.gd
extends Node

signal assignment_changed()

var assigned_hexes = {}

# Таймеры потребления профессиональных ресурсов, ключ — "row,col".
# Значение: { "elapsed": float, "interval": float } — сколько секунд прошло
# с момента последнего списания и с каким интервалом нужно списывать.
# Эти таймеры нужны, чтобы потребление шло НЕ каждый production-тик
# (раз в 2 сек), а с интервалом, заданным в декларации потребления
# (data/consumption.json или устаревшее поле consumption у продукта;
# например, 10 сек для группы «Лодки»). Сам по себе таймер НЕ блокирует
# производство: если ресурса нет, улучшение просто откатывается к базовому
# множителю (без бонуса потребления). См. tick_consumption().
var consumption_timers: Dictionary = {}

func find_vacancy() -> Dictionary:
    var main_map = get_parent()
    var tile_data = main_map.tile_data

    var candidates = []
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            var improvement = tile.get("improvement")
            if improvement == null:
                continue
            # Инфраструктурные улучшения (поле "no_worker" в improvements.json,
            # например пристань) рабочих не требуют и не должны получать их
            # при автоназначении свободных жителей.
            if GameData.is_no_worker_improvement(improvement):
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

    # Защита от прямых вызовов: инфраструктурные улучшения (no_worker,
    # например пристань) рабочего не получают ни при каких условиях.
    var mm = get_parent()
    if mm != null and row >= 0 and row < mm.map_rows and col >= 0 and col < mm.map_cols:
        var target_tile = mm.tile_data[row][col]
        if target_tile != null and target_tile.get("improvement", null) != null \
                and GameData.is_no_worker_improvement(target_tile.improvement):
            return false

    assigned_hexes[key] = true
    # Метка профессии ставится АВТОМАТИЧЕСКИ здесь. Игрок не управляет
    # метками напрямую: профессия определяется улучшением, на которое
    # назначен рабочий (см. docs.md, «Профессии и потребление»).
    # Никаких отдельных данных о метке не храним — она производна от
    # улучшения и автоматически снимается при remove_worker().
    consumption_timers.erase(key) # свежий старт таймера потребления
    CityData.idle_population -= 1
    emit_signal("assignment_changed")
    return true

func remove_worker(row: int, col: int):
    var key = str(row) + "," + str(col)
    if assigned_hexes.has(key):
        assigned_hexes.erase(key)
        # Метка профессии снимается АВТОМАТИЧЕСКИ вместе со снятием рабочего
        # (она была производной от улучшения, см. assign_worker).
        # Сбрасываем таймер потребления, чтобы при повторном назначении
        # отсчёт начался заново, а не с «остатка» прошлой смены.
        consumption_timers.erase(key)
        CityData.idle_population += 1
        emit_signal("assignment_changed")

func has_worker(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    return assigned_hexes.has(key)

func get_assigned_count() -> int:
    return assigned_hexes.size()

# Профессия рабочего на гексе (row, col). Возвращает id профессии по улучшению,
# на которое он назначен, или "", если рабочего нет / улучшение без профессии.
# Используется тултипом и панелью для отображения «Профессия: …».
func get_profession(row: int, col: int) -> String:
    if not has_worker(row, col):
        return ""
    var main_map = get_parent()
    if main_map == null:
        return ""
    var tile = main_map.tile_data[row][col]
    if tile == null:
        return ""
    var imp = tile.get("improvement")
    if imp == null:
        return ""
    return GameData.get_profession_for_improvement(imp)

# Возвращает таймер потребления для гекса, при необходимости инициализируя
# его по профессии рабочего. elapsed — сколько секунд прошло с последнего
# списания (или с момента назначения), interval — с каким интервалом
# производится списание (берётся из потребления профессии).
# Если на гексе нет рабочего или у его профессии нет потребления —
# возвращает { "active": false }.
func get_consumption_timer(row: int, col: int) -> Dictionary:
    var key = str(row) + "," + str(col)
    if not has_worker(row, col):
        return {"active": false}
    var prof = get_profession(row, col)
    if prof.is_empty():
        return {"active": false}
    var cons_list = GameData.get_profession_consumption(prof)
    if cons_list.is_empty():
        return {"active": false}
    # Если у профессии несколько потребителей с разными интервалами,
    # берём минимальный — он определяет ритм списания.
    var min_interval := 1e9
    for entry in cons_list:
        var iv = float(entry.get("interval", 0))
        if iv > 0 and iv < min_interval:
            min_interval = iv
    if min_interval >= 1e9:
        return {"active": false}
    if not consumption_timers.has(key):
        consumption_timers[key] = {"elapsed": 0.0, "interval": min_interval}
    return {"active": true, "elapsed": consumption_timers[key].elapsed, "interval": min_interval}

# Двигает таймер потребления на delta секунд и возвращает итоговый множитель
# производства для этого гекса. Логика:
#   * Если у профессии нет потребления — возвращает 1.0 (без бонуса, без
#     изменений для остальной системы).
#   * На каждом вызове проверяет, хватает ли на складе ВСЕХ требуемых
#     продуктов. Пока хватает — множитель = 1.0 + production_bonus
#     (например, 1.5 при бонусе 0.5). Как только хоть одного не стало —
#     множитель откатывается к 1.0, улучшение продолжает работать на базе.
#   * Каждые interval секунд (для тростниковых лодок — раз в 10 сек) при
#     наличии ресурса списывает amount единиц со склада и сбрасывает таймер.
#     Для групповых записей списывается любой подходящий продукт группы:
#     сначала запас суммируется по всем членам, затем расходуется жадно
#     (приоритет качества «best»).
#     Если ресурса нет — таймер НЕ сбрасывается; при появлении ресурса
#     списание произойдёт сразу, без ожидания полного интервала.
# Улучшение НИКОГДА не «встаёт»: оно всегда даёт хотя бы базовое
# производство. Бонус — надбавка за снабжение профессии расходниками.
func tick_consumption(row: int, col: int, delta: float) -> float:
    var key = str(row) + "," + str(col)
    if not has_worker(row, col):
        return 1.0
    var prof = get_profession(row, col)
    if prof.is_empty():
        return 1.0
    var cons_list = GameData.get_profession_consumption(prof)
    if cons_list.is_empty():
        return 1.0

    # Считаем минимальный interval (для нескольких потребителей с разной
    # частотой берём самый частый — он определяет ритм таймера).
    # И суммарный production_bonus: у одной профессии может быть несколько
    # потребителей с разными бонусами, в этом случае применяем максимальный
    # (бонусы не складываются — это сознательное упрощение баланса).
    var min_interval := 1e9
    var max_bonus := 0.0
    for entry in cons_list:
        var iv = float(entry.get("interval", 0))
        if iv > 0 and iv < min_interval:
            min_interval = iv
        var b = float(entry.get("production_bonus", 0.0))
        if b > max_bonus:
            max_bonus = b
    if min_interval >= 1e9:
        return 1.0

    if not consumption_timers.has(key):
        consumption_timers[key] = {"elapsed": 0.0, "interval": min_interval}

    var timer: Dictionary = consumption_timers[key]
    timer.elapsed += delta

    # Проверяем наличие всех требуемых ресурсов КАЖДЫЙ тик, чтобы бонус
    # корректно включался/отключался при колебаниях запасов на складе.
    # Групповые записи (is_group) проверяются по суммарному запасу всех
    # членов группы — потребляется любой подходящий продукт из набора.
    var can_consume := true
    for entry in cons_list:
        var amt = int(entry.get("amount", 0))
        if amt <= 0:
            continue
        if entry.get("is_group", false):
            var members: Array = entry.get("group_members", [])
            if members.is_empty():
                can_consume = false
                break
            var total := 0
            for pid in members:
                total += CityData.get_storage_amount(pid)
                if total >= amt:
                    break
            if total < amt:
                can_consume = false
                break
        else:
            var pid = str(entry.get("product_id", ""))
            if pid == "":
                continue
            if CityData.get_storage_amount(pid) < amt:
                can_consume = false
                break

    # Момент списания. Если ресурса хватает — списываем и сбрасываем таймер.
    # Если не хватает — НЕ списываем, таймер сохраняем (при появлении
    # ресурса спишем сразу, не дожидаясь полного интервала).
    if timer.elapsed >= min_interval:
        if can_consume:
            for entry in cons_list:
                var amt = int(entry.get("amount", 0))
                if amt <= 0:
                    continue
                if entry.get("is_group", false):
                    # Списание из группы: жадное заполнение остатка по членам
                    # группы (как при расходовании групповых рецептов в крафте).
                    # Приоритет качества — «best» (как у одиночных продуктов).
                    var remaining = amt
                    for pid in entry.get("group_members", []):
                        if remaining <= 0:
                            break
                        var avail = CityData.get_storage_amount(pid)
                        if avail <= 0:
                            continue
                        var take = min(avail, remaining)
                        CityData.remove_from_storage(pid, take, "best")
                        remaining -= take
                else:
                    var pid = str(entry.get("product_id", ""))
                    if pid == "":
                        continue
                    CityData.remove_from_storage(pid, amt, "best")
            timer.elapsed = 0.0
        # else: таймер остаётся как есть, на следующем тике проверим снова

    consumption_timers[key] = timer
    return 1.0 + (max_bonus if can_consume else 0.0)

# Сериализация таймеров потребления для сохранения.
# Формат: [{ "row": int, "col": int, "elapsed": float }, ...]
# interval не сохраняем — он вычисляется из профессии при загрузке.
func serialize_consumption_timers() -> Array:
    var result = []
    for key in consumption_timers.keys():
        var parts = key.split(",", false)
        if parts.size() == 2:
            result.append({
                "row": int(parts[0]),
                "col": int(parts[1]),
                "elapsed": float(consumption_timers[key].get("elapsed", 0.0))
            })
    return result

func load_consumption_timers(timers: Array):
    consumption_timers.clear()
    for item in timers:
        if item is Dictionary and item.has("row") and item.has("col"):
            var row = int(item.get("row", -1))
            var col = int(item.get("col", -1))
            if row >= 0 and col >= 0:
                consumption_timers[str(row) + "," + str(col)] = {
                    "elapsed": float(item.get("elapsed", 0.0))
                }

func serialize_assignments() -> Array:
    var result = []
    for key in assigned_hexes.keys():
        var parts = key.split(",", false)
        if parts.size() == 2:
            result.append({"row": int(parts[0]), "col": int(parts[1])})
    return result

func load_assignments(assignments: Array):
    assigned_hexes.clear()
    var main_map = get_parent()
    for item in assignments:
        if item is Dictionary and item.has("row") and item.has("col"):
            var row = int(item.get("row", -1))
            var col = int(item.get("col", -1))
            if row >= 0 and col >= 0:
                if main_map and row < main_map.map_rows and col < main_map.map_cols:
                    # Миграция старых сохранений: в сейвах, сделанных до поля
                    # "no_worker", на пристань мог быть назначен рабочий.
                    # Такие назначения недопустимы — отбрасываем их (житель
                    # вернётся в свободные при пересчёте idle_population).
                    var load_tile = main_map.tile_data[row][col]
                    if load_tile != null and load_tile.get("improvement", null) != null \
                            and GameData.is_no_worker_improvement(load_tile.improvement):
                        continue
                    assigned_hexes[str(row) + "," + str(col)] = true
    emit_signal("assignment_changed")
