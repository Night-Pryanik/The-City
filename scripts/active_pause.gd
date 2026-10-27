# THE ACTIVE PAUSE — the simulation is stopped, but the interface lives.
#
# The ordinary pause menu stops the simulation AND takes the interface away with
# it. Here the tree is paused in exactly the same way, but the nodes of the
# interface are switched to PROCESS_MODE_ALWAYS: the player keeps looking at the
# city and keeps making decisions. Only the tick of the simulation stops.
#
# The actions are not executed on the click — they are put into the queue and are
# performed on the resume. Nothing is paid, nothing is written off and nothing is
# reserved at the moment of the click, therefore the cancellation needs no
# refund: the costs of a cancelled action were never spent.
#
# The one-shot protection is built into the existing guards of the actions, not
# into a separate check: a hex with a waiting action is refused exactly like a hex
# with a build under way (build_manager.start_build). The gather of the wild
# berries therefore cannot be queued twice and then started twice on the resume —
# neither by a second click, nor through a second way into the same execution
# point.
extends Node

const UI_THEME = preload("res://scripts/ui_theme.gd")

## The mode is switched on or off.
signal active_changed(active: bool)
## A record is added to the queue or removed from it.
signal queue_changed()

# A thin caution frame around the window. It is the only constant indication that
# the simulation is stopped: the buttons look exactly as usual, and the actions
# look as though they had already started. The frame means a caution, so it is the
# blend of the warning and the loss colours of the palette.
const BORDER_WIDTH := 2.0

static func border_color() -> Color:
    var caution := UI_THEME.color("warning").lerp(UI_THEME.color("expense"), 0.35)
    caution.a = 0.9
    return caution

# Everything the player can click through while the simulation is stopped. The
# map itself is NOT in the list: its _process IS the simulation, and it has to
# keep standing still. The nodes of the interface below have no _process that
# touches the state of the world — their per-frame methods only redraw the
# tooltips and the progress bars.
const UI_NODES := [
    "ControlPanel", "CityUI", "TownUI", "HUD", "InputHandler", "TopRightLayer",
]

var main_map: Node = null

var _queue: Array = []
var _next_id: int = 0
var _active: bool = false

var _border_layer: CanvasLayer = null
var _border: Control = null


func setup(map: Node) -> void:
    main_map = map
    # The tick below must survive the pause of the tree — see _process.
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(false)
    _build_border()


# While the mode is on, main_map._process does not run — it IS the simulation.
# With it stops the edge scrolling and the timer of the tooltip, both of which
# live in InputHandler.handle_process. The player must be able to scroll the map
# and to read the hexes under the cursor while the world is stopped, therefore
# this one tick is forwarded from here. Everything else stays frozen.
func _process(delta: float) -> void:
    if main_map == null:
        return
    var handler = main_map.get_node_or_null("InputHandler")
    if handler != null and handler.has_method("handle_process"):
        handler.handle_process(delta)


# --- THE MODE ---

func is_active() -> bool:
    return _active


# THE SINGLE TOGGLE of the mode. Neither the button in the HUD nor the space bar
# differs from the other: each of them does exactly this one thing and nothing
# else — they do not close the windows and do not open the pause menu.
func set_active(on: bool) -> void:
    if _active == on:
        return
    _active = on
    if not on:
        # The queue is performed BEFORE the resume of the simulation: the tree is
        # still paused here, so the actions start in the very same moment as the
        # world does. _active is already false, therefore the execution points do
        # not intercept the calls of the flush a second time.
        _flush()
    set_process(on)
    _apply_ui_process_mode(on)
    _set_border_visible(on)
    # The owner of the flag recomputes it from this mode AND from the pause menu.
    if main_map != null and main_map.has_method("apply_pause_state"):
        main_map.apply_pause_state()
    active_changed.emit(on)


# --- THE QUEUE ---

# Cuts off the execution of the action while the pause is on. The record goes
# into the queue and is performed on the resume. Returns true — the caller must
# return its usual "done" value and must not execute anything itself.
#
# The record:
#   key        — the identity of the action for the one-shot protection
#   subject    — what the action is about (the id of the building, the index of
#                the upgrade, the id of the technology)
#   label      — the name of the action for the messages and the cancel button
#   execute    — the callable of the real execution (without any arguments)
#   row, col   — the hex of the empty progress bar (-1 when the action has no
#                place on the map)
#   bar_color  — the colour of the bar of that kind of action
#   bar_offset — the vertical offset of the bar, the same as the one of the real bar
func intercept(record: Dictionary) -> bool:
    if not _active:
        return false
    _next_id += 1
    var rec := record.duplicate()
    rec["id"] = _next_id
    rec["row"] = int(rec.get("row", -1))
    rec["col"] = int(rec.get("col", -1))
    _queue.append(rec)
    _notify_queue_changed()
    return true


