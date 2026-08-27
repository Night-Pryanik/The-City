# CityData.gd (Autoload)
@tool
extends Node

# Склад и производство
var city_storage: Dictionary = {}
# Детализация склада по качеству: product_id -> { "common": N, "fine": N, ... }
# Сумма по всем уровням качества всегда равна city_storage[product_id].
var city_quality_detail: Dictionary = {}
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var city_food_pool: Dictionary = {}
var city_built_buildings: Array = []
var domesticated_animals: Array = []
var domesticated_plants: Array = []

# Стройка зданий: ключ -> данные
var building_construction: Dictionary = {}

# Технологии
var unlocked_technologies: Array = []
var current_research_tech_id: String = ""
var current_research_science_cost: int = 0
var research_progress: float = 0.0
var research_science_accumulated: float = 0.0

# Сообщения для HUD после завершения исследования (о найденных ресурсах)
var last_research_messages: Array = []

# --- НАСЕЛЕНИЕ ---
var total_population: int = 1
var idle_population: int = 1 # свободные жители (не занятые нигде)
var food_for_new_settler: int = 100
var food_per_citizen: int = 1

const PRODUCTION_INTERVAL: float = 2.0

# --- ТРУД ---
# Труд = скорость работы города. 1 житель = 1 труд/сек.
# НЕ накапливается, это скорость, не запас.
func get_total_labor() -> float:
    return float(total_population) * 1.0

signal city_updated()
signal research_completed(tech_id: String)
signal research_error(message: String)
signal population_changed(new_population: int)
signal building_construction_started(building_id: String, build_key: String)
signal building_construction_completed(building_id: String, build_key: String)

func setup():
    city_storage.clear()
    city_quality_detail.clear()
    production_rates.clear()
    consumption_rates.clear()
    city_food_pool.clear()
    city_built_buildings.clear()
    building_construction.clear()
    domesticated_animals.clear()
    domesticated_plants.clear()
    unlocked_technologies.clear()
# Растениеводство — всегда открыта при старте игры
    unlocked_technologies.append("farming")
    current_research_tech_id = ""
    current_research_science_cost = 0
    research_progress = 0.0
    research_science_accumulated = 0.0
    last_research_messages = []

    total_population = 1
    idle_population = 1 # один житель, пока нигде не занят

    for pid in GameData.products.keys():
        city_storage[pid] = 0
        city_quality_detail[pid] = {}
        production_rates[pid] = 0
        consumption_rates[pid] = 0
        if GameData.products[pid].get("category") == "food":
            city_food_pool[pid] = true

    if city_storage.has("meat"):
        city_storage["meat"] = 10
        # Стартовое мясо — обычного качества.
        if not city_quality_detail.has("meat"):
            city_quality_detail["meat"] = {}
        city_quality_detail["meat"]["common"] = city_quality_detail["meat"].get("common", 0) + 10

func reset_counters():
    for pid in production_rates.keys():
        production_rates[pid] = 0
        consumption_rates[pid] = 0

# --- ХЕЛПЕРЫ ДЛЯ РАБОТЫ С КАЧЕСТВОМ РЕСУРСОВ ---
# city_storage хранит общее количество, city_quality_detail — разбивку по качеству.
# Все операции добавления/списания должны идти через эти хелперы, чтобы
# сумма по деталям всегда совпадала с city_storage.

# Возвращает разбивку по качеству для продукта (словарь {quality: count}).
# Если разбивки нет (старый сейв), возвращает пустой словарь.
func get_quality_breakdown(pid: String) -> Dictionary:
    return city_quality_detail.get(pid, {})

# Возвращает общее количество продукта на складе.
func get_storage_amount(pid: String) -> int:
    return city_storage.get(pid, 0)

# Добавляет amount единиц продукта pid указанного качества.
# Синхронно обновляет city_storage и city_quality_detail.
func add_to_storage(pid: String, amount: int, quality: String = "common"):
    if amount <= 0:
        return
    city_storage[pid] = city_storage.get(pid, 0) + amount
    if not city_quality_detail.has(pid):
        city_quality_detail[pid] = {}
    var detail: Dictionary = city_quality_detail[pid]
    detail[quality] = detail.get(quality, 0) + amount

# Уменьшает общее количество продукта pid на amount единиц.
# Списывает по приоритету качества (best/worst/random) и возвращает
# разбивку фактически списанного: {quality: count}.
# Если приоритет не указан, используется "best".
func remove_from_storage(pid: String, amount: int, priority: String = "best") -> Dictionary:
    if amount <= 0:
        return {}
    var available = city_storage.get(pid, 0)
    var to_remove = min(amount, available)
    var consumed = _consume_quality_detail(pid, to_remove, priority)
    city_storage[pid] = available - to_remove
    return consumed

