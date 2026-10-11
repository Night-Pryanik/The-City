# Headless test of the town trade economy (production closure + cascade
# import): scripts/town_economy.gd
#   godot --headless --path . --script res://tests/test_town_economy.gd
#
# Exactly what the mechanic intends is checked:
#   1. CLOSURE. A resource that is not on the hex but is produced by a recipe
#      from one that is, lands in the sell pool; then further down the chain
#      (wood -> charcoal -> iron). A recipe whose raw material is missing does
#      not land in the pool.
#   2. @-GROUP. It closes with ONE member out of many.
#   3. READINESS = the share of closed ingredients, the amount is NOT counted.
#      Synthetics at 1/2, 1/3, 2/3 give exactly 50, 33, 67.
#   4. CASCADE. Import opens up a family of goods: bought ore — metal appeared,
#      from metal — wares. The number of passes is not fixed.
#   5. ISOLATION. Imported goods are not sold — even if they are crafted.
#   6. DETERMINISM. Two consecutive calls give identical pools: the main
#      regression test, because on save load the pools are computed twice, and
#      a "jumping" buy_pool would break the batch on every save read.
#   7. BOUNDARIES. A single-ingredient recipe gives neither import nor closure
#      at zero available; a recipe with two gaps out of three is imported (1/3),
#      a recipe with more gaps is not.
#   8. GROUP REPRESENTATIVE. Random, but stable between calls and always
#      from the group's membership.
#   9. LIVE MAP. The pools are non-empty, and a recomputation changes nothing.
#  10. BASE POOL = PRODUCTS. The raw material itself (field, deposit, animal)
#      does not land in the pool — the town sells the harvest, not a "wheat
#      field". This removes two consecutive "Wheat" in the window (wheat_field
#      gives wheat — they were named the same).
#  11. ANIMALS. The animals themselves are not goods; the goods are meat,
#      hide, milk, catch.
#  12. ONE-TIME. Wild food (wild_food) gives nothing: it cannot be gathered
#      endlessly, so there is nothing to sell. Nuggets — on the contrary, give
#      ore: copper is needed by the smith and is mined without limit.
#  13. DUPLICATE NAMES. In the window there is one row per name, even if the
#      pool has two different ids with the same name (papyrus_plant and
#      papyrus both "Papyrus").
#  14. WINDOW. The lists live in a ScrollContainer: a long pool scrolls instead
#      of spilling over the window's bottom edge onto the map.
#  15. TREASURY. A new town receives town_initial_treasury from
#      game_balance.json, the window shows the treasury and updates it
#      immediately on the trade signal; the town cannot go negative.
#  16. STORAGE. Every good of the sell pool has a supply of 100..500
#      (town_storage_initial_min/max), and it survives a pool recomputation —
#      sold goods do not come back on save reload.
#  17. PRODUCTION PLAN. The production plan (production) is derived from the
#      recipes (10 silk -> 10 silk); the storage is moved by daily trade
#      (tests 23+).
#  18. STORAGE LIMIT. town_storage_limit is per good, not for the whole
#      storage: a town at the limit on one good keeps trading the others.
#  19. TRADE AFTER SCOUTING. An unscouted town does not trade, otherwise by the
#      time it meets the player its storage would have drifted from the
#      starting supply.
#  20. DEAL. A sale debits units from the storage, a purchase adds them;
#      outside the supply the deal does not go through, the storage does not go
#      negative.
#  21. WINDOW. The sell column shows the number of units in storage, and it
#      updates on the signal without rebuilding the list.
#  22. QUALITY. A storage good has exactly one level: raw material takes the
#      HIGHEST quality among the ring's hexes (not the first found), crafting —
#      the standard weighted average over the ingredients; in the window — only
#      stars in the level's color, without breakdown and percentages, with a
#      tooltip naming the level.
#  23. COMFORT. The supply level that trade gravitates to is DERIVED as the
#      middle of town_storage_initial_min/max (300), there is no separate field.
#  24. TWO-WAY. The storage moves BOTH up AND down: over 400 ticks there are
#      both purchases and sales, and the storage does not freeze at the starting
#      supply.
#  25. BOUNDARIES. The storage does not go negative and does not exceed the
#      limit: on an empty storage the direction is forcedly buying, on a full
#      one — selling.
#  26. INERTIA. The direction repeats, so rises and falls come in runs of 3+
#      deals, instead of alternating every day.
#  27. TRADE SAVE. The last deal's direction and the tick counter are world
#      state: after a round-trip the next tick goes exactly the same way.
#  28. CATEGORIES IN THE WINDOW. The goods in the buy and sell pools are split
#      by category, as on the city interface's "Resources" tab: the category
#      header is a solid line, the name centered, the line; below it — rows of
#      only that category.
extends SceneTree

# Watchdog against hangs: without it, a broken _run() coroutine looks like
# eternal silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Reference ids from data/: recipes are taken from GameData.crafts, so the
# checks compare against the REGISTRY itself, not hardcoded expectations.
const WOOD := "wood"          # raw material -> charcoal -> planks
const CHARCOAL := "charcoal"
const PLANKS := "planks"
const WHEAT := "wheat"        # member of @millable_grains
const COPPER_ORE := "copper_ore"
const IRON_ORE := "iron_ore"
const TIN := "tin"            # member of @bronze_alloys (bronze_alloys: tin/antimony/arsenic)

var _te = null
var _failed := false


func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()


func _check(cond: bool, msg: String) -> void:
    if cond:
        return
    _failed = true
    print("FAIL: ", msg)


func _run() -> void:
    # Autoloads are fetched through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at compile time of this file.
    # new_game() also loads all the data (recipes, groups, resources).
    get_root().get_node("SaveManager").new_game()
    var gd = get_root().get_node("GameData")
    _check(not gd.crafts.is_empty(), "recipe registry did not load")
    _check(gd.product_groups.has("bronze_alloys"),
        "group bronze_alloys did not load")
    # The module is also loaded via load(): class_name may not be in the cache
    # yet in --script mode (the same argument as MapHelpers in other tests).
    _te = load("res://scripts/town_economy.gd")

    # Cases can be selected by name: -- --case=readiness. See watchdog.gd.
    if WATCHDOG.wants_case("closure"):
        _test_closure()
    if WATCHDOG.wants_case("group_closes_with_one_member"):
        _test_group_closes_with_one_member()
    if WATCHDOG.wants_case("readiness"):
        _test_readiness()
    if WATCHDOG.wants_case("cascade"):
        _test_cascade()
    if WATCHDOG.wants_case("import_isolated_from_sell"):
        _test_import_isolated_from_sell()
    if WATCHDOG.wants_case("determinism"):
        _test_determinism()
    if WATCHDOG.wants_case("group_member"):
        _test_group_member()
    if WATCHDOG.wants_case("base_pool_is_products_only"):
        _test_base_pool_is_products_only()
    if WATCHDOG.wants_case("animals_excluded"):
        _test_animals_excluded()
    if WATCHDOG.wants_case("one_time_resources"):
        _test_one_time_resources()
    if WATCHDOG.wants_case("duplicate_names_hidden"):
        await _test_duplicate_names_hidden()
    if WATCHDOG.wants_case("live_map"):
        await _test_live_map()
    if WATCHDOG.wants_case("town_ui_window"):
        await _test_town_ui_window()
    if WATCHDOG.wants_case("town_quality"):
        await _test_town_quality()
    if WATCHDOG.wants_case("town_treasury"):
        await _test_town_treasury()
    if WATCHDOG.wants_case("storage_seeded"):
        _test_storage_seeded()
    if WATCHDOG.wants_case("production_plan"):
        _test_production_plan()
    if WATCHDOG.wants_case("storage_limit"):
        _test_storage_limit()
    if WATCHDOG.wants_case("production_after_scouting"):
        _test_production_after_scouting()
    if WATCHDOG.wants_case("trade_comfort_from_data"):
        _test_trade_comfort_from_data()
    if WATCHDOG.wants_case("trade_moves_both_ways"):
        _test_trade_moves_both_ways()
    if WATCHDOG.wants_case("trade_bounds_and_no_negative"):
        _test_trade_bounds_and_no_negative()
    if WATCHDOG.wants_case("trade_inertia_and_runs"):
        _test_trade_inertia_and_runs()
    if WATCHDOG.wants_case("trade_moves_goods"):
        _test_trade_moves_goods()
    if WATCHDOG.wants_case("window_shows_stock"):
        await _test_window_shows_stock()
    if WATCHDOG.wants_case("town_ui_categories"):
        await _test_town_ui_categories()

    WATCHDOG.report_skipped()
    if _failed:
        print("TOWN ECONOMY TEST FAILED")
    else:
        print("TOWN ECONOMY TEST OK")
    quit(2 if _failed else 0)


