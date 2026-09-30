# Deepholm — Godot project

> **In short:** This folder holds the playable game. It explains how to start it, where each part of the code lives, and how to run the automated tests.

This directory is the Godot 4 project. The authoritative simulation is written
from its own contracts (`docs/architecture/`) and never depends on scenes,
rendering or wall-clock time.

## Run

```text
godot --headless --path game --import      # once, builds the class cache
godot --path game                          # play (or open project.godot in the editor)
godot --headless --path game --quit-after 1   # headless boot check
```

The boot scene (`scenes/boot.tscn` + `scripts/boot.gd`) starts a paused, seeded
New Game with the map viewer, order toolbar, colonist panel and work-priority
table. `WorldState` receives an explicit seed and advances only through
`tick()` and `apply(command)`.

## Layout

- `scripts/core/` — the deterministic simulation (world state, job engine,
  scheduling, routing, regions/rooms, combat, incidents, persistence, world
  generation). No scene, node or rendering dependencies.
- `scripts/viewer/` — presentation: map rendering, colonist sprites, panels,
  tick pacing. Talks to the core only through getters, `apply()` and `tick()`.
- `scripts/tools/` — resource builders (tile set, colonist frames) and a
  screenshot tool.
- `scripts/tests/` — headless test scripts, save fixtures and lints.
- `content/` + `content/schemas/` — gameplay rules as JSON, with schemas.
- `data/` — viewer text table, tile set and sprite frames, plus example
  records and schemas.
- `assets/generated/` — original placeholder pixel art produced by
  `tools/generate_placeholder_art.py`; see `assets/CREDITS.md`.

## Tests

No external test framework is required:

```text
godot --headless --path game --script res://scripts/tests/test_world_state_determinism.gd
tools/run_tests.sh [path-to-godot]                             # whole suite, from the repo root
pwsh game/scripts/tests/run_all_tests.ps1 -GodotPath <godot>   # whole suite, PowerShell
```

`test_world_state_determinism.gd` replays an identical command/tick sequence
against two seeded `WorldState` instances and asserts equal `state_hash()` and
event logs, plus map/spawn invariants, rejection categories, tick advancement,
event ordering and the read-only snapshot boundary (see
`scripts/core/commands/README.md` for the command contract).
