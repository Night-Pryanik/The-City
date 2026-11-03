# Headless test of the specializations of the city:
#   godot --headless --path . --script res://tests/test_specializations.gd
#
# Checks:
#   1. The data: the branches of data/specializations.json are well formed, every bonus type is a
#      type the code implements (an unknown one would silently give nothing), the thresholds are a
#      real progression, no branch hides itself from the player, and every identifier a branch
#      mentions exists.
#   2. The milestones: a pick is earned per reached threshold, and only the unspent ones are
#      pending.
#   3. The choice: there are no ranks — a branch is taken once, a repeated pick is refused, and a
#      branch whose predecessors are not chosen is not offered.
#   4. The availability: every branch of the data is either offered, taken or listed as unavailable —
#      the player can always read the whole list.
#   5. The bonuses: a bonus that names its improvements acts on those alone, a bonus that names none
#      acts on every improvement, and the wording names what the percentage scales.
#   6. The non-numeric effects: they are shown by the tab "Specialization" and never reach the
#      numeric list of the tab "Effects".
#   7. The building production: a working building of the city really produces more with the
#      industry branch — both in the planned output and in the units released by the tick.
#   8. The live scene: the tab of the city window offers the available branches and takes a pick
#      from there, keeps the unavailable ones under a disclosure; the choice window stops the
#      simulation, may be postponed without spending the pick, and spends it on confirm.
#
# The expectations are derived from the data (the ids, the values, the thresholds), never from the
# numbers of the file: a balance edit must not break the test.
extends SceneTree

# The hang watchdog — see tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# The bonus types the code implements (CityData, "THE SPECIALIZATIONS OF THE CITY").
const BONUS_TYPES := [
    "improvement_production", "building_production", "internal_market_price",
    "trade_sell_price", "trade_buy_price", "research_speed",
]

var _cdata = null
var _gdata = null
var _main_map = null

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state: Dictionary = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    _cdata = get_root().get_node("CityData")
    _gdata = get_root().get_node("GameData")
    # The autoloads join the tree on the first frame, and the lookups of the map go through
    # get_tree(): before that frame there is nothing to search in.
    await process_frame

    _test_data(state)
    _test_thresholds(state)
    _test_choice(state)
    _test_prerequisites(state)
    _test_bonuses(state)
    _test_effects(state)
    await _test_live(state)

    if state["failed"]:
        print("SPECIALIZATIONS TEST FAILED")
        quit(1)
    else:
        print("SPECIALIZATIONS TEST OK")
        quit(0)

# --- 1. The data ---

func _test_data(state: Dictionary) -> void:
    var thresholds: Array = _cdata.get_specialization_thresholds()
    check(not thresholds.is_empty(), "the data must declare at least one threshold", state)
    var ascending := true
    for i in range(1, thresholds.size()):
        if int(thresholds[i]) <= int(thresholds[i - 1]):
            ascending = false
    check(ascending, "the thresholds must be a strictly ascending list", state)

    var ids: Array = []
    for spec in _gdata.specializations:
        var id := str(spec.get("id", ""))
        check(not id.is_empty(), "every branch needs an id", state)
        check(not ids.has(id), "the id \"%s\" is declared twice" % id, state)
        ids.append(id)
        check(not str(spec.get("name", "")).is_empty(), "the branch \"%s\" has no name" % id, state)
        check(not str(spec.get("icon", "")).is_empty(), "the branch \"%s\" has no icon" % id, state)
        # An optional phrase of its own: it must say something the bare name does not.
        var full := str(spec.get("full_name", ""))
        if full != "":
            check(full != str(spec.get("name", "")),
                "the branch \"%s\" repeats its name as its full name" % id, state)
        # Nothing is withheld from the player: every branch is listed, available or not.
        check(not spec.has("hidden"),
            "the branch \"%s\" declares \"hidden\" — a branch is never withheld" % id, state)
        var bonuses: Array = spec.get("bonuses", [])
        check(not bonuses.is_empty(), "the branch \"%s\" gives nothing" % id, state)
        for bonus in bonuses:
            var type := str(bonus.get("type", ""))
            check(BONUS_TYPES.has(type),
                "the branch \"%s\" declares an unknown bonus type \"%s\"" % [id, type], state)
            check(absf(float(bonus.get("value", 0.0))) > 0.0,
                "the bonus \"%s\" of the branch \"%s\" is zero" % [type, id], state)
            for imp_id in bonus.get("improvements", []):
                check(_gdata.improvements.has(str(imp_id)),
                    "the branch \"%s\" names the improvement \"%s\", which does not exist"
                        % [id, str(imp_id)], state)

    # Every bonus type of the base game is given by some branch: a type nothing uses is a type the
    # code carries for nothing.
    for type in BONUS_TYPES:
        check(not _branch_with_type(type).is_empty(),
            "no branch gives \"%s\" — a bonus type of the base game is unused" % type, state)

    # The four branches of the base game are open from the start: nothing is chosen, and they still
    # have no predecessor and no condition to wait for.
    _reset_specs()
    var open_now: Array = _cdata.get_available_specializations()
    check(open_now.size() == 4,
        "exactly four branches must be available at the start (got %d: %s)"
            % [open_now.size(), str(open_now.map(func(b): return str(b.get("id", ""))))], state)

    # No field of the data mentions "hidden" — the wording of the file must not survive the model.
    var text := FileAccess.get_file_as_string("res://data/specializations.json")
    var compact := text.replace(" ", "").replace("\t", "")
    check(not compact.contains("\"hidden\""),
        "the data must not declare \"hidden\": a branch is available or unavailable", state)

