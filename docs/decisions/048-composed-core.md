# ADR 048: Composed core — one size rule replaces per-file budgets

> **In short:** The simulation core is now a thin `WorldState` façade over small
> modules (refactor R1–R12). Instead of one line cap per file, raised by an ADR
> every time a feature needed room, every core file must stay at or below 800 lines
> and every function at or below 80 lines of code. The few files that were already
> bigger are frozen at their current size until a named task shrinks them.

- **Status:** accepted
- **Date:** 2026-10-27
- **Scope:** simulation; `docs/architecture/core-budgets.json`, `tools/check_core_budgets.py`, the CI size step.
- **Supersedes:** ADR 015, 016, 017, 023, 025, 027, 028, 029, 030, 031, 032, 035, 036, 041 (every "… raises … core budget" ADR).
- **Depends on:** `docs/orca/REFACTOR-PLAN.md`, ADR 011 (one work engine), `docs/architecture/extension-points.md`.

## Context

`core-budgets.json` capped the line count of a hand-picked list of large files.
Fourteen ADRs exist only to raise `world_state.gd`'s cap (5,030 lines at its peak)
or a sibling's. The caps limited growth but never moved code: each new
system landed in `world_state.gd` and its ADR raised the cap.

The refactor (R1–R12) split that file into modules: event log, item/tile/object/zone
tables, passability, work progress, construction, trench, trade, needs, combat, the
command router and handlers, toil bindings, and in R12 the tick pipeline
(`world/tick_pipeline.gd`), world seeding (`worldgen/world_seeding.gd`) and content
tables (`content/content_tables.gd`). `world_state.gd` is now under 800 lines.
A per-file list is no longer what keeps the core small.

## Decision

1. **One rule for every `.gd` file under `game/scripts/core/`:** at most
   `max_file_lines` (800) total lines, and every function at most
   `max_function_lines` (80) code lines. A function's length runs from its `func`
   line to the next one, without comment and blank lines: the `FuncLines` column of
   `tools/measure_core.ps1`.
2. **Old caps below the rule stay.** A file whose pre-ADR cap was already stricter
   than 800 keeps that cap in `stricter_file_caps` (`job_queue.gd` 790,
   `global_assignment.gd` 688): replacing it with 800 would raise it.
3. **Frozen exceptions.** A file or function that was already over the rule when it
   landed is listed in `core-budgets.json` with `cap` set to its size at that point,
   plus `until`, the task that removes it (`R14` for persistence, or `unassigned`).
   A cap is never raised. An exception the code no longer needs (the file or
   function is back within the rule, or is gone) fails the check until someone
   deletes it, so the list only ever shrinks.
4. **`tools/check_core_budgets.py`** enforces 1 to 3 and runs in CI in place of the
   old per-file loop. It also runs locally: `python tools/check_core_budgets.py`.
5. **No budget ADRs.** Code that would push a file over the rule goes into a new
   module or an extension point (`extension-points.md`). An exception is never
   added for new code. Adding one, or raising a cap, needs an ADR that supersedes
   this one.
6. **`WorldState.tick()` runs `TickPipeline`**, whose `PHASES` list names the per-tick
   phases in order. A new per-tick system adds a phase there (ADR 046's `story`
   phase is the first planned one), not a line in `world_state.gd`.

## Alternatives considered

- **Keep per-file caps and lower them.** This keeps the ADR-per-raise habit and
  ignores every file not on the list, which is how `save_io.gd`, `state_codec.gd`,
  `world_generator.gd` and `content_registry.gd` grew past 800 with no cap at all.
- **Split every file over 800 in R12.** That would touch persistence, which R14
  rewrites anyway, and files other tasks are changing while R12 is in flight (A4 is changing
  `toil_executor.gd`). The owner chose frozen exceptions instead (R12 handoff).
- **A file cap only.** Most of the past complexity hid in a few very long functions
  (`_init` reached 123 lines, `_validate_state` is 306), so functions get a cap too.

## Consequences

- Later features add modules or phases. They do not raise caps.
- Six files and five functions stay over the rule for now (listed in
  `core-budgets.json`). The persistence ones go away with R14; the others need
  backlog entries of their own.
- The superseded ADRs stay as history; their numbers in `core-budgets.json` no
  longer apply.

## Acceptance criteria

- [x] `core-budgets.json` holds the rule, the stricter old caps and the frozen exceptions; CI runs
      `tools/check_core_budgets.py`.
- [x] `tools/measure_core.ps1` shows no core file above 800 lines outside the
      exceptions, and no function above 80.
- [x] The superseded ADRs say so in their status line.
- [x] Save/migration impact: none (no persisted shape changes).
