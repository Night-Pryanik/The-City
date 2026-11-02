@tool
extends "res://scripts/main_map/windows.gd"

# The map of the game: the node of scenes/MainMap.tscn.
#
# The implementation is split by topic over scripts/main_map/; every link extends the previous
# one and this file is the last link — the engine callbacks (_ready, _input, _process) and the
# assembly of the node: the managers, the windows, the signals and the first readouts. The parts
# see each other's fields and methods as their own, therefore the split costs no forwarding.

func _make_tech_popup() -> Control:
    var popup_script = load("res://scripts/tech_popup.gd")
    var popup = Control.new()
    popup.set_script(popup_script)
    return popup

func _ready():
    if Engine.is_editor_hint():
        _initialize_map()
        map_renderer.initialize(tile_data, self)
        highlight_layer.initialize(self)
        progress_bar_layer.initialize(tile_data, self)
        improvement_state_layer.initialize(tile_data, self, map_renderer)
        map_renderer.queue_redraw()
        return

    _load_map_config()

    # A tileset changes the pictures of the whole interface, and the map keeps its own copy
    # of the textures: the icons are reloaded when the table of replacements changes.
    IconRegistry.overrides_changed.connect(_on_icons_changed)

    # The active pause is created before everything else: the execution points of
    # the actions reach it as early as the _ready of the managers, and it owns the
    # flag of the pause of the tree.
    active_pause = ACTIVE_PAUSE_SCRIPT.new()
    active_pause.name = "ActivePause"
    add_child(active_pause)
    active_pause.setup(self)

    # The history of the important messages is created before the managers: they
    # report their first messages as early as their own _ready, and the HUD has to
    # have somewhere to put them by then.
    journal = JOURNAL_SCRIPT.new()
    journal.name = "Journal"
    add_child(journal)
    if SaveManager.is_loaded:
        journal.restore(SaveManager.saved_data.get("journal", []))
    hud.set_journal(journal)

    # The logistics is created before the world is built: the load path restores its
    # cargo right after the roads and the towns are in place, and the production tick
    # needs it on the very first tick.
    delivery_manager = DELIVERY_MANAGER_SCRIPT.new()
    delivery_manager.name = "DeliveryManager"
    add_child(delivery_manager)
    delivery_manager.initialize(self)

    # The trade with the towns needs the towns (the warehouse, the treasury) and the
    # logistics (the road from a town to the city), so it is initialized right after
    # both exist.
    town_trade_manager = TOWN_TRADE_MANAGER_SCRIPT.new()
    town_trade_manager.name = "TownTradeManager"
    add_child(town_trade_manager)
    town_trade_manager.initialize(town_manager, delivery_manager)

    if SaveManager.is_loaded:
        GameData.load_all_data()
        map_renderer.load_icons()
        SaveManager.apply_loaded_data()

        # We restore the state of the world/window from the save BEFORE the building of tile_data.
        _apply_saved_map_state()

        tile_data = []
        road_manager.initialize(city_row, city_col)
        var saved_tiles = SaveManager.saved_data.get("tile_data", [])
        for row in range(map_rows):
            var col_array = []
            for col in range(map_cols):
                # crop_bred — the id of a domesticated animal/plant which is bred
                # on an empty hex (see docs.md, the section "Breeding of animals/plants").
                # For the natural resources tile.resource remains.
                var tile = {"terrain": "plain", "cover": "none", "climate": "", "resource": null, "crop_bred": null, "improvement": null, "decorative": false, "production_fractional_remainder": 0.0, "feed_fractional_remainder": 0.0, "herd_mature": false, "terrain_icon": "", "in_influence": false, "is_explored": false, "river_edges": [], "in_town_influence": false, "has_town": false, "road_built": false, "road_level": 1, "road_staged": false}
                if row < saved_tiles.size() and col < saved_tiles[row].size():
                    var saved = saved_tiles[row][col]
                    if not saved.is_empty():
                        # The forest is a cover (cover) over the terrain.
                        var saved_terrain = saved.get("terrain", "")
                        var saved_cover = saved.get("cover", "none")
                        tile["terrain"] = saved_terrain
                        tile["cover"] = saved_cover
                        tile["climate"] = saved.get("climate", "")
                        tile["resource"] = saved.get("resource")
                        tile["crop_bred"] = saved.get("crop_bred")
                        # The occupancy of the livestock
                        tile["fill_time"] = float(saved.get("fill_time", 0.0))
                        tile["herd_mature"] = bool(saved.get("herd_mature", false))
                        # The fractional remainder of the continuous production of an improvement.
                        # The obsolete production_progress is not used; if it is present
                        # we simply ignore it and start from zero.
                        if saved.has("production_progress"):
                            tile["production_fractional_remainder"] = 0.0
                            tile["feed_fractional_remainder"] = 0.0
                        else:
                            tile["production_fractional_remainder"] = float(saved.get("production_fractional_remainder", 0.0))
                            tile["feed_fractional_remainder"] = float(saved.get("feed_fractional_remainder", 0.0))
                        tile["improvement"] = saved.get("improvement")
                        tile["decorative"] = bool(saved.get("decorative", false))
                        tile["quality"] = saved.get("quality", "")
                        tile["terrain_icon"] = saved.get("terrain_icon", "")
                        tile["in_influence"] = saved.get("in_influence", false)
                        tile["is_explored"] = saved.get("is_explored", false)
                        tile["river_edges"] = saved.get("river_edges", [])
                        # road_built — a road is laid on the hex, built by
                        # the player (the special action "Build a road"). The segments are not
                        # written to the save, therefore only the fact is saved:
                        # by it the network is recalculated on loading (see
                        # road_manager.rebuild_player_roads).
                        tile["road_built"] = bool(saved.get("road_built", false))
                        # road_level — the road level to this hex (see
                        # SaveManager._serialize_tile_data).
                        tile["road_level"] = int(saved.get("road_level", 1))
                        # road_staged — the road to an improvement on this hex is going
                        # by a phased project, its state is stored by the flags
                        # road_built/road_level and the queue of the projects. Such a hex
                        # the recalculation rebuild_roads_from_existing must skip,
                        # otherwise it would finish the unpaid (or the cancelled) road
                        # for free.
                        tile["road_staged"] = bool(saved.get("road_staged", false))
                col_array.append(tile)
            tile_data.append(col_array)

        # We guarantee that the city is on a permitted terrain on loading a save
        _ensure_city_valid_terrain()
        _mark_city_hex()

        # We restore the builds of the improvements, the buildings and the claiming of the territory
        build_manager.restore_builds(SaveManager.saved_data.get("active_builds", {}))
        build_manager.restore_building_builds(SaveManager.saved_data.get("active_building_builds", {}))
        build_manager.restore_expansion_builds(SaveManager.saved_data.get("active_expansion_builds", {}))

        # We restore the unfinished phased projects (the road by the hexes).
        # Their segments are not written to the save: the already laid part is restored
        # by the flags road_built, set on each connected hex
        # of the step (see _on_project_step_completed), and the queue of the remaining
        # segments continues to be completed.
        project_manager.restore_projects(SaveManager.saved_data.get("active_projects", {}))

        # We restore the assignments of the workers and the citizens
        worker_manager.load_assignments(SaveManager.saved_data.get("worker_assignments", []))
        # The timers of the occupational consumption — after the assignments, so that
        # the interval for each hex is recalculated by the current profession.
        worker_manager.load_consumption_timers(SaveManager.saved_data.get("profession_consumption_timers", []))
        # The timers of the consumption of the city ("all", all the citizens of the city) — the interval
        # is recalculated from the data on loading, we store only elapsed.
        worker_manager.load_city_consumption_timers(SaveManager.saved_data.get("city_consumption_timers", []))
        townsfolk_manager.load_assignments(SaveManager.saved_data.get("townsfolk_assignments", []))
        # The timers of the occupational consumption of the CITY BUILDINGS — after
        # the assignments of the citizens: the profession is determined by the building (data/buildings.json),
        # the fractional remainders are stored in the save, the intervals are recalculated from the data.
        worker_manager.load_building_consumption_timers(SaveManager.saved_data.get("building_profession_consumption_timers", []))

        # For the already researched technologies we guarantee the spawn of the resources opened by them
        CityData.ensure_tech_resources_spawned()

        # We recalculate the free citizens by the actually restored assignments
        var total_assigned = worker_manager.get_assigned_count() + townsfolk_manager.get_assigned_count()
        CityData.idle_population = max(0, CityData.total_population - total_assigned)

        # --- THE CHECK: if there are assignments of the citizens, but they do not coincide with the number of the buildings, we fix it ---
        var current_buildings_count = CityData.city_built_buildings.size()
        var invalid_keys = []
        for key in townsfolk_manager.assigned_buildings.keys():
            var idx = int(key)
            if idx >= current_buildings_count:
                invalid_keys.append(key)
        for key in invalid_keys:
            townsfolk_manager.assigned_buildings.erase(key)

        if invalid_keys.size() > 0:
            total_assigned = worker_manager.get_assigned_count() + townsfolk_manager.get_assigned_count()
            CityData.idle_population = max(0, CityData.total_population - total_assigned)

        _update_population_hud()

        road_manager.rebuild_roads_from_existing(tile_data, map_rows, map_cols,
                Callable(self, "_skip_improvement_road_restore"))

        # We restore the rivers from the save and mark river_edges in the hexes
        river_manager.load_rivers(SaveManager.saved_data.get("rivers", []))
        river_manager.mark_river_edges(tile_data, map_rows, map_cols, HEX_RADIUS)

        # We collect the hexes of a unique terrain (for example, a soda lake) after the loading.
        unique_terrain_hexes = []
        for row in range(map_rows):
            for col in range(map_cols):
                var terrain_id = tile_data[row][col].get("terrain", "plain")
                var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
                if t_data.get("unique", false):
                    unique_terrain_hexes.append({"row": row, "col": col})

        # We restore the towns from the save and mirror them into town_hexes for the renderer.
        # town_manager.load_towns fills the master list towns, and the derived
        # town_hexes — inside the manager; plus we manually set tile.has_town
        town_manager.load_towns(SaveManager.saved_data.get("towns", []))
        towns = town_manager.towns
        town_hexes = []
        for h in town_manager.town_hexes:
            tile_data[h.row][h.col]["has_town"] = true
            town_hexes.append({"row": h.row, "col": h.col})

        # The personal rings of the towns are rebuilt by the radius from the record
        # (compute_all_town_influences). It also sets the flags
        # in_town_influence on the tiles and collects the flat mirror
        # town_influence_hexes for the renderer. The ring is built WHOLLY (without
        # a clip by the current Region); what of the ring
        # is visible to the player is decided by the renderer (the fog of war + the era).
        #
        # BEFORE the recalculation we give the manager the starting area of the player: its
        # boundaries are restored from the save, and on the generation it is set in
        # generate_towns. The territory of the towns is cut out of it — over the whole map
        # (including the hexes under the fog) the hexes of the player remain his.
        town_manager.set_player_start_area(start_region_start_row, start_region_end_row,
                start_region_start_col, start_region_end_col)
        town_manager.compute_all_town_influences(tile_data, map_rows, map_cols)
        # We fill the rings of the towns with the decorative improvements and also for the old
        # saves, where these marks were still absent.
        town_manager._place_decorative_town_improvements(tile_data, map_rows, map_cols)
        # We build the roads of the towns ONLY HERE: the improvements in the rings already stand
        # (the call above), and the towns themselves are already loaded from the save. Up to this point
        # there were no networks of the towns on the map.
        _rebuild_town_roads()
        town_influence_hexes = []
        for h in town_manager.town_influence_hexes:
            town_influence_hexes.append({"row": h.row, "col": h.col})

        # The cargo that was on the road and in the queues at the moment of the save.
        # It is restored after the roads and the towns: a route is recomputed from the
        # road network, and the towns take part in the route of a town source.
        delivery_manager.deserialize(SaveManager.saved_data.get("delivery", {}))

        # The standing contracts with the towns. They are restored after the towns:
        # a contract finds its town by the id and reads the position and the name of
        # the town from the restored record.
        town_trade_manager.deserialize(SaveManager.saved_data.get("town_contracts", []))

        # The ledger of the one-time purchases still on the road. It is restored AFTER the
        # contracts on purpose: town_trade_manager.deserialize resets the whole state of the
        # manager, this ledger included. The queue of the route is already restored by this
        # point (delivery_manager.deserialize above), so the ledger lands on the queue it
        # describes.
        town_trade_manager.deserialize_deliveries(
                SaveManager.saved_data.get("town_deliveries", {}))

        SaveManager.is_loaded = false
        SaveManager.saved_data.clear()
        map_renderer.initialize(tile_data, self)
        highlight_layer.initialize(self)
        progress_bar_layer.initialize(tile_data, self)
        improvement_state_layer.initialize(tile_data, self, map_renderer)
    else:
        randomize()
        # The world is built in stages with a frame between them (see _initialize_map):
        # the first yield gives the loading screen of the new game a chance to be drawn
        # before the heavy work starts. Without the screen (a test, the editor) the
        # generation runs in one go, as it always did.
        _loading_overlay = get_tree().root.get_node_or_null("LoadingOverlay")
        world_generating = true
        if _loading_overlay != null:
            _update_loading_progress(0.0, tr("Preparing world..."))
            await get_tree().process_frame
        await _initialize_map()
        road_manager.initialize(city_row, city_col)
        # The road network of the city of the player is ready — it is possible to build the networks of the towns
        # (the towns and their improvements are already placed in _initialize_map).
        _rebuild_town_roads()
        map_renderer.initialize(tile_data, self)
        highlight_layer.initialize(self)
        progress_bar_layer.initialize(tile_data, self)
        improvement_state_layer.initialize(tile_data, self, map_renderer)

    _load_settings()

    tooltip_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    tooltip_text_label.custom_minimum_size = Vector2(300, 0)
    tooltip_text_label.bbcode_enabled = true

    add_child(settings_menu)
    settings_menu.hide()

    # The initialization of InputHandler
    input_handler.initialize(self)

    map_tooltip = MapTooltip.new(tooltip_text_label, tooltip_products_container, map_renderer, worker_manager)

    # The initialization of the panel of the hex (the bottom panel).
    control_panel.initialize(self)

    input_handler.set_tooltip_delay(tooltip_delay)
    input_handler.set_extended_tooltip_delay(extended_tooltip_delay)
    input_handler.set_scroll_speed(edge_scroll_speed)
    city_ui.set_building_detail_delay(building_detail_delay)
    hud.set_message_duration(hud_message_duration)
    _setup_clock()
    top_right_box.minimum_size_changed.connect(_fit_top_right_panel)
    _apply_fps_visibility()
    CityData.set_resource_display_interval(resource_display_interval)
    # The planned consumption on the tab "Resources" (the tooltip and the dynamics "≈") is counted
    # by the workers worker_manager — we pass the reference into the UI of the city.
    city_ui.set_worker_manager(worker_manager)
    # The external column of the tab "Trade" reads the towns discovered by the player and their
    # distance from the city from the map (see get_trade_partners).
    city_ui.set_map(self)

    # The initialization of DebugManager
    debug_manager.initialize(self)

    # The UI-helpers for the HUD tooltips (the breakdown of the treasury, and potentially the future
    # tooltips on the elements of the HUD). Its own CanvasLayer and Control-host, so that
    # the tooltips lie over the HUD and the map; the detailed list of the panels is inside
    # ui_helpers.setup() — see the corresponding script. We pass null into
    # message_label: the HUD of the map shows its own message through hud_message.gd,
    # there is no need to duplicate the channel.
    _setup_hud_tooltip_layer()

    _calc_offsets()
    map_renderer.queue_redraw()

    _update_population_hud()
    _update_treasury_hud()

    city_ui.closed.connect(_on_city_ui_close)
    # The "Trade partners" column asked to show a town: the city window is closed and the map is
    # centered on the town (see _on_town_focus_requested).
    city_ui.town_focus_requested.connect(_on_town_focus_requested)
    town_ui.closed.connect(_on_town_ui_close)
    # The window reads the route to the city from the map to compare the entered
    # amount with the throughput of the route (see town_ui._route_capacity).
    town_ui.set_map(self)
    town_ui.trade_order_submitted.connect(_on_town_trade_order)
    # The window asked to close the standing contract it is editing (see
    # town_ui._on_close_contract_pressed): the mechanics live in town_trade_manager, the
    # answer is reported by the HUD.
    town_ui.contract_close_requested.connect(_on_town_contract_close_requested)
    town_ui.delivery_cancel_requested.connect(_on_town_delivery_cancel_requested)
    # The list of the contracts changed (signed, updated or torn): the trade panel of the
    # window follows the contract of the good it shows, so an order that has just become a
    # standing contract can be closed or corrected without reopening the panel
    # (see town_ui.on_contracts_changed).
    town_trade_manager.contracts_changed.connect(town_ui.on_contracts_changed)
    # A standing contract that could not be paid or fulfilled is torn automatically
    # (see town_trade_manager.tick_contracts): the player learns about it from the HUD.
    town_trade_manager.notice.connect(_on_town_trade_notice)
    town_manager.town_treasury_changed.connect(town_ui.on_town_treasury_changed)
    town_manager.town_storage_changed.connect(town_ui.on_town_storage_changed)
    city_button.pressed.connect(_on_city_button_pressed)
    expansion_button.pressed.connect(_on_expansion_button_pressed)
    city_ui.build_requested.connect(CityData.request_build)
    CityData.research_error.connect(_on_research_error)
    CityData.research_error.connect(hud.show_message)
    CityData.population_changed.connect(_on_population_changed)
    CityData.famine_death.connect(_on_famine_death)
    # The treasury in the HUD is updated via the tick path (city_updated) with the check of
    # the era of the display of the resources — synchronously with the other resources. The direct
    # signal treasury_changed is not needed here: the income of the internal market changes
    # the treasury on every tick, and without throttling the HUD label would flicker every tick.
    CityData.city_updated.connect(_on_city_data_updated)
    city_ui.research_requested.connect(CityData.start_research)
    CityData.research_completed.connect(_on_research_completed)
    expansion_manager.chunk_hovered.connect(_on_chunk_hovered)
    worker_manager.assignment_changed.connect(_on_assignment_changed)
    townsfolk_manager.assignment_changed.connect(_on_townsfolk_assignment_changed)
    # The control panel must react to the external changes: the assignment
    # of the workers, the completion/cancellation of the builds, the update of the city, the learning of the technologies,
    # the expansion of the territory. Otherwise it would show the outdated information.
    worker_manager.assignment_changed.connect(control_panel.refresh)
    build_manager.build_completed.connect(_on_control_panel_build_changed)
    build_manager.build_cancelled.connect(_on_control_panel_build_changed)
    build_manager.build_paused.connect(_on_control_panel_build_changed)
    # The tick update (and not refresh): the info column with the resources and the preview
    # are updated with the display interval (see control_panel.on_city_updated).
    CityData.city_updated.connect(control_panel.on_city_updated)
    CityData.research_completed.connect(control_panel.refresh)

    # The change of the language on the fly: the text set in the scenes is translated by Godot itself, and
    # everything assembled in the code (the lists of the tabs, the panel of the hex, the HUD) has to be
    # rebuilt. By this moment the data has already been re-read by the language manager.
    LocalizationManager.locale_changed.connect(_on_locale_changed)

    tech_popup = _make_tech_popup()
    add_child(tech_popup)
    tech_popup.hide()
    if tech_popup.has_signal("go_to_technologies"):
        tech_popup.go_to_technologies.connect(_on_tech_popup_go_to_techs)

    if pause_menu:
        if not pause_menu.save_pressed.is_connected(_on_pause_save):
            pause_menu.save_pressed.connect(_on_pause_save)
        if not pause_menu.load_pressed.is_connected(_on_pause_load):
            pause_menu.load_pressed.connect(_on_pause_load)
        if not pause_menu.new_game_pressed.is_connected(_on_pause_new_game):
            pause_menu.new_game_pressed.connect(_on_pause_new_game)
        if not pause_menu.visibility_changed.is_connected(_on_pause_menu_visibility_changed):
            pause_menu.visibility_changed.connect(_on_pause_menu_visibility_changed)

    build_manager.build_message.connect(hud.show_message)
    build_manager.build_completed.connect(_on_build_completed)
    build_manager.build_building_completed.connect(_on_building_build_completed)
    build_manager.building_upgrade_completed.connect(_on_building_upgrade_completed)
    build_manager.expansion_build_completed.connect(expansion_manager.on_expansion_build_completed)
    # The phased projects (the road by the hexes): the distribution of the labour is done by build_manager itself,
    # and the effect of each completed segment is applied by main_map.
    build_manager.project_manager = project_manager
    # The managers that start the actions must be able to reach the queue of the
    # active pause. CityData reaches it through the main_map itself.
    build_manager.active_pause = active_pause
    expansion_manager.active_pause = active_pause
    project_manager.step_completed.connect(_on_project_step_completed)
    project_manager.project_completed.connect(_on_project_completed)
    project_manager.project_cancelled.connect(_on_project_cancelled)
    city_button.gui_input.connect(_on_city_button_gui_input)

    # The signals from ExpansionManager
    expansion_manager.expansion_mode_changed.connect(_on_expansion_mode_changed)
    expansion_manager.territory_expanded.connect(_on_territory_expanded)

    menu_button.pressed.connect(_on_menu_button_pressed)

    pause_button.pressed.connect(toggle_active_pause)
    active_pause.active_changed.connect(_on_active_pause_changed)
    _refresh_pause_button()

    _setup_research_hud()
    _setup_era_advance_ui()

    # The journal window is added last, so that it is drawn over the map and over the
    # control panel: it is the topmost window of the game.
    add_child(journal_ui)
    journal_ui.setup(journal)
    journal_ui.hide()
    journal_ui.closed.connect(_on_journal_closed)
    journal_button.pressed.connect(open_journal)

    # The window of the saves is added after the pause menu and carries a higher
    # canvas layer, so it is drawn over the menu that opens it.
    add_child(save_load_window)
    save_load_window.hide()
    save_load_window.save_requested.connect(_on_save_requested)
    save_load_window.load_requested.connect(_on_load_requested)

    _update_loading_progress(1.0)
    _remove_loading_overlay()

