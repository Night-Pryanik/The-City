# Тест рантайм-валидатора игровых данных (headless):
#   godot --headless --path . --script res://tests/test_data_validation.gd
#
# Проверяет две вещи:
#   1) ДЕТЕКТОР (главное). На искусственных данных в каждый вид проверки
#      вносится ровно одна поломка, и тест требует найти каждую — с
#      правильным видом проверки, идентификатором и владельцем ссылки.
#      Данные синтетические намеренно: тест не должен сломаться, когда
#      автор починит настоящие data/*.json.
#   2) ЛОЖНЫЕ СРАБАТЫВАНИЯ. Два места, где валидатор обязан промолчать:
#      produced_in == "*" (служебный маркер «в любом здании», см.
#      CityData.can_craft_in) и category у СЫРЬЯ (там это фильтр генерации
#      карты со своим набором значений — animals/plants/metals/minerals,
#      а не категории из data/categories.json).
#
# Реальные data/*.json прогоняются в конце только на предмет «валидатор не
# падает»; сам их список проблем не проверяется и печатается для справки.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _initialize() выглядит снаружи
# как вечное молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const DataValidator = preload("res://scripts/data_validator.gd")


func _initialize():
	WATCHDOG.arm(self)
	var state = {"failed": false}

	_test_detector(state)
	_test_no_false_positives_on_synthetic(state)
	_test_real_data(state)

	if state["failed"]:
		print("VALIDATION TEST FAILED")
		quit(1)
	else:
		print("VALIDATION TEST OK")
		quit(0)


# --- 1) Каждый вид проверки ловит свою поломку -----------------------------

func _test_detector(state: Dictionary):
	var gd = _make_data()

	# Ожидаемый набор поломок: вид проверки → [идентификатор, владелец].
	# Порядок и количество проверяются точно: лишняя или пропавшая проблема —
	# тоже баг валидатора.
	var expected := {
		"produced_in": [["ghost_mill", "bad_produced_in"]],
		"result": [["ghost_product", "bad_result"]],
		"improved_by": [["ghost_farm", "bad_improved_by"]],
		"unlock_improvement": [["ghost_farm", "bad_unlock_improvement"]],
		"unlock_tech": [
			["ghost_tech", "bad_building_tech"],
			["ghost_tech", "bad_improvement_tech"],
			["ghost_tech", "bad_product_tech"],
			["ghost_tech", "bad_craft_tech"],
		],
		"profession": [
			["ghost_prof", "bad_building_prof"],
			["ghost_prof", "bad_improvement_prof"],
		],
		"category": [["ghost_category", "bad_category"]],
		"group_member": [["ghost_member", "bad_group"]],
		"resource_group": [["@ghost_group", "bad_group_ref"]],
		"resource": [["ghost_raw", "bad_resource_ref"]],
		"prerequisite": [["ghost_tech", "bad_tech_prereq"]],
	}

	var problems: Array = DataValidator.new().validate(gd)

	for kind in expected:
		for pair in expected[kind]:
			var ref_id: String = str(pair[0])
			var source_id: String = str(pair[1])
			var found := _find(problems, kind, ref_id, source_id)
			check(not found.is_empty(),
				"не найдена проблема: kind=%s, ref=%s, источник=%s" % [kind, ref_id, source_id],
				state)

	# Каждая поломка должна давать ровно одну проблему своего вида, а не
	# «соседнюю» — иначе сообщение указывает не на то поле.
	check(problems.size() == _expected_problem_count(expected),
		"ожидалось %d проблем, получено %d: %s" % [
			_expected_problem_count(expected), problems.size(),
			_str_messages(problems)], state)

	# Сообщение обязано называть и недостающий идентификатор, и владельца
	# ссылки — иначе игрок не поймёт, что чинить.
	var sample := _find(problems, "group_member", "ghost_member", "bad_group")
	check(sample.has("message"), "у проблемы нет поля message", state)
	check(str(sample.get("message", "")).contains("ghost_member"),
		"сообщение не содержит искомый идентификатор: %s" % str(sample.get("message", "")), state)
	check(str(sample.get("message", "")).contains("bad_group"),
		"сообщение не содержит id владельца ссылки: %s" % str(sample.get("message", "")), state)
	check(str(sample.get("where", "")).contains("bad_group"),
		"поле where не содержит id владельца ссылки: %s" % str(sample.get("where", "")), state)

	gd.free()


# --- 2) Два места, где валидатор обязан промолчать ------------------------

