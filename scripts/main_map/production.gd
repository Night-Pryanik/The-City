@tool
extends "res://scripts/main_map/roads.gd"

# This link — the simulation of the city: the tick of the production (see _simulation_tick), the
# growing pastures and the delivery of the produced units to the city.

# The tick of the simulation of the city: the production of every improvement on the map, the
# standing contracts with the towns, the shipping of the goods, the consumption of the city and
# the tick of CityData itself. It runs from _process once per CityData.SIMULATION_TICK.
func _simulation_tick(delta: float) -> void:
    production_timer += delta
    if production_timer >= CityData.SIMULATION_TICK:
        production_timer -= CityData.SIMULATION_TICK
        # We rebuild from scratch: the tick below will fill the list with the actual growing
        # pastures, and the frame-by-frame advance goes on in _tick_pasture_fill().
        _growing_pastures = {}
        _has_growing_pastures = false
        CityData.reset_counters()
        # The warning triangle over an improvement is drawn from tile.road_capacity_short,
        # the badge of a cut-off improvement from tile.road_missing. Both live in the state
        # layer, which redraws on demand, so a flag that flips here must ask for a redraw
        # itself: otherwise an upgraded road would leave the triangle on the screen until
        # the next assignment change.
        var overlay_flag_changed := false
        # The whole map, and not only the Region: an outpost — an improvement outside the
        # Region, opened by "Emporia" — produces on this very tick. The scan of the empty
        # hexes costs one null check, and the tick runs once a second.
        for row in range(map_rows):
            for col in range(map_cols):
                var tile = tile_data[row][col]
                if tile == null or tile.improvement == null:
                    continue
                if bool(tile.get("decorative", false)):
                    # An improvement of a town is not the player's: it neither produces for
                    # the city nor is served by its roads.
                    if bool(tile.get("road_capacity_short", false)) \
                            or bool(tile.get("road_missing", false)):
                        tile["road_capacity_short"] = false
                        tile["road_missing"] = false
                        overlay_flag_changed = true
                    continue
                # A road is what carries the goods to the city: an improvement that needs one
                # and has no route to the city stands idle. The improvements that are never
                # reached by a road (no_road, no_worker) keep delivering straight into the
                # storage — see _deliver_production.
                var route_avg_speed := _route_avg_speed(row, col)
                var road_missing := route_avg_speed < 0.0 \
                        and MapHelpers.improvement_needs_road(str(tile.improvement))
                if bool(tile.get("road_missing", false)) != road_missing:
                    tile["road_missing"] = road_missing
                    overlay_flag_changed = true
                if road_missing:
                    if bool(tile.get("road_capacity_short", false)):
                        tile["road_capacity_short"] = false
                        overlay_flag_changed = true
                    continue
                if not worker_manager.has_worker(row, col):
                    # A paused improvement transports nothing: there is no road-capacity
                    # problem to warn about.
                    if bool(tile.get("road_capacity_short", false)):
                        tile["road_capacity_short"] = false
                        overlay_flag_changed = true
                    continue
                # The road to the city limits the throughput: the surplus of a fast
                # improvement queues on the route instead of being destroyed (see the
                # delivery in _deliver_production). The warning triangle over the
                # improvement is driven by the SAME check as the red "(route X
                # units/sec)" note in the tooltip and the panel, so the badge and the
                # note cannot disagree.
                var capacity_short := not map_tooltip.road_capacity_shortfall(
                        row, col, tile_data).is_empty()
                if bool(tile.get("road_capacity_short", false)) != capacity_short:
                    overlay_flag_changed = true
                tile["road_capacity_short"] = capacity_short
                # The production goes both from the natural resource (tile.resource), and from
                # the bred one (tile.crop_bred, see the breeding scheme). If both are
                # null — there is nothing to produce on the hex.
                var eff_res = MapHelpers.get_effective_resource(tile)
                if eff_res == "":
                    # A forest plot on an empty forest hex: there is no resource, but
                    # the cover gives wood (wood_yield > 0 in covers.json).
                    # The output = wood_yield × the multipliers of the improvement and the profession.
                    # The future covers with wood_yield > 0 will be picked up automatically.
                    if tile.improvement == "lumberjack_hut":
                        var wood_yield: float = MapHelpers.get_cover_wood_yield(tile)
                        if wood_yield > 0.0:
                            var lj_consumption_mult: float = worker_manager.tick_consumption(
                                row, col, CityData.SIMULATION_TICK)
                            var lj_imp_mult: float = CityData.get_improvement_production_multiplier(
                                "lumberjack_hut", _is_hex_irrigated(row, col),
                                tile.get("terrain", ""), "lumberjack_hut")
                            # The identifier of the improvement — the source of the income/expense (the label
                            # is resolved by ui_helpers by the id, see
                            # GameData.get_source_display_name).
                            var lj_source = GameData.improvement_source_id("lumberjack_hut")
                            # --- THE CONTINUOUS PRODUCTION OF THE FOREST PLOT ---
                            # The wood yield of the cover is a per-second rate: on every tick
                            # we add (wood_yield × the multipliers) × SIMULATION_TICK units
                            # to the storage. The fractional remainder accumulates in
                            # tile.production_fractional_remainder, so that the average rate
                            # does not drift.
                            var lj_per_sec: float = wood_yield * lj_imp_mult * lj_consumption_mult
                            var lj_remainder: float = float(tile.get("production_fractional_remainder", 0.0)) + lj_per_sec * CityData.SIMULATION_TICK
                            var lj_floor: int = int(floor(lj_remainder))
                            tile["production_fractional_remainder"] = lj_remainder - float(lj_floor)
                            if lj_floor > 0:
                                _deliver_production(row, col, "wood", lj_floor, "common",
                                        lj_source, route_avg_speed)
                            # The planned output: it is visible on every tick, while the worker
                            # is in place.
                            CityData.record_planned_improvement_production("wood", lj_source,
                                int(ceil(wood_yield * lj_imp_mult * lj_consumption_mult)))
                    continue

                # The occupational consumption: the improvements which have a consumption
                # through a profession (the consumption of the product) write off
                # the resource by their own interval. The timer advances BY THE STEP OF THE TICK
                # of the simulation on every tick (a departure from "one tick, to rule
                # over all"): the accuracy is ±1 sec on the intervals of 10+ sec. The call
                # is OBLIGATORY for any hex with a worker — otherwise the timer of the
                # consumption does not advance and the bonus of the profession "freezes".

                # It returns the total multiplier of the production: 1.0 without the bonus,
                # 1.0+bonus while the resource is there. The improvement does NOT stop on a shortage —
                # it simply works at the base.
                var consumption_multiplier: float = worker_manager.tick_consumption(
                    row, col, CityData.SIMULATION_TICK)

                var res_data = GameData.raw_resources.get(eff_res, {})
                var feed_needed = res_data.get("feed_consumption", 0)
                var production_multiplier = 1.0
                if tile.improvement != null:
                    # We pass terrain_id and resource_id for the modifiers by
                    # the terrain (for example, the bitumen on the asphalt lake x2).
                    production_multiplier = CityData.get_improvement_production_multiplier(
                        tile.improvement, _is_hex_irrigated(row, col),
                        tile.get("terrain", ""), eff_res)

                # We apply the bonus of the occupational consumption (for example,
                # +50% to the production of fish, while there are reed boats).
                # The multiplier comes from worker_manager.tick_consumption();
                # it is equal to 1.0 without the bonus or with a shortage of the supplies.
                production_multiplier *= consumption_multiplier

                # The growing resources (time_to_mature > 0): the herd breeds in cycles,
                # the fill is advanced FRAME BY FRAME in _tick_pasture_fill() (a smooth
                # bar) and the batches of the heads are yielded there. The non-lethal
                # produce (the milk, the wool, the eggs) is ramped up only until the
                # FIRST maturation: after it the herd is established, and the breeding
                # cycles do not cut its output any more.
                var live_pid := GameData.live_product_of(eff_res)
                # The herd of the species lives in the city storage (the live_* units
                # there are the whole population). An extinct species (zero heads)
                # leaves the pasture empty: it yields nothing and consumes no feed.
                var herd_gone := live_pid != "" and CityData.get_storage_amount(live_pid) <= 0
                if MapHelpers.is_growing_resource(res_data):
                    # The key "row,col" — so that the duplicates do not accumulate between the ticks.
                    _growing_pastures[str(row) + "," + str(col)] = {"row": row, "col": col}
                    if not bool(tile.get("herd_mature", false)):
                        production_multiplier *= MapHelpers.get_fill_fraction(tile, res_data)
                if herd_gone:
                    production_multiplier = 0.0

                # The quality of the resource on the hex is passed into the production.
                var tile_quality = tile.get("quality", "common")
                # The identifier of the improvement — the source of the income/expense in the plan
                # (the label is resolved by ui_helpers, see
                # GameData.get_source_display_name).
                var improvement_source = GameData.improvement_source_id(str(tile.improvement))
                # --- THE CONTINUOUS PRODUCTION OF AN IMPROVEMENT ---
                # The "produces" of the resource is a per-second rate: on every tick we
                # add (produces × production_multiplier) × SIMULATION_TICK units of the
                # product to the storage. The fractional remainder accumulates in
                # tile.production_fractional_remainder, so that the average rate does not drift.
                #
                # The feed (feed_consumption) is written off at the same per-second rate:
                # feed_per_sec = feed_needed. If there is not enough feed, the production
                # is cut to 25% on this tick.
                var produces: Dictionary = res_data.get("produces", {})
                var feed_per_sec: float = float(feed_needed)

                if feed_needed > 0 and not herd_gone:
                    var feed_consumed: int = _consume_feed_continuous(tile, feed_per_sec, improvement_source)
                    var actual_mult: float = production_multiplier if feed_consumed >= feed_per_sec * CityData.SIMULATION_TICK else 0.25
                    _emit_continuous_production(tile, produces, actual_mult, tile_quality, improvement_source, row, col, route_avg_speed)
                else:
                    _emit_continuous_production(tile, produces, production_multiplier, tile_quality, improvement_source, row, col, route_avg_speed)

                # The planned output/consumption: they are visible on EVERY tick, while
                # the worker is in place (they close the gaps between the ticks on the tab
                # "Resources" — the same "blind windows" as for the recipes of the buildings).
                for planned_pid in GameData.raw_resources.get(eff_res, {}).get("produces", {}):
                    if not CityData.is_product_available(planned_pid):
                        continue
                    # The live_* heads are bred in batches by the cycle, they are not
                    # a per-second planned output.
                    if str(GameData.products.get(planned_pid, {}).get("category", "")) == "livestock":
                        continue
                    var planned_amount := 0
                    if feed_needed > 0 and CityData.city_storage.get("feed", 0) < feed_needed:
                        planned_amount = int(ceil(float(RangeUtils.get_min_value(res_data["produces"][planned_pid], 1)) * 0.25))
                    else:
                        planned_amount = int(ceil(float(RangeUtils.get_min_value(res_data["produces"][planned_pid], 1)) * production_multiplier))
                    CityData.record_planned_improvement_production(planned_pid, improvement_source, planned_amount)
                if feed_needed > 0 and not herd_gone:
                    CityData.record_planned_improvement_consumption("feed", improvement_source, feed_needed)

        # The standing contracts with the towns are paid and fulfilled on the city
        # tick (see town_trade_manager.tick_contracts), BEFORE the shipping: the
        # goods of a contract of this tick share the road with the production of
        # this tick, and a contract that cannot be paid is torn before it is
        # charged.
        if town_trade_manager != null:
            town_trade_manager.tick_contracts()
        if delivery_manager != null:
            # The goods produced in this tick are shipped BEFORE the interface reads the
            # queue: do_tick emits city_updated below, and the panel and the tooltip
            # rebuild the delivery rows from it. Shipping afterwards would show the fresh
            # production as "waiting to ship" even on a road that carries everything.
            delivery_manager.ship()
        if overlay_flag_changed:
            improvement_state_layer.queue_redraw()
        CityData.do_tick()
        # The consumption of the city of the pseudo-profession "all" (all the citizens of the city,
        # including the employed ones): it writes off the resources per head by total_population
        # by the common city timer (see worker_manager.tick_city_consumption).
        # It gives no bonus to the production — a test of the infrastructure.
        worker_manager.tick_city_consumption(CityData.SIMULATION_TICK)

