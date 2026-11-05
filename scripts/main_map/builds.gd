@tool
extends "res://scripts/main_map/production.gd"

# This link — the builds: the phased projects of the road and of the improvement, what happens
# when a build, a step of a project or a building of the city is completed, and the cancellation
# dialogs of them.

func _on_build_completed(row: int, col: int, imp_id: String, target_res_id = null):
    var tile = tile_data[row][col]

    if GameData.special_actions.has(imp_id):
        var sa = GameData.special_actions[imp_id]
        var action_type = sa.get("action_type", "terrain")
        # A special action (the felling of the forest, the gathering of the wild plants, the demolition of the improvements and so on).
        # We free the worker, if it has been assigned.
        if worker_manager.has_worker(row, col):
            worker_manager.remove_worker(row, col)

        if action_type == "cover":
            # The felling of the forest: only the cover changes, terrain and resource stay.
            var result_cover = sa.get("result_cover", "none")
            tile.cover = result_cover
        elif action_type == "forage":
            # The gathering of a one-off resource (the wild plants, the metal nuggets and so on):
            # we remove the resource from the hex and add the harvest to the storage.
            # The quality of the gathered harvest = the quality of the resource on the hex.
            # The output of the product is taken from the produces field of the RESOURCE (a number or
            # [min, max]) — the parsing/validation is done by RangeUtils.roll_value.
            # The safety-guard: only the one-off resources can be gathered
            # (improved_by == null). If the action somehow got onto
            # an ordinary resource — we give nothing (the resource remains in place).
            var harvest_res_id: String = str(tile.get("resource", ""))
            var harvest_data: Dictionary = {}
            if harvest_res_id != "" and GameData.raw_resources.has(harvest_res_id):
                harvest_data = GameData.raw_resources[harvest_res_id]
            if harvest_res_id != "" and harvest_data.get("improved_by", null) == null:
                var forage_quality = tile.get("quality", "common")
                var res_produces: Dictionary = harvest_data.get("produces", {})
                for prod_id in res_produces:
                    var amount = RangeUtils.roll_value(res_produces[prod_id],
                            tr("produces goods '%s' from resource '%s'") % [prod_id, harvest_res_id], 0)
                    if amount <= 0:
                        continue
                    CityData.add_to_storage(prod_id, amount, forage_quality)
                    hud.show_message(tr("Collected %d %s!") % [amount, GameData.get_product_name(prod_id)], GameData.HUD_MESSAGE_NORMAL)
                # The resource disappears from the map after the gathering.
                tile.resource = null
        elif action_type == "demolish":
            # The demolition of an improvement: we remove the improvement. The natural tile.resource
            # remains (if it was), and tile.crop_bred is reset —
            # the breeding lives exactly as long as the improvement costs.
            # Otherwise after the demolition the production cycle would start to "produce" a resource,
            # for which there is no improvement any more.
            tile.improvement = null
            tile.crop_bred = null
            # The herd disappears on the demolition — the accumulated occupancy is reset.
            tile["fill_time"] = 0.0
            tile["herd_mature"] = false
            # The fractional remainder of the production cycle of the demolished improvement — as well.
            tile["production_fractional_remainder"] = 0.0
            tile["feed_fractional_remainder"] = 0.0
        elif action_type == "road":
            # The road is a phased project (project_manager), and not an ordinary build
            # on this hex: its segments are added to the network one by one, until
            # project_manager brings the queue to the end. It cannot get here — the start
            # of the road is intercepted in
            # build_manager.start_build and goes into start_road_project.
            # The branch is left as "do nothing": if the road somehow
            # has got to an ordinary build, the completion
            # simply does not touch the map, and does not fix whatever it is.
            build_manager.remove_build(row, col)
            return
        else:
            # The terrain action (for example, the drainage): we reset the resources and
            # the improvement, clear the cover and crop_bred, so that the hex becomes
            # a clean plain (without the marsh cover).
            tile.resource = null
            tile.improvement = null
            tile.crop_bred = null
            tile.cover = "none"
            tile["fill_time"] = 0.0
            tile["herd_mature"] = false
            # The fractional remainder of the production cycle of the removed improvement — as well.
            tile["production_fractional_remainder"] = 0.0
            tile["feed_fractional_remainder"] = 0.0

        # We change the terrain type only if result_terrain is set and is not equal to "dont_change".
        var result_terrain = str(sa.get("result_terrain", ""))
        if result_terrain != "" and result_terrain != "dont_change":
            # The result names a terrain or a relief family. A family is resolved through the
            # climate zone of the hex, so a drained swamp becomes a boreal plain in the north and a
            # tropical plain at the equator.
            var variant := GameData.zone_terrain(str(tile.get("climate", "")), result_terrain)
            tile.terrain = variant if variant != "" else result_terrain
            _assign_terrain_icon(row, col)

        build_manager.remove_build(row, col)
        map_renderer.queue_redraw()
        _redraw_progress_layer()
        return

    # The improvement is the only thing that has remained after the branch of the special actions. The
    # construction itself is applied by _apply_improvement: the same code is needed by the last step of
    # the project "road → improvement", where the record of the build in build_manager does not
    # exist at all (the improvement lies in the queue of the project, and not in active_builds).
    build_manager.remove_build(row, col)
    _apply_improvement(row, col, imp_id, target_res_id)

