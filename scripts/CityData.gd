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

# --- ТЕКУЩАЯ ЭПОХА ---
# Индекс текущей эпохи в GameData.eras (см. data/eras.json).
# Источник истины для ограничения «изучать можно только технологии
# текущей и предыдущих эпох». Синхронизируется с main_map.current_era
# при переходе эпохи и загрузке сохранения.
var current_era_index: int = 0

# Сообщения для HUD после завершения исследования (о найденных ресурсах)
var last_research_messages: Array = []

# --- НАСЕЛЕНИЕ ---
var total_population: int = 1
var idle_population: int = 1 # свободные жители (не занятые нигде)
# Название города — выбирается игроком в диалоге при старте новой игры.
# Пустая строка = имя ещё не задано (на карте тогда не рисуется).
var city_name: String = ""
var food_for_new_settler: int = 1000
var food_per_citizen: int = 10
# Дебаг-переключатель: потребляет ли население еду. Управляется из
# дебаг-меню (пункт «Переключение потребления еды»), НЕ сохраняется в сейв —
# это рантайм-обходной тумблер для отладки, а не игровое состояние.
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

# Запись ФАКТА списания на внутреннем рынке за тик. Отдельный счётчик
# (market_consumption_rates), потому что общий consumption_rates
# смешан с производственными входами зданий. Пишется из worker_manager
# ровно в тех местах, где ресурс уходит городу за деньги.
func record_market_consumption(pid: String, amount: int) -> void:
    if amount <= 0:
        return
    market_consumption_rates[pid] = int(market_consumption_rates.get(pid, 0)) + amount
    # Тот же факт копится в окно отображения: тиковый счётчик гаснет в
    # reset_counters(), а карточке «Торговли» нужен факт, переживающий
    # интервал отображения из настроек (см. market_consumption_accum).
    market_consumption_accum[pid] = int(market_consumption_accum.get(pid, 0)) + amount

# Сбрасывает окно факта потребления рынка в «прошлое» и обнуляет
# аккумулятор. Вызывается рядом с rotate_treasury_window (см.
# tick_resource_display). Пока первое окно не завершилось, снимок пуст —
# get_market_consumption_per_sec() берёт текущий аккумулятор, чтобы строка
# не показывала «0» при идущем потреблении.
func rotate_market_consumption_window() -> void:
    market_consumption_snapshot = market_consumption_accum.duplicate()
    market_consumption_accum.clear()

# Факт потребления на внутреннем рынке в единицах В СЕКУНДУ по прошедшему
# окну отображения: product_id -> ед./сек. Окно короче симуляционного тика не
# бывает (минимум 1 сек), поэтому за окно факт всегда есть.
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

# --- ПЛАНОВЫЙ СПРОС ЗДАНИЙ (для «Потребление (плановое)» на вкладке «Ресурсы») ---
# Кэш ссылки на TownsfolkManager: нужен и do_tick(), и подсчёту спроса зданий.
# Ищется один раз и переиспользуется (is_instance_valid — на случай удаления узла).
var _townsfolk_ref: Node = null

func _get_townsfolk() -> Node:
    if _townsfolk_ref != null and is_instance_valid(_townsfolk_ref):
        return _townsfolk_ref
    # Узел может быть вне дерева (тесты вызывают счётчики напрямую, до
    # добавления сцены) — тогда искать нечего, и null — правильный ответ.
    if not is_inside_tree():
        return null
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map:
        _townsfolk_ref = main_map.get_node_or_null("TownsfolkManager")
    return _townsfolk_ref

# Кэш ссылки на WorkerManager: нужен плановому производству зданий (бонус
# профессии горожанина) и тику потребления — симметрично _get_townsfolk().
var _worker_manager_ref: Node = null

func _get_worker_manager() -> Node:
    if _worker_manager_ref != null and is_instance_valid(_worker_manager_ref):
        return _worker_manager_ref
    # См. _get_townsfolk: вне дерева искать нечего.
    if not is_inside_tree():
        return null
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map:
        _worker_manager_ref = main_map.get_node_or_null("WorkerManager")
    return _worker_manager_ref

# Число РАБОТАЮЩИХ горожан по профессиям: prof_id -> count. Профессия берётся
# у здания (поле "profession" в data/buildings.json). Учитываются только
# здания, где есть горожанин И хотя бы один непустой слот: простаивающее
# здание расходники не тратит, поэтому в план его расход не попадает
# (см. worker_manager.get_planned_consumption_map).
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

# Возвращает плановый спрос ПОСТРОЕННЫХ ЗДАНИЙ на ресурсы за один крафт
# рецепта. Рецепт в do_tick() исполняется раз в `time` секунд при назначенном
# горожанине и наличии ингредиентов, поэтому спрос идёт вместе с временем
# рецепта (interval, секунды). Формат результата:
#   product_id -> { "Имя здания" -> { "amount": N, "interval": float,
#                                     "count": M, "is_group": bool,
#                                     "group_name": String } }
#   amount   — суммарный спрос этого здания на ресурс за один крафт слотов;
#   interval — время крафта, секунды (при нескольких слотах здания с разным
#              time берётся минимальное — как у профессий в
#              worker_manager.get_planned_consumption_map); 0 — «за тик»
#              (рецепт без поля time);
#   count  — сколько слотов-рецептов дают этот спрос (для «хN» в тултипе);
#   is_group / group_name — спрос задан группой «@»: относится к ЛЮБОМУ члену
#   группы, в тултипе помечается именем группы.
# Спрос показывается независимо от наличия ингредиентов на складе — это
# плановое потребление (потребность), а не факт; факт считает do_tick().
func get_building_planned_consumption() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Без горожанина здание не работает и ничего не потребляет.
        if tm == null or not tm.has_townsfolk(i):
            continue
        # Идентификатор здания — источник спроса (совпадает с источником
        # фактического расхода в do_tick, чтобы в тултипе это был один и тот
        # же субъект). Подпись резолвится в ui_helpers по id.
        var building_source = GameData.building_source_id(str(bld.get("id", "")))
        for recipe_id in slots:
            if recipe_id == "" or recipe_id == "empty":
                continue
            var recipe = get_craft_by_id(recipe_id)
            if recipe.is_empty():
                continue
            # Время крафта слота — единица измерения планового спроса.
            var craft_time := get_craft_time(recipe)
            var resources: Dictionary = recipe.get("resources", {})
            for res in resources:
                var amount_needed = int(resources[res])
                if amount_needed <= 0:
                    continue
                if res.begins_with("@"):
                    # Групповой ресурс: спрос относится к любому члену группы.
                    # Ключ "@"-группы — всегда id из product_groups.json.
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

# Хелпер записи спроса здания на ресурс (см. get_building_planned_consumption).
# interval — время крафта рецепта, секунды (0 — «за тик»); при нескольких
# записях одного источника берётся минимальный — как у профессий в
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

