# The City Development Diary

## How to keep this diary (for AI assistants)

This file is a **record of principled decisions**, not a commit log and not a bug tracker.
It answers one question: *why the game is built this way and not otherwise*. It is read
months later, when the code is no longer in front of you — so entries are written as an explanation,
not as a report.

### When you should NOT write here

The diary is **not required** after:

- a typo, a rename, formatting, a comment or a docstring;
- a minor fix ("silent click", "the highlight drifts", "a panel sticks out past another panel");
- tweaking a constant, a balance number, a color, a delay, a timing;
- a refactor that does not change behavior;
- "fixed / cleaned up / added text to the UI / moved a test / moved an anchor".

All of this is already told by `git log` and by commit messages. Duplicating it here
means reading a stale copy of a commit a month later. **After fixing a typo,
an entry here is not needed.**

### When you should write

- A decision whose meaning **cannot be read from the code**: why "this way" is right,
  while "the other way" works, but is wrong.
- **A rejected option — together with the reason.** The absence of code does not explain why
  something is deliberately missing; without an entry, this decision will be revisited from scratch.
- **An invariant** ("this must not be done") — so that the next session does not break it,
  not knowing what it is for.
- **An expensive trap or convention** that has already been stepped on.
- **A change of frame**: what is now considered the source of truth, and what is derived from it.

### Entry format

Heading `## <what was decided> (date)`, then in short blocks: **context/problem →
decision → what we deliberately do not do**.

Do not write: a list of changed files and functions, test numbers, "Check: 22 tests
— OK", "verified via `git stash` on a clean HEAD". This is not a log. If an entry
reads like "fixed X" — it does not belong here. If you can throw away half of an entry
and lose nothing — throw it away.

### What this diary is not

A list of what is implemented, a task plan, a backlog, a test-run report. The state of the project
lives in `docs.md` and `README.md`, the history — in `git log`. None of it is duplicated here.

---

## Context about the author

- The author is a game designer and tester, a self-taught programmer: his main experience is C++ and
  modifying other people's code; he came to Godot/GDScript from Python and is learning as he goes.
- Working style: a detailed spec → the assistant implements → the author tests and fixes.
  Bursts of coding sessions plus long design brainstorms.
- Strengths: game-design thinking, pragmatism ("first the base, then
  the polish"), respect for the player.
- Constraint: only free tiers → a token quota per 5-hour period, after
  which the session is cut off. Hence the main pain: after the quota runs out, the author is left
  with code he barely understands.
- Consequence for the assistant: changes must be explainable without a live interlocutor.
  That is why the reasons for decisions live here and in `docs.md`, not in the chat.

## What kind of game this is

- Genre: city-building + economic simulator. In spirit — a trimmed-down Civilization:
  one city and its surroundings, without diplomacy, wars and units.
- Setting: from the Neolithic to the present day, 7 eras.
- Stack: Godot Engine 4.7 (Forward+), GDScript.

## Economy: currencies and their decomposition

Key decision: **"food as currency" creates soft-locks**, when production =
consumption and the warehouse is empty: there is nothing to build with, and "shift people to food" looks
artificial. Hence the currencies are divided by meaning, rather than named with a single word:

| Currency | What it means | Rule |
|---|---|---|
| Food | life and expansion | feeds the population; optional sinks — scouting, buying chunks, demolition |
| Labor | the pace of the city's work | **a rate, not a supply** — it does not accumulate |
| Science | research | `science_cost` science points; base income ≥ 1 point per tick |
| Coins | trade | appear from the 2nd era; live in the city's treasury |

**Labor.**
- 1 citizen → 1 labor/sec (base rate). Construction time = `work_cost` / labor per second.
- Labor does not pile up: "I came from the kitchen — I have 500 labor" cannot happen. The cost is
  a constant from JSON, the **time** is computed, not accumulated.
- `work_cost = 0` → instant construction (hand mill).
- Benchmarks: the first farm builds in 6–8 seconds → 8 labor. Then logarithmically:
  map improvements 8–60, city buildings 50–350, technologies 120–2000+.

**Parallel constructions (option B).** If the player has started several constructions,
**the rate is divided equally among them**: each one gets `total_rate / N`, the time of each
grows, but the total amount of work per unit of time equals the size of the city. This is the most
fair and realistic option. The cap "one construction per 5 citizens" we deliberately
do not introduce — let it scale naturally.
- Tick progress every frame: `progress_per_second = labor_per_second / active_builds.size()`.
  Added/removed a construction — the rate of the others changes on its own, nothing has to be recomputed by hand.
  **Do NOT use `create_timer().timeout`** — it is fixed.
- UI: in the context menu "Time: 15 sec (accounting for 1 current construction)", a ⏳ icon
  when there are other active constructions, in the HUD — a list of constructions with progress bars.
- Buildings in the city — no more than one construction at a time (a UI limitation:
  buildings are a text list). Map improvements — no limit.
- Canceling a construction: the spent labor is burned, the building does not appear, materials
  are returned, the rate of the others grows. Satisfaction = 0 → all constructions stall.
  The city is not working — that is fair.

**Satiety is two-factor, not stock-only.** The mechanic "100 food → birth → 0 in
the warehouse" creates false spikes, to which a stock-only metric gives a false
alarm.

```
trend = min(production / max(consumption, 0.01), 1.0)  # pull production toward consumption
stock_factor = clamp(stock / (population * BUFFER), 0.0, 1.0)  # is there a buffer
satiety = trend * 0.7 + stock_factor * 0.3
```

Labor production = population × satisfaction × 1 labor/sec/citizen.

**Scouting and claiming are paid with coins from the treasury, not with food.** Prices are moved out to
`data/game_balance.json`; the labor of claiming is **not** scaled by distance: claiming is
direct labor, while distance affects money.
- **The distance multiplier is a single universal one** for all distance-dependent
  costs, rather than a separate field for improvements, special actions and scouting. Otherwise
  every new distance-dependent action would spawn a field, and their values
  would drift apart.
- The price is computed in one place, inside the charge point, not in the UI: otherwise the display
  and the charge would diverge.
- The treasury does not go negative; on a refusal (for example, hitting the limit of simultaneous
  constructions) the money is returned. Previously, food would disappear on such a refusal.
- `initial_treasury` and the costs are tuned in JSON without editing code.

**What we do not do:** floods and pollution — they contradict "respect for the player".

## Key design patterns

1. **The tension of "buy now vs wait for the era".** Spend food now on the needed
   chunk or save up and get the whole Region for free on an era change. Both options are valid —
   that is the whole point.
2. **Hiding information until research.** The player does not know what is inside an unexplored
   hex. The cost of scouting turns this into a decision: spend on information or guess.
3. **Auto-filling vacancies with the option of manual control.** 95% of the time the player
   leaves it alone, 5% — digs in to fine-tune. Not the other way around.
4. **Domestication as a strategic reserve.** Not "build a farm on every suitable
   hex", but "found wild cows — domesticated them — now they are yours AS LONG AS at least one
   living specimen remains". Lost the last one — the species is gone, you need new scouting or import.
   Creates the tension of "slaughter or breed". It requires animals to be
   a **countable resource**, not a virtual presence on a hex: otherwise the boundary "0 =
   lost" cannot be counted.
5. **"ADD not REMOVE" challenges.** A challenge does not remove options, it adds a new
   development branch. Otherwise the player quickly slides down to 1–2 available options. Examples:
   "Vegan" → the "Herbalist" branch, "Monogamist" → "Breeder", "I don't want to wait" →
   "Colonizer", "It will be mine anyway" → "Diplomat".
6. **Respect for the player.** No "fixed bonuses from the designer". The choice is always
   the player's, meaningful and with consequences.

## Technologies and resources

**One rule: a resource appears on the map only after researching the technology for its
use.** At the start, an implicit technology "Farming" (`farming`) is unlocked.
Technology progress bars for map resources are removed: a technology is not "assembled
from the map".

**Spawning.** **All** resources are placed on the map for which the biome
constraints and `spawn_conditions` are satisfied. Previously a random selection "1–3 per category" was in effect —
it has been removed: because of it the player received a resource that simply does not exist in the world, and the chain
broke. The exception-guarantee: if the starting area (Ring + Region) has no
metal at all, exactly one is added; when new metals appear, the constraint
remains "1 random id", not all at once.
- Spawning only on empty hexes — do not break existing chains.
- An already-scouted hex immediately shows the new resource.
- Resources with `tech_reveal` (underground minerals) spawn like ordinary ones, but are hidden from
  the player until the technology is researched.
- In the Ring resources are visible immediately, in the Region — after scouting.
- If a resource did not spawn at all — the player needs alternatives: other metals,
  import, substituting resources. This is precisely the role of trade.

**Tree format — a pull model** `prerequisites`: `[["A"], ["B","C"]]` = A OR (B AND C).
An empty array = available immediately. Links are stored on the dependent technology, not on the
unlocking one: `unlock_tech` on content (buildings, improvements, recipes) is a separate
mechanic for unlocking content; unavailable content is simply filtered out of the UI.

**The tree is a forest, not a tree.** A broad parallel hub plus short chains;
dependencies are natural (processing chains and historical continuity);
a building is available if its input chain is unlocked. Basic food plants — immediately,
technical and exotic ones — behind technologies. The visualization is horizontal, the root
on the left, time flows to the right, an era = a vertical column.

**Stubs are normal.** While the only player is the author, empty stubs are useful:
they are a visible to-do list.

**The popup after research** shows the name, `description`, `flavor` and the found
resources, pauses the game and works while paused (`PROCESS_MODE_ALWAYS`).

**Grouping of identical buildings:** "Name xN" and the status "(working: M of N)" with
a color indication; the details panel shows all buildings of the type with buttons
for pausing/starting each one.

## Three registries for classifying resources (DO NOT CONFUSE)

- **categories.json** — the visual boxes of the "Resources" tab. The only mechanic:
  the `food` category folds into the Food pool. Everything else (for example, `fruits`) does not go
  into the pool.
- **groups.json** — groups for diversity bonuses and enumeration of domesticated
  species (cattle, grains, textile, oil_crops...).
- **product_groups.json** — groups of interchangeable raw resources **only** for recipes
  (`@millable_grains`, `@oil_crops`). They have nothing to do with bonuses or the UI.

Rule: a category = "what it is", a group = "what it is related to for bonuses",
a product_group = "what it is replaced by in crafting". One product can belong to different
registries independently (flax: textile in groups + oil_crops in product_groups).

## Diversity bonuses: a three-tier scheme

**Terminology.** Group (top level: meat animals, food plants,
minerals — the `group` field) → subgroup (middle level: cattle, grains, textile — the
`subgroup` field) → species (a specific resource). A group's natural bonus follows from what
it produces: minerals → quarries/mines, food plants → farms,
productive animals → honey/happiness, decorative and medicinal ones → happiness/health.

**Three tiers of rewards.**
1. Access to a group (at least one subgroup present) → a base bonus.
2. 3+ subgroups within a group → the bonus grows.
3. 3+ species within a subgroup → an additional bonus to that subgroup.

Both dimensions are rewarded: **width** (subgroups) and **depth** (species). Thresholds and
values live in `bonuses.json`; the UI only renders what is there — new groups
and thresholds are added without editing the UI.

**Access rule (what counts as "present").** A species is counted if it is domesticated
(animals/plants) or if a map improvement producing it is working. **Import
counts as long as the route is active** — this is the second role of trade, and it does not
stop at a disabled road.

**Visualization: three principles.**
1. Layered rows with subtotals, not a single formula in a row.
2. Species icons instead of names, where possible (there are icons for all resources).
3. A hint of the next threshold ("one more subgroup → +4"): the window becomes a list
of goals, not a reference book.

Grey undiscovered groups telegraph the future ("after Mining") and tie
bonuses to technologies and trade. The card is assembled from data and icons with ordinary
primitives (VBox/HBox, Label, TextureRect, ColorRect for the pips) — without custom
drawing.

## Product quality: what was rejected

We wanted to simulate the historical quality of goods (linen canvas is better than jute)
so that quality would affect the sale price. Approaches considered and rejected:

1. **A numeric `quality` field in resources/goods** — opaque: the price becomes a lottery due to
   auto-consumption from `@`-groups, and it does not solve routing.
2. **Tiered recipes** (fine/coarse) — a doubling of goods; does not cover quality
   *through the process* (wine: aging, barrels, conditions — the raw resource is the same).
3. **Batches** (separate storage of varieties) — micromanagement: lists, merging, a variety-selection UI,
   routing.
4. **Average quality over the warehouse** — erases the variety; the market sees no difference; complexity
   with no benefit.
5. **"City reputation"** (a price bonus to the whole line for access to good raw resources) —
   contrived flavor: merchants do not pay more for goods A just because goods B
   are good in the city.

**Bottom line.** Quality is **not** simulated as a market mechanic. The price is a static base
value by product id (× a settlement modifier in trade). "Premium" is expressed by
different product lines (fabric_clothes / wool_clothes / leather_clothes),
not by varieties of a single product. Historical facts live in flavor texts and in the economy
of inputs: a rare raw resource → an expensive good.

**The only permissible niche for quality.** Deposit quality (the chance of
"common/rare/exceptional" at spawn) — only as a currency of prestigious
challenges (the `min_quality` field in a product's specialization). It does not
affect the base economy, and requires no routing from the player.

**A limiting counterexample.** Wine shows that quality often lives in the process,
not in the raw resource. Therefore a "raw-resource" quality scheme cannot become general — and this
example keeps in check all future attempts to return to it.

## Deposit quality affects price: a multiplier, not an addition

The first version of the line format was **additive** ("Price: 4 + 1 (★★) = 5"), and the values
1.15/1.35/1.6 were chosen "softly" so as not to break the balance. This turned out to be wrong
for two reasons at once:

- the same addition in coins to different prices breaks the scale — feed at 1 would get
  +100%, a decoration at 140 +0.7%;
- and, more importantly, when rounding to whole coins **adjacent levels collapsed into one
  price**: `4 × 1.15` and `4 × 1.35` both gave 5, that is, quality stopped being worth
  the difference.

A measurement across all 268 prices from `data/`: at 1.15/1.35/1.6 the levels differ only for 225
goods (43 merged), at 1.25/1.60/2.00 — for 254, at 1.30/1.75/2.30 — for 265 (only
three goods at 1 coin merge). **The last one was chosen: 1.0 / 1.3 / 1.75 / 2.3**,
an expected treasury income of +26.8% with spawn weights 50/30/15/5.

Consequences worth keeping in mind:
- the base is rounded to a whole number **once**, the result = `round(base × multiplier)` — otherwise
  the tooltip and the treasury would compute different prices;
- the multiplier must be **visible in the line text as a separate term**, not hidden
  in the result: the player must see what the price is made of;
- the field is named so that its name shows that it **multiplies**;
- a soft default of 1.0 for an unknown level — old data and saves do not break.

## Reputation, challenges and city specialization (planned)

**Core: a product carries its own specialization.** The single source of truth is the block
`specialization` inside the product. No shared `challenges.json`: a challenge
is created on the fly when the soft-reputation threshold is reached, the parameters are read from
the block, the rewards — from there too. A modder only needs to add a block to their product.
The rewards can be a brand product, a building, a perk and a specialization development branch;
the branches live in a separate small registry, the block merely references an id.

**Three tiers.**
1. *Soft reputation* (automatic) — hidden cumulative counters of what was produced and
   sold for each product, saved to the save file. Retroactivity of progress
   is free. When the threshold is reached: the status "Known for its cheese", a small
   price bonus, a congratulation popup — an emotional surprise reward.
2. *Challenge* (deliberate) — activates automatically after soft reputation;
   the list of challenges and rewards is visible in advance. The condition: sell N units of a good,
   optionally with `min_quality` — then deposit quality works as a currency
   of prestige, and without a quality system the field is simply ignored.
3. *Prestige specialization* — a brand product, a building, a perk, a development branch.

**Fame requires witnesses.** Both tiers are by default counted on the `sell` trigger,
not `produce`: a city that ate all its cheese itself is not known for cheese. For early products
`trigger: produce` is acceptable. Consequence: with a sell trigger, specialization naturally
becomes a mid-game feature, because trade appears from the 2nd era.

**Brand = place of sale (historical accuracy).** The world does not care where a
good was produced — it knows where it was bought: Damascus steel was produced in India (wootz), but
sold through Damascus; "Venetian glass" — from Murano; "Portuguese spices" — from
India and Indonesia; Dutch tulips — from the Ottoman Empire. That is why reselling
imported goods also creates fame, and this is not an exploit, but historical truth.

**A meta-challenge for ingenuity.** A challenge completed "not the way it was
intended" (sell 100 exceptional cheese without producing a single unit —
by reselling imports), is **rewarded**, not punished: a hidden meta-challenge,
a title/perk in the spirit of "Trading hub". ADD not REMOVE even at the level of the rules.

**A limit of 1–2 active specializations** (grows with population) — otherwise "famous for everything"
= famous for nothing. Standard branches (agrarian, industrial) unlock from population
thresholds, specialization ones — from challenges; the city chooses from the visible ones.

## Trade with settlements

- **Only from the 2nd era (Antiquity).** In the 1st era — only the domestic economy, without
  neighbors. Advancing to Antiquity is itself a reward: the whole unexplored Region
  for free + a new currency (coins).
- Settlements spawn tied to biomes (mountains, coast, forest). Each has its own
  `buys` and `sells`.
- Laying a route = buying a corridor of chunks up to the settlement; after the corridor is closed
  the road is laid automatically.
- Settlements grow and stagnate from trade — this is mid-game.
- Era 1: barter/virtual trade, not implemented as a mechanic. Later eras:
  overseas trade abstractly, without roads across the ocean (there are no units in the game).
- Trade is an important fallback in case "the needed resource did not spawn in the region".

## The "Trade" tab: the domestic market

- **Two columns.** On the left domestic trade (working), on the right external — for now
  only a heading. The columns and cards live in scenes (`CityUI.tscn`,
  `TradeResourceCard.tscn`), not in code: the layout can be moved with the mouse in
  the editor, the script only fills in values.
- **A card = a resource or a group.** The row key is `display_key` (a product id
  or `@group`), not a pid: this way the addressing is the same for single resources and
  groups. Because of this, planned consumption is not reused — it
  expands a group into each member, which is correct for a tooltip, but would give
  six "Fruits" rows instead of one. The tab has its own map
  (`get_population_consumption_map`).
- **Banning consumption is a real mechanic.** The charge and the income to the treasury
  stop, the entry drops out of the plan, the production bonus is removed.
  Without removing the bonus, the ban would be a free way to keep the production
  multiplier forever: there is no expense, but the bonus burns. The production inputs
  of building recipes the ban does not touch — it is about the domestic market.
- **A banned resource stays in the list** (dimmed). Otherwise it could not
  be turned back on: the player would see that the resource disappeared and would not understand
  why.
- **The ban check is before the timer/remainder accumulates.** Otherwise a banned
  entry would accumulate a debt, and on unbanning the city would charge it all at once.
- **The charge priority by quality** is moved out of the code into a player setting
  (previously it was a hardcoded `"best"`). The same cycle best → worst → random as the
  building quality button.
- **Two buttons of one toggle** (a rectangle like the food one and a CheckBox) —
  deliberately: these are two variants of one switch, to choose the look. **Later
  replaced by a single `CheckBox`** (see the next section).

## The "Trade" tab: what was fixed after the first showing

The player looked at the finished cards and found nine rough spots. Four of them
turned out to be not cosmetics but real defects, and three dragged a rework of
the architecture along with them.

- **The cards were recreated EVERY TICK.** `refresh()` glued the composition
  signature together from sorted keys, while `update_values()` compared it
  against the signature in the dictionary's insertion order. The signatures never
  matched → the card list was reassembled in full on every tick. Hence the
  "flickering", the disappearing tooltips, and the extra work of instancing the
  scene. Now the signature is built by a single function `_signature_of` (keys
  are always sorted) and matches by construction.
- **Any assignment to `tooltip_text` kills an open tooltip** — even if the
  string has not changed. Hence the rule `_set_tooltip`: assign only on an actual
  change. On top of that, the cards were switched from tick-based updating to the
  resource display period (1..5 sec from the settings), like the "Resources" tab.
- **Two tooltips on the quality breakdown.** The label had the standard
  `tooltip_text`, and at the same time a custom quality breakdown was shown. The
  standard one was removed — it duplicated and pushed a second window on screen.
- **The consumption fact could not be read once every N seconds.** The counter
  `market_consumption_rates` lives for exactly one tick and is cleared in
  `reset_counters()`, so with a display interval of 2–5 sec it always came up
  empty. A window `market_consumption_accum/_snapshot` was added following the
  model of the cash window; it is rotated in `tick_resource_display`.
- **Expenses and income.** The norm per SINGLE buyer is shown straight from
  `data/consumption.json` (`10 units/1 sec`), not the city-wide total (`210/sec`):
  the player configures consumption per one citizen and should see their own
  numbers. An "Income" row was added — how many coins per second the resource
  brings in.
- **Two copies of the income formula diverged, and the test caught it:** the card
  showed 3570 coins/sec, the treasury tooltip showed 1260, and neither number
  looked broken. The formula was extracted into a single helper
  `_planned_market_income_rows`.
- **Group icons** were taken from the first member with an icon (for "Alcohol" — a
  jug of beer). An optional field `"icon"` was added for a group in
  `data/product_groups.json` + a tooltip on the icon explaining the source.
- **The quality star color** was duplicated in two files. The constant
  `QUALITY_MARKER_COLOR` moved into `ui_helpers.gd` next to
  `PRICE_TEXT_COLOR`: both are presentation elements shared by the tabs.

### Follow-up: tooltips did not show at all, and "Income" lied

**Tooltips.** The player reported: neither the price calculation, nor the
composition of buyers, nor the income breakdown is shown. The cause turned out
not to be in the logic but in the engine: **in Godot 4 a `Label` has
`mouse_filter = IGNORE`**, so the `mouse_entered` signal NEVER arrives at such a
node (verified by a probe on Godot 4.7: `Label.new().mouse_filter == 2`).
The scheme "hover → assemble the text → assign `tooltip_text`" could not have
worked even once. The `RichTextLabel` of the quality label had `STOP`, so its own
tooltip worked — and that is exactly what was confusing: some hints are there,
some are not.

It is fixed in two places: `mouse_filter = 0` on four nodes in the scene + the
text is placed **ahead of time**, in `_update_card`. The second turned out to be
even more useful: the tooltip is assembled from the same data of the same window
as the card's own numbers, and cannot describe a different moment in time.
Hover tracking remained only for the sake of `_hovered_tip` — we do not touch the
node under the cursor, because assigning `tooltip_text` dismisses the already
shown window. A separate subtlety: in Godot 4 a `Control` **has no**
`is_hovered()` method, so hovering has to be caught via
signals (the first attempt with `is_hovered()` failed with "Nonexistent function").

**Income.** Second report: for "Fruits" `Income: 2730/sec`, while the top bar
shows `Treasury: 94364 [+161≈]`. Both numbers were computed by their own rules,
and both looked intact:

- **The plan** (`_planned_market_income_rows`: all demand × price) is not
  limited by storage. 21 citizens × 10 units/sec × 13 coins = 2730, even though
  only 10 units lay in storage. On top of that, for a group all demand is
  attributed to the single member that has anything — and at the price of the best quality.
- **The fact** in the top bar is what was actually sold over the window.

The "Income" row now shows the **fact** (`worker_manager.get_actual_market_income_map`,
a fold of `record_treasury_income` by `display_key` — exactly those records from which
the treasury tooltip and "Treasury: N [+X≈]" live), while the plan moved into the row's tooltip with an
explanation of why the fact is lower. The sum of the "Income" rows now equals the market profit
of the treasury by construction, and the test verifies this.

**A lesson about the test scenario.** The "phantom income" regression failed at
first: the plan came out zero, because by the time of the check the only unit in
storage had already been **sold**, the plan honestly zeroed out, and the condition "the plan is several times
greater than the fact" was not met. The plan must be read **before** the write-off — the order
of operations in the scenario turned out to be part of the scenario itself. A good sign: the test failed
not because of the code but because of a wrongly set-up experiment.

**A lesson about the tool.** Half the time went into editing files rather than
code: `tests/test_trade_tab.gd` is written in CRLF, `scripts/trade_tab.gd` in LF,
and the editor silently refused to find the text that was there. Plus `is_hovered()`.
Both times the culprit was not Godot but the assumption "how is this set up here" without
checking: first two bytes for `\r\n` from `[System.IO.File]::ReadAllBytes`, then
a probe on `mouse_filter` — and both questions were closed at once.

**The general lesson:** a "simple mismatch" (signature versus dictionary order, a copy
of a formula, different update windows) cost more than the new
functionality itself. Such places are worth closing off with a comparison against the source of truth, rather than
with two edits in one's head.

**Incidentally.** `tests/test_consumption.gd` was red BEFORE these edits: it required
exactly one consumption entry for the pseudo-profession "All Citizens", but the registry has
two (`@fruits` and `@alcohol`), and exactly one timer as well. Constants depending on
the number of entries in the data were replaced with a lookup of the needed entry: the balance changes —
the test should not fail.

---

## The forgotten "@": a data error caught by a test

**Symptom.** `tests/test_consumption.gd` is red, the only failure:
"product jewelry from consumption.json not found in products".

**The cause is not localization, though everything pointed to it.** In `data/consumption.json`
there is `"resource": "jewelry"`, but there is no product with such an id: `jewelry` is a
**group** of goods (`data/product_groups.json`), and a group must be written with
`@`. Neighboring entries of the same commit (`@tableware`, `@fruits`, `@boats`)
are written correctly — one character had been missed.

**Why the author went there.** The id `jewelry` belongs **both to a technology**
(`data/technologies/ancient.json`, `name: "Jewelry"`) **and to a goods group**
(`name: "Jewelry"`), and the English labels match word for word, while
`locale/ru.po` gives the same "Jewelry" for both. This is exactly the case
described above, in the section about "name coincidences merge subjects": there the
texts for `smelter` at least differed, here they do not. In the interface a technology and a
group cannot be told apart, and what ended up in the registry was **the name the author saw**, not the id
with `@`.

**A lesson about the silent breakage.** This error broke nothing in the game. The resolver
`_build_consumption_entry` for a key without `@` does not check the existence of the product
and substitutes `products.get(id, {})` — the rule got an identifier-label with an
empty icon. The consumption row hung in the "Resources" tab and **never
wrote off anything**: no error, no treasury, no complaint from the player. Only a test
comparing the data against the source of truth could catch it.

**What was done.**

1. Data: `"jewelry"` → `"@jewelry"`.
2. The resolver `_build_consumption_entry` now prints a warning and
   skips the entry — as is already done for a nonexistent group. The silence
   is over.
3. **A new validator check** `consumption_resource` / `consumption_group`,
   so that the author fixes the data by a hint with the file and line, rather than by the test.
   The check **mirrors the resolver**: a key without `@` is looked up in `products`, not in
   `all_resources` — consumption takes goods from storage, not raw resources from a hex, and
   a comparison against raw resources would produce false positives on every product.
4. The `jewelry` group was extended with copper and glass ornaments — **at the end**:
   the order of members sets the greedy write-off and the source of the group's icon (taken from
   the first member with an icon).

