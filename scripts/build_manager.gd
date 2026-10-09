@tool
extends Node

signal build_message(text: String)
signal build_completed(row: int, col: int, imp_id: String, target_res_id)
signal build_paused(row: int, col: int)
signal build_cancelled(row: int, col: int)
signal build_building_completed(building_id: String, build_key: String)
signal build_building_paused(build_key: String)
signal build_building_cancelled(build_key: String)
# The upgrade of a built city building to an improved version. It is emitted when
# the labour is accumulated and the building is ready to be replaced by the improved version.
# build_key — the build key; idx — the index of the building in CityData.city_built_buildings;
# upgrade_to — the id of the improved version; building_name — its human-readable name.
signal building_upgrade_completed(build_key: String, idx: int, upgrade_to: String, building_name: String)
# The claiming of the territory (buying a chunk for labour). It is emitted when the labour
# is accumulated and the chunk is ready to be joined to the Influence Ring.
signal expansion_build_completed(chunk: Array)

var active_builds: Dictionary = {} # the improvements on the map: the key "row,col"
var active_building_builds: Dictionary = {} # the building of buildings: the key "building_<index>"
var active_expansion_builds: Dictionary = {} # the claiming of the territory: the key "expansion_<index>"

# The cache of the number of active builds (improvements + buildings). It is updated on every
# addition/removal of a build, so that has_active_builds() could work in
# O(1), without scanning the dictionaries every frame (it is used in main_map._process
# for the decision to redraw the progress bar layer).
var _active_build_count: int = 0

# === Staged projects (project_manager) ===
#
# A project (a road route over hexes) is a queue of steps, each of which is
# built separately and takes exactly ONE slot in the labour pool: only the current
# step goes at the same time. The labour rate here is NOT reinvented, but
# is computed in the same _process by the same rules as for the improvements: one
# labour divided among all for the city. Otherwise a staged project would get
# its own rate on top of the general one, and the city would build faster than itself.
#
# The connection is intentionally narrow: the manager declares how many steps are going, and
# gets the ready rate (receive_labor). build_manager is not obliged to know
# about roads and aqueducts.
var project_manager: Node = null

func _ready():
    set_process(not Engine.is_editor_hint())
    _recount_active_builds()

func _process(delta):
    if Engine.is_editor_hint():
        return

    # We collect the active (not paused) builds of improvements, buildings and claims
    var active_builds_list = []
    for key in active_builds.keys():
        var data = active_builds[key]
        if data.get("status", "active") == "active":
            active_builds_list.append(data)
    for key in active_building_builds.keys():
        var data = active_building_builds[key]
        if data.get("status", "active") == "active":
            active_builds_list.append(data)
    for key in active_expansion_builds.keys():
        var data = active_expansion_builds[key]
        if data.get("status", "active") == "active":
            active_builds_list.append(data)

    # If there are no active builds — we do nothing. The steps of the staged projects
    # are also counted as builds (see project_manager below), therefore the check
    # must not cut off the labour distribution when only a project is going.
    var project_steps := _get_active_project_steps()
    if active_builds_list.is_empty() and project_steps <= 0:
        return

    # We distribute the total labour equally among the active builds
    var total_labor = CityData.get_total_labor()
    var labor_per_build = total_labor / (active_builds_list.size() + project_steps)

    var to_complete = []
    var to_complete_buildings = []
    var to_complete_expansions = []
    for data in active_builds_list:
        if CityData.ignore_build_requirements:
            # Debug: "Ignore building requirements" — ALL builds
            # (buildings, improvements, special actions, territory claiming) are instantly
            # brought to 100% in one frame. There are no exceptions: a build started
            # before the flag was enabled also completes right away — otherwise the switch
            # would not apply to everything already in the pool.
            data["progress"] = data["work_cost"]
        else:
            data["progress"] += labor_per_build * delta
        data["allocated_labor"] = labor_per_build
        if data["progress"] >= data["work_cost"]:
            if data.has("row"):
                to_complete.append(data)
            elif data.has("chunk"):
                to_complete_expansions.append(data)
            else:
                to_complete_buildings.append(data)

    for data in to_complete:
        var key = str(data["row"]) + "," + str(data["col"])
        emit_signal("build_message", tr("Completed: %s") % data["imp_name"])
        emit_signal("build_completed", data["row"], data["col"], data["imp_id"], data.get("target_res_id"))
        active_builds.erase(key)

    for data in to_complete_buildings:
        var bkey = data.get("build_key", "")
        # First we remove the entry from the active builds: the signal handlers
        # may immediately update the city panel and must see the completed state.
        active_building_builds.erase(bkey)
        _active_build_count -= 1
        if data.get("is_upgrade", false):
            # The upgrade of the building is complete — a signal for CityData, which will replace
            # the building with the improved version (and not add a new one at the end of the list).
            emit_signal("build_message", tr("Upgraded: %s") % data.get("upgrade_name", data.get("upgrade_to", "")))
            emit_signal("building_upgrade_completed", bkey, data.get("upgrade_idx", -1), data.get("upgrade_to", ""), data.get("upgrade_name", ""))
        else:
            emit_signal("build_message", tr("Built: %s") % data["building_name"])
            emit_signal("build_building_completed", data["building_id"], bkey)

    for data in to_complete_expansions:
        var ekey = data.get("build_key", "")
        emit_signal("build_message", tr("Claiming complete!"))
        emit_signal("expansion_build_completed", data["chunk"])
        active_expansion_builds.erase(ekey)

    # After the completion of the builds in _process we update the cache of the counter.
    if not to_complete.is_empty() or not to_complete_buildings.is_empty() or not to_complete_expansions.is_empty():
        _recount_active_builds()

    # The steps of the staged projects get the very same divided rate and
    # are sorted ONE PER FRAME. It is called after the distribution to its own builds,
    # because the step handler (main_map) may touch the road network and thereby
    # change the number of active projects — that does not affect the already computed rate,
    # but it will be taken into account on the next frame.
    if project_manager != null and project_steps > 0:
        project_manager.receive_labor(labor_per_build, delta,
                CityData.ignore_build_requirements)

