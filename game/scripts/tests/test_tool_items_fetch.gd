extends "res://scripts/tests/support/tool_items_base.gd"

## test_tool_items_fetch checks; shared helpers and the file's full description are in support/tool_items_base.gd.

func _init() -> void:
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
	_check_held_tool_skips_fetch_tool_travel()
	_check_destroyed_tool_fails_job_and_requeues_with_backoff()
	_check_destroyed_tool_during_fetch_travel_fails_and_backs_off()
	_check_destroyed_tool_among_multiple_reservations_not_first_and_unrelated_held_tool_preserved()
	_check_destroyed_fetch_target_preserves_unrelated_held_tool()
	_check_fetch_route_survives_impassable_fetch_destination_trim()

	if _failed:
		quit(1)
		return
	print("test_tool_items_fetch: PASS")
	quit(0)

## fetch_tool toil: a pick reachable of the colonist's own dig
## target lets the job run to completion through fetch_tool/reserve/go_to/
## work/release_all with no blocked_no_tool detour.
func _check_fetch_tool_success_frees_no_travel() -> void:
	var world := _build_single_dig_world(271001)
	world.spawn_ground_tool_item("pick", 0, 0)
	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "a dig job with a reachable pick must complete via fetch_tool within the tick budget")
	var colonist := world.get_colonists()[0]
	_expect(String(colonist.get("held_tool", "")) != "", "the colonist must still hold the pick after the job completes")

## blocked_no_tool: a dig job submitted where no pick exists
## anywhere exposes reason blocked_no_tool/remedy craft_or_find:pick while
## staying an ordinary queued (non-terminal) job -- exactly like any other
## blocked job ADR 004 skips (job_queue.gd's own BLOCKED_TARGET_RESERVED etc.)
## -- freeing its colonist for other work the same tick instead of terminally
## failing and resubmitting a lookalike replacement under a new id (which
## would reset its aging and make cancel_job() on the original id report
## job_already_terminal). The colonist must go on to complete a
## different, tool-free job (forage) in the same run, and the original job id
## must still be the live, cancellable order the whole time.
func _check_blocked_no_tool_frees_colonist_for_other_work() -> void:
	var world := _build_single_dig_world(271002)
	var dig_submitted := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_submitted.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_submitted.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		var dig_job := Scenarios.find_job(world, dig_id)
		if String(dig_job.get("reason", "")) == "blocked_no_tool":
			blocked = true
			_expect(String(dig_job.get("status", "")) == "queued",
				"a dig job with no pick anywhere must stay a queued, non-terminal job, got status '%s'" % dig_job.get("status"))
			_expect(String(dig_job.get("remedy", "")) == "craft_or_find:pick",
				"blocked_no_tool must carry remedy craft_or_find:pick, got '%s'" % dig_job.get("remedy"))
			break
	_expect(blocked, "a dig job with no pick anywhere must expose reason blocked_no_tool within the tick budget")

	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var forage_submitted := Scenarios.command(world, "forage_1", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_submitted.get("ok", false), "forage submission must be accepted")
	var forage_id := String(forage_submitted.get("job_id", ""))

	var forage_completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, forage_id).get("status", "")) == "completed":
			forage_completed = true
			break
	_expect(forage_completed,
		"the colonist freed from the blocked dig job must complete a different, tool-free job in the same run")

	var dig_after := Scenarios.find_job(world, dig_id)
	_expect(String(dig_after.get("status", "")) == "queued",
		"the blocked dig job must remain the same queued job the whole time, not a terminal failure replaced by a resubmission")
	var cancel_result := Scenarios.command(world, "cancel_dig", "cancel_job", {"job_id": dig_id})
	_expect(cancel_result.get("ok", false),
		"a dig job blocked on a missing tool must still be cancellable by its original id, got %s" % cancel_result)
	_expect(String(Scenarios.find_job(world, dig_id).get("status", "")) == "cancelled",
		"cancelling the blocked dig job must actually mark it cancelled")