func _test_no_false_positives_on_synthetic(state: Dictionary):
	var gd = _make_data()
	var problems: Array = DataValidator.new().validate(gd)

	check(_find(problems, "produced_in", "*", "wildcard_recipe").is_empty(),
		"служебный маркер \"*\" в produced_in не должен считаться поломкой", state)
	check(_find(problems, "category", "animals", "wildcard_raw").is_empty(),
		"category у сырья («animals») не должен сверяться с data/categories.json", state)

	# Явно пустые поля (null) — не ссылки. Ни одна из этих сущностей не
	# должна попасть в результат ни под каким видом проверки.
	for entity_id in ["null_fields", "null_product", "null_improvement", "null_building"]:
		for problem in problems:
			check(str(problem.get("source_id", "")) != entity_id,
				"явно пустое поле (null) у «%s» принято за битую ссылку: %s" % [
					entity_id, str(problem.get("message", ""))], state)
			check(str(problem.get("ref_id", "")) != "<null>",
				"идентификатор «<null>» в сообщении — null не переведён в пустую строку", state)

	# Данные БЕЗ индекса происхождения (entity_sources пуст) — проблемы
	# всё равно находятся, просто остаются без указания файла. Отсутствие
	# индекса не должно ронять валидатор: это делает проверку годной для
	# любых данных с теми же полями.
	for problem in problems:
		check(str(problem.get("file", "")).is_empty(),
			"без индекса происхождения файл указываться не должен: %s" % [
				str(problem.get("message", ""))], state)
		check(int(problem.get("line", 0)) == 0,
			"без индекса происхождения строка не должна быть ненулевой", state)
		check(str(problem.get("location", "")).is_empty(),
			"без индекса происхождения location должен быть пустым", state)
		check(not str(problem.get("message", "")).contains("Файл:"),
			"в сообщении не должно быть строки «Файл:» без индекса: %s" % [
				str(problem.get("message", ""))], state)

	gd.free()


# --- 3) Настоящие данные: валидатор не падает -----------------------------

func _test_real_data(state: Dictionary):
	var gd = load("res://scripts/GameData.gd").new()
	gd.load_all_data()

	check(gd.data_loaded, "GameData.load_all_data() не выставил data_loaded", state)

	var problems: Array = DataValidator.new().validate(gd)
	print("Проблем в res://data по проверке ссылок: %d" % problems.size())
	for problem in problems:
		print("  - ", str(problem.get("message", "")))

	# Конкретные id из настоящих данных не проверяем: их автор починит, и
	# тест упадёт на ровно том, ради чего валидатор написан. Проверяем
	# инварианты, которые должны держаться при любом содержимом данных.

	# produced_in == "*" у псевдорецепта "empty" (data/crafts/pseudo.json)
	# — не поломка.
	for problem in problems:
		check(not (problem.get("kind") == "produced_in" and problem.get("ref_id") == "*"),
			"валидатор ругается на \"*\" в produced_in", state)

	# Категория проверяется только у продуктов: у каждой проблемы вида
	# "category" владелец обязан быть продуктом, а не сырьём.
	var products: Dictionary = gd.products
	for problem in problems:
		if problem.get("kind") != "category":
			continue
		var owner_id := str(problem.get("source_id", ""))
		check(products.has(owner_id),
			"проблема category у не-продукта «%s» — сырьё сверяется с чужим набором категорий" % owner_id,
			state)

	# У каждой проблемы заполнены обе строки сообщения.
	for problem in problems:
		var msg := str(problem.get("message", ""))
		check(not msg.is_empty(), "проблема без текста сообщения", state)
		check(not str(problem.get("headline", "")).is_empty(),
			"проблема без headline", state)
		check(not str(problem.get("where", "")).is_empty(),
			"проблема без where", state)

	_check_file_and_line(state, problems)

	# count_by_kind обязан согласовываться с самим списком.
	var counts := DataValidator.new().count_by_kind(problems)
	var total := 0
	for kind in counts:
		total += int(counts[kind])
	check(total == problems.size(),
		"count_by_kind разошёлся с числом проблем: %d != %d" % [total, problems.size()], state)

	gd.free()


