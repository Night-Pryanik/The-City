# journal_ui.gd
#
# The journal window: the important messages of the HUD as a vertical list, newest
# first (see journal.gd for the history itself). Unread entries are drawn in the bold
# face and read ones in the body face; a click on the text, like a click on the
# "Mark as read" button beside it, marks the entry as read.
#
# THE WINDOW OWNS NOTHING. The entries live in the journal node, the icons in
# IconRegistry, the look of the buttons in the project theme. This script draws the
# rows and forwards the clicks — therefore the dot on the HUD button, the window and
# the save can never disagree about what is read.
#
# The window is opened by main_map, which also pauses the game: the pause flag is
# recomputed from the visibility of this node (see main_map.apply_pause_state), so the
# window itself never writes get_tree().paused.
extends Control

## The window was closed by the player (the close button or ESC).
signal closed

const ICON_READ := "check.svg"
const ICON_DELETE := "cross.svg"
const ICON_CLEAR_ALL := "demolish.svg"

# The theme variation of the bold face (see theme/tooltips_theme.tres and
# font_manager.gd): the manager answers it with a heavier instance of the CHOSEN
# interface font, so an unread entry stays heavier whatever family the player picked.
# A per-node font override would have pinned the family of one message for good.
const BOLD_VARIATION := &"BoldLabel"

const ROW_BUTTON_SIZE := Vector2(24, 24)
const ROW_ICON_SIZE := 16
const HEADER_ICON_SIZE := 18

var journal: Node = null

# A rebuild is already scheduled. The list is rebuilt DEFERRED: a click on a row
# button deletes the row that is emitting the signal, and freeing it inside the
# emission is asking for a dangling call.
var _rebuild_queued := false

@onready var mark_all_button: Button = $WindowPanel/Margin/VBox/Header/MarkAllButton
@onready var clear_all_button: Button = $WindowPanel/Margin/VBox/Header/ClearAllButton
@onready var close_button: Button = $WindowPanel/Margin/VBox/Header/CloseButton
@onready var empty_label: Label = $WindowPanel/Margin/VBox/EmptyLabel
@onready var list: VBoxContainer = $WindowPanel/Margin/VBox/Scroll/List

func _ready() -> void:
    # The game is paused while the journal is open, and the window has to accept
    # clicks, ESC and its own deferred rebuild then.
    process_mode = Node.PROCESS_MODE_ALWAYS
    _fit_to_viewport()
    hide()
    close_button.pressed.connect(close_journal)
    mark_all_button.pressed.connect(_on_mark_all_pressed)
    clear_all_button.pressed.connect(_on_clear_all_pressed)
    _apply_icons()
    _rebuild()

# The history this window draws. The signal is connected once: a second call with the
# same journal must not make one change rebuild the list twice.
func setup(source: Node) -> void:
    if journal == source:
        return
    if journal != null and is_instance_valid(journal) and journal.changed.is_connected(_queue_rebuild):
        journal.changed.disconnect(_queue_rebuild)
    journal = source
    if journal != null and not journal.changed.is_connected(_queue_rebuild):
        journal.changed.connect(_queue_rebuild)
    _rebuild()

func open_journal() -> void:
    _fit_to_viewport()
    show()
    _rebuild()

# The overlay covers the whole screen. The anchors of the scene cannot do it: the window
# hangs under the map root, which is a Node2D, and a Node2D has no rectangle to stretch
# the anchors to — the root would stay 0×0 with the panel folded into the corner. The
# size is taken from the viewport instead, on every opening, so that a window resized
# between two openings is covered as well (the same way as tech_popup.gd does it).
func _fit_to_viewport() -> void:
    size = get_viewport_rect().size

func close_journal() -> void:
    if not visible:
        return
    hide()
    closed.emit()

func _unhandled_input(event: InputEvent) -> void:
    # ESC belongs to the window while it is open — the pause menu and the map do not
    # see it. The tree is paused here, so this node is the only one that can answer.
    if not visible:
        return
    if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        get_viewport().set_input_as_handled()
        close_journal()