func _input(event):
    # Only the debug menu is handled here. The input of the MAP belongs to
    # InputHandler, which is its own entry point: main_map stops processing while
    # the active pause is on, and the map must keep receiving the input then.
    # Both nodes are in the same _input pass; this one is the parent, so it goes
    # first — and set_input_as_handled() above keeps the handled keys away from
    # InputHandler.
    #
    # The debug menu: opening/closing on F9
    if event is InputEventKey and event.pressed and event.keycode == KEY_F9:
        debug_manager.toggle()
        get_viewport().set_input_as_handled()
        return

    # ESC closes the debug menu, if it is open
    if debug_manager.is_open:
        if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
            debug_manager.close()
            get_viewport().set_input_as_handled()
            return
        # The hotkeys of the items of the debug menu: the digit 1..9, 0 calls
        # the corresponding item of the main menu (see debug_manager.trigger_hotkey).
        if event is InputEventKey and event.pressed:
            var num = _debug_hotkey_number(event.keycode)
            if num >= 0:
                debug_manager.trigger_hotkey(num)
                get_viewport().set_input_as_handled()
                return

# Returns the digit for the debug hotkey by the key code, or -1, if the key
# is not a digit (the main row + the keyboard digit 0).
func _debug_hotkey_number(keycode: Key) -> int:
    match keycode:
        KEY_1: return 1
        KEY_2: return 2
        KEY_3: return 3
        KEY_4: return 4
        KEY_5: return 5
        KEY_6: return 6
        KEY_7: return 7
        KEY_8: return 8
        KEY_9: return 9
        KEY_0: return 0
    return -1

