# CityData.gd (Autoload)
@tool
extends Node

# The storage and the production
var city_storage: Dictionary = {}
# The breakdown of the storage by quality: product_id -> { "common": N, "fine": N, ... }
# The sum over all the levels of the quality is always equal to city_storage[product_id].
var city_quality_detail: Dictionary = {}
# The actual counters of the production/consumption for the current tick of the simulation.
# They are needed to determine the famine (CityData._check_population_change compares
# the sums over the food_pool) and for the TopBar (city_ui._update_food_label — the label
# "Food: N [+Y / -Z]" with the fact per tick, a fallback to the planned at a zero
# fact). The breakdown by the sources (production_sources / consumption_sources)
# has been removed from the tooltip of the tab "Resources" (see the commit 5790016), and the
# sources themselves are no longer maintained.
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var city_food_pool: Dictionary = {}
# --- THE INTERNAL MARKET (the tab "Trade") ---
# The key of the state in all three dictionaries below is the DISPLAY_KEY of the resource: the id
# of a single product ("feathers") or an "@group" ("@boats"). This is exactly the
# key which GameData.get_profession_consumption() puts into the record
# (the field display_key), therefore the addressing is the same both for the single
# resources and for the groups of products.
#
# market_consumption_enabled — whether the city is allowed to buy this resource on the
# internal market (the toggle on the card of "Trade"). The absence of the key =
# allowed (by default the market is open for everything).
var market_consumption_enabled: Dictionary = {}
# consumption_priority — the priority of the write-off BY QUALITY on the internal
# market: "best" | "worst" | "random" (data/qualities.json,
# priority_options). The default — GameData.get_quality_priority_default(),
# exactly as quality_priority of the buildings (see building_panel).
var consumption_priority: Dictionary = {}
# market_consumption_rates — the ACTUAL consumption on the internal market
# for the current tick: product_id -> units. A separate counter, because the
# common consumption_rates is mixed with all the channels (including the production
# inputs of the buildings), and the card of "Trade" needs exactly the market. It lives exactly
# one tick of the simulation, it is cleared in reset_counters() — as the other rates.
var market_consumption_rates: Dictionary = {}
# market_consumption_accum / _snapshot — the same fact, but accumulated over the DISPLAY
# window, and not over one tick. The tick counter is not enough: the display
# interval is configured by the player (1..5 sec), and when it is read once in 2-5 seconds
# the tick counter has almost always already been cleared (reset_counters) — the "fact" in the card
# would either not appear at all, or would jump between the zeroes. The window gives a stable
# value, which is also visible at the refresh rate of 1 sec.
# It is filled in record_market_consumption(), reset into the snapshot in
# rotate_market_consumption_window() (next to rotate_treasury_window).
var market_consumption_accum: Dictionary = {}
var market_consumption_snapshot: Dictionary = {}
var city_built_buildings: Array = []
var domesticated_animals: Array = []
var domesticated_plants: Array = []
var domesticated_resources: Array = []
# The treasury of the city (the coins). It is always a whole number; it is replenished by the consumption of the
# resources on the internal market (see add_treasury / get_internal_market_price and
# docs.md, "The treasury of the city and the internal market").
var treasury: int = 0

# The construction of the buildings: the key -> the data
var building_construction: Dictionary = {}

# The technologies
var unlocked_technologies: Array = []
var current_research_tech_id: String = ""
var current_research_science_cost: int = 0
var research_progress: float = 0.0
var research_science_accumulated: float = 0.0

# The messages for the HUD after the completion of a research (about the found resources)
var current_era_index: int = 0

# --- THE POPULATION ---
var last_research_messages: Array = []

# The debug toggle: whether the population consumes the food. It is managed from the
# debug menu (the item "Toggle the consumption of the food"), it is NOT saved to the save —
# this is a runtime bypass toggle for the debugging, and not a game state.
var total_population: int = 1
var idle_population: int = 1 # the free citizens (not busy anywhere)
# The name of the city — it is chosen by the player in the dialog at the start of a new game.
# An empty string = the name is not set yet (then it is not drawn on the map).
var city_name: String = ""
var food_for_new_settler: int = 1000
var food_per_citizen: int = 10
    # The record of the FACT of the write-off on the internal market for the tick. A separate counter
    # (market_consumption_rates), because the common consumption_rates
    # is mixed with the production inputs of the buildings. It is written from worker_manager
    # exactly at those places where the resource leaves the city for money.
var food_consumption_enabled: bool = true
# The debug toggle: ignore the requirements of the technologies. When it is on —
# the research does not check the prerequisites and the restriction by the eras (it is possible to learn
# the technologies of the next eras). The toggle from the debug menu, is NOT saved to the save.
# Only the selected technology is learned at that time — the predecessors are not
# are added automatically.
var ignore_tech_requirements: bool = false
# The debug toggle: ignore the requirements of the construction. When it is on —
# ALL the actions which spend time or resources are performed instantly and for free:
#   * the buildings in the city and their improvements ( upgrades) — instantly, without the queue of
#     the builds and without the limit of the simultaneously building objects, the additional
#     materials (additional_cost) are not checked and not written off, the additional
#     conditions (additional_req) are considered met;
#   * the improvements and all the special actions on the map (the felling of the forest, the gathering of the wild plants,
#     the drainage of the marshes, the demolition of an improvement, the road) — instantly;
#   * the scouting of a chunk — instantly and for free (the coins are not written off from the treasury);
#   * the claiming of the territory (the purchase of a chunk) — instantly and for free.
# The toggle from the debug menu, is NOT saved to the save. The technological requirements
# (unlock_tech) it does NOT cancel — there is a separate toggle for that
# ignore_tech_requirements.
var ignore_build_requirements: bool = false

# --- THE TICK OF THE GAME SIMULATION ---
# The single step of the whole game simulation: the production of the improvements and the buildings (the crafting
# of the slots), the consumption of the food by the population, the occupational and the city consumption,
# the feed of the pastures, the base growth of the science and so on — everything ticks once per SIMULATION_TICK
# seconds (the step in main_map._process). The improvements release the product by
# their own interval — the field "production_interval" from
# data/improvements.json (see get_improvement_production_interval).
const SIMULATION_TICK: float = 1.0

# --- THE DISPLAY INTERVAL OF THE RESOURCES (the setting "Settings → Game → The interval
# of the update of the data about the resources"). The simulation ticks every SIMULATION_TICK
# seconds, and the DISPLAY of the resources (the tab "Resources", the top bar of the city,
# the tooltip of the details of a building, the left column of the control panel, the tooltips with the resources)
# is updated no more often than once per resource_display_interval seconds.
#
# The mechanics is the "era of the display" (epoch): a single counter in the autoload, which
# is advanced by main_map._process (on the pause of the tree _process does not go — the interval
# is counted in the game time). Every UI place stores the last seen
# era and is updated only when it has changed (resource_display_due) —
# in this way all the places are updated simultaneously, by one "jerk" per interval.
# The updates on the explicit actions of the player (opening a window, a click on a hex, a change
# of the assignments, the toggle of the food) do NOT wait for the era — they are called directly and after
# themselves they synchronise the era.
#
# The acceptable values: 1..5 seconds with a step of 1: the data changes only on
# the ticks of 1 second, a fractional interval would give only an uneven rhythm of the
# updates (the updates would fall into a different phase of the ticks) with invariably
# correct whole numbers on the screen.
var resource_display_interval: float = 1.0
var resource_display_epoch: int = 0
var _resource_display_accum: float = 0.0

# Sets the display interval of the resources (step 1, range 1..5 sec).
# A change of the value resets the accumulator and raises the era — all the places
# are updated immediately at the nearest check. The same value is a no-op.
func set_resource_display_interval(value: float) -> void:
    var new_interval := clampf(roundf(value), 1.0, 5.0)
    if is_equal_approx(new_interval, resource_display_interval):
        return
    resource_display_interval = new_interval
    _resource_display_accum = 0.0
    resource_display_epoch += 1

# Accumulates the game time and raises the era, when the interval has passed.
# It is called from main_map._process every frame.
func tick_resource_display(delta: float) -> void:
    if resource_display_interval <= 0.0:
        return
    _resource_display_accum += delta
    if _resource_display_accum >= resource_display_interval:
        # fmod holds the phase instead of accumulating an endless remainder: the interval
        # is a multiple of the tick step (1 sec), the fractional part almost does not accumulate.
        _resource_display_accum = fmod(_resource_display_accum, resource_display_interval)
        resource_display_epoch += 1
        # The display window of the breakdown of the treasury is updated by its own rhythm
        # (treasury_window_length_sec, by default 3 sec — see
        # DEFAULT_TREASURY_WINDOW_SEC). The binding to the era of the resources is convenient
        # for the UI (with one tick "the resources have updated → the breakdown of the
        # treasury has updated"), but the segment is shorter: the era ticks once per
        # resource_display_interval (1..5 sec), and here we count our own ticks
        # with the same delta as the resource era (an even step of 1 sec is not needed —
        # the accuracy requires only "plus or minus a second").
        _treasury_window_accum_sec += float(resource_display_interval)
        if _treasury_window_accum_sec >= treasury_window_length_sec:
            rotate_treasury_window()
            _treasury_window_accum_sec = 0.0
        # The window of the fact of the consumption of the market — by the length of the resource era (1..5 sec):
        # the card of "Trade" is updated exactly then, therefore its "fact"
        # must be accumulated exactly after the same. It has no length of its own
        # deliberately — any other one would cut the card off for an interval, and
        # with an interval of 5 sec a window of 3 sec would be updated more often than the card.
        rotate_market_consumption_window()

# The accumulator of the game time for the window of the breakdown of the treasury. Only here.
var _treasury_window_accum_sec: float = 0.0

# True, if the place has not updated the display of the resources since the last check.
# The caller remembers CityData.resource_display_epoch after the update.
func resource_display_due(last_epoch: int) -> bool:
    return last_epoch != resource_display_epoch

# --- THE ERAS ---
# Returns the index of the era of the technology in GameData.eras.
# If the technology is not found, or its era is absent from the list of the eras — -1.
func get_tech_era_index(tech_id: String) -> int:
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null:
        return -1
    var era_id: String = tech_data.get("era", "")
    for i in range(GameData.eras.size()):
        if GameData.eras[i].get("id", "") == era_id:
            return i
    return -1

# Is it allowed to learn the technology by the eras: only the technologies of the
# current and the previous eras are allowed. The technologies of the next era are inaccessible,
# even if all their prerequisites are met.
func is_tech_era_allowed(tech_id: String) -> bool:
    # Debug: with "do not observe the requirements" enabled the restriction by the eras
    # is removed — it is possible to learn the technologies of any era.
    if ignore_tech_requirements:
        return true
    var era_idx := get_tech_era_index(tech_id)
    # A technology without a known era is not blocked (a protection from incorrect data).
    if era_idx < 0:
        return true
    return era_idx <= current_era_index

# The human-readable name of the era by the index; for an incorrect index — an empty string.
func _get_era_name_by_index(index: int) -> String:
    if index < 0 or index >= GameData.eras.size():
        return ""
    return GameData.eras[index].get("name", "")

# The transition to the next era. It is called from main_map.advance_to_next_era().
func advance_era() -> void:
    if current_era_index < GameData.eras.size() - 1:
        current_era_index += 1
    emit_signal("city_updated")

# --- THE SCIENCE ---
# The base income of the science of the city (points/sec). The city never produces less than
# this rate, even without the science buildings — so that the early game is not blocked.
const BASE_SCIENCE_PER_SEC: float = 1.0
# The cache of the contribution of the working science buildings to the rate of the research (points/sec).
# It is recalculated from scratch once per tick of the simulation in do_tick(). The formula per building:
#   (additional_yield.science + the weighted average of the special_yield of the consumed
#    mixture of the bases) × the bonus of the profession of the scholar (the feathers/ink, ×1.25).
# Neither required nor the craft_time of the recipe "Science" are included in the rate of the science:
# the recipe is only a "pass" (while the raw material is available, the scholars work), its input
# only sets the expense of the fuel. The rate of the work of the scholars is determined by the
# special_yield of the bases themselves (see docs.md, "Science: production and research").
# There is no pool of science — the produced science is not accumulated in the storage, but directly
# is added to the rate of the learning of the technologies (see get_science_rate_per_sec,
# of the display window, and the tooltip of the breakdown (see rotate_treasury_window above):
# the sum accumulated over the window is divided by the length of the window. Both numbers are the FACT by the
# same points where add_treasury/spend_treasury is called; there are no planned maps here
# and none are needed: the treasury has no planned rate of the expenses (the expenses are the event-based
# spendings of the player), and the income is written into the flat accumulator next to the replenishment anyway.
# This is the same data that the tooltip reads, — the rows in the HUD and in the city cannot
# diverge from the breakdown.
# tick_research_science_continuous).
var science_buildings_rate_per_sec: float = 0.0
# The cache of the breakdown of the rate of the science by the sources (for the tooltip on the tab
# "Technologies"). It is filled in once per tick in do_tick() next to
# science_buildings_rate_per_sec from the same values:
#   {
#     "base": 1.0,                  # BASE_SCIENCE_PER_SEC
#     "buildings": [                # for each working science building
#         "name": "Scriptorium",
#         "fixed": 3.0,             # additional_yield.science, WITHOUT the bonus
#         "mediums": 2.0,           # the weighted average of the special_yield of the mixture, WITHOUT the bonus
#         "bonus": 1.25,            # the multiplier of the profession (the feathers/ink)
#         "mediums_names": ["Papyrus"],        # what is actually consumed
#         "bonus_names": ["Feathers"],            # what gives the bonus of the consumption
#       }, ...
#     ],
#     "total": 7.5,                 # = get_science_rate_per_sec()
#   }
# The total of a building = (fixed + mediums) × bonus — it is assembled in the tooltip.
# Before the first tick — an empty dictionary (the tooltip shows only the base).
var science_breakdown: Dictionary = {}

