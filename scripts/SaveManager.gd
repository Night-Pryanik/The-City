# SaveManager.gd (Autoload)
extends Node

const SAVE_PATH = "user://savegame.json"
var is_loaded = false
var saved_data = {}

func save_game():
    var main_map = Engine.get_main_loop().root.get_node_or_null("MainMap")
    if not main_map:
        printerr("Save error: MainMap not found")
        return

    var build_manager = main_map.get_node_or_null("BuildManager")
    var data = {
        "city_storage": CityData.city_storage,
        "city_quality_detail": CityData.city_quality_detail,
        "production_rates": CityData.production_rates,
        "consumption_rates": CityData.consumption_rates,
        "city_food_pool": CityData.city_food_pool,
        # The internal market (the "Trade" tab): the consumption permission
        # toggles and the per-quality write-off priority. The keys are display_key
        # (the product id or "@group").
        "market_consumption_enabled": CityData.market_consumption_enabled,
        "consumption_priority": CityData.consumption_priority,
        "city_built_buildings": _serialize_buildings(CityData.city_built_buildings),
        "domesticated_animals": CityData.domesticated_animals,
        "domesticated_plants": CityData.domesticated_plants,
        "domesticated_resources": CityData.domesticated_resources,
        "unlocked_technologies": CityData.unlocked_technologies,
        "current_research_tech_id": CityData.current_research_tech_id,
        "current_research_science_cost": CityData.current_research_science_cost,
        "research_science_accumulated": CityData.research_science_accumulated,
        "research_progress": CityData.research_progress,
        "current_era_index": CityData.current_era_index,
        "total_population": CityData.total_population,
        "idle_population": CityData.idle_population,
        "food_for_new_settler": CityData.food_for_new_settler,
        "food_per_citizen": CityData.food_per_citizen,
        "treasury": CityData.treasury,
        "tile_data": _serialize_tile_data(main_map),
        "worker_assignments": main_map.worker_manager.serialize_assignments(),
        # The occupational consumption timers: for each worker with
        # a profession we store how many seconds have passed since the last write-off.
        # The interval is recalculated from the profession on loading, therefore
        # we store only elapsed.
        "profession_consumption_timers": main_map.worker_manager.serialize_consumption_timers(),
        # The city consumption timers of the pseudo-profession "all" (all citizens):
        # we store only elapsed per display_key; the interval is recalculated
        # from the data on loading.
        "city_consumption_timers": main_map.worker_manager.serialize_city_consumption_timers(),
        # The occupational consumption timers of CITY BUILDINGS (the
        # "profession" field in data/buildings.json): the key is the building index,
        # we store only the fractional remainders (the intervals are recalculated
        # from the data).
        "building_profession_consumption_timers": main_map.worker_manager.serialize_building_consumption_timers(),
        "townsfolk_assignments": main_map.townsfolk_manager.serialize_assignments(),
        "active_builds": build_manager.active_builds if build_manager else {},
        "active_building_builds": build_manager.active_building_builds if build_manager else {},
        "active_expansion_builds": build_manager.active_expansion_builds if build_manager else {},
        # The unfinished staged projects (the queue of road segments). It is
        # the queue itself that is saved, and not the road segments: the segments,
        # as all the other roads, are restored from the hex flags.
        "active_projects": _serialize_projects(main_map),
        "building_construction": CityData.building_construction,
        "rivers": main_map.river_manager.serialize_rivers(),
        "towns": main_map.town_manager.serialize_towns(),
        "map_state": main_map.get_map_state(),
        "city_name": CityData.city_name
    }
    var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
    if file:
        file.store_string(JSON.stringify(data, "\t"))
        print("The game is saved.")
    else:
        printerr("Game save error!")

func load_game() -> bool:
    if not FileAccess.file_exists(SAVE_PATH):
        return false
    var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
    if file:
        var text = file.get_as_text()
        var parsed = JSON.parse_string(text)
        var data = null
        if parsed is Dictionary:
            data = parsed
        else:
            if parsed.error != OK:
                printerr("Save loading error: ", parsed.error_string)
                return false
            data = parsed.result

        if data == null:
            return false
        saved_data = data
        is_loaded = true
        print("The game is loaded.")
        return true
    return false

