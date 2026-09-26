# Headless-тест времени рецептов (поле `time` в data/crafts/*.json):
#   godot --headless --path "E:\The City" --script res://tests/test_craft_time.gd
#
# Проверяет:
#   1) get_craft_time() читает поле time и откатывается на SIMULATION_TICK;
#   2) непрерывный крафт: CraftContainer набирает ингредиенты со скоростью
#      resources/time и выпускает result со скоростью result/time, поэтому при
#      time = 5 и шаге тика 1 сек кирпичи идут по 2 ед./сек, а глина списывается
#      по 6 ед./сек (глины 30 -> кирпичи 10), а не «пачками раз в 5 секунд»;
#   3) состояние контейнера живёт в записи здания (ключ "slot_containers",
#      уходит в сейв), мигрирует со старого "slot_progress" и создаётся лениво
#      для старых сейвов и зданий с большим числом слотов;
#   4) при нехватке сырья контейнер «замерзает»: он НЕ копит долг по времени,
#      поэтому после подвоза сырья за тик уходит ровно одна порция результата
#      (а не залп за все накопившиеся секунды), и цикл сбрасывается;
#   5) плановые спрос и выпуск зданий несут interval = time рецепта и доходят
#      до карты worker_manager.get_planned_consumption_map() (её читает тултип).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Автозагрузки попадают «внутрь дерева» только после инициализации, поэтому
# тест запускается из первого кадра (_process), а не из _initialize:
# иначе get_tree() внутри do_tick() вернёт null.
var _done := false

# Сторож поднимается в _initialize, а сам тест стартует из первого _process —
# таймеру всё равно, откуда начали. Смысл разделения тот же, что у остальных
# тестов: любой обрыв внутри _run() должен приводить к коду 2, а не висеть.
func _initialize() -> void:
	WATCHDOG.arm(self)

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

	# --- 2. Непрерывный крафт: постоянные скорости, а не пачки ---
	# Рецепт bricks: глина 30 -> кирпичи 10, time = 5. Значит за тик (1 сек)
	# контейнер набирает 30/5 = 6 глины и выпускает 10/5 = 2 кирпича. Оба числа
	# целые, поэтому sub-unit аккумуляторы не дают дрейфа и «хвоста» на выходе.
	city.add_to_storage("clay", 60, "common")
	city.total_population = 1
	city.idle_population = 0
	city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks"], "quality_priority": "best"}]
	tm.assigned_buildings = {"0": true} # зданию назначен горожанин

	city.do_tick() # 1 сек
	check(city.get_storage_amount("clay") == 54, "тик 1: списано 6 глины (30/5 = 6 ед./сек)", state)
	check(city.get_storage_amount("bricks") == 2, "тик 1: выпущено 2 кирпича (10/5 = 2 ед./сек)", state)
	check(is_equal_approx(city.get_slot_progress_ratio(0, 0), 0.2),
		"тик 1: ratio = min(6/30, 1/5) = 0.2 (факт %.2f)" % city.get_slot_progress_ratio(0, 0), state)

	for _i in range(3): # 2, 3 и 4 сек — скорости те же
		city.do_tick()
	check(city.get_storage_amount("clay") == 36, "тики 2-4: списано ещё 18 глины (24 из 60)", state)
	check(city.get_storage_amount("bricks") == 8, "тики 2-4: выпущено ещё 6 кирпичей (8 всего)", state)
	check(is_equal_approx(city.get_slot_progress_ratio(0, 0), 0.8),
		"тики 2-4: ratio = min(24/30, 4/5) = 0.8 (факт %.2f)" % city.get_slot_progress_ratio(0, 0), state)

	city.do_tick() # 5 сек — цикл завершён, контейнер сброшен
	check(city.get_storage_amount("bricks") == 10, "тик 5: за полный цикл выпущено ровно 10 кирпичей", state)
	check(city.get_storage_amount("clay") == 30, "тик 5: израсходовано ровно 30 глины", state)
	check(is_zero_approx(city.get_slot_progress_ratio(0, 0)),
		"после завершения цикла контейнер сброшен (ratio = 0)", state)

	for _i in range(4): # 6, 7, 8 и 9 сек — второй цикл
		city.do_tick()
	city.do_tick() # 10 сек — второй цикл завершён
	check(city.get_storage_amount("bricks") == 20, "за 10 тиков (10 сек) выпущено 20 кирпичей (2 цикла)", state)
	check(city.get_storage_amount("clay") == 0, "израсходованы все 60 глины", state)
	check(is_zero_approx(city.get_slot_progress_ratio(0, 0)),
		"после второго цикла контейнер сброшен (ratio = 0)", state)

	# --- 3. Контейнер слота живёт в записи здания (уходит в сейв) ---
	# Состояние непрерывного крафта хранится не в плоском массиве секунд
	# (ключ "slot_progress" от пакетной модели), а в CraftContainer на каждый
	# слот — ключ "slot_containers" в city_built_buildings[i].
	var bld: Dictionary = city.city_built_buildings[0]
	check(bld.has("slot_containers"), "контейнеры слотов записаны в запись здания", state)
	check(bld.get("slot_containers", []).size() == 1, "контейнер по числу слотов", state)

	# Старый сейв (ключ "slot_progress" от пакетной модели) мигрирует:
	# контейнеры создаются по числу слотов, старый ключ вычищается, чтобы
	# не тащить его дальше. Накопленные секунды не переносятся — в новой модели
	# это была бы не заполненность контейнера, а бессмысленные числа.
	city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks"], "slot_progress": [2.5]}]
	city.get_slot_containers(0)
	var migrated: Dictionary = city.city_built_buildings[0]
	check(migrated.has("slot_containers"), "старый сейв мигрирует в slot_containers", state)
	check(not migrated.has("slot_progress"), "старый ключ slot_progress вычищен при миграции", state)
	check(migrated.get("slot_containers", []).size() == 1,
		"для старого сейва контейнер создаётся по числу слотов", state)

	# Здание, у которого слотов больше, чем контейнеров: массив подгоняется лениво.
	city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks", "bricks"]}]
	city.get_slot_containers(0)
	check(city.city_built_buildings[0].get("slot_containers", []).size() == 2,
		"контейнеры дозаводятся под текущее число слотов", state)
	check(is_zero_approx(city.get_slot_progress_value(0, 1)), "новый слот старого сейва начинает с 0 сек", state)

