# Headless-тест подсветки наведения/выделения гексов (map_renderer, ФАЗЫ 2.5 и 3.5):
#   godot --headless --path . --script res://tests/test_highlight_hexes.gd
#
# Рендерер подсвечивает набор гексов, который отдаёт
# expansion_manager.get_highlight_hexes(row, col):
#   - гекс в Кольце Влияния → только он сам;
#   - вне Кольца → весь чанк разведки/покупки (get_chunk_hexes);
#   - если чанка нет, а гекс ИССЛЕДОВАН (разведанная область вне Региона) →
#     чанк подсветки до 5 гексов, построенный BFS наружу от гекса под курсором
#     (_get_explored_chunk_hexes);
#   - если чанка нет и гекс в кольце влияния чужого городка → сам гекс:
#     клик и наведение не должны быть «молчаливыми».
# Также проверяется детекция изменений в update_hovered_chunk: она идёт по
# набору ПОДСВЕТКИ (иначе переход между разведанными кластерами давал
# [] == [], сигнал chunk_hovered не эмитился, и подсветка «застывала» на
# предыдущей позиции курсора).
# Проверяется на живых данных реальной сцены MainMap (новая игра).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state = {"failed": false}
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var city = get_root().get_node("CityData")
	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame
	var em = main_map.expansion_manager

	# --- 1. Гекс города (Кольцо Влияния): подсвечивается только он сам ---
	var city_hl: Array = em.get_highlight_hexes(main_map.city_row, main_map.city_col)
	check(city_hl.size() == 1
		and city_hl[0].row == main_map.city_row and city_hl[0].col == main_map.city_col,
		"гекс в Кольце Влияния должен подсвечиваться только сам", state)

	# --- 2. Гекс вне карты: подсветки нет ---
	check(em.get_highlight_hexes(-5, -5).is_empty(),
		"гекс вне карты не должен давать подсветку", state)

	# --- 3. Неисследованный гекс Региона: подсвечивается весь чанк ---
	var region_hex = _find_unexplored_region_hex(main_map)
	check(region_hex != null, "не найден неисследованный гекс Региона", state)
	if region_hex != null:
		var chunk: Array = em.get_chunk_hexes(region_hex.row, region_hex.col)
		check(chunk.size() > 0, "чанк неисследованного гекса Региона не должен быть пустым", state)
		var hl: Array = em.get_highlight_hexes(region_hex.row, region_hex.col)
		check(hl.size() == chunk.size(),
			"для неисследованного гекса должен подсвечиваться весь чанк (%d против %d)"
				% [hl.size(), chunk.size()], state)

	# --- 4. Неисследованный гекс тумана войны (с Картографией): подсветка есть ---
	city.unlocked_technologies.append("cartography")
	var fog_hex = _find_fog_hex(main_map)
	check(fog_hex != null, "не найден неисследованный гекс тумана войны", state)
	if fog_hex != null:
		var hl_fog: Array = em.get_highlight_hexes(fog_hex.row, fog_hex.col)
		check(hl_fog.size() >= 1,
			"неисследованный гекс тумана должен подсвечиваться (чанк или сам гекс)", state)
		check(_contains_hex(hl_fog, fog_hex.row, fog_hex.col),
			"подсветка обязана включать наведённый гекс", state)

	# --- 5. ИССЛЕДОВАННЫЙ гекс вне Региона: подсвечивается чанк до 5 гексов ---
	# Это и был «молчаливый» клик: get_chunk_hexes() для такого гекса возвращает
	# пустой массив (покупка возможна только в Регионе). Фолбэк строит BFS от
	# гекса под курсором по разведанным гексам (у одиночного гекса чанк состоит
	# из него самого).
	var explored_fog = _find_fog_hex(main_map)
	if explored_fog != null:
		main_map.tile_data[explored_fog.row][explored_fog.col]["is_explored"] = true
		check(em.get_chunk_hexes(explored_fog.row, explored_fog.col).is_empty(),
			"у исследованного гекса вне Региона чанка нет (причина «молчаливого» клика)", state)
		var hl_explored: Array = em.get_highlight_hexes(explored_fog.row, explored_fog.col)
		check(hl_explored.size() >= 1 and hl_explored.size() <= 5,
			"исследованный гекс вне Региона подсвечивается чанком до 5 гексов (получено %d)"
				% hl_explored.size(), state)
		check(_contains_hex(hl_explored, explored_fog.row, explored_fog.col),
			"подсветка должна включать наведённый гекс", state)
		for h in hl_explored:
			check(bool(main_map.tile_data[h.row][h.col].get("is_explored", false)),
				"кластер состоит только из разведанных гексов", state)
			check(not bool(main_map.tile_data[h.row][h.col].get("in_influence", false)),
				"кластер не включает Кольцо Влияния", state)
			check(not bool(main_map.tile_data[h.row][h.col].get("in_town_influence", false)),
				"кластер не пересекает кольца чужих городков", state)

	# --- 5a. Кластер из нескольких гексов: подсвечивается целиком из любой ---
	# --- точки, разные гексы одного кластера дают ИДЕНТИЧНЫЙ набор ----------
	# Соседний с разведанным гекс тумана делаем разведанным — кластер растёт.
	var neighbor = null
	var isolated = null
	for n in em._get_neighbors(explored_fog.row, explored_fog.col):
		if not main_map.is_hex_on_map(n.row, n.col):
			continue
		var nt = main_map.tile_data[n.row][n.col]
		if nt == null or bool(nt.get("in_influence", false)) or bool(nt.get("in_town_influence", false)):
			continue
		if main_map.is_valid_hex(n.row, n.col):
			continue
		neighbor = n
		break
	check(neighbor != null, "у разведанного гекса должен найтись сосед в тумане", state)
	if neighbor != null:
		main_map.tile_data[neighbor.row][neighbor.col]["is_explored"] = true
		var hl_from_first: Array = em.get_highlight_hexes(explored_fog.row, explored_fog.col)
		var hl_from_second: Array = em.get_highlight_hexes(neighbor.row, neighbor.col)
		check(hl_from_first.size() == 2 and hl_from_second.size() == 2,
			"кластер из двух разведанных гексов подсвечивается целиком (%d и %d)"
				% [hl_from_first.size(), hl_from_second.size()], state)
		check(em._chunk_equals(hl_from_first, hl_from_second),
			"один и тот же кластер с разных гексов даёт идентичный набор", state)
		# --- 5b. Изолированный разведанный гекс: кластер только из него ---
		if fog_hex != null:
			# Берем гекс тумана, не соседствующий с уже разведанными.
			for cand_row in range(main_map.map_rows):
				if isolated != null:
					break
				for cand_col in range(main_map.map_cols):
					if not main_map.is_hex_on_map(cand_row, cand_col):
						continue
					var ct = main_map.tile_data[cand_row][cand_col]
					if ct == null or bool(ct.get("is_explored", false)) \
							or bool(ct.get("in_influence", false)) \
							or bool(ct.get("in_town_influence", false)):
						continue
					if main_map.is_valid_hex(cand_row, cand_col):
						continue
					var has_explored_neighbor := false
					for cn in em._get_neighbors(cand_row, cand_col):
						if main_map.is_hex_on_map(cn.row, cn.col):
							var cnt = main_map.tile_data[cn.row][cn.col]
							if cnt != null and bool(cnt.get("is_explored", false)):
								has_explored_neighbor = true
								break
					if not has_explored_neighbor:
						isolated = {"row": cand_row, "col": cand_col}
						break
		check(isolated != null, "не найден изолированный гекс тумана для кластера из 1", state)
		if isolated != null:
			main_map.tile_data[isolated.row][isolated.col]["is_explored"] = true
			var hl_iso: Array = em.get_highlight_hexes(isolated.row, isolated.col)
			check(hl_iso.size() == 1 and _contains_hex(hl_iso, isolated.row, isolated.col),
				"изолированный разведанный гекс подсвечивается сам", state)

	# --- 5c. Регресс «застывшей» подсветки (баг 2) через сигнал ---
	# Раньше update_hovered_chunk сравнивал чанк ДЕЙСТВИЙ (get_chunk_hexes):
	# у разведанных гексов вне Региона он всегда пуст, переход между двумя
	# такими кластерами давал [] == [] — сигнал не эмитился, и рендерер
	# продолжал показывать подсветку предыдущей позиции курсора. Теперь
	# детекция идёт по набору подсветки.
	var signal_events: Array = []
	var handler = func(chunk: Array): signal_events.append(chunk.duplicate(true))
	em.chunk_hovered.connect(handler)
	# Наведение на первый гекс кластера → 1 эмит с кластером из 2 гексов.
	em.update_hovered_chunk(explored_fog.row, explored_fog.col)
	check(signal_events.size() == 1 and signal_events[0].size() == 2,
		"наведение на кластер эмитит сигнал с 2 гексами", state)
	# Переход на второй гекс ТОГО ЖЕ кластера → 0 эмитов (набор не изменился).
	em.update_hovered_chunk(neighbor.row, neighbor.col)
	check(signal_events.size() == 1,
		"переход внутри кластера не эмитит сигнал лишний раз", state)
	# Переход на изолированный гекс → 1 эмит с набором из 1 гекса.
	em.update_hovered_chunk(isolated.row, isolated.col)
	check(signal_events.size() == 2 and signal_events[1].size() == 1,
		"переход на другой кластер эмитит сигнал с новым набором", state)
	check(_contains_hex(signal_events[1], isolated.row, isolated.col)
		and not _contains_hex(signal_events[1], explored_fog.row, explored_fog.col),
		"новая подсветка — на новом кластере, а не на предыдущем", state)
	# Уход курсора с карты → 1 эмит с пустым набором.
	em.clear_hovered_chunk()
	check(signal_events.size() == 3 and signal_events[2].is_empty(),
		"уход курсора эмитит сигнал с пустым набором", state)
	em.chunk_hovered.disconnect(handler)

	# --- 6. Гекс в кольце влияния чужого городка: тоже сам гекс ---
	var town_ring = _find_town_ring_hex(main_map)
	check(town_ring != null, "не найден гекс в кольце влияния чужого городка", state)
	if town_ring != null:
		# Для НЕисследованного гекса кольца чанк разведки собирается — разведчиков
		# туда посылать можно (это разрешено правилами). Пустой чанк — у
		# ИССЛЕДОВАННОГО гекса кольца: покупка на территории чужого городка
		# запрещена, и без фолбэка клик по такому гексу не подсвечивал ничего.
		main_map.tile_data[town_ring.row][town_ring.col]["is_explored"] = true
		check(em.get_chunk_hexes(town_ring.row, town_ring.col).is_empty(),
			"у исследованного гекса в кольце чужого городка чанка нет", state)
		var hl_ring: Array = em.get_highlight_hexes(town_ring.row, town_ring.col)
		check(hl_ring.size() == 1,
			"гекс в кольце чужого городка должен подсвечиваться сам (получено %d)"
				% hl_ring.size(), state)

	# --- 7. Инвариант: для гекса на карте подсветка никогда не пуста ---
	var empty_highlights := 0
	var checked_hexes := 0
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			if main_map.tile_data[row][col] == null:
				continue
			checked_hexes += 1
			if em.get_highlight_hexes(row, col).is_empty():
				empty_highlights += 1
	check(empty_highlights == 0,
		"для каждого гекса на карте подсветка не должна быть пустой (пустых: %d из %d)"
			% [empty_highlights, checked_hexes], state)
	print("HIGHLIGHT STATS: гексов проверено %d, пустых подсветок %d" % [checked_hexes, empty_highlights])

	_finish(main_map, state)# Первый неисследованный гекс Региона.
