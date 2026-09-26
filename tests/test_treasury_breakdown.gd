# Smoke-тест разбивки казны по источникам (headless):
#   godot --headless --path "E:\The City" --script res://tools/test_treasury_breakdown.gd
# Проверяет state-машину CityData.record_treasury_* / rotate_treasury_window.
# Не использует autoload-зависимый API (GameData/CityData игрового процесса),
# потому что в `--script`-режиме autoload-цепочка не поднимается (см.
# developer_diary, «Багфикс: ...»): для интеграционной проверки нужен
# реальный запуск сцены (полный headless-проход уже сделал вручную и в
# short headless-прогоне на 240 кадров — ошибок парсинга и SCRIPT ERROR нет).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    var state: Dictionary = {"failed": false}

    var cd = load("res://scripts/CityData.gd").new()
    cd.treasury = 0

    # ---- 1) Накопление в текущем окне ----
    cd.record_treasury_income("Рыбак", 5)
    cd.record_treasury_income("Рыбак", 3)
    cd.record_treasury_income("Все жители", 7)
    cd.record_treasury_expense("Разведка", 12)

    check(int(cd.treasury_income_accum.get("Рыбак", 0)) == 8,
        "accum Рыбак: ожидалось 8, получено %d" % int(cd.treasury_income_accum.get("Рыбак", 0)), state)
    check(int(cd.treasury_income_accum.get("Все жители", 0)) == 7,
        "accum Все жители: ожидалось 7, получено %d" % int(cd.treasury_income_accum.get("Все жители", 0)), state)
    check(int(cd.treasury_expense_accum.get("Разведка", 0)) == 12,
        "accum Разведка: ожидалось 12, получено %d" % int(cd.treasury_expense_accum.get("Разведка", 0)), state)
    check(cd.treasury_income_snapshot.is_empty(),
        "snapshot до rotate должен быть пуст", state)

    # ---- 2) rotate_treasury_window: снимок + обнуление ----
    cd.rotate_treasury_window()
    check(int(cd.treasury_income_snapshot.get("Рыбак", 0)) == 8,
        "snapshot Рыбак после rotate: ожидалось 8, получено %d" % int(cd.treasury_income_snapshot.get("Рыбак", 0)), state)
    check(int(cd.treasury_income_snapshot.get("Все жители", 0)) == 7,
        "snapshot Все жители после rotate: ожидалось 7, получено %d" % int(cd.treasury_income_snapshot.get("Все жители", 0)), state)
    check(int(cd.treasury_expense_snapshot.get("Разведка", 0)) == 12,
        "snapshot Разведка после rotate: ожидалось 12, получено %d" % int(cd.treasury_expense_snapshot.get("Разведка", 0)), state)
    check(cd.treasury_income_accum.is_empty(),
        "accum после rotate должен быть пуст", state)
    check(cd.treasury_expense_accum.is_empty(),
        "accum expense после rotate должен быть пуст", state)

    # ---- 3) Дополнительное накопление после rotate — снапшот не трогается ----
    cd.record_treasury_income("Кузнец", 11)
    cd.record_treasury_expense("Разведка", 4)
    check(int(cd.treasury_income_accum.get("Кузнец", 0)) == 11,
        "новый accum Кузнец не пишется", state)
    check(int(cd.treasury_income_snapshot.get("Кузнец", 0)) == 0,
        "снимок не должен обновляться без rotate", state)
    check(int(cd.treasury_expense_snapshot.get("Разведка", 0)) == 12,
        "снимок расходов не должен обновляться без rotate", state)

    # ---- 4) Empty / zero-amount calls — no-op ----
    var income_before: Dictionary = cd.treasury_income_accum.duplicate()
    var expense_before: Dictionary = cd.treasury_expense_accum.duplicate()
    cd.record_treasury_income("", 5) # пустое имя — игнор
    cd.record_treasury_income("X", 0) # 0 — игнор
    cd.record_treasury_expense("", 5)
    cd.record_treasury_expense("Y", 0)
    check(cd.treasury_income_accum == income_before,
        "после no-op вызовов income_accum не должен меняться", state)
    check(cd.treasury_expense_accum == expense_before,
        "после no-op вызовов expense_accum не должен меняться", state)

    # ---- 5) DEFAULT_TREASURY_WINDOW_SEC ----
    check(cd.DEFAULT_TREASURY_WINDOW_SEC == 3.0,
        "DEFAULT_TREASURY_WINDOW_SEC: ожидалось 3.0, получено %s" % str(cd.DEFAULT_TREASURY_WINDOW_SEC), state)

    # ---- 6) Возврат (refund) неттируется внутри источника расхода ----
    # В иерархической разбивке казны возврат освоения чанка не выделен в
    # отдельный источник дохода (там только «Потребление населения»), а
    # отнимается от gross-расхода «Освоение чанков». Тултип показывает
    # net-сумму со знаком «−», refund не вылезает отдельной строкой.
    var cd2 = load("res://scripts/CityData.gd").new()
    cd2.treasury = 0
    cd2.record_treasury_expense("Освоение чанков", 25)  # заплатили
    cd2.record_treasury_expense("Освоение чанков", -10) # стройка не стартанула → возврат
    cd2.rotate_treasury_window()
    var net_expansion := int(cd2.treasury_expense_snapshot.get("Освоение чанков", 0))
    check(net_expansion == 15,
        "нето-расход после возврата: ожидалось 15, получено %d" % net_expansion, state)
    # «Чистый» возврат без компенсирующей траты тоже не падает: запись с
    # amount < 0 уходит в тот же источник, после чего rotate фиксирует
    # снимок с отрицательным значением; в тултипе такие источники скрыты,
    # потому что у игрока всё равно нет расхода — это видно по самому факту.
    var cd3 = load("res://scripts/CityData.gd").new()
    cd3.record_treasury_expense("Освоение чанков", -10)
    cd3.rotate_treasury_window()
    check(int(cd3.treasury_expense_snapshot.get("Освоение чанков", 0)) == -10,
        "чистый возврат без траты: ожидалось -10, получено %d" % int(cd3.treasury_expense_snapshot.get("Освоение чанков", 0)), state)

    if state.failed:
        print("FAIL")
        quit(1)
    else:
        print("TREASURY BREAKDOWN TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if cond:
        return
    state.failed = true
    print("FAIL: %s" % msg)
