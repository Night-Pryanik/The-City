# river_manager.gd
# Менеджер рек: генерирует речную систему на карте.
#
# Схема генерации (речная система):
#   - Главные реки: исток в горах, устье в озере. Не пересекаются друг с другом.
#   - Притоки: исток в горах (или холмах, если гор мало), впадают в главные
#     реки или в другие притоки (точка слияния). Притоки не впадают в озёра.
#   - Гарантируется, что хотя бы одна река проходит через стартовую область
#     «Кольцо + Регион» (для этого при необходимости генерируется
#     дополнительная главная река через промежуточную вершину внутри области).
#   - Реки не проходят по рёбрам озёрных гексов и их соседей (кроме последнего
#     шага в устье/точку слияния), чтобы река не текла по берегу озера.
#
# Количество рек и минимальные длины берутся из data/map_config.json:
#   num_main_rivers, num_tributaries, min_river_length, min_tributary_length.
#
# Реки и озера дают бонусы к производству ресурсов улучшениями, имеющими доступ к пресной воде.
@tool
extends Node

# --- Константы ---
const MAX_TURN_ANGLE_DEG := 60.0 # Максимальный угол поворота за один шаг
const MAX_TURN_ANGLE_SOFT_DEG := 90.0 # Запасной угол при застревании
const NUM_RIVER_ATTEMPTS := 6 # Попыток построить одну реку

const RIVER_COLOR := Color(26.0 / 255.0, 95.0 / 255.0, 180.0 / 255.0, 0.9) # Тёмно-синее тело реки (#1a5fb4)
const RIVER_WIDTH := 10.0 # Толщина тела реки
const RIVER_SHORE_COLOR := Color(98.0 / 255.0, 160.0 / 255.0, 234.0 / 255.0, 0.25) # Лёгкая подкраска берегов
const RIVER_SHORE_WIDTH := 10.0 # Толщина береговой подложки
const RIVER_HIGHLIGHT_COLOR := Color(98.0 / 255.0, 160.0 / 255.0, 234.0 / 255.0, 0.95) # Светло-голубой блик (#62a0ea)
const RIVER_HIGHLIGHT_WIDTH := 6.0 # Толщина блика по воде

# Стиль притоков: тоньше и светлее, чтобы визуально отличать от главных рек.
const TRIBUTARY_COLOR := Color(70.0 / 255.0, 140.0 / 255.0, 210.0 / 255.0, 0.85) # Светло-синее тело притока
const TRIBUTARY_WIDTH := 6.0 # Толщина тела притока
const TRIBUTARY_SHORE_COLOR := Color(120.0 / 255.0, 180.0 / 255.0, 240.0 / 255.0, 0.2) # Лёгкая подкраска берегов притока
const TRIBUTARY_SHORE_WIDTH := 6.0 # Толщина береговой подложки притока
const TRIBUTARY_HIGHLIGHT_COLOR := Color(130.0 / 255.0, 190.0 / 255.0, 245.0 / 255.0, 0.9) # Светло-голубой блик притока
const TRIBUTARY_HIGHLIGHT_WIDTH := 4.0 # Толщина блика притока

var rivers: Array = [] # Array of Array of Vector2 (world-координаты точек каждой реки)
var main_rivers: Array = [] # Только главные реки (исток в горах, устье в озере)
var tributaries: Array = [] # Только притоки (впадают в главные реки или другие притоки)

# Последний построенный граф вершин. Используется повторно в mark_river_edges(),
# чтобы не строить граф (тысячи вершин) дважды за одну генерацию карты.
var _cached_graph: Dictionary = {}


