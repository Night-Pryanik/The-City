# Theme presets — how to read, edit or add an interface palette

This guide describes the JSON files of `theme/presets/`: what each field means, which
rules make a preset loadable and what a colour actually changes on screen.
The eight shipped presets are the working examples.

---

## 1. What a preset is

A preset is the whole palette of the interface — one JSON file with a name, a set of
named colours (the **tokens**) and two shape numbers. It is data, not code: a file
dropped into the folder becomes a choice in Settings without anything being registered
or rebuilt.

```
theme/
  tooltips_theme.tres        <- the project Theme resource: fonts and label variations
  presets/
    classic.json             <- one file = one palette
    mediterranean.json
    ...
```

The player chooses one in **Settings → the Interface tab → Interface theme**. The choice
applies at once, every window and the map overlay repaint, and it is remembered.

The chosen preset is a **player preference, not part of a save**: it lives in
`user://settings.cfg` (`[interface]` → `theme`) next to the language and the font, so
the same city can be played in any palette.

**Where the colours go:** `theme/tooltips_theme.tres` is the resource the engine hands to
every control, and ThemeManager writes the palette into that resource in place. Do not
edit colours there — the preset overwrites them at start. The `.tres` holds the fonts and
the label variations only.

---

## 2. How presets are found and checked

- The game reads **`res://theme/presets/*.json`** and nothing else. There is no
  `user://` folder for themes, so a preset has to be inside the game files.
- The file name itself means nothing; the `id` field is what the game and the setting
  use. A file with another extension is skipped.
- Every file is validated on read. **A file with any problem is skipped as a whole** —
  a missing token is never filled with a default colour, because a half-painted
  interface cannot be told apart from a bug. The reason is printed to the console as a
  `ThemeManager: <file> is ignored — …` warning, and the other presets keep working.
- Two files with the same `id`: the first (alphabetically by file name) wins, the second
  is warned about and ignored.
- Opening Settings scans the folder again, so a preset copied in while the game runs
  appears in the list without a restart.
- `classic` is the fallback: its palette is applied when nothing is chosen, and when the
  chosen id has disappeared. Delete the file and nothing can be applied at all — the
  standard controls keep the engine's own look, and only the styles a script builds fall
  back to `UiTheme.FALLBACK`, which is the same list of values as the file.

---

## 3. The skeleton

```json
{
    "id": "my_palette",
    "name_key": "Theme: My Palette",
    "chrome": { "panel_bg": "#1C1C1C", "...": "all 31 tokens" },
    "data":   { "price": "#FF8100", "...": "all 6 tokens" },
    "metrics": { "panel_radius": 4, "control_radius": 3 }
}
```

Plain, strict JSON: no comments (`//` is not stripped here, unlike in `data/*.json`), no
trailing commas, one object at the top level.

### The hard rules

| Rule | Requirement |
|------|-------------|
| `id` | non-empty; `a-z`, `0-9`, `_`, `-` only — lower case, no spaces |
| `name_key` | non-empty; a **translation key**, see §9 |
| `chrome` | an object holding **all 31** tokens of §5 |
| `data` | an object holding **all 6** tokens of §6 |
| `metrics` | an object with both keys of §7, numbers ≥ 0 |
| every colour | `#RRGGBB` or `#RRGGBBAA` — a `#`, hex digits (either case), no `rgb()`, no colour names, no 3-digit shorthand |

Extra keys are tolerated but never read, so an editor may keep notes as an unused field
(e.g. `"comment": "…"`) rather than in a real comment.

---

## 4. How to read the token tables

Each token below is listed with what it paints **now**. Most surfaces are not a single
token but a small formula over two or three of them: a plate is `panel_bg` behind a
`panel_border` frame, a button is `control_bg` behind a `control_border` frame. A handful
of tints are produced by lightening, darkening or lowering the alpha of a token — which
is why a colour already close to pure white or pure black leaves the interface nowhere to
go for its hover and pressed states.

