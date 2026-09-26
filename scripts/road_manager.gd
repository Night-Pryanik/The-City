# road_manager.gd
extends Node

# Храним дороги как Set строк в формате "row1,col1|row2,col2" (каноническое направление)
# Каноническое = с меньшей суммой row+col, или если равны, то с меньшим col
var road_segments: Dictionary = {}

# Список "подключённых" гексов (те, к которым уже есть дорога)
var connected_hexes: Dictionary = {}
var city_row: int = 0
var city_col: int = 0

# === Сети дорог городков ===
# У каждого городка своя независимая сеть: от центра городка — к его
# улучшениям в кольце влияния (их расставляет
# town_manager._place_decorative_town_improvements). Сети НЕ склеиваются: ни с
# сетью города игрока, ни друг с другом. За это отвечает
# town_connected_hexes — у каждого городка свой набор подключённых гексов, и
# поиск дороги останавливается только на гексе СВОЕЙ сети. Иначе «дороги от
# городка» стали бы дорогами от города игрока, а все городки ещё и связались бы
# между собой одной паутиной дорог через него.
#
# town_road_segments — все сегменты дорог городков в одном плоском словаре
# (канонический ключ сегмента -> true): для отрисовки набор всё равно один, и
# совпавший с сегментом другого городка сегмент просто рисуется один раз.
# town_connected_hexes ключуется координатами ЦЕНТРА городка ("row,col"), а не
# индексом в towns: такой ключ не «поедет», если городки в списке поменяются
# местами.
var town_road_segments: Dictionary = {}
var town_connected_hexes: Dictionary = {}

# Инициализация после генерации карты
func initialize(new_city_row: int, new_city_col: int):
    self.city_row = new_city_row
    self.city_col = new_city_col
    # Полный сброс сетей: initialize() зовётся один раз на старте партии (и для
    # новой игры, и для загрузки), поэтому состояние всегда начинается с чистого
    # листа — иначе старые сети протекли бы в новую партию.
    road_segments.clear()
    connected_hexes.clear()
    clear_town_roads()
    var key = _hex_key(new_city_row, new_city_col)
    connected_hexes[key] = true

func rebuild_roads_from_existing(tile_data: Array, region_rows: int, region_cols: int):
    for row in range(region_rows):
        for col in range(region_cols):
            var tile = tile_data[row][col]
            # Декоративные улучшения (tile.decorative) принадлежат ГОРОДКАМ, а
            # не игроку: их дороги строит сам городок от своего центра
            # (build_town_road_from). Проверки раньше не было, и при загрузке
            # сейва сеть дорог ГОРОДА ИГРОКА прирастала дорогами ко всем полям,
            # лесным делянкам и карьерам всех городков на карте (вызов
            # rebuild_roads_from_existing идёт до загрузки городков, а в tile_data
            # сейва улучшения городков лежат вместе с улучшениями игрока).
            if tile != null and tile.get("improvement", null) != null \
                    and not bool(tile.get("decorative", false)):
                build_road_from(row, col, tile_data, region_rows, region_cols)

# Прокладывает дорогу от нового улучшения до ближайшего подключённого гекса
# в сети ГОРОДА ИГРОКА.
func build_road_from(
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int
):
    var start_key = _hex_key(start_row, start_col)
    if connected_hexes.has(start_key):
        return

    var best_path = _find_connect_path(start_row, start_col, connected_hexes,
            tile_data, region_rows, region_cols)
    if best_path.is_empty():
        return

    # Добавляем все сегменты дороги
    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        _add_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col)
        connected_hexes[_hex_key(from_hex.row, from_hex.col)] = true
        connected_hexes[_hex_key(to_hex.row, to_hex.col)] = true

# Общий для города и городков поиск пути от (start_row, start_col) до
# ближайшего гекса из `connected`. Возвращает путь (Array of {row, col}) от
# старта до найденной цели либо пустой массив, если пути нет.
#
# Правила одинаковые для обеих сетей, поэтому и живут здесь:
#   - водные улучшения (например, рыбацкие лодки) не прокладывают дорогу по
#     воде: доступ к водному ресурсу обеспечивает пристань (harbor), стоящая на
#     берегу, к которой дорога строится штатно как к обычному наземному
#     улучшению;
#   - улучшения с флагом no_road дороги не получают (ирригационные каналы —
#     инфраструктура, к которой дорогу прокладывать не нужно);
#   - путь обязан состоять из соседних гексов.
#
# Побочных эффектов нет: `connected` НЕ пополняется — это делает вызывающий код,
# и только для СВОЕЙ сети (у города — connected_hexes, у городка — набор из
# town_connected_hexes). Благодаря этому сети городков остаются независимыми,
# см. build_town_road_from.
func _find_connect_path(
    start_row: int,
    start_col: int,
    connected: Dictionary,
    tile_data: Array,
    region_rows: int,
    region_cols: int
) -> Array:
    if start_row >= 0 and start_row < tile_data.size() \
            and start_col >= 0 and start_col < tile_data[start_row].size():
        var start_tile = tile_data[start_row][start_col]
        if start_tile != null and MapHelpers.is_water_terrain(start_tile.get("terrain", "")):
            return []
        var start_imp_id = start_tile.get("improvement", null)
        if start_imp_id != null and GameData.improvements.has(start_imp_id) \
                and GameData.improvements[start_imp_id].get("no_road", false):
            return []

    var best_path = _find_path_dijkstra(
        start_row, start_col, tile_data, region_rows, region_cols, connected
    )
    if best_path.is_empty():
        return []

    # Гарантируем, что путь состоит только из соседних гексов
    if not _validate_path(best_path):
        printerr("Ошибка: путь содержит несоседние гексы!")
        return []
    return best_path