# --- 4) Указание на файл и строку -----------------------------------------
#
# Проблема обязана называть не только сущность, но и ФАЙЛ, в котором сущность
# объявлена, и строку. Смысл такой строки — «здесь смотри», поэтому проверяется
# не сам номер, а то, что на этой строке действительно лежит объявление
# владельца: иначе номер был бы правдоподобным и неверным, и хуже, чем его
# отсутствие.
func _check_file_and_line(state: Dictionary, problems: Array):
	# Файлы из разных проблем читаем по одному разу.
	var lines_by_file := {}
	for problem in problems:
		var file_path := str(problem.get("file", ""))
		var line := int(problem.get("line", 0))
		var source_id := str(problem.get("source_id", ""))

		check(not file_path.is_empty(),
			"у проблемы %s не указан файл" % str(problem.get("message", "")), state)
		check(line > 0,
			"у проблемы %s не указана строка" % str(problem.get("message", "")), state)

		if file_path.is_empty() or line <= 0:
			continue

		check(file_path.begins_with("res://data/"),
			"файл проблемы вне папки data: %s" % file_path, state)
		var location := str(problem.get("location", ""))
		check(location.contains(file_path),
			"location не содержит путь к файлу: %s" % location, state)
		check(location.contains(str(line)),
			"location не содержит номер строки: %s" % location, state)
		check(str(problem.get("message", "")).contains(file_path),
			"message не содержит путь к файлу — пропадёт в логе", state)

		if not lines_by_file.has(file_path):
			lines_by_file[file_path] = _read_lines(file_path)
		var lines: Array = lines_by_file[file_path]
		check(line <= lines.size(),
			"строка %d за пределами файла %s (%d строк)" % [line, file_path, lines.size()], state)
		if line > lines.size():
			continue
		var decl := str(lines[line - 1])
		check(decl.contains("\"%s\"" % source_id),
			"строка %d файла %s — это не объявление «%s»: %s" % [
				line, file_path, source_id, decl.strip_edges()], state)


# --- ВСПОМОГАТЕЛЬНОЕ ------------------------------------------------------