func _tick_pasture_fill(delta: float):
    if _growing_pastures.is_empty():
        return
    var had_growing := true
    var still_growing := {}
    var cycle_mult := float(GameData.game_balance.get("breeding_cycle_multiplier", 1))
    for key in _growing_pastures:
        var entry: Dictionary = _growing_pastures[key]
        var row: int = entry["row"]
        var col: int = entry["col"]
        # We check the actuality: the improvement may have been demolished, the worker — removed.
        var tile = tile_data[row][col]
        if tile.improvement == null or bool(tile.get("decorative", false)) \
                or not worker_manager.has_worker(row, col):
            continue
        var eff_res := MapHelpers.get_effective_resource(tile)
        var res_data = GameData.raw_resources.get(eff_res, {})
        if not MapHelpers.is_growing_resource(res_data):
            continue
        var live_pid := GameData.live_product_of(eff_res)
        # The herd lives in the city storage: while the species is extinct (zero
        # heads), the pasture stays empty — the fill is frozen, nothing breeds.
        if live_pid != "" and CityData.get_storage_amount(live_pid) <= 0:
            still_growing[key] = entry
            continue
        var ttm: float = float(res_data["time_to_mature"])
        var fill_time: float = float(tile.get("fill_time", 0.0))
        fill_time += delta
        # The first maturation establishes the herd: from now on the non-lethal
        # produce flows in full and the fill becomes the progress of the breeding.
        if not bool(tile.get("herd_mature", false)) and fill_time >= ttm:
            tile["herd_mature"] = true
        var period: float = ttm * cycle_mult
        var produces: Dictionary = res_data.get("produces", {})
        while fill_time >= period:
            # The breeding batch: the pasture yields the heads straight into the
            # herd (the storage). The overshoot stays in fill_time for the next cycle.
            fill_time -= period
            if live_pid != "" and produces.has(live_pid) and int(produces[live_pid]) > 0:
                var batch := int(produces[live_pid])
                var source := GameData.improvement_source_id(str(tile.improvement))
                CityData.add_to_storage(live_pid, batch, str(tile.get("quality", "common")))
                CityData.record_production_source(live_pid, source, batch)
        tile["fill_time"] = fill_time
        still_growing[key] = entry
    _growing_pastures = still_growing
    _has_growing_pastures = not still_growing.is_empty()
    # We redraw while it is growing; the final frame — so as to erase the bar,
    # when the last pasture has been demolished (otherwise the bar hangs on the screen).
    if _has_growing_pastures or had_growing:
        progress_bar_layer.queue_redraw()

