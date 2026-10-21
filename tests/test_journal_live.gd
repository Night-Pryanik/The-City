# Headless test of the journal on the LIVE map:
#   godot --headless --path . --script res://tests/test_journal_live.gd
#
# The fast test (tests/test_journal.gd) covers the history, the HUD hookup and the
# window on a bare tree. This one covers what only the real scene can show:
#   1. The map owns one history, the HUD pushes into exactly that one, and the journal
#      button of the HUD is there with its unread dot.
#   2. The button opens the window and the game stops; closing it resumes the game.
#      The pause flag is the one main_map owns — the journal must not write it itself.
#   3. The journal survives a save and a load: the texts and the read flags come back.
#
# The test writes a slot of its own and removes it afterwards, and puts the slot the
# player selected last back in place: a test must not eat a real game.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const TEST_SLOT := "test_journal_live"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    var save_manager = get_root().get_node("SaveManager")
    var game_data = get_root().get_node("GameData")
    var last_slot_backup := str(save_manager.last_slot_id)
    save_manager.new_game()

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    # --- 1. The history and the button ---
    check(main_map.journal != null, "the map owns a journal", state)
    check(main_map.hud.journal == main_map.journal, "the HUD feeds the journal of the map", state)
    var button = main_map.find_child("JournalButton", true, false)
    check(button != null, "the HUD has a journal button", state)
    check(button.text == "Journal", "the button is captioned (got: %s)" % button.text, state)
    check(not button.tooltip_text.is_empty(), "the button has a tooltip", state)
    var dot = main_map.find_child("UnreadDot", true, false)
    check(dot != null, "the journal button carries the unread dot", state)
    check(dot != null and dot.get_parent() == button, "the dot sits on the journal button", state)

    main_map.journal.clear()
    check(not dot.visible, "the dot is hidden while nothing is unread", state)

    main_map.hud.show_message("routine", game_data.HUD_MESSAGE_NORMAL)
    check(main_map.journal.entries.is_empty(), "an ordinary message is not journalled", state)
    main_map.hud.show_message("something important", game_data.HUD_MESSAGE_IMPORTANT)
    check(main_map.journal.entries.size() == 1, "an important message is journalled", state)
    check(dot.visible, "the dot appears on the journal button", state)

    # --- 2. The window and the pause ---
    check(not main_map.journal_ui.visible, "the window is closed at start", state)
    check(not paused, "the game runs before the journal is opened", state)
    button.pressed.emit()
    await process_frame
    check(main_map.journal_ui.visible, "the button opens the window", state)
    check(paused, "opening the journal pauses the game", state)

    main_map.close_journal()
    await process_frame
    check(not main_map.journal_ui.visible, "close_journal() closes the window", state)
    check(not paused, "closing the journal resumes the game", state)

    # A window closed over a world stopped by the ACTIVE pause must leave it stopped.
    main_map.toggle_active_pause()
    check(paused, "the active pause stops the game", state)
    main_map.open_journal()
    await process_frame
    main_map.close_journal()
    await process_frame
    check(paused, "closing the journal keeps the world stopped by the active pause", state)
    main_map.toggle_active_pause()
    check(not paused, "the active pause is off again", state)

    # The pause menu takes the HUD buttons away, and _process cannot do it: the tree is
    # paused and _process does not run then.
    main_map.open_pause_menu()
    await process_frame
    check(button.disabled, "the journal button is disabled while the pause menu is open", state)
    main_map.pause_menu.hide()
    main_map.apply_pause_state()
    await process_frame
    check(not paused, "the pause menu is closed again", state)

    # --- 3. The save and the load ---
    main_map.journal.clear()
    main_map.hud.show_message("kept message", game_data.HUD_MESSAGE_IMPORTANT)
    main_map.hud.show_message("read message", game_data.HUD_MESSAGE_IMPORTANT)
    main_map.journal.mark_read(int(main_map.journal.entries[0]["id"]))
    save_manager.save_game(TEST_SLOT, "journal test")

    var saved = _read_save(save_manager)
    check(saved is Dictionary and saved.has("journal"), "the save file carries the journal", state)
    var saved_entries = saved.get("journal", []) if saved is Dictionary else []
    check(saved_entries is Array and saved_entries.size() == 2,
        "both entries are written to the save (got: %d)"
            % (saved_entries.size() if saved_entries is Array else -1), state)

    get_root().remove_child(main_map)
    main_map.free()
    await process_frame

    check(save_manager.load_game(TEST_SLOT), "the save file is read back", state)
    var loaded_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(loaded_map)
    await process_frame
    await process_frame

    check(loaded_map.journal.entries.size() == 2, "both entries are restored (got: %d)"
        % loaded_map.journal.entries.size(), state)
    if loaded_map.journal.entries.size() == 2:
        check(str(loaded_map.journal.entries[0]["text"]) == "read message",
            "the order is restored (got: %s)" % str(loaded_map.journal.entries[0]["text"]), state)
        check(not bool(loaded_map.journal.entries[0]["unread"]),
            "the read flag is restored", state)
        check(bool(loaded_map.journal.entries[1]["unread"]),
            "the unread flag is restored", state)
        check(loaded_map.journal.unread_count() == 1, "one unread entry after the load", state)
    var loaded_dot = loaded_map.find_child("UnreadDot", true, false)
    check(loaded_dot != null and loaded_dot.visible,
        "the dot is up right after the load", state)
    # A message that arrives after the load must not collide with the restored ids.
    loaded_map.hud.show_message("after the load", game_data.HUD_MESSAGE_IMPORTANT)
    check(loaded_map.journal.entries.size() == 3, "a new message is appended after the load", state)
    var ids := {}
    for entry in loaded_map.journal.entries:
        ids[int(entry["id"])] = true
    check(ids.size() == loaded_map.journal.entries.size(),
        "the ids of the restored entries are unique", state)

    get_root().remove_child(loaded_map)
    loaded_map.free()
    await process_frame

    save_manager.delete_save(TEST_SLOT)
    save_manager._store_last_slot(last_slot_backup)
    if state["failed"]:
        print("JOURNAL LIVE TEST FAILED")
        quit(1)
    else:
        print("JOURNAL LIVE TEST OK")
        quit(0)

func _read_save(save_manager) -> Variant:
    var path: String = save_manager.slot_data_path(TEST_SLOT)
    if not FileAccess.file_exists(path):
        return null
    var file = FileAccess.open(path, FileAccess.READ)
    if file == null:
        return null
    var parsed = JSON.parse_string(file.get_as_text())
    return parsed if parsed is Dictionary else null

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
