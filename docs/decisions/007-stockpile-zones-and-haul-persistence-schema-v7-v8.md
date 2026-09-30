# ADR 007: Stockpile zones and haul persistence, schemaVersion 7-8

> **In short:** Players can mark storage areas on the map, and colonists carry loose items there; both the storage areas and the carrying jobs are kept in save files.

- **Status:** accepted
- **Date:** 2026-09-18
- **Scope:** simulation (`WorldState`, `JobQueue`, `ToilExecutor`,
  `ReservationTable`), persistence (save schema and migration)
- **Implements:** [ADR 003](003-scheduling-explainability-save-integrity-mobile-first.md),
  principle 3 (save integrity is a named strategy).
- **Extends:** [ADR 006](006-items-with-ids-and-carrying-schema-v6.md), which
  deferred stockpile zones, the haul job kind, and their viewer support.

## Context

ADR 006 gave ground wood a first-class item identity (`{id, x, y, kind,
count}`) specifically so a later stockpile zone and haul job kind would have
something with an id to reserve, but deferred both. The follow-up work
built exactly that: player-drawn rectangular stockpile zones
(`zone_add`/`zone_remove`) and a `haul` job kind that carries an item to a
free zone cell through the same generic toil vocabulary dig/chop already
used, plus a doubling backoff so a permanently-blocked haul job cannot
monopolize the global scheduler. Both are new persisted, public data shapes
— `game-state.schema.json` and the save envelope change twice more (schema
7 for zones, schema 8 for haul job fields) — so per `AGENTS.md` ("update the
relevant contract, schema, example, test, and a short numbered ADR when the
decision crosses a boundary") this needs a numbered ADR, matching the one
ADR 005 wrote for schema 4 and ADR 006 wrote for schema 6.

This ADR was written retroactively, alongside the viewer and documentation
changes, after the zone and haul code had already shipped
(`content/jobs.json`, `WorldState`'s zone/haul code, `save_migrations.gd`'s
v6->v7 and v7->v8 steps, `game-state.schema.json`'s `schemaVersion: 8`). It
records the decision `docs/decisions/` was missing for that code, the gap
`docs/architecture/source-of-truth.yaml`'s "check `docs/decisions/` before
proposing architecture" rule exists to catch.

## Decision

1. **One `ReservationTable`, namespaced by prefix, not a new ledger per
   concept.** A haul job's source item and destination cell are reserved
   as `item:<item_id>` and `cell:x,y` keys on the exact same
   `ReservationTable` dig/chop's `tile:x,y` keys already use, acquired
   together before the job goes active and released together by
   `release_all` on every terminal transition. This avoids inventing a
   second reservation mechanism only for haul.
2. **Job kinds become content, not a branch per kind.** `content/jobs.json`
   declares each kind's fixed toil sequence (`{kind, labour, toils: [...]}`);
   `ToilExecutor` implements the six-toil vocabulary (`reserve`, `go_to`,
   `pick_up`, `work`, `place`, `release_all`) once. Adding `haul` needed no
   new per-kind branch in the toil stepping itself, only `WorldState`'s
   own haul-specific two-leg travel orchestration (leg one to the item, leg
   two to the reserved cell) and completion effect, since haul has no
   `work` phase and its second leg targets a different destination than its
   `target` field.
3. **Zones are player-drawn rectangles, applied immediately.** `zone_add`/
   `zone_remove` mirror `place_object`/`remove_object`'s "no job queue,
   validated and applied the same tick" shape rather than going through the
   job queue themselves. `WorldState._find_free_haul_cell()` scans zones in
   id then row-major cell order for deterministic destination assignment.
4. **A haul job with no free destination backs off instead of retrying
   every tick.** `HAUL_RETRY_BASE_TICKS`/`HAUL_RETRY_CAP_TICKS` (10/40,
   doubling) are injected into `JobQueue` the same way `MOVE_TICKS_PER_TILE`/
   `WORK_TICKS` are injected into `ToilExecutor` — named constants owned by
   `WorldState`, not hard-coded a second time. A backed-off job still reports
   as reserved through `get_reservations()` so ADR 004's global scheduler
   pre-scoring exclusion skips it without spending a route-search slot.
5. **schemaVersion bumps 6 -> 7 -> 8, as two separate steps.** Version 7
   adds `zones`/`nextZoneId` (stockpile zones alone, no haul job fields yet);
   version 8 adds every job's `itemId`/`cell`/`retryAt`/`backoffTicks`
   (haul alone, zones already in place). Splitting the two increments this
   way — rather than one combined schema 6 -> 7 bump — keeps each migration
   step's truthful-backfill story (see below) about exactly one new concept,
   matching every prior single-concept schema bump in this codebase (schema
   4: objects; schema 5: rerouting; schema 6: items/carrying).
6. **Explicit v6->v7 and v7->v8 migrations.** A version-6 save predates
   zones entirely: no zone could ever have been drawn, so `zones: []` and
   `nextZoneId: 1` are the truthful backfill, not an inferred default. A
   version-7 save predates the haul job kind: no job could ever have been a
   haul job, so every existing job gains `itemId: ""`, `cell: null`,
   `retryAt: 0`, `backoffTicks: 0` — `JobQueue.submit_dig()`'s own harmless
   defaults for a job that was never attached to an item or a reserved
   cell. Both follow the same explicit, chained, non-mutating migration
   pattern already used for v1->v6 in `save_migrations.gd`.

## Alternatives considered

- **A single combined schema 6 -> 7 bump for zones and haul together.**
  Rejected: it would couple two independently-shippable concepts (a zone
  can exist with no haul job kind yet reading it) into one migration step
  and one truthful-backfill story, breaking the "one concept per schema
  bump" pattern every earlier ADR in this codebase already established.
- **A separate reservation table for item/cell keys, distinct from the
  tile-keyed one dig/chop use.** Rejected: `ReservationTable` is already a
  generic String-keyed ledger with no built-in notion of what a key means —
  adding a second instance would only duplicate `acquire`/`release`/
  `release_all`/`snapshot` logic for no behavioral gain, and namespaced
  prefixes already guarantee `tile:`/`item:`/`cell:` keys never collide.
- **Retry a blocked haul job every tick, like dig/chop's blocking reasons.**
  Rejected: unlike a dig/chop target (which either frees up or stays
  reserved), a haul job with no zone at all can stay permanently blocked;
  retrying it every tick would compete for a route-search slot forever and
  risk starving unrelated jobs under ADR 004's bounded per-tick work,
  motivating the backoff instead.

## Consequences

- `docs/architecture/contracts/game-state.schema.json`: `schemaVersion`
  const is `8`; `zones`/`nextZoneId` and every job's `itemId`/`cell`/
  `retryAt`/`backoffTicks` are new required shapes (already applied to the
  schema file by the implementation this ADR documents).
- `docs/architecture/save-system.md` documents schema version 8 as current,
  the v6->v7 and v7->v8 migrations, and the `zones`/haul-job-field wire
  shapes.
- `docs/architecture/orders-and-movement.md` gains a "Jobs, toils and
  reservations" section documenting the six-toil vocabulary,
  `content/jobs.json`'s shape, the `ReservationTable`'s key domains, the
  zone commands, and the backoff constants.
- `game/scripts/core/jobs/reservation_table.gd`, `toil_executor.gd`,
  `job_queue.gd`, and `game/scripts/core/world_state.gd` already carry the
  zone/haul implementation this ADR records; no simulation code changes with
  this ADR itself.
- `game/scripts/viewer/`: the viewer's zone-drawing tool, carried-item
  marker, stockpile-count rendering, and colonist panel toil display are the
  presentation-layer consequence of this decision, delivered alongside this
  ADR.

## Acceptance criteria

- [x] `game-state.schema.json` requires `zones`/`nextZoneId` and every job's
      `itemId`/`cell`/`retryAt`/`backoffTicks`, and fixes `schemaVersion` at
      `8`.
- [x] `save-system.md` documents schema versions 7 and 8, the `zones` and
      haul-job-field shapes, and both migrations.
- [x] `orders-and-movement.md` documents the toil vocabulary,
      `content/jobs.json`, `ReservationTable` key domains, zone commands,
      and backoff constants.
- [x] `save_migrations.gd` implements explicit, non-mutating v6->v7 and
      v7->v8 steps, exercised by fixtures in `test_save_migration.gd`.
- [x] `test_zone_commands.gd` and `test_haul_stockpile.gd` cover zone
      add/remove validation, the shared cell reservation, haul completion,
      mid-carry cancellation, destination-removed failure, and backoff
      interval growth.
