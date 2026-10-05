# project_manager.gd
# A universal STAGED construction system.
#
# A project is an ordered queue of STEPS, and they are built one by one: while
# the current step is not finished, the next one does not start. The manager knows
# nothing about roads or aqueducts: it can only turn the queue, drip labour into
# the current step and report events. What a step means and what happens
# on its completion is decided by the project owner (main_map) via the
# step_completed signal. Therefore a new kind of project (for example, an aqueduct
# from a mountain to the city) is a new step handler, and not an edit of this file.
#
# The labour is NOT invented here: the rate is given out by build_manager (see
# receive_labor), because it is the same one for all the builds of the city — the invariant
# "the total amount of work per unit of time equals the size of the city" lives
# in exactly one place.
#
# The manager intentionally does NOT refer to autoloads (CityData): the debug flag
# "Ignore building requirements" comes as an argument. Thanks to
# this the file can be loaded in a headless test via load() — such a workaround
# is described in the header of tests/test_road_building.gd.
extends Node

## The project has started: the first step has been set to work.
signal project_started(project_id: String, kind: String, title: String)
## A step is finished. The owner applies its effect to the world (for example, lays
## a road segment). The signal is sent BEFORE the next step starts — so the order
## "built the segment → showed it on the map → started the next one" is guaranteed.
signal step_completed(project_id: String, kind: String, step: Dictionary)
## The next step has started. On its hex a new progress bar is shown.
signal step_started(project_id: String, kind: String, step: Dictionary)
## The project queue is empty — everything is built.
signal project_completed(project_id: String, kind: String, meta: Dictionary)
## The project was cancelled by the player: what is already built stays, what is not finished — does not.
signal project_cancelled(project_id: String, kind: String, meta: Dictionary)
## A message for the HUD. A separate signal (and not a common one with build_manager), so that
## the manager does not drag the interface along with it.

# The active projects: project_id -> project record.
var projects: Dictionary = {}

# A counter for the keys. The key is a string — it goes into the save as a dictionary key,
# and not as an index, therefore it survives the reordering of the projects on loading.
var _next_id: int = 0

## Puts the project in the queue. It returns project_id, or "" — if the queue
## is empty (there is nothing to build).
##
## steps — an array of steps, each:
##   {
##     "label": String,                 # the step label (HUD, cancel)
##     "work_cost": float,              # how much labour the step needs
##     "progress": float,               # the accumulated labour (filled in here)
##     "status": "active",
##     "allocated_labor": float,
##     "hex": {"row": int, "col": int}, # the hex ABOVE which the progress bar is drawn
##     "ghost": Dictionary,             # the ghost segments of this step
##     "data": Dictionary,              # the payload for the handler
##   }
## meta — the project data needed by the owner on completion (for example, whether
## the target is a town). The steps must be a non-empty array of dictionaries.
func start_project(
        kind: String,
        title: String,
        target_row: int,
        target_col: int,
        steps: Array,
        meta: Dictionary = {}) -> String:
    if steps.is_empty():
        return ""
    _next_id += 1
    var project_id := "%s_%d" % [kind, _next_id]
    for step in steps:
        step["progress"] = 0.0
        step["status"] = "active"
        step["allocated_labor"] = 0.0
    projects[project_id] = {
        "id": project_id,
        "kind": kind,
        "title": title,
        "target_row": target_row,
        "target_col": target_col,
        "steps": steps,
        "step_index": 0,
        "status": "active",
        "meta": meta
    }
    project_started.emit(project_id, kind, title)
    step_started.emit(project_id, kind, steps[0])
    return project_id

## Cancels the project. The already built steps do not go anywhere — the road
## cancel does not roll back the laid part, just like the cancel of an improvement build.
func cancel_project(project_id: String) -> bool:
    if not projects.has(project_id):
        return false
    var project: Dictionary = projects[project_id]
    projects.erase(project_id)
    project_cancelled.emit(project_id, str(project.get("kind", "")),
            project.get("meta", {}))
    return true

## Cancels the project whose target is the hex (row, col).
func cancel_project_at(row: int, col: int) -> bool:
    var project := get_project_at(row, col)
    if project.is_empty():
        return false
    return cancel_project(str(project.get("id", "")))

## Cancels the project OCCUPYING the hex (row, col) — any of its hexes, not only
## the target. The counterpart of get_project_at_hex: it can be interrupted from a hex that the
## player sees, and not only from the one that was pressed at the start.
func cancel_project_at_hex(row: int, col: int) -> bool:
    var project := get_project_at_hex(row, col)
    if project.is_empty():
        return false
    return cancel_project(str(project.get("id", "")))

