# Headless-тест стоимости территории: разведка и освоение оплачиваются МОНЕТАМИ
# из казны города, цена гекса растёт с расстоянием от города (универсальный
# модификатор из data/game_balance.json), еда при этом НЕ тратится.
#   godot --headless --path . --script res://tests/test_territory_costs.gd
#
# Проверки:
#   1. Универсальное поле distance_cost_modifier_per_hex реально читается:
#      при подмене значения меняются и труд улучшений, и монеты разведки/освоения
#      (то есть хардкода 0.25 в формулах не осталось).
#   2. Цена гекса = ceil(база × (1 + расстояние × модификатор)), цена чанка =
#      сумма цен гексов; дальше от города — дороже.
#   3. start_scouting() списывает ровно цену чанка монетами и НЕ трогает еду.
#   4. При пустой казне разведка не стартует, казна не уходит в минус.
#   5. handle_action(): при нехватке монет — отказ без изменений казны и без
#      запуска стройки; при достатке — списание ровно цены чанка и запуск
#      стройки освоения.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state = {"failed": false}

	# Автозагрузки берём через дерево сцены: в режиме --script имена
	# GameData/CityData недоступны на этапе компиляции этого файла.
	# new_game() заодно грузит все данные и сбрасывает состояние города.
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var city = get_root().get_node("CityData")
	var gdata = get_root().get_node("GameData")
	# Глобальные классы тоже берём через load(): в --script-режиме имена
	# HexUtils/MapHelpers не гарантированы на этапе компиляции теста.
	var hex_utils = load("res://scripts/HexUtils.gd")
	var map_helpers = load("res://scripts/map_helpers.gd")

	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame

	check(main_map.tile_data.size() == main_map.map_rows,
			"карта не инициализирована (tile_data пуст)", state)
	var em = main_map.expansion_manager

	# --- Значения из data/game_balance.json ---
	var balance: Dictionary = gdata.game_balance
	var base_scout: int = int(balance.get("scouting_cost_per_hex", -1))
	var base_expansion: int = int(balance.get("expansion_cost_per_hex", -1))
	var distance_modifier: float = float(balance.get("distance_cost_modifier_per_hex", -1.0))
	check(base_scout > 0, "scouting_cost_per_hex должен быть > 0 в game_balance.json", state)
	check(base_expansion > 0, "expansion_cost_per_hex должен быть > 0 в game_balance.json", state)
	check(distance_modifier > 0.0,
			"distance_cost_modifier_per_hex должен быть > 0 в game_balance.json", state)

	var city_row: int = main_map.city_row
	var city_col: int = main_map.city_col

	# --- 2. Формула цены гекса ---
	# Гекс города: расстояние 0 → множитель 1 → цена равна базе.
	check(em.get_hex_scout_cost(city_row, city_col) == base_scout,
			"цена разведки гекса города должна равняться базе (%d)" % base_scout, state)
	check(em.get_hex_money_cost(city_row, city_col) == base_expansion,
			"цена освоения гекса города должна равняться базе (%d)" % base_expansion, state)

	# Гекс на 4 колонки в сторону: для odd-r при равных рядах расстояние = 4.
	var probe_row: int = city_row
	var probe_col: int = min(city_col + 4, main_map.map_cols - 1)
	var probe_dist: int = hex_utils.hex_distance(probe_row, probe_col, city_row, city_col)
	check(probe_dist > 0, "пробный гекс должен быть на расстоянии > 0 от города", state)

	var expected_scout: int = int(ceil(float(base_scout) * (1.0 + float(probe_dist) * distance_modifier)))
	var expected_money: int = int(ceil(float(base_expansion) * (1.0 + float(probe_dist) * distance_modifier)))
	check(em.get_hex_scout_cost(probe_row, probe_col) == expected_scout,
			"цена разведки гекса на расстоянии %d должна быть %d (получено %d)"
					% [probe_dist, expected_scout, em.get_hex_scout_cost(probe_row, probe_col)], state)
	check(em.get_hex_money_cost(probe_row, probe_col) == expected_money,
			"цена освоения гекса на расстоянии %d должна быть %d (получено %d)"
					% [probe_dist, expected_money, em.get_hex_money_cost(probe_row, probe_col)], state)
	check(em.get_hex_scout_cost(probe_row, probe_col) > em.get_hex_scout_cost(city_row, city_col),
			"дальний гекс должен стоить дороже ближнего (модификатор дальности)", state)

	# --- 1. Универсальность модификатора: подмена значения меняет все расчёты ---
	var original_modifier: float = distance_modifier
	balance["distance_cost_modifier_per_hex"] = 1.0
	var imp_id: String = ""
	for id in gdata.improvements.keys():
		if float(gdata.improvements[id].get("work_cost", 0)) > 0.0:
			imp_id = id
			break
	check(imp_id != "", "не найдено улучшение с work_cost > 0 для проверки труда", state)
	if imp_id != "":
		var cost_data: Dictionary = map_helpers.get_improvement_work_cost(
				imp_id, probe_row, probe_col, main_map.tile_data, city_row, city_col)
		var expected_dist_mult: float = 1.0 + float(probe_dist) * 1.0
		var actual_dist_mult: float = float(cost_data.get("distance_mult_base", 0.0))
		check(abs(actual_dist_mult - expected_dist_mult) < 0.0001,
				"труд улучшения должен брать модификатор дальности из game_balance.json (ожидалось ×%.2f, получено ×%.2f)"
						% [expected_dist_mult, actual_dist_mult], state)
	check(em.get_hex_scout_cost(probe_row, probe_col)
					== int(ceil(float(base_scout) * (1.0 + float(probe_dist) * 1.0))),
			"цена разведки должна следовать за значением из game_balance.json", state)
	check(em.get_hex_money_cost(probe_row, probe_col)
					== int(ceil(float(base_expansion) * (1.0 + float(probe_dist) * 1.0))),
			"цена освоения должна следовать за значением из game_balance.json", state)
	balance["distance_cost_modifier_per_hex"] = original_modifier

	# --- 3. Разведка: монеты списываются, еда не тратится ---
	var region_hex = _find_unexplored_region_hex(main_map)
	check(region_hex != null, "не найден неисследованный гекс в Регионе", state)
	if region_hex == null:
		_finish(main_map, state)
		return
	var scout_chunk: Array = em.get_chunk_hexes(region_hex.row, region_hex.col)
	check(scout_chunk.size() > 0, "чанк разведки в Регионе не должен быть пустым", state)
	var per_hex_sum := 0
	for hex in scout_chunk:
		per_hex_sum += em.get_hex_scout_cost(hex.row, hex.col)
	var scout_cost: int = em.get_chunk_scout_cost(scout_chunk)
	check(scout_cost == per_hex_sum,
			"цена чанка разведки должна быть суммой цен гексов (%d против %d)" % [scout_cost, per_hex_sum], state)
	check(scout_cost > 0, "цена чанка разведки должна быть > 0", state)

	var food_before: int = _food_total(city)
	var treasury_before: int = city.treasury
	if treasury_before < scout_cost:
		city.add_treasury(scout_cost - treasury_before)
		treasury_before = city.treasury
	main_map.start_scouting(scout_chunk)
	check(main_map.is_scouting, "разведка должна запускаться при достатке монет в казне", state)
	check(city.treasury == treasury_before - scout_cost,
			"казна должна уменьшиться ровно на цену чанка (%d): было %d, стало %d"
					% [scout_cost, treasury_before, city.treasury], state)
	check(_food_total(city) == food_before, "разведка НЕ должна списывать еду", state)
	main_map.is_scouting = false
	main_map.scouting_chunk = []

	# --- 6. Тултипы не должны зависеть от значений, меняющихся каждый тик ---
	# Иначе _build_actions() пересоздаёт кнопки каждый тик (сравнение тултипов
	# в _actions_equal) и наведённый тултип сбрасывается.
	var cp = main_map.control_panel
	var probe_tile: Dictionary = main_map.tile_data[region_hex.row][region_hex.col]
	var actions_before: Array = cp._collect_actions(region_hex.row, region_hex.col, probe_tile)
	check(actions_before.size() > 0, "для неисследованного гекса должны быть действия", state)
	city.add_treasury(1) # казна изменилась — тултипы измениться НЕ должны
	var actions_after: Array = cp._collect_actions(region_hex.row, region_hex.col, probe_tile)
	check(cp._actions_equal(actions_before, actions_after),
			"тултипы разведки/освоения не должны меняться от казны (панель пересоздаёт кнопки и сбрасывает тултип)", state)

	# --- 4. Пустая казна: разведка не стартует, минуса нет ---
	var treasury_saved: int = city.treasury
	city.treasury = 0
	main_map.start_scouting(scout_chunk)
	check(not main_map.is_scouting, "при пустой казне разведка не должна запускаться", state)
	check(city.treasury == 0, "казна не должна уходить в минус", state)
	city.treasury = treasury_saved

	# --- 5. Освоение: монеты из казны + запуск стройки ---
	var expansion_chunk: Array = _find_region_hexes(main_map, em, 2)
	check(expansion_chunk.size() == 2, "не найдено 2 гекса Региона для проверки освоения", state)
	if expansion_chunk.size() == 2:
		var money_cost: int = em.get_chunk_money_cost(expansion_chunk)
		var work_cost: int = em.get_chunk_cost(expansion_chunk)
		check(money_cost > 0 and work_cost > 0,
				"цена освоения (%d монет) и труд (%d) должны быть > 0" % [money_cost, work_cost], state)
		var builds_before: int = main_map.build_manager.get_total_active_builds()
		# Нехватка монет: отказ без списания и без стройки.
		city.treasury = money_cost - 1
		var ok_poor: bool = em.handle_action(expansion_chunk, money_cost, work_cost)
		check(not ok_poor, "при нехватке монет handle_action() должен вернуть false", state)
		check(city.treasury == money_cost - 1, "при нехватке монет казна не должна меняться", state)
		check(main_map.build_manager.get_total_active_builds() == builds_before,
				"при нехватке монет стройка освоения не должна запускаться", state)
		# Достаток монет: списание ровно цены чанка и запуск стройки.
		city.treasury = money_cost + 7
		var ok_rich: bool = em.handle_action(expansion_chunk, money_cost, work_cost)
		check(ok_rich, "при достатке монет handle_action() должен вернуть true", state)
		check(city.treasury == 7, "казна должна уменьшиться ровно на цену чанка (%d)" % money_cost, state)
		check(main_map.build_manager.get_total_active_builds() == builds_before + 1,
				"стройка освоения должна быть запущена", state)

	_finish(main_map, state)

