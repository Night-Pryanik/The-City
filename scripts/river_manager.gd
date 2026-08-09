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

    # --- Принудительный выход на границу ---
    # Если путь не достиг border vertex, а достаточно длинный,
    # "жёстко" движемся к ближайшей border vertex по ребрам
    var best_key = ""
    if path.size() >= MIN_RIVER_LENGTH and not border_vertices.has(current_key):
        var last_pos = path[path.size() - 1]
        var best_dist_sq = INF
        for bv in border_vertices:
            if visited.has(bv):
                continue
            var dist_sq = last_pos.distance_squared_to(vertex_positions[bv])
            if dist_sq < best_dist_sq:
                best_dist_sq = dist_sq
                best_key = bv
        if best_key != "" and best_key != current_key:
            var target_pos = vertex_positions[best_key]
            var hard_prev = prev_key
            var hard_current = current_key
            var hard_step = 0
            while hard_current != best_key and hard_step < 30:
                hard_step += 1
                var hard_candidates = []
                for n in neighbors_map[hard_current]:
                    if n == hard_prev or visited.has(n):
                        continue
                    hard_candidates.append(n)
                if hard_candidates.is_empty():
                    break
                # Выбираем соседа, ближайшего к цели
                var chosen_n = ""
                var chosen_dist = INF
                for n in hard_candidates:
                    var n_dist = vertex_positions[n].distance_squared_to(target_pos)
                    if n_dist < chosen_dist:
                        chosen_dist = n_dist
                        chosen_n = n
                if chosen_n == "":
                    break
                path.append(vertex_positions[chosen_n])
                visited[chosen_n] = true
                hard_prev = hard_current
                hard_current = chosen_n

    # Гарантируем выход на границу: добавляем border vertex,
    # если "жёсткий" путь не достиг цели (например, застрял
    # внутри из‑за того, что все соседи уже посещены)
    if best_key != "" and not visited.has(best_key):
        path.append(vertex_positions[best_key])

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