# Возвращает плановое производство ПОСТРОЕННЫХ ЗДАНИЙ за один крафт рецепта
# (зеркально к спросу зданий: рецепт в do_tick() даёт result раз в `time`
# секунд при горожанине и наличии ингредиентов). Формат результата:
#   product_id -> { "Имя здания" -> { "amount": N, "interval": float, "count": M } }
#   amount   — суммарный выпуск этого здания за один крафт (по всем слотам);
#   interval — время крафта, секунды (min по слотам здания; 0 — «за тик»);
#   count    — сколько слотов-рецептов дают этот выпуск (для «хN» в тултипе).
# План показывается независимо от наличия ингредиентов — это способность
# производителя, а не факт; факт считает do_tick().
func get_building_planned_production() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    # Множитель профессии горожанина (worker_manager.get_building_production_bonus)
    # — чтобы плановая метка «≈» совпадала с фактическим выпуском.
    var wm = _get_worker_manager()
    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Без горожанина здание не работает и ничего не производит.
        if tm == null or not tm.has_townsfolk(i):
            continue
        # Бонус профессии: 1.0 без профессии или без расходников, иначе
        # 1.0 + бонусы (см. worker_manager._aggregate_production_bonus).
        # Простаивающее здание (все слоты пусты) бонуса не получает.
        var prof_multiplier := 1.0
        if wm != null and not are_all_slots_empty(i):
            prof_multiplier = wm.get_building_production_bonus(i)
        # Идентификатор здания — источник выпуска (совпадает с источником
        # фактического производства в do_tick, чтобы в тултипе это был один и
        # тот же субъект).
        var building_source = GameData.building_source_id(str(bld.get("id", "")))
        for recipe_id in slots:
            if recipe_id == "" or recipe_id == "empty":
                continue
            var recipe = get_craft_by_id(recipe_id)
            if recipe.is_empty():
                continue
            # Время крафта слота — единица измерения планового выпуска.
            var craft_time := get_craft_time(recipe)
            var production: Dictionary = recipe.get("result", {})
            for res in production:
                var amount = int(production[res])
                if amount <= 0:
                    continue
                # Бонус профессии применяется к выпуску рецепта — как множитель
                # производства у улучшений на карте.
                if prof_multiplier != 1.0:
                    amount = int(round(float(amount) * prof_multiplier))
                    if amount <= 0:
                        continue
                _record_planned_supply(result, res, building_source, amount, craft_time)
    return result

# Хелпер записи выпуска здания (см. get_building_planned_production).
# interval — время крафта рецепта, секунды (0 — «за тик»); при нескольких
# записях одного источника берётся минимальный.
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

# Точка входа планового производства: рецепты зданий (interval = time рецепта,
# 0 — «за тик») + улучшения на карте (interval = production_interval улучшения,
# см. get_improvement_production_interval). План нужен потому, что в
# непрерывной модели (см. main_map._emit_continuous_production и CraftContainer)
# выпуск идёт каждый тик по чуть-чуть, и метка динамики `[+N≈]` показывает
# средний per_sec — этого достаточно для UI вкладки «Ресурсы». Записи
# наполняются из main_map.gd на каждом тике симуляции.
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

# --- ПЛАНОВОЕ ПРОИЗВОДСТВО УЛУЧШЕНИЙ НА КАРТЕ ---
# Кэш планового выпуска улучшений на текущий тик симуляции:
#   product_id -> { "Имя улучшения" -> { "amount": N, "interval": float, "count": M } }
#   amount   — суммарный выпуск улучшения за ОДИН цикл (по всем гексам);
#   interval — production_interval улучшения, секунды;
#   count    — сколько гексов с этим улучшением работают (для «хN» в тултипе).
# Наполняется из main_map.gd на каждом тике, чистится в reset_counters()
# вместе с фактическими счётчиками. Сейв не затрагивается — план всегда
# выводится из текущих данных.
var improvement_planned_production: Dictionary = {}

# Время одного цикла производства улучшения imp_id в секундах — поле
# "production_interval" из data/improvements.json. Поле отсутствует или <= 0 —
# улучшение выпускает продукцию каждый тик симуляции (старые данные).
func get_improvement_production_interval(imp_id: String) -> float:
    var interval: float = float(GameData.improvements.get(imp_id, {}).get("production_interval", 0.0))
    if interval <= 0.0:
        return SIMULATION_TICK
    return interval

# Запись планового выпуска улучшения за один цикл (вызывается из main_map.gd
# для каждого работающего улучшения на каждом тике симуляции).
func record_planned_improvement_production(pid: String, source_id: String, amount: int, interval: float):
    _record_cycle_entry(improvement_planned_production, pid, source_id, amount, interval)

# --- ПЛАНОВОЕ ПОТРЕБЛЕНИЕ УЛУЧШЕНИЙ НА КАРТЕ (корм пастбищ) ---
# Корм (feed_consumption ресурса) списывается непрерывно (см.
# main_map._consume_feed_continuous), и в плане указывается средний расход за
# цикл производства — для UI вкладки «Ресурсы» (зеркально к плановому
# выпуску). Наполняется из main_map.gd на каждом тике, чистится в
# reset_counters().
var improvement_planned_consumption: Dictionary = {}

# Запись планового потребления улучшения за один цикл (вызывается из main_map.gd).
func record_planned_improvement_consumption(pid: String, source_id: String, amount: int, interval: float):
    _record_cycle_entry(improvement_planned_consumption, pid, source_id, amount, interval)

# Кэш планового потребления улучшений для мерджа во вкладке «Ресурсы»
# (worker_manager.get_planned_consumption_map знает только профессии,
# городское «all» и спрос зданий).
func get_improvement_planned_consumption() -> Dictionary:
    return improvement_planned_consumption

# Общий хелпер записи цикловой записи (выпуск или потребление улучшения):
# amount суммируется, count — число гексов-источников, interval — минимальный.
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

# Возвращает человекочитаемое имя здания по его id (или сам id, если здание
# не найдено в реестре). Единственное место знания об этом — GameData.
func get_building_name(building_id: String) -> String:
    return GameData.get_building_display_name(building_id)

# --- ХЕЛПЕРЫ ДЛЯ РАБОТЫ С КАЧЕСТВОМ РЕСУРСОВ ---
# city_storage хранит общее количество, city_quality_detail — разбивку по качеству.
# Все операции добавления/списания должны идти через эти хелперы, чтобы
# сумма по деталям всегда совпадала с city_storage.

# Возвращает разбивку по качеству для продукта (словарь {quality: count}).
# Если разбивки нет (старый сейв), возвращает пустой словарь.
func get_quality_breakdown(pid: String) -> Dictionary:
    return city_quality_detail.get(pid, {})

# Возвращает общее количество продукта на складе.
func get_storage_amount(pid: String) -> int:
    return city_storage.get(pid, 0)

# Добавляет amount единиц продукта pid указанного качества.
# Синхронно обновляет city_storage и city_quality_detail.
func add_to_storage(pid: String, amount: int, quality: String = "common"):
    if amount <= 0:
        return
    city_storage[pid] = city_storage.get(pid, 0) + amount
    if not city_quality_detail.has(pid):
        city_quality_detail[pid] = {}
    var detail: Dictionary = city_quality_detail[pid]
    detail[quality] = detail.get(quality, 0) + amount