The engine draws some marks as textures rather than as colours — the checkbox box and
its tick, the on/off switch, the slider knob. Those are rasterised from the palette when
a preset is applied, so they follow it too (their recipe is given in the tables).

---

## 5. `chrome` — the surface of the interface

### 5.1. Plates and windows

| Token | What it paints |
|-------|----------------|
| `panel_bg` | The fill of every plate: the panels of the city and of the map overlay, a standalone window, a popup menu, the base of a warning panel. **Its alpha is deliberate** — see §8. |
| `panel_border` | The frame around every plate: 1 px on a panel, 2 px on a floating window (that heavier line is what marks a window as a window). |
| `control_bg` | The resting fill of a button and of a dropdown; also the strip raised over a panel (a tab bar, a top bar), so a bar and the buttons on it read as one family; also the highlight of a hovered tab. |
| `control_hover` | A button under the cursor. |
| `control_pressed` | A button held down or toggled on. |
| `control_disabled` | A disabled button; also the fill of a read-only text field. |
| `control_border` | The frame of every control, and the box of a checkbox, and the knob of a slider. |
| `control_border_disabled` | The frame of a disabled control and of a read-only field. |

### 5.2. Text

| Token | What it paints |
|-------|----------------|
| `text` | The default caption of a label, a button, a field, a progress bar and a tooltip, the caret, and the caption of a hovered tab — only the selected tab has a token of its own. Also the tint of a hovered row in the trade lists (`text` at 10 % alpha). |
| `text_secondary` | A quieter value where the number still matters: a quantity, a distance, a stock line. Also the knob of a switch in the "off" position. |
| `text_muted` | Everything that is not actionable: a disabled caption, a field placeholder, a hint under a control, an explanatory note, an unselected tab, the `MutedLabel` variation. |
| `info` | A neutral highlight — a thing that is happening rather than a value: the bar of a queued or ongoing action on the map, the highlighted relations of the tech tree, a road and delivery hint, an unread marker, the informational rows of the data-problems window. |

### 5.3. The accent

| Token | What it paints |
|-------|----------------|
| `accent` | The marker of the interface: the resting state of an active toggle button (the city tab bar, the sections of foreign trade), the tick of a checked box, a pressed slider knob, the text selection (`accent` at 35 % alpha, so the selected text stays readable). The inactive buttons of such a group are the same accent dimmed and semi-transparent, so one token decides the whole bar. |
| `accent_hover` | The same active button **under the cursor or held**. The whole toggle group is painted by the accent family in every state, so the active tab keeps its mark while the pointer is over it; a value that barely differs from `accent` makes a hover invisible, one that flips the lightness makes the bar jump. |
| `accent_text` | The caption drawn **on** either accent surface — the resting and the hovered active button. Contrast against both is enforced. |

### 5.4. Fields

| Token | What it paints |
|-------|----------------|
| `field_bg` | The fill of an editable text field. |
| `field_border` | The frame of a text field that does not have the focus. |
| `focus_border` | The focus ring of a button, and the frame of a field that has the focus. The ring is drawn over the normal box and has no fill of its own, so it only needs to be distinguishable from `control_border`. |

### 5.5. Bars

| Token | What it paints |
|-------|----------------|
| `track` | The empty groove: the background of a progress bar, the slider track, the fill of an inset well, the "off" track of a switch. |
| `fill` | The filled part of a progress bar and of a slider; the "on" track of a switch; the tint of a selected row in the trade lists (`fill` at 35 % alpha). |

Progress bars of the map overlay are drawn by hand and take their colour from the `data`
tokens and `info` (a construction bar, a scout bar), not from these two.

### 5.6. Tabs, tooltips, scrollbars, rows

| Token | What it paints |
|-------|----------------|
| `tab_active_bg` | The plate under the selected tab of a tab bar. |
| `tab_active_text` | The caption of the selected tab. |
| `tooltip_bg` | The fill of a tooltip. |
| `tooltip_border` | The frame of a tooltip. |
| `scrollbar` | The grabber of a scrollbar (the part you drag). |
| `scrollbar_hover` | The grabber under the cursor or held. |
| `hairline` | The thinnest marks in the interface: a separator line, the rules of a category header, the column rules of the action panel, the era dividers of the tech tree. |
| `row_hover` | A row under the cursor: a menu item, a building card, a row of the town trade columns. |
| `row_selected` | The row the player has picked in the town trade columns — the one solid fill among the rows, so it has to stay clearly apart from `row_hover`. |

