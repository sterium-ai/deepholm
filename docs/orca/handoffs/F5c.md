# F5c handoff: happiness from a thought table

## Branch and commit

- Branch: `antonelmejor50-hub/f5c-happiness-from-a-thought`, rebased on `origin/main`
  `f51498d` (the owner's round-2 decisions), on top of `f55e9b0` (the F5c scope approval), L3
  `bb3ff32` (#55, no schema bump) and F5b `5399153` (#54). Five commits (the feature, the
  review round-1 fixes, the handoff figures after the rebase, the review round-2 fixes, the
  owner round-2 change, plus a sixth with the review round-3 handoff wording), not pushed.
- **Schema number.** Save schema **v13** (`_v12_to_v13()`). The owner note said to take v14 only
  if F5a-b (v13) landed first. F5a-b (tool hauling, its own v13 bump) is a different task from
  F5b (#54, cooking, merged, v12). F5a-b has not landed: `origin/main` (`f51498d`) is still at
  `SCHEMA_VERSION` 12 after L3. So there is **no renumbering**. If F5a-b merges first, this step becomes `_v13_to_v14`. The fixture, the
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
- New `game/scripts/core/actors/thoughts.gd` (`ActorThoughts`, 126 lines). It is a static module
  with no state and no clock: every function takes the tick.
  - `add` refreshes a thought, or stacks it up to `stack_limit` and then restarts the instance
    that expires first.
  - Other functions: `prune`, `happiness` (= base + active weights, clamped), `active`,
    `apply_state_tick` and `ids_for_job_kind`.
  - Colonist state: an optional `thoughts: [{id, until}]`, sorted by id then `until`. A thought
    is active while `tick < until`. The key is erased when the list empties.
  - No randomness and no new per-colonist loop: every per-colonist step runs inside the
    existing colonist loop of `NeedsSystem.decay_needs()` (a combat death is recorded as a
    count and applied there, see hook 4).
  - Only colonists think: `applies(actor, registry)` is true when the actor's definition has the
    `worker` component, and the needs are read through `ActorTable.get_component()`. This keeps
    `test_actor_field_lint` clean: no bare `"colonist"` literal and no direct `actor.get("needs")`.

**Hooks** (the owner asked for a minimal list; `needs_system.gd` was not rewritten and
`world_state.gd` kept its line count, still 767 lines; its one change is the `state_hash()` line that
also calls `_needs_system.hash_into(snapshot)`, hook 4):
1. `needs_system.gd:188-208`, `decay_needs()`. Inside the existing colonist loop, one call to
   `ActorThoughts.apply_state_tick()` (:203): prune, then `hungry` and `slept_ground`. The bed
   check is **per colonist**: `_bed_reachable_once()` (:467) returns a `Callable(colonist)` that
   is true when a bed is reachable from that colonist's own region. The set of regions that
   reach a bed is built at most once per tick, and only when some colonist's rest is low.
2. `needs_system.gd:417`, `apply_need_effect()`. This adds `ate_meal`, `ate_raw` or `slept_bed`
   through `_need_thought` (:456). New helpers: `add_thought` (:444) and `add_job_thoughts`
   (:450).
3. `toil_bindings.gd:368`, `_complete_job()`. One line: `_needs_system.add_job_thoughts(colonist,
   kind)`.
4. `combat_system.gd:129-131`, `apply_actor_death()`. When a colony colonist dies, one call to
   `_needs_system.record_colony_death()` (`needs_system.gd:129`) increments
   `pending_colony_deaths`. There is no loop in combat. The next tick's `decay_needs()` colonist
   loop (:210-213) gives `colonist_died` once per pending death to each colony colonist, then
   clears the count. Decay runs before combat in a tick, so the survivors think it one tick
   after the death. That is 1 tick out of a 5-day thought. The count is in `state_hash()`:
   `NeedsSystem.hash_into()` adds `pending_colony_deaths` when it is above 0, called from the
   existing `_crafting.hash_into(snapshot)` line, so `world_state.gd` stays at 767 lines.

Presentation:
- `view_snapshot.gd`: a `happiness` block, `{colonist id: {value, thoughts}}`, derived at the
  snapshot tick for detailed ids.
- `viewer/colonist_panel.gd`: `_happiness_lines` (:502) shows "Happiness: N/100" and one line
  per active thought, with its name and weight. The snapshot carries each thought's
  `remaining` ticks, but the panel does not show it.

Persistence (schema v13):
- `entity_codec.gd` encodes and decodes `thoughts` when present.
- `entity_validator.gd` checks the shape: a list of `{id: string, until: int ≥ 0}`.
- `state_codec.gd`: `SCHEMA_VERSION` 13.
- `save_migrations.gd`: `_v12_to_v13()` changes no data. The field is optional, and an absent
  field means no thoughts.
- `game-state.schema.json`: `const 13`, the optional `thoughts` on a colonist, and the optional
  top-level `pendingColonyDeaths` (integer ≥ 1). It is present only when a colony colonist died
  on the tick being saved; that is the window between the death and the next decay tick.
  - `NeedsSystem` encodes and decodes it, through `state_codec.gd`.
  - `save_io.gd` lists it among the optional top-level fields.
  - `giver_validator.gd` (`_valid_pending_colony_deaths`) rejects 0, negatives and non-integers,
    because absent means none.
  - It is part of the same unreleased v13 bump, so it needs no further migration: a v12 save
    never has a death pending.
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
- `crafted` counts `craft_work` and `cook_work` (owner, round 2). The thought is given to the
  worker who completes the job.
- `colonist_died` goes to every colony colonist. Relations are a non-goal.
- `colonist_died` lands one tick after the death, through the pending count (hook 4).
- The panel shows each thought's name and weight, not its time left.

**Owner decision: accepted**, in BACKLOG F5c on `main`, commit `f51498d`:

> **Review round 2 (owner's interface, 2026-11-03): design deviations accepted** as listed in
> the F5c handoff: (1) `slept_ground` comes from the needs tick (tired with no reachable bed),
> not from a sleep job; (2) `meal_items` content key decides meal (+) vs raw (0); (3)
> `colonist_died` goes to every colony colonist and lands one tick after the death through the
> pending count (now hashed); (4) the panel shows name and weight, not time left. One change
> required: **`crafted` must also count `cook_work`** (content, one word). ADR 066 merges as
> `proposed` (README rule).

The one change is made: `thoughts.json` `crafted.job_kinds` is `["craft_work", "cook_work"]`,
checked by test 14. ADR 066 stays *proposed*, as the owner says.

Why the code does not follow the design text literally (kept for the record):
- **Ground sleep.** No sleep job ends on the floor: sleep need jobs always target a bed. A
  literal "slept on the ground" event would need a new floor-sleep job, which is outside F5c and
  would mean rewriting `needs_system`'s sleep path (the owner note forbids a rewrite).
- **Death one tick late.** An immediate thought needs a loop over the survivors inside
  `apply_actor_death()`. That loop is exactly what review round 1 rejected, and the owner's
  round-1 note says to fix it as Codex asks. The pending count is the remaining way to use the
  existing decay loop.

## Owner approvals (files outside the listed owned paths)

**Owner decision: approved** for the scope, in BACKLOG F5c on `main`, commit `f55e9b0`:

> **Review round 1 (owner's interface, 2026-11-03): scope.** `core/world/view_snapshot.gd`
> (happiness and active thoughts for the panel) and `game/data/text/en.json` (thought labels)
> are approved as F5c's scope, as declared in the handoff. The technical findings (per-actor
> bed reachability, death thoughts through the existing actor iteration, trigger-driven tests
> for stack limits/replacement/refresh/raw food) are fixed as Codex asks — no amendment.

The owned paths allow "hooks where the triggering events are emitted", "persistence" and
"viewer colonist panel". These files sit in or next to those areas but are not named:
- hooks: `needs_system.gd` (also `pending_colony_deaths`), `toil_bindings.gd`,
  `combat_system.gd`;
- **viewer data: `game/scripts/core/world/view_snapshot.gd`** (the `happiness` block the panel
  reads; the panel cannot derive it itself);
- persistence: `entity_codec.gd`, `entity_validator.gd`, `state_codec.gd`, `save_migrations.gd`,
  `save_io.gd`, `validators/giver_validator.gd`,
  `docs/architecture/contracts/game-state.schema.json`, `test_save_migration.gd`;
- **text: `game/data/text/en.json`** (the happiness label and the thought names the panel shows);
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
- Suite (owner round 2, on `f51498d`): `run_tests: all 138 test(s) PASS  [1.007s]` (1007 s; the runner prints a locale thousands separator)
- Suite (review round 3, on `f51498d`, after the handoff wording fix): `run_tests: all 138 test(s) PASS  [909s]`
- `test_thoughts.gd`: PASS.
- `check_core_budgets.py`: `OK (files <= 800 lines, functions <= 80 code lines, 2 stricter file
  cap(s), 1 file and 3 function exception(s))`. No cap was raised.
- `lint_content_literals.ps1`: `PASS (no tile-id/work-ticks/move-ticks literal found outside the
  registry)`.
- `measure_core.ps1`: `core total: 23454 lines in 114 files` (L3 included). Touched files (lines, code lines,
  comment lines, largest function and its length):

| file | lines | code | comments | largest function |
|---|---|---|---|---|
| `world_state.gd` | 767 (unchanged) | 593 | 114 | `state_hash` 30 |
| `state_codec.gd` | 602 | 440 | 107 | `decode` 70 |
| `toil_bindings.gd` | 500 | 376 | 87 | `_init` 49 |
| `needs_system.gd` | 519 | 401 | 81 | `ensure_needs` 45 |

  The other touched core files (`thoughts.gd` 126, `combat_system.gd` 199, `save_io.gd` 404,
  `validators/giver_validator.gd` 159, `view_snapshot.gd` 264, `entity_codec.gd`,
  `entity_validator.gd` 320, `save_migrations.gd` 286) are far below 800 lines.
- Tests compared with `main`:
  - `test_*.gd` files: 137 on main (`f51498d`), 138 on the branch (`+test_thoughts.gd`);
  - `_check_` sites: 2156 on main, 2188 on the branch;
  - no test was deleted, skipped or loosened.

`test_thoughts.gd` drives everything through real ticks, commands and jobs, never through
direct calls:
1. A meal and a bed raise happiness to 68 within 2 days (> 60), with `ate_meal` and `slept_bed`.
2. Starving on the ground (no bed) drops happiness to 30 (< 40). After a bed is built,
   `slept_ground` stops.
3. Thoughts expire on schedule: `ate_meal` is still active at `until − 1` (happiness 60) and gone
   at `until` (50), and the key is erased.
4. The same seed gives the same `state_hash()`.
5. A save/load in the middle of a thought: the original and the restored world both run two
   more days, then their `state_hash()` values are compared once and match.
6. A recorded session replays to identical hashes.
7. A harvest job gives `harvested` (happiness 52).
8. A craft job gives `crafted` to the crafter only.
9. A colonist's death in combat records `pendingColonyDeaths` 1, which is saved (a value of 0 is
   rejected on load). At the next tick the witness gets `colonist_died` (35) in both the
   original and the restored world, with identical hashes. The raider gets nothing. A save
   with the pending count removed loads to a different `state_hash()` (round 2: the count is
   hashed; this assertion fails without the fix).
10. Stack limit: four deaths keep three `colonist_died` instances; the fourth replaces the
    earliest (happiness 5).
11. Per-region beds: with a rock wall between them, the colonist cut off from the bed gets
    `slept_ground` and the one beside it does not.
12. A repeated meal refreshes the one `ate_meal` instance instead of adding a second one.
13. Raw food adds `ate_raw` only (happiness 50).
14. A cook job (kitchen, `meal`) gives `crafted` to the cook only (owner round 2). With
    `cook_work` removed from `job_kinds`, this check fails.

## Review response (round 1, `.orca-review.md`, REQUEST_CHANGES)

Blocking:
1. **Bed reachability was colony-wide.** Fixed: it is now per colonist region (hook 1). Test 11.
2. **A per-colonist loop was added in combat.** Fixed: combat records a pending count, and the
   existing decay loop applies it (hook 4). The count is persisted as `pendingColonyDeaths`,
   so a save in between is exact. Test 9.
3. **Missing tests.** Added tests 10–13. Test 9 now also covers the pending count.
4. **Scope amendment for `view_snapshot.gd` and `en.json`.** *Approved* by the owner in BACKLOG
   F5c (`f55e9b0`, quoted under "Owner approvals"). Items 1–3 are fixed as Codex asks.
5. **Deviations need the owner's quoted decision.** None is recorded in BACKLOG F5c, so each
   is marked *awaiting* above and ADR 066 stays *proposed*.

Non-blocking:
- The panel shows name and weight only. The "days left" claim was removed.
- Test 5 is described as it runs: two days, then one hash comparison. It does not compare
  tick by tick.

## Review response (round 2, `.orca-review.md`, REQUEST_CHANGES)

Blocking:
1. **`pending_colony_deaths` was not in `state_hash()`.** Fixed: `NeedsSystem.hash_into()`
   adds it when above 0 (hook 4). Test 9 checks that two worlds that differ only in the pending
   count hash differently. With the hash line reverted, `test_thoughts` fails.
2. **Deviations still lack the owner's decision.** No decision has been recorded on `main`
   since `f55e9b0`. They stay *awaiting*. The section above now says why the design text
   cannot be followed literally within F5c's limits. **For the owner:** accept or change the
   ground-sleep substitute and the one-tick death delay.

Non-blocking:
- The measure table's `funcs` column is renamed `comments` (it is comment lines).
- The schema bullet now says that F5a-b (tool hauling, v13, not landed) is not F5b (#54, v12,
  merged). The branch stays at v13.

## Owner note (round 2, BACKLOG F5c, `f51498d`)

1. **Deviations accepted** (quoted above); the "awaiting" status from review rounds 1 and 2 is
   closed.
2. **`crafted` must also count `cook_work`.** Done in `content/thoughts.json` (one word, no code
   change); test 14 covers it. ADR 066's table and consequences say so.
3. **ADR 066 stays *proposed*.** Unchanged; it now cites `f51498d` for the accepted deviations.

## Review response (round 3, `.orca-review.md`, APPROVE)

Blocking: none.

Non-blocking:
- **`F5c.md:61`, "`world_state.gd` did not change".** Reworded: its line count is unchanged
  (767), and its one change is the `state_hash()` line that also calls
  `_needs_system.hash_into(snapshot)` (hook 4).
- **Full suite not rerun in the review sandbox.** Rerun here after the wording fix; the result
  is the round-3 suite line under Validation.

## Limitations and next action

- Happiness is information only. Its consequences (depression) are F5d.
- Approved in review round 3; ready to merge (ADR 066 stays *proposed*).
