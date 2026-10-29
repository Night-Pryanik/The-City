# craft_container.gd
# A container of continuous crafting for one slot of a building.
#
# The principle: NOT a batch transaction on the interval completion, but a gradual
# filling with the ingredients at a given rate (amount / time units/sec)
# and the completion when ALL the ingredients have accumulated AND craft_time seconds have passed.
#
# On a shortage of raw materials the container "freezes": fractional/filled do not grow,
# the time does not accumulate — the craft automatically stretches until the raw materials appear.
#
# The structure of one ingredient slot:
#   {
#     "kind": "single" | "group" | "alternatives",
#         # a single product, an @-group, or an OR-group of the variants
#         # (see the alternative ingredients in the header of GameData.gd)
#     "pid": "...",                   # the id of the single product
#     "group_key": "...",             # the key of the @-group (for example "fruits")
#     "members": ["..."],             # the ids of the @-group members
#     "variants": [ { key, amount } ],# the variants of the OR-group (kind "alternatives")
#     "required": int,                # how many units need to be accumulated
#     "filled": int,                  # already accumulated (an integer)
#     "fractional": float,            # the fractional remainder per tick
#     "consumed": [{ qty: int, quality: String }],  # for the quality of the result
#     "consumed_pids": { pid: int },  # the accumulated composition of what was consumed BY PID
#                                     # across all the cycles (it is NOT reset in
#                                     # reset(); for science — the weighted average
#                                     # special_yield of the mix, see CityData.do_tick)
#     "extra": bool                   # the slot is an additional ingredient of the recipe
#                                     # (see "The quality of the result" below)
#   }
#
# THE QUALITY OF THE RESULT
# The base ingredients give a weighted average of their qualities, rounded to the nearest level.
# The additional ingredient is a minority of the mass — 10 units of dye against 20 of wool — so
# a plain average over everything would let a cheap addition DILUTE a good base: exceptional wool
# with a common dye averages 2.33 and drops to "fine". Instead the additional ingredient
# RAISES the level of the base by one at most, and never lowers it: a plain garment with an
# exceptional dye becomes "fine", a perfect garment stays perfect even with a common dye. That is
# why the slot knows whether it is an additional ingredient.
#
# The state is serialized via serialize()/deserialize() and saved
# together with city_built_buildings (without a separate key in the save).
#
# Dependencies: CityData (autoload) for the write-off from the storage and the group
# definitions. The container assumes that CityData is already loaded.

class_name CraftContainer
extends RefCounted

var recipe_id: String = ""
var craft_time: float = 1.0      # seconds per full cycle (recipe.time)
var elapsed: float = 0.0          # seconds since the last reset()
var ingredient_slots: Array = []  # an array of dictionaries (see the header of the file)
# The result of the recipe: { "pid": full_amount, ... }. It is cached on the creation of
# the container, so that tick() can compute the gradual output without re-reading
# the recipe every frame.
var result_products: Dictionary = {}
# The sub-unit accumulator for the output of the result: pid -> float. It stores the fractional
# remainder of "how many product units have accumulated since the last actual addition
# to the storage". On a tick we add per_release = full_amount * SIMULATION_TICK /
# craft_time; when it accumulates >= 1.0, we output the integer part to the storage and
# record it as consumption/production. This agrees the UI label "[+N≈]"
# with the fact in the storage: 10/10 sec = +1 every tick (and not +10 times in 10 sec).
var release_fractional: Dictionary = {}
# How much of the result this cycle has already reached the storage: pid -> int. The cycle owes
# exactly full_amount, while a tick can pay out only whole units — the debt is settled on
# completion (see the end of tick()).
var released: Dictionary = {}

# Constructs the container by the recipe. If slot_data is passed — it is used
# as the restored state (from the save). Otherwise — an empty container.
#
# recipe — the recipe dictionary from GameData.crafts:
#   {
#     "id": "...",
#     "time": 5.0,
#     "resources": { "pid_or_@group": amount, ... },
#     "result": { "pid": amount, ... }
#   }
func _init(recipe: Dictionary = {}, slot_data: Dictionary = {}):
    if not recipe.is_empty():
        recipe_id = str(recipe.get("id", ""))
        craft_time = _resolve_craft_time(recipe)
        if slot_data.is_empty():
            ingredient_slots = _build_slots_from_recipe(recipe)
        else:
            _restore_from_slot_data(recipe, slot_data)
        _init_release_state(recipe)
    elif not slot_data.is_empty():
        # Restoration without a recipe (theoretically; usually there is a recipe).
        recipe_id = str(slot_data.get("recipe_id", ""))
        craft_time = float(slot_data.get("craft_time", 1.0))
        elapsed = float(slot_data.get("elapsed", 0.0))
        ingredient_slots = slot_data.get("slots", [])
        # release_fractional is restored from the saved dict.
        var saved_release = slot_data.get("release_fractional", {})
        release_fractional = saved_release if saved_release is Dictionary else {}
        var saved_released = slot_data.get("released", {})
        released = saved_released if saved_released is Dictionary else {}

