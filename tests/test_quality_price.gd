# Headless-тест цены товара по качеству (data/qualities.json, price_multiplier):
#   godot --headless --path "E:\The City" --script res://tests/test_quality_price.gd
#
# Качество влияет на цену множителем: цена единицы = база × price_multiplier
# уровня, с округлением до целого числа монет. Проверки:
#
#  1. В qualities.json поле price_multiplier есть у всех уровней и растёт
#     по шкале качества; у обычного качества множитель 1.0, у неизвестного
#     уровня — тоже 1.0 (мягкий дефолт, старые данные не ломаются).
#  2. Разбивка цены целочисленная и сходится с множителем на ВСЕХ товарах
#     реестра, у которых есть цена: total == round(base × multiplier) и
#     total >= base (качество не удешевляет товар).
#  3. Формат строки тултипа — «Цена: 4 * 1.30 (★★) = 5»: целые база и итог,
#     множитель с двумя знаками, звёзды уровня. Контрольный пример
#     (товар с базовой ценой 4) сверяется с точной строкой. У обычного
#     качества и у товара без цены (science) строки нет.
#  4. Внутренний рынок: цена единицы растёт с качеством, а доход за
#     смешанный склад считается ПО КАЧЕСТВУ каждой списанной единицы
#     (10 обычных + 5 хороших НЕ равно 15 × цена обычного), пустая
#     разбивка — доход 0.
#  5. Средний множитель по складу (для планового дохода) — взвешенный по
#     разбивке city_quality_detail; без разбивки — 1.0.
#  6. Рендер тултипа качества: строка цены появляется под уровнями выше
#     обычного и не появляется под обычным.
#  7. Тултип СТРОКИ на вкладке «Ресурсы» (show_flow_tooltip): под базовой
#     строкой «Цена: N» выводится цена ТОЛЬКО для тех уровней выше
#     обычного, которые РЕАЛЬНО лежат на складе (разбивка
#     city_quality_detail), в том же формате, что и в тултипе звёзд:
#     «Цена: 4 * 1.30 (★★) = 5», по строке на уровень, от худшего к лучшему.
#     Уровней, которых на складе нет (в т.ч. при пустой разбивке), строк нет —
#     как и у товара без цены.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _failed := false

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	# Автозагрузки берём через дерево сцены: в режиме --script имена
	# GameData/CityData недоступны на этапе компиляции этого файла.
	# new_game() поднимает GameData.load_all_data() и CityData.setup().
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var gd = get_root().get_node("GameData")
	var city = get_root().get_node("CityData")

	var levels: Array = gd.get_quality_levels()
	check(levels.size() == 4, "ожидалось 4 уровня качества, получено %d" % levels.size())

	# --- 1. Поле price_multiplier: есть у всех, растёт по шкале ---
	var prev_mult := 0.0
	for qid in levels:
		var qd: Dictionary = gd.get_quality_data(qid)
		check(qd.has("price_multiplier"),
			"у уровня «%s» нет поля price_multiplier" % qid)
		var m := float(qd.get("price_multiplier", 0.0))
		check(m > prev_mult,
			"множитель уровня «%s» (%.2f) должен быть больше предыдущего (%.2f)"
			% [qid, m, prev_mult])
		prev_mult = m
	check(is_equal_approx(gd.get_quality_price_multiplier("common"), 1.0),
		"у обычного качества множитель должен быть 1.0")
	check(is_equal_approx(gd.get_quality_price_multiplier("no_such_quality"), 1.0),
		"для неизвестного уровня множитель должен быть 1.0 (мягкий дефолт)")

	# --- 2. Разбивка цены целочисленная и сходится на всех товарах ---
	var checked_prices := 0
	for pid in gd.products:
		if gd.get_base_price(pid) <= 0.0:
			continue
		checked_prices += 1
		for qid in levels:
			var d: Dictionary = gd.get_price_breakdown_for_quality(pid, qid)
			var base := int(d["base"])
			var total := int(d["total"])
			var mult := float(d["multiplier"])
			check(total == int(round(float(base) * mult)),
				"итоговая цена %s/%s не равна round(база × множитель)" % [pid, qid])
			# Неокруглённый хелпер и разбивка для тултипа должны сходиться
			# после округления — иначе тултип показывал бы одну цену, а
			# внутренний рынок платил бы по другой.
			check(int(round(gd.get_price_for_quality(pid, qid))) == total,
				"get_price_for_quality расходится с разбивкой цены (%s/%s)" % [pid, qid])
			check(total >= base,
				"качество не должно удешевлять товар (%s/%s: %d < %d)" % [pid, qid, total, base])
			if qid == "common":
				check(total == base,
					"у обычного качества итог должен совпадать с базой (%s)" % pid)
	check(checked_prices > 100,
		"проверено слишком мало товаров с ценой: %d" % checked_prices)


	# --- 3. Формат строки тултипа ---
	# Формат: «Цена: <целое> * <множитель с двумя знаками> (<звёзды>) = <целое>».
	var line_re := RegEx.new()
	var err := line_re.compile("^Цена: [0-9]+ \\* [0-9]+\\.[0-9]{2} \\(★+\\) = [0-9]+$")
	check(err == OK, "не скомпилировалась проверка формата строки: %d" % err)
	# Контрольный товар с базовой ценой 4 (в данных таких много).
	var sample_id := ""
	for pid in gd.products:
		if is_equal_approx(gd.get_base_price(pid), 4.0):
			sample_id = pid
			break
	check(sample_id != "", "в реестре нет товара с базовой ценой 4")
	for qid in levels:
		var line: String = gd.format_quality_price_line(sample_id, qid)
		if qid == "common":
			check(line == "", "у обычного качества строка цены не показывается")
			continue
		var d: Dictionary = gd.get_price_breakdown_for_quality(sample_id, qid)
		check(line_re.search(line) != null,
			"строка цены не по формату «Цена: X * M (★★) = A»: «%s»" % line)
		check(line.contains(" * %s " % "%.2f" % float(d["multiplier"])),
			"в строке должен быть множитель уровня: «%s»" % line)
		check(line.contains(gd.get_quality_stars(qid)),
			"в строке должны быть звёзды уровня: «%s»" % line)
		check(line.ends_with("= %d" % int(d["total"])),
			"в строке должен быть итог round(база × множитель): «%s»" % line)
	# Точный контрольный пример: цена 4, хорошее качество → 4 * 1.30 = 5.
	check(gd.format_quality_price_line(sample_id, "fine") == "Цена: 4 * 1.30 (★★) = 5",
		"контрольный пример: ожидалось «Цена: 4 * 1.30 (★★) = 5», получено «%s»"
		% gd.format_quality_price_line(sample_id, "fine"))
	# Товар без цены (псевдоресурс science) строки не даёт.
	check(gd.format_quality_price_line("science", "perfect") == "",
		"у товара без цены строка цены не показывается")
	check(gd.format_quality_price_line("", "fine") == "",
		"без id товара строка цены не показывается")

	# --- 4. Внутренний рынок: цена и доход по качеству ---
	var base_market: int = city.get_internal_market_price(sample_id)
	check(base_market > 0, "у контрольного товара должна быть рыночная цена")
	check(city.get_internal_market_price(sample_id, "common") == base_market,
		"обычное качество не должно менять цену внутреннего рынка")
	var fine_market: int = city.get_internal_market_price(sample_id, "fine")
	var perfect_market: int = city.get_internal_market_price(sample_id, "perfect")
	check(fine_market == int(round(float(base_market) * gd.get_quality_price_multiplier("fine"))),
		"цена хорошего качества не равна round(базовая рыночная × множитель)")
	check(perfect_market > fine_market and fine_market > base_market,
		"цена внутреннего рынка должна расти с качеством (%d / %d / %d)"
		% [base_market, fine_market, perfect_market])
	var mixed_income: int = city.get_internal_market_income(
		sample_id, {"common": 10, "fine": 5})
	check(mixed_income == 10 * base_market + 5 * fine_market,
		"доход за смешанный склад должен считаться по качеству каждой единицы: %d" % mixed_income)
	check(mixed_income > 15 * base_market,
		"смешанный склад должен приносить больше, чем 15 единиц обычного качества")
	check(city.get_internal_market_income(sample_id, {}) == 0,
		"пустая разбивка списанного — доход 0")

	# --- 5. Средний множитель по складу (для планового дохода) ---
	city.city_quality_detail[sample_id] = {"common": 10, "fine": 5}
	var expected_avg := (10.0 + 5.0 * float(gd.get_quality_price_multiplier("fine"))) / 15.0
	check(is_equal_approx(city.get_stock_quality_price_multiplier(sample_id), expected_avg),
		"средний множитель по складу должен быть взвешен по разбивке")
	city.city_quality_detail[sample_id] = {}
	check(is_equal_approx(city.get_stock_quality_price_multiplier(sample_id), 1.0),
		"без разбивки по качеству средний множитель должен быть 1.0")

	# --- 6. Рендер тултипа качества ---
	await _check_quality_tooltip_render(gd, sample_id)

	# --- 7. Рендер тултипа строки вкладки «Ресурсы» ---
	await _check_flow_tooltip_price_render(gd, sample_id)

	if _failed:
		print("FAIL")
		quit(1)
	else:
		print("QUALITY PRICE TEST OK")
		quit(0)

