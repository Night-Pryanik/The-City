# river_manager.gd
# Менеджер рек: генерирует визуальные реки, проходящие по вершинам гексов
# от одной границы карты к другой (или к той же самой границе).
# Реки — чисто визуальный элемент на этом этапе.
@tool
extends Node

# --- Константы ---
const MIN_RIVER_LENGTH := 8 # Минимальное количество точек у реки
const MAX_WALK_STEPS := 100 # Максимальное число шагов при построении пути
const MAX_TURN_ANGLE_DEG := 60.0 # Максимальный угол поворота за один шаг
const MAX_TURN_ANGLE_SOFT_DEG := 90.0 # Запасной угол при застревании
const MIN_LENGTH_FOR_EXIT := 8 # Минимальная длина пути для попытки выхода на границу
const NUM_RIVER_ATTEMPTS := 4 # Попыток построить одну реку
const NUM_RIVERS_MIN := 1 # Минимальное количество рек
const NUM_RIVERS_MAX := 2 # Максимальное количество рек

const RIVER_COLOR := Color(26.0 / 255.0, 95.0 / 255.0, 180.0 / 255.0, 0.9) # Тёмно-синее тело реки (#1a5fb4)
const RIVER_WIDTH := 6.0 # Толщина тела реки
const RIVER_SHORE_COLOR := Color(98.0 / 255.0, 160.0 / 255.0, 234.0 / 255.0, 0.25) # Лёгкая подкраска берегов
const RIVER_SHORE_WIDTH := 10.0 # Толщина береговой подложки
const RIVER_HIGHLIGHT_COLOR := Color(98.0 / 255.0, 160.0 / 255.0, 234.0 / 255.0, 0.95) # Светло-голубой блик (#62a0ea)
const RIVER_HIGHLIGHT_WIDTH := 3.0 # Толщина блика по воде

var rivers: Array = [] # Array of Array of Vector2 (world-координаты точек каждой реки)


# -------------------------------------------------------
# Главный метод: генерирует реки на карте
# -------------------------------------------------------
func generate_rivers(rows: int, cols: int, radius: float) -> void:
    rivers = []
    if rows < 3 or cols < 3:
        return

    var graph = _build_vertex_graph(rows, cols, radius)
    var border_vertices = _find_border_vertices(graph, rows, cols)

    if border_vertices.is_empty():
        return

    var num_rivers = randi_range(NUM_RIVERS_MIN, NUM_RIVERS_MAX)
    for _i in range(num_rivers):
        var river = _try_generate_river(graph, border_vertices, rows, cols, radius)
        if river.size() >= MIN_RIVER_LENGTH:
            rivers.append(river)


# -------------------------------------------------------
# Пытается сгенерировать одну реку, делая несколько попыток
# с разными случайными точками входа
# -------------------------------------------------------
func _try_generate_river(graph: Dictionary, border_vertices: Array, rows: int, cols: int, radius: float) -> Array:
    for _attempt in range(NUM_RIVER_ATTEMPTS):
        var river = _generate_river(graph, border_vertices, rows, cols, radius)
        if river.size() >= MIN_RIVER_LENGTH:
            return river
    return []


# -------------------------------------------------------
# Строит "граф вершин": узлы = уникальные точки world-координат,
# ребра = соединения через соседние вершины внутри гексов.
# -------------------------------------------------------
func _build_vertex_graph(rows: int, cols: int, radius: float) -> Dictionary:
    var vertex_positions: Dictionary = {} # key -> Vector2
    var vertex_hexes: Dictionary = {} # key -> Array of {row, col, vidx}

    for row in range(rows):
        for col in range(cols):
            for vidx in range(6):
                var pos = HexUtils.hex_vertex(row, col, vidx, radius)
                var key = _vertex_key(pos)
                if not vertex_positions.has(key):
                    vertex_positions[key] = pos
                    vertex_hexes[key] = []
                vertex_hexes[key].append({"row": row, "col": col, "vidx": vidx})

    # Граф соседства: для каждой вершины соседями являются
    # вершины (vidx-1)%6 и (vidx+1)%6 в каждом гексе, содержащем вершину
    var neighbors: Dictionary = {}
    for vkey in vertex_positions.keys():
        var nbrs: Dictionary = {}
        var hex_list = vertex_hexes[vkey]
        for hex_info in hex_list:
            for delta in [-1, 1]:
                var nvi = (hex_info.vidx + delta) % 6
                var npos = HexUtils.hex_vertex(hex_info.row, hex_info.col, nvi, radius)
                var nkey = _vertex_key(npos)
                if nkey != vkey:
                    nbrs[nkey] = true
        neighbors[vkey] = nbrs.keys()

    return {
        "positions": vertex_positions,
        "neighbors": neighbors,
        "hexes": vertex_hexes
    }


