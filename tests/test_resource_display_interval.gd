# Headless test for the "Resource display update interval" setting:
#   godot --headless --path . --script res://tests/test_resource_display_interval.gd
#
# Verifies:
#   1. The slider in the settings (the "Game" tab): range 1..5, step 1; the key
#      game/resource_display_interval is saved to user://settings.cfg and
#      read back when the settings are reopened.
#   2. CityData.set_resource_display_interval(): clamps to 1..5, whole values,
#      advances the era when the value changes; tick_resource_display() advances
#      the era as the interval accumulates.
#   3. On the live scene MainMap.tscn (new game, interval 3 sec): the supply
#      label of the "Resources" tab, the top row "Food: N", the "Required/in
#      storage" row in the building details tooltip and the left column of the
#      control panel update ONLY when the interval elapses; the event-driven
#      city_ui.refresh_light() updates instantly.
#   4. The quality label in the "Resources" tab row is a RichTextLabel with
#      BBCode enabled (text with [color=…] tags), and on an empty quality
#      breakdown it hides.
#
# IMPORTANT: after the last await all the checking code runs synchronously in
# one frame — the main_map._process accumulator does not have time to advance
# the era, and the checks are deterministic. The only await after them is at
# the very end (point 3f, measuring the geometry of the rows): containers
# recompute their sizes at the end of the frame, and the eras are not checked
# there anymore.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")

    # --- 1. Settings menu: slider and config key ---
    var settings = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings)
    await process_frame
    var slider = settings.find_child("ResourceDisplayIntervalSlider", true, false)
    var value_label = settings.find_child("ResourceDisplayIntervalValueLabel", true, false)
    check(slider != null, "slider ResourceDisplayIntervalSlider found", state)
    check(value_label != null, "label ResourceDisplayIntervalValueLabel found", state)
    if slider != null:
        check(is_equal_approx(slider.min_value, 1.0) and is_equal_approx(slider.max_value, 5.0),
            "slider is set from 1 to 5 seconds", state)
        check(is_equal_approx(slider.step, 1.0), "slider step is 1 second", state)
        slider.value = 3.0
    settings.save_settings()
    check(value_label != null and value_label.text == "3 sec",
        "slider label shows \"3 sec\" (got: %s)" % (value_label.text if value_label else "null"), state)
    var cfg = ConfigFile.new()
    var err = cfg.load("user://settings.cfg")
    check(err == OK, "settings.cfg saved", state)
    if err == OK:
        check(is_equal_approx(float(cfg.get_value("game", "resource_display_interval", 0.0)), 3.0),
            "key game/resource_display_interval saved with value 3", state)

    # Reopening the settings reads the saved value.
    settings.queue_free()
    await process_frame
    var settings2 = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings2)
    await process_frame
    var slider2 = settings2.find_child("ResourceDisplayIntervalSlider", true, false)
    check(slider2 != null and is_equal_approx(slider2.value, 3.0),
        "slider reads the saved value 3", state)
    settings2.queue_free()
    await process_frame

    # --- 2. CityData: clamp, step and "era" ---
    city.set_resource_display_interval(10.0)
    check(is_equal_approx(city.resource_display_interval, 5.0),
        "clamp from above: 10 → 5 seconds", state)
    city.set_resource_display_interval(0.0)
    check(is_equal_approx(city.resource_display_interval, 1.0),
        "clamp from below: 0 → 1 second", state)
    check(is_equal_approx(city.resource_display_interval, roundf(city.resource_display_interval)),
        "interval is always whole (step 1 second)", state)
    var epoch_unit = city.resource_display_epoch
    city.tick_resource_display(0.5)
    check(city.resource_display_epoch == epoch_unit,
        "with a 1 sec interval half a second does not advance the era", state)
    city.tick_resource_display(0.6)
    check(city.resource_display_epoch > epoch_unit,
        "the era advances once the interval has accumulated", state)
    var epoch_same = city.resource_display_epoch
    city.set_resource_display_interval(1.0)
    check(city.resource_display_epoch == epoch_same,
        "setting the same value again is a no-op (the era does not change)", state)
    # We keep 1 sec: main_map._ready will apply the three seconds saved in p.1.
    city.set_resource_display_interval(1.0)

    # --- 3. Integration on the live MainMap scene ---
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    check(is_equal_approx(main_map.resource_display_interval, 3.0),
        "main_map._load_settings() read interval 3 from cfg (got: %s)" % main_map.resource_display_interval, state)
    check(is_equal_approx(city.resource_display_interval, 3.0),
        "the setting was applied to CityData at map start", state)

    main_map.open_city()
    await process_frame
    var city_ui = main_map.city_ui
    check(city_ui.visible, "the city interface is open", state)

    # --- FURTHER ONLY SYNCHRONOUS CODE (no await): deterministic eras ---
    # Clean accumulator start: changing the value resets accum (1 → 3).
    city.set_resource_display_interval(1.0)
    city.set_resource_display_interval(3.0)
    check(is_equal_approx(city.resource_display_interval, 3.0),
        "interval set to 3 seconds", state)

    var res_tab = city_ui.resources_tab
    var pid := ""
    for k in res_tab.amount_labels.keys():
        pid = k
        break
    check(pid != "", "the \"Resources\" tab has at least one row", state)

    # --- 3a. Supply label of the "Resources" tab ---
    if pid != "":
        var label = res_tab.amount_labels.get(pid, null)
        check(label != null, "row supply label found", state)
        var prod_name: String = str(res_tab.products.get(pid, {}).get("name", pid))
        var amount_before: int = int(city.city_storage.get(pid, 0))
        city_ui.refresh_light()  # event-driven update — instantly
        var text_before: String = label.text
        check(text_before == "%s: %d  " % [prod_name, amount_before],
            "after the event-driven update the label shows the current supply %d (got: \"%s\")" % [amount_before, text_before], state)

        # The "events are instant" rule: refresh_light() sees the new supply at once.
        city.add_to_storage(pid, 5)
        city_ui.refresh_light()
        check(label.text == "%s: %d  " % [prod_name, amount_before + 5],
            "refresh_light() (event) updated the label instantly to %d" % (amount_before + 5), state)

        # Tick path: before the interval elapses city_updated does not move the label.
        var epoch_res = city.resource_display_epoch
        var shown: String = label.text
        city.tick_resource_display(1.0)
        check(city.resource_display_epoch == epoch_res,
            "interval 3 sec: after 1 second the era is unchanged", state)
        city.emit_signal("city_updated")
        check(label.text == shown,
            "before the interval elapses the city_updated tick does not change the supply label", state)
        city.tick_resource_display(1.0)
        check(city.resource_display_epoch == epoch_res,
            "interval 3 sec: after 2 seconds the era is unchanged", state)
        city.tick_resource_display(1.0)
        check(city.resource_display_epoch > epoch_res,
            "interval 3 sec: on the 3rd second the era is advanced", state)
        # Change the storage BEFORE emitting with the era elapsed — the tick must show it.
        city.add_to_storage(pid, 5)
        city.emit_signal("city_updated")
        check(label.text == "%s: %d  " % [prod_name, amount_before + 10],
            "after the interval the city_updated tick updated the label to %d (got: \"%s\")"
                % [amount_before + 10, label.text], state)

    # --- 3b. Top row "Food: N" ---
    # TopFoodLabel in the scene became an HBoxContainer with three child labels;
    # the text "Food" lives in city_ui.top_food_value_label (see city_ui.gd:18).
    var food_pid := ""
    for k in city.city_food_pool.keys():
        if bool(city.city_food_pool.get(k, false)):
            food_pid = k
            break
    if food_pid != "":
        city_ui.refresh_light()  # synchronize the era + fresh redraw
        var food_before: String = city_ui.top_food_value_label.text
        var epoch_food = city.resource_display_epoch
        city.add_to_storage(food_pid, 7)
        city.emit_signal("city_updated")
        check(city_ui.top_food_value_label.text == food_before,
            "before the interval the top \"Food\" row did not update", state)
        city.tick_resource_display(1.0)
        city.tick_resource_display(1.0)
        city.tick_resource_display(1.0)
        check(city.resource_display_epoch > epoch_food,
            "the era of the top row was advanced after 3 seconds", state)
        city.emit_signal("city_updated")
        check(city_ui.top_food_value_label.text != food_before,
            "after the interval the top \"Food\" row updated", state)

    # --- 3c. Building details tooltip: the "Required/in storage" row ---
    var btab = city_ui.buildings_tab
    var bdata = null
    for b in btab.buildings_data:
        if b.has("additional_cost"):
            bdata = b
            break
    check(bdata != null, "found a building with additional_cost for the details tooltip", state)
    if bdata != null:
        btab._hovered_building_id = bdata["id"]
        btab._show_building_details(bdata)
        city_ui.ui_helpers.detail_tooltip_panel.visible = true
        check(btab._detail_material_rows.size() > 0,
            "the details tooltip has material rows", state)
        if btab._detail_material_rows.size() > 0:
            var row0: Dictionary = btab._detail_material_rows[0]
            var mat_label = row0["amount_label"]
            var res0: String = row0["resource_id"]
            var req0: int = int(row0["required_amount"])
            var avail0: int = int(city.city_storage.get(res0, 0))
            check(mat_label.text == "%d/%d" % [req0, avail0],
                "the first tooltip build shows the current storage %s" % mat_label.text, state)
            # Synchronize the tooltip era with a fixed interval "jump"
            # (between opening the tooltip and this point the era could have elapsed).
            city.tick_resource_display(1.0)
            city.tick_resource_display(1.0)
            city.tick_resource_display(1.0)
            city.emit_signal("city_updated")
            var epoch_mat = city.resource_display_epoch
            avail0 = int(city.city_storage.get(res0, 0))
            var mat_before: String = mat_label.text
            city.add_to_storage(res0, 50)
            city.emit_signal("city_updated")
            check(mat_label.text == mat_before,
                "before the interval the material row did not update (left: %s)" % mat_before, state)
            city.tick_resource_display(1.0)
            city.tick_resource_display(1.0)
            city.tick_resource_display(1.0)
            check(city.resource_display_epoch > epoch_mat,
                "the building tooltip era was advanced", state)
            city.emit_signal("city_updated")
            var mat_expected: String = "%d/%d" % [req0, avail0 + 50]
            check(mat_label.text == mat_expected,
                "after the interval the material row updated (expected: %s, got: %s)"
                    % [mat_expected, mat_label.text], state)

    # --- 3d. Hex control panel: the left column ---
    var cp = main_map.control_panel
    main_map.select_hex(main_map.city_row, main_map.city_col)  # event — at once
    check(cp.has_selection(), "the city hex is selected", state)
    cp._info_label.text = "SENTINEL"
    var epoch_cp = city.resource_display_epoch
    city.emit_signal("city_updated")
    check(cp._info_label.text == "SENTINEL",
        "before the interval the left column of the panel is not redrawn", state)
    city.tick_resource_display(1.0)
    city.tick_resource_display(1.0)
    city.tick_resource_display(1.0)
    check(city.resource_display_epoch > epoch_cp, "the panel era was advanced", state)
    city.emit_signal("city_updated")
    check(cp._info_label.text != "SENTINEL" and cp._info_label.text != "",
        "after the interval the left column was redrawn", state)

    # --- 3e. Quality label in the "Resources" tab row ---
    # The label must be a RichTextLabel: only it understands the [color=…] (BBCode)
    # tags, and exactly such text lands in the row (GameData.format_quality_share_text).
    # On a plain Label the same string would be rendered as "[color=#a0a0a0]30%[/color]".
    var gd = get_root().get_node("GameData")
    var q_pid := ""
    for k in res_tab.quality_labels.keys():
        q_pid = str(k)
        break
    check(q_pid != "", "the resource list has a row with a quality label", state)
    if q_pid != "":
        var q_breakdown := {"common": 30, "perfect": 60}
        city.city_quality_detail[q_pid] = q_breakdown
        city_ui.refresh_light()  # event-driven update — instantly
        var q_label = res_tab.quality_labels.get(q_pid)
        check(q_label is RichTextLabel,
            "the quality label must be a RichTextLabel (only it has BBCode), got: %s"
            % (q_label.get_class() if q_label != null else "null"), state)
        if q_label is RichTextLabel:
            check((q_label as RichTextLabel).bbcode_enabled,
                "the quality label has bbcode_enabled turned on", state)
            check((q_label as RichTextLabel).fit_content,
                "the quality label fits its content (fit_content)", state)
            check((q_label as RichTextLabel).autowrap_mode == TextServer.AUTOWRAP_OFF,
                "the quality label has line wrapping disabled (AUTOWRAP_OFF) — otherwise it reports
                a minimum width of 1 px, the row stacks vertically, and the icon stretches
                (got: %d)" % (q_label as RichTextLabel).autowrap_mode, state)
            check((q_label as RichTextLabel).vertical_alignment == VERTICAL_ALIGNMENT_CENTER,
                "the quality label text is vertically centered", state)
            var q_expected := "[color=#%s]★[/color] %s" % [
                res_tab.QUALITY_MARKER_COLOR.to_html(false),
                gd.format_quality_share_text(q_breakdown)]
            check(str((q_label as RichTextLabel).text) == q_expected,
                "quality label = blue star + storage shares (expected: \"%s\", got: \"%s\")"
                % [q_expected, str((q_label as RichTextLabel).text)], state)
            # Empty breakdown — the label hides instead of showing 0%.
            city.city_quality_detail[q_pid] = {}
            city_ui.refresh_light()
            check(not (q_label as RichTextLabel).visible,
                "on an empty breakdown the quality label hides", state)
            # Restore the breakdown: it is no longer needed later in the test.
            city.city_quality_detail[q_pid] = q_breakdown
            city_ui.refresh_light()

    # --- 3f. Geometry of the resource list rows (after real layout) ---
    # Containers recompute their sizes at the end of the frame, which is why an
    # await is needed here: the eras above have already been checked, and they are
    # no longer used below.
    # The regression this point catches: a RichTextLabel with fit_content and
    # line wrapping enabled reports a minimum width of 1 px → the HBox gives the
    # label 1 px → "★ (33%/67%)" stacks letter by letter → the row spreads to
    # ~200 px, and the icon (STRETCH_SCALE, vertical FILL) stretches to 40×200.
    # Result: a "one-pixel star" and "broken" resource icons.
    await process_frame
    await process_frame
    var res_list = city_ui.get_node("ContentPanel/ResourcesPanel/ScrollContainer/ResourcesList")
    var tall_rows: int = 0
    var bad_icons: int = 0
    var bad_markers: int = 0
    var rows_checked: int = 0
    var icons_checked: int = 0
    var markers_checked: int = 0
    for node in res_list.get_children():
        if not (node is HBoxContainer):
            continue
        rows_checked += 1
        var row: HBoxContainer = node
        if row.size.y > 64.0:
            tall_rows += 1
            print("  tall row (%.1f px): %s" % [row.size.y, str(row.get_child(0).name)])
        for child in row.get_children():
            if child is TextureRect:
                icons_checked += 1
                var ic: TextureRect = child
                if not is_equal_approx(ic.size.x, 40.0) or not is_equal_approx(ic.size.y, 40.0):
                    bad_icons += 1
                    print("  icon %s: %s" % [str(ic.texture.resource_path.get_file()), str(ic.size)])
            elif child is RichTextLabel and (child as Control).visible:
                # Hidden labels (empty quality breakdown) do not take part in layout
                # and keep a zero size — they are not counted.
                var rl: RichTextLabel = child
                markers_checked += 1
                if rl.size.x < 20.0:
                    bad_markers += 1
                    print("  collapsed quality label: %s" % str(rl.size))
    check(rows_checked > 0, "the resource list has HBoxContainer rows to measure the geometry", state)
    check(icons_checked > 0, "the resource list has icons to measure the geometry (checked: %d)" % icons_checked, state)
    check(markers_checked > 0, "the list has visible quality labels to measure the geometry (checked: %d)" % markers_checked, state)
    check(tall_rows == 0,
        "no resource list row has spread in height (rows taller than 64 px: %d out of %d)"
        % [tall_rows, rows_checked], state)
    check(bad_icons == 0,
        "all resource icons are exactly 40×40 and not stretched to the row height (distorted: %d out of %d)"
        % [bad_icons, icons_checked], state)
    check(bad_markers == 0,
        "quality labels did not collapse to 1 px in width (collapsed: %d)" % bad_markers, state)

    _finish(main_map, state)

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("RESOURCE DISPLAY INTERVAL TEST FAILED")
        quit(1)
    else:
        print("RESOURCE DISPLAY INTERVAL TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