func apply_loaded_data():
    # Called from main_map.gd after the scene is ready
    CityData.city_storage = saved_data.get("city_storage", {})
    CityData.city_quality_detail = saved_data.get("city_quality_detail", {})
    CityData.production_rates = saved_data.get("production_rates", {})
    CityData.consumption_rates = saved_data.get("consumption_rates", {})
    CityData.city_food_pool = saved_data.get("city_food_pool", {})
    # The internal market settings (the "Trade" tab). The missing keys mean that
    # everything is permitted and the default priority is taken, which is exactly
    # what an empty dictionary does: CityData treats a missing key precisely that way.
    CityData.market_consumption_enabled = saved_data.get("market_consumption_enabled", {})
    CityData.consumption_priority = saved_data.get("consumption_priority", {})
    CityData.city_built_buildings = saved_data.get("city_built_buildings", [])

    # We supplement the storage with the missing products (in case the save has no
    # products added to the game later — for example, pots/bricks/clay).
    for pid in GameData.products.keys():
        if not CityData.city_storage.has(pid):
            CityData.city_storage[pid] = 0
        if not CityData.production_rates.has(pid):
            CityData.production_rates[pid] = 0
        if not CityData.consumption_rates.has(pid):
            CityData.consumption_rates[pid] = 0
        if GameData.products[pid].get("category") == "food":
            CityData.city_food_pool[pid] = true

    CityData.domesticated_animals = saved_data.get("domesticated_animals", [])
    CityData.domesticated_plants = saved_data.get("domesticated_plants", [])
    CityData.domesticated_resources = saved_data.get("domesticated_resources", [])
    if CityData.domesticated_resources.is_empty():
        CityData.domesticated_resources.append_array(CityData.domesticated_animals)
        CityData.domesticated_resources.append_array(CityData.domesticated_plants)
    CityData.unlocked_technologies = saved_data.get("unlocked_technologies", [])
    # Crop growing is always unlocked at the start of the game — we add it if absent
    if not ("farming" in CityData.unlocked_technologies):
        CityData.unlocked_technologies.append("farming")
    CityData.current_research_tech_id = saved_data.get("current_research_tech_id", "")
    CityData.current_research_science_cost = saved_data.get("current_research_science_cost", 0)
    CityData.research_science_accumulated = saved_data.get("research_science_accumulated", 0.0)
    CityData.research_progress = saved_data.get("research_progress", 0.0)
    # The current era. If the field is absent, the value is
    # restored from map_state in main_map._apply_saved_map_state().
    CityData.current_era_index = saved_data.get("current_era_index", 0)
    CityData.total_population = saved_data.get("total_population", CityData.total_population)
    CityData.idle_population = saved_data.get("idle_population", CityData.idle_population)
    CityData.food_for_new_settler = saved_data.get("food_for_new_settler", CityData.food_for_new_settler)
    CityData.food_per_citizen = saved_data.get("food_per_citizen", CityData.food_per_citizen)
    # The city treasury. If the field is absent, the starting
    # amount is restored from game_balance.json (initial_treasury), just as on a new game.
    CityData.treasury = int(saved_data.get("treasury", int(GameData.game_balance.get("initial_treasury", 10))))
    # We restore the building constructions (their construction progress is stored in build_manager)
    CityData.building_construction = saved_data.get("building_construction", {})
    # tile_data will be restored separately

    # The city name. If the field is absent, a random one is substituted.
    CityData.city_name = saved_data.get("city_name", "")
    if CityData.city_name.is_empty():
        GameData.load_all_data()
        CityData.city_name = GameData.get_random_city_name()

func new_game():
    GameData.load_all_data()
    CityData.setup()
    is_loaded = false
    saved_data.clear()
    print("A new game has started.")

func has_save() -> bool:
    return FileAccess.file_exists(SAVE_PATH)

