# ADR 054: Scenarios as content

> **In short:** How a new world is set up now lives in `content/scenarios.json` instead of
> two viewer scripts. Each scenario entry gives the map size, the seed, the tick rate,
> whether incidents are on, and an ordered list of setup steps taken from a small fixed set.
> `ScenarioBuilder` (core) builds a world from one entry. The default New Game is the
> `new_game` entry and the old debug scenario is the `debug` entry. Both build exactly the
> same worlds as before.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** content (a new collection kind), simulation (a caller-side world factory in the
  core), presentation (`boot.gd`, the New Game dialog, `debug_scenario.gd`)
- **Depends on:** ADR 010 and its A13 amendment (content registry, packs, one session
  registry), ADR 020 (river-aware spawn clearing and its land-tile pool), ADR 048 (composed
  core, size rule), ADR 052 (localisation-ready text: content labels are text keys)
- **Implements:** BACKLOG A16; `docs/architecture/foundation-audit.md` row "Scenarios and levels"

## Context

There were two ways to start a world, both written as code in the viewer:

- **New Game** (`boot.gd` `build_default_world()` and `viewer/new_game_setup.gd`): a world at
  `mapgen.json`'s default size with incidents on, one ground tool for each `needs_tool` in
  `jobs.json`, and one bed per colonist.
- **Debug Scenario** (`viewer/debug_scenario.gd`): a 48×48 world with a seeded wall line and
  door, chairs and tables, a berry bush and a bed, 24 seeded dig orders and, for its own seed
  only, a pre-tilled plot and a seed stock.

The numbers, kinds and seed offsets were constants in GDScript. Adding a third start meant
writing a third script. `debug_scenario.gd` also wrote `world._colonists`, `world._items` and
`world._next_item_id` from the viewer, which `foundation-audit.md` lists as a boundary leak.
Placing a tool needs `spawn_ground_tool_item()`, and viewer scripts may not call it
(`test_architecture_rules.gd`), so `boot.gd` had to pass that method into `new_game_setup.gd`
as a callable.

## Decision

### Content: `content/scenarios.json`

`scenarios` is a collection kind keyed by `id`, validated by
`content/schemas/scenarios.schema.json`. Each entry has:

| Field | Meaning |
| --- | --- |
| `id`, `label` | Registry id, and the `data/text` key of the name the New Game dialog shows (resolved through `TextTable`, ADR 052; for example `scenario.new_game`). |
| `seed` (optional) | The scenario's own seed. If it is missing, the caller must supply one (the New Game dialog's seed field). |
| `map` (optional) | `{width, height}`. If it is missing, `mapgen.json`'s default New Game size is used. |
| `tick_rate` | Ticks per second for the new world. A New Game started from the dialog uses it unless the caller passes a rate. |
| `incidents_enabled` | Whether the incident scheduler runs (`WorldState.enable_incidents()`). |
| `setup` | Ordered list of steps (below). |

Each setup step is `{"step": <name>, ...fields}`, plus an optional `"when": "scenario_seed"`.
A step with `when` runs only if the world's seed equals the entry's own `seed`. The registry
rejects `when` in a scenario that has no seed. The step vocabulary is closed (a schema
`enum`). The fields each step reads are listed in `ContentRegistry.SCENARIO_STEP_FIELDS`, and
the registry requires each step to carry exactly those fields, no more and no fewer:

| Step | Fields | What it does |
| --- | --- | --- |
| `needed_tools` | — | Places one ground tool for each distinct `needs_tool` in `jobs.json` (sorted) on the spawn clearing's land pool, using `spawn_ground_tool_item()`. |
| `per_colonist_objects` | `kind` | Places one `kind` object per colonist with `place_object`, on the pool tiles after the ones earlier pool steps took. |
| `object_rows` | `seed_offset`, `rows` | Places rows of objects at the clearing's left edge, on the clearing's top or bottom edge plus `offset`. Each row takes the first tiles that are neither tree nor water. If a row has a `door`, one random tile in it gets that kind instead, drawn from `seed + seed_offset`. |
| `dig_orders` | `count`, `seed_offset`, `priority` | Submits `count` dig orders at tick 0 on random soil tiles, drawn from `seed + seed_offset`. |
| `till_plot` | `search_radius`, `tick_budget` | Submits a HIGH-priority till order on the free soil tile nearest a colonist, then ticks until that tile is plowed, at most `tick_budget` ticks. |
| `ground_items` | `kind`, `count`, `search_radius` | Drops one stack of `count` `kind` items on the free soil tile nearest a colonist, never on the till target. `kind` may not be a tool item (`items.json` kind `tool`). Tools live in `ToolItemStore`, where `fetch_tool` finds them, so they are placed by `needed_tools`. |

Cross-file checks run at load time (`ContentRegistry._check_scenarios()`). Each object kind a
step names (`per_colonist_objects.kind`, each row object and each `door`) must be declared in
`objects.json`, and the `ground_items` kind must be declared in `items.json`. A violation is
a typed `dangling_reference`. A field mismatch, a seedless `when`, or a `ground_items` step
naming a tool item is a typed `schema_violation`. Both errors name `scenarios.json`.

`scenarios` is an **optional** collection kind (`OPTIONAL_COLLECTION_KINDS`). A bundle
without it still loads, so the minimal fixture bundles the registry tests write stay valid.
When it is present it loads, is cross-checked and accepts packs exactly like the required
kinds, so a content pack can add or override a scenario.

### Code: `game/scripts/core/world/scenario_builder.gd`

`ScenarioBuilder.build(content, scenario_id, options)` builds a `WorldState` from the session
registry (A13) and runs the entry's active steps in order. `options` may override `seed`,
`tick_rate` and `incidents_enabled`. It returns `null` and pushes an error when the scenario
is unknown or no seed is available. The step algorithms moved here from `debug_scenario.gd`
and `new_game_setup.gd` statement for statement. The constants they used now come from the
step fields.