# How many staged projects are being built now. Each takes exactly one slot
# in the labour pool: only the current step goes at the same time, the others wait in the queue.
func _get_active_project_steps() -> int:
    if project_manager == null:
        return 0
    return project_manager.get_active_step_count()

func start_build(row: int, col: int, imp_id: String, target_res_id = null,
        road_level: int = 0) -> bool:
    # On a city hex the construction of improvements is forbidden.
    var main_map_check = get_tree().root.find_child("MainMap", true, false)
    if main_map_check and row == main_map_check.city_row and col == main_map_check.city_col:
        emit_signal("build_message", tr("Cannot build on a city hex"))
        return false

    # The road (the build_road special action) is the only action applicable
    # on the hex of another town: it does not build an improvement on its hex, but
    # connects the road network of the CITY with the town (the road reaches its centre
    # at the chosen level, see road_manager.plan_road_to). Therefore the prohibitions "there is someone else's
    # town here" and "there is an influence ring here" do not concern it. It still
    # does not touch the decorative improvements.
    var is_road_action := imp_id != "" \
            and GameData.special_actions.has(imp_id) \
            and str(GameData.special_actions[imp_id].get("action_type", "")) == "road"

    # On a town hex (a small settlement) the construction is also forbidden —
    # it is a "someone else's" place, by design nothing can be built there and no
    # special actions either. At the moment (the first stage) the towns are purely
    # decorative; in the future the interaction will appear here (trade and so on).
    if main_map_check and row >= 0 and row < main_map_check.tile_data.size() \
            and col >= 0 and col < main_map_check.tile_data[row].size():
        var t_tile = main_map_check.tile_data[row][col]
        if t_tile != null and bool(t_tile.get("decorative", false)):
            emit_signal("build_message", tr("This is a decorative town improvement — it cannot be modified"))
            return false
        if t_tile != null and bool(t_tile.get("has_town", false)) and not is_road_action:
            emit_signal("build_message", tr("Another town stands here — cannot build"))
            return false
        # In the influence ring of another town it is impossible to build: around someone else's
        # settlement the fields/pastures/infrastructure are actually occupied, and
        # the player cannot "stick" their own improvement there. The rings themselves
        # are drawn by the renderer (a semi-transparent blue fill) — that gives
        # the player a visual signal even before attempting to build.
        # The rings of the player's own town are not affected (checked below).
        if t_tile != null and bool(t_tile.get("in_town_influence", false)) and not is_road_action:
            emit_signal("build_message", tr("This is inside another town's influence ring — cannot build"))
            return false

    var key = str(row) + "," + str(col)
    if active_builds.has(key):
        emit_signal("build_message", tr("Construction is already underway here"))
        return false
    # The hex may also be occupied by a STAGED project: an improvement waiting in the queue
    # "road → improvement" does not lie in active_builds, therefore the checks
    # above alone are not enough. Without it, on a hex where the improvement is not yet built,
    # it would be possible to start a second build — and two buildings would share the hex.
    if project_manager != null and project_manager.has_project_at(row, col):
        emit_signal("build_message", tr("Construction is already underway here"))
        return false

    var imp_data = GameData.improvements.get(imp_id, {})
    var imp_name = imp_data.get("name", imp_id)
    # The special actions (logging, draining swamps, etc.) are not improvements —
    # we take the name from GameData.special_actions.
    if GameData.special_actions.has(imp_id):
        imp_name = GameData.special_actions[imp_id].get("name", imp_id)

    # The labour cost depends on the terrain type and the distance to the city.
    var main_map = get_tree().root.find_child("MainMap", true, false)
    # road_level — the road level chosen by the player in the improvement build
    # preview; 0 means "not set" and then the best available
    # level is taken, the same one the panel shows by default.
    var effective_road_level := road_level
    if effective_road_level <= 0:
        effective_road_level = GameData.get_max_unlocked_road_level()
    var work_cost = 0
    if main_map and main_map.has_method("get_improvement_work_cost"):
        work_cost = main_map.get_improvement_work_cost(imp_id, row, col,
                effective_road_level)["cost"]
    else:
        work_cost = imp_data.get("work_cost", 0)

    # The construction now requires labour, and not food. With
    # "Ignore building requirements" enabled the improvements are built instantly.
    # The road is checked NOT by the price, but by the PLAN. Previously a zero price meant
    # "there is no route" (the hex is cut off by water, the town cannot be reached), and without this
    # check the build would complete instantly. A zero price for a road is
    # a legitimate state (a level with work_cost = 0), and such a road must not be
    # declared impossible. The sign "the road cannot be built" is !ok of
    # the plan, and not the price.
    if is_road_action and main_map != null and main_map.has_method("get_road_plan") \
            and not bool(main_map.get_road_plan(row, col).get("ok", false)):
        # The reason is taken straight from the plan: for a town it is usually "there is no explored
        # path", and saying "there is no land path" would be wrong — there is
        # a land path to the town, the player just has not explored it yet.
        var reason := str(main_map.get_road_plan(row, col).get("reason", ""))
        if not reason.is_empty():
            # The reasons from the plan start with a capital letter — after a colon in
            # a sentence it looks like an error.
            reason = reason.substr(0, 1).to_lower() + reason.substr(1)
        emit_signal("build_message", tr("Cannot build a road here: %s") % reason)
        return false

    # A road is not one build for the whole route, but a STAGED project: a queue
    # of segments, each is built separately (project_manager). The launch is delegated to
    # main_map: it owns both the road planner (road_manager) and the project
    # manager, therefore it assembles the steps itself. The entry point stays the same
    # (start_build), so that the panels and other callers do not have to know
    # which special actions are staged.
    if is_road_action:
        if main_map == null or not main_map.has_method("start_road_project"):
            emit_signal("build_message", tr("Failed to build the road"))
            return false
        return main_map.start_road_project(row, col, effective_road_level)

    # The improvement that requires a road goes into the CHAIN "road →
    # improvement": one staged project and one slot, first the road segments,
    # the last step — the build itself (main_map.start_improvement_road_project).
    # The improvements without a road (the hex is already connected, no_road, there is no
    # path) remain an ordinary build below — for them the analysis gives no new segments.
    var is_special_action: bool = GameData.special_actions.has(imp_id)
    if not is_special_action and main_map != null \
            and main_map.has_method("start_improvement_road_project") \
            and main_map.has_method("get_road_cost_breakdown_for_improvement"):
        var road_bd: Dictionary = main_map.get_road_cost_breakdown_for_improvement(
                row, col, effective_road_level)
        if bool(road_bd.get("ok", false)):
            return main_map.start_improvement_road_project(row, col, imp_id, imp_name,
                    target_res_id, effective_road_level)

    if work_cost <= 0 or CityData.ignore_build_requirements:
        emit_signal("build_message", tr("Built instantly: %s") % imp_name)
        emit_signal("build_completed", row, col, imp_id, target_res_id)
        return true

    # The general limit of simultaneous builds (buildings + improvements) equals the number of citizens
    if get_total_active_builds() >= CityData.total_population:
        emit_signal("build_message", tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)") % CityData.total_population)
        return false

    active_builds[key] = {
        "progress": 0.0,
        "work_cost": work_cost,
        "imp_id": imp_id,
        "target_res_id": target_res_id,
        "imp_name": imp_name,
        "row": row,
        "col": col,
        "status": "active",
        "allocated_labor": 0.0,
    }
    _active_build_count += 1

    emit_signal("build_message", tr("Construction of %s started (%.0f work)") % [imp_name, work_cost])
    return true