# Уменьшает общее количество продукта pid на amount единиц.
# Списывает по приоритету качества (best/worst/random) и возвращает
# разбивку фактически списанного: {quality: count}.
# Если приоритет не указан, используется "best".
func remove_from_storage(pid: String, amount: int, priority: String = "best") -> Dictionary:
    if amount <= 0:
        return {}
    var available = city_storage.get(pid, 0)
    var to_remove = min(amount, available)
    var consumed = _consume_quality_detail(pid, to_remove, priority)
    city_storage[pid] = available - to_remove
    return consumed

# Списывает amount единиц из разбивки по качеству согласно приоритету.
# Возвращает словарь {quality: count} фактически списанного.
func _consume_quality_detail(pid: String, amount: int, priority: String) -> Dictionary:
    var detail: Dictionary = city_quality_detail.get(pid, {})
    if detail.is_empty():
        # Нет разбивки (старый сейв) — считаем всё "common".
        return {"common": amount}

    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return {"common": amount}

    var consumed = {}
    var remaining = amount

    # Определяем порядок списания уровней качества.
    var order = []
    if priority == "worst":
        order = levels.duplicate() # от худшего к лучшему
    elif priority == "random":
        order = levels.duplicate()
        order.shuffle()
    else: # "best" и по умолчанию — от лучшего к худшему
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

    # Если осталось (например, разбивка неполная) — списываем как common.
    if remaining > 0:
        consumed["common"] = consumed.get("common", 0) + remaining

    return consumed

# Возвращает уровень качества, соответствующий взвешенному среднему
# по разбивке consumed (словарь {quality: count}).
# Используется при производстве: качество результата = взвешенное среднее
# качества потреблённого сырья, округлённое до ближайшего уровня.
# Собирает плоскую разбивку потреблённого сырья по качеству из контейнера
# крафта: для каждого слота ингредиента проходит по накопленным «входам»
# (consumed) и складывает в единый словарь {quality: count}.
# Используется при завершении крафта для расчёта качества результата —
# прямой аналог consumed_all в старой пакетной логике.
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
    # Округляем до ближайшего уровня качества.
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
            # produces может быть числом или диапазоном [min, max] — для
            # детерминированного непрерывного производства берём минимум
            # диапазона (см. RangeUtils).
            var amount = ceili(float(RangeUtils.get_min_value(raw["produces"][pid], 1)) * multiplier)
            # Проверяем, доступен ли этот продукт (по технологии)
            if not _is_product_available(pid):
                continue
            if amount <= 0:
                continue
            # Всегда добавляем в storage и записываем источник (раньше в первом
            # тике, когда продукта ещё не было в city_storage, источник
            # вообще не записывался — это и был баг «тултип пустой на новом
            # производстве»).
            add_to_storage(pid, amount, quality)
            if source_id != "":
                record_production_source(pid, source_id, amount)
            else:
                production_rates[pid] += amount

# --- ВРЕМЯ РЕЦЕПТА (time) ---
# Рецепт слота здания исполняется непрерывно: ингредиенты забираются
# со склада поштучно с рассчитанной скоростью (required / time ед./сек).
# Крафт считается завершённым, когда ВСЕ ингредиенты набраны и прошло
# craft_time секунд. Если сырья не хватает — контейнер «замерзает»
# (время не копит, ингредиенты не забираются), и крафт автоматически
# затягивается до появления сырья на складе.
#
# На каждый слот здания заводится CraftContainer (см. scripts/craft_container.gd),
# который хранит состояние заполнения и список «входов» с качествами для
# расчёта качества результата. Контейнеры сериализуются вместе с
# city_built_buildings под ключом "slot_containers".
#
# Шаг симуляции — SIMULATION_TICK (1 сек). Дробные остатки за тик
# копятся в контейнере (sub-unit accumulator), поэтому средняя скорость
# не дрейфует (21/5 = 4.2 → чередуем 4 и 5 единиц).

# Время одного крафта рецепта в секундах. Поле time отсутствует или <= 0 —
# рецепт ведёт себя как раньше: крафт каждый тик симуляции.
func get_craft_time(recipe: Dictionary) -> float:
    var t := float(recipe.get("time", 0.0))
    if t <= 0.0:
        return SIMULATION_TICK
    return t

# Возвращает данные рецепта по id (или пустой словарь, если рецепт не найден).
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
    # Подгоняем массив под текущее число слотов.
    while containers.size() < slots.size():
        containers.append(null)
    if containers.size() > slots.size():
        containers.resize(slots.size())
    # Ленивое восстановление сериализованных контейнеров из сейва:
    # SaveManager._serialize_buildings пишет плоские dict (JSON-совместимые),
    # поэтому после загрузки здесь лежат dict, а не объекты. При первом
    # обращении пересобираем CraftContainer по ТЕКУЩЕМУ рецепту слота;
    # несовместимость рецепта контейнер разруливает сам
    # (_restore_from_slot_data мерджит состояние по совпадающим ингредиентам).
    # Без этого типизированное присваивание в _ensure_slot_container падало бы
    # на dict после загрузки сейва.
    for i in range(mini(containers.size(), slots.size())):
        var c = containers[i]
        if c == null or c is CraftContainer:
            continue
        var recipe = get_craft_by_id(str(slots[i]))
        if recipe.is_empty():
            # Рецепт слота не разрешается — слот считается пустым
            # (та же семантика, что в _ensure_slot_container).
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
        # Используем сохранённое состояние, если оно соответствует
        # текущему рецепту (для будущих сейвов в новом формате).
        var saved = null
        if slot_idx < old_progress.size() and old_progress[slot_idx] is Dictionary:
            saved = old_progress[slot_idx]
        out.append(CraftContainer.new(recipe, saved if saved != null else {}))
    # Чистим старый ключ, чтобы не таскать его в сейвах.
    bld.erase("slot_progress")
    return out

# Контейнер конкретного слота или null, если слот пуст / рецепт не найден.
func get_slot_container(b_index: int, slot_idx: int) -> CraftContainer:
    var containers := get_slot_containers(b_index)
    if slot_idx < 0 or slot_idx >= containers.size():
        return null
    var c = containers[slot_idx]
    if c is CraftContainer:
        return c
    return null

# Возвращает или создаёт контейнер слота, синхронизируя с текущим рецептом.
# Если рецепт в слоте изменился — пересоздаёт контейнер (сбрасывая прогресс).
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
    # Рецепт изменился — пересоздаём.
    var fresh = CraftContainer.new(recipe)
    containers[slot_idx] = fresh
    return fresh

# Время крафта рецепта в слоте здания (0, если слот пуст или рецепт не найден).
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

# Доля готовности текущего крафта слота (0..1) — для UI панели здания.
func get_slot_progress_ratio(b_index: int, slot_idx: int) -> float:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return 0.0
    return c.completion_ratio()

# Текстовое состояние контейнера слота для UI панели здания.
# Пример: "8/20 (3.4 сек)" — заполненность первого ингредиента + время.
func get_slot_status_text(b_index: int, slot_idx: int) -> String:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return ""
    return c.status_text()

