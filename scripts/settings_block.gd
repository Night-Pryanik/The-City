class_name SettingsBlock
extends Node

# One block of a settings menu: the availability of a group of settings is tied to
# one parent setting. While the parent is switched off, the controls of the block
# cannot be edited and are drawn dimmed; the values they hold stay as they are and
# keep being saved and applied.
#
# A block is data, not code: this node only points at the parent control and at the
# roots of the dependent subtrees (a heading with its row of controls, say). A menu
# knows its blocks through refresh() alone — declaring a block, or changing what
# belongs to it, touches no menu code.

# The parent setting. Any button whose pressed state gates the block — a checkbox,
# typically. The dependents stay editable only while it remains pressed.
@export var gate: NodePath

# The roots of the dependent subtrees. A root is dimmed as a whole, and every
# interactive control found under it stops taking input while the gate is off.
@export var dependents: Array[NodePath] = []

# The blocks of a menu see each other through this group: a gate that one block
# switches off takes its own dependents down with it (see _cascade).
const GROUP := &"settings_blocks"

# The brightness of a switched-off block. A multiply dim leaves the value readable:
# the setting is suspended, not hidden.
const OFF_MODULATE := Color(1, 1, 1, 0.4)

# One refresh pass is numbered, and every block remembers the pass that last wrote
# it. A gate declared inside its own dependents would otherwise recurse forever.
static var _pass_id := 0

var _gate_control: BaseButton = null
var _roots: Array[Control] = []
var _root_modulate: Array[Color] = []
var _focus_modes := {}
var _last_pass := -1

func _ready() -> void:
    _resolve()
    if _gate_control == null:
        push_error("SettingsBlock \"%s\": the gate %s is not a button of the same scene"
            % [name, str(gate)])
        return
    add_to_group(GROUP)
    if not _gate_control.toggled.is_connected(_on_gate_toggled):
        _gate_control.toggled.connect(_on_gate_toggled)
    refresh()

func _on_gate_toggled(_pressed: bool) -> void:
    refresh()

# Applies the state of the gate to the dependents. force_off is set while an outer
# block has switched this block's own gate off.
func refresh(force_off := false) -> void:
    if _gate_control == null:
        return
    SettingsBlock._pass_id += 1
    _refresh(force_off, SettingsBlock._pass_id)

func _refresh(force_off: bool, pass_id: int) -> void:
    if _last_pass == pass_id:
        return
    _last_pass = pass_id
    # A gate switched off by an outer block reads as off, whatever its own
    # button_pressed says.
    var editable := not force_off and _gate_control.button_pressed
    for i in _roots.size():
        _roots[i].modulate = _root_modulate[i] if editable else OFF_MODULATE
        _set_editable(_roots[i], editable)
    _cascade(force_off or not editable, pass_id)

# The gates of the blocks nested inside this one have just gained or lost their
# interactivity, and the blocks they own follow either way.
func _cascade(force_off: bool, pass_id: int) -> void:
    if not is_inside_tree():
        return
    for node in get_tree().get_nodes_in_group(GROUP):
        if node == self:
            continue
        var block := node as SettingsBlock
        if block == null or block._gate_control == null:
            continue
        for root in _roots:
            if root == block._gate_control or root.is_ancestor_of(block._gate_control):
                block._refresh(force_off, pass_id)
                break

func _resolve() -> void:
    if not gate.is_empty():
        _gate_control = get_node_or_null(gate) as BaseButton
    for path in dependents:
        var root := get_node_or_null(path) as Control
        if root == null:
            push_error("SettingsBlock \"%s\": the dependent %s is not a Control of the same scene"
                % [name, str(path)])
            continue
        # A root nested in another root is dimmed by that root already: a second dim
        # would make it twice as dark.
        var nested := false
        for outer in _roots:
            if outer == root or outer.is_ancestor_of(root):
                nested = true
                break
        if nested:
            continue
        _roots.append(root)
        _root_modulate.append(root.modulate)

# Every interactive control under the root stops taking input, and lets go of the
# keyboard focus — a focused slider still answers the arrow keys. Labels and rows
# have no such property: they only follow the dim of their root.
func _set_editable(node: Node, editable: bool) -> void:
    if node is Range:
        node.editable = editable
        _set_focus(node, editable)
    elif node is BaseButton:
        # A gate stays interactive even under another block's dim: it is the control
        # that switches the sub-tree back on.
        if node != _gate_control:
            node.disabled = not editable
    elif node is LineEdit or node is TextEdit:
        node.editable = editable
        _set_focus(node, editable)
    for child in node.get_children():
        _set_editable(child, editable)

func _set_focus(node: Control, editable: bool) -> void:
    if not _focus_modes.has(node):
        _focus_modes[node] = node.focus_mode
    node.focus_mode = _focus_modes[node] if editable else Control.FOCUS_NONE
