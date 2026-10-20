# Headless test for the settings-block infrastructure (scripts/settings_block.gd):
#   godot --headless --path . --script res://tests/test_settings_blocks.gd
#
# Checks:
#   1. The "Edge scrolling speed" block of the settings menu: the parent checkbox
#      gates the heading and the slider row — editable and drawn normally while it is
#      on, non-editable and dimmed while it is off, everything restored when it comes
#      back. The speed value is not reset: a non-editable slider keeps its value, and
#      the value is still saved to user://settings.cfg.
#   2. The reopen path: a saved edge_scrolling = false opens with the block switched
#      off (load_settings() assigns button_pressed, which does not emit toggled).
#   3. The mechanism is data, not code: blocks declared over arbitrary controls —
#      built here in code — behave the same, including a block nested inside another
#      one: switching the outer gate off takes the inner block with it, and switching
#      it back on gives it its own state again.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")
const SETTINGS_SCENE := "res://scenes/settings_menu.tscn"
const BLOCK_SCRIPT := "res://scripts/settings_block.gd"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    # A known starting point: the test asserts the default-on block, and the machine
    # it runs on may carry any settings.cfg.
    var seed_cfg := ConfigFile.new()
    seed_cfg.set_value("interface", "edge_scrolling", true)
    seed_cfg.set_value("interface", "edge_scroll_speed", 300.0)
    seed_cfg.save("user://settings.cfg")

    # --- 1. The block of the settings menu ---
    var settings = load(SETTINGS_SCENE).instantiate()
    get_root().add_child(settings)
    await process_frame
    var checkbox = settings.find_child("EdgeScrollingCheckBox", true, false)
    var slider = settings.find_child("EdgeScrollSpeedSlider", true, false)
    var row = settings.find_child("HBoxContainer5", true, false)
    var heading = settings.find_child("Label7", true, false)
    var value_label = settings.find_child("EdgeScrollSpeedValueLabel", true, false)
    check(checkbox != null and slider != null and row != null and heading != null,
        "the edge scrolling controls are found", state)
    if checkbox != null and slider != null and row != null and heading != null:
        check(checkbox.button_pressed, "the parent checkbox is on", state)
        check(slider.editable, "parent on: the slider is editable", state)
        check(heading.modulate.a > 0.9,
            "parent on: the heading is not dimmed (a=%.2f)" % heading.modulate.a, state)
        check(row.modulate.a > 0.9,
            "parent on: the row is not dimmed (a=%.2f)" % row.modulate.a, state)

        # The parent goes off: assigning button_pressed does not emit toggled.
        checkbox.button_pressed = false
        checkbox.toggled.emit(false)
        check(not slider.editable, "parent off: the slider is not editable", state)
        check(heading.modulate.a < 0.9,
            "parent off: the heading is dimmed (a=%.2f)" % heading.modulate.a, state)
        check(row.modulate.a < 0.9,
            "parent off: the value row is dimmed (a=%.2f)" % row.modulate.a, state)
        check(is_equal_approx(slider.value, 300.0),
            "parent off: the value is kept (300 px/s)", state)

        # A non-editable slider still takes its value from code — and still saves it.
        slider.value = 500.0
        settings.save_settings()
        check(value_label != null and value_label.text == "500 px/s",
            "the label follows the value of the disabled slider", state)
        var cfg := ConfigFile.new()
        var err := cfg.load("user://settings.cfg")
        check(err == OK, "settings.cfg saved", state)
        if err == OK:
            check(is_equal_approx(float(cfg.get_value("interface", "edge_scroll_speed", 0.0)), 500.0),
                "the speed is saved while the block is switched off", state)
            check(not bool(cfg.get_value("interface", "edge_scrolling", true)),
                "the parent checkbox is saved as off", state)

        checkbox.button_pressed = true
        checkbox.toggled.emit(true)
        check(slider.editable, "parent on again: the slider is editable", state)
        check(heading.modulate.a > 0.9 and row.modulate.a > 0.9,
            "parent on again: nothing is dimmed", state)

    # --- 2. Reopen over the saved "parent off" ---
    if checkbox != null:
        checkbox.button_pressed = false
        checkbox.toggled.emit(false)
    settings.save_settings()
    settings.queue_free()
    await process_frame
    var settings2 = load(SETTINGS_SCENE).instantiate()
    get_root().add_child(settings2)
    await process_frame
    var checkbox2 = settings2.find_child("EdgeScrollingCheckBox", true, false)
    var slider2 = settings2.find_child("EdgeScrollSpeedSlider", true, false)
    var heading2 = settings2.find_child("Label7", true, false)
    check(checkbox2 != null and slider2 != null and heading2 != null,
        "the reopened settings are found", state)
    if checkbox2 != null and slider2 != null and heading2 != null:
        check(not checkbox2.button_pressed, "the reopen reads the saved parent off", state)
        check(not slider2.editable, "the reopen opens the block switched off", state)
        check(heading2.modulate.a < 0.9, "the reopened heading is dimmed", state)
        check(is_equal_approx(slider2.value, 500.0),
            "the reopen reads the saved speed 500", state)
        var value_label2 = settings2.find_child("EdgeScrollSpeedValueLabel", true, false)
        check(value_label2 != null and value_label2.text == "500 px/s",
            "the reopened label shows the saved speed", state)
        checkbox2.button_pressed = true
        checkbox2.toggled.emit(true)
        check(slider2.editable and heading2.modulate.a > 0.9,
            "the block comes back with the parent", state)
    settings2.queue_free()
    await process_frame

    # --- 3. Blocks declared over arbitrary controls ---
    var probe := Control.new()
    probe.name = "ProbeSettings"
    var outer_gate := CheckBox.new()
    outer_gate.name = "ProbeOuterGate"
    outer_gate.button_pressed = true
    var inner_gate := CheckBox.new()
    inner_gate.name = "ProbeInnerGate"
    inner_gate.button_pressed = true
    var row_probe := HBoxContainer.new()
    row_probe.name = "ProbeRow"
    row_probe.add_child(inner_gate)
    var leaf := HSlider.new()
    leaf.name = "ProbeLeaf"
    var block_script = load(BLOCK_SCRIPT)
    var outer_deps: Array[NodePath] = [NodePath("../ProbeRow")]
    var inner_deps: Array[NodePath] = [NodePath("../ProbeLeaf")]
    var outer_block = block_script.new()
    outer_block.name = "ProbeOuterBlock"
    outer_block.gate = NodePath("../ProbeOuterGate")
    outer_block.dependents = outer_deps
    var inner_block = block_script.new()
    inner_block.name = "ProbeInnerBlock"
    inner_block.gate = NodePath("../ProbeRow/ProbeInnerGate")
    inner_block.dependents = inner_deps
    probe.add_child(outer_gate)
    probe.add_child(outer_block)
    probe.add_child(row_probe)
    probe.add_child(inner_block)
    probe.add_child(leaf)
    get_root().add_child(probe)
    await process_frame
    check(leaf.editable, "probe: the leaf slider is editable", state)

    outer_gate.button_pressed = false
    outer_gate.toggled.emit(false)
    check(not leaf.editable, "probe: the nested block follows the outer gate off", state)
    check(inner_gate.disabled,
        "probe: the outer block switches the inner gate off", state)
    check(leaf.modulate.a < 0.9,
        "probe: the nested block is dimmed (a=%.2f)" % leaf.modulate.a, state)

    outer_gate.button_pressed = true
    outer_gate.toggled.emit(true)
    check(leaf.editable and not inner_gate.disabled,
        "probe: the outer gate back on restores the nested block", state)
    check(leaf.modulate.a > 0.9,
        "probe: the nested block is bright again (a=%.2f)" % leaf.modulate.a, state)

    inner_gate.button_pressed = false
    inner_gate.toggled.emit(false)
    check(not leaf.editable, "probe: the inner gate gates its own leaf", state)
    check(leaf.modulate.a < 0.9, "probe: the inner gate dims its own leaf", state)
    inner_gate.button_pressed = true
    inner_gate.toggled.emit(true)
    check(leaf.editable, "probe: the inner gate back on", state)

    get_root().remove_child(probe)
    probe.free()
    await process_frame

    _finish(state)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("SETTINGS BLOCKS TEST FAILED")
        quit(1)
    else:
        print("SETTINGS BLOCKS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
