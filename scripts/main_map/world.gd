@tool
extends "res://scripts/main_map/knowledge.gd"

# This link — the world itself: the generation of the map, the boundaries of the Ring and of the
# Region, the transition to the next era, the state of the map in the save and the debug reveal
# of the whole map.

# The loading bar of a new game or a loaded save. It lives on the ROOT (see LoadingOverlay):
# the scene change frees the menu, while the world is still being built or restored here.
# Without an overlay (a test, the editor, a direct scene run) the calls do nothing.
func _update_loading_progress(value: float, status: String = "") -> void:
    if _loading_overlay == null:
        return
    var bar = _loading_overlay.get_node_or_null("VBoxContainer/ProgressBar")
    if bar != null:
        bar.value = clampf(value, 0.0, 1.0)
    var label = _loading_overlay.get_node_or_null("VBoxContainer/StatusLabel")
    if label != null and status != "":
        label.text = status

func _remove_loading_overlay() -> void:
    if _loading_overlay != null:
        _loading_overlay.queue_free()
        _loading_overlay = null

# One frame of the loading screen. Without it the stages of the generation would run
# inside a single frame and the bar would jump from 0 to 100. The stages run in one go
# when there is no loading screen (a test, the editor, a direct scene run).
func _yield_loading_frame() -> void:
    if _loading_overlay == null:
        return
    await get_tree().process_frame

