# Headless-тест общего реестра иконок IconRegistry (автозагрузка):
#   godot --headless --path . --script res://tests/test_icon_registry.gd
#
# Зачем: до появления реестра индекс иконок строился рекурсивным обходом
# res://icons в ВОСЬМИ модулях (map_renderer, resources_tab, buildings_tab —
# дважды в одном файле, building_panel, tech_tree, town_ui, trade_tab), причём
# правила индексации расходились: где-то дубль перезаписывал путь, где-то
# игнорировался; и половину индекса занимали 288 файлов *.import. Хуже всего
# buildings_tab собирал индекс внутри _show_building_details — обход 576 файлов
# при каждом наведении на здание. Тест защищает единственный оставшийся
# источник истины.
#
# Истина для проверки — САМА файловая система (рекурсивный обход каталога), а не
# константы теста: иконки добавляются и перекладываются между подпапками.
#
# Проверяется:
#  1. Индекс полон: в нём ровно те файлы, что лежат в res://icons, минус
#     служебные (*.import/*.remap/скрытые) — поимённая сверка с обходом.
#  2. Служебных файлов в индексе нет, скрытых нет.
#  3. Дублей имён нет (иначе одна картинка молча подменяла бы другую, и
#     результат зависел бы от порядка обхода).
#  4. Каждый путь из индекса — существующий файл с тем же именем.
#  5. build() идемпотентен: повторная пересборка даёт тот же результат.
#  6. get_texture кэширует: два вызова на один файл дают ОДИН объект
#     (раньше кэши жили в шести модулях копиями).
#  7. Неизвестное и пустое имя дают "" / null, без ошибок.
#
# НЕ проверяется: наличие иконки для каждой ссылки в data/*.json. В данных
# намеренно есть ссылки на ещё не нарисованные иконки (будущие товары и
# профессии), UI их штатно пропускает — требовать наличия означало бы запретить
# автору дописывать данные заранее. Число таких ссылок печатается как справка.
#
# ВАЖНО: скрипт компилируется ДО регистрации автозагрузок, поэтому реестр
# берём через дерево сцены, а не по имени (тот же приём, что CityData в
# других тестах).
extends SceneTree

# Сторож зависаний — см. tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const ROOT := "res://icons"
# Служебные файлы, которые реестр обязан пропускать.
const SKIP_SUFFIXES := [".import", ".remap"]

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	var state = {"failed": false}
	var registry = get_root().get_node("IconRegistry")
	check(registry != null, "автозагрузка IconRegistry не зарегистрирована", state)
	if registry == null:
		_finish(state)
		return

	# --- Истина: что реально лежит на диске (рекурсивный обход) ---
	var on_disk := {}
	_scan_disk(ROOT, on_disk)

	check(registry.count() > 0, "индекс иконок пуст (получено: %d)" % registry.count(), state)
	check(registry.count() == on_disk.size(),
		"размер индекса не совпадает с числом файлов на диске (в индексе %d, на диске %d)"
			% [registry.count(), on_disk.size()], state)

	# --- 1. Поимённая сверка индекса с диском ---
	var missing_in_index: Array = []
	for file_name in on_disk.keys():
		if not registry.has(file_name):
			missing_in_index.append(file_name)
	check(missing_in_index.is_empty(),
		"файлы, которых нет в индексе: %s" % _fmt_list(missing_in_index), state)

	var extra_in_index: Array = []
	for file_name in registry.paths.keys():
		if not on_disk.has(file_name):
			extra_in_index.append(file_name)
	check(extra_in_index.is_empty(),
		"в индексе есть то, чего нет на диске: %s" % _fmt_list(extra_in_index), state)

	# --- 2. Служебные и скрытые файлы в индекс не попадают ---
	var junk: Array = []
	for file_name in registry.paths.keys():
		var is_junk: bool = file_name.begins_with(".")
		for suffix in SKIP_SUFFIXES:
			if file_name.ends_with(suffix):
				is_junk = true
		if is_junk:
			junk.append(file_name)
	check(junk.is_empty(),
		"служебные/скрытые файлы попали в индекс: %s" % _fmt_list(junk), state)

	# --- 3. Дубли имён ---
	# Считаем сами: если две картинки в разных подпапках называются одинаково,
	# в индексе останется первая, а вторая будет молча потеряна.
	var names_seen := {}
	var duplicates: Array = []
	for path in on_disk.values():
		var base: String = str(path).get_file()
		if names_seen.has(base):
			duplicates.append("%s (%s и %s)" % [base, names_seen[base], path])
		else:
			names_seen[base] = path
	check(duplicates.is_empty(),
		"в res://icons есть одноимённые файлы в разных папках: %s"
			% _fmt_list(duplicates), state)
