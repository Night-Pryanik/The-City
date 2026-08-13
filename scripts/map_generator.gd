# map_generator.gd
@tool
extends Node

# Минимальное количество СВОБОДНЫХ (без ресурса) гексов каждого типа местности,
# которое должно оставаться внутри Кольца Влияния после размещения всех ресурсов.
# Гарантирует, что у игрока всегда будет достаточно места для постройки
# нескольких ферм/пастбищ одного ресурса (например, киноа растёт только
# в горах — нужно ≥2 свободных горных гекса, чтобы построить ≥2 ферм).
const FREE_TERRAIN_HEXES := 2

# Порог «избыточности» типа местности: если какого-то типа в Кольце Влияния
# больше этого значения, его свободные гексы можно конвертировать
# в недостающие типы.
const OVER_REP_THRESHOLD := 3

# Вычисляет количество центров Вороного для каждого типа местности на основе
# плотностей (terrain_density) и среднего размера кластера (target_cluster),
# заданных в data/map_config.json. Пропорции по умолчанию: равнины ≈ 50%,
# холмы ≈ 30%, горы ≈ 20%.
func make_terrain_counts(rows: int, cols: int) -> Dictionary:
    var cfg: Dictionary = GameData.map_config
    var density: Dictionary = cfg.get("terrain_density", {})
    var target_cluster: int = int(cfg.get("target_cluster", 22))

    var area := rows * cols
    var total := maxi(12, int(round(float(area) / target_cluster)))

    var plain_w := float(density.get("plain", 0.50))
    var hill_w := float(density.get("hill", 0.30))
    var mountain_w := float(density.get("mountain", 0.20))

    return {
        "plain": maxi(3, int(round(total * plain_w))),
        "hill": maxi(2, int(round(total * hill_w))),
        "mountain": maxi(2, int(round(total * mountain_w))),
    }

func generate_map(rows: int, cols: int, city_row: int, city_col: int, raw_res: Dictionary, terrain_counts: Dictionary) -> Array:
    var tile_data = []
    for row in range(rows):
        var col_array = []
        for col in range(cols):
            col_array.append({"terrain": "plain", "cover": "none", "resource": null, "improvement": null})
        tile_data.append(col_array)

    # Генерируем центры для Вороного
    var centers = []
    for terrain_id in terrain_counts.keys():
        var count = terrain_counts[terrain_id]
        for _i in range(count):
            var r = randi() % rows
            var c = randi() % cols
            centers.append({"r": r, "c": c, "terrain": terrain_id})

    # Jump Flood Algorithm (JFA): строим диаграмму Вороного за O(n log n)
    # вместо наивного O(n * centers). Для карты 200x200 это ~2.5 млн операций
    # вместо ~73 млн, что ускоряет генерацию рельефа в десятки раз.
    var voronoi = _jump_flood_voronoi(rows, cols, centers)
    for row in range(rows):
        for col in range(cols):
            tile_data[row][col]["terrain"] = voronoi[row][col]

    # --- Покров (cover): генерируем ПОСЛЕ рельефа, с учётом terrain ---
    # Вероятности покрова для каждого типа местности заданы в terrains.json
    # (поле cover_chance: { "cover_id": вес, ... }).
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            tile_data[row][col]["cover"] = _roll_cover(terrain_id)

    # Мультииндекс свободных гексов по (terrain, cover) — для быстрого
    # размещения ресурсов без полного сканирования карты на каждый ресурс.
    # Строится ОДИН раз и обновляется по мере занятия гексов ресурсами.
    var hex_index = _build_hex_index(tile_data, rows, cols, city_row, city_col)

    # --- Животные ---
    var animal_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "animals":
            animal_resources[rid] = r
    _place_resources(tile_data, animal_resources, rows, cols, city_row, city_col, hex_index)

    # --- Растения ---
    var plant_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "plants":
            plant_resources[rid] = r
    _place_resources(tile_data, plant_resources, rows, cols, city_row, city_col, hex_index)

    # --- Минералы ---
    var mineral_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "minerals":
            mineral_resources[rid] = r
    _place_resources(tile_data, mineral_resources, rows, cols, city_row, city_col, hex_index)

    # --- Ресурсы, открываемые технологиями (НЕ генерируются здесь) ---
    # Они спавнятся динамически после изучения соответствующей технологии
    # (см. CityData.spawn_resource_on_tech_research).

    return tile_data

