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

        var has_worker = false
        if tm:
            has_worker = tm.has_townsfolk(i)

        if not has_worker:
            continue

        var recipe = null
        for c in GameData.crafts:
            if c["id"] == recipe_id:
                recipe = c
                break
        if not recipe:
            continue

        var can_craft = true
        for res in recipe["resources"]:
            if city_storage.get(res, 0) < recipe["resources"][res]:
                can_craft = false
                break

        if can_craft:
            for res in recipe["resources"]:
                city_storage[res] -= recipe["resources"][res]
                consumption_rates[res] += recipe["resources"][res]
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

    var main_map = get_tree().root.find_child("MainMap", true, false)

    if available_food >= food_for_new_settler and total_population > 0:
        total_population += 1
        idle_population += 1  # новый житель пока свободен

        # --- ПЫТАЕМСЯ НАЗНАЧИТЬ НА ВАКАНСИЮ ПО ПРИОРИТЕТУ ---
        # Сначала пытаемся найти свободное улучшение на карте
        var assigned = false
        if main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            assigned = wm.assign_worker()  # пытается взять жителя из idle_population

        # Если не удалось — пытаемся найти свободное здание в городе
        if not assigned and main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            assigned = tm.assign_townsfolk()

        # Если никуда не назначился — остаётся в idle_population

        # Списываем еду за нового жителя
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

    elif available_food <= 0 and total_population > 1:
        total_population -= 1
        # Умирает кто-то из занятых (сначала учёные, потом горожане, потом рабочие)
        # Пока учёных нет, снимаем горожанина или рабочего
        var removed = false
        if main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            for i in range(city_built_buildings.size()):
                if tm.has_townsfolk(i):
                    tm.remove_townsfolk(i)  # возвращает жителя в idle_population
                    removed = true
                    break
        if not removed and main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            # Убираем первого попавшегося рабочего
            for key in wm.assigned_hexes.keys():
                var parts = key.split(",")
                if parts.size() == 2:
                    wm.remove_worker(int(parts[0]), int(parts[1]))
                    removed = true
                    break
        if not removed:
            # Если никто не занят — просто уменьшаем idle_population
            idle_population -= 1

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
