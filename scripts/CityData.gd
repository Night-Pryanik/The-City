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
var current_research_time: float = 0.0   # время в секундах на изучение
var research_progress: float = 0.0       # 0.0 .. 1.0

const PRODUCTION_INTERVAL: float = 2.0

signal city_updated()
signal research_completed(tech_id: String)
signal research_error(message: String)

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

    for pid in GameData.products.keys():
        city_storage[pid] = 0
        production_rates[pid] = 0
        consumption_rates[pid] = 0
        if GameData.products[pid].get("category") == "food":
            city_food_pool[pid] = true

    # Стартовый запас еды (мясо) для первой постройки
    if city_storage.has("meat"):
        city_storage["meat"] = 10

func reset_counters():
    for pid in production_rates.keys():
        production_rates[pid] = 0
        consumption_rates[pid] = 0

func add_raw_production(raw_id: String):
    if Engine.is_editor_hint():
        return
    var raw = GameData.raw_resources.get(raw_id, {})
    if raw.has("produces"):
        for pid in raw["produces"]:
            var amount = raw["produces"][pid]
            if city_storage.has(pid):
                city_storage[pid] += amount
                production_rates[pid] += amount

func do_tick():
    if Engine.is_editor_hint():
        return
    for bld in city_built_buildings:
        var recipe_id = bld.get("recipe", "")
        if recipe_id == "":
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
    emit_signal("city_updated")

# --- Исследования ---

func start_research(tech_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    if current_research_tech_id != "":
        # Находим название текущей технологии для сообщения об ошибке
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
        emit_signal("research_error", "Начато исследование: " + tech_data["name"])
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
