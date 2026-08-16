class_name MapHelpers

## Возвращает фактическую стоимость труда для постройки улучшения imp_id на гексе (row, col).
## Стоимость зависит от базового work_cost улучшения, типа местности (move_cost) и
## расстояния от города. Возвращает словарь с итоговой стоимостью и деталями расчёта
## (для расширенного тултипа).
static func get_improvement_work_cost(
	imp_id: String,
	row: int,
	col: int,
	tile_data: Array,
	city_row: int,
	city_col: int
) -> Dictionary:
	# Спец-действия не являются улучшениями — используем их базовую стоимость из данных.
	var base_cost := 0.0
	if GameData.special_actions.has(imp_id):
		base_cost = float(GameData.special_actions[imp_id].get("work_cost", 0))
	else:
		var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
		base_cost = float(imp_data.get("work_cost", 0))

	# Множитель от типа местности: чем выше move_cost, тем труднее строить.
	var terrain_id := "plain"
	if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
		terrain_id = tile_data[row][col].get("terrain", "plain")

	var move_cost := 1.0
	if GameData.terrains.has(terrain_id):
		move_cost = float(GameData.terrains[terrain_id].get("move_cost", 1))

	# Множитель сложности строительства. Если у террейна явно задан
	# work_cost_mult (например, у озёр с move_cost=999, где move_cost означает
	# «непроходимо» для юнитов, а не сложность стройки), используем его.
	# Иначе считаем по формуле на основе move_cost.
	var terrain_mult := 1.0 + (move_cost - 1.0) * 0.35
	if GameData.terrains.has(terrain_id):
		var work_cost_mult_override: float = GameData.terrains[terrain_id].get("work_cost_mult", -1.0)
		if work_cost_mult_override >= 0.0:
			terrain_mult = float(work_cost_mult_override)

	# Множитель от расстояния до города (в гексах).
	var distance := HexUtils.hex_distance(row, col, city_row, city_col)
	var distance_mult := 1.0 + float(distance) * 0.25

	var final_cost := int(ceil(base_cost * terrain_mult * distance_mult))

	return {
		"cost": final_cost,
		"base_cost": int(base_cost),
		"terrain_id": terrain_id,
		"terrain_name": GameData.terrains.get(terrain_id, {}).get("name", terrain_id),
		"move_cost": move_cost,
		"terrain_mult": terrain_mult,
		"distance": distance,
		"distance_mult": distance_mult
	}

## Проверяет, есть ли рядом с гексом (row, col) канал (improvement == "canal" или is_canal == true у соседей).
static func is_hex_adjacent_to_canal(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
	if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
		return false
	var neighbors = HexUtils.get_neighbors_odd_r(row, col, map_rows, map_cols)
	for n in neighbors:
		if tile_data[n.row][n.col] == null:
			continue
		var tile = tile_data[n.row][n.col]
		var imp_id = tile.improvement
		if imp_id == "canal":
			return true
		var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
		if imp_data.get("is_canal", false):
			return true
	return false


## Проверяет, орошен ли гекс (row, col): озеро, река, канал-сосед или цепочка ферм ведёт к воде (BFS, max 3 шага).
static func is_hex_irrigated(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
	if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
		return false
	var tile = tile_data[row][col]
	if tile == null:
		return false

	if tile.get("terrain", "plain") == "lake":
		return true
	if tile.get("river_edges", []).size() > 0:
		return true
	if is_hex_adjacent_to_canal(row, col, tile_data, map_rows, map_cols):
		return true

	var neighbors = HexUtils.get_neighbors_odd_r(row, col, map_rows, map_cols)
	for n in neighbors:
		var neighbor_tile = tile_data[n.row][n.col]
		if neighbor_tile == null:
			continue
		if neighbor_tile.get("terrain", "plain") == "lake":
			return true
		if neighbor_tile.get("river_edges", []).size() > 0:
			return true

	if tile.improvement != "farm":
		return false

	var visited := {}
	var queue = [ {"row": row, "col": col, "dist": 0}]
	visited["%d_%d" % [row, col]] = true

	while queue.size() > 0:
		var item = queue.pop_front()
		var crow = item.row
		var ccol = item.col
		var dist = item.dist
		var current_tile = tile_data[crow][ccol]
		if current_tile == null:
			continue

		if current_tile.get("terrain", "plain") == "lake":
			return true
		if current_tile.get("river_edges", []).size() > 0:
			return true
		if is_hex_adjacent_to_canal(crow, ccol, tile_data, map_rows, map_cols):
			return true
		if dist >= 3:
			continue

		var neighbors_local = HexUtils.get_neighbors_odd_r(crow, ccol, map_rows, map_cols)
		for n in neighbors_local:
			var key = "%d_%d" % [n.row, n.col]
			if visited.has(key):
				continue
			var neighbor_tile = tile_data[n.row][n.col]
			if neighbor_tile == null:
				continue
			if neighbor_tile.get("terrain", "plain") == "lake":
				return true
			if neighbor_tile.improvement == "farm":
				visited[key] = true
				queue.append({"row": n.row, "col": n.col, "dist": dist + 1})
	return false