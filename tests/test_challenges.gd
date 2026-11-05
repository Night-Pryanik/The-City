# Headless test of the fame of a good and the challenges of the era:
#   godot --headless --path . --script res://tests/test_challenges.gd
#
# Checks:
#   1. The data: the tiers of a good form an ascending ladder over one counter, every trigger and
#      every reward type is one the code implements, a prestige good is a good of its own that
#      points back at the base one, and every identifier a branch or a recipe borrows exists.
#   2. The counters: a sale is booked by quality, "min_quality" narrows the ladder rung to that
#      level and above, "produce" and "sell" are different counters, and an unknown trigger counts
#      nothing instead of guessing.
#   3. The ladder: every rung is paid once, a big sale pays the rungs it crossed all at once, and
#      the reward of a rung arrives — the price of the good, the recipe of the prestige one, the
#      specialization branch.
#   4. The picks: a challenge whose reward is a specialization gives one choice, a challenge that
#      gives anything else gives none, and the choices of the milestones stay untouched.
#   5. The gates: the recipe of a prestige good is closed before its rung and open after it, and
#      the branch stands in the list of the unavailable ones with the reason it waits.
#   6. The save: the counters, the rungs paid and the price of the fame come back from the record
#      the manager writes.
#   7. The tasks of the era: the window of the era is judged when it closes, the free claiming of
#      the new Region is not a purchase, and a task of another era is not offered.
#   8. The live scene: the tab of the city window opens and lists both the tasks and the ladder.
#
# The expectations are derived from the data (the thresholds, the rewards, the goods), never from
# the numbers of the file: a balance edit must not break the test.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The good the ladder is walked on. Any good with the three rungs would do; the test reads the
# thresholds from its record instead of assuming them.
const LADDER_GOOD := "cheese"

# The ways a tier counts a good (ChallengeManager.TRIGGER_SELL / TRIGGER_PRODUCE).
const TRIGGERS := ["sell", "produce"]

# The rewards the code applies (see ChallengeManager.apply_reward).
const REWARDS := ["trade_price", "brand_product", "specialization", "effect_stub"]

var _cdata = null
var _gdata = null
var _main_map = null
var _mgr = null

# The tiers the manager announced, collected through its signal.
var _events: Array = []

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state: Dictionary = {"failed": false}
    _main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(_main_map)
    # CityData.setup() runs in the _ready of the map and resets the city to a new game; the
    # autoloads join the tree on the first frame.
    await process_frame
    await process_frame
    _cdata = get_root().get_node("CityData")
    _gdata = get_root().get_node("GameData")
    _mgr = _main_map.get("challenge_manager")

    if _mgr == null:
        push_error("FALL: the map carries no challenge manager")
        print("CHALLENGES TEST FAILED")
        quit(1)
        return
    _mgr.fame_tier_completed.connect(
            func(tier_id: String, tier: String, _reward: Dictionary):
                _events.append([tier_id, tier]))

    _test_data(state)
    _test_counters(state)
    _test_ladder(state)
    _test_picks(state)
    _test_gates(state)
    _test_save(state)
    await _test_era(state)
    await _test_tab(state)

    if state["failed"]:
        print("CHALLENGES TEST FAILED")
        quit(1)
    else:
        print("CHALLENGES TEST OK")
        quit(0)

# --- 1. THE DATA ---

