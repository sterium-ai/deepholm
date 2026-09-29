# ADR 003: Deterministic scheduling, explainability, save integrity, and mobile-first constraints

- **Status:** accepted
- **Date:** 2026-09-14
- **Owners:** project integrator and simulation owner
- **Scope:** simulation, persistence, presentation

## Context

Issue #15 asks the project to turn the most common ways colony
simulations lose player trust (the "what goes wrong" design-research notes)
into canonical, cross-cutting contracts before further vertical-slice
implementation proceeds. Those notes rank four problems and state a "game
rule" for each:

1. Save loss and crashes destroyed progress and trust (saving is typically an
   opt-in per-class contract with no version field or atomic-write pattern).
2. Colonists went idle under load despite queued work (task, action and
   path managers are typically three separate large classes with no
   transactional handoff or fairness policy).
3. Colonist behavior had no actionable explanation (status/thought
   vocabulary existed, but no evidence ties it to the actual decision that
   produced a given outcome).
4. Mobile touch, readability, and battery constraints are core
   requirements, not optional polish.

[ADR 001](001-game-foundation.md) already establishes the
tick-driven, seeded-random simulation core and its independence from
presentation and platform. [ADR 002](002-agent-ownership-and-review.md)
already establishes that a subsystem owner records its contract in the
repository and a different agent reviews it. Neither ADR states, at a level
concrete enough to implement against, how task scheduling must behave under
load, how a rejection or idle transition must be explained, what "save
integrity" requires beyond "versioned," or what mobile-first means for the
application and presentation layers. This ADR closes that gap by promoting
the four "what goes wrong" game rules to accepted, canonical decisions,
without reopening or weakening ADR 001 or ADR 002.

## Decision

The following four principles are accepted as canonical, in addition to
(not replacing) ADR 001 and ADR 002. Each is a contract that later
implementation task contracts must conform to; this ADR does not itself
implement any of them.

### 1. Task scheduling and priority is a deterministic contract

- Task selection and route work operate on deterministic, bounded
  per-tick work budgets. Progress on partially processed work persists
  between ticks rather than restarting.
- A maximum service wait, expressed in simulation ticks (never render
  frames or wall-clock time), is defined for continuously eligible work at
  the supported load, together with an explicit fairness policy that
  prevents higher-priority work from starving lower-priority work
  indefinitely.
- A blocked task must be skippable without blocking evaluation of other
  eligible tasks in the same tick.
- Reservations (of a target tile, item, or route) are released on
  cancellation, failure, or invalidation, and are reconsidered when
  prerequisites next change; a reservation must never be silently leaked.
