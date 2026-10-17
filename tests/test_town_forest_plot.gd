# Headless test: the forest plot of a town (the woodcutter's camp).
#   godot --headless --path . --script res://tests/test_town_forest_plot.gd
#
# Background. A town's decorative pass stands a woodcutter's camp
# (lumberjack_hut) on a forest hex of its ring. A camp on a BARE forest hex has
# no resource to extract — its output is the timber of the COVER
# (wood_yield in data/covers.json, main_map.gd) — but the sell pool was built
# from the resources of the hexes only, so such a town had a camp and nothing to
# sell from it.
#
# Now the camp's timber reaches the pool, and the production closure of
# TownEconomy.build_pools adds the goods made of it (planks, charcoal) by the
# same rule as for every other raw material.
#
# The camp keeps its TWO documented modes apart (docs.md, "Woodcutter's Camp"):
# on a wood RESOURCE hex it extracts that resource through the common flow and
# yields the resource's own products (the timber among them, since the wood
# resources list it in their produces), never the cover's wood on top of them.
#
# Checks (on synthetic maps + a live map):
#   1. A town with a forest hex in its ring gets a forest plot and sells wood;
#      the goods made of wood follow, and the timber carries a quality.
#   2. A ring with no timber cover gets no plot and no wood.
#   3. A cover that yields no timber (reeds) is not a plot.
#   4. A wood RESOURCE hex sells the resource's production, timber included, and
#      that timber carries the quality of the resource, not the ordinary level
#      the cover's timber is traded at.
#   5. A repeat pass (as on save load) keeps the pool: wood neither appears nor
#      disappears.
#   6. Live map (MainMap): a town sells wood exactly when its ring holds a
#      source of it — a forest plot or a wood resource.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const FOREST_PLOT := "lumberjack_hut"
const WOOD := "wood"
# A cover that yields timber and one that does not (data/covers.json). The
# barren one is "reeds": every forest cover yields timber, the swamp forest
# included, so a forest cover is not a fixture of "no timber".
const TIMBER_COVER := "forest"
const BARREN_COVER := "reeds"
# A resource the camp extracts (improved_by == lumberjack_hut): its own products
# are traded instead of the cover's wood.
const WOOD_RESOURCE := "oak_tree"
const WOOD_RESOURCE_PRODUCT := "galls"
# A quality level that is NOT the ordinary one the cover's timber is credited
# with (DEFAULT_QUALITY in town_economy.gd), so the source of the timber row is
# visible in the pool.
const RESOURCE_QUALITY := "fine"
# The goods the closure makes out of wood ALONE (data/crafts/crafts.json), so
# their presence is not left to an import roll.
const WOOD_CRAFTED := ["planks", "charcoal"]

var _tm = null
var _gdata = null


func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()


func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at this file's compile time.
    # new_game() also loads all the data (resources, improvements, covers).
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    if WATCHDOG.wants_case("town_with_forest_gets_wood"):
        _test_town_with_forest_gets_wood(state)
    if WATCHDOG.wants_case("ring_without_timber_has_no_wood"):
        _test_ring_without_timber_has_no_wood(state)
    if WATCHDOG.wants_case("barren_cover_is_not_a_plot"):
        _test_barren_cover_is_not_a_plot(state)
    if WATCHDOG.wants_case("wood_resource_is_not_a_plot"):
        _test_wood_resource_is_not_a_plot(state)
    if WATCHDOG.wants_case("reload_keeps_the_wood"):
        _test_reload_keeps_the_wood(state)

    # The live scene goes last and separately: MainMap creates its own
    # TownManager, there is no need to keep a second instance around.
    get_root().remove_child(_tm)
    _tm.free()
    _tm = null

    if WATCHDOG.wants_case("live_scene"):
        await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TOWN FOREST PLOT TEST FAILED")
        quit(1)
    else:
        print("TOWN FOREST PLOT TEST OK")
        quit(0)


# -------------------------------------------------------
# Synthetic maps
# -------------------------------------------------------