## The "already holds a matching tool"
## fast path must actually reserve it for the new job (or refuse to treat it
## as satisfied when another job already owns that reservation), not merely
## compare item kind -- otherwise a colonist's second matching job proceeds
## unreserved and a competing job could take the tool mid-work.
func _check_held_tool_reuse_respects_other_jobs_reservation() -> void:
	var world := _build_single_dig_world(271003)
	world.spawn_ground_tool_item("pick", 0, 0)
	var dig1 := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	var dig1_id := String(dig1.get("job_id", ""))
	var completed1 := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, dig1_id).get("status", "")) == "completed":
			completed1 = true
			break
	_expect(completed1, "the first dig job must complete")
	var held_id := String(world.get_colonists()[0].get("held_tool", ""))
	_expect(held_id != "", "the colonist must still hold the pick after completing the first dig job")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"a completed job must release its own tool reservation")

	_expect(world.reserve_tool_item(held_id, "other_job"),
		"reserving the held pick for a different job must succeed")

	var dig2 := Scenarios.command(world, "dig_2", "dig", {"x": 1, "y": 0, "priority": 1})
	_expect(dig2.get("ok", false), "the second dig submission must be accepted")
	var dig2_id := String(dig2.get("job_id", ""))

	var dig2_blocked := false
	for _i in 10:
		world.tick()
		if String(Scenarios.find_job(world, dig2_id).get("reason", "")) == "blocked_no_tool":
			dig2_blocked = true
			break
	_expect(dig2_blocked,
		"a held pick already reserved by a different job must not be treated as satisfied -- the colonist must report blocked_no_tool instead of silently reusing it")

	_expect(world.release_tool_item_reservation(held_id, "other_job"), "releasing the competing reservation must succeed")

	var dig2_completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, dig2_id).get("status", "")) == "completed":
			dig2_completed = true
			break
	_expect(dig2_completed, "once the competing reservation clears, the second dig job must complete by reusing the same held pick")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the second dig job must also release its own reservation on completion")

## Pausing a dig job for a critical need
## must release its held tool's job reservation (not just its target tile
## reservation), so the tool is genuinely available to another job while this
## one is suspended; resuming must reacquire the same physically-held tool for
## free (no extra travel) since the interrupt never made the colonist drop it.
func _check_need_interrupt_releases_and_reacquires_held_tool() -> void:
	var world := WorldStateType.new(271004, 10)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	for kind in TestAccess.need_definitions(world).keys():
		if kind != "food":
			TestAccess.need_definitions(world)[kind]["rate_per_day"] = 0
	TestAccess.item_table(world).ground_berries["1_1"] = 1
	world.spawn_ground_tool_item("pick", 0, 0)

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
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

	for i in TestAccess.colonists(world).size():
		if String(TestAccess.colonists(world)[i]["id"]) == "colonist_0":
			TestAccess.colonists(world)[i]["needs"]["food"] = 5

	var interrupted := false
	for _i in 40:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "queued":
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
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "completed":
			dig_completed = true
			break
	_expect(dig_completed, "the interrupted dig job must resume and complete under the same job id")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the resumed dig job must release the reacquired tool reservation on completion")

## find_nearest_free_tool()'s nearest-first
## order must not wedge fetch_tool forever on a closer candidate that turns
## out unreachable -- a farther, genuinely reachable one must still be tried.
func _check_fetch_tool_skips_unreachable_candidate_for_farther_one() -> void:
	var world := WorldStateType.new(271005)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 7):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 6, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 2) # closer (distance 2) but walled off on every side
	world.spawn_ground_tool_item("pick", 5, 0) # farther (distance 5) but reachable along the corridor

	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 6, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 300:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"a dig job must complete by fetching the farther, reachable pick once the nearer one proves unreachable, instead of staying blocked forever")

## _exclude_fetch_candidate() must not re-enter
## _advance_fetch_tool() for the next-nearest candidate within the same tick
## -- each candidate's own go_to search already spends a route-search
## attempt, so chaining candidate after candidate in one tick could run an
## unbounded number of MeasuredRoute.resume() calls for a single colonist in
## a single tick, violating ADR 004's aggregate per-tick routing bound. With
## two nearer candidates walled off before a farther reachable one, at most
## one new fetch_tool go_to attempt ("enter" in ToilExecutor.trace) may begin
## per tick.
func _check_fetch_tool_does_not_chain_multiple_candidates_in_one_tick() -> void:
	var world := WorldStateType.new(271006)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 9):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 8, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 2) # closer (distance 2), walled off
	world.spawn_ground_tool_item("pick", 0, 3) # next-closer (distance 3), also walled off
	world.spawn_ground_tool_item("pick", 7, 0) # farthest (distance 7), reachable along the corridor

	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 8, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var previous_enters := 0
	var completed := false
	for _i in 400:
		world.tick()
		var enters := 0
		for entry in TestAccess.toils(world).trace:
			if String(entry.get("toil", "")) == "fetch_tool" and String(entry.get("phase", "")) == "enter":
				enters += 1
		_expect(enters - previous_enters <= 1,
			"at most one new fetch_tool candidate may begin its go_to search per tick, went from %d to %d entries" % [previous_enters, enters])
		previous_enters = enters
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"the dig job must still complete by eventually trying the farthest reachable pick despite two nearer unreachable candidates")

