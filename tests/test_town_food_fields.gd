# Headless test: town food fields.
#   godot --headless --path . --script res://tests/test_town_food_fields.gd
#
# Background. A town whose ring had no food resources was getting 1-2
# decorative farms — BARE. The improvement is there, the road to it is
# connected, and there is nothing to grow: no resource on the hex, no goods in
# the sell pool. A player looking over the town's territory fairly asks "how do
# they not starve?".
#
# Now every field is sown with ITS OWN domesticated food crop (crop_bred — a
# farm on an empty hex is breeding, not fallow land), and the town's sell pool
# receives the PRODUCTION of the crops (wheat, cassava, ...), not the fields
# themselves (see TownEconomy.collect_base_resources: a town sells the harvest,
# not the "wheat field"). That is why all the checks below look at production.
#
# Checks (on synthetic maps):
#   1. A town without food resources gets farms with crops from the
#      food_plants group; each is breedable on its own hex, quality is set, and
#      the production of all crops ends up in the sell pool (a town without
#      resources is no longer empty).
#   2. Wild food (wild_food, group "wild") does NOT count as a food plant:
#      a ring with only wild food still gets real crops, and a town's crop
#      cannot be wild food. Wild food itself is a one-time find, so neither it
#      nor its foraged_food goes into the pool.
#   3. A crop is chosen for EACH field separately: two fields of a town are two
#      different goods, not a uniform wedge.
#   4. A repeat pass (as on save load) does NOT change crops: no field is
#      re-sown, the sell pool is stable.
#   5. A town whose ring ALREADY has a food plant changes nothing: it gets no
#      farms of its own, and the pool holds the harvest of its own plant.
#   6. If there are no spots for farms (a ring with no free plains) — the town
#      stays without food, but nothing breaks and no crop is invented.
#   7. The choice is random: across many towns the crops differ, and the fields
#      of one town are almost always different.
#   8. Live map (MainMap): not a single bare farm, towns have food.
#   9. Old save: bare farms get seeded, not replaced with new ones.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Food plant reference (group food_plants) and wild food (group wild).
const FOOD_PLANT := "wheat_field"
const WILD_FOOD := "wild_food"
# The product gathered from wild food. A one-time find: it does not get into
# the sell pool (see TownEconomy.collect_base_resources).
const FORAGE_FOOD := "foraged_food"

var _tm = null
var _gdata = null
var _mh = null


func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()


func _run() -> void:
    var state = {"failed": false}

    # Autoloads are taken through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at this file's compile time.
    # new_game() also loads all the data (resources, improvements, qualities).
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    # Global classes are also taken through load(): in --script mode the name
    # MapHelpers is not guaranteed at the test's compile time.
    _mh = load("res://scripts/map_helpers.gd")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    if WATCHDOG.wants_case("town_without_food_gets_field"):
        _test_town_without_food_gets_field(state)
    if WATCHDOG.wants_case("wild_food_is_not_a_field"):
        _test_wild_food_is_not_a_field(state)
    if WATCHDOG.wants_case("reload_keeps_the_same_crop"):
        _test_reload_keeps_the_same_crop(state)
    if WATCHDOG.wants_case("crop_is_picked_per_field"):
        _test_crop_is_picked_per_field(state)
    if WATCHDOG.wants_case("town_with_own_food_plant_unchanged"):
        _test_town_with_own_food_plant_unchanged(state)
    if WATCHDOG.wants_case("town_without_plain_stays_foodless"):
        _test_town_without_plain_stays_foodless(state)
    if WATCHDOG.wants_case("crops_vary_between_towns"):
        _test_crops_vary_between_towns(state)
    if WATCHDOG.wants_case("old_save_bare_farms_get_seeded"):
        _test_old_save_bare_farms_get_seeded(state)

    # The live scene goes last and separately: MainMap creates its own
    # TownManager, there is no need to keep a second instance around.
    get_root().remove_child(_tm)
    _tm.free()
    _tm = null

    if WATCHDOG.wants_case("live_scene"):
        await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TOWN FOOD FIELDS TEST FAILED")
        quit(1)
    else:
        print("TOWN FOOD FIELDS TEST OK")
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
# before it: otherwise the rings and fields of the previous scenario would end
# up in the sample (towns in all tests are placed at the same map point).
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


