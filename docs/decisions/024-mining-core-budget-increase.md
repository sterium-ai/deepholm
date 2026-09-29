# ADR 024: Mining wiring raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Implements:** issue #347 (mining), issue #352.

## Decision

Wiring the `mine` job kind into `world_state.gd` changes its line count: 2075 -> 2092. The
`core-budgets.json` cap for this file moves 2125 -> 2092 to match, per the convention ADR
016/017/018/022 already set ("cap equals exact post-change line count").

`mine` is added as a content-only job kind (`game/content/jobs.json`: `labour: "mine"`,
`needs_tool: "pick"`, the same `fetch_tool`/`reserve`/`go_to`/`work`/`release_all` toils and
20/80 retry backoff as `dig`) plus a matching `stone` material item
(`game/content/items.json`). `LABOUR_KINDS` already declares `"mine"` for `dig`
(colonist-ai.md 3.2), so no new labour kind and no labour-table UI (#233) change; `dig` itself,
its target, its toils and its tests are untouched.

Round-1 review (codex) found two defects in the first cut of this change: `mine` had its own
self-contained target/assignee validator inside `world_state.gd`
(`_check_mine_target_command()`), never routed through
`game/scripts/core/commands/command_checks.gd`'s `CommandChecks`, so `WorldState.preview()`
disagreed with `WorldState.apply()` for every mine command (preview reported
`unknown_command_type`); and `_toil_on_work_complete()`'s `"mine"` branch spawned a stone and
floored the tile unconditionally, so two mine orders queued for the same rock tile could both
complete a stone once the first order's release freed the second to activate against an
already-floored target. Both are fixed in this revision:

- `command_checks.gd` now joins `"mine"` to `check()`'s and `check_target_job_command()`'s shared dig/
  chop/forage/till/sow dispatch: a new `elif type == "mine":` branch checks `TILE_ROCK` (no
  passability check -- rock, like a tree, is impassable), and `"mine"` joins the
  assignee-accepting (`F3`, issue #290) type list alongside dig/chop/forage. `world_state.gd`'s
  own `_check_mine_target_command()` and its dedicated `"mine"` branch in
  `_apply_job_command()` are removed; `mine` now flows through the exact same
  `CommandChecks.check_target_job_command()` call dig/chop/forage/till/sow already use, so
  `preview()` and `apply()` can never disagree again. `test_command_preview.gd` gained
  preview/apply parity cases for a valid mine, an invalid (non-rock) target, an unknown
  assignee, a refused (non-colony faction) assignee, and unsupported priorities, using the
  existing `_check_preview_matches_apply()` helper, which already asserts preview() mutates
  nothing (state_hash/events/_event_sequence unchanged).
- `_toil_on_work_complete()`'s `"mine"` branch now re-checks `get_tile(target) == TILE_ROCK`
  before flooring the tile or spawning stone, exactly like till/sow's own stale-target
  revalidation: a stale mine job fails `invalid_target` (`resubmit_order`) instead of
  overwriting the floor a different job already produced.
  `test_mine_job.gd`'s new `_check_overlapping_mine_orders_produce_one_stone()` proves two mine
  orders queued for the same rock tile produce exactly one stone, the stale order terminates
  `failed`/`invalid_target`, and neither the tile reservation nor any other reservation is left
  orphaned (`ReservationInvariants.find_orphaned_reservations()`).

`blocked_no_tool` needs no new code at all: it is already fully generic via
`_needs_tool_by_kind`/`fetch_tool`/`JobQueue.block_no_tool()`, driven entirely by
`jobs.json`'s declared `needs_tool: "pick"` for `mine`.

## Consequences

`world_state.gd`'s public surface no longer gains any mine-specific helper beyond
`_spawn_stone_item()`; `_check_mine_target_command()` is gone, and `_apply_job_command()`'s
target-job branch is a single shared list (`["dig", "chop", "forage", "till", "sow", "mine"]`)
instead of a `mine`-only special case. `command_checks.gd` grows by one `elif` branch and one
list entry; it has no line-count cap in `core-budgets.json` (only `world_state.gd`,
`toil_executor.gd`, `job_queue.gd` and `global_assignment.gd` are capped there), so this change
does not raise a second budget. `mine` is not yet part of the persisted-save schema's job-kind
enum (`docs/architecture/contracts/game-state.schema.json`,
`game/scripts/core/persistence/save_io.gd`): both are explicitly out of this task's scope
(Non-goals reserve save/schema validation code for a separate track), so a save taken while a
`mine` job is queued or active will fail `SaveIO` validation until that track adds `"mine"` to
both enums. No existing dig/chop/forage/till/sow test, save fixture, or determinism literal
changes, since none of them ever submit a `mine` command.

Round-1 review directed the shared-validation fix into `command_checks.gd`; an ADR cannot
itself grant ownership authorization, so round-2 review (codex) correctly blocked merge until
that file was added to issue #352's Owned paths. It has since been added there, which is the
authorization round-2 required; the fix itself was already correct in both prior rounds and is
unchanged here.
