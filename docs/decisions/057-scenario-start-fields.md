# ADR 057: Scenario start fields (roster, calendar, enabled incidents)

> **In short:** A scenario entry can now say how many colonists start (and give some of them
> their own labour priorities), which calendar the world runs on, and which incidents can
> happen. `ScenarioBuilder` hands these to `WorldState` when it is constructed, through a
> small `WorldSetup` object. The calendar and the incident list are saved (save schema v4), so
> a loaded world and a replay keep them. An
> entry that leaves the fields out (both shipped entries) builds exactly the same world as
> before.

- **Status:** accepted
- **Date:** 2026-10-29
- **Scope:** content (three optional `scenarios.json` fields), simulation (one new
  `WorldState` construction parameter), persistence (save schema v4, `scenarioStart`)
- **Extends:** ADR 054 (scenarios as content; this closes the three fields its
  "Consequences" deferred)
- **Depends on:** ADR 008 (calendar), ADR 017 (incidents), ADR 020 (spawn clearing),
  ADR 048 (composed core, size rule)
- **Implements:** BACKLOG A16b

## Context

ADR 054 left three scenario fields out because each needed a construction parameter the world
did not have: the colonist count came only from `mapgen.json`'s `colonist_count`, the calendar
only from `calendar.json`, and `IncidentScheduler` had one on/off switch. `world_state.gd` was
at 790 of its 800-line cap, so the parameters had to fit without growing it.

## Decision

### Content: three optional fields on a scenario entry

| Field | Meaning |
| --- | --- |
| `roster` | `{count, colonists?}`. `count` replaces `mapgen.json`'s `colonist_count` for this world: it sets how many colonists spawn and sizes the spawn clearing's food sources exactly as `colonist_count` does (`WorldGenerator.place_spawn()`). It may not exceed the rectangular spawn clearing (`spawn_area_width` × `spawn_area_height`, 36 tiles today), because `place_spawn()` prefers that clearing whenever one exists and puts one colonist per tile. `colonists[i]`, when present, defines `colonist_i`: today only `{"labour": {kind: level}}`, written over the colonist's default labour table. Colonists past the list keep `actors.json`'s defaults. |
| `calendar` | A whole calendar document (the shape of `calendar.schema.json`: `day_length_ticks` and `windows`), used instead of `calendar.json`. Its day length drives everything that reads the world's calendar: labour boosts, calendar alerts, needs' per-day rates and the incident day. |
| `incidents` | A non-empty list of `incidents.json` ids. Only these enter the daily draw. Omitted means every incident, as before. "No incidents" stays `incidents_enabled: false`, which is still the master switch (callers and replays override it through `options.incidents_enabled`). |

`ContentRegistry._check_scenario_start()` cross-checks them at load time, each failing typed and
naming `scenarios.json`:

- `schema_violation`: a `count` larger than the spawn clearing; more `colonists` definitions than `count`; a labour that is not one of the
  colonist's declared `worker.labours`, or a level that is not an integer within its
  `labour_min`..`labour_max` (the same rule as `set_labour`); a calendar window id listed twice;
  an incident listed twice. The schema also rejects a roster without `count`, a calendar without
  `day_length_ticks`/`windows` and an empty incident list.
- `dangling_reference`: a calendar window naming an undeclared labour; an incident id that is
  not in `incidents.json`.

### Code

