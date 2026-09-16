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

# Таймеры ГОРОДСКОГО потребления псевдо-профессии "all" (все жители города).
# Ключ — display_key записи потребления ("@fruits" для группы, id продукта
# для одиночного), значение { "elapsed": float }. Эти таймеры живут отдельно
# от consumption_timers (те привязаны к гексам "row,col"): потребление "all"
# не привязано к улучшениям и списывается поголовно по CityData.total_population.
var city_consumption_timers: Dictionary = {}

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
            # Имя профессии — источник расхода в тултипе ресурсов («Рыбак» и т.п.).
            var prof_source = GameData.professions.get(prof, {}).get("name", prof)
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
                        CityData.record_consumption_source(pid, prof_source, take)
                        # Фактическое потребление на внутреннем рынке даёт доход в казну
                        CityData.add_treasury(CityData.get_internal_market_price(pid) * take)
                        remaining -= take
                else:
                    var pid = str(entry.get("product_id", ""))
                    if pid == "":
                        continue
                    CityData.remove_from_storage(pid, amt, "best")
                    CityData.record_consumption_source(pid, prof_source, amt)
                    # Фактическое потребление на внутреннем рынке даёт доход в казну.
                    CityData.add_treasury(CityData.get_internal_market_price(pid) * amt)
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

# --- ГОРОДСКОЕ ПОТРЕБЛЕНИЕ (псевдо-профессия "all", все жители города) ---
# Профессия "all" (data/professions.json) — вершина иерархии: покрывает ВСЕХ
# жителей, включая занятых на улучшениях и в зданиях. Её потребление не
# привязано к гексам, поэтому тикает общим городским таймером, а записи
# берутся из того же реестра: GameData.get_profession_consumption("all").
#
# Семантика amount для "all": НА ОДНОГО жителя. Суммарное списание за тик =
# amount * CityData.total_population. Списание идёт ПО ФАКТУ НАЛИЧИЯ: за
# попытку списывается min(есть на складе, нужное количество) — ожидания
# полного покрытия нет. Если на складе меньше нужного, списывается всё, что
# есть, и таймер сбрасывается; если склад пуст — таймер сохраняется
# «горячим», и всё, что появится, списывается на ближайшем тике без ожидания
# полного интервала. Жадное списание из @-группы — как в tick_consumption().
# production_bonus игнорируется: городское потребление бонусов не даёт.
# Вызывается из main_map._process в production-тике с шагом
# CityData.PRODUCTION_INTERVAL (та же точность, что у по-гексового потребления).
func tick_city_consumption(delta: float) -> void:
    var cons_list = GameData.get_profession_consumption("all")
    var all_source = GameData.professions.get("all", {}).get("name", "all")
    if cons_list.is_empty():
        return
    for entry in cons_list:
        var iv = float(entry.get("interval", 0))
        if iv <= 0:
            continue
        var dkey = str(entry.get("display_key", ""))
        if dkey.is_empty():
            continue
        if not city_consumption_timers.has(dkey):
            city_consumption_timers[dkey] = {"elapsed": 0.0}
        var timer: Dictionary = city_consumption_timers[dkey]
        timer.elapsed += delta
        if timer.elapsed < iv:
            continue

        # Сколько нужно списать за тик: amount — на одного жителя.
        var amt = int(entry.get("amount", 0)) * CityData.total_population
        if amt <= 0:
            timer.elapsed = 0.0
            continue

        if entry.get("is_group", false):
            var members: Array = entry.get("group_members", [])
            if members.is_empty():
                continue
            var total := 0
            for pid in members:
                total += CityData.get_storage_amount(pid)
            if total <= 0:
                continue # склад пуст — таймер не сбрасываем: спишем сразу при появлении
            # Жадное списание по членам группы (приоритет "best") ПО ФАКТУ
            # НАЛИЧИЯ: берём всё, что есть, но не больше нужного. Ждать полного
            # покрытия (amount * население) не требуется — частичное списание
            # тоже происходит (и сбрасывает таймер, см. timer.elapsed ниже).
            var remaining = amt
            for pid in members:
                if remaining <= 0:
                    break
                var avail = CityData.get_storage_amount(pid)
                if avail <= 0:
                    continue
                var take = min(avail, remaining)
                CityData.remove_from_storage(pid, take, "best")
                CityData.record_consumption_source(pid, all_source, take)
                # Горожане платят за потреблённый товар из казны (внутренний рынок).
                CityData.add_treasury(CityData.get_internal_market_price(pid) * take)
                remaining -= take
        else:
            var pid = str(entry.get("product_id", ""))
            if pid.is_empty():
                continue
            var have = CityData.get_storage_amount(pid)
            if have <= 0:
                continue # склад пуст — таймер не сбрасываем: спишем сразу при появлении
            # По факту наличия: списываем всё, что есть, но не больше нужного.
            var take = min(have, amt)
            CityData.remove_from_storage(pid, take, "best")
            CityData.record_consumption_source(pid, all_source, take)
            # Горожане платят за потреблённый товар из казны (внутренний рынок).
            CityData.add_treasury(CityData.get_internal_market_price(pid) * take)
        timer.elapsed = 0.0

# Сериализация таймеров городского потребления для сохранения.
# Формат: [{ "resource": String, "elapsed": float }, ...]
# interval не сохраняем — он вычисляется из данных при загрузке.
func serialize_city_consumption_timers() -> Array:
    var result = []
    for dkey in city_consumption_timers.keys():
        result.append({
            "resource": dkey,
            "elapsed": float(city_consumption_timers[dkey].get("elapsed", 0.0))
        })
    return result

