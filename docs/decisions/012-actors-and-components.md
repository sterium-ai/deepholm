# ADR 012: Actors and components — an accessor layer, not a new colonist shape

- **Status:** accepted
- **Date:** 2026-09-20
- **Scope:** content (`game/content/actors.json`, `game/content/schemas/actors.schema.json`),
  content loading (`game/scripts/core/content/content_registry.gd`), the actor table
  (`game/scripts/core/actors/actor_table.gd`, `game/scripts/core/actors/components/`),
  colonist spawning (`game/scripts/core/world_state.gd`)
- **Implements:** F2 in `docs/architecture/foundation-for-breadth.md`; issue #281 (task t1 of #266).

## Decision

`content/actors.json` declares three actor definitions — `colonist`, `wolf`, `trader` — each
naming a `components` array from a closed vocabulary (`mover`, `worker`, `needs`, `health`,
`inventory`, `combat`, `wild`, `visitor`) and a `tunables` object with per-component
content-declared values (e.g. `health.maxHp`). `ContentRegistry` gains `actors` as a sixth
collection kind (`ID_FIELD_BY_KIND["actors"] = "id"`), validated against
`content/schemas/actors.schema.json` (required fields, numeric bounds on every declared
tunable, and a closed `enum` on `components` items naming the same eight component names —
kept for standard-JSON-Schema-tool conformance and tested against `ActorTable.COMPONENT_NAMES`
by `test_actor_table.gd` so the two vocabularies cannot drift apart; the registry's own
minimal validator does not implement `enum`, so an unknown component name is still caught, with
its operative `ERROR_DANGLING_REFERENCE`, by the cross-reference check below) and cross-checked
in `_check_references()`: an actor naming a component outside the closed vocabulary fails
construction with `ERROR_DANGLING_REFERENCE`, mirroring the existing `is_known_toil()` check for
`jobs.json`.

Once every component name is confirmed known, `ContentRegistry._init()` runs a second pass,
`_check_actor_component_tunables()`, that calls `ActorTable.validate_component(name, tunables)`
for every component every actor definition declares, failing construction with
`ERROR_SCHEMA_VIOLATION` on the first invalid one. This exists because the registry's
single-field JSON-Schema-subset validator can enforce a bound on one field (`health.maxHp >=
1`) but not a rule that spans two (`health.hp <= health.maxHp`, `worker.labour_min <=
labour_default <= labour_max`) or the absence of a component's entire tunables entry (an
omitted `tunables.health` key defaults to `{}`, which fails `ActorHealth.validate({})` because
`maxHp` is missing) — exactly the gap between "schema-shaped" and "actually usable" tunables
that letting `ActorTable.spawn()` apply silent per-field defaults would otherwise paper over.

`ActorTable` (`game/scripts/core/actors/actor_table.gd`) is a stateless, scene-independent
class of static methods: `spawn(def_id, x, y, registry, id)` builds a new actor Dictionary from
its content definition; `has_component(actor, name, registry)` and
`get_component(actor, name, registry)` take the registry explicitly rather than caching it, so
every call is a direct, current lookup against the actor's own `def_id` (its `kind` field) in
the content bundle; `validate_component(name, tunables)` dispatches to the named component's own
`validate(tunables)`, used only by `ContentRegistry` above. Each component
(`components/{mover,worker,needs,health,inventory,combat,wild,visitor}.gd`) is a small class
with a `validate(tunables)` method; only `needs` has `apply_tick()` for its per-tick behaviour
(need decay), not yet wired into `WorldState`'s own tick loop, which still drives need decay
itself. `mover`, like `combat`/`wild`/`visitor`, is data plus `validate()` only in this task:
real movement stays owned by `ToilExecutor`/`GlobalAssignment` against the actual route shape
(`job_id`/`path`/`step`/`move_ticks_remaining`), and `mover` must not add a second, incompatible
movement algorithm against an invented `{x, y}` target shape.

