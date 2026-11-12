# Comment Guidelines for AI Agents

## No Save Migration

The game does not maintain backward compatibility with old save files. When adding new mechanics or modifying existing ones, **do not write save migration code**. When a saved data format changes, old saves are simply considered invalid.

## Purpose

Comments in this project should explain the **current state of the project**, not its development history.

The codebase is actively evolving. Do not preserve historical explanations in source files merely because the current implementation replaced an older implementation.

The goal is to keep comments concise, useful, and focused on information that cannot be easily inferred from the current code or data.

## 1. Describe the current behavior

Comments should describe or explain the system as it exists **now**.

Good:

> Town economies are virtual. Resource quantities are not simulated; resource presence is sufficient for production-closure analysis.

Bad:

> This used to simulate resource quantities, but the system was later changed to use virtual resource presence.

The second comment describes development history rather than the current design.

## 2. Do not document obsolete implementations

Do not add comments describing:

- how the system worked before;
- what implementation was replaced;
- what a previous algorithm did;
- why an old approach was abandoned;
- previous data structures;
- previous production or consumption models;
- previous UI behavior;
- previous bugs that have already been fixed;
- migration steps that are no longer relevant.

Do not leave such comments behind when modifying existing code.

Git history is the appropriate place for implementation history.

## 3. Do not narrate obvious code

Comments should not simply translate code into English.

Avoid:

> Increment the counter by one.

> Check whether the resource exists.

> Loop through all recipes.

> Return the result.

If the code is already self-explanatory, no comment is needed.

Prefer comments that explain **why** something is done when the reason is not obvious from the implementation.

## 4. Explain non-obvious design decisions

A comment is valuable when it preserves knowledge that would otherwise be difficult to recover from the code.

Good reasons to comment include:

- an important game-design rule;
- an architectural constraint;
- an intentional exception to a general rule;
- a non-obvious invariant;
- a subtle dependency between systems;
- a deliberate simplification;
- a performance-related constraint;
- behavior that looks unusual but is intentional.

Example:

> Ingredient amounts are intentionally ignored here. Town economies are virtual, so this calculation determines whether a production dependency exists, not whether the town has sufficient quantities.

This is useful because the reason cannot necessarily be inferred from the surrounding code.

## 5. Prefer "why" over "what"

When a comment is necessary, prefer explaining **why** the code behaves this way rather than describing **what** the code literally does.

Bad:

> Check whether at least one ingredient is available.

Better:

> Recipes with at least one local ingredient may become import candidates. A recipe with no local foothold is not considered here.

## 6. Do not preserve comments just because they are old

When editing an existing file, review nearby comments.

If a comment describes obsolete behavior, remove or rewrite it.

Do not assume that an existing comment is correct merely because it was written by a previous developer or agent.

The current code and current design decisions are authoritative.

## 7. Do not use comments as a development diary

Do not write comments such as:

> Changed this after testing.

> This was fixed in September 2026.

> Originally this was implemented differently.

> This is a temporary solution from the previous version.

> TODO: restore the old behavior.

Development history, experiments, playtesting results, and discarded approaches belong in the development diary, issue tracker, commit history, or other project-history documentation.

## 8. Do not mention commits unless technically necessary

Normally, comments should not contain commit hashes, dates, branch names, or references to previous commits.

A commit reference is appropriate only when it provides genuinely useful technical context that cannot be expressed more clearly in the comment itself.

## 9. Keep comments stable

A good comment should remain correct even if the surrounding implementation is refactored.

Avoid comments that depend on specific function names, variable names, line numbers, or implementation details unless those details are themselves the important point.

Prefer documenting the invariant or design rule.

## 10. Comments in data files follow the same rules

These rules apply not only to source code, but also to:

- JSON and other data files;
- configuration files;
- technology data;
- resource data;
- building data;
- recipe data;
- test data;
- scripts and tooling.

