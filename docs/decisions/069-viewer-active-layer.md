# ADR 069: Map layers, step L4 — the viewer draws one active layer

> **In short:** L4 makes the debug viewer draw one layer at a time. The active layer is viewer
> state only (never saved, never a command), switched with PageUp/PageDown or the ▲/▼ buttons
> beside a "z N" label; tiles, objects, colonists, other actors, designations, items, zones and
> construction sites are filtered to it, stairs and ramps get a small up/down marker, and every
> command the viewer builds carries the active layer as its `z`. The core gains one column, the
> actors' `z` in the view snapshot; the save schema does not change.

- **Status:** proposed (owner sign-off pending; L4 handoff)
- **Date:** 2026-11-03
- **Scope:** viewer
- **Implements:** [ADR 045](045-map-layers.md) §7 (step L4)

## Context

ADR 045 §7 asks the viewer to draw one active layer, switch it with keys or buttons, show the
links between layers and the layer number, and send commands with the active `z`. Until L4 the
viewer drew the surface and consumed deeper dirty cells without drawing them (ADR 063 §3).
WorldState's planar getters (`get_tile(x, y)`, `get_object(x, y)`) answer for the surface only;
`get_tiles()` is flat and z-outermost and `get_objects()` entries carry `z`. The view snapshot
had no layer for actors.

## Decision

1. **Viewer state only.** `MapView.active_layer` (0 = surface) lives in the viewer. Switching
   issues no command and touches nothing in the world, so `state_hash()` is unchanged; it is not
   saved, and `set_world()` resets it to the surface. `set_active_layer(z)` clamps to the map's
   layers, cancels an in-progress selection, redraws, and emits `layer_changed(z)` only when the
   layer actually changes; `step_layer(±1)` moves one layer.
2. **Input.** PageUp goes up one layer (z - 1), PageDown down one (z + 1). The control bar has
   ▲ and ▼ buttons around a "z N" label. Glyphs and notation, not words, so no text-table keys.
3. **Layer slice.** `viewer/layer_slice.gd` reads one layer from `get_tiles()` and
   `get_objects()`. On the surface it keeps calling `get_tile()`/`get_object()`, so layer 0
   draws exactly as before L4. A deep layer's slice is a copy, re-read when one of its cells is
   dirty. A switch rebuilds the tile and object layers in full; there is no per-layer cache.
4. **Filtering.** Tiles, objects, colonists, other actors, designations, ground items,
   stockpile zones and construction sites are drawn only when their `z` is the active layer.
   The view snapshot gains a `z` column beside `x` and `y` (ADR 045 §7's per-layer slice);
   nothing else in the core changes.
5. **Links.** A stair or ramp object (content `link_up` / `link_down`, ADR 068) on the active
   layer gets a small white triangle per direction: up at the tile's top-right corner, down at
   its bottom-right. Drawn in art and colour modes alike.
6. **Commands.** Every command the viewer builds (dig, mine, chop, wall, build, zones,
   rectangles) carries the active layer as `payload.z`; commands aimed at an existing thing
   (a construction site, a workbench, a stockpile) keep that thing's own `z`. Whether the core
   accepts a deep command is the core's rule, not the viewer's.
7. **Rooms.** Rooms stay on the surface (ADR 068 §8), so the room label is empty off it.

## Alternatives considered

- **Active layer in the world or the save.** It would change `state_hash()` on a pure view
  action and need a schema bump; it is a camera property, not simulation state.
- **Drawing all layers stacked or translucent.** Harder to read and to pick tiles on; ADR 045
  §7 chose one layer.
- **Planar getters with a `z` argument in WorldState.** Cleaner, but a core API change outside
  L4's scope; the viewer-side slice keeps the core untouched beyond the snapshot column.

## Consequences

- A deep layer redraws from a copy when its cells change: O(width × height) per dirtying tick
  on that layer, only while it is active.
- The owner checks the look after merge; final art for the layer markers is a later step.
- Words for the controls (if wanted instead of glyphs) need text-table keys in `en.json`.
