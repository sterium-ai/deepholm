# Vision and principles

## Product vision

Deepholm is a calm-but-consequential underground colony simulation. The
player turns a dangerous layered cave into a functioning settlement by issuing
priorities, allocating scarce resources, and responding to emergent problems.
The game keeps the genre's pillars—digging, construction, colonists,
needs, production, farming, and defense—while making the simulation testable,
data-driven, and extensible.

## Product promise

Every order should create a visible chain of consequences: a dig exposes space,
space enables a room, the room changes needs and production, and production
improves the colony's ability to survive the next constraint.

## Non-goals for the first release

- Shipping monetization, ad, identity, or analytics integrations.
- Supporting every item, enemy, language, or workshop before the core
  loop is fun and stable.
- Allowing arbitrary scripting inside save files or content packs.

## Engineering principles

1. **Simulation first.** Rules live in a headless core and are covered by
   deterministic tests.
2. **Commands in, events out.** Presentation requests changes through validated
   commands and reacts to domain events.
3. **Data over class proliferation.** Items, buildings, recipes, jobs, and
   tuning are content records, not one class per variant.
4. **Explicit uncertainty.** Observations inferred from research or playtests are marked as
   evidence, never treated as requirements without a product decision.
5. **Small vertical increments.** Each slice must be playable, saveable, and
   diagnosable before adding breadth.
6. **Stable identity.** Entity and content IDs are opaque to presentation and
   remain stable across migrations.
