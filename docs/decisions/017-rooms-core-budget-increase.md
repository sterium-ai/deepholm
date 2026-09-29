# ADR 017: Rooms wiring raises the world_state.gd core budget

- **Status:** accepted
- **Date:** 2026-09-20
- **Scope:** `docs/architecture/core-budgets.json` cap for `game/scripts/core/world_state.gd`.
- **Implements:** F5 in `docs/architecture/foundation-for-breadth.md`; issue #293.

## Decision

Wiring `RoomMap` (`game/scripts/core/map/rooms.gd`) into `world_state.gd` raises its
`core-budgets.json` cap: 1855 -> 1877. `WorldState` owns a lazily-built `RoomMap` (mirroring
`RegionMap`'s own lazy field from ADR 016, so a save/load's direct `_tiles`/`_objects`
overwrite in `state_codec.gd` never leaves it stale), calls `on_passability_changed()` from
the same two mutation sites `RegionMap` already hooks (`_set_object()`,
`_toil_on_work_complete()`), exposes the read-only `get_room_at()` lookup Presentation
(`boot.gd`) reads, and scales a completed sleep job's `restore` by
`needs.json`'s `bedroom_rest_multiplier` in `_apply_need_effect()` when the bed's tile is
inside a recognised bedroom.

All of this is orchestration — a field, a lazy accessor built from callables `WorldState`
already exposes (`passability()`, `get_object()`, and the existing `_is_in_any_zone()`
helper reused as-is for the `has_stockpile` predicate, so no new zone-overlap loop was added
here), two call-sites at the passability mutation points `RegionMap` already hooks, and one
conditional multiplier inside the single function `docs/architecture/orders-and-movement.md`
("Need jobs" -> "On completion") names as the need-effect site — not new decision logic. None
of it fits the toil executor, a job-giver module, or content: `RoomMap` itself (the actual
enclosure/bedroom/storeroom logic) already lives in `game/scripts/core/map/rooms.gd`, same
as `RegionMap`; only the wiring that must live where the mutations and the need-effect
function already live raises the cap.

## Consequences

The cap now equals the file's exact post-change line count, matching every prior
`core-budgets.json` entry (including the cap ADR 016 set, which this change increases
further). No other core file's budget changes; the toil executor and scheduler are untouched
by this task.
