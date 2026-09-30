# ADR 037: A colonist's single carrying slot becomes a 4-unit "hands" list

> **In short:** Colonists used to carry one thing at a time. They now have "hands" that hold up to four units, possibly of different kinds, so one trip can move a whole small stack.

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** simulation (`ActorInventory`, `ToilExecutor`, `WorldState`), persistence (save
  schema, migration), `docs/architecture/core-budgets.json`.

## Context

ADR 006 gave a colonist a single `carrying` field (`null`, or `{itemId, kind, count}`): one
ground item, moved whole or, in one caller (`_consume_build_cost`), shrunk before a partial
deposit. A haul or build job could therefore only move exactly the count of the single ground
item it picked up: never more, and never a second kind at once. This change lets a colonist carry
up to 4 units in total, of one or more kinds, so a single `pick_up` can take a whole 4-unit stack
instead of the scheduler needing a second job for units 2-4. It also lets a later change (ADR 038:
list-valued `build_cost` and multi-source, nearest-first fetching) gather from more than one
source without changing this schema or these toils again.

## Decision

**`hands` replaces `carrying`.** A colonist's `hands` field is a list of `{kind, count}`
entries: at most one entry per distinct kind held, every entry's `count >= 1`, and the sum of all
counts never exceeding `ActorInventory.HANDS_CAPACITY` (4). Unlike the single-slot field, `hands`
entries have no item id: a `pick_up` may merge units from a ground item into an existing
same-kind entry, and `place` always mints a fresh ground item id per entry it deposits, so no
entry could keep a stable id across a full pick-up/place cycle anyway. `ActorInventory`
(`game/scripts/core/actors/components/inventory.gd`) becomes the sole owner of this shape,
following the discipline ADR 012 established for the field it replaces:
`is_carrying`/`has_kind`/`count_of_kind` (read), `free_capacity` (capacity check),
`add_to_hands`/`remove_from_hands` (mutate), and `hands_snapshot`/`clear_hands` (bulk read/clear).
No caller indexes `hands` directly; the 13 former `InventoryType.carried_item()`/`set_carrying()`/
`consume_one_carried()`/`clear_carrying()` call sites in `world_state.gd`, and `toil_executor.gd`'s
`pick_up()`/`place()`, all move to this accessor set.

**`ToilExecutor.pick_up(colonist, item_id, count: int = -1)` gains a count parameter.** It
moves `min(requested_count, ground_item.count, hands_free_capacity)` units from the ground item
into hands (merging into an existing same-kind entry via `add_to_hands`) and decrements the
ground item's count (removing it at 0, as before). `count < 0` (the default, which every existing
single-unit caller and `HaulGiver`'s no-count `pick_up` call still pass) requests the whole ground
stack and lets the free-capacity clamp decide how much moves. This is what makes a 4-unit stack
move in one call and a 6-unit stack leave 2 behind after one `pick_up` of 4, with no job-giver
change: `HaulGiver.advance()`'s existing per-tick re-scan of unclaimed ground items already
resubmits a fresh haul job for the remainder. `pick_up` still fails with the typed
`REASON_ITEM_OUT_OF_REACH`/`REASON_ITEM_NOT_FOUND` reasons. `REASON_ALREADY_CARRYING` is retired
(multiple kinds and partial fills are now legal) and replaced by `REASON_HANDS_FULL`, returned
when free capacity is already 0. Non-positive explicit counts are rejected as a no-op, so they can
never create a zero-count hands entry.

**`ToilExecutor.place(colonist, cell)` deposits every hands entry in one call:** one fresh
ground item per distinct kind held (`hands_snapshot()`, each minted through the injected
`place_item` callable from `WorldState._next_item_id`), then `clear_hands()`. A caller that needs
a *partial* deposit removes the unwanted portion through the hands accessors first, as
`_consume_build_cost` already did by shrinking `carrying['count']` before depositing the
remainder. It now calls `InventoryType.remove_from_hands(builder, cost.item, cost.quantity)`
followed by the same `_deposit_carried_item()` call, which is a no-op once hands are empty and
otherwise deposits whatever is left (the cost item's remainder or, once mixed kinds occur, any
other kind still held).

