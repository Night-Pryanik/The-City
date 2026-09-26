# Headless-тест: заливка колец городков покрывает кольцо ЦЕЛИКОМ.
#   godot --headless --path "E:\The City" --script res://tests/test_town_fill_region.gd
#
# Регресс на дефект, из-за которого заливка выглядела «нарисованной наполовину»
# (особенно у левой границы Региона): кольца городков клипались по СТАРТОВОМУ
# Региону при генерации, и с ростом Региона (смена эпохи) заливка навсегда
# оставалась огрызком — рисовалась только та часть кольца, что попала в новый
# Регион (измеренные потери — до 18% гексов заливки).
#
# Проверяется на живых данных реальной сцены MainMap (новая игра):
#   1. Кольцо в данных равно кольцу по радиусу (клипа по Региону больше нет)
#      и флаг in_town_influence выставлен ровно на гексах колец.
#   2. В 1-й эпохе заливки нет вообще — кольца не выдают чужой городок.
#   3. После смены эпохи заливка равна «кольцо минус туман»: потерь нет.
#   4. Гекс заливки не лежит в тумане, а его полный bbox — внутри текстуры
#      заливки (текстура не может обрезать гекс пополам).
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

	var tm = main_map.town_manager
	var r = main_map.map_renderer

	# --- 1: кольца в данных полные (регресс на клип по Региону) ---
	# Допустимое отличие от «кольца по радиусу» — только межгородской клип
	# «кто первый встал, того и тапки»: гекс, уже занятый более ранним
	# городком, из кольца выбрасывается. Любое другое расхождение — дефект.
	var ring_keys: Dictionary = {}
	var claimed: Dictionary = {}
	for t in main_map.towns:
		var expected := _key_set(_full_ring(main_map, tm, t))
		for k in expected.keys():
			if claimed.has(k):
				expected.erase(k)
		var stored := _key_set(t.get("influence_hexes", []))
		check(expected == stored,
			"кольцо городка (%d,%d) должно совпадать с кольцом по радиусу минус занятые соседями гексы; нет в данных: %s, лишние: %s"
				% [int(t.row), int(t.col), str(_keys_only_in(expected, stored)),
					str(_keys_only_in(stored, expected))], state)
		for k in stored.keys():
			ring_keys[k] = true
			claimed[k] = true
	var stray: Array = []
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if tile != null and bool(tile.get("in_town_influence", false)) \
					and not ring_keys.has("%d,%d" % [row, col]):
				stray.append([row, col])
	check(stray.is_empty(),
		"флаг in_town_influence стоит только на гексах колец (лишних: %s)" % str(stray), state)

	# --- 2: в 1-й эпохе заливки нет ---
	r.invalidate_town_influence_cache()
	_rebuild(r)
	check(r.get_town_fill_hexes().is_empty(),
		"в 1-й эпохе кольца не должны рисоваться (иначе виден чужой городок), гексов: %d"
			% r.get_town_fill_hexes().size(), state)

	# --- 3: после смены эпохи заливка = кольцо минус туман, потерь нет ---
	var before := _key_set(r.get_town_fill_hexes())
	main_map.advance_to_next_era()
	await process_frame
	_rebuild(r)
	var after := _key_set(r.get_town_fill_hexes())
	var should_be: Dictionary = {}
	for t in main_map.towns:
		for h in _full_ring(main_map, tm, t):
			if not main_map.is_hex_in_fog(int(h.row), int(h.col)):
				should_be["%d,%d" % [int(h.row), int(h.col)]] = true
	check(not should_be.is_empty(),
		"после смены эпохи заливка должна появиться (проверяем на живой карте)", state)
	check(_keys_only_in(should_be, after).is_empty(),
		"после смены эпохи потеряна часть заливки (не нарисованы: %s)"
			% str(_keys_only_in(should_be, after)), state)
	check(_keys_only_in(after, should_be).is_empty(),
		"после смены эпохи нарисована лишняя заливка (лишние: %s)"
			% str(_keys_only_in(after, should_be)), state)
	check(after.size() >= before.size(),
		"заливка не должна терять гексы при смене эпохи (было %d, стало %d)"
			% [before.size(), after.size()], state)

	# --- 4: заливка целиком помещается в текстуру (её не режет край) ---
	# Заливка может выходить за пределы Региона — на разведанных гексах за ним
	# (так работает разведка), — поэтому проверяем не Регион, а покрытие
	# текстурой: именно её край давал «заливку наполовину».
	var fog_left: Array = []
	for h in r.get_town_fill_hexes():
		if main_map.is_hex_in_fog(int(h.row), int(h.col)):
			fog_left.append([int(h.row), int(h.col)])
	check(fog_left.is_empty(),
		"гексы заливки не должны лежать в тумане войны (нарушителей: %s)" % str(fog_left), state)
	check(r._influence_fill_texture != null,
		"текстура заливки должна быть построена (иначе рисуется fallback)", state)
	if r._influence_fill_texture != null:
		_check_texture_covers_hexes(main_map, r, state)

	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("TOWN FILL REGION TEST FAILED")
		quit(1)
	else:
		print("TOWN FILL REGION TEST OK")
		quit(0)

# Кольцо городка по его радиусу — эталон «как должно быть» (town_manager
# строит кольца ровно так; клипа по Региону в нём больше нет).
func _full_ring(main_map, tm, t) -> Array:
	return tm.compute_town_influence(
			main_map.tile_data, main_map.map_rows, main_map.map_cols,
			int(t.row), int(t.col), t,
			int(t.get("influence_radius", 3)))

# Текстура должна покрывать гекс заливки ЦЕЛИКОМ: гекс, обрезанный её край,
# — это и есть «заливка наполовину». Проверяем, что текстура содержит точный
# габарит гекса (радиус по вертикали, 0.866 радиуса по горизонтали) с допуском
# в 0.01 px на погрешность float. Запас в 1 px, который _build_town_fill_texture
# даёт сверх габарита, на сглаживание стыков, в допуск не входит: он не
# обязателен. Настоящий обрез — это десятки пикселей.
func _check_texture_covers_hexes(main_map, r, state: Dictionary) -> void:
	var radius: float = main_map.HEX_RADIUS
	var half_w: float = radius * sqrt(3.0) * 0.5
	var tol := 0.01
	var cut: Array = []
	for h in r.get_town_fill_hexes():
		var c: Vector2 = HexUtils.hex_center(int(h.row), int(h.col), radius)
		if c.x - half_w - tol < r._influence_texture_origin.x \
				or c.x + half_w + tol > r._influence_texture_origin.x + r._influence_texture_size.x \
				or c.y - radius - tol < r._influence_texture_origin.y \
				or c.y + radius + tol > r._influence_texture_origin.y + r._influence_texture_size.y:
			cut.append([int(h.row), int(h.col)])
	check(cut.is_empty(),
		"текстура заливки не должна обрезать гекс пополам (обрезанных: %s)" % str(cut), state)

# Принудительно пересобирает кэш рендера (как это делает кадр отрисовки).
func _rebuild(r) -> void:
	r._ensure_town_influence_cache(r._get_visible_hex_range())

func _key_set(hexes: Array) -> Dictionary:
	var out: Dictionary = {}
	for h in hexes:
		out["%d,%d" % [int(h.row), int(h.col)]] = true
	return out

# Ключи, которые есть только в a.
func _keys_only_in(a: Dictionary, b: Dictionary) -> Array:
	var out: Array = []
	for k in a.keys():
		if not b.has(k):
			out.append(k)
	return out

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
