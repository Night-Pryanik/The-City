# expansion_manager.gd
extends Node

var is_expansion_mode = false
var hexes_bought = 0
var current_chunk = [] # массив {"row": int, "col": int}
var current_hover_hex = null # {"row": int, "col": int}

signal expansion_mode_changed(active: bool)
signal territory_expanded(row: int, col: int, cost: int)
signal chunk_hovered(chunk: Array) # для оповещения рендерера

@onready var main_map = get_parent()

func toggle():
    is_expansion_mode = !is_expansion_mode
    current_chunk = []
    emit_signal("expansion_mode_changed", is_expansion_mode)
    return is_expansion_mode

func is_active() -> bool:
    return is_expansion_mode

func get_hex_cost(row: int, col: int) -> int:
    var tile = main_map.tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    var base_cost = 50
    if GameData.terrains.has(terrain_id):
        base_cost = GameData.terrains[terrain_id].get("expansion_cost", 50)
    var multiplier = 1.0 + hexes_bought * 0.05
    return int(base_cost * multiplier)

# Возвращает чанк (список гексов), который включает стартовый гекс.
# Чанк однороден по статусу исследования: если стартовый гекс не исследован,
# в чанк включаются только неисследованные гексы (для разведки).
# Если стартовый гекс исследован — только исследованные (для освоения).
func get_chunk_hexes(start_row: int, start_col: int) -> Array:
    var chunk = []
    var visited = {}
    var queue = [ {"row": start_row, "col": start_col}]
    var key = str(start_row) + "," + str(start_col)
    visited[key] = true
    var start_explored = main_map.tile_data[start_row][start_col].get("is_explored", false)

    while queue.size() > 0 and chunk.size() < 5:
        var current = queue.pop_front()
        chunk.append(current)
        var neighbors = _get_neighbors(current.row, current.col)
        for n in neighbors:
            var n_key = str(n.row) + "," + str(n.col)
            if visited.has(n_key):
                continue
            if not main_map.is_valid_hex(n.row, n.col):
                continue
            var tile = main_map.tile_data[n.row][n.col]
            if tile.get("in_influence", false):
                continue
            # Исключаем гексы с отличающимся статусом исследования,
            # чтобы не включать в чанк разведки уже исследованные гексы
            if tile.get("is_explored", false) != start_explored:
                continue
            visited[n_key] = true
            queue.append(n)
    return chunk

# Обновляет текущий подсвеченный чанк
func update_hovered_chunk(row: int, col: int):
    current_hover_hex = {"row": row, "col": col}
    var chunk = get_chunk_hexes(row, col)
    if _chunk_equals(chunk, current_chunk):
        return
    current_chunk = chunk
    emit_signal("chunk_hovered", current_chunk)

func clear_hovered_chunk():
    current_hover_hex = null
    if current_chunk.is_empty():
        return
    current_chunk = []
    emit_signal("chunk_hovered", current_chunk)

# Стоимость всего чанка
func get_chunk_cost(chunk: Array) -> int:
    var max_cost = 0
    for hex in chunk:
        var cost = get_hex_cost(hex.row, hex.col)
        if cost > max_cost:
            max_cost = cost
    return max_cost * chunk.size()

func show_context_menu(chunk: Array, click_pos: Vector2, available_food: int):
    # --- Проверка: все гексы в чанке исследованы ---
    var all_explored = true
    for hex in chunk:
        var tile = main_map.tile_data[hex.row][hex.col]
        if not tile.get("is_explored", false):
            all_explored = false
            break
    if not all_explored:
        main_map.hud.show_message("Этот чанк ещё не исследован!")
        return

    # --- Проверка: чанк граничит с Кольцом Влияния ---
    var has_neighbor = false
    for hex in chunk:
        var neighbors = HexUtils.get_neighbors_odd_r(hex.row, hex.col, main_map.map_rows, main_map.map_cols)
        for n in neighbors:
            var n_tile = main_map.tile_data[n.row][n.col]
            if n_tile.get("in_influence", false):
                has_neighbor = true
                break
        if has_neighbor:
            break
    if not has_neighbor:
        main_map.hud.show_message("Этот чанк не граничит с вашими владениями!")
        return

    # --- Остальной код (формирование меню) ---
    var cost = get_chunk_cost(chunk)
    var hex_count = chunk.size()
    var max_cost = 0
    for hex in chunk:
        var c = get_hex_cost(hex.row, hex.col)
        if c > max_cost:
            max_cost = c
    main_map.popup_menu.clear()
    var label = "Освоить выделенную область (%d клеток, %d/%d еды)" % [hex_count, cost, available_food]
    main_map.popup_menu.add_item(label)
    main_map.popup_menu.set_item_metadata(
        main_map.popup_menu.item_count - 1,
        {"action": "expand_territory", "chunk": chunk, "cost": cost}
    )
    main_map.popup_menu.position = click_pos
    main_map.popup_menu.popup()

func handle_action(chunk: Array, cost: int) -> bool:
    # Режим "Развитие" убран - действие доступно всегда
    var available_food = 0
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid]:
            available_food += CityData.city_storage.get(pid, 0)
    if available_food < cost:
        main_map.hud.show_message("Недостаточно еды! Нужно %d, есть %d" % [cost, available_food])
        return false

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

    for hex in chunk:
        if hex.row >= 0 and hex.row < main_map.map_rows and hex.col >= 0 and hex.col < main_map.map_cols:
            main_map.tile_data[hex.row][hex.col]["in_influence"] = true
            hexes_bought += 1

    current_chunk = []
    emit_signal("territory_expanded", chunk[0].row, chunk[0].col, cost)
    return true

func _chunk_equals(a: Array, b: Array) -> bool:
    if a.size() != b.size():
        return false
    for i in range(a.size()):
        if a[i].row != b[i].row or a[i].col != b[i].col:
            return false
    return true

func _get_neighbors(row: int, col: int) -> Array:
    var neighbors = []
    var directions = []
    if row % 2 == 0:
        directions = [
            {"r": 0, "c": - 1}, {"r": 0, "c": 1},
            {"r": - 1, "c": - 1}, {"r": - 1, "c": 0},
            {"r": 1, "c": - 1}, {"r": 1, "c": 0}
        ]
    else:
        directions = [
            {"r": 0, "c": - 1}, {"r": 0, "c": 1},
            {"r": - 1, "c": 0}, {"r": - 1, "c": 1},
            {"r": 1, "c": 0}, {"r": 1, "c": 1}
        ]
    for d in directions:
        neighbors.append({"row": row + d.r, "col": col + d.c})
    return neighbors

func is_hovering_region() -> bool:
    return current_hover_hex != null
