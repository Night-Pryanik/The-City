@tool
extends Panel

# The bounds of the "HUD message display time" setting (the Interface tab of the settings
# menu). set_message_duration() clamps to them, so a hand-edited user://settings.cfg cannot
# make a message flash out or stay forever.
const MIN_MESSAGE_DURATION := 1.0
const MAX_MESSAGE_DURATION := 10.0

enum MessageType { NORMAL, IMPORTANT }

var message_label: Label
var message_timer: float = 0.0
var message_duration: float = 3.0
var hud_original_size: Vector2
var current_message_type: MessageType = MessageType.NORMAL

# The journal of the important messages (see journal.gd). Every message passes through
# show_message(), so the copy is made here: a caller reports its message once and never
# has to remember to push the same text into the history as well. The dot on the
# journal button follows the unread count of the same node.
var journal: Node = null

func _ready():
    # We find the Label named "MapMessageLabel" inside the VBoxContainer
    var vbox = $VBoxContainer
    message_label = vbox.get_node("MapMessageLabel")
    message_label.visible = false
    hud_original_size = size
    # The width adapts to the contents immediately: the "Treasury" line has become
    # longer ("Treasury: N [+X≈ / -Y≈]"), while the HUD in the scene has a fixed 184 px.
    _fit_size()

# The dimensions of the HUD contents. The container is vertical: the heights of the
# children add up (plus a 4 px gap, as in the old _adjust_size), and the width is the
# MAXIMUM of the children widths, not the sum (otherwise the panel would inflate
# fourfold). The width must be not less than the original one (the "City"/"Growth"
# buttons), the height — as before, the maximum
# of the contents and the original one.
func _content_size() -> Vector2:
    var vbox = $VBoxContainer
    var content := Vector2.ZERO
    for child in vbox.get_children():
        if not child.visible:
            continue
        var child_min: Vector2 = child.get_combined_minimum_size()
        content.x = maxf(content.x, child_min.x)
        content.y += child_min.y + 4
    return content

# Fits the panel size to the contents. In the editor we do not touch the size: the
# label text is set only during the game, and a size change of a @tool script in
# the editor would be saved into the scene.
func _fit_size() -> void:
    if Engine.is_editor_hint():
        return
    var content := _content_size()
    size = Vector2(
        maxf(content.x, hud_original_size.x),
        maxf(content.y, hud_original_size.y)
    )

func show_message(text: String, type: MessageType = MessageType.NORMAL):
    message_label.text = text
    message_label.visible = true
    message_timer = 0.0
    current_message_type = type
    # Only the important messages are worth keeping: the ordinary ones report routine
    # actions (a road built, a road cancelled) and would bury the journal under noise.
    if type == MessageType.IMPORTANT and journal != null:
        journal.add_message(text)
    call_deferred("_adjust_size")

# The history the HUD feeds, and whose unread count the dot on the journal button
# shows. The connection is made once: two calls with the same journal must not refresh
# the dot twice on every change.
func set_journal(source: Node) -> void:
    if journal == source:
        return
    if journal != null and is_instance_valid(journal) and journal.changed.is_connected(_refresh_unread_dot):
        journal.changed.disconnect(_refresh_unread_dot)
    journal = source
    if journal != null and not journal.changed.is_connected(_refresh_unread_dot):
        journal.changed.connect(_refresh_unread_dot)
    _refresh_unread_dot()

func _refresh_unread_dot() -> void:
    # Looked up by name: the panel is also built by hand in tests, where the journal
    # button does not exist and there is nothing to mark.
    var dot := get_node_or_null("VBoxContainer/JournalButton/UnreadDot")
    if dot == null:
        return
    dot.visible = journal != null and journal.unread_count() > 0

# Applies the "HUD message display time" setting (the key interface/hud_message_duration in
# user://settings.cfg). Called by main_map from apply_settings() and at map start. The timer
# counts up, so shortening the duration while a message is on screen hides it right away.
func set_message_duration(value: float) -> void:
    message_duration = clampf(value, MIN_MESSAGE_DURATION, MAX_MESSAGE_DURATION)

func _adjust_size():
    await get_tree().process_frame
    _fit_size()

func _process(delta):
    if message_label.visible:
        message_timer += delta
        if message_timer >= message_duration:
            message_label.visible = false
            message_timer = 0.0
            _fit_size()

# A public entry point for external code: recalculate the panel size after someone
# has changed the label text. It is needed because the "Treasury" line grows along
# with the balance ("Treasury: 100 [+2≈ / -0≈]" is shorter than
# "Treasury: 123456 [+1234≈ / -4567≈]"),
# while the HUD width in the scene is fixed (184 px). From main_map this is triggered in
# _update_treasury_hud() — the same place where the new treasury text is set.
func refresh_size() -> void:
    _fit_size()