func _process(delta):
    if Engine.is_editor_hint():
        return

    # The world is still being generated: the stages run with a frame between them,
    # and those frames must not simulate, select hexes or move the map.
    if world_generating:
        return

    # We block the buttons of the HUD while the game is paused or the town window is
    # open: the player must see the treasury, but must not accidentally leave the town
    # interface by pressing a HUD button.
    var is_paused: bool = get_tree().paused
    var hud_blocked: bool = is_paused or town_ui.visible
    if research_button:
        research_button.disabled = hud_blocked
    if city_button:
        city_button.disabled = hud_blocked
    if expansion_button:
        expansion_button.disabled = hud_blocked
    if journal_button:
        journal_button.disabled = hud_blocked

    # The science accumulates every frame, and is not bound to the tick of the simulation.
    # Without this the progress bar of the research jumped by jerks.
    if not is_paused:
        CityData.tick_research_science_continuous(delta)
        # The occupancy of the pastures — the same thing: it accumulates every frame, so that
        # the progress bar of the occupancy moves smoothly, and not by a jump once per tick.
        _tick_pasture_fill(delta)

    # We advance the "era" of the display of the resources: the places where the resources are shown
    # (the tab "Resources", the top bar, the resource tooltips) are updated with
    # the interval from the settings, and not on every tick. On the pause of the tree _process does
    # not go — the interval is counted in the game time (see CityData).
    CityData.tick_resource_display(delta)

    # The tooltip of the breakdown of the treasury by the sources of income/expense: polling + the sticking
    # (the logic repeats city_ui.gd — there the same thing for the tooltip over
    # TopFoodLabel; a single rhythm, a single delay building_detail_delay).
    var mouse_pos_now: Vector2 = get_viewport().get_mouse_position()
    var hovered_treasury := _is_treasury_hovered(mouse_pos_now)
    var hovered_treasury_label := _is_treasury_label_hovered(mouse_pos_now)
    if hovered_treasury:
        _treasury_hover_leave_timer = 0.0
        if hovered_treasury_label and not _treasury_locked:
            _treasury_hover_timer += delta
            if _treasury_hover_timer >= building_detail_delay:
                _treasury_locked = _show_treasury_tooltip(mouse_pos_now)
    else:
        _treasury_hover_timer = 0.0
        # The cursor has left the label and the tooltip: we hold the "stuck" panel for
        # the grace window (the transition of the cursor onto the tooltip itself must not blink), then
        # we remove the sticking and hide it. NOT return — below is the tick of the simulation.
        _treasury_hover_leave_timer += delta
        if not _treasury_locked or _treasury_hover_leave_timer >= MAP_TOOLTIP_LEAVE_GRACE:
            _treasury_hover_leave_timer = 0.0
            _treasury_locked = false
            _map_ui_helpers.hide_treasury_tooltip()

    # The tick of the simulation of the towns: every discovered town adds its per-tick
    # rate to its warehouse. It runs on its OWN clock, several times slower than the
    # one of the city (town_tick_ticks × CityData.SIMULATION_TICK), therefore the
    # accumulator lives here, outside the block of the city tick below, and not inside
    # it — the town would otherwise only tick while the city happens to tick.
    var town_tick := TownManager.get_town_tick_seconds()
    town_timer += delta
    if town_timer >= town_tick:
        town_timer -= town_tick
        town_manager.tick_towns(tile_data)
        # The open window shows the stock of the sale column. It is refreshed HERE
        # and not from town_storage_changed, because the tick writes units off every
        # town on the map at once, and only one of them can be on screen.
        if town_ui.visible and town_ui.has_town:
            town_ui.refresh_storage()

    # The arrivals of the logistics advance on every frame, not on the simulation tick:
    # they are a game-time countdown, so the transit delay must not be rounded to whole
    # seconds. They go BEFORE the tick below, so that the goods shipped by the tick are
    # not advanced on the very frame they leave (the tick ships AFTER this call). The
    # shipping itself runs once per tick, inside the block below. When the game is
    # paused, _process is not called at all and the cargo simply waits.
    if delivery_manager != null:
        delivery_manager.advance(delta)

    _simulation_tick(delta)

    _update_research_progress()
    # We redraw the layer of the progress bars ONLY when there is something to show:
    # a research is going, there are active builds (including the steps of the phased
    # projects — they are counted by has_active_builds) or the scouting is going. Otherwise
    # the layer is light and its _draw() draws nothing — there is no reason to call
    # queue_redraw() every frame. When the construction/research/scouting
    # has finished/started, the corresponding handlers call
    # _redraw_progress_layer() (see below), so that the layer is guaranteed to be
    # updated and does not remain hanging at 100% or showing the outdated bars.
    if CityData.current_research_tech_id != "" \
            or build_manager.has_active_builds() \
            or is_scouting \
            or _has_growing_pastures:
        progress_bar_layer.queue_redraw()

    input_handler.handle_process(delta)

    if is_scouting:
        scouting_timer += delta
        if scouting_timer >= _get_scouting_time(scouting_chunk.size()):
            _complete_scouting()