func _test_data(state: Dictionary) -> void:
    var ladders := 0
    for pid in _gdata.products:
        var product: Dictionary = _gdata.products[pid]
        var blocks := _tiers(product)
        if blocks.is_empty():
            continue
        ladders += 1
        var previous := 0
        for tier in _mgr.TIERS:
            if not blocks.has(tier):
                continue
            var block: Dictionary = blocks[tier]
            var threshold := int(block.get("threshold", 0))
            check(threshold > 0, "%s: the rung %s must name a positive threshold" % [pid, tier],
                    state)
            # The rungs share one counter, so a ladder whose rung asks for less than the one below
            # it would be paid before the player ever heard of it.
            check(threshold >= previous,
                    "%s: the rung %s must not ask for less than the rung below it" % [pid, tier],
                    state)
            previous = threshold
            check(TRIGGERS.has(str(block.get("trigger", "sell"))),
                    "%s: the rung %s counts a trigger the code does not implement" % [pid, tier],
                    state)
            for reward in _mgr.rewards_of(block):
                check(REWARDS.has(str(reward.get("type", ""))),
                        "%s: the rung %s rewards a type the code does not apply" % [pid, tier],
                        state)
                if str(reward.get("type", "")) == _mgr.REWARD_BRAND_PRODUCT:
                    _check_brand_product(state, pid, str(reward.get("product", "")))
                if str(reward.get("type", "")) == _mgr.REWARD_SPECIALIZATION:
                    check(not _cdata.get_specialization(str(reward.get("id", ""))).is_empty(),
                            "%s: the rung %s rewards an unknown specialization" % [pid, tier], state)
    check(ladders >= 1, "at least one good must carry the ladder of the fame", state)

    check(not _gdata.challenges.is_empty(), "data/challenges.json declares no era challenge", state)
    for record in _gdata.challenges:
        if not (record is Dictionary):
            continue
        var id := str(record.get("id", ""))
        check(_mgr.KNOWN_CONDITIONS.has(str(record.get("condition", ""))),
                "the era challenge %s names a condition the code does not check" % id, state)
        check(record.has("reward"), "the era challenge %s rewards nothing" % id, state)
        check(str(record.get("name", "")) != "", "the era challenge %s is unnamed" % id, state)

    # A prestige branch is opened by a rung of the fame; the reference is the only way the player
    # can ever take it.
    for spec in _gdata.specializations:
        var unlock = spec.get("unlock", null)
        var conditions: Array = [] if unlock == null else (
            [unlock] if unlock is Dictionary else (unlock if unlock is Array else []))
        for condition in conditions:
            if not (condition is Dictionary):
                continue
            if str(condition.get("type", "")) != "challenge":
                continue
            check(not _mgr.fame_record_of(str(condition.get("id", ""))).is_empty(),
                    "the specialization %s waits for a challenge no good declares"
                            % str(spec.get("id", "")), state)

const _KNOWN_REWARDS := ["trade_price", "brand_product", "specialization", "effect_stub"]

# The three rungs of a good, in the order of the ladder.
func _tiers(product: Dictionary) -> Dictionary:
    var out := {}
    for tier in _mgr.TIERS:
        var block = product.get(tier, null)
        if block is Dictionary:
            out[tier] = block
    return out

func _check_brand_product(state: Dictionary, pid: String, brand_id: String) -> void:
    var brand: Dictionary = _gdata.products.get(brand_id, {})
    check(not brand.is_empty(), "the prestige good %s of %s is not declared" % [brand_id, pid],
            state)
    if brand.is_empty():
        return
    # The prestige good is a good of its own, not a grade of the base one: what ties it to the
    # ladder is the reference back, and the name the city puts on it. The rung of the fame may stand
    # on another good of the same line — the fame of the steel is the fame of the blade, while the
    # brand the city earns is the bar the blade is forged of — so the brand is judged against the
    # good it names, not against the good of the rung.
    var base := str(brand.get("brand_of", ""))
    check(not base.is_empty() and _gdata.products.has(base),
            "the prestige good %s must be the brand of a declared good (names \"%s\")"
                    % [brand_id, base], state)
    if base.is_empty():
        return
    check(float(brand.get("price", 0.0)) > float(_gdata.products[base].get("price", 0.0)),
            "the prestige good %s must be dearer than the good it is made of" % brand_id, state)

    # The name of a brand is composed from the good and the city, and it stands without brackets: a
    # brand is read as a name of the good, the way «пармская» is, not as a qualification in
    # parentheses. The wording of the phrase belongs to the catalog, so what is judged here is the
    # structure — the good, the city, and no brackets — in whatever language the run speaks. The
    # record keeps a name of its own for the moments the city has none (the menu, a detached mod
    # probe), and that name is the fallback, not the label of the running game.
    var saved_city := str(_cdata.city_name)
    _cdata.city_name = "Testfeld"
    var base_name := str(_gdata.get_product_name(base))
    var shown := str(_gdata.get_good_display_name(brand_id))
    check(shown.contains("Testfeld") and shown.contains(base_name),
            "the prestige good %s must be shown by its base good and by the city: %s"
                    % [brand_id, shown], state)
    check(not shown.contains("(") and not shown.contains(")"),
            "the name of a brand carries no brackets: %s" % shown, state)
    var recipe := _craft_of(brand_id)
    if not recipe.is_empty():
        check(_gdata.get_craft_display_name(recipe) == shown,
                "the row of the building must carry the name of the brand, not the name of the " +
                "workshop: %s" % str(recipe.get("name", "")), state)
    _cdata.city_name = ""
    check(str(_gdata.get_good_display_name(brand_id)) == str(_gdata.get_product_name(brand_id)),
            "without a name of the city the prestige good must fall back to the name of its record",
            state)
    _cdata.city_name = saved_city