# -------------------------------------------------------
# Округление позиции для создания стабильного ключа вершины
# -------------------------------------------------------
func _vertex_key(pos: Vector2) -> String:
    return "%d_%d" % [roundi(pos.x * 100.0), roundi(pos.y * 100.0)]


# -------------------------------------------------------
# Находит вершины, которые находятся ПРЯМО на границе карты,
# т.е. их x или y совпадает с минимальной/максимальной
# границей по координатам всех вершин графа.
# -------------------------------------------------------
func _find_border_vertices(graph: Dictionary, _rows: int, _cols: int) -> Array:
    var vertex_positions: Dictionary = graph["positions"]
    var border_keys: Array = []

    if vertex_positions.is_empty():
        return border_keys

    # --- Границы карты по координатам вершин ---
    var min_x = INF
    var max_x = - INF
    var min_y = INF
    var max_y = - INF
    for pos in vertex_positions.values():
        min_x = min(min_x, pos.x)
        max_x = max(max_x, pos.x)
        min_y = min(min_y, pos.y)
        max_y = max(max_y, pos.y)

    # Вершина — "на краю", если она совпадает с одной из границ
    var eps: float = 0.1
    for vkey in vertex_positions.keys():
        var pos = vertex_positions[vkey]
        if abs(pos.x - min_x) <= eps or abs(pos.x - max_x) <= eps or \
           abs(pos.y - min_y) <= eps or abs(pos.y - max_y) <= eps:
            border_keys.append(vkey)

    return border_keys


# -------------------------------------------------------
# Генерирует одну реку: A* поиск пути между двумя случайными
# граничными вершинами с фильтрацией по углу поворота.
# -------------------------------------------------------
func _generate_river(graph: Dictionary, border_vertices: Array, rows: int, cols: int, radius: float) -> Array:
    var vertex_positions: Dictionary = graph["positions"]
    var neighbors_map: Dictionary = graph["neighbors"]

    if border_vertices.size() < 2:
        return []

    # Выбираем стартовую и целевую граничные вершины случайным образом
    var start_idx = randi() % border_vertices.size()
    var goal_idx = randi() % border_vertices.size()
    while goal_idx == start_idx:
        goal_idx = randi() % border_vertices.size()

    var start_key = border_vertices[start_idx]
    var goal_key = border_vertices[goal_idx]

    # Ищем путь через A* без запрещённых вершин
    var path_keys = _find_path_astar(start_key, goal_key, graph, {}, MAX_TURN_ANGLE_DEG)

    if path_keys.is_empty():
        return []

    # Проверяем минимальную длину
    if path_keys.size() < MIN_RIVER_LENGTH:
        return []

    # Преобразуем ключи в координаты
    var path: Array = []
    for k in path_keys:
        path.append(vertex_positions[k])

    return path


# -------------------------------------------------------
# A* поиск пути между двумя вершинами графа с фильтрацией
# по углу поворота. Возвращает массив ключей вершин или пустой массив.
# -------------------------------------------------------
func _find_path_astar(start_key: String, goal_key: String, graph: Dictionary, forbidden_keys: Dictionary, max_turn_angle_deg: float) -> Array:
    var vertex_positions: Dictionary = graph["positions"]
    var neighbors_map: Dictionary = graph["neighbors"]

    var open_set: Array = [start_key]
    var came_from: Dictionary = {}
    var g_score: Dictionary = {start_key: 0.0}
    var f_score: Dictionary = {start_key: _heuristic(start_key, goal_key, vertex_positions)}

    while not open_set.is_empty():
        # Извлекаем узел с минимальным f_score
        open_set.sort_custom(func(a, b):
            var fa = f_score.get(a, INF)
            var fb = f_score.get(b, INF)
            return fa < fb)
        var current = open_set.pop_front()

        if current == goal_key:
            return _reconstruct_path(came_from, current)

        var current_pos = vertex_positions[current]
        var dir = Vector2.ZERO
        if came_from.has(current):
            var prev_key = came_from[current]
            dir = (current_pos - vertex_positions[prev_key]).normalized()
        else:
            # Для стартовой вершины направление к цели
            dir = (vertex_positions[goal_key] - current_pos).normalized()

        # Соседи
        var candidates: Array = []
        for n in neighbors_map[current]:
            if forbidden_keys.has(n):
                continue
            candidates.append(n)

        # Фильтруем по углу
        var valid: Array = _filter_by_angle(candidates, current_pos, dir, vertex_positions, max_turn_angle_deg)
        if valid.is_empty():
            valid = _filter_by_angle(candidates, current_pos, dir, vertex_positions, max_turn_angle_deg + 30.0)
            if valid.is_empty():
                continue

        for neighbor in valid:
            var tentative_g = g_score[current] + current_pos.distance_to(vertex_positions[neighbor])
            if tentative_g < g_score.get(neighbor, INF):
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                f_score[neighbor] = tentative_g + _heuristic(neighbor, goal_key, vertex_positions)
                if neighbor not in open_set:
                    open_set.append(neighbor)

    return []


