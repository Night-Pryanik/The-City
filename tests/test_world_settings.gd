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
#   6. The map preview of both tabs follows the settings, and the water on it is the sea the
#      generator builds for those settings (the modes, the edges, the islands, the shallows,
#      the beaches).
#   7. Neither the map size nor the number of towns is part of data/map_config.json: the
#      world reads them from the player's choice (CityData.world_map_size / world_town_count).
#   8. The "Seas" section: the mode dropdown, the rows of the chosen mode only, a tooltip on
#      every control, the numeric fields and the ranges they are clamped to.
#
# The generation of the world is not started here: the size is read through the dialog,
# and test_new_game_loading covers the path from a new game to a generated map.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")
const WRAPPED_TOOLTIP = preload("res://scripts/wrapped_tooltip.gd")

const MENU_SCENE := "res://scenes/main_menu.tscn"
const SCREEN := Vector2i(1152, 768)

# The script of the preview, loaded in _run(): its cell codes are what _is_water compares.
var _preview_script = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state := {"failed": false}

    # Loaded rather than preloaded: in the --script mode the autoloads are not in the global
    # cache when this file is compiled, and the preview reaches the sea manager.
    var WorldPreview = load("res://scripts/world_preview.gd")
    _preview_script = WorldPreview

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

    var regenerate_button: Button = null
    for preview in menu.world_previews:
        var preview_parent = preview.get_parent()
        var button: Button = preview_parent.get_node_or_null("RegeneratePreviewButton")
        var disclaimer: Label = preview_parent.get_node_or_null("PreviewDisclaimerLabel")
        check(button != null and button.text == tr("Regenerate"),
                "each preview has a regenerate button", state)
        check(disclaimer != null and disclaimer.text == tr(
                "This map is only an approximate preview; the actual world will be generated separately and may differ."),
                "each preview explains that the actual world may differ", state)
        if regenerate_button == null:
            regenerate_button = button
    if regenerate_button != null:
        var preview_seed_before: int = menu._preview_seed
        var map_size_before: int = menu._selected_map_size()
        var town_count_before: int = menu._selected_town_count()
        regenerate_button.pressed.emit()
        check(menu._preview_seed != preview_seed_before,
                "regenerating changes the preview seed", state)
        check(menu._selected_map_size() == map_size_before
                and menu._selected_town_count() == town_count_before,
                "regenerating leaves the selected world settings unchanged", state)

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

    # --- 6b. The water of the preview ---
    # The picture is built by the generator itself: the sea mask of the chosen settings, cut
    # down to the cells of the preview. The checks below are about the sea it draws, not about
    # the exact coastline (which is random and pinned by the seed of the preview).
    var no_sea: Dictionary = menu._selected_sea_config().duplicate(true)
    no_sea["mode"] = "none"
    var dry: Dictionary = WorldPreview.build(60, no_sea)
    check(is_zero_approx(float(dry["sea_share"])),
            "a world without a sea has no water on the picture (got %.3f)"
                    % float(dry["sea_share"]), state)

    var coast: Dictionary = menu._selected_sea_config().duplicate(true)
    coast["mode"] = "edge"
    coast["sides"] = [1, 1]
    coast["edge_islands_enabled"] = false
    var one_side: Dictionary = WorldPreview.build(60, coast)
    check(float(one_side["sea_share"]) > 0.02,
            "the coastal strips put water on the picture (got %.3f)"
                    % float(one_side["sea_share"]), state)
    check(_sea_edges(one_side) == 1,
            "one edge of the sea leaves the water on one side of the picture (got %d)"
                    % _sea_edges(one_side), state)

    var all_sides: Dictionary = coast.duplicate(true)
    all_sides["sides"] = [4, 4]
    var four_sides: Dictionary = WorldPreview.build(60, all_sides)
    check(_sea_edges(four_sides) == 4,
            "four edges of the sea put water on all four sides of the picture (got %d)"
                    % _sea_edges(four_sides), state)
    check(float(four_sides["sea_share"]) > float(one_side["sea_share"]),
            "four edges of the sea take more of the map than one (got %.3f of %.3f)"
                    % [float(four_sides["sea_share"]), float(one_side["sea_share"])], state)

    # The same settings must draw the same picture, otherwise a change of one setting could
    # not be told apart from a new roll of the coastline.
    var again: Dictionary = WorldPreview.build(60, coast)
    check(again["cells"] == one_side["cells"],
            "the same sea settings draw the same picture", state)

    # The islands are land inside the sea: the water around them turns into shallows and
    # beaches, so the picture of the same coast changes with the checkbox.
    var islands: Dictionary = coast.duplicate(true)
    islands["edge_islands_enabled"] = true
    check(WorldPreview.build(60, islands)["cells"] != one_side["cells"],
            "the islands of the sea change the picture", state)

    # The beach and the shallow band are two rims of the same coast, and both are settings of
    # their own: each must be visible without the other.
    var deep_shallows: Dictionary = coast.duplicate(true)
    deep_shallows["coast_max_depth"] = 1
    check(WorldPreview.build(60, deep_shallows)["cells"] != one_side["cells"],
            "the depth of the shallows changes the picture", state)
    var no_beach: Dictionary = coast.duplicate(true)
    no_beach["beach"] = false
    check(WorldPreview.build(60, no_beach)["cells"] != one_side["cells"],
            "the beaches change the picture", state)

    # The caption says what the sea took, which is the one number the picture cannot show.
    check(menu.world_previews[0]._sea_caption() == tr("No sea")
            or menu.world_previews[0]._sea_caption().contains("%"),
            "the caption names the share of the sea (got %s)"
                    % menu.world_previews[0]._sea_caption(), state)

    # The dialog rebuilds the picture on every change of a sea setting, not only on the mode:
    # a number typed into a field must move the preview as well.
    var before_typing: Dictionary = menu.world_previews[0]._picture
    var depth_field: LineEdit = menu.sea_controls["max_sea_depth"]["control"]
    depth_field.text = "6"
    depth_field.text_changed.emit("6")
    check(menu.world_previews[0]._picture["cells"] != before_typing["cells"],
            "a sea setting typed into the field moves the picture", state)
    depth_field.text = str(menu._sea_default("max_sea_depth"))
    menu._normalize_sea_fields()

    # --- 7. The seas ---
    tabs.current_tab = menu.TAB_WORLD
    await process_frame
    check(tabs.get_tab_control(menu.TAB_WORLD).is_ancestor_of(menu.sea_mode_option),
            "the sea mode lives on the world tab", state)
    check(menu.sea_mode_option.item_count == menu.SEA_MODES.size(),
            "the mode is a dropdown of the generation modes (got %d items)"
                    % menu.sea_mode_option.item_count, state)
    check(menu.sea_mode_option.get_item_text(0) == tr("None"),
            "the first mode is the one without a sea (got %s)"
                    % menu.sea_mode_option.get_item_text(0), state)

    var sea: Dictionary = menu._selected_sea_config()
    check(sea["mode"] == "edge", "a new game starts with the coastal strips (got %s)"
            % str(sea["mode"]), state)
    for key in get_root().get_node("CityData").DEFAULT_SEA.keys():
        check(sea.has(key), "the sea configuration keeps the field %s" % key, state)

    # The rows of the mode that is not chosen stay out of the list: the islands belong to
    # the coastal strips, the elevation field has its own settings.
    check(menu.sea_controls["edge_island_size"]["row"].visible,
            "the island settings are available for the coasts", state)
    check(not menu.sea_controls["noise_strength"]["row"].visible,
            "the elevation field settings are hidden for the coasts", state)
    check(menu.sea_controls["beach"]["row"].visible,
            "the common settings are available for the coasts", state)

    menu.sea_mode_option.select(menu.SEA_MODES.find("noise"))
    menu._on_sea_mode_selected(menu.SEA_MODES.find("noise"))
    check(menu._selected_sea_config()["mode"] == "noise",
            "the chosen mode is read back (got %s)" % str(menu._selected_sea_config()["mode"]),
            state)
    check(menu.sea_controls["noise_strength"]["row"].visible,
            "the elevation field settings appear with the noise mode", state)
    check(not menu.sea_controls["edge_island_size"]["row"].visible,
            "the island settings are hidden for the noise mode", state)
    check(menu.sea_controls["max_sea_depth"]["row"].visible,
            "the common settings stay with the noise mode", state)

    menu.sea_mode_option.select(menu.SEA_MODES.find("none"))
    menu._on_sea_mode_selected(menu.SEA_MODES.find("none"))
    check(menu._selected_sea_config()["mode"] == "none",
            "the mode without a sea is read back", state)
    for key in ["beach", "max_sea_depth", "edge_island_size", "noise_strength"]:
        check(not menu.sea_controls[key]["row"].visible,
                "%s is hidden while there is no sea" % key, state)

    menu.sea_mode_option.select(menu.SEA_MODES.find("edge"))
    menu._on_sea_mode_selected(menu.SEA_MODES.find("edge"))

    # The island settings belong to the island checkbox: while it is off the group leaves
    # the list, heading and all.
    var islands_check: CheckBox = menu.sea_controls["edge_islands_enabled"]["control"]
    check(islands_check.button_pressed, "islands are grown by default", state)
    check(menu.sea_controls["edge_island_size"]["row"].visible,
            "the island settings are shown while islands are grown", state)

    islands_check.button_pressed = false
    menu._on_sea_islands_toggled(false)
    for key in ["edge_island_size", "edge_island_density", "edge_island_min_distance",
            "edge_island_max_attempts"]:
        check(not menu.sea_controls[key]["row"].visible,
                "%s is hidden while islands are off" % key, state)
    check(not _row_of(menu.sea_rows, tr("Islands in the seas")).visible,
            "the heading of the island group goes with it", state)
    check(menu.sea_controls["edge_islands_enabled"]["row"].visible,
            "the island checkbox itself stays", state)
    check(menu.sea_controls["edge_width_min"]["row"].visible,
            "the rest of the coast settings stays", state)

    islands_check.button_pressed = true
    menu._on_sea_islands_toggled(true)
    check(menu.sea_controls["edge_island_size"]["row"].visible,
            "the island settings come back with the checkbox", state)

    # Every control explains itself with the comment the setting had in the data. The hints
    # are long, so they ride on the wrapping carrier (scripts/wrapped_tooltip.gd): the
    # engine's own tooltip never breaks a line.
    for key in menu.sea_controls.keys():
        var spec: Dictionary = menu.sea_controls[key]
        var controls: Array = [spec["from"], spec["to"]] if spec["kind"] == menu.SEA_PAIR \
                else [spec["control"]]
        controls.append(spec["row"].get_child(0))
        for control in controls:
            var carrier = WRAPPED_TOOLTIP.find_carrier(control)
            check(carrier != null and not carrier.tooltip_text.is_empty(),
                    "the sea setting %s has a tooltip" % key, state)
    check(WRAPPED_TOOLTIP.find_carrier(menu.sea_mode_option) != null,
            "the mode dropdown has a tooltip", state)

    # A whole number takes digits only and is clamped to its bounds.
    var depth_edit: LineEdit = menu.sea_controls["max_sea_depth"]["control"]
    depth_edit.text = ""
    menu._keep_number(depth_edit, "2a8", false)
    check(depth_edit.text == "28", "the sea field keeps the digits only (got %s)"
            % depth_edit.text, state)
    depth_edit.text = "999"
    menu._normalize_sea_fields()
    check(depth_edit.text == "100" and int(menu._selected_sea_config()["max_sea_depth"]) == 100,
            "a depth above the maximum is pulled to it (got %s)" % depth_edit.text, state)
    depth_edit.text = ""
    menu._normalize_sea_fields()
    check(depth_edit.text == "28",
            "an empty field falls back to the default (got %s)" % depth_edit.text, state)

    # A fraction takes a decimal point and a minus sign.
    var level_edit: LineEdit = menu.sea_controls["noise_sea_level"]["control"]
    level_edit.text = "-0.25"
    menu._normalize_sea_fields()
    check(level_edit.text == "-0.25", "the fraction keeps its sign and point (got %s)"
            % level_edit.text, state)
    check(is_equal_approx(float(menu._selected_sea_config()["noise_sea_level"]), -0.25),
            "the fraction is read back (got %s)"
                    % str(menu._selected_sea_config()["noise_sea_level"]), state)
    menu._keep_number(level_edit, "1.2.3", true)
    check(level_edit.text == "1.23", "a fraction keeps a single point (got %s)"
            % level_edit.text, state)

    # The bounds of a range stay in order: the "from" never rises above the "to".
    var size_spec: Dictionary = menu.sea_controls["edge_island_size"]
    size_spec["from"].text = "9"
    size_spec["to"].text = "2"
    menu._normalize_sea_fields()
    check(size_spec["from"].text == "9" and size_spec["to"].text == "9",
            "a range keeps its bounds in order (got %s – %s)"
                    % [size_spec["from"].text, size_spec["to"].text], state)
    check(menu._selected_sea_config()["edge_island_size"] == [9, 9],
            "the range is read back as a pair (got %s)"
                    % str(menu._selected_sea_config()["edge_island_size"]), state)

    # --- 8. The size and the count are not in the data ---
    var game_data = get_root().get_node("GameData")
    check(game_data.data_loaded, "the game data is loaded by the menu", state)
    check(not game_data.map_config.has("map_rows") and not game_data.map_config.has("map_cols"),
            "the map size is not part of data/map_config.json", state)
    check(not game_data.map_config.has("num_towns"),
            "the number of towns is not part of data/map_config.json", state)
    check(not game_data.map_config.has("sea"),
            "the sea settings are not part of data/map_config.json", state)
    check(game_data.map_config.has("start_ring_rows"),
            "the rest of the map configuration is still read", state)
    var city_data = get_root().get_node("CityData")
    check(city_data.world_map_size == 60,
            "a new game starts from the medium map (got %d)" % city_data.world_map_size, state)
    check(city_data.world_town_count == 16,
            "a new game starts with 16 towns (got %d)" % city_data.world_town_count, state)
    check(str(city_data.world_sea.get("mode", "")) == "edge",
            "a new game starts with the default sea (got %s)"
                    % str(city_data.world_sea.get("mode", "")), state)

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

# The line of the settings list that carries `text` — a row (its first child is the label) or
# a heading (the label itself).
func _row_of(rows: Array, text: String) -> Control:
    for entry in rows:
        var row: Control = entry["row"]
        if row is Label and row.text == text:
            return row
        if row.get_child_count() > 0 and row.get_child(0) is Label \
                and row.get_child(0).text == text:
            return row
    return null

# The map edges of the picture that carry water, counted in the middle of the edge. The
# corners are left out on purpose: a strip along one side runs the whole length of it and
# touches the two perpendicular edges with its ends, whatever the sea settings are.
func _sea_edges(picture: Dictionary) -> int:
    var grid: int = picture["grid"]
    var cells: PackedByteArray = picture["cells"]
    var middle := int(grid / 2.0)
    var wet := {
        "north": _is_water(cells[middle]),
        "south": _is_water(cells[(grid - 1) * grid + middle]),
        "west": _is_water(cells[middle * grid]),
        "east": _is_water(cells[middle * grid + grid - 1]),
    }
    var count := 0
    for side in wet.keys():
        if wet[side]:
            count += 1
    return count

func _is_water(code: int) -> bool:
    return code == _preview_script.CELL_DEEP_SEA or code == _preview_script.CELL_SHALLOW_SEA

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