# --- 2. The milestones ---

func _test_thresholds(state: Dictionary) -> void:
    var thresholds: Array = _cdata.get_specialization_thresholds()
    _reset_specs()

    _cdata.total_population = 1
    check(_cdata.get_specialization_picks_earned() == 0,
        "one citizen must not earn a pick", state)
    check(_cdata.get_pending_specialization_picks() == 0,
        "with nothing earned there is nothing pending", state)
    check(_cdata.get_next_specialization_threshold() == int(thresholds[0]),
        "the next milestone must be the first threshold", state)

    _cdata.total_population = int(thresholds[0])
    check(_cdata.get_specialization_picks_earned() == 1,
        "the first threshold must earn exactly one pick", state)
    check(_cdata.get_pending_specialization_picks() == 1,
        "an unspent earned pick must be pending", state)

    if thresholds.size() > 1:
        _cdata.total_population = int(thresholds[1])
        check(_cdata.get_specialization_picks_earned() == 2,
            "the second threshold must earn the second pick", state)
        if thresholds.size() > 2:
            check(_cdata.get_next_specialization_threshold() == int(thresholds[2]),
                "the next milestone must move past the reached thresholds", state)

    # A spent pick is no longer pending.
    _cdata.specialization_claimed = 1
    check(_cdata.get_pending_specialization_picks() == 1,
        "a spent pick must lower the pending count", state)
    _reset_specs()

# --- 3. The choice ---

func _test_choice(state: Dictionary) -> void:
    _reset_specs()
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[0])

    check(not _cdata.choose_specialization("no_such_branch"),
        "an unknown branch must not be chosen", state)

    var spec := _branch_with_type("improvement_production", true)
    var id := str(spec.get("id", ""))
    check(_cdata.choose_specialization(id), "a branch with a pending pick must be chosen", state)
    check(_cdata.is_specialization_chosen(id), "the chosen branch must be marked as chosen", state)
    check(_cdata.specialization_claimed == 1, "the pick must be spent", state)
    check(_cdata.get_pending_specialization_picks() == 0,
        "nothing must be pending after the only pick is spent", state)
    check(_cdata.get_chosen_specializations().size() == 1,
        "the city must have exactly one branch", state)

    # No ranks: a second pick of the same branch is impossible even with a pick in hand.
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[-1])
    check(_cdata.get_pending_specialization_picks() > 0,
        "the last threshold must leave picks to spend", state)
    check(not _cdata.choose_specialization(id),
        "a branch the city already has must not be chosen again", state)
    check(_cdata.get_chosen_specializations().size() == 1,
        "the refused pick must not add a branch", state)
    check(not _cdata.get_available_specializations().any(
            func(branch): return str(branch.get("id", "")) == id),
        "a chosen branch must not be offered again", state)

    # A branch is one pick: the picks of the city are limited by its branches.
    _reset_specs()

# --- 4. The prerequisites ---

func _test_prerequisites(state: Dictionary) -> void:
    _reset_specs()
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[-1])

    var gated: Array = []
    for spec in _gdata.specializations:
        var prerequisites: Array = spec.get("prerequisites", [])
        if prerequisites.is_empty():
            continue
        gated.append(spec)
        var id := str(spec.get("id", ""))
        check(not _cdata.is_specialization_available(spec),
            "the branch \"%s\" must be closed before its predecessors are chosen" % id, state)
        check(not _cdata.choose_specialization(id),
            "a branch with unmet prerequisites must not be chosen: \"%s\"" % id, state)
        check(not _cdata.get_available_specializations().any(
                func(branch): return str(branch.get("id", "")) == id),
            "a branch with unmet prerequisites must not be offered: \"%s\"" % id, state)
        check(not _cdata.get_specialization_prerequisites_text(spec).is_empty(),
            "the branch \"%s\" must name what it requires" % id, state)

        # Every predecessor of the branch, chosen one by one, opens it.
        for group in prerequisites:
            for required in (group if group is Array else [group]):
                if _cdata.is_specialization_chosen(str(required)):
                    continue
                check(_cdata.choose_specialization(str(required)),
                    "the predecessor \"%s\" must be chooseable" % str(required), state)
        check(_cdata.is_specialization_available(spec),
            "the branch \"%s\" must open once its predecessors are chosen" % id, state)
        check(_cdata.choose_specialization(id),
            "the branch \"%s\" must be chooseable once it is open" % id, state)
        _reset_specs()

    check(not gated.is_empty(), "the data must declare a branch with prerequisites", state)

    # An unknown condition type keeps the branch closed: a typo must not open what the author meant
    # to keep shut.
    var probe := {"id": "probe",
        "unlock": [{"type": "no_such_condition", "id": "x"}]}
    check(not _cdata.is_specialization_available(probe),
        "an unknown unlock condition must keep the branch closed", state)

    # Nothing is withheld: every branch of the data is either offered, taken or listed as
    # unavailable. A branch that falls out of all three is invisible to the player.
    _reset_specs()
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[-1])
    var available_ids: Array = _cdata.get_available_specializations().map(
            func(b): return str(b.get("id", "")))
    var locked_ids: Array = _cdata.get_locked_specializations().map(
            func(b): return str(b.get("id", "")))
    for spec in _gdata.specializations:
        var id := str(spec.get("id", ""))
        check(available_ids.has(id) or locked_ids.has(id),
            "the branch \"%s\" is neither available nor listed as unavailable — the player cannot "
                % id + "see it at all", state)
    # A branch with an unmet prerequisite is exactly what the disclosure holds.
    for spec in _gdata.specializations:
        if spec.get("prerequisites", []).is_empty():
            continue
        check(locked_ids.has(str(spec.get("id", ""))),
            "the branch \"%s\" waits for a predecessor and must be listed as unavailable"
                % str(spec.get("id", "")), state)
    _reset_specs()

