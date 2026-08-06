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

func generate_map(rows: int, cols: int, city_row: int, city_col: int, raw_res: Dictionary, terrain_counts: Dictionary) -> Array:
    var tile_data = []
    for row in range(rows):
        var col_array = []
        for col in range(cols):
            col_array.append({"terrain": "plain", "resource": null, "improvement": null})
        tile_data.append(col_array)

    # Генерируем центры для Вороного
    var centers = []
    for terrain_id in terrain_counts.keys():
        var count = terrain_counts[terrain_id]
        for _i in range(count):
            var r = randi() % rows
            var c = randi() % cols
            centers.append({"r": r, "c": c, "terrain": terrain_id})

    for row in range(rows):
        for col in range(cols):
            var min_dist = 999999
            var nearest = "plain"
            for center in centers:
                var d = HexUtils.hex_distance(row, col, center.r, center.c)
                if d < min_dist:
                    min_dist = d
                    nearest = center.terrain
            tile_data[row][col]["terrain"] = nearest

    # --- Животные ---
    var animal_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "animals":
            animal_resources[rid] = r
    _place_resources(tile_data, animal_resources, rows, cols, city_row, city_col)

    # --- Растения ---
    var plant_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "plants":
            plant_resources[rid] = r
    _place_resources(tile_data, plant_resources, rows, cols, city_row, city_col)

    # --- Минералы ---
    var mineral_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "minerals":
            mineral_resources[rid] = r
    _place_resources(tile_data, mineral_resources, rows, cols, city_row, city_col)

    # --- Ресурсы, открываемые технологиями (НЕ генерируются здесь) ---
    # Они спавнятся динамически после изучения соответствующей технологии
    # (см. CityData.spawn_resource_on_tech_research).

    return tile_data

func _place_resources(tile_data: Array, res_dict: Dictionary, rows: int, cols: int, city_row: int, city_col: int):
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
        var possible = []
        for r in range(rows):
            for c in range(cols):
                if abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                    continue
                if tile_data[r][c]["resource"] != null:
                    continue
                var terrain_id = tile_data[r][c]["terrain"]
                if terrain_id in data.get("allowed_terrains", []):
                    possible.append({"row": r, "col": c})
        if possible.size() > 0:
            var hex = possible[randi() % possible.size()]
            tile_data[hex.row][hex.col]["resource"] = res_id

func place_wild_food(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int):
    var count = randi_range(2, 4)
    var wild_id = "wild_food"
    if not GameData.raw_resources.has(wild_id):
        print("ОШИБКА: wild_food не найден в GameData.raw_resources!")
        return
    var wild_data = GameData.raw_resources[wild_id]
    var possible = []
    for r in range(rows):
        for c in range(cols):
            # Только в Кольце Влияния
            if not tile_data[r][c]["in_influence"]:
                continue
            # Не слишком близко к городу (чтобы не мешать стартовому строительству)
            if abs(r - city_row) <= 2 and abs(c - city_col) <= 2:
                continue
            if tile_data[r][c]["resource"] != null:
                continue
            var terrain = tile_data[r][c]["terrain"]
            if terrain in wild_data.get("allowed_terrains", []):
                possible.append({"row": r, "col": c})
    possible.shuffle()
    var placed = 0
    for i in range(min(count, possible.size())):
        var hex = possible[i]
        tile_data[hex.row][hex.col]["resource"] = wild_id
        placed += 1
    print("Размещено дикоросов: ", placed)

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
