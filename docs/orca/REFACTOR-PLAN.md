# Refactor plan: from one `WorldState` to a composed core

> **In short:** `game/scripts/core/world_state.gd` is 5,000 lines (2,700 of code, 2,000 of
> comments, 286 functions) and owns every piece of state plus every rule. The goal is a
> `WorldState` that is a thin façade over small, single-purpose modules, so new systems
> (layers, workshops, skills, thoughts, squads) plug in without touching the core. The
> behaviour, the save format and the test suite stay exactly as they are until the split is
> finished.

## Why now

The game already has the right pillars (deterministic core, commands + ticks, content with
schemas, versioned saves, headless tests). What it lacks is a core that can grow: every
feature so far ended in `world_state.gd` and an ADR raising its line budget (every ADR in
`docs/decisions/` whose title ends in "core budget increase"). The owner's goal is a game with far more
systems than today's; that cannot be built on a 5,000-line file.

## Non-negotiables during the refactor

1. **Behaviour-preserving.** Every `R*` task leaves `state_hash()` for every existing test
   scenario byte-identical, every event log identical, and every save fixture loading as
   before. No schema version bump unless a task says so explicitly (none planned).
2. **Public surface stays.** `WorldState.new(...)`, `apply()`, `tick()`, `preview()`, every
   `get_*` the viewer or tests use, `state_hash()`, `to_save_state()` / `from_save_state()`.
   Tests that reach into `_private` fields may be adapted to the new owner of that field in
   the same task; their assertions do not change.
3. **One module per task, in order.** Each task extracts one responsibility, moves the
   functions and the fields they own, replaces the body in `WorldState` with delegation,
   runs the full suite, and lowers `world_state.gd`'s cap in
   `docs/architecture/core-budgets.json` to its new size (never raises it).
4. **Modules are plain `RefCounted`, scene-free, with injected dependencies.** A module
   receives what it needs in `_init` (the content registry, a seeded RNG, the event sink, a
   sibling module) and never reaches back into `WorldState` by reference. If it needs a
   callback, it takes a `Callable`.
5. **Each module owns its persistence.** It exposes `encode() -> Dictionary` and
   `decode(data: Dictionary)` (or `restore(...)`) and `hash_into(ctx)`; `state_codec.gd`
   calls those instead of reading `world._field` directly. The resulting JSON must be
   identical to today's, field for field, so fixtures keep loading.
6. **Comments move with the code and get shorter.** The doc-comment essays in
   `world_state.gd` are history, not contract. Keep the *why* in one or two lines; the *how*
   is the code. Anything a future author must know goes into the module's class doc or an
   ADR.
7. **No new behaviour.** If an extraction reveals a bug, note it in the handoff report and
   file it as a separate backlog entry; do not fix it inside a refactor task.

## Target layout

```
game/scripts/core/
  world_state.gd            façade: construction, apply/tick/preview, state_hash, save glue  (< 900 lines)
  world/
    event_log.gd            R1  events, sequence numbers, ordering, queue event collection
    command_router.gd       R10 validate → dispatch → applied/rejection envelopes
    tick_pipeline.gd        R12 the ordered list of per-tick phases
  map/
    tile_grid.gd            R3  tiles, water cache, dirty cells, tile keys
    regions.gd  rooms.gd    (exist)
    passability.gd          R3  passable_for_* and faction/door rules
  objects/
    object_table.gd         R3  placed objects, footprints, origins, orientation, health, factions
    construction_site.gd    (exists)
    construction_system.gd  R5  sites, site fetch/work submission, enclosure check, finalize/cancel
    zone_table.gd           R3  zones + overlap queries
  items/
    item_table.gd           R2  ground items, berries, item factions, next id, spawn/remove/consume
    tool_item_store.gd      (exists, moves here)
  jobs/
    work_progress.gd        R4  work progress, owners, suspended progress
    toil_bindings.gd        R11 the `_toil_*` callbacks wired into ToilExecutor
  actors/
    needs_system.gd         R8  decay, interrupt/suspend/resume, need reasons, source candidates
    trench_system.gd        R6  traps, climb-out, escape jobs, rescue bookkeeping
    combat_system.gd        R9  apply_combat, death, inventory drop, scheduling cleanup
  economy/
    trade_system.gd         R7  trade offers, accept_trade
  commands/
    command_checks.gd       (exists)
    handlers/*.gd           R10 one file per command family (orders, construction, zones, actors, incidents)
```

Files that already have a home (`jobs/`, `scheduling/`, `routing/`, `incidents/`,
`calendar/`, `content/`, `persistence/`, `worldgen/`) stay where they are.

## Task sequence (details and acceptance in `BACKLOG.md`)