# --- Pool for an arbitrary set of ids: base -> closure without import ---
# The closure is computed directly through _close_pool, bypassing the import cascade.
func _pool_only(base_ids: Array) -> Dictionary:
    var pool: Dictionary = {}
    for pid in base_ids:
        pool[str(pid)] = true
    var made: Dictionary = {}
    _te._close_pool(pool, made, {})
    return pool


# 1. Closure: wood -> charcoal -> planks. The closure is recursive, not one
# step: charcoal appears only after wood, planks — only after charcoal.
func _test_closure() -> void:
    var pool := _pool_only([WOOD])
    _check(pool.has(CHARCOAL),
        "charcoal must come from wood — the closure did not fire")
    _check(pool.has(PLANKS),
        "planks must come from charcoal — the closure chain is not recursive")
    # Wood gives charcoal, so with copper ore copper will be smelted: the
    # closure must link the WHOLE chain, not just the first step.
    var with_ore := _pool_only([WOOD, COPPER_ORE])
    _check(with_ore.has(CHARCOAL), "charcoal must come from wood even with ore present")
    _check(with_ore.has("copper"),
        "wood + copper_ore must give copper via charcoal — the chain did not close")
    # But without wood (no charcoal) copper is not smelted even with ore present.
    _check(not _pool_only([COPPER_ORE]).has("copper"),
        "without charcoal the town will not smelt copper ore")
    _check(_pool_only([WOOD, IRON_ORE]).has("iron"),
        "wood + iron_ore must give iron via charcoal")


# 2. An @-group closes with ONE member: wheat is in @millable_grains, so the
# flour recipe is closed, even though the group has nine grains.
func _test_group_closes_with_one_member() -> void:
    var gd = get_root().get_node("GameData")
    var millable: Array = gd.product_groups.get("millable_grains", [])
    _check(millable.has(WHEAT), "wheat must belong to @millable_grains")
    var pool := _pool_only([WHEAT])
    _check(pool.has("flour"), "a single wheat from the group must give flour")
    _check(pool.has("bread"), "bread must come from flour")


# 3. Readiness = the share of closed ingredients, the amount is not read.
func _test_readiness() -> void:
    var pool := _pool_only([WOOD, COPPER_ORE])
    # bronze: copper + @bronze_alloys + charcoal. copper and charcoal are
    # closed (charcoal from wood), the alloy is missing => 2 of 3.
    _check(_te.readiness_percent("bronze", pool) == 67,
        "bronze readiness (2 of 3) must be 67, got %d"
            % _te.readiness_percent("bronze", pool))
    # bronze_tools: bronze + charcoal. Only charcoal is closed => 1 of 2.
    _check(_te.readiness_percent("bronze_tools", pool) == 50,
        "bronze_tools readiness (1 of 2) must be 50, got %d"
            % _te.readiness_percent("bronze_tools", pool))
    # A recipe with no closed ingredient: 0.
    var empty := _pool_only([PLANKS])
    _check(_te.readiness_percent("gold", empty) == 0,
        "a recipe with no available ingredient has readiness 0")
    # The amount does NOT matter: a recipe with two ingredients gives 50
    # regardless of whether it asks for 10 or 100 units. We compare against the
    # recipe's OWN data so the test does not drift from it when the balance is
    # tweaked.
    var gd = get_root().get_node("GameData")
    for craft in gd.crafts:
        if str(craft.get("id", "")) != "iron":
            continue
        var ingredients: Dictionary = craft.get("resources", {})
        _check(ingredients.size() == 2,
            "iron must remain a two-ingredient recipe")
        var only_ore := _pool_only([IRON_ORE])
        _check(_te.readiness_percent("iron", only_ore) == 50,
            "readiness must not depend on the amount (iron_ore -> 50)")

# 4. CASCADE. Import must open whole families, not a single good. On the hex
# ONLY wood: charcoal (from wood) is there, but iron ore is not — so the "iron"
# recipe is closed exactly halfway and can win a roll. Having bought the ore,
# the town gets metal, and from metal — wares. The number of passes is not
# fixed, so we check the result, not the iteration count. Different town ids
# give different rolls, so we iterate over them: this way the cascade is
# guaranteed to be met.
func _test_cascade() -> void:
    var found_family := false
    var details := ""
    for i in range(60):
        var pools: Dictionary = _te.build_pools("town_%d" % i, [WOOD])
        var sell: Array = pools["sell_pool"]
        var buy: Array = pools["buy_pool"]
        if buy.has(IRON_ORE) and sell.has("iron") and sell.has("iron_tools"):
            # The family opened up: the town processed the bought ore, from the
            # metal it made wares, and the wares are already on sale.
            found_family = true
            break
        details = "town %d: buys %s, sells %s" % [i, str(buy), str(sell)]
    _check(found_family,
        "the import cascade did not open the iron family for any town (%s)"
            % details)


# 5. ISOLATION. Bought goods are not sold — by design requirement.
func _test_import_isolated_from_sell() -> void:
    for i in range(40):
        var pools: Dictionary = _te.build_pools("town_%d" % i, [WOOD, IRON_ORE])
        var sell: Array = pools["sell_pool"]
        var buy: Array = pools["buy_pool"]
        for pid in buy:
            _check(not sell.has(pid),
                "imported good \"%s\" must not land in the sell pool" % pid)


# 6. DETERMINISM (the main regression test). On save load the pools are
# computed twice, so a repeated call must give the SAME thing.
func _test_determinism() -> void:
    for i in range(10):
        var town_id := "town_det_%d" % i
        var first: Dictionary = _te.build_pools(town_id, [WOOD, COPPER_ORE, WHEAT])
        var second: Dictionary = _te.build_pools(town_id, [WOOD, COPPER_ORE, WHEAT])
        _check(first["sell_pool"] == second["sell_pool"],
            "the sell pool of town %s changed on recomputation" % town_id)
        # Stability is the only thing checked here; "will the town buy anything
        # at all" depends on rolls and by definition is not guaranteed for any
        # particular town (see the cascade test, which iterates dozens of ids
        # for that reason).
        _check(first["buy_pool"] == second["buy_pool"],
            "the buy pool of town %s changed on recomputation" % town_id)


