# The City — Design document

**Version:** 2026-08-21  
**Repository:** https://github.com/Night-Pryanik/The-City  
**Engine:** Godot (GDScript)  
**Purpose of the document:** a canonical description of the game for continuing development (including by a new assistant) without reading the whole chat history. The code and JSON in the repository are the source of truth for the implementation; this file is the source of truth for the *intent*.

---

## 1. High concept

**The City** is an economic-resource simulator of the development of **a single city** on a hex map across several historical eras.

The player does not micromanage individual residents and does not draw a street grid in the spirit of Cities: Skylines. **The city is the main character:** it extracts, processes, researches, expands and trades. Residents are "cogs" (workers/slots), not characters.

### Fantasy

> Grow a city that *remembers* what it used to be: from the first farms to a recognisable producer (cheese, glass, porcelain…), on a landscape with rivers, lakes, seas and unique terrain types.

### Genre references

- Closer to: **Anno** (chains), a soft **map-level 4X** (expansion, technologies), a resource-economy sim.  
- Further from: a classic street-level city-builder (C:S), a combat 4X, an RPG.

The author's old notes (2014–2019) described a more "urban-planning" variant (roads, housing, transport, taxes). The current direction is **deliberately** shifted towards the economy and the landscape. Urban-planning elements are acceptable only if they reinforce this fantasy rather than requiring a second game on top of the first.

---

## Worldview and Historical Context

### 1. The World of The City

The City is an economic strategy game about the development of human civilization as a whole. Its world is built around an intentionally alternate geography, an alternate historical context, and a flexible cultural identity.

The game does not represent any particular real-world geographical region or civilization. It is neither a simulation of Europe nor a reconstruction of the Mediterranean, the Middle East, or any other specific part of the world. There are no direct equivalents of real-world historical or geographical regions on the game map.

Most importantly, **Europe is not the historical, geographical, or cultural center of The City**. European history is one source of historical knowledge among many, but it does not provide the universal framework through which the game's world is understood.

The project does not depict the story of European civilization gradually discovering, adopting, and incorporating the achievements of other peoples. Instead, it explores the development of human society through a broader perspective in which different parts of the world, their knowledge, resources, and practices have equal historical significance.

This principle influences the game's geography, chronology, technology progression, resource availability, cultural references, and naming conventions.

### 2. Alternate Geography

The geographical setting of The City is deliberately independent of the actual arrangement of continents, ecosystems, and biogeographical regions on Earth.

Plants, animals, and natural resources originating in different parts of the real world may coexist within a single game map. For example, South American llamas may share their surroundings with Chinese ramie and tropical coconut palms.

Such combinations are a natural part of the game's setting rather than geographical inaccuracies within it. The map represents an alternate world with its own distribution of natural resources and environmental conditions.

Consequently, the presence of a particular resource in a region does not imply that the region corresponds to the real-world location from which that resource originated. Real-world geographical origins are useful for understanding the nature and properties of resources, but they do not define their mandatory placement in the game.

The game's geography is therefore best understood as a functional and ecological setting rather than a reconstruction of Earth. Climate, terrain, vegetation, and resource distribution provide the framework for economic development, while the specific combinations found in the world remain deliberately fictional.

### 3. Alternate History and the Development of Humanity

The historical context of The City is similarly alternate.

The game does not reproduce the actual chronological development of any particular civilization. It draws inspiration from the technological achievements, material culture, agricultural practices, and production methods of humanity across different periods and geographical regions.

Historical developments are considered in a broader context: discoveries, inventions, and practices are part of humanity's shared technological heritage, regardless of where they originated.

This perspective is particularly important for technologies and products whose history is associated with different regions at different times. The introduction of an item to Europe, for example, is not equivalent to its invention, origin, or first use. Many resources and practices were familiar to the populations of their places of origin long before they became known elsewhere.

The game does not treat the spread of knowledge toward Europe as the culmination of historical development. The histories of the Americas, Africa, Asia, and Oceania are independent and significant parts of humanity's technological and cultural history.

