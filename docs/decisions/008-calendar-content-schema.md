# ADR 008: Calendar content schema and CalendarService

- **Status:** accepted
- **Date:** 2026-09-19
- **Scope:** content (`game/content/calendar.json`), simulation (new
  `game/scripts/core/calendar/calendar_service.gd`)
- **Implements:** [ADR 004](004-global-assignment-fairness-policy.md) (the
  "calendar boost" term in the effective-priority formula, `docs/architecture/
  colonist-ai.md` section 3.2); `docs/architecture/colonist-ai.md` section 3.7
  (calendar urgency); objective #197.

## Context

Section 3.7 of `colonist-ai.md` sketched calendar content before any season
or day-tracking data existed anywhere in the codebase: `{season windows,
boosts: [{labour: farm, from: spring/1, to: spring/20, boost: +1, label:
"sowing window"}]}`. That sketch names a `season` concept (`spring/1`) no
other subsystem defines yet — there is no season-length content, no
season-boundary tick, nothing a `CalendarService` could read to convert
`spring/1` into a tick or a day number. This task needed a schema and a pure
`CalendarService` today, without waiting on season content that isn't part
of this objective and that no later task in the current gating chain
introduces either.

Per `AGENTS.md`'s simulation rules, this service must be plain GDScript
driven by explicit ticks and never read wall-clock time, so "day" and
"window" have to be defined purely in terms of tick numbers and the content
file — not calendar dates.

## Decision

1. **`day_length_ticks: int` replaces implicit season/date math.** One
   number, injected from content, converts a tick into a day number:
   `day_of_tick(tick) = floor(tick / day_length_ticks) + 1`. No wall-clock
   read, no season table — `day_of_tick` is a pure function of its two
   inputs.
2. **Windows are flat day-of-year ranges, not season-qualified dates.**
   `{id, labour, from, to, boost, label}`, with `from`/`to` plain 1-indexed,
   inclusive day numbers (day 1 = spring day 1, matching 3.7's example
   exactly under that reading). This supersedes the `{season windows,
   boosts: [...]}` sketch: it drops the undefined `season windows` wrapper
   and the `spring/1`-style qualified day, and adds `id` (needed so a
   specific seeded window, `sow`, is addressable by tests and later wiring
   tasks without matching on `label` text). A later task adding summer/
   autumn/winter content adds windows whose `from`/`to` account for the
   fixed length of the seasons before them; neither the schema nor
   `CalendarService` changes to support that.
3. **`active_boost` sums matching windows instead of returning the first
   match.** Multiple windows with the same `labour` and overlapping days are
   legal content (e.g. a general priority boost stacked with a
   labour-specific one); summing is the simpler contract and degenerates to
   a single window's boost in the one-window case this task ships.
4. **`alert_state` takes colony facts as plain booleans, not a `WorldState`
   reference.** `has_labour_enabled`, `has_plowed_plot`, `has_seed_stock`,
   and `already_fired` are passed in by the caller. This task's non-goals
   explicitly exclude wiring the alert into live game state (that is t4,
   which introduces plowed-plot/seed-stock tracking); taking booleans instead
   of querying `WorldState` directly means this class has no dependency on
   that state existing yet, and t4 only has to compute the four booleans
   and call this pure function.
5. **A fixed `ALERT_LEAD_DAYS = 3` lead time, named and exported.** 3.7 says
   only "N days before a window"; 3 is a reasonable default lead (enough
   turnaround for the player to plow and stock seed without alerting so
   early it is ignored) and, critically, is a named constant on
   `CalendarService` rather than a literal, so a later balance pass changes
   one number and the test asserts against the same constant instead of a
   hand-copied value.
6. **`already_fired` is caller-tracked state, not calendar-owned.** Whether
   a given window's alert has already fired for its current occurrence is a
   one-shot flag the caller (t4) owns and persists; `CalendarService` stays
   pure and stateless across calls, consistent with every other query on
   this class.

## Alternatives considered

- **Keep the `spring/1`-style qualified date and add a season-length table
  to this task.** Rejected: no other subsystem tracks seasons, and this
  objective's non-goals exclude modifying `world_state.gd` or introducing
  new colonist/farm-order state — inventing season content here would be
  scope creep beyond what #197 asks for, and flat day numbers already
  satisfy the one seeded example (spring days 1-20 = days 1-20).
- **`active_boost` returns the first matching window's boost instead of
  summing.** Rejected: summing is no more complex to implement or test and
  does not foreclose stacked windows later; "first match" would silently
  drop a second window's boost with no signal to content authors.
- **`alert_state` reads `WorldState` directly.** Rejected: the task
  explicitly requires colony facts as booleans so t4 (which introduces
  plowed-plot/seed-stock tracking) is not a dependency of this task; a
  direct `WorldState` reference would create exactly the dependency the
  task instructions call out to avoid.

## Consequences

- `game/content/calendar.json` declares `day_length_ticks` and one seeded
  window: `{id: "sow", labour: "farm", from: 1, to: 20, boost: 1, label:
  "sowing window"}`. [ADR 023](023-needs-decay-points-per-day.md) (issue #349)
  changes `day_length_ticks` from 100 to 2200 so each day takes longer; the
  window's `from`/`to` day numbers are unchanged, since they are day numbers,
  not ticks.
- `game/scripts/core/calendar/calendar_service.gd` loads that content once
  in its constructor and exposes `day_of_tick`, `active_boost`,
  `alert_state`, `day_length_ticks`, and `window_definitions` as pure
  functions of their arguments and the cached content; it never reads
  `FileAccess`/`RandomNumberGenerator`/OS time outside that one-time load.
- `docs/architecture/colonist-ai.md` section 3.7 is updated to document this
  schema and `CalendarService`'s contract in place of the old `{season
  windows, boosts: [...]}` sketch.
- Wiring `active_boost` into the effective-priority formula (3.2) and
  `alert_state` into the alert list and live colony state is deferred to t3
  and t4 respectively, per this task's non-goals.

## Acceptance criteria

- [x] `game/content/calendar.json` matches this schema and the seeded
      `sow` window exactly.
- [x] `calendar_service.gd` contains no scene, node, wall-clock, or global
      randomness dependency; every query method is pure.
- [x] `docs/architecture/colonist-ai.md` section 3.7 documents the
      implemented schema, not the earlier sketch.
- [x] `test_calendar.gd` asserts `active_boost`, `alert_state`'s due/not-due
      conditions, and the seeded window's `id`, `labour`, `from`, `to`,
      `boost`, and `label` fields.
