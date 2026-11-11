# Tilesets — how to re-draw the icons of The City

This guide describes how a tileset works and how to assemble one. A ready-made specimen
lives next to this file:

- `_example` — a set that declares **every** type and carries a few icons of each, so the
  whole mechanism can be seen at once. It is switched **off** by its folder name (see §2.1)
  — rename the folder to `example` and restart the game to see it work.

A tileset **replaces icons, it does not add new entities**: the game keeps its own icon
names and the data (`data/*.json`) keeps pointing at the vanilla file names. A tileset
decides which *picture* is shown for a name. The one thing it may add is **extra numbered
variants of a family the vanilla game already knows** — a fourth, fifth or sixth picture
of a cover (§4.2).

---

## 1. What a tileset is

A tileset is a **folder** with a required `tileset.json` manifest and the images:

```
tilesets/
  my_set/                  <- the tileset folder (the folder name is the id of the set)
    tileset.json           <- the manifest (the file name is fixed)
    icons/                 <- the images, any layout inside the folder
      buildings/
        bakery.svg
      misc/
        coin_stack.svg
```

Where tilesets live: in the `tilesets/` folder of the game (`res://tilesets`). Unlike
mods, there is no second root in the user folder — a tileset is installed by copying its
folder into `tilesets/`.

**The set of tilesets is not a part of the save.** The game reads the folder once at
startup and the result is the same for every city. Which set draws which type of icons is
the player's choice, made in Settings → Appearance → *Icon sets* (see §5).

---

## 2. How tilesets and their files are scanned

### 2.1. Discovery

The game looks **only at the subfolders** of `tilesets/` — one level deep. In each
subfolder it looks for a file named **exactly `tileset.json`**.

- A folder without `tileset.json` is silently ignored.
- A file with any other name (`manifest.json`, `tileset.example.json`, …) is **not** a
  manifest — the folder is not a tileset.
- A bare `.json` file lying directly in `tilesets/` (not in a subfolder) is ignored.
- Folders nested inside a tileset are not tilesets themselves.
- **A folder whose name starts with `_` is skipped.** That is how the shipped example
  stays inert: `tilesets/_example` is a complete, valid tileset that the game never reads.
  Rename it to `example` (or drop the underscore from your own folder) to switch it on.
  This is also the way to keep a set at hand without applying it.

### 2.2. The images: the whole folder is read

Everything inside the tileset folder is scanned **recursively**, in any subfolders at any
depth. The subfolder layout means nothing to the game — `icons/buildings/bakery.svg`,
`bakery.svg` and `whatever/deep/bakery.svg` are the same icon. The example groups its
files by type for the human reading it, not for the game.

These extensions are taken for images:

```
.png  .svg  .webp  .jpg  .jpeg  .bmp  .tga
```

Anything else in the folder (a readme, a palette, a source `.kra`/`.psd`, `*.import`,
`*.uid`) is left alone. The case of the extension does not matter.

If two files inside one tileset have the same bare name (`bakery.png` and `bakery.svg`),
the first one found wins — keep one picture per icon.

### 2.3. Importing

The engine turns every image into an imported texture, and an image that was never
imported **cannot be loaded**. After adding or replacing files in `tilesets/`, open the
project in the Godot editor once (or run `godot --headless --path . --import`) so that the
new files get imported. An exported build carries the imported textures with it.

---

## 3. The `tileset.json` manifest

### 3.1. Fields

| Field         | Required | Meaning |
|---------------|----------|---------|
| `name`        | **yes**  | the name of the set — a non-empty string |
| `description` | **yes**  | what the set is, for the player and for the author of the next set |
| `type`        | **yes**  | the types of icons this set replaces; a string or an array of strings (§3.3) |
| `author`      | no       | the author; a string, or the plural form `authors` with an array |
| `version`     | no       | a free-form string, e.g. `"1.0.0"` |

If `name`, `description` or `type` is missing or empty, the tileset is **not applied** —
the game skips it and prints the reason to the log. The folder is still a tileset, so the
mistake is reported instead of silently disappearing.

`//` and `/* … */` comments are allowed in the manifest (the same as in `data/*.json`).

### 3.2. A minimal manifest

```json
{
  "name": "My First Set",
  "description": "Re-drawn building icons.",
  "type": "buildings"
}
```

