# worker_manager.gd
extends Node

signal assignment_changed()

var assigned_hexes = {}

# Sub-unit accumulator для НЕПРЕРЫВНОГО профессионального потребления,
# ключ — "row,col". Значение: { "fractional": { dkey: float, ... } } —
# дробные остатки потребления по каждой записи потребления профессии (dkey —
# id продукта или "@id_группы"). Раньше здесь лежал пакетный таймер
# { "elapsed", "interval" }, списывавший amount единиц раз в interval секунд;
# в continuous-модели каждый тик забираем amount / interval единиц (с
# дробным остатком для целочисленной точности), см. tick_consumption().
var consumption_timers: Dictionary = {}

# То же для профессий ГОРОДСКИХ ЗДАНИЙ (поле "profession" в buildings.json):
# ключ — "b<индекс здания>". Индексы зданий стабильны (сноса нет, апгрейд
# сохраняет индекс), поэтому ключ не «плывёт». Словарь отдельный: формат
# ключей "row,col" по-гексовых таймеров и их сериализация не меняются.
# См. tick_building_consumption().
var building_consumption_timers: Dictionary = {}

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
            if improvement == null or bool(tile.get("decorative", false)):
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
        if target_tile != null and bool(target_tile.get("decorative", false)):
            return false
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
# Метка производна от улучшения и отдельной строкой «Профессия» в интерфейсе
# не выводится: используется расчётом потребления и плановой картой вкладки
# «Ресурсы» (имя профессии — источник расхода).
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

# Двигает таймер потребления гекса на delta секунд и возвращает итоговый
# множитель производства. Ядро логики общее со зданиями —
# _tick_profession_consumption (подробности у него):
#   * Если у профессии нет потребления — возвращает 1.0 (без бонуса, без
#     изменений для остальной системы).
#   * На каждом вызове проверяет, хватает ли на складе ВСЕХ требуемых
#     продуктов. Пока хватает — множитель = 1.0 + production_bonus
#     (например, 1.5 при бонусе 0.5). Как только хоть одного не стало —
#     множитель откатывается к 1.0, улучшение продолжает работать на базе.
#   * Списание непрерывное: amount / interval единиц в секунду (дробные
#     остатки копятся в sub-unit аккумуляторе). Для групповых записей
#     списывается любой подходящий продукт группы — жадно по членам
#     (приоритет качества «best»). Если ресурса нет — таймер не сбрасывается,
#     при появлении ресурса списание произойдёт сразу.
#   * Бонусы одиночных записей профессии складываются, у групповых берётся
#     лучший доступный (см. _aggregate_production_bonus).
# Улучшение НИКОГДА не «встаёт»: оно всегда даёт хотя бы базовое
# производство. Бонус — надбавка за снабжение профессии расходниками.
func tick_consumption(row: int, col: int, delta: float) -> float:
    if not has_worker(row, col):
        return 1.0
    var prof = get_profession(row, col)
    if prof.is_empty():
        return 1.0
    return _tick_profession_consumption(prof, str(row) + "," + str(col), consumption_timers, delta)

# Профессия горожанина в городском здании (поле "profession" в
# data/buildings.json). Пустая строка — профессии у здания нет.
func get_building_profession(b_index: int) -> String:
    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return ""
    var bld_id := str(CityData.city_built_buildings[b_index].get("id", ""))
    return GameData.get_profession_for_building(bld_id)

# Потребление и бонус профессии горожанина в здании: та же механика, что у
# гекса (tick_consumption), но таймеры живут в отдельном словаре
# building_consumption_timers, а ключ — "b<индекс здания>". Индексы зданий
# стабильны (сноса нет, апгрейд сохраняет индекс), поэтому ключ не «плывёт».
# Вызывается из CityData.do_tick() только для РАБОТАЮЩЕГО здания (есть
# горожанин и хотя бы один непустой слот): простаивающее здание расходники
# не тратит.
func tick_building_consumption(b_index: int, delta: float) -> float:
    var prof = get_building_profession(b_index)
    if prof.is_empty():
        return 1.0
    return _tick_profession_consumption(prof, "b" + str(b_index), building_consumption_timers, delta)

