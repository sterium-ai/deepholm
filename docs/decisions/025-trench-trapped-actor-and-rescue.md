# ADR 025: Trench, trapped-actor and rescue — content shape, find-roll and placement rules

- **Status:** accepted
- **Date:** 2026-09-22 (owner design, per issue #357); this task 2026-09-23; amended 2026-09-23
  (issue #358 round 2 review) to add the persisted find-roll RNG contract below.
- **Scope:** `game/content/tiles.json`, `game/content/items.json`, `game/content/jobs.json`'s
  `dig` entry, `game/content/schemas/jobs.schema.json`, `ContentRegistry`
  (`game/scripts/core/content/content_registry.gd`), `docs/architecture/core-budgets.json`'s
  cap for `game/scripts/core/world_state.gd`, and (round 2 amendment)
  `docs/architecture/contracts/game-state.schema.json`,
  `game/scripts/core/persistence/save_io.gd`,
  `game/scripts/core/persistence/state_codec.gd`, and
  `game/scripts/core/persistence/save_migrations.gd`.
- **Implements:** issue #357 (t1 of the trench/trapped-actor/rescue objective, issue #348);
  blocked by and builds on issue #347 (mining).

## Decision

Digging soil no longer merely floors the tile: dig, trapped-actor and rescue is this
objective's design. A completed `dig` job turns its target tile into a new passable,
non-diggable `trench` tile kind (`content/tiles.json`), carrying the same `move_cost`/
`move_ticks_per_tile` as `soil`/`floor` so routing neither avoids it nor pays extra to enter it
— only its `diggable: false` and its (later) trap semantics distinguish it from floor. Dig
also always yields a `sand` item and rolls a `find_table` for a second, rarer item (`gold_coin`,
`flint`, `coal`, `seed`, or nothing): `content/jobs.json`'s `dig` entry gains a `yields` field,
`{"always": ["sand"], "find_table": [{"item": "gold_coin", "weight": 5}, {"item": "flint",
"weight": 20}, {"item": "coal", "weight": 10}, {"item": "seed", "weight": 10}, {"item": null,
"weight": 55}]}` (weights sum to 100; `item: null` is "no find"). `sand`/`gold_coin`/`flint`/
`coal` are new `content/items.json` entries (`seed` already exists), each a non-empty `kind`
(`material` for sand/flint/coal, `valuable` for gold_coin) following the existing `tool`/`seed`
convention — nothing in this task or its successors branches on the exact string, only on
declared-id existence.

`jobs.schema.json` gains the `yields` shape (optional per job entry: `always` an array of item
id strings, `find_table` an array of `{item, weight}` rows, `weight` an integer `>= 0` per the
schema's own "integer"/"minimum" support). `ContentRegistry` validates two things the schema's
minimal JSON-Schema subset cannot express on its own: `_check_references()` now cross-checks
every `yields.always`/`yields.find_table` item id against `items.json` (a dangling id is
`ERROR_DANGLING_REFERENCE`, matching every other cross-file check this registry already
performs; a `find_table` entry's `item` may be JSON `null`, meaning "no find", checked by
`typeof()` before any `String()` conversion — the same guard `_check_references()` already uses
for faction relation values, since a non-string, non-null JSON value must never reach a
GDScript `String()` constructor); and a new `_check_job_yields()` sums each job's
`find_table` weights and rejects a sum other than 100, typed `ERROR_SCHEMA_VIOLATION` (a
cross-field arithmetic rule, not a per-field shape check, so it does not belong in
`_validate_node`). `content_registry.gd` also gains `const TILE_TRENCH := "trench"` alongside
its existing `TILE_ROCK`/`TILE_SOIL`/... constants.

### Deterministic find-roll rule (for t2)

The find roll must be reproducible from the world seed alone, like every other simulation
decision (AGENTS.md "inject a seeded random source"). t2 (dig's runtime completion effects,
out of this task's scope) owns a dedicated seeded `RandomNumberGenerator`, salted off the world
seed the same way `IncidentScheduler._random` already is
(`game/scripts/core/incidents/incident_scheduler.gd:99-100`: `_random.seed = world_seed +
SEED_SALT`, its own distinct salt constant so it never shares a single `randi()` call sequence
with `WorldState`'s own `_random` or any other module's salted stream) — this objective's find
roll gets its own salt constant, distinct from `IncidentScheduler`'s. The roll is consumed
exactly once per completed dig job, and when more than one dig job completes on the same tick,
the rolls are consumed in ascending job-id order, so replaying the same seed against the same
command stream always produces the same find sequence regardless of dictionary/array iteration
order elsewhere in `WorldState`.

### Item placement rule (for t2)

`sand` and any rolled find item spawn on the ground, never inside the trench tile itself (a
trench is meant to be walked into and out of, not instantly cluttered under the digger's feet).
t2 places each spawned item on the nearest adjacent passable, non-`trench` tile to the dug
tile; when more than one adjacent tile qualifies at the same (nearest) distance, the tie is
broken deterministically in ascending row-major order (lowest `y`, then lowest `x`) so the
outcome never depends on dictionary/array iteration order. Only if no adjacent tile qualifies
(every neighbour is impassable or itself a trench) does the item fall back to spawning on the
trench tile itself.

### Amendment (round 2 review): persisted find-roll RNG, and the `trench` runtime save gap

t2's first slice added `trench` to the save schema's tile-kind enum but missed two runtime
consequences of a saved world actually being able to contain one, both fixed in this task's
round 2: `SaveIO._validate_state()` carries its own separate, hand-written tile-kind allow-list
(`game/scripts/core/persistence/save_io.gd`, independent of the JSON schema file) that still
rejected `"trench"`, so `SaveIO.write_atomic()` failed every manual save and autosave the moment
a colony completed its first dig. That list now includes `"trench"` alongside every other
`content_registry.gd` tile constant.

Second, `world._dig_find_random` (the seeded stream `_roll_dig_find()` draws against) was
deliberately left unpersisted in the first slice, following `_object_factions`'s "a later task
persists this" precedent — but unlike faction ownership, an unpersisted find-roll stream is a
real determinism regression: `StateCodec.decode()` builds a fresh `WorldState` whose
constructor re-seeds `_dig_find_random` from scratch, so every save/load round trip silently
rewound the find sequence to its very first roll instead of continuing where the live run left
off, even though the guaranteed sand yield and the trench tile itself round-tripped correctly.
This is now fixed the same way `IncidentScheduler`'s own RNG stream already is (ADR 004): a new,
**optional** top-level `digFindRng: {seed, state}` field (`StateCodec.encode()`/`decode()`),
included in `state_hash()` unconditionally (not gated by `state_hash(include_incidents)`, since
dig has nothing to do with incidents) so a diverged find sequence can never hide behind an
unchanged hash. It is deliberately optional, not required, on the wire — unlike `rng`/
`incidentScheduler`, which are both required — precisely so pre-existing hand-built save
fixtures exercising unrelated persistence behavior (bounds validation, atomicity, seed fidelity)
that predate this field are not forced into this task's Owned paths just to add a placeholder
value neither they nor their own review scope ever cared about; `StateCodec.decode()` simply
leaves `_dig_find_random` at the constructor's own fresh `seed + DIG_FIND_SEED_SALT` value when
the field is absent, which is exactly what every pre-existing fixture already implicitly relied
on before this field existed. `SaveIO` also gained the same structural-JSON-text exact-int64
recovery (`_restore_exact_dig_find_rng()`) that `rng`/`incidentScheduler.rng` already have,
since `.state` is an engine-internal 64-bit counter just as capable of exceeding `2^53` as either
of those. `SaveMigrations` bumps `SCHEMA_VERSION` 22 -> 23 and backfills `digFindRng` for any
older save the exact same deterministic way `WorldState._init()` itself derives a fresh stream
(`seed + DIG_FIND_SEED_SALT`) — mirroring `_migrate_v20_to_v21()`'s identical
`incidentScheduler.rng` backfill — since no pre-v23 save ever recorded a live run's true
continuation to recover; a save that already completed digs simply restarts its find sequence
from that fresh point on its next dig, the same one-time cost the incident scheduler's own
v20->v21 backfill already paid.

### `escape_trench`/`rescue` reuse the existing toil vocabulary (for t3/t4)

Trap-on-entry, climb-out (`escape_trench`) and `rescue` are later tasks' scope (t3/t4), but
their shape is fixed now so `content/jobs.json` stays additive, data-only content the same way
every other job kind already is: `escape_trench` and `rescue` are ordinary
`content/jobs.json` kinds reusing the exact `reserve, go_to, work, release_all` toil sequence
`dig`/`chop`/`forage`/`till`/`sow` already use, unchanged — no new toil, no `toil_executor.gd`
change, per `docs/architecture/orders-and-movement.md`'s "content/jobs.json" section: "a job
kind is data, not a branch in `WorldState`." Trap-on-entry itself (an actor's own state
becoming "trapped" on stepping onto a `trench` tile with a live trap, and what gates it from
acting) is t3's design, not this ADR's; nothing here commits `world_state.gd` to a specific trap
representation, since that decision needs t3's own concrete data flow in hand.

### Deferred: filling a trench back in

This objective does not fill a trench back in. A later, separate objective owns "consumes sand,
restores soil" — turning a `trench` tile back into `soil` by spending a carried `sand` item is
out of scope for trench/trapped-actor/rescue (t1-t4) entirely, left for a follow-up track to
design and implement.

### `world_state.gd` core budget

`core-budgets.json`'s cap for `game/scripts/core/world_state.gd` rises 2092 -> 2222 (+130
lines) in this task, ahead of the code that will use it: t2's dig completion effects (trench
tile transform, seeded find roll, adjacent-tile item placement, job-id ordering for same-tick
completions) and t3/t4's trap/climb-out/rescue completion effects and bookkeeping will not fit
in the file's current headroom (0 lines free — the file sits exactly at its prior cap, 2092,
today). +130 is sized against `world_state.gd`'s own comparable multi-piece precedent, ADR 018's
incident wiring (+109 lines for a day-gated draw, staging, activation and a shared finish-
boundary hook spread across one task): this objective spans three follow-on tasks touching
`world_state.gd` (dig completion, trap/climb-out, rescue) rather than one, so a similar-order
budget is reserved now rather than re-opening this ADR for a small raise after each task. Any
task that still finds this insufficient raises the cap again with its own ADR, per the
`core-budgets.json` convention every prior increase (016/017/018/022/024) already follows.
`toil_executor.gd`'s own cap is unchanged: nothing in this design touches that file, since
`escape_trench`/`rescue` reuse its existing toil vocabulary unmodified.

## Consequences

- A dig completed today (before t2 lands) still only floors its target tile and spawns nothing
  — this task changes content and the registry's validation of it, not `world_state.gd`'s
  `_toil_on_work_complete()` dig branch, which is explicitly t2's scope (Non-goals).
- `trench` has no viewer art or atlas cell yet (`game/scripts/viewer/tile_atlas_map.gd` is out
  of this task's Owned paths and Non-goals); `test_tile_atlas_map.gd` is unaffected because it
  walks a fixed, hand-written list of `WorldStateType.TILE_*` constants rather than
  `ContentRegistry.list("tiles")`, so it does not require every declared tile kind to have a
  mapped cell. A later presentation task adds `trench`'s cell the same way stone's was added
  (#376).
- `mine`'s own `stone` yield and toil sequence (issue #347) are untouched; `dig`'s new `yields`
  field is additive content only `ContentRegistry`, this task's tests, and (starting with t2)
  `world_state.gd`'s dig-completion branch read.
- `yields` itself is job content, not persisted per-instance job state, so it needs no schema
  entry of its own. A saved world CAN now contain a `trench` tile and trench-sourced items
  (t2's own scope): `docs/architecture/contracts/game-state.schema.json`'s map tile-kind enum
  gains `"trench"`, and `SaveIO._validate_state()`'s own runtime tile-kind check is updated to
  match — see the round 2 amendment below for why the initial t2 slice still needed a follow-up
  here.

## Alternatives considered

- **Branch on tile kind string equality in `world_state.gd` instead of a named `TILE_TRENCH`
  constant.** Rejected: every other tile kind already has a compile-time constant mirror
  (`content_registry.gd`'s own doc comment on `TILE_ROCK`/`TILE_SOIL`/...); a bare string
  literal for the newest kind would be the one inconsistency and an easy typo source across
  t2-t4.
- **Let the find roll reuse `WorldState`'s own `_random`.** Rejected: `IncidentScheduler`
  already establishes the pattern of a dedicated, separately-salted `RandomNumberGenerator` per
  subsystem specifically so one subsystem's roll count never perturbs another's `randi()`
  sequence; sharing `_random` would make the find-roll sequence depend on how many other
  `_random` draws happen to occur first, breaking reproducibility across unrelated changes.
