# ADR 031: Rescue route safety and per-job progress keys raise the world_state.gd core budget

> **In short:** Fixes so a rescuer never walks through a trench on the way to help, and two rescues
> at the same spot never mix up each other's progress. The fixes needed more room in one
> size-limited core file.

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`;
  `game/scripts/core/jobs/givers/rescue_giver.gd`.
- **Extends:** [ADR 030](030-rescue-persistence-and-reservation-fixes-core-budget-increase.md).

## Context

After ADR 030, the rescue giver still had five defects:

1. Route safety only rejected a path crossing the victim's own tile, so a rescuer could be routed
   through a different trench.
2. A candidate rescuer that moved every tick could restart the route search indefinitely, ahead of
   a later, idle candidate.
3. `_resume_paused_job()`'s generic path ignored reach and reservations, so a resumed rescue could
   cross a trench or start work one tile away from its verified target.
4. Two rescue jobs sharing a target tile could read and clear each other's saved work progress
   across a suspend/resume.
5. `state_hash()` omitted `RescueGiver`'s job-to-victim association.

## Decision

Route safety and candidate drift (defects 1 and 2) are fixed inside `rescue_giver.gd`, which is
not core-budgeted. The remaining fixes, and one hook the route check needs, change
`world_state.gd`:

- A new `_is_trench_tile()` callable passed to `RescueGiverType.new()`, so the giver's route check
  rejects a path crossing *any* trench.
- A new `_resume_paused_rescue()` branch in `_resume_paused_job()` that revalidates a resumed rescue
  through `RescueGiver.route_is_safe()` and requires exact-tile arrival before work starts,
  retiring an unsafe or unreachable commitment instead of resubmitting it.
- `_work_progress_key()` scoped to the tile's current reservation owner, so two rescue jobs sharing
  a target tile never read or clear each other's progress.
- `state_hash()` includes `RescueGiver.get_job_victims()`.

The cap moves 2948 -> 2998 (+50; the file is 2993 lines).

## Consequences

- ADR 032 replaces the resume revalidation (`route_is_safe()`) and the owner-scoped progress key
  described here with a shared route budget, post-commit route safety and job-identity progress
  keys.