## WorldState._finish_job() must validate the terminal operation before
## releasing anything: a rejected command (e.g. complete_job against a
## still-queued, blocked_no_tool order -- JobQueue.complete() is active_only)
## must not discard the job's tool reservations while the job itself stays
## queued. blocked_no_tool's recovery lives in JobQueue's ordinary
## queued-job/backoff state (job_queue.gd's _tool_requirement_satisfied()),
## so this also proves that state survives a rejected terminal command
## untouched.
func _check_rejected_complete_job_preserves_tool_block_recovery() -> void:
	var world := _build_single_dig_world(271007)
	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("reason", "")) == "blocked_no_tool":
			blocked = true
			break
	_expect(blocked, "a dig job with no pick anywhere must expose reason blocked_no_tool within the tick budget")

	var reject_result := Scenarios.command(world, "complete_attempt", "complete_job", {"job_id": dig_id})
	_expect(not reject_result.get("ok", false),
		"complete_job against a queued (not active) blocked job must be rejected, not silently accepted")
	_expect(String(Scenarios.find_job(world, dig_id).get("status", "")) == "queued",
		"a rejected complete_job must leave the blocked job's status untouched")

	world.spawn_ground_tool_item("pick", 0, 0)
	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"a rejected complete_job against a blocked order must leave its recovery tracking intact -- supplying a tool must still reconnect and complete the same job id")

