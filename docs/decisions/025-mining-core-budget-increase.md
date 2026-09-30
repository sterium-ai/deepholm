# ADR 025: Mining wiring raises the world_state.gd core budget

> **In short:** Colonists can now mine rock with a pick to get stone. Mining orders are checked by
> the same rules as other dig-style orders, and two orders on the same rock can never both produce
> stone.

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`;
  `game/scripts/core/commands/command_checks.gd`.

## Decision

`mine` is added as a content-only job kind (`game/content/jobs.json`: `labour: "mine"`,
`needs_tool: "pick"`, the same `fetch_tool`/`reserve`/`go_to`/`work`/`release_all` toils and 20/80
retry backoff as `dig`) plus a matching `stone` material item (`game/content/items.json`).
`LABOUR_KINDS` already declares `"mine"` for `dig` (colonist-ai.md 3.2), so there is no new labour
kind and no labour-table UI change; `dig` itself, its target, its toils and its tests are
untouched.

Two rules keep `mine` consistent with the other target jobs:

- **Shared command validation.** `mine` goes through `CommandChecks` like dig/chop/forage/till/sow,
  so `WorldState.preview()` and `WorldState.apply()` cannot disagree. `command_checks.gd`'s
  `check()` and `check_target_job_command()` gain an `elif type == "mine":` branch that requires
  `TILE_ROCK` (no passability check: rock, like a tree, is impassable), and `"mine"` joins the
  assignee-accepting type list alongside dig/chop/forage. `world_state.gd` has no mine-specific
  validator or `_apply_job_command()` branch. `test_command_preview.gd` has preview/apply parity
  cases for a valid mine, a non-rock target, an unknown assignee, a refused (non-colony faction)
  assignee and unsupported priorities, using `_check_preview_matches_apply()`, which also asserts
  that `preview()` mutates nothing.
- **Completion revalidates the target.** `_toil_on_work_complete()`'s `"mine"` branch re-checks
  `get_tile(target) == TILE_ROCK` before flooring the tile or spawning stone, like till/sow's
  stale-target revalidation. A stale mine job fails `invalid_target` (`resubmit_order`) instead of
  overwriting a floor another job already produced. `test_mine_job.gd`'s
  `_check_overlapping_mine_orders_produce_one_stone()` proves two mine orders on the same rock
  produce exactly one stone, the stale order ends `failed`/`invalid_target`, and no reservation is
  orphaned (`ReservationInvariants.find_orphaned_reservations()`).

`blocked_no_tool` needs no new code: it is already generic via
`_needs_tool_by_kind`/`fetch_tool`/`JobQueue.block_no_tool()`, driven by `jobs.json`'s
`needs_tool: "pick"`.

Wiring `mine` into `world_state.gd` brings it to 2092 lines, and the `core-budgets.json` cap moves
2125 -> 2092 to match, per the convention that the cap equals the exact post-change line count
(ADRs 015-017 and 023).

## Consequences

- `world_state.gd` gains no mine-specific helper beyond `_spawn_stone_item()`.
  `_apply_job_command()`'s target-job branch is a single shared list (`["dig", "chop", "forage",
  "till", "sow", "mine"]`). `command_checks.gd` grows by one `elif` branch and one list entry; it
  has no cap in `core-budgets.json`, so no second budget is raised.
- This change did not add `mine` to the persisted-save job-kind enums
  (`docs/architecture/contracts/game-state.schema.json`, `save_io.gd`), so a save taken while a
  `mine` job was queued or active failed `SaveIO` validation until a later change added it to both.
- No existing dig/chop/forage/till/sow test, save fixture or determinism literal changes, since
  none of them submit a `mine` command.
