# expansion_manager.gd
extends Node

# Еда за освоение — фиксированная, небольшая. Обоснование: поселенцы
# запасаются едой перед походом в новые регионы. Основная стоимость
# освоения — ТРУД (см. expansion_cost в terrains.json), который
# накапливается через стройку в build_manager.
const FOOD_COST_PER_HEX = 5

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

# Возвращает стоимость ТРУДА для освоения одного гекса.
# Базовое значение берётся из expansion_cost террейна (теперь это труд).
# Множитель за количество купленных гексов убран: труд должен оставаться
# «умеренным» и не раздуваться с ростом города.
func get_hex_cost(row: int, col: int) -> int:
    var tile = main_map.tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    var base_cost = 2
    if GameData.terrains.has(terrain_id):
        base_cost = GameData.terrains[terrain_id].get("expansion_cost", 2)
    # Модификаторы технологий (target = "construction_cost", см. data/modifiers.json)
    # также снижают стоимость освоения территории (труд накапливается через стройку).
    return int(ceil(float(base_cost) * MapHelpers.get_construction_cost_mult()))

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

# Стоимость ТРУДА всего чанка = сумма труда по гексам.
func get_chunk_cost(chunk: Array) -> int:
    var total = 0
    for hex in chunk:
        total += get_hex_cost(hex.row, hex.col)
    return total

# Стоимость ЕДЫ всего чанка — фиксированная, небольшая.
func get_chunk_food_cost(chunk: Array) -> int:
    return chunk.size() * FOOD_COST_PER_HEX

# Запускает освоение чанка. Еда списывается сразу (фиксированная, небольшая),
# а труд накапливается через стройку в build_manager (прогресс во времени).
func handle_action(chunk: Array, food_cost: int, work_cost: int) -> bool:
    # --- Проверка и списание еды (запас поселенцев перед походом) ---
    var available_food = 0
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid]:
            available_food += CityData.city_storage.get(pid, 0)
    if available_food < food_cost:
        main_map.hud.show_message("Недостаточно еды! Нужно %d, есть %d" % [food_cost, available_food])
        return false

    var remaining = food_cost
    var active_food = []
    for pid in CityData.city_food_pool:
        if CityData.city_food_pool[pid] and CityData.city_storage.get(pid, 0) > 0:
            active_food.append(pid)
    while remaining > 0 and active_food.size() > 0:
        var pid = active_food[randi() % active_food.size()]
        CityData.remove_from_storage(pid, 1, "best")
        remaining -= 1
        if CityData.city_storage.get(pid, 0) <= 0:
            active_food.erase(pid)

    # --- Запуск стройки освоения (труд накапливается во времени) ---
    var bm = main_map.build_manager
    if bm and bm.has_method("start_expansion_build"):
        return bm.start_expansion_build(chunk, work_cost)
    # Fallback: если build_manager недоступен — осваиваем мгновенно.
    _complete_expansion(chunk)
    return true

# Обработчик завершения стройки освоения: труд накоплен — присоединяем чанк.
# Подключён в main_map._ready() на сигнал build_manager.expansion_build_completed.
func on_expansion_build_completed(chunk: Array):
    _complete_expansion(chunk)

# Завершает освоение чанка: помечает гексы как принадлежащие Кольцу Влияния.
func _complete_expansion(chunk: Array):
    for hex in chunk:
        if hex.row >= 0 and hex.row < main_map.map_rows and hex.col >= 0 and hex.col < main_map.map_cols:
            main_map.tile_data[hex.row][hex.col]["in_influence"] = true
            hexes_bought += 1
    current_chunk = []
    emit_signal("territory_expanded", chunk[0].row, chunk[0].col, get_chunk_cost(chunk))

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