# Starts the claiming of a chunk of territory for labour. The labour accumulates over time
# through the common labour pool (like the building of buildings/improvements). When the
# labour is accumulated, the signal expansion_build_completed(chunk) is emitted,
# and expansion_manager joins the chunk to the Influence Ring.
func start_expansion_build(chunk: Array, work_cost: int, money_cost: int = 0) -> bool:
    if chunk.is_empty() or work_cost <= 0:
        return false

    # With "Ignore building requirements" enabled the claiming does not wait
    # for labour, and the limit of simultaneous builds does not apply: the chunk is joined
    # to the Influence Ring by the same signal as on a normal completion.
    if CityData.ignore_build_requirements:
        emit_signal("build_message", tr("Claiming complete instantly!"))
        emit_signal("expansion_build_completed", chunk)
        return true

    # The general limit of simultaneous builds (buildings + improvements + claims)
    # equals the number of citizens.
    if get_total_active_builds() >= CityData.total_population:
        emit_signal("build_message", tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)") % CityData.total_population)
        return false

    var build_key = "expansion_" + str(Time.get_ticks_usec())
    active_expansion_builds[build_key] = {
        "progress": 0.0,
        "work_cost": work_cost,
        # The price in coins, written off at the start. It is stored so that the cancel
        # could return it (cancel_expansion) — the money left the treasury BEFORE
        # the labour began, and without this number there is nothing to return.
        "money_cost": money_cost,
        "chunk": chunk,
        "build_key": build_key,
        "status": "active",
        "allocated_labor": 0.0
    }
    _active_build_count += 1

    emit_signal("build_message", tr("Claiming land started (%d work)") % work_cost)
    return true

