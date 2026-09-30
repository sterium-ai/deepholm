# Behaviour extension points

> **In short:** A step-by-step guide to adding new behaviour, such as a new
> job, creature, faction or building, in the places the design expects, so the
> game stays consistent.

This is the recipe for adding behaviour under the one-work-engine rule. A
colonist action is a job, a job is a list of toils, and a decision about when
that job exists belongs to a job giver. WorldState owns state, validation, and
orchestration; it is not a place to add behaviour.

Command handlers such as `accept_trade` and `set_faction` are ordinary
WorldState orchestration: they validate and mutate state through existing
boundaries and are not a separate extension point.

## Content

- Files: `game/content/jobs.json` and the relevant content JSON (items,
  objects, needs, actors, tiles, mapgen, or calendar), plus the matching schema under
  `game/content/schemas/*.schema.json` (co-located by file name, e.g.
  `jobs.json` / `jobs.schema.json`) when a field's shape changes. Every
  content file loads once through `ContentRegistry`
  (`game/scripts/core/content/content_registry.gd`), which validates it
  against its schema, cross-checks references (a job's `needs_tool` naming a
  declared item, a job's toils naming toils `ToilExecutor` implements, a
  need's `source_kind` naming a declared object kind), and freezes the bundle
  at session start; callers read it through `get_entry(kind, id)`,
  `list(kind)`, `document(kind)`, and `version()` rather than a hand-rolled
  constant or a fresh file read. A missing file, a schema violation, or a
  dangling reference leaves the registry invalid with a typed error
  (`get_error(): {code, message, file}`) instead of a partially-populated
  bundle; `WorldState._init()` treats an invalid registry as fatal. Update
  the applicable schema/contract docs.
- Test: extend the focused content test, such as `test_forage_content.gd` or
  `test_calendar.gd`; extend `test_content_registry.gd` when the loader,
  validator, or reference checks themselves change.
- Example: the `eat_food`, `drink_water`, and `sleep` definitions in
  `content/jobs.json` describe need jobs as data, including their toil lists;
  `test_need_jobs.gd` verifies the definitions and their execution. See
  [ADR 010](../decisions/010-content-registry.md) for the registry's own
  design.

### Actor definition / Component

- Files: add an actor definition to `game/content/actors.json`, selecting
  components and their tunables. Reuse existing components for a new actor
  kind; a new component also needs a plain GDScript implementation under
  `game/scripts/core/actors/components/*.gd`, registered in
  `game/scripts/core/actors/actor_table.gd` for validation and spawn/accessor
  dispatch, with the vocabulary/tunables reflected in
  `game/content/schemas/actors.schema.json`. `ContentRegistry` validates
  actor definitions like jobs and needs: schema checks, known-component
  references, and each component's `validate(tunables)` must pass before the
  bundle is usable.
- Test: extend `test_actor_table.gd` for definitions, component state and
  invalid tunables/references; use `test_actor_field_lint.gd` to check that
  core consumers use the component accessors.
- Example: `colonist`, `wolf`, and `trader` in `content/actors.json` select
  from the existing component vocabulary. See
  [ADR 012](../decisions/012-actors-and-components.md) for the accessor-layer
  design; component logic still uses the single work engine.

## Toil

- Files: add or extend the vocabulary and execution rules in
  `game/scripts/core/jobs/toil_executor.gd`; update `content/jobs.json` when
  the toil is used by a job. Add an ADR when the vocabulary or boundary grows.
- Test: extend `test_toils_dig_chop_regression.gd`, or the focused job test for
  the new toil and its failure/release paths.
- Example: `consume` is implemented once by `toil_executor.gd` and is used by
  the need jobs; `test_need_jobs.gd` checks the known toil and its completion.
  `deposit` ([ADR 040](../decisions/040-construction-sites.md)) is a second
  example: a new verb rather than an extension of `place`, because its
  destination (a construction site's `held_materials`) has no "cell still free"
  precondition and no ground-item side effect. Branching `place` on "is this a
  site or a cell" would be exactly the per-kind special case a new verb exists
  to avoid. `test_construction_site.gd` checks it.

## Job-giver

- Files: add a module under `game/scripts/core/jobs/givers/` and wire it from
  `world_state.gd` only as orchestration. Submit through the shared
  `jobs/job_queue.gd`; do not create a parallel queue or colonist loop.
- Test: extend the giver's scenario test, such as `test_need_jobs.gd` or
  `test_haul_stockpile.gd`, including blocked and retry cases.
- Example: `need_giver.gd` creates need jobs from thresholds, while
  `haul_giver.gd` creates haul jobs from eligible items and destinations;
  `test_haul_need_interrupt.gd` covers their interaction. `construction_giver.gd`
  decides when a construction site's next fetch or work job
  should exist, reading `ConstructionSiteTable` state `world_state.gd` owns
  rather than tracking its own parallel notion of site progress;
  `test_construction_site.gd` covers its fetch/work scheduling and blocked
  cases.

## Presentation

- Files: update the presentation layer (`game/scripts/presentation/`, or the
  existing panel/boot script) to read state and diagnostics. Do not put a
  decision or simulation rule there.
- Test: extend the matching UI contract test, such as
  `test_colonist_panel_toil.gd` and `test_colonist_panel.gd`.
- Example: `colonist_panel.gd` resolves a colonist's active job and toil and
  renders need activity; `test_colonist_panel_toil.gd` verifies the displayed
  toil during a job.

## Contract

- Files: update the relevant canonical contract in `docs/architecture/`, the
  data schema/example, and a numbered ADR in `docs/decisions/` when the
  boundary or public shape changes. Respect `source-of-truth.yaml` precedence.
- Test: extend `test_architecture_rules.gd` for structural rules and the
  focused behaviour test for runtime semantics.
- Example: ADR 008 and `content/calendar.json` define the calendar window
  shape; `test_calendar.gd` checks the schema and pure service behaviour.
  `build_line` ([ADR 042](../decisions/042-build-line-batch-command.md)) is a
  command handler like `accept_trade`/`set_faction` above — ordinary
  `WorldState` orchestration, not a new extension point — but its batch
  payload shape and its whole-set enclosure-atomicity rule change the command
  contract, hence the ADR; `test_wall_orders.gd` checks it.

## Faction

- Files: add or edit an entry in `game/content/factions.json` (`{id, relations, rules}`;
  `relations` needs one row for every *other* declared faction, `rules` is the three flat
  booleans `may_pass_doors`, `may_reserve_colony_items`, `may_be_ordered`). Adding a faction
  means adding its own entry *and* adding a relation row to it in every other existing
  faction's `relations` map — `ContentRegistry` requires a row both ways between every pair,
  and relations may be asymmetric (a wolf's relation to the colony need not equal the colony's
  relation to wolves), so neither direction can be inferred from the other. Validated against
  `game/content/schemas/factions.schema.json` and cross-checked by `ContentRegistry` like any
  other collection (a missing relation row, an unknown relation value, or an actor's
  `faction_id` naming an undeclared faction is `ERROR_DANGLING_REFERENCE`). Read relations
  through `game/scripts/core/relations/relations.gd` (`relation(a, b)`,
  `is_hostile(actor_a, actor_b)`) rather than a hand-rolled lookup. A faction's rules are
  consulted at runtime in several places, not only in `game/scripts/core/world_state.gd`:
  `passability(x, y, faction_id)`'s `_faction_may_pass_doors()` gate on door objects; the
  reservation gate `GlobalAssignment.set_reservation_gate()` wires to
  `_colonist_may_reserve_colony_items()`/`_faction_may_reserve_colony_items()`; the
  order/job-giver gate `GlobalAssignment.set_order_eligibility()` wires to
  `_colonist_may_be_ordered()`/`_faction_may_be_ordered()`, consulted by `GlobalAssignment`
  before a worker may be proposed for or resume any job; and
  `game/scripts/core/jobs/givers/need_giver.gd`'s own `_may_be_ordered()` reads
  `rules.may_be_ordered` directly to filter an actor out of `advance()` before its needs are
  evaluated. A new faction needs no change to any of these call sites; a new *rule* does.
- Test: extend `test_factions.gd` for a new faction's registry shape and `Relations` behaviour;
  extend `test_faction_doors.gd` for a passability change, `test_faction_reservations.gd` for a
  reservation-gate change, and `test_order_input.gd`/`test_set_faction_command.gd` for an
  order-eligibility or faction-mutation change; extend `test_content_registry.gd` when the
  loader, schema, or cross-reference checks themselves change.
- Example: `colony`, `wildlife`, `raiders`, `traders`, `allies` in `content/factions.json` are
  each one entry with a relation row per other faction and the three rule booleans — adding a
  sixth faction is its own new `content/factions.json` entry *plus* a relation row to it added
  into each of the five existing entries' `relations` maps (both directions must be given
  explicitly since a relation need not be symmetric), no core code to hand-edit. A faction that
  may *act* without being ordered — a hostile raid that arrives and attacks on its own — still
  needs F5's incident and combat work ([foundation-for-breadth.md](foundation-for-breadth.md)); this extension point only
  declares who may pass doors, reserve colony items, and be given player orders, not what an
  unordered actor decides to do. See [ADR 014](../decisions/014-factions-and-relations.md) for
  the collection's design and its amendments wiring the three consultation points above.

## Incident

- Files: add or edit an entry in `game/content/incidents.json` (`{id, faction, min_day,
  weight, cooldown_days, spawn: {actor_def, count, edge, wait_ticks, lingers}}`), validated against
  `game/content/schemas/incidents.schema.json` and cross-checked by `ContentRegistry` like any
  other collection (an unknown `faction` or `actor_def` is `ERROR_DANGLING_REFERENCE`; `spawn.lingers`
  is an optional boolean, default `false`, with nothing to dangle). When `spawn.lingers` is `true`,
  `IncidentScheduler.on_job_finished()` leaves the spawned actor in the world instead of despawning it
  once its own walk-then-wait job completes, handing it off to whatever generic per-tick system
  already has work queued for it (e.g. `ApproachGiver`'s own hostile search, ADR 033) — see
  [ADR 034](../decisions/034-incident-lingering-actors.md) for why this exists and exactly how it
  works in `incident_scheduler.gd`, including the documented gap that a lingering actor's
  in-flight status is not persisted across save/reload. Fired by
  `game/scripts/core/incidents/incident_scheduler.gd`'s seeded, budgeted daily draw
  (`WorldState.tick()` calls it once per day boundary) or on demand through the `spawn_incident`
  command (`{"type": "spawn_incident", "payload": {"id": ...}}`, dispatched by the debug viewer's
  own per-incident buttons in `boot.gd`'s `_make_incident_buttons()`/`spawn_incident()`); either
  path proposes the declared actor(s) through the same job queue every other actor uses and
  records one `incident_started` event (`{incident_id, faction, actor_ids}`) via
  `WorldState.get_events()`. A new actor kind an incident spawns is an
  [actor definition](#actor-definition--component), not new incident code; a new lookup-table
  entry for how a renderer should draw that actor kind belongs in
  `game/scripts/viewer/tile_atlas_map.gd`'s `ACTOR_ATLAS_MAP`, reusing an already-registered
  atlas cell the same way `OBJECT_ATLAS_MAP`'s entries do, unless new art is explicitly in scope.
- Test: extend `test_incidents.gd` for the scheduler's budget draw, spawn/despawn lifecycle, and
  the debug command; extend `test_content_registry.gd` when the loader, schema, or cross-reference
  checks themselves change; extend `test_colonist_panel.gd`/`boot.gd`'s own alert-list test when a
  presentation change (surfacing `incident_started`, drawing a spawned actor) is added.
- Example: `wildlife_wander` (wolves via the `west` edge) and `trader_visit` (a trader via the
  `east` edge) in `content/incidents.json` are each one entry naming an existing faction and actor
  definition; `boot.gd`'s `_update_need_alerts_label()` appends one line per `incident_started`
  event to the same standing-alert list the need-unmet/need-source-missing lines already populate.
  This is presentation-only: it adds no simulation rule and only reads
  `WorldState.get_events()`. See [ADR 014](../decisions/014-factions-and-relations.md) for the
  faction rules incidents spawn actors into and
  [foundation-for-breadth.md](foundation-for-breadth.md)'s F5 section for the incident model's design.

## Stations

- Files: add a row to `game/content/objects.json` (`footprint`, `rotatable`, `build_cost`,
  `build_ticks`, `max_builders`, like every other buildable kind) and an atlas cell for it in
  `game/scripts/viewer/tile_atlas_map.gd`'s `OBJECT_ATLAS_MAP` (or accept the placeholder/no-art
  rendering when new art is out of scope, as it was for `workbench` in the construction-site
  work). That is the whole extension: the construction-site model
  ([ADR 040](../decisions/040-construction-sites.md)) reads every object kind's `build_cost`/
  `build_ticks`/`max_builders` generically through `ConstructionGiver`/`ConstructionSiteTable`, and
  the `build`/`cancel_site` commands validate any kind the same footprint-aware way. A station that
  needs a colonist to actually *use* it once built (a crafting bench consuming/producing items, not
  merely being constructed) is a [job-giver](#job-giver) reading `get_object`/`get_construction_site`
  the same way `need_giver.gd` already reads bed/water/berries sources — still no new core
  simulation class. Workbench art and a crafting job giver were explicit non-goals of the
  construction-site design, which covers only the construction mechanism itself.
- Test: extend `test_object_storage.gd`/`test_forage_content.gd` for the new `objects.json` row;
  extend `test_construction_site.gd`/`test_build.gd` if the new kind's own footprint/cost/duration
  shape exercises a construction-site path the existing fixtures do not already cover.
- Example: `workbench` is exactly one `content/objects.json` row
  (`footprint: [2, 1]`, `rotatable: true`, `build_cost: [{wood, 3}, {stone, 4}]`,
  `build_ticks: 120`, `max_builders: 2`) — no new simulation code, since
  `_apply_construction_submission()`/`ConstructionGiver`/`ConstructionSiteTable` already
  generalize over every `build_cost`-bearing kind.

Keep core classes scene-independent and deterministic. A new job giver or
toil must flow through the existing queue, scheduler, and consolidated toil
executor. A per-colonist loop, re-route path, or job-state machine elsewhere is
not an extension; it is a defect.
