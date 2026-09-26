# Временный smoke-тест системы потребления (headless):
#   godot --headless --path "E:\The City" --script res://tests/test_consumption.gd
# Проверяет: загрузку data/consumption.json, резолвинг группы "@boats",
# дедупликацию и жадное списание из группы. После проверки файл можно удалить.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
	WATCHDOG.arm(self)
	var state = {"failed": false}

	var gd = load("res://scripts/GameData.gd").new()
	gd.load_all_data()

	# 1) Реестр загружен и каждое правило из data/consumption.json разбирается.
	#    Конкретное число правил НЕ хардкодится: реестр пополняется данными
	#    (например, правило «перья учёного»), и само число не должно ронять
	#    тест. Проверяются инварианты: реестр непуст, у каждого правила есть
	#    ресурс, список профессий и положительные amount/interval, а ресурс
	#    резолвится — одиночный продукт либо @-группа из product_groups.json.
	check(not gd.consumption_rules.is_empty(), "реестр consumption не загрузился", state)
	for rule in gd.consumption_rules:
		var res_key := str(rule.get("resource", ""))
		check(not res_key.is_empty(), "правило consumption без поля resource: %s" % str(rule), state)
		check(not rule.get("profession", []).is_empty(), "правило %s без поля profession" % res_key, state)
		check(int(rule.get("amount", 0)) > 0, "у правила %s amount <= 0" % res_key, state)
		check(float(rule.get("interval", 0.0)) > 0.0, "у правила %s interval <= 0" % res_key, state)
		if res_key.begins_with("@"):
			check(not gd.product_groups.get(res_key.substr(1), []).is_empty(),
				"группа %s из consumption.json не найдена в product_groups.json" % res_key, state)
		else:
			check(gd.products.has(res_key), "продукт %s из consumption.json не найден в products" % res_key, state)

	# 2) Потребление рыбака — групповая запись "@boats"
	var cons = gd.get_profession_consumption("fisherman")
	check(cons.size() == 1, "ожидалась 1 запись для fisherman, получено: %d" % cons.size(), state)
	if cons.size() == 1:
		var e = cons[0]
		check(e.get("is_group", false) == true, "запись не групповая", state)
		check(e.get("display_key", "") == "@boats", "display_key != @boats", state)
		check(e.get("product_name", "") == "Лодки", "имя группы != Лодки", state)
		check(e.get("group_members", []) == ["reed_boat"], "члены группы неверны", state)
		check(e.get("icon", "") == "reed_boat.png", "иконка группы неверна", state)
		# amount/interval — балансные числа из data/consumption.json, поэтому
		# сверяем их с САМИМ правилом реестра, а не с константой в тесте. Так
		# тест по-прежнему ловит потерю/подмену полей при разборе записи, но
		# не ломается при правке баланса.
		var rule_boats := _rule_for(gd.consumption_rules, "@boats", "fisherman")
		check(not rule_boats.is_empty(), "в реестре нет правила @boats для fisherman", state)
		if not rule_boats.is_empty():
			check(int(e.get("amount", -1)) == int(rule_boats.get("amount", -2)),
				"amount @boats потерян при разборе правила: %s" % str(e.get("amount", null)), state)
			check(abs(float(e.get("interval", -1.0)) - float(rule_boats.get("interval", -2.0))) < 0.01,
				"interval @boats потерян при разборе правила: %s" % str(e.get("interval", null)), state)

	# 3) Дубликаты: после перевода лодки на реестр продукт не должен
	#    дублироваться (у reed_boat больше нет поля consumption)
	check(gd.products.get("reed_boat", {}).has("consumption") == false,
		"у reed_boat не должно быть поля consumption", state)

	# 4) Сводка потребления
	var summary = gd.get_profession_consumption_summary("fisherman")
	check(summary.has("@boats"), "в сводке нет @boats", state)

	# 5) Жадное списание из группы (логика как в tick_consumption)
	var cd = load("res://scripts/CityData.gd").new()
	cd.city_storage = {"reed_boat": 0}
	cd.city_quality_detail = {}
	cd.add_to_storage("reed_boat", 1, "common")
	# Из группы boats (только reed_boat) списываем amount=1
	var members = ["reed_boat"]
	var remaining = 1
	for pid in members:
		if remaining <= 0:
			break
		var avail = cd.get_storage_amount(pid)
		if avail <= 0:
			continue
		var take = min(avail, remaining)
		cd.remove_from_storage(pid, take, "best")
		remaining -= take
	check(remaining == 0, "списание из группы не произошло", state)
	check(cd.get_storage_amount("reed_boat") == 0, "склад не обнулился", state)

	# 6) Недоступность: группа не найдена -> запись пропускается
	var bad = gd._build_consumption_entry("@nonexistent_group", {"amount": 1})
	check(bad.is_empty(), "несуществующая группа должна пропускаться", state)

	# 7) Псевдо-профессия "all" (все жители города): групповая запись "@fruits"
	check(gd.professions.has("all"), "в professions.json нет псевдо-профессии all", state)
	check(gd.professions.get("all", {}).get("pseudo", false) == true, "all не помечена pseudo", state)
	var cons_all = gd.get_profession_consumption("all")
	check(cons_all.size() == 1, "ожидалась 1 запись для all, получено: %d" % cons_all.size(), state)
	if cons_all.size() == 1:
		var ea = cons_all[0]
		check(ea.get("is_group", false) == true, "запись all не групповая", state)
		check(ea.get("display_key", "") == "@fruits", "display_key != @fruits", state)
		check(ea.get("product_name", "") == "Фрукты", "имя группы != Фрукты", state)
		check(ea.get("group_members", []) == ["grapes", "olives", "mulberries", "figs", "dates", "cactus_fruit"],
			"члены группы @fruits неверны: %s" % str(ea.get("group_members", [])), state)
		# Как и выше — amount/interval сверяем с самим правилом реестра.
		var rule_all := _rule_for(gd.consumption_rules, "@fruits", "all")
		check(not rule_all.is_empty(), "в реестре нет правила @fruits для all", state)
		if not rule_all.is_empty():
			check(int(ea.get("amount", -1)) == int(rule_all.get("amount", -2)),
				"amount all потерян при разборе правила: %s" % str(ea.get("amount", null)), state)
			check(abs(float(ea.get("interval", -1.0)) - float(rule_all.get("interval", -2.0))) < 0.01,
				"interval all потерян при разборе правила: %s" % str(ea.get("interval", null)), state)

	# 8) Городское потребление "all": списание ПОГОЛОВНО (amount * население)
	#    ПО ФАКТУ НАЛИЧИЯ, без ожидания полного покрытия. Жадное заполнение из
	#    членов группы. Имена автозагрузок (CityData/GameData)
	#    в этом скрипте использовать нельзя — он компилируется ДО их регистрации,
	#    поэтому берём синглтоны через дерево сцены.
	var city = get_root().get_node("CityData") # относительный путь: absolute из --script-режима запрещён
	var gdata = get_root().get_node("GameData")
	# Автозагрузка GameData данные не грузила — отдаём ей уже загруженные
	# реестры (test gd.load_all_data() грузил их в отдельный экземпляр).
	gdata.consumption_rules = gd.consumption_rules
	gdata.product_groups = gd.product_groups
	gdata.product_group_names = gd.product_group_names
	gdata.products = gd.products
	gdata.professions = gd.professions
	gdata.game_balance = gd.game_balance
	var wm = load("res://scripts/worker_manager.gd").new()
	city.total_population = 3 # население прежнее; десятикратно вырос amount
	# 3 жителя * 10 фруктов = 30 за попытку. На складе 40 (20 винограда +
	# 20 оливок): списывается ровно 30, жадно из членов группы.
	city.add_to_storage("grapes", 20, "common")
	city.add_to_storage("olives", 20, "common")
	# Ожидаемый доход казны за единицу: round(price * множитель из game_balance).
	var market_mult := float(gdata.game_balance.get("internal_market_price_multiplier", 0.25))
	var coin_g := int(round(float(gdata.products.get("grapes", {}).get("price", 0)) * market_mult))
	var coin_o := int(round(float(gdata.products.get("olives", {}).get("price", 0)) * market_mult))
	wm.tick_city_consumption(10.0)
	check(city.get_storage_amount("grapes") == 0, "виноград не списан городским потреблением", state)
	check(city.get_storage_amount("olives") == 10, "оливки списаны неверно (ожидается остаток 10)", state)
	check(city.treasury == 20 * coin_g + 10 * coin_o, "доход казны за списание неверен: %d" % city.treasury, state)
	# Частичное списание по факту наличия: остаток 10 < 30 — списывается всё,
	# таймер сбрасывается (не ждём накопления до полных 30).
	wm.tick_city_consumption(10.0)
	check(city.get_storage_amount("olives") == 0, "частичное списание не сработало (ожидается 0 оливок)", state)
	check(city.treasury == 20 * coin_g + 20 * coin_o, "доход казны за частичное списание неверен: %d" % city.treasury, state)
	# Пустой склад: списания нет (таймер сохраняется).
	wm.tick_city_consumption(10.0)
	check(city.treasury == 20 * coin_g + 20 * coin_o, "на пустом складе списания/дохода быть не должно", state)
	# Появился 1 фрукт — списывается тут же, без ожидания полного интервала.
	city.add_to_storage("olives", 1, "common")
	wm.tick_city_consumption(10.0)
	check(city.get_storage_amount("olives") == 0, "появившийся фрукт не списан сразу", state)
	check(city.treasury == 20 * coin_g + 20 * coin_o + coin_o, "доход казны за 1 фрукт неверен: %d" % city.treasury, state)
	# Таймер сериализуется/восстанавливается
	var ser = wm.serialize_city_consumption_timers()
	check(ser.size() == 1 and ser[0].get("resource", "") == "@fruits", "таймер all не сериализуется", state)
	var wm2 = load("res://scripts/worker_manager.gd").new()
	wm2.load_city_consumption_timers(ser)
	check(wm2.city_consumption_timers.has("@fruits"), "таймер all не восстанавливается", state)
	wm.free()
	wm2.free()

	if state["failed"]:
		print("SMOKE TEST FAILED")
		quit(1)
	else:
		print("SMOKE TEST OK")
		quit(0)

# Первое правило реестра consumption.json для пары (ресурс, профессия).
# Нужно, чтобы сверять балансные amount/interval с источником данных, а не
# с константой внутри теста: баланс в json меняется, тест — нет.
func _rule_for(rules: Array, res_key: String, prof_id: String) -> Dictionary:
	for r in rules:
		if str(r.get("resource", "")) == res_key and (prof_id in r.get("profession", [])):
			return r
	return {}

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true

