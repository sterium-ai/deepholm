# ADR 034: Trader visit round-2 revision (two-way trade swap, stale-offer cleanup) raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Implements:** issue #278 (Result item 2, "trader"); issue #305; round-1 review response;
  supersedes ADR 033's line count (its budget math still holds, the file has since grown).

## Decision

Round-1 review found `_apply_accept_trade_command()` only removed `want_item` from the
colony and never actually moved it into the trader, and that a refused trader's
`trade_offer` outlived the trader in `get_pending_trade_offers()`. Both are fixed inside
the same extension points ADR 033 already established -- no new toil, job-giver, or
command:

- **Two-way swap.** `want_item` now moves out of an eligible stockpiled item
  (`_find_available_build_item()`, the same zone/reservation/uncommitted invariant `build`
  already resolves its own stockpiled item through, so a trade can never rip an item out
  of a colonist's hands mid-haul) into the trader's `inventory` component via the new
  `_append_trader_inventory_item()` helper (shared with `_post_trade_offer()`'s own
  give_item append). `give_item` then moves out of that inventory into the stockpile tile
  the want_item unit just vacated, via the new `_remove_stockpiled_item_unit()` helper.
- **Stale offer cleanup at the shared boundary.** `_finish_job()`'s "incident" branch --
  the one place every incident actor's departure converges, accepted or not -- now erases
  the departing actor's `_pending_trade_offers` entry, so a refused trader's offer never
  outlives it.

Cap moves 3928 -> 3970 (+42; file is 3970 lines after this revision).

## Consequences

- No other core file's budget changes.
- `test_trader_visit.gd` asserts both inventories, the stockpile tile, a carried-only
  `want_item` rejection, and that an unaccepted trader's offer is gone from
  `get_pending_trade_offers()` once it departs.
