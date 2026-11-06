# challenge_manager.gd
# The fame of a good and the challenges of the era (see docs.md, "The fame of a good").
#
# The manager owns what the data cannot say by itself: the counters the tiers are measured against,
# the order in which a threshold is judged, and what a reward does. The records stay in the data —
# the tiers in the product itself (data/products/*.json) and the one-off tasks in
# data/challenges.json — so a mod adds a challenge by writing a record, not by writing a rule.
#
# A tier counts ONE counter per good, split by the quality of the units. The counter is cumulative
# and is never spent, so a save made before a tier existed simply carries no counter, and a threshold
# passed long ago still counts the units given away over the whole game.
#
# The two triggers are the two ways a good leaves the city that the world can see:
#   "sell" — a town takes the units from the storage of the city (the default, and the honest one:
#            fame needs witnesses, and a city that ate all its own cheese is not known for cheese);
#   "produce" — the city makes the units, whatever it then does with them.
# "min_quality" narrows a tier to the units of that level and above; the quality of the deposits is
# thus the currency of prestige, and a good produced without quality in the game ignores the field.
extends Node

const TIER_REPUTATION := "reputation"
const TIER_BRAND := "brand"
const TIER_CHALLENGE := "challenge"
const TIERS := [TIER_REPUTATION, TIER_BRAND, TIER_CHALLENGE]

const TRIGGER_SELL := "sell"
const TRIGGER_PRODUCE := "produce"

# The rewards of the data that the code knows. A record naming anything else is reported by the
# validator and gives nothing.
const REWARD_TRADE_PRICE := "trade_price"
const REWARD_BRAND_PRODUCT := "brand_product"
const REWARD_SPECIALIZATION := "specialization"
const REWARD_EFFECT_STUB := "effect_stub"

# The conditions of the era challenges (data/challenges.json, "condition"), for the validator. A mod
# cannot add one of these: the data names the task, the code is what decides whether it is done.
const KNOWN_CONDITIONS := ["buy_no_chunks_in_one_era", "buy_all_available_chunks_in_one_era"]

# The counters: product id -> {quality id: the units given away}. A good sold through a @-group is
# booked to the concrete good that left the storage, so the fame of a group is the fame of its
# members and never an alias of the first one.
var sold_by_quality := {}
var produced_by_quality := {}

# The tiers the city has already been paid for: "<tier id>:<tier>" -> true. The set is what keeps a
# threshold from rewarding twice, and a save that carries it is a save the rewards came in.
var done_tiers := {}

# The era challenges completed: challenge id -> true.
var completed_challenges := {}

# The era challenges the city can no longer complete: challenge id -> true. Only a task offered once
# stands here for the whole game; a task that returns with every era is judged again when the next
# window opens, so its failure is announced but not kept.
var failed_challenges := {}

# The chunks the city bought since the era began (see _on_territory_expanded and era_window_closed).
var chunks_bought_this_era := 0

# The challenge of a good is addressed as "<product id>_challenge" when its record names no id of
# its own: the fame blocks live in the product, and an id written by the author is the link the
# data of another file (a specialization, a recipe) uses.
const CHALLENGE_ID_SUFFIX := "_challenge"

# The reward of a reputation tier is a share on the price a town pays. It is held here rather than
# in the bonuses of a specialization because the two are read by the same code.
var _fame_price_share := {}

# A tier has just been paid for: the city window redraws the tab, the HUD shows the news.
signal fame_tier_completed(tier_id: String, tier: String, reward: Dictionary)
# An era challenge has been completed.
signal challenge_completed(challenge: Dictionary)
# An era challenge can no longer be completed: the window it was set in is lost for the city.
signal challenge_failed(challenge: Dictionary)

var _main_map = null


