# ADR 044: Area orders expand through a saved per-tick queue

> **In short:** A dragged rectangle of dig/chop/mine/cancel/... orders is now
> one command. The game turns it into the same single-tile orders as before,
> but a fixed number per tick instead of all in one frame, so releasing even a
> whole-map order no longer freezes the game. The pending part is saved.

- **Status:** accepted
- **Date:** 2026-10-25
- **Scope:** simulation, persistence
- **Implements:** backlog B1 (`docs/orca/BACKLOG.md`)

## Context

Releasing a drag with a per-tile tool submitted one command per tile, all
in the same frame (`order_input.gd`'s `commit_rectangle()`). On a 256x256
map that is up to 65,536 commands. Before B1 each one also cost a pass over
every job or event, so a whole-map dig was quadratic (extrapolated at hours;
`bench_area_orders.gd`, numbers in `docs/orca/handoffs/B1.md`). B1's first two
steps made every per-command and per-tick cost independent of the queue size,
but a whole-map release still cost ~6 s of one frame for Dig and ~12 s for
Cancel: tens of microseconds per tile command, times 65,536, in one frame.
The backlog's fix principle allows spreading an area order over ticks only as
"an explicit, deterministic, saved queue (a command that expands N tiles per
tick), never wall-clock based".

## Decision

**`area_order` is one command naming a rectangle**: `{order, x, y, width,
height, priority}`, `order` one of `dig`, `chop`, `forage`, `till`, `sow`,
`mine`, `cancel`, `remove_object` (the viewer's per-tile tools). Payload rule
`AreaOrders.check()` is shared by `apply()` and `preview()`: an unknown order,
a non-integer field or an extra key is `invalid_payload`; an empty rectangle
or one not inside the map, `invalid_target`.

**Expansion reuses the single-tile command.** An accepted order joins a
queue (`game/scripts/core/commands/area_orders.gd`). Each tile, in row-major
order, becomes exactly the command a click on that tile submits and goes
through `apply()` itself: same rules, same `command_applied` /
`command_rejected` event, same rejection reasons. For `cancel` the tile's
command is the covering construction site's `cancel_site`, else `cancel_job`
for the tile's preferred pending job (queued before active, then higher
priority, then lower id), else nothing -- the rule the viewer applied before,
now in the core (`AreaOrders.cancel_before()`, which the viewer's preview
calls too). Pending jobs per tile come from `JobIndex.pending_at()`, kept from
JobQueue's own events.

**Paced per tick, never by wall-clock.** `AreaOrders.TILES_PER_STEP` (128)
of the order's own tiles are expanded when it is accepted -- even behind a
backlog of earlier orders -- and 128 tiles at the start of every `tick()`,
before the clock advances (the same tick a player command issued just before
that tick would carry), for the pending orders first-in first-out. A
rectangle of up to 128 tiles behaves exactly as before: every job exists when
the release returns, with its own rejections (never an earlier order's) in
the envelope's `skipped` list.

**Per tile, acceptance order.** Before an order expands a tile, every earlier
pending order whose rectangle holds that tile and has not reached it yet
expands it first ("pulled forward": the index joins that order's `done` list
and is skipped when its row-major cursor gets there). An order therefore acts
on each tile exactly as if every earlier order had already finished there --
a Cancel dragged over a Dig still filling in cancels the Dig's jobs, and a
Dig dragged after that Cancel is not cancelled by it.

**Judged when expanded.** Each tile is checked against the world at the
moment it is expanded, as a click at that moment would be. `cancel` records
the next job and site numbers at acceptance (`jobLimit`, `siteLimit`) and
never touches a job or site created after the order -- except the jobs an
earlier area order created since: while a later cancel is pending, each
expansion records the job numbers it created as `[first, end, order id]`
ranges (`created`), dropped once no cancel is pending. Area orders never
create construction sites.

**Saved and hashed.** A pending queue is part of `state_hash()` (an idle one
is left out, so a world that never used an area order hashes exactly as
before; its next order id is not observable outside the save), and the queue
is part of the save as
`areaOrders` (`{nextId, list, created}`, each entry carrying the next tile
index and its pulled-forward `done` indexes):
schemaVersion 25 -> 26, with an explicit migration that backfills an empty
queue. A save taken mid-expansion resumes at the same tile
(`test_area_orders.gd`).

## Alternatives considered

- **Keep one command per tile, only faster.** After B1's first two steps this
  is still ~6 s (Dig) / ~12 s (Cancel) of one frame for a whole map: the cost
  of 65,536 commands, not of any one of them.
- **Spread the per-tile commands in the viewer, a few per frame.** Not saved
  (a save mid-way loses the rest) and paced by frames, i.e. wall-clock;
  rejected by the backlog's own fix principle.
- **A batch submit that bypasses `apply()`** (check + submit per tile, one
  event for the whole order). About three times cheaper per tile, but a second
  path for the same rules and no per-tile events. Keeping `apply()` keeps
  one rule set; the per-tick budget absorbs the cost.
- **A larger budget (256 tiles per tick).** Measured at ~21 ms (Dig) and
  ~33 ms (Cancel) per tick on a 256x256 map, a dropped frame per tick; 128
  keeps a tick near 12 / 20 ms at the price of a slower fill (a whole map takes
  512 ticks, about 4 minutes at X1, while the colony already works the first
  rows).

## Consequences

- Releasing any drag costs at most one 128-tile step in that frame, plus at
  most one pulled-forward tile per earlier pending order for each of them.
- A large order's designations fill in row by row over the next ticks; the
  viewer's rejected-tiles text only lists tiles rejected at release, later
  rejections are their `command_rejected` events.
- `world_state.gd` gains the queue's wiring (seven lines) and stays at its
  line count; no core budget changes.
- New persisted state: `areaOrders` (schema 26), contract
  `docs/architecture/contracts/game-state.schema.json`, `save-system.md`,
  validator `SaveIO._valid_area_orders()`, migration
  `SaveMigrations._migrate_v25_to_v26()`, fixture and checks in
  `test_save_migration.gd`.

## Acceptance criteria

- [x] `docs/architecture/orders-and-movement.md` documents `area_order`.
- [x] Contract, validator, migration and fixture updated (schemaVersion 26).
- [x] `test_area_orders.gd`: a whole-map dig yields the per-tile path's dig
      jobs (count, targets, order); a save taken mid-expansion reloads and
      completes identically; budget, small rectangles and invalid payloads.
- [x] The source-of-truth index still points to the authoritative documents.
