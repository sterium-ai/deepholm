extends SceneTree

## Covers issue #213: axe/pick tool items and their persistence.
## content/items.json declares axe and pick as kind "tool"; content/jobs.json's
## dig/chop declare needs_tool; WorldState gains identity-bearing tool item
## storage (ground/held/stockpile location) plus an item reservation map
## (colonist-ai.md 3.4's "no reservation outlives its job" invariant, reused
## via reservation_invariants.gd). Issue #271 added the fetch_tool toil itself
## (colonist-ai.md 2/3.3): see _check_fetch_tool_success_frees_no_travel() and
## _check_blocked_no_tool_frees_colonist_for_other_work() below. Issue #266
## added drop_tool and the foreign-reservation handover wait
## (_check_foreign_reservation_triggers_drop_tool_handover()) and the
## destroyed-mid-job failure path
## (_check_destroyed_tool_fails_job_and_requeues_with_backoff()).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveMigrationsType = preload("res://scripts/core/persistence/save_migrations.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const ITEMS_CONTENT_PATH := "res://content/items.json"
const JOBS_CONTENT_PATH := "res://content/jobs.json"
const SAVE_IO_TEST_PATH := "user://test-tool-items-save-io.json"

var _failed := false

func _init() -> void:
	_check_items_content_declares_axe_and_pick()
	_check_jobs_content_declares_needs_tool()
	_check_fresh_colonist_held_tool_empty()
	_check_ground_tool_item_and_state_hash()
	_check_reservation_lifecycle_all_terminal_paths()
	_check_reservation_released_on_real_job_commands()
	_check_reservation_released_on_natural_completion()
	_check_reservation_invariant_no_leftover_on_terminal_job()
	_check_held_and_stockpile_locations()
	_check_held_tool_conflict_is_rejected()
	_check_spawn_ground_tool_item_rejects_non_tool_kind()
	_check_save_round_trip()
	_check_save_io_rejects_extra_toolitems_field()
	_check_dropping_a_reserved_tool_releases_its_reservation()
	_check_fetch_tool_success_frees_no_travel()
	_check_blocked_no_tool_frees_colonist_for_other_work()
	_check_held_tool_reuse_respects_other_jobs_reservation()
	_check_need_interrupt_releases_and_reacquires_held_tool()
	_check_fetch_tool_skips_unreachable_candidate_for_farther_one()
	_check_fetch_tool_does_not_chain_multiple_candidates_in_one_tick()
	_check_rejected_complete_job_preserves_tool_block_recovery()
	_check_interrupted_job_refetches_and_works_at_job_target_not_tool_location()
	_check_blocked_no_tool_respects_labour_disabled()
	_check_blocked_no_tool_permanently_unreachable_tool_backs_off_and_frees_colonist()
	_check_blocked_no_tool_reason_survives_backoff_window()
	_check_blocked_no_tool_failure_frees_job_for_a_different_colonist()
	_check_save_io_round_trip_after_candidate_excluded()
	_check_v10_migration_to_v11()
	_check_held_tool_skips_fetch_tool_travel()
	_check_foreign_reservation_triggers_drop_tool_handover()
	_check_drop_tool_prefers_nearby_stockpile_cell()
	_check_destroyed_tool_fails_job_and_requeues_with_backoff()
	_check_requester_waits_for_real_handover_then_completes()
	_check_destroyed_tool_during_fetch_travel_fails_and_backs_off()
	_check_drop_tool_revalidates_destination_at_arrival()
	_check_save_io_round_trip_mid_drop_tool_movement_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_drop_tool_route_search_matches_uninterrupted_run()
	_check_adjacent_busy_holder_does_not_steal_tool_same_tick()
	_check_fetch_tool_retargets_when_holder_drops_tool_elsewhere()
	_check_ordinary_route_not_misclassified_as_drop_when_reservation_appears_midflight()
	_check_fetch_route_not_misclassified_as_drop_when_other_reservation_appears()
	_check_requester_cancellation_midflight_still_completes_drop_correctly()
	_check_drop_continues_when_holders_own_next_job_needs_a_different_tool()
	_check_fetch_route_not_misclassified_as_drop_when_leftover_tool_also_foreign_reserved()
	_check_drop_cell_adjacent_to_impassable_ordinary_target_uses_nearest_stockpile_cell()
	_check_drop_cell_exactly_on_passable_ordinary_target_is_used()
	_check_drop_cell_near_passable_ordinary_target_uses_nearest_stockpile_cell()
	_check_destroyed_tool_among_multiple_reservations_not_first_and_unrelated_held_tool_preserved()
	_check_destroyed_fetch_target_preserves_unrelated_held_tool()
	_check_fetch_route_survives_impassable_fetch_destination_trim()
	_check_fetch_route_survives_drifting_handover_holder_while_requester_holds_leftover()
	_check_save_io_round_trip_mid_drop_tool_search_impassable_target_between_holder_and_stockpile()
	_check_drop_tool_skips_cell_already_occupied_by_another_tool()
	_check_drop_tool_falls_back_to_ground_when_destination_zone_removed_midflight()
	_check_save_io_round_trip_after_requester_cancellation_midflight()
	_check_save_io_round_trip_in_reservation_release_gap_with_unrelated_foreign_reserved_held_tool()
	_check_save_io_round_trip_ordinary_route_after_held_tool_foreign_reserved_midflight()
	_check_drop_tool_during_haul_job_preserves_cargo_identity_in_place()
	_check_drop_tool_during_haul_job_preserves_cargo_identity_via_stockpile()
	_check_save_io_round_trip_mid_drop_during_haul_job_preserves_cargo_and_completes()
	_check_destroyed_foreign_held_tool_while_waiting_reconciles_holder()
	_check_destroyed_foreign_held_tool_mid_drop_reconciles_holder_route()

	if _failed:
		quit(1)
		return
	print("test_tool_items: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## game/content/items.json must declare an 'axe' and a 'pick' entry, both
## kind 'tool'.
func _check_items_content_declares_axe_and_pick() -> void:
	var file := FileAccess.open(ITEMS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_expect(false, "could not open %s" % ITEMS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("items")) != TYPE_ARRAY:
		_expect(false, "%s must contain a top-level 'items' array" % ITEMS_CONTENT_PATH)
		return
	var by_id: Dictionary = {}
	for entry in parsed["items"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("id")) == TYPE_STRING:
			by_id[entry["id"]] = entry
	_expect(by_id.get("axe", {}).get("kind") == "tool", "items.json must declare 'axe' with kind 'tool'")
	_expect(by_id.get("pick", {}).get("kind") == "tool", "items.json must declare 'pick' with kind 'tool'")

## game/content/jobs.json's 'dig' entry must declare needs_tool 'pick' and
## 'chop' must declare needs_tool 'axe'.
func _check_jobs_content_declares_needs_tool() -> void:
	var file := FileAccess.open(JOBS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_expect(false, "could not open %s" % JOBS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("jobs")) != TYPE_ARRAY:
		_expect(false, "%s must contain a top-level 'jobs' array" % JOBS_CONTENT_PATH)
		return
	var by_kind: Dictionary = {}
	for entry in parsed["jobs"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("kind")) == TYPE_STRING:
			by_kind[entry["kind"]] = entry
	_expect(by_kind.get("dig", {}).get("needs_tool") == "pick", "jobs.json's dig must declare needs_tool 'pick'")
	_expect(by_kind.get("chop", {}).get("needs_tool") == "axe", "jobs.json's chop must declare needs_tool 'axe'")

## A freshly spawned colonist's held_tool must be "" (empty).
func _check_fresh_colonist_held_tool_empty() -> void:
	var world := WorldStateType.new(20260919)
	var colonists := world.get_colonists()
	_expect(colonists.size() > 0, "a fresh world must spawn at least one colonist")
	for colonist in colonists:
		_expect(String(colonist.get("held_tool", "MISSING")) == "",
			"a freshly spawned colonist's held_tool must be empty, got '%s'" % colonist.get("held_tool"))

## Adding a ground tool item and reserving it by job id must change
## state_hash().
func _check_ground_tool_item_and_state_hash() -> void:
	var world := WorldStateType.new(20260919)
	var hash_before_spawn := world.state_hash()
	var item_id := world.spawn_ground_tool_item("axe", 5, 5)
	_expect(item_id != "", "spawn_ground_tool_item must return a non-empty id")
	_expect(world.state_hash() != hash_before_spawn, "spawning a ground tool item must change state_hash()")

	var item := world.get_tool_item(item_id)
	_expect(item.get("kind") == "axe", "spawned tool item must record kind 'axe'")
	_expect(item.get("location", {}).get("type") == "ground", "a freshly spawned tool item must be on the ground")
	_expect(item.get("location", {}).get("x") == 5 and item.get("location", {}).get("y") == 5,
		"a freshly spawned tool item's location must match spawn coordinates")

	var hash_before_reserve := world.state_hash()
	_expect(world.reserve_tool_item(item_id, "job_1"), "reserving a free tool item must succeed")
	_expect(world.state_hash() != hash_before_reserve, "reserving a tool item must change state_hash()")
	_expect(not world.reserve_tool_item(item_id, "job_2"),
		"reserving a tool item already held by another job must fail")
	_expect(world.get_tool_item_reservation(item_id) == "job_1", "item must still be reserved by job_1")

## Releasing the reservation on job completion, cancellation, failure and
## invalidation must remove it from the reservation map on every path.
func _check_reservation_lifecycle_all_terminal_paths() -> void:
	var world := WorldStateType.new(20260919)
	var item_id := world.spawn_ground_tool_item("pick", 1, 1)
	var terminal_paths := ["job_complete", "job_cancel", "job_fail", "job_invalidate"]
	for job_id in terminal_paths:
		_expect(world.reserve_tool_item(item_id, job_id),
			"reserving a free tool item for '%s' must succeed" % job_id)
		_expect(world.is_tool_item_reserved(item_id), "item must be reserved before release ('%s')" % job_id)
		_expect(world.release_tool_item_reservation(item_id, job_id),
			"releasing the reservation on '%s' must succeed" % job_id)
		_expect(not world.is_tool_item_reserved(item_id),
			"item must be unreserved after '%s' releases it" % job_id)
		_expect(world.get_tool_item_reservation(item_id) == "",
			"reservation map must have no owner for '%s' after release" % job_id)
	# A job may never release a reservation it does not own.
	_expect(world.reserve_tool_item(item_id, "job_owner"), "reserving for job_owner must succeed")
	_expect(not world.release_tool_item_reservation(item_id, "job_impostor"),
		"a job must not be able to release another job's reservation")
	_expect(world.get_tool_item_reservation(item_id) == "job_owner",
		"the rightful owner's reservation must survive an impostor's release attempt")

func _command(world: WorldStateType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

## A 4x1 soil corridor with one colonist at its near end and a dig target two
## tiles away: enough for the scheduler to assign and activate a real dig job
## after a single tick(), without letting it run to natural completion.
func _build_single_dig_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 4):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	return world

## Reservations must be released the instant WorldState itself finishes a
## job, not only when a caller happens to call release_tool_item_reservation()
## directly (that only proves the primitive works, not that WorldState's own
## terminal transitions call it). Drives a real dig job through each of
## complete_job/cancel_job/fail_job/invalidate_job's own command path
## (_apply_job_command() -> _finish_job()) with a tool reserved for that job's
## real id, ticking once first so "complete_job" (which requires an active
## job) is exercised identically to the other three.
func _check_reservation_released_on_real_job_commands() -> void:
	for command_type in ["complete_job", "cancel_job", "fail_job", "invalidate_job"]:
		var world := _build_single_dig_world(20260919)
		world.spawn_ground_tool_item("pick", 0, 0)
		var submitted := _command(world, "dig_submit", "dig", {"x": 2, "y": 0, "priority": 1})
		_expect(submitted.get("ok", false), "dig submission must be accepted (%s)" % command_type)
		var job_id := String(submitted.get("job_id", ""))
		_expect(job_id != "", "a real dig job_id must come back from submission (%s)" % command_type)
		world.tick()
		var item_id := world.spawn_ground_tool_item("pick", 2, 0)
		_expect(world.reserve_tool_item(item_id, job_id),
			"reserving the tool for the real dig job must succeed (%s)" % command_type)
		var result := _command(world, "terminate", command_type, {"job_id": job_id})
		_expect(result.get("ok", false), "%s must be accepted for a real active job: %s" % [command_type, result])
		_expect(world.get_tool_item_reservation(item_id) == "",
			"%s must release the job's tool reservation automatically, not leave it dangling" % command_type)

## The same invariant must hold when a dig job finishes naturally through
## ticking (_advance_work() -> _finish_job()), a different code path than any
## command in _check_reservation_released_on_real_job_commands().
func _check_reservation_released_on_natural_completion() -> void:
	var world := _build_single_dig_world(20260919)
	var submitted := _command(world, "dig_submit", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	var item_id := world.spawn_ground_tool_item("pick", 2, 0)
	_expect(world.reserve_tool_item(item_id, job_id), "reserving the tool for the real dig job must succeed")

	var completed := false
	for _tick_index in range(200):
		world.tick()
		for job in world.get_jobs():
			if String(job.get("id", "")) == job_id and String(job.get("status", "")) == "completed":
				completed = true
		if completed:
			break
	_expect(completed, "the dig job must complete naturally within the tick budget")
	_expect(world.get_tool_item_reservation(item_id) == "",
		"natural job completion must release the job's tool reservation automatically")

## An invariant check (reservation_invariants.gd, colonist-ai.md 3.4) must
## assert that no reservation ever points at a terminal job: reusing the same
## ReservationTable/invariant helper the tile-target reservations already use.
func _check_reservation_invariant_no_leftover_on_terminal_job() -> void:
	var world := WorldStateType.new(20260919)
	var item_id := world.spawn_ground_tool_item("axe", 2, 2)
	_expect(world.reserve_tool_item(item_id, "job_active"), "reserving for an active job must succeed")

	var table := world.get_tool_reservation_table()
	var active_jobs: Array[Dictionary] = [{"id": "job_active", "status": "active"}]
	var orphans := ReservationInvariantsType.find_orphaned_reservations(table, active_jobs)
	_expect(orphans.is_empty(), "a reservation owned by an active job must not be orphaned")

	# The job goes terminal without releasing -- this is the violation the
	# invariant must catch.
	var terminal_jobs: Array[Dictionary] = [{"id": "job_active", "status": "completed"}]
	orphans = ReservationInvariantsType.find_orphaned_reservations(table, terminal_jobs)
	_expect(orphans == [item_id], "a reservation owned by a terminal job must be reported orphaned")

	# Releasing on the terminal transition must clear the violation.
	_expect(world.release_tool_item_reservation(item_id, "job_active"), "releasing on completion must succeed")
	orphans = ReservationInvariantsType.find_orphaned_reservations(table, terminal_jobs)
	_expect(orphans.is_empty(), "no reservation may outlive its job once released")

## Moving a tool item into a colonist's hand must set that colonist's
## held_tool and clear it again on drop; a stockpile cell is just another
## location a tool can rest at (no reservation of the cell itself).
func _check_held_and_stockpile_locations() -> void:
	var world := WorldStateType.new(20260919)
	var item_id := world.spawn_ground_tool_item("axe", 3, 3)
	var colonist_id := String(world.get_colonists()[0]["id"])

	_expect(world.set_tool_item_held(item_id, colonist_id), "moving a tool item to a colonist's hand must succeed")
	var held_colonist := _find_colonist(world, colonist_id)
	_expect(String(held_colonist.get("held_tool")) == item_id, "colonist.held_tool must record the held item id")
	_expect(world.get_tool_item(item_id)["location"]["type"] == "held", "item location must be 'held'")

	_expect(world.set_tool_item_stockpile(item_id, 9, 9), "moving a held tool item to a stockpile cell must succeed")
	held_colonist = _find_colonist(world, colonist_id)
	_expect(String(held_colonist.get("held_tool")) == "", "dropping a held tool must clear the former holder's held_tool")
	var location: Dictionary = world.get_tool_item(item_id)["location"]
	_expect(location["type"] == "stockpile" and location["x"] == 9 and location["y"] == 9,
		"item must now rest on the stockpile cell (9, 9)")

	_expect(world.set_tool_item_ground(item_id, 4, 4), "moving a stockpiled tool item to the ground must succeed")
	location = world.get_tool_item(item_id)["location"]
	_expect(location["type"] == "ground" and location["x"] == 4 and location["y"] == 4,
		"item must now rest on the ground at (4, 4)")

## A colonist already holding one item must not be handed a second: doing so
## would silently overwrite held_tool while the first item's own location dict
## still claims it is held by this colonist. Both conflict cases: a different
## colonist already holding another item, and re-handing the colonist its own
## already-held item (a no-op success, not a conflict).
func _check_held_tool_conflict_is_rejected() -> void:
	var world := WorldStateType.new(20260919)
	var colonist_id := String(world.get_colonists()[0]["id"])
	var first_item := world.spawn_ground_tool_item("axe", 1, 1)
	var second_item := world.spawn_ground_tool_item("pick", 2, 2)
	_expect(world.set_tool_item_held(first_item, colonist_id), "holding the first item must succeed")

	_expect(not world.set_tool_item_held(second_item, colonist_id),
		"handing a colonist a second item while it still holds the first must be rejected")
	var colonist := _find_colonist(world, colonist_id)
	_expect(String(colonist.get("held_tool")) == first_item,
		"a rejected handoff must leave the colonist's original held_tool unchanged")
	_expect(world.get_tool_item(second_item)["location"]["type"] == "ground",
		"a rejected handoff must leave the second item where it was")

	_expect(world.set_tool_item_held(first_item, colonist_id),
		"re-handing a colonist the item it already holds must succeed (no-op)")
	colonist = _find_colonist(world, colonist_id)
	_expect(String(colonist.get("held_tool")) == first_item, "held_tool must still name the same item")

## spawn_ground_tool_item() must refuse any kind that is not a declared tool
## kind (is_tool_kind()), instead of silently storing an arbitrary string.
func _check_spawn_ground_tool_item_rejects_non_tool_kind() -> void:
	var world := WorldStateType.new(20260919)
	var before := world.get_tool_items().size()
	_expect(world.spawn_ground_tool_item("wood", 1, 1) == "", "spawning a non-tool kind ('wood') must be rejected")
	_expect(world.spawn_ground_tool_item("not_a_real_kind", 1, 1) == "", "spawning an unknown kind must be rejected")
	_expect(world.get_tool_items().size() == before, "a rejected spawn must not allocate a tool item id")

func _find_colonist(world: WorldStateType, colonist_id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}

## to_save_state()/from_save_state() must round-trip tool items, their
## reservations and a colonist's held_tool.
func _check_save_round_trip() -> void:
	var world := WorldStateType.new(20260919)
	var ground_id := world.spawn_ground_tool_item("pick", 6, 7)
	_expect(world.reserve_tool_item(ground_id, "job_saved"), "reserving the ground item must succeed")
	var colonist_id := String(world.get_colonists()[0]["id"])
	var held_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(held_id, colonist_id), "moving the second item to the colonist's hand must succeed")

	var saved := world.to_save_state()
	_expect(int(saved["schemaVersion"]) == StateCodecType.SCHEMA_VERSION,
		"to_save_state() must report the current schema version")
	_expect(saved.has("toolItems") and saved.has("toolReservations"), "saved state must include toolItems/toolReservations")

	var validation := SaveIOType._validate_state(saved)
	_expect(validation["ok"], "a freshly produced save must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

	var restored := WorldStateType.from_save_state(saved)
	var restored_ground := restored.get_tool_item(ground_id)
	_expect(restored_ground.get("kind") == "pick" and restored_ground.get("location", {}).get("type") == "ground",
		"restored ground tool item must keep its kind and ground location")
	_expect(restored.get_tool_item_reservation(ground_id) == "job_saved",
		"restored tool reservation map must keep job_saved's reservation")
	var restored_colonist := _find_colonist(restored, colonist_id)
	_expect(String(restored_colonist.get("held_tool")) == held_id,
		"restored colonist must still record held_tool")
	_expect(restored.get_tool_item(held_id).get("location", {}).get("type") == "held",
		"restored held tool item must keep its 'held' location")

## game-state.schema.json declares toolItems additionalProperties: false;
## SaveIO._valid_tool_items() must reject a current-schema save that carries
## an extra field on the toolItems container itself, not just on its entries.
func _check_save_io_rejects_extra_toolitems_field() -> void:
	var world := WorldStateType.new(20260919)
	world.spawn_ground_tool_item("axe", 1, 1)
	var saved := world.to_save_state()
	_expect(SaveIOType._validate_state(saved)["ok"], "the unmodified save must pass validation first")

	var tampered: Dictionary = saved.duplicate(true)
	var tool_items: Dictionary = (tampered["toolItems"] as Dictionary).duplicate(true)
	tool_items["extra"] = "unexpected"
	tampered["toolItems"] = tool_items
	var validation := SaveIOType._validate_state(tampered)
	_expect(not validation["ok"], "a toolItems container with an unexpected field must be rejected")
	_expect(validation.get("code") == "schema_error",
		"an unexpected toolItems field must fail as schema_error, got '%s'" % validation.get("code"))

## An explicit drop must release whatever job reservation the tool carried
## (colonist-ai.md 2: a dropped tool stays unreserved and free for another
## colonist's job) -- both drop destinations: the ground and a stockpile
## cell.
func _check_dropping_a_reserved_tool_releases_its_reservation() -> void:
	var world := WorldStateType.new(20260919)
	var ground_item := world.spawn_ground_tool_item("axe", 1, 1)
	_expect(world.reserve_tool_item(ground_item, "job_drop_ground"), "reserving before a ground drop must succeed")
	_expect(world.set_tool_item_ground(ground_item, 8, 8), "moving an already-ground item must still succeed")
	_expect(world.get_tool_item_reservation(ground_item) == "",
		"set_tool_item_ground() must release the item's existing reservation")
	_expect(not world.is_tool_item_reserved(ground_item), "the dropped item must read back as unreserved")

	var stockpile_item := world.spawn_ground_tool_item("pick", 2, 2)
	_expect(world.reserve_tool_item(stockpile_item, "job_drop_stockpile"), "reserving before a stockpile drop must succeed")
	_expect(world.set_tool_item_stockpile(stockpile_item, 9, 9), "moving a reserved item to a stockpile cell must succeed")
	_expect(world.get_tool_item_reservation(stockpile_item) == "",
		"set_tool_item_stockpile() must release the item's existing reservation")
	_expect(not world.is_tool_item_reserved(stockpile_item), "the stockpiled item must read back as unreserved")

	var colonist_id := String(world.get_colonists()[0]["id"])
	var held_item := world.spawn_ground_tool_item("axe", 3, 3)
	_expect(world.set_tool_item_held(held_item, colonist_id), "picking up a tool must succeed")
	_expect(world.reserve_tool_item(held_item, "job_holding"), "reserving a held tool for its job must succeed")
	_expect(world.set_tool_item_ground(held_item, 4, 4), "dropping a held, reserved item must succeed")
	_expect(world.get_tool_item_reservation(held_item) == "",
		"dropping a held tool must also release its job reservation")

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

## The single wood item still on the ground, or {} when none: place() now
## always mints a fresh item id (issue #402: hands entries have no id of
## their own to preserve across a pick_up/place round trip), so a delivered
## item's final ground location must be found by kind, not by its original
## "item_1" id.
func _wood_item(world: WorldStateType) -> Dictionary:
	for item in world._items.values():
		if String(item["kind"]) == "wood":
			return item
	return {}

## Issue #271's fetch_tool toil: a pick reachable of the colonist's own dig
## target lets the job run to completion through fetch_tool/reserve/go_to/
## work/release_all with no blocked_no_tool detour.
func _check_fetch_tool_success_frees_no_travel() -> void:
	var world := _build_single_dig_world(271001)
	world.spawn_ground_tool_item("pick", 0, 0)
	var submitted := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "a dig job with a reachable pick must complete via fetch_tool within the tick budget")
	var colonist := world.get_colonists()[0]
	_expect(String(colonist.get("held_tool", "")) != "", "the colonist must still hold the pick after the job completes")

## Issue #271's blocked_no_tool: a dig job submitted where no pick exists
## anywhere exposes reason blocked_no_tool/remedy craft_or_find:pick while
## staying an ordinary queued (non-terminal) job -- exactly like any other
## blocked job ADR 004 skips (job_queue.gd's own BLOCKED_TARGET_RESERVED etc.)
## -- freeing its colonist for other work the same tick instead of terminally
## failing and resubmitting a lookalike replacement under a new id (round 3
## review: that would reset its aging and make cancel_job() on the original id
## report job_already_terminal). The colonist must go on to complete a
## different, tool-free job (forage) in the same run, and the ORIGINAL job id
## must still be the live, cancellable order the whole time.
func _check_blocked_no_tool_frees_colonist_for_other_work() -> void:
	var world := _build_single_dig_world(271002)
	var dig_submitted := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_submitted.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_submitted.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		var dig_job := _find_job(world, dig_id)
		if String(dig_job.get("reason", "")) == "blocked_no_tool":
			blocked = true
			_expect(String(dig_job.get("status", "")) == "queued",
				"a dig job with no pick anywhere must stay a queued, non-terminal job, got status '%s'" % dig_job.get("status"))
			_expect(String(dig_job.get("remedy", "")) == "craft_or_find:pick",
				"blocked_no_tool must carry remedy craft_or_find:pick, got '%s'" % dig_job.get("remedy"))
			break
	_expect(blocked, "a dig job with no pick anywhere must expose reason blocked_no_tool within the tick budget")

	_expect(_command(world, "place_bush", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var forage_submitted := _command(world, "forage_1", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_submitted.get("ok", false), "forage submission must be accepted")
	var forage_id := String(forage_submitted.get("job_id", ""))

	var forage_completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, forage_id).get("status", "")) == "completed":
			forage_completed = true
			break
	_expect(forage_completed,
		"the colonist freed from the blocked dig job must complete a different, tool-free job in the same run")

	var dig_after := _find_job(world, dig_id)
	_expect(String(dig_after.get("status", "")) == "queued",
		"the blocked dig job must remain the SAME queued job the whole time, not a terminal failure replaced by a resubmission")
	var cancel_result := _command(world, "cancel_dig", "cancel_job", {"job_id": dig_id})
	_expect(cancel_result.get("ok", false),
		"a dig job blocked on a missing tool must still be cancellable by its original id, got %s" % cancel_result)
	_expect(String(_find_job(world, dig_id).get("status", "")) == "cancelled",
		"cancelling the blocked dig job must actually mark it cancelled")

## Issue #271 round 3 review finding: the "already holds a matching tool"
## fast path must actually reserve it for the new job (or refuse to treat it
## as satisfied when another job already owns that reservation), not merely
## compare item kind -- otherwise a colonist's second matching job proceeds
## unreserved and a competing job could take the tool mid-work.
func _check_held_tool_reuse_respects_other_jobs_reservation() -> void:
	var world := _build_single_dig_world(271003)
	world.spawn_ground_tool_item("pick", 0, 0)
	var dig1 := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	var dig1_id := String(dig1.get("job_id", ""))
	var completed1 := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, dig1_id).get("status", "")) == "completed":
			completed1 = true
			break
	_expect(completed1, "the first dig job must complete")
	var held_id := String(world.get_colonists()[0].get("held_tool", ""))
	_expect(held_id != "", "the colonist must still hold the pick after completing the first dig job")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"a completed job must release its own tool reservation")

	_expect(world.reserve_tool_item(held_id, "other_job"),
		"reserving the held pick for a different job must succeed")

	var dig2 := _command(world, "dig_2", "dig", {"x": 1, "y": 0, "priority": 1})
	_expect(dig2.get("ok", false), "the second dig submission must be accepted")
	var dig2_id := String(dig2.get("job_id", ""))

	var dig2_blocked := false
	for _i in 10:
		world.tick()
		if String(_find_job(world, dig2_id).get("reason", "")) == "blocked_no_tool":
			dig2_blocked = true
			break
	_expect(dig2_blocked,
		"a held pick already reserved by a different job must not be treated as satisfied -- the colonist must report blocked_no_tool instead of silently reusing it")

	_expect(world.release_tool_item_reservation(held_id, "other_job"), "releasing the competing reservation must succeed")

	var dig2_completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, dig2_id).get("status", "")) == "completed":
			dig2_completed = true
			break
	_expect(dig2_completed, "once the competing reservation clears, the second dig job must complete by reusing the same held pick")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the second dig job must also release its own reservation on completion")