# === Дороги городков ===

# Полный пересчёт дорог городков: для каждого городка строится дорога от его
# центра к каждому улучшению в его КОЛЬЦЕ ВЛИЯНИЯ. Вызывать надо ПОСЛЕ
# town_manager._place_decorative_town_improvements — до неё улучшений в кольце
# ещё нет, и строить будет нечего.
#
# В сейв дороги не пишутся — ровно как городские: входные данные (городки и их
# улучшения) в сейве уже есть, поэтому сеть каждый раз считается заново, и на
# экране всегда одна и та же картина. Каждый городок получает СВОЮ независимую
# сеть (см. town_connected_hexes).
func rebuild_town_roads(towns: Array, tile_data: Array,
        region_rows: int, region_cols: int) -> void:
    clear_town_roads()
    if towns == null:
        return
    for town in towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        if town_row < 0 or town_col < 0:
            continue
        # Центр городка — корень своей сети: к нему стягиваются все дороги.
        _town_connected(town_row, town_col)[_hex_key(town_row, town_col)] = true
        for h in town.get("influence_hexes", []):
            var row := int(h.get("row", -1))
            var col := int(h.get("col", -1))
            if row < 0 or col < 0 or row >= region_rows or col >= region_cols:
                continue
            var tile = tile_data[row][col]
            if tile == null or tile.get("improvement", null) == null:
                continue
            build_town_road_from(town_row, town_col, row, col,
                    tile_data, region_rows, region_cols)

# Прокладывает дорогу от улучшения (start_row, start_col) до сети ЭТОГО
# городка — полный аналог build_road_from, но в сети городка. Путь ищется
# только до гексов, подключённых к ЭТОМУ городку, поэтому дорога городка
# логически не может стать частью дорог города игрока или другого городка.
# Геометрически трасса может пройти по гексам соседа (путь ищется по всей
# карте, вода непроходима) — набор сегментов для отрисовки у городов общий,
# и «общая трасса» просто рисуется один раз.
func build_town_road_from(
    town_row: int,
    town_col: int,
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int
) -> void:
    var connected := _town_connected(town_row, town_col)
    if connected.has(_hex_key(start_row, start_col)):
        return

    var best_path = _find_connect_path(start_row, start_col, connected,
            tile_data, region_rows, region_cols)
    if best_path.is_empty():
        return

    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        _add_town_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col)
        connected[_hex_key(from_hex.row, from_hex.col)] = true
        connected[_hex_key(to_hex.row, to_hex.col)] = true

# Набор подключённых гексов СЕТИ ГОРОДКА (создаётся на первый запрос).
func _town_connected(town_row: int, town_col: int) -> Dictionary:
    var key := _hex_key(town_row, town_col)
    if not town_connected_hexes.has(key):
        town_connected_hexes[key] = {}
    return town_connected_hexes[key]

# Сбрасывает все сети дорог городков (старт партии и полный пересчёт).
func clear_town_roads() -> void:
    town_road_segments.clear()
    town_connected_hexes.clear()

# Проверяет, соединён ли гекс дорогами с центром ЭТОГО городка.
func is_town_connected(town_row: int, town_col: int, row: int, col: int) -> bool:
    var connected = town_connected_hexes.get(_hex_key(town_row, town_col), null)
    if connected == null:
        return false
    return connected.has(_hex_key(row, col))

# Добавляет сегмент дороги городка в каноническом направлении (без дубликатов)
func _add_town_road_segment(row1: int, col1: int, row2: int, col2: int):
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    town_road_segments[key] = true

# Все сегменты дорог городков (для отрисовки).
func get_all_town_road_segments() -> Dictionary:
    return town_road_segments.duplicate()

# Ключ гекса "row,col" — единый формат ключей во всех словарях менеджера.
func _hex_key(row: int, col: int) -> String:
    return str(row) + "," + str(col)

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
# до ближайшего гекса из `connected` (у города — connected_hexes, у городка —
# его личный набор в town_connected_hexes).
func _find_path_dijkstra(
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    connected: Dictionary
) -> Array:
    var visited = {}
    var parent = {}
    var cost_so_far = {}
    var start_key = _hex_key(start_row, start_col)
    
    # Инициализация
    cost_so_far[start_key] = 0
    parent[start_key] = null
    
    var current_key = start_key
    
    while true:
        var cur_row = int(current_key.split(",")[0])
        var cur_col = int(current_key.split(",")[1])
        
        # Проверяем, подключён ли текущий гекс к сети
        if connected.has(current_key) and current_key != start_key:
            # Восстанавливаем путь
            return _reconstruct_path(current_key, parent)
        
        visited[current_key] = true
        
        var neighbors = _get_neighbors(cur_row, cur_col, region_rows, region_cols)
        for n in neighbors:
            var n_key = _hex_key(n.row, n.col)
            
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