func _initialize_map():
    world_generating = true
    GameData.load_all_data()
    var selected_city_name = CityData.city_name
    CityData.setup()
    CityData.city_name = selected_city_name
    map_renderer.load_icons()

    # We set the starting sizes of the Ring and the Region from the configuration.
    ring_rows = start_ring_rows
    ring_cols = start_ring_cols
    region_rows = ring_rows + region_width * 2
    region_cols = ring_cols + region_width * 2
    _recalculate_bounds()

    # We remember the starting boundaries (the Ring + the visible window). They are needed for
    # the guarantees of the spawn of the resources, so that the metal and food_plant do NOT appear beyond
    # the initially visible area even after the expansion to a new era.
    start_influence_start_row = influence_start_row
    start_influence_end_row = influence_end_row
    start_influence_start_col = influence_start_col
    start_influence_end_col = influence_end_col
    start_region_start_row = region_start_row
    start_region_end_row = region_end_row
    start_region_start_col = region_start_col
    start_region_end_col = region_end_col

    # The world is built in STAGES, with a frame between them: the generation of the
    # whole map (the relief, the cover, the resources) is long enough for the player to
    # wonder whether the game has hung, therefore the loading bar of the new game is
    # advanced between the stages (see _update_loading_progress). Without a loading
    # screen (a test, the editor, a direct scene run) the stages run in one go
    # (see _yield_loading_frame).
    var generator = load("res://scripts/map_generator.gd").new()
    # The number of the Voronoi centres for each terrain type is computed
    # from the configuration terrain_config (density + target_cluster),
    # set in data/map_config.json.
    var terrain_counts = generator.make_terrain_counts(map_rows, map_cols)

    _update_loading_progress(0.05, tr("Generating seas..."))
    await _yield_loading_frame()
    tile_data = generator.init_tile_data(map_rows, map_cols)
    var sea_mask = generator.apply_sea_mask(tile_data, map_rows, map_cols, city_row, city_col)

    _update_loading_progress(0.15, tr("Generating relief..."))
    await _yield_loading_frame()
    generator.generate_relief(tile_data, map_rows, map_cols, city_row, city_col, terrain_counts)

    _update_loading_progress(0.35, tr("Shaping landscape..."))
    await _yield_loading_frame()
    generator.post_process_relief(tile_data, map_rows, map_cols, sea_mask, city_row, city_col)

    _update_loading_progress(0.50, tr("Applying climate..."))
    await _yield_loading_frame()
    generator.apply_climate_and_covers(tile_data, map_rows, map_cols)

    _update_loading_progress(0.65, tr("Placing resources..."))
    await _yield_loading_frame()
    generator.place_all_resources(tile_data, GameData.raw_resources, map_rows, map_cols, city_row, city_col)

    _update_loading_progress(0.75, tr("Finalizing terrain..."))
    await _yield_loading_frame()
    generator.ensure_outward_corridor(tile_data, map_rows, map_cols, city_row, city_col)
    print("The map of the world has been generated. Hexes: ", map_rows * map_cols)

    _update_loading_progress(0.80, tr("Preparing starting area..."))
    await _yield_loading_frame()

    # We guarantee that the city is on a permitted terrain (a plain or the hills)
    _ensure_city_valid_terrain()

    # We mark the starting Influence Ring and reset the research.
    # The flags are set for the WHOLE map, because the generators (place_wild_food and so on)
    # iterate over all the hexes and refer to "in_influence".
    for row in range(map_rows):
        for col in range(map_cols):
            var tile = tile_data[row][col]
            tile["in_influence"] = is_in_influence(row, col)
            tile["is_explored"] = false

    # We collect the hexes of a unique terrain (for example, a soda lake).
    # They are displayed on the map even beyond the visible Region
    # (see map_renderer._draw), therefore we store them in a separate list.
    unique_terrain_hexes = []
    for row in range(map_rows):
        for col in range(map_cols):
            var terrain_id = tile_data[row][col].get("terrain", "plain")
            var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
            if t_data.get("unique", false):
                unique_terrain_hexes.append({"row": row, "col": col})

    # The hexes of the towns and of the influence ring are mirrored AFTER town_manager.generate_towns
    # below (it itself calls compute_all_town_influences at the end, see the script town_manager).
    # Here we do not mirror anything yet: the master copies are still empty.

    # The wild plants and the guaranteed food_plant spawn ONLY once at the
    # start of a new game and ONLY inside the starting Influence Ring.
    # We pass the explicit boundaries of the starting Ring, so that these functions never
    # go beyond its limits (even if the Ring expands later).
    _ensure_food_plant(influence_start_row, influence_end_row, influence_start_col, influence_end_col, city_row, city_col)
    generator.place_wild_food(tile_data,
            influence_start_row, influence_end_row, influence_start_col, influence_end_col,
            city_row, city_col)

    # The resources which occur in the Influence Ring are not duplicated in the Region.
    var influence_resource_types = {}
    for row in range(influence_start_row, influence_end_row + 1):
        for col in range(influence_start_col, influence_end_col + 1):
            var res = tile_data[row][col]["resource"]
            if res != null:
                influence_resource_types[res] = true

    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            if not tile_data[row][col]["in_influence"]:
                var res = tile_data[row][col]["resource"]
                if res != null and influence_resource_types.has(res):
                    tile_data[row][col]["resource"] = null

    # --- The guarantees for the starting area "Ring + Region" ---
    # We use the starting boundaries (and not the current ones), so that on a future
    # expansion to a new era it does not fire again. At the moment in the game
    # the only metal is the iron; when adding a new one the function will choose
    # one of them at random. The same for the other categories below.
    #
    # The food plant is guaranteed separately (see _ensure_food_plant above)
    # and remains ONLY in the starting Ring — the player must have the possibility
    # to put a farm immediately without the scouting/buying of the region.
    _ensure_minimum_resource({"category": "metals"})
    _ensure_minimum_resource({"category": "minerals", "subgroup": "construction_materials"})

    # --- The post-processing: we guarantee a sufficient number of FREE hexes ---
    # After the placement of all the resources of each terrain type in the Influence Ring
    # there must remain at least FREE_TERRAIN_HEXES free (resource == null)
    # hexes. This excludes a soft-lock: if a resource (for example, quinoa — only the mountains)
    # has got into the ring, the player will always have a place for the additional farms/pastures.
    # The method converts ONLY the free hexes and NEVER destroys the resources.
    generator.ensure_free_terrain_hexes(tile_data, terrain_counts,
            influence_start_row, influence_end_row, influence_start_col, influence_end_col,
            city_row, city_col)

    # We use a LOCAL generator of random numbers for the choice of the icon of the landscape.
    # Under no circumstances may seed()/randomize() be called on the global RNG inside
    # this loop — it would destroy the randomness of all the subsequent randf()/randi()
    # (for example, on the spawn of the resources after the learning of the technologies).
    var icon_rng = RandomNumberGenerator.new()
    for row in range(map_rows):
        for col in range(map_cols):
            var tile = tile_data[row][col]
            var terrain_id = tile.terrain
            if GameData.terrains.has(terrain_id):
                var t = GameData.terrains[terrain_id]
                if t.has("icons"):
                    var icons_array = t.icons
                    if icons_array.size() > 0:
                        icon_rng.seed = row * 1000 + col
                        var idx = icon_rng.randi() % icons_array.size()
                        tile["terrain_icon"] = icons_array[idx]
                elif t.has("icon"):
                    tile["terrain_icon"] = t.icon
                else:
                    tile["terrain_icon"] = ""

    # We generate the river system (the main rivers + the tributaries) over the whole map
    # and mark the river edges in the data of the hexes. We pass tile_data (for the mountains/lakes).
    _update_loading_progress(0.90, tr("Carving rivers..."))
    await _yield_loading_frame()
    river_manager.generate_rivers(map_rows, map_cols, HEX_RADIUS, tile_data)
    river_manager.mark_river_edges(tile_data, map_rows, map_cols, HEX_RADIUS, river_manager.get_cached_graph())

    # --- The towns (the small settlements) ---
    # They are placed AFTER the rivers, so that river_edges have already been set and
    # are used as the points of attraction (priority 2). The number of the towns is chosen
    # by the player in the world settings of a new game (CityData.world_town_count),
    # the priorities are fixed in scripts/town_manager.gd.
    #
    # We pass two areas:
    #   exclusion_* — the starting visible area (the Ring + the starting Region).
    #     Inside it the towns do NOT spawn, otherwise they would be visible from the very
    #     beginning of the game and the sense of "the small unknown settlements" would be lost.
    #   era2_region_* — the visible area of the 2nd era (Ring_2 + Region_2).
    #     This is the "mandatory zone" for the guarantee: at least 1 town must
    #     get there, so that on the transition to the 2nd era the player can immediately
    #     see someone and start trading.
    var era2_region_bounds: Dictionary = _compute_era2_region_bounds()
    _update_loading_progress(0.95, tr("Founding towns..."))
    await _yield_loading_frame()
    town_manager.generate_towns(tile_data, map_rows, map_cols, city_row, city_col,
            start_region_start_row, start_region_end_row,
            start_region_start_col, start_region_end_col,
            era2_region_bounds.start_row, era2_region_bounds.end_row,
            era2_region_bounds.start_col, era2_region_bounds.end_col)

    # The mirrors town_hexes / town_influence_hexes are built ONLY AFTER generate_towns:
    # town_manager calls compute_all_town_influences at the end of generate_towns, and only
    # after that do both master copies contain the data. Built earlier, the mirror would
    # silently copy the emptiness and the rings would not be drawn at all.
    town_hexes = []
    for h in town_manager.town_hexes:
        town_hexes.append({"row": h.row, "col": h.col})
    town_influence_hexes = []
    for h in town_manager.town_influence_hexes:
        town_influence_hexes.append({"row": h.row, "col": h.col})
    # The full records of the towns — a reference to the master list of the manager (and not a snapshot):
    # the renderer reads the per-town rings and the colours, and any future edits in
    # town_manager are immediately reflected on the map without a repeated mirroring.
    towns = town_manager.towns

    # The final guarantee: on the hex of the city there should be no resource, and the terrain
    # must be a permitted one (plain or hill). It is a safety-net for the case,
    # if some function of the spawn of the resources or of the conversion of the terrain
    # has missed the check of the coordinates of the city.
    _ensure_city_hex_clean()
    # We mark the hex of the city with the flag is_city — the logic of the water (MapHelpers) counts
    # it as a conductor/source, when the water is really brought to the city.
    _mark_city_hex()
    generator.free()
    world_generating = false

