# F5c handoff: happiness from a thought table

## Branch and commit

- Branch: `antonelmejor50-hub/f5c-happiness-from-a-thought`, on `origin/main` `5399153` (F5b,
  #54). Fetched again before committing: `origin/main` had not moved, so no rebase was needed. One
  commit, not pushed.
- **Schema number.** Save schema **v13** (`_v12_to_v13()`). The owner note said to take v14 only
  if F5a-b (v13) landed first. It has not landed (`origin/main` is still at v12), so **no
  renumbering**. If F5a-b merges first, this step becomes `_v13_to_v14`. The fixture, the
  `SCHEMA_VERSION` constant, the schema `const` and the `13:` arm move up by one.
- ADR: **066** (owner's allocation), `docs/decisions/066-happiness-from-thoughts.md`, status
  *proposed*, plus its row in `docs/decisions/README.md`.

## What changed

Design: BACKLOG F5c (closed with the owner on 2026-10-30), recorded in ADR 066.

Content:
- `game/content/thoughts.json` and `game/content/schemas/thoughts.schema.json`. The registry
  loads every `content/*.json` that has a schema, so the file is picked up automatically
  (`manifest.json` holds only a version and has no file list).
  - Fixed values: `base` 50, `min` 0, `max` 100.
  - State rules: `hungry` (food ≤ 25) and `slept_ground` (rest ≤ 25).
  - `meal_items`: `["meal"]`.
  - The table:

| id | weight | days | repeat | trigger |
|---|---|---|---|---|
| `ate_meal` | +10 | 1.5 | refresh | a need job eats an item in `meal_items` |
| `ate_raw` | 0 | 1 | refresh | a need job eats any other food (berries, raw `food`) |
| `hungry` | −12 | 0.1 | refresh | each needs tick while food ≤ 25 |
| `slept_ground` | −8 | 0.5 | refresh | each needs tick while rest ≤ 25 and no bed is reachable |
| `slept_bed` | +8 | 1.5 | refresh | a sleep need job completes |
| `harvested` | +2 | 1 | stack 3 | a `harvest` job completes (`job_kinds`) |
| `crafted` | +2 | 1 | stack 3 | a `craft_work` job completes (`job_kinds`) |
| `colonist_died` | −15 | 5 | stack 3 | a colony colonist dies (every other colony colonist) |

- `game/data/text/en.json`: the panel's happiness label and one label per thought id.

Simulation:
- New `game/scripts/core/actors/thoughts.gd` (`ActorThoughts`, 125 lines). It is a static module
  with no state and no clock: every function takes the tick.
  - `add` refreshes a thought, or stacks it up to `stack_limit` and then restarts the instance
    that expires first.
  - Other functions: `prune`, `happiness` (= base + active weights, clamped), `active`,
    `apply_state_tick` and `ids_for_job_kind`.
  - Colonist state: an optional `thoughts: [{id, until}]`, sorted by id then `until`. A thought
    is active while `tick < until`. The key is erased when the list empties.
  - No randomness and no new per-colonist loop.
  - Only colonists think: `applies(actor, registry)` is true when the actor's definition has the
    `worker` component, and the needs are read through `ActorTable.get_component()`. This keeps
    `test_actor_field_lint` clean: no bare `"colonist"` literal and no direct `actor.get("needs")`.

**Hooks** (the owner asked for a minimal list; `needs_system.gd` was not rewritten and
`world_state.gd` did not change, still 767 lines):
1. `needs_system.gd:182-188`, `decay_needs()`. Inside the existing colonist loop, one call to
   `ActorThoughts.apply_state_tick()`: prune, then `hungry` and `slept_ground`. The bed lookup
   (`_bed_reachable_once`, :445) runs at most once per tick and only when some colonist's rest
   is low.
2. `needs_system.gd:421`, `apply_need_effect()`. This adds `ate_meal`, `ate_raw` or `slept_bed`
   through `_need_thought` (:435). New helpers: `add_thought` (:424) and `add_job_thoughts`
   (:429).
3. `toil_bindings.gd:368`, `_complete_job()`. One line: `_needs_system.add_job_thoughts(colonist,
   kind)`.
4. `combat_system.gd:129-133`, `apply_actor_death()`. When a colony colonist dies, every other
   living colony colonist gets `colonist_died`.

Presentation:
- `view_snapshot.gd`: a `happiness` block, `{colonist id: {value, thoughts}}`, derived at the
  snapshot tick for detailed ids.
- `viewer/colonist_panel.gd`: `_happiness_lines` shows "Happiness N" and one line per active
  thought, with its weight and the days left.

Persistence (schema v13):
- `entity_codec.gd` encodes and decodes `thoughts` when present.
- `entity_validator.gd` checks the shape: a list of `{id: string, until: int ≥ 0}`.
- `state_codec.gd`: `SCHEMA_VERSION` 13.
- `save_migrations.gd`: `_v12_to_v13()` changes no data. The field is optional, and an absent
  field means no thoughts.
- `game-state.schema.json`: `const 13` and the optional `thoughts` on a colonist.
- New fixture `game/scripts/tests/fixtures/save_schema_v13_fixture.json`, written by
  `docs/orca/handoffs/F5c-write-save.gd`. It carries thoughts.
- `state_hash()` hashes the whole colonist dictionary (`EntityCodec._hash_colonists`), so
  thoughts are covered by the hash. The save/load and replay checks below verify this.

## Deviations from the design text (for the owner)

- **`slept_ground` has no sleep job of its own.** Sleep need jobs always target a bed, so
  "slept on the ground" never happens as a job. Instead it comes from the needs tick: the
  colonist is tired (rest ≤ 25) and no bed is reachable. Once a bed is reachable it stops.
  `test_thoughts` checks this.
- `meal_items` is a new content key that decides meal (+) versus raw (0).
- `crafted` counts only `craft_work`. `cook_work` is not counted; adding it is a one-word
  content change. The thought is given to the worker who completes the job.
- `colonist_died` goes to every colony colonist. Relations are a non-goal.
- The panel shows each thought's weight and the days it has left.

## Owner approvals pending (files outside the listed owned paths)

The owned paths allow "hooks where the triggering events are emitted", "persistence" and
"viewer colonist panel". These files sit in or next to those areas but are not named:
- hooks: `needs_system.gd`, `toil_bindings.gd`, `combat_system.gd`;
- viewer data: `view_snapshot.gd`;
- persistence: `entity_codec.gd`, `entity_validator.gd`, `state_codec.gd`, `save_migrations.gd`,
  `docs/architecture/contracts/game-state.schema.json`, `test_save_migration.gd`;
- text: `game/data/text/en.json`;
- ADR index: `docs/decisions/README.md`.

## Validation

Commands, from the worktree root (Godot path
`C:/dev/Going Deeper/tools/godot/Godot_v4.7.2-stable_win64_console.exe`):

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/run_tests.ps1
"$G" --headless --path game --script res://scripts/tests/test_thoughts.gd
python tools/check_core_budgets.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File game/scripts/tests/lint_content_literals.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/measure_core.ps1
```

Results at the branch head:
- Suite: `run_tests: all 137 test(s) PASS  [952s]`
- `test_thoughts.gd`: PASS.
- `check_core_budgets.py`: `OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file
  cap(s), 1 file and 3 function exception(s))`. No cap was raised.
- `lint_content_literals.ps1`: `PASS (no tile-id/work-ticks/move-ticks literal found outside the
  registry)`.
- `measure_core.ps1`: `core total: 23133 lines in 113 files`. Touched files (lines, code lines,
  functions, largest function and its length):

| file | lines | code | funcs | largest function |
|---|---|---|---|---|
| `world_state.gd` | 767 (unchanged) | 593 | 114 | `state_hash` 30 |
| `state_codec.gd` | 597 | 436 | 106 | `decode` 70 |
| `toil_bindings.gd` | 500 | 376 | 87 | `_init` 49 |
| `needs_system.gd` | 489 | 382 | 72 | `ensure_needs` 45 |

  The other touched core files (`thoughts.gd` 125, `combat_system.gd` 201, `view_snapshot.gd`
  264, `entity_codec.gd`, `entity_validator.gd` 320, `save_migrations.gd` 286) are far below
  800 lines.
- Tests compared with `main`:
  - `test_*.gd` files: 136 on main, 137 on the branch (`+test_thoughts.gd`);
  - `_check_` sites: 2130 on main, 2152 on the branch;
  - no test was deleted, skipped or loosened.

`test_thoughts.gd` drives everything through real ticks, commands and jobs, never through
direct calls:
1. A meal and a bed raise happiness to 68 within 2 days (> 60), with `ate_meal` and `slept_bed`.
2. Starving on the ground (no bed) drops happiness to 30 (< 40). After a bed is built,
   `slept_ground` stops.
3. Thoughts expire on schedule: `ate_meal` is still active at `until − 1` (happiness 60) and gone
   at `until` (50), and the key is erased.
4. The same seed gives the same `state_hash()`.
5. A save/load in the middle of a thought continues tick by tick with identical hashes.
6. A recorded session replays to identical hashes.
7. A harvest job gives `harvested` (happiness 52).
8. A craft job gives `crafted` to the crafter only.
9. A colonist's death in combat gives `colonist_died` to the witness (35) and nothing to the
   raider. The thought survives save/load.

## Limitations and next action

- Happiness is information only. Its consequences (depression) are F5d.
- The owner should review the deviations and pending approvals above, then sign off ADR 066.
