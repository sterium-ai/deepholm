# ADR 042: `build_line` submits a whole wall/rectangle drag as one atomic command

> **In short:** When the player drags out a wall or a rectangle, the whole shape is now ordered in one step. Blocked tiles are simply skipped, and if the shape would trap someone, the order is refused as a whole instead of leaving a gap.

- **Status:** accepted
- **Date:** 2026-09-26
- **Scope:** a new `build_line` command (`game/scripts/core/world_state.gd`),
  `docs/architecture/core-budgets.json`'s cap for `world_state.gd`.

## Context

`build` (ADR 040) submits exactly one construction site per command. Without
a batch command, drawing a wall line or a rectangle by dragging the cursor
would make the UI submit one `build` command per tile, with
`WorldState.tick()` able to run between them. Two problems follow. First,
the enclosure check (`_would_enclose_tiles()`) sees only one candidate tile at
a time, so for a drag that seals a room only when the *whole* line is placed,
it would accept every tile individually until the last one, which alone would
be rejected with `blocked_target_unreachable`. An order the player intended as
one shape becomes "n-1 walls built, one gap" instead of "all n, or a clear
reason why not". Second, a caller-ordered tile list has no canonical order:
two UIs (or a test) dragging the same rectangle in different scan orders must
still produce the same set of construction sites.

## Decision

**`build_line` is one command carrying a whole tile set, not a batch of
individual `build` commands.** Payload: `{kind: string, tiles: [{x: int, y:
int}, ...], orientation: string}`, where `orientation` is optional and means
the same as in `build`. `WorldState._classify_build_line_command()` is the
single read-only rule shared by `apply()` (via `_apply_build_line_command()`)
and `preview()`, and runs in this fixed order:

1. **Payload validation** (`invalid_payload`): a non-string, empty, or unknown
   `kind`; a `kind` without `build_cost`; a malformed `orientation`; a
   non-array or empty `tiles`; or any tile entry missing integer `x`/`y`.
2. **Canonicalization**: `tiles` is de-duplicated and sorted into row-major
   order (lowest `y`, then lowest `x`). The command never trusts caller order,
   so the same tile set always produces the same site ids and positions
   regardless of drag direction or scan order. De-duplication is needed
   because a repeated tile in the caller's list would otherwise pass
   classification twice (no reservation is taken at this stage) and create
   two overlapping sites at the same origin in step 5.
3. **Per-tile occupancy classification, not per-tile rejection**: each
   canonical tile runs the same single-tile footprint and occupancy rule as
   `_apply_construction_submission()` (factored into
   `_construction_footprint_check()`, shared by both): in bounds, passable
   for the kind, not a colonist's tile, not a tree tile, not already an
   object, not already claimed. The enclosure check is *excluded* here. A
   tile that fails moves to a `skipped` list (`{x, y, reason}`, with the
   reason the single-tile command would have returned) instead of rejecting
   the whole command. For a `kind` wider than one tile (e.g. `workbench`'s
   `[2, 1]` footprint), each candidate's footprint is also checked against
   the footprints already claimed by *earlier* surviving candidates in the
   same batch (`claimed_footprint` in `_classify_build_line_command()`).
   Without this, two origins whose footprints overlap (e.g. `(10,10)` and
   `(11,10)`, sharing `(11,10)`) would each pass
   `_construction_footprint_check()`, since neither reservation exists yet
   during classification, and both would create sites competing for the same
   tile in step 5. Only the row-major first survives; the later one is skipped
   with `invalid_target`, the reason a real reservation conflict returns.
