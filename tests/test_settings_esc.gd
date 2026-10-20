# Headless test of closing the settings window with ESC:
#   godot --headless --path . --script res://tests/test_settings_esc.gd
#
# The settings window is reached from the pause menu, that is, over a PAUSED
# tree: a pausable node stops receiving input while the simulation is stopped,
# so ESC used to reach nobody at all (the pause menu is hidden under the
# settings window, and InputHandler does not answer to a paused tree).
#
# Checks (a live pause menu, res://scenes/pause_menu.tscn, the game paused —
# exactly as in a game):
#   1) clicking "Settings" hides the pause menu and shows the settings window,
#      the game stays paused;
#   2) ESC closes the settings window and returns the pause menu over it, the
#      game stays paused (the window must not swallow the pause with itself);
#   3) ESC on an already hidden settings window does nothing — the key belongs
#      to the pause menu that is visible again;
#   4) a settings window that does not belong to the pause menu (the one from
#      the main menu) is closed by ESC as well, and a hidden one ignores it.
extends SceneTree

# Hang watchdog: without it, an interrupted _run() coroutine looks from the
# outside like eternal silence. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    await process_frame

    # --- 1. The settings window over the pause menu: the tree is paused ---
    # pause_menu._on_settings() hands the instance to its parent (main_map in a
    # game); a stub with that one property stands in for the map here.
    var host := _make_game_host()
    get_root().add_child(host)
    var pause_menu = load("res://scenes/pause_menu.tscn").instantiate()
    host.add_child(pause_menu)
    await process_frame
    await process_frame

    # The pause menu opens only together with pausing the game (main_map.open_pause_menu).
    paused = true
    pause_menu.show()
    await process_frame

    var settings_btn: Button = pause_menu.find_child("SettingsButton", true, false)
    check(settings_btn != null, "1: the SettingsButton is found", state)
    settings_btn.pressed.emit()
    await process_frame

    var settings: Control = pause_menu.settings_menu_instance
    check(settings != null and settings.visible,
        "1: the settings window is shown over the pause menu", state)
    check(not pause_menu.visible,
        "1: the pause menu is hidden while the settings window is open", state)
    check(paused, "1: the game is still paused", state)
    check(settings.process_mode == Node.PROCESS_MODE_ALWAYS,
        "1: the settings window answers input while the game is paused", state)

    # --- 2. ESC closes the settings window and returns the pause menu ---
    settings._unhandled_input(_esc_event())
    await process_frame
    check(not settings.visible, "2: ESC closed the settings window", state)
    check(pause_menu.visible, "2: the pause menu returned", state)
    check(paused, "2: the game stayed paused", state)

    # --- 3. ESC on the hidden settings window belongs to the pause menu ---
    # (the pause menu handles its own ESC — the hidden settings must not swallow it)
    settings._unhandled_input(_esc_event())
    await process_frame
    check(pause_menu.visible and paused,
        "3: a second ESC on a hidden settings window left the pause menu in place", state)

    pause_menu.queue_free()
    host.queue_free()
    await process_frame

    # --- 4. A settings window without a host (the main menu one) ---
    var free_settings = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(free_settings)
    await process_frame
    check(free_settings.visible, "4: the settings window opens", state)
    free_settings._unhandled_input(_esc_event())
    await process_frame
    check(not free_settings.visible, "4: ESC closed the settings window", state)
    free_settings._unhandled_input(_esc_event())
    await process_frame
    check(not free_settings.visible, "4: ESC on a hidden settings window does nothing", state)
    free_settings.queue_free()
    await process_frame

    if state["failed"]:
        print("SETTINGS ESC TEST FAILED")
        quit(1)
        return
    print("SETTINGS ESC TEST OK")
    quit(0)

func _esc_event() -> InputEventKey:
    var event := InputEventKey.new()
    event.keycode = KEY_ESCAPE
    event.pressed = true
    return event

# pause_menu._on_settings() writes the instance into its parent as
# `settings_menu` (main_map in a game); a stub with that property is enough for
# the menu to run the very same path it runs in a game.
func _make_game_host() -> Node:
    var script := GDScript.new()
    script.source_code = "extends Node\nvar settings_menu = null\n"
    script.reload()
    var node := Node.new()
    node.set_script(script)
    node.name = "GameHost"
    return node

func check(cond: bool, msg: String, state: Dictionary):
    if cond:
        print("OK: ", msg)
    else:
        state["failed"] = true
        push_error("ASSERT FAILED: " + msg)
        print("ASSERT FAILED: ", msg)