A full example — `_example/tileset.json`.

### 3.3. The types

`type` says **what the set is drawn for**, and it is the only thing that decides which
vanilla icons the set may replace:

| Type              | What it covers |
|-------------------|----------------|
| `resources`       | raw resources and products (`icons/resources/**`) |
| `buildings`       | buildings (`icons/buildings/**`) |
| `technologies`    | technologies (`icons/tech/**`) |
| `terrains`        | the terrain pictures of the map (`icons/terrain/**`) |
| `improvements`    | improvements — farms, mines, pastures (`icons/improvements/**`) |
| `special_actions` | the special actions of a town and the road (`icons/special_actions/**`) |
| `misc`            | everything else: coins, the upgrade and the pause of a building, the marks of the menu, the tab buttons (`icons/*`, and any folder no type names) |

A single type may be written as a string, several as an array:

```json
"type": "buildings"
"type": ["buildings", "improvements"]
```

An unknown type makes the whole tileset invalid (the allowed values are the seven above).

**Only the declared types are replaced.** A set with `"type": ["buildings"]` changes the
building icons and leaves every other icon of the game untouched — a file it ships for
another type is ignored, which is what makes a full icon pack usable: ship everything,
declare what the set is actually drawn for.

### 3.4. One tileset per type

A type is drawn by **one** tileset only: two building sets would mix two drawing styles, so
the game never merges them.

**The player decides which set draws a type** — Settings → Appearance → *Icon sets*, one
dropdown per type (see §5). Until a type is chosen the game applies the **folder rule**: the
set whose folder name sorts **last** wins that type whole, and the game prints a warning
naming the rivals. The loser keeps its other types.

```
tilesets/
  a_rough/     type: ["buildings"]         <- draws buildings until the player picks otherwise
  b_smooth/    type: ["buildings", "misc"] <- wins buildings by the folder rule, owns misc
```

So a set works as soon as it is installed, and the settings are only needed when two sets
compete for one type.

---

## 4. How an icon is matched

An icon is addressed by its **bare name** — the file name without the extension:

```
tilesets/my_set/icons/bakery.svg   ->  replaces  res://icons/buildings/bakery.png
```

So the author is free to draw in any format the game can read: an SVG replaces a PNG, and a
PNG replaces an SVG. The name must match **exactly**, including case:
`hand_mill.svg` replaces `hand_mill.png`, and `handmill.svg` replaces nothing.

Two rules follow from this:

- **A file that names no icon replaces nothing** — unless it is named after an entity of the
  data, after a family of variants (§4.1), or is an extra numbered variant of a vanilla
  family (§4.2). The game prints the list of such files to the log — that is the fastest way
  to find a typo.
- **The set does not have to be complete.** An icon the set does not ship keeps its vanilla
  picture, so a set may re-draw three buildings and leave the rest of the game alone.

Where the vanilla names come from: `icons/<type>/<name>.png`. The list of the names of a
type is simply the contents of its folder — copy a name from there.

**A set draws the vanilla game.** Its names are resolved against `res://icons` and the
vanilla data only: what a mod adds or redraws never moves the meaning of a file of a set. A
mod brings its own data and its own pictures together (`mods/README.md` §4.5, §4.6), so it
needs no set for that, and a set never has to know which mods the player runs.

### 4.1. One picture for a whole entity

A terrain and a cover are drawn from **several pictures**, and the data lists them for the
entity itself:

```
data/covers.json:  { "id": "temperate_rainforest", "icons": [ "temperate_rainforest_1.png",
                                                              "temperate_rainforest_2.png",
                                                              "temperate_rainforest_3.png" ] }
```

The game picks the picture by the hex, so three pictures are three slightly different patches
of the same forest. An author who has **one** picture for the entity must not draw three
copies of it: name the file after the **id of the entity** —

```
tilesets/my_set/icons/temperate_rainforest.svg   ->   replaces all three pictures of the cover
```

— and every picture the data gives that entity is drawn with that one file.

The list of the pictures belongs to the data, not to a convention of the file names: today
every record names its pictures after its id, and that is a convenience of the art, not a
rule. The id is what the file name is matched against, so a set keeps working when the
pictures of an entity are renamed.

The rules of the expansion:

- A file whose bare name matches **no** icon is read as the id of an entity: it replaces every
  picture the data gives that entity, inside the types the set declares.
- A file that names an icon of its own replaces exactly that icon (the usual rule), even if an
  entity file of the same set would draw it as well. So a set may ship
  `temperate_rainforest.svg` for the whole cover and `temperate_rainforest_2.svg` for one
  picture it wants different.
- The **declared types are the namespace** of a name. One name may be both an icon of one type
  and an entity of another — the terrain `tundra_plain` and a picture `tundra_plain.png` that
  is, say, a good of some other type. A set for `terrains` reads the name as the entity; a set
  for the other type reads it as the icon. A set that declares both types means both with one
  name, which is what it asked for.
- An entity is expanded only inside the **declared types**: a `buildings` set cannot claim a
  cover, and a `terrains` set does not touch a building icon.
- A file named after a **family of names** works as well: `tundra_moss.svg` draws
  `tundra_moss_1..3` whether or not `tundra_moss` is an id, and `forest.svg` draws the three
  pictures of the forest above. The family is the name without a trailing `_<number>`.
- A name with no trailing number is no family: `bakery` stays the icon `bakery.png`, and a
  file `bakery` replaces exactly it.
- A family of one picture works the same way: `beach` draws `beach_1`.

What is an entity of several pictures: every record of the **vanilla** data with more than one
name in `icons` — every cover and every terrain of `data/covers.json` and
`data/terrains/*.json`. An entity of **one** picture needs no id: the file name is the name of
its picture, and the usual rule covers it. An entity a mod adds is not here: a mod draws it
with its own pictures (`mods/README.md` §4.5).

A set that draws only some pictures of an entity is not an error — one picture may be meant
to differ. The game does print a line about it, naming the entity and how many of its pictures
the set covers: that is the case where a cover comes out patched from two drawings.

```
TilesetManager: "my_set": reeds (1 of 3 pictures) — a file named after the entity draws all
of them at once.
```

### 4.2. More pictures than the data declares

A cover and a terrain are drawn from a **list** of pictures, and the vanilla data decides
how long it is:

```
data/covers.json:  { "id": "coral_reef", "icons": [ "coral_reef_1.png",
                                                    "coral_reef_2.png",
                                                    "coral_reef_3.png" ] }
```

A set may draw **more** of them. Add a numbered file whose family the vanilla game already
knows but whose number it never named:

```
tilesets/my_set/coral_reef_4.png     ->   a FOURTH picture of the same reef
tilesets/my_set/coral_reef_5.png
tilesets/my_set/coral_reef_6.png
```

The map then picks from all six pictures while this set is applied. Nothing in the data
changes, and no save ever stores `coral_reef_4.png`: choosing **Original icons** returns to
the three vanilla pictures, so a save made with the set on still opens in the vanilla game
— and a missing picture can never leave a black hex behind.

The rules:

- **The family must exist in the vanilla game.** `coral_reef_1..3.png` lie in
  `icons/terrain/`, so `coral_reef` is a family the game knows. A set of `marsh_1..3.png`
  has no vanilla `marsh` family (the vanilla art is `cold_marsh_*` / `warm_marsh_*`), so
  those files name nothing and the game reports them as ignored. To add a new **entity** a
  mod is needed (`mods/README.md` §4.5) — a set draws only what the vanilla game has.
- **The number must be unused.** A file named after an existing vanilla picture
  (`coral_reef_2.png`) is an ordinary exact replacement (§4), not an extra variant.
- The set must **declare the type of the family** (`terrains` for covers and terrains), and
  only the set that **wins** that type offers extras (§3.4).
- Extras are numbered pictures in any format: `coral_reef_4.svg` works as well. The family
  is the name without its trailing `_<number>` (§4.1).
- The picture is chosen **at draw time**, from a fixed seed made of the hex coordinates, so a
  redraw does not flicker and a save/load cycle does not reshuffle the map.
- Extras combine with a family file (§4.1): one `coral_reef.svg` redraws the three vanilla
  pictures and `coral_reef_4..6.png` add three more.
- **Terrain pictures are baked into the save** as `terrain_icon`. An extra is folded in only
  while the map is drawn, so the save keeps a vanilla name; world generation, tooltips and
  the UI never see an extra name. Covers are chosen at draw time anyway.

