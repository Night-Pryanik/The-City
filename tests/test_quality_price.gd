# Headless-тест отображения качества: цена, цвет и доля уровня
# (data/qualities.json: price_multiplier, color).
#   godot --headless --path . --script res://tests/test_quality_price.gd
#
# Качество влияет на цену множителем: цена единицы = база × price_multiplier
# уровня, с округлением до целого числа монет. Проверки:
#
#  1. Поля price_multiplier и color: множитель есть у всех уровней и растёт
#     по шкале качества (у обычного 1.0, у неизвестного уровня тоже 1.0 —
#     мягкий дефолт); цвет задан у всех уровней массивом [R, G, B] 0…255,
#     у уровней разный, get_quality_color отдаёт цвет из данных, а для
#     неизвестного уровня — светло-серый дефолт.
#  2. Доля уровня на складе: get_quality_share_percent считает процент от
#     ОБЩЕГО количества (а не долю лучшего уровня от остальных);
#     format_quality_share_text собирает «(33%/67%)» — по одному проценту на
#     присутствующий уровень, от худшего к лучшему, каждый в своём цвете
#     (BBCode). Пустая разбивка — пустая строка.
#  3. Разбивка цены целочисленная и сходится с множителем на ВСЕХ товарах
#     реестра, у которых есть цена: total == round(base × multiplier) и
#     total >= base (качество не удешевляет товар).
#  4. Формат строки цены уровня — «★★ = x1.30 = 5»: множитель с двумя
#     знаками после x, итог целый, строка собирается для ЛЮБОГО уровня шкалы,
#     включая обычное («★ = x1.00 = 4»). Строка склеивается из звёзд уровня и
#     хвоста « = x1.30 = 5» (format_quality_price_tail), потому что тултип
#     красит их разными цветами. Контрольный пример (товар с базовой ценой 4)
#     сверяется с точной строкой. У товара без цены (science), без id и у
#     несуществующего уровня строки нет.
#  5. Внутренний рынок: цена единицы растёт с качеством, а доход за
#     смешанный склад считается ПО КАЧЕСТВУ каждой списанной единицы
#     (10 обычных + 5 хороших НЕ равно 15 × цена обычного), пустая
#     разбивка — доход 0.
#  6. Средний множитель по складу (для планового дохода) — взвешенный по
#     разбивке city_quality_detail; без разбивки — 1.0.
#  7. Рендер тултипа качества (show_quality_tooltip): заголовок
#     «Уровни качества ресурса: N», строки уровней «★★ Хорошее: 5 (30%)» с
#     количеством и долей, звёзды в цвете уровня. Цен в нём нет вовсе:
#     полный список цен живёт в тултипе строки.
#  8. Тултип СТРОКИ на вкладке «Ресурсы» (show_flow_tooltip): под базовой
#     строкой «Цена: N» (золотой) идёт лестница «★★ = x1.30 = 5» по ВСЕМ
#     уровням, которые РЕАЛЬНО лежат на складе (разбивка
#     city_quality_detail), от худшего к лучшему. Строка лестницы ДВУХЦВЕТНАЯ:
#     звёзды — в цвете своего уровня (data/qualities.json), расчёт цены —
#     золотым (ui_helpers.PRICE_TEXT_COLOR); обе части совпадают с
#     format_quality_price_scale_rows и не схлопнуты по ширине. Уровней,
#     которых на складе нет (в т.ч. при пустой разбивке), строк нет — как и
#     у товара без цены.
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

	# Поле color: у всех уровней задан массивом [R, G, B] в диапазоне
	# 0…255 (та же форма, что у покрытий/улучшений/ресурсов), цвета уровней
	# попарно разные — иначе строки разбивки и тултипы не отличить друг от
	# друга, — а get_quality_color отдаёт ровно цвет из данных.
	var seen_colors := {}
	for qid in levels:
		var qd_color = gd.get_quality_data(qid).get("color", null)
		check(qd_color is Array and qd_color.size() == 3,
			"у уровня «%s» нет поля color в виде массива [R, G, B]: %s" % [qid, str(qd_color)])
		if not (qd_color is Array and qd_color.size() == 3):
			continue
		for comp in qd_color:
			check(float(comp) >= 0.0 and float(comp) <= 255.0,
				"компонента цвета уровня «%s» вне диапазона 0…255: %s" % [qid, str(comp)])
		var hex: String = gd.get_quality_color(qid).to_html(false)
		check(hex == "%02x%02x%02x" % [int(qd_color[0]), int(qd_color[1]), int(qd_color[2])],
			"get_quality_color должен отдавать цвет из данных уровня «%s»: %s вместо %02x%02x%02x"
			% [qid, hex, int(qd_color[0]), int(qd_color[1]), int(qd_color[2])])
		check(not seen_colors.has(hex),
			"цвет уровня «%s» совпал с цветом уровня «%s» (%s) — уровни должны различаться цветом"
			% [qid, str(seen_colors.get(hex, "")), hex])
		seen_colors[hex] = qid
	# Мягкий дефолт для уровня без поля color: неизвестный id и пустая строка
	# рисуются светло-серым (продублировано GameData.QUALITY_COLOR_FALLBACK).
	check(gd.get_quality_color("no_such_quality") == Color(0.8, 0.8, 0.8),
		"для неизвестного уровня цвет должен быть светло-серым дефолтом")
	check(gd.get_quality_color("") == Color(0.8, 0.8, 0.8),
		"для пустого id уровня цвет должен быть светло-серым дефолтом")

	# --- 2. Доля уровня на складе: проценты и строка разбивки ---
	# Проценты считаются от ОБЩЕГО количества товара: разбивка 30/10/60 даёт
	# 30/10/60 процентов, а не «доли от лучшего уровня» (тогда получилось бы
	# 100/33/200 — именно это и показывала строка списка до переделки).
	var share_breakdown := {"common": 30, "fine": 10, "perfect": 60}
	check(gd.get_quality_share_percent(30, share_breakdown) == 30,
		"доля обычного уровня (30 из 100) должна быть 30 процентов")
	check(gd.get_quality_share_percent(10, share_breakdown) == 10,
		"доля хорошего уровня (10 из 100) должна быть 10 процентов")
	check(gd.get_quality_share_percent(60, share_breakdown) == 60,
		"доля превосходного уровня (60 из 100) должна быть 60 процентов")
	check(gd.get_quality_share_percent(5, {}) == 0,
		"на пустой разбивке доля должна быть 0")
	check(gd.get_quality_share_percent(0, {"common": 0}) == 0,
		"на нулевой разбивке доля должна быть 0")
	# Сумма долей — около 100%: проценты округляются по отдельности, и
	# «допиливать» их до ровных 100% было бы враньём о дробных долях.
	var share_sum := 0
	for qid in share_breakdown:
		share_sum += gd.get_quality_share_percent(int(share_breakdown[qid]), share_breakdown)
	check(abs(share_sum - 100) <= 1,
		"сумма долей по разбивке должна быть около 100%%, получено %d" % share_sum)

	# Строка разбивки для строки списка: по одному проценту на присутствующий
	# уровень, от худшего к лучшему, каждый обёрнут в BBCode-цвет своего
	# уровня: «(30%/10%/60%)» с «[color=#a0a0a0]30%[/color]» и так далее.
	# Сверяем строкой целиком — так проверяются сразу и порядок уровней, и их
	# проценты, и цвета. Регулярное выражение здесь не используется намеренно:
	# шаблон с '#' внутри (это тег цвета BBCode) в этой сборке Godot ведёт себя
	# неочевидно, а точное сравнение проверяет строго.
	var share_order := ["common", "fine", "perfect"]
	var share_parts: Array = []
	for qid in share_order:
		share_parts.append("[color=#%s]%d%%[/color]" % [
			gd.get_quality_color(qid).to_html(false),
			gd.get_quality_share_percent(int(share_breakdown[qid]), share_breakdown)])
	var share_text: String = gd.format_quality_share_text(share_breakdown)
	check(share_text == "(%s)" % "/".join(share_parts),
		"строка разбивки должна быть «(%s)», получено «%s»"
		% ["/".join(share_parts), share_text])
	# Уровня, которого на складе нет (исключительное), в строке быть не должно.
	check(not share_text.contains(gd.get_quality_color("exceptional").to_html(false)),
		"уровня, которого нет на складе (исключительное), в строке разбивки быть не должно: «%s»"
		% share_text)
	# Только обычное качество на складе — «(100%)»; пустая и нулевая разбивка —
	# пустая строка (метка списка по ней прячется).
	var single_share: String = gd.format_quality_share_text({"common": 40})
	check(single_share.contains("100%"),
		"разбивка только из обычного качества должна дать «(100%%)»: «%s»" % single_share)
	check(gd.format_quality_share_text({}).is_empty(),
		"на пустой разбивке строка разбивки должна быть пустой")
	check(gd.format_quality_share_text({"fine": 0}).is_empty(),
		"на разбивке из нулей строка разбивки должна быть пустой")

	# --- 3. Разбивка цены целочисленная и сходится на всех товарах ---
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


	# --- 4. Формат строки цены уровня ---
	# Формат: «★ = x1.00 = 4» / «★★ = x1.30 = 5» — звёзды уровня, множитель с
	# двумя знаками после x и целый итог. Строится для ЛЮБОГО уровня шкалы,
	# включая самый низкий: раньше он отбрасывался, и у склада, где лежит
	# только обычное качество, лестницы не было вовсе.
	var line_re := RegEx.new()
	var err := line_re.compile("^★+ = x[0-9]+\\.[0-9]{2} = [0-9]+$")
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
		var d: Dictionary = gd.get_price_breakdown_for_quality(sample_id, qid)
		check(line_re.search(line) != null,
			"строка цены не по формату «★★ = x1.30 = 5»: «%s»" % line)
		check(line.begins_with(gd.get_quality_stars(qid) + " = "),
			"строка должна начинаться со звёзд уровня: «%s»" % line)
		check(line.contains("= x%s =" % "%.2f" % float(d["multiplier"])),
			"в строке должен быть множитель уровня: «%s»" % line)
		check(line.ends_with("= %d" % int(d["total"])),
			"в строке должен быть итог round(база × множитель): «%s»" % line)
		# Нижний уровень шкалы — не исключение: множитель 1.0 тоже показываем.
		check(line != "", "у уровня «%s» строка цены не должна быть пустой" % qid)
	# Хвост строки — всё, КРОМЕ звёзд (« = x1.30 = 5»): именно его тултип строки
	# красит золотым, а звёзды — в цвет уровня. Формат хвоста проверяется
	# отдельно, и строка целиком обязана собираться из звёзд и хвоста без
	# единого разночтения — иначе покрашенные части разъедутся с текстом.
	var tail_re := RegEx.new()
	var tail_err := tail_re.compile("^ = x[0-9]+\\.[0-9]{2} = [0-9]+$")
	check(tail_err == OK, "не скомпилировалась проверка формата хвоста: %d" % tail_err)
	for qid in levels:
		var tail: String = gd.format_quality_price_tail(sample_id, qid)
		var q_line: String = gd.format_quality_price_line(sample_id, qid)
		check(tail_re.search(tail) != null,
			"хвост строки цены не по формату « = x1.30 = 5»: «%s»" % tail)
		check(q_line == gd.get_quality_stars(qid) + tail,
			"строка должна собираться из звёзд и хвоста: «%s» вместо «%s%s»"
			% [q_line, gd.get_quality_stars(qid), tail])
	check(gd.format_quality_price_tail(sample_id, "fine") == " = x1.30 = 5",
		"контрольный пример хвоста хорошего уровня: «%s»"
		% gd.format_quality_price_tail(sample_id, "fine"))
	check(gd.format_quality_price_tail(sample_id, "exceptional") == " = x1.75 = 7",
		"контрольный пример хвоста исключительного уровня (4 × 1.75 = 7): «%s»"
		% gd.format_quality_price_tail(sample_id, "exceptional"))
	check(gd.format_quality_price_tail("science", "perfect") == "",
		"у товара без цены хвост не показывается")
	check(gd.format_quality_price_tail(sample_id, "no_such_quality") == "",
		"у несуществующего уровня хвост не показывается")
	# Точные контрольные примеры: цена 4, обычное/хорошее/превосходное.
	check(gd.format_quality_price_line(sample_id, "common") == "★ = x1.00 = 4",
		"контрольный пример обычного уровня: ожидалось «★ = x1.00 = 4», получено «%s»"
		% gd.format_quality_price_line(sample_id, "common"))
	check(gd.format_quality_price_line(sample_id, "fine") == "★★ = x1.30 = 5",
		"контрольный пример хорошего уровня: ожидалось «★★ = x1.30 = 5», получено «%s»"
		% gd.format_quality_price_line(sample_id, "fine"))
	check(gd.format_quality_price_line(sample_id, "perfect") == "★★★★ = x2.30 = 9",
		"контрольный пример превосходного уровня: ожидалось «★★★★ = x2.30 = 9», получено «%s»"
		% gd.format_quality_price_line(sample_id, "perfect"))
	# Товар без цены (псевдоресурс science) строки не даёт.
	check(gd.format_quality_price_line("science", "perfect") == "",
		"у товара без цены строка цены не показывается")
	check(gd.format_quality_price_line("", "fine") == "",
		"без id товара строка цены не показывается")
	# Уровня нет в шкале — показывать нечего: без звёзд строку не собрать.
	check(gd.format_quality_price_line(sample_id, "no_such_quality") == "",
		"у несуществующего уровня строка цены не показывается")
	check(gd.format_quality_price_line(sample_id, "") == "",
		"у пустого уровня строка цены не показывается")

	# --- 5. Внутренний рынок: цена и доход по качеству ---
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

	# --- 6. Средний множитель по складу (для планового дохода) ---
	city.city_quality_detail[sample_id] = {"common": 10, "fine": 5}
	var expected_avg := (10.0 + 5.0 * float(gd.get_quality_price_multiplier("fine"))) / 15.0
	check(is_equal_approx(city.get_stock_quality_price_multiplier(sample_id), expected_avg),
		"средний множитель по складу должен быть взвешен по разбивке")
	city.city_quality_detail[sample_id] = {}
	check(is_equal_approx(city.get_stock_quality_price_multiplier(sample_id), 1.0),
		"без разбивки по качеству средний множитель должен быть 1.0")

	# --- 7. Рендер тултипа качества ---
	await _check_quality_tooltip_render(gd)

	# --- 8. Рендер тултипа строки вкладки «Ресурсы» ---
	await _check_flow_tooltip_price_render(gd, sample_id)

	if _failed:
		print("FAIL")
		quit(1)
	else:
		print("QUALITY PRICE TEST OK")
		quit(0)