# Итоговый множитель производства профессии горожанина в здании БЕЗ расхода и
# движения таймеров — для планового производства
# (CityData.get_building_planned_production), чтобы метка «≈» совпадала с
# фактом. 1.0 — у здания нет профессии либо расходников не хватает.
func get_building_production_bonus(b_index: int) -> float:
    var prof = get_building_profession(b_index)
    if prof.is_empty():
        return 1.0
    return 1.0 + _aggregate_production_bonus(GameData.get_profession_consumption(prof))

# Суммарный production_bonus профессии по доступным расходникам:
#   * ОДИНОЧНЫЕ записи — каждая доступная добавляет свой бонус (складываются):
#     перья +25% и чернила +25% → +50%;
#   * ГРУППОВЫЕ записи — только максимальный из доступных: группа «Лодки»
#     даёт бонус от лучшего доступного члена группы, а не ото всех сразу.
# «Доступна» — на складе хватает полной пачки amount (см. _can_consume_full).
func _aggregate_production_bonus(cons_list: Array) -> float:
    var group_max := 0.0
    var single_sum := 0.0
    for entry in cons_list:
        var b := float(entry.get("production_bonus", 0.0))
        if b <= 0.0:
            continue
        if not _can_consume_full(entry, int(entry.get("amount", 0))):
            continue
        if entry.get("is_group", false):
            group_max = maxf(group_max, b)
        else:
            single_sum += b
    return group_max + single_sum

# Общее ядро профессионального потребления: двигает sub-unit аккумуляторы
# переданного словаря таймеров (timers), списывает ресурсы со склада и
# возвращает множитель производства (1.0 — без бонуса).
#   * На каждом вызове проверяет, хватает ли на складе ВСЕХ требуемых
#     продуктов. Пока хватает — множитель = 1.0 + production_bonus
#     (см. _aggregate_production_bonus). Как только хоть одного не стало —
#     множитель откатывается к 1.0, объект продолжает работать на базе.
#   * Per-second скорость потребления = amount / interval: каждый тик
#     накапливается дробный остаток, целая часть списывается со склада.
#     Для групповых записей списывается любой подходящий продукт группы:
#     сначала запас суммируется по всем членам, затем расходуется жадно
#     (приоритет качества «best»). Если ресурса нет — таймер НЕ сбрасывается;
#     при появлении ресурса списание произойдёт сразу.
# Объект НИКОГДА не «встаёт»: он всегда даёт хотя бы базовое производство.
# Бонус — надбавка за снабжение профессии расходниками.
func _tick_profession_consumption(prof: String, key: String, timers: Dictionary, delta: float) -> float:
    var cons_list = GameData.get_profession_consumption(prof)
    if cons_list.is_empty():
        return 1.0

    # Имя профессии — источник расхода в тултипе ресурсов («Рыбак» и т.п.).
    var prof_source = GameData.professions.get(prof, {}).get("name", prof)

    # --- НЕПРЕРЫВНОЕ ПРОФЕССИОНАЛЬНОЕ ПОТРЕБЛЕНИЕ ---
    # Вместо пакетного списания раз в `interval` секунд — каждый тик забираем
    # amount / interval единиц (с sub-unit accumulator). Раньше потребление
    # было дискретным: при amount=10, interval=10 списание происходило раз в
    # 10 секунд пачкой 10 штук, из-за чего инвентарь игрока мог «скакать»
    # (на тике списания −10, всё остальное время −0). В continuous-модели
    # списание идёт равномерно: −1 каждый тик — склад уменьшается плавно,
    # производственный бонус включается/выключается плавно при колебаниях
    # запасов. Это согласуется с производством ресурсов (фермы/шахты/мастерские),
    # которые тоже переведены на непрерывный выпуск.
    #
    # can_consume определяется по ПОЛНОЙ пачке amount (как раньше) — бонус
    # включается только когда хватает ресурса на целый цикл. Если хватает
    # только частично — списываем сколько есть, бонус НЕ начисляется.
    if not timers.has(key):
        timers[key] = {"fractional": {}}

    var fractional: Dictionary = timers[key].fractional

    for entry in cons_list:
        var amt: int = int(entry.get("amount", 0))
        var interval: float = float(entry.get("interval", 0))
        if amt <= 0 or interval <= 0.0:
            continue

        # Per-second скорость потребления = amt / interval. Каждый тик
        # накапливаем дробный остаток.
        var per_tick: float = float(amt) / interval * delta
        var frac_key: String = _fractional_key(entry)
        var cur_frac: float = float(fractional.get(frac_key, 0.0)) + per_tick
        var floor_take: int = int(floor(cur_frac))
        if floor_take <= 0:
            fractional[frac_key] = cur_frac
            continue

        cur_frac -= float(floor_take)
        fractional[frac_key] = cur_frac

        if entry.get("is_group", false):
            # Списание из группы: жадно по членам (best-качество).
            var remaining: int = floor_take
            for member_pid in entry.get("group_members", []):
                if remaining <= 0:
                    break
                var avail: int = CityData.get_storage_amount(member_pid)
                if avail <= 0:
                    continue
                var take: int = mini(avail, remaining)
                if take <= 0:
                    continue
                var member_consumed: Dictionary = CityData.remove_from_storage(member_pid, take, "best")
                CityData.record_consumption_source(member_pid, prof_source, take)
                # Фактическое потребление на внутреннем рынке даёт доход в казну.
                # Цена — по качеству КАЖДОЙ списанной единицы: разбивка consumed
                # приходит из remove_from_storage (см. docs.md, «Казна города и
                # внутренний рынок»).
                var member_take_price: int = CityData.get_internal_market_income(member_pid, member_consumed)
                CityData.add_treasury(member_take_price)
                # Источник дохода для тултипа «Казна» по тому же ключу,
                # что и в плановой карте (имя профессии, напр. «Рыбак»).
                CityData.record_treasury_income(prof_source, member_take_price, str(member_pid))
                remaining -= take
        else:
            var pid: String = str(entry.get("product_id", ""))
            if pid.is_empty():
                continue
            var avail_single: int = CityData.get_storage_amount(pid)
            if avail_single <= 0:
                continue
            var take_single: int = mini(avail_single, floor_take)
            if take_single <= 0:
                continue
            var single_consumed: Dictionary = CityData.remove_from_storage(pid, take_single, "best")
            CityData.record_consumption_source(pid, prof_source, take_single)
            # Цена — по качеству каждой списанной единицы (см. выше).
            var single_take_price: int = CityData.get_internal_market_income(pid, single_consumed)
            CityData.add_treasury(single_take_price)
            # Источник дохода для тултипа «Казна» по тому же ключу,
            # что и в плановой карте (имя профессии, напр. «Рыбак»).
            CityData.record_treasury_income(prof_source, single_take_price, pid)

    timers[key].fractional = fractional
    return 1.0 + _aggregate_production_bonus(cons_list)