## _resume_paused_job() must not start a route toward the job target (or the
## work timer directly) before ToilExecutor's tool check runs: otherwise a
## resumed needs_tool job whose tool was taken away while paused could resume
## its work timer at the fetched tool's location instead of the job target,
## or reuse a stale job-target route as fetch_tool's own travel leg. Simulates "taken away" by directly moving the held pick to a second,
## distant colonist while colonist_0 is paused (a second colonist's own AI is
## not under test here) and asserts colonist_0's work toil is only ever
## active while it actually stands on/adjacent to the dig target, through a
## full fetch-after-interrupt cycle: reacquire (by travelling to the new
## holder), return, and complete at the original target.
func _check_interrupted_job_refetches_and_works_at_job_target_not_tool_location() -> void:
	var world := WorldStateType.new(271008, 10)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 5, "y": 5,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	for kind in TestAccess.need_definitions(world).keys():
		if kind != "food":
			TestAccess.need_definitions(world)[kind]["rate_per_day"] = 0
	TestAccess.item_table(world).ground_berries["1_1"] = 1
	world.spawn_ground_tool_item("pick", 0, 0)

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var work_started := false
	for _i in 20:
		world.tick()
		if Scenarios.colonist_by_id(world, "colonist_0").get("work") != null:
			work_started = true
			break
	_expect(work_started, "the dig job must reach its work toil (holding the pick) within budget")
	var held_id := String(Scenarios.colonist_by_id(world, "colonist_0").get("held_tool", ""))
	_expect(held_id != "", "colonist_0 must be holding the pick while working")

	for i in TestAccess.colonists(world).size():
		if String(TestAccess.colonists(world)[i]["id"]) == "colonist_0":
			TestAccess.colonists(world)[i]["needs"]["food"] = 5

	var interrupted := false
	for _i in 40:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "queued":
			interrupted = true
			break
	_expect(interrupted, "the food need must interrupt the dig job")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"suspending the dig job for a need interrupt must release its tool reservation")

	# The pick is taken away while colonist_0 is paused.
	_expect(world.set_tool_item_held(held_id, "colonist_1"),
		"moving the unreserved, paused-colonist-held pick to a second colonist must succeed")
	_expect(String(Scenarios.colonist_by_id(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0 must no longer record held_tool once the pick moves to colonist_1")

	var dig_completed := false
	for _i in 300:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("work") != null:
			var cx := int(colonist_0["x"])
			var cy := int(colonist_0["y"])
			_expect(maxi(absi(cx - 2), absi(cy - 0)) <= 1,
				"colonist_0's work toil must only run while it stands on/adjacent to the dig target (2, 0), got (%d, %d)" % [cx, cy])
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "completed":
			dig_completed = true
			break
	_expect(dig_completed,
		"the interrupted dig job must reacquire a pick (by travelling to its new holder) and complete under the same job id")
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the resumed dig job must release the reacquired tool reservation on completion")

## blocked_no_tool's recovery must go through the
## fair scheduler's ordinary labour eligibility check (GlobalAssignment's
## _is_labour_enabled(), consulted for every _waiting entry before it may ever
## be scored/activated) exactly like any other queued job, not a side-channel
## reconnect that bypasses it. Disables "mine" labour for the only colonist
## while its dig job sits blocked_no_tool, then supplies a pick: the job must
## not reactivate while labour stays disabled, even though a matching tool
## now exists -- only once labour is re-enabled does the same job (never
## replaced by a resubmission) complete.
func _check_blocked_no_tool_respects_labour_disabled() -> void:
	var world := _build_single_dig_world(271010)
	TestAccess.colonists(world)[0]["labourTable"] = {"mine": 3}
	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("reason", "")) == "blocked_no_tool":
			blocked = true
			break
	_expect(blocked, "a dig job with no pick anywhere must expose reason blocked_no_tool within the tick budget")

	_expect(Scenarios.command(world, "disable_mine", "set_labour", {"colonist": "colonist_0", "kind": "mine", "level": 0}).get("ok", false),
		"set_labour must be accepted")
	world.spawn_ground_tool_item("pick", 0, 0)

	for _i in 60:
		world.tick()
		_expect(String(Scenarios.find_job(world, dig_id).get("status", "")) != "active",
			"a dig job must not reactivate while mine labour is disabled for its only colonist, even once a pick exists")

	_expect(Scenarios.command(world, "enable_mine", "set_labour", {"colonist": "colonist_0", "kind": "mine", "level": 3}).get("ok", false),
		"set_labour must be accepted")

	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the same dig job (id %s) must complete once mine labour is re-enabled and a pick exists" % dig_id)

## dig/chop's own retry_base_ticks/retry_cap_ticks (content/jobs.json) must
## drive a backoff: otherwise an available-but-permanently-unreachable tool
## could retrigger a real route-search attempt every tick, and the colonist
## blocked on it might never be free to do other work. Isolates a pick fully enclosed by rock
## (no adjacent passable tile at all, unlike a merely-far-away one) so it can
## never be fetched: JobQueue's own activation gate only checks a matching
## tool exists (a cheap check, colonist-ai.md 2/3.3), so the job still goes
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
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 6):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	world.spawn_ground_tool_item("pick", 2, 3) # fully enclosed by rock on every side

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 5, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var first_backoff := 0
	for _i in 60:
		world.tick()
		var job := Scenarios.find_job(world, dig_id)
		if String(job.get("reason", "")) == "blocked_no_tool" and int(job.get("backoff_ticks", 0)) > 0:
			first_backoff = int(job["backoff_ticks"])
			break
	_expect(first_backoff > 0, "the dig job must expose a nonzero backoff once blocked_no_tool")

	var escalated := false
	for _i in 400:
		world.tick()
		var job := Scenarios.find_job(world, dig_id)
		_expect(String(job.get("status", "")) in ["queued", "active"],
			"a permanently blocked dig job must never terminate on its own")
		# The tool-backoff check must run before JobQueue.tick()'s
		# reachability check: otherwise a backed-off job's reservation-shortcut
		# selection feeds a stale/no-search-this-tick _can_reach() result back
		# into the same job and overwrites blocked_no_tool's reason with
		# blocked_target_unreachable for the entire backoff window, even though
		# the target itself is reachable.
		if String(job.get("status", "")) == "queued" and int(job.get("backoff_ticks", 0)) > 0:
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"a permanently-unreachable-tool dig job's reason must stay blocked_no_tool throughout its own backoff window, got '%s' at backoff_ticks=%d" % [job.get("reason", ""), job.get("backoff_ticks", 0)])
		if int(job.get("backoff_ticks", 0)) > first_backoff:
			escalated = true
			break
	_expect(escalated, "the dig job's backoff must grow across repeated blocked_no_tool cycles, not repeat forever unbounded")

	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var forage_result := Scenarios.command(world, "forage_1", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_result.get("ok", false), "forage submission must be accepted")
	var forage_id := String(forage_result.get("job_id", ""))

	var forage_completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, forage_id).get("status", "")) == "completed":
			forage_completed = true
			break
	_expect(forage_completed,
		"the colonist must complete a different, tool-free job despite the permanently blocked dig job")
	_expect(String(Scenarios.find_job(world, dig_id).get("status", "")) == "queued",
		"the permanently blocked dig job must remain the same queued job throughout, never terminated")