The resulting setting is not intended to be a precise historical simulation. It is an alternate representation of the development of human civilization, drawing on real-world achievements without being bound to their exact historical sequence.

### 4. Game Eras as a Technological Framework

The eras in The City are abstract stages of technological development. Their names are primarily chosen for familiarity and ease of recognition, rather than for strict correspondence with real-world historical periodization.

The boundaries and duration of game eras correlate only approximately with the actual historical eras whose names they use. In particular, the game's Ancient Era should not be interpreted as a direct representation of European Antiquity, nor should the game's Medieval Era be understood as a reconstruction of the European Middle Ages.

Different civilizations followed their own historical trajectories. Their periods of development, technological achievements, and cultural transformations did not necessarily coincide with European chronology. Many of these historical periods have no direct equivalent in conventional European periodization.

Game eras provide a shared framework for describing the approximate technological capabilities of humanity at different stages of the game. They are not intended to establish a universal historical calendar or to imply that all regions of the world followed the same sequence of events.

Within this framework, the availability of a resource, product, or production process is determined primarily by its technological feasibility at the corresponding level of development.

An item that was already used by people in one part of the world may therefore be available in an early game era, even if it became familiar to Europeans much later.

### 5. Historical Origins, Adoption, and Technological Feasibility

An important distinction in the historical approach of The City is the difference between the origin of something, its earliest known use, its spread between regions, and its eventual adoption by European societies.

These events are not interchangeable and often occurred at very different times.

The historical record is also incomplete. The earliest surviving written reference or archaeological evidence does not necessarily indicate the actual beginning of a practice. The absence of known evidence from an earlier period is not, by itself, proof that the practice did not exist.

This distinction is particularly relevant to agricultural products, food and beverages, medicinal and recreational plants, textiles, and other materials that originated outside Europe.

#### Coffee

Coffee is an example of the distinction between documented historical use and technological feasibility.

Its historical spread and the emergence of established coffee-drinking traditions are associated with particular periods and regions. However, the operations involved in processing coffee beans — drying, roasting, grinding, and preparing an infusion — do not inherently require sophisticated technologies.

The existence of later historical records of coffee consumption does not automatically establish that its use was technologically impossible in earlier periods.

In the context of The City, the relevant question is not simply when coffee became a familiar beverage in a particular region, but when humanity possessed the practical means to process and consume it.

#### Tobacco

Tobacco illustrates the geographical dimension of this distinction.

Originating in the Americas, tobacco was used by Indigenous peoples long before European contact. Its introduction to Europe in the sixteenth century represents the spread of an already existing plant and established practices to another part of the world.

The European adoption of tobacco is therefore a later chapter in its history, not the beginning of its use by humanity.

Its availability in an early game era can be justified by the much earlier history of its cultivation and consumption in the Americas.

#### Technological Feasibility

Historical dates alone are insufficient to determine when something can appear in the game. The actual technological requirements of a product or process are equally important.

Some products became widely known or commercially significant only at a relatively late date, despite relying on operations and materials that had been available much earlier. Conversely, other products genuinely depend on specialized knowledge, tools, materials, or production methods that emerged only after significant technological advances.

The game's progression therefore considers the practical complexity of production:

- the materials and resources involved;
- the tools and equipment required;
- the processing operations and production techniques;
- the knowledge necessary to perform those operations;
- the existence of comparable methods in other parts of the world.

This approach allows the game to maintain technological coherence without mistaking the chronology of one region for the chronology of humanity as a whole.

### 6. Cultural Identity and Toponymy

The cultural identity of The City is not tied to any single historical civilization, language family, or geographical region.

Names of cities, regions, products, and other elements of the game world may draw inspiration from different cultural and linguistic traditions. Elements from otherwise unrelated traditions may appear together within the same name.

For example, **"Qasr-al-Midgard"** combines Middle Eastern and Norse-inspired elements. Such combinations are entirely consistent with the alternate cultural setting of the game.

This flexibility reflects the fictional nature of the world and its independent cultural identity. Names are not required to reproduce real-world historical naming conventions or follow the geographical distribution of actual languages.

