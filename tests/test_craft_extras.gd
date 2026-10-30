# Headless test for the additional ingredients of a recipe — the generated result
# (see GameData.gd, "Additional ingredients of a recipe"):
#   godot --headless --path . --script res://tests/test_craft_extras.gd
#
# Checks:
#   1) the generated id round-trips: one addition is accepted, an unknown one and a second one
#      are rejected;
#   2) the recipe built on the fly keeps the ingredients of the base, adds the chosen good as
#      an AND-term and yields the generated good;
#   3) the generated good is materialised: category, icon and technology of the base, the price
#      formula, membership in the goods groups of the base;
#   4) a full cycle through do_tick spends the addition and produces the generated good;
#   5) a re-read of the data drops the generated records, and the rebuild brings them back;
#   6) the price of a generated good against its base — the row of the tooltips;
#   7) the radio buttons follow the warehouse: a good that is not there cannot be picked, while
#      the chosen one stays clickable so that the choice can be taken back;
#   8) the quality of the addition raises the quality of the result by one level at most;
#   9) an open window of the additions refreshes its amounts and availability in place.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _done := false

func _initialize() -> void:
    WATCHDOG.arm(self)

func _process(_delta) -> bool:
    if _done:
        return true
    _done = true
    _run()
    return true

func _run() -> void:
    var state = {"failed": false}

    # The names are asserted as the source text: the machine may run in another language, and
    # the autoloads choose it on the first frame — after this test has started.
    TranslationServer.set_locale("en")

    var gd = get_root().get_node("GameData")
    gd.load_all_data()
    var city = get_root().get_node("CityData")

    if WATCHDOG.wants_case("id_roundtrip"):
        _test_id_roundtrip(gd, state)
    if WATCHDOG.wants_case("recipe_built"):
        _test_recipe_built(gd, city, state)
    if WATCHDOG.wants_case("product_materialised"):
        _test_product_materialised(gd, state)
    if WATCHDOG.wants_case("cycle"):
        _test_cycle(gd, city, state)
    if WATCHDOG.wants_case("rebuild"):
        _test_rebuild(gd, city, state)
    if WATCHDOG.wants_case("extra_price"):
        _test_extra_price(gd, state)
    if WATCHDOG.wants_case("extra_options_stock"):
        _test_extra_options_stock(gd, city, state)
    if WATCHDOG.wants_case("popup_stock_refresh"):
        _test_popup_stock_refresh(city, state)
    if WATCHDOG.wants_case("quality_rule"):
        _test_quality_rule(gd, city, state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("CRAFT EXTRAS TEST FAILED")
        quit(1)
    else:
        print("CRAFT EXTRAS TEST OK")
        quit(0)


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true


# --- 1. The id of a generated good ---
func _test_id_roundtrip(gd, state: Dictionary) -> void:
    check(gd.parse_generated_id("gold_jewelry").is_empty(),
        "an id without the separator is not generated", state)

    var parsed: Dictionary = gd.parse_generated_id("gold_jewelry+lazurite_ore")
    check(str(parsed.get("base", "")) == "gold_jewelry", "the base is split off the id", state)
    check(str(parsed.get("extra", "")) == "lazurite_ore",
        "the addition is split off the id", state)

    check(gd.make_generated_id("gold_jewelry", "pearl") == "gold_jewelry+pearl",
        "the addition is the tail of the id", state)
    check(gd.make_generated_id("gold_jewelry", "") == "gold_jewelry",
        "no addition — the base id itself", state)
    check(gd.make_generated_id("gold_jewelry", "onyx") == "gold_jewelry",
        "an addition that does not exist is dropped", state)

    check(gd.parse_generated_id("gold_jewelry+onyx").is_empty(),
        "an unknown addition makes the id not generated", state)
    # A good carries ONE addition: "with lazurite and with pearl" does not exist.
    check(gd.parse_generated_id("gold_jewelry+pearl+lazurite_ore").is_empty(),
        "a second addition makes the id not generated", state)
    check(gd.parse_generated_id("+pearl").is_empty(), "an empty base is not generated", state)


# --- 2. The recipe built on the fly ---
func _test_recipe_built(gd, city, state: Dictionary) -> void:
    var base: Dictionary = gd.find_craft("gold_jewelry")
    check(not base.is_empty(), "the base recipe exists in the data", state)

    var recipe: Dictionary = gd.get_craft("gold_jewelry+lazurite_ore")
    check(not recipe.is_empty(), "the generated recipe is resolved", state)
    check(str(recipe.get("id", "")) == "gold_jewelry+lazurite_ore",
        "the generated recipe keeps the full id", state)
    check(is_equal_approx(float(recipe.get("time", 0.0)), float(base.get("time", 0.0))),
        "the addition does not change the time of the cycle", state)

    # The ingredients: the two of the base plus the stone, as three AND-terms.
    var groups: Array = gd.craft_alternatives(recipe)
    check(groups.size() == 3, "the base ingredients and the stone give three terms", state)
    var keys: Array = []
    for group in groups:
        for variant in group:
            keys.append(str(variant.get("key", "")))
    check("gold" in keys and "charcoal" in keys and "lazurite_ore" in keys,
        "the stone is an ordinary ingredient of the generated recipe", state)
    var amount := 0
    for variant in groups[2]:
        if str(variant.get("key", "")) == "lazurite_ore":
            amount = int(variant.get("amount", 0))
    check(amount == int(gd.craft_extras["lazurite_ore"].get("amount", 0)),
        "the stone is taken in the amount declared by the registry", state)

    # The result is the generated good, in the amount of the base.
    var result: Dictionary = recipe.get("result", {})
    check(result.has("gold_jewelry+lazurite_ore"),
        "the result is the generated good", state)
    check(int(result.get("gold_jewelry+lazurite_ore", 0)) == int(base["result"]["gold_jewelry"]),
        "the output amount is the one of the base recipe", state)

    check(str(recipe.get("name", "")) == "Gold Jewelry (+Lazurite)",
        "the name carries the addition in the nominative case: " + str(recipe.get("name", "")),
        state)

    # The recipe of a building slot is resolved by the same call, and the building accepts it.
    check(city.can_craft_in("gold_jewelry+lazurite_ore", "jeweler_house"),
        "a recipe with an addition is still craftable in the jeweler's house", state)
    check(not city.can_craft_in("gold_jewelry+lazurite_ore", "bakery"),
        "a recipe with an addition is not craftable in an unrelated building", state)


# --- 3. The generated good ---
func _test_product_materialised(gd, state: Dictionary) -> void:
    var pid := "gold_jewelry+lazurite_ore"
    gd.materialise_generated(pid)
    check(gd.products.has(pid), "the generated good is materialised", state)
    var good: Dictionary = gd.products.get(pid, {})
    var base: Dictionary = gd.products.get("gold_jewelry", {})
    check(str(good.get("category", "")) == str(base.get("category", "")),
        "the generated good inherits the category of the base", state)
    check(str(good.get("icon", "")) == str(base.get("icon", "")),
        "the generated good inherits the icon of the base", state)
    check(str(good.get("unlock_tech", "")) == str(base.get("unlock_tech", "")),
        "the generated good inherits the unlock technology of the base", state)

    # The price: the base and the addition at their own price, the addition being spent per
    # craft cycle, and the synergy coefficient over the sum.
    var batch := float(int(gd.find_craft("gold_jewelry")["result"]["gold_jewelry"]))
    var expected := float(base["price"])
    var record: Dictionary = gd.craft_extras["lazurite_ore"]
    expected += gd.get_base_price("lazurite_ore") * float(record["amount"]) / batch
    expected = round(expected * (1.0 + float(gd.game_balance.get("craft_extra_synergy", 0.0))))
    check(int(good.get("price", 0)) == int(expected),
        "the price is the sum of the parts and the synergy (expected %d, got %d)"
                % [int(expected), int(good.get("price", 0))], state)
    check(int(good.get("price", 0)) > int(base.get("price", 0)),
        "a good with an addition is worth more than the plain one", state)

    # The goods groups of the base are what the population and the trade address.
    var members: Array = gd.product_groups.get("jewelry", [])
    check("gold_jewelry" in members and pid in members,
        "the generated good joins the goods group of its base", state)
    check(int(gd.get_storage_amount("@jewelry", {pid: 5})) == 5,
        "the group amount counts the generated good", state)


# --- 4. A full cycle through the simulation ---
func _test_cycle(gd, city, state: Dictionary) -> void:
    var main_map := Node.new()
    main_map.name = "MainMap"
    get_root().add_child(main_map)
    var tm = load("res://scripts/townsfolk_manager.gd").new()
    tm.name = "TownsfolkManager"
    main_map.add_child(tm)

    var recipe_id := "gold_jewelry+lazurite_ore"
    city.city_built_buildings = [ {"id": "jeweler_house", "slots": [recipe_id], "quality_priority": "best"}]
    city.total_population = 1
    city.idle_population = 0
    tm.assigned_buildings = {"0": true}

    # gold_jewelry: 10 gold + 10 charcoal + 10 stones per 20 sec.
    city.city_storage.clear()
    city.add_to_storage("gold", 10, "common")
    city.add_to_storage("charcoal", 10, "common")
    city.add_to_storage("lazurite_ore", 10, "common")
    # A few ticks of margin: the fractional accumulators of the ingredients do not divide the
    # 20 seconds evenly (10 stones per cycle = 0.5 per tick).
    for _i in range(24):
        city.do_tick()

    check(int(city.get_storage_amount("gold")) == 0,
        "the metal of the base recipe is spent", state)
    check(int(city.get_storage_amount("lazurite_ore")) == 0,
        "the additional ingredient is spent", state)
    var pid := "gold_jewelry+lazurite_ore"
    check(int(city.get_storage_amount(pid)) == 10,
        "the cycle yields 10 generated goods (got %d)" % int(city.get_storage_amount(pid)), state)
    check(gd.products.has(pid),
        "the good that reached the storage has a record", state)

    # The plan of the building counts the addition as its demand: the Resources tab and the
    # "Consumes" section read the same numbers.
    var demand: Dictionary = city.get_building_planned_consumption()
    var by_source: Dictionary = demand.get("lazurite_ore", {})
    var planned := 0
    for source in by_source:
        planned += int(by_source[source].get("amount", 0))
    check(planned == 10,
        "the additional ingredient is part of the planned demand (got %d)" % planned, state)

    main_map.queue_free()


# --- 5. The quality of the result against the quality of the addition ---
# The addition is a minority of the mass (10 units of dye against 100 of wool), so a plain
# weighted average over everything would never move the level. The addition raises the base
# by ONE level at most, and never lowers it.
# The units keep BOTH levels apart — the base and the addition — because the price is the sum of
# the two parts, each at its own level; the level of the good itself is a reading of that pair.
func _test_quality_rule(gd, city, state: Dictionary) -> void:
    var main_map := Node.new()
    main_map.name = "MainMap"
    get_root().add_child(main_map)
    var tm = load("res://scripts/townsfolk_manager.gd").new()
    tm.name = "TownsfolkManager"
    main_map.add_child(tm)

    var pid: String = gd.make_generated_id("wool_clothes", "woad")
    city.city_built_buildings = [ {"id": "weaver_house", "slots": [pid], "quality_priority": "best"}]
    city.total_population = 1
    city.idle_population = 0
    tm.assigned_buildings = {"0": true}

    var cases := [
        ["common", "exceptional", "fine"],
        ["common", "common", "common"],
        ["exceptional", "common", "exceptional"],
        ["fine", "exceptional", "exceptional"],
        ["perfect", "perfect", "perfect"],
    ]
    for entry in cases:
        var got := _run_wool_cycle(city, pid, str(entry[0]), str(entry[1]))
        var levels: Dictionary = gd.quality_level_totals(got)
        check(levels == {str(entry[2]): 10},
            "wool %s + dye %s must give %s (got %s)"
                % [entry[0], entry[1], entry[2], str(levels)], state)
        var key: String = gd.make_quality_key(str(entry[0]), str(entry[1]))
        check(got.has(key),
            "the units must keep the levels of both parts (key \"%s\", got %s)" % [key, str(got)],
            state)

    main_map.queue_free()


# One full cycle of wool clothes with the given qualities of the base and the addition. The
# result is the breakdown by quality of what has reached the storage.
func _run_wool_cycle(city, pid: String, base_q: String, extra_q: String) -> Dictionary:
    city.city_storage.clear()
    city.city_quality_detail.clear()
    city.add_to_storage("wool", 20, base_q)
    city.add_to_storage("woad", 10, extra_q)
    for _i in range(6):
        city.do_tick()
    return city.city_quality_detail.get(pid, {}).duplicate()


# --- 6. The rebuild after a re-read of the data ---
func _test_rebuild(gd, city, state: Dictionary) -> void:
    var pid := "gold_jewelry+pearl"
    city.city_storage.clear()
    city.add_to_storage(pid, 4, "common")
    check(gd.products.has(pid), "the good is materialised on the way into the storage", state)

    # A re-read of the data rebuilds `products` from the files: the generated record is gone.
    gd.load_all_data()
    check(not gd.products.has(pid), "a re-read of the data drops the generated record", state)

    city.rebuild_generated_products()
    check(gd.products.has(pid), "the rebuild restores the record from the storage", state)
    var members: Array = gd.product_groups.get("jewelry", [])
    check(pid in members, "the rebuilt good is back in the goods group", state)


# --- 6. The price of a generated good against its base (the tooltip row) ---
# The row of the tooltips of the "Resources" and "Trade" tabs: " + = x1.30 = 26" — the same shape
# as the row of the quality ladder, and the plus of the addition in the name.
func _test_extra_price(gd, state: Dictionary) -> void:
    var base_pid := "wool_clothes"
    check(gd.format_extra_price_row(base_pid).is_empty(),
        "a plain good has nothing to explain about its price", state)

    var pid: String = gd.make_generated_id(base_pid, "woad")
    # The good has to exist before it has a price: the recipe is what materialises the record.
    gd.get_craft(pid)
    var row: Dictionary = gd.format_extra_price_row(pid)
    check(not row.is_empty(), "a good with an addition explains its price", state)
    check(str(row.get("glyph", "")) == "+", "the row carries the plus of the name", state)

    var price: float = gd.get_price_for_quality(pid, "")
    var ratio: float = price / gd.get_price(base_pid)
    check(ratio > 1.0,
        "a good with an addition must be dearer than the plain one (x%.2f)" % ratio, state)
    # The row quotes the two BASE prices, not the price of a level: the coefficient is the same at
    # every level, so a single price here would contradict the quality ladder above the row.
    var base_price: float = gd.get_price(base_pid)
    check(str(row.get("tail", "")) == " = x%.2f (%d → %d)" % [
            ratio, int(round(base_price)), int(round(price))],
        "the row shows the coefficient and both prices, got \"%s\""
            % str(row.get("tail", "")), state)
    check(str(row.get("text", "")) == "+" + str(row.get("tail", "")),
        "the row is glued from the glyph and the tail", state)

    # The coefficient follows the price of the addition — it is not a constant of the mechanic.
    var dearer: String = gd.make_generated_id(base_pid, "purple")
    gd.get_craft(dearer)
    check(gd.get_generated_price_multiplier(dearer) > gd.get_generated_price_multiplier(pid),
        "a dearer addition raises the coefficient", state)


# --- 7. The radio buttons follow the warehouse ---
# A good that is not in the warehouse cannot be picked: the cycle would only stall waiting for
# it. It stays in the list, so that the player sees what the recipe accepts and what is missing.
func _test_extra_options_stock(gd, city, state: Dictionary) -> void:
    var recipe_id := "wool_clothes"
    city.city_storage.clear()
    city.add_to_storage("woad", 5, "common")
    var options := _options_by_product(gd, recipe_id)
    check(options.has("woad"), "the recipe offers the good of its kind", state)
    check(int(options.get("woad", {}).get("in_stock", 0)) == 5,
        "the radio button carries the amount in the warehouse", state)
    check(bool(options.get("woad", {}).get("selectable", false)),
        "a good in the warehouse can be chosen", state)

    var other := ""
    for product_id in options:
        if str(product_id) != "woad":
            other = str(product_id)
            break
    check(other != "", "the recipe offers more than one good of the kind", state)
    check(int(options.get(other, {}).get("in_stock", -1)) == 0,
        "the other good is not in the warehouse", state)
    check(not bool(options.get(other, {}).get("selectable", true)),
        "a good that is not in the warehouse cannot be chosen", state)

    # The chosen addition stays clickable with an empty shelf: otherwise the player could not
    # take back a good that has run out and the slot would be stuck with it.
    city.city_storage.clear()
    var chosen_recipe: String = gd.make_generated_id(recipe_id, other)
    var chosen_options := _options_by_product(gd, chosen_recipe)
    check(int(chosen_options.get(other, {}).get("in_stock", -1)) == 0,
        "the chosen good has run out", state)
    check(bool(chosen_options.get(other, {}).get("selectable", false)),
        "the chosen good stays clickable so that the choice can be taken back", state)


# The items of all the kinds of a recipe by the product id — the shape the radio buttons are
# built from.
func _options_by_product(gd, recipe_id: String) -> Dictionary:
    var out := {}
    for group in gd.get_recipe_extra_options(recipe_id):
        for item in group.get("items", []):
            out[str(item["product"])] = item
    return out


# --- 9. The stock row of an open popup ---
# The window of the additions is built once and is not rebuilt on a tick (a rebuild would close
# it under the cursor), so the amounts of its radios are refreshed in place.
func _test_popup_stock_refresh(city, state: Dictionary) -> void:
    var panel = (load("res://scripts/building_panel.gd") as Script).new()
    # The radios of the panel are the ones the technology has opened.
    city.unlocked_technologies.append("dyeing")
    city.city_storage.clear()
    city.add_to_storage("woad", 5, "common")
    city.city_built_buildings = [ {"id": "weaver_house", "slots": ["wool_clothes"],
            "quality_priority": "best"}]

    var popup := PopupPanel.new()
    popup.set_meta("extras_slot", [0, 0])
    var radio = (load("res://scripts/extras_radio.gd") as Script).new()
    radio.set_meta("extra_product", "woad")
    popup.add_child(radio)
    panel.open_popup = popup

    panel._refresh_extras_popup()
    check(radio.tooltip_text == TranslationServer.translate("In storage: %d") % 5,
        "an open popup shows the amount in the warehouse, got \"%s\"" % radio.tooltip_text,
        state)
    check(not radio.disabled, "a good in the warehouse stays selectable", state)

    city.city_storage.clear()
    panel._refresh_extras_popup()
    check(radio.tooltip_text == TranslationServer.translate("Not in storage"),
        "the amount of an open popup follows the warehouse, got \"%s\"" % radio.tooltip_text,
        state)
    check(radio.disabled, "a good that has run out cannot be picked", state)

    # The chosen addition stays clickable with an empty shelf even after a refresh: otherwise
    # the choice could not be taken back.
    city.city_built_buildings[0]["slots"] = ["wool_clothes+woad"]
    panel._refresh_extras_popup()
    check(not radio.disabled,
        "the chosen good stays clickable after a refresh so that the choice can be taken back",
        state)

    panel.open_popup = null
    panel.free()
    popup.free()