Data comments should explain unusual design decisions or constraints, not document the history of the data.

## 11. Comments must use English

English is the primary language of the project's source code and development documentation.

Comments added or modified by an agent must be written in English.

Do not mix Russian and English in comments unless a specific quoted game/UI string requires it.

## 12. Before adding a comment, ask three questions

Before writing a comment, ask:

1. **Is this information already obvious from the code or data?**
2. **Does this explain the current system rather than its history?**
3. **Would this information help a future developer or agent make a correct change?**

If the answer to the first question is "yes", the comment is probably unnecessary.

If the answer to the second question is "no", the comment probably belongs in project history instead.

If the answer to the third question is "no", consider removing it.

## 13. When changing behavior, update comments instead of preserving history

If an implementation changes, comments describing the old implementation should be removed or rewritten to describe the new implementation.

Do not write a historical comparison merely to explain the change.

Bad:

> Previously production was simulated in batches. It now uses continuous flow.

Better:

> Production is represented as a continuous flow rather than discrete batches.

Even better, if the code already makes this obvious:

> [No comment needed.]

## 14. When in doubt, prefer no comment

Comments are not documentation by default.

A concise, readable implementation with no comment is preferable to an implementation surrounded by commentary that merely restates its behavior.

The purpose of comments is to preserve **non-obvious knowledge**, not to increase the amount of text in the repository.

## Local-only Files and the Working-Tree `.gitignore`

`.gitignore` and `project.godot` carry the `skip-worktree` bit, so git ignores local edits to them. The working-tree `.gitignore` therefore holds ignore rules that are not part of the repository, while the committed version stays minimal. A rule added to the working tree never shows up in `git status` and is never pushed.

Files ignored only by the working-tree `.gitignore` are local by design and must not be committed: `docs.md`, `developer_diary.md`, `TODO.md`, the scratch files under `tools/`, and the assistant's memory folder.

Font files are local as well. The `*.ttf` rule keeps every font out of the index except `fonts/InterVariable.ttf`, which was added before the rule and is tracked on purpose — it is the font the game ships with (SIL OFL). Any other font in `fonts/` belongs to the machine it sits on and must not reach a distributed build unless its own license allows redistribution.

`docs.md` is the detailed design document, and source comments reference it by section name. It stays on disk and remains valid for local work, although the file is absent from the repository — the references are not a reason to re-add it.

To keep a file local, list it in the working-tree `.gitignore` and drop it from the index with `git rm --cached <file>`, which leaves the file itself untouched on disk.

## The Example Mod and a New Recipe Chain

`mods/blacklist_example` is a shipped mod that removes the winemaker's house, its recipes and the wines they produce. A new recipe in one of the removed buildings breaks it: the mod leaves the recipe behind, the recipe keeps a reference to a building that no longer exists, and `tests/test_mods.gd` fails with "the example adds no problems to the data".

A new chain therefore has to be removed whole: the recipe, the product it makes, and every goods group that lists the product. The group is rewritten by the mod itself (`mods/blacklist_example/data/product_groups.json`), and the list it writes must hold exactly the members that survive — a member left out of the list is not an error, but a member of a removed product in the list is.

## Text and the Texture Filter of a Canvas Item

The atlas of a font is a texture, and a `CanvasItem` samples it with its own `texture_filter`. A text drawn with `draw_string` on an item whose filter is `TEXTURE_FILTER_NEAREST` comes out streaked and stretched as soon as the window scales the interface by a fraction (`window/stretch/mode = "canvas_items"` with a base smaller than the window), because the glyph bitmap is then magnified by a nearest sampling. The letters of a small size suffer first.

Keep hand-drawn text on a layer of its own with the default filter, and reserve the nearest filter for the picture that needs the hard edges. `scripts/world_preview.gd` does this: the map texture is drawn on the nearest filter, the caption and the legend on a layer of their own.

