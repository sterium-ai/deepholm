# ADR 063: Map layers, step L2 — the details ADR 045 left to the sweep

> **In short:** L2 makes every map tile a `Vector3i(x, y, z)` and saves `z` with schema v9
> (ADR 045 named v8; F3 took v8 first), as ADR 045 decided. This records the few choices that
> ADR left open: surface tiles keep their String key formats, the `(x, y)` read helpers mean
> the surface, regions and rooms still cover only the surface until L3, and a save may declare
> at most 64 layers.

- **Status:** proposed (owner sign-off pending; L2 handoff)
- **Date:** 2026-10-30
- **Scope:** simulation, persistence, presentation
- **Implements:** [ADR 045](045-map-layers.md) §1, §2, §5, §6 (step L2)

## Context

ADR 045 fixed the coordinate (`Vector3i`, `z` = layer, 0 = surface), the flat index
(`z * width * height + y * width + x`), the save shape (`z` beside every `x`/`y`,
`map.layerCount`, a single-layer migration) and the command rule (a missing `z` is the
surface, filled at the command boundary; an out-of-range `z` is `invalid_target`). L2 is the
mechanical sweep that applies it with one layer. A few details were left to it:

- ADR 045 §2 retires the String tile keys in favour of integers, "chosen by A2/L1". L1 kept
  the Strings byte for byte, because saves, events, reservations and `state_hash()` carry them.
- WorldState's public queries take `(x, y)` ints (`get_tile()`, `get_object()`,
  `passability()`, …); 300+ test and viewer call sites use them.
- Regions, rooms and their packed builds are per-layer work for L3 (ADR 045 §4).
- `map.layerCount` needs an upper bound so a hostile save cannot make the reader allocate
  `width × height × layerCount` tiles without limit.

## Decision

1. **Keys.** `TileGrid.coord_key()`, `target_key()`, `cell_key()` and `comma_key()` take a
   `Vector3i`. A surface tile keeps its L1 format (`"x_y"`, `"tile:x,y"`, `"cell:x,y"`,
   `"x,y"`); a deeper one appends its layer (`"x_y_z"`, `"tile:x,y,z"`, …). Their inverses
   read both. Replacing them with integers stays a later save change.
2. **`(x, y)` shorthands.** WorldState's public read queries and `TestAccess`'s helpers keep
   their `(x, y)` signatures and address the surface (`TileGrid.SURFACE`). Every module behind
   them, every record writer and every internal Callable takes a `Vector3i`.
3. **Surface-only maps.** Regions and rooms keep their planar, layer-0 build
   (`RegionMap.region_of()` and `TileGrid.on_passability_changed()`/`get_room_at()` answer
   "no region"/"no room" off the surface). `RouteSearch` checks `z` bounds but expands planar
   neighbours only; a search never leaves its start's layer. L3 adds the per-layer maps, the
   region graph and link edges.
4. **Save bound.** `TileGrid.MAX_LAYER_COUNT = 64`: `MapValidator` rejects a larger
   `layerCount` and `SaveWire` refuses to expand a map past `width × height × 64` tiles. F4
   sets the gameplay limit within it.
5. **Command boundary.** `CommandChecks.check_command_layer()`, run by
   `CommandRouter.validate_command()` after the tick check, fills a missing `z` in the payload
   (and in each `build_line` tile) and rejects a non-int `z` as `invalid_payload` and an
   out-of-range one as `invalid_target` with the out-of-map detail `target_outside_map`. The
   viewer sends `z = TileGrid.SURFACE` until L4's active layer.
6. **Route wire encoding.** A packed route stays planar (box, bits and frontier indices within
   the start's layer); unpacked tiles take the start's `z`. A pre-v9 file's `{x, y}` tiles
   unpack as they were and the v8 → v9 step adds `z: 0`.

## Alternatives considered

- **Integer tile keys now.** The cleanest end state, but it changes every saved and hashed
  key at once and is a separate save change; L2's acceptance asks for dumps that differ only
  by the added `z`/`layerCount` fields.
- **`(x, y, z := 0)` on every query.** Keeps call sites but makes `z` optional inside the core,
  which ADR 045 §6 forbids.
- **No layer cap.** Leaves the reader's allocation guard unbounded.

## Consequences

- One layer behaves exactly as before: the recorded route searches, the scenario dumps and
  the pinned `state_hash()` literals reproduce once the added fields are taken out
  (`docs/orca/handoffs/L2.md`).
- L3 owns: per-layer regions/rooms, the region graph, link edges, and every "nearest" search
  that may cross layers (the planar metrics assert `a.z == b.z`).
- L4 owns: the viewer's active layer, the per-layer view snapshot and the `(x, y)` → `Vector3i`
  attachment on the viewer side.

## Acceptance criteria

- [x] The affected canonical document is updated (`save-system.md` "Layers (v9)",
      `game-state.schema.json` v9).
- [x] Contracts, examples, and tests are updated (`test_map_layers.gd`, `test_save_migration.gd`).
- [x] Save/migration impact is handled (schema v9, `SaveMigrations._v8_to_v9()`,
      `save_schema_v9_fixture.json`).
- [x] The source-of-truth index still points to the authoritative location (`docs/decisions/`
      is indexed as a folder).
