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