# Сторож зависаний для headless-тестов (tests/*.gd).
#
# Тест — это скрипт на SceneTree в отдельном процессе (`godot --headless
# --path . --script res://tests/<имя>.gd`). Ошибка времени выполнения внутри
# корутины `_run()` (например, вызов с аргументом не того типа) ОБРЫВАЕТ
# корутину: до `quit()` управление не доходит, дерево продолжает крутиться, и
# снаружи это выглядит как молчаливое зависание — процесс живёт вечно и ничего
# не печатает. Именно так вёл себя test_detail_tooltip с вызовом
# show_flow_tooltip, которому в resource_id подали Dictionary вместо String.
#
# `arm()` поднимает таймер на весь прогон. Если тест не дошёл до конца (обрыв
# корутины, забытый `quit()`, настоящее зависание на `await`), он печатает
# метку теста и выходит с кодом 2. Снимать таймер не нужно: успешный тест
# вызывает `quit()` сам, и таймер просто не успевает сработать. Обратная
# сторона: забытый `quit()` в конце теста тоже ловится — такой тест сам по себе
# «зависший».
#
# Подключается по пути, а не через class_name: при запуске через --script
# глобальные имена классов могут быть ещё не в кеше (тот же аргумент, что у
# underlined_label в ui_helpers.gd), а preload надёжен в любом режиме.
#
# Обычный выход из _initialize():
#     const WATCHDOG = preload("res://tests/watchdog.gd")
#     func _initialize() -> void:
#         WATCHDOG.arm(self)
#         _run()
extends RefCounted

# Запас большой: самый долгий тест сейчас идёт ~10 с (генерация карт), 120 с —
# это примерно двенадцатикратный запас на медленную машину. Тест, которому
# нужен свой предел, передаёт его явно: WATCHDOG.arm(self, 30.0).
const DEFAULT_TIMEOUT: float = 120.0

# Таймер поднимается один раз на процесс: повторный arm() (например, из
# _initialize и из первого _process) ничего не меняет.
static var _armed := false

static func arm(tree: SceneTree, timeout: float = DEFAULT_TIMEOUT) -> void:
	if _armed:
		return
	_armed = true
	var label := _label(tree)
	tree.create_timer(timeout, true, false, true).timeout.connect(
		func() -> void:
			var msg := "WATCHDOG [%s]: тест не завершился за %.0f с — завис или оборвался внутри _run()" % [label, timeout]
			push_error(msg)
			print(msg)
			print("WATCHDOG [%s] HUNG" % label)
			tree.quit(2)
	)

# Метка для сообщения — имя файла теста без пути и расширения.
static func _label(tree: SceneTree) -> String:
	var script := tree.get_script() as Script
	if script == null or script.resource_path == "":
		return "без имени"
	return script.resource_path.get_file().get_basename()
