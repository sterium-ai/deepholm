# ADR 051: Data-driven work effects (`jobs.json` `effects`)

> **In short:** What dig, chop, mine, forage, till and sow do when their work toil finishes
> is now content: an `effects` block on the job's `jobs.json` entry (tile check, input
> consumed, tile transform, object cleared, items always yielded, find table).
> `ToilBindings` applies that block with one generic function instead of a `match` per kind,
> so a new work kind of this shape is a content entry. Every existing kind behaves exactly as
> before.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** content (`jobs.json` shape and schema, `ContentRegistry` cross-checks),
  simulation (`ToilBindings` work completion, `ItemTable` spawns and finds)
- **Depends on:** ADR 010 (content registry), ADR 026 (dig yields, find table, placement
  rule), ADR 047 (ground-berry factions), ADR 048 (composed core)
- **Implements:** BACKLOG A14

## Context

After R11, `ToilBindings._toil_on_work_complete()` held a `match` with one branch per work
kind. Six of those branches (dig, chop, mine, forage, till, sow) did the same few things in
different combinations: check the target tile, take one input item, rewrite the tile, clear
the object, spawn items, stage a find roll. The items were spawned through three special
cases (`spawn_wood_item`, `spawn_stone_item`, `spawn_berries_item`) and `"sand"` was a
literal, although `jobs.json` already declared dig's `yields.always: ["sand"]`. The find
roll read the table of the `"dig"` entry by name. Adding a work kind meant code in two
modules.

The other branches (site_work, sleep, escape_trench, rescue) call into a system that owns
the rule (construction, needs, trench); they are not data and stay code.

## Decision

1. **Shape.** A `jobs.json` entry may carry `effects`, all fields optional:

   ```json
   "effects": {
     "requires_tile": "soil",
     "consumes": "seed",
     "set_tile": "trench",
     "clear_object": true,
     "yields": {"placement": "adjacent", "always": ["sand"], "ground_berries": 1,
                "find_table": [{"item": "flint", "weight": 20}, {"item": null, "weight": 80}]}
   }
   ```

   `requires_tile`/`set_tile` are tile ids, `consumes` and every `always`/`find_table` item
   are item ids. `yields.placement` is required when `yields` is present: `"target"` (the
   work tile) or `"adjacent"` (ADR 026's rule: first passable, non-trench orthogonal
   neighbour in N, W, E, S order, else the tile). `ground_berries` adds that many units to
   the ground-berry counter of the placement tile; berries are not an item (`eat_food` reads the counter),
   so they keep their own storage, and this field is the only place the difference shows.
   The former top-level `yields` block moves inside `effects`, unchanged except for
   `placement` and `always`/`find_table` both becoming optional.
2. **Order.** `ToilBindings.apply_work_effects()` applies the block in a fixed order:
   `requires_tile` (mismatch: the job fails `invalid_target`/`resubmit_order`, nothing
   changes), `consumes` (one unit through `ItemTable.remove_one_item_of_kind()`; none left:
   fails `blocked_missing_input`/`resubmit_order`), `set_tile`, `clear_object`, each `always`
   item in list order at the placement, `ground_berries`, then one staged find when the kind
   has a `find_table`. This is the order every one of the six branches used, so their
   results, item ids and event order are unchanged. The trench trap check (ADR 026) still
   runs first, and the dirty-cell/region/room hooks still fire after, only when the tile
   changed.
3. **One spawn by item id.** `spawn_wood_item()` and `spawn_stone_item()` are removed; every
   yield goes through `ItemTable.spawn_item(item_id, x, y)`. `spawn_berries_item()` stays,
   because ground berries are a counter, not an item.
4. **Finds by kind.** A staged find carries the job kind (`{job_id, kind, x, y}`);
   `resolve_dig_finds()` reads that kind's `effects.yields.find_table` and placement. Staged
   finds are still resolved once per tick in ascending job-id order, with one draw each from
   the same salted stream, so dig's sequence is unchanged. `pending_dig_finds` is still empty
   between ticks and never saved, so the added field changes no save.
5. **Content checks.** `ContentRegistry` rejects, typed `dangling_reference` on `jobs.json`:
   an unknown tile id in `requires_tile`/`set_tile`, an unknown item id in `consumes`,
   `always` or `find_table`. It rejects, typed `schema_violation`: `effects` on a job with no
   `work` toil, and a `find_table` whose weights do not sum to 100 (as before).
6. **What stays code.** Kinds whose completion belongs to another system (site_work, sleep,
   escape_trench, rescue) keep their branch. Ordering a work kind (commands, area orders,
   their preview checks) is outside this decision: those modules still name the six kinds.

## Consequences

- A new tile-transforming or item-yielding work kind needs a `jobs.json` entry and nothing
  in `ToilBindings` or `ItemTable` (`test_work_effects_content.gd` proves it with a fixture
  kind). To let the player order it, `area_orders.gd`, `command_checks.gd` and
  `order_handler.gd` still need the kind added; that is a follow-up, not part of A14.
- Save format and `state_hash()` are unchanged: no persisted field moved.
- The tile/object/item literals of the six kinds now live in `jobs.json`, under the content
  lint like every other content literal.
