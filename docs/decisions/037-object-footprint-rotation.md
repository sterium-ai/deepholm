# ADR 037: Object footprint, rotation, and multi-builder content fields

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** content (`objects.json`), simulation (`WorldState`), persistence
  (save schema, no migration step)
- **Revisits:** [ADR 005](005-tile-objects-schema-v4.md) decision point 1,
  "One object per tile"; objective #401, issue #405.

## Context

ADR 005 decided a tile holds at most one object and, in its own "Alternatives
considered", explicitly rejected letting one object span more than one tile,
deferring that to a future task with real content and test coverage behind
it. Issue #405 is that task: `content/objects.json` gains `footprint`
(`[w, h]`), `rotatable`, `build_ticks`, and `max_builders`, and the
debug/map-gen `place_object`/`remove_object` command path gains an optional
`orientation` so a kind declaring a footprint larger than `[1, 1]` can be
placed spanning several tiles.

## Decision

1. **Still one *logical* object per tile group -- multi-tile footprint, not
   stacking.** ADR 005's point 1 is revised, not reversed: a placed object
   with footprint `[w, h] != [1, 1]` occupies `w * h` tiles simultaneously,
   each carrying the exact same kind/faction/health, but it is still one
   object with one identity, one health pool, one faction. Two independent
   objects still cannot occupy the same tile -- footprint placement rejects
   on overlap with any existing object, tree, colonist, or water tile on
   *any* of its tiles, the same single-tile rule ADR 005 already established,
   just applied per footprint tile (`WorldState._check_place_object_command()`).
2. **Origin tile + orientation, not a duplicated record per tile, is the
   source of truth for identity.** `WorldState` tracks a placed object by its
   origin tile (the `(x, y)` passed to `_set_object()`/`place_object`) and an
   optional orientation (`"horizontal"`/`"vertical"`, meaningful only when the
   kind declares `rotatable: true`). Every occupied tile still duplicates
   kind/faction/health into `_objects`/`_object_factions`/`_object_health`
   (unchanged runtime shape, so `get_object(x, y)` and `passability(x, y)`
   need no footprint-aware branch of their own), but a new `_object_origin`
   map lets any occupied tile resolve back to its origin, so a
   `remove_object` or damage event aimed at a non-origin tile still resolves
   and clears/persists the *whole* object, not a partial footprint.
3. **Persisted as one record per object, not one per occupied tile.**
   `game-state.schema.json`'s `object` `$def` gains an optional
   `orientation` field (`""`, `"horizontal"`, or `"vertical"`; absent or an
   explicit `""` both mean `[1, 1]`/no rotation -- the encoder never writes
   `""` itself, but the schema and `SaveIO._valid_object()` accept it as
   identical to the field's absence, since it names the same default value,
   not a third state). `StateCodec._encode_objects()` writes exactly one
   record per origin tile; `_decode_objects()` plus `WorldState.
   _object_footprint_tiles()` re-expand it to every occupied tile on load.
   This keeps a save's `objects` array proportional to the number of placed
   objects, not the number of tiles they cover, and keeps a v25 save written
   before this task (no `orientation` field on any entry) loading unchanged
   -- optional fields never require a schema-version bump or migration step,
   the same precedent `objects[].health` (F5/#302) already set.
4. **Rotation swaps the declared footprint, nothing else.** `orientation:
   "vertical"` on a `rotatable` kind swaps `footprint`'s `[w, h]` to `[h, w]`
   before computing occupied tiles; a non-rotatable kind or an absent/
   `"horizontal"` orientation always uses the declared `[w, h]` as-is.
   Nothing in the footprint/orientation vocabulary reads a kind's `passable`,
   `is_door`, or health fields differently per occupied tile -- every tile of
   the footprint is identical, so no per-tile variant content is introduced.
5. **`build_ticks` and `max_builders` are inert data in this task.** Both
   fields are declared and schema-validated for every object (`wall`/`door`/
   `bed` set to today's `build` job's `work_ticks`, 40; every kind gets
   `max_builders: 1`), but no job-giver, toil, or the `build` order flow reads
   them yet -- wiring timed/multi-builder construction into the work engine
   is explicitly out of this task's scope (see the issue's Non-goals) and is
   deferred to a later task, exactly as ADR 005 deferred passability/commands
   to its own later tasks.
