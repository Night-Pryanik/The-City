# Mods — how to create a mod for The City

This guide describes how mods work in the game and how to assemble them correctly.
Two ready-made examples live next to this file:

- `test_mod` — the full specimen: new entities, overrides of vanilla ones and a blacklist;
- `blacklist_example` — a small mod that only REMOVES things (see §4.3).

---

## 1. What a mod is

A mod is a **folder** with a required `mod.json` manifest, an optional `data` folder and an
optional `icons` folder:

```
mods/
  my_mod/                  <- the mod folder (the folder name itself means nothing)
    mod.json               <- the manifest (the file name is fixed)
    data/                  <- the game data (an optional folder)
      buildings.json
      crafts.json
      ...
    icons/                 <- the pictures of the entities it adds (an optional folder)
      buildings/
        windmill.png
      ...
```

Where mods live:

- `mods/` in the game folder (`res://mods`) — the mods shipped with the game;
- `mods/` in the user folder (`user://mods`; on Windows that is
  `%APPDATA%\The City\mods`) — the mods installed by the player.

A mod in `user://mods` with the same `id` as a shipped one **replaces** it — that is how
a shipped mod is patched without touching the game files.

**The set of mods belongs to the save.** It is chosen in the city naming dialog
(the "Mods (n)" toggle) and stored in the slot; when a save is loaded the game restores
the very set that city was played with.

---

## 2. How mods and their files are scanned

### 2.1. Mod discovery

The game looks **only at the subfolders** of `mods/` and `user://mods` — one level deep.
In each subfolder it looks for a file named **exactly `mod.json`**.

- A folder without `mod.json` is silently ignored.
- A file with any other name (`manifest.json`, `meta.json`, …) is **not** a manifest —
  the mod does not show up in the list at all.
- A bare `.json` file lying directly in `mods/` (not in a subfolder) is not a mod and is
  ignored.
- Folders nested inside a mod are not mods themselves.

### 2.2. Mod data: ONLY the `data` folder is read

The game opens `<mod folder>/data` and reads **all** `.json` files inside it.

**If you put `buildings.json` in the mod folder root (next to `mod.json`) instead of in
`data`, the game will NOT find it.** A file outside `data` is simply not read — the mod
counts as "empty". The `data` folder is optional: a mod without it is valid, it just
changes nothing.

The only other folder the game opens is `<mod folder>/icons` — the pictures for the
entities the mod adds (§4.5). Everything else in the mod folder is ignored.

### 2.3. Inside `data` the folder structure is free

The walk is **recursive**: files may be laid out in any subfolders at any depth
(`data/buildings.json`, `data/products/food.json`, `data/whatever/you/like.json`) —
everything is read and merged together. The order of the folders and files inside `data`
does not affect the result (only the top-level JSON structure matters, see §4).

### 2.4. Comments in JSON are allowed

Data files may use `//` and `/* … */` — they are stripped before parsing
(the same as in the vanilla `data/*.json`).

---

## 3. The `mod.json` manifest

### 3.1. Required fields

| Field      | Required | Requirements |
|------------|----------|--------------|
| `id`       | **yes**  | a non-empty string; latin letters, digits and `_` only |
| `name`     | **yes**  | a non-empty string — shown in the mod list |
| `version`  | **yes**  | a non-empty string (free format, e.g. `"1.0.0"`) |
| `authors`  | **yes**  | a non-empty array of strings; or the single field `author`: `"Name"` |

If any of these fields is missing or empty, the mod **appears in the list but cannot be
enabled** — the game shows the reason.

### 3.2. Optional fields

- `description` — a string, the text shown in the mod list.
- `dependencies` — an array of other mods' `id`s. When a mod is enabled, its dependencies
  are enabled automatically and applied **before** it (a dependency is always applied
  before its dependent).
- `conflicts` — an array of mod `id`s incompatible with this one. The game refuses to
  enable a conflicting set (checked in both directions).

Depending on or conflicting with oneself is forbidden. The `id`s in
`dependencies`/`conflicts` follow the same alphabet rule as the mod's `id`.

