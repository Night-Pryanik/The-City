# road_manager.gd
extends Node

# Храним дороги как Set строк в формате "row1,col1|row2,col2" (каноническое направление)
# Каноническое = с меньшей суммой row+col, или если равны, то с меньшим col
var road_segments: Dictionary = {}

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
func build_road_from(
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int
):
    var start_key = str(start_row) + "," + str(start_col)
    if connected_hexes.has(start_key):
        return

    # Водные улучшения (например, рыбацкие лодки) не прокладывают дорогу по воде:
    # доступ к водному ресурсу обеспечивает пристань (harbor), стоящая на берегу,
    # к которой дорога строится штатно как к обычному наземному улучшению.
    if start_row >= 0 and start_row < tile_data.size() \
            and start_col >= 0 and start_col < tile_data[start_row].size():
        var start_tile = tile_data[start_row][start_col]
        if start_tile != null and MapHelpers.is_water_terrain(start_tile.get("terrain", "")):
            return

    var best_path = _find_path_dijkstra(
        start_row, start_col, tile_data, region_rows, region_cols
    )
    if best_path.is_empty():
        return

    # Гарантируем, что путь состоит только из соседних гексов
    if not _validate_path(best_path):
        printerr("Ошибка: путь содержит несоседние гексы!")
        return

    # Добавляем все сегменты дороги
    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        _add_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col)
        connected_hexes[str(from_hex.row) + "," + str(from_hex.col)] = true
        connected_hexes[str(to_hex.row) + "," + str(to_hex.col)] = true

# Добавляет сегмент дороги в каноническом направлении (без дубликатов)
func _add_road_segment(row1: int, col1: int, row2: int, col2: int):
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    road_segments[key] = true

# Получает канонический ключ для пары гексов
func _get_canonical_road_key(row1: int, col1: int, row2: int, col2: int) -> String:
    var sum1 = row1 + col1
    var sum2 = row2 + col2
    if sum1 < sum2 or (sum1 == sum2 and col1 < col2):
        return "%d,%d|%d,%d" % [row1, col1, row2, col2]
    return "%d,%d|%d,%d" % [row2, col2, row1, col1]

# Валидирует, что все соседние элементы в пути являются соседями
func _validate_path(path: Array) -> bool:
    for i in range(path.size() - 1):
        var curr = path[i]
        var next = path[i + 1]
        if not _are_neighbors(curr.row, curr.col, next.row, next.col):
            return false
    return true

# Dijkstra с приоритетной очередью для поиска кратчайшего пути
func _find_path_dijkstra(
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int
) -> Array:
    var visited = {}
    var parent = {}
    var cost_so_far = {}
    var start_key = str(start_row) + "," + str(start_col)
    
    # Инициализация
    cost_so_far[start_key] = 0
    parent[start_key] = null
    
    var current_key = start_key
    
    while true:
        var cur_row = int(current_key.split(",")[0])
        var cur_col = int(current_key.split(",")[1])
        
        # Проверяем, подключён ли текущий гекс к сети
        if connected_hexes.has(current_key) and current_key != start_key:
            # Восстанавливаем путь
            return _reconstruct_path(current_key, parent)
        
        visited[current_key] = true
        
        var neighbors = _get_neighbors(cur_row, cur_col, region_rows, region_cols)
        for n in neighbors:
            var n_key = str(n.row) + "," + str(n.col)
            
            if visited.has(n_key):
                continue

            var tile = tile_data[n.row][n.col]
            if tile == null or MapHelpers.is_water_terrain(tile.get("terrain", "plain")):
                continue
            var terrain_id = tile.get("terrain", "plain")
            var move_cost = 1
            if GameData.terrains.has(terrain_id):
                move_cost = GameData.terrains[terrain_id].get("move_cost", 1)
            
            var new_cost = cost_so_far[current_key] + move_cost
            if not cost_so_far.has(n_key) or new_cost < cost_so_far[n_key]:
                cost_so_far[n_key] = new_cost
                parent[n_key] = current_key
        
        # Выбираем следующий узел с минимальной стоимостью
        var min_cost = INF
        var next_key = null
        for key in cost_so_far.keys():
            if not visited.has(key) and cost_so_far[key] < min_cost:
                min_cost = cost_so_far[key]
                next_key = key
        
        if next_key == null:
            # Путь не найден
            return []
        
        current_key = next_key
    
    # Никогда не должны достичь этой точки
    return []

# Восстанавливает путь от конца к началу
func _reconstruct_path(end_key: String, parent: Dictionary) -> Array:
    var path = []
    var current_key = end_key
    
    while current_key != null:
        var parts = current_key.split(",")
        path.push_front({"row": int(parts[0]), "col": int(parts[1])})
        current_key = parent.get(current_key, null)
    
    return path

# Проверяет, являются ли два гекса соседями
func _are_neighbors(row1: int, col1: int, row2: int, col2: int) -> bool:
    var neighbors = _get_neighbors(row1, col1, 999, 999)
    for n in neighbors:
        if n.row == row2 and n.col == col2:
            return true
    return false

# Получение соседей для odd-r гексагональной сетки
func _get_neighbors(row: int, col: int, max_rows: int, max_cols: int) -> Array:
    var neighbors = []
    var directions = []
    
    # Для even rows (row % 2 == 0)
    if row % 2 == 0:
        directions = [
            {"r": 0, "c": - 1}, # W
            {"r": 0, "c": 1}, # E
            {"r": - 1, "c": - 1}, # NW
            {"r": - 1, "c": 0}, # NE
            {"r": 1, "c": - 1}, # SW
            {"r": 1, "c": 0} # SE
        ]
    else:
        # Для odd rows (row % 2 == 1)
        directions = [
            {"r": 0, "c": - 1}, # W
            {"r": 0, "c": 1}, # E
            {"r": - 1, "c": 0}, # NW
            {"r": - 1, "c": 1}, # NE
            {"r": 1, "c": 0}, # SW
            {"r": 1, "c": 1} # SE
        ]

    for d in directions:
        var nr = row + d.r
        var nc = col + d.c
        if nr >= 0 and nr < max_rows and nc >= 0 and nc < max_cols:
            neighbors.append({"row": nr, "col": nc})
    return neighbors

# Проверка, есть ли дорога между двумя гексами
func has_road_between(row1: int, col1: int, row2: int, col2: int) -> bool:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    return road_segments.has(key)

# Получить все сегменты дорог (для отладки)
func get_all_road_segments() -> Dictionary:
    return road_segments.duplicate()
