# Security Policy

## The game and the security of it

The City is a desktop game. It runs entirely on the computer of the player: it
does not connect to a server, it asks for no account, it collects no telemetry,
and it reads no data of the system except the files of the game and the saves of
the player.

There is no attack surface of a service here, and no personal data to protect.

## What to report where

**A bug or a crash** — an issue in the tracker, with the bug report template. The
saves of the player are the most valuable thing to attach: a save that leads to
the crash is worth more than any description of it.

**A problem with the safety of the data** — a save that corrupts other saves, a
mod that writes outside its own folder, anything that touches the files of the
system without being asked — do not open a public issue about it. Write to the
maintainer, [@Night-Pryanik](https://github.com/Night-Pryanik), in a private
message.

## The versions that are supported

The game is in active development, and the only supported version is the current
state of the `main` branch. The saves are not compatible between the versions of
the game: a change of the format of the data makes the old saves invalid, and no
migration is written for them.

## A security issue in a mod

A mod is a third-party work with its own author and its own license. Report a
problem with a mod to the author of the mod, and tell the maintainer of the game
if the mod belongs to the set that ships with it.
