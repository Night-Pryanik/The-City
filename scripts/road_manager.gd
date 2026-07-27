# road_manager.gd
extends Node

# Храним дороги как словарь: { "row,col": {"row,col": true, ...}, ... }
# Это означает, что гекс (row,col) соединён дорогой с соседним (row2,col2)
var road_connections: Dictionary = {}

# Список "подключённых" гексов (те, к которым уже есть дорога)
var connected_hexes: Dictionary = {}
var city_row: int = 0
var city_col: int = 0

# Инициализация после генерации карты
func initialize(new_city_row: int, new_city_col: int):
    self.city_row = new_city_row
    self.city_col = new_city_col
    var key = str(new_city_row) + "," + str(new_city_col)
    connected_hexes[key] = true

func rebuild_roads_from_existing(tile_data: Array, region_rows: int, region_cols: int):
    for row in range(region_rows):
        for col in range(region_cols):
            var tile = tile_data[row][col]
            if tile != null and tile.get("improvement", null) != null:
                build_road_from(row, col, tile_data, region_rows, region_cols)

# Прокладывает дорогу от нового улучшения до ближайшего подключённого гекса
func build_road_from(start_row: int, start_col: int, tile_data: Array, region_rows: int, region_cols: int):
    var start_key = str(start_row) + "," + str(start_col)
    if connected_hexes.has(start_key):
        return  # уже подключён

    # Находим ближайший подключённый гекс
    var best_path = _find_path_to_connected(start_row, start_col, tile_data, region_rows, region_cols)

    if best_path.is_empty():
        return

    # Добавляем все гексы пути в connected_hexes и строим рёбра
    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        var from_key = str(from_hex.row) + "," + str(from_hex.col)
        var to_key = str(to_hex.row) + "," + str(to_hex.col)

        # Добавляем двустороннюю связь
        if not road_connections.has(from_key):
            road_connections[from_key] = {}
        road_connections[from_key][to_key] = true

        if not road_connections.has(to_key):
            road_connections[to_key] = {}
        road_connections[to_key][from_key] = true

        connected_hexes[from_key] = true
        connected_hexes[to_key] = true

# Простой поиск пути к ближайшему подключённому гексу (BFS)
func _find_path_to_connected(start_row: int, start_col: int, _tile_data: Array, region_rows: int, region_cols: int) -> Array:
    var queue = []
    var visited = {}
    var parent = {}

    var start_key = str(start_row) + "," + str(start_col)
    queue.append({"row": start_row, "col": start_col})
    visited[start_key] = true

    while queue.size() > 0:
        var current = queue.pop_front()
        var cur_key = str(current.row) + "," + str(current.col)

        # Проверяем, подключён ли этот гекс
        if connected_hexes.has(cur_key):
            # Восстанавливаем путь
            var path = []
            var node = cur_key
            while node != start_key:
                var parts = node.split(",")
                path.push_front({"row": int(parts[0]), "col": int(parts[1])})
                node = parent[node]
            path.push_front({"row": start_row, "col": start_col})
            return path

        # Соседи (6 направлений для odd-r сетки)
        var neighbors = _get_neighbors(current.row, current.col, region_rows, region_cols)
        for n in neighbors:
            var n_key = str(n.row) + "," + str(n.col)
            if not visited.has(n_key):
                visited[n_key] = true
                parent[n_key] = cur_key
                queue.append(n)

    return []  # путь не найден

# Получение соседей для odd-r гексагональной сетки
func _get_neighbors(row: int, col: int, max_rows: int, max_cols: int) -> Array:
    var neighbors = []
    var directions = [
        {"r": 0, "c": -1}, {"r": 0, "c": 1},
        {"r": -1, "c": 0}, {"r": 1, "c": 0},
        {"r": -1, "c": 1}, {"r": 1, "c": -1}
    ]
    # Корректировка для odd-r offset
    if row % 2 == 1:
        directions = [
            {"r": 0, "c": -1}, {"r": 0, "c": 1},
            {"r": -1, "c": 0}, {"r": 1, "c": 0},
            {"r": -1, "c": 1}, {"r": 1, "c": 1}
        ]

    for d in directions:
        var nr = row + d.r
        var nc = col + d.c
        if nr >= 0 and nr < max_rows and nc >= 0 and nc < max_cols:
            neighbors.append({"row": nr, "col": nc})
    return neighbors

# Проверка, есть ли дорога между двумя соседними гексами
func has_road_between(row1: int, col1: int, row2: int, col2: int) -> bool:
    var key1 = str(row1) + "," + str(col1)
    if road_connections.has(key1):
        return road_connections[key1].has(str(row2) + "," + str(col2))
    return false
