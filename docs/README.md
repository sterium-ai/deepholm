# Deepholm documentation

> **In short:** This page is the map of every document in the repository: what
> the game is, how the code is organised, why each design decision was made,
> how game content is described, how it is tested, and how AI agents contribute.

Start with the [project README](../README.md) for a tour. Each page below opens
with a short plain-language summary.

## Overview

| Document | What it covers |
| --- | --- |
| [Project README](../README.md) | What Deepholm is, how to run it, design pillars and a technical tour |
| [Vision and principles](architecture/vision.md) | Product intent and the principles every system follows |
| [Vertical slice](architecture/vertical-slice.md) | Scope and acceptance criteria of the first playable slice |
| [Godot project](../game/README.md) | Layout of the `game/` folder, how to run it and its tests |

## Architecture

| Document | What it covers |
| --- | --- |
| [Architecture overview](architecture/README.md) | Entry point to the engineering contracts and their rules |
| [Source-of-truth index](architecture/source-of-truth.yaml) | Which document is authoritative for each concern |
| [Simulation boundaries](architecture/simulation-boundaries.md) | Layering, determinism and the simulation/presentation boundary |
| [Orders and movement](architecture/orders-and-movement.md) | Commands, tick costs, toils, reservations, routing, construction, combat |
| [Colonist AI](architecture/colonist-ai.md) | How colonists choose work, reserve targets, use tools and meet needs |
| [Save system](architecture/save-system.md) | Save layout, rotation, integrity checks and schema migrations |
| [Map experience](architecture/map-experience.md) | PC camera, HUD, coordinate conversion and designation tools |
| [Extension points](architecture/extension-points.md) | The five ways new behaviour may enter the code |
| [Foundation for breadth](architecture/foundation-for-breadth.md) | Content registry, actors, factions, regions, rooms and incidents |
| [Game-state contract](architecture/contracts/game-state.schema.json) | JSON Schema of the serialized game state |
| [Core size budgets](architecture/core-budgets.json) | Line-count caps for the largest core files (checked in CI) |
| [Command contract](../game/scripts/core/commands/README.md) | Command envelope, rejections and the read-only query surface |
| [Job queue](../game/scripts/core/jobs/README.md) | Job lifecycle, blocking reasons and remedies |
| [Route search](../game/scripts/core/routing/README.md) | Budgeted, resumable path search |

## Decisions

Architecture decision records (ADRs) in [`decisions/`](decisions/), numbered in
the order they were accepted. New ones start from the
[ADR template](architecture/adr/000-template.md). ADRs whose titles end in
"raise(s) … core budget" record why a file in
[core-budgets.json](architecture/core-budgets.json) was allowed to grow.

