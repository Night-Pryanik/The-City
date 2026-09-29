# Тест вкладки «Торговля»: внутренний рынок, карточки ресурсов, тумблеры
# разрешения потребления и приоритет списания по качеству.
#   godot --headless --path . --script res://tests/test_trade_tab.gd
#
# Балансные числа (amount/interval, цены, состав групп) сверяются с САМИМИ
# данными, а не с константами теста: баланс в json меняется, тест — нет.
# Проверки:
#
#  1. CityData-состояние рынка: по умолчанию всё разрешено, приоритет —
#     дефолт из data/qualities.json; toggle переключает, неизвестный
#     приоритет из сейва откатывается к дефолтному, пустой ключ — no-op.
#  2. Цикл приоритета: best → worst → random → best, набор и порядок — из
#     данных (quality_priority_options).
#  3. Приоритет РЕАЛЬНО меняет списание: смешанный склад (обычное +
#     превосходное) под "best" съедает превосходное первым, под "worst" —
#     обычное.
#  4. Запрет (тумблер) реально останавливает: городское потребление не
#     списывает склад и не платит в казну; план источник не содержит; бонус
#     производства снят; карточка остаётся в карте с enabled = false.
#  5. get_population_consumption_map: ключ строки — display_key, группа НЕ
#     разворачивается, consumers_total = max(«Все жители», Σ профессий).
#  6. Факт счётчика рынка наполняется при списании и очищается в
#     reset_counters (живёт ровно один тик).
#  7. SaveManager: настройки рынка переживают сохранение; в старом сейве без
#     полей всё разрешено.
#  8. Живая сцена CityUI.tscn: колонки построены по сцене, карточки
#     создаются, обе кнопки-тумблера показывают одно состояние.
extends SceneTree