- `core/world/world_setup.gd` (`WorldSetup`) is the construction input: plain data with no
  `WorldState` reference. `WorldSetup.from_scenario(entry)` reads the three fields; a default
  `WorldSetup` is the base start (`mapgen.json`'s count, `calendar.json`, every incident).
- `WorldState._init()` takes it as a last optional parameter (`setup`, `null` = default):
  - world seeding receives `setup.seeding_mapgen(mapgen)`, a copy of `mapgen.json` with the
    roster's `colonist_count`, and the per-colonist definitions. `WorldSeeding` writes each
    definition's levels into the spawned `labourTable` in place, so the table's key order (which
    `state_hash()` reads) never changes;
  - `CalendarService` is built from `setup.calendar_document(content)`;
  - `IncidentScheduler` receives `setup.enabled_incidents`. `_run_daily_draw()` skips an id not
    in a non-empty list before any other test, so no RNG draw happens for it; with an empty list
    the draw is the same code path as before. The debug `spawn_incident` command still bypasses
    the list, as it already bypasses `min_day`, cooldowns and the budget.
- `ScenarioBuilder.build()` passes `WorldSetup.from_scenario(scenario)` to the constructor.
  Setup steps then see the scenario roster (`per_colonist_objects` places one bed per colonist
  of the scenario's roster). If the world spawned fewer colonists than the roster's `count` (a
  spawn search that fell back past the rectangular clearing), the builder pushes an error and
  returns `null`, as for an unknown scenario: a roster is never truncated silently.
- To keep `world_state.gd` under its cap, two blocks moved out unchanged: the content startup
  checks (`WorldSetup.startup_tables()`: tool requirements, then the haul entry, the same
  messages in the same order) and the after-load incident reconciliation
  (`IncidentScheduler.reconcile_after_load()`, same statements; `WorldState` keeps a one-line
  delegator for `StateCodec`). `world_state.gd` goes from 790 to 783 lines (789 to 782 once A9 landed).

### Persistence: save schema v4

The calendar and the incident list keep ruling the world after tick 0 (day length, boosts,
alerts, needs' per-day rates, the incident draw), so they are save state. The roster is not:
the saved entities already are the roster.

- New required top-level field `scenarioStart`: `{"calendar": <calendar document> | null,
  "enabledIncidents": [<incident id>, ...]}`. `null` is `calendar.json` and `[]` is every
  incident, so a base-start world saves `{"calendar": null, "enabledIncidents": []}` and keeps
  following the content files as before.
- `WorldSetup.encode()`/`WorldSetup.decode()` convert it; `StateCodec.decode()` builds the world
  from the decoded setup (the roster fields stay at the base start: the saved entities replace
  the generated ones). A replay starts from a save, so it keeps them too.
- `StateCodec.SCHEMA_VERSION` 3 → 4; `SaveMigrations` v3 → v4 adds the base start (exactly what a
  v3 world ran on) and refuses a v3 state that already has the field;
  `CalendarValidator._valid_scenario_start()` validates the shape;
  `docs/architecture/contracts/game-state.schema.json` and `save-system.md` describe it; the
  fixture `save_schema_v4_fixture.json` is the v1/v2/v3 fixtures' session written at v4.
- **Numbering:** v3 is A13b's (`contentPacks`, ADR 010 amendment 2), which landed first; this
  change was written as v2 → v3 and renumbered to v3 → v4 when rebased onto it.
- `scenarioStart` is checked after `contentPacks`: a save on a scenario pack names the missing
  pack (`content_packs_mismatch`), and loads only on that pack's session registry.
- `scenarioStart` is not in `state_hash()`, like the content files it replaces.

### Determinism

Every new input is content, read at construction; no new RNG stream. A scenario that uses none of
the fields takes exactly the old code paths: the shipped `new_game` and `debug` entries build
identical event logs and 100 ticks of `state_hash()`, and saves that differ from `main`'s only by
`schemaVersion` 4 and the added base-start `scenarioStart` (the A16 probe,
`docs/orca/handoffs/A16-scenario_dump.gd`, compared by `A16b-compare_probe.py`; see
`docs/orca/handoffs/A16b.md`).

## Alternatives considered

- **Run the roster as setup steps** (spawn extra colonists, `set_labour` commands). Rejected: the
  colonist count also sizes the spawn clearing and its food, which only world seeding decides,
  and extra commands would add events a scenario start does not need.
- **Override `calendar.json` through a content pack.** Rejected: a pack changes every scenario in
  the session, and calendar is a document kind, not a mergeable collection.
- **Replace `incidents_enabled` with the list.** Rejected for now: the switch is the override
  `DebugScenario.build()`, the replay log (`incidentsEnabled`) and the tests already use; a list
  on top of it changes none of them.
- **Save the scenario id instead of the two values.** Rejected: the entry may come from a pack
  that is not loaded next time, or change between versions, and the save would then silently run
  on other rules; the values themselves keep a save self-contained.
- **Add the parameters to `WorldState` directly.** Rejected by the size rule (ADR 048):
  `WorldSetup` keeps the start inputs in one typed place and leaves room in `world_state.gd`.

## Consequences

- A scenario can now be a small colony, a big one, a short-day or long-day world, or a quiet start
  with only peaceful visitors, as content only.
- The calendar and incident list are saved (schema v4); `incidents_enabled` is still not (the
  boot layer re-applies it after a load, as before).
- A roster larger than the spawn clearing is rejected rather than placed in a bigger clearing:
  growing the clearing would change `WorldGenerator.place_spawn()`, which is at its frozen size
  exception (870 lines).
- Per-colonist definitions only carry labour levels. Names, traits or starting gear would be new
  definition fields with their own checks.
- `ContentRegistry.COLONIST_COUNT` still mirrors `mapgen.json`'s default; it is the base start,
  not every world's count.

## Acceptance criteria

- [x] The affected canonical documents are updated: this ADR, `scenarios.schema.json` (the
  contract), `extension-points.md` ("Scenario"), `game-state.schema.json` and `save-system.md`.
- [x] Contracts, examples and tests: `scenarios.schema.json`, `game-state.schema.json`,
  `game/scripts/tests/test_scenario_start.gd`, `test_save_migration.gd`.
- [x] Save/migration impact: schema v4 with its v3 → v4 migration and the v4 fixture.
- [x] The source-of-truth index still points to `scenarios.schema.json`.
