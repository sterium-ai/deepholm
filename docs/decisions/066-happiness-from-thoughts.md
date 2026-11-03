# ADR 066: Happiness from a thought table

> **In short:** A colonist keeps a short list of timed *thoughts* (`{"id", "until"}`), each
> defined in `content/thoughts.json` with a weight, a duration in days and a repeat rule.
> Happiness is never stored: it is 50 plus the weights of the active thoughts, clamped to
> 0..100. Thoughts come from existing events (eating, sleeping, being hungry, sleeping with
> no bed in reach, finishing a harvest or craft job, a colony colonist dying) through a few
> one-line hooks. The colonist panel shows happiness and the active thoughts. Saves move to
> schema v13 (an optional `thoughts` field per colonist).

- **Status:** proposed (design closed with the owner in BACKLOG F5c; owner sign-off pending)
- **Date:** 2026-11-03
- **Scope:** content (`thoughts.json` and its schema), simulation (`ActorThoughts`, hooks in
  `NeedsSystem`, `ToilBindings`, `CombatSystem`), persistence (schema v13), presentation
  (`ViewSnapshot` happiness block, colonist panel)
- **Depends on:** ADR 065 (meals and `satiety`, F5b), ADR 051 (data-driven work effects),
  ADR 011 (one work engine)
- **Implements:** BACKLOG F5c

## Context

The owner's design (BACKLOG F5c) asks for happiness built from a table of thoughts: meal (+),
raw food (0), hungry (−), slept on the ground (−), bed (+), harvested (+), crafted (+),
colonist died (−). Each thought has an id, a ± weight, a duration in days and a repeat rule.
Happiness = 50 + the sum of the active weights, clamped to 0..100, shown in the colonist panel.
Mood effects (F5d), relations and F9 are non-goals. `world_state.gd` must not grow, and
`needs_system.gd` gets hooks, not a rewrite (owner note for F5c).

## Decision

**Content.** `content/thoughts.json` (schema `content/schemas/thoughts.schema.json`, picked up by
the registry's schema discovery) holds `base` 50, `min` 0, `max` 100, the two state rules `hungry` (food ≤ 25)
and `slept_ground` (rest ≤ 25), `meal_items` (`["meal"]`), and the table:

| id | weight | days | repeat | source |
|---|---|---|---|---|
| `ate_meal` | +10 | 1.5 | refresh | a need job eats an item in `meal_items` |
| `ate_raw` | 0 | 1 | refresh | a need job eats any other food |
| `hungry` | −12 | 0.1 | refresh | each tick while food ≤ 25 |
| `slept_ground` | −8 | 0.5 | refresh | each tick while rest ≤ 25 and no bed is reachable |
| `slept_bed` | +8 | 1.5 | refresh | a sleep job completes (sleep jobs always target a bed) |
| `harvested` | +2 | 1 | stack 3 | a job of kind `harvest` completes (`job_kinds`) |
| `crafted` | +2 | 1 | stack 3 | a job of kind `craft_work` completes (`job_kinds`) |
| `colonist_died` | −15 | 5 | stack 3 | a colony colonist dies; every other colony colonist |

`refresh` restarts the one instance; `stack` adds an instance up to `stack_limit`, then
restarts the one that expires first.

**State.** A colonist's optional top-level `thoughts` is a list of `{"id", "until"}` sorted by
id then `until`; a thought is active while the tick is below `until`. The key is absent when
the list is empty, so a colonist that never thought saves as before. Only colonists think.

**Code.** `ActorThoughts` (`core/actors/thoughts.gd`) is a static module with no state and no
clock: every function takes the tick. Hooks, each one line or a short block:
- `NeedsSystem.decay_needs()` calls `ActorThoughts.apply_state_tick()` inside its existing
  colonist loop (prune, then `hungry` / `slept_ground`). "No bed reachable" is judged from each
  colonist's own region. The set of regions that reach a bed is built at most once per tick,
  and only when some colonist's rest is low;
- `NeedsSystem.apply_need_effect()` adds `ate_meal` / `ate_raw` / `slept_bed`;
- `ToilBindings._complete_job()` calls `NeedsSystem.add_job_thoughts()` (by `job_kinds`);
- `CombatSystem.apply_actor_death()` calls `NeedsSystem.record_colony_death()`, which counts a
  pending death. The next tick's decay colonist loop gives `colonist_died` to each colony
  colonist once per pending death, then clears the count. The thought lands one tick after
  the death.

No new per-colonist loop (every per-colonist step runs in the existing decay loop), no
randomness. Happiness is derived in `ViewSnapshot`, which gains a
`happiness` block `{colonist id: {value, thoughts}}` for detailed ids; the panel reads it.

**Persistence.** Schema v13. Migration `_v12_to_v13` changes no data (the field is optional
and absent means no thoughts); the validator checks the shape. An optional top-level
`pendingColonyDeaths` (integer ≥ 1, absent when 0) carries a death not yet applied across a
save, so a save in that window restores exactly. Fixture
`save_schema_v13_fixture.json` carries thoughts.

## Alternatives considered

- **Stored happiness, adjusted by events.** That needs decay rules and a second persisted
  value that can drift from the thoughts. Deriving it keeps one source of truth.
- **`slept_ground` from a sleep job on the floor.** Sleep jobs always target a bed, so that
  event never happens. The thought therefore comes from the decay tick (tired with no
  reachable bed), which is when a colonist would really sleep rough.
- **Thought triggers declared in work effects (`work_effects`).** That is more general but
  adds a second effect engine. The `job_kinds` list on the thought keeps the table as the
  single place to edit.

## Consequences

- Thoughts ship with no mood effects (F5d), so happiness is information only for now.
- `colonist_died` is broadcast to every colony colonist; relations (later) may weight it.
- `cook_work` does not count as `crafted`; adding it is a one-word content change.
- `content/thoughts.json` is the place to tune the weights and durations.

## Acceptance criteria

- [x] The affected canonical document is updated (this ADR, the decisions index).
- [x] Contracts, examples and tests are updated (`game-state.schema.json`, `test_thoughts.gd`,
  `test_save_migration.gd`).
- [x] Save/migration impact is handled (v13, `_v12_to_v13`, v13 fixture).
- [x] The source-of-truth index still points to the authoritative location.