func load_city_consumption_timers(timers: Array):
    city_consumption_timers.clear()
    for item in timers:
        if item is Dictionary and item.has("resource"):
            var dkey = str(item.get("resource", ""))
            if not dkey.is_empty():
                city_consumption_timers[dkey] = {
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

# --- ПЛАНОВОЕ ПОТРЕБЛЕНИЕ РЕСУРСОВ ---
# Для вкладки «Ресурсы»: тултип (блок «Потребление (плановое)») и динамика с
# маркером «≈». Показывает, сколько ресурса БУДЕТ списано текущими
# потребителями, независимо от фазы таймеров потребления и наличия на складе.
# Фактические счётчики (CityData.consumption_rates/sources) живут один
# production-тик и наполняются только в момент списания — отсюда «слепые
# окна» у интервального потребления (лодки: 10 шт. раз в 10 сек).

# Число рабочих по профессиям: prof_id -> count. Один проход по назначенным
# гексам; профессия производна от улучшения (см. get_profession).
func count_workers_by_profession() -> Dictionary:
    var result: Dictionary = {}
    for key in assigned_hexes.keys():
        var parts = key.split(",", false)
        if parts.size() != 2:
            continue
        var prof = get_profession(int(parts[0]), int(parts[1]))
        if prof.is_empty():
            continue
        result[prof] = int(result.get(prof, 0)) + 1
    return result

# Собирает полную карту планового потребления:
#   product_id -> { "Имя источника" -> { "amount": int, "interval": float,
#                  "count": int, "is_group": bool, "group_name": String,
#                  "is_population": bool } }
# Источники:
#   1) профессиональное потребление (data/consumption.json и устаревшее
#      products[*].consumption): amount каждой записи × число рабочих профессии;
#      при нескольких записях одного источника amount суммируется, а interval
#      берётся минимальный — ровно так списывает tick_consumption (все записи
#      списка разом по минимальному интервалу);
#   2) городское потребление «all»: amount × total_population (is_population);
#   3) спрос построенных зданий (рецепты слотов,
#      CityData.get_building_planned_consumption): amount — спрос за один крафт,
#      interval — время крафта рецепта (`time`), см. CityData.get_craft_time.
# Для групповых записей план относится к ЛЮБОМУ члену группы; в тултипе такие
# строки помечаются именем группы (group_name = имя группы из данных).
func get_planned_consumption_map() -> Dictionary:
    var result: Dictionary = {}
    # Профессиональное потребление: по фактическим рабочим на улучшениях.
    var workers = count_workers_by_profession()
    for prof_id in workers:
        if prof_id == "all":
            continue # псевдо-профессия не назначается на гексы; обрабатывается ниже
        _record_profession_planned(result, prof_id, int(workers[prof_id]), false)
    # Городское потребление «Все жители» — всегда (население ≥ 1), поголовно:
    # count = total_population, а не число назначенных гексов.
    if CityData.total_population > 0:
        _record_profession_planned(result, "all", CityData.total_population, true)
    # Спрос зданий (рецепты): amount — за один крафт, interval — время рецепта.
    var building_demand = CityData.get_building_planned_consumption()
    for pid in building_demand:
        for source_name in building_demand[pid]:
            var e: Dictionary = building_demand[pid][source_name]
            _record_planned_entry(result, str(pid), str(source_name), int(e.get("amount", 0)), float(e.get("interval", 0.0)), int(e.get("count", 1)), bool(e.get("is_group", false)), str(e.get("group_name", "")), false)
    return result

# Записывает в result плановое потребление профессии prof_id при count
# потребителях. Для псевдо-профессии «all» count = население города и
# is_population = true (тултип показывает «(N чел.)»).
func _record_profession_planned(result: Dictionary, prof_id: String, count: int, is_population: bool):
    if count <= 0:
        return
    var source_name: String = GameData.professions.get(prof_id, {}).get("name", prof_id)
    for entry in GameData.get_profession_consumption(prof_id):
        var amount = int(entry.get("amount", 0)) * count
        if amount <= 0:
            continue
        var interval = float(entry.get("interval", 0))
        var is_group: bool = entry.get("is_group", false)
        var targets: Array = entry.get("group_members", []) if is_group else [entry.get("product_id", "")]
        var group_name: String = str(entry.get("product_name", "")) if is_group else ""
        for pid in targets:
            if str(pid).is_empty():
                continue
            _record_planned_entry(result, str(pid), source_name, amount, interval, count, is_group, group_name, is_population)

# Хелпер записи/агрегации планового потребления (см. get_planned_consumption_map).
func _record_planned_entry(result: Dictionary, pid: String, source_name: String, amount: int, interval: float, count: int, is_group: bool, group_name: String, is_population: bool):
    if not result.has(pid):
        result[pid] = {}
    var by_source: Dictionary = result[pid]
    if not by_source.has(source_name):
        by_source[source_name] = {"amount": 0, "interval": interval, "count": 0, "is_group": false, "group_name": "", "is_population": false}
    var entry: Dictionary = by_source[source_name]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)
    entry["count"] = maxi(int(entry.get("count", 0)), count)
    entry["is_group"] = bool(entry.get("is_group", false)) or is_group
    if str(entry.get("group_name", "")) == "":
        entry["group_name"] = group_name
    entry["is_population"] = bool(entry.get("is_population", false)) or is_population