# Initializes the result cache and the sub-unit accumulator.
func _init_release_state(recipe: Dictionary):
    var prod: Dictionary = recipe.get("result", {})
    result_products = {}
    release_fractional = {}
    released = {}
    for pid in prod:
        var amt = int(prod[pid])
        if amt <= 0:
            continue
        result_products[pid] = amt
        release_fractional[pid] = 0.0
        released[pid] = 0

# --- SIMULATION TICK ---
# Advances the container by delta seconds. is_active = false — the container
# is frozen (there is no citizen in the building): we take nothing and do not accumulate time.
#
# quality_priority — "best" / "worst" / "random": the quality priority when
# taking from the storage. For @-groups it is always greedy by "best" within a single tick.
# output_multiplier — the multiplier of the OUTPUT RATE of the result (the profession bonus:
# 1.0 — no bonus). The ingredients are written off at the base rate meanwhile,
# therefore the bonus does not "eat" any extra raw materials.
#
# Returns a dictionary:
#   {
#     "completed": bool,                       # true if the container is full AND craft_time has passed
#     "consumed_breakdown": { pid: { quality: count } },  # the breakdown by quality (for calculating the quality of the result)
#     "missing": [String],                     # the ingredient keys that are not enough (for the UI/tooltip)
#     "releases": [{ "pid": "...", "amount": N, "quality": "..." }]  # what to output to the storage on this tick
#   }
func tick(delta: float, is_active: bool, quality_priority: String = "best", output_multiplier: float = 1.0) -> Dictionary:
    var result := {
        "completed": false,
        "consumed_breakdown": {},
        "missing": [],
        "releases": []
    }
    if not is_active:
        return result

    elapsed += delta
    for slot in ingredient_slots:
        var required_total = int(slot.get("required", 0))
        var filled_now = int(slot.get("filled", 0))
        if filled_now >= required_total:
            continue

        # The consumption rate: required / craft_time units/sec
        var per_sec := 0.0
        if craft_time > 0.0:
            per_sec = float(required_total) / craft_time

        # The sub-unit accumulator: the fractional remainder accumulates, so that the average
        # rate is accurate (for example, 21/5 = 4.2 → we alternate 4 and 5). The epsilon absorbs
        # the binary drift of the sum: ten additions of 0.1 give 0.9999999999999999, and without
        # it an ingredient of 2 units per 20 s would be taken a tick late, stretching the cycle.
        var fractional = float(slot.get("fractional", 0.0))
        var to_take_total = per_sec * delta + fractional
        var to_take_int = int(floor(to_take_total + 1e-9))
        fractional = maxf(0.0, to_take_total - float(to_take_int))
        slot["fractional"] = fractional

        if to_take_int <= 0:
            # Nothing is due this tick: a slow ingredient (2 stones per 20 s) reaches a whole unit
            # only every tenth tick. That is NOT a shortage — the rate is simply lower than
            # one unit per tick, and the release keeps following the clock.
            continue

        # We try to take to_take_int from the storage.
        var take_res := _take_from_storage(slot, to_take_int, quality_priority)
        var taken = int(take_res.get("taken", 0))
        var breakdown: Dictionary = take_res.get("breakdown", {})
        var taken_pids: Dictionary = take_res.get("pids", {})

        # We accumulate the composition of what was consumed BY PID. Unlike slot["consumed"]
        # (which is reset in reset()), this copy survives the cycles and is needed by science:
        # the weighted average special_yield of the actually consumed mix of raw materials
        # (see CityData.do_tick, the "SCIENCE RECIPE" block).
        var consumed_pids: Dictionary = slot.get("consumed_pids", {})
        for tp in taken_pids:
            consumed_pids[str(tp)] = int(consumed_pids.get(str(tp), 0)) + int(taken_pids[tp])
        slot["consumed_pids"] = consumed_pids

        if taken <= 0:
            result["missing"].append(_slot_display_key(slot))
            continue

        slot["filled"] = filled_now + taken

        # We record the "inputs" for the subsequent calculation of the quality of the result.
        var consumed_arr: Array = slot.get("consumed", [])
        for qid in breakdown:
            var cnt = int(breakdown[qid])
            if cnt <= 0:
                continue
            consumed_arr.append({"qty": cnt, "quality": str(qid)})
        slot["consumed"] = consumed_arr

        # We sum the consumed_breakdown by pid.
        for consumed_pid in taken_pids:
            if not result["consumed_breakdown"].has(consumed_pid):
                result["consumed_breakdown"][consumed_pid] = {}
            var agg: Dictionary = result["consumed_breakdown"][consumed_pid]
            for qid in breakdown:
                agg[qid] = int(agg.get(qid, 0)) + int(breakdown[qid])

        if taken < to_take_int:
            var key = _slot_display_key(slot)
            if not result["missing"].has(key):
                result["missing"].append(key)

    # --- GRADUAL OUTPUT OF THE RESULT ---
    # Every tick the container accumulates the fractional remainder per_release = full_amount
    # × delta / craft_time for each pid in result_products. When
    # release_fractional[pid] >= 1.0, we output the integer part to the storage (with a quality
    # calculated from the consumed accumulated at the current moment).
    #
    # The release follows the CLOCK, not the fill: an ingredient is taken at
    # required / craft_time per second, so the fill of a working container and the clock grow at
    # the same pace. A tick where a slow ingredient (2 units per 20 s) happens to owe nothing is
    # still a working tick — the rate of the result must not depend on how the ingredients are
    # quantised into whole units, otherwise the output arrives in bursts at the end of the cycle.
    #
    # The gate is the supply: a container with an ingredient that has nothing left to take pays
    # nothing out. The check is on the STORAGE, not on this tick's due amount: an ingredient of
    # 10 units per 20 s asks for a whole unit only every second tick, and on the ticks in between
    # the container looks idle while it is in fact starving. The cycle is not lost by a stall —
    # the time and the fill keep their own accounts, and the debt is settled on completion
    # (see below).
    #
    # The quality of the output is recalculated every tick — it depends on how much
    # raw material has already been taken, so it converges to the weighted average by the end of
    # the cycle.
    if craft_time > 0.0 and is_active and not _is_starving():
        for pid in result_products:
            var full_amount: int = int(result_products[pid])
            if full_amount <= 0:
                continue
            var per_release: float = float(full_amount) * delta / craft_time * output_multiplier
            var frac: float = float(release_fractional.get(pid, 0.0)) + per_release
            var floor_amount: int = int(floor(frac))
            frac = frac - float(floor_amount)
            release_fractional[pid] = frac
            if floor_amount > 0:
                released[pid] = int(released.get(pid, 0)) + floor_amount
                var release_quality := _compute_quality_from_consumed()
                result["releases"].append({
                    "pid": pid,
                    "amount": floor_amount,
                    "quality": release_quality
                })

    # The cycle is complete when every ingredient is gathered AND the time has passed. The
    # profession bonus may have released more than full_amount over the cycle — that surplus is
    # the point of the bonus, so only the debt is settled here: a recipe whose result cannot be
    # paid out in whole units (or that was stalled by a shortage) still owes exactly full_amount.
    var became_complete := _fill_progress() >= 1.0 and elapsed >= craft_time
    if became_complete:
        for pid in result_products:
            var full_amount: int = int(result_products[pid])
            if full_amount <= 0:
                continue
            var owed := full_amount - int(released.get(pid, 0))
            if owed > 0:
                var release_quality := _compute_quality_from_consumed()
                result["releases"].append({
                    "pid": pid,
                    "amount": owed,
                    "quality": release_quality
                })
            released[pid] = 0
            release_fractional[pid] = 0.0
        result["completed"] = true
    return result

