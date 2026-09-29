# ADR 033: Trader visit/accept_trade raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-24
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Implements:** issue #278 (Result item 2, "trader"); issue #305.

## Decision

Wiring the trader's `trade_offer` and the new `accept_trade` command raises
`world_state.gd`'s `core-budgets.json` cap: 3804 -> 3928. Both extensions use
existing extension points, not new ones:

- `_maybe_post_trade_offer()`/`_post_trade_offer()`/`_pick_trade_items()` hook
  into `_set_work_progress()`, the same per-tick callable
  `ToilExecutor.advance_work_step()` already calls for every work-toil job
  (`docs/architecture/orders-and-movement.md`, "Incident jobs"), so a trader
  (the `visitor` component, F2) posts its offer on its own already-generic
  incident wait -- no new toil, no new job-giver, no parallel arrival system.
  The offer posts on the wait's first tick rather than its last so
  `accept_trade` has a real window before the trader's despawn, which stays
  on its unchanged schedule: `test_incidents.gd`'s own exact-wait-timing
  assertions (out of this task's owned paths) still hold for every incident
  actor, trader included.
- `_apply_accept_trade_command()` follows the existing command-validation
  shape (`_apply_set_faction_command()`'s validate-then-mutate,
  `_rejection()`/`_applied()`), reuses `_remove_one_item_of_kind()` (already
  `sow`'s own seed precondition) and `_spawn_item()` for the ground-item
  swap, and cancels the trader's still-active incident job through the
  shared finish boundary (`_finish_job()`) so `IncidentScheduler.on_job_finished()`
  removes the trader exactly the way its own unaccepted despawn already does.

None of this fits the toil executor, a job-giver module, or content alone:
the swap is a one-shot command mutation, not a decision made every tick, and
the offer/departure timing is entirely the existing incident wait's own
schedule.

## Consequences

The cap now equals the file's exact post-change line count, matching every
prior `core-budgets.json` entry. No other core file's budget changes.