Check it in the real window, not in a screenshot of the viewport: a viewport rendered at its own size shows no scaling and therefore no artefact at all. `DisplayServer.screen_get_image()` captures what the player sees.

---

## The City: Historical, Geographical, and Cultural Context

### The Fundamental Principle

**Europe is not the center of the world in The City.**

European history is not the foundation of the game's chronology. European geography does not define the structure of the game world, and European historical events and achievements are not a universal measure of humanity's technological or cultural development.

The City is not a simulation of European civilization gradually discovering the rest of the world. It is an economic strategy game depicting the development of humanity as a whole in an alternate historical and geographical context.

When designing mechanics, resources, technologies, production chains, names, descriptions, or any other aspect of the game, always keep this principle in mind.

### 1. Alternate Geography and History

The geography of The City is deliberately alternate. On a single game map, it is perfectly normal to find:

- South American llamas;
- Chinese ramie;
- tropical coconut palms.

These are not map-generation errors, nor an attempt to recreate real-world biogeographical boundaries. Plants, animals, and natural resources from completely different continents and regions can coexist within the same game world.

History works in much the same way: the game does not reproduce the real-world sequence of historical events, the spread of cultures, or interactions between civilizations. Real historical processes can serve as sources of inspiration, but they do not impose mandatory constraints on the game world.

**Do not attempt to reconstruct the real Earth or its historical geography through the game's mechanics.** The City has no real-world historical or geographical regions. It is not Europe, the Mediterranean, the Middle East, or any other specific geographical region.

### 2. Game Eras Are Approximate Labels for Technological Development

The names of the game's eras were chosen primarily for familiarity and recognizability. Their purpose is to make progression easier for players to understand, not to accurately reproduce historical periodization.

The boundaries, duration, and content of game eras correspond only approximately to real historical eras. The game's Ancient Era, for example, is not required to correspond to European Antiquity, nor is its Medieval Era required to correspond to the European Middle Ages.

Other parts of the world had their own historical periods, cultural developments, and chronologies, which frequently had little or nothing in common with European periodization. European historical eras therefore cannot serve as a universal calendar for humanity.

**Game eras represent the approximate level of technological development of humanity as a whole.** They are an abstract progression framework required by the game.

When determining the era in which a technology, product, or production process becomes available, consider whether humanity could realistically have developed or used it at that general technological level, regardless of where in the world it happened.

### 3. Do Not Confuse Arrival in Europe with Arrival in the World

This is one of the most common mistakes.

The fact that a particular product, plant, technology, or custom appeared in Europe during a certain era does not mean that it originated or first came into use by humanity at that time.

It is important to distinguish between:

- the origin of a phenomenon or technology;
- its earliest known use;
- its spread to other regions;
- its introduction to Europe;
- the beginning of mass production or widespread consumption.

These are different historical events and may be separated by centuries or even millennia.

This distinction is particularly important for products and plants originating in the Americas, Asia, Africa, and Oceania. Their use by Indigenous peoples and other populations often long predates their introduction to Europeans.

Do not use statements such as "this resource appeared in the 16th century" when what you actually mean is that it appeared in Europe during that period.

### 4. Examples of Incorrect Reasoning

#### Coffee

**Incorrect reasoning:**

> "Coffee began to be consumed around the 10th century, so allowing it to be cultivated and consumed in the game's Ancient Era would be historically inaccurate."

The existence of documented evidence of coffee consumption during a particular period does not prove that consuming it was impossible before then.

Drying, roasting, and grinding coffee beans do not require technologies fundamentally inaccessible to people of earlier eras. There is no reason to automatically postpone coffee's availability until a specific historical date simply because that is when its documented history of use or spread becomes prominent.

#### Tobacco

**Incorrect reasoning:**

> "Tobacco appeared in Europe in the 16th century, so allowing it to be cultivated and consumed in the game's Ancient Era would be historically inaccurate."

