# Headless-тест показа ПРОФЕССИОНАЛЬНОГО ПОТРЕБЛЕНИЯ ЗДАНИЙ:
#   godot --headless --path . --script res://tests/test_building_consumption_ui.gd
#
# Проверяется:
#   1. ConsumptionUi.build_rows_for_building(): строки расхода профессии здания
#      («Перья: 2 шт./сек (+25% к производству)» — 10 шт. раз в 5 сек из
#      data/consumption.json), умножение на число РАБОЧИХ зданий
#      («4 шт./сек (2 здания)»), случай без рабочих зданий и здание без
#      профессии (пустой список).
#   2. Тултип деталей здания (вкладка «Здания»): секция «Потребляет:» со
#      скоростью расхода — показывается до постройки, как «Стоимость».
#   3. Окно деталей здания: сумма по двум рабочим постройкам, затем пометка
#      «(рабочих зданий нет)», когда слоты здания пусты (здание простаивает и
#      расходники не тратит).
#
# ВАЖНО: скрипт компилируется ДО регистрации автозагрузок, поэтому берём их
# через дерево сцены, а общий помощник — load() по пути (тот же приём, что с
# HexUtils в test_territory_costs и с underlined_label в ui_helpers).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
	WATCHDOG.arm(self)
	_run()