## The tool-backoff check must run before JobQueue.tick()'s reachability
## check (see the reason assertion in
## _check_blocked_no_tool_permanently_unreachable_tool_backs_off_and_frees_
## colonist() above for the existing-but-unreachable-tool case). This is the
## missing-tool case: a dig job with no matching tool anywhere must keep
## reporting reason blocked_no_tool/remedy craft_or_find:pick across the
## entire backoff window, not merely the tick it is first observed.
func _check_blocked_no_tool_reason_survives_backoff_window() -> void:
	var world := _build_single_dig_world(271012)
	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted even with no pick anywhere")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, dig_id)
		if String(job.get("reason", "")) == "blocked_no_tool" and int(job.get("backoff_ticks", 0)) > 0:
			blocked = true
			break
	_expect(blocked, "the dig job must expose a nonzero backoff once blocked_no_tool")

	# dig's own retry_base_ticks is 20 (content/jobs.json): 15 further ticks
	# stays safely inside the same backoff window.
	for _i in 15:
		world.tick()
		var job := Scenarios.find_job(world, dig_id)
		_expect(String(job.get("reason", "")) == "blocked_no_tool",
			"a dig job's reason must stay blocked_no_tool throughout its own backoff window, got '%s'" % job.get("reason", ""))
		_expect(String(job.get("remedy", "")) == "craft_or_find:pick",
			"a dig job's remedy must stay craft_or_find:pick throughout its own backoff window, got '%s'" % job.get("remedy", ""))

