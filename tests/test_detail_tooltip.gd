# Headless test of the "stuck" scrollbar of tooltips (building details, resource flows):
#   godot --headless --path . --script res://tests/test_detail_tooltip.gd
#
# Bug scenario: the tooltip is shown for a "large" building (> 15 rows, with a
# scrollbar), then the content is rebuilt for a "small" building (as when
# quickly moving the cursor between buttons) and the tooltip is shown again —
# in the same frame (delay = 0) and after hiding (delay > 0).
# Expectation: the panel size is recalculated for the new content, and the
# scrollbar, which the small content does not need, does not remain.
extends SceneTree

# Hang watchdog: without it, an aborted _run() coroutine looks from the outside
# like eternal silence (this is exactly what the hung run looked like because of
# calling show_flow_tooltip with a Dictionary instead of a String). Details — in
# tests/watchdog.gd.
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

    var panel: Panel = ui.detail_tooltip_panel
    var scroll: ScrollContainer = ui.detail_tooltip_scroll
    var max_h: float = ui.DETAIL_TOOLTIP_MAX_ROWS * ui.DETAIL_TOOLTIP_ROW_HEIGHT

    # --- 1. Large content: tooltip with a scrollbar ---
    _fill_content(ui.detail_tooltip_content, 22)
    ui.show_building_detail_tooltip(Vector2(100, 100))
    await process_frame
    await process_frame
    check(panel.visible, "the large building tooltip is visible")
    check(panel.size.y <= max_h + 8.0 + 0.5,
        "the panel height is limited to 15 rows (actual %.1f)" % panel.size.y)
    check(scroll.get_v_scroll_bar().visible, "a scrollbar is expected for the large content")

    # --- 2. Quick switch to a "small" building: rebuild and
    # re-show in the same frame (worst case: delay = 0) ---
    _fill_content(ui.detail_tooltip_content, 3)
    ui.show_building_detail_tooltip(Vector2(100, 100))
    await process_frame
    await process_frame
    check(panel.visible, "the small building tooltip is visible")
    check(panel.size.y < max_h,
        "the panel height is recalculated for the small content (actual %.1f)" % panel.size.y)
    check(not scroll.get_v_scroll_bar().visible,
        "the scrollbar must not remain for the small content")

    # --- 3. Variant with a delay: the tooltip is hidden, the content is rebuilt,
    # and a frame later it is shown again (the content has not been laid out all
    # this time) ---
    _fill_content(ui.detail_tooltip_content, 22)
    ui.show_building_detail_tooltip(Vector2(100, 100))
    await process_frame
    _fill_content(ui.detail_tooltip_content, 3)
    ui.hide_building_detail_tooltip()
    await process_frame
    await process_frame
    ui.show_building_detail_tooltip(Vector2(100, 100))
    await process_frame
    await process_frame
    check(panel.visible, "the re-shown tooltip is visible")
    check(panel.size.y < max_h,
        "after hiding, the height is recalculated (actual %.1f)" % panel.size.y)
    check(not scroll.get_v_scroll_bar().visible,
        "after hiding, the scrollbar must not come back")

    # --- 3b. The case "the content is rebuilt for another building while the
    # panel is VISIBLE, and there is no repeated show call" is deliberately NOT
    # checked. The panel size is computed only inside show_building_detail_tooltip
    # (ui_helpers.gd); there is no per-frame recomputation in ui_helpers — there
    # is nothing to wait for the panel to shrink without a repeated show(). In
    # the game this state is not observed either: city_ui._process either hides
    # the tooltip (the cursor left the button) or shows it again (hovering over
    # the button of a new building). ---

    # --- 4. The same scenario for the flow tooltip (the "Resources" tab) ---
    # The show_flow_tooltip calls use the FULL argument list: the resource_id
    # parameter has type String, and a Dictionary in its place aborts the _run()
    # coroutine — control never reaches quit(), and the run hangs.
    var fpanel: Panel = ui.flow_tooltip_panel
    var fscroll: ScrollContainer = ui.flow_tooltip_scroll
    # special_yield in the game is {product_id: amount} (GameData.
    # get_special_yield → data/products/*.json), so here too the values are
    # numbers, not dictionaries: otherwise int(special_yield[id]) inside
    # show_flow_tooltip would trip over the type.
    var sources := {}
    for i in 25:
        sources["Source %d" % i] = 10 + i
    ui.show_flow_tooltip(Vector2(100, 100), "Resource", sources, "", {}, {})
    await process_frame
    await process_frame
    check(fpanel.visible, "the large flow tooltip is visible")
    check(fscroll.get_v_scroll_bar().visible, "a scrollbar is expected for the large flow")
    var small := {"One": 5}
    ui.show_flow_tooltip(Vector2(100, 100), "Resource", small, "", {}, {})
    await process_frame
    await process_frame
    check(fpanel.size.y < max_h,
        "the flow tooltip height is recalculated (actual %.1f)" % fpanel.size.y)
    check(not fscroll.get_v_scroll_bar().visible,
        "the flow scrollbar must not remain for the small content")

    if _failed:
        print("DETAIL TOOLTIP TEST FAILED")
        quit(1)
    else:
        print("DETAIL TOOLTIP TEST OK")
        quit(0)

# Imitation of rebuilding the content in _show_building_details (buildings_tab):
# a title + an autowrap description of fixed width (as in the real tooltip)
# + list rows.
func _fill_content(content: VBoxContainer, rows: int) -> void:
    for child in content.get_children():
        child.free()
    var title := Label.new()
    title.text = "Building"
    title.add_theme_font_size_override("font_size", 18)
    content.add_child(title)
    var desc := Label.new()
    desc.text = "Building description: a text long enough to wrap onto several lines at a fixed tooltip width."
    desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    desc.custom_minimum_size = Vector2(420, 0)
    content.add_child(desc)
    for i in rows:
        var lbl := Label.new()
        lbl.text = "• Row %d: cost, production slots, recipes" % i
        content.add_child(lbl)

func check(cond: bool, msg: String) -> void:
    if cond:
        print("OK: ", msg)
    else:
        _failed = true
        push_error("ASSERT FAILED: " + msg)
        print("ASSERT FAILED: ", msg)