# --- 2. THE COUNTERS ---

func _test_counters(state: Dictionary) -> void:
    _reset_all()
    var product: Dictionary = _gdata.products[LADDER_GOOD]
    var reputation: Dictionary = product["reputation"]
    var brand: Dictionary = product["brand"]

    _mgr.record_sale(LADDER_GOOD, {"common": 40})
    _mgr.record_sale(LADDER_GOOD, {"fine": 10})
    check(_mgr.tier_counter(product, reputation) == 50,
            "a rung without a quality filter counts every unit given away", state)
    check(_mgr.tier_counter(product, brand) == 0,
            "a rung that waits for a quality must not count the units below it", state)

    _mgr.record_sale(LADDER_GOOD, {"exceptional": 7})
    check(_mgr.tier_counter(product, brand) == 7,
            "the units of the awaited quality must count", state)
    check(_mgr.tier_counter(product, reputation) == 57,
            "one counter is shared by the rungs of a good", state)

    # The second trigger is a different ledger: what the city made is not what it sold.
    _mgr.record_production(LADDER_GOOD, 25, "common")
    check(_mgr.tier_counter(product, {"trigger": "produce"}) == 25,
            "the trigger \"produce\" counts what the city made", state)
    check(_mgr.tier_counter(product, reputation) == 57,
            "a sale and a production are not the same counter", state)

    check(_mgr.tier_counter(product, {"trigger": "gift"}) == 0,
            "an unknown trigger counts nothing instead of guessing", state)
    check(_mgr.sold_by_quality.has(LADDER_GOOD), "the counter is kept per good", state)

# --- 3. THE LADDER ---

func _test_ladder(state: Dictionary) -> void:
    _reset_all()
    var product: Dictionary = _gdata.products[LADDER_GOOD]
    var thresholds := {}
    for tier in _mgr.TIERS:
        if product.has(tier):
            thresholds[tier] = int((product[tier] as Dictionary).get("threshold", 0))

    var multiplier_before: float = _cdata.get_trade_sell_price_multiplier(LADDER_GOOD)

    # One sale that crosses every rung pays every one of them: a city that has given away a
    # thousand units is known, branded and famous at once.
    _mgr.record_sale(LADDER_GOOD, {"exceptional": thresholds[_mgr.TIER_CHALLENGE]})
    for tier in _mgr.TIERS:
        check(_mgr.is_tier_done(_mgr.challenge_id(product, {}), tier),
                "the rung %s must be paid by the sale that crossed it" % tier, state)
    check(_events.size() == thresholds.size(),
            "each rung announces itself once (got %d for %d)" % [_events.size(),
                    thresholds.size()], state)

    var reward: Dictionary = _mgr.reward_at(product[_mgr.TIER_REPUTATION])
    check(absf(_cdata.get_trade_sell_price_multiplier(LADDER_GOOD)
            - multiplier_before * (1.0 + float(reward.get("value", 0.0)))) < 0.0001,
            "the rung of the reputation raises the price a town pays", state)

    check(_mgr.is_challenge_completed(_mgr.challenge_id(product, product[_mgr.TIER_CHALLENGE])),
            "the last rung is the challenge the data addresses", state)
    # The recipe of the prestige good waits for the technology of the base one as well; the test
    # learns it so that the rung of the ladder is the only thing left to prove.
    var ladder_recipe := _craft_of("aged_cheese")
    var ladder_tech := str(ladder_recipe.get("unlock_tech", ""))
    if not _cdata.is_tech_unlocked(ladder_tech):
        _cdata.unlocked_technologies.append(ladder_tech)
    check(_cdata.is_craft_available(ladder_recipe),
            "the prestige recipe opens with the rung that rewards it", state)

    # A rung is paid once: a second sale crosses nothing new.
    _events.clear()
    _mgr.record_sale(LADDER_GOOD, {"exceptional": 500})
    check(_events.is_empty(), "a rung already paid is not paid again", state)