func _ready() -> void:
    # The manager is built in code, like the rest of the map managers (see main_map.state.gd), so
    # it waits for the map it hooks into.
    set_process(false)
    fame_tier_completed.connect(_on_fame_tier_completed)
    challenge_completed.connect(_on_challenge_completed)
    challenge_failed.connect(_on_challenge_failed)


# The reward of a tier or of a task is a surprise the player did not have to look for, so it is said
# out loud: the important line of the HUD goes into the journal of the game (journal.gd).
func _on_fame_tier_completed(_tier_id: String, tier: String, _reward: Dictionary) -> void:
    var map = get_node_or_null("/root/MainMap")
    if map == null or map.hud == null:
        return
    map.hud.show_message(_news_of_tier(tier), GameData.HUD_MESSAGE_IMPORTANT)


func _on_challenge_completed(challenge: Dictionary) -> void:
    _show_challenge_news(challenge, true)


func _on_challenge_failed(challenge: Dictionary) -> void:
    _show_challenge_news(challenge, false)


# The outcome of a task of the era is news the player is not sent looking for, so it is said out
# loud: the important line of the HUD goes into the journal of the game (journal.gd). A completion
# is also stopped in front of the player by the window the map builds; a failure is only said, since
# the city has nothing to take and nothing to decide.
func _show_challenge_news(challenge: Dictionary, completed: bool) -> void:
    var map = get_node_or_null("/root/MainMap")
    if map == null or map.hud == null:
        return
    map.hud.show_message(_news_of_era_challenge(challenge, completed), GameData.HUD_MESSAGE_IMPORTANT)


func _news_of_tier(tier: String) -> String:
    match tier:
        TIER_REPUTATION:
            return tr("The towns know what the city is good at.")
        TIER_BRAND:
            return tr("The world has learned the name of the goods of the city.")
        TIER_CHALLENGE:
            return tr("The challenge of the era is completed: the city has a specialization to take.")
        _:
            return tr("The fame of a good has brought the city news.")


func _news_of_era_challenge(challenge: Dictionary, completed: bool) -> String:
    if completed:
        return tr("Challenge completed: %s") % _challenge_title(challenge)
    return tr("Challenge failed: %s") % _challenge_title(challenge)


# A task of the era is known to the player by its name; the id is what the author left when the
# record came without one.
func _challenge_title(record: Dictionary) -> String:
    var name := str(record.get("name", ""))
    return name if name != "" else str(record.get("id", ""))


# The body of the news about a finished task of the era: what it asked and what the city earned. The
# standing of the city is not part of it — the window opens when the task is over, and what is left
# to buy says nothing to a player who has just bought it.
#
# Every line carries the kind it is ("name", "flavor", "reward"), which says to the view how to paint
# it: the window of the result gives a kind the shape the tab gives the same words.
func challenge_news_lines(record: Dictionary) -> Array:
    var lines: Array = []
    var title := _challenge_title(record)
    if title != "":
        lines.append({"kind": "name", "text": title})
    var description := str(record.get("description", ""))
    if description != "":
        lines.append({"kind": "flavor", "text": description})
    for reward in rewards_of(record):
        var text := reward_text(reward)
        if text != "":
            lines.append({"kind": "reward", "text": text})
    return lines


# The map owns the era and the claiming of the Region, and both are needed by the era challenges.
func bind_map(main_map) -> void:
    _main_map = main_map
    if _main_map == null:
        return
    _main_map.expansion_manager.territory_expanded.connect(_on_territory_expanded)


# Called when the era advances, BEFORE the new Region is claimed: the window of the era that is
# closing is judged while its own Region is still the whole of the picture, and the free claiming of
# the new Region — which spends no money and is not a purchase — cannot spoil the task of restraint.
# A task that is not done by the time its window closes is not done at all: the era does not wait.
func era_window_closed() -> void:
    for record in era_challenge_records():
        if _condition_holds(record):
            complete_era_challenge(record)
        else:
            fail_era_challenge(record)
    chunks_bought_this_era = 0


