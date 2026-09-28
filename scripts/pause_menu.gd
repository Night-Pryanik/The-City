extends CanvasLayer

signal save_pressed
signal load_pressed
signal new_game_pressed

var settings_menu_instance: Control = null
var settings_canvas: CanvasLayer = null

# Диалог подтверждения для необратимых пунктов меню — «Перейти в главное
# меню» и «Выйти из игры». Один диалог на оба пункта: перед показом
# подставляются заголовок, текст и действие.
# Действие хранится в _pending_action, а не подключается к сигналу confirmed
# заново на каждый запрос: при отмене одноразовое соединение осталось бы
# висеть и сработало бы при СЛЕДУЮЩЕМ подтверждении (то есть «выход» мог бы
# сработать вместо «главного меню»).
var confirm_dialog: ConfirmationDialog = null
var _pending_action: Callable = Callable()

func _ready():
    # Меню паузы должно работать, даже когда игра приостановлена
    process_mode = Node.PROCESS_MODE_WHEN_PAUSED
    _make_confirm_dialog()

    var resume_btn = find_child("ResumeButton", true, false)
    var save_btn = find_child("SaveButton", true, false)
    var load_btn = find_child("LoadButton", true, false)
    var new_game_btn = find_child("NewGameButton", true, false)
    var exit_btn = find_child("ExitButton", true, false)
    var settings_btn = find_child("SettingsButton", true, false)

    if resume_btn: resume_btn.pressed.connect(_on_resume)
    else: printerr("ResumeButton not found in PauseMenu")

    if save_btn: save_btn.pressed.connect(_on_save)
    else: printerr("SaveButton not found in PauseMenu")

    if load_btn: load_btn.pressed.connect(_on_load)
    else: printerr("LoadButton not found in PauseMenu")

    if new_game_btn:
        # Кнопка в меню паузы всегда действует из запущенной партии:
        # вместо начала новой игры она возвращает в главное меню.
        new_game_btn.text = "Перейти в главное меню"
        new_game_btn.pressed.connect(_on_new_game)
    else: printerr("NewGameButton not found in PauseMenu")

    if exit_btn: exit_btn.pressed.connect(_on_exit)
    else: printerr("ExitButton not found in PauseMenu")

    if settings_btn: settings_btn.pressed.connect(_on_settings)
    else: printerr("SettingsButton not found in PauseMenu")

func _make_confirm_dialog():
    confirm_dialog = ConfirmationDialog.new()
    # Локализуем стандартные кнопки диалога (по умолчанию Godot показывает
    # английские «OK» / «Cancel» — проект без файлов переводов).
    confirm_dialog.get_ok_button().text = "Да"
    confirm_dialog.get_cancel_button().text = "Отмена"
    # Пока открыто меню паузы, игра стоит на паузе, поэтому диалог должен
    # принимать ввод при get_tree().paused == true.
    confirm_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
    confirm_dialog.confirmed.connect(_on_confirm_accepted)
    confirm_dialog.canceled.connect(_on_confirm_rejected)
    add_child(confirm_dialog)
    confirm_dialog.hide()

# Спрашивает подтверждение перед необратимым действием: подставляет в диалог
# заголовок и текст, запоминает действие и показывает окно. Пока диалог
# открыт, остальные пункты меню недоступны (окно перехватывает ввод), а ESC
# закрывает именно его, а не всё меню паузы (см. _unhandled_input).
func _ask_confirmation(title: String, text: String, action: Callable):
    if not confirm_dialog:
        return
    confirm_dialog.title = title
    confirm_dialog.dialog_text = text
    _pending_action = action
    confirm_dialog.popup_centered()

func _on_confirm_accepted():
    var action = _pending_action
    # Сбрасываем ДО вызова: действие может уничтожить узел (смена сцены) или
    # закрыть окно, а подтверждение не должно срабатывать повторно.
    _pending_action = Callable()
    if action.is_valid():
        action.call()

func _on_confirm_rejected():
    # Отмена, крестик и ESC одинаковы: действие просто не выполняется.
    _pending_action = Callable()

func _unhandled_input(event):
    # Обрабатываем ESC только когда меню паузы открыто (иначе событие
    # должен получить InputHandler, чтобы открыть меню)
    if not visible:
        return
    if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        # Открыт диалог подтверждения: ESC закрывает его (canceled), а меню
        # паузы остаётся на месте вместе с паузой игры.
        if confirm_dialog and confirm_dialog.visible:
            return
        if settings_menu_instance and settings_menu_instance.visible:
            # Закрываем настройки — _on_settings_menu_visibility_changed покажет меню паузы снова
            settings_menu_instance.hide()
        else:
            _close_pause_menu()

func _set_game_paused(paused: bool):
    get_tree().paused = paused

func _close_pause_menu():
    # Диалог подтверждения не должен пережить меню (иначе он остался бы
    # висеть поверх игры, если закрыть меню каким-то иным способом).
    if confirm_dialog:
        confirm_dialog.hide()
        _pending_action = Callable()
    hide()
    _set_game_paused(false)

func _on_resume():
    _close_pause_menu()

func _on_save():
    emit_signal("save_pressed")
    _close_pause_menu()

func _on_load():
    # При загрузке выходим из паузы, чтобы сцена могла перезагрузиться
    _set_game_paused(false)
    emit_signal("load_pressed")

func _on_new_game():
    # Пункт не создаёт новую партию, а возвращает в главное меню. Переход
    # необратим (текущая партия теряется), поэтому спрашиваем подтверждение.
    _ask_confirmation("Переход в главное меню",
        "Действительно выйти в главное меню? Несохранённый прогресс будет потерян.",
        _confirm_new_game)

func _confirm_new_game():
    _set_game_paused(false)
    emit_signal("new_game_pressed")

func _on_exit():
    # Выход из игры необратим и несохранённый прогресс пропадает.
    _ask_confirmation("Выход из игры",
        "Действительно выйти из игры? Несохранённый прогресс будет потерян.",
        _confirm_exit)

func _confirm_exit():
    get_tree().quit()

func _on_settings():
    if not settings_menu_instance:
        settings_canvas = CanvasLayer.new()
        add_child(settings_canvas)
        settings_menu_instance = load("res://scenes/settings_menu.tscn").instantiate()
        settings_canvas.add_child(settings_menu_instance)
        settings_menu_instance.visibility_changed.connect(_on_settings_menu_visibility_changed)

    # Передаём ссылку на этот экземпляр в main_map.gd
    var main = get_parent()
    main.settings_menu = settings_menu_instance

    hide() # прячем паузу
    settings_menu_instance.show()

func _on_settings_menu_visibility_changed():
    if settings_menu_instance and not settings_menu_instance.visible:
        # Меню настроек закрыли – показываем меню паузы снова
        show()