**Every `world_state.gd` caller is updated, with unchanged behaviour at count 1.**
`_drop_carried_item_from`, `_deposit_carried_item`, `_force_drop_carried_item`, and
`_drop_carried_haul_item` now deposit everything in hands (`place()` already does this;
`_force_drop_carried_item`'s unconditional fallback path now iterates `hands_snapshot()` instead
of a single entry). `_consume_carried_item_of_kind` (sow's seed-consumption fallback) removes one
unit of the named kind and fails the owning haul job only once that kind's last unit is gone,
which generalizes correctly to mixed-kind hands (not exercised by this change's tests, which stay
single-kind because the four buildable kinds each cost 1 wood). `_build_completion_failure` and
`_consume_build_cost` check and spend the declared quantity of the declared kind via
`count_of_kind`/`remove_from_hands`, never the whole hand. `build_cost` itself stays a single
`{item, quantity}` object in this change (ADR 038 makes it a list).

**`get_colonists()` gains a derived, presentation-only `carrying` mirror.** The viewer layer
(`colonist_sprites.gd`'s cargo badge, `colonist_panel.gd`'s toil inference, `map_view.gd`'s
colour-mode marker) reads a colonist's `carrying` key directly, and all three obtain colonist
dicts through `WorldState.get_colonists()`. Rather than change the viewer in the same step,
`get_colonists()` (already a detached `actor.duplicate(true)` copy, per ADR 012's "same shape
callers have always seen" comment) adds a `carrying` key derived from `hands` via
`InventoryType.is_carrying()`/`hands_snapshot()`: `null` when hands are empty, otherwise
`{kind, count}` of the first hands entry. The key exists only on `get_colonists()`'s copies, never
on `_colonists` itself, so it is invisible to `state_hash()`, encode/decode, and
`test_actor_field_lint.gd` (which scans `core/`, not `viewer/`, and does not protect
`hands`/`carrying`, per its doc comment). It reflects only the first held kind, which matches the
single-kind hands this change produces; true multi-kind rendering is left to a later viewer change.

**`ActorTable.spawn()` (`game/scripts/core/actors/actor_table.gd`) is left unchanged** and still
builds `{"carrying": null, ...}` for a freshly spawned colonist. `WorldState._spawn_colonists()`
replaces that key with `hands: []` immediately after `ActorTable.spawn()` returns, the same way it
already appends `trapped: null` after spawning. This is safe for determinism: `state_hash()` hashes
`JSON.stringify(_colonists)`, and Godot's `JSON.stringify()` serializes a Dictionary's keys in
sorted order, not insertion order. This was verified empirically: a freshly spawned colonist and
the same colonist restored from a save already produced byte-identical JSON before this change,
even though their two constructors build the dict in different field orders.

**Schema and migration.** `docs/architecture/contracts/game-state.schema.json`'s `$defs/carrying`
becomes `$defs/handsEntry` (`{kind, count}`, `count` 1-4), and a colonist's `hands` (required,
replacing `carrying` in the colonist `allOf`) is an array of at most 4 such entries.
`StateCodec._encode_carrying_field`/`_decode_carrying_field` become `_encode_hands_field`/
`_decode_hands_field` over the list, and the colonist encode/decode call sites follow.
`SaveIO`'s `_valid_entity_carrying` becomes `_valid_entity_hands` (array, no duplicate kinds,
every count >= 1, sum <= `ActorInventory.HANDS_CAPACITY`), and both `entity` allowed-key lists
(the top-level scan and `ENTITY_COMPONENT_FIELDS`) swap `carrying` for `hands`.
`StateCodecType.SCHEMA_VERSION` goes from 24 to 25 (read live, never hardcoded in code or tests).
`SaveMigrations` gains `_migrate_v24_to_v25`: a `null` `carrying` becomes an empty `hands` array,
and a populated one becomes a one-entry `hands` array with its `kind` and `count` (the item id is
dropped, since hands entries have none). `_is_schema_v24_state`'s allowed and required top-level
key lists mirror `SaveIO._validate_state()`'s `top_level`/`optional_top_level` rather than
`_is_schema_v23_state`'s narrower list, which predates several optional fields (such as
`rescueVictimAssignments` and `workProgressOwners`) that a real v24 save always carries.

**Core budgets.** `world_state.gd` moves from 3970 to 4015 (+45): the accessor call-site rewrites
and `pick_up`/`place`'s expanded doc comments and multi-entry loops (+29), plus `get_colonists()`'s
`carrying` compatibility mirror and its doc comment (+16). `toil_executor.gd` moves from 836 to 860
(+24): +18 for the hands changes and +6 for rejecting non-positive `pick_up` counts. `job_queue.gd`
is unchanged (no toil, reservation, or scheduling change was needed for hands) and keeps its
budget.

## Alternatives considered

- **Keep per-item ids in hands entries, merging counts only when both kind and id match.**
  Rejected: a pick-up spanning more than one ground item of the same kind (a 6-unit stack picked
  up in two visits, or two adjacent stacks) would need one hands entry to reference several ids,
  defeating the flat `{kind, count}` shape; nothing downstream (place, build-cost consumption,
  sow) ever needs the original id.
- **Make `pick_up`'s `count` parameter required instead of defaulting to `-1` ("take all you
  can").** Rejected: dig, chop, and forage never call `pick_up`, and haul's `item_id_for` hook has
  no natural "requested count", since `HaulGiver` submits one job per ground item rather than per
  desired quantity. Every call site would need a new hook just to say "take the whole stack",
  which the default already expresses with no new `ToilExecutor` surface.
- **Change `actor_table.gd` to build `hands: []` directly.** ADR 012's "components are an
  accessor layer over existing fields, not a literal nested key" section would allow it. Not done
  in this change, which kept `actor_table.gd` untouched; the post-spawn key swap in
  `world_state.gd` produces the identical live shape.

## Consequences

- `docs/architecture/contracts/game-state.schema.json`: the `schemaVersion` const is `25`, and
  `hands` replaces `carrying` as a colonist's required field.
- `docs/architecture/save-system.md` documents `hands` and the v24 to v25 migration.
- `test_items_pick_up_place.gd` gains 4-unit, 6-unit, and hands-full coverage. Every existing
  hands/carrying assertion in `test_haul_need_interrupt.gd`, `test_haul_stockpile.gd`, and
  `test_build.gd` moves to the new accessors without changing what it proves.
- `test_save_migration.gd` gains a schemaVersion-24 fixture (one entity carrying nothing and one
  carrying an item) proving the v24 to v25 step.
