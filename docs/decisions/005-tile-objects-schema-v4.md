# ADR 005: Persisted tile objects and schemaVersion 4

- **Status:** accepted
- **Date:** 2026-09-18
- **Scope:** simulation (`WorldState`), persistence (save schema and migration)
- **Implements:** [ADR 003](003-scheduling-explainability-save-integrity-mobile-first.md),
  principle 3 (save integrity is a named strategy); objective #176.

## Context

Objective #176 asks for placeable tile objects (chair, door, wall, table) as
declared content, with `WorldState` tracking which tile carries which object.
This is a new persisted, public data shape: `game-state.schema.json` and the
save envelope both change, so per `AGENTS.md` ("update the relevant contract,
schema, example, test, and a short numbered ADR when the decision crosses a
boundary") the decision needs a numbered ADR, not just an implementation.

## Decision

1. **One object per tile.** `WorldState` stores at most one object kind per
   `(x, y)` tile, mirroring the existing `_ground_items` map rather than
   introducing a second, differently-shaped collection. There is no stacking
   or multi-object tile in this task; a future task that needs more than one
   occupant per tile must revisit this ADR.
2. **Content-declared kinds.** Valid object kinds are declared in
   `game/content/objects.json`, each with `passable`, `move_cost`, and
   `is_door`, matching the vocabulary in
   [`colonist-ai.md`](../architecture/colonist-ai.md) section 3.5. This task
   only declares the content; no passability/cost function or renderer reads
   these fields yet (deferred to tasks t2 and t6).
3. **Detached accessors.** `WorldState` exposes `get_object(x, y) -> String`
   (`""` for no object) and `get_objects() -> Array[Dictionary]` (copies of
   `{x, y, kind}`), the same read shape already used for ground items, so
   callers cannot mutate simulation state through a returned reference.
4. **schemaVersion bumps 3 -> 4.** The persisted save gains a top-level
   `objects` array in the same `{target: {x, y}, kind}` shape as
   `groundItems`. `state_hash()` includes the objects map, so a save/load
   round trip and a diagnostic hash both change when a tile object is added
   or removed.
5. **Explicit v3->v4 migration.** A version-3 save is migrated to version 4
   by backfilling `objects: []`. Version 3 predates placeable objects, so no
   tile could ever have carried one — an empty array is the truthful value,
   not an inferred default. This follows the same explicit, chained,
   non-mutating migration pattern already used for v1->v2 and v2->v3 in
   `save_migrations.gd`, restated in
   [`save-system.md`](../architecture/save-system.md).

## Alternatives considered

- **Store objects as a per-entity list instead of a per-tile map.** Rejected:
  objects are static map furniture, not entities with behavior; a per-tile
  map matches how tiles and ground items are already modeled and keeps
  lookup by position O(1).
- **Allow multiple objects per tile now, anticipating future stacking.**
  Rejected: nothing in objective #176 or `colonist-ai.md` 3.5 asks for
  stacking, and speculative multi-occupancy would force route/passability
  code (task t2) to handle a case with no current content or test coverage.
- **Skip the schema/version bump and treat `objects` as an optional field.**
  Rejected: `save-system.md` and ADR 003 already forbid silently defaulting a
  missing required field; an optional field would let an old save silently
  claim tiles have no objects instead of an explicit, tested migration step.

## Consequences

- `docs/architecture/contracts/game-state.schema.json`: `schemaVersion` const
  is `4`; `objects` is a new required top-level array, sibling to
  `groundItems`.
- `docs/architecture/save-system.md` documents `schemaVersion` 4 as current,
  the v3->v4 migration, and the `objects` field and its accessors.
- `game/scripts/core/world_state.gd` and
  `game/scripts/core/persistence/state_codec.gd` gain the objects map,
  its encode/decode, and its contribution to `state_hash()`.
- `game/scripts/core/persistence/save_migrations.gd` gains the v3->v4 step;
  `test_save_migration.gd` gains a schemaVersion-3 fixture covering it.
- No passability/movement-cost function, `place_object`/`remove_object`
  commands, route search, or renderer change is introduced by this ADR; they
  are explicitly deferred to tasks t2, t5, and t6.

## Acceptance criteria

- [x] `game-state.schema.json` requires `objects` and fixes `schemaVersion`
      at `4`.
- [x] `save-system.md` documents schema version 4, the `objects` field, and
      the v3->v4 migration.
- [x] `save_migrations.gd` implements an explicit, non-mutating v3->v4 step
      backfilling `objects: []`, exercised by a schemaVersion-3 fixture in
      `test_save_migration.gd`.
- [x] `WorldState.get_object()`/`get_objects()` return detached copies and
      `state_hash()` changes when an object is added, covered by
      `test_object_storage.gd`.
