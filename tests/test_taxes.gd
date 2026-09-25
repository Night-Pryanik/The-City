# Headless-тест налогов населения (подушный налог в казну):
#   godot --headless --path "E:\The City" --script res://tools/test_taxes.gd
#
# Каждый житель платит в казну базовый налог (base_tax_per_citizen из
# data/game_balance.json) за КАЖДЫЙ тик симуляции. Проверки:
#
#   1. Ставка читается из data/game_balance.json и равна 2;
#      CityData.get_base_tax_per_citizen() возвращает ту же ставку.
#   2. Доход за тик = ставка × население (CityData.get_tax_income_per_tick).
#   3. collect_taxes() кладёт в казну ровно ставка × население и пишет
#      источник в ПЛОСКИЙ накопитель разбивки (CityData.TAX_INCOME_SOURCE).
#   4. Платить некому (население 0) — no-op: казна не меняется.
#   5. Живой тик: do_tick() увеличивает казну на налог (+ доход внутреннего
#      рынка, который измеряется отдельно по продуктовому накопителю).
#   6. Разбивка казны (worker_manager): тип «Налоги» — «плоский»
#      (CityData.TREASURY_FLAT_TYPE_KEY) с rate = ставка × население и
#      label = «2 × 3 чел.»; налог виден и когда рыночного дохода ещё нет.
#   7. Рендер тултипа (ui_helpers.show_treasury_tooltip): одна строка
#      «• Налоги: 2 × 3 чел. = 6 / сек», итог секции прибыли учитывает налог.
extends SceneTree

func _initialize():
	_run()