# -------------------------------------------------------
# Минимальная бинарная куча (priority queue) для A*.
# push/pop за O(log n) вместо sort_custom + pop_front за O(n log n) на шаг.
# -------------------------------------------------------
class PriorityQueue:
    var _keys: Array = []
    var _priorities: Array = []

    func push(key: String, priority: float) -> void:
        _keys.append(key)
        _priorities.append(priority)
        _sift_up(_keys.size() - 1)

    func pop_min() -> String:
        if _keys.is_empty():
            return ""
        var top: String = _keys[0]
        var last_idx: int = _keys.size() - 1
        _keys[0] = _keys[last_idx]
        _priorities[0] = _priorities[last_idx]
        _keys.resize(last_idx)
        _priorities.resize(last_idx)
        if _keys.size() > 1:
            _sift_down(0)
        return top

    func is_empty() -> bool:
        return _keys.is_empty()

    func _sift_up(idx: int) -> void:
        while idx > 0:
            var parent: int = (idx - 1) >> 1
            if _priorities[idx] < _priorities[parent]:
                var tk: String = _keys[idx]
                _keys[idx] = _keys[parent]
                _keys[parent] = tk
                var tp: float = _priorities[idx]
                _priorities[idx] = _priorities[parent]
                _priorities[parent] = tp
                idx = parent
            else:
                break

    func _sift_down(idx: int) -> void:
        var size: int = _keys.size()
        while true:
            var left: int = idx * 2 + 1
            var right: int = left + 1
            var smallest: int = idx
            if left < size and _priorities[left] < _priorities[smallest]:
                smallest = left
            if right < size and _priorities[right] < _priorities[smallest]:
                smallest = right
            if smallest == idx:
                break
            var tk: String = _keys[idx]
            _keys[idx] = _keys[smallest]
            _keys[smallest] = tk
            var tp: float = _priorities[idx]
            _priorities[idx] = _priorities[smallest]
            _priorities[smallest] = tp
            idx = smallest


# -------------------------------------------------------
# Главный метод: генерирует речную систему на карте.
# tile_data — 2D-массив гексов (для определения гор/озёр/холмов).
# region_* — границы стартовой области «Кольцо + Регион» (инклюзивные),
# через которую должна проходить хотя бы одна река.
# -------------------------------------------------------
func generate_rivers(rows: int, cols: int, radius: float, tile_data: Array,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> void:
    rivers = []
    if rows < 3 or cols < 3:
        return

    # Гексы, которые касаются озёр (озёрные гексы и их соседи).
    # Строятся ДО графа, чтобы флаги запрещённых рёбер были предвычислены
    # в самом графе (проверка O(1) во время A* вместо O(гексы^2) на соседа).
    var lake_adjacent_hexes = _build_lake_adjacent_hexes(tile_data, rows, cols)

    var graph = _build_vertex_graph(rows, cols, radius, lake_adjacent_hexes)
    _cached_graph = graph

    # Кандидаты на истоки (горы) и устья главных рек (озёра).
    var mountain_vertices = _find_terrain_vertices(graph, tile_data, "mountain")
    var lake_vertices = _find_terrain_vertices(graph, tile_data, "lake")
    var hill_vertices = _find_terrain_vertices(graph, tile_data, "hill")

    print("RIVER DEBUG: горных вершин=", mountain_vertices.size(), ", озёрных вершин=", lake_vertices.size(), ", холмистых=", hill_vertices.size())

    if mountain_vertices.is_empty() or lake_vertices.is_empty():
        print("RIVER DEBUG: нет гор или озёр, выход")
        return

    # Параметры из конфигурации.
    var cfg: Dictionary = GameData.map_config
    var num_main = int(cfg.get("num_main_rivers", 3))
    var num_trib = int(cfg.get("num_tributaries", 5))
    var min_main_len = int(cfg.get("min_river_length", 8))
    var min_trib_len = int(cfg.get("min_tributary_length", 4))

    var used_vertices: Dictionary = {} # Вершины, уже занятые реками
    main_rivers = []

    # --- Генерация главных рек (гора -> озеро, не пересекаются) ---
    for _i in range(num_main):
        var river = _try_generate_main_river(graph, mountain_vertices, lake_vertices,
                lake_adjacent_hexes, used_vertices, min_main_len)
        if river.size() >= min_main_len:
            _mark_used(river, used_vertices)
            main_rivers.append(river)
    print("RIVER DEBUG: главных рек сгенерировано=", main_rivers.size())

    # --- Гарантия: хотя бы одна река проходит через стартовую область ---
    if not _any_river_in_region(main_rivers, graph,
            region_start_row, region_end_row, region_start_col, region_end_col):
        var forced = _try_generate_forced_river(graph, mountain_vertices, lake_vertices,
                lake_adjacent_hexes, used_vertices, min_main_len,
                region_start_row, region_end_row, region_start_col, region_end_col)
        if forced.size() >= min_main_len:
            _mark_used(forced, used_vertices)
            main_rivers.append(forced)

    # --- Генерация притоков (гора/холм -> занятая вершина, слияние) ---
    tributaries = []
    for _i in range(num_trib):
        var river = _try_generate_tributary(graph, mountain_vertices, hill_vertices,
                lake_vertices, lake_adjacent_hexes, used_vertices, min_trib_len)
        if river.size() >= min_trib_len:
            _mark_used(river, used_vertices)
            tributaries.append(river)

    rivers = main_rivers + tributaries
    print("RIVER DEBUG: всего рек=", rivers.size())


# -------------------------------------------------------
# Пытается сгенерировать одну главную реку: исток в горах, устье в озере.
# Главные реки не пересекаются: A* идёт с forbidden = used_vertices.
# -------------------------------------------------------
func _try_generate_main_river(graph: Dictionary, mountain_vertices: Array,
        lake_vertices: Array, lake_adjacent_hexes: Dictionary,
        used_vertices: Dictionary, min_len: int) -> Array:
    var free_mountains: Array = []
    for vk in mountain_vertices:
        if not used_vertices.has(vk) and not lake_vertices.has(vk) and not _vertex_in_hexes(vk, graph, lake_adjacent_hexes):
            free_mountains.append(vk)
    var free_lakes: Array = []
    for vk in lake_vertices:
        if not used_vertices.has(vk):
            free_lakes.append(vk)
    if free_mountains.is_empty() or free_lakes.is_empty():
        return []

    for _attempt in range(NUM_RIVER_ATTEMPTS):
        var start = free_mountains[randi() % free_mountains.size()]
        var goal = free_lakes[randi() % free_lakes.size()]
        var path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_DEG, {}, lake_adjacent_hexes)
        if path.is_empty():
            path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, {}, lake_adjacent_hexes)
        if path.size() >= min_len:
            return _keys_to_positions(path, graph)
    return []


