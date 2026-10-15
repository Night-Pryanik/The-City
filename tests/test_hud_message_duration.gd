# Headless test for the "HUD message display time" setting:
#   godot --headless --path . --script res://tests/test_hud_message_duration.gd
#
# Verifies:
#   1. The slider in the settings (the "Interface" tab): range 1..10, step 0.5; the
#      key interface/hud_message_duration is saved to user://settings.cfg and read
#      back when the settings are reopened; the value label follows the slider.
#   2. The HUD timer (hud_message.gd) on a bare panel: set_message_duration()
#      clamps to 1..10, a message stays visible for the whole duration and hides
#      on the first tick past it.
#   3. On the live scene MainMap.tscn: the value saved by the settings menu is read
#      by main_map._load_settings() and applied to the HUD at start; a change of the
#      slider reaches the running HUD at once (through apply_settings()).
#
# The panel of the HUD is built by hand instead of being taken from MainMap.tscn:
# the timing is then driven by explicit _process() calls, with the engine tick
# switched off, and does not depend on the real frame rate.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # --- 1. Settings menu: the slider, the label and the config key ---
    var settings = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings)
    await process_frame
    var slider = settings.find_child("HudMessageDurationSlider", true, false)
    var value_label = settings.find_child("HudMessageDurationValueLabel", true, false)
    check(slider != null, "slider HudMessageDurationSlider found", state)
    check(value_label != null, "label HudMessageDurationValueLabel found", state)
    if slider != null:
        check(is_equal_approx(slider.min_value, 1.0) and is_equal_approx(slider.max_value, 10.0),
            "slider is set from 1 to 10 seconds", state)
        check(is_equal_approx(slider.step, 0.5), "slider step is 0.5 second", state)
        check(is_equal_approx(slider.value, 3.0),
            "without a settings file the slider starts at 3 seconds", state)
        slider.value = 5.0
    settings.save_settings()
    check(value_label != null and value_label.text == "5.0 sec",
        "the value label shows \"5.0 sec\" (got: %s)"
            % (value_label.text if value_label else "null"), state)
    var cfg = ConfigFile.new()
    var err = cfg.load("user://settings.cfg")
    check(err == OK, "settings.cfg saved", state)
    if err == OK:
        check(is_equal_approx(float(cfg.get_value("interface", "hud_message_duration", 0.0)), 5.0),
            "key interface/hud_message_duration saved with value 5", state)

    # Reopening the settings reads the saved value.
    settings.queue_free()
    await process_frame
    var settings2 = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings2)
    await process_frame
    var slider2 = settings2.find_child("HudMessageDurationSlider", true, false)
    check(slider2 != null and is_equal_approx(slider2.value, 5.0),
        "the slider reads the saved value 5", state)

    # --- 2. The HUD timer on a bare panel ---
    var hud_script = load("res://scripts/hud_message.gd")
    var hud = hud_script.new()
    var vbox = VBoxContainer.new()
    vbox.name = "VBoxContainer"
    var message_label = Label.new()
    message_label.name = "MapMessageLabel"
    vbox.add_child(message_label)
    hud.add_child(vbox)
    get_root().add_child(hud)
    await process_frame
    # The engine must not tick the panel: the timing below is driven by hand.
    hud.set_process(false)
    check(hud.message_label == message_label, "the HUD picked up MapMessageLabel", state)
    check(is_equal_approx(hud.message_duration, 3.0), "the HUD default duration is 3 seconds", state)
    hud.set_message_duration(100.0)
    check(is_equal_approx(hud.message_duration, 10.0), "clamp from above: 100 -> 10 seconds", state)
    hud.set_message_duration(0.0)
    check(is_equal_approx(hud.message_duration, 1.0), "clamp from below: 0 -> 1 second", state)
    hud.set_message_duration(4.0)
    hud.show_message("hello")
    check(hud.message_label.visible and hud.message_label.text == "hello",
        "show_message() shows the label with the new text", state)
    hud._process(3.9)
    check(hud.message_label.visible,
        "3.9 s into a 4 s message the label is still visible", state)
    hud._process(0.2)
    check(not hud.message_label.visible, "past the duration the label hides", state)
    check(is_equal_approx(hud.message_timer, 0.0), "the timer is reset when the message hides", state)
    # Two frames so that the deferred _adjust_size() of show_message() has run.
    await process_frame
    await process_frame
    get_root().remove_child(hud)
    hud.free()
    await process_frame

    # --- 3. The live map: read at start, applied on a change ---
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    check(is_equal_approx(main_map.hud_message_duration, 5.0),
        "main_map._load_settings() read 5 from cfg (got: %s)" % main_map.hud_message_duration, state)
    check(is_equal_approx(main_map.hud.message_duration, 5.0),
        "the setting was applied to the HUD at map start", state)

    slider2.value = 7.5
    main_map.apply_settings()
    check(is_equal_approx(main_map.hud.message_duration, 7.5),
        "apply_settings() pushed the new value into the running HUD", state)

    settings2.queue_free()
    _finish(main_map, state)

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("HUD MESSAGE DURATION TEST FAILED")
        quit(1)
    else:
        print("HUD MESSAGE DURATION TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