Tobacco originated in the Americas and was used by Indigenous peoples long before contact with Europeans. Its arrival in Europe during the 16th century is part of the history of its introduction to a new region, not the history of tobacco's origin or the beginning of its use by humanity.

Consequently, tobacco can absolutely be available in game eras corresponding to the period when Indigenous peoples of the Americas were already using it.

#### The General Rule

If a plant, product, or technology was already being used by humanity — or could reasonably have been used given the technological capabilities of the time — it may be available in the corresponding game era, regardless of where in the world that use took place.

Do not artificially delay its appearance until the point when Europe became familiar with it.

### 5. Technological Feasibility and Historical Accuracy

Do not confuse a historical fact with a technological requirement.

If a product first became widely used during a particular century, that does not necessarily mean its production required technologies invented during that same period.

Ask the right questions:

- What actual operations are required to produce this item?
- What tools, materials, and knowledge are necessary?
- Were these operations accessible to people in earlier eras?
- Did comparable production methods exist in other parts of the world?
- Are we mistaking the later spread of a technology for the date of its invention?

For example, if producing a particular item only requires drying, grinding, roasting, or mixing readily available materials, do not automatically assign it to a later era solely because its best-known historical records date from that period.

Of course, this does not mean that every product can be unconditionally moved into the earliest game era. If it genuinely requires sophisticated tools, specialized materials, advanced chemistry, or specific production knowledge, those technological constraints should be respected.

**Availability should be determined by the actual technological complexity of production, not by the date something appeared in Europe.**

### 6. Alternate Toponymy and Cultural Blending

The City does not require names to conform to specific real-world historical languages, cultures, or regions.

Names of cities, regions, products, and other objects may combine elements from different linguistic and cultural traditions.

For example, "Qasr-al-Midgard" is a perfectly acceptable combination of Middle Eastern and Norse-inspired toponymy.

There is no need to correct such combinations merely to make them conform to real-world historical geography. Alternate toponymy is part of the game's fictional setting.

Names should nevertheless remain reasonably pronounceable, meaningful, and internally consistent with their immediate context. The freedom to blend cultural styles does not mean that names should be random collections of words.

### 7. Working with Historical Sources

Real history remains an important source of inspiration and a means of checking plausibility. However, it must be approached carefully.

When researching the origins of a product, plant, animal, technology, or custom:

1. Do not limit yourself to European historical sources and dates.
2. Consider the object's origin and its history of use in its original region.
3. Distinguish between the earliest archaeological or written evidence and the actual beginning of a practice.
4. Remember that the absence of known evidence does not prove that a practice did not exist.
5. Do not attribute inventions, discoveries, or achievements of other peoples to Europe merely because they were later popularized or documented there.
6. Do not present the history of one civilization as the obligatory developmental sequence for all others.

When historical evidence is disputed or insufficient, acknowledge the uncertainty rather than confidently assigning an arbitrary date.

### 8. A Practical Decision-Making Rule

When adding a resource, technology, production chain, or any other historically informed element, ask yourself:

**"Was this accessible to humanity at approximately this level of technological development in at least one part of the real world?"**

If the answer is yes, do not rule it out of an earlier game era simply because it appeared much later in Europe.

If the answer is no, determine which technological prerequisites were genuinely missing and whether assigning the element to a later game era is justified.

Always remember that game eras are an approximate scale of overall technological development, not a calendar of European history.

### Key Takeaways

- Europe is one part of the world among many, not its historical or geographical center.
- European periodization is not a universal chronology of humanity.
- The date a product appeared in Europe is not the same as the date it originated or first came into use.
- The histories of other peoples and regions have their own value and must not be treated as appendices to European history.
- The geography, history, and toponymy of The City are deliberately alternate.
- Historical plausibility should be determined by origins, technological prerequisites, and actual production capabilities, not by familiar European dates.

**Do not turn The City into a game about Europe gradually discovering the rest of the world. That is not the game we are making.**