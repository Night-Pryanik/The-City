# Headless-тест правила «Чанк разведки должен граничить с известной территорией»:
#   godot --headless --path "E:\The City" --script res://tools/test_scouting_frontier.gd
#
# Тест поднимает РЕАЛЬНУЮ сцену MainMap (новая игра на настоящей карте) и
# проверяет правило на живых данных:
#
#   1. Положительный случай: неисследованный гекс Региона у границы Кольца
#      Влияния → чанк непустой, примыкает к известной территории, кнопка
#      «Отправить разведчиков» активна, start_scouting() тратит монеты и
#      запускает разведку.
#   2. Инвариант по всей карте (до Картографии — по Региону, после — и по
#      туману войны): активность кнопки разведки РАВНА примыканию чанка к
#      известной территории, а тултип недоступного чанка объясняет причину.
#   3. Отрицательный случай: чанк в тумане войны, оторванный от известного
#      мира (таких на карте тысячи) → кнопка неактивна с причиной,
#      start_scouting() не запускается и монеты НЕ списывает.
#   4. Динамика границы: стоит пометить соседний гекс разведанным — тот же
#      чанк становится доступен и разведка запускается (граница «ползёт»).
#   5. Страховка публичной точки входа: пустой чанк разведку не запускает и
#      монеты не тратит.
#
# Известная территория = Кольцо Влияния (in_influence) ИЛИ разведанные гексы
# (is_explored) — см. main_map.is_hex_known / is_chunk_adjacent_to_known.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const FRONTIER_TOOLTIP := "Область не граничит с исследованной территорией"

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state = {"failed": false}

	# Автозагрузки берём через дерево сцены: в режиме --script имена
	# GameData/CityData недоступны на этапе компиляции этого файла.
	# new_game() грузит данные игры и сбрасывает состояние города —
	# Картография на старте не изучена.
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var city = get_root().get_node("CityData")

	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame

	var em = main_map.expansion_manager
	var cp = main_map.control_panel

	check(main_map.tile_data.size() == main_map.map_rows,
			"карта не инициализирована (tile_data пуст)", state)
	check(not main_map.is_cartography_researched(),
			"на старте новой игры Картография не должна быть изучена", state)
	check(not main_map.is_chunk_adjacent_to_known([]),
			"пустой чанк не может граничить с известной территорией", state)

	# ============ 1. Разведка у границы Кольца Влияния ============
	var front_hex = _find_region_hex_near_known(main_map)
	check(front_hex != null, "не найден неисследованный гекс Региона у границы Кольца", state)
	if front_hex == null:
		_finish(main_map, state)
		return

	var front_chunk: Array = em.get_chunk_hexes(front_hex.row, front_hex.col)
	check(front_chunk.size() > 0, "чанк разведки у границы Кольца не должен быть пустым", state)
	check(main_map.is_chunk_adjacent_to_known(front_chunk),
			"чанк у границы Кольца обязан примыкать к известной территории", state)

	var front_action = _find_action(cp._collect_actions(front_hex.row, front_hex.col,
			main_map.tile_data[front_hex.row][front_hex.col]), "scout_chunk")
	check(front_action != null, "у гекса у границы Кольца должна быть кнопка разведки", state)
	if front_action != null:
		check(front_action.get("enabled", false),
				"кнопка разведки у границы Кольца должна быть активна", state)

	city.add_treasury(em.get_chunk_scout_cost(front_chunk))
	var front_treasury_before: int = city.treasury
	var front_cost: int = em.get_chunk_scout_cost(front_chunk)
	main_map.start_scouting(front_chunk)
	check(main_map.is_scouting, "разведка чанка у границы Кольца должна запускаться", state)
	check(city.treasury == front_treasury_before - front_cost,
			"за разведку должно списаться ровно цена чанка (%d): было %d, стало %d"
					% [front_cost, front_treasury_before, city.treasury], state)
	# Имитируем завершение экспедиции: гексы чанка становятся разведанными,
	# граница известного мира сдвигается вперёд.
	_mark_explored(main_map, front_chunk)
	main_map.is_scouting = false
	main_map.scouting_chunk = []

	# ============ 2. Инвариант по всей карте ДО Картографии ============
	check(not main_map.is_scouting, "перед проверкой инварианта разведка должна быть завершена", state)
	var stats_before: Dictionary = _check_frontier_invariant(main_map, state)
	check(int(stats_before["available"]) > 0,
			"до Картографии должен существовать хотя бы один доступный чанк разведки в Регионе", state)
	print("FRONTIER STATS (до Картографии): ", stats_before)

	# ============ 3. Отрицательный случай: оторванный чанк в тумане ============
	city.unlocked_technologies.append("cartography")
	check(main_map.is_cartography_researched(),
			"is_cartography_researched() должен стать true после изучения технологии", state)

	var stats_after: Dictionary = _check_frontier_invariant(main_map, state)
	check(int(stats_after["detached"]) > 0,
			"в тумане войны должны существовать чанки, оторванные от известного мира", state)
	print("FRONTIER STATS (с Картографией): ", stats_after)

	var fog_hex = _find_detached_fog_hex(main_map, em)
	check(fog_hex != null, "не найден оторванный от известного мира гекс тумана войны", state)
	if fog_hex == null:
		_finish(main_map, state)
		return

	var fog_chunk: Array = em.get_chunk_hexes(fog_hex.row, fog_hex.col)
	check(fog_chunk.size() > 0,
			"чанк в тумане войны должен собираться — подсветка остаётся видимой", state)
	check(not main_map.is_chunk_adjacent_to_known(fog_chunk),
			"оторванный чанк не должен примыкать к известной территории", state)

	var fog_action = _find_action(cp._collect_actions(fog_hex.row, fog_hex.col,
			main_map.tile_data[fog_hex.row][fog_hex.col]), "scout_chunk")
	check(fog_action != null, "кнопка разведки должна быть и у недоступного чанка (с причиной)", state)
	if fog_action != null:
		check(not fog_action.get("enabled", true),
				"кнопка разведки оторванного чанка должна быть неактивна", state)
		check(str(fog_action.get("tooltip", "")) == FRONTIER_TOOLTIP,
				"тултип оторванного чанка должен объяснять причину (получено: «%s»)"
						% str(fog_action.get("tooltip", "")), state)

	var fog_treasury_saved: int = city.treasury
	main_map.start_scouting(fog_chunk)
	check(not main_map.is_scouting,
			"start_scouting() не должен запускаться для оторванного чанка", state)
	check(city.treasury == fog_treasury_saved,
			"за отказ монеты списываться НЕ должны: было %d, стало %d"
					% [fog_treasury_saved, city.treasury], state)

	# ============ 4. Динамика границы известного мира ============
	var frontier_hex = _first_neighbor(main_map, fog_hex.row, fog_hex.col)
	check(frontier_hex != null, "у гекса тумана должен быть хотя бы один сосед на карте", state)
	if frontier_hex != null:
		# Помечаем соседний гекс разведанным: граница известного мира доходит
		# до чанка, и он обязан стать доступным без перезапуска чего-либо.
		main_map.tile_data[frontier_hex.row][frontier_hex.col]["is_explored"] = true
		check(main_map.is_chunk_adjacent_to_known(fog_chunk),
				"после разведки соседнего гекса чанк обязан стать доступным", state)
		var fog_action_after = _find_action(cp._collect_actions(fog_hex.row, fog_hex.col,
				main_map.tile_data[fog_hex.row][fog_hex.col]), "scout_chunk")
		check(fog_action_after != null, "кнопка разведки должна остаться у доступного чанка", state)
		if fog_action_after != null:
			check(fog_action_after.get("enabled", false),
					"после появления разведанного соседа кнопка разведки должна стать активной", state)

		var fog_cost: int = em.get_chunk_scout_cost(fog_chunk)
		city.add_treasury(fog_cost)
		var fog_treasury_before: int = city.treasury
		main_map.start_scouting(fog_chunk)
		check(main_map.is_scouting,
				"после появления разведанного соседа разведка должна запускаться", state)
		check(city.treasury == fog_treasury_before - fog_cost,
				"за разведку приграничного чанка должно списаться ровно цена чанка (%d)" % fog_cost, state)
		main_map.is_scouting = false
		main_map.scouting_chunk = []

	# ============ 5. Страховка: пустой чанк ============
	var empty_treasury_saved: int = city.treasury
	main_map.start_scouting([])
	check(not main_map.is_scouting, "пустой чанк разведку не запускает", state)
	check(city.treasury == empty_treasury_saved, "пустой чанк монеты не тратит", state)

	_finish(main_map, state)