At the same time, cultural blending is not synonymous with arbitrary word combinations. Names should remain recognizable, reasonably pronounceable, and internally coherent within their immediate context.

The resulting toponymy contributes to the game's identity as a fictional world rather than a geographically disguised version of a particular region on Earth.

### 7. Historical Research as a Source of Inspiration

Real-world history remains an important foundation for the game's resources, technologies, production processes, and cultural references.

Historical research helps establish what materials were available, how people processed them, what tools they used, and what technological knowledge was required. It also provides examples of production practices and economic relationships that can inspire game mechanics.

However, historical information is considered within the broader perspective of humanity's development rather than through the chronology of any single region.

In particular, historical research distinguishes between:

- the origin of a resource or technology;
- its earliest known use;
- its adoption by different populations;
- its spread to other regions;
- its introduction to Europe;
- its eventual industrialization or mass production.

These distinctions provide a more accurate understanding of historical development and prevent the dates associated with one region from being mistaken for universal milestones.

When historical evidence is incomplete or disputed, the game may rely on a reasonable interpretation of technological feasibility rather than imposing an arbitrary historical date.

The objective is not to reproduce every historical detail, but to create a coherent alternate world grounded in the actual achievements and capabilities of humanity.

### 8. Design Implications

The historical and geographical philosophy described above has several direct consequences for the design of The City.

**Resource availability** is not restricted by the real-world geographical distribution of plants, animals, and materials. Their placement is determined by the fictional geography and the game's ecological and economic systems.

**Technological progression** represents the approximate development of humanity as a whole. Game eras are not tied to the historical milestones of a particular civilization.

**Product and resource introduction** is based on historical origins and technological feasibility, rather than the date when a product became known in Europe.

**Production chains** draw on real-world material properties and historical techniques, while allowing alternate combinations and sequences consistent with the game's technological framework.

**Cultural and geographical references** are not required to conform to a single historical or regional identity. The world has its own alternate cultural and geographical context.

These principles allow The City to combine historical inspiration with creative freedom while maintaining a consistent view of technological and economic development.

### Conclusion

The City presents an alternate world in which human civilization develops as a whole, rather than through the historical perspective of any single region.

Its geography is fictional, its chronology is an approximate technological framework, and its cultural identity is deliberately eclectic. Real-world history provides the knowledge and inspiration behind its resources, technologies, and production systems, but no single civilization or regional chronology defines the entire world.

**The City is not a story of Europe discovering the rest of the world. It is a story of humanity developing its knowledge, industries, and societies in an alternate world.**

---

## 2. Design principles (mandatory)

1. **95% / 5%** — most of the time the system runs itself (auto-filling slots, sensible defaults). Manual configuration is rare and optional.
2. **Uniformity of rules** matters more than "historical vibe" in contested places (resource visibility, fresh water vs sea, etc.).
3. **Data-driven** — resources, buildings, technologies, terrains, recipes in JSON; modding is an architectural goal.
4. **City, not resident** — formulas depend on the scale of the city/buildings, not on the happiness of each NPC.
5. **Labour does not pile up in a warehouse** — it is computed at the moment of an action (construction, research): cost ÷ labour production per second → time.
6. **Realism is desirable, balance matters more** — "artificial" multipliers are acceptable if the player can read them; plausible constraints are preferable (feed, processing, time to fill a pasture).
7. **The early game must not be a waiting simulator** — it needs activities that do not cost much (scouting, foraging, etc.).

---

## 3. Map and world

### 3.1. Topology

- Grid: **odd-r** hexes.
- At start the **entire** map is generated at once (currently typically 60×60; the target headroom is up to ~200×200 with optimisation).
- **Ring of Influence** — the zone where improvements can be built. Start: set in `map_config` (`start_ring_rows/cols`, roughly 7×9).
- **Region** — a strip of width `region_width` (usually 2) around the Ring: only here can chunks be BOUGHT for a resource (coins from the treasury + labour — per the current economy, see docs.md, "Claiming territory: labour + coins").
- **Fog of war** — everything beyond the Ring+Region. Displayed as a solid grey fill. After researching the **Cartography** technology, scouting can be sent to any point reachable by scrolling — including the territory of towns; before that, scouting is limited to the unexplored part of the Region (fog hexes do not respond to hover and click). Both scouting and buying chunks require the chunk to **border known territory** (the Ring of Influence or explored hexes): scouts do not jump over unexplored land, the border of the known world expands forward chunk by chunk. Buying chunks is still limited to the Region. A hex in the fog of war reveals no information: the tooltip and panel show only a placeholder until the hex is explored.
- On an **era transition**: the unbought Region may be given away for free; the Ring expands; a new Region forms outside it (era logic is in development).

