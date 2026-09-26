# Headless-тест: заливка колец городков не протекает в туман войны.
#   godot --headless --path . --script res://tests/test_town_fill_fog.gd
#
# Проверяется на живых данных реальной сцены MainMap (новая игра):
#   1. В 1-й эпохе колец не видно вообще — иначе чужой городок выдал бы себя
#      в неисследованной зоне Региона с самого начала игры.
#   2. Ни один гекс заливки (кэш рендера) не лежит в тумане войны.
#   3. Ни одна граница кольца не имеет конца в тумане войны (сосед с гексом
#      заливки вне тумана).
#   4. После разведки туманного гекса заливка на нём появляется, кэш при
#      этом пересобирается (без инвалидации разведка не дала бы эффекта).
#   5. То же самое верно после смены эры: кэш пересобирается, новых гексов
#      заливки в тумане не появляется.
#
# Пункты 2-5 проверяются начиная с эры Античности (current_era >= 1): именно с
# неё городки вообще видны игроку, значит и их кольца (см.
# map_renderer._ensure_town_influence_cache). В 1-й эпохе кольца не рисуются
# НИКОГДА — независимо от тумана, поэтому для проверок тумана нужна смена эры.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state = {"failed": false}
	get_root().get_node("SaveManager").new_game()
	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame
	await process_frame

	var r = main_map.map_renderer

	# --- 1: в 1-й эпохе колец не видно ---
	r.invalidate_town_influence_cache()
	_rebuild(r)
	check(r.get_town_fill_hexes().is_empty(),
		"в 1-й эпохе кольца городков не должны рисоваться (получено гексов: %d)"
			% r.get_town_fill_hexes().size(), state)

	# С эры Античности городки видимы — дальше проверяем собственно туман.
	main_map.advance_to_next_era()
	await process_frame

	# --- 2 и 3: заливка и границы не заходят в туман ---
	_rebuild(r)
	check(_fill_in_fog(main_map, r).is_empty(),
		"заливка городков не должна рисоваться на гексах тумана войны (нарушителей: %s)"
			% str(_fill_in_fog(main_map, r)), state)
	check(_borders_in_fog(main_map, r).is_empty(),
		"границы колец городков не должны уходить в туман войны (нарушителей: %s)"
			% str(_borders_in_fog(main_map, r)), state)

	# --- 4: разведка открывает заливку и пересобирает кэш ---
	var fog_hexes: Array = []
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if tile != null and main_map.is_hex_in_fog(row, col) \
					and bool(tile.get("in_town_influence", false)):
				fog_hexes.append({"row": row, "col": col})
	check(not fog_hexes.is_empty(),
		"на живой карте должен найтись хотя бы один гекс кольца городка в тумане", state)
	if not fog_hexes.is_empty():
		var h: Dictionary = fog_hexes[0]
		# Разведка штатным путём: чанк из одного гекса. Кэш заливки должен
		# пересобраться САМ (см. invalidate_town_influence_cache в
		# _complete_scouting) — вручную его не трогаем.
		main_map.scouting_chunk = [h]
		main_map.is_scouting = true
		main_map._complete_scouting()
		_rebuild(r)
		check(not main_map.is_hex_in_fog(h.row, h.col),
			"разведанный гекс не может быть в тумане войны", state)
		var now_drawn: bool = _is_filled(r, h.row, h.col)
		check(now_drawn,
			"после разведки заливка городка должна появиться на гексе (%d,%d)"
				% [int(h.row), int(h.col)], state)

	# --- 5: смена эры ---
	main_map.advance_to_next_era()
	await process_frame
	_rebuild(r)
	check(_fill_in_fog(main_map, r).is_empty(),
		"после смены эры заливка не должна уходить в туман войны (нарушителей: %s)"
			% str(_fill_in_fog(main_map, r)), state)
	check(_borders_in_fog(main_map, r).is_empty(),
		"после смены эры границы колец не должны уходить в туман (нарушителей: %s)"
			% str(_borders_in_fog(main_map, r)), state)

	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("TOWN FILL FOG TEST FAILED")
		quit(1)
	else:
		print("TOWN FILL FOG TEST OK")
		quit(0)

# Принудительно пересобирает кэш рендера (как это делает кадр отрисовки).
func _rebuild(r) -> void:
	r._ensure_town_influence_cache(r._get_visible_hex_range())

func _is_filled(r, row: int, col: int) -> bool:
	for h in r.get_town_fill_hexes():
		if int(h.row) == row and int(h.col) == col:
			return true
	return false

# Гексы заливки, попавшие в туман войны.
func _fill_in_fog(main_map, r) -> Array:
	var bad: Array = []
	for h in r.get_town_fill_hexes():
		if main_map.is_hex_in_fog(int(h.row), int(h.col)):
			bad.append([int(h.row), int(h.col)])
	return bad

# Отрезки границ, у которых хотя бы один конец-гекс в тумане войны.
func _borders_in_fog(main_map, r) -> Array:
	var bad: Array = []
	for h in r.get_town_border_hexes():
		if main_map.is_hex_in_fog(int(h.row), int(h.col)):
			bad.append([int(h.row), int(h.col)])
	return bad

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
