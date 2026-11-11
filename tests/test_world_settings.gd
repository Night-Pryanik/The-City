# Headless test of the new game window:
#   godot --headless --path . --script res://tests/test_world_settings.gd
#
# Covers:
#   1. The window is one dialog with three tabs (the city, the world, the mods), and it
#      keeps ONE size: switching tabs must not resize it.
#   2. The City tab holds the name field, the World tab the settings, the Mods tab the list.
#   3. The map size is a preset list with "Custom size" at the end; the custom field takes
#      only digits and is clamped to the allowed range, and its buttons step the side.
#   4. The number of towns is a plain number field: digits only, clamped to the allowed
#      range, zero allowed. The buttons beside it step the number and stop at the bounds.
#   5. The proportional checkbox computes the count from the map size and takes the input
#      away from the field and the buttons while it is on.
#   6. The map preview of both tabs follows the settings, and the water on it is the sea the
#      generator builds for those settings (the modes, the edges, the islands, the shallows,
#      the beaches). A town dot stands only on land the city can reach: one that would fall
#      into the sea or on an island moves to that land, so the count stays as chosen.
#   7. Neither the map size nor the number of towns is part of data/map_config.json: the
#      world reads them from the player's choice (CityData.world_map_size / world_town_count).
#   8. The "Seas" section: the mode dropdown, the rows of the chosen mode only, a tooltip on
#      every control, the numeric fields and the ranges they are clamped to. Every numeric
#      field of the tab owns step buttons with the increment of its setting.
#   9. The "Rivers" section: the four settings (also out of data/map_config.json), their
#      fields, and the schematic main rivers on the picture — the chosen count, no tributaries,
#      not a single point in the water, and no two rivers meeting each other or themselves.
#  10. The resource density scales the number of specimens a resource spawns: a density below
#      standard never reduces a lone specimen, a density above it multiplies even a lone one,
#      and a resource with spawn_count 0 stays unspawned at any density.
#  11. The climate is a dropdown of the five choices (random by default), and every choice
#      reads back the temperature belt it names.
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

    # The resource density is a dropdown of the six presets, standard by default, and it
    # lives on the world tab like the other world settings.
    check(tabs.get_tab_control(menu.TAB_WORLD).is_ancestor_of(menu.resource_density_option),
            "the resource density lives on the world tab", state)
    check(menu.resource_density_option.item_count == menu.RESOURCE_DENSITY_PRESETS.size(),
            "the density lists the six presets (got %d items)"
                    % menu.resource_density_option.item_count, state)
    check(is_equal_approx(menu._selected_resource_density(), 1.0),
            "the standard density is the default (got %s)"
                    % str(menu._selected_resource_density()), state)
    check(menu.resource_density_option.get_item_text(
            menu.RESOURCE_DENSITY_PRESETS.find(1.0)) == tr("Standard") + " (1x)",
            "the default item reads as the standard density with its multiplier", state)
    var density_names: Array[String] = [tr("Low"), tr("Standard"), tr("Above average"),
            tr("High"), tr("Very high"), tr("Extremely high")]
    var density_coefs: Array[String] = ["0.5x", "1x", "1.5x", "2x", "3x", "5x"]
    for index in range(menu.RESOURCE_DENSITY_PRESETS.size()):
        menu.resource_density_option.select(index)
        check(is_equal_approx(menu._selected_resource_density(),
                menu.RESOURCE_DENSITY_PRESETS[index]),
                "density preset %d reads back its multiplier (got %s)"
                        % [index, str(menu._selected_resource_density())], state)
        check(menu.resource_density_option.get_item_text(index)
                == "%s (%s)" % [density_names[index], density_coefs[index]],
                "density preset %d shows its name and multiplier (got %s)"
                        % [index, menu.resource_density_option.get_item_text(index)], state)
    menu.resource_density_option.select(menu.RESOURCE_DENSITY_PRESETS.find(1.0))
    check(WRAPPED_TOOLTIP.find_carrier(menu.resource_density_option) != null,
            "the density dropdown has a tooltip", state)

    # The climate is a dropdown of the five choices, random by default, and it lives on the
    # world tab like the other world settings.
    check(tabs.get_tab_control(menu.TAB_WORLD).is_ancestor_of(menu.climate_option),
            "the climate lives on the world tab", state)
    check(menu.climate_option.item_count == menu.CLIMATE_PRESETS.size(),
            "the climate lists the five choices (got %d items)"
                    % menu.climate_option.item_count, state)
    check(menu._selected_climate() == "random",
            "the random climate is the default (got %s)" % menu._selected_climate(), state)
    var climate_names: Array[String] = [tr("Random climate"), tr("Boreal"), tr("Temperate"),
            tr("Subtropics"), tr("Tropics")]
    for index in range(menu.CLIMATE_PRESETS.size()):
        menu.climate_option.select(index)
        check(menu._selected_climate() == menu.CLIMATE_PRESETS[index],
                "climate choice %d reads back its belt (got %s)"
                        % [index, menu._selected_climate()], state)
        check(menu.climate_option.get_item_text(index) == climate_names[index],
                "climate choice %d shows its name (got %s)"
                        % [index, menu.climate_option.get_item_text(index)], state)
    menu.climate_option.select(menu.CLIMATE_PRESETS.find("random"))
    check(WRAPPED_TOOLTIP.find_carrier(menu.climate_option) != null,
            "the climate dropdown has a tooltip", state)

    var regenerate_button: Button = null
    for preview in menu.world_previews:
        var preview_parent = preview.get_parent()
        var button: Button = preview_parent.get_node_or_null("RegeneratePreviewButton")
        var disclaimer: Label = preview_parent.get_node_or_null("PreviewDisclaimerLabel")
        check(button != null and button.text == tr("Regenerate"),
                "each preview has a regenerate button", state)
        check(disclaimer != null and disclaimer.text == tr(
                "The coast, the relief and the belts are the world itself. Resources are not shown; towns and rivers are a sketch."),
                "each preview names what is the world itself and what stays a sketch", state)
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

    # The side steps by tens and stops at the bounds of the custom range.
    var size_stepper: HBoxContainer = menu.custom_size_edit.get_parent()
    menu.custom_size_edit.text = "60"
    size_stepper.get_child(2).pressed.emit()
    check(menu.custom_size_edit.text == "70" and menu._selected_map_size() == 70,
            "the side plus button steps by ten (got %s)" % menu.custom_size_edit.text, state)
    size_stepper.get_child(0).pressed.emit()
    check(menu.custom_size_edit.text == "60",
            "the side minus button steps back (got %s)" % menu.custom_size_edit.text, state)
    menu.custom_size_edit.text = "200"
    size_stepper.get_child(2).pressed.emit()
    check(menu.custom_size_edit.text == "200", "the side step stops at the maximum", state)
    menu.custom_size_edit.text = "10"
    size_stepper.get_child(0).pressed.emit()
    check(menu.custom_size_edit.text == "10", "the side step stops at the minimum", state)

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

    menu.town_count_edit.text = "12"
    menu.town_count_plus.pressed.emit()
    check(menu._selected_town_count() == 13,
            "the town plus button is wired to the step (got %d)" % menu._selected_town_count(), state)
    menu.town_count_minus.pressed.emit()
    check(menu._selected_town_count() == 12,
            "the town minus button is wired to the step (got %d)" % menu._selected_town_count(), state)

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

    # A town of the world stands only where the player's city can reach it by land, and the
    # dots of the picture keep the rule: the land across a strait is land, but it takes none.
    var island_grid := 7
    var island_cells := PackedByteArray()
    island_cells.resize(island_grid * island_grid)
    island_cells.fill(WorldPreview.CELL_LAND)
    island_cells[3 * island_grid + 1] = WorldPreview.CELL_BEACH
    for y in range(island_grid):
        island_cells[y * island_grid + 3] = WorldPreview.CELL_DEEP_SEA
    var reachable: PackedByteArray = WorldPreview._reachable_cells(
            island_cells, island_grid, 3 * island_grid + 2)
    check(reachable[3 * island_grid + 2] == 1,
            "the land of the city is a town site", state)
    check(reachable[3 * island_grid + 1] == 1,
            "a beach of the city's shore is a town site", state)
    check(reachable[3 * island_grid + 5] == 0,
            "the land of an island is not a town site", state)

    # A town that would fall into the sea or on an island moves to the city's land instead of
    # vanishing: the picture keeps the count of the setting.
    var site_preview = WorldPreview.new()
    site_preview.set_world(60, 1, {
        "grid": island_grid,
        "cells": island_cells,
        "reachable": reachable,
    })
    var site_square := Rect2(0.0, 0.0, 70.0, 70.0)
    var island_point: Vector2 = site_square.position \
            + Vector2(5.5, 3.5) * (site_square.size / float(island_grid))
    var no_towns: Array[Vector2] = []
    var site: int = site_preview._nearest_free_cell(site_square, island_point, no_towns)
    check(site >= 0 and reachable[site] == 1,
            "a town that falls on an island moves to the city's land", state)
    site_preview.free()

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

    # The relief gives each family a height of its own, and the kinds that own a colour keep it
    # whatever the belt. The lake and the wetland are told apart by colour, not by the light.
    check(WorldPreview._cell_height(WorldPreview.CELL_MOUNTAIN)
            > WorldPreview._cell_height(WorldPreview.CELL_HILL),
            "a mountain stands above a hill on the relief", state)
    check(WorldPreview._cell_height(WorldPreview.CELL_HILL)
            > WorldPreview._cell_height(WorldPreview.CELL_LAND),
            "a hill stands above the plain", state)
    check(WorldPreview._cell_height(WorldPreview.CELL_DEEP_SEA)
            < WorldPreview._cell_height(WorldPreview.CELL_LAKE),
            "the deep sea lies below a lake", state)
    var no_belts := PackedByteArray()
    var flat := PackedFloat32Array()
    flat.resize(9)
    var lake_color: Color = WorldPreview._cell_color(
            WorldPreview.CELL_LAKE, no_belts, flat, 3, 4)
    var wetland_color: Color = WorldPreview._cell_color(
            WorldPreview.CELL_WETLAND, no_belts, flat, 3, 4)
    check(lake_color == WorldPreview.LAKE_COLOR, "a lake keeps its own colour", state)
    check(wetland_color != lake_color,
            "the wetland is told apart from the lake by colour", state)
    check(WorldPreview._cell_color(WorldPreview.CELL_DEEP_SEA, no_belts, flat, 3, 4)
            == WorldPreview.DEEP_SEA_COLOR, "the deep sea keeps its own colour", state)

    # The caption says what the sea took, which is the one number the picture cannot show.
    check(menu.world_previews[0]._sea_caption() == tr("No sea")
            or menu.world_previews[0]._sea_caption().contains("%"),
            "the caption names the share of the sea (got %s)"
                    % menu.world_previews[0]._sea_caption(), state)

    # The dialog rebuilds the picture on every change of a sea setting, not only on the mode:
    # a number typed into a field must move the preview as well. It moves once the typing pauses,
    # because the relief is the generator's own work on the whole map and every keystroke would
    # run it again.
    var before_cells: PackedByteArray = menu.world_previews[0]._picture["cells"]
    var depth_field: LineEdit = menu.sea_controls["max_sea_depth"]["control"]
    depth_field.text = "6"
    depth_field.text_changed.emit("6")
    check(menu._preview_timer != null and not menu._preview_timer.is_stopped(),
            "a sea setting being typed waits for the typing to pause", state)
    var deadline := Time.get_ticks_msec() + 5000
    while menu.world_previews[0]._picture["cells"] == before_cells \
            and Time.get_ticks_msec() < deadline:
        await process_frame
    check(menu.world_previews[0]._picture["cells"] != before_cells,
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

    # --- 7b. The step buttons of the numeric rows ---
    # Every numeric field owns the town-count layout: minus, field, plus. The increment is
    # the setting's own: one for whole hexes, a fraction of the range for shares.
    var depth_stepper: HBoxContainer = depth_edit.get_parent()
    depth_edit.text = "28"
    depth_stepper.get_child(2).pressed.emit()
    check(depth_edit.text == "29", "the sea depth steps by one (got %s)" % depth_edit.text, state)
    depth_stepper.get_child(0).pressed.emit()
    check(depth_edit.text == "28",
            "the sea depth steps back by one (got %s)" % depth_edit.text, state)
    depth_edit.text = "100"
    depth_stepper.get_child(2).pressed.emit()
    check(depth_edit.text == "100", "the depth step stops at the upper bound", state)
    depth_edit.text = "1"
    depth_stepper.get_child(0).pressed.emit()
    check(depth_edit.text == "1", "the depth step stops at the lower bound", state)

    var bays_edit: LineEdit = menu.sea_controls["edge_envelope_strength"]["control"]
    var bays_stepper: HBoxContainer = bays_edit.get_parent()
    bays_edit.text = "0.5"
    bays_stepper.get_child(2).pressed.emit()
    check(bays_edit.text == "0.6", "the bays step by a tenth (got %s)" % bays_edit.text, state)
    bays_edit.text = "0"
    bays_stepper.get_child(0).pressed.emit()
    check(is_zero_approx(float(bays_edit.text)),
            "the bays step stops at zero (got %s)" % bays_edit.text, state)

    var density_edit: LineEdit = menu.sea_controls["edge_island_density"]["control"]
    density_edit.text = "0.03"
    density_edit.get_parent().get_child(2).pressed.emit()
    check(density_edit.text == "0.04",
            "the island density steps by a hundredth (got %s)" % density_edit.text, state)

    var attempts_edit: LineEdit = menu.sea_controls["edge_island_max_attempts"]["control"]
    attempts_edit.text = "60"
    attempts_edit.get_parent().get_child(2).pressed.emit()
    check(attempts_edit.text == "70",
            "the search attempts step by ten (got %s)" % attempts_edit.text, state)

    var level_stepper: HBoxContainer = level_edit.get_parent()
    level_edit.text = "0"
    level_stepper.get_child(2).pressed.emit()
    check(level_edit.text == "0.05",
            "the sea level steps by a twentieth (got %s)" % level_edit.text, state)
    level_stepper.get_child(0).pressed.emit()
    level_stepper.get_child(0).pressed.emit()
    check(level_edit.text == "-0.05",
            "the sea level steps below zero (got %s)" % level_edit.text, state)

    # Each bound of a range owns its own buttons; stepping the lower one past the upper
    # carries the upper along, and the upper cannot drop below the lower.
    var sides_spec: Dictionary = menu.sea_controls["sides"]
    sides_spec["from"].text = "1"
    sides_spec["to"].text = "2"
    var from_stepper: HBoxContainer = sides_spec["from"].get_parent()
    var to_stepper: HBoxContainer = sides_spec["to"].get_parent()
    from_stepper.get_child(2).pressed.emit()
    check(sides_spec["from"].text == "2",
            "the range bound steps by one (got %s)" % sides_spec["from"].text, state)
    from_stepper.get_child(2).pressed.emit()
    check(sides_spec["from"].text == "3" and sides_spec["to"].text == "3",
            "the lower bound carries the upper one past it (got %s – %s)"
                    % [sides_spec["from"].text, sides_spec["to"].text], state)
    to_stepper.get_child(0).pressed.emit()
    check(sides_spec["to"].text == "3",
            "the upper bound cannot step below the lower one (got %s)" % sides_spec["to"].text,
            state)

    var river_edit: LineEdit = menu.river_controls["num_main_rivers"]["control"]
    var river_stepper: HBoxContainer = river_edit.get_parent()
    river_edit.text = "3"
    river_stepper.get_child(2).pressed.emit()
    check(river_edit.text == "4", "the river count steps by one (got %s)" % river_edit.text, state)
    river_edit.text = "20"
    river_stepper.get_child(2).pressed.emit()
    check(river_edit.text == "20", "the river step stops at the upper bound", state)
    river_edit.text = "0"
    river_stepper.get_child(0).pressed.emit()
    check(river_edit.text == "0", "the river step stops at zero", state)

    # Back to the defaults for the picture checks below.
    depth_edit.text = "28"
    bays_edit.text = "0.5"
    density_edit.text = "0.03"
    attempts_edit.text = "60"
    level_edit.text = "0"
    sides_spec["from"].text = "1"
    sides_spec["to"].text = "2"
    size_spec["from"].text = "1"
    size_spec["to"].text = "5"
    river_edit.text = "3"
    menu._normalize_sea_fields()
    menu._normalize_river_fields()

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

    # --- 9. The rivers ---
    for key in ["num_main_rivers", "num_tributaries", "min_river_length", "min_tributary_length"]:
        check(not game_data.map_config.has(key),
                "the river setting %s is not part of data/map_config.json" % key, state)

    check(menu.river_controls.size() == 4,
            "the world tab owns four river settings (got %d)" % menu.river_controls.size(), state)
    var river_defaults: Dictionary = menu._selected_river_config()
    check(int(river_defaults["num_main_rivers"]) == 3
            and int(river_defaults["num_tributaries"]) == 5
            and int(river_defaults["min_river_length"]) == 8
            and int(river_defaults["min_tributary_length"]) == 4,
            "the river settings start from their defaults (got %s)" % str(river_defaults), state)
    for key in menu.river_controls.keys():
        var spec: Dictionary = menu.river_controls[key]
        check(tabs.get_tab_control(menu.TAB_WORLD).is_ancestor_of(spec["control"]),
                "the river setting %s lives on the world tab" % key, state)
        var carrier = WRAPPED_TOOLTIP.find_carrier(spec["control"])
        check(carrier != null and not carrier.tooltip_text.is_empty(),
                "the river setting %s has a tooltip" % key, state)

    var main_rivers_edit: LineEdit = menu.river_controls["num_main_rivers"]["control"]
    main_rivers_edit.text = ""
    menu._keep_number(main_rivers_edit, "4a", false)
    check(main_rivers_edit.text == "4", "the river field keeps the digits only (got %s)"
            % main_rivers_edit.text, state)
    main_rivers_edit.text = "999"
    menu._normalize_river_fields()
    check(main_rivers_edit.text == "20"
            and int(menu._selected_river_config()["num_main_rivers"]) == 20,
            "a count above the maximum is pulled to it (got %s)" % main_rivers_edit.text, state)

    # The default sea of the dialog has water, so every main river the setting asks for has a
    # coast to mouth at. The tributaries are not drawn: their count must not touch the picture.
    menu.map_size_option.select(1)
    menu._on_map_size_selected(1)
    menu.sea_mode_option.select(menu.SEA_MODES.find("edge"))
    menu._on_sea_mode_selected(menu.SEA_MODES.find("edge"))
    menu.river_controls["num_main_rivers"]["control"].text = "4"
    menu.river_controls["num_tributaries"]["control"].text = "7"
    menu.river_controls["min_river_length"]["control"].text = "8"
    menu._refresh_preview()

    var river_picture: Dictionary = menu.world_previews[0]._picture
    var rivers: Array = river_picture["rivers"]
    check(rivers.size() == 4,
            "the picture draws the chosen number of main rivers (got %d)" % rivers.size(), state)
    var all_on_land := true
    var grid: int = int(river_picture["grid"])
    var cells: PackedByteArray = river_picture["cells"]
    for path in rivers:
        check(path.size() >= 2, "every river on the picture has a path", state)
        for index in range(path.size() - 1):
            var steps := maxi(1, ceili(path[index].distance_to(path[index + 1]) * 4.0))
            for step in range(steps + 1):
                var point: Vector2 = path[index].lerp(path[index + 1],
                        float(step) / float(steps))
                var cell := clampi(int(floor(point.y)), 0, grid - 1) * grid \
                        + clampi(int(floor(point.x)), 0, grid - 1)
                if _is_water(cells[cell]):
                    all_on_land = false
    check(all_on_land, "no river on the picture flows through the sea", state)

    var crossings: Array = _crossing_pairs(rivers, grid)
    check(crossings.is_empty(),
            "the rivers on the picture do not cross each other (pairs %s)"
                    % str(crossings), state)
    var self_crossed: Array = _self_crossed(rivers, grid)
    check(self_crossed.is_empty(),
            "no river on the picture crosses itself (rivers %s)" % str(self_crossed), state)

    # The courses are a roll of the preview seed, so more than one seed is checked: a crossing
    # is the kind of mistake that shows on one roll and hides on another.
    for preview_seed in [101, 202, 303]:
        var rolled: Dictionary = WorldPreview.build(60,
                menu._resolved_sea_config(preview_seed), preview_seed,
                menu._selected_river_config())
        var rolled_rivers: Array = rolled["rivers"]
        check(rolled_rivers.size() == 4,
                "seed %d draws the chosen number of rivers (got %d)"
                        % [preview_seed, rolled_rivers.size()], state)
        check(_crossing_pairs(rolled_rivers, int(rolled["grid"])).is_empty(),
                "seed %d keeps the rivers apart" % preview_seed, state)
        check(_self_crossed(rolled_rivers, int(rolled["grid"])).is_empty(),
                "seed %d keeps every river clear of itself" % preview_seed, state)

    menu.river_controls["num_tributaries"]["control"].text = "20"
    menu._refresh_preview()
    check(menu.world_previews[0]._picture["rivers"].size() == 4,
            "the tributaries are not drawn on the picture (got %d rivers)"
                    % menu.world_previews[0]._picture["rivers"].size(), state)

    menu.river_controls["num_main_rivers"]["control"].text = "0"
    menu._refresh_preview()
    check(menu.world_previews[0]._picture["rivers"].is_empty(),
            "zero main rivers leaves the picture without rivers", state)

    menu.river_controls["num_main_rivers"]["control"].text = "3"
    menu.river_controls["num_tributaries"]["control"].text = "5"
    menu._normalize_river_fields()
    menu._refresh_preview()

    # --- 10. The density scales the spawn count ---
    # The multiplier is applied where the generator resolves spawn_count, so it reaches every
    # resource (the ordinary, the one-off and the wild plants) through the one helper.
    var generator = load("res://scripts/map_generator.gd").new()
    var saved_density: float = city_data.world_resource_density
    var specimen := func(base: int) -> int:
        return generator._resolve_spawn_count({"id": "test", "spawn_count": base})

    city_data.world_resource_density = 1.0
    check(specimen.call(0) == 0 and specimen.call(1) == 1 and specimen.call(4) == 4,
            "the standard density leaves the spawn count unchanged", state)

    city_data.world_resource_density = 0.5
    check(specimen.call(1) == 1,
            "a lone specimen is not halved at a low density (got %d)" % specimen.call(1), state)
    check(specimen.call(4) == 2,
            "a low density halves a repeated spawn (got %d)" % specimen.call(4), state)
    check(specimen.call(0) == 0, "a zero spawn stays zero at a low density", state)

    city_data.world_resource_density = 2.0
    check(specimen.call(1) == 2,
            "a high density doubles even a lone specimen (got %d)" % specimen.call(1), state)
    check(specimen.call(3) == 6,
            "a high density doubles a repeated spawn (got %d)" % specimen.call(3), state)

    city_data.world_resource_density = 1.5
    check(specimen.call(2) == 3,
            "an above-average density scales by 1.5 (got %d)" % specimen.call(2), state)

    city_data.world_resource_density = 5.0
    check(specimen.call(1) == 5,
            "an extreme density multiplies a lone specimen fivefold (got %d)"
                    % specimen.call(1), state)

    city_data.world_resource_density = saved_density
    generator.free()

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

# The segments of a line grouped by the cell of their middle, so two lines are compared only
# where they can meet.
func _segment_buckets(path: PackedVector2Array, grid: int) -> Dictionary:
    var buckets := {}
    for index in range(path.size() - 1):
        var middle := (path[index] + path[index + 1]) * 0.5
        var key := clampi(int(floor(middle.y)), 0, grid - 1) * grid \
                + clampi(int(floor(middle.x)), 0, grid - 1)
        if buckets.has(key):
            buckets[key].append(index)
        else:
            buckets[key] = PackedInt32Array([index])
    return buckets

# Whether a segment of `points` meets the bucketed line. On one line the segments that follow
# the tested one meet it at a shared end rather than across, so `skip` leaves them out.
func _meets(buckets: Dictionary, line: PackedVector2Array, points: PackedVector2Array,
        grid: int, skip: int) -> bool:
    for index in range(points.size() - 1):
        var middle := (points[index] + points[index + 1]) * 0.5
        var row := clampi(int(floor(middle.y)), 0, grid - 1)
        var col := clampi(int(floor(middle.x)), 0, grid - 1)
        for offset_row in range(-1, 2):
            for offset_col in range(-1, 2):
                var r := row + offset_row
                var c := col + offset_col
                if r < 0 or r >= grid or c < 0 or c >= grid:
                    continue
                var key := r * grid + c
                if not buckets.has(key):
                    continue
                for other in buckets[key]:
                    if skip > 0 and other < index + skip:
                        continue
                    if Geometry2D.segment_intersects_segment(points[index],
                            points[index + 1], line[other], line[other + 1]) != null:
                        return true
    return false

# The pairs of rivers of the picture whose lines meet.
func _crossing_pairs(rivers: Array, grid: int) -> Array:
    var buckets: Array = []
    for path in rivers:
        buckets.append(_segment_buckets(path, grid))
    var pairs: Array = []
    for first in range(rivers.size()):
        for second in range(first + 1, rivers.size()):
            if _meets(buckets[first], rivers[first], rivers[second], grid, 0):
                pairs.append([first, second])
    return pairs

# The rivers of the picture that cross themselves.
func _self_crossed(rivers: Array, grid: int) -> Array:
    var crossed: Array = []
    for index in range(rivers.size()):
        if _meets(_segment_buckets(rivers[index], grid), rivers[index],
                rivers[index], grid, 3):
            crossed.append(index)
    return crossed

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