## Issue #271 round 3 review finding: pausing a dig job for a critical need
## must release its held tool's job reservation (not just its target tile
## reservation), so the tool is genuinely available to another job while this
## one is suspended; resuming must reacquire the SAME physically-held tool for
## free (no extra travel) since the interrupt never made the colonist drop it.
func _check_need_interrupt_releases_and_reacquires_held_tool() -> void:
	var world := WorldStateType.new(271004, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	world._ground_berries["1_1"] = 1
	world.spawn_ground_tool_item("pick", 0, 0)

	var dig_result := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var work_started := false
	for _i in 20:
		world.tick()
		if world.get_colonists()[0].get("work") != null:
			work_started = true
			break
	_expect(work_started, "the dig job must reach its work toil (holding the pick) within budget")
	var held_id := String(world.get_colonists()[0].get("held_tool", ""))
	_expect(held_id != "", "the colonist must be holding the pick while working")
	_expect(world.get_tool_item_reservation(held_id) == dig_id,
		"the dig job must own the pick's reservation while actively working")

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 5

	var interrupted := false
	for _i in 40:
		world.tick()
		if String(_find_job(world, dig_id).get("status", "")) == "queued":
			interrupted = true
			break
	_expect(interrupted, "the food need must interrupt the dig job")

	_expect(world.get_tool_item_reservation(held_id) == "",
		"suspending the dig job for a need interrupt must release its tool reservation")
	_expect(String(world.get_tool_item(held_id).get("location", {}).get("type", "")) == "held",
		"the interrupted colonist must keep physically holding the pick while away")
	_expect(world.reserve_tool_item(held_id, "probe_job"),
		"the released pick must be genuinely available for a different job to claim while this one is suspended")
	_expect(world.release_tool_item_reservation(held_id, "probe_job"), "releasing the probe reservation must succeed")

	var dig_completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, dig_id).get("status", "")) == "completed":
			dig_completed = true
			break
	_expect(dig_completed, "the interrupted dig job must resume and complete under the same job id")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the resumed dig job must release the reacquired tool reservation on completion")