# Списывает amount единиц из разбивки по качеству согласно приоритету.
# Возвращает словарь {quality: count} фактически списанного.
func _consume_quality_detail(pid: String, amount: int, priority: String) -> Dictionary:
    var detail: Dictionary = city_quality_detail.get(pid, {})
    if detail.is_empty():
        # Нет разбивки (старый сейв) — считаем всё "common".
        return {"common": amount}

    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return {"common": amount}

    var consumed = {}
    var remaining = amount

    # Определяем порядок списания уровней качества.
    var order = []
    if priority == "worst":
        order = levels.duplicate() # от худшего к лучшему
    elif priority == "random":
        order = levels.duplicate()
        order.shuffle()
    else: # "best" и по умолчанию — от лучшего к худшему
        order = levels.duplicate()
        order.reverse()

    for qid in order:
        if remaining <= 0:
            break
        var available = detail.get(qid, 0)
        if available <= 0:
            continue
        var take = min(available, remaining)
        detail[qid] = available - take
        consumed[qid] = consumed.get(qid, 0) + take
        remaining -= take

    # Если осталось (например, разбивка неполная) — списываем как common.
    if remaining > 0:
        consumed["common"] = consumed.get("common", 0) + remaining

    return consumed

# Возвращает уровень качества, соответствующий взвешенному среднему
# по разбивке consumed (словарь {quality: count}).
# Используется при производстве: качество результата = взвешенное среднее
# качества потреблённого сырья, округлённое до ближайшего уровня.
func quality_from_breakdown(consumed: Dictionary) -> String:
    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return "common"
    var total := 0
    var weighted := 0.0
    for qid in consumed:
        var count = int(consumed[qid])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * float(GameData.get_quality_value(qid))
    if total <= 0:
        return "common"
    var avg = weighted / float(total)
    # Округляем до ближайшего уровня качества.
    var best_qid = levels[0]
    var best_diff = 1e9
    for qid in levels:
        var diff = abs(float(GameData.get_quality_value(qid)) - avg)
        if diff < best_diff:
            best_diff = diff
            best_qid = qid
    return best_qid

func add_raw_production(raw_id: String, multiplier: float = 1.0, quality: String = "common"):
    if Engine.is_editor_hint():
        return
    var raw = GameData.raw_resources.get(raw_id, {})
    if raw.has("produces"):
        for pid in raw["produces"]:
            var amount = ceili(raw["produces"][pid] * multiplier)
            # Проверяем, доступен ли этот продукт (по технологии)
            if not _is_product_available(pid):
                continue
            if city_storage.has(pid):
                add_to_storage(pid, amount, quality)
                production_rates[pid] += amount

func do_tick():
    if Engine.is_editor_hint():
        return

    # --- Работа зданий (только если есть горожанин) ---
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null

    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue

        # Проверяем, есть ли горожанин на этом здании
        var has_worker = false
        if tm:
            has_worker = tm.has_townsfolk(i)

        if not has_worker:
            continue # здание не работает

        for recipe_id in slots:
            if recipe_id == "" or recipe_id == "empty":
                continue

            var recipe = null
            for c in GameData.crafts:
                if c["id"] == recipe_id:
                    recipe = c
                    break
            if not recipe:
                continue

            # --- ПРОВЕРКА РЕСУРСОВ (С ПОДДЕРЖКОЙ ГРУПП) ---
            var missing_resources = []
            var resources_to_consume = {} # { "product_id": amount, ... }

            for res in recipe["resources"]:
                var amount_needed = recipe["resources"][res]
                if res.begins_with("@"):
                    # Групповой ресурс
                    var group_key = res.trim_prefix("@")
                    # Сначала ищем группу по id, затем по человекочитаемому имени
                    var group_products = GameData.product_groups.get(group_key, [])
                    if group_products.is_empty():
                        group_products = GameData.product_groups.get(_get_group_id_by_name(group_key), [])
                    if group_products.is_empty():
                        # Группа не найдена — считаем рецепт недоступным
                        missing_resources.append(res)
                        break

                    var total_available = 0
                    for prod in group_products:
                        total_available += city_storage.get(prod, 0)
                    if total_available < amount_needed:
                        missing_resources.append(res)
                        break

                    # Собираем нужное количество из разных продуктов
                    var remaining = amount_needed
                    for prod in group_products:
                        var available = city_storage.get(prod, 0)
                        if available > 0:
                            var take = min(available, remaining)
                            if take > 0:
                                resources_to_consume[prod] = resources_to_consume.get(prod, 0) + take
                                remaining -= take
                                if remaining <= 0:
                                    break
                else:
                    # Обычный ресурс
                    if city_storage.get(res, 0) < amount_needed:
                        missing_resources.append(res)
                        break
                    resources_to_consume[res] = amount_needed

            # Если не хватает ресурсов — пропускаем рецепт
            if not missing_resources.is_empty():
                continue

            # --- СПИСЫВАЕМ РЕСУРСЫ ---
            # Приоритет выбора качества сырья: по умолчанию — лучшее.
            var priority = bld.get("quality_priority", GameData.get_quality_priority_default())
            var consumed_all = {} # объединённая разбивка потреблённого сырья по качеству
            for prod in resources_to_consume:
                var consumed = remove_from_storage(prod, resources_to_consume[prod], priority)
                consumption_rates[prod] = consumption_rates.get(prod, 0) + resources_to_consume[prod]
                # Суммируем разбивки потреблённого по всем ресурсам рецепта,
                # чтобы вычислить итоговое качество результата как взвешенное среднее.
                for qid in consumed:
                    consumed_all[qid] = consumed_all.get(qid, 0) + consumed[qid]

            # --- ДОБАВЛЯЕМ РЕЗУЛЬТАТ ---
            # Качество результата = взвешенное среднее качества потреблённого сырья.
            var result_quality = quality_from_breakdown(consumed_all)
            for res in recipe["result"]:
                var amount = recipe["result"][res]
                add_to_storage(res, amount, result_quality)
                production_rates[res] = production_rates.get(res, 0) + amount

    # --- Потребление еды населением ---
    # Еда потребляется без учёта качества (качество — визуальная механика),
    # поэтому списываем по умолчанию "best" через хелпер, чтобы детализация
    # качества всегда оставалась консистентной.
    var food_needed = max(0, total_population - 1) * food_per_citizen
    var food_eaten = 0
    for pid in city_food_pool:
        if city_food_pool[pid] and city_storage.get(pid, 0) > 0:
            var available = city_storage[pid]
            var to_take = min(available, food_needed - food_eaten)
            remove_from_storage(pid, to_take, "best")
            consumption_rates[pid] += to_take
            food_eaten += to_take
            if food_eaten >= food_needed:
                break

    _check_population_change()
    emit_signal("city_updated")

