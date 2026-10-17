# Headless test of the "sticking" of the upgrade tooltip of a building:
#   godot --headless --path . --script res://tests/test_upgrade_tooltip_pin.gd
#
# The tooltip of the "Upgrade" button in the building details window is a rich panel of
# its own (building_panel.upgrade_tooltip_panel), assembled from the costs of the improved
# version. It behaves as the details tooltip of a building on the "Buildings" tab: after
# the cursor has been held on the button for UPGRADE_TOOLTIP_DELAY, the panel is PINNED in
# place, and the cursor can be moved onto it — onto a group resource in its rows, to unfold
# the composition of the group (the composition itself is drawn by the shared
# ui_helpers.group_tooltip_panel on top of the upgrade tooltip).
#
# Checks:
#   1. The content of the tooltip is assembled from the data of the improved version (the
#      materials of additional_cost come as the resource rows), not from the constants of
#      the test.
#   2. The first show — the panel appears under the button (as before the sticking was
#      introduced).
#   3. The panel is pinned: a repeated show with keep_position keeps the position.
#   4. The rows with a group resource CATCH the mouse — the cursor reaches them through the
#      panel (the panel itself catches the mouse, its content does not), and the composition
#      tooltip of the group really appears on hovering such a row.
#   5. Hiding resets the pinning.
#
# The data dependency is the same as in test_building_consumption_ui: the upgrade pair and
# its costs come from data/buildings.json, and the test derives its expectations from the
# data instead of hardcoding the numbers.
#
# IMPORTANT: the script is compiled BEFORE the autoloads are registered, so the autoloads
# are taken through the scene tree.
extends SceneTree

# The hang watchdog: without it a broken _run() coroutine looks from the outside like
# eternal silence. See tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _failed := false

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var gdata = get_root().get_node("GameData")
    var city = get_root().get_node("CityData")

    # A building that can be upgraded (upgrades_into) and whose target has costs in
    # additional_cost — otherwise there is nothing to check in the content of the tooltip.
    var pair := _pick_upgrade_pair(gdata)
    check(not pair.is_empty(),
        "data/buildings.json must contain a building with an upgrade whose target has additional_cost")
    if pair.is_empty():
        _finish()
        return
    var from_id: String = str(pair["from"])
    var target: Dictionary = pair["target"]

    # The upgraded building is present in the city, and the technology of the target is
    # researched — otherwise can_upgrade_building is false and the button is not created.
    city.city_built_buildings = [ {"id": from_id, "slots": ["empty"], "quality_priority": "best"}]
    var unlock_tech := str(target.get("unlock_tech", ""))
    if not unlock_tech.is_empty() and not city.is_tech_unlocked(unlock_tech):
        city.unlocked_technologies.append(unlock_tech)

    # The building details window of the building with the upgrade button.
    var holder := Control.new()
    root.add_child(holder)
    var ui_helpers = load("res://scripts/ui_helpers.gd").new()
    ui_helpers.setup(holder, Label.new())
    holder.add_child(ui_helpers)
    var panel = load("res://scripts/building_panel.gd").new()
    root.add_child(panel)
    await process_frame
    await process_frame

    panel.open(from_id, {
        "products": gdata.products,
        "raw_resources": gdata.raw_resources,
        "crafts_data": gdata.crafts,
        "ui_helpers": ui_helpers,
    })
    await process_frame
    await process_frame
    check(panel.visible, "the building details window is open")

    # --- 1. The content is assembled from the data of the improved version ---
    var filled: bool = panel._fill_upgrade_tooltip_content(0)
    check(filled, "the tooltip of the upgrade of \"%s\" must be filled" % from_id)
    if not filled:
        _finish()
        return
    var texts := _collect_texts(panel.upgrade_tooltip_content)
    check(_has_text(texts, str(target.get("name", ""))),
        "the tooltip must name the improved building \"%s\" (got: %s)"
            % [str(target.get("name", "")), str(texts)])
    # Every resource of additional_cost must come as a row (through make_resource_entry):
    # the row is recognized by the name of the resource in the text of the content.
    var bundles: Array = gdata.parse_additional_cost(target.get("additional_cost", []))
    var expected_rows := 0
    for bundle in bundles:
        expected_rows += (bundle as Dictionary).size()
    check(expected_rows > 0, "the improved building must have additional_cost in the data")
    for bundle in bundles:
        for res_id in bundle:
            check(_has_text(texts, gdata.format_resource_name(str(res_id))),
                "the tooltip must have a row for the material \"%s\" (got: %s)"
                    % [str(res_id), str(texts)])

    # --- 2. The first show: the panel appears under the button ---
    var button := Button.new()
    button.size = Vector2(28, 28)
    button.position = Vector2(200, 120)
    panel.add_child(button)
    await process_frame
    panel._show_upgrade_tooltip_panel(button)
    await process_frame
    check(panel.upgrade_tooltip_panel.visible, "the tooltip is visible after the show")
    var shown_pos: Vector2 = panel.upgrade_tooltip_panel.position
    var btn_rect: Rect2 = button.get_global_rect()
    check(is_equal_approx(shown_pos.y, btn_rect.position.y + btn_rect.size.y + 4.0),
        "the panel must stand under the button (expected %.1f, got %.1f)"
            % [btn_rect.position.y + btn_rect.size.y + 4.0, shown_pos.y])

    # --- 3. The pinned panel keeps its position on a repeated show ---
    panel._show_upgrade_tooltip_panel(button, true)
    await process_frame
    check(panel.upgrade_tooltip_panel.position == shown_pos,
        "keep_position must preserve the position of the pinned panel (%s → %s)"
            % [str(shown_pos), str(panel.upgrade_tooltip_panel.position)])

    # --- 4. The rows with a group resource catch the mouse ---
    # The panel itself catches the mouse (so that the cursor does not fall through to the
    # panel of the building behind it), while its content does not — the row handlers of
    # the group resources live exactly there.
    check(panel.upgrade_tooltip_panel.mouse_filter == Control.MOUSE_FILTER_STOP,
        "the upgrade tooltip panel must catch the mouse (mouse_filter = STOP)")
    check(panel.upgrade_tooltip_content.mouse_filter == Control.MOUSE_FILTER_IGNORE,
        "the content of the tooltip must not intercept the input (mouse_filter = IGNORE)")
    # A row of a group resource is reachable by the cursor: the label has MOUSE_FILTER_PASS
    # and a handler of the hovering (the composition of the group is drawn on top).
    var group_label: Control = _find_group_label(panel.upgrade_tooltip_content)
    if group_label != null:
        check(group_label.mouse_filter != Control.MOUSE_FILTER_IGNORE,
            "a row of a group resource must catch the mouse, otherwise the tooltip will not show")
        check(group_label.mouse_entered.get_connections().size() > 0,
            "a row of a group resource must react to hovering with the composition tooltip")
        # The composition tooltip of the group really appears on hovering such a row.
        group_label.mouse_entered.emit()
        await process_frame
        check(ui_helpers.group_tooltip_panel.visible,
            "hovering a group resource in the upgrade tooltip must unfold the composition of the group")
        var group_texts := _collect_texts(ui_helpers.group_tooltip_content)
        check(not group_texts.is_empty(),
            "the composition of the group in the tooltip must not be empty")
        group_label.mouse_exited.emit()
        await process_frame
        check(not ui_helpers.group_tooltip_panel.visible,
            "leaving the group row must hide the composition of the group")

    # --- 5. The pinned panel disappears when the cursor is taken off it ---
    # The panel is pinned (step 3), and the cursor is on neither the button nor the panel:
    # after the grace of leaving the panel must hide itself, otherwise it would hang over
    # the interface of the building until the window is closed.
    # We drive the cursor explicitly: the headless run has no real pointer, and the polling
    # of _process_upgrade_tooltip reads the position from the viewport.
    panel._upgrade_leave_timer = 0.0
    _set_mouse_position(Vector2(-1000, -1000))
    await process_frame
    check(panel.upgrade_tooltip_panel.visible,
        "the pinned panel must survive the first frame after the cursor has left")
    # The grace on leaving has passed — the panel is hidden.
    panel._upgrade_leave_timer = panel.UPGRADE_TOOLTIP_LEAVE_GRACE
    await process_frame
    check(not panel.upgrade_tooltip_panel.visible,
        "the pinned panel must disappear when the cursor is taken off it")
    check(not panel._upgrade_tooltip_locked,
        "hiding on leaving must reset the pinning of the tooltip")

    # --- 6. Hiding resets the pinning ---
    panel._fill_upgrade_tooltip_content(0)
    panel._show_upgrade_tooltip_panel(button)
    panel._upgrade_tooltip_locked = true
    await process_frame
    check(panel.upgrade_tooltip_panel.visible, "the tooltip is shown again")
    panel._hide_upgrade_tooltip()
    await process_frame
    check(not panel.upgrade_tooltip_panel.visible, "the tooltip must be hidden")
    check(not panel._upgrade_tooltip_locked, "hiding must reset the pinning of the tooltip")

    holder.queue_free()
    panel.queue_free()
    _finish()

