# ADR 026: Trap-on-entry and hostile climb-out raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-23
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Implements:** issue #359 (t3 of the trench/trapped-actor/rescue objective, issue #348), ADR 025.

## Decision

ADR 025 reserved `world_state.gd`'s cap at 2222 (+130 over its prior 2092) ahead of t2/t3/t4, sized
against ADR 018's incident-wiring precedent and explicitly inviting "any task that still finds
this insufficient raises the cap again with its own ADR." t3 (trap-on-trench-entry, faction-aware
climb-out, and the round-2-review-mandated correctness fixes: preempt-arrival trapping so a
same-tick route arrival and work completion can never race a despawn; a persisted `fromTile` and
faction-aware exit search with a recoverable blocked-exit outcome, not a silent `trapped: null`;
`ticksRemaining` synchronized against the real escape_trench work timer instead of a second
countdown engine; and activation-gated duration stamping, mirroring `IncidentScheduler`'s own
staging so two actors trapped on one tile never overwrite each other's progress) needed more than
ADR 025's reservation covered, moving the cap to 2322 in this ADR's own round-3 revision.

By round 4, `world_state.gd` had also absorbed origin/main's own unrelated growth (the #342 combat
system merge: `Combat`/`CombatGiver`/`CombatResolver` wiring, `_apply_combat()`, the flee-job-giver
plumbing) ahead of this task's own merge commit, and round 4's own review fixes added a further
narrow set of changes confined to `_actor_may_reserve_target()` (a trapped actor may only ever
reserve its own tile, closing off `CombatGiver`'s own `flee` job for one), `_check_trench_arrival()`
/`_toil_on_work_complete()` (trapping now gated to a colonist or a hostile actor only, never a
trader, per Non-goals), and `_remove_colonist_by_id()` (an actual death, not just an ordinary
incident despawn, always wins over the trapped-actor despawn guard). The cap moves 2594 -> 2774
(+180) to match the file's exact post-change line count as merged, per the convention ADR
016/017/018/022/024 already set ("cap equals exact post-change line count") -- the 2594 starting
point already reflects origin/main's own pre-existing combat-system growth, not this task's own.

t3 also moves the `trench_climb_ticks` tunable from the top-level `trenchClimbTicks` sibling round
1 used (a divergence from the task's requested `wild.trench_climb_ticks` shape, forced by
`ActorWild.validate()` rejecting non-empty `wild` tunables and `wild.gd` being outside round 1's
Owned paths) into `content/actors.json`'s `tunables.wild.trench_climb_ticks`, now that `wild.gd`
and `core-budgets.json` are both authorized paths for this round. `_trench_climb_ticks()` reads
the new path; the constant's default (`DEFAULT_TRENCH_CLIMB_TICKS = 40`) and every existing
trapped-actor test behaviour are unchanged, since the wolf's real content value stays 40.

## Consequences

- No further trap/climb-out work is anticipated in `world_state.gd` beyond this task (t4, rescue,
  is expected to add a bounded amount of its own completion-effect code); a future task that still
  finds the cap insufficient raises it again with its own ADR, same as this one did for ADR 025's.
- `ActorWild.validate()` now accepts an optional single tunable, `trench_climb_ticks: int >= 1`;
  every other component's tunable contract is unchanged.
