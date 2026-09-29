# Vertical slice contract

The first playable slice proves the colony loop on one finite map. It is the
minimum implementation target; everything outside this list is deferred.
The slice's visual direction is documented in [docs/art/style.md](../art/style.md).

## Included

- One generated or hand-authored two-dimensional, tile-based map with solid
  rock, diggable soil, walkable floor, and one blocked hazard tile.
- One player-controlled colony with one colonist.
- Camera, tile selection, pause, single-step, and simulation speed controls.
- A dig command that validates targets, creates a job, finds a route, and
  converts diggable terrain into walkable floor.
- A priority-based task queue with cancellation and clear failure reasons.
  Selection and route work run on deterministic, bounded per-tick budgets
  with a declared maximum service wait (in ticks) and an explicit fairness
  policy for lower priorities, per [ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md).
- Inventory containing a small set of resource IDs: soil, stone, food, and wood.
- One construction action for a floor and one for a bed; construction consumes
  resources and occupies a tile.
- Hunger, sleep, and health needs with visible state changes.
- One workshop and one recipe that consume inputs and create an output.
- Save, load, and migration from the current schema version.
- Minimal UI for map state, selected entity, pending jobs, inventory, and errors.

## Excluded

Combat, farming growth, animals, multi-level travel, relationships, research,
campaign progression, multiplayer, mods, ads, purchases, cloud saves, and
external services. They may be represented as future extension points but must
not be required by the slice.

## Acceptance criteria

- A fresh run reaches a playable map with one colonist and the four resource IDs.
- Issuing a valid dig order eventually changes the target tile and emits a
  completion event; an invalid or blocked order emits a typed failure event.
  Every rejected, blocked, interrupted, or cancelled order, and every
  colonist transition to idle, exposes its actual reason and, where
  applicable, a remedy through core state or an ordered domain event, per
  [ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md).
- The colonist cannot occupy blocked terrain and never spends resources for a
  failed construction.
- Hunger and sleep change from simulation ticks alone and health never leaves its
  declared bounds.
- The recipe cannot complete without inputs and produces exactly its declared
  output once.
- Saving and loading at the same tick produces equivalent simulation state,
  excluding transient UI state. A validated snapshot replaces the active
  save only after validation succeeds, the last known-good save is
  preserved until then, and a failed write or load leaves the prior save
  and live state intact with a visible, typed error, per
  [ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md).
- A fixed seed plus the same command sequence produces the same state hash.
- The headless simulation runs without graphics, Android, audio, or network
  dependencies.
- On the smallest supported mobile screen and UI scale, camera gestures are
  distinguishable from order gestures, an area order can be previewed and
  cancelled before it commits, critical status and failure reasons remain
  readable with no hover-only actions, and backgrounding the app submits no
  further simulation ticks, per
  [ADR 003](../decisions/003-scheduling-explainability-save-integrity-mobile-first.md).
