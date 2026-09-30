# ADR 027: Trap-on-entry and hostile climb-out raise the world_state.gd core budget

> **In short:** A creature or colonist that walks into a trench now gets stuck, and hostile
> creatures slowly climb back out. Supporting this needed more room in one size-limited core file.

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`;
  `content/actors.json`'s `wild` tunables and `ActorWild.validate()`.
- **Depends on:** [ADR 026](026-trench-trapped-actor-and-rescue.md).

## Decision

ADR 026 reserved `world_state.gd`'s cap at 2222 (+130 over 2092) for the trench feature and stated
that any step finding it insufficient would raise it with its own ADR. Trap-on-entry and
faction-aware climb-out needed more than that reservation, for these behaviours:

- **Arrival trapping pre-empts work.** An actor is trapped as its route arrives, so a same-tick
  arrival and work completion can never race a despawn.
- **Recoverable exits.** The tile the actor entered from (`fromTile`) is persisted, and the exit
  search is faction-aware; a blocked exit is a recoverable outcome, not a silent `trapped: null`.
- **One timer.** `ticksRemaining` is synchronized with the real `escape_trench` work timer rather
  than a second countdown.
- **Activation-gated duration stamping**, mirroring `IncidentScheduler`'s staging, so two actors
  trapped on one tile never overwrite each other's progress.

That first raised the cap to 2322. The file then also absorbed the unrelated growth of the combat
system (ADR 021: `Combat`/`CombatGiver`/`CombatResolver` wiring, `_apply_combat()`, the flee giver),
which brought the baseline to 2594, plus three further trap rules:

- `_actor_may_reserve_target()`: a trapped actor may only reserve its own tile, which also keeps
  `CombatGiver` from giving it a `flee` job.
- `_check_trench_arrival()`/`_toil_on_work_complete()`: only a colonist or a hostile actor can be
  trapped, never a trader.
- `_remove_colonist_by_id()`: an actual death, unlike an ordinary incident despawn, always
  overrides the trapped-actor despawn guard.

The cap moves 2594 -> 2774 (+180) to match the file's exact post-change line count, per the
convention of ADRs 015-017, 023 and 025.

The climb-out duration is read from `content/actors.json`'s `tunables.wild.trench_climb_ticks`.
An earlier draft used a top-level `trenchClimbTicks` sibling because `ActorWild.validate()`
rejected any non-empty `wild` tunables; `ActorWild.validate()` now accepts this tunable.
`_trench_climb_ticks()` reads the new path. The default (`DEFAULT_TRENCH_CLIMB_TICKS = 40`) and
every trapped-actor test are unchanged, since the wolf's content value stays 40.

## Consequences

- No further trap or climb-out work is expected in `world_state.gd`. Rescue (ADR 029) adds its own
  code and, if the cap is insufficient, raises it with its own ADR.
- `ActorWild.validate()` accepts one optional tunable, `trench_climb_ticks: int >= 1`; every other
  component's tunable contract is unchanged.