# --- THE CONTINUOUS PRODUCTION: THE HELPERS ---
# The functions moved out for the block "THE CONTINUOUS PRODUCTION OF AN IMPROVEMENT" in _process.
# These functions encapsulate the work with the sub-unit accumulator and with the write-off of the feed,
# so that the main cycle of the production stays compact and readable.

# Writes off the feed continuously: feed_per_sec units/sec. The fractional remainder
# accumulates in tile.feed_fractional_remainder. It returns how many units
# of the feed managed to be written off for the tick (0, if there is nothing in the storage).
#
# On a shortage of the feed: EVERYTHING that is in the storage is written off (within the
# limits of the accumulated remainder). If even partially it was not enough — the production
# is cut to 0.25 in the calling code.
func _consume_feed_continuous(tile: Dictionary, feed_per_sec: float, improvement_source: String) -> int:
    if feed_per_sec <= 0.0:
        return 0
    var remainder: float = float(tile.get("feed_fractional_remainder", 0.0)) + feed_per_sec * CityData.SIMULATION_TICK
    var floor_amount: int = int(floor(remainder))
    tile["feed_fractional_remainder"] = remainder - float(floor_amount)
    if floor_amount <= 0:
        return 0
    var available := int(CityData.city_storage.get("feed", 0))
    if available <= 0:
        return 0
    var take = mini(available, floor_amount)
    CityData.remove_from_storage("feed", take, "best")
    CityData.record_consumption_source("feed", improvement_source, take)
    return take