### 5.7. What sits over something else

| Token | What it paints |
|-------|----------------|
| `scrim` | The plate that darkens a screen behind a modal window — the journal and the save/load window stand on it. Its alpha is how far the background is pushed back — see §8. |
| `row_dim` | Not a paint: a **modulate multiplier** for a whole row, card or technology that is inert — unavailable, not yet reachable, switched off. See §8. |

---

## 6. `data` — the meaning of a value

These six are the colours of numbers and markers, not of chrome. They belong to the
palette because a data colour is tuned for the surface it lies on: an orange price that
reads on dark grey can vanish on bone white.

| Token | Meaning | Where |
|-------|---------|-------|
| `price` | A price of one unit, a tariff — the number that names a cost rather than a flow of money. Also the bar of an expansion proposal. | the Trade tab, the foreign trade column, the town window, the expansion overlay |
| `price_amount` | The sum inside a price row: the base price line, the amount at the end of a quality ladder row, the total of a decorated good. `price` paints the label, the coefficients and the formula around it. | the row tooltip of the "Resources" tab |
| `quality` | A quality level of goods. Also the scout-progress bar on the map. | the goods lists, the tooltips, the map |
| `income` | A gain: a surplus, a positive delta, a route that brings goods, a modifier that helps. Also the group headings of the data-problems report. | resources, trade, the action panel, the problems window |
| `expense` | A loss: a deficit, a cost, money the treasury pays out. Also the title line of the data-problems report, and the tint of a warning surface (`SurfaceProblem` = `panel_bg` pulled 18 % towards `expense`, framed in it). | the town window, the trade rows, a problem panel |
| `warning` | A shortfall or a caution that is not fatal: not enough stock, a yield an improvement will not reach. Also the money the treasury **receives** — the gold side of a deal, which pairs with the red `expense` side in both trade windows — and the referenced identifier in the problems report. | resource lists, the action panel, both trade columns |

---

## 7. `metrics` — the shape, not the colour

| Key | Applies to |
|-----|------------|
| `panel_radius` | The corner radius of every plate: panels, floating windows, the inset well, the veil over the map. A tooltip is the exception — its box is square in every preset. |
| `control_radius` | The corner radius of every control: buttons, dropdowns, text fields, the focus ring. |

Whole pixels, zero or more. `0` gives a hard, rectangular interface; above ~8 the plates
start to look soft and a thin frame reads as a pill. The two are independent on purpose —
a palette with square windows and rounded buttons is a legitimate look, and the reverse
is too.

---

## 8. Three values that are not plain colours

**`panel_bg` carries an alpha, and keeps it.** Windows float over the map, and the map
must stay readable behind them; `classic` uses `#1C1C1CF5` (~96 % opaque). A plate over
the world screen can also be a *veil* (`SurfaceVeil`), which is `panel_bg` with its alpha
forced to 0.72 — so the hue comes from the palette, the transparency from the design. A
fully opaque `panel_bg` still works, it just hides more of the map.

**`scrim`'s alpha is the only one the player judges directly.** It says how far the
background is pushed back behind a modal. Dark palettes use a near-black plate around
60 % (`#00000099`); a light palette needs a lighter one (`modern` uses `#2A262080`),
because the same black over bone white reads as a smudge rather than as a dim.