func start_building_build(building_id: String) -> String:
    var work_cost = 0
    var building_name = building_id
    for b in GameData.buildings:
        if b["id"] == building_id:
            work_cost = b.get("work_cost", 0)
            building_name = b.get("name", building_id)
            break

    var additional_req_check = CityData.check_building_additional_req(building_id)
    if not additional_req_check["ok"]:
        emit_signal("build_message", additional_req_check["reason"])
        return ""

    # The technology modifiers (target = "construction_cost", see data/modifiers.json)
    # reduce the cost of building buildings just as they do for the improvements.
    if work_cost > 0:
        work_cost = int(ceil(float(work_cost) * MapHelpers.get_construction_cost_mult()))

    # With "Ignore building requirements" enabled the building is built
    # instantly — we complete the build right away (the CityData.ignore_build_requirements flag).
    if work_cost <= 0 or CityData.ignore_build_requirements:
        emit_signal("build_building_completed", building_id, "")
        return ""

    # The general limit of simultaneous builds (buildings + improvements) equals the number of citizens
    if get_total_active_builds() >= CityData.total_population:
        emit_signal("build_message", tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)") % CityData.total_population)
        return ""

    var build_key = "building_" + str(Time.get_ticks_usec())
    active_building_builds[build_key] = {
        "progress": 0.0,
        "work_cost": work_cost,
        "building_id": building_id,
        "building_name": building_name,
        "build_key": build_key,
        "status": "active",
        "allocated_labor": 0.0
    }
    _active_build_count += 1

    emit_signal("build_message", tr("Construction of %s started (%.0f work)") % [building_name, work_cost])
    return build_key