func _on_territory_expanded(_row: int, _col: int, _cost) -> void:
    chunks_bought_this_era += 1
    for record in era_challenge_records():
        if _condition_holds(record):
            complete_era_challenge(record)
        elif _condition_lost(record):
            fail_era_challenge(record)


# --- THE COUNTERS ------------------------------------------------------------

# The units of a good a town has taken from the city. `breakdown` is what the storage gave up, by
# quality (CityData.remove_from_storage returns it).
func record_sale(pid: String, breakdown: Dictionary) -> void:
    _accumulate(sold_by_quality, pid, breakdown)
    _check_product_tiers(pid)


# The units of a good the city has made.
func record_production(pid: String, amount: int, quality: String) -> void:
    if amount <= 0:
        return
    _accumulate(produced_by_quality, pid, {quality: amount})
    _check_product_tiers(pid)


func _accumulate(into: Dictionary, pid: String, breakdown: Dictionary) -> void:
    if pid.is_empty() or breakdown.is_empty():
        return
    if not into.has(pid):
        into[pid] = {}
    var by_quality: Dictionary = into[pid]
    for quality in breakdown:
        var units := int(breakdown[quality])
        if units <= 0:
            continue
        var key := str(quality)
        by_quality[key] = int(by_quality.get(key, 0)) + units


# The counter a tier is measured against: the units of the good counted by the trigger of the tier,
# and only those of the quality the tier waits for.
func tier_counter(product: Dictionary, block: Dictionary) -> int:
    var pid := str(product.get("id", ""))
    var trigger := str(block.get("trigger", TRIGGER_SELL))
    var by_quality: Dictionary
    match trigger:
        TRIGGER_SELL:
            by_quality = sold_by_quality.get(pid, {})
        TRIGGER_PRODUCE:
            by_quality = produced_by_quality.get(pid, {})
        _:
            # An unknown trigger counts nothing (data_validator reports it): guessing "sell" would
            # make a typo of the author pay the player for a task he never did.
            return 0
    var minimum := str(block.get("min_quality", ""))
    if minimum.is_empty():
        var plain := 0
        for quality in by_quality:
            plain += int(by_quality[quality])
        return plain
    return _units_at_or_above(by_quality, minimum)


# The units of the levels at `quality` and better. The order of the levels is the order of the data
# (worst first), not an assumption about the spelling of an identifier.
func _units_at_or_above(by_quality: Dictionary, quality: String) -> int:
    var levels := GameData.get_quality_levels()
    var rank := levels.find(quality)
    if rank < 0:
        return 0
    var total := 0
    for i in range(rank, levels.size()):
        total += int(by_quality.get(str(levels[i]), 0))
    return total


# --- THE TIERS OF A GOOD -----------------------------------------------------

# The fame blocks of the data, in the shape the interface lists them: a challenge of the era and its
# tiers, each with the progress of the city against its threshold.
func fame_records() -> Array:
    var out: Array = []
    for pid in GameData.products:
        var product: Dictionary = GameData.products[pid]
        for tier in TIERS:
            var block = product.get(tier, null)
            if not (block is Dictionary):
                continue
            out.append(_fame_record(product, tier, block))
    out.sort_custom(func(a, b):
        return str(a.get("id", "")) < str(b.get("id", "")))
    return out


func _fame_record(product: Dictionary, tier: String, block: Dictionary) -> Dictionary:
    return {
        "id": challenge_id(product, block),
        "tier": tier,
        "product": str(product.get("id", "")),
        "product_name": GameData.get_product_name(str(product.get("id", ""))),
        "icon": str(block.get("icon", product.get("icon", ""))),
        "name": str(block.get("name", "")),
        "description": str(block.get("description", "")),
        "threshold": int(block.get("threshold", 0)),
        "trigger": str(block.get("trigger", TRIGGER_SELL)),
        "min_quality": str(block.get("min_quality", "")),
        "progress": tier_counter(product, block),
        "reward": block.get("reward", {}),
        "done": is_tier_done(challenge_id(product, block), tier),
    }