# The progress of the cycle by the ingredients: min over the slots of filled/required (1.0 — every
# ingredient is gathered). It is used by the completion check: the time may have passed while the
# raw materials were missing, so the fill has the last word.
func _fill_progress() -> float:
    var min_fill := 1.0
    for slot in ingredient_slots:
        var required := float(slot.get("required", 0))
        if required <= 0.0:
            continue
        min_fill = minf(min_fill, float(int(slot.get("filled", 0))) / required)
    return clampf(min_fill, 0.0, 1.0)

# true when some ingredient still needs units but there is nothing left to take for it.
# It is checked AFTER the take loop of the tick, i.e. against the storage as it is now: a slot
# that has just taken its share and left an empty shelf counts as starving, which is the honest
# answer — the next unit is not there.
func _is_starving() -> bool:
    for slot in ingredient_slots:
        if int(slot.get("filled", 0)) >= int(slot.get("required", 0)):
            continue
        if not _slot_has_supply(slot):
            return true
    return false

# Whether the storage holds at least one unit the slot can take: the single pid itself,
# any member of the @-group, or any variant of the OR-group.
func _slot_has_supply(slot: Dictionary) -> bool:
    var kind := str(slot.get("kind", "single"))
    if kind == "alternatives":
        for variant in slot.get("variants", []):
            if _available_of_key(str(variant.get("key", ""))) > 0:
                return true
        return false
    if kind == "group":
        return _available_of_key("@" + str(slot.get("group_key", ""))) > 0
    return _available_of_key(str(slot.get("pid", ""))) > 0