| Id | Extracts | Approx. functions leaving `world_state.gd` |
| --- | --- | --- |
| R0 | Tooling only: Windows test runner, `GODOT` env, a `tools/measure_core.ps1` that prints per-file code/comment line counts | 0 |
| R1 | `EventLog` | `_insert_event`, `_next_sequence`, `_event_less`, `_collect_queue_events`, `get_events`, `_applied`, `_rejection`, `_pure_rejection`, `_reject`, `_apply_noop` |
| R2 | `ItemTable` | `_item_lookup`, `_place_*_item`, `_remove_*_item*`, `_spawn_*_item`, `get_items`, `get_ground_wood`, `get_ground_berries*`, `_has_item_of_kind`, `_consume_carried_item_of_kind`, `_find_available_stockpiled_item`, `_remove_stockpiled_item_unit`, berries keys, `_dig_item_placement`, `_roll_dig_find`, `_resolve_dig_finds` |
| R3 | `TileGrid`, `ObjectTable`, `ZoneTable`, `Passability` | `get_tile(s)`, `_tile_*`, `_mark_dirty`, `get_dirty_cells`, `_get_water_tiles`, `_update_water_tile_cache`, `_get_regions`, `_get_rooms`, `get_room_at`, `_object_*`, `_set_object`, `_damage_object`, `get_object*`, `get_objects`, `is_cell_free`, `_is_cell_occupied`, `_is_bare_tile`, `get_zone(s)`, `_is_in_any_zone`, `_zone_overlaps`, `_is_passable`, `_passable_for_*`, `_faction_may_*`, `_colonist_may_*`, `passability`, `_region_reachable` |
| R4 | `WorkProgress` | every `*_work_progress*` function and the three progress maps |
| R5 | `ConstructionSystem` | every `_construction_*`, `_site_fetch*`, `_submit_site_*`, `_apply_construction_submission`, `_check_construction_command`, `_classify_build_line_command`, `_apply_build_line_command`, `_build_site_*`, `_finalize_construction_site`, `_cancel_construction_site`, `_release_site_builder`, `_would_enclose_tiles`, `_flood_fill_passable`, `get_construction_site(s)`, `_public_site_view` |
| R6 | `TrenchSystem` | `_check_trench_arrival`, `_actor_traps_on_trench`, `_trap_actor`, `_submit_trench_escape`, `_activate_pending_escapes`, `_trench_climb_ticks`, `_trench_exit_tile`, `_is_trench_tile`, `_escaping_actor_at`, `_rescue_*`, `_retire_rescue_job`, `_trapped_rescue_victims`, `get_colonist_rescue_reason` |
| R7 | `TradeSystem` | `_maybe_post_trade_offer`, `_post_trade_offer`, `_pick_trade_items`, `_apply_accept_trade_command`, `_append_trader_inventory_item`, `_remove_trader_offered_item`, `get_pending_trade_offers` |
| R8 | `NeedsSystem` | `_decay_needs`, `_pause_work_job`, `_resume_paused_job`, `_interrupt_current_job`, `_resume_interrupted_job`, `_set_need_reason`, `_emit_need_unmet_event`, `_need_*`, `_consume_source_valid`, `_apply_need_effect`, `_full_needs`, `_ensure_needs`, `get_colonist_need_reason`, `get_active_need_job_id` |
| R9 | `CombatSystem` | `_apply_combat`, `get_actor_combat_reason`, `_apply_actor_death`, `_cleanup_actor_scheduling`, `_cancel_job_for_death`, `_drop_inventory_*`, `_ensure_combat`, `_ensure_health`, `get_actors_with_health` |
| R10 | `CommandRouter` + handlers | `_validate_command`, every `_apply_*_command`, `_check_*_command`, `apply`, `preview` bodies |
| R11 | `ToilBindings` | every `_toil_*`, `_work_target_for`, `_resolve_giver_association`, `_tool_exists`, `_tool_requirement_for_kind`, `_drop_carried_*`, `_deposit_carried_item`, `_force_drop_carried_item`, `_terminate_haul_job_by_id` |
| R12 | `TickPipeline` + façade cleanup | `tick` body, `_advance_colonists`, `_colonists_not_*`, `_rescue_candidates`, `_committed_jobs`, `_scheduler_workers`; delete dead code; `world_state.gd` < 900 lines; budgets file rewritten as a flat 800-line cap for every core file |
| R13 | `boot.gd` split | scene composition vs. new-game setup vs. input wiring; `boot.gd` < 300 lines |

After R12, `docs/architecture/core-budgets.json` becomes a single rule ("no file under
`game/scripts/core/` above 800 lines; no function above 80") checked by CI, and the
"budget increase" ADRs are superseded by one ADR describing the composed core.

## How to do an extraction (the recipe every `R*` task follows)

1. `godot --headless --path game --import`, then run the full suite on the untouched branch
   and keep the output as the baseline (`tools\run_tests.ps1 > baseline.txt`).
2. Create the module file with its class doc, `_init` taking its dependencies, and the
   fields it will own. Move the functions **verbatim** first; change names only where the
   module's own naming makes the old name wrong.
3. In `WorldState`, replace each moved function with a one-line delegation, or delete it when
   no caller remains outside the module. Grep the whole repo for each removed name
   (`git grep "_function_name"`): callers in tests, givers, the codec and the viewer.
4. Move persistence: add `encode()`/`decode()` to the module, make `state_codec.gd` call
   them, and diff a saved game before/after (`test_save_migration.gd` and the fixtures must
   pass unchanged).
5. Make `state_hash()` delegate to the module for its fields (`hash_into`).
6. Run the full suite. Compare the per-test output with the baseline: identical PASS lines,
   no new warnings from Godot.
7. Lower the `world_state.gd` cap in `core-budgets.json` to the new line count (rounded up
   to the next 10) and add the new file to the budget list with an 800 cap.
8. Trim comments: a moved function keeps at most a 1–3 line *why*. If the essay documented an
   invariant, add it as an `assert` or a test instead.
9. Handoff report (AGENTS.md): list every moved function, every test file touched and why, the
   before/after line counts (`tools\measure_core.ps1`), and the suite result.

## What the reviewer checks (summary; full list in `REVIEW.md`)

- The diff is a move, not a rewrite: logic lines identical modulo renames and indentation.
- No module holds a reference to `WorldState`; dependencies are explicit.
- Save JSON and fixtures unchanged; `state_hash` coverage unchanged.
- Budgets lowered, never raised; no test disabled, skipped or weakened.
- The handoff report's numbers match `tools\measure_core.ps1`.