# Возвращает id группы по её человекочитаемому имени (или сам ключ, если это id).
func _get_group_id_by_name(gname: String) -> String:
    for gid in GameData.product_group_names:
        if GameData.product_group_names[gid] == gname:
            return gid
    return gname

func _check_population_change():
    var available_food = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            available_food += city_storage.get(pid, 0)

    # --- ДИНАМИКА ЕДЫ (для определения голода) ---
    var total_prod = 0
    var total_cons = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            total_prod += production_rates.get(pid, 0)
            total_cons += consumption_rates.get(pid, 0)

    var main_map = get_tree().root.find_child("MainMap", true, false)

    # --- РОСТ НАСЕЛЕНИЯ ---
    if available_food >= food_for_new_settler and total_population > 0:
        total_population += 1
        idle_population += 1 # новый житель пока свободен

        # Пытаемся назначить его на работу (сначала на улучшение, потом в город)
        var assigned = false
        if main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            assigned = wm.assign_worker() # уменьшит idle_population при успехе

        if not assigned and main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            assigned = tm.assign_townsfolk()

        # Если никуда не назначился — остаётся в idle_population

        # Списываем еду за рождение
        var remaining = food_for_new_settler
        var active_food = []
        for pid in city_food_pool:
            if city_food_pool[pid] and city_storage.get(pid, 0) > 0:
                active_food.append(pid)
        while remaining > 0 and active_food.size() > 0:
            var pid = active_food[randi() % active_food.size()]
            remove_from_storage(pid, 1, "best")
            remaining -= 1
            if city_storage.get(pid, 0) <= 0:
                active_food.erase(pid)

        emit_signal("population_changed", total_population)
        print("Население выросло до ", total_population)

    # --- ГОЛОД (смерть от недостатка еды) ---
    elif available_food == 0 and total_cons > total_prod and total_population > 1:
        total_population -= 1

        # Убираем одного жителя с работы (сначала горожанина, потом рабочего).
        # Умерший НЕ переходит в категорию свободных, поэтому после снятия
        # с работы компенсируем увеличение idle_population.
        var removed = false
        if main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            for i in range(city_built_buildings.size()):
                if tm.has_townsfolk(i):
                    tm.remove_townsfolk(i) # увеличит idle_population
                    idle_population -= 1 # умерший не становится свободным
                    removed = true
                    break

        if not removed and main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            for key in wm.assigned_hexes.keys():
                var parts = key.split(",")
                if parts.size() == 2:
                    wm.remove_worker(int(parts[0]), int(parts[1])) # увеличит idle_population
                    idle_population -= 1 # умерший не становится свободным
                    removed = true
                    break

        # Если житель был свободен (не работал), просто уменьшаем idle_population
        if not removed and idle_population > 0:
            idle_population -= 1

        # Корректируем idle_population, чтобы он не превышал total_population
        if idle_population > total_population:
            idle_population = total_population

        emit_signal("population_changed", total_population)
        print("Население уменьшилось до ", total_population)