# 8. @-GROUP REPRESENTATIVE. Random, but stable and always from the group.
func _test_group_member() -> void:
    var gd = get_root().get_node("GameData")
    var members: Array = gd.product_groups.get("bronze_alloys", [])
    # bronze asks for @bronze_alloys: the pool has copper (ore) and charcoal
    # (wood), it is precisely the alloy that is missing. If the town decided to
    # import, the purchase must contain ONE of the group members — and no
    # "@bronze_alloys" key.
    var seen_group_pick := false
    for i in range(40):
        var pools: Dictionary = _te.build_pools("town_grp_%d" % i, [WOOD, COPPER_ORE])
        for pid in pools["buy_pool"]:
            _check(not str(pid).begins_with("@"),
                "there must be no group key \"%s\" in the buy pool" % pid)
            if members.has(str(pid)):
                seen_group_pick = true
    _check(seen_group_pick,
        "no town picked a representative of @bronze_alloys — "
        + "check the group expansion in import")


# --- Base pool: products only, not raw resources ---

# Synthetic hexes with one resource each (collect_base_resources reads the
# resource key, and on empty — crop_bred).
func _tiles_with(resources: Array) -> Array:
    var tiles: Array = []
    for res_id in resources:
        tiles.append({"resource": str(res_id)})
    return tiles

# The sell pool from hexes with the given resources (without import: 0 gaps).
# The types are annotated explicitly: _te is loaded via load(), and without
# them the function's output is not inferred by the compiler.
func _sell_pool_of(resources: Array) -> Array:
    var base: Array = _te.collect_base_resources(_tiles_with(resources))
    var pools: Dictionary = _te.build_pools("town_base_test", base)
    return pools["sell_pool"]

# 10. Fields and deposits: the PRODUCTS go into the pool, the raw material
# itself does not. This is exactly what removes two consecutive "Wheat":
# wheat_field gives wheat, and both were named "Wheat", though they are
# different things — a sowing and a grain.
func _test_base_pool_is_products_only() -> void:
    var pool := _sell_pool_of(["wheat_field", "basalt_deposit"])
    _check(not pool.has("wheat_field"),
        "the field wheat_field itself must not land in the sell pool: the town sells wheat, not a wheat field")
    _check(not pool.has("basalt_deposit"),
        "the deposit basalt_deposit itself must not land in the sell pool: the town sells stone, not the deposit")
    _check(pool.has(WHEAT), "the field's product (wheat) must be in the sell pool")
    _check(pool.has("basalt"), "the deposit's product (basalt) must be in the sell pool")
    # Regression for the original symptom: no resource from data/resources/** in the pool.
    var gd = get_root().get_node("GameData")
    var raw_leaked: Array = []
    for res_id in pool:
        if gd.raw_resources.has(str(res_id)):
            raw_leaked.append(str(res_id))
    _check(raw_leaked.is_empty(),
        "there must be no raw resource from data/resources in the sell pool (found: %s)" % str(raw_leaked))

# 11. Animals: the pool has meat/hide/milk/catch, but not the animals themselves.
func _test_animals_excluded() -> void:
    var pool := _sell_pool_of(["cows", "ostrich", "freshwater_fish"])
    for animal in ["cows", "ostrich", "freshwater_fish"]:
        _check(not pool.has(animal),
            "the animal \"%s\" is not a good: the town must not sell it as such" % animal)
    _check(pool.has("raw_meat"), "cows must yield meat (raw_meat)")
    _check(pool.has("hide"), "cows must yield raw meat and hide (hide)")
    _check(pool.has("raw_milk"), "cows must yield milk (raw_milk)")
    _check(pool.has("eggs"), "ostriches must yield eggs (eggs)")
    _check(pool.has("raw_fish"), "fish must yield a catch (raw_fish), not the fish itself")

# 12. One-time resources: improved_by == null.
func _test_one_time_resources() -> void:
    # Wild food is gathered once -> there is nothing to trade.
    var wild := _sell_pool_of(["wild_food"])
    _check(not wild.has("wild_food"), "wild food must not be sold as such")
    _check(not wild.has("foraged_food"),
        "food gathered from wild food must not be a good: it cannot be gathered again")
    # Nuggets are also one-time, but they are ORE, not a find: copper is needed
    # by the smith, and it is mined without limit.
    var nugget := _sell_pool_of(["copper_nugget"])
    _check(not nugget.has("copper_nugget"), "the nugget itself is not a good, but a find on the hex")
    _check(nugget.has("copper"), "the nugget's product (copper) must be in the pool: copper is needed by the smith")
    # The is_one_time flag matches the game one (control_panel/main_map).
    _check(_te.is_one_time("wild_food"), "wild_food must be recognized as one-time")
    _check(_te.is_one_time("copper_nugget"), "copper_nugget must be recognized as one-time")
    _check(not _te.is_one_time("wheat_field"), "a field with improved_by is not one-time")


