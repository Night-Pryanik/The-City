# Headless-тест времени рецептов (поле `time` в data/crafts/*.json):
#   godot --headless --path "E:\The City" --script res://tools/test_craft_time.gd
#
# Проверяет:
#   1) get_craft_time() читает поле time и откатывается на SIMULATION_TICK;
#   2) do_tick() копит время слота и крафтит раз в time секунд (time = 5 при
#      шаге тика 1 сек → крафты на 5-м, 10-м, 15-м... тиках, средний период 5 сек);
#   3) при нехватке сырья таймер «горячий»: время не копится, крафт идёт на
#      ближайшем тике после подвоза сырья (без залпа крафтов);
#   4) slot_progress живёт в записи здания (уходит в сейв) и создаётся лениво
#      для старых сейвов и зданий с большим числом слотов;
#   5) плановые спрос и выпуск зданий несут interval = time рецепта и доходят
#      до карты worker_manager.get_planned_consumption_map() (её читает тултип).
extends SceneTree

# Автозагрузки попадают «внутрь дерева» только после инициализации, поэтому
# тест запускается из первого кадра (_process), а не из _initialize:
# иначе get_tree() внутри do_tick() вернёт null.
var _done := false

func _process(_delta) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true

func _run() -> void:
	var state = {"failed": false}

	# Первый кадр: дерево сцены уже поднято (автозагрузки внутри дерева),
	# поэтому do_tick()/плановые карты видят MainMap через get_tree().root.
	# До первого кадра get_tree() вернул бы null.

	# Автозагрузки GameData/CityData/SaveManager уже в дереве, но реестры
	# GameData грузит меню/карта — в headless-режиме загружаем их сами.
	# Имя автозагрузки в этом скрипте использовать нельзя: он компилируется
	# ДО их регистрации, поэтому берём синглтоны через дерево сцены.
	var gd = get_root().get_node("GameData")
	gd.load_all_data()
	var city = get_root().get_node("CityData")

	# do_tick() ищет на карте MainMap/TownsfolkManager — делаем заглушки.
	var main_map := Node.new()
	main_map.name = "MainMap"
	get_root().add_child(main_map)
	var tm = load("res://scripts/townsfolk_manager.gd").new()
	tm.name = "TownsfolkManager"
	main_map.add_child(tm)

	# --- 1. Данные: time у рецептов и откат get_craft_time ---
	var no_time: Array = []
	for c in gd.crafts:
		if str(c.get("id", "")) == "empty":
			continue # «Пусто» — псевдо-рецепт: time = 0, слот его не исполняет
		if float(c.get("time", 0.0)) <= 0.0:
			no_time.append(str(c.get("id", "?")))
	check(no_time.is_empty(), "у всех рецептов есть time > 0 (нет у: %s)" % str(no_time), state)
	check(is_equal_approx(city.get_craft_time({"id": "t"}), city.SIMULATION_TICK),
		"без поля time период = шаг тика", state)
	check(is_equal_approx(city.get_craft_time({"id": "t", "time": 0}), city.SIMULATION_TICK),
		"time = 0 трактуется как «за тик»", state)
	check(is_equal_approx(city.get_craft_time({"id": "t", "time": 7.5}), 7.5),
		"time = 7.5 возвращается как есть", state)

	var craft_time := 5.0 # time рецепта bricks (гончарная мастерская, глина 30 -> кирпичи 10)
	var recipe = city.get_craft_by_id("bricks")
	check(not recipe.is_empty(), "рецепт bricks найден в data/crafts", state)
	if not recipe.is_empty():
		check(is_equal_approx(city.get_craft_time(recipe), craft_time),
			"time рецепта bricks = %s" % str(craft_time), state)

	# --- 2. Крафт раз в time секунд ---
	city.add_to_storage("clay", 60, "common")
	city.total_population = 1
	city.idle_population = 0
	city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks"], "quality_priority": "best"}]
	tm.assigned_buildings = {"0": true} # зданию назначен горожанин

	city.do_tick() # 1 / 5 сек
	check(city.get_storage_amount("bricks") == 0, "тик 1 (1/5 сек): крафта быть не должно", state)
	check(is_equal_approx(city.get_slot_progress_value(0, 0), 1.0),
		"тик 1: накоплено 1 сек (факт %.1f)" % city.get_slot_progress_value(0, 0), state)

	for _i in range(3): # 2, 3 и 4 / 5 сек
		city.do_tick()
	check(city.get_storage_amount("bricks") == 0, "тики 2-4 (4/5 сек): крафта быть не должно", state)

	city.do_tick() # 5 >= 5 — крафт, время рецепта израсходовано целиком
	check(city.get_storage_amount("bricks") == 10, "тик 5: ожидался крафт (10 кирпичей)", state)
	check(city.get_storage_amount("clay") == 30, "тик 5: списано 30 глины", state)
	check(is_equal_approx(city.get_slot_progress_value(0, 0), 0.0),
		"после крафта остаток 0 сек (time кратен шагу тика)", state)

	for _i in range(4): # 1, 2, 3 и 4 / 5 сек
		city.do_tick()
	city.do_tick() # 5 >= 5 — второй крафт ровно через 5 сек от первого
	check(city.get_storage_amount("bricks") == 20, "за 10 тиков (10 сек) при time = 5 ожидалось 2 крафта", state)
	check(city.get_storage_amount("clay") == 0, "израсходованы все 60 глины", state)
	check(is_equal_approx(city.get_slot_progress_value(0, 0), 0.0),
		"после второго крафта остаток 0 сек", state)

	# --- 3. Прогресс хранится в записи здания (уходит в сейв) ---
	var bld: Dictionary = city.city_built_buildings[0]
	check(bld.has("slot_progress"), "slot_progress записан в запись здания", state)
	check(bld.get("slot_progress", []).size() == 1, "slot_progress по числу слотов", state)

	# Старый сейв (без ключа) и здание, у которого слотов больше, чем записей:
	# массив прогресса создаётся лениво и нужной длины.
	city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks", "bricks"]}]
	city.get_slot_progress(0)
	check(city.city_built_buildings[0].get("slot_progress", []).size() == 2,
		"для старого сейва slot_progress создаётся по числу слотов", state)
	check(is_equal_approx(city.get_slot_progress_value(0, 1), 0.0),
		"новый слот старого сейва начинает с 0 сек", state)

