# ADR 035: A colonist's single carrying slot becomes a 4-unit "hands" list

- **Status:** accepted
- **Date:** 2026-09-25
- **Scope:** simulation (`ActorInventory`, `ToilExecutor`, `WorldState`), persistence (save
  schema, migration), `docs/architecture/core-budgets.json`
- **Implements:** issue #402 (t1 of a two-task split; t2 owns `build_cost` becoming a list and
  multi-source/nearest fetch logic, both explicitly out of scope here).

## Context

ADR 006 gave a colonist a single `carrying` field (`null`, or `{itemId, kind, count}`): one
ground item, moved whole or shrunk by one caller (`_consume_build_cost`) before a partial
deposit. A haul or build job could therefore only ever move exactly the count of whichever
single ground item it picked up -- never more, never a second kind at once. Issue #402 asks
for a colonist to carry up to 4 units total, of one or more kinds, so a single `pick_up` can
already take a whole 4-unit stack instead of the scheduler needing a second job for units 2-4,
and t2 can later let a haul job gather from more than one source without this task's own
schema/toil changes moving again.

## Decision

**`hands` replaces `carrying`.** A colonist's `hands` field is a list of `{kind, count}`
entries: at most one entry per distinct kind actually held, every entry's `count >= 1`, the
sum of every entry's `count` never exceeding `ActorInventory.HANDS_CAPACITY` (4). Unlike the
single-slot field, `hands` has no item id of its own -- a `pick_up` may merge units from a
ground item into an existing same-kind entry, and `place` always mints a fresh ground item id
per entry it deposits, so no entry could keep a stable id across a full pick_up/place round
trip anyway. `ActorInventory` (`game/scripts/core/actors/components/inventory.gd`) becomes
the sole owner of this shape, mirroring the discipline ADR 012 already established for the
field it replaces: `is_carrying`/`has_kind`/`count_of_kind` (read), `free_capacity` (capacity
check), `add_to_hands`/`remove_from_hands` (mutate), `hands_snapshot`/`clear_hands` (bulk
read/clear). No caller indexes `hands` directly; `world_state.gd`'s 13 former
`InventoryType.carried_item()`/`set_carrying()`/`consume_one_carried()`/`clear_carrying()` call
sites and `toil_executor.gd`'s `pick_up()`/`place()` all move to this accessor set.

**`ToilExecutor.pick_up(colonist, item_id, count: int = -1)` gains a count parameter.** It
moves `min(requested_count, ground_item.count, hands_free_capacity)` units from the ground item
into hands (merging into an existing same-kind entry via `add_to_hands`), decrementing the
ground item's own count (removed entirely at 0, exactly as before). `count < 0` (the default,
and what every existing single-unit caller and `HaulGiver`'s own no-count `pick_up` call still
pass) requests the whole ground stack, letting the free-capacity clamp alone decide how much
actually moves -- this is what makes a 4-unit stack move in one call and a 6-unit stack leave 2
behind after one `pick_up` of 4, with no job-giver change (`HaulGiver.advance()`'s existing
per-tick re-scan of unclaimed ground items already resubmits a fresh haul job for whatever
remains). `pick_up` still fails typed `REASON_ITEM_OUT_OF_REACH`/`REASON_ITEM_NOT_FOUND` as
before; `REASON_ALREADY_CARRYING` is retired (multiple kinds and partial fills are now legal)
and replaced by `REASON_HANDS_FULL`, returned when free capacity is already 0.

**`ToilExecutor.place(colonist, cell)` deposits every hands entry in one call.** One fresh
ground item per distinct kind held (`hands_snapshot()`, each minted through the injected
`place_item` callable off `WorldState._next_item_id`), then `clear_hands()`. A caller that
needs a *partial* deposit removes the unwanted portion via the hands accessors first, exactly
as `_consume_build_cost` already did today by shrinking `carrying['count']` before depositing
the remainder -- now `InventoryType.remove_from_hands(builder, cost.item, cost.quantity)`
followed by the same `_deposit_carried_item()` call, which is a no-op once hands are empty and
otherwise deposits whatever is left (the cost item's own remainder, or -- once t2 allows mixed
kinds -- any other kind still held).

