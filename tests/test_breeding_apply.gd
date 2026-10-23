# Headless test: applying a bred improvement on a hex (MainMap._apply_improvement).
#   godot --headless --path . --script res://tests/test_breeding_apply.gd
#
# Background. Building a farm/pasture through BREEDING (on an empty hex) must
# write the id of the domesticated crop into tile.crop_bred — otherwise the
# improvement is placed but the crop is not raised: the field is mute and no
# production cycle starts. A translation pass once dropped the single line
# `tile.crop_bred = target_res_id` from _apply_improvement, and every breeding
# build silently produced a bare improvement.
#
# The town decorations are a red herring: the decorative fields of a town are
# sown separately (town_manager._seed_decorative_field) and always had their
# crop. It is the PLAYER's breeding that was broken. This test pins the two
# branches of _apply_improvement:
#   1. An empty hex + target_res_id -> tile.crop_bred is set, tile.resource stays null.
#   2. A hex with a natural resource + target_res_id -> tile.resource is kept,
#      tile.crop_bred stays null (extraction, not breeding).
#   3. A second breeding of the same crop inherits the quality of the first
#      domesticated instance (the round trip through find_domesticated_quality,
#      which only sees hexes that carry crop_bred).
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Cassava: a food plant bred by the "farm" improvement on a plain without cover.
const CROP := "cassava_field"
const IMP := "farm"


func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()


func _run() -> void:
    var state = {"failed": false}

    get_root().get_node("SaveManager").new_game()
    var city = get_root().get_node("CityData")
    var gdata = get_root().get_node("GameData")

    # The data must actually describe cassava as a farm-bred crop, or the test
    # below would prove nothing.
    var crop_data: Dictionary = gdata.raw_resources.get(CROP, {})
    check(not crop_data.is_empty(), "resource %s must exist in the data" % CROP, state)
    check(str(crop_data.get("improved_by", "")) == IMP,
        "%s must be bred by the %s improvement" % [CROP, IMP], state)

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    if WATCHDOG.wants_case("breeding_sets_crop"):
        _test_breeding_sets_crop(main_map, city, state)
    if WATCHDOG.wants_case("existing_resource_keeps_natural"):
        _test_existing_resource_keeps_natural(main_map, state)
    if WATCHDOG.wants_case("quality_inherited"):
        _test_quality_inherited(main_map, state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("BREEDING APPLY TEST FAILED")
        quit(1)
    else:
        print("BREEDING APPLY TEST OK")
        quit(0)


# An empty plain hex without an improvement, a resource, a crop, a town or a
# decoration — exactly the hex a player breeds on. The search is limited to the
# visible region: the quality inheritance (find_domesticated_quality) only looks
# inside it, so a hex outside would never be found by the round-trip test.
# A "plain" here is the relief family, not a terrain id: the map carries the
# climate variety of it (steppe_plain, prairie_plain, boreal_plain, ...).
func _find_empty_plain(main_map) -> Dictionary:
    var gdata = get_root().get_node("GameData")
    var tile_data = main_map.tile_data
    for r in range(main_map.region_start_row, main_map.region_end_row + 1):
        for c in range(main_map.region_start_col, main_map.region_end_col + 1):
            if r < 0 or r >= tile_data.size() or c < 0 or c >= tile_data[r].size():
                continue
            var tile = tile_data[r][c]
            if tile == null:
                continue
            if gdata.terrain_family(str(tile.get("terrain", ""))) != "plain":
                continue
            if str(tile.get("cover", "none")) != "none":
                continue
            if tile.get("resource", null) != null or tile.get("crop_bred", null) != null:
                continue
            if tile.get("improvement", null) != null:
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("decorative", false)):
                continue
            return {"row": r, "col": c}
    return {}


func _test_breeding_sets_crop(main_map, city, state: Dictionary) -> void:
    var hex := _find_empty_plain(main_map)
    if hex.is_empty():
        check(false, "the generated map must have an empty plain hex for breeding", state)
        return

    main_map._apply_improvement(hex.row, hex.col, IMP, CROP)
    var tile = main_map.tile_data[hex.row][hex.col]

    check(str(tile.get("improvement", "")) == IMP,
        "the improvement must be placed on the hex", state)
    # The regression: the bred crop must be recorded, or the field is mute.
    check(str(tile.get("crop_bred", "")) == CROP,
        "breeding must write the crop into crop_bred (got %s)" % str(tile.get("crop_bred", null)), state)
    check(tile.get("resource", null) == null,
        "a bred crop must not be written into tile.resource — it is not a natural deposit", state)
    check(str(tile.get("quality", "")) != "",
        "a bred crop must get a quality (inherited or rolled)", state)
    check(CROP in city.domesticated_resources,
        "breeding must register the crop as domesticated", state)


func _test_existing_resource_keeps_natural(main_map, state: Dictionary) -> void:
    var hex := _find_empty_plain(main_map)
    if hex.is_empty():
        check(false, "the generated map must have an empty plain hex for breeding", state)
        return

    # Extraction, not breeding: the hex already carries a natural resource.
    var tile = main_map.tile_data[hex.row][hex.col]
    tile["resource"] = CROP
    tile["quality"] = "exceptional"

    main_map._apply_improvement(hex.row, hex.col, IMP, CROP)

    check(tile.get("resource", null) == CROP,
        "a natural resource must stay in tile.resource after the improvement is built", state)
    check(tile.get("crop_bred", null) == null,
        "an extraction must not set crop_bred (it stays null)", state)
    check(str(tile.get("quality", "")) == "exceptional",
        "the quality of an existing natural resource must be preserved", state)


func _test_quality_inherited(main_map, state: Dictionary) -> void:
    # The first breeding rolls/inherits a quality; a second breeding of the SAME
    # crop must inherit it ("exceptional produces exceptional"). The inheritance
    # reads crop_bred, so it only works once the bug above is fixed.
    var first := _find_empty_plain(main_map)
    if first.is_empty():
        check(false, "the generated map must have an empty plain hex for breeding", state)
        return
    main_map._apply_improvement(first.row, first.col, IMP, CROP)
    var first_quality := str(main_map.tile_data[first.row][first.col].get("quality", ""))
    check(first_quality != "", "the first breeding must produce a quality", state)

    var second := _find_empty_plain(main_map)
    if second.is_empty():
        check(false, "the generated map must have a second empty plain hex for breeding", state)
        return
    main_map._apply_improvement(second.row, second.col, IMP, CROP)
    var second_quality := str(main_map.tile_data[second.row][second.col].get("quality", ""))

    check(second_quality == first_quality,
        "a second breeding of the same crop must inherit the domesticated quality (%s vs %s)"
            % [second_quality, first_quality], state)


func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        push_error("ASSERT: " + message)
        print("ASSERT FAILED: ", message)
        state["failed"] = true