# Places the improvement on the hex (row, col): the construction itself, the breeding, the worker and
# the redrawing. It is moved out of _on_build_completed, because the same is done by
# the step of a phased project (see _on_project_step_completed) — the rule "the improvement
# has appeared" must not exist in two forms.
#
# We do NOT build the road here: by this moment its segments have already been passed by the queue (or
# the road is not needed at all). Building it here would mean returning the old scheme
# "the road as a whole and for free".
func _apply_improvement(row: int, col: int, imp_id: String, target_res_id = null) -> void:
    var tile = tile_data[row][col]
    tile.improvement = imp_id
    tile["fill_time"] = 0.0
    tile["herd_mature"] = false
    # The production cycle of the new improvement starts from zero.
    tile["production_fractional_remainder"] = 0.0
    tile["feed_fractional_remainder"] = 0.0
    if target_res_id != null:
        # Two scenarios:
        # 1) There was ALREADY a natural resource on the hex (tile.resource != null) — we
        #    place the improvement in order to extract it. tile.resource is preserved,
        #    crop_bred remains null. The quality is the current quality of the resource.
        # 2) The hex was empty (tile.resource == null) — this is the breeding. We write
        #    the id of the bred animal/plant into tile.crop_bred, and tile.resource
        #    is NOT touched (it remains null). The quality is inherited from the already
        #    domesticated instance of this same resource, otherwise we throw a roll.
        var was_existing_resource = tile.resource != null
        if was_existing_resource:
            tile.resource = target_res_id
            # The quality of the resource is determined like this:
            # - If there was ALREADY a resource on the hex (an improvement of the existing one) — we preserve
            #   its quality. Otherwise any construction of a farm/mine would reset
            #   quality to "common", because there is no quality field in the JSON of the resources.
            var existing_q = tile.get("quality", "")
            if existing_q == "" or existing_q == null:
                tile["quality"] = GameData.roll_quality()
        else:
            # The breeding on an empty hex: the id of the resource lives in crop_bred.
            tile.crop_bred = target_res_id
            # - If this is the breeding of a NEW animal/plant (the hex was empty) —
            #   we look on the map for the already domesticated instance of this resource and
            #   inherit its quality ("exceptional produces exceptional").
            #   If there is none yet — we generate it at random.
            var inherited_quality = _find_domesticated_quality(target_res_id)
            if inherited_quality != "" and inherited_quality != null:
                tile["quality"] = inherited_quality
            else:
                tile["quality"] = GameData.roll_quality()
        if CityData:
            # The first domestication of a species grants the seed herd: the heads to start
            # the breeding of a NEW herd on an empty hex. A known species (the breeding
            # itself, an earlier find) grants nothing — the breeding of an unknown species
            # is impossible, so the grant fires exactly once per species.
            if CityData.register_domesticated_resource(target_res_id):
                var live_pid := GameData.live_product_of(target_res_id)
                if live_pid != "":
                    CityData.add_to_storage(live_pid, CityData.livestock_breeding_cost())
                    hud.show_message(tr("%s is domesticated — %d heads of livestock are in the storage")
                            % [GameData.get_product_name(live_pid), CityData.livestock_breeding_cost()],
                            GameData.HUD_MESSAGE_NORMAL)
    if not worker_manager.assign_worker(row, col):
        pass
    map_renderer.queue_redraw()
    _redraw_progress_layer()