# 22. QUALITY. Every storage good has exactly ONE level: for raw material — the
# resource's quality on the hex, for crafting — the city's standard rule
# (weighted average over the ingredient levels, see CityData.quality_from_breakdown).
# Mixed quality does not occur in a town at all.
func _test_town_quality() -> void:
    var gd = get_root().get_node("GameData")
    var levels: Array = gd.get_quality_levels()
    _check(levels.size() == 4, "the quality scale must have 4 steps")

    # Raw material takes the hex's quality. Two hexes of the same raw material
    # of different quality are not averaged: the storage level is set by the
    # HIGHEST quality among those found.
    var tiles: Array = [
        {"resource": "wheat_field", "quality": "exceptional"},
        {"resource": "basalt_deposit", "quality": "fine"},
    ]
    var base: Dictionary = _te.collect_base_qualities(tiles)
    _check(str(base.get("wheat", "")) == "exceptional",
        "wheat must inherit the field's quality (got \"%s\")" % str(base.get("wheat", "")))
    _check(str(base.get("feed", "")) == "exceptional",
        "feed from the same field must have the same quality")
    _check(str(base.get("basalt", "")) == "fine",
        "stone must get the deposit's quality")

    # The highest wins, the traversal order does not matter. A common cow and
    # an exceptional cow in the same ring give meat/hide/milk of the
    # EXCEPTIONAL level.
    var highs: Dictionary = _te.collect_base_qualities([
        {"resource": "cows", "quality": "common"},
        {"resource": "cows", "quality": "exceptional"},
    ])
    _check(str(highs.get("raw_meat", "")) == "exceptional",
        "with a mix of a common and an exceptional cow, the exceptional wins (got \"%s\")"
            % str(highs.get("raw_meat", "")))
    _check(str(highs.get("hide", "")) == "exceptional",
        "the cow's by-products (hide) must also be exceptional")
    _check(str(highs.get("raw_milk", "")) == "exceptional",
        "the cow's by-products (milk) must also be exceptional")
    # The reverse order — the same result (the highest, not the "first encountered").
    var highs_rev: Dictionary = _te.collect_base_qualities([
        {"resource": "cows", "quality": "exceptional"},
        {"resource": "cows", "quality": "common"},
    ])
    _check(str(highs_rev.get("raw_meat", "")) == "exceptional",
        "the highest quality must not depend on the ring traversal order")
    # Perfect quality beats exceptional.
    var best: Dictionary = _te.collect_base_qualities([
        {"resource": "cows", "quality": "common"},
        {"resource": "cows", "quality": "exceptional"},
        {"resource": "cows", "quality": "perfect"},
    ])
    _check(str(best.get("raw_meat", "")) == "perfect",
        "perfect quality must beat exceptional (got \"%s\")"
            % str(best.get("raw_meat", "")))

    # A resource without a rolled quality (broken save) — the common level, not an empty string.
    var broken: Dictionary = _te.collect_base_qualities([{"resource": "wheat_field"}])
    _check(str(broken.get("wheat", "")) == "common",
        "a resource without quality must fall back to the common level")

    # Craft: the weighted average of the ingredients. wood (perfect=4) + copper_ore
    # (common=1) -> average 2.5 -> rounded to the nearest level (fine=2,
    # diff=0.5 vs exceptional=3, diff=0.5 — a tie, the first in the scale wins).
    var crafted: String = _te.craft_result_quality(
        {"id": "copper", "resources": {"wood": 1, "copper_ore": 1}},
        {"wood": true, "copper_ore": true},
        {"wood": "perfect", "copper_ore": "common"})
    _check(crafted == "fine" or crafted == "exceptional",
        "crafting from perfect+common must give a middle level (got \"%s\")" % crafted)

    # Both ingredients exceptional -> the result is exceptional.
    var same: String = _te.craft_result_quality(
        {"id": "copper", "resources": {"wood": 1, "copper_ore": 1}},
        {"wood": true, "copper_ore": true},
        {"wood": "exceptional", "copper_ore": "exceptional"})
    _check(same == "exceptional",
        "equal ingredient levels give the same level (got \"%s\")" % same)

    # The window shows stars in the level's color, without breakdown and percentages.
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["sell_pool"] = [WOOD, PLANKS]
    town["buy_pool"] = []
    town["storage"] = {WOOD: 120, PLANKS: 40}
    town["quality"] = {WOOD: "perfect", PLANKS: "fine"}
    tm.towns.append(town)

    ui.open_town(town, true)
    var quality_labels: Dictionary = ui._sell_quality_labels
    _check(quality_labels.size() == 2,
        "every sell row must have a quality label (got %d)" % quality_labels.size())
    var wood_name: String = ui._get_resource_display_name(WOOD)
    var wood_stars: Label = quality_labels.get(wood_name, null)
    _check(wood_stars != null, "a good's row must have a star label")
    if wood_stars != null:
        _check(wood_stars.text == gd.get_quality_stars("perfect"),
            "the row's stars must be the good's level (got \"%s\")" % wood_stars.text)
        _check(not wood_stars.text.contains("%") and not wood_stars.text.contains("("),
            "the quality label must have no breakdown or percentages, only stars")
        _check(wood_stars.get_theme_color("font_color") == gd.get_quality_color("perfect"),
            "the stars must be colored in their level's color")
        # The tooltip explains which quality level it is.
        _check(not wood_stars.tooltip_text.is_empty(),
            "the stars must have a tooltip explaining the level")
        _check(wood_stars.tooltip_text.contains(gd.get_quality_name("perfect")),
            "the tooltip must name the quality level (got \"%s\")" % wood_stars.tooltip_text)
        _check(wood_stars.mouse_filter == Control.MOUSE_FILTER_STOP,
            "the star label must catch the mouse, otherwise the tooltip will not show")
    # The second good — its own level and its own tooltip.
    var planks_name: String = ui._get_resource_display_name(PLANKS)
    var planks_stars: Label = quality_labels.get(planks_name, null)
    _check(planks_stars != null, "the second row must also have a star label")
    if planks_stars != null:
        _check(planks_stars.text == gd.get_quality_stars("fine"),
            "the second row's stars must be its level (got \"%s\")" % planks_stars.text)
        _check(planks_stars.tooltip_text.contains(gd.get_quality_name("fine")),
            "the second row's tooltip must name its level (got \"%s\")" % planks_stars.tooltip_text)
    ui.queue_free()
    tm.queue_free()


# 13. Two different ids with the same name — one row in the window.
# The main protection against duplicates lives in the data (raw material does
# not land in the pool), but data/products has exactly one pair of different
# ids with the same name: papyrus_plant (crop) and papyrus (craft) are both
# called "Papyrus", and both can end up in one town's pool.
func _test_duplicate_names_hidden() -> void:
    var gd = get_root().get_node("GameData")
    var papyrus_plant: Dictionary = gd.products.get("papyrus_plant", {})
    var papyrus: Dictionary = gd.products.get("papyrus", {})
    _check(not papyrus_plant.is_empty() and not papyrus.is_empty(),
        "the test relies on the papyrus_plant/papyrus pair in data/products — it must exist")
    _check(str(papyrus_plant.get("name", "")) == str(papyrus.get("name", "")),
        "papyrus_plant and papyrus must be named the same, otherwise the test is meaningless")
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    # The frame is needed for @onready: without it the node references are not filled yet.
    await process_frame
    ui.open_town({"name": "T", "sell_pool": ["papyrus_plant", "papyrus"], "buy_pool": []}, true)
    var names: Array = ui._visible_row_names(ui.sell_list)
    _check(names.size() == 1,
        "two goods with the same name must give one row (got %d: %s)"
            % [names.size(), str(names)])
    ui.queue_free()

# 14. Window: the lists scroll and draw nothing over the map.
func _test_town_ui_window() -> void:
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    _check(ui.buy_scroll is ScrollContainer,
        "the buy list must live in a ScrollContainer, otherwise a long list will spill onto the map")
    _check(ui.sell_scroll is ScrollContainer,
        "the sell list must live in a ScrollContainer, otherwise a long list will spill onto the map")
    _check(ui.buy_list.get_parent() == ui.buy_scroll, "BuyList must be a child of BuyScroll")
    _check(ui.sell_list.get_parent() == ui.sell_scroll, "SellList must be a child of SellScroll")
    _check(ui.window_panel.clip_contents,
        "WindowPanel must clip its contents: otherwise a long list is drawn over the map")

    # A long pool: there are far more rows than fit in the window.
    var gd = get_root().get_node("GameData")
    var long_pool: Array = []
    for pid in gd.products.keys():
        long_pool.append(str(pid))
    ui.open_town({"name": "T", "sell_pool": long_pool, "buy_pool": long_pool}, true)
    await process_frame
    await process_frame
    _check(ui.sell_list.get_child_count() > 10,
        "the test must fill the list with dozens of rows (rows: %d)" % ui.sell_list.get_child_count())
    # The key point: the content is taller than the window — so scrolling is really needed.
    var content_height: float = ui.sell_list.size.y
    var window_height: float = ui.window_panel.size.y
    _check(content_height > window_height,
        "the content must be taller than the window, otherwise there is nothing to scroll (content %d, window %d)"
            % [int(content_height), int(window_height)])
    # And the scroll really scrolls: we shift it and wait for a frame.
    ui.sell_scroll.scroll_vertical = int(content_height)
    await process_frame
    _check(ui.sell_scroll.scroll_vertical > 0,
        "the ScrollContainer must scroll vertically (position: %d)" % ui.sell_scroll.scroll_vertical)
    ui.queue_free()