# Проверяет тултип разбора качества (show_quality_tooltip): заголовок
# «Уровни качества ресурса: N», строки уровней «★★ Хорошее: 5 (29%)» с
# количеством и долей, звёзды в цвете уровня — и ни одной строки цены:
# полный список цен живёт в тултипе строки (см. _check_flow_tooltip_price_render).
func _check_quality_tooltip_render(gd) -> void:
	var holder := Control.new()
	get_root().add_child(holder)
	var ui = load("res://scripts/ui_helpers.gd").new()
	ui.setup(holder, Label.new())
	holder.add_child(ui)
	await process_frame
	await process_frame

	var breakdown := {"common": 10, "fine": 5, "perfect": 2}
	ui.show_quality_tooltip(Vector2(50, 50), "Товар", breakdown)
	await process_frame

	var header_text := ""
	var level_texts: Array = []
	var star_colors: Array = []
	var header_labels := 0
	for child in ui.quality_tooltip_vbox.get_children():
		# Строка уровня качества — HBoxContainer: первый потомок звёзды,
		# второй «Имя: N (P%)». Кроме заголовка Label-строк в тултипе быть
		# не должно: раньше под каждым уровнем рисовалась «  Цена: …».
		if child is HBoxContainer:
			var stars_label := child.get_child(0) as Label
			var name_label := child.get_child(1) as Label
			level_texts.append(str(name_label.text))
			star_colors.append(stars_label.get_theme_color("font_color"))
		elif child is Label:
			header_text = str((child as Label).text)
			header_labels += 1
	check(header_text == "Уровни качества ресурса: Товар",
		"заголовок тултипа качества должен быть «Уровни качества ресурса: Товар», получено «%s»"
		% header_text)
	check(header_labels == 1,
		"в тултипе качества должен быть только заголовок (Label-строк: %d) — цен в нём нет"
		% header_labels)
	check(level_texts.size() == 3,
		"тултип должен показать 3 строки качества, показано %d" % level_texts.size())

	# Строки уровней — от худшего к лучшему: количество и доля от общего
	# количества товара (10 + 5 + 2 = 17 → 59% / 29% / 12%).
	var expected_order := ["common", "fine", "perfect"]
	for i in range(mini(level_texts.size(), expected_order.size())):
		var qid: String = expected_order[i]
		var count := int(breakdown[qid])
		var expected_text := "%s: %d (%d%%)" % [
			gd.get_quality_name(qid), count,
			gd.get_quality_share_percent(count, breakdown)]
		check(str(level_texts[i]) == expected_text,
			"строка уровня №%d должна быть «%s», получено «%s»"
			% [i, expected_text, str(level_texts[i])])
		# Звёзды строки покрашены в цвет уровня (data/qualities.json, color).
		check(star_colors[i] == gd.get_quality_color(qid),
			"звёзды уровня «%s» должны быть в его цвете: %s вместо %s"
			% [qid, str(star_colors[i]), str(gd.get_quality_color(qid))])
	# Сумма показанных долей — около 100%: доли берутся от общего количества,
	# а не от лучшего уровня (тогда вышло бы 100% / 29% / 12% + «превосходных
	# больше, чем всех остальных»).
	var pct_sum := 0
	for qid in breakdown:
		pct_sum += gd.get_quality_share_percent(int(breakdown[qid]), breakdown)
	check(abs(pct_sum - 100) <= 1,
		"сумма долей в тултипе должна быть около 100%%, получено %d" % pct_sum)

	# Пустая разбивка — остаётся только заголовок: строк уровней нет.
	ui.show_quality_tooltip(Vector2(50, 50), "Товар", {})
	await process_frame
	var rows_empty := 0
	for child in ui.quality_tooltip_vbox.get_children():
		if child is HBoxContainer:
			rows_empty += 1
	check(rows_empty == 0,
		"при пустой разбивке строк уровней быть не должно, показано %d" % rows_empty)

	holder.queue_free()