# Сбрасывает контейнер слота: после смены рецепта слот начинает
# отсчёт крафта заново.
func reset_slot_progress(b_index: int, slot_idx: int) -> void:
    var c := get_slot_container(b_index, slot_idx)
    if c != null:
        c.reset()

func do_tick():
    if Engine.is_editor_hint():
        return

    # Вклад зданий науки в скорость пересчитывается с нуля каждый тик
    # (см. блок «РЕЦЕПТ „НАУКА"» в цикле зданий ниже). Записи по зданиям
    # собираются в промежуточный список, после цикла из него собирается
    # science_breakdown.
    science_buildings_rate_per_sec = 0.0
    var science_breakdown_buildings: Array = []

    # --- Работа зданий (только если есть горожанин) ---
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    # WorkerManager — потребление расходников профессией горожанина
    # (tick_building_consumption) и множитель производства от неё.
    var wm = main_map.get_node("WorkerManager") if main_map and main_map.has_node("WorkerManager") else null

    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Идентификатор здания — общий источник для прихода и расхода его
        # рецептов (показывает «Ручная мельница», «Дом варщика» в тултипе
        # ресурсов; подпись резолвит ui_helpers по id).
        var building_source = GameData.building_source_id(str(bld.get("id", "")))

        # Проверяем, есть ли горожанин на этом здании
        var has_worker = false
        if tm:
            has_worker = tm.has_townsfolk(i)

        if not has_worker:
            continue # здание не работает

        # --- ПРОФЕССИЯ ГОРОЖАНИНА (поле "profession" в data/buildings.json) ---
        # Потребление расходников профессией и множитель её производства.
        # Тикает раз на здание за тик (не на слот!) и только у РАБОТАЮЩЕГО
        # здания: у простаивающего (все слоты пусты) расходники впустую не
        # тратятся. Множитель передаётся в CraftContainer ниже и применяется к
        # начислению науки за завершённый цикл. Бонусы одиночных записей
        # складываются, у групповых берётся лучший (см.
        # worker_manager._aggregate_production_bonus).
        var prof_multiplier := 1.0
        if wm != null and not are_all_slots_empty(i):
            prof_multiplier = wm.tick_building_consumption(i, SIMULATION_TICK)

        # --- НЕПРЕРЫВНЫЙ КРАФТ (CraftContainer) ---
        # Приоритет качества сырья: из здания или дефолт. Передаётся в контейнер
        # для списания и влияет на выбор качества внутри @-групп.
        var priority = bld.get("quality_priority", GameData.get_quality_priority_default())

        for slot_idx in range(slots.size()):
            var recipe_id = slots[slot_idx]
            if recipe_id == "" or recipe_id == "empty":
                continue

            var container: CraftContainer = _ensure_slot_container(i, slot_idx)
            if container == null:
                continue

            # Продвигаем контейнер на один тик. tick() сам списывает ингредиенты
            # со склада (через CityData.remove_from_storage) и возвращает:
            #   consumed_breakdown — разбивка по качествам для тултипа ресурсов
            #                          и расчёта качества science;
            #   releases — что выпустить на склад в этот тик (постепенный выпуск
            #              результата пропорционально прогрессу: full_amount /
            #              craft_time единиц/сек, с sub-unit accumulator для
            #              целочисленной точности). При completed добивается
            #              остаток fractional — выпускается ровно full_amount
            #              за весь цикл.
            #   completed — true если контейнер полон И прошло craft_time.
            var tick_res: Dictionary = container.tick(SIMULATION_TICK, has_worker, priority, prof_multiplier)

            # --- РЕГИСТРАЦИЯ РАСХОДА ЗА ТИК ---
            # Записываем consumption source для тултипа ресурсов и UI-метки
            # динамики. В continuous-модели потребление идёт каждый тик, и эта
            # запись — основной источник данных для красной метки [−N≈].
            var consumed_breakdown: Dictionary = tick_res.get("consumed_breakdown", {})
            for consumed_pid in consumed_breakdown:
                var total_consumed := 0
                for qid in consumed_breakdown[consumed_pid]:
                    total_consumed += int(consumed_breakdown[consumed_pid][qid])
                if total_consumed > 0:
                    record_consumption_source(consumed_pid, building_source, total_consumed)

            # --- РЕЦЕПТ «НАУКА»: прямой вклад в скорость исследований ---
            # Пула науки больше нет: наука зданий не копится на складе, а
            # напрямую складывается в скорость изучения технологий (см.
            # docs.md, «Наука: производство и исследования»). Формула
            # по зданию:
            #   * фиксированный выход здания (additional_yield.science —
            #     очков/сек у Библиотеки и Скриптория) — течёт, пока здание
            #     работает (есть горожанин и непустой слот), даже без основ;
            #   * наука от основ для письма — средневзвешенный special_yield
            #     смеси, которую здание фактически расходует (consumed_pids).
            #     Ни required, ни craft_time рецепта в скорость НЕ входят:
            #     рецепт — лишь «пропуск» (пока сырьё доступно — missing
            #     пуст — учёные работают), его вход задаёт только расход
            #     топлива со склада. Скорость работы учёных определяется
            #     самим special_yield основ (глин. таблички +1, папирус +2,
            #     пергамент +3, шёлк +3, бумага +5). Пока состава нет —
            #     вклад основ 0.
            #   * всё это умножается на бонус профессии учёного
            #     (перья/чернила): (fixed + mediums) × prof_multiplier.
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
                        # Средневзвешенный special_yield смеси основ, которую
                        # фактически расходует слот (consumed_pids копится по
                        # pid и переживает reset цикла). Это и есть вклад
                        # основ в скорость науки — без множителей.
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
                # Разбивка для тултипа: fixed/mediums пишутся БЕЗ бонуса —
                # множитель применяется к сумме при выводе. bonus_names —
                # продукты, чьё потребление даёт бонус профессии здания.
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

            # --- ПОСТЕПЕННЫЙ ВЫПУСК РЕЗУЛЬТАТА (каждый тик) ---
            # Каждая «порция» выпуска имеет качество, рассчитанное по
            # накопленному consumed на текущий момент (см. CraftContainer._compute_quality_from_consumed).
            # Это семантически согласуется с UI: метка [≈] показывает плановый
            # per_sec, а на склад фактически приходит +N за тик (в среднем).
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

            # --- КРАФТ ЗАВЕРШЁН ---
            # На этом этапе releases за тик уже включает «добивку» остатка
            # fractional — суммарно за цикл выпускается ровно full_amount для
            # каждого pid результата. Ничего дополнительно добавлять не нужно.
            # Особый случай рецепта «science» не нужен: его вклад в скорость
            # исследований начисляется каждый тик выше (блок «РЕЦЕПТ
            # „НАУКА"»), на склад наука не поступает.

            # --- СБРОС КОНТЕЙНЕРА ДЛЯ СЛЕДУЮЩЕГО КРАФТА ---
            container.reset()

    # --- РАЗБИВКА СКОРОСТИ НАУКИ ПО ИСТОЧНИКАМ (для тултипа) ---
    science_breakdown = {
        "base": BASE_SCIENCE_PER_SEC,
        "buildings": science_breakdown_buildings,
        "total": get_science_rate_per_sec()
    }

    # --- Потребление еды населением ---
    # Еда потребляется без учёта качества (качество — визуальная механика),
    # поэтому списываем по умолчанию "best" через хелпер, чтобы детализация
    # качества всегда оставалась консистентной.
    # Дебаг-переключатель: пока food_consumption_enabled == false жители
    # НЕ едят еду (тумблер в дебаг-меню). Рост/убыль населения при этом
    # считается как обычно — отключено только само списание еды со склада.
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

    # --- НАЛОГИ: каждый житель платит базовый налог в казну каждый тик ---
    # Порядок важен: сбор идёт ПОСЛЕ потребления еды и ДО
    # _check_population_change() — налог за тик платят те, кто жил в этом тике
    # (рост/убыль населения учтутся со следующего тика). Сумма и запись в
    # разбивку казны — внутри collect_taxes() (см. «Казна города и внутренний
    # рынок» в docs.md, раздел «Налоги»).
    collect_taxes()
    _check_population_change()
    emit_signal("city_updated")

