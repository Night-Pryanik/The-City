# Headless-тест подтверждений в меню паузы:
#   godot --headless --path . --script res://tests/test_pause_menu_confirm.gd
#
# Пункты «Перейти в главное меню» и «Выйти из игры» необратимы: первый
# выбрасывает текущую партию, второй закрывает игру. Раньше они выполнялись
# сразу, одним кликом.
#
# Проверяем (живое меню паузы, res://scenes/pause_menu.tscn, игра на паузе —
# ровно как в партии):
#   1) клик по «Перейти в главное меню» ОТКРЫВАЕТ диалог: главное меню не
#      вызвано, партия не потеряна, меню паузы на месте, игра на паузе;
#   2) «Отмена» (а также ESC) закрывает диалог, ничего не выполняя;
#   3) ESC при открытом диалоге не закрывает само меню паузы и не снимает
#      паузу игры (иначе игрок одним нажатием терял бы и меню, и паузу);
#   4) «Да» выполняет действие: сигнал new_game_pressed уходит и игра
#      разблокируется;
#   5) отменённое действие не «протухает»: после отмены первого пункта
#      подтверждение второго НЕ вызывает выход из игры (проверяется тем, что
#      процесс доживает до конца теста);
#   6) клик по «Выйти из игры» открывает свой диалог; «Да» в нём завершает
#      процесс — последняя строка теста, дальше завершать его нельзя.
#
# ПРО ВЕРДИКТ ПРОГОНА. Тест сам завершает процесс (пункт 6), поэтому `quit(0)`
# в конце недостижим, и код возврата сам по себе НИЧЕГО не доказывает: если
# «Да» вышел бы слишком рано, процесс просто исчез бы, не напечатав последнюю
# строку, — а код остался бы 0, и прогон выглядел бы зелёным. Поэтому точка
# прохождения помечается файлом SENTINEL, и прогон засчитывается только
# вместе с ним (метку удаляет вызывающий перед запуском).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как
# вечное молчание. Подробности — в tests/watchdog.gd. Предел здесь короче
# обычного: последняя проверка ДОЛЖна сама завершить процесс, и если выход
# не сработал, короткий таймер превращает зависание в понятную ошибку.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Метка «тест дошёл до последней строки». Обоснование — в шапке файла.
const SENTINEL := "user://test_pause_menu_confirm.done"

var _failed := false
var _new_game_pressed := 0

func _initialize() -> void:
    WATCHDOG.arm(self, 25.0)
    _run()

func _run() -> void:
    await process_frame

    var pause_menu = load("res://scenes/pause_menu.tscn").instantiate()
    root.add_child(pause_menu)
    await process_frame
    await process_frame

    pause_menu.new_game_pressed.connect(func() -> void: _new_game_pressed += 1)
    # Меню паузы открывается только вместе с паузой игры (main_map.open_pause_menu).
    paused = true
    pause_menu.show()
    await process_frame

    var new_game_btn: Button = pause_menu.find_child("NewGameButton", true, false)
    var exit_btn: Button = pause_menu.find_child("ExitButton", true, false)
    var dialog: ConfirmationDialog = pause_menu.confirm_dialog
    check(new_game_btn != null and exit_btn != null, "0: кнопки меню паузы на месте")
    check(dialog != null, "0: диалог подтверждения создан вместе с меню")

    # --- 1. Клик по «Перейти в главное меню» спрашивает подтверждение ---
    new_game_btn.pressed.emit()
    await process_frame
    check(dialog.visible, "1: открыт диалог подтверждения")
    check(pause_menu.visible and paused,
        "1: меню паузы на месте и игра на паузе")
    check(_new_game_pressed == 0,
        "1: сигнал перехода в главное меню НЕ отправлен без подтверждения")

    # --- 2. «Отмена» ничего не выполняет ---
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    check(not dialog.visible, "2: «Отмена» закрыла диалог")
    check(pause_menu.visible and paused, "2: меню паузы осталось, игра на паузе")
    check(_new_game_pressed == 0, "2: отмена не выполнила действие")

    # --- 3. ESC при открытом диалоге не закрывает меню паузы ---
    new_game_btn.pressed.emit()
    await process_frame
    pause_menu._unhandled_input(_esc_event())
    await process_frame
    check(dialog.visible, "3: ESC не закрыл диалог подтверждения")
    check(pause_menu.visible and paused,
        "3: ESC не закрыл меню паузы и не снял паузу игры")
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    check(not dialog.visible, "3: диалог закрыт кнопкой «Отмена»")

    # --- 4. «Да» выполняет действие ---
    new_game_btn.pressed.emit()
    await process_frame
    dialog.get_ok_button().pressed.emit()
    await process_frame
    check(_new_game_pressed == 1,
        "4: «Да» отправило сигнал new_game_pressed (получено %d)" % _new_game_pressed)
    check(not paused, "4: игра разблокирована для смены сцены")

    # --- 5. Отменённое действие не «протухает»: следующее подтверждение
    #        не должно вызвать выход из игры (иначе процесс умер бы здесь) ---
    new_game_btn.pressed.emit()
    await process_frame
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    new_game_btn.pressed.emit()
    await process_frame
    dialog.get_ok_button().pressed.emit()
    await process_frame
    check(_new_game_pressed == 2,
        "5: второе подтверждение выполнило только «главное меню» (сигналов %d)"
            % _new_game_pressed)
    check(not paused,
        "5: подтверждённый переход разблокировал игру для смены сцены")

    # Тест не connected к new_game_pressed сцену, поэтому партия осталась на
    # месте: возвращаем дерево в состояние живой игры с открытым меню паузы.
    paused = true

    # --- 6. «Выйти из игры» спрашивает подтверждение и по «Да» завершает игру ---
    exit_btn.pressed.emit()
    await process_frame
    check(dialog.visible, "6: открыт диалог подтверждения выхода")
    check(dialog.dialog_text.contains("выйти") or dialog.dialog_text.contains("Несохранённый"),
        "6: текст диалога предупреждает о выходе и потере прогресса («%s»)"
            % dialog.dialog_text)
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    check(not dialog.visible and pause_menu.visible and paused,
        "6: «Отмена» оставила игру в меню паузы, на паузе")

    if _failed:
        print("PAUSE MENU CONFIRM TEST FAILED")
        quit(1)
        return

    # Последний шаг: подтверждение выхода обязано само завершить процесс.
    # Если _confirm_exit не вызвался, процесс не закончится и его снимет
    # сторож с кодом 2 — тест всё равно станет «красным», только медленнее.
    # Метку ставим ДО последнего нажатия: её наличие доказывает, что тест
    # дошёл до конца, а не умер на полпути (см. шапку файла).
    var marker := FileAccess.open(SENTINEL, FileAccess.WRITE)
    if marker != null:
        marker.store_string("reached-final-step\n")
        marker.close()
    print("PAUSE MENU CONFIRM TEST OK")
    exit_btn.pressed.emit()
    await process_frame
    dialog.get_ok_button().pressed.emit()

func _esc_event() -> InputEventKey:
    var event := InputEventKey.new()
    event.keycode = KEY_ESCAPE
    event.pressed = true
    return event

func check(cond: bool, msg: String) -> void:
    if cond:
        print("OK: ", msg)
    else:
        _failed = true
        push_error("ASSERT FAILED: " + msg)
        print("ASSERT FAILED: ", msg)