**A subtlety worth seeing only afterwards.** A consumption rule has no
`id` field, so the general origin index skips it — a
separate pass keyed by `resource` was needed. And the declaration line cannot be searched
with the general `_find_decl_line`: it searches for the first occurrence of the value in the raw text and does not
cut out comments, so the pointer pointed at the **author's explanation** next to
the rule rather than at the rule itself (in my own comment — line 84 instead of 86).
The test did not catch this: the comment also contains `"jewelry"`. Hence
`_find_resource_decl_line`, which looks for the line where the `"resource"` field sits next to
the value.

**The general lesson:** "the test is red because of localization" is almost always untrue.
The failure must be read to the end of the message: here it pointed at the data, and
localization was merely the reason the author wrote it that way. And the second
half: a data error that **silently does nothing** (an entry without
consumption) is more dangerous than one that crashes — only the test found it.

---

## Map: generation via JSON presets

**The idea:** a modder configures map generation via JSON, without programming. The code is
a single generator that reads a preset; the preset defines the shape (rectangle, ring, circle,
two_circles, archipelago, coastal_strip, river_valley), biomes and weights, cluster sizes,
guaranteed resources, minimum distances. Strings beginning with `$` are evaluated
as a Godot expression through the built-in sandbox class `Expression` — safely and without a parser
of our own.

- **What a modder CAN do:** shape, biomes, weights, cluster sizes, resources, distances,
  computed values.
- **What a modder CANNOT do:** write algorithms, reach into files and the network, break mechanics.

**A technique against "lone mountains":** clusters `mountain: [2, 3]` plus the requirement
`min_same_biome_neighbors` for special biomes. A lone mountain physically cannot
occur — not "unlikely" but impossible. The generation defect is set by parameters, not
by fixing the code.

**Recommendation:** move era parameters and other tunable quantities into JSON,
so that tuning is not a code edit.

## The "Expansion" mode — an overlay, not a permission gate

**The problem.** The gating (the mode disabled ordinary interactions) regularly put
even the author into the trap of "why is nothing clickable", and the mode's indication weakened with a
fully purchased Region: no highlights → the mode is indistinguishable from the ordinary map.

**The solution.**
1. **The gating is removed.** Construction in the Ring and scouting/purchase in the Region coexist
   on the ordinary map through the context menu (own hex → build an improvement;
   unscouted chunk → scout; scouted → buy). Protection from misclicks is
   the menu itself with the price, a separate safety mode is not needed.
2. **"Expansion" = a pure overlay-planner**, not a permissions toggle:
   chunk highlights (unscouted / scouted unclaimed / claimed),
   a hover preview of the action's target, and in the future — corridors to settlements, canals, roads.
3. The "Expansion" button has a pressed state (toggle hygiene).
4. The mode blocks nothing, so the question "how do I know I'm in the mode" is not pressing:
   the overlay is visible as long as it is useful.

**Rejected:** permanent outlines of chunk borders — the highlight zones are the chunks,
the outlines are redundant.

## Scouting, fog and the territory border

**Scouting outside the Region — only after the "Cartography" technology.** Before it, one cannot go
beyond the Region: neither a chunk highlight, nor a click, nor a scouts button. The
technology's `unlock_effects` field is **functional** here, not display-only: "Cartography"
promises scouting in the fog, and the code is obliged to read this. The gate is placed at several points
(hex hit-test, chunk assembly, highlight rendering, scouting start) — because each
of them was a separate leak path.

**Scouting — only into chunks adjacent to known territory.** Otherwise scouts
leap across the fog and expose "pockets" far from the border of the known world.
- "Known territory" = the Ring of Influence (`in_influence`) **OR** a scouted hex.
  One cannot take only `is_explored`: the whole world, including the Ring, starts with
  `is_explored = false` — there would be a soft-lock at the start of a new game and in old saves.
  The influence rings of foreign towns are not part of "known territory".
- It is the **chunk** that is checked, not the clicked hex: a chunk of 5 hexes that reached
  the border of the known world is allowed, even if the click was on a hex one step deeper.
- The meaning of the rule matters not on its own: "scouting within the scroll" no longer means
  "anywhere" — distant chunks are unreachable until the path to them is scouted.

**Claiming is still limited to the Region** — even with "Cartography". Purchase outside the
Region is impossible; the button shows the reason instead of silently disappearing.

**The fog border is a matter of principle.** The fog is what lies **beyond**
the Ring and the Regions. Unscouted hexes of the Region are NOT considered fog: they are visible on
the map (darkened) and their tooltip honestly says "Terrain: … / Resource: unknown
(send scouts)". Beyond the Ring+Region nothing is drawn except a dark
canvas — and therefore there should be no information either. If we decide to hide the terrain also in an
unscouted Region, a single check in the fog predicate changes, not a dozen places.

A foggy hex does not become "hovered" (there is no tooltip at all), the panel column
shows the stub "information unavailable", but the actions (scouting) remain. A click on
blocked fog does not "stay silent" but explains that "Cartography" is needed.

**A highlight is never "silent".** The set of highlights always coincides with what the
panel's actions apply to. If a hex has no action chunk (a scouted hex outside the
Region, a hex in the ring of a foreign town), the hex itself is highlighted. Click and hover
work the same way.

**The priority of refusal matters more than the refusal itself.** Scouting that has run into an unscouted
corridor should call for scouts, not report "not allowed". Otherwise the player closes a
nonexistent problem and does not understand that the solution is in their hands.

## Town placement: a strict cascade of priorities

Town priorities are processed **strictly cascade-wise**: to move on to the next
priority, the generator must go over the WHOLE map and make sure that no suitable
hexes remain for the current one. It is unacceptable for a town to settle on a lake shore
(3rd priority) when the map is full of places with a cluster of resources (1st priority).

Plus a **cascade refinement**: having found a place for a higher priority, we try to improve
it by "topping up" the lower ones (2+ resources → also strategic → also a river → also a
lake/sea). If a priority could not be reached — **we skip it** and go to the
next: the cascade is not interrupted by this.

- Resources already occupied by standing towns are not counted as a resource priority: one
  cluster should not pull two towns.
- The search for a place is a full traversal of the map, not N random anchor points: the single
  valid hex among thousands of candidates must be found, otherwise the priority is falsely
  declared exhausted.
- The priority is counted from the **town's** hex, not from an intermediate anchor: otherwise
  "2+ resources nearby" turns into a requirement that says nothing.

## Roads

- **A road is a special action `"road"`, not an improvement.** It is the only one that does not change
  the contents of a hex but builds a segment of the city's network. Hence a separate branch in three places
  where action types are handled: applicability, price calculation, execution.
- **The price is per hex, linear along the length of the route, and WITHOUT a distance multiplier.** The
  distance is already reflected by the length of the route; with a multiplier, a road to a distant town would get
  more expensive twice. The benchmark is 3 labor per hex: a hex of road is simple work (a farm is 8, clearing
  forest is 22), but the linear growth makes a 10-hex road (30 labor) equal to one and a
  half farms. A distant town should be a tangible but reachable investment.
- **The price is calculated in one place** — the preview and the actual construction take the same
  value. `work_cost = 0` for a road means **not** "instant construction" but
  "there is no route": without a separate check the construction would finish instantly, the player would get
  zero roads and would not understand why.
- **Planning is separated from construction.** The route calculation writes nothing into the network;
  both the preview and the price are fed by it. The plan is cached by the version of the network **and the
  version of map knowledge**: the route also depends on what the player has already scouted, otherwise the
  panel would show "no road" even after the passage is open.
- **The route that the player builds goes only over scouted land.** Otherwise the player
  "builds" a road that later cannot be seen or explained: it would have exposed
  unscouted territories. Automatic road networks (to the improvements of the city and
  towns) do not get this filter — they have no rules of their own.
- **The reason for refusal is phrased for the player.** "A route exists but it is not scouted — send
  scouts" and "there is no land route at all, the town is across water" are different situations
  with different solutions. The first phrasing wrongly turns the player away from a task that
  they can solve.
- **Each town has its own network.** Pathfinding stops at a hex of its OWN network,
  so the roads of towns cannot become part of the roads of the player's city. The key of a
  network is the coordinates of the town's **center**, not an index in a list: the index would "drift" if the towns
  were rearranged.
- **The connection is stored in two layers, and this is not duplication.** The computed flag "currently
  connected" draws an icon and does not require storage. The saved fact "the player built this"
  is needed to reassemble the connection after loading (road segments are not written to the save) and
  to answer the question about trade. These are different questions: "are we connected now"
  and "did the player build this".
- **The road to a town goes not to the town's hex but to the nearest road in its influence ring**
  — that is how it was stated in the task. The segments of the new road go into the **city's**
  network: two networks become one road. The ring and the town itself do not participate in the network.
- **Trade with a town is gated by a road, but access to the interface is not.** A scouted
  town can always be opened: there you can see what it has to buy and sell.
  The road requirement lives in a single stub function next to a constant that real trade will one day
  remove.
- **The road network is not written to the save.** The input data (towns and improvements) is already
  in the save, the network is recomputed at the start of a game and on load.

## Debug tools

**Principles of the debug menu.** A thin UI on top of existing APIs (not one's own workaround
assignments), a separate scene on a hotkey, in release builds — a gate via
`OS.has_feature("debug")`, all changes go through ordinary signals so that the UI does not get
out of sync. The fact "I cheated" is not written to the save.

**The "Ignore building requirements" toggle removes the requirements but not
the geometry.** The requirements are technologies (clear forest, drainage), "Cartography",
the adjacency of a chunk to known territory, money, labor. The geometry of an action (where a
route can even be laid, which chunk to scout) remains: to "instantly build"
a road that cannot be reached means to build it haphazardly. They must not be mixed into one
toggle — you would get two toggles with overlapping scopes and
no way to tell which of them disabled what.

## Visual conventions

**Hex highlighting distinguishes the action type and availability by palette, not by text.**
The hue encodes the action (scouting / claiming — two mutually distinct hues),
the muting of the hue — that the action is unavailable, the thickness of the frame — hover or click.
Chunks adjacent to known territory keep their former colors, so as not to change
the familiar picture.

**The palette lives in exactly one place** (in the function that chooses the highlight style).
The concrete colors are not duplicated anywhere: neither in code comments, nor in `docs.md`, nor in
this diary. Otherwise any edit of the palette leaves outdated references in ten places.
Behavior is described by semantics, not by literals. Testing the palette with a test that
hardcodes the concrete colors is also not allowed — it would break on any edit and provides no
useful checks; readability is checked visually in the game.

The hue of unavailable claiming is deliberately chosen to be far from the grey-brown
gamut of the terrain: the muted "as before" hue blended with the mountains and hills, and the player did not
see that the action exists but is unavailable.

## Interface conventions

- **Separation of ticks from events.** Resources and numbers update on an interval (configurable
  1–5 sec, step 1 — the data changes only on one-second ticks, a fractional step would give only an
  uneven rhythm). Event-driven things update **instantly**: costs from JSON,
  hints about labor and limits, population, treasury, science, structural changes of panels.
  The interval is game time, not system time — it does not run while paused.
- **A tooltip must not contain values that change every tick** (for example, the current
  treasury). The action panel does not recreate the buttons while the list has not changed — this is exactly what
  preserves the hovered tooltip; a value that changes every tick breaks this property.
- **A hovering tooltip must "stick":** while the cursor is held, the panel is pinned,
  and the cursor can be moved onto the panel itself. Live updating of the content must not
  reposition the panel, otherwise the tooltip "runs away" from the cursor and cannot be caught.
- **Numbers in the interface are rounded explicitly and identically** everywhere: an integer without a fractional part,
  otherwise one tenth of a coin/sec rounds to zero. The tooltip and the treasury are obliged to compute
  the same price — otherwise they would show different numbers for the same
  goods.
- **A panel that does not fit in its container is a bug, not a trifle.** A hover
  tied to the node's rectangle will not see the "tail" of the text beyond the old panel.

## Rules for working with AI assistants (process empirics)

1. **Procedural math and generation (rivers, roads, geometric algorithms) — clean sheet only:**
   erase the old code, give a full specification, get a new implementation. Do not try to fix
   someone else's algorithm piecemeal — it will retain a contradictory mental model, and the
   patching workaround will repeat again and again.
2. **Everything else (data-driven mechanics, UI, JSON content) — incremental edits
   work fine.**
