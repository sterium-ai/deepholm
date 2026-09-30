# ADR 001: Deterministic game foundation

> **In short:** The game's rules run as plain, predictable code that can be tested on its own, separate from graphics and from any particular device.

- **Status:** accepted
- **Date:** 2026-09-10
- **Scope:** simulation core, presentation boundary, content

## Context

The game needs a maintainable implementation that can be tested independently
from Android, rendering, and any particular presentation layer.

## Decision

The game is an original Godot 4 project under `game/`. Authoritative
simulation code is plain, scene-independent GDScript. The simulation advances
through explicit ticks and seeded randomness, while presentation consumes
state/events through application boundaries.

Content is data-driven and versioned. Design research and playtest notes
remain evidence sources; they are not implementation dependencies.

## Consequences

- Headless deterministic tests can run without loading a scene.
- Godot scenes remain thin and less vulnerable to UID/resource corruption.
- New features must define contracts before changing shared surfaces.
- External assets and code cannot be added to the game without a
  separate rights review.