- The exact numeric wait bound and workload shape are specified in the
  task contract that implements the scheduler, not invented from
  guesses about how other games schedule (the research notes explicitly do
  not establish any other game's scheduling algorithm or tick order).

### 2. Explainability is a core feature, not a presentation add-on

- Every rejected, blocked, interrupted, or cancelled order, and every
  transition of a colonist to idle, must expose its actual reason through
  core state or an ordered domain event — never only through animation,
  inactivity, or other presentation-layer inference.
- The reason must be specific and current: it identifies the blocking
  prerequisite or interruption cause and, where applicable, a remedy (for
  example, enable a labor, or supply a missing input), and it updates when
  the cause changes.
- This extends the typed command rejection and ordered domain events
  already required by [`simulation-boundaries.md`](../architecture/simulation-boundaries.md):
  those events are the authoritative channel for "why did that happen,"
  and presentation must read them rather than re-derive a reason.

### 3. Save integrity is a named strategy, not an implicit property

- At the application persistence boundary, a complete, versioned snapshot
  is validated before it replaces the active save. The last known-good
  save is preserved until replacement succeeds.
- A failed write or load produces a visible, typed error and leaves the
  prior save and the live simulation state intact — a save is never left
  half-written as the active save.
- The persisted snapshot always carries `schemaVersion`, `contentVersion`,
  `seed`, `tick`, and the state the schema requires. Migration between
  schema versions is explicit; a missing required field fails the load
  with a migration error and must never be silently defaulted. This
  restates and sharpens the existing rule in
  [`simulation-boundaries.md`](../architecture/simulation-boundaries.md)'s
  persistence boundary section, which already forbids silent defaulting.
- Saving and loading at the same tick must produce equivalent simulation
  state, excluding transient UI state (already required by
  [`vertical-slice.md`](../architecture/vertical-slice.md)); this ADR adds
  that the validate-before-replace and preserve-last-good-save behavior is
  itself in scope for that same acceptance test.

### 4. Mobile-first is an explicit constraint on the application and presentation layers

- In the presentation layer, camera gestures (pan, zoom) are distinguished
  from order gestures; an area order previews the affected tiles and is
  cancellable before it commits.
- Critical status and failure/explanation reasons (principle 2) remain
  readable and reachable at the smallest supported screen and UI scale,
  with no interaction that depends on hover.
- In the application layer, simulation tick submission is suspended while
  the app is backgrounded; foreground rendering is capped, and no
  background rendering or polling runs beyond what session lifecycle
  requires.
- Platform callbacks (lifecycle, input, notifications) never mutate the
  simulation core directly — they route through the same command boundary
  as any other input, per [ADR 001](001-game-foundation.md) and
  [`simulation-boundaries.md`](../architecture/simulation-boundaries.md).
- A device-specific frame-pacing and battery/power budget, and the exact
  smallest supported device/screen size, are agreed in the mobile
  acceptance task contract before mobile acceptance testing, not asserted
  here without measurement.

Stable IDs, versioning, and migration consequences for any new persisted
field these principles eventually require are deferred to the task
contract that implements them; this ADR fixes the contract-level rule, not
a data shape.

## Alternatives considered

- **Leave the four rules as informal guidance inside the research notes.**
  Rejected: research notes are evidence, not contracts, and
  `source-of-truth.yaml` ranks evidence below canonical contracts and
  accepted ADRs. Cross-cutting rules that every future task contract must
  satisfy need to sit in the canonical/ADR tier, or they can be silently
  overridden by a task that never reads the notes.
- **Split this into four separate ADRs, one per principle.** Rejected:
  the four principles were ranked and evidenced together against the same
  vertical slice, reference the same two canonical documents, and are
  small enough individually that four ADRs would fragment review and
  invite drift between them (for example, explainability's event channel
  and save integrity's typed-error channel should stay the same shape).
- **Adopt a generic FIFO or strict-priority task queue with no fairness
  guarantee.** Rejected: a strict-priority queue reproduces exactly the
  starvation risk the research notes rank second — high-priority work
  arriving continuously would starve lower-priority work indefinitely,
  which is the reported symptom, not a fix for it.
- **Let presentation infer explanations from animation or inactivity
  state, as many games do.**
  Rejected: this reproduces the exact gap identified in problem 3 and
  conflicts with the presentation/simulation boundary ADR 001 already
  established.
- **Treat mobile constraints as post-slice polish.** Rejected: the design
  notes rank this as one of four core problems, not as a nice-to-have; deferring it past the vertical slice would let an
  architecture take shape that cannot cheaply add gesture disambiguation
  or backgrounding behavior later.
- **Specify exact numeric wait bounds, device targets, or battery budgets
  in this ADR.** Rejected: the research notes explicitly warn against
  inventing a capacity limit from guesses about other games; those
  numbers belong in the task contract that implements and measures them,
  with this ADR fixing only the shape of the guarantee.

## Consequences

- [`docs/architecture/vertical-slice.md`](../architecture/vertical-slice.md)
  and [`docs/architecture/simulation-boundaries.md`](../architecture/simulation-boundaries.md)
  gain additive clarifications (see their diffs in this same change) that
  make the four principles checkable acceptance criteria rather than only
  ADR prose. No existing acceptance criterion in either document is
  removed or weakened.
- Future task contracts — a task-scheduler contract, an explainability
  event/reason schema, a save-migration implementation, and a mobile
  input/performance budget — must each cite this ADR and satisfy the
  relevant principle above; a reviewer (per ADR 002) checks the task
  contract against this ADR before implementation review.
- `docs/architecture/contracts/game-state.schema.json` is unchanged by
  this ADR. The schema fields these principles will eventually need
  (for example, a persisted task-reservation identity or a typed reason
  code) are introduced by the implementing task's own contract update,
  not invented speculatively here.
- `game/` is unchanged by this ADR; no principle above is implemented in
  code by this change.
- Ownership: the simulation owner is responsible for the scheduler and
  save-integrity contracts (principles 1 and 3); the agent implementing
  presentation/application boundaries owns the explainability event
  surface and mobile constraints (principles 2 and 4), consistent with
  ADR 002's phase-based ownership rather than a fixed model assignment.
- Risk accepted: because the exact wait bound, reason taxonomy, and mobile
  device budget are deferred to implementing task contracts, this ADR
  alone cannot be tested end-to-end; the acceptance criteria below are
  scoped to what this documentation-only change can verify.

## Acceptance criteria

- [ ] The affected canonical documents (`vertical-slice.md`,
      `simulation-boundaries.md`) are updated additively to reflect the
      four principles, or this ADR states why no change was needed for a
      given document.
- [ ] `docs/architecture/source-of-truth.yaml`'s evidence section lists
      the design-research documents.
- [ ] Contracts, examples, and tests are marked N/A: this ADR does not
      change `game-state.schema.json` or any test, since no principle is
      implemented in code by this change.
- [ ] Save/migration impact is N/A for this change; the save-integrity
      *strategy* is fixed here, and its implementation is deferred to a
      future task contract that this ADR constrains.
- [ ] The source-of-truth index still points to the authoritative location
      for each canonical document (unchanged by this ADR).