# --- 5. The bonuses ---

func _test_bonuses(state: Dictionary) -> void:
    _reset_specs()
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[-1])

    var global_improvement := str(_branch_with_type("improvement_production", true).get("id", ""))
    var science := str(_branch_with_type("research_speed", true).get("id", ""))
    var domestic := str(_branch_with_type("internal_market_price", true).get("id", ""))
    var foreign := str(_branch_with_type("trade_sell_price").get("id", ""))
    var industry := str(_branch_with_type("building_production", true).get("id", ""))
    check(not domestic.is_empty(), "the data must declare a branch of the domestic market", state)
    check(not foreign.is_empty(), "the data must declare a branch of the foreign trade", state)

    # The value of a branch as the data declares it: the test reads it, it does not assume 10%.
    var global_step := _value_of(global_improvement, "improvement_production")
    check(_cdata.choose_specialization(global_improvement),
        "the branch of the improvements must be chooseable", state)
    check(is_equal_approx(_cdata.get_specialization_bonus("improvement_production"), global_step),
        "the share of the branch must be the value of the data", state)
    check(is_equal_approx(_cdata.get_specialization_multiplier("improvement_production"),
            1.0 + global_step),
        "the multiplier must be 1 + the share", state)

    # The improvement multiplier reaches the list the panel and the tooltip draw.
    var product := 1.0
    var labels: Array = []
    for mod in _cdata.get_improvement_production_modifiers("farm", false, "", "farm"):
        product *= float(mod.get("multiplier", 1.0))
        labels.append(str(mod.get("label", "")))
    check(is_equal_approx(product, _cdata.get_improvement_production_multiplier("farm", false,
            "", "farm")),
        "the total multiplier must be the product of the records", state)
    var named := false
    for label in labels:
        if label.contains(str(_cdata.get_specialization(global_improvement).get("name", ""))):
            named = true
    check(named, "the row of the improvement must name the branch that gives it", state)

    # A bonus that names its improvements acts on those alone.
    for spec in _gdata.specializations:
        var id := str(spec.get("id", ""))
        var targets := _targets_of(id)
        if targets.is_empty():
            continue
        check(_cdata.choose_specialization(id),
            "the branch \"%s\" must be chooseable for the measurement" % id, state)
        var step := _value_of(id, "improvement_production")
        for imp_id in targets:
            var share: float = _cdata.get_specialization_improvement_share(str(imp_id))
            check(is_equal_approx(share, global_step + step),
                "the improvement \"%s\" must carry both its own branch and the general one "
                % str(imp_id) + "(got %s, expected %s)" % [str(share), str(global_step + step)],
                state)
        # An improvement outside the list keeps only the general share.
        var outside: Array = []
        for imp_id in _gdata.improvements.keys():
            if targets.has(str(imp_id)):
                continue
            outside.append(str(imp_id))
            if outside.size() >= 2:
                break
        for other in outside:
            var share: float = _cdata.get_specialization_improvement_share(other)
            check(is_equal_approx(share, global_step),
                "the improvement \"%s\" must not carry the branch \"%s\" (got %s)"
                    % [other, id, str(share)], state)
        _reset_specs()
        check(_cdata.choose_specialization(global_improvement),
            "the branch of the improvements must stay chosen", state)

    # The wording names the quantity the percentage scales: a bare "+10%" says nothing about what
    # grows, and the player cannot tell a production branch from a price one.
    for type in BONUS_TYPES:
        var wording: String = _cdata.format_specialization_bonus(type, 0.1)
        check(wording.contains("+10%"),
            "the wording of \"%s\" must carry the amount (got \"%s\")" % [type, wording], state)
    check(_cdata.format_specialization_bonus("improvement_production", 0.1).contains("production"),
        "the wording of the improvements must say that the percentage is of the production", state)
    check(_cdata.format_specialization_bonus("building_production", 0.1).contains("production"),
        "the wording of the buildings must say that the percentage is of the production", state)
    check(_cdata.format_specialization_bonus("research_speed", 0.1).contains("speed"),
        "the wording of the science must say that the percentage is of the speed", state)
    for type in ["internal_market_price", "trade_sell_price", "trade_buy_price"]:
        check(_cdata.format_specialization_bonus(type, 0.1).contains("price"),
            "the wording of \"%s\" must say that the percentage is of the price" % type, state)
    # A branch that names its improvements still says what the percentage scales.
    var targeted: Array = []
    var targeted_id := ""
    for spec in _gdata.specializations:
        var own: Array = _targets_of(str(spec.get("id", "")))
        if not own.is_empty():
            targeted = own
            targeted_id = str(spec.get("id", ""))
            break
    check(not targeted_id.is_empty(),
        "the data must declare a branch with its own improvements", state)
    if not targeted.is_empty():
        var targeted_wording: String = _cdata.format_specialization_bonus(
                "improvement_production", 0.2, targeted)
        check(targeted_wording.contains("production"),
            "the wording of a branch with its own improvements must say \"production\"", state)

    # The full name of a branch: the word "specialization" is part of it wherever the branch is the
    # source of a bonus, otherwise a bare adjective says nothing.
    var full_name: String = _cdata.get_specialization_full_name(
            _cdata.get_specialization(global_improvement))
    check(full_name.contains("specialization"),
        "the full name of a branch must carry the word \"specialization\" (got \"%s\")" % full_name,
        state)
    check(full_name.contains(str(_cdata.get_specialization(global_improvement).get("name", ""))),
        "the full name of a branch must keep its name", state)
    # A branch may bring its own phrase: the word does not always follow the name.
    for spec in _gdata.specializations:
        var own := str(spec.get("full_name", ""))
        if own == "":
            continue
        check(_cdata.get_specialization_full_name(spec) == own,
            "the branch \"%s\" must be named by its own full name"
                % str(spec.get("id", "")), state)
    var rows_of_the_effects: Array = _cdata.get_city_effects()
    var sourced := false
    for effect in rows_of_the_effects:
        if str(effect.get("group", "")) == "specializations" \
                and str(effect.get("source", "")) == full_name:
            sourced = true
    check(sourced, "the tab \"Effects\" must name the branch in full", state)

    # The science rate is multiplied by its branch.
    _reset_specs()
    check(_cdata.choose_specialization(science), "the science branch must be chooseable", state)
    var science_step := _value_of(science, "research_speed")
    var expected_science: float = (_cdata.BASE_SCIENCE_PER_SEC
            + _cdata.science_buildings_rate_per_sec) * (1.0 + science_step)
    check(is_equal_approx(_cdata.get_science_rate_per_sec(), expected_science),
        "the rate of the science must carry the specialization (got %s, expected %s)"
            % [str(_cdata.get_science_rate_per_sec()), str(expected_science)], state)

    # The domestic market: the price the city gets for its goods on its own market rises.
    _reset_specs()
    var pid := _priced_product()
    check(not pid.is_empty(), "the data must have a priced product to measure the market with",
        state)
    if pid != "":
        var price_plain: int = _cdata.get_internal_market_price(pid)
        check(price_plain > 0, "a priced product must have a price on the internal market", state)
        check(_cdata.choose_specialization(domestic),
            "the domestic market branch must be chooseable", state)
        var domestic_step := _value_of(domestic, "internal_market_price")
        var base_price := float(_gdata.products.get(pid, {}).get("price", 0.0))
        var market_mult := float(
                _gdata.game_balance.get("internal_market_price_multiplier", 1.0))
        var market_base := int(round(base_price * market_mult * (1.0 + domestic_step)))
        var expected_price := int(round(
                float(market_base) * _gdata.get_quality_price_multiplier("")))
        check(_cdata.get_internal_market_price(pid) == expected_price,
            "the price of the internal market must carry the branch (got %d, expected %d)"
                % [_cdata.get_internal_market_price(pid), expected_price], state)
        check(_cdata.get_internal_market_price(pid) > price_plain,
            "the domestic market must raise the price of the goods (%d -> %d)"
                % [price_plain, _cdata.get_internal_market_price(pid)], state)
        # The domestic market does not touch the prices of the towns: that is the foreign trade.
        check(is_equal_approx(_cdata.get_specialization_multiplier("trade_sell_price"), 1.0),
            "the domestic market must not change what a town pays", state)
        check(is_equal_approx(_cdata.get_specialization_multiplier("trade_buy_price"), 1.0),
            "the domestic market must not change what the city pays a town", state)

    # The foreign trade: a development of the domestic market — the town pays more and asks less.
    _reset_specs()
    check(not _cdata.is_specialization_available(_cdata.get_specialization(foreign)),
        "the foreign trade must wait for the domestic market", state)
    check(not _cdata.choose_specialization(foreign),
        "the foreign trade must not be chosen before the domestic market", state)
    check(_cdata.choose_specialization(domestic),
        "the domestic market must be chooseable first", state)
    check(_cdata.is_specialization_available(_cdata.get_specialization(foreign)),
        "the domestic market must open the foreign trade", state)
    check(_cdata.choose_specialization(foreign), "the foreign trade must be chooseable", state)
    check(is_equal_approx(_cdata.get_specialization_multiplier("trade_sell_price"),
            1.0 + _value_of(foreign, "trade_sell_price")),
        "the sale price must be raised by the foreign trade", state)
    check(is_equal_approx(_cdata.get_specialization_multiplier("trade_buy_price"),
            1.0 + _value_of(foreign, "trade_buy_price")),
        "the purchase price must follow the foreign trade (a negative value lowers it)", state)
    check(_cdata.get_specialization_multiplier("trade_buy_price") < 1.0,
        "the foreign trade must make a purchase cheaper", state)

    # Several branches at once: each kind carries its own share and they do not bleed into each
    # other.
    _reset_specs()
    for id in [global_improvement, industry, domestic, science]:
        check(_cdata.choose_specialization(id), "the branch \"%s\" must be chooseable" % id, state)
    check(is_equal_approx(_cdata.get_specialization_multiplier("improvement_production"),
            1.0 + global_step),
        "the improvements must carry only their own branch", state)
    check(is_equal_approx(_cdata.get_specialization_multiplier("building_production"),
            1.0 + _value_of(industry, "building_production")),
        "the buildings must carry only their own branch", state)
    check(is_equal_approx(_cdata.get_specialization_multiplier("research_speed"),
            1.0 + _value_of(science, "research_speed")),
        "the science must carry only its own branch", state)
    check(is_equal_approx(_cdata.get_specialization_multiplier("internal_market_price"),
            1.0 + _value_of(domestic, "internal_market_price")),
        "the internal market must carry only its own branch", state)

    _reset_specs()

