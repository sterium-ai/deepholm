# ADR 059: Crops, growth stages, harvest and farm zones

> **In short:** A sown tile now grows. A crop is content: its stages are tile kinds
> (sprout, grown, ripe), it grows only inside its calendar window, and an unripe crop
> withers a day after the window closes. A ripe crop gets a `harvest` job that leaves 2 food
> and 1 seed on the tile. A new zone kind, `farm`, makes colonists till, sow and harvest its
> tiles without per-tile orders. The save gains the zone kind and one growth record per sown
> tile (schema v6).

- **Status:** accepted (design closed with the owner on 2026-10-29, BACKLOG F1)
- **Date:** 2026-10-29
- **Scope:** content, simulation, persistence, presentation
- **Depends on:** ADR 057 (scenario start: a scenario calendar may replace `calendar.json`), ADR 051 (data-driven work effects), ADR 048 (composed core and budgets),
  ADR 010 (content registry), ADR 049/053 (save schema and migrations), ADR 054 (scenarios)
- **Implements:** BACKLOG F1; `docs/architecture/colonist-ai.md` ("Crops and farm zones"),
  `orders-and-movement.md` (zone commands), `save-system.md` (v6)

## Context

`till` and `sow` existed (`plowed_soil` → `planted`), but a planted tile never changed: the
baseline's food loop (sow, grow, harvest, store, resow) stopped at the first step. The owner
closed F1's design on 2026-10-29 (BACKLOG F1, "Design"): one content-defined crop, three
visible stages over about 4 days inside the sowing window, a `harvest` job (labour `farm`)
leaving 2 food and 1 seed on the tile, no growth outside the window and withering one day
after it, and a `farm` zone that tills, sows and harvests its tiles without orders.

## Decision

1. **Crops are content.** `content/crops.json` (an optional collection kind, schema
   `crops.schema.json`, cross-checked by `core/farming/crop_content.gd`) declares per crop:
   `seed_item`, `sow_job` and `harvest_job` (its own `jobs.json` kinds), `window` (a
   `calendar.json` window id), `grow_days`, `stages` (tile ids from sown to ripe),
   `wither_days_after_window` and `withered_tile`. v1 ships one crop, `carrot`: jobs `sow` and
   `harvest`, `planted` → `crop_grown` → `crop_ripe`, 4 days, window `sow`, 1 day, `plowed_soil`.
   A crop's jobs do its work: `CropContent` refuses (as `dangling_reference` on `crops.json`) a
   sow job whose effects do not consume the crop's `seed_item` and set its first stage, a
   harvest job that does not require its last stage, and a stage tile shared by two crops. The
   window is not checked against `calendar.json`: a calendar
   without it (a scenario's, ADR 057) leaves the crop no season (it never grows, a zone never
   sows it, an unripe one withers). A second crop is data only: a `crops.json` entry, its seed and produce items, its stage tiles
   and its two jobs (`test_farm_two_crops.gd` adds two this way, from a content pack).
2. **Stages are tiles.** The stage a player sees is the tile kind, so passability, the viewer,
   the dirty-cell stream and the harvest's `requires_tile` need nothing new. `FarmSystem`
   (`core/farming/farm_system.gd`) owns only how far each sown tile has grown:
   `crops["x,y"] = {crop, growth}`. Growth is a tick count, +1 per tick while the window is
   open; stage i shows from `growth >= ripe * i / (n - 1)`, `ripe = grow_days * day_length_ticks`.
   Past the window's last day + `wither_days_after_window` (the start of day 22 for `sow`), an
   unripe crop's tile becomes `withered_tile`; a ripe one waits for its harvest. No RNG is drawn:
   growth is tick-based, so the same seed and commands give the same `state_hash()`.
3. **Records follow the tiles.** `FarmSystem.advance()` reads the tile grid's dirty-cell
   stream (A6) and reconciles each changed cell: a stage tile without a record gets one at its
   stage's threshold, any other tile loses its record. A truncated stream and `decode()`
   reconcile the whole map. It runs in a new `TickPipeline` phase, `farming`, after
   `advance_colonists`/`dig_finds`, so a sow or harvest completed in a tick has its record before
   the tick ends and a save never sees a sown tile without one.
