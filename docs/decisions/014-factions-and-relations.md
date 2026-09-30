# ADR 014: Factions and relations — a new content collection and a read-only accessor

> **In short:** Every creature belongs to a group (the colony, wildlife, raiders, traders or allies), a data file says how each group treats the others, and those rules decide who may open doors, take colony items or receive player orders.

- **Status:** accepted
- **Date:** 2026-09-20
- **Scope:** content (`game/content/factions.json`,
  `game/content/schemas/factions.schema.json`), content loading
  (`game/scripts/core/content/content_registry.gd`), a new core module
  (`game/scripts/core/relations/relations.gd`)
- **Implements:** F3 in [`foundation-for-breadth.md`](../architecture/foundation-for-breadth.md).

## Decision

`content/factions.json` declares exactly five factions — `colony`, `wildlife`, `raiders`,
`traders`, `allies` — each `{id, relations, rules}`. `relations` is a Dictionary keyed by every
*other* declared faction id, valued `"hostile" | "neutral" | "friendly"`; it is **not required to
be symmetric** (`colony`'s relation to `wildlife` is declared `"neutral"`, but `wildlife`'s
relation to `colony` is declared `"hostile"` — wolves attack colonists on sight, but colonists do
not treat wildlife as hostile by default; this asymmetric pair is exactly what
`test_factions.gd` asserts on). `rules` is three flat booleans: `may_pass_doors`,
`may_reserve_colony_items`, `may_be_ordered`. Only `colony`'s `may_be_ordered` is `true` — no
other faction's actors take player orders.

`ContentRegistry` gains `factions` as a seventh collection kind (`ID_FIELD_BY_KIND["factions"] =
"id"`), loaded, schema-validated and frozen exactly like jobs/needs/objects/items/tiles/actors
(ADR 010's pattern) — it is now a *required* kind, so every fixture bundle anywhere in the test
suite that constructs a `ContentRegistry` against a custom `content_dir` needs its own
`factions.json` (see Consequences).

`_check_references()` gains three faction checks, all typed `ERROR_DANGLING_REFERENCE` on
failure (mirroring how `jobs.needs_tool` naming an item of the wrong kind is *also*
`dangling_reference`, not a separate type, despite not being a bare "unknown id" case):

1. Every faction's `relations` must have exactly one row per *other* declared faction id (no
   missing row, no self-row, no row naming an undeclared faction).
2. Every relation value must first be a JSON string, then one of
   `"hostile"/"neutral"/"friendly"` (`Relations.is_known_relation_value()`, preloaded into the
   registry the same way `ActorTable.is_known_component()` and `ToilExecutor.is_known_toil()`
   already are). The type check runs *before* the value is ever passed to GDScript's `String()`
   constructor: `factions.schema.json`'s `additionalProperties` schema is not enforced by the
   registry's minimal validator (see below), so a malformed relation value (a JSON number,
   boolean, `null`, array, or object) reaches `_check_references()` untyped, and `String()` — as
   opposed to `str()` or a `"%s"` format — throws `Invalid call. Nonexistent 'String' constructor`
   for those types instead of converting them (verified directly against this engine version, not
   assumed). Checking `typeof(value) == TYPE_STRING` first turns that would-be crash into the
   ordinary typed `dangling_reference` error every other malformed reference in this function
   already produces.
3. An actor definition's **optional** `faction_id` field, when present, must name a declared
   faction id. It is optional, and no real `content/actors.json` entry declares it today — see
   Non-goals below.