# --- ИССЛЕДОВАНИЯ ---
func start_research(tech_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    if current_research_tech_id != "":
        var current_tech_name = current_research_tech_id
        for t in GameData.technologies:
            if t["id"] == current_research_tech_id:
                current_tech_name = t["name"]
                break
        emit_signal("research_error", "Уже идёт исследование: " + current_tech_name)
        return false
    if tech_id in unlocked_technologies:
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break
        emit_signal("research_error", "Технология уже изучена: " + tech_name)
        return false
    var tech_data = null
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_data = t
            break
    if tech_data == null:
        emit_signal("research_error", "Технология не найдена: " + tech_id)
        return false
    if not are_prerequisites_met(tech_id):
        var prereq_text = get_tech_prerequisites_text(tech_id)
        emit_signal("research_error", "Не выполнены требования: " + prereq_text)
        return false
    # Исследование не требует еды — только очки науки.
    current_research_tech_id = tech_id
    current_research_science_cost = int(tech_data.get("science_cost", 3))
    research_progress = 0.0
    research_science_accumulated = 0.0
    print("Начато исследование: ", tech_data["name"])
    emit_signal("city_updated")
    return true

# Возвращает количество очков науки за тик.
# Учёных пока нет, поэтому город сам генерирует минимум — 1 очко за тик.
# Город не может генерировать меньше 1 очка науки за тик.
func get_science_per_tick() -> float:
    var science = 0.0
    # TODO: при добавлении учёных сюда нужно будет суммировать их вклад.
    # Пока учёных нет — город генерирует минимум 1 очко науки за тик.
    return max(1.0, science)

# Возвращает количество накопленных очков науки по текущему исследованию.
func get_research_science_collected() -> float:
    return research_science_accumulated

# Обновляет прогресс исследования непрерывно — вызывается каждый кадр
# из _process в main_map.gd. Раньше это делалось раз в PRODUCTION_INTERVAL
# (2 секунды), из-за чего прогресс-бар дёргался рывками: тик → 33%, пауза,
# тик → 66%, пауза. Теперь accumulated растёт с правильной скоростью
# (science_per_sec = science_per_tick / PRODUCTION_INTERVAL), и UI
# получает гладкий сигнал.
func tick_research_science_continuous(delta: float) -> void:
    if Engine.is_editor_hint():
        return
    if current_research_tech_id == "":
        return
    if current_research_science_cost <= 0:
        current_research_science_cost = 1
    var rate: float = get_science_per_tick() / PRODUCTION_INTERVAL
    research_science_accumulated += rate * delta
    research_progress = clamp(research_science_accumulated / float(current_research_science_cost), 0.0, 1.0)
    if research_science_accumulated >= current_research_science_cost:
        _complete_research()

func _complete_research():
    if current_research_tech_id == "":
        return
    var completed_tech_id = current_research_tech_id
    unlocked_technologies.append(current_research_tech_id)
    var tech_name = current_research_tech_id
    for t in GameData.technologies:
        if t["id"] == current_research_tech_id:
            tech_name = t["name"]
            break
    emit_signal("research_error", "Исследование завершено: " + tech_name)
    # Технология может открывать новые виды ресурсов — спавним их на карте.
    # Сообщения готовим ДО сигнала research_completed, чтобы попап
    # мог отобразить найденные ресурсы сразу.
    last_research_messages = spawn_resource_on_tech_research(completed_tech_id)
    emit_signal("research_completed", current_research_tech_id)
    # После завершения исследования очки науки сбрасываются на ноль.
    current_research_tech_id = ""
    current_research_science_cost = 0
    research_progress = 0.0
    research_science_accumulated = 0.0
    emit_signal("city_updated")

func is_tech_unlocked(tech_id: String) -> bool:
    return tech_id in unlocked_technologies

func _get_tech_data(tech_id: String):
    for t in GameData.technologies:
        if t["id"] == tech_id:
            return t
    return null

# Проверяет, выполнены ли prerequisites технологии.
# Формат: [ [A, B], [C] ] => (A И B) ИЛИ C
func are_prerequisites_met(tech_id: String) -> bool:
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null:
        return false
    if not tech_data.has("prerequisites"):
        return true
    var prereqs: Array = tech_data.get("prerequisites", [])
    for group in prereqs:
        var all_met = true
        for req_id in group:
            if not (req_id in unlocked_technologies):
                all_met = false
                break
        if all_met:
            return true
    return false

# Возвращает человекочитаемый текст требований технологии.
func get_tech_prerequisites_text(tech_id: String) -> String:
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null or not tech_data.has("prerequisites"):
        return ""
    var or_parts = []
    var prereqs: Array = tech_data.get("prerequisites", [])
    for group in prereqs:
        var and_names = []
        for req_id in group:
            var req_data = _get_tech_data(req_id)
            and_names.append(req_data.get("name", req_id) if req_data else req_id)
        or_parts.append(" и ".join(and_names))
    return " или ".join(or_parts)

# Доступна ли технология для изучения (prerequisites выполнены, не изучена, не в процессе).
func is_tech_available(tech_id: String) -> bool:
    if tech_id in unlocked_technologies:
        return false
    if tech_id == current_research_tech_id:
        return false
    return are_prerequisites_met(tech_id)

# Возвращает список id технологий (в порядке их изучения — от корня до target),
# которые игроку ещё нужно изучить, чтобы стала доступной tech_id.
# Уже изученные технологии пропускаются; требования берутся из поля
# `prerequisites` (группы ИЛИ · элементов И — выбирается группа с наименьшим
# числом недостающих технологий). Исключаются циклы и дубликаты.
# Используется для кнопки «Изучить ...» в панели управления спецдействий.
func get_tech_study_chain(tech_id: String) -> Array:
    var chain: Array = []
    _collect_tech_chain(tech_id, chain, {})
    return chain

func _collect_tech_chain(tech_id: String, chain: Array, visiting: Dictionary) -> void:
    if tech_id in visiting or tech_id in chain:
        return
    var data = _get_tech_data(tech_id)
    if data == null or is_tech_unlocked(tech_id):
        return
    var prereqs: Array = data.get("prerequisites", [])
    if not prereqs.is_empty():
        # Выбираем группу предусловий с наименьшим числом недостающих технологий.
        var best_reqs: Array = []
        var best_missing := 1 << 30
        for group in prereqs:
            var missing: Array = []
            for req_id in group:
                if not is_tech_unlocked(req_id):
                    missing.append(req_id)
            if missing.size() < best_missing:
                best_missing = missing.size()
                best_reqs = missing
        visiting[tech_id] = true
        for req_id in best_reqs:
            _collect_tech_chain(req_id, chain, visiting)
        visiting.erase(tech_id)
    if tech_id not in chain:
        chain.append(tech_id)

# Открыто ли здание игроку (по полю unlock_tech самого здания).
func is_building_unlocked(building_id: String) -> bool:
    for b in GameData.buildings:
        if b["id"] == building_id:
            var required_tech = b.get("unlock_tech", "")
            if required_tech != "":
                return is_tech_unlocked(required_tech)
    return true

# Открыто ли улучшение игроку (по полю unlock_tech самого улучшения).
func is_improvement_unlocked(imp_id: String) -> bool:
    if imp_id == null or imp_id == "":
        return true
    var imp_data = GameData.improvements.get(imp_id, {})
    var required_tech = imp_data.get("unlock_tech", "")
    if required_tech != "":
        return is_tech_unlocked(required_tech)
    return true

# Возвращает id технологии, открывающей указанное улучшение (для контекстного меню).
func get_improvement_unlock_tech(imp_id: String) -> String:
    var imp_data = GameData.improvements.get(imp_id, {})
    return imp_data.get("unlock_tech", "")

# Формирует сообщения о ресурсах, раскрываемых изученной технологией.
# Вызывается после завершения исследования технологии.
#
# Новая модель (см. docs.md, «tech_reveal: скрытые ресурсы»):
#   - Все ресурсы спавнятся на карте с самого старта (map_generator.gd).
#   - tech_required гейтит постройку улучшения (как и раньше).
#   - tech_reveal гейтит видимость самого ресурса на карте.
#   - Эта функция перечисляет ресурсы, у которых tech_reveal == tech_id,
#     и для каждого формирует сообщение:
#       * ресурс есть на карте          → "Учёные оценили: найдено <X>."
#       * ресурса на карте нет          → "Похоже, в вашем регионе <X> отсутствует."
#   - Размещением на карте функция НЕ занимается: все ресурсы уже там
#     с момента генерации карты.
#
# Гарантия «1 металл в стартовом Кольце + Регионе» обеспечивается отдельно
# в main_map._initialize_map через MapHelpers.ensure_minimum_resource.
# Возвращает массив сообщений для попапа технологии.
func spawn_resource_on_tech_research(tech_id: String) -> Array:
    var messages = []
    if Engine.is_editor_hint():
        return messages
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return messages
    var tile_data = main_map.tile_data

    # Собираем виды ресурсов, РАСКРЫВАЕМЫХ этой технологией (tech_reveal).
    # Если у ресурса нет tech_reveal — он виден сразу и эта функция его
    # не упоминает; если tech_reveal есть, но не совпадает с tech_id,
    # ресурс ещё скрыт и о нём мы тоже не сообщаем.
    for res_id in GameData.raw_resources:
        var data = GameData.raw_resources[res_id]
        var reveal_tech: String = data.get("tech_reveal", "")
        if reveal_tech != tech_id:
            continue
        var res_name: String = data.get("name", res_id)
        if _is_resource_on_map(tile_data, res_id):
            messages.append("Учёные оценили: в вашем регионе можно найти %s." % res_name)
        else:
            messages.append("Похоже, в вашем регионе %s отсутствует." % res_name)
    return messages

# Проверяет, есть ли на карте хотя бы один гекс с указанным ресурсом.
func _is_resource_on_map(tile_data: Array, res_id: String) -> bool:
    for row in tile_data:
        for tile in row:
            if tile.get("resource", null) == res_id:
                return true
    return false

# Проверяет, присутствует ли на карте хотя бы один ресурс, РАСКРЫВАЕМЫЙ
# указанной технологией (tech_reveal == tech_id).
func _tech_has_resource_on_map(tile_data: Array, tech_id: String) -> bool:
    for row in tile_data:
        for tile in row:
            var res_id = tile.get("resource", null)
            if res_id == null:
                continue
            var data = GameData.raw_resources.get(res_id, {})
            if data.get("tech_reveal", "") == tech_id:
                return true
    return false

# Вызывается при загрузке сохранения: для уже изученных технологий
# гарантирует, что открытые ими ресурсы корректно отображаются.
# В новой модели (все ресурсы уже на карте) это, по сути, no-op: если
# ресурс с tech_reveal == tech_id на карте есть (а он там есть в норме),
# функция ничего не делает. Если сейв старый и ресурс на карте отсутствует,
# нового спавна тоже не делаем — старые сохранения с повреждённой картой
# пользователь чинит сам (или стартует новую партию).
func ensure_tech_resources_spawned():
    if Engine.is_editor_hint():
        return
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return
    var tile_data = main_map.tile_data
    for tech_id in unlocked_technologies:
        # На карте уже есть ресурс, раскрываемый этой технологией — ок.
        if _tech_has_resource_on_map(tile_data, tech_id):
            continue
        # На всякий случай прогоняем функцию (сформирует «отсутствует»
        # сообщения, но в HUD они не пойдут — мы их тут же отбрасываем).
        spawn_resource_on_tech_research(tech_id)

# Проверяет доступность продукта (включая технологии, улучшения и здания).
func _is_product_available(product_id: String) -> bool:
    var product_data = GameData.products.get(product_id, {})
    # Проверка технологии
    var required_tech = product_data.get("unlock_tech", "")
    if required_tech != "" and not is_tech_unlocked(required_tech):
        return false

    # Проверка улучшения (на карте)
    var required_improvement = product_data.get("unlock_improvement", "")
    if required_improvement != "" and not _has_improvement(required_improvement):
        return false

    # Проверка здания (в городе)
    var required_building = product_data.get("unlock_building", "")
    if required_building != "" and not _has_building(required_building):
        return false

    return true

func _has_improvement(improvement_id: String) -> bool:
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if not main_map:
        return false
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile and tile.get("improvement") == improvement_id:
                return true
    return false

func _has_building(building_id: String) -> bool:
    for bld in city_built_buildings:
        if bld.get("id") == building_id:
            return true
    return false

# TODO: временная миграция старых сейвов (формат "recipe"). Удалить после того,
#	   как все старые сохранения перестанут использоваться.
# Конвертирует старые записи зданий {"id": ..., "recipe": ...} в новый формат {"id": ..., "slots": [...]}.
func migrate_old_save_format():
    for bld in city_built_buildings:
        if not bld.has("slots"):
            bld["slots"] = _slots_from_legacy(bld)
            bld.erase("recipe")

# TODO: временная миграция. Удалить вместе с migrate_old_save_format().
func _slots_from_legacy(bld: Dictionary) -> Array:
    var building_id = bld.get("id", "")
    var slots = _auto_assign_slots(building_id)
    var legacy_recipe = bld.get("recipe", "")
    # Если в старом сейве был конкретный рецепт — ставим его в первый слот
    if legacy_recipe != "" and legacy_recipe != "empty":
        if slots.size() > 0:
            slots[0] = legacy_recipe
        else:
            slots.append(legacy_recipe)
    return slots

# Списывает additional_cost здания со склада. Поддерживает обе формы поля
# (объект и массив пачек с AND-логикой) и групповые ключи (@xxx) — для них
# списание распределяется по членам группы, как в рецептах.
# Атомарно: если хотя бы одной пачки не хватает — НИЧЕГО не списывается.
# Возвращает { "ok": true } при успехе или { "ok": false, "missing": [имена...] }.
func consume_additional_cost(bdata: Dictionary) -> Dictionary:
    if not bdata.has("additional_cost"):
        return {"ok": true}
    var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
    if bundles.is_empty():
        return {"ok": true}

    # Первый проход: проверяем, что всего хватает, и собираем план списания
    # [{ "prod_id": amount, ... }, ...] — по плану на каждую пачку.
    var plan: Array = []
    var missing: Array = []
    for bundle in bundles:
        var bundle_plan: Dictionary = {}
        for res_id in bundle:
            var required: int = int(bundle[res_id])
            if required <= 0:
                continue
            if GameData.is_group_key(res_id):
                var group_key = res_id.trim_prefix("@")
                var group_products = GameData.product_groups.get(group_key, [])
                if group_products.is_empty():
                    group_products = GameData.product_groups.get(_get_group_id_by_name(group_key), [])
                if group_products.is_empty():
                    missing.append(res_id)
                    continue
                var total_available := 0
                for prod in group_products:
                    total_available += city_storage.get(prod, 0)
                if total_available < required:
                    missing.append(res_id)
                    continue
                # Собираем сколько откуда брать (жадно по списку группы)
                var remaining = required
                for prod in group_products:
                    var available = city_storage.get(prod, 0)
                    if available <= 0:
                        continue
                    var take = min(available, remaining)
                    if take > 0:
                        bundle_plan[prod] = bundle_plan.get(prod, 0) + take
                        remaining -= take
                        if remaining <= 0:
                            break
            else:
                if city_storage.get(res_id, 0) < required:
                    missing.append(res_id)
                    continue
                bundle_plan[res_id] = bundle_plan.get(res_id, 0) + required
        plan.append(bundle_plan)

    if not missing.is_empty():
        return {"ok": false, "missing": missing}

    # Второй проход: всё проверено — списываем. Приоритет качества — как
    # в рецептах (по умолчанию «лучшее»).
    var priority = GameData.get_quality_priority_default()
    for bundle_plan in plan:
        for prod in bundle_plan:
            var amount: int = int(bundle_plan[prod])
            remove_from_storage(prod, amount, priority)
            consumption_rates[prod] = consumption_rates.get(prod, 0) + amount
    return {"ok": true}

func request_build(building_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break
    if not bdata:
        return false
    # Здание должно быть открыто изученной технологией
    if not is_building_unlocked(building_id):
        print("Здание недоступно: ", bdata.get("name", building_id))
        return false
    # Списываем additional_cost (если есть) — атомарно, до старта стройки.
    # Поддерживает массив пачек (AND-логика) и групповые ключи (@xxx).
    var cost_check = consume_additional_cost(bdata)
    if not cost_check["ok"]:
        print("Не хватает ресурсов для постройки ", bdata.get("name", building_id), ": ", cost_check.get("missing", []))
        return false
    var work_cost = bdata.get("work_cost", 0)
    # Общий лимит одновременных строек (здания + улучшения) равен общему числу жителей
    if work_cost > 0:
        var main_map = get_tree().root.find_child("MainMap", true, false)
        var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
        var total_active = building_construction.size()
        if bm:
            total_active = bm.get_total_active_builds()
        if total_active >= total_population:
            print("Можно строить не более %d зданий или улучшений одновременно (лимит = число жителей)" % total_population)
            return false
    # Строительство зданий теперь требует труд, а не еду
    if work_cost <= 0:
        # Если стоимость 0 (например, ручная мельница), строим мгновенно
        city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})

        # Автоматически назначаем горожанина на новое здание, если есть свободные
        var townsfolk_map = get_tree().root.find_child("MainMap", true, false)
        if townsfolk_map and townsfolk_map.has_node("TownsfolkManager"):
            var tm = townsfolk_map.get_node("TownsfolkManager")
            tm.assign_townsfolk()

        emit_signal("city_updated")
        return true

    # Для зданий с work_cost > 0 запускаем стройку через build_manager
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map and main_map.has_node("BuildManager"):
        var bm = main_map.get_node("BuildManager")
        var build_key = bm.start_building_build(building_id)
        if build_key != "":
            # Сохраняем стройку в отдельный словарь, здание появится в городе только после завершения
            building_construction[build_key] = {
                "building_id": building_id,
                "build_key": build_key,
                "slots": _auto_assign_slots(building_id)
            }
            emit_signal("building_construction_started", building_id, build_key)
            emit_signal("city_updated")
            return true
        return false

    # Если build_manager недоступен, строим мгновенно (fallback)
    city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})
    if main_map and main_map.has_node("TownsfolkManager"):
        var tm2 = main_map.get_node("TownsfolkManager")
        tm2.assign_townsfolk()
    emit_signal("city_updated")
    return true