# Синтетический набор данных: «хорошая» база + по одной поломке каждого вида.
# Создаётся отдельный экземпляр GameData (не автозагрузка) — ему доступны
# все публичные поля, которые читает валидатор.
func _make_data() -> Node:
	var gd = load("res://scripts/GameData.gd").new()

	gd.categories = [
		{"id": "food", "name": "Еда"},
		{"id": "other", "name": "Разное"},
	]
	gd.professions = {
		"farmer": {"id": "farmer", "name": "Фермер"},
		"blacksmith": {"id": "blacksmith", "name": "Кузнец"},
	}
	gd.technologies = [
		{"id": "t_fire", "name": "Огонь"},
		{"id": "t_wheel", "name": "Колесо"},
		# Пререквизиты в обоих допустимых форматах: плоский список и
		# список ИЛИ-групп [[ "a", "b" ], [ "c" ]].
		{"id": "t_flat_prereq", "name": "Плоский", "prerequisites": ["t_fire"]},
		{"id": "t_group_prereq", "name": "Групповой", "prerequisites": [["t_fire", "t_wheel"]]},
	]
	gd.improvements = {
		"farm": {"id": "farm", "name": "Ферма"},
		"quarry": {"id": "quarry", "name": "Карьер"},
	}
	gd.products = {
		"wheat": {"id": "wheat", "name": "Пшеница", "category": "food"},
		"flour": {"id": "flour", "name": "Мука", "category": "food"},
		"tools": {"id": "tools", "name": "Инструменты", "category": "other"},
	}
	gd.raw_resources = {
		"wood": {"id": "wood", "name": "Дерево", "type": "raw", "category": "plants"},
		"clay": {"id": "clay", "name": "Глина", "type": "raw", "category": "plants"},
	}
	gd.product_groups = {
		"grains": ["wheat"],
		"food": ["wheat", "flour"],
	}
	gd.product_group_names = {
		"grains": "Злаки",
		"food": "Еда",
	}
	gd.buildings = [
		{"id": "bakery", "name": "Пекарня"},
	]

	# --- поломки ---
	# produced_in → несуществующее здание
	gd.buildings.append({"id": "bad_building_tech", "name": "Дом", "unlock_tech": "ghost_tech"})
	# profession у здания
	gd.buildings.append({"id": "bad_building_prof", "name": "Мастерская",
			"profession": "ghost_prof"})
	# unlock_tech у улучшения
	gd.improvements["bad_improvement_tech"] = {"id": "bad_improvement_tech",
			"name": "Плохая яма", "unlock_tech": "ghost_tech"}
	# profession у улучшения
	gd.improvements["bad_improvement_prof"] = {"id": "bad_improvement_prof",
			"name": "Плохая пашня", "profession": "ghost_prof"}
	# improved_by у сырья
	gd.raw_resources["bad_improved_by"] = {"id": "bad_improved_by", "name": "Рожь",
			"type": "raw", "improved_by": "ghost_farm"}
	# unlock_improvement у продукта
	gd.products["bad_unlock_improvement"] = {"id": "bad_unlock_improvement",
			"name": "Зерно", "category": "food", "unlock_improvement": "ghost_farm"}
	# unlock_tech у продукта
	gd.products["bad_product_tech"] = {"id": "bad_product_tech", "name": "Соль",
			"category": "food", "unlock_tech": "ghost_tech"}
	# category у продукта
	gd.products["bad_category"] = {"id": "bad_category", "name": "Мёд",
			"category": "ghost_category"}
	# несуществующий член @-группы
	gd.product_groups["bad_group"] = ["wheat", "ghost_member"]
	gd.product_group_names["bad_group"] = "Плохая группа"
	# prerequisites технологии (ИЛИ-группа с одним несуществующим id)
	gd.technologies.append({"id": "bad_tech_prereq", "name": "Плохая технология",
			"prerequisites": [["t_wheel", "ghost_tech"]]})

	# Ловушки ложных срабатываний.
	gd.crafts = [
		# Корректные рецепты — на них валидатор молчит.
		{"id": "good_recipe", "name": "Хороший рецепт", "produced_in": ["bakery"],
				"resources": {"wood": 2, "@grains": 5}, "result": {"flour": 3},
				"unlock_tech": "t_fire"},
		# "*" — служебный маркер «в любом здании».
		{"id": "wildcard_recipe", "name": "Пустой рецепт", "produced_in": ["*"],
				"resources": {}, "result": {}},
		# Ссылка на сырьё в result не считается поломкой (рецепт вправе
		# требовать и сырьё — «clay»), а вот несуществующее — да.
		{"id": "raw_result_ok", "name": "Рецепт с сырьём в result",
				"produced_in": ["bakery"], "resources": {}, "result": {"clay": 1}},
		{"id": "bad_produced_in", "name": "Рецепт в призрачном здании",
				"produced_in": ["ghost_mill"], "resources": {}, "result": {}},
		{"id": "bad_result", "name": "Рецепт с призрачным продуктом",
				"produced_in": ["bakery"], "resources": {}, "result": {"ghost_product": 1}},
		{"id": "bad_craft_tech", "name": "Рецепт за призрачной технологией",
				"produced_in": ["bakery"], "resources": {}, "result": {"flour": 1},
				"unlock_tech": "ghost_tech"},
		{"id": "bad_group_ref", "name": "Рецепт с призрачной группой",
				"produced_in": ["bakery"], "resources": {"@ghost_group": 5}, "result": {}},
		{"id": "bad_resource_ref", "name": "Рецепт с призрачным ресурсом",
				"produced_in": ["bakery"], "resources": {"ghost_raw": 5}, "result": {}},
	]
	# Категория "animals" у сырья — фильтр генерации карты, не категория
	# из categories.json. Проверяется у сырья отдельно ниже.
	gd.raw_resources["wildcard_raw"] = {"id": "wildcard_raw", "name": "Корова",
			"type": "raw", "category": "animals"}

	# Явно пустые поля (null). В data/*.json так записаны, например,
	# "improved_by": null у самородков — это «улучшения нет», а не ссылка
	# на несуществующее улучшение. str(null) в GDScript даёт «<null>»,
	# поэтому без отдельной обработки валидатор ругался бы на каждое
	# пустое поле (регрессия, найденная этим же тестом).
	gd.raw_resources["null_fields"] = {"id": "null_fields", "name": "Пустое сырьё",
			"type": "raw", "improved_by": null, "unlock_tech": null, "category": null}
	gd.products["null_product"] = {"id": "null_product", "name": "Пустой продукт",
			"category": "food", "unlock_improvement": null, "unlock_tech": null}
	gd.improvements["null_improvement"] = {"id": "null_improvement",
			"name": "Пустое улучшение", "profession": null, "unlock_tech": null}
	gd.buildings.append({"id": "null_building", "name": "Пустое здание",
			"profession": null, "unlock_tech": null})

	return gd


func _find(problems: Array, kind: String, ref_id: String, source_id: String) -> Dictionary:
	for problem in problems:
		if str(problem.get("kind", "")) == kind \
				and str(problem.get("ref_id", "")) == ref_id \
				and str(problem.get("source_id", "")) == source_id:
			return problem
	return {}


# Строки файла данных как есть (с комментариями) — номера строк в сообщениях
# валидатора считаются по исходному тексту, а не по очищенному от комментариев.
func _read_lines(file_path: String) -> Array:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return []
	return Array(file.get_as_text().split("\n"))


func _expected_problem_count(expected: Dictionary) -> int:
	var total := 0
	for kind in expected:
		total += (expected[kind] as Array).size()
	return total


func _str_messages(problems: Array) -> String:
	var lines: Array = []
	for problem in problems:
		lines.append(str(problem.get("message", "")))
	return "; ".join(lines)


func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true