func _check_population_change():
    var available_food = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            available_food += city_storage.get(pid, 0)

    # --- ДИНАМИКА ЕДЫ (для определения голода) ---
    var total_prod = 0
    var total_cons = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            total_prod += production_rates.get(pid, 0)
            total_cons += consumption_rates.get(pid, 0)

    var main_map = get_tree().root.find_child("MainMap", true, false)

    # --- РОСТ НАСЕЛЕНИЯ ---
    if available_food >= food_for_new_settler and total_population > 0:
        total_population += 1
        idle_population += 1 # новый житель пока свободен

        # Пытаемся назначить его на работу (сначала на улучшение, потом в город)
        var assigned = false
        if main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            assigned = wm.assign_worker() # уменьшит idle_population при успехе

        if not assigned and main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            assigned = tm.assign_townsfolk()

        # Если никуда не назначился — остаётся в idle_population

        # Списываем еду за рождение
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
        print("Население выросло до ", total_population)

    # --- ГОЛОД (смерть от недостатка еды) ---
    elif available_food == 0 and total_cons > total_prod and total_population > 1:
        total_population -= 1

        # Убираем одного жителя с работы (сначала горожанина, потом рабочего).
        # Умерший НЕ переходит в категорию свободных, поэтому после снятия
        # с работы компенсируем увеличение idle_population.
        var removed = false
        if main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            for i in range(city_built_buildings.size()):
                if tm.has_townsfolk(i):
                    tm.remove_townsfolk(i) # увеличит idle_population
                    idle_population -= 1 # умерший не становится свободным
                    removed = true
                    break

        if not removed and main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            for key in wm.assigned_hexes.keys():
                var parts = key.split(",")
                if parts.size() == 2:
                    wm.remove_worker(int(parts[0]), int(parts[1])) # увеличит idle_population
                    idle_population -= 1 # умерший не становится свободным
                    removed = true
                    break

        # Если житель был свободен (не работал), просто уменьшаем idle_population
        if not removed and idle_population > 0:
            idle_population -= 1

        # Корректируем idle_population, чтобы он не превышал total_population
        if idle_population > total_population:
            idle_population = total_population

        emit_signal("population_changed", total_population)
        print("Население уменьшилось до ", total_population)