func _mark_city_hex() -> void:
    if city_row >= 0 and city_row < map_rows and city_col >= 0 and city_col < map_cols:
        tile_data[city_row][city_col]["is_city"] = true

func _ensure_city_valid_terrain() -> void:
    MapHelpers.ensure_city_valid_terrain(tile_data, city_row, city_col, map_rows, map_cols)

func _is_hex_irrigated(row: int, col: int) -> bool:
    return MapHelpers.is_hex_irrigated(row, col, tile_data, map_rows, map_cols)

func _ensure_minimum_resource(filter: Dictionary):
    # The guarantee works by the STARTING boundaries "Ring + Region", and not by the
    # current ones (which can be expanded by a transition to a new era).
    # It is used on the initialization of the map, so that in the starting area
    # there is always at least one resource satisfying the filter.
    # Examples of the filters:
    #   { "category": "metals" }                                          — any metal
    #   { "category": "animals", "group": "meat_animals" }                — a meat animal
    #   { "category": "minerals", "subgroup": "construction_materials" }  — a construction material
    MapHelpers.ensure_minimum_resource(
        tile_data, filter,
        start_influence_start_row, start_influence_end_row,
        start_influence_start_col, start_influence_end_col,
        city_row, city_col
    )

# Guarantees the presence of at least one resource from food_plants in the starting Ring.
# It is called ONLY once at the start of a new game (from _initialize_map).
# The boundaries (min_row..max_row, min_col..max_col) are the starting Ring,
# therefore the food_plant is guaranteed not to appear beyond its limits
# and is not recreated after the start.
func _ensure_food_plant(min_row: int, max_row: int, min_col: int, max_col: int, city_row_arg: int = -1, city_col_arg: int = -1):
    MapHelpers.ensure_food_plant(tile_data, min_row, max_row, min_col, max_col, city_row_arg, city_col_arg)