func get_project(project_id: String) -> Dictionary:
    return projects.get(project_id, {})

## Whether a project is going to this hex right now (by the TARGET hex). The control panel
## asks this in order not to show "Build road" again on a hex
## to which the road is already being built.
func has_project_at(row: int, col: int) -> bool:
    return not get_project_at(row, col).is_empty()

func get_project_at(row: int, col: int) -> Dictionary:
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        if int(project.get("target_row", -1)) == row \
                and int(project.get("target_col", -1)) == col:
            return project
    return {}

## The project OCCUPYING this hex — any of its steps, and not only the target.
##
## Why two different questions. has_project_at() (by the target) is needed in order to hide
## the "Build road" button on a hex to which the road is ALREADY going. But the
## cancel button must appear on ANY hex of the project: the player sees the road as
## a ghost on a dozen hexes and the progress bar on the current segment, and clicks
## where they see the construction. A button hidden at the far end of the route (possibly
## off-screen) cannot be found — that was the original bug.
##
## The hex of a step is known from two places, and both are needed:
##   · "hex" — the hex on which the progress bar is drawn (the segment that
##     joins the network);
##   · "data".from / "data".to — both ends of the segment. The from hex is already joined
##     by the previous step, but the player sees the road on it, and will click
##     exactly on it.
func get_project_at_hex(row: int, col: int) -> Dictionary:
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        if _project_touches_hex(project, row, col):
            return project
    return {}

func has_project_at_hex(row: int, col: int) -> bool:
    return not get_project_at_hex(row, col).is_empty()

## Whether the hex belongs to the project. The target is checked separately from the steps: in
## an already started project the target equals the hex of the last step, but it is not
## safe to rely on that equality — the order of the steps has already been changed and
## will be changed again.
func _project_touches_hex(project: Dictionary, row: int, col: int) -> bool:
    if int(project.get("target_row", -1)) == row \
            and int(project.get("target_col", -1)) == col:
        return true
    var steps: Array = project.get("steps", [])
    # We also deliberately count the already built steps: they have become a real
    # road on the map, and the player clicks on it — the cancel must work.
    for step in steps:
        var bar_hex: Dictionary = step.get("hex", {})
        if int(bar_hex.get("row", -1)) == row and int(bar_hex.get("col", -1)) == col:
            return true
        var data: Dictionary = step.get("data", {})
        for key in ["from", "to"]:
            var h: Dictionary = data.get(key, {})
            if int(h.get("row", -1)) == row and int(h.get("col", -1)) == col:
                return true
    return false

func has_active_projects() -> bool:
    return not projects.is_empty()

## How many "builds" are going now. Each active project takes exactly ONE
## slot in the labour pool: only the current step is built at the same time. This value
## build_manager adds to its own builds, so that the labour rate reaches
## the projects by the same rule as the improvements, buildings and claim.
func get_active_step_count() -> int:
    return projects.size()



## Drips labour into the current step of each active project. It is called by
## build_manager — the labor_per_step rate is the same for all and is already divided.
##
## instant — the debug "Ignore building requirements": the queue
## is fully worked through in one frame, exactly like ordinary builds. The flag is passed
## as an argument, and is not read from CityData, so that the file stays free of
## autoloads (see the header).
func receive_labor(labor_per_step: float, delta: float, instant: bool = false) -> void:
    if projects.is_empty():
        return
    # We copy the keys: the signal emits can change projects (the project cancellation
    # from the step handler), and the iteration over the dictionary would then behave unpredictably.
    for project_id in projects.keys():
        if not projects.has(project_id):
            continue
        var project: Dictionary = projects[project_id]
        if str(project.get("status", "active")) != "active":
            continue
        _advance(project, labor_per_step, delta, instant)

## The progress of the current step on the hex (row, col) — for drawing the progress bar.
## An empty dictionary if nothing is being built on the hex right now.
func get_step_progress_at(row: int, col: int) -> Dictionary:
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        var step := _current_step(project)
        if step.is_empty():
            continue
        var hex: Dictionary = step.get("hex", {})
        if int(hex.get("row", -1)) == row and int(hex.get("col", -1)) == col:
            return {
                "project_id": project_id,
                "kind": str(project.get("kind", "")),
                # The type of the STEP, and not of the project: in the "road → improvement" chain the steps
                # are different, and the progress bar layer paints the improvement step in yellow
                # (the improvement build colour), and the road segment — in blue.
                "step_type": str(step.get("data", {}).get("step_type", "")),
                "title": str(project.get("title", "")),
                "label": str(step.get("label", "")),
                "progress": float(step.get("progress", 0.0)),
                "work_cost": float(step.get("work_cost", 0.0)),
                "step_index": int(project.get("step_index", 0)),
                "steps_left": _steps_left(project),
            }
    return {}