6. **The player-facing `build` flow is unchanged.** `_apply_build_submission()`
   and its `_check_build_command()` rule still only ever place a footprint
   `[1, 1]` object (every real content kind with a `build_cost` today
   declares `footprint: [1, 1]`); this ADR's footprint/orientation support is
   reachable only through the debug/map-gen `place_object` command until a
   later task extends `build` itself.

## Alternatives considered

- **A separate `footprints` collection keyed by origin, with `_objects`
  holding only the origin tile.** Rejected: `passability(x, y)` and
  `get_object(x, y)` are called per-tile from hot paths (route search,
  region/room invalidation) that must not need footprint-aware branching or
  an extra lookup indirection; duplicating into `_objects` keeps every
  existing single-tile reader correct with zero changes, which is also why
  every existing `wall`/`door`/`bed` test keeps passing unchanged.
- **Persist one record per occupied tile (today's shape) and let `decode()`
  deduplicate by origin.** Rejected: this is what the task explicitly asks
  the codec to stop doing -- a save's size would still scale with occupied
  tile count, not object count, and "one record per placed object" is easier
  to reason about and diff by hand.
- **Bump `schemaVersion` for the new optional `orientation` field.**
  Rejected: `orientation`'s absence is a fully truthful "no rotation" value
  for every save written before this task, the same reasoning that already
  kept `objects[].health` (F5/#302) and `route.rerouting` un-versioned.

## Consequences

- `game/content/objects.json` / `objects.schema.json`: every object
  declares `footprint`, `rotatable`, `build_ticks`, `max_builders`;
  `build_cost` keeps its existing (issue #403) list shape and requiredness.
  One test-only kind, `test_footprint_crate` (footprint `[2, 1]`,
  `rotatable: true`), is added for footprint test coverage the same way
  `test_multi_source_crate` already covers multi-source build costs.
- `game/scripts/core/world_state.gd`: `_objects`/`_set_object`/
  `get_object`/`get_objects`/`passability()` behave identically for every
  footprint-`[1, 1]` kind; `_set_object()` now also invalidates
  regions/rooms for every footprint tile, gains `_object_origin`/
  `_object_orientation` bookkeeping, and `_check_place_object_command()`
  (not `CommandChecks.check_place_object_command()`, outside this task's
  owned paths) validates a footprint's every tile.
- `docs/architecture/contracts/game-state.schema.json`: `object` `$def`
  gains optional `orientation` (`""`/`"horizontal"`/`"vertical"`); no
  `schemaVersion` change.
- `game/scripts/core/persistence/state_codec.gd` / `save_io.gd`:
  `_encode_objects()`/`_decode_objects()` work in origin records, not
  per-tile duplicates; `SaveIO._valid_object()` validates the new optional
  field.
- `docs/architecture/core-budgets.json`: `world_state.gd`'s cap raises to
  accommodate the footprint helpers and the new `_check_place_object_command()`.

## Acceptance criteria

- [x] `objects.schema.json` requires `footprint`/`rotatable`/`build_ticks`/
      `max_builders` on every object; `ContentRegistry` rejects a malformed
      row typed `schema_violation`.
- [x] A `[2, 1]` `horizontal` placement occupies both footprint tiles,
      reported by `get_object()` and independently impassable.
- [x] An overlapping tree/object/colonist/water tile on either footprint tile
      rejects with the exact single-tile `invalid_target`/`invalid_payload`
      reasons.
- [x] Region/room invalidation runs for every footprint tile
      (`test_regions.gd`).
- [x] A multi-tile object round-trips a save with an unchanged `state_hash()`;
      a same-schema-version save with no `orientation` field loads unchanged.
- [x] Existing `wall`/`door`/`bed` tests pass unchanged.