**Components are an accessor layer over existing fields, not a literal nested key.** This is
the scope-limiting decision the task set: `ActorTable.spawn("colonist", ...)` must produce
exactly the same `Array[Dictionary]` shape `WorldState._spawn_colonists()` has always produced
— `id, kind, x, y, needs, labourTable, route, work, carrying, held_tool` — because
`state_hash()` hashes `JSON.stringify(_colonists)`, which is sensitive to key presence and
insertion order (`world_state.gd`'s own `_ensure_needs()` doc comment). So `has_component(actor,
"worker", registry)` never checks for a nested `"worker"` key; it looks up whether `actor`'s
definition (by its `"kind"` field) declares a `worker` component at all, and
`get_component(actor, "worker", registry)` assembles `{"labourTable": actor["labourTable"],
"held_tool": actor["held_tool"]}` from the colonist's pre-existing fields. `"mover"` reads the
shared `"route"` field the same way. Every other component (`needs`, `health`, `inventory`,
`combat`, `wild`, `visitor`) reads its own like-named key — real for a freshly spawned wolf or
trader (which have no legacy shape to preserve), inert for a colonist today (whose dict carries
no `"health"`/`"inventory"` key yet; `get_component` simply returns `null` for those on a live
colonist until a later task gives them real per-instance state).

`world_state.gd`'s `_spawn_colonists()` now calls `ActorTable.spawn("colonist", x, y, _content,
id)` instead of building the Dictionary from local literals, reading the labour table and full
needs from `_content` (via `ActorWorker.default_labour_table()` / `ActorNeeds.build_full_needs()`)
rather than `_default_labour_table()`/`_full_needs()` (both still present, since
`test_save_migration.gd`/`test_labour_table.gd`/etc. call them directly on a `WorldState`
instance). `get_colonists()` is now a filter — every actor in `_colonists` with a `worker`
component — rather than an unconditional copy; since `_colonists` holds only colonists today
(see Non-goals), its output is unchanged.

## Consequences

- Adding a fourth actor kind, or a new tunable on an existing one, is a content change plus a
  schema/fixture update — no core code to hand-edit, matching F1's own payoff for jobs/needs.
- `test_actor_table.gd` proves `has_component()` matches each definition's declared components
  exactly (true for its own, false for every other known name) for colonist, wolf and trader
  spawned directly through `ActorTable.spawn()`; that a fixture with an unknown component, an
  out-of-bounds single-field tunable, a component missing its tunables entirely, `health.hp`
  above its own `maxHp`, or `worker.labour_default` outside `[labour_min, labour_max]` on either
  side each fails construction with the correctly typed error; and that the schema's
  `components` enum matches `ActorTable.COMPONENT_NAMES`.
- No live colonist gained a new field, and no save/wire shape changed: `state_hash()` and every
  existing headless test's fixture-construction code are unaffected by this task.
- A future task (t3) can give `health`/`inventory`/`combat` real per-instance state and behaviour
  by extending `_spawn_generic_actor()`'s branch and each component's `apply_tick()`, without
  touching the colonist accessor path this ADR fixes in place.

## Alternatives considered

- **Add `worker`/`health`/`inventory` as new nested keys on every colonist, migrating the save
  format now.** Rejected: out of scope for this task (task t4) and unnecessary — no consumer
  needs a live colonist's health or inventory yet, and forcing the migration early would touch
  `state_hash()`, `StateCodec`, and every save-round-trip test for no immediate payoff.
- **Give `ActorTable` instance state (construct it once with a `ContentRegistry`, drop the
  `registry` parameter from `has_component`/`get_component`).** Rejected: every other core class
  this registry-driven (`ToilExecutor`, the job givers) is either fully static or takes its
  dependencies as constructor parameters injected by `WorldState`; a bare stateless utility
  class is simplest to construct and test from a headless script with no setup, and keeps
  `ActorTable` scene-independent by construction rather than by discipline.
- **Enforce the closed component vocabulary only through `_check_references()`, with no `enum`
  in the schema at all.** Rejected on review: the schema is also the contract a standard,
  spec-conformant JSON Schema tool reads, and without an `enum` such a tool would accept any
  non-empty string as a component name. The `enum` is now declared for that reason, but stays
  inert in the registry's own minimal validator (`_validate_node` does not implement `enum`),
  so `_check_references()` remains the operative, typed (`ERROR_DANGLING_REFERENCE`) check;
  `test_actor_table.gd` asserts the schema's `enum` and `ActorTable.COMPONENT_NAMES` never
  drift apart.
- **Let a declared component's tunables fall back to per-field defaults at spawn time instead
  of failing construction.** Rejected: `ActorTable.spawn()`/`_spawn_generic_actor()` build each
  component from whatever tunables the definition provides via `Dictionary.get(key, default)`,
  which would silently substitute a default for a missing or invalid tunable (e.g. spawning a
  wolf whose `health.maxHp` was omitted with `maxHp = 1` from `ActorHealth.build()`'s own
  default) rather than surfacing the content author's mistake. `_check_actor_component_tunables()`
  fails construction instead, matching how a missing required field already fails the schema
  check rather than defaulting.

## Amendment (issue #283): health, needs, inventory and worker gain real per-instance behaviour

`health`, `needs`, `inventory` and `worker` stop being data-plus-`validate()`-only components
(the "not yet wired" state the Decision section above describes) and become the single place
their own per-instance logic runs, per this ADR's own component-ownership rule — callers no
longer duplicate a component's field CRUD inline.

- **Health initialization and bounds.** A colonist now spawns with a real `"health"` field —
  `{hp, maxHp, dead}` — the first genuinely new runtime key this ADR's accessor layer adds to a
  live colonist (every other component still reads a colonist's pre-existing field). A colonist
  always spawns at `hp == maxHp` regardless of any `tunables.health.hp` below it
  (`ActorHealth.build_full()`, used by `ActorTable._spawn_colonist()` and by
  `world_state.gd`'s `_ensure_health()` backfill); a generic actor (wolf, trader) still honors
  an optional `hp` tunable below `maxHp` via the pre-existing `ActorHealth.build()`.
  `ActorHealth.clamp_bounds()` keeps `hp` in `[0, maxHp]` and `maxHp` floored at 1 under any
  sequence of edits, and once `dead` becomes true (hp reaches 0) it stays true even if
  something later sets `hp` positive again — death is permanent. `ActorHealth.apply_tick()`
  re-clamps every tick; no code path deals damage yet (this task's own Non-goals), so a
  colonist's `hp` starts at `maxHp` and stays there today, but the invariant holds for whenever
  combat/hazard damage is added later without touching this component again.
- **Component ownership.** `ActorNeeds.apply_tick()` (need decay, called from `world_state.gd`'s
  `_decay_needs()`) is now actually wired into `WorldState`'s tick path, closing the "not yet
  wired" gap the original Decision section named. `ActorInventory` owns a colonist's carried-item
  field (`is_carrying()`/`carried_item()`/`set_carrying()`/`clear_carrying()`/
  `consume_one_carried()` over the legacy `"carrying"` field) and `ActorWorker` owns its
  labour-table and held-tool fields (`default_labour_table()`/`labour_level()`/
  `is_valid_labour_value()`/`set_labour_level()` over `"labourTable"`, `get_held_tool()`/
  `set_held_tool()`/`clear_held_tool()` over `"held_tool"`) — the field names and their
  accessor-layer-not-a-nested-key status are unchanged from the Decision section above.
  `ToilExecutor`, `ToolItemStore`, `GlobalAssignment` and `WorldState` call into these instead
  of indexing `"carrying"`/`"held_tool"`/`"labourTable"` inline; job transitions, routing and
  scheduling themselves stay in their existing owners (this ADR does not create a second
  job-state machine — `docs/architecture/extension-points.md`'s one-work-engine rule still
  applies).
- **Runtime hash vs. save format.** `state_hash()`'s internal snapshot dictionary now includes
  `health`, so a colonist's `hp`/`dead` divergence is caught by every existing relative hash
  comparison (two seeded runs, save/load round-trips). This is deliberately a runtime-only
  change: the save/wire format and `docs/architecture/contracts/game-state.schema.json` are
  untouched here — task t4 (#274's schema/migration follow-up) owns adding `health` to the
  persisted colonist shape. Until t4 lands, a restored save's colonist is missing `"health"`,
  which `_ensure_health()`'s backfill (mirroring `_ensure_held_tool()`'s existing pattern for
  a pre-task-#213 save) fills with `ActorHealth.build_full()`'s default rather than treating it
  as invalid.
