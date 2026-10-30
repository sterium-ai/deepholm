# ADR 064: Stockpile filters and priorities

> **In short:** A stockpile zone now says which item groups it accepts and has a priority from
> 1 to 3. Haulers take each loose item to the highest-priority stockpile that accepts it and
> has room, the nearest one first. An item lying in a stockpile that no longer accepts it is
> hauled out. A new stockpile accepts everything at priority 2, which is how every stockpile
> behaved before. One new command (`zone_set_stockpile`), a minimal viewer panel, save schema
> v9.

- **Status:** accepted (design closed with the owner on 2026-10-30, `BACKLOG.md` F5a)
- **Date:** 2026-10-30
- **Scope:** simulation (`ZoneTable`, `HaulGiver`, one command), persistence (schema v9,
  optional stockpile fields), presentation (a stockpile panel)
- **Depends on:** ADR 007 (stockpile zones and hauling), ADR 011 (one work engine), ADR 045
  (TileGrid owns the planar metrics), ADR 052 (codes in the core, words in `data/text`), ADR 061
  (item groups)
- **Implements:** BACKLOG F5a

## Context

Until now every stockpile accepted every item, and `HaulGiver.find_free_haul_cell()` took the
first free cell in zone-id order. The owner's design (BACKLOG F5a): a stockpile accepts a set of
item groups (F2's `tool`, `material`, `food`, `seed`, and `ore` once F4 adds it) and has a
priority 1-3; haulers take each item to the nearest valid stockpile of the highest priority; an
item lying in a stockpile that no longer accepts it is moved to a valid one; a new stockpile
accepts every group at priority 2 (today's behaviour). Per-item filters, stack limits and other
hauling priorities are out.

## Decision

### State: `ZoneTable`

- A stockpile record `{id, x, y, width, height}` may gain `groups` (the accepted groups,
  ascending, no duplicates) and `priority` (1-3). **Each key is stored only away from its
  default** (every group, priority 2). Consequences: a stockpile nobody configured is the
  pre-F5a record, so its `state_hash()` and save are unchanged; and "every group" means every
  group the content has at the time, so when F4 adds `ore`, an unconfigured stockpile accepts
  ore without a migration. Setting every group back stores no `groups` key.
- An item's group is its `items.json` `kind` (ADR 061). The groups a filter may name are
  `ZoneTable.groups_of(items)`, the distinct kinds of the session's items. `items.json`'s
  declared `groups` list is not exposed by `ContentRegistry`, and the registry already checks
  that every kind is declared, so the kinds are the usable subset of the declared list (today
  they are equal; a declared group with no item would be a filter that never matters).
- Farm zones never carry a filter (the command and the save validator reject it).
- `accepts_item_at(x, y, kind)`: inside a stockpile that accepts the item's group.
  `stockpiles_for_item(kind, from)`: the accepting stockpiles, ordered by priority (high first),
  then Manhattan distance from the item to the rectangle (`TileGrid.manhattan()` to the
  rectangle's nearest cell), then zone id. `get_stockpile_zones_for_group(group)`: the accepting
  stockpiles in id order.

### Hauling: `HaulGiver` (the only job-giver change)

- `advance()` skips an item only when it lies in a stockpile that accepts it; an item in a
  stockpile that no longer accepts it gets a haul job like any loose item, which "moves it out".
  An item already in a valid stockpile is never moved to a higher-priority one: the design asks
  for the priority when choosing a destination, and moving stocked items again is "hauling
  priorities beyond the stockpile one" (a non-goal).
- `find_free_haul_cell(item_id)` (the `JobQueue` destination finder) reads the item through
  `ItemTable.item_lookup()` and walks `stockpiles_for_item()`: the first stockpile in that order
  with a free, passable, unoccupied cell wins, row-major inside it, as before. "Nearest valid
  stockpile of the highest priority" is read with room: a full priority-3 stockpile falls
  through to the next one, otherwise an item would wait forever beside free space. With no
  accepting stockpile with room the haul blocks `blocked_destination_full` with the existing
  doubling backoff. A one-stockpile world picks exactly the same cell as before; with several
  default stockpiles the nearest one now wins instead of the lowest id (the design's "nearest").
- Nearest is measured from the item, at activation: the hauler is not known when the
  destination is reserved (`JobQueue._tick_haul()` reserves item and cell before assignment).
- Tool drops (`ToolDropToil`, a colonist putting back a tool) receive
  `get_stockpile_zones_for_group("tool")` instead of every stockpile, so a tool is never dropped
  into a stockpile that does not accept tools. Only the Callable `WorldState` passes changed.

### Command: `zone_set_stockpile`

`{id, groups, priority}`: `groups` is a comma-separated string because command payload values
are Strings or ints (`CommandRouter.validate_command()`); `""` accepts nothing. Rejections:
`invalid_payload/zone_set_stockpile_payload`, `invalid_target/unknown_zone`,
`invalid_target/zone_not_stockpile`, `invalid_payload/stockpile_priority_out_of_range`,
`invalid_payload/unknown_item_group` (unknown or repeated). The check lives in `CommandChecks`,
so `preview()` and `apply()` agree. A haul already carrying an item to a stockpile that stops
accepting it still delivers it; HaulGiver then hauls it out. Cancelling those hauls would need
the carried item's kind in `ZoneHandler` for a rare case, and the result is the same.

### Persistence: schema v9

`zones[]` stockpile entries may carry `groups` and `priority`; `game-state.schema.json` and
`ObjectValidator._valid_zone()` accept them (groups ascending, distinct, each one of the
session's item kinds, `SaveIO.content_rules()["itemGroups"]`; priority 1-3; never on a farm
zone). `_v8_to_v9` keeps every zone as it is: a v8 stockpile is a v9 stockpile at its default.
It refuses a v8 zone that already carries either key. Fixture `save_schema_v9_fixture.json`
(F3's v8 fixture session, `docs/orca/handoffs/F5a-write-save.gd`) equals the v8 fixture but
for `schemaVersion`. Decode drops a saved `priority` of 2, so memory always holds the sparse form.

### Presentation

`viewer/stockpile_panel.gd`, on `workbench_panel.gd`'s pattern, in the info column: one block
per stockpile with its priority (- / +) and one toggle per group (`[x] Food` / `[ ] Food`). Every
button applies `zone_set_stockpile`; nothing else mutates. Texts under `stockpile.*` in
`data/text/en.json`.

## Alternatives considered

- **Always store `groups` and `priority`.** Explicit, but it changes every existing world's
  hash and save, and an "all groups" list frozen at creation would silently exclude `ore` when
  F4 lands.
- **Nearest free cell over all stockpiles.** Changes the cell a single-stockpile world picks
  (today row-major), so every existing haul scenario would shift. Ranking stockpiles, then
  row-major inside one, keeps them identical.
- **Re-sort stocked items when a higher-priority stockpile appears.** Out of the design and the
  cause of haul ping-pong; left out.

## Consequences

- `HaulGiver`'s constructor takes `accepts_item_at`, `stockpiles_for_item` and `item_lookup` in
  place of `is_in_any_zone` and `get_zones`. Other `is_in_any_zone()` users (construction and
  crafting stock, rooms) still treat any stockpile tile as "in a stockpile", filter or not.
- A stocked tool (ADR 061: a `ToolItemStore` item, not a ground item) has no haul path, so a
  tool lying in a stockpile that stops accepting tools stays there until a colonist takes it;
  only new drops respect the filter.
- `L2` (`Vector3i`): the distance uses `TileGrid.manhattan()`; the rectangle clamp is the one
  planar step and moves with the zone rectangle when zones gain a layer.