# Проверяет, что show_quality_tooltip под уровнями выше обычного рисует
# строку «  Цена: …», а под обычным — не рисует ничего.
func _check_quality_tooltip_render(gd, sample_id: String) -> void:
	var holder := Control.new()
	get_root().add_child(holder)
	var ui = load("res://scripts/ui_helpers.gd").new()
	ui.setup(holder, Label.new())
	holder.add_child(ui)
	await process_frame
	await process_frame

	ui.show_quality_tooltip(Vector2(50, 50), "Товар",
		{"common": 10, "fine": 5, "perfect": 2}, sample_id)
	await process_frame

	var price_lines: Array = []
	var quality_rows := 0
	for child in ui.quality_tooltip_vbox.get_children():
		# Строка уровня качества — HBoxContainer со звёздами и «Имя: N»,
		# строка цены — Label прямо в vbox.
		if child is HBoxContainer:
			quality_rows += 1
		elif child is Label and child.text.contains("Цена:"):
			price_lines.append(child.text)
	check(quality_rows == 3, "тултип должен показать 3 строки качества, показано %d" % quality_rows)
	check(price_lines.size() == 2,
		"строк цены должно быть 2 (fine и perfect), показано %d" % price_lines.size())
	var fine_line: String = "  " + gd.format_quality_price_line(sample_id, "fine")
	check(price_lines.has(fine_line),
		"под хорошим качеством ожидалась строка «%s», получено %s" % [fine_line, str(price_lines)])
	var perfect_line: String = "  " + gd.format_quality_price_line(sample_id, "perfect")
	check(price_lines.has(perfect_line),
		"под превосходным качеством ожидалась строка «%s», получено %s" % [perfect_line, str(price_lines)])

	# Без id товара строк цены нет вовсе (старый вызов без prod_id).
	ui.show_quality_tooltip(Vector2(50, 50), "Товар", {"common": 10, "fine": 5})
	await process_frame
	var lines_without_id := 0
	for child in ui.quality_tooltip_vbox.get_children():
		if child is Label and child.text.contains("Цена:"):
			lines_without_id += 1
	check(lines_without_id == 0,
		"без prod_id строк цены быть не должно, показано %d" % lines_without_id)

	holder.queue_free()

