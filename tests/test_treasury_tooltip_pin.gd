# Headless test of the "pin" behaviour of the treasury breakdown tooltip:
#   godot --headless --path . --script res://tests/test_treasury_tooltip_pin.gd
#
# The treasury breakdown tooltip (the map HUD and the top bar of CityUI) uses one
# and the same ui_helpers.show_treasury_tooltip. The hover behaviour is the same as
# for the building details tooltip: after a delay the panel locks in place, and the
# cursor can be moved onto the tooltip itself. Technically this rests on the pair
# "show while pinned without keep_position" + "live-update on a resource-era change
# with keep_position=true": the second redraw must not move the panel.
#
# We check:
#   1) the first show — the panel is at the cursor (+15, +15);
#   2) keep_position=true with the cursor at a different position — the panel does
#      NOT move, but the content updates;
#   3) without keep_position the panel follows the cursor again;
#   4) keep_position=true on a hidden panel does not work as an "anchor" — the usual
#      show at the cursor (otherwise the tooltip would "jump" to the old place);
#   5) an empty breakdown hides the panel (there is nothing to pin).
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _failed := false

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    await process_frame

    var holder := Control.new()
    root.add_child(holder)
    var ui = load("res://scripts/ui_helpers.gd").new()
    ui.setup(holder, Label.new())
    holder.add_child(ui)
    await process_frame
    await process_frame

    var panel: Panel = ui.treasury_tooltip_panel
    var vbox: VBoxContainer = ui.treasury_tooltip_vbox

    # --- 1. The first draw: the panel appears at the cursor ---
    ui.show_treasury_tooltip(Vector2(100, 100), 42, _income_one_source(), {}, 3.0)
    await process_frame
    await process_frame
    check(panel.visible, "1: the tooltip is visible after the first draw")
    check(panel.position == Vector2(115, 115),
        "1: the panel is at the cursor (+15, +15), actual %s" % str(panel.position))
    var locked_pos: Vector2 = panel.position
    var rows_before: int = vbox.get_child_count()

    # --- 2. Live-update of the "pinned" tooltip: the panel stays in place ---
    ui.show_treasury_tooltip(Vector2(300, 250), 42, _income_two_sources(), {}, 3.0, true)
    await process_frame
    await process_frame
    check(panel.visible, "2: the tooltip is visible after live-update")
    check(panel.position == locked_pos,
        "2: keep_position preserves the panel position (%s → %s)"
            % [str(locked_pos), str(panel.position)])
    check(vbox.get_child_count() > rows_before,
        "2: the content updated (rows %d → %d)"
            % [rows_before, vbox.get_child_count()])

    # --- 3. The usual show (without keep_position) follows the cursor ---
    ui.show_treasury_tooltip(Vector2(200, 200), 42, _income_one_source(), {}, 3.0)
    await process_frame
    check(panel.position == Vector2(215, 215),
        "3: without keep_position the panel follows the cursor, actual %s" % str(panel.position))

    # --- 4. keep_position on a hidden panel: there is no anchor ---
    ui.hide_treasury_tooltip()
    await process_frame
    check(not panel.visible, "4: the tooltip is hidden")
    ui.show_treasury_tooltip(Vector2(250, 220), 42, _income_one_source(), {}, 3.0, true)
    await process_frame
    check(panel.visible, "4: the tooltip is shown again")
    check(panel.position == Vector2(265, 235),
        "4: without a visible panel keep_position does not \"anchor\", actual %s" % str(panel.position))

    # --- 5. Empty breakdown: the panel is hidden ---
    ui.show_treasury_tooltip(Vector2(250, 220), 0, {}, {}, 3.0, true)
    await process_frame
    check(not panel.visible, "5: an empty breakdown hides the panel")
    check(vbox.get_child_count() == 0, "5: the content of the empty breakdown is cleared")

    # --- 6. Expenses without income: the panel is shown and also pins ---
    ui.show_treasury_tooltip(Vector2(120, 140), 7, {}, {"Scouting": 12}, 3.0)
    await process_frame
    check(panel.visible, "6: the tooltip with expenses only is visible")
    check(panel.position == Vector2(135, 155),
        "6: the panel is at the cursor, actual %s" % str(panel.position))
    var exp_pos: Vector2 = panel.position
    ui.show_treasury_tooltip(Vector2(600, 400), 7, {}, {"Scouting": 12}, 3.0, true)
    await process_frame
    check(panel.position == exp_pos,
        "6: the expense tooltip also holds its position (%s → %s)"
            % [str(exp_pos), str(panel.position)])

    if _failed:
        print("TREASURY TOOLTIP PIN TEST FAILED")
        quit(1)
    else:
        print("TREASURY TOOLTIP PIN TEST OK")
        quit(0)

# The income map in the format worker_manager.get_actual_treasury_income_map():
# type → source → product → { coins_per_sec, product_name }.
# The keys are IDENTIFIERS (CityData.POPULATION_INCOME_TYPE and
# GameData.profession_source_id), not labels: the label is resolved in the render
# (ui_helpers.show_treasury_tooltip → GameData.get_source_display_name).
func _income_one_source() -> Dictionary:
    return {
        _income_type_key(): {
            _source_key("all"): {
                "fish": {"coins_per_sec": 3.0, "product_name": "Fish"}
            }
        }
    }

func _income_two_sources() -> Dictionary:
    var income: Dictionary = _income_one_source()
    income[_income_type_key()][_source_key("fisherman")] = {
        "fish": {"coins_per_sec": 2.0, "product_name": "Fish"}
    }
    return income

func _income_type_key() -> String:
    var city = root.get_node("CityData")
    return city.POPULATION_INCOME_TYPE

func _source_key(prof_id: String) -> String:
    var gdata = root.get_node("GameData")
    return gdata.profession_source_id(prof_id)

func check(cond: bool, msg: String) -> void:
    if cond:
        print("OK: ", msg)
    else:
        _failed = true
        push_error("ASSERT FAILED: " + msg)
        print("ASSERT FAILED: ", msg)