# --- RESETTING THE CONTAINER ---
# Called after a successful craft or on a recipe change in the slot.
func reset():
    elapsed = 0.0
    for slot in ingredient_slots:
        slot["filled"] = 0
        slot["fractional"] = 0.0
        slot["consumed"] = []
        # slot["consumed_pids"] is NOT reset: it is the accumulated composition
        # of what was consumed by pid across all the cycles (it is needed by science — the weighted
        # average special_yield of the mix of raw materials), see CityData.do_tick.
    for pid in release_fractional:
        release_fractional[pid] = 0.0
    for pid in released:
        released[pid] = 0

# The quality of the result at the moment of the call — it is applied to each portion of the
# output. The base ingredients give the weighted average of their qualities; the additional
# ingredient raises that level by one at most, and never lowers it (see the header of the file).
#
# The result is a quality KEY, not a level: a good with an additional ingredient keeps the level
# of its base and the level of its addition apart, because its price is the sum of the two parts,
# each at its own level (see GameData, "THE QUALITY KEY OF A STORAGE ROW"). The level of the good
# itself is read from the key by the same rule — the base raised by the addition by one at most.
func _compute_quality_from_consumed() -> String:
    var levels: Array = []
    if is_instance_valid(GameData):
        levels = GameData.get_quality_levels()
    if levels.is_empty():
        return "common"

    var base := {}
    # The highest level among the units of the additional ingredient taken so far: its shelf may
    # hold a mix, and the addition counts at its best.
    var extra_level := -1
    for slot in ingredient_slots:
        var is_extra := bool(slot.get("extra", false))
        for entry in slot.get("consumed", []):
            var qty: int = int(entry.get("qty", 0))
            if qty <= 0:
                continue
            var qid: String = str(entry.get("quality", "common"))
            if is_extra:
                extra_level = maxi(extra_level, _level_index(qid, levels))
            else:
                base[qid] = int(base.get(qid, 0)) + qty

    var base_level := str(levels[_nearest_level_index(base, levels)])
    if extra_level < 0:
        return base_level
    return GameData.make_quality_key(base_level, str(levels[extra_level]))

# The index of the quality level in the ordered list of levels (worst first). The argument is a
# quality key — an additional ingredient keeps the levels of its parts, and it counts as the level
# of the good itself. An unknown key falls back to the worst level.
func _level_index(quality_key: String, levels: Array) -> int:
    return maxi(0, levels.find(GameData.quality_key_level(quality_key)))

# The level nearest to the weighted average of the consumed amounts.
func _nearest_level_index(consumed: Dictionary, levels: Array) -> int:
    var total: int = 0
    var weighted: float = 0.0
    for key in consumed:
        var count: int = int(consumed[key])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * float(GameData.get_quality_value(
                GameData.quality_key_level(str(key))))
    if total <= 0:
        return 0
    var avg: float = weighted / float(total)
    var best_index: int = 0
    var best_diff: float = 1e9
    for i in range(levels.size()):
        var diff: float = absf(float(GameData.get_quality_value(str(levels[i]))) - avg)
        if diff < best_diff:
            best_diff = diff
            best_index = i
    return best_index