# Проверяет цены по качеству в тултипе СТРОКИ вкладки «Ресурсы»
# (ui_helpers.show_flow_tooltip): под базовой «Цена: N» идёт строка ТОЛЬКО для
# тех уровней выше обычного, которые РЕАЛЬНО лежат на складе (разбивка
# city_quality_detail). Уровней, которых на складе нет, строк быть не должно —
# показывать цену несуществующего на складе товара незачем.
func _check_flow_tooltip_price_render(gd, sample_id: String) -> void:


# Формат строки — тот же, что в тултипе звёзд (format_quality_price_line):
# «Цена: <целое> * <множитель с двумя знаками> (<звёзды>) = <целое>».
	var line_re := RegEx.new()
	var err := line_re.compile("^Цена: [0-9]+ \\* [0-9]+\\.[0-9]{2} \\(★+\\) = [0-9]+$")
	check(err == OK, "не скомпилировалась проверка формата строки: %d" % err)

	# Пустая разбивка (старый сейв или товар без качества) — ни одной строки.
	check(gd.format_quality_price_scale_lines(sample_id, {}).is_empty(),
		"при пустой разбивке строк цен по качеству быть не должно")
	check(gd.format_quality_price_scale_lines(sample_id).is_empty(),
		"без разбивки (аргумент по умолчанию) строк быть не должно")

	# Только обычное качество на складе — блока нет: цена обычного уровня уже
	# показана базовой строкой «Цена: N» над блоком.
	check(gd.format_quality_price_scale_lines(sample_id, {"common": 40}).is_empty(),
		"при одном лишь обычном качестве строк быть не должно")

	# Хорошее + превосходное: показаны РОВНО эти два уровня, исключительного
	# (которого на складе нет) — нет. Порядок — от худшего к лучшему.
	var breakdown := {"common": 40, "fine": 12, "perfect": 3}
	var lines: Array = gd.format_quality_price_scale_lines(sample_id, breakdown)
	check(lines.size() == 2,
		"строк должно быть 2 (fine и perfect), показано %d: %s"
		% [lines.size(), str(lines)])
	# Строки совпадают с тем, что даёт тултип звёзд для того же уровня: блок в
	# тултипе строки собран той же функцией format_quality_price_line, поэтому
	# сравниваем посимвольно с её результатом.
	var fine_expected: String = gd.format_quality_price_line(sample_id, "fine")
	var perfect_expected: String = gd.format_quality_price_line(sample_id, "perfect")
	check(str(lines[0]) == fine_expected,
		"строка хорошего уровня должна совпадать со строкой тултипа звёзд: «%s» вместо «%s»"
		% [str(lines[0]), fine_expected])
	check(str(lines[1]) == perfect_expected,
		"строка превосходного уровня не совпала с расчётной: «%s» вместо «%s»"
		% [str(lines[1]), perfect_expected])
	check(line_re.search(str(lines[0])) != null
			and line_re.search(str(lines[1])) != null,
		"строки не по формату тултипа звёзд «Цена: X * M (★★) = A»: %s" % str(lines))
	# Исключительного (★★★) на складе нет. Проверять через подстроку звёзд
	# нельзя: «★★★» входит в «★★★★», поэтому сверяем строки целиком.
	var exceptional_line: String = gd.format_quality_price_line(sample_id, "exceptional")
	check(exceptional_line != "" and not lines.has(exceptional_line),
		"строки уровня, которого нет на складе (исключительное), быть не должно: %s"
		% str(lines))
	# Множители уровней различаются — иначе сравнение строк не значимо.
	var perfect_d: Dictionary = gd.get_price_breakdown_for_quality(sample_id, "perfect")
	check(perfect_d["multiplier"] != gd.get_quality_price_multiplier("fine"),
		"множители уровней должны различаться — иначе проверка строк не значима")

	# Количество нулевое — уровень считается отсутствующим (такое возможно при
	# рассинхроне разбивки и запаса в старом сейве).
	check(gd.format_quality_price_scale_lines(sample_id, {"fine": 0}).is_empty(),
		"при count == 0 строка показываться не должна")

	# Рендер: строки лестницы подставляются в тултип строки (отступ 2 пробела),
	# а товар без разбивки и без цены не даёт ни одной строки.
	var holder := Control.new()
	get_root().add_child(holder)
	var ui = load("res://scripts/ui_helpers.gd").new()
	ui.setup(holder, Label.new())
	holder.add_child(ui)
	await process_frame
	await process_frame

	ui.show_flow_tooltip(Vector2(50, 50), "Товар", {}, sample_id, {}, {}, breakdown)
	await process_frame

	var base_line := ""
	var scale_lines: Array = []
	for child in ui.flow_tooltip_vbox.get_children():
		if not (child is Label):
			continue
		if child.text.begins_with("Цена: "):
			base_line = child.text
		elif child.text.begins_with("  Цена: "):
			scale_lines.append(child.text)
	check(base_line == "Цена: %d" % int(round(gd.get_price(sample_id))),
		"в тултипе строки должна быть базовая цена, получено «%s»" % base_line)
	check(scale_lines.size() == 2,
		"в тултипе строки должно быть 2 строки (только уровни со склада), показано %d: %s"
		% [scale_lines.size(), str(scale_lines)])
	for i in range(mini(scale_lines.size(), lines.size())):
		check(str(scale_lines[i]) == "  " + str(lines[i]),
			"строка №%d в тултипе не совпала с расчётной: «%s» вместо «%s»"
			% [i, str(scale_lines[i]), "  " + str(lines[i])])

	# Пустая разбивка: блока цен по качеству нет вовсе.
	ui.show_flow_tooltip(Vector2(50, 50), "Товар", {}, sample_id, {}, {}, {})
	await process_frame
	check(_count_scale_lines(ui) == 0,
		"при пустой разбивке в тултипе не должно быть строк по качеству")

	# Товар без цены (science): строк нет даже с непустой разбивкой.
	ui.show_flow_tooltip(Vector2(50, 50), "Наука", {}, "science", {}, {},
		{"common": 10, "perfect": 2})
	await process_frame
	check(_count_scale_lines(ui) == 0,
		"у товара без цены строк по качеству быть не должно")

	holder.queue_free()
# Считает строки цен по качеству в тултипе строки. Отступ 2 пробела —
# отличает их от базовой «Цена: N», у которой отступа нет.
func _count_scale_lines(ui) -> int:
	var result := 0
	for child in ui.flow_tooltip_vbox.get_children():
		if child is Label and child.text.begins_with("  Цена: "):
			result += 1
	return result

func check(cond: bool, msg: String):
	if cond:
		return
	_failed = true
	print("FAIL: %s" % msg)