# Проверяет, хватает ли ресурса на полный цикл потребления для одной записи.
# Для групп — суммарно по всем членам группы.
func _can_consume_full(entry: Dictionary, amt: int) -> bool:
    if amt <= 0:
        return false
    if entry.get("is_group", false):
        var members: Array = entry.get("group_members", [])
        if members.is_empty():
            return false
        var total: int = 0
        for pid in members:
            total += CityData.get_storage_amount(pid)
            if total >= amt:
                return true
        return total >= amt
    var pid := str(entry.get("product_id", ""))
    if pid.is_empty():
        return false
    return CityData.get_storage_amount(pid) >= amt

# Ключ для fractional-аккумулятора по типу ресурса (одиночный/группа).
# Один аккумулятор на запись потребления.
func _fractional_key(entry: Dictionary) -> String:
    if entry.get("is_group", false):
        return "@" + str(entry.get("display_key", ""))
    return str(entry.get("product_id", entry.get("display_key", "")))

# Сериализация таймеров потребления для сохранения.
# Формат: [{ "row": int, "col": int, "fractional": { dkey: float, ... } }, ...]
# Дробные остатки накапливаются по dkey (id продукта или @-группа) — после
# перевода на continuous-модель хранить нечего, кроме них (новые правила
# amount/interval вычисляются из профессии при загрузке).
func serialize_consumption_timers() -> Array:
    var result = []
    for key in consumption_timers.keys():
        var parts = key.split(",", false)
        if parts.size() == 2:
            result.append({
                "row": int(parts[0]),
                "col": int(parts[1]),
                "fractional": (consumption_timers[key].get("fractional", {}) as Dictionary).duplicate(true)
            })
    return result