## Issue #271 round 3 review finding: find_nearest_free_tool()'s nearest-first
## order must not wedge fetch_tool forever on a closer candidate that turns
## out unreachable -- a farther, genuinely reachable one must still be tried.
func _check_fetch_tool_skips_unreachable_candidate_for_farther_one() -> void:
	var world := WorldStateType.new(271005)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 7):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(6, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 2) # closer (distance 2) but walled off on every side
	world.spawn_ground_tool_item("pick", 5, 0) # farther (distance 5) but reachable along the corridor

	var submitted := _command(world, "dig_1", "dig", {"x": 6, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 300:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"a dig job must complete by fetching the farther, reachable pick once the nearer one proves unreachable, instead of staying blocked forever")

## Round 4 review finding: _exclude_fetch_candidate() must not re-enter
## _advance_fetch_tool() for the next-nearest candidate within the same tick
## -- each candidate's own go_to search already spends a route-search
## attempt, so chaining candidate after candidate in one tick could run an
## unbounded number of MeasuredRoute.resume() calls for a single colonist in
## a single tick, violating ADR 004's aggregate per-tick routing bound. With
## two nearer candidates walled off before a farther reachable one, at most
## one NEW fetch_tool go_to attempt ("enter" in ToilExecutor.trace) may begin
## per tick.
func _check_fetch_tool_does_not_chain_multiple_candidates_in_one_tick() -> void:
	var world := WorldStateType.new(271006)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 9):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(8, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 2) # closer (distance 2), walled off
	world.spawn_ground_tool_item("pick", 0, 3) # next-closer (distance 3), also walled off
	world.spawn_ground_tool_item("pick", 7, 0) # farthest (distance 7), reachable along the corridor

	var submitted := _command(world, "dig_1", "dig", {"x": 8, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var previous_enters := 0
	var completed := false
	for _i in 400:
		world.tick()
		var enters := 0
		for entry in world._toils.trace:
			if String(entry.get("toil", "")) == "fetch_tool" and String(entry.get("phase", "")) == "enter":
				enters += 1
		_expect(enters - previous_enters <= 1,
			"at most one new fetch_tool candidate may begin its go_to search per tick, went from %d to %d entries" % [previous_enters, enters])
		previous_enters = enters
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"the dig job must still complete by eventually trying the farthest reachable pick despite two nearer unreachable candidates")

## Round 4 review finding: WorldState._finish_job() unblocked/released before
## validating the terminal operation, so a rejected command (e.g. complete_job
## against a still-queued, blocked_no_tool order -- JobQueue.complete() is
## active_only) permanently discarded the job's tool reservations even though
## the job itself stayed queued and un-terminated. Round 5 folded
## blocked_no_tool's recovery into JobQueue's own ordinary queued-job/backoff
## state (job_queue.gd's _tool_requirement_satisfied()), so this now also
## proves that state survives a rejected terminal command untouched.
func _check_rejected_complete_job_preserves_tool_block_recovery() -> void:
	var world := _build_single_dig_world(271007)
	var dig_result := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		if String(_find_job(world, dig_id).get("reason", "")) == "blocked_no_tool":
			blocked = true
			break
	_expect(blocked, "a dig job with no pick anywhere must expose reason blocked_no_tool within the tick budget")

	var reject_result := _command(world, "complete_attempt", "complete_job", {"job_id": dig_id})
	_expect(not reject_result.get("ok", false),
		"complete_job against a queued (not active) blocked job must be rejected, not silently accepted")
	_expect(String(_find_job(world, dig_id).get("status", "")) == "queued",
		"a rejected complete_job must leave the blocked job's status untouched")

	world.spawn_ground_tool_item("pick", 0, 0)
	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"a rejected complete_job against a blocked order must leave its recovery tracking intact -- supplying a tool must still reconnect and complete the SAME job id")

