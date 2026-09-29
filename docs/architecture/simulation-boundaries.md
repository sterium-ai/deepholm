# Simulation boundaries

## Runtime layers

```text
Presentation
  UI, renderer, input mapping, audio, accessibility
        |
Application
  command validation, session lifecycle, save/load orchestration
        |
Simulation core
  clock, map, entities, needs, jobs, inventory, construction, production
        |
Content and persistence
  versioned definitions, serializers, migrations, deterministic RNG
```

The dependency direction is downward. The simulation core has no dependency on
the presentation or platform layers.

## Inputs and outputs

The core accepts:

- a `Command` with actor, command ID, simulation tick, and typed payload;
- a fixed content bundle/version;
- a seed and, when loading, a validated state snapshot.

The core returns:

- a new immutable state snapshot or a typed command rejection;
- ordered domain events with tick and source entity;
- a deterministic state hash suitable for tests and diagnostics.

UI state, camera position, selected entity, animations, sound playback, network
responses, and platform callbacks are not simulation state. They may reference
simulation IDs but cannot mutate the core directly.

## Determinism and time

- The simulation advances only through explicit ticks.
- Randomness comes from an injected seeded generator; no wall-clock or global
  random calls are permitted in core rules.
- Event ordering is stable: tick, system priority, entity ID, event sequence.
- Floating-point values are avoided in authoritative state where integer or
  fixed-point values are sufficient.
- Task selection and route work run on deterministic, bounded per-tick work
  budgets; partially processed work persists between ticks rather than
  restarting. A maximum service wait for continuously eligible work, measured
  in ticks, and an explicit fairness policy for lower priorities are declared
  in the owning task contract. A blocked task is skipped without blocking
  evaluation of other eligible tasks in the same tick, and reservations are
  released on cancellation, failure, or invalidation and reconsidered when
  prerequisites change (see
  [ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md)).

## Explainability

Every rejected, blocked, interrupted, or cancelled command, and every
transition of a simulation-owned actor to idle, carries its actual reason as
part of core state or as an ordered domain event — never only inferable from
animation, inactivity, or other presentation-layer state. The reason
identifies the blocking prerequisite or interruption cause and, where
applicable, a remedy, and it updates when the cause changes. Presentation
reads these authoritative reasons; it does not re-derive them (see
[ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md)).

## Persistence boundary

Save files contain `schemaVersion`, `contentVersion`, `seed`, `tick`, and the
serializable state defined by [the schema](contracts/game-state.schema.json).
Unknown fields may be ignored for forward-compatible reads; missing required
fields must fail with a migration error, never silently default.

A candidate snapshot is validated before it replaces the active save, and the
last known-good save is preserved until that replacement succeeds. A failed
write or load produces a visible, typed error and leaves the prior save and
the live simulation state intact; a save is never left half-written as the
active save (see
[ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md)).

## External services

Android, billing, ads, achievements, identity, analytics, and cloud services are
adapters behind application interfaces. They are out of scope for the vertical
slice and must never be called from simulation systems.

## Mobile and platform boundary

The application layer suspends simulation tick submission while the app is
backgrounded and caps foreground rendering; it must not run background
rendering or polling beyond what session lifecycle requires. Platform
callbacks (lifecycle, input, notifications) never mutate the simulation core
directly — they route through the same command boundary as any other input
(see
[ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md)).