# --- The list -------------------------------------------------------------------

func _queue_rebuild() -> void:
    if _rebuild_queued:
        return
    _rebuild_queued = true
    _rebuild.call_deferred()

func _rebuild() -> void:
    _rebuild_queued = false
    if not is_inside_tree():
        return
    for child in list.get_children():
        list.remove_child(child)
        child.queue_free()
    var entries: Array = journal.entries if journal != null else []
    empty_label.visible = entries.is_empty()
    for entry in entries:
        list.add_child(_make_row(entry))
    # A button that would do nothing is disabled: the player sees at a glance that
    # everything is read, or that the journal is empty.
    mark_all_button.disabled = journal == null or journal.unread_count() == 0
    clear_all_button.disabled = entries.is_empty()

func _make_row(entry: Dictionary) -> Control:
    var id := int(entry["id"])
    var unread := bool(entry["unread"])
    var row := HBoxContainer.new()
    row.name = "Entry%d" % id
    row.add_theme_constant_override("separation", 6)

    var text := Label.new()
    text.name = "Text"
    text.text = str(entry["text"])
    text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    # The label takes the whole free width of the row, so "a click on the message"
    # means the whole message area and not only the letters.
    text.mouse_filter = Control.MOUSE_FILTER_STOP
    text.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    text.theme_type_variation = BOLD_VARIATION if unread else &""
    text.gui_input.connect(_on_text_gui_input.bind(id))
    row.add_child(text)

    var read_button := _make_row_button("ReadButton", ICON_READ,
            tr("Mark as read") if unread else tr("Already read"), "v")
    read_button.disabled = not unread
    read_button.pressed.connect(_mark_read.bind(id))
    row.add_child(read_button)

    var delete_button := _make_row_button("DeleteButton", ICON_DELETE,
            tr("Delete message"), "x")
    delete_button.pressed.connect(_on_delete_pressed.bind(id))
    row.add_child(delete_button)
    return row

# A small square button with an icon and no text. The tooltip is the only label it
# has, therefore the icon falls back to a glyph: an empty button would be unreadable
# if the file of the icon is missing.
func _make_row_button(button_name: String, icon_name: String, tooltip: String,
        fallback_text: String) -> Button:
    var button := Button.new()
    button.name = button_name
    button.custom_minimum_size = ROW_BUTTON_SIZE
    button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    button.tooltip_text = tooltip
    _set_icon(button, icon_name, ROW_ICON_SIZE, fallback_text)
    return button

func _apply_icons() -> void:
    _set_icon(mark_all_button, ICON_READ, HEADER_ICON_SIZE, "v")
    _set_icon(clear_all_button, ICON_CLEAR_ALL, HEADER_ICON_SIZE, "x")
    _set_icon(close_button, ICON_DELETE, HEADER_ICON_SIZE, "x")

func _set_icon(button: Button, icon_name: String, max_size: int, fallback_text: String) -> void:
    var tex := IconRegistry.get_texture(icon_name)
    if tex == null:
        button.text = fallback_text
        return
    button.icon = tex
    button.expand_icon = true
    button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    button.add_theme_constant_override("icon_max_width", max_size)
    button.add_theme_constant_override("icon_max_height", max_size)

# --- The clicks -----------------------------------------------------------------

func _on_text_gui_input(event: InputEvent, id: int) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse := event as InputEventMouseButton
    if mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed:
        _mark_read(id)

func _on_delete_pressed(id: int) -> void:
    if journal != null:
        journal.remove(id)

func _on_mark_all_pressed() -> void:
    if journal != null:
        journal.mark_all_read()

func _on_clear_all_pressed() -> void:
    if journal != null:
        journal.clear()

func _mark_read(id: int) -> void:
    if journal != null:
        journal.mark_read(id)