# === THE PHASED CONSTRUCTION OF THE ROAD (the special action build_road) ===
#
# The road is a project of separate segments, and not one build over the whole route: the player
# confirms the route, it entirely enters the queue (project_manager) and is completed one hex at
# a time. The "ghost" of the route remains on the map until the end, and the built segments
# disappear from it and become a real road. Each segment is paid by its own step, and an unpaid
# segment simply does not start.

# The special action "Build a road" on the hex (row, col). It is called from
# build_manager.start_build, therefore it returns a bool in its sense.
#
# Here there is only the parsing of the refusal for the player (there is no route, the level is not scouted,
# the limit of the builds is exhausted). The construction itself lives in the common function
# _start_road_project_steps, which is also used by the road to an improvement: the rules of
# them are the same by construction, and not by agreement.
func start_road_project(row: int, col: int, road_level: int) -> bool:
    # The route may disappear between the click of the button and the confirmation (for example,
    # the player managed to build another road) — then we simply report the reason.
    # The steps and the price are taken from get_road_cost_breakdown — the same source as
    # the preview, therefore the start cannot take a different price than what was shown.
    var breakdown: Dictionary = get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        hud.show_message(tr("Failed to build the road: %s") % breakdown.get("reason", tr("no path")), GameData.HUD_MESSAGE_IMPORTANT)
        return false
    var plan := get_road_plan(row, col)
    var is_town := bool(plan.get("is_town", false))

    # We check the level HERE, and not in the panel: the panel is a display, and
    # the only place where it is decided whether anything can be built at all.
    # The rule itself "the level is unlocked by its own technology" lives in the data and in
    # GameData.is_road_level_unlocked, here we only refuse to build
    # an unscouted level.
    if not GameData.is_road_level_unlocked(road_level):
        hud.show_message(tr("Road level %d requires a technology") % road_level, GameData.HUD_MESSAGE_IMPORTANT)
        return false

    # The common limit of the simultaneous builds is equal to the number of the citizens. The road takes
    # one slot, and not one per hex: one segment is built at the same time.
    if not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        hud.show_message(tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)")
                % CityData.total_population, GameData.HUD_MESSAGE_IMPORTANT)
        return false

    var title := tr("Road")
    if is_town:
        var town = find_town_at(row, col)
        if town != null:
            title = tr("Road to town \"%s\"") % str(town.get("name", ""))

    if active_pause != null and active_pause.intercept({
            "key": str(row) + "," + str(col),
            "label": title,
            "row": row,
            "col": col,
            "bar_color": UI_THEME.color("info"),
            "bar_offset": 16,
            "execute": func(): start_road_project(row, col, road_level),
    }):
        return true

    return _start_road_project_steps(row, col, breakdown.get("steps", []),
            int(breakdown.get("cost", 0)), is_town, title, {})