func count() -> int:
    return _queue.size()


func is_empty() -> bool:
    return _queue.is_empty()


func has_pending_key(key: String) -> bool:
    if key.is_empty():
        return false
    for rec in _queue:
        if str(rec.get("key", "")) == key:
            return true
    return false


# The record standing on the hex, or an empty dictionary.
func get_pending_at(row: int, col: int) -> Dictionary:
    if row < 0 or col < 0:
        return {}
    for rec in _queue:
        if int(rec.get("row", -1)) == row and int(rec.get("col", -1)) == col:
            return rec
    return {}


func has_pending_at(row: int, col: int) -> bool:
    return not get_pending_at(row, col).is_empty()


# The record whose key begins with prefix, or an empty dictionary. The actions
# without a place on the map are keyed by their kind: "building:bakery",
# "upgrade:3", "research". It lets the interface turn the button that would start
# the action into the button that cancels it.
func get_pending_by_prefix(prefix: String) -> Dictionary:
    for rec in _queue:
        if str(rec.get("key", "")).begins_with(prefix):
            return rec
    return {}


# The names of the waiting actions, in the order of their queueing.
func labels() -> Array:
    var out: Array = []
    for rec in _queue:
        out.append(str(rec.get("label", "")))
    return out


# The removal from the queue. There is no refund here and none is needed: the
# costs of a queued action were never spent — the action never left the queue,
# therefore the treasury and the storage of the city are exactly as they were
# before the click.
func cancel_by_id(id: int) -> bool:
    for i in _queue.size():
        if int(_queue[i].get("id", -1)) == id:
            _queue.remove_at(i)
            _notify_queue_changed()
            return true
    return false


func cancel_by_key(key: String) -> bool:
    for i in _queue.size():
        if str(_queue[i].get("key", "")) == key:
            _queue.remove_at(i)
            _notify_queue_changed()
            return true
    return false


func cancel_at(row: int, col: int) -> bool:
    for i in _queue.size():
        var rec: Dictionary = _queue[i]
        if int(rec.get("row", -1)) == row and int(rec.get("col", -1)) == col:
            _queue.remove_at(i)
            _notify_queue_changed()
            return true
    return false


# The map redraws its bars only when the simulation asks for it, and the
# simulation is stopped. Without this call the bars of the queued actions would
# stay invisible until the resume. The panel of the hex is refreshed for the same
# reason: the buttons it offers depend on what waits on the hex.
func _notify_queue_changed() -> void:
    queue_changed.emit()
    if main_map == null:
        return
    if main_map.has_method("_redraw_progress_layer"):
        main_map._redraw_progress_layer()
    var panel = main_map.get_node_or_null("ControlPanel")
    if panel != null and panel.has_method("refresh"):
        panel.refresh()


func _flush() -> void:
    if _queue.is_empty():
        return
    # The queue is taken out BEFORE the execution: the progress bars of the
    # queued actions must disappear at once, and a record that fails to start
    # must not be retried behind the back of the player.
    var pending := _queue.duplicate()
    _queue.clear()
    _notify_queue_changed()
    for rec in pending:
        var call_exec: Callable = rec.get("execute", Callable())
        if call_exec.is_valid():
            call_exec.call()


# --- THE INTERFACE DURING THE PAUSE ---

func _apply_ui_process_mode(on: bool) -> void:
    if main_map == null:
        return
    for path in UI_NODES:
        var node := main_map.get_node_or_null(path)
        if node == null:
            continue
        node.process_mode = Node.PROCESS_MODE_ALWAYS if on else Node.PROCESS_MODE_INHERIT


# The orange frame. It is drawn on its own layer above everything, and it does
# not intercept the mouse: the click has to reach the buttons underneath.
func _build_border() -> void:
    _border_layer = CanvasLayer.new()
    _border_layer.name = "ActivePauseBorderLayer"
    _border_layer.layer = 200
    _border_layer.process_mode = Node.PROCESS_MODE_ALWAYS
    add_child(_border_layer)

    _border = Control.new()
    _border.name = "ActivePauseBorder"
    _border.set_anchors_preset(Control.PRESET_FULL_RECT)
    _border.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _border.draw.connect(_draw_border)
    _border_layer.add_child(_border)
    _border.visible = false


func _draw_border() -> void:
    # The line is drawn with its centre ON the edge of the window, therefore the
    # rectangle is drawn a half-width inside — otherwise half of the line would
    # lie outside the visible area and the frame would look thinner than it is.
    var inset := BORDER_WIDTH * 0.5
    var rect := Rect2(Vector2(inset, inset), _border.size - Vector2(inset * 2.0, inset * 2.0))
    _border.draw_rect(rect, border_color(), false, BORDER_WIDTH)


func _set_border_visible(on: bool) -> void:
    if _border == null:
        return
    _border.visible = on
    if on:
        _border.queue_redraw()