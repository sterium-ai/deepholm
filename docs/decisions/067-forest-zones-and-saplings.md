# ADR 067: Forest zones and saplings

> **In short:** A new zone kind, `forest`, makes colonists with the farm labour plant
> saplings on its empty soil (`plant_sapling`, no seed). A sapling grows through three stage
> tiles over 8 days into a `tree`; a ripe sapling under a colonist waits until the tile is
> free. Felling stays the manual `chop`, and the soil a chop leaves in a forest zone is
> replanted. The save gains one growth record per sapling tile (schema v11).

- **Status:** accepted (design closed with the owner, BACKLOG F6a)
- **Date:** 2026-11-03
- **Scope:** content, simulation, persistence, presentation
- **Depends on:** ADR 059 (crops and farm zones, whose machinery this reuses), ADR 051
  (data-driven work effects), ADR 048 (composed core), ADR 010 (content registry),
  ADR 049/053 (save schema and migrations), ADR 045/063 (map layers: tiles are `Vector3i`)
- **Implements:** BACKLOG F6a; `docs/architecture/colonist-ai.md` ("Forest zones and
  saplings"), `orders-and-movement.md` (zone commands), `save-system.md` (v11, "Saplings")

## Context

Trees were only ever map generation's: once chopped, a tile stayed soil and wood was finite.
F1 already gave zones a kind, job-givers per zone and per-tile growth records with stage
tiles. A renewable wood source fits that machinery without new mechanisms.

## Decision

1. **Content.** `content/forests.json` (schema `content/schemas/forests.schema.json`) lists
   forests: `id`, `label`, `plant_job`, `grow_days`, `stages` (tile ids, planted to oldest)
   and `grown_tile`. v1 has one: `tree`, `plant_sapling`, 8 days, `sapling_1` → `sapling_2`
   → `sapling_3`, `tree`. `core/farming/forest_content.gd` cross-checks the ids against
   `jobs.json` and `tiles.json` at load. The stage tiles are passable; `tree` stays impassable.
2. **Planting.** `plant_sapling` is a plain `jobs.json` kind: labour `farm`, toils reserve,
   go_to, work (30 ticks), release_all; effects `requires_tile: soil`, `set_tile: sapling_1`.
   It takes no seed or other item.
3. **Zone.** `zone_add` accepts `kind: "forest"`, which names no crop (a crop is
   `invalid_payload`). `ForestGiver` (`core/zones/forest_giver.gd`), run by
   `FarmSystem.advance()` after `FarmGiver` in the `farming` phase, submits the plant job on
   every forest-zone tile that is passable soil and not the target of a live farm job, zones
   in id order, row-major.
4. **Growth.** `TreeGrowth` (`core/farming/tree_growth.gd`, composed by `FarmSystem`) keeps
   `{forest, growth}` per sapling tile. Growth rises one per tick with no season up to
   `grow_days × day_length_ticks`; stage *i* shows from `ripe × i / n`. At ripe the tile
   becomes `grown_tile`, except while a colonist or creature stands on it: the tree is
   impassable, so the flip waits for the tile to be free. A ground item (the felled tree's wood)
   does not hold it back. Records are reconciled with the tiles on every dirty
   cell and on decode, iterated in key order, and draw no RNG.
5. **Felling.** Unchanged: the player's `chop` order fells the tree and leaves soil, which
   the forest zone replants on the next `farming` tick.
6. **Save.** Schema v11 adds `saplings: [{target, forest, growth}]` in tile-key order,
   validated against the session's forests; `_v10_to_v11` adds an empty list. The records are
   part of `state_hash()`. (F5a landed first with v10, ADR 064, so F6a takes v11.)
7. **Viewer.** A "Forest Zone" tool sends `zone_add` with `kind: "forest"`; the stage tiles
   draw with sprout decor over soil.

## Non-goals

Auto-felling, changes to wood yield, seasons for trees, pasture.

## Consequences

- Wood is renewable through player chop orders.
- An idle farmer may stand on a ripe sapling and hold it back until it moves away; a
  step-off rule for idle colonists is a possible follow-up.
