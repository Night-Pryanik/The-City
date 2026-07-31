# CityData.gd (Autoload)
@tool
extends Node

# Склад и производство
var city_storage: Dictionary = {}
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var city_food_pool: Dictionary = {}
var city_built_buildings: Array = []
var domesticated_animals: Array = []
var domesticated_plants: Array = []

# Технологии
var unlocked_technologies: Array = []
var current_research_tech_id: String = ""
var current_research_time: float = 0.0
var research_progress: float = 0.0

# --- НАСЕЛЕНИЕ ---
var total_population: int = 1
var idle_population: int = 1  # свободные жители (не занятые нигде)
var food_for_new_settler: int = 100
var food_per_citizen: int = 1

const PRODUCTION_INTERVAL: float = 2.0

signal city_updated()
signal research_completed(tech_id: String)
signal research_error(message: String)
signal population_changed(new_population: int)

func setup():
    city_storage.clear()
    production_rates.clear()
    consumption_rates.clear()
    city_food_pool.clear()
    city_built_buildings.clear()
    domesticated_animals.clear()
    domesticated_plants.clear()
    unlocked_technologies.clear()
    current_research_tech_id = ""
    current_research_time = 0.0
    research_progress = 0.0

    total_population = 1
    idle_population = 1  # один житель, пока нигде не занят

    for pid in GameData.products.keys():
        city_storage[pid] = 0
        production_rates[pid] = 0
        consumption_rates[pid] = 0
        if GameData.products[pid].get("category") == "food":
            city_food_pool[pid] = true

    if city_storage.has("meat"):
        city_storage["meat"] = 10

func reset_counters():
    for pid in production_rates.keys():
        production_rates[pid] = 0
        consumption_rates[pid] = 0

func add_raw_production(raw_id: String, multiplier: float = 1.0):
    if Engine.is_editor_hint():
        return
    var raw = GameData.raw_resources.get(raw_id, {})
    if raw.has("produces"):
        for pid in raw["produces"]:
            var amount = raw["produces"][pid] * multiplier
            # Проверяем, доступен ли этот продукт (по технологии)
            if not _is_product_available(pid):
                continue
            if city_storage.has(pid):
                city_storage[pid] += amount
                production_rates[pid] += amount