# Сторож зависаний — см. tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state: Dictionary = {"failed": false}
	var city = get_root().get_node("CityData")
	var gdata = get_root().get_node("GameData")
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	city.treasury = 0
	city.total_population = 3
	# Псевдо-профессия "all" ест @fruits (10 ед. на жителя раз в секунду).
	var all_key := _all_key(gdata)
	var all_members: Array = _all_members(gdata, all_key)
	check(not all_members.is_empty(), "у псевдо-профессии all нет ресурса для проверки", state)

	# ---- 1. Состояние рынка по умолчанию ----
	check(city.is_market_consumption_enabled(all_key),
		"по умолчанию потребление должно быть разрешено", state)
	var default_priority: String = gdata.get_quality_priority_default()
	check(city.get_consumption_priority(all_key) == default_priority,
		"приоритет по умолчанию должен совпадать с qualities.json", state)
	check(city.toggle_market_consumption_enabled(all_key) == false,
		"toggle должен выключить потребление", state)
	check(not city.is_market_consumption_enabled(all_key),
		"после toggle потребление должно быть запрещено", state)
	check(city.toggle_market_consumption_enabled(all_key) == true,
		"второй toggle должен включить потребление обратно", state)
	# Неизвестный приоритет (испорченный сейв) откатывается к дефолту.
	city.consumption_priority[all_key] = "какая-то дичь"
	check(city.get_consumption_priority(all_key) == default_priority,
		"неизвестный приоритет должен откатываться к дефолтному", state)
	# Пустой ключ — no-op (нечего адресовать).
	city.set_market_consumption_enabled("", false)
	check(city.is_market_consumption_enabled(""),
		"пустой ключ должен игнорироваться", state)

	# ---- 2. Цикл приоритета ----
	var options: Array = gdata.get_quality_priority_options()
	check(options.size() >= 2, "нужно минимум два варианта приоритета в данных", state)
	if options.size() >= 2:
		city.consumption_priority[all_key] = str(options[0])
		check(city.cycle_consumption_priority(all_key) == str(options[1]),
			"цикл приоритета должен идти по порядку данных: %s" % str(options), state)
		# Цикл кольцевой: пройдя весь список, возвращаемся к первому.
		# Уже стоим на options[1], осталось сделать size-2 перехода.
		for i in range(1, options.size() - 1):
			city.cycle_consumption_priority(all_key)
		city.cycle_consumption_priority(all_key)
		check(city.get_consumption_priority(all_key) == str(options[0]),
			"цикл приоритета должен замыкаться на первый вариант: %s" % str(options), state)
		# Неизвестное текущее значение стартует цикл с первого варианта.
		city.consumption_priority[all_key] = "мусор"
		check(city.cycle_consumption_priority(all_key) == str(options[1]),
			"при неизвестном текущем значении цикл берёт следующий вариант", state)
		city.consumption_priority.erase(all_key)

	# ---- 3. Приоритет реально меняет порядок списания ----
	# Смешанный склад: 10 обычных + 10 превосходных, списать 10.
	var first_member := str(all_members[0])
	_check_priority_order(city, first_member, "best", "perfect", state)
	_check_priority_order(city, first_member, "worst", "common", state)

	# ---- 4. Запрет реально останавливает городское потребление ----
	var wm = load("res://scripts/worker_manager.gd").new()
	city.total_population = 3
	city.treasury = 0
	for m in all_members:
		city.add_to_storage(str(m), 100, "common")
	# Разрешено — списывается и платит казна.
	wm.tick_city_consumption(1.0)
	var spent_enabled := _total_storage(city, all_members)
	check(spent_enabled > 0, "при разрешённом потреблении списание должно идти", state)
	check(city.treasury > 0, "при разрешённом потреблении казна должна получать доход", state)
	check(int(city.market_consumption_rates.get(first_member, 0)) > 0,
		"факт рынка должен накапливаться при списании", state)
	# Запрещаем — и повторяем тик.
	city.set_market_consumption_enabled(all_key, false)
	var stock_before := _total_storage(city, all_members)
	var treasury_before: int = city.treasury
	wm.tick_city_consumption(1.0)
	check(_total_storage(city, all_members) == stock_before,
		"при запрете склад не должен списываться", state)
	check(city.treasury == treasury_before,
		"при запрете доход в казну не должен идти", state)
	# Запрет виден в плане: у членов запрещённой группы источника нет.
	# Проверяем именно членов этой группы: у псевдо-профессии «Все жители»
	# может быть несколько записей (@fruits и @alcohol), и запрет @fruits
	# не должен выбрасывать из плана @alcohol.
	var plan: Dictionary = wm.get_planned_consumption_map(false)
	var plan_leak := ""
	for m in all_members:
		var member := str(m)
		if plan.has(member) and plan[member].has("Все жители"):
			plan_leak = member
			break
	check(plan_leak == "",
		"запрещённый ресурс не должен попадать в план потребления (найден %s)" % plan_leak, state)
	# Карточка остаётся в карте рынка, но с enabled = false.
	var pop_map: Dictionary = wm.get_population_consumption_map()
	check(pop_map.has(all_key),
		"запрещённый ресурс должен оставаться в карте рынка (иначе его не включить)", state)
	if pop_map.has(all_key):
		check(pop_map[all_key].get("enabled", true) == false,
			"в карте рынка запрещённый ресурс помечен enabled = false", state)
	# Возвращаем разрешение — расход пошёл снова.
	city.set_market_consumption_enabled(all_key, true)
	wm.tick_city_consumption(1.0)
	check(_total_storage(city, all_members) < stock_before,
		"после разрешения списание должно возобновиться", state)

	# ---- 4b. Запрет снимает бонус производства ----
	# Берём запись рыбака (@boats): у неё production_bonus +50%.
	var boats_key := "@boats"
	if gdata.product_groups.has("boats"):
		for m in gdata.product_groups["boats"]:
			city.add_to_storage(str(m), 100, "common")
		var cons_list: Array = gdata.get_profession_consumption("fisherman")
		var bonus_on := 0.0
		for e in cons_list:
			bonus_on += wm._aggregate_production_bonus([e])
		check(bonus_on > 0.0,
			"с расходниками на складе бонус производства должен начисляться", state)
		city.set_market_consumption_enabled(boats_key, false)
		var bonus_off := 0.0
		for e in cons_list:
			bonus_off += wm._aggregate_production_bonus([e])
		check(bonus_off == 0.0,
			"при запрете потребления бонус производства должен быть снят", state)
		city.set_market_consumption_enabled(boats_key, true)

	# ---- 5. Форма карты рынка ----
	check(pop_map.has(all_key), "карта рынка должна содержать ресурс псевдо-профессии all", state)
	if pop_map.has(all_key):
		var row: Dictionary = pop_map[all_key]
		check(row.get("is_group", false) == true,
			"ресурс псевдо-профессии all — группа, is_group должен быть true", state)
		check((row.get("members", []) as Array).size() == all_members.size(),
			"группа не должна разворачиваться: members = все члены", state)
		check(int(row.get("consumers_total", 0)) == 3,
			"consumers_total для «Все жители» должен равняться населению: %d" % int(row.get("consumers_total", 0)), state)
		# Скорость: amount на жителя / interval, умноженная на население.
		# Считаем ТОЛЬКО по записям этой карточки: у псевдо-профессии all их
		# несколько (@fruits и @alcohol), а скорость строки — её собственная.
		var expected := 0.0
		for e in gdata.get_profession_consumption("all"):
			if str(e.get("display_key", "")) != all_key:
				continue
			var amount := float(e.get("amount", 0))
			var iv := float(e.get("interval", 0))
			expected += (amount * 3.0 * city.SIMULATION_TICK / iv) if iv > 0.0 else amount * 3.0 * city.SIMULATION_TICK
		check(absf(float(row.get("per_sec", -1.0)) - expected) < 0.01,
			"per_sec карточки неверен: ожидалось %.2f, получено %.2f" % [expected, float(row.get("per_sec", 0.0))], state)
	# Ключ карты — display_key, а не pid: у рыбака это "@boats", а не pid.
	# Назначаем рыбака на улучшение, чтобы профессия появилась в карте.
	var pop_map2: Dictionary = wm.get_population_consumption_map()
	var has_group_row := pop_map2.has("@boats")
	check(has_group_row or not pop_map2.has("reed_boat"),
		"строки карточек должны ключеваться display_key, а не pid", state)
	# Рыбак входит и в «Все жители»: consumers_total = max(3, 1) = 3.
	if has_group_row:
		var boats_row: Dictionary = pop_map2["@boats"]
		check(int(boats_row.get("consumers_total", 0)) == 1,
			"потребителей у @boats должен быть один рыбак: %d" % int(boats_row.get("consumers_total", 0)), state)

	# ---- 6. Факт живёт ровно один тик ----
	check(city.market_consumption_rates.size() > 0,
		"факт рынка должен быть наполнен после списания", state)
	city.reset_counters()
	check(city.market_consumption_rates.is_empty(),
		"reset_counters должен очищать факт рынка", state)

	# ---- 7. Сохранение настроек ----
	city.set_market_consumption_enabled(all_key, false)
	city.set_consumption_priority(all_key, "worst")
	var market_before: Dictionary = city.market_consumption_enabled.duplicate()
	var priority_before: Dictionary = city.consumption_priority.duplicate()
	# Старый сейв без полей рынка — всё должно быть разрешено.
	save_manager.saved_data = {"city_food_pool": {}}
	save_manager.apply_loaded_data()
	check(city.is_market_consumption_enabled(all_key),
		"в старом сейве без полей рынка потребление должно быть разрешено", state)
	# Возврат сохранённых значений.
	save_manager.saved_data = {
		"market_consumption_enabled": market_before,
		"consumption_priority": priority_before,
	}
	save_manager.apply_loaded_data()
	check(not city.is_market_consumption_enabled(all_key),
		"настройка запрета должна переживать сохранение", state)
	check(city.get_consumption_priority(all_key) == "worst",
		"приоритет должен переживать сохранение", state)
	city.market_consumption_enabled.clear()
	city.consumption_priority.clear()

	# ---- 8. Живая сцена CityUI ----
	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame
	var city_ui = main_map.get_node_or_null("CityUI")
	check(city_ui != null, "CityUI не найдена в MainMap", state)
	if city_ui != null:
		# Колонки вкладки «Торговля» — из сцены, обе на месте.
		var internal_panel = city_ui.get_node_or_null("ContentPanel/TradePanel/Split/InternalPanel")
		var external_panel = city_ui.get_node_or_null("ContentPanel/TradePanel/Split/ExternalPanel")
		check(internal_panel != null,
			"в сцене нет левой колонки «Внутренняя торговля»", state)
		check(external_panel != null,
			"в сцене нет правой колонки «Внешняя торговля»", state)
		if external_panel != null:
			var ext_title: Label = external_panel.get_node_or_null("TitleLabel")
			check(ext_title != null and ext_title.text == "Внешняя торговля",
				"у внешней торговли должен быть заголовок", state)
			# Внешняя торговля — заглушка: кроме заголовка ничего нет.
			check(external_panel.get_child_count() == 1,
				"колонка внешней торговли пока должна содержать только заголовок", state)
		# Открываем вкладку и смотрим карточки.
		city_ui.refresh()
		city_ui._switch_tab("trade")
		await process_frame
		var list = city_ui.get_node_or_null(
			"ContentPanel/TradePanel/Split/InternalPanel/InternalScroll/InternalList")
		check(list != null, "нет списка карточек внутренней торговли", state)
		if list != null and list.get_child_count() > 0:
			var card = list.get_child(0)
			check(card.get_node_or_null("Layout/Header/TradeToggleRect") != null,
				"в карточке нет кнопки-прямоугольника", state)
			check(card.get_node_or_null("Layout/Header/TradeCheckBox") != null,
				"в карточке нет чекбокса", state)
			check(card.get_node_or_null("Layout/Header/PriorityButton") != null,
				"в карточке нет кнопки приоритета", state)
			var tab = city_ui.trade_tab
			if tab != null and not tab.cards.is_empty():
				var key: String = str(tab.cards.keys()[0])
				var ctx: Dictionary = tab.cards[key]
				var rect: ColorRect = ctx["toggle_rect"]
				var box: CheckBox = ctx["checkbox"]
				var before: bool = city.is_market_consumption_enabled(key)
				var expected_color := Color(0, 0.8, 0, 1) if before else Color(0.8, 0.1, 0.1, 1)
				check(rect.color == expected_color,
					"цвет прямоугольника должен соответствовать состоянию", state)
				check(box.button_pressed == before,
					"чекбокс должен показывать то же состояние, что и прямоугольник", state)
				# Клик по чекбоксу переключает состояние рынка.
				box.button_pressed = not before
				box.toggled.emit(box.button_pressed)
				check(city.is_market_consumption_enabled(key) != before,
					"клик по чекбоксу должен менять состояние рынка", state)
				# Клик по прямоугольнику — тоже (тот же тумблер).
				var after_box: bool = city.is_market_consumption_enabled(key)
				var click := InputEventMouseButton.new()
				click.button_index = MOUSE_BUTTON_LEFT
				click.pressed = true
				tab._on_toggle_rect_input(click, key)
				check(city.is_market_consumption_enabled(key) != after_box,
					"клик по прямоугольнику должен менять состояние рынка", state)
				# После правки обе кнопки показывают одно состояние.
				tab.update_values()
				var current: bool = city.is_market_consumption_enabled(key)
				check(box.button_pressed == current,
					"обе кнопки должны показывать одно состояние после правки", state)
				var rect_after := Color(0, 0.8, 0, 1) if current else Color(0.8, 0.1, 0.1, 1)
				check(rect.color == rect_after,
					"прямоугольник должен совпадать с чекбоксом после обновления", state)
				# Кнопка приоритета циклит настройку.
				var priority_was: String = city.get_consumption_priority(key)
				tab._on_priority_pressed(key)
				check(city.get_consumption_priority(key) != priority_was,
					"кнопка приоритета должна менять приоритет потребления", state)
	# Уборка состояния, чтобы тест не влиял на следующие прогоны.
	city.total_population = 1
	city.city_storage.clear()
	city.city_quality_detail.clear()
	city.market_consumption_enabled.clear()
	city.consumption_priority.clear()
	city.market_consumption_rates.clear()
	wm.free()
	main_map.queue_free()

	if state["failed"]:
		print("TRADE TAB TEST FAILED")
		quit(1)
	else:
		print("TRADE TAB TEST OK")
		quit(0)

