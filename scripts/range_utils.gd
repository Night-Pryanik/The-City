# range_utils.gd
# Утилиты для разбора значений формата «число или диапазон [min, max]»
# из конфигурационных JSON (map_config.json, ресурсы и т.п.).
# Чисто-утилитный модуль: статические функции, без собственного состояния.
#
# Публичный API:
#   - parse_range(value) : Dictionary — { "ok": bool, "min": int, "max": int }
#
# Используется:
#   - scripts/map_generator.gd (_resolve_spawn_count — поле spawn_count ресурсов)
#   - scripts/sea_manager.gd   (apply_sea — поле sea.sides из map_config.json)
@tool
class_name RangeUtils


# Разбирает значение в формате «число» или «массив [min, max]».
#
# Допустимые входные данные:
#   * число (int/float)        -> ok=true, min=max=число;
#   * массив ровно из 2 чисел  -> ok=true, min/max из массива;
#                                 если max < min — форсированно меняются местами;
# всё остальное              -> ok=false (вызывающий код решает, какой
#                                 использовать безопасный дефолт).
#
# Возвращает словарь:
#   { "ok": bool, "min": int, "max": int }
static func parse_range(value: Variant) -> Dictionary:
	var result := {"ok": false, "min": 0, "max": 0}
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		result["ok"] = true
		result["min"] = int(value)
		result["max"] = int(value)
	elif value is Array and value.size() == 2:
		var first_is_number: bool = typeof(value[0]) == TYPE_INT or typeof(value[0]) == TYPE_FLOAT
		var second_is_number: bool = typeof(value[1]) == TYPE_INT or typeof(value[1]) == TYPE_FLOAT
		if first_is_number and second_is_number:
			result["ok"] = true
			result["min"] = int(value[0])
			result["max"] = int(value[1])
			if result["max"] < result["min"]:
				# Диапазон задан в обратном порядке — меняем местами.
				var tmp: int = result["min"]
				result["min"] = result["max"]
				result["max"] = tmp
	return result

# Возвращает случайное целое для значения формата «число или [min, max]»:
#   * число N            -> N;
#   * массив [min, max]  -> randi_range(min, max);
#   * некорректные данные (не число / не массив из 2 чисел, отрицательные
#     значения) -> предупреждение в консоль и default_value.
#
# Используется для полей ресурсов `spawn_count` (сколько экземпляров спавнить
# на карте) и `produces` (сколько продукции даёт одноразовый ресурс при сборе) —
# см. scripts/map_generator.gd и scripts/main_map.gd (ветка action_type "forage").
static func roll_value(value: Variant, context_name: String = "значение", default_value: int = 1) -> int:
	var parsed: Dictionary = parse_range(value)
	if not parsed.ok or parsed.min < 0 or parsed.max < 0:
		print("RangeUtils.roll_value: некорректное значение для %s "
				+ "(ожидается число >= 0 или массив [min, max] из чисел >= 0), "
				+ "используется %d." % [context_name, default_value])
		return default_value
	return randi_range(parsed.min, parsed.max)

# Возвращает минимальную границу значения формата «число или [min, max]».
# Нужна для детерминированных расчётов и отображения (тултипы, превью),
# где нельзя каждый кадр бросать случайное число. При некорректных данных
# возвращает default_value.
static func get_min_value(value: Variant, default_value: int = 1) -> int:
	var parsed: Dictionary = parse_range(value)
	if not parsed.ok or parsed.min < 0:
		return default_value
	return parsed.min