# --- 4. THE PICKS ---

func _test_picks(state: Dictionary) -> void:
    _reset_all()
    _cdata.total_population = 0
    _cdata.specialization_claimed = 0
    check(_cdata.get_pending_specialization_picks() == 0,
            "a city of no citizens has no choice to spend", state)

    var product: Dictionary = _gdata.products[LADDER_GOOD]
    var challenge: String = _mgr.challenge_id(product, product[_mgr.TIER_CHALLENGE])
    _mgr.record_sale(LADDER_GOOD, {"exceptional":
            int((product[_mgr.TIER_CHALLENGE] as Dictionary).get("threshold", 0))})
    check(_cdata.specialization_challenge_picks == 1,
            "a challenge rewarded with a specialization gives one choice", state)
    check(_cdata.get_pending_specialization_picks() == 1,
            "the choice a challenge gave is pending", state)

    # A task of the era that gives something else gives no choice of the specialization.
    for record in _gdata.challenges:
        if record is Dictionary and str(_mgr.reward_at(record).get("type", "")) \
                != _mgr.REWARD_SPECIALIZATION:
            _mgr.complete_era_challenge(record)
    check(_cdata.specialization_challenge_picks == 1,
            "a challenge that rewards no specialization gives no choice", state)

    # The milestones keep their own budget: the gift of a challenge is added to it, never merged.
    _cdata.total_population = int(_cdata.get_specialization_thresholds()[0])
    _cdata.check_specialization_choice()
    check(_cdata.get_pending_specialization_picks() == 2,
            "the choices of the milestones and of the challenges add up", state)
    check(not _mgr.is_challenge_completed("no_such_challenge"),
            "a challenge nobody did is not completed", state)
    check(_mgr.is_challenge_completed(challenge), "the ladder names its own challenge", state)

# --- 5. THE GATES ---

func _test_gates(state: Dictionary) -> void:
    _reset_all()
    var product: Dictionary = _gdata.products[LADDER_GOOD]
    var spec_id := str(_mgr.reward_at(product[_mgr.TIER_CHALLENGE]).get("id", ""))
    var spec: Dictionary = _cdata.get_specialization(spec_id)
    check(not spec.is_empty(), "the challenge of %s rewards a specialization" % LADDER_GOOD, state)

    var recipe := _craft_of("aged_cheese")
    # The technology alone is not enough: the recipe waits for the fame of the good.
    if not _cdata.is_tech_unlocked(str(recipe.get("unlock_tech", ""))):
        _cdata.unlocked_technologies.append(str(recipe.get("unlock_tech", "")))
    check(not _cdata.is_craft_available(recipe),
            "the prestige recipe is closed while no rung of its ladder is paid", state)
    check(not _cdata.is_specialization_available(spec),
            "the prestige branch cannot be taken before its challenge", state)
    var requires: String = _cdata.get_specialization_unlock_text(spec)
    # The text names the task the branch waits for — the title the author gave the rung, or the good
    # itself — and never the bare identifier of it.
    check(requires != "" and requires != _mgr.challenge_id(product, product[_mgr.TIER_CHALLENGE]),
            "the branch says what it waits for (got \"%s\")" % requires, state)

    # The rung that grants the prestige good opens the work of it at once; the branch is not one of
    # those, it waits for the last rung of the ladder.
    _mgr.record_sale(LADDER_GOOD, {"exceptional":
            int((product[_mgr.TIER_BRAND] as Dictionary).get("threshold", 0))})
    check(_cdata.is_craft_available(recipe),
            "the rung of the brand opens the recipe it rewards", state)
    check(not _cdata.is_specialization_available(spec),
            "the branch waits for the last rung, not for the brand one", state)

    _mgr.record_sale(LADDER_GOOD, {"exceptional":
            int((product[_mgr.TIER_CHALLENGE] as Dictionary).get("threshold", 0))})
    check(_cdata.is_specialization_available(spec),
            "the challenge opens the branch it rewards", state)

    # Nothing is withheld: a branch the city cannot take still stands in the list the tab reads.
    _reset_all()
    var locked: Array = _cdata.get_locked_specializations()
    var found := false
    for other in locked:
        if str(other.get("id", "")) == spec_id:
            found = true
    check(found, "an unopened branch is listed among the unavailable ones", state)