# The identifier of a product of the base data with a price and no additional ingredient: the price
# of the internal market of such a good is a plain product of the base price and the multipliers.
func _priced_product() -> String:
    for pid in _gdata.products:
        if not _gdata.parse_generated_id(str(pid)).is_empty():
            continue
        if float(_gdata.products[pid].get("price", 0.0)) > 0.0:
            return str(pid)
    return ""

# --- 6. The non-numeric effects ---

func _test_effects(state: Dictionary) -> void:
    _reset_specs()
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[-1])
    var spec := _branch_with_type("research_speed", true)
    var id := str(spec.get("id", ""))
    _cdata.choose_specialization(id)

    var rows: Array = []
    for effect in _cdata.get_city_effects():
        if str(effect.get("group", "")) == "specializations":
            rows.append(effect)
    check(not rows.is_empty(),
        "the numeric effects of the specialization must reach the tab \"Effects\"", state)
    var names_the_branch := false
    var full_name: String = _cdata.get_specialization_full_name(spec)
    for row in rows:
        check(not str(row.get("name", "")).is_empty(),
            "a row of the effects of the specialization has no wording", state)
        if str(row.get("source", "")) == full_name:
            names_the_branch = true
    check(names_the_branch, "the effects must name the branch they come from in full", state)

    # The non-numeric lines of the data are not among them: they belong to the tab "Specialization".
    var non_numeric: Array = _cdata.get_specialization_effects(spec)
    for line in non_numeric:
        for row in rows:
            check(str(row.get("name", "")) != str(line),
                "a non-numeric effect must not reach the numeric list", state)

    _reset_specs()

