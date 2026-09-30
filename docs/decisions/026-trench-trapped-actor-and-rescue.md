# ADR 026: Trench, trapped-actor and rescue — content shape, find-roll and placement rules

> **In short:** Digging soil now leaves a trench and always produces sand, sometimes with a bonus
> find such as a coin or flint. Trenches can later trap creatures or colonists, who then need to
> climb out or be rescued. This record fixes the data shape and the rules that keep digging
> results repeatable.

- **Status:** accepted
- **Date:** 2026-09-23 (design agreed 2026-09-22; amended 2026-09-23 to add the persisted
  find-roll RNG)
- **Scope:** `game/content/tiles.json`, `game/content/items.json`, `game/content/jobs.json`'s
  `dig` entry, `game/content/schemas/jobs.schema.json`, `ContentRegistry`
  (`game/scripts/core/content/content_registry.gd`), `docs/architecture/core-budgets.json`'s cap
  for `game/scripts/core/world_state.gd`, and (amendment)
  `docs/architecture/contracts/game-state.schema.json`,
  `game/scripts/core/persistence/save_io.gd`, `game/scripts/core/persistence/state_codec.gd` and
  `game/scripts/core/persistence/save_migrations.gd`.
- **Depends on:** ADR 025 (mining).

## Context

The trench/trapped-actor/rescue feature is delivered in four steps: (1) content shape and
validation (this ADR), (2) dig completion effects, (3) trap-on-entry and climb-out
([ADR 027](027-trench-trap-escape-core-budget-increase.md)), and (4) the rescue job giver
([ADR 029](029-rescue-job-giver-core-budget-increase.md)). This ADR also fixes the rules the later
steps must follow.

## Decision

Digging soil no longer merely floors the tile. A completed `dig` job turns its target into a new
passable, non-diggable `trench` tile kind (`content/tiles.json`) with the same `move_cost`/
`move_ticks_per_tile` as `soil`/`floor`, so routing neither avoids it nor pays extra to enter it;
only `diggable: false` and its trap semantics distinguish it from floor. Dig always yields a `sand`
item and rolls a `find_table` for a second, rarer item (`gold_coin`, `flint`, `coal`, `seed`, or
nothing). `content/jobs.json`'s `dig` entry gains a `yields` field:
`{"always": ["sand"], "find_table": [{"item": "gold_coin", "weight": 5}, {"item": "flint",
"weight": 20}, {"item": "coal", "weight": 10}, {"item": "seed", "weight": 10}, {"item": null,
"weight": 55}]}` (weights sum to 100; `item: null` means no find). `sand`/`gold_coin`/`flint`/
`coal` are new `content/items.json` entries (`seed` already exists), each with a non-empty `kind`
(`material` for sand/flint/coal, `valuable` for gold_coin), following the existing `tool`/`seed`
convention. No code branches on the exact kind string, only on the declared id existing.

`jobs.schema.json` gains the optional `yields` shape: `always` is an array of item-id strings,
`find_table` an array of `{item, weight}` rows with `weight` an integer `>= 0`. `ContentRegistry`
validates two things the schema's minimal JSON-Schema subset cannot express:

- `_check_references()` cross-checks every `yields.always`/`yields.find_table` item id against
  `items.json`; a dangling id is `ERROR_DANGLING_REFERENCE`, like every other cross-file check. A
  `find_table` entry's `item` may be JSON `null`; it is checked with `typeof()` before any
  `String()` conversion, the same guard used for faction relation values, so a non-string,
  non-null value never reaches a `String()` constructor.
- A new `_check_job_yields()` rejects a `find_table` whose weights do not sum to 100, typed
  `ERROR_SCHEMA_VIOLATION`. It is a cross-field arithmetic rule, not a per-field shape check, so it
  does not belong in `_validate_node`.

`content_registry.gd` also gains `const TILE_TRENCH := "trench"` alongside `TILE_ROCK`,
`TILE_SOIL` and the other tile constants.

### Deterministic find roll

The find roll must be reproducible from the world seed alone, like every other simulation decision
(AGENTS.md "inject a seeded random source"). Dig completion owns a dedicated seeded
`RandomNumberGenerator`, salted off the world seed the way `IncidentScheduler._random` is
(`_random.seed = world_seed + SEED_SALT`) but with its own distinct salt constant, so it never
shares a `randi()` sequence with `WorldState._random` or any other module's stream. One roll is
consumed per completed dig job; when several dig jobs complete on the same tick, rolls are consumed
in ascending job-id order, so replaying the same seed and command stream always produces the same
finds regardless of iteration order elsewhere in `WorldState`.

### Item placement

