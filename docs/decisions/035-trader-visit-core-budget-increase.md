# ADR 035: Trader visit and accept_trade raise the world_state.gd core budget

> **In short:** Visiting traders can now offer a swap that the player accepts. That feature lives in the main world-state file, so that file's agreed size limit was raised to fit it.

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.

## Decision

Wiring the trader's `trade_offer` and the new `accept_trade` command raises
`world_state.gd`'s `core-budgets.json` cap from 3804 to 3928. Both extensions use
existing extension points rather than new ones:

- `_maybe_post_trade_offer()`/`_post_trade_offer()`/`_pick_trade_items()` hook
  into `_set_work_progress()`, the same per-tick callable
  `ToilExecutor.advance_work_step()` already calls for every work-toil job
  (`docs/architecture/orders-and-movement.md`, "Incident jobs"). A trader
  (an actor with the `visitor` component) therefore posts its offer during its
  existing generic incident wait: no new toil, no new job-giver, no parallel
  arrival system. The offer posts on the wait's first tick rather than its last,
  so `accept_trade` has a real window before the trader's despawn. The despawn
  keeps its unchanged schedule, so the exact wait-timing assertions in
  `test_incidents.gd` still hold for every incident actor, traders included.
- `_apply_accept_trade_command()` follows the existing command-validation
  shape (`_apply_set_faction_command()`'s validate-then-mutate,
  `_rejection()`/`_applied()`). It reuses `_remove_one_item_of_kind()` (already
  `sow`'s seed precondition) and `_spawn_item()` for the ground-item swap, and
  cancels the trader's still-active incident job through the shared finish
  boundary (`_finish_job()`), so `IncidentScheduler.on_job_finished()` removes
  the trader exactly as it does for an unaccepted departure.

None of this fits the toil executor, a job-giver module, or content alone:
the swap is a one-shot command mutation, not a per-tick decision, and the
offer and departure timing is entirely the existing incident wait's schedule.

## Consequences

The cap equals the file's exact post-change line count, matching every
prior `core-budgets.json` entry. No other core file's budget changes.