# Building serialization: it converts CraftContainer (RefCounted) into a flat
# dict, so that JSON.stringify does not fail on a non-standard type. On loading the
# dict is restored lazily in CityData.get_slot_containers() (the common entry
# point for _ensure_slot_container and the UI) via CraftContainer(recipe, slot_data).
func _serialize_buildings(buildings: Array) -> Array:
    var out: Array = []
    if not (buildings is Array):
        return out
    for bld in buildings:
        if not (bld is Dictionary):
            out.append(bld)
            continue
        var copy: Dictionary = bld.duplicate(true)
        var conts = copy.get("slot_containers", null)
        if conts is Array:
            var serialized: Array = []
            for c in conts:
                if c == null:
                    serialized.append(null)
                elif c is CraftContainer:
                    serialized.append(c.serialize())
                elif c is Dictionary:
                    serialized.append(c.duplicate(true))
                else:
                    serialized.append(null)
            copy["slot_containers"] = serialized
        out.append(copy)
    return out

# The queue of steps of the unfinished staged projects for the save. There may be no
# manager (an old game without the node) — then we save an empty queue.
func _serialize_projects(main_map: Node) -> Dictionary:
    var project_manager = main_map.get_node_or_null("ProjectManager")
    if project_manager == null or not project_manager.has_method("serialize_projects"):
        return {}
    return project_manager.serialize_projects()

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
                    "cover": tile.get("cover", "none"),
                    "resource": tile.get("resource"),
                    "improvement": tile.get("improvement"),
                    "decorative": tile.get("decorative", false),
                    # crop_bred — the id of the animal/plant bred on an empty
                    # hex via building a pasture/farm. null if the hex
                    # is not used for breeding. It is saved to the save,
                    # so that after a reload the breeding of the same species continues.
                    "crop_bred": tile.get("crop_bred"),
                    # fill_time — the accumulated time of filling up the headcount
                    # (time_to_mature). It is saved so that after loading
                    # the pasture does not start filling up again from zero.
                    "fill_time": tile.get("fill_time", 0.0),
                    # production_fractional_remainder — the fractional remainder
                    # the sub-unit accumulator of continuous production (see
                    # main_map._emit_continuous_production). It is saved
                    # so that the average rate does not drop to zero on
                    # loading. The old production_progress key is no longer
                    # written — it was for the batch model.
                    "production_fractional_remainder": tile.get("production_fractional_remainder", 0.0),
                    # feed_fractional_remainder — the fractional remainder of the feed
                    # (see main_map._consume_feed_continuous). It is saved
                    # for the same reason.
                    "feed_fractional_remainder": tile.get("feed_fractional_remainder", 0.0),
                    "quality": tile.get("quality", ""),
                    "terrain_icon": tile.get("terrain_icon", ""),
                    "in_influence": tile.get("in_influence", false),
                    "is_explored": tile.get("is_explored", false),
                    "river_edges": tile.get("river_edges", []),
                    # road_built — the fact that "the player has built a road to this hex"
                    # (the "Build road" special action). The road segments themselves
                    # are not written to the save, neither for the city nor for the
                    # towns: the network is recalculated on loading, and this flag is
                    # enough as the input data (road_manager.rebuild_player_roads).
                    "road_built": tile.get("road_built", false),
                    # road_level — the level of the road by which this hex
                    # is connected to the network (data/roads.json). The segments
                    # with levels, as well as the segments themselves, are not written
                    # to the save, therefore the level
                    # lies on the hex next to road_built: without it the network
                    # would be restored as a solid trail.
                    "road_level": tile.get("road_level", 1),
                    # road_staged — the road to an improvement on this hex goes as
                    # a staged project. Its state is stored by road_built and
                    # road_level on the connected hexes plus the project
                    # queue; without this flag the network recalculation "by the fact
                    # of an improvement" (road_manager.rebuild_roads_from_existing)
                    # would consider the hex ready and finish the rest of the route
                    # for free. The roads to the improvements, as before, are implied
                    # by the improvement.
                    "road_staged": tile.get("road_staged", false)
                })
            else:
                row_arr.append({})
        result.append(row_arr)
    return result
