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
const MIN_LENGTH_FOR_EXIT := 4 # Минимальная длина пути для попытки выхода на границу
const NUM_RIVER_ATTEMPTS := 4 # Попыток построить одну реку
const NUM_RIVERS_MIN := 1 # Минимальное количество рек
const NUM_RIVERS_MAX := 2 # Максимальное количество рек

const RIVER_COLOR := Color(0.2, 0.55, 1.0, 0.8) # Синий цвет реки
const RIVER_WIDTH := 5.0 # Толщина линии реки

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
# Находит все вершины, граничащие с краем карты
# (вершина принадлежит хотя бы одному гексу на границе массива)
# -------------------------------------------------------
func _find_border_vertices(graph: Dictionary, rows: int, cols: int) -> Array:
    var border_keys: Array = []
    for vkey in graph["hexes"].keys():
        var hex_list = graph["hexes"][vkey]
        for hex_info in hex_list:
            if hex_info.row == 0 or hex_info.row == rows - 1 or \
               hex_info.col == 0 or hex_info.col == cols - 1:
                border_keys.append(vkey)
                break
    return border_keys


# -------------------------------------------------------
# Генерирует одну реку: случайное блуждание по графу вершин
# с ограничением угла поворота 60°.
# -------------------------------------------------------
func _generate_river(graph: Dictionary, border_vertices: Array, rows: int, cols: int, radius: float) -> Array:
    var vertex_positions: Dictionary = graph["positions"]
    var neighbors_map: Dictionary = graph["neighbors"]

    var map_center = HexUtils.hex_center(rows / 2, cols / 2, radius)

    # --- Точка входа: случайная вершина на границе карты ---
    var entry_key = border_vertices[randi() % border_vertices.size()]
    var entry_pos = vertex_positions[entry_key]

    # --- Начальное направление: в сторону центра карты ---
    var inward_dir = (map_center - entry_pos).normalized()

    # --- Выбираем первого соседа, идущего "внутрь" ---
    var inward_candidates: Array = []
    for n in neighbors_map[entry_key]:
        var ndir = (vertex_positions[n] - entry_pos).normalized()
        if ndir.dot(inward_dir) > 0:
            inward_candidates.append(n)
    if inward_candidates.is_empty():
        inward_candidates = neighbors_map[entry_key]
    if inward_candidates.is_empty():
        return []

    var first_key = inward_candidates[randi() % inward_candidates.size()]
    var dir = (vertex_positions[first_key] - entry_pos).normalized()

    # --- Путь реки ---
    var path: Array = [entry_pos, vertex_positions[first_key]]
    var visited: Dictionary = {entry_key: true, first_key: true}
    var prev_key = entry_key
    var current_key = first_key

    var step = 0
    while step < MAX_WALK_STEPS:
        step += 1
        var current_pos = vertex_positions[current_key]

        # Кандидаты: соседи, не предыдущая вершина и не посещённые
        var candidates: Array = []
        for n in neighbors_map[current_key]:
            if n == prev_key or visited.has(n):
                continue
            candidates.append(n)

        if candidates.is_empty():
            break

        # Фильтруем по углу (≤ 60°)
        var valid: Array = _filter_by_angle(candidates, current_pos, dir, vertex_positions, MAX_TURN_ANGLE_DEG)

        if valid.is_empty():
            # Запасной вариант: расширяем угол до 90°
            valid = _filter_by_angle(candidates, current_pos, dir, vertex_positions, MAX_TURN_ANGLE_SOFT_DEG)
            if valid.is_empty():
                break

        # Проверка выхода на границу (только если путь уже достаточно длинный)
        if path.size() >= MIN_LENGTH_FOR_EXIT:
            for n in valid:
                if border_vertices.has(n):
                    path.append(vertex_positions[n])
                    return path

        # Сортируем кандидатов по возрастанию угла (ближе к "прямо")
        valid.sort_custom(func(a, b):
            var da = abs(_signed_angle(dir, vertex_positions[a] - current_pos))
            var db = abs(_signed_angle(dir, vertex_positions[b] - current_pos))
            return da < db)

        # Выбор следующей вершины:
        # 50% — "прямо" (наименьший угол), 30% — вторая по углу, 20% — случайная
        var chosen
        var roll = randf()
        if roll < 0.5:
            chosen = valid[0]
        elif roll < 0.8 and valid.size() > 1:
            chosen = valid[1]
        else:
            chosen = valid[randi() % valid.size()]

        visited[chosen] = true
        dir = (vertex_positions[chosen] - current_pos).normalized()
        prev_key = current_key
        current_key = chosen
        path.append(vertex_positions[chosen])

    return path


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
    rivers = []
    if river_data == null:
        return
    for river_pts in river_data:
        var river: Array = []
        for pt in river_pts:
            river.append(Vector2(float(pt[0]), float(pt[1])))
        rivers.append(river)
