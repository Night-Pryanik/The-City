# Headless test of the "About" window of the main menu:
#   godot --headless --path . --script res://tests/test_about_window.gd
#
# The window shows the author of the game, the licenses the project is published
# under and the third-party components it ships with. It is opened from the main
# menu, and it must not stay behind when it is closed — otherwise a hidden overlay
# would intercept the clicks of the menu on every later visit.
#
# We check:
#   1) the main menu has the "About" item, and it stands between "Settings" and "Quit";
#   2) the click opens the window on the scene tree root, and it shows the author,
#      both licenses and the third-party components;
#   3) ESC closes the window, and the window removes itself from the tree;
#   4) the "Close" button closes the window as well.
extends SceneTree

# Hang watchdog: without it an interrupted _run() coroutine looks from the outside like
# eternal silence. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const MENU_SCENE := "res://scenes/main_menu.tscn"
const ABOUT_SCRIPT := "res://scripts/about_window.gd"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var menu = load(MENU_SCENE).instantiate()
    get_root().add_child(menu)
    await process_frame
    await process_frame

    # --- 1. The item of the menu ---
    var about_button: Button = menu.find_child("AboutButton", true, false)
    var settings_button: Button = menu.find_child("SettingsButton", true, false)
    var quit_button: Button = menu.find_child("QuitButton", true, false)
    check(about_button != null, "1: the menu has the \"About\" item", state)
    check(about_button.text == tr("About"),
        "1: the item is captioned (got: %s)" % about_button.text, state)
    check(_order(menu, settings_button, about_button, quit_button),
        "1: the item stands between \"Settings\" and \"Quit\"", state)

    # --- 2. The click opens the window ---
    about_button.pressed.emit()
    await process_frame
    await process_frame

    var window := _find_about_window()
    check(window != null, "2: the click opens the window", state)
    if window == null:
        _finish(state)
        return

    check(window.visible, "2: the window is on the screen", state)
    var text := _collect_text(window)
    check(text.contains("Anton Burmistrov"),
        "2: the window names the author", state)
    check(text.contains("CC BY-NC-SA 4.0"),
        "2: the window names the license of the code", state)
    check(text.contains("CC BY 4.0"),
        "2: the window names the license of the artwork and the data", state)
    check(text.contains("Inter"),
        "2: the window names the bundled font", state)
    check(text.contains("Godot"),
        "2: the window names the engine", state)
    check(text.contains("creativecommons.org/licenses/by-nc-sa/4.0/"),
        "2: the window links the license of the code", state)
    check(text.contains("github.com/Night-Pryanik/The-City"),
        "2: the window links the repository", state)

    # --- 3. ESC closes the window ---
    window._input(_esc_event())
    await process_frame
    await process_frame
    check(not is_instance_valid(window) or not window.visible,
        "3: ESC closed the window", state)
    check(_find_about_window() == null,
        "3: the window removed itself from the tree", state)

    # --- 4. The "Close" button closes the window ---
    about_button.pressed.emit()
    await process_frame
    await process_frame
    window = _find_about_window()
    check(window != null, "4: the window opens again", state)
    if window != null:
        var close_button: Button = window.find_child("CloseButton", true, false)
        if close_button == null:
            # The button is the last child of the window: it is found by its caption.
            for node in window.find_children("*", "Button", true, false):
                if node.text == "Close":
                    close_button = node
                    break
        check(close_button != null, "4: the window has the \"Close\" button", state)
        if close_button != null:
            close_button.pressed.emit()
            await process_frame
            await process_frame
            check(_find_about_window() == null,
                "4: the \"Close\" button closed the window", state)

    get_root().remove_child(menu)
    menu.free()
    _finish(state)

# The order of three items of the menu: the first of them comes before the second,
# and the second before the third.
func _order(menu: Node, first: Node, second: Node, third: Node) -> bool:
    if first == null or second == null or third == null:
        return false
    var box := menu.find_child("VBoxContainer", true, false)
    if box == null:
        return false
    var children := box.get_children()
    var a := children.find(first)
    var b := children.find(second)
    var c := children.find(third)
    return a >= 0 and b > a and c > b

# The window of the "About": it is added to the scene tree root, and it is found by
# its script — the window has no name of its own.
func _find_about_window() -> Node:
    for child in get_root().get_children():
        var script: Script = child.get_script()
        if script != null and script.resource_path == ABOUT_SCRIPT:
            return child
    return null

# Every word of the window, in one string.
#
# The tree is walked by hand: find_children() skips the nodes that were built by the
# code (they have no owner), and the window is built by the code.
func _collect_text(node: Node) -> String:
    var parts: Array[String] = []
    _collect_into(node, parts)
    return "\n".join(parts)

func _collect_into(node: Node, parts: Array[String]) -> void:
    for child in node.get_children():
        if child is RichTextLabel or child is Label:
            parts.append(str(child.text))
        _collect_into(child, parts)

func _esc_event() -> InputEventKey:
    var event := InputEventKey.new()
    event.keycode = KEY_ESCAPE
    event.pressed = true
    return event

func _finish(state: Dictionary) -> void:
    if state["failed"]:
        print("ABOUT WINDOW TEST FAILED")
        quit(1)
    else:
        print("ABOUT WINDOW TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if cond:
        print("OK: ", msg)
    else:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
