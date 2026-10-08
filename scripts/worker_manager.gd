# worker_manager.gd
extends Node

signal assignment_changed()

var assigned_hexes = {}

# The sub-unit accumulator for the CONTINUOUS professional consumption,
# the key is "row,col". The value: { "fractional": { dkey: float, ... } } -
# the fractional remains of the consumption by each record of the consumption of a profession (dkey is
# the id of a product or "@id_of_the_group"). Earlier there was a packet timer
# { "elapsed", "interval" } here, which wrote off amount units once per interval seconds;
# in the continuous model every tick takes amount / interval units (with
# a fractional remains for the integer accuracy), see tick_consumption().
var consumption_timers: Dictionary = {}

# The same for the professions of the URBAN BUILDINGS (the field "profession" in buildings.json):
# the key is "b<index of the building>". The indices of the buildings are stable (there is no demolition, an upgrade
# preserves the index), therefore the key does not "drift". A separate dictionary: the format
# of the keys "row,col" of the per-hex timers and their serialization do not change.
# See tick_building_consumption().
var building_consumption_timers: Dictionary = {}

# The timers of the URBAN consumption of the pseudo-profession "all" (all the residents of the city).
# The key is display_key of the record of the consumption ("@fruits" for a group, the id of a product
# for a single one), the value is { "elapsed": float }. These timers live separately
# from consumption_timers (those are bound to the hexes "row,col"): the consumption of "all"
# is not bound to the improvements and is written off per capita by CityData.total_population.
var city_consumption_timers: Dictionary = {}

func find_vacancy() -> Dictionary:
    var main_map = get_parent()
    var tile_data = main_map.tile_data

    var candidates = []
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            var improvement = tile.get("improvement")
            if improvement == null or bool(tile.get("decorative", false)):
                continue
            # The infrastructure improvements (the field "no_worker" in improvements.json,
            # for example a pier) do not require the workers and must not receive them
            # on the auto-assignment of the free residents.
            if GameData.is_no_worker_improvement(improvement):
                continue
            if assigned_hexes.has(str(row) + "," + str(col)):
                continue

            var priority = 0
            if improvement == "farm" or improvement == "pasture" or improvement == "mine":
                priority = 1
            else:
                priority = 2

            candidates.append({
                "row": row,
                "col": col,
                "priority": priority,
                "improvement": improvement
            })

    candidates.sort_custom(func(a, b): return a.priority < b.priority)
    if candidates.size() > 0:
        return {"row": candidates[0].row, "col": candidates[0].col}
    return {}

func assign_worker(row: int = -1, col: int = -1) -> bool:
    if row == -1 or col == -1:
        var vacancy = find_vacancy()
        if vacancy.is_empty():
            return false
        row = vacancy.row
        col = vacancy.col

    var key = str(row) + "," + str(col)
    if assigned_hexes.has(key):
        return false
    if CityData.idle_population <= 0:
        return false

    # The protection from the direct calls: the infrastructure improvements (no_worker,
    # for example a pier) do not get a worker under any conditions.
    var mm = get_parent()
    if mm != null and row >= 0 and row < mm.map_rows and col >= 0 and col < mm.map_cols:
        var target_tile = mm.tile_data[row][col]
        if target_tile != null and bool(target_tile.get("decorative", false)):
            return false
        if target_tile != null and target_tile.get("improvement", null) != null \
                and GameData.is_no_worker_improvement(target_tile.improvement):
            return false

    assigned_hexes[key] = true
    # The mark of a profession is set AUTOMATICALLY here. The player does not manage
    # the marks directly: the profession is determined by the improvement to which
    # a worker is assigned (see docs.md, "The professions and the consumption").
    # We do not store any separate data about the mark - it is derived from the
    # improvement and is automatically removed by remove_worker().
    consumption_timers.erase(key) # a fresh start of the timer of the consumption
    CityData.idle_population -= 1
    emit_signal("assignment_changed")
    return true

func remove_worker(row: int, col: int):
    var key = str(row) + "," + str(col)
    if assigned_hexes.has(key):
        assigned_hexes.erase(key)
        # The mark of a profession is removed AUTOMATICALLY together with the removal of a worker
        # (it was derived from the improvement, see assign_worker).
        # We reset the timer of the consumption, so that on a repeated assignment
        # the countdown starts from scratch, and not from the "remains" of the past shift.
        consumption_timers.erase(key)
        CityData.idle_population += 1
        emit_signal("assignment_changed")