# --- ИССЛЕДОВАНИЯ ---
func start_research(tech_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    # Дебаг: при включённом «не учитывать требования» технология изучается
    # мгновенно — без постановки в очередь, проверки prereq/эпох и накопления
    # науки. Текущее исследование при этом не прерывается.
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
    # Исследование не требует еды — только очки науки.
    current_research_tech_id = tech_id
    current_research_science_cost = int(tech_data.get("science_cost", 3))
    research_progress = 0.0
    research_science_accumulated = 0.0
    print("Начато исследование: ", tech_data["name"])
    emit_signal("city_updated")
    return true

# Мгновенно разблокирует технологию — используется в дебаг-режиме
# «не учитывать требования технологий» (ignore_tech_requirements), когда
# изучение должно происходить сразу, без очереди и накопления науки.
# Изучается только выбранная технология: предшественники НЕ добавляются.
# Текущее исследование (current_research_tech_id) не трогается.
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
    # Технология может открывать новые виды ресурсов — спавним их на карте и
    # готовим сообщения для попапа (аналогично _complete_research).
    last_research_messages = spawn_resource_on_tech_research(tech_id)
    emit_signal("research_completed", tech_id)
    emit_signal("city_updated")
    print("Мгновенно изучена (дебаг): ", tech_data.get("name", tech_id))
    return true

# Фактическая скорость науки города (очков/сек) — прямая сумма источников:
# базовый доход (BASE_SCIENCE_PER_SEC) плюс вклад работающих зданий науки
# (кэш science_buildings_rate_per_sec, пересчитывается раз в тик в do_tick).
# Пула науки нет: произведённая наука не копится на складе, а сразу задаёт
# скорость изучения технологий (см. tick_research_science_continuous и
# docs.md, «Наука: производство и исследования»).
func get_science_rate_per_sec() -> float:
    return BASE_SCIENCE_PER_SEC + science_buildings_rate_per_sec

# Разбивка скорости науки по источникам (см. science_breakdown) — для тултипа
# на вкладке «Технологии». Кэш заполняется раз в тик в do_tick().
func get_science_breakdown() -> Dictionary:
    return science_breakdown

# Возвращает количество накопленных очков науки по текущему исследованию.
func get_research_science_collected() -> float:
    return research_science_accumulated

# Обновляет прогресс исследования непрерывно — вызывается каждый кадр
# из _process в main_map.gd. Скорость — прямая сумма всех источников науки
# (get_science_rate_per_sec: база + работающие здания науки), поэтому
# прогресс-бар растёт плавно покадрово. Наука НЕ копится: пока исследования
# нет, начисления не происходит, а выработка зданий «впустую» теряется
# (пул науки убран, см. docs.md, «Наука: производство и исследования»).
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
    # Технология может открывать новые виды ресурсов — спавним их на карте.
    # Сообщения готовим ДО сигнала research_completed, чтобы попап
    # мог отобразить найденные ресурсы сразу.
    last_research_messages = spawn_resource_on_tech_research(completed_tech_id)
    emit_signal("research_completed", current_research_tech_id)
    # После завершения исследования очки науки сбрасываются на ноль.
    current_research_tech_id = ""
    current_research_science_cost = 0
    research_progress = 0.0
    research_science_accumulated = 0.0
    emit_signal("city_updated")

func is_tech_unlocked(tech_id: String) -> bool:
    return tech_id in unlocked_technologies

# Человекочитаемое название технологии по её id (для сообщений игроку и
# тултипов). Если технология не найдена — возвращается сам id, чтобы в
# сообщении не оказалось пустой строки.
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

# Проверяет, выполнены ли prerequisites технологии.
# Формат: [ [A, B], [C] ] => (A И B) ИЛИ C
func are_prerequisites_met(tech_id: String) -> bool:
    # Дебаг: при включённом «не учитывать требования» prerequisites не
    # проверяются вовсе. Изучается только выбранная технология, предшественники
    # в unlocked_technologies не добавляются (см. _complete_research).
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

# Возвращает человекочитаемый текст требований технологии.
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

# Доступна ли технология для изучения (prerequisites выполнены, не изучена,
# не в процессе, эпоха не выше текущей).
func is_tech_available(tech_id: String) -> bool:
    if tech_id in unlocked_technologies:
        return false
    if tech_id == current_research_tech_id:
        return false
    if not is_tech_era_allowed(tech_id):
        return false
    return are_prerequisites_met(tech_id)

# Возвращает список id технологий (в порядке их изучения — от корня до target),
# которые игроку ещё нужно изучить, чтобы стала доступной tech_id.
# Уже изученные технологии пропускаются; требования берутся из поля
# `prerequisites` (группы ИЛИ · элементов И — выбирается группа с наименьшим
# числом недостающих технологий). Исключаются циклы и дубликаты.
# Используется для кнопки «Изучить ...» в панели управления спецдействий.
func get_tech_study_chain(tech_id: String) -> Array:
    var chain: Array = []
    _collect_tech_chain(tech_id, chain, {})
    return chain

# Максимальное количество «хопов» — технологий, оставшихся до открытия целевой
# технологии (НЕ считая саму цель), — при котором панель управления показывает
# кнопки постройки улучшения, заблокированного технологией, и изучения этой
# технологии. Требование: кнопки видны только если хопов ≤ TECH_HOPS_MAX.
const TECH_HOPS_MAX := 2

# Сколько технологий осталось изучить, чтобы открыть tech_id (сама tech_id
# НЕ считается). Пример для «Каналов» (canals): на старте цепочка = 3
# («Ирригация», «Горное дело», «Каменная кладка») → 3 хопа; после изучения
# «Ирригации» → 2 хопа («Горное дело», «Каменная кладка»).
func get_tech_hops(tech_id: String) -> int:
    return maxi(0, get_tech_study_chain(tech_id).size() - 1)

func _collect_tech_chain(tech_id: String, chain: Array, visiting: Dictionary) -> void:
    if tech_id in visiting or tech_id in chain:
        return
    var data = _get_tech_data(tech_id)
    if data == null or is_tech_unlocked(tech_id):
        return
    # Технологии будущих эпох в цепочку не попадают: их нельзя изучать,
    # пока не совершён переход в соответствующую эпоху.
    if not is_tech_era_allowed(tech_id):
        return
    var prereqs: Array = data.get("prerequisites", [])
    if not prereqs.is_empty():
        # Выбираем группу предусловий с наименьшим числом недостающих технологий.
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

# Открыто ли здание игроку (по полю unlock_tech самого здания).
func is_building_unlocked(building_id: String) -> bool:
    for b in GameData.buildings:
        if b["id"] == building_id:
            var required_tech = b.get("unlock_tech", "")
            if required_tech != "":
                return is_tech_unlocked(required_tech)
    return true

# Проверяет дополнительные условия строительства здания из buildings.json.
# Возвращает словарь {"ok": bool, "reason": String}, чтобы UI и фактический
# запуск строительства показывали одинаковую причину отказа.
func check_building_additional_req(building_id: String) -> Dictionary:
    # Дебаг: при включённом «Игнорировать требования строительства» любые
    # дополнительные условия (additional_req) считаются выполненными.
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

# Открыто ли улучшение игроку (по полю unlock_tech самого улучшения).
func is_improvement_unlocked(imp_id: String) -> bool:
    if imp_id == null or imp_id == "":
        return true
    var imp_data = GameData.improvements.get(imp_id, {})
    var required_tech = imp_data.get("unlock_tech", "")
    if required_tech != "":
        return is_tech_unlocked(required_tech)
    return true

# Возвращает id технологии, открывающей указанное улучшение (для контекстного меню).
func get_improvement_unlock_tech(imp_id: String) -> String:
    var imp_data = GameData.improvements.get(imp_id, {})
    return imp_data.get("unlock_tech", "")

# Формирует сообщения о ресурсах, раскрываемых изученной технологией.
# Вызывается после завершения исследования технологии.
#
# Новая модель (см. docs.md, «tech_reveal: скрытые ресурсы»):
#   - Все ресурсы спавнятся на карте с самого старта (map_generator.gd).
#   - tech_required гейтит постройку улучшения (как и раньше).
#   - tech_reveal гейтит видимость самого ресурса на карте.
#   - Эта функция перечисляет ресурсы, у которых tech_reveal == tech_id,
#     и для каждого формирует сообщение:
#       * ресурс есть на карте          → "Учёные оценили: найдено <X>."
#       * ресурса на карте нет          → "Похоже, в вашем регионе <X> отсутствует."
#   - Размещением на карте функция НЕ занимается: все ресурсы уже там
#     с момента генерации карты.
#
# Гарантия «1 металл в стартовом Кольце + Регионе» обеспечивается отдельно
# в main_map._initialize_map через MapHelpers.ensure_minimum_resource.
# Возвращает массив сообщений для попапа технологии.
func spawn_resource_on_tech_research(tech_id: String) -> Array:
    var messages = []
    if Engine.is_editor_hint():
        return messages
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return messages
    var tile_data = main_map.tile_data

    # Собираем виды ресурсов, РАСКРЫВАЕМЫХ этой технологией (tech_reveal).
    # Если у ресурса нет tech_reveal — он виден сразу и эта функция его
    # не упоминает; если tech_reveal есть, но не совпадает с tech_id,
    # ресурс ещё скрыт и о нём мы тоже не сообщаем.
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

# Проверяет, есть ли на карте хотя бы один гекс с указанным ресурсом.
func _is_resource_on_map(tile_data: Array, res_id: String) -> bool:
    for row in tile_data:
        for tile in row:
            if tile.get("resource", null) == res_id:
                return true
    return false

# Проверяет, присутствует ли на карте хотя бы один ресурс, РАСКРЫВАЕМЫЙ
# указанной технологией (tech_reveal == tech_id).
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

# Вызывается при загрузке сохранения: для уже изученных технологий
# гарантирует, что открытые ими ресурсы корректно отображаются.
# В новой модели (все ресурсы уже на карте) это, по сути, no-op: если
# ресурс с tech_reveal == tech_id на карте есть (а он там есть в норме),
# функция ничего не делает. Если сейв старый и ресурс на карте отсутствует,
# нового спавна тоже не делаем — старые сохранения с повреждённой картой
# пользователь чинит сам (или стартует новую партию).
func ensure_tech_resources_spawned():
    if Engine.is_editor_hint():
        return
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return
    var tile_data = main_map.tile_data
    for tech_id in unlocked_technologies:
        # На карте уже есть ресурс, раскрываемый этой технологией — ок.
        if _tech_has_resource_on_map(tile_data, tech_id):
            continue
        # На всякий случай прогоняем функцию (сформирует «отсутствует»
        # сообщения, но в HUD они не пойдут — мы их тут же отбрасываем).
        spawn_resource_on_tech_research(tech_id)

# Проверяет доступность продукта (включая технологии, улучшения и здания).
func _is_product_available(product_id: String) -> bool:
    var product_data = GameData.products.get(product_id, {})
    # Проверка технологии
    var required_tech = product_data.get("unlock_tech", "")
    if required_tech != "" and not is_tech_unlocked(required_tech):
        return false

    # Проверка улучшения (на карте)
    var required_improvement = product_data.get("unlock_improvement", "")
    if required_improvement != "" and not _has_improvement(required_improvement):
        return false

    # Проверка здания (в городе)
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

# --- АПГРЕЙД ЗДАНИЙ ---
# Здание может иметь улучшенную версию: поле "upgrades_into" в buildings.json
# (например, hand_mill -> animal_mill). Апгрейд — обычная стройка в общем пуле
# труда (build_manager), но во время неё здание продолжает работать как обычно,
# а по завершении заменяется на улучшенную версию с переносом настроек
# (рецепты слотов, приоритет качества; работник остаётся привязан к индексу
# здания, поэтому состояние «работает/приостановлено» переносится само).

# Возвращает id улучшенной версии здания (поле "upgrades_into") или пустую
# строку, если у здания нет улучшения.
func get_building_upgrade_target(building_id: String) -> String:
    for b in GameData.buildings:
        if b.get("id", "") == building_id:
            return String(b.get("upgrades_into", ""))
    return ""

# Возвращает данные идущего апгрейда здания по его индексу в городе
# (пустой словарь, если апгрейд не идёт). Проксирует запрос в build_manager,
# где хранятся все активные стройки.
func get_building_upgrade_data(idx: int) -> Dictionary:
    if Engine.is_editor_hint():
        return {}
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null or not main_map.has_node("BuildManager"):
        return {}
    var bm = main_map.get_node("BuildManager")
    return bm.get_building_upgrade_by_index(idx)

# Можно ли начать апгрейд здания под индексом idx:
# - у здания есть поле upgrades_into;
# - улучшенная версия открыта технологией (её unlock_tech изучен);
# - апгрейд этого здания ещё не идёт.
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

# Запускает апгрейд здания под индексом idx в его улучшенную версию.
# Атомарно списывает additional_cost улучшенной версии и регистрирует стройку
# апгрейда в build_manager (либо завершает апгрейд мгновенно, если у улучшенной
# версии work_cost == 0 или включён дебаг-флаг «Игнорировать требования
# строительства»). Возвращает { "ok": bool, "reason": String } для UI.
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

    # Улучшенная версия должна быть открыта технологией.
    if not is_building_unlocked(upgrade_to):
        return {"ok": false, "reason": tr("Research the technology that unlocks \"%s\" first") % upgrade_data.get("name", upgrade_to)}

    # Дополнительные условия улучшенной версии (additional_req).
    var additional_req_check = check_building_additional_req(upgrade_to)
    if not additional_req_check["ok"]:
        return {"ok": false, "reason": additional_req_check["reason"]}

    var main_map = get_tree().root.find_child("MainMap", true, false)
    var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
    if bm == null:
        return {"ok": false, "reason": tr("Construction manager unavailable")}

    # Апгрейд этого здания уже идёт — повторный запуск невозможен.
    if not bm.get_building_upgrade_by_index(idx).is_empty():
        return {"ok": false, "reason": tr("This building is already being upgraded")}

    # Общий лимит одновременных строек (здания + улучшения + апгрейды) равен
    # числу жителей. Проверяем ДО списания материалов.
    var work_cost = upgrade_data.get("work_cost", 0)
    if work_cost > 0 and not ignore_build_requirements:
        if bm.get_total_active_builds() >= total_population:
            return {"ok": false, "reason": tr("You can build or upgrade no more than %d buildings at once (limit = number of citizens)") % total_population}

    # Атомарно списываем additional_cost улучшенной версии (при включённом
    # дебаг-флаге материалы не проверяются и не списываются).
    var cost_check = consume_additional_cost(upgrade_data)
    if not cost_check["ok"]:
        var missing_names = []
        for m in cost_check.get("missing", []):
            missing_names.append(str(m))
        return {"ok": false, "reason": tr("Missing: ") + ", ".join(missing_names)}

    var build_key = bm.start_building_upgrade(idx, from_id, upgrade_to)
    if build_key == "":
        # Мгновенное завершение (work_cost == 0 / дебаг-флаг): сигнал
        # building_upgrade_completed уже эмитнут, main_map обработает его
        # и вызовет complete_building_upgrade.
        emit_signal("city_updated")
        return {"ok": true, "reason": ""}

    emit_signal("building_upgrade_started", idx, upgrade_to, build_key)
    emit_signal("city_updated")
    return {"ok": true, "reason": ""}

# Завершает апгрейд: заменяет здание под индексом idx на улучшенную версию
# с переносом настроек. Вызывается из main_map._on_building_upgrade_completed
# (сигнал build_manager.building_upgrade_completed) или напрямую при
# мгновенном апгрейде. Возвращает true при успехе.
func complete_building_upgrade(idx: int, upgrade_to: String) -> bool:
    if idx < 0 or idx >= city_built_buildings.size():
        return false
    var old_bld = city_built_buildings[idx]
    var from_id: String = old_bld.get("id", "")
    if from_id == "" or get_building_upgrade_target(from_id) != upgrade_to:
        return false

    # Настройки старой версии: выбранные рецепты слотов и приоритет качества.
    var old_slots: Array = old_bld.get("slots", [])
    var priority: String = old_bld.get("quality_priority", GameData.get_quality_priority_default())

    # Данные улучшенной версии: число слотов и дефолтные рецепты.
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

    # Перенос рецептов: рецепт, исполняемый и в новой версии, сохраняется;
    # непригодные (например, ручной помол зерна при апгрейде в мельницу с
    # животной тягой) заменяются дефолтным рецептом новой версии или «Пусто».
    var new_slots: Array = []
    for i in range(slot_count):
        var selected_id: String = old_slots[i] if i < old_slots.size() else ""
        if selected_id == "" or selected_id == "empty":
            # Пустой слот остаётся пустым — выбор игрока сохраняется.
            new_slots.append("empty")
        elif can_craft_in(selected_id, upgrade_to):
            new_slots.append(selected_id)
        else:
            if i < default_recipes.size():
                new_slots.append(default_recipes[i])
            else:
                new_slots.append("empty")

    # Состояние «работает/приостановлено» переносится само: работник привязан
    # к индексу здания (townsfolk_manager), а индекс не меняется.
    city_built_buildings[idx] = {
        "id": upgrade_to,
        "slots": new_slots,
        "quality_priority": priority
    }
    emit_signal("city_updated")
    return true

# Конвертирует старые записи зданий {"id": ..., "recipe": ...} в новый формат {"id": ..., "slots": [...]}.
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
    # Если в старом сейве был конкретный рецепт — ставим его в первый слот
    if legacy_recipe != "" and legacy_recipe != "empty":
        if slots.size() > 0:
            slots[0] = legacy_recipe
        else:
            slots.append(legacy_recipe)
    return slots

# Списывает additional_cost здания со склада. Поддерживает обе формы поля
# (объект и массив пачек с AND-логикой) и групповые ключи (@xxx) — для них
# списание распределяется по членам группы, как в рецептах.
# Атомарно: если хотя бы одной пачки не хватает — НИЧЕГО не списывается.
# Возвращает { "ok": true } при успехе или { "ok": false, "missing": [имена...] }.
func consume_additional_cost(bdata: Dictionary) -> Dictionary:
    # Дебаг: при включённом «Игнорировать требования строительства»
    # дополнительные материалы не проверяются и не списываются.
    if ignore_build_requirements:
        return {"ok": true}
    if not bdata.has("additional_cost"):
        return {"ok": true}
    var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
    if bundles.is_empty():
        return {"ok": true}

    # Первый проход: проверяем, что всего хватает, и собираем план списания
    # [{ "prod_id": amount, ... }, ...] — по плану на каждую пачку.
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
                # Ключ "@"-группы — всегда id из product_groups.json.
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
                # Собираем сколько откуда брать (жадно по списку группы)
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

    # Второй проход: всё проверено — списываем. Приоритет качества — как
    # в рецептах (по умолчанию «лучшее»).
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
    # Здание должно быть открыто изученной технологией
    if not is_building_unlocked(building_id):
        print("Здание недоступно: ", bdata.get("name", building_id))
        return false
    var additional_req_check = check_building_additional_req(building_id)
    if not additional_req_check["ok"]:
        print("Не выполнено условие для постройки ",
            bdata.get("name", building_id), ": ", additional_req_check["reason"])
        return false
    # Списываем additional_cost (если есть) — атомарно, до старта стройки.
    # Поддерживает массив пачек (AND-логика) и групповые ключи (@xxx).
    var cost_check = consume_additional_cost(bdata)
    if not cost_check["ok"]:
        print("Не хватает ресурсов для постройки ", bdata.get("name", building_id), ": ", cost_check.get("missing", []))
        return false
    var work_cost = bdata.get("work_cost", 0)
    # Общий лимит одновременных строек (здания + улучшения) равен общему числу жителей.
    # При включённом «Игнорировать требования строительства» лимит не применяется —
    # здания строятся мгновенно и не попадают в очередь строек.
    if work_cost > 0 and not ignore_build_requirements:
        var main_map = get_tree().root.find_child("MainMap", true, false)
        var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
        var total_active = building_construction.size()
        if bm:
            total_active = bm.get_total_active_builds()
        if total_active >= total_population:
            print("Можно строить не более %d зданий или улучшений одновременно (лимит = число жителей)" % total_population)
            return false
    # Строительство зданий теперь требует труд, а не еду. При включённом
    # «Игнорировать требования строительства» даже здания с work_cost > 0
    # строятся мгновенно (флаг CityData.ignore_build_requirements).
    if work_cost <= 0 or ignore_build_requirements:
        # Если стоимость 0 (например, ручная мельница), строим мгновенно
        city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})

        # Автоматически назначаем горожанина на новое здание, если есть свободные
        var townsfolk_map = get_tree().root.find_child("MainMap", true, false)
        if townsfolk_map and townsfolk_map.has_node("TownsfolkManager"):
            var tm = townsfolk_map.get_node("TownsfolkManager")
            tm.assign_townsfolk()

        emit_signal("city_updated")
        return true

    # Для зданий с work_cost > 0 запускаем стройку через build_manager
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map and main_map.has_node("BuildManager"):
        var bm = main_map.get_node("BuildManager")
        var build_key = bm.start_building_build(building_id)
        if build_key != "":
            # Сохраняем стройку в отдельный словарь, здание появится в городе только после завершения
            building_construction[build_key] = {
                "building_id": building_id,
                "build_key": build_key,
                "slots": _auto_assign_slots(building_id)
            }
            emit_signal("building_construction_started", building_id, build_key)
            emit_signal("city_updated")
            return true
        return false

    # Если build_manager недоступен, строим мгновенно (fallback)
    city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})
    if main_map and main_map.has_node("TownsfolkManager"):
        var tm2 = main_map.get_node("TownsfolkManager")
        tm2.assign_townsfolk()
    emit_signal("city_updated")
    return true

