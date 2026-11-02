# Tilesets — how to re-draw the icons of The City

This guide describes how a tileset works and how to assemble one. A ready-made specimen
lives next to this file:

- `_example` — a set that declares **every** type and carries a few icons of each, so the
  whole mechanism can be seen at once. It is switched **off** by its folder name (see §2.1)
  — rename the folder to `example` and restart the game to see it work.

A tileset **replaces icons, it does not add them**: the game keeps its own icon names and
the data (`data/*.json`) keeps pointing at the vanilla file names. A tileset only decides
which *picture* is shown for a name.

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

- **A file that names no icon replaces nothing.** The game prints the list of such files to
  the log — that is the fastest way to find a typo.
- **The set does not have to be complete.** An icon the set does not ship keeps its vanilla
  picture, so a set may re-draw three buildings and leave the rest of the game alone.

Where the vanilla names come from: `icons/<type>/<name>.png`. The list of the names of a
type is simply the contents of its folder — copy a name from there. **A mod may add names
of its own** (`<mod folder>/icons`, see `mods/README.md` §4.5): they are indexed next to
the vanilla ones, and a set of the same type re-draws them as well.

### 4.1. What a set cannot do

- It cannot **add** a new icon name: a name exists only if the data refers to it — the
  vanilla data, or the data of a mod. An icon a mod adds is a target like any other, so a
  set may redraw it; but a file naming nothing the data uses replaces nothing.
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
- [ ] The images are imported (the project was opened in the editor after the files were
      added).
- [ ] No other tileset declares the same type — or this one is meant to win.
- [ ] The game log has no `TilesetManager` warnings about files that replace nothing.