# Jump Flood Algorithm (JFA) для построения диаграммы Вороного на
# гексагональной сетке (odd-r). Сложность O(rows * cols * log2(max(rows, cols)))
# вместо наивного O(rows * cols * centers.size()).
# Возвращает 2D-массив terrain_id для каждой клетки.
func _jump_flood_voronoi(rows: int, cols: int, centers: Array) -> Array:
    # Сетка индексов ближайших центров (-1 = пусто).
    var grid = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(-1)
        grid.append(row_arr)

    # Предвычисляем q-координаты центров (для быстрого hex_distance).
    var center_q = []
    for ci in range(centers.size()):
        var center = centers[ci]
        center_q.append(center.c - ((center.r - (center.r & 1)) >> 1))

    # Размещаем центры в сетке.
    for ci in range(centers.size()):
        var center = centers[ci]
        grid[center.r][center.c] = ci

    # Начальный шаг: наибольшая степень двойки, не превосходящая max(rows, cols).
    var max_dim = maxi(rows, cols)
    var step = 1
    while step * 2 <= max_dim:
        step *= 2

    # 8 направлений JFA (прямоугольный шаблон).
    var dirs = [
        Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1),
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1)
    ]

    # Двойная буферизация (ping-pong), чтобы информация распространялась
    # ровно на один "прыжок" за итерацию.
    var read_grid = grid
    var write_grid = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(-1)
        write_grid.append(row_arr)

    while step >= 1:
        for r in range(rows):
            var q_base = (r - (r & 1)) >> 1
            for c in range(cols):
                var q = c - q_base
                var best_ci = read_grid[r][c]
                var best_dist = INF
                if best_ci >= 0:
                    var cr = centers[best_ci].r
                    var cq = center_q[best_ci]
                    best_dist = (abs(q - cq) + abs(r - cr) + abs((q + r) - (cq + cr))) >> 1
                for d in dirs:
                    var nr = r + d.x * step
                    var nc = c + d.y * step
                    if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
                        continue
                    var neighbor_ci = read_grid[nr][nc]
                    if neighbor_ci < 0:
                        continue
                    var ncr = centers[neighbor_ci].r
                    var ncq = center_q[neighbor_ci]
                    var dist = (abs(q - ncq) + abs(r - ncr) + abs((q + r) - (ncq + ncr))) >> 1
                    if dist < best_dist:
                        best_dist = dist
                        best_ci = neighbor_ci
                write_grid[r][c] = best_ci
        # Меняем буферы местами.
        var tmp = read_grid
        read_grid = write_grid
        write_grid = tmp
        step >>= 1

    # Финальный проход по 6 гексагональным соседям: убирает артефакты
    # прямоугольного шаблона JFA и доводит границы до гексагональной метрики.
    var even_dirs = [
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(-1, -1), Vector2i(-1, 0),
        Vector2i(1, -1), Vector2i(1, 0)
    ]
    var odd_dirs = [
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(-1, 0), Vector2i(-1, 1),
        Vector2i(1, 0), Vector2i(1, 1)
    ]
    for r in range(rows):
        var row_dirs = even_dirs if r % 2 == 0 else odd_dirs
        var q_base = (r - (r & 1)) >> 1
        for c in range(cols):
            var q = c - q_base
            var best_ci = read_grid[r][c]
            var best_dist = INF
            if best_ci >= 0:
                var cr = centers[best_ci].r
                var cq = center_q[best_ci]
                best_dist = (abs(q - cq) + abs(r - cr) + abs((q + r) - (cq + cr))) >> 1
            for d in row_dirs:
                var nr = r + d.x
                var nc = c + d.y
                if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
                    continue
                var neighbor_ci = read_grid[nr][nc]
                if neighbor_ci < 0:
                    continue
                var ncr = centers[neighbor_ci].r
                var ncq = center_q[neighbor_ci]
                var dist = (abs(q - ncq) + abs(r - ncr) + abs((q + r) - (ncq + ncr))) >> 1
                if dist < best_dist:
                    best_dist = dist
                    best_ci = neighbor_ci
            read_grid[r][c] = best_ci

    # Преобразуем индексы центров в terrain_id.
    var result = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        for c in range(cols):
            var ci = read_grid[r][c]
            row_arr[c] = centers[ci].terrain if ci >= 0 else "plain"
        result.append(row_arr)
    return result