# Автоназначение рецептов на слоты при постройке здания:
# 1. Берём default_recipes здания
# 2. Назначаем на слоты по порядку, без повторения
# 3. Если слотов больше, чем рецептов — остальные получают "empty"
# 4. Если рецептов больше, чем слотов — лишние просто не помещаются
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

# Возвращает true, если все слоты здания пусты (рецепт "Пусто" или "").
# Используется для отображения статуса "простаивает".
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

# Проверяет, может ли рецепт исполняться в указанном здании.
# produced_in поддерживает массив значений; "*" означает "в любом здании" (пустой рецепт).
func can_craft_in(craft_id: String, building_id: String) -> bool:
    var recipe = null
    for c in GameData.crafts:
        if c["id"] == craft_id:
            recipe = c
            break
    if not recipe:
        return false

    var produced_in = recipe.get("produced_in", [])
    # Обратная совместимость: если produced_in — строка, приводим к массиву
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

# Возвращает итоговый множитель производства для улучшения imp_id.
# has_fresh_water — есть ли доступ к пресной проточной воде на гексе.
# terrain_id — тип местности гекса (для модификаторов по местности,
#   например, асфальтовое озеро даёт x2 к битуму).
# resource_id — id ресурса на гексе (для модификаторов по местности).
func get_improvement_production_multiplier(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> float:
    var multiplier = 1.0
    for mod in get_improvement_production_modifiers(imp_id, has_fresh_water, terrain_id, resource_id):
        multiplier *= mod.get("multiplier", 1.0)
    return multiplier

# Возвращает список активных модификаторов производства для улучшения imp_id.
# Каждый элемент: { "label": String, "multiplier": float }
# terrain_id — тип местности гекса (для модификаторов по местности).
# resource_id — id ресурса на гексе (для модификаторов по местности).
func get_improvement_production_modifiers(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> Array:
    var result = []
    if imp_id == null or imp_id == "":
        return result

    # Модификатор доступа к пресной проточной воде
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

    # Модификаторы по типу местности (terrain_modifiers).
    # Применяются, когда на гексе с указанным terrain_id добывается
    # указанный resource_id (через улучшение). Например, битум на
    # асфальтовом озере (asphalt_lake) даёт x2 к производству.
    # См. data/modifiers.json, блок "terrain_modifiers".
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

    # Модификаторы от изученных технологий
    for tm in GameData.modifiers.get("tech_modifiers", []):
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not is_tech_unlocked(tech_id):
            continue
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break

        # Универсальный формат: "production_multiplier": { "<imp_id>": 1.05 }
        # (по аналогии с бонусом от пресной воды).
        var multipliers = tm.get("production_multiplier", {})
        if multipliers.has(imp_id):
            var m = float(multipliers[imp_id])
            if m != 1.0:
                result.append({
                    "label": "+%d%% (%s)" % [int(round((m - 1.0) * 100.0)), tech_name],
                    "multiplier": m
                })

        # Старый формат с полем "modifiers" (target == "<imp_id>_production").
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
