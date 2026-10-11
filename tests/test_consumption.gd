# Temporary smoke test for the consumption system (headless):
#   godot --headless --path . --script res://tests/test_consumption.gd
# Checks: loading of data/consumption.json, resolution of the "@boats" group,
# deduplication and greedy deduction from the group. After checking, the file can be deleted.
extends SceneTree

# Hang watchdog: without it, a broken _run() coroutine looks like eternal
# silence from the outside. See tests/watchdog.gd for details.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    var state = {"failed": false}

    var gd = load("res://scripts/GameData.gd").new()
    gd.load_all_data()

    # 1) The registry is loaded and every rule from data/consumption.json is parsed.
    #    The exact number of rules is NOT hardcoded: the registry is extended with data
    #    (for example, the "scholar's feathers" rule), and the number itself must not break
    #    the test. Invariants are checked: the registry is non-empty, every rule has a
    #    resource, a profession list and positive amount/interval, and the resource
    #    resolves — a single product or a @-group from product_groups.json.
    check(not gd.consumption_rules.is_empty(), "consumption registry was not loaded", state)
    for rule in gd.consumption_rules:
        var res_key := str(rule.get("resource", ""))
        check(not res_key.is_empty(), "consumption rule without a resource field: %s" % str(rule), state)
        check(not rule.get("profession", []).is_empty(), "rule %s without a profession field" % res_key, state)
        check(int(rule.get("amount", 0)) > 0, "rule %s has amount <= 0" % res_key, state)
        check(float(rule.get("interval", 0.0)) > 0.0, "rule %s has interval <= 0" % res_key, state)
        if res_key.begins_with("@"):
            check(not gd.product_groups.get(res_key.substr(1), []).is_empty(),
                "group %s from consumption.json not found in product_groups.json" % res_key, state)
        else:
            check(gd.products.has(res_key), "product %s from consumption.json not found in products" % res_key, state)

    # 2) Fisherman's consumption — a group entry "@boats"
    var cons = gd.get_profession_consumption("fisherman")
    check(cons.size() == 1, "expected 1 entry for fisherman, got: %d" % cons.size(), state)
    if cons.size() == 1:
        var e = cons[0]
        check(e.get("is_group", false) == true, "entry is not a group", state)
        check(e.get("display_key", "") == "@boats", "display_key != @boats", state)
        # The group name is compared against the product_group_names registry itself, not
        # against the Russian word: the label is translated when data is loaded
        # (data_loader._localize_display_fields), and in this headless run
        # it may equally come back Russian or English — depending on
        # the language in the settings. We check what matters: the label is taken from
        # the data, not assembled from the identifier.
        var boats_name: String = str(gd.product_group_names.get("boats", ""))
        check(not boats_name.is_empty(), "the boats group must have a name", state)
        check(boats_name != "boats", "the group name must not match its id", state)
        check(e.get("product_name", "") == boats_name,
            "the @boats name was not taken from the registry: %s" % str(e.get("product_name", "")), state)
        # The group composition is also a matter of data: the author may extend it,
        # so we compare against product_groups, and check each member as
        # an existing product — otherwise a group with a "ghost" id would pass silently.
        var boats_members: Array = gd.product_groups.get("boats", [])
        check(not boats_members.is_empty(), "the boats group must not be empty", state)
        check(e.get("group_members", []) == boats_members,
            "the @boats members were not taken from the registry: %s" % str(e.get("group_members", [])), state)
        for member_id in boats_members:
            check(gd.products.has(str(member_id)),
                "the @boats member \"%s\" must be a product" % member_id, state)
        check(e.get("icon", "") == "reed_boat.png", "the group icon is wrong", state)
        # amount/interval are balance numbers from data/consumption.json, so
        # we compare them against the registry rule itself, not against a constant in the test. That way
        # the test still catches loss/substitution of fields when parsing an entry, but
        # does not break when the balance is edited.
        var rule_boats := _rule_for(gd.consumption_rules, "@boats", "fisherman")
        check(not rule_boats.is_empty(), "no @boats rule for fisherman in the registry", state)
        if not rule_boats.is_empty():
            check(int(e.get("amount", -1)) == int(rule_boats.get("amount", -2)),
                "@boats amount lost when parsing the rule: %s" % str(e.get("amount", null)), state)
            check(abs(float(e.get("interval", -1.0)) - float(rule_boats.get("interval", -2.0))) < 0.01,
                "@boats interval lost when parsing the rule: %s" % str(e.get("interval", null)), state)

    # 3) Duplicates: after moving the boat to the registry, the product must not
    #    be duplicated (reed_boat no longer has a consumption field)
    check(gd.products.get("reed_boat", {}).has("consumption") == false,
        "reed_boat must not have a consumption field", state)

    # 4) Consumption summary
    var summary = gd.get_profession_consumption_summary("fisherman")
    check(summary.has("@boats"), "@boats is missing from the summary", state)

    # 5) Greedy deduction from the group (logic as in tick_consumption)
    var cd = load("res://scripts/CityData.gd").new()
    cd.city_storage = {"reed_boat": 0}
    cd.city_quality_detail = {}
    cd.add_to_storage("reed_boat", 1, "common")
    # From the boats group (only reed_boat) we deduct amount=1
    var members = ["reed_boat"]
    var remaining = 1
    for pid in members:
        if remaining <= 0:
            break
        var avail = cd.get_storage_amount(pid)
        if avail <= 0:
            continue
        var take = min(avail, remaining)
        cd.remove_from_storage(pid, take, "best")
        remaining -= take
    check(remaining == 0, "deduction from the group did not happen", state)
    check(cd.get_storage_amount("reed_boat") == 0, "storage was not zeroed", state)

    # 6) Unavailability: group not found -> the entry is skipped
    var bad = gd._build_consumption_entry("@nonexistent_group", {"amount": 1})
    check(bad.is_empty(), "a non-existent group must be skipped", state)

    # 7) Pseudo-profession "all" (all city citizens): a group entry "@fruits"
    check(gd.professions.has("all"), "professions.json has no pseudo-profession all", state)
    check(gd.professions.get("all", {}).get("pseudo", false) == true, "all is not marked pseudo", state)
    var cons_all = gd.get_profession_consumption("all")
    # How many entries "All Citizens" has is a matter of DATA, not a test constant:
    # the registry has several (@fruits and @alcohol), and adding a new group
    # must not break the test. The check is >= 1 rather than size() == 1, so that
    # a second entry does not fail the test even though the parsing is correct.
    check(cons_all.size() >= 1,
        "the all pseudo-profession must have at least one resource, got: %d" % cons_all.size(), state)
    # We check the SPECIFIC @fruits group inside the list, not the first element:
    # the order of entries is not defined and changes with the balance.
    var ea: Dictionary = {}
    for entry in cons_all:
        if str(entry.get("display_key", "")) == "@fruits":
            ea = entry
            break
    check(not ea.is_empty(), "the \"All Citizens\" consumption has no @fruits entry", state)
    if not ea.is_empty():
        check(ea.get("is_group", false) == true, "the all entry is not a group", state)
        check(ea.get("display_key", "") == "@fruits", "display_key != @fruits", state)
        # As above: the group name comes from the registry, not a word hardcoded in the test.
        var fruits_name: String = str(gd.product_group_names.get("fruits", ""))
        check(not fruits_name.is_empty(), "the fruits group must have a name", state)
        check(ea.get("product_name", "") == fruits_name,
            "the @fruits name was not taken from the registry: %s" % str(ea.get("product_name", "")), state)
        # The group composition is a matter of DATA (the author extends it with fruits), so
        # we compare it against product_groups.json. A meaningful invariant
        # follows: grapes and olives remain in the group — the city consumption check
        # below is built on them, and without them there is nothing to deduct.
        var fruits_members: Array = gd.product_groups.get("fruits", [])
        check(ea.get("group_members", []) == fruits_members,
            "the @fruits members were not taken from the registry: %s" % str(ea.get("group_members", [])), state)
        for required_id in ["grapes", "olives"]:
            check(required_id in fruits_members,
                "@fruits must still contain %s" % required_id, state)
        # As above — amount/interval are compared against the registry rule itself.
        var rule_all := _rule_for(gd.consumption_rules, "@fruits", "all")
        check(not rule_all.is_empty(), "no @fruits rule for all in the registry", state)
        if not rule_all.is_empty():
            check(int(ea.get("amount", -1)) == int(rule_all.get("amount", -2)),
                "all amount lost when parsing the rule: %s" % str(ea.get("amount", null)), state)
            check(abs(float(ea.get("interval", -1.0)) - float(rule_all.get("interval", -2.0))) < 0.01,
                "all interval lost when parsing the rule: %s" % str(ea.get("interval", null)), state)

    # 8) City consumption "all": deduction is PER CAPITA (amount * population)
    #    ON ACTUAL AVAILABILITY, without waiting for full coverage. Greedy filling from
    #    the group members. Autoload names (CityData/GameData)
    #    cannot be used in this script — it is compiled BEFORE they are registered,
    #    so we take the singletons through the scene tree.
    var city = get_root().get_node("CityData") # relative path: absolute is forbidden in --script mode
    var gdata = get_root().get_node("GameData")
    # The GameData autoload did not load the data — we hand it the already loaded
    # registries (test gd.load_all_data() loaded them into a separate instance).
    gdata.consumption_rules = gd.consumption_rules
    gdata.product_groups = gd.product_groups
    gdata.product_group_names = gd.product_group_names
    gdata.products = gd.products
    gdata.professions = gd.professions
    gdata.game_balance = gd.game_balance
    var wm = load("res://scripts/worker_manager.gd").new()
    city.total_population = 3 # same population; amount grew tenfold
    # 3 citizens * 10 fruits = 30 per attempt. Storage has 40 (20 grapes +
    # 20 olives): exactly 30 is deducted, greedily from the group members.
    city.add_to_storage("grapes", 20, "common")
    city.add_to_storage("olives", 20, "common")
    # Expected treasury income per unit: round(price * multiplier from game_balance).
    var market_mult := float(gdata.game_balance.get("internal_market_price_multiplier", 0.25))
    var coin_g := int(round(float(gdata.products.get("grapes", {}).get("price", 0)) * market_mult))
    var coin_o := int(round(float(gdata.products.get("olives", {}).get("price", 0)) * market_mult))
    wm.tick_city_consumption(10.0)
    check(city.get_storage_amount("grapes") == 0, "grapes were not deducted by city consumption", state)
    check(city.get_storage_amount("olives") == 10, "olives deducted incorrectly (expected remainder 10)", state)
    check(city.treasury == 20 * coin_g + 10 * coin_o, "treasury income for the deduction is wrong: %d" % city.treasury, state)
    # Partial deduction based on availability: remainder 10 < 30 — everything is deducted,
    # the timer resets (we do not wait to accumulate the full 30).
    wm.tick_city_consumption(10.0)
    check(city.get_storage_amount("olives") == 0, "partial deduction did not work (expected 0 olives)", state)
    check(city.treasury == 20 * coin_g + 20 * coin_o, "treasury income for the partial deduction is wrong: %d" % city.treasury, state)
    # Empty storage: no deduction (the timer is preserved).
    wm.tick_city_consumption(10.0)
    check(city.treasury == 20 * coin_g + 20 * coin_o, "there must be no deduction/income on empty storage", state)
    # 1 fruit appeared — it is deducted immediately, without waiting for the full interval.
    city.add_to_storage("olives", 1, "common")
    wm.tick_city_consumption(10.0)
    check(city.get_storage_amount("olives") == 0, "the newly appeared fruit was not deducted immediately", state)
    check(city.treasury == 20 * coin_g + 20 * coin_o + coin_o, "treasury income for 1 fruit is wrong: %d" % city.treasury, state)
    # The timer is serialized/restored. We look for @fruits among the timers rather
    # than requiring exactly one: "All Citizens" has several resources (@fruits and
    # @alcohol), each with its own timer. A "exactly one timer" check
    # would break when any new group is added to the registry.
    var ser = wm.serialize_city_consumption_timers()
    var has_fruits_timer := false
    for item in ser:
        if str(item.get("resource", "")) == "@fruits":
            has_fruits_timer = true
            break
    check(has_fruits_timer, "the all timer is not serialized: %s" % str(ser), state)
    var wm2 = load("res://scripts/worker_manager.gd").new()
    wm2.load_city_consumption_timers(ser)
    check(wm2.city_consumption_timers.has("@fruits"), "the all timer is not restored", state)
    wm.free()
    wm2.free()

    if state["failed"]:
        print("SMOKE TEST FAILED")
        quit(1)
    else:
        print("SMOKE TEST OK")
        quit(0)

# The first consumption.json registry rule for a (resource, profession) pair.
# Needed to compare balance amount/interval against the data source, not
# against a constant inside the test: the balance in json changes, the test does not.
func _rule_for(rules: Array, res_key: String, prof_id: String) -> Dictionary:
    for r in rules:
        if str(r.get("resource", "")) == res_key and (prof_id in r.get("profession", [])):
            return r
    return {}

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