# --- THE LABOUR ---
# The labour = the rate of the work of the city. 1 citizen = 1 labour/sec.
# It is NOT accumulated, it is a rate, and not a stock.
func get_total_labor() -> float:
    return float(total_population) * 1.0

signal city_updated()
signal research_completed(tech_id: String)
signal research_error(message: String)
signal population_changed(new_population: int)
# The treasury has changed: new_total is the current whole number of the coins.
signal treasury_changed(new_total: int)
signal building_construction_started(building_id: String, build_key: String)
signal building_construction_completed(building_id: String, build_key: String)
# The upgrade of a built building has been started: idx is the index of the building in
# city_built_buildings, upgrade_to is the id of the improved version.
signal building_upgrade_started(idx: int, upgrade_to: String, build_key: String)

func setup():
    city_storage.clear()
    city_quality_detail.clear()
    production_rates.clear()
    consumption_rates.clear()
    city_food_pool.clear()
    market_consumption_enabled.clear()
    consumption_priority.clear()
    market_consumption_rates.clear()
    market_consumption_accum.clear()
    market_consumption_snapshot.clear()
    city_built_buildings.clear()
    improvement_planned_production.clear()
    improvement_planned_consumption.clear()
    building_construction.clear()
    domesticated_animals.clear()
    domesticated_plants.clear()
    domesticated_resources.clear()
    unlocked_technologies.clear()
# Crop farming is always available at the start of the game
    unlocked_technologies.append("farming")
    current_research_tech_id = ""
    current_research_science_cost = 0
    research_progress = 0.0
    research_science_accumulated = 0.0
    science_buildings_rate_per_sec = 0.0
    science_breakdown = {}
    current_era_index = 0
    last_research_messages = []
    city_name = ""

    # The starting treasury is from data/game_balance.json (the field initial_treasury).
    treasury = int(GameData.game_balance.get("initial_treasury", 10))
    # The tracking of the incomes/expenses for the tooltip "Treasury": a one-off transaction at the
    # start of the game is impossible, but the snapshots of the previous window could have remained from
    # the previous session/save — we clear them.
    treasury_income_accum.clear()
    treasury_income_product_accum.clear()
    treasury_expense_accum.clear()
    treasury_income_snapshot.clear()
    treasury_income_product_snapshot.clear()
    treasury_expense_snapshot.clear()
    treasury_window_length_sec = DEFAULT_TREASURY_WINDOW_SEC

    total_population = 1
    idle_population = 1 # one citizen, while he is busy nowhere

    for pid in GameData.products.keys():
        city_storage[pid] = 0
        city_quality_detail[pid] = {}
        production_rates[pid] = 0
        consumption_rates[pid] = 0
        if GameData.products[pid].get("category") == "food":
            city_food_pool[pid] = true

    if city_storage.has("meat"):
        city_storage["meat"] = 10
        # The starting meat — of the ordinary quality.
        if not city_quality_detail.has("meat"):
            city_quality_detail["meat"] = {}
        city_quality_detail["meat"]["common"] = city_quality_detail["meat"].get("common", 0) + 10

func reset_counters():
    # The actual counters of the production/consumption for the tick: they are used for
    # the determination of the famine (_check_population_change) and the TopBar
    # (city_ui._update_food_label). They live exactly one tick of the simulation.
    production_rates.clear()
    consumption_rates.clear()
    # The planned release/consumption of the improvements is the cache of the current tick (it is filled
    # from main_map.gd), it lives exactly one tick of the simulation, as well as the actual
    # counters.
    improvement_planned_production.clear()
    improvement_planned_consumption.clear()
    # The fact of the consumption on the internal market for the tick (the tab "Trade") —
    # such a counter for one tick, as the two above.
    market_consumption_rates.clear()

# --- THE TREASURY OF THE CITY ---
# Adds the coins to the treasury. The treasury is always a whole number of coins: amount must be
# a whole number (the profit of the internal market is counted from the rounded price of a unit,
# see get_internal_market_price). It emits treasury_changed for the update of the UI.
func add_treasury(amount: int) -> void:
    if amount == 0:
        return
    treasury += amount
    emit_signal("treasury_changed", treasury)

# Writes off the coins from the treasury (the payment of the scouting, of the claiming of a chunk and so on).
# It returns false and writes off NOTHING, if there are not enough coins: the treasury never
# goes into the minus, and the caller itself shows the player the reason of the refusal.
# A non-positive amount is a "free" action: we count it as successful.
func spend_treasury(amount: int) -> bool:
    if amount <= 0:
        return true
    if treasury < amount:
        return false
    treasury -= amount
    emit_signal("treasury_changed", treasury)
    return true

# --- THE TAXES ---
# Every citizen pays the base tax into the treasury for EVERY tick of the simulation
# (the value is base_tax_per_citizen in data/game_balance.json). The single point of
# the collection is collect_taxes(), it is called by do_tick().
# In the breakdown of the treasury the tax is still ONE, therefore it is not distributed by the
# sources/products, but is drawn by one row under the type TAX_INCOME_TYPE
# (see TREASURY_FLAT_TYPE_KEY and ui_helpers.show_treasury_tooltip).
#
# Here it is IMPORTANT: both constants store the ENGLISH text, because tr() cannot be
# called in the expression of a constant. The translation is applied at the point of the drawing —
# ui_helpers wraps the label in tr() (see show_treasury_tooltip). In this way the keys
# remain the same in any language, and a change of the language does not require a rebuild
# of the accumulators of the treasury.
const TAX_INCOME_TYPE: String = "Taxes"
# The source of the tax in the FLAT accumulator of the incomes (treasury_income_accum ->
# treasury_income_snapshot, see record_treasury_income). A separate name — so that
# the collection of the taxes is not mixed with the market income from "All citizens" in the flat
# accumulator (the hierarchical breakdown of the tooltip does not read the flat snapshot).
const TAX_INCOME_SOURCE: String = "Poll tax"
# The top-level type in the breakdown of the treasury: the income from the internal market. For the same
# reason as TAX_INCOME_TYPE, it stores the English text and is translated in
# ui_helpers.show_treasury_tooltip. Previously this key was obtained by the call
# tr("Population consumption") right in worker_manager, and it changed together with the
# language — in the middle of the accumulation window the old and the new key would not have matched.
const POPULATION_INCOME_TYPE: String = "Population consumption"

# The base tax from one citizen for one tick of the simulation
# (data/game_balance.json, the field base_tax_per_citizen).
func get_base_tax_per_citizen() -> int:
    return int(GameData.game_balance.get("base_tax_per_citizen", 2))

# The tax income for one tick of the simulation: the base tax × the population.
# The single source of truth for the collection (collect_taxes) and for the row "Taxes" in the
# tooltip of the treasury (worker_manager._fill_tax_income).
func get_tax_income_per_tick() -> int:
    return get_base_tax_per_citizen() * total_population

# The collection of the taxes for the tick: every citizen pays the base tax into the treasury.
# It returns the actually collected amount (0 — there is no one to pay).
func collect_taxes() -> int:
    var amount: int = get_tax_income_per_tick()
    if amount <= 0:
        return 0
    add_treasury(amount)
    record_treasury_income(TAX_INCOME_SOURCE, amount)
    return amount

# --- THE BREAKDOWN OF THE TREASURY BY THE SOURCES (for the tooltip) ---
# The sources of the profit/expense of the treasury are assembled in the tooltip on hover over
# "Treasury: N" in the HUD of the map and in the top bar of the interface of the city
# (see show_treasury_tooltip in ui_helpers.gd). The behaviour is separate for the two
# sides of the balance:
#   * The profit — a continuous flow from the consumption on the internal market
#     (worker_manager.get_planned_treasury_income_map): it is counted from
#     planned_consumption_map × internal_market_price. An analogue of "Production
#     (planned)" on the tab "Resources" — evenly and without flickering.
#   * The expenses — the event-based transactions of the player (the scouting, the claiming of a chunk, the return
#     on the refusal of a build). The automatic expense into the treasury has no planned
#     rate — these are the one-off amounts per click, therefore the tooltip shows
#     the fact over the LATEST display window (by default 3 seconds), and not
#     "/sec". The window is reset once per `treasury_window_length_sec` next to
#     the resource era (see tick_resource_display), so that the tooltip is stable,
# and it did not flicker on every tick.
#
# The snapshots (`treasury_*_snapshot`) store the data of the past window, the tooltip reads
# them. The current tick (after the next change of the era) is in `treasury_*_accum`, these
# counters are filled from record_treasury_income/_expense and are reset into
# the snapshot in rotate_treasury_window().
var treasury_income_accum: Dictionary = {}
var treasury_income_product_accum: Dictionary = {}
var treasury_expense_accum: Dictionary = {}
var treasury_income_snapshot: Dictionary = {}
var treasury_income_product_snapshot: Dictionary = {}
var treasury_expense_snapshot: Dictionary = {}
var treasury_window_length_sec: float = 3.0

# The marker of the "FLAT" type of income in the breakdown of the treasury. An ordinary type is expanded
# by three levels (the type → the source → the product), and a type under whose key there is
# { "rate": float, "label": String }, the tooltip draws by ONE row:
#   • Taxes: 2 × 3 people = 6 / sec
# It is needed for the incomes without a goods breakdown — at the moment these are the taxes (the tax is one,
# there is nothing to divide it into the sources/products). The rate itself is appended by
# the renderer (ui_helpers.show_treasury_tooltip), the "label" is the right part before the "=".
const TREASURY_FLAT_TYPE_KEY: String = "@flat"

# Records the income of the treasury by the source (it is accumulated in the current window). The calls
# are next to add_treasury in the places of the actual replenishment of the treasury (see callers).
# source_id is the identifier of the source, and not its label: "@prof:fisherman",
# "@bld:bakery" (see GameData.get_source_display_name). The key of the accumulator must not
# depend on the language — LocalizationManager.set_locale re-reads the data,
# but does not reset the accumulators, and the translated key would diverge from the old one.
func record_treasury_income(source_id: String, amount: int, product_id: String = "") -> void:
    if amount == 0 or source_id.is_empty():
        return
    treasury_income_accum[source_id] = int(treasury_income_accum.get(source_id, 0)) + amount
    if not product_id.is_empty():
        if not treasury_income_product_accum.has(source_id):
            treasury_income_product_accum[source_id] = {}
        var source_products: Dictionary = treasury_income_product_accum[source_id]
        source_products[product_id] = int(source_products.get(product_id, 0)) + amount

# Records the expense of the treasury by the source (it is accumulated in the current window).
# The calls are next to spend_treasury in the places of the actual write-off. The signed amount:
#   amount > 0 — the gross expense (the spending);
#   amount < 0 — the return (refund) into THE SAME source: it is recorded into the accumulated
#                 amount of this source (a negative record is subtracted).
#                 See expansion_manager.handle_action as an example: the gross +
#                 refund in one pair gives the net expense in the snapshot.
#   amount == 0 — a no-op (it is discarded).
# The return is recorded inside the source, because a return does not fit into
# any type of income of the hierarchical breakdown (there is only the "Consumption of
# the population" and the future "Taxes"/"Trade"). If in the snapshot the source
# has turned out to have net <= 0 (only the returns without a compensating spending), the tooltip
# does not show it — for the player this is equivalent to the absence of the expense.
func record_treasury_expense(source_id: String, amount: int) -> void:
    if amount == 0 or source_id.is_empty():
        return
    treasury_expense_accum[source_id] = int(treasury_expense_accum.get(source_id, 0)) + amount

# Resets the current window into the "past" and zeroes the accumulators. It is called once
# per `treasury_window_length_sec` next to the change of the era of the display of the resources
# (see tick_resource_display). The tooltip always reads the snapshot — the data of the past
# complete window; in this way the new accumulations of the current window do not "jump" on every tick
# of the update.
func rotate_treasury_window() -> void:
    treasury_income_snapshot = treasury_income_accum.duplicate()
    treasury_income_product_snapshot = treasury_income_product_accum.duplicate(true)
    treasury_expense_snapshot = treasury_expense_accum.duplicate()
    treasury_income_accum.clear()
    treasury_income_product_accum.clear()
    treasury_expense_accum.clear()

# The duration of the window in seconds. By default 3 sec — shorter than the minimum possible
# interval of the display of the resources (1 sec), but sufficient to capture the one-off
# transactions of the scouting/claiming without smearing the fact.
const DEFAULT_TREASURY_WINDOW_SEC: float = 3.0

# --- THE DYNAMICS OF THE TREASURY FOR THE ROW "Treasury: N [+X / -Y]" (the HUD of the map and the top
# bar of the city) ---
# The actual rates of the profit and the expense in COINS/SECOND by the data of the same
# Until the first window has finished, the snapshots are empty — we take the current accumulators
# (exactly as worker_manager.get_actual_treasury_income_map). Otherwise in the first
# seconds after the start/loading the row would show "+0 / -0" with a going
# income.
func get_treasury_flow_per_sec() -> Dictionary:
    var income_map: Dictionary = treasury_income_snapshot
    if income_map.is_empty():
        income_map = treasury_income_accum
    var expense_map: Dictionary = treasury_expense_snapshot
    if expense_map.is_empty():
        expense_map = treasury_expense_accum
    var window_sec: float = treasury_window_length_sec
    if window_sec <= 0.0:
        return {"income": 0.0, "expense": 0.0}
    var income := 0.0
    for source_id in income_map:
        income += float(int(income_map[source_id]))
    # The expense — only the positive net by the source: the return on the refusal
    # of the claiming is recorded as a minus in the same source, and for the player it is equal to
    # "there was no expense" (the same rule as in the renderer of the breakdown tooltip).
    var expense := 0.0
    for source_id in expense_map:
        var amount := int(expense_map[source_id])
        if amount > 0:
            expense += float(amount)
    return {
        "income": maxf(income, 0.0) / window_sec,
        "expense": expense / window_sec,
    }

# The text of the dynamics for the row "Treasury": "[+123≈ / -456≈]". Both numbers are the fact over the
# last window, recalculated per second, therefore they are marked with "≈": the same
# marker as on the tab "Resources" and in the footer of the tooltip of the treasury.
func get_treasury_flow_text() -> String:
    var flow: Dictionary = get_treasury_flow_per_sec()
    return "[+%s≈ / -%s≈]" % [
        _format_treasury_rate(float(flow.get("income", 0.0))),
        _format_treasury_rate(float(flow.get("expense", 0.0))),
    ]

