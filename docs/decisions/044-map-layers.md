# ADR 044: Map layers — one `Vector3i` coordinate, one flat tile index

> **In short:** Underground layers are stacked copies of the surface map, all the same size.
> A tile is named by `Vector3i(x, y, layer)` everywhere in the rules, and stored by one
> number that counts across all layers, so layer 0 keeps today's numbers and saves. Stairs,
> ramps and tunnels are the only way between layers, and they always go straight up or down.

- **Status:** accepted (signed off by the owner on 2026-10-27, review round 2)
- **Date:** 2026-10-26
- **Scope:** simulation (map, passability, regions, rooms, routing, distance rules),
  persistence (tile shape and the single-layer migration), presentation (one visible layer).
- **Depends on:** [ADR 019](019-world-dimensions-and-generation.md) (map size and generation),
  [ADR 018](018-pc-map-presentation.md) (camera and designation), ADR 015/016 (regions and
  rooms), [ADR 039](039-object-footprint-rotation.md) (footprints).
- **Prepares:** F4 (underground layers, tunnel, ores, supports, cave-ins); A2 (integer tile
  keys) and A8 (A\* routing) are written to be compatible with it.

## Context

The baseline's identity feature (`docs/design/baseline.md` §1) is a stack of underground
layers reached through a tunnel building, with stairs between them. The core is 2D by
construction (`docs/architecture/foundation-audit.md` §3.3). Measured on `main` at
`279b42f` (commands under "Inventory" below):

- one `TileGrid.tiles: Array[String]` indexed `y * width + x`; `regions.gd`, `rooms.gd` and
  `world_generator.gd` each repeat that index math;
- 516 `Vector2i` occurrences in `game/scripts/core` (the audit's 506 plus later growth),
  and 183 more in `game/scripts/viewer` and `boot.gd`;
- four String key formats for one tile, plus a composite: `"%d_%d"` (23 occurrences:
  `ObjectTable.object_key()`, `ItemTable` ground berries, `WorkProgress`, combat targeting
  and resolver, `StateCodec`), `"tile:%d,%d"` (`WorldState._tile_key()`,
  `JobQueue._target_key()` through `TARGET_KEY_PREFIX`, `ConstructionSystem`),
  `"cell:%d,%d"` (`WorldState._cell_key()`, `JobQueue._cell_key()`), `"%d,%d"`
  (`ConstructionGiver._site_key()`), and `"<jobId>:%d_%d"` (`WorkProgress`, rescue jobs);
- saves write every coordinate as `{x, y}` through `StateCodec._encode_tile()`; actors,
  items, zones and commands carry flat `"x"`/`"y"` fields (115 `["x"]` reads in core);
- 17 lines of planar distance math (`absi`, Chebyshev, `_distance_sq`) in 11 core files
  (givers, toils, combat, assignment, worldgen, `world_state.gd`), used to rank nearest
  candidates and to test adjacency.

The audit offered three models: a layer index carried next to `Vector2i`, `Vector3i`, or one
flat index across layers. This ADR picks one, before any F4 code, so that adding a layer is
one change at a few owners and not 516 independent edits.

## Decision

### 1. Coordinate: `Vector3i(x, y, z)`, `z` = layer

- Every rule, query, job field, event and command that names a tile uses `Vector3i`. `z` is
  the layer index: `0` is the surface, `1, 2, …` go down. There are no layers above the
  surface and no negative `z`.
- All layers share the world's `width` and `height` (ADR 019's clamp, today ≤ 512). A layer
  is a full `width × height` grid; "solid rock not yet dug" is a tile kind, not a hole in
  the grid.
- A `Vector2i` stays legal only where the value is genuinely planar: a footprint offset, a
  direction, an atlas coordinate, a rectangle size, a screen/tile conversion before the
  layer is attached. A `Vector2i` that names a map tile is a defect once the sweep (step L2
  below) has landed.

