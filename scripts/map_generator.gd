# map_generator.gd
@tool
extends Node

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

    return tile_data

func _place_resources(tile_data: Array, res_dict: Dictionary, rows: int, cols: int, city_row: int, city_col: int):
    if res_dict.size() == 0:
        return
    # Определяем количество видов: 50% шанс на 2, 30% шанс на 3
    var roll = randf()
    var num_types = 1
    if roll < 0.5:
        num_types = 2
    elif roll < 0.8:   # 0.5 + 0.3 = 0.8
        num_types = 3
    # Перемешиваем ключи и берём нужное количество
    var ids = res_dict.keys()
    ids.shuffle()
    var chosen = ids.slice(0, min(num_types, ids.size()))

    for res_id in chosen:
        var data = res_dict[res_id]
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

func _place_wild_food(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int):
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