`sand` and any find spawn on the ground next to the trench, not in it (a trench is meant to be
walked into and out of, not cluttered under the digger's feet). Each item goes to the nearest
adjacent passable, non-`trench` tile; ties are broken in ascending row-major order (lowest `y`,
then lowest `x`), so the outcome never depends on iteration order. Only if no adjacent tile
qualifies (every neighbour is impassable or a trench) does the item spawn on the trench tile.

### Amendment: persisted find-roll RNG and trench saves

The first implementation of dig completion added `trench` to the save schema's tile-kind enum but
missed two consequences of a saved world containing one:

- `SaveIO._validate_state()` has its own hand-written tile-kind allow-list, independent of the JSON
  schema, which still rejected `"trench"`. Every manual save and autosave failed after the colony's
  first dig. The list now includes `"trench"` alongside every other tile constant.
- The find-roll stream (`world._dig_find_random`, drawn by `_roll_dig_find()`) was not persisted.
  `StateCodec.decode()` builds a fresh `WorldState` whose constructor re-seeds the stream, so every
  save/load rewound the find sequence to its first roll: a real determinism regression, even though
  the sand yield and the trench itself round-tripped correctly.

The stream is now persisted the way `IncidentScheduler`'s RNG is (ADR 004): a new optional
top-level `digFindRng: {seed, state}` field (`StateCodec.encode()`/`decode()`), included in
`state_hash()` unconditionally (not gated by `include_incidents`), so a diverged find sequence
cannot hide behind an unchanged hash. Unlike the required `rng`/`incidentScheduler` fields it is
optional on the wire, so existing hand-built save fixtures for unrelated persistence behavior
(bounds validation, atomicity, seed fidelity) stay valid without a placeholder value; when it is
absent, `StateCodec.decode()` leaves the stream at the constructor's fresh
`seed + DIG_FIND_SEED_SALT` value, which is what those fixtures always relied on. `SaveIO` gains
the same exact-int64 recovery from the JSON text (`_restore_exact_dig_find_rng()`) that
`rng`/`incidentScheduler.rng` have, since `.state` is a 64-bit counter that can exceed `2^53`.
`SaveMigrations` bumps `SCHEMA_VERSION` 22 -> 23 and backfills `digFindRng` for older saves exactly
as `WorldState._init()` derives a fresh stream, mirroring `_migrate_v20_to_v21()`'s
`incidentScheduler.rng` backfill. No pre-v23 save recorded the live continuation, so a migrated
save restarts its find sequence from that fresh point on its next dig.

### `escape_trench` and `rescue` reuse the existing toil vocabulary

The shape of the later climb-out and rescue jobs is fixed now so `content/jobs.json` stays
additive, data-only content: `escape_trench` and `rescue` are ordinary job kinds reusing the
`reserve, go_to, work, release_all` toil sequence that `dig`/`chop`/`forage`/`till`/`sow` use. No
new toil and no `toil_executor.gd` change, per `docs/architecture/orders-and-movement.md`: "a job
kind is data, not a branch in `WorldState`." How an actor becomes trapped on entering a trench, and
what that prevents it from doing, is left to the trap-on-entry design (ADR 027); nothing here
commits `world_state.gd` to a trap representation.

### Deferred: filling a trench back in

Turning a `trench` back into `soil` by spending a carried `sand` item is out of scope for this
feature and left to a separate follow-up.

### `world_state.gd` core budget

`core-budgets.json`'s cap for `world_state.gd` rises 2092 -> 2222 (+130 lines) ahead of the code
that will use it. The file sits exactly at its cap, and the dig completion effects (trench
transform, seeded find roll, adjacent placement, job-id ordering) plus the trap, climb-out and
rescue effects will not fit. The size follows the comparable multi-part precedent of ADR 017's
incident wiring (+109 lines in one step); this feature touches `world_state.gd` in three steps, so
a similar-sized budget is reserved once rather than reopened after each step. A step that still
finds it insufficient raises the cap with its own ADR, as every prior increase (ADRs 015-017, 023,
025) did. `toil_executor.gd`'s cap is unchanged: `escape_trench`/`rescue` reuse its toils
unmodified.

## Consequences

- Until dig completion effects are implemented, a completed dig still only floors its target and
  spawns nothing; this ADR changes content and its validation, not `world_state.gd`'s
  `_toil_on_work_complete()` dig branch.
- `trench` has no viewer art or atlas cell yet. `test_tile_atlas_map.gd` is unaffected because it
  walks a fixed list of `WorldStateType.TILE_*` constants rather than `ContentRegistry.list("tiles")`.
  A later presentation change can add the cell the same way stone's was added.
- `mine`'s `stone` yield and toil sequence are untouched. `dig`'s `yields` field is additive
  content, read by `ContentRegistry`, its tests and the dig-completion branch.
- `yields` is job content, not persisted per-instance job state, so it needs no save-schema entry.
  A saved world can contain a `trench` tile and trench-sourced items: the save schema's tile-kind
  enum includes `"trench"` and `SaveIO._validate_state()`'s runtime check matches (see the
  amendment above).

## Alternatives considered

- **Compare tile-kind strings in `world_state.gd` instead of a named `TILE_TRENCH` constant.**
  Rejected: every other tile kind has a constant mirror in `content_registry.gd`; a bare string for
  the newest kind would be the one inconsistency and an easy source of typos.
- **Let the find roll reuse `WorldState._random`.** Rejected: `IncidentScheduler` already
  establishes a dedicated, separately salted `RandomNumberGenerator` per subsystem so one
  subsystem's roll count never perturbs another's sequence. Sharing `_random` would make the find
  sequence depend on unrelated draws.
