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
#     "kind": "single" | "group",     # a single product or an @-group
#     "pid": "...",                   # the id of the single product
#     "group_key": "...",             # the key of the @-group (for example "fruits")
#     "members": ["..."],             # the ids of the @-group members
#     "required": int,                # how many units need to be accumulated
#     "filled": int,                  # already accumulated (an integer)
#     "fractional": float,            # the fractional remainder per tick
#     "consumed": [{ qty: int, quality: String }],  # for the quality of the result
#     "consumed_pids": { pid: int },  # the accumulated composition of what was consumed BY PID
#                                     # across all the cycles (it is NOT reset in
#                                     # reset(); for science — the weighted average
#                                     # special_yield of the mix, see CityData.do_tick)
#   }
#
# The quality of the result is calculated at the moment of the craft completion as a
# weighted average of the qualities of all the "inputs" (consumed) — this is a direct analogue
# of the current behaviour of quality_from_breakdown().
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

# Initializes the result cache and the sub-unit accumulator.
func _init_release_state(recipe: Dictionary):
    var prod: Dictionary = recipe.get("result", {})
    result_products = {}
    release_fractional = {}
    for pid in prod:
        var amt = int(prod[pid])
        if amt <= 0:
            continue
        result_products[pid] = amt
        release_fractional[pid] = 0.0

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
    var all_full := true
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
        # rate is accurate (for example, 21/5 = 4.2 → we alternate 4 and 5).
        var fractional = float(slot.get("fractional", 0.0))
        var to_take_total = per_sec * delta + fractional
        var to_take_int = int(floor(to_take_total))
        fractional = to_take_total - float(to_take_int)
        slot["fractional"] = fractional

        if to_take_int <= 0:
            all_full = false
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
            all_full = false
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
            all_full = false
            var key = _slot_display_key(slot)
            if not result["missing"].has(key):
                result["missing"].append(key)

    # --- GRADUAL OUTPUT OF THE RESULT ---
    # Every tick the container accumulates the fractional remainder per_release = full_amount
    # × delta / craft_time for each pid in result_products. When
    # release_fractional[pid] >= 1.0, we output the integer part to the storage (with a quality
    # calculated from the consumed accumulated at the current moment).
    #
    # The quality of the output is recalculated every tick — it depends on how much
    # raw material has already been taken. If the recipe works at full volume (all the ingredients
    # are available), the quality converges to the final weighted average by the end of
    # the cycle. If on some tick the container has "frozen" due to a shortage,
    # the consumption also stops, and the output is temporarily suspended
    # (per_release accumulates, but release_fractional does not grow, because we
    # output only when elapsed grows — and it always grows when is_active).
    #
    # On completed we finish off the fractional remainder, so as to output exactly full_amount.
    if craft_time > 0.0 and is_active and all_full:
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
                var release_quality := _compute_quality_from_consumed()
                result["releases"].append({
                    "pid": pid,
                    "amount": floor_amount,
                    "quality": release_quality
                })

    # On completed we finish off the fractional remainder (if less than 1.0 is left by the end of the cycle).
    var became_complete := all_full and elapsed >= craft_time
    if became_complete:
        for pid in result_products:
            var leftover: float = float(release_fractional.get(pid, 0.0))
            if leftover > 0.0:
                var release_quality := _compute_quality_from_consumed()
                result["releases"].append({
                    "pid": pid,
                    "amount": int(leftover),
                    "quality": release_quality
                })
                release_fractional[pid] = 0.0
        result["completed"] = true
    return result

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

# An internal helper: the quality of the result = the weighted average over all the
# "inputs" of the container (at the moment of the call). It is used to determine
# the quality of each "portion" of the output.
func _compute_quality_from_consumed() -> String:
    var breakdown := {}
    for slot in ingredient_slots:
        for entry in slot.get("consumed", []):
            var qty: int = int(entry.get("qty", 0))
            var qid: String = str(entry.get("quality", "common"))
            if qty <= 0:
                continue
            breakdown[qid] = int(breakdown.get(qid, 0)) + qty
    if breakdown.is_empty():
        return "common"
    return _quality_from_breakdown(breakdown)

