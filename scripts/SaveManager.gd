# SaveManager.gd (Autoload)
extends Node

const SAVE_PATH = "user://savegame.json"
var is_loaded = false
var saved_data = {}   # сюда будем складывать все данные при загрузке

func save_game():
    var main_map = Engine.get_main_loop().root.get_node_or_null("MainMap")
    if not main_map:
        printerr("Ошибка сохранения: MainMap не найден")
        return

    var data = {
        "city_storage": CityData.city_storage,
        "production_rates": CityData.production_rates,
        "consumption_rates": CityData.consumption_rates,
        "city_food_pool": CityData.city_food_pool,
        "city_built_buildings": CityData.city_built_buildings,
        "domesticated_animals": CityData.domesticated_animals,
        "domesticated_plants": CityData.domesticated_plants,
        "unlocked_technologies": CityData.unlocked_technologies,
        "current_research_tech_id": CityData.current_research_tech_id,
        "current_research_time": CityData.current_research_time,
        "research_progress": CityData.research_progress,
        "total_population": CityData.total_population,
        "workers": CityData.workers,
        "townsfolk": CityData.townsfolk,
        "scholars": CityData.scholars,
        "food_for_new_settler": CityData.food_for_new_settler,
        "food_per_citizen": CityData.food_per_citizen,
        "tile_data": _serialize_tile_data(main_map),
        "worker_assignments": main_map.worker_manager.serialize_assignments()
    }
    var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
    if file:
        file.store_string(JSON.stringify(data, "\t"))
        print("Игра сохранена.")
    else:
        printerr("Ошибка сохранения игры!")

func load_game() -> bool:
    if not FileAccess.file_exists(SAVE_PATH):
        return false
    var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
    if file:
        var text = file.get_as_text()
        var data = JSON.parse_string(text)
        if data == null:
            return false
        saved_data = data
        is_loaded = true
        print("Игра загружена.")
        return true
    return false

func apply_loaded_data():
    # Вызывается из main_map.gd после готовности сцены
    CityData.city_storage = saved_data.get("city_storage", {})
    CityData.production_rates = saved_data.get("production_rates", {})
    CityData.consumption_rates = saved_data.get("consumption_rates", {})
    CityData.city_food_pool = saved_data.get("city_food_pool", {})
    CityData.city_built_buildings = saved_data.get("city_built_buildings", [])
    CityData.domesticated_animals = saved_data.get("domesticated_animals", [])
    CityData.domesticated_plants = saved_data.get("domesticated_plants", [])
    CityData.unlocked_technologies = saved_data.get("unlocked_technologies", [])
    CityData.current_research_tech_id = saved_data.get("current_research_tech_id", "")
    CityData.current_research_time = saved_data.get("current_research_time", 0.0)
    CityData.research_progress = saved_data.get("research_progress", 0.0)
    CityData.total_population = saved_data.get("total_population", CityData.total_population)
    CityData.workers = saved_data.get("workers", CityData.workers)
    CityData.townsfolk = saved_data.get("townsfolk", CityData.townsfolk)
    CityData.scholars = saved_data.get("scholars", CityData.scholars)
    CityData.food_for_new_settler = saved_data.get("food_for_new_settler", CityData.food_for_new_settler)
    CityData.food_per_citizen = saved_data.get("food_per_citizen", CityData.food_per_citizen)
    # tile_data будет восстановлен отдельно

func new_game():
    GameData.load_all_data()
    CityData.setup()
    is_loaded = false
    saved_data.clear()
    print("Новая игра начата.")

func has_save() -> bool:
    return FileAccess.file_exists(SAVE_PATH)

func _serialize_tile_data(main_map: Node) -> Array:
    var result = []
    var rows = main_map.tile_data.size()
    for row in range(rows):
        var row_arr = []
        var cols = main_map.tile_data[row].size()
        for col in range(cols):
            var tile = main_map.get_tile_data(row, col)
            if tile:
                row_arr.append({
                    "terrain": tile.get("terrain", "plain"),
                    "resource": tile.get("resource"),
                    "improvement": tile.get("improvement"),
                    "terrain_icon": tile.get("terrain_icon", ""),
                    "in_influence": tile.get("in_influence", false)
                })
            else:
                row_arr.append({})
        result.append(row_arr)
    return result