# The format of the rate is as ui_helpers._format_rate: a whole number without the fractional part,
# otherwise one decimal (we do not round 0.3 coins/sec to zero).
func _format_treasury_rate(value: float) -> String:
    if is_equal_approx(value, round(value)):
        return str(int(round(value)))
    return "%.1f" % value

# Returns the price at which the internal market buys a unit of the goods pid from the city
# (in the coins of the treasury). It is a share of the base price of the goods (price from
# data/products/*.json), set by the multiplier internal_market_price_multiplier
# in data/game_balance.json, with the rounding
# to the nearest whole number. It returns 0 for the goods without a price.
#
# quality_id is the level of the quality of the unit being WRITTEN OFF (""/"common" — the ordinary one):
# the price is multiplied by the multiplier of the quality (data/qualities.json,
# price_multiplier) and is rounded to a whole number again, therefore the coins are always
# whole, and the internal market buys a good goods more expensively.
# The income of the treasury for the actually written off units of the goods taking the QUALITY of each
# unit into account. consumed is the breakdown {quality: count} which
# remove_from_storage() returned: the price is counted by each level separately, therefore
# a mixed storage brings more than count × the price of the ordinary quality.
# An empty breakdown (there was nothing to write off) — the income is 0.
func get_internal_market_price(pid: String, quality_id: String = "") -> int:
    var prod = GameData.products.get(pid, {})
    var base_price = float(prod.get("price", 0))
    if base_price <= 0.0:
        return 0
    var mult = float(GameData.game_balance.get("internal_market_price_multiplier", 1.0))
    var market_base := int(round(base_price * mult))
    return int(round(float(market_base) * GameData.get_quality_price_multiplier(quality_id)))

# The average multiplier of the price by the quality, weighted by the breakdown of the storage
# (city_quality_detail). It is needed where the quality of the future deal is unknown —
# above all for the PLANNED income of the treasury in the tooltip: the plan by the ordinary
# quality would systematically underestimate the fact, if there is a good goods in the storage.
# Without a breakdown (an old save, an empty storage) — 1.0.
func get_stock_quality_price_multiplier(pid: String) -> float:
    var detail: Dictionary = city_quality_detail.get(pid, {})
    var total := 0
    var weighted := 0.0
    for qid in detail:
        var count := int(detail[qid])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * GameData.get_quality_price_multiplier(str(qid))
    if total <= 0:
        return 1.0
    return weighted / float(total)

# --- THE RECORDING OF THE FACT FOR THE TICK ---
# These helpers update the actual counters of the production/consumption for the tick
# (production_rates / consumption_rates). They are used for the determination of the famine
# (_check_population_change) and the TopBar (city_ui._update_food_label).
# The breakdown by the sources (production_sources / consumption_sources) used to be
# shown in the tooltip of the tab "Resources", but after the commit 5790016
# the tooltip displays only the planned production/consumption, therefore
# the breakdown is no longer maintained — only the total rates remained.
#
# The parameter source_id is kept in the signature for compatibility with the callers
# (main_map.gd, worker_manager.gd); it is not written anywhere.

# The public helper of the recording of the FACT of the production for the tick. It is used from
# main_map.gd and do_tick().
#   source_id is the identifier of the source (see GameData.get_source_display_name:
#   "@prof:fisherman", "@bld:bakery", "@imp:farm", "@pop_food"). It is the key
#   of the accumulator, and not a label: the label is resolved in ui_helpers at the drawing.
func record_production_source(pid: String, _source_id: String, amount: int):
    production_rates[pid] = production_rates.get(pid, 0) + amount

# The public helper of the recording of the FACT of the consumption for the tick. It is used from
# main_map.gd, worker_manager.gd and do_tick(). source_id is the identifier
# of the source (see GameData.get_source_display_name), and not a label.
func record_consumption_source(pid: String, _source_id: String, amount: int):
    consumption_rates[pid] = consumption_rates.get(pid, 0) + amount

# --- THE INTERNAL MARKET: THE RESOLUTION AND THE PRIORITY OF THE WRITE-OFF ---
# The whole section works with the DISPLAY_KEY (see the description of the dictionaries above):
# the id of a single product, or an "@group". An empty key is a no-op: it cannot
# address anything, and a silently swallowed click on a non-existent row
# would be worse than an explicit ignore.

# Is the consumption of the resource on the internal market allowed. The absence of the key —
# allowed (the market is open by default).
func is_market_consumption_enabled(display_key: String) -> bool:
    if display_key.is_empty():
        return true
    return bool(market_consumption_enabled.get(display_key, true))

# Allows/forbids the consumption. The forbidding means a complete absence of
# the write-off: worker_manager does not write off the resource from the storage, does not pay into the
# treasury and does not give the bonus of the production by this record (see
# worker_manager._aggregate_production_bonus).
func set_market_consumption_enabled(display_key: String, value: bool) -> void:
    if display_key.is_empty():
        return
    market_consumption_enabled[display_key] = value

# The switch of the toggle of "Trade". It returns the new state, so that
# the calling side (the card) immediately updates both variant-buttons.
func toggle_market_consumption_enabled(display_key: String) -> bool:
    var new_value := not is_market_consumption_enabled(display_key)
    set_market_consumption_enabled(display_key, new_value)
    return new_value

# The priority of the write-off by quality. The absence of the key — the default from the data
# (data/qualities.json, priority_default). A value which is not in the list
# of the options (a corrupted save, the rule was renamed) is also read as the
# default: the check lives both on the reading and on the writing, otherwise a corrupted save
# would silently break the write-off.
func get_consumption_priority(display_key: String) -> String:
    if display_key.is_empty():
        return GameData.get_quality_priority_default()
    var stored := str(consumption_priority.get(display_key, ""))
    if stored.is_empty() or not GameData.get_quality_priority_options().has(stored):
        return GameData.get_quality_priority_default()
    return stored

# Assigns the priority. An unknown value is silently replaced with the default:
# in this way a corrupted save does not break the write-off, and leads to the "best
# quality" — the safe default behaviour.
func set_consumption_priority(display_key: String, priority: String) -> void:
    if display_key.is_empty():
        return
    if not GameData.get_quality_priority_options().has(priority):
        priority = GameData.get_quality_priority_default()
    consumption_priority[display_key] = priority

# Cyclically switches the priority (best → worst → random → best) and
# returns the new value. The order and the set are from data/qualities.json
# (get_quality_priority_options), the same cycle as at the button of the priority of the
# quality of a building (see building_panel._on_quality_priority_pressed).
func cycle_consumption_priority(display_key: String) -> String:
    var options: Array = GameData.get_quality_priority_options()
    if options.is_empty():
        return get_consumption_priority(display_key)
    var current := get_consumption_priority(display_key)
    var idx: int = options.find(current)
    if idx < 0:
        # The current value is not from the list (an old save) — we start the cycle
        # from the first variant, and not from the unpredictable position -1.
        idx = 0
    var new_priority := str(options[(idx + 1) % options.size()])
    set_consumption_priority(display_key, new_priority)
    return new_priority

    # the quality of the consumed raw material, rounded to the nearest level.
    # It assembles the flat breakdown of the consumed raw material by the quality from the container
func record_market_consumption(pid: String, amount: int) -> void:
    if amount <= 0:
        return
    market_consumption_rates[pid] = int(market_consumption_rates.get(pid, 0)) + amount
    # The same fact is accumulated into the display window: the tick counter goes out in
    # reset_counters(), and the card of "Trade" needs a fact which survives
    # the display interval from the settings (see market_consumption_accum).
    market_consumption_accum[pid] = int(market_consumption_accum.get(pid, 0)) + amount

# Resets the window of the fact of the consumption of the market into the "past" and zeroes
# the accumulator. It is called next to rotate_treasury_window (see
# tick_resource_display). Until the first window has finished, the snapshot is empty —
# get_market_consumption_per_sec() takes the current accumulator, so that the row
# does not show "0" with a going consumption.
func rotate_market_consumption_window() -> void:
    market_consumption_snapshot = market_consumption_accum.duplicate()
    market_consumption_accum.clear()

# The fact of the consumption on the internal market in units PER SECOND over the past
# display window: product_id -> units/sec. The window is not shorter than the tick of the simulation
# (the minimum is 1 sec), therefore over the window the fact always exists.
func get_market_consumption_per_sec() -> Dictionary:
    var source: Dictionary = market_consumption_snapshot
    if source.is_empty():
        source = market_consumption_accum
    if source.is_empty() or resource_display_interval <= 0.0:
        return {}
    var result: Dictionary = {}
    for pid in source:
        var amount := int(source[pid])
        if amount > 0:
            result[str(pid)] = float(amount) / resource_display_interval
    return result

# --- THE PLANNED DEMAND OF THE BUILDINGS (for "Consumption (planned)" on the tab "Resources") ---
# The cache of the reference to TownsfolkManager: it is needed by do_tick(), and by the counting of the demand of the buildings.
# It is looked up once and reused (is_instance_valid — in case the node is deleted).
var _townsfolk_ref: Node = null

func _get_townsfolk() -> Node:
    if _townsfolk_ref != null and is_instance_valid(_townsfolk_ref):
        return _townsfolk_ref
    # The node can be outside the tree (the tests call the counters directly, before
    # adding the scene) — then there is nothing to look up, and null is the right answer.
    if not is_inside_tree():
        return null
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map:
        _townsfolk_ref = main_map.get_node_or_null("TownsfolkManager")
    return _townsfolk_ref

# The cache of the reference to WorkerManager: it is needed by the planned production of the buildings (the bonus
# of the profession of the citizen) and by the tick of the consumption — symmetrically _get_townsfolk().
var _worker_manager_ref: Node = null

func _get_worker_manager() -> Node:
    if _worker_manager_ref != null and is_instance_valid(_worker_manager_ref):
        return _worker_manager_ref
    # See _get_townsfolk: outside the tree there is nothing to look up.
    if not is_inside_tree():
        return null
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map:
        _worker_manager_ref = main_map.get_node_or_null("WorkerManager")
    return _worker_manager_ref

# The number of WORKING citizens by the professions: prof_id -> count. The profession is taken
# from the building (the field "profession" in data/buildings.json). Only the buildings
# where there is a citizen AND at least one non-empty slot are taken into account: an idle
# building does not spend the supplies, therefore its expense does not enter the plan
# (see worker_manager.get_planned_consumption_map).
func get_townsfolk_professions_count() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    if tm == null:
        return result
    for i in range(city_built_buildings.size()):
        if not tm.has_townsfolk(i):
            continue
        if are_all_slots_empty(i):
            continue
        var prof: String = tm.get_profession(i)
        if prof.is_empty():
            continue
        result[prof] = int(result.get(prof, 0)) + 1
    return result

# Returns the planned demand of the BUILT buildings for the resources per one crafting of the
# recipe. The recipe in do_tick() is executed once per `time` seconds with a citizen assigned
# and the ingredients present, therefore the demand goes together with the time of the
# recipe (interval, seconds). The format of the result:
#   product_id -> { "The name of the building" -> { "amount": N, "interval": float,
#   amount   is the total demand of this building for the resource per one crafting of the slots;
#   interval is the time of the crafting, in seconds (with several slots of the building with a different
#              time the minimum is taken — as for the professions in
#              worker_manager.get_planned_consumption_map); 0 is "per tick"
#              (a recipe without the field time);
#   count  is how many slots-recipes give this demand (for the "xN" in the tooltip);
#   is_group / group_name is the demand set by the group "@": it refers to ANY member
#   of the group, in the tooltip it is marked by the name of the group.
# The demand is shown regardless of the presence of the ingredients in the storage — this is the
# planned consumption (the need), and not the fact; the fact is counted by do_tick().
func get_building_planned_consumption() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Without a citizen the building does not work and consumes nothing.
        if tm == null or not tm.has_townsfolk(i):
            continue
        # The identifier of the building is the source of the demand (it coincides with the source of
        # the actual expense in do_tick, so that in the tooltip it is the same
# the same subject). The label is resolved in ui_helpers by the id.
        var building_source = GameData.building_source_id(str(bld.get("id", "")))
        for recipe_id in slots:
            if recipe_id == "" or recipe_id == "empty":
                continue
            var recipe = get_craft_by_id(recipe_id)
            if recipe.is_empty():
                continue
            # The time of the crafting of the slot is the unit of measurement of the planned demand.
            var craft_time := get_craft_time(recipe)
            var resources: Dictionary = recipe.get("resources", {})
            for res in resources:
                var amount_needed = int(resources[res])
                if amount_needed <= 0:
                    continue
                if res.begins_with("@"):
                    # A group resource: the demand refers to any member of the group.
                    # The key of the "@"-group is always the id from product_groups.json.
                    var group_key = res.trim_prefix("@")
                    var group_products = GameData.product_groups.get(group_key, [])
                    if group_products.is_empty():
                        continue
                    var group_name = GameData.get_product_group_name(res)
                    for prod in group_products:
                        _record_planned_demand(result, prod, building_source, amount_needed, true, group_name, craft_time)
                else:
                    _record_planned_demand(result, res, building_source, amount_needed, false, "", craft_time)
    return result

# The helper of the recording of the demand of a building for a resource (see get_building_planned_consumption).
# interval is the time of the crafting of the recipe, in seconds (0 is "per tick"); with several
# records of one source the minimum is taken — as for the professions in
# worker_manager._record_planned_entry.
func _record_planned_demand(result: Dictionary, pid: String, source_id: String, amount: int, is_group: bool, group_name: String, interval: float):
    if not result.has(pid):
        result[pid] = {}
    var by_source: Dictionary = result[pid]
    if not by_source.has(source_id):
        by_source[source_id] = {"amount": 0, "count": 0, "is_group": false, "group_name": "", "interval": interval}
    var entry: Dictionary = by_source[source_id]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["count"] = int(entry.get("count", 0)) + 1
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)
    entry["is_group"] = bool(entry.get("is_group", false)) or is_group
    if str(entry.get("group_name", "")) == "":
        entry["group_name"] = group_name