## WorldState._toil_on_no_tool_found() must requeue through
## GlobalAssignment.requeue_assignment(), not suspend_assignment(), which pins
## the requeued job's restrict_to to the colonist whose fetch just failed --
## that would permanently bind an ordinary dig order to its first colonist
## even once that colonist's own labour is disabled and a different,
## still-eligible colonist could complete it. colonist_0 starts adjacent to the dig target
## (so it always wins the initial assignment) but the only pick anywhere is
## fully enclosed by rock (so its own fetch_tool travel leg proves it
## unreachable and triggers on_no_tool_found); colonist_0's mine labour is
## then disabled, and only once a second, genuinely reachable pick appears
## does colonist_1 -- the only colonist still eligible for "mine" -- complete
## the same order.
func _check_blocked_no_tool_failure_frees_job_for_a_different_colonist() -> void:
	var world := WorldStateType.new(271013)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 9, 9, WorldStateType.TILE_SOIL)
	TestAccess.set_tile(world, 2, 2, WorldStateType.TILE_ROCK)
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if dx != 0 or dy != 0:
				TestAccess.set_tile(world, 2 + dx, 2 + dy, WorldStateType.TILE_ROCK)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {"mine": 3},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 19, "y": 19,
		"needs": {"food": 100, "water": 100, "rest": 100}, "labourTable": {"mine": 3},
		"route": null, "work": null, "hands": [], "held_tool": ""})
	world.spawn_ground_tool_item("pick", 2, 2) # enclosed, unreachable by anyone

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 9, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var blocked := false
	for _i in 300:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("reason", "")) == "blocked_no_tool":
			blocked = true
			break
	_expect(blocked, "colonist_0's own fetch_tool attempt at the enclosed pick must eventually report blocked_no_tool")

	_expect(Scenarios.command(world, "disable_colonist0_mine", "set_labour", {"colonist": "colonist_0", "kind": "mine", "level": 0}).get("ok", false),
		"disabling colonist_0's mine labour must be accepted")
	world.spawn_ground_tool_item("pick", 5, 5) # genuinely reachable, only useful to colonist_1 now

	var completed := false
	for _i in 400:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed,
		"once colonist_0's labour is disabled, the same dig job must still complete -- via colonist_1, the only colonist still eligible -- proving the requeue was not pinned back to colonist_0")
	_expect(String(Scenarios.colonist_by_id(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0 must never pick up the new pick while its mine labour stays disabled")

## ADR 013's "Already held" fast path (satisfied() reserves
## a matching held tool for the job with no travel) proven directly against
## the execution trace, not merely inferred from "the job completed quickly".
func _check_held_tool_skips_fetch_tool_travel() -> void:
	var world := _build_single_dig_world(266001)
	var held_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(held_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	TestAccess.toils(world).clear_trace()

	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the dig job must complete")
	for entry in TestAccess.toils(world).trace:
		_expect(String(entry.get("toil", "")) != "fetch_tool",
			"a colonist already holding the matching tool must never enter/complete fetch_tool's own travel: %s" % [TestAccess.toils(world).trace])
	_expect(world.get_tool_item_reservation(held_id) == "",
		"the completed job must release the reused held tool's reservation")

## A tool a job actively holds and has reserved (satisfied(), mid
## reserve/go_to/work) must fail the job's current toil the instant it is
## destroyed/removed, release every reservation the job held, and re-queue the
## job through the same backoff mechanism as an ordinary blocked_no_tool
## failure -- proven here by supplying a fresh tool afterward and reaching
## completion under the same job id.
func _check_destroyed_tool_fails_job_and_requeues_with_backoff() -> void:
	var world := _build_single_dig_world(266004)
	world.spawn_ground_tool_item("pick", 0, 0)
	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
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
	# -- both must be released by the failure below, not just the destroyed
	# one.
	var extra_id := world.spawn_ground_tool_item("axe", 5, 5)
	_expect(world.reserve_tool_item(extra_id, job_id), "reserving a second, unrelated tool for the same job must succeed")

	# Simulate the tool being destroyed/removed out from under the active job.
	TestAccess.tool_store(world).items.erase(held_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, job_id)
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
		"every other reservation the failing job held must also be released, not just the destroyed item's")
	_expect(String(world.get_colonists()[0].get("held_tool", "")) == "",
		"the colonist must no longer record held_tool once its actively-used tool is destroyed")
	_expect(world.get_colonists()[0].get("work") == null,
		"the colonist's work toil must stop the instant its active tool is destroyed")

	# Supplying a fresh pick must let the same job id complete afterward.
	world.spawn_ground_tool_item("pick", 0, 0)
	var completed := false
	for _i in 120:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the re-queued job must still complete once a replacement tool becomes available")

## A tool destroyed while fetch_tool is still travelling toward it (reserved
## but not yet physically held) must fail the job's current toil and back off
## exactly like a destroyed held tool does --
## ToolFetchToil.advance() must not silently rescan and reserve the farther,
## still-existing candidate instead of failing.
func _check_destroyed_tool_during_fetch_travel_fails_and_backs_off() -> void:
	var world := WorldStateType.new(266006)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 9):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 8, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var near_id := world.spawn_ground_tool_item("pick", 3, 0)
	var far_id := world.spawn_ground_tool_item("pick", 7, 0)

	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 8, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		if world.get_tool_item_reservation(near_id) == job_id and String(world.get_colonists()[0].get("held_tool", "")) == "":
			travelling = true
			break
	_expect(travelling, "the dig job must reserve and start travelling toward the nearer pick within budget")
	_expect(String(Scenarios.find_job(world, job_id).get("status", "")) == "active",
		"the dig job must be active while fetch_tool is travelling")

	TestAccess.tool_store(world).items.erase(near_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, job_id)
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
		"the farther, still-existing pick must not have been silently reserved as a replacement")
	_expect(String(world.get_colonists()[0].get("held_tool", "")) == "", "the colonist must hold nothing")

	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the re-queued job must still complete by fetching the farther, surviving pick")

## active_tool_missing()/fail_for_destroyed_tool() must scan
## every reservation job_id holds, not just the first the ReservationTable
## snapshot happens to yield -- and must clear colonist.held_tool only when
## the destroyed item is the one actually held, never a surviving one, even
## when the destroyed reservation is not the job's own primary (held) tool.
func _check_destroyed_tool_among_multiple_reservations_not_first_and_unrelated_held_tool_preserved() -> void:
	var world := _build_single_dig_world(266017)
	world.spawn_ground_tool_item("pick", 0, 0)
	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var held_id := ""
	for _i in 30:
		world.tick()
		if world.get_colonists()[0].get("work") != null:
			held_id = String(world.get_colonists()[0].get("held_tool", ""))
			break
	_expect(held_id != "", "colonist_0 must be holding the pick while working")

	# A second, unrelated reservation the same job also happens to hold, not
	# yet physically held by anyone -- destroyed below, while the already-held
	# pick survives, to prove neither check depends on dictionary iteration
	# order finding the destroyed item first.
	var extra_id := world.spawn_ground_tool_item("axe", 5, 5)
	_expect(world.reserve_tool_item(extra_id, job_id), "reserving a second, unrelated tool for the same job must succeed")

	TestAccess.tool_store(world).items.erase(extra_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, job_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"a job whose non-primary reservation was destroyed must still re-queue with reason blocked_no_tool, got '%s'" % job.get("reason"))
			_expect(String(world.get_colonists()[0].get("held_tool", "")) == held_id,
				"colonist_0 must still physically hold the surviving pick -- only the unrelated destroyed reservation should have any effect")
			break
	_expect(requeued, "the dig job must re-queue within the tick budget once its non-primary reserved tool is destroyed")
	_expect(not world.is_tool_item_reserved(held_id), "the surviving pick's reservation must still be released like any other terminal transition")

## A tool destroyed while fetch_tool is still travelling toward it (reserved
## but not held) must not clear colonist.held_tool when the colonist is also
## already holding a different, unrelated tool -- that surviving item's own
## location still correctly says "held" by this colonist, and clearing
## held_tool would desync it. The axe sits far from chop_1's own job target
## so that no target-adjacency check can mask the result: the destroyed-tool
## check must run before any route interpretation regardless of geometry.
func _check_destroyed_fetch_target_preserves_unrelated_held_tool() -> void:
	var world := WorldStateType.new(266018)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 20, 0, WorldStateType.TILE_TREE)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	var axe_id := world.spawn_ground_tool_item("axe", 5, 0)

	var submitted := Scenarios.command(world, "chop_1", "chop", {"x": 20, "y": 0, "priority": 1})
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

	TestAccess.tool_store(world).items.erase(axe_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, job_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			break
	_expect(requeued, "chop_1 must re-queue within the tick budget once its in-flight fetch target is destroyed")
	_expect(String(world.get_colonists()[0].get("held_tool", "")) == pick_id,
		"colonist_0 must still hold the unrelated leftover pick -- only the destroyed axe's own reservation should have any effect")
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) == "held",
		"the surviving pick's own item record must still correctly say it is held")
	for entry in TestAccess.toils(world).trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"a destroyed in-flight fetch target must never be reinterpreted as a drop leg for the surviving leftover pick: %s" % [TestAccess.toils(world).trace])