# THE CHAIN ROAD-TO-IMPROVEMENT on the hex (row, col).
#
# It is started from build_manager.start_build, when the improvement is due a road.
# This is ONE phased project and ONE slot: first go the segments of the road, the last
# step — the construction of the improvement itself. The sequence here is not a decoration:
# the materials to the distant hex are carried by the road, and building the improvement while the road
# is not there yet would mean carrying its worker and the construction materials off the roads.
#
# The level of the road the player has chosen in the preview of the construction of the improvement; imp_id and
# target_res_id are needed by the last step (target_res_id — the breeding: the id of the animal
# or the plant which has to be planted on the hex).
#
# outpost_fee is the one-time coin fee of an improvement built outside the Region (0 for
# an ordinary improvement). It is paid once at the start of the project, not per step.
#
# A refusal here means the improvement is built in an ordinary way: if the road is not
# needed (the hex is already connected, the improvement with the flag no_road, there is no
# land route), the calling code will not pass the control here, and the improvement will stand as an ordinary
# build. The errors of the level and the limit, on the contrary, are shown by the same rows as
# the other builds.
func start_improvement_road_project(row: int, col: int, imp_id: String, imp_name: String,
        target_res_id, road_level: int, outpost_fee: int = 0) -> bool:
    if project_manager == null or road_level <= 0:
        return false
    if row < 0 or row >= tile_data.size() or col < 0 or col >= tile_data[row].size():
        return false
    if not GameData.is_road_level_unlocked(road_level):
        hud.show_message(tr("Road level %d requires a technology") % road_level, GameData.HUD_MESSAGE_IMPORTANT)
        return false
    # The road to the hex is already being built: a second project would mean a second payment for
    # one and the same route.
    if project_manager.has_project_at(row, col):
        return false
    var breakdown: Dictionary = get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        return false
    var steps: Array = breakdown.get("steps", [])
    if steps.is_empty():
        return false
    if not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        hud.show_message(tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)")
                % CityData.total_population, GameData.HUD_MESSAGE_IMPORTANT)
        return false

    # The last step of the chain — the construction of the improvement itself. It has no price of its own:
    # it is exactly MapHelpers.get_improvement_work_cost, the same calculation that the
    # preview takes. The ghost segments of the step are absent: the road by this moment already stands,
    # and drawing anything in its place would be a lie.
    var improvement_cost := int(MapHelpers.get_improvement_work_cost(
            imp_id, row, col, tile_data, city_row, city_col).get("cost", 0))
    steps.append({
        "label": tr("Build %s") % imp_name,
        "work_cost": improvement_cost,
        "hex": {"row": row, "col": col},
        "ghost": {},
        "data": {
            # step_type distinguishes the improvement step in the handler and in the colour of
            # the progress bar: yellow was the colour of the build of an improvement, blue —
            # of a segment of the road.
            "step_type": "improvement",
            "improvement": imp_id,
            "imp_name": imp_name,
            "target_res_id": target_res_id,
        },
    })
    var total_cost := int(breakdown.get("cost", 0)) + improvement_cost
    var title := tr("Road")
    if not imp_name.is_empty():
        title = tr("Road to %s") % imp_name

    if active_pause != null and active_pause.intercept({
            "key": str(row) + "," + str(col),
            "label": title,
            "row": row,
            "col": col,
            "bar_color": UI_THEME.color("info"),
            "bar_offset": 16,
            "execute": func(): start_improvement_road_project(row, col, imp_id, imp_name,
                    target_res_id, road_level, outpost_fee),
    }):
        return true

    # The breeding as the last step of the project: the seed herd is written off here,
    # because the improvement will be applied from the queue, and not from an ordinary
    # build. The check itself was passed in build_manager.start_build; the write-off can
    # fail only if the heads went somewhere during the pause. The heads travel in the
    # project meta — the cancellation of the project returns them.
    var livestock_meta := {}
    if target_res_id != null:
        var target_tile = tile_data[row][col]
        if target_tile != null and target_tile.get("resource", null) == null \
                and GameData.live_product_of(str(target_res_id)) != "":
            if not CityData.take_livestock_for(str(target_res_id)):
                hud.show_message(tr("Not enough livestock: %d heads of %s are needed to start a herd")
                        % [CityData.livestock_breeding_cost(),
                        GameData.get_product_name(GameData.live_product_of(str(target_res_id)))],
                        GameData.HUD_MESSAGE_IMPORTANT)
                return false
            livestock_meta = {"livestock_res_id": str(target_res_id)}

    # The one-time fee of an outpost is written off when the project really starts (after the
    # active pause) and travels in meta, so that the cancellation can return it.
    if outpost_fee > 0 and not CityData.ignore_build_requirements:
        if not CityData.spend_treasury(outpost_fee):
            hud.show_message(tr("Not enough coins for the outpost fee: %d needed") % outpost_fee,
                    GameData.HUD_MESSAGE_IMPORTANT)
            return false
        CityData.record_treasury_expense(GameData.SRC_OUTPOST, outpost_fee)

    # The input data for the save: the road of this hex is going by a phased
    # project. While the flag is absent, the recalculation of the network "by the fact of the improvement"
    # (road_manager.rebuild_roads_from_existing) would count the hex as ready and
    # would finish the rest of the route for free. We set the flag BEFORE the start and remove it,
    # if the project has not started after all, — otherwise the hex would remain forever
    # an "improvement without a road" in the data of the save.
    tile_data[row][col]["road_staged"] = true
    var project_meta: Dictionary = livestock_meta.merged({
            "improvement": imp_name, "improvement_id": imp_id,
            "outpost_fee": outpost_fee if outpost_fee > 0 else 0})
    if not _start_road_project_steps(row, col, steps, total_cost, false, title, project_meta):
        tile_data[row][col]["road_staged"] = false
        if not livestock_meta.is_empty():
            CityData.return_livestock_for(str(livestock_meta.get("livestock_res_id", "")))
        if outpost_fee > 0 and not CityData.ignore_build_requirements:
            CityData.add_treasury(outpost_fee)
            CityData.record_treasury_expense(GameData.SRC_OUTPOST, -outpost_fee)
        return false
    return true

