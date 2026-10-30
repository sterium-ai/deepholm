# ADR 062: Skills and XP per labour

> **In short:** Every colonist has a skill level from 0 to 10 in each labour. Finishing a job
> earns experience (XP) in that job's labour, and enough XP raises the level. A more skilled
> colonist works faster (70 % speed at level 0, 160 % at level 10), a good hauler carries one
> more item every 5 levels, and when several free colonists could take a job the most skilled
> one gets it. A new world gives each colonist two strong labours and weak ones elsewhere,
> drawn from the world seed. Skills are saved (save schema v6).

- **Status:** accepted
- **Date:** 2026-10-30
- **Scope:** content (`game/content/skills.json` and its schema, the scenario roster's
  `skills`), simulation (the skills component, the work toil's duration, hands capacity, the
  scheduler's batching pick, XP at job completion, world seeding, the view snapshot),
  persistence (schema v6), presentation (the work table)
- **Extends:** [ADR 004](004-global-assignment-fairness-policy.md) (global assignment),
  [ADR 012](012-actors-and-components.md) (actors and components),
  [ADR 037](037-hands-multi-unit-carrying.md) (hands), [ADR 055](055-viewer-snapshot.md)
  (view snapshot), [ADR 057](057-scenario-start-fields.md) (scenario roster)
- **Implements:** BACKLOG F3 (design closed with the owner on 2026-10-30; owner decisions of
  2026-10-30 on the speed figure and the scope, below)

## Context

The baseline asks for colonists who get better at what they do. The owner closed the design on
2026-10-30: a level 0–10 per labour; XP per completed job (amount per job kind in content,
default 1); growing thresholds in a content table; work speed linear from 70 % at level 0 to
160 % at level 10, applied to `work_ticks`; one extra hauled item every 5 levels; seeded
starting skills (two labours at 3–6, the rest at 0–2) that a scenario roster may fix; the most
skilled free colonist with the labour enabled is preferred, ties broken by distance as before;
no decay; skills saved and shown in the labour table.

Owner decisions taken while implementing and after review (2026-10-30, in the author's terminal):

- **Speed figure.** The entry's acceptance said a level-8 colonist finishes "in ~62 %" of the
  level-0 time, but the closed curve gives 70 / 142 ≈ 49 %. The owner kept the curve
  (70 → 160) and corrected the acceptance figure to ~49 %.
- **Scope.** The owner extended F3's owned paths to `core/jobs/toil_bindings.gd` (XP at job
  completion), `core/world/view_snapshot.gd` (skill progress for the viewer) and
  `core/worldgen/world_seeding.gd` (where colonists are created and the roster applied, in
  place of `world/scenario_builder.gd`). After review, the owner also approved
  `core/actors/actor_table.gd` (`spawn("colonist")` builds the zero skills, item 2).

## Decision

1. **Content.** `skills.json` (a document kind, discovered by ContentRegistry like any file
   with a schema): `xp_to_next` (the XP that takes level L to L + 1, `[10, 25, 45, 70, 100,
   135, 175, 220, 270, 325]`; its length, 10, is the top level), `speed_percent_at_min` 70,
   `speed_percent_at_max` 160, `carry_labour` "haul", `carry_bonus_every` 5,
   `xp_per_job` `{default: 1, by_kind: {}}` and `starting` `{major_count: 2, major_min: 3,
   major_max: 6, minor_min: 0, minor_max: 2}`. The schema types each `by_kind` value as an
   integer >= 0 by listing every job kind of `jobs.json` (the loader's schema subset checks
   values only through named properties), so a bad or unknown override fails content loading;
   a job kind added later needs a schema line before it can be overridden. A bundle without the file (a test fixture) has
   empty rules: base speed, no XP, no bonus, no seeding.
2. **State.** A worker carries `skills`, `{labour: {level, xp}}` for its declared labours;
   `xp` is the progress inside the current level and restarts at 0 on a level up (the
   remainder carries over); the top level keeps `xp` 0. `ActorTable.spawn("colonist")` builds
   every labour at 0. The component is `core/actors/components/skills.gd` (`ActorSkills`),
   static functions over the actor dictionary and the rules, like the other components.
3. **Work speed.** `ToilExecutor.start_work()` sets the work toil's duration to
   `max(1, round(work_ticks * 100 / speed))`, `speed = at_min + (at_max - at_min) * level / 10`
   (integer division). Chop (40 ticks): 57 ticks at level 0, 28 at level 8. A labour the
   colonist has no record for (forage, need jobs) keeps `work_ticks`. A resumed job keeps its
   stored remainder (not rescaled). `site_work` has `work_ticks` 1, so building speed does not
   change with skill (limitation, see below).
4. **XP.** Every toil-driven completion goes through `ToilBindings._complete_job()`: once
   `finish(complete_job)` accepts it, the colonist that held the job earns
   `xp_per_job.by_kind[kind]` (else `default`) in the kind's labour
   (`ToilExecutor.award_job_xp()`). A player `complete_job` command earns nothing. No event is
   emitted (the labour table shows the level).
5. **Hands.** Capacity is `ActorInventory.HANDS_CAPACITY` (4) plus `haul level / 5`
   (`ToilExecutor.hands_capacity()`); `pick_up` and site-fetch's "hands full" rule read it, and
   the save validator checks a colonist's hands against it.
6. **Assignment.** `GlobalAssignment` scores proposals exactly as before and records each
   proposal's `skill` (the worker's level in the job's labour). In the batching pass, when a
   job's turn comes (its best-scored proposal from a worker whose slot is free), the job goes
   to the most skilled of its proposers whose slot is still free; equal skill keeps the first in
   the old `_pair_before()` order, which is the old choice (best score: priority, aging,
   travel). With all skills equal the batching is exactly ADR 004's. Proposals are grouped by
   job once per tick, so the pass stays linear in the number of proposals. Labour eligibility,
   the priority bracket, aging and activation are unchanged.
7. **Starting skills.** `WorldSeeding` seeds every new world's colonists from a local RNG
   seeded `placement_seed ^ 0x5C11` (never the simulation stream, so placement and the
   simulation stream do not shift): for each colonist in roster order, two distinct labours are
   drawn as majors, then one level per labour in declared order (majors 3–6, others 0–2). A
   scenario roster entry's `skills` (`{labour: level}`, levels 0–10, checked by the schema)
   then overrides those labours with XP 0. A decoded world is never reseeded. Colonists spawned
   later (an incident's migrant) start at 0.
8. **Save, schema v6.** Each colonist entity has `skills` (sorted labours, `{level, xp}`
   ints); it is in `state_hash()` with the rest of the actor. `SaveMigrations._v5_to_v6()`
   gives each colonist of a v5 save every labour of its `labourTable` at level 0, XP 0 (a v5
   colonist had no skills; seeding happens only at world creation). The validator checks a
   colonist's `skills`: exactly the 7 labours, level 0..top, `0 <= xp < xp_to_next[level]`
   (0 at the top). The field is optional, like `heldTool`: every colonist the game spawns, seeds
   or migrates carries it, and a worker without it (a hand-built test actor) works untracked
   (invariant of item 3). Fixture `save_schema_v6_fixture.json`, written by
   `docs/orca/handoffs/F3-write-save.gd`.
9. **Viewer.** `get_view_snapshot()` adds `skills`, `{detailed id: {labour: {level, xp,
   next}}}` from `ActorSkills.progress()` with the world's rules; the work table shows, under
   each priority button, the level and a bar of XP toward the next level (full at the top).

## Consequences

- Every new world's colonists now work at 70–124 % of the old speed in their labours, so
  tests that counted work ticks on seeded colonists were updated (the handoff report lists
  them); hand-built test colonists without `skills` keep the old timing.
- `state_hash()` of every scenario changes (new persisted field and seeded levels).
- Saves are schema v6. When F1 (v6) and F2 (v7) land first, this bump moves to the next free
  number at rebase, with its migration arm renumbered.

## Limitations

- Building speed does not scale (site_work's `work_ticks` is 1; a site's progress is one per
  builder per tick); build XP is earned per site_work job, i.e. per tick of building.
- No skill-up event or message; XP gained by an interrupted job is earned only at completion.
- Migrated (v5) colonists start at level 0 in every labour.

## Alternatives considered

- **Skill as a score term.** Adding `k * skill` to the pair score would let skill outweigh the
  player's priorities and the aging guarantee, and no `k` both beats the travel penalty (up to
  15) per level and stays under one priority bracket (16) over ten levels. Rejected for the
  batching pick above, which only reorders who gets a job among its proposers.
- **Store cumulative XP and derive the level.** The level would change when content changes
  the thresholds; storing the level keeps saves stable.
- **Seed migrated colonists.** The design seeds skills when a world is created; a migration
  that invented levels for a colony already in play (migrants included) would be a second,
  different seeding rule. Level 0 is explicit and needs no RNG in the migration.
