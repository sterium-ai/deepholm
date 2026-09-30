# ADR 032: Shared rescue route budget and post-commit route safety raise the world_state.gd core budget

> **In short:** Rescue route-finding now shares the same per-tick effort limit as all other
> movement, and a rescuer's path is re-checked every time it changes, so no rescuer ever walks
> through a trench. A rescue that becomes unsafe is dropped and chosen afresh.

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`;
  `game/scripts/core/jobs/givers/rescue_giver.gd`; `docs/architecture/colonist-ai.md` section 3.6;
  `docs/architecture/orders-and-movement.md` (work-progress keying).
- **Supersedes:** the resume revalidation and owner-scoped progress key of
  [ADR 031](031-rescue-route-safety-and-progress-keys-core-budget-increase.md).

## Context

After ADR 031, rescue still had these problems:

- The giver's route searches did not share the per-colonist, per-tick route budget (ADR 004), and
  `RescueGiver.route_is_safe()` ran a synchronous search to completion on resume.
- Only the commit-time route was checked for trenches. A mid-travel re-route, a resumed route, or
  the path the scheduler computes at activation could still cross a trench or end one tile off
  target, because the map can change after commit.
- An unreachable rescue was resubmitted under the same rescuer, instead of letting the victim's
  next search choose any rescuer.
- Progress keys were cleaned up by tile rather than by the terminating job's identity.
- `state_hash()` hashed the raw job-to-victim Dictionary, so identical associations restored in a
  different insertion order hashed differently.

## Decision

All fixes use boundaries `world_state.gd` already owns: no `toil_executor.gd`,
`global_assignment.gd` or `reservation_table.gd` change, and no new toil.

- **Shared route budget (ADR 004).** `RescueGiver` is constructed with `WorldState._route_budget`,
  the per-colonist, per-tick ledger that `GlobalAssignment.tick()` clears at its start and
  `ToilExecutor`'s go_to re-route already honours. The giver spends at most one
  `RerouteType.resume()` per candidate colonist per tick and keeps an unfinished search across
  ticks. To share the ledger, `_rescue_giver.advance()` runs immediately *after*
  `_scheduler.tick()` and before `_advance_colonists()` (running before the scheduler, its marks
  were wiped by the clear). A commitment therefore reaches the scheduler's committed-proposal path
  one tick later; priority ordering is unchanged. `get_route_telemetry()` reports actual calls.
  `RescueGiver.route_is_safe()` is removed.
- **Post-commit route safety.** The giver validates only the commit-time route. After that:
  1. `_toil_go_to_passable()` gives a `rescue` job `_rescue_routable_to()`, under which every
     trench tile is impassable and the target has no impassable-target exception, so a mid-travel
     re-route never crosses a trench, and a target that became impassable reads as unreachable
     instead of being trimmed to a neighbouring tile;
  2. `_resume_paused_rescue()` re-derives its route through the executor's budgeted
     `advance_go_to()` under the same passability, still requiring exact-tile arrival;
  3. `_rescue_activation_safe()` re-checks a fresh activation's scheduler-computed path (no trench,
     ends on target, target passable) before its first step.

  All three retire an unsafe commitment through `_retire_rescue_job()`.
- **Retire, never resubmit under the same rescuer.** `_toil_on_unreachable()` sends a rescue to
  `_retire_rescue_job()` (cancel through the shared finish boundary, drop its progress key, call
  `RescueGiver.resolve_job()`), and the giver retires a queued commitment the scheduler has marked
  `blocked_target_unreachable`. The victim's next search may then choose any rescuer.
  `RescueGiver.reassign_job()` and `_resubmit_unreachable_job()`'s rescue branch are removed.
- **Identity-keyed progress cleanup.** `_work_progress_key_for_job(job_id, job)` is the single
  source of a job's key (job-scoped for `rescue`, the plain tile otherwise); the tile-addressed
  `_work_progress_key()` used by the executor's mid-work hooks resolves the owner and delegates.
  Every terminal boundary (`_apply_job_command()`, `_trap_actor()`, `_cancel_job_for_death()`,
  `_resolve_refused_reservations()`, `_retire_rescue_job()`) clears through
  `_clear_terminated_job_progress()` by the terminating job's identity: a rescue's key on every
  terminal transition, active or suspended; an ordinary job's plain key only when it was the active
  owner, as before.
- **Canonical hash.** `state_hash()` uses `StateCodec._encode_rescue_victim_assignments()` (a sorted
  `{jobId, victimId}` array) instead of the raw Dictionary. `test_toils_dig_chop_regression.gd` and
  `test_world_state_determinism.gd` recaptured their hash literals for this snapshot-shape change,
  as recorded in each file's comments.

The cap moves 2998 -> 3110 (+112; the file is 3099 lines).

## Consequences

- One asymmetry remains, documented in colonist-ai.md 3.6: the giver's commit-time search uses the
  unrestricted `_routable_to()`, so it validates exactly the path the scheduler's activation will
  compute, while every later re-route excludes trenches.
- A retired rescue restarts its 20-tick work from scratch under a fresh job id; only a suspended and
  resumed rescue keeps its progress.
