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

## Возвращает имя иконки ландшафта для гекса (row, col) на основе его terrain.
## Использует детерминированный RNG (seed = row * 1000 + col) для стабильности
## между сохранениями/загрузками.
static func get_terrain_icon(row: int, col: int, tile_data: Array) -> String:
	var tile = tile_data[row][col]
	var terrain_id: String = tile.get("terrain", "plain")
	if not GameData.terrains.has(terrain_id):
		return ""
	var t: Dictionary = GameData.terrains[terrain_id]
	if t.has("icons"):
		var icons_array: Array = t.icons
		if icons_array.size() > 0:
			var icon_rng = RandomNumberGenerator.new()
			icon_rng.seed = row * 1000 + col
			var idx = icon_rng.randi() % icons_array.size()
			return icons_array[idx]
	elif t.has("icon"):
		return t.icon
	return ""


## Ищет на карте уже одомашненный экземпляр ресурса res_id (гекс с этим ресурсом
## и построенным улучшением) и возвращает его качество.
## Если такого нет — возвращает пустую строку.
static func find_domesticated_quality(
	res_id: String,
	tile_data: Array,
	region_start_row: int,
	region_end_row: int,
	region_start_col: int,
	region_end_col: int
) -> String:
	for r in range(region_start_row, region_end_row + 1):
		for c in range(region_start_col, region_end_col + 1):
			var t = tile_data[r][c]
			if t.get("resource") == res_id and t.get("improvement") != null:
				var q = t.get("quality", "")
				if q != "" and q != null:
					return q
	return ""


## Гарантирует, что город находится на разрешённой местности (равнина или холмы).
## Если город был сгенерирован/загружен на горе или озере — меняет на равнину.
static func ensure_city_valid_terrain(
	tile_data: Array,
	city_row: int,
	city_col: int,
	map_rows: int,
	map_cols: int
) -> void:
	if city_row < 0 or city_row >= map_rows or city_col < 0 or city_col >= map_cols:
		return
	var city_tile = tile_data[city_row][city_col]
	var current_terrain: String = city_tile.get("terrain", "plain")
	var allowed_terrains: Array[String] = ["plain", "hill"]
	if current_terrain not in allowed_terrains:
		city_tile["terrain"] = "plain"

## Хит-тест: какой гекс (row, col) находится под пиксельными координатами (mx, my).
## Итерирует только видимое окно (Кольцо + Регион) для производительности.
static func pixel_to_hex(
	mx: float, my: float,
	region_start_row: int, region_end_row: int,
	region_start_col: int, region_end_col: int,
	offset_x: float, offset_y: float,
	scroll_offset: Vector2,
	hex_radius: float
):
	for row in range(region_start_row, region_end_row + 1):
		for col in range(region_start_col, region_end_col + 1):
			var center = HexUtils.hex_center(row, col, hex_radius)
			center.x += offset_x + scroll_offset.x
			center.y += offset_y + scroll_offset.y
			var verts = HexUtils.hex_vertices(center.x, center.y, hex_radius)
			if HexUtils.point_in_polygon(mx, my, verts):
				return {"row": row, "col": col}
	return null

## Возвращает id улучшения, которое можно построить на гексе,
## или пустую строку, если постройка невозможна.
static func get_buildable_improvement(tile: Dictionary) -> String:
	if tile.improvement != null:
		return ""

	if tile.resource != null:
		var raw: Dictionary = GameData.raw_resources.get(tile.resource, {})
		if "improved_by" in raw and raw.improved_by != null and raw.improved_by != "":
			var imp_id: String = raw.improved_by
			if CityData.is_improvement_unlocked(imp_id):
				return imp_id
		return ""

	# Пустой гекс: пастбище или ферма из одомашненных видов.
	var tile_cover: String = tile.get("cover", "none")
	if CityData.domesticated_animals.size() > 0 and CityData.is_improvement_unlocked("pasture"):
		for animal_id in CityData.domesticated_animals:
			var animal_data: Dictionary = GameData.raw_resources.get(animal_id, {})
			if tile.terrain in animal_data.get("allowed_terrain", []) and tile_cover in animal_data.get("allowed_cover", []):
				return "pasture"
	if CityData.domesticated_plants.size() > 0 and CityData.is_improvement_unlocked("farm"):
		for plant_id in CityData.domesticated_plants:
			var plant_data: Dictionary = GameData.raw_resources.get(plant_id, {})
			if tile.terrain in plant_data.get("allowed_terrain", []) and tile_cover in plant_data.get("allowed_cover", []):
				return "farm"
	return ""


## Формирует строку описания чанка после разведки.
static func get_chunk_info(chunk: Array, tile_data: Array) -> String:
	var terrain_types := {}
	var cover_forests := false
	var resources := []
	for hex in chunk:
		var tile = tile_data[hex.row][hex.col]
		var terrain: String = tile.get("terrain", "plain")
		terrain_types[terrain] = terrain_types.get(terrain, 0) + 1
		var cover_id: String = tile.get("cover", "none")
		if cover_id != "none":
			cover_forests = true
		if tile.resource != null:
			var res_name: String = GameData.raw_resources.get(tile.resource, {}).get("name", tile.resource)
			resources.append(res_name)

	var terrain_names: Array[String] = []
	for terrain_id in terrain_types.keys():
		terrain_names.append(GameData.terrains.get(terrain_id, {}).get("name", terrain_id))
	var terrain_str := ", ".join(terrain_names)
	if cover_forests:
		terrain_str += ", лес"
	var resource_str := ", ".join(resources) if resources.size() > 0 else "нет"
	return "Ландшафт: %s. Ресурсы: %s" % [terrain_str, resource_str]