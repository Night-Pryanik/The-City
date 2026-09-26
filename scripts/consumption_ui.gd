# consumption_ui.gd
# Общее представление ПРОФЕССИОНАЛЬНОГО ПОТРЕБЛЕНИЯ (data/consumption.json)
# в интерфейсе: превращает записи GameData.get_profession_consumption() в
# готовые строки показа вида «Перья: 2 шт./сек (+25% к производству)».
#
# Единая точка правды для всех мест, где игрок видит расход профессии:
#   * scripts/map_tooltip.gd    — расширенный тултип гекса и левая колонка
#                                 панели управления (улучшения на карте);
#   * scripts/buildings_tab.gd  — тултип деталей здания (вкладка «Здания»);
#   * scripts/building_panel.gd — окно деталей здания.
# Формат строки раньше жил внутри map_tooltip.gd, из-за чего каждое новое
# место копипастило бы расчёт скорости и подписи.
#
# Само потребление не хранится здесь: только профессиональные записи
# (см. docs.md, раздел «Профессии и потребление ресурсов»). Еда, корм
# пастбищ и спрос рецептов зданий — это ДРУГОЕ потребление, в этих строках
# не показывается.
#
# Публичный API:
#   - format_rate(value)                        : String  — «2» / «0.5»
#   - build_rows(prof_id, workers := 1)         : Array   — строки показа
#   - build_rows_for_building(building_id, w := 1) : Array — то же по профессии здания
class_name ConsumptionUi


# Форматирует скорость (ед./сек): целые значения без дробной части,
# дробные — с одним знаком («1.5»).
static func format_rate(value: float) -> String:
	if value == floor(value):
		return str(int(value))
	return "%.1f" % value


# Русская форма числительного: 1 здание / 2 здания / 5 зданий.
static func _plural(count: int, one: String, few: String, many: String) -> String:
	var mod100 := count % 100
	if mod100 >= 11 and mod100 <= 14:
		return many
	var mod10 := count % 10
	if mod10 == 1:
		return one
	if mod10 >= 2 and mod10 <= 4:
		return few
	return many


# Собирает строки показа профессионального потребления профессии.
#
# workers — сколько РАБОЧИХ объектов делят одну и ту же профессию:
#   1 (по умолчанию) — одно улучшение на карте или одно здание: скорость
#     такая же, как в расширенном тултипе гекса;
#   0 — рабочих объектов нет: скорость остаётся «на один объект», но в
#     подписи добавляется «(рабочих зданий нет)» — так окно деталей зданий
#     объясняет, почему при работающих слотах расхода не происходит;
#   N > 1 — скорость умножается на N, в подписи появляется «(N здания)»
#     (окно деталей зданий показывает сумму по рабочим постройкам).
#
# Каждая строка:
#   { "display_key": String   — id продукта или "@группа" (ключ для UI),
#     "name": String,          — имя продукта/группы,
#     "icon": String,          — имя файла иконки ("" — иконки нет),
#     "is_group": bool,        — групповая запись (списывается любой член),
#     "per_sec": float,        — суммарная скорость расхода, ед./сек,
#     "production_bonus": float, — 0.5 = +50% к производству; 0 = без бонуса,
#     "workers": int,
#     "rate_label": String,    — «2 шт./сек (+25% к производству)»,
#     "label": String }        — «Перья: 2 шт./сек (+25% к производству)»
static func build_rows(prof_id: String, workers: int = 1) -> Array:
	var rows: Array = []
	if prof_id.is_empty():
		return rows
	# workers = 0 не обнуляет скорость: расход на один объект остаётся виден,
	# отсутствие рабочих отражается только в подписи.
	var count := maxi(workers, 0)
	var multiplier := float(maxi(count, 1))
	for entry in GameData.get_profession_consumption(prof_id):
		var amount := int(entry.get("amount", 0))
		var interval := float(entry.get("interval", 0.0))
		# Показ — посекундный: amount записи, делённый на её interval.
		# interval = 0 означает «за тик», а тик симуляции равен секунде —
		# делить не на что, скорость равна amount.
		var per_sec := float(amount) if interval <= 0.0 else float(amount) / interval
		per_sec *= multiplier
		var bonus := float(entry.get("production_bonus", 0.0))
		rows.append({
			"display_key": str(entry.get("display_key", entry.get("product_id", ""))),
			"name": str(entry.get("product_name", entry.get("product_id", ""))),
			# Иконку кладёт GameData в обоих случаях: у продукта — своя,
			# у группы — первая из членов, у которой иконка задана.
			"icon": str(entry.get("icon", "")),
			"is_group": bool(entry.get("is_group", false)),
			"per_sec": per_sec,
			"production_bonus": bonus,
			"workers": count,
			"rate_label": _format_rate_label(per_sec, bonus, count),
		})
	for row in rows:
		# Имя продукта добавляется здесь, а не в _format_rate_label(): места,
		# где имя рисуется хелпером с иконкой (вкладка «Здания», окно здания),
		# берут name/display_key и дописывают к строке «rate_label».
		row["label"] = "%s: %s" % [row["name"], row["rate_label"]]
	return rows


# То же, что build_rows, но профессия берётся из самого здания (поле
# "profession" в data/buildings.json). У здания без профессии — пустой
# массив: работают по общей модели слотов, расходников не тратят.
static func build_rows_for_building(building_id: String, workers: int = 1) -> Array:
	if building_id.is_empty():
		return []
	return build_rows(GameData.get_profession_for_building(building_id), workers)


# Часть строки после имени продукта: «2 шт./сек (+25% к производству)».
# production_bonus выводится, чтобы игрок видел, зачем профессии этот
# расходник: пока ресурса хватает, производство идёт с бонусом, при нехватке
# — откатывается к базовому множителю (само производство не встаёт).
static func _format_rate_label(per_sec: float, bonus: float, workers: int) -> String:
	var text := "%s шт./сек" % format_rate(per_sec)
	if workers > 1:
		# Расход делят несколько рабочих объектов одного типа — показываем
		# сумму и сколько её даёт (окно деталей зданий).
		text += " (%d %s)" % [workers, _plural(workers, "здание", "здания", "зданий")]
	elif workers == 0:
		text += " (рабочих зданий нет)"
	if bonus > 0.0:
		text += " (+%d%% к производству)" % int(round(bonus * 100.0))
	return text
