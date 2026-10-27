# mod_list.gd
#
# The mod manager: every installed mod on the left, the mods of the game on the right.
#
# THE RIGHT LIST IS THE LOAD ORDER. The data is merged from top to bottom, so a mod lower
# in the list overrides the fields of the mods above it. A mod that requires another one
# stays BELOW it — its dependency has to be applied first — and the arrows refuse to
# break that pair (ModManager.order_conflict says why).
#
# The list is the mods TAB of the new game window: the mods of a game are a question of
# their own, next to the city and the world.
#
# THE LIST ONLY COLLECTS THE CHOICE. It never touches the data: `selection_changed` hands
# the ordered set to the host, and the host applies it (main_menu starts a new game with
# it).
#
# THE CHECK OF THE MOD DATA RUNS HERE, when a checkbox is switched on, and not at
# startup: the mod is not part of the game until the player chooses it, so its data is
# checked exactly at the moment it starts to matter. A mod that brings broken references
# is not switched on, and the list says what is wrong with it.
extends VBoxContainer

const UI_THEME = preload("res://scripts/ui_theme.gd")

const ROW_INDENT := 6
const MAX_SHOWN_PROBLEMS := 5
const NAME_FONT_SIZE := 18
const SMALL_FONT_SIZE := 12
const ORDER_ROW_HEIGHT := 30

## The player changed the set or its order. The host applies it.
signal selection_changed(ids: Array)

# The chosen mods, in the order they are applied. A dependency is always in the list
# together with the mod that requires it.
var _selected: Array = []
# mod id -> the row checkbox. The dictionary also answers "is this mod on the list".
var _checkboxes: Dictionary = {}
# mod id -> the label with the requirements and the conflicts of the mod.
var _status_labels: Dictionary = {}
# mod id -> the row of the load order. The rows of one build form one button group, so
# exactly one of them is highlighted.
var _order_rows: Dictionary = {}
var _order_group := ButtonGroup.new()
# The mod the arrows move.
var _picked := ""
@onready var available_scroll: ScrollContainer = $Panes/AvailablePane/ScrollArea/Scroll
@onready var list: VBoxContainer = $Panes/AvailablePane/ScrollArea/Scroll/List
@onready var order_scroll: ScrollContainer = $Panes/SelectedPane/Body/ScrollArea/Scroll
@onready var order_list: VBoxContainer = $Panes/SelectedPane/Body/ScrollArea/Scroll/OrderList
@onready var up_button: Button = $Panes/SelectedPane/Body/OrderButtons/UpButton
@onready var down_button: Button = $Panes/SelectedPane/Body/OrderButtons/DownButton
@onready var problems_panel: PanelContainer = $ProblemsPanel
@onready var problems_label: Label = $ProblemsPanel/ProblemsMargin/ProblemsLabel

func _ready() -> void:
    _wire_scroll_gutter(available_scroll)
    _wire_scroll_gutter(order_scroll)
    up_button.pressed.connect(_on_move_pressed.bind(-1))
    down_button.pressed.connect(_on_move_pressed.bind(1))
    _refresh_order_buttons()

# --- Opening ---------------------------------------------------------------------

# Fills both lists with the given set. The set is resolved first: a save may name a mod
# that has been deleted since, and its dependencies must be complete.
func open(ids: Array) -> void:
    ModManager.scan()
    _selected = ModManager.resolve(ids)
    _picked = str(_selected[0]) if not _selected.is_empty() else ""
    _clear_problems()
    _rebuild()

func selected_ids() -> Array:
    return _selected.duplicate()

# --- The list --------------------------------------------------------------------

func _rebuild() -> void:
    _rebuild_available()
    _rebuild_order()
    _sync_checkboxes()

func _rebuild_available() -> void:
    for child in list.get_children():
        list.remove_child(child)
        child.queue_free()
    _checkboxes.clear()
    _status_labels.clear()

    if ModManager.mods.is_empty():
        list.add_child(_make_hint(tr("No mods are installed.")))
        return
    for manifest in ModManager.mods:
        list.add_child(_make_row(manifest))

func _make_row(manifest: Dictionary) -> Control:
    var mod_id := str(manifest["id"])

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", ROW_INDENT)
    row.tooltip_text = _tooltip(manifest)

    var checkbox := CheckBox.new()
    checkbox.custom_minimum_size = Vector2(24, 24)
    checkbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    checkbox.button_pressed = _selected.has(mod_id)
    checkbox.disabled = not str(manifest.get("error", "")).is_empty()
    checkbox.toggled.connect(_on_toggled.bind(mod_id))
    row.add_child(checkbox)
    _checkboxes[mod_id] = checkbox

    var column := VBoxContainer.new()
    column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    column.add_theme_constant_override("separation", 0)
    row.add_child(column)

    column.add_child(_make_header_line(manifest))
    var authors := Label.new()
    authors.text = tr("by %s") % ", ".join(PackedStringArray(manifest["authors"]))
    authors.add_theme_font_size_override("font_size", SMALL_FONT_SIZE)
    authors.theme_type_variation = &"MutedLabel"
    authors.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(authors)

    var description := Label.new()
    description.text = str(manifest["description"])
    description.add_theme_font_size_override("font_size", SMALL_FONT_SIZE)
    description.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    description.visible = not description.text.is_empty()
    column.add_child(description)

    var status := Label.new()
    status.add_theme_font_size_override("font_size", SMALL_FONT_SIZE)
    status.add_theme_color_override("font_color", UI_THEME.color("warning"))
    status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(status)
    _status_labels[mod_id] = status

    return row