### 3.2. Terrain layers

1. **Terrain (relief):** plain, hill, mountain, lake, swamp, marsh, sea, beach (+ unique: soda_lake, asphalt_lake, …).
2. **Cover:** none, forest, sparse_forest, reeds, swamp_forest, … — a separate layer; forest is not a separate "terrain type" but an overlay on top of the relief.

- **Swamp (swamp)** — part of the Voronoi (`terrain_config`).  
- **Marsh (marsh)** — post-processing only near water (lakes and seas); not Voronoi centres.  
- **Sea (sea)** — **not** Voronoi: a mask before/over the Voronoi.  
- **Beach (beach)** — land by the sea, tied to the map edge.

### 3.3. Relief generation

- Base land relief: **Voronoi + JFA**, densities and `target_cluster` **per type** in `map_config.terrain_config`.
- `target_cluster` — the average size of a patch; smaller → finer clusters.
- Guarantees around the city:
  - `CENTER_EXCLUSION_RADIUS` — impassable centres (lake/sea) are not placed nearby;
  - `PLAIN_ZONE_RADIUS` / `_ensure_plain_zone` — a plain yard;
  - `_ensure_outward_corridor` — if the city is cut off by water, a corridor is cut through.

### 3.4. Sea

- Config: the `sea` block in `map_config`.
- Modes: `none` | `edge` | `noise`.
- The player's intent: the sea is **mostly beyond the map edge**; on the map there is a **small bay/tongue**, not a solid strip along the entire edge, but if desired the player can configure sea generation to their own taste.
- Parameters such as `sides`, `edge_width_*`, `edge_envelope_strength`, `max_sea_depth` control the shape; the target UX is "we found an outlet to the sea", not "the entire eastern border is ocean".
- `move_cost` for sea/lake is high (impassable for land-based logic).
- **Fresh water / irrigation** — from lakes, rivers, canals, conduit farms; **not** from the sea.
- **Two uses of water in production** — as a *material* (irrigation of cultivated plants, washing/soaking hides at a tanner's) and as *motive power* (ore washing at a mine/quarry, water-driven bellows in metallurgy). The first needs water access only, the second also needs the "Water Wheel" technology. Both are data-driven and can target map improvements as well as city buildings. The vineyard stays dry-farmed, and the Water Mill is paid for by its own recipe rather than a second multiplier.
- **The effect of a technology belongs to the technology** — every effect lives in the record of that technology in `tech_modifiers`, so a technology and everything it changes are read in one place. A record may ask for the water as well (`requires_water`), which is what the water-driven machinery needs.
- **Gearing is a mechanic of its own, and it needs no water** — the toothed wheels pass a rotation on to the working tool, and the same gears are turned by a water wheel, an animal, a treadle or a human arm. The "Cog Wheel" technology (the wheel and the mathematics) opens it: the ratchet and the geared winch of the mine, the gear drive of the animal mill, the ratchet of the press, the crank of the saw, the treadle of the loom. The hoists of the mine belong to the gears; the water only washes the ore.

### 3.5. Rivers

- Along the **edges/vertices** of hexes (not filling the centre of a hex).
- Main rivers: source in the mountains (otherwise hills) → mouth into a **lake or sea**.
- Tributaries flow into main rivers/other tributaries.
- Do not flow through swamps/marshes.
- Rendering: meanders, point cache; performance is critical on large maps.

### 3.6. Unique terrains

- `unique: true` in the terrain data; `place_unique_terrains` places **one** cluster on the map (size from `cluster_size`).
- Examples: soda lake, asphalt lake — a bonus to the extraction of the associated resource (`terrain_modifiers`).

---

## 4. Resources

### 4.1. Spawn

- **Almost all resources spawn at start** on suitable hexes.
- The exception, in the spirit of the early game: guaranteed starting food plants in the starting zone.
- Guarantees in the starting zone (Ring+Region): food (plant), construction material/mineral, metal (not visible at start, unlocked after researching the technology) (see `ensure_minimum_resource`).

### 4.2. Visibility and extraction

Two independent fields:

| Field | Meaning |
|------|--------|
| **`tech_required`** | A technology is needed to **build an improvement** / operate it |
| **`tech_reveal`** | The resource **becomes visible on the map** only after the corresponding technology is researched (deep metals, etc.) |

- "Surface" resources are visible after scouting / in a bought zone, but may be locked until `tech_required`.
- `tech_reveal`: even in a bought zone they stay hidden until the corresponding tech is researched; on reveal — a message; if the hex already has another improvement — the UI shows an exclamation mark, tooltip "discovered / demolish / build".
- Scouting over hidden iron may honestly report "no resources" — the scouts did not recognise the ore.

### 4.3. Domestication

- A resource on the map = "wild X are found in the area".
- The first improvement (farm/pasture) **domesticates** the species → afterwards the same improvement type can be placed on suitable hexes without a repeated "wild" tile.
- Breeding on an empty hex must record a `crop_bred` field in the hex data (the current schema is in the code).
- Breeding animals/plants inherits quality: "exceptional cows produce exceptional calves".

### 4.4. Quality (accepted for implementation)

- Levels: **common → good → exceptional → superb** (4 steps).
- Quality exists on raw materials and is inherited by products (with averaging if the warehouse is mixed): "exceptional flour makes exceptional bread".
- The warehouse stores a breakdown by quality; tooltips / the Trade tab show the details.
- **Towns use simplified rules:** their warehouses never hold mixed quality, each good has exactly one level, taken from the resource on the map. During "production" the standard craft-result rule applies (weighted average), as for the player's city. In the town window the level is shown simply as stars and their colour, without a breakdown or percentages.
- Auto-selection of raw materials: by default priority is given to higher quality; optionally fine-tuning per building (expensive / cheap / random).
- A separate "system of canvas grades from different materials (linen, jute)" was **not** introduced as batch micromanagement — instead, raw-material quality.

---

## 5. Production and the city

### 5.1. Map improvements vs city buildings

- **Improvements** on hexes: farms, pastures, mines, tar pits… — mostly raw materials (and restrictions by terrain/cover).
- **City buildings**: processing, production slots, recipes (butchery, cheese dairy, forge…).
- One worker (slot) per improvement/building — the base employment model.
- Production slots: a list of buildings → slots → what they produce; switching a slot/building off without micromanaging every resident.

### 5.2. Food and growth

- Historically food was the "currency" for everything — this is being **softened / phased out**: food is primarily for the population and growth; scouting and claiming territory go through **treasury coins** (+ time and labour), construction and science through **labour** and **science** respectively.
- Population growth: a food threshold per new resident (a progression where "each next one is more expensive" is possible).
- Pastures: raw meat/milk → processing in the city; **feed** from farms; without feed a strong penalty to output; livestock filling over time (planned).

### 5.3. Labour

- The city produces labour as a function of scale (population/development), not as an accumulating warehouse of "hammers".
- Action time = f(cost in the data, current labour speed, modifiers such as satiety, the Wheel).
- **The Wheel:** −30% to the influence of distance from the city on the labour cost when building improvements.

### 5.4. Trade and specialisations (design, partly ahead)

- Domestic/foreign market, prices, imports for chains.
- **Reputation / "known for X"** from volumes → a soft bonus.
- **Challenges** (including dynamic ones by product/quality): complete one → the brand "good (CityName)", a specialisation branch, unique buildings.
- A meta-achievement for "completing a challenge by reselling an import" is deliberately allowed as a clever workaround.
- Static achievements: "Monogamist", "I don't want to wait" (buy out the Region before an era change), etc.

---

## 6. Technologies and eras

### 6.1. Technologies

- A tree (UI: root, links; highlighting of paths to parents).
- They unlock: buildings, improvements, mechanics, sometimes resource reveals, bonuses.
- Split by eras (planned): in each era only the technologies of that era can be unlocked. Until the player advances from the Ancient era to the Antiquity era, Antiquity technologies are not available.

### 6.2. Eras

- Plan: several major eras (either 3 (major, carefully crafted), or 7 — **not yet finalised**).
- Transition by goals (food / other metrics in the future).
- On transition: territory expansion, new opportunities; old buildings may be preserved, change function, or become obsolete (the "city through the ages" intent).

**Open question:** a full run through to modern times vs a focus on antiquity–early modernity with deep chains. The fallback option is a limited chronological span.

---

## 7. Early game

The problem: "you placed a farm — now you watch a counter".

Accepted/desirable activities:

1. **Scouting the Region** — cost (treasury coins, growing with distance from the city) + time, progress per chunk; reveals the landscape and visible resources.
2. **Gathering wild plants** — one-off on a limited number of hexes, a small food bonus, not a map-wide clicker.
3. Later: buying chunks, pastures, processing, technologies.

The "Development" mode originally blocked the normal map; there was discussion of combining construction in the Ring and scouting in the Region on one map and freeing the mode up for other mechanics.

---

## 8. UI / UX

- Tooltips: terrain, resource, improvement, quality, irrigation, construction time.
- A lock on a resource closed by tech.
- The buildings tab: not an empty panel — a description, recipes **before** construction (critical).
- A technology tree with dependency highlighting.
- Rule: information for a decision (what to build / what to research) must be available **before** spending a turn/resource.

---

## 9. Technical anchors for the assistant

| Area | Where to look |
|---------|----------------|
| Map config | `data/map_config.json` |
| Terrains | `data/terrains/` |
| Map generation | `scripts/map_generator.gd` (and related) |
| Rivers | river manager / generator / renderer |
| Resources, tech fields | resource JSON + spawn logic |
| City, UI | `city_ui/`, city managers |
| Documentation in code | comments in the generator, `docs` if present |

The assistant **can and should** read GitHub/raw files. Do not simulate reading.

The internet and the repository are the primary way of synchronising the project state between chats.

---

## 10. Known problems and open decisions

### Known / recurring

- Performance of generation/rendering on large maps (rivers, scrolling in late eras).
- Large terrain patches at high `target_cluster` / merging of centres.
- An empty early game if there are few activities alongside accumulation.

### Open design decisions

1. The final number and content of **eras**.    
2. The boundary of **urban planning** (roads as logistics — yes; street-level C:S — no, while the core is economic).  
3. Full trade, challenges, brands — the design is broadly agreed, implementation as the base becomes ready.  

---

## 11. What the game does *not* do (deliberately, for now)

- Character-by-character combat / armies.  
- Micromanagement of every resident.  
- Accumulation of labour in a warehouse "while the player is in the kitchen".  
- A mandatory street-level city builder.  
- A quality system via manual batches and sorting lots in the warehouse.

---

## 12. Brief history of the shift in focus

The author's notes of 2014–2019: a stronger emphasis on shaping the city's appearance, roads, housing, municipal buildings, quests, public transport.  
Current development (2026): a resource economy on hexes, chains, technologies, landscape, eras as a frame.  
**The connecting thread:** one city over a long time; almost everything from the old notes *can* be added, but not at the cost of blurring the core. The priority is what reinforces the "city-economy on a map".

---

## 13. Instructions for a "new" assistant

1. Read this document.  
2. Check the latest commits and the key JSON/scripts in the repository.  
3. Do not propose breaking the principles of §2 without an explicit request from the author.  
4. Write/edit code only when the author is at the computer and asks; from a phone — design and specifications.  
5. When unsure about the implementation — look at the code, do not guess from a file name.  
6. The language of communication with the author is **Russian**.

---

*End of the design document.*