# The final safety-check: it guarantees that on the hex of the city there is no resource
# and the terrain is valid. It is called after all the stages of the generation of the map.
func _ensure_city_hex_clean() -> void:
    var city_tile = tile_data[city_row][city_col]
    if city_tile.get("resource", null) != null:
        print("WARNING: a resource was standing on the hex of the city '", city_tile["resource"], "' — it has been removed.")
        city_tile["resource"] = null
    _ensure_city_valid_terrain()

# Looks on the map for an already domesticated instance of the resource res_id (a hex with this resource
# and a built improvement — a farm/pasture) and returns its quality.
# It is used on the breeding of a new animal/plant on an empty hex:
# the quality is inherited from the already domesticated specimen
# ("exceptional produces exceptional"). If there is no such specimen —
# it returns an empty string, and the calling code generates the quality through roll.
func _find_domesticated_quality(res_id: String) -> String:
    return MapHelpers.find_domesticated_quality(
        res_id, tile_data,
        region_start_row, region_end_row,
        region_start_col, region_end_col
    )

# Chooses the icon of the landscape for the hex (row, col) based on its terrain.
func _assign_terrain_icon(row: int, col: int) -> void:
    tile_data[row][col]["terrain_icon"] = MapHelpers.get_terrain_icon(row, col, tile_data)

# Loads the map parameters for a new game. The map size is chosen by the player
# in the world settings (CityData.world_map_size); the rest of the parameters come
# from data/map_config.json (through GameData). A loaded game overrides the size
# from its save via _apply_saved_map_state.
func _load_map_config():
    var size: int = CityData.world_map_size
    if size < 10:
        size = 60
    map_rows = size
    map_cols = size

    var cfg: Dictionary = GameData.map_config
    start_ring_rows = int(cfg.get("start_ring_rows", 7))
    start_ring_cols = int(cfg.get("start_ring_cols", 5))
    region_width = int(cfg.get("region_width", 2))

    # The city is always at the centre of the whole map.
    city_row = int(map_rows / 2.0)
    city_col = int(map_cols / 2.0)