# Empty map: all hexes are plain without resources, rivers, improvements or towns.
func _make_map(rows: int, cols: int) -> Array:
    var tile_data := []
    for r in range(rows):
        var row := []
        for c in range(cols):
            row.append({
                "terrain": "plain",
                "cover": "none",
                "resource": null,
                "quality": "",
                "crop_bred": null,
                "improvement": null,
                "decorative": false,
                "fill_time": 0.0,
                "production_fractional_remainder": 0.0,
                "feed_fractional_remainder": 0.0,
                "has_town": false,
                "river_edges": [],
                "in_influence": false,
                "is_explored": false,
                "in_town_influence": false,
            })
        tile_data.append(row)
    return tile_data


# Places a town and immediately builds its influence ring — exactly as the
# game does: compute_all_town_influences -> _place_decorative_town_improvements.
func _add_town(tile_data: Array, rows: int, cols: int, row: int, col: int) -> Dictionary:
    var town: Dictionary = _tm._make_town_record(_tm.towns.size(), row, col, false)
    tile_data[row][col]["has_town"] = true
    _tm.towns.append(town)
    town["influence_hexes"] = _tm.compute_town_influence(tile_data, rows, cols, row, col, town)
    return town


# Each scenario runs on its own map and its own town, so the manager is empty
# before it: otherwise the rings and plots of the previous scenario would end up
# in the sample (towns in all tests are placed at the same map point).
func _reset_towns() -> void:
    _tm.towns.clear()
    _tm.town_hexes = []
    _tm.town_influence_hexes = []
    _tm.set_player_start_area(-1, -1, -1, -1)


# All hexes of the town's ring (candidates for decorative placement).
func _ring_tiles(tile_data: Array, town: Dictionary) -> Array:
    var result := []
    for h in town.get("influence_hexes", []):
        var r := int(h.get("row", -1))
        var c := int(h.get("col", -1))
        if r < 0 or r >= tile_data.size() or c < 0 or c >= tile_data[r].size():
            continue
        if bool(tile_data[r][c].get("has_town", false)):
            continue
        result.append(tile_data[r][c])
    return result


# The hexes of the ring that really are a forest plot: a woodcutter's camp on a
# hex whose cover yields timber and which has no resource to extract instead.
# This mirrors the production rule of main_map.gd, not the production code.
func _forest_plots(tile_data: Array, town: Dictionary) -> Array:
    var result := []
    for tile in _ring_tiles(tile_data, town):
        if str(tile.get("improvement", "")) != FOREST_PLOT:
            continue
        if _cover_yield(tile) <= 0.0:
            continue
        var res = tile.get("resource", null)
        if res != null and res != "":
            continue
        var bred = tile.get("crop_bred", null)
        if bred != null and bred != "":
            continue
        result.append(tile)
    return result


func _cover_yield(tile: Dictionary) -> float:
    var cover_id := str(tile.get("cover", "none"))
    if not _gdata.covers.has(cover_id):
        return 0.0
    return float(_gdata.covers[cover_id].get("wood_yield", 0.0))


# The production of a resource (oak_tree -> galls). It is this, and not the
# resource itself, that ends up in the sell pool.
func _produces(res_id) -> Array:
    var ids: Array = []
    var data: Dictionary = _gdata.raw_resources.get(str(res_id), {})
    for product_id in data.get("produces", {}):
        ids.append(str(product_id))
    return ids


# -------------------------------------------------------
# 1. A town with a forest hex gets a plot and sells wood
# -------------------------------------------------------

