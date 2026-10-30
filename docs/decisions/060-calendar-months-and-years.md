# ADR 060: Calendar months and years derived from the day

> **In short:** A month is 3 days and a year is 12 months. The game still counts only days,
> from the start; month and year are worked out from the day number, so saves do not change.
> A calendar window may now be written as a range of months as well as a range of days, and
> the viewer shows "day D · month M · year Y" with the open window's name.

- **Status:** accepted
- **Date:** 2026-10-29
- **Scope:** content (`game/content/calendar.json` and its schema), simulation
  (`CalendarService`, the view snapshot), presentation (the viewer's date line)
- **Extends:** [ADR 008](008-calendar-content-schema.md) (calendar content and `CalendarService`),
  [ADR 055](055-viewer-snapshot.md) (one read-only view snapshot per refresh)
- **Implements:** BACKLOG F0 (design closed with the owner on 2026-10-29);
  `docs/design/baseline.md` §9 and owner decision 1

## Context

ADR 008 gave the game days and day-range windows only. The baseline (`docs/design/baseline.md`
§9) asks for months and years, and the owner decided their length on 2026-10-29: 3 days per
month, 12 months per year, so a year is 36 days of 2,200 ticks. The owner also fixed that day
numbering stays as it is, that windows may be declared by months as well as by days with `sow`
left as declared, and that the viewer shows the date and the window label.

## Decision

1. **Two new content numbers.** `calendar.json` declares `days_per_month: 3` and
   `months_per_year: 12`. Both are optional in the schema and default to 1, so a test calendar
   that only sets `day_length_ticks` keeps working (every day is then its own month and year).
2. **Day is the only clock.** `day_of_tick(tick)` is unchanged (day 1 is ticks
   `[0, day_length_ticks)`). `month_of_tick(tick) = (day - 1) / days_per_month % months_per_year + 1`
   and `year_of_tick(tick) = (day - 1) / (days_per_month * months_per_year) + 1`, integer
   division. Nothing new is stored, hashed or saved: month and year are pure functions of the
   tick and the content.
3. **Month-range windows.** A window declares `from`/`to` (days) or `from_month`/`to_month`
   (months), exactly one complete pair. The schema says so with `oneOf`; ContentRegistry's
   schema subset does not read `oneOf`, so `ContentRegistry._init()` calls
   `CalendarService.window_range_error()` and rejects a half, mixed, doubled or missing range as
   `schema_violation` (`calendar.json`). `CalendarService` converts a month range once, when it loads,
   to the day range `(from_month - 1) * days_per_month + 1 .. to_month * days_per_month`, and
   every query (`active_boost`, `alert_state`, the alert giver's soonest window) reads only
   `from`/`to`. A month window is therefore exactly the equivalent day window, tick for tick.
   Like day windows, the converted range counts from the start of the game: windows do not
   repeat each year (ADR 008's one-shot alert set is unchanged).
4. **Date for display.** `date_of_tick(tick)` returns `{day, month, year, window_label}`, where
   `window_label` is the label of the first window, in declaration order, open on that day
   (`""` when none). `WorldState.get_view_snapshot()` carries it as `"date"`, computed from the
   world's own `CalendarService` (passed to `ViewSnapshot.build()` in `sources`), and the
   viewer's information column formats it through the text table
   (`calendar.date_label`, `calendar.date_window_label`, ADR 052).

## Alternatives considered

- **Store month and year in the save.** Rejected by the owner's design: they follow from the
  day, and storing them would only add a field that can disagree with the tick.
- **Windows repeat every year.** Not in the closed design, and it would change behaviour after
  day 36 and need the fired-alert set to be per year (a save change). Left for a later task.
- **A WorldState getter for the date, or a viewer-built CalendarService.** Rejected by the
  owner: `world_state.gd` is at its size limit (ADR 048) and the viewer reads one snapshot per
  refresh (ADR 055); a second CalendarService in the viewer could drift from the world's.

## Consequences

- `state_hash()`, events and saves are unchanged for every existing scenario; the shipped `sow`
  window keeps `from: 1, to: 20`.
- A crop task (F1) can keep using day ranges; content can now write seasons as months.
- The snapshot gains one small read-only Dictionary per refresh.

## Acceptance criteria

- [x] `docs/architecture/colonist-ai.md` §3.7 documents the new fields and queries.
- [x] `test_calendar_months.gd` covers the registry rejecting incomplete or conflicting ranges,
      month/year boundaries, determinism, month windows against
      the equivalent day range (pure and through `WorldState.tick()`), the snapshot's date and
      the viewer's date line.
- [x] Save/migration impact: none (nothing new persisted).
- [x] `docs/architecture/simulation-boundaries.md` names the snapshot's date.