### 3.3. A minimal manifest

```json
{
  "id": "my_mod",
  "name": "My First Mod",
  "authors": ["Your Name"],
  "version": "1.0.0"
}
```

A full example — `test_mod/mod.json`.

---

## 4. Data files

### 4.1. File names mean nothing

The game does **not** look for specific names like `buildings.json`. All `.json` files
from the `data` folder are read and merged into one tree, and the parsing goes **by the
top-level JSON keys**, not by the file names.

So the `buildings` dictionary happily lives in `my_buildings.json`, `extra/xyz.json` or
any other name — as long as the file is inside the `data` folder. The vanilla file names
(`buildings.json`, `crafts.json`, …) are a convention for humans, not a requirement.

**But the top-level keys themselves must be the vanilla ones.** The allowed keys
(the data collections):

```
resources, crafts, buildings, improvements, technologies, categories,
groups, eras, product_groups, professions, quality_levels, roads, terrains,
covers, climate_zones, special_actions, consumption, group_bonuses, subgroup_bonuses,
modifiers, map_config, game_balance, city_names, qualities,
priority_default, priority_options, priority_names, blacklist
```

Any other top-level key is an `unknown_field` error, and such a mod cannot be enabled
(see §6).

### 4.2. The merge rules with the vanilla data

A mod's data is laid on top of the vanilla data **before** the game collections are
assembled, addressed by the record's `id`:

1. **A new `id`** — the record (a product, a building, a recipe…) is simply added next to
   the vanilla ones.
2. **An existing `id`** — the record is overridden **field by field**: the fields the mod
   writes replace the vanilla values; the fields it does not write keep theirs. No
   duplicates appear.

Details:

- A field value is taken **as a whole**. If a mod writes `"produces": {...}`, that
  dictionary replaces the vanilla one, it does not add entries to it.
- The records of the `consumption` collection are addressed by the `resource` field, not
  by `id` (the same as in the vanilla data).
- Arrays without identifiers (for example, `city_names`) are only appended to. The
  vanilla city-name pool is not one of these arrays: it lives per language in
  `locale/city_names_<code>.json`, outside the mod merge, and what a mod adds is laid
  on top of the pool of the current language.
- The top-level dictionaries that are not collections of entities (`game_balance`,
  `modifiers`, `map_config`, `qualities`) are merged **recursively, block by block**: a
  mod changing one constant does not erase its neighbours.
- Do not declare the same `id` twice inside one mod: the order the files inside `data` are
  read in is not guaranteed. Between different mods the order is deterministic — by
  dependencies, and a mod applied later overrides one applied earlier.

### 4.3. The blacklist: removing entities

A mod does not have to only add and change — it can also **remove** vanilla entities.
The `blacklist` key is a dictionary: a **collection** → the list of the **identifiers**
to remove from it.

```json
{
  "blacklist": {
    "buildings": [ "alchemist_house" ],
    "crafts": [ "papyrus", "glass_bottle", "green_vitriol", "ink_from_green_vitriol_galls" ],
    "resources": [ "papyrus", "glass_bottle", "green_vitriol" ]
  }
}
```

- The keys are the collection names from §4.1 that hold records with identifiers
  (`resources`, `crafts`, `buildings`, `improvements`, `technologies`, `categories`,
  `groups`, `eras`, `product_groups`, `professions`, `quality_levels`, `roads`,
  `terrains`, `covers`, `climate_zones`, `special_actions`, `consumption`). Any other key is reported as
  an unknown field. The config blocks (`game_balance`, `modifiers`, `map_config`,
  `qualities`) and the arrays without identifiers (`city_names`, the diversity bonuses)
  cannot be blacklisted — there is no entity to remove.
- The identifiers belong to their collection. The same id in two collections is **two
  different entities**: `"papyrus"` in `crafts` and in `resources` are the recipe and the
  product, and the example above removes both. Inside one collection a repeated id
  changes nothing.