func has_worker(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    return assigned_hexes.has(key)

func get_assigned_count() -> int:
    return assigned_hexes.size()

# The profession of a worker on the hex (row, col). It returns the id of a profession by the improvement
# to which he is assigned, or "" if there is no worker / the improvement has no profession.
# The mark is derived from the improvement and is not displayed by a separate row "Profession" in the interface:
# it is used by the calculation of the consumption and by the plan map of the tab
# "Resources" (the name of the profession is the source of the expense).
func get_profession(row: int, col: int) -> String:
    if not has_worker(row, col):
        return ""
    var main_map = get_parent()
    if main_map == null:
        return ""
    var tile = main_map.tile_data[row][col]
    if tile == null:
        return ""
    var imp = tile.get("improvement")
    if imp == null:
        return ""
    return GameData.get_profession_for_improvement(imp)

# Advances the timer of the consumption of the hex by delta seconds and returns the final
# multiplier of the production. The core of the logic is common with the buildings -
# _tick_profession_consumption (the details are in it):
#   * If the profession has no consumption - it returns 1.0 (no bonus, no
#     changes for the rest of the system).
#   * On every call it checks whether there is enough of ALL the required
#     products in the storage. While there is enough - the multiplier = 1.0 + production_bonus
#     (for example, 1.5 with a bonus of 0.5). As soon as at least one of them is gone -
#     the multiplier rolls back to 1.0, the improvement continues to work at the base.
#   * The write-off is continuous: amount / interval units per second (the fractional
#     remains accumulate in the sub-unit accumulator). For the group records
#     any suitable product of the group is written off - greedily by the members
#     (the priority of the quality "best"). If there is no resource - the timer is not reset,
#     on the appearance of the resource the write-off happens at once.
#   * The bonuses of the single records of a profession add up, for the group ones the best
#     available is taken (see _aggregate_production_bonus).
# An improvement NEVER "stops": it always gives at least the base
# production. The bonus is an extra for the supply of the profession with the consumables.
func tick_consumption(row: int, col: int, delta: float) -> float:
    if not has_worker(row, col):
        return 1.0
    var prof = get_profession(row, col)
    if prof.is_empty():
        return 1.0
    return _tick_profession_consumption(prof, str(row) + "," + str(col), consumption_timers, delta)

# The profession of a resident in an urban building (the field "profession" in
# data/buildings.json). An empty string - the building has no profession.
func get_building_profession(b_index: int) -> String:
    if b_index < 0 or b_index >= CityData.city_built_buildings.size():
        return ""
    var bld_id := str(CityData.city_built_buildings[b_index].get("id", ""))
    return GameData.get_profession_for_building(bld_id)

# The consumption and the bonus of the profession of a resident in a building: the same mechanic as for a
# hex (tick_consumption), but the timers live in a separate dictionary
# building_consumption_timers, and the key is "b<index of the building>". The indices of the buildings
# are stable (there is no demolition, an upgrade preserves the index), therefore the key does not "drift".
# It is called from CityData.do_tick() only for a WORKING building (there is a
# resident and at least one non-empty slot): an idle building does not spend
# the consumables.
func tick_building_consumption(b_index: int, delta: float) -> float:
    var prof = get_building_profession(b_index)
    if prof.is_empty():
        return 1.0
    return _tick_profession_consumption(prof, "b" + str(b_index), building_consumption_timers, delta)

# The final multiplier of the production of the profession of a resident in a building WITHOUT the expense and
# the movement of the timers - for the planned production
# (CityData.get_building_planned_production), so that the mark "=" coincides with
# the fact. 1.0 - the building has no profession or there are not enough consumables.
func get_building_production_bonus(b_index: int) -> float:
    var prof = get_building_profession(b_index)
    if prof.is_empty():
        return 1.0
    return 1.0 + _aggregate_production_bonus(GameData.get_profession_consumption(prof))

# The total production_bonus of a profession by the available consumables:
#   * The SINGLE records - every available one adds its bonus (they add up):
#     the feathers +25% and the ink +25% -> +50%;
#   * The GROUP records - only the maximum of the available ones: the group "Boats"
#     gives the bonus from the best available member of the group, and not from all of them at once.
# "Available" means that the storage has a full pack of amount (see _can_consume_full).
# A record forbidden on the inner market (the toggle of the "Trade") gives no bonus:
# without a write-off there is also no "supply of the profession with the consumables", and otherwise
# the ban would turn into a free way to keep the multiplier x1.5
# permanently (there is no expense, and the bonus burns).
func _aggregate_production_bonus(cons_list: Array) -> float:
    var group_max := 0.0
    var single_sum := 0.0
    for entry in cons_list:
        if not CityData.is_market_consumption_enabled(_entry_display_key(entry)):
            continue
        var b := float(entry.get("production_bonus", 0.0))
        if b <= 0.0:
            continue
        if not _can_consume_full(entry, int(entry.get("amount", 0))):
            continue
        if entry.get("is_group", false):
            group_max = maxf(group_max, b)
        else:
            single_sum += b
    return group_max + single_sum

# The common core of the professional consumption: it advances the sub-unit accumulators
# of the passed dictionary of the timers (timers), writes off the resources from the storage and
# returns the multiplier of the production (1.0 - without a bonus).
#   * On every call it checks whether there is enough of ALL the required
#     products in the storage. While there is enough - the multiplier = 1.0 + production_bonus
#     (see _aggregate_production_bonus). As soon as at least one of them is gone -
#     the multiplier rolls back to 1.0, the object continues to work at the base.
#   * The per-second rate of the consumption = amount / interval: on every tick
#     a fractional remains accumulates, the integer part is written off from the storage.
#     For the group records any suitable product of the group is written off:
#     first the stock is summed over all the members, then it is spent greedily
#     (the priority of the quality "best"). If there is no resource - the timer is NOT reset;
#     on the appearance of the resource the write-off happens at once.
# The object NEVER "stops": it always gives at least the base production.
# The bonus is an extra for the supply of the profession with the consumables.
func _tick_profession_consumption(prof: String, key: String, timers: Dictionary, delta: float) -> float:
    var cons_list = GameData.get_profession_consumption(prof)
    if cons_list.is_empty():
        return 1.0

    # The identifier of the profession is the source of the expense (see GameData
    # .get_source_display_name: the label is resolved in ui_helpers at the drawing).
    var prof_source = GameData.profession_source_id(prof)

    # --- THE CONTINUOUS PROFESSIONAL CONSUMPTION ---
    # Instead of a packet write-off once per `interval` seconds - on every tick we take
    # amount / interval units (with a sub-unit accumulator). Earlier the consumption
    # was discrete: with amount=10, interval=10 the write-off happened once every
    # 10 seconds by a pack of 10 pieces, because of which the inventory of the player could "jump"
    # (on the tick of the write-off -10, all the other time -0). In the continuous model
    # the write-off goes evenly: -1 on every tick - the storage decreases smoothly,
    # the production bonus turns on/off smoothly with the fluctuations
    # of the stocks. This is consistent with the production of the resources (the farms/the mines/the workshops),
    # which are also converted to a continuous output.
    #
    # can_consume is determined by the FULL pack of amount (as before) - the bonus
    # turns on only when there is enough of the resource for a whole cycle. If there is only
    # a partial amount - we write off what there is, the bonus is NOT accrued.
    if not timers.has(key):
        timers[key] = {"fractional": {}}

    var fractional: Dictionary = timers[key].fractional

    for entry in cons_list:
        # The toggle of the "Trade": a resource which is forbidden on the inner market is not
        # spent at all. The check is BEFORE the accumulation of the fractional remains,
        # otherwise a forbidden record would accumulate a debt and on the permission write off
        # at once everything accumulated (see the fractional below).
        var entry_key := _entry_display_key(entry)
        if not CityData.is_market_consumption_enabled(entry_key):
            continue
        var amt: int = int(entry.get("amount", 0))
        var interval: float = float(entry.get("interval", 0))
        if amt <= 0 or interval <= 0.0:
            continue

        # The priority of the write-off by the quality is a setting of the player from the tab
        # "Trade" (CityData.consumption_priority, the default from
        # data/qualities.json). Earlier there was a hard "best" here.
        var priority := CityData.get_consumption_priority(entry_key)

        # The per-second rate of the consumption = amt / interval. On every tick
        # we accumulate a fractional remains.
        var per_tick: float = float(amt) / interval * delta
        var frac_key: String = _fractional_key(entry)
        var cur_frac: float = float(fractional.get(frac_key, 0.0)) + per_tick
        var floor_take: int = int(floor(cur_frac))
        if floor_take <= 0:
            fractional[frac_key] = cur_frac
            continue

        cur_frac -= float(floor_take)
        fractional[frac_key] = cur_frac

        if entry.get("is_group", false):
            # The write-off from a group: greedily by the members (the best quality).
            var remaining: int = floor_take
            for member_pid in entry.get("group_members", []):
                if remaining <= 0:
                    break
                var avail: int = CityData.get_storage_amount(member_pid)
                if avail <= 0:
                    continue
                var take: int = mini(avail, remaining)
                if take <= 0:
                    continue
                var member_consumed: Dictionary = CityData.remove_from_storage(member_pid, take, priority)
                CityData.record_consumption_source(member_pid, prof_source, take)
                # The fact of the INNER MARKET exactly - a separate counter for
                # the cards of the tab "Trade" (the general consumption_rates
                # is mixed with the production inputs of the buildings).
                CityData.record_market_consumption(member_pid, take)
                # The actual consumption on the inner market gives an income to the treasury.
                # The price is by the quality of EACH written-off unit: the breakdown of consumed
                # comes from remove_from_storage (see docs.md, "The treasury of the city and the
                # inner market").
                var member_take_price: int = CityData.get_internal_market_income(member_pid, member_consumed)
                CityData.add_treasury(member_take_price)
                # The source of the income for the tooltip "Treasury" by the same key,
                # as in the plan map (the name of a profession, for example "Fisherman").
                CityData.record_treasury_income(prof_source, member_take_price, str(member_pid))
                remaining -= take
        else:
            var pid: String = str(entry.get("product_id", ""))
            if pid.is_empty():
                continue
            var avail_single: int = CityData.get_storage_amount(pid)
            if avail_single <= 0:
                continue
            var take_single: int = mini(avail_single, floor_take)
            if take_single <= 0:
                continue
            var single_consumed: Dictionary = CityData.remove_from_storage(pid, take_single, priority)
            CityData.record_consumption_source(pid, prof_source, take_single)
            # The fact of the inner market (see above).
            CityData.record_market_consumption(pid, take_single)
            # The price is by the quality of each written-off unit (see above).
            var single_take_price: int = CityData.get_internal_market_income(pid, single_consumed)
            CityData.add_treasury(single_take_price)
            # The source of the income for the tooltip "Treasury" by the same key,
            # as in the plan map (the name of a profession, for example "Fisherman").
            CityData.record_treasury_income(prof_source, single_take_price, pid)

    timers[key].fractional = fractional
    return 1.0 + _aggregate_production_bonus(cons_list)

# Checks whether there is enough of a resource for a full cycle of the consumption for one record.
# For the groups - in total over all the members of the group.
func _can_consume_full(entry: Dictionary, amt: int) -> bool:
    if amt <= 0:
        return false
    if entry.get("is_group", false):
        var members: Array = entry.get("group_members", [])
        if members.is_empty():
            return false
        var total: int = 0
        for pid in members:
            total += CityData.get_storage_amount(pid)
            if total >= amt:
                return true
        return total >= amt
    var pid := str(entry.get("product_id", ""))
    if pid.is_empty():
        return false
    return CityData.get_storage_amount(pid) >= amt

# The DISPLAY_KEY of a record of the consumption is the single addressing key of the settings
# of the inner market (CityData.market_consumption_enabled /
# consumption_priority) and of the rows of the tab "Trade". For the group
# records it is the already ready "@<group>", for the single ones - the id of a product.
# The fallback to product_id is needed for the protection from the records without a display_key.
func _entry_display_key(entry: Dictionary) -> String:
    var key := str(entry.get("display_key", ""))
    if key.is_empty():
        key = str(entry.get("product_id", ""))
    return key

# The key for the fractional accumulator by the type of the resource (a single one/a group).
# One accumulator per record of the consumption.
func _fractional_key(entry: Dictionary) -> String:
    if entry.get("is_group", false):
        return "@" + str(entry.get("display_key", ""))
    return str(entry.get("product_id", entry.get("display_key", "")))

# The serialization of the timers of the consumption for the save.
# The format: [{ "row": int, "col": int, "fractional": { dkey: float, ... } }, ...]
# The fractional remains accumulate by dkey (the id of a product or the @-group) - after
# the switch to the continuous model there is nothing to store except for them (the new rules
# amount/interval are computed from the profession on the load).
func serialize_consumption_timers() -> Array:
    var result = []
    for key in consumption_timers.keys():
        var parts = key.split(",", false)
        if parts.size() == 2:
            result.append({
                "row": int(parts[0]),
                "col": int(parts[1]),
                "fractional": (consumption_timers[key].get("fractional", {}) as Dictionary).duplicate(true)
            })
    return result

func load_consumption_timers(timers: Array):
    consumption_timers.clear()
    for item in timers:
        if item is Dictionary and item.has("row") and item.has("col"):
            var row = int(item.get("row", -1))
            var col = int(item.get("col", -1))
            if row >= 0 and col >= 0:
                var frac_raw = item.get("fractional", {})
                var frac: Dictionary = frac_raw if frac_raw is Dictionary else {}
                consumption_timers[str(row) + "," + str(col)] = {
                    "fractional": frac
                }

# The serialization of the timers of the consumption of the buildings (see building_consumption_timers).
# The format: [{ "index": int, "fractional": { dkey: float, ... } }, ...]
func serialize_building_consumption_timers() -> Array:
    var result = []
    for key in building_consumption_timers.keys():
        var k := str(key)
        if not k.begins_with("b"):
            continue
        result.append({
            "index": int(k.substr(1)),
            "fractional": (building_consumption_timers[key].get("fractional", {}) as Dictionary).duplicate(true)
        })
    return result

func load_building_consumption_timers(timers: Array):
    building_consumption_timers.clear()
    for item in timers:
        if item is Dictionary and item.has("index"):
            var idx = int(item.get("index", -1))
            if idx >= 0:
                var frac_raw = item.get("fractional", {})
                var frac: Dictionary = frac_raw if frac_raw is Dictionary else {}
                building_consumption_timers["b" + str(idx)] = {
                    "fractional": frac
                }
# --- THE URBAN CONSUMPTION (the pseudo-profession "all", all the residents of the city) ---
# The profession "all" (data/professions.json) is the top of the hierarchy: it covers ALL
# the residents, including those employed at the improvements and in the buildings. Its consumption is not
# bound to the hexes, therefore it ticks with a general urban timer, and the records
# are taken from the same registry: GameData.get_profession_consumption("all").
#
# The semantics of amount for "all": PER ONE resident. The total write-off per tick =
# amount * CityData.total_population. The write-off goes BY THE FACT OF THE PRESENCE: per
# attempt min(what is in the storage, the required amount) is written off - there is no waiting for
# a full coverage. If the storage has less than required, everything that
# is there is written off, and the timer is reset; if the storage is empty - the timer is kept
# "hot", and everything which appears is written off on the nearest tick without waiting for
# a full interval. The greedy write-off from a @-group is as in tick_consumption().
# production_bonus is ignored: the urban consumption gives no bonuses.
# It is called from main_map._process on a tick of the simulation with the step
# CityData.SIMULATION_TICK (the same accuracy as that of the per-hex consumption).
func tick_city_consumption(delta: float) -> void:
    var cons_list = GameData.get_profession_consumption("all")
    var all_source = GameData.profession_source_id("all")
    if cons_list.is_empty():
        return
    for entry in cons_list:
        var iv = float(entry.get("interval", 0))
        if iv <= 0:
            continue
        var dkey = str(entry.get("display_key", ""))
        if dkey.is_empty():
            continue
        # The toggle of the "Trade": a forbidden resource is not bought by the residents.
        # The return is BEFORE the accumulation of the timer - otherwise the ban would accumulate the time and
        # on the permission it would write off the accumulated amount at once.
        if not CityData.is_market_consumption_enabled(dkey):
            continue
        if not city_consumption_timers.has(dkey):
            city_consumption_timers[dkey] = {"elapsed": 0.0}
        var timer: Dictionary = city_consumption_timers[dkey]
        timer.elapsed += delta
        if timer.elapsed < iv:
            continue

        # How much needs to be written off per tick: amount is per one resident.
        var amt = int(entry.get("amount", 0)) * CityData.total_population
        if amt <= 0:
            timer.elapsed = 0.0
            continue

        if entry.get("is_group", false):
            var members: Array = entry.get("group_members", [])
            if members.is_empty():
                continue
            var total := 0
            for pid in members:
                total += CityData.get_storage_amount(pid)
            if total <= 0:
                continue # the storage is empty - we do not reset the timer: we will write off at once on the appearance
            # The greedy write-off by the members of the group (the priority of the quality from
            # CityData.consumption_priority) BY THE FACT OF
            # THE PRESENCE: we take everything there is, but not more than required. Waiting for a full
            # coverage (amount * the population) is not required - a partial write-off
            # also happens (and resets the timer, see the timer.elapsed below).
            var remaining = amt
            # The priority of the write-off by the quality is a setting of the tab "Trade"
            # (CityData.consumption_priority), and not a hard "best".
            var priority := CityData.get_consumption_priority(dkey)
            for pid in members:
                if remaining <= 0:
                    break
                var avail = CityData.get_storage_amount(pid)
                if avail <= 0:
                    continue
                var take = min(avail, remaining)
                var group_consumed: Dictionary = CityData.remove_from_storage(pid, take, priority)
                CityData.record_consumption_source(pid, all_source, take)
                # The fact of the inner market for the card of the "Trade".
                CityData.record_market_consumption(pid, take)
                # The residents pay for the consumed goods from the treasury (the inner market).
                # The price is by the quality of each written-off unit.
                var group_take_price: int = CityData.get_internal_market_income(pid, group_consumed)
                CityData.add_treasury(group_take_price)
                # The source of the income for the tooltip "Treasury" (the urban consumption,
                # the name is taken from data/professions.json -> "All residents").
                CityData.record_treasury_income(all_source, group_take_price, str(pid))
                remaining -= take
        else:
            var pid = str(entry.get("product_id", ""))
            if pid.is_empty():
                continue
            var have = CityData.get_storage_amount(pid)
            if have <= 0:
                continue # the storage is empty - we do not reset the timer: we will write off at once on the appearance
            # By the fact of the presence: we write off everything there is, but not more than required.
            var take = min(have, amt)
            var city_consumed: Dictionary = CityData.remove_from_storage(pid, take, CityData.get_consumption_priority(dkey))
            CityData.record_consumption_source(pid, all_source, take)
            # The fact of the inner market for the card of the "Trade".
            CityData.record_market_consumption(pid, take)
            # The residents pay for the consumed goods from the treasury (the inner market).
            # The price is by the quality of each written-off unit.
            var city_take_price: int = CityData.get_internal_market_income(pid, city_consumed)
            CityData.add_treasury(city_take_price)
            # The source of the income for the tooltip "Treasury" (the urban consumption).
            CityData.record_treasury_income(all_source, city_take_price, pid)
        timer.elapsed = 0.0

# The serialization of the timers of the urban consumption for the save.
# The format: [{ "resource": String, "elapsed": float }, ...]
# We do not save interval - it is computed from the data on the load.
func serialize_city_consumption_timers() -> Array:
    var result = []
    for dkey in city_consumption_timers.keys():
        result.append({
            "resource": dkey,
            "elapsed": float(city_consumption_timers[dkey].get("elapsed", 0.0))
        })
    return result

func load_city_consumption_timers(timers: Array):
    city_consumption_timers.clear()
    for item in timers:
        if item is Dictionary and item.has("resource"):
            var dkey = str(item.get("resource", ""))
            if not dkey.is_empty():
                city_consumption_timers[dkey] = {
                    "elapsed": float(item.get("elapsed", 0.0))
                }

func serialize_assignments() -> Array:
    var result = []
    for key in assigned_hexes.keys():
        var parts = key.split(",", false)
        if parts.size() == 2:
            result.append({"row": int(parts[0]), "col": int(parts[1])})
    return result

func load_assignments(assignments: Array):
    assigned_hexes.clear()
    var main_map = get_parent()
    for item in assignments:
        if item is Dictionary and item.has("row") and item.has("col"):
            var row = int(item.get("row", -1))
            var col = int(item.get("col", -1))
            if row >= 0 and col >= 0:
                if main_map and row < main_map.map_rows and col < main_map.map_cols:
                    # "no_worker", a worker could have been assigned to a pier.
                    # Such assignments are inadmissible - we drop them (the resident
                    # will return to the free ones at the recalculation of the idle_population).
                    var load_tile = main_map.tile_data[row][col]
                    if load_tile != null and bool(load_tile.get("decorative", false)):
                        continue
                    if load_tile != null and load_tile.get("improvement", null) != null \
                            and GameData.is_no_worker_improvement(load_tile.improvement):
                        continue
                    assigned_hexes[str(row) + "," + str(col)] = true
    emit_signal("assignment_changed")

# --- THE PLANNED CONSUMPTION OF THE RESOURCES ---
# For the tab "Resources": the tooltip (the block "Consumption (planned)") and the dynamics with a
# marker "=". It shows how much of the resource WILL be written off by the current
# consumers, regardless of the phase of the timers of the consumption and the presence in the storage.
# The actual counters (CityData.consumption_rates/sources) live for one
# production tick and are filled only at the moment of the write-off - hence the "blind
# windows" of the interval consumption (the boats: 10 pieces once per 10 seconds).

# The number of the workers by the professions: prof_id -> count. One pass over the assigned
# hexes; the profession is derived from the improvement (see get_profession).
func count_workers_by_profession() -> Dictionary:
    var result: Dictionary = {}
    for key in assigned_hexes.keys():
        var parts = key.split(",", false)
        if parts.size() != 2:
            continue
        var prof = get_profession(int(parts[0]), int(parts[1]))
        if prof.is_empty():
            continue
        result[prof] = int(result.get(prof, 0)) + 1
    return result

# Collects the full map of the planned consumption:
#   product_id -> { "The name of the source" -> { "amount": int, "interval": float,
#                  "count": int, "is_group": bool, "group_name": String,
#                  "is_population": bool } }
# The sources:
#   1) the professional consumption of the workers at the improvements and of the residents in the
#      buildings (data/consumption.json and the legacy products[*].consumption):
#      amount of each record × the number of the workers/residents of the profession; for the buildings
#      only the WORKING ones are taken into account (there is a resident and a non-empty slot) -
#      CityData.get_townsfolk_professions_count;
#      with several records of one source amount is summed, and interval
#      is taken as the minimum - exactly as tick_consumption writes off (all the records
#      of the list at once by the minimum interval);
#   2) the urban consumption "all": amount × total_population (is_population);
#   3) the demand of the built buildings (the recipes of the slots,
#      CityData.get_building_planned_consumption): amount is the demand for one craft,
#      interval is the time of the recipe (`time`), see CityData.get_craft_time.
# For the group records the plan refers to ANY member of the group; in the tooltip such
# rows are marked with the name of the group (group_name = the name of the group from the data).
func get_planned_consumption_map(include_production_inputs: bool = true) -> Dictionary:
    var result: Dictionary = {}
    # The professional consumption: by the actual workers at the improvements.
    var workers = count_workers_by_profession()
    for prof_id in workers:
        if prof_id == "all":
            continue # the pseudo-profession is not assigned to the hexes; it is processed below
        _record_profession_planned(result, prof_id, int(workers[prof_id]), false)
    # The professional consumption of the urban buildings: the profession of a resident
    # (the field "profession" in data/buildings.json). Only the WORKING
    # buildings are taken into account - there is a resident and at least one non-empty slot: the consumables
    # of an idle building do not fall into the plan (see get_townsfolk_professions_count).
    var town_workers = CityData.get_townsfolk_professions_count()
    for prof_id in town_workers:
        if prof_id == "all":
            continue # the pseudo-profession is not assigned to the buildings; it is processed below
        _record_profession_planned(result, prof_id, int(town_workers[prof_id]), false)
    # The urban consumption "All residents" - always (the population >= 1), per capita:
    # count = total_population, and not the number of the assigned hexes.
    if CityData.total_population > 0:
        _record_profession_planned(result, "all", CityData.total_population, true)
    if not include_production_inputs:
        return result
    # The demand of the buildings (the recipes): amount is for one craft, interval is the time of the recipe.
    var building_demand = CityData.get_building_planned_consumption()
    for pid in building_demand:
        for source_id in building_demand[pid]:
            var e: Dictionary = building_demand[pid][source_id]
            _record_planned_entry(result, str(pid), str(source_id), int(e.get("amount", 0)), float(e.get("interval", 0.0)), int(e.get("count", 1)), bool(e.get("is_group", false)), str(e.get("group_name", "")), false)
    # The planned consumption of the improvements on the map (the feed of the pastures): amount is for one
    # cycle of the production, interval is the production_interval of the improvement. The feed
    # is written off per cycle (see main_map, the block "THE PRODUCTION CYCLE OF THE IMPROVEMENT"),
    # therefore the records fall into the plan on a par with the demand of the buildings.
    var improvement_demand = CityData.get_improvement_planned_consumption()
    for pid in improvement_demand:
        for source_id in improvement_demand[pid]:
            var e: Dictionary = improvement_demand[pid][source_id]
            _record_planned_entry(result, str(pid), str(source_id), int(e.get("amount", 0)), float(e.get("interval", 0.0)), int(e.get("count", 1)), bool(e.get("is_group", false)), str(e.get("group_name", "")), false)
    return result

# The consumption BY THE POPULATION, keyed by DISPLAY_KEY, is the source of the data for
# the cards of the tab "Trade" (the left column).
#
# What differs from get_planned_consumption_map(false):
#   * the key of the row is display_key ("feathers" / "@boats"), and not a pid. The plan
#     unfolds an @-group on EACH member, writing the full
#     sum into each - for the card "Fruits" it would give six rows with the full
#     sum instead of one;
#   * the groups are not unfolded: members is a list of the members, the storage and the price
#     are counted over them as a whole;
#   * the resources forbidden by the toggle of the "Trade" are NOT dropped, but
#     they remain with enabled = false - otherwise the player could not turn them
#     back on, seeing that they disappeared from the list.
#
# It returns:
#   display_key -> {
#     "name": String,          - the name of a product or a group,
#     "is_group": bool,
#     "members": Array,        - the pids: [pid] or the members of a group,
#     "icon": String,          - the name of the file of the icon ("" - there is no icon),
#     "enabled": bool,         - whether the consumption on the market is allowed,
#     "priority": String,      - the priority of the write-off by the quality,
#     "sources": { the name of a profession -> {
#         "amount": int,        - the SUM over all the consumers of this profession,
#         "unit_amount": int,   - the NORM PER ONE (amount from consumption.json),
#         "interval": float, "count": int,
#         "is_population": bool } },
#     "consumers_total": int,  - how many residents consume it (see below),
#     "per_sec": float,       - the total planned expense, units/sec.
#     "per_consumer_per_sec": float,   - the norm per one consumer, units/sec;
#     "per_consumer_amount": int,     - amount from consumption.json;
#     "per_consumer_interval": float,
#     "available": bool }     - whether the city can obtain it at all (see
#                             is_resource_obtainable)
#
# consumers_total is taken as max("All residents", Σ the professions): the pseudo-profession
# all covers the whole population, including the employed, therefore a simple summation
# would count the fisherman twice (both in "All residents" and in "Fisherman").
func get_population_consumption_map() -> Dictionary:
    var result: Dictionary = {}
    # The professional consumption: the workers at the improvements of the map.
    var workers = count_workers_by_profession()
    for prof_id in workers:
        if prof_id == "all":
            continue # the pseudo-profession is not assigned to the hexes
        _record_population_row(result, str(prof_id), int(workers[prof_id]), false)
    # The professional consumption of the urban buildings (the field "profession").
    var town_workers = CityData.get_townsfolk_professions_count()
    for prof_id in town_workers:
        if prof_id == "all":
            continue
        _record_population_row(result, str(prof_id), int(town_workers[prof_id]), false)
    # The pseudo-profession "all" - always, as long as there is a population.
    if CityData.total_population > 0:
        _record_population_row(result, "all", CityData.total_population, true)
    # We count the totals for each row.
    for display_key in result:
        _finalize_population_row(result, display_key)
    # Whether the city can obtain the resource at all: produced, extracted or imported.
    # The tab "Trade" hides the rows that are unavailable right now under a disclosure,
    # so that the working list is not mixed with the resources the city cannot get.
    for display_key in result:
        result[display_key]["available"] = is_resource_obtainable(result[display_key])
    return result

# Whether the city can obtain a resource or a group right now: it is already in the
# storage, it is produced (an actual or a planned output of a building/improvement) or
# it will be imported. A group is obtainable when at least one of its members is: the
# members are interchangeable.
#
# The only source of truth about the resources the city gets is the current production plan
# (CityData.get_planned_production_map) plus whatever already lies in the storage. A resource
# that is neither stored nor produced is beyond the reach of the city: no improvement extracts
# it, no recipe makes it, and the external trade that could import it is not implemented yet.
func is_resource_obtainable(row: Dictionary) -> bool:
    var members: Array = row.get("members", [])
    if members.is_empty():
        return true
    var planned: Dictionary = CityData.get_planned_production_map()
    for pid in members:
        var member := str(pid)
        if CityData.get_storage_amount(member) > 0:
            return true
        if planned.has(member):
            return true
    return false

# Adds/complements a row of the card by the profession prof_id with count
# consumers. The same profession can come from two sources
# (the workers on the map and the residents in the buildings) - their amounts add up.
func _record_population_row(result: Dictionary, prof_id: String, count: int, is_population: bool) -> void:
    if count <= 0:
        return
    # The key of the source is the identifier of the profession; the label is resolved by trade_tab.
    var source_id: String = GameData.profession_source_id(prof_id)
    for entry in GameData.get_profession_consumption(prof_id):
        var amount := int(entry.get("amount", 0)) * count
        if amount <= 0:
            continue
        var display_key := _entry_display_key(entry)
        if display_key.is_empty():
            continue
        var is_group: bool = bool(entry.get("is_group", false))
        if not result.has(display_key):
            result[display_key] = {
                "name": str(entry.get("product_name", display_key)),
                "is_group": is_group,
                "members": (entry.get("group_members", []) as Array).duplicate() if is_group else [str(entry.get("product_id", ""))],
                "icon": str(entry.get("icon", "")),
                "enabled": CityData.is_market_consumption_enabled(display_key),
                "priority": CityData.get_consumption_priority(display_key),
                "sources": {},
            }
        var row: Dictionary = result[display_key]
        # The row could have come from another profession - we complement the composition of the fields
        # once, without overwriting the already collected sources.
        if is_group and (row.get("members", []) as Array).is_empty():
            row["members"] = (entry.get("group_members", []) as Array).duplicate()
        var sources: Dictionary = row["sources"]
        var prev_amount: int = int(sources.get(source_id, {}).get("amount", 0))
        sources[source_id] = {
            "amount": prev_amount + amount,
            # The norm PER ONE consumer is exactly what is declared in
            # data/consumption.json (amount), without a multiplication by the number of the
            # consumers. Exactly it is shown by the card of the "Trade" in the row
            # "The expense for 1": the sum over the residents (10 units × 21 = 210) - that is already
            # "how much the city eats", and it must not be confused with the norm.
            "unit_amount": int(entry.get("amount", 0)),
            "interval": float(entry.get("interval", 0)),
            "count": count,
            "is_population": is_population,
        }

# Recounts the totals of the row of the card: the number of the consumers and the planned
# rate of the expense per second. The rate is amount × SIMULATION_TICK / interval
# (the same formula as in the planned consumption and in the tooltips): interval = 0
# means "per tick", and a tick of the simulation equals a second.
func _finalize_population_row(result: Dictionary, display_key: String) -> void:
    var row: Dictionary = result[display_key]
    var sources: Dictionary = row["sources"]
    var population_count := 0
    var professions_count := 0
    var per_sec := 0.0
    # The norm per one consumer. A resource can have several buyers with
    # DIFFERENT norms (for example, "All residents" eat the fruits by 10 units/sec, and
    # a scholar - the feathers by 10 units/5 seconds). We show the norm of the most massive
    # buyer: the card has one row "The expense for 1", and the norm of the "main"
    # buyer is the only one which does not lie. The norms of the others are visible in
    # the tooltip of this row (see trade_tab._on_consumption_hover).
    var best_count := -1
    var per_consumer_per_sec := 0.0
    var per_consumer_amount := 0
    var per_consumer_interval := 0.0
    for source_id in sources:
        var entry: Dictionary = sources[source_id]
        var count := int(entry.get("count", 0))
        if bool(entry.get("is_population", false)):
            population_count = maxi(population_count, count)
        else:
            professions_count += count
        var amount := float(entry.get("amount", 0))
        var interval := float(entry.get("interval", 0))
        if interval > 0.0:
            per_sec += amount * CityData.SIMULATION_TICK / interval
        else:
            per_sec += amount * CityData.SIMULATION_TICK
        # The norm of the source per one consumer: unit_amount is the amount from
        # data/consumption.json, already without a multiplication by count (see
        # _record_population_row), therefore there is nothing more to divide by.
        var unit_amount := float(entry.get("unit_amount", 0))
        var unit_per_sec := (unit_amount * CityData.SIMULATION_TICK / interval
            if interval > 0.0 else unit_amount * CityData.SIMULATION_TICK)
        # On an equality of the consumers the one who eats more in the recalculation
        # per one wins: so at 1 fisherman and 1 resident the row does not show the norm
        # of a random profile.
        if count > best_count or (count == best_count and unit_per_sec > per_consumer_per_sec):
            best_count = count
            per_consumer_per_sec = unit_per_sec
            per_consumer_amount = int(unit_amount)
            per_consumer_interval = interval
    row["consumers_total"] = maxi(population_count, professions_count)
    row["per_sec"] = per_sec
    row["per_consumer_per_sec"] = per_consumer_per_sec
    row["per_consumer_amount"] = per_consumer_amount
    row["per_consumer_interval"] = per_consumer_interval

# The planned rate of the INCOME of the treasury by the TYPES of the profit - for the tooltip "Treasury"
# in the HUD of the map and in the top bar of the interface of the city.
# The analogue of "Production (planned)" on the tab "Resources": an even flow,
# it does not flicker on the ticks without a write-off. It returns a hierarchical structure:
#   {
#     "The consumption of the population": {              # the type of the profit (top level)
#       "All residents": {                       # the source (= the name of a profession/residents)
#         "fruit":  { coins_per_sec: 2.5, product_name: "Fruits" },
#         "salt":   { coins_per_sec: 0.5, product_name: "Salt" }
#       },
#       "Fisherman": {
#         "reed_boat": { coins_per_sec: 1.2, product_name: "Boats" }
#       }
#     }
#     # the future types: "Taxes", "Trade" - are added here by a separate
#     # function, so that the scale of the types is extended without a fix of the tooltip.
#   }
# Within one "source" the products can repeat (for example, for
# `@boats` the group is laid out by the members - each member by a separate
# pid). The tooltip sorts the sources and the products by the descending rate.
#
# The goods without a base price (price <= 0) are excluded: the price of the inner market
# for them = 0 and they do not participate in the profit.
func get_planned_treasury_income_map() -> Dictionary:
    var result: Dictionary = {}
    _fill_consumption_income(result)
    _fill_tax_income(result)
    return result

# The actual rate of the income of the treasury by the sources and the products for the last
# window of the display. If the first window is not yet finished, we use its current
# accumulator, so that the tooltip is not empty right after the start of the game.
# The taxes (the type "Taxes") do not depend on the window: they come every tick, therefore
# they are always added - the row of the tax does not go empty even in the first window after
# the start/load (see _fill_tax_income).
func get_actual_treasury_income_map() -> Dictionary:
    var product_income: Dictionary = CityData.treasury_income_product_snapshot
    var window_sec := CityData.treasury_window_length_sec
    if product_income.is_empty():
        product_income = CityData.treasury_income_product_accum

    var result: Dictionary = {}
    if not product_income.is_empty() and window_sec > 0.0:
        var income_by_source: Dictionary = {}
        for source_id in product_income:
            var source_products: Dictionary = product_income[source_id]
            for pid in source_products:
                var amount: int = int(source_products[pid])
                if amount <= 0:
                    continue
                if not income_by_source.has(source_id):
                    income_by_source[source_id] = {}
                income_by_source[source_id][pid] = {
                    "coins_per_sec": float(amount) / window_sec,
                    "product_name": GameData.products.get(pid, {}).get("name", pid)
                }
        if not income_by_source.is_empty():
            result[CityData.POPULATION_INCOME_TYPE] = income_by_source
    _fill_tax_income(result)
    return result

# The taxes are the second type of the income of the treasury ("The consumption of the population" + "Taxes").
# Each resident pays the base tax every tick, therefore the planned and
# the actual rate coincide and are counted by ONE expression from the current
# of the population: CityData.get_tax_income_per_tick() (the single source of truth, there
# is also the rate from data/game_balance.json).
# The format of the record is a "flat" type (CityData.TREASURY_FLAT_TYPE_KEY): the tax is so far
# the only one, there is nothing to lay it out by the sources/products, therefore the tooltip
# draws it by one row "• Taxes: 2 × 3 persons = 6 / sec". "label" is the right
# part before the sign "=" (the rate × the number of the payers), the rate is formatted and
# added by the renderer itself (ui_helpers.show_treasury_tooltip).
func _fill_tax_income(result: Dictionary) -> void:
    var per_tick: int = CityData.get_tax_income_per_tick()
    if per_tick <= 0:
        return
    result[CityData.TAX_INCOME_TYPE] = {
        CityData.TREASURY_FLAT_TYPE_KEY: {
            "rate": float(per_tick) / CityData.SIMULATION_TICK,
            "label": tr("%d × %d people") % [
                CityData.get_base_tax_per_citizen(), CityData.total_population
            ]
        }
    }

# The income from the consumption on the inner market: the professional consumption
# of the workers + the urban consumption "all". The inputs of the recipes of the buildings and the improvements
# do not belong here: they are spent by the production, and not sold by the population.
# The market income lives under the type "The consumption of the population"; the other types
# ("Taxes" - see _fill_tax_income, "Trade" and so on) are added
# in parallel without a fix of this function.
# The planned income of the treasury from the market, FOLDED BY THE CARDS of the tab "Trade":
# display_key -> { "coins_per_sec": float, "by_source": { a profession: coins/sec } }.
#
# The key is display_key, and not a pid, exactly as in get_population_consumption_map: the
# card "Fruits" has six members of the group, and summing the income by a pid would mean
# showing six rows instead of one. The records of the plan are marked by display_key
# (see _record_planned_entry), therefore the folding is exact.
#
# The FORMULA is the same as in _fill_consumption_income (the plan "The consumption of the
# population" in the tooltip of the treasury): per_sec × the price, where the price is the market one with
# a correction for the average quality of what really lies in the storage. The general
# formula is moved out into _planned_market_income_per_pid, so that the card and the tooltip
# of the treasury physically could not differ in the number.
# The rows of the planned market income are the COMMON source of truth for the two
# consumers: the rows "Income" of the cards of the "Trade" and the block
# "The consumption of the population" in the tooltip of the treasury. It returns an array:
#   { "pid": String, "source": String, "coins_per_sec": float,
#     "product_name": String }
#
# The formula of the income is per_sec × the price, where the price is taken from
# _planned_market_income_per_pid (the market one, with a correction for the average quality
# of the storage). The formula lives in one place not out of love for the beauty: when the copies
# diverged, the card showed 3570 coins/sec, and the tooltip of the treasury 1260 -
# and neither of them looked broken.
func _planned_market_income_rows() -> Array:
    var rows: Array = []
    var per_pid := _planned_market_income_per_pid()
    var planned := get_planned_consumption_map(false)
    for pid in per_pid:
        if not planned.has(pid):
            continue
        # A member of a group without a remainder and without a production is not sold: a group is
        # "any suitable goods", and without a filter all six members of the "Fruits" would fall into the income at once.
        # all six members of the "Fruits" at once.
        if not bool(per_pid[pid]["available"]):
            continue
        var market_price: float = float(per_pid[pid]["price"])
        var product_name: String = GameData.products.get(pid, {}).get("name", pid)
        for source_id in planned[pid]:
            var entry: Dictionary = planned[pid][source_id]
            var amount := float(entry.get("amount", 0))
            var interval := float(entry.get("interval", 0))
            # The per-second consumption of a record (see ui_helpers._planned_per_sec).
            var per_sec: float
            if interval > 0.0:
                per_sec = amount * CityData.SIMULATION_TICK / interval
            else:
                per_sec = amount * CityData.SIMULATION_TICK
            if per_sec <= 0.0:
                continue
            rows.append({
                "pid": str(pid),
                "source": str(source_id),
                "coins_per_sec": per_sec * market_price,
                "product_name": product_name,
            })
    return rows

func get_population_income_map() -> Dictionary:
    var result: Dictionary = {}
    var planned := get_planned_consumption_map(false)
    for row_data in _planned_market_income_rows():
        var pid := str(row_data["pid"])
        var entry: Dictionary = planned[pid].get(str(row_data["source"]), {})
        var dkey := str(entry.get("display_key", ""))
        # An empty display_key - the record is not from the consumption of the population (the demand
        # of the buildings, the feed of the improvements): these are the production inputs, they are not
        # sold to the city and do not belong to the market income.
        if dkey.is_empty():
            continue
        var coins := float(row_data["coins_per_sec"])
        if not result.has(dkey):
            result[dkey] = {"coins_per_sec": 0.0, "by_source": {}}
        var row: Dictionary = result[dkey]
        row["coins_per_sec"] = float(row.get("coins_per_sec", 0.0)) + coins
        var by_source: Dictionary = row["by_source"]
        by_source[str(row_data["source"])] = \
            float(by_source.get(str(row_data["source"]), 0.0)) + coins
    return result

# The ACTUAL income of the inner market for the window of the display, folded by
# the cards of the tab "Trade": display_key -> { "coins_per_sec": float,
# "by_source": { a profession: coins/sec } }. The format is the same as in
# get_population_income_map, but there it is the PLAN, and here it is the FACT.
#
# The source is the same records CityData.record_treasury_income(a profession, a price, a pid),
# from which the tooltip of the treasury and the row "Treasury: N [+X]" are collected. Therefore the sum
# of the rows "Income" of the cards is equal to the actual market profit of the treasury: there is
# nothing by which they could differ. But it is the FACT that must be shown: the plan (the whole demand × the price) is not
# limited by the storage and for a half-empty storage gave fantastical thousands
# of coins per second, which never were in the treasury.
#
# The key is computed EXACTLY as in get_population_income_map (the display_key
# of the planned record of the same "source + goods" pair): for a group it is "@<group>", and
# the income of the six members of the "Fruits" falls into one card, and not into six rows.
func get_actual_market_income_map() -> Dictionary:
    var result: Dictionary = {}
    var actual: Dictionary = get_actual_treasury_income_map().get(CityData.POPULATION_INCOME_TYPE, {})
    if actual.is_empty():
        return result
    var planned := get_planned_consumption_map(false)
    for source_id in actual:
        var products: Dictionary = actual[source_id]
        for pid in products:
            var entry: Dictionary = planned.get(str(pid), {}).get(str(source_id), {})
            var dkey := str(entry.get("display_key", ""))
            # An empty display_key - the income is not from the consumption of the population (see above).
            if dkey.is_empty():
                continue
            var coins := float(products[pid].get("coins_per_sec", 0.0))
            if not result.has(dkey):
                result[dkey] = {"coins_per_sec": 0.0, "by_source": {}}
            var row: Dictionary = result[dkey]
            row["coins_per_sec"] = float(row.get("coins_per_sec", 0.0)) + coins
            var by_source: Dictionary = row["by_source"]
            by_source[str(source_id)] = \
                float(by_source.get(str(source_id), 0.0)) + coins
    return result

# The general formula of the planned market income: pid -> { "price": int, "available": bool }.
# price is the price of the inner market with a correction for the average multiplier of the quality
# of the storage (CityData.get_stock_quality_price_multiplier): the quality of the future deal
# is unknown, and the plan at the ordinary quality would understate the fact.
# available is whether the goods have any stock/production at all. For a GROUP
# record a member without a presence is not sold: a group is "any suitable goods",
# and without a filter all six members of the "Fruits" would fall into the income at once.
func _planned_market_income_per_pid() -> Dictionary:
    var result: Dictionary = {}
    var planned_production := CityData.get_planned_production_map()
    var planned := get_planned_consumption_map(false)
    for pid in planned:
        var market_price: int = int(round(
            float(CityData.get_internal_market_price(str(pid)))
            * CityData.get_stock_quality_price_multiplier(str(pid))))
        if market_price <= 0:
            continue
        var available := true
        for source_id in planned[pid]:
            var entry: Dictionary = planned[pid][source_id]
            if not bool(entry.get("is_group", false)):
                continue
            # A member of a group without a remainder and without a production does not go into the income.
            if CityData.get_storage_amount(str(pid)) <= 0 \
                    and int(CityData.production_rates.get(pid, 0)) <= 0 \
                    and planned_production.get(pid, {}).is_empty():
                available = false
                break
        result[str(pid)] = {"price": market_price, "available": available}
    return result

func _fill_consumption_income(result: Dictionary) -> void:
    var income_type := CityData.POPULATION_INCOME_TYPE
    if not result.has(income_type):
        result[income_type] = {}
    var type_dict: Dictionary = result[income_type]
    # Exactly the same rows as in the row "Income" of the cards of the "Trade"
    # (get_population_income_map) - a common helper, therefore a divergence of the numbers
    # between the card and the tooltip is impossible by construction.
    for row_data in _planned_market_income_rows():
        var source_id := str(row_data["source"])
        if not type_dict.has(source_id):
            type_dict[source_id] = {}
        var source_dict: Dictionary = type_dict[source_id]
        source_dict[str(row_data["pid"])] = {
            "coins_per_sec": float(row_data["coins_per_sec"]),
            "product_name": str(row_data["product_name"]),
        }

# Writes the planned consumption of the profession prof_id with count
# consumers into the result. For the pseudo-profession "all" count = the population of the city and
# is_population = true (the tooltip shows "(N persons)").
func _record_profession_planned(result: Dictionary, prof_id: String, count: int, is_population: bool):
    if count <= 0:
        return
    # The key of the source is the identifier of the profession; the label is resolved by ui_helpers.
    var source_id: String = GameData.profession_source_id(prof_id)
    for entry in GameData.get_profession_consumption(prof_id):
        # A resource forbidden on the inner market does not fall into the plan: otherwise
        # the tab "Resources" would show the expense, and the tooltip of the treasury - the income,
        # which will not be. The card of the "Trade" itself shows the ban
        # separately (see get_population_consumption_map).
        if not CityData.is_market_consumption_enabled(_entry_display_key(entry)):
            continue
        var amount = int(entry.get("amount", 0)) * count
        if amount <= 0:
            continue
        var interval = float(entry.get("interval", 0))
        var is_group: bool = entry.get("is_group", false)
        var targets: Array = entry.get("group_members", []) if is_group else [entry.get("product_id", "")]
        var group_name: String = str(entry.get("product_name", "")) if is_group else ""
        for pid in targets:
            if str(pid).is_empty():
                continue
            _record_planned_entry(result, str(pid), source_id, amount, interval, count, is_group, group_name, is_population, str(entry.get("display_key", "")))

# The helper of the recording/aggregation of the planned consumption (see get_planned_consumption_map).
# The key by_source is the identifier of the source (GameData.get_source_display_name).
func _record_planned_entry(result: Dictionary, pid: String, source_id: String, amount: int, interval: float, count: int, is_group: bool, group_name: String, is_population: bool, display_key: String = ""):
    if not result.has(pid):
        result[pid] = {}
    var by_source: Dictionary = result[pid]
    if not by_source.has(source_id):
        by_source[source_id] = {"amount": 0, "interval": interval, "count": 0, "is_group": false, "group_name": "", "is_population": false, "display_key": ""}
    var entry: Dictionary = by_source[source_id]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)
    entry["count"] = maxi(int(entry.get("count", 0)), count)
    entry["is_group"] = bool(entry.get("is_group", false)) or is_group
    if str(entry.get("group_name", "")) == "":
        entry["group_name"] = group_name
    entry["is_population"] = bool(entry.get("is_population", false)) or is_population
    # display_key addresses the CARD, and pid - a concrete goods. The same
    # consumption of the "Fruits" is written by the plan into each member of the group, and without
    # display_key it would be impossible to fold these records back into one row
    # of the card (see get_population_income_map). An empty value - the record is not
    # from the consumption of the population (the demand of the buildings, the feed of the improvements), it does not
    # participate in the market income.
    if str(entry.get("display_key", "")) == "" and not display_key.is_empty():
        entry["display_key"] = display_key