# 15. Town treasury: starting value, deals, the window in real time, save.
func _test_town_treasury() -> void:
    var gd = get_root().get_node("GameData")
    var expected := int(gd.game_balance.get("town_initial_treasury", -1))
    _check(expected == 1000,
        "town_initial_treasury in game_balance.json: expected 1000, got %d" % expected)

    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    _check(int(town.get("treasury", -1)) == expected,
        "a new town must receive the starting treasury (got %s)" % str(town.get("treasury")))

    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    tm.town_treasury_changed.connect(ui.on_town_treasury_changed)
    ui.open_town(town, true)
    _check(ui.treasury_label.text.contains(str(expected)),
        "the window must show the town's treasury (text: %s)" % ui.treasury_label.text)

    tm.add_town_treasury(town, 150)
    _check(ui.treasury_label.text.contains(str(expected + 150)),
        "after income the treasury in the window must update immediately (text: %s)" % ui.treasury_label.text)
    _check(tm.spend_town_treasury(town, 50), "a debit within the treasury must go through")
    _check(ui.treasury_label.text.contains(str(expected + 100)),
        "after the debit the treasury in the window must update immediately (text: %s)" % ui.treasury_label.text)
    _check(not tm.spend_town_treasury(town, expected * 10), "the town cannot go negative")
    _check(tm.get_town_treasury(town) == expected + 100, "a failed debit does not change the treasury")

    tm.towns.append(town)
    var saved: Array = tm.serialize_towns()
    tm.load_towns(saved)
    _check(tm.get_town_treasury(tm.towns[0]) == expected + 100, "the town treasury must survive a save")
    var legacy: Dictionary = saved[0].duplicate()
    legacy.erase("treasury")
    tm.load_towns([legacy])
    _check(tm.get_town_treasury(tm.towns[0]) == expected,
        "a save without a town treasury must receive the starting value")

    ui.queue_free()
    tm.queue_free()


# 9. LIVE MAP. The pools are computed for real towns, and a recomputation
# (as on save load) changes nothing.
func _test_live_map() -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    var tm = main_map.get_node_or_null("TownManager")
    if tm == null:
        print("SKIP: the live map did not create a TownManager")
        return
    var towns: Array = tm.towns
    _check(not towns.is_empty(), "the live map must have towns")
    var first: Dictionary = {}
    for town in towns:
        var sell: Array = town.get("sell_pool", [])
        _check(not sell.is_empty(),
            "the sell pool of town %s is empty — the town has nothing to sell"
                % str(town.get("id", "")))
        # Import must not leak into the sale.
        for pid in town.get("buy_pool", []):
            _check(not sell.has(pid),
                "in town %s the bought good \"%s\" landed in the sale"
                    % [str(town.get("id", "")), pid])
        first[str(town.get("id", ""))] = [sell.duplicate(), town.get("buy_pool", []).duplicate()]
    # A recomputation — exactly what the game does on save load.
    tm._refresh_sell_pools(main_map.tile_data)
    for town in towns:
        var key := str(town.get("id", ""))
        if not first.has(key):
            continue
        _check(first[key][0] == town.get("sell_pool", []),
            "in town %s the sell pool changed on recomputation" % key)
        _check(first[key][1] == town.get("buy_pool", []),
            "in town %s the buy pool changed on recomputation" % key)

    # --- STORAGE ON THE LIVE MAP ---
    # Every town has a storage covering the whole sell pool, and it is not
    # empty: otherwise the player would see goods in the window with not a
    # single unit.
    for town in towns:
        var key := str(town.get("id", ""))
        var storage: Dictionary = town.get("storage", {})
        var sell: Array = town.get("sell_pool", [])
        _check(not storage.is_empty(),
            "town %s has an empty storage — nothing to sell in the window" % key)
        for pid in sell:
            _check(storage.has(str(pid)),
                "in town %s the storage lacks the good \"%s\" from the sell pool"
                    % [key, pid])
        # Bought goods are not put into storage: what is bought is raw material, not a good.
        for pid in town.get("buy_pool", []):
            _check(not storage.has(str(pid)),
                "in town %s the bought good \"%s\" landed in storage" % [key, pid])
        # The storage mirrors the sell pool one-to-one: it has nothing extra and
        # nothing missing. The pool is computed TWICE on a new game, and between
        # the passes the ring gets decorative fields, so a good may stop being
        # sellable after it has already landed in storage.
        var on_stock: Array = []
        for pid in storage.keys():
            on_stock.append(str(pid))
        on_stock.sort()
        var sell_sorted: Array = sell.duplicate()
        sell_sorted.sort()
        _check(on_stock == sell_sorted,
            "the storage of town %s must match the sell pool: in storage %s, in the pool %s"
                % [key, str(on_stock), str(sell_sorted)])
        # And the storage is filled BELOW the limit: an unscouted town must not
        # stand full already at the start of the game (see test 19 on scouting).
        var limit: int = _te.get_storage_limit()
        for pid in storage:
            _check(int(storage[pid]) <= limit,
                "in town %s the good \"%s\" in storage is above the limit (%d > %d)"
                    % [key, pid, int(storage[pid]), limit])

    # --- QUALITY ON THE LIVE MAP ---
    # Every storage good has exactly one quality level, and it is from the
    # data/qualities.json scale. There must be no row without stars in the window.
    var gd = get_root().get_node("GameData")
    var levels: Array = gd.get_quality_levels()
    for town in towns:
        var key := str(town.get("id", ""))
        var quality: Dictionary = town.get("quality", {})
        _check(not quality.is_empty(),
            "town %s has no quality for its storage goods" % key)
        for pid in town.get("sell_pool", []):
            var qid := str(quality.get(str(pid), ""))
            _check(levels.has(qid),
                "in town %s the good \"%s\" has no quality level (got \"%s\")"
                    % [key, pid, qid])
        # Mixed quality does not occur in a town: quality is stored as one
        # level per good, not a breakdown, so extra keys are an error.
        for pid in quality.keys():
            _check(levels.has(str(quality[pid])),
                "in town %s the good \"%s\" has a level outside the scale" % [key, pid])
        for pid in quality.keys():
            _check(town.get("sell_pool", []).has(str(pid)),
                "in town %s quality is set for the non-sellable \"%s\"" % [key, pid])
    main_map.queue_free()


# 16. STARTING SUPPLY. Every good of the sell pool has a supply within the
# bounds from game_balance.json, and a pool recomputation (as on save load)
# does NOT touch it: otherwise sold units would come back on every load.
func _test_storage_seeded() -> void:
    var gd = get_root().get_node("GameData")
    var low := int(gd.game_balance.get("town_storage_initial_min", -1))
    var high := int(gd.game_balance.get("town_storage_initial_max", -1))
    _check(low == 100,
        "town_storage_initial_min in game_balance.json: expected 100, got %d" % low)
    _check(high == 500,
        "town_storage_initial_max in game_balance.json: expected 500, got %d" % high)

    var storage: Dictionary = _te.build_initial_storage("town_0", [WOOD, PLANKS, WHEAT])
    _check(storage.size() == 3,
        "the starting storage must cover all three goods (got %d)" % storage.size())
    for pid in storage:
        var amount := int(storage[pid])
        _check(amount >= low and amount <= high,
            "the starting supply \"%s\" = %d, outside the bounds [%d, %d]" % [pid, amount, low, high])

    # Determinism: the same town and the same good give the same supply. The
    # pools are computed twice on a new game and on every load, so a random
    # value here would mean a jumping storage.
    var again: Dictionary = _te.build_initial_storage("town_0", [WOOD, PLANKS, WHEAT])
    _check(again == storage, "the starting supply must be deterministic")

    # Different towns differ: neighbors on the map must not have an identical
    # "carbon-copy" storage.
    var differs := false
    for i in range(30):
        var other: Dictionary = _te.build_initial_storage("town_%d" % i,
                [WOOD, PLANKS, WHEAT])
        if other.get(WOOD, -1) != storage.get(WOOD, -2):
            differs = true
            break
    _check(differs, "different towns must have different supplies of the same good")


