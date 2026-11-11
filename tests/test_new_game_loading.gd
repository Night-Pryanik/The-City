extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# A new game started from the main menu must not freeze silently: a loading screen
# appears right after the confirmation, its bar advances with the stages of the
# world generation, and it is removed when the world is ready.
#
# The generation of the world runs in stages with a frame between them (see
# main_map._initialize_map), therefore the test watches the bar frame by frame: a
# bar that jumps from 0 to 100 (the stages merged into one frame) fails here as
# loudly as a missing screen.
#
# The world that comes out of it is the world the preview showed: the seed of the picture is
# handed over, and the generated map is compared with the picture hex for hex.

func _initialize() -> void:
    WATCHDOG.arm(self)
    call_deferred("_run")

func _run() -> void:
    var state := {"failed": false}
    await process_frame
    get_root().get_node("SaveManager").new_game()

    var menu = load("res://scenes/main_menu.tscn").instantiate()
    get_root().add_child(menu)
    await process_frame
    await process_frame

    # The same call the OK button of the name dialog makes. It suspends on the
    # first frame, so the screen is already in the tree when it returns.
    menu._on_new_game()
    await process_frame
    var preview_seed: int = menu._preview_seed
    var sea: Dictionary = menu._resolved_sea_config(preview_seed)
    var climate: String = menu._selected_climate()
    menu._start_new_game("Test City")

    var overlay = get_root().get_node_or_null("LoadingOverlay")
    check(overlay != null, "a new game must show a loading screen", state)
    if overlay == null:
        _finish(state)
        return

    var bar = overlay.get_node_or_null("VBoxContainer/ProgressBar")
    var status = overlay.get_node_or_null("VBoxContainer/StatusLabel")
    check(bar != null and status != null,
            "the loading screen must own a bar and a status line", state)

    var values := {}
    var texts := {}
    var frames := 0
    var centred := false
    while get_root().get_node_or_null("LoadingOverlay") != null and frames < 600:
        if bar != null:
            values[bar.value] = true
        if status != null:
            texts[status.text] = true
        # The box must sit in the middle of the screen: the anchors put its corner at
        # the centre, and only the grow directions make it grow around that point.
        if not centred and overlay != null:
            var vbox = overlay.get_node_or_null("VBoxContainer")
            if vbox != null and vbox.size.x > 0.0:
                var viewport: Vector2 = get_root().get_visible_rect().size
                var centre: Vector2 = vbox.position + vbox.size / 2.0
                check(absf(centre.x - viewport.x / 2.0) < 2.0
                        and absf(centre.y - viewport.y / 2.0) < 2.0,
                        "the loading box must sit in the centre of the screen "
                        + "(box centre %s, screen centre %s)" % [str(centre), str(viewport / 2.0)],
                        state)
                centred = true
        await process_frame
        frames += 1

    check(frames < 600, "the world generation must finish (it hung after 600 frames)", state)
    check(centred, "the loading box must be laid out", state)
    check(values.size() >= 3,
            "the bar must advance in stages, not jump (saw %d values)" % values.size(), state)
    check(texts.size() >= 3,
            "the status must name the stages (saw %d lines)" % texts.size(), state)
    check(get_root().get_node_or_null("LoadingOverlay") == null,
            "the loading screen must be removed when the world is ready", state)

    var map = get_root().get_node_or_null("MainMap")
    check(map != null, "the game scene must be loaded", state)
    if map != null:
        check(not map.world_generating, "the world must be ready after the generation", state)
        check(map.tile_data.size() == map.map_rows and map.tile_data[0].size() == map.map_cols,
                "the map must be generated in full (%d rows)" % map.tile_data.size(), state)
        check(map.towns.size() > 0, "the towns must be placed", state)
        _check_picture_is_the_world(state, map, preview_seed, sea, climate)

    _finish(state)

# The picture of the new game window is the world the player gets: the seed it shows is handed
# over, and the same stages run from it again. The terrain of the guaranteed food plant is repaired
# after the picture is drawn, so a hex or two of the starting ring may differ; nothing beyond it
# may.
func _check_picture_is_the_world(state: Dictionary, map, preview_seed: int, sea: Dictionary,
        climate: String) -> void:
    var city_data = get_root().get_node("CityData")
    check(city_data.world_seed == preview_seed,
            "the world is generated from the seed of the picture (got %d, the picture showed %d)"
                    % [city_data.world_seed, preview_seed], state)
    var preview = load("res://scripts/world_preview.gd")
    var pictured: Array = preview.relief_tiles(map.map_rows, sea, preview_seed, climate)
    var outside := 0
    var inside := 0
    for row in range(map.map_rows):
        for col in range(map.map_cols):
            if str(map.tile_data[row][col].get("terrain", "")) \
                    == str(pictured[row][col].get("terrain", "")):
                continue
            if row >= map.start_influence_start_row and row <= map.start_influence_end_row \
                    and col >= map.start_influence_start_col \
                    and col <= map.start_influence_end_col:
                inside += 1
            else:
                outside += 1
    check(outside == 0,
            "the map beyond the starting ring is the picture hex for hex (%d differences)"
                    % outside, state)
    var plant_hexes: int = load("res://scripts/map_generator.gd").FOOD_PLANT_TERRAIN_HEXES
    check(inside <= plant_hexes,
            "only the terrain of the guaranteed food plant differs inside the starting ring "
                    + "(%d hexes)" % inside, state)

func _finish(state: Dictionary) -> void:
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("NEW GAME LOADING TEST FAILED")
        quit(1)
    else:
        print("NEW GAME LOADING TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