Under the hood: `TilesetManager.build_overrides()` puts the file into the replacement table
(so `IconRegistry.path_of()` can load it) and publishes its name in
`IconRegistry.extra_variants`; `IconRegistry.expand_variants()` folds those names into the
data's list. `map_renderer.gd` caches the grown lists in `load_icons()` and drops them when
`overrides_changed` fires — that is why switching a set repaints the map at once (§5).

`tilesets/iso` uses this today: `coral_reef_4..6`, `beach_2..3` and `oasis_3` give those
covers and the beach terrain more variety than the vanilla data declares.

### 4.3. What a set cannot do

- It cannot **add a new icon name or a new entity**: apart from the numbered extra variants
  of §4.2, a name exists only if the data refers to it — the vanilla data, or the data of a
  mod. An icon a mod adds is a target like any other, so a set may redraw it; but a file
  naming nothing the data uses replaces nothing.
- It cannot **group entities the data does not group**: two covers are two ids, so one picture
  for both needs two files (or two names). The data decides what a group is, the set only
  draws it.
- It cannot **remove** an icon.
- It cannot change the **proportion** the UI expects: the vanilla icons are square
  pictures of about 200–256 px, and the UI scales them to the size it needs. A set drawn
  at another size is scaled to fit and may come out blurred or off-centre — draw square,
  in the same spirit as the vanilla set.

---

## 5. Choosing a set in the game

**Settings → Appearance → *Icon sets*** holds one dropdown per type of icons, and the choice
is the player's, not the author's:

```
Resources           [ Placeholder Set  v]
Buildings           [ Original icons   v]
Technologies        [ Placeholder Set  v]
...
```

- The list of a type holds **Original icons** (the vanilla pictures) and every installed set
  that declares that type. A set that is drawn for another type is not offered.
- Every type keeps its **row** even when no installed set declares it: the rows are what
  tells the player which kinds of pictures a set can replace. With no sets at all the
  section is still shown, every row holding **Original icons** alone and greyed out, and
  the hint above them says the `tilesets` folder is empty.
- The choice is **per type**, so the buildings may come from one set and the coins of the
  interface from another.
- The choice is a player preference: it lives in `user://settings.cfg` next to the language,
  the font and the theme, **not** in a save, and it applies to every city.
- The change is applied **at once**: the map and the open windows repaint without a restart.
- A type that has never been touched follows the folder rule of §3.4, so a freshly installed
  set is already in use and the dropdown shows it as the current choice.
- A chosen set that is later deleted does not leave the type empty: the folder rule answers
  for it again until the player picks something else.

The rows are built from the manifests at startup, so a set that is added or removed needs a
restart of the game — the folders of `res://tilesets` are read once.

---

## 6. A tileset skeleton

```
tilesets/tile_industry/
  tileset.json
  icons/
    buildings/
      bakery.svg
      hand_mill.svg
    misc/
      coin_stack.svg
```

with

```json
{
  "name": "Tile Industry",
  "description": "Buildings in a tiled, mosaic style.",
  "author": "Your Name",
  "version": "0.1.0",
  "type": ["buildings", "misc"]
}
```

The `icons/` folder is a convention for humans. `buildings/` and `misc/` there are not
read by the game — the manifest decides what is replaced, and the file names decide which
icon each picture stands for.

---

## 7. A short checklist

- [ ] The tileset is a folder inside `tilesets/`, and its name does not start with `_`.
- [ ] The folder root holds a file named **exactly** `tileset.json`.
- [ ] `name`, `description` and `type` are filled in; `type` uses the seven known values.
- [ ] Every image is named after the vanilla icon it replaces, without the extension
      (`bakery.svg` for `icons/buildings/bakery.png`).
- [ ] One picture for an entity drawn from several pictures is named after the **id of the
      entity** (`temperate_rainforest.svg`), or after its family of names (`forest.svg`),
      see §4.1.
- [ ] Extra pictures of a family use an **unused number of a vanilla family**
      (`coral_reef_4.png`), see §4.2 — never a name the data has to be edited to declare.
- [ ] The images are imported (the project was opened in the editor after the files were
      added).
- [ ] No other tileset declares the same type — or this one is meant to win.
- [ ] The game log has no `TilesetManager` warnings about files that replace nothing.