The builder is a **caller-side factory**, not a `WorldState` module. It creates the world and
drives it like any other client, through `apply()`, `tick()`, `enable_incidents()`, the read
getters and `spawn_ground_tool_item()`. That last call is now possible because the builder is
in the core, so no callable has to be passed in. Two bootstrap writes from the old debug
scenario remain, and each is documented on its step:

- `till_plot` tops up the colonists' needs before each of its ticks, reading them through
  `ActorTable.get_component()`, so a need interruption cannot keep the till job from
  finishing within the budget.
- `ground_items` writes the item table directly, because no command spawns a stackable ground
  item.

Neither write is new. Both moved out of the viewer, which closes the viewer-side leak
`foundation-audit.md` lists. A command or toil that removes them is follow-up work.

Shared choices are computed lazily, once, so their timing matches the old code exactly. The
colonist snapshot is taken from `get_colonists()` copies when a step first needs it. The till
target is chosen when `dig_orders` (which must not offer that tile) or `till_plot` first asks
for it.

The spawn-pool steps, `needed_tools` and `per_colonist_objects`, share a single cursor into
the clearing's land-tile pool. Each step takes tiles from the cursor on and moves the cursor
past them, so a scenario with beds and then chairs gets distinct tiles for every tool, bed
and chair. For the shipped `new_game` (tools, then beds) the cursor gives exactly the tiles
the old fixed "past the tools" offset gave.

### Presentation

- `boot.gd` `build_default_world(seed, tick_rate = null, content, scenario_id = "new_game")`
  delegates to the builder. A `null` tick rate keeps the scenario's own rate. `_start_new_game()`
  takes the scenario the dialog picked and does not override its rate. The Debug Scenario
  button builds the `debug` entry on the session registry.
- `viewer/new_game_dialog.gd` gets a scenario picker that lists the registry's scenarios by
  their translated label, with `new_game` preselected. The seed field still applies. A scenario with its own seed then runs
  without its `when` steps, just as `DebugScenario.build(other_seed)` always did.
- `viewer/debug_scenario.gd` becomes a thin wrapper around the `debug` entry. It keeps
  `build(seed, tick_rate, incidents_enabled)` for its callers, and `scenario_seed()` and
  `starting_seed_count()` replace the old constants.
- `viewer/new_game_setup.gd` is deleted. All of its logic is now the `needed_tools` and
  `per_colonist_objects` steps.

### Determinism, saves and versioning

The builder draws only from the world's seeded streams and from fresh `RandomNumberGenerator`s
seeded with `seed + seed_offset`, so the same scenario, content and options always produce the
same `state_hash()`. Scenarios are read only while a world is being built. A running or saved
world never refers to its scenario, so the save format, `state_hash()` coverage and the
content manifest version are all unchanged (no schema bump, no migration). The A16 harness
`docs/orca/handoffs/A16-scenario_dump.gd` shows the saved state, the event log and 100 ticks
of hashes are byte-identical to `main` for three New Game seeds and three debug-scenario
builds.

## Alternatives considered

- **Fully declarative placement** (absolute tile lists for objects and items). This cannot
  express "next to the spawn clearing" or "nearest soil to a colonist" on a generated map,
  and the default New Game could not stay byte-identical. Rejected. Fixed-map scenarios can
  add such a step later.
- **Keep the builder in the viewer.** It could not place tools without a callable, it would
  keep the private-field writes in the viewer, and headless tools could not build a scenario
  without viewer scripts. Rejected.
- **Make `scenarios` a required kind.** Every registry fixture bundle in the tests would need
  a `scenarios.json` that has nothing to do with what those tests check. Rejected in favour
  of an optional kind that the base bundle ships and `test_scenarios.gd` requires.
- **A `scenario` field in `WorldState._init()`.** That would put setup policy inside the
  façade, which is at its size limit (800 of 800 lines since A5). Rejected.

## Consequences

- A new start (a tutorial, a test arena, a pack's own start) is now a content entry, built
  from the existing steps. A start that needs a new kind of placement needs a new step in
  `ScenarioBuilder` and `SCENARIO_STEP_FIELDS`, plus a schema `enum` value.
- **Deferred from the A16 goal, with the owner's approval.** The owner decided this in A16's
  first review round ("Aprobar alcance reducido"; recorded in BACKLOG A16), and the work is
  backlog task A16b. Each of these needs a construction parameter that `WorldState` or
  `WorldGenerator` does not have yet:
  - a per-scenario starting roster: the colonist count is `mapgen.json`'s `colonist_count`,
    which `ContentRegistry.COLONIST_COUNT` mirrors at compile time;
  - a per-scenario calendar: `CalendarService` reads `calendar.json`;
  - a per-incident enable list: `IncidentScheduler` has a single on/off switch.

  The schema leaves these fields out instead of accepting values it would ignore.
- Win and lose conditions are A17 (story layer), not scenario fields.
- `content_registry.gd` is at 798 of 800 lines. The next registry rule has to move
  validation into its own module first.

## Acceptance criteria

- [x] The affected canonical documents are updated: this ADR, `extension-points.md` (new
  "Scenario" section) and `foundation-audit.md` (§3.6 status).
- [x] Contracts, examples and tests: `scenarios.schema.json`, `scenarios.json`,
  `game/scripts/tests/test_scenarios.gd`.
- [x] Save/migration impact: none (scenarios are build-time only), shown by the A16 dump.
- [x] The source-of-truth index (`docs/architecture/source-of-truth.yaml`) points to
  `scenarios.schema.json` as the scenario contract.