# The identifier a tier is addressed by outside the product: the one the author wrote, or the derived
# one when the block stands on its own.
func challenge_id(product: Dictionary, block: Dictionary = {}) -> String:
    var written := str(block.get("id", ""))
    if not written.is_empty():
        return written
    return "%s%s" % [str(product.get("id", "")), CHALLENGE_ID_SUFFIX]


func is_tier_done(id: String, tier: String) -> bool:
    return done_tiers.has("%s:%s" % [id, tier])


func is_challenge_completed(id: String) -> bool:
    if completed_challenges.has(id):
        return true
    # The fame block of a good is a challenge of its own: a specialization waits for it by the id of
    # the block, and the block is completed the moment its threshold is paid for.
    return done_tiers.has("%s:%s" % [id, TIER_CHALLENGE])


func _check_product_tiers(pid: String) -> void:
    var product = GameData.products.get(pid, null)
    if not (product is Dictionary):
        return
    # The soft reputation first, the brand after it, the challenge last: the tiers share one counter,
    # and a city that crossed 1000 units crossed 200 as well. Judging them in the order of the ladder
    # pays all of them at once rather than leaving the player with a task he has already done.
    for tier in TIERS:
        var block = product.get(tier, null)
        if not (block is Dictionary):
            continue
        var id := challenge_id(product, block)
        if is_tier_done(id, tier):
            continue
        var threshold := int(block.get("threshold", 0))
        if threshold <= 0 or tier_counter(product, block) < threshold:
            continue
        mark_tier_done(id, tier)
        for reward in rewards_of(block):
            apply_reward(product, reward)
        emit_signal("fame_tier_completed", id, tier, reward_at(block, 0))


func mark_tier_done(id: String, tier: String) -> void:
    done_tiers["%s:%s" % [id, tier]] = true


# --- THE REWARDS -------------------------------------------------------------

func reward_at(block, index: int = 0) -> Dictionary:
    var rewards := rewards_of(block)
    return rewards[index] if index < rewards.size() else {}


func rewards_of(block) -> Array:
    var reward = block.get("reward", null) if block is Dictionary else null
    if reward is Dictionary:
        return [reward]
    if reward is Array:
        return reward
    return []


func apply_reward(product, reward: Dictionary) -> void:
    match str(reward.get("type", "")):
        REWARD_TRADE_PRICE:
            var pid := str(product.get("id", "")) if product is Dictionary else ""
            if pid.is_empty():
                return
            var share := float(reward.get("value", 0.0))
            _fame_price_share[pid] = float(_fame_price_share.get(pid, 0.0)) + share
        REWARD_BRAND_PRODUCT:
            # The recipe of the prestige good is opened by the tier itself (its "unlock_challenge"
            # names the tier), so nothing is granted here: the point is that the tier is done.
            pass
        REWARD_SPECIALIZATION:
            CityData.grant_specialization_pick()
        REWARD_EFFECT_STUB:
            # A place for an effect the code has not been written for yet.
            print("ChallengeManager: the stub effect '%s' is granted." % str(reward.get("id", "")))
        _:
            pass


# The share the fame of a good adds to the price a town pays for it. A tier of another good never
# raises this one: the share is scoped to the product that earned it.
func get_fame_trade_price_share(pid: String) -> float:
    return float(_fame_price_share.get(pid, 0.0))


