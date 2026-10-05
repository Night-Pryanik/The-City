@tool
extends Panel

var message_label: Label
var message_timer: float = 0.0
var message_duration: float = 3.0
var hud_original_size: Vector2

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

func show_message(text: String):
    message_label.text = text
    message_label.visible = true
    message_timer = 0.0
    call_deferred("_adjust_size")

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
