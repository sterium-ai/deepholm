extends "res://scripts/tests/support/tool_items_base.gd"

## test_tool_items_reservations checks; shared helpers and the file's full description are in support/tool_items_base.gd.

func _init() -> void:
	_check_reservation_lifecycle_all_terminal_paths()
	_check_reservation_released_on_real_job_commands()
	_check_reservation_released_on_natural_completion()
	_check_reservation_invariant_no_leftover_on_terminal_job()
	_check_dropping_a_reserved_tool_releases_its_reservation()

	if _failed:
		quit(1)
		return
	print("test_tool_items_reservations: PASS")
	quit(0)

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
		var submitted := Scenarios.command(world, "dig_submit", "dig", {"x": 2, "y": 0, "z": 0, "priority": 1})
		_expect(submitted.get("ok", false), "dig submission must be accepted (%s)" % command_type)
		var job_id := String(submitted.get("job_id", ""))
		_expect(job_id != "", "a real dig job_id must come back from submission (%s)" % command_type)
		world.tick()
		var item_id := world.spawn_ground_tool_item("pick", 2, 0)
		_expect(world.reserve_tool_item(item_id, job_id),
			"reserving the tool for the real dig job must succeed (%s)" % command_type)
		var result := Scenarios.command(world, "terminate", command_type, {"job_id": job_id})
		_expect(result.get("ok", false), "%s must be accepted for a real active job: %s" % [command_type, result])
		_expect(world.get_tool_item_reservation(item_id) == "",
			"%s must release the job's tool reservation automatically, not leave it dangling" % command_type)

## The same invariant must hold when a dig job finishes naturally through
## ticking (_advance_work() -> _finish_job()), a different code path than any
## command in _check_reservation_released_on_real_job_commands().
func _check_reservation_released_on_natural_completion() -> void:
	var world := _build_single_dig_world(20260919)
	var submitted := Scenarios.command(world, "dig_submit", "dig", {"x": 2, "y": 0, "z": 0, "priority": 1})
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