# The name of the mod and its version. The version is dimmed: the name is what the
# player looks for, the version only tells the installed build apart.
func _make_header_line(manifest: Dictionary) -> Control:
    var line := HBoxContainer.new()
    line.add_theme_constant_override("separation", 8)

    var name_label := Label.new()
    name_label.text = str(manifest["name"])
    name_label.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
    line.add_child(name_label)

    var version := Label.new()
    version.text = str(manifest["version"])
    version.add_theme_font_size_override("font_size", SMALL_FONT_SIZE)
    version.theme_type_variation = &"MutedLabel"
    version.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    line.add_child(version)

    return line

func _make_hint(text: String) -> Label:
    var label := Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", SMALL_FONT_SIZE)
    label.theme_type_variation = &"MutedLabel"
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    return label

func _tooltip(manifest: Dictionary) -> String:
    var lines: Array = [
        "%s %s" % [str(manifest["name"]), str(manifest["version"])],
        tr("Identifier: %s") % str(manifest["id"]),
        tr("Authors: %s") % ", ".join(PackedStringArray(manifest["authors"])),
        str(manifest["dir"]),
    ]
    if not (manifest["dependencies"] as Array).is_empty():
        lines.append(tr("Requires: %s") % ", ".join(PackedStringArray(manifest["dependencies"])))
    if not (manifest["conflicts"] as Array).is_empty():
        lines.append(tr("Conflicts with: %s") % ", ".join(PackedStringArray(manifest["conflicts"])))
    return "\n".join(PackedStringArray(lines))

# --- The load order ---------------------------------------------------------------

func _rebuild_order() -> void:
    for child in order_list.get_children():
        order_list.remove_child(child)
        child.queue_free()
    _order_rows.clear()
    _order_group = ButtonGroup.new()

    if _selected.is_empty():
        order_list.add_child(_make_hint(tr("No mods are chosen yet.")))
    else:
        for mod_id in _selected:
            order_list.add_child(_make_order_row(str(mod_id)))
    _sync_order_view()

func _make_order_row(mod_id: String) -> Button:
    var manifest := ModManager.get_mod(mod_id)
    var button := Button.new()
    button.toggle_mode = true
    button.button_group = _order_group
    button.alignment = HORIZONTAL_ALIGNMENT_LEFT
    button.custom_minimum_size = Vector2(0, ORDER_ROW_HEIGHT)
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.set_meta("mod_name", str(manifest.get("name", mod_id)))
    button.tooltip_text = _tooltip(manifest) if not manifest.is_empty() else mod_id
    button.set_pressed_no_signal(mod_id == _picked)
    button.pressed.connect(_on_order_row_pressed.bind(mod_id))
    _order_rows[mod_id] = button
    return button

# Puts the rows in the order of the set and numbers them. The rows themselves are reused:
# a move must not reset the scroll of the list or the highlight.
func _sync_order_view() -> void:
    var index := 0
    for mod_id in _selected:
        var row = _order_rows.get(str(mod_id), null)
        if row == null:
            continue
        order_list.move_child(row, index)
        index += 1
        var name := str((row as Button).get_meta("mod_name", str(mod_id)))
        (row as Button).text = "%d. %s" % [index, name]
    _refresh_order_buttons()

func _refresh_order_buttons() -> void:
    var index := _selected.find(_picked)
    # The highlighted mod can be gone (it was switched off), and then the arrows have
    # nothing to move: the first mod of the list takes the highlight.
    if index < 0 and not _selected.is_empty():
        _picked = str(_selected[0])
        index = 0
    var row = _order_rows.get(_picked, null)
    if row != null:
        (row as Button).set_pressed_no_signal(true)
    up_button.disabled = index <= 0
    down_button.disabled = index < 0 or index >= _selected.size() - 1

func _on_order_row_pressed(mod_id: String) -> void:
    _picked = mod_id
    _refresh_order_buttons()

func _on_move_pressed(offset: int) -> void:
    var from := _selected.find(_picked)
    var to := from + offset
    if from < 0 or to < 0 or to >= _selected.size():
        return
    var reason := ModManager.order_conflict(_selected, from, to)
    if not reason.is_empty():
        _show_message(reason)
        return
    _selected.remove_at(from)
    _selected.insert(to, _picked)
    _clear_problems()
    _sync_order_view()
    selection_changed.emit(selected_ids())

# --- Switching -------------------------------------------------------------------

