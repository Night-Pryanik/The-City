# Test of the recipe badge and of the scrolling row of unlocked icons on a technology button.
#   godot --headless --path . --script res://tests/test_tech_unlock_recipes.gd
#
# A technology that opens recipes shows ONE badge for the whole set (the row has room for four
# icons of content of any kind, and a technology may open fourteen recipes), and the names of
# what it opens live in the tooltip of that badge. Two more rules are checked here:
#   - the row is a strip: it shows four slots and scrolls when there are more, without a bar,
#     and an arrow takes a slot of its own rather than lying over an icon;
#   - the scrolling (the arrows, the wheel) must not steal the click that starts the research.
#
# Checks:
#   1. A technology with recipes contributes exactly one item, with the recipe badge.
#   2. Its tooltip names every recipe the technology opens, one per line, and nothing else.
#   3. A technology without recipes contributes no such item.
#   4. The button draws the badge among its icons, and the row of a fitting set shows no arrows.
#   5. When the content is wider than the row, the arrows appear, the right one scrolls the row,
#      the wheel over the row scrolls it too, and the tree under the cursor does not move.
#   6. A premium recipe joins the list only with the rung of the brand that grants it, and then it
#      is named by the city rather than by the title of the recipe.
extends SceneTree

# The hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")
# Enough frames for the deferred layout of the freshly built tree.
const SETTLE_FRAMES := 4

var _gdata = null
var _cdata = null
var _mgr = null
var _icons = null
# The constants of the tree. The script of the tree is not preloaded: a preload would compile
# it before the autoloads it names are registered, and the whole feature would fail to load.
var _const = {}

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state: Dictionary = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    for _i in range(SETTLE_FRAMES):
        await process_frame
    main_map.open_city()
    for _i in range(SETTLE_FRAMES):
        await process_frame
    # The autoloads are not resolvable at the compile time of a --script file.
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _icons = get_root().get_node("IconRegistry")
    _mgr = main_map.get("challenge_manager")
    check(_mgr != null, "the map carries the challenge manager", state)
    if _mgr == null:
        _finish(state)
        return
    var city_ui = main_map.get_node_or_null("CityUI")
    check(city_ui != null, "CityUI is found", state)
    if city_ui == null:
        _finish(state)
        return

    city_ui.show_technologies_tab()
    for _i in range(SETTLE_FRAMES):
        await process_frame
    var tree = city_ui.tech_tree
    _const = tree.get_script().get_script_constant_map()

    _check_items(tree, state)
    _check_button(tree, state)
    await _check_scrolling(tree, state)
    _check_premium_recipe(tree, state)

    _finish(state)

# --- The list of what a technology opens -------------------------------------------------

func _recipe_items(tree, tech_id: String) -> Array:
    var found: Array = []
    for item in tree._get_unlock_items(tech_id):
        if item.get("icon", "") == _const["ICON_NEW_RECIPES"]:
            found.append(item)
    return found

func _recipe_names(tech_id: String) -> Array[String]:
    var names: Array[String] = []
    for craft in _gdata.crafts:
        if craft.get("unlock_tech", "") != tech_id:
            continue
        if not _cdata.is_craft_fame_granted(craft):
            continue
        names.append(_gdata.get_craft_display_name(craft))
    return names

func _tooltip_names(tip: String) -> Array[String]:
    var out: Array[String] = []
    for line in tip.split("\n").slice(1):
        out.append(line.substr(2))
    return out