# Decorative farms of the ring sown with a food crop.
func _cropped_farms(tile_data: Array, town: Dictionary) -> Array:
    var result := []
    for tile in _ring_tiles(tile_data, town):
        if str(tile.get("improvement", "")) != "farm":
            continue
        var crop = tile.get("crop_bred", null)
        if crop != null and crop != "":
            result.append(tile)
    return result


func _res_group(res_id) -> String:
    var data: Dictionary = _gdata.raw_resources.get(str(res_id), {})
    return str(data.get("group", ""))

# The production of a resource (wheat_field -> wheat/feed, cows -> raw_meat/hide).
# It is this, and not the resource itself, that ends up in the sell pool (see
# TownEconomy.collect_base_resources), so the trade checks look here. An empty
# array means "nothing to sell".
func _produces(res_id) -> Array:
    var ids: Array = []
    var data: Dictionary = _gdata.raw_resources.get(str(res_id), {})
    for product_id in data.get("produces", {}):
        ids.append(str(product_id))
    return ids

# The GOODS category from data/products (food, materials, metals, ...). Products
# are not in GameData.raw_resources, so "is there food in the pool" is a question
# about the product's category, not about the field-resource's group.
func _product_category(res_id) -> String:
    var data: Dictionary = _gdata.products.get(str(res_id), {})
    return str(data.get("category", ""))


# -------------------------------------------------------
# 1. A town without food resources gets fields with a crop
# -------------------------------------------------------