# Выбирает покров (cover) для гекса с указанным типом местности по весам
# из terrains.json (cover_chance). Если поле отсутствует или пустое —
# возвращает "none".
func _roll_cover(terrain_id: String) -> String:
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    var chances: Dictionary = t.get("cover_chance", {})
    if chances.is_empty():
        return "none"
    var total := 0.0
    for cid in chances.keys():
        total += float(chances[cid])
    if total <= 0.0:
        return "none"
    var roll = randf() * total
    var accum := 0.0
    for cid in chances.keys():
        accum += float(chances[cid])
        if roll < accum:
            return cid
    return "none"

# Строит мультииндекс свободных гексов по (terrain, cover).
# Ключ: "terrain|cover" -> Array словарей {"row", "col"}.
# Гексы рядом с городом (abs <= 1) исключаются, чтобы не мешать
# стартовому строительству (как в исходном _place_resources).
func _build_hex_index(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> Dictionary:
    var index: Dictionary = {}
    for r in range(rows):
        for c in range(cols):
            if abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var terrain_id = tile.get("terrain", "plain")
            var cover_id = tile.get("cover", "none")
            var key = "%s|%s" % [terrain_id, cover_id]
            if not index.has(key):
                index[key] = []
            index[key].append({"row": r, "col": c})
    return index

# Удаляет гекс из мультииндекса после занятия его ресурсом.
func _remove_hex_from_index(hex_index: Dictionary, row: int, col: int, terrain_id: String, cover_id: String) -> void:
    var key = "%s|%s" % [terrain_id, cover_id]
    if not hex_index.has(key):
        return
    var arr: Array = hex_index[key]
    for i in range(arr.size()):
        if arr[i].row == row and arr[i].col == col:
            arr.remove_at(i)
            break
    if arr.is_empty():
        hex_index.erase(key)

func _place_resources(tile_data: Array, res_dict: Dictionary, rows: int, cols: int, city_row: int, city_col: int, hex_index: Dictionary):
    if res_dict.size() == 0:
        return
    # Определяем количество видов: 50% шанс на 2, 30% шанс на 3
    var roll = randf()
    var num_types = 1
    if roll < 0.5:
        num_types = 2
    elif roll < 0.8: # 0.5 + 0.3 = 0.8
        num_types = 3
    # Перемешиваем ключи и берём нужное количество
    var ids = res_dict.keys()
    ids.shuffle()
    var chosen = ids.slice(0, min(num_types, ids.size()))

    for res_id in chosen:
        var data = res_dict[res_id]
        # Ресурсы, требующие НЕизученную технологию, не спавнятся на старте.
        # Они спавнятся динамически после изучения технологии
        # (см. CityData.spawn_resource_on_tech_research).
        var tech_required = data.get("tech_required", "")
        if tech_required != "" and not CityData.is_tech_unlocked(tech_required):
            continue
        # Ресурсы с дополнительными условиями спавна (spawn_conditions):
        # если шанс активации не выпал — ресурс исключается из спавна.
        if not HexUtils.spawn_conditions_met(data):
            continue
        # Собираем кандидатов из мультииндекса: перебираем только комбинации
        # (terrain, cover), разрешённые ресурсом, вместо полного сканирования карты.
        var possible = []
        for terrain_id in data.get("allowed_terrain", []):
            for cover_id in data.get("allowed_cover", []):
                var key = "%s|%s" % [terrain_id, cover_id]
                if not hex_index.has(key):
                    continue
                var arr: Array = hex_index[key]
                for hex in arr:
                    # Фильтруем гексы по геометрическим условиям spawn_conditions.
                    if HexUtils.is_hex_conditions_met(tile_data, hex.row, hex.col, data):
                        possible.append(hex)
        if possible.size() > 0:
            var hex = possible[randi() % possible.size()]
            tile_data[hex.row][hex.col]["resource"] = res_id
            # Задаём случайное качество ресурсу при спавне.
            tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()
            # Убираем занятый гекс из индекса, чтобы его не выбрал другой ресурс.
            _remove_hex_from_index(hex_index, hex.row, hex.col,
                    tile_data[hex.row][hex.col]["terrain"], tile_data[hex.row][hex.col].get("cover", "none"))

# Размещает дикоросы ТОЛЬКО внутри стартового Кольца Влияния.
# Вызывается один раз при старте новой игры (из main_map._initialize_map).
# Границы (min_row..max_row, min_col..max_col) — это стартовое Кольцо,
# поэтому дикоросы гарантированно не появляются за его пределами
# и не пересоздаются после старта.
func place_wild_food(tile_data: Array, min_row: int, max_row: int, min_col: int, max_col: int, city_row: int, city_col: int):
    var count = randi_range(2, 4)
    var wild_id = "wild_food"
    if not GameData.raw_resources.has(wild_id):
        print("ОШИБКА: wild_food не найден в GameData.raw_resources!")
        return
    var wild_data = GameData.raw_resources[wild_id]
    var possible = []
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            # Не слишком близко к городу (чтобы не мешать стартовому строительству)
            if abs(r - city_row) <= 2 and abs(c - city_col) <= 2:
                continue
            if tile_data[r][c]["resource"] != null:
                continue
            var terrain = tile_data[r][c]["terrain"]
            var cover = tile_data[r][c].get("cover", "none")
            if terrain in wild_data.get("allowed_terrain", []) and cover in wild_data.get("allowed_cover", []):
                possible.append({"row": r, "col": c})
    possible.shuffle()
    for i in range(min(count, possible.size())):
        var hex = possible[i]
        tile_data[hex.row][hex.col]["resource"] = wild_id
        # Дикоросы тоже имеют качество.
        tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()

# Пост-обработка генерации карты: гарантирует, что внутри Кольца Влияния
# после размещения всех ресурсов остаётся минимум FREE_TERRAIN_HEXES СВОБОДНЫХ
# (без ресурса) гексов каждого типа местности, участвующего в алгоритме Вороного.
#
# Это напрямую устраняет софт-лок: если ресурс (например, киноа — только горы)
# попал в Кольцо Влияния, у игрока всегда будет достаточно свободных горных
# гексов, чтобы построить несколько ферм/пастбищ этого ресурса.
#
# Метод вызывается ПОСЛЕ размещения ресурсов в main_map._initialize_map().
# Он НИКОГДА не уничтожает ресурсы: конвертируются только СВОБОДНЫЕ гексы,
# и только рядом с уже существующим кластером целевого типа (BFS-расширение),
# чтобы новые гексы примыкали к старым, а не появлялись в случайных местах.
func ensure_free_terrain_hexes(tile_data: Array, terrain_counts: Dictionary,
        min_row: int, max_row: int, min_col: int, max_col: int) -> void:
    # Считаем СВОБОДНЫЕ (resource == null) гексы каждого типа внутри границ.
    var free_count: Dictionary = {}
    for terrain_id in terrain_counts.keys():
        free_count[terrain_id] = 0
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var terrain_id = tile.get("terrain", "plain")
            if free_count.has(terrain_id):
                free_count[terrain_id] += 1

    # Для каждого типа, у которого меньше FREE_TERRAIN_HEXES свободных гексов,
    # добавляем недостающие рядом с кластером этого типа.
    for terrain_id in terrain_counts.keys():
        var deficit = FREE_TERRAIN_HEXES - free_count.get(terrain_id, 0)
        if deficit <= 0:
            continue
        var converted = _convert_free_terrain_near_cluster(tile_data, terrain_id, deficit,
                min_row, max_row, min_col, max_col, free_count, terrain_counts)
        free_count[terrain_id] += converted

# Конвертирует СВОБОДНЫЕ гексы других типов в terrain_id рядом с уже
# существующим кластером этого типа. Возвращает количество конвертированных.
func _convert_free_terrain_near_cluster(tile_data: Array, terrain_id: String, deficit: int,
        min_row: int, max_row: int, min_col: int, max_col: int,
        free_count: Dictionary, terrain_counts: Dictionary) -> int:
    var converted = 0

    # Кластер = существующие свободные гексы целевого типа внутри границ.
    var cluster: Array = []
    var visited := {}
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            if tile.get("terrain", "plain") == terrain_id:
                cluster.append({"row": r, "col": c})
                visited["%d_%d" % [r, c]] = true

    # Собираем кандидатов-доноров: СВОБОДНЫЕ гексы других типов с расстоянием
    # от кластера (волновой обход BFS наружу).
    var candidates: Array = []
    var frontier = cluster.duplicate()
    var distance = 0
    var max_distance = (max_row - min_row + 1) + (max_col - min_col + 1)
    while frontier.size() > 0 and distance < max_distance:
        distance += 1
        var next_frontier: Array = []
        for hex in frontier:
            var neighbors = HexUtils.get_neighbors_odd_r(hex.row, hex.col, max_row + 1, max_col + 1)
            for n in neighbors:
                if n.row < min_row or n.row > max_row or n.col < min_col or n.col > max_col:
                    continue
                var key = "%d_%d" % [n.row, n.col]
                if visited.has(key):
                    continue
                visited[key] = true
                # Пропускаем гексы с ресурсом — их конвертировать НЕЛЬЗЯ.
                if tile_data[n.row][n.col].get("resource", null) != null:
                    continue
                var n_terrain = tile_data[n.row][n.col].get("terrain", "plain")
                if n_terrain == terrain_id:
                    next_frontier.append(n)
                else:
                    candidates.append({"row": n.row, "col": n.col, "terrain": n_terrain, "dist": distance})
        frontier = next_frontier

    # Если свободных гексов целевого типа нет вовсе — берём любой свободный гекс
    # как «зародыш» кластера (первый гекс ставится в любом свободном месте,
    # остальные уже будут рядом с ним). Для зародыша разрешаем взять гекс
    # у донора, у которого осталось ровно FREE_TERRAIN_HEXES (последний
    # свободный гекс у донора забирать нельзя, но "ровно 2" можно — это
    # не лишает донорский тип всех ресурсов, а лишь переносит свободное
    # место к дефицитному типу).
    if cluster.size() == 0 and candidates.size() == 0:
        for r in range(min_row, max_row + 1):
            for c in range(min_col, max_col + 1):
                if tile_data[r][c].get("resource", null) != null:
                    continue
                if tile_data[r][c].get("terrain", "plain") != terrain_id:
                    candidates.append({"row": r, "col": c,
                            "terrain": tile_data[r][c].get("terrain", "plain"), "dist": 0})

    # Сортировка: (1) ближе к существующему кластеру, (2) избыточные типы первыми.
    candidates.sort_custom(func(a, b):
        var a_over = free_count.get(a.terrain, 0) > OVER_REP_THRESHOLD
        var b_over = free_count.get(b.terrain, 0) > OVER_REP_THRESHOLD
        if a.dist != b.dist:
            return a.dist < b.dist
        if a_over != b_over:
            return a_over and not b_over
        return a.terrain < b.terrain)

    for hex in candidates:
        if converted >= deficit:
            break
        var old_terrain = hex.terrain
        var row = hex.row
        var col = hex.col
        var tile = tile_data[row][col]
        # Гекс мог быть изменён ранее другим дефицитным типом.
        if tile.get("terrain", "plain") != old_terrain:
            continue
        # Конвертируем ТОЛЬКО свободные гексы (ресурс не трогаем).
        if tile.get("resource", null) != null:
            continue
        # Нельзя забирать свободный гекс у типа, у которого и так меньше
        # FREE_TERRAIN_HEXES — иначе просто перенесём софт-лок на другой тип.
        # Исключение: если у целевого типа вообще нет свободных гексов
        # (cluster.size()==0), разрешаем взять «зародыш» даже у донора
        # с ровно FREE_TERRAIN_HEXES, т.к. иначе дефицитный тип останется
        # заблокированным навсегда.
        var donor_min = FREE_TERRAIN_HEXES
        if cluster.size() == 0:
            donor_min = FREE_TERRAIN_HEXES - 1
        if free_count.get(old_terrain, 0) <= donor_min:
            continue
        tile["terrain"] = terrain_id
        if free_count.has(old_terrain):
            free_count[old_terrain] = max(0, free_count[old_terrain] - 1)
        free_count[terrain_id] = free_count.get(terrain_id, 0) + 1
        converted += 1

    return converted