3. **The specification is written literalist-proof:** invariants ("every segment of the polyline = one
   hex edge"), prohibitions ("the path does not go through hex centers"), acceptance criteria
   ("a segment longer than an edge = a bug"). A literalist genie executes the words, not the intent.
4. **Implementation is expendable, the specification is an asset.** `design_doc.md` stores the accumulated
   constraints; subsequent sessions are fed by them.

## Test discipline

- **A runtime error inside a coroutine cuts it off silently** — control never reaches
  `quit()`, and the process lives forever. This is a trap for all headless tests,
  not for a particular file. Hence a shared watchdog for the whole run, rather than copy-paste per
  file.
- **The watchdog is a shared helper, not copy-paste.** One entry point, a marker with the test's name from
  `resource_path`, a nonzero exit code on timeout. A normal completion cancels the
  watchdog with a flag: a forgotten `quit()` is caught too, since such a test is "hung" by itself.
  The time limit has a margin for a slow machine, but not for "wait forever"; a custom limit
  can be passed explicitly.
- **The shared helper file must not be named `test_*.gd`**: otherwise the "all tests from the
  folder" run will try to launch it as a main-loop script and fail with an incomprehensible
  error.
- **A regression that fails on its own (data drift) is not a consequence of the edit.**
  Before blaming the current work, roll it back and check on a clean HEAD. Otherwise
  a false trail remains in the diary and in one's head.
- **Verification by mutation instead of taking one's word for it.** A "green" test that has
  never once run looks the same as a working one. Temporarily replacing a function with a stub
  must fail exactly the checks it protects.
- **On a live random map, check not "everyone has it" but the rule as a whole.** Improvements
  stand both on water hexes of the ring and on ones cut off by water — the statement "everyone has
  a road" would simply be false. The real invariant: a road exists if and only
  if there is a land route to the town.
- **Do not tailor the random map to the check.** If an honest scenario cannot
  unfold (a town on an island), honestly skip it and write about it, instead of
  tailoring the input data.
- **Catch engine errors (`SCRIPT ERROR`, `Parse Error`) in tests just as strictly as
  assertion failures.** Function checks pass while integration tests print an
  error to stderr, which a run filtered by `FAIL` does not show.
- **When running via `--script`, one must not reference classes by `class_name`:**
  when the test script is loaded, the global names may not yet be in the cache, and the
  compilation of a dependent file fails, and then the error looks like a completely different
  module is "to blame". Get by with `load()` and calling static methods through a variable.
- **Indentation - spaces only.** 

## Rivers

**A river is a boundary entity, not a tile type in the center of a hex.** Reasons:
- it does not eat up tiles on small maps (11×9);
- a variable number of watered neighbors (2–4) rather than a fixed 6;
- the fresh-water bonus via adjacency comes out naturally;
- the hex is already overloaded (resource, improvement, road, landscape).

Historical context: in Civ 1 (1991) rivers were tiles, in Civ 2–6 they were boundaries, in
Civ 7 tiles again (units sail along them). The City has no units, hence boundaries.

**Three-level water system:**

| Level | What | For whom | Scale |
|---|---|---|---|
| River | natural source | farms, mills | hexes around |
| Canal | artificial continuation | farms, mills | +3 hexes from the source |
| Aqueduct | grand project, drinking water | city, population | deferred |

**Irrigation.** A binary +50% production bonus for a farm when water is present. The bonus
**does not stack** (river + canal do not give +100%). Irrigation works **as long as the chain is intact**:
it breaks — the bonus is lost. Farms carry water themselves and are part of the chain.
A canal is a separate light improvement (6–8 work, cheaper than a farm). Water range:
a maximum of 3 hexes from the source (river or canal).

**Mill on the map:** requires water (a river OR a canal), does not process grain itself,
gives a passive +5% to the speed of all mills in the city.

**Generation algorithm.** A river enters at a random point on a random border of the Region;
the first 2 steps are a random direction, but not outward (into the map); thereafter each step is
a random allowed direction: straight (0°) or a soft turn (±60°), a reversal
(180°) is forbidden, a medium turn (120°) occasionally. A river cannot exit until it has passed
a minimum of 4 hexes. The exit is through any border of the Region. The parameters are in JSON
(`count`, `min_length`, `guaranteed`).

**Data model.** Each hex stores which of its 6 edges are river. A hex is irrigated if
at least one of its edges is river or it is adjacent to a canal.

**Visualization v1** — a three-layer line plus wave markers, without AI images:
a dark-blue wide line (the river body), a light-blue thin one (a highlight on the water), wave
symbols every 2–3 hexes. The bonus is a light tint on the banks.
Acceptance criterion: an alpha tester immediately says "this is a river", not "this is a border or a road".

## Rivers: final architecture (implemented)

Supplements the previous section: the v1 algorithm from the spec is implemented through a separate manager.

- **RiverManager — the sole owner of rivers:** generation, serialization, `river_edges`.
  The map generator does not generate rivers, the renderer only draws.
- **The data is a vertex graph** (nodes = hex vertices, graph edges = hex edges) plus
  A* with a turn-angle constraint. The path goes strictly through adjacent vertices, so cutting across
  is impossible by construction: the graph simply has no "through-hex" edges.
- 1–2 rivers per map, guaranteed from border to border, minimum length 8 vertices.
  Rivers may merge, but not intersect and not run along themselves.
- `mark_river_edges` derives the tiles' `river_edges` from the polyline; irrigation and bank
  tinting read the same thing — a single source of truth.
- Saving: an array of arrays of points, several rivers survive saving without being glued together.
- **Visuals are separated from data:** meandering within an edge and smoothing live only
  in the renderer.

### Process lesson

A patch session with five assistants could not remove the cut-offs: the assistants patched the boundary traversal,
keeping a contradictory mental model. A session from a clean slate changed the data
representation (a vertex graph) — and the invariant became **structural** rather than checkable.
See "Rules for working with AI assistants" above.

---

## Staged construction moved into the shared project system (2026-09-29)

**Context.** A road was built as a single task: the player confirmed the route, paid for
the whole length, and a few seconds later received it in full. It cost a long span —
and the player looked at empty ground, not understanding what their purchase consisted of
and how much longer to wait. The second case along the road: an aqueduct from a mountain to the city was
already under discussion, and it requires exactly the same thing — "a queue of sections with shared
payment" — but the whole machinery of the road cannot be repeated a second time.

**Solution.** The queue of steps was moved into a separate `project_manager.gd`, which
no road entity knows about. A project is ordered steps, each
step is built separately; what a step means is decided by the owner through
`step_completed`. The road became the first user, the aqueduct will be the second, and
neither of them will require changes in the manager.

**Why `build_manager` hands out the labor rate, and not the project manager.** The invariant
"the total amount of work per unit of time equals the size of the city" lives in
exactly one place — in `_process` of `build_manager`. If a project invented its own
rate, the city would receive work "on top of" the shared amount and would build faster than itself.
Therefore the project manager declares how many steps are running (one slot per
project, not per number of hexes), and receives a ready, divided rate. The exchange
is deliberately narrow: two methods, not a single piece of knowledge about roads.

**Why sections go from the network to the target, although the plan returns the path the other way.**
`plan_road_to` returns the path from the target to the city — that is how the search builds it. Reversing
it was necessary in substance, not for symmetry: each step has two hexes, and if
you build from the target, the section hangs in the air the whole time until the queue reaches
the city. From the network — it joins an already-finished road each time. The side
effects are the same, and they are pleasant: the progress bar moves from the city to the target, and the route's
ghost is "eaten away" from the city, that is, what is not yet built is always visible behind, not
ahead.

**What disappeared, and why it is not a loss.** The former partial payment (you paid for part
of the span — construction stayed active with a remainder, the player paid and paid)
disappeared along with one big task. With staging it is not only
unnecessary, but contradictory: an underpaid section simply does not begin. Payment
became more honest and clearer — a separate step for each section, and the last step
picks up the rounding remainder so that the sum of the steps matches the price in the preview to
the unit of work.

**The interrupt button must be where the player taps.** A separate story,
out of which a general rule grew. The road cancel button lived on the **target** hex
(`get_project_at()` — a search by target coordinates). But the player does not select the target
hex: they see a progress bar on the current section and a yellow ghost along the whole
rest of the route, and presses where they are looking. The button hid at the far
end of the span, and most often it was not visible at all — and there was nothing to interrupt a
half-built road with. Hence the split into two questions: "is there a project
**at this** hex" (hides the "Build Road" button) and "does the project occupy
**this** hex" (gives the interrupt button).

Then it turned out that early `return`s in `_collect_actions()` muted the button
where a road could be built: on a hex with an improvement and in a town's influence
ring. The second case is especially unpleasant — a road to a town ends
with a section **inside** its influence ring, that is, on the last step the button
disappeared by itself. Plus the `elif` for ordinary construction: on a road hex that
a project is heading toward, one can build something else, and one button silently
swallowed the other.

I gathered everything into `_append_cancel_actions()`, which is called from all branches, and
along the way renamed the buttons: `Stop: Drain Water` is more honest than
`Cancel construction` — from the button you can see exactly what is being interrupted. Pressing in
the middle of the route cancels the **whole** project, and this is stated directly in the dialog:
otherwise the player presses "cancel just this little piece" and gets the whole road cancelled.

**Claiming and scouting.** They had no cancellation at all — and their actions take
the longest. Here a question surfaced that did not arise with the road: the money for them
is deducted **immediately**, on dispatch, not on completion. I hesitated for a long time:
to refund or not. I decided to **refund** — the money was paid for a result (a chunk in
the Influence Ring, the scouted hexes), and there will be no result. The price of refusal is
the work invested and the time, and that is already tangible. All the more so since
`expansion_manager.handle_action()` already did exactly the same thing when a claiming construction could
not start: the money went back so that the price would not be lost. The rule came out
single and easy to explain to the player: **cancellation refunds the money, but not the work**.

What remained was to figure out how to cancel scouting if there is only one expedition in the game. The button
appears on the hex of its chunk, and the cancellation resets the timer and refunds the price.
No hexes are revealed in the process: scouting is applied in full in
`_complete_scouting()`, it has no intermediate state, and there is no reason to invent
one for the sake of cancellation.
**Cancellation does not roll back the road.** Already-laid sections remain, only
the ghost of the unfinished one disappears. This matches the cancellation of ordinary
improvement construction and what the player has already seen on the map: what needs to be cancelled is the "tail"
of the project, not to rewind the result.

**Saving.** Road segments, like all roads, are not written to the save. Therefore
the `road_built` flag is set on **every** hex joined by a section, not
only on the project target: otherwise a half-built road after a restart
would lose the entire built tail and start again from the city. The queue
itself lies in the save separately (`active_projects`) and continues to be built.

**An invariant that must not be violated:** the project ghost and the route preview are
different sets of segments with different lifetimes. The preview lives as long as
the panel is open; the ghost lives until the end of construction. They must not be merged "for the sake of less code"
— then after confirmation the route would disappear from the map, and this would
look like a bug, even though the code would be correct.

---

## Terrain and distance multipliers applied to road sections (2026-09-29)

**Context.** The distance multiplier was not applied to the road, with an explicit justification
in the data: "the distance is already reflected by the length of the span, otherwise it would get more expensive twice."
While the road was a single purchase, this was true — the player paid `3 × length` and
did not see what was inside. Staged construction cancelled this reasoning: a section
became a separate construction on a separate hex, and a section ten hexes from
the city began to cost exactly as much as a neighboring one. The same work, the same
load, ten times farther. The discrepancy stopped being hidden.

**Solution.** The price of a section is `base × work_cost_mult(terrain) ×
(1 + distance × coefficient) × tech multipliers`. The terrain multiplier is the same
`work_cost_mult` as for improvements: "construction difficulty" does not depend on
what is being built, and a copy of the table in the road's code would diverge from
the data within a month.

**Why its own distance coefficient, and not the shared 0.25.** The shared multiplier
is applied to a single construction, where the player chooses the hex themselves. Here the formula
is applied to each section, that is, it is multiplied by the length of the span: at 0.25
section No. 20 costs six times more than the first, and the network hits a wall —
you would never reach a distant town. A separate field in `game_balance.json`,
value 0.1, gives a readable series 1.1, 1.2, …, 2.0. This is a deliberate
exception to the rule "one value for everything", and it deserves a note in
the data rather than silence: otherwise the next session will see two different fields with
the same name and decide that one of them is a typo.

**Why terrain is taken by the `to` hex, and not as `max(from, to)`.** In the queue
each interior hex of the span occurs twice: as the `to` of one step and as
the `from` of the next. With `max`, a marsh in the middle of the span would be paid for twice —
for the same hex. With `to`, each hex is charged exactly once, and
this is correct in substance: `from` is already in the network, it was paid for when the road reached it.

**There is no and will be no surcharge for span length.** Here it is worth fixing
the very wording, because it is easy to confuse with the first two multipliers.
"Complicated and long roads take a long time to build" — these are two independent reasons:
a long road takes longer to build because there are more sections, not because
a penalty is charged for "length". Presenting the final cost as "span ×2.8"
is misleading and looks like a punishment for length that does not exist in the code.
One must count by sections.

**A defect that was not visible in isolation has been incidentally closed.** The preview price
was calculated as `base × plan.segments`, and `plan.segments` is `path.size() − 1`,
that is, all segments of the path, **including the already-built ones**, whereas the steps
filtered them out. On a route running along a partially built road, the preview
showed more than was deducted. Now the steps with their prices are the single source
(`main_map._build_road_steps`), and both the preview and the launch take the same array:
the discrepancy is excluded by construction, not by a check. The scheme "the last step
picks up the rounding remainder" also disappeared — with different step prices it
would give overpayment or shortfall, and the sum is now exact by construction.

**An invariant that must not be violated:** the distance multiplier of improvements and
of road sections are different fields with a shared formula, and "universality" here
means a formula, not a number. The tech multiplier for the distance contribution ("Wheel")
is obliged to be **one** function for both cases: it reduces distance, and if
it were only on improvements, the wheel would cheapen construction but not the road —
even though the road is precisely about the wheel.
---

## Icons live in a single registry (2026-10-01)

**Context.** An icon file name in `data/*.json` is just a name (`wheat.png`),
not a path. Therefore every consumer that needs the picture had to
turn the name into a path — and **eight modules** did this by recursively
walking `res://icons`: `map_renderer`, `resources_tab`, `buildings_tab` (twice in
one file), `building_panel`, `tech_tree`, `town_ui`, `trade_tab`. The walk
went over 576 files, and three of them simultaneously kept local texture
dictionaries on top of `load()`, which Godot already caches anyway.

**Why this cannot be fixed "by cleaning up each module".** The indexing
rules of the eight copies diverged: in half of them a duplicate name overwrote the path, in
the rest it was ignored, and three printed a warning. There are currently no duplicate names in
`icons/`, so the divergence is harmless for now — it is waiting for the
moment when the author puts `wheat.png` into a subfolder as well. This is a
delayed-fuse trap: it looks like it works, but it will break on a new icon and in
the most incomprehensible place. Half of the index (288 of 576 entries) is
`*.import` files, which are not icons at all.

A separate find of the same refactoring: `buildings_tab._build_icon_index_local`
was called **inside `_show_building_details`**, that is, the 576-file walk
happened on every hover over a building.

**Solution.** `scripts/icon_registry.gd` — an autoload `IconRegistry` that
builds the index once per game (lazily, on first access) and provides
`has()` / `icon_path()` / `get_texture()`. Invariant: need a path or a texture —
ask the registry; we do not write our own walk of `res://icons` in new code. The test
`tests/test_icon_registry.gd` verifies the index against the file system itself, not against
constants — otherwise it would become stale with the very first reshuffling of pictures.

**What we deliberately do not do.**

- *A manifest generated at import time (EditorPlugin).* It would track new icons
  automatically, but it is a whole subsystem tool for the sake of six hundred files.
  The registry builds in a couple of milliseconds, once.
- *`class_name IconRegistry` with static fields instead of an autoload.*
  It saves a line in `project.godot`, but the project already has a direct prohibition against
  relying on `class_name` in headless mode (`ui_helpers.gd`: when launched via
  `--script`, global class names may not yet be in the cache). The autoload
  works the same everywhere.
- *Requiring an icon to exist for every reference in the data.* In `data/*.json` there are
  ~144 references to icons that have not been drawn yet (future goods, professions) — this
  is a normal way to write data ahead of time. The test prints their count as
  a reference, but does not fail.
- *Converting the hardcoded paths* (`city_ui._setup_tab_bar_icons`,
  `main_menu`) to the registry all at once. Four static icons are not a duplication of the index;
  moving them out would add a dependency without a gain.

**A trap we have already stepped on twice.** `get_path()` as a method name
is impossible: `Node.get_path()` returns a `NodePath` and overrides it, and
the engine treats the override as a compilation error (warning-as-error). The method
is named `icon_path()`. Second: in `map_renderer` the local `icon_textures`
is left **deliberately** — this is the hot path of `_draw`, an access on every hex
every frame, and reaching into an autoload from `draw` is premature. The registry only
fills it.

---

## Road levels, route and "maximum speed" (2026-10-01)

**Context.** A road was a single entity without qualities: `road_manager` stored
a set of segments (`key -> true`), all of them had one color and one width, and the price
of a section lived in `special_actions.json` as `work_cost: 10`. The request: the road
gained levels with a "maximum speed" — not the speed of units, but
throughput (how many units of resource per second a section carries),
a route from an improvement to the city with an average speed, an "Upgrade
road" button with a ghost and a level choice.

**Solution.** A level is an entry in the new `data/roads.json` (`level`, `name`,
`work_cost`, `max_speed`, `unlock_tech`, `color`, `width`), and a network section
stores **the level number as its value**: `road_segments: "row,col|row,col" -> level`.
The first level is a free trail (10 units/sec), "Wheel" unlocks the second —
a cart road (30 units/sec). The task constraint: only the ancient era and two
levels, to test the end-to-end path; the remaining levels are added with data.

**Why a level is a dictionary value, and not a separate list.** The segment dictionary
already enumerates all sections. A second list of "which section is of which level"
would diverge from it with the very first change to the network, and the desynchronization would look
not like a data error, but like a "ghost" road of the wrong level. A dictionary
value is perfectly suited for this: `.has()`, `.size()`, iteration over keys
work as before, and the level travels together with the section.

**Why `work_cost` moved out of the special action.** A level is a property of a section, and
the price of a section is a property of the level. A copy of one number in two files would diverge
at the first balance edit, and quietly at that: "Build Road" would show the price
of a trail while a cart road was selected, and only the player would see the error.

**Three consequences that had to be fixed rather than worked around.**

- `maxi(1, cost)` in `get_road_step_work_cost` turned a free level into
  a paid one. The lower bound was set not from logic, but because the base was always
  positive (10 from the special action). With a zero base it became incorrect, and
  free improvement construction stopped being free.
- The check "a road cannot be built" was on `work_cost <= 0` — that is, on
  the price, which was used as a sign of "there is no span". With a free trail,
  a zero price became a legitimate state, and the road would be declared
  impossible. The sign was moved to `!ok` on the plan, where it should be.
- A staged project step with a zero price does not accumulate work and does not complete by itself:
  it would hold the construction slot forever. A free road is now traversed in full
  at once, by the same step handler.

**Why the route is a separate search, and not a plan.** `plan_road_to` searches for where
a road can still be laid: Dijkstra over the terrain, with a scouting filter.
`find_route_to_city` searches for how to actually get there: a breadth-first traversal of the built network,
without the knowledge filter. They must not be mixed — these are different questions, and code
that "just reuses the planner" would, within a month, produce a route over
the terrain for a road that does not exist.

**Why both the average speed and the minimum are shown.** The request was about the average.
The average alone is not enough: on a route of three trails and one cart road, the average
equals 15, and the cargo still hits the 10. "Average 15" sounds like "all
is well" and leads to upgrading the wrong section. The minimum is precisely the
bottleneck, for the sake of eliminating which the route is upgraded. The average remains because
it answers a different question — "how fast on average does the cargo travel".

**The whole route is upgraded, not the section next to the improvement.** The
speed of a route is determined by the narrowest link of the chain, so upgrading one
end gives nothing. That is why the button is not "upgrade here" but "upgrade
the road from here to the city", and its tooltip directly names the current bottleneck.

**A GDScript trap that cost time.** `str(value or "")` with `value ==
null` yields the string `"<null>"`, not an empty one. A naive `is_empty()`
check passed, and `"<null>"` got into the list of researched technologies — the
unlock cycle silently broke, and "Wheel" never unlocked. In `roads.json`,
the `unlock_tech` field of the trail is exactly `null`, so the case is not hypothetical.
The reading was moved into `GameData._road_unlock_tech` with a type check.

**An invariant that must not be violated:** `segments[i]` of the route connects
`path[i]` and `path[i + 1]`. Both the route highlighting and the upgrade queue
depend on it (the steps go in reverse order — from the city to the target). "Almost the other way
around" is unacceptable here, and the check of the order of levels in `test_road_levels.gd` is not
a decoration, but the guard of this invariant.

**What is deliberately absent.** The flow of resources is not limited: `avg_speed` is calculated and
shown, but production still goes straight to storage. Limiting
consumption by throughput is a separate mechanic with its own queue and
rules; doing it along with levels would mean changing the economy blindly, without
a verifiable foundation.

**Later: the road level on a hex (2026-10-01).** Added based on the results of the first
pass: the player did not see what level the road arriving at their hex was. The line
is output in the extended tooltip and in the left column of the control panel.

Three things here are non-obvious.

**The level of a hex ≠ the level from the hex's data.** A hex has several adjoining
sections, and at a junction the levels are different: the player upgrades the route to their improvement,
while the branch to a neighboring hex remains a trail. `tile["road_level"]` describes
only the section by which the hex was **connected** to the network, and at a junction it would show
exactly half of what is actually around the hex. Therefore the levels are collected
from the network — `road_manager.get_hex_road_levels`, and the hex's data is not read.

And one cannot choose "the one correct" level: at a junction there are two of them, and both are correct.
Therefore all of them are listed, not "the main one".

**The ordinary tooltip does not show the level.** The first version added the line to
`_build_text`, and it automatically made it into both the ordinary tooltip and the left column
of the panel — both points are built from this text. The result was wrong: the ordinary tooltip
answers the question "what is on this hex" (terrain, resource, improvement), whereas
the road level is its connection to the city. Two different questions should not be mixed in
one block, so the line moved to two dedicated places.

**A trap that cost time.** `update_extended_tooltip` called
`render_products` twice: first for the new line, then for the extended
production. `render_products` clears the container, and the second call wiped out
the first. On a hex without an improvement the second call did not happen, everything worked — but on
a hex with a road AND a natural resource the line disappeared silently. Now the lines
accumulate in an array and are rendered with a single call at the end. The trap is dangerous precisely
because it looks like "sometimes it works": on the test map, without resources on
the hexes under the road, the bug did not reproduce.

Another small thing of the same kind: `has_extended_tooltip_info` answers only
"whether to show", and one must not add rendering to it — otherwise the check that
the hover handler calls would get a side effect and would start drawing
the tooltip twice.

---

## Road level on a hex = the maximum (2026-10-01)

**Context.** The first version showed on a hex a list of the levels of the adjoining
segments: at an intersection of two trails and one cart road it produced
“Trail (level 1), Cart Road (level 2)”. Formally correct, but
it contradicts what the player sees on the map: the hex is drawn as a single road.
The author of the task proposed a rule: **the road level on a hex = the maximum over
the adjoining segments** — at such an intersection the hex is a cart road.

**Why the maximum and not the minimum.** The maximum matches the picture: segments
are drawn according to their own level, and the best of them determines how the hex looks.
The minimum would give a “trail hex” with a cart road in the middle — the same
contradiction, only reversed.

**My objection about the cascade was wrong.** I assumed that the rule
meant “all segments of the hex have a single level”, and from that I deduced that upgrading
one segment would spread across the whole network. But storing the hex's level and requiring
it of all segments is a **different, stronger** requirement, which
the author did not put forward. When the level is stored only on segments (as is done), the
maximum rule requires nothing: a trail through an intersection stays a trail, and
the best road reaching the hex is what gets displayed.

This is worth writing down, because the mistake was not in the code but in the substitution: I
attributed to the author a requirement he had not made, and built on it an entire
argument. I should have first reread his words literally — “the maximum level
of the roads COMING from the adjoining hexes” — and it immediately became clear that this was about
reading, not about storing.

**Three concepts that are now distinguished explicitly.** The segment level (the fact
of construction, the source of truth), the hex level (a derived value for display) and
`tile["road_level"]` (the save's input data: the level of the segment by which the hex
was connected). The first version labelled the latter as “the road level on the hex”,
and that invited confusion. Now the discrepancy is visible in the code itself.

**A bug found along the way: the “Upgrade road” button.** The condition for its appearance
checked the MAXIMUM of the route's levels against the best available level. One had only
to upgrade one segment out of four — the maximum became equal to the best level, and
the button disappeared, even though three trails remained. To the player this looked like
“the route is already upgraded”, and there was no way to bring the road up to par: a class of error where “an incomplete
state looks like a finished one”. The correct thing to check is the MINIMUM — the button is not
needed only when the route is entirely at the best level.

The fix was found not by reading the code but by posing the question “what should happen
on a partially upgraded route”. Formally the code was consistent: it compared
the maximum with the maximum. The contradiction was between the code and the player's expectation.

---

## The road upgrade preview dragged along the production block (2026-10-01)

**Context.** On a hex with a built improvement the player clicks the “Upgrade
road” button and sees “Will produce: …” in the preview — as if he were about
to build this improvement. On top of that, the block pushed the road-level selection downwards, and one had
to scroll down to it.

**Cause.** The production block in `_build_preview` was opened by the condition
`type != "special"`. That cut off only special actions. The road upgrade has
its own type `upgrade_road` — that is, also “not special”, and so the condition passed.
In addition, `_on_action_pressed` substituted `eff_res` into the preview — the effective resource
of the hex, that is, on a hex with an improvement it was the resource of the improvement itself, which is where
the output came from.

**Solution.** The condition was replaced with a whitelist: production is shown only
for `build_improvement` and `build_breeding` — that is, exactly where the player
is really building something. For `upgrade_road`, `eff_res` is no longer computed:
the hex's resource has nothing to do with a road upgrade.

**Why a whitelist and not “everything except”.** “Everything except X” is a condition
that silently extends the block to every new action type: the author added
an action type, did not notice the condition, and got a spurious block in someone else's preview. A
whitelist fails explicitly: a new type will not get into the production block until it is
explicitly added there. “Default” errors in the UI cost more than an extra line of
code.

**A side effect that matters more than the bug itself.** The production block was not
merely superfluous — it was about an action the player was not performing. The improvement
already stands, and its output is visible in the left column of the panel and in the hex tooltip. Repeating
this in the preview of another action teaches the player that the preview shows the “future”
wherever it is drawn — and he stops trusting what he sees. A rule
for future blocks: the preview tells about the action that is confirmed by
the “Start” button, and about no other.
---

## The tooltip refresh erased the road-level line (2026-10-01)

**Context.** On a hex with a built pasture the line “Road: Trail (level 1,
…)” in the extended tooltip appeared and a second later disappeared — and did not return until the cursor
moved away. Resources without an improvement, farms, vineyards and woodcutter's camps
worked correctly.

**Cause.** The base and the extended tooltip blocks live in the same container
`_tooltip_products_container`, and `render_products` clears it before drawing.
The extended block is drawn **once per hover** (`InputHandler`: the flag
`_extended_tooltip_shown`). But for “growing” resources the handler calls
`update_tooltip_text` every `resource_display_interval`, and that rebuilds
the container from scratch and substitutes the base list — the road line disappeared.

Why only pastures: this refresh runs on `_is_hovered_tile_growing()` —
an improvement is built **and** the resource has `time_to_mature > 0`. Such a field exists only for
animals, that is, exactly for pastures. Farms and woodcutter's camps have no refresh at all.
Separately, the “off by one tick” also lined up: the delay for showing the extended block (1 sec) and
the refresh period (1 sec) are almost equal.

**Solution.** `MapTooltip` remembers the hex for which the block is shown
(`_extended_row` / `_extended_col`), and `update_tooltip_text` in that case
substitutes the extended block's set of lines instead of the base one. The line collection was moved into
`_collect_extended_block`, which is called both by the display of the block and by its redraw — otherwise
the two lists would have drifted apart. The binding is reset in `InputHandler` when the hex changes
and when the tooltip is hidden (`clear_extended_tooltip`) — the same place where its
own flag is reset. Along the way `_render_extra_products` updates `_last_products_key`:
previously the key stayed from the base set, and the “nothing has changed” optimisation
compared the wrong thing against what was actually drawn.

**Why the invariant belongs in `MapTooltip` and not a patch in `InputHandler`.** One could
have added `if _extended_tooltip_shown: update_extended_tooltip(...)` to the handler.
The diff would be smaller, but the invariant would remain broken inside `MapTooltip`: any
subsequent call to `update_tooltip_text` would erase the block again, and the bug would return
quietly. The point of the fix is “a periodic refresh has no right to erase an already shown
block”, and that is a property of the tooltip itself, not of the calling code.

**Why the test checks the contents of the container and not just the calls.** The regression
looks harmless exactly until in the test there changes
`fill_time`. If the fill text has not changed, the early exit triggers
“nothing has changed”, the container is left untouched — and the check passes without having
checked anything. The test moves the fill level between calls (which is precisely the cause of the refresh
in the game), performs **two** ticks in a row and counts the occurrences of the line: it must
remain and must not be duplicated. Separately it is checked that after `clear_extended_tooltip`
the line disappears — otherwise the fix would have quietly left the block hanging after the hex changes.

**What came in handy.** The constraint “refresh only for growing resources” explained
the report within a minute: the player listed where it worked and where it did not, and that exactly
matched `time_to_mature > 0`. Symptoms like these are not “it is broken” but “it works not
everywhere”, and the map of matches usually points to a condition, not to the code.

---

## The hex tooltip split into a base and an extended one (2026-10-02)

**Context.** The player asked: move out of the ordinary hex tooltip everything except the
terrain type, the resource and the improvement. On a hex with a pasture the tooltip grew to six or
eight lines, and most of them were properties that change over time
(fill level, output) or are needed far from always (access to fresh water).

**What exactly moved and where to.** The new function `MapTooltip._collect_hex_properties`
collects the hex's properties — resource quality, feed consumption, pasture fill level,
access to fresh water — and is used by two destinations: the extended tooltip block
(`_collect_extended_block`) and the full text of the left column of the control panel
(`_build_text` with `basic_only = false`). The ordinary tooltip calls `_build_text` with
`basic_only = true` and shows only the terrain, the resource and the improvement.

**Why I did not delete these lines entirely.** The control panel shows everything at once, without
a hover delay, and its `_build_text` is shared with the tooltip. If I had simply cut
the lines out of the function, the panel would have lost half of the information about the hex. Hence the flag
`basic_only` and a single properties function: a move, not copy-paste.

**The base production block was deleted entirely.** The tooltip had its own set of lines
`_collect_production` with the header “Once built, %s will give:”. It duplicated what
the extended block already shows — but with bonuses and modifiers. It would have left two
truths about the same output with different numbers, so I deleted the function.

**`has_extended_tooltip_info` was rewritten as “the block is non-empty”.** Previously the function
enumerated the conditions itself: production bonus, road, professional consumption.
After the move there were more such conditions, and the list would have started to diverge from
the list of lines: the block would either not show at all or show up empty. Now the check
asks the same collector that builds the block. A side effect in the collector is not
permissible in that case — it is called by `handle_process` every frame while the block is not shown (the
diary warned about this before too), so I also removed the dead line filter
`tr("Construction:")`, which for some reason was editing the caption.

**What came in handy.** Three things: (1) the rule “the check and the content ask the same
thing” paid off immediately — otherwise the very first new item in the list of conditions would have produced a silent
breakage; (2) the test first had to be brought to “fails on a clean HEAD”, otherwise it
would have protected against nothing: the first version passed silently because it checked
only the new code; (3) indentation in the project is spaces, not tabs (`.editorconfig`),
and a naive “re-encoding” of the indentation in the patch broke the file entirely.
---

## A self-introduced “bottleneck” — removed (2026-10-01)

**Context.** While sorting out road levels, the author noticed: “I see you
have introduced, on your own, such an entity as throughput with `min_speed`,
though I did not ask for it.” And he immediately formulated his expectation: a route should
have an **average** speed over the whole route — nine cart roads and one
trail give `(9*30 + 1*10)/10` = 28, not 10. One small pothole on a highway should not
suddenly lower the speed of the whole highway.

**What was actually wrong.** The average (`avg_speed`) already existed and was already
the arithmetic mean — the formula matched the author's expectation exactly. But
`min_speed` (the “bottleneck”) I had indeed introduced myself, without being asked, and put it
forward as the leading value: it made its way into the route line in parentheses, into the tooltip of the
“Upgrade road” button and into the upgrade preview. On top of that I defended it in `docs.md` with a separate
paragraph: “the average answers the question ‘how fast the cargo moves’, the minimum answers ‘where it
gets stuck’; it is the bottleneck that must be improved, not the average.” That is, the disagreement with the author was
recorded in the documentation as a position.

**Why my argument was wrong.** The reasoning came from a queue model:
the cargo must pass through the narrowest segment anyway, so the flow is limited by
the minimum. The model is consistent in itself, but it described a different game. The author
wanted a bad segment to lower the route's speed **in proportion to its
share**, rather than bring it down: nine good segments and one bad one is almost
a good route. The queue model and the “average over the route” model answer
different questions, and by substituting the first for the second I shifted the balance towards
“improve everything a little at a time” and made a trail on a highway a catastrophe.

**Solution.** `min_speed` was removed entirely: from the route dictionary, from three places
in the interface, from the tests and from the documentation. Only the average remained. Not a single
reference to `min_speed` existed in the logic — the availability of the “Upgrade road” button
is computed from the minimum segment level (`worst_level`), not from the minimum
speed — so removing the value broke nothing.

**A side discovery.** In the upgrade preview the line “Bottleneck: 10 → 30 units/sec,
average 30 units/sec” was simply incorrect: the third number was being substituted
`ceil(max_speed of the new road)`, that is, the per-segment speed of the new segment, not
the average over the route. Upgrading 3 segments out of 10 gives a true average of 16, while the caption
reported 30. That is a separate error, which removing the line closed. A rule for
the future: the number in the “average” caption must be computed from the route; substituting
the characteristic of a single segment and labelling it “average” is a typical trap.

**What came in handy.** The test for the author's example — nine cart roads and one
trail, exactly 28 — is now in `test_road_levels.gd`. What turned out to be useful was not
the number itself but the way it was constructed: the configuration had to be assembled all at once, because
`upgrade_road_segment` can only raise the level and lowering a segment
is impossible. The test for “the average is higher than the speed of the worst segment” checks precisely that
property which the author described in words about the pothole on the highway — that is, it pins down
a rule, not an example.

**Overall conclusion.** The route's speed should not have been invented: the author described it
in a single sentence with a formula, and that description covered the question completely. Inventing a “more realistic” value cost an extra entity in the API, three lines in the interface and a paragraph in the documentation that defended the wrong choice. Realism is not an argument here: if the author has set a rule, contentious improvements should be brought as a question, not as a completed change.

---

## A town's territory never intrudes on the player's starting area (2026-10-02)

**Context.** The author showed two screenshots: right after the start of the game a resource (sesame)
inside the player's Influence Ring turned out to be marked as the territory of the town of
Mervabad, and the town placed its decorative “Plantation” there; after advancing to the
second era the same territory turned out to be already inside the land assigned to the player.
The wording was firm: “under no circumstances”, with the clarification that
the rule must also be the same for the guaranteed 2nd-era town.

**What was wrong.** A town's influence ring (`compute_town_influence`) is built with a
radius of 3 and stored in full. The prohibition on the starting area was exactly one — on the
**centre** of the town (`_is_valid_town_hex`, the `exclusion_*` rectangle). But a ring
of radius 3, placed one hex beyond the border of that rectangle, quietly
intruded 2–3 hexes inside. Two consequences: a resource inside the Influence Ring received the flag
`in_town_influence`, `build_manager` blocked its improvement, and
`_place_decorative_town_improvements` placed a town building on it. The second
screenshot is a direct continuation: when the era changes, the player's Ring becomes exactly
the starting Region, so the “intruding” hexes turned out to be assigned to the player
(`in_influence`) and at the same time foreign (`in_town_influence`) — one could neither build
nor buy a chunk. On top of that, the attracting role was reversed: the player's resources
took part in building the priority masks, that is, they themselves pulled the town towards the border.

**Solution.** The starting area (the Ring + the 1st-era Region) became an entity rather than
a parameter of a single call: `town_manager.player_start_area`. Every hex of a ring
is cut out of it — for all towns, including the guaranteed era‑2 one, and the
cut-out check runs **before** the inter-town clip (“first come, first served” must not take
hexes away from the player). Resources inside the area drop out of the `multi_resource` and
`strategic` masks. The boundaries live in `map_state`, so the rule also works when a save is
loaded, not only at generation.

**What we deliberately do not do.** We do not push the towns back to `radius + 1` from the border
of the area. Then the rings would never have to be cut out and they would stay as even
circles, but the distribution of towns across the map would shift (and near the edge of the Region there
would simply be fewer of them), and the author would have to choose between a “beautiful ring” and an
“honest placement”. He chose cutting out — it is cheaper and does not touch the
placement balance. The price is known and deliberate: for a town right at the border of the area the ring
becomes a stub (on a live map, up to 10 hexes out of ~18). If ever this
starts to look bad, what needs changing is not the cut-out but the minimum distance to
the area.

**Why this does not repeat the old bug with the Region-based clipping.** The Region clip
(it existed and was removed) froze the ring at the borders of the 1st era: the Region grows,
but the clipped-off part never came back — the fill remained a stub forever.
Here the cut-out area is **fixed**: it is set once and does not change for the whole
game, so exactly what already belongs to the player is what stays cut off. The
difference is not in “to cut out or not” but in what exactly is cut out — and that is what must
be checked in the code and in the test.

**Saving and loading.** The boundaries of the area live in `map_state` as four fields
`start_region_*` and are restored in `_apply_saved_map_state()` BEFORE the
rings are recomputed. They cannot be recomputed from `start_ring_*` and `region_width`: `region_width` in
the save already stores the value of the CURRENT era, and for a game played through to the third
era such a recomputation would give an area larger than the real one — too much would be cut out.
In saves created before this change the fields do not exist; there the boundaries are approximately
restored from the starting ring and the current region width (for a game
started in the 1st era this is the exact value). Those saves cannot have their exact historical boundaries
restored — only replayed.

**What came in handy.** The new test was at first written “to a happy picture” and
passed silently — it checked only its own synthetic scenario.
Real value came from the habit of first breaking the rule (`_is_in_player_start_area`
returned `false`) and making sure the tests fail: all the consequences immediately came out,
including the “dead zone” after the era change — that is, the test protects against the whole bug,
not just one half of it. A second technique of the same kind: a separate
check of the save path (`load_towns` → `set_player_start_area` → recomputation), because
the first version of the test inserted towns directly into the array and in that way differed from
a real load.

---
## The road to an improvement is a chain of “road first, then improvement” (2026-10-02)

**Context.** At first the author asked that roads built automatically when an
improvement is constructed follow the same rules as ordinary roads (in stages and not for free, even the basic
trail), that both prices be visible in the preview, and that the improvement and the road start
in parallel, with the road having priority when construction slots are scarce. Then he clarified: let the improvement
be added TO THE QUEUE of the staged road construction — the road first, then the improvement straight after.

**What was actually wrong.** Three discrepancies, and all three were a consequence of a single
decision — “the road to an improvement is a side effect of the finished improvement”.
`main_map._on_build_completed()` called `road_manager.build_road_from()`, that is, it
laid the **whole** route with a single call, bypassing `project_manager`; the price of the road was
mixed into the price of the improvement (`get_improvement_work_cost` added `road_cost` into
`cost`), and `get_road_cost_for_improvement()` returned `0` first thing for level ≤ 1.
The result: an improvement on a distant hex cost as an improvement, the road appeared all at once and
for free, and in the preview the road line was drawn only when `road_cost > 0` — that is,
for the basic trail (which is almost always) it was not visible at all. Separately: because of
`road_level` in the construction record, the road level was lost when a save was loaded
(`restore_builds` did not read it), and `rebuild_roads_from_existing` rebuilt such
a road with the default level — **a cart road to a farm degraded to a trail**.

**An intermediate version that had to be redone.** At first exactly what
the first request asked for was done: the improvement is an ordinary construction in `active_builds`, the road is a separate
project, both start simultaneously, and when slots are scarce the road takes a slot and
the improvement is rejected. It worked, but **was inconvenient in essence**: the chain occupied
**two** slots, and in a new game there is one citizen, so an improvement with a road could not be
started at all — one had to build the road, then come back and build the improvement.
The priority of the road in this scheme was not a rule of the game but an attempt to get around the shortage of slots.

**Solution.** An improvement with a road is **one staged project and one slot**: first
the road segments, the last step being the construction itself (`data.step_type = "improvement"`, with the improvement's
id and a separate resource). The step applies `main_map._apply_improvement()`,
shared with ordinary construction and extracted from `_on_build_completed`, so the rule
“the improvement has appeared” does not exist in two forms. The start goes through `_start_road_project_steps()`,
shared with a road, by special action: one queue, one formula for the segment price, one
handler. The prices are separated — `cost` (improvement), `road_cost`/`road_segments` (road),
`total_cost` (the sum), and the sum of the queue's steps equals the preview's total, so the labour is deducted
once. Improvements that do not need a road do not touch the chain and remain
an ordinary construction — there is no reason to rewrite the construction path of all the game's improvements for their sake.

**The main pitfall — the “occupied hex”.** An improvement waiting in the queue is not in
`active_builds`, so the check “something is already being built on the hex” does not see it, and on the hex one could
launch a second construction, and the two would share the hex (and the one that
finished later would “win”). This is cured by an additional check of `project_manager.has_project_at` in
`build_manager.start_build`. Verified by a test.

**Why a separate `road_staged` flag.** The road network is not written to the save, it
is recomputed. For the player's road the input data is `road_built`/`road_level` on
the connected hexes plus the project queue. But `rebuild_roads_from_existing()` still
builds a road to **every** improvement, because previously an improvement
guaranteed a road. With a staged road this would mean that the unpaid remainder
after a reload gets completed for free, and a cancelled road comes back in full.
The `road_staged` flag on the improvement's hex says “this road is managed by a project”, and the recomputation
skips such a hex — it is restored in exactly the same way as the player's road.
Old saves do not contain the field, and for them the behaviour is as before: improvement ⇒ road.
A side effect of the solution — the bug with the level degradation was fixed: the road to an improvement
is now restored according to its own `road_level`, not by default.

**What we deliberately do not do.** Cancelling an improvement does not cancel its road: the road
has its own interrupt button, and already paid-for segments remain by the general rule. A second
project to the same hex is not created (`has_project_at`), otherwise the player would pay for one
route twice.

**Test.** `tests/test_improvement_road.gd` — the order of the steps (the improvement comes last, and before
its road there is none on the hex), one slot when the limit is one construction, the prohibition of a second construction on
an occupied hex, separate prices, both sums in the preview, and the skipping of `road_staged` during
restoration. The first version of the test silently missed the point: it computed the rate from
the **whole** labour of the city, while `build_manager` divides the labour among all active constructions —
the rate is half as much, and “exactly one segment per frame” was not satisfied. The second version of the test
was written for the parallel variant and after the decision changed it was checking non-existent
behaviour (the improvement in `active_builds`) — the test is fixed together with the rule, and that is worth
keeping in mind: checks against the old scheme look plausible. The lesson is the same as in
the previous entries: a check must replicate the mechanics, not just verify the result.
## A special action is not shown a road that will never be built (2026-10-02)

**Context.** The author noticed: in the preview column of the control panel the
road construction cost is shown for special actions too (for example, foraging
wild plants), although no roads are built when these actions are performed.

**What was wrong.** `main_map.get_improvement_work_cost()` appended the road breakdown
(`get_road_cost_breakdown_for_improvement`) to the result unconditionally — for any id
that did not turn out to be the most expensive. But a road is not owed to everything: `build_manager`
`.start_build` explicitly excludes special actions (`if not is_special_action ...` before
`start_improvement_road_project`), that is, foraging wild plants, clear forest, drainage and
demolishing an improvement go as ordinary construction on a hex, and `_on_build_completed` performs them,
without touching the road network. The panel, however, looked only at the numbers (`road_segments > 0`) and
drew the row "Road to the city (level): M work, K new sections", the hint about the
staged road and "Total", which this road was part of. The result: the wild-plant foraging preview
promised a route that nobody builds, and the "Total" was larger than the price of the action itself.

**Solution.** The road breakdown moved under the check `GameData.special_actions.has()`:
for special actions it returns `road_applicable = false`, `road_cost = 0`,
`road_segments = 0`, `road_pending = false`, `total_cost = cost`. The panel draws the road block
and the "Total" row based on `road_applicable`, not on the presence of numbers — that is, the decision
"is a road built here" is made by the source of the price, not by the display. The "Total" was removed
together with the road deliberately: without the second sum it would have been a copy of the price one row above.

**Why a flag, and not a check of the action type right in the panel.** The type (`build_improvement`
/ `special`) is known to the panel, but the road is not a property of the type: it depends on whether
the improvement is built as a chain. The check "is this a special action?" in the panel would become
a second place where the rule lives, and would diverge from `build_manager` if a special action
were ever decided to have a road laid to it. The flag is the same technique as
`road_pending`: uncertainty is expressed in the calculation data, not in a guess on the screen.

**What was deliberately left untouched.** The price of the special actions themselves
(`MapHelpers.get_improvement_work_cost`), their execution (`_on_build_completed`) and the block
of the road preview (`type == "special"` + `_is_road_action`) — there a road really
is built. The road level selector in the preview, as before, is set only for
improvements and breeding.

**Test.** None was written — the author asked to do without new tests. Manual check: the preview
"Collect wild plants" on a hex with wild plants — there must be no road rows and no "Total",
what must remain is the action price, base, terrain, distance and the tech multiplier; the preview
of an improvement on a distant hex — both sums are in place.

## A town sells the harvest, not the field it grows on (2026-10-05)

**Context.** The author sent a screenshot of the town window and asked why there are two "Wheat"
and two "Fish" in a row. He also complained that the long list spills past the bottom edge of the window
right onto the map.

**What was wrong.** `collect_base_resources()` put into the base pool **both the resource id
on the hex and its `produces`**. Everything follows from that: `wheat_field` (a sowing, named "Wheat") and its harvest
`wheat` (grain, also "Wheat") ended up in the same list as two rows; `freshwater_fish`
and `sea_fish` — both "Fish"; and "Ostriches" and "Cows" generally looked like goods, although a town
does not sell animals, it breeds them. On top of that, `BuyList`/`SellList` were bare `VBoxContainer`s
in a 600×440 window — without clipping and without scrolling, so dozens of rows physically ran
past the panel.

**Solution.** The rule moved from the data into one place: **only the produce of a resource
goes into the sale pool**, while the resource itself — a field, a deposit, an animal — is not goods. Previously this read
as a "list of exceptions" (remove fields, remove animals, think separately about one-off ones),
and each exception had to be remembered. Now there is one rule and it covers everything at once:
`wheat_field` → `wheat` + `feed`, `cows` → `raw_meat` + `hide` + `raw_milk`, `cows` is never
in the pool at all, so there is no need to check for it either.

One-off resources (`improved_by == null`) split into two different answers, and this is not
an accident but a difference in the nature of the thing. `wild_food` is a find: you gather it — and it is gone, so
neither it nor `foraged_food` appears in trade. `copper_nugget` and other nuggets are
also one-off, but this is ore, not a find: copper is needed by the blacksmith and is mined without
restriction, so its produce goes into the pool. The trait is extracted into `is_one_time()` and matches
the in-game one (the same as for the "Collect resource" special action), while the `metals` category distinguishes them.
It is worth noting separately that `wild_food` has the category `plants`, not `metals` — the cutoff had to be by
category, not by the `wild` group.

In the interface, the lists went into a `ScrollContainer` (following the example of `InternalScroll` in `CityUI`),
the window grew from 600×440 to 768×600 and got `clip_contents`. The dedup by name in
`_fill_resource_list()` is kept, but now it is insurance rather than the main protection: in
`data/products` there is exactly one pair of different ids with the same name —
`papyrus_plant` (harvest) and `papyrus` (craft), both "Papyrus", and both really can end up in
the pool of one town.

**Why this is safe for the chain.** The rule seemed risky: what if some
recipe eats a raw resource. I checked the data — not a single id from `data/resources/**` appears
as an ingredient of any recipe from `data/crafts/**`. Recipes operate only on produce
(`hide`, `raw_meat`, `wheat`, `copper_ore`), and all `produces` of all 112 resources point
strictly to produce. So the chains do not break, and the pool simply stops showing what
should not be in it.

**What had to be rewritten in the tests, and why this is more important than the edits themselves.** Four checks in
`test_town_food_fields.gd` and one in `test_town_start_area.gd` looked in the pool for **the resource itself**,
and after the edit they became meaningless: `sell_pool.has("sheep")` can never be true,
that is, the check stays green forever and stops guarding anything. I rewrote them to check
produce (`wool`/`raw_meat`/`raw_milk` for a sheep, `wheat`/`feed` for wheat). Separately,
`_res_group(res_id) == "food_plants"` became a vacuous check: it looks for a group in
`raw_resources`, but the pool now holds produce, which is not there at all — the check passed
always without checking anything. I replaced it with the goods category from `data/products`.

**Lesson.** The check "X must not get into the pool" after a rule change often stays
green not because everything is fine, but because X can no longer get there. A green test
after a data edit is worth re-reading with your eyes: it may have stopped asserting anything.

**Test.** `tests/test_town_economy.gd` — 5 new cases: the base pool contains only
produce (including the regression "not a single id from `data/resources/**`"), animals are excluded,
one-off resources (`wild_food` is empty, a nugget yields ore) and `is_one_time()`; two ids with the same
name give one window row; the lists are in a `ScrollContainer`, `clip_contents` is enabled,
the content is taller than the window and scrolling really scrolls. `test_town_food_fields.gd` and
`test_town_start_area.gd` are rewritten to check produce.

## The left column of "Trade" shows only what the city can really obtain (October 8, 2026)

**Problem.** `consumption.json` describes the POTENTIAL demand of professions: a pasture
will want boats, citizens — fruit, alcohol, dishes, jewelry. But as long as the city has neither
a supply nor production, these rows are pure noise: the player opens the tab and sees
a list of resources he does not have and cannot get anywhere. A row in the list reads as
"the city trades in this", while in fact it is "someday, if it appears".

**Solution.** The left column is split by the trait "the city can really obtain this":
available resources are ordinary cards, unavailable ones are under an expandable list
(a toggle with an arrow and the number of hidden rows). The fold is closed by default, the state
of expansion survives a rebuild. The toggle is created only when there is something to hide —
an empty fold over an empty container would be the same noise we are moving away from.

**Where the boundary of availability is.** The trait is `is_resource_obtainable`: a resource is obtainable if
at least one of its members is in storage or is part of the production plan
(`get_planned_production_map` — recipes with a citizen and working improvements). A group
is available when any member is available: members are interchangeable, a group is "any
suitable goods". We do **not** count as available what "theoretically could appear":
vegetation of a suitable biome, a researched technology, an existing recipe without
an executor. Such a resource is unavailable precisely because the city has not a single unit and
nobody makes it — and it is exactly this case that created the noise.

**Why not a list of exceptions.** The first impulse is to subtract from `consumption.json` the entries
for professions that the city does not have. This works until the first worker: hire a fisherman —
and boats surface, although there is nowhere to get them. Availability is a property of a specific pair
"resource × current state of the city", not of a profession, which is why it is computed from
the current storage and production plan, and not from the data.

**Invariant.** Availability is part of the signature of the column's composition (`_signature_of` marks
each key `=1`/`=0`). Without the mark, a resource that became unavailable or available
would not rebuild the layout: the set of keys is the same, but the card must move between
the working list and the fold. The next session, adding a field to the market card row, must
remember: everything that affects the position of a card in the column must go into the signature.

