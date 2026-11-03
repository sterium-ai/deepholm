# ADR 071: Underground layers — generation, discovery, tunnel, drill and ores (F4)

> **In short:** a world starts with the surface only. A finished `tunnel` (built with a `drill`
> crafted at the workbench) discovers the layer below. The new layer is generated from the world
> seed alone, so it is the same whenever it is found. Discovery appends the layer to TileGrid,
> places its ore veins and logs `layer_discovered`. Every finished tunnel carves a floor landing
> below itself with `stairs_up` on it, and the pair forms an L3 vertical link. Mining a vein gives
> one raw ore item in the new `ore` group. Up to three underground layers exist. The save records
> the generator's version as `map.undergroundVersion` (schema v14 locally; **v16 on main**, see
> the F4 handoff).

- **Status:** proposed (owner sign-off pending; F4 handoff)
- **Date:** 2026-11-03
- **Scope:** core (worldgen, underground, persistence), content, viewer placeholders
- **Builds on:** [ADR 045](045-map-layers.md) §5 (deterministic layer generation),
  [ADR 068](068-vertical-links-and-region-graph.md) (vertical links), ADR 069 (active layer)

## Context

L1–L4 gave TileGrid layers, `Vector3i` tiles, vertical links (`link_down` / `link_up` objects
paired by (x, y)), the region graph and a viewer with an active layer. Nothing created a layer
during play: worlds were generated with a fixed `layer_count`. F4 asks for discovery by digging,
deterministic per-layer content, ores by depth, and mining that feeds the existing haul/stockpile
loop, with no smelting and no cave-ins.

`world_generator.gd` is frozen at 870 lines and `world_state.gd` is at its 800-line cap, so the
work goes into new modules.

## Decision

1. **Generation is a pure function of the seed.** `UndergroundGenerator.generate_layer(seed,
   layer, width, height, object_definitions)` (core/worldgen/underground_generator.gd) seeds its
   own `RandomNumberGenerator` from `seed + UNDERGROUND_SEED_SALT + layer * LAYER_SEED_STRIDE`. It
   never reads the tick, the world RNGs or anything built so far. The layer is `rock` with
   random-walk `floor` pockets (one per 256 tiles, at least one). Veins are drawn in a fixed order
   (vein kinds sorted by id): `round(area * per_thousand_tiles / 1000)` of each, at least one,
   on rock only, at most one per tile, and a vein that finds no free rock in 8 tries is skipped.
   So seed 42's L1 is identical whether it is discovered at tick 100 or at tick 10000.
2. **Veins are content.** An object definition with a `vein` block (`ore`, `layer`,
   `per_thousand_tiles`) is a vein. The vein objects are impassable and sit on rock:
   - L1: copper, tin and coal
   - L2: iron and silver
   - L3: gold and gems

   Adding a vein kind is a content change. It changes the layers that are generated from then
   on, which is what `undergroundVersion` (§6) guards.
3. **Discovery.** `LayerDiscovery` (core/underground/layer_discovery.gd) is wired to
   `ConstructionSystem.on_site_completed`, a new optional Callable. When a `tunnel` on layer
   `z < 3` is finished and layer `z + 1` does not exist yet:
   - the generated tiles are appended, so the existing flat indices never move;
   - `layer_count`, the regions and the water cache are invalidated;
   - the veins are placed with `ObjectTable.place_generated`;
   - the cell grid is reset;
   - the job givers' cached bounds are raised;
   - one `layer_discovered` event is logged (`data.layer`, `data.first_index`).

   Layers are only ever appended in order (L1, then L2, then L3), because a tunnel on layer N
   can only be built once layer N exists.
4. **Stairs, one tunnel per layer, routing.**
   - Every finished tunnel carves a 3×3 floor landing below itself on layer `z + 1` and puts
     `stairs_up` at the centre, under the tunnel. The landing only turns rock and veins into
     floor: any other object there (a wall, furniture) is kept, and if the centre is not free the
     stairs are skipped.
   - The tunnel has `link_down` and the stairs have `link_up`, so L3's link pairing and the region
     graph connect the layers with no new code.
   - `LayerDiscovery.may_place` (a new optional `ConstructionSystem.may_place` Callable) vetoes
     a tunnel with `invalid_target` in two cases. The detail is `tunnel_layer_taken` when the
     layer already has a tunnel, a tunnel site or another tunnel in the same build line. It is
     `tunnel_landing_blocked` when the stairs tile below holds anything but a vein or
     `stairs_up`.
   - Route searches see the vertical links (L3b, ADR 068). `LayerDiscovery.links()` returns the
     region graph's `vertical_links()` on a map with more than one layer. `wire_routing()` gives
     it to the scheduler and the need, rescue and approach givers as `links_of`; their measured
     routes call `RouteSearch.set_vertical_links()`. Distance scoring on other layers uses
     `ZoneTable.OTHER_LAYER_DISTANCE` (as `tool_matching` already did); reach tests are false
     across layers.
5. **Tunnel and drill.**
   - The `drill` is a `material` item from the workbench recipe `drill` (wood ×2 and stone ×3).
   - The `tunnel` is a buildable 1×1 passable object costing drill ×1 and wood ×2, with 160 build
     ticks. The drill is consumed as a build cost; nothing else in the build pipeline changed.
6. **Mining veins → ore.**
   - The `mine` job's effects gain `vein_ore: true`. When the target holds a vein object,
     `VeinMining.yield_ore` clears the vein and spawns one item of its `ore` at the tile, after
     the usual rock→floor and stone yield.
   - The ore items (copper_ore, tin_ore, coal_ore, iron_ore, silver_ore, gold_ore, rough_gem)
     are in the new item group `ore`, so stockpiles can accept them and haul them like any other
     item.
7. **Persistence.** The layers themselves are tiles and objects, saved with the map as before.
   - The new state is `map.undergroundVersion` (integer ≥ 1): the generator algorithm a world
     uses for the layers it has not discovered yet. It is required and validated, and the load
     restores it.
   - The migration v13→v14 adds `undergroundVersion: 1`.
   - Schema v14 locally; it is renumbered to v16 on main, after F6b-1 (v14) and F5a-b (v15).
8. **Viewer.** The new objects and items have placeholder colours in `map_view.gd` and
   placeholder entries, with reasons, in `world_pack.json` until pack art is chosen. There are
   also text keys for the drill recipe and the `ore` stockpile group.

## Consequences

- An undiscovered layer costs nothing. The world holds only the surface until a tunnel is
  finished, so the tick of a fresh world is unchanged.
- Changing `UndergroundGenerator` or the vein content changes the future layers of existing
  saves. A change to the algorithm must bump `GENERATOR_VERSION`, and keeping old saves'
  layers identical would need the old algorithm kept behind that version. Nothing does that yet,
  since there is only version 1.
- There is no build tool for the tunnel in the control bar yet: the viewer's tool list is
  outside F4's owned paths. Tunnels are placed by build orders (tests, commands). This is a
  follow-up.
- There are no cave-ins, no smelting, and no layers below L3 (`MAX_UNDERGROUND_LAYER`).

## Known limitations

- A route search keeps the vertical links it was given when it was created. A tunnel finished
  during a search is seen by the next search.
- If an object is built on the stairs tile while the tunnel is still a site, the finished tunnel
  gets no stairs. `may_place` only checks the tile when the tunnel is placed.
- Deconstructing a tunnel would free its layer for another one. There is no deconstruct command
  yet, so this cannot happen today.