# --- 4. Пути из индекса указывают на существующие файлы ---
	var bad_paths: Array = []
	var checked_paths := 0
	for file_name in registry.paths.keys():
		var path: String = registry.paths[file_name]
		checked_paths += 1
		if str(path).get_file() != file_name or not FileAccess.file_exists(path):
			bad_paths.append("%s -> %s" % [file_name, path])
	check(checked_paths == on_disk.size(),
		"проверено путей %d, а файлов на диске %d" % [checked_paths, on_disk.size()], state)
	check(bad_paths.is_empty(),
		"пути индекса не ведут к файлам: %s" % _fmt_list(bad_paths), state)

	# --- 5. build() идемпотентен ---
	var count_before: int = registry.count()
	registry.build()
	check(registry.count() == count_before,
		"повторный build() изменил размер индекса (было %d, стало %d)"
			% [count_before, registry.count()], state)

	# --- 6. get_texture отдаёт общий кэшированный объект ---
	var texture_name := ""
	for file_name in registry.paths.keys():
		if str(file_name).ends_with(".png"):
			texture_name = file_name
			break
	check(not texture_name.is_empty(), "в индексе нет ни одной .png", state)
	if not texture_name.is_empty():
		var tex_a = registry.get_texture(texture_name)
		var tex_b = registry.get_texture(texture_name)
		check(tex_a is Texture2D, "get_texture вернул не текстуру для %s" % texture_name, state)
		check(tex_a == tex_b,
			"текстура %s грузится повторно вместо кэша" % texture_name, state)
		# Путь и текстура обязаны соответствовать одной и той же записи.
		check(registry.icon_path(texture_name) == str(registry.paths[texture_name]),
			"icon_path расходится с paths для %s" % texture_name, state)

	# --- 7. Неизвестные имена ---
	check(registry.icon_path("definitely_missing_icon.png") == "",
		"icon_path для несуществующей иконки вернул не пустую строку", state)
	check(registry.get_texture("definitely_missing_icon.png") == null,
		"get_texture для несуществующей иконки вернул не null", state)
	check(registry.icon_path("") == "", "icon_path для пустого имени вернул не пустую строку", state)
	check(registry.get_texture("") == null, "get_texture для пустого имени вернул не null", state)
	check(not registry.has("definitely_missing_icon.png"),
		"has() для несуществующей иконки вернул true", state)

	# Справка (не проверка): сколько ссылок в данных указывает на ещё
	# ненарисованные иконки. Печатается, чтобы автор видел масштаб.
	_print_missing_references(state)

	_finish(state)
# Рекурсивный обход каталога с теми же правилами пропуска, что у реестра.
func _scan_disk(folder_path: String, out: Dictionary) -> void:
	var dir := DirAccess.open(folder_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if dir.current_is_dir():
			_scan_disk(folder_path.path_join(file_name), out)
		else:
			var skip: bool = file_name.begins_with(".")
			for suffix in SKIP_SUFFIXES:
				if file_name.ends_with(suffix):
					skip = true
			if not skip:
				out[file_name] = folder_path.path_join(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

# Печатает, на какие иконки ссылаются данные, но файла ещё нет. Это норма
# (будущий контент), поэтому проверкой не считается.
func _print_missing_references(state: Dictionary) -> void:
	var registry = get_root().get_node("IconRegistry")
	var gdata = get_root().get_node("GameData")
	if registry == null or gdata == null:
		return
	if not gdata.data_loaded:
		gdata.load_all_data()
	var missing := {}
	for entry in _iter_icon_refs(gdata):
		var name := str(entry)
		if not name.is_empty() and not registry.has(name):
			missing[name] = true
	print("СПРАВКА: ссылок в данных на ненарисованные иконки — %d (это норма)"
		% missing.size())

# Все значения полей icon / icons в данных: сырьё, продукты, улучшения,
# местности, покровы, здания, технологии, спецдействия, модификаторы, группы,
# профессии.
func _iter_icon_refs(gdata) -> Array:
	var out: Array = []
	for d in [gdata.raw_resources, gdata.products, gdata.improvements,
			gdata.terrains, gdata.professions, gdata.qualities, gdata.covers,
			gdata.special_actions]:
		_collect_from_dict(d, out)
	for list_data in [gdata.technologies, gdata.crafts, gdata.categories, gdata.eras]:
		_collect_from_list(list_data, out)
	_collect_from_dict(gdata.product_group_icons, out)
	for group_id in gdata.product_groups.keys():
		_collect_from_list(gdata.product_groups[group_id], out)
	# Модификаторы: внешний вид — словарь, но запись может быть и списком
	# (данные не задают единой формы), поэтому проверяем тип перед чтением.
	for mod in gdata.modifiers.values():
		if mod is Dictionary:
			_collect_from_list(mod.get("tech_modifiers", []), out)
		elif mod is Array:
			_collect_from_list(mod, out)
	return out

func _collect_from_dict(source, out: Array) -> void:
	if source == null or not (source is Dictionary):
		return
	for value in source.values():
		_collect_from_entry(value, out)

func _collect_from_list(source, out: Array) -> void:
	if source == null or not (source is Array):
		return
	for value in source:
		_collect_from_entry(value, out)

func _collect_from_entry(value, out: Array) -> void:
	if value == null:
		return
	if value is String or value is StringName:
		# product_group_icons хранит id -> имя файла иконки.
		if not str(value).is_empty():
			out.append(str(value))
		return
	if not (value is Dictionary):
		return
	var d: Dictionary = value
	if d.has("icon"):
		out.append(str(d["icon"]))
	if d.has("icons"):
		_collect_from_list(d["icons"], out)
	# Произвольные эффекты технологии: [{ "icon": ..., "name": ... }].
	_collect_from_list(d.get("unlock_effects", []), out)

func _fmt_list(items: Array) -> String:
	if items.is_empty():
		return "(нет)"
	var shown := items.slice(0, 8)
	var text := ", ".join(PackedStringArray(shown))
	if items.size() > shown.size():
		text += " … всего %d" % items.size()
	return text

func _finish(state: Dictionary) -> void:
	if state["failed"]:
		print("ICON REGISTRY TEST FAILED")
		quit(1)
	else:
		print("ICON REGISTRY TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true