# 17. PRODUCTION PLAN BY RECIPE. The production plan (production) is derived
# from the recipes: as much as a recipe promises, that much is written into the
# plan. But the plan NO LONGER moves the storage directly — the storage is
# moved by daily TRADE (test 23).
func _test_production_plan() -> void:
    var gd = get_root().get_node("GameData")
    var base: Array = _te.collect_base_resources(_tiles_with([WOOD]))
    var pools: Dictionary = _te.build_pools("town_prod", base)
    var production: Dictionary = pools["production"]
    _check(not production.is_empty(),
        "from wood the town produces something — the production plan is not empty")
    var checked := 0
    for pid in production:
        var id := str(pid)
        # We look for a recipe with such a result and compare the output.
        for craft in gd.crafts:
            var result: Dictionary = craft.get("result", {})
            if not result.has(id):
                continue
            _check(int(production[id]) == int(result[id]),
                "recipe \"%s\" output for \"%s\": plan=%d, recipe=%d"
                    % [str(craft.get("id", "")), id, int(production[id]), int(result[id])])
            checked += 1
            break
        # Import does not land in storage.
        _check(not pools["buy_pool"].has(id),
            "the bought good \"%s\" must not land in the production plan" % id)
    _check(checked > 0,
        "the test must compare at least one good against a recipe (compared: %d)" % checked)


# 18. STORAGE LIMIT. The limit applies PER GOOD, not to the whole storage: a
#     town that has hit the ceiling on one good keeps trading the others.
func _test_storage_limit() -> void:
    var limit: int = _te.get_storage_limit()
    _check(limit == 1000,
        "town_storage_limit in game_balance.json: expected 1000, got %d" % limit)

    # A good at the ceiling and its neighbor: a long trade run must not let
    # either of them past the limit, but the neighbor must move — the ceiling on
    # one good does not freeze the others.
    var storage: Dictionary = {WOOD: limit, PLANKS: 10, CHARCOAL: 7}
    var signs: Dictionary = {}
    var counter := 0
    var planks_moved := false
    for _i in range(200):
        counter = _te.tick_trade(storage, signs, counter, "town_limit", limit)
        _check(int(storage[WOOD]) <= limit and int(storage[WOOD]) >= 0,
            "a good at the ceiling must not go past the limit (got %d)" % int(storage[WOOD]))
        if int(storage[PLANKS]) != 10:
            planks_moved = true
    _check(planks_moved,
        "the neighboring good must keep trading while another is at the ceiling")
    for pid in storage:
        _check(int(storage[pid]) >= 0 and int(storage[pid]) <= limit,
            "\"%s\" went outside the bounds [0, %d]: %d" % [str(pid), limit, int(storage[pid])])


# A synthetic map where the given hex (row, col) carries the flags, and the
# rest are empty. Its size is fitted to the town's hex: town_manager looks at
# the town's own coordinates, not at the first hex.
func _map_with_tile(row: int, col: int, flags: Dictionary) -> Array:
    var tile_data: Array = []
    for r in range(row + 1):
        var line: Array = []
        for c in range(col + 1):
            line.append(flags.duplicate() if r == row and c == col else {})
        tile_data.append(line)
    return tile_data


# 19. TRADE STARTS ONLY AFTER SCOUTING. An unscouted town does not trade,
# otherwise by the time it meets the player its storage would have drifted
# from the starting supply.
func _test_production_after_scouting() -> void:
    var gd = get_root().get_node("GameData")
    var city_data = get_root().get_node("CityData")
    # A town tick is town_tick_ticks times longer than the city tick. We check
    # both the multiplier from game_balance.json and the resulting duration.
    _check(int(gd.game_balance.get("town_tick_ticks", -1)) == 4,
        "town_tick_ticks in game_balance.json: expected 4, got %d"
            % int(gd.game_balance.get("town_tick_ticks", -1)))
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town_tick: float = tm.get_town_tick_seconds()
    _check(is_equal_approx(town_tick,
            float(city_data.SIMULATION_TICK) * 4.0),
        "the town tick must be 4 times longer than the city tick (got %.2f, city tick %.2f)"
            % [town_tick, float(city_data.SIMULATION_TICK)])
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["sell_pool"] = [WOOD]
    town["production"] = {WOOD: 10}
    town["storage"] = {WOOD: 100}
    tm.towns.append(town)

    # A hex in an unknown world: no flags — the town does not trade.
    var unknown := _map_with_tile(5, 5, {"is_explored": false, "in_influence": false})
    tm.tick_towns(unknown)
    _check(tm.get_town_goods(town, WOOD) == 100,
        "an unscouted town must not trade (storage=%d)"
            % tm.get_town_goods(town, WOOD))
    _check(not bool(town.get("production_started", false)),
        "the production-start flag must not be set before scouting")
    _check(int(town.get("trade_counter", -1)) == 0,
        "an unscouted town must not advance the trade counter")

    # Scouting revealed the hex — trade began. The storage shifted in EITHER
    # direction, but by exactly one deal: not "+10 by the plan", but a market
    # lot of 3..15 (or wholesale).
    unknown[5][5]["is_explored"] = true
    tm.tick_towns(unknown)
    var after: int = tm.get_town_goods(town, WOOD)
    _check(after != 100,
        "after scouting the town must trade (storage remained %d)" % after)
    var moved: int = absi(after - 100)
    _check(moved >= int(_te.get_trade_min()),
        "a deal cannot be smaller than the minimum (shift %d)" % moved)
    _check(bool(town.get("production_started", false)),
        "the production-start flag must be set on scouting")
    _check(int(town.get("trade_counter", -1)) == 1,
        "a scouted town must advance the trade counter")

    # The second scouting path — a hex inside known territory, without is_explored.
    var town2: Dictionary = tm._make_town_record(1, 1, 1, false)
    town2["sell_pool"] = [WOOD]
    town2["production"] = {WOOD: 10}
    town2["storage"] = {WOOD: 100}
    tm.towns.append(town2)
    var known := _map_with_tile(1, 1, {"in_influence": true, "is_explored": false})
    tm.tick_towns(known)
    _check(tm.get_town_goods(town2, WOOD) != 100,
        "a hex in known territory also starts trade (storage=%d)"
            % tm.get_town_goods(town2, WOOD))
    tm.queue_free()


