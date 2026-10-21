# Headless test for the HUD clock and the "Show clock" setting:
#   godot --headless --path . --script res://tests/test_hud_clock.gd
#
# Verifies:
#   1. The settings menu (the "Interface" tab): the ClockCheckBox exists and is on
#      by default; switching it off saves the key interface/show_clock and a reopen
#      reads the saved value back.
#   2. On the live scene MainMap.tscn: main_map reads show_clock from the config and
#      shows/hides the clock label in the top right corner accordingly — both at the
#      map start and live, through apply_settings().
#   3. The clock shows the real local time: _update_clock() writes HH:MM equal to the
#      system time, and the tick timer survives a paused tree (PROCESS_MODE_ALWAYS).
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # --- 1. The settings menu: the checkbox, the default and the config key ---
    var settings = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings)
    await process_frame
    var checkbox = settings.find_child("ClockCheckBox", true, false)
    check(checkbox != null, "checkbox ClockCheckBox found in the Interface tab", state)
    if checkbox != null:
        check(checkbox.button_pressed,
            "without a settings file the clock is on by default", state)
        checkbox.button_pressed = false
        checkbox.toggled.emit(false)
    var cfg := ConfigFile.new()
    var err := cfg.load("user://settings.cfg")
    check(err == OK, "settings.cfg saved", state)
    if err == OK:
        check(not bool(cfg.get_value("interface", "show_clock", true)),
            "key interface/show_clock saved as off", state)

    # Reopening the settings reads the saved value.
    settings.queue_free()
    await process_frame
    var settings2 = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings2)
    await process_frame
    var checkbox2 = settings2.find_child("ClockCheckBox", true, false)
    check(checkbox2 != null and not checkbox2.button_pressed,
        "the reopened settings read the clock off", state)
    settings2.queue_free()
    await process_frame

    # --- 2. The live map: read at start, applied on a change ---
    # A known starting point: the machine may carry any settings.cfg.
    var seed_cfg := ConfigFile.new()
    seed_cfg.set_value("interface", "show_clock", false)
    seed_cfg.save("user://settings.cfg")

    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    check(not main_map.show_clock,
        "main_map._load_settings() read show_clock = false (got: %s)" % main_map.show_clock, state)
    check(main_map.clock_label != null and not main_map.clock_label.visible,
        "the clock label is hidden at the map start", state)
    check(main_map._clock_timer != null
            and main_map._clock_timer.process_mode == Node.PROCESS_MODE_ALWAYS,
        "the clock tick timer runs while the tree is paused", state)

    seed_cfg = ConfigFile.new()
    seed_cfg.set_value("interface", "show_clock", true)
    seed_cfg.save("user://settings.cfg")
    main_map.apply_settings()
    check(main_map.show_clock and main_map.clock_label.visible,
        "apply_settings() shows the clock label again", state)

    # --- 3. The text is the real local time ---
    main_map._update_clock()
    var now: Dictionary = Time.get_time_dict_from_system()
    var expected := "%02d:%02d" % [now["hour"], now["minute"]]
    check(main_map.clock_label.text == expected,
        "the clock shows the system time %s (got: %s)"
            % [expected, main_map.clock_label.text], state)

    _finish(main_map, state)

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("HUD CLOCK TEST FAILED")
        quit(1)
    else:
        print("HUD CLOCK TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