# --- 4. Контейнер замерзает при нехватке сырья ---
	# В непрерывной модели контейнер НЕ копит долг по времени: без сырья
	# ингредиент не набирается, поэтому прогресс упирается в заполненность,
	# а не во время (completion_ratio = min(заполненность, время/craft_time)).
	# Поэтому после подвоза сырья контейнер не «догоняет» накопившиеся секунды
	# залпом: за тик уходит ровно одна порция результата (10/5 = 2 кирпича),
	# после чего цикл сбрасывается.
	city.city_built_buildings = [{"id": "pottery_workshop", "slots": ["bricks"], "quality_priority": "best"}]
	for _i in range(8): # 8 сек без сырья — заметно больше времени цикла (5 с)
		city.do_tick()
	# Тип контейнера здесь намеренно не указывается: упоминание CraftContainer
	# заставило бы компилировать craft_container.gd, а он обращается к
	# автозагрузке GameData, которая в режиме --script ещё не зарегистрирована
	# (та же причина, по которой синглтоны берутся из дерева сцены).
	var starved = city.get_slot_container(0, 0)
	check(city.get_storage_amount("clay") == 0, "без сырья расхода нет", state)
	check(is_zero_approx(starved.completion_ratio()),
		"без сырья прогресс = 0 (упирается в заполненность, а не во время)", state)
	check(int(starved.ingredient_slots[0].get("filled", 0)) == 0,
		"ингредиент не набирается без сырья", state)
	check(starved.elapsed >= craft_time,
		"время в контейнере идёт (%.1f с >= %.1f), но заморозку не отменяет" % [starved.elapsed, craft_time], state)

	var bricks_before: int = city.get_storage_amount("bricks")
	city.add_to_storage("clay", 30, "common")
	city.do_tick()
	check(city.get_storage_amount("clay") == 24, "после подвоза сырья списано 6 глины за тик (30/5)", state)
	check(city.get_storage_amount("bricks") == bricks_before + 2,
		"выпуск за тик = 2 кирпича, залпа из 10 не было (было %d, стало %d)"
			% [bricks_before, city.get_storage_amount("bricks")], state)
	check(is_zero_approx(city.get_slot_progress_ratio(0, 0)),
		"после завершения цикла контейнер сброшен (ratio = 0)", state)

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
	# Состояние задаём прямо в контейнере. Раньше здесь стояло
	# city.get_slot_progress(0)[0] = 2.5, но get_slot_progress() — это
	# ВЫЧИСЛЯЕМЫЙ геттер (ratio * craft_time): запись в его результат попадала
	# в свежий временный Array и молча пропадала. Поэтому наполовину
	# заполненный контейнер (15 из 30 глины, 2.5 из 5 сек) готовим явно.
	var cont = city.get_slot_container(0, 0)
	cont.elapsed = 2.5
	cont.ingredient_slots[0]["filled"] = 15
	check(abs(city.get_slot_progress_ratio(0, 0) - 0.5) < 0.001,
		"ratio = min(заполненность, время/craft_time) = min(15/30, 2.5/5) = 0.5", state)
	check(abs(city.get_slot_progress_value(0, 0) - 2.5) < 0.001,
		"legacy get_slot_progress_value = ratio * craft_time = 2.5", state)
	city.reset_slot_progress(0, 0)
	check(is_zero_approx(city.get_slot_progress_value(0, 0)),
		"reset_slot_progress обнуляет накопленное контейнером", state)
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