# 23. COMFORT LEVEL IS DERIVED FROM DATA. It is the middle of the starting
# supply range: a town is born somewhere in
# [town_storage_initial_min, max], so exactly this range is the "healthy supply"
# for the game. There is deliberately no separate field — otherwise the number
# would drift from the range when the balance is tweaked.
func _test_trade_comfort_from_data() -> void:
    var gd = get_root().get_node("GameData")
    var low := float(gd.game_balance.get("town_storage_initial_min", 100))
    var high := float(gd.game_balance.get("town_storage_initial_max", 500))
    var expected := (low + high) * 0.5
    _check(is_equal_approx(_te.get_trade_comfort(), expected),
        "comfort must be the middle of the starting supply range: expected %.1f, got %.1f"
            % [expected, _te.get_trade_comfort()])
    # On the current data this is exactly 300.
    _check(is_equal_approx(_te.get_trade_comfort(), 300.0),
        "with the current game_balance.json comfort must be 300 (got %.1f)"
            % _te.get_trade_comfort())


# 24. TRADE MOVES BOTH WAYS. The key requirement: the numbers in storage either
# grow or shrink, like in real trade — not monotonically rise to the ceiling.
# We run a long series of ticks and check that there were BOTH purchases AND
# sales, and that the storage did not "stick" to the starting supply.
func _test_trade_moves_both_ways() -> void:
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["storage"] = {WOOD: 300}
    # The trade counter is needed: an unscouted/hexless town does not trade, so
    # we drive the model directly through TownEconomy.tick_trade.
    var ups := 0
    var downs := 0
    var limit: int = _te.get_storage_limit()
    var signs: Dictionary = {}
    var counter := 0
    var previous := 300
    for _i in range(400):
        counter = _te.tick_trade(town["storage"], signs, counter, "town_moves", limit)
        var now: int = int(town["storage"][WOOD])
        if now > previous:
            ups += 1
        elif now < previous:
            downs += 1
        previous = now
    _check(ups > 0 and downs > 0,
        "over 400 trade ticks there must be both purchases and sales (up=%d, down=%d)"
            % [ups, downs])
    # Both sides must be substantial, not one random deal: the market must move
    # back and forth, not crawl in one direction.
    _check(ups >= 40 and downs >= 40,
        "trade must be substantially two-way (up=%d, down=%d)" % [ups, downs])
    # The storage must not stay put for the whole run.
    _check(int(town["storage"][WOOD]) != 300,
        "the storage must not freeze at the starting supply")
    tm.queue_free()


# 25. BOUNDARIES. The storage never goes negative and never exceeds the limit,
# even if trade is driven on an empty and on a full storage.
func _test_trade_bounds_and_no_negative() -> void:
    var limit: int = _te.get_storage_limit()
    # Empty storage: there is nothing to sell — the direction is forcedly
    # buying, the storage grows instead of falling below zero.
    var empty_rng := RandomNumberGenerator.new()
    empty_rng.seed = 1
    var empty: Dictionary = _te.trade_once(0, limit, -1, empty_rng)
    _check(int(empty["stock"]) >= 0,
        "an empty storage cannot go negative (storage=%d)" % int(empty["stock"]))
    _check(int(empty["sign"]) >= 0,
        "on an empty storage the town cannot sell (sign=%d)" % int(empty["sign"]))
    # Full storage: there is nowhere to buy — the direction is forcedly selling,
    # the limit is not exceeded.
    var full_rng := RandomNumberGenerator.new()
    full_rng.seed = 1
    var full: Dictionary = _te.trade_once(limit, limit, 1, full_rng)
    _check(int(full["stock"]) <= limit,
        "a full storage must not exceed the limit (storage=%d)" % int(full["stock"]))
    _check(int(full["sign"]) <= 0,
        "on a full storage the town cannot buy (sign=%d)" % int(full["sign"]))

    # A long run from edge to edge: not a single excursion outside [0, limit]
    # and not a single negative remainder.
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    for start in [0, 1, 5, limit - 1, limit]:
        var town: Dictionary = tm._make_town_record(0, 5, 5, false)
        town["storage"] = {WOOD: int(start)}
        var signs: Dictionary = {}
        var counter := 0
        for _i in range(300):
            counter = _te.tick_trade(town["storage"], signs, counter,
                    "town_bounds_%d" % start, limit)
            var now: int = int(town["storage"][WOOD])
            _check(now >= 0 and now <= limit,
                "the storage went outside the bounds [0, %d]: %d (start %d)" % [limit, now, int(start)])
    tm.queue_free()


# 26. INERTIA AND RUNS. The direction repeats, so rises and falls come in short
# runs, instead of alternating every day. We check that runs are really longer
# than one deal — this is exactly what the design asked for ("long runs of rises
# or falls may be observed").
func _test_trade_inertia_and_runs() -> void:
    var limit: int = _te.get_storage_limit()
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["storage"] = {WOOD: 300}
    var signs: Dictionary = {}
    var counter := 0
    var previous := 300
    var run_length := 0
    var run_direction := 0
    var max_run := 0
    var long_runs := 0
    for _i in range(400):
        counter = _te.tick_trade(town["storage"], signs, counter, "town_runs", limit)
        var now: int = int(town["storage"][WOOD])
        var direction := signi(now - previous)
        if direction != 0 and direction == run_direction:
            run_length += 1
        else:
            run_direction = direction
            run_length = 1 if direction != 0 else 0
        max_run = maxi(max_run, run_length)
        if run_length >= 3:
            long_runs += 1
        previous = now
    _check(max_run >= 3,
        "inertia must produce runs of at least 3 consecutive deals (max run %d)" % max_run)
    _check(long_runs > 0,
        "runs of rises/falls of length 3+ must occur (found %d)" % long_runs)
    # The last deal's direction is stored in state — it is the input of inertia.
    _check(signs.has(WOOD), "the last deal's direction must be stored in state")
    tm.queue_free()