- The blacklist is applied right after the mod's own merge, so the rule between mods is
  the one of the overrides: a mod applied **later** (a dependent, or one the dependency
  order put after it) may declare a blacklisted entity again, and it will be back.
- The `consumption` rules are addressed by their `resource` field, exactly as in the
  vanilla data: `"consumption": [ "bread" ]` removes the rule that spends bread.
- Keep the whole blacklist in **one** file: two files of one mod that both list the same
  collection do not add up, the one read later wins.

**A removed entity leaves its references behind, and they are the mod's own business.**
A goods group that lists a removed product, a recipe that spends a removed resource, a
building whose `default_recipes` names a removed recipe — all of them are broken
references now, and the check of §6 refuses the mod until they are cleaned. The referrers
are removed the same two ways: a blacklist entry (remove the referrer too) or an
override (rewrite the field without the removed id). `mods/test_mod` shows both: it
blacklists the product `papyrus` and rewrites the two goods groups that listed it, and
it removes the whole vitriol chain of the alchemist house — the building, its recipe,
the recipe that spends the product, and the product itself.

`mods/blacklist_example` is the short version of the same idea, and it is the one to read
first. It removes one whole chain — the winemaker's house, its two recipes and the two
wines they produce — and then rewrites the single goods group that listed the wines:

```
data/blacklist.json         the building, the recipes, the products
data/product_groups.json    the "alcohol" group without the two wines
```

The order matters for the reader, not for the game: the blacklist is applied first, so
the group written by the mod never names a product that is still there. Note what the
mod does NOT touch: the `winemaker` profession stays (nothing refers to a profession from
the side of the buildings), and so does the technology that unlocked the house — a
removal takes out entities, not the rules that led to them.

A blacklist entry that names nothing is reported as well (the check `blacklist`): the
collection has no such identifier and no mod declared it, so nothing was removed. It is
a typo, and a blacklist that silently does nothing is worse than one that fails.

### 4.4. Localization

The `data` files hold the **English** source text of the `name`, `description`, `flavor`
fields — that text is also the translation key (the same as in the vanilla files).

---

### 4.5. Icons for the entities you add

A new resource, building or technology needs a picture. The game takes it from the **icons
folder of the mod**, so the mod carries its own art and the data only names the file:

```
mods/tile_industry/
  icons/
    resources/
      rye.png
    buildings/
      windmill.png
    tech/
      windmills.png
    misc/
      windmill_token.png
```

```json
{ "id": "windmill", "name": "Windmill", "icon": "windmill.png", ... }
```

The rules:

- The layout is the one of the game's own `res://icons`: the **first folder** under `icons/`
  is the type of the pictures inside it. The folders are `resources`, `buildings`, `tech`,
  `terrain`, `improvements`, `special_actions`; everything else — the root of `icons/`
  included — is **misc** (coins, buttons, marks of the interface). The nesting below the
  first folder is free. The names the manifest of a tileset uses work as folders too:
  `products` is `resources` (a product is a resource record), `terrains` is `terrain`,
  `technologies` is `tech`.
- The `icon` field of the data names the file **exactly, extension included**:
  `"icon": "rye.png"` for `icons/resources/rye.png`, `"icon": "rye.svg"` for a drawing in
  SVG. There is no "find by bare name" here: the extension is a part of the name.
- PNG, SVG, WEBP, JPG, BMP and TGA are read. A mod in `%APPDATA%\The City\mods` is a set of
  **raw files** the engine has never imported, so the game decodes them itself: the picture
  is taken as it lies on disk, with no import step and no `.import` file of any kind. An
  SVG is rasterised at the size it declares.
- An icon with the name of a vanilla one **replaces** it. That is how a mod redraws the art
  of the game without a tileset. When two mods ship one name, the mod **lower in the list**
  wins, and the game prints a warning naming both.
- Only the mods of the **running game** are indexed: a switched-off mod brings no icons and
  cannot take a name from another mod. A mod that only ships pictures (a retexture, no
  `data` at all) works the same way.