# --- PROGRESS FOR THE UI (0..1) ---
# The readiness degree = min(the ingredients fill, time/craft_time).
# With a shortage of raw materials the progress still grows, as long as at least the
# time accumulates, — but it does not exceed 1.0.
func completion_ratio() -> float:
    if ingredient_slots.is_empty():
        return 0.0
    var min_fill := 1.0
    for slot in ingredient_slots:
        var req = float(slot.get("required", 1))
        if req <= 0.0:
            continue
        var fill: float = float(int(slot.get("filled", 0))) / req
        if fill < min_fill:
            min_fill = fill
    var time_ratio := 0.0
    if craft_time > 0.0:
        time_ratio = clampf(elapsed / craft_time, 0.0, 1.0)
    return clampf(minf(min_fill, time_ratio), 0.0, 1.0)

# The text state of the container for the building panel UI:
#   "8/20 (3.4 sec)"  — the fill + how much time has passed.
func status_text() -> String:
    if ingredient_slots.is_empty():
        return ""
    var slot0: Dictionary = ingredient_slots[0]
    var filled = int(slot0.get("filled", 0))
    var required = int(slot0.get("required", 0))
    return tr("%d/%d (%.1f sec)") % [filled, required, elapsed]

# --- SERIALIZATION ---
# The format:
#   {
#     "recipe_id": "...",
#     "craft_time": float,
#     "elapsed": float,
#     "slots": [ { ... per-slot state ... } ],
#     "release_fractional": { pid: float },
#     "released": { pid: int }
#   }
func serialize() -> Dictionary:
    return {
        "recipe_id": recipe_id,
        "craft_time": craft_time,
        "elapsed": elapsed,
        "slots": ingredient_slots.duplicate(true),
        "release_fractional": release_fractional.duplicate(true),
        "released": released.duplicate(true)
    }

# Restoration of the state from the previously serialized data. On a mismatch
# of the recipe (for example, the recipe has changed in the JSON), the container is recreated from scratch,
# but with the saved values for the compatible ingredients.
func _restore_from_slot_data(recipe: Dictionary, slot_data: Dictionary):
    recipe_id = str(recipe.get("id", slot_data.get("recipe_id", "")))
    craft_time = _resolve_craft_time(recipe)
    elapsed = float(slot_data.get("elapsed", 0.0))
    var saved_slots: Array = slot_data.get("slots", [])
    ingredient_slots = _build_slots_from_recipe(recipe)
    # The merge of the saved values by the matching ingredient keys.
    for i in range(ingredient_slots.size()):
        if i >= saved_slots.size():
            break
        var fresh: Dictionary = ingredient_slots[i]
        var saved: Dictionary = saved_slots[i]
        # An alternatives slot has no single pid/group key, so it is matched by
        # the kind and the required amount (see _slot_display_key for the kind).
        if str(saved.get("kind", "")) == str(fresh.get("kind", "")) \
                and str(saved.get("pid", "")) == str(fresh.get("pid", "")) \
                and str(saved.get("group_key", "")) == str(fresh.get("group_key", "")) \
                and int(saved.get("required", 0)) == int(fresh.get("required", 0)):
            fresh["filled"] = int(saved.get("filled", 0))
            fresh["fractional"] = float(saved.get("fractional", 0.0))
            fresh["consumed"] = saved.get("consumed", [])
            fresh["consumed_pids"] = saved.get("consumed_pids", {})
        # Otherwise a fresh empty slot remains (the recipe has changed).
        # release_fractional is restored, if it is saved in the current form.
    var saved_release = slot_data.get("release_fractional", null)
    var saved_released = slot_data.get("released", null)
    for pid in result_products:
        # We merge by pid — we keep only the known result_products.
        release_fractional[pid] = float(saved_release.get(pid, 0.0)) if saved_release is Dictionary else 0.0
        released[pid] = int(saved_released.get(pid, 0)) if saved_released is Dictionary else 0