## Round 4 review finding: _resume_paused_job() started a route toward the job
## target (or the work timer directly) before ToilExecutor's own tool check
## ran, so a resumed needs_tool job whose tool was taken away while paused
## could resume its work timer at the fetched tool's location instead of the
## job target, or reuse a stale job-target route as fetch_tool's own travel
## leg. Simulates "taken away" by directly moving the held pick to a second,
## distant colonist while colonist_0 is paused (a second colonist's own AI is
## not under test here) and asserts colonist_0's work toil is only ever
## active while it actually stands on/adjacent to the dig target, through a
## full fetch-after-interrupt cycle: reacquire (by travelling to the new
## holder), return, and complete at the original target.
func _check_interrupted_job_refetches_and_works_at_job_target_not_tool_location() -> void:
	var world := WorldStateType.new(271008, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 5, "y": 5,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	world._ground_berries["1_1"] = 1
	world.spawn_ground_tool_item("pick", 0, 0)

	var dig_result := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var work_started := false
	for _i in 20:
		world.tick()
		if _find_colonist(world, "colonist_0").get("work") != null:
			work_started = true
			break
	_expect(work_started, "the dig job must reach its work toil (holding the pick) within budget")
	var held_id := String(_find_colonist(world, "colonist_0").get("held_tool", ""))
	_expect(held_id != "", "colonist_0 must be holding the pick while working")

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 5

	var interrupted := false
	for _i in 40:
		world.tick()
		if String(_find_job(world, dig_id).get("status", "")) == "queued":
			interrupted = true
			break
	_expect(interrupted, "the food need must interrupt the dig job")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"suspending the dig job for a need interrupt must release its tool reservation")

	# The pick is taken away while colonist_0 is paused.
	_expect(world.set_tool_item_held(held_id, "colonist_1"),
		"moving the unreserved, paused-colonist-held pick to a second colonist must succeed")
	_expect(String(_find_colonist(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0 must no longer record held_tool once the pick moves to colonist_1")

	var dig_completed := false
	for _i in 300:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("work") != null:
			var cx := int(colonist_0["x"])
			var cy := int(colonist_0["y"])
			_expect(maxi(absi(cx - 2), absi(cy - 0)) <= 1,
				"colonist_0's work toil must only run while it stands on/adjacent to the dig target (2, 0), got (%d, %d)" % [cx, cy])
		if String(_find_job(world, dig_id).get("status", "")) == "completed":
			dig_completed = true
			break
	_expect(dig_completed,
		"the interrupted dig job must reacquire a pick (by travelling to its new holder) and complete under the same job id")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the resumed dig job must release the reacquired tool reservation on completion")

## Round 5 review finding: blocked_no_tool's recovery must go through the
## fair scheduler's ordinary labour eligibility check (GlobalAssignment's
## _is_labour_enabled(), consulted for every _waiting entry before it may ever
## be scored/activated) exactly like any other queued job, not a side-channel
## reconnect that bypasses it. Disables "mine" labour for the only colonist
## while its dig job sits blocked_no_tool, then supplies a pick: the job must
## NOT reactivate while labour stays disabled, even though a matching tool
## now exists -- only once labour is re-enabled does the SAME job (never
## replaced by a resubmission) complete.
func _check_blocked_no_tool_respects_labour_disabled() -> void:
	var world := _build_single_dig_world(271010)
	world._colonists[0]["labourTable"] = {"mine": 3}
	var dig_result := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		if String(_find_job(world, dig_id).get("reason", "")) == "blocked_no_tool":
			blocked = true
			break
	_expect(blocked, "a dig job with no pick anywhere must expose reason blocked_no_tool within the tick budget")

	_expect(_command(world, "disable_mine", "set_labour", {"colonist": "colonist_0", "kind": "mine", "level": 0}).get("ok", false),
		"set_labour must be accepted")
	world.spawn_ground_tool_item("pick", 0, 0)

	for _i in 60:
		world.tick()
		_expect(String(_find_job(world, dig_id).get("status", "")) != "active",
			"a dig job must not reactivate while mine labour is disabled for its only colonist, even once a pick exists")

	_expect(_command(world, "enable_mine", "set_labour", {"colonist": "colonist_0", "kind": "mine", "level": 3}).get("ok", false),
		"set_labour must be accepted")

	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the SAME dig job (id %s) must complete once mine labour is re-enabled and a pick exists" % dig_id)

## Round 5 review finding: dig/chop's own retry_base_ticks/retry_cap_ticks
## (content/jobs.json) were declared but never read, so an available-but-
## permanently-unreachable tool could repeatedly retrigger a real route-search
## attempt every tick with no backoff, and the colonist blocked on it was
## never proven free to do other work. Isolates a pick fully enclosed by rock
## (no adjacent passable tile at all, unlike a merely-far-away one) so it can
## never be fetched: JobQueue's own activation gate only checks a matching
## tool EXISTS (a cheap check, colonist-ai.md 2/3.3), so the job still goes
## active and fetch_tool still tries and fails to reach it -- exactly as it
## already does for a merely-unreachable candidate -- but it must always
## return to queued/blocked_no_tool afterward rather than getting stuck
## active, its backoff must strictly grow across two consecutive block cycles
## (job_queue.gd's _tool_requirement_satisfied(), reusing the same
## backoff_ticks field haul's own destination backoff already uses) instead
## of retrying every tick forever, and the colonist must still complete a
## different, tool-free forage job.
func _check_blocked_no_tool_permanently_unreachable_tool_backs_off_and_frees_colonist() -> void:
	var world := WorldStateType.new(271011)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 6):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	world.spawn_ground_tool_item("pick", 2, 3) # fully enclosed by rock on every side

	var dig_result := _command(world, "dig_1", "dig", {"x": 5, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var first_backoff := 0
	for _i in 60:
		world.tick()
		var job := _find_job(world, dig_id)
		if String(job.get("reason", "")) == "blocked_no_tool" and int(job.get("backoff_ticks", 0)) > 0:
			first_backoff = int(job["backoff_ticks"])
			break
	_expect(first_backoff > 0, "the dig job must expose a nonzero backoff once blocked_no_tool")

	var escalated := false
	for _i in 400:
		world.tick()
		var job := _find_job(world, dig_id)
		_expect(String(job.get("status", "")) in ["queued", "active"],
			"a permanently blocked dig job must never terminate on its own")
		# Round 6 review finding: JobQueue.tick()'s reachability check ran
		# BEFORE the tool-backoff check, so a backed-off job's own reservation
		# shortcut selection fed a stale/no-search-this-tick _can_reach() result
		# back into the SAME job and overwrote blocked_no_tool's reason with
		# blocked_target_unreachable for the entire backoff window, even though
		# the target itself is genuinely reachable.
		if String(job.get("status", "")) == "queued" and int(job.get("backoff_ticks", 0)) > 0:
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"a permanently-unreachable-tool dig job's reason must stay blocked_no_tool throughout its own backoff window, got '%s' at backoff_ticks=%d" % [job.get("reason", ""), job.get("backoff_ticks", 0)])
		if int(job.get("backoff_ticks", 0)) > first_backoff:
			escalated = true
			break
	_expect(escalated, "the dig job's backoff must grow across repeated blocked_no_tool cycles, not repeat forever unbounded")

	_expect(_command(world, "place_bush", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var forage_result := _command(world, "forage_1", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_result.get("ok", false), "forage submission must be accepted")
	var forage_id := String(forage_result.get("job_id", ""))

	var forage_completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, forage_id).get("status", "")) == "completed":
			forage_completed = true
			break
	_expect(forage_completed,
		"the colonist must complete a different, tool-free job despite the permanently blocked dig job")
	_expect(String(_find_job(world, dig_id).get("status", "")) == "queued",
		"the permanently blocked dig job must remain the same queued job throughout, never terminated")

## Round 6 review finding: JobQueue.tick()'s reachability check ran BEFORE
## the tool-backoff check (see the reason assertion folded into
## _check_blocked_no_tool_permanently_unreachable_tool_backs_off_and_frees_
## colonist() above for the existing-but-unreachable-tool case). This is the
## missing-tool case: a dig job with no matching tool anywhere must keep
## reporting reason blocked_no_tool/remedy craft_or_find:pick across the
## ENTIRE backoff window, not merely the tick it is first observed.
func _check_blocked_no_tool_reason_survives_backoff_window() -> void:
	var world := _build_single_dig_world(271012)
	var dig_result := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, dig_id)
		if String(job.get("reason", "")) == "blocked_no_tool" and int(job.get("backoff_ticks", 0)) > 0:
			blocked = true
			break
	_expect(blocked, "the dig job must expose a nonzero backoff once blocked_no_tool")

	# dig's own retry_base_ticks is 20 (content/jobs.json): 15 further ticks
	# stays safely inside the same backoff window.
	for _i in 15:
		world.tick()
		var job := _find_job(world, dig_id)
		_expect(String(job.get("reason", "")) == "blocked_no_tool",
			"a dig job's reason must stay blocked_no_tool throughout its own backoff window, got '%s'" % job.get("reason", ""))
		_expect(String(job.get("remedy", "")) == "craft_or_find:pick",
			"a dig job's remedy must stay craft_or_find:pick throughout its own backoff window, got '%s'" % job.get("remedy", ""))

## Round 6 review finding: WorldState._toil_on_no_tool_found() reused
## GlobalAssignment.suspend_assignment(), which unconditionally pins the
## requeued job's restrict_to to the colonist whose fetch just failed --
## permanently binding an ordinary dig order to its first colonist even once
## that colonist's own labour is disabled and a different, still-eligible
## colonist could complete it. colonist_0 starts adjacent to the dig target
## (so it always wins the initial assignment) but the only pick anywhere is
## fully enclosed by rock (so its own fetch_tool travel leg proves it
## unreachable and triggers on_no_tool_found); colonist_0's mine labour is
## then disabled, and only once a second, genuinely reachable pick appears
## does colonist_1 -- the only colonist still eligible for "mine" -- complete
## the SAME order.
func _check_blocked_no_tool_failure_frees_job_for_a_different_colonist() -> void:
	var world := WorldStateType.new(271013)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(9, 9)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(2, 2)] = WorldStateType.TILE_ROCK
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if dx != 0 or dy != 0:
				world._tiles[world._tile_index(2 + dx, 2 + dy)] = WorldStateType.TILE_ROCK
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {"mine": 3},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 19, "y": 19,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {"mine": 3},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	world.spawn_ground_tool_item("pick", 2, 2) # enclosed, unreachable by anyone

	var dig_result := _command(world, "dig_1", "dig", {"x": 9, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 300:
		world.tick()
		if String(_find_job(world, dig_id).get("reason", "")) == "blocked_no_tool":
			blocked = true
			break
	_expect(blocked, "colonist_0's own fetch_tool attempt at the enclosed pick must eventually report blocked_no_tool")

	_expect(_command(world, "disable_colonist0_mine", "set_labour", {"colonist": "colonist_0", "kind": "mine", "level": 0}).get("ok", false),
		"disabling colonist_0's mine labour must be accepted")
	world.spawn_ground_tool_item("pick", 5, 5) # genuinely reachable, only useful to colonist_1 now

	var completed := false
	for _i in 400:
		world.tick()
		if String(_find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"once colonist_0's labour is disabled, the SAME dig job must still complete -- via colonist_1, the only colonist still eligible -- proving the requeue was not pinned back to colonist_0")
	_expect(String(_find_colonist(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0 must never pick up the new pick while its mine labour stays disabled")

## Round 6 review finding: ToolFetchToil._excluded (per-job, tried-and-
## unreachable tool-id set) must persist across a REAL SaveIO round trip
## (write_atomic()/read(), schemaVersion 17) -- otherwise a restored run
## re-tries a candidate an uninterrupted run had already ruled out, changing
## every subsequent tick. Walls off a closer pick (excluded after one failed
## fetch attempt) while a farther one stays reachable, saves right after the
## closer candidate is excluded but before the job completes, and proves both
## the excluded set itself and the full tick-by-tick continuation to
## completion match an uninterrupted run.
func _check_save_io_round_trip_after_candidate_excluded() -> void:
	var world := WorldStateType.new(271014)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 7):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(6, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 2) # closer (distance 2) but walled off
	world.spawn_ground_tool_item("pick", 5, 0) # farther (distance 5) but reachable

	var submitted := _command(world, "dig_1", "dig", {"x": 6, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var excluded := false
	for _i in 300:
		world.tick()
		var current: Array = world._toils.get_fetch_tool_excluded().get(job_id, [])
		if not current.is_empty():
			excluded = true
			break
	_expect(excluded, "the closer, walled-off pick must be excluded within the tick budget")
	_expect(String(_find_job(world, job_id).get("status", "")) != "completed",
		"the job must not already be complete the instant the closer candidate is excluded")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-exclusion: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-exclusion: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored._toils.get_fetch_tool_excluded().get(job_id, []) == world._toils.get_fetch_tool_excluded().get(job_id, []),
		"restore must recover the exact excluded-candidate set, not drop it")
	_expect(restored.state_hash() == world.state_hash(),
		"restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	for _i in 300:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
			break
	_expect(direct_completed, "the uninterrupted run must still complete by fetching the farther pick")

	var restored_completed := false
	for _i in 300:
		restored.tick()
		var restored_job := {}
		for j in restored.get_jobs():
			if String(j["id"]) == job_id:
				restored_job = j
		if String(restored_job.get("status", "")) == "completed":
			restored_completed = true
			break
	_expect(restored_completed, "the SaveIO-restored run must also complete by fetching the farther pick, without re-trying the excluded one")
	_expect(world.state_hash() == restored.state_hash(),
		"the source and SaveIO-restored runs must reach the identical final hash")

## SaveMigrations.migrate() must turn an inline schemaVersion-10 Dictionary
## literal (no workProgress/pausedJobs/toolItems/toolReservations keys, no
## entity heldTool/labourTable) all the way to the current schema (13) --
## with workProgress/pausedJobs backfilled at the v10->v11 step (task #205,
## merged from main), labourTable backfilled at the v11->v12 step (task
## #207, merged from main), and toolItems/toolReservations backfilled at the
## v12->v13 step (task #213's own version bump) -- and pass SaveIO's
## current-schema validation.
func _check_v10_migration_to_v11() -> void:
	var v10_state := {
		"schemaVersion": 10,
		"contentVersion": "vertical-slice-1",
		"seed": 1,
		"tick": 0,
		"map": {"width": 1, "height": 1, "tiles": ["floor"]},
		"entities": [{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"needs": {"food": 100, "water": 100, "rest": 100},
			"route": null, "work": null, "carrying": null,
		}],
		"inventory": {},
		"jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {},
			"pending": {}, "assignments": {},
		},
		"rng": {"seed": 1, "state": 0},
		"items": {"nextId": 1, "list": []},
		"objects": [],
		"zones": [],
		"nextZoneId": 1,
		"groundBerries": [],
	}
	var result := SaveMigrationsType.migrate(v10_state, 10, StateCodecType.SCHEMA_VERSION)
	_expect(result["ok"], "migrating a schemaVersion-10 state to current schema must succeed: %s" % result.get("message", ""))
	if not result["ok"]:
		return
	var migrated: Dictionary = result["state"]
	_expect(int(migrated["schemaVersion"]) == StateCodecType.SCHEMA_VERSION,
		"migrated state must report the current schema version")
	_expect(migrated["workProgress"] == [], "migrated state's workProgress must be honestly empty")
	_expect(migrated["pausedJobs"] == [], "migrated state's pausedJobs must be honestly empty")
	_expect(migrated["toolItems"]["list"] == [], "migrated state's toolItems.list must be honestly empty")
	_expect(migrated["toolReservations"] == {}, "migrated state's toolReservations must be honestly empty")
	_expect(not (migrated["entities"][0] as Dictionary).has("heldTool"),
		"a migrated pre-#213 entity must leave heldTool absent, not backfilled")
	_expect((migrated["entities"][0] as Dictionary).get("labourTable") == {
			"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3,
		}, "a migrated pre-#207 entity must be backfilled to the default all-3 labourTable")

	var validation := SaveIOType._validate_state(migrated)
	_expect(validation["ok"], "a migrated state must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Issue #266: ADR 012's own "Already held" fast path (satisfied() reserves
## a matching held tool for the job with no travel) proven directly against
## the execution trace, not merely inferred from "the job completed quickly".
func _check_held_tool_skips_fetch_tool_travel() -> void:
	var world := _build_single_dig_world(266001)
	var held_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(held_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	var submitted := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	world._toils.clear_trace()

	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the dig job must complete")
	for entry in world._toils.trace:
		_expect(String(entry.get("toil", "")) != "fetch_tool",
			"a colonist already holding the matching tool must never enter/complete fetch_tool's own travel: %s" % [world._toils.trace])
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the completed job must release the reused held tool's reservation")

## Issue #266: a colonist holding a tool that a foreign job has reserved
## (ADR 012 case (b)'s third location -- held by another colonist but
## unreserved at the moment fetch_tool claimed it) must run drop_tool as the
## first toil of its own next dispatched job, before that job's own go_to/work,
## and must no longer hold the tool once dropped.
func _check_foreign_reservation_triggers_drop_tool_handover() -> void:
	var world := WorldStateType.new(266002)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "place_bush", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"),
		"reserving the held pick for a different (foreign) job must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	world._toils.clear_trace()

	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete once it drops the foreign-reserved pick")

	var drop_index := -1
	var go_to_index := -1
	for i in world._toils.trace.size():
		var entry: Dictionary = world._toils.trace[i]
		if drop_index == -1 and String(entry.get("toil", "")) == "drop_tool" and String(entry.get("phase", "")) == "complete":
			drop_index = i
		if go_to_index == -1 and String(entry.get("toil", "")) == "go_to" and String(entry.get("phase", "")) == "enter":
			go_to_index = i
	_expect(drop_index != -1, "colonist_0 must run a drop_tool toil before its own forage job: %s" % [world._toils.trace])
	_expect(go_to_index != -1 and drop_index < go_to_index,
		"drop_tool must complete before the forage job's own go_to toil begins: %s" % [world._toils.trace])

	_expect(String(_find_colonist(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0 must no longer hold the pick once it has been dropped for the handover")
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) in ["ground", "stockpile"],
		"the dropped pick must rest on the ground or a stockpile cell, not stay held")

## Issue #266: when a free stockpile cell lies within ToolDropToil.TOOL_DROP_RADIUS
## of the holder, drop_tool must walk there and drop the tool on that cell
## instead of dropping in place.
func _check_drop_tool_prefers_nearby_stockpile_cell() -> void:
	var world := WorldStateType.new(266003)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add near colonist_0 must be accepted")
	_expect(_command(world, "place_bush", "place_object", {"x": 5, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 5, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 2 and location.get("y") == 0,
		"a free stockpile cell within reach must be preferred over dropping the pick in place, got %s" % location)

## Issue #266: a tool a job actively holds and has reserved (satisfied(), mid
## reserve/go_to/work) must fail the job's current toil the instant it is
## destroyed/removed, release every reservation the job held, and re-queue the
## job through the same backoff mechanism t1 wired for an ordinary
## blocked_no_tool failure -- proven here by supplying a fresh tool afterward
## and reaching completion under the SAME job id.
func _check_destroyed_tool_fails_job_and_requeues_with_backoff() -> void:
	var world := _build_single_dig_world(266004)
	world.spawn_ground_tool_item("pick", 0, 0)
	var submitted := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var work_started := false
	var held_id := ""
	for _i in 30:
		world.tick()
		if world.get_colonists()[0].get("work") != null:
			work_started = true
			held_id = String(world.get_colonists()[0].get("held_tool", ""))
			break
	_expect(work_started, "the dig job must reach its work toil (actively using the pick) within budget")
	_expect(held_id != "", "colonist_0 must be holding the pick while working")
	_expect(world.get_tool_item_reservation(held_id) == job_id,
		"the dig job must own the pick's reservation while actively working")

	# A second, unrelated tool reservation the same job happens to also own
	# (round 2 review finding: the old fix released only held_id) -- both must
	# be released by the failure below, not just the destroyed one.
	var extra_id := world.spawn_ground_tool_item("axe", 5, 5)
	_expect(world.reserve_tool_item(extra_id, job_id), "reserving a second, unrelated tool for the same job must succeed")

	# Simulate the tool being destroyed/removed out from under the active job.
	world._tool_store.items.erase(held_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"a job whose active tool was destroyed must re-queue with reason blocked_no_tool, got '%s'" % job.get("reason"))
			_expect(int(job.get("backoff_ticks", 0)) > 0,
				"a job whose active tool was destroyed must re-queue with a nonzero backoff, got %d" % job.get("backoff_ticks", 0))
			break
	_expect(requeued, "the dig job must re-queue within the tick budget once its active tool is destroyed")
	_expect(not world.is_tool_item_reserved(held_id),
		"every reservation the job held on the destroyed tool must be released, not left dangling")
	_expect(not world.is_tool_item_reserved(extra_id),
		"every OTHER reservation the failing job held must also be released, not just the destroyed item's")
	_expect(String(world.get_colonists()[0].get("held_tool", "")) == "",
		"the colonist must no longer record held_tool once its actively-used tool is destroyed")
	_expect(world.get_colonists()[0].get("work") == null,
		"the colonist's work toil must stop the instant its active tool is destroyed")

	# Supplying a fresh pick must let the SAME job id complete afterward.
	world.spawn_ground_tool_item("pick", 0, 0)
	var completed := false
	for _i in 120:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the re-queued job must still complete once a replacement tool becomes available")

func _find_job_colonist_id(world: WorldStateType, job_id: String) -> String:
	var assignments := world.get_assignments()
	for worker in assignments:
		if String(assignments[worker]["job_id"]) == job_id:
			return String(worker)
	return ""

## Round 2 review finding: the requester side of the handover was untested --
## ToolFetchToil._arrive() used to steal the tool straight out of the
## holder's hand instead of waiting for its own drop_tool toil. Two real
## colonists, two real jobs throughout: colonist_0 holds a leftover pick
## while busy foraging; colonist_1's real dig job reserves that same pick
## while colonist_0 is still busy, and must wait (reason
## waiting_for_tool_handover, itemId naming the pick, blockingJobId naming
## colonist_0's own currently assigned job) until colonist_0's own next
## dispatched job (a second forage order) runs drop_tool and actually
## releases it -- only then does colonist_1 pick it up and complete.
func _check_requester_waits_for_real_handover_then_completes() -> void:
	var world := WorldStateType.new(266010)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")

	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	_expect(_command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1}).get("ok", false),
		"forage A submission must be accepted")
	_expect(_command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1}).get("ok", false),
		"forage B submission must be accepted")

	# colonist_0 must already be genuinely busy on forage_a before the dig
	# order (and its fetch_tool reservation) ever exists -- otherwise it would
	# still be transiently unassigned (the ordinary one-tick scheduler lag)
	# when the reservation lands, and the handover wait's own "idle holder"
	# fallback (waiting_for_handover()) would let colonist_1 steal the pick
	# directly instead of exercising the wait this test is about.
	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget, before the dig order below exists")

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var waiting_seen := false
	var completed := false
	for _i in 400:
		world.tick()
		var dig_job := _find_job(world, dig_id)
		if String(dig_job.get("reason", "")) == "waiting_for_tool_handover":
			waiting_seen = true
			_expect(String(dig_job.get("item_id", "")) == pick_id,
				"waiting_for_tool_handover's itemId must name the reserved pick, got '%s'" % dig_job.get("item_id"))
			var blocking_job_id := String(dig_job.get("blocking_job_id", ""))
			_expect(not blocking_job_id.is_empty() and _find_job_colonist_id(world, blocking_job_id) == "colonist_0",
				"waiting_for_tool_handover's blockingJobId must name colonist_0's own currently assigned job, got '%s'" % blocking_job_id)
			_expect(String(_find_colonist(world, "colonist_1").get("held_tool", "")) == "",
				"colonist_1 must not hold the pick while genuinely waiting for the handover")
		if String(dig_job.get("status", "")) == "completed":
			completed = true
			break
	_expect(waiting_seen, "the dig job must expose reason waiting_for_tool_handover while colonist_0 still holds the pick")
	_expect(completed, "the dig job must complete once colonist_0's own next dispatched job drops the pick")
	_expect(String(_find_colonist(world, "colonist_1").get("held_tool", "")) == pick_id,
		"colonist_1 must end up holding the pick it waited for")

	var drop_seen := false
	for entry in world._toils.trace:
		if String(entry.get("toil", "")) == "drop_tool" and String(entry.get("phase", "")) == "complete":
			drop_seen = true
	_expect(drop_seen, "colonist_0 must have run a drop_tool toil to release the handover: %s" % [world._toils.trace])

## Round 2 review finding: a tool destroyed while fetch_tool is still
## TRAVELLING toward it (reserved but not yet physically held) must fail the
## job's current toil and back off exactly like a destroyed HELD tool does --
## ToolFetchToil.advance() must not silently rescan and reserve the farther,
## still-existing candidate instead of failing.
func _check_destroyed_tool_during_fetch_travel_fails_and_backs_off() -> void:
	var world := WorldStateType.new(266006)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 9):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(8, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var near_id := world.spawn_ground_tool_item("pick", 3, 0)
	var far_id := world.spawn_ground_tool_item("pick", 7, 0)

	var submitted := _command(world, "dig_1", "dig", {"x": 8, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		if world.get_tool_item_reservation(near_id) == job_id and String(world.get_colonists()[0].get("held_tool", "")) == "":
			travelling = true
			break
	_expect(travelling, "the dig job must reserve and start travelling toward the nearer pick within budget")
	_expect(String(_find_job(world, job_id).get("status", "")) == "active",
		"the dig job must be active while fetch_tool is travelling")

	world._tool_store.items.erase(near_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"a job whose in-flight fetch_tool target was destroyed must re-queue with reason blocked_no_tool, got '%s'" % job.get("reason"))
			_expect(int(job.get("backoff_ticks", 0)) > 0,
				"a job whose in-flight fetch_tool target was destroyed must re-queue with a nonzero backoff")
			break
	_expect(requeued, "the dig job must re-queue within the tick budget once its in-flight fetch target is destroyed")
	_expect(not world.is_tool_item_reserved(near_id), "the destroyed pick's reservation must be released")
	_expect(not world.is_tool_item_reserved(far_id),
		"the farther, still-existing pick must NOT have been silently reserved as a replacement")
	_expect(String(world.get_colonists()[0].get("held_tool", "")) == "", "the colonist must hold nothing")

	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the re-queued job must still complete by fetching the farther, surviving pick")

## Round 2 review finding: drop_tool's own destination must stay fixed for
## the whole leg (no per-tick recomputation) and must be REVALIDATED at
## arrival, not assumed -- a different job claiming the originally-chosen
## stockpile cell mid-travel must not silently retarget the colonist to a
## closer/farther alternative cell while it is still walking toward the old
## one; it must instead notice at arrival that its own destination is no
## longer free and drop on the ground there instead.
func _check_drop_tool_revalidates_destination_at_arrival() -> void:
	var world := WorldStateType.new(266007)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 4, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(_command(world, "place_bush", "place_object", {"x": 9, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 9, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	# One tick in, drop_tool has already chosen (2, 0) -- the nearest free
	# cell -- and started walking there (distance 2 tiles, 4 ticks/tile: still
	# far from arrival). Claim that exact cell from a different job now,
	# leaving (5, 0) -- also in the zone, also within TOOL_DROP_RADIUS -- free.
	world.tick()
	var colonist := world.get_colonists()[0]
	_expect(colonist.get("route") != null and int(colonist["x"]) == 0 and int(colonist["y"]) == 0,
		"the colonist must still be travelling toward the drop cell, not yet arrived")
	world._scheduler.queue.get_reservation_table().acquire("cell:2,0", "blocker_job")
	_expect(not world.is_cell_free(2, 0), "claiming cell (2, 0) from a different job must make it no longer free")
	_expect(world.is_cell_free(5, 0), "cell (5, 0) must remain free as the untouched alternative")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "the pick must be dropped within the tick budget despite the contested cell")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "ground" and location.get("x") == 2 and location.get("y") == 0,
		"the colonist must still walk all the way to (2, 0) -- its own already-chosen destination -- and only THEN fall back to dropping on the ground there, got %s" % location)

	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete despite the drop falling back to the ground")

## Round 2 review finding: a save/load taken mid-way through a drop_tool
## leg's own MOVEMENT (an already-resolved path, no in-flight reroute search)
## must not lose track of it being a drop leg -- StateCodec has no new field
## for this (ADR 012: the leg is reconstructed from already-persisted state,
## see tool_drop_toil.gd's is_dropping()), so a naive restore could otherwise
## treat the in-flight route as the tool-free job's own ordinary route and
## start work at the stockpile cell instead of completing the handover.
func _check_save_io_round_trip_mid_drop_tool_movement_matches_uninterrupted_run() -> void:
	var world := WorldStateType.new(266008)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 4, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(_command(world, "place_bush", "place_object", {"x": 9, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")
	var submitted := _command(world, "forage_1", "forage", {"x": 9, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var midway := false
	for _i in 60:
		world.tick()
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") == null and String(colonist.get("held_tool", "")) == pick_id \
				and int(colonist["x"]) > 0 and int(colonist["x"]) < 4:
			midway = true
			break
	_expect(midway, "the colonist must be caught mid-movement toward the drop cell (resolved path, not yet arrived)")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop-tool-movement: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-drop-tool-movement: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 after the handover resolves")

	var restored_completed := false
	for _i in 200:
		restored.tick()
		if String(_find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
			break
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 after the handover resolves")
	_expect(world.state_hash() == restored.state_hash(),
		"the source and SaveIO-restored runs must reach the identical final hash")
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held",
		"the pick must actually have been dropped (handover completed), not stuck mid-travel forever")

## Round 2 review finding: the same save/load guarantee must also hold while
## a drop_tool leg's own bounded re-route SEARCH is still in flight
## (rerouting != null, no resolved path yet) -- _restore_reroutes()
## (state_codec.gd, out of this task's owned paths) reconstructs its cost
## callable from ToilExecutor.needs_fetch_tool(), which reports false for a
## tool-free job's drop leg; the search's own already-persisted
## snapshot.target is still used correctly via the ordinary "job target"
## branch in that case, since a drop's chosen stockpile cell is already
## pre-verified passable and needs no target-tile passability exception. A
## wide-open 21x21 room forces the RNG-free Dijkstra search to expand well
## past its own 64-per-tick budget (a uniform-cost flood fill covers ~2*r^2
## tiles by the time it reaches a target r tiles away) before ever reaching
## the target, even though the target itself sits within TOOL_DROP_RADIUS (a
## short, thin wall forces a small detour around it, not a long walk) -- so
## the resolved WALK afterward stays short while the SEARCH genuinely spans
## more than one tick.
func _check_save_io_round_trip_mid_drop_tool_route_search_matches_uninterrupted_run() -> void:
	var world := WorldStateType.new(266009)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 21):
		for y in range(0, 21):
			world._tiles[world._tile_index(x, y)] = WorldStateType.TILE_FLOOR
	for y in range(11, 15):
		world._tiles[world._tile_index(10, y)] = WorldStateType.TILE_ROCK
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 10, "y": 15, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(_command(world, "place_bush", "place_object", {"x": 0, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 10, 10)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")
	var submitted := _command(world, "forage_1", "forage", {"x": 0, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var mid_search := false
	for _i in 10:
		world.tick()
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null and String(colonist.get("held_tool", "")) == pick_id:
			mid_search = true
			break
	_expect(mid_search, "the colonist's drop-tool re-route search must still be unresolved within a few ticks")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop-tool route search: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-drop-tool route search: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	for _i in 400:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 after the handover resolves")

	var restored_completed := false
	for _i in 400:
		restored.tick()
		if String(_find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
			break
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 after the handover resolves")
	_expect(world.state_hash() == restored.state_hash(),
		"the source and SaveIO-restored runs must reach the identical final hash")

## Round 2 review: a requester whose fetch_tool candidate is reserved from a
## busy foreign holder it happens to already stand ADJACENT to must not steal
## it the very same tick the reservation lands -- advance_go_to()'s own
## path.size()<=1 shortcut would otherwise call on_arrive (pickup) inline,
## inside the SAME ToolFetchToil.advance() call that just reserved it, before
## ToilExecutor's own waiting_for_handover() gate ever runs again.
func _check_adjacent_busy_holder_does_not_steal_tool_same_tick() -> void:
	var world := WorldStateType.new(266011)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(_command(world, "place_bush", "place_object", {"x": 20, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(_command(world, "forage_a", "forage", {"x": 20, "y": 0, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget, before the dig order below exists")

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var reserved_tick_seen := false
	for _i in 10:
		world.tick()
		if world.get_tool_item_reservation(pick_id) == dig_id:
			reserved_tick_seen = true
			_expect(String(_find_colonist(world, "colonist_1").get("held_tool", "")) == "",
				"colonist_1 must not hold the pick the same tick its fetch_tool reserves it from a busy holder")
			_expect(String(world.get_tool_item(pick_id).get("location", {}).get("colonist_id", "")) == "colonist_0",
				"the pick must still be physically held by colonist_0 the same tick it gets reserved by dig_1")
			break
	_expect(reserved_tick_seen, "dig_1's fetch_tool must reserve the pick within budget")

	var completed := false
	for _i in 400:
		world.tick()
		if String(_find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "dig_1 must still complete once colonist_0's own next dispatched job drops the pick")
	_expect(String(_find_colonist(world, "colonist_1").get("held_tool", "")) == pick_id,
		"colonist_1 must end up holding the pick it waited for")

## Round 2 review: a fetch_tool leg that legitimately started travelling
## toward an IDLE holder's tool must correctly retarget, not fail, once that
## holder later becomes busy and its own drop_tool toil relocates the tool to
## a stockpile cell away from where the fetch route was already heading --
## advance_go_to() never re-targets an already-resolved route on its own, so
## without ToolFetchToil.advance() discarding the stale route, the requester
## would walk all the way to the tool's OLD position, find nothing there, and
## back off with blocked_no_tool instead of completing.
func _check_fetch_tool_retargets_when_holder_drops_tool_elsewhere() -> void:
	var world := WorldStateType.new(266012)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(25, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var dig_result := _command(world, "dig_1", "dig", {"x": 25, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_1 := _find_colonist(world, "colonist_1")
		if world.get_tool_item_reservation(pick_id) == dig_id and colonist_1.get("route") != null:
			travelling = true
			break
	_expect(travelling, "dig_1's fetch_tool must reserve the pick and start travelling toward idle colonist_0 within budget")
	_expect(_find_colonist(world, "colonist_0").get("route") == null,
		"colonist_0 must still be idle (a legitimate direct-pickup target) at the moment the reservation lands")

	_expect(_command(world, "place_bush", "place_object", {"x": 0, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(_command(world, "forage_1", "forage", {"x": 0, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must become busy on forage_1 within budget")

	var backed_off := false
	var completed := false
	for _i in 400:
		world.tick()
		var job := _find_job(world, dig_id)
		if String(job.get("status", "")) == "queued":
			backed_off = true
		if String(job.get("status", "")) == "completed":
			completed = true
			break
	_expect(not backed_off, "dig_1 must retarget toward the pick's new stockpile location instead of failing blocked_no_tool")
	_expect(completed, "dig_1 must complete once fetch_tool retargets toward the relocated pick")

## Round 2 review: is_dropping() must never reinterpret a job's own ordinary
## go_to leg as a drop leg just because needs_drop() also happens to turn true
## mid-flight -- exact-equality against the (impassable, therefore one-tile-
## trimmed) ordinary target used to misclassify every such route the instant
## a foreign job reserved the held tool, diverting it to a stockpile cell
## instead of letting it reach its own job's target.
func _check_ordinary_route_not_misclassified_as_drop_when_reservation_appears_midflight() -> void:
	var world := WorldStateType.new(266013)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "place_bush", "place_object", {"x": 20, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 20, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var midway := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		if colonist.get("route") != null and int(colonist["x"]) > 2:
			midway = true
			break
	_expect(midway, "colonist_0 must be caught mid-travel toward the bush before the foreign reservation lands")

	_expect(world.reserve_tool_item(pick_id, "foreign_job"),
		"reserving the held pick for a foreign job mid-travel must succeed")

	world._toils.clear_trace()
	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must complete without being diverted to drop_tool mid-travel")
	for entry in world._toils.trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"an in-flight ordinary route must never run a drop_tool toil while it is still heading to its own job's target: %s" % [world._toils.trace])

## Round 2 review: is_dropping() must also leave an in-flight fetch_tool leg
## alone when a DIFFERENT held tool becomes foreign-reserved mid-travel (a
## colonist can hold one leftover tool while fetching an unrelated new one) --
## the route's own destination coincides with ToolFetchToil's own current
## target, not a drop cell, so it must never be reinterpreted as a drop leg.
func _check_fetch_route_not_misclassified_as_drop_when_other_reservation_appears() -> void:
	var world := WorldStateType.new(266014)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 21):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(20, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	world.spawn_ground_tool_item("axe", 20, 0)

	var submitted := _command(world, "chop_1", "chop", {"x": 20, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var midway := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		if colonist.get("route") != null and int(colonist["x"]) > 2:
			midway = true
			break
	_expect(midway, "colonist_0 must be caught mid-travel toward the axe before the foreign reservation lands")

	_expect(world.reserve_tool_item(pick_id, "foreign_job"),
		"reserving the leftover pick for a foreign job mid-fetch-travel must succeed")

	world._toils.clear_trace()
	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own chop job must still complete, fetching the axe without a spurious drop_tool detour")
	for entry in world._toils.trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"an in-flight fetch_tool leg must never run a drop_tool toil for an unrelated held tool: %s" % [world._toils.trace])
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) == "ground",
		"the leftover pick must end up on the ground (fetch_tool's own minimal drop-at-arrival), not vanish")

## Round 2 review: cancelling the requester's job WHILE its own drop_tool leg
## is still mid-walk must not let the SAME in-flight route be reinterpreted as
## the holder's own ordinary leg once the reservation disappears --
## is_dropping() must keep recognizing it as a drop in progress purely from
## colonist.held_tool/route (it never depended on needs_drop() remaining true
## once started), completing the drop and THEN correctly starting the
## holder's own next toil, never mistaking the stockpile arrival for the
## holder's own job target.
func _check_requester_cancellation_midflight_still_completes_drop_correctly() -> void:
	var world := WorldStateType.new(266015)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var forage_a_result := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a_result.get("ok", false), "forage A submission must be accepted")
	var forage_a_id := String(forage_a_result.get("job_id", ""))
	var forage_b_result := _command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_b_result.get("ok", false), "forage B submission must be accepted")
	var forage_b_id := String(forage_b_result.get("job_id", ""))

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget")

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var dropping := false
	for _i in 200:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == pick_id and colonist_0.get("route") != null \
				and int(colonist_0["x"]) > 0 and int(colonist_0["x"]) < 5:
			dropping = true
			break
	_expect(dropping, "colonist_0 must be caught mid-walk toward the stockpile cell before cancellation")

	_expect(_command(world, "cancel_dig_1", "cancel_job", {"job_id": dig_id}).get("ok", false),
		"cancelling dig_1 mid-drop-walk must be accepted")
	_expect(world.get_tool_item_reservation(pick_id) == "", "cancelling dig_1 must release its reservation on the pick")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "colonist_0 must still complete the drop after the requester's own job is cancelled mid-walk")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 5 and location.get("y") == 0,
		"colonist_0 must finish walking to its own already-chosen stockpile cell, not abandon the drop mid-way, got %s" % location)

	var both_completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, forage_a_id).get("status", "")) == "completed" \
				and String(_find_job(world, forage_b_id).get("status", "")) == "completed":
			both_completed = true
			break
	_expect(both_completed, "colonist_0 must still complete both of its own forage jobs, never mistaking the stockpile arrival for its own job target")

## Round 4 review: unlike the cancellation test just above (tool-free forage),
## the holder's own NEXT DISPATCHED job may itself need a DIFFERENT tool than
## the one it is dropping. The instant the foreign job that triggered the drop
## is cancelled, needs_drop() turns false while ToolFetchToil.needs() turns
## true (axe != pick) -- the OLD is_dropping() read that combination as "not
## dropping, must be fetching" and abandoned the in-flight walk to the
## stockpile cell partway there. ToolDropToil's own _active_drop marker must
## keep recognizing the SAME in-flight leg regardless.
func _check_drop_continues_when_holders_own_next_job_needs_a_different_tool() -> void:
	var world := WorldStateType.new(266029)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(15, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(25, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	var labour_table_all_but_mine := {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	var labour_table_all_but_chop := {"mine": 3, "chop": 0, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_but_mine})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": labour_table_all_but_chop})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	world.spawn_ground_tool_item("axe", 20, 0)

	var dig_result := _command(world, "dig_1", "dig", {"x": 15, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var reserved := false
	for _i in 20:
		world.tick()
		if world.get_tool_item_reservation(pick_id) == dig_id:
			reserved = true
			break
	_expect(reserved, "dig_1 must reserve colonist_0's held pick within budget")

	var chop_result := _command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(chop_result.get("ok", false), "chop submission must be accepted")
	var chop_id := String(chop_result.get("job_id", ""))

	var dropping := false
	for _i in 30:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == pick_id and colonist_0.get("route") != null \
				and int(colonist_0["x"]) > 0 and int(colonist_0["x"]) < 5:
			dropping = true
			break
	_expect(dropping, "colonist_0 must be caught mid-walk toward the stockpile cell, dropping the pick, before dig_1 is cancelled")

	_expect(_command(world, "cancel_dig_1", "cancel_job", {"job_id": dig_id}).get("ok", false),
		"cancelling dig_1 mid-drop-walk must be accepted")
	_expect(world.get_tool_item_reservation(pick_id) == "", "cancelling dig_1 must release its reservation on the pick")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "colonist_0 must still complete the drop after dig_1 is cancelled mid-walk, even though its own next job needs a different tool")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 5 and location.get("y") == 0,
		"colonist_0 must finish walking to its own already-chosen stockpile cell instead of abandoning it for chop_1's own axe fetch, got %s" % location)

	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, chop_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0 must still complete chop_1, fetching the axe after finishing the drop")

## Round 4 review: the requester may ALSO hold a leftover tool that becomes
## foreign-reserved (needs_drop() true) WHILE its own fetch_tool reservation
## on a DIFFERENT tool is momentarily released by the holder's own drop --
## unlike _check_fetch_route_survives_drifting_handover_holder_while_requester_holds_leftover()'s
## unreserved leftover, needs_drop() is genuinely true here, and the OLD
## is_dropping() fell through to its position-based fallback and misread the
## frozen fetch route as the requester's OWN drop leg for the wrong tool.
## Also proves a SaveIO round trip taken before the holder's drop resolves the
## gap reaches the identical state_hash() tick by tick through it as an
## uninterrupted run.
func _check_fetch_route_not_misclassified_as_drop_when_leftover_tool_also_foreign_reserved() -> void:
	var world := WorldStateType.new(266030)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(25, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	var labour_table_all_but_chop := {"mine": 3, "chop": 0, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	var labour_table_all_3 := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_but_chop})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_3})
	var axe_id := world.spawn_ground_tool_item("axe", 20, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	var leftover_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(leftover_id, "colonist_1"), "moving the leftover pick into colonist_1's hand must succeed")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 15, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var submitted := _command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_1 := _find_colonist(world, "colonist_1")
		if world.get_tool_item_reservation(axe_id) == job_id and colonist_1.get("route") != null and int(colonist_1["x"]) > 1:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward idle colonist_0 within budget")

	_expect(world.reserve_tool_item(leftover_id, "foreign_job"),
		"reserving colonist_1's own leftover pick for a foreign job mid-fetch-travel must succeed")

	_expect(_command(world, "place_bush", "place_object", {"x": 20, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(_command(world, "forage_0", "forage", {"x": 20, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var drifting := false
	for _i in 30:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == axe_id and colonist_0.get("route") != null:
			drifting = true
			break
	_expect(drifting, "colonist_0 must start walking its own drop_tool leg while still physically holding the axe within budget")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken while the requester's own leftover tool is also foreign-reserved: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var pick_ever_left_colonist_1 := false
	var direct_completed := false
	var restored_completed := false
	for i in 400:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		var colonist_1 := _find_colonist(world, "colonist_1")
		var held := String(colonist_1.get("held_tool", ""))
		if held != leftover_id and held != axe_id:
			pick_ever_left_colonist_1 = true
		if not direct_completed and String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(_find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(not pick_ever_left_colonist_1,
		"colonist_1 must hold either its own leftover pick or the freshly fetched axe at every tick, never neither -- a misclassified drop leg would empty its hands early")
	_expect(direct_completed, "chop_1 must still complete in the uninterrupted run once colonist_0 finishes relocating the axe")
	_expect(restored_completed, "chop_1 must still complete in the SaveIO-restored run too")

## Round 4 review: _find_drop_cell() previously excluded every cell reachable-
## adjacent to an IMPASSABLE ordinary target too (a stockpile zone overlapping
## the reach of forage's own bush, colonist-ai.md/objects.json's berry_bush is
## never itself walkable), discarding an otherwise valid, free stockpile cell
## for no reason once is_dropping() no longer identifies a leg from target
## position at all (it reads ToolDropToil's own stable _active_drop marker
## instead -- see tool_drop_toil.gd's own doc comment). The bush tile itself
## is still naturally excluded by _cell_still_free()'s own passability check,
## not by any special-cased "avoid" exclusion, so the nearest remaining free
## cell in the zone must be used rather than falling back to the ground.
func _check_drop_cell_adjacent_to_impassable_ordinary_target_uses_nearest_stockpile_cell() -> void:
	var world := WorldStateType.new(266016)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 3, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(_command(world, "place_bush", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must complete")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 2 and location.get("y") == 0,
		"the nearest free stockpile cell adjacent to the impassable bush must be used, not discarded for a ground fallback, got %s" % location)

## Round 4 review: with leg identification no longer based on target position
## at all, a drop destination coinciding EXACTLY with the job's own passable
## ordinary target is no longer ambiguous with that job's own ordinary/
## fetch_tool leg (both are told apart purely by ToolDropToil's own
## _active_drop marker) and must be used like any other qualifying free
## stockpile cell -- the zone here contains only that one cell, so there is no
## nearer alternative to prefer.
func _check_drop_cell_exactly_on_passable_ordinary_target_is_used() -> void:
	var world := WorldStateType.new(266028)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(3, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 3, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add exactly on the till target must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := _command(world, "till_1", "till", {"x": 3, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "till submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own till job must complete despite dropping exactly on its own passable target")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 3 and location.get("y") == 0,
		"the drop destination coinciding exactly with the passable till target must be used directly, got %s" % location)

## A PASSABLE ordinary target (till's own soil target, tiles.json's "soil" is
## walkable -- till, unlike dig, declares no needs_tool at all, so the held
## pick's own foreign reservation below can never block this job's own
## activation-time tool-availability gate the way it would for a pick-needing
## job kind). The zone here spans the target's immediate neighbours on both
## sides; round 4 review removed _find_drop_cell()'s exclusion of the exact
## target tile entirely (see _check_drop_cell_exactly_on_passable_ordinary_target_is_used()
## below for that case directly), but the nearest of the two neighbours here
## is still strictly closer to the colonist than the target tile itself, so
## the nearest-cell tie-break must still choose one of them, not the target.
func _check_drop_cell_near_passable_ordinary_target_uses_nearest_stockpile_cell() -> void:
	var world := WorldStateType.new(266024)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(3, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 3, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := _command(world, "till_1", "till", {"x": 3, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "till submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own till job must complete despite dropping right next to its own passable target")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 2 and location.get("y") == 0,
		"the nearest free stockpile cell adjacent to the passable till target must be used, not discarded or a farther one chosen, got %s" % location)

## Round 2 review: active_tool_missing()/fail_for_destroyed_tool() must scan
## EVERY reservation job_id holds, not just the first the ReservationTable
## snapshot happens to yield -- and must clear colonist.held_tool only when
## the DESTROYED item is the one actually held, never a surviving one, even
## when the destroyed reservation is not the job's own primary (held) tool.
func _check_destroyed_tool_among_multiple_reservations_not_first_and_unrelated_held_tool_preserved() -> void:
	var world := _build_single_dig_world(266017)
	world.spawn_ground_tool_item("pick", 0, 0)
	var submitted := _command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var held_id := ""
	for _i in 30:
		world.tick()
		if world.get_colonists()[0].get("work") != null:
			held_id = String(world.get_colonists()[0].get("held_tool", ""))
			break
	_expect(held_id != "", "colonist_0 must be holding the pick while working")

	# A second, unrelated reservation the SAME job also happens to hold, not
	# yet physically held by anyone -- destroyed below, while the ALREADY-HELD
	# pick survives, to prove neither check depends on dictionary iteration
	# order finding the destroyed item first.
	var extra_id := world.spawn_ground_tool_item("axe", 5, 5)
	_expect(world.reserve_tool_item(extra_id, job_id), "reserving a second, unrelated tool for the same job must succeed")

	world._tool_store.items.erase(extra_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"a job whose non-primary reservation was destroyed must still re-queue with reason blocked_no_tool, got '%s'" % job.get("reason"))
			_expect(String(world.get_colonists()[0].get("held_tool", "")) == held_id,
				"colonist_0 must still physically hold the surviving pick -- only the unrelated destroyed reservation should have any effect")
			break
	_expect(requeued, "the dig job must re-queue within the tick budget once its non-primary reserved tool is destroyed")
	_expect(not world.is_tool_item_reserved(held_id), "the surviving pick's reservation must still be released like any other terminal transition")

## Round 2/3 review: a tool destroyed while fetch_tool is still travelling
## toward it (reserved but not held) must not clear colonist.held_tool when
## the colonist is ALSO already holding a different, unrelated tool -- that
## surviving item's own location still correctly says "held" by this
## colonist, and clearing held_tool would desync it from that truth. The axe
## sits FAR from chop_1's own job target (round 3 review: the round 2 version
## placed the axe adjacent to the job target, which let is_dropping()'s own
## "reachable-adjacent to the ordinary target" branch mask the real bug by
## accident -- the destroyed-tool check must run before ANY route
## interpretation regardless of geometry, proven here by making that branch
## never apply in the first place).
func _check_destroyed_fetch_target_preserves_unrelated_held_tool() -> void:
	var world := WorldStateType.new(266018)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(20, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	var axe_id := world.spawn_ground_tool_item("axe", 5, 0)

	var submitted := _command(world, "chop_1", "chop", {"x": 20, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		if world.get_tool_item_reservation(axe_id) == job_id and String(world.get_colonists()[0].get("held_tool", "")) == pick_id:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward it while still holding the leftover pick")
	var colonist := world.get_colonists()[0]
	_expect(int(colonist["x"]) < 5, "colonist_0 must still be well short of the far-away axe when it is destroyed below")

	world._tool_store.items.erase(axe_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			break
	_expect(requeued, "chop_1 must re-queue within the tick budget once its in-flight fetch target is destroyed")
	_expect(String(world.get_colonists()[0].get("held_tool", "")) == pick_id,
		"colonist_0 must still hold the unrelated leftover pick -- only the destroyed axe's own reservation should have any effect")
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) == "held",
		"the surviving pick's own item record must still correctly say it is held")
	for entry in world._toils.trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"a destroyed in-flight fetch target must never be reinterpreted as a drop leg for the surviving leftover pick: %s" % [world._toils.trace])

## Round 3 review: a fetch_tool destination trimmed one tile short by
## advance_go_to()'s own target-tile trim (the tool's own tile made
## impassable mid-travel, e.g. a wall built on it) must never be
## misclassified as a drop leg -- the old is_dropping() compared the route's
## frozen destination against ToolFetchToil.current_target() for EXACT
## position equality, which the trim always broke. colonist_0 holds an
## unrelated leftover pick throughout, so is_dropping()'s entry gate stays
## active the whole time.
func _check_fetch_route_survives_impassable_fetch_destination_trim() -> void:
	var world := WorldStateType.new(266022)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(25, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	var axe_id := world.spawn_ground_tool_item("axe", 10, 0)

	var submitted := _command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		if world.get_tool_item_reservation(axe_id) == job_id and colonist.get("route") != null and int(colonist["x"]) > 2:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward it within budget")

	_expect(_command(world, "wall_on_axe", "place_object", {"x": 10, "y": 0, "kind": "wooden_wall"}).get("ok", false),
		"placing a wall directly on the axe's own tile mid-travel must be accepted")

	world._toils.clear_trace()
	var completed := false
	for _i in 400:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "chop_1 must still complete, picking up the axe from one tile short of its now-impassable tile")
	for entry in world._toils.trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"a fetch_tool leg trimmed short by an impassable fetch destination must never be reinterpreted as a drop leg: %s" % [world._toils.trace])

## Round 3 review: a busy foreign holder's OWN drop_tool leg physically walks
## while still holding the requester's reserved tool -- ToolMatchingType.
## item_target() reports a "held" item's location as the holder's CURRENT
## position, so it moves every tick the holder is mid-walk, drifting
## ToolFetchToil.current_target() away from the requester's already-in-flight
## route (frozen by design once reserved, see tool_fetch_toil.gd's own
## "freshly_reserved" gate) until the holder finally arrives and actually
## drops it. The requester ALSO holds an unrelated leftover tool throughout,
## so is_dropping()'s entry gate stays active the whole time this drift is
## happening, and must never misclassify the frozen route as a drop leg --
## proven here by asserting the requester's own leftover pick is only ever
## dropped in the single correct place (ToolFetchToil._arrive()'s own swap
## for the axe once it genuinely arrives), never mid-travel.
func _check_fetch_route_survives_drifting_handover_holder_while_requester_holds_leftover() -> void:
	var world := WorldStateType.new(266023)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(25, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": {"chop": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var axe_id := world.spawn_ground_tool_item("axe", 20, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	var leftover_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(leftover_id, "colonist_1"), "moving the leftover pick into colonist_1's hand must succeed")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 15, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var submitted := _command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_1 := _find_colonist(world, "colonist_1")
		if world.get_tool_item_reservation(axe_id) == job_id and colonist_1.get("route") != null and int(colonist_1["x"]) > 1:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward idle colonist_0 within budget")
	_expect(_find_colonist(world, "colonist_0").get("route") == null,
		"colonist_0 must still be idle (a legitimate direct-pickup target) at the moment the reservation lands")

	_expect(_command(world, "place_bush", "place_object", {"x": 20, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(_command(world, "forage_0", "forage", {"x": 20, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var drifting := false
	for _i in 30:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == axe_id and colonist_0.get("route") != null:
			drifting = true
			break
	_expect(drifting, "colonist_0 must start walking its own drop_tool leg while still physically holding the axe within budget")

	var pick_ever_left_colonist_1 := false
	var completed := false
	for _i in 400:
		world.tick()
		var colonist_1 := _find_colonist(world, "colonist_1")
		var held := String(colonist_1.get("held_tool", ""))
		if held != leftover_id and held != axe_id:
			pick_ever_left_colonist_1 = true
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(not pick_ever_left_colonist_1,
		"colonist_1 must hold either its own leftover pick or the freshly fetched axe at every tick, never neither -- a mid-travel drop_tool misclassification would empty its hands early")
	_expect(completed, "chop_1 must still complete once colonist_0 finishes relocating the axe and the fetch route retargets to it")

## Round 2 review: _restore_reroutes() must reconstruct a drop_tool leg's
## in-flight search with the SAME plain passability the live toil always
## uses, not job.target's own target-tile exception -- proven here by placing
## the job's own impassable target directly on a full-width wall between the
## holder and its chosen stockpile cell, the one geometry where the old
## exception opened a "shortcut" a live/direct run could never take (the live
## search is always plain, no exception, regardless of save/load). Compares
## state_hash() after every tick, not merely at completion, so any single
## diverging tick fails immediately.
func _check_save_io_round_trip_mid_drop_tool_search_impassable_target_between_holder_and_stockpile() -> void:
	var world := WorldStateType.new(266019)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	for x in range(0, 48):
		world._tiles[world._tile_index(x, 6)] = WorldStateType.TILE_ROCK
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 5, "y": 5, "route": null, "work": null})
	_expect(_command(world, "place_bush", "place_object", {"x": 5, "y": 6, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement on the wall row must be accepted")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 5, "y": 9, "width": 1, "height": 1}).get("ok", false),
		"zone_add south of the wall must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 5, 5)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")
	var submitted := _command(world, "forage_1", "forage", {"x": 5, "y": 6, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var mid_search := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null and String(colonist.get("held_tool", "")) == pick_id:
			mid_search = true
			break
	_expect(mid_search, "the colonist's drop-tool re-route search toward the walled-off stockpile cell must still be unresolved within budget")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop-tool search with an impassable target on the wall: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	var restored_completed := false
	for i in 400:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d): a wrong passability exception here would let the restored search cross the wall the direct run never could" % i)
		if not direct_completed and String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(_find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 once the drop search proves the stockpile cell unreachable")
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 once the drop search proves the stockpile cell unreachable")
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) == "ground",
		"with the wall having no legitimate crossing, the pick must fall back to dropping on the ground, not reach the stockpile via a fake shortcut")

## Round 2 review: _find_drop_cell()/_cell_still_free() must also treat a
## cell already holding a ground/stockpiled tool item as occupied -- the
## general cell_occupied callable only ever checked colonists and stackable
## items, never tool items.
func _check_drop_tool_skips_cell_already_occupied_by_another_tool() -> void:
	var world := WorldStateType.new(266020)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 2, "height": 1}).get("ok", false),
		"zone_add near colonist_0 must be accepted")
	world.spawn_ground_tool_item("axe", 2, 0)
	_expect(_command(world, "place_bush", "place_object", {"x": 5, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 5, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 3 and location.get("y") == 0,
		"the cell already holding an axe must be skipped in favor of the next free cell, got %s" % location)

## Round 2 review: removing the destination zone mid-travel must also be
## revalidated at arrival -- storing location.type "stockpile" for a cell
## that no longer belongs to any zone would be wrong, so arrival must fall
## back to dropping on the ground when the zone is gone.
func _check_drop_tool_falls_back_to_ground_when_destination_zone_removed_midflight() -> void:
	var world := WorldStateType.new(266021)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var zone_result := _command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 1, "height": 1})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	var zone_id := String(zone_result.get("zone_id", ""))
	_expect(_command(world, "place_bush", "place_object", {"x": 9, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 9, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	world.tick()
	var colonist := world.get_colonists()[0]
	_expect(colonist.get("route") != null and int(colonist["x"]) == 0 and int(colonist["y"]) == 0,
		"the colonist must still be travelling toward the drop cell, not yet arrived")
	_expect(_command(world, "zone_remove_1", "zone_remove", {"id": zone_id}).get("ok", false),
		"removing the destination zone mid-travel must be accepted")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "the pick must be dropped within the tick budget despite its destination zone disappearing")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "ground" and location.get("x") == 2 and location.get("y") == 0,
		"the colonist must still walk all the way to its own already-chosen cell (2, 0) and only THEN fall back to the ground once that cell no longer belongs to any zone, got %s" % location)

	var completed := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete despite the drop falling back to the ground")

## Round 5 review: seed_active_drop()'s restore-time heuristic could not
## reconstruct the drop leg's identity in three unbounded-duration cases
## (docs/decisions/012-tool-toils.md's "Round 5 review"). ToolDropToil no
## longer has any restore-time heuristic at all: JobQueue.
## set_active_item_marker()/get_active_item_marker() persist the SAME marker
## advance() already maintains directly on the job's own already-round-tripped
## itemId field, so a restore needs no bootstrap step -- the marker is simply
## already there. This proves the first of the three cases: a save taken
## AFTER the requester's job that triggered the drop is cancelled (releasing
## the reservation needs_drop() reads), compared tick by tick against an
## uninterrupted run through to both forage jobs completing.
func _check_save_io_round_trip_after_requester_cancellation_midflight() -> void:
	var world := WorldStateType.new(266031)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var forage_a_result := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a_result.get("ok", false), "forage A submission must be accepted")
	var forage_a_id := String(forage_a_result.get("job_id", ""))

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget")

	# Issue #349/ADR 023 slowed real needs decay to points-per-day: colonist_0
	# going idle after forage_a completes no longer starves fast enough, on
	# its own, to earn a second (eat_food) job dispatch before colonist_1's
	# fetch_tool toil simply walks over and takes the unreserved held pick
	# directly -- the scenario this check actually needs is "colonist_0 gets
	# dispatched a new job while holding a foreign-reserved tool", not real
	# hunger timing, so food is pinned low here (mirroring _isolate_need()-
	# style direct need mutation elsewhere in this suite) to make NeedGiver
	# assign colonist_0 the eat_food job for the ground berries forage_a just
	# produced at (1, 0) the instant it goes idle, well before colonist_1
	# physically arrives. forage_b (below) is deliberately NOT submitted this
	# early -- see its own comment -- so this cannot reuse that job instead.
	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 20

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var dropping := false
	for _i in 200:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == pick_id and colonist_0.get("route") != null \
				and int(colonist_0["x"]) > 0 and int(colonist_0["x"]) < 5:
			dropping = true
			break
	_expect(dropping, "colonist_0 must be caught mid-walk toward the stockpile cell before cancellation")

	# forage_b is only submitted now, once colonist_1 is already committed to
	# dig_1's own tool reservation: colonist_1's labourTable must stay a
	# SaveIO-valid, full 7-kind table (unlike its plain-live-state-only
	# sibling test above, this one takes a real SaveIO round trip, which
	# rejects any non-canonical key such as a "forage" one used purely to
	# keep a live colonist out of the forage pool) -- sequencing forage_b's
	# submission after colonist_1 already committed keeps it out of
	# contention without relying on a labour toggle forage does not have.
	var forage_b_result := _command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_b_result.get("ok", false), "forage B submission must be accepted")
	var forage_b_id := String(forage_b_result.get("job_id", ""))

	_expect(_command(world, "cancel_dig_1", "cancel_job", {"job_id": dig_id}).get("ok", false),
		"cancelling dig_1 mid-drop-walk must be accepted")
	_expect(world.get_tool_item_reservation(pick_id) == "", "cancelling dig_1 must release its reservation on the pick")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken after the requester's job is cancelled mid-drop: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(_find_job(world, forage_a_id).get("status", "")) == "completed" \
				and String(_find_job(world, forage_b_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(_find_job(restored, forage_a_id).get("status", "")) == "completed" \
				and String(_find_job(restored, forage_b_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run must still complete both forage jobs after the cancellation")
	_expect(restored_completed, "the SaveIO-restored run must also complete both forage jobs, never abandoning or misreading the drop")

## Second of the three round 5 review cases: a save taken INSIDE the window
## between a fetch_tool reservation being released (the holder's own
## drop_tool leg completing) and the requester's own next advance() re-
## reserving it, while the requester ALSO physically holds a second,
## unrelated tool that is itself foreign-reserved -- exactly the state whose
## restore-time reconstruction (needs_drop() true for the unrelated tool)
## used to permanently misseed the marker as "dropping" for a genuine fetch
## leg. With no restore-time reconstruction left at all (the marker is only
## ever set by ToolDropToil.advance() actually starting a drop, and the
## requester never does here -- it only fetches), there is nothing to
## misseed.
##
## Round 6 review: the previous version of this test saved BEFORE the
## holder's drop even completed, never inside the gap at all -- a save taken
## that early would restore correctly even under the OLD, now-removed
## seed_active_drop() heuristic, so it never actually exercised this case.
## The gap is real but brief: WorldState._advance_colonists() advances every
## colonist within ONE external tick() call, sorted by id (not append order),
## so whichever of the two colonists' ids sorts LAST runs its own turn AFTER
## the other's within the same tick. Naming the requester "colonist_0" (sorts
## first) and the holder "colonist_1" (sorts second) makes the holder's drop
## -- and the reservation release it causes -- happen strictly AFTER the
## requester's own turn each tick, so the release is invisible to the
## requester until ITS next turn, at the START of the following external
## tick() call. Saving immediately after the tick() call whose holder turn
## performed the drop, before calling tick() again, therefore captures a
## real, observable gap: the axe genuinely unreserved, the requester's own
## fetch route still in flight, and its own unrelated leftover pick still
## foreign-reserved -- proven directly below before the save is taken.
func _check_save_io_round_trip_in_reservation_release_gap_with_unrelated_foreign_reserved_held_tool() -> void:
	var world := WorldStateType.new(266032)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(25, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	var labour_table_all_but_chop := {"mine": 3, "chop": 0, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	var labour_table_all_3 := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	# colonist_0 is the REQUESTER (fetches the axe via chop_1) so that its id
	# sorts, and therefore advances, before colonist_1 the HOLDER every tick --
	# see the doc comment above for why this ordering is what makes the
	# release gap actually observable across a tick() boundary.
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_3})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_but_chop})
	var axe_id := world.spawn_ground_tool_item("axe", 20, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_1"), "moving the axe into colonist_1's hand must succeed")
	var leftover_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(leftover_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 15, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var submitted := _command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if world.get_tool_item_reservation(axe_id) == job_id and colonist_0.get("route") != null and int(colonist_0["x"]) > 1:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward idle colonist_1 within budget")

	_expect(world.reserve_tool_item(leftover_id, "foreign_job"),
		"reserving colonist_0's own leftover pick for a foreign job mid-fetch-travel must succeed")
	_expect(_command(world, "place_bush", "place_object", {"x": 20, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(_command(world, "forage_0", "forage", {"x": 20, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	# Advance until colonist_1's own drop_tool leg has actually COMPLETED (the
	# axe physically leaves its hand and its reservation is genuinely gone) --
	# not merely started -- while colonist_0's own fetch route is still
	# present. Because colonist_0 (the requester) advances before colonist_1
	# (the holder) every tick, the tick whose holder turn performs the drop is
	# already the gap: colonist_0's own turn that same tick ran BEFORE the
	# release, so it has not re-scanned yet, and won't until its NEXT turn.
	var in_gap := false
	for _i in 60:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		var axe := world.get_tool_item(axe_id)
		if String(axe.get("location", {}).get("type", "")) != "held" \
				and colonist_0.get("route") != null \
				and world.get_tool_item_reservation(axe_id) == "":
			in_gap = true
			break
	_expect(in_gap, "the axe must be dropped, releasing its reservation, while colonist_0's own fetch route is still in flight, within budget")

	var colonist_0 := _find_colonist(world, "colonist_0")
	_expect(colonist_0.get("route") != null, "colonist_0's own fetch route must still exist at the moment of save")
	_expect(world.get_tool_item_reservation(axe_id) == "",
		"the axe's reservation must be genuinely absent at the moment of save -- proving the save lands inside the gap, not before it")
	_expect(world.get_tool_item_reservation(leftover_id) == "foreign_job",
		"colonist_0's own unrelated leftover pick must still be foreign-reserved at the moment of save")
	_expect(String(colonist_0.get("held_tool", "")) == leftover_id,
		"colonist_0 must still physically hold its own unrelated leftover pick at the moment of save")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken inside the reservation-release gap: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(_find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "chop_1 must still complete in the uninterrupted run")
	_expect(restored_completed, "chop_1 must still complete in the SaveIO-restored run too, never misread as a drop leg for colonist_1's own leftover pick")

## Third of the three round 5 review cases, and the widest: a save taken
## during an ordinary go_to leg (no fetch_tool, no drop_tool -- forage's own
## plain travel) after the colonist's held tool happens to become foreign-
## reserved mid-leg. Live behaviour never reclassifies an in-flight leg this
## way (drop_tool insertion only ever happens at a toil boundary), and with no
## restore-time heuristic left to misfire on needs_drop() alone, neither does
## a restore.
func _check_save_io_round_trip_ordinary_route_after_held_tool_foreign_reserved_midflight() -> void:
	var world := WorldStateType.new(266033)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(_command(world, "place_bush", "place_object", {"x": 20, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")

	var submitted := _command(world, "forage_1", "forage", {"x": 20, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var midway := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		if colonist.get("route") != null and int(colonist["x"]) > 2:
			midway = true
			break
	_expect(midway, "colonist_0 must be caught mid-travel toward the bush before the foreign reservation lands")

	_expect(world.reserve_tool_item(pick_id, "foreign_job"),
		"reserving the held pick for a foreign job mid-travel must succeed")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-ordinary-route after the held tool becomes foreign-reserved: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	restored._toils.clear_trace()
	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(_find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 without ever diverting to drop_tool")
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 without ever diverting to drop_tool")
	for entry in restored._toils.trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"the restored run must never misread the already-in-flight ordinary route as a drop leg: %s" % [restored._toils.trace])

## Round 6 review (issue #266): drop_tool runs for ANY active job kind,
## including haul -- needs_drop() is unconditional on job kind, and a freshly
## activated job's colonist.route/work both start null exactly like any other
## toil boundary, so a haul job's colonist can be sent to drop_tool before its
## own first pick_up toil ever runs. The drop-leg marker must never be written
## into the job's own itemId field: for a haul job that field already IS the
## cargo's own item id (attached at submission by HaulGiver, read back by
## pick_up's item_id_for hook), and overwriting/clearing it mid-drop would
## corrupt which ground item the job is actually carrying. This drives a real
## haul job through an in-place drop (no stockpile cell within
## TOOL_DROP_RADIUS of the colonist's own position at activation) and proves
## the cargo's own itemId survives untouched on every single tick, and the
## haul job still completes and places its real cargo.
func _check_drop_tool_during_haul_job_preserves_cargo_identity_in_place() -> void:
	var world := WorldStateType.new(266040)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(axe_id, "foreign_job"),
		"reserving colonist_0's held axe for a foreign job must succeed, before any haul job even exists")
	# Zone far from colonist_0's own position (distance 20) so no cell inside
	# it ever falls within TOOL_DROP_RADIUS (5) of the drop: the axe's own
	# drop must fall back to dropping in place, not walking to a stockpile.
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 20, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	world._items["item_1"] = {"id": "item_1", "x": 10, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2

	var haul_job_id := ""
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "haul" and String(job.get("item_id", "")) == "item_1":
				haul_job_id = String(job["id"])
		if not haul_job_id.is_empty():
			break
	_expect(not haul_job_id.is_empty(), "a haul job for item_1 must be auto-submitted and activated within budget")
	if haul_job_id.is_empty():
		return

	var dropped := false
	for _i in 40:
		world.tick()
		_expect(String(_find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must always name its cargo (item_1), never the tool being dropped or empty")
		if String(world.get_tool_item(axe_id).get("location", {}).get("type", "")) == "ground":
			dropped = true
			break
	_expect(dropped, "the axe must be dropped in place within budget")

	var completed := false
	for _i in 200:
		world.tick()
		_expect(String(_find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must still name its cargo (item_1) all the way through completion")
		if String(_find_job(world, haul_job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the haul job must still complete after the in-place drop")
	var final_item: Dictionary = _wood_item(world)
	_expect(int(final_item.get("x", -1)) == 20 and int(final_item.get("y", -1)) == 0,
		"item_1 must end up placed inside the stockpile zone at (20, 0), got %s" % final_item)

## Same regression as above, but the axe's own drop must walk to a nearby
## free stockpile cell instead of dropping in place (ToolDropToil's own
## nearest-cell preference). A single zone with two cells is used so the
## haul job's own destination reservation and the axe's own drop cell can
## each take one without contesting the other -- which specific cell either
## one lands on is left unasserted (an implementation detail of two
## independent, unrelated cell searches), only that they end up on different
## cells inside the same zone, and that the cargo's own itemId survives.
func _check_drop_tool_during_haul_job_preserves_cargo_identity_via_stockpile() -> void:
	var world := WorldStateType.new(266041)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(axe_id, "foreign_job"),
		"reserving colonist_0's held axe for a foreign job must succeed, before any haul job even exists")
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 3, "y": 0, "width": 2, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	world._items["item_1"] = {"id": "item_1", "x": 10, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2

	var haul_job_id := ""
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "haul" and String(job.get("item_id", "")) == "item_1":
				haul_job_id = String(job["id"])
		if not haul_job_id.is_empty():
			break
	_expect(not haul_job_id.is_empty(), "a haul job for item_1 must be auto-submitted and activated within budget")
	if haul_job_id.is_empty():
		return

	var axe_cell: Vector2i
	var dropped := false
	for _i in 60:
		world.tick()
		_expect(String(_find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must always name its cargo (item_1), never the tool being dropped or empty")
		var location: Dictionary = world.get_tool_item(axe_id).get("location", {})
		if String(location.get("type", "")) == "stockpile":
			axe_cell = Vector2i(int(location["x"]), int(location["y"]))
			_expect(axe_cell.y == 0 and axe_cell.x in [3, 4], "the axe must land inside the zone, got %s" % [axe_cell])
			dropped = true
			break
	_expect(dropped, "the axe must be walked to a free stockpile cell and dropped there within budget")

	var completed := false
	for _i in 200:
		world.tick()
		_expect(String(_find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must still name its cargo (item_1) all the way through completion")
		if String(_find_job(world, haul_job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the haul job must still complete after the stockpile-cell drop")
	var final_item: Dictionary = _wood_item(world)
	_expect(int(final_item.get("y", -1)) == 0 and int(final_item.get("x", -1)) in [3, 4],
		"item_1 must end up placed inside the same zone, got %s" % final_item)
	_expect(not (int(final_item.get("x", -1)) == axe_cell.x and int(final_item.get("y", -1)) == axe_cell.y),
		"item_1's own cell must not be the same cell the axe was dropped on")

## Round 6 review: a save/load taken mid-way through the SAME drop_tool leg
## as above (an already-resolved path toward the stockpile cell, colonist
## still walking) must round-trip the haul job's own cargo identity, its
## own item:/cell: reservations, and reach completion identically in both the
## direct and the SaveIO-restored run -- proving the blockingJobId-based
## marker (not itemId) survives a real file round trip without corrupting
## haul state, the specific gap the previous review round's fix addressed.
func _check_save_io_round_trip_mid_drop_during_haul_job_preserves_cargo_and_completes() -> void:
	var world := WorldStateType.new(266042)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(axe_id, "foreign_job"),
		"reserving colonist_0's held axe for a foreign job must succeed, before any haul job even exists")
	# Three cells (3,0)/(4,0)/(5,0), all within TOOL_DROP_RADIUS of colonist_0's
	# own start position but far enough to require real travel: the haul
	# job's own destination reservation takes one of them at activation
	# (before the colonist ever moves), leaving at least two still free for
	# the axe's own, independent drop-cell search moments later.
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 3, "y": 0, "width": 3, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	world._items["item_1"] = {"id": "item_1", "x": 15, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2

	var haul_job_id := ""
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "haul" and String(job.get("item_id", "")) == "item_1":
				haul_job_id = String(job["id"])
		if not haul_job_id.is_empty():
			break
	_expect(not haul_job_id.is_empty(), "a haul job for item_1 must be auto-submitted and activated within budget")
	if haul_job_id.is_empty():
		return

	var midway := false
	for _i in 30:
		world.tick()
		var colonist := _find_colonist(world, "colonist_0")
		if colonist.get("route") != null and String(colonist.get("held_tool", "")) == axe_id:
			midway = true
			break
	_expect(midway, "colonist_0 must be caught mid-movement toward the axe's own drop cell (still holding it, still routing), within budget")

	var mid_job := _find_job(world, haul_job_id)
	_expect(String(mid_job.get("item_id", "")) == "item_1",
		"the haul job's own itemId must still name its cargo (item_1) while the axe's own drop leg is in flight")
	_expect(String(mid_job.get("blocking_job_id", "")) == axe_id,
		"the haul job's own blockingJobId must carry the in-flight drop-leg marker (the axe's id) while dropping")
	var cell: Vector2i = mid_job["cell"]
	_expect(world._scheduler.queue.get_reservation_table().owner("item:item_1") == haul_job_id,
		"the haul job's own cargo reservation must still be intact mid-drop")
	_expect(world._scheduler.queue.get_reservation_table().owner("cell:%d,%d" % [cell.x, cell.y]) == haul_job_id,
		"the haul job's own destination-cell reservation must still be intact mid-drop")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop during a haul job: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")
	_expect(String(_find_job(restored, haul_job_id).get("item_id", "")) == "item_1",
		"the restored haul job's own itemId must still name its cargo (item_1) right after restore")
	_expect(restored._scheduler.queue.get_reservation_table().owner("item:item_1") == haul_job_id,
		"the restored haul job's own cargo reservation must still be intact right after restore")

	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(_find_job(world, haul_job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(_find_job(restored, haul_job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run's haul job must still complete")
	_expect(restored_completed, "the SaveIO-restored run's haul job must also still complete, cargo identity intact throughout")
	var direct_item: Dictionary = world._items.get("item_1", {})
	var restored_item: Dictionary = restored._items.get("item_1", {})
	_expect(direct_item.get("x") == restored_item.get("x") and direct_item.get("y") == restored_item.get("y"),
		"item_1 must end up at the same final cell in both runs, got %s vs %s" % [direct_item, restored_item])

## Round 6 review: destroying a tool while its FOREIGN holder is still busy
## (not yet dropping it) used to leave that holder's own held_tool pointing
## at the vanished id forever -- tool_item_store.gd's set_held()/set_ground()
## both refuse to touch a colonist's held_tool once the item itself is gone
## (there is no location left for their own _clear_holder() to read), so a
## stale reference was otherwise never cleared and blocked every later pickup
## for that colonist. Two real colonists, two real jobs, same shape as
## _check_requester_waits_for_real_handover_then_completes(): colonist_0
## holds a leftover pick while busy foraging; colonist_1's dig job reserves
## that same pick and must wait -- destroyed here mid-wait, proving
## colonist_1's job releases and backs off, colonist_0's own held_tool is
## reconciled even though colonist_0 was never the failing job's own
## colonist, and colonist_0 can still pick up a genuinely new tool afterward.
func _check_destroyed_foreign_held_tool_while_waiting_reconciles_holder() -> void:
	var world := WorldStateType.new(266030)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")

	_expect(_command(world, "place_bush", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var forage_a := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a.get("ok", false), "forage_a submission must be accepted")
	var forage_a_id := String(forage_a["job_id"])

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a before the dig order below exists")

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var waiting_seen := false
	for _i in 400:
		world.tick()
		if String(_find_job(world, dig_id).get("reason", "")) == "waiting_for_tool_handover":
			waiting_seen = true
			break
	_expect(waiting_seen, "the dig job must expose reason waiting_for_tool_handover while colonist_0 still holds the pick")
	_expect(String(_find_colonist(world, "colonist_0").get("held_tool", "")) == pick_id,
		"colonist_0 must still physically hold the pick right before it is destroyed")

	world._tool_store.items.erase(pick_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, dig_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"the waiting dig job must re-queue with reason blocked_no_tool once its reserved tool is destroyed, got '%s'" % job.get("reason"))
			_expect(int(job.get("backoff_ticks", 0)) > 0,
				"the waiting dig job must re-queue with a nonzero backoff")
			break
	_expect(requeued, "the waiting dig job must re-queue within the tick budget once its reserved tool is destroyed")
	_expect(not world.is_tool_item_reserved(pick_id), "the destroyed pick's reservation must be released")
	_expect(String(_find_colonist(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0's own held_tool must be reconciled even though colonist_0 was never the failing job's own colonist")

	var forage_done := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, forage_a_id).get("status", "")) == "completed":
			forage_done = true
			break
	_expect(forage_done, "colonist_0's own forage_a job must still complete")

	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"),
		"colonist_0 must be able to hold a genuinely new tool now that its stale held_tool reference is cleared")

## Round 6 review: destroying a foreign-held reserved tool while its holder
## is actively mid-DROP (already walking toward a stockpile cell for its own
## next dispatched job, is_dropping() true) must not leave a dangling route:
## the holder's own drop-leg marker would otherwise still name the vanished
## item while held_tool no longer does, and the holder's own next-tick
## advance() would misread the stale, still-in-flight route as its ordinary
## go_to leg and arrive at the drop cell instead of its actual target.
func _check_destroyed_foreign_held_tool_mid_drop_reconciles_holder_route() -> void:
	var world := WorldStateType.new(266031)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var forage_a := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a.get("ok", false), "forage_a must be accepted")
	var forage_a_id := String(forage_a["job_id"])

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := _find_colonist(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a before the dig order below exists")

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var forage_a_done := false
	var forage_b_id := ""
	for _i in 400:
		world.tick()
		if not forage_a_done and String(_find_job(world, forage_a_id).get("status", "")) == "completed":
			forage_a_done = true
			var forage_b := _command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
			_expect(forage_b.get("ok", false), "forage_b must be accepted right as forage_a completes")
			forage_b_id = String(forage_b.get("job_id", ""))
		if not forage_b_id.is_empty():
			break
	_expect(forage_a_done, "forage_a must complete within budget")
	_expect(not forage_b_id.is_empty(), "forage_b must have been submitted once forage_a completed")

	# forage_b's own first toil is drop_tool (colonist_0's held pick is now
	# foreign-reserved by dig_1) -- caught two ticks in, still travelling.
	world.tick()
	var mid_drop := _find_colonist(world, "colonist_0")
	_expect(mid_drop.get("route") != null and String(mid_drop.get("held_tool", "")) == pick_id,
		"colonist_0 must be mid-drop-leg, still holding the pick, one tick into forage_b")
	world.tick()
	var still_travelling := _find_colonist(world, "colonist_0")
	_expect(still_travelling.get("route") != null and String(still_travelling.get("held_tool", "")) == pick_id,
		"colonist_0 must still be travelling toward the drop cell, not yet arrived")

	world._tool_store.items.erase(pick_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, dig_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"the dig job must re-queue with reason blocked_no_tool once the pick is destroyed mid-drop, got '%s'" % job.get("reason"))
			_expect(int(job.get("backoff_ticks", 0)) > 0, "the dig job must re-queue with a nonzero backoff")
			break
	_expect(requeued, "the dig job must re-queue within the tick budget once the pick is destroyed mid-drop")
	_expect(not world.is_tool_item_reserved(pick_id), "the destroyed pick's reservation must be released")

	var after_destroy := _find_colonist(world, "colonist_0")
	_expect(String(after_destroy.get("held_tool", "")) == "",
		"colonist_0's held_tool must be reconciled once its in-flight drop target is destroyed")
	_expect(after_destroy.get("route") == null,
		"colonist_0's dangling mid-drop route must be cleared, not left to be misread as its own ordinary go_to leg")

	var forage_b_done := false
	for _i in 200:
		world.tick()
		if String(_find_job(world, forage_b_id).get("status", "")) == "completed":
			forage_b_done = true
			break
	_expect(forage_b_done, "colonist_0 must still complete forage_b at its own real target, not the abandoned drop cell")
