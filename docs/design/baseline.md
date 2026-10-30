# Baseline: the minimum feature set

> **In short:** Deepholm is inspired by a small classic mobile colony sim. The owner's rule
> is: first reach everything that game offered at minimum, with better engineering, then go
> beyond it (towards a Dwarf Fortress-like depth). This page is the inventory that rule is
> measured against. Status reflects `main` as of 2026-10-19.

Status legend: **done** · **partial** (something exists but not the full rule) · **missing**
· **later** (deferred by the owner). Behaviour is *inspired by* the reference; nothing is
copied from it, and its name does not appear in this repository.

## 1. Map and terrain

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Surface map with earth, stone, water, lava, sand, grass, plowed/dried soil, coloured floors | rock, grass/sand/dirt, floor, plowed, planted, hazard, tree, water; 256×256 seeded, river, groves | partial |
| Ore objects: copper, tin, iron, silver, gold, coal, gems, one deep-only metal | none | missing |
| Rock outcrops, mineable stone → stone item | done | done |
| Underground layers reached through a tunnel building (one per layer, needs a drill item); stairs; "layer N discovered" | surface only | **missing (core of the game)** |
| Cave-ins; support pillars prevent collapses | — | missing (after layers) |
| Finite water sources, wells over water, lava, bridges | river tiles, water need from river | missing |
| Dig as areas/lines/points, dig-remove, smooth floor, plow/unplow | dig rectangle (trench), cancel; till/sow per tile | partial |

## 2. Orders and construction

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Build menu in groups (buildings, workshops, infrastructure, furniture, misc); ghost preview, cost, rotation, multi-cell; materials delivered by haulers | walls (wood/stone, lines), doors, beds, 2×1 rotatable workbench; construction sites with multi-source fetch | partial |
| Demolish; fertilize; harvest | — | missing |
| Walls/floors in wood, stone brick, brick, iron; doors wood/iron, lockable | wood/stone walls, doors (no lock) | partial |
| Task priority chosen at creation | job priority 1–3 | done |

## 3. Colonists

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| 15 labours (miner, lumberjack, builder, hauler, farmer, cook, carpenter, blacksmith, metallurgist, mason, engineer, weaver, medic, herder, agronomist) with enable + priority | labour table 1–4/off for mine, chop, farm, haul, forage, build | partial |
| Skill 0–10 per labour with XP tiers; speed and haul capacity scale with skill | none | missing |
| Needs food, water, energy, happiness, health; per-colonist thresholds; hungry/starving bands | food, water, rest 0..100; warn/urgent/critical; per-day decay | partial |
| Starvation/dehydration damage; wounded state; hospital bed, medic, medicine items | health component, combat damage only | missing |
| Death, burial, memorial | — | missing |
| Happiness from a thought table (dozens of weighted thoughts, decay, repetition); depression; breakdowns | — | missing |
| Relations (friend/foe/lover), personality traits, favourite food | factions only | missing |
| Equipment slots head/body/hands/back; clothing wear | tool in hand | partial |
| Names, appearance, memories | ids only | missing |
| Migrants arrive | migrant incident | partial |
| Golems | — | later |

## 4. Economy

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| ~150 items in ~15 groups (ores, ingots, stone, wood, seeds, tools, weapons, armour, food, furniture, gems, medicine, coins, other) | axe, pick, seed, wood, stone, sand, flint, coal, coin, berries | missing (registry exists) |
| ~10 workshops with recipes, current/annual production targets, craft queue | workbench object, no recipes | missing |
| Stockpile zones with per-group/item filters, per-tile disable, stacking | stockpile zone, haul, no filters | partial |
| Trade: periodic merchant, market, buy/sell, colony money | trader visit with one-for-one offer | partial |
| Colony wealth and stock statistics | — | missing |

## 5. Farming, forest, animals

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Farm zone: plow → fertilize → sow (several crops) → growth stages → harvest; planting season; drought | till/sow per tile, sowing window; no growth, no harvest, no zone | partial |
| Forest reserve zone: saplings planted and grown | — | missing |
| Pasture zone with animals (eggs, milk, meat) | — | missing |
| Food processing (flour, bread, stew, cheese, drinks) | — | missing |

## 6. Combat and threats

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Squads, HQ/barracks, attack/defend orders; warrior stats and ranks | combat component, factions, flee | missing |
| Raid waves on a growing schedule, spawn at map edge in groups, retreat on losses, difficulty knob | wolf incident; raider entry spawns a hostile animal | missing |
| Traps with limited charges | — | missing |
| Bosses | — | later |
| Trenches as defence (Deepholm original) | done | done |

## 7. Rooms and comfort

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Rooms recognised by walls; material, decor, quality tier; personal room needs a bed; dormitory; housing thoughts | enclosure recognition + bedroom rest bonus | partial |
| Furniture: bed, table, chair, cabinet, carpet, decorations, meeting stone, training dummy | chair/table/bed with passability only | partial |

## 8. Progression and modes

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Campaign goal, survival, sandbox; year milestones | new game with seed | missing |
| Research levels | — | later |
| Colony statistics screen | colonist panel | missing |
| ~30 announcements | need alerts, incident line | partial |

## 9. Time

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Months and years (the reference had no "day") | day = 2200 ticks; 3 days/month, 12 months/year derived from the day; windows by day or month range; viewer date line (F0, ADR 060) | done |
| Tick-based need decay (the reference was frame-rate dependent, a bug) | done | done |

## 10. Saving

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Reliable saves | JSON, schema version + migrations, integrity hash, atomic writes, 1 manual + 3 rotating + last-good, autosave | done (better than the baseline) |

## 11. Interface and platform

| Baseline | Deepholm today | Status |
| --- | --- | --- |
| Tool modes; colonist info window with labours, equipment, relations, thoughts | debug toolbar; colonist panel; labour table | partial; left action panel parked |
| Touch, landscape, several languages, settings | PC web + native; text table | later; no ads/IAP |

## Owner decisions still pending

1. ~~Month/year on top of days~~ — **decided 2026-10-29: 3 days/month, 12 months/year**; done in F0 (ADR 060).
2. Starvation rule: slow periodic damage vs. direct death.
3. ~~Breakdowns~~ — **decided 2026-10-30: depression only** (F5d); no "goes crazy" chance.

## Suggested order to close the minimum

1. Crops: growth and harvest; farm zones.
2. Workbench recipes, item groups, stockpile filters.
3. Skills/XP per labour and the remaining labours.
4. Underground layers + tunnel + ores + cave-ins/supports (the game's identity; biggest gap).
5. Happiness/thoughts, depression, relations.
6. Forest reserve, pasture, animals, food processing.
7. Squads, raid waves, traps.
8. Health/wounds/medic, death/burial.
9. Room quality/furniture, real trade, statistics, campaign modes.

The refactor in `../orca/REFACTOR-PLAN.md` comes first: none of these fit in today's
`world_state.gd`.