# Returns the planned production of the BUILT BUILDINGS per one crafting of the recipe
# (mirrored to the demand of the buildings: the recipe in do_tick() gives result once per `time`
# seconds with a citizen and the ingredients present). The format of the result:
#   product_id -> { "The name of the building" -> { "amount": N, "interval": float, "count": M } }
#   amount   is the total output of this building per one crafting (over all the slots);
#   interval is the time of the crafting, in seconds (min over the slots of the building; 0 is "per tick");
#   count    is how many slots-recipes give this output (for the "xN" in the tooltip).
# The plan is shown regardless of the presence of the ingredients — this is the ability of the
# producer, and not the fact; the fact is counted by do_tick().
func get_building_planned_production() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    # The multiplier of the profession of the citizen (worker_manager.get_building_production_bonus)
    # — so that the planned label "≈" coincides with the actual output.
    var wm = _get_worker_manager()
    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Without a citizen the building does not work and produces nothing.
        if tm == null or not tm.has_townsfolk(i):
            continue
        # The bonus of the profession: 1.0 without a profession or without the supplies, otherwise
        # 1.0 + the bonuses (see worker_manager._aggregate_production_bonus).
        # An idle building (all the slots are empty) receives no bonus.
        var prof_multiplier := 1.0
        if wm != null and not are_all_slots_empty(i):
            prof_multiplier = wm.get_building_production_bonus(i)
        # The identifier of the building is the source of the output (it coincides with the source of
        # the actual production in do_tick, so that in the tooltip it is one and
        # the same subject).
        var building_source = GameData.building_source_id(str(bld.get("id", "")))
        for recipe_id in slots:
            if recipe_id == "" or recipe_id == "empty":
                continue
            var recipe = get_craft_by_id(recipe_id)
            if recipe.is_empty():
                continue
            # The time of the crafting of the slot is the unit of measurement of the planned output.
            var craft_time := get_craft_time(recipe)
            var production: Dictionary = recipe.get("result", {})
            for res in production:
                var amount = int(production[res])
                if amount <= 0:
                    continue
                # The bonus of the profession is applied to the output of the recipe — as the multiplier
                # of the production at the improvements on the map.
                if prof_multiplier != 1.0:
                    amount = int(round(float(amount) * prof_multiplier))
                    if amount <= 0:
                        continue
                _record_planned_supply(result, res, building_source, amount, craft_time)
    return result

# The helper of the recording of the output of a building (see get_building_planned_production).
# interval is the time of the crafting of the recipe, in seconds (0 is "per tick"); with several
# records of one source the minimum is taken.
func _record_planned_supply(result: Dictionary, pid: String, source_id: String, amount: int, interval: float):
    if not result.has(pid):
        result[pid] = {}
    var by_source: Dictionary = result[pid]
    if not by_source.has(source_id):
        by_source[source_id] = {"amount": 0, "count": 0, "interval": interval}
    var entry: Dictionary = by_source[source_id]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["count"] = int(entry.get("count", 0)) + 1
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)

# The entry point of the planned production: the recipes of the buildings (interval = time of the recipe,
# 0 is "per tick") + the improvements on the map (interval = production_interval of the improvement,
# see get_improvement_production_interval). The plan is needed, because in
# the continuous model (see main_map._emit_continuous_production and CraftContainer)
# the output goes on every tick a little bit, and the label of the dynamics `[+N≈]` shows
# the average per_sec — that is enough for the UI of the tab "Resources". The records
# are filled from main_map.gd on every tick of the simulation.
func get_planned_production_map() -> Dictionary:
    var result := get_building_planned_production()
    for pid in improvement_planned_production:
        if not result.has(pid):
            result[pid] = {}
        var by_source: Dictionary = result[pid]
        for source_id in improvement_planned_production[pid]:
            var src: Dictionary = improvement_planned_production[pid][source_id]
            if not by_source.has(source_id):
                by_source[source_id] = {"amount": 0, "count": 0, "interval": float(src.get("interval", 0.0))}
            var entry: Dictionary = by_source[source_id]
            entry["amount"] = int(entry.get("amount", 0)) + int(src.get("amount", 0))
            entry["count"] = int(entry.get("count", 0)) + int(src.get("count", 1))
            entry["interval"] = minf(float(entry.get("interval", 0.0)), float(src.get("interval", 0.0)))
    return result

# --- THE PLANNED PRODUCTION OF THE IMPROVEMENTS ON THE MAP ---
# The cache of the planned output of the improvements for the current tick of the simulation:
#   product_id -> { "The name of the improvement" -> { "amount": N, "interval": float, "count": M } }
#   amount   is the total output of the improvement per ONE cycle (over all the hexes);
#   interval is production_interval of the improvement, in seconds;
#   count    is how many hexes with this improvement are working (for the "xN" in the tooltip).
# It is filled from main_map.gd on every tick, it is cleared in reset_counters()
# together with the actual counters. The save is not affected — the plan is always
# computed from the current data.
var improvement_planned_production: Dictionary = {}

# The time of one production cycle of the improvement imp_id in seconds — the field
# "production_interval" from data/improvements.json. The field is absent, or <= 0 —
# the improvement releases the product on every tick of the simulation (the old data).
func get_improvement_production_interval(imp_id: String) -> float:
    var interval: float = float(GameData.improvements.get(imp_id, {}).get("production_interval", 0.0))
    if interval <= 0.0:
        return SIMULATION_TICK
    return interval

# The record of the planned output of the improvement per one cycle (it is called from main_map.gd
# for each working improvement on each tick of the simulation).
func record_planned_improvement_production(pid: String, source_id: String, amount: int, interval: float):
    _record_cycle_entry(improvement_planned_production, pid, source_id, amount, interval)

# --- THE PLANNED CONSUMPTION OF THE IMPROVEMENTS ON THE MAP (the feed of the pastures) ---
# The feed (the feed_consumption of the resource) is written off continuously (see
# main_map._consume_feed_continuous), and in the plan the average expense per
# the production cycle is given — for the UI of the tab "Resources" (mirrored to the planned
# output). It is filled from main_map.gd on every tick, it is cleared in
# reset_counters().
var improvement_planned_consumption: Dictionary = {}

# The record of the planned consumption of the improvement per one cycle (it is called from main_map.gd).
func record_planned_improvement_consumption(pid: String, source_id: String, amount: int, interval: float):
    _record_cycle_entry(improvement_planned_consumption, pid, source_id, amount, interval)

# The cache of the planned consumption of the improvements for the merge in the tab "Resources"
# (worker_manager.get_planned_consumption_map knows only about the professions,
# the city "all" and the demand of the buildings).
func get_improvement_planned_consumption() -> Dictionary:
    return improvement_planned_consumption

# The common helper of the recording of a cyclic record (the output or the consumption of an improvement):
# amount is summed up, count is the number of the hexes-sources, interval is the minimum.
func _record_cycle_entry(cache: Dictionary, pid: String, source_id: String, amount: int, interval: float):
    if pid.is_empty() or amount <= 0:
        return
    if not cache.has(pid):
        cache[pid] = {}
    var by_source: Dictionary = cache[pid]
    if not by_source.has(source_id):
        by_source[source_id] = {"amount": 0, "count": 0, "interval": interval}
    var entry: Dictionary = by_source[source_id]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["count"] = int(entry.get("count", 0)) + 1
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)

# Returns the human-readable name of the building by its id (or the id itself, if the building
# is not found in the registry). The single place of the knowledge about it is GameData.
func get_building_name(building_id: String) -> String:
    return GameData.get_building_display_name(building_id)

# --- THE HELPERS FOR WORKING WITH THE QUALITY OF THE RESOURCES ---
# city_storage stores the total amount, city_quality_detail is the breakdown by quality.
# All the operations of the addition/write-off must go through these helpers, so that
# the sum over the details always coincides with city_storage.

# Returns the breakdown by quality for the product (a dictionary {quality: count}).
# If there is no breakdown (an old save), it returns an empty dictionary.
func get_quality_breakdown(pid: String) -> Dictionary:
    return city_quality_detail.get(pid, {})

# Returns the total amount of the product in the storage.
func get_storage_amount(pid: String) -> int:
    return city_storage.get(pid, 0)

# Adds amount units of the product pid of the specified quality.
# It synchronously updates city_storage and city_quality_detail.
func add_to_storage(pid: String, amount: int, quality: String = "common"):
    if amount <= 0:
        return
    city_storage[pid] = city_storage.get(pid, 0) + amount
    if not city_quality_detail.has(pid):
        city_quality_detail[pid] = {}
    var detail: Dictionary = city_quality_detail[pid]
    detail[quality] = detail.get(quality, 0) + amount

# Decreases the total amount of the product pid by amount units.
# It writes off by the priority of the quality (best/worst/random) and returns
# the breakdown of what has actually been written off: {quality: count}.
# If the priority is not specified, "best" is used.
func remove_from_storage(pid: String, amount: int, priority: String = "best") -> Dictionary:
    if amount <= 0:
        return {}
    var available = city_storage.get(pid, 0)
    var to_remove = min(amount, available)
    var consumed = _consume_quality_detail(pid, to_remove, priority)
    city_storage[pid] = available - to_remove
    return consumed

# Writes off amount units from the breakdown by quality according to the priority.
# It returns a dictionary {quality: count} of what has actually been written off.
func _consume_quality_detail(pid: String, amount: int, priority: String) -> Dictionary:
    var detail: Dictionary = city_quality_detail.get(pid, {})
    if detail.is_empty():
        # There is no breakdown (an old save) — we count everything as "common".
        return {"common": amount}

    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return {"common": amount}

    var consumed = {}
    var remaining = amount

    # We determine the order of the write-off of the levels of the quality.
    var order = []
    if priority == "worst":
        order = levels.duplicate() # from the worst to the best
    elif priority == "random":
        order = levels.duplicate()
        order.shuffle()
    else: # "best" and by default — from the best to the worst
        order = levels.duplicate()
        order.reverse()

    for qid in order:
        if remaining <= 0:
            break
        var available = detail.get(qid, 0)
        if available <= 0:
            continue
        var take = min(available, remaining)
        detail[qid] = available - take
        consumed[qid] = consumed.get(qid, 0) + take
        remaining -= take

    # If something has remained (for example, the breakdown is incomplete) — we write it off as common.
    if remaining > 0:
        consumed["common"] = consumed.get("common", 0) + remaining

    return consumed

# Returns the level of the quality corresponding to the weighted average
# by the breakdown consumed (a dictionary {quality: count}).
# It is used on the production: the quality of the result = the weighted average,
# The time of one crafting of the recipe in seconds. The field time is absent, or <= 0 —
# the recipe behaves as before: the crafting on every tick of the simulation.
# of the crafting: for each slot of the ingredients it goes through the accumulated "inputs"
# (consumed) and sums them into a single dictionary {quality: count}.
# It is used on the completion of the crafting for the calculation of the quality of the result —
# a direct analogue of consumed_all in the old batch logic.
func _collect_container_quality(container: CraftContainer) -> Dictionary:
    var out := {}
    if container == null:
        return out
    for slot in container.ingredient_slots:
        for entry in slot.get("consumed", []):
            var qty = int(entry.get("qty", 0))
            var qid = str(entry.get("quality", "common"))
            if qty <= 0:
                continue
            out[qid] = int(out.get(qid, 0)) + qty
    return out

func quality_from_breakdown(consumed: Dictionary) -> String:
    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return "common"
    var total := 0
    var weighted := 0.0
    for qid in consumed:
        var count = int(consumed[qid])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * float(GameData.get_quality_value(qid))
    if total <= 0:
        return "common"
    var avg = weighted / float(total)
    # We round to the nearest level of the quality.
    var best_qid = levels[0]
    var best_diff = 1e9
    for qid in levels:
        var diff = abs(float(GameData.get_quality_value(qid)) - avg)
        if diff < best_diff:
            best_diff = diff
            best_qid = qid
    return best_qid

func add_raw_production(raw_id: String, multiplier: float = 1.0, quality: String = "common", source_id: String = ""):
    if Engine.is_editor_hint():
        return
    var raw = GameData.raw_resources.get(raw_id, {})
    if raw.has("produces"):
        for pid in raw["produces"]:
            # produces can be a number or a range [min, max] — for
            # the deterministic continuous production we take the minimum
            # of the range (see RangeUtils).
            var amount = ceili(float(RangeUtils.get_min_value(raw["produces"][pid], 1)) * multiplier)
            # We check whether this product is available (by the technology)
            if not _is_product_available(pid):
                continue
            if amount <= 0:
                continue
            # We always add to the storage and record the source (previously on the first
            # tick, when the product was not yet in city_storage, the source
            # was not recorded at all — that was the bug of the "empty tooltip on a new
            # production").
            add_to_storage(pid, amount, quality)
            if source_id != "":
                record_production_source(pid, source_id, amount)
            else:
                production_rates[pid] += amount

# --- THE TIME OF THE RECIPE (time) ---
# The recipe of a slot of a building is executed continuously: the ingredients are taken
# from the storage one by one at the calculated rate (required / time units/sec).
# The crafting is counted as completed, when ALL the ingredients have been gathered and craft_time
# seconds have passed. If there is not enough raw material — the container "freezes"
# (the time does not accumulate, the ingredients are not taken), and the crafting automatically
# is extended until the raw material appears in the storage.
# A CraftContainer is created for each slot of a building (see scripts/craft_container.gd),
# which stores the state of the filling and the list of the "inputs" with the qualities for
# the calculation of the quality of the result. The containers are serialized together with
# city_built_buildings under the key "slot_containers".
#
# The step of the simulation is SIMULATION_TICK (1 sec). The fractional remainders per tick
# accumulate in the container (the sub-unit accumulator), therefore the average rate
# does not drift (21/5 = 4.2 → we alternate 4 and 5 units).
#
# The time of one crafting of the recipe in seconds. The field time is absent, or <= 0 —
# the recipe behaves as before: the crafting on every tick of the simulation.

    # we prepare the messages for the popup (analogously to _complete_research).