func _on_toggled(pressed: bool, mod_id: String) -> void:
    var before: Array = _selected.duplicate()
    if pressed:
        _try_enable(mod_id)
    else:
        _try_disable(mod_id)
    _sync_checkboxes()
    if _selected != before:
        _rebuild_order()
        selection_changed.emit(selected_ids())

func _try_enable(mod_id: String) -> void:
    var plan := ModManager.enable_plan(mod_id, _selected)
    if not plan["ok"]:
        _set_checked(mod_id, false)
        _show_message(str(plan["reason"]))
        return

    var previous: Array = _selected.duplicate()
    _selected.append(mod_id)
    _selected.append_array(plan["add"])
    # The new mod goes to the bottom of the list — it has the last word over the mods
    # that are already there — and its dependencies are pulled up right above it.
    _selected = ModManager.resolve(_selected)

    # The data is checked on the set as it would run, and only after the switch: the
    # mod is not part of the game while the checkbox is off, so its errors do not
    # matter until now.
    var problems := ModManager.validate_selection(_selected)
    if not problems.is_empty():
        _selected = previous
        _show_problems(problems)
        return
    _picked = mod_id
    _clear_problems()

func _try_disable(mod_id: String) -> void:
    var users := ModManager.required_by(mod_id, _selected)
    if not users.is_empty():
        _set_checked(mod_id, true)
        _show_message(tr("This mod is required by \"%s\".") % _names_of(users))
        return
    _selected.erase(mod_id)
    _clear_problems()

func _sync_checkboxes() -> void:
    for mod_id in _checkboxes:
        _set_checked(str(mod_id), _selected.has(mod_id))
    for mod_id in _status_labels:
        _refresh_status(str(mod_id))

func _set_checked(mod_id: String, pressed: bool) -> void:
    var checkbox = _checkboxes.get(mod_id, null)
    if checkbox != null:
        (checkbox as CheckBox).set_pressed_no_signal(pressed)

# What a switched-on mod needs, and what stands in its way. It is the answer to "why did
# this checkbox just refuse to stay on", so it is written next to the mod itself.
func _refresh_status(mod_id: String) -> void:
    var label = _status_labels.get(mod_id, null)
    if label == null:
        return
    var manifest := ModManager.get_mod(mod_id)
    var lines: Array = []
    var error := str(manifest.get("error", ""))
    if not error.is_empty():
        lines.append(error)
    if not (manifest["dependencies"] as Array).is_empty():
        lines.append(tr("Requires: %s") % _names_of(manifest["dependencies"]))
    if not (manifest["conflicts"] as Array).is_empty():
        lines.append(tr("Conflicts with: %s") % _names_of(manifest["conflicts"]))
    (label as Label).text = "\n".join(PackedStringArray(lines))
    (label as Label).visible = not lines.is_empty()

func _names_of(ids: Array) -> String:
    var names: Array = []
    for id in ids:
        var manifest := ModManager.get_mod(str(id))
        names.append(str(manifest["name"]) if not manifest.is_empty() else str(id))
    return ", ".join(PackedStringArray(names))

# --- The messages ------------------------------------------------------------------

func _show_message(text: String) -> void:
    problems_label.text = text
    problems_label.add_theme_color_override("font_color", UI_THEME.color("warning"))
    _set_problems_visible(not text.is_empty())

func _show_problems(problems: Array) -> void:
    var lines: Array = [tr("The mod data has errors, so the mod was not switched on:")]
    var shown := mini(problems.size(), MAX_SHOWN_PROBLEMS)
    for i in shown:
        lines.append("• " + str(problems[i].get("message", "")))
    if problems.size() > shown:
        lines.append(tr("…and %d more. The full list is in the console.") % (problems.size() - shown))
    for problem in problems:
        push_warning("Mod data: " + str(problem.get("message", "")))
    problems_label.text = "\n".join(PackedStringArray(lines))
    problems_label.add_theme_color_override(
            "font_color", UI_THEME.color("expense").lightened(0.45))
    _set_problems_visible(true)

func _clear_problems() -> void:
    problems_label.text = ""
    _set_problems_visible(false)

# The panel is not a fixed part of the list: it takes room only while it has something to say.
func _set_problems_visible(value: bool) -> void:
    problems_panel.visible = value

# The gutter is reserved (SHOW_ALWAYS) so that the rows keep their width when the list
# starts to overflow, but an idle bar paints its grabber over the whole track. The bar
# is hidden while everything fits (the same rule as in town_ui.gd).
func _wire_scroll_gutter(scroll: ScrollContainer) -> void:
    var bar := scroll.get_v_scroll_bar()
    if bar == null:
        return
    bar.changed.connect(_on_scroll_metrics_changed.bind(bar))
    _on_scroll_metrics_changed(bar)

func _on_scroll_metrics_changed(bar: VScrollBar) -> void:
    if bar == null or not is_instance_valid(bar):
        return
    var idle := bar.max_value <= bar.page
    bar.modulate.a = 0.0 if idle else 1.0
    bar.mouse_filter = Control.MOUSE_FILTER_IGNORE if idle else Control.MOUSE_FILTER_STOP