# Проверяет инвариант правила по всей карте: для каждого неисследованного гекса
# активность кнопки разведки равна примыканию его чанка к известной территории,
# а недоступный чанк объясняет причину в тултипе. Возвращает счётчики для
# диагностики (сколько чанков доступно / оторвано / не собирается вовсе).
func _check_frontier_invariant(main_map, state: Dictionary) -> Dictionary:
	var cp = main_map.control_panel
	var em = main_map.expansion_manager
	var available := 0
	var detached := 0
	var empty_chunks := 0
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			var chunk: Array = em.get_chunk_hexes(row, col)
			if chunk.is_empty():
				empty_chunks += 1
				continue
			var adjacent: bool = main_map.is_chunk_adjacent_to_known(chunk)
			if adjacent:
				available += 1
			else:
				detached += 1
			var action = _find_action(cp._collect_actions(row, col, tile), "scout_chunk")
			if action == null:
				continue
			check(bool(action.get("enabled", false)) == adjacent,
					"(%d,%d): активность кнопки разведки должна совпадать с примыканием чанка (примыкает=%s)"
							% [row, col, str(adjacent)], state)
			if not adjacent:
				check(str(action.get("tooltip", "")) == FRONTIER_TOOLTIP,
						"(%d,%d): тултип недоступного чанка должен объяснять причину (получено: «%s»)"
								% [row, col, str(action.get("tooltip", ""))], state)
	return {"available": available, "detached": detached, "empty_chunks": empty_chunks}

