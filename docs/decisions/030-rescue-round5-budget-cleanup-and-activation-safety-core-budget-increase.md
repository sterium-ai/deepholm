# ADR 030: Rescue round-5 revision (shared route budget, identity-keyed progress cleanup, post-commit route safety) raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`;
  `game/scripts/core/jobs/givers/rescue_giver.gd`; `docs/architecture/colonist-ai.md` 3.6;
  `docs/architecture/orders-and-movement.md` (work-progress keying).
- **Implements:** issue #360 (t4 of the trench/trapped-actor/rescue objective, issue #348),
  round-4 review response; supersedes the resume-validation and progress-key mechanisms ADR 029
  describes.

## Decision

Round-4 review found four remaining defects in the rescue-giver slice (ADR 029) plus one it
classed as a task-body gap. All five are resolved inside the task's Owned paths — no
`toil_executor.gd`, `global_assignment.gd` or `reservation_table.gd` change, and no new toil —
by hooking rescue's post-commit safety into boundaries `world_state.gd` already owns:

- **Shared route budget (ADR 004).** `RescueGiver` is constructed with `WorldState._route_budget`
  itself — the per-colonist, per-tick ledger `GlobalAssignment.tick()` clears at its start and
  `ToilExecutor`'s go_to re-route already honours — and spends at most one `RerouteType.resume()`
  per candidate colonist per tick against it, retaining an unfinished search across ticks. To
  share that ledger, `_rescue_giver.advance()` now runs immediately **after** `_scheduler.tick()`
  and before `_advance_colonists()` (it used to run before the scheduler, where its marks were
  wiped by the clear). A commitment therefore reaches the scheduler's committed-proposal path one
  tick later than before; priority ordering is unchanged. `get_route_telemetry()` reports actual
  calls. `RescueGiver.route_is_safe()` — a synchronous search run to completion on resume — is
  removed.
- **Post-commit route safety, at the source.** The giver validates the commit-time route only.
  Afterwards: (1) `_toil_go_to_passable()` hands a `rescue` job `_rescue_routable_to()`, under
  which every trench tile is impassable and the target has no impassable-target exception — so a
  mid-travel re-route can never cross a trench, and a target made impassable reads as
  unreachable instead of being trimmed to start work one tile off; (2) `_resume_paused_rescue()`
  re-derives its route through the executor's own budgeted `advance_go_to()` under that same
  passability, exact-tile arrival still required; (3) `_rescue_activation_safe()` re-checks a
  fresh activation's scheduler-computed path (no trench, ends on target, target passable) before
  its first drive, since the map may change between commit and activation. All three retire an
  unsafe commitment through `_retire_rescue_job()`.
- **Retire, never resubmit under the same rescuer.** `_toil_on_unreachable()` routes a rescue to
  `_retire_rescue_job()` (cancel through the shared finish boundary, drop its progress key,
  `RescueGiver.resolve_job()`), and the giver itself retires a queued commitment the scheduler has
  marked `blocked_target_unreachable`. The victim's next search may then choose any rescuer.
  `RescueGiver.reassign_job()` and `_resubmit_unreachable_job()`'s rescue branch are removed.
- **Identity-keyed progress cleanup.** `_work_progress_key_for_job(job_id, job)` is the one
  source of a job's key (job-scoped for `rescue`, plain tile otherwise); the tile-addressed
  `_work_progress_key()` used by the executor's mid-work hooks resolves the owner and delegates.
  Every terminal boundary (`_apply_job_command()`, `_trap_actor()`, `_cancel_job_for_death()`,
  `_resolve_refused_reservations()`, `_retire_rescue_job()`) clears through
  `_clear_terminated_job_progress()` by the terminating job's explicit identity: a rescue's key on
  every terminal transition, active or suspended; an ordinary job's plain key only when it was the
  active owner, exactly as before.
- **Canonical hash.** `state_hash()` folds in `StateCodec._encode_rescue_victim_assignments()`
  (sorted `{jobId, victimId}` array) instead of the raw Dictionary, so identical associations
  restored in a different insertion order hash identically. `test_toils_dig_chop_regression.gd` and
  `test_world_state_determinism.gd` recaptured their literals (a pure snapshot-shape change,
  documented in each file's own trail).

Cap moves 2998 -> 3110 (+112; file is 3099 lines after this revision).

## Consequences

- The reviewer's finding 5 ("task-body") needed no owned-path expansion: the go_to passability
  hook and the first-drive boundary are `WorldState`'s own, and the executor's re-route machinery
  is reused unchanged. The residual asymmetry is documented in colonist-ai.md 3.6: the giver's
  commit-time search stays on the unrestricted `_routable_to()` (so it validates the exact path the
  scheduler's activation will compute), while every later re-route runs trench-excluding.
- A retired rescue restarts its 20-tick work from scratch under a fresh job id; only a
  suspended-and-resumed rescue keeps its own progress.
- ADR 029's "no further rescue-specific work is anticipated" is superseded by this ADR the same
  way it superseded ADR 028's.
