# ADR 036: Two-way trader swap and stale-offer cleanup raise the world_state.gd core budget

> **In short:** Trading now really exchanges goods in both directions, and a trader's offer disappears when the trader leaves. These fixes slightly enlarged the main world-state file, so its size limit was raised again.

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Supersedes:** ADR 035's line count (its budget reasoning still holds; the file has since grown).

## Context

The first version of `_apply_accept_trade_command()` only removed `want_item`
from the colony and never moved it into the trader, and a refused trader's
`trade_offer` outlived the trader in `get_pending_trade_offers()`.

## Decision

Both problems are fixed inside the extension points ADR 035 already
established, with no new toil, job-giver, or command:

- **Two-way swap.** `want_item` now moves out of an eligible stockpiled item
  into the trader's `inventory` component via the new
  `_append_trader_inventory_item()` helper (shared with `_post_trade_offer()`'s
  `give_item` append). The item is found with `_find_available_build_item()`,
  the same zone/reservation/uncommitted rule `build` uses for its stockpiled
  items, so a trade can never take an item out of a colonist's hands mid-haul.
  `give_item` then moves out of that inventory onto the stockpile tile the
  `want_item` unit just vacated, via the new `_remove_stockpiled_item_unit()`
  helper.
- **Stale-offer cleanup at the shared boundary.** `_finish_job()`'s "incident"
  branch, the one place every incident actor's departure converges (accepted
  or not), now erases the departing actor's `_pending_trade_offers` entry, so a
  refused trader's offer never outlives it.

The cap moves from 3928 to 3970 (+42; the file is 3970 lines after this change).

## Consequences

- No other core file's budget changes.
- `test_trader_visit.gd` asserts both inventories, the stockpile tile, the
  rejection of a `want_item` that exists only in someone's hands, and that an
  unaccepted trader's offer is gone from `get_pending_trade_offers()` once it
  departs.
