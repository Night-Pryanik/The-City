# expansion_manager.gd
extends Node

var is_expansion_mode = false
var hexes_bought = 0

signal expansion_mode_changed(active: bool)
signal territory_expanded(row: int, col: int, cost: int)

@onready var main_map = get_parent()

func toggle():
    is_expansion_mode = !is_expansion_mode
    emit_signal("expansion_mode_changed", is_expansion_mode)
    return is_expansion_mode

func is_active() -> bool:
    return is_expansion_mode

func get_hex_cost(row: int, col: int) -> int:
    var tile = main_map.tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    var base_cost = 50  # значение по умолчанию
    if GameData.terrains.has(terrain_id):
        base_cost = GameData.terrains[terrain_id].get("expansion_cost", 50)
    # Нарастание цены: +5% за каждый уже купленный гекс
    var multiplier = 1.0 + hexes_bought * 0.05
    return int(base_cost * multiplier)

func show_context_menu(row: int, col: int, click_pos: Vector2, available_food: int):
    var cost = get_hex_cost(row, col)
    var tile = main_map.tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    var terrain_name = GameData.terrains.get(terrain_id, {}).get("name", "Земля")
    main_map.popup_menu.clear()
    var label = "Освоить (%s, %d/%d еды)" % [terrain_name, cost, available_food]
    main_map.popup_menu.add_item(label)
    main_map.popup_menu.set_item_metadata(
        main_map.popup_menu.item_count - 1,
        {"action": "expand_territory", "row": row, "col": col, "cost": cost}
    )
    main_map.popup_menu.position = click_pos
    main_map.popup_menu.popup()

func handle_action(row: int, col: int, cost: int):
    if not is_expansion_mode:
        return false
    # Проверяем, хватает ли еды
    var available_food = 0
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid]:
            available_food += CityData.city_storage.get(pid, 0)
    if available_food < cost:
        main_map.hud.show_message("Недостаточно еды! Нужно %d, есть %d" % [cost, available_food])
        return false

    # Списываем еду (используем тот же механизм, что и в BuildManager)
    var remaining = cost
    var active_food = []
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid] and CityData.city_storage.get(pid, 0) > 0:
            active_food.append(pid)
    while remaining > 0 and active_food.size() > 0:
        var pid = active_food[randi() % active_food.size()]
        CityData.city_storage[pid] -= 1
        remaining -= 1
        if CityData.city_storage[pid] <= 0:
            active_food.erase(pid)

    if row >= 0 and row < main_map.REGION_ROWS and col >= 0 and col < main_map.REGION_COLS:
        main_map.tile_data[row][col]["in_influence"] = true
        hexes_bought += 1
        emit_signal("territory_expanded", row, col, cost)
        return true
    return false
