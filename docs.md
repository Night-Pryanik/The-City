# The City game data documentation

All game data is stored in JSON files in the `data/` folder. This document describes the structure of each file and the purpose of its fields.

---

## Hex model: terrain + cover

| Field | Description | Examples |
| --- | --- | --- |
| `terrain` | **Terrain** — the base terrain type | `"plain"`, `"hill"`, `"mountain"` |
| `cover` | **Cover** — vegetation on top of the terrain | `"none"`, `"sparse_forest"`, `"forest"` |

A "plain with forest" hex is `terrain: "plain"` + `cover: "forest"`.

### Rendering

1. First the `terrain` icon/texture is drawn (the `terrain_icon` field).
2. On top of it — a semi-transparent `cover` overlay (an icon; if there is no icon — a colored polygon with `alpha`).
3. The resource / improvement / progress bars are drawn on top of everything.
4. The size of the improvement icon on the map depends on whether the hex has a resource:
   - **the hex has a resource** — the improvement is drawn as a small marker (32 px, `IMPROVEMENT_ICON_SIZE`) above the top edge, on top of the resource icon;
   - **the hex has no resource** (a woodcutter's camp on an empty forest, an irrigation canal, decorative town improvements on empty hexes) — the improvement is drawn large in the center of the hex, the size of the resource icon (80 px, `RESOURCE_ICON_SIZE`): in effect it replaces the missing resource icon. In this case the fresh water droplet is placed above the icon, not to its right.

### Clear forest

Clear forest = `cover` → `"none"`. In `special_actions.json` this uses `action_type: "cover"`:

- applicable if the hex's `cover` is in `source_cover` and the hex has **no** resource and no improvement;
- on completion only `cover` changes; the terrain/resource/improvement are not touched.

---

## Breeding animals and plants (the `crop_bred` schema)

In `tile_data` there are **two independent fields** for resources on a hex:

| Field | When it appears | When it is cleared |
| --- | --- | --- |
| `resource` | A natural resource placed by the map generator or appearing after a technology is researched (`tech_required`). The field is permanent and does not depend on the improvement | Only by special actions (for example, demolition) or by manual overwriting |
| `crop_bred` | A bred animal/plant set when a pasture/farm/apiary is built on an **empty** hex | Removed together with the improvement (via the "Demolish Improvement" special action); replaced when a new farm/pasture is built on this hex |

### Behavior when building an improvement

In `main_map._on_build_completed` (`scripts/main_map.gd`) the scenario depends on whether the hex had a natural resource:

1. **`tile.resource != null`** (there was already a natural resource) — we place an improvement to harvest it. `tile.resource` is preserved, `tile.crop_bred` stays `null`. This is the "improving an existing resource" case (for example, a mine on a mineral, a farm on natural wheat).
2. **`tile.resource == null`** (the hex was empty) — the player breeds a domesticated species. We write the `id` of the animal/plant into `tile.crop_bred` and do NOT touch `tile.resource` (it stays `null`). This is the "built a pasture on an empty hex and raised cattle there" case.

### Effective resource

Subsystems (production, tooltips, rendering, research progress bars) need only one id — "what is actually produced on this hex". For this, `scripts/map_helpers.gd` has a helper:

```gdscript
MapHelpers.get_effective_resource(tile)
```

Returns `tile.resource` if it is set, otherwise `tile.crop_bred`, otherwise an empty string. Use it in all subsystems that want to "know what is produced" on a hex, without thinking about the nature of the resource.

### Quality inheritance

When the player breeds a new animal/plant on an empty hex, the quality is determined as follows (`scripts/main_map.gd: _on_build_completed`, the `else` branch):

1. First we search the map for an already domesticated instance of the same species — a hex where `improvement != null` and (`resource == target_res_id` OR `crop_bred == target_res_id`).
2. If there is one and it has a quality set — we inherit it ("exceptional begets exceptional").
3. Otherwise — we generate it randomly via `GameData.roll_quality()`.

The search over both fields (`resource` and `crop_bred`) is implemented in `MapHelpers.find_domesticated_quality`.

### What can be bred (the `breedable` field)

The breeding mechanic does not apply to all domesticated species. In the resource JSON
(`data/resources/*.json`) there is a `breedable` field — `true` by default if the field
is not set. For water resources (fish of lakes and the sea) it is `false`: they cannot
be "bred" on empty hexes — fish is harvested only where there is a natural
resource, via the "Fishing Boats" improvement (`fishing_boats`) with a harbor_access check.
The domestication of fish by building boats is preserved: it goes into
`CityData.domesticated_animals` and is displayed as a domesticated species, but neither the control
panel (`control_panel.gd`) nor the empty-hex building helper
(`MapHelpers.get_buildable_improvement`) will offer to breed it.
The biome check is performed via `MapHelpers.can_breed_resource_on_tile` in all
places where breeding options are formed; it takes `breedable` into account.

### Additional breeding sites (the `breeding` field)

By default a species can be bred on any pair of `allowed_terrain` +
`allowed_cover`. The optional `breeding` field **adds** additional
sites, without changing the natural spawn restrictions. The format is an array of groups:

```json
"breeding": [
  [ { "terrain": "sandy_desert" }, { "cover": "oasis" } ],
  [ { "terrain": "rocky_desert" }, { "cover": "oasis" } ]
]
```

- the outer array is combined with **OR** — any group qualifies;
- the conditions inside a group are combined with **AND**;
- only the `terrain` and `cover` keys are supported; a condition with a single key
  restricts only the terrain or only the cover;
- the value of `terrain` or `cover` can be a string or an array of strings; for
  an array, membership of the hex's actual value is checked;
- empty groups, groups with unknown keys and an invalid `breeding` type
  are ignored;
- `spawn_conditions` does not affect breeding — it is additional conditions
  for the natural appearance of the resource;
- `breedable: false` forbids breeding regardless of a suitable biome.

An array inside a condition lets you avoid listing identical groups. For example,
the two groups below allow `swamp` and `marsh` with both `reeds` and `none`:

```json
"breeding": [
  [ { "terrain": "swamp" }, { "cover": [ "reeds", "none" ] } ],
  [ { "terrain": "marsh" }, { "cover": [ "reeds", "none" ] } ]
]
```

A single check for the menu, crop selection and build hints is implemented
in `MapHelpers.can_breed_resource_on_tile`.

### Removing breeding

Demolishing the improvement (`action_type: "demolish"` in `special_actions.json`) on a hex with `crop_bred`:

- `tile.improvement = null`
- `tile.crop_bred = null`
- `tile.resource` is **not touched** (there wasn't one on this hex anyway — this is breeding)

After demolition the hex becomes "empty" again — a pasture/farm for another species can be built on it.

### Hex summary

| Scenario | `terrain` | `cover` | `resource` | `crop_bred` | `improvement` |
| --- | --- | --- | --- | --- | --- |
| Empty hex | … | … | `null` | `null` | `null` |
| Natural resource, no improvement | … | … | `"wheat_field"` | `null` | `null` |
| Improving an existing resource (farm on wheat) | … | … | `"wheat_field"` | `null` | `"farm"` |
| Breeding on an empty hex (pasture with cattle) | … | … | `null` | `"cows"` | `"pasture"` |
| After removing breeding | … | … | `null` | `null` | `null` |

---

## Fresh water and irrigation (the `water_access` schema)

### Types of fresh water access

Each hex can have access to fresh water. The access type is a **derived** value: it is computed on the fly, is not stored in the save and is not set in the data. The single source of truth is a static function in `scripts/map_helpers.gd`:

```gdscript
MapHelpers.get_hex_water_access(row, col, tile_data, map_rows, map_cols) -> String
```

It returns one of three strings:

| Value | Meaning |
| --- | --- |
| `"direct"` | Direct access to fresh water: a hex with a `terrain` or `cover` that carries the `fresh_water_source: true` flag (currently — a lake and an oasis), a hex that has `river_edges` (a river), the canal itself (`is_canal: true` on its improvement), a neighbor of a canal, or a neighbor of a fresh water source. See the section "Fresh water sources: the `fresh_water_source` flag". |
| `"chain"` | Access via a **chain of conductors** — farms/plantations/canals (`conducts_water == true`). It works ONLY after the "Irrigation" technology is researched (`tech_id: "irrigation"`). All the intermediate links of the chain are conductors; the chain ends with a conductor that has its own direct access to water (`direct`). Empty coastal hexes of rivers and fresh water sources do NOT pass water on. The chain length comes from the `water_chain_length` modifier in `data/modifiers.json` (see below). |
| `""` | There is no access to fresh water. |

The fresh water bonus (a production multiplier from `data/modifiers.json`, the `fresh_water.production_multiplier` field) is received by hexes with any access: `direct` — always, `chain` — only after "Irrigation" is researched. The former function `is_hex_irrigated(...)` is a wrapper over `get_hex_water_access`; it returns `true` if there is access (for compatibility with existing calls).

### Chain length (the `water_chain_length` modifier)

The chain length between conductors is set by **data**, not by code: `data/modifiers.json` → `tech_modifiers[].modifiers[]` with `target: "water_chain_length"`. The maximum value among the researched technologies is taken. Currently:

| Technology | Length |
| --- | --- |
| "Irrigation" (`irrigation`) | 3 |
| "Canals" (`canals`) | 4 |

"Canals" requires "Irrigation" as a prerequisite (`prerequisites`), so when "Canals" is researched both modifiers are active, and the maximum (4) wins. With no researched technologies having this `target`, the length = 0 and the chain does not work at all (a conductor without direct access to water gets no bonus). The implementation is `MapHelpers.get_water_chain_length()`.

### Water conductors

The `conducts_water: true` field on an improvement in `data/improvements.json` makes a hex a "conductor" — able to spread fresh water to neighboring hexes after "Irrigation" is researched.

Currently the conductors are:

- **Farm** (`farm`)
- **Plantation** (`plantation`)
- **Irrigation Canal** (`irrigation_canal`) — itself a direct water source (`is_canal: true`), so it immediately gives water to its neighbors.

Building a conductor on a hex that **already has** direct access to water (`direct`) immediately gives it the fresh water bonus. Passing water to neighboring hexes along a chain (`chain`) becomes available only after the "Irrigation" technology is researched.

**Important (bugfix):** only conductor improvements pass water. Empty coastal hexes (neighbors of a fresh water source, or hexes whose edge is a river edge) have direct access themselves, but do NOT pass water further: a `chain` must consist entirely of conductors and close on a conductor that has its own direct access. Previously the BFS closed on any "direct source", so a farm next to a river/lake through an empty shore received the bonus without a single neighboring conductor.

### Fresh water sources: the `fresh_water_source` flag

Exactly which `terrain` and `cover` count as direct fresh water sources is **set by data**, not by code:

- In `data/terrains.json` — the `fresh_water_source: true` field on a terrain type.
- In `data/covers.json` — the `fresh_water_source: true` field on a cover.

If the field is set on a terrain/cover, a hex with that `terrain`/`cover` (and its coastal neighbors) get `"direct"` access to water without any technology being researched. The source is read by `MapHelpers._is_fresh_water_source_terrain` / `_is_fresh_water_source_cover` (`scripts/map_helpers.gd`); the combined `_is_fresh_water_source_tile` check that joins both is called from `_is_direct_water_source` and `_is_adjacent_to_fresh_water_source`. Rivers (`river_edges`) are a separate source, not through the flag.

Currently the flag is set on:

- `terrain` — **"Freshwater Lake"** (`lake`).
- `cover` — **"Oasis"** (`oasis`). An oasis can lie on any desert base (`sandy_desert` / `rocky_desert`), but it is the cover that makes the hex a fresh water source.

New fresh water sources (for example, a spring, a hot spring, a glacier) need only be added to `terrains.json`/`covers.json` with the `fresh_water_source: true` field — the `water_access` code will pick them up automatically, with no edits to `map_helpers.gd`.

Regression tests: `tests/water_access_test.gd` (+ `.tscn`). Run:

```
godot --headless --path . res://tests/water_access_test.tscn
```

### Display

- **A droplet next to the improvement** (`scripts/map_renderer.gd`): drawn next to any improvement with access to water. `direct` — a filled blue droplet (as farms used to have), `chain` — an outline, muted droplet.
- **Extended tooltip** (`scripts/map_tooltip.gd`): the line "Fresh water access: …" is shown for **all** hexes (not only those with an improvement): `direct` or `via chain (requires Irrigation)`. On hexes without access the line is absent. The regular tooltip does not have it: see the section "Regular and extended hex tooltips".

### Irrigation canals (`irrigation_canal`)

Canals are infrastructure improvements unlocked by the "Canals" technology (`unlock_tech: "canals"`). With them you can extend fresh water to remote hexes. The full validation of the building conditions is `MapHelpers.can_build_canal()` (used from `control_panel.gd`).

**Where you can build:**

- A hex in the Influence Ring, without a resource/improvement/breedable crop/foreign town.
- Terrain that is "flat and dry" — NOT water (`sea`/`lake` and custom `*_lake` with `move_cost >= 999`), NOT mountains, NOT swamp/marsh. Passable land: `plain`, `hill`, `beach` and any custom terrains with `move_cost < 999`, except `swamp`/`marsh`.

**Where you MUST NOT:** any water tiles, mountains, swamps, marshes, impassable terrains, occupied/claimed/town hexes.

**Requirement for a neighboring water source** (at least one):

- a river along a **shared edge** (for a river it is checked that it flows exactly along the edge that borders the canal's hex — via `get_shared_edge_index`);
- a neighbor that is a fresh water source (`fresh_water_source: true` on its `terrain`/`cover`: currently — a lake or an oasis);
- another canal (`is_canal: true` on the neighbor);
- a water conductor (farm/plantation/canal) with direct access to water — this allows the canal to be "extended" from an already irrigated network.

**What a canal gives after construction:** it is itself a direct water source (`_is_direct_water_source` returns `true` for a canal), plus its hex is a conductor (`conducts_water: true`). Neighboring hexes get `direct` access, and hexes further along the chain get `chain` with the length set by the modifier (4 with "Canals" researched).

---

## Harvesting water resources (the `harbor_access` schema)

Water resources (currently — the freshwater fish `freshwater_fish` on lakes and marine resources on the shallow sea `shallow_sea`) are available for exploitation only through a pair of two improvements:

| Improvement | Flag in `improvements.json` | Where it is built |
| --- | --- | --- |
| **Harbor** (`harbor`) | `water_body_harbor: true` | An empty coastal hex: land (not a mountain, not water) with a `lake`/`sea` neighbor. The button appears in the control panel after "Fishing" is researched |
| **Fishing Boats** (`fishing_boats`) | `requires_harbor: true` | A hex with a fish resource that belongs to a water body with a harbor |

### Key rules

1. **One water body = one harbor.** A water body is a connected area of fresh water (`lake`) or sea (`shallow_sea` and `sea`; a lake does not connect to the sea). A harbor opens the resources of only ITS OWN water body; a neighboring lake needs its own harbor.
2. **Access is computed dynamically** (`MapHelpers.has_harbor_access`, `scripts/map_helpers.gd`): a BFS/flood-fill from the resource hex over connected hexes of the same water body; if any visited water hex has a land neighbor with the `water_body_harbor` improvement — there is a path, and the resource is accessible. There is no state/cache, therefore:
   - building a harbor instantly opens all the resources of the water body;
   - demolishing the harbor closes the water body again for NEW boat constructions (boats already built keep working).
3. **UI gate:** the "Build Fishing Boats" button in the control panel (`control_panel.gd`) is inactive with the tooltip "requires a Dock on the shore of this water body" until the BFS finds a harbor on this water body.
4. A harbor does not harvest resources by itself — it is only an access key.
5. **A harbor is an infrastructure improvement:** it is marked with the `no_worker: true` field in `improvements.json` and **does not require a worker** — it opens water resources immediately after construction. A citizen cannot be assigned to it, and the control panel has no "Start/Pause operation" buttons for it.

### A town's decorative harbour is not the key

The towns place their own harbours on their coasts (see *Town harbours*). Such a
harbour is the scenery of a foreign settlement: `has_harbor_access` skips a
`water_body_harbor` improvement standing on a tile with `decorative: true`. A body
of water is opened only by the harbour of the player — otherwise a coastal town
would give the whole sea away for free, and rule 3 would contradict the dock the
player sees on the map.

### Shallow sea

When the sea is generated, along every boundary between the sea and land, including around islands, a strip of `shallow_sea` is created. Its local width varies smoothly from 1 hex up to `sea.coast_max_depth` inclusive; by default the maximum is 5. Beyond the strip, the deep sea `sea` remains. All marine resources are placed only on `shallow_sea`, but both sea terrain types form a single water body for harbor access and for the generation of river mouths.

---

## File reference

---

### `data/technologies.json` — technologies

Root key: `technologies` (an array of objects).

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `id` | string | ✅ | A unique technology identifier | `"farming"` |
| `name` | string | ✅ | The display name | `"Farming"` |
| `era` | string | ✅ | The era (see `eras.json`) | `"ancient"` |
| `science_cost` | number | ✅ | The research cost in science | `3.0` |
| `description` | string | ✅ | A brief description of what it unlocks | `"Unlocks all food plants and allows you to build farms."` |
| `flavor` | string | ✅ | Lore text (historical background) | `"The first farmers noticed..."` |
| `prerequisites` | array\<array\<string\>\> | ⬜ | Prerequisite technologies. **An array of arrays**: within each nested array — OR (one is enough), between arrays — AND (all are required) | `[ [ "animal_husbandry" ] ]` — one is required; `[ [ "oil_making", "animal_husbandry" ] ]` — one of the two is required |
| `icon` | string | ⬜ | The technology icon's file name (looked up via the `IconRegistry`, see "Icon registry") | `"wheat.png"` |
| `unlock_effects` | array\<object\> | ⬜ | **Arbitrary technology effects for the icons on the button** (see "Icons of unlocked content"). Each element: `{ "icon": "<file>", "name": "<tooltip label>" }` | `[ { "icon": "farm.png", "name": "Farms: +50% production" } ]` |

---

### `data/resources/*.json` — resources on the map

Files:

- `resources/minerals.json` — minerals and stones
- `resources/animals.json` — animals
- `resources/plants/food_plants.json` — food plants
- `resources/plants/fruit_plants.json` — fruit plants
- `resources/plants/textile_plants.json` — technical (textile) crops
- `resources/plants/flowers.json` — flowers

Root key: `resources` (an array of objects).

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `id` | string | ✅ | A unique resource identifier | `"wheat_field"` |
| `name` | string | ✅ | The display name | `"Wheat"` |
| `type` | string | ✅ | The entity type. For resources on the map it is always `"raw"` | `"raw"` |
| `category` | string | ✅ | The category (see `categories.json`) | `"plants"`, `"animals"`, `"minerals"` |
| `group` | string | ✅ | A group for diversity bonuses (see `groups.json`). It can be an empty string | `"food_plants"`, `"meat_animals"`, `""` |
| `subgroup` | string \| array\<string\> | ✅ | The subgroup(s) for diversity bonuses (see `groups.json`). It can be an empty string. An array — the resource belongs to several subgroups at once (for example, lazurite — dyes and jewelry stone) | `"cereals"`, `"cattle"`, `""`, `["dye_minerals", "jewelry_minerals"]` |
| `tech_required` | string | ⬜ | **The technology that unlocks the appearance of the resource on the map.** Until it is researched — the resource does not spawn. Absent for foraged food (`wild_food`) | `"farming"` |
| `allowed_terrain` | array\<string\> | ✅ | The **terrains** on which the resource can spawn (see `terrains.json`); for `breedable` resources these are also the base breeding sites. Additional sites are set by `breeding` | `["plain", "hill"]` |
| `allowed_cover` | array\<string\> | ✅ | The **covers** on which the resource can spawn (see `covers.json`); for `breedable` resources these are also the base breeding sites. Additional sites are set by `breeding` | `["none", "sparse_forest", "forest"]` |
| `breeding` | array\<array\<object\>\> | ⬜ | **Additional breeding sites** on empty hexes. The outer array is combined with OR, the conditions inside a group — with AND. It does not affect natural spawning; for more detail — see the section about `crop_bred` | `[ [ { "terrain": "sandy_desert" }, { "cover": "oasis" } ] ]` |
| `spawn_count` | number \| array | ⬜ | **The number of instances of the resource on the map.** A number (`3`) — a fixed amount; an array `[min, max]` (`[2, 4]`) — a random amount from the range. `0` — the resource does not spawn at all; `1` or an absent field — the old behavior (one instance). Invalid data (not a number / not an array of 2 numbers, negative values) → a console warning and the default `1`. If min > max — the range is forcibly swapped. For **one-off** resources (foraged food, nuggets; `improved_by: null`) spawning happens across the **whole map** at game start, as with foraged food. See `_resolve_spawn_count()` and `place_one_time_resources()` in `scripts/map_generator.gd` | `[2, 4]` |
| `spawn_conditions` | array\<array\<object\>\> | '
 ⬜ | **Additional resource spawn conditions.** An array of condition groups combined with AND/OR (see the subsection below). If the conditions are not met — the resource is excluded from spawning | `[ [ { "type": "near_river", "chance": 100 } ] ]` |
| `improved_by` | string \| null | ✅ | The ID of the improvement that must be built to harvest the resource (see `improvements.json`). `null` — the resource does not require an improvement (for example, foraged food) | `"farm"`, `null` |
| `produces` | object | ✅ | What the resource gives: `{ "product": amount }`. The **amount** can be a number (`1`) or a range `[min, max]` (`[2, 5]`). A number — a fixed output (normal production by an improvement); a range — a random output (for **one-off** resources with `improved_by: null`: nuggets, foraged food). Invalid data → a warning and the default `1`. Validation/roll — `RangeUtils.roll_value()` in `scripts/range_utils.gd` | `{ "wheat": 1, "feed": 12 }`, `{ "gold": [2, 5] }` |
| `icon` | string | ✅ | The icon's file name in `icons/` | `"wheat.png"` |
| `color` | array\<number\> | ✅ | A placeholder RGB color `[r, g, b]` (0–255), used if the icon is not found | `[218, 165, 32]` |
| `feed_consumption` | number | ⬜ | **Animals only.** Feed consumption per unit of time | `10` |
| `time_to_mature` | number | ⬜ | **Animals only.** Time until maturity | `60.0` |

> **Important:** `tech_required` is used **only** in resource files. For buildings, improvements, goods and recipes, `unlock_tech` is used.

### One-off (gatherable) resources — foraged food and nuggets

Some resources on the map are **one-off**: they cannot be worked with an improvement (`improved_by: null`); instead they are **gathered** with the universal special action "Forage Resource" (`action_type: "forage"`). After gathering, the resource **disappears from the map** (`tile.resource = null`).

> **How "one-off" is determined.** The resource has `improved_by: null` (it is not worked by an improvement) and a non-empty `produces` (there is something to gather). To add a new one-off resource, it is enough to describe it in the data with `improved_by: null` and `produces` — gathering will be picked up automatically.

Rules for such resources:

| Rule | Value |
| --- | --- |
| Spawn | At game start, **across the whole map** (not only in the starting Influence Ring), by the `place_one_time_resources()` function in `scripts/map_generator.gd` |
| Number of instances | The resource's `spawn_count` field (a number or `[min, max]`) |
| Output when gathered | The resource's `produces` field: `{ "product": a number or [min, max] }`; each gathering takes a random value from the range |
| Biome restrictions | Standard: `allowed_terrain` / `allowed_cover` (and `spawn_conditions`, if set) |
| Concealment | Standard, via `tech_reveal`: nuggets spawn immediately but are visible to the player only after the technology is researched (for example, "Native Metals") |
| After gathering | The resource is removed from the hex, and the output is added to storage (crop quality = resource quality) |

How this works in the data:

- The source resource: `data/resources/metals.json` (the `*_nugget` nuggets), `data/resources/plants/food_plants.json` (`wild_food`).
- The gathering special action is **a single one for all cases**: `data/special_actions.json`, `id: "forage_resource"`, `action_type: "forage"`.
- Code: `scripts/map_generator.gd` (`place_one_time_resources`, `_resolve_spawn_count`), `scripts/control_panel.gd` (action applicability), `scripts/main_map.gd` (the `action_type == "forage"` branch), `scripts/range_utils.gd` (`RangeUtils.roll_value`).

Example (`data/resources/metals.json`): `{"id": "gold_nugget", "improved_by": null, "produces": {"gold": [2, 5]}, "spawn_count": [1, 10]}` — 1–10 gold nuggets will appear on the map; each will give 2–5 "Gold" when gathered and disappear.

In **in-game tooltips** one-off resources are not shown as "once the improvement is built it will give" — they have no continuous production, and the `produces` output refers only to the moment of gathering.

### `tech_reveal` — hidden resources (underground minerals)

`tech_reveal` is an optional string field in `data/resources/*.json`. Meaning: the resource **exists on the map from the very start**, but the player **does not see it** until the specified technology is researched. After research, the resource becomes visible like a regular one (taking scouting/purchasing of the area into account).

| Field | When | What it does |
| --- | --- | --- |
| `tech_required` | Building an improvement to harvest | Without the researched technology, the improvement (`farm`/`mine`/...) is unavailable in the UI. The resource itself is visible on the map. |
| `tech_reveal` | Viewing the resource itself on the map | Without the researched technology the resource is **hidden from the player**: it is not shown in the tooltip, not mentioned in the scouts' report, not shown in the context menu, and there is no resource icon on the hex. After research, it becomes fully visible, like a regular resource. |

**The relationship between the two fields.** Most resources have only `tech_required`: they are visible immediately, but can be harvested only after the corresponding technology. For "underground" resources (deep metals, rare ores) **both** fields are filled in. A typical pair for iron:

```json
"tech_reveal": "mining",            // the player learns to recognize ore in the mountains
"tech_required": "metal_processing" // the player learns to extract and smelt it
```

Until `mining` is researched, iron is "invisible": the scouts report "Resources: none", the tooltip does not show the resource, and there is no icon on the hex. Research `mining` — you see the ore in the mountains; research `metal_processing` — you can place a mine and start extracting.

**Conflict with an improvement.** If by the time a `tech_reveal` resource is discovered the hex already has an improvement for another resource (for example, on a hill with iron the player has built a pasture with sheep), a **red triangle with a "!"** is drawn:

- The old improvement is **not demolished automatically**; its production continues.
- In the tooltip: "Found here: \<resource\>" and "Demolish the current improvement to build \<new_improvement\>" (the improvement name is substituted from the resource's `improved_by`, not hardcoded).
- The triangle appears **only when `tech_reveal` has already been researched** — before that there is neither a triangle nor any mention of the resource.

**Spawn guarantees in the starting area.** So that the player does not end up in the situation "researched X, but there is nothing in the area", the starting area "Ring + Region" is guaranteed to contain at least one representative of each key category (via `MapHelpers.ensure_minimum_resource`, which picks a **random** id from the suitable ones):

| Guarantee | Filter | Bounds | Why |
| --- | --- | --- | --- |
| Metal | `{ "category": "metals" }` | Ring + Region | Learned about metals — there is something to extract. When new metals are added (copper, tin, gold…), it is enough to give them a `tech_reveal` — the guarantee will work automatically. |
| Building material | `{ "category": "minerals", "subgroup": "construction_materials" }` | Ring + Region | After `mining`/`masonry` — there is something to extract for construction. |

**A food plant** is guaranteed separately via `_ensure_food_plant` and remains **only** in the starting Ring (not in the Region): the player must be able to place a farm right away, without scouting and purchasing chunks.

When adding new categories (for example, ores for `metalurgy`), it is enough to add another call to `_ensure_minimum_resource({"category": "...", "group": "...", "subgroup": "..."})` with the required filter in `_initialize_map`.

#### Additional spawn conditions (`spawn_conditions`)

The `spawn_conditions` field lets you set **additional conditions** under which a raw resource (`"type": "raw"`) can appear on the map. It is checked **in parallel** with `allowed_terrain`, `allowed_cover` and `tech_required`: the resource will spawn only if the terrain AND the cover AND the technology AND the spawn conditions are all satisfied.

**Format** — an array of condition groups combined with **AND/OR** logic (similar to the technologies' `prerequisites`):

```json
"spawn_conditions": [
  [ { "type": "near_river", "chance": 100 } ]
]
```

- **The outer array** — condition groups combined with **OR**: it is enough for at least one group to be satisfied.
- **The inner array** — the group's conditions combined with **AND**: all the group's conditions must be satisfied.
- Each condition is an object:
  - `type` — the condition type (see the list below);
  - `chance` (a number 0–100) — the **probability of the resource activating**. If the random roll does not fall within the chance, the group is considered unsatisfied.

**Available condition types:**

| Type | Description |
|---|---|
| `near_river` | The hex has a **shared edge** with a river (the hex's `river_edges` are filled). Rivers are generated during map creation, so the check works correctly also for dynamic resource spawning after a technology is researched |

**Behavior when the conditions are not met:**

1. During spawning (at game start and during dynamic spawning from a technology), for a resource with `spawn_conditions`, the `chance` is "rolled" first. If the chance does not succeed, the resource is **excluded** from the resources that can appear on the map.
2. Then suitable hexes are searched for that satisfy `allowed_terrain`, `allowed_cover` and the groups' geometric conditions at the same time (for example, for `near_river` — only hexes adjacent to a river).
3. If no suitable hex is found (for example, a river does not run near suitable territory) — the resource **does not appear**. If a technology is researched, the player will see the message "It seems your region has no X."

**Example — clay (`clay_deposit`):** it spawns only on a hex with the allowed terrain type (`"allowed_terrain": ["plain"]`) that has a shared edge with a river, with 100 percent probability:

```json
"spawn_conditions": [ [ { "type": "near_river", "chance": 100 } ] ]
```

#### Universal condition by terrain type (`terrain`)

Besides `near_river`, there is a universal spawn condition by **terrain type**:

```json
"spawn_conditions": [ [ { "type": "terrain", "terrain_id": "soda_lake", "chance": 100 } ] ]
```

- `type: "terrain"` — the resource can appear only on hexes whose `terrain == terrain_id`.
- This condition is used for resources harvested on **unique terrain** (for example, soda on the soda lake `soda_lake`).
- Resources with such a condition spawn on suitable hexes anywhere on the map (including outside the starting Ring/Region), because unique terrain can be located far away.

---

### Unique terrain types (the `unique: true` field)

Some terrain types are not "base relief" (plain, hills, mountains, lakes) that participate in the Voronoi algorithm. Instead, they are placed on the map **separately and in a single instance**. Such types are marked in `data/terrains.json`:

```json
{
  "id": "soda_lake",
  "name": "Soda Lake",
  "color": [200, 220, 255],
  "move_cost": 999,
  "expansion_cost": 200,
  "unique": true,
  "cluster_size": 3,
  "cover_chance": { "none": 100 }
}
```

**Behavior:**

1. `map_generator.gd.make_terrain_counts()` ignores types with `unique: true` — they **do not participate** in the Voronoi diagram.
2. The generic function `place_unique_terrains(tile_data, rows, cols, city_row, city_col)` itself iterates over **all** unique terrain types (`unique: true`) from `data/terrains.json`. For each type it reads the maximum cluster size from the `cluster_size` field (default `3` if the field is not set) and places **one connected cluster** of `1..cluster_size` hexes **outside the starting Influence Ring**.
3. In `generate_map()` it is called once: `place_unique_terrains(tile_data, rows, cols, city_row, city_col)`. Adding a new unique type to `terrains.json` (with `"unique": true` and `"cluster_size"`) **requires no code changes** — the function picks it up automatically.

**Display:** hexes of unique terrain located **outside the visible Region** are displayed on the map darkened (like an unexplored Region), without resources/improvements. This is implemented in `map_renderer._draw_unique_terrain_hex()` (the list of hexes is stored in `main_map.unique_terrain_hexes`).

---

### Example: Soda (the soda lake `soda_lake`)

Chain:

1. **`terrains.json`** — the terrain type `soda_lake` with `"unique": true` and `"cluster_size": 3`.
2. **`map_generator.gd`** — during map generation, `place_unique_terrains` places a `soda_lake` cluster (1..`cluster_size` hexes) outside the Ring.
3. **`resources/minerals.json`** — the `soda_deposit` resource:
   - `tech_required: "soda_extraction"` — appears on the map after the technology is researched.
   - `allowed_terrain: ["soda_lake"]` — only on the soda lake.
   - `spawn_conditions: [ [ { "type": "terrain", "terrain_id": "soda_lake", "chance": 100 } ] ]` — searched across the whole map.
   - `improved_by: "soda_quarry"` — extracted by the "Soda Quarry" improvement.
4. **`technologies.json`** — `soda_extraction` ("Soda Extraction", prerequisite `mining`) unlocks both the resource and the improvement; `glassmaking` and `soap_making` depend on `soda_extraction`.
5. **`improvements.json`** — `soda_quarry` ("Soda Quarry", `unlock_tech: "soda_extraction"`).

---

### Unique terrain with a production bonus (`terrain_modifiers`)

Some unique terrain types give a **production bonus** to the resource extracted on them. For example, the asphalt lake (`asphalt_lake`) gives **x2 to bitumen**. The bonus is implemented through the modifier system in `data/modifiers.json` — the `terrain_modifiers` block.

**Format of `terrain_modifiers`** (an array of objects):

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `terrain_id` | string | The terrain type on which the bonus applies | `"asphalt_lake"` |
| `resource_id` | string | ID of the resource to which the bonus applies | `"bitumen_deposit_asphalt"` |
| `production_multiplier` | number | Production multiplier (multiplied with the other modifiers) | `2.0` |

```json
"terrain_modifiers": [
  {
    "terrain_id": "asphalt_lake",
    "resource_id": "bitumen_deposit_asphalt",
    "production_multiplier": 2.0
  }
]
```

**How it works:**

1. The modifier applies when exactly `resource_id` is extracted on a hex with `terrain_id` (through an improvement).
2. The multiplier is multiplied with the other modifiers (fresh water, technologies) in `CityData.get_improvement_production_multiplier`.
3. In the extended tooltip the bonus is displayed as a line like `x2.0 (Asphalt Lake)`.

**Important:** the bonus is tied to a **specific resource**, not to the terrain type as a whole. This allows having on the map at the same time:

- ordinary bitumen (`bitumen_deposit`) on plain/hills — x1;
- bitumen on the asphalt lake (`bitumen_deposit_asphalt`) — x2.

### Example: Bitumen (the asphalt lake `asphalt_lake`)

Chain:

1. **`terrains.json`** — the terrain type `asphalt_lake` with `"unique": true` and `"cluster_size": 3`.
2. **`map_generator.gd`** — during map generation, `place_unique_terrains` places an `asphalt_lake` cluster (1..`cluster_size` hexes) outside the Ring.
3. **`resources/minerals.json`** — the `bitumen_deposit_asphalt` resource:
   - `tech_required: "bitumen_extraction"` — appears on the map after the technology is researched.
   - `allowed_terrain: ["asphalt_lake"]` — only on the asphalt lake.
   - `spawn_conditions: [ [ { "type": "terrain", "terrain_id": "asphalt_lake", "chance": 100 } ] ]` — searched across the whole map.
   - `improved_by: "tar_pit"` — extracted by the same "Tar Pit" improvement as ordinary bitumen.
4. **`modifiers.json`** — `terrain_modifiers` with `terrain_id: "asphalt_lake"`, `resource_id: "bitumen_deposit_asphalt"`, `production_multiplier: 2.0`.
5. **`technologies.json`** — `bitumen_extraction` ("Bitumen Extraction") unlocks both the resource and the improvement.
6. **`improvements.json`** — `tar_pit` ("Tar Pit", `unlock_tech: "bitumen_extraction"`).

---

### `data/buildings.json` — buildings

Root key: `buildings` (an array of objects).

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `id` | string | ✅ | Unique building identifier | `"bakery"` |
| `name` | string | ✅ | Display name | `"Bakery"` |
| `work_cost` | number | ✅ | Construction cost in work | `25` |
| `additional_cost` | object \| array\<object\> | ⬜ | Additional resources for construction. Can be an object `{ "resource": amount }` (old format, backwards compatible) or an **array of objects** — then each batch requires all of its own resources, and **all** batches are required at once (AND logic). The key may begin with `@` — this is a reference to a group from `product_groups.json` | `{ "flour": 3.0 }`, `[ { "flour": 3.0, "wood": 10.0 }, { "gold": 50.0 } ]` |
| `icon` | string | ✅ | Icon file name in `icons/` | `"bakery.png"` |
| `production_slots` | number | ✅ | Number of production slots | `1.0` |
| `default_recipes` | array\<string\> | ✅ | IDs of recipes available in the building by default (see `crafts.json`) | `["bread"]` |
| `profession` | string | ⬜ | **Citizen profession id** (see `data/professions.json`). Determines what the building's worker consumes and how often, and what production bonus they receive (see the "Professions and resource consumption" section). Set on buildings where the citizen's work is a profession (currently: Library and Scriptorium — `scientist`) | `"scientist"` |
| `unlock_tech` | string | ⬜ | **Technology that unlocks construction of the building.** Until it is researched, the building is unavailable | `"cheese_making"` |
| `upgrades_into` | string | ⬜ | **Improved version of the building.** If set, a built building can be upgraded into the specified one (see the "Building upgrades" section). Available only after researching the technology that unlocks the target building | `"animal_mill"` |

---

### `data/improvements.json` — improvements

Improvements are structures on map tiles (farm, mine, pasture, etc.) that allow resources to be extracted.

Root key: `improvements` (an array of objects).

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `id` | string | ✅ | Unique improvement identifier | `"farm"` |
| `name` | string | ✅ | Display name | `"Farm"` |
| `icon` | string | ✅ | Icon file name in `icons/` | `"farm.png"` |
| `color` | array\<number\> | ✅ | Placeholder RGB color `[r, g, b]` (0–255) | `[255, 255, 0]` |
| `work_cost` | number | ✅ | Construction cost in work | `8` |
| `unlock_tech` | string | ⬜ | **Technology that unlocks the improvement.** Until it is researched, the improvement cannot be built | `"farming"` |
| `no_worker` | bool | ⬜ | **Infrastructure improvement — no worker required** (for details see the "Professions and resource consumption" section, subsection "Improvements without a worker"). Currently the flag is set only on the harbor | `true` |
| `profession` | string | ⬜ | id of the worker's profession at the improvement (see `data/professions.json`). Not set for improvements with `no_worker` | `"farmer"` |
| `conducts_water` | bool | ⬜ | Fresh water conductor (the `water_access` scheme, works after "Irrigation") | `true` |
| `water_body_harbor` | bool | ⬜ | The improvement unlocks the water resources of its own water body (the `harbor_access` scheme). Currently — only on the harbor | `true` |
| `requires_harbor` | bool | ⬜ | Construction requires a harbor on the same water body (the `harbor_access` scheme). Currently — only on fishing boats | `true` |

For details of the water resource access scheme, see the "Water resource extraction (the `harbor_access` scheme)" section.

---

### `data/crafts.json` — production recipes

Root key: `crafts` (an array of objects).

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `id` | string | ✅ | Unique recipe identifier | `"bread"` |
| `name` | string | ✅ | Display name | `"Bread"` |
| `produced_in` | array\<string\> | ✅ | IDs of buildings where the recipe is available. `"*"` — available everywhere | `["bakery"]`, `["*"]` |
| `resources` | object \| array | ✅ | Input resources. **Classic form** — `{ "resource": amount }`; the key may begin with `@` — this is a reference to a group from `product_groups.json`. **Alternatives form** — an array of terms combined with AND (see the "Alternative ingredients" subsection) | `{ "flour": 1 }`, `{ "@millable_grains": 1 }`, `[[ {"iron": 20}, {"meteorite_iron": 20}], {"charcoal": 10}]` |
| `result` | object | ✅ | Output resources: `{ "resource": amount }` | `{ "bread": 1 }` |
| `display_result` | object | ⬜ | **For UI only.** The recipe's pseudo-output: what is drawn as "resources → result" instead of `result` when the output is not a warehouse good (science; in the future — health, happiness, and similar pseudo-resources). Not read by the mechanics (craft container, storage, planned production) | `{ "science": 1 }` |
| `time` | number | ✅ | **Craft time in seconds.** How many seconds the slot accumulates time for one output of `result` (see the "Recipe time (`time`)" subsection) | `5.0` |
| `description` | string | ⬜ | Recipe description | `"Makes a set of tools for craftsmen"` |
| `unlock_tech` | string | ⬜ | **Technology that unlocks the recipe.** Until it is researched, the recipe is hidden from the list | `"cheese_making"` |

> **A note on `@`:** if a key in `resources` or `result` begins with `@`, it means "any product from the group". For example, `"@millable_grains": 1` — "1 unit of any grain crop from the `millable_grains` group".

#### Alternative ingredients (arrays in `resources`)

Instead of creating a goods group (`product_groups.json`), a recipe can list **interchangeable ingredients** directly in the `resources` field. The format is an array of terms combined with **AND**; a term is a dictionary `{ "resource": amount }` or an **array** of such dictionaries combined with **OR**:

```json
"resources": [
  [ { "iron": 20 }, { "meteorite_iron": 20 } ],   // 20 iron OR 20 meteorite iron
  { "charcoal": 10 }                              // AND 10 charcoal — unconditionally
]
```

- **OR inside a term:** any single option suffices; the options do not need to be mixed, but if the first is insufficient within the tick, the remainder is drawn from the next (the order of the list sets the preference — chosen by the data author).
- **AND between terms:** all terms are needed at once; a shortage of any one "freezes" the container, as usual.
- The keys inside the options may be the same as in the classic form: a product, a raw resource, or `@group`. The amount can even differ between options — the one declared for the chosen option is used.
- The classic form `{ key: amount }` is fully compatible: it is equivalent to an array of single-element terms.
- The validator (`data_validator.gd`) checks each option of each term as an ordinary reference to a resource/group.

Implementation: normalization — `GameData.parse_craft_resources()` / `GameData.craft_alternatives()` (the single source of the form), consumption — `CraftContainer` (slot type `"alternatives"` in `scripts/craft_container.gd`), planned demand — `CityData.get_building_planned_consumption()`, town trade pools — `TownEconomy.is_recipe_ready()` / `_readiness_of()` / `_missing_representatives()`. Test: `tests/test_craft_alternatives.gd` (run: `godot --headless --path . --script res://tests/test_craft_alternatives.gd`).

#### Recipe time (`time`)

Crafting in a building slot runs as a **continuous stream** (`scripts/craft_container.gd`, class `CraftContainer`): over `time` seconds the slot consumes all of the recipe's `resources` and outputs all of the `result` — that is, it is not "one batch every `time` seconds" but two constant rates (`resources/time` units/sec on input, `result/time` units/sec on output; the tick step is `SIMULATION_TICK = 1` sec).

- Each building slot has its own container. They live in the building record under the `slot_containers` key in `CityData.city_built_buildings[i]` (an array of `CraftContainer`), so they go into the save along with the cities. The array is created lazily and fitted to the current number of slots (`CityData.get_slot_containers()`): buildings after an upgrade and new slots receive an empty container.
- **Fractional rates are exact:** consumption and output go through sub-unit accumulators, so the remainder carries over between ticks and the average rate does not drift (21 clay in 5 sec → we alternate 4 and 5 units). When a cycle completes, the fractional tail is topped up, so exactly `result` arrives in storage per cycle.
- **At most one "cycle completion" per tick:** the actual rate is always limited by the simulation step, so with `time < SIMULATION_TICK` the slot fits into one cycle per tick.
- **No raw materials — the container "freezes":** if the ingredients are insufficient, they are not accumulated, and progress is capped by the fill level, not by time. The container **does not accumulate a time debt**, so after raw materials are delivered, exactly one portion of the result (`result/time`) is emitted in one tick, not a "volley" for all the accumulated seconds.
- **Changing the recipe in a slot** recreates the container from scratch (`CityData._ensure_slot_container()`, `reset_slot_progress()` is called from `building_panel.gd`) so that the old cycle is not "recounted" using the new `time`.
- If the `time` field is absent or `<= 0`, the recipe behaves as "per tick" (`get_craft_time()` returns the tick step, `CraftContainer` — 1 sec).
- **UI:** the building panel (`building_panel.gd`) shows a craft progress bar for slots with `time > SIMULATION_TICK` (`CityData.get_slot_progress_ratio()` = `min(fill level, time/craft_time)`), updated in `_process()` without rebuilding the panel. The old getters `get_slot_progress()` / `get_slot_progress_value()` return `ratio * craft_time` and are kept for the sake of UI that has not yet been migrated to `completion_ratio()`.
- The planned consumption and planned production of buildings carry the recipe's `interval = time`, so the tooltip of the "Resources" tab shows demand/output as "units/sec", while the row's dynamics bring them to the tick (see the subsection "Planned consumption in the 'Resources' tab").

---

### `data/products/*.json` — products (storage)

Files:

- `products/products.json` — tools, weapons, clothes, oil, wine
- `products/materials.json` — materials (hide, wool, flour, etc.)
- `products/drinks.json` — drinks
- `products/fruits.json` — fruits
- `products/construction_materials.json` — construction materials
- `products/other.json` — other (raw resources, fodder, flowers)

Root key: `resources` (an array of objects).

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `id` | string | ✅ | Unique product identifier | `"flour"` |
| `name` | string | ✅ | Display name | `"Flour"` |
| `type` | string | ✅ | Entity type. For products it is always `"product"` | `"product"` |
| `category` | string | ✅ | Category for the "Resources" tab (see `categories.json`) | `"material"` |
| `icon` | string | ✅ | Icon file name in `icons/` | `"flour.png"` |
| `unlock_tech` | string | ⬜ | **Technology that unlocks the product.** Until it is researched, the product is unavailable | `"weaving"` |
| `unlock_improvement` | string | ⬜ | **Only in `products/other.json`.** Identifier of the improvement that must be built at least once so that this resource can start being produced. For example, the "fodder" resource starts being produced on farms only after the first pasture is built | `"pasture"` |

> **Science (`science`)** — a virtual placeholder product that is **not shown on the "Resources" tab** (filtered in `scripts/resources_tab.gd`). There is no longer a science pool: buildings' science is added directly to the research rate, so the product is not added anywhere. The definition is kept for compatibility with old saves (the remainder in storage is inert). For details, see the "Science: production and research" section below.

---

## Building upgrades

A building can have an improved version — the `upgrades_into` field in `data/buildings.json` (for example, `hand_mill` → `animal_mill`). The mechanics are described below.

### When an upgrade is available

The "Upgrade" button (a thick blue up arrow) appears in the building's production slot only when **all** of the following conditions are met:

1. The building has the `upgrades_into` field set.
2. The technology that unlocks the **target** building (its `unlock_tech`) has been researched.
3. An upgrade of this instance is not yet in progress.

### Upgrade process

- **Start**: the "Upgrade" button in the production slot. The target building's `additional_cost` is deducted instantly (atomically: if there is not enough, nothing is deducted, and the reason is shown in the message line). The overall limit of concurrent constructions is taken into account (equal to the number of citizens). If the target's `work_cost` is zero or the debug flag "Ignore building requirements" is enabled, the upgrade happens instantly.
- **Upgrade time**: the building works as usual. Work accumulates in the common pool (build_manager), and a progress bar is visible in the production slot instead of the "Upgrade" button.
- **Completion**: the building is replaced with the improved version **at the same index** in `city_built_buildings` (the worker stays attached — the "working/paused" state carries over by itself).

### Carrying settings over to the improved version

- **Quality priority** (`quality_priority`) is carried over unchanged.
- **Slots (recipes)**: for each slot it is checked whether the current recipe can be executed in the target building (`can_craft_in`). A compatible recipe is preserved; an incompatible one (for example, `grind_grain_hand` in `animal_mill`, where it does not exist) is replaced with the new version's default recipe or `empty`. Empty slots stay empty.
- **The "working/paused" state**: carries over automatically, because the worker is attached to the building's index in the city, and the index does not change.
- **Citizen profession**: is determined by the building (the `profession` field in `data/buildings.json`) and is recalculated automatically after the replacement — the index and the citizen do not change, so the new version's profession consumption and bonus take effect on the nearest tick.

### Display in the list of built buildings

The tooltip of the button in the list of built buildings (`buildings_tab`) shows a bulleted list of states with color coding:

| State | Format | Color |
| --- | --- | --- |
| working | `working: N` (the number of buildings with a worker and non-empty slots) | green |
| idle | `idle: N` (there is a worker, all slots are empty) | yellow |
| not working | `not working: N` (without a worker) | red |
| upgradeable | `upgradeable: N` (the number of instances available for upgrade) | blue |

The colors use the same palette as the list's button statuses and the labels of buildings under construction. The tooltip updates live on every game tick — states change right under the cursor (assigning workers, starting/completing an upgrade, researching a technology).

### Related files

| File | What is affected |
| --- | --- |
| `data/buildings.json` | The `upgrades_into` field |
| `scripts/build_manager.gd` | The methods `start_building_upgrade`, `get_building_upgrade_by_index`; the `building_upgrade_completed` signal; the upgrade is stored in `active_building_builds` with the `is_upgrade` flag |
| `scripts/CityData.gd` | `get_building_upgrade_target`, `get_building_upgrade_data`, `can_upgrade_building`, `start_building_upgrade(idx)`, `complete_building_upgrade(idx, upgrade_to)` |
| `scripts/building_panel.gd` | The "Upgrade" button with a cost tooltip (resource icons), the upgrade progress bar |
| `scripts/buildings_tab.gd` | Counting `upgradeable` in `_group_buildings`, the list's colored tooltip |
| `scripts/ui_helpers.gd` | The `built_tooltip_panel` panel for the colored tooltip |
| `scripts/main_map.gd` | The `_on_building_upgrade_completed` handler |

---

## Science: production and research

Science is not a warehouse resource but a **research rate**: all sources add up into a single quantity (points/sec), which is credited directly to the progress of the current research and is shown on the "Technologies" tab (the label "Science: X/sec"). There is no science pool and no stockpiling: while nothing is being researched, science output is simply not credited.

### Research rate

`CityData.get_science_rate_per_sec()` — the direct sum of the sources:

1. **Base income:** `BASE_SCIENCE_PER_SEC = 1.0` points/sec always (even without libraries) — so that the early game is not blocked.
2. **Fixed output of science buildings:** the `additional_yield.science` field in `data/buildings.json` — points/sec while the building is working (there is a citizen and a non-empty slot; the recipe does not matter): Library +1, Scriptorium +3 (the future Academy — +5).
3. **Science from writing mediums:** the weighted average `special_yield.science` of the mixture of mediums that the building actually consumes: clay tablets +1, wax tablets +1, papyrus +2, parchment +3, silk +3, paper +5. The `special_yield` value of a medium is its contribution to the scholars' working rate (papyrus in storage = +2 points/sec). While there is no composition, the contribution is 0.
4. **Writing implements bonus:** while the Scholar has enough of the writing set (`data/consumption.json`, +25%), the sum of items 2–3 for the building is multiplied by 1.25. The base (item 1) is not affected by the bonus.

The city formula: `total = BASE + Σ_buildings (fixed_building + medium_mixture) × consumption_bonus`.

The buildings' contribution is recalculated once per simulation tick in `CityData.do_tick()` and written to the `science_buildings_rate_per_sec` cache. The composition of the mixture is accounted for as a weighted average over the actually consumed mediums: the composition accumulates by pid in the slot's container (`consumed_pids`, survives the cycle reset), so each medium gives the science of its own `special_yield`.

**The "Science" recipe does not enter the science rate.** Neither the recipe's `required` nor its `time` participates in the calculation: the recipe is merely a "pass". While raw materials are available (the slot's `missing` is empty), the scholars work; the recipe's input only sets the fuel consumption from storage (20 units of mediums per 5 sec = 4 units/sec), and not the science rate. It does not matter how many mediums are stockpiled — what matters is *which* `special_yield` the consumed medium has.

### The "Science" recipe (`data/crafts/pseudo.json`)

```json
{
  "id": "science",
  "name": "Science",
  "produced_in": [ "library", "scriptorium" ],
  "resources": { "@writing_mediums": 20 },
  "result": { },
  "display_result": { "science": 1 },
  "time": 5.0,
  "unlock_tech": "writing"
}
```

- **Input:** 20 units of any good from the `writing_mediums` group ("Writing Medium") per cycle (5 sec) — this is only the scholar's **fuel consumption** (4 units/sec); the recipe itself does not enter the science rate (see "Research rate" above): what matters is which medium's `special_yield` is consumed, not how much and how fast.
- **Output:** there is no real output (`result` is empty) — science is not created as a good but goes directly into the research rate (see above). The `display_result` field is a hint to the interface: in all recipe lists and in the building slot it renders as "Writing Medium → Science".
- **Buildings:** Library (`library`), Scriptorium (`scriptorium`).

### The "Library" building (`data/buildings.json`)

```json
{
  "id": "library",
  "name": "Library",
  "work_cost": 50,
  "additional_cost": [ { "planks": 120 } ],
  "profession": "scientist",
  "icon": "library.png",
  "production_slots": 1.0,
  "unlock_tech": "writing",
  "default_recipes": [ "science" ],
  "additional_yield": { "science": 1 }
}
```

- **1 production slot**, the default recipe is "Science"; the citizen's profession is Scholar.
- `additional_yield.science` = **+1 science point per second** while a scholar works in the library.
- Requires the researched technology "Writing" (`writing`); availability in the "Buildings" interface is determined via `unlock_tech`.

### Crediting progress

- `CityData.tick_research_science_continuous(delta)` is called every frame from `main_map._process`: `research_science_accumulated += get_science_rate_per_sec() × delta` — the progress bar is smooth, the rate updates once per tick.
- If there is no current research, science is not credited and not accumulated (the buildings' output is lost "for nothing").

### Display

- The science rate is shown on the **"Technologies"** tab (`SciencePoolLabel`, "Science: X/sec").
- Hovering the cursor over the "Science: X/sec" label shows a **breakdown tooltip**, whose arithmetic agrees with the label: "Base", for each working science building — "Building" (the net `additional_yield.science`), "Scholarly materials" (the net weighted average `special_yield` of the consumed mixture, with product names), "Consumption bonus" (+25% with the names of the bonus products, e.g. "(Writing Set)") and "Total". The building total = (Building + Scholarly materials) × Consumption bonus. The data source is the `CityData.science_breakdown` cache (filled once per tick in `do_tick()`, the getter `get_science_breakdown()`); the tooltip updates live (`tech_tree.update_progress`).
- On the "Resources" tab science is **hidden** (a special skip for `"science"` in `resources_tab.gd`).

### Saving

Only the accumulated progress of the current research is saved (`research_science_accumulated`). The science pool and its "drain" (`science_drain_accum`, `SCIENCE_DRAIN_PER_SEC`) have been removed from the code and the save; the `city_storage["science"]` remainder from old saves is inert (the product is hidden and spent nowhere).

## Limiting technology research by eras

You can research **only technologies of the current and previous eras**. Technologies of the next era are unavailable, even if all their `prerequisites` are met.

- **The "current era" parameter:** `CityData.current_era_index` (an index in `GameData.eras` from `data/eras.json`). The initial value is `0` (Ancient).
- **Checks:**
  - `CityData.is_tech_era_allowed(tech_id)` — the technology's era ≤ the current one (a technology without a known era is not blocked);
  - `CityData.start_research()` rejects technologies of future eras with the `research_error` message "\"X\" belongs to the next era…";
  - `CityData.is_tech_available()` takes the era into account — the technology tree (`tech_tree.gd`) marks such buttons with the tooltip `[Era: … — advance to it first]`;
  - `CityData.get_tech_study_chain()` (the "Research …" button in special actions) does not include technologies of future eras.
- **Synchronization:** `main_map.current_era` (the map's era index) — when advancing an era (`advance_to_next_era`) and when loading a save, both values are synchronized. There is currently one condition for advancing: a built Market for advancing from the Ancient to the Antiquity era.
- **Saving:** `current_era_index` is saved in `SaveManager` (and duplicated in `map_state.current_era`); old saves without the field are restored from the map state.

---

### Service files

---

#### `data/categories.json` — resource categories

Root key: `categories` (array of objects).

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `id` | string | Unique category identifier | `"food"` |
| `name` | string | Display name | `"Food"` |

Categories are a purely visual split for the "Resources" tab in the city. The single exception: all resources of the `food` category are pooled together and counted as **Food** in storage. On the tab each category is rendered as a header — a solid line, the name centered in the column, a line again (the shared `UiHelpers.build_category_header()`, the same header in the town window too); the order of categories follows this file.

---

#### `data/groups.json` — resource groups (for bonuses)

Root key: `groups` (array of objects).

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `id` | string | Unique group identifier | `"cattle"` |
| `name` | string | Display name | `"Cattle"` |

Groups are used by the **diversity bonus** mechanic (see `bonuses.json`) and when listing domesticated species. The `group` and `subgroup` fields on resources reference these IDs.

> **Do not confuse with `product_groups.json`!** Here the groups are for bonuses; there they are for substitution into recipes.

---

#### `data/product_groups.json` — goods groups (for recipes)

Root key: `product_groups` (array of objects).

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `id` | string | Unique group identifier | `"millable_grains"` |
| `name` | string | Display name | `"Millable Grains"` |
| `products` | array\<string\> | IDs of the goods in the group | `["wheat", "rye", "barley"]` |

Groups are used in recipes (`crafts.json`) for substitution: the key `"@millable_grains"` in `resources` means "any goods from this group".

> **Do not confuse with `groups.json`!** Here the groups are for substitution into recipes; there they are for diversity bonuses.

---

#### `data/eras.json` — eras

Root key: `eras` (array of objects).

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `id` | string | Unique era identifier | `"ancient"` |
| `name` | string | Display name | `"Ancient"` |

Used in `technologies.json` (the `era` field).

##### Splitting the technology tree by eras

The technology tree (`scripts/tech_tree.gd`) is visually split into **eras**:

- Each technology in `data/technologies/*.json` has an `era` field (an id from `eras.json`).
- The tree's columns are built from the dependencies (`prerequisites`), and a column's era is determined **by the majority** of the technologies in it (see `_column_era` in `tech_tree.gd`).
- Consecutive columns of the same era are merged into an **era group** (`_compute_era_groups`).
- Above each group an **era name header** is drawn (for example, "Ancient"), and between groups a thick **vertical divider line**.
- The headers and lines scroll together with the tree (they are drawn inside `_inner`).

**Important:** the columns are built from the dependencies (`prerequisites`) and then normalized by era (`_normalize_era_columns` in `tech_tree.gd`): the technologies of each era are shifted so that eras follow left to right in the order from `eras.json`. This guarantees that even if a late technology (for example, "Parchment" from Antiquity) would fall into the ancient column by its dependencies, it will be moved to a separate column further right — and a vertical divider line will appear between the groups. The dependency-based layout (barycenter) within each era is preserved.

Display parameters (constants in `tech_tree.gd`):

| Constant | Description |
| --- | --- |
| `ERA_LABEL_HEIGHT` | Height of the strip above the columns for the era headers |
| `ERA_LABEL_WIDTH` | Width of the era header |
| `ERA_LINE_COLOR` / `ERA_LINE_WIDTH` | Color and thickness of the vertical divider |

##### Icons of unlocked content on technology buttons

On each button of the technology tree a row of **small icons (16×16)** is displayed at the bottom — everything the technology unlocks. The technology's name is pressed against the **top edge** of the button. Icon sources (collected in `_get_unlock_items` in `tech_tree.gd`, drawn by `_add_unlock_icons`):

1. **Buildings** — records in `data/buildings.json` with `unlock_tech == <technology id>`; the icon is taken from the `icon` field, the tooltip from `name`.
2. **Improvements** — records in `data/improvements.json` with `unlock_tech == <id>`; likewise (`icon` / `name`).
3. **Special actions** — records in `data/special_actions.json` with `unlock_tech == <id>` (for example, "Clear Forest", "Drain Water"); likewise (`icon` / `name`).
4. **Modifier effects** — records in the `tech_modifiers` block of `data/modifiers.json` with `tech_id == <id>`: if the record has the `icon` field (a file in `res://icons`) and the `name` field (the tooltip caption) set, the effect's icon is drawn. Example:

```json
{ "tech_id": "plow", "icon": "farm.png", "name": "Farms: +50% production", "production_multiplier": { "farm": 1.5 } }
```

1. **Arbitrary effects** — an optional `unlock_effects` field on the technology itself (`data/technologies/*.json`), for effects of any kind that have no registry of their own:

```json
"unlock_effects": [ { "icon": "farm.png", "name": "Farms: +50% production" } ]
```

Display rules:

- Duplicates are filtered out by the (icon, tooltip) pair: the same thing is not drawn twice.
- Items without an icon, or with an icon whose file is not found, are skipped.
- Tooltips: hovering over an **icon** shows its caption (the building's/improvement's name or the effect's caption); hovering over the **rest of the button** shows the technology's general tooltip (description, science, state).
- The icons do not intercept clicks (`mouse_filter = PASS`) — clicking the button works as before (start research).

#### Icon registry (`IconRegistry`)

An icon's file name in all the data (`data/*.json`) is **only the name**, without a path: `wheat.png`, not `resources/raw/plants/wheat.png`. The path is looked up in `res://icons` by file name across all subfolders. The only place where this lookup happens is the autoload `scripts/icon_registry.gd` (`IconRegistry` in `project.godot`).

| What | How |
| --- | --- |
| `IconRegistry.has("wheat.png")` | whether such a file exists |
| `IconRegistry.icon_path("wheat.png")` | the full `res://` path, or `""`. Needed where the engine expects a **path** rather than a texture: the `[img=…]` tag in BBCode. The method's name is not `get_path()`: on `Node` that method is already taken for returning a `NodePath` |
| `IconRegistry.get_texture("wheat.png")` | a `Texture2D` from the shared cache, or `null`. The main way: we draw icons via `TextureRect` / `Button.icon` |
| `IconRegistry.count()` | how many icons are in the index (test) |

Indexing rules (the same across the whole project):

1. The index is built **once per game**, lazily — on first access.
2. Service files are skipped: `*.import`, `*.remap`, anything starting with a dot. Previously they took up half of the index (288 of 576 entries).
3. **A duplicate name does not overwrite** the first path but is added to a list; at the end a `push_warning` reports all duplicates at once. If an image with the same name sits both in the root and in a subfolder, the first one in traversal order wins, and the second is silently lost.
4. A missing icon is **not an error**: `get_texture` returns `null`, and the calling code simply does not set an icon. The data deliberately contains references to icons that have not been drawn yet (future goods and professions).

The texture cache is shared across the whole project. The exception is `map_renderer.icon_textures`: there the dictionary stayed **local**, because it is a hot `_draw` path (accessed for every hex every frame), and it is filled from the registry (`_cache_icon`).

**Invariant:** do not create your own traversal of `res://icons` or your own path dictionary. If you need a path or a texture — ask `IconRegistry`. Otherwise the very problem the registry exists for will come back: an image in the UI will start depending on which module set the path first.

**Test.** `tests/test_icon_registry.gd` (headless): it compares the index against the real contents of `res://icons` (the truth is the file system itself, not the test's constants), catches `.import`/hidden files and duplicate names, checks the idempotency of `build()`, the shared texture cache and the behavior on an unknown/empty name. The presence of an icon for every reference in `data/*.json` is **not checked** on purpose — that would forbid adding data ahead of time; the test prints the number of such references for information.

---

#### `data/terrains.json` — terrain types (relief)

Root key: `terrains` (array of objects).

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `id` | string | Unique terrain identifier | `"plain"` |
| `name` | string | Display name | `"Plain"` |
| `color` | array\<number\> | Placeholder RGB color `[r, g, b]` (0–255) | `[144, 238, 144]` |
| `move_cost` | number | Movement cost | `1` |
| `expansion_cost` | number | Cost of expanding influence | `50` |
| `work_cost_mult` | number | ⬜ Multiplier for the work cost of building improvements on this terrain. If not set, it is computed by a formula based on `move_cost` in `map_helpers.gd` | `2.0` |
| `icons` | array\<string\> | Terrain icon variants in `icons/terrain/` | `["plain_1.png", "plain_2.png", "plain_3.png"]` |
| `unique` | boolean | ⬜ **For unique types only.** `true` — the type does not take part in the Voronoi algorithm and is placed by a separate function `place_unique_terrains` | `true` |
| `cluster_size` | number | ⬜ **For `unique: true` only.** Maximum cluster size in hexes (the actual size is a random `1..cluster_size`). Read by the function `place_unique_terrains`; default `3` if the field is not set | `3` |
| `cover_chance` | object | **Cover generation weights** for this terrain: `{ "cover_id": weight, ... }`. The greater the weight, the higher the chance of the cover appearing | `{ "none": 60, "sparse_forest": 15, "forest": 25 }` |
| `fresh_water_source` | bool | ⬜ **A direct source of fresh water.** If `true`, a hex of this type (and its coastal neighbors) gives the `water_access` scheme the `"direct"` status without researching technologies. Currently only `lake` has it. To add a new fresh-water terrain (a spring, a hot spring, etc.), it is enough to set this flag. For details, see the section "Fresh-water sources: the `fresh_water_source` flag" | `true` |

`cover_chance` is read in `map_generator.gd` during map generation: for each hex a random value proportional to the weights is "rolled". If the field is absent or empty, the hex gets `cover: "none"`.

Used in `resources/*.json` (the `allowed_terrain` field).

---

### Swamps and marshes

The swamp is a base terrain (`swamp`) that takes part in the Voronoi algorithm alongside the plain, hills, lakes and mountains. Swamps can have any type of cover: `none`, `sparse_forest`, `forest` or `reeds` (reeds). The `terrain_config` configuration in `data/map_config.json` sets the share of swamps on the map (`density`, 5% by default) and the average cluster size (`target_cluster`, an upper limit — 5 hexes by default, i.e. swamps form small scattered patches).

Marshes are a post-processing pass over the terrain after Voronoi in `map_generator.gd`. Around every lake `lake` **and every sea `sea`**, each neighboring plain hex (`plain`) has a ~45% chance (the constant `MARSH_CHANCE`) of turning into a swamp — this forms a ring one hex wide around the water. Around seas, marshes can also form on the **beach** (`beach`) — a waterlogged coastal zone. Such a hex is additionally marked with a temporary `_is_marsh` flag, and during cover generation its `cover` is forced to `reeds`.

The resource "Clay" (`clay_deposit`) in `data/resources/minerals.json` has been extended and can now also spawn on swamps: `allowed_terrain` now includes `"swamp"`, and `allowed_cover` includes `"reeds"`.

---

### Seas and beaches

The sea (`sea`) and the beach (`beach`) are two new terrain types that **do not take part** in the Voronoi algorithm (they are not in `terrain_config`). The sea is generated as a **mask** before Voronoi and reapplied over the result, so that Voronoi does not overwrite it.

#### Terrain types

| Type | `move_cost` | `expansion_cost` | `work_cost_mult` | Description |
| --- | --- | --- | --- | --- |
| `sea` | `999` (impassable) | `0` | `1.0` | Open water. Impassable for units, but a **buildable** territory (fishing boats and the like can be placed) |
| `beach` | `1` | `50` | `1.0` | Coast. Passable, an ordinary buildable territory |

Both types have `cover_chance: { "none": 100 }` — no cover is generated on them.

#### Configuration (`data/map_config.json`, the `sea` block)

```json
"sea": {
  "mode": "edge",              // "none" (no seas) | "edge" (coastal strips with bays) | "noise" (height field)
  "sides": [1, 2],             // the [min, max] range for the number of cardinal directions with a sea; [0,0] — no sea
  "beach": true,               // true: land adjacent to the sea becomes a beach (beach)
  "max_sea_depth": 8,          // the depth limit of the sea from the map edge (in hexes), so that the sea does not "eat up" the map

  // --- "edge" mode only ---
  "edge_width_min": 0,         // minimum strip width (in hexes); 0 lets the shore break into bays
  "edge_width_max": 7,         // maximum strip width (in hexes)
  "edge_envelope_strength": 0.7, // bays: 0 = a solid strip from edge to edge, ~0.7 = a bay in the middle of a side and land at the edges, 1 = only the peak of the bay

  // --- "noise" mode only ---
  "noise_sea_level": 0.0,      // the "land/sea" threshold: elevation <= threshold = sea
  "noise_strength": 0.35,      // the amplitude of the height noise (raggedness of the shore, islands)
  "noise_edge_gradient": 1,    // continentality: 0 = islands everywhere, 1 = sea strictly at the edges
  "noise_city_bump": 0.5,      // the "hill" of elevation around the city: guarantees a starting continent
  "noise_city_bump_radius": 8  // the radius of guaranteed land around the city (in hexes)
}
```

| Field | Type | Description |
| --- | --- | --- |
| `mode` | string | `"none"` — no seas; `"noise"` (option A) — elevation = gradient from the edge + noise + city_bump, land = `elevation > noise_sea_level`; `"edge"` (option B) — a strip of sea along the chosen sides, the width being smooth 1D noise |
| `sides` | array\<number\> | The `[min, max]` range for the number of randomly chosen cardinal directions that will have a sea (`"east"`, `"west"`, `"north"`, `"south"`). `[x,x]` — a fixed number of sides. `[0,0]` — no sea is generated |
| `beach` | boolean | `true`: land adjacent to the sea becomes a beach |
| `max_sea_depth` | number | The depth limit of the sea from the map edge (in hexes): an upper bound for the sea's width |
| `edge_width_min` / `edge_width_max` | number | For `mode: "edge"`: the range of the sea strip's width (in hexes) |
| `edge_envelope_strength` | number | For `mode: "edge"`: how pronounced the bays are (0 = a solid strip, 1 = only the peak of the bay) |
| `noise_sea_level` | number | The "land/sea" threshold for the "noise" option |
| `noise_strength` | number | The amplitude of the height noise for the "noise" option |
| `noise_edge_gradient` | number | Continentality: 0 = islands everywhere, 1 = sea strictly at the edges |
| `noise_city_bump` | number | The "hill" of elevation around the city, guarantees a starting continent |
| `noise_city_bump_radius` | number | The radius of guaranteed land around the city (in hexes) |

#### Generation

1. **`map_generator.gd`** — `_apply_sea()` is called at the start of `generate_map` (before Voronoi). It builds the sea mask according to the chosen mode, marks hexes with a temporary `_is_sea` flag, and marks the land adjacent to the sea with the `_is_beach` flag (if `beach: true`).
2. After Voronoi the mask is **reapplied** over the result (by the `_is_sea` / `_is_beach` flags), so that Voronoi does not overwrite the sea/beach.
3. **Marshes** are also generated around seas (as around lakes): neighboring plains have a ~45% chance of becoming marshes.
4. The **exit corridor** (`_ensure_outward_corridor`) breaks through the sea as it does a lake (the sea is not an obstacle to the breakthrough), and the coast (`beach`, `move_cost: 1`) is a valid exit.

#### Rivers and seas

- **Main rivers** can flow into seas just as into lakes (mouths = lakes + seas).
- **Tributaries** do not flow into seas (nor into lakes) — only into main rivers or other tributaries.
- Rivers **do not flow over the sea**: sea hexes and their neighbors are included in `restricted_hexes` in `river_manager.gd`.

#### Building on the sea

The sea is an ordinary buildable territory. A sea hex is part of the Influence Ring (via `in_influence`), and improvements (for example, fishing boats) can be built on it through the standard mechanism. `expansion_cost: 0` means the sea is cheap/free to claim when expanding territory. `work_cost_mult: 1.0` — building on the sea is no more expensive than on the plain.

#### City

`ensure_city_valid_terrain` (`map_helpers.gd`) guarantees that the city does not end up on a sea/beach: if the city is generated/loaded on `sea`/`beach` (or a mountain/lake), it is turned into a plain.

---

#### `data/covers.json` — cover (forest)

The `reeds` cover ("Reeds") is forced on swamps around lakes (marshes) and can roll on swamps with a random cover.

Used in `resources/*.json` (the `allowed_cover` field).

Root key: `covers` (array of objects).

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `id` | string | Unique cover identifier | `"forest"` |
| `name` | string | Display name (shown to the player, e.g. "Forest") | `"Forest"` |
| `color` | array\<number\> | Placeholder RGB color `[r, g, b]` (0–255) for the fallback | `[34, 139, 34]` |
| `alpha` | number | Overlay opacity (0.0 – 1.0) | `0.45` |
| `move_cost_bonus` | number | Additional movement cost from the cover (currently 0 — the forest does not slow you down, unlike the earlier terrain-forest with `move_cost: 1`) | `0` |
| `wood_yield` | number | ⬜ Wood output from the cover: how many units of the "Wood" goods per tick the "Woodcutter's Camp" (`lumberjack_hut`) gives. A missing field = 0 (the camp cannot be built). ANY cover with `wood_yield > 0` is taken into account — new forest covers (jungle, taiga, etc.) just need to be described here, no code change needed | `2` |
| `fresh_water_source` | bool | ⬜ **A direct source of fresh water.** If `true`, a hex with this cover (and its coastal neighbors) gives the `water_access` scheme the `"direct"` status without researching technologies. Currently only `oasis` has it. To add a new fresh-water cover (for example, a "marsh puddle"), it is enough to set this flag. For details, see the section "Fresh-water sources: the `fresh_water_source` flag" | `true` |
| `icons` | array\<string\> | Overlay icons in `icons/terrain/` (drawn on top of the terrain; if empty, a colored polygon) | `["forest_1.png", "forest_2.png", "forest_3.png"]` |

##### Woodcutter's Camp and wood output (the `wood_yield` scheme)

The "Woodcutter's Camp" (`lumberjack_hut`, unlocked by the "Wood Processing" technology) works in two modes:

1. **On a wood resource** — if the hex has a raw resource with `improved_by: "lumberjack_hut"`, the camp extracts it like an ordinary improvement through the general production flow (the specific goods are set in the resource's `produces`).
2. **On an empty forest hex** — if there is no resource and the cover yields wood (`wood_yield > 0`), the camp produces the "Wood" goods (`wood`): output = the cover's `wood_yield` × the multipliers of the improvement and of the "Lumberjack" profession. Currently: sparse forest — 1, forest — 2.

The camp can be built on an empty dry hex (not a mountain, not water, not a swamp/marsh, not impassable terrain with `move_cost >= 999`) with a cover of `wood_yield > 0`. Helpers: `MapHelpers.get_cover_wood_yield()` / `MapHelpers.can_build_lumberjack_hut()` (`scripts/map_helpers.gd`); production is in the `main_map.gd` tick, availability and preview are in `control_panel.gd` and `map_tooltip.gd`.

Wood is processed in the city building "Sawmill" (`sawmill`) by the "Saw Boards" recipe (`sawing`): 2 wood → 1 "Planks" (`planks`).

Used in `resources/*.json` (the `allowed_cover` field).

---

#### `data/special_actions.json` — special actions on the map

Special actions are actions performed on map hexes (clear forest, forage, demolish improvements, etc.). They are implemented through the work system `build_manager`, but they are not improvements.

Root key: `special_actions` (array of objects).

| Field | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `id` | string | ✅ | Unique special action identifier | `"clear_forest"` |
| `name` | string | ✅ | Display name | `"Clear Forest"` |
| `action_type` | string | ⬜ | Action type. `"terrain"` (default) — transforms the terrain; `"cover"` — changes the cover; `"forage"` — gathers a resource; `"demolish"` — demolishes an improvement; `"road"` — a road from the city to the specified hex | `"cover"` |
| `icon` | string | ⬜ | The file name of the action's icon in the `icons/` folder (taken from the `IconRegistry` by file name; subfolders do not matter). If it is not set or the file is not found, the button shows "?" | `"forest_1.png"` |
| `source_terrain` | string | ⬜ | For `action_type: "terrain"`. A single terrain type the action applies to (see `terrains.json`). The alternative is the `source_terrains` list | `"swamp"` |
| `source_terrains` | array<string> | ⬜ | For `action_type: "terrain"`. A list of terrain types the action applies to as a single action (for example, draining swamps and marshes) | `["swamp", "marsh"]` |
| `source_cover` | array\<string\> | ⬜ | For `action_type: "cover"`. The covers the action applies to (see `covers.json`). The action is unavailable if the hex has a resource or an improvement | `["forest", "sparse_forest"]` |
| `result_terrain` | string | ✅ | The terrain type the source is transformed into. The value `"dont_change"` means the terrain type does not change | `"plain"`, `"dont_change"` |
| `result_cover` | string | ⬜ | For `action_type: "cover"`. The cover that will be set after completion (for example, `"none"` — clear forest) | `"none"` |
| `work_cost` | number | ✅ | The cost in work. For `action_type: "road"` this is the price **per one new section of the route** (per hex), not for the action as a whole: total = `work_cost` × the number of new segments | `22` |
| `unlock_tech` | string | ⬜ | The technology that unlocks the action. Until it is researched, the context menu shows a "Research X" item | `"metal_processing"` |

**Action types (`action_type`):**

- `"terrain"` (default) — transforms one terrain type into another. Applies if the hex has `source_terrain` (or is in the `source_terrains` list) and has no improvement. Example: draining swamps and marshes.
- `"cover"` — changes the hex's cover (`source_cover` → `result_cover`). Applies if the hex's `cover` is in `source_cover` and the hex has **no** resource or improvement (clearing forest with a resource/improvement is forbidden). On completion only `cover` changes. Example: clear forest.
- `"forage"` — gathering a one-time resource (wild food, native metals). The single action `forage_resource` ("Forage Resource"). Applies if the hex has a resource marked as one-time (`improved_by: null` + a non-empty `produces`) and it is visible to the player (including `tech_reveal`). On completion it removes the resource from the map and adds the goods from the resource's `produces` field to storage (a number or `[min, max]`). The terrain type does not change.
- `"demolish"` — demolishing an improvement. Applies if the hex has an improvement. On completion it removes the improvement; the resource remains. The terrain type does not change.
- `"road"` — a road built by the **player** (built in as `build_road`, "Build Road"). The only special action that does not change the hex's contents but builds a section of the city's road network. See the section "Roads built by the player" below for details.

> **Example of draining swamps and marshes** (built in as `drain_water`): a record with `"action_type": "terrain"`, `"source_terrains": ["swamp", "marsh"]`, `"result_terrain": "plain"`; cost 24 work (3x a farm's construction). Unlocked by the "Irrigation" technology. No code change needed.
>
> **Example of foraging** (built into the game): the universal action `"id": "forage_resource"`, `"action_type": "forage"`, `"result_terrain": "dont_change"`. On a hex with the `wild_food` resource (`improved_by: null`) a "Forage Resource" button appears. The output when foraged (the `produces` field of the `wild_food` resource) is `{ "foraged_food": [2, 4] }`: each time it is foraged, 2–4 units of "Foraged Food" land in storage, and the resource disappears from the hex.
>
> **Example of demolishing an improvement** (built into the game): `"action_type": "demolish"`, `"result_terrain": "dont_change"`.

---

#### `data/bonuses.json` — diversity bonuses

Root keys: `group_bonuses` and `subgroup_bonuses` (arrays of objects).

**`group_bonuses`** — bonuses for the number of subgroups in a group:

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `group_id` | string | The group's ID (see `groups.json`) | `"meat_animals"` |
| `bonus_type` | string | Bonus type | `"happiness"` |
| `tiers` | array\<object\> | Bonus thresholds | see below |

**`subgroup_bonuses`** — bonuses for the number of species in a subgroup:

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `subgroup_id` | string | The subgroup's ID (see `groups.json`) | `"cattle"` |
| `bonus_type` | string | Bonus type | `"happiness"` |
| `tiers` | array\<object\> | Bonus thresholds | see below |

**The `tiers` object:**

| Field | Type | Description | Example |
| --- | --- | --- | --- |
| `min_subgroups` / `min_species` | number | The minimum number of subgroups (for `group_bonuses`) or species (for `subgroup_bonuses`) | `3` |
| `value` | number | The bonus amount | `10` |

---

## World schema: Ring, Region, Map and Eras

### Terminology

| Term | Description |
| --- | --- |
| **World map** | The entire hex map (`map_rows × map_cols`). It is generated in full at the start of a new game: terrain, cover, resources and rivers for all 60×60 (or however many are specified in map_config.json) hexes at once. |
| **Influence Ring** | A rectangular area around the city that belongs to the player from the very start. Its size is set in `data/map_config.json`. |
| **Region** | A strip of hexes around the Ring (width `region_width`). Only here can chunks be BOUGHT (claimed). Scouting is not limited by the Region **after researching the "Cartography" technology**: before that, scouts may only be sent into the unexplored part of the Region. |
| **Fog of war** | Hexes outside the Ring + Region. They exist in the data and are displayed as a solid opaque fill everywhere the map can be scrolled to. The fog can be **scouted**: after researching the **"Cartography"** technology, scouts may be sent to any point reachable by scrolling — including the territory of towns. Hexes in the fog **cannot be bought**. |

### Size configuration (`data/map_config.json`)

```json
{
  "map_config": {
    "map_rows": 60,        // Whole map: rows (hexes)
    "map_cols": 60,        // Whole map: columns (hexes)
    "start_ring_rows": 7,   // Starting Influence Ring: rows
    "start_ring_cols": 9,   // Starting Influence Ring: columns
    "region_width": 2,      // Width of the Region around the Ring (in hexes)

    // --- Densities and clusters of terrain types ---
    // target_cluster — the global cluster size in hexes (a fallback for types without their own).
    // terrain_config — for each type: density (share of centers) + target_cluster
    //   (an upper bound: centers ≤ area / target_cluster).
    "target_cluster": 22,
    "terrain_config": {
      "plain":    { "density": 0.40, "target_cluster": 22 },
      "hill":     { "density": 0.25, "target_cluster": 30 },
      "lake":     { "density": 0.10, "target_cluster": 50 },
      "mountain": { "density": 0.20, "target_cluster": 25 },
      "swamp":    { "density": 0.05, "target_cluster": 5 }
    },

    // --- River generation ---
    "num_main_rivers": 3,      // Number of main rivers
    "num_tributaries": 5,      // Number of tributaries
    "min_river_length": 8,     // Minimum length of a main river (in path points)
    "min_tributary_length": 4  // Minimum length of a tributary (in path points)
  }
}
```

The file is loaded by the same loader as the rest of the data (`data_loader.gd`), so it supports `//` and `/* */` comments.

### River generation (river system)

Rivers are generated in `river_manager.gd` at the start of a new game (after terrain and resources are generated). The scheme is a **river system** of main rivers and tributaries:

- **Main rivers** — a source in the mountains, a mouth in a lake **or sea**. They do not cross each other (A* runs with occupied vertices forbidden).
- **Tributaries** — a source in the mountains (or hills, if there are few mountains), they flow into main rivers or into other tributaries (a confluence point). Tributaries **do not flow into lakes or seas** (their vertices are excluded from confluence points).
- **Guarantee for the starting area** — at least one river always passes through the starting area "Ring + Region". If, after the main rivers are generated, none has crossed the area, an additional main river is generated through an intermediate vertex inside the area (a mountain on one side → a vertex in the area → a lake/sea on the other side).

The number of rivers and the minimum lengths are set in `data/map_config.json` (see above). The river data format (`Array of Array of Vector2`) has not changed, so rendering, saving/loading and river bonuses work as before.

### River rendering

Rivers are drawn in PHASE 2.75 of `_draw()` — after the roads, before the highlights and icons. The geometry is assembled in `map_renderer._build_river_frame_cache()` → `_collect_river_segments()`; `_draw_river_list()` only draws the finished segments in the required style (main rivers — thicker and darker, tributaries — thinner and lighter). The steps:

1. **Viewport culling** — a river whose rectangle does not intersect the screen with a margin of `MAP_CACHE_MARGIN` is not processed;
2. **smoothing** — meander points are built along the whole river in **world** coordinates and put into the `_river_smooth_cache` cache (the key is a serialization of the source points), because the points do not change as the map is scrolled;
3. **screen clipping** — the smoothed line is clipped to the screen rectangle with a margin;
4. **fog-of-war clipping** — the parts lying in the fog are discarded from the clipped line (see below).

**Fog-of-war clipping.** A hex in the fog is not drawn at all (see `_draw_hex`), so a river on it would hang in black emptiness. A river flows along the **edges** of hexes, so a river point is visible if at least one of the **three nearest** hexes to it is not in the fog: the two nearest share the edge under the point, and the third covers the point at the vertex where three hexes meet. A point surrounded by fog is hidden — the river breaks off at the border of the scouted area. Checking exactly the three nearest (and not just the one nearest) matters: a river running exactly along the border stays solid rather than dashed — the edge between a scouted and an unscouted hex is visible. A hex outside the map does not count as visible: `is_hex_in_fog` outside the map returns `false`, so the check includes an explicit `is_hex_on_map`.

**Cache.** The river geometry (`_river_frame_cache`) is tied to the map offset: within `MAP_CACHE_MARGIN` it is reused, so scrolling does not reassemble it every frame. The fog affects clipping, so on any change of the fog (scouting, claiming territory, era change, debug map reveal) the river cache is reset — the single entry point `invalidate_town_influence_cache()`.

**Invariant:** after the offset the points live in screen coordinates, so the clipping rectangle must be a screen rectangle (`_get_screen_rect()` / `_get_cache_rect()`). Previously a `Rect2(Vector2(-offset_x, -offset_y), ...)` — a **world** window — stood here; when the map was centered (`offset_x ≈ -2280`) it moved far off-screen, `_clip_river_to_rect()` returned `[]` for every river, and the rivers **stopped being drawn altogether**, although they remained in the data (`river_edges`, access to fresh water, town priority) — that is, the bug was visible only as "a map without rivers".

**Tests.** `tests/test_river_rendering.gd` (headless): on the live `MainMap.tscn` map it checks that the screen rectangle starts at zero, that at least one river yields non-empty lines and all of its points lie inside the screen, that scrolling the map does not "kill" the rendering, and that a river entirely off-screen is still not drawn; separately — that the geometry cache is not reassembled on every frame of scrolling. `tests/test_river_fog.gd` (headless): the fog really does discard some of the smoothed river points; all surviving points lie over scouted territory (checked by an **independent** full sweep of the map, not by the same local estimator); a point in the Region is visible, a point deep in the fog is not.

### Town generation: priority cascade

Towns (small settlements) are generated in `scripts/town_manager.gd` at the start of a new game, AFTER the rivers and seas (`river_edges` and `beach` are points of attraction). The number of towns is `num_towns` in `data/map_config.json`.

**Five priorities** (the algorithm goes through them strictly top to bottom):

| № | Priority | Condition on the town's hex |
| --- | --- | --- |
| 1 | `multi_resource` | 2+ DIFFERENT resources within a radius of `MAX_ATTRACTION_DISTANCE` (3 hexes) |
| 2 | `strategic` | a strategic resource (`resource.strategic == true`) within a radius of 3 hexes |
| 3 | `river` | a river flows through the hex (`river_edges` is non-empty) |
| 4 | `lake_coast` | the hex is land adjacent to a lake (`terrain == "lake"`) |
| 5 | `sea_coast` | a sea coast (`terrain == "beach"`) |

**The priorities are NOT equivalent.** STEP 0: the base is the first priority from the top that has a valid hex **anywhere on the map**. The search is a full sweep of the map by the priority mask (no "N random attempts"), so a priority is considered exhausted only when not a single suitable hex remains on the map. As long as there is even one free spot with a cluster of resources nearby, a town will not be placed by a lake or sea.

STEPS 1..N: **cascade refinement**. Over the remaining priorities downwards, we look within a radius of `REFINEMENT_RADIUS` (2 hexes) for a hex satisfying ALL the priorities already earned AND the new one (intersection of masks). Found — the position moves, the priority is added to the chain. Not found — the priority is skipped (the position and the chain do not change), and the cascade continues with the next one. Ideally a town occupies a hex with 2+ resources AND a strategic resource AND on a river AND on the shore of a lake/sea — as far as the refinement radius allows.

A resource within a radius of 3 of which a town already stands does not participate in the count: the same cluster does not attract several towns. A hex with a resource cannot be occupied — the town is placed next to it, within a radius of 3. Secondary priority (`TERRAIN_PREFERENCE`): after the cascade, the position is softly refined by terrain type (plain/sand → hills → deserts → marsh/swamp → mountains) without losing the priorities earned.

**The player's starting area does not attract towns.** The resources lying in it (Influence Ring + 1st-era Region) do not participate in either the "2+ different resources" priority or the "strategic resource" priority. The area already belongs to the player from the very first second, so attracting someone else's settlement to it is pointless: its ring would not be able to make use of it anyway — the town's territory is cut out of the starting area (see "Fill and outlines of town rings"). The rule applies to all towns, including the guaranteed 2nd-era town.

**Implementation points:** `scripts/town_manager.gd` — `_try_place_one_town()` (the cascade), `_find_hex_in_mask()` (a sweep of the whole map + reservoir sampling of a random candidate), `_find_hex_in_radius_satisfying()` and `_hex_satisfies_all_masks()` (the refinement step), `_build_*_mask()` (priority masks), `_build_claimed_resource_mask()` (claimed resources), `player_start_area` / `_is_in_player_start_area()` (the player's starting area); `data/map_config.json` (`num_towns`).
Tests: `tests/test_town_priorities.gd` (headless) — resource surroundings beat water; the transition to the next priority happens only after the current one is exhausted across the whole map; the single valid hex is found on a large map; refinement assembles the full priority chain; a skipped priority does not break the cascade; an empty map → no town is placed; `generate_towns()` places all `num_towns`. `tests/test_town_start_area.gd` — the player's resources give neither the base nor the strategic priority, but the same resources OUTSIDE the area do.

### Absolute coordinates and the window

- Hex coordinates are **absolute** within the whole map (`0..map_rows-1`, `0..map_cols-1`).
- The city is always at the **center of the map** (`city_row = map_rows / 2`, `city_col = map_cols / 2`).
- The borders of the Ring and the Region are recalculated dynamically relative to the city:
  - `influence_start/end_row/col` — the absolute borders of the Ring;
  - `region_start/end_row/col` — the absolute borders of the visible "Ring + Region" window.
- **Rendering and input** work in two areas: the "Ring + Region" window is drawn in detail, while the scroll-reachable strip around it is a solid opaque fill as fog of war. Unexplored hexes outside the Region are not drawn at all. Hexes beyond the reach of scrolling are not drawn either.
- **Buying (claiming) chunks is available only inside the Region** and only for chunks bordering the Influence Ring. **Scouting** is available at any point reachable by scrolling the map, including the fog of war and the territory of towns — but only after researching the **"Cartography"** technology (see below); production and workers still work only in the Influence Ring.

### Fill and outlines of town rings

A town's influence ring is stored in the data **in full by radius** (`town["influence_hexes"]`: radius 3 + an asymmetric notch + paths to resources), and exactly two things are cut out of it: the **player's starting area** and the hexes occupied by an earlier town. The ring is not clipped by the **current** Region. What of it is visible to the player is decided by the renderer — the only place where this visibility is defined (`map_renderer._ensure_town_influence_cache()`):

- **era** — in the 1st era (`current_era < 1`) the rings are not drawn at all, nor are the towns themselves: otherwise a ring creeping into the Region would give away someone else's town from the very start of the game;
- **debug reveal** — the debug action "Open the whole map" (`main_map.debug_whole_map_revealed`, stored in the save) lifts the era gate: the reveal is deliberate, so there is nothing left to hide, and both the rings and the roads of the towns are drawn even in the 1st era;
- **fog of war** — a hex in the fog gets neither fill nor outline. The converse holds: a **scouted** hex outside the Region does get the fill (that is how scouting works).

**A town's territory never reaches into the player's starting area** (Influence Ring + 1st-era Region — what the player sees and builds in from the very first second). Every hex of this area is cut out of the ring of **all** towns without exception, including the guaranteed 2nd-era town. The check runs before the inter-town clip: the player is stronger than any neighboring town. The cut-out hexes do not receive the `in_town_influence` flag, do not enter `influence_hexes`, the town's sell pool, or the decorative improvements (`_place_decorative_town_improvements` takes candidates from the ring). The practical consequence: a resource inside the Influence Ring no longer ends up "in the shadow" of a town — it can be built on and improved, and the chunk with it can be bought; after an era change there are no "dead zones" left in the territory assigned to the player.

The area is stored in `town_manager.player_start_area`; during generation it is set by `generate_towns()` (from the passed `exclusion_*`), on save load by `main_map` before `compute_all_town_influences()` (the borders lie in `map_state` as `start_region_*`; old saves do not have them, in which case they are recalculated from the starting ring and the current Region width). The area **does not change** throughout the whole game — which is why the cut-out does not "freeze" the ring: as the Region grows, exactly what already belongs to the player remains cut out.

**Why the ring cannot be clipped by the Region.** Clipping by the starting Region froze the ring at the 1st-era borders forever: as the Region grew (era change) the fill remained a stub — only the part of the ring that fell into the new Region was drawn, and the cut-off part did not come back (the measured losses were up to 18% of the fill hexes; worst of all for towns at the edge of the Region, including on the left). For the same reason, on save load the rings are recalculated by radius — old games repair themselves. The cut-out by the starting area differs from this precisely in that the area is immovable: what is cut off is what already belongs to the player.

**The fill is pre-rendered into a single RGBA texture**, whose bounds are computed **from the fill itself**, and not from the corners of the Region. On an odd-r grid the odd rows are shifted by half a hex, so the corners of the Region are not the extreme points of the map: the hexes of the edge columns in even rows stick out past them by roughly 0.73 of a radius, and the texture cut them off at its edge — a hex looked drawn **half-way** (more noticeable on the left, where the minimum is taken from the corner with an odd row). Now every fill hex fits entirely into the texture.

On an era change, the hexes of foreign towns' rings inside the former Region are **not annexed** to the player's Influence Ring ("someone else's is not ours": there one can neither build nor buy a chunk), but they **are explored** — otherwise they would remain fog and be drawn as a black hole in the middle of the assigned territory. The player sees their terrain, resources and ring fill, that is, immediately understands whose land it is. Inside the player's **starting** area there are no such hexes at all — it is cut out of the rings during generation and on load.

Implementation points: `scripts/town_manager.gd` — `player_start_area` / `set_player_start_area()` / `_is_in_player_start_area()`, `compute_all_town_influences()` (cutting out the starting area and the inter-town clip), `compute_town_influence()` (the ring by radius, without clipping by the Region); `scripts/main_map.gd` — `get_map_state()` / `_apply_saved_map_state()` / `_restore_start_region_bounds()` (the starting area's borders in the save), `advance_to_next_era()`; `scripts/map_renderer.gd` — `_ensure_town_influence_cache()` (the era and fog gates) and `_build_town_fill_texture()` (the texture bounds from the fill). Tests: `tests/test_town_fill_region.gd` (the ring in the data = the ring by radius minus the starting area minus neighbors, no fill in the 1st era, no losses after an era change, the texture does not cut a hex), `tests/test_town_start_area.gd` (cutting out of the rings, the player's resources neither attract nor are sold, no "dead zones" on the live map after an era change) and `tests/test_town_fill_fog.gd` (the fill and outlines do not leak into the fog, scouting opens the fill). The debug reveal of the whole map in the 1st era draws the rings and the roads of the towns: `tests/test_debug_whole_map_fill.gd`.

### Town food fields

A town whose influence ring has no food resources gets 1–2 decorative farms on free plains without cover (`town_manager._place_decorative_town_improvements`). Previously they remained **bare**: an improvement stands there, a road has been laid to it, and there is nothing to grow — neither a resource on the hex nor a good in the sell pool. A player examining a town's territory rightly asks "how are they not starving?".

Now every field is sown with its **own** domesticated food crop, and all these crops go into the sell pool.

| Decision | Why |
| --- | --- |
| The crop is chosen for **each** field separately, and not one per town | Two adjacent fields with different crops read as a farmstead rather than a uniform wedge, and the town immediately has two goods for sale. Exactly the same logic as for natural resources: the sell pool is a list of resource **types**, not of deposits |
| Only the `food_plants` group; wild plants (`wild_food`, the `wild` group) are excluded | Wild plants are not grown on a farm: they have `improved_by: null`, they are gathered by the "Forage Wild Plants" special action and disappear from the hex. A town that chews wild plants does not answer the question about hunger |
| Specifically `tile.crop_bred`, not `tile.resource` | A farm on an empty hex is **breeding** (the `crop_bred` scheme), not a natural deposit. The hex honestly shows "their own field", while the natural-resource logic (debugging, chunk buying, deposit tools) stays uninvolved with the fields of a foreign town |
| Breedability is checked by `MapHelpers.can_breed_resource_on_tile` | By the same rule as when the player builds a farm: the crop always suits its hex, and new plants in `food_plants.json` are picked up automatically. `allowed_terrain`/`allowed_cover` keep mountain and roadside species out of plain fields |
| Quality is set as when the player breeds | The field has a quality — stars are drawn, the tooltip does not lie |
| The sell pool is computed from the **effective** resource (`tile.resource` OR `tile.crop_bred`) | Previously only `resource` was read, and the fields were mute. The pool is reassembled at the end of `_place_decorative_town_improvements` — after the improvements are placed, otherwise the crop would not get into it |
| A town gets its fields **once per game** | The sign "fields already exist" is a filler farm in the ring (`farm` without a natural resource, sown or not). If there are none, we place 1–2 new ones. Without such a check, every repeated pass would add two more farms, and the ring would become overgrown with them the more often the player loads the game. A side effect of the same rule: the **bare** farms from old games are sown rather than replaced with new ones, and a crop is not invented where the player can build their own |
| A repeated pass (save load) does not change the crop | An already sown field is read from `crop_bred` and is not touched again, so the town is not "resown" on every load, and the sell pool is stable |
| If there is no room for a farm — the town remains without food | The crop is not invented "in a vacuum": no field — no goods |
| This still gives the player no production | The production cycle of `main_map` and `worker_manager` skip `tile.decorative`. The field is needed exactly for appearance and for the sell pool |

`crop_bred` and `quality` are saved to the save (`SaveManager`, `tile_data`), so the crop survives a reload, and `load_towns` + `compute_all_town_influences` restore the sell pool from the hexes themselves.

> The sell pool contains the **output** of the crop, not the crop itself: `wheat_field` yields `wheat` and `feed`, so the town window shows "Wheat" but not "Wheat Field". The same rule as for any other raw resource (see "Town production closure and import", step 1).

**Implementation points:** `scripts/town_manager.gd` — `_place_decorative_town_improvements()` (detecting a food plant, collecting filler and bare farms, sowing), `_pick_town_field_crop()` (random selection of a breedable species), `_seed_decorative_field()` (sowing with a breedability check and quality), `_refresh_sell_pools()` (the effective resource instead of the natural one). Test: `tests/test_town_food_fields.gd` (headless) — a town without food resources gets sown fields, and the **output** of those fields (`wheat`, `feed`) goes into the sell pool while the fields themselves do not; wild plants do not count as food and do not go into the pool; the crop is chosen for each field separately; a repeated pass does not resow the fields or add new ones; a town with its own food plant does not change; with no room for a farm the town remains without food; the crops of different towns differ; the bare farms of an old game are sown; on the live `MainMap` not a single bare farm remains.
### Town harbours

A town whose ring contains a **marine resource** (a resource standing on a sea hex:
`sea_fish`, `murex`, `cuttlefish`) gets a harbour on the coast of that body of water
(`town_manager._place_town_sea_harbors`). The boats themselves are stood on the
resource hex by the common `improved_by` pass — the harbour is their mooring, so the
rule is "a catch in the ring — a dock on the shore", and not "a sea in the ring".

| Decision | Why |
| --- | --- |
| The trigger is a **marine resource in the ring**, not the sea itself | A ring over a sea without fish has nothing to catch, so there is nothing to moor: a decorative dock on such a coast would be a lie about the economy of the town |
| **One harbour per connected sea body** holding such a resource | The same rule as for the player (one body = one harbour): a single dock already serves the whole body, and a row of them along the same shore reads as spam |
| The hex must be **free**: no resource, no improvement, no bred culture, and it must be the land of the RING adjacent to that very body (not a mountain, not an impassable terrain) | The town does not build over what is already there; a coast occupied by a resource or by an earlier improvement leaves the town without a harbour instead of displacing anything |
| The **closest** such hex to the centre of the town wins, the ties are broken by the coordinates | The road to the harbour is as short as possible, and the same save always produces the same map |
| The pass runs **before** the farms, the forest plot and the quarry passes | They would otherwise be able to take the only free coastal hex of the ring |
| It is **idempotent**: a body to which this town already has a harbour in the ring is skipped | The pass runs on every load of a save, and a reload must not add a second dock to the same shore |
| The harbour is **decorative** (`decorative: true`): no worker, no production, it cannot be modified through the panel, and `MapHelpers.has_harbor_access` ignores it | A body of water of the player is opened only by the harbour of the player: a foreign settlement must not give the sea away for free, otherwise the UI gate contradicts the dock visible on the map |

A lake is never a reason for a harbour: a freshwater fish is a separate body of
water, and only the sea (`sea`, `shallow_sea`) counts — see `SEA_TERRAINS`.

**Implementation points:** `scripts/town_manager.gd` — `SEA_TERRAINS`,
`_is_sea_terrain()`, `_sea_body_id()` (a flood-fill of a sea body, cached for the
whole pass), `_is_better_harbor_hex()`, `_place_town_sea_harbors()` (called from
`_place_decorative_town_improvements()` right after the ring candidates are
collected); `scripts/map_helpers.gd` — `has_harbor_access()` skips the harbour
improvements of the tiles with `decorative: true`.

### Town production closure and import

A town trades not only in what lies on its hexes. It **produces**: the sell pool is the production closure over the recipes from `data/crafts/*.json`, and it is willing to buy in part of what is missing. The computation lives entirely in `scripts/town_economy.gd` (pure static functions over the data — it does not depend on the map), and is called from `town_manager._refresh_sell_pools()`.

**Steps:**

1. **The base pool is only the OUTPUT** of the resources of the ring's hexes (a natural `resource` OR a breedable `crop_bred`, as in the food fields). The resource itself — a field, a deposit, an animal — is **not** a good: the town sells the harvest, not a "wheat field". The rule is exactly one, so both animals and one-time finds require no separate exceptions.

   | Resource on the hex | Goes into the pool | Example |
   | --- | --- | --- |
   | An ordinary raw resource | only `produces` | `wheat_field` → `wheat`, `feed` |
   | An animal | only `produces` | `cows` → `raw_meat`, `hide`, `raw_milk` |
   | A one-time metal (`improved_by: null`, `category: metals`) | only `produces` | `copper_nugget` → `copper` |
   | One-time other (`improved_by: null`) | **nothing** | `wild_food` → nothing |
   | Not in the registry (a broken save) | the id itself | — |

   The one-time sign is the same as for the "Forage Resource" special action (`improved_by == null` and a non-empty `produces`), factored out into `is_one_time()`. In the data there are exactly 5 one-time resources: four nuggets and `wild_food`. The nuggets yield ore (copper is needed by the blacksmith, it is extracted without limit), while wild plants yield nothing — they cannot be gathered every time, so there is nothing to sell.

   The closure does not suffer from this: not a single id from `data/resources/**` occurs as a recipe ingredient in `data/crafts/**` — the recipes operate only on products. The `INCLUDE_RESOURCE_YIELD` flag (on) is kept as an emergency switch for debugging: when `false`, the resource ids themselves enter the pool.
2. **Closure (fixed point)** — while the pool expands, every recipe with all available ingredients adds its `result`. An `@`-group is considered closed if the pool contains **at least one** member (the same semantics as in `GameData.get_storage_amount`). The pseudo-recipes `empty`/`science` drop out: their `result` is empty.
3. A recipe's **readiness** = the share of closed ingredients, **resource quantity is not taken into account** (see below). An import candidate is a recipe that has not closed but has at least one available ingredient.
4. **A probability roll** by this share. If it succeeds → the missing types go into `buy_pool`. An `@`-group expands to a **random** member (price does not matter).
5. **The cascade repeats** as long as new import opens something up: bought ore gives metal, metal gives wares. There is no fixed number of passes — the loop runs until a round in which not a single new import appeared (on the real data, 1–4 rounds, 2.4 on average).
6. **Isolation:** `sell_pool` = base resources + everything produced **minus what was imported**. What is bought is not sold: the town buys for the sake of production, not for reselling raw resources.

| Decision | Why |
| --- | --- |
| Resource quantity is **not** taken into account | A town's economy is virtual: it extracts nothing and produces nothing in buildings. For it, "iron and coal are needed" is the same as "30 iron and 20 coal are needed". The volumes from the recipes are not read at all |
| The recipe's estimate is a **probability**, not a formula | A virtual economy does not need an honest measure. 1 out of 2 → 50%, 1 out of 3 → 33%, 2 out of 3 → 67%; roll the dice — it imports. Randomness is appropriate here: a town that has almost everything has the right NOT to want to bother with it |
| Readiness is rounded **up** | 2/3 = 66.67 → 67. Discarding the fractional part would give 66, and "two out of three" would read worse than "one out of two" (50), even though more is closed |
| Single-ingredient recipes do not participate in import | They drop out on their own: at 0/1 the rule "there is at least one available ingredient" cuts them off, at 1/1 the recipe is fully closed and goes into the closure. Importing for the sake of a single ingredient is irrational |
| The player's technology gate is **not applied** | A town has no technology tree of its own. The gate would tie the pool to the player's progress, and a town at the edge of the map would "freeze" at the level of an era the player has not yet grown into. `produced_in` is not checked either: a town does not build city buildings |
| The roll is **deterministic** | `_refresh_sell_pools()` is called twice in a row, and both times on save load. A global `randi()` would give a different `buy_pool` on every read of the save, and "what the town buys" would jump from game to game. The seed is derived from `(town id, recipe id, index)` — the same trick as in `_make_border_color` |
| One roll per recipe | A recipe occurs in several rounds of the cascade; rerolling it every time would be a lottery with an unlimited number of attempts. The decision is remembered: the town "has decided", rather than "rolling the dice again" |
| Raw resources **do not** go into the sell pool | A field, a deposit and an animal are a description of a hex, not a good. Showing them in the list would mean slipping the player "two wheats" in a row (`wheat_field` and its harvest `wheat` are named the same) and "Fish ×2" (`freshwater_fish` and `sea_fish`). One rule instead of a list of exceptions covers both animals and one-time finds |

**Serialization:** `sell_pool` and `buy_pool` were already written in `serialize_towns()` and read in `load_towns()` — only the contents changed, the save format is the same.

**Measurement on the live map** (`MainMap`, 60×60, 17 towns): the sell pool ranges from 5 to 36 goods, imports from 0 to 11. A town that has bought in ore immediately starts selling metal and wares made from it.

**Implementation points:** `scripts/town_economy.gd` — `collect_base_resources()` (the output of the hexes' resources) and `is_one_time()` (the `improved_by == null` sign), `is_available()` (a single key and an `@`-group), `_close_pool()` (the closure), `readiness_percent()` (readiness), `_roll_import()` / `_pick_group_member()` / `_seed_for()` (deterministic roll and choice), `build_pools()` (the cascade + pool assembly), `refresh_all_towns()` / `refresh_town()` (recomputation over the rings); `scripts/town_manager.gd` — `_refresh_sell_pools()` delegates to the module.

**Test:** `tests/test_town_economy.gd` (headless) — closure in depth (`wood → charcoal → iron`), a group closes with one member, readiness 67/50 and independence from quantity, the cascade unfolds the iron family, imports do not enter the sale, a repeated computation gives the same pools (the main regression test for determinism), a group's member is always from the group, the base pool contains only output (not a single id from `data/resources/**`), animals are excluded, the one-time `wild_food` is empty while the nuggets yield ore, two ids with the same name give one window row, the lists lie in a `ScrollContainer` and scroll, the goods are split by categories (a header — a line, a name, a line; rows only of their own category); on the live map the pools are non-empty and stable against a repeated recomputation.

### Town window: long lists and one name — one row

Both columns of the window (`scenes/TownUI.tscn`) lie in a `ScrollContainer` (`BuyScroll` / `SellScroll`, like `InternalScroll` in `CityUI.tscn`). Without this, a town's sell pool — dozens of rows — spilled past the bottom edge of the window right onto the map. The window was enlarged from 600×440 to 768×600 (it stays centered on the 1152×768 screen), and `WindowPanel` got `clip_contents = true` — even if the layout comes apart, the content physically cannot be drawn over the map.

In `_fill_resource_list()` rows with the same displayed name are shown once. This is **a safety net**, not the main protection: after the pool switched to output, duplicates "two wheats" cannot be in it. But in `data/products` there is exactly one pair of different ids with the same name — `papyrus_plant` (the harvest from `papyrus_field`) and `papyrus` (the craft from it) are both called "Papyrus", and both can end up in the pool of one town. The row also got a minimum height of `ROW_HEIGHT` (28 px, like the icon): a wrapping label no longer overlaps the neighboring row.

The goods in both columns are split by **categories** — exactly as on the "Resources" tab of the city interface (`resources_tab.gd`): a category header is a solid line, the name centered in the column, another line; below it, rows of only that category. The lines are stretched `ColorRect`s, not glyphs: the default font does not contain U+2500 (box drawing), and from characters a line would not reach exactly the edges of the column at an arbitrary width. The header is built by the shared `UiHelpers.build_category_header()` — it is used by both the town window and the "Resources" tab, so they cannot diverge. The order of categories is by `GameData.categories` (`data/categories.json`); a category not in the reference (for example, `animals` or `plants` of a raw hex) goes to the end under its own id, so not a single row is lost. A row's category is taken via `GameData.get_resource_data()` (the shared reference covering both raw resources and products) and matches the category of the id that "won" the name deduplication — otherwise the row would go under the wrong header. The implementation is `_fill_resource_list()` (grouping) + `_build_resource_row()` (one row), `_get_resource_category()` / `_get_category_name()` / `_ordered_categories()`.

### Town treasury

Each town has its own treasury — the `treasury` field in the `town_manager.towns` record. The starting value is `town_initial_treasury` from `data/game_balance.json` (1000 coins); the treasury is saved with the town record, and a save without the field gets the starting value.

The treasury changes only through `TownManager.add_town_treasury(town, amount)` and `TownManager.spend_town_treasury(town, amount)`. A debit beyond the balance does not go through (it returns `false`): a town does not go into debt. Both functions emit `town_treasury_changed(town_id, treasury)`; `main_map` connects it to `town_ui.on_town_treasury_changed`, so the "Treasury" label in the top-right corner of the town window (`TreasuryLabel` in `TownUI.tscn`) updates immediately on a deal, without waiting for a tick and without rebuilding the goods lists (the scroll position is not reset).

### The warehouse of a town (English)

The trade pools answer **what** a town can trade; the warehouse answers **how much of it is on hand right now**. Before this, a town listed dozens of goods and the player had no way to tell a hill of grain from a single egg — every entry read the same. Now the sell column shows a number next to every good, and that number grows while the town works.

Everything a town "gathers" on the map and "produces" in its buildings is virtual, and it all lands in the warehouse.

**The data.** Three fields in `data/game_balance.json` drive the whole subsystem:

| Field | Default | Meaning |
| --- | --- | --- |
| `town_storage_limit` | 1000 | Capacity of the warehouse **per product id**. One town can hold 1000 wheat *and* 1000 silk at once. |
| `town_storage_initial_min` / `town_storage_initial_max` | 100 / 500 | Bounds of the starting stock of every product of the sell pool. |
| `town_tick_ticks` | 4 | How many common ticks make one town tick — a town fills its stock four times slower than the city produces. |

**Where the numbers come from.** The per-tick rate of a town (`production`, in the town record) is the sum of two parts, both read from data:

- the **yield of the ring** — the `produces` field of the resources on its hexes, exactly the same source as the base pool (`TownEconomy.collect_base_yields`). A range `[min, max]` takes its minimum, the same deterministic convention as the city's own production (`CityData.add_raw_production`): a roll here would refill the warehouse differently on every load of a save;
- the **output of the recipes** — filled inside `_close_pool()` at the very moment a product enters the pool, so the rate and the pool can never disagree. A recipe reading `result: {"silk": 10}` adds **10 silk per town tick**.

A product the ring already yields is not produced by a recipe as well: the closure skips ids that are already in the pool, so the two parts never fight over one product id.

**A town never runs short.** If it decided to make something, it makes it — no matter how many towns gather or import it. Nothing is consumed and nothing can be "out of stock"; only the limit stops the accumulation. The ingredients are virtual, so tracking them would only invent scarcity the design does not want.

**Production starts when the player sees the town.** Until then the town holds its starting stock and nothing grows. The reason is timing: a town fills its warehouse in a few minutes, and one that had been producing since the world was generated would already be pinned at the limit by the time the player arrived — the trade would be dead on arrival. The gate is the same condition under which the town is drawn on the map (the hex is in the player's known territory, or it has been scouted), and it latches into `production_started`, so a town discovered once keeps producing.

**The tick.** `main_map._process` accumulates its own `town_timer` and calls `TownManager.tick_towns()` every `town_tick_ticks × CityData.SIMULATION_TICK` seconds — a separate, slower clock from `production_timer`, which drives the city. The tick deliberately does **not** emit a signal per town: it writes units off every town on the map several times a second. Instead the open window is refreshed in place (`TownUI.refresh_storage`), which rewrites the numbers without rebuilding the rows and so keeps the scroll position.

**Trade deals.** The warehouse changes only through `TownManager.add_town_goods(town, id, amount)` and `take_town_goods(town, id, amount)`, which emit `town_storage_changed(town_id)`. Selling more than the town has fails and writes nothing off — a town cannot sell what it does not have. Buying into a full product returns how many units actually fitted. These are the seam the real trade will use; the trade itself is still a stub (`is_trade_available`).

**Determinism.** The starting stock of a product is derived from `(the town id, the product id)` and not from the global RNG — the pools are recalculated twice on a new game and on every load of a save, and a roll would give the warehouse a different stock each time. Two towns differ; the same town is always the same.

**Determinism across saves.** The warehouse mirrors the sell pool exactly: a product that has *just* entered the pool gets a starting stock, and a product that is no longer for sale is dropped. The pruning is not cosmetic — the pools are recalculated twice on a new game, and the ring gains its decorative fields in between, so a product seeded on the first pass can turn into an import on the second and would otherwise sit on the warehouse forever as goods the town neither gathered nor made. A product that *stays* in the pool keeps its stock, so sold units do not come back on every reload.

**Implementation points:** `scripts/town_economy.gd` — `get_storage_limit()`, `get_initial_stock()`, `build_initial_storage()`, `collect_base_yields()`, `store_production()` and the `production` output of `build_pools()` / `refresh_town()`; `scripts/town_manager.gd` — the `storage` and `production_started` fields, `get_town_goods()` / `add_town_goods()` / `take_town_goods()`, `get_town_tick_seconds()`, `_is_town_production_started()` and `tick_towns()`; `scripts/main_map.gd` — the `town_timer` and the call in `_process`; `scripts/town_ui.gd` — the quantity label in the sell column and `refresh_storage()`.

**Save format:** `storage` and `production_started` are written by `serialize_towns()` and read by `load_towns()`. The per-tick `production` rate is deliberately **not** saved — it is derived from the ring and recalculated on load, so it cannot go stale against the pools.

**Tests:** `tests/test_town_economy.gd` (headless) — the starting stock stays within the configured bounds, is deterministic, and differs between towns; the plan matches the recipe output read from `GameData.crafts` itself and never contains an imported good; production grows the warehouse by exactly the recipe output and consumes nothing; the limit is enforced per product, not per warehouse; an unscouted town does not produce and a scouted one does, by both paths (`is_explored` and `in_influence`); deals move units in both directions, fail beyond the stock and do not go negative; the save round-trip preserves the warehouse; and on a live map every town has a non-empty warehouse covering its whole sell pool, with no imported goods on it.

### The quality of town goods (English)

The city tracks quality as a **breakdown**: a single product can sit in the warehouse as 300 common and 700 perfect units at once, and every operation weights the levels. The towns deliberately do not. The rule for them is simpler and is the whole point of this section:

> **A town warehouse never holds mixed quality. Every product carries exactly one level.**

That one level is the quality of the **resource on the map** the product comes from. The player already sees the stars of a resource on a hex (`tile.quality`, drawn by `map_renderer._draw_quality_stars`), and the town simply keeps that level for everything the hex yields. When the ring holds several hexes of the same resource at different levels, the **highest one wins**: if a ring has common cows and exceptional cows, the meat, hide and milk are exceptional, not common and not an averaged middle. A town is a virtual economy over a handful of hexes; a per-unit breakdown there would be a fiction the player could do nothing with, and the window has room for stars only.

**Where the level comes from.** `TownEconomy.collect_base_qualities(tiles)` walks the ring exactly like the base pool (`collect_base_resources`) and the per-tick yield (`collect_base_yields`) do, reads `tile.quality` and maps it onto the **products** of the resource (`wheat_field` → `wheat`, `feed`). It considers **every** candidate hex and keeps the best level (`is_better_quality`, comparing `GameData.get_quality_value`), so the result does not depend on the order of the walk. A resource without a rolled level (a broken save, a resource whose quality was never set) falls back to the ordinary level, so the window never shows a row without stars.

**What production does.** The crafted goods follow the **standard craft rule of the city** — the quality of the result is the weighted average of the levels of the ingredients, rounded to the nearest level (`CityData.quality_from_breakdown`). `TownEconomy.craft_result_quality` is the town's mirror of it: it resolves each OR-group of the recipe to the first variant present in the pool, reads that variant's level, and averages the level **values** from `data/qualities.json`. Because a town ingredient exists at exactly one level, the "breakdown" of the city degenerates to one unit per ingredient, and the rule reads as "the average level of the ingredients". The quantities from `data/crafts` are still ignored: the town economy is virtual, and one ingredient one vote is the honest reading of a recipe the town does not actually measure. This is the same expectation the design doc states — "exceptional flour makes exceptional bread" — and it is what makes a town with good raw materials sell better goods.

**How it is displayed.** The sale column shows the stars of the level in the colour of that level (`data/qualities.json`, `color`), and nothing else. There is **no breakdown and no percentages**: there is only one level to show, and the star marker the city uses for "this good has a breakdown" would suggest a split that does not exist. Hovering the stars shows a small tooltip naming the level ("Quality: exceptional"), so the colour and the star count do not have to be memorised. The stars read as a property of the product ("what it is"), the unit count to the right as its amount. The stars of a row never change while it is on screen — a town holds one level of a product — but `refresh_storage()` rewrites them together with the number through the same seam, so the two labels of a row can never drift apart.

**Implementation points:** `scripts/town_economy.gd` — `DEFAULT_QUALITY`, `collect_base_qualities()` (with `is_better_quality()`), `craft_result_quality()` (with `_ingredient_quality()` and `_round_quality_to_level()`), the `qualities` parameter of `_close_pool()` / `build_pools()` and the `quality` output of `refresh_town()`; `scripts/town_manager.gd` — the `quality` field of a town record and `get_town_goods_quality()`; `scripts/town_ui.gd` — `_sell_quality_labels`, `_quality_of()`, `_apply_row_quality()` and the stars label in `_fill_resource_list()`.

**Save format:** the `quality` field is deliberately **not** saved — like the per-tick `production` rate it is derived from the ring and recomputed on load by `compute_all_town_influences` → `_refresh_sell_pools`, so it cannot go stale against the pools or the map.

**Tests:** `tests/test_town_economy.gd` (headless) — a ring resource hands its hex level to all of its products; the **highest** level wins over mixed hexes of the same product regardless of walk order (and perfect beats exceptional); a resource without a level falls back to the ordinary one; the craft rule averages the levels of the ingredients (and identical levels yield that same level); on a live map every product of every town's sell pool carries a level from the scale, and the `quality` map holds no keys outside the pool; the window draws one stars label per row, in the colour of the level, with no percentages and no breakdown, and each label carries a tooltip naming its level (and accepts the mouse so the tooltip can show).

### Roads from towns to their improvements

Each town has its **own road network**: from the town's own hex to its improvements in the influence ring (`tile.improvement`, placed by `town_manager._place_decorative_town_improvements` as decorative ones: farms, a forest plot, a quarry, a harbor, resource improvements). The rules are exactly the same as for the player's city: the shortest path over land from an improvement to an **already connected** hex of the network, water is impassable, and `no_road` ones (fishing boats, irrigation canals) get no road.

| Decision | Why |
| --- | --- |
| The network is **its own per town** (`road_manager.town_connected_hexes`, the key being the coordinates of the town center) | Otherwise "roads from a town" would become roads from the player's city, and all towns would be linked to one another by a single web of roads through it. The search stops only at the hexes of ITS OWN town. |
| The segments lie in one flat set `town_road_segments` | For rendering the set is one anyway; a segment that coincides with a neighboring town's is simply drawn once. |
| The path is sought **across the whole map**, not only within the ring | A ring may have a notch and be cut off by a neighboring town — with a "ring only" restriction, some improvements would be left without a road forever. |
| A water improvement gets no road | As with the city: one approaches water along the shore, not over the water. |
| The roads are **not written** to the save | As with the city's: the input data (towns and improvements) is already in the save, and the network is recalculated at the start of a game and on load. |
| Visible from the Antiquity era and outside the fog of war | The same gates as for the ring fill (`map_renderer.are_town_roads_visible()` / `is_town_road_segment_visible()`): otherwise a road would give away an unexplored settlement before the player had scouted it. |

A road **geometrically** may pass near the city or across foreign territory — a road is physical, the path is sought across the map. But logically it is connected to no one's network: the `connected_hexes` of the player's city does not change because of this.

**Implementation points:** `scripts/road_manager.gd` — `rebuild_town_roads()`, `build_town_road_from()`, the search `_find_connect_path()` shared with the city; `scripts/main_map.gd` — `_rebuild_town_roads()` (called in two places: a new game after `road_manager.initialize()`, and on load — after the towns and their improvements are restored); `scripts/map_renderer.gd` — `_draw_all_roads()` (two passes: the city and the towns) and the `ROAD_COLOR` / `ROAD_WIDTH` style. Test: `tests/test_town_roads.gd` (headless) — a road to every improvement, isolation of the networks, ignoring decorative improvements when recomputing from the save, water improvements without a road, the live scene and the visibility gates.

### Roads the player builds

Besides the automatic roads to improvements, the player can build a road **to any hex where there is no road yet**: the `build_road` special action (`action_type: "road"`, "Build Road") in `data/special_actions.json`. A road built **together with an improvement** follows exactly these rules — see "Road to an improvement" below.

| What | How |
| --- | --- |
| The button | On a hex of the Influence Ring to which there is no road yet, in the right column of the control panel. It is not shown on water, on hexes with a `no_road` improvement (an irrigation canal, boats), on hexes already connected to the road network, and on hexes to which a road is **already being built** — instead there is a project-cancel button |
| The preview | A separate block in the preview column: where the route will run, the **range of the price per section**, the number of new sections, the range of the distance to the city, the terrains on the route with their multipliers, and the total. If there is no path — the reason and a disabled "Start" button |
| The price per section | The `work_cost` of the **road level** (data/roads.json) × the **terrain** multiplier × the **distance** multiplier × the technology multiplier. The total for the road is the sum of the prices of its sections, and this is the only source: both the preview and the start take the same steps from `main_map._build_road_steps()`, so it is impossible to show one thing and debit another. More on levels in the next section |
| Terrain | The `work_cost_mult` multiplier from `terrains/terrains.json` — **the same** as for improvements (plain 1.0, hills 1.35, rocky desert 1.5, marsh 2.0, mountains 2.5). It is taken by the hex that the section **attaches** to the network: in the queue every internal hex of the route occurs twice (as the `to` of one step and as the `from` of the next), and with `max(from, to)` the same hex would be paid for twice. The planner — Dijkstra over `move_cost` — bypasses difficult terrain on its own when there is a detour, so a road through mountains means "there is no way around", not "the player chose a bad route" |
| Distance | A separate coefficient `road_distance_cost_modifier_per_hex` in `game_balance.json` (**0.1**), not the general `0.25` of improvements: the distance multiplier is applied to **every** section, so it is multiplied by the length of the route, and at 0.25 section #20 would cost ×6. The value 0.1 gives a readable series ×1.1, ×1.2, …, ×2.0. The "wheel" (`improvement_distance_cost`) reduces the contribution of distance — **both for improvements and for the road**, because the formula is one (`MapHelpers.get_distance_tech_mult()`) |
| Length surcharges | **None**, and none are introduced. A long road takes longer to build because there are more sections, not because of a penalty: "hard and long roads take a long time to build" is two independent reasons, each visible on its own section. Paying for "length" with a third multiplier would mean punishing the player twice for the same decision |
| Construction | The standard algorithm `road_manager.plan_road_to()` — the shortest path over land from the hex to the nearest already connected hex of the city's network. The route is turned into a **queue of sections**, and they are built one by one: `main_map._build_road_steps()` → `project_manager` → `road_manager.build_road_step()`. Each section immediately shortens the network, so the next routes are shorter |
| Merging with a neighboring road | A new road that has come **right up** to an already connected hex of its own network merges with it: `road_manager._join_adjacent_connected()` builds the missing segment between neighboring hexes of the network (at the level of the road just laid). Without this, two roads meeting on neighboring hexes would remain with a gap that the player has **no means** to close: the "Build Road" button is shown only on a hex WITHOUT a road, and both hexes of the gap are already connected. It works both for the city's network and for the towns' networks (in `build_road_from`, `build_town_road_from`, `build_road_to`, `build_road_step`) |
| Order of sections | **From the network to the target**, even though the plan returns the path from the target to the city (`plan_road_to` builds it in the reverse direction). Then each section attaches to an already finished road rather than hanging in the air until the end of construction. For the same reason the progress bar travels from the city to the target, and the ghost is "eaten" starting from the city |
| Payment | Separate for each section, and **the sum of the steps equals the price shown in the preview by construction**: each step is rounded up separately, and the total is simply summed. The previous scheme "the last step covers the remainder" has been removed — with different step prices it would produce an overpayment or an underpayment. There is no longer any partial payment of the route: an underpaid section simply does not start, and work that falls short is lost on cancellation |
| Planar price vs steps | `plan.segments` is `path.size() − 1`, that is, **all** segments of the path, including the already built ones. One cannot multiply it by the price per section: there is no need to pay for the sections already laid. The source of the steps is `main_map._build_road_steps()`, which also filters; the preview and the start take the steps from there, so the discrepancy "showed more than was taken" is ruled out |
| Cancellation | A **"Stop: Road"** button on **any** hex of the project — on the progress bar of the current section, on a ghost section and on the target, not only on the target. The dialog says outright that **the whole project** is being interrupted, and names the number of unfinished sections. The sections already laid **remain** — cancellation does not roll the road back |
| Saving | Road segments are not written to the save (as are all the others). What is saved is the **input data**: the `tile["road_built"]` flag and the `tile["road_level"]` level, which are set on **every** hex attached by a section, and from them the network is recalculated on load (`road_manager.rebuild_player_roads()`). An old save keeps its old prices — this is correct, no repair is needed. A level without `road_level` is a trail (level 1) |

### Road to an improvement

The road the player gets together with an improvement is **not a side effect of a finished improvement**, but part of a single chain. Previously it was laid by a single call to `road_manager.build_road_from()` at the moment the improvement was completed, and its price was included in the price of the improvement, while for the basic trail it was zeroed out altogether. Now an improvement with a road is **one staged project and one slot**, where the road sections come first and the construction itself is the last step.

| Aspect | How it works |
| --- | --- |
| When it starts | With a single click of "Start": `build_manager.start_build` sees that the improvement is due a road (the breakdown `get_road_cost_breakdown_for_improvement` yields new sections) and goes to `main_map.start_improvement_road_project`. Improvements without a road remain an ordinary construction in `active_builds` |
| What is in the queue | `section 1 → … → section N → improvement`. The last step carries `data.step_type = "improvement"`, `improvement` (id) and `target_res_id` (breeding) and is applied by the step handler through `_apply_improvement()`, shared with ordinary construction |
| Order of steps | First the road, then the improvement. Materials are carried to a distant hex along the road, and "building the improvement while there is no road yet" would mean hauling the worker and building materials over roadless terrain |
| How much it costs | The same as the same road built separately, including the basic trail: the sum of the prices of its sections. The breakdown is `main_map.get_road_cost_breakdown_for_improvement()`, the same as in the "Build Road" preview, so the figures in the panel and at the start match |
| Two prices in the preview | `Improvement: N work` and `Road to the city (level): M work, K new sections`, plus `Total`. The improvement's `cost_data` returns `cost` (the improvement), `road_applicable`, `road_cost`, `road_segments` and `total_cost`; **the road is not included in `cost`** — otherwise the same work would be debited twice |
| Slots | **One slot for the whole chain.** Previously the improvement and the road each took a slot, so in a new game (one citizen — a limit of one construction) they could not be started together, and one had to prioritize the road and refuse the improvement. Now the chain either fits within the limit or does not start at all |
| The ghost and the bars | While the road is under way — the ghost of its route and a blue section bar; on the last step the ghost disappears and a yellow bar appears on the improvement's hex (the same color as for ordinary construction: `project_manager.get_step_progress_at` returns the step's `step_type`) |
| When there is no road | The hex is already connected, the improvement has the `no_road` flag (an irrigation canal, boats), or there is no land path — then the improvement is built by ordinary construction without a road, and the preview says "Road to the city: not needed". If a road project is **already** under way to the hex (the player built a road here separately), the preview writes "already under construction" and does not show the price a second time — that queue pays for it; and the construction itself will not start, the hex is occupied |
| For special actions | Special actions (gathering wild plants, clearing forest, drainage, demolishing an improvement) do **not** get a road: `build_manager.start_build` sends them to ordinary construction, bypassing `start_improvement_road_project`. Therefore `main_map.get_improvement_work_cost()` returns `road_applicable = false`, `road_cost = 0`, `total_cost = cost` for them, and the preview draws neither a road line nor a "Total" — there is nothing to sum |
| Cancellation | A single button "Stop: Road to "Farm"" on **any** hex of the chain cancels it entirely. The sections already laid remain; the improvement is not built, and the work for it is **not spent** — it is last in the queue |
| An occupied hex | A hex with an ongoing chain cannot be occupied by a second construction: the improvement in the queue is not in `active_builds`, so `build_manager.start_build` also checks `project_manager.has_project_at` |
| Saving | The input data on the improvement's hex: `road_staged` (the road is being led by a project), plus `road_built`/`road_level` on the already attached hexes and the project queue. `road_manager.rebuild_roads_from_existing` **skips** such a hex (`main_map._skip_improvement_road_restore`), otherwise it would finish an unfinished or cancelled road for free. Old saves do not contain the field — there the roads to improvements, as before, are due from the improvement itself |

Test: `tests/test_improvement_road.gd` (headless) — the order of steps, one slot under a limit of one construction, the inadmissibility of a second construction on an occupied hex, separate prices, both sums in the preview, and skipping `road_staged` on restore.

Planning cache: the panel asks for the road plan on every tick, and pathfinding is a Dijkstra over the map, so the plan is cached in `road_manager` by **two** versions: the "network version" (`_network_version`, which changes on any change of the roads) and the "map knowledge version" (`_knowledge_version`, see below).

### Staged construction: the project system

A road is not the only thing that makes sense to build in parts, so the queue of steps was moved into a separate shared mechanism, `scripts/project_manager.gd`, and the road is its first (and so far only) user.

| What | Decision |
| --- | --- |
| What a project is | An ordered queue of **steps**. Until the current step is finished, the next one does not start. A step is one hex of the route: its own labour, its own hex for the progress bar, its own ghost segment, and a `data` payload for the handler |
| What the manager knows | **Nothing about roads.** It advances the queue, drips labour into the current step, and emits events. What a step means is decided by the owner — `main_map` on the `step_completed` signal. A new kind of project (say, an aqueduct from a mountain to the city) is a new step handler, not an edit to the manager |
| Where labour comes from | The rate is handed out by `build_manager` in its own `_process` and by its own rule: the city's labour is divided equally among **all** active builds. Each active project takes exactly **one** slot — only the current step is being built at a time, the rest wait in the queue. Projects do not invent their own rate, otherwise the city would build faster than itself |
| Ghost | `project_manager.get_pending_ghost_segments()` — the union of the segments of all not-yet-built steps of all active projects. The renderer draws it in the same style and in the same pass as the preview, but it lives until the end of the construction, not until the panel is closed. A built section disappears from the ghost by itself: its step has left the queue |
| Progress bar | `project_manager.get_step_progress_at(row, col)` — drawn on the hex that the section under construction joins to the network. When moving to the next step, the bar moves by itself |
| Link to `build_manager` | Narrow: `build_manager.project_manager` (a reference) + two calls — `get_active_step_count()` for the number of slots and `receive_labor(rate, delta, instant)` for the handout. `start_build()` intercepts the road and goes to `main_map.start_road_project()`, so the entry point for panels and debugging has not changed |
| Debug flag | "Ignore building requirements" comes into `receive_labor` as an argument rather than being read from `CityData`. Thanks to this, the manager is free of autoloads and is loaded in a headless test via `load()`; on the other hand, the flag also affects already started projects, just like all other builds |
| Saving | `serialize_projects()` / `restore_projects()`. The queue is saved with its position (`step_index`) and accumulated labour. On restore, signals are **not** emitted: the world has already been restored in full, and the owner simply redraws the ghost from the final state |

**Implementation points:** `scripts/project_manager.gd` (the whole queue); `scripts/main_map.gd` (`start_road_project`, `_build_road_steps`, `_on_project_step_completed/_on_project_completed/_on_project_cancelled`, `_refresh_project_ghost`); `scripts/road_manager.gd` (`build_road_step`, `get_road_segment_key`); `scripts/build_manager.gd` (`project_manager`, `_get_active_project_steps`, the handout in `_process`); `scripts/map_renderer.gd` (`set_project_ghost_segments`, `_draw_project_ghost`); `scripts/progress_bar_layer.gd` (the current step's bar); `scripts/control_panel.gd` (`cancel_project`, `_append_cancel_actions`, `_make_project_cancel_action`); `scripts/SaveManager.gd` (`active_projects`). Tests: `tests/test_staged_projects.gd`, `tests/test_cancel_actions.gd` (headless).

### Interrupting any action in progress

The interrupt button is part of the panel's **single rule**: on a hex where something
is going on, a `Stop: <action name>` button appears. Previously the rule
existed in four places and was nowhere complete.

| Action | Button | Where it appears | What is lost | What is returned |
| --- | --- | --- | --- | --- |
| Ordinary construction (improvement) | `Stop: House` | the improvement's hex | invested labour | — |
| The "road → improvement" chain | `Stop: Road to Farm` | any hex of the chain (the improvement, a ghost section, the progress bar) | invested labour, unfinished sections and the unbuilt improvement | already laid sections remain |
| Special action (drainage, clearing) | `Stop: Drain Water` | the special action's hex | invested labour | — |
| Road project | `Stop: Road` | **any** hex of the project | invested labour, unbuilt sections | already built sections remain |
| Claiming land | `Stop: Claiming land` | the first hex of the chunk being claimed | invested labour | the paid coins |
| Scouting | `Stop: Scouting` | a hex of the chunk being scouted | the expedition's time | the paid coins |

**The rule about money.** Claiming and scouting are paid for **immediately**, at
start. That is why cancelling **refunds** what was paid: the money was paid for a
result (a chunk in the Influence Ring, explored hexes), and there will be no result.
The price of giving up is the invested labour and time. For ordinary construction
and a project no refund is needed: no money is spent there at all, only labour is
lost. `expansion_manager.handle_action` already does the same when a claiming build failed to start.

**What each fix repaired.**

- *The project button lived only on the target.* The player sees the construction on the current section
  and on the ghost, but the button was on a hex that could be off
  screen. Added `project_manager.get_project_at_hex()` — searching for a project by
  **any** of its hexes (`hex`, `data.from`, `data.to`, the target). The search by target
  (`get_project_at()`) remains: it is needed to hide the "Build
  Road" button on a hex that a road is already heading to.
- *Early `return`s in `_collect_actions` lost the project check.* A hex with an
  improvement and a hex in a town's influence ring returned the list before the cancel block.
  A road to a hex with an improvement could be built but not cancelled; a road to
  a town ends with a section in its influence ring — there too the button was
  missing. Added a shared helper `_append_cancel_actions()`, called from all
  branches.
- *`elif` hid one button behind another.* A build on a road hex suppressed
  the project button. These are **different** things, so when both are present both are shown.
- *The generic "Cancel construction".* From the button it was impossible to tell what was being interrupted.
  Now the name is taken from the action's data.

**Cancelling interrupts EVERYTHING.** A button on a hex in the middle of a route cancels the whole project
entirely, and this is stated both in the tooltip and in the dialog: silently cancelling half
the route would be a lie.

**Implementation points:** `scripts/project_manager.gd` (`get_project_at_hex`,
`_project_touches_hex`, `cancel_project_at_hex`); `scripts/control_panel.gd`
(`_append_cancel_actions`, `_append_long_action_cancel`, `_make_project_cancel_action`);
`scripts/main_map.gd` (`confirm_cancel_project` — by `project_id`,
`confirm_cancel_expansion`, `confirm_cancel_scouting`, `cancel_scouting`,
`_show_cancel_dialog`); `scripts/build_manager.gd` (`cancel_expansion`,
`cancel_expansion_at_hex`); `scripts/expansion_manager.gd` (passes `money_cost`).
Test: `tests/test_cancel_actions.gd` (headless).
### Road levels and routes

A road consists of **sections** (segments between neighbouring hexes). Each section has a **level** from `data/roads.json`, and a level defines exactly two numbers:

| Field | Meaning |
| --- | --- |
| `work_cost` | The base price of **one section** of this level in labour, before multipliers (terrain, distance from the city, technologies). The formula is the same as before, but the base is taken from the level rather than from the `work_cost` of the special action |
| `max_speed` | **"Maximum speed"**: how many units of resource per second the section can carry. This is NOT the speed of units but the throughput: a farm produces 15 units/sec, but along a trail with `max_speed = 10` no more than 10 will be carried |

| Level | id | max_speed | work_cost | Unlocked |
| --- | --- | --- | --- | --- |
| 1 | `trail` Trail | 10 | 5 | from the start of the game |
| 2 | `cart_road` Cart Road | 30 | 8 | by the "Wheel" technology |

| Decision | Why |
| --- | --- |
| A separate file `data/roads.json` rather than fields in `special_actions.json` | A level is a property of a **section**, not of an action. A copy of one price in two files would diverge at the first balance edit, and "Build Road" would show the price of a trail instead of the one the player chose |
| The level is stored **as a value** in `road_manager.road_segments` | Previously there was a `Set` (`-> true`). With the arrival of levels the value became a payload: a section remembers its level, and no separate list of "which section is of which level" is needed, one that would diverge from this dictionary at the first change to the network |
| Level 1 is paid, even though it is the cheapest | Previously the trail was free when an improvement was built: its price was zeroed by `main_map.get_road_cost_for_improvement`, and the road itself appeared all at once and without payment. The player did not see its cost, and building an improvement on a distant hex was "free with a road". Now the road to an improvement is an ordinary build (see "Road to an improvement"), and it is paid for by whoever ordered it |
| `get_road_step_work_cost` does not let a non-zero base yield a zero section price | The lower bound `maxi(1, …)` remains as protection against a zero base in the data: multipliers below one must not yield zero labour. A zero base (if such a level is added) is charged as zero, and the project runs such a road instantly, without taking a slot |
| The check "a road cannot be built" is by the PLAN, not by the price | Previously `work_cost <= 0` meant "there is no route" (the hex is cut off by water). A zero price is a legitimate state, and declaring it by price would be impossible |
| A free (zero-by-data) road is built immediately, without the project queue | A step with a zero price does not accumulate labour and would not finish by itself — it would hold a build slot forever. For ordinary levels the branch is unreachable, but it remains a safeguard against a "step with no work" |
| The colour and thickness of a section come from the level (`color`, `width`) | Otherwise an upgraded road would be visible only from the labels in the panel. Grouping segments by level is free: the level is already stored as a value |

**There are currently two levels in the game** — enough to verify the end-to-end path of a level (build → route → speed → upgrade). Further levels are added as entries in `data/roads.json` + one technology per era; no code change is needed.

### Route from an improvement to the city

`road_manager.find_route_to_city(row, col, town_row, town_col)` searches for a path **over already built roads** (not over the terrain — this is fundamentally different from `plan_road_to`, which searches for where a road can still be laid). The search is a breadth-first traversal of the network; no knowledge filter is needed: the road already stands where it is visible.

Returns `{ok, reason, path, segments, levels, length, avg_speed}`.

| Field | What it is |
| --- | --- |
| `path` | The hexes of the route from the improvement to the city |
| `segments` | The section keys; **invariant**: `segments[i]` connects `path[i]` and `path[i + 1]` |
| `levels` | The level of each section, parallel to `segments` |
| `avg_speed` | The **arithmetic mean** of the `max_speed` of the route's sections |

The route's speed is the **average over sections, not the minimum**. A route of nine
cart roads and one trail gives `(9*30 + 1*10)/10` = **28 units/sec**, not 10:
one bad pothole on a highway must not suddenly lower the speed of the whole highway.

A separate "bottleneck" value (`min_speed`) deliberately does not exist for a route: it was
introduced in the first version without being requested and removed at the author's demand (see
developer_diary.md). It did not affect the game logic — the availability of the "Upgrade
road" button is computed from the minimum **level** of the sections, not from the minimum
speed.

The route is **cached** by network version (`_route_cache`, reset together with `_plan_cache`). Unlike the plan cache, the map-knowledge version is not part of the key: the route follows roads, not terrain, so it does not depend on scouting.

**Route display.** When an improvement (or a town) with a road is clicked, the route is highlighted on the map with a thin cyan line over the roads (`map_renderer.set_route_segments` + `ROUTE_COLOR`). This is a **separate layer** from the preview ghost: the preview is "what will be built" (semi-transparent, as before), the route is "what is already built and working now". They are never lit at the same time, otherwise the two highlights would compete for the map. The line "Route to the city: N sections, average X units/sec" is shown in the left column of the panel — it is needed all the time, not only while the preview is open.

### Route throughput and delivery time

The "improvement → city" route is described by **two independent quantities**, and they must not be confused:

| Quantity | Formula | Meaning |
| --- | --- | --- |
| **Delivery time** (transit delay) | `route length × transit_time_per_hex` | How many seconds the cargo takes to travel from the improvement to the city. This is a delay, not a loss: the cargo travels and will arrive |
| **Throughput** (flow rate) | the route's average speed `avg_speed` | How many units per second the route is able to **send** from the improvement |

`transit_time_per_hex` is a **single tuning point** (`data/game_balance.json`, the `logistics` block, starting value `0.2` sec/hex). The coefficient is not smeared across formulas: both the engine and the interface take it from `DeliveryManager.get_transit_time_per_hex()`. The route length is already known (`find_route_to_city(...).length`), so the delay is a derived quantity, not a separate data parameter.

**The surplus is no longer lost.** The former behaviour ("an amount equal to the average speed reaches the city, and the rest disappears") has been removed. Now a product that did not fit into the flow **queues on the route**, is sent at the flow's speed, travels for the delivery time, and only then is credited to the city's storage. Production, recipes, labour and balance have not changed — what changed is the fate of the surplus: it **waits** rather than vanishing.

**The limit is per route, not per batch and not per product.** Each route has one shared limit and one queue (FIFO): the batches of one improvement leave in order. **Different routes do not compete** — even if they physically share a road section: three routes of 30 units/sec give 90 units/sec in total. There is no full simulation of "vehicles" and flow priorities: what is modelled is flow and delay, not transport vehicles.

Batches **do not artificially wait for each other**: a new batch is not obliged to wait for the previous one to arrive — both can be en route at the same time if the flow allows.

Without a route (`find_route_to_city` returned `ok = false` — for example, a water improvement beyond a harbor) there is no limit: the product is placed in storage immediately. No road — nothing to limit.

| Point | What it does |
| --- | --- |
| `delivery_manager.gd` | The logistics engine: queues, shipping, transit, receipt. One node per `MainMap` |
| `delivery_manager.advance(delta)` | **Receipt** — every frame: the cargo holds a countdown independent of the time scale |
| `delivery_manager.ship()` | **Shipping** — once per tick (`SHIP_STEP = 1 sec`), right after the tick's production and **before** the interface reads the queue |
| `delivery_manager.create_cargo(row, col, product, quality, amount, source)` | **API hook**: puts cargo on the route. The single entry point for "the goods must travel" |
| `delivery_manager.get_route_status(row, col)` | `{has_route, flow_rate, transit_delay, pending, in_transit, eta}` — the route's state for the interface |
| `main_map._deliver_production(row, col, ...)` | The improvement's output: a route exists → `create_cargo`; no route → straight to storage |
| `main_map._emit_continuous_production(..., row, col, route_avg_speed)` | Computes the output and passes it to `_deliver_production`; it **no longer truncates** `per_sec` |
| `main_map` (production tick) | Computes the average speed via `_route_avg_speed` and sets `tile["road_capacity_short"]` — a flag for drawing |
| `map_tooltip.delivery_lines(row, col)` | The lines "Delivery: awaiting shipment N units" / "in transit N units (arriving within X sec)" — in the extended tooltip and in the left column of the panel |
| `map_tooltip.production_rates` | The single source of product speeds (for display and for the overload check) |
| `map_tooltip.road_capacity_shortfall` | Products whose speed is higher than the route's average speed: `{prod_id: {rate, avg_speed}}` |
| `map_tooltip._append_route_shortfall` | Adds a red marker `(🚧 X units/sec)` to an overloaded product — instead of the word "route", the road icon `icons/special_actions/road.svg` |
| `map_renderer._draw_road_capacity_warning` | Draws a small triangle with "!" above the improvement, next to the water droplet |

| Decision | Why |
| --- | --- |
| The two parameters are separated: delay and flow | These are different questions — "when will it arrive" and "how much per second will leave". A single shared quantity answered neither |
| `transit_time_per_hex` lives in `game_balance.json`, not in the code | The author sets the pace of logistics in one place; the coefficient is not scattered across formulas |
| The surplus **waits in a queue** rather than being lost | The player must not lose already produced goods because of a narrow road: the road sets the pace, it does not destroy the product |
| The limit is **per route**, not per product and not per batch | A route has one physical throughput; splitting it among products would mean inventing a rule the road does not have |
| **Different routes do not compete** | A route is an independent thread; a shared road section must not silently cut off a neighbour |
| Batches **do not wait for each other** | Between an improvement and the city there is no "single cart": cargo travels as a flow, and two batches can be en route at the same time |
| No simulation of transport vehicles | The model is flow and delay, not units: the requirement "no full simulation of vehicles" is met without losing the meaning |
| One manager: receipt per frame, shipping per tick | No per-batch timers: all logistics state is in one place — predictable performance and a simple save |
| Shipping happens **before** the interface reads the queue | The panel reads the queue inside the tick (`do_tick` emits `city_updated`). If shipping happened after, fresh production would hang for a second as "awaiting shipment" even on a road that carries everything; the queue should show only a real jam |
| Changing the `road_capacity_short` flag itself requests a redraw | The map is drawn on demand; without a request, the "!" triangle removed after a road upgrade would hang on the screen until the mouse moved |
| Transit stores a **countdown**, not an absolute time | The save does not depend on the clock: after loading, the cargo continues from the same place, time does not "jump", and the cargo is not duplicated |
| When a route disappears, the cargo is **handed over to storage** (`_flush_route`) | The road could have been demolished or cut off: unfinished cargo must not hang in a nonexistent route |
| The overload comparison is **per product**, not by the sum | An improvement has different output for different products; "average 10, sum 130" does not answer the question of what exactly will not be delivered. The marker is therefore targeted |
| The red marker is in the product's own line, not on a separate line | The player reads "Wheat: 15 units/sec" and right there "(🚧 10 units/sec)": cause and effect in one line |
| The word "route" is replaced by the **road icon** | The full marker "(route 10 units/sec)" did not fit in the narrow left column of the panel and spilled onto the neighbouring one. The icon is ~40 px shorter and the same in all languages |
| The marker is assembled into its own tight row (`HBoxContainer`, `separation = 0`) | "(", the icon, the number and ")" stay together and take up the minimum width |
| The icon takes the marker's colour (`modulate`) | The whole marker reads as a single red tag "the issue is the route", not as a multi-coloured set |
| A single source of speeds (`production_rates`) | The triangle, the marker and the number in the line take the speed from one place — otherwise the icon and the label would diverge |
| The `road_capacity_short` flag is computed on the tick and stored on the hex | Drawing happens per frame and must not recompute production with multipliers every time; the flag is updated once per `SIMULATION_TICK` |
| The marker and the triangle appear only on an improvement with a worker | What is actually carried is what is limited; a stopped improvement has no transport |
| Purchases from towns follow the same path (`create_cargo`) | A purchase does not "materialise" instantly: first the quantity and the payment are recorded, then the cargo travels along the route and arrives by the same rules. The purchase interface is for the future; the engine and API are ready |

### Road level on a hex

**Rule: the road level on a hex = the maximum over the adjacent sections of BOTH networks — the player's city and the towns.** At a crossroads where a trail and a cart road meet, the hex shows the cart road (level 2) — just as it looks on the map. The hex's level is a **derived quantity**, not a stored one: a hex simply has no level of its own, only the level of a section is stored.

Three concepts are deliberately distinguished, and confusing them is a source of errors:

| Concept | Where it lives | What it is |
| --- | --- | --- |
| The level of a **section** | `road_segments["r,c\|r,c"]` (city) and `town_road_segments["r,c\|r,c"]` (towns) | The fact of construction: this piece of road is built thus. The single source of truth |
| The level of a **hex** | not stored, computed as the maximum | "What is the best road that reaches this hex". For display only |
| `tile["road_level"]` | the hex's data | Not the hex's level! It is the save's input data: the level of the section by which the hex was connected to the network |

| Decision | Why |
| --- | --- |
| The hex's level = the **maximum**, not the minimum and not a list | The maximum matches how the hex looks on the map: the road is drawn along the best adjacent section. The list "Trail, Cart Road" was more honest to the data, but contradicted the picture — the player looked at one road and read about two |
| The hex's level is not **stored** | If it were stored and required all adjacent sections to be of its level, then raising one section would require raising all the others adjacent to the same hex, and those would require all adjacent to them: the level would crawl across the **entire connected road network**. The maximum rule requires none of this: a trail through a crossroads remains a trail |
| Sections of **both** networks are taken into account — both the player's city and the towns | The towns' roads are drawn on the map, so the line must describe them: otherwise a road is visible on the hex while the tooltip is silent about it, and the criterion ("whose road is this") is invisible to the player. The level of towns' roads is always a trail (1), the player cannot upgrade them — but the line answers the question "what is drawn on the hex", not "what can be done here". The route (`find_route_to_city`) already counted a town's sections as a trail — now the hex's level is consistent with it |
| The wording "up to N units/sec **per section**" | The best road passes through the hex, not every adjacent section. The player sees the route average separately (the "Route to the city" line), and the label must not read as "the whole road here carries N" |
| The line is shown in the **extended** tooltip and in the **left column** of the panel, but not in the ordinary one | A road's level is not a property of the hex (like terrain or a resource) but its connection to the city. The ordinary tooltip is responsible for "what is on this hex", and cramming logistics into it mixes two different questions |
| The **road upgrade** preview does not contain the "Will produce" block | The player pressed the road upgrade button for the sake of the road. The improvement's production is the "future" of an improvement he is not building, and it also pushed the road-level selection down, forcing him to scroll the preview |
| On a hex with a road the extended tooltip is shown even if there is no production | `has_extended_tooltip_info` returns `true` when a road is present. Otherwise on an empty hex under a road (where the player decides what to improve) the block would not appear at all |
| The line is added in `update_extended_tooltip` **before** the early exits | On a hex without an improvement all the checks below return control earlier, and the line would not appear — yet that is exactly where it is most needed |
| `update_extended_tooltip` accumulates lines and renders them in a **single** call | `render_products` clears the container, and two calls in a row would erase the first: on a hex with a road and a natural resource the road level would silently disappear |
| Hex properties are the single source of lines (`_collect_hex_properties`) | Quality, fodder, fill level and fresh-water access were taken on their own and were assembled in ad-hoc places by separate changes. The common text gathered in the tooltip "what is on this hex" ran up to seven lines |
| The extended block **remembers the hex**, and the content refresh redraws exactly it | The refresh (`InputHandler` → `update_tooltip_text`) runs only for hexes with changing content (`map_tooltip.has_live_content`: a growing resource OR cargo on a route) and rebuilds the shared container from scratch. Without being tied to a hex, the level line would live for exactly one tick: the block's display delay (1 sec) and the refresh period (1 sec) almost coincide |

#### Content refresh does not erase the extended block

Both tooltip blocks — the basic and the extended — live in a **single** container,
`_tooltip_products_container`, and `render_products` clears it before drawing.
Therefore the extended block must survive a repeated call to `update_tooltip_text`.

Such a repeated call is made only by the content refresh in `InputHandler`, and
only on hexes where the content changes over time. The decision is made by
a **single point** — `map_tooltip.has_live_content`, and there are exactly two reasons:
a "growing" resource (`time_to_mature > 0`, that is, a pasture) and **delivery** (there
is cargo in the queue or in transit). Farms, vineyards and forest plots without cargo
have no `time_to_mature` — they do not need a refresh, and the container is not rebuilt needlessly.

`MapTooltip` stores the hex for which the block is shown (`_extended_row` /
`_extended_col`), and in that case `update_tooltip_text` substitutes the set of
lines of the extended block instead of the basic one. Both points — showing the block and
redrawing it — collect the lines in one function, `_collect_extended_block`,
so that the lists do not diverge.

The binding is reset in the two places where the `InputHandler`'s own flag
("the block is already shown") is also reset: on a **change of hex** and on
**hiding the tooltip** (`clear_extended_tooltip`). Without the reset, returning to the same hex
would draw the extended block immediately, bypassing the hover delay.

#### Delivery updates in real time

The delivery lines ("awaiting shipment" / "in transit") describe a **live process**:
the queue shrinks, the cargo sets off and arrives. While the tooltip was tied to
the "pastures only" refresh, on a hex with a route it **froze** — it showed
the state at the moment of appearance and never changed again (delivery is not a growing
resource, it has no `time_to_mature`).

The "awaiting shipment" line shows **only a real jam**: the current tick's
production is shipped before the interface reads the queue (see "Route throughput
and delivery time"), so on a road that carries everything
the queue is empty rather than flickering with fresh production for a second.

The fix is one reason in the `has_live_content` list:

| Decision | Why |
| --- | --- |
| The "whether to update" decision lives in a **single** point (`map_tooltip.has_live_content`), not in two places | While the list of reasons was in `InputHandler` separately from the block's lines, delivery was added to the block but forgotten in the reason — and the tooltip froze. A shared point keeps the lists from diverging (the same principle as with `has_extended_tooltip_info`) |
| `has_live_content` is a **pure function** of the hex | It is called every frame while the mouse is on the hex; it has no right to touch the labels (just like `_collect_extended_block`) |
| The period is the same `CityData.resource_display_interval` as for the rest of the interface | The data changes on 1 sec ticks, and the whole UI updates synchronously, "in one jerk" per interval (1..5 sec, a setting). A separate period for delivery would put the tooltip and the panel's left column out of phase |
| The growing resource moved into `map_tooltip` from `InputHandler` | Both refresh reasons are now in one place; otherwise "why does it update" would have to be searched for in two files |

**Test.** `tests/test_tooltip_live_refresh.gd` — a hex without cargo is static, with
cargo it is "live" (the check fails if delivery is removed from `has_live_content`),
a delivery step changes the shown block, after the cargo is carried away the hex is static again.

### Ordinary and extended hex tooltips

The hover tooltip for a hex has two levels: the ordinary (immediately) and the extended (after a hover delay configured in the "Extended map tooltip delay" menu). Both are assembled by a single class — `MapTooltip` (`scripts/map_tooltip.gd`).

| Level | What it shows |
| --- | --- |
| Ordinary tooltip | Terrain with cover (rivers, lakes, forest, village), the terrain description, the resource, an improvement with its status, markers of foreign territory, the conflict hint "Demolish ...". That is, one answer: "what is on this hex" |
| Extended block | The road level, delivery (awaiting shipment / in transit), hex properties (quality, fodder, fill level, fresh water), production with modifiers and profession expenses |
| The panel's left column | The full set — everything at once, without a hover delay; the hex properties remain |

**Why the split is like this.** The ordinary tooltip answers the question "what stands on this hex", and everything else is properties that change over time: a pasture's fill level, output, expenses. Previously the tooltip grew to six or eight lines and appeared in full immediately on hover, even though half of those lines are far from always needed.

**A single source of lines.** The hex properties are collected by one function for both addressees: `MapTooltip._collect_hex_properties` (properties) and `MapTooltip._collect_extended_block` (road level lines, production, expenses) — the texts are not duplicated in two places.

**The decision about the check.** `has_extended_tooltip_info` does not enumerate conditions but asks the same assembler that builds the block: "show it if the block is non-empty". A list of conditions and a list of lines written separately will sooner or later diverge — and the block will either not appear at all or appear empty.

**Test.** `tests/test_hex_tooltip_split.gd` — the separation of the basic and extended block, the completeness of the panel's left-column text, the match between "whether to show" and the block's non-emptiness, and a refresh that does not erase the extended block. Live delivery update — `tests/test_tooltip_live_refresh.gd` (see "Delivery updates in real time").

#### Production lines: the speed per second

The product line in the extended tooltip, in the panel's left column and in the build preview shows a **single** number — the speed per second. The source of the lines is one: `map_tooltip._collect_extended_production` (tooltip and panel) and `control_panel._build_preview` (preview) keep the same format.

| Concept | Where it lives | Does the player see it |
| --- | --- | --- |
| Speed | the resource's `produces` (`data/resources/*.json`), units/sec | Yes — the single number of the line |

**`produces` is the rate.** The player receives a **continuous flow**: `main_map._emit_continuous_production` on every tick (`SIMULATION_TICK = 1 sec`) adds `produces × multiplier × SIMULATION_TICK` units to storage. Limestone with `produces: { "limestone": 10 }` gives exactly **10 units every second**. There is no separate "output per cycle" quantity and no cycle interval in the data: the number in `produces` is the number the player gets per second.

| Decision | Why |
| --- | --- |
| The speed equals `produces` directly | The player manages a flow per second: the road's throughput, the profession's expenses and the "Resources" tab are all compared with this speed — everything in "units/sec" |
| The "when built" hint shows the **full** speed | The livestock only starts to fill up after construction, so on a hex without an improvement the fill fraction is 0. The hint describes the future and takes the potential output, while a working improvement takes the current fraction |

Test: `tests/test_production_display.gd`.

### The "Upgrade road" button and a partially upgraded route

The button is determined by the **route to the city**, not by the hex's contents: it is present on **any** hex that has a route and at least one section below the best available level — including an **empty** hex without a resource or an improvement. The player has the right to upgrade the road to a hex where he is only planning to build something.

The button is shown as long as there is **at least one** section below the best available level on the route, that is, the **minimum** of the route's levels is checked.

Previously the maximum was checked, and the button disappeared on a partially upgraded route: it was enough to upgrade one section out of four — the maximum became equal to the best level, the button vanished, although three trails remained. To the player this looked like "the route is already upgraded", and there was nothing to finish the road with. The class of bug is "an incomplete state looks like a finished one".

A separate bug of the same kind: the call to `_append_upgrade_road_action` sat inside the branch for a hex **with an improvement**, which ended with `return`, so on an empty hex with a road the button was absent altogether. The player saw the button on a neighbouring hex with an improvement and did not understand the criterion. Now the call is present in both branches of `_collect_actions` — both on a hex with an improvement and on one without.

### Road upgrade

A separate panel action (`control_panel.UPGRADE_ROAD_TYPE`), **not** a special action from `data/special_actions.json`: an upgrade does not change the hex's contents and has no `work_cost` of its own (the section's price is taken from the level), so it lives as a panel action type.

| Aspect | How it works |
| --- | --- |
| When the button appears | On **any** hex of the Influence Ring (with or without an improvement) that has a route to the city and at least one of its sections below the best available level. A button with an unreachable goal is noise in the action column |
| What is upgraded | The **whole route** from the city to the hex, not the last section: the route's speed is determined by the narrowest section, so upgrading one end achieves nothing |
| Ghost | The same `ROAD_PREVIEW_*` style as when building: the sections already stand, but the player must see which one is being upgraded |
| Implementation | The same `project_manager`, `kind = "road_upgrade"`, with steps one section at a time from the city to the target. `road_manager.upgrade_road_segment` does **not lower** the level and returns `false` if there is nothing to upgrade: an empty project step is a step with no work |
| Price and start | `main_map.get_road_upgrade_breakdown` — a single source for the preview and the start, as with a new road |

**The level in the preview** is the shared `_build_road_level_selector` block for three cases ("Build Road", building an improvement, "Upgrade road"): a button for every **researched** level, from the best to the worst; by default the best available is selected, but the player can choose any earlier one, including the basic trail. The level is part of the preview snapshot (`_preview_equal`) — otherwise the preview would remain from the previous level and would show the trail's price when a cart road is selected.

The road to an **improvement** is no longer part of the improvement's price: it is a separate build with its own queue of sections and its own price (see "Road to an improvement"). The preview shows both sums — `Improvement: N work` and `Road to the city (level): M work` — plus the total, and the route of new sections is drawn on the map.

### Route preview on the map (the "ghost" road)

While the "Build Road" preview is open, the route is drawn right on the map: a semi-transparent road, a halo + a line on top (`map_renderer.ROAD_PREVIEW_*`). This is not decoration but an answer to the question "why is it so expensive": for a road to a town the route follows explored land and can wind noticeably, and without the highlight the price in the preview looks like an error.

| Aspect | Decision |
| --- | --- |
| What is drawn | Only the **new** segments of the plan (`road_manager.get_plan_new_segments`). Already built sections are skipped: the player does not pay for them |
| When | Exactly while the preview is open. The synchronisation lives in `control_panel._sync_road_preview_on_map()`, called from `_refresh()` — this way the route updates when the plan changes (for example, after scouting) and is removed on ESC, on a click on another hex, and on confirming the construction |
| Where in the drawing | PHASE 2g in `_draw_all_roads()` — the last pass over roads: above real roads, below rivers, highlights and icons. The early `return` for town roads was replaced by an `if`, otherwise in era 1 the preview would not be drawn |
| Era gate | **None**: this is a hint, not a construction, and it is shown in any era, like the city's roads. The fog gate is checked (`_segment_clear_of_fog`) — the plan cannot reach into the fog, but the possibility of "revealing" it is excluded |
| Redraw | `set_road_preview_segments()` compares the signature of the set of segments and redraws the map only when the route really changes — the panel keeps the preview open between ticks |

The geometry, the meanders and the clipping of invisible segments are not duplicated: `_draw_road_segments()` received optional `color` / `width`, so the ghost is drawn by the same code as a real road.

**Visual check.** `tools/diag_road_preview.gd` (one-off, outside the git index): raises a live match, opens the preview and saves a frame to `tools/diag_road_preview.png` — in headless a snapshot is impossible (the driver has no rasterisation), so the script runs with a window and exits by itself.

**Test.** `tests/test_road_building.gd`: synthetic — there are exactly as many preview segments as in the plan, all between neighbouring hexes, the route reaches the already built network of the city, the sampling builds nothing and empties after construction; a live scene — with the preview open the route on the map equals the plan, after ESC it disappears, and the route to the town runs entirely over explored land. A separate case, `merge_adjacent_roads`, checks the merging of a new road with a neighbouring hex of the same network (the target hex neighbours two connected hexes at once — before the fix exactly one of the two segments remained unbuilt).

### Road to a town and the link with the city

On the hex of an **explored town** the same "Build Road" button appears, but its target is special: **the town itself (its centre)**, not the nearest road in the influence ring. The player chooses a road level, and that level must reach the town: otherwise the highway would run into the town's own trail at the ring's edge and lose its quality. The route is found by Dijkstra from the town's centre to the nearest road of the city's network, after which the segments go into the **city's** network. Where the route passes over the town's own trail (the "centre → ring" section), the city's network holds a section of the chosen level: the route and the tooltip take the level from the city's network (`road_manager._segment_level_by_key`), and the renderer does not draw the town's trail over the highway.

**The route runs only over territory known to the player.** A road that the player builds cannot pass through the fog of war: the `hex_allowed` restriction in `road_manager._find_path_between()` (both the neighbours and the **source hex** — the town's centre — are checked) receives `main_map.is_hex_known` (`in_influence || is_explored`). For a town this is literally the same requirement as access to its interface: one cannot even approach an unexplored settlement. Automatic road networks do not get the filter: the city's improvements stand in the Influence Ring, and a town scouts its surroundings itself.

A consequence for the player: seeing a town is not enough — the way to it must also be explored. Scouting opens chunks adjacent to known land, so the corridor to the town opens by the same path by which the player got there, and the route will repeat it (and may even shorten it — Dijkstra searches for the shortest path over known land, not over the history of wanderings).

The failure reason distinguishes two cases, and this is fundamental: "a path exists but is not explored" — calls for scouts, "there is no land path at all (the town is beyond water)" — honestly admits that a road is impossible. The second case is checked by the same search without the knowledge restriction and only on an unsuccessful plan (the result is cached, so there is no extra Dijkstra per tick). `build_manager` no longer invents its own message but takes the text from the plan.

The plan cache must be reset when knowledge changes, otherwise the panel would keep showing "no road" even after the player has explored the passage. This is handled by `road_manager.bump_map_knowledge()`, which is called from `main_map` in four places: completion of scouting (`_complete_scouting`), claiming land (`_on_territory_expanded`), advancing to the next era (`advance_to_next_era`) and the debug opening of the whole map (`debug_open_whole_map`). Restoring a road from a save uses the same filter (`rebuild_player_roads(tile_data, ..., _road_hex_allowed())`).

The connection is recorded by two independent layers:

| Layer | Where | Why |
| --- | --- | --- |
| A computed flag "currently connected" | `road_manager.is_town_linked_to_city()` — the intersection of the road networks of the city and the town | The icon above the town's hex is drawn; the renderer and the test also use it to decide whether to show the icon |
| A stored fact "the player built this" | `town["road_linked"]` in the town's record (`serialize_towns` / `load_towns`) | Input data for restoring the link from a save and a flag of trade availability |

The link icon is two curved arrows pointing at each other, drawn procedurally (`map_renderer._draw_trade_link_icon`) above the town's icon. Its size is set by the **same** constant as the fresh-water droplet: `map_renderer.MARKER_ICON_RADIUS` (6 px). The icon is drawn only for a revealed town (otherwise it would give away what the player has not yet reached).

The road segments to a town are stored separately from the rest (`road_manager.town_link_segments`) and are drawn with the same gates as the towns' roads: from the Antiquity era and provided both ends of the segment are outside the fog of war. The gate here is a safeguard for the future: by the rule "only over explored land" such a road cannot be built through an unexplored hex, so in practice its ends are always known. They are drawn **by level** (from the city's network), and sections of the town's network already covered by the player's road are not drawn over it — otherwise the highway to the town would visually turn into a trail on the last hexes.

**Trade and the road-requirement stub.** The town's interface opens **always**, regardless of the road: an explored town can be viewed without it. The road gates only the trade itself, and the trade itself is not yet implemented — so the requirement is formalised by a single stub function:

```gdscript
# town_manager.gd
const TOWN_TRADE_REQUIRES_ROAD := true
func is_trade_available(town: Dictionary) -> bool:
    if not TOWN_TRADE_REQUIRES_ROAD:
        return true
    return bool(town.get("road_linked", false))
```

All consumers ask it: the control panel (the tooltip of the "Open town" button) and the town window (`town_ui.open_town(town, trade_available)`, where without a road the label "Trade unavailable: there is no road from the city to this town" is shown). When real trade appears, the stub is removed in one place: the value of the constant is changed to `false`, or the function itself is rewritten to the real rules.

### Scouting and the Cartography technology

The rule "scouts can be sent anywhere the scroll can reach" applies **only after researching the Cartography technology** (`data/technologies/antiquity.json`, id `cartography`, requirement — Writing).

| Player action | Before Cartography | After Cartography |
| --- | --- | --- |
| Hovering the cursor over a hex outside the Region (fog of war) | The hex is unavailable: no tooltip, the chunk highlight is not drawn | The chunk highlight is present, but there is no tooltip: the fog does not give away information about the hex (see `is_hex_in_fog`) |
| Information about the hex (tooltip / left column of the panel) | — | In the Ring+Region the terrain is visible (the resource — only after scouting); in the fog of war — the placeholder "Hex not scouted" |
| LMB click on a hex in the fog of war | The hex is not selected (the HUD shows a hint that the technology is needed) | The hex is selected, the "Send scouts" button becomes available |
| Composition of the scouting chunk (BFS) | Only the unexplored hexes of the **Region** | The whole area reachable by scrolling (including the fog of war and the territory of towns) |
| Where scouting is allowed (adjacency to the known world) | Only chunks bordering the Influence Ring or explored hexes | The same rule: fog-of-war chunks at the border of the known world |
| Buying (claiming) a chunk | Only the Region (unchanged) | Only the Region (unchanged) |

**Adjacency rule (as of 2026-09).** Scouts can only be sent into a chunk that has **at least one hex bordering known territory** — the Influence Ring (`in_influence`) or an explored hex (`is_explored`). Free "pockets" in the fog of war cannot be scouted: scouts do not jump over unexplored land. A chunk that does not border the known world is still assembled and highlighted — but in a muted (desaturated) tone: the player sees what they have selected and immediately understands from its appearance that scouts cannot be sent there, and the "Send scouts" button is inactive with the hint "The area does not border explored territory" — the same UX as for claiming ("The area does not border your territory").

Practical consequences:

1. It is the **chunk** that is checked, not the clicked hex: a BFS chunk of 5 hexes that reaches the border of the known world is allowed, even if the click was made on a hex one step deeper.
2. At the start of a new game `is_explored` is set nowhere, including the Influence Ring (see `_initialize_map`), so the Ring also counts as known — otherwise scouting would be impossible in principle.
3. The border of the known world "creeps": after an expedition completes, its hexes become explored, and the next chunk beyond them becomes available. With `region_width = 2` this means: first the inner strip of the Region (bordering the Ring), then the outer one (bordering the inner one), and then — after Cartography — the fog of war.
4. Hexes neighbouring the Influence Ring do not themselves touch the fog (the Region is a strip of width `region_width`), so the "bridge" into the fog is the outer strip of the Region.
5. When the era changes, the whole former Region is explored and becomes the Ring, so the border automatically shifts to the new Region.

**Implementation points:**

- `scripts/main_map.gd` — the constant `CARTOGRAPHY_TECH_ID`, `is_cartography_researched()`, `is_hex_interactive()` (the Region — always, the fog of war — only with the technology), `get_region_bounds()` (the Region's bounds in the format of `get_scout_reach_bounds()`), `is_hex_known()` (known territory: `in_influence` or `is_explored`), `is_chunk_adjacent_to_known()` (adjacency of a chunk to the known world, neighbours via `HexUtils.get_neighbors_odd_r`), safety checks in `start_scouting()` (an empty chunk and a lack of adjacency — a refusal BEFORE debiting coins).
- `scripts/expansion_manager.gd` — `get_chunk_hexes()`: for an unexplored starting hex the BFS runs over `get_scout_reach_bounds()` only with Cartography researched, otherwise over `get_region_bounds()`; outside the Region without the technology the chunk is empty (otherwise it would consist of a single starting hex and produce a highlight in the fog). The chunk itself is assembled regardless of adjacency — the gate is applied by the UI and `start_scouting()`. `get_highlight_hexes()` gives the renderer the set of hexes to highlight on hover/selection: the chunk, or, if there is no chunk, for an explored hex outside the Region a highlight chunk of up to 5 hexes built by BFS outward from the hex under the cursor (`_get_explored_chunk_hexes()`; the same fallback is used for selection by click), and for a hex in the influence ring of a foreign town — the hex itself, so that a click is not "silent". Change detection in `update_hovered_chunk()` goes by the highlight set, not by the action chunk, otherwise moving between explored areas would yield `[] == []` and a "frozen" highlight.
- `scripts/control_panel.gd` — `_collect_region_actions()`: for a non-adjacent chunk the "Send scouts" button is inactive (`enabled = not is_scouting and known_neighbor`) with the reason in the tooltip. The left column of the panel for a hex in the fog of war shows the placeholder "Hex not scouted — information unavailable" instead of terrain/resources.
- `scripts/InputHandler.gd` — `_interactive_hex_at()` (the gate for hover, highlight and click); `_pixel_to_hex()` remains pure geometry (it is used by the debug mode).
- `scripts/map_renderer.gd` — `_draw_exploration_highlights()`: a green fill for explored hexes (there is no longer a white outline), a safety filter for the highlight (it does not go outside the Region without the technology) and the highlight of the chunk/hex under the cursor — via `expansion_manager.get_highlight_hexes()`; selection by click (PHASE 3.5) draws the same set. The colours are computed by `_get_highlight_style()` — a palette of four types (scouting/claiming × allowed/not allowed, see the section on highlighting in the "Control panel" section).
- `scripts/CityData.gd` — `get_tech_name()` (the technology name for HUD messages).
- `tools/test_scouting_frontier.gd` — a headless test of the adjacency rule (a positive case at the Ring, an invariant over the whole map, a refusal for a detached chunk without debiting coins, a border shift when an explored neighbour appears).
- `tools/test_highlight_hexes.gd` — a headless highlight test: for every hex of the map the highlight set is non-empty (the chunk or the hex itself); the Influence Ring, the Region, the fog of war and a foreign town's ring are checked.
- `tools/test_fog_info.gd` — a headless test of "the fog gives away no information": the fog predicate, the placeholder in the left column of the panel without terrain/resources, the appearance of information after scouting, and the safety check of `update_tooltip_text()`.

### Cost of scouting (coins from the treasury)

As of 2026-09 scouting (sending scouts into a chunk) is **not paid for with food** — an expedition costs **coins from the city treasury**. Food remains only for feeding the population and for growth.

**Formula.** `chunk price = Σ over hexes ceil(base × (1 + hex distance × distance modifier))`, where:

| Parameter | Where it lives | Default |
| --- | --- | --- |
| base — the scouting price of one hex | `data/game_balance.json`, `scouting_cost_per_hex` | `3` coins |
| distance modifier | `data/game_balance.json`, `distance_cost_modifier_per_hex` | `0.25` (+25% per hex) |

The distance is measured from the city hex (`HexUtils.hex_distance`) — the same value as in the work cost of improvements. The price of a chunk is the sum of the prices of its hexes, so distant chunks are more expensive than nearby ones. Tech modifiers (for example, the "Wheel") **do not affect** scouting: they are about hauling goods, while scouts go on foot or ride horses.

**How it works:**

1. The player selects an unexplored chunk → "Send scouts". The tooltip shows the price: "Send scouts: N coins from the treasury, time [K sec.]". The player always sees the treasury in the HUD — it is deliberately NOT included in the tooltip: values that change every tick make tooltips differ, and the panel rebuilds the buttons and the hovered tooltip is reset (see `control_panel._build_actions`).
2. On confirmation the coins are debited from the treasury **immediately** (`CityData.spend_treasury`), and then the scouting timer runs (3 sec. per hex).
3. If there are not enough coins, the HUD says "Not enough coins in the treasury! Need N, treasury has M", scouting does not start, and the treasury does not go negative.

**Distance modifiers.** The field `distance_cost_modifier_per_hex` in `data/game_balance.json` is **shared by all the costs of a single building**; there is no longer a hardcoded `0.25` in the code:

| What gets more expensive with distance | Where it is computed |
| --- | --- |
| The work of building improvements and special actions | `MapHelpers.get_improvement_work_cost()` (tech modifiers are applied on top of it there too, target `improvement_distance_cost`) |
| The coins for scouting a chunk | `expansion_manager.get_hex_scout_cost()` |
| The coins for claiming a chunk | `expansion_manager.get_hex_money_cost()` |

The single point for reading the value is `MapHelpers.get_distance_cost_modifier()`, and the multiplier itself is `MapHelpers.get_distance_mult(distance) = 1 + distance × modifier`. The work of claiming is **not** scaled by distance (a balance decision: what gets more expensive farther from the city is logistics, not the work itself).

**A road section has its own coefficient** — `road_distance_cost_modifier_per_hex` (`0.1`), the function `MapHelpers.get_road_distance_mult()`. The exception is not out of carelessness: the common multiplier is applied to a single building, where the player chooses the hex themselves, whereas here it is applied to every section of a route, that is, it is multiplied by its length. With `0.25` section No. 20 would cost 6 times as much as the first, and the road to a distant town would become permanently unaffordable. The formula is the same (`1 + distance × coefficient`) and the tech modifiers are the same — the "Wheel" reduces the contribution of distance both in improvements and in the road, through a single function `get_distance_tech_mult()`.

**Terrain multiplier** — `work_cost_mult` from `terrains/terrains.json`, shared by improvements and road sections (`MapHelpers.get_terrain_work_mult()`). "Construction difficulty" does not depend on what exactly is being built, and duplicating the table of multipliers in the road code would mean discovering a new terrain in the data a month later and forgetting about it.

**Implementation points:** `scripts/expansion_manager.gd` (`get_scout_cost_per_hex()`, `get_hex_scout_cost()`, `get_chunk_scout_cost()`), `scripts/main_map.gd` (`start_scouting(chunk)` — the price is computed inside the method, the coins are debited via `CityData.spend_treasury()`), `scripts/control_panel.gd` (the button and the tooltip), `scripts/CityData.gd` (`spend_treasury()`), `scripts/map_helpers.gd` (`get_distance_cost_modifier()` / `get_distance_mult()`).

### Claiming territory: labour + coins

As of 2026-09 buying chunks (expanding the Influence Ring) is paid for with **coins from the treasury + work** (food is no longer part of the payment). The cost of claiming consists of two parts:

| Part | What it is | Where it comes from | Rationale |
| --- | --- | --- | --- |
| **Work** (the main cost) | Accumulation of work through construction over time; it is **not** scaled by distance | The terrain's `expansion_cost` in `data/terrains.json` (this is work, not food) | Claiming new lands requires the labour of settlers |
| **Coins** (the chunk price) | Debited from the treasury immediately when claiming starts | `expansion_cost_per_hex` in `data/game_balance.json` × the distance modifier `distance_cost_modifier_per_hex` (per hex, rounded up) | The equipment and logistics of an expedition: distant lands cost more |

**How it works:**

1. The player selects an explored chunk (RMB) → "Claim the area".
2. The context menu shows: the number of tiles, the price in coins, the required work and the estimated time (`work / city work`).
3. On confirmation **the coins are debited from the treasury immediately**, and **the work accumulates over time** through the common work pool of `build_manager` (like the construction of buildings/improvements). If there are not enough coins — a refusal without debiting; if the construction did not start (for example, the limit of simultaneous constructions has been exhausted), the coins are returned to the treasury.
4. Once the work has accumulated, `build_manager` emits the signal `expansion_build_completed(chunk)`, and `expansion_manager` joins the chunk to the Influence Ring (`in_influence = true`).

**Key files:**

- `scripts/expansion_manager.gd` — the claiming logic: `get_hex_cost()`/`get_chunk_cost()` (work from `expansion_cost`), `get_hex_money_cost()`/`get_chunk_money_cost()` (coins = `expansion_cost_per_hex` × distance modifier, per hex), `handle_action()` (debiting coins + starting the construction, returning the coins if the construction is refused), `on_expansion_build_completed()` (joining the chunk).
- `scripts/build_manager.gd` — the claiming construction: `start_expansion_build()`, the dictionary `active_expansion_builds`, the signal `expansion_build_completed`, the progress bar via `get_expansion_progress_for_hex()`.
- `scripts/progress_bar_layer.gd` — the orange claiming progress bar on the first hex of the chunk.
- `data/terrains.json` — `expansion_cost` now means **work** (not food).

**Work balance.** The multiplier for the number of purchased hexes has been removed: the work stays "moderate" and does not balloon as the city grows. Even claiming 5 mountain hexes (5 × the `expansion_cost` of mountains = 5 × 5 = 25 work) takes seconds of real time at a normal city work rate.

**Coin balance.** The money part is computed per hex with the universal distance modifier (5 coins per hex near the city, more expensive towards the edge of the Region) and is tuned by the `expansion_cost_per_hex` field in `data/game_balance.json` — without touching the code. A benchmark: the first chunk at the Ring ≈ 60 coins, the far edge of the Region ≈ 90-100 (with a starting treasury of 100).

**Saving.** Claiming constructions are saved to the save in the `active_expansion_builds` block and restored via `build_manager.restore_expansion_builds()`.

---

### Debug menu: "Ignore construction requirements"

The `[7]` toggle in the debug menu (F9) — the flag `CityData.ignore_build_requirements`. It makes **any action that spends time or resources instant and free**. The flag lives only at runtime and is **not saved to the save**.

| What | How it behaves with the flag on |
| --- | --- |
| City buildings | Are built instantly, do not queue; the limit of simultaneous constructions does not apply; `additional_cost` is not checked and not debited; `additional_req` is considered fulfilled |
| Building upgrade | Instantly and without debiting the `additional_cost` of the upgraded version |
| Improvements on the map | Instantly, without a queue and without a construction limit |
| **Special actions** (clearing forest, gathering wild plants, draining marshes, demolishing an improvement, road) | Instantly; the button is not blocked by an exhausted construction limit |
| **Scouting a chunk** | Instantly and free: coins are not debited from the treasury, the timer does not start, the chunk is scouted within the same `start_scouting()` call |
| **Claiming territory** | Instantly and free: coins are not debited, the chunk joins the Influence Ring by the same signal `expansion_build_completed` as on a normal completion |
| Constructions started **before** the flag is enabled | Are brought to 100% in a single frame — there are no exceptions, the toggle acts on everything already in the pool |

**What the flag does NOT override.**

- **Technology requirements** (`unlock_tech` for buildings, improvements and special actions, the Cartography requirement for scouting, the adjacency of a chunk to known territory) — for that there is a separate toggle "Ignore technology requirements".
- **The geometry of the action.** A road is still built only where a route can be laid at all; scouting — only into a chunk bordering the known world. Otherwise the action would simply have nothing to act on: to "instantly build" a road that cannot be reached would mean building it anyhow.

**Interface.** The scouting and claiming tooltips in this mode are static ("instantly and free (debug)") — they contain neither treasury nor time, so as not to reset the hovered tooltip every tick (see the convention in `control_panel._build_actions`). In the preview of special actions and the road a yellow line is added: "Debug: instant and free"; the price calculation below it stays as before, so that it is visible how much the construction would have cost without the flag. The flag's state is part of the preview snapshot, so toggling it immediately redraws the open block.

**Implementation points:** `build_manager.gd` (`_process` — early completion of any construction, `start_expansion_build` — instant claiming), `expansion_manager.gd` (`handle_action` — the coins for claiming), `main_map.gd` (`start_scouting` — instant free scouting), `control_panel.gd` (`_append_special_action` — the construction-limit gate removed, `_collect_region_actions` — tooltips, `_add_instant_hint` — the line in the preview), `CityData.gd` (the flag itself, `check_building_additional_req`, `consume_additional_cost`).

**Test.** `tests/test_ignore_build_requirements.gd` — on the live scene `MainMap.tscn` it checks both polarities of the flag for scouting, claiming, gathering wild plants and draining marshes, the gate of the limit of simultaneous constructions, and the early completion of a claiming construction started before the flag.

---

### Advancing to the next era

The **"Advance to the next era"** button in the debug menu (F9) does the following:

1. The whole current (unpurchased) Region is explored **instantly and free**.
2. The whole current Region is bought/joined **instantly and free** (`in_influence = true`).
3. The former Ring + Region become the **new Influence Ring**.
4. Around the new Ring a **new Region of the same width** (`region_width`) is formed.
5. Hexes beyond the new Ring + Region are still hidden by the fog of war.

Implementation: `main_map.advance_to_next_era()`.

### Saving the world state

The save stores a `map_state` block containing the map dimensions, the current Ring/Region dimensions and the era number. On load the state is restored before `tile_data` is built.

---

## Hex control panel (ControlPanel)

At the bottom of the game map a control panel is **always** visible (`scenes/MainMap.tscn`, node `ControlPanel`, script `scripts/control_panel.gd`). The panel's height is **20% of the window height** (`anchor_top = 0.8`, `anchor_bottom = 1.0`).

### How it works

1. The player clicks **LMB** on a hex in the Influence Ring → the hex is selected (fill + outline, drawn in `map_renderer.gd`), and information and actions appear in the panel. Outside the Ring the whole scouting/claiming chunk is selected; if there is no chunk and the hex is explored (an explored area outside the Region) — a highlight chunk of up to 5 hexes built by BFS from the selected hex; if there is no chunk and the hex is in the influence ring of a foreign town — the hex itself: the set for highlighting is computed by `expansion_manager.get_highlight_hexes()`, so the highlight always matches what the panel's actions apply to. The highlight style encodes the type and the availability of the action: the tone — scouting or claiming, the muting of the tone — that the chunk does not border known territory and the action is unavailable; on hover the outline is thin, on click it is thick. The single source of the concrete colour values is `map_renderer._get_highlight_style()`; they are not duplicated in the code or the documentation. For a hex in the fog of war (`main_map.is_hex_in_fog()`) a placeholder is shown instead of information: "Hex not scouted — information unavailable": terrain, resources and improvements are hidden until the hex is scouted.
2. The **left (larger) part** — full information about the hex: terrain, cover, movement cost, resource, improvement, fresh water access, quality, production with modifiers. The source is `MapTooltip.build_hex_info()` (`scripts/map_tooltip.gd`), shared with the tooltip so that the display does not diverge. For a hex in the fog of war (`main_map.is_hex_in_fog()`) a placeholder is shown instead of information: "Hex not scouted — information unavailable": terrain, resources and improvements are hidden until the hex is scouted.
3. The **right (smaller) part** — action buttons for the selected hex.
4. Clicking an action button (for example, "Build Farm") opens a **preview**: the production calculation taking into account all modifiers (water, terrain, technologies) + the "Build" and "Cancel" buttons. Cancel also resets the preview.
5. **ESC** resets first the preview, then the selection. **Clicking another hex** also resets the preview (the selection moves to the new hex).
6. The panel **does not show stale data**: it updates on the signals `worker_manager.assignment_changed`, `build_manager.build_completed/build_cancelled/build_paused`, `CityData.city_updated/research_completed`, `expansion_manager.territory_expanded`.

### Availability of actions

- Actions **possible for the given hex** are shown (obviously inapplicable ones are filtered out, for example there is no "Clear forest" button on a hex without forest).
- Actions **currently unavailable** are **grey** + a tooltip with the reason: "technology X is required", "no work available: construction limit (number of citizens) reached", "No free workers", "the resource has not been discovered yet", and so on.
- A hex outside the Influence Ring: the only grey button hints that the territory must first be claimed (RMB → "Claim").
- Scouting: for an unexplored hex there is a "Send scouts" button, but it is **grey with the reason "The area does not border explored territory"** if the chunk does not border the known world (the Influence Ring or explored hexes) — see docs.md, "Scouting and the Cartography technology". The yellow highlight of the chunk remains: the player sees exactly what they have selected and understands why the action is unavailable.
- Claiming: for a chunk not bordering the Influence Ring, the "Claim the area" button is grey with the reason "The area does not border your territory".

### Construction scenario (preview → confirmation)

1. The hex has the resource "Wheat" → the "Build Farm" button appears in the right part.
2. Clicking the button adds a preview: "Will produce: Wheat: N, Feed: N" (taking modifiers into account) + "Cost: N work" + the "Build" / "Cancel" buttons.
3. "Build" starts construction via `build_manager.start_build(row, col, "farm", target_res_id)` — the preview is reset, the selection is kept.
4. "Cancel" or ESC resets the preview — "building a farm on a neighbouring tile with the old button" is impossible.

### Key files

- `scripts/control_panel.gd` — the panel controller: state (`_selected_hex`, `_preview_action`), action collection (`_collect_actions`), preview (`_build_preview`), confirmation (`_confirm_build`).
- `scripts/map_tooltip.gd` — `build_hex_info()` (text + products) and `render_products()` — the shared list renderer.
- `scripts/main_map.gd` — `select_hex()` / `clear_selection()`, public wrappers for the panel, connection of the update signals.
- `scripts/InputHandler.gd` — LMB click on a hex → `main_map.select_hex()`; ESC resets the preview/selection.
- `scripts/map_renderer.gd` — `_draw_selected_hex_highlight()`: fill + outline; the style (the action's tone, muting = unavailable, outline thickness = hover/click) is taken from `_get_highlight_style()`; the set of hexes (a single hex in the Influence Ring, the whole chunk, or, when the chunk is empty, a chunk of up to 5 explored hexes from the selected hex, or the hex itself) is computed by `expansion_manager.get_highlight_hexes()`.

---

## Quick reference

| File | What it describes | Key technology field |
| --- | --- | --- |
| `technologies.json` | Technologies | — (the technologies themselves) |
| `resources/*.json` | Resources on the map | **`tech_required`** — appearance on the map |
| `buildings.json` | Buildings | `unlock_tech` — availability of construction |
| `improvements.json` | Improvements on tiles | `unlock_tech` — availability of construction; `no_worker` — infrastructure improvements (without a worker) |
| `crafts.json` | Production recipes | `unlock_tech` — availability of the recipe |
| `products/*.json` | Goods in storage | `unlock_tech` — availability of the goods |
| `consumption.json` | Registry of professional consumption (profession → product or `@`-group) | — |
| `categories.json` | Categories for the "Resources" tab | — |
| `groups.json` | Groups for variety bonuses | — |
| `product_groups.json` | Groups for substitution into recipes (`@`) | — |
| `eras.json` | Eras | — |
| `terrains.json` | Terrain types (relief) + `cover_chance` | — |
| `covers.json` | Cover (forest, etc.) | — |
| `special_actions.json` | Special actions (clearing forest, etc.) | `unlock_tech` — availability of the action |
| `bonuses.json` | Variety bonuses | — |
| `game_balance.json` | Numeric balance constants: the city's starting treasury, the domestic market price multiplier, the universal distance modifier, the scouting and hex-claiming prices | — |

---

## Professions and resource consumption

The profession system describes **who** works at a facility and **what** a profession consumes from storage. Facilities are of two kinds: improvements on the map (farm, mine, fishing boats, etc.) and city buildings (Library, Scriptorium — the townsfolk of TownsfolkManager). For both, the profession is set by the `profession` field in the facility's data (`data/improvements.json` / `data/buildings.json`) and is an internal identifier: it is not shown in the interface as a separate "Profession" line — the player sees its consequences (consumption and bonus), and on the "Resources" tab — it as a source of planned consumption (the key of the source is the identifier, and the label is resolved at render time — see "Source keys: an identifier, not a name"). The exception is the pseudo-profession `all` ("All Citizens"): the top of the profession hierarchy, covering the whole population of the city (see the subsection "The pseudo-profession "all" and city consumption").

### Files and connections

| File | What it stores |
| --- | --- |
| `data/professions.json` | The profession registry: id, name forms, icon, description |
| `data/improvements.json` | Each improvement has a `profession: "<id>"` field (or empty if the improvement does not require a worker with a profession). The flag `no_worker: true` completely excludes the assignment of workers (see the subsection "Improvements without a worker") |
| `data/buildings.json` | A building has the same `profession: "<id>"` field for the citizen working in the building (currently: `library`, `scriptorium` — `scientist`) |
| `data/products/*.json` | Goods in storage; the legacy field `consumption` — consumption "from the resource" (isolated cases) |
| `data/consumption.json` | The registry of professional consumption: a product or a goods group (`@`) → professions, amount/interval/bonus |
| `scripts/worker_manager.gd` | Assignment/dismissal, per-hex consumption timers, building consumption timers (`building_consumption_timers`), city consumption `all`, debiting, the consumption plan |
| `scripts/townsfolk_manager.gd` | Assignment of townsfolk to buildings; `get_profession(index)` — the profession by building (the `profession` field in `data/buildings.json`) |
| `scripts/main_map.gd` | In the production tick it calls `worker_manager.tick_consumption()` for every worker and `worker_manager.tick_city_consumption()` for the whole population; the simulation tick starts `CityData.do_tick()` (building consumption) |
| `scripts/map_tooltip.gd` | The "Consumes: …" section of a worker's profession in the hex tooltip (for improvements with a profession and consumables) and in the left column of the control panel |
| `scripts/consumption_ui.gd` | The shared builder of the display rows for a profession's consumption (`build_rows` / `build_rows_for_building`, `format_rate`, `format_rate_with_unit`): resource name, the rate "units/sec", the bonus "+N% to production". This is the only place where such text is computed — all four displays use it (see the subsection "Where a profession's consumption is shown") |
| `scripts/buildings_tab.gd` | The "Consumes: …" section in the building details tooltip ("Buildings" tab): a property of the building type, visible even before construction |
| `scripts/building_panel.gd` | The same section in the building details window: the sum over the working buildings of this type |
| `scripts/resources_tab.gd`, `scripts/ui_helpers.gd` | The "Resources" tab: the dynamics with the "≈" marker and the tooltip blocks "Production/Consumption (current)/(planned)" (see the subsection "Planned consumption in the "Resources" tab") |
| `scripts/SaveManager.gd` | Saving/loading of the consumption timers |

### Declaring consumption

Consumption is described **on the side of the resource** (not on the side of the improvement or the profession) in two places:

1. **`data/consumption.json` — the main registry.** An entry of the form `{ "resource": "<id>|@<group>", "profession": [...], "amount": N, "interval": S, "production_bonus": B }`. The target resource is either the id of a single product or a reference to a goods group from `product_groups.json` in the format `@<id>` (like the `@` substitution in craft recipes). This is exactly how the consumption of the "Boats" group by the fisherman is described.
2. **The legacy "from the resource" scheme**: the `consumption` field of a product in `data/products/*.json`. It is kept for the rare cases when a resource has no analogues and a group cannot be assembled. New entries are recommended to be added to the registry.

This gives two benefits:

1. **One resource — several consumers.** For example, boats can be consumed by fishermen now and, possibly, by pearl divers in the future — without editing professions.
2. **Balance editing in one place.** Increasing `interval` in a registry entry immediately slows down all of its consumers.

The connection "profession ↔ resource" is through the entry's `profession` field (an array of profession ids).

Priority and duplicates: registry entries are processed first; if the same resource is described both in the registry and in the product's `consumption` field for one profession, the duplicate entry is ignored (protection against double debiting — the key `display_key` in `GameData.get_profession_consumption`).

### Automatic marks

The player **does not manage the marks manually**. The algorithm:

1. A worker is assigned to a hex with an improvement (`worker_manager.assign_worker`) or a citizen — to a building (`townsfolk_manager.assign_townsfolk`).
2. The profession is determined by the facility: by the field `improvement.profession` (`GameData.get_profession_for_improvement`) or `building.profession` (`GameData.get_profession_for_building`; wrappers — `worker_manager.get_building_profession` and `townsfolk_manager.get_profession`).
3. The mark "lives" as long as the worker/citizen is at that facility.
4. On dismissal (`worker_manager.remove_worker` / `townsfolk_manager.remove_townsfolk`) the mark disappears — it is derived from the facility, no separate state is stored.

A profession is an internal identifier: it is not shown in the interface as a separate "Profession …" line. The player sees its consequences: the consumption of consumables and the production bonus, and on the "Resources" tab — it as a source in the "Consumption (planned)" block. The key of the source is the **identifier** `GameData.profession_source_id(prof_id)` (`"@prof:fisherman"`), and the label is resolved at render time — see "Source keys: an identifier, not a name".

### Improvements without a worker (the `no_worker` field)

Some improvements are not extractors but **infrastructure facilities**: they perform their functions by themselves and do not require a citizen to be assigned (currently the only one is the harbor `harbor`, scheme `harbor_access`). Such improvements are marked in `data/improvements.json` with the flag `"no_worker": true`. Behaviour:

1. **Workers cannot be assigned at all:** `worker_manager.find_vacancy()` skips such hexes when auto-assigning free citizens, and `worker_manager.assign_worker()` refuses on a direct call.
2. The **control panel** (`control_panel.gd`) does not show the "Start work / Pause work" buttons for them — only special actions remain (for example, demolition).
3. The **tooltip/information panel** shows the status `(infrastructure: no worker required)` instead of `(inactive: no worker)`; the profession is not shown.
4. The `profession` field of such improvements is **not set** — by their meaning they work without people.
5. On load (`worker_manager.load_assignments`) an assignment to an improvement with the `no_worker` flag is discarded, and the citizen is returned to the free ones (when `idle_population` is recalculated).

### Debiting resources and the production bonus

- Improvements: in `main_map.gd._process` every second (`SIMULATION_TICK = 1`) it iterates over hexes with workers; for each one `worker_manager.tick_consumption(row, col, delta)` is called, returning the **production multiplier** of the hex.
- Buildings: in `CityData.do_tick()` for every working building (there is a citizen and at least one non-empty slot) `worker_manager.tick_building_consumption(i, delta)` is called — the same mechanics, with the timers in `building_consumption_timers` (key `b<index>`). The multiplier is passed to `CraftContainer.tick(...)` (the recipe's output rate) and multiplies the science accrual for a completed cycle (the `special_yield` of writing materials + the building's `additional_yield`). An idle building has neither consumption nor bonus.
- The multiplier:
  - `1.0` — if the profession has no consumption, or if the storage lacks at least one of the required resources;
  - `1.0 + production_bonus` — while all the needed resources are available (for example, `1.5` at a bonus of `0.5`);
  - the bonuses of **single** entries of a profession add up (feathers `+25%` and ink `+25%` → `+50%`); among **group** ones the best available is taken — the "Boats" group gives a single bonus from the best available member, not the sum over the members (see `worker_manager._aggregate_production_bonus`).
- The multiplier is **multiplied** by the other production coefficients (terrain modifiers, the fill_fraction of growing resources; for buildings — by the recipe's output).
- The consumption timer accumulates `elapsed`. When `elapsed >= interval`:
  - if the resource is present — it debits `amount` units from the storage and resets the timer;
  - for a **group** resource (`@<group>`) the stock is computed as the sum of all members of the group; the debit is greedy: the remainder of `amount` is filled from the available members of the group in order (quality priority `best`, as for single products);
  - if the resource is absent (including the total stock of the group) — it **does NOT debit**, and the timer is preserved; when the resource appears, the debit will happen immediately, without waiting for a full interval.
- **The improvement does not "stop"**: when consumables are short it simply rolls back to base production (without the bonus). This is gentler than a hard stop and does not break the economy during temporary supply interruptions.

### Where a profession's consumption is shown

The row format is the same everywhere and is assembled in one place — `scripts/consumption_ui.gd`:

`Consumes:` → `<Resource name>: <N> units/sec (+N% to production)`

The rate is per second (the entry's `amount` divided by its `interval`; `interval = 0` — "per tick", and a tick equals a second); fractional values are written with one decimal place. The `production_bonus` is shown as a percentage so that the player sees why the profession needs this consumable. The resource name is drawn with an icon, and for an `@`-group — the underlined name of the group with its composition on hover (`ui_helpers.make_resource_entry`).

**The unit of measurement is a separate catalog entry.** The unit lives as a single `msgid` `"units/sec"` ("units/sec"), and not inside a phrase together with the number. The number is formatted by `ConsumptionUi.format_rate`, and the unit is appended by `ConsumptionUi.format_rate_with_unit` — the only place where they are joined, so the number and the unit cannot diverge and the translator sees the unit, not a dozen identical phrases with a baked-in number. Separate PHRASES where `units/sec` stands inside a sentence (a road section's speed, trade turnover, "Route to the city") remain separate entries: there the meaning of the phrase is translated, not the unit.

Four displays:

1. **The extended hex tooltip** (`map_tooltip.update_extended_tooltip`) and the **left column of the control panel** (`map_tooltip.build_hex_info` → `control_panel`) — for map improvements. The section appears only if the improvement is built, a worker is assigned, it has a profession and the profession has consumables. The rate is per one improvement.
2. **The building details tooltip** on the "Buildings" tab (`buildings_tab._show_building_details`) — the section sits between "Cost:" and "Extra output:". It is shown as a property of the building type (the profession is set in the data), that is, also **before construction**; the rate is per one building, with no summation.
3. **The building details window** (`building_panel._fill_consumption_section`) — the same section between "Buildings: N" and the list of slots. Here there can be several buildings of one type, so the **sum over the working ones** is shown: the rate is multiplied by the number of buildings that have a citizen and at least one non-empty slot (the same rule as in `CityData.get_townsfolk_professions_count` and in the consumption plan). With one working building the row matches the hex tooltip, with several a note "(2 buildings)" is added, and when there are no working buildings — "(no working buildings)" (the rate then stays "per one building").
4. Planned consumption on the "Resources" tab (see the subsection below) — a different cut: there the expense is aggregated by resources, not by professions.

#### The "resource is consumed by someone" mark

In the building details tooltip a resource that is consumed by some entry of `data/consumption.json` (or by the legacy field `products[*].consumption`) is underlined with a **dotted line** — by analogy with the underlining of `@`-groups, but with a finer dash (`underlined_label.gd`, `dot_style = true`). On hover a tooltip is shown: "Consumed by: `<name>`" with a list of consumers: the profession name, the `amount/interval` norm in units/sec and the production bonus.

The reverse index "resource → consumers" is `GameData.get_consumption_consumers(display_key)`. The address of a resource can be either a product id or `@<group>`: a query by **product** additionally goes through the composition of all groups, so a rule addressing a group is visible on a specific good — this is exactly how the recipe row "Reed Boats" learns that the group `@boats` is consumed by the fisherman. A query by **`@`-key** answers only with the rules of the group itself and does not expand the composition into separate rules: a group row is responsible for the group, not for every good that shares a rule with it. In the result row the field `via_group` contains the `@<group>` through which the consumer came, and the tooltip explains this with a separate line: "Consumed as part of the group "…"".

The consumers tooltip is assembled in `ui_helpers.show_consumption_tooltip`; the rate is formatted by the same `ConsumptionUi.format_rate` as the consumption rows, so the numbers cannot diverge.

The mark is opt-in: `ui_helpers.make_resource_entry(..., show_consumers: bool = false)`. It is enabled by the **recipe** rows of the building details tooltip (ingredients and result): there the resource is named without a norm, so the underlining and the tooltip add what is not visible in the row.

The rows of the "Consumes:" and "Extra materials" sections do NOT get the mark. In "Consumes:" the norm and the bonus are already printed right in the row (`Writing Set: 1 units/sec (+25% to production)`), and the consumers tooltip would merely repeat the same row — the mark would be a duplication. On the other screens (the construction cost, the upgrade window, the "Resources" tab) the resource also stays un-underlined: there the row reads as an "expense" or an "ingredient".

A recipe gets into the list only when the technology is unlocked (`CityData.is_tech_unlocked`), so the mark in the recipe rows is visible only for available recipes — as are the rows themselves.

For a building without a profession (or a profession without consumables) the section is not shown at all.

### The pseudo-profession "all" and city consumption

`data/professions.json` contains the pseudo-profession `all` ("All Citizens") — the **top of the hierarchy**. It is not a worker mark:

- it covers **all** the citizens of the city — the free ones, the workers at improvements with any professions, and the city workers in buildings;
- it is marked with the field `"pseudo": true`; **no improvement should reference it** (the `profession` field in `improvements.json`) — otherwise a "profession" would appear in the UI of a worker;
- consumption is described by ordinary entries of `data/consumption.json` with `"profession": ["all"]`, but is processed separately: not per hex, but **per head**.

The mechanics (`worker_manager.tick_city_consumption`, called from `main_map._process` in the production tick):

1. The `amount` in the entry is counted **per one citizen**: the total debit per tick = `amount × CityData.total_population`.
2. The debits go by a common city timer (`city_consumption_timers`, the key being the entry's `display_key`), not by the hex timers.
3. The debit goes **by actual availability**: per attempt `min(present in storage, amount × population)` is debited, and there is no waiting for full coverage. If the storage has less than needed — everything that is there is debited and the timer is reset; if the storage is empty — the timer is kept "hot", and everything that appears is debited on the nearest tick without waiting for a full interval. The greedy parsing from an `@`-group is like that of per-hex consumption (quality priority "best").
4. `production_bonus` is not applied for `all` (in the data it is `0.0`): city consumption gives no bonuses.

### Saving

`SaveManager` saves only `elapsed` (keyed by `row,col`). `interval` is not stored — it is always computed from the profession on load, which eliminates desync when the data changes. The city consumption timers of `all` are saved analogously (`city_consumption_timers`: only `elapsed` by `display_key`; `interval` is recalculated from the data).
The professional consumption timers of **buildings** are a separate save key `building_profession_consumption_timers` (an array of `{ "index": int, "fractional": {…} }`); they are loaded in `main_map` after the townsfolk assignments. Old saves without the key are loaded as an empty dictionary.

### Example: the "Boats" group for the fisherman

1. `data/professions.json` — the profession `fisherman` with the name "Fisherman".
2. `data/improvements.json` — `fishing_boats` has the field `"profession": "fisherman"`.
3. `data/product_groups.json` — the group `boats` ("Boats").
4. `data/consumption.json` — the entry `{ "resource": "@boats", "profession": ["fisherman"], "amount": 10, "interval": 10, "production_bonus": 0.5 }`.
5. When the fishing boats are started with a worker:
      - the section `Consumes: Boats: 1 units/sec (+50% to production)` appears in the tooltip/panel;
      - while there are boats from the group in the storage, 1 unit is debited every second (10 units once every 10 sec → 1 unit/sec), and the fish production runs with the multiplier `x1.5`;
   - if the boats run out, the improvement keeps working with the base multiplier `x1.0` (without the bonus). As soon as boats appear in the storage, the bonus immediately returns.

### Planned consumption in the "Resources" tab

The actual counters (`CityData.consumption_rates` / `consumption_sources`) live for one SIMULATION_TICK (= 1 sec) and are filled only at the moment of debiting, so interval consumption (boats: 10 units once every 10 sec → 1 unit/sec) is "invisible" most of the time. So that the player always has the full picture, the "Resources" tab shows **planned consumption** — how much of a resource WILL be debited by the current consumers per second, regardless of the phase of the timers and of the presence in the storage.

**The resource tooltip** — five items in order: price / "Production (current):" / "Production (planned):" / "Consumption (current):" / "Consumption (planned):" (at the end — the "≈" footnote). The "actual + plan" pairs go in a row and are grouped: first production (current, then planned), then consumption (current, then planned). The "Consumption (current):" section shows the actual debit over the last SIMULATION_TICK (= 1 sec); during interval consumption, between debits it shows the last actual one (`CityData.last_consumption_sources` — survives ticks, updated in `reset_counters()` with the data of the elapsed tick), as long as the resource has planned consumption. The "Consumption (planned):" section, with rows in descending order of contribution:

- `• Fisherman: 1 units/sec.` — the professional consumption of workers at improvements and of citizens in buildings (`amount × number of consumers of the profession` / `interval`); with several — `• Fisherman x2: 2 units/sec.` (10×2/10). For buildings only the working ones are counted (a citizen + a non-empty slot), the source being the citizen's profession (for example, `• Scholar: 0.1 units/sec.` for feathers);
- `• All Citizens (5): 25 units/sec.` — the consumption of `all` (`amount × total_population` / `interval`, the population in parentheses);
- `• Charcoal Kiln: 4 units/sec.` — the demand of built buildings with an assigned citizen by the recipes of their slots: the recipe is executed once every `time` seconds (the `time` field in `data/crafts/*.json`, see the subsection "Recipe time (`time`)"), so the demand is shown as "units/sec" (amount × slots / `time`); the demand is shown also when the ingredients are currently short in the storage — it is a need, not a fact;
- group entries apply to ANY member of the group and are marked with its name: `• Fisherman (group "Boats"): 1 units/sec.`.

**Production (planned)** — the section right below the "Production (current)" block (above both consumption blocks): what WILL be produced by the current producers — the recipes of buildings with a citizen (`CityData.get_planned_production_map()` → `get_building_planned_production()`): `• Charcoal Kiln: +2 units/sec.` (with several slots — `xN`; a recipe without a `time` field gives "units/sec", since SIMULATION_TICK = 1 sec). It is shown also when there is no actual production for the tick — for example, the kiln did not have enough wood. The production of improvements on the map **is included** in the planned production: improvements output a continuous per-second rate, so their planned rate = `produces` units/sec (for example, a farm: 5 wheat units/sec; a pasture: 3 feed units/sec). "Production (current)" for improvements shows the actual output over the last SIMULATION_TICK (= 1 sec), which coincides with the plan.

**Dynamics** (the red marker of the resource row) — a variant of "actual + plan": if there is a debit for the tick, the actual one is shown (`-10]`); if there was no debit for the tick but a plan exists — the plan reduced to the tick, with the "≈" marker: `-2≈]` for boats (`10 × SIMULATION_TICK / 10`, i.e. `10 × 1 / 10`), `-8≈]` for the charcoal kiln (`20 units/5 sec` → `20 × SIMULATION_TICK / 5` = `20 × 1 / 5` = 4; on the debit tick — the actual `-20]`). The sum is computed over the sources: `amount × SIMULATION_TICK / interval` for interval entries (the demand of buildings carries `interval = time` of the recipe) and `amount` as is for "per tick"; the result is `max(1, round)`. For fruits (interval = tick = 1 sec) the plan coincides with the actual. The explanation of "≈" is shown in the tooltip.

Data source: `worker_manager.get_planned_consumption_map()` — professional consumption (by the number of workers of the professions) + city `all` (by population) + a merge of the buildings' demand from `CityData.get_building_planned_consumption()` (built buildings with a citizen, slot-recipes of `GameData.crafts`, with support for `@`-groups; the entry carries `interval = time` of the recipe, so the need is brought to the tick honestly). Planned production is taken from `CityData.get_planned_production_map()` (the `result` output of the buildings' recipes; the entries also carry `interval = time`). The cache is recalculated on the tab on every `update_data()`/`refresh()` (once per tick when the city is open). The feeding of the population (food) and the feed of pastures are not part of planned consumption: they are debited every tick and are visible in the dynamics directly. Saves are not affected — the plan is always derived from the current data.

**Membership in the resource list** is determined by a common rule — the single source of truth is `resources_tab._is_displayable()`: a row is visible if the player has a source of income — stock in the storage, production for the tick or planned production (an existing producer-building with a citizen). Planned consumption of a row does NOT add it. Therefore members of an `@`-group without their own income are not shown at all — neither rows nor plan marks: when only grapes are produced, dates, figs and the other "Fruits" are absent from the list; millet is absent if only wheat from "Grains" is gathered. As soon as such a resource gets its own income (its own improvement, a building recipe, an import when it appears), the row appears by itself: `update_values()` compares "should be visible / already shown" and on a mismatch calls a full rebuild of the list (the same path as when a new product appears). For the same reason the row disappears immediately when the last source of income is lost (the storage is emptied to 0, the producer is demolished or the citizen is dismissed), without waiting for a structural update of the tab. Planned production, on the contrary, is itself a source of income (a working building with a recipe): the row of its product stays in the list as long as the producer exists, even with zero stock and zero actual for the tick (charcoal at a starving kiln — "+10≈").

### professions.json format

```json
{
  "professions": [
    {
      "id": "fisherman",
      "name": "Fisherman",
      "icon": "profession_fisherman.png",
      "description": "Fishes from boats on any water body with a dock."
    }
  ]
}
```

- `id` — a unique snake_case identifier, used in `improvements.profession` and `buildings.profession`, as well as in the `profession` fields of the entries of `data/consumption.json` and of the legacy `products[*].consumption`. The pseudo-profession `all` must not be used in `improvements.profession` / `buildings.profession` — only in `data/consumption.json`.
- `name` — the nominative singular form ("Fisherman"). It is not shown in the interface as a separate "Profession …" line: it serves as the source name in the "Consumption (planned)" block of the "Resources" tab.
- `icon` — the icon file name (as for products/improvements). It is currently not displayed anywhere. It is not set for the pseudo-profession `all`.
- `description` — a short description for future tooltips.
- `pseudo` — the marker of a pseudo-profession (only for `all`): not a worker mark but a counter of the whole population.

### consumption.json format (the main registry)

```json
{
  "consumption": [
    {
      "resource": "@boats",
      "profession": [ "fisherman" ],
      "amount": 1,
      "interval": 10,
      "production_bonus": 0.5
    }
  ]
}
```

- `resource` — the target resource: the id of a product from `data/products/*.json` **or** `@<id>` of a group from `data/product_groups.json` (like the `@` substitution in craft recipes). A reference to a group **must** start with `@`: without it the key is looked up among products rather than groups — and the group id would not be found there (the group `jewelry` has no product with such an id, only `gold_jewelry`, `copper_jewelry` and others). There is deliberately no lookup by human-readable name: such a fallback would silently substitute the data of a similar group and break the addressing (see `_build_consumption_entry`).
- `profession` — an array of profession ids that consume the resource. One resource can be consumed by several professions.
- `amount` — how many units are debited per one "consumption tick". For a group — in total from any set of members of the group.
- `interval` — the period between debits in seconds. Fractional values are allowed.
- `production_bonus` — an addition to the production multiplier of the facility (an improvement or a building with a profession) while the storage has enough of `amount` units (for a group — of the total stock). `0.5` means +50% (the resulting multiplier `1.5`). At `0` or with the field absent — there is no bonus. The bonuses of **single** entries of a profession add up (feathers and ink for the Scholar), among **group** ones the maximum is taken — a group gives a single bonus from the best available member, not the sum (see `worker_manager._aggregate_production_bonus`).
- If a group is not found in `product_groups.json` (or a product — in `data/products/*.json`), the entry is skipped with a diagnostic message in the log (there will be no consumption or bonus). The same error is shown in the problems window as `consumption_group` / `consumption_resource` — see the section on the validator.

### Product `consumption` format (legacy, for isolated cases)

```json
"consumption": {
  "profession": [ "fisherman" ],
  "amount": 1,
  "interval": 10,
  "production_bonus": 0.5
}
```

- `profession` — an array of profession ids that consume this product.
- `amount` — how many units are debited per one "consumption tick".
- `interval` — the period between debits in seconds. Fractional values are allowed.
- `production_bonus` — an addition to the production multiplier of the improvement while the storage has enough of `amount` units. `0.5` means +50% (the resulting multiplier `1.5`). At `0` or with the field absent — there is no bonus. The bonuses of single entries of a profession add up, among group ones the maximum is taken (see `worker_manager._aggregate_production_bonus`).

### Current list of professions (as of 2026-09-17)

| id | Name | Improvements / buildings |
| --- | --- | --- |
| `farmer` | Farmer | farm |
| `herder` | Herder | pasture |
| `miner` | Miner | mine |
| `quarryman` | Quarryman | quarry |
| `beekeeper` | Beekeeper | beehive |
| `vinedresser` | Vinedresser | vineyard |
| `potter` | Potter | clay_pit |
| `planter` | Planter | plantation |
| `tar_collector` | Tar Burner | tar_pit |
| `soda_extractor` | Soda Extractor | soda_quarry |
| `fisherman` | Fisherman | fishing_boats |
| `lumberjack` | Lumberjack | lumberjack_hut |
| `scientist` | Scholar | library, scriptorium (buildings) |

---

## Resource prices

Every resource in `data/` has a base price — the `price` field (a number, conventional
coins per unit). The price is set both for raw resources (`data/resources/**/*.json`)
and for goods (`data/products/*.json`).

`price` is the **base, averaged, "default"** price. It does not account for
local situations (famine, excess supply, etc.) — such effects
are implemented through dynamic multipliers (see below).

### Where the price is shown

The "Resources" tab: when hovering over a good in storage, as well as over a row
of domesticated animals/plants, the tooltip shows the current price
(`ui_helpers.show_flow_tooltip` → the row "Price: N"). Below it is the price
ladder by quality (see "Price by quality" below).

### Value conventions

- **Goods** — price per unit of the good.
- **Animals** (raw resources of animal husbandry) — the price "per head/animal"
  (for example, a cow 60, a horse 150).
- **Fields, deposits, plantations** — the price equals the price of their main product
  (a wheat field = wheat, an iron-ore deposit = iron ore),
  so that the price of a natural resource and of the goods in storage is consistent.
- **Pseudo-resources** (`science` — a virtual pool) **have no** price: on the
  "Resources" tab they are not shown, `GameData.get_price` will return 0 for them.

Approximate scale (2026-09): feed/wild plants ≈1, grain 2–5, vegetables/legumes
3–5, fruits 5–10, meat/fish 5–9, cheese 14, honey 16; planks 4, bricks 6, marble 14;
ores 6–22, metals 14–70; cloth 4–60, clothes 16–90; dyes 5–55;
jewelry 22–140; tools 40–90; weapons 45–110.

### Dynamic price (multipliers)

The final price is computed in `GameData.gd`:

| Method | Purpose |
| --- | --- |
| `GameData.get_base_price(res_id)` | base from JSON (the `price` field) |
| `GameData.get_price_multiplier(res_id)` | product of the active multipliers |
| `GameData.get_price(res_id)` | total: base × multipliers |
| `GameData.apply_price_modifier(res_id, factor, multiplier)` | enable a multiplier |
| `GameData.remove_price_modifier(res_id, factor)` | disable one multiplier |
| `GameData.clear_price_modifiers()` | reset all multipliers |

Multipliers are stored in `GameData.price_modifiers`: `res_id -> { factor: multiplier }`
and are **multiplied** together. `factor` is a meaningful name for the reason (for example,
`"famine"`, `"market_glut"`), so that different mechanics do not overwrite each other.

Example — a famine in the city raised food prices:

```gdscript
GameData.apply_price_modifier("wheat", "famine", 1.5)
GameData.apply_price_modifier("meat", "famine", 1.5)
# ... the famine is over:
GameData.remove_price_modifier("wheat", "famine")
```

The tooltip on the "Resources" tab updates in real time: an open tooltip
is rebuilt every tick (the `update_values` loop in `resources_tab.gd`), so
new multipliers are shown immediately, without restarting the game.

> Note: the price is shown in the tooltip and is used by the domestic market
> (see "City treasury and domestic market"): when resources are consumed, the treasury
> receives income based on a share of the price. The price registry and the multiplier API are designed so that
> in the future they can be used both for external trade and for market
> events.

### Price by quality (the `price_multiplier` multiplier)

The quality of a unit of goods raises its price. The multiplier lives in
`data/qualities.json` for each quality level and is **multiplied** by the price
of the unit (rather than added — the same addition in coins would break the price
scale, where goods cost from 1 to 150):

| Level | `stars` | `price_multiplier` | `color` | Example: goods for 4 |
| --- | --- | --- | --- | --- |
| `common` (Common) | ★ | `1.0` | `[160, 160, 160]` gray | 4 |
| `fine` (Fine) | ★★ | `1.3` | `[90, 200, 110]` green | `4 × 1.30 = 5` |
| `exceptional` (Exceptional) | ★★★ | `1.75` | `[186, 120, 255]` purple | `4 × 1.75 = 7` |
| `perfect` (Perfect) | ★★★★ | `2.3` | `[255, 215, 0]` gold | `4 × 2.30 = 9` |

The values are chosen so that adjacent levels give **different** final
prices: on the current data (268 goods), the levels differ for 265 of them,
only three goods for 1 coin merge. Closer values
(1.15/1.35/1.6) gave the same price for 43 goods — quality stopped being
worth the difference.

The price is always rounded to a **whole** number of coins: the base is rounded once,
the total — `round(base × multiplier)`. Fractional coins do not exist in the game.

| Method | Purpose |
| --- | --- |
| `GameData.get_quality_price_multiplier(qid)` | quality-level multiplier (for an unknown id and `common` — 1.0) |
| `GameData.get_price_for_quality(res_id, qid)` | price with quality, without rounding |
| `GameData.get_price_breakdown_for_quality(res_id, qid)` | `{ base, multiplier, total }` — numbers for the tooltip |
| `GameData.format_quality_price_line(res_id, qid)` | a single level's row: `★★ = x1.30 = 5` (glued together from the stars and the tail) |
| `GameData.format_quality_price_tail(res_id, qid)` | the row's tail without the stars: ` = x1.30 = 5` — this is exactly what the tooltip colors with the standard price color, which is why it is returned separately |
| `GameData.format_quality_price_scale_rows(res_id, quality_breakdown)` | prices by the levels that are actually in storage (the `city_quality_detail` breakdown) — an array of records `{ "qid", "stars", "tail", "text" }`. `stars` is colored in the level's color, `tail` — the standard price color, `text` — the finished row as a whole; the parts are glued together from the same data, so the text and the color cannot diverge |
| `GameData.get_quality_color(qid)` | the level's color from the `color` field (without the field — a light-gray default) |
| `GameData.get_quality_share_percent(count, quality_breakdown)` | the level's share as a percentage of the total amount of goods in storage |
| `GameData.format_quality_share_text(quality_breakdown)` | the storage-breakdown string for a list row: `(33%/67%)` with a BBCode color for each percentage |

### Quality-level color (`color`) and storage shares

Each level in `data/qualities.json` has a `color` field — an array
`[R, G, B]` in the range 0…255 (the same notation as for covers
`data/covers.json`, improvements and resources). The palette is "as in roguelikes":
gray (common) → green (fine) → purple (exceptional, "epic") →
gold (perfect, "legendary"). The field is optional: without it the level
is drawn light-gray (`GameData.QUALITY_COLOR_FALLBACK`), so old data
does not break the interface.

The level's color paints three places on the "Resources" tab:

1. **List row** (`resources_tab._update_quality_label`): a single **blue**
   star marker `★` (the constant `resources_tab.QUALITY_MARKER_COLOR`, the interface
   accent) and the storage breakdown in parentheses, where each percentage is colored in the color
   of its own level: `★ (33%/67%)`. The star marker is always single and always blue —
   it is the symbol "the good has a quality breakdown", not the quality level
   (the levels are shown by the percentages). The percentages are counted from the **total** amount
   of the good in storage and are rounded separately, so they add up to ~100%
   (33%/33%/33% is fine; "polishing" them to an even 100% would mean lying about
   the fractional shares). The breakdown is empty — the label hides.

   The row's label is a `RichTextLabel` with `bbcode_enabled = true` (only it
   has BBCode) and **`autowrap_mode = TextServer.AUTOWRAP_OFF`**. Disabled wrapping
   here is mandatory, not cosmetic: with wrapping enabled `RichTextLabel` cannot
   tell the container the width of its content (`get_minimum_size()` = 1 px),
   `HBoxContainer` gives the label exactly that 1 px, and `★ (33%/67%)` stacks
   one letter per line. The row spreads out to ~200 px in height, and the resource
   icon (`STRETCH_SCALE` + vertical `SIZE_FILL`) stretches to
   40×200 — this is the "star the size of 1 pixel" and the "broken" resource
   icons. A second layer of protection: the row's icons are given
   `size_flags_vertical = Control.SIZE_SHRINK_CENTER`, so even a tall
   row will not stretch them — the icon stays 40×40 and is simply centered
   vertically. The regression is caught by `tests/test_resource_display_interval.gd`
   (item 3f: measuring the geometry of all list rows after a real layout —
   the row's height, the size of each icon, the width of each visible label).
2. **Row tooltip** (`ui_helpers.show_flow_tooltip`): in the price-ladder row
   the **stars** are colored in their level's color, while the price calculation itself is in the standard price
   color (`ui_helpers.PRICE_TEXT_COLOR`, `_make_quality_price_row`).
3. **The "Resource quality levels" tooltip** (`ui_helpers.show_quality_tooltip`):
   the stars in the level's color.

The quality stars on the map (`map_renderer`) and in the hex tooltip (`map_tooltip`)
remain as before — the new color is not applied there.

**Displaying the price by quality.** The price is shown in **one** tooltip
of the "Resources" tab (and nowhere else — neither the hex tooltip on the map nor the control
panel): in the **row tooltip** (`show_flow_tooltip`, hovering over the name
or the dynamics of a resource). Under the base row "Price: N" there is a **ladder** — one
row for each level that is **actually in storage** (according to the
`city_quality_detail` breakdown), from worst to best:

```
Price: 4
  ★ = x1.00 = 4
  ★★ = x1.30 = 5
  ★★★★ = x2.30 = 9
```

Each row of the ladder is **two-colored**: the **stars — in their level's color**
(`data/qualities.json`, `color`: gray → green → purple → gold), and
**the price calculation itself** (`= x1.75 = 7`) — in the **standard price color**, the same shade as the
row "Price: N" above the ladder (`ui_helpers.PRICE_TEXT_COLOR`). The level is read by the
color of the stars without reading the text, and money looks like money, not like quality.
The exception where the shades coincide is the "perfect" level: it is already gold,
so its row is entirely gold; this is a property of the data, not a separate
decision in the code.

The level in a row is named by stars, so the "Price:" caption is not needed in it: the
ladder is already preceded by the base price of the same good. The **entire** scale is shown,
including the lowest level (`★ = x1.00 = 4`): the ladder reads as a single
table where the multiplier is visible for each level, rather than starting from the middle.
Levels that are **not** in storage do not get rows: the price of a good
that is not in storage only misleads. A good without a price
(for example, `science`) has no ladder at all. The breakdown is taken fresh on each
tooltip update, so a disappearing supply also removes its row.

The **"Resource quality levels" tooltip** (`show_quality_tooltip`, hovering over the
quality label in a list row) shows **only the composition of the storage** — how many
units of which quality and what share of each level, without prices:

```
Resource quality levels: Feathers
★ Common: 3147 (33%)
★★★★ Perfect: 6365 (67%)
```

There are deliberately no prices here: each level has its own price, and the full list would take
as much space as the tooltip itself (the price ladder lives in the row tooltip).

**Effect on the treasury.** The domestic market buys each written-off unit at the
price of ITS quality: `CityData.get_internal_market_price(pid, quality_id)` and
`CityData.get_internal_market_income(pid, { quality: count })`. A mixed
storage brings in more than the same amount of common goods. For the
**planned** income (the treasury tooltip), where the quality of the future transaction is unknown,
the average multiplier over the storage breakdown is used —
`CityData.get_stock_quality_price_multiplier(pid)`.

---

## City treasury and domestic market

The treasury is the city's stock of coins (`CityData.treasury`). Always an integer: profit
is calculated from the rounded price of a unit of goods, so there are no fractional coins.
Coins are not produced by buildings — the treasury is replenished when citizens buy
goods on the domestic market or through trade with other settlements.
The treasury is spent on actions on the map: sending scouts and claiming
(buying) territory chunks (see "Scouting cost (coins from the treasury)" and
"Claiming land: 'work + coins'").

### The `data/game_balance.json` file

The numeric balance constants are moved out of the code into a separate file:

| Field | Default | Meaning |
| --- | --- | --- |
| `initial_treasury` | `100` | Coins in the treasury at the start of a new game (assigned in `CityData.setup()`) |
| `town_initial_treasury` | `1000` | The starting treasury of **each town** when it is generated (see "Town treasury") |
| `internal_market_price_multiplier` | `1.0` | The share of the base price of the good (`price` from `data/products/*.json`) at which the domestic market buys goods from the city |
| `distance_cost_modifier_per_hex` | `0.25` | The **universal** distance modifier: an increase to the cost for each hex of distance from the city (`0.25` = +25% per hex). Read by `MapHelpers.get_distance_cost_modifier()` and applied to the work of improvements/special actions and to the coins of scouting and claiming |
| `scouting_cost_per_hex` | `3` | The base price of scouting one hex in treasury coins (the price of a chunk is the sum over the hexes with the distance modifier) |
| `expansion_cost_per_hex` | `5` | The base price of claiming one hex in treasury coins (work is counted separately, from the terrain's `expansion_cost`) |

### Income mechanics

1. Resource consumption is described in `data/consumption.json` (see "Professions and resource consumption").
2. As soon as a record's `interval` passes and the resources are **actually written off** from storage (`CityData.remove_from_storage`), income is added to the treasury: the written-off amount × the price per unit on the domestic market.
3. The price per unit on the domestic market (`CityData.get_internal_market_price`) is `round(round(price × internal_market_price_multiplier) × price_multiplier of the quality level)`, see "Price by quality". The income for a mixed write-off is computed by `CityData.get_internal_market_income(pid, { quality: count })`: the price is taken **by the quality of each unit**, so a mixed storage brings in more than the same amount of common goods. Previously the `remove_from_storage` breakdown was returned but not used — a single price was counted for the whole good.
4. City consumption writes off according to availability (see "The pseudo-profession 'all' and city consumption"): on a partial write-off the income is proportional to the units actually written off; if no write-off happened at all (storage empty) — there is no income either (the timer is kept, income will appear on the first actual write-off).
5. Any new consumption record (a new resource, an `@`-group or a profession) will start bringing in income automatically — no code changes are needed.
6. The planned income in the treasury tooltip (`worker_manager._fill_consumption_income`) does not know the quality of the future transaction, so it takes the multiplier averaged over the storage breakdown (`CityData.get_stock_quality_price_multiplier`).

### Display

- **Map HUD** — the label "Treasury: N" (`HUD/VBoxContainer/TreasuryLabel` in `MainMap.tscn`). Updated via the tick path `CityData.city_updated` → `main_map._on_city_data_updated` with a check of the resource display epoch (`CityData.resource_display_due(_treasury_display_epoch)`), at start/load (`_ready`) and immediately when the interval setting changes (`apply_settings`). Previously it subscribed to `treasury_changed`, but domestic-market income changes the treasury every tick — without throttling the label would blink once a second.
  - **The city interface's top bar** (`CityUI`, the same strip as food and population): three separate child labels in `TopFoodLabel` (`HBoxContainer`) — `FoodLabel`, `PopLabel`, `TreasuryLabel`. The shared text is updated via the tick path `city_updated` → `_refresh_light` with an epoch check, so it goes at the same rhythm as the resources. It is not subscribed to `treasury_changed` directly (for the same reasons as the HUD label).

#### Dynamics in the row: "Treasury: N [+X≈ / -Y≈]"

Both labels show next to the balance the **actual** profit and expenses of the treasury in coins/sec — by analogy with the income/expense dynamics on the "Resources" tab ("Food: N [+Y / -Z]"). Both figures are per second, so they are marked "≈": this is the same marker as on the "Resources" tab and in the footer of the treasury tooltip.

The data are the same display windows that the breakdown tooltip reads, but in a different form:

| Row part | What it shows | Where it comes from |
| --- | --- | --- |
| `N` | balance | the `_displayed_treasury` cache (shared between the label and the tooltip, so the tooltip does not "run ahead" by 1+ tick) |
| `+X≈` | average **actual** profit | the sum of the flat `treasury_income_snapshot` (domestic-market income + poll tax) ÷ `treasury_window_length_sec` |
| `-Y≈` | average **actual** expenses | the sum of the positive values of `treasury_expense_snapshot` (scouting, claiming) ÷ `treasury_window_length_sec` |

**Why actual rather than planned.** The treasury has no planned expense rate — these are the player's event-driven click spends; both income and expense are written into flat accumulators next to `add_treasury` / `spend_treasury`, so "actual" here is no less precise than planned. The only difference from the tooltip is the reduction to a second: in the tooltip expenses are shown as a **sum over the window** ("Expenses (actual, over the last 3 sec)"), in the row — per second; an explanation of this is in the tooltip footer.

**The first window.** Until the window completes, the snapshots are empty — `CityData.get_treasury_flow_per_sec()` takes the current accumulators (`*_accum`), exactly like `worker_manager.get_actual_treasury_income_map()`. Otherwise the first 3 seconds after start/load the row would show "+0 / -0" while income is running. The sum over the window is divided by its length, so the figures do not flicker: the window (3 sec) is longer than the label rhythm (1–5 sec from the settings), and they are updated by the same "jolt" by resource epoch.

**A single point of truth.** The dynamics text is assembled by one method — `CityData.get_treasury_flow_text()` (the figures — `get_treasury_flow_per_sec()`, the number format — as in `ui_helpers._format_rate`: an integer without a fractional part, otherwise one decimal). It is read by both `main_map._update_treasury_hud()` and `city_ui._update_food_label()`, so the rows in the HUD and in the city cannot diverge from each other or from the tooltip. Refunds (a cancelled claim) do not go into expenses — just as the tooltip hides them.

**HUD width.** The HUD panel in the scene is a fixed 184 px, while the treasury row with dynamics is longer and grows with the balance. `hud_message.gd` therefore recalculates the panel size to fit the content (`_content_size` / `_fit_size`, the public `refresh_size()` — called from `_update_treasury_hud()` right after the text changes): the width — the maximum of the widths of the visible children (the container is vertical, only the heights are added), the height — as before. Otherwise the text would stick out onto the map, and the label's rectangle (which drives the hover and the "sticking" of the tooltip, `main_map._is_treasury_label_hovered`) would remain the width of the old panel.

### Source keys: an identifier, not a name

Everywhere a source of income/expense lands in an aggregate dictionary (`planned_production_map`, `planned_consumption_map`, `treasury_income_accum`, `treasury_expense_accum`, the `sources` of the "Trade" cards), the key is an **identifier**, not a human-readable name. The name is only a caption that `GameData.get_source_display_name(source_id)` resolves at render time.

**Why.** Two reasons, both of which showed up in the game:

1. **A language change breaks the accumulators.** `LocalizationManager.set_locale` is called from the menu right during a match and re-reads the data, but does not reset the treasury accumulators. If the key were a translated string, changing the language in the middle of the window (3 sec) would turn one source into two with separate remainders: "Scouting" and `Scouting` side by side. With an identifier, the key does not depend on the language.
2. **Matching names merge subjects.** `smelter` is the id of both a profession (`data/professions.json`) and a building (`data/buildings.json`), and in the planned maps both land in the same dictionary under the same product. With names, only the difference in text separated them; with bare ids the rows would merge.

**Key format** — a namespace prefix followed by the id:

| Key | What it is | Assembled by |
| --- | --- | --- |
| `@prof:<id>` | a profession, including the pseudo-profession `all` | `GameData.profession_source_id()` |
| `@bld:<id>` | a city building | `GameData.building_source_id()` |
| `@imp:<id>` | an improvement on a hex | `GameData.improvement_source_id()` |
| `@pop_food` | population food — there is no separate entity in the data | the constant `GameData.SRC_POP_FOOD` |
| `@scouting`, `@claim` | one-off treasury spends (scouting, claiming a chunk) | `GameData.SRC_SCOUTING`, `SRC_CLAIMING` |

Refunds on cancellation (of a claim, of scouting) are written **as a minus into the same key** as the spend (`build_manager.gd`, `expansion_manager.gd`, `main_map.gd`) — otherwise the net over the window would not match the actual change in the balance.

The top-level type in the treasury breakdown is a separate entity, not a source: these are the English constants `CityData.TAX_INCOME_TYPE` (`"Taxes"`) and `CityData.POPULATION_INCOME_TYPE` (`"Population consumption"`), which are translated at render time. Previously the second one was produced by a call to `tr("Population consumption")` right in `worker_manager`, and changed along with the language.

**There is no reverse name → id resolution in the project.** It used to exist in three places (`GameData._find_group_id_by_name`, `CityData._get_group_id_by_name`, `craft_container._resolve_group_members`) as a safety net for `@`-keys written with a human-readable name. In all `data/` files such keys are absent — there it is always an id, — so the fallback was removed: it would silently substitute the data of a group with a similar name.

Save migration is neither supported nor required: the save formats do not maintain backward compatibility.

### The treasury breakdown tooltip by source

When hovering over "Treasury: N" in the map HUD or in the city interface's top strip, a tooltip is shown with the balance broken down by source (by analogy with the "Production (planned)" / "Consumption (planned)" block on the "Resources" tab).

- **Profit (planned, /sec):** the uniform average rate of income from consumption on the domestic market, by source. Computed on the fly from `worker_manager.get_planned_treasury_income_map()`: for each `planned_consumption_map` record (pid, source) — `amount × SIMULATION_TICK / interval × internal_market_price(pid)`, then summed by source. It does not blink on ticks without a write-off (the same approach as planned consumption on the "Resources" tab).
- **Expenses (actual, over the last N sec):** a single figure for the completed display window (by default 3 seconds, the constant `CityData.DEFAULT_TREASURY_WINDOW_SEC`). Scouting and claiming a chunk are event-driven player spends, they have no planned rate, so the expense breakdown shows the actual, not `/sec`. The refund of coins when a claim is cancelled (`expansion_manager.handle_action`) goes into income with the note "… (refund)", so that the net over the window matches the actual change in the balance.

The expense snapshot window is synchronized with the resource display epoch: `CityData.tick_resource_display(delta)` next to the epoch advance does `rotate_treasury_window()`, accumulating the data from `record_treasury_income/_expense` over the next interval and moving it into `treasury_*_snapshot`. The tooltip always reads the snapshot, and when the epoch changes (1–5 sec from the settings) the visible tooltip is redrawn with up-to-date figures while the cursor remains on the label or on the tooltip itself (the redraw happens in place — see "Sticking" below).

**The panel "sticks" (like the building details tooltip).** While the cursor is on the label and the tooltip is not yet shown, a delay accumulates — the same setting as for the building details tooltip ("Interface → Tooltip delay (building details, treasury breakdown)", `building_detail_delay`, by default 0.5 s). When it elapses, the panel is shown ONCE and is fixed in place (`treasury_locked` in `city_ui.gd`, `_treasury_locked` in `main_map.gd`): further polling does not move the panel, so the cursor can be moved onto the tooltip itself — it stays open while the cursor is on it (the long list is scrolled with the wheel via `treasury_tooltip_scroll`). Leaving the label and the tooltip keeps the panel for another grace window of 0.35 s (`BUILDING_DETAIL_LEAVE_GRACE` / `MAP_TOOLTIP_LEAVE_GRACE`) — moving the cursor from the label to the tooltip does not blink, — after which the "sticking" is released and the tooltip hides. An empty breakdown (no income, no expenses) is not shown by the panel: no "sticking" occurs, polling continues — income may appear on the next tick without moving the cursor. In the HUD the label is considered hovered only when the HUD is visible, so when the city interface is open the map tooltip does not pop up.

Styles and layout (`HBoxContainer`, a single theme and `_make_tooltip_style`) are shared with `flow_tooltip_panel` and `quality_tooltip_panel` — the treasury breakdown tooltip is created in `ui_helpers.setup()` in parallel for two owners (the map HUD and CityUI), each with its own `CanvasLayer`/`Control` host, so that the panels lie on top of the UI and do not overlap by z-index.

### Changing and saving

- Replenishing the treasury — `CityData.add_treasury(amount)`; spending — `CityData.spend_treasury(amount)` (returns `false` and writes off nothing if there are not enough coins: the treasury does not go negative). Both emit `treasury_changed(new_total)`.
- Next to `add_treasury` / `spend_treasury`, at the points of fact (domestic-market consumption, scouting, claiming), `CityData.record_treasury_income(source, amount)` / `record_treasury_expense(source, amount)` are called. They accumulate in the current window; they are moved into the snapshot in `rotate_treasury_window()` (called once per resource epoch from `tick_resource_display`). The save is not affected — the window lives exactly one resource interval.
- The treasury is saved into the save (`SaveManager`, the `"treasury"` field). In saves made before the mechanic appeared, the field is absent — `initial_treasury` from `game_balance.json` is restored, as in a new game, `is_hex_in_fog()` (fog of war: not a Ring, not scouted and outside the Region — the tooltip and the left column of the panel do not show information).

### Taxes (poll tax)

Each citizen of the city pays a fixed tax into the treasury for EVERY simulation tick (`SIMULATION_TICK = 1 sec`). **So far there is only one tax**, so it is not broken down by sources/products and is drawn as a flat row in the treasury breakdown tooltip.

#### Static part — `data/game_balance.json`

- The field `base_tax_per_citizen` — the base tax in coins from one citizen per tick. By default it is `2` (standard: every second each citizen brings 2 coins into the treasury).
- This value is CONTROLLED by `CityData.get_base_tax_per_citizen()` (read-only from json). This number no longer appears anywhere else in the code — a balance change in the json is immediately reflected in the process.

#### Dynamics — every tick

`CityData.collect_taxes()` is called from `CityData.do_tick()` **after** food consumption and **before** `_check_population_change()`:

- The tax amount = `get_base_tax_per_citizen() * total_population` (`CityData.get_tax_income_per_tick()`).
- The method does `add_treasury(amount)` and then `record_treasury_income(TAX_INCOME_SOURCE, amount)`, where `TAX_INCOME_SOURCE` is `CityData.TAX_INCOME_SOURCE` = `"Poll tax"`, and `TAX_INCOME_TYPE` is `CityData.TAX_INCOME_TYPE` = `"Taxes"` (the type key in the flat structure of the tooltip).

This order is deliberate: the tax for a tick is paid by **those who lived during that tick** (population growth/decline will be counted from the next tick).

#### In the treasury breakdown tooltip

The income source rendered hierarchically shows the actual average profit, but now it should land **in a single flat one, rather than two of two types** (construction by type + tax).

- The planned and actual treasury income now include the type with the key `CityData.TAX_INCOME_TYPE` (the second row).
- **ONE** row is drawn: `• Taxes: 2 × 3 people = 6 / sec` (rate × number of citizens = amount per second).
- The flat type is marked by `CityData.TREASURY_FLAT_TYPE_KEY` = `"@flat"`; it has `{rate, label}` so that the non-breakdown without products can be rendered.
- The profit section total also belongs to this row.

#### Tests

"Headless test of population taxes" — `tools/test_taxes.gd`. For a new game:

- Reads `base_tax_per_citizen` from `data/game_balance.json` with `GameData.game_balance.get("base_tax_per_citizen", 2)` and compares it with `CityData.get_base_tax_per_citizen()` (both 2).
- Checks `CityData.get_tax_income_per_tick() == base_tax_per_citizen * total_population`.
- `collect_taxes()` with `total_population = 3` modifies the treasury by `2 * 3 = 6` and stores `treasury_income_accum["Poll tax"] == 6`.
- `collect_taxes()` with `total_population = 0` returns 0 — the treasury does not change.
- `do_tick()` copies the tax into the treasury breakdown for the tick.
- The generator `worker_manager.get_actual_treasury_income_map()` returns the flat type `"Taxes"` with `rate = 6` and `flat_label = "2 × 3 people"`; `get_planned_treasury_income_map()` too.
- Directly renders the flat tooltip row "Taxes: 2 × 3 people = 6 / sec" via `ui_helpers.show_treasury_tooltip()` and checks it in `treasury_tooltip_vbox`.
- The profit section total takes the tax into account.

That is why a tooltip with an empty market shows the tax separately and does not vanish into the void.

**The problem.** The simulation ticks every second (`CityData.SIMULATION_TICK`), and before the setting existed EVERY place that displayed resources was redrawn every tick — the numbers jumped once a second, and the player could not influence it. The setting "Settings → Game → Resource data refresh interval" sets how often the UI shows new values: **from 1 to 5 seconds with a step of 1**. The simulation (`CityData.do_tick()` and all calculations) meanwhile keeps running every second — only the display lags behind.

**The config key.** `user://settings.cfg`, section `game`, key `resource_display_interval` (default `1.0`). Read in `main_map._load_settings()`, applied via `CityData.set_resource_display_interval()` (in the map's `_ready` and in `apply_settings()`).

**The 1-second step is deliberate.** The data (supplies, the "per tick" dynamics, hex production) change only on 1-second ticks, so a fractional interval gives no benefit: updates would fall in a different phase of the ticks, and the player would see an uneven rhythm ("a jump every two, then every one") with the whole numbers invariably correct.

**The mechanic — the "display epoch" (epoch).** A single counter `CityData.resource_display_epoch` is advanced by `main_map._process` via `CityData.tick_resource_display(delta)` (when the tree is paused `_process` does not run — the interval is counted in game time). Each UI place stores the last epoch it saw and updates only when it has changed (`CityData.resource_display_due(last_epoch)`) — this way all places update simultaneously, "in one jolt" once per interval. Changing the setting advances the epoch — the UI updates immediately.

**Rule: events — instantly, ticks — at the interval.**

| Place | What it shows | Update |
| --- | --- | --- |
| The "Resources" tab (`resources_tab.update_values`; with it — the open tooltips: sources of income/expense, quality, groups, food) | supply, per-tick dynamics, quality | by epoch (the tick path `city_ui._refresh_light`); immediately — when the city is opened (`refresh()`), on structural changes (`_needs_full_refresh`), on assignment changes (`refresh_light()`), on the food toggle (`update_food_label()`) |
| The city's top strip ("Food: N [+Y/-Z] … \| Population … \| Treasury: N [+X≈ / -Y≈] …") | food supply and dynamics; the treasury — balance and actual profit/expense dynamics | by epoch; immediately — on `population_changed` and the food toggle. The treasury in the row is updated by the same tick path with an epoch check (see "Treasury display" above) |
| The treasury label in the map HUD | balance and actual profit/expense dynamics | by epoch (the tick path `main_map._on_city_data_updated`), at start/load and when the interval setting changes — immediately; along with the text the HUD panel width is recalculated to fit the row |
| The treasury breakdown tooltip (the map HUD and the city's top strip) | planned income `/sec` by source + actual expenses over the last 3 sec | first render on hover: the `building_detail_delay` delay (as for the building details tooltip, by default 0.5 s), then the panel **sticks** in place (the cursor can be moved onto the tooltip), leaving — polling + grace 0.35 s; live update of the content — on the resource epoch change (`_refresh_light` / `_on_city_data_updated` → `resource_display_due`) with the panel position preserved (`keep_position`) |
| The building details tooltip (`buildings_tab.refresh_building_detail_tooltip`) | "Required/in storage" materials + color | live update — by epoch; first assembly on hover (`_show_building_details`) — immediately |
| The hex control panel (`control_panel.on_city_updated`) | the left column "Produces/Consumes … per tick", the production list, the action preview | by epoch (the tick path); immediately — click/actions/research/claiming (`refresh()`, `_refresh()`). The action buttons are maintained every tick: their tooltips contain no values that change every tick, and the `_last_actions_snapshot` snapshot prevents recreating them without changes |
| The map tooltip (`InputHandler`, `map_tooltip`) | hex production, pasture fill level, delivery (waiting to be sent / in transit) | first render on hex change — immediately; periodic content refresh — once per `CityData.resource_display_interval`, but only on hexes with changing content (`map_tooltip.has_live_content`: a growing resource OR cargo on a route) |

**Not throttled:** static costs/descriptions from JSON; the hint "Construction: N work …" above the "Build" button (work and construction limits, not storage); population/science in the HUD (updated by events). The treasury in the HUD and in the city's top strip now obeys the resource display interval (see "Treasury display" above); the town window (`town_ui` — the "Buy/Sell" columns are still empty).

**Test.** `tools/test_resource_display_interval.gd` — the slider and the config key, the clamp/epoch of `CityData`, and on a live `MainMap.tscn`: the supply label, "Food: N", the building tooltip's materials row and the panel's left column do not update until the interval arrives and do update after; `refresh_light()` (an event) updates instantly.

---

## The "Trade" tab

The tab is split into two columns: on the left **"Domestic trade"** (working), on the right **"Foreign trade"** — so far only a heading, foreign trade itself is not implemented. The markup of both columns is in the scene `scenes/CityUI.tscn` (`ContentPanel/TradePanel/Split`), the logic is in `scripts/trade_tab.gd`.

### Resource card

One card per resource or goods group that the city currently consumes. **The card's markup lives in a separate scene, `scenes/TradeResourceCard.tscn`**, the script only instantiates it and substitutes values — any element can be moved with the mouse in the editor. The cards are sorted by name.

### Available and unavailable resources

`data/consumption.json` describes the entire possible demand of professions, but the city is not able to obtain every one of these resources: there is neither a supply nor production. Such rows must not clutter the working column, so the list is divided in two:

- **available** resources and groups — ordinary cards in the left column;
- **unavailable** ones — move under a collapsible list: the toggle "▸ Unavailable goods (N)" (with a state arrow and the number of hidden rows) and a container with the same full-fledged cards. Collapsed by default; the expanded state survives a rebuild of the list (`trade_tab.unavailable_open`).

The availability criterion is `worker_manager.is_resource_obtainable(row)`: a resource is obtainable if **at least one of its members** is already in storage (`CityData.get_storage_amount > 0`) or is part of the current production plan (`CityData.get_planned_production_map` — building recipes with a citizen and working map improvements). A group is available if at least one of its members is available: the members are interchangeable. Foreign trade, which could provide imports, is not implemented yet, so its contribution to availability is not counted — when it appears, imports will add income to the row through supply/production, and the availability rule will not change.

**Availability is part of the composition signature** (`trade_tab._signature_of`): the key is marked (`key=1`/`key=0`), so when a resource stops being available (storage is empty) or becomes available (a supply appears), the layout is rebuilt and the card moves between the working list and the collapsed section.

**The column width does not "breathe".** `InternalScroll` has `vertical_scroll_mode = SHOW_ALWAYS` (2): the space for the vertical scrollbar is permanently reserved. With `AUTO` (the default), `ScrollContainer` gave the content the width minus the scrollbar, so when the collapsed section was expanded (the list overflows, the scrollbar appears) the cards became narrower by the width of the bar, and when it was closed they became wider again. With `SHOW_ALWAYS` the card width does not depend on whether the scrollbar is currently needed.

| Field | Value |
| --- | --- |
| Name | The name of the resource or group; for a group, " (group)" is appended |
| Icon | The resource's own icon. For a group — `icon` from `data/product_groups.json`, and if it is not set, the icon of the FIRST member with an icon. The tooltip on the icon explains the source ("taken from the goods 'Beer'") |
| Priority button | Switches the quality write-off priority: stars of the best level (`best`), stars of the worst (`worst`), 🎲 (`random`). The same cycle and indication as the building quality button (`building_panel._on_quality_priority_pressed`) |
| Toggle | A single `CheckBox` — allow/forbid consumption on the domestic market |
| Storage | The total amount for the resource; for a group it is summed over all members |
| ★ (33%/67%) | A breakdown of storage by quality, each percentage in the color of its level (`GameData.format_quality_share_text`), the star marker is the light-blue `ui_helpers.QUALITY_MARKER_COLOR` (as on the "Resources" tab). Hovering shows the tooltip "Resource quality levels" (`ui_helpers.show_quality_tooltip`), the same one as on the "Resources" tab |
| Price | `CityData.get_internal_market_price` for ordinary quality; for a group — a "min–max" range over the members (the members' prices differ, averaging would be misleading). The tooltip explains the formula and the price ladder by levels |
| Buyers | How many citizens consume the resource. The tooltip is a list of the form `All citizens: 21`, `Fisherman: 1`, in descending order of the number of buyers |
| **Consumption per 1** | **The rate of ONE buyer** in its original form from `data/consumption.json`: `10 units/1 sec`. The city-wide total (10 × 21 = 210) is deliberately not shown in the row — the player configures consumption per one citizen and should see their own numbers. The full breakdown by profession and the actual over the window are in the tooltip. For a forbidden resource — "—" |
| **Income** | The **ACTUAL** over the display window: how many coins per second the market really brought to the treasury — the same source as the row "Treasury: N [+X≈]", so the sum of the "Income" rows equals the actual market profit of the treasury. The plan ("how much it would bring with a non-empty storage") and the breakdown by buyers are in the tooltip. For a forbidden resource — "—" |

**A forbidden resource stays in the list** (dimmed, consumption and income "—"): otherwise it could not be turned back on. The composition of the list changes structurally (a worker was assigned, the population grew, a resource became available or unavailable), so on every update the **composition signature** is compared (`trade_tab._signature_of`, the keys are always in the same order, with an availability mark) — on a mismatch the cards are rebuilt entirely, and on a match only the texts are updated.

### Updates and tooltips

- **Cards update at the interval from the settings** (`CityData.resource_display_epoch`), like the "Resources" tab, and not on every tick. The update only runs while the tab is active.
- **Tooltips are filled when the card is updated, not on hover** (`trade_tab._update_card` → `_price_tooltip_text` / `_consumers_tooltip_text` / `_consumption_tooltip_text` / `_income_tooltip_text`). The reason is technical: in Godot 4 a `Label` has `mouse_filter = IGNORE`, the `mouse_entered` signal **never arrives** at such a node, and the approach "hovered → assembled the text → assigned `tooltip_text`" did not work (verified on Godot 4.7). That is why `PriceValue` / `ConsumersValue` / `ConsumptionValue` / `IncomeValue` have `mouse_filter = 0` (STOP) in the scene, and the text is set in advance — as a bonus, the tooltip is assembled from the same data of the same window as the card's own numbers.
- **Tooltips are not reassigned if the text has not changed** (`trade_tab._set_tooltip`). Godot resets the display of a tooltip on any assignment to `tooltip_text`, so frequent overwriting without a check would dismiss an open tooltip. The node **under the cursor** is not touched at all: an assignment takes down the window already shown, so an update under the hovered row simply waits for the player to move the mouse away (`_hovered_tip`, tracked through `mouse_entered`/`mouse_exited` — `Control` in Godot 4 has no `is_hovered()` method).
- **The actual consumption** is taken from the display window (`CityData.get_market_consumption_per_sec` → `market_consumption_accum/_snapshot`), and not from the per-tick `market_consumption_rates`: the per-tick counter is cleared in `reset_counters()` and on an interval of 2–5 sec always turned out to be empty. The window is rotated in `tick_resource_display` together with the resource epoch.
- The open quality-breakdown tooltip (a panel of its own in `ui_helpers`) is still shown on hover and updated on an epoch change (`trade_tab.refresh_open_tooltip`) — it stays in place under the cursor.

### The row key — `display_key`

The key is the resource's **DISPLAY_KEY**: the id of a single product (`"feathers"`) or `"@group"` (`"@boats"`). This is exactly what `GameData.get_profession_consumption()` puts into the record (the `display_key` field), so the addressing is the same for single resources and groups.

This implies a difference from `get_planned_consumption_map()`: the plan expands an `@`-group into **each** member, writing the full total into each (for a tooltip this is correct — you can see exactly which goods were eaten), whereas the card needs one row per group. That is why the tab has a separate method, `worker_manager.get_population_consumption_map()`, returning `display_key → { name, is_group, members, icon, enabled, priority, sources, consumers_total, per_sec, per_consumer_per_sec, per_consumer_amount, per_consumer_interval }`. It accounts for the professions of workers on improvements (`count_workers_by_profession`), the professions of townsfolk in buildings (`CityData.get_townsfolk_professions_count`) and the pseudo-profession "All citizens" (by population).

**`consumers_total` = `max("All citizens", Σ professions)`.** The pseudo-profession `all` covers the entire population, including the employed, so a simple addition would count a fisherman twice — both in "All citizens" and in "Fisherman".

**`per_consumer_*` is the rate per one, `per_sec` is the city-wide total.** In each source of `sources` both quantities are stored: `amount` (rate × number of consumers) and `unit_amount` (the `amount` from `data/consumption.json` without multiplication). At the row level, `per_consumer_*` is calculated from the **most numerous** buyer: the card has a single "Consumption per 1" row, and the main buyer's rate is the only thing that does not lie when different professions have different rates. The other rates are visible in the row's tooltip.

### Card income: actual in the row, plan in the tooltip

The "Income" row is `worker_manager.get_actual_market_income_map()`: `display_key → { coins_per_sec, by_source }`, the **actual over the display window**. The source is the same records `CityData.record_treasury_income(profession, price, pid)` from which the treasury tooltip and the row "Treasury: N [+X≈]" are assembled, so the sum of the "Income" rows **equals** the actual market profit of the treasury.

**Why not the plan.** The plan (`per_sec × price`, see below) is not limited by storage: 21 citizens × 10 units/sec × 13 coins gave 2730 coins/sec with ten units in storage, whereas the treasury showed +161/sec. Neither of the two looked broken, but the "income" in the card was not income. Now the plan lives in the row's tooltip — that is its place, with the caption "Plan: demand … × price …" and an explanation of why the actual is lower.

**The key is `display_key`, not pid**, exactly as with the consumption cards: otherwise "Fruits" would get six rows with the full total. `display_key` is taken from the planned record of the same "source + goods" pair (`_record_planned_entry` marks records with this field); records without it (building demand, improvement feed) are production inputs, they are not sold to the city and are not part of the market income.

**The plan formula is the same for everyone** — `_planned_market_income_rows()`: `per_sec × price`, where the price is taken from `_planned_market_income_per_pid` (the market price multiplied by the average quality multiplier of storage). The same helper fills the "Population consumption" block in the treasury tooltip, so the **plan** of the cards and the plan in the tooltip cannot diverge. Previously the formula was duplicated in two places, and a test caught the discrepancy: the card showed 3570 coins/sec, the treasury tooltip — 1260. A group member with no remainder and no production does not count toward income (a group is "any suitable goods"), so the plan is honestly zeroed out when storage is empty.

### Goods group icon

Groups in the project originally had no icons of their own, and the card took the icon of the **first member with an icon set** — for "Alcohol" that is a jug of beer, for "Fruits" a bunch. Now a group can be given its own icon with an optional field in `data/product_groups.json`:

```jsonc
{
  "id": "alcohol",
  "name": "Alcohol",
  "icon": "beer.png",        // optional
  "products": [ "beer", "mead", "sake" ]
}
```

The selection rule (`GameData.get_product_group_icon_info`): its own `"icon"` field → otherwise the first icon among the members → otherwise there is no icon (the node is hidden). The field is optional, so old groups without it work as before. The method also returns the icon's source (`source_pid`) so the card can explain in the tooltip what the group is drawn with: without an explanation the player does not understand where "Alcohol" got its jug from.

### The consumption allow toggle

The card has a **single** `CheckBox` — it writes to `CityData.market_consumption_enabled[display_key]`. Previously the toggle was duplicated: next to it stood a custom 14×14 `ColorRect` (like the food toggle on the "Resources" tab) with its own synchronization logic and the `_syncing_toggles` flag, and two buttons showed a single state. The two-button variant was removed in favor of a standard `CheckBox` — it is labeled, keyboard-accessible and does not need its own drawing code.

The programmatic setting of `button_pressed` is guarded by a "value changed" check (`trade_tab._update_toggle`): assigning the same value still emits the `toggled` signal and would loop the edit.

### What the prohibition does

The prohibition is a full-fledged mechanic, not just a display:

1. `worker_manager` skips the record: storage is not deducted, the treasury receives no income;
2. the record drops out of **planned** consumption (`get_planned_consumption_map`) — otherwise the "Resources" tab would show an expense and the treasury tooltip an income that will not happen;
3. the `production_bonus` for this record is removed (`_aggregate_production_bonus`): without deduction there is no "supplying the profession with consumables" either, otherwise the prohibition would be a free way to keep the production multiplier permanently;
4. the prohibition does **not** touch the production inputs of building recipes — it concerns only the domestic market.

The prohibition check in `_tick_profession_consumption` sits **before** the accumulation of the fractional remainder, and in `tick_city_consumption` — **before** the timer accumulation: otherwise a forbidden record would accumulate a debt and, when allowed, deduct everything at once.

### Quality write-off priority

The order and the set of options come from `data/qualities.json` (`priority_options`: `best` → `worst` → `random` → `best`), the names come from `priority_names`. A value that is not in the list (a corrupted save) is read as the default — the check lives both on read and on write (`CityData.get_consumption_priority` / `set_consumption_priority`). Previously write-off on the domestic market went strictly by `"best"`.

### State and saving

Three dictionaries in `CityData` (the key in all of them is `display_key`):

- `market_consumption_enabled` — `display_key → bool`, **no key = allowed**;
- `consumption_priority` — `display_key → "best" | "worst" | "random"`;
- `market_consumption_rates` — the actual consumption per tick (`product_id → units`). A separate counter, because the general `consumption_rates` is mixed with the production inputs of buildings, and the card needs specifically the market. It lives exactly one tick and is cleared in `reset_counters()`.

The first two are saved to the save file (`SaveManager`, next to `city_food_pool`). In old saves the fields are absent — then everything is allowed and the default priority is taken, which is exactly what an empty dictionary does.

**Update.** Cards are updated on the resource epoch and **only while the tab is active** (`city_ui._refresh_light`, like `tech_tree`); when switching to the tab and on a full city refresh the list is rebuilt entirely (`trade_tab.refresh`).

**Test.** `tests/test_trade_tab.gd` — the state and the priority cycle (including a broken value from a save); the priority really changes the write-off order on a mixed storage; the prohibition stops the deduction, the income and the production bonus, drops out of the plan but stays in the market map; the shape of the map (the `display_key` key, the group is not expanded, `consumers_total`); the sum of the **plan** of the cards matches the plan of the treasury tooltip, the sum of the **actual** matches the actual of the treasury tooltip; the "phantom income" regression (storage of a single unit of excellent quality: the plan is many times greater than the actual, the "Income" row must show the actual); nodes with tooltips are not `MOUSE_FILTER_IGNORE`, the tooltips are filled without hovering and survive an update; the actual is cleared in `reset_counters`; saving/loading and an old save; on the live `MainMap.tscn` — both columns are built from the scene, the foreign one contains only a heading, cards are created, the toggle shows one state and switches it, the priority button cycles the setting, changing values does not recreate the cards. Availability: `is_resource_obtainable` (a resource with no supply and no production is unavailable, with storage it is available, a group is available if at least one member is available), the `available` field in every row of the market map; on the live scene — unavailable resources lie under the toggle and are hidden by default, the working list contains only available cards, the toggle expands and hides, the expanded state survives a rebuild of the list, a resource with an appearing supply becomes available; the card width does not change when the vertical scrollbar appears (`InternalScroll` has the `SHOW_ALWAYS` mode, the card width with and without overflow matches).

---

## Pause menu: confirmation of irreversible items


The pause menu is `scenes/pause_menu.tscn`, script `scripts/pause_menu.gd`. It is opened by the "Menu" button (top-right corner) or **ESC** (`main_map.open_pause_menu()`); when it opens the game is paused (`get_tree().paused = true`), and the city/claiming buttons are blocked.

| Item | Behavior |
| --- | --- |
| Return to game | closes the menu, unpauses |
| Save game | `save_pressed` → `SaveManager.save_game()`, then closes the menu |
| Load game | unpauses and `load_pressed` → reloads the scene |
| Settings | hides the menu, opens `settings_menu.tscn`; on return shows the menu again |
| **Return to main menu** | **asks for confirmation**, then `new_game_pressed` → `main_map._on_pause_new_game` changes the scene to `main_menu.tscn` |
| **Exit game** | **asks for confirmation**, then `get_tree().quit()` |

### Confirmation rules

- **One dialog for both items** (`confirm_dialog`, `ConfirmationDialog`), created in the menu's `_ready()`. The method `_ask_confirmation(title, text, action)` substitutes the title and text, remembers the action in `_pending_action` and shows the window.
- **The action is not connected to the signal again on every request.** Connecting `confirmed.connect(action, CONNECT_ONE_SHOT)` inside `_ask_confirmation` would, after a cancellation, leave a dangling one-shot connection: it did not fire, but it also did not disappear, and it would fire on the next confirmation (exiting the game instead of returning to the menu). The handler `_on_confirm_accepted` is single and always in place; it performs the remembered action and **resets it before the call** — the action may destroy the node (a scene change).
- **The dialog works while paused:** `process_mode = PROCESS_MODE_ALWAYS`, otherwise with `paused == true` it would accept neither a click nor ESC. The buttons are localized manually: "Yes" / "Cancel" (the project has no translation files, Godot gives "OK" / "Cancel" by default).
- **Cancellation is equivalent to "do nothing":** `_on_confirm_rejected` (the "Cancel" button, the cross, ESC) only resets `_pending_action`. The pause menu stays open, the game — paused.
- **ESC with the dialog open closes the dialog, not the menu** — the check `confirm_dialog.visible` in `_unhandled_input`. Without it ESC would dismiss the window, leaving the menu with a dialog hanging over it. Closing the menu also dismisses the dialog in `_close_pause_menu()` — in case it was closed in some other way (for example, from `InputHandler._handle_esc`).
- **The texts name the cost of the decision:** "The current game will not be saved" and "Unsaved progress will be lost". The project has no autosave, so the wording is precise.

### Key files

- `scripts/pause_menu.gd` — the menu items, the confirmation dialog, ESC.
- `scripts/main_map.gd` — `open_pause_menu()`, subscriptions to `save_pressed` / `load_pressed` / `new_game_pressed`, `_on_pause_new_game` (scene change).
- `scripts/InputHandler.gd` — ESC opens/closes the menu (`_handle_esc`).
- `tests/test_pause_menu_confirm.gd` — a headless test of the confirmations.

**Test.** `tests/test_pause_menu_confirm.gd` — a live `res://scenes/pause_menu.tscn` with pausing enabled, presses of real buttons: a click opens the dialog and does not emit the signal; "Cancel" and ESC perform nothing; ESC does not close the menu and does not unpause; "Yes" emits `new_game_pressed` and unblocks the game; a cancelled action does not "go stale". The test **terminates the process itself** with its last check (a quit confirmation must kill the game), so the `quit(0)` at the end is unreachable and the exit code proves nothing: a "Yes" that quit too early would leave code 0 without the last line. The completion point is marked by the file `user://test_pause_menu_confirm.done` — a run is counted only together with the marker.

## Game data integrity check at startup

`scripts/data_validator.gd` checks the **cross-references** in `data/*.json`: if an identifier that one entity references is not declared anywhere, that is a data breakage, and the game fails on it in-game rather than at load time. The check runs in `main_menu.gd::_check_game_data()` — that is, right after the game starts and **before the game begins** (the main menu is in `run/main_scene`, and the `MainMap` scene with map generation has not been created yet).

The JSON syntax is checked by a separate tool, `tools/validate_json.py`; there is no overlap between the two checks — that one catches broken JSON, the validator catches broken references.

| Check | Where it looks for the reference | What it points to |
| --- | --- | --- |
| `produced_in` | recipe | building |
| `result`, `display_result` | recipe | resource (raw resource or goods) |
| `improved_by` | resource | improvement |
| `unlock_improvement` | product | improvement |
| `unlock_tech` | building, improvement, resource, recipe | technology |
| `profession` | building, improvement | profession |
| `category` | **product** | category from `data/categories.json` |
| `group_member` | goods group | product |
| `resource_group` | recipe (`resources`) | `@`-group |
| `resource` | recipe (`resources`) | resource |
| `consumption_resource` | consumption rule (`resource`) | product |
| `consumption_group` | consumption rule (`resource`) | `@`-group |
| `prerequisite` | technology (`prerequisites`) | technology |
| `product_source` | product | — (see below) |
| `id_charset` | declaration (`id`) | — (see below) |
| `id_lookalike` | declaration (`id`) | — (see below) |

### Identifiers: charset and homoglyphs (`id_charset`, `id_lookalike`)

**Only the `id` fields** in all 15 collections are checked — resources, recipes, buildings, improvements, technologies, categories, professions, goods groups, quality levels, special actions, terrains, covers, eras, road levels.

**Only** the set `a-z`, `0-9` and `_` is allowed. It is exactly what is used in all 515 identifiers of `data/`, so the strict rule produces not a single false positive. Everything else — Cyrillic, spaces, hyphens, uppercase — is an error.

**Why this is needed.** An identifier is at the same time the key by which the files are stitched together and the text that the author searches for by eye in the editor. A typo with a Cyrillic "с" is indistinguishable from a Latin "c" **and at the same time does not break references** if the neighboring identifiers are written the same way. All the other validator checks miss such a case.

- `id_charset` — there is a character in `id` outside the allowed alphabet. The message contains the **position, Unicode code and a hint** ("looks like "c" in Latin"), because printing the character itself in the text is useless: the author would read "с" as "c". Uppercase letters are not caught — `_` and digits are part of the project, and uppercase in an id is visible at once.
- `id_lookalike` — **two identifiers indistinguishable by eye** are declared at the same time (`carmine` and `сarmine`). This is a case that ordinary checks miss entirely: for the engine these are two different resources, a reference to the Latin spelling is correct (it exists and looks right), and the Cyrillic one lies as dead weight. Characters indistinguishable from Latin ones are reduced to their Latin form by the `IDENT_LOOKALIKES` table; for a character outside the table there will be no hint — that is more honest than guessing the form.

**Why references are not checked separately.** This is not a simplification: if a reference contains the same non-ASCII character as the declaration, the problem will be found by `id_charset`. If it points to a Latin identifier, it will be found by any of the broken-reference checks. A separate pass over references would not have found a single new case.

**What the checks do not touch:** the `name` and `description` fields — in `data/*.json` they are legitimately in Russian (the translation is applied over the English text, `data_loader.DISPLAY_FIELDS`). The check runs over the `id` field and nothing more.

### Consumption rules (`consumption_resource`, `consumption_group`)

`data/consumption.json` is checked separately from recipes, because **`resource` is resolved differently**: a key without `@` is looked up in `GameData.products`, with `@` — in `product_groups` (this is exactly what `GameData._build_consumption_entry` does). The check mirrors the resolver, not the general recipe references: consumption takes **goods from storage**, not a raw resource from a hex, so the "raw resource" from `all_resources` does not fit here — and checking against it would produce false positives on every product. The `profession` field is checked by the general `profession` check: the message is equally true for buildings, improvements and consumption rules.

**The most common breakage here is a forgotten `@`.** The author writes a group id where a resource is needed. Before the check appeared, such a record broke nothing: the resolver substituted `products.get(id, {})`, and the rule got an identifier label with an empty icon — the consumption row silently hung in the interface and **never deducted anything**. Now this is visible both in the problems window and in the console (`GameData._build_consumption_entry` prints a warning and skips the record, as is already done for a nonexistent group).

**A rule's identifier is its `resource`.** The registry record has no `id` field, so the general origin-index pass (`data_loader._remember_sources`) skips such records, while a separate one (`_remember_consumption_sources`) keys them by the value of `resource` — the same one that the validator passes as `source_id`. The declaration line is looked up by its own `_find_resource_decl_line`: the general `_find_decl_line` looks for the first occurrence of the value in the raw text, does not cut out comments, and the reference would point to the author's explanation rather than to the rule.

### A product without a source (`product_source`)

The other checks catch **broken references** — an identifier that someone referenced but did not declare. `product_source` catches the opposite: an identifier is declared, but **there is nowhere to get it**. A product that is produced neither by an improvement on the map nor by a recipe is unreachable: it will not appear in storage, and recipes that require it will forever stall with "no raw material". In-game this is visible only as an empty storage — without a single word of "why".

A source exists if the product's id appears in at least one of five places:

| Where | Field | What it is |
| --- | --- | --- |
| recipe | `result` | the ordinary crafting output |
| recipe | `display_result` | a pseudo-output for the interface: it does not create a real goods, but "Science" (`science`) exists only there |
| resource | `produces` | production by an improvement on the map (the field exists both for raw resources and for goods — the mechanism is the same) |
| building | `additional_yield` | a fixed output per second: `science` at the library and the scriptorium |
| cover | `wood_yield` | the woodcutter's camp (see below) |

**Only products are checked.** Raw resources are taken from the map by generation, so by definition they have a source, and checking raw resources would produce false positives on each of the 112 resources.

**The woodcutter's camp is the only producer that is not in `produces`.** "Wood" (`wood`) does not appear in any `produces`: it is made by the camp on an empty forest hex, and the output is taken from the `wood_yield` field of the **cover** (`data/covers.json`), not from the resource on the hex (`main_map.gd`, production tick → `CityData.add_to_storage("wood", …)`). The link "cover → camp → product" is hardcoded in the code, so it is not visible from the data. The validator restores it **by reading the data**, not by an exception list: a source exists if `lumberjack_hut` is declared **and** at least one cover has `wood_yield > 0`. Demolish the camp or zero out the output from the covers — the validator will say that wood is unreachable. An exception list would be silent about both cases.

### What the validator must NOT complain about

- **`produced_in: ["*"]`** — a service marker "in any building" (parsed in `CityData.can_craft_in`). Without an exception the validator would complain about the pseudo-recipe `empty` in `data/crafts/pseudo.json`.
- **`category` on a RAW RESOURCE** — this is a map-generation filter with its own set of values (`animals`, `plants`, `metals`, `minerals`, see `MapHelpers.ensure_minimum_resource`), not a category from `categories.json`. It must not be checked against `categories.json`: that set is not there, and the validator would spew false positives on every animal. That is why `category` is checked **only on products**.
- **Explicitly empty fields** (`"improved_by": null`) — this is "no improvement", not a reference. `str(null)` in GDScript gives the string `"<null>"`, so empty values are converted to an empty string (`_as_id`), otherwise every empty field would be considered broken.
- **Goods from `display_result`** — "Science" does not get into storage (it has an empty `result`), but a recipe produces it, and without accounting for `display_result` the `product_source` check would declare it unreachable.
- **Wood from the woodcutter's camp** — produced from the cover's `wood_yield`, not from the resource's `produces`; the source is restored by reading the data (see the section above).

### Message format

A problem is shown in a **window**, not as a console entry: the data author needs to see which identifier is missing, in which field it was referenced and **in which file it lies**.

```
Technology with the identifier "salt_mining" does not exist.
A reference to this technology is present in product "Salt" (salt), field unlock_tech.
File: res://data/products/products.json, line 93.
```

For `product_source` the wording is different — there is no broken reference, so it is absent from the first line too; the owner (the product itself) and the file remain:

```
Product "coal" is not produced anywhere.
Source not found: product "Coal" (coal) appears neither in produces of any map
resource, nor in result/display_result of any recipe, nor in additional_yield
of any building. Add a data source or remove the product from the file.
File: res://data/products/minerals.json, line 3.
```

The window is `scripts/data_problems_window.gd`: a dimming overlay, a list of problems in blocks by check kind, a summary "how many of which kinds", the buttons "Copy the list" (to the clipboard) and "Close" (or ESC). The window does not patch the data — you need to edit the files in `data/`.

### Where the file and line come from

`_merge_dictionaries` merges all `data/` files into a single dictionary, and after that the place where each entity is declared cannot be recovered: "Wheat" could have come from `products/food.json` or from `products/products.json`. That is why, while reading the files, the index `data_loader.entity_sources` is filled in parallel with the merging:

```
"collection:id" → { "file": "res://data/product_groups.json", "line": 44 }
```

The kind of the reference owner is mapped to a top-level collection through `SOURCE_COLLECTIONS` in the validator (for resources this is `resources` — raw resources and goods lie in a common list, and the `type` field distinguishes the type).

The subtleties on which this breaks:

- **The line is counted by the ORIGINAL text of the file, not by the one cleaned of comments.** `_strip_json_comments` discards the line breaks inside `/* … */`, so the numbering of the cleaned text would not match what the author sees in the editor (in `improvements.json` the header comment takes up half the screen).
- **This is the line of the owner's DECLARATION, not a line of mention.** For `oil_crops` it is 44 (`"id": "oil_crops"`), while the list members are 47, 49, 52: a difference of several lines within a single record. The declaration was chosen because it is unique: an id can occur in the same file both as a group member and as a recipe result, and then the "line of mention" would point to the wrong place.
- **Data without an index does not crash the validator.** `_source_index()` will return an empty dictionary, and the problem will simply be left without the "File:" line.

### Key files

- `scripts/data_validator.gd` — the checks, `validate(gd) -> Array` and `count_by_kind()`. It does not depend on autoloads: the data is passed as an argument, so the validator runs headless on artificial data.
- `scripts/data_problems_window.gd` — the window with the list of problems.
- `scripts/main_menu.gd` — `_check_game_data()`, the entry point of the check.
- `scripts/GameData.gd` — the `data_loaded` flag (so as not to read `data/*.json` twice: the menu checks the data on entry, and a new game loads it again) and the passing-through of `entity_sources`.
- `scripts/data_loader.gd` — `entity_sources`, `_remember_sources()`, `_find_decl_line()`. `SOURCE_COLLECTIONS` lists 15 collections: the first 9 are needed for references, the remaining 6 (`terrains`, `covers`, `eras`, `groups`, `quality_levels`, `special_actions`) — **only** for the identifier checks, so that a problem points to the file and line.
- `tests/test_data_validation.gd` — a headless test.

**Test.** `tests/test_data_validation.gd` checks five things. **The detector:** on synthetic data exactly one breakage is introduced into each kind of check, and the test requires finding each one — with the correct check kind, identifier and reference owner; an extra or missing problem also counts as a bug. The data is synthetic **deliberately**: the test must not break when the author fixes the real `data/*.json`. Because of the "product without a source" check, the set needs a "donor" recipe — it gives a source to all products with deliberate breakages in other fields, otherwise a single breakage would produce two problems at once and the "exactly one" requirement would stop meaning anything. **False positives:** `*` in `produced_in`, `category` on a raw resource, explicitly empty (`null`) fields, "product without a source" for goods from `display_result` / `produces` / the woodcutter's camp, **Cyrillic in `name`** (in `data/*.json` it is legitimate) and an underscore with digits in `id` — these are nine places where a naive validator makes noise. **The camp's exception is computed from the data:** zeroing out `wood_yield` on all covers and deleting `lumberjack_hut` separately must each cause wood to end up in the problems — otherwise the "source" would be a hardcoded list that would be silent forever. **Non-ASCII in id:** a Cyrillic identifier produces **two** problems of different kinds at once — `id_charset` ("replace it with Latin") and `id_lookalike` ("you now have two different resources"), and the test requires both. This is not a duplicate, but two different statements about a single character. **Absence of the index:** on data without `entity_sources` the problems are still found, but without the "File:" line. **Correctness of the file reference:** for each problem on the real data the file lies in `res://data/`, the line does not go beyond the file, and **at the specified line the owner's declaration really is located** — what is checked is not the number itself, but that it points where it promises. For `product_source` problems it is additionally checked that the owner is a product from `GameData.products` and not a raw resource. The real `data/*.json` are otherwise run for invariants, and their list of problems is printed for reference and not checked — **except for one case: the absence of non-ASCII in id is checked as zero.** Here a failure means not someone else's breakage, but a typo that went into the release and cannot be caught by anything else.

## Running tests: `tools/run_tests.py`

The tests are independent headless `SceneTree` scripts (`tests/test_*.gd`), each in its own
Godot process. They are run by a single launcher:

```
python tools/run_tests.py                 # the fast set (before a commit)
python tools/run_tests.py --all           # all 39 tests
python tools/run_tests.py --only road,sea # filter by a substring of the name
python tools/run_tests.py --only town_economy --case=readiness
                                          # one case from one test
python tools/run_tests.py --only cancel_actions --repeat=5
                                          # 5 times in a row — catching flakes
python tools/run_tests.py --list          # what was found and in which set
python tools/run_tests.py -j 1            # sequentially (for debugging)
```

**Why a launcher and not a framework.** The tests are ordinary `SceneTree` scripts with their own
contract (a verdict line and/or an exit code, plus `tests/watchdog.gd` for hangs).
GUT/gdUnit would require rewriting all of them for no gain. The launcher only
gathers the run in one place and applies the same verdict rules to each.

**Verdict rules** (in order, the first one that fires decides):

1. **Engine errors.** `SCRIPT ERROR`, `Parse Error`, `Failed to load script` in stderr —
   this is a failure regardless of the exit code. The log records a real case where
   the asserts passed but an integration test printed an engine error that a run
   filtering by `FAIL` in stdout did not see.
2. **Timeout** (the process was killed) — a failure. The limit is taken from the test's own
   `WATCHDOG.arm(self, N)` plus a margin of 30 s, that is, each test has its own limit.
3. **Exit code ≠ 0** — a failure. Code 2 — the watchdog fired or the test's own `_failed` branch.
4. **Code 0, but no verdict line** — a failure. An empty run is not counted as successful:
   otherwise a test that did nothing would look green.
5. **`test_pause_menu_confirm` — by the marker.** This test kills its own process while checking
   the quit confirmation, so its exit code proves nothing. The verdict is the file
   `user://test_pause_menu_confirm.done`, which the test writes right before the last click;
   the launcher deletes the marker before starting so that a file from a previous run does not give a false `PASS`.

**Sets.** "Fast" — everything that does not depend on the generation of a whole map and long
economic runs; "slow" (20 tests out of 39) — `--all`. The classification lies in the
constants `SLOW` / `MARKERLESS` / `NEEDS_SENTINEL` in the script itself. A test that fell into no
list is still executed under `--all` and printed as `fast`, that is, a new
test cannot silently drop out of the set.

**Case selection.** 17 tests declare named cases (`func _test_*`). The `--case` filter
arrives through `OS.get_cmdline_user_args()` (after the `--` separator on the command line)
and is handled by `tests/watchdog.gd`: `WATCHDOG.wants_case("name")`. The comparison is by
substring, case-insensitive, so `--case=readiness` covers `_test_readiness`.
Skipped cases are printed as a list before the verdict (`SKIPPED (--case): …`) so that
a filtered run does not look complete.

**Repeats.** `--repeat=N` runs each test N times. A test that passes neither all nor
any attempt is marked `FLAKY` — this is the main reason for the flag: catching unstable
tests that fail every other time. Each attempt gets its own `APPDATA` sandbox,
so state does not leak between runs.

**Isolation.** `APPDATA` is substituted for each process, so parallel tests do not share
`settings.cfg`, `savegame.json` and the `test_pause_menu_confirm` marker (two tests really
write to the user directory). The logs of each test and the run summary are placed in
`tools/test_logs/` (a service directory, it does not get into the index).

A parallel run on 6 workers takes about a minute versus roughly six minutes for a
sequential one.