## A fetch_tool destination trimmed one tile short by
## advance_go_to()'s own target-tile trim (the tool's own tile made
## impassable mid-travel, e.g. a wall built on it) must never be
## misclassified as a drop leg -- comparing the route's frozen destination
## against ToolFetchToil.current_target() for exact position equality would
## break on the trim. colonist_0 holds an
## unrelated leftover pick throughout, so is_dropping()'s entry gate stays
## active the whole time.
func _check_fetch_route_survives_impassable_fetch_destination_trim() -> void:
	var world := WorldStateType.new(266022)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 25, 0, WorldStateType.TILE_TREE)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	var axe_id := world.spawn_ground_tool_item("axe", 10, 0)

	var submitted := Scenarios.command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
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

	_expect(Scenarios.command(world, "wall_on_axe", "place_object", {"x": 10, "y": 0, "kind": "wooden_wall"}).get("ok", false),
		"placing a wall directly on the axe's own tile mid-travel must be accepted")

	TestAccess.toils(world).clear_trace()
	var completed := false
	for _i in 400:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "chop_1 must still complete, picking up the axe from one tile short of its now-impassable tile")
	for entry in TestAccess.toils(world).trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"a fetch_tool leg trimmed short by an impassable fetch destination must never be reinterpreted as a drop leg: %s" % [TestAccess.toils(world).trace])
