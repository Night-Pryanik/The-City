# Headless-тест «залипания» тултипа разбивки казны:
#   godot --headless --path "E:\The City" --script res://tools/test_treasury_tooltip_pin.gd
#
# Тултип разбивки казны (HUD карты и верхняя полоса CityUI) использует один и
# тот же ui_helpers.show_treasury_tooltip. Поведение при наведении — как у
# тултипа деталей здания: после задержки панель фиксируется на месте, и курсор
# можно перевести на сам тултип. Технически это живёт на паре «показ при
# залипании без keep_position» + «live-update на смене ресурсной эпохи с
# keep_position=true»: вторая перерисовка не должна сдвигать панель.
#
# Проверяем:
#   1) первичный показ — панель у курсора (+15, +15);
#   2) keep_position=true при другом положении курсора — панель НЕ двигается,
#      но содержимое обновляется;
#   3) без keep_position панель снова следует за курсором;
#   4) keep_position=true на скрытой панели «якорем» не работает — обычный
#      показ у курсора (иначе тултип «выпрыгивал» бы в старом месте);
#   5) пустая разбивка панель скрывает (залипать нечему).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _failed := false

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    await process_frame

    var holder := Control.new()
    root.add_child(holder)
    var ui = load("res://scripts/ui_helpers.gd").new()
    ui.setup(holder, Label.new())
    holder.add_child(ui)
    await process_frame
    await process_frame

    var panel: Panel = ui.treasury_tooltip_panel
    var vbox: VBoxContainer = ui.treasury_tooltip_vbox

    # --- 1. Первичная отрисовка: панель появляется у курсора ---
    ui.show_treasury_tooltip(Vector2(100, 100), 42, _income_one_source(), {}, 3.0)
    await process_frame
    await process_frame
    check(panel.visible, "1: тултип виден после первичной отрисовки")
    check(panel.position == Vector2(115, 115),
        "1: панель у курсора (+15, +15), факт %s" % str(panel.position))
    var locked_pos: Vector2 = panel.position
    var rows_before: int = vbox.get_child_count()

    # --- 2. Live-update «залипшего» тултипа: панель стоит на месте ---
    ui.show_treasury_tooltip(Vector2(300, 250), 42, _income_two_sources(), {}, 3.0, true)
    await process_frame
    await process_frame
    check(panel.visible, "2: тултип виден после live-update")
    check(panel.position == locked_pos,
        "2: keep_position сохраняет место панели (%s → %s)"
            % [str(locked_pos), str(panel.position)])
    check(vbox.get_child_count() > rows_before,
        "2: содержимое обновилось (строк %d → %d)"
            % [rows_before, vbox.get_child_count()])

    # --- 3. Обычный показ (без keep_position) идёт за курсором ---
    ui.show_treasury_tooltip(Vector2(200, 200), 42, _income_one_source(), {}, 3.0)
    await process_frame
    check(panel.position == Vector2(215, 215),
        "3: без keep_position панель следует за курсором, факт %s" % str(panel.position))

    # --- 4. keep_position на скрытой панели: якоря нет ---
    ui.hide_treasury_tooltip()
    await process_frame
    check(not panel.visible, "4: тултип скрыт")
    ui.show_treasury_tooltip(Vector2(250, 220), 42, _income_one_source(), {}, 3.0, true)
    await process_frame
    check(panel.visible, "4: тултип показан заново")
    check(panel.position == Vector2(265, 235),
        "4: без видимой панели keep_position не «якорит», факт %s" % str(panel.position))

    # --- 5. Пустая разбивка: панель скрывается ---
    ui.show_treasury_tooltip(Vector2(250, 220), 0, {}, {}, 3.0, true)
    await process_frame
    check(not panel.visible, "5: пустая разбивка скрывает панель")
    check(vbox.get_child_count() == 0, "5: содержимое пустой разбивки очищено")

    # --- 6. Расходы без дохода: панель показывается и тоже залипает ---
    ui.show_treasury_tooltip(Vector2(120, 140), 7, {}, {"Разведка": 12}, 3.0)
    await process_frame
    check(panel.visible, "6: тултип только с расходами виден")
    check(panel.position == Vector2(135, 155),
        "6: панель у курсора, факт %s" % str(panel.position))
    var exp_pos: Vector2 = panel.position
    ui.show_treasury_tooltip(Vector2(600, 400), 7, {}, {"Разведка": 12}, 3.0, true)
    await process_frame
    check(panel.position == exp_pos,
        "6: расходный тултип тоже держит место (%s → %s)"
            % [str(exp_pos), str(panel.position)])

    if _failed:
        print("TREASURY TOOLTIP PIN TEST FAILED")
        quit(1)
    else:
        print("TREASURY TOOLTIP PIN TEST OK")
        quit(0)

# Карта дохода в формате worker_manager.get_actual_treasury_income_map():
# тип → источник → продукт → { coins_per_sec, product_name }.
func _income_one_source() -> Dictionary:
    return {
        "Потребление населения": {
            "Все жители": {
                "fish": {"coins_per_sec": 3.0, "product_name": "Рыба"}
            }
        }
    }

func _income_two_sources() -> Dictionary:
    var income: Dictionary = _income_one_source()
    income["Потребление населения"]["Рыбак"] = {
        "fish": {"coins_per_sec": 2.0, "product_name": "Рыба"}
    }
    return income

func check(cond: bool, msg: String) -> void:
    if cond:
        print("OK: ", msg)
    else:
        _failed = true
        push_error("ASSERT FAILED: " + msg)
        print("ASSERT FAILED: ", msg)