func _craft_of(result_id: String) -> Dictionary:
    for craft in _gdata.crafts:
        if not (craft is Dictionary):
            continue
        var result = craft.get("result", null)
        if result is Dictionary and result.has(result_id):
            return craft
    return {}

# --- 6. THE SAVE ---

func _test_save(state: Dictionary) -> void:
    _reset_all()
    var product: Dictionary = _gdata.products[LADDER_GOOD]
    var reputation: Dictionary = product[_mgr.TIER_REPUTATION]
    _mgr.record_sale(LADDER_GOOD, {"exceptional": int(reputation.get("threshold", 0))})
    _mgr.record_production(LADDER_GOOD, 12, "fine")
    _mgr.chunks_bought_this_era = 3
    var snapshot: Dictionary = _mgr.serialize()

    _reset_all()
    check(_cdata.get_trade_sell_price_multiplier(LADDER_GOOD) == 1.0,
            "a city with no fame sells at the plain price", state)

    _mgr.deserialize(snapshot)
    check(_mgr.tier_counter(product, reputation) == int(reputation.get("threshold", 0)),
            "the counter of the fame comes back from the save", state)
    check(_mgr.is_tier_done(_mgr.challenge_id(product, reputation), _mgr.TIER_REPUTATION),
            "the rung paid before the save stays paid", state)
    check(_mgr.produced_by_quality.get(LADDER_GOOD, {}).get("fine", 0) == 12,
            "the production counter comes back from the save", state)
    check(_mgr.chunks_bought_this_era == 3, "the window of the era is restored", state)
    # The price of the fame is a consequence of the rungs, and it is rebuilt, not stored.
    check(absf(_cdata.get_trade_sell_price_multiplier(LADDER_GOOD)
            - (1.0 + float(_mgr.reward_at(reputation).get("value", 0.0)))) < 0.0001,
            "the price of the fame returns with the rung that granted it", state)

    # A save written before the mechanic carries nothing: the city has earned nothing.
    _reset_all()
    _mgr.deserialize({})
    check(_mgr.tier_counter(product, reputation) == 0,
            "a save without the block of the fame earns nothing", state)

# --- 7. THE TASKS OF THE ERA ---

func _test_era(state: Dictionary) -> void:
    _reset_all()
    var restraint := {}
    var whole := {}
    for record in _gdata.challenges:
        match str(record.get("condition", "")):
            "buy_no_chunks_in_one_era":
                restraint = record
            "buy_all_available_chunks_in_one_era":
                whole = record
    check(not restraint.is_empty() and not whole.is_empty(),
            "both tasks of the Region are declared", state)
    if restraint.is_empty() or whole.is_empty():
        return

    check(_mgr.offers_in_current_era(restraint) == (int(_main_map.current_era)
            == int(restraint.get("era", 0))),
            "a task of an era is offered only while that era runs", state)

    # The window of the restraint is the era: one purchase in it and the task is lost.
    _mgr.chunks_bought_this_era = 1
    _mgr.era_window_closed()
    check(not _mgr.is_challenge_completed(str(restraint.get("id", ""))),
            "a city that bought a chunk is not the one that bought none", state)
    check(_mgr.chunks_bought_this_era == 0,
            "the window of the era closes with the era", state)

    _mgr.era_window_closed()
    check(_mgr.is_challenge_completed(str(restraint.get("id", ""))),
            "an era that bought nothing closes with its task done", state)

    # The whole Region is done when nothing is left to buy; the count reads the map.
    var left: int = _mgr.available_chunk_count()
    check(_mgr.era_challenge_progress(whole).get("text", "") != "",
            "the task of the Region says how much is left", state)
    if left == 0:
        _mgr.era_window_closed()
        check(_mgr.is_challenge_completed(str(whole.get("id", ""))),
                "a Region with nothing left to claim is a claimed Region", state)

    # A reward that is not a specialization gives no choice — the era tasks are exactly that.
    check(_cdata.specialization_challenge_picks == 0,
            "the tasks of the Region give no choice of the specialization", state)

    # A condition the code does not implement never completes, however the data names it: the
    # judgment belongs to the code, the record only points at it.
    _gdata.challenges.append({"id": "invented_condition", "condition": "not_in_the_code"})
    _mgr.chunks_bought_this_era = 0
    _mgr.era_window_closed()
    _gdata.challenges.pop_back()
    check(not _mgr.is_challenge_completed("invented_condition"),
            "a challenge is completed by the code, not by the data", state)