func get_craft_time(recipe: Dictionary) -> float:
    var t := float(recipe.get("time", 0.0))
    if t <= 0.0:
        return SIMULATION_TICK
    return t

# Returns the data of the recipe by id (or an empty dictionary, if the recipe is not found).
func get_craft_by_id(recipe_id: String) -> Dictionary:
    for c in GameData.crafts:
        if c.get("id", "") == recipe_id:
            return c
    return {}

# --- THE SLOT CONTAINERS (continuous crafting) ---
# One CraftContainer per slot of a building. The array is created lazily and
# is fitted to the current number of the slots.
func get_slot_containers(b_index: int) -> Array:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return []
    var bld: Dictionary = city_built_buildings[b_index]
    var slots: Array = bld.get("slots", [])
    var containers = bld.get("slot_containers", null)
    if not (containers is Array):
        containers = _migrate_slot_containers(b_index, slots)
        bld["slot_containers"] = containers
    # We fit the array to the current number of the slots.
    while containers.size() < slots.size():
        containers.append(null)
    if containers.size() > slots.size():
        containers.resize(slots.size())
    # The lazy restoration of the serialized containers from the save:
    # SaveManager._serialize_buildings writes the flat dicts (JSON-compatible),
    # therefore after the loading here there are dicts, and not objects. On the first
    # access we rebuild the CraftContainer by the CURRENT recipe of the slot;
    # the incompatibility of the recipe is handled by the container itself
    # (_restore_from_slot_data merges the state by the matching ingredients).
    # Without this the typed assignment in _ensure_slot_container would fall
    # on a dict after the loading of the save.
    for i in range(mini(containers.size(), slots.size())):
        var c = containers[i]
        if c == null or c is CraftContainer:
            continue
        var recipe = get_craft_by_id(str(slots[i]))
        if recipe.is_empty():
            # The recipe of the slot is not resolved — the slot is counted as empty
            # (the same semantics as in _ensure_slot_container).
            containers[i] = null
            continue
        var saved: Dictionary = c if c is Dictionary else {}
        containers[i] = CraftContainer.new(recipe, saved)
    return containers

# Internal: creates the array of CraftContainer from the obsolete slot_progress,
# or from scratch. The progress of the obsolete timer is not carried over — those
# were just seconds, and not the occupancy of the container; a correct conversion
# is impossible without a loss of meaning, so the slot starts crafting anew.
func _migrate_slot_containers(b_index: int, slots: Array) -> Array:
    var out: Array = []
    var bld: Dictionary = city_built_buildings[b_index]
    var old_progress = bld.get("slot_progress", [])
    for slot_idx in range(slots.size()):
        var recipe_id = str(slots[slot_idx])
        if recipe_id == "" or recipe_id == "empty":
            out.append(null)
            continue
        var recipe = get_craft_by_id(recipe_id)
        if recipe.is_empty():
            out.append(null)
            continue
        # We use the saved state, if it corresponds
# to the current recipe (for the future saves in the new format).
        var saved = null
        if slot_idx < old_progress.size() and old_progress[slot_idx] is Dictionary:
            saved = old_progress[slot_idx]
        out.append(CraftContainer.new(recipe, saved if saved != null else {}))
    # We clear the obsolete key, so as not to carry it in the saves.
    bld.erase("slot_progress")
    return out

# The container of a particular slot or null, if the slot is empty / the recipe is not found.
func get_slot_container(b_index: int, slot_idx: int) -> CraftContainer:
    var containers := get_slot_containers(b_index)
    if slot_idx < 0 or slot_idx >= containers.size():
        return null
    var c = containers[slot_idx]
    if c is CraftContainer:
        return c
    return null

# Returns or creates the container of the slot, synchronising it with the current recipe.
# If the recipe in the slot has changed — it recreates the container (resetting the progress).
func _ensure_slot_container(b_index: int, slot_idx: int) -> CraftContainer:
    var containers := get_slot_containers(b_index)
    if slot_idx < 0 or slot_idx >= containers.size():
        return null
    var slots: Array = city_built_buildings[b_index].get("slots", [])
    var recipe_id = str(slots[slot_idx])
    if recipe_id == "" or recipe_id == "empty":
        containers[slot_idx] = null
        return null
    var recipe = get_craft_by_id(recipe_id)
    if recipe.is_empty():
        containers[slot_idx] = null
        return null
    var existing: CraftContainer = containers[slot_idx]
    if existing != null and existing.recipe_id == recipe_id:
        return existing
    # The recipe has changed — we recreate it.
    var fresh = CraftContainer.new(recipe)
    containers[slot_idx] = fresh
    return fresh

# The time of the crafting of the recipe in the slot of the building (0, if the slot is empty or the recipe is not found).
func get_slot_craft_time(b_index: int, slot_idx: int) -> float:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return 0.0
    var slots: Array = city_built_buildings[b_index].get("slots", [])
    if slot_idx < 0 or slot_idx >= slots.size():
        return 0.0
    var recipe_id := str(slots[slot_idx])
    if recipe_id == "" or recipe_id == "empty":
        return 0.0
    var recipe = get_craft_by_id(recipe_id)
    if not (recipe is Dictionary) or recipe.is_empty():
        return 0.0
    return get_craft_time(recipe)

# --- THE OLD UI API: get_slot_progress/get_slot_progress_value ---
# These functions return the accumulated time of the slot as craft_time * completion_ratio.
# The new model has no analogue (the container fills up, and does not "accumulate the time"),
# but the callers that still show a progress bar need exactly these values.
func get_slot_progress(b_index: int) -> Array:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return []
    var slots: Array = city_built_buildings[b_index].get("slots", [])
    var out: Array = []
    for slot_idx in range(slots.size()):
        out.append(get_slot_progress_value(b_index, slot_idx))
    return out

func get_slot_progress_value(b_index: int, slot_idx: int) -> float:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return 0.0
    return c.completion_ratio() * get_slot_craft_time(b_index, slot_idx)

# The share of the readiness of the current crafting of the slot (0..1) — for the UI of the panel of the building.
func get_slot_progress_ratio(b_index: int, slot_idx: int) -> float:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return 0.0
    return c.completion_ratio()

# The text state of the container of the slot for the UI of the panel of the building.
# An example: "8/20 (3.4 sec)" — the filling of the first ingredient + the time.
func get_slot_status_text(b_index: int, slot_idx: int) -> String:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return ""
    return c.status_text()

# Resets the container of the slot: after a change of the recipe the slot starts
# the counting of the crafting from scratch.
func reset_slot_progress(b_index: int, slot_idx: int) -> void:
    var c := get_slot_container(b_index, slot_idx)
    if c != null:
        c.reset()

func do_tick():
    if Engine.is_editor_hint():
        return

    # The contribution of the science buildings to the rate is recalculated from scratch on every tick
    # (see the block "THE RECIPE "SCIENCE"" in the loop of the buildings below). The records by the buildings
    # are collected into an intermediate list, after the loop the rate is assembled from it
    # science_breakdown.
    science_buildings_rate_per_sec = 0.0
    var science_breakdown_buildings: Array = []

    # --- The work of the buildings (only if there is a citizen) ---
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    # WorkerManager — the consumption of the supplies by the profession of the citizen
    # (tick_building_consumption) and the multiplier of the production from it.
    var wm = main_map.get_node("WorkerManager") if main_map and main_map.has_node("WorkerManager") else null

    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # The identifier of the building is the common source for the income and the expense of its
        # recipes (it shows "Hand mill", "Brewer's house" in the tooltip of the
        # resources; the label is resolved by ui_helpers by the id).
        var building_source = GameData.building_source_id(str(bld.get("id", "")))

        # We check whether there is a citizen on this building
        var has_worker = false
        if tm:
            has_worker = tm.has_townsfolk(i)

        if not has_worker:
            continue # the building does not work

        # --- THE PROFESSION OF THE CITIZEN (the field "profession" in data/buildings.json) ---
        # The consumption of the supplies by the profession and the multiplier of its production.
        # It ticks once per building per tick (and not per slot!) and only for a WORKING
        # building: at an idle one (all the slots are empty) the supplies are spent in vain.
        # The multiplier is passed into the CraftContainer below and is applied to
        # the crediting of the science for a completed cycle. The bonuses of the single records
        # are summed up, of the group ones the best is taken (see
        # worker_manager._aggregate_production_bonus).
        var prof_multiplier := 1.0
        if wm != null and not are_all_slots_empty(i):
            prof_multiplier = wm.tick_building_consumption(i, SIMULATION_TICK)

        # --- THE CONTINUOUS CRAFTING (CraftContainer) ---
        # The priority of the quality of the raw material: from the building or the default. It is passed into the container
        # for the write-off and affects the choice of the quality inside the "@"-group.
        var priority = bld.get("quality_priority", GameData.get_quality_priority_default())

        for slot_idx in range(slots.size()):
            var recipe_id = slots[slot_idx]
            if recipe_id == "" or recipe_id == "empty":
                continue

            var container: CraftContainer = _ensure_slot_container(i, slot_idx)
            if container == null:
                continue

            # We advance the container by one tick. tick() itself writes off the ingredients
            # from the storage (through CityData.remove_from_storage) and returns:
            #   consumed_breakdown — the breakdown by the qualities for the tooltip of the resources
            #                          and the calculation of the quality of the science;
            #   releases — what to release into the storage on this tick (the gradual release
            #              of the result in proportion to the progress: full_amount /
            #              craft_time units/sec, with a sub-unit accumulator for
            #              the integer accuracy). On completed the fractional
            #              remainder is caught up — exactly full_amount is released
            #              over the whole cycle.
            #   completed — true if the container is full AND craft_time has passed.
            var tick_res: Dictionary = container.tick(SIMULATION_TICK, has_worker, priority, prof_multiplier)

            # --- THE RECORDING OF THE EXPENSE FOR THE TICK ---
            # We record the consumption source for the tooltip of the resources and the UI label
# of the dynamics. In the continuous model the consumption goes on every tick, and this
# record is the main source of the data for the red label [-N≈].
            var consumed_breakdown: Dictionary = tick_res.get("consumed_breakdown", {})
            for consumed_pid in consumed_breakdown:
                var total_consumed := 0
                for qid in consumed_breakdown[consumed_pid]:
                    total_consumed += int(consumed_breakdown[consumed_pid][qid])
                if total_consumed > 0:
                    record_consumption_source(consumed_pid, building_source, total_consumed)

            # --- THE RECIPE "SCIENCE": the direct contribution to the rate of the research ---
            # There is no pool of the science any more: the science of the buildings is not accumulated in the storage, but
            # is directly added to the rate of the learning of the technologies (see
            # docs.md, "Science: production and research"). The formula
            # per building:
            #   * the fixed output of the building (additional_yield.science —
            #     points/sec of the Library and the Scriptorium) — it flows while the building
            #     works (there is a citizen and a non-empty slot), even without the bases;
            #   * the science from the bases for the writing — the weighted average of the special_yield
            #     of the mixture which the building actually consumes (consumed_pids).
            #     Neither required nor craft_time of the recipe enters the rate:
            #     the recipe is only a "pass" (while the raw material is available — the missing
            #     is empty — the scholars work), its input only sets the expense
            #     of the fuel from the storage. The rate of the work of the scholars is determined by
            #     the special_yield of the bases themselves (clay tablets +1, papyrus +2,
            #     parchment +3, silk +3, paper +5). While there is no composition —
            #     the contribution of the bases is 0.
            #   * all of this is multiplied by the bonus of the profession of the scholar
            #     (the feathers/ink): (fixed + mediums) × prof_multiplier.
            if recipe_id == "science":
                var missing: Array = tick_res.get("missing", [])
                var building_fixed := float(GameData.get_building_additional_yield(bld.get("id", "")).get("science", 0))
                var building_mediums := 0.0
                var mediums_names: Array = []
                if missing.is_empty():
                    for slot in container.ingredient_slots:
                        var required_total := int(slot.get("required", 0))
                        if required_total <= 0:
                            continue
                        # The weighted average of the special_yield of the mixture of the bases which
                        # the slot actually consumes (consumed_pids accumulates by
                        # pid and survives the reset of the cycle). This is the contribution
                        # of the bases to the rate of the science — without the multipliers.
                        var consumed_pids: Dictionary = slot.get("consumed_pids", {})
                        var yield_sum := 0.0
                        var qty_sum := 0
                        for consumed_pid in consumed_pids:
                            var consumed_qty := int(consumed_pids[consumed_pid])
                            if consumed_qty <= 0:
                                continue
                            var medium_science := float(GameData.get_special_yield(str(consumed_pid)).get("science", 0))
                            yield_sum += medium_science * float(consumed_qty)
                            qty_sum += consumed_qty
                            mediums_names.append(GameData.format_resource_name(str(consumed_pid)))
                        if qty_sum > 0:
                            building_mediums += yield_sum / float(qty_sum)
                var science_instant := (building_fixed + building_mediums) * prof_multiplier
                science_buildings_rate_per_sec += science_instant
                # The breakdown for the tooltip: fixed/mediums are written WITHOUT the bonus —
                # the multiplier is applied to the sum at the output. bonus_names are the
                # products whose consumption gives the bonus of the profession of the building.
                var bonus_names: Array = []
                var bld_prof: String = str(bld.get("profession", ""))
                if bld_prof != "" and prof_multiplier > 1.001:
                    for cons_entry in GameData.get_profession_consumption(bld_prof):
                        if float(cons_entry.get("production_bonus", 0.0)) <= 0.0:
                            continue
                        bonus_names.append(str(cons_entry.get("product_name", "")))
                var science_bld_entry := {
                    "name": building_source,
                    "fixed": building_fixed,
                    "mediums": building_mediums,
                    "bonus": prof_multiplier,
                    "mediums_names": mediums_names,
                    "bonus_names": bonus_names
                }
                science_breakdown_buildings.append(science_bld_entry)

            # --- THE GRADUAL RELEASE OF THE RESULT (every tick) ---
            # Each "portion" of the release has the quality, calculated by
            # the accumulated consumed at the current moment (see CraftContainer._compute_quality_from_consumed).
            # This agrees with the UI semantically: the label [≈] shows the planned
            # per_sec, and the storage actually receives +N per tick (on average).
            var releases: Array = tick_res.get("releases", [])
            for rel in releases:
                var rel_pid: String = str(rel.get("pid", ""))
                var rel_amount: int = int(rel.get("amount", 0))
                var rel_quality: String = str(rel.get("quality", "common"))
                if rel_amount <= 0 or rel_pid.is_empty():
                    continue
                add_to_storage(rel_pid, rel_amount, rel_quality)
                record_production_source(rel_pid, building_source, rel_amount)

            if not bool(tick_res.get("completed", false)):
                continue

            # --- THE CRAFTING IS COMPLETED ---
            # At this stage the releases per tick already include the "catching up" of the fractional
            # remainder — over the whole cycle exactly full_amount is released for
            # each pid of the result. Nothing extra has to be added.
            # The special case of the recipe "science" is not needed: its contribution to the rate of the
            # research is credited on every tick above (the block "THE RECIPE
            # "SCIENCE""), the science does not arrive into the storage.

            # --- THE RESET OF THE CONTAINER FOR THE NEXT CRAFTING ---
            container.reset()

    # --- THE BREAKDOWN OF THE RATE OF THE SCIENCE BY THE SOURCES (for the tooltip) ---
    science_breakdown = {
        "base": BASE_SCIENCE_PER_SEC,
        "buildings": science_breakdown_buildings,
        "total": get_science_rate_per_sec()
    }

    # --- The consumption of the food by the population ---
    # The food is consumed without taking the quality into account (the quality is a visual mechanics),
    # therefore we write off by the default "best" through the helper, so that the breakdown
    # of the quality always remains consistent.
    # The debug toggle: while food_consumption_enabled == false the citizens
    # do NOT eat the food (the toggle in the debug menu). The growth/decline of the population is at that time
    # counted as usual — only the write-off of the food from the storage is disabled.
    if food_consumption_enabled:
        var food_needed = max(0, total_population - 1) * food_per_citizen
        var food_eaten = 0
        for pid in city_food_pool:
            if city_food_pool[pid] and city_storage.get(pid, 0) > 0:
                var available = city_storage[pid]
                var to_take = min(available, food_needed - food_eaten)
                remove_from_storage(pid, to_take, "best")
                record_consumption_source(pid, GameData.SRC_POP_FOOD, to_take)
                food_eaten += to_take
                if food_eaten >= food_needed:
                    break

    # --- THE TAXES: every citizen pays the base tax into the treasury on every tick ---
    # The order matters: the collection goes AFTER the consumption of the food and BEFORE
    # _check_population_change() — the tax for the tick is paid by those who lived in this tick
    # (the growth/decline of the population will be taken into account from the next tick). The amount and the record into
    # the breakdown of the treasury are inside collect_taxes() (see "The treasury of the city and the internal
    # market" in docs.md, the section "Taxes").
    collect_taxes()
    _check_population_change()
    emit_signal("city_updated")