**`row_dim` is a multiplier, not a colour.** The interface paints nothing for an inert
row — it multiplies the row's own surface by this value, so only the three channels are
used and they must be **equal to each other**: any tint would dye every row it touches.
The useful range is narrow: below ~0.45 a dark palette crushes the row to black and the
text becomes unreadable; above ~0.9 the row no longer looks inert. A dark palette needs a
*lighter* neutral than a light one — multiplying a dark plate by 0.62 already takes it
close to black, while the same factor over a light plate only greys it. The dark presets
land around `#ABABAB`–`#B3B3B3`, the light ones at `#9E9E9E`, and `classic` — the palette
that reproduces the default look token for token — at `#9E9E9E`. Judge the value against
the surface actually dimmed, not against the plate of the window around it.

---

## 9. The name the player sees

`name_key` is a **translation key**, not a label: the item in the Settings dropdown is
`tr(name_key)`, so it follows the interface language. The convention of the shipped
presets is `"Theme: <Name>"` (the Russian catalog renders it as «Тема: …»).

The catalogs are rebuilt from the code, the scenes and `data/`, and a preset file is not
part of that scan, so a new name needs a hand-written record in `locale/ru.po` (msgid =
the exact `name_key` string, msgstr = the translation). Without the record the English
key is shown as is — which is a working, if untranslated, list.

---

## 10. Readability

`tests/test_theme_manager.gd` runs a contrast matrix over **every preset on disk**, on
the WCAG relative-luminance ratio. A preset below a threshold fails the test, so these
are requirements, not advice:

| Pair | Minimum |
|------|---------|
| `text` on `panel_bg`, on `tooltip_bg`, on `control_bg`, on `field_bg`, on `row_selected`, on `row_hover`, on `track` | 4.5 : 1 |
| `text_secondary` on `panel_bg` | 4.5 : 1 |
| `text_muted` on `panel_bg` | 3.0 : 1 |
| `tab_active_text` on `tab_active_bg` | 4.5 : 1 |
| `accent_text` on `accent` and on `accent_hover` | 4.5 : 1 |
| each `data` token and `info` on `panel_bg` | 3.0 : 1 |

4.5 : 1 is body text, 3.0 : 1 is a large mark or a coloured number. Keep `text_muted`
legible but clearly quieter than `text`: it has to read as secondary at a glance.

Run the test headless while tuning a palette:

```
godot --path . --headless --script res://tests/test_theme_manager.gd
```

---

## 11. What a preset does NOT change

- **The map.** Terrain, water and rivers (`map_renderer`, `world_preview`,
  `river_manager`) are their own colours and no theme restyles them — the interface sits
  over a world that keeps its palette.
- **The colours that carry game meaning from the data side**: the borders of the towns,
  the goods markers and the terrain tints come from data, not from the theme.
- **Fonts** (the family choice lives in Settings and is written into the same Theme
  resource by FontManager) and **artwork** — icons, resource drawings, the title screen.
- **Layout.** Sizes, margins and the minimum size of every control stay the engine's, so
  a screen laid out for one palette does not shift in another.
- A few marks are drawn in `Color.WHITE` and dimmed by `modulate`, which reads correctly
  on a dark palette and on the light ones only because those keep their surfaces in the
  ranges the idiom expects. When in doubt, keep a plate darker than the text on it.

---

## 12. A short checklist

- [ ] The file is in `theme/presets/` and ends with `.json`.
- [ ] `id` — lower case `a-z`, `0-9`, `_`, `-`, and not used by another file.
- [ ] `name_key` — `"Theme: <Name>"`, and a matching record in `locale/ru.po`.
- [ ] Plain JSON: no comments, no trailing commas, all three objects (`chrome`, `data`,
      `metrics`) present.
- [ ] All 31 `chrome` tokens, all 6 `data` tokens, both metrics.
- [ ] Every colour is `#RRGGBB` or `#RRGGBBAA`.
- [ ] `row_dim` is a neutral grey (`R = G = B`) in the 0.45–0.85 range.
- [ ] `scrim` keeps a real alpha (~0.5 and above) — a translucent plate does not read as
      a modal.
- [ ] The contrast pairs of §10 hold, checked by the test rather than by eye.
- [ ] The console shows no `ThemeManager: … is ignored` warning, the preset appears in
      Settings → Interface, and switching to it repaints the city, the tabs and a modal.