# The common part of the start of the road: the steps and the price are already counted, it remains to put
# the queue in project_manager. Both entries go through it — the road by the special action
# and the road to an improvement, — therefore the rules of the construction of them coincide by
# construction: one queue of the steps, one formula of the price of a segment
# (MapHelpers.get_road_step_work_cost), one handler of the step
# (_on_project_step_completed).
func _start_road_project_steps(row: int, col: int, steps: Array, cost: int,
        is_town: bool, title: String, extra_meta: Dictionary) -> bool:
    if steps.is_empty():
        return false

    # A free road cannot wait: a step without the work in the queue of the project is
    # a step which will not finish by itself and will hold the slot forever. For
    # such a road we immediately pass all the steps: there is nothing to pay, nothing to wait for.
    if cost <= 0:
        return _finish_free_road_project(row, col, steps, is_town)

    # We put the target in meta: the event project_completed comes already AFTER
    # the project has been thrown out of the manager, and there is nowhere else to take the hex which
    # has to be marked with the input data for the save.
    var meta := {
        "mode": "build",
        "is_town": is_town,
        "target_row": row,
        "target_col": col,
    }
    meta.merge(extra_meta)
    var project_id: String = project_manager.start_project("road", title, row, col, steps, meta)
    if project_id == "":
        return false
    hud.show_message(tr("%s: %d sections, built one at a time") % [title, steps.size()], GameData.HUD_MESSAGE_NORMAL)
    # The ghost of the route appears immediately after the confirmation and lives until the end of
    # the build: from this moment the panel is closed, and the player must nevertheless
    # see the whole project on the map and understand how much is still left.
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    return true

# A free road is built entirely and at once: there is nothing to pay for it, therefore
# there is no reason to wait in the queue of the project. The effects of the steps are the same and in the same
# order (from the network to the target), as in an ordinary project, — the common function of the effect of the
# step (_on_project_step_completed) is called from both paths, so that the rule
# "a segment has appeared — the hex is connected" does not exist in two forms.
func _finish_free_road_project(row: int, col: int, steps: Array,
        is_town: bool) -> bool:
    for step in steps:
        _on_project_step_completed("", "road", step)
    _mark_road_built(row, col, {"is_town": is_town})
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()
    return true

