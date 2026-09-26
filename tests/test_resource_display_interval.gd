# Headless-тест настройки «Интервал обновления данных о ресурсах»:
#   godot --headless --path . --script res://tests/test_resource_display_interval.gd
#
# Проверяется:
#   1. Слайдер в настройках (вкладка «Игра»): диапазон 1..5, шаг 1; ключ
#      game/resource_display_interval сохраняется в user://settings.cfg и
#      читается обратно при повторном открытии настроек.
#   2. CityData.set_resource_display_interval(): кламп 1..5, целые значения,
#      повышение эпохи при смене значения; tick_resource_display() повышает
#      эпоху по накоплению интервала.
#   3. На живой сцене MainMap.tscn (новая игра, интервал 3 сек): метка запаса
#      вкладки «Ресурсы», верхняя строка «Еда: N», строка «Требуется/на складе»
#      в тултипе деталей здания и левая колонка панели управления обновляются
#      ТОЛЬКО по наступлении интервала; событийный city_ui.refresh_light()
#      обновляет мгновенно.
#   4. Метка качества в строке вкладки «Ресурсы» — это RichTextLabel с
#      включённым BBCode (текст с тегами [color=…]), и на пустой разбивке по
#      качеству она прячется.
#
# ВАЖНО: после последнего await весь проверочный код идёт синхронно в одном
# кадре — накопитель main_map._process не успевает сместить эпоху, и проверки
# детерминированы. Единственный await после них — в самом конце (пункт 3f, замер
#      геометрии строк): контейнеры пересчитывают размеры в конце кадра, а эпохи
#      там уже не проверяются.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state = {"failed": false}
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var city = get_root().get_node("CityData")

	# --- 1. Меню настроек: слайдер и ключ конфига ---
	var settings = load("res://scenes/settings_menu.tscn").instantiate()
	get_root().add_child(settings)
	await process_frame
	var slider = settings.find_child("ResourceDisplayIntervalSlider", true, false)
	var value_label = settings.find_child("ResourceDisplayIntervalValueLabel", true, false)
	check(slider != null, "слайдер ResourceDisplayIntervalSlider найден", state)
	check(value_label != null, "метка ResourceDisplayIntervalValueLabel найдена", state)
	if slider != null:
		check(is_equal_approx(slider.min_value, 1.0) and is_equal_approx(slider.max_value, 5.0),
			"слайдер задан от 1 до 5 секунд", state)
		check(is_equal_approx(slider.step, 1.0), "шаг слайдера — 1 секунда", state)
		slider.value = 3.0
	settings.save_settings()
	check(value_label != null and value_label.text == "3 сек",
		"метка слайдера показывает «3 сек» (получено: %s)" % (value_label.text if value_label else "null"), state)
	var cfg = ConfigFile.new()
	var err = cfg.load("user://settings.cfg")
	check(err == OK, "settings.cfg сохранён", state)
	if err == OK:
		check(is_equal_approx(float(cfg.get_value("game", "resource_display_interval", 0.0)), 3.0),
			"ключ game/resource_display_interval сохранён со значением 3", state)

	# Повторное открытие настроек читает сохранённое значение.
	settings.queue_free()
	await process_frame
	var settings2 = load("res://scenes/settings_menu.tscn").instantiate()
	get_root().add_child(settings2)
	await process_frame
	var slider2 = settings2.find_child("ResourceDisplayIntervalSlider", true, false)
	check(slider2 != null and is_equal_approx(slider2.value, 3.0),
		"слайдер читает сохранённое значение 3", state)
	settings2.queue_free()
	await process_frame

	# --- 2. CityData: кламп, шаг и «эпоха» ---
	city.set_resource_display_interval(10.0)
	check(is_equal_approx(city.resource_display_interval, 5.0),
		"кламп сверху: 10 → 5 секунд", state)
	city.set_resource_display_interval(0.0)
	check(is_equal_approx(city.resource_display_interval, 1.0),
		"кламп снизу: 0 → 1 секунда", state)
	check(is_equal_approx(city.resource_display_interval, roundf(city.resource_display_interval)),
		"интервал всегда целый (шаг 1 секунда)", state)
	var epoch_unit = city.resource_display_epoch
	city.tick_resource_display(0.5)
	check(city.resource_display_epoch == epoch_unit,
		"при интервале 1 сек полсекунды эпоху не двигают", state)
	city.tick_resource_display(0.6)
	check(city.resource_display_epoch > epoch_unit,
		"эпоха повышается, когда накоплен интервал", state)
	var epoch_same = city.resource_display_epoch
	city.set_resource_display_interval(1.0)
	check(city.resource_display_epoch == epoch_same,
		"повторное установление того же значения — no-op (эпоха не меняется)", state)
	# Оставляем 1 сек: main_map._ready применит сохранённые в п.1 три секунды.
	city.set_resource_display_interval(1.0)

	# --- 3. Интеграция на живой сцене MainMap ---
	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame
	check(is_equal_approx(main_map.resource_display_interval, 3.0),
		"main_map._load_settings() прочитал интервал 3 из cfg (получено: %s)" % main_map.resource_display_interval, state)
	check(is_equal_approx(city.resource_display_interval, 3.0),
		"настройка применена в CityData при старте карты", state)

	main_map.open_city()
	await process_frame
	var city_ui = main_map.city_ui
	check(city_ui.visible, "интерфейс города открыт", state)

	# --- ДАЛЬШЕ ТОЛЬКО СИНХРОННЫЙ КОД (без await): детерминированные эпохи ---
	# Чистый старт накопителя: смена значения сбрасывает accum (1 → 3).
	city.set_resource_display_interval(1.0)
	city.set_resource_display_interval(3.0)
	check(is_equal_approx(city.resource_display_interval, 3.0),
		"интервал переведён в 3 секунды", state)

	var res_tab = city_ui.resources_tab
	var pid := ""
	for k in res_tab.amount_labels.keys():
		pid = k
		break
	check(pid != "", "во вкладке «Ресурсы» есть хотя бы одна строка", state)

	# --- 3a. Метка запаса вкладки «Ресурсы» ---
	if pid != "":
		var label = res_tab.amount_labels.get(pid, null)
		check(label != null, "метка запаса строки найдена", state)
		var prod_name: String = str(res_tab.products.get(pid, {}).get("name", pid))
		var amount_before: int = int(city.city_storage.get(pid, 0))
		city_ui.refresh_light()  # событийное обновление — мгновенно
		var text_before: String = label.text
		check(text_before == "%s: %d  " % [prod_name, amount_before],
			"после событийного обновления метка показывает текущий запас %d (получено: «%s»)" % [amount_before, text_before], state)

		# Правило «события мгновенно»: refresh_light() видит новый запас сразу.
		city.add_to_storage(pid, 5)
		city_ui.refresh_light()
		check(label.text == "%s: %d  " % [prod_name, amount_before + 5],
			"refresh_light() (событие) обновил метку мгновенно на %d" % (amount_before + 5), state)

		# Тиковый путь: до наступления интервала city_updated не двигает метку.
		var epoch_res = city.resource_display_epoch
		var shown: String = label.text
		city.tick_resource_display(1.0)
		check(city.resource_display_epoch == epoch_res,
			"интервал 3 сек: через 1 секунду эпоха стоит", state)
		city.emit_signal("city_updated")
		check(label.text == shown,
			"до наступления интервала тик city_updated не меняет метку запаса", state)
		city.tick_resource_display(1.0)
		check(city.resource_display_epoch == epoch_res,
			"интервал 3 сек: через 2 секунды эпоха стоит", state)
		city.tick_resource_display(1.0)
		check(city.resource_display_epoch > epoch_res,
			"интервал 3 сек: на 3-й секунде эпоха повышена", state)
		# Меняем склад ДО эмита с наступившей эпохой — тик обязан показать.
		city.add_to_storage(pid, 5)
		city.emit_signal("city_updated")
		check(label.text == "%s: %d  " % [prod_name, amount_before + 10],
			"после интервала тик city_updated обновил метку на %d (получено: «%s»)"
				% [amount_before + 10, label.text], state)

	# --- 3b. Верхняя строка «Еда: N» ---
	# TopFoodLabel в сцене стал HBoxContainer с тремя дочерними метками;
	# текст «Еда» живёт в city_ui.top_food_value_label (см. city_ui.gd:18).
	var food_pid := ""
	for k in city.city_food_pool.keys():
		if bool(city.city_food_pool.get(k, false)):
			food_pid = k
			break
	if food_pid != "":
		city_ui.refresh_light()  # синхронизация эпохи + свежая отрисовка
		var food_before: String = city_ui.top_food_value_label.text
		var epoch_food = city.resource_display_epoch
		city.add_to_storage(food_pid, 7)
		city.emit_signal("city_updated")
		check(city_ui.top_food_value_label.text == food_before,
			"до интервала верхняя строка «Еда» не обновилась", state)
		city.tick_resource_display(1.0)
		city.tick_resource_display(1.0)
		city.tick_resource_display(1.0)
		check(city.resource_display_epoch > epoch_food,
			"эпоха верхней строки повышена через 3 секунды", state)
		city.emit_signal("city_updated")
		check(city_ui.top_food_value_label.text != food_before,
			"после интервала верхняя строка «Еда» обновилась", state)

	# --- 3c. Тултип деталей здания: строка «Требуется/на складе» ---
	var btab = city_ui.buildings_tab
	var bdata = null
	for b in btab.buildings_data:
		if b.has("additional_cost"):
			bdata = b
			break
	check(bdata != null, "найдено здание с additional_cost для тултипа деталей", state)
	if bdata != null:
		btab._hovered_building_id = bdata["id"]
		btab._show_building_details(bdata)
		city_ui.ui_helpers.detail_tooltip_panel.visible = true
		check(btab._detail_material_rows.size() > 0,
			"в тултипе деталей есть строки материалов", state)
		if btab._detail_material_rows.size() > 0:
			var row0: Dictionary = btab._detail_material_rows[0]
			var mat_label = row0["amount_label"]
			var res0: String = row0["resource_id"]
			var req0: int = int(row0["required_amount"])
			var avail0: int = int(city.city_storage.get(res0, 0))
			check(mat_label.text == "%d/%d" % [req0, avail0],
				"первая сборка тултипа показывает текущий склад %s" % mat_label.text, state)
			# Синхронизируем эпоху тултипа фиксированным «рывком» интервала
			# (между открытием тултипа и этим местом эпоха могла наступить).
			city.tick_resource_display(1.0)
			city.tick_resource_display(1.0)
			city.tick_resource_display(1.0)
			city.emit_signal("city_updated")
			var epoch_mat = city.resource_display_epoch
			avail0 = int(city.city_storage.get(res0, 0))
			var mat_before: String = mat_label.text
			city.add_to_storage(res0, 50)
			city.emit_signal("city_updated")
			check(mat_label.text == mat_before,
				"до интервала строка материалов не обновилась (осталось: %s)" % mat_before, state)
			city.tick_resource_display(1.0)
			city.tick_resource_display(1.0)
			city.tick_resource_display(1.0)
			check(city.resource_display_epoch > epoch_mat,
				"эпоха тултипа здания повышена", state)
			city.emit_signal("city_updated")
			var mat_expected: String = "%d/%d" % [req0, avail0 + 50]
			check(mat_label.text == mat_expected,
				"после интервала строка материалов обновилась (ожидалось: %s, получено: %s)"
					% [mat_expected, mat_label.text], state)

	# --- 3d. Панель управления гексом: левая колонка ---
	var cp = main_map.control_panel
	main_map.select_hex(main_map.city_row, main_map.city_col)  # событие — сразу
	check(cp.has_selection(), "гекс города выделен", state)
	cp._info_label.text = "СЕНТИНЕЛ"
	var epoch_cp = city.resource_display_epoch
	city.emit_signal("city_updated")
	check(cp._info_label.text == "СЕНТИНЕЛ",
		"до интервала левая колонка панели не перерисовывается", state)
	city.tick_resource_display(1.0)
	city.tick_resource_display(1.0)
	city.tick_resource_display(1.0)
	check(city.resource_display_epoch > epoch_cp, "эпоха панели повышена", state)
	city.emit_signal("city_updated")
	check(cp._info_label.text != "СЕНТИНЕЛ" and cp._info_label.text != "",
		"после интервала левая колонка перерисована", state)

	# --- 3e. Метка качества в строке вкладки «Ресурсы» ---
	# Метка обязана быть RichTextLabel: теги [color=…] (BBCode) понимает только
	# он, а в строку попадает ровно такой текст (GameData.format_quality_share_text).
	# На обычном Label та же строка вывелась бы как «[color=#a0a0a0]30%[/color]».
	var gd = get_root().get_node("GameData")
	var q_pid := ""
	for k in res_tab.quality_labels.keys():
		q_pid = str(k)
		break
	check(q_pid != "", "в списке ресурсов есть строка с меткой качества", state)
	if q_pid != "":
		var q_breakdown := {"common": 30, "perfect": 60}
		city.city_quality_detail[q_pid] = q_breakdown
		city_ui.refresh_light()  # событийное обновление — мгновенно
		var q_label = res_tab.quality_labels.get(q_pid)
		check(q_label is RichTextLabel,
			"метка качества должна быть RichTextLabel (BBCode есть только у него), получено: %s"
			% (q_label.get_class() if q_label != null else "null"), state)
		if q_label is RichTextLabel:
			check((q_label as RichTextLabel).bbcode_enabled,
				"у метки качества включён bbcode_enabled", state)
			check((q_label as RichTextLabel).fit_content,
				"метка качества вписывается в содержимое (fit_content)", state)
			check((q_label as RichTextLabel).autowrap_mode == TextServer.AUTOWRAP_OFF,
				"у метки качества выключен перенос строк (AUTOWRAP_OFF) — иначе она сообщает
				минимальную ширину 1 px, строка встаёт в столбик, а иконка растягивается
				(получено: %d)" % (q_label as RichTextLabel).autowrap_mode, state)
			check((q_label as RichTextLabel).vertical_alignment == VERTICAL_ALIGNMENT_CENTER,
				"текст метки качества выровнен по центру строки", state)
			var q_expected := "[color=#%s]★[/color] %s" % [
				res_tab.QUALITY_MARKER_COLOR.to_html(false),
				gd.format_quality_share_text(q_breakdown)]
			check(str((q_label as RichTextLabel).text) == q_expected,
				"метка качества = голубая звезда + доли по складу (ожидалось: «%s», получено: «%s»)"
				% [q_expected, str((q_label as RichTextLabel).text)], state)
			# Пустая разбивка — метка прячется, а не показывает 0%.
			city.city_quality_detail[q_pid] = {}
			city_ui.refresh_light()
			check(not (q_label as RichTextLabel).visible,
				"при пустой разбивке метка качества прячется", state)
			# Возвращаем разбивку: дальше по тесту она больше не нужна.
			city.city_quality_detail[q_pid] = q_breakdown
			city_ui.refresh_light()

	# --- 3f. Геометрия строк списка ресурсов (после реальной раскладки) ---
	# Контейнеры пересчитывают размеры в конце кадра, поэтому здесь и нужен
	# await: эпохи выше уже проверены, а ниже они больше не используются.
	# Регресс, который ловит этот пункт: RichTextLabel с fit_content и включённым
	# переносом строк сообщает минимальную ширину 1 px → HBox отдаёт метке 1 px →
	# «★ (33%/67%)» встаёт в столбик по букве → строка расползается до ~200 px, а
	# иконка (STRETCH_SCALE, вертикальный FILL) растягивается в 40×200. Итог:
	# «звезда размером 1 пиксель» и «поломанные» иконки ресурсов.
	await process_frame
	await process_frame
	var res_list = city_ui.get_node("ContentPanel/ResourcesPanel/ScrollContainer/ResourcesList")
	var tall_rows: int = 0
	var bad_icons: int = 0
	var bad_markers: int = 0
	var rows_checked: int = 0
	var icons_checked: int = 0
	var markers_checked: int = 0
	for node in res_list.get_children():
		if not (node is HBoxContainer):
			continue
		rows_checked += 1
		var row: HBoxContainer = node
		if row.size.y > 64.0:
			tall_rows += 1
			print("  высокая строка (%.1f px): %s" % [row.size.y, str(row.get_child(0).name)])
		for child in row.get_children():
			if child is TextureRect:
				icons_checked += 1
				var ic: TextureRect = child
				if not is_equal_approx(ic.size.x, 40.0) or not is_equal_approx(ic.size.y, 40.0):
					bad_icons += 1
					print("  иконка %s: %s" % [str(ic.texture.resource_path.get_file()), str(ic.size)])
			elif child is RichTextLabel and (child as Control).visible:
				# Скрытые метки (пустая разбивка по качеству) в раскладке не участвуют
				# и остаются с нулевым размером — их не считаем.
				var rl: RichTextLabel = child
				markers_checked += 1
				if rl.size.x < 20.0:
					bad_markers += 1
					print("  схлопнувшаяся метка качества: %s" % str(rl.size))
	check(rows_checked > 0, "в списке ресурсов есть строки-HBoxContainer для замера геометрии", state)
	check(icons_checked > 0, "в списке ресурсов есть иконки для замера геометрии (проверено: %d)" % icons_checked, state)
	check(markers_checked > 0, "в списке есть видимые метки качества для замера геометрии (проверено: %d)" % markers_checked, state)
	check(tall_rows == 0,
		"ни одна строка списка ресурсов не расползлась по высоте (строк с высотой > 64 px: %d из %d)"
		% [tall_rows, rows_checked], state)
	check(bad_icons == 0,
		"все иконки ресурсов ровно 40×40 и не растянуты по высоте строки (искажённых: %d из %d)"
		% [bad_icons, icons_checked], state)
	check(bad_markers == 0,
		"метки качества не схлопнулись до 1 px по ширине (схлопнутых: %d)" % bad_markers, state)

	_finish(main_map, state)

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("RESOURCE DISPLAY INTERVAL TEST FAILED")
		quit(1)
	else:
		print("RESOURCE DISPLAY INTERVAL TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
