# ADR 029: Rescue job-giver raises the world_state.gd core budget

> **In short:** When a colonist is stuck in a trench, another colonist now comes to pull them out.
> Wiring this rescue behaviour into the simulation needed more room in one size-limited core file.

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`;
  new `game/scripts/core/jobs/givers/rescue_giver.gd`.
- **Depends on:** [ADR 026](026-trench-trapped-actor-and-rescue.md),
  [ADR 027](027-trench-trap-escape-core-budget-increase.md).

## Context

Rescue is the last step of the trench feature (ADR 026): a colonist trapped in a trench is freed
by another colonist through an ordinary `rescue` job. ADR 027 left `world_state.gd`'s cap at 2774,
its exact line count, and expected rescue to add only a bounded amount of completion-effect code.

## Decision

A new job giver, `RescueGiver` (`rescue_giver.gd`), decides when a `rescue` job should exist and
which colonist performs it, as `NeedGiver` does for needs. It needs more `world_state.gd` wiring than
a single completion-effect branch:

- the giver's construction and its `advance()` call;
- the `_rescue_candidates()`/`_trapped_rescue_victims()` pool builders and the
  `_rescue_target_candidates()` target rule;
- the `_adjacent_trapped_colonist()` lookup used at work completion;
- the `get_colonist_rescue_reason()`/`_set_rescue_reason()` reason-cache pair;
- rescue commitments merged into `_committed_jobs()`;
- a shared `_resolve_giver_association()` helper, factored out of `_trap_actor()`,
  `_cancel_job_for_death()` and `_resolve_refused_reservations()`, so `RescueGiver.resolve_job()`
  hears about a rescue job cancelled or failed outside its own `advance()`, as `NeedGiver` does;
- a rescue-aware branch in `_resubmit_unreachable_job()`, since a rescue job's first `go_to` leg can
  become unreachable like any other.

The cap moves 2774 -> 2910 (+136), matching the file's exact post-change line count, per the
convention of ADRs 015-017, 023 and 025-027.

## Consequences

- `rescue_giver.gd` carries none of this budget: job-giver modules are not core-budgeted, like
  `need_giver.gd` and `haul_giver.gd`.
- Defects later found in this first version are fixed by ADRs 030 (persistence and reservations),
  031 (route safety and progress keys) and 032 (shared route budget and post-commit route safety).