4. **Harvest is a plain job kind.** `jobs.json` `harvest` (the carrot's `harvest_job`): labour `farm`, toils
   `reserve, go_to, work, release_all`, 30 work ticks, effects `requires_tile: crop_ripe`,
   `set_tile: plowed_soil`, `yields.always: [food, food, seed]` at the target. `food` is a new
   `items.json` id (kind `food`), a stackable ground item `HaulGiver` carries to a stockpile.
5. **FarmGiver.** `core/jobs/givers/farm_giver.gd`, built and run by `FarmSystem` after growth:
   the ripe crop's `harvest_job` on every ripe tile (sown by a zone or a per-tile order), then on
   every farm zone, row-major in zone-id order, a `till` on passable soil and, only while the
   zone crop's window is open, that crop's `sow_job` on plowed soil, never more sows than the
   ground units of that crop's seed not already claimed by a live sow of it. Every live till and
   crop job (`FarmSystem.job_kinds`) claims its tile, so a player's order and the giver never
   double up. Priority is the player's default (`NORMAL`). The per-tile `sow` order is the
   carrot's `sow` job, unchanged. `ToilExecutor` takes its job definitions from the session
   `ContentRegistry` (it read `res://content/jobs.json` before), so a pack's crop jobs run
   (owner-approved scope extension, 2026-10-30).
6. **Farm zones.** `zone_add` takes optional `kind` (`"stockpile"` default, or `"farm"`) and
   `crop` (required for a farm zone, refused on a stockpile, `unknown_crop` when not in
   content). `ZoneTable` stores `{"kind": "farm", "crop"}` on farm zones only; stockpiles keep
   their exact pre-F1 record, so their hash is unchanged. A farm zone stores nothing:
   `is_in_any_zone()` and the new `get_stockpile_zones()` (haul and tool-drop destinations, wired
   in `WorldState`) skip it, so an item on a farm tile is hauled away like any loose item.
7. **Save v6.** Zones may carry `kind`/`crop`; a top-level `crops` list holds
   `{target, crop, growth}` per sown tile (validated by `validators/farm_validator.gd` against the
   session's crop ids). On disk `crops` goes through A7's SaveWire like `entities` and `jobs`: a
   record table (`{"$keys"}` header, one row per crop), packed in the same single stringify
   (ADR 058). `SaveMigrations` v5 → v6 adds `crops: []` (every v5 zone is already a v6
   stockpile); a v5 sown tile gets its record on decode. Fixture `save_schema_v6_fixture.json`
   is the R14/A5/A13b/A16b/A7 session, which the v1 to v5 fixtures migrate to exactly. (v6
   because A7 took v5, ADR 058, before F1 landed.)
   `state_hash()` adds `crops` only when non-empty, so a world without crops keeps its hash
   (that session: `1180613310` before and after).
8. **Viewer.** The three stage tiles draw the planted ground with the sprout source's three
   cells: pack art from `Farm.png`'s carrot row (`world_pack.json`, measured by the B3 script),
   placeholder cells otherwise. A "Farm Zone" tool paints a farm zone of the first crop.

## Alternatives considered

- **Stage in the growth record only, one `planted` tile.** Needs a new viewer read path for
  the stage, and the harvest's ripe check in code instead of `requires_tile`. Rejected.
- **Growth as a sown tick (no per-tick work).** "No growth outside the window" then needs an
  in-window tick count between two ticks across windows; one counter per tile is simpler and
  its cost is one dictionary walk per tick over sown tiles only.
- **A hook in `ToilBindings` when sow completes.** Couples the work engine to farming; the
  dirty-cell stream already reports every tile change, including direct ones.
- **Ground food as berries (a per-tile counter).** Berries are not items and are never hauled;
  the design wants harvest yields stored in a stockpile. A plain item reuses hauling as is.

## Consequences

- A scenario calendar (ADR 057) that lacks a crop's window gives that crop no season: it never
  grows, a farm zone never sows it, and an unripe one withers at once.

- `world_state.gd` grows by composition only (795 lines, under 800).
- Colonists do not eat `food` yet: `eat_food` still targets berries (NeedsSystem). Making
  stored food edible is follow-up work outside F1's owned paths.
- The window test is a day range on `calendar.json`'s `from`/`to`. When F0 adds month-declared
  windows and years, `FarmSystem._in_window()` and the wither day should move to
  `CalendarService`'s window query.
- A farm zone's giver walks its cells every tick; very large farm zones cost proportionally.
- Sowing outside the window is still allowed by a per-tile order; such a crop never grows and
  withers on the wither day.

## Acceptance criteria

- [x] The affected canonical documents are updated (colonist-ai.md, orders-and-movement.md,
      save-system.md, contracts/game-state.schema.json).
- [x] Contracts, examples, and tests are updated (`test_farm_zone.gd`, `test_save_migration.gd`).
- [x] Save/migration impact is handled (v6, migration, fixture).
- [x] The source-of-truth index still points to the authoritative location.
