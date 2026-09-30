# ADR 039: Object footprint, rotation, and multi-builder content fields

> **In short:** Objects can now be bigger than one tile, for example a two-tile crate, and can be turned sideways. Each such object is still saved and treated as a single thing.

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** content (`objects.json`), simulation (`WorldState`), persistence
  (save schema, no migration step).
- **Extends:** [ADR 005](005-tile-objects-schema-v4.md), revising its decision
  point 1, "One object per tile".

## Context

ADR 005 decided that a tile holds at most one object and, in its "Alternatives
considered", rejected letting one object span more than one tile until there
was real content and test coverage behind it. This change provides that:
`content/objects.json` gains `footprint` (`[w, h]`), `rotatable`,
`build_ticks`, and `max_builders`, and the debug/map-gen
`place_object`/`remove_object` command path gains an optional `orientation`,
so a kind declaring a footprint larger than `[1, 1]` can be placed spanning
several tiles.

## Decision

1. **Still one *logical* object per tile group: multi-tile footprints, not
   stacking.** ADR 005's point 1 is revised, not reversed. A placed object
   with footprint `[w, h] != [1, 1]` occupies `w * h` tiles at once, each
   carrying the same kind, faction, and health, but it is still one object
   with one identity, one health pool, and one faction. Two independent
   objects still cannot share a tile: footprint placement is rejected if
   *any* of its tiles overlaps an existing object, tree, colonist, or water
   tile, which is ADR 005's single-tile rule applied per footprint tile
   (`WorldState._check_place_object_command()`).
2. **The origin tile plus orientation, not a record per tile, is the source
   of truth for identity.** `WorldState` tracks a placed object by its origin
   tile (the `(x, y)` passed to `_set_object()`/`place_object`) and an
   optional orientation (`"horizontal"`/`"vertical"`, meaningful only when the
   kind declares `rotatable: true`). Every occupied tile still duplicates
   kind, faction, and health into `_objects`/`_object_factions`/`_object_health`
   (the runtime shape is unchanged, so `get_object(x, y)` and
   `passability(x, y)` need no footprint-aware branch), and a new
   `_object_origin` map resolves any occupied tile back to its origin. A
   `remove_object` or damage event aimed at a non-origin tile therefore still
   clears or persists the *whole* object, never a partial footprint.
3. **Persisted as one record per object, not one per occupied tile.**
   `game-state.schema.json`'s `object` `$def` gains an optional
   `orientation` field (`""`, `"horizontal"`, or `"vertical"`). Absent and
   `""` both mean `[1, 1]`/no rotation: the encoder never writes `""`, but the
   schema and `SaveIO._valid_object()` accept it as equivalent to absence,
   since it names the same default rather than a third state.
   `StateCodec._encode_objects()` writes exactly one record per origin tile;
   `_decode_objects()` plus `WorldState._object_footprint_tiles()` re-expand
   it to every occupied tile on load. A save's `objects` array stays
   proportional to the number of placed objects, not the tiles they cover,
   and a v25 save written before this change (no `orientation` on any entry)
   loads unchanged. Optional fields need no schema-version bump or migration
   step, the precedent `objects[].health` already set.
4. **Rotation swaps the declared footprint and nothing else.** `orientation:
   "vertical"` on a `rotatable` kind swaps `footprint`'s `[w, h]` to `[h, w]`
   before computing occupied tiles; a non-rotatable kind, or an absent or
   `"horizontal"` orientation, always uses the declared `[w, h]`. Nothing
   reads a kind's `passable`, `is_door`, or health fields differently per
   occupied tile: every footprint tile is identical, so no per-tile content
   variants are introduced.
5. **`build_ticks` and `max_builders` are inert data for now.** Both fields
   are declared and schema-validated for every object (`wall`, `door`, and
   `bed` use the `build` job's current `work_ticks`, 40, and every kind gets
   `max_builders: 1`), but no job-giver, toil, or the `build` order flow reads
   them yet. Wiring timed, multi-builder construction into the work engine is
   deferred to a later change, as ADR 005 deferred passability and commands.
6. **The player-facing `build` flow is unchanged.** `_apply_build_submission()`
   and its `_check_build_command()` rule still place only footprint-`[1, 1]`
   objects (every real content kind with a `build_cost` declares
   `footprint: [1, 1]`). Footprint and orientation support is reachable only
   through the debug/map-gen `place_object` command until `build` itself is
   extended.

## Alternatives considered

- **A separate `footprints` collection keyed by origin, with `_objects`
  holding only the origin tile.** Rejected: `passability(x, y)` and
  `get_object(x, y)` are called per tile from hot paths (route search,
  region/room invalidation) that must not need footprint-aware branching or
  an extra lookup. Duplicating into `_objects` keeps every existing
  single-tile reader correct with no changes, which is also why every
  existing `wall`/`door`/`bed` test keeps passing unchanged.
- **Persist one record per occupied tile (the previous shape) and let
  `decode()` deduplicate by origin.** Rejected: a save's size would still
  scale with occupied tiles rather than objects, and "one record per placed
  object" is easier to reason about and to diff by hand.
- **Bump `schemaVersion` for the new optional `orientation` field.**
  Rejected: absence of `orientation` is a truthful "no rotation" for every
  save written before this change, the same reasoning that kept
  `objects[].health` and `route.rerouting` unversioned.

## Consequences

- `game/content/objects.json` / `objects.schema.json`: every object
  declares `footprint`, `rotatable`, `build_ticks`, and `max_builders`;
  `build_cost` keeps its list shape and remains required. One test-only kind,
  `test_footprint_crate` (footprint `[2, 1]`, `rotatable: true`), provides
  footprint test coverage, as `test_multi_source_crate` does for multi-source
  build costs.
- `game/scripts/core/world_state.gd`: `_objects`, `_set_object`,
  `get_object`, `get_objects`, and `passability()` behave identically for
  every footprint-`[1, 1]` kind. `_set_object()` now also invalidates regions
  and rooms for every footprint tile and maintains `_object_origin`/
  `_object_orientation`, and `_check_place_object_command()` (rather than
  `CommandChecks.check_place_object_command()`, which is unchanged) validates
  every tile of a footprint.
- `docs/architecture/contracts/game-state.schema.json`: the `object` `$def`
  gains optional `orientation` (`""`/`"horizontal"`/`"vertical"`); no
  `schemaVersion` change.
- `game/scripts/core/persistence/state_codec.gd` / `save_io.gd`:
  `_encode_objects()`/`_decode_objects()` work with origin records rather
  than per-tile duplicates, and `SaveIO._valid_object()` validates the new
  optional field.
- `docs/architecture/core-budgets.json`: `world_state.gd`'s cap is raised
  to accommodate the footprint helpers and the new
  `_check_place_object_command()`.

## Verification

- `objects.schema.json` requires `footprint`, `rotatable`, `build_ticks`, and
  `max_builders` on every object, and `ContentRegistry` rejects a malformed
  row with the typed reason `schema_violation`.
- A `[2, 1]` `horizontal` placement occupies both footprint tiles; each is
  reported by `get_object()` and is independently impassable.
- An overlapping tree, object, colonist, or water tile on either footprint
  tile is rejected with the same `invalid_target`/`invalid_payload` reasons
  as a single-tile placement.
- Region and room invalidation runs for every footprint tile
  (`test_regions.gd`).
- A multi-tile object round-trips a save with an unchanged `state_hash()`,
  and a same-schema-version save with no `orientation` field loads unchanged.
- Existing `wall`/`door`/`bed` tests pass unchanged.
