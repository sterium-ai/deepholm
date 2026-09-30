# ADR 024: Needs decay in points per day; day length 2200 ticks

> **In short:** A game day is now about 18 real minutes long at normal speed, and hunger, thirst
> and tiredness are measured per day instead of per tick, so colonists no longer starve within a
> minute.

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** content (`game/content/needs.json`, `game/content/calendar.json`,
  `game/content/schemas/needs.schema.json`), simulation
  (`game/scripts/core/actors/components/needs.gd`,
  `game/scripts/core/actors/actor_table.gd`, `game/scripts/core/world_state.gd`),
  persistence (`game/scripts/core/persistence/state_codec.gd`,
  `save_migrations.gd`, `save_io.gd`, `docs/architecture/contracts/game-state.schema.json`,
  schemaVersion 22).

## Context

Before this change (design decision of 2026-09-22), `content/needs.json` decayed food/water/rest 1/2/1
points per tick from a 100-point full value, and `content/calendar.json` set
`day_length_ticks` to 100. At the default x1 speed (2 ticks/s) a colonist
starved in 50 real seconds and a game day lasted 50 s — far too fast for any
real play session.

## Decision

1. **`day_length_ticks: 2200`.** At x1 (2 ticks/s) a day now takes ~1100 real
   seconds (~18.3 minutes), matching the playtest target.
2. **`needs.json` replaces `rate` (points per tick) with `rate_per_day`
   (points per day).** `food: 67`, `water: 100`, `rest: 80` — chosen so that,
   from full (100) with no restores, food reaches 0 after
   `2200 * 100 / 67 ≈ 3284` ticks, water after exactly `2200` ticks (its rate
   equals `full`), and rest after `2200 * 100 / 80 = 2750` ticks.
   `needs.schema.json` requires `rate_per_day` (integer ≥ 0) and no longer
   permits `rate`; `additionalProperties: false` makes a needs.json that still
   declares `rate` fail `ContentRegistry` construction with
   `schema_violation`.
3. **A deterministic per-colonist, per-need integer accumulator, not
   float division.** `ActorNeeds.apply_tick()` (the only place decay is
   applied) keeps a `needsAccumulator` value per need kind alongside `needs`
   itself: each tick it adds that need's `rate_per_day` to the accumulator,
   then while the accumulator is at or above `day_length_ticks` it subtracts
   `day_length_ticks` and the need drops by one point (clamped at 0). This is
   integer-only, has no floating-point state, and is exactly reproducible
   given the same tick sequence and rate — the same guarantee AGENTS.md
   requires of all simulation state. `WorldState._decay_needs()` supplies
   `rate_per_day` (read from `content/needs.json`, not `actors.json`'s own
   dead `rates` copy — unchanged from the prior per-tick design) and
   `day_length_ticks` (from `CalendarService`, the same instance every other
   calendar-driven query reads) to `apply_tick()` each tick.
4. **`needsAccumulator` is new persisted per-colonist state.** It round-trips
   through `StateCodec.encode()/decode()` exactly like `needs` (camelCase on
   the wire, sorted keys), is required on the wire schema for every entity
   kind that carries `needs` (colonist, wolf), and is validated by
   `SaveIO._validate_state()` (non-negative integers for food/water/rest, no
   upper bound — unlike `needs` itself, an accumulator's range is
   `[0, day_length_ticks)`, and hardcoding that content-derived bound into the
   schema would drift the next time the day length is rebalanced). This is
   schemaVersion 22's only shape change; `SaveMigrations._migrate_v21_to_v22()`
   backfills every pre-v22 entity's `needsAccumulator` to zero for each kind
   its `needs` already tracks — honest, since no v21 save ever tracked a
   sub-point carry to lose.
5. **The sowing window's day-number range is unchanged.** Per ADR 008,
   `calendar.json`'s `from`/`to` are plain 1-indexed, inclusive *day numbers*
   (`day_of_tick(tick) = floor(tick / day_length_ticks) + 1`), not ticks and
   not a fraction of a day to rescale. `day_length_ticks` changing from 100
   to 2200 changes how many ticks a day takes, not what a day number means,
   so the seeded `sow` window stays exactly `{from: 1, to: 20}` — the sowing
   season is still days 1 through 20, now each a longer 2200-tick day. An
   earlier revision of this ADR rescaled `to` to 419 to "preserve the same
   fraction of a day"; that treated `from`/`to` as if they were ticks, which
   contradicts ADR 008 and `CalendarService.day_of_tick`/`active_boost`, and
   would have silently extended the farming boost from 20 game-days to 419
   game-days. That rescale is reverted.

## Consequences

- No floats enter simulation state: `needs`, `needsAccumulator`, and every
  content value this change touches are integers.
- `test_needs.gd`, `test_need_jobs.gd`, `test_new_game_forage_chop.gd`,
  `test_calendar.gd`, and `test_labour_priority_scheduling.gd` are rewritten
  against the new scale (`day_length_ticks: 2200`, `rate_per_day` fixtures),
  not weakened.
- `test_save_migration.gd` adds a v21→v22 fixture proving a pre-v22 save
  loads with every accumulator backfilled to 0.
- `NeedGiver` and `CalendarService` needed no code change: neither reads
  `rate`/`rate_per_day` directly (`NeedGiver` only reads thresholds;
  `CalendarService` treats `day_length_ticks` as an opaque content value).

## Alternatives considered

- **Keep `rate` as points-per-tick and just divide `day_length_ticks` by 22 in
  the accumulator instead.** Rejected: the design names the new content
  field `rate_per_day`, and points-per-day is far easier for a content author to reason about and balance than a
  fractional-points-per-tick rate would be.
- **Rescale the sowing window's `to` by the same factor `day_length_ticks`
  grew by (to 419).** Rejected: `from`/`to` are day numbers under ADR 008,
  not ticks, so there is no fraction-of-a-day ratio to preserve; rescaling
  them changes the sowing season's actual length in days, an unintended
  gameplay change.