# Recalculates the ABSOLUTE boundaries of the Influence Ring and of the visible window
# (the Ring + the Region) around the city. It is called after a change of
# ring_rows/ring_cols/region_rows/region_cols (a new game, a loading, an era).
func _recalculate_bounds():
    var bounds = MapHelpers.recalculate_bounds(
        city_row, city_col,
        ring_rows, ring_cols,
        region_rows, region_cols,
        map_rows, map_cols
    )
    influence_start_row = bounds.influence_start_row
    influence_end_row = bounds.influence_end_row
    influence_start_col = bounds.influence_start_col
    influence_end_col = bounds.influence_end_col
    region_start_row = bounds.region_start_row
    region_end_row = bounds.region_end_row
    region_start_col = bounds.region_start_col
    region_end_col = bounds.region_end_col

# Returns a dictionary with the current state of the world/window for the save.
#
# start_region_* — the boundaries of the STARTING area of the player (the Ring + the Region of the 1st era)
# at the moment of the generation. They do not change during the whole game, but they are needed after the loading:
# by them the territory of the towns is cut out of the starting area (see
# town_manager.set_player_start_area), otherwise the loaded game would get
# towns creeping onto the land of the player. It is impossible to recalculate them from start_ring_* and
# region_width: region_width in the save may have already changed on the transition to
# the next era.
func get_map_state() -> Dictionary:
    return {
        "map_rows": map_rows,
        "map_cols": map_cols,
        "start_ring_rows": start_ring_rows,
        "start_ring_cols": start_ring_cols,
        "region_width": region_width,
        "ring_rows": ring_rows,
        "ring_cols": ring_cols,
        "region_rows": region_rows,
        "region_cols": region_cols,
        "current_era": current_era,
        "debug_whole_map_revealed": debug_whole_map_revealed,
        "start_region_start_row": start_region_start_row,
        "start_region_end_row": start_region_end_row,
        "start_region_start_col": start_region_start_col,
        "start_region_end_col": start_region_end_col,
    }

# Computes the absolute boundaries of the VISIBLE area of the 2nd era
# (Ring_2 + Region_2). It is used by town_manager as the "mandatory
# zone" for the guarantee "≥1 town in the era-2".
#
#
# The scheme (see advance_to_next_era):
#   1) everything current (the Ring + the Region) is scouted for free and joined;
#   2) the old (the Ring + the Region) becomes the new Ring;
#   3) around the new Ring a new Region of the width era2_region_width is formed.
#
# The dimensions:
#   ring_2  = region_1   = (start_ring + start_region_width*2)
#   region_2 = ring_2 + era2_region_width*2
# The absolute boundaries are counted from the centre of the city and are clipped by the map.
func _compute_era2_region_bounds() -> Dictionary:
    # The width of the Region of the second era. By default — the current region_width
    # (for the old eras.json without the field region_width). If in data/eras.json
    # the era with the index 1 (the second by count, counting the ancient one as 0) has
    # its own value — we take it.
    var era2_region_width: int = region_width
    if GameData.eras.size() >= 2:
        var era2_data: Dictionary = GameData.eras[1]
        if era2_data.has("region_width"):
            era2_region_width = int(era2_data.get("region_width", region_width))

    # The Ring of the 2nd era = the Region of the 1st era (the starting visible area).
    var era2_ring_rows: int = region_rows
    var era2_ring_cols: int = region_cols
    # The Region of the 2nd era = Ring_2 + era2_region_width*2 in each direction.
    var era2_region_rows: int = era2_ring_rows + era2_region_width * 2
    var era2_region_cols: int = era2_ring_cols + era2_region_width * 2

    var start_row: int = maxi(0, city_row - int(era2_region_rows / 2.0))
    var end_row: int = mini(map_rows - 1, start_row + era2_region_rows - 1)
    var start_col: int = maxi(0, city_col - int(era2_region_cols / 2.0))
    var end_col: int = mini(map_cols - 1, start_col + era2_region_cols - 1)
    return {
        "start_row": start_row,
        "end_row": end_row,
        "start_col": start_col,
        "end_col": end_col,
    }

