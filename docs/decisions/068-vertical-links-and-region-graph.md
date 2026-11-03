# ADR 068: Map layers, step L3 — vertical links, the region graph and link edges

> **In short:** L3 adds `VerticalLinks` (stairs, ramps and tunnels as object content flags,
> straight up or down only), builds regions on every layer and joins them through those links
> into a region graph, and lets `RouteSearch` cross a link as one more neighbour. Links are
> derived from the map and never saved, so the save schema does not change. Wiring the links into
> the simulation's callers is the follow-up L3b.

- **Status:** proposed (owner sign-off pending; L3 handoff)
- **Date:** 2026-11-03
- **Scope:** simulation, content
- **Implements:** [ADR 045](045-map-layers.md) §3, §4 (step L3, packages 1 and 2)

## Context

ADR 045 §3 makes stairs, ramps and tunnels the only way between layers and keeps them
straight up/down; §4 asks for per-layer regions joined into a graph, link edges in the route
search with A8's heuristic and tie-break kept, and rescue/dig targets that work across layers.
It left open where links live, whether they are saved, how region ids are numbered across
layers, and what `same_region()` and `reachable()` mean once two layers touch. ADR 063 §3
kept regions and rooms on the surface until this step.

## Decision

1. **Content flags.** An object definition may declare `link_up` and `link_down` (optional
   booleans in `objects.schema.json`). `Passability` packs them beside its existing flags
   (`LINK_UP = 4`, `LINK_DOWN = 8`) and answers `passable_tile(tile)` and `link_flags(tile)`.
   No shipped object declares them yet; layer generation (L5) and tunnel building place them.
2. **What a link is.** z grows underground (ADR 045), so `(x, y, z)` is the upper end and
   `(x, y, z + 1)` the lower one. `core/map/vertical_links.gd` holds one bit per upper tile:
   the two are linked while the upper tile has `link_down`, the lower `link_up`, and both are
   colony-passable. A one-sided stair, flags declared the wrong way round or a blocked end is
   no link. Beside the bits it keeps the links' upper ends as an ascending index, so the
   region graph and `links()` cost O(links), not O(tiles); `on_tile_changed()` re-derives the
   two links a tile can belong to and inserts or removes them in the index.
3. **Never saved.** Links are rebuilt from tiles and objects on load, like regions, so neither
   the save format nor `state_hash()` changes. No schema bump.
4. **Per-layer regions, global ids.** `RegionMap` floods every layer on its own and numbers
   regions layer by layer starting with layer 0, so a single-layer map keeps every id it had.
   `region_id()`/`region_of()` answer on any layer.
5. **Region graph.** Each link joins the regions of its two ends. `component_of(tile)` is the
   lowest region id in that tile's connected component, rebuilt lazily after any region or
   link change. `same_region()` stays planar (one region); `reachable(from, target)` asks for
   the same component, and an impassable target (a dig or work target) counts through its
   orthogonal neighbours on its own layer only, never through the tile above or below.
6. **Link edges in RouteSearch.** `set_vertical_links(links)`, called after construction and
   before `restore()`, adds a tile's link ends as neighbours: the one above (z - 1) before the
   four planar offsets, the one below (z + 1) after them, so discovery stays in ascending flat
   index.
   Crossing costs the destination tile's `cost_fn`. The heuristic becomes the 3D Manhattan
   distance × `min_cost`, consistent because every step changes it by at most one tile. The
   f/h/latest-pushed tie-break is unchanged; without links, or with z = 0 everywhere, the
   search is the A8 search, byte for byte.
7. **Rescues.** Work progress already keys a rescue as `"<job_id>:<coord_key>"`, and
   `coord_key()` carries `z` off the surface, so two rescues on different layers keep their own
   progress; L3 pins that in a test.
8. **Rooms stay on the surface.** Rooms keep their planar layer-0 build; underground rooms
   need their own rules (roofs, temperature) and are a later step.

## Alternatives considered

- **Links as tile kinds.** Simpler for dug stairs, but every object-built stair would need a
  tile change; objects cover both. Tile-kind flags stay a follow-up if L5 wants them.
- **Saving links.** Redundant with the tiles and objects that define them, and would cost a
  schema bump (v13) for no gain.
- **Merged region ids across a link.** Would renumber regions whenever a stair is built or
  removed and make `same_region()` cross layers silently; a separate component label keeps
  region ids stable and the planar meaning of `same_region()`.

## Consequences

- Single-layer maps behave exactly as before: region ids, recorded route searches, dumps and
  pinned hashes are unchanged.
- **L3b** passes `RegionMap.vertical_links()` to the simulation's searches
  (`GlobalAssignment`, the givers, `ToilExecutor`, `StateCodec`'s restore) and measures the
  1000-colonist case (A14) across layers. Until then no simulation route leaves its layer,
  though `reachable()` already answers across links.
- `NeedsSystem` compares raw region ids and stays layer-local until it moves to
  `component_of()` (follow-up).

## Acceptance criteria

- [x] Two-layer test map with a stair pair: regions split, merge, stair removed, dig target on
      its own layer, two rescues keep their own progress (`test_vertical_links.gd`).
- [x] Route search crosses the stair on the cheapest path, deterministically and across a
      snapshot/restore, and is unchanged without links (`test_vertical_links.gd`).
- [x] Single-layer dumps and recorded searches unchanged (`test_route_search_recorded.gd`,
      `test_regions.gd`, full suite).
- [x] The affected canonical documents are updated (`core/routing/README.md`,
      `objects.schema.json`).
- [x] Save/migration impact: none (links are derived, no schema bump).
- [ ] Owner sign-off.
