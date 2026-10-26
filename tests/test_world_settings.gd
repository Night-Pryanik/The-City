# Headless test of the world settings of a new game:
#   godot --headless --path . --script res://tests/test_world_settings.gd
#
# Covers:
#   1. The name dialog is centred and takes nearly the whole height of the screen.
#   2. "World settings" unfolds a panel INSIDE the dialog, under its own button, and the
#      mods button is pushed down; a second press folds the panel back.
#   3. The map size is a preset list with "Custom size" at the end; the custom field takes
#      only digits and is clamped to the allowed range.
#   4. The map size is no longer part of data/map_config.json: the map reads it from the
#      player's choice (CityData.world_map_size).
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

    # --- 1. The size and the place of the dialog ---
    # The margins are kept for the decorated rect: the frame of the window is what the
    # player sees around the content.
    var expected_height: int = int(screen.y) - menu.DIALOG_EDGE_MARGIN * 2
    var deco_size: Vector2i = dialog.get_size_with_decorations()
    var deco_pos: Vector2i = dialog.get_position_with_decorations()
    check(deco_size.y == expected_height,
            "the dialog is as tall as the screen minus the margins (got %d, want %d)"
                    % [deco_size.y, expected_height], state)
    var centre := Vector2(deco_pos) + Vector2(deco_size) / 2.0
    check(absf(centre.y - screen.y / 2.0) <= 1.0,
            "the dialog is centred vertically (centre %s)" % str(centre), state)
    check(absf(centre.x - screen.x / 2.0) <= 1.0,
            "the dialog is centred horizontally (centre %s)" % str(centre), state)

    # --- 2. The panel unfolds inside the dialog ---
    check(menu.world_settings_panel != null, "the dialog owns a world settings panel", state)
    check(not menu.world_settings_panel.visible, "the panel starts folded", state)
    check(menu.world_settings_panel.is_ancestor_of(menu.map_size_option),
            "the map size lives inside the panel", state)

    var mods_y_folded: float = menu.mods_button.global_position.y
    var dialog_height: int = dialog.size.y
    menu.world_settings_button.button_pressed = true
    await process_frame
    await process_frame
    check(menu.world_settings_panel.visible, "the first press unfolds the panel", state)
    check(dialog.visible, "the panel does not close the dialog", state)
    var mods_y_unfolded: float = menu.mods_button.global_position.y
    check(mods_y_unfolded > mods_y_folded,
            "the mods button moves down while the panel is open (%f -> %f)"
                    % [mods_y_folded, mods_y_unfolded], state)
    check(dialog.size.y == dialog_height, "the dialog keeps its height", state)

    menu.world_settings_button.button_pressed = false
    await process_frame
    await process_frame
    check(not menu.world_settings_panel.visible, "the second press folds the panel", state)
    check(is_equal_approx(menu.mods_button.global_position.y, mods_y_folded),
            "the mods button comes back", state)

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

    # --- 4. The size is not in the data any more ---
    var game_data = get_root().get_node("GameData")
    check(game_data.data_loaded, "the game data is loaded by the menu", state)
    check(not game_data.map_config.has("map_rows") and not game_data.map_config.has("map_cols"),
            "the map size is not part of data/map_config.json", state)
    check(game_data.map_config.has("start_ring_rows"),
            "the rest of the map configuration is still read", state)
    var city_data = get_root().get_node("CityData")
    check(city_data.world_map_size == 60,
            "a new game starts from the medium map (got %d)" % city_data.world_map_size, state)

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
