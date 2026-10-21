# save_load_window.gd
#
# The window of the saves. In the save mode it offers a place — an existing slot or
# a new one — and a name for it; in the load mode, the list of the saved games.
#
# THE WINDOW ONLY COLLECTS THE CHOICE. The host performs it: main_map saves and
# reloads the scene, main_menu loads and changes the scene. One window therefore
# serves both, and the storage never learns about the interface.
#
# In the game the window is opened from the pause menu, that is, over a PAUSED tree:
# a pausable node would stop receiving ESC there (the same reason as in journal_ui.gd),
# so the node is PROCESS_MODE_ALWAYS. Its layer is above the pause menu, which stays
# behind the window instead of being hidden by it.
extends CanvasLayer

const UiHelpers = preload("res://scripts/ui_helpers.gd")

## The player confirmed a save. An empty slot_id means a new slot: the id belongs to
## the storage, and the window knows only the name.
signal save_requested(slot_id: String, save_name: String)
## The player confirmed the loading of an existing slot.
signal load_requested(slot_id: String)
## The window was closed by the player (the cross, ESC, Cancel).
signal closed

enum Mode { SAVE, LOAD }

# The id that means "a new slot".
const NEW_SLOT_ID := ""

const ROW_MIN_HEIGHT := 46
const ROW_BUTTON_SIZE := Vector2(28, 28)
const ROW_ICON_SIZE := 16
const HEADER_ICON_SIZE := 18

var mode: int = Mode.SAVE

# The slots as the storage reports them, the newest first.
var _slots: Array = []
# slot id -> the row button. The buttons of one build form one group, so exactly one
# row is pressed; the dictionary answers "is this id on the list" at the same time.
var _row_buttons: Dictionary = {}
# The highlighted place. It is not the target of a save by itself: the save is
# identified by the NAME, and the highlight follows the name field (see _on_name_changed).
var _selected_id := NEW_SLOT_ID
# The name offered for a new slot (the name of the city of the running game).
var _suggested_name := ""

var _confirm: ConfirmationDialog = null
var _pending_action: Callable = Callable()

@onready var title_label: Label = $Root/WindowPanel/Margin/VBox/Header/TitleLabel
@onready var close_button: Button = $Root/WindowPanel/Margin/VBox/Header/CloseButton
@onready var name_row: HBoxContainer = $Root/WindowPanel/Margin/VBox/NameRow
@onready var name_edit: LineEdit = $Root/WindowPanel/Margin/VBox/NameRow/NameEdit
@onready var empty_label: Label = $Root/WindowPanel/Margin/VBox/EmptyLabel
@onready var scroll: ScrollContainer = $Root/WindowPanel/Margin/VBox/Scroll
@onready var list: VBoxContainer = $Root/WindowPanel/Margin/VBox/Scroll/List
@onready var cancel_button: Button = $Root/WindowPanel/Margin/VBox/Buttons/CancelButton
@onready var accept_button: Button = $Root/WindowPanel/Margin/VBox/Buttons/AcceptButton

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    hide()
    close_button.pressed.connect(close)
    cancel_button.pressed.connect(close)
    accept_button.pressed.connect(_on_accept_pressed)
    name_edit.text_changed.connect(_on_name_changed)
    name_edit.text_submitted.connect(func(_text: String) -> void: _on_accept_pressed())
    _set_icon(close_button, "cross.svg", HEADER_ICON_SIZE, "x")
    _make_confirm_dialog()
    _wire_scroll_gutter()

# --- Opening ---------------------------------------------------------------------

func open_save(suggested_name: String = "") -> void:
    mode = Mode.SAVE
    _suggested_name = suggested_name.strip_edges()
    title_label.text = tr("Save game")
    name_row.visible = true
    accept_button.text = tr("Save")
    _reload()
    show()
    name_edit.grab_focus()
    name_edit.select_all()

func open_load() -> void:
    mode = Mode.LOAD
    title_label.text = tr("Load game")
    name_row.visible = false
    accept_button.text = tr("Load")
    _reload()
    show()

