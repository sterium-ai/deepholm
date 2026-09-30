# Deepholm architecture

> **In short:** This folder describes how the game is meant to be built: what
> it should do, how its parts fit together, and the rules every change has to
> follow.

This directory is the canonical engineering contract for the game. It describes
the intended product, the first playable slice, simulation boundaries, data
contracts, agent ownership, and decision records. The contracts come first and
the code follows them.

## Start here

1. [Source-of-truth index](source-of-truth.yaml)
2. [Vision and principles](vision.md)
3. [Vertical slice](vertical-slice.md)
4. [Simulation boundaries](simulation-boundaries.md)
5. [Agent ownership](agent-ownership.md)
6. [Game-state contract](contracts/game-state.schema.json)
7. [Save system](save-system.md)
8. [Orders and movement](orders-and-movement.md)
9. [Colonist AI design](colonist-ai.md)
10. [Map experience](map-experience.md)
11. [Behaviour extension points](extension-points.md)
12. [Foundation for breadth](foundation-for-breadth.md)
13. [Architecture decision records (ADRs)](../decisions/)
14. [ADR template](adr/000-template.md)

For an overview of all project documentation, see the [docs index](../README.md).

Design research and playtest notes are evidence sources. When evidence is
ambiguous, the game contract wins after the decision is recorded in an ADR.

## Contract rules

- The simulation is deterministic for a fixed seed, command stream, and content
  version.
- Rendering, UI, audio, platform services, and monetization cannot mutate
  simulation state directly; they submit commands or consume events.
- Gameplay content is data-driven and versioned. IDs are stable once published.
- Saves contain a schema version and must be migrated explicitly.
- Every change to a boundary, public data shape, or vertical-slice acceptance
  criterion requires an ADR or an update to the relevant contract.

## Acceptance criteria for this documentation package

- A new contributor can identify the canonical document for each architecture
  concern in under five minutes.
- A simulation test can run without a renderer, Android runtime, or network.
- The JSON schema validates the minimum save/state payload described by the
  vertical slice.
- Ownership rules identify one accountable owner for every contract surface and
  define how conflicts are resolved.
