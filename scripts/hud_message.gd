extends Panel

var message_label: Label
var message_timer: float = 0.0
var message_duration: float = 3.0
var hud_original_size: Vector2

func _ready():
    # Находим Label с именем "MapMessageLabel" внутри VBoxContainer
    var vbox = $VBoxContainer
    message_label = vbox.get_node("MapMessageLabel")
    message_label.visible = false
    hud_original_size = size

func show_message(text: String):
    message_label.text = text
    message_label.visible = true
    message_timer = 0.0
    call_deferred("_adjust_size")

func _adjust_size():
    await get_tree().process_frame
    var total_height = 0.0
    for child in $VBoxContainer.get_children():
        if child.visible:
            total_height += child.get_combined_minimum_size().y + 4
    size = Vector2(hud_original_size.x, max(total_height, hud_original_size.y))

func _process(delta):
    if message_label.visible:
        message_timer += delta
        if message_timer >= message_duration:
            message_label.visible = false
            message_timer = 0.0
            size = hud_original_size