func _check_items(tree, state: Dictionary) -> void:
    var tech_id := "dyeing"
    var names := _recipe_names(tech_id)
    check(names.size() > 4,
        "the sample technology opens more recipes than the row could show one by one (%d)"
            % names.size(), state)

    var items := _recipe_items(tree, tech_id)
    check(items.size() == 1,
        "the recipes of one technology make exactly one unlock item (%d)" % items.size(), state)
    if items.is_empty():
        return
    var tip: String = items[0]["tip"]
    check(tip.begins_with(tr("Unlocks recipes:")),
        "the tooltip opens with the heading of the list", state)

    var lines := tip.split("\n")
    check(lines.size() == names.size() + 1,
        "one line per recipe under the heading (%d of %d)" % [lines.size(), names.size() + 1], state)
    for name in names:
        check(tip.contains("- " + name),
            "the tooltip names the recipe \"%s\"" % name, state)
    var listed := _tooltip_names(tip)
    var sorted := listed.duplicate()
    sorted.sort()
    check(listed == sorted, "the recipes are listed in the order of their names", state)
    var foreign := []
    for line_name in listed:
        if not names.has(line_name):
            foreign.append(line_name)
    check(foreign.is_empty(),
        "the tooltip lists no recipe of another technology (%s)" % ", ".join(foreign), state)

    check(_recipe_items(tree, "wheel").is_empty(),
        "a technology that opens no recipes gets no recipe badge", state)

# --- The premium recipe in the list ------------------------------------------------------

# A premium recipe is opened by the technology and by the rung of the brand at once, so the research
# alone promises nothing: the line appears only when the rung is paid, and it names the good by the
# city — the same name the slot of the workshop carries — never by the title written in the recipe.
func _check_premium_recipe(tree, state: Dictionary) -> void:
    var ladder := _brand_ladder()
    check(not ladder.is_empty(),
        "the data has a ladder whose rung of the brand grants a recipe of a technology", state)
    if ladder.is_empty():
        return
    var recipe: Dictionary = ladder["recipe"]
    var tech_id := str(recipe.get("unlock_tech", ""))
    var data_name := str(recipe.get("name", ""))
    var tip := _recipe_tip(tree, tech_id)
    check(tip != "", "the technology %s has the badge of recipes" % tech_id, state)
    if tip == "":
        return

    check(not _tooltip_names(tip).has(data_name),
        "the tooltip hides the premium recipe before its rung of the brand", state)

    var saved_city := str(_cdata.city_name)
    _cdata.city_name = "Testfeld"
    _mgr.mark_tier_done(str(ladder["id"]), "brand")
    var after := _tooltip_names(_recipe_tip(tree, tech_id))
    var brand_name := str(_gdata.get_product_name(str(ladder["brand"])))
    check(after.has(brand_name),
        "the tooltip announces the premium recipe \"%s\" once the rung is paid" % brand_name, state)
    check(not after.has(data_name),
        "the line of a premium recipe carries the name of the city, not the title of the recipe (%s)"
            % data_name, state)
    _cdata.city_name = saved_city
    _mgr.done_tiers.erase("%s:brand" % str(ladder["id"]))

func _recipe_tip(tree, tech_id: String) -> String:
    var items := _recipe_items(tree, tech_id)
    return str(items[0]["tip"]) if not items.is_empty() else ""

# The first ladder whose rung of the brand rewards a recipe the data attributes to a technology.
func _brand_ladder() -> Dictionary:
    for pid in _gdata.products:
        var product: Dictionary = _gdata.products[pid]
        var block = product.get("brand", null)
        if not (block is Dictionary):
            continue
        for reward in _mgr.rewards_of(block):
            if not (reward is Dictionary) or str(reward.get("type", "")) != "brand_product":
                continue
            var brand_id := str(reward.get("product", ""))
            var recipe := _recipe_of(brand_id)
            if str(recipe.get("unlock_tech", "")) == "":
                continue
            return {"id": _mgr.challenge_id(product, block), "brand": brand_id, "recipe": recipe}
    return {}

func _recipe_of(pid: String) -> Dictionary:
    for craft in _gdata.crafts:
        if craft.get("result", {}).has(pid):
            return craft
    return {}

func _row_of(tree, tech_id: String) -> HBoxContainer:
    var btn: Button = tree._tech_nodes[tech_id]["button"]
    return btn.get_node_or_null("UnlockIconsScroll/UnlockIconsRow")

