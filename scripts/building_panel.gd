# building_panel.gd
# Панель деталей здания: отображает информацию о здании и его слотах,
# позволяет менять рецепт в каждом слоте.
extends Control

var building_index: int = -1
var products: Dictionary = {}
var buildings_data: Array = []
var crafts_data: Array = []

var panel: Panel
var title_label: Label
var info_label: Label
var slots_container: VBoxContainer

func _ready():
    # Создаём оверлей-панель поверх CityUI.
    # ВАЖНО: CityUI — дочерний узел Node2D-сцены, поэтому у него нет собственного rect.
    # Задаём размеры корневого Control вручную в open().
    var dim = ColorRect.new()
    dim.color = Color(0, 0, 0, 0.5)
    dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(dim)

    var center = CenterContainer.new()
    center.set_anchors_preset(Control.PRESET_FULL_RECT)
    add_child(center)

    panel = Panel.new()
    panel.custom_minimum_size = Vector2(460, 400)
    # Непрозрачный тёмный фон для панели
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.13, 0.13, 0.13, 1.0)
    style.set_border_width_all(2)
    style.border_color = Color(0.4, 0.4, 0.4, 1.0)
    style.set_corner_radius_all(4)
    panel.add_theme_stylebox_override("panel", style)
    center.add_child(panel)

    var vbox = VBoxContainer.new()
    vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 20
    vbox.offset_top = 20
    vbox.offset_right = -20
    vbox.offset_bottom = -20
    vbox.add_theme_constant_override("separation", 10)
    panel.add_child(vbox)

    title_label = Label.new()
    title_label.add_theme_font_size_override("font_size", 20)
    vbox.add_child(title_label)

    info_label = Label.new()
    vbox.add_child(info_label)

    var slots_title = Label.new()
    slots_title.text = "Слоты производства:"
    vbox.add_child(slots_title)

    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vbox.add_child(scroll)

    slots_container = VBoxContainer.new()
    slots_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(slots_container)

    var close_btn = Button.new()
    close_btn.text = "Закрыть"
    close_btn.pressed.connect(_on_close_pressed)
    vbox.add_child(close_btn)

func open(index: int, data: Dictionary):
    building_index = index
    products = data.get("products", {})
    crafts_data = data.get("crafts_data", [])
    # Задаём размер корневого Control = размер viewport, чтобы оверлей покрывал всё
    var vp_size = get_viewport_rect().size
    size = vp_size
    position = Vector2.ZERO
    _refresh()
    show()

func _refresh():
    if building_index < 0 or building_index >= CityData.city_built_buildings.size():
        return
    # Гарантируем, что у здания есть слоты (на случай старых сейвов/сессий)
    CityData.migrate_old_save_format()
    var bld = CityData.city_built_buildings[building_index]
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == bld["id"]:
            bdata = b
            break

    var building_name = bdata["name"] if bdata else bld["id"]
    title_label.text = building_name

    var info_text = "Слотов: %d" % bld.get("slots", []).size()
    if bdata:
        info_text += "\nСтоимость в еде: %d" % bdata.get("cost_food", 0)
        if bdata.has("additional_cost"):
            info_text += "\nДополнительно:"
            for res_id in bdata["additional_cost"]:
                var res_name = products.get(res_id, {}).get("name", res_id)
                info_text += "\n  %s: %d" % [res_name, bdata["additional_cost"][res_id]]
    info_label.text = info_text

    # Очищаем старые слоты
    for child in slots_container.get_children():
        child.queue_free()

    var slots = bld.get("slots", [])
    for i in range(slots.size()):
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 8)

        var slot_label = Label.new()
        slot_label.text = "Слот %d:" % (i + 1)
        slot_label.custom_minimum_size = Vector2(70, 0)
        row.add_child(slot_label)

        var option = OptionButton.new()
        option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        # Собираем доступные рецепты: "empty" + все, что можно исполнять в этом здании
        var available = []
        available.append("empty")
        for craft in crafts_data:
            if craft["id"] == "empty":
                continue
            if CityData.can_craft_in(craft["id"], bld["id"]):
                available.append(craft["id"])

        var current = slots[i]
        var selected_idx = 0
        for j in range(available.size()):
            var craft_id = available[j]
            var craft_name = craft_id
            for c in crafts_data:
                if c["id"] == craft_id:
                    craft_name = c.get("name", craft_id)
                    break
            option.add_item(craft_name)
            option.set_item_metadata(j, craft_id)
            if craft_id == current:
                selected_idx = j
        option.select(selected_idx)
        option.item_selected.connect(_on_slot_changed.bind(i, available))
        row.add_child(option)

        slots_container.add_child(row)

func _on_slot_changed(option_index: int, slot_idx: int, available: Array):
    if building_index < 0 or building_index >= CityData.city_built_buildings.size():
        return
    var craft_id = available[option_index]
    var bld = CityData.city_built_buildings[building_index]
    var slots = bld.get("slots", [])
    if slot_idx < slots.size():
        slots[slot_idx] = craft_id
        bld["slots"] = slots
        CityData.emit_signal("city_updated")

func _input(event: InputEvent):
    if not visible:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        # Клик вне панели (по затемнению) закрывает её
        if not panel.get_global_rect().has_point(event.global_position):
            hide()
            get_viewport().set_input_as_handled()

func _on_close_pressed():
    hide()