func _run() -> void:
	var state = {"failed": false}
	var consumption_ui = load("res://scripts/consumption_ui.gd")

	# --- Живая сцена: новая игра, город, интерфейс ---
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame
	main_map.open_city()
	await process_frame
	var city_ui = main_map.city_ui
	check(city_ui != null and city_ui.visible, "интерфейс города открыт", state)
	var gdata = get_root().get_node("GameData")

	# --- 1. Строки профессионального потребления профессии здания ---
	check(gdata.get_profession_for_building("library") == "scientist",
		"у библиотеки профессия scientist (получено: %s)"
			% gdata.get_profession_for_building("library"), state)
	var rows = consumption_ui.build_rows_for_building("library")
	check(rows.size() == 1,
		"у библиотеки одна строка расхода (получено: %d)" % rows.size(), state)
	if rows.size() == 1:
		var row: Dictionary = rows[0]
		check(str(row.get("display_key", "")) == "feathers",
			"расходник библиотеки — feathers (получено: %s)" % str(row.get("display_key", "")), state)
		check(str(row.get("name", "")) == "Перья",
			"имя расходника «Перья» (получено: %s)" % str(row.get("name", "")), state)
		check(is_equal_approx(float(row.get("per_sec", 0.0)), 2.0),
			"скорость 10 шт. / 5 сек = 2 шт./сек (получено: %s)" % str(row.get("per_sec", 0.0)), state)
		check(str(row.get("label", "")) == "Перья: 2 шт./сек (+25% к производству)",
			"подпись строки совпадает с тултипом гекса (получено: «%s»)" % str(row.get("label", "")), state)
	# Суммирование по рабочим зданиям того же типа.
	var rows2 = consumption_ui.build_rows_for_building("library", 2)
	if rows2.size() == 1:
		check(str(rows2[0].get("label", "")) == "Перья: 4 шт./сек (2 здания) (+25% к производству)",
			"два рабочих здания дают сумму и пометку (получено: «%s»)" % str(rows2[0].get("label", "")), state)
	else:
		check(false, "при двух рабочих зданиях строка одна (получено: %d)" % rows2.size(), state)
	# Рабочих зданий нет: скорость остаётся «на одно здание», но подпись говорит, почему.
	var rows0 = consumption_ui.build_rows_for_building("library", 0)
	if rows0.size() == 1:
		check(str(rows0[0].get("label", "")) == "Перья: 2 шт./сек (рабочих зданий нет) (+25% к производству)",
			"без рабочих зданий есть пометка (получено: «%s»)" % str(rows0[0].get("label", "")), state)
	else:
		check(false, "без рабочих зданий строка одна (получено: %d)" % rows0.size(), state)
	# Здание без профессии: показывать нечего.
	check(consumption_ui.build_rows_for_building("bakery").is_empty(),
		"у пекарни (без профессии) строк расхода нет", state)
	check(consumption_ui.build_rows_for_building("").is_empty(),
		"для пустого id здания строк расхода нет", state)


	# --- 2. Тултип деталей здания на вкладке «Здания» ---
	var btab = city_ui.buildings_tab
	var library = null
	for b in btab.buildings_data:
		if b.get("id", "") == "library":
			library = b
			break
	check(library != null, "данные библиотеки есть во вкладке «Здания»", state)
	if library != null:
		btab._hovered_building_id = "library"
		btab._show_building_details(library)
		var tip_texts := _collect_texts(city_ui.ui_helpers.detail_tooltip_content)
		check(_has_line(tip_texts, "Потребляет:"),
			"в тултипе деталей есть заголовок «Потребляет:» (получено: %s)" % str(tip_texts), state)
		check(_has_text(tip_texts, "2 шт./сек"),
			"в тултипе деталей есть скорость расхода «2 шт./сек» (получено: %s)" % str(tip_texts), state)
		check(_has_text(tip_texts, "+25% к производству"),
			"в тултипе деталей есть бонус «+25%% к производству» (получено: %s)" % str(tip_texts), state)
		# У здания без профессии секции быть не должно.
		var bakery = null
		for b in btab.buildings_data:
			if b.get("id", "") == "bakery":
				bakery = b
				break
		if bakery != null:
			btab._show_building_details(bakery)
			var bakery_texts := _collect_texts(city_ui.ui_helpers.detail_tooltip_content)
			check(not _has_line(bakery_texts, "Потребляет:"),
				"у пекарни (без профессии) секции «Потребляет:» нет", state)

	# --- 3. Окно деталей здания: сумма по рабочим зданиям ---
	var city = get_root().get_node("CityData")
	city.city_built_buildings = [
		{"id": "library", "slots": ["science"], "quality_priority": "best"},
		{"id": "library", "slots": ["science"], "quality_priority": "best"},
	]
	city.idle_population = maxi(city.idle_population, 4)
	var tm = main_map.get_node("TownsfolkManager")
	check(tm.assign_townsfolk(0), "горожанин назначен в первое здание", state)
	check(tm.assign_townsfolk(1), "горожанин назначен во второе здание", state)
	city_ui._on_building_detail_requested("library")
	await process_frame
	var panel = city_ui.building_panel
	check(panel != null and panel.visible, "окно деталей здания открыто", state)
	if panel != null:
		check(panel.consumption_box != null and panel.consumption_box.visible,
			"секция «Потребляет:» показана в окне здания", state)
		var panel_texts := _collect_texts(panel.consumption_box)
		check(_has_text(panel_texts, "4 шт./сек (2 здания)"),
			"окно здания показывает сумму по двум рабочим (получено: %s)" % str(panel_texts), state)
		check(_has_text(panel_texts, "+25% к производству"),
			"окно здания показывает бонус к производству (получено: %s)" % str(panel_texts), state)
		# Одно здание простаивает (слоты пустые) — расходник не тратится.
		city.city_built_buildings[1]["slots"] = ["empty"]
		panel._refresh()
		var idle_texts := _collect_texts(panel.consumption_box)
		check(_has_text(idle_texts, "2 шт./сек"),
			"при простаивающем здании скорость — одно здание (получено: %s)" % str(idle_texts), state)
		check(not _has_text(idle_texts, "(2 здания)"),
			"простаивающее здание не попадает в сумму (получено: %s)" % str(idle_texts), state)
		# Оба здания без горожан — расхода нет, но скорость «на здание» видна.
		tm.remove_townsfolk(0)
		tm.remove_townsfolk(1)
		panel._refresh()
		var no_worker_texts := _collect_texts(panel.consumption_box)
		check(_has_text(no_worker_texts, "рабочих зданий нет"),
			"без горожан есть пометка «рабочих зданий нет» (получено: %s)" % str(no_worker_texts), state)
		# Здание без профессии: секция скрыта.
		city.city_built_buildings = [{"id": "bakery", "slots": ["bread"], "quality_priority": "best"}]
		var bakery_data = city_ui.data_cache.duplicate()
		bakery_data["ui_helpers"] = city_ui.ui_helpers
		panel.open("bakery", bakery_data)
		check(panel.consumption_box.get_child_count() == 0 and not panel.consumption_box.visible,
			"у здания без профессии секция «Потребляет:» скрыта", state)

	_finish(main_map, state)

# Собирает тексты всех меток под узлом (Label и RichTextLabel на любой глубине).
func _collect_texts(node: Node) -> Array:
	var result: Array = []
	for child in node.get_children():
		if child is Label:
			result.append(str((child as Label).text))
		elif child is RichTextLabel:
			result.append(str((child as RichTextLabel).text))
		else:
			result.append_array(_collect_texts(child))
	return result

func _has_text(texts: Array, needle: String) -> bool:
	for t in texts:
		if str(t).contains(needle):
			return true
	return false

func _has_line(texts: Array, line: String) -> bool:
	for t in texts:
		if str(t) == line:
			return true
	return false

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("BUILDING CONSUMPTION UI TEST FAILED")
		quit(1)
	else:
		print("BUILDING CONSUMPTION UI TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
