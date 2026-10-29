# ADR 057: Scenario start fields (roster, calendar, enabled incidents)

> **In short:** A scenario entry can now say how many colonists start (and give some of them
> their own labour priorities), which calendar the world runs on, and which incidents can
> happen. `ScenarioBuilder` hands these to `WorldState` when it is constructed, through a
> small `WorldSetup` object. An entry that leaves them out (both shipped entries) builds
> exactly the same world as before.

- **Status:** accepted
- **Date:** 2026-10-29
- **Scope:** content (three optional `scenarios.json` fields), simulation (one new
  `WorldState` construction parameter)
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
| `roster` | `{count, colonists?}`. `count` replaces `mapgen.json`'s `colonist_count` for this world: it sets how many colonists spawn and sizes the spawn clearing and its food sources exactly as `colonist_count` does (`WorldGenerator.place_spawn()`). `colonists[i]`, when present, defines `colonist_i`: today only `{"labour": {kind: level}}`, written over the colonist's default labour table. Colonists past the list keep `actors.json`'s defaults. |
| `calendar` | A whole calendar document (the shape of `calendar.schema.json`: `day_length_ticks` and `windows`), used instead of `calendar.json`. Its day length drives everything that reads the world's calendar: labour boosts, calendar alerts, needs' per-day rates and the incident day. |
| `incidents` | A non-empty list of `incidents.json` ids. Only these enter the daily draw. Omitted means every incident, as before. "No incidents" stays `incidents_enabled: false`, which is still the master switch (callers and replays override it through `options.incidents_enabled`). |

`ContentRegistry._check_scenario_start()` cross-checks them at load time, each failing typed and
naming `scenarios.json`:

- `schema_violation`: more `colonists` definitions than `count`; a labour that is not one of the
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
  of the scenario's roster).
- To keep `world_state.gd` under its cap, two blocks moved out unchanged: the content startup
  checks (`WorldSetup.startup_tables()`: tool requirements, then the haul entry, the same
  messages in the same order) and the after-load incident reconciliation
  (`IncidentScheduler.reconcile_after_load()`, same statements; `WorldState` keeps a one-line
  delegator for `StateCodec`). `world_state.gd` goes from 790 to 783 lines.

### Determinism

Every new input is content, read at construction; no new RNG stream. A scenario that uses none of
the fields takes exactly the old code paths: the shipped `new_game` and `debug` entries build
byte-identical saves, event logs and 100 ticks of `state_hash()` (the A16 probe,
`docs/orca/handoffs/A16-scenario_dump.gd`; see `docs/orca/handoffs/A16b.md`).

## Alternatives considered

- **Run the roster as setup steps** (spawn extra colonists, `set_labour` commands). Rejected: the
  colonist count also sizes the spawn clearing and its food, which only world seeding decides,
  and extra commands would add events a scenario start does not need.
- **Override `calendar.json` through a content pack.** Rejected: a pack changes every scenario in
  the session, and calendar is a document kind, not a mergeable collection.
- **Replace `incidents_enabled` with the list.** Rejected for now: the switch is the override
  `DebugScenario.build()`, the replay log (`incidentsEnabled`) and the tests already use; a list
  on top of it changes none of them.
- **Add the parameters to `WorldState` directly.** Rejected by the size rule (ADR 048):
  `WorldSetup` keeps the start inputs in one typed place and leaves room in `world_state.gd`.

## Consequences

- A scenario can now be a small colony, a big one, a short-day or long-day world, or a quiet start
  with only peaceful visitors, as content only.
- **Not persisted.** Like `incidents_enabled`, the start fields are construction inputs, not save
  state. The roster survives a save (the colonists and their labour tables are entities), but a
  loaded world, and a replay (which starts from a save), runs on `calendar.json` and every
  incident. Persisting the scenario id (or the two fields) needs a save schema change and is
  follow-up work, to be coordinated with A13b's schema v3.
- Per-colonist definitions only carry labour levels. Names, traits or starting gear would be new
  definition fields with their own checks.
- `ContentRegistry.COLONIST_COUNT` still mirrors `mapgen.json`'s default; it is the base start,
  not every world's count.

## Acceptance criteria

- [x] The affected canonical documents are updated: this ADR, `scenarios.schema.json` (the
  contract), `extension-points.md` ("Scenario").
- [x] Contracts, examples and tests: `scenarios.schema.json`,
  `game/scripts/tests/test_scenario_start.gd`.
- [x] Save/migration impact: none (no persisted field changes); the limitation above is recorded.
- [x] The source-of-truth index still points to `scenarios.schema.json`.