| ADR | Title |
| --- | --- |
| [001](decisions/001-game-foundation.md) | Deterministic game foundation |
| [002](decisions/002-agent-ownership-and-review.md) | Phase-based agent ownership and independent review |
| [003](decisions/003-scheduling-explainability-save-integrity-mobile-first.md) | Deterministic scheduling, explainability, save integrity, and mobile-first constraints |
| [004](decisions/004-global-assignment-fairness-policy.md) | Global assignment with bounded aging and route work |
| [005](decisions/005-tile-objects-schema-v4.md) | Persisted tile objects and schemaVersion 4 |
| [006](decisions/006-items-with-ids-and-carrying-schema-v6.md) | Ground wood becomes first-class items, colonist carrying, schemaVersion 6 |
| [007](decisions/007-stockpile-zones-and-haul-persistence-schema-v7-v8.md) | Stockpile zones and haul persistence, schemaVersion 7-8 |
| [008](decisions/008-calendar-content-schema.md) | Calendar content schema and CalendarService |
| [009](decisions/009-need-interrupt-suspend-resume.md) | Critical-need interrupt suspend/resume releases the paused job's reservation |
| [010](decisions/010-content-registry.md) | Content registry — one loader, schema-validated, frozen at session start |
| [011](decisions/011-one-work-engine.md) | One work engine and behaviour extension points |
| [012](decisions/012-actors-and-components.md) | Actors and components — an accessor layer, not a new colonist shape |
| [013](decisions/013-tool-toils.md) | Tool toils — fetch_tool and drop_tool |
| [014](decisions/014-factions-and-relations.md) | Factions and relations — a new content collection and a read-only accessor |
| [015](decisions/015-regions-core-budget-increase.md) | Regions wiring raises two core budgets |
| [016](decisions/016-rooms-core-budget-increase.md) | Rooms wiring raises the world_state.gd core budget |
| [017](decisions/017-incidents-core-budget-increase.md) | Incidents wiring raises two core budgets |
| [018](decisions/018-pc-map-presentation.md) | Clipped PC map camera and explicit designation tools |
| [019](decisions/019-world-dimensions-and-generation.md) | World dimensions, pure worldgen module, and incremental map presentation |
| [020](decisions/020-river-vegetation-and-spawn-generation.md) | Main river, correlated vegetation, and river-aware spawn placement |
| [021](decisions/021-combat-resolution.md) | Generic combat resolution and targeting |
| [022](decisions/022-visual-target-16px-pixel-art.md) | Visual target — flat top-down 16 px pixel art |
| [023](decisions/023-job-queue-shared-preview-checks-core-budget-increase.md) | JobQueue's shared preview checks raise its core budget |
| [024](decisions/024-needs-decay-points-per-day.md) | Needs decay in points per day; day length 2200 ticks |
| [025](decisions/025-mining-core-budget-increase.md) | Mining wiring raises the world_state.gd core budget |
| [026](decisions/026-trench-trapped-actor-and-rescue.md) | Trench, trapped-actor and rescue — content shape, find-roll and placement rules |
| [027](decisions/027-trench-trap-escape-core-budget-increase.md) | Trap-on-entry and hostile climb-out raise the world_state.gd core budget |
| [028](decisions/028-build-job-core-budget-increase.md) | The `build` job kind raises core budgets |
| [029](decisions/029-rescue-job-giver-core-budget-increase.md) | Rescue job-giver raises the world_state.gd core budget |
| [030](decisions/030-rescue-persistence-and-reservation-fixes-core-budget-increase.md) | Rescue persistence and reservation fixes raise two core budgets |
| [031](decisions/031-rescue-route-safety-and-progress-keys-core-budget-increase.md) | Rescue route safety and per-job progress keys raise the world_state.gd core budget |
| [032](decisions/032-rescue-shared-route-budget-and-activation-safety-core-budget-increase.md) | Shared rescue route budget and post-commit route safety raise the world_state.gd core budget |
| [033](decisions/033-hostile-approach.md) | Hostile approach job-giver |
| [034](decisions/034-incident-lingering-actors.md) | Lingering incident actors (`spawn.lingers`) |
| [035](decisions/035-trader-visit-core-budget-increase.md) | Trader visit and accept_trade raise the world_state.gd core budget |
| [036](decisions/036-trader-two-way-swap-and-offer-cleanup-core-budget-increase.md) | Two-way trader swap and stale-offer cleanup raise the world_state.gd core budget |
| [037](decisions/037-hands-multi-unit-carrying.md) | A colonist's single carrying slot becomes a 4-unit "hands" list |
| [038](decisions/038-build-multi-source-fetch-efficiency.md) | `build` gains a per-job multi-source fetch plan; `build_cost` becomes a list |
| [039](decisions/039-object-footprint-rotation.md) | Object footprint, rotation, and multi-builder content fields |
| [040](decisions/040-construction-sites.md) | Persistent construction sites replace the single-worker `build` job |
| [041](decisions/041-colonist-glide-move-ticks-getter-core-budget-increase.md) | A read-only move_ticks_per_tile getter for the colonist glide raises the world_state.gd core budget |
| [042](decisions/042-build-line-batch-command.md) | `build_line` submits a whole wall/rectangle drag as one atomic command |
| [043](decisions/043-site-fetch-chained-deposit.md) | `site_fetch`'s `deposit` completion chains onto further same-kind sites |

## Content and data

| Location | What it holds |
| --- | --- |
| [`game/content/`](../game/content/) | The game rules as JSON: tiles, objects, items, jobs, needs, actors, factions, incidents, calendar, map generation, plus a manifest |
| [`game/content/schemas/`](../game/content/schemas/) | One JSON Schema per content file; `ContentRegistry` validates content at startup |
| [`game/data/text/en.json`](../game/data/text/en.json) | Player-facing English strings used by the viewer |
| [`game/data/examples/`](../game/data/examples/), [`game/data/schemas/`](../game/data/schemas/) | Early schema sketches (buildings, recipes, events, …); not loaded by the game |
| [Art style](art/style.md) | Pixel-art rules, sprite sizes, grounding and shoreline layering |
| [Terrain autotiling](art/terrain-autotile.md) | How grass/water/rock borders are composed |
| [Asset credits](../game/assets/CREDITS.md) | Every image is original, generated by `tools/generate_placeholder_art.py` |

## Testing

| Location | What it holds |
| --- | --- |
| [`game/scripts/tests/`](../game/scripts/tests/) | Headless test scripts (`test_*.gd`), frozen save fixtures (`fixtures/`) and the content-literal lint |
| [`tools/run_tests.sh`](../tools/run_tests.sh) | Runs the whole suite (bash); `game/scripts/tests/run_all_tests.ps1` is the PowerShell equivalent |
| [CI workflow](../.github/workflows/ci.yml) | JSON validation, lint, core budgets, import, boot check and the full suite on every push and pull request |

See [Running the tests](../README.md#running-the-tests) for commands.

## Contributing with AI agents

| Document | What it covers |
| --- | --- |
| [AGENTS.md](../AGENTS.md) | Operating rules for every agent and human contributor |
| [Agent ownership](architecture/agent-ownership.md) | One owner per subsystem and how changes are coordinated |
| [ADR 002](decisions/002-agent-ownership-and-review.md) | Why authors and reviewers are different agents |
| [Pull request template](../.github/PULL_REQUEST_TEMPLATE.md) | What every change must report |
| [Agent orchestrator](https://github.com/sterium-ai/agent-orchestrator) | The separate tool that assigns tasks and reviewers |