func close() -> void:
    if not visible:
        return
    if _confirm != null:
        _confirm.hide()
    _pending_action = Callable()
    hide()
    closed.emit()

func _input(event: InputEvent) -> void:
    # ESC belongs to the window while it is open — neither the pause menu nor the map
    # sees it. The event is taken in _input, and not in _unhandled_input: the name
    # field holds the focus when the window opens, and a LineEdit spends ESC on
    # releasing the focus, so the window would need a second press to close.
    if not visible:
        return
    if _confirm != null and _confirm.visible:
        return
    if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        get_viewport().set_input_as_handled()
        close()

# --- The list --------------------------------------------------------------------

func _reload() -> void:
    _slots = SaveManager.list_saves()
    _rebuild()
    var target := _preferred_slot()
    _select(target)
    if mode == Mode.SAVE:
        name_edit.text = _name_for(target)

func _rebuild() -> void:
    # A rebuild replaces every row, so the buttons of the previous build must leave
    # the group: otherwise a freed button stays the pressed one of it.
    for child in list.get_children():
        list.remove_child(child)
        child.queue_free()
    _row_buttons.clear()

    var group := ButtonGroup.new()
    if mode == Mode.SAVE:
        list.add_child(_make_row(NEW_SLOT_ID, tr("New save"), "", group))
    for slot in _slots:
        var id := str(slot.get("id", ""))
        list.add_child(_make_row(id, str(slot.get("name", "")), UiHelpers.save_details(slot), group))
    empty_label.visible = mode == Mode.LOAD and _slots.is_empty()

func _make_row(id: String, title: String, details: String, group: ButtonGroup) -> Control:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 4)

    # A toggle button is the row: it brings the hover, the focus and the pressed
    # state from the theme, which a hand-drawn selection would have to repeat.
    var button := Button.new()
    button.toggle_mode = true
    button.button_group = group
    button.alignment = HORIZONTAL_ALIGNMENT_LEFT
    button.custom_minimum_size = Vector2(0, ROW_MIN_HEIGHT)
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.text = title if details.is_empty() else "%s\n%s" % [title, details]
    button.pressed.connect(_on_row_pressed.bind(id))
    row.add_child(button)
    _row_buttons[id] = button

    if mode == Mode.LOAD:
        var delete_button := Button.new()
        delete_button.custom_minimum_size = ROW_BUTTON_SIZE
        delete_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        delete_button.tooltip_text = tr("Delete this save")
        _set_icon(delete_button, "cross.svg", ROW_ICON_SIZE, "x")
        delete_button.pressed.connect(_on_delete_pressed.bind(id))
        row.add_child(delete_button)
    return row

# The place the window opens on: the slot selected last (in the save window or in the
# load window), so that a repeated save does not need a click. In the save mode the
# absence of a choice means a new slot; in the load mode, the newest one.
func _preferred_slot() -> String:
    if _row_buttons.has(SaveManager.last_slot_id):
        return SaveManager.last_slot_id
    if mode == Mode.SAVE:
        return NEW_SLOT_ID
    for slot in _slots:
        return str(slot.get("id", ""))
    return NEW_SLOT_ID

func _select(slot_id: String) -> void:
    _selected_id = slot_id if _row_buttons.has(slot_id) else NEW_SLOT_ID
    for key in _row_buttons:
        (_row_buttons[key] as Button).set_pressed_no_signal(key == _selected_id)
    accept_button.disabled = mode == Mode.LOAD and _selected_id == NEW_SLOT_ID

func _name_for(slot_id: String) -> String:
    if slot_id == NEW_SLOT_ID:
        return _suggested_name if not _suggested_name.is_empty() else tr("Save")
    return _slot_name(slot_id)

func _slot_name(slot_id: String) -> String:
    for slot in _slots:
        if str(slot.get("id", "")) == slot_id:
            return str(slot.get("name", ""))
    return ""