func _test_tab(state: Dictionary) -> void:
    _reset_all()
    var city_ui = _main_map.get_node_or_null("CityUI")
    check(city_ui != null, "CityUI not found in MainMap", state)
    if city_ui == null:
        return
    var button = city_ui.get_node_or_null("TabBarPanel/TabBar/EraChallengesButton")
    check(button != null, "the tab button of the challenges is missing", state)
    check(city_ui.get_node_or_null("ContentPanel/ChallengesPanel") != null,
            "the panel of the challenges is missing", state)
    check(city_ui.challenges_tab != null, "the challenges tab script is not attached", state)
    if button == null or city_ui.challenges_tab == null:
        return

    # The button is a tab now, not a stub: it switches the window instead of saying "under
    # development".
    check(not (button in city_ui.stub_buttons),
            "the challenges button is no longer a stub", state)
    button.pressed.emit()
    check(city_ui.active_tab == "challenges",
            "the button did not switch to the challenges (got \"%s\")" % city_ui.active_tab, state)
    check(city_ui.challenges_panel.visible, "the challenges panel is not shown", state)
    await process_frame

    var list = city_ui.get_node_or_null(
            "ContentPanel/ChallengesPanel/Body/ScrollContainer/ChallengeList")
    check(list != null and list.get_child_count() > 0,
            "the list of the challenges is empty", state)
    if list == null:
        return

    # A good of the ladder, a rung of it and the reward of that rung are all readable.
    _mgr.record_sale(LADDER_GOOD, {"exceptional":
            int((_gdata.products[LADDER_GOOD][_mgr.TIER_REPUTATION] as Dictionary)
                    .get("threshold", 0))})
    city_ui.challenges_tab.refresh()
    await process_frame
    var text := _list_text(list)
    check(text.find(_gdata.get_product_name(LADDER_GOOD)) >= 0,
            "the tab names the good the ladder is about", state)
    check(text.find(str(_cdata.format_signed_percent(
            float(_mgr.reward_at(_gdata.products[LADDER_GOOD][_mgr.TIER_REPUTATION])
                    .get("value", 0.0))))) >= 0,
            "the tab says what the rung of the reputation gives", state)
    check(text.find("aged_cheese") < 0,
            "the prestige good of the ladder is named, not its identifier", state)

    var specializations = city_ui.get_node_or_null(
            "ContentPanel/SpecializationPanel/Body/ScrollContainer/SpecializationList")
    check(specializations != null, "the specialization list is missing", state)
    if specializations == null:
        return
    city_ui._switch_tab("specialization")
    await process_frame
    var spec_text := _list_text(specializations)
    check(spec_text.find("Requires") >= 0 or spec_text.find("cheese") >= 0,
            "an unopened prestige branch says what it waits for", state)

func _list_text(node: Node) -> String:
    var out := ""
    for child in node.get_children():
        out += _collect_text(child) + "\n"
    return out

func _collect_text(node: Node) -> String:
    var out := ""
    if node is Label:
        out += node.text
    for child in node.get_children():
        out += " " + _collect_text(child)
    return out

# --- THE STATE OF A NEW GAME ---

# Everything the mechanic remembers, back to the empty counters it starts with. The test walks the
# ladder more than once, and a rung paid by the pass before would hide the reward of the pass after.
func _reset_all() -> void:
    _events.clear()
    _mgr.sold_by_quality.clear()
    _mgr.produced_by_quality.clear()
    _mgr.done_tiers.clear()
    _mgr.completed_challenges.clear()
    _mgr.chunks_bought_this_era = 0
    _mgr._fame_price_share.clear()
    _cdata.specialization_challenge_picks = 0
    _cdata.specialization_claimed = 0
    _cdata.chosen_specialization_ids.clear()

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("OK: ", message)
    else:
        state["failed"] = true
        push_error("FALL: " + message)
