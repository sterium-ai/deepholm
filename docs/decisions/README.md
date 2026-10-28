# Architecture decision records

> **In short:** One file per decision, numbered in the order the decisions were accepted. This
> page is the index. Each number is used once. The redirect table below maps numbers used
> before a renumbering to the current records.

New records start from the [ADR template](../architecture/adr/000-template.md) and take the
next free number. ADRs whose titles say a change "raises" a core budget record why a file was
allowed to grow under the old per-file caps; [ADR 048](048-composed-core.md) supersedes them
all with one size rule.

| ADR | Title |
| --- | --- |
| [001](001-game-foundation.md) | Deterministic game foundation |
| [002](002-agent-ownership-and-review.md) | Phase-based agent ownership and independent review |
| [003](003-scheduling-explainability-save-integrity-mobile-first.md) | Deterministic scheduling, explainability, save integrity, and mobile-first constraints |
| [004](004-global-assignment-fairness-policy.md) | Global assignment with bounded aging and route work |
| [005](005-tile-objects-schema-v4.md) | Persisted tile objects and schemaVersion 4 |
| [006](006-items-with-ids-and-carrying-schema-v6.md) | Ground wood becomes first-class items, colonist carrying, schemaVersion 6 |
| [007](007-stockpile-zones-and-haul-persistence-schema-v7-v8.md) | Stockpile zones and haul persistence, schemaVersion 7-8 |
| [008](008-calendar-content-schema.md) | Calendar content schema and CalendarService |
| [009](009-need-interrupt-suspend-resume.md) | Critical-need interrupt suspend/resume releases the paused job's reservation |
| [010](010-content-registry.md) | Content registry — one loader, schema-validated, frozen at session start |
| [011](011-one-work-engine.md) | One work engine and behaviour extension points |
| [012](012-actors-and-components.md) | Actors and components — an accessor layer, not a new colonist shape |
| [013](013-tool-toils.md) | Tool toils — fetch_tool and drop_tool |
| [014](014-factions-and-relations.md) | Factions and relations — a new content collection and a read-only accessor |
| [015](015-regions-core-budget-increase.md) | Regions wiring raises two core budgets |
| [016](016-rooms-core-budget-increase.md) | Rooms wiring raises the world_state.gd core budget |
| [017](017-incidents-core-budget-increase.md) | Incidents wiring raises two core budgets |
| [018](018-pc-map-presentation.md) | Clipped PC map camera and explicit designation tools |
| [019](019-world-dimensions-and-generation.md) | World dimensions, pure worldgen module, and incremental map presentation |
| [020](020-river-vegetation-and-spawn-generation.md) | Main river, correlated vegetation, and river-aware spawn placement |
| [021](021-combat-resolution.md) | Generic combat resolution and targeting |
| [022](022-visual-target-16px-pixel-art.md) | Visual target — flat top-down 16 px pixel art |
| [023](023-job-queue-shared-preview-checks-core-budget-increase.md) | JobQueue's shared preview checks raise its core budget |
| [024](024-needs-decay-points-per-day.md) | Needs decay in points per day; day length 2200 ticks |
| [025](025-mining-core-budget-increase.md) | Mining wiring raises the world_state.gd core budget |
| [026](026-trench-trapped-actor-and-rescue.md) | Trench, trapped-actor and rescue — content shape, find-roll and placement rules |
| [027](027-trench-trap-escape-core-budget-increase.md) | Trap-on-entry and hostile climb-out raise the world_state.gd core budget |
| [028](028-build-job-core-budget-increase.md) | The `build` job kind raises core budgets |
| [029](029-rescue-job-giver-core-budget-increase.md) | Rescue job-giver raises the world_state.gd core budget |
| [030](030-rescue-persistence-and-reservation-fixes-core-budget-increase.md) | Rescue persistence and reservation fixes raise two core budgets |
| [031](031-rescue-route-safety-and-progress-keys-core-budget-increase.md) | Rescue route safety and per-job progress keys raise the world_state.gd core budget |
| [032](032-rescue-shared-route-budget-and-activation-safety-core-budget-increase.md) | Shared rescue route budget and post-commit route safety raise the world_state.gd core budget |
| [033](033-hostile-approach.md) | Hostile approach job-giver |
| [034](034-incident-lingering-actors.md) | Lingering incident actors (`spawn.lingers`) |
| [035](035-trader-visit-core-budget-increase.md) | Trader visit and accept_trade raise the world_state.gd core budget |
| [036](036-trader-two-way-swap-and-offer-cleanup-core-budget-increase.md) | Two-way trader swap and stale-offer cleanup raise the world_state.gd core budget |
| [037](037-hands-multi-unit-carrying.md) | A colonist's single carrying slot becomes a 4-unit "hands" list |
| [038](038-build-multi-source-fetch-efficiency.md) | `build` gains a per-job multi-source fetch plan; `build_cost` becomes a list |
| [039](039-object-footprint-rotation.md) | Object footprint, rotation, and multi-builder content fields |
| [040](040-construction-sites.md) | Persistent construction sites replace the single-worker `build` job |
| [041](041-colonist-glide-move-ticks-getter-core-budget-increase.md) | A read-only move_ticks_per_tile getter for the colonist glide raises the world_state.gd core budget |
| [042](042-build-line-batch-command.md) | `build_line` submits a whole wall/rectangle drag as one atomic command |
| [043](043-site-fetch-chained-deposit.md) | `site_fetch`'s `deposit` completion chains onto further same-kind sites |
| [044](044-area-order-expansion-queue.md) | Area orders expand through a saved per-tick queue |
| [045](045-map-layers.md) | Map layers — one `Vector3i` coordinate, one flat tile index |
| [046](046-story-layer.md) | Story and quest layer (trigger → condition → effect) |
| [047](047-work-progress-owner-records-and-ground-berry-factions.md) | Work-progress owners and ground berries persist explicit records |
| [048](048-composed-core.md) | Composed core — one size rule replaces per-file budgets |
| [049](049-save-schema-reset-v1.md) | Save schema reset to v1 before release |
| [050](050-command-observer.md) | Optional command observer on `WorldState.apply()` |
| [051](051-data-driven-work-effects.md) | Data-driven work effects (`jobs.json` `effects`) |
| [052](052-localisation-ready-text.md) | Codes in the core, words in `data/text/<locale>.json` |
| [053](053-job-storage-retired-history.md) | Live job storage, a bounded history of retired jobs, read-only views |
| [054](054-scenarios-as-content.md) | Scenarios as content |
| [055](055-viewer-snapshot.md) | One read-only view snapshot per viewer refresh |

