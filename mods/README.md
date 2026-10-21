# Mods — how to create a mod for The City

This guide describes how mods work in the game and how to assemble them correctly.
A ready-made example mod lives in the `test_mod` subfolder next to this file.

---

## 1. What a mod is

A mod is a **folder** with a required `mod.json` manifest and an optional `data` folder:

```
mods/
  my_mod/                  <- the mod folder (the folder name itself means nothing)
    mod.json               <- the manifest (the file name is fixed)
    data/                  <- the game data (an optional folder)
      buildings.json
      crafts.json
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
covers, special_actions, consumption, group_bonuses, subgroup_bonuses,
modifiers, map_config, game_balance, city_names, qualities,
priority_default, priority_options, priority_names
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
- Arrays without identifiers (for example, `city_names`) are only appended to.
- The top-level dictionaries that are not collections of entities (`game_balance`,
  `modifiers`, `map_config`, `qualities`) are merged **recursively, block by block**: a
  mod changing one constant does not erase its neighbours.
- Do not declare the same `id` twice inside one mod: the order the files inside `data` are
  read in is not guaranteed. Between different mods the order is deterministic — by
  dependencies, and a mod applied later overrides one applied earlier.

### 4.3. Localization

The `data` files hold the **English** source text of the `name`, `description`, `flavor`
fields — that text is also the translation key (the same as in the vanilla files).

---

## 5. A mod skeleton

```
mods/tile_industry/
  mod.json
  data/
    buildings.json      <- new and changed buildings
    crafts.json         <- new and changed recipes
    resources.json      <- new and changed resources
```

A ready-made specimen exercising both merge rules — `mods/test_mod`.

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
- [ ] The mod passes the data validator with no new errors.