# The continuous production of an improvement: on every tick it produces
# produces × production_multiplier × SIMULATION_TICK units of the product.
# The fractional remainder accumulates in tile.production_fractional_remainder,
# so that the average rate does not drift.
#
# production_multiplier can be < 1.0 (for example, 0.25 on a shortage of the feed)
# or > 1.0 (the bonus of the profession). The zero values are skipped, so as not to
# breed the zero records in the sources.
#
# The produced units are handed to _deliver_production: with a road they go through the
# route (queue → road → storage, see delivery_manager.gd), and without one they reach
# the storage at once. The road therefore limits the DELIVERY, not the production: a
# fast improvement keeps producing, and the surplus waits in the queue instead of being
# destroyed by a slow road.
func _emit_continuous_production(tile: Dictionary, produces: Dictionary, production_multiplier: float, tile_quality: String, improvement_source: String, row: int, col: int, route_avg_speed: float = -1.0) -> void:
    if produces.is_empty():
        return
    var tick := float(CityData.SIMULATION_TICK)
    for pid in produces:
        if not CityData._is_product_available(pid):
            continue
        # The live_* heads are not a continuous flow: the herd breeds in batches
        # through the fill cycle (_tick_pasture_fill).
        if str(GameData.products.get(pid, {}).get("category", "")) == "livestock":
            continue
        var per_sec_amt := float(RangeUtils.get_min_value(produces[pid], 1)) * production_multiplier
        var remainder: float = float(tile.get("production_fractional_remainder", 0.0)) + per_sec_amt * tick
        var floor_amount: int = int(floor(remainder))
        tile["production_fractional_remainder"] = remainder - float(floor_amount)
        if floor_amount > 0:
            _deliver_production(row, col, pid, floor_amount, tile_quality,
                    improvement_source, route_avg_speed)

# Hands a unit of production to the city: through the route when the hex has one, and
# straight into the storage when it does not.
#
# A road that does not exist cannot limit anything, so the absence of a route
# (route_avg_speed < 0) means "deliver at once". The improvements that are due a road never
# reach this case: the production tick skips them while they have no route (see
# MapHelpers.improvement_needs_road), so what is delivered at once is only the produce of the
# water improvements behind a harbour and of the other no_road/no_worker infrastructure.
#
# The amounts are whole units: the caller keeps the sub-unit remainder of the
# production, so the delivery never has to deal with fractions.
func _deliver_production(row: int, col: int, product: String, amount: int,
        quality: String, source: String, route_avg_speed: float) -> void:
    if amount <= 0:
        return
    if route_avg_speed >= 0.0 and delivery_manager != null \
            and delivery_manager.create_cargo(row, col, product, quality, amount, source):
        return
    CityData.add_to_storage(product, amount, quality)
    CityData.record_production_source(product, source, amount)