# --- 7. The building production ---

func _test_building_production(state: Dictionary) -> void:
    var pick := _pick_production_building()
    if pick.is_empty():
        print("SKIP: the data has no building recipe to measure the industry branch with")
        return
    var industry := str(_branch_with_type("building_production", true).get("id", ""))
    var step := _value_of(industry, "building_production")
    var townsfolk = _main_map.get_node("TownsfolkManager")

    _cdata.city_built_buildings = [
        {"id": pick["building"], "slots": [pick["recipe"]], "quality_priority": "best"},
    ]
    _cdata.idle_population = maxi(_cdata.idle_population, 2)
    townsfolk.assign_townsfolk(0)
    check(townsfolk.has_townsfolk(0), "a townsfolk must be assigned to the building", state)

    # The planned output: the recipe result scaled by the branch, the same number the "≈" of the
    # tab "Resources" shows.
    _reset_specs()
    var planned_plain := _planned_amount(str(pick["pid"]))
    _cdata.chosen_specialization_ids.append(industry)
    var planned_bonus := _planned_amount(str(pick["pid"]))
    check(planned_plain == int(pick["amount"]),
        "without the branch the plan must be the plain result of the recipe (got %d, expected %d)"
            % [planned_plain, int(pick["amount"])], state)
    check(planned_bonus > planned_plain,
        "the industry branch must raise the planned output (%d -> %d)"
            % [planned_plain, planned_bonus], state)

    # The units really released over one cycle of the recipe.
    _reset_specs()
    var plain := _released_over_cycle(pick)
    _cdata.chosen_specialization_ids.append(industry)
    var with_branch := _released_over_cycle(pick)
    var expected := float(pick["amount"]) * (1.0 + step)
    check(plain == int(pick["amount"]),
        "one cycle without the branch must give exactly the result of the recipe (got %d, expected %d)"
            % [plain, int(pick["amount"])], state)
    check(absf(float(with_branch) - expected) <= 1.0,
        "one cycle with the branch must give the result scaled by it (got %d, expected ~%d)"
            % [with_branch, int(round(expected))], state)
    check(with_branch > plain,
        "the industry branch must raise the units really released (%d -> %d)"
            % [plain, with_branch], state)

    _reset_specs()
    _cdata.city_built_buildings = []
    townsfolk.remove_townsfolk(0)