func _find_unexplored_region_hex(main_map):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if tile == null:
				continue
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			if main_map.is_valid_hex(row, col):
				return {"row": row, "col": col}
	return null

# Первый неисследованный гекс тумана войны (вне Региона, вне Кольца Влияния и
# вне кольца чужого городка).
func _find_fog_hex(main_map):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			if main_map.is_valid_hex(row, col):
				continue
			var tile = main_map.tile_data[row][col]
			if tile == null:
				continue
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			if bool(tile.get("in_town_influence", false)):
				continue
			return {"row": row, "col": col}
	return null

# Первый гекс в кольце влияния чужого городка (вне Кольца Влияния игрока и вне
# Региона — там get_chunk_hexes гарантированно пуст).
func _find_town_ring_hex(main_map):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if tile == null:
				continue
			if not bool(tile.get("in_town_influence", false)):
				continue
			if bool(tile.get("in_influence", false)) or main_map.is_valid_hex(row, col):
				continue
			return {"row": row, "col": col}
	return null

func _contains_hex(hexes: Array, row: int, col: int) -> bool:
	for hex in hexes:
		if hex.row == row and hex.col == col:
			return true
	return false

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("HIGHLIGHT HEXES TEST FAILED")
		quit(1)
	else:
		print("HIGHLIGHT HEXES TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