# A local copy of CityData.quality_from_breakdown — without an access to the autoload
# on every tick. The semantics are 1-to-1: the weighted average of the qualities
# rounded to the nearest level.
func _quality_from_breakdown(consumed: Dictionary) -> String:
    var levels: Array = []
    if is_instance_valid(GameData):
        levels = GameData.get_quality_levels()
    if levels.is_empty():
        return "common"
    var total: int = 0
    var weighted: float = 0.0
    for qid in consumed:
        var count: int = int(consumed[qid])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * float(GameData.get_quality_value(qid))
    if total <= 0:
        return "common"
    var avg: float = weighted / float(total)
    var best_qid: String = str(levels[0])
    var best_diff: float = 1e9
    for qid in levels:
        var diff: float = abs(float(GameData.get_quality_value(qid)) - avg)
        if diff < best_diff:
            best_diff = diff
            best_qid = str(qid)
    return best_qid

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
#     "release_fractional": { pid: float }
#   }
func serialize() -> Dictionary:
    return {
        "recipe_id": recipe_id,
        "craft_time": craft_time,
        "elapsed": elapsed,
        "slots": ingredient_slots.duplicate(true),
        "release_fractional": release_fractional.duplicate(true)
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
    if saved_release is Dictionary:
        # We merge by pid — we keep only the known result_products.
        for pid in result_products:
            release_fractional[pid] = float(saved_release.get(pid, 0.0))
    else:
        # An old save (without release_fractional) — we initialize with zeros.
        for pid in result_products:
            release_fractional[pid] = 0.0

# --- BUILDING THE SLOTS FROM THE RECIPE ---
# resources — { "pid_or_@group": amount, ... }. For @-groups we resolve the members.
func _build_slots_from_recipe(recipe: Dictionary) -> Array:
    var out: Array = []
    var resources: Dictionary = recipe.get("resources", {})
    for res_key in resources.keys():
        var amt = int(resources[res_key])
        if amt <= 0:
            continue
        var slot := {
            "kind": "single",
            "pid": "",
            "group_key": "",
            "members": [],
            "required": amt,
            "filled": 0,
            "fractional": 0.0,
            "consumed": [],
            "consumed_pids": {}
        }
        if str(res_key).begins_with("@"):
            var group_key = str(res_key).trim_prefix("@")
            var members = _resolve_group_members(group_key)
            slot["kind"] = "group"
            slot["group_key"] = group_key
            slot["members"] = members
        else:
            slot["pid"] = str(res_key)
        out.append(slot)
    return out

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
    if kind == "single":
        var pid = str(slot.get("pid", ""))
        if pid == "":
            return out
        return _take_single(pid, amount, priority)
    # --- @-group: greedily by the members with the "best" priority ---
    var members: Array = slot.get("members", [])
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
    var best_qid: String = str(quality_levels[quality_levels.size() - 1])
    var sign: int = -1 if priority == "best" else 1
    out.sort_custom(func(a, b):
        var a_best: int = int(CityData.city_quality_detail.get(a, {}).get(best_qid, 0))
        var b_best: int = int(CityData.city_quality_detail.get(b, {}).get(best_qid, 0))
        if a_best != b_best:
            return sign * a_best < sign * b_best
        # On a tie of the "best" stocks — we sort by the total amount.
        var a_total: int = int(CityData.city_storage.get(a, 0))
        var b_total: int = int(CityData.city_storage.get(b, 0))
        return sign * a_total < sign * b_total)
    return out

# --- INTERNAL ---
func _resolve_craft_time(recipe: Dictionary) -> float:
    var t := float(recipe.get("time", 0.0))
    if t <= 0.0:
        # The historical behaviour: time=0 → the craft every tick (1 sec).
        return 1.0
    return t

func _slot_display_key(slot: Dictionary) -> String:
    if str(slot.get("kind", "")) == "group":
        return "@" + str(slot.get("group_key", ""))
    return str(slot.get("pid", ""))