# The improvement of the already built road from the city to the hex (row, col).
#
# The difference from the building of a new road: the segments ALREADY EXIST, therefore the step of the project does not
# add a segment, but raises its level (road_manager.upgrade_road_segment).
# The queue itself and the "ghost" — the same as for the building: the player sees the route to
# the target and understands how many segments are still to be improved.
#
# The steps go FROM THE CITY to the target, as during the construction: in this way the progress bar travels in the same
# direction as the ghost, and the player sees where the road has already been improved.
func start_road_upgrade_project(row: int, col: int, road_level: int) -> bool:
    if not GameData.is_road_level_unlocked(road_level):
        hud.show_message(tr("Road level %d requires a technology") % road_level, GameData.HUD_MESSAGE_IMPORTANT)
        return false
    var breakdown := get_road_upgrade_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        hud.show_message(tr("Nothing to upgrade: %s")
                % breakdown.get("reason", tr("no route to the city")), GameData.HUD_MESSAGE_IMPORTANT)
        return false
    var steps: Array = breakdown.get("steps", [])

    if not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        hud.show_message(tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)")
                % CityData.total_population, GameData.HUD_MESSAGE_IMPORTANT)
        return false

    if active_pause != null and active_pause.has_pending_at(row, col):
        hud.show_message(tr("Construction is already underway here"), GameData.HUD_MESSAGE_IMPORTANT)
        return false

    if active_pause != null and active_pause.intercept({
            "key": str(row) + "," + str(col),
            "label": tr("Upgrade road"),
            "row": row,
            "col": col,
            "bar_color": UI_THEME.color("info"),
            "bar_offset": 16,
            "execute": func(): start_road_upgrade_project(row, col, road_level),
    }):
        return true

    var project_id: String = project_manager.start_project(
            "road_upgrade", tr("Upgrade road"), row, col, steps, {
        "mode": "upgrade",
        "target_row": row,
        "target_col": col,
        "road_level": road_level,
    })
    if project_id == "":
        return false
    hud.show_message(tr("Upgrading the road to the city: %d sections") % steps.size(), GameData.HUD_MESSAGE_NORMAL)
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    return true

# The effect of one segment of the road: the segment goes into the network of the city, both of its hexes
# become connected. The flag road_built is set on EVERY connected
# hex, and not only on the target of the project: the segments are not written to the save, and by these
# the flags the network is recalculated on loading (road_manager.rebuild_player_roads).
# In this way a half-built road survives the restart, and does not disappear.
#
# The same handler also serves the improvement of the road (kind "road_upgrade"):
# the segment already exists, therefore instead of adding a segment its level
# is raised. Both modes in one place — the rule "the step has been applied to the hex"
# must not exist in two forms.
func _on_project_step_completed(_project_id: String, kind: String, step: Dictionary) -> void:
    var data: Dictionary = step.get("data", {})

    # The last step of the chain "road → improvement": we place the improvement. Its data
    # travels in the step (imp_id, the bred animal/plant), because the records
    # of the build in build_manager on this hex are absent — the improvement lies in the queue
    # of the project. The effect is applied by the same _apply_improvement as an ordinary
    # build from active_builds.
    if str(data.get("step_type", "")) == "improvement":
        var imp_id := str(data.get("improvement", ""))
        if imp_id.is_empty():
            return
        var imp_row := int(step.get("hex", {}).get("row", -1))
        var imp_col := int(step.get("hex", {}).get("col", -1))
        if imp_row < 0 or imp_col < 0:
            return
        _apply_improvement(imp_row, imp_col, imp_id, data.get("target_res_id", null))
        hud.show_message(tr("Completed: %s") % str(data.get("imp_name", imp_id)), GameData.HUD_MESSAGE_NORMAL)
        control_panel.refresh()
        return

    if kind != "road" and kind != "road_upgrade":
        return
    var from_hex: Dictionary = data.get("from", {})
    var to_hex: Dictionary = data.get("to", {})
    var f_row := int(from_hex.get("row", -1))
    var f_col := int(from_hex.get("col", -1))
    var t_row := int(to_hex.get("row", -1))
    var t_col := int(to_hex.get("col", -1))
    if f_row < 0 or t_row < 0:
        return
    var road_level := int(data.get("road_level", road_manager.DEFAULT_ROAD_LEVEL))
    if bool(data.get("is_upgrade", false)):
        road_manager.upgrade_road_segment(f_row, f_col, t_row, t_col, road_level)
        if t_row < tile_data.size() and t_col < tile_data[t_row].size() \
                and tile_data[t_row][t_col] != null:
            tile_data[t_row][t_col]["road_level"] = road_level
        return
    road_manager.build_road_step(f_row, f_col, t_row, t_col,
            bool(data.get("is_town", false)), road_level)
    if t_row < tile_data.size() and t_col < tile_data[t_row].size() \
            and tile_data[t_row][t_col] != null:
        tile_data[t_row][t_col]["road_built"] = true
        # The level of the segment is the input data for the save on a par with road_built:
        # without it the restored network would be a solid trail.
        tile_data[t_row][t_col]["road_level"] = road_level
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