**Every `world_state.gd` caller updated, same behavior at count 1.** `_drop_carried_item_from`/
`_deposit_carried_item`/`_force_drop_carried_item`/`_drop_carried_haul_item` now deposit
everything currently in hands (place() already does this; `_force_drop_carried_item`'s own
unconditional-fallback path now iterates `hands_snapshot()` instead of a single entry).
`_consume_carried_item_of_kind` (sow's seed-consumption fallback) removes one unit of the named
kind from hands and fails the owning haul job only once that kind's last unit is gone --
generalizing correctly for a future mixed-kind hand (not exercised by this task's own tests,
which stay single-kind per the four buildable kinds' own 1-wood cost). `_build_completion_failure`/
`_consume_build_cost` check/spend the declared quantity of the declared kind specifically via
`count_of_kind`/`remove_from_hands`, never the whole hand. `build_cost` itself stays today's
single `{item, quantity}` object (t2's own scope).

**`get_colonists()` grows a derived `carrying` mirror, presentation-only.** The unowned viewer
layer (`colonist_sprites.gd`'s cargo badge, `colonist_panel.gd`'s toil inference, `map_view.gd`'s
colour-mode marker -- all t3's own task per Non-goals) reads a colonist's `carrying` key
directly, and all three obtain their colonist dicts through `WorldState.get_colonists()`.
Rather than edit those out-of-scope files, `get_colonists()` (already a detached
`actor.duplicate(true)` copy per ADR 012's "same shape callers have always seen" comment) adds a
`carrying` key derived from `hands` via `InventoryType.is_carrying()`/`hands_snapshot()`: `null`
when hands are empty, else `{kind, count}` of the first hands entry. This key exists only on
`get_colonists()`'s own copies -- never on `_colonists` itself, so it is invisible to
`state_hash()`, encode/decode, and `test_actor_field_lint.gd` (which scans `core/`, not
`viewer/`, and does not protect `hands`/`carrying` per its own doc comment). It reflects only the
first held kind, which is exactly today's behavior for this task's own single-kind hands; t3
picks up true multi-kind rendering when it touches the viewer layer.

**`ActorTable.spawn()` (`game/scripts/core/actors/actor_table.gd`) is not owned by this task**
and still literally builds `{"carrying": null, ...}` for a freshly spawned colonist. Rather than
edit a file outside this task's ownership, `WorldState._spawn_colonists()` (owned) replaces that
key with `hands: []` immediately after `ActorTable.spawn()` returns, the same way it already
appends `trapped: null` post-spawn. This is safe: `state_hash()` hashes `JSON.stringify(_colonists)`,
and Godot's `JSON.stringify()` serializes a Dictionary's keys in sorted order, not insertion
order (verified empirically -- a fresh-spawned colonist and the same colonist restored from a
save produce byte-identical JSON despite their two constructors building the dict in different
field orders already, before this change), so the erase-then-assign carries no insertion-order
risk to determinism.

**Schema and migration.** `docs/architecture/contracts/game-state.schema.json`'s `$defs/carrying`
becomes `$defs/handsEntry` (`{kind, count}`, `count` 1-4), and a colonist's `hands` (required,
replacing `carrying` in the colonist `allOf`) is an array of at most 4 such entries.
`StateCodec._encode_carrying_field`/`_decode_carrying_field` become `_encode_hands_field`/
`_decode_hands_field` over the list; the colonist encode/decode call sites follow.
`SaveIO`'s `_valid_entity_carrying` becomes `_valid_entity_hands` (array, no duplicate kinds,
every count >= 1, sum <= `ActorInventory.HANDS_CAPACITY`), and both `entity` allowed-key lists
(top-level scan and `ENTITY_COMPONENT_FIELDS`) swap `carrying` for `hands`.
`StateCodecType.SCHEMA_VERSION` bumps 24 -> 25 (read live, never hardcoded in this task or its
tests). `SaveMigrations` gains `_migrate_v24_to_v25`: a `null` `carrying` becomes an empty
`hands` array, a populated one becomes a one-entry `hands` array carrying its own `kind`/`count`
(the item id is dropped -- a hands entry never had one). `_is_schema_v24_state`'s allowed/
required top-level key lists mirror `SaveIO._validate_state()`'s own `top_level`/
`optional_top_level` (not `_is_schema_v23_state`'s narrower list, which predates several
now-optional fields such as `rescueVictimAssignments`/`workProgressOwners` that a real v24 save
already always carries).

**Core budgets.** `world_state.gd` moves 3970 -> 4015 (+45): the accessor-call-site rewrites and
`pick_up`/`place`'s expanded doc comments and multi-entry loops (+29), plus `get_colonists()`'s
`carrying` compatibility mirror and its doc comment (+16). `toil_executor.gd` moves 836 -> 860
(+24): the initial +18, plus a review-round fix (+6) rejecting non-positive `pick_up` counts as a
no-op before they can create a zero-count hands entry. `job_queue.gd` is untouched by this task
(no toil, reservation, or scheduling change was needed for hands) and keeps its existing budget.

## Alternatives considered

- **Keep per-item ids in hands entries, merging counts only when kinds AND ids match.**
  Rejected: a pick_up that spans more than one ground item of the same kind (a 6-unit stack
  picked up in two visits, or two adjacent stacks) would need a hands entry to reference
  multiple ids, defeating the point of a flat `{kind, count}` shape; nothing downstream (place,
  build-cost consumption, sow) ever needed the original id back.
- **Give `pick_up` a required `count` parameter instead of a `-1` "take everything you can"
  default.** Rejected: every existing call site (dig/chop/forage never call it; haul's own
  `item_id_for` hook has no natural per-job "requested count" concept since `HaulGiver` submits
  one job per ground item, not per desired quantity) would need a new hook purely to say
  "take the whole stack," which the default already expresses with no new `ToilExecutor`
  surface.
- **Edit `actor_table.gd` to build `hands: []` directly, since ADR 012's own "components are an
  accessor layer over existing fields, not a literal nested key" section already treats a
  colonist's field set as something this ADR-family owns.** Rejected: `actor_table.gd` is not
  in this task's `Owned paths`; per-task ownership takes precedence over an earlier ADR's own
  scope note, and the post-spawn key swap in `world_state.gd` achieves the identical live shape.

## Consequences

- `docs/architecture/contracts/game-state.schema.json`: `schemaVersion` const is `25`;
  `hands` replaces `carrying` as a colonist's required field.
- `docs/architecture/save-system.md` documents `hands` and the v24->v25 migration.
- `test_items_pick_up_place.gd` gains the 4-unit/6-unit/hands-full coverage; every existing
  hands/carrying-shaped assertion across `test_haul_need_interrupt.gd`, `test_haul_stockpile.gd`,
  and `test_build.gd` moves to the new accessors without changing what it proves.
- `test_save_migration.gd` gains a schemaVersion-24 fixture (a null-carrying and a
  populated-carrying entity) proving the v24->v25 step.
