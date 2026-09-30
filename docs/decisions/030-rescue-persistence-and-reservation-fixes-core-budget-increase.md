# ADR 030: Rescue persistence and reservation fixes raise two core budgets

> **In short:** Fixes to the rescue behaviour so that saving and loading, or interrupting a
> rescuer, never creates duplicate rescues or leaves things wrongly marked as claimed. The fixes
> needed more room in two size-limited core files.

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` caps for `game/scripts/core/world_state.gd`
  and `game/scripts/core/jobs/job_queue.gd`; `game/scripts/core/jobs/givers/rescue_giver.gd`;
  `game/scripts/core/persistence/state_codec.gd`.
- **Extends:** [ADR 029](029-rescue-job-giver-core-budget-increase.md).

## Context

The first rescue giver (ADR 029) had four defects:

1. A stale rescue commitment could overwrite a need commitment for the same actor.
2. `rescue_giver.gd` acquired the `trapped:<victim_id>` reservation key itself, outside
   `JobQueue`'s activation/reactivation lifecycle, so the key did not survive a need or combat
   suspend/resume cycle.
3. `RescueGiver`'s job-to-victim bookkeeping was neither persisted nor rebuilt, so a save/load
   could create a duplicate rescue and orphan a reservation; the giver also kept using an obsolete
   `ReservationTable` after `JobQueue.restore()` replaced it.
4. A job terminated by command (`cancel_job`/`fail_job`/`invalidate_job`/`complete_job`) never told
   `RescueGiver` its association had resolved, unlike `NeedGiver`.

All four must be fixed without adding a new field to the job shape.

## Decision

- **`job_queue.gd`:** a generic extra-reservation-keys callback (`set_extra_reservation_keys()`/
  `_extra_keys_for_job`), used by `tick()`'s activation branch, `reactivate()` and `restore()`'s
  active-job rebuild, so a job's extra keys follow exactly the same lifecycle as its ordinary target
  key. Cap 549 -> 596 (+47).
- **`world_state.gd`:** `_committed_jobs()`'s merge order is corrected so a need commitment is not
  overwritten; `_apply_job_command()` uses `_resolve_giver_association()` instead of a need-only
  check; a new `_rescue_victim_for_job()` completion lookup (with `_adjacent_trapped_colonist()`
  kept only as a defensive fallback); and the `set_extra_reservation_keys()` wiring in
  `_build_dimension_services()`. Cap 2910 -> 2948 (+38).
- **`rescue_giver.gd`** (not core-budgeted): `_commit()`/`reassign_job()` no longer acquire the
  `trapped:` key directly. `extra_keys_for_job()`, `victim_for_job()`,
  `restore_victim_assignments()`, `restore_pending_assignments()` and `set_reservation_table()`
  replace the unpersisted design.
- **`state_codec.gd`** (not core-budgeted): `decode()` rebuilds the job-to-victim association from
  the already-persisted jobs and colonists (a deterministic adjacency match, since no job field may
  name the rescued colonist) before `JobQueue.restore()`, and the rescuer association from the
  scheduler's restored `restrict_to` after it. There is no new save-schema field and no
  `SCHEMA_VERSION` bump, so `save_migrations.gd` needs no new step.

## Consequences

- The extra-reservation-keys mechanism in `job_queue.gd` is generic and reusable by any future job
  kind that needs a reservation key beyond its target, where previously only haul's `item:`/`cell:`
  pair was special-cased.
- Further defects in rescue route safety and progress keying are addressed by ADR 031.
