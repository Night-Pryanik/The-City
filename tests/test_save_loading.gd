extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# "Continue game" must not freeze silently: a loading screen appears right after the
# click, its bar advances with the stages of the save restore, and it is removed when
# the world is ready.
#
# The restore runs in stages with a frame between them (see main_map._ready), therefore
# the test watches the bar frame by frame: a bar that jumps from 0 to 100 (the stages
# merged into one frame) fails here as loudly as a missing screen.
#
# The save is a real one: the test first generates a world through the new game path,
# saves it, returns to the menu and clicks continue — the whole player path.

const SLOT := "test_save_loading"

func _initialize() -> void:
    WATCHDOG.arm(self)
    call_deferred("_run")

func _run() -> void:
    var state := {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    var last_slot_backup := str(save_manager.last_slot_id)
    save_manager.delete_save(SLOT)
    await process_frame
    save_manager.new_game()

    var menu = load("res://scenes/main_menu.tscn").instantiate()
    get_root().add_child(menu)
    await process_frame
    await process_frame

    # A world to save: the restore must read a save the game itself wrote.
    menu._start_new_game("Test City")
    var frames := 0
    while get_root().get_node_or_null("LoadingOverlay") != null and frames < 600:
        await process_frame
        frames += 1
    check(frames < 600, "the world generation must finish (it hung after 600 frames)", state)
    var map = get_root().get_node_or_null("MainMap")
    check(map != null, "the game scene must be loaded", state)
    if map == null:
        _cleanup(save_manager, last_slot_backup)
        _finish(state)
        return
    check(save_manager.save_game(SLOT, "Loading test"), "the world is written into a slot", state)

    # Back to the menu, as after quitting to it from a running game.
    change_scene_to_file("res://scenes/main_menu.tscn")
    await process_frame
    await process_frame
    menu = current_scene
    check(menu != null and not menu.continue_button.disabled,
            "the menu offers the continue of the written save", state)
    if menu == null:
        _cleanup(save_manager, last_slot_backup)
        _finish(state)
        return

    # The click itself. It suspends on the first frame, so the screen is already in
    # the tree when the call returns.
    menu._on_continue_game()
    var overlay = get_root().get_node_or_null("LoadingOverlay")
    check(overlay != null, "the continue click must show a loading screen", state)
    if overlay == null:
        _cleanup(save_manager, last_slot_backup)
        _finish(state)
        return

    var bar = overlay.get_node_or_null("VBoxContainer/ProgressBar")
    var status = overlay.get_node_or_null("VBoxContainer/StatusLabel")
    check(bar != null and status != null,
            "the loading screen must own a bar and a status line", state)

    var values := {}
    var texts := {}
    frames = 0
    while get_root().get_node_or_null("LoadingOverlay") != null and frames < 600:
        if bar != null:
            values[bar.value] = true
        if status != null:
            texts[status.text] = true
        await process_frame
        frames += 1

    check(frames < 600, "the save restore must finish (it hung after 600 frames)", state)
    check(values.size() >= 3,
            "the bar must advance in stages, not jump (saw %d values)" % values.size(), state)
    check(texts.size() >= 3,
            "the status must name the stages (saw %d lines)" % texts.size(), state)
    check(get_root().get_node_or_null("LoadingOverlay") == null,
            "the loading screen must be removed when the save is restored", state)

    map = get_root().get_node_or_null("MainMap")
    check(map != null, "the game scene must be loaded", state)
    if map != null:
        check(not map.world_generating, "the world must be ready after the restore", state)
        check(map.tile_data.size() == map.map_rows and map.tile_data[0].size() == map.map_cols,
                "the map must be restored in full (%d rows)" % map.tile_data.size(), state)
        check(map.towns.size() > 0, "the towns must be restored", state)
    check(str(get_root().get_node("CityData").city_name) == "Test City",
            "the restored city keeps the name of the save", state)

    _cleanup(save_manager, last_slot_backup)
    _finish(state)

func _cleanup(save_manager, last_slot_backup: String) -> void:
    save_manager.delete_save(SLOT)
    save_manager._store_last_slot(last_slot_backup)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("SAVE LOADING TEST FAILED")
        quit(1)
    else:
        print("SAVE LOADING TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)