func load_consumption_timers(timers: Array):
    consumption_timers.clear()
    for item in timers:
        if item is Dictionary and item.has("row") and item.has("col"):
            var row = int(item.get("row", -1))
            var col = int(item.get("col", -1))
            if row >= 0 and col >= 0:
                var frac_raw = item.get("fractional", {})
                var frac: Dictionary = frac_raw if frac_raw is Dictionary else {}
                consumption_timers[str(row) + "," + str(col)] = {
                    "fractional": frac
                }

# Сериализация таймеров потребления зданий (см. building_consumption_timers).
# Формат: [{ "index": int, "fractional": { dkey: float, ... } }, ...]
func serialize_building_consumption_timers() -> Array:
    var result = []
    for key in building_consumption_timers.keys():
        var k := str(key)
        if not k.begins_with("b"):
            continue
        result.append({
            "index": int(k.substr(1)),
            "fractional": (building_consumption_timers[key].get("fractional", {}) as Dictionary).duplicate(true)
        })
    return result

func load_building_consumption_timers(timers: Array):
    building_consumption_timers.clear()
    for item in timers:
        if item is Dictionary and item.has("index"):
            var idx = int(item.get("index", -1))
            if idx >= 0:
                var frac_raw = item.get("fractional", {})
                var frac: Dictionary = frac_raw if frac_raw is Dictionary else {}
                building_consumption_timers["b" + str(idx)] = {
                    "fractional": frac
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
# Вызывается из main_map._process в тике симуляции с шагом
# CityData.SIMULATION_TICK (та же точность, что у по-гексового потребления).
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
                var group_consumed: Dictionary = CityData.remove_from_storage(pid, take, "best")
                CityData.record_consumption_source(pid, all_source, take)
                # Горожане платят за потреблённый товар из казны (внутренний рынок).
                # Цена — по качеству каждой списанной единицы.
                var group_take_price: int = CityData.get_internal_market_income(pid, group_consumed)
                CityData.add_treasury(group_take_price)
                # Источник дохода для тултипа «Казна» (городское потребление,
                # имя берётся из data/professions.json → «Все жители»).
                CityData.record_treasury_income(all_source, group_take_price, str(pid))
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
            var city_consumed: Dictionary = CityData.remove_from_storage(pid, take, "best")
            CityData.record_consumption_source(pid, all_source, take)
            # Горожане платят за потреблённый товар из казны (внутренний рынок).
            # Цена — по качеству каждой списанной единицы.
            var city_take_price: int = CityData.get_internal_market_income(pid, city_consumed)
            CityData.add_treasury(city_take_price)
            # Источник дохода для тултипа «Казна» (городское потребление).
            CityData.record_treasury_income(all_source, city_take_price, pid)
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
                    if load_tile != null and bool(load_tile.get("decorative", false)):
                        continue
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
#   1) профессиональное потребление рабочих на улучшениях и горожан в
#      зданиях (data/consumption.json и устаревшее products[*].consumption):
#      amount каждой записи × число рабочих/горожан профессии; для зданий
#      учитываются только РАБОТАЮЩИЕ (есть горожанин и непустой слот) —
#      CityData.get_townsfolk_professions_count;
#      при нескольких записях одного источника amount суммируется, а interval
#      берётся минимальный — ровно так списывает tick_consumption (все записи
#      списка разом по минимальному интервалу);
#   2) городское потребление «all»: amount × total_population (is_population);
#   3) спрос построенных зданий (рецепты слотов,
#      CityData.get_building_planned_consumption): amount — спрос за один крафт,
#      interval — время крафта рецепта (`time`), см. CityData.get_craft_time.
# Для групповых записей план относится к ЛЮБОМУ члену группы; в тултипе такие
# строки помечаются именем группы (group_name = имя группы из данных).
func get_planned_consumption_map(include_production_inputs: bool = true) -> Dictionary:
    var result: Dictionary = {}
    # Профессиональное потребление: по фактическим рабочим на улучшениях.
    var workers = count_workers_by_profession()
    for prof_id in workers:
        if prof_id == "all":
            continue # псевдо-профессия не назначается на гексы; обрабатывается ниже
        _record_profession_planned(result, prof_id, int(workers[prof_id]), false)
    # Профессиональное потребление городских зданий: профессия горожанина
    # (поле "profession" в data/buildings.json). Учитываются только РАБОТАЮЩИЕ
    # здания — есть горожанин и хотя бы один непустой слот: расходники
    # простаивающего здания в план не попадают (см. get_townsfolk_professions_count).
    var town_workers = CityData.get_townsfolk_professions_count()
    for prof_id in town_workers:
        if prof_id == "all":
            continue # псевдо-профессия не назначается на здания; обрабатывается ниже
        _record_profession_planned(result, prof_id, int(town_workers[prof_id]), false)
    # Городское потребление «Все жители» — всегда (население ≥ 1), поголовно:
    # count = total_population, а не число назначенных гексов.
    if CityData.total_population > 0:
        _record_profession_planned(result, "all", CityData.total_population, true)
    if not include_production_inputs:
        return result
    # Спрос зданий (рецепты): amount — за один крафт, interval — время рецепта.
    var building_demand = CityData.get_building_planned_consumption()
    for pid in building_demand:
        for source_name in building_demand[pid]:
            var e: Dictionary = building_demand[pid][source_name]
            _record_planned_entry(result, str(pid), str(source_name), int(e.get("amount", 0)), float(e.get("interval", 0.0)), int(e.get("count", 1)), bool(e.get("is_group", false)), str(e.get("group_name", "")), false)
    # Плановое потребление улучшений на карте (корм пастбищ): amount — за один
    # цикл производства, interval — production_interval улучшения. Корм
    # списывается за цикл (см. main_map, блок «ЦИКЛ ПРОИЗВОДСТВА УЛУЧШЕНИЯ»),
    # поэтому записи попадают в план наравне со спросом зданий.
    var improvement_demand = CityData.get_improvement_planned_consumption()
    for pid in improvement_demand:
        for source_name in improvement_demand[pid]:
            var e: Dictionary = improvement_demand[pid][source_name]
            _record_planned_entry(result, str(pid), str(source_name), int(e.get("amount", 0)), float(e.get("interval", 0.0)), int(e.get("count", 1)), bool(e.get("is_group", false)), str(e.get("group_name", "")), false)
    return result

# Плановая скорость ДОХОДА казны по ТИПАМ прибыли — для тултипа «Казна»
# в HUD карты и в верхней полосе интерфейса города.
# Аналог «Производство (плановое)» на вкладке «Ресурсы»: равномерный поток,
# не мигает на тиках без списания. Возвращает иерархическую структуру:
#   {
#     "Потребление населения": {              # тип прибыли (top level)
#       "Все жители": {                       # источник (= имя профессии/горожан)
#         "fruit":  { coins_per_sec: 2.5, product_name: "Фрукты" },
#         "salt":   { coins_per_sec: 0.5, product_name: "Соль" }
#       },
#       "Рыбак": {
#         "reed_boat": { coins_per_sec: 1.2, product_name: "Лодки" }
#       }
#     }
#     # будущие типы: "Налоги", "Торговля" — добавляются сюда же отдельной
#     # функцией, чтобы шкала типов расширялась без правки тултипа.
#   }
# Внутри одного «источника» продукты могут повторяться (например, для
# `@boats` группа раскладывается по членам — каждый член отдельным
# pid). Тултип сортирует источники и продукты по убыванию скорости.
#
# Товары без базовой цены (price ≤ 0) исключены: цена внутреннего рынка
# для них = 0 и в прибыли не участвуют.
func get_planned_treasury_income_map() -> Dictionary:
    var result: Dictionary = {}
    _fill_consumption_income(result)
    _fill_tax_income(result)
    return result

# Фактическая скорость дохода казны по источникам и продуктам за последнее
# окно отображения. Если первое окно еще не завершено, используем его текущий
# накопитель, чтобы тултип не был пустым сразу после запуска игры.
# Налоги (тип «Налоги») не зависят от окна: они приходят каждый тик, поэтому
# добавляются всегда — строка налога не пустует и в первом окне после
# старта/загрузки (см. _fill_tax_income).
func get_actual_treasury_income_map() -> Dictionary:
    var product_income: Dictionary = CityData.treasury_income_product_snapshot
    var window_sec := CityData.treasury_window_length_sec
    if product_income.is_empty():
        product_income = CityData.treasury_income_product_accum

    var result: Dictionary = {}
    if not product_income.is_empty() and window_sec > 0.0:
        var income_by_source: Dictionary = {}
        for source_name in product_income:
            var source_products: Dictionary = product_income[source_name]
            for pid in source_products:
                var amount: int = int(source_products[pid])
                if amount <= 0:
                    continue
                if not income_by_source.has(source_name):
                    income_by_source[source_name] = {}
                income_by_source[source_name][pid] = {
                    "coins_per_sec": float(amount) / window_sec,
                    "product_name": GameData.products.get(pid, {}).get("name", pid)
                }
        if not income_by_source.is_empty():
            result["Потребление населения"] = income_by_source
    _fill_tax_income(result)
    return result

# Налоги — второй тип дохода казны («Потребление населения» + «Налоги»).
# Каждый житель платит базовый налог каждый тик, поэтому плановая и
# фактическая скорость совпадают и считаются ОДНИМ выражением из текущего
# населения: CityData.get_tax_income_per_tick() (единый источник истины, там
# же — ставка из data/game_balance.json).
# Формат записи — «плоский» тип (CityData.TREASURY_FLAT_TYPE_KEY): налог пока
# один, раскладывать его по источникам/продуктам не на что, поэтому тултип
# рисует его одной строкой «• Налоги: 2 × 3 чел. = 6 / сек». «label» — правая
# часть до знака «=» (ставка × число плательщиков), скорость форматирует и
# дописывает сам рендер (ui_helpers.show_treasury_tooltip).
func _fill_tax_income(result: Dictionary) -> void:
    var per_tick: int = CityData.get_tax_income_per_tick()
    if per_tick <= 0:
        return
    result[CityData.TAX_INCOME_TYPE] = {
        CityData.TREASURY_FLAT_TYPE_KEY: {
            "rate": float(per_tick) / CityData.SIMULATION_TICK,
            "label": "%d × %d чел." % [
                CityData.get_base_tax_per_citizen(), CityData.total_population
            ]
        }
    }

# Доход от потребления на внутреннем рынке: профессиональное потребление
# рабочих + городское потребление «all». Входы рецептов зданий и улучшений
# сюда не входят: они расходуются производством, а не продаются населением.
# Рыночный доход живёт под типом «Потребление населения»; прочие типы
# («Налоги» — см. _fill_tax_income, «Торговля» и т.п.) добавляются
# параллельно без правки этой функции.
func _fill_consumption_income(result: Dictionary) -> void:
    var income_type := "Потребление населения"
    if not result.has(income_type):
        result[income_type] = {}
    var type_dict: Dictionary = result[income_type]
    var planned := get_planned_consumption_map(false)
    var planned_production := CityData.get_planned_production_map()
    for pid in planned:
        # План — доход по СРЕДНЕМУ качеству того, что реально лежит на складе
        # (CityData.get_stock_quality_price_multiplier): качество будущей
        # сделки неизвестно, а план по обычному качеству занижал бы факт.
        var market_price: int = int(round(
            float(CityData.get_internal_market_price(str(pid)))
            * CityData.get_stock_quality_price_multiplier(str(pid))))
        if market_price <= 0:
            continue
        var product_name: String = GameData.products.get(pid, {}).get("name", pid)
        for source_name in planned[pid]:
            var entry: Dictionary = planned[pid][source_name]
            # Групповое потребление списывается только из реально доступных
            # членов группы. Не показываем в казне остальные члены группы,
            # которые лишь были перечислены при её разворачивании.
            if bool(entry.get("is_group", false)) \
                    and CityData.get_storage_amount(str(pid)) <= 0 \
                    and int(CityData.production_rates.get(pid, 0)) <= 0 \
                    and planned_production.get(pid, {}).is_empty():
                continue
            var amount := float(entry.get("amount", 0))
            var interval := float(entry.get("interval", 0))
            # Per-second потребление записи (см. ui_helpers._planned_per_sec).
            var per_sec: float
            if interval > 0.0:
                per_sec = amount * CityData.SIMULATION_TICK / interval
            else:
                per_sec = amount * CityData.SIMULATION_TICK
            if per_sec <= 0.0:
                continue
            var coins_per_sec: float = per_sec * float(market_price)
            if not type_dict.has(source_name):
                type_dict[source_name] = {}
            var source_dict: Dictionary = type_dict[source_name]
            source_dict[pid] = {"coins_per_sec": coins_per_sec, "product_name": product_name}

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