# The reward of a tier or of a challenge in the words of the view that lists them. The manager owns
# what a reward type does, so it is the one that can say what the player will get; a plate that
# invented its own phrasing would drift from the grant.
func reward_text(reward: Dictionary, product_id: String = "") -> String:
    match str(reward.get("type", "")):
        REWARD_TRADE_PRICE:
            if product_id.is_empty():
                return tr("The town pays %s more") % CityData.format_signed_percent(
                        float(reward.get("value", 0.0)))
            return tr("The town pays %s more for %s") % [
                    CityData.format_signed_percent(float(reward.get("value", 0.0))),
                    GameData.get_product_name(product_id)]
        REWARD_BRAND_PRODUCT:
            return tr("Unlock the recipe of %s") % GameData.get_product_name(
                    str(reward.get("product", "")))
        REWARD_SPECIALIZATION:
            var spec := CityData.get_specialization(str(reward.get("id", "")))
            if spec.is_empty():
                return tr("A specialization of the city")
            return tr("%s, and one free specialization point to spend") \
                    % CityData.get_specialization_full_name(spec)
        REWARD_EFFECT_STUB:
            return tr("An effect still to be written (%s)") % str(reward.get("id", ""))
    return ""


# The fame block addressed by the id of its challenge, or an empty record. Another file of the data
# (a specialization, a recipe) names that id, and the player has to be told which good the branch
# waits for. The tiers of a good share one id when the author writes none, so the challenge tier —
# the one that carries the name of the task — is the record returned.
func fame_record_of(id: String) -> Dictionary:
    var other := {}
    for record in fame_records():
        if str(record.get("id", "")) != id:
            continue
        if str(record.get("tier", "")) == TIER_CHALLENGE:
            return record
        if other.is_empty():
            other = record
    return other


# What a fame task *opens*, as opposed to what *completes* it. The recipe of the prestige good waits
# for the rung that grants the good — the brand — so a city can work it before the whole ladder is
# climbed; the branch of the specialization waits for the last rung and asks with
# "is_challenge_completed". A task of the era is not a ladder: it opens what it names the moment it
# is done, and the last rung always implies the brand one — a city that sold a thousand units
# crossed the five hundred of them as well.
func is_challenge_opened(challenge_id: String) -> bool:
    if completed_challenges.has(challenge_id):
        return true
    if is_tier_done(challenge_id, TIER_BRAND):
        return true
    return is_tier_done(challenge_id, TIER_CHALLENGE)


# --- WHAT THE RUNG OF THE BRAND OPENS ------------------------------------------

# The prestige good → the fame task whose rung of the brand grants it. The pair is written on the
# side of the ladder (the reward of the block), so the work of the brand is opened without the author
# naming the task in every recipe again. The map comes from the data alone and is built once: the
# loaded goods do not change while the city plays.
var _brand_granters := {}


func _index_brand_granters() -> void:
    _brand_granters = {}
    for pid in GameData.products:
        var product: Dictionary = GameData.products[pid]
        var block = product.get(TIER_BRAND, null)
        if not (block is Dictionary):
            continue
        for reward in rewards_of(block):
            if not (reward is Dictionary):
                continue
            if str(reward.get("type", "")) != REWARD_BRAND_PRODUCT:
                continue
            _brand_granters[str(reward.get("product", ""))] = challenge_id(product, block)


# Whether the city has earned the right to work this prestige good: the rung that grants it is paid.
# A good that no ladder grants is a mistake of the data, not a debt of the city — the validator names
# it — and until the author fixes it the good is worked as an ordinary one.
func is_brand_granted(brand_id: String) -> bool:
    if _brand_granters.is_empty():
        _index_brand_granters()
    var id := str(_brand_granters.get(brand_id, ""))
    if id.is_empty():
        return true
    return is_challenge_opened(id)


# --- THE CHALLENGES OF THE ERA -------------------------------------------------

# The one-off tasks of data/challenges.json that the city can still finish.
func era_challenge_records() -> Array:
    var out: Array = []
    for record in GameData.challenges:
        if not (record is Dictionary):
            continue
        var id := str(record.get("id", ""))
        if completed_challenges.has(id) or failed_challenges.has(id):
            continue
        if not offers_in_current_era(record):
            continue
        out.append(record)
    return out