**What we deliberately do not do.** We do not hide unavailable resources entirely — the player must
see the possibilities (what groups exist, what generally appears in demand), which is why it is a fold,
and not a cut-out. We do not count imports: foreign trade is not implemented. When it appears,
import will give a row a supply/production and will fall under the same rule without changes.

## A single test run: `tools/run_tests.py` (October 8, 2026)

**What was decided.** The tests remain independent `SceneTree` scripts in their own processes —
this is their main virtue (one failing does not bring down the others). Instead of a framework
(GUT/gdUnit would have required rewriting all 39 tests), a thin launcher was added on top of the
already existing scheme: it assembles the run in one place and applies to each test
the same verdict rules.

**The verdict rules are the whole point of the launcher.** The main one: `SCRIPT ERROR` / `Parse Error`
in stderr is a failure **regardless of the return code**. The diary has already recorded this case
in words ("catch engine errors in tests just as strictly as assertion failures"), but in
practice the run was manual: `grep FAIL` over stdout. The launcher closes the hole mechanically.
Additionally: code 0 without a verdict line is also a failure (an empty run is never green),
and for `test_pause_menu_confirm` the verdict is taken from the `user://…done` marker, because this
test kills its own process and its return code proves nothing.

**The rules were validated by mutation, not on faith.** A parse error was introduced
into `test_fog_info` (the assertions pass, the return code is 0) — the launcher caught it.
The verdict line was removed from `test_icon_registry` — a "silent run" was caught.
An early `quit(0)` before the marker was added to `test_pause_menu_confirm` — caught by the absence
of the marker. All three mutations were reverted, the tree is clean.

