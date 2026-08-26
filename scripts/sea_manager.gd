# sea_manager.gd
# Вся логика генерации морей, побережья и связанных с ними пост-обработок,
# вынесенная из map_generator.gd. Чисто-утилитный модуль: статические функции,
# без собственного состояния.
#
# Публичный API:
#   - sea_config()                                     : Dictionary
#   - is_sea_hex(tile_data, row, col)                  : bool
#   - apply_sea(tile_data, rows, cols, city_row,
#               city_col)                              : Array   (2D bool mask)
#   - reapply_sea_mask(tile_data)                      : void    (после Вороного)
#   - replace_island_lakes(tile_data, sea_mask,
#                          rows, cols)                 : void
#   - apply_sea_coast_marshes(tile_data, rows, cols)   : void
#
# Использует временные флаги на гексах:
#   - tile._is_sea    : bool — гекс входит в маску моря
#   - tile._is_beach  : bool — гекс превращён в пляж (beach)
#   - tile._is_marsh  : bool — гекс превращён в марш (marsh) [общий с озёрными]
#
# Временные флаги сбрасываются map_generator._ensure_plain_zone и
# map_generator._punch_hex после того, как их работа завершена.
@tool
class_name SeaManager

# --- Константы ---
# Шанс превратить пляжный гекс в марш. Тот же, что и для озерных маршей
# в map_generator.gd (MARSH_CHANCE). Дублируется осознанно: модули изолированы
# друг от друга, и менять шанс глобально можно одним точечным рефакторингом.
const MARSH_CHANCE := 0.15


# Возвращает конфигурацию моря из data/map_config.json (блок "sea").
static func sea_config() -> Dictionary:
	return GameData.map_config.get("sea", {})


# Возвращает true, если гекс (row, col) помечен как море (временный флаг _is_sea).
static func is_sea_hex(tile_data: Array, row: int, col: int) -> bool:
	return tile_data[row][col].get("_is_sea", false)