func is_challenge_failed(id: String) -> bool:
    return failed_challenges.has(id)


# Whether the task of the data is offered at this moment. A record without "era" belongs to no
# particular era and is always on the list; a record that names one is live only while the world
# stands in it.
func offers_in_current_era(record: Dictionary) -> bool:
    if not record.has("era"):
        return true
    if _main_map == null:
        return false
    return int(_main_map.current_era) == int(record.get("era", 0))


# Whether the condition of a task holds at this moment. A task without a condition of the code is
# never done: the data names the check, it cannot invent one.
func _condition_holds(record: Dictionary) -> bool:
    match str(record.get("condition", "")):
        "buy_no_chunks_in_one_era":
            return chunks_bought_this_era == 0
        "buy_all_available_chunks_in_one_era":
            return _main_map != null and region_open_hex_count() == 0
        _:
            return false


# Whether the condition of a live task has become unreachable before its window closed. The task of
# restraint is lost with the first purchase of the era; the Region stays winnable until the era ends,
# because every hex left in it can still be bought. A condition the code does not know is not called
# lost here — the validator already reports it, and the city is not told it failed at something the
# game never measured.
func _condition_lost(record: Dictionary) -> bool:
    match str(record.get("condition", "")):
        "buy_no_chunks_in_one_era":
            return chunks_bought_this_era > 0
        _:
            return false


func complete_era_challenge(record: Dictionary) -> void:
    var id := str(record.get("id", ""))
    if id.is_empty() or completed_challenges.has(id):
        return
    completed_challenges[id] = true
    for reward in rewards_of(record):
        apply_reward(null, reward)
    emit_signal("challenge_completed", record)


# The window of the task is closed and the city did not meet it. A task offered once is gone for the
# whole game; a task of every era comes back with the next window, so only its news is kept.
func fail_era_challenge(record: Dictionary) -> void:
    var id := str(record.get("id", ""))
    if id.is_empty() or failed_challenges.has(id):
        return
    if bool(record.get("once", false)):
        failed_challenges[id] = true
    emit_signal("challenge_failed", record)


# The progress of an era task, for the tab that lists them before the player accepts any of them.
func era_challenge_progress(record: Dictionary) -> Dictionary:
    match str(record.get("condition", "")):
        "buy_no_chunks_in_one_era":
            return {"text": tr("Chunks bought this era: %d") % chunks_bought_this_era}
        "buy_all_available_chunks_in_one_era":
            return {"text": tr("Chunks left to buy: %d") % available_chunk_count()}
        _:
            return {"text": ""}


# The chunks the city could still claim in the Region of the current era. A chunk is not stored on
# the map: the claiming assembles it by a BFS outwards from a hex (expansion_manager.get_chunk_hexes),
# so the task walks the same rule over every hex that is open, and a hex already counted is not taken
# from a second start. The fog is not part of the count: land the city has not scouted is still the
# Region it has to buy, and a task that read only the explored hexes would be met by taking the one
# chunk the player happened to look at.
func available_chunks() -> Array:
    if _main_map == null:
        return []
    var bounds = _main_map.get_region_bounds()
    var seen := {}
    var out: Array = []
    for row in range(int(bounds.row_start), int(bounds.row_end) + 1):
        for col in range(int(bounds.col_start), int(bounds.col_end) + 1):
            var key := "%d,%d" % [row, col]
            if seen.has(key) or not _is_claimable_hex(row, col):
                continue
            var chunk = _main_map.expansion_manager.get_chunk_hexes(row, col)
            if chunk.is_empty():
                continue
            for hex in chunk:
                seen["%d,%d" % [int(hex.row), int(hex.col)]] = true
            out.append(chunk)
    return out


func available_chunk_count() -> int:
    return available_chunks().size()


