# ADR 028: Rescue persistence/reservation revision raises two core budgets

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` caps for `game/scripts/core/world_state.gd`
  and `game/scripts/core/jobs/job_queue.gd`.
- **Implements:** issue #360 (t4 of the trench/trapped-actor/rescue objective, issue #348),
  round-2 review response, ADR 025/026/027.

## Decision

Round-2 review of issue #360 found four blocking defects in the original rescue-giver slice
(ADR 027): a need commitment could be overwritten by a stale rescue commitment for the same
actor; the `trapped:<victim_id>` reservation key was acquired directly by `rescue_giver.gd`
outside `JobQueue`'s own activation/reactivation boundary, so it never survived a
need/combat suspend-resume cycle; a save/load could create a duplicate rescue and orphan a
reservation, because `RescueGiver`'s own job-to-victim bookkeeping was neither persisted nor
rebuilt, and it read/wrote an obsolete `ReservationTable` after `JobQueue.restore()` replaced
it; and a command-path termination (`cancel_job`/`fail_job`/`invalidate_job`/`complete_job`)
never told `RescueGiver` its association resolved, unlike `NeedGiver`.

Fixing all four within the existing "no new job-shape field" constraint required:

- `job_queue.gd`: a new generic `set_extra_reservation_keys()`/`_extra_keys_for_job` callback,
  threaded through `tick()`'s activation branch, `reactivate()`, and `restore()`'s own
  active-job rebuild, so a job's extra reservation key(s) move through the exact same
  lifecycle its ordinary target key already does. Cap moves 549 -> 596 (+47).
- `world_state.gd`: `_committed_jobs()`'s merge order corrected, `_apply_job_command()` now
  shares `_resolve_giver_association()` instead of a need-only check, a new
  `_rescue_victim_for_job()` completion lookup (with `_adjacent_trapped_colonist()` kept only
  as its defensive fallback), and the new `set_extra_reservation_keys()` wiring in
  `_build_dimension_services()`. Cap moves 2910 -> 2948 (+38).
- `game/scripts/core/jobs/givers/rescue_giver.gd` (not core-budgeted, matching ADR 027's own
  "Consequences"): `_commit()`/`reassign_job()` no longer acquire the `trapped:` key directly;
  `extra_keys_for_job()`, `victim_for_job()`, `restore_victim_assignments()`,
  `restore_pending_assignments()`, and `set_reservation_table()` replace the old,
  never-persisted design.
- `game/scripts/core/persistence/state_codec.gd` (not core-budgeted): `decode()` rebuilds
  `RescueGiver`'s job-to-victim association from already-persisted jobs/colonists (a
  deterministic adjacency match, since no per-job field may name "which colonist is being
  rescued") and its rescuer association from the scheduler's own restored `restrict_to`,
  before and after `JobQueue.restore()` respectively -- no new save-schema field, no
  `SCHEMA_VERSION` bump, so `save_migrations.gd` needed no new migration step for this
  revision.

## Consequences

- No further rescue-specific work is anticipated in `world_state.gd` or `job_queue.gd` beyond
  this revision; a future task that still finds either cap insufficient raises it again with
  its own ADR, same as this one did for ADR 026/027's.
- The generic extra-reservation-keys mechanism in `job_queue.gd` is reusable by any future job
  kind that needs a reservation key beyond its own ordinary target, the same way haul's own
  `item:`/`cell:` pair already was special-cased before this change.