func _check_population_change():
    var available_food = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            available_food += city_storage.get(pid, 0)

    # --- THE DYNAMICS OF THE FOOD (for the determination of the famine) ---
    var total_prod = 0
    var total_cons = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            total_prod += production_rates.get(pid, 0)
            total_cons += consumption_rates.get(pid, 0)

    var main_map = get_tree().root.find_child("MainMap", true, false)

    # --- THE GROWTH OF THE POPULATION ---
    if available_food >= food_for_new_settler and total_population > 0:
        total_population += 1
        idle_population += 1 # the new citizen is free for now

        # We try to assign him to a work (first to an improvement, then to the city)
        var assigned = false
        if main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            assigned = wm.assign_worker() # it will decrease idle_population on success

        if not assigned and main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            assigned = tm.assign_townsfolk()

        # If he has not been assigned anywhere — he remains in idle_population

        # We write off the food for the birth
        var remaining = food_for_new_settler
        var active_food = []
        for pid in city_food_pool:
            if city_food_pool[pid] and city_storage.get(pid, 0) > 0:
                active_food.append(pid)
        while remaining > 0 and active_food.size() > 0:
            var pid = active_food[randi() % active_food.size()]
            remove_from_storage(pid, 1, "best")
            remaining -= 1
            if city_storage.get(pid, 0) <= 0:
                active_food.erase(pid)

        emit_signal("population_changed", total_population)
        print("The population has grown to ", total_population)

    # --- THE FAMINE (the death from the lack of the food) ---
    elif available_food == 0 and total_cons > total_prod and total_population > 1:
        total_population -= 1

        # We remove one citizen from the work (first the citizen, then the worker).
        # The deceased does NOT pass into the category of the free, therefore after the removal
        # from the work we compensate the increase of idle_population.
        var removed = false
        if main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            for i in range(city_built_buildings.size()):
                if tm.has_townsfolk(i):
                    tm.remove_townsfolk(i) # it will increase idle_population
                    idle_population -= 1 # the deceased does not become free
                    removed = true
                    break

        if not removed and main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            for key in wm.assigned_hexes.keys():
                var parts = key.split(",")
                if parts.size() == 2:
                    wm.remove_worker(int(parts[0]), int(parts[1])) # it will increase idle_population
                    idle_population -= 1 # the deceased does not become free
                    removed = true
                    break

        # If the citizen was free (did not work), we simply decrease idle_population
        if not removed and idle_population > 0:
            idle_population -= 1

        # We correct idle_population, so that it does not exceed total_population
        if idle_population > total_population:
            idle_population = total_population

        emit_signal("population_changed", total_population)
        print("The population has decreased to ", total_population)

