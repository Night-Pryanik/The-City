# Headless test of "Continue game" in the main menu:
#   godot --headless --path . --script res://tests/test_main_menu_continue.gd
#
# Covers:
#   1. The item is the FIRST of the menu and is gated by the same fact as "Load game":
#      no saves — no button.
#   2. The tooltip describes the save the click will take — the place chosen last,
#      otherwise the newest — and follows the storage: once the last save is deleted the
#      button goes dead.
#
# The click itself is not simulated: it changes the scene, which would start a whole map
# generation inside the test process. What the click does — load_game() without an id —
# is asserted directly.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const MENU_SCENE := "res://scenes/main_menu.tscn"

const SLOT_OLD := "test_menu_old"
const SLOT_NEW := "test_menu_new"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    var last_slot_backup := str(save_manager.last_slot_id)
    save_manager.delete_save(SLOT_OLD)
    save_manager.delete_save(SLOT_NEW)

    # The runner gives every test its own APPDATA, so the process starts with no saves.
    # A direct run on a machine that has them starts with the button alive instead.
    var empty_start: bool = save_manager.list_saves().is_empty()
    save_manager._store_last_slot("")

    var menu = load(MENU_SCENE).instantiate()
    get_root().add_child(menu)
    await process_frame

    var continue_button = menu.continue_button
    check(continue_button != null, "the menu has the continue item", state)
    check(menu.get_node("VBoxContainer").get_child(0) == continue_button,
        "the continue item is the first of the menu", state)
    check(continue_button.text == "Continue game",
        "the item is captioned (got: %s)" % continue_button.text, state)

    if empty_start:
        check(continue_button.disabled, "with no saves the item is dead", state)
        check(continue_button.tooltip_text.is_empty(),
            "a dead item promises nothing (got: %s)" % continue_button.tooltip_text, state)

    # Two saves of different ages: the newer one is the one "Continue" takes when the
    # player has not chosen anything yet. The moments lie in the future, so that the
    # saves of the player himself never outrank them in a direct run.
    var now := int(Time.get_unix_time_from_system())
    save_manager.write_slot(SLOT_OLD, _slot_data(SLOT_OLD, "Old game", now + 1000))
    save_manager.write_slot(SLOT_NEW, _slot_data(SLOT_NEW, "New game", now + 2000))
    menu._refresh_save_buttons()
    check(not continue_button.disabled, "with a save the item is alive", state)
    var tooltip: String = continue_button.tooltip_text
    check(tooltip.contains("New game"),
        "the tooltip names the newest save (got: %s)" % tooltip, state)
    check(tooltip.contains("City: Paris"), "the tooltip names the city (got: %s)" % tooltip, state)
    check(tooltip.contains("Era: Antiquity"), "the tooltip names the era (got: %s)" % tooltip, state)
    check(tooltip.contains("Population: 128"),
        "the tooltip names the population (got: %s)" % tooltip, state)
    check(tooltip.contains("Saved: "), "the tooltip names the moment (got: %s)" % tooltip, state)
    check(tooltip.split("\n").size() == 5,
        "the tooltip is one fact per line (got: %d)" % tooltip.split("\n").size(), state)

    # The place chosen last wins over the newest: the button keeps its promise.
    save_manager._store_last_slot(SLOT_OLD)
    menu._refresh_save_buttons()
    check(continue_button.tooltip_text.contains("Old game"),
        "the tooltip follows the place chosen last (got: %s)" % continue_button.tooltip_text, state)

    # The click loads exactly that save: the same call, without an id.
    var resume = save_manager.get_resume_save()
    check(str(resume.get("id", "")) == SLOT_OLD,
        "the button describes the save the load takes (got: %s)" % str(resume.get("id", "")), state)
    check(save_manager.load_game(), "the continue path reads a save", state)
    check(str(save_manager.saved_data.get("city_name", "")) == "Paris",
        "the state of that save is in saved_data", state)

    # The saves are gone — the item must go dead with them.
    save_manager.delete_save(SLOT_OLD)
    save_manager.delete_save(SLOT_NEW)
    menu._refresh_save_buttons()
    var remaining: bool = not save_manager.get_resume_save().is_empty()
    check(continue_button.disabled == not remaining,
        "the item follows the storage (disabled: %s, save left: %s)"
            % [str(continue_button.disabled), str(remaining)], state)

    get_root().remove_child(menu)
    menu.free()
    save_manager._store_last_slot(last_slot_backup)

    if state["failed"]:
        print("MAIN MENU CONTINUE TEST FAILED")
        quit(1)
    else:
        print("MAIN MENU CONTINUE TEST OK")
        quit(0)

# A save as the menu sees it, without a running map.
func _slot_data(slot_id: String, save_name: String, saved_at: int) -> Dictionary:
    return {
        "city_name": "Paris",
        "current_era_index": 1,
        "total_population": 128,
        "_meta": {
            "id": slot_id,
            "name": save_name,
            "city_name": "Paris",
            "saved_at": saved_at,
            "era_index": 1,
            "population": 128
        }
    }

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