# --- BUILDING THE SLOTS FROM THE RECIPE ---
# The resources are normalized through GameData.craft_alternatives(): an array of OR-groups
# of the variants { key, amount }. A group with one variant is a usual single/group slot;
# a group with several variants — the kind "alternatives": ANY variant listed is enough
# (see the alternative ingredients in the header of GameData.gd).
func _build_slots_from_recipe(recipe: Dictionary) -> Array:
    var out: Array = []
    var extra_pid := str(recipe.get("extra", ""))
    for or_group in GameData.craft_alternatives(recipe):
        if or_group.is_empty():
            continue
        var required := int(or_group[0].get("amount", 0))
        if required <= 0:
            continue
        var slot := {
            "kind": "single",
            "pid": "",
            "group_key": "",
            "members": [],
            "variants": [],
            "required": required,
            "filled": 0,
            "fractional": 0.0,
            "consumed": [],
            "consumed_pids": {},
            "extra": false
        }
        if or_group.size() == 1:
            _apply_variant_to_slot(slot, or_group[0])
            slot["extra"] = not extra_pid.is_empty() and str(slot["pid"]) == extra_pid
        else:
            slot["kind"] = "alternatives"
            slot["variants"] = or_group
        out.append(slot)
    return out

# Fills the slot by one variant of the ingredient: a single product or an @-group
# (the members are resolved by the id from data/product_groups.json).
func _apply_variant_to_slot(slot: Dictionary, variant: Dictionary):
    var key := str(variant.get("key", ""))
    slot["required"] = int(variant.get("amount", slot.get("required", 0)))
    if key.begins_with("@"):
        var group_key = key.trim_prefix("@")
        slot["kind"] = "group"
        slot["group_key"] = group_key
        slot["members"] = _resolve_group_members(group_key)
    else:
        slot["kind"] = "single"
        slot["pid"] = key

func _resolve_group_members(group_key: String) -> Array:
    # The resolution of an @-group by the id from data/product_groups.json. The reverse search by
    # the human-readable name is deliberately absent: it would silently substitute the members
    # of another group with a similar name (in the data the @-keys are always ids).
    if not is_instance_valid(GameData):
        return []
    return GameData.product_groups.get(group_key, [])

# Takes amount units from the storage for the slot. For a single one — directly;
# for an @-group — greedily by the members with the "best" priority within a tick.
#
# Returns:
#   {
#     "taken": int,                       # the amount actually taken
#     "breakdown": { quality: count },    # the breakdown by quality
#     "pids": { pid: count }              # the breakdown by pid (for an @-group — several)
#   }
func _take_from_storage(slot: Dictionary, amount: int, priority: String) -> Dictionary:
    var out := {"taken": 0, "breakdown": {}, "pids": {}}
    if amount <= 0:
        return out
    var kind = str(slot.get("kind", "single"))
    if kind == "alternatives":
        # OR-group: the variants are consumed GREEDILY in the order of the list
        # (the data author decides what is preferable). Mixing is possible when
        # the first variant has less than the tick asks: the remainder is taken
        # from the next variant, so a partial stock is never wasted.
        var remaining = amount
        for variant in slot.get("variants", []):
            if remaining <= 0:
                break
            if _available_of_key(str(variant.get("key", ""))) <= 0:
                continue
            var take_res := _take_by_variant(slot, variant, remaining, priority, false)
            var taken := int(take_res.get("taken", 0))
            if taken <= 0:
                continue
            for qid in take_res.get("breakdown", {}):
                out["breakdown"][qid] = int(out["breakdown"].get(qid, 0)) + int(take_res["breakdown"][qid])
            out["taken"] = int(out["taken"]) + taken
            for pid in take_res.get("pids", {}):
                out["pids"][pid] = int(out["pids"].get(pid, 0)) + int(take_res["pids"][pid])
            remaining -= taken
        return out
    if kind == "single":
        var pid = str(slot.get("pid", ""))
        if pid == "":
            return out
        return _take_single(pid, amount, priority)
    # --- @-group: greedily by the members with the "best" priority ---
    return _take_group(slot.get("members", []), amount, priority)

# Greedily takes the amount by the members of the @-group in the given order.
func _take_group(members: Array, amount: int, priority: String) -> Dictionary:
    var out := {"taken": 0, "breakdown": {}, "pids": {}}
    if members.is_empty():
        return out
    var remaining = amount
    var ordered := _order_group_members_by_priority(members, priority)
    for pid in ordered:
        if remaining <= 0:
            break
        var avail = int(CityData.city_storage.get(pid, 0))
        if avail <= 0:
            continue
        # We write off greedily at this pid within the limits of remaining.
        var take = mini(avail, remaining)
        var breakdown = CityData.remove_from_storage(pid, take, priority)
        # We merge the breakdown.
        for qid in breakdown:
            out["breakdown"][qid] = int(out["breakdown"].get(qid, 0)) + int(breakdown[qid])
        out["taken"] = int(out["taken"]) + take
        out["pids"][pid] = int(out["pids"].get(pid, 0)) + take
        remaining -= take
    return out