# Starts the upgrade of an already built city building (idx — the index in
# CityData.city_built_buildings, from_id — the current id of the building) to its improved
# version upgrade_to. It returns the build_key of the build, or "" on failure.
# The upgrade is an ordinary build in the common labour pool: it participates in the common
# limit of simultaneous builds and in the equal distribution of labour among the builds.
func start_building_upgrade(idx: int, from_id: String, upgrade_to: String) -> String:
    # The upgrade can only be started for an existing building of that id.
    if idx < 0 or idx >= CityData.city_built_buildings.size():
        return ""
    if CityData.city_built_buildings[idx].get("id", "") != from_id:
        return ""

    # The upgrade of this same building is already going.
    for key in active_building_builds.keys():
        var data = active_building_builds[key]
        if data.get("is_upgrade", false) and data.get("upgrade_idx", -1) == idx:
            emit_signal("build_message", tr("This building is already being upgraded"))
            return ""

    var work_cost = 0
    var upgrade_name = upgrade_to
    for b in GameData.buildings:
        if b["id"] == upgrade_to:
            work_cost = b.get("work_cost", 0)
            upgrade_name = b.get("name", upgrade_to)
            break

    var additional_req_check = CityData.check_building_additional_req(upgrade_to)
    if not additional_req_check["ok"]:
        emit_signal("build_message", additional_req_check["reason"])
        return ""

    # The technology modifiers (target = "construction_cost", see data/modifiers.json)
    # reduce the cost of the upgrade just as they reduce the cost of a new build.
    if work_cost > 0:
        work_cost = int(ceil(float(work_cost) * MapHelpers.get_construction_cost_mult()))

    # With a zero cost of the upgrade or the debug flag enabled we complete
    # instantly — with the building_upgrade_completed signal.
    if work_cost <= 0 or CityData.ignore_build_requirements:
        emit_signal("building_upgrade_completed", "", idx, upgrade_to, upgrade_name)
        return ""

    # The general limit of simultaneous builds (buildings + improvements + upgrades) equals
    # the number of citizens.
    if get_total_active_builds() >= CityData.total_population:
        emit_signal("build_message", tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)") % CityData.total_population)
        return ""

    var build_key = "building_upgrade_" + str(idx) + "_" + str(Time.get_ticks_usec())
    active_building_builds[build_key] = {
        "progress": 0.0,
        "work_cost": work_cost,
        "building_id": from_id,
        "building_name": from_id,
        "build_key": build_key,
        "status": "active",
        "allocated_labor": 0.0,
        "is_upgrade": true,
        "upgrade_idx": idx,
        "upgrade_to": upgrade_to,
        "upgrade_name": upgrade_name
    }
    _active_build_count += 1

    emit_signal("build_message", tr("Upgrade of %s started (%.0f work)") % [upgrade_name, work_cost])
    return build_key

# Returns the data of the ongoing upgrade of a building by its index in the city
# (an empty dictionary if the upgrade is not going). It is used by the building panel for
# showing the progress of the improvement and by the "Upgrade" button to block a repeat.
func get_building_upgrade_by_index(idx: int) -> Dictionary:
    for key in active_building_builds.keys():
        var data = active_building_builds[key]
        if data.get("is_upgrade", false) and data.get("upgrade_idx", -1) == idx:
            return data
    return {}

