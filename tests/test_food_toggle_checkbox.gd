# Headless test of the food toggle of the "Resources" tab (resources_tab.gd):
#   godot --headless --path . --script res://tests/test_food_toggle_checkbox.gd
#
# A food row carries a standard CheckBox — the same widget as the consumption toggle of
# the "Trade" tab — and it is the only owner of the state in the row:
#   1. the row holds a CheckBox (not a hand-drawn marker), its state follows city_food_pool;
#   2. the toggle writes the new state into city_food_pool and asks the city interface to
#      recount the food row of the top strip;
#   3. a refresh from the model (update_values) moves the box without echoing the change
#      back — a programmatic button_pressed emits toggled too.
extends SceneTree

# Without the watchdog a broken coroutine inside _run() looks like a silent hang
# from the outside. See tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# The city interface stub: the tab talks to its parent through update_food_label().
class StubCity extends Node:
    var food_label_calls := 0

    func update_food_label():
        food_label_calls += 1

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()

    var parent := StubCity.new()
    get_root().add_child(parent)
    var list := VBoxContainer.new()
    parent.add_child(list)

    var tab = load("res://scripts/resources_tab.gd").new()
    tab.setup(list, null)
    parent.add_child(tab)

    var pid := "test_food"
    tab.products = {pid: {"name": "Test food", "category": "food"}}
    tab.city_storage = {pid: 100}
    tab.city_food_pool = {pid: true}
    tab.refresh()

    var toggles: Dictionary = tab.get_food_toggles()
    check(toggles.has(pid), "a food row must have a toggle", state)
    if not toggles.has(pid):
        _finish(state)
        return

    var box = toggles[pid]
    check(box is CheckBox, "the food toggle must be a standard CheckBox (got %s)"
        % (box.get_class() if box != null else "null"), state)
    check(box != null and box.button_pressed,
        "the box must be checked while the product is in the food pool", state)
    # The "off" state has to be visible on the dark panel: the theme answers the empty box with
    # its own light icon, since the built-in one is a dark square on a dark background.
    var theme := ThemeDB.get_project_theme()
    check(theme != null and theme.has_icon("unchecked", "CheckBox"),
        "the theme must define CheckBox/icons/unchecked", state)
    if not (box is CheckBox):
        _finish(state)
        return

    # 2. A click: the box writes the state itself.
    box.button_pressed = false
    check(tab.city_food_pool.get(pid, true) == false,
        "unchecking the box must remove the product from the food pool", state)
    check(parent.food_label_calls == 1,
        "the toggle must ask the city interface to recount the food (calls: %d)"
            % parent.food_label_calls, state)

    box.button_pressed = true
    check(tab.city_food_pool.get(pid, false) == true,
        "checking the box must put the product back into the food pool", state)
    check(parent.food_label_calls == 2,
        "every toggle must reach update_food_label() (calls: %d)"
            % parent.food_label_calls, state)

    # 3. The model moves the box, and the move does not echo back as a user edit.
    tab.city_food_pool[pid] = false
    tab.update_values()
    check(box.button_pressed == false,
        "update_values() must uncheck the box when the pool lost the product", state)
    check(parent.food_label_calls == 2,
        "a refresh from the model must not echo the change back as a click (calls: %d)"
            % parent.food_label_calls, state)

    tab.city_food_pool[pid] = true
    tab.update_values()
    check(box.button_pressed == true,
        "update_values() must check the box when the pool got the product back", state)

    _finish(state)

func _finish(state: Dictionary) -> void:
    if state["failed"]:
        print("FOOD TOGGLE TEST FAILED")
        quit(1)
    else:
        print("FOOD TOGGLE TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    push_error("ASSERT: " + message)
    print("ASSERT FAILED: ", message)
    state["failed"] = true