# The headless run has no real pointer, and the polling of the sticking reads the position
# from the viewport — we set it by hand.
func _set_mouse_position(pos: Vector2) -> void:
    var vp := root.get_viewport()
    if vp != null:
        vp.warp_mouse(pos)

# The pair "a building -> its improved version", where the improved version has
# additional_cost. The choice comes from the data, not from a constant.
func _pick_upgrade_pair(gdata) -> Dictionary:
    for b in gdata.buildings:
        var from_id := str(b.get("id", ""))
        var to_id := str(b.get("upgrades_into", ""))
        if from_id.is_empty() or to_id.is_empty():
            continue
        for target in gdata.buildings:
            if str(target.get("id", "")) != to_id:
                continue
            if target.has("additional_cost"):
                return {"from": from_id, "target": target}
            break
    return {}

# The first row of a group resource (a label with the composition tooltip) in the content.
func _find_group_label(node: Node) -> Control:
    for child in node.get_children():
        if child is Control and child.get("underline_text") != null:
            return child
        var found := _find_group_label(child)
        if found != null:
            return found
    return null

func _collect_texts(node: Node) -> Array:
    var result: Array = []
    for child in node.get_children():
        if child is Label:
            result.append(str((child as Label).text))
        else:
            result.append_array(_collect_texts(child))
    return result

func _has_text(texts: Array, needle: String) -> bool:
    if needle.is_empty():
        return false
    for t in texts:
        if str(t).contains(needle):
            return true
    return false

func _finish() -> void:
    WATCHDOG.report_skipped()
    if _failed:
        print("UPGRADE TOOLTIP PIN TEST FAILED")
        quit(1)
    else:
        print("UPGRADE TOOLTIP PIN TEST OK")
        quit(0)

func check(cond: bool, msg: String) -> void:
    if cond:
        print("OK: ", msg)
    else:
        _failed = true
        push_error("ASSERT FAILED: " + msg)
        print("ASSERT FAILED: ", msg)