# Автоназначение рецептов на слоты при постройке здания:
# 1. Берём default_recipes здания
# 2. Назначаем на слоты по порядку, без повторения
# 3. Если слотов больше, чем рецептов — остальные получают "empty"
# 4. Если рецептов больше, чем слотов — лишние просто не помещаются
func _auto_assign_slots(building_id: String) -> Array:
    var result = []
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break
    if not bdata:
        return result

    var slot_count = int(bdata.get("production_slots", 1))
    var default_recipes = bdata.get("default_recipes", [])

    for i in range(slot_count):
        if i < default_recipes.size():
            result.append(default_recipes[i])
        else:
            result.append("empty")
    return result

# Возвращает true, если все слоты здания пусты (рецепт "Пусто" или "").
# Используется для отображения статуса "простаивает".
func are_all_slots_empty(b_index: int) -> bool:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return false
    var bld = city_built_buildings[b_index]
    var slots = bld.get("slots", [])
    if slots.is_empty():
        return false
    for recipe_id in slots:
        if recipe_id != "" and recipe_id != "empty":
            return false
    return true

# Проверяет, может ли рецепт исполняться в указанном здании.
# produced_in поддерживает массив значений; "*" означает "в любом здании" (пустой рецепт).
func can_craft_in(craft_id: String, building_id: String) -> bool:
    var recipe = null
    for c in GameData.crafts:
        if c["id"] == craft_id:
            recipe = c
            break
    if not recipe:
        return false

    var produced_in = recipe.get("produced_in", [])
    # Обратная совместимость: если produced_in — строка, приводим к массиву
    if produced_in is String:
        produced_in = [produced_in]

    if building_id in produced_in:
        return true
    if "*" in produced_in:
        return true
    return false