func do_tick():
    if Engine.is_editor_hint():
        return

    # --- Работа зданий (только если есть горожанин) ---
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null

    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var recipe_id = bld.get("recipe", "")
        if recipe_id == "":
            continue

        # Проверяем, есть ли горожанин на этом здании
        var has_worker = false
        if tm:
            has_worker = tm.has_townsfolk(i)

        if not has_worker:
            continue  # здание не работает

        var recipe = null
        for c in GameData.crafts:
            if c["id"] == recipe_id:
                recipe = c
                break
        if not recipe:
            continue

        # --- ПРОВЕРКА РЕСУРСОВ (С ПОДДЕРЖКОЙ ГРУПП) ---
        var missing_resources = []
        var resources_to_consume = {}  # { "product_id": amount, ... }

        for res in recipe["resources"]:
            var amount_needed = recipe["resources"][res]
            if res.begins_with("@"):
                # Групповой ресурс
                var group_id = res.trim_prefix("@")
                var group_products = GameData.product_groups.get(group_id, [])
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
        for prod in resources_to_consume:
            city_storage[prod] -= resources_to_consume[prod]
            consumption_rates[prod] += resources_to_consume[prod]

        # --- ДОБАВЛЯЕМ РЕЗУЛЬТАТ ---
        for res in recipe["result"]:
            city_storage[res] += recipe["result"][res]
            production_rates[res] += recipe["result"][res]

    # --- Потребление еды населением ---
    var food_needed = max(0, total_population - 1) * food_per_citizen
    var food_eaten = 0
    for pid in city_food_pool:
        if city_food_pool[pid] and city_storage.get(pid, 0) > 0:
            var available = city_storage[pid]
            var to_take = min(available, food_needed - food_eaten)
            city_storage[pid] -= to_take
            consumption_rates[pid] += to_take
            food_eaten += to_take
            if food_eaten >= food_needed:
                break

    _check_population_change()
    emit_signal("city_updated")

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
        idle_population += 1  # новый житель пока свободен

        # Пытаемся назначить его на работу (сначала на улучшение, потом в город)
        var assigned = false
        if main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            assigned = wm.assign_worker()  # уменьшит idle_population при успехе

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
            city_storage[pid] -= 1
            remaining -= 1
            if city_storage[pid] <= 0:
                active_food.erase(pid)

        emit_signal("population_changed", total_population)
        print("Население выросло до ", total_population)

    # --- ГОЛОД (смерть от недостатка еды) ---
    elif available_food == 0 and total_cons > total_prod and total_population > 1:
        total_population -= 1

        # Убираем одного жителя с работы (сначала горожанина, потом рабочего)
        var removed = false
        if main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            for i in range(city_built_buildings.size()):
                if tm.has_townsfolk(i):
                    tm.remove_townsfolk(i)  # увеличит idle_population
                    removed = true
                    break

        if not removed and main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            for key in wm.assigned_hexes.keys():
                var parts = key.split(",")
                if parts.size() == 2:
                    wm.remove_worker(int(parts[0]), int(parts[1]))  # увеличит idle_population
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
    var cost = tech_data.get("cost_food", 10)
    var available_food = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            available_food += city_storage[pid]
    if available_food >= cost:
        var remaining = cost
        var active_food = []
        for pid in city_food_pool:
            if city_food_pool[pid] and city_storage[pid] > 0:
                active_food.append(pid)
        while remaining > 0 and active_food.size() > 0:
            var pid = active_food[randi() % active_food.size()]
            city_storage[pid] -= 1
            remaining -= 1
            if city_storage[pid] <= 0:
                active_food.erase(pid)
        current_research_tech_id = tech_id
        current_research_time = tech_data.get("time", 10.0)
        research_progress = 0.0
        print("Начато исследование: ", tech_data["name"])
        emit_signal("city_updated")
        return true
    else:
        emit_signal("research_error", "Недостаточно еды для исследования " + tech_data.get("name", tech_id) + ". Нужно " + str(cost))
        return false

func tick_research(delta: float):
    if Engine.is_editor_hint():
        return
    if current_research_tech_id == "":
        return
    research_progress += delta / current_research_time
    if research_progress >= 1.0:
        unlocked_technologies.append(current_research_tech_id)
        var tech_name = current_research_tech_id
        for t in GameData.technologies:
            if t["id"] == current_research_tech_id:
                tech_name = t["name"]
                break
        emit_signal("research_error", "Исследование завершено: " + tech_name)
        emit_signal("research_completed", current_research_tech_id)
        current_research_tech_id = ""
        current_research_time = 0.0
        research_progress = 0.0
        emit_signal("city_updated")

func is_tech_unlocked(tech_id: String) -> bool:
    return tech_id in unlocked_technologies

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
    for row in range(main_map.REGION_ROWS):
        for col in range(main_map.REGION_COLS):
            var tile = main_map.get_tile_data(row, col)
            if tile and tile.get("improvement") == improvement_id:
                return true
    return false

func _has_building(building_id: String) -> bool:
    for bld in city_built_buildings:
        if bld.get("id") == building_id:
            return true
    return false

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
    var cost = bdata.get("cost_food", 0)
    var available_food = 0
    var active_food = []
    for pid in city_food_pool:
        if city_food_pool[pid]:
            var stock = city_storage.get(pid, 0)
            available_food += stock
            if stock > 0:
                active_food.append(pid)
    if available_food >= cost:
        var remaining = cost
        while remaining > 0 and active_food.size() > 0:
            var pid = active_food[randi() % active_food.size()]
            city_storage[pid] -= 1
            remaining -= 1
            if city_storage[pid] <= 0:
                active_food.erase(pid)
        var recipe_id = ""
        for craft in GameData.crafts:
            if craft["produced_in"] == building_id:
                recipe_id = craft["id"]
                break
        city_built_buildings.append({"id": building_id, "recipe": recipe_id})

        # Автоматически назначаем горожанина на новое здание, если есть свободные
        var main_map = get_tree().root.find_child("MainMap", true, false)
        if main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            tm.assign_townsfolk()

        emit_signal("city_updated")
        return true
    else:
        print("Недостаточно еды для постройки ", bdata.get("name", building_id))
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
