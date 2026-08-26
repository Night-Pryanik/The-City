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
	elif value is Array and value.size() == 2 \\
			and (typeof(value[0]) == TYPE_INT or typeof(value[0]) == TYPE_FLOAT) \\
			and (typeof(value[1]) == TYPE_INT or typeof(value[1]) == TYPE_FLOAT):
		result["ok"] = true
		result["min"] = int(value[0])
		result["max"] = int(value[1])
		if result["max"] < result["min"]:
			# Диапазон задан в обратном порядке — меняем местами.
			var tmp: int = result["min"]
			result["min"] = result["max"]
			result["max"] = tmp
	return result