# -------------------------------------------------------
# Пытается сгенерировать приток: исток в горах (или холмах, если гор мало),
# устье — занятая вершина (точка слияния с любой рекой). Притоки не впадают
# в озёра: озёрные вершины исключаются из merge_keys.
# -------------------------------------------------------
func _try_generate_tributary(graph: Dictionary, mountain_vertices: Array,
        hill_vertices: Array, lake_vertices: Array, lake_adjacent_hexes: Dictionary,
        used_vertices: Dictionary, min_len: int) -> Array:
    if used_vertices.is_empty():
        return []

    # Исток: свободные горные вершины; если их мало — добавляем холмистые.
    var free_sources: Array = []
    for vk in mountain_vertices:
        if not used_vertices.has(vk) and not lake_vertices.has(vk) and not _vertex_in_hexes(vk, graph, lake_adjacent_hexes):
            free_sources.append(vk)
    if free_sources.size() < 3:
        for vk in hill_vertices:
            if not used_vertices.has(vk) and not lake_vertices.has(vk) and not _vertex_in_hexes(vk, graph, lake_adjacent_hexes):
                free_sources.append(vk)
    if free_sources.is_empty():
        return []

    # Устья: занятые вершины, исключая озёрные (притоки не впадают в озёра).
    var merge_keys: Dictionary = used_vertices.duplicate()
    for vk in lake_vertices:
        merge_keys.erase(vk)
    if merge_keys.is_empty():
        return []
    var merge_list: Array = merge_keys.keys()

    for _attempt in range(NUM_RIVER_ATTEMPTS):
        var start = free_sources[randi() % free_sources.size()]
        var goal = merge_list[randi() % merge_list.size()]
        var path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_DEG, merge_keys, lake_adjacent_hexes)
        if path.is_empty():
            path = _find_path_astar(start, goal, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, merge_keys, lake_adjacent_hexes)
        if path.size() >= min_len:
            return _keys_to_positions(path, graph)
    return []