# --- 4. «Горячий» таймер при нехватке сырья ---
	# Склад пуст: слот доходит до времени крафта и ждёт сырьё, не копя время.
	city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks"], "quality_priority": "best"}]
	for _i in range(5): # 1..5 сек — на пятом таймер упёрся в нехватку
		city.do_tick()
	check(is_equal_approx(city.get_slot_progress_value(0, 0), craft_time),
		"без сырья прогресс держится на времени крафта (факт %.1f)" % city.get_slot_progress_value(0, 0), state)
	city.do_tick()
	city.do_tick()
	check(is_equal_approx(city.get_slot_progress_value(0, 0), craft_time),
		"без сырья время не копится — залпа крафтов не будет", state)

	var bricks_before: int = city.get_storage_amount("bricks")
	city.add_to_storage("clay", 30, "common")
	city.do_tick()
	check(city.get_storage_amount("bricks") == bricks_before + 10,
		"при появлении сырья крафт идёт на ближайшем тике (до %d, стало %d)" % [bricks_before, city.get_storage_amount("bricks")], state)
	check(is_equal_approx(city.get_slot_progress_value(0, 0), city.SIMULATION_TICK),
		"после «горячего» крафта остаток = шаг тика (факт %.1f)" % city.get_slot_progress_value(0, 0), state)

	# --- 5. Плановые спрос/выпуск несут time рецепта ---
	var demand: Dictionary = city.get_building_planned_consumption()
	check(not demand.get("clay", {}).is_empty(), "плановый спрос на глину есть", state)
	for src in demand.get("clay", {}):
		var e: Dictionary = demand["clay"][src]
		check(int(e.get("amount", 0)) == 30, "спрос за один крафт = 30 глины", state)
		check(is_equal_approx(float(e.get("interval", 0.0)), craft_time),
			"interval спроса = time рецепта (%s сек)" % str(craft_time), state)

	var supply: Dictionary = city.get_building_planned_production()
	check(not supply.get("bricks", {}).is_empty(), "плановый выпуск кирпичей есть", state)
	for src in supply.get("bricks", {}):
		var e2: Dictionary = supply["bricks"][src]
		check(int(e2.get("amount", 0)) == 10, "выпуск за один крафт = 10 кирпичей", state)
		check(is_equal_approx(float(e2.get("interval", 0.0)), craft_time),
			"interval выпуска = time рецепта (%s сек)" % str(craft_time), state)

	# Карта планового потребления (её читает тултип вкладки «Ресурсы») должна
	# получить тот же interval от спроса зданий.
	var wm = load("res://scripts/worker_manager.gd").new()
	var wm_clay: Dictionary = wm.get_planned_consumption_map().get("clay", {})
	var found_building := false
	for src in wm_clay:
		var e3: Dictionary = wm_clay[src]
		if int(e3.get("amount", 0)) == 30:
			found_building = true
			check(is_equal_approx(float(e3.get("interval", 0.0)), craft_time),
				"карта планового потребления несёт interval = time рецепта", state)
	check(found_building, "спрос здания попал в карту планового потребления", state)
	wm.free()

	# --- 6. Хелперы прогресса слота ---
	city.city_built_buildings[0]["slots"] = ["bricks"]
	city.get_slot_progress(0)[0] = 2.5
	check(abs(city.get_slot_progress_ratio(0, 0) - 0.5) < 0.001,
		"ratio = накопленное / time (2.5/5 = 0.5)", state)
	city.reset_slot_progress(0, 0)
	check(is_equal_approx(city.get_slot_progress_value(0, 0), 0.0),
		"reset_slot_progress обнуляет накопленное время слота", state)
	city.city_built_buildings[0]["slots"] = ["empty"]
	check(is_equal_approx(city.get_slot_craft_time(0, 0), 0.0),
		"пустой слот не имеет времени крафта", state)
	check(is_equal_approx(city.get_slot_progress_ratio(0, 0), 0.0),
		"ratio пустого слота = 0", state)

	main_map.queue_free()

	if state["failed"]:
		print("CRAFT TIME TEST FAILED")
		quit(1)
	else:
		print("CRAFT TIME TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