# The hexes of the Region the city does not own and could still take. The count of HEXES, not of the
# chunks above, is what the task of the whole Region is measured against: the grouping of the fog is
# decided by how the player scouts, while the land left is the same whichever way he reaches it.
func region_open_hex_count() -> int:
    if _main_map == null:
        return 0
    var bounds = _main_map.get_region_bounds()
    var count := 0
    for row in range(int(bounds.row_start), int(bounds.row_end) + 1):
        for col in range(int(bounds.col_start), int(bounds.col_end) + 1):
            if _is_claimable_hex(row, col):
                count += 1
    return count


# A hex is open for claiming when it is inside the Region and belongs neither to the city nor to the
# ring of a town (expansion_manager refuses the same two). Whether the player has scouted it changes
# when he can buy it, not whether the task still asks for it.
func _is_claimable_hex(row: int, col: int) -> bool:
    if not _main_map.is_valid_hex(row, col):
        return false
    var tile = _main_map.get_tile_data(row, col)
    if not (tile is Dictionary):
        return false
    if bool(tile.get("in_influence", false)) or bool(tile.get("in_town_influence", false)):
        return false
    return true


# --- THE SAVE ------------------------------------------------------------------

# The record of the save. The counters are copied, not handed over: the caller writes the record to
# the disk and may keep the dictionary while the city goes on selling, and a snapshot that aliases
# the live counters is not a snapshot.
func serialize() -> Dictionary:
    return {
        "sold": _copy_counters(sold_by_quality),
        "produced": _copy_counters(produced_by_quality),
        "tiers": done_tiers.keys(),
        "challenges": completed_challenges.keys(),
        "challenge_failures": failed_challenges.keys(),
        "chunks_this_era": chunks_bought_this_era,
    }


func _copy_counters(by_product: Dictionary) -> Dictionary:
    var out := {}
    for pid in by_product:
        out[pid] = (by_product[pid] as Dictionary).duplicate(true)
    return out


# JSON reads every number of a dictionary as a float, so the units are coerced on the way back in.
func deserialize(state: Dictionary) -> void:
    if not (state is Dictionary) or state.is_empty():
        return
    sold_by_quality = _index_of_counters(state.get("sold", {}))
    produced_by_quality = _index_of_counters(state.get("produced", {}))
    done_tiers = {}
    var tiers = state.get("tiers", [])
    if tiers is Array:
        for tier in tiers:
            done_tiers[str(tier)] = true
    completed_challenges = {}
    var challenges = state.get("challenges", [])
    if challenges is Array:
        for id in challenges:
            completed_challenges[str(id)] = true
    failed_challenges = {}
    var failures = state.get("challenge_failures", [])
    if failures is Array:
        for id in failures:
            failed_challenges[str(id)] = true
    chunks_bought_this_era = int(state.get("chunks_this_era", 0))
    _restore_fame_prices()


func _index_of_counters(by_product) -> Dictionary:
    var out := {}
    if not (by_product is Dictionary):
        return out
    for pid in by_product:
        var by_quality = by_product[pid]
        if not (by_quality is Dictionary):
            continue
        var coerced := {}
        for quality in by_quality:
            var units := int(by_quality[quality])
            if units > 0:
                coerced[str(quality)] = units
        if not coerced.is_empty():
            out[str(pid)] = coerced
    return out


# The share a reputation tier adds to the price is a consequence of the counters, not a fact of its
# own: a save that says the tier is done says the share, and a good whose tier the save does not
# mention gets nothing.
func _restore_fame_prices() -> void:
    _fame_price_share.clear()
    for pid in GameData.products:
        var product: Dictionary = GameData.products[pid]
        var block = product.get(TIER_REPUTATION, null)
        if not (block is Dictionary):
            continue
        if not is_tier_done(challenge_id(product, block), TIER_REPUTATION):
            continue
        for reward in rewards_of(block):
            if str(reward.get("type", "")) != REWARD_TRADE_PRICE:
                continue
            _fame_price_share[str(pid)] = float(reward.get("value", 0.0))
