extends CanvasLayer

signal save_pressed
signal load_pressed
signal new_game_pressed

var settings_menu_instance: Control = null
var settings_canvas: CanvasLayer = null

# A confirmation dialog for irreversible menu items — "Return to the main
# menu" and "Exit the game". One dialog for both items: the title, the text
# and the action are substituted before showing.
# The action is stored in _pending_action, and not re-connected to the confirmed
# signal on every request: on cancel a one-shot connection would remain
# hanging and would fire on the NEXT confirmation (that is, "exit" could
# fire instead of "main menu").
var confirm_dialog: ConfirmationDialog = null
var _pending_action: Callable = Callable()

func _ready():
    # The pause menu must work even when the game is paused
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
        # The button in the pause menu always works from a running game:
        # instead of starting a new game, it returns to the main menu.
        new_game_btn.text = tr("Return to main menu")
        new_game_btn.pressed.connect(_on_new_game)
    else: printerr("NewGameButton not found in PauseMenu")

    if exit_btn: exit_btn.pressed.connect(_on_exit)
    else: printerr("ExitButton not found in PauseMenu")

    if settings_btn: settings_btn.pressed.connect(_on_settings)
    else: printerr("SettingsButton not found in PauseMenu")

func _make_confirm_dialog():
    confirm_dialog = ConfirmationDialog.new()
    # We localize the standard dialog buttons (by default Godot shows
    # the English "OK" / "Cancel" — a project without translation files).
    confirm_dialog.get_ok_button().text = tr("Yes")
    confirm_dialog.get_cancel_button().text = tr("Cancel")
    # While the pause menu is open, the game is paused, so the dialog must
    # accept input when get_tree().paused == true.
    confirm_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
    confirm_dialog.confirmed.connect(_on_confirm_accepted)
    confirm_dialog.canceled.connect(_on_confirm_rejected)
    add_child(confirm_dialog)
    confirm_dialog.hide()

# Asks for confirmation before an irreversible action: substitutes the title
# and the text into the dialog, remembers the action and shows the window.
# While the dialog is open, the other menu items are unavailable (the window
# intercepts the input), and ESC closes exactly it, and not the whole pause
# menu (see _unhandled_input).
func _ask_confirmation(title: String, text: String, action: Callable):
    if not confirm_dialog:
        return
    confirm_dialog.title = title
    confirm_dialog.dialog_text = text
    _pending_action = action
    confirm_dialog.popup_centered()

func _on_confirm_accepted():
    var action = _pending_action
    # We reset BEFORE the call: the action may destroy the node (a scene change) or
    # close the window, and the confirmation must not fire again.
    _pending_action = Callable()
    if action.is_valid():
        action.call()

func _on_confirm_rejected():
    # Cancel, the cross and ESC are all the same: the action simply is not performed.
    _pending_action = Callable()

func _unhandled_input(event):
    # We handle ESC only when the pause menu is open (otherwise the event
    # must be received by InputHandler in order to open the menu)
    if not visible:
        return
    if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        # The confirmation dialog is open: ESC closes it (canceled), and the pause
        # menu stays in place along with the game pause.
        if confirm_dialog and confirm_dialog.visible:
            return
        if settings_menu_instance and settings_menu_instance.visible:
            # We close the settings — _on_settings_menu_visibility_changed will show the pause menu again
            settings_menu_instance.hide()
        else:
            _close_pause_menu()

func _set_game_paused(paused: bool):
    get_tree().paused = paused

func _close_pause_menu():
    # The confirmation dialog must not outlive the menu (otherwise it would remain
    # hanging over the game if the menu is closed in some other way).
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
    # On load we exit the pause, so that the scene can reload
    _set_game_paused(false)
    emit_signal("load_pressed")

func _on_new_game():
    # The item does not create a new game, but returns to the main menu. The transition
    # is irreversible (the current game is lost), therefore we ask for confirmation.
    _ask_confirmation(tr("Return to main menu"),
        tr("Really return to the main menu?\nUnsaved progress will be lost."),
        _confirm_new_game)

func _confirm_new_game():
    _set_game_paused(false)
    emit_signal("new_game_pressed")

func _on_exit():
    # Exiting the game is irreversible and the unsaved progress is lost.
    _ask_confirmation(tr("Exit game"),
        tr("Really exit the game?\nUnsaved progress will be lost."),
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

    # We pass a reference to this instance to main_map.gd
    var main = get_parent()
    main.settings_menu = settings_menu_instance

    hide() # we hide the pause
    settings_menu_instance.show()

func _on_settings_menu_visibility_changed():
    if settings_menu_instance and not settings_menu_instance.visible:
        # The settings menu was closed – we show the pause menu again
        show()
