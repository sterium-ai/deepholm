# ADR 040: `build_line` submits a whole wall/rectangle drag as one atomic command

- **Status:** accepted
- **Date:** 2026-09-26
- **Scope:** a new `build_line` command (`game/scripts/core/world_state.gd`),
  `docs/architecture/core-budgets.json`'s cap for `world_state.gd`.
- **Implements:** issue #450 (objective #420, issue #449's follow-on).

## Context

`build` (ADR 038) submits exactly one construction site per command. Drawing a
wall line or a rectangle of floor tiles by dragging the cursor means the UI
would otherwise submit one `build` command per tile, each independently
racing `WorldState.tick()` in between. Two problems follow directly from
that: the enclosure check (`_would_enclose_tiles()`) only ever sees one
candidate tile at a time, so a drag that seals a room only when its *whole*
line is placed would incorrectly accept every tile individually right up
until the very last one, which alone would be rejected
`blocked_target_unreachable` — an order the player clearly intended as one
shape gets split into "n-1 walls built, one gap" instead of "all n, or a
clear rejection why not." And a caller-ordered tile list has no canonical
order at all: two different UIs (or a test) dragging the same rectangle in a
different scan order must still produce the same set of construction sites.

## Decision

**`build_line` is one command carrying a whole tile set, not a batch of
individual `build` commands.** Payload: `{kind: string, tiles: [{x: int, y:
int}, ...], orientation: string}` — `orientation` is optional, identical
meaning to `build`'s. `WorldState._classify_build_line_command()` is the
single read-only rule shared verbatim by `apply()` (via
`_apply_build_line_command()`) and `preview()`, run in this fixed order:

1. **Payload validation** (`invalid_payload`): a non-string/empty/unknown
   `kind`, a `kind` missing `build_cost`, a malformed `orientation`, a
   non-array or empty `tiles`, or any tile entry missing integer `x`/`y`.
2. **Canonicalization**: `tiles` is de-duplicated and sorted into row-major
   order (lowest `y`, then lowest `x`) — the command never trusts caller
   order, so the same tile set always produces the same site ids/positions
   regardless of drag direction or scan order. De-duplication exists because
   an accidental repeat in the caller's own list would otherwise pass
   classification twice (no reservation is taken yet at this stage) and go on
   to create two overlapping sites at the same origin in step 5.
