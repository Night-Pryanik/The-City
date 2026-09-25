# Headless-тест правила «Разведка вне Региона — только после Картографии»:
#   godot --headless --path "E:\The City" --script res://tools/test_cartography_gate.gd
#
# Тест поднимает РЕАЛЬНУЮ сцену MainMap (новая игра на настоящей карте) и
# проверяет правило на живых данных:
#
#   1. ДО Картографии:
#      - чанк неисследованного гекса в Регионе собирается и не выходит за Регион;
#      - чанк гекса в тумане войны (вне Региона) ПУСТОЙ — значит, подсветка
#        и кнопка «Отправить разведчиков» там не появляются;
#      - main_map.is_hex_interactive() запрещает наведение/клик вне Региона;
#      - start_scouting() не запускает разведку чанка в тумане (страховка на
#        публичной точке входа), но запускает в Регионе.
#
#   2. ПОСЛЕ изучения Картографии:
#      - чанк в тумане войны собирается и включает стартовый гекс;
#      - is_hex_interactive() разрешает взаимодействие;
#      - start_scouting() запускает разведку.
#
# Дополнительное правило (проверяется целиком в tools/test_scouting_frontier.gd):
# разведку можно отправить только в чанк, примыкающий к известной территории
# (main_map.is_chunk_adjacent_to_known). Поэтому здесь и гекс Региона, и гекс
# тумана берутся у границы известного мира: перед проверкой разведки в тумане
# соседний гекс Региона помечается разведанным.
extends SceneTree

func _initialize():
	_run()