**Isolation.** `APPDATA` is substituted with a sandbox for each process. This is mandatory
for a parallel run: two tests really write into the user directory
(`settings.cfg` in `test_resource_display_interval`, the marker in `test_pause_menu_confirm`),
and `--user-data-dir` and `--isolated` in Godot 4.7 are ignored on `--script` launches —
verified. The marker is deleted before the launch, otherwise a file from a previous run would give `PASS`.

**A side result — two stale tests.** The run immediately found what it was made for:
`test_cancel_actions` and `test_staged_projects` printed "TEST OK" and exited with code 0,
while in stderr there lay `SCRIPT ERROR: Invalid type in function 'start_road_project' … Cannot
convert argument 3 from String to int`. The tests passed `ROAD_ACTION_ID := "build_road"`
where a `road_level: int` has long been expected (the signature changed together with road levels).
Both sides were fixed: the third argument is now taken as
`GameData.get_max_unlocked_road_level()` — the same derivative that
`build_manager` uses, so a balance edit of the levels will not turn the test into a different scenario.

**Cost and gain.** 39 tests, 6 workers — about a minute for a full run versus roughly
six minutes sequentially. The sets are separated: "fast" (19 tests, without
map generation and long economic runs) and `--all`. The classification is constants in the
script itself; a test that falls into neither list is still executed by `--all` and printed
as `fast`, so a new test cannot silently drop out of the set.

**Rejected.** Running all tests inside a single Godot process — then one failure
kills the run and the isolation for which the scheme was built is lost. Logs for each test
and the run summary are in `tools/test_logs/` (outside the index).

## The "resource consumed by someone" marker in the building details tooltip (October 8, 2026)

**Task.** In the pinned building details tooltip on the "Buildings" tab, a resource that
is part of an entry in `data/consumption.json` must be underlined with a dotted line (by analogy with
the breakdown of `@`-groups) and, on hover, show who consumes it.

**A reverse index, not a walk over professions.** `GameData.get_consumption_consumers(display_key)` was added —
it is the inverse of the same registry: addressed by the same `display_key` with which `get_profession_consumption`
fills in the entry (a product id or `@<group>`). The alternative — iterate over `professions` and call
`get_profession_consumption` for each — would give a different row order, a different set (the entry
`"profession": []` would not be found) and would cost more; most importantly, it would read the data "from the other
side", and a divergence from the write-off mechanic would be a matter of time. The same key in both
directions rules this out by construction. Legacy entries `products[*].consumption` are taken into account,
but lose to the registry by the same "profession+resource" pair — the same priority as in
`get_profession_consumption`.

**Two different underlines.** `underlined_label.gd` got `dot_style`: a link to a group
is drawn with a 2 px dash, the consumption marker — 1 px. This is not decoration: an `@`-group and "resource
consumed by someone" are different facts, and in one row they can meet (the "Alcohol" group
in the "Consumes:" section — both a link to the composition and a consumption marker). The same line would make
the player guess what the dash under the name means.

**The consumers tooltip is its own panel.** `ui_helpers.show_consumption_tooltip` is drawn in
`consumption_tooltip_panel`, not in `group_tooltip_panel`. Reuse looked cheaper,
but then for an `@`-group one would have to choose: show the composition or show the consumers — and
the player needs both. The rate is formatted with the same `ConsumptionUi.format_rate` as the
profession's consumption rows: the numbers in the two places physically cannot diverge.

**The marker is opt-in (`show_consumers`), not default behavior.** `make_resource_entry`
is called by all tabs, and in most places the row reads as an "expense" or an "ingredient"
(recipes, construction cost, the upgrade window). The consumption marker there would be noise, so
it is enabled by the recipe rows of the building details tooltip: in a recipe a resource is named without a norm, and
the underline with the tooltip add what is not visible in the row. On the other screens (construction
cost, the upgrade window, the "Resources" tab) the resource remains un-underlined.

**Test line.** In `tests/test_building_consumption_ui.gd` a case `consumption_marker` was added
(enabled via `--case=`, like the others). The assertions are derived from the data: the marker is searched for by
the resource name from `get_profession_consumption`, the presence of consumers — through the reverse index,
the rate in the tooltip is checked against BOTH variants of the unit string ("ед./сек" / "units/sec"):
the build's `units/sec` as a separate `msgid` stays untranslated in the headless run, and
hardcoding one variant would fail the test on correct data — which is what happened on the first iteration.

## The road level on a hex also accounts for town roads (October 9, 2026)

**Symptom.** When hovering over hexes in a town's influence ring, the row "Road: …"
in the extended tooltip and in the left column of the panel appeared intermittently: on one
hex the level is there, on the neighboring one — not. The criterion ("whose road is this") is not
visible to the player: a road is drawn on both hexes.

**Cause.** `road_manager.get_hex_road_level` computed the maximum only over
the segments of the PLAYER city's network (`road_segments`) and deliberately ignored the
town network (`town_road_segments`, see docs.md, "Road level on a hex"). But
town roads are drawn on the map (`map_renderer._draw_all_roads`, phase 2b), and
the route of a road to a town improvement (for example, to a quarry) consists of town
segments. The result: a hex with a drawn town road and without a player road gave
an empty row — while the neighboring hex, which the player's road had already reached, showed
"Cart Road (level 2)". Hence "sometimes it shows, sometimes it does not".

