# Contributing to The City

The City is a game in active development. Everything is welcome: a bug report, a
fix, a new resource in the economy, a translation, a mod.

## The short version

1. Open an issue first for anything bigger than a typo fix — it saves everybody the
   work of a pull request that goes in the wrong direction.
2. Make one change per pull request, and describe what it changes and why.
3. Run the tests before you push.

## Running the game

The project is written in GDScript and needs **Godot 4.7**. Open the project folder
in Godot and press F5.

The project is data-driven: the economy — resources, recipes, buildings,
technologies, terrains — is described in `data/*.json`, and the code reads it. A
new good usually means a new record in the JSON and no code at all.

## Running the tests

The tests are headless scripts in `tests/`. The runner starts Godot itself and
runs them in parallel:

```
python tools/run_tests.py            # the fast suite
python tools/run_tests.py --all      # every test
python tools/run_tests.py --only road,sea   # only the tests whose name matches
```

The runner looks for Godot in the usual places and in `PATH`; if it is somewhere
else, point it there with the `GODOT` environment variable.

A single test can also be run by hand:

```
godot --headless --path . --script res://tests/test_road_building.gd
```

After you add a **new** script with a `class_name`, the cache of the global
classes has to be rebuilt, otherwise the headless runs fail with "Identifier not
declared in the current scope":

```
godot --headless --path . --import
```

The JSON of the game data can be checked on its own:

```
python tools/validate_json.py
```

## The rules of the code

* Indentation is a tab, as in the rest of the project.
* The comments are in English, and they explain the current state of the system
  and the reason behind a decision — not the history of how it was written. A
  comment that only repeats the code is not needed.
* The game data is checked by the validator: a resource that is referenced by a
  recipe must exist, and the identifiers must be unique. The check runs on every
  start of the game and reports the broken references in a window.
* **There is no save migration.** The game does not keep the saves of older
  versions, and a change of the data format simply invalidates the old saves. Do
  not write code that converts the old saves.

The full description of the project and of its systems is in
[`design_doc.md`](../design_doc.md).

The rules of the community are in [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Translations

English is the source language: the English text of a string is its key, and it
lives in the code and in the JSON of the data. The Russian catalog is
[`locale/ru.po`](../locale/ru.po), and the compiled catalog the game loads is
[`locale/ru.mo`](../locale/ru.mo).

A new string therefore needs two things: the English text in the code, and the
Russian translation in `locale/ru.po`.

## Mods

A mod is a separate work with its own license — the license of a mod is the
license of its author, and it is not bound by the license of the game. The
mechanism of the mods is described in [`mods/README.md`](../mods/README.md).

## The license of a contribution

The code of the game is published under CC BY-NC-SA 4.0, the artwork and the game
data under CC BY 4.0. By contributing you agree that your contribution is
published under the same license as the part it belongs to.

The names of the authors are listed in [`AUTHORS`](../AUTHORS).
