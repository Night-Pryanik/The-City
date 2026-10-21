# Headless test of the window of the saves on the LIVE map:
#   godot --headless --path . --script res://tests/test_save_window_live.gd
#
# The fast test (tests/test_save_slots.gd) covers the storage and the window on a bare
# tree. This one covers the wiring that only the real scene has:
#   1. The "Save game" item of the pause menu opens the window OVER the menu, and the
#      game stays stopped: the player comes back to the menu, not to the map.
#   2. The save goes to the chosen slot under the typed name, and the window is closed
#      afterwards while the menu is still open.
#   3. The place saved last is preselected on the next opening, and the "Load game"
#      item opens the same window in the list mode.
#
# The test writes its own slots and removes them afterwards, and puts the place the
# player selected last back: it must not eat a real game.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const TEST_NAME := "window test"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    var city_data = get_root().get_node("CityData")
    var last_slot_backup := str(save_manager.last_slot_id)
    _delete_test_slots(save_manager)
    save_manager.new_game()
    # The name is given by the main menu on a real start; the test plays that role.
    city_data.city_name = "Paris"

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var window = main_map.save_load_window
    check(window != null, "the map owns the window of the saves", state)
    check(not window.visible, "the window is closed at start", state)

    main_map.open_pause_menu()
    await process_frame
    check(main_map.pause_menu.visible, "the pause menu is open", state)
    check(paused, "the menu stops the game", state)

    # --- 1. The item opens the window over the menu ---
    var save_button = main_map.pause_menu.find_child("SaveButton", true, false)
    check(save_button != null, "the menu has the save item", state)
    save_button.pressed.emit()
    await process_frame
    check(window.visible, "the item opens the window", state)
    check(main_map.pause_menu.visible, "the menu stays behind the window", state)
    check(paused, "the game stays stopped under the window", state)
    check(window.name_row.visible, "the window is in the save mode", state)
    check(window.name_edit.text == str(city_data.city_name),
        "the name field carries the name of the city (got: %s)" % window.name_edit.text, state)

    # --- 2. The save goes to the chosen slot ---
    var slots_before: int = save_manager.list_saves().size()
    window.name_edit.text = TEST_NAME
    window.accept_button.pressed.emit()
    await process_frame
    check(not window.visible, "the window closes after the save", state)
    check(main_map.pause_menu.visible, "the player is back at the menu", state)
    check(paused, "the game is still stopped after the save", state)

    var slots: Array = save_manager.list_saves()
    check(slots.size() == slots_before + 1,
        "a new slot is written (got: %d, before: %d)" % [slots.size(), slots_before], state)
    var saved_meta := _find_by_name(slots, TEST_NAME)
    check(not saved_meta.is_empty(), "the slot carries the typed name", state)
    var saved_id := str(saved_meta.get("id", ""))
    check(FileAccess.file_exists(save_manager.slot_data_path(saved_id)),
        "the state of the slot is on the disk", state)
    check(str(saved_meta.get("city_name", "")) == str(city_data.city_name),
        "the slot knows the city it was made in", state)
    check(str(save_manager.last_slot_id) == saved_id,
        "the place saved last is remembered", state)

    # --- 3. The next opening preselects it, and the load item opens the list ---
    save_button.pressed.emit()
    await process_frame
    check(window.visible, "the window opens again", state)
    check(str(window._selected_id) == saved_id,
        "the place saved last is preselected (got: %s, expected: %s)"
            % [str(window._selected_id), saved_id], state)
    check(window.name_edit.text == TEST_NAME,
        "the name of the selected slot is in the field (got: %s)" % window.name_edit.text, state)

    window.close()
    await process_frame
    var load_button = main_map.pause_menu.find_child("LoadButton", true, false)
    check(load_button != null, "the menu has the load item", state)
    load_button.pressed.emit()
    await process_frame
    check(window.visible, "the load item opens the window", state)
    check(not window.name_row.visible, "the window is in the load mode", state)
    check(paused, "the game is still stopped behind the list", state)
    check(str(window._selected_id) == saved_id, "the slot saved last is preselected in the list", state)

    window.close()
    await process_frame
    get_root().remove_child(main_map)
    main_map.free()
    await process_frame

    # --- The cleanup ---
    _delete_test_slots(save_manager)
    save_manager._store_last_slot(last_slot_backup)

    if state["failed"]:
        print("SAVE WINDOW LIVE TEST FAILED")
        quit(1)
    else:
        print("SAVE WINDOW LIVE TEST OK")
        quit(0)

func _delete_test_slots(save_manager) -> void:
    for slot in save_manager.list_saves():
        if str(slot.get("name", "")) == TEST_NAME:
            save_manager.delete_save(str(slot.get("id", "")))

func _find_by_name(slots: Array, save_name: String) -> Dictionary:
    for slot in slots:
        if str(slot.get("name", "")) == save_name:
            return slot
    return {}

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
