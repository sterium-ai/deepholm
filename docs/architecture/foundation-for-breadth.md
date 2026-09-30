# Foundation for breadth: what must be solid before structures, enemies and allies

> **In short:** Before adding many new buildings, enemies and allies, the game
> needs a few solid building blocks. This page lists those five foundations,
> in order, and records which are already done.

Design question (2026-09-18): what is a good next step so that the game has a solid, coherent
base on which to build more complexity — different kinds of structures, different kinds of
enemies, some allies? This page answers with an audit of what the game has today, the
architectural patterns that make breadth cheap in a data-driven simulation, and the five
foundations to lay **between the AI increments (B–E) and the first "breadth" content**.

Two labelling schemes are used throughout:

- **Increments A–E** are the colonist-AI milestones defined in
  [colonist-ai.md, section 5](colonist-ai.md#5-sequencing): A passability and re-routing,
  B toils and reservations, C labour table and calendar urgency, D needs, E tools.
- **Foundations F1–F5** are the five foundations this page proposes (section 3): F1 content
  registry, F2 actors and components, F3 factions and relations, F4 system split, F5 regions,
  rooms and incidents.

Nothing here changes the AI plan in [colonist-ai.md](colonist-ai.md); it says what to do with
the seams that plan leaves open so that content becomes data instead of code.

## 1. Where the game stands (audit, 2026-09-18)

Strong: deterministic tick core, seeded RNG, commands in / events out, typed reasons,
fair scheduler with proofs, bounded routes, one `passability()` rule, versioned saves with
migrations, headless tests as the review gate, and a content folder with JSON schemas.

Weak, and the reason to stop and lay foundations before breadth:

- **`world_state.gd` is becoming a god class.** 691 lines, 52 functions: map
  generation, tiles, objects, colonists, ground items, movement, work, command dispatch, hashing.
  Every increment adds to it. A single massive map class invites exactly the coupling
  failures described in [colonist-ai.md](colonist-ai.md) section 2.
- **Actors are only colonists.** `_colonists: Array[Dictionary]` with ad-hoc keys. An enemy or
  an animal has no place to exist; a "faction" is not a concept.
- **Tile and object *kind ids* are still named as constants in code** (`TILE_ROCK`…, mirroring
  `content/tiles.json`'s own ids); their *costs* are not — `move_ticks_per_tile` (tiles.json)
  and each job's `work_ticks`/haul `priority`/retry backoff (jobs.json) moved into content and
  load through `ContentRegistry` (F1, the content registry, below).
- **Content schemas exist but nothing validates content at startup**; `data/examples/*.json`
  are examples, not loaded definitions.
- **No damage, no health as a component, no combat model**; no structure integrity.
- **No room/region model**: a "structure" beyond a wall tile (a bedroom, a storeroom, a
  defended entrance) cannot be recognised by the simulation.
- **No incident/spawn model**: nothing can arrive on the map.

## 2. Patterns that make breadth cheap

- **Definitions as data.** Every kind of thing — tile, object, item, job, actor kind, faction,
  incident — is a definition loaded from content files and validated at startup. The engine is
  generic over definitions; adding a new enemy or building is a content entry, not new code.
- **Components.** An actor is a definition plus components that add behaviour (health,
  inventory, needs, worker, combat…). Actors of any faction share one job/decision system.
- **Factions and relations.** Hostility, trade and alliance come from a relation matrix between
  factions, not from per-actor special cases.
- **Incidents.** Arrivals (raiders, traders, migrants) are content entries fired by a scheduler
  with a budget.
- **Rooms and regions.** Enclosures are computed from the map and give stats that needs and
  other systems read.

A colony loop hosts enemies and allies cleanly only if **actors, factions, definitions and
incidents are first-class from the start**, not bolted on. The job engine's quality (no cancel
spam, typed explanations) is a separate concern, already covered by `colonist-ai.md`.

## 3. The five foundations (in order)

### F1 — Content registry: one loader, schema-validated, versioned — **Implemented**

`ContentRegistry` (`game/scripts/core/content/content_registry.gd`) loads every
`content/*.json` file that has a matching schema under `game/content/schemas/`
(tiles, objects, items, jobs, needs, calendar, manifest, mapgen today — a future kind
with its own schema is picked up automatically, not silently skipped) at session
start, validates each against its schema, cross-checks references, and freezes the
bundle; callers read it through `get_entry(kind, id)`, `list(kind)`, `document(kind)`,
and `version()`. Work costs and movement costs have moved from constants into
`content/tiles.json` (`move_ticks_per_tile` per tile) and `content/jobs.json`
(`work_ticks` per job kind, plus the haul entry's `priority`/`retry_base_ticks`/
`retry_cap_ticks`); `content/needs.json` carries the matching `full`/`job_priority`/
`retry_base_ticks`/`retry_cap_ticks` per need. Map-generation numbers — rock vein
count/length, spawn area position/size, and hazard/tree/water counts with their
placement-attempt caps — have moved the same way, from constants into
`content/mapgen.json`, read whole via `ContentRegistry.document("mapgen")` and used
directly by `WorldState`'s map carving methods. `WorldState` reads all of these from the
registry at construction and injects them into `ToilExecutor`/`NeedGiver`/
`HaulGiver`'s existing constructor parameters. Every save's
`contentVersion` is now sourced from `ContentRegistry.version()` rather than a
hard-coded literal (`content_version` in `docs/architecture/save-system.md`), and a
mismatch against the content bundle on disk is a typed `content_version_mismatch`
load error with a rename migration hook. `test_content_registry.gd` loads
the real bundle and asserts every cross-reference resolves, and fails a fixture
construction on any dangling reference (a job that names an unknown item), a schema
violation, or malformed JSON. Payoff: every later "add a kind of X" is a JSON entry
plus a test fixture, and the reviewer's checklist can say "content only, no code". See
[ADR 010](../decisions/010-content-registry.md) for the registry's design.

### F2 — Actors and components, not colonists — **Implemented**

`ActorTable` (`game/scripts/core/actors/actor_table.gd`) spawns actors from
`game/content/actors.json` and exposes `has_component()` / `get_component()`.
The component classes in `game/scripts/core/actors/components/*.gd` implement
`mover`, `worker`, `needs`, `health`, `inventory`, `combat`, `wild`, and `visitor`;
`ContentRegistry` validates definitions, component names and tunables.
Scheduler, executor and need-giver consumers use component accessors, and
`worker`, `inventory`, `needs` and `health` own labour/tool access, carrying,
need decay and health bounds respectively. Health and faction membership
are persisted with the schema-v18 migration (see
[save-system.md](save-system.md)).

Components are an accessor layer over the existing colonist dictionary:
`worker` exposes `labourTable` and `held_tool`, rather than adding a nested
`worker` key. `get_colonists()` filters actors by the worker component; job
scheduling, movement and execution retain their existing owners. The `wolf` and
`trader` definitions demonstrate component composition, but live spawning of
non-colonists and combat behaviour remain future work. Payoff: a new actor kind
can reuse component implementations through a content entry. See
[ADR 012](../decisions/012-actors-and-components.md) and the
[actor/component recipe](extension-points.md#actor-definition--component).

### F3 — Factions and relations — **Implemented**

`content/factions.json` declares `colony`, `wildlife`, `raiders`, `traders`, `allies`, each with
a relation row per other faction (`hostile | neutral | friendly`, not required to be symmetric)
and the rules `may_pass_doors`, `may_reserve_colony_items`, `may_be_ordered`; `ContentRegistry`
loads, schema-validates and cross-checks it as a seventh required collection kind, and
`game/scripts/core/relations/relations.gd` reads relations for any pair of factions or actors.
Every placed object, ground-berries cell, and item carries a `faction_id`, and every
colonist's existing `factionId` field participates in the same rules.
`WorldState.passability()` takes an optional `faction_id` and blocks a door to a faction whose
rules say it may not pass; `GlobalAssignment`'s reservation and order-eligibility gates
consult `may_reserve_colony_items` and `may_be_ordered` before a job may be proposed, activated,
or resumed, so a raider can neither reserve the colony's food nor be given a player order.
Live spawning of non-colony actors and the combat/incident work that would let a hostile
faction act on its own belong to F5 (regions, rooms and incidents, below). Payoff: adding a faction, or changing a
relation or rule, is a `content/factions.json` entry with no core code to hand-edit; an ally is
a faction with `friendly` relation and the worker component, and a tame animal is `colony`
faction with `tame`. See [ADR 014](../decisions/014-factions-and-relations.md) for the
collection's design and the [faction recipe](extension-points.md#faction) for how to extend it.

### F4 — Systems with a fixed tick order, extracted from `world_state.gd`

Split the god object into systems that each own one concern and run in a declared order every
tick (already the event ordering model: `system_priority`): `map`, `content`, `needs`,
`scheduling`, `jobs/toils`, `movement`, `combat`, `hazards`, `incidents`, `persistence`.
`WorldState` becomes the container that owns the actor table, the map, the reservation table
and the event log, and calls systems in order. Rule enforced by a lint test: no system reads
another's private state; they communicate through the shared tables and events. Payoff: a
new mechanic (fire, sieges, trade) is a new system file, and the tick order is documented and
tested, which a single-manager design never provides.

### F5 — Regions, rooms and incidents — **Implemented**

`game/scripts/core/map/regions.gd` recomputes connected walkable areas by flood fill whenever
passability changes (a wall placed/removed, a door added), giving reachability an O(1) region
lookup ahead of any route search. `game/scripts/core/map/rooms.gd` derives rooms from enclosed
regions bounded by walls/doors with at least one door, exposing size, door count, and whether the
room contains a bed or a stockpile; `WorldState.get_room_at()` reads this for any tile, and
`boot.gd`'s room label names a bedroom/storeroom/plain room the player last selected,
presentation-only. `content/incidents.json` declares `{id, faction, min_day, weight,
cooldown_days, spawn: {actor_def, count, edge, wait_ticks}}`; `game/scripts/core/incidents/
incident_scheduler.gd` runs a seeded, budgeted daily draw at each day boundary and also accepts
an on-demand `spawn_incident` command, proposing the declared actor(s) — of a faction (F3) built
from an actor definition (F2) — through the same job queue and shared toil dispatch every other
actor uses, and recording one `incident_started` event per firing. `wildlife_wander`
(hostile wolves) and `trader_visit` (a neutral trader) are the first two incident entries;
`tile_atlas_map.gd`'s `ACTOR_ATLAS_MAP` gives the renderer a lookup-table entry for each
spawned actor kind, and `boot.gd`'s standing alert list
surfaces each `incident_started` event alongside the existing need alerts. Combat itself —
an unordered hostile actor acting on its own — remains future work; F5's own scope is regions,
rooms, and getting actors of any faction onto the map and through the work engine. Payoff: the
first enemy and the first ally are two incident entries and two actor defs. See
[ADR 014](../decisions/014-factions-and-relations.md) and the
[incident recipe](extension-points.md#incident) for how to extend it.

## 4. Where this sits against the AI increments

| When | What |
| --- | --- |
| During B | Nothing changes. B's toils and ReservationTable are already component-agnostic. |
| Between B and D | **F1 content registry** (small, mostly moving constants to JSON + loader + validation test) — delivered. D's needs read `content/needs.json` through it. |
| Between D and C | **F2 actors/components** — implemented: actor definitions and component accessors now own the labour/tool and need/health fields. |
| After E | **F4 system split** — by then all systems exist; extracting them is mechanical and hash-checked (same tests, same hashes). Do it as one milestone, one system at a time. |
| Then | **F3 factions** — delivered. **F5 regions/rooms/incidents** — delivered: a wolf (wild, hostile) and a trader (neutral visitor) arrive as incidents, and a headless breadth test builds a bedroom through haul and work toils, verifies wall, door and bed recognition, and proves its rest-quality boost over an open bed. **First breadth content** — delivered: hostile wolf attack, neutral trader offer and acceptance, allied migrant recruitment, and the built-bedroom proof, backed by the combat and build-order foundations. |

Each foundation is one milestone with the same acceptance style as the AI increments:
headless tests, hash equality where behaviour must not change, contract migration, docs. The
lint tests (F1 dangling references, F4 system isolation) are what keep the base solid as
content is added later.

## 5. Explicitly deferred

Skills/traits per actor (a component later), mood/thoughts, z-levels, weather, fire/water
propagation, animal taming beyond the flag, diplomacy beyond the relation matrix, research
tree. All fit as new components, systems or content once F1–F5 exist; none should be started
before them.