func _find_unexplored_region_hex(main_map):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
				continue
			if not main_map.is_valid_hex(row, col):
				continue
			# Разведка доступна только в чанк, примыкающий к известной
			# территории (Кольцо Влияния или разведанные гексы) — см.
			# main_map.is_chunk_adjacent_to_known. Берём гекс у границы Кольца,
			# иначе start_scouting() откажет и тест проверит не то.
			if not _hex_has_known_neighbor(main_map, row, col):
				continue
			return {"row": row, "col": col}
	return null

func _hex_has_known_neighbor(main_map, row: int, col: int) -> bool:
	for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
		if main_map.is_hex_known(n.row, n.col):
			return true
	return false

func _find_region_hexes(main_map, em, count: int) -> Array:
	# Гексы Региона, пригодные для освоения: не в кольце чужого городка и с
	# ненулевым трудом. У воды и «непроходимых» террейнов expansion_cost = 0 —
	# такие гексы не годятся: start_expansion_build() требует work_cost > 0,
	# а труд освоения от расстояния не зависит (решение по балансу).
	var result := []
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			if not main_map.is_valid_hex(row, col):
				continue
			var tile = main_map.tile_data[row][col]
			if bool(tile.get("in_town_influence", false)):
				continue
			if em.get_hex_cost(row, col) <= 0:
				continue
			result.append({"row": row, "col": col})
			if result.size() >= count:
				return result
	return result

func _food_total(city) -> int:
	var total := 0
	for pid in city.city_food_pool:
		if city.city_food_pool[pid]:
			total += city.city_storage.get(pid, 0)
	return total

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("TERRITORY COSTS TEST FAILED")
		quit(1)
	else:
		print("TERRITORY COSTS TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