func _run() -> void:
	var state = {"failed": false}

	# Автозагрузки берём через дерево сцены: в режиме --script имена
	# GameData/CityData недоступны на этапе компиляции этого файла.
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var city = get_root().get_node("CityData")
	var gdata = get_root().get_node("GameData")

	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame

	check(main_map.tile_data.size() == main_map.map_rows,
			"карта не инициализирована (tile_data пуст)", state)

	# --- 1. Ставка из data/game_balance.json ---
	var base_tax: int = int(gdata.game_balance.get("base_tax_per_citizen", -1))
	check(base_tax > 0, "base_tax_per_citizen должен быть > 0 в game_balance.json", state)
	check(base_tax == 2, "base_tax_per_citizen: ожидалось 2, получено %d" % base_tax, state)
	check(city.get_base_tax_per_citizen() == base_tax,
			"get_base_tax_per_citizen() должен читать ставку из game_balance.json", state)

	# --- 2. Доход за тик = ставка × население ---
	city.total_population = 1
	check(city.get_tax_income_per_tick() == base_tax,
			"при 1 жителе налог за тик должен быть %d" % base_tax, state)
	city.total_population = 3
	check(city.get_tax_income_per_tick() == base_tax * 3,
			"при 3 жителях налог за тик должен быть %d" % (base_tax * 3), state)

	# --- 3. collect_taxes(): казна ровно на налог + запись в разбивку ---
	city.treasury = 0
	city.treasury_income_accum.clear()
	city.treasury_income_product_accum.clear()
	var collected: int = city.collect_taxes()
	check(collected == base_tax * 3,
			"collect_taxes() вернул %d, ожидалось %d" % [collected, base_tax * 3], state)
	check(city.treasury == base_tax * 3,
			"казна после сбора: ожидалось %d, получено %d" % [base_tax * 3, city.treasury], state)
	check(int(city.treasury_income_accum.get(city.TAX_INCOME_SOURCE, 0)) == base_tax * 3,
			"плоский накопитель должен содержать налог под источником «%s»"
					% city.TAX_INCOME_SOURCE, state)

	# --- 4. Платить некому — no-op ---
	city.treasury = 0
	city.total_population = 0
	check(city.collect_taxes() == 0, "при нулевом населении налог собираться не должен", state)
	check(city.treasury == 0, "при нулевом населении казна не должна меняться", state)

	# --- 5. Живой тик: налог приходит из do_tick() ---
	# Внутри do_tick() налог собирается ДО _check_population_change, поэтому
	# считаем его от населения на начало тика. Доход внутреннего рынка (здания
	# с профессиями и т.п.) измеряем отдельно — по продуктовому накопителю,
	# чтобы проверка не зависела от того, что именно продалось в этом тике.
	city.total_population = 3
	city.treasury = 0
	city.treasury_income_accum.clear()
	city.treasury_income_product_accum.clear()
	city.do_tick()
	var market_income: int = _sum_accum(city.treasury_income_product_accum)
	check(city.treasury == base_tax * 3 + market_income,
			"за тик казна должна получить налог %d + рынок %d (получено %d)"
					% [base_tax * 3, market_income, city.treasury], state)
	check(int(city.treasury_income_accum.get(city.TAX_INCOME_SOURCE, 0)) == base_tax * 3,
			"за тик в разбивку должен попасть налог %d" % (base_tax * 3), state)


	# --- 6. Разбивка казны: тип «Налоги» — плоская строка ---
	city.total_population = 3
	var actual: Dictionary = main_map.worker_manager.get_actual_treasury_income_map()
	check(actual.has(city.TAX_INCOME_TYPE),
			"в разбивке казны должен быть тип «%s»" % city.TAX_INCOME_TYPE, state)
	var flat_row: Dictionary = actual.get(city.TAX_INCOME_TYPE, {}).get(city.TREASURY_FLAT_TYPE_KEY, {})
	check(not flat_row.is_empty(),
			"тип «%s» должен быть «плоским» (ключ %s)"
					% [city.TAX_INCOME_TYPE, city.TREASURY_FLAT_TYPE_KEY], state)
	check(abs(float(flat_row.get("rate", 0.0)) - float(base_tax * 3)) < 0.0001,
			"ставка налога в разбивке: ожидалось %d, получено %s"
					% [base_tax * 3, str(flat_row.get("rate", 0.0))], state)
	check(str(flat_row.get("label", "")) == "%d × 3 чел." % base_tax,
			"подпись налога: ожидалось «%d × 3 чел.», получено «%s»"
					% [base_tax, str(flat_row.get("label", ""))], state)

	# Налог виден и тогда, когда рыночного дохода ещё нет (старт новой игры,
	# первое окно после загрузки, пустой склад).
	city.treasury_income_product_accum.clear()
	city.treasury_income_product_snapshot.clear()
	var taxes_only: Dictionary = main_map.worker_manager.get_actual_treasury_income_map()
	check(taxes_only.has(city.TAX_INCOME_TYPE),
			"налоги должны быть в разбивке и без рыночного дохода", state)
	check(not taxes_only.has("Потребление населения"),
			"без рыночного дохода тип «Потребление населения» показываться не должен", state)
	check(main_map.worker_manager.get_planned_treasury_income_map().has(city.TAX_INCOME_TYPE),
			"плановый генератор разбивки тоже должен знать про налоги", state)

	# --- 7. Рендер тултипа: одна строка «• Налоги: 2 × 3 чел. = 6 / сек» ---
	var holder := Control.new()
	root.add_child(holder)
	var ui = load("res://scripts/ui_helpers.gd").new()
	ui.setup(holder, Label.new())
	holder.add_child(ui)
	await process_frame
	await process_frame

	var tax_line: String = "%s: %d × 3 чел. = %s / сек" % [
		city.TAX_INCOME_TYPE, base_tax, _fmt_rate(float(base_tax * 3))
	]
	ui.show_treasury_tooltip(Vector2(80, 80), city.treasury, taxes_only, {}, 3.0)
	await process_frame
	var texts: Array = []
	_collect_label_texts(ui.treasury_tooltip_vbox, texts)
	check(texts.has(tax_line),
			"строка налога «%s» не найдена среди строк тултипа: %s" % [tax_line, str(texts)], state)
	check(texts.has("Прибыль (фактическая, средняя): %s / сек" % _fmt_rate(float(base_tax * 3))),
			"итог секции прибыли должен учитывать налог: %s" % str(texts), state)
	check(not texts.has("Все жители"),
			"плоский тип не должен раскрываться в источники/продукты", state)

	# Рынок + налог: итог секции = сумма строк, налог по-прежнему одной строкой.
	var mixed: Dictionary = taxes_only.duplicate(true)
	mixed["Потребление населения"] = {
		"Все жители": {
			"fish": {"coins_per_sec": 2.5, "product_name": "Рыба"}
		}
	}
	ui.show_treasury_tooltip(Vector2(80, 80), city.treasury, mixed, {}, 3.0)
	await process_frame
	texts.clear()
	_collect_label_texts(ui.treasury_tooltip_vbox, texts)
	check(texts.has(tax_line), "строка налога должна остаться и рядом с рынком: %s" % str(texts), state)
	check(texts.has("Рыба: 2.5 / сек"), "строки рынка должны рисоваться как раньше: %s" % str(texts), state)
	var expected_total: float = _sum_map_rates(mixed, city.TREASURY_FLAT_TYPE_KEY)
	check(texts.has("Прибыль (фактическая, средняя): %s / сек" % _fmt_rate(expected_total)),
			"итог секции прибыли: ожидалось «%s»" % _fmt_rate(expected_total), state)

	_finish(main_map, state)

# Собирает тексты всех Label дерева (включая «пули» _make_bullet_row, где
# символ и текст — отдельные метки в HBox).
func _collect_label_texts(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is Label:
			out.append((child as Label).text)
		_collect_label_texts(child, out)

# Сумма продуктового накопителя: { источник -> { pid -> amount } }.
func _sum_accum(by_source: Dictionary) -> int:
	var total := 0
	for source in by_source:
		for pid in by_source[source]:
			total += int(by_source[source][pid])
	return total

# Суммарная скорость разбивки: обычные типы — по продуктам, «плоский» — по его
# rate (то же правило, что в рендере тултипа).
func _sum_map_rates(income: Dictionary, flat_key: String) -> float:
	var total := 0.0
	for income_type in income:
		var type_dict: Dictionary = income[income_type]
		var flat: Dictionary = type_dict.get(flat_key, {})
		if not flat.is_empty():
			total += float(flat.get("rate", 0.0))
			continue
		for source in type_dict:
			for pid in type_dict[source]:
				total += float(type_dict[source][pid].get("coins_per_sec", 0.0))
	return total

# Формат скорости — как ui_helpers._format_rate (целые без дробной части).
func _fmt_rate(value: float) -> String:
	if value == floor(value):
		return str(int(value))
	return "%.1f" % value

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("TAXES TEST FAILED")
		quit(1)
	else:
		print("TAXES TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true