# Restores the state of the world/window from the save.
# It is called BEFORE the building of tile_data on loading.
func _apply_saved_map_state():
    var st: Dictionary = SaveManager.saved_data.get("map_state", {})
    if not st.is_empty():
        map_rows = int(st.get("map_rows", map_rows))
        map_cols = int(st.get("map_cols", map_cols))
        start_ring_rows = int(st.get("start_ring_rows", start_ring_rows))
        start_ring_cols = int(st.get("start_ring_cols", start_ring_cols))
        region_width = int(st.get("region_width", region_width))
        ring_rows = int(st.get("ring_rows", ring_rows))
        ring_cols = int(st.get("ring_cols", ring_cols))
        region_rows = int(st.get("region_rows", region_rows))
        region_cols = int(st.get("region_cols", region_cols))
        current_era = int(st.get("current_era", 0))
    # We synchronise the era with CityData (the restriction of the learning of the technologies by the eras).
    if st.has("current_era"):
        CityData.current_era_index = current_era
    # The reveal belongs to the save and not to the session: the tiles (is_explored/in_influence)
    # are restored from it, and without this flag a loaded game would hide the rings of the towns
    # behind the era gate again.
    debug_whole_map_revealed = bool(st.get("debug_whole_map_revealed", false))
    city_row = int(map_rows / 2.0)
    city_col = int(map_cols / 2.0)
    _recalculate_bounds()
    _restore_start_region_bounds(st)

# Restores the boundaries of the STARTING area of the player (the Ring + the Region of the 1st era).
# In the save they lie as separate fields of map_state — they cannot be recalculated from
# start_ring_* and region_width, because region_width changes on a change of the era
# and there we recalculate from the starting ring and the current width of the region (for a game
# which started in the 1st era it is the exact value; for a later one — an approximation
# "better than no boundaries at all").
func _restore_start_region_bounds(st: Dictionary) -> void:
    if st.has("start_region_start_row") and st.has("start_region_end_row") \
            and st.has("start_region_start_col") and st.has("start_region_end_col"):
        start_region_start_row = int(st["start_region_start_row"])
        start_region_end_row = int(st["start_region_end_row"])
        start_region_start_col = int(st["start_region_start_col"])
        start_region_end_col = int(st["start_region_end_col"])
        return
    var start_ring_rows_ := start_ring_rows + region_width * 2
    var start_ring_cols_ := start_ring_cols + region_width * 2
    start_region_start_row = maxi(0, city_row - int(start_ring_rows_ / 2.0))
    start_region_end_row = mini(map_rows - 1, start_region_start_row + start_ring_rows_ - 1)
    start_region_start_col = maxi(0, city_col - int(start_ring_cols_ / 2.0))
    start_region_end_col = mini(map_cols - 1, start_region_start_col + start_ring_cols_ - 1)