### 2. Storage and keys: one flat index, owned by `TileGrid`

```text
index(c) = c.z * width * height + c.y * width + c.x
```

- `TileGrid` owns the only implementation: `index_of(c: Vector3i) -> int`,
  `coord_of(index: int) -> Vector3i`, `in_bounds(c) -> bool`, `layer_count`,
  `layer_size = width * height`. `regions.gd`, `rooms.gd` and `world_generator.gd` stop
  repeating the math and call it (or receive it as a `Callable`, per the no-back-reference
  rule).
- Every per-tile table key is that integer. The four String formats are retired:
  `objects`, `object_factions`, `object_origin`, `object_health`, ground berries, plain
  work progress, reservations and site keys all key by `int`. A reservation that must not
  collide with an item or actor id keeps a typed wrapper (`{"tile": index}` or a prefix on
  the integer, chosen by A2), never a coordinate string.
- **Job-scoped keys keep their job.** A `rescue` job's work progress is keyed by the pair
  (job id, tile index), not by the tile alone, because two rescues can share a target
  ([ADR 032](032-rescue-shared-route-budget-and-activation-safety-core-budget-increase.md),
  `WorkProgress`'s class invariant). The composite `"<jobId>:%d_%d"` String becomes that
  pair (for example `"<jobId>:<index>"` or a job-id → index map, chosen by A2/L1); only the
  coordinate part changes. Ownership, suspension and release rules are unchanged. The same
  applies to any future key that today combines a tile with another identity.
- `z` is outermost, so **layer 0's indices equal today's `y * width + x`**, and appending a
  layer never renumbers an existing one. Layers can therefore be added during play (a
  layer is "discovered") by growing `tiles` by `layer_size`; the count never shrinks.
- Neighbour order, everywhere a deterministic order is needed (route expansion, flood
  fills, candidate scans), is **ascending flat index**: on one layer that is today's
  row-major order, so every existing tie-break is unchanged; across layers, the tile above
  sorts before the planar neighbours and the tile below after them.

### 3. Between layers: vertical links only

- A **vertical link** joins `(x, y, z)` and `(x, y, z + 1)`, the same column one layer
  apart, never a diagonal or a jump. It exists when the upper tile's object (or tile kind)
  declares `link_down` and the lower one declares `link_up` in content, and both are
  passable for the moving faction. Stairs, ramps and the tunnel building are content
  entries with these flags; F4 chooses which objects exist and what they cost.
- Links are **derived**, like regions: a `VerticalLinks` index (under `map/`) is rebuilt
  from tiles and objects on first use and updated at the existing passability-changed
  points (`_mark_dirty()` call sites). Links add no save field.
- Crossing a link costs the destination tile's `move_cost`, the same rule as a planar step
  (`RouteSearch`'s "cost to enter that tile").
- Because links are strictly vertical, `(|dx| + |dy| + |dz|) × min_move_cost` never
  overestimates a route, so A8's A\* heuristic stays admissible with layers.

### 4. Passability, regions, rooms, routing and distance

- **Passability** is per tile: `passability(c: Vector3i, faction)`; out of bounds includes
  `z ≥ layer_count`. A2's packed cost and door arrays grow by `layer_size` per layer, using
  the same flat index.
- **Regions** flood-fill within a layer only (planar neighbours), and region ids stay
  global integers (unique across layers). `same_region()` keeps its planar meaning.
- **Region graph.** One node per region id, one edge per vertical link between the regions
  at its two ends. Each region gets a component label (lowest region id in its component).
  Two regions are *connected* when their labels are equal.
- **Graph invalidation.** The labels are derived and go stale on **any** change to region
  membership or to links:
  - a link appears or disappears;
  - a planar split or merge (`on_passability_changed()` assigns a new id or folds ids
    together);
  - a region's last tile disappears.

  Each of these marks the graph dirty. The next query rebuilds the labels from the current
  region ids and links, in ascending region id order, so the result is deterministic.
  Union-find alone is not enough, because it cannot undo a merge when a split happens. A
  rebuild costs O(regions + links), not O(tiles).
- **`reachable(from, target)`** keeps today's two rules and lifts them to the graph:
  1. `target` is out of bounds → false.
  2. `target` is passable → true when the region of `from` and the region of `target` are
     connected.
  3. `target` is impassable (region id 0: a dig, chop, mine or build target, worked from an
     adjacent tile) → true when any of its **same-layer** orthogonal neighbours is passable
     and its region is connected to the region of `from`.

  This is the current adjacent-work exception in `regions.gd` `reachable()`, unchanged on
  one layer. A tile is never "reachable" through the layer above or below it, matching the
  planar work-adjacency rule below.
- **Rooms** stay per layer. A link tile bounds a room the way a door does: rooms never span
  layers, so "bedroom", "storeroom" and their bonuses keep today's rules.
- **Routing:** `RouteSearch` expands planar neighbours plus the link ends of the current
  tile, in ascending flat index. Its bounds become `Vector3i` (`z` from 0 to
  `layer_count - 1`), and its snapshot stores `Vector3i` path tiles.
- **Work adjacency** (stand next to a tile to dig, chop, mine, build) stays planar and on the
  same layer. Digging *down* is a tunnel or stair job, designed in F4, not adjacency
  across layers.
- **Distance ranking:** a planar distance (`absi`, Chebyshev, `_distance_sq`) is only
  defined between two tiles on the same layer. A "nearest" search that may cross layers
  ranks by route cost (as ADR 038/043 already do) or restricts its candidates to the
  actor's layer.
- **The three metrics stay three helpers.** The 17 lines use three different metrics, and
  each keeps its exact formula. L1 must not merge them into one "distance".

  | Helper (on `TileGrid`, static) | Formula | Used today for | Sites |
  | --- | --- | --- | --- |
  | `manhattan(a, b)` | `absi(dx) + absi(dy)` | nearest-candidate ranking and travel penalty | `approach_giver.gd:423`, `combat_targeting.gd:96`, `need_giver.gd:322-334`, `rescue_giver.gd:341-342`, `tool_drop_toil.gd:399`, `tool_matching.gd:40`, `global_assignment.gd:438` |
  | `chebyshev(a, b)` | `maxi(absi(dx), absi(dy))` | the `<= 1` "next to" test (8 neighbours) and square rings | `approach_giver.gd:458`, `toil_executor.gd:509/589/885`, `tool_fetch_toil.gd:322`, `world_state.gd:1451`, `world_generator.gd:1125` |
  | `distance_sq(a, b)` | `dx * dx + dy * dy` | flee-candidate comparison | `combat_giver.gd:372-393` |

  - All three take `Vector3i` and assert `a.z == b.z`, so a call across layers fails
    loudly. A ranking that may cross layers uses route cost instead.
  - On one layer, each helper returns the same integer as the expression it replaces, so
    L1's scenario dump stays byte-identical.
  - `world_generator.gd:1125` works on plain `x`/`y` ints inside one layer's generation and
    may keep its inline form.
  - Line numbers are as of `279b42f`.
- **Incidents and spawn** stay on the surface (`z = 0`) until an F-task says otherwise;
  map-edge entry is a surface concept.

### 5. Saves

- Every coordinate object gains `z`: `{x, y, z}` in `_encode_tile()`/`_decode_tile()`, and
  `z` beside every flat `x`/`y` pair (actors, items, zones). `SaveIO._valid_tile()` checks
  `0 ≤ z < layerCount`.
- `map` gains `layerCount`. `map.tiles` stays one flat array of
  `layerCount × width × height` kinds in flat-index order, so a single-layer save's array is
  already a valid layer-0 array. (A7 may later compact it; it keeps the flat order.)
- Generated layers are content of the save once discovered: their tiles are persisted, never
  regenerated on load. A layer's generation draws from a stream salted by the world seed and
  the layer index, so discovering it on day 3 or day 30 gives the same rock.
- **Migration from single-layer** (from schema 25 today, or from R14's reset version if R14
  lands first): `layerCount = 1`; add `z: 0` to every coordinate object and beside every
  flat `x`/`y`; `tiles` unchanged. Historic migrations in `save_migrations.gd` keep their
  2D shapes; the new step runs last. The migration test loads a committed single-layer
  fixture and checks that layer 0's tiles, objects, actors, items and jobs equal the
  pre-migration values field by field, and that the migrated world's `state_hash()` survives
  a save/load round trip.
- `state_hash()` covers `layerCount` and the full `tiles` array; `VerticalLinks`, like the
  region and room maps, is derived and excluded.

### 6. Commands and events

- Commands that name a tile carry `z`. Until F4 ships a reason to send anything else,
  command validation fills a missing `z` with `0` **at the command boundary only**; inside
  the core `z` is never optional. An out-of-range `z` is rejected like an out-of-map
  `x`/`y` today (`invalid_target`, `commands/command_checks.gd`); no new reason code.
- Events that name a tile carry `z`; the dirty-cell log becomes `Array[Vector3i]`.

### 7. Viewer: one active layer

The viewer shows one layer at a time; the rest of the contract is in
[`map-experience.md`](../architecture/map-experience.md#layers-planned-adr-044). In short:
an *active layer* (viewer state, never persisted, like the camera), switched by buttons and
keys; tiles, objects, designations and actors drawn for that layer only; screen-to-tile
conversion returns `Vector3i(x, y, active_layer)`; dirty cells of other layers are consumed
but not drawn until that layer becomes active.

## Inventory: what must change

Counts from `main` at `279b42f`. Not every `Vector2i` is a map tile (directions, footprint
offsets, atlas coordinates); the sweep keeps those.

| Area | `Vector2i` | Other coordinate sites | Change |
| --- | ---: | --- | --- |
| `map/` (`tile_grid`, `passability`, `regions`, `rooms`) | 60 | 3 copies of `y * width + x` | flat index owner; region graph; `VerticalLinks` (new) |
| `jobs/` (queue, toils, givers, work progress, tools) | 105 | `"tile:"`, `"cell:"`, `"%d,%d"`, `"<jobId>:%d_%d"` keys | job `target`/`cell`/`site` become `Vector3i`; integer keys |
| `objects/` (object table, construction) | 60 | `"%d_%d"` object keys, footprints | integer keys; footprints stay planar offsets on the origin's layer |
| `world_state.gd` | 56 | `_tile_key()`, `_cell_key()` | delegation to `TileGrid` helpers only |
| `combat/` | 58 | `"%d_%d"` target keys, `_distance_sq` | integer keys; same-layer distance helper |
| `worldgen/` | 46 | own index math, distance fields | layer-0 generation unchanged; per-layer generator salted by layer |
| `actors/` (trench system, components) | 35 | actor `x`/`y` fields | actor position gains `z` |
| `routing/` | 30 | row-major neighbour sort | `Vector3i` bounds, link edges, flat-index order |
| `incidents/` | 20 | edge spawn | surface only |
| `scheduling/` | 20 | planar distance | same-layer helper or route cost |
| `persistence/` | 15 | `_encode_tile()`, `_valid_tile()`, 115 `["x"]` reads in core | `{x, y, z}`, `layerCount`, migration + fixture |
| `items/`, `commands/` | 11 | ground-berry `"%d_%d"` keys, command `x`/`y` | integer keys; command `z` default at the boundary |
| **core total** | **516** | | |
| viewer + `boot.gd` | 183 | `tiles_in_rectangle()`, `tile_at_local()`, dirty-cell cursor | active layer (map-experience.md) |

Order of work (each step its own task, suite green and hash-checked):

1. **A2** — integer tile keys and packed cost arrays (already in the backlog). Removes most
   String keys while there is still one layer.
2. **L1** — `TileGrid` becomes the only index owner (`index_of`/`coord_of`/`in_bounds`,
   `manhattan`/`chebyshev`/`distance_sq`), every remaining key goes through it. No save change; scenario dump
   byte-identical to `main`.
3. **L2** — the `Vector2i` → `Vector3i` sweep with `layer_count = 1`, the save bump and the
   single-layer migration with its fixture. Scenario dump identical apart from the schema
   version and the added `z`/`layerCount` fields.
4. **L3** — `VerticalLinks`, the region graph and link edges in `RouteSearch`. It is tested
   on a hand-built two-layer map with a stair pair. The tests cover:
   - a wall that splits a layer-0 region so that one half loses its stair;
   - removing that wall again (merge);
   - removing the stair;
   - an impassable dig target whose only reachable neighbour sits on its own layer;
   - two rescues on the same target, each keeping its own progress.
5. **L4** — the viewer's active layer.
6. **F4** — gameplay: layer generation and discovery, tunnel building, stairs, ores,
   supports and cave-ins, on top of L1–L4.

## Alternatives considered

- **A layer index next to `Vector2i`** (`(tile, layer)` pairs, or a `layer` field beside
  `x`/`y`). Smallest initial diff, but every function and Dictionary key needs a second
  argument, and forgetting it silently means layer 0, which is exactly the kind of bug the
  tests would not catch on a surface-only map. Rejected.
- **`Vector3i` with no flat index** (keys stay coordinates, as `Vector3i` or strings).
  Readable, but keeps the String/`Dictionary` lookups that the audit measured as the hot-path
  cost and leaves the index math duplicated. Rejected as incomplete: this ADR keeps
  `Vector3i` for the rules and adds the flat index for storage.
- **Flat index everywhere** (jobs, events and commands carry an `int`). Fastest, but
  unreadable in saves, events, tests and reason messages, and it couples every consumer to
  `width`/`height`. Rejected for the public shape; kept as the storage key.
- **Per-layer sizes or sparse layers.** Would let shallow layers be smaller, but breaks the
  "append a layer, renumber nothing" property and the vertical-link rule. Rejected; an
  undug layer is solid rock and costs one String per tile, like the surface.
- **Diagonal ramps** (a link from `(x, y, z)` to a neighbour on `z + 1`). More natural for
  ramps, but breaks the admissible heuristic and makes link tiles belong to two columns.
  Rejected; a ramp is a vertical link with its own move cost and art.

## Consequences

- One coordinate type and one index make "add a layer" a change to `TileGrid` and content,
  not to every system. Layer 0 keeps its indices, neighbour order and tile array, so the L1
  and L2 steps can prove "no behaviour change" with the existing scenario dumps.
- The sweep (L2) is large (516 core sites, 183 viewer sites) but mechanical; it is a save
  format change and must ship its bump, migration and fixture in the same change.
- Memory grows linearly: each layer adds `width × height` tile kinds (65,536 at 256×256) and
  the matching packed arrays from A2.
- Rooms never span layers, and planar distance never crosses them. A future rule that needs
  either (a multi-level room, a "nearest" that compares layers by straight-line distance)
  needs an ADR of its own.
- F4 still owns the gameplay decisions: how many layers, when a layer is discovered, what
  the tunnel building and the drill item do, ores, supports and cave-ins.

## Acceptance criteria

- [x] The affected canonical document is updated (`map-experience.md`, "Layers").
- [x] Contracts, examples and tests: N/A here (no code); the shape changes are listed for
      L2, which updates `game-state.schema.json`, its examples and the migration test.
- [x] Save/migration impact is specified (§5); implemented in L2.
- [x] The source-of-truth index still points to the authoritative location
      (`docs/decisions/` is indexed as a folder).
- [x] The owner signs this ADR off: signed off on 2026-10-27, so F4's Design block can cite
      it.