# 20. DEAL. A sale debits units from the storage, a purchase puts them there.
# Outside the supply the deal does not go through — the town does not sell what
# it does not have.
func _test_trade_moves_goods() -> void:
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["storage"] = {WOOD: 200}
    tm.towns.append(town)

    _check(tm.get_town_goods(town, WOOD) == 200, "the starting supply must be read from the storage")
    _check(tm.take_town_goods(town, WOOD, 50), "selling 50 units must go through")
    _check(tm.get_town_goods(town, WOOD) == 150,
        "after the sale 150 must remain in storage (got %d)"
            % tm.get_town_goods(town, WOOD))
    _check(not tm.take_town_goods(town, WOOD, 500),
        "the town cannot sell more than it has in storage")
    _check(tm.get_town_goods(town, WOOD) == 150,
        "a failed sale must not change the storage")

    _check(tm.add_town_goods(town, PLANKS, 30) == 30, "buying 30 units must go through")
    _check(tm.get_town_goods(town, PLANKS) == 30, "after the purchase the good must be in storage")

    # A purchase into an already full storage accepts only what fits.
    var limit: int = _te.get_storage_limit()
    var full: Dictionary = tm._make_town_record(2, 6, 6, false)
    full["storage"] = {WOOD: limit}
    tm.towns.append(full)
    _check(tm.add_town_goods(full, WOOD, 100) == 0,
        "nothing must fit into a full storage")
    _check(tm.add_town_goods(full, PLANKS, 25) == 25,
        "it must fit into another good — the limit is per good, not per storage")

    # Save: the storage and the scouting flag survive a round-trip.
    var saved: Array = tm.serialize_towns()
    tm.load_towns(saved)
    var loaded: Dictionary = tm.towns[0]
    _check(tm.get_town_goods(loaded, WOOD) == 150,
        "the storage must survive a save (got %d)" % tm.get_town_goods(loaded, WOOD))

    # 27. TRADE STATE SURVIVES A SAVE. The last deal's direction and the tick
    # counter are WORLD STATE, not derived data (unlike "production", which is
    # recomputed from the ring). If they are not saved, then on load the deal
    # "flips" and the storage is shuffled. Here we check exactly that: after a
    # round-trip the next tick must go the SAME way.
    var trade_town: Dictionary = tm._make_town_record(7, 9, 9, false)
    trade_town["storage"] = {WOOD: 300, PLANKS: 300}
    tm.towns.append(trade_town)
    var limit2: int = _te.get_storage_limit()
    # We run a few ticks so the state stops being trivial.
    for _i in range(5):
        var signs: Dictionary = trade_town.get("trade_signs", {})
        var counter := int(trade_town.get("trade_counter", 0))
        counter = _te.tick_trade(trade_town["storage"], signs, counter,
                str(trade_town.get("id", "")), limit2)
        trade_town["trade_signs"] = signs
        trade_town["trade_counter"] = counter
    _check(int(trade_town["trade_counter"]) == 5,
        "the trade counter must advance by 5 ticks")
    _check(not trade_town["trade_signs"].is_empty(),
        "the last deals' directions must be recorded in state")

    var round_trip: Array = tm.serialize_towns()
    tm.load_towns(round_trip)
    var reloaded: Dictionary = {}
    for t in tm.towns:
        if str(t.get("id", "")) == str(trade_town.get("id", "")):
            reloaded = t
            break
    _check(not reloaded.is_empty(), "the town with trade state must survive a save")
    _check(int(reloaded.get("trade_counter", -1)) == 5,
        "the trade counter must survive a save (got %s)"
            % str(reloaded.get("trade_counter")))
    _check(reloaded.get("trade_signs", {}) == trade_town["trade_signs"],
        "the deals' directions must survive a save")
    # And most importantly: the next tick after loading repeats the one that would have been without it.
    var expected_signs: Dictionary = trade_town["trade_signs"].duplicate()
    var expected_counter := int(trade_town["trade_counter"])
    var expected_storage: Dictionary = trade_town["storage"].duplicate()
    _te.tick_trade(expected_storage, expected_signs, expected_counter,
            str(trade_town.get("id", "")), limit2)
    var loaded_signs: Dictionary = reloaded["trade_signs"]
    var loaded_counter := int(reloaded["trade_counter"])
    _te.tick_trade(reloaded["storage"], loaded_signs, loaded_counter,
            str(reloaded.get("id", "")), limit2)
    _check(reloaded["storage"][WOOD] == expected_storage[WOOD]
            and reloaded["storage"][PLANKS] == expected_storage[PLANKS],
        "the next tick after loading must repeat the same path (got %s, expected %s)"
            % [str(reloaded["storage"]), str(expected_storage)])
    tm.queue_free()


# 21. THE WINDOW SHOWS THE STORAGE. The sell column shows the number of units,
# and it updates on the trade signal without rebuilding the list.
func _test_window_shows_stock() -> void:
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["sell_pool"] = [WOOD, PLANKS]
    town["buy_pool"] = [IRON_ORE]
    town["storage"] = {WOOD: 321, PLANKS: 7}
    tm.towns.append(town)
    tm.town_storage_changed.connect(ui.on_town_storage_changed)

    ui.open_town(town, true)
    var labels: Dictionary = ui._sell_quantity_labels
    _check(labels.size() == 2,
        "the sell column must have a number for each good (got %d)" % labels.size())
    # The rows are keyed by display name, and it is translated: we take it from
    # the window itself, otherwise the check would depend on the test run's language.
    var wood_name: String = ui._get_resource_display_name(WOOD)
    var wood_label: Label = labels.get(wood_name, null)
    _check(wood_label != null and wood_label.text.contains("321"),
        "the window must show the number of units of the good in storage")

    # A deal changes the storage — the label updates immediately, and the list
    # is not rebuilt (otherwise the scroll would reset on every deal).
    var rows_before: Array = ui.sell_list.get_children()
    tm.take_town_goods(town, WOOD, 21)
    _check(ui._sell_quantity_labels.get(wood_name, null).text.contains("300"),
        "after the sale the number in the window must update immediately")
    _check(ui.sell_list.get_children() == rows_before,
        "updating the numbers must not rebuild the list")

    # A town tick also updates the window — a separate path refresh_storage().
    ui.refresh_storage()
    _check(ui._sell_quantity_labels.get(wood_name, null).text.contains("300"),
        "refresh_storage must read the current storage")
    ui.queue_free()
    tm.queue_free()


# 28. CATEGORIES IN THE WINDOW. The goods in the buy and sell pools are split
# by category, as on the city interface's "Resources" tab: the category header
# is a solid line, the name centered, the line; below it — rows of only that
# category.
func _test_town_ui_categories() -> void:
    var gd = get_root().get_node("GameData")
    # One good from EACH category — otherwise there is nothing to check the split with.
    var pool: Array = []
    var used_cat: Dictionary = {}
    var used_name: Dictionary = {}
    for pid in gd.products.keys():
        var id := str(pid)
        var name := str(gd.get_resource_data(id).get("name", id))
        if used_name.has(name):
            continue
        var cat := str(gd.get_resource_data(id).get("category", "other"))
        if used_cat.has(cat):
            continue
        used_cat[cat] = true
        used_name[name] = true
        pool.append(id)
        if pool.size() >= 4:
            break
    _check(pool.size() >= 3,
        "the test must collect goods from several categories (got %d)" % pool.size())

    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    ui.open_town({"name": "T", "sell_pool": pool, "buy_pool": pool}, true)
    await process_frame
    _assert_pool_grouped(ui.sell_list, ui, pool)
    _assert_pool_grouped(ui.buy_list, ui, pool)
    ui.queue_free()


# Checks that the container's rows are grouped by category: each row goes
# under the header of ITS OWN category, the header has lines on the left and
# right, and there are exactly as many headers as there are distinct categories
# in the pool.
func _assert_pool_grouped(container, ui, pool: Array) -> void:
    var expected: Dictionary = {}   # display name -> expected category name
    var categories: Dictionary = {}
    for pid in pool:
        var id := str(pid)
        var name: String = ui._get_resource_display_name(id)
        var cat: String = ui._get_resource_category(id)
        expected[name] = ui._get_category_name(cat)
        categories[cat] = true

    var current_header := ""
    var header_count := 0
    var row_count := 0
    for entry in ui._visible_list_entries(container):
        if entry["kind"] == "header":
            current_header = str(entry["text"])
            header_count += 1
            _check(bool(entry.get("lined", false)),
                "the category name \"%s\" must have lines on the left and right" % current_header)
        else:
            var row_name := str(entry["text"])
            row_count += 1
            _check(current_header == str(expected.get(row_name, "<none>")),
                "the row \"%s\" must go under the header of its own category (currently \"%s\")"
                    % [row_name, current_header])
    _check(header_count == categories.size(),
        "there must be as many headers as distinct categories in the pool (%d, got %d)"
            % [categories.size(), header_count])
    _check(row_count == expected.size(),
        "there must be as many rows as goods in the pool (%d, got %d)"
            % [expected.size(), row_count])
