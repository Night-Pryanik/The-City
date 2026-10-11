# Headless test of confirmations in the pause menu:
#   godot --headless --path . --script res://tests/test_pause_menu_confirm.gd
#
# The "Return to the main menu" and "Exit the game" items are irreversible: the first
# discards the current game, the second closes the game. Previously they were performed
# immediately, with a single click.
#
# We check (a live pause menu, res://scenes/pause_menu.tscn, the game paused —
# exactly as in a game):
#   1) clicking "Return to the main menu" OPENS the dialog: the main menu is not
#      invoked, the game is not lost, the pause menu is still there, the game is paused;
#   2) "Cancel" (and ESC as well) closes the dialog without performing anything;
#   3) ESC with the dialog open does not close the pause menu itself and does not
#      unpause the game (otherwise the player would lose both the menu and the pause with one press);
#   4) "Yes" performs the action: the new_game_pressed signal is emitted and the game
#      is unblocked;
#   5) a cancelled action does not "go stale": after cancelling the first item,
#      confirming the second does NOT cause the game to exit (this is checked by the fact
#      that the process survives to the end of the test);
#   6) clicking "Exit the game" opens its own dialog; "Yes" in it terminates the
#      process — the last line of the test, it must not be terminated after that.
#
# ABOUT THE RUN VERDICT. The test terminates the process itself (item 6), so `quit(0)`
# at the end is unreachable, and the return code alone proves NOTHING: if
# "Yes" exited too early, the process would simply disappear without printing the last
# line — and the code would stay 0, and the run would look green. Therefore the
# passing point is marked with a SENTINEL file, and the run is counted only
# together with it (the caller removes the marker before starting).
extends SceneTree

# Hang watchdog: without it, an interrupted _run() coroutine looks from the outside like
# eternal silence. Details — in tests/watchdog.gd. The limit here is shorter than
# usual: the last check MUST terminate the process itself, and if the exit
# did not work, a short timer turns the hang into a clear error.
const WATCHDOG = preload("res://tests/watchdog.gd")

# The marker "the test reached the last line". The rationale is in the file header.
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
    # The pause menu opens only together with pausing the game (main_map.open_pause_menu).
    paused = true
    pause_menu.show()
    await process_frame

    var new_game_btn: Button = pause_menu.find_child("NewGameButton", true, false)
    var exit_btn: Button = pause_menu.find_child("ExitButton", true, false)
    var dialog: ConfirmationDialog = pause_menu.confirm_dialog
    check(new_game_btn != null and exit_btn != null, "0: the pause menu buttons are present")
    check(dialog != null, "0: the confirmation dialog is created together with the menu")

    # --- 1. Clicking "Return to the main menu" asks for confirmation ---
    new_game_btn.pressed.emit()
    await process_frame
    check(dialog.visible, "1: the confirmation dialog is open")
    check(pause_menu.visible and paused,
        "1: the pause menu is present and the game is paused")
    check(_new_game_pressed == 0,
        "1: the return-to-main-menu signal is NOT sent without confirmation")

    # --- 2. "Cancel" performs nothing ---
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    check(not dialog.visible, "2: \"Cancel\" closed the dialog")
    check(pause_menu.visible and paused, "2: the pause menu remained, the game is paused")
    check(_new_game_pressed == 0, "2: the cancel did not perform the action")

    # --- 3. ESC with the dialog open does not close the pause menu ---
    new_game_btn.pressed.emit()
    await process_frame
    pause_menu._unhandled_input(_esc_event())
    await process_frame
    check(dialog.visible, "3: ESC did not close the confirmation dialog")
    check(pause_menu.visible and paused,
        "3: ESC did not close the pause menu and did not unpause the game")
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    check(not dialog.visible, "3: the dialog was closed by the \"Cancel\" button")

    # --- 4. "Yes" performs the action ---
    new_game_btn.pressed.emit()
    await process_frame
    dialog.get_ok_button().pressed.emit()
    await process_frame
    check(_new_game_pressed == 1,
        "4: \"Yes\" sent the new_game_pressed signal (received %d)" % _new_game_pressed)
    check(not paused, "4: the game is unblocked for the scene change")

    # --- 5. A cancelled action does not "go stale": the next confirmation
    #        must not cause the game to exit (otherwise the process would die here) ---
    new_game_btn.pressed.emit()
    await process_frame
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    new_game_btn.pressed.emit()
    await process_frame
    dialog.get_ok_button().pressed.emit()
    await process_frame
    check(_new_game_pressed == 2,
        "5: the second confirmation performed only \"main menu\" (signals %d)"
            % _new_game_pressed)
    check(not paused,
        "5: the confirmed transition unblocked the game for the scene change")

    # The test did not connect the scene to new_game_pressed, so the game stayed in
    # place: we return the tree to the state of a live game with the pause menu open.
    paused = true

    # --- 6. "Exit the game" asks for confirmation and on "Yes" terminates the game ---
    exit_btn.pressed.emit()
    await process_frame
    check(dialog.visible, "6: the exit confirmation dialog is open")
    check(dialog.dialog_text.contains("exit") or dialog.dialog_text.contains("Unsaved"),
        "6: the dialog text warns about exiting and losing progress (\"%s\")"
            % dialog.dialog_text)
    dialog.get_cancel_button().pressed.emit()
    await process_frame
    check(not dialog.visible and pause_menu.visible and paused,
        "6: \"Cancel\" left the game in the pause menu, paused")

    if _failed:
        print("PAUSE MENU CONFIRM TEST FAILED")
        quit(1)
        return

    # The last step: the exit confirmation must terminate the process itself.
    # If _confirm_exit was not called, the process will not end and the
    # watchdog will take it down with code 2 — the test will still turn "red", only slower.
    # We set the marker BEFORE the last press: its presence proves that the test
    # reached the end and did not die halfway (see the file header).
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