# --- THE RESEARCH ---
func start_research(tech_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    # Debug: with "do not observe the requirements" enabled the technology is learned
    # instantly — without putting it in the queue, without the check of prereq/eras and without the accumulation
    # of the science. The current research is not interrupted at that time.
    if ignore_tech_requirements:
        return _complete_tech_instantly(tech_id)
    if current_research_tech_id != "":
        var current_tech_name = current_research_tech_id
        for t in GameData.technologies:
            if t["id"] == current_research_tech_id:
                current_tech_name = t["name"]
                break
        emit_signal("research_error", tr("Research already in progress: ") + current_tech_name)
        return false
    if tech_id in unlocked_technologies:
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break
        emit_signal("research_error", tr("Technology already researched: ") + tech_name)
        return false
    var tech_data = null
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_data = t
            break
    if tech_data == null:
        emit_signal("research_error", tr("Technology not found: ") + tech_id)
        return false
    if not are_prerequisites_met(tech_id):
        var prereq_text = get_tech_prerequisites_text(tech_id)
        emit_signal("research_error", tr("Requirements not met: ") + prereq_text)
        return false
    if not is_tech_era_allowed(tech_id):
        var tech_name = tech_data.get("name", tech_id)
        var next_era_name = _get_era_name_by_index(current_era_index + 1)
        emit_signal("research_error", tr("\"%s\" belongs to the next era. Advance to the %s era first.") % [tech_name, next_era_name])
        return false
    # The research does not require the food — only the points of the science.
    current_research_tech_id = tech_id
    current_research_science_cost = int(tech_data.get("science_cost", 3))
    research_progress = 0.0
    research_science_accumulated = 0.0
    print("The research has started: ", tech_data["name"])
    emit_signal("city_updated")
    return true

# Instantly unlocks the technology — it is used in the debug mode
# "do not observe the requirements of the technologies" (ignore_tech_requirements), when
# the learning has to happen at once, without the queue and the accumulation of the science.
# Only the selected technology is learned: the predecessors are NOT added.
# The current research (current_research_tech_id) is not touched.
func _complete_tech_instantly(tech_id: String) -> bool:
    if tech_id in unlocked_technologies:
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break
        emit_signal("research_error", tr("Technology already researched: ") + tech_name)
        return false
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null:
        emit_signal("research_error", tr("Technology not found: ") + tech_id)
        return false
    unlocked_technologies.append(tech_id)
    # The technology can open the new kinds of the resources — we spawn them on the map and
# The actual rate of the science of the city (points/sec) — a direct sum of the sources:
# the base income (BASE_SCIENCE_PER_SEC) plus the contribution of the working science buildings
# (the cache science_buildings_rate_per_sec, it is recalculated once per tick in do_tick).
# There is no pool of the science: the produced science is not accumulated in the storage, and it immediately sets
# the rate of the learning of the technologies (see tick_research_science_continuous and
# docs.md, "Science: production and research").
    last_research_messages = spawn_resource_on_tech_research(tech_id)
    emit_signal("research_completed", tech_id)
    emit_signal("city_updated")
    print("Instantly learned (debug): ", tech_data.get("name", tech_id))
    return true

# The actual rate of the science of the city (points/sec) — a direct sum of the sources:
# the base income (BASE_SCIENCE_PER_SEC) plus the contribution of the working science buildings
# (the cache science_buildings_rate_per_sec, it is recalculated once per tick in do_tick).
# There is no pool of the science: the produced science is not accumulated in the storage, and it immediately sets
# the rate of the learning of the technologies (see tick_research_science_continuous and
# docs.md, "Science: production and research").
func get_science_rate_per_sec() -> float:
    return BASE_SCIENCE_PER_SEC + science_buildings_rate_per_sec

# The breakdown of the rate of the science by the sources (see science_breakdown) — for the tooltip
# on the tab "Technologies". The cache is filled in once per tick in do_tick().
func get_science_breakdown() -> Dictionary:
    return science_breakdown

# Returns the number of the accumulated points of the science for the current research.
func get_research_science_collected() -> float:
    return research_science_accumulated

# Updates the progress of the research continuously — it is called every frame
# from _process in main_map.gd. The rate is a direct sum of all the sources of the science
# (get_science_rate_per_sec: the base + the working science buildings), therefore
# the progress bar grows smoothly frame by frame. The science is NOT accumulated: while there is no research,
# the crediting does not happen, and the work of the buildings is lost "in vain"
# (the pool of the science has been removed, see docs.md, "Science: production and research").
func tick_research_science_continuous(delta: float) -> void:
    if Engine.is_editor_hint():
        return
    if current_research_tech_id == "":
        return
    if current_research_science_cost <= 0:
        current_research_science_cost = 1
    research_science_accumulated += get_science_rate_per_sec() * delta
    research_progress = clamp(research_science_accumulated / float(current_research_science_cost), 0.0, 1.0)
    if research_science_accumulated >= current_research_science_cost:
        _complete_research()

func _complete_research():
    if current_research_tech_id == "":
        return
    var completed_tech_id = current_research_tech_id
    unlocked_technologies.append(current_research_tech_id)
    var tech_name = get_tech_name(current_research_tech_id)
    emit_signal("research_error", tr("Research complete: ") + tech_name)
    # The technology can open the new kinds of the resources — we spawn them on the map.
    # We prepare the messages BEFORE the signal research_completed, so that the popup
    # can display the found resources at once.
    last_research_messages = spawn_resource_on_tech_research(completed_tech_id)
    emit_signal("research_completed", current_research_tech_id)
    # After the completion of the research the points of the science are reset to zero.
    current_research_tech_id = ""
    current_research_science_cost = 0
    research_progress = 0.0
    research_science_accumulated = 0.0
    emit_signal("city_updated")

func is_tech_unlocked(tech_id: String) -> bool:
    return tech_id in unlocked_technologies

# The human-readable name of the technology by its id (for the messages to the player and
# the tooltips). If the technology is not found — the id itself is returned, so that in the
# message there is not an empty string.
func get_tech_name(tech_id: String) -> String:
    for t in GameData.technologies:
        if t.get("id", "") == tech_id:
            return str(t.get("name", tech_id))
    return tech_id

func _get_tech_data(tech_id: String):
    for t in GameData.technologies:
        if t["id"] == tech_id:
            return t
    return null

# Are the prerequisites of the technology met.
# The format: [ [A, B], [C] ] => (A AND B) OR C
func are_prerequisites_met(tech_id: String) -> bool:
    # Debug: with "do not observe the requirements" enabled the prerequisites are not
    # checked at all. Only the selected technology is learned, the predecessors
    # are not added to unlocked_technologies (see _complete_research).
    if ignore_tech_requirements:
        return true
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null:
        return false
    if not tech_data.has("prerequisites"):
        return true
    var prereqs: Array = tech_data.get("prerequisites", [])
    for group in prereqs:
        var all_met = true
        for req_id in group:
            if not (req_id in unlocked_technologies):
                all_met = false
                break
        if all_met:
            return true
    return false

# Returns the human-readable text of the requirements of the technology.
func get_tech_prerequisites_text(tech_id: String) -> String:
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null or not tech_data.has("prerequisites"):
        return ""
    var or_parts = []
    var prereqs: Array = tech_data.get("prerequisites", [])
    for group in prereqs:
        var and_names = []
        for req_id in group:
            var req_data = _get_tech_data(req_id)
            and_names.append(req_data.get("name", req_id) if req_data else req_id)
        or_parts.append(tr(" and ").join(and_names))
    return tr(" or ").join(or_parts)

# Is the technology available for learning (the prerequisites are met, it is not learned,
# it is not in progress, the era is not above the current one).
func is_tech_available(tech_id: String) -> bool:
    if tech_id in unlocked_technologies:
        return false
    if tech_id == current_research_tech_id:
        return false
    if not is_tech_era_allowed(tech_id):
        return false
    return are_prerequisites_met(tech_id)

# Returns the list of the ids of the technologies (in the order of their learning — from the root to the target),
# which the player still has to learn in order for tech_id to become available.
# The already learned technologies are skipped; the requirements are taken from the field
# `prerequisites` (the OR groups · the AND elements — the group with the least
# number of the missing technologies is chosen). The cycles and the duplicates are excluded.
# It is used for the button "Learn ..." in the control panel of the special actions.
func get_tech_study_chain(tech_id: String) -> Array:
    var chain: Array = []
    _collect_tech_chain(tech_id, chain, {})
    return chain

# The maximum number of "hops" — the technologies that remain until the target
# technology is unlocked (NOT counting the target itself) — at which the control panel shows
# the buttons of the construction of the improvement blocked by the technology, and of the
# learning of this technology. The requirement: the buttons are visible only if the hops are <= TECH_HOPS_MAX.
const TECH_HOPS_MAX := 2

# How many technologies are left to learn in order to unlock tech_id (tech_id itself is
# NOT counted). An example for "Canals": at the start the chain = 3
# ("Irrigation", "Mining", "Stone masonry") → 3 hops; after the learning of
# "Irrigation" → 2 hops ("Mining", "Stone masonry").
func get_tech_hops(tech_id: String) -> int:
    return maxi(0, get_tech_study_chain(tech_id).size() - 1)

func _collect_tech_chain(tech_id: String, chain: Array, visiting: Dictionary) -> void:
    if tech_id in visiting or tech_id in chain:
        return
    var data = _get_tech_data(tech_id)
    if data == null or is_tech_unlocked(tech_id):
        return
    # The technologies of the future eras do not enter the chain: they cannot be learned
    # until the transition to the corresponding era has been made.
    if not is_tech_era_allowed(tech_id):
        return
    var prereqs: Array = data.get("prerequisites", [])
    if not prereqs.is_empty():
        # We choose the group of the preconditions with the least number of the missing technologies.
        var best_reqs: Array = []
        var best_missing := 1 << 30
        for group in prereqs:
            var missing: Array = []
            for req_id in group:
                if not is_tech_unlocked(req_id):
                    missing.append(req_id)
            if missing.size() < best_missing:
                best_missing = missing.size()
                best_reqs = missing
        visiting[tech_id] = true
        for req_id in best_reqs:
            _collect_tech_chain(req_id, chain, visiting)
        visiting.erase(tech_id)
    if tech_id not in chain:
        chain.append(tech_id)

# Is the building unlocked for the player (by the unlock_tech field of the building itself).
func is_building_unlocked(building_id: String) -> bool:
    for b in GameData.buildings:
        if b["id"] == building_id:
            var required_tech = b.get("unlock_tech", "")
            if required_tech != "":
                return is_tech_unlocked(required_tech)
    return true

# Checks the additional conditions of the construction of the building from buildings.json.
# It returns a dictionary {"ok": bool, "reason": String}, so that the UI and the actual
# start of the construction show the same reason of the refusal.
func check_building_additional_req(building_id: String) -> Dictionary:
    # Debug: with "Ignore building requirements" enabled any
    # additional condition (additional_req) is considered met.
    if ignore_build_requirements:
        return {"ok": true, "reason": ""}
    var building_data = null
    for b in GameData.buildings:
        if b.get("id", "") == building_id:
            building_data = b
            break
    if building_data == null:
        return {"ok": false, "reason": tr("Building not found")}

    var requirement = String(building_data.get("additional_req", ""))
    if requirement == "":
        return {"ok": true, "reason": ""}

    if requirement == "running_water":
        var main_map = get_tree().root.find_child("MainMap", true, false)
        if main_map == null or main_map.tile_data.is_empty():
            return {"ok": false, "reason": tr("No access to fresh water")}
        var water_access = MapHelpers.get_hex_water_access(
            main_map.city_row,
            main_map.city_col,
            main_map.tile_data,
            main_map.map_rows,
            main_map.map_cols
        )
        if water_access != "":
            return {"ok": true, "reason": ""}
        return {"ok": false, "reason": tr("The city needs access to fresh water")}

    return {"ok": false, "reason": tr("Unknown construction requirement: %s") % requirement}

# Is the improvement unlocked for the player (by the unlock_tech field of the improvement itself).
func is_improvement_unlocked(imp_id: String) -> bool:
    if imp_id == null or imp_id == "":
        return true
    var imp_data = GameData.improvements.get(imp_id, {})
    var required_tech = imp_data.get("unlock_tech", "")
    if required_tech != "":
        return is_tech_unlocked(required_tech)
    return true

# Returns the id of the technology that unlocks the specified improvement (for the context menu).
func get_improvement_unlock_tech(imp_id: String) -> String:
    var imp_data = GameData.improvements.get(imp_id, {})
    return imp_data.get("unlock_tech", "")

# Assembles the messages about the resources revealed by the learned technology.
# It is called after the completion of the research of a technology.
#
# The new model (see docs.md, "tech_reveal: hidden resources"):
#   - All the resources spawn on the map from the very start (map_generator.gd).
#   - tech_required gates the construction of the improvement (as before).
#   - tech_reveal gates the visibility of the resource itself on the map.
#   - This function enumerates the resources for which tech_reveal == tech_id,
#     and for each one assembles a message:
#       * the resource is on the map          → "The scholars have estimated: <X> has been found."
#       * the resource is not on the map       → "It seems that <X> is absent in your region."
#   - The function does NOT deal with the placement on the map: all the resources are already there
#     from the moment of the generation of the map.
#
# The guarantee "1 metal in the starting Ring + Region" is provided separately
# in main_map._initialize_map through MapHelpers.ensure_minimum_resource.
# It returns an array of the messages for the popup of the technology.
    # We collect the kinds of the resources REVEALED by this technology (tech_reveal).
    # If a resource has no tech_reveal — it is visible at once and this function does not
    # mention it; if tech_reveal is present, but does not coincide with tech_id,
    # the resource is still hidden and we do not report it either.
func spawn_resource_on_tech_research(tech_id: String) -> Array:
    var messages = []
    if Engine.is_editor_hint():
        return messages
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return messages
    var tile_data = main_map.tile_data

    # We collect the kinds of the resources REVEALED by this technology (tech_reveal).
    # If a resource has no tech_reveal — it is visible at once and this function does not
    # mention it; if tech_reveal is present, but does not coincide with tech_id,
    # the resource is still hidden and we do not report it either.
    for res_id in GameData.raw_resources:
        var data = GameData.raw_resources[res_id]
        var reveal_tech: String = data.get("tech_reveal", "")
        if reveal_tech != tech_id:
            continue
        var res_name: String = data.get("name", res_id)
        if _is_resource_on_map(tile_data, res_id):
            messages.append(tr("Scholars estimate: your region may contain %s.") % res_name)
        else:
            messages.append(tr("It seems your region has no %s.") % res_name)
    return messages

# Checks whether there is at least one hex with the specified resource on the map.
func _is_resource_on_map(tile_data: Array, res_id: String) -> bool:
    for row in tile_data:
        for tile in row:
            if tile.get("resource", null) == res_id:
                return true
    return false

# Checks whether at least one resource REVEALED is present on the map
# specified by the technology (tech_reveal == tech_id).
func _tech_has_resource_on_map(tile_data: Array, tech_id: String) -> bool:
    for row in tile_data:
        for tile in row:
            var res_id = tile.get("resource", null)
            if res_id == null:
                continue
            var data = GameData.raw_resources.get(res_id, {})
            if data.get("tech_reveal", "") == tech_id:
                return true
    return false

# It is called on the loading of a save: for the already learned technologies
# it guarantees that the resources opened by them are displayed correctly.
# In the new model (all the resources are already on the map) this is essentially a no-op: if
# the resource with tech_reveal == tech_id is on the map (and normally it is),
# the function does nothing. If the save is old and the resource is absent from the map,
# we do not spawn a new one either — the old saves with a damaged map
# the user fixes himself (or starts a new game).
func ensure_tech_resources_spawned():
    if Engine.is_editor_hint():
        return
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return
    var tile_data = main_map.tile_data
    for tech_id in unlocked_technologies:
        # There is already a resource on the map, revealed by this technology — ok.
        if _tech_has_resource_on_map(tile_data, tech_id):
            continue
        # Just in case we run the function (it will form the "is absent"
        # messages, but in the HUD they will not go — we discard them right away).
        spawn_resource_on_tech_research(tech_id)

# Checks the availability of the product (including the technologies, the improvements and the buildings).
func _is_product_available(product_id: String) -> bool:
    var product_data = GameData.products.get(product_id, {})
    # The check of the technology
    var required_tech = product_data.get("unlock_tech", "")
    if required_tech != "" and not is_tech_unlocked(required_tech):
        return false

    # The check of the improvement (on the map)
    var required_improvement = product_data.get("unlock_improvement", "")
    if required_improvement != "" and not _has_improvement(required_improvement):
        return false

    # The check of the building (in the city)
    var required_building = product_data.get("unlock_building", "")
    if required_building != "" and not _has_building(required_building):
        return false

    return true

func _has_improvement(improvement_id: String) -> bool:
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if not main_map:
        return false
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile and tile.get("improvement") == improvement_id:
                return true
    return false

func _has_building(building_id: String) -> bool:
    for bld in city_built_buildings:
        if bld.get("id") == building_id:
            return true
    return false

# --- THE UPGRADES OF THE BUILDINGS ---
# A building can have an improved version: the field "upgrades_into" in buildings.json
# (for example, hand_mill -> animal_mill). The upgrade is an ordinary build in the common pool
# of the labour (build_manager), but during it the building continues to work as usual,
# and on the completion it is replaced by the improved version with the transfer of the settings
# (the recipes of the slots, the priority of the quality; the worker remains bound to the index of the
# building, therefore the state "working/paused" is transferred by itself).
# Returns the id of the improved version of the building (the field "upgrades_into") or an empty
# string, if the building has no improvement.
func get_building_upgrade_target(building_id: String) -> String:
    for b in GameData.buildings:
        if b.get("id", "") == building_id:
            return String(b.get("upgrades_into", ""))
    return ""

# Returns the data of the going upgrade of the building by its index in the city
# (an empty dictionary, if the upgrade is not going). It proxies the request into build_manager,
# where all the active builds are stored.
func get_building_upgrade_data(idx: int) -> Dictionary:
    if Engine.is_editor_hint():
        return {}
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null or not main_map.has_node("BuildManager"):
        return {}
    var bm = main_map.get_node("BuildManager")
    return bm.get_building_upgrade_by_index(idx)

# Can the upgrade of the building under the index idx be started:
# - the building has the field upgrades_into;
# - the improved version is unlocked by a technology (its unlock_tech is learned);
# - the upgrade of this building is not going yet.
func can_upgrade_building(idx: int) -> bool:
    if idx < 0 or idx >= city_built_buildings.size():
        return false
    var from_id: String = city_built_buildings[idx].get("id", "")
    if from_id == "":
        return false
    var upgrade_to: String = get_building_upgrade_target(from_id)
    if upgrade_to == "":
        return false
    if not is_building_unlocked(upgrade_to):
        return false
    if not get_building_upgrade_data(idx).is_empty():
        return false
    return true

# Starts the upgrade of the building under the index idx into its improved version.
# It atomically writes off the additional_cost of the improved version and registers the build of the
# upgrade in build_manager (or completes the upgrade instantly, if the work_cost of the improved
# version == 0 or the debug flag "Ignore building requirements" is enabled). It returns
# { "ok": bool, "reason": String } for the UI.
func start_building_upgrade(idx: int) -> Dictionary:
    if idx < 0 or idx >= city_built_buildings.size():
        return {"ok": false, "reason": tr("Building not found")}
    var from_id: String = city_built_buildings[idx].get("id", "")
    var upgrade_to: String = get_building_upgrade_target(from_id)
    if upgrade_to == "":
        return {"ok": false, "reason": tr("This building has no improved version")}

    var upgrade_data = null
    for b in GameData.buildings:
        if b.get("id", "") == upgrade_to:
            upgrade_data = b
            break
    if upgrade_data == null:
        return {"ok": false, "reason": tr("Improved building version not found")}

    # The improved version must be unlocked by a technology.
    if not is_building_unlocked(upgrade_to):
        return {"ok": false, "reason": tr("Research the technology that unlocks \"%s\" first") % upgrade_data.get("name", upgrade_to)}

    # The additional conditions of the improved version (additional_req).
    var additional_req_check = check_building_additional_req(upgrade_to)
    if not additional_req_check["ok"]:
        return {"ok": false, "reason": additional_req_check["reason"]}

    var main_map = get_tree().root.find_child("MainMap", true, false)
    var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
    if bm == null:
        return {"ok": false, "reason": tr("Construction manager unavailable")}

    # The upgrade of this building is already going — a repeated start is impossible.
    if not bm.get_building_upgrade_by_index(idx).is_empty():
        return {"ok": false, "reason": tr("This building is already being upgraded")}

    # The common limit of the simultaneous builds (buildings + improvements + upgrades) is equal to
    # the number of the citizens. We check it BEFORE the write-off of the materials.
    var work_cost = upgrade_data.get("work_cost", 0)
    if work_cost > 0 and not ignore_build_requirements:
        if bm.get_total_active_builds() >= total_population:
            return {"ok": false, "reason": tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)") % total_population}

    # We atomically write off the additional_cost of the improved version (with the debug
    # flag enabled the materials are not checked and not written off).
    var cost_check = consume_additional_cost(upgrade_data)
    if not cost_check["ok"]:
        var missing_names = []
        for m in cost_check.get("missing", []):
            missing_names.append(str(m))
        return {"ok": false, "reason": tr("Missing: ") + ", ".join(missing_names)}

    var build_key = bm.start_building_upgrade(idx, from_id, upgrade_to)
    if build_key == "":
        # The instant completion (work_cost == 0 / the debug flag): the signal
        # building_upgrade_completed has already been emitted, main_map will handle it
        # and call complete_building_upgrade.
        emit_signal("city_updated")
        return {"ok": true, "reason": ""}

    emit_signal("building_upgrade_started", idx, upgrade_to, build_key)
    emit_signal("city_updated")
    return {"ok": true, "reason": ""}

# Completes the upgrade: it replaces the building under the index idx with the improved version
# with the transfer of the settings. It is called from main_map._on_building_upgrade_completed
# (the signal build_manager.building_upgrade_completed) or directly on
# an instant upgrade. It returns true on success.
func complete_building_upgrade(idx: int, upgrade_to: String) -> bool:
    if idx < 0 or idx >= city_built_buildings.size():
        return false
    var old_bld = city_built_buildings[idx]
    var from_id: String = old_bld.get("id", "")
    if from_id == "" or get_building_upgrade_target(from_id) != upgrade_to:
        return false

    # The settings of the old version: the selected recipes of the slots and the priority of the quality.
    var old_slots: Array = old_bld.get("slots", [])
    var priority: String = old_bld.get("quality_priority", GameData.get_quality_priority_default())

    # The data of the improved version: the number of the slots and the default recipes.
    var new_bdata = null
    for b in GameData.buildings:
        if b.get("id", "") == upgrade_to:
            new_bdata = b
            break
    var slot_count := 1
    var default_recipes: Array = []
    if new_bdata:
        slot_count = int(new_bdata.get("production_slots", 1))
        default_recipes = new_bdata.get("default_recipes", [])

    # The transfer of the recipes: a recipe which is executable in the new version is preserved;
    # the unsuitable ones (for example, the manual grinding of the grain on the upgrade to the mill
    # with the animal traction) are replaced by the default recipe of the new version or by "Empty".
    var new_slots: Array = []
    for i in range(slot_count):
        var selected_id: String = old_slots[i] if i < old_slots.size() else ""
        if selected_id == "" or selected_id == "empty":
            # An empty slot remains empty — the choice of the player is preserved.
            new_slots.append("empty")
        elif can_craft_in(selected_id, upgrade_to):
            new_slots.append(selected_id)
        else:
            if i < default_recipes.size():
                new_slots.append(default_recipes[i])
            else:
                new_slots.append("empty")

    # The state "working/paused" is transferred by itself: the worker is bound
    # to the index of the building (townsfolk_manager), and the index does not change.
    city_built_buildings[idx] = {
        "id": upgrade_to,
        "slots": new_slots,
        "quality_priority": priority
    }
    emit_signal("city_updated")
    return true

# Converts the old records of the buildings {"id": ..., "recipe": ...} into the new format {"id": ..., "slots": [...]}.
func migrate_old_save_format():
    for bld in city_built_buildings:
        if not bld.has("slots"):
            bld["slots"] = _slots_from_legacy(bld)
            bld.erase("recipe")

# The slots of a building from the obsolete "recipe" field.
func _slots_from_legacy(bld: Dictionary) -> Array:
    var building_id = bld.get("id", "")
    var slots = _auto_assign_slots(building_id)
    var legacy_recipe = bld.get("recipe", "")
    # If in the old save there was a concrete recipe — we put it into the first slot
    if legacy_recipe != "" and legacy_recipe != "empty":
        if slots.size() > 0:
            slots[0] = legacy_recipe
        else:
            slots.append(legacy_recipe)
    return slots

# Writes off the additional_cost of the building from the storage. It supports both forms of the field
# (an object and an array of batches with the AND logic) and the group keys (@xxx) — for them
# the write-off is distributed over the members of the group, as in the recipes.
# Atomically: if at least one batch is not enough — NOTHING is written off.
# It returns { "ok": true } on success, or { "ok": false, "missing": [the names...] }.
func consume_additional_cost(bdata: Dictionary) -> Dictionary:
    # Debug: with "Ignore building requirements" enabled
    # the additional materials are not checked and not written off.
    if ignore_build_requirements:
        return {"ok": true}
    if not bdata.has("additional_cost"):
        return {"ok": true}
    var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
    if bundles.is_empty():
        return {"ok": true}

    # The first pass: we check that there is enough of everything, and we assemble the plan of the write-off
    # [{ "prod_id": amount, ... }, ...] — by the plan for each batch.
    var plan: Array = []
    var missing: Array = []
    for bundle in bundles:
        var bundle_plan: Dictionary = {}
        for res_id in bundle:
            var required: int = int(bundle[res_id])
            if required <= 0:
                continue
            if GameData.is_group_key(res_id):
                var group_key = res_id.trim_prefix("@")
                # The key of the "@"-group is always the id from product_groups.json.
                var group_products = GameData.product_groups.get(group_key, [])
                if group_products.is_empty():
                    missing.append(res_id)
                    continue
                var total_available := 0
                for prod in group_products:
                    total_available += city_storage.get(prod, 0)
                if total_available < required:
                    missing.append(res_id)
                    continue
                # We assemble how much from where to take (greedily by the list of the group)
                var remaining = required
                for prod in group_products:
                    var available = city_storage.get(prod, 0)
                    if available <= 0:
                        continue
                    var take = min(available, remaining)
                    if take > 0:
                        bundle_plan[prod] = bundle_plan.get(prod, 0) + take
                        remaining -= take
                        if remaining <= 0:
                            break
            else:
                if city_storage.get(res_id, 0) < required:
                    missing.append(res_id)
                    continue
                bundle_plan[res_id] = bundle_plan.get(res_id, 0) + required
        plan.append(bundle_plan)

    if not missing.is_empty():
        return {"ok": false, "missing": missing}

    # The second pass: everything is checked — we write off. The priority of the quality is as
    # in the recipes (by default "best").
    var priority = GameData.get_quality_priority_default()
    for bundle_plan in plan:
        for prod in bundle_plan:
            var amount: int = int(bundle_plan[prod])
            remove_from_storage(prod, amount, priority)
            consumption_rates[prod] = consumption_rates.get(prod, 0) + amount
    return {"ok": true}

func request_build(building_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break
    if not bdata:
        return false
    # The building must be unlocked by a learned technology
    if not is_building_unlocked(building_id):
        print("The building is unavailable: ", bdata.get("name", building_id))
        return false
    var additional_req_check = check_building_additional_req(building_id)
    if not additional_req_check["ok"]:
        print("The condition for the construction is not met ",
            bdata.get("name", building_id), ": ", additional_req_check["reason"])
        return false
    # We write off the additional_cost (if there is one) — atomically, before the start of the build.
    # It supports the array of batches (the AND logic) and the group keys (@xxx).
    var cost_check = consume_additional_cost(bdata)
    if not cost_check["ok"]:
        print("There are not enough resources for the construction ", bdata.get("name", building_id), ": ", cost_check.get("missing", []))
        return false
    var work_cost = bdata.get("work_cost", 0)
    # The common limit of the simultaneous builds (the buildings + the improvements) is equal to the total number of the citizens.
    # With "Ignore building requirements" enabled the limit does not apply —
    # the buildings are built instantly and do not enter the queue of the builds.
    if work_cost > 0 and not ignore_build_requirements:
        var main_map = get_tree().root.find_child("MainMap", true, false)
        var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
        var total_active = building_construction.size()
        if bm:
            total_active = bm.get_total_active_builds()
        if total_active >= total_population:
            print("At most %d buildings or improvements can be built at the same time (the limit = the number of the citizens)" % total_population)
            return false
    # The construction of the buildings now requires the labour, and not the food. With
    # "Ignore building requirements" enabled even the buildings with work_cost > 0
    # are built instantly (the flag CityData.ignore_build_requirements).
    if work_cost <= 0 or ignore_build_requirements:
        # If the cost is 0 (for example, a hand mill), we build instantly
        city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})

    # We automatically assign a citizen to the new building, if there are free ones
        var townsfolk_map = get_tree().root.find_child("MainMap", true, false)
        if townsfolk_map and townsfolk_map.has_node("TownsfolkManager"):
            var tm = townsfolk_map.get_node("TownsfolkManager")
            tm.assign_townsfolk()

        emit_signal("city_updated")
        return true

    # For the buildings with work_cost > 0 we start the build through build_manager
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map and main_map.has_node("BuildManager"):
        var bm = main_map.get_node("BuildManager")
        var build_key = bm.start_building_build(building_id)
        if build_key != "":
    # We store the build in a separate dictionary, the building will appear in the city only after the completion
            building_construction[build_key] = {
                "building_id": building_id,
                "build_key": build_key,
                "slots": _auto_assign_slots(building_id)
            }
            emit_signal("building_construction_started", building_id, build_key)
            emit_signal("city_updated")
            return true
        return false

    # If build_manager is unavailable, we build instantly (fallback)
    city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})
    if main_map and main_map.has_node("TownsfolkManager"):
        var tm2 = main_map.get_node("TownsfolkManager")
        tm2.assign_townsfolk()
    emit_signal("city_updated")
    return true

    # The auto-assignment of the recipes to the slots on the construction of the building:
    # 1. We take the default_recipes of the building
    # 2. We assign them to the slots in order, without a repetition
    # 3. If there are more slots than the recipes — the rest get "empty"
    # 4. If there are more recipes than the slots — the extra ones simply do not fit