# -------------------------------------------------------
# Принудительно генерирует главную реку, гарантированно проходящую через
# стартовую область. Выбирает гору с одной стороны области и озеро с другой,
# берёт свободную вершину внутри области как промежуточную точку (waypoint)
# и строит путь «гора -> waypoint -> озеро».
# -------------------------------------------------------
func _try_generate_forced_river(graph: Dictionary, mountain_vertices: Array,
        lake_vertices: Array, lake_adjacent_hexes: Dictionary,
        used_vertices: Dictionary, min_len: int,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> Array:
    # Пары сторон: [исток, устье]. Пробуем все комбинации.
    var side_pairs: Array = [
        ["top", "bottom"], ["bottom", "top"],
        ["left", "right"], ["right", "left"]
    ]

    for side_pair in side_pairs:
        var src_side = _vertices_on_side(mountain_vertices, graph, side_pair[0],
                region_start_row, region_end_row, region_start_col, region_end_col)
        var dst_side = _vertices_on_side(lake_vertices, graph, side_pair[1],
                region_start_row, region_end_row, region_start_col, region_end_col)

        var free_src: Array = []
        for vk in src_side:
            if not used_vertices.has(vk) and not lake_vertices.has(vk) and not _vertex_in_hexes(vk, graph, lake_adjacent_hexes):
                free_src.append(vk)
        var free_dst: Array = []
        for vk in dst_side:
            if not used_vertices.has(vk):
                free_dst.append(vk)
        if free_src.is_empty() or free_dst.is_empty():
            continue

        # Свободные вершины внутри области как промежуточные точки.
        var region_vertices = _vertices_in_region(graph,
                region_start_row, region_end_row, region_start_col, region_end_col)
        var free_waypoints: Array = []
        for vk in region_vertices:
            if not used_vertices.has(vk) and not _vertex_in_hexes(vk, graph, lake_adjacent_hexes):
                free_waypoints.append(vk)
        if free_waypoints.is_empty():
            continue

        for _attempt in range(NUM_RIVER_ATTEMPTS):
            var start = free_src[randi() % free_src.size()]
            var goal = free_dst[randi() % free_dst.size()]
            var wp = free_waypoints[randi() % free_waypoints.size()]

            var path1 = _find_path_astar(start, wp, graph, used_vertices, MAX_TURN_ANGLE_DEG, {}, lake_adjacent_hexes)
            if path1.is_empty():
                path1 = _find_path_astar(start, wp, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, {}, lake_adjacent_hexes)
            if path1.is_empty():
                continue

            var path2 = _find_path_astar(wp, goal, graph, used_vertices, MAX_TURN_ANGLE_DEG, {}, lake_adjacent_hexes)
            if path2.is_empty():
                path2 = _find_path_astar(wp, goal, graph, used_vertices, MAX_TURN_ANGLE_SOFT_DEG, {}, lake_adjacent_hexes)
            if path2.is_empty():
                continue

            # Объединяем пути (waypoint не дублируем).
            var combined: Array = path1.duplicate()
            for i in range(1, path2.size()):
                combined.append(path2[i])
            if combined.size() >= min_len:
                return _keys_to_positions(combined, graph)
    return []


# -------------------------------------------------------
# Находит вершины, у которых хотя бы один гекс имеет заданный рельеф.
# -------------------------------------------------------
func _find_terrain_vertices(graph: Dictionary, tile_data: Array, terrain_id: String) -> Array:
    var vertex_hexes: Dictionary = graph["hexes"]
    var result: Array = []
    for vk in vertex_hexes.keys():
        for hex_info in vertex_hexes[vk]:
            if tile_data[hex_info.row][hex_info.col]["terrain"] == terrain_id:
                result.append(vk)
                break
    return result


# -------------------------------------------------------
# Находит гексы, которые касаются озёр: озёрные гексы и их соседи.
# Возвращает словарь с ключами "row_col" -> true.
# -------------------------------------------------------
func _build_lake_adjacent_hexes(tile_data: Array, rows: int, cols: int) -> Dictionary:
    var result: Dictionary = {}

    # Собираем озёрные гексы.
    var lake_hexes: Array = []
    for row in range(rows):
        for col in range(cols):
            if tile_data[row][col]["terrain"] == "lake":
                lake_hexes.append({"row": row, "col": col})

    # Помечаем озёрные гексы и их соседей.
    for lh in lake_hexes:
        result["%d_%d" % [lh.row, lh.col]] = true
        for n in HexUtils.get_neighbors_odd_r(lh.row, lh.col, rows, cols):
            result["%d_%d" % [n.row, n.col]] = true

    return result


# -------------------------------------------------------
# Возвращает true, если вершина принадлежит хотя бы одному гексу из словаря.
# -------------------------------------------------------
func _vertex_in_hexes(vk: String, graph: Dictionary, hexes_dict: Dictionary) -> bool:
    var vertex_hexes: Dictionary = graph["hexes"]
    if not vertex_hexes.has(vk):
        return false
    for hex_info in vertex_hexes[vk]:
        if hexes_dict.has("%d_%d" % [hex_info.row, hex_info.col]):
            return true
    return false


# -------------------------------------------------------
# Возвращает true, если ребро (a_key -> b_key) принадлежит хотя бы одному
# запрещённому гексу (озеро или его сосед).
# -------------------------------------------------------
func _edge_in_forbidden_hexes(a_key: String, b_key: String, vertex_hexes: Dictionary, forbidden_hexes: Dictionary) -> bool:
    if forbidden_hexes.is_empty():
        return false
    if not vertex_hexes.has(a_key) or not vertex_hexes.has(b_key):
        return false
    var a_hexes = vertex_hexes[a_key]
    var b_hexes = vertex_hexes[b_key]
    for ha in a_hexes:
        for hb in b_hexes:
            if ha.row == hb.row and ha.col == hb.col:
                if forbidden_hexes.has("%d_%d" % [ha.row, ha.col]):
                    return true
    return false


# -------------------------------------------------------
# Возвращает вершины из списка, у которых есть гекс на указанной стороне
# от стартовой области (top/bottom/left/right).
# -------------------------------------------------------
func _vertices_on_side(vertices: Array, graph: Dictionary, side: String,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> Array:
    var vertex_hexes: Dictionary = graph["hexes"]
    var result: Array = []
    for vk in vertices:
        for hex_info in vertex_hexes[vk]:
            var ok := false
            if side == "top" and hex_info.row < region_start_row:
                ok = true
            elif side == "bottom" and hex_info.row > region_end_row:
                ok = true
            elif side == "left" and hex_info.col < region_start_col:
                ok = true
            elif side == "right" and hex_info.col > region_end_col:
                ok = true
            if ok:
                result.append(vk)
                break
    return result


# -------------------------------------------------------
# Возвращает все вершины, у которых есть гекс внутри стартовой области.
# -------------------------------------------------------
func _vertices_in_region(graph: Dictionary,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> Array:
    var vertex_hexes: Dictionary = graph["hexes"]
    var result: Array = []
    for vk in vertex_hexes.keys():
        for hex_info in vertex_hexes[vk]:
            if hex_info.row >= region_start_row and hex_info.row <= region_end_row and \
               hex_info.col >= region_start_col and hex_info.col <= region_end_col:
                result.append(vk)
                break
    return result


# -------------------------------------------------------
# Проверяет, проходит ли хотя бы одна река через стартовую область.
# -------------------------------------------------------
func _any_river_in_region(rivers_list: Array, graph: Dictionary,
        region_start_row: int, region_end_row: int,
        region_start_col: int, region_end_col: int) -> bool:
    var vertex_hexes: Dictionary = graph["hexes"]
    for river in rivers_list:
        for pt in river:
            var key = _vertex_key(pt)
            if vertex_hexes.has(key):
                for hex_info in vertex_hexes[key]:
                    if hex_info.row >= region_start_row and hex_info.row <= region_end_row and \
                       hex_info.col >= region_start_col and hex_info.col <= region_end_col:
                        return true
    return false


# -------------------------------------------------------
# Помечает все вершины реки как занятые.
# -------------------------------------------------------
func _mark_used(river: Array, used_vertices: Dictionary) -> void:
    for pt in river:
        used_vertices[_vertex_key(pt)] = true


# -------------------------------------------------------
# Преобразует массив ключей вершин в массив world-координат.
# -------------------------------------------------------
func _keys_to_positions(path_keys: Array, graph: Dictionary) -> Array:
    var positions: Dictionary = graph["positions"]
    var path: Array = []
    for k in path_keys:
        path.append(positions[k])
    return path


# -------------------------------------------------------
# Строит "граф вершин": узлы = уникальные точки world-координат,
# ребра = соединения через соседние вершины внутри гексов.
#
# Оптимизация: флаг "forb" (ребро принадлежит запрещённому гексу у озера)
# предвычисляется здесь ОДИН раз для всех рёбер, поэтому A* проверяет
# запрет за O(1) на соседа вместо перебора гексов обеих вершин.
# -------------------------------------------------------
func _build_vertex_graph(rows: int, cols: int, radius: float, forbidden_hexes: Dictionary = {}) -> Dictionary:
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
    # вершины (vidx-1)%6 и (vidx+1)%6 в каждом гексе, содержащем вершину.
    # Представление — ПАРАЛЛЕЛЬНЫЕ МАССИВЫ (важно для скорости A*):
    #   neighbors[vkey] = Array of String (ключи соседей)
    #   forb_mask[vkey] = Array of bool  (true = ребро лежит в гексе у озера)
    # Это даёт O(1) проверку запрещённого ребра без аллокации словаря на ребро.
    var neighbors: Dictionary = {}
    var forb_mask: Dictionary = {}
    var forbidden_empty := forbidden_hexes.is_empty()
    for vkey in vertex_positions.keys():
        var nbrs: Array = []
        var forbs: Array = []
        var nbr_set: Dictionary = {} # дедупликация соседей
        var hex_list = vertex_hexes[vkey]
        for hex_info in hex_list:
            for delta in [-1, 1]:
                var nvi = (hex_info.vidx + delta) % 6
                var npos = HexUtils.hex_vertex(hex_info.row, hex_info.col, nvi, radius)
                var nkey = _vertex_key(npos)
                if nkey != vkey and not nbr_set.has(nkey):
                    nbr_set[nkey] = true
                    nbrs.append(nkey)
                    forbs.append(false if forbidden_empty else _edge_in_forbidden_hexes(vkey, nkey, vertex_hexes, forbidden_hexes))
        neighbors[vkey] = nbrs
        forb_mask[vkey] = forbs

    return {
        "positions": vertex_positions,
        "neighbors": neighbors,
        "hexes": vertex_hexes,
        "forb": forb_mask
    }


# -------------------------------------------------------
# Округление позиции для создания стабильного ключа вершины
# -------------------------------------------------------
func _vertex_key(pos: Vector2) -> String:
    return "%d_%d" % [roundi(pos.x * 100.0), roundi(pos.y * 100.0)]


# -------------------------------------------------------
# A* поиск пути между двумя вершинами графа с фильтрацией
# по углу поворота. Возвращает массив ключей вершин или пустой массив.
#
# forbidden_keys — вершины, занятые другими реками (нельзя проходить,
# кроме goal_key и merge_keys).
# forbidden_hexes — гексы у озёр (озеро + соседи). Флаги запрещённых рёбер
# предвычислены в графе (поле "forb" — параллельный массив bool).
# Река не может проходить по РЁБРАМ у озёр, кроме последнего шага в устье/
# точку слияния. Чтобы река могла войти в озеро, разрешается один шаг
# снаружи в вершину, соседнюю с устьем (approach), после чего путь обязан
# завершиться в устье.
# merge_keys — вершины, на которых путь может закончиться (точки слияния).
#
# Ключевые оптимизации (замена sort_custom + pop_front исходного кода):
#   - открытый список — бинарная куча (PriorityQueue): push/pop за O(log n);
#   - in_heap + closed_set: устаревшие записи кучи пропускаются, куча не
#     разрастается, каждая вершина обрабатывается ровно один раз;
#   - проверка запрещённых рёбер — O(1) по предвычисленному флагу forb;
#   - angle_to не требует нормализованных векторов — убраны normalized().
# -------------------------------------------------------
func _find_path_astar(start_key: String, goal_key: String, graph: Dictionary, forbidden_keys: Dictionary, max_turn_angle_deg: float, merge_keys: Dictionary = {}, forbidden_hexes: Dictionary = {}) -> Array:
    var vertex_positions: Dictionary = graph["positions"]
    var neighbors_map: Dictionary = graph["neighbors"]
    var forb_mask: Dictionary = graph.get("forb", {})

    # Ограничиваем область поиска bbox-ом вокруг start и goal.
    # Это ускоряет A* в разы на больших картах, не меняя формат данных рек:
    # путь по-прежнему строится по вершинам гексов, поэтому mark_river_edges
    # и весь функционал (бонусы у рек, near_river) работают как раньше.
    var start_pos = vertex_positions[start_key]
    var goal_pos = vertex_positions[goal_key]
    var min_x = minf(start_pos.x, goal_pos.x)
    var max_x = maxf(start_pos.x, goal_pos.x)
    var min_y = minf(start_pos.y, goal_pos.y)
    var max_y = maxf(start_pos.y, goal_pos.y)
    # Запас: 25% от суммы сторон bbox, но не меньше фиксированного минимума,
    # чтобы река могла естественно изгибаться и вливаться в merge-вершины.
    var margin = maxf((max_x - min_x + max_y - min_y) * 0.25, 200.0)
    min_x -= margin
    max_x += margin
    min_y -= margin
    max_y += margin

    # Вершины, через которые река может подойти к устью/слиянию:
    # само устье и его непосредственные соседи. Вход в такую вершину снаружи
    # разрешён (один шаг), после чего путь обязан завершиться в устье.
    var approach_keys: Dictionary = {}
    approach_keys[goal_key] = true
    var goal_nbrs: Array = neighbors_map.get(goal_key, [])
    for n in goal_nbrs:
        approach_keys[n] = true
    for mk in merge_keys.keys():
        approach_keys[mk] = true
        var mk_nbrs: Array = neighbors_map.get(mk, [])
        for n in mk_nbrs:
            approach_keys[n] = true

    var open_set = PriorityQueue.new()
    open_set.push(start_key, _heuristic(start_key, goal_key, vertex_positions))
    var came_from: Dictionary = {}
    var g_score: Dictionary = {start_key: 0.0}
    var closed_set: Dictionary = {}
    var in_heap: Dictionary = {start_key: true}

    var has_merge := not merge_keys.is_empty()
    var has_forbidden := not forbidden_keys.is_empty()
    var has_forb := not forb_mask.is_empty()
    var max_angle_rad = deg_to_rad(max_turn_angle_deg)
    var soft_angle_rad = deg_to_rad(max_turn_angle_deg + 30.0)

    while not open_set.is_empty():
        var current = open_set.pop_min()
        # Ленивое удаление: пропускаем устаревшие записи кучи.
        if not in_heap.has(current):
            continue
        in_heap.erase(current)
        # closed_set — каждая вершина обрабатывается ровно один раз.
        if closed_set.has(current):
            continue
        closed_set[current] = true

        if current == goal_key or (has_merge and merge_keys.has(current)):
            return _reconstruct_path(came_from, current)

        var current_pos = vertex_positions[current]
        var dir = Vector2.ZERO
        if came_from.has(current):
            dir = current_pos - vertex_positions[came_from[current]]
        else:
            # Для стартовой вершины направление к цели
            dir = vertex_positions[goal_key] - current_pos

        # Соседи:
        # 1) Запрещены вершины, занятые другими реками (кроме устья/слияния).
        # 2) Запрещены рёбра с флагом forb, КРОМЕ:
        #    - последнего шага в устье/точку слияния;
        #    - одного шага снаружи в approach-вершину (чтобы войти в озеро).
        #    Переход между двумя approach-вершинами запрещён — это предотвращает
        #    течение реки вдоль берега озера.
        # Отбрасываем соседей за пределами bbox — это и есть основное ускорение.
        var current_is_approach = approach_keys.has(current)
        var candidates: Array = []
        var current_nbrs: Array = neighbors_map[current]
        var current_forbs: Array = forb_mask.get(current, [])
        for i in range(current_nbrs.size()):
            var n: String = current_nbrs[i]
            if has_forbidden and forbidden_keys.has(n) and n != goal_key and not merge_keys.has(n):
                continue
            if has_forb and i < current_forbs.size() and current_forbs[i]:
                if n == goal_key or merge_keys.has(n):
                    pass # последний шаг в устье/слияние разрешён
                elif approach_keys.has(n) and not current_is_approach:
                    pass # вход снаружи в approach-вершину разрешён
                else:
                    continue
            var npos = vertex_positions[n]
            if npos.x < min_x or npos.x > max_x or npos.y < min_y or npos.y > max_y:
                continue
            candidates.append(n)

        # Фильтруем по углу
        var valid: Array = _filter_by_angle(candidates, current_pos, dir, vertex_positions, max_angle_rad)
        if valid.is_empty():
            valid = _filter_by_angle(candidates, current_pos, dir, vertex_positions, soft_angle_rad)
            if valid.is_empty():
                continue

        var g_current = g_score[current]
        for neighbor in valid:
            var tentative_g = g_current + current_pos.distance_to(vertex_positions[neighbor])
            if tentative_g < g_score.get(neighbor, INF):
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                open_set.push(neighbor, tentative_g + _heuristic(neighbor, goal_key, vertex_positions))
                in_heap[neighbor] = true

    return []


func _heuristic(a_key: String, b_key: String, vertex_positions: Dictionary) -> float:
    return vertex_positions[a_key].distance_to(vertex_positions[b_key])


func _reconstruct_path(came_from: Dictionary, current: String) -> Array:
    var total_path: Array = [current]
    while came_from.has(current):
        current = came_from[current]
        total_path.append(current)
    total_path.reverse()
    return total_path


# -------------------------------------------------------
# Фильтрует кандидатов по углу поворота относительно dir.
# max_angle_rad передаётся в радианах (вычисляется один раз в A*).
# angle_to не требует нормализованных векторов — normalized() не нужен.
# -------------------------------------------------------
func _filter_by_angle(candidates: Array, current_pos: Vector2, dir: Vector2,
        vertex_positions: Dictionary, max_angle_rad: float) -> Array:
    var valid: Array = []
    for n in candidates:
        var ndir = vertex_positions[n] - current_pos
        var angle = abs(ndir.angle_to(dir))
        if angle <= max_angle_rad + 0.02:
            valid.append(n)
    return valid


# -------------------------------------------------------
# Возвращает список рек (массив точек) — для рендеринга и сохранения
# -------------------------------------------------------
func get_rivers() -> Array:
    return rivers


# -------------------------------------------------------
# Возвращает только главные реки (для разной отрисовки)
# -------------------------------------------------------
func get_main_rivers() -> Array:
    return main_rivers


# -------------------------------------------------------
# Возвращает только притоки (для разной отрисовки)
# -------------------------------------------------------
func get_tributaries() -> Array:
    return tributaries


# -------------------------------------------------------
# Возвращает последний построенный граф вершин (для повторного
# использования в mark_river_edges без повторного построения).
# -------------------------------------------------------
func get_cached_graph() -> Dictionary:
    return _cached_graph


# -------------------------------------------------------
# Сериализует реки для сохранения (Vector2 -> [x, y]).
# Новый формат — словарь { "main": [...], "tributaries": [...] },
# чтобы при загрузке сохранить различие главных рек и притоков.
# -------------------------------------------------------
func serialize_rivers():
    return {
        "main": _serialize_list(main_rivers),
        "tributaries": _serialize_list(tributaries)
    }


# -------------------------------------------------------
# Вспомогательный метод: сериализует список рек в [x, y]
# -------------------------------------------------------
func _serialize_list(river_list: Array) -> Array:
    var result: Array = []
    for river in river_list:
        var pts: Array = []
        for pt in river:
            pts.append([pt.x, pt.y])
        result.append(pts)
    return result


# -------------------------------------------------------
# Загружает реки из сохранённых данных.
# Поддерживает оба формата:
#   - новый: словарь { "main": [...], "tributaries": [...] };
#   - старый: простой массив массивов (все реки считаются главными).
# -------------------------------------------------------
func load_rivers(river_data) -> void:
    # Если нет данных для загрузки — НЕ очищаем, чтобы не стирать
    # реки, сгенерированные в _initialize_map() для новой игры
    if river_data == null or river_data.is_empty():
        return

    main_rivers = []
    tributaries = []

    if river_data is Dictionary:
        # Новый формат: словарь с разделением на главные и притоки.
        main_rivers = _deserialize_list(river_data.get("main", []))
        tributaries = _deserialize_list(river_data.get("tributaries", []))
    else:
        # Старый формат: простой массив — все реки считаем главными.
        main_rivers = _deserialize_list(river_data)

    rivers = main_rivers + tributaries


# -------------------------------------------------------
# Вспомогательный метод: десериализует список рек из [x, y]
# -------------------------------------------------------
func _deserialize_list(river_list: Array) -> Array:
    var result: Array = []
    for river_pts in river_list:
        var river: Array = []
        for pt in river_pts:
            river.append(Vector2(float(pt[0]), float(pt[1])))
        result.append(river)
    return result

# Помечает рёбра рек в данных гексов.
# graph — опциональный готовый граф (из get_cached_graph()); если не передан
# или пуст — граф строится заново. Это убирает двойное построение графа
# (тысячи вершин) при генерации новой карты.
func mark_river_edges(tile_data: Array, rows: int, cols: int, radius: float, graph: Dictionary = {}) -> void:
    if tile_data == null or tile_data.size() == 0:
        return

    var use_graph = graph if not graph.is_empty() else _build_vertex_graph(rows, cols, radius)
    var vertex_hexes = use_graph["hexes"]

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