# The road is completed entirely: we mark the target with the input data for the save and
# open the trade, if the road was going to a town.
func _on_project_completed(_project_id: String, kind: String, meta: Dictionary) -> void:
    _refresh_project_ghost()
    if kind == "road":
        # The project has already been thrown out of the manager by this moment, therefore we take the target
        # from meta, filled in at the start (see start_road_project).
        var row := int(meta.get("target_row", -1))
        var col := int(meta.get("target_col", -1))
        if row >= 0 and col >= 0:
            # For the chain "road → improvement" the message of the finished road would be
            # in vain: the improvement has already worked as the last step and has spoken about itself
            # (_on_project_step_completed). The flag road_built is set in any case.
            _mark_road_built(row, col, meta, not meta.has("improvement"))
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

func _on_project_cancelled(_project_id: String, _kind: String, _meta: Dictionary) -> void:
    # The laid segments remain (the cancellation does not roll back the road), only
    # the ghost of what could not be completed disappears.
    # The seed herd of a cancelled "road → breeding" project returns to the storage.
    # It travels in the meta only while the improvement step is NOT applied: after it
    # the project completes and the cancellation is impossible.
    var livestock_res_id = str(_meta.get("livestock_res_id", ""))
    if livestock_res_id != "":
        CityData.return_livestock_for(livestock_res_id)
    # The fee of an outpost returns together with the project: the improvement was not
    # placed, so the player did not get what the coins were paid for.
    var outpost_fee := int(_meta.get("outpost_fee", 0))
    if outpost_fee > 0 and not CityData.ignore_build_requirements:
        CityData.add_treasury(outpost_fee)
        CityData.record_treasury_expense(GameData.SRC_OUTPOST, -outpost_fee)
    _refresh_project_ghost()
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

# Marks the target of the road as built — this is the input data for the restoration of the
# road from the save (the segments are not written to the save, see road_manager).
# An ordinary hex gets the flag on the hex itself; a town gets it on the hex (the road
# reaches the town centre, so the flag lies there) and in the record of the town (by it
# the availability of the trade is read, see town_manager.is_trade_available).
func _mark_road_built(row: int, col: int, plan: Dictionary,
        show_message: bool = true) -> void:
    tile_data[row][col]["road_built"] = true
    if not bool(plan.get("is_town", false)):
        if show_message:
            hud.show_message(tr("Road built!"), GameData.HUD_MESSAGE_NORMAL)
        return
    var town = find_town_at(row, col)
    if town == null:
        return
    town["road_linked"] = true
    if show_message:
        hud.show_message(tr("Road to town \"%s\" built — trade available!")
                % str(town.get("name", tr("Town"))), GameData.HUD_MESSAGE_NORMAL)

func _on_building_build_completed(building_id: String, build_key: String):
    # The construction of the building is complete - we add it to the city
    var slots = []
    if CityData.building_construction.has(build_key):
        var construction_data = CityData.building_construction[build_key]
        slots = construction_data.get("slots", [])
        CityData.building_construction.erase(build_key)

    CityData.city_built_buildings.append({"id": building_id, "slots": slots})

    # We assign the citizen
    if has_node("TownsfolkManager"):
        var tm = get_node("TownsfolkManager")
        tm.assign_townsfolk()

    CityData.emit_signal("city_updated")
    map_renderer.queue_redraw()
    _redraw_progress_layer()

    # The natural trigger of the transition to the next era: the Market has been built.
    if building_id == "market":
        _on_market_built()