# The write-off of one product taking the quality priority into account. It delegates to
# CityData.remove_from_storage() — it will correctly update city_storage
# and city_quality_detail itself and return the breakdown by quality.
func _take_single(pid: String, amount: int, priority: String) -> Dictionary:
    var avail = int(CityData.city_storage.get(pid, 0))
    if avail <= 0:
        return {"taken": 0, "breakdown": {}, "pids": {}}
    var take = mini(avail, amount)
    var breakdown = CityData.remove_from_storage(pid, take, priority)
    return {
        "taken": take,
        "breakdown": breakdown,
        "pids": {pid: take}
    }

# Takes the amount of the variant of the ingredient: a single product directly,
# an @-group greedily by the members.
func _take_by_variant(_slot: Dictionary, variant: Dictionary, amount: int,
        priority: String, _dry_run: bool) -> Dictionary:
    var key := str(variant.get("key", ""))
    if key.begins_with("@"):
        var members: Array = _resolve_group_members(key.substr(1))
        return _take_group(members, amount, priority)
    return _take_single(key, amount, priority)

# How many units of the key (a product or an @-group) are there in the storage.
func _available_of_key(key: String) -> int:
    if key.begins_with("@"):
        var total := 0
        for member in _resolve_group_members(key.substr(1)):
            total += int(CityData.city_storage.get(str(member), 0))
        return total
    return int(CityData.city_storage.get(key, 0))

# Orders the members of an @-group by the quality priority.
# - "best"  — first the members with the LARGER amount of the BEST quality in the storage;
#             on a tie — the member with the larger total stock.
# - "worst" — the other way round.
# - other   — the order as in the array (without reordering).
# This is the agreement with the user: "greedily from the best quality" on a group
# consumption. If there are no best stocks — the member still participates (further in
# the order), so that the cycle does not hang waiting for the ideal source.
func _order_group_members_by_priority(members: Array, priority: String) -> Array:
    var out: Array = []
    out.append_array(members)
    if priority != "best" and priority != "worst":
        return out
    if not is_instance_valid(GameData):
        return out
    var quality_levels: Array = GameData.get_quality_levels()
    if quality_levels.is_empty():
        return out
    # The best quality is the last one in the order of levels (GameData returns from
    # the worst to the best, see the comment in _consume_quality_detail in CityData).
    # The stock is summed by the level of the good: a good with an additional ingredient holds a
    # key of two levels, and its units count as the level the good itself has.
    var best_qid: String = str(quality_levels[quality_levels.size() - 1])
    var sort_sign: int = -1 if priority == "best" else 1
    out.sort_custom(func(a, b):
        var a_best: int = int(GameData.quality_level_totals(
                CityData.city_quality_detail.get(a, {})).get(best_qid, 0))
        var b_best: int = int(GameData.quality_level_totals(
                CityData.city_quality_detail.get(b, {})).get(best_qid, 0))
        if a_best != b_best:
            return sort_sign * a_best < sort_sign * b_best
        # On a tie of the "best" stocks — we sort by the total amount.
        var a_total: int = int(CityData.city_storage.get(a, 0))
        var b_total: int = int(CityData.city_storage.get(b, 0))
        return sort_sign * a_total < sort_sign * b_total)
    return out

# --- INTERNAL ---
func _resolve_craft_time(recipe: Dictionary) -> float:
    var t := float(recipe.get("time", 0.0))
    if t <= 0.0:
        # The historical behaviour: time=0 → the craft every tick (1 sec).
        return 1.0
    return t

func _slot_display_key(slot: Dictionary) -> String:
    var kind := str(slot.get("kind", ""))
    if kind == "group":
        return "@" + str(slot.get("group_key", ""))
    if kind == "alternatives":
        # The readable key of the OR-group: all the variants separated by "|".
        # It is used only for the report of the shortage — the identity of the
        # variants is not required from it.
        var parts: Array = []
        for variant in slot.get("variants", []):
            parts.append(str(variant.get("key", "")))
        return "|".join(parts)
    return str(slot.get("pid", ""))