func _check_button(tree, state: Dictionary) -> void:
    var row := _row_of(tree, "dyeing")
    check(row != null, "the button of the technology has the row of unlocked icons", state)
    if row == null:
        return
    var badges := 0
    for child in row.get_children():
        if child is TextureRect and child.texture == _icons.get_texture(_const["ICON_NEW_RECIPES"]):
            badges += 1
    check(badges == 1, "the recipe badge is drawn once on the button (%d)" % badges, state)

    var btn: Button = tree._tech_nodes["dyeing"]["button"]
    check(not btn.get_node("UnlockIconsScroll").get_h_scroll_bar().visible,
        "the row of a technology that fits shows no scroll bar", state)
    check(not _arrow_of(btn, 1).visible and not _arrow_of(btn, -1).visible,
        "the row of a technology that fits shows no arrows", state)
    # The arrow takes its own click, the row itself leaves the click to the button.
    check(_arrow_of(btn, 1).mouse_filter == Control.MOUSE_FILTER_STOP,
        "an arrow consumes its click instead of starting the research", state)
    var strip: ScrollContainer = btn.get_node("UnlockIconsScroll")
    check(strip.mouse_filter == Control.MOUSE_FILTER_PASS,
        "the row passes the click to the button", state)

func _arrow_of(btn: Button, direction: int) -> Button:
    return btn.get_node_or_null("UnlockArrowLeft" if direction < 0 else "UnlockArrowRight")

# --- The row that does not fit -----------------------------------------------------------

func _check_scrolling(tree, state: Dictionary) -> void:
    var btn: Button = tree._tech_nodes["dyeing"]["button"]
    var strip: ScrollContainer = btn.get_node("UnlockIconsScroll")
    var row: HBoxContainer = strip.get_node("UnlockIconsRow")

    # The real data never overflows the widened button, so the overflow is made by hand:
    # more icons of the same size in the same row.
    var needed: int = int(_const["UNLOCK_ICONS_VISIBLE"]) + 2 - row.get_child_count()
    for _i in range(maxi(0, needed)):
        var filler := TextureRect.new()
        filler.custom_minimum_size = Vector2(_const["UNLOCK_ICON_SIZE"], _const["UNLOCK_ICON_SIZE"])
        filler.mouse_filter = Control.MOUSE_FILTER_PASS
        row.add_child(filler)
    for _i in range(SETTLE_FRAMES):
        await process_frame

    check(tree._unlock_row_overflows(row),
        "the row of %d icons overflows its %d px" % [row.get_child_count(), _const["UNLOCK_ROW_PLAIN_WIDTH"]], state)
    check(_arrow_of(btn, 1).visible, "the right arrow appears when there is more to the right", state)
    check(not _arrow_of(btn, -1).visible, "the left arrow stays hidden at the beginning of the row", state)
    # An arrow stands in a slot of the row instead of covering an icon: the strip gives that
    # slot up, so the icons and the arrows never share the same pixels.
    check(is_equal_approx(strip.size.x, float(_const["UNLOCK_ROW_PLAIN_WIDTH"]) - float(_const["UNLOCK_ROW_SLOT"])),
        "the row shows three icons while the right arrow takes the fourth slot (%.0f)" % strip.size.x, state)
    check(not strip.get_global_rect().intersects(_arrow_of(btn, 1).get_global_rect()),
        "the right arrow is drawn outside the icons of the row", state)

    _arrow_of(btn, 1).pressed.emit()
    for _i in range(SETTLE_FRAMES):
        await process_frame
    var scrolled := strip.get_h_scroll_bar().value
    check(scrolled > 0.0, "the right arrow scrolls the row (%.0f)" % scrolled, state)
    check(row.position.x < 0.0, "the row moves with the scroll (%.0f)" % row.position.x, state)
    check(_arrow_of(btn, -1).visible, "the left arrow appears once the row is not at its edge", state)
    check(not strip.get_global_rect().intersects(_arrow_of(btn, -1).get_global_rect()),
        "the left arrow is drawn outside the icons of the row", state)
    # The left arrow takes a slot too, so one slot of the bar would leave the icons unchanged;
    # the step goes on until a new icon really comes in.
    var content: float = tree._unlock_row_content_width(row)
    check(scrolled + tree._unlock_row_window(content, scrolled)
            > tree._unlock_row_window(content, 0.0) + 0.5,
        "one press of the right arrow brings a new icon (%.0f of %.0f)" % [scrolled, content], state)

    # Back to the beginning: a position that hides a single icon behind the left arrow is not
    # worth the slot that arrow takes, so the step lands on the first icon instead.
    _arrow_of(btn, -1).pressed.emit()
    for _i in range(SETTLE_FRAMES):
        await process_frame
    check(is_equal_approx(strip.get_h_scroll_bar().value, 0.0),
        "the left arrow steps over the position of one hidden icon (%.0f)"
            % strip.get_h_scroll_bar().value, state)
    check(not _arrow_of(btn, -1).visible, "the left arrow is gone back at the beginning", state)
    check(is_equal_approx(strip.size.x, float(_const["UNLOCK_ROW_PLAIN_WIDTH"]) - float(_const["UNLOCK_ROW_SLOT"])),
        "the row shows three icons again at the beginning (%.0f)" % strip.size.x, state)

    # The wheel is checked on a button of its own, laid at the origin: the buttons of the live
    # tree sit inside a scrolled panel, and an event pushed at such a position is picked by
    # nothing at all.
    await _check_wheel(tree, state)

