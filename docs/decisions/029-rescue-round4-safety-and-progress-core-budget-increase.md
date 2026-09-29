# ADR 029: Rescue round-4 revision raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Implements:** issue #360 (t4 of the trench/trapped-actor/rescue objective, issue #348),
  round-2 review round-4 response, ADR 025/026/027/028.

## Decision

Round-2 review's fourth pass found five further defects in the rescue-giver slice (ADR 028):
route safety only rejected a path crossing the VICTIM's own tile, letting a candidate through a
completely unrelated trench; a candidate that moved every tick could indefinitely restart the
search ahead of a later, idle candidate; `_resume_paused_job()`'s generic reach/reservation-
oblivious path let a resumed rescue cross a trench or start work one tile off its own verified
target; two rescue jobs sharing one target tile could read and clear each other's saved work
progress across a suspend/resume; and `state_hash()` omitted RescueGiver's own job-to-victim
association.

Fixing the `world_state.gd`-side defects (route safety and candidate drift are entirely
`rescue_giver.gd`'s own, not core-budgeted) required:

- A new `_is_trench_tile()` callable wired into `RescueGiverType.new()`, so the real-route safety
  check in `rescue_giver.gd` can reject a path crossing ANY trench, not merely the one it already
  knew about.
- A new `_resume_paused_rescue()` branch in `_resume_paused_job()`, revalidating a resumed rescue
  through `RescueGiver.route_is_safe()` and requiring exact-tile arrival before work starts,
  retiring an unsafe or unreachable commitment instead of blindly resubmitting it.
- `_work_progress_key()` scoped to the tile's current reservation owner, so two rescue jobs
  sharing a target tile can never read or clear each other's saved progress.
- `state_hash()` now folds in `RescueGiver.get_job_victims()`.

Cap moves 2948 -> 2998 (+50, current file 2993 lines).

## Consequences

- No further rescue-specific work is anticipated in `world_state.gd` beyond this revision; a
  future task that still finds the cap insufficient raises it again with its own ADR, same as
  this one did for ADR 026/027/028's.