A latent bug in the registry's minimal JSON-Schema-subset validator (`_validate_node`) is fixed
in the same change: `additionalProperties` was compared directly against the boolean `false`,
which throws a runtime "Invalid operands 'Dictionary' and 'bool'" error the moment a schema gives
it an object value instead of a boolean — exactly what `factions.schema.json`'s dynamic-keyed
`relations` needs for standard-JSON-Schema-tool conformance (`"additionalProperties": {"type":
"string", "enum": [...]}`). The fix makes a non-boolean `additionalProperties` inert (accepted,
unenforced) rather than crashing, the same stance the validator already takes toward `enum`
(ADR 012's own precedent).

`game/scripts/core/relations/relations.gd` is a new, plain, scene-independent core module
(`class_name Relations extends RefCounted`), constructed from a frozen `ContentRegistry`
(`Relations.new(registry)`, `registry` taken untyped/duck-typed rather than `: ContentRegistry`
so `content_registry.gd`'s own preload of this file for `RELATION_VALUES`/
`is_known_relation_value()` — reused for check 2 above — does not create a preload cycle). It
exposes exactly two functions:

- `relation(a_faction_id, b_faction_id) -> String`: faction `a`'s own row for `b` — not
  symmetric. A faction relating to itself is always `"friendly"`.
- `is_hostile(actor_a, actor_b) -> bool`: reads each actor Dictionary's own `"faction_id"` field
  and calls `relation()`.

As first introduced, neither function was called by production code (see Non-goals). They are
the documented seam for three consultation points, wired up by the amendments below:

- **Passability** (`content/objects.json`'s door objects): a door's `passable` check gains a
  `rules.may_pass_doors` consultation for the moving actor's faction, so a colony door is
  passable to `colony`/`allies` and blocked to `hostile` factions.
- **Reservations** (the `ReservationTable`/haul job-givers): a reservation attempt against a
  colony-owned item gains a `rules.may_reserve_colony_items` consultation, so a raider cannot
  reserve the colony's food.
- **Order/job-giver validation** (order input, `GlobalAssignment`): an order or auto-assigned job
  targeting an actor gains a `rules.may_be_ordered` consultation, so only `colony` actors can be
  given player orders (a tame animal, per F3's own payoff example, would be `colony` faction
  gaining that eligibility for free).

## Non-goals

- Does not add `faction_id` to any placed object, item, debug command, or `content/actors.json`
  entry. `game/content/actors.json` and `game/content/schemas/actors.schema.json` are
  untouched — no real actor definition needs a `faction_id` yet since nothing consults one. The
  dangling-reference check above is written to activate the moment the field is added, without
  a second registry change.
- Does not touch `passability()`, reservations, or order/job-giver validation. Those are the
  three consultation points named above, deferred to the amendments below.
- Does not confuse content's `faction_id` (snake_case, a definition-level default a future actor
  kind could declare) with the pre-existing, unrelated runtime/save field `factionId` (camelCase,
  present on every live colonist Dictionary and in `game-state.schema.json`, at the time always
  `"colony"` since only one faction had ever been assignable). The two are deliberately named
  differently; this decision does not touch the runtime field, its migration, or its schema.

## Consequences

- `test_content_registry.gd` and `test_actor_table.gd` both construct `ContentRegistry` against
  custom fixture directories; since `factions` is now required, both files' shared fixture
  writers (`_write_required_tiles_and_mapgen()`, `_write_minimal_bundle()`) gained a minimal
  two-faction `factions.json` so their existing, unrelated assertions keep exercising the error
  they were written to prove rather than an incidental `missing_file` for `factions`. Without
  it, nine previously-passing sub-tests in `test_actor_table.gd` would fail on a different error
  than the one each asserts on; the change is fixture data only, with no assertion or production
  logic touched.
- `test_factions.gd` proves: the real bundle declares exactly the five faction ids with only
  `colony`'s `may_be_ordered` true; `Relations.relation()` reads the asymmetric
  `colony`/`wildlife` pair correctly in both directions and returns `"friendly"` for a
  self-relation; a fixture actor naming an undeclared `faction_id` fails construction with
  `ERROR_DANGLING_REFERENCE` naming `actors.json`; and, for each of five malformed relation
  values (number, boolean, `null`, array, object), construction fails with
  `ERROR_DANGLING_REFERENCE` naming `factions.json` and exposes no partial `factions` collection,
  rather than crashing.
- Adding a sixth faction, or changing a relation/rule, is a content-only change — no core code to
  hand-edit, matching every other `ContentRegistry` collection kind's payoff.
- `combat`/`wild`/`visitor` actor components and every job-giver are unaffected by the original
  decision: nothing reads `Relations` yet, and `state_hash()`/the save format are untouched.

## Amendment 1: faction ids on placed objects and items

`game/scripts/core/world_state.gd`'s `docs/architecture/core-budgets.json` cap rose from 1627
to 1689: `place_object`/chop/forage now default a `faction_id` on every placed object and
first-class item (`_object_factions`/`_ground_berries_factions`/`_item_factions`, parallel maps
rather than a nested value inside `_objects`/`_ground_berries`/`_items`, since `state_codec.gd`'s
`_encode_objects()`/`_encode_items()` each assume a fixed existing value shape for those three),
and a new `set_faction` debug command mutates an actor's existing `factionId` field via this
ADR's `factions` registry lookup.

## Amendment 2: faction-aware door passability

`game/scripts/core/world_state.gd`'s `docs/architecture/core-budgets.json` cap rose from 1689
to 1707: `passability(x, y, faction_id: String = "colony")` gained the parameter, plus a
`_faction_may_pass_doors()` helper consulting this ADR's `factions` registry for a door object,
per F3's "Passability" consultation point named above. Every pre-existing single-argument call
site is unchanged.

## Amendment 3: player-order eligibility and reservation gates

`game/scripts/core/world_state.gd`'s `docs/architecture/core-budgets.json` cap rose from 1707
to 1774, then to 1802; `game/scripts/core/scheduling/global_assignment.gd`'s
cap rose from 511 to 586. An optional `assignee` on `dig`/`chop`/`forage` commands (carried
through `GlobalAssignment.submit()`'s existing `restrict_to`) is rejected `not_ordered_by_player`
when the named actor's faction's `may_be_ordered` is not true (`WorldState._apply_job_command()`).

Two independent gates live in `GlobalAssignment` itself, both consulted *before* the reserve step
they guard, never after, so a refused actor's reservation is never even transiently held:

- `set_order_eligibility()` (`_may_be_ordered`): consulted for every worker before it may be
  proposed for *any* job, `tick()`'s per-worker proposal scan — the one gate that reaches `haul`,
  which has no actor pool of its own to filter (unlike `need_giver.gd`, which additionally filters
  the colonist pool it scans by the same rule, so an ineligible actor's need is never even
  evaluated).
- `set_reservation_gate()` (`_may_reserve`): consulted immediately before `tick()`'s
  `advance_selection()` would acquire a chosen job's `tile:`/`item:`/`cell:` key, and again before
  `resume_assignment()`'s `reactivate()` would re-acquire one after a critical-need interrupt —
  covering both a job's first activation and its resumption, so a faction change made while the
  job was suspended cannot let it reacquire on resume. A refused job is never added to
  `advance_selection()`'s selection, so `JobQueue.tick()` never processes it; `GlobalAssignment`
  records the job id via `take_refused_reservations()` for `WorldState._resolve_refused_reservations()`
  (called right after `_scheduler.tick()`, before any colonist reads the new assignment) to
  terminally resolve with the same typed-rejection path `zone_remove`'s `blocked_destination_gone`
  already uses (`JobQueue.set_pending_fail_reason()` + the job's own `fail()`), plus
  `need_giver.gd` bookkeeping for a need job — `GlobalAssignment` itself has no visibility into
  `NeedGiver`.

`WorldState._resubmit_unreachable_job()` (an unreachable first-leg target's cancel-and-resubmit)
now preserves a player-ordered job's `assignee` restriction across the resubmission, read via the
new `GlobalAssignment.restrict_to_for()` before the original job's activated-entry snapshot is
erased — without it, the restriction was silently dropped the instant a target briefly became
unreachable, since `need_giver.gd`'s own `colonist_for_job()` (the only prior source) is empty for
a plain player order.

## Amendment 4: refusal-handling fixes

`game/scripts/core/world_state.gd`'s `docs/architecture/core-budgets.json` cap rose from 1802
to 1819 (`global_assignment.gd`'s own 586 cap is unchanged) to fix three defects:

- A refused *resumption* of a suspended `haul` job could strand its colonist's carried item
  forever: `_resolve_refused_reservations()` now looks the colonist up by the `worker` id
  `GlobalAssignment.take_refused_reservations()` returns alongside each refused `job_id` (its
  `_assignments` entry is already gone by then) and drops the carried item the same way an
  ordinary haul termination does.
- `_resolve_refused_reservations()` is now also called at the end of `_apply_job_command()` and
  after `_advance_colonists()` (not before) in `tick()`, so a refusal `_need_giver.resolve_job()`
  triggers recursively — from a command outside `tick()` entirely, or from need completion inside
  `_advance_colonists()` — is always resolved before the enclosing mutator returns, never left in
  `GlobalAssignment`'s transient, unsaved `_refused_reservations` across a save/load boundary.
- `_worker_may_be_ordered()` is now revalidated at the same point `_worker_may_reserve()` already
  was (`tick()`'s "ready" selection loop and `resume_assignment()`), not only at an unrestricted
  entry's early scan filter: a `restrict_to`'d order, a committed need, or a resumed suspension
  could previously reach activation on a since-revoked `may_be_ordered` as long as
  `may_reserve_colony_items` still passed, since the two rules are independent.

## Amendment 5: forced drop of a stranded carried item

`game/scripts/core/world_state.gd`'s `docs/architecture/core-budgets.json` cap rose from 1819
to 1842: `_drop_carried_item_from()` now checks `ToilExecutor.place()`'s result and falls back to
a new `_force_drop_carried_item()` (an unconditional `_place_ground_item()` write, bypassing
`place()`'s occupancy/passability re-validation, mirroring `tool_drop_toil.gd`'s own
`_drop_tool_ground` terminal fallback) when the colonist's own tile is occupied or impassable at
the exact tick a refusal terminates its haul, so the carried item is never stranded in
`carrying` instead of returned to the ground.

## Amendment 6: autonomous activation for incident actors

F5 "Incidents" needs a non-colony actor (a spawned wolf/trader) to run its own walk-then-wait job
through the shared job/toil engine, submitted by `IncidentScheduler`/`WorldState` itself, never by
a player order. `_may_be_ordered` exists specifically to stop a *player order*
(`WorldState._apply_job_command()`'s assignee check) from naming a non-colony assignee; it was
never meant to veto that same actor's own autonomous submission of its own job, but it also
blocked `GlobalAssignment.tick()`'s ordinary per-worker proposal scan from ever selecting a
non-colony actor for *any* job. An earlier implementation worked around this by force-activating
outside `tick()`, which broke the reservation gate and the queue clock.

`global_assignment.gd` gains a narrow, additive activation path instead:

- `submit()` gains an `autonomous: bool = false` parameter. When true, `"autonomous": true` is
  stored on the waiting entry (and on the wire, `queueEntry.autonomous`); when false the key is
  absent, so every ordinary entry, snapshot and save keeps its exact pre-incident shape (the
  incidents-disabled hash baseline is unchanged). `submit_autonomous(target, priority,
  tick_number, kind, worker)` is a thin wrapper that also sets `restrict_to = worker`, so an
  autonomous entry can only ever activate for the one worker that submitted it.
- The "ready" selection loop's authoritative gate (the one point every proposal reaches right
  before `advance_selection()` ever acquires a reservation, where both gates are revalidated per
  Amendment 4) skips only `_worker_may_be_ordered()` for an entry
  flagged `autonomous`. The reservation gate is never skipped; it is consulted in a target-aware
  form instead. `set_autonomous_reservation_gate(Callable(worker_id, target) -> bool)` wires the
  gate an autonomous entry is checked against (falling back to `_may_reserve` itself when unset,
  i.e. gated exactly like any other entry). `WorldState` binds it to
  `_actor_may_reserve_target()`: a faction whose `rules.may_reserve_colony_items` is true may
  reserve any target; one whose rule is false (wildlife, traders) may reserve a target tile only
  when it is **bare** — no placed object, no ground item, no ground berries, no tool item, and
  not inside a stockpile zone (`WorldState._is_bare_tile()`, the same predicate
  `IncidentScheduler` applies when it picks a spawn tile and a target, so a proposed target is
  one the gate accepts). This keeps `_may_reserve`'s actual rule — a non-colony actor never
  reserves a colony-owned item/object/cell — while defining what that rule means for an
  actor's own bare-tile walk/wait target, which is not a colony item. Nothing else in the gate
  check changes: the reservation table's own target-conflict check (`JobQueue.tick()`'s
  `_table.owner()`/`.acquire()`, run via the ordinary `queue.advance_selection()` call
  immediately after) is not bypassed, so an autonomous job still refuses a target another job
  already owns — including a race between two autonomous jobs, or an autonomous job and a
  colonist's job, for the same target — and stays queued `blocked_target_reserved` exactly like
  an ordinary job. A refusal by the gate follows the existing
  `take_refused_reservations()`/`_resolve_refused_reservations()` path.
- `set_autonomous_passability(Callable(worker_id, tile) -> cost)` wires the cost callable an
  autonomous entry's own route search (the initial bounded search, and the path-trim step) runs
  under, in place of `tick()`'s colony-bound `passable`; `WorldState` binds it to the actor's own
  faction (`_passable_for_worker()`), so a wildlife actor's initial route never crosses a colony
  door. Ordinary entries are unaffected.
- `WorldState`'s own `_colonist_may_be_ordered()`/`_colonist_may_reserve_colony_items()` gates
  resolve a staged (proposed, not yet spawned) incident actor's faction as well as a roster
  actor's, so the ordinary scan never proposes such an actor for a colony job.
- No other change: an autonomous job still goes through the exact same
  `tick()`/`advance_selection()` clock-driven activation and reservation acquisition as every
  other job. `WorldState` never calls `advance_selection()`/`set_assignment()` for an incident
  job — activation happens only inside `WorldState`'s own single regular `_scheduler.tick()` pass
  per tick, so submitting several autonomous jobs inside one `WorldState` tick (a multi-actor
  incident, or a debug command) cannot tick `JobQueue`'s or `GlobalAssignment`'s clock more than
  once. A proposed actor is *staged* until that activation: it is offered to `tick()` as a worker
  but enters the world only once its job is active (see ADR 017 and
  `docs/architecture/orders-and-movement.md`, "Incident jobs").

`docs/architecture/core-budgets.json`'s cap for `game/scripts/core/scheduling/global_assignment.gd`
rises accordingly (ADR 017 records the exact number); `job_queue.gd` is untouched.

## Alternatives considered

- **Require every faction's relation matrix to be symmetric, storing only the upper triangle.**
  Rejected: F3's own text explicitly calls for asymmetric relations (a predator
  is hostile to prey without the reverse necessarily holding); storing a full, explicit row per
  faction keeps `relation()` a simple lookup with no "which half is canonical" ambiguity.
- **Give `Relations` a fallback of `"hostile"` (fail closed) instead of `"neutral"` for a faction
  id the content bundle does not declare.** Rejected: this path is unreachable for a valid
  registry's own declared factions (completeness is enforced at construction), and defensive
  fail-closed behavior for an impossible case would silently mask a real bug (a caller passing a
  bogus id) as ordinary game behavior instead of surfacing it.
- **Enforce the `faction_id`-on-actors check by requiring the field on every actor definition
  now.** Rejected: no consumer reads an actor definition's faction membership yet, so changing
  `content/actors.json`/`content/schemas/actors.schema.json` is unnecessary; making the field
  optional keeps the real bundle valid today while the check is already correct and tested (via a
  fixture with its own schema copy) for when the field is added for real.