func add_animal(animal_id: String):
    if Engine.is_editor_hint():
        return
    if GameData.raw_resources.has(animal_id) and GameData.raw_resources[animal_id].get("category") == "animals":
        if not (animal_id in domesticated_animals):
            domesticated_animals.append(animal_id)

func add_plant(plant_id: String):
    if Engine.is_editor_hint():
        return
    if GameData.raw_resources.has(plant_id) and GameData.raw_resources[plant_id].get("category") == "plants":
        if not (plant_id in domesticated_plants):
            domesticated_plants.append(plant_id)

func is_product_available(product_id: String) -> bool:
    return _is_product_available(product_id)

# Возвращает итоговый множитель производства для улучшения imp_id.
# has_fresh_water — есть ли доступ к пресной проточной воде на гексе.
# terrain_id — тип местности гекса (для модификаторов по местности,
#   например, асфальтовое озеро даёт x2 к битуму).
# resource_id — id ресурса на гексе (для модификаторов по местности).
func get_improvement_production_multiplier(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> float:
    var multiplier = 1.0
    for mod in get_improvement_production_modifiers(imp_id, has_fresh_water, terrain_id, resource_id):
        multiplier *= mod.get("multiplier", 1.0)
    return multiplier

# Возвращает список активных модификаторов производства для улучшения imp_id.
# Каждый элемент: { "label": String, "multiplier": float }
# terrain_id — тип местности гекса (для модификаторов по местности).
# resource_id — id ресурса на гексе (для модификаторов по местности).
func get_improvement_production_modifiers(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> Array:
    var result = []
    if imp_id == null or imp_id == "":
        return result

    # Модификатор доступа к пресной проточной воде
    if has_fresh_water:
        var fw = GameData.modifiers.get("fresh_water", {})
        var multipliers = fw.get("production_multiplier", {})
        if multipliers.has(imp_id):
            var m = float(multipliers[imp_id])
            if m != 1.0:
                result.append({
                    "label": "+%d%% (Доступ к пресной воде)" % int(round((m - 1.0) * 100.0)),
                    "multiplier": m
                })

    # Модификаторы по типу местности (terrain_modifiers).
    # Применяются, когда на гексе с указанным terrain_id добывается
    # указанный resource_id (через улучшение). Например, битум на
    # асфальтовом озере (asphalt_lake) даёт x2 к производству.
    # См. data/modifiers.json, блок "terrain_modifiers".
    if terrain_id != "" and resource_id != "":
        for tm in GameData.modifiers.get("terrain_modifiers", []):
            if tm.get("terrain_id", "") != terrain_id:
                continue
            if tm.get("resource_id", "") != resource_id:
                continue
            var m = float(tm.get("production_multiplier", 1.0))
            if m != 1.0:
                var terrain_name: String = GameData.terrains.get(terrain_id, {}).get("name", terrain_id)
                result.append({
                    "label": "x%.1f (%s)" % [m, terrain_name],
                    "multiplier": m
                })

    # Модификаторы от изученных технологий
    for tm in GameData.modifiers.get("tech_modifiers", []):
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not is_tech_unlocked(tech_id):
            continue
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break

        # Универсальный формат: "production_multiplier": { "<imp_id>": 1.05 }
        # (по аналогии с бонусом от пресной воды).
        var multipliers = tm.get("production_multiplier", {})
        if multipliers.has(imp_id):
            var m = float(multipliers[imp_id])
            if m != 1.0:
                result.append({
                    "label": "+%d%% (%s)" % [int(round((m - 1.0) * 100.0)), tech_name],
                    "multiplier": m
                })

        # Старый формат с полем "modifiers" (target == "<imp_id>_production").
        for mod in tm.get("modifiers", []):
            var target = mod.get("target", "")
            if target != imp_id + "_production":
                continue
            var mod_type = mod.get("type", "percent")
            var value = float(mod.get("value", 0))
            var multiplier = 1.0
            if mod_type == "percent":
                multiplier = 1.0 + value / 100.0
            else:
                multiplier = value
            result.append({
                "label": "+%d%% (%s)" % [int(value), tech_name],
                "multiplier": multiplier
            })
    return result
