# ADR 058: Save pipeline: one pass, compact wire encoding, saved route costs, writes off the main thread

> **In short:** A save is now packed into a compact file encoding (tiles as a palette plus
> runs, route searches as base64 bitsets and arrays, long record lists as tables),
> stringified once and hashed once, and the file work runs on a worker thread. An in-flight
> route search also saves its accumulated costs, so after a load it continues exactly as it
> would have, even across a map change. Save schema v5, with a migration from v4.
> `WorldState.dispose()` frees a world that is being replaced.

- **Status:** accepted
- **Date:** 2026-10-29
- **Scope:** persistence (`persistence/save_io.gd`, new `save_wire.gd` and `save_write.gd`,
  `save_manager.gd`, `scheduling_codec.gd`, `save_migrations.gd`, `StateCodec.SCHEMA_VERSION`
  5, `save-system.md`, `game-state.schema.json`), simulation (`routing/route_search.gd`
  snapshot and restore, `WorldState.dispose()` with `world/world_disposer.gd`)
- **Depends on:** ADR 003 (versioned saves), ADR 049 (schema reset), ADR 053 (v2), ADR 010
  amendment 2 (v3), ADR 057 (v4), ADR 054 (A* route search)
- **Implements:** BACKLOG A7; foundation audit §4.4 (route cost rebuild) and the
  `bench_save_load` findings

## Context

`bench_save_load` at 1,000 actors (baseline, `bench-baseline.md`): 1,408 KB file,
`write_atomic()` 1,744 ms, all of it on the main thread. `write_atomic()` stringified the
state three times and parsed it once to compute an integrity hash that `read()` could
reproduce; `map.tiles` was 450 KB of repeated tile ids; route searches were lists of
`{"x", "y"}` objects. A dropped `WorldState` was never freed (111 to 156 objects per world
kept alive by Callable cycles).

`RouteSearch.restore()` rebuilt each visited tile's accumulated cost `g` from the current map
(`_rebuild_costs()`). A search spans many ticks, and the map can change in between: a tile
visited before the change then gets its new cost on load while the uninterrupted search keeps
the old one, the frontier is pushed with other priorities and the loaded game diverges.

The "one ContentRegistry per session" part of the A7 entry was done by A13b.

## Decision

1. **Saved route costs.** `RouteSearch.snapshot()` adds `cost` (tile -> `g` of every visited
   tile) and `restore()` takes it as it was. `_rebuild_costs()` remains only for a state
   without `cost` (a v4 save or older). The plain route state gains an optional `cost` array in
   `visited` order; `state_hash()` covers it through the snapshot.
2. **Wire encoding (`SaveWire`).** `SaveIO` packs the plain state right before its one
   `JSON.stringify` and unpacks it right after the parse, so `StateCodec`, the validators and
   `game-state.schema.json` keep describing the plain state. Packed: `map.tiles` to `palette`
   plus `tileRuns`; route searches to `box`, `visitedBits`, `cameFromDirs` (2-bit direction
   per visited tile), `costBytes` (float64) and `frontierTiles` (int32 tile indices), base64;
   `entities`, `jobs` and `scheduling.waiting` to a record table (`{"$keys": [...]}` then one
   row per record). The packer leaves anything it cannot restore exactly in the plain form
   and the reader accepts the plain form of every packed field. Costs are the only floats in
   the state and never appear as JSON numbers. A packed map larger than the session's
   `max_world_size` is refused before any tile is expanded (`test_save_wire.gd`).
3. **One pass.** The integrity hash is the SHA-256 of the state text exactly as written; the
   envelope is assembled around that text. `read()` hashes the raw `state` span located by
   `SaveJsonInts`, and falls back to the pre-A7 rule (hash of `JSON.stringify` of the parsed
   state) for files written that way.
4. **Off the main thread.** `SaveIO.begin_write()` packs and stringifies on the calling
   thread and hands the text, the path and a plain copy of the session registry's version,
   packs and whitelists (`content_check()`) to a `SaveWrite` thread, which hashes, writes,
   reads back and renames. The worker never sees the state Dictionary or the world.
   `SaveManager.begin_save_*()` return the handle; the blocking `save_*()` wait on it.
5. **Schema v5** with a v4 -> v5 migration (shape unchanged; v4 routes stay without `cost`)
   and `save_schema_v5_fixture.json`, the same session as the v1 to v4 fixtures.
6. **`WorldState.dispose()`** (`WorldDisposer`) walks the objects the world owns: those
   reachable through Object variables and the containers holding them, never through a
   Callable, since a Callable may point outside the world (the viewer's `CommandRecorder`
   hooked on as the command listener). It then replaces each Object, Callable, Array and
   Dictionary variable of the walked objects with an empty one, which breaks the cycles and
   only detaches outside listeners. What the caller handed in, the session `ContentRegistry`
   and the `WorldSetup`, is neither walked nor reset, and containers are replaced rather than
   cleared, so shared data is untouched (`test_world_dispose.gd`).

## Alternatives considered

- **Compact encoding inside `StateCodec`.** Would change the dictionary every test and
  validator reads (`test_save_*` build plain states by hand); a separate wire layer keeps that
  contract and confines the format to the file.
- **A whole-map bitset per route search.** 8 KB per search on a 256x256 map, larger than the
  plain lists for the short A* searches; the bitset covers the visited box instead.
- **Compressing the file** (`FileAccess.open_compressed`). Smaller still, but no longer JSON
  text: the exact-integer scan, the integrity span and every tool that reads a save as text
  would change. Not needed for the target.
- **A blocking API with an internal thread.** Joining at once gains nothing; the handle lets
  the caller tick on.

## Consequences

- `bench_save_load`, 1,000 actors: file 579.6 KB (41% of 1,408 KB), main-thread save
  (`encode()` + `begin_write()`) 89.8 ms, `hash_match=true`; leak check delta 0 after
  `dispose()` (156 without). Numbers in `docs/orca/handoffs/A7.md`.
- A loaded search's visited tiles come back in row-major order instead of discovery order;
  nothing reads that order (`state_hash()` stringifies with sorted keys).
- `boot.gd` and `AutosaveTrigger` still use the blocking save, and `boot.gd` does not call
  `dispose()` yet: both are follow-ups once A9 (which owns `boot.gd`) has landed.
- Only one save write per `SaveManager` at a time.

## Acceptance criteria

- [x] `save-system.md` updated ("Atomic writes", "Wire encoding", migration v4 -> v5, "Route
  searches").
- [x] `game-state.schema.json` v5 (`routeState.cost`), fixture
  `save_schema_v4_fixture.json`, `test_save_migration.gd`, `test_save_route_continuation.gd`.
- [x] Save/migration impact handled (v4 -> v5).
- [x] The source-of-truth index still points to `save-system.md` and the schema.