# Первый неисследованный гекс Региона, у которого есть известный сосед
# (граница известного мира проходит рядом).
func _find_region_hex_near_known(main_map):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			if not main_map.is_valid_hex(row, col):
				continue
			var tile = main_map.tile_data[row][col]
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			if _hex_has_known_neighbor(main_map, row, col):
				return {"row": row, "col": col}
	return null

# Первый гекс тумана войны, чей чанк не примыкает к известной территории.
func _find_detached_fog_hex(main_map, em):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			if main_map.is_valid_hex(row, col):
				continue
			var tile = main_map.tile_data[row][col]
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			var chunk: Array = em.get_chunk_hexes(row, col)
			if chunk.is_empty():
				continue
			if not main_map.is_chunk_adjacent_to_known(chunk):
				return {"row": row, "col": col}
	return null

func _hex_has_known_neighbor(main_map, row: int, col: int) -> bool:
	for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
		if main_map.is_hex_known(n.row, n.col):
			return true
	return false

func _first_neighbor(main_map, row: int, col: int):
	var neighbors: Array = HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols)
	if neighbors.is_empty():
		return null
	return neighbors[0]

func _mark_explored(main_map, chunk: Array) -> void:
	for hex in chunk:
		main_map.tile_data[hex.row][hex.col]["is_explored"] = true

func _find_action(actions: Array, type: String):
	for action in actions:
		if action.get("type", "") == type:
			return action
	return null

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("SCOUTING FRONTIER TEST FAILED")
		quit(1)
	else:
		print("SCOUTING FRONTIER TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