func _heuristic(a_key: String, b_key: String, vertex_positions: Dictionary) -> float:
    return vertex_positions[a_key].distance_to(vertex_positions[b_key])


func _reconstruct_path(came_from: Dictionary, current: String) -> Array:
    var total_path: Array = [current]
    while came_from.has(current):
        current = came_from[current]
        total_path.push_front(current)
    return total_path


# -------------------------------------------------------
# Фильтрует кандидатов по углу поворота относительно dir
# -------------------------------------------------------
func _filter_by_angle(candidates: Array, current_pos: Vector2, dir: Vector2,
        vertex_positions: Dictionary, max_angle_deg: float) -> Array:
    var valid: Array = []
    var max_angle_rad = deg_to_rad(max_angle_deg)
    for n in candidates:
        var ndir = (vertex_positions[n] - current_pos).normalized()
        var angle = abs(_signed_angle(dir, ndir))
        if angle <= max_angle_rad + 0.02:
            valid.append(n)
    return valid


# -------------------------------------------------------
# Знаковый угол между двумя векторами (в радианах, [-PI, PI])
# -------------------------------------------------------
func _signed_angle(a: Vector2, b: Vector2) -> float:
    return a.angle_to(b)


# -------------------------------------------------------
# Возвращает список рек (массив точек) — для рендеринга и сохранения
# -------------------------------------------------------
func get_rivers() -> Array:
    return rivers


# -------------------------------------------------------
# Сериализует реки для сохранения (Vector2 -> [x, y])
# -------------------------------------------------------
func serialize_rivers() -> Array:
    var result: Array = []
    for river in rivers:
        var pts: Array = []
        for pt in river:
            pts.append([pt.x, pt.y])
        result.append(pts)
    return result


# -------------------------------------------------------
# Загружает реки из сохранённых данных
# -------------------------------------------------------
func load_rivers(river_data: Array) -> void:
    # Если нет данных для загрузки — НЕ очищаем, чтобы не стирать
    # реки, сгенерированные в _initialize_map() для новой игры
    if river_data == null or river_data.is_empty():
        return
    rivers = []
    for river_pts in river_data:
        var river: Array = []
        for pt in river_pts:
            river.append(Vector2(float(pt[0]), float(pt[1])))
        rivers.append(river)

func mark_river_edges(tile_data: Array, rows: int, cols: int, radius: float) -> void:
    if tile_data == null or tile_data.size() == 0:
        return

    var graph = _build_vertex_graph(rows, cols, radius)
    var vertex_hexes = graph["hexes"]

    # Очистим существующие river_edges, если они есть
    for row in range(rows):
        for col in range(cols):
            var tile = tile_data[row][col]
            if tile != null:
                tile["river_edges"] = []

    for river in rivers:
        if river.size() < 2:
            continue
        var prev_pos = river[0]
        var prev_key = _vertex_key(prev_pos)
        for i in range(1, river.size()):
            var cur_pos = river[i]
            var cur_key = _vertex_key(cur_pos)
            if not vertex_hexes.has(prev_key) or not vertex_hexes.has(cur_key):
                prev_pos = cur_pos
                prev_key = cur_key
                continue
            var prev_hexes = vertex_hexes[prev_key]
            var cur_hexes = vertex_hexes[cur_key]
            var common_hexes = []
            for prev_hex in prev_hexes:
                for cur_hex in cur_hexes:
                    if prev_hex.row == cur_hex.row and prev_hex.col == cur_hex.col:
                        common_hexes.append({"row": prev_hex.row, "col": prev_hex.col, "v1": prev_hex.vidx, "v2": cur_hex.vidx})
            for info in common_hexes:
                var row = info.row
                var col = info.col
                var v1 = info.v1
                var v2 = info.v2
                var edge_index = -1
                if (v1 + 1) % 6 == v2:
                    edge_index = v1
                elif (v2 + 1) % 6 == v1:
                    edge_index = v2
                if edge_index >= 0:
                    var tile = tile_data[row][col]
                    if tile != null:
                        var edges = tile.get("river_edges", [])
                        if edge_index not in edges:
                            edges.append(edge_index)
                            tile["river_edges"] = edges
            prev_pos = cur_pos
            prev_key = cur_key