func _on_building_upgrade_completed(_build_key: String, idx: int, upgrade_to: String, _building_name: String):
    # The upgrade of the building is complete — we replace the building under this index with the improved
    # version with the transfer of the settings (the recipes of the slots, the priority of the quality; the worker
    # remains bound to the index of the building, therefore the state "working/
    # paused" is transferred by itself). The signal city_updated is emitted inside
    # CityData.complete_building_upgrade, the panel of the city will update itself.
    CityData.complete_building_upgrade(idx, upgrade_to)

# The public wrapper over _confirm_cancel_build for the control panel.
func confirm_cancel_build(row: int, col: int):
    _confirm_cancel_build(row, col)

# The cancellation of a phased project. It is called from ANY of its hexes, therefore the project
# is passed by project_id, and not searched by the coordinates: the hex on which the player
# clicked may be the middle of the route, and not the target. The confirmation dialog is the same
# as for an ordinary build: the cancellation is irreversible, and the already laid segments of
# the road remain on the map.
func confirm_cancel_project(project_id: String):
    if project_manager == null or project_id == "":
        return
    var project: Dictionary = project_manager.get_project(project_id)
    if project.is_empty():
        return
    var steps: Array = project.get("steps", [])
    var done := int(project.get("step_index", 0))
    var left := maxi(0, steps.size() - done)
    var title := str(project.get("title", tr("Construction")))

    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel construction")
    var text := tr("Cancel \"%s\"?\n\n") % title
    if left > 0:
        var progress := 0.0
        var step_cost := 0.0
        if done < steps.size():
            # The labour of the CURRENT step, and not of the step under the clicked hex: the
            # click may land anywhere along the route, where the step progress is unknown.
            var cur: Dictionary = steps[done]
            progress = float(cur.get("progress", 0.0))
            step_cost = float(cur.get("work_cost", 0.0))
        text += tr("Unfinished sections: %d. Work spent on them (%.0f/%.0f) will be lost.\n\n") % [
            left, progress, step_cost,
        ]
    if done > 0:
        text += tr("Already built sections (%d) will stay on the map.") % done
    dialog.dialog_text = text
    dialog.get_ok_button().text = tr("Yes")
    var was_paused = get_tree().paused
    get_tree().paused = true
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS

    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        if project_manager.cancel_project(str(project.get("id", ""))):
            hud.show_message(tr("Construction cancelled"), GameData.HUD_MESSAGE_NORMAL)
        _refresh_project_ghost()
        _redraw_progress_layer()
    )
    add_child(dialog)
    dialog.popup_centered()
    dialog.visibility_changed.connect(func():
        if not dialog.visible and not was_paused:
            get_tree().paused = false
    )

func _confirm_cancel_build(row: int, col: int):
    var prog = build_manager.get_progress(row, col)
    if prog.is_empty():
        return
    var imp_name = prog.get("imp_name", tr("Upgrade"))
    var work_done = prog.get("progress", 0.0)
    var work_total = prog.get("work_cost", 0)

    # We create the confirmation dialog
    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel construction")
    dialog.dialog_text = tr("Cancel construction of \"%s\"?\n\nSpent work (%.0f/%d) will be lost.") % [imp_name, work_done, work_total]
    # We localize the button of the confirmation (by default Godot shows "OK" —
    # a project without translation files).
    dialog.get_ok_button().text = tr("Yes")
    # We pause the game while the confirmation dialog of the cancellation is open.
    var was_paused = get_tree().paused
    get_tree().paused = true
    # The dialog must accept the input while the tree is paused.
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS

    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        build_manager.cancel_build(row, col)
        # After the cancellation of the build the progress bar on the hex disappears — we redraw
        # the layer explicitly, because if it was the last active build, _process
        # will no longer call queue_redraw() for the layer of the bars.
        _redraw_progress_layer()
    )
    add_child(dialog)
    dialog.popup_centered()
    # The AcceptDialog has no signal canceled: the closing of the window by the cross simply
    # hides the dialog. We unpause in this case as well.
    dialog.visibility_changed.connect(func():
        if not dialog.visible and not was_paused:
            get_tree().paused = false
    )