4. **One enclosure check across the whole surviving set.** This applies only
   when `kind` is impassable: `_would_enclose_tiles()` runs once, treating
   every surviving tile's footprint as one hypothetical placement. If it would
   strand any currently reachable tile, the **entire command** is rejected
   with `blocked_target_unreachable`: no sites are created, no reservations
   are taken, and the `skipped` list from step 3 is discarded. This is the
   atomicity rule the command exists for: a line's enclosure effect is a
   property of the whole shape, not of any one tile, so it can only be judged
   once every tile's occupancy is known. `_would_enclose_tiles()`'s per-actor
   baseline (`before.size() - tiles.size()`, originally written for a single
   kind's always-reachable footprint) is counted per reachable component
   rather than over the whole candidate set, because `build_line` can submit
   tiles in components that were never connected. With whole-set subtraction,
   a candidate beside a reachable colonist plus an isolated one-tile candidate
   elsewhere under-counted and missed a real enclosure. Each component's
   baseline now subtracts only the candidate tiles its flood fill reached.
5. **Otherwise, one site per surviving tile**, created in row-major order
   exactly as `_apply_construction_submission()` does for a single tile
   (footprint reservation on the shared `ReservationTable` with owner
   `"site:<id>"`, then `ConstructionSiteTable.create()`). The command returns
   `{ok: true, sites: [{id, x, y}, ...], skipped: [...]}`.

**Atomicity covers enclosure and reservation-taking, not occupancy.** An
occupied tile mid-line does not fail the batch: it is reported in `skipped`
and every other tile still gets a site, matching the player's expectation
that a drag places a wall on every clear tile in its path. What *is*
all-or-nothing is the enclosure verdict and the resulting reservations: either
every surviving tile gets a site and a reservation or, on enclosure, none do.
No partial reservation state is left for the caller to reconcile.

**No new job, toil, or job-giver.** Every site `build_line` creates is
mechanically identical to one created by `build` (same `ConstructionSiteTable`
record shape, same `ConstructionGiver` fetch and work scheduling, same
`cancel_site` teardown). This uses the "command handlers are ordinary
WorldState orchestration" extension point
([extension-points.md](../architecture/extension-points.md)), not a new
decision layer.

## Alternatives considered

- **Have the caller submit a loop of individual `build` commands.** Rejected:
  this is the split-drag problem described above. The enclosure check would
  only ever see one tile, accepting a line that seals a room until its last
  tile, and a caller-ordered submission has no canonical result.
- **Reject the whole command on any occupied tile** instead of skipping it.
  Rejected: a rectangle that includes an occupied tile should create sites for
  every other tile, matching the intuitive drag behaviour of building around an
  obstacle rather than failing the entire selection over one blocked cell.
- **Re-run the enclosure check per surviving tile instead of once across the
  set.** Rejected: `_would_enclose_tiles()` already accepts an arbitrary tile
  list (built for a single kind's multi-tile footprint, e.g. `workbench`).
  Checking the whole surviving batch at once is cheaper (one flood fill instead
  of N) and correct for a line whose enclosure effect exists only once every
  tile is placed together; checking tiles individually would miss exactly the
  case this command exists to handle.

## Consequences

- `game/scripts/core/world_state.gd`: 4760 -> 4905 lines (+145) for
  `_construction_footprint_check()` (factored out of
  `_check_construction_command()`, with no behaviour change to `build`),
  `_classify_build_line_command()`, `_apply_build_line_command()`, the
  `build_line` and preview dispatch wiring, `claimed_footprint` overlap
  tracking, and `_would_enclose_tiles()`'s per-component candidate count.
  `_validate_command()`'s generic payload-value check (String/int only) gains
  one narrowly scoped exception for `build_line`'s `tiles` array. The cap is
  raised from 4765 to 4930 for headroom.
- `game/scripts/tests/test_wall_orders.gd` (new) covers: line and rectangle
  site creation and row-major ordering; occupied-tile skipping; whole-batch
  enclosure rejection with zero sites and reservations; per-site `cancel_site`
  releasing only its own material, with `cancel_site` over every site in a
  line leaving `ReservationInvariants.find_orphaned_reservations()` empty; an
  in-batch overlapping-footprint regression (horizontal and vertical
  `workbench`, covering preview parity, reservation ownership, and
  cancellation); and a disconnected-component enclosure regression.
- No `content/*.json`, save-schema, or toil-vocabulary change: once created,
  a site from `build_line` is indistinguishable from one created by `build`.

## Known limitations

- A colonist still fetches material per site (one `site_fetch`/`site_work`
  job pair per construction site). Chaining one haul trip across several
  sites in the same line was left to a follow-up
  ([ADR 043](043-site-fetch-chained-deposit.md)).
- There is no tile-count cap: a very large drag creates proportionally many
  sites and reservations in one command.