func _test_town_without_food_gets_field(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var farms := _cropped_farms(tile_data, town)
    check(not farms.is_empty(),
        "a town without food resources must get sown farms, not bare buildings", state)
    if farms.is_empty():
        return
    for tile in farms:
        var crop := str(tile.get("crop_bred"))
        check(_res_group(crop) == "food_plants",
            "a town's crop must be a food plant (group food_plants), not \"%s\" (group \"%s\")"
                % [crop, _res_group(crop)], state)
        check(crop != WILD_FOOD,
            "wild food cannot be grown on a town's farm, but the field got \"%s\"" % crop, state)
        check(_mh.can_breed_resource_on_tile(crop, tile),
            "the crop \"%s\" cannot be bred on its own hex — the player's and the town's farm rules have diverged" % crop, state)
        check(str(tile.get("quality", "")) != "",
            "a sown field must have a quality (like the player's breeding), not an empty string", state)
        check(bool(tile.get("decorative", false)),
            "a town's field stays decorative: it must not give the player production or workers", state)

    # Sell pool: it must hold the PRODUCTION of the crops (wheat, feed, ...),
    # not the fields themselves. A town sells the harvest, not the "wheat
    # field": a field is a hex description, and in the sell list it only confused.
    var pool: Array = town.get("sell_pool", [])
    var missing: Array = []
    for tile in farms:
        var crop := str(tile.get("crop_bred"))
        for product_id in _produces(crop):
            if not pool.has(product_id):
                missing.append("%s->%s" % [crop, product_id])
    check(missing.is_empty(),
        "the production of a field's crop must end up in the town's sell pool (missing: %s, pool: %s)" % [str(missing), str(pool)], state)
    # Regression for "two wheats": the field itself must not be in the pool at all.
    var raw_in_pool: Array = []
    for res_id in pool:
        if _gdata.raw_resources.has(str(res_id)):
            raw_in_pool.append(str(res_id))
    check(raw_in_pool.is_empty(),
        "the sell pool must not contain the field-resources themselves, only their production (found: %s)" % str(raw_in_pool), state)


# -------------------------------------------------------
# 2. Wild food does not count as a food plant
# -------------------------------------------------------

func _test_wild_food_is_not_a_field(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # One hex of the ring is wild food. It is gathered by a special action, does
    # not require an improvement and does not become a farm: "a town on wild
    # food" is exactly what we are moving away from.
    tile_data[10][12]["resource"] = WILD_FOOD
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var farms := _cropped_farms(tile_data, town)
    check(not farms.is_empty(),
        "wild food in the ring must not cancel a food field: the town must still have something to feed on", state)
    for tile in farms:
        check(str(tile.get("crop_bred")) != WILD_FOOD,
            "wild food cannot be bred on a farm (wild_food does not pass can_breed_resource_on_tile)", state)
    # Wild food is a one-time find: it cannot be gathered endlessly, so neither
    # the wild food itself nor its foraged_food appears in trade. A field is a
    # different case: its production must be in the pool.
    var pool: Array = town.get("sell_pool", [])
    check(not pool.has(WILD_FOOD) and not pool.has(FORAGE_FOOD),
        "wild food and the food gathered from it must not get into the sell pool (pool: %s)" % str(pool), state)
    var crop_products: Array = []
    for tile in farms:
        for product_id in _produces(str(tile.get("crop_bred"))):
            if pool.has(product_id):
                crop_products.append(product_id)
    check(not crop_products.is_empty(),
        "the sell pool must contain the products of the cropped fields (pool: %s)" % str(pool), state)


# -------------------------------------------------------
# 4. A repeat pass (save load) does not change crops
# -------------------------------------------------------

func _test_reload_keeps_the_same_crop(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)
    var first := _cropped_farms(tile_data, town)
    if first.is_empty():
        check(false, "the first pass should have sown the town's fields", state)
        return
    # The ring traversal order is stable, so the sets are compared element by element.
    var before: Array = []
    for tile in first:
        before.append(str(tile.get("crop_bred")))
    var first_pool: Array = (town.get("sell_pool", []) as Array).duplicate()

    # This is exactly what a save load looks like: rings and improvements are
    # restored from the save, decorative placement is called once more.
    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var after: Array = []
    for tile in _cropped_farms(tile_data, town):
        after.append(str(tile.get("crop_bred")))
    check(after == before,
        "a repeat pass must neither re-sow the fields nor ADD new ones (was %d fields %s, became %d fields %s)"
            % [before.size(), str(before), after.size(), str(after)], state)
    check((town.get("sell_pool", []) as Array) == first_pool,
        "the sell pool after a repeat pass must match the previous one (was %s, became %s)"
            % [str(first_pool), str(town.get("sell_pool", []))], state)


# -------------------------------------------------------
# 5. A crop is chosen for EACH field separately
# -------------------------------------------------------

# Two adjacent fields with different crops read as a farmstead, not as a
# uniform wedge, and give the town two goods instead of one. We check the
# choice itself (reliably: 30 rolls into one kind out of ~20 — a probability on
# the order of 20^-30) and that both of the town's crops end up for sale.
func _test_crop_is_picked_per_field(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    # The choice itself: many rolls — many different crops.
    var picks := {}
    for i in range(30):
        picks[_tm._pick_town_field_crop(tile_data[10][11])] = true
    check(picks.size() > 1,
        "a crop must be chosen randomly for each field, not be a constant (30 rolls gave %d different: %s)"
            % [picks.size(), str(picks.keys())], state)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)
    var farms := _cropped_farms(tile_data, town)
    check(farms.size() == 2,
        "on a plains map a town must get two fields (got %d)" % farms.size(), state)
    if farms.size() != 2:
        return
    var pool: Array = town.get("sell_pool", [])
    var missing: Array = []
    for tile in farms:
        var crop := str(tile.get("crop_bred"))
        for product_id in _produces(crop):
            if not pool.has(product_id):
                missing.append("%s->%s" % [crop, product_id])
    check(missing.is_empty(),
        "the production of both crops must end up in the sell pool so the town trades two different goods (missing: %s, pool: %s)"
            % [str(missing), str(pool)], state)


# -------------------------------------------------------
# 6. A town with its own food plant is unchanged
# -------------------------------------------------------

func _test_town_with_own_food_plant_unchanged(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    tile_data[10][12]["resource"] = FOOD_PLANT
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    # It gets no farms of its own (they were not placed before either) — no
    # field is needed, the food is already there.
    check(_cropped_farms(tile_data, town).is_empty(),
        "a town with a food plant in the ring must not get sown fields", state)
    var pool: Array = town.get("sell_pool", [])
    var wheat_products: Array = []
    for product_id in _produces(FOOD_PLANT):
        if pool.has(product_id):
            wheat_products.append(product_id)
    check(not wheat_products.is_empty(),
        "a town must sell the harvest of the ring's food plant, not the plant itself (found: %s, pool: %s)"
            % [str(wheat_products), str(pool)], state)
    check(not pool.has(FOOD_PLANT),
        "the field itself \"%s\" must not be in the sell pool: a town sells wheat, not a wheat field (pool: %s)"
            % [FOOD_PLANT, str(pool)], state)
    # The neighboring free plains stay free: no crop is invented where the
    # player can build their own.
    var untouched_plains := 0
    for tile in _ring_tiles(tile_data, town):
        if tile.get("improvement", null) == null and str(tile.get("terrain", "")) == "plain":
            untouched_plains += 1
    check(untouched_plains > 0,
        "no extra farms need to be placed in a ring with a food plant", state)


# -------------------------------------------------------
# 6. No spots for a farm — the town stays foodless but does not break
# -------------------------------------------------------

func _test_town_without_plain_stays_foodless(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # A ring without free plains: everything is hills. There is nowhere to put a
    # farm, so no crop may be invented either.
    var town := _add_town(tile_data, rows, cols, 10, 10)
    for tile in _ring_tiles(tile_data, town):
        tile["terrain"] = "hill"

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    check(_cropped_farms(tile_data, town).is_empty(),
        "without spots for a farm a town must not get fields", state)
    var pool: Array = town.get("sell_pool", [])
    # The pool must not be topped up with invented food: field-resources cannot
    # be in it in principle, and products with no source (a field/deposit in the
    # ring) have nowhere to come from — so the pool stays exactly what the real
    # hexes gave it.
    var invented: Array = []
    for res_id in pool:
        if _gdata.raw_resources.has(str(res_id)):
            invented.append(str(res_id))
    check(invented.is_empty(),
        "the sell pool must not contain raw resources even if there are no fields (found: %s)" % str(invented), state)


# -------------------------------------------------------
# 7. The choice is random, fields of one town differ
# -------------------------------------------------------

func _test_crops_vary_between_towns(state: Dictionary) -> void:
    # Many towns on one map (the rings do not overlap) — we look at whether the
    # crop is really chosen randomly and not hardcoded to a constant, and
    # whether the two fields of one town get DIFFERENT crops.
    # The spacing between towns (9-10 hexes) is definitely larger than two ring
    # radii, so no field goes to two towns at once.
    _reset_towns()
    var rows := 100
    var cols := 100
    var tile_data := _make_map(rows, cols)
    var centers := []
    for i in range(40):
        var row := 5 + int(i / 8.0) * 10
        var col := 5 + (i % 8) * 9
        centers.append(_add_town(tile_data, rows, cols, row, col))

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var seen := {}
    var foodless := 0
    var two_field_towns := 0
    var differing_pairs := 0
    for town in centers:
        var farms := _cropped_farms(tile_data, town)
        if farms.is_empty():
            foodless += 1
            continue
        seen[str(farms[0].get("crop_bred"))] = true
        if farms.size() == 2:
            two_field_towns += 1
            if str(farms[0].get("crop_bred")) != str(farms[1].get("crop_bred")):
                differing_pairs += 1
    check(seen.size() > 1,
        "town crops must differ (got %d different across 40 towns: %s) — otherwise the whole map harvests one crop"
            % [seen.size(), str(seen.keys())], state)
    check(foodless == 0,
        "every town on a plains map must get a food field (without a field: %d)" % foodless, state)
    check(two_field_towns > 0,
        "the sample must contain towns with two fields (found: %d)" % two_field_towns, state)
    # Two fields matching is a rare case (1 kind out of ~20), so the requirement
    # "almost always different" is robust, unlike "always different".
    check(differing_pairs >= 20,
        "the fields of one town must carry different crops, not a uniform wedge: %d different pairs out of %d towns with two fields"
            % [differing_pairs, two_field_towns], state)


# -------------------------------------------------------
# 8. Live MainMap scene (new game)
# -------------------------------------------------------

# The main check on a real map: the generator produces mixed terrain, and towns
# without food resources are guaranteed to be there. We look at whether after
# real generation not a SINGLE bare farm is left and whether towns that had
# nothing to feed on sell something.
func _test_live_scene(state: Dictionary) -> void:
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var tile_data = main_map.tile_data

    # 1. A bare farm is a building without a resource and without a crop. It is
    #    the very display case that makes the player ask "how do they not starve?".
    var bare_farms: Array = []
    var seeded_fields: Array = []
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            var tile = tile_data[r][c]
            if tile == null or str(tile.get("improvement", "")) != "farm":
                continue
            if not bool(tile.get("decorative", false)):
                continue
            var has_resource = tile.get("resource", null) != null and tile.get("resource") != ""
            var crop = tile.get("crop_bred", null)
            if crop != null and crop != "":
                seeded_fields.append([r, c, str(crop)])
            elif not has_resource:
                bare_farms.append([r, c])
    check(bare_farms.is_empty(),
        "on the live map no decorative farms without a resource and without a crop must remain (hexes: %s)" % str(bare_farms), state)
    check(not seeded_fields.is_empty(),
        "on the live map at least some towns must get sown food fields", state)

    # 2. All sown fields are food plants, and all of them are sold by their own
    #    town (and only by it: towns do not share rings).
    var crops_ok := true
    for f in seeded_fields:
        if _res_group(str(f[2])) != "food_plants" or str(f[2]) == WILD_FOOD:
            crops_ok = false
    check(crops_ok,
        "all town fields are sown with food plants, not with wild food", state)

    # A town's food is the GOODS of the food category in data/products (wheat,
    # cassava, ...), not field-resources with the food_plants group: the pool
    # holds harvests, not the crops themselves.
    var sold_somewhere := 0
    for t in main_map.towns:
        var sells_food := false
        for res_id in t.get("sell_pool", []):
            if _product_category(res_id) == "food":
                sells_food = true
        if sells_food:
            sold_somewhere += 1
    check(sold_somewhere > 0,
        "at least one town on the live map must sell food (towns with food: %d out of %d)"
            % [sold_somewhere, main_map.towns.size()], state)

    # 3. A crop must not get into the sell pool of a town whose ring it does not
    #    touch — and must not "stick" to the player: on a hex with a field the
    #    player can neither build nor buy a chunk.
    var leaks: Array = []
    for t in main_map.towns:
        for h in t.get("influence_hexes", []):
            var r := int(h.get("row", -1))
            var c := int(h.get("col", -1))
            if r < 0 or r >= tile_data.size() or c < 0 or c >= tile_data[r].size():
                continue
            var tile = tile_data[r][c]
            if tile == null:
                continue
            if tile.get("improvement", null) == null and tile.get("resource", null) == null \
                    and tile.get("crop_bred", null) == null:
                continue
            if not bool(tile.get("in_town_influence", false)):
                leaks.append([int(t.row), int(t.col), r, c])
    check(leaks.is_empty(),
        "town improvements and fields must lie only in its own ring (offenders: %s)" % str(leaks), state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


# -------------------------------------------------------
# 9. Old save: bare farms left over from earlier versions
# -------------------------------------------------------

# A save made before food fields appeared already contains farms without a
# crop. A new pass must seed THEM, not place more farms nearby: otherwise a
# town would forever keep some of its empty "display cases".
func _test_old_save_bare_farms_get_seeded(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    # We simulate an old save: all free plains of the ring are occupied by farms
    # without a resource and without a crop (that is exactly how the previous
    # version placed them).
    var legacy_farms: Array = []
    for tile in _ring_tiles(tile_data, town):
        if tile.get("improvement", null) == null and tile.get("resource", null) == null \
                and str(tile.get("terrain", "")) == "plain" and str(tile.get("cover", "none")) == "none":
            _tm._set_decorative_improvement(tile, "farm")
            legacy_farms.append(tile)
    check(not legacy_farms.is_empty(), "the test should have prepared the old save's bare farms", state)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var unseeded: Array = []
    for tile in legacy_farms:
        var crop = tile.get("crop_bred", null)
        if crop == null or crop == "":
            unseeded.append([int(tile.get("terrain", ""))])
    check(unseeded.is_empty(),
        "the old save's bare farms must be seeded on the next pass (remaining: %d)" % unseeded.size(), state)

    var seeded := _cropped_farms(tile_data, town)
    check(not seeded.is_empty(),
        "a town from an old save must get a food field", state)
    var pool: Array = town.get("sell_pool", [])
    var missing: Array = []
    for tile in seeded:
        var crop := str(tile.get("crop_bred"))
        for product_id in _produces(crop):
            if not pool.has(product_id):
                missing.append("%s->%s" % [crop, product_id])
    check(missing.is_empty(),
        "the production of the old save's sown fields must end up in the sell pool (missing: %s, pool: %s)"
            % [str(missing), str(pool)], state)


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: " + msg)
        state["failed"] = true