3. **Per-tile occupancy classification, not per-tile rejection**: each
   canonical tile runs the exact single-tile footprint/occupancy rule
   `_apply_construction_submission()` already runs (now factored into
   `_construction_footprint_check()`, shared by both) — in-bounds,
   passable-for-kind, not a colonist's own tile, not a tree tile, not already
   an object, not already claimed — EXCLUDING the enclosure check. A tile that
   fails moves to a `skipped` list (`{x, y, reason}`, the same reason string
   the single-tile command would have returned for it) instead of rejecting
   the whole command. A `kind` wider than one tile (e.g. `workbench`'s `[2,
   1]` footprint) additionally checks each candidate's footprint against
   every EARLIER surviving candidate's own claimed footprint in this same
   batch (`claimed_footprint` in `_classify_build_line_command()`): two
   origins whose footprints overlap (e.g. `(10,10)` and `(11,10)`, sharing
   `(11,10)`) would otherwise both individually pass
   `_construction_footprint_check()` — neither one's reservation exists in
   the table yet during classification — and both survive to create two
   sites that fight over the same tile in step 5. Only the row-major first of
   the two survives; the later one is skipped `invalid_target`, the same
   reason a real reservation conflict already returns (round 1 review
   finding: two horizontal workbenches at `(10,10)`/`(11,10)`).
4. **One enclosure check across the whole surviving set.** Only meaningful
   when `kind` is impassable: `_would_enclose_tiles()` runs once, treating
   every surviving tile's footprint together as one hypothetical placement.
   If it would strand any currently-reachable tile, the **entire command** is
   rejected `blocked_target_unreachable` — no sites are created, no
   reservations are taken, and the `skipped` list from step 3 is discarded.
   This is the atomicity rule the command exists for: a line's enclosure
   effect is a property of the whole shape, not any one tile in it, so it can
   only be judged once every tile's occupancy is already known.
   `_would_enclose_tiles()`'s per-actor baseline (`before.size() -
   tiles.size()`, previously written for a single kind's own, always-
   reachable footprint) is counted per reachable component, not over the
   whole candidate set: `build_line` can submit tiles spanning components
   that were never connected (round 1 review finding: a candidate beside a
   reachable colonist plus an isolated, disconnected one-tile candidate
   elsewhere made the old whole-set subtraction under-count and miss a real
   enclosure). Each component's own baseline now subtracts only the
   candidate tiles that component's flood fill actually reached.
5. **Otherwise, one site per surviving tile**, created in the same row-major
   order, exactly as `_apply_construction_submission()` does for a single
   tile (footprint reservation on the shared `ReservationTable`, owner
   `"site:<id>"`, then `ConstructionSiteTable.create()`). The command returns
   `{ok: true, sites: [{id, x, y}, ...], skipped: [...]}`.

**Atomicity is scoped to enclosure and reservation-taking, not to occupancy.**
An occupied tile mid-line does not fail the batch — it is reported in
`skipped` and every other tile still gets a site, matching a player's
intuition that a drag places a wall on every clear tile in its path. What
*is* all-or-nothing is the enclosure verdict and the resulting reservations:
either every surviving tile gets a site and a reservation, or (on enclosure)
none of them do. No partial reservation state is ever left behind for the
caller to reconcile.

**No new job, toil, or job-giver.** Every site `build_line` creates is
mechanically identical to one `build` created (same `ConstructionSiteTable`
record shape, same `ConstructionGiver` fetch/work scheduling, same
`cancel_site` teardown) — this is the "command handlers are ordinary
WorldState orchestration" extension point
(`docs/architecture/extension-points.md`), not a new decision layer. A
colonist still fetches and delivers material one site at a time; chaining
hands across sites in one trip is explicitly deferred (issue #450's
Non-goals, t3).

## Alternatives considered

- **Submit `build_line` as a loop of individual `build` commands from the
  caller.** Rejected: this is exactly the split-drag problem above — the
  enclosure check would only ever see one tile, silently accepting a line
  that seals a room until its very last tile, and a caller-ordered submission
  has no canonical result.
- **Reject the whole command on any occupied tile**, rather than skipping it.
  Rejected: acceptance explicitly requires "a rectangle including an occupied
  tile creates sites for every other tile," matching the intuitive drag
  behavior of building around an obstacle rather than failing the entire
  selection over one blocked cell.
- **Re-run the enclosure check per surviving tile instead of once across the
  set.** Rejected: `_would_enclose_tiles()` already accepts an arbitrary tile
  list (built for a single kind's multi-tile footprint, e.g. `workbench`);
  checking the whole surviving batch at once is both cheaper (one flood fill
  instead of N) and correct for a line whose enclosure effect only exists
  once every tile is placed together — checking tiles individually would miss
  exactly the case this command exists to handle.

## Consequences

- `game/scripts/core/world_state.gd`: 4760 -> 4905 lines (+145):
  `_construction_footprint_check()` (factored out of
  `_check_construction_command()`, no behavior change to `build`),
  `_classify_build_line_command()`, `_apply_build_line_command()`, and the
  `build_line`/preview dispatch wiring, plus the round-1 review fixes above
  (`claimed_footprint` overlap tracking and `_would_enclose_tiles()`'s
  per-component candidate count). `_validate_command()`'s generic
  payload-value check (String/int only) gains one narrowly-scoped exception
  for `build_line`'s own `tiles` array field. Cap raised 4765 -> 4930 for
  headroom.
- `game/scripts/tests/test_wall_orders.gd` (new): line/rectangle site
  creation and row-major ordering, occupied-tile skipping, whole-batch
  enclosure rejection with zero sites/reservations, per-site `cancel_site`
  releasing only its own material while looping it over every site in a line
  leaves `ReservationInvariants.find_orphaned_reservations()` empty, an
  in-batch overlapping-footprint regression (horizontal and vertical
  `workbench`, covering preview parity, reservation ownership and
  cancellation), and a disconnected-component enclosure regression.
- No `content/*.json`, save-schema, or toil-vocabulary change: every site
  `build_line` creates is indistinguishable, once created, from one `build`
  created.

## Known limitations

- A colonist still fetches material per-site (one `site_fetch`/`site_work`
  job pair per construction site); chaining a single haul trip across several
  sites in the same line is deferred to a follow-up (issue #450's Non-goals,
  t3).
- No tile-count cap. None is required by this task's acceptance and none is
  invented; a very large drag creates proportionally many sites and
  reservations in one command.