**Solution — count the segments of BOTH networks.** A town road is drawn, so
the row must describe it: the tooltip answers the question "what is drawn on
the hex", not "what the player can change here". This is exactly the same principle by
which the MAXIMUM over adjacent segments was chosen earlier ("the maximum matches
how the hex looks on the map"). The previous formulation of the decision ("town
segments are not counted, their level is always 1 and the player does not upgrade them") protected
against noise, but created a worse noise: silence about a visible road.

**Why this does not break the rest.** `get_hex_road_level` is a purely display
quantity (docs.md: "for display only"), it has no other consumers. The route
(`find_route_to_city`) already counted town segments as a trail
(`_segment_level_by_key`), the "Upgrade road" button comes from the route
(`get_route_to_city`), not from the hex level, so in the ring of a foreign town it
does not appear. A separate `_any_segment_level` was added, and `get_segment_level`
was left as it was: it sees only the city network, and that is needed for route finding.

**Test.** `tests/test_town_roads.gd`, case `town_road_level_on_hex`: on
a synthetic map with towns it checks that for a hex outside the city with a town
road (and WITHOUT a player road — this is checked separately, otherwise the test would pass
before the edit too) `get_hex_road_level == 1`. Validation by mutation: with
`get_hex_road_level` reverted to the old behavior the case fails ("got 0"). Plus
`test_road_levels._find_hex_without_road` now looks for a hex with
`get_hex_road_level == 0`, not only `not is_hex_connected`: a town route
can go outside the ring, and "a hex without a road" must mean "without a road at all".


## A road to a town goes all the way to the town itself at the chosen level (October 9, 2026)

**Symptom.** The player builds a high-speed highway to a town, selects
a level (a cart road) in the preview, but at the border of the influence ring the highway "turns into
a trail": the last hexes to the town are drawn as a trail, and the route to the town
loses in average speed.

**Cause.** The target of the road to the town was **the nearest road in the influence ring**
(`road_manager._town_road_targets_in_ring`): the route was searched with multi-point
Dijkstra from all roads of the ring to the city network and broke off at the first of them.
Only NEW segments received the chosen level (from the city network to the ring), while
the last stretch "ring → center" remained the town's own trail
(level 1, `town_road_segments`). The player saw and paid for a highway, but a
trail reached the town.

**Solution — the target of the road to the town is the town itself (its center).** In
`_compute_road_plan`, for a town hex the source of the route became the town center
(previously — all roads of the ring), and not "the nearest road in the ring". All segments
of the route, including the last one (entering the ring and leading to the center), receive
the level chosen by the player and go into the CITY network. `_town_road_targets_in_ring`
was deleted; the parameter `town_influence_hexes` was cleaned out of `plan_road_to` / `build_road_to`
and out of `main_map.get_road_plan` / `rebuild_player_roads` (and along with it
`main_map.get_town_influence_hexes`) — it no longer influenced anything.

**Why this does not break the networks.** Where the player's route passes over a
town trail, the segment lies in `road_segments` (the player's level) and at the same time in
`town_road_segments` (the trail). This is not a conflict: the route and the level row take
the level from the city network (`_segment_level_by_key` prefers `road_segments`,
`get_hex_road_level` — the maximum over both networks). The link is still computed
by the intersection of the networks (`is_town_linked_to_city`): the town center belongs to both.
The town network remains its own — its other branches (to improvements) are untouched.

**Rendering.** Two edits in `map_renderer._draw_all_roads`. First: segments of the
town network already covered by the player network are not drawn (previously the town trail lay
on top of the highway). Second: the link segments to the town are drawn BY LEVEL from the city
network (previously — with the default style on top of the level road), and they are
excluded from phase 2a and drawn only in phase 2c with the fog gate — that is how it is intended in
the comment on the phases, but the code had drawn them twice before this, once without the gate.

**Test.** `test_road_building.gd`: `_test_town_link` now checks that
`road_path[0]` is the CENTER of the town (and not a hex of the ring), and that the route ends on
the city network; the new case `town_road_level` builds a road to the town at a level above
the trail and checks that EVERY segment of the route is of this level, and that
`get_hex_road_level(center)` equals the chosen one. Validation by mutation: with the target
`(row+1, col)` (the road breaks off on the neighboring hex) the case fails "got 1".
Full run — 39/39 PASS.

**Rejected.** Keeping the target on the ring and "raising" the segments of the town network to
the player's level: then the level would live in the town network, which the player by design does not
upgrade, and `town_road_segments` would stop being "always a trail" — one would have
to introduce a second source of the level for the same road.

## Two roads that meet on neighboring hexes connect themselves (October 9, 2026)

**Symptom.** In the player's screenshot: in the center a vineyard with a road, to the southeast
of it — another road. The hexes are neighbors, the roads look at each other, but
there is nothing to connect them with — "under such conditions the roads should connect
automatically". There is no manual way to close the gap: the "Build
road" button is shown only on a hex where there is NO road YET (`control_panel`), and
both hexes of the gap already have a road.

**Cause.** The route connected to the FIRST reached hex of its network and
did nothing more. If two branches of the network came to NEIGHBORING hexes, the segment
between these neighbors never appeared: `_find_connect_path` returned a path to
one hex of the network, and "did not know" about the second neighboring hex of the network. Diagnostics on
a live map confirmed this: the city network had 17 connected hexes and 6 pairs
of neighbors between which there is no segment (for example, `29,27 -- 30,27`,
`30,31 -- 31,30`, `31,27 -- 32,28`); the same class of gaps was found in town
networks too.

**Solution — a new hex of the network merges with all neighboring hexes of the same network.**
`road_manager._join_adjacent_connected(row, col, road_level, connected,
is_town)` appeared: it iterates over the neighbors of the just-connected hex, and if the neighbor is already
in the network and there is no segment between them — it builds it. The merge segment is laid at
the level of the JUST laid road (the road "continues" onto the neighboring hex at
its own level). The helper is called from all four places where hexes enter the network:
`build_road_from` and `build_town_road_from` (restore from save) — for each
hex of the path, `build_road_to` — for both ends of each laid segment,
`build_road_step` (a staged project) — for both ends of the step. For towns
(`is_town = true`) the segment goes into `_add_town_road_segment` and remains in the
town network — the city and town networks are still independent.

**Why this is right, and not "patching".** The gap is a consequence of the fact that pathfinding
stops at the first hex of the network, although the network is a set of hexes, not a single
"entrance". Merging neighbors brings the shape of the network into a consistent state:
a connected hex and its connected neighbor must be joined by a segment. This is
an invariant, not a special case — the diagnostics after the edit give
`city network: connected hexes = 17, missing segments between neighbours = 0`.

**Test.** The new case `merge_adjacent_roads` in `tests/test_road_building.gd`:
synthetic `city -> R -> P`, and the hex `Q` is adjacent to BOTH `R` AND `P` (`R`
and `P` have a common diagonal neighbor). It cannot be shorter than one of the two links, so
pathfinding reaches either of the two, and before the edit exactly one segment remained
unbuilt. The case checks that after building a road to `Q` BOTH segments exist
(`Q-R` and `Q-P`) and that the merge segment is of the level of the laid road.
Validation by mutation: with `_join_adjacent_connected` stubbed out the case fails on
"a new hex must merge with the second neighboring hex P of the same network as well".
Full run — 39/39 PASS (it was 38 + the new case).

**Rejected.** Fixing it in `_find_connect_path` by adding all hexes adjacent to
the network to the targets: then the path would end on a random neighbor, not on the "entrance" to
the network, and the cost of the route (the number of segments) would depend on the traversal order. Merging
after the fact is cheaper and does not touch planning.

## Road throughput limits hauling out (October 9, 2026)

**What was done.** Roads had levels with a stated maximum speed, but
the flow of resources along them was limited by nothing. Now
`main_map._emit_continuous_production` compares the output of each
product against the average speed of the route to the city and trims it down to that speed:
everything that does not fit is lost. The average speed comes from
`road_manager.find_route_to_city().avg_speed` — it is the arithmetic mean
of the segments' maximum speeds, not the minimum: a road made of a string of trails and
highways has the right to be a little faster than a solid trail.

**We limit each product separately, not equally.** The first idea — to divide
the throughput between the products of an improvement — was rejected. `avg_speed` is
the flow for each resource, not a shared budget: two carts carrying different things are not
obliged to share a lane. Therefore each product is compared against the speed
independently, and an improvement may have wheat getting through while feed does not.
The same requirement dictates the interface (see below).

**One source of truth for speeds.** A product's production speed is needed in
two places — in the simulation tick (to trim) and in the interface (to display). So that
the multiplier formula does not drift apart, in `map_tooltip.production_rates` there is a
single calculation `{prod_id: {rate, base}}` (improvement interval × multipliers × fill
fraction × irrigation), and it is used by both `_collect_extended_production` and
`main_map._emit_continuous_production`.

**Indication.** A red triangle with a "!" is drawn above the improvement — to the right of
the water droplet, if there is one (`map_renderer._draw_road_capacity_warning`; the shared
primitive `_draw_warning_triangle` is now also shared by the technology warning).
The `tile.road_capacity_short` flag is recomputed every simulation tick, so
after loading a save it comes into a consistent state on its own — the renderer
recomputes nothing per frame.

**Tooltip and panel.** In the "Produces:" block, each problem resource, next to its
total, gets a red note ` (route X units/sec)`. It is localized through
the new msgid `" (route %s units/sec)"`; the key is put into the item as `route_text` /
`route_color`, and `render_products` outputs it as a second `Label` on the same row.

**Test.** A new case `tests/test_road_capacity.gd` (SLOW): a pure check of the trimming
(15 wheat + 5 clay with a route of 10 → 10 and 5; route `-1` → no trimming) and
a live scene — a synthetic resource with `{wheat: 10, clay: 20}`, a level 1 road:
clay is flagged as short, wheat is not; after upgrading all segments to level 2
(`avg 30`) the flag is cleared and the 20 clay goes through in full. Full run —
40/40 PASS (was 39 + the new case).

**Rejected.** (1) Dividing `avg_speed` between products — see above. (2) Computing
the shortfall flag in the renderer every frame — expensive and duplicates the production formula;
we compute it in the tick. (3) Blocking production when there is no route:
`harbor`/`fishing_boats` have `no_road = true`, there is no land route, and `ok = false`
means "we do not limit", not "we forbid".

**Side finding.** The farm's `feed` yields 120 units/sec — that hits the ceiling
of the trail immediately, as soon as feed is unlocked (animal husbandry technology + pasture). Under
the new mechanic this is expected, but the balance of that output is a question for the author, not for
the code.

## Rivers are clipped by the fog of war, not by the Region rectangle (October 9, 2026)

**Problem.** Rivers were drawn on top of the fog of war: a hex in the fog is not
drawn at all (see `_draw_hex`), while the river line ran through it and hung in
the black void.

**Solution.** A river point is visible if at least one of the **three nearest**
hexes to it is not in the fog. A river flows along the edges of hexes, so the two nearest hexes
share the edge beneath the point, and the third covers the point at a vertex where three
hexes meet. A point surrounded by fog is hidden — the river breaks off at the border of the scouted
area.

**Why the three nearest hexes, and not one nearest.** Checking only the nearest
hex produces a dashed line: the meander wobbles the point around the edge, the nearest center
ends up sometimes on one side and sometimes on the other, and a river running exactly along the border
of the scouted area breaks into dashes. The three nearest hexes cover both sides
of the edge, so such a river stays solid, while the clipping still happens exactly
at the border: a point inside the fog is surrounded by fog from all three nearest hexes.
A hex outside the map is not counted as visible — `is_hex_in_fog` outside the map returns
`false`, so the check includes an explicit `is_hex_on_map`.

**Deliberately not doing.** We are not bringing back clipping by the "Ring +
Region" rectangle (it existed before scouting appeared): now the visible area is not
a rectangle but the union of the Ring, the Region and the scouted hexes, so
the rectangle would clip away scouted areas and leave fog inside. Nor do we clip
by the nearest hex alone — see above.

**Invariant.** Fog affects river clipping, so any change to it (scouting,
buying territory, changing era, debug map reveal) must reset the cache
of river geometry; the single entry point is `invalidate_town_influence_cache()`.

## Production lines: speed per second only (October 9, 2026)

**Problem.** The extended tooltip displayed differently how much an improvement
would give on a resource. Fish: "Raw fish: 10 units/sec". Sheep: "Raw meat (base 20)" — without
a speed. Limestone: "Limestone: 5 units/sec", even though the data says
`produces: { "limestone": 10 }`. The same for nephrite, soapstone, lawsonia and woad.

**The cause — two independent ones.** (1) The format of the line depended on whether
a modifier was active or whether the livestock was incomplete: the base was shown only then. Fish
(no `time_to_mature`) went as a speed, sheep (a growing resource) — as a base.
(2) The number from the data is the output per ONE production cycle, not per second:
speed = `produces / production_interval`. A quarry and a mine have an interval of 2 sec,
so 10 per cycle = 5 units/sec; fishing boats have an interval of 1 sec, so 10 per
cycle = 10 units/sec.

**What exactly the player gets.** Verified in the code and empirically
(`tools/diag_production_rate.gd`): production is CONTINUOUS.
`main_map._emit_continuous_production` on every tick (`SIMULATION_TICK = 1 sec`)
adds `produces × multiplier / production_interval` units to storage. Limestone
gives exactly 5 units EVERY second (5, 10, 15, 20, 25 after each tick), not
10 every 2 seconds. The player never sees batches of `production_interval` length.

**Solution.** The line shows only the speed per second: `"Name: M units/sec"`.
The "per cycle" base is removed — it does not reach the player as a separate sum, and the label merely
provoked a comparison with a number the player does not see. The fix is in
`map_tooltip._collect_extended_production` (the tooltip and the left column of the panel) and in
`control_panel._build_preview` (the construction preview) — one format. The orphaned
msgid `"%s (base %s)"` was removed from `locale/messages.pot` and `locale/ru.po`, the `.mo`
was rebuilt.

**The "when built" hint.** On a hex without an improvement `tile.fill_time` is 0
(livestock is filled only after construction), so the fill fraction was 0
and damped the speed: for sheep the line had no number at all. The hint describes
the future and therefore takes the potential output (`fill_frac = 1.0`), while a working
improvement still shows the current fraction.

**Test.** A new case `tests/test_production_display.gd`: for a resource with an interval
≠ 1 the speed = base/interval (5, not 10) and there is no base in the line; for a growing
resource without an improvement the hint shows the full speed, not 0. Validation
by mutation: restoring the zero fill fraction fails the case. Full run — 42/42
PASS (was 41 + the new case).

**Rejected.** (1) Showing the per-cycle base next to the speed: that is what we
did at first, but the player receives a continuous flow, and "base 10" next to "5 units/sec"
only confused things — the division by the interval would have had to be explained. (2) Showing
the number from the data (10) as the speed: it would not have matched what actually arrives at
storage. (3) Showing "10 every 2 seconds": there are no batches in the game, `production_interval`
the player never observes.

## Logistics: the surplus waits in a queue instead of being lost (October 9, 2026)

**What was wrong.** The previous version (`## Road throughput
limits hauling out`) compared the product's speed against the route's average speed and
**trimmed** the excess: everything that did not fit into the flow disappeared. The player lost
already-produced goods because of a narrow road — a road should set the **pace**, not
destroy the product.

**What was done.** A route is now described by **two independent quantities**, and they are not
mixed:

- **delivery time** (transit delay) = `route length × transit_time_per_hex`;
- **throughput** (flow rate) = the route's average speed `avg_speed`.

`transit_time_per_hex` is the **single tuning point** (`data/game_balance.json`, the
`logistics` block, starting at `0.2` sec/hex); both the engine and the interface read it through
`DeliveryManager.get_transit_time_per_hex()`. The length is already available in
`find_route_to_city(...).length`, so the delay is derived, not a data
parameter.

The surplus is **no longer lost**: the product joins a queue on the route, leaves at the
flow rate, travels for the delivery time, and only then is credited to storage.
Production, recipes, labor and balance did not change — the fate of the surplus did.

**The limit is per route.** Each route has one shared limit and one queue
(FIFO): batches from one improvement leave in order. **Different routes do not
compete** even on a shared road segment: three routes of 30 units/sec give 90
in total. There is no full simulation of "carts" — a flow and a delay are modeled. Batches do not
artificially wait for each other: two can be on the road at the same time.

**The engine — `scripts/delivery_manager.gd`.** One node on `MainMap`, updated
once per frame (`update(delta)`): intake is per frame (cargo counts down rather than using an
absolute time, so the save does not depend on the clock), while shipping is in steps of
`SHIP_STEP = 1 sec`. No timers per batch: the whole logistics state is in one
place. The public entry point is `create_cargo(row, col, product, quality, amount,
source)`; `get_route_status(...)` gives the interface `{has_route, flow_rate,
transit_delay, pending, in_transit, eta}`. If the route disappears (the road was demolished or
cut off), `_flush_route` releases the unfinished cargo to storage — goods do not get stuck
in a nonexistent route. `main_map._emit_continuous_production` received
the parameters `row, col, route_avg_speed` and passes the output to `_deliver_production`:
if there is a route — `create_cargo`, if not — straight to storage (without a road there is nothing
to limit). `SaveManager` serializes the logistics state under the key `delivery`.

**Purchases from towns — engine and API, no interface.** A purchase does not
"materialize" instantly: the quantity and payment are fixed, then the cargo travels via the
same `create_cargo` and arrives under the same rules. The limit is for the whole route, not for
an individual purchase. The purchasing interface is for the future.

**The interface — minimal.** `map_tooltip.delivery_lines(row, col)` gives the lines
"Delivery: waiting to ship N units" / "in transit N units (arriving within X sec)" in
the extended tooltip and the left column of the panel. The red note `(🚧 X units/sec)` and
the triangle above the improvement remain — they show the **limit** of the route.
There are no moving caravans.

**Test.** A new case `tests/test_delivery_logistics.gd` (SLOW): delay =
length × coefficient; the flow limits shipping; the batch size does not affect
the pace; batches of one route share one limit (FIFO); different routes do not
compete; two batches on the road at once; nothing is lost or duplicated;
save/load; time scale; road upgrade; length scales the delay;
the coefficient comes from the balance. The old case `test_road_capacity.gd` was rewritten:
instead of "trim, the surplus is lost" it checks that the whole volume sits in the queue and
arrives. Full run — see `tools/run_tests.py`.

**Rejected.** (1) Keeping the trimming and "losing" the surplus — directly contradicts
the requirement not to lose goods. (2) Dividing the limit between products or batches —
a road has one physical throughput. (3) Shared competition of routes
for a segment — a route is an independent thread, a neighbor must not silently cut it down. (4)
Simulating vehicles — the requirement is "no full simulation of carts".
(5) A timer per batch — expensive and complicates the save.

**About `.mo`.** `project.godot` loads `res://locale/ru.po` directly (Godot reads
`.po` itself), `locale/ru.mo` does not take part in loading — verified by deleting the file:
Russian still works. The `.mo` remains a compiled artifact for
compatibility/tools and is rebuilt by `tools/i18n_compile_mo.py` (with no
external dependencies), but it does not affect the game.

## Delivery in the tooltip updates in real time (October 10, 2026)

**Symptom (in the author's words).** The extended tooltip on the map does not update in
real time: the delivery state in it freezes at the moment the tooltip appears.
The queue and the cargo in transit should change, but the line does not move.

**Cause.** The periodic refresh of content without mouse movement in `InputHandler`
went **only by growing resources**: `_is_hovered_tile_growing()` checked
`time_to_mature > 0` on the hex's resource. The delivery lines had been added to
the extended block (`_collect_extended_block` → `delivery_lines`), but the refresh
condition did not know about them: delivery has no `time_to_mature`, so a hex with cargo
was considered static and `update_tooltip_text` was not called for it. A classic
expense: the lines and the "when to redraw" condition lived in two places and drifted apart.

**Fix.** The decision "whether to update the content" was consolidated into **one pure point**
`MapTooltip.has_live_content(row, col, tile_data)`: it returns `true` if
the hex is growing **or** there is cargo on its route (`delivery_manager.has_cargo`).
`InputHandler` no longer keeps its own copy of the condition — it asks `main_map.
has_live_content(...)` and updates the tooltip once per `CityData.resource_display_interval`.
The growing-resource logic moved from `InputHandler` into `map_tooltip` (both causes
are now next to each other; the dead `_is_hovered_tile_growing` was removed).

**Why the period is the same as the rest of the UI.** The data changes on 1 sec ticks, and
the display interval (1..5 sec, a setting) is deliberately shared across the whole interface:
all places update "in one jerk" per era. A separate period for delivery would
phase-shift the tooltip and the left column of the panel (`control_panel.on_city_updated` → `_refresh` →
`_append_route_info` → `delivery_lines`) — they show the same
lines and must not diverge.

**Test.** A new `tests/test_tooltip_live_refresh.gd` (SLOW): a hex without cargo and without
a growing resource is static; with cargo — "live"; a delivery step changes the displayed
block (2 lines → 3, "in transit" appears); after the haul-out the hex is static again.
Validation by mutation: if delivery is removed from `has_live_content`, the case "a hex with
cargo must be considered live" fails — the test really does guard the defect.

**Rejected.** (1) Keeping the condition in `InputHandler` and also adding the cargo check
there — then the refresh cause would again live in two files, and the test could not
exercise the decision without a live scene with hovering. (2) Its own, more frequent period for
delivery — a desync with the panel and with the display era. (3) Updating the tooltip
every frame — extra container rebuilds; the guard "only on a real
change" saves us from extra drawing, but not from extra row assembly.

## Logistics: a queue without a false jam and a cleared triangle (October 11, 2026)

**What was wrong.** Two symptoms from the game. (1) The control panel forever showed
the "waiting to ship" line, even when the road was carrying the whole production without a jam.
(2) The overload "!" triangle did not disappear right after building an improved
road — you had to jiggle the mouse.

**Cause (1).** The panel reads the queue inside the tick: `main_map._process` runs
production, then `CityData.do_tick()` emits `city_updated`, and
`control_panel.on_city_updated` → `delivery_lines` takes `pending`. But shipping happened
in `delivery_manager.update(delta)` AFTER the tick. That is, the panel always read the queue
at the moment "production has already been added, but not yet shipped" — and on a road that
carries everything, it saw that very fresh production of the second as "waiting to ship".
The delay (transit) and the flow had nothing to do with it — the defect was in the **timing
of the read**, not in the formula.

**Cause (2).** `tile.road_capacity_short` is recomputed on the production tick,
and after a road upgrade it is reset on the nearest tick. But the map is drawn **on
demand**: `map_renderer._draw` runs only after `queue_redraw()`, and that
is triggered by input (mouse/scroll) and explicit actions. The tick reset the flag but did not request
a redraw — and the triangle hung on the screen until the nearest mouse movement.

**What was done.** Intake and shipping are separated: `delivery_manager.advance(delta)` —
every frame (the transit countdown), `delivery_manager.ship()` — one step per tick,
and it is called **right after the tick's production and before `do_tick()`**. Now the interface
reads the already-shipped state: the queue shows only a real jam.
Inside `_ship_route`, the accumulator's remainder is now truncated to the fractional part
(`fmod`), not to 1.0: a route does not "accumulate" unused flow and does not splash
it out later. For the second defect, the tick remembers whether the overload flag changed, and if
it did — it calls `map_renderer.queue_redraw()` itself.

**Rejected.** (1) Reordering `update` so that the panel reads after shipping —
the panel reads inside the tick (`do_tick`), and production always runs before `do_tick`;
the only way is to ship between them. (2) Its own shipping timer, independent
of the tick — again a desync with the interface. (3) Simply redrawing the map every
frame — abandoning "draw on demand" and adding extra load for the sake of one icon.

**Test.** `tests/test_delivery_logistics.gd`, a new case `queue_only_backlog`:
when production is not above the flow, the queue that the interface reads on the
`city_updated` signal must be empty; when production is above the flow — it must grow. The snapshot
is taken EXACTLY in the signal handler — otherwise the test would see the already-shipped
state. Validation by mutation: moving `ship()` after `do_tick()` fails the case
("got 1"). `tests/test_road_capacity.gd` was extended with a redraw check via
the draw counter `map_renderer.draw_calls` (edge auto-scroll is disabled,
otherwise the map is redrawn every frame): a tick with a flag change must redraw
the map, a tick without a change — must not. Validation by mutation: without `queue_redraw()` the test fails.
Intake in the logistics tests now goes through `_step` = `advance` + `ship` (the same
order as in `_process`).

## `produces` is the rate: `production_interval` removed (October 11, 2026)

**Context.** Every improvement carried a `production_interval` (the field in
`data/improvements.json`): the time in seconds of one production cycle, mostly 2, for
the tar pit and the soda quarry — 3. The actual speed was `produces / production_interval`:
limestone with `produces: { "limestone": 10 }` on a quarry (interval 2) gave 5 units/sec,
not 10. The player sees only the per-second speed, so the field was an implementation
detail — but it also silently halved (or thirded) every number written in the data.

**Decision.** The field is gone. `produces` is now the rate itself: units per second.
Limestone gives 10 units/sec. The feed of the pastures is bound to the same mechanic and
changes with it: `feed_consumption` is now the feed rate per second too (the code no
longer divides it by the interval). Because the output and the feed were divided by the
same interval, their RATIO is unchanged — what changes is only the absolute throughput
(everything is now `interval` times faster than the player used to get).

**What we deliberately do not do.** We do not keep the field "for the future" as a
formal stub on the infrastructure improvements (a harbor, a canal): a field that nothing
reads is a trap for the next session. We do not rebalance `produces` to preserve the old
per-second speed — the whole point is that the data number is the speed. We do not touch
the `interval` of the professions and of the building recipes (`data/consumption.json`,
`time` in `data/crafts/*.json`): those are a different, still-alive mechanic; only the
improvement cycle is removed. In the planned-production maps an improvement record now
carries `interval = 0`, which the UI already reads as "per tick" (tick = 1 sec = per
second), so the plan shows the rate directly.

**Note on the old entry.** "Production lines: speed per second only" (October 9, 2026)
rejected option (2) — "show the data number (10) as the speed" — because 10 did not match
what actually arrived at storage. The resolution here is the other half of that choice:
the data is changed so that 10 IS what arrives, and then showing 10 is correct.


## The food dynamics of the population: the pool ration counted once, and the famine that killed the newborn (October 11, 2026)

**Context.** With two citizens the top bar read "Food: 0 [+10≈ / -320≈]", and the second
citizen died on the tick its birth emptied the warehouse. The number is not a deficit: the
population eats `(population - 1) × food_per_citizen = 10` units per second, and the city
produces enough. Two separate defects sat behind the report.

**Defect 1 — the display multiplied the ration by the number of the foods.** The plan of the
consumption writes the population ration under EVERY product of the food pool, because the pool
is shared: any of the products can satisfy the demand, and each row of the tab shows the full
amount — the same convention the `@`-groups follow. `city_ui._planned_food_per_sec` then summed
the plan over the whole pool, so the ration was counted once per food: 32 foods × 10 = 320.

**Defect 2 — the famine could not see the food delivered along a road.** The goods of a
road-connected improvement are credited to `production_rates` on ARRIVAL
(`delivery_manager._deliver`), and `advance()` runs per frame BEFORE the tick block. The tick
then calls `reset_counters()`, which clears the counter — so by the time
`_check_population_change()` runs, the whole window of arrivals is already gone and the city
reads as one that produces no food at all. With the warehouse emptied by the birth, the
population eats the last of it (`total_cons = 10`), the check sees `total_prod = 0` and kills a
resident. A city fed through a road starves while it is feeding itself.

**What was done.** The ration entry is now flagged in the plan (`is_population`, the flag already
existed) and `_planned_food_per_sec` counts it ONCE — any product of the pool can satisfy it, so
summing it per product is meaningless. The famine falls back to the planned output
(`CityData._planned_food_production_per_sec`, the same reduction over the planned maps) whenever
the actual production of the tick is zero. The fallback is not a new idea: the top bar already
does exactly this for its own reason (the cyclic consumption and the "blind windows" between the
ticks), and reusing it makes the LABEL and the FATE of the citizen agree — the player can no
longer see a positive dynamics and lose a resident to it.

**Rejected.** (1) Recording the production of a road-connected improvement at the moment it is
produced instead of at the arrival — `_deliver` deliberately attributes the source at the arrival,
because that is when the goods reach the city, and the treasury breakdown reads the same records.
(2) Moving `reset_counters()` to the end of the tick block, so the arrivals of the window survive
to the check — that empties the planned caches between the ticks, and the tab "Resources" reads
them outside the tick. (3) Not writing the ration into every food product at all — the per-row
display would lose the source that explains the expense of the pool.

**Test.** `tests/test_food_population_dynamics.gd`: the planned expense of the pool must equal the
single ration (not the ration per food), a city whose production was wiped by the reset must not
lose a resident while the plan carries an output, and a city with no producer at all must still
lose exactly one. Validation by mutation: without the two fixes the test fails on "got 320" and
on "must not starve". Reproduced end-to-end on a live map as well: a farm with no road survives, a
farm behind a road used to drop the population from 2 to 1 on the tick the warehouse was emptied.


## The byproduct that starved the staple: the route flow is per product (October 11, 2026)

**Context.** The report: three lentil farms stand within a second of the city, the top bar reads
"Food: 0 [+40≈ / -15≈]", and the population sits at 3 and never grows. The food arithmetic looked
positive, so the growth threshold (1000 banked) was not the whole story.

**Root cause — the byproduct flooded the route.** A food plant outputs a STAPLE AND A BYPRODUCT on
the same hex (`data/resources/plants/food_plants.json`: `produces: { lentils: 10, feed: 60 }`).
Both entered ONE route queue, and `delivery_manager._ship_route` shipped them from a single shared
FIFO at the route's `avg_speed` (a trail = 10 units/sec) — the TOTAL of the route, not per product.
The 60/sec of fodder therefore occupied ~86% of the pipe and the 10/sec of food was almost never at
the head of the queue. The city received almost no food: the pool stayed at 0, the fodder piled up
(30 210 in the report), and the population froze at 3 — no growth (nothing banked) and no famine
either, because `_check_population_change` falls back to the PLANNED output (40 > 20). The top bar's
"+40≈" was that same planned number, never what arrived.

**What was done.** The route's flow rate is now the throughput of EVERY product it carries.
`delivery_manager._ship_route` grants each product waiting on the route its own budget for the step
(`ship_accum` became a per-product dictionary), and `_dispatch` walks the queue taking each
product's share — the order stays FIFO WITHIN a product. This is the per-product reading the
overload marker already made (`map_tooltip.road_capacity_shortfall`, which compares each product
against the route speed separately), so the marker, the triangle and the delivery now agree; the
old shared FIFO contradicted them.

**Rejected.** (1) Rebalancing the data instead (lowering the farms' fodder output): the fodder is a
legitimate routed product — a pasture eats `feed` from the city storage — and ANY dominant byproduct
would starve its staple the same way. (2) Making the top bar and the famine read the delivered rate
without touching delivery: that would kill residents for a road problem the player can fix by
upgrading, and it would leave the surplus arriving nowhere.

**Test.** `tests/test_delivery_logistics.gd`, case `multi_product_share`: a staple (10/step) and a
byproduct (60/step) on one route with a flow of 10 — the staple must keep arriving at its own rate
(100 over 10 steps) while the byproduct queues. Validation by mutation: with the shared FIFO the
staple receives 10 instead of 100. Reproduced end-to-end on a live map: three lentil farms behind
trails gave food 0 / fodder 5 115 / population stuck at 3 before, and food climbing ~+10/sec with
the population 3 → 4 after.


## The "Foreign trade" column: two sections, sorting, and the discovered towns (October 12, 2026)

**Context.** The right column of the "Trade" tab had been a heading and nothing else since the
column split. The request: give it two section buttons in a horizontal row (small, square, with an
icon and a tooltip, like the city tab-switch buttons) — "Trade deals" and "Trade partners"; sort
the deals by resource name, by price and by type (purchase/sale); sort the partners by town name
and by distance; fill the partner section with the towns the player has discovered (the towns open
for trade), each with a small button that closes the city interface and centers the map on the
town. The trade itself is not implemented, so the deals section is prepared, not populated.

**What was done.** The column lives in a new `scripts/external_trade_tab.gd`, the markup in
`scenes/CityUI.tscn` under `ContentPanel/TradePanel/Split/ExternalPanel` (the node name is kept —
the tests and `city_ui` refer to it).

The two sections switch by **panel visibility** (`DealsSection` / `PartnersSection`), not by a
`TabContainer`: the manual pattern of `city_ui._switch_tab` keeps the column a plain `VBoxContainer`
chain and lets the switch buttons sit in the header instead of a tab strip. Both list scrolls are
`vertical_scroll_mode = SHOW_ALWAYS` — the same anti-"breathing" fix as in the domestic column, so a
row's width does not depend on whether the scrollbar is currently needed. The section buttons
(36×34) and the sort buttons (28×28) carry an icon and a tooltip; the active section/key is
highlighted with a light-grey stylebox and a black font.

The highlight was **extracted** into `ui_helpers.highlight_toggle_button(button, active)`: it had
been local to `city_ui._highlight_active_tab_button`, and the column would have been its third
copy. The city tabs now call the same helper.

**The deals are a documented stub.** `_collect_deals()` returns an empty array on purpose, with the
row shape it will produce written next to it in a comment (`town_id, town_name, product_id, name,
icon, type, price`); `_build_deal_row` already renders the full row (icon, name, town, type — the
purchase in the expense colour, the sale in the income colour — and the price), and an empty source
shows "No trade deals yet". When the trade appears, only the body of `_collect_deals` changes: the
sorting, the rows and the empty state already read from it. The type order is the constant
`buy = 0, sell = 1` rather than a comparison of the translated names — the order must not change
with the language. Every sort is stable by name as a secondary key.

**The partners are the discovered towns.** `main_map.get_trade_partners()` reads
`town_manager.get_discovered_towns(tile_data)`; a town is discovered when its tile is
`in_influence` or `is_explored` — the same rule the town production and the town rendering already
used, so `is_town_discovered` was extracted from `_is_town_production_started` and both call it. A
row is a border-colour swatch, the town name, the distance in hexes (`HexUtils.hex_distance`) and
the goto button.

A town **without a road stays in the list**, with a dimmed `road.svg` marker and the tooltip "Trade
unavailable: there is no road from the city to this town". The discovery opens the town, the road
opens the trade (`is_trade_available`) — hiding a discovered town over a missing road would leave
the player without an explanation of why the trade is not there.

**The goto button and the camera.** The button emits `town_focus_requested(row, col)`; the chain is
`external_trade_tab` → `city_ui` (re-emits) → `main_map._on_town_focus_requested`, which closes the
city and centers the map. The column knows nothing about the camera and the map knows nothing about
the list. `main_map.center_on_hex(row, col)` is the extracted scrolling formula (the
`scroll_offset` computation, clamped by `get_max_scroll()`, plus the redraw of the renderer, the
scroll layer and the progress bar) — it replaced the inline right-click branch of
`_on_city_button_gui_input`, so the right-click centering and the goto button cannot drift apart.

**Updates** are signature-based, as in the domestic column: `_deals_signature_of` includes the sort
key, the direction and every field of a row; `_partners_signature_of` is deliberately reduced to
the town id and the road state, because the name and the distance of a discovered town cannot
change. A rebuild therefore happens only on a real change of composition, and an open tooltip and
the scroll position survive. The tooltips and labels (including those of the sort and switch
buttons) are refreshed in `refresh()`, which also makes them follow a language change —
`city_ui.refresh()` runs on `_on_locale_changed` — so the column needs no
`NOTIFICATION_TRANSLATION_CHANGED` handling of its own.

**Icons.** Five flat 32×32 SVGs were added to `icons/` (`sort_name`, `sort_price`, `sort_type`,
`sort_distance`, `goto`): the repository had only 64×64 painterly game icons, and the sort bar
needs small flat glyphs. They go through the `IconRegistry` like every other icon; the import and
the rendering were verified on this project before relying on them.

**Rejected.** (1) A `TabContainer` for the two sections: it would break the column's
`VBoxContainer` chain and put the switch buttons in a tab strip rather than in the header.
(2) Hiding the towns without a road: the road gates the trade, not the discovery, and the list is
exactly what the section promises — "the towns the player has discovered". (3) Sorting the deal
type by the translated names: the order would flip with the language. (4) Rebuilding the partner
list on every era tick: the signature check keeps an open tooltip and the scroll alive.

**Test.** `tests/test_trade_tab.gd::_check_external_trade` on a live `MainMap.tscn`: the section
buttons (icon, tooltip, ≥28 px), the exclusive switch, both scrolls `SHOW_ALWAYS`; the sort bars
(3 deals / 2 partners) with icons and tooltips after `refresh()`; the click semantics (a new key →
ascending, a repeated click → descending); the deals sorting through `tab._sorted_deals(...)` on a
synthetic array (price asc `Ale, Mead, Wine, Beer`; type asc — purchases first: `Ale, Beer, Wine,
Mead`); the empty source → the empty state, and `_fill_deals` → one row per deal; the partners: the
undiscovered towns cleared → an empty list, then three opened towns → exactly three rows sorted by
name, with `get_trade_partners()` matching `HexUtils.hex_distance`; the distance sorting asc/desc
through the rendered rows; the number of road markers equal to the number of towns without
`trade_available`; `center_on_hex` on the centre of a Region within 2 px of the screen centre; and
the goto button: exactly one request with that town's row/col, `city_ui` closed, `scroll_offset`
changed and the town closer to the centre. Full suite: 47/47.

## The town window: centering, interactive rows, and the trade settings foundation (October 12, 2026)

**Context.** The town window (`scenes/TownUI.tscn`, `scripts/town_ui.gd`) showed two static
resource columns and nothing else. The request: center the window; make the buy/sell rows
interactive (hover + click highlight); add the trade parameters — a manual amount field, "±"
buttons (tens by default, units with Ctrl, hundreds with Shift, the rule in the button tooltips), a
"Permanent" checkbox (off by default, a one-time deal → a standing contract), a warning triangle
when the amount exceeds the throughput of the route from the town to the city (with the shortfall
in its tooltip), whole-positive-integer input only, and confirm/cancel. The trade itself is still
not implemented: only its foundation.

**Where the trade settings live (the design question).** Two options were on the table: a separate
small floating window over the map, or an inline mini-panel inserted into the column under the
selected row. The **inline panel** was chosen. The town window is about comparing many rows (what is
cheap here, what the town lacks), so a second floating window would cover the very list the player
is deciding from and would need its own z-order and centering. The inline panel keeps the context:
the selected row stays highlighted, its stock and stars stay visible above the settings, and the
rest of the column scrolls as before. Only one panel is open at a time; a click on another row
moves it, a repeated click closes it.

**Centering (done in code, not with anchors).** The first attempt anchored the panel to the centre
of a full-rect root `Control` — and the window flew off the top-left corner of the screen. The
reason: the town interface is a child of `MainMap`, which is a **`Node2D`**, and a `Control` whose
parent is not a `Control` anchors against `parent_canvas_item->get_anchorable_rect()`, which for a
`Node2D` is a **zero-sized rect**. The centre anchor therefore resolved to (0,0) and the panel landed
at minus half its size, i.e. off-screen. (This is also why every panel of `CityUI` is positioned by
absolute offsets: anchors are useless in this hierarchy.) So the window is centered in
`town_ui._center_window()` from `get_viewport_rect().size`, clamped to zero so the top-left corner
stays reachable on a viewport smaller than the window; it runs in `_ready`, on `open_town` and on
`Viewport.size_changed`. The `WindowPanel` keeps `clip_contents`, so a long list still cannot spill
onto the map.

**Interactive rows.** A row is now a `PanelContainer` with a stylebox that carries three states —
transparent normal, light hover, a stronger blue "selected" — instead of a bare `HBoxContainer`. The
row and the quality-stars label are wired to the same hover/click handlers (the stars keep their own
tooltip and `MOUSE_FILTER_STOP`, as `test_town_economy` requires), so hovering the stars highlights
the row too and they are not a dead zone. The name of a row is stored in its metadata
(`town_resource_row`, `town_row_key`, `town_row_name`), which is how the trade panel finds its row
and how the test reads the column back.

**The amount field and the steps.** The field is a `LineEdit` whose `text_changed` handler keeps
digits only and strips the leading zeros (so a paste is filtered as well and the field never shows
"007" or a lone "0"); the length is capped. The "±" buttons change the amount by 10 by default, by 1
with Ctrl and by 100 with Shift — the step is a pure `_amount_step(ctrl, shift)` (Ctrl wins when both
are held), the modifiers are read at the click, and the whole rule is written in the button
tooltips. The amount never falls below 1, and confirm is disabled while the field is empty.

**The route-capacity warning.** A new `scripts/warning_badge.gd` draws the same red "!" triangle the
map already draws over an over-producing improvement
(`map_renderer._draw_warning_triangle`) — with the engine fallback font and no icon asset, so the
warning looks the same on the map and in the window. The window reads the throughput from
`main_map.get_route_to_city(town_row, town_col)` → `avg_speed` (the same number `control_panel`
shows as "average N units/sec"). The badge appears when the amount is strictly above it; a town
without a road has no route, the capacity is taken as zero, and any amount warns (the status row
already explains the missing road).

**The foundation, not the trade.** Confirm assembles an order — `town_id`, `town_name`, `row`,
`col`, `side` ("buy"/"sell"), `product_id`, `product_name`, `amount`, `permanent`,
`route_capacity` — and hands it over by the new signal `trade_order_submitted`. `main_map` connects
it to `_on_town_trade_order`, a documented no-op stub that is the single place the real mechanics
will be attached to (the same pattern as `town_manager.is_trade_available` and
`external_trade_tab._collect_deals`). Nothing is spent or moved; the panel reports that the trade is
not implemented yet.

**Localization.** The new strings were added to the catalog with the project's own toolchain
(`python tools/i18n_build_po.py`, then the Russian msgstrs, then `python tools/i18n_compile_mo.py`):
`locale/ru.po` has 0 untranslated entries and `tools/i18n_check_po.py` reports the catalog in order.

**Rejected.** (1) A separate floating settings window: it would cover the list being compared.
(2) Turning the whole row into a `Button`: the quality stars must keep their own tooltip, and a
`Button` child would have swallowed the hover of the stars (a dead zone). (3) A drawn-from-scratch
warning glyph or a `⚠` label: the map already has a triangle, and reusing its shape keeps the two
readings identical without a new asset. (4) Computing the route capacity in the window from the road
data: `get_route_to_city` is the single source the rest of the UI already uses.

**Test.** `tests/test_town_trade_ui.gd` (fast, no map generation — the route is stubbed with an
inner class): the window centered within 1 px and fitting the viewport; the rows are mouse-catching
and marked, hover changes and restores the background, hovering the stars highlights the row, a
click selects it (the selected background) and opens the panel exactly at `row index + 1`, a
repeated click closes it; the panel's field/buttons/checkbox (Permanent off by default)/tooltips;
the input sanitizer (letters, signs, fractions, leading zeros), the steps 10/1/100 (Ctrl wins), the
amount floor at 1 and the disabled confirm; the capacity rule (`_exceeds_capacity` — strictly
above) and the badge visibility and tooltip across no-route / within / at-limit / above; and the
assembled order's fields plus the "not implemented" note. Full suite: 24/24 fast, plus
`test_town_economy`, `test_road_building`, `test_town_roads`, `test_town_priorities`.

## The town trade panel: four corrections after the first showing (October 12, 2026)

**Context.** The first version of the trade panel was shown and four things were wrong at once. All
four are in `scripts/town_ui.gd`, in `_build_trade_panel()` and its new helpers; the scene was not
touched.

**1. The heading "Selling: Wood" is gone.** The panel sits directly under the row it belongs to, and
that row is highlighted, so the side and the name were already read from it. The heading only
repeated the highlighted row and took a line off a panel that is already five controls tall.
`_side_label()` had no other caller and was removed with it.

**2. "Dark on dark" controls.** The window and the panel are dark (`0.11`), and the default theme
draws a `Button`/`CheckBox` in a dark grey with a frame of almost the same value — the controls read
as dark blobs and the player cannot see where a button ends and the panel begins. Every control of
the panel now gets an explicit `StyleBoxFlat` with a **light** frame: `CONTROL_BG_COLOR` (0.20) /
`CONTROL_BORDER_COLOR` (0.62) for the normal state, a lighter fill on hover, a darker one pressed,
and a dimmed frame when disabled (so "confirm cannot be pressed" is visible and not only felt). The
amount field is styled with the same frame — it stands in the same row between two buttons and
without a frame it would read as a hole in the panel. The three helpers (`_style_panel_button`,
`_style_check_box`, `_style_amount_field`) all go through one `_make_control_style(bg, border)`, so
the four states of the four controls cannot drift apart.

**3. The contract tooltip is scoped to the box.** A `CheckBox` with a `text` shows its
`tooltip_text` over the box AND over the caption, and the caption was most of the row. The box is
therefore left **textless** (it is the only thing carrying the tooltip) and the caption became a
`Label` of its own, named `PermanentLabel`. The caption stays clickable — `gui_input` toggles the box
— but it deliberately carries no tooltip of its own, and no ancestor of it does either, so Godot's
tooltip lookup (which walks up the parents when the hovered control has none) finds nothing.

**4. Confirm/cancel are square icon buttons.** They are 36×36 `Button`s with `icon` =
`IconRegistry.get_texture("check.svg" / "cross.svg")`, `expand_icon` and a centred icon, and **no
text at all** — the same look as the "Start"/"Cancel" pair of the preview panel
(`control_panel._show_preview_header`). The words "Confirm"/"Cancel" moved into the tooltips. As in
the control panel, a missing icon file falls back to a glyph ("✓"/"✕") so the button is never blank.
The row is right-aligned (`BoxContainer.ALIGNMENT_END`).

**Localization.** No new msgids: every string reused an existing catalog entry ("Confirm", "Cancel",
"Permanent", "Amount:", the checkbox tooltip). Rebuilding the catalogs produced a byte-identical
`ru.po`/`ru.mo` (`tools/i18n_check_po.py`: 0 untranslated, 0 Cyrillic, 0 duplicates).

**Test.** `tests/test_town_trade_ui.gd`, case `panel`, was extended: no heading label of the kind
`"<side>: <name>"` anywhere in the panel; the checkbox is textless and carries the tooltip while a
`PermanentLabel` exists with an empty tooltip; both icon buttons are square, textless, carry an icon
and a tooltip; and a `_check_visible_frame` helper asserts a border on all four sides with a
luminance above 0.4 (a light frame against the dark panel) on the two buttons, the checkbox and the
amount field. Full suite: 24/24 fast, plus `test_town_economy`, `test_road_building`,
`test_town_roads`, `test_town_priorities`.

## The town trade: the road gates the settings, and the money is on the screen (October 12, 2026)

**Context.** Three more findings after the second showing of the town window: (1) the trade settings
panel must not open at all while the trade with the town is unavailable (no road); (2) a resource row
must show the price of ONE unit, to the right of the name; (3) the panel must show the sum of the
order in the free space left of the confirm/cancel buttons, and that sum must follow the amount in
real time. All three live in `scripts/town_ui.gd` (plus one comment in `main_map`); the scene was not
touched.

**1. The road gates the settings, not the window.** `_can_trade()` is now the single question, and
three places ask it. `_build_resource_row` does not wire an inert row at all — no hover, no click —
and dims it (`ROW_DISABLED_MODULATE`, 0.62), so the pool is still READ but reads as information, the
same "the discovery opens the town, the road opens the trade" line the "Foreign trade" column already
follows. `_toggle_selection` and `_open_trade_panel` check the flag again: the rows are simply not
wired, but a guard in the two entry points means no caller (a test, a future button, a scripted
refresh) can open the settings of a town without a road. The status row under the name still explains
why. `main_map.open_town_ui`'s comment said the availability is passed "by the status, and not by a
blocking" — that is now the opposite of the truth and was rewritten.

**2. The price of a unit.** `_unit_price(resource_id, side)` = `GameData.get_price_for_quality(...)`:
the current market price (base × the dynamic market multipliers — the same number the "Trade" tab
works with) times the quality multiplier of the level the row shows. The `side` argument is what
decides whether there IS a quality: the SALE column holds the goods the town itself has and its stars
name that level, so the price carries exactly that multiplier; the PURCHASE column is about the goods
the town LACKS — the quality of what the city will deliver is not known at the row and the row has no
stars — so the plain market price is shown (`_town_quality_of` returns "" and the multiplier is 1.0).
The first version of the function keyed the quality off the id alone and would have applied the town's
quality to a purchase row as well, which is exactly the "the price and the stars of one row cannot
tell different stories" rule broken. The label is gold (`UiHelpers.PRICE_TEXT_COLOR`, shared with the
"Trade" tab), fixed-width (`PRICE_COLUMN_WIDTH`) so the prices line up in a column, and it keeps a
tooltip — a bare number does not say it is the price of a single unit.

**3. The live total.** The panel's button row got a `TotalLabel` that EXPANDS: that is what pushes the
two icon buttons to the right edge (the old `ALIGNMENT_END` became redundant). The text is
recomputed in `_update_total_label`, called from `_update_amount_feedback` — and both the field and the
`+`/`−` buttons already go through that, so the sum follows the typing and the buttons with no extra
plumbing. The direction is read from the side: the sale column is what the TOWN sells, so the city
PAYS (`Cost: %d`, red); the purchase column is what the town buys, so the city IS PAID (`Income: %d`,
gold) — the same pair of colours `external_trade_tab` paints its deal rows with.

**The price is live, so the total is too.** The market multipliers move, so the price of a row is
rewritten in place on every town tick — `refresh_storage` (which already refreshed the stock and the
stars) now also walks `_price_labels` and re-runs `_update_total_label` for the open order. The new
map is keyed by the row key and holds `{label, id, side}`, and it is cleared once per rebuild in
`_refresh`, NOT per column: both columns have prices, and `_fill_resource_list` runs twice (buy, then
sell), so clearing inside it would have wiped the purchase prices.

**Localization.** Three new msgids: `Cost: %d` → "Стоимость: %d", `Income: %d` → "Доход: %d",
`Price per unit: %d coins` → "Цена за единицу: %d монет" (the wording follows the existing "Cost:",
"Income:" and "%d монет" entries). `i18n_check_po.py`: 0 untranslated, 0 Cyrillic, 0 duplicates.

**Test.** `tests/test_town_trade_ui.gd` gained three cases. `no_trade`: the rows are listed but dimmed
and do not react to hover, a click selects nothing and opens nothing, and a DIRECT call to
`_open_trade_panel` / `_toggle_selection` is a no-op; the same town opened with a road becomes
interactive again. `price`: the sale row shows the market price with the town's quality multiplier,
the purchase row the plain market price, the tooltip names the number, and hovering the price
highlights the row. `total`: the label sits first in the row with the buttons and expands, and the
text follows `_set_amount`, the `+`/`−` buttons and the typing (`Cost: …` for the sale column,
`Income: …` for the purchase one, `Cost: 0` for an empty field). The test also loads the game data
itself (`_gdata.load_all_data()` when `data_loaded` is false) — in a `--script` run nothing loads it,
the watchdog only RELOADS it once it is loaded. Full suite: 48/48 (`--all`).

## The HUD stays visible while the town window is open (October 12, 2026)

**Context.** The user asked to keep the HUD on screen when the town interface is open: the player
must see the treasury amount while trading. All HUD buttons must be inactive.

**Implementation.** `main_map.gd`:
- `_process` now computes `hud_blocked := is_paused or town_ui.visible` and disables
  `research_button`, `city_button` and `expansion_button` when it is true. The HUD itself is NOT
  hidden — its labels (population, year, treasury) stay readable.
- `open_town_ui` no longer calls `hud.hide()`; `_on_town_ui_close` no longer calls `hud.show()`.
  The control panel is still hidden/shown as before.
- The HUD is drawn AFTER the town window in the scene tree (`MainMap.tscn`), so it renders on top
  and is never covered by the town panel.

**Test.** Fast suite 24/24 PASS; town tests (`town_economy`, `road_building`, `town_roads`,
`town_priorities`, `town_trade_ui`) PASS.

## The standing contract shows its cost per second (October 12, 2026)

**Context.** The user asked: when the "Permanent" checkbox is on, the total of the order must be
shown per second — `Cost: X/sec` or `Income: X/sec` — because a standing contract charges or pays
every tick. The amount field already shows the number of units per tick, so the total must match
that rhythm.

**Implementation.** `_update_total_label` now branches on the state of the checkbox: when it is
pressed, the format string carries `/sec` (`Cost: %d/sec` / `Income: %d/sec`). The checkbox is
wired to `_on_permanent_toggled`, which stores the state in `_panel_permanent` and rewrites the
total immediately — so the label switches the moment the box is checked or unchecked.

`_panel_permanent` is also restored when the panel is rebuilt on a `_refresh` (a town tick or an
era change): without this, the flag would be lost every second while the window stays open. A new
resource selection resets it to `false` — each fresh row starts with a one-time deal, which is the
safer default.

**Localization.** Two new msgids: `Cost: %d/sec` → "Стоимость: %d/сек", `Income: %d/sec` →
"Доход: %d/сек". `i18n_check_po.py` → 0 untranslated.

**Test.** `tests/test_town_trade_ui.gd`, case `total`, was extended: toggling the checkbox to
permanent appends `/sec` to the total; toggling back reverts to the plain format; switching to
the buy column and toggling there shows `Income: …/sec`. Full suite: 24/24 fast, plus the four
slow town tests, all PASS.

## The town trade: a term sheet, not a market subscription (October 12, 2026)

**Context.** The town window had been "*prepared for trade*" for two sessions: rows, a trade panel, the
order assembled and handed over by a signal to a documented no-op. The task was the first real stage —
the city buys from a town, once or on a standing contract — and the design question that arrived with it
was not "how to move the numbers" but **what a contract is**.

**Decision: the unit price is frozen at signing.** The row of the trade panel shows the live market price
times the quality multiplier, and that number travels inside the order. The contract stores it and charges
`amount × unit_price` every tick, forever, without ever re-reading the market.

The alternative — a live subscription that re-prices every tick — is tempting, because the market
multipliers already move on their own. It was rejected for one reason: the "Trade deals" section of the
"Trade" tab shows the **cost** of a contract as a number, and the HUD shows the money actually leaving the
treasury. With a live price those two numbers would drift apart within a few seconds, every era tick, with
nothing on screen to explain it — the player would read it as a bug. With a frozen price the row is a term
sheet: the deal the player signed is the deal that runs, and a town that raises its price cannot make an
old contract more expensive.

**Decision: a contract is not a debt.** Every tick, before anything is charged, the town is re-found by id,
the stock is re-read and the treasury is re-counted. If the town is gone, has run out of the good, or the
city cannot pay — the contract is **torn**, the failed tick is settled by nobody, and the player is told
why in the HUD. There is no arrears bookkeeping anywhere in the project, deliberately: the alternative
would be a negative balance on the city with a penalty rate, an interest model and a recovery order — a
credit subsystem the design does not want, to make a deal the player cannot be forced into. Neither side
can be forced, so nothing is owed.

**Decision: the goods take the ordinary road.** A purchase does not "materialise" at the warehouse: the
coins move first, then the units are queued on the route from the town through the same
`create_cargo` the production of an improvement uses. The road limits a deal exactly like it limits
production, and that is the point — a 60-per-second contract over a 30-per-second trail queues, and the
"!" triangle of the trade panel already warned the player about it before confirming. The contract tick
runs inside the simulation block **before** `ship()`, so one tick of a deal ships on the same step as the
production of the same tick. There is no separate clock for trade.

The one exception is a route that does not exist at all — then the goods land at once, because a road that
is not there cannot limit anything. That is the same fallback `_deliver_production` uses for an improvement
on a hex without a road; the "no limit" rule does not care who the goods belong to.

**What we deliberately do not do.** The city **selling** to a town is not implemented, and the order of
that side returns an explicit message instead of doing nothing silently. Silently dropping a sale would
leave the player clicking a confirm button that does nothing — worse than a sentence that names what is
missing. The seam is the `side == "sell"` branch of one function, and the second stage attaches there.

A town does not spend what it earns: the coins simply accumulate in its treasury. A town has no purchases
of its own yet, so "money in, money never out" is honest today and needs no ledger — when the city starts
selling, the town's spends get their own bookkeeping, in the same place.

A one-time purchase leaves nothing to list. The "Trade deals" section shows the standing contracts and
only them: a one-time deal is over the moment it is confirmed, and a row that disappears by itself on the
next tick would read as a rendering bug. The delivery time of a row is read from the **live** route
(`get_route_status`), so a road that got longer or faster changes the number on a contract that is already
running — the one field of a deal that is deliberately not frozen, because it is not a term of the deal,
only the distance the goods currently travel.

## The dynamics of the row reads the plan, so a contract must enter the plan (October 12, 2026)

**Context.** The town trade was working: a contract charged the treasury, wrote the goods off the town and
queued them on the road. The player reported that the bought good still showed `+0` in the dynamics of the
tab "Resources" — the storage was growing, the label denied it. Nothing was broken in the delivery: the
goods really arrived.

**The cause is a convention, not a bug in the trade.** The green label of a resource row
(`resources_tab._format_prod_label`) reads **`CityData.get_planned_production_map()` only**. The actual
per-tick `production_rates` is deliberately not part of that label — it is what the famine check and the
top bar read. The plan is assembled from three per-second caches, and the town contracts were in none of
them: a contract was a *fact* of the delivery and never a *promise* of the city, so the row had nothing to
show.

**Decision: a standing contract is a promise, so it goes into the plan.**
`CityData.town_planned_production` (`record_planned_town_production`, source `SRC_TOWN_TRADE`) is merged
into the plan by the same rule as the improvements (`_merge_planned_cache`), with `interval = 0` — a
contract is a continuous per-second rate, exactly like a working improvement, and the label reads it as
`[+N≈`.

The obvious alternative was to make the label fall back to the actual `production_rates` when the plan is
empty. It was rejected because the two numbers have different lifetimes: `production_rates` is cleared by
`reset_counters()` on every tick, while the arrivals are credited by `delivery_manager.advance()` on
arbitrary **frames**. A road that delivers every tick would therefore still show `+0` on most redraws and
`+2N` on the others, depending on where the display interval happened to fall — a jitter with no meaning.
The plan is the number that does not flicker, and the "≈" marker already tells the player that it is a
promise and not a fact. Making the label read the fact would have deleted the distinction the whole tab is
built on.

**The record is written after the teardown sweep.** `tick_contracts()` tears a contract that cannot be paid
or fulfilled *before* it records the plan, so a dead contract never promises goods the city will not
receive. The cache lives exactly one tick (`reset_counters()`, `setup()`), the same lifetime as the plan of
the improvements, so a contract that is gone simply stops being counted on the next tick.

**A one-time purchase stays out of the plan.** It is a single delivery, not a rate: writing it into a
per-second map would either show a phantom inflow for one tick or, worse, be read as a rate and promise the
same delivery every second. The row of a one-time purchase shows its goods through the storage, which is
what actually grew.

**What this does not do.** The plan does not make the row appear from nothing: `refresh()` walks
`city_storage`, so a good that the city has never held still needs its first arrival to get a row. That is
the pre-existing rule for improvements as well, and it is honest — the plan of a row the player has never
seen would be a row appearing out of nowhere. For the reported case the good was already in storage; only
its dynamics was missing.