# Runs one cycle of the recipe of the building and returns how many units of the result arrived.
# The ingredients are filled with a margin, so a shortage never limits the cycle.
func _released_over_cycle(pick: Dictionary) -> int:
    _cdata.city_built_buildings = [
        {"id": pick["building"], "slots": [pick["recipe"]], "quality_priority": "best"},
    ]
    _cdata.city_storage[str(pick["pid"])] = 0
    _cdata.city_quality_detail[str(pick["pid"])] = {}
    _cdata.add_to_storage(str(pick["ingredient"]), int(pick["ingredient_amount"]) * 20)
    var ticks: int = maxi(1, int(round(float(pick["time"]))))
    for _i in range(ticks):
        _cdata.do_tick()
    return _cdata.get_storage_amount(str(pick["pid"]))

func _planned_amount(pid: String) -> int:
    var planned: Dictionary = _cdata.get_building_planned_production()
    var total := 0
    for source in planned.get(pid, {}):
        total += int(planned[pid][source].get("amount", 0))
    return total

# A recipe of a city building to measure the branch with: a single result, a single concrete
# ingredient and a whole number of seconds, so one cycle is a whole number of ticks. Everything is
# taken from the data — a balance edit only changes which recipe is picked.
func _pick_production_building() -> Dictionary:
    for recipe in _gdata.crafts:
        if not (recipe is Dictionary):
            continue
        var result: Dictionary = recipe.get("result", {})
        if result.size() != 1:
            continue
        var pid := str(result.keys()[0])
        var amount := int(result[pid])
        if amount < 8:
            continue
        var time := float(recipe.get("time", 0.0))
        if time <= 0.0 or not is_equal_approx(time, roundf(time)):
            continue
        var resources = recipe.get("resources", {})
        if not (resources is Dictionary) or resources.size() != 1:
            continue
        var ingredient := str(resources.keys()[0])
        if ingredient.begins_with("@"):
            continue
        var recipe_id := str(recipe.get("id", ""))
        for building in _gdata.buildings:
            var building_id := str(building.get("id", ""))
            if not _cdata.can_craft_in(recipe_id, building_id):
                continue
            return {
                "building": building_id,
                "recipe": recipe_id,
                "pid": pid,
                "amount": amount,
                "time": time,
                "ingredient": ingredient,
                "ingredient_amount": int(resources[ingredient]),
            }
    return {}

# --- 8. The live scene ---