# Проверяет, что приоритет реально определяет, КАКОЕ качество съедается
# первым: кладём 10 обычных + 10 превосходных и списываем 10.
func _check_priority_order(city, pid: String, priority: String, expected_first: String, state: Dictionary) -> void:
	city.city_storage.clear()
	city.city_quality_detail.clear()
	city.set_consumption_priority(pid, priority)
	city.add_to_storage(pid, 10, "common")
	city.add_to_storage(pid, 10, "perfect")
	city.remove_from_storage(pid, 10, city.get_consumption_priority(pid))
	var detail: Dictionary = city.get_quality_breakdown(pid)
	check(int(detail.get(expected_first, 0)) == 0,
		"приоритет «%s» должен был съесть качество «%s» первым" % [priority, expected_first], state)
	city.consumption_priority.erase(pid)

# Сумма запаса по членам группы.
func _total_storage(city, members: Array) -> int:
	var total := 0
	for m in members:
		total += city.get_storage_amount(str(m))
	return total

# display_key ресурса псевдо-профессии "all" (берём из данных, а не хардкодим).
func _all_key(gdata) -> String:
	for e in gdata.get_profession_consumption("all"):
		var key := str(e.get("display_key", ""))
		if not key.is_empty():
			return key
	return ""

# Члены группы ресурса псевдо-профессии "all".
func _all_members(gdata, key: String) -> Array:
	if key.begins_with("@"):
		return gdata.product_groups.get(key.trim_prefix("@"), [])
	return [key] if not key.is_empty() else []

func check(condition: bool, message: String, state: Dictionary) -> void:
	if condition:
		print("OK: ", message)
	else:
		state["failed"] = true
		push_error("FALL: " + message)