## The project ghosts: the union of the segments of ALL the not yet built steps of all
## active projects. It is exactly this set that draws the route on the map while
## the construction is going: the built segment disappears from the ghost by itself, because its
## step has left the queue.
func get_pending_ghost_segments() -> Dictionary:
    var ghost: Dictionary = {}
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        var steps: Array = project.get("steps", [])
        for i in range(int(project.get("step_index", 0)), steps.size()):
            for key in steps[i].get("ghost", {}).keys():
                ghost[key] = true
    return ghost

## The project data for the save. The road segments, as always, are not written:
## the step queue is saved, and the network is recalculated from the hex flags.
func serialize_projects() -> Dictionary:
    var out: Dictionary = {}
    for project_id in projects.keys():
        out[project_id] = (projects[project_id] as Dictionary).duplicate(true)
    return out

## Restores the projects from the save. An empty dictionary — a normal new game.
func restore_projects(data: Dictionary) -> void:
    projects.clear()
    if data.is_empty():
        return
    for project_id in data.keys():
        var project = data[project_id]
        if not (project is Dictionary):
            continue
        var steps: Array = project.get("steps", [])
        # Without steps there is no reason to restore the project, and without kind there is
        # nothing to determine who will handle its steps.
        if steps.is_empty() or str(project.get("kind", "")) == "":
            continue
        projects[String(project_id)] = project.duplicate(true)
        # The counter continues from the maximum already occupied number, so that
        # a new project does not get a key that coincides with the restored one.
        var suffix := String(project_id).rfind("_")
        if suffix >= 0:
            _next_id = maxi(_next_id, int(String(project_id).substr(suffix + 1)))
    # We do NOT emit the signals on restoring: the world is already restored as a whole, and
    # the owner will redraw the ghosts itself based on the resulting queue state.

# -------------------------------------------------------
# Internal
# -------------------------------------------------------

func _current_step(project: Dictionary) -> Dictionary:
    var steps: Array = project.get("steps", [])
    var index := int(project.get("step_index", 0))
    if index < 0 or index >= steps.size():
        return {}
    return steps[index]

func _steps_left(project: Dictionary) -> int:
    var steps: Array = project.get("steps", [])
    return maxi(0, steps.size() - int(project.get("step_index", 0)))

# Drips labour into the current step and, if it has filled up, finishes it.
func _advance(project: Dictionary, labor_per_step: float, delta: float,
        instant: bool) -> void:
    var step := _current_step(project)
    if step.is_empty():
        return
    if instant:
        step["progress"] = float(step.get("work_cost", 0.0))
    else:
        step["progress"] = float(step.get("progress", 0.0)) + labor_per_step * delta
    step["allocated_labor"] = labor_per_step
    if float(step["progress"]) < float(step.get("work_cost", 0.0)):
        return
    # There may be many steps in the queue, and only one frame. Without the debug flag, exactly one
    # step is finished per frame — otherwise the staged nature would not be visible.
    while true:
        _complete_current_step(project)
        if not instant or not projects.has(str(project.get("id", ""))):
            return
        var next_step := _current_step(project)
        if next_step.is_empty():
            return
        next_step["progress"] = float(next_step.get("work_cost", 0.0))

# Finishes the current step and shifts the queue. When the last step is
# completed, the project is thrown out of projects and project_completed is emitted.
func _complete_current_step(project: Dictionary) -> void:
    var project_id := str(project.get("id", ""))
    var kind := str(project.get("kind", ""))
    var steps: Array = project.get("steps", [])
    var index := int(project.get("step_index", 0))
    if index < 0 or index >= steps.size():
        return
    var step: Dictionary = steps[index]
    project["step_index"] = index + 1
    # The order of the emits matters: first the owner applies the effect of the step (the segment
    # of the road appears on the map), and only then the next step starts with its
    # new progress bar.
    step_completed.emit(project_id, kind, step)
    if project_id in projects and int(project["step_index"]) < steps.size():
        step_started.emit(project_id, kind, steps[int(project["step_index"])])
        return
    if project_id in projects:
        var meta: Dictionary = project.get("meta", {})
        projects.erase(project_id)
        project_completed.emit(project_id, kind, meta)