# The slot the name belongs to; an empty id if the name is free.
func _slot_by_name(save_name: String) -> String:
    if save_name.is_empty():
        return NEW_SLOT_ID
    for slot in _slots:
        if str(slot.get("name", "")) == save_name:
            return str(slot.get("id", ""))
    return NEW_SLOT_ID

# --- The actions -----------------------------------------------------------------

func _on_row_pressed(slot_id: String) -> void:
    _selected_id = slot_id
    if mode == Mode.SAVE:
        name_edit.text = _name_for(slot_id)
    accept_button.disabled = mode == Mode.LOAD and slot_id == NEW_SLOT_ID

# The name is what identifies a save, not the row that happens to be highlighted: a
# name that no slot carries is a new save, and only a name that matches an existing slot
# overwrites it. The highlight follows the field, so the place that will be written is
# visible before the button is pressed.
func _on_name_changed(text: String) -> void:
    if mode != Mode.SAVE:
        return
    _select(_slot_by_name(text.strip_edges()))

func _on_accept_pressed() -> void:
    if mode == Mode.LOAD:
        if _selected_id != NEW_SLOT_ID:
            load_requested.emit(_selected_id)
        return

    var save_name := name_edit.text.strip_edges()
    if save_name.is_empty():
        save_name = _name_for(NEW_SLOT_ID)
    var target := _slot_by_name(save_name)
    # The highlight is brought in line with the name once more: a programmatic
    # assignment to the field emits no text_changed, and the row must never point at a
    # slot other than the one the button is about to write.
    _select(target)
    # Overwriting a slot destroys a game: the confirmation is asked here, before the
    # host is told. A name that belongs to no slot creates a new save and destroys
    # nothing, therefore it needs no confirmation.
    if not target.is_empty():
        _ask_confirmation(tr("Overwrite the save"),
                tr("Overwrite the save \"%s\"?") % save_name,
                func() -> void: save_requested.emit(target, save_name))
        return
    save_requested.emit(NEW_SLOT_ID, save_name)

func _on_delete_pressed(slot_id: String) -> void:
    _ask_confirmation(tr("Delete the save"),
            tr("Delete the save \"%s\"?") % _slot_name(slot_id),
            func() -> void:
                SaveManager.delete_save(slot_id)
                _reload())

# --- The confirmation dialog -----------------------------------------------------

# One dialog for both destructive actions: the title, the text and the action are
# substituted before showing. The action lives in _pending_action and is not
# re-connected on every request — a one-shot connection would remain hanging after a
# cancel and would fire on the NEXT confirmation (the same rule as in pause_menu.gd).
func _make_confirm_dialog() -> void:
    _confirm = ConfirmationDialog.new()
    _confirm.get_ok_button().text = tr("Yes")
    _confirm.get_cancel_button().text = tr("Cancel")
    _confirm.process_mode = Node.PROCESS_MODE_ALWAYS
    _confirm.confirmed.connect(_on_confirm_accepted)
    _confirm.canceled.connect(_on_confirm_rejected)
    add_child(_confirm)
    _confirm.hide()

func _ask_confirmation(title: String, text: String, action: Callable) -> void:
    if _confirm == null:
        return
    _confirm.title = title
    _confirm.dialog_text = text
    _pending_action = action
    _confirm.popup_centered()

func _on_confirm_accepted() -> void:
    var action = _pending_action
    # The action is reset BEFORE the call: it may close the window or free the rows.
    _pending_action = Callable()
    if action.is_valid():
        action.call()

func _on_confirm_rejected() -> void:
    _pending_action = Callable()

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

# --- Icons -----------------------------------------------------------------------
# An icon button keeps a glyph as a fallback: a button with no caption and no icon
# would be unreadable if the file is missing.
func _set_icon(button: Button, icon_name: String, max_size: int, fallback_text: String) -> void:
    var texture := IconRegistry.get_texture(icon_name)
    if texture == null:
        button.text = fallback_text
        return
    button.icon = texture
    button.expand_icon = true
    button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    button.add_theme_constant_override("icon_max_width", max_size)
    button.add_theme_constant_override("icon_max_height", max_size)