# --- DEBUG: OPEN THE WHOLE MAP ---
# The whole map at once becomes the Influence Ring: all the hexes are marked
# as belonging to the Ring and as scouted, the boundaries of the Ring/Region
# are expanded to the dimensions of the whole map. After that one can build/improve
# on any hex without the scouting and the purchase of the territory.
# debug_whole_map_revealed lifts the era gate of the rings and of the roads of the towns:
# the reveal is deliberate, so there is nothing left to hide in the 1st era.
func debug_open_whole_map():
    if tile_data.is_empty():
        return

    debug_whole_map_revealed = true

    # We mark each hex as a part of the Influence Ring and as scouted.
    for row in range(map_rows):
        for col in range(map_cols):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            tile["in_influence"] = true
            tile["is_explored"] = true

    # The whole map is open — the knownness has changed, the plans of the roads are recalculated.
    road_manager.bump_map_knowledge()

    # We expand the Ring and the Region to the dimensions of the whole map — is_in_influence()
    # and is_valid_hex() will return true for any coordinates.
    ring_rows = map_rows
    ring_cols = map_cols
    region_rows = map_rows
    region_cols = map_cols

    _recalculate_bounds()
    _calc_offsets()
    # The fill of the rings is filtered by the fog of war, and the reveal changes the fog:
    # the render cache must be dropped explicitly, the Region bounds do not always change.
    map_renderer.invalidate_town_influence_cache()
    map_renderer.queue_redraw()

    if hud:
        hud.show_message(tr("Debug: whole map revealed and inside the Influence Ring (%d×%d)") % [map_rows, map_cols], GameData.HUD_MESSAGE_NORMAL)

# --- THE TRANSITION TO THE NEXT ERA ---
# The infrastructure of the expansion of the world:
#   1. The whole current (not bought) Region is scouted instantly and for free.
#   2. The whole current Region is instantly and for free bought/joined.
#   3. The former Ring + Region become the new Influence Ring.
#   4. Around the new Ring a new Region of the same width is formed.
#   5. The hexes beyond the new Ring + Region are still hidden (the fog of war).
func advance_to_next_era():
    if tile_data.is_empty():
        return

    # The era that is closing is judged by the challenges of the era BEFORE the free claiming of
    # the new Region: the task of restraint counts the chunks the city bought, and what the advance
    # itself gives away for nothing is not a purchase (challenge_manager.era_window_closed).
    if challenge_manager != null:
        challenge_manager.era_window_closed()

    # 1-2. We scout and join the whole current Region for free.
    # The hexes in the influence ring of a foreign town are NOT joined: they must not
    # blocks by in_town_influence), nor to buy a chunk (expansion_manager
    # blocks by the same flag) — this is a "dead zone" in the Region near
    # someone else's town.
    #
    # Such hexes are nevertheless SCOUTED: otherwise they would remain fog
    # and would be drawn as a black hole in the middle of the just claimed territory.
    # A scouted hex is visible (the terrain, the resources) and is marked with the fill of the ring of
    # the town — the player immediately sees whose land it is and why it cannot be bought.
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_town_influence", false)):
                tile["is_explored"] = true
                continue
            tile["is_explored"] = true
            tile["in_influence"] = true

    # The whole Region has become known — the plans of the roads are recalculated (the route to
    # the town goes over the scouted land).
    road_manager.bump_map_knowledge()

    # 3. The former Ring + Region become the new Ring.
    ring_rows = region_rows
    ring_cols = region_cols

    # 4. The new Region: the width is taken from the configurable field region_width
    # of that era, into which we transition (data/eras.json). If the field is not set —
    # the current value remains (backward compatibility with the old eras.json).
    var next_era_index: int = current_era + 1
    if next_era_index >= 0 and next_era_index < GameData.eras.size():
        var era_data: Dictionary = GameData.eras[next_era_index]
        if era_data.has("region_width"):
            region_width = int(era_data.get("region_width", region_width))

    region_rows = ring_rows + region_width * 2
    region_cols = ring_cols + region_width * 2

    # 5. We recalculate the boundaries; the hexes of the new Region are not scouted and not in the influence.
    # The hexes of the rings of the other towns are not touched: we scouted them in the step 1-2 (see
    # there the comment about the "dead zone"), we cannot reset them back to the fog.
    _recalculate_bounds()
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            if not is_in_influence(row, col):
                tile["in_influence"] = false
                tile["is_explored"] = false

    current_era += 1
    # The boundaries of the Region have grown: a part of the formerly foggy hexes now enters the
    # Region, therefore the cache of the fill/boundaries of the rings of the towns has become outdated.
    # We synchronise the current era in CityData — the restriction
    # on the learning of the technologies depends on it (only the current and the previous eras).
    map_renderer.invalidate_town_influence_cache()
    # --- THE NATURAL TRANSITION TO THE NEXT ERA ---
    # The Market is the condition of the transition from the first era. After its construction the game
    # is paused and a dialog with a Yes/No choice is shown.
    # In case of a refusal a small button appears in the HUD, opening the same dialog.
    # No timers, no prohibitions and no reminders: the player can play in the current
    # era as long as he wants.
    CityData.current_era_index = current_era
    CityData.emit_signal("city_updated")
    _calc_offsets()
    map_renderer.queue_redraw()
    if hud:
        hud.show_message(tr("New era! City borders expanded. Influence ring: %d×%d") % [ring_rows, ring_cols], GameData.HUD_MESSAGE_NORMAL)

    # If the Market has already been built, and the era has not been changed (the player refused and left)
    # - we show the button in the HUD again.
