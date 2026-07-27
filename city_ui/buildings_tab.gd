# buildings_tab.gd
extends Node

var ui_helpers: Node
var products: Dictionary = {}
var buildings_data: Array = []
var crafts_data: Array = []
var city_storage: Dictionary = {}
var city_food_pool: Dictionary = {}
var built_buildings: Array = []
var selected_building_id: String = ""

var buildings_item_list: ItemList
var building_name_label: Label
var building_cost_label: Label
var building_recipes_label: Label
var build_button: Button
var built_buildings_list: Node
var food_label: Label
var hsplit: HSplitContainer

signal build_requested(building_id: String)

func setup(item_list: ItemList, name_lbl: Label, cost_lbl: Label, recipes_lbl: Label, btn: Button, built_list: Node, food_lbl: Label, splitter: HSplitContainer, helpers: Node):
    buildings_item_list = item_list
    building_name_label = name_lbl
    building_cost_label = cost_lbl
    building_recipes_label = recipes_lbl
    build_button = btn
    built_buildings_list = built_list
    food_label = food_lbl
    hsplit = splitter
    ui_helpers = helpers

    if not buildings_item_list.item_selected.is_connected(_on_building_selected):
        buildings_item_list.item_selected.connect(_on_building_selected)
    if not build_button.pressed.is_connected(_on_build_pressed):
        build_button.pressed.connect(_on_build_pressed)
    build_button.disabled = true

func update_data(data: Dictionary):
    products = data.get("products", {})
    buildings_data = data.get("buildings_data", [])
    crafts_data = data.get("crafts_data", [])
    city_storage = data.get("city_storage", {})
    city_food_pool = data.get("city_food_pool", {})
    built_buildings = data.get("built_buildings", [])

func refresh_list():
    buildings_item_list.clear()
    selected_building_id = ""
    build_button.disabled = true
    if ui_helpers:
        ui_helpers.set_message("")
    food_label.text = ""
    for bld in buildings_data:
        var item_text = bld["name"]
        var cost_food = bld.get("cost_food", 0)
        item_text += " (еда: %d" % cost_food
        if bld.has("additional_cost"):
            for res_id in bld["additional_cost"]:
                var res_name = products.get(res_id, {}).get("name", res_id)
                var amount = bld["additional_cost"][res_id]
                item_text += ", %s: %d" % [res_name, amount]
        item_text += ")"
        buildings_item_list.add_item(item_text)
    center_split_offset()

func refresh_built():
    for child in built_buildings_list.get_children():
        child.queue_free()
    var counts = {}
    for bld in built_buildings:
        var id = bld["id"]
        counts[id] = counts.get(id, 0) + 1
    for id in counts:
        var bdata = null
        for b in buildings_data:
            if b["id"] == id:
                bdata = b
                break
        var building_name = bdata["name"] if bdata else id
        var line = building_name + (" x%d" % counts[id] if counts[id] > 1 else "")
        var lbl = Label.new()
        lbl.text = line
        built_buildings_list.add_child(lbl)

func center_split_offset():
    if hsplit:
        hsplit.split_offset = hsplit.size.x / 2

func _on_building_selected(idx: int):
    if ui_helpers:
        ui_helpers.set_message("")
    if idx >= 0 and idx < buildings_data.size():
        selected_building_id = buildings_data[idx]["id"]
        var bdata = buildings_data[idx]
        building_name_label.text = bdata["name"]
        var cost_text = "Стоимость в еде: " + str(bdata.get("cost_food", 0))
        if bdata.has("additional_cost"):
            cost_text += "\nДополнительно:"
            for res_id in bdata["additional_cost"]:
                var res_name = products.get(res_id, {}).get("name", res_id)
                var amount = bdata["additional_cost"][res_id]
                cost_text += "\n  %s: %d" % [res_name, amount]
        building_cost_label.text = cost_text

        if bdata.has("additional_cost"):
            var res_texts = []
            for res_id in bdata["additional_cost"]:
                var required = bdata["additional_cost"][res_id]
                var available = city_storage.get(res_id, 0)
                var res_name = products.get(res_id, {}).get("name", res_id)
                res_texts.append("%s: %d/%d" % [res_name, available, required])
            food_label.text = "Доп. ресурсы: " + ", ".join(res_texts)
        else:
            food_label.text = ""

        var recipes_text = "Рецепты:\n"
        var found = false
        for craft in crafts_data:
            if craft["produced_in"] == selected_building_id:
                var inputs = []
                for res in craft["resources"]:
                    inputs.append(products.get(res, {}).get("name", res) + " - " + str(craft["resources"][res]))
                var outputs = []
                for res in craft["result"]:
                    outputs.append(products.get(res, {}).get("name", res) + " - " + str(craft["result"][res]))
                recipes_text += "Производит: " + ", ".join(outputs) + "\n"
                recipes_text += "Затраты: " + ", ".join(inputs) + "\n"
                recipes_text += "Время: " + str(craft.get("time", 0)) + "\n"
                found = true
        if not found:
            recipes_text = "Нет рецептов"
        building_recipes_label.text = recipes_text
        build_button.disabled = false
        get_parent().update_food_label()
    else:
        selected_building_id = ""
        build_button.disabled = true
        food_label.text = ""

func _on_build_pressed():
    if selected_building_id == "":
        if ui_helpers:
            ui_helpers.set_message("Не выбрано здание")
        return

    var bdata = null
    for b in buildings_data:
        if b["id"] == selected_building_id:
            bdata = b
            break
    if not bdata:
        return

    var missing_parts = []
    var cost_food = bdata.get("cost_food", 0)
    var available_food = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            available_food += city_storage.get(pid, 0)
    if available_food < cost_food:
        missing_parts.append("еды %d" % cost_food)

    if bdata.has("additional_cost"):
        var additional = bdata["additional_cost"]
        for res_id in additional:
            var required = additional[res_id]
            var available = city_storage.get(res_id, 0)
            if available < required:
                var res_name = products.get(res_id, {}).get("name", res_id)
                missing_parts.append("%s %d" % [res_name, required])

    if missing_parts.size() > 0:
        if ui_helpers:
            ui_helpers.set_message("Не хватает: " + ", ".join(missing_parts))
        return

    emit_signal("build_requested", selected_building_id)
