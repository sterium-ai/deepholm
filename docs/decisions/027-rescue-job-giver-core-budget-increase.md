# ADR 027: Rescue job-giver raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Implements:** issue #360 (t4 of the trench/trapped-actor/rescue objective, issue #348), ADR 025/026.

## Decision

ADR 026 left `world_state.gd`'s cap at 2774, matching its own exact post-change line count, and
noted "t4, rescue, is expected to add a bounded amount of its own completion-effect code." t4
(`rescue_giver.gd`, this task) needed orchestration wiring beyond a single completion-effect
branch: the giver's own construction and `advance()` call, the `_rescue_candidates()`/
`_trapped_rescue_victims()` pool builders, the `_rescue_target_candidates()` target rule, the
`_adjacent_trapped_colonist()` completion-effect lookup, the new `get_colonist_rescue_reason()`/
`_set_rescue_reason()` reason-cache pair, the `_committed_jobs()` merge, and a shared
`_resolve_giver_association()` helper factored out of three existing call sites
(`_trap_actor()`, `_cancel_job_for_death()`, `_resolve_refused_reservations()`) so RescueGiver's
own `resolve_job()` is told about a rescue job cancelled/failed outside its own `advance()`, the
same way NeedGiver already is. `_resubmit_unreachable_job()` also gained a rescue-aware branch,
since a rescue job's first `go_to` leg can turn unreachable exactly like any other job's can.
The cap moves 2774 -> 2910 (+136), matching the file's exact post-change line count, per the
convention ADR 016/017/018/022/024/025/026 already set.

## Consequences

- No further rescue-specific work is anticipated in `world_state.gd` beyond this task; a future
  task that still finds the cap insufficient raises it again with its own ADR, same as this one
  did for ADR 026's.
- `rescue_giver.gd` itself (a new file under `game/scripts/core/jobs/givers/`) carries none of
  this budget -- job-giver modules are not core-budgeted files today, matching `need_giver.gd`
  and `haul_giver.gd`.