## Renumbered records (redirects)

Two renumberings made each number unique again:

- Commit `2ff9481` (2026-09-30). Before it, 012, 018, 020 and 027 were each used by two
  records. Every record from the second 012 onwards moved up by one or two numbers, and some
  files were renamed.
- R16 (2026-10-28). A5 and A16 both took 053, so A16's scenarios record became 054.

A reference to an old number in a commit message, handoff or older review means the record in
the right-hand column.

| Old number and file | Current record |
| --- | --- |
| 012 `012-tool-toils.md` | [013](013-tool-toils.md) |
| 015 `015-factions-and-relations.md` | [014](014-factions-and-relations.md) |
| 016 `016-regions-core-budget-increase.md` | [015](015-regions-core-budget-increase.md) |
| 017 `017-rooms-core-budget-increase.md` | [016](016-rooms-core-budget-increase.md) |
| 018 `018-incidents-core-budget-increase.md` | [017](017-incidents-core-budget-increase.md) |
| 020 `020-combat-resolution.md` | [021](021-combat-resolution.md) |
| 021 `021-visual-target-16px-pixel-art.md` | [022](022-visual-target-16px-pixel-art.md) |
| 022 `022-job-queue-shared-preview-checks-budget-increase.md` | [023](023-job-queue-shared-preview-checks-core-budget-increase.md) |
| 023 `023-needs-decay-points-per-day.md` | [024](024-needs-decay-points-per-day.md) |
| 024 `024-mining-core-budget-increase.md` | [025](025-mining-core-budget-increase.md) |
| 025 `025-trench-trapped-actor-and-rescue.md` | [026](026-trench-trapped-actor-and-rescue.md) |
| 026 `026-trench-trap-escape-core-budget-increase.md` | [027](027-trench-trap-escape-core-budget-increase.md) |
| 027 `027-build-job-core-budget-increase.md` | [028](028-build-job-core-budget-increase.md) |
| 027 `027-rescue-job-giver-core-budget-increase.md` | [029](029-rescue-job-giver-core-budget-increase.md) |
| 028 `028-rescue-persistence-and-reservation-fix-core-budget-increase.md` | [030](030-rescue-persistence-and-reservation-fixes-core-budget-increase.md) |
| 029 `029-rescue-round4-safety-and-progress-core-budget-increase.md` | [031](031-rescue-route-safety-and-progress-keys-core-budget-increase.md) |
| 030 `030-rescue-round5-budget-cleanup-and-activation-safety-core-budget-increase.md` | [032](032-rescue-shared-route-budget-and-activation-safety-core-budget-increase.md) |
| 031 `031-hostile-approach.md` | [033](033-hostile-approach.md) |
| 032 `032-incident-lingering-actors.md` | [034](034-incident-lingering-actors.md) |
| 033 `033-trader-visit-core-budget-increase.md` | [035](035-trader-visit-core-budget-increase.md) |
| 034 `034-trader-visit-round2-core-budget-increase.md` | [036](036-trader-two-way-swap-and-offer-cleanup-core-budget-increase.md) |
| 035 `035-hands-multi-unit-carrying.md` | [037](037-hands-multi-unit-carrying.md) |
| 036 `036-build-multi-source-fetch-efficiency.md` | [038](038-build-multi-source-fetch-efficiency.md) |
| 037 `037-object-footprint-rotation.md` | [039](039-object-footprint-rotation.md) |
| 038 `038-construction-sites.md` | [040](040-construction-sites.md) |
| 039 `039-colonist-glide-move-ticks-getter-core-budget-increase.md` | [041](041-colonist-glide-move-ticks-getter-core-budget-increase.md) |
| 040 `040-build-line-batch-command.md` | [042](042-build-line-batch-command.md) |
| 041 `041-site-fetch-chained-deposit.md` | [043](043-site-fetch-chained-deposit.md) |
| 053 `053-scenarios-as-content.md` (A16, R16 renumbering) | [054](054-scenarios-as-content.md) |
