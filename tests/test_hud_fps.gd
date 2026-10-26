# Headless test for the HUD FPS counter and the "Show FPS counter" setting:
#   godot --headless --path . --script res://tests/test_hud_fps.gd
#
# Verifies:
#   1. The settings menu (the "Interface" tab): the FpsCheckBox exists and is on
#      by default; switching it off saves the key interface/show_fps and a reopen
#      reads the saved value back.
#   2. On the live scene MainMap.tscn: main_map reads show_fps from the config and
#      shows/hides the FpsLabel in the top right corner accordingly — both at the
#      map start and live, through apply_settings().
#   3. The counter shows the engine frame rate, the Menu button next to it keeps
#      its text-only width, and the panel hugs the right edge of the screen.
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
    var checkbox = settings.find_child("FpsCheckBox", true, false)
    check(checkbox != null, "checkbox FpsCheckBox found in the Interface tab", state)
    if checkbox != null:
        check(checkbox.button_pressed,
            "without a settings file the FPS counter is on by default", state)
        checkbox.button_pressed = false
        checkbox.toggled.emit(false)
    var cfg := ConfigFile.new()
    var err := cfg.load("user://settings.cfg")
    check(err == OK, "settings.cfg saved", state)
    if err == OK:
        check(not bool(cfg.get_value("interface", "show_fps", true)),
            "key interface/show_fps saved as off", state)

    # Reopening the settings reads the saved value.
    settings.queue_free()
    await process_frame
    var settings2 = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings2)
    await process_frame
    var checkbox2 = settings2.find_child("FpsCheckBox", true, false)
    check(checkbox2 != null and not checkbox2.button_pressed,
        "the reopened settings read the FPS counter off", state)
    settings2.queue_free()
    await process_frame

    # --- 2. The live map: read at start, applied on a change ---
    # A known starting point: the machine may carry any settings.cfg.
    var seed_cfg := ConfigFile.new()
    seed_cfg.set_value("interface", "show_fps", false)
    seed_cfg.save("user://settings.cfg")

    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    check(not main_map.show_fps,
        "main_map._load_settings() read show_fps = false (got: %s)" % main_map.show_fps, state)
    check(main_map.fps_label != null and not main_map.fps_label.visible,
        "the FPS label is hidden at the map start", state)
    var hidden_panel_width: float = main_map.top_right_panel.size.x

    seed_cfg = ConfigFile.new()
    seed_cfg.set_value("interface", "show_fps", true)
    seed_cfg.save("user://settings.cfg")
    main_map.apply_settings()
    check(main_map.show_fps and main_map.fps_label.visible,
        "apply_settings() shows the FPS label again", state)
    check(main_map.top_right_panel.size.x > hidden_panel_width,
        "the panel grows to make room for the counter (%.1f -> %.1f)"
            % [hidden_panel_width, main_map.top_right_panel.size.x], state)

    # --- 3. The counter, the Menu button and the panel ---
    main_map.fps_label._refresh()
    check(main_map.fps_label.text.begins_with("FPS: "),
        "the counter shows the frame rate (got: %s)" % main_map.fps_label.text, state)

    var menu_min: Vector2 = main_map.menu_button.get_combined_minimum_size()
    check(main_map.menu_button.size.x <= menu_min.x + 1.0,
        "the Menu button is no wider than its text (got: %.1f, minimum: %.1f)"
            % [main_map.menu_button.size.x, menu_min.x], state)

    var view_width: float = get_root().get_visible_rect().size.x
    var panel_rect: Rect2 = main_map.top_right_panel.get_global_rect()
    check(absf(panel_rect.end.x - (view_width - main_map.TOP_RIGHT_MARGIN)) < 1.0,
        "the top right panel hugs the right edge (end: %.1f, expected: %.1f)"
            % [panel_rect.end.x, view_width - main_map.TOP_RIGHT_MARGIN], state)

    _finish(main_map, state)

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("HUD FPS TEST FAILED")
        quit(1)
    else:
        print("HUD FPS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