func _auto_assign_slots(building_id: String) -> Array:
    var result = []
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break
    if not bdata:
        return result

    var slot_count = int(bdata.get("production_slots", 1))
    var default_recipes = bdata.get("default_recipes", [])

    for i in range(slot_count):
        if i < default_recipes.size():
            result.append(default_recipes[i])
        else:
            result.append("empty")
    return result

# Returns true, if all the slots of the building are empty (the recipe "Empty" or "").
# It is used for the display of the status "idle".
func are_all_slots_empty(b_index: int) -> bool:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return false
    var bld = city_built_buildings[b_index]
    var slots = bld.get("slots", [])
    if slots.is_empty():
        return false
    for recipe_id in slots:
        if recipe_id != "" and recipe_id != "empty":
            return false
    return true

# Checks whether the recipe can be executed in the specified building.
# produced_in supports an array of values; "*" means "in any building" (the empty recipe).
func can_craft_in(craft_id: String, building_id: String) -> bool:
    var recipe = null
    for c in GameData.crafts:
        if c["id"] == craft_id:
            recipe = c
            break
    if not recipe:
        return false

    var produced_in = recipe.get("produced_in", [])
    # The backward compatibility: if produced_in is a string, we bring it to an array
    if produced_in is String:
        produced_in = [produced_in]

    if building_id in produced_in:
        return true
    if "*" in produced_in:
        return true
    return false

func add_animal(animal_id: String):
    if Engine.is_editor_hint():
        return
    register_domesticated_resource(animal_id)

func register_domesticated_resource(res_id: String):
    if Engine.is_editor_hint() or not GameData.raw_resources.has(res_id):
        return
    if not MapHelpers.can_breed_resource(res_id):
        return
    if MapHelpers.get_breeding_improvement(res_id).is_empty():
        return
    if not (res_id in domesticated_resources):
        domesticated_resources.append(res_id)

func add_plant(plant_id: String):
    if Engine.is_editor_hint():
        return
    register_domesticated_resource(plant_id)

func is_product_available(product_id: String) -> bool:
    return _is_product_available(product_id)

# Returns the total multiplier of the production for the improvement imp_id.
# has_fresh_water is whether there is access to the fresh running water on the hex.
# terrain_id is the type of the terrain of the hex (for the modifiers by the terrain,
#   for example, the asphalt lake gives x2 to the bitumen).
# resource_id is the id of the resource on the hex (for the modifiers by the terrain).
func get_improvement_production_multiplier(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> float:
    var multiplier = 1.0
    for mod in get_improvement_production_modifiers(imp_id, has_fresh_water, terrain_id, resource_id):
        multiplier *= mod.get("multiplier", 1.0)
    return multiplier

# Returns the list of the active production modifiers for the improvement imp_id.
# Each element: { "label": String, "multiplier": float }
# terrain_id is the type of the terrain of the hex (for the modifiers by the terrain).
# resource_id is the id of the resource on the hex (for the modifiers by the terrain).
func get_improvement_production_modifiers(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> Array:
    var result = []
    if imp_id == null or imp_id == "":
        return result

    # The modifier of the access to the fresh running water
    if has_fresh_water:
        var fw = GameData.modifiers.get("fresh_water", {})
        var multipliers = fw.get("production_multiplier", {})
        if multipliers.has(imp_id):
            var m = float(multipliers[imp_id])
            if m != 1.0:
                result.append({
                    "label": tr("+%d%% (Fresh water access)") % int(round((m - 1.0) * 100.0)),
                    "multiplier": m
                })

    # The modifiers by the type of the terrain (terrain_modifiers).
    # They are applied, when the specified resource_id is extracted on a hex
    # with the specified terrain_id (through an improvement). For example, the bitumen on
    # the asphalt lake (asphalt_lake) gives x2 to the production.
    # See data/modifiers.json, the block "terrain_modifiers".
    if terrain_id != "" and resource_id != "":
        for tm in GameData.modifiers.get("terrain_modifiers", []):
            if tm.get("terrain_id", "") != terrain_id:
                continue
            if tm.get("resource_id", "") != resource_id:
                continue
            var m = float(tm.get("production_multiplier", 1.0))
            if m != 1.0:
                var terrain_name: String = GameData.terrains.get(terrain_id, {}).get("name", terrain_id)
                result.append({
                    "label": "x%.1f (%s)" % [m, terrain_name],
                    "multiplier": m
                })

    # The modifiers from the learned technologies
    for tm in GameData.modifiers.get("tech_modifiers", []):
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not is_tech_unlocked(tech_id):
            continue
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break

    # The universal format: "production_multiplier": { "<imp_id>": 1.05 }
    # (by analogy with the bonus of the fresh water).
        var multipliers = tm.get("production_multiplier", {})
        if multipliers.has(imp_id):
            var m = float(multipliers[imp_id])
            if m != 1.0:
                result.append({
                    "label": "+%d%% (%s)" % [int(round((m - 1.0) * 100.0)), tech_name],
                    "multiplier": m
                })

    # The obsolete format with the field "modifiers" (target == "<imp_id>_production").
        for mod in tm.get("modifiers", []):
            var target = mod.get("target", "")
            if target != imp_id + "_production":
                continue
            var mod_type = mod.get("type", "percent")
            var value = float(mod.get("value", 0))
            var multiplier = 1.0
            if mod_type == "percent":
                multiplier = 1.0 + value / 100.0
            else:
                multiplier = value
            result.append({
                "label": "+%d%% (%s)" % [int(value), tech_name],
                "multiplier": multiplier
            })
    return result
