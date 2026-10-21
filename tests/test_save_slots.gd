# Headless test of the save slots and of the window of the saves:
#   godot --headless --path . --script res://tests/test_save_slots.gd
#
# Covers:
#   1. The storage (scripts/SaveManager.gd): one slot is two files, the list holds
#      what can actually be loaded, the newest first, a slot is read back and deleted,
#      and the place selected last is remembered between the runs.
#   2. The window (scenes/save_load_window.tscn): the rows of both modes, the
#      preselected place, the name field, the confirmation before an overwrite, and
#      the signals the host acts on.
#
# The test writes its own slots and removes them afterwards, and puts the place the
# player selected last back: it must not eat a real game.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# The window is loaded by path inside the run, and not preloaded: in the --script
# mode the autoloads are not yet script identifiers while the test itself compiles,
# and a preloaded chain would fail on "Identifier not found: SaveManager".
const WINDOW_SCENE := "res://scenes/save_load_window.tscn"

const SLOT_A := "test_slots_a"
const SLOT_B := "test_slots_b"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    var last_slot_backup := str(save_manager.last_slot_id)
    save_manager.delete_save(SLOT_A)
    save_manager.delete_save(SLOT_B)

    # --- 1. The storage ---
    check(save_manager.write_slot(SLOT_A, _slot_data(SLOT_A, "Older game", 100)),
        "a slot is written", state)
    check(save_manager.write_slot(SLOT_B, _slot_data(SLOT_B, "Newer game", 200)),
        "a second slot is written", state)
    check(FileAccess.file_exists(save_manager.slot_data_path(SLOT_A)),
        "the state of the slot is on the disk", state)
    check(FileAccess.file_exists(save_manager.slot_meta_path(SLOT_A)),
        "the metadata of the slot is a file of its own", state)
    check(save_manager.has_slot(SLOT_A), "has_slot() sees the written slot", state)
    check(not save_manager.has_slot("test_slots_missing"), "has_slot() sees no missing slot", state)
    check(save_manager.has_save(), "the player has something to load", state)

    var slots: Array = save_manager.list_saves()
    var ids := _ids(slots)
    check(ids.has(SLOT_A) and ids.has(SLOT_B), "both slots are on the list", state)
    check(ids.find(SLOT_B) < ids.find(SLOT_A),
        "the newest slot comes first (got: %s)" % str(ids), state)
    var meta := _find(slots, SLOT_B)
    check(str(meta.get("name", "")) == "Newer game",
        "the list carries the name (got: %s)" % str(meta.get("name", "")), state)
    check(str(meta.get("city_name", "")) == "Paris", "the list carries the city", state)
    check(int(meta.get("era_index", -1)) == 3, "the list carries the era", state)

    check(save_manager.load_game(SLOT_A), "a slot is read back", state)
    check(save_manager.is_loaded, "the load raises the flag", state)
    check(str(save_manager.saved_data.get("city_name", "")) == "Paris",
        "the state of the slot is in saved_data", state)
    check(str(save_manager.last_slot_id) == SLOT_A, "the loaded slot becomes the remembered one", state)

    # The remembered place survives a restart: it is read from the file, not kept in memory.
    save_manager._store_last_slot(SLOT_B)
    save_manager.last_slot_id = ""
    save_manager._load_last_slot()
    check(str(save_manager.last_slot_id) == SLOT_B,
        "the remembered place is read from the disk (got: %s)" % str(save_manager.last_slot_id), state)

    # The default target of a load without an id is the remembered slot.
    check(save_manager.load_game(), "a load without an id uses the remembered slot", state)
    check(str(save_manager.saved_data.get("city_name", "")) == "Paris", "it is the slot B that was read", state)

    check(save_manager.delete_save(SLOT_B), "a slot is deleted", state)
    check(not FileAccess.file_exists(save_manager.slot_data_path(SLOT_B)),
        "the state file is gone", state)
    check(not FileAccess.file_exists(save_manager.slot_meta_path(SLOT_B)),
        "the metadata file is gone", state)
    check(not _ids(save_manager.list_saves()).has(SLOT_B), "the deleted slot leaves the list", state)
    check(str(save_manager.last_slot_id).is_empty(),
        "deleting the remembered slot forgets it", state)
    check(save_manager.has_slot(SLOT_A), "the neighbour slot is untouched", state)

    # --- 2. The window ---
    save_manager._store_last_slot(SLOT_A)
    # The pause menu comes first, the window after it — the order of MainMap.tscn,
    # where the window is added by main_map last. ESC is delivered in the reverse
    # tree order, so the window gets it before the menu behind it.
    var pause_menu = load("res://scenes/pause_menu.tscn").instantiate()
    get_root().add_child(pause_menu)
    await process_frame

    var window = load(WINDOW_SCENE).instantiate()
    get_root().add_child(window)
    await process_frame
    check(not window.visible, "the window is closed until it is opened", state)

    var slot_count: int = save_manager.list_saves().size()

    # The save mode: an existing place, or a new one.
    window.open_save("Testopolis")
    await process_frame
    check(window.visible, "open_save() shows the window", state)
    check(window.name_row.visible, "the save mode asks for a name", state)
    check(window.accept_button.text == "Save", "the button offers a save", state)
    check(window.list.get_child_count() == slot_count + 1,
        "the save mode lists the slots plus a new one (got: %d, expected: %d)"
            % [window.list.get_child_count(), slot_count + 1], state)
    check(window._row_buttons.has(window.NEW_SLOT_ID), "the list offers a new slot", state)
    check(str(window._selected_id) == SLOT_A, "the place selected last is preselected", state)
    check(window.name_edit.text == "Older game",
        "the name of the selected slot is in the field (got: %s)" % window.name_edit.text, state)

    var requested: Array = []
    window.save_requested.connect(func(slot_id: String, save_name: String) -> void:
        requested.append([slot_id, save_name]))

    # A new slot: the name field carries the suggestion of the host.
    (window._row_buttons[window.NEW_SLOT_ID] as Button).pressed.emit()
    check(window.name_edit.text == "Testopolis",
        "a new slot is offered under the name of the city (got: %s)" % window.name_edit.text, state)
    window.accept_button.pressed.emit()
    check(requested.size() == 1, "the save is requested (got: %d)" % requested.size(), state)
    if requested.size() == 1:
        check(str(requested[0][0]).is_empty(), "a new save carries no slot id", state)
        check(str(requested[0][1]) == "Testopolis", "the name from the field is passed", state)

    # A name of its own means a NEW save, even while an existing slot is highlighted:
    # nothing is destroyed, so nothing is asked.
    requested.clear()
    (window._row_buttons[SLOT_A] as Button).pressed.emit()
    window.name_edit.text = "Another name"
    # What real typing emits: a programmatic assignment to LineEdit.text is silent.
    window.name_edit.text_changed.emit("Another name")
    check(str(window._selected_id).is_empty(),
        "the highlight leaves the slot whose name was replaced (got: %s)" % str(window._selected_id), state)
    window.accept_button.pressed.emit()
    check(not window._confirm.visible, "a free name asks for no confirmation", state)
    check(requested.size() == 1, "the save under a free name is requested (got: %d)" % requested.size(), state)
    if requested.size() == 1:
        check(str(requested[0][0]).is_empty(), "a free name creates a new slot", state)
        check(str(requested[0][1]) == "Another name", "the typed name is passed", state)

    # And the other way round: a typed name that a slot carries highlights that slot.
    window.name_edit.text = "Older game"
    window.name_edit.text_changed.emit("Older game")
    check(str(window._selected_id) == SLOT_A,
        "typing the name of a slot highlights it (got: %s)" % str(window._selected_id), state)

    # An existing slot: the overwrite is confirmed first, and a cancel saves nothing.
    requested.clear()
    (window._row_buttons[SLOT_A] as Button).pressed.emit()
    check(window.name_edit.text == "Older game", "the name follows the selected slot", state)
    window.accept_button.pressed.emit()
    check(window._confirm.visible, "the overwrite asks for a confirmation", state)
    check(requested.is_empty(), "nothing is saved before the confirmation", state)
    window._confirm.canceled.emit()
    check(requested.is_empty(), "a cancelled overwrite saves nothing", state)
    window.accept_button.pressed.emit()
    window._confirm.get_ok_button().pressed.emit()
    check(requested.size() == 1, "the confirmed overwrite is requested (got: %d)" % requested.size(), state)
    if requested.size() == 1:
        check(str(requested[0][0]) == SLOT_A, "the overwrite targets the selected slot", state)

    # The load mode: the slots only, no name and no new one.
    window.open_load()
    await process_frame
    check(not window.name_row.visible, "the load mode asks for no name", state)
    check(window.accept_button.text == "Load", "the button offers a load", state)
    check(window.list.get_child_count() == slot_count,
        "the load mode lists the slots only (got: %d, expected: %d)"
            % [window.list.get_child_count(), slot_count], state)
    check(not window._row_buttons.has(window.NEW_SLOT_ID), "the load list offers no new slot", state)
    check(window.empty_label.visible == (window.list.get_child_count() == 0),
        "the empty state matches the list", state)
    check(str(window._selected_id) == SLOT_A, "the place selected last is preselected here too", state)
    check(not window.accept_button.disabled, "there is something to load", state)

    var loaded: Array = []
    window.load_requested.connect(func(slot_id: String) -> void: loaded.append(slot_id))
    window.accept_button.pressed.emit()
    check(loaded.size() == 1 and str(loaded[0]) == SLOT_A,
        "the load of the selected slot is requested (got: %s)" % str(loaded), state)

    # Closing: the host listens to it (main_menu refreshes its button on it).
    var closed_count := [0]
    window.closed.connect(func() -> void: closed_count[0] += 1)
    window.close()
    check(not window.visible, "close() hides the window", state)
    check(closed_count[0] == 1, "close() reports the closing (got: %d)" % closed_count[0], state)

    # --- 3. ESC belongs to the window, not to the pause menu behind it ---
    # The window is opened over a stopped world, and the menu that opened it stays
    # behind: an ESC that closed the menu instead would throw the player out of the
    # game while they are still choosing a save.
    pause_menu.show()
    paused = true
    window.open_save("Paris")
    await process_frame
    check(window.visible and pause_menu.visible, "the window is open over the menu", state)
    _press_escape()
    await process_frame
    check(not window.visible, "ESC closes the window", state)
    check(pause_menu.visible, "ESC does not reach the pause menu behind the window", state)

    paused = false
    pause_menu.hide()
    get_root().remove_child(window)
    window.free()
    get_root().remove_child(pause_menu)
    pause_menu.free()

    # --- The cleanup ---
    save_manager.delete_save(SLOT_A)
    save_manager.delete_save(SLOT_B)
    save_manager._store_last_slot(last_slot_backup)

    if state["failed"]:
        print("SAVE SLOTS TEST FAILED")
        quit(1)
    else:
        print("SAVE SLOTS TEST OK")
        quit(0)

# A slot as the save window sees it, without a running map: the state carries the
# metadata, exactly as save_game() writes it.
func _slot_data(slot_id: String, save_name: String, saved_at: int) -> Dictionary:
    return {
        "city_name": "Paris",
        "current_era_index": 3,
        "total_population": 128,
        "_meta": {
            "id": slot_id,
            "name": save_name,
            "city_name": "Paris",
            "saved_at": saved_at,
            "era_index": 3,
            "population": 128
        }
    }

func _press_escape() -> void:
    var event := InputEventKey.new()
    event.keycode = KEY_ESCAPE
    event.physical_keycode = KEY_ESCAPE
    event.pressed = true
    get_root().push_input(event)

func _ids(slots: Array) -> Array:
    var out: Array = []
    for slot in slots:
        out.append(str(slot.get("id", "")))
    return out

func _find(slots: Array, slot_id: String) -> Dictionary:
    for slot in slots:
        if str(slot.get("id", "")) == slot_id:
            return slot
    return {}

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
