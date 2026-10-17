# Headless test for the journal of the important messages:
#   godot --headless --path . --script res://tests/test_journal.gd
#
# Verifies:
#   1. The history itself (scripts/journal.gd): newest first, the unread flag, reading,
#      deleting, clearing, the 200-entry cap, and the round trip through the save file
#      (serialize -> JSON -> restore, including the float ids JSON hands back).
#   2. The HUD (scripts/hud_message.gd): only GameData.HUD_MESSAGE_IMPORTANT reaches the
#      history, an ordinary message does not, and the dot on the journal button follows
#      the unread count.
#   3. The window (scenes/journal.tscn): one row per entry, the bold variation on the
#      unread ones only, a click on the text reads the entry, the row buttons read and
#      delete, the header buttons read all and clear all, the empty state, and closing
#      by the button and by ESC.
#
# The window is tested on a bare tree: the map, the pause and the button of the HUD are
# covered by tests/test_journal_live.gd, which needs a generated map.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const JOURNAL_SCRIPT := preload("res://scripts/journal.gd")
const HUD_SCRIPT := preload("res://scripts/hud_message.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # --- 1. The history ---
    var journal = JOURNAL_SCRIPT.new()
    journal.name = "Journal"
    get_root().add_child(journal)
    await process_frame

    var changes := [0]
    journal.changed.connect(func() -> void: changes[0] += 1)

    journal.add_message("first")
    journal.add_message("second")
    check(journal.entries.size() == 2, "two messages are in the history", state)
    check(str(journal.entries[0]["text"]) == "second",
        "the newest message is first (got: %s)" % str(journal.entries[0]["text"]), state)
    check(journal.unread_count() == 2, "both messages are unread", state)
    check(changes[0] == 2, "every added message emits changed (got: %d)" % changes[0], state)

    journal.add_message("   ")
    check(journal.entries.size() == 2, "a blank message is not stored", state)

    var first_id := int(journal.entries[1]["id"])
    var second_id := int(journal.entries[0]["id"])
    check(first_id != second_id, "the entries have different ids", state)

    check(journal.mark_read(first_id), "an unread entry can be read", state)
    check(not journal.is_unread(first_id), "the entry is read", state)
    check(journal.unread_count() == 1, "one unread entry is left", state)
    check(not journal.mark_read(first_id), "reading a read entry changes nothing", state)

    check(journal.mark_all_read(), "mark_all_read() reports a change", state)
    check(journal.unread_count() == 0, "nothing is unread after mark_all_read()", state)
    check(not journal.mark_all_read(), "mark_all_read() on a read list reports no change", state)

    check(journal.remove(first_id), "an entry can be deleted", state)
    check(journal.entries.size() == 1, "one entry is left after the deletion", state)
    check(not journal.remove(first_id), "deleting a missing entry reports nothing", state)
    check(int(journal.entries[0]["id"]) == second_id,
        "the deleted entry does not shift the id of its neighbour", state)

    # The cap: the OLDEST entries are dropped, the newest stay.
    journal.clear()
    for i in JOURNAL_SCRIPT.MAX_ENTRIES + 5:
        journal.add_message("message %d" % i)
    check(journal.entries.size() == JOURNAL_SCRIPT.MAX_ENTRIES,
        "the history is capped at %d entries (got: %d)"
            % [JOURNAL_SCRIPT.MAX_ENTRIES, journal.entries.size()], state)
    check(str(journal.entries[0]["text"]) == "message %d" % (JOURNAL_SCRIPT.MAX_ENTRIES + 4),
        "the newest entry survives the cap", state)
    check(str(journal.entries[journal.entries.size() - 1]["text"]) == "message 5",
        "the oldest entries were dropped by the cap (got: %s)"
            % str(journal.entries[journal.entries.size() - 1]["text"]), state)

    # The round trip through the save file: the ids come back as floats from JSON.
    journal.clear()
    journal.add_message("alpha")
    journal.add_message("beta")
    journal.mark_read(int(journal.entries[1]["id"]))
    var restored = JOURNAL_SCRIPT.new()
    get_root().add_child(restored)
    await process_frame
    var parsed = JSON.parse_string(JSON.stringify(journal.serialize()))
    check(parsed is Array, "the serialized history is JSON-safe", state)
    restored.restore(parsed)
    check(restored.entries.size() == 2, "both entries are restored", state)
    check(str(restored.entries[0]["text"]) == "beta", "the restored order is kept", state)
    check(restored.unread_count() == 1, "the read flag is restored", state)
    check(typeof(restored.entries[0]["id"]) == TYPE_INT, "the restored id is an int", state)
    check(int(restored.entries[0]["id"]) == int(journal.entries[0]["id"]),
        "the restored ids are the saved ones", state)
    # A message that arrives after the load must not take the id of a restored entry.
    var highest_restored := 0
    for entry in restored.entries:
        highest_restored = maxi(highest_restored, int(entry["id"]))
    restored.add_message("gamma")
    check(int(restored.entries[0]["id"]) > highest_restored,
        "a message added after the load takes an id above every restored one (got: %d, highest restored: %d)"
            % [int(restored.entries[0]["id"]), highest_restored], state)
    var ids := {}
    for entry in restored.entries:
        ids[int(entry["id"])] = true
    check(ids.size() == restored.entries.size(), "the ids stay unique after a restore", state)

    restored.restore("not an array")
    check(restored.entries.is_empty(), "a broken save record empties the history", state)
    restored.queue_free()
    await process_frame

    # --- 2. The HUD feeds the history ---
    # The autoload is taken by node: in --script mode the global names of the autoloads
    # are not resolved at compile time (see AGENTS.md, the test rules).
    var game_data = get_root().get_node("GameData")
    var hud = HUD_SCRIPT.new()
    var vbox = VBoxContainer.new()
    vbox.name = "VBoxContainer"
    var message_label = Label.new()
    message_label.name = "MapMessageLabel"
    vbox.add_child(message_label)
    var journal_button = Button.new()
    journal_button.name = "JournalButton"
    vbox.add_child(journal_button)
    var dot = Control.new()
    dot.name = "UnreadDot"
    dot.visible = false
    journal_button.add_child(dot)
    hud.add_child(vbox)
    get_root().add_child(hud)
    await process_frame
    hud.set_process(false)
    hud.set_journal(journal)

    journal.clear()
    check(not dot.visible, "the dot is hidden while the history is empty", state)
    hud.show_message("routine", game_data.HUD_MESSAGE_NORMAL)
    check(journal.entries.is_empty(), "an ordinary message does not reach the history", state)
    check(not dot.visible, "an ordinary message does not raise the dot", state)
    hud.show_message("important", game_data.HUD_MESSAGE_IMPORTANT)
    check(journal.entries.size() == 1, "an important message reaches the history", state)
    check(not journal.entries.is_empty() and str(journal.entries[0]["text"]) == "important",
        "the history keeps the text of the message", state)
    check(dot.visible, "the dot appears while a message is unread", state)
    journal.mark_all_read()
    check(not dot.visible, "the dot disappears when everything is read", state)
    journal.add_message("one more")
    check(dot.visible, "the dot returns with a new unread message", state)
    get_root().remove_child(hud)
    hud.free()
    await process_frame

    # --- 3. The window ---
    journal.clear()
    journal.add_message("unread message")
    journal.add_message("read message")
    journal.mark_read(int(journal.entries[0]["id"]))
    var ui = load("res://scenes/journal.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    var closed := [0]
    ui.closed.connect(func() -> void: closed[0] += 1)
    ui.setup(journal)
    ui.open_journal()
    await process_frame

    var list = ui.find_child("List", true, false)
    check(list != null, "the window has a list container", state)
    check(list.get_child_count() == 2, "one row per entry (got: %d)" % list.get_child_count(), state)
    check(ui.visible, "open_journal() shows the window", state)

    var read_row = list.get_child(0)
    var unread_row = list.get_child(1)
    var read_text = read_row.find_child("Text", true, false)
    var unread_text = unread_row.find_child("Text", true, false)
    check(read_text != null and unread_text != null, "every row has a text label", state)
    check(str(read_text.text) == "read message", "the rows follow the order of the history", state)
    check(unread_text.theme_type_variation == &"BoldLabel",
        "the unread message is drawn in the bold variation (got: %s)"
            % str(unread_text.theme_type_variation), state)
    check(read_text.theme_type_variation == &"",
        "the read message is drawn in the body face (got: %s)"
            % str(read_text.theme_type_variation), state)
    check(not unread_row.find_child("ReadButton", true, false).disabled,
        "the read button of an unread message is enabled", state)
    check(read_row.find_child("ReadButton", true, false).disabled,
        "the read button of a read message is disabled", state)

    # A click on the message itself reads it.
    var click := InputEventMouseButton.new()
    click.button_index = MOUSE_BUTTON_LEFT
    click.pressed = true
    unread_text.gui_input.emit(click)
    await process_frame
    await process_frame
    check(journal.unread_count() == 0, "a click on the message marks it read", state)
    var rebuilt_text = list.get_child(1).find_child("Text", true, false)
    check(rebuilt_text.theme_type_variation == &"",
        "after the click the row is redrawn in the body face (got: %s)"
            % str(rebuilt_text.theme_type_variation), state)

    # The row buttons.
    var row_read_button = list.get_child(1).find_child("ReadButton", true, false)
    check(row_read_button.disabled, "the read button is disabled on a read message", state)

    var row_delete_button = list.get_child(0).find_child("DeleteButton", true, false)
    row_delete_button.pressed.emit()
    await process_frame
    await process_frame
    check(journal.entries.size() == 1, "the row button deletes its message", state)
    check(str(journal.entries[0]["text"]) == "unread message",
        "the row button deletes exactly its own message (left: %s)"
            % str(journal.entries[0]["text"]), state)
    check(list.get_child_count() == 1, "the list follows the deletion", state)

    # The header buttons.
    journal.add_message("unread again")
    await process_frame
    await process_frame
    check(ui.mark_all_button.disabled == false, "the \"mark all\" button is enabled", state)
    ui.mark_all_button.pressed.emit()
    await process_frame
    await process_frame
    check(journal.unread_count() == 0, "\"mark all\" reads every message", state)
    check(ui.mark_all_button.disabled, "the \"mark all\" button is disabled when all is read", state)

    check(ui.clear_all_button.disabled == false, "the \"delete all\" button is enabled", state)
    ui.clear_all_button.pressed.emit()
    await process_frame
    await process_frame
    check(journal.entries.is_empty(), "\"delete all\" empties the history", state)
    check(list.get_child_count() == 0, "the list is empty", state)
    check(ui.empty_label.visible, "the empty state is shown", state)
    check(ui.clear_all_button.disabled, "the \"delete all\" button is disabled on an empty history", state)
    check(ui.mark_all_button.disabled, "the \"mark all\" button is disabled on an empty history", state)

    # Closing: by the button and by ESC.
    ui.close_button.pressed.emit()
    await process_frame
    check(not ui.visible, "the close button hides the window", state)
    check(closed[0] == 1, "the close button emits closed (got: %d)" % closed[0], state)
    var esc := InputEventKey.new()
    esc.keycode = KEY_ESCAPE
    esc.pressed = true
    ui._unhandled_input(esc)
    check(closed[0] == 1, "ESC on a hidden window does nothing", state)
    ui.open_journal()
    await process_frame
    ui._unhandled_input(esc)
    check(not ui.visible, "ESC closes the window", state)
    check(closed[0] == 2, "ESC emits closed (got: %d)" % closed[0], state)

    ui.queue_free()
    journal.queue_free()
    await process_frame

    if state["failed"]:
        print("JOURNAL TEST FAILED")
        quit(1)
    else:
        print("JOURNAL TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