func _test_live(state: Dictionary) -> void:
    _main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(_main_map)
    await process_frame
    await process_frame
    # CityData.setup() runs in the _ready of the map and resets the city to a new game.
    _cdata = get_root().get_node("CityData")
    _gdata = get_root().get_node("GameData")

    _test_building_production(state)

    var city_ui = _main_map.get_node_or_null("CityUI")
    check(city_ui != null, "CityUI not found in MainMap", state)
    if city_ui == null:
        return

    var tab_button = city_ui.get_node_or_null("TabBarPanel/TabBar/ReputationSpecializationButton")
    check(tab_button != null, "the tab button of the specialization is missing", state)
    check(city_ui.get_node_or_null("ContentPanel/SpecializationPanel") != null,
        "the panel of the specialization is missing", state)

    _reset_specs()
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[0])

    if tab_button != null:
        check(tab_button.icon != null, "the tab button does not carry an icon", state)
        tab_button.pressed.emit()
    check(city_ui.active_tab == "specialization",
        "the tab button did not switch to the specialization (got \"%s\")" % city_ui.active_tab,
        state)
    check(city_ui.specialization_panel.visible, "the specialization panel is not shown", state)
    await process_frame

    var tab = city_ui.specialization_tab
    check(tab != null, "the specialization tab script is not attached", state)
    if tab == null:
        return
    var list = city_ui.get_node_or_null(
        "ContentPanel/SpecializationPanel/Body/ScrollContainer/SpecializationList")
    check(list != null and list.get_child_count() > 0,
        "the list of the specialization is empty", state)
    if list == null:
        return

    # --- The dot on the tab button and the caption of the tab ---
    # open_city() runs the same full pass before it shows the window; the test asks for it directly,
    # because the city window is not necessarily on screen in a headless run.
    city_ui.refresh()
    var dot = city_ui.get_node_or_null("TabBarPanel/TabBar/ReputationSpecializationButton/PickDot")
    check(dot != null, "the tab button of the specialization carries no dot", state)
    if dot != null:
        check(dot.visible, "an unspent pick must show the dot on the tab button", state)
    check(tab.title_label != null, "the tab has no caption", state)
    if tab.title_label != null:
        var caption: String = tab.title_label.text
        check(caption.begins_with(tr("Specialization")),
            "the caption must start with the name of the tab (got \"%s\")" % caption, state)
        check(caption.contains(" | "),
            "the caption must separate its parts with a bar (got \"%s\")" % caption, state)
        check(caption.contains(tr("Unspent choices: %d")
                    % _cdata.get_pending_specialization_picks()),
            "the caption must carry the unspent picks (got \"%s\")" % caption, state)
        check(caption.contains(str(_cdata.get_next_specialization_threshold())),
            "the caption must carry the next milestone (got \"%s\")" % caption, state)

    # The tab offers the branches of the city, and a pick is taken right here.
    var available := _first_available(state)
    check(not available.is_empty(), "the tab must offer an available branch", state)
    if available.is_empty():
        return
    var text := _list_text(list)
    check(text.contains(str(available.get("name", ""))),
        "the tab does not name the available branch", state)
    check(text.contains(tr("Available")), "the tab does not mark the available branches", state)

    # An available branch is drawn in full colour: the muting belongs to the branches that cannot
    # be taken.
    var plain_plates := 0
    for child in list.get_children():
        if child is PanelContainer and is_equal_approx((child as Control).modulate.a, 1.0):
            plain_plates += 1
    check(plain_plates > 0, "an available branch must not be drawn muted", state)

    var choose_button := _find_button(list, tr("Choose"))
    check(choose_button != null, "the tab does not offer a button to take a branch", state)
    if choose_button != null:
        choose_button.pressed.emit()
        await process_frame
    check(_cdata.is_specialization_chosen(str(available.get("id", ""))),
        "the pick of the tab must choose the branch", state)
    check(_cdata.specialization_claimed == 1, "the pick of the tab must be spent", state)
    if dot != null:
        check(not dot.visible, "a spent pick must hide the dot of the tab button", state)
    # The window rebuilds itself on the signal of the pick; the test asks for the rebuild directly,
    # because the city window is not necessarily on screen in a headless run.
    tab.refresh()
    text = _list_text(list)
    check(text.contains(tr("Chosen")), "the tab does not mark the chosen branch", state)
    check(_find_button(list, tr("Choose")) == null or _cdata.get_pending_specialization_picks() > 0,
        "the tab must not offer a pick that cannot be spent", state)

    # --- The disclosure of the branches that cannot be taken yet ---
    # The player can always read the whole list of the specializations: the ones that cannot be
    # taken yet stand under a disclosure, collapsed by default.
    var locked: Array = _cdata.get_locked_specializations()
    check(not locked.is_empty(), "the data must have a branch the city cannot take yet", state)
    check(tab.locked_header != null,
        "the tab does not offer the disclosure of the unavailable branches", state)
    check(tab.locked_list != null, "the disclosure has no container", state)
    if tab.locked_header != null and tab.locked_list != null:
        check(tab.locked_header.text.contains(tr("Unavailable specializations")),
            "the toggle must be captioned (got \"%s\")" % tab.locked_header.text, state)
        check(tab.locked_header.text.contains(str(locked.size())),
            "the toggle must carry the number of the branches behind it", state)
        check(not tab.locked_open and not tab.locked_list.visible,
            "the unavailable branches must be collapsed by default", state)
        check(tab.locked_list.get_child_count() == locked.size(),
            "the disclosure must hold every unavailable branch (got %d, expected %d)"
                % [tab.locked_list.get_child_count(), locked.size()], state)
        # A branch that cannot be taken is drawn muted, so a mixed list reads at a glance.
        for child in tab.locked_list.get_children():
            if child is PanelContainer:
                check((child as Control).modulate.a < 1.0,
                    "the plate of an unavailable branch must be drawn muted", state)
        var locked_text := _list_text(tab.locked_list)
        for spec in locked:
            check(locked_text.contains(_cdata.get_specialization_full_name(spec)),
                "the disclosure must name the branch \"%s\"" % str(spec.get("id", "")), state)
        # A branch that waits for a predecessor names it, and names it in full.
        var waits_for := ""
        var predecessor := ""
        for spec in locked:
            var requirements: String = _cdata.get_specialization_prerequisites_text(spec)
            if requirements == "":
                continue
            waits_for = requirements
            var groups: Array = spec.get("prerequisites", [])
            if not groups.is_empty():
                var first = groups[0]
                predecessor = str(first[0] if first is Array else first)
            break
        if waits_for != "":
            check(locked_text.contains(waits_for),
                "the plate of an unavailable branch must name what it waits for", state)
            if predecessor != "":
                var expected_requirement: String = _cdata.get_specialization_full_name(
                        _cdata.get_specialization(predecessor))
                check(waits_for.contains(expected_requirement),
                    "a prerequisite must be named in full — expected \"%s\", got \"%s\""
                        % [expected_requirement, waits_for], state)
        tab.locked_header.button_pressed = true
        tab.locked_header.toggled.emit(true)
        check(tab.locked_list.visible, "the toggle must unfold the unavailable branches", state)
        # The unfolded state survives the rebuild of the list, as it does on the tab "Trade".
        tab.refresh()
        check(tab.locked_open and tab.locked_list != null and tab.locked_list.visible,
            "the unfolded state must survive the rebuild of the list", state)
        if tab.locked_header != null and tab.locked_list != null:
            tab.locked_header.button_pressed = false
            tab.locked_header.toggled.emit(false)
            check(not tab.locked_list.visible, "a repeated click must fold them again", state)

    # --- The choice window ---
    _reset_specs()
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[0])
    var popup = _main_map.get_node_or_null("SpecializationPopup")
    check(popup != null, "the choice window was not created", state)
    if popup == null:
        return

    _cdata.check_specialization_choice()
    await process_frame
    check(popup.visible, "the choice window must open on an unspent pick", state)
    check(paused, "the choice window must stop the simulation", state)

    # A postponed choice closes the window and keeps the pick.
    popup._on_postpone_pressed()
    await process_frame
    check(not popup.visible, "the postponed choice must close the window", state)
    check(not paused, "the postponed choice must resume the simulation", state)
    check(_cdata.get_pending_specialization_picks() == 1,
        "the postponed choice must keep the pick", state)
    check(_cdata.chosen_specialization_ids.is_empty(),
        "the postponed choice must not choose a branch", state)

    # The tab takes the postponed pick.
    tab.refresh()
    check(_find_button(list, tr("Choose")) != null,
        "the tab must offer the postponed pick", state)

    # A pick from the window: the branch is chosen and the world resumes.
    popup.open()
    await process_frame
    check(popup.visible, "the window must open again for the postponed pick", state)
    popup._selected_id = str(available.get("id", ""))
    popup._on_confirm_pressed()
    await process_frame
    check(_cdata.is_specialization_chosen(str(available.get("id", ""))),
        "the pick of the window must choose the branch", state)
    check(not popup.visible, "the window must close after the last unspent pick", state)
    check(not paused, "the window must resume the simulation", state)

    _main_map.queue_free()
    await process_frame

