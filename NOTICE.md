# Third-party notices

**What this file is.** The City uses a few things that other people made — a font
and the game engine. Each of them comes with its own conditions, and this file
names them. It is a list and nothing more: it does not limit what you may do with
the game itself.

## The licenses of this project

| Part | License | File |
|---|---|---|
| Code — scripts, scenes, tests, tools | CC BY-NC-SA 4.0 | [`LICENSE`](LICENSE) |
| Artwork, game data, texts | CC BY 4.0 | [`LICENSE-ASSETS.md`](LICENSE-ASSETS.md) |

In plain words: the code may be read, changed and shared by anyone, may not be
used to make money, and a changed version must stay under the same license. The
artwork and the data may be reused by anyone, including commercially, as long as
The City is credited.

## Fonts

### Inter

- Files: `fonts/InterVariable.ttf`, `fonts/inter_bold.tres`, `fonts/inter_medium.tres`
- License: SIL Open Font License 1.1
- Copyright: Copyright 2020 The Inter Project Authors (https://github.com/rsms/inter)
- License text: `fonts/OFL.txt`

What it means in practice: the font may be bundled with the game and handed to
players. The only condition is that the copyright notice and the license travel
with it — which is what this file does.

The font family is picked from whatever is found in `fonts/`, and the OFL permits the
font to be bundled and redistributed with the game.

This is the only font that travels with the repository. The `*.ttf` rule of the
working-tree `.gitignore` keeps every other font out of the index, so a font that
sits in `fonts/` on a developer machine stays there — and must not reach a
distributed build unless its own license allows redistribution.

## Engine

### Godot Engine

- The game is built with the Godot Engine, which is distributed under the MIT License.
  The engine is not part of this repository; the exported game contains the engine's
  own license text.

## Artwork

The artwork in `icons/`, `tilesets/` and `icon.svg` was produced with the help of an
image-generation model. The author claims the copyright over the result and licenses
it under CC BY 4.0 (see [`LICENSE-ASSETS.md`](LICENSE-ASSETS.md)).

## Mods

Mods are third-party content. They are **not** covered by the licenses of this
project: a mod carries its own license, stated by its author. The two mods that ship
with the game (`mods/test_mod` and `mods/blacklist_example`) are part of this project
and are covered by the licenses above.

## When you distribute the game

Both licenses require the credit and the license notice to travel with the copy that
leaves your hands. A build that you give away must therefore carry:

- the license of the code and the license of the artwork and the data;
- the credit — "The City by Anton Burmistrov";
- this file with the list of third-party components.

Two ways to do that: ship `LICENSE`, `LICENSE-ASSETS.md` and `NOTICE.md` next to the
game file, or show the same information in a screen inside the game ("About" or
"Licenses"). Files added to the export list of the Godot project travel with the
build.