# Проверяет лестницу цен по качеству в тултипе СТРОКИ вкладки «Ресурсы»
# (ui_helpers.show_flow_tooltip): под базовой «Цена: N» идёт строка на каждый
# уровень, который РЕАЛЬНО лежит на складе (разбивка city_quality_detail), в
# формате «★★ = x1.30 = 5» и в цвете своего уровня. Уровней, которых на
# складе нет, строк быть не должно — показывать цену несуществующего на
# складе товара незачем.
func _check_flow_tooltip_price_render(gd, sample_id: String) -> void:
	# Формат строки лестницы — тот же, что у format_quality_price_line.
	var line_re := RegEx.new()
	var err := line_re.compile("^★+ = x[0-9]+\\.[0-9]{2} = [0-9]+$")
	check(err == OK, "не скомпилировалась проверка формата строки: %d" % err)

	# Пустая разбивка (старый сейв или товар без качества) — ни одной строки.
	check(gd.format_quality_price_scale_rows(sample_id, {}).is_empty(),
		"при пустой разбивке строк цен по качеству быть не должно")
	check(gd.format_quality_price_scale_rows(sample_id).is_empty(),
		"без разбивки (аргумент по умолчанию) строк быть не должно")

	# Только обычное качество на складе: строка ЕСТЬ («★ = x1.00 = 4»). Раньше
	# нижний уровень шкалы отбрасывался, и у такого склада блока не было.
	var common_only: Array = gd.format_quality_price_scale_rows(sample_id, {"common": 40})
	check(common_only.size() == 1
			and str((common_only[0] as Dictionary)["qid"]) == "common",
		"при одном лишь обычном качестве должна быть ровно одна строка уровня common: %s"
		% str(common_only))

	# Все три уровня на складе: показаны РОВНО они, исключительного (которого
	# на складе нет) — нет. Порядок — от худшего к лучшему.
	var breakdown := {"common": 40, "fine": 12, "perfect": 3}
	var rows: Array = gd.format_quality_price_scale_rows(sample_id, breakdown)
	check(rows.size() == 3,
		"строк должно быть 3 (common, fine, perfect), показано %d: %s"
		% [rows.size(), str(rows)])
	var expected_order := ["common", "fine", "perfect"]
	for i in range(mini(rows.size(), expected_order.size())):
		var qid: String = expected_order[i]
		var row: Dictionary = rows[i]
		check(str(row["qid"]) == qid,
			"строка №%d должна быть уровня «%s», показано «%s»" % [i, qid, str(row["qid"])])
		# Строка совпадает с тем, что даёт format_quality_price_line: блок
		# собран той же функцией, поэтому сверяем посимвольно.
		check(str(row["text"]) == gd.format_quality_price_line(sample_id, qid),
			"строка №%d не совпала с расчётной: «%s» вместо «%s»"
			% [i, str(row["text"]), gd.format_quality_price_line(sample_id, qid)])
		check(line_re.search(str(row["text"])) != null,
			"строка №%d не по формату лестницы «★★ = x1.30 = 5»: «%s»" % [i, str(row["text"])])
		# Части строки отдаются ОТДЕЛЬНО: тултип красит звёзды в цвет уровня, а
		# хвост расчёта — золотым, и обе части обязаны в точности сходиться с
		# готовой строкой (иначе подсвеченное не совпадёт с текстом).
		check(str(row["stars"]) == gd.get_quality_stars(qid),
			"звёзды строки №%d должны быть звёздами уровня «%s»: «%s» вместо «%s»"
			% [i, qid, str(row["stars"]), gd.get_quality_stars(qid)])
		check(str(row["tail"]) == gd.format_quality_price_tail(sample_id, qid),
			"хвост строки №%d не совпал с расчётным: «%s» вместо «%s»"
			% [i, str(row["tail"]), gd.format_quality_price_tail(sample_id, qid)])
		check(str(row["text"]) == str(row["stars"]) + str(row["tail"]),
			"строка №%d должна склеиваться из звёзд и хвоста: «%s»" % [i, str(row["text"])])
	# Исключительного (★★★) на складе нет. Проверять по подстроке звёзд
	# нельзя: «★★★» входит в «★★★★», поэтому сверяем id уровня в строке.
	var has_exceptional := false
	for row in rows:
		if str((row as Dictionary)["qid"]) == "exceptional":
			has_exceptional = true
	check(not has_exceptional,
		"строки уровня, которого нет на складе (исключительное), быть не должно: %s" % str(rows))
	# Множители уровней различаются — иначе сравнение строк не значимо.
	var perfect_d: Dictionary = gd.get_price_breakdown_for_quality(sample_id, "perfect")
	check(perfect_d["multiplier"] != gd.get_quality_price_multiplier("fine"),
		"множители уровней должны различаться — иначе проверка строк не значима")

	# Количество нулевое — уровень считается отсутствующим (такое возможно при
	# рассинхроне разбивки и запаса в старом сейве).
	check(gd.format_quality_price_scale_rows(sample_id, {"fine": 0}).is_empty(),
		"при count == 0 строка показываться не должна")

	# Рендер: строки лестницы подставляются в тултип строки с отступом 2
	# пробела; звёзды в них — в цвете своего уровня, а расчёт цены — золотым.
	# Товар без разбивки и без цены не даёт ни одной строки.
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
	var scale_stars: Array = []
	var scale_tails: Array = []
	for child in ui.flow_tooltip_vbox.get_children():
		if child is Label:
			var label := child as Label
			if label.text.begins_with("Цена: "):
				base_line = label.text
		elif child is HBoxContainer and child.get_child_count() == 2:
			# Строка лестницы — HBox из двух Label: звёзды в цвете уровня и
			# золотой хвост расчёта цены.
			var stars_label := child.get_child(0) as Label
			var tail_label := child.get_child(1) as Label
			if stars_label == null or tail_label == null:
				continue
			if not str(stars_label.text).begins_with("  ★"):
				continue
			scale_stars.append({
				"text": str(stars_label.text),
				"color": stars_label.get_theme_color("font_color"),
				"width": stars_label.size.x,
			})
			scale_tails.append({
				"text": str(tail_label.text),
				"color": tail_label.get_theme_color("font_color"),
				"width": tail_label.size.x,
			})
	check(base_line == "Цена: %d" % int(round(gd.get_price(sample_id))),
		"в тултипе строки должна быть базовая цена, получено «%s»" % base_line)
	check(scale_stars.size() == 3,
		"в тултипе строки должно быть 3 строки (только уровни со склада), показано %d: %s"
		% [scale_stars.size(), str(scale_stars)])
	# Порядок строк и их текст — как у format_quality_price_scale_rows. Звёзды
	# покрашены в цвет СВОЕГО уровня (data/qualities.json), а сам расчёт цены —
	# золотым (ui_helpers.PRICE_TEXT_COLOR).
	for i in range(mini(scale_stars.size(), rows.size())):
		var qid: String = expected_order[i]
		var row: Dictionary = rows[i]
		var stars_cell: Dictionary = scale_stars[i]
		var tail_cell: Dictionary = scale_tails[i]
		check(str(stars_cell["text"]) == "  " + str(row["stars"]),
			"звёзды строки №%d не совпали с расчётными: «%s» вместо «%s»"
			% [i, str(stars_cell["text"]), "  " + str(row["stars"])])
		check(str(tail_cell["text"]) == str(row["tail"]),
			"расчёт цены строки №%d не совпал с расчётным: «%s» вместо «%s»"
			% [i, str(tail_cell["text"]), str(row["tail"])])
		check(stars_cell["color"] == gd.get_quality_color(qid),
			"звёзды строки №%d («%s») должны быть в цвете уровня «%s»: %s вместо %s"
			% [i, str(stars_cell["text"]), qid, str(stars_cell["color"]),
				str(gd.get_quality_color(qid))])
		check(tail_cell["color"] == ui.PRICE_TEXT_COLOR,
			"расчёт цены строки №%d («%s») должен быть золотым: %s вместо %s"
			% [i, str(tail_cell["text"]), str(tail_cell["color"]), str(ui.PRICE_TEXT_COLOR)])
		# Ни одна часть строки не схлопнулась по ширине.
		check(float(stars_cell["width"]) > 5.0 and float(tail_cell["width"]) > 20.0,
			"строка №%d схлопнулась по ширине (звёзды %s px, расчёт %s px)"
			% [i, str(stars_cell["width"]), str(tail_cell["width"])])
	# Цвет звёзд и золотой расчёт различаются хотя бы там, где это видно глазом:
	# иначе «звёзды в цвете уровня» ничего бы не значило.
	var fine_stars: Dictionary = scale_stars[1] if scale_stars.size() > 1 else {}
	check(fine_stars.get("color", Color.BLACK) != ui.PRICE_TEXT_COLOR,
		"звёзды уровня не должны совпадать по цвету с золотым расчётом цены")
	# Панель тултипа не схлопнулась: её ширина считается по минимальному размеру
	# содержимого, поэтому узкая панель = узкие строки внутри.
	check(ui.flow_tooltip_panel.size.x > 100.0,
		"панель тултипа строки схлопнулась по ширине: %s" % str(ui.flow_tooltip_panel.size))

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

# Считает строки лестницы цен по качеству в тултипе строки. Отступ 2 пробела
# отличает их от базовой «Цена: N», у которой отступа нет.
func _count_scale_lines(ui) -> int:
	var result := 0
	for child in ui.flow_tooltip_vbox.get_children():
		# Строка лестницы — HBox из двух Label, первый из них «  ★…» (второй —
		# золотой хвост расчёта). Отступ 2 пробела отличает лестницу от
		# базовой «Цена: N», у которой отступа нет.
		if not (child is HBoxContainer) or child.get_child_count() != 2:
			continue
		var stars_label := child.get_child(0) as Label
		if stars_label != null and str(stars_label.text).begins_with("  ★"):
			result += 1
	return result

func check(cond: bool, msg: String):
	if cond:
		return
	_failed = true
	print("FAIL: %s" % msg)