# Генерирует маску моря на карте ДО алгоритма Вороного.
# Возвращает 2D-массив bool: true = гекс является морем.
# Поддерживает два режима (см. data/map_config.json, блок "sea"):
#   - "noise" (вариант А): elevation = градиент от края + шум + city_bump;
#     суша = elevation > sea_level.
#   - "edge" (вариант Б): полоса моря у выбранных сторон, ширина — гладкий 1D-шум.
#   - "none": море не генерируется.
# Гексы моря помечаются временным флагом _is_sea, чтобы после Вороного
# маску можно было повторно применить поверх результата.
static func apply_sea(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> Array:
	var cfg := sea_config()
	var mode: String = cfg.get("mode", "none")
	var sea_mask: Array = []
	for r in range(rows):
		var row_arr = []
		row_arr.resize(cols)
		row_arr.fill(false)
		sea_mask.append(row_arr)

	if mode == "none":
		return sea_mask

	var max_sea_depth: int = int(cfg.get("max_sea_depth", 8))
	var beach_enabled: bool = cfg.get("beach", true)

	# sides — диапазон [min, max] количества случайно выбранных сторон света,
	# у которых будет море. [0,0] — море не генерируется.
	# Разбор и валидация формата («число» или «[min, max] из чисел», swap при
	# перепутанных границах) делегированы RangeUtils.parse_range.
	# При некорректных данных море не генерируется (безопасное поведение).
	var parsed_sides: Dictionary = RangeUtils.parse_range(cfg.get("sides", []))
	if not parsed_sides.ok:
		print("map_generator: предупреждение — поле sea.sides задано некорректно, море не генерируется. Ожидается число или [min, max] (0..4).")
		return sea_mask
	var sides: Array = []
	var min_sides: int = clampi(parsed_sides["min"], 0, 4)
	var max_sides: int = clampi(parsed_sides["max"], 0, 4)
	# Если минимум = 0 — море может не сгенерироваться вообще.
	if max_sides <= 0:
		return sea_mask
	var all_sides: Array = ["east", "west", "north", "south"]
	var count: int = randi_range(min_sides, max_sides)
	all_sides.shuffle()
	for i in range(count):
		sides.append(all_sides[i])

	if mode == "noise":
		_apply_sea_noise(sea_mask, rows, cols, city_row, city_col, cfg, max_sea_depth, sides)
	elif mode == "edge":
		_apply_sea_edge(sea_mask, rows, cols, cfg, max_sea_depth, sides)
		# Острова в морях — только для режима "edge". Размещаются ДО пометки
		# _is_sea и ДО _apply_beach, чтобы пляж потом корректно обвёл новые
		# острова (как и любую другую сушу рядом с морем).
		if bool(cfg.get("edge_islands_enabled", true)):
			_apply_sea_islands(sea_mask, rows, cols, cfg, city_row, city_col)

	# Помечаем гексы моря временным флагом _is_sea.
	for r in range(rows):
		for c in range(cols):
			if sea_mask[r][c]:
				tile_data[r][c]["_is_sea"] = true

	# Пляж: суша, соседняя с морем, становится пляжем (beach).
	if beach_enabled:
		_apply_beach(tile_data, sea_mask, rows, cols)

	return sea_mask


# Повторно применяет маску моря/пляжа поверх результата Вороного. Вороной
# заполнил всю карту своим рельефом, поэтому по флагам _is_sea / _is_beach
# восстанавливаем исходные типы местности, чтобы их не перезаписало.
static func reapply_sea_mask(tile_data: Array) -> void:
	for row in range(tile_data.size()):
		var data_row: Array = tile_data[row]
		for col in range(data_row.size()):
			var tile = data_row[col]
			if tile.get("_is_sea", false):
				tile["terrain"] = "sea"
				tile["cover"] = "none"
			elif tile.get("_is_beach", false):
				tile["terrain"] = "beach"
				tile["cover"] = "none"


# Вариант А: elevation = градиент от края + шум + city_bump; суша = elevation > sea_level.
# sides — список сторон, у которых может быть море ("east", "west", "north", "south").
# Если sides пуст — море генерируется со всех сторон (поведение по умолчанию).
static func _apply_sea_noise(sea_mask: Array, rows: int, cols: int,
		city_row: int, city_col: int, cfg: Dictionary, max_sea_depth: int, sides: Array) -> void:
	var sea_level: float = float(cfg.get("noise_sea_level", 0.0))
	var noise_strength: float = float(cfg.get("noise_strength", 0.35))
	var edge_gradient: float = float(cfg.get("noise_edge_gradient", 0.4))
	var city_bump: float = float(cfg.get("noise_city_bump", 0.5))
	var city_bump_radius: float = float(cfg.get("noise_city_bump_radius", 8))

	# Нормализованные координаты: 0 в центре карты, 1 на краю.
	var half_rows = float(rows - 1) / 2.0
	var half_cols = float(cols - 1) / 2.0

	for r in range(rows):
		for c in range(cols):
			# Расстояние до ближайшего края карты (в гексах).
			var edge_dist_hex = min(
				min(r, rows - 1 - r),
				min(c, cols - 1 - c)
			)
			# Ограничение ширины моря: гексы дальше max_sea_depth от края — суша.
			if edge_dist_hex > max_sea_depth:
				continue

			# Если заданы стороны — проверяем, что гекс находится у одной из них.
			# Иначе (sides пуст) — море со всех сторон.
			if not sides.is_empty():
				var near_allowed_side := false
				for side in sides:
					var dist_to_side := -1
					if side == "east":
						dist_to_side = cols - 1 - c
					elif side == "west":
						dist_to_side = c
					elif side == "north":
						dist_to_side = r
					elif side == "south":
						dist_to_side = rows - 1 - r
					# Гекс у выбранной стороны, если он в пределах max_sea_depth от неё.
					if dist_to_side >= 0 and dist_to_side <= max_sea_depth:
						near_allowed_side = true
						break
				if not near_allowed_side:
					continue

			# Нормализованное расстояние до края (0 на краю, 1 в центре).
			var edge_dist = min(
				min(float(r) / half_rows, float(rows - 1 - r) / half_rows),
				min(float(c) / half_cols, float(cols - 1 - c) / half_cols)
			)
			# Градиент: центрирован около 0. На краю (edge_dist=0) — отрицательный
			# (море), в центре (edge_dist=1) — положительный (суша).
			var gradient = (edge_dist - 0.5) * 2.0 * edge_gradient

			# Шум высот (детерминированный по координатам), центрирован около 0:
			# от -noise_strength до +noise_strength.
			var noise = (_hash_noise(r, c) * 2.0 - 1.0) * noise_strength

			# City bump: «холм» вокруг города, гарантирующий стартовый континент.
			var dist_to_city = HexUtils.hex_distance(r, c, city_row, city_col)
			var bump = 0.0
			if dist_to_city <= city_bump_radius:
				var t = 1.0 - float(dist_to_city) / city_bump_radius
				bump = city_bump * t * t

			var elevation = gradient + noise + bump
			if elevation <= sea_level:
				sea_mask[r][c] = true


# Вариант Б: полоса моря у выбранных сторон, ширина — гладкий 1D-шум.
static func _apply_sea_edge(sea_mask: Array, rows: int, cols: int,
		cfg: Dictionary, max_sea_depth: int, sides: Array) -> void:
	if sides.is_empty():
		return

	var width_min: float = float(cfg.get("edge_width_min", 1))
	var width_max: float = float(cfg.get("edge_width_max", 7))
	var envelope_strength: float = float(cfg.get("edge_envelope_strength", 0.0))

	# Крупномасштабный 1D-шум для естественности берега
	var envelope_noise: FastNoiseLite = FastNoiseLite.new()
	envelope_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	envelope_noise.seed = randi()
	envelope_noise.frequency = 0.08

	for side in sides:
		var len: int = rows if (side == "east" or side == "west") else cols
		var arr: Array = []
		var seg: int = 8
		var i0: int = -1
		var v0: float = 0.0
		var v1: float = randf()

		# Центр стороны для параболической огибающей
		var center_pos: float = float(len) / 2.0
		var half_len: float = float(len) / 2.0

		for coord in range(len):
			if coord / seg != i0:
				i0 = coord / seg
				v0 = v1
				v1 = randf()
			var t: float = 0.5 - 0.5 * cos(float(coord % seg) / float(seg) * PI)
			var base_width: float = lerpf(width_min, width_max, lerpf(v0, v1, t))

			# Параболическая огибающая: 1 в центре, 0 на краях
			var dist_from_center: float = abs(float(coord) - center_pos)
			var parabola: float = 1.0 - pow(dist_from_center / half_len, 2.0)
			parabola = max(0.0, parabola)

			# Комбинируем параболу с шумом
			if envelope_strength > 0.0:
				var noise_val: float = 0.5 + 0.5 * envelope_noise.get_noise_1d(float(coord))
				var env: float = lerp(parabola, parabola * noise_val, envelope_strength)
				base_width *= env

			arr.append(int(round(base_width)))

		# Применяем ширину к гексам
		for coord in range(len):
			var width: int = arr[coord]
			if width <= 0:
				continue
			for depth in range(width):
				if depth >= max_sea_depth:
					break
				var r: int = 0
				var c: int = 0
				match side:
					"east": r = coord; c = cols - 1 - depth
					"west": r = coord; c = depth
					"south": r = rows - 1 - depth; c = coord
					"north": r = depth; c = coord
				if r >= 0 and r < rows and c >= 0 and c < cols:
					sea_mask[r][c] = true


# Генерирует острова внутри маски моря (режим "edge"): часть морских гексов
# превращается в сушу группами (BFS-рост из случайных seed-точек).
# Количество "умно" подстраивается под площадь моря: target = sea_area *
# edge_island_density, фактическое число — randi_range(0, target + 1). В
# маленьком море это часто даёт 0 островов, в большом — может дать много.
# Вызывается ДО _apply_beach, чтобы пляж корректно обвёл новые острова.
static func _apply_sea_islands(sea_mask: Array, rows: int, cols: int,
		cfg: Dictionary, city_row: int, city_col: int) -> void:
	# --- Чтение параметров с дефолтами ---
	var size_range: Array = cfg.get("edge_island_size", [1, 5])
	var size_min: int = 1
	var size_max: int = 5
	if size_range is Array and size_range.size() >= 2:
		size_min = maxi(1, int(size_range[0]))
		size_max = maxi(size_min, int(size_range[1]))
	var density: float = float(cfg.get("edge_island_density", 0.003))
	var min_distance: int = maxi(0, int(cfg.get("edge_island_min_distance", 3)))
	var max_attempts: int = maxi(1, int(cfg.get("edge_island_max_attempts", 60)))

	# --- Считаем площадь моря и целевое количество островов ---
	var sea_area := 0
	for r in range(rows):
		for c in range(cols):
			if sea_mask[r][c]:
				sea_area += 1
	# Без моря (или совсем крошечное) — выходим, делать нечего.
	if sea_area < size_min:
		return

	var target: int = int(round(float(sea_area) * density))
	# Разброс: 0..target+1. Если target=0, даёт 0..1 (редкий одиночный остров);
	# если target=10, даёт 0..11. Это и есть «может быть, но не обязано».
	var actual_count: int = randi_range(0, target + 1)
	if actual_count <= 0:
		return

	# --- Список всех морских гексов (для быстрого случайного выбора seed) ---
	var sea_cells: Array = []
	for r in range(rows):
		for c in range(cols):
			if sea_mask[r][c]:
				sea_cells.append({"row": r, "col": c})
	if sea_cells.is_empty():
		return
	sea_cells.shuffle()

	# --- Занятые точки (центры уже размещённых островов) — для min_distance ---
	var occupied: Array = []

	var islands_placed := 0
	var island_index := 0
	while island_index < actual_count and not sea_cells.is_empty():
		# Размер конкретного острова в этом размещении.
		var island_size: int = randi_range(size_min, size_max)
		# Ищем seed-точку: перебираем sea_cells в случайном порядке, пока не
		# найдём подходящую (в море + не слишком близко к городу/другим островам).
		var seed_index := -1
		var attempts := 0
		while attempts < max_attempts and sea_cells.size() > 0:
			var idx: int = randi() % sea_cells.size()
			var candidate = sea_cells[idx]
			# Слишком близко к городу (стартовая зона) — пропускаем. 2 гекса —
			# потому что _ensure_plain_zone очищает радиус 2 вокруг города;
			# даже если остров на границе этого радиуса, его гексы уйдут в
			# равнину и он «исчезнет», что нарушит инвариант «остров в море».
			if HexUtils.hex_distance(candidate.row, candidate.col, city_row, city_col) <= 2:
				attempts += 1
				# Удаляем из пула, чтобы не перебирать вечно.
				sea_cells.remove_at(idx)
				continue
			# Слишком близко к другому острову — пропускаем.
			var too_close := false
			for occ in occupied:
				if HexUtils.hex_distance(candidate.row, candidate.col, occ.row, occ.col) < min_distance:
					too_close = true
					break
			if too_close:
				attempts += 1
				sea_cells.remove_at(idx)
				continue
			# Нашли подходящую seed-точку.
			seed_index = idx
			break
		if seed_index < 0:
			# Не нашли место за max_attempts попыток — выходим, оставшиеся
			# острова не размещаем (лучше меньше, чем бесконечный цикл).
			break
		var seed = sea_cells[seed_index]
		sea_cells.remove_at(seed_index)

		# --- BFS-рост кластера: добавляем соседей по одному, пока не наберём island_size ---
		var cluster: Array = [seed]
		var cluster_set := {}
		cluster_set["%d,%d" % [seed.row, seed.col]] = true
		var frontier: Array = [seed]
		while cluster.size() < island_size and not frontier.is_empty():
			var next_frontier: Array = []
			for cell in frontier:
				if cluster.size() >= island_size:
					break
				var neighbors = HexUtils.get_neighbors_odd_r(cell.row, cell.col, rows, cols)
				neighbors.shuffle()
				for n in neighbors:
					if cluster.size() >= island_size:
						break
					var nk := "%d,%d" % [n.row, n.col]
					if cluster_set.has(nk):
						continue
					# Растём только по морю — не «прыгаем» на сушу/острова.
					if not sea_mask[n.row][n.col]:
						continue
					cluster_set[nk] = true
					cluster.append(n)
					next_frontier.append(n)
					if cluster.size() >= island_size:
						break
			frontier = next_frontier
		if cluster.is_empty():
			continue

		# --- Превращаем гексы кластера из моря в сушу (сброс sea_mask) ---
		for cell in cluster:
			sea_mask[cell.row][cell.col] = false
		# Запоминаем seed как занятую точку для будущих min_distance проверок.
		occupied.append(seed)
		islands_placed += 1
		island_index += 1

	if islands_placed > 0:
		print("map_generator: размещено островов в море: %d (целевое количество было %d, площадь моря %d)" %
				[islands_placed, target, sea_area])


# Гладкая ширина полосы моря вдоль стороны (1D-шум).
# На данный момент не вызывается (реальный _apply_sea_edge использует свой
# 1D-шум через FastNoiseLite). Сохранён для будущих экспериментов с
# генерацией береговой линии.
static func _smooth_width(row: int, col: int, side: String, width_min: int, width_max: int) -> float:
	var t := 0.0
	if side == "east" or side == "west":
		t = float(row) / 10.0
	else:
		t = float(col) / 10.0
	# Сумма синусоид даёт плавное изменение ширины вдоль берега.
	var v = 0.5 + 0.5 * sin(t * 6.283 + _hash_noise(row, col) * 6.283)
	return lerpf(float(width_min), float(width_max), v)


# Детерминированный псевдослучайный шум по координатам (0..1).
# Константа-смещение 1013904223 гарантирует, что для (0,0) шум не равен 0.0
# (иначе при sea_level = 0.0 гекс (0,0) всегда становился бы морем).
static func _hash_noise(row: int, col: int) -> float:
	var h = row * 374761393 + col * 668265263 + 1013904223
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float((h & 0x7fffffff) % 10000) / 10000.0


# Превращает сушу, соседнюю с морем, в пляж (beach).
static func _apply_beach(tile_data: Array, sea_mask: Array, rows: int, cols: int) -> void:
	# Пляж формируется только на суше, связанной с краем карты. Замкнутые
	# морем участки сохраняют рельеф Вороного и не превращаются в марши.
	var edge_connected_land := []
	for r in range(rows):
		var row_arr = []
		row_arr.resize(cols)
		row_arr.fill(false)
		edge_connected_land.append(row_arr)

	var queue: Array = []
	for r in range(rows):
		for c in range(cols):
			if r != 0 and r != rows - 1 and c != 0 and c != cols - 1:
				continue
			if sea_mask[r][c] or edge_connected_land[r][c]:
				continue
			edge_connected_land[r][c] = true
			queue.append({"row": r, "col": c})

	var queue_index := 0
	while queue_index < queue.size():
		var current = queue[queue_index]
		queue_index += 1
		for n in HexUtils.get_neighbors_odd_r(current.row, current.col, rows, cols):
			if sea_mask[n.row][n.col] or edge_connected_land[n.row][n.col]:
				continue
			edge_connected_land[n.row][n.col] = true
			queue.append(n)

	for r in range(rows):
		for c in range(cols):
			if sea_mask[r][c] or not edge_connected_land[r][c]:
				continue
			# Гекс суши: проверяем, есть ли сосед-море.
			var has_sea_neighbor := false
			for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
				if sea_mask[n.row][n.col]:
					has_sea_neighbor = true
					break
			if has_sea_neighbor:
				tile_data[r][c]["terrain"] = "beach"
				tile_data[r][c]["_is_beach"] = true


# Морские острова не должны состоять из озёр: заменяем озёра в замкнутых
# морем land-компонентах на равнину. Вызывается ДО проверки минимального
# числа озёр на карте.
static func replace_island_lakes(tile_data: Array, sea_mask: Array, rows: int, cols: int) -> void:
	var edge_connected_land := []
	for r in range(rows):
		var row_arr = []
		row_arr.resize(cols)
		row_arr.fill(false)
		edge_connected_land.append(row_arr)

	var queue: Array = []
	for r in range(rows):
		for c in range(cols):
			if r != 0 and r != rows - 1 and c != 0 and c != cols - 1:
				continue
			if sea_mask[r][c] or edge_connected_land[r][c]:
				continue
			edge_connected_land[r][c] = true
			queue.append({"row": r, "col": c})

	var queue_index := 0
	while queue_index < queue.size():
		var current = queue[queue_index]
		queue_index += 1
		for n in HexUtils.get_neighbors_odd_r(current.row, current.col, rows, cols):
			if sea_mask[n.row][n.col] or edge_connected_land[n.row][n.col]:
				continue
			edge_connected_land[n.row][n.col] = true
			queue.append(n)

	for r in range(rows):
		for c in range(cols):
			if sea_mask[r][c] or edge_connected_land[r][c]:
				continue
			if tile_data[r][c].get("terrain", "plain") == "lake":
				tile_data[r][c]["terrain"] = "plain"
				tile_data[r][c]["cover"] = _roll_cover("plain")


# Марши на побережье (пляже): часть beach-гексов вокруг моря с шансом
# MARSH_CHANCE превращается в marsh. Внутренняя суша морских островов
# НЕ затрагивается — только прибрежная зона. Вызывается ПОСЛЕ применения
# маски моря/пляжа (когда terrain == "sea" и "beach" уже выставлены).
static func apply_sea_coast_marshes(tile_data: Array, rows: int, cols: int) -> void:
	var sea_hexes: Array = []
	for r in range(rows):
		for c in range(cols):
			if tile_data[r][c].get("terrain", "plain") == "sea":
				sea_hexes.append({"row": r, "col": c})

	# У морей: марши образуются ТОЛЬКО на побережье (пляже beach), а не на
	# внутренней суше островков. Пляж — прибрежная заболоченная зона.
	for water in sea_hexes:
		var neighbors = HexUtils.get_neighbors_odd_r(water.row, water.col, rows, cols)
		for n in neighbors:
			var t = tile_data[n.row][n.col]
			if t.get("terrain", "plain") != "beach":
				continue
			if randf() < MARSH_CHANCE:
				t["terrain"] = "marsh"
				t["_is_marsh"] = true
				t["_is_beach"] = false


# Локальная копия `_roll_cover` из map_generator.gd: нужна для
# replace_island_lakes (озеро в морском острове превращаем в равнину, у
# которой должен быть cover по весам terrains.json). Когда map_generator
# тоже станет чисто утилитным, можно будет вынести cover-логику в
# отдельный модуль. Пока — дублируем минимально.
static func _roll_cover(terrain_type: String) -> String:
	var t: Dictionary = GameData.terrains.get(terrain_type, {})
	var chances: Dictionary = t.get("cover_chance", {})
	if chances.is_empty():
		return "none"
	var total := 0.0
	total = 0.0
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