func _setup_era_advance_ui():
    era_advance_button = Button.new()
    era_advance_button.text = tr("New era")
    era_advance_button.tooltip_text = tr("Advance requirement met. Click to advance to the next era.")
    era_advance_button.visible = false
    era_advance_button.pressed.connect(_show_era_advance_offer)
    hud.get_node("VBoxContainer").add_child(era_advance_button)

    era_dialog = ConfirmationDialog.new()
    era_dialog.title = tr("New era")
    era_dialog.dialog_text = tr("Congratulations, your city has reached the next level of development!\nDo you want to transition to the next era?")
    era_dialog.ok_button_text = tr("Yes")
    era_dialog.cancel_button_text = tr("No")
    era_dialog.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
    era_dialog.confirmed.connect(_on_era_dialog_confirmed)
    era_dialog.canceled.connect(_on_era_dialog_declined)
    add_child(era_dialog)
    era_dialog.hide()

    # The player remains in the current era: we unpause, we leave the button in the HUD.
    if current_era == 0 and _is_market_built():
        era_advance_button.visible = true

func _is_market_built() -> bool:
    for b in CityData.city_built_buildings:
        if b.get("id", "") == "market":
            return true
    return false

func _on_market_built():
    if current_era == 0:
        _show_era_advance_offer()

func _show_era_advance_offer():
    get_tree().paused = true
    era_dialog.popup_centered()

func _on_era_dialog_confirmed():
    get_tree().paused = false
    era_advance_button.visible = false
    advance_to_next_era()

func _on_era_dialog_declined():
    # The player remains in the current era: we unpause, we leave the button in the HUD.
    get_tree().paused = false
    era_advance_button.visible = (current_era == 0)

# The ghost on the map = the segments of the steps of the active projects that are not built yet.
# It is updated on every event of the project, therefore the built segment disappears
# from the route by itself.
func _refresh_project_ghost() -> void:
    if map_renderer == null:
        return
    map_renderer.set_project_ghost_segments(project_manager.get_pending_ghost_segments())

func _on_territory_expanded(_row: int, _col: int, cost: int):
    # cost is the labour spent on the claiming (see expansion_manager).
    hud.show_message(tr("Territory expanded! (%d work spent)") % cost, GameData.HUD_MESSAGE_NORMAL)
    # The claiming removes the fog from the hexes (in_influence = true) — the cache of the fill of the rings of
    # the towns is rebuilt, otherwise the new territory would remain without the fill.
    # The cache of the plans of the roads is also reset: the bought hex has become known.
    road_manager.bump_map_knowledge()
    map_renderer.invalidate_town_influence_cache()
    map_renderer.queue_redraw()
    # The control panel is redrawn here, and not by a direct subscription to the signal:
    # territory_expanded carries three arguments, and control_panel.refresh() does not
    # accept a single one — on a direct connection Godot broke the call, and the panel
    # after the claiming remained with the old actions and the highlighting.
    control_panel.refresh()
    if city_ui.visible:
        city_ui.refresh()

func is_expansion_mode_active() -> bool:
    return expansion_manager.is_active()
