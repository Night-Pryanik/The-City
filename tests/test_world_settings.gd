# Headless test of the new game window:
#   godot --headless --path . --script res://tests/test_world_settings.gd
#
# Covers:
#   1. The window is one dialog with three tabs (the city, the world, the mods), and it
#      keeps ONE size: switching tabs must not resize it.
#   2. The City tab holds the name field, the World tab the settings, the Mods tab the list.
#   3. The map size is a preset list with "Custom size" at the end; the custom field takes
#      only digits and is clamped to the allowed range.
#   4. The number of towns is a plain number field: digits only, clamped to the allowed
#      range, zero allowed. The buttons beside it step the number and stop at the bounds.
#   5. The proportional checkbox computes the count from the map size and takes the input
#      away from the field and the buttons while it is on.
#   6. The map preview of both tabs follows the settings.
#   7. Neither the map size nor the number of towns is part of data/map_config.json: the
#      world reads them from the player's choice (CityData.world_map_size / world_town_count).
#
# The generation of the world is not started here: the size is read through the dialog,
# and test_new_game_loading covers the path from a new game to a generated map.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

const MENU_SCENE := "res://scenes/main_menu.tscn"
const SCREEN := Vector2i(1152, 768)

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state := {"failed": false}

    # The headless window is 64x64 by default; the dialog is sized from the screen, so the
    # test asks for the size of the real game window.
    get_root().size = SCREEN
    await process_frame
    var screen: Vector2 = get_root().get_visible_rect().size
    check(screen.y > 200.0, "the test window is big enough (got %s)" % str(screen), state)

    var menu = load(MENU_SCENE).instantiate()
    get_root().add_child(menu)
    await process_frame

    menu._on_new_game()
    await process_frame
    await process_frame

    var dialog = menu.new_game_dialog
    check(dialog != null and dialog.visible, "the new game dialog is open", state)
    if dialog == null:
        _finish(state)
        return

    # --- 1. One window, three tabs, one size ---
    var tabs: TabContainer = menu.tab_container
    check(tabs != null, "the dialog owns a tab container", state)
    check(tabs.get_tab_count() == 3,
            "the window has three tabs (got %d)" % tabs.get_tab_count(), state)
    check(tabs.get_tab_title(menu.TAB_CITY) == tr("City")
            and tabs.get_tab_title(menu.TAB_WORLD) == tr("World")
            and tabs.get_tab_title(menu.TAB_MODS).begins_with(tr("Mods")),
            "the tabs are named after their question (got %s / %s / %s)" % [
                    tabs.get_tab_title(menu.TAB_CITY), tabs.get_tab_title(menu.TAB_WORLD),
                    tabs.get_tab_title(menu.TAB_MODS)], state)
    check(tabs.current_tab == menu.TAB_CITY, "the city tab opens first", state)

    var deco_size: Vector2i = dialog.get_size_with_decorations()
    var deco_pos: Vector2i = dialog.get_position_with_decorations()
    check(deco_size.y < int(screen.y),
            "the window does not take the whole screen height (got %d of %d)"
                    % [deco_size.y, int(screen.y)], state)
    check(deco_size.x >= menu.DIALOG_CONTENT_WIDTH,
            "the window is as wide as its widest tab (got %d)" % deco_size.x, state)
    var centre := Vector2(deco_pos) + Vector2(deco_size) / 2.0
    check(absf(centre.y - screen.y / 2.0) <= 1.0,
            "the dialog is centred vertically (centre %s)" % str(centre), state)
    check(absf(centre.x - screen.x / 2.0) <= 1.0,
            "the dialog is centred horizontally (centre %s)" % str(centre), state)

    var size_before: Vector2i = dialog.size
    for tab in [menu.TAB_WORLD, menu.TAB_MODS, menu.TAB_CITY]:
        tabs.current_tab = tab
        await process_frame
        await process_frame
        check(dialog.size == size_before,
                "the window keeps its size on tab %d (got %s, was %s)"
                        % [tab, str(dialog.size), str(size_before)], state)

    # --- 2. Every tab holds what it is named after ---
    check(tabs.get_tab_control(menu.TAB_CITY).is_ancestor_of(menu.city_name_edit),
            "the name field lives on the city tab", state)
    check(tabs.get_tab_control(menu.TAB_WORLD).is_ancestor_of(menu.map_size_option),
            "the map size lives on the world tab", state)
    check(tabs.get_tab_control(menu.TAB_WORLD).is_ancestor_of(menu.town_count_edit),
            "the town count lives on the world tab", state)
    check(tabs.get_tab_control(menu.TAB_MODS) == menu.mod_list,
            "the mod list IS the mods tab", state)
    check(menu.world_previews.size() == 2,
            "the city and the world tabs each have a preview (got %d)"
                    % menu.world_previews.size(), state)
    check(menu._selected_town_count() == 16,
            "the default town count is 16 (got %d)" % menu._selected_town_count(), state)

    # --- 3. The map size: presets and the custom side ---
    check(menu.map_size_option.item_count == menu.MAP_SIZE_PRESETS.size() + 1,
            "the list is the presets plus the custom item (%d items)"
                    % menu.map_size_option.item_count, state)
    check(menu.map_size_option.get_item_text(menu.MAP_SIZE_PRESETS.size()) == "Custom size",
            "the last item is the custom size (got %s)"
                    % menu.map_size_option.get_item_text(menu.MAP_SIZE_PRESETS.size()), state)
    check(menu._selected_map_size() == 60, "the medium map is the default (got %d)"
            % menu._selected_map_size(), state)
    check(not menu.custom_size_row.visible, "the custom field is hidden for a preset", state)

    menu.map_size_option.select(2)
    menu._on_map_size_selected(2)
    check(menu._selected_map_size() == 100,
            "a preset gives its own side (got %d)" % menu._selected_map_size(), state)

    menu.map_size_option.select(menu.MAP_SIZE_PRESETS.size())
    menu._on_map_size_selected(menu.MAP_SIZE_PRESETS.size())
    check(menu.custom_size_row.visible, "the custom field appears", state)
    check(menu._selected_map_size() == 60,
            "the custom field starts from the default (got %d)" % menu._selected_map_size(), state)

    menu.custom_size_edit.text = "250"
    menu._normalize_custom_size()
    check(menu.custom_size_edit.text == "200" and menu._selected_map_size() == 200,
            "a side above the maximum is pulled to it (got %s)" % menu.custom_size_edit.text, state)

    menu.custom_size_edit.text = "5"
    menu._normalize_custom_size()
    check(menu.custom_size_edit.text == "10" and menu._selected_map_size() == 10,
            "a side below the minimum is pulled to it (got %s)" % menu.custom_size_edit.text, state)

    menu.custom_size_edit.text = ""
    menu._on_custom_size_text_changed("4a2")
    check(menu.custom_size_edit.text == "42",
            "the field keeps the digits only (got %s)" % menu.custom_size_edit.text, state)
    check(menu._selected_map_size() == 42,
            "the filtered number is the chosen side (got %d)" % menu._selected_map_size(), state)

    # --- 4. The number of towns and its ceiling ---
    # The ceiling is a density, not a number: it follows the map, so one field serves a 30×30
    # village map and a 200×200 world.
    check(menu._max_town_count(30) == 10,
            "a 30×30 map holds 10 towns (got %d)" % menu._max_town_count(30), state)
    check(menu._max_town_count(60) == 40,
            "a 60×60 map holds 40 towns (got %d)" % menu._max_town_count(60), state)
    check(menu._max_town_count(100) == 111,
            "a 100×100 map holds 111 towns (got %d)" % menu._max_town_count(100), state)

    menu.map_size_option.select(1)
    menu._on_map_size_selected(1)
    menu.town_count_edit.text = "16"
    menu._normalize_town_count()

    menu.town_count_edit.text = "999"
    menu._normalize_town_count()
    check(menu.town_count_edit.text == "40" and menu._selected_town_count() == 40,
            "a count above the ceiling is pulled to it (got %s)" % menu.town_count_edit.text, state)

    menu.town_count_edit.text = "0"
    menu._normalize_town_count()
    check(menu._selected_town_count() == 0,
            "zero towns is a valid choice (got %d)" % menu._selected_town_count(), state)

    menu.town_count_edit.text = ""
    menu._on_town_count_text_changed("1x2")
    check(menu.town_count_edit.text == "12",
            "the field keeps the digits only (got %s)" % menu.town_count_edit.text, state)
    check(menu._selected_town_count() == 12,
            "the filtered number is the chosen count (got %d)" % menu._selected_town_count(), state)

    # A count that does not fit the smaller map comes down with it.
    menu.map_size_option.select(0)
    menu._on_map_size_selected(0)
    check(menu.town_count_edit.text == "10" and menu._selected_town_count() == 10,
            "the count is pulled down to the ceiling of the smaller map (got %s)"
                    % menu.town_count_edit.text, state)
    menu.map_size_option.select(1)
    menu._on_map_size_selected(1)

    # --- 5. The step buttons and the proportional count ---
    check(menu.proportional_check != null, "the row owns a proportional checkbox", state)
    check(not menu.proportional_check.button_pressed, "the count is manual by default", state)
    check(menu.town_count_edit.editable, "the field takes input by default", state)
    check(not menu.town_count_minus.disabled and not menu.town_count_plus.disabled,
            "the step buttons are enabled by default", state)

    menu._on_town_count_step(1)
    check(menu._selected_town_count() == 11,
            "the plus button steps the count up (got %d)" % menu._selected_town_count(), state)
    menu._on_town_count_step(-1)
    menu._on_town_count_step(-1)
    check(menu._selected_town_count() == 9,
            "the minus button steps the count down (got %d)" % menu._selected_town_count(), state)

    menu.town_count_edit.text = "40"
    menu._on_town_count_step(1)
    check(menu._selected_town_count() == 40, "the step stops at the ceiling of the map", state)
    menu.town_count_edit.text = "0"
    menu._on_town_count_step(-1)
    check(menu._selected_town_count() == 0, "the step stops at zero", state)

    # The computed count keeps the default on the medium map and follows the map size. The
    # property is what a click on the checkbox changes; the handler is called after it in
    # case the assignment does not report itself as a toggle.
    menu.map_size_option.select(1)
    menu._on_map_size_selected(1)
    menu.proportional_check.button_pressed = true
    menu._refresh_town_row()
    check(not menu.town_count_edit.editable,
            "the field is read only while the count is computed", state)
    check(menu.town_count_minus.disabled and menu.town_count_plus.disabled,
            "the step buttons are off while the count is computed", state)
    check(menu._selected_town_count() == 16 and menu.town_count_edit.text == "16",
            "the medium map keeps the default 16 towns (got %s)" % menu.town_count_edit.text, state)

    menu.map_size_option.select(0)
    menu._on_map_size_selected(0)
    check(menu._selected_town_count() == 8,
            "a small map gets 8 towns (got %d)" % menu._selected_town_count(), state)
    check(menu.town_count_edit.text == "8",
            "the field shows the computed count (got %s)" % menu.town_count_edit.text, state)

    menu.map_size_option.select(4)
    menu._on_map_size_selected(4)
    check(menu._selected_town_count() == 53,
            "the giant map gets 53 towns (got %d)" % menu._selected_town_count(), state)

    menu.proportional_check.button_pressed = false
    menu._refresh_town_row()
    check(menu.town_count_edit.editable, "the field takes input again", state)
    check(not menu.town_count_minus.disabled, "the buttons are enabled again", state)

    # Back to a known state for the preview check below.
    menu.map_size_option.select(1)
    menu._on_map_size_selected(1)
    menu.town_count_edit.text = "12"
    menu._normalize_town_count()

    # --- 6. The preview follows the settings ---
    for preview in menu.world_previews:
        check(preview.map_size == 60,
                "the preview shows the chosen side (got %d)" % preview.map_size, state)
        check(preview.town_count == 12,
                "the preview shows the chosen towns (got %d)" % preview.town_count, state)
    check(menu.world_previews[0].max_map_size == menu.MAX_MAP_SIZE,
            "the preview knows the largest map of the game (got %d)"
                    % menu.world_previews[0].max_map_size, state)

    menu.map_size_option.select(0)
    menu._on_map_size_selected(0)
    check(menu.world_previews[1].map_size == 30,
            "a preset moves the preview at once (got %d)" % menu.world_previews[1].map_size, state)

    # --- 7. The size and the count are not in the data ---
    var game_data = get_root().get_node("GameData")
    check(game_data.data_loaded, "the game data is loaded by the menu", state)
    check(not game_data.map_config.has("map_rows") and not game_data.map_config.has("map_cols"),
            "the map size is not part of data/map_config.json", state)
    check(not game_data.map_config.has("num_towns"),
            "the number of towns is not part of data/map_config.json", state)
    check(game_data.map_config.has("start_ring_rows"),
            "the rest of the map configuration is still read", state)
    var city_data = get_root().get_node("CityData")
    check(city_data.world_map_size == 60,
            "a new game starts from the medium map (got %d)" % city_data.world_map_size, state)
    check(city_data.world_town_count == 16,
            "a new game starts with 16 towns (got %d)" % city_data.world_town_count, state)

    get_root().remove_child(menu)
    menu.free()
    _finish(state)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("WORLD SETTINGS TEST FAILED")
        quit(1)
    else:
        print("WORLD SETTINGS TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