func _check_wheel(tree, state: Dictionary) -> void:
    var btn := Button.new()
    btn.size = Vector2(int(_const["BUTTON_WIDTH"]), int(_const["BUTTON_HEIGHT"]))
    root.add_child(btn)
    tree._add_unlock_icons(btn, "dyeing")
    var strip: ScrollContainer = btn.get_node("UnlockIconsScroll")
    var row: HBoxContainer = strip.get_node("UnlockIconsRow")
    var needed: int = int(_const["UNLOCK_ICONS_VISIBLE"]) + 2 - row.get_child_count()
    for _i in range(maxi(0, needed)):
        var filler := TextureRect.new()
        filler.custom_minimum_size = Vector2(int(_const["UNLOCK_ICON_SIZE"]), int(_const["UNLOCK_ICON_SIZE"]))
        filler.mouse_filter = Control.MOUSE_FILTER_PASS
        row.add_child(filler)
    for _i in range(SETTLE_FRAMES):
        await process_frame

    var tree_scroll: ScrollContainer = tree._scroll
    var tree_offset_before := tree_scroll.scroll_vertical
    var before := strip.get_h_scroll_bar().value
    var at: Vector2 = strip.global_position + strip.size * 0.5
    for _i in range(2):
        var event := InputEventMouseButton.new()
        event.button_index = MOUSE_BUTTON_WHEEL_DOWN
        event.pressed = true
        event.position = at
        event.global_position = at
        event.device = 0
        root.push_input(event, true)
    for _i in range(SETTLE_FRAMES):
        await process_frame
    check(strip.get_h_scroll_bar().value > before,
        "the wheel over the row scrolls it (%.0f of %.0f)"
            % [strip.get_h_scroll_bar().value, before], state)
    check(is_equal_approx(tree_scroll.scroll_vertical, tree_offset_before),
        "the wheel taken by a scrolling row does not move the tree", state)
    btn.queue_free()

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TECH UNLOCK RECIPES TEST FAILED")
        quit(1)
    else:
        print("TECH UNLOCK RECIPES TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("OK: ", message)
    else:
        state["failed"] = true
        push_error("ASSERT FAILED: " + message)
