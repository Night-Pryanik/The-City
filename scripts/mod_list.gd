# mod_list.gd
#
# The list of the installed mods: a checkbox per mod, and the details of every mod —
# the author, the version, the description, what it requires and what it conflicts with.
#
# The list is embedded into the city naming dialog and is collapsed until the player asks
# for it: the mods are a detail of a new game, not its first question.
#
# THE LIST ONLY COLLECTS THE CHOICE. It never touches the data: `selection_changed` hands
# the set to the host, and the host applies it (main_menu starts a new game with it).
#
# THE CHECK OF THE MOD DATA RUNS HERE, when a checkbox is switched on, and not at
# startup: the mod is not part of the game until the player chooses it, so its data is
# checked exactly at the moment it starts to matter. A mod that brings broken references
# is not switched on, and the list says what is wrong with it.
extends VBoxContainer

const ROW_INDENT := 6
const MAX_SHOWN_PROBLEMS := 5
const NAME_FONT_SIZE := 18
const SMALL_FONT_SIZE := 12

## The player changed the set. The host applies it.
signal selection_changed(ids: Array)
## The room the list needs has changed: the problems panel was shown or hidden.
signal layout_changed

# The chosen mods, in the order they are applied. A dependency is always in the list
# together with the mod that requires it.
var _selected: Array = []
# mod id -> the row checkbox. The dictionary also answers "is this mod on the list".
var _checkboxes: Dictionary = {}
# mod id -> the label with the requirements and the conflicts of the mod.
var _status_labels: Dictionary = {}
@onready var empty_label: Label = $EmptyLabel
@onready var scroll: ScrollContainer = $ScrollArea/Scroll
@onready var list: VBoxContainer = $ScrollArea/Scroll/List
@onready var problems_panel: PanelContainer = $ProblemsPanel
@onready var problems_label: Label = $ProblemsPanel/ProblemsMargin/ProblemsLabel

func _ready() -> void:
    _wire_scroll_gutter()

# --- Opening ---------------------------------------------------------------------

# Fills the list with the given set. The set is resolved first: a save may name a mod
# that has been deleted since, and its dependencies must be complete.
func open(ids: Array) -> void:
    ModManager.scan()
    _selected = ModManager.resolve(ids)
    _clear_problems()
    _rebuild()

func selected_ids() -> Array:
    return _selected.duplicate()

# --- The list --------------------------------------------------------------------

func _rebuild() -> void:
    for child in list.get_children():
        list.remove_child(child)
        child.queue_free()
    _checkboxes.clear()
    _status_labels.clear()

    for manifest in ModManager.mods:
        list.add_child(_make_row(manifest))
    empty_label.visible = ModManager.mods.is_empty()
    _sync_checkboxes()

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
    authors.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
    authors.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(authors)

    var description := Label.new()
    description.text = str(manifest["description"])
    description.add_theme_font_size_override("font_size", SMALL_FONT_SIZE)
    description.add_theme_color_override("font_color", Color(0.78, 0.78, 0.78))
    description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    description.visible = not description.text.is_empty()
    column.add_child(description)

    var status := Label.new()
    status.add_theme_font_size_override("font_size", SMALL_FONT_SIZE)
    status.add_theme_color_override("font_color", Color(0.95, 0.75, 0.4))
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
    version.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
    version.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    line.add_child(version)

    return line

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

# --- Switching -------------------------------------------------------------------

func _on_toggled(pressed: bool, mod_id: String) -> void:
    var before: Array = _selected.duplicate()
    if pressed:
        _try_enable(mod_id)
    else:
        _try_disable(mod_id)
    _sync_checkboxes()
    if _selected != before:
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

    # The data is checked on the set as it would run, and only after the switch: the
    # mod is not part of the game while the checkbox is off, so its errors do not
    # matter until now.
    var problems := ModManager.validate_selection(_selected)
    if not problems.is_empty():
        _selected = previous
        _show_problems(problems)
        return
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
    problems_label.add_theme_color_override("font_color", Color(0.95, 0.75, 0.4))
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
    problems_label.add_theme_color_override("font_color", Color(1.0, 0.62, 0.62))
    _set_problems_visible(true)

func _clear_problems() -> void:
    problems_label.text = ""
    _set_problems_visible(false)

# The panel is not a fixed part of the list: it takes room only while it has something
# to say, and the host has to know that the room has changed.
func _set_problems_visible(value: bool) -> void:
    if problems_panel.visible == value:
        return
    problems_panel.visible = value
    layout_changed.emit()

# The gutter is reserved (SHOW_ALWAYS) so that the rows keep their width when the list
# starts to overflow, but an idle bar paints its grabber over the whole track. The bar
# is hidden while everything fits (the same rule as in town_ui.gd).
func _wire_scroll_gutter() -> void:
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