func pause_build(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return false

    var data = active_builds[key]
    if data.get("status", "active") == "paused":
        return false

    data["status"] = "paused"
    data["allocated_labor"] = 0.0
    emit_signal("build_paused", row, col)
    emit_signal("build_message", tr("Construction of %s paused") % data["imp_name"])
    return true

func resume_build(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return false

    var data = active_builds[key]
    if data.get("status", "active") == "active":
        return false

    data["status"] = "active"
    emit_signal("build_message", tr("Construction of %s resumed") % data["imp_name"])
    return true

# Cancels the claiming of the territory by its build_key. The labour already invested
# in the chunk is lost, and the coins written off at the start are RETURNED: the money was paid for
# joining the chunk to the Influence Ring, and it did not happen. The already done so is
# expansion_manager.handle_action, when the build could not start — there
# the refund is mandatory, so that the price does not disappear. The agreement "the cancel returns
# the starting costs, but not the labour" is the same as for the scouting.
func cancel_expansion(build_key: String) -> bool:
    if not active_expansion_builds.has(build_key):
        return false
    var data: Dictionary = active_expansion_builds[build_key]
    active_expansion_builds.erase(build_key)
    var money_cost := int(data.get("money_cost", 0))
    if money_cost > 0 and not CityData.ignore_build_requirements:
        CityData.add_treasury(money_cost)
        # The refund goes to THE SAME expense source as a negative record: over the display
        # window the total agrees with the actual result (paid Y → got Y
        # back → 0). A separate "income" would not suit the hierarchical breakdown
        # of the treasury — the same reason as in expansion_manager.handle_action.
        CityData.record_treasury_expense(GameData.SRC_CLAIMING, -money_cost)
    emit_signal("build_message", tr("Claiming cancelled. Spent %.0f/%d work")
            % [float(data.get("progress", 0.0)), int(data.get("work_cost", 0))])
    _recount_active_builds()
    return true

# Cancels the claiming by the hex (row, col) — it takes the first hex of the claimed chunk,
# exactly as get_expansion_progress_for_hex. In this way the button in the panel does not depend on
# the format of the key of the entry in the internal dictionary.
func cancel_expansion_at_hex(row: int, col: int) -> bool:
    var data := get_expansion_progress_for_hex(row, col)
    if data.is_empty():
        return false
    return cancel_expansion(str(data.get("build_key", "")))

func cancel_build(row: int, col: int):
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return

    var data = active_builds[key]
    var imp_name = data["imp_name"]
    var work_done = data["progress"]
    var work_total = data["work_cost"]

    active_builds.erase(key)
    _active_build_count -= 1
    emit_signal("build_cancelled", row, col)
    emit_signal("build_message", tr("Construction of %s cancelled. Spent %.0f/%d work") % [imp_name, work_done, work_total])

func pause_building_build(build_key: String) -> bool:
    if not active_building_builds.has(build_key):
        return false

    var data = active_building_builds[build_key]
    if data.get("status", "active") == "paused":
        return false

    data["status"] = "paused"
    data["allocated_labor"] = 0.0
    emit_signal("build_building_paused", build_key)
    emit_signal("build_message", tr("Construction of %s paused") % data["building_name"])
    return true

func resume_building_build(build_key: String) -> bool:
    if not active_building_builds.has(build_key):
        return false

    var data = active_building_builds[build_key]
    if data.get("status", "active") == "active":
        return false

    data["status"] = "active"
    emit_signal("build_message", tr("Construction of %s resumed") % data["building_name"])
    return true

func cancel_building_build(build_key: String):
    if not active_building_builds.has(build_key):
        return

    var data = active_building_builds[build_key]
    var building_name = data["building_name"]
    var work_done = data["progress"]
    var work_total = data["work_cost"]

    active_building_builds.erase(build_key)
    _active_build_count -= 1
    emit_signal("build_building_cancelled", build_key)
    emit_signal("build_message", tr("Construction of %s cancelled. Spent %.0f/%d work") % [building_name, work_done, work_total])

# Returns the total number of active builds (improvements + buildings + claims
# + the current steps of the staged projects). A project takes one slot, and not
# per hex: only one of its segments is built at the same time.
func get_total_active_builds() -> int:
    return active_builds.size() + active_building_builds.size() \
        + active_expansion_builds.size() + _get_active_project_steps()

# Returns true if there is at least one active build (an improvement, a building
# or a territory claim). It works in O(1) via the cached counter —
# it is used in main_map._process to decide whether the progress bar layer
# needs to be redrawn every frame. The project steps are not in the counter: they are
# polled every frame by project_manager, and not by the build_manager cache.
func has_active_builds() -> bool:
    return _active_build_count > 0 or _get_active_project_steps() > 0

# Recalculates the cache of the number of active builds by the actual size of the dictionaries.
# It is called when restoring the builds from the save and in _ready.
func _recount_active_builds():
    _active_build_count = active_builds.size() + active_building_builds.size() + active_expansion_builds.size()

func is_building(row: int, col: int) -> bool:
    return active_builds.has(str(row) + "," + str(col))

func is_building_paused(row: int, col: int) -> bool:
    var key = str(row) + "," + str(col)
    if not active_builds.has(key):
        return false
    return active_builds[key].get("status", "active") == "paused"

func get_progress(row: int, col: int) -> Dictionary:
    var key = str(row) + "," + str(col)
    if active_builds.has(key):
        return active_builds[key]
    return {}

# Returns the data of the territory claim build, if the hex (row, col) is the FIRST
# hex of the claimed chunk. It is used for drawing the progress bar of the claim
# ONLY on the selected hex (and not on all the hexes of the chunk).
func get_expansion_progress_for_hex(row: int, col: int) -> Dictionary:
    for key in active_expansion_builds.keys():
        var data = active_expansion_builds[key]
        var chunk = data.get("chunk", [])
        if chunk.is_empty():
            continue
        var first_hex = chunk[0]
        if first_hex.row == row and first_hex.col == col:
            return data
    return {}

func remove_build(row: int, col: int):
    var key = str(row) + "," + str(col)
    if active_builds.erase(key):
        _active_build_count -= 1

# Restores the improvement builds from the save.
func restore_builds(data: Dictionary):
    active_builds.clear()
    if data.is_empty():
        _recount_active_builds()
        return
    for key in data.keys():
        var build_data = data[key]
        if not (build_data is Dictionary):
            continue
        # We validate: the build must have the coordinates and imp_id
        if not build_data.has("row") or not build_data.has("col") or not build_data.has("imp_id"):
            continue
        active_builds[String(key)] = {
            "progress": float(build_data.get("progress", 0.0)),
            "work_cost": float(build_data.get("work_cost", 1.0)),
            "imp_id": String(build_data.get("imp_id", "")),
            "target_res_id": build_data.get("target_res_id"),
            "imp_name": String(build_data.get("imp_name", build_data.get("imp_id", ""))),
            "row": int(build_data.get("row", 0)),
            "col": int(build_data.get("col", 0)),
            "status": String(build_data.get("status", "active")),
            "allocated_labor": float(build_data.get("allocated_labor", 0.0))
        }
    _recount_active_builds()

# Restores the territory claim builds from the save.
func restore_expansion_builds(data: Dictionary):
    active_expansion_builds.clear()
    if data.is_empty():
        _recount_active_builds()
        return
    for key in data.keys():
        var build_data = data[key]
        if not (build_data is Dictionary):
            continue
        # We validate: the claim build must have chunk and work_cost
        if not build_data.has("chunk") or not build_data.has("work_cost"):
            continue
        active_expansion_builds[String(key)] = {
            "progress": float(build_data.get("progress", 0.0)),
            "work_cost": float(build_data.get("work_cost", 1.0)),
            "chunk": build_data.get("chunk", []),
            "build_key": String(build_data.get("build_key", key)),
            "status": String(build_data.get("status", "active")),
            "allocated_labor": float(build_data.get("allocated_labor", 0.0))
        }
    _recount_active_builds()

# Restores the building builds from the save.
func restore_building_builds(data: Dictionary):
    active_building_builds.clear()
    if data.is_empty():
        _recount_active_builds()
        return
    for key in data.keys():
        var build_data = data[key]
        if not (build_data is Dictionary):
            continue
        # We validate: the build must have building_id
        if not build_data.has("building_id"):
            continue
        active_building_builds[String(key)] = {
            "progress": float(build_data.get("progress", 0.0)),
            "work_cost": float(build_data.get("work_cost", 1.0)),
            "building_id": String(build_data.get("building_id", "")),
            "building_name": String(build_data.get("building_name", build_data.get("building_id", ""))),
            "build_key": String(build_data.get("build_key", key)),
            "status": String(build_data.get("status", "active")),
            "allocated_labor": float(build_data.get("allocated_labor", 0.0)),
            # The building upgrade fields (for ordinary builds is_upgrade == false).
            "is_upgrade": bool(build_data.get("is_upgrade", false)),
            "upgrade_idx": int(build_data.get("upgrade_idx", -1)),
            "upgrade_to": String(build_data.get("upgrade_to", "")),
            "upgrade_name": String(build_data.get("upgrade_name", build_data.get("building_name", "")))
        }
    _recount_active_builds()

func is_building_build_active(build_key: String) -> bool:
    return active_building_builds.has(build_key)

func is_building_build_paused(build_key: String) -> bool:
    if not active_building_builds.has(build_key):
        return false
    return active_building_builds[build_key].get("status", "active") == "paused"

func get_building_build_progress(build_key: String) -> Dictionary:
    if active_building_builds.has(build_key):
        return active_building_builds[build_key]
    return {}