# The first branch the city may take right now.
func _first_available(state: Dictionary) -> Dictionary:
    var available: Array = _cdata.get_available_specializations()
    check(not available.is_empty(), "the city must have a branch to take", state)
    return available[0] if not available.is_empty() else {}

# The first button of a list with the given caption.
func _find_button(list: Node, caption: String) -> Button:
    for child in list.get_children():
        var found := _find_button_in(child, caption)
        if found != null:
            return found
    return null

func _find_button_in(node: Node, caption: String) -> Button:
    if node is Button and str((node as Button).text) == caption:
        return node as Button
    for child in node.get_children():
        var found := _find_button_in(child, caption)
        if found != null:
            return found
    return null

# The text of every label of a list, joined: the checks read the list as the player does.
func _list_text(list: Node) -> String:
    var parts: Array = []
    for child in list.get_children():
        _collect_text(child, parts)
    return " ".join(parts)

func _collect_text(node: Node, parts: Array) -> void:
    if node is Label:
        parts.append(str((node as Label).text))
    elif node is RichTextLabel:
        parts.append(str((node as RichTextLabel).get_parsed_text()))
    for child in node.get_children():
        _collect_text(child, parts)

# --- The helpers of the data ---

# The first branch that gives the type. With open_only the search is limited to the branches that
# need no predecessor — the ones the test can rely on at the start of a game.
func _branch_with_type(type: String, open_only: bool = false) -> Dictionary:
    for spec in _gdata.specializations:
        if open_only and not spec.get("prerequisites", []).is_empty():
            continue
        for bonus in spec.get("bonuses", []):
            if str(bonus.get("type", "")) == type:
                return spec
    return {}

func _value_of(branch_id: String, type: String) -> float:
    for bonus in _cdata.get_specialization(branch_id).get("bonuses", []):
        if str(bonus.get("type", "")) == type:
            return float(bonus.get("value", 0.0))
    return 0.0

# The improvements a branch names for its production bonus.
func _targets_of(branch_id: String) -> Array:
    for bonus in _cdata.get_specialization(branch_id).get("bonuses", []):
        if str(bonus.get("type", "")) != "improvement_production":
            continue
        var targets = bonus.get("improvements", [])
        if targets is Array and not targets.is_empty():
            return targets
    return []

func _reset_specs() -> void:
    _cdata.chosen_specialization_ids.clear()
    _cdata.specialization_claimed = 0

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("OK: ", message)
    else:
        state["failed"] = true
        push_error("FALL: " + message)