func _run() -> void:
	var state = {"failed": false}

	# Автозагрузки берём через дерево сцены: в режиме --script имена
	# GameData/CityData недоступны на этапе компиляции этого файла.
	# new_game() заодно грузит все данные (GameData.load_all_data) и
	# сбрасывает состояние города (CityData.setup) — Картография не изучена.
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var city = get_root().get_node("CityData")

	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame

	check(main_map.tile_data.size() == main_map.map_rows,
			"карта не инициализирована (tile_data пуст)", state)
	check(not city.is_tech_unlocked("cartography"),
			"на старте новой игры Картография не должна быть изучена", state)
	check(not main_map.is_cartography_researched(),
			"is_cartography_researched() должен быть false до изучения технологии", state)

	# --- Ищем неисследованные гексы: один в Регионе у границы Кольца Влияния,
	#     один в тумане войны у границы Региона ---
	# Гекс Региона обязан примыкать к известной территории (иначе его чанк не
	# годится для разведки — см. main_map.is_chunk_adjacent_to_known и
	# tools/test_scouting_frontier.gd). Для гекса тумана нужен «мост» — гекс
	# Региона, который сам касается тумана: при region_width = 2 гексы у Кольца
	# Влияния тумана не касаются. В разделе «ПОСЛЕ Картографии» этот мост
	# помечается разведанным, и разведка в соседний туман становится доступной.
	var region_hex = null
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			if not main_map.is_valid_hex(row, col):
				continue
			if not _hex_has_known_neighbor(main_map, row, col):
				continue
			region_hex = {"row": row, "col": col}
			break
		if region_hex != null:
			break
	var bridge_hex = _find_region_hex_near_fog(main_map)
	var fog_hex = null
	if bridge_hex != null:
		fog_hex = _find_fog_neighbor(main_map, bridge_hex.row, bridge_hex.col)
	check(region_hex != null, "не найден неисследованный гекс Региона у границы Кольца Влияния", state)
	check(bridge_hex != null, "не найден гекс Региона, граничащий с туманом войны", state)
	check(fog_hex != null, "не найден неисследованный гекс тумана войны у границы Региона", state)
	if region_hex == null or bridge_hex == null or fog_hex == null:
		_finish(main_map, state)
		return

	# ======================= ДО Картографии =======================
	check(main_map.is_hex_interactive(region_hex.row, region_hex.col),
			"гекс в Регионе должен быть доступен для наведения/клика", state)
	check(not main_map.is_hex_interactive(fog_hex.row, fog_hex.col),
			"без Картографии гекс в тумане войны НЕ должен быть доступен", state)

	var region_chunk = main_map.expansion_manager.get_chunk_hexes(region_hex.row, region_hex.col)
	check(region_chunk.size() > 0, "чанк разведки в Регионе не должен быть пустым", state)
	var region_chunk_inside = true
	for hex in region_chunk:
		if not main_map.is_valid_hex(hex.row, hex.col):
			region_chunk_inside = false
	check(region_chunk_inside, "без Картографии чанк разведки обязан лежать в Регионе", state)

	var fog_chunk = main_map.expansion_manager.get_chunk_hexes(fog_hex.row, fog_hex.col)
	check(fog_chunk.is_empty(),
			"без Картографии чанк для гекса в тумане войны должен быть пустым (получено %d)" % fog_chunk.size(),
			state)

	# Страховка публичной точки входа main_map.start_scouting():
	# разведка чанка в тумане без Картографии не должна запускаться вообще.
	main_map.start_scouting([fog_hex])
	check(not main_map.is_scouting,
			"start_scouting() не должен запускаться для чанка в тумане без Картографии", state)
	# А в Регионе разведка запускается. Оплата идёт монетами из казны, поэтому
	# заранее пополняем казну на цену чанка: этот тест проверяет гейт по
	# Картографии, а не достаток монет (экономику проверяет
	# tools/test_territory_costs.gd).
	city.add_treasury(main_map.expansion_manager.get_chunk_scout_cost(region_chunk))
	main_map.start_scouting(region_chunk)
	check(main_map.is_scouting,
			"start_scouting() должен запускаться для чанка в Регионе", state)
	main_map.is_scouting = false
	main_map.scouting_chunk = []

	# ==================== ПОСЛЕ Картографии ====================
	city.unlocked_technologies.append("cartography")
	check(main_map.is_cartography_researched(),
			"is_cartography_researched() должен стать true после изучения технологии", state)
	check(main_map.is_hex_interactive(fog_hex.row, fog_hex.col),
			"с Картографией гекс в тумане войны должен стать доступен", state)

	var fog_chunk_after = main_map.expansion_manager.get_chunk_hexes(fog_hex.row, fog_hex.col)
	check(fog_chunk_after.size() > 0,
			"с Картографией чанк разведки в тумане войны не должен быть пустым", state)
	var contains_start = false
	for hex in fog_chunk_after:
		if hex.row == fog_hex.row and hex.col == fog_hex.col:
			contains_start = true
	check(contains_start, "чанк разведки обязан включать стартовый гекс", state)

	# Разведка доступна только в чанк, примыкающий к известной территории
	# (Кольцо Влияния или разведанные гексы) — см.
	# main_map.is_chunk_adjacent_to_known. Сам чанк в тумане собирается в любом
	# случае (подсветка + неактивная кнопка с причиной), но запустить
	# разведку можно лишь у границы известного мира. Поэтому: находим гекс
	# Региона, граничащий с туманом, помечаем его разведанным («мост» в туман) и
	# проверяем запуск разведки на чанке соседнего гекса тумана.
	# «Мост» в туман: помечаем разведанным гекс Региона, касающийся тумана, —
	# граница известного мира доходит до fog_hex, и разведка туда разрешена
	# (см. main_map.is_chunk_adjacent_to_known). Без такого моста чанк тумана
	# оторван от известного мира, и start_scouting() обязан отказать
	# (проверяется в tools/test_scouting_frontier.gd).
	main_map.tile_data[bridge_hex.row][bridge_hex.col]["is_explored"] = true
	check(main_map.is_chunk_adjacent_to_known(fog_chunk_after),
			"после разведки моста чанк тумана обязан примыкать к известной территории", state)

	# Оплата — монетами из казны: пополняем её на цену чанка в тумане.
	city.add_treasury(main_map.expansion_manager.get_chunk_scout_cost(fog_chunk_after))
	main_map.start_scouting(fog_chunk_after)
	check(main_map.is_scouting,
			"с Картографией start_scouting() должен запускаться и для чанка в тумане", state)
	main_map.is_scouting = false
	main_map.scouting_chunk = []

	_finish(main_map, state)

func _hex_has_known_neighbor(main_map, row: int, col: int) -> bool:
	# Известная игроку территория: Кольцо Влияния (in_influence) или
	# разведанный гекс (is_explored) — см. main_map.is_hex_known.
	for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
		if main_map.is_hex_known(n.row, n.col):
			return true
	return false

# Первый неисследованный гекс Региона, у которого есть сосед ЗА пределами
# Региона (туман войны): через него граница известного мира дотягивается до
# тумана. Важно: при region_width = 2 гексы, соседние с Кольцом Влияния, сами
# тумана не касаются — «мост» в туман ищется отдельно.
func _find_region_hex_near_fog(main_map):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			if not main_map.is_valid_hex(row, col):
				continue
			var tile = main_map.tile_data[row][col]
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			if _find_fog_neighbor(main_map, row, col) != null:
				return {"row": row, "col": col}
	return null

# Первый сосед гекса (row, col), лежащий в тумане войны (вне Региона).
func _find_fog_neighbor(main_map, row: int, col: int):
	for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
		if main_map.is_valid_hex(n.row, n.col):
			continue
		return {"row": n.row, "col": n.col}
	return null

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("CARTOGRAPHY GATE TEST FAILED")
		quit(1)
	else:
		print("CARTOGRAPHY GATE TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
