@tool
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
    # Ширина подстраивается под содержимое сразу: строка «Казна» стала длиннее
    # («Казна: N [+X≈ / -Y≈]»), а в сцене у HUD фиксированные 184 px.
    _fit_size()

# Габариты содержимого HUD. Контейнер вертикальный: высоты детей складываются
# (плюс зазор 4 px, как в старом _adjust_size), а ширина — это МАКСИМУМ ширин
# детей, а не сумма (иначе панель раздувалась бы вчетверо). Ширина нужна не
# меньше исходной (кнопки «Город»/«Развитие»), высота — как раньше, максимум
# из содержимого и исходной.
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

# Подгоняет размер панели под содержимое. В редакторе не трогаем размер: текст
# меток ставится только во время игры, а изменение size у @tool-скрипта в
# редакторе сохранялось бы в сцену.
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

# Публичная точка для внешнего кода: пересчитать размер панели после того, как
# кто-то изменил текст метки. Нужна, потому что строка «Казна» растёт вместе с
# балансом («Казна: 100 [+2≈ / -0≈]» короче «Казна: 123456 [+1234≈ / -4567≈]»),
# а в сцене ширина HUD зафиксирована (184 px). Из main_map это дёргается в
# _update_treasury_hud() — там же, где ставится новый текст казны.
func refresh_size() -> void:
    _fit_size()
