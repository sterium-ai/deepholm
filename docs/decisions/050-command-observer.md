# ADR 050: Optional command observer on `WorldState.apply()`

> **In short:** `WorldState` gets one optional listener, `command_observer`. After each
> command that comes from outside the core, `apply()` calls it with the command and its
> result. It exists so the viewer can record a session for headless replay (A11). It may
> not change the world, only one listener can be set at a time, and commands the core sends
> itself while ticking are not reported.

- **Status:** accepted
- **Date:** 2026-10-28
- **Scope:** simulation (public surface of `WorldState`), presentation (the recorder in `boot.gd`)
- **Depends on:** ADR 048 (composed core: `WorldState` façade), ADR 044 (area-order expansion queue)
- **Implements:** BACKLOG A11, with the hook the owner approved in A11's scope extension;
  `docs/architecture/replay.md`

## Context

A11 records a viewer session (start state, every command, `state_hash()` checkpoints) so that
`tools/replay.ps1` can replay it headless and report the first diverging tick. The viewer has no
single place where commands pass through: `map_view`, `order_input`, `colonist_panel`,
`work_table_panel`, `debug_scenario`, `new_game_setup` and `boot.gd` each call `world.apply()`
directly. A
recorder therefore has to hear commands at `WorldState.apply()` itself.

Until now `WorldState`'s contract (`simulation-boundaries.md`, "Inputs and outputs") was: commands
in, state, events and hash out. Presentation could read but had no hook into the core. A
listener on `apply()` adds to that public surface, and this ADR fixes its rules.

The core itself also calls `apply()`. `AreaOrders` (ADR 044) expands an `area_order` tile by tile
inside `tick()`, and it did so through the public `apply`. Building the hook showed the
consequence: an observer on `apply()` heard every expanded tile. The replay then applied each
one twice, once from the log and once from its own expansion, and diverged one tick after the
area order.

## Decision

1. **Shape.** `WorldState.command_observer: Callable`, unset by default. `apply(command)`
   runs the command router, then, if the observer is valid, calls
   `command_observer.call(command, result)` with apply()'s own result, and returns that
   result unchanged. `preview()` and `tick()` never call it.
2. **Timing.** The observer is called once per `apply()` call, after the command has been
   validated and applied or rejected, and before `apply()` returns. Rejected commands are
   reported too, with `result.ok == false`.
3. **Only commands from outside the core.** Code inside the core never sends commands
   through the public `apply()`. `AreaOrders` is built with
   `func(command: Dictionary) -> Dictionary: return _commands.apply(command)`, which calls the
   command router directly. As a result, the per-tile commands an area order sends while
   expanding inside `tick()` are not reported: they are part of the tick, and a replay
   reproduces them by ticking. Any future core module that needs to submit commands receives
   the router in the same way, never `apply`.
4. **No mutation.** The observer may read the command and the result, and read-only getters.
   It must not call `apply()`, `tick()` or anything that changes state, and it must not
   change the `command` or `result` dictionaries in place; the recorder deep-copies what it
   keeps. Neither the observer nor whether one is set is part of `state_hash()` or the save.
5. **Ownership.** The slot holds one listener. Today its only user is the viewer's
   `CommandRecorder`: `start()` sets the observer and `stop()` clears it. `boot.gd` stops the
   recorder before swapping worlds, so a world never keeps an observer it no longer reports
   to. Before a second listener ever lands, a list of listeners would replace the single
   slot; this ADR would be amended.

## Alternatives considered

- **Route every viewer command through one viewer function.** The direct `world.apply()`
  calls in seven files (`boot.gd`, `map_view`, `order_input`, `colonist_panel`,
  `work_table_panel`, `debug_scenario`, `new_game_setup`) would have to change, and nothing
  would stop a new viewer module from calling `world.apply()` directly and going unrecorded. Rejected: it is fragile, and it reaches
  far beyond A11's scope.
- **Rebuild commands from the event log.** The `command_applied` event has the command id,
  actor and payload but not the type, and rejections only record a reason. Rejected: the
  log does not hold enough to rebuild the commands.
- **A `WorldState` subclass that records.** `StateCodec.decode()` and the new-game paths
  build plain `WorldState`s, so a loaded or new world would not record. Rejected.
- **A Godot signal.** `WorldState` is a plain-GDScript `RefCounted`, and no class in the core
  declares a signal. A `Callable` slot does the same job without adding an engine-object
  dependency.

## Consequences

- The viewer can record any session. With no observer set, the cost is one `is_valid()` check
  per command. `world_state.gd` grows by 3 lines (796, rule 800).
- The observer only ever reports commands from outside the core. That is what makes "apply
  the recorded commands, then `tick()`" a faithful replay.
- Risk: a listener that mutates the world would break determinism. Nothing in the language
  stops it, so the rule rests on this ADR, the comment on the field and code review. The
  only listener records data.
- Deferred: several listeners at once (see Decision 5).

## Acceptance criteria

- [x] The affected canonical documents are updated: `simulation-boundaries.md` ("Inputs and
  outputs") and `replay.md`.
- [x] Contracts, examples and tests are updated. `test_command_replay.gd`
  `_check_observer_contract` covers Decision 1–3: one call per `apply()` with that call's
  result, rejections included; no call from `preview()`; no call while an `area_order`
  expands inside `tick()`; the call site is only in `apply()`; `AreaOrders` does not receive
  `apply`. `test_boot_command_recording.gd` covers Decision 5 (F9 sets and clears the
  observer, and a world swap leaves none).
- [x] Save/migration impact: none. The observer is not persisted or hashed.
- [x] `source-of-truth.yaml` is unchanged in authority. `replay.md` stays indexed under
  `command_replay`, and this ADR is in `docs/decisions/`.
