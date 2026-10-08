# Сторож зависаний для headless-тестов (tests/*.gd).
#
# Тест — это скрипт на SceneTree в отдельном процессе (`godot --headless
# --path . --script res://tests/<имя>.gd`, команду запускают ИЗ КОРНЯ
# репозитория: `--path .` — это «текущий каталог», поэтому результат не
# зависит от того, куда именно положен клон).
#
# После СВЕЖЕГО клона нужен один раз `godot --headless --path . --import`:
# без него нет каталога `.godot/` и кэша `.godot/uid_cache.bin`, поэтому
# автозагрузки (GameData/CityData/SaveManager) не инстанцируются, а
# `get_root().get_node("CityData")` возвращает null. Тест при этом падает не
# по существу, а с кодом 2 от сторожа ниже, и по сообщению непонятно, что дело
# в неимпортированном проекте. Для уже открытого в редакторе проекта импорт
# выполнен, шаг не нужен.
#
# Ошибка времени выполнения внутри
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

# --- Выбор отдельных кейсов -------------------------------------------------
#
# Тест из 25 кейсов гоняется целиком ради одного — это главная статья расходов
# при правке одной механики. Фильтр приходит штатным способом Godot: после
# разделителя `--` аргументы движок не разбирает и отдаёт приложению.
#
#     godot --headless --path . --script res://tests/test_town_economy.gd \
#         -- --case=readiness --case=trade_comfort_from_data
#
# Живёт здесь, а не в каждом тесте, по той же причине, что и сторож: это общий
# помощник, который уже preload'ится всеми тестами (в --script-режиме class_name
# может быть ещё не в кеше, поэтому preload по пути надёжнее).
const CASE_PREFIX := "--case="

static func requested_cases() -> PackedStringArray:
    var wanted := PackedStringArray()
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with(CASE_PREFIX):
            var value := arg.substr(CASE_PREFIX.length()).strip_edges()
            if value != "":
                wanted.append(value)
    return wanted

# Выполнять ли кейс с таким именем. Без фильтра — все.
#
# Сравнение по подстроке без учёта регистра: имена кейсов длинные
# (`trade_comfort_from_data`), и набирать их целиком каждый раз незачем, а
# тестов, где одна подстрока накрыла бы два разных кейса, в проекте нет.
static func wants(name: String) -> bool:
    var wanted := requested_cases()
    if wanted.is_empty():
        return true
    for filter in wanted:
        if name.to_lower().contains(filter.to_lower()):
            return true
    return false

# Обёртка над вызовом кейса.
#
# Возвращает false, если кейс отфильтрован, и true, если его надо выполнить.
# Вызывающий пишет так:
#
#     if WATCHDOG.wants_case("readiness"):
#         _test_readiness()
#     if WATCHDOG.wants_case("live_map"):
#         await _test_live_map()
#
# Именно «сначала спросить, потом вызвать напрямую», а не «передать кейс
# замыканием»: вызов корутины через Callable.call() движок обрывает с
# «Trying to call an async function without await», а `await callable.call()`
# движок принимает как обычное значение (await на не-сигнале просто
# разворачивается), из-за чего корутина не выполняется до конца. Прямой вызов
# в теле теста — единственная форма, которая работает и для обычных кейсов,
# и для корутин.
static func wants_case(name: String) -> bool:
    if wants(name):
        return true
    _skipped.append(name)
    return false

static var _skipped := PackedStringArray()

# Печатается тестом перед вердиктом. Пропущенные кейсы надо видеть: иначе
# отфильтрованный прогон неотличим от полного по одной лишь строке «тест OK».
static func report_skipped() -> void:
    if _skipped.is_empty():
        return
    print("SKIPPED (--case): ", ", ".join(_skipped))