func _test_town_with_forest_gets_wood(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # One hex of the ring carries a timber cover. The hex stays free of any
    # resource, so the camp works in its "empty forest hex" mode.
    tile_data[10][12]["cover"] = TIMBER_COVER
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var plots := _forest_plots(tile_data, town)
    check(not plots.is_empty(),
        "a town with a forest cover in its ring must get a forest plot", state)
    for tile in plots:
        check(bool(tile.get("decorative", false)),
            "a town's forest plot stays decorative: it must not give the player production or workers", state)

    var pool: Array = town.get("sell_pool", [])
    check(pool.has(WOOD),
        "a town with a forest plot must sell wood (pool: %s)" % str(pool), state)
    check(not pool.has(FOREST_PLOT),
        "the plot itself (\"%s\") must not be in the sell pool (pool: %s)"
            % [FOREST_PLOT, str(pool)], state)

    # The production closure: the goods made out of wood alone follow it into
    # the pool, exactly as for any other raw material.
    var missing: Array = []
    for product_id in WOOD_CRAFTED:
        if not pool.has(product_id):
            missing.append(product_id)
    check(missing.is_empty(),
        "the goods made of wood must follow it into the sell pool (missing: %s, pool: %s)"
            % [str(missing), str(pool)], state)

    # The timber carries a level, so the town window shows stars and not a row
    # without a quality.
    var quality: Dictionary = town.get("quality", {})
    check(str(quality.get(WOOD, "")) != "",
        "the wood of a forest plot must carry a quality (quality: %s)" % str(quality), state)
    check(str(quality.get(WOOD, "")) == "common",
        "the timber of the cover is traded at the ordinary level (got \"%s\")"
            % str(quality.get(WOOD, "")), state)

    # The warehouse behind the new row: the pool and the storage must agree.
    var storage: Dictionary = town.get("storage", {})
    check(storage.has(WOOD),
        "a product of the sell pool must have a starting stock in the warehouse (storage: %s)"
            % str(storage.keys()), state)


# -------------------------------------------------------
# 2. A ring without timber gets no wood
# -------------------------------------------------------

func _test_ring_without_timber_has_no_wood(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # Every hex of the ring is bare plain: no cover at all.
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    check(_forest_plots(tile_data, town).is_empty(),
        "a ring without a timber cover must not get a forest plot", state)
    var pool: Array = town.get("sell_pool", [])
    check(not pool.has(WOOD),
        "a town without a forest plot must not sell wood (pool: %s)" % str(pool), state)
    check(not (town.get("quality", {}) as Dictionary).has(WOOD),
        "a town without a forest plot must not carry a wood quality", state)
    check(not (town.get("storage", {}) as Dictionary).has(WOOD),
        "a town without a forest plot must not have wood on its warehouse", state)


# -------------------------------------------------------
# 3. A cover that yields no timber is not a plot
# -------------------------------------------------------

func _test_barren_cover_is_not_a_plot(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # Reeds carry no wood_yield: there is nothing for the camp to take.
    tile_data[10][12]["cover"] = BARREN_COVER
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    check(_forest_plots(tile_data, town).is_empty(),
        "a cover without wood_yield must not carry a forest plot", state)
    check(not (town.get("sell_pool", []) as Array).has(WOOD),
        "a plot on a cover without wood_yield would be a lie: the town must not sell wood", state)


# -------------------------------------------------------
# 4. A wood RESOURCE hex sells the resource, not the cover
# -------------------------------------------------------

func _test_wood_resource_is_not_a_plot(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # A resource extracted BY the camp: the improved_by pass stands the camp on
    # it, and the camp then works in its "resource" mode.
    tile_data[10][12]["cover"] = TIMBER_COVER
    tile_data[10][12]["resource"] = WOOD_RESOURCE
    tile_data[10][12]["quality"] = RESOURCE_QUALITY
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var pool: Array = town.get("sell_pool", [])
    for product_id in _produces(WOOD_RESOURCE):
        check(pool.has(product_id),
            "the camp on a wood resource must sell the resource's own product \"%s\" (pool: %s)"
                % [product_id, str(pool)], state)
    check(pool.has(WOOD_RESOURCE_PRODUCT),
        "the wood resource \"%s\" must yield \"%s\" (pool: %s)"
            % [WOOD_RESOURCE, WOOD_RESOURCE_PRODUCT, str(pool)], state)
    # The timber of a wood resource is a product of the RESOURCE (the wood
    # resources list it in their produces), so it must be in the pool even
    # though the camp stands on a timber cover.
    check(pool.has(WOOD),
        "the timber of the wood resource \"%s\" must be on sale (pool: %s)"
            % [WOOD_RESOURCE, str(pool)], state)
    # ...and it must be accounted to the resource: the cover's timber is traded
    # at the ordinary level, while the hex's own quality is the one that was
    # rolled for the resource. A "common" row here would mean the pool took the
    # timber from the cover.
    check(str((town.get("quality", {}) as Dictionary).get(WOOD, "")) == RESOURCE_QUALITY,
        ("the timber of a wood resource must carry the quality of the resource (\"%s\"), " +
        "not the ordinary level of the cover's timber (got \"%s\")")
            % [RESOURCE_QUALITY, str((town.get("quality", {}) as Dictionary).get(WOOD, ""))],
        state)
    check(not pool.has(WOOD_RESOURCE),
        "the resource itself is not a good — only its production is (pool: %s)" % str(pool), state)


# -------------------------------------------------------
# 5. A repeat pass (save load) keeps the pool
# -------------------------------------------------------

func _test_reload_keeps_the_wood(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    tile_data[10][12]["cover"] = TIMBER_COVER
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)
    check((town.get("sell_pool", []) as Array).has(WOOD),
        "the first pass should have put wood on sale", state)
    var first_pool: Array = (town.get("sell_pool", []) as Array).duplicate()
    var first_plots := _forest_plots(tile_data, town).size()

    # This is exactly what a save load looks like: rings and improvements are
    # restored from the save, decorative placement is called once more.
    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    check((town.get("sell_pool", []) as Array) == first_pool,
        "the sell pool after a repeat pass must match the previous one (was %s, became %s)"
            % [str(first_pool), str(town.get("sell_pool", []))], state)
    check(_forest_plots(tile_data, town).size() == first_plots,
        "a repeat pass must not add a second forest plot to the ring", state)


# -------------------------------------------------------
# 6. Live MainMap scene (new game)
# -------------------------------------------------------

# The main check on a real map: a town sells wood exactly when a forest plot
# stands in its ring. The expectation is recomputed here from the map (cover
# yield + the camp), not taken from the production code.
func _test_live_scene(state: Dictionary) -> void:
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var tile_data = main_map.tile_data

    var plots_found := 0
    var wrong: Array = []
    for t in main_map.towns:
        var has_plot := false
        var has_wood_resource := false
        for h in t.get("influence_hexes", []):
            var r := int(h.get("row", -1))
            var c := int(h.get("col", -1))
            if r < 0 or r >= tile_data.size() or c < 0 or c >= tile_data[r].size():
                continue
            var tile = tile_data[r][c]
            if tile == null:
                continue
            # The second source of wood: a wood resource of the ring. The camp on
            # such a hex extracts the resource, and the resource lists the timber
            # in its produces.
            var res_id := str(tile.get("resource", ""))
            if res_id.is_empty() or res_id == "<null>":
                res_id = str(tile.get("crop_bred", ""))
            if not res_id.is_empty() and res_id != "<null>" and _produces(res_id).has(WOOD):
                has_wood_resource = true
            if str(tile.get("improvement", "")) != FOREST_PLOT:
                continue
            if _cover_yield(tile) <= 0.0:
                continue
            var res = tile.get("resource", null)
            if res != null and res != "":
                continue
            has_plot = true
        if has_plot:
            plots_found += 1
        var sells_wood: bool = (t.get("sell_pool", []) as Array).has(WOOD)
        if (has_plot or has_wood_resource) != sells_wood:
            wrong.append([int(t.row), int(t.col), has_plot, has_wood_resource, sells_wood])

    check(plots_found > 0,
        "on the live map at least one town must get a forest plot (otherwise the check proves nothing)", state)
    check(wrong.is_empty(),
        ("a town must sell wood exactly when its ring holds a source of it — a forest plot " +
        "or a wood resource ([row, col, has_plot, has_wood_resource, sells_wood]: %s)")
            % str(wrong), state)

    # Every sold wood must come with a level and a warehouse row, like any other
    # product of the pool.
    for t in main_map.towns:
        if not (t.get("sell_pool", []) as Array).has(WOOD):
            continue
        check(str((t.get("quality", {}) as Dictionary).get(WOOD, "")) != "",
            "wood on the live map must carry a quality", state)
        check((t.get("storage", {}) as Dictionary).has(WOOD),
            "wood on the live map must have a stock on the warehouse", state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: " + msg)
        state["failed"] = true