- A tileset from `tilesets/` draws the **vanilla game**: a file of a set that names an icon
  of a mod replaces nothing. What a mod draws is the mod's own business.

Nothing else has to be done: a mod icon is an ordinary icon of the registry, so the map,
the lists, the tooltips and the buttons find it by the same name as a vanilla one.

### 4.6. Redrawing a vanilla entity with one picture

A terrain and a cover are drawn from **several pictures** (`icons/terrain/tundra_plain_1.png`,
`_2`, `_3`), and the game picks one by the hex. A mod that wants **one** picture for such an
entity does not copy it under three names: it declares the entity again in its own data and
names its own picture there.

```json
// mods/my_mod/data/pictures.json
{
  "terrains": [ { "id": "tundra_plain", "icons": [ "my_plain.png" ] } ],
  "covers":   [ { "id": "tundra_moss",  "icons": [ "my_moss.png"  ] } ]
}
```

The data of a mod is merged **field by field** (§4.1): the record keeps the `name`, the
`color`, the `move_cost`, the `family` and every other field of the vanilla one, and only the
`icons` list is replaced. The pictures themselves lie in `icons/terrain/` of the mod.

The rules:

- The **same id** is the whole mechanism — no separate list, no new manifest field. What the
  mod writes is what it overrides; the rest stays vanilla.
- The mod redraws the entity, it does not rename it: the id, the name and the yields stay.
- A tileset keeps addressing the pictures of the **game**, so a mod's one-picture override
  does not change what a set draws. When a mod and a set both draw one entity, the mod's data
  wins: the entity no longer lists the pictures a set replaces.
- One picture for **one** entity is all this does. Several entities with one picture are
  several records — the data decides what a group is.

---

## 5. A mod skeleton

```
mods/tile_industry/
  mod.json
  data/
    buildings.json      <- new and changed buildings
    crafts.json         <- new and changed recipes
    resources.json      <- new and changed resources
    blacklist.json      <- the entities to remove from the game (an optional file)
  icons/                <- the pictures for the entities it adds (§4.5)
    buildings/
      windmill.svg
    resources/
      rye.png
```

A ready-made specimen exercising all three rules — adding, overriding and removing — is
`mods/test_mod`. It also ships its own icons: the building `tile_kiln` and the good
`glazed_tile` are drawn by `mods/test_mod/icons/`, and their `icon` fields name those files.
A specimen that only removes is `mods/blacklist_example`:

```
mods/blacklist_example/
  mod.json
  data/
    blacklist.json          <- the entities to remove from the game
    product_groups.json     <- the groups that referred to them, rewritten
```

---

## 6. The data check on enabling

When a mod is enabled, the game assembles the data "vanilla + the selected mods" **exactly
as the game will see it**, and runs the result through the validator. Only the problems
the mod **adds** to the vanilla ones are reported (broken vanilla data does not blame
every mod).

If such problems exist, the mod **cannot be enabled**: the checkbox flips back and the
game shows the list of problems with the file and the line (including inside the mod).
So a mod's data must be well-formed: existing references, known fields, valid
identifiers.

---

## 7. A short checklist

- [ ] The mod is a folder inside `mods/` (in the game root or in `%APPDATA%\The City\mods`).
- [ ] The mod folder root holds a file named **exactly** `mod.json`.
- [ ] `mod.json` has `id`, `name`, `version`, `authors` (or `author`) filled in.
- [ ] `id` — `a-z`, `0-9`, `_` only.
- [ ] All data lives **inside the `data` folder** (files in the mod folder root are not
      seen).
- [ ] Inside `data` the file names and the subfolder structure are arbitrary; only the
      top-level JSON keys from the vanilla list matter.
- [ ] A new `id` is added; an existing one is overridden field by field.
- [ ] A blacklisted entity has no references left: the groups, recipes and rules that
      named it are removed or overridden too.
- [ ] Every new entity has a picture in the `icons` folder of the mod, and its `icon` field
      names the file with the extension (`"icon": "rye.png"`).
- [ ] The mod passes the data validator with no new errors.
