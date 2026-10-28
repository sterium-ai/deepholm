extends "res://scripts/tests/support/rescue_base.gd"

## test_rescue_routing checks; shared helpers and the file's full description are in support/rescue_base.gd.

func _init() -> void:
	_check_unsafe_route_rejected_in_favour_of_a_safe_candidate()
	_check_no_rescue_when_every_route_crosses_the_trench()
	_check_route_rejected_when_it_crosses_an_unrelated_trench()
	_check_long_ordinary_travel_eventually_lets_a_later_candidate_win()
	_check_moving_candidate_cannot_starve_a_stationary_backup()
	_check_need_interrupt_across_the_trench_rejects_unsafe_resume()
	_check_rescue_searches_share_the_per_colonist_route_budget()
	_check_blocked_corridor_reroute_never_crosses_a_trench_and_another_rescuer_helps()
	_check_blocked_corridor_with_a_safe_detour_reroutes_without_crossing_the_trench()
	_check_target_made_impassable_retires_the_rescue_instead_of_working_off_target()
	if _failed:
		quit(1)
		return
	print("test_rescue_routing: PASS")
	quit(0)

## Regression (a reserved near-side tile): the victim's own
## nearest, cheapest adjacent tile (1, 2) is reserved by an unrelated job, so
## the only remaining target (3, 2) is a straight shot through the trench
## (2, 2) for the near candidate (0, 2) -- exactly the geometry where the
## old "restricted search proves a detour exists" scheme
## would have committed the near candidate to a route the real go_to executor
## would actually walk straight through the trench. A second, farther
## candidate (5, 2) can reach the same target safely (from the far side, never
## touching (2, 2)). The fix must reject the unsafe pairing outright and use
## the safe one instead -- never assume the near candidate's own restricted
## "detour" would really be followed.
func _check_unsafe_route_rejected_in_favour_of_a_safe_candidate() -> void:
	var world := _fresh_world(360014)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	_trap_colonist_at(world, victim, Vector2i(2, 2))
	TestAccess.set_tile(world, 2, 1, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 2, 3, WorldStateType.TILE_ROCK)
	# Reserves the near-side target directly on the shared table, exactly like
	# an unrelated job's own active tile reservation would, forcing the only
	# remaining target to (3, 2).
	TestAccess.scheduler(world).queue.get_reservation_table().acquire("tile:1,2", "blocker_job")
	var unsafe_rescuer := _spawn_colonist(world, "unsafe_rescuer", 0, 2)
	var unsafe_id: String = String(unsafe_rescuer["id"])
	var safe_rescuer := _spawn_colonist(world, "safe_rescuer", 5, 2)
	var safe_id: String = String(safe_rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "a rescue job must still be generated despite the near candidate's own route being unsafe")
	_expect(TestAccess.rescue_giver(world).colonist_for_job(String(job["id"])) == safe_id,
		"the unsafe near candidate must never be chosen; the safe far candidate must be used instead")
	_expect(job["target"] == Vector2i(3, 2), "the only remaining target must be (3, 2)")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the safe candidate must still complete the rescue")
	_expect(unsafe_rescuer.get("trapped") == null, "the rejected unsafe candidate must never actually be sent, so it never falls into the trench")
	_expect(safe_rescuer.get("trapped") == null, "the chosen safe candidate must never fall into the trench either")

## Regression (intervening trenches): the victim's trench
## (5, 0) is the only passable crossing point of an otherwise fully walled
## column x=5 -- every route from the west side to the one remaining target
## (6, 0), on the east side, must cross it. No detour exists anywhere on the
## map, unlike the previous check's own far-side candidate. The giver must
## refuse to dispatch anyone rather than send a rescuer through the trench,
## exposing REASON_NO_RESCUER_AVAILABLE exactly as if no candidate existed.
func _check_no_rescue_when_every_route_crosses_the_trench() -> void:
	var world := _fresh_world(360015)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var victim_id: String = String(victim["id"])
	_trap_colonist_at(world, victim, Vector2i(5, 0))
	TestAccess.set_tile(world, 4, 0, WorldStateType.TILE_ROCK)
	for y in range(1, world.get_map_height()):
		TestAccess.set_tile(world, 5, y, WorldStateType.TILE_ROCK)
	var rescuer := _spawn_colonist(world, "rescuer", 0, 0)
	var job := {}
	var exposed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world)
		if world.get_colonist_rescue_reason(victim_id) == "no_rescuer_available":
			exposed = true
	_expect(job.is_empty(), "no rescue job may ever be generated when every real route to every target crosses the trench")
	_expect(exposed, "WorldState must expose no_rescuer_available while every route would cross the trench")
	_expect(victim.get("trapped") != null, "the victim must stay trapped rather than be sent an unsafe rescuer")
	_expect(rescuer.get("trapped") == null, "the only candidate must never be dispatched into the trench")

## Regression (an unrelated trench on the route): the victim's trench at
## (5, 0) is not the only trench on the map. A near candidate's real route to
## the only remaining target (4, 0) crosses a completely unrelated trench at
## (2, 0) -- the old "does the path cross the victim's own tile" check let
## this through, since (2, 0) is not (5, 0). The fix must reject it and use
## the farther, genuinely safe candidate instead.
func _check_route_rejected_when_it_crosses_an_unrelated_trench() -> void:
	var world := _fresh_world(360018)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	_trap_colonist_at(world, victim, Vector2i(5, 0))
	TestAccess.set_tile(world, 6, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 5, 1, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_TRENCH)
	var unsafe_rescuer := _spawn_colonist(world, "unsafe_rescuer", 0, 0)
	var safe_rescuer := _spawn_colonist(world, "safe_rescuer", 4, 5)
	var safe_id: String = String(safe_rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "a rescue job must still be generated despite the near candidate's route crossing an unrelated trench")
	_expect(TestAccess.rescue_giver(world).colonist_for_job(String(job["id"])) == safe_id,
		"a candidate whose only route crosses a different trench than the victim's own must never be chosen")
	_expect(job["target"] == Vector2i(4, 0), "the only remaining target must be (4, 0)")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the safe candidate must still complete the rescue")
	_expect(unsafe_rescuer.get("trapped") == null, "the rejected candidate must never actually be sent, so it never falls into the unrelated trench")

## The real-travel half: a candidate doing
## a genuinely long ordinary labour job keeps moving, tile after tile, for
## far longer than a single sweep takes -- unlike
## _check_pending_rescue_preempts_ordinary_labour()'s own deliberately short
## travel, which dodges this. The bounded stale-retry counter must still let
## a later, idle candidate win instead of the search restarting forever.
func _check_long_ordinary_travel_eventually_lets_a_later_candidate_win() -> void:
	var world := _fresh_world(360019)
	var long_bound := 400
	var worker := _spawn_colonist(world, "long_travel_worker", 0, 5)
	var worker_id: String = String(worker["id"])
	# Far enough (46 of the map's 48 columns) that the remaining travel still
	# outlasts every stale-retry sweep below: each sweep's own real-route
	# search takes longer the farther the worker has already drifted, so the
	# cumulative time to exhaust MAX_STALE_RETRIES grows too -- a shorter trip
	# lets the worker simply arrive and go stationary first, legitimately (not
	# staleness) resolving the search before the retry bound is ever tested.
	TestAccess.set_tile(world, 46, 5, WorldStateType.TILE_SOIL)
	var labour_submit := TestAccess.scheduler(world).submit(Vector2i(46, 5), 1, world.get_tick(), "till", worker_id)
	_expect(labour_submit.get("ok", false), "setup: the long ordinary labour order must be accepted")
	var labour_job_id: String = String(labour_submit["job_id"])
	# Waits for the worker to be genuinely under way and far along (not merely
	# assigned, not merely "x > 0"): a rescue search that starts too early
	# converges against a nearby, barely-moved position, where each of the (up
	# to four) targets resolves in a single tick -- a 3-target sweep and this
	# actor's own 3-tick move_ticks_per_tile hold then take the exact same
	# duration, so the search spuriously reads "not stale" and legitimately
	# (not staleness) locks in the worker before its own long travel ever
	# really shows drift. Once genuinely far, each target's own route search
	# needs more than one tick, breaking that coincidental alignment.
	var traveling := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if String(TestAccess.scheduler(world).queue.get_job(labour_job_id).get("status", "")) == "active" and int(worker["x"]) >= 10:
			traveling = true
			break
	_expect(traveling, "setup: the long ordinary labour job must be genuinely under way, not merely assigned, before the trap happens")
	var backup := _spawn_colonist(world, "backup_worker", 0, 30)
	var backup_id: String = String(backup["id"])
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var job := {}
	for _i in long_bound:
		world.tick()
		job = _find_rescue_job(world, backup_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "a bounded number of stale retries must let the search move on to the idle backup candidate despite the nearer candidate's own long, continuous travel")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the backup candidate must go on to complete the rescue")

## The targeted half: a candidate whose live
## position differs every single tick (teleported here, independent of any
## real job, to make the effect deterministic rather than dependent on
## move_ticks_per_tile timing) must never indefinitely restart the search
## ahead of a later, stationary candidate.
func _check_moving_candidate_cannot_starve_a_stationary_backup() -> void:
	var world := _fresh_world(360020)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var moving := _spawn_colonist(world, "moving_candidate", 0, 5)
	var backup := _spawn_colonist(world, "backup_candidate", 0, 20)
	var backup_id: String = String(backup["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		# Strictly increasing, never repeating (clamped to stay on the map): a
		# cyclic offset can, by coincidence, land back on the exact position a
		# sweep started from once that sweep's own real-route search length
		# (itself a function of that same position) happens to consume a
		# multiple of the cycle's period many ticks -- a legitimate, non-stale
		# match at that point, just not the one this check means to force.
		# Monotonic drift can never revisit an earlier position, so the live
		# position is always provably past wherever any sweep started.
		moving["y"] = mini(5 + _i, 46)
		world.tick()
		job = _find_rescue_job(world, backup_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "a bounded number of stale retries must let the search move on to the stationary backup candidate")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		moving["y"] = mini(5 + _i, 46)
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the backup candidate must go on to complete the rescue")

## The "across the trench" half: the only
## passage across x=5 is the victim's own trench tile. A critical need whose
## only source sits on the far side is fine for the need job itself (an
## ordinary job may cross a trench), but it leaves the rescuer on the wrong
## side of the only passage for its own rescue target. Resuming must never
## blindly walk it back across; the stale commitment must be retired so a
## fresh search can find the still-safe target from the rescuer's new side.
## TestAccess.needs_system(world).interrupt_current_job()/_resume_interrupted_job() (the exact same
## wrappers a real critical need uses, see
## _check_need_interrupt_one_tile_beyond_target_requires_exact_arrival() below)
## reposition the rescuer directly rather than routing a real need job across
## the trench: any ordinary job's route stepping onto any trench tile (a
## waypoint or a target -- world_state.gd's own _check_trench_arrival(),
## a separate mechanic) unconditionally traps a colonist, so a real
## cross-trench need job would itself become a second trapped victim instead
## of landing safely on the far side. Direct repositioning isolates the one
## thing this check is about: world_state.gd's resume path revalidating route
## safety from the rescuer's actual (possibly interrupt-shifted) position,
## never trusting a commitment made from a since-vacated tile.
func _check_need_interrupt_across_the_trench_rejects_unsafe_resume() -> void:
	var world := _fresh_world(360021)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	_trap_colonist_at(world, victim, Vector2i(5, 0))
	for y in range(1, world.get_map_height()):
		TestAccess.set_tile(world, 5, y, WorldStateType.TILE_ROCK)
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 0)
	var rescuer_id: String = String(rescuer["id"])
	var job_id := ""
	var working := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if job_id.is_empty():
			var job := _find_rescue_job(world, rescuer_id)
			if not job.is_empty():
				job_id = String(job["id"])
		if not job_id.is_empty() and rescuer.get("work") != null:
			working = true
			break
	_expect(working, "setup: the rescuer must reach its own active work toil")
	_expect(TestAccess.scheduler(world).queue.get_job(job_id)["target"] == Vector2i(4, 0),
		"setup: the west-side candidate must commit to the only route that never crosses the trench")
	TestAccess.needs_system(world).interrupt_current_job(rescuer)
	rescuer["x"] = 10
	rescuer["y"] = 0
	TestAccess.needs_system(world).resume_interrupted_job(rescuer_id)
	_expect(rescuer.get("work") == null,
		"a resumed rescue whose only route back to its own stale target crosses the trench must never resume that work")
	var rescued := false
	var fresh_job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		# The stale commitment is retired through the toil executor's own
		# budgeted, multi-tick re-route (never a
		# synchronous search), so the old job id can still be pending for a
		# few ticks -- only a different rescue job counts as the fresh one.
		if fresh_job.is_empty():
			var candidate := _find_rescue_job(world, rescuer_id)
			if not candidate.is_empty() and String(candidate["id"]) != job_id:
				fresh_job = candidate
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the victim must still be rescued, via a fresh safe target, once the unsafe resumption is retired")
	_expect(String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "cancelled",
		"the unsafe stale commitment must be retired (cancelled), never walked through the trench")
	_expect(rescuer.get("trapped") == null, "the rescuer must never have fallen into the trench while re-routing")
	for key in TestAccess.progress_table(world).progress.keys():
		_expect(not String(key).begins_with(job_id + ":"), "retiring the stale rescue must drop its own job-scoped progress key")
	_expect(not fresh_job.is_empty() and fresh_job["target"] == Vector2i(6, 0),
		"the fresh target must be the east-side candidate, reachable from the rescuer's new side without crossing the trench")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(int(rescuer["x"]), int(rescuer["y"])),
		"the victim must end up on the rescuer's own tile")
	var report := ReservationInvariantsType.check(TestAccess.scheduler(world).queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "retiring an unsafe resumed rescue must leave no orphaned reservations")

## ADR 004: three victims' searches all evaluating
## the one far-away candidate on a large open map must share that colonist's
## single per-tick route allowance with the scheduler and the toil executor
## -- never one resume() per victim per tick -- while every unfinished search
## is retained across ticks and still completes; and a resumed rescue must
## re-route through the same budgeted, multi-tick search, never a search run
## to completion synchronously.
func _check_rescue_searches_share_the_per_colonist_route_budget() -> void:
	var world := _fresh_world(360029)
	var victim_a: Dictionary = TestAccess.colonists(world)[0]
	var victim_b := _spawn_colonist(world, "colonist_1", 0, 0)
	var victim_c := _spawn_colonist(world, "colonist_2", 0, 0)
	var victims: Array = [[victim_a, Vector2i(10, 12)], [victim_b, Vector2i(20, 24)], [victim_c, Vector2i(30, 36)]]
	for entry in victims:
		var victim: Dictionary = entry[0]
		var trench: Vector2i = entry[1]
		victim["x"] = trench.x - 1
		victim["y"] = trench.y
		TestAccess.set_tile(world, trench.x, trench.y, WorldStateType.TILE_TRENCH)
		TestAccess.set_tile(world, trench.x + 1, trench.y, WorldStateType.TILE_SOIL)
		var submit := TestAccess.scheduler(world).submit(Vector2i(trench.x + 1, trench.y), 1, world.get_tick(), "till", String(victim["id"]))
		_expect(submit.get("ok", false), "setup: each victim's own till submission must be accepted")
	var all_trapped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if victim_a.get("trapped") != null and victim_b.get("trapped") != null and victim_c.get("trapped") != null:
			all_trapped = true
			break
	_expect(all_trapped, "setup: all three victims must be trapped")
	var rescuer := _spawn_colonist(world, "colonist_3", 47, 47)
	var rescuer_id: String = String(rescuer["id"])
	var max_giver_resumes := 0
	var budget_shared := true
	var giver_resume_ticks := 0
	var retained_search_seen := false
	var job := {}
	for _i in 800:
		for victim_id in TestAccess.rescue_giver_searching(world).keys():
			if TestAccess.rescue_giver_searching(world)[victim_id].get("search") != null:
				retained_search_seen = true
		world.tick()
		var telemetry := TestAccess.rescue_giver(world).get_route_telemetry()
		var metrics := TestAccess.scheduler(world).get_metrics()
		for colonist_id in telemetry.keys():
			max_giver_resumes = maxi(max_giver_resumes, int(telemetry[colonist_id]))
			if int(telemetry[colonist_id]) + int((metrics.get(colonist_id, {}) as Dictionary).get("route_calls", 0)) > 1:
				budget_shared = false
		if int(telemetry.get(rescuer_id, 0)) > 0:
			giver_resume_ticks += 1
		job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "the single far candidate must eventually be committed to one of the victims")
	_expect(max_giver_resumes == 1, "RescueGiver must resume() at most once per colonist per tick even with three victims evaluating the same candidate (max %d)" % max_giver_resumes)
	_expect(budget_shared, "RescueGiver's resume() must count against the same per-colonist route allowance the scheduler spends")
	_expect(giver_resume_ticks > 3, "a far search must span several ticks of one budgeted step each (got %d)" % giver_resume_ticks)
	_expect(retained_search_seen, "an unfinished search must be retained across ticks, never restarted")
	var job_id: String = String(job["id"])
	_expect(_tick_until_job_active(world, job_id, RESCUE_TICK_BOUND), "setup: the committed rescue must activate")
	TestAccess.needs_system(world).interrupt_current_job(rescuer)
	rescuer["x"] = 47
	rescuer["y"] = 0
	TestAccess.needs_system(world).resume_interrupted_job(rescuer_id)
	var route = rescuer.get("route")
	_expect(route != null and route.get("rerouting") != null,
		"a resumed rescue far from its target must leave a retained, in-progress re-route -- never a search run to completion synchronously")
	var previous_calls := int((route["rerouting"] as Dictionary).get("resume_calls", 0)) if route != null and route.get("rerouting") != null else 0
	_expect(previous_calls <= 1, "resuming must spend at most one budgeted resume() step")
	var one_step_per_tick := true
	for _i in 20:
		world.tick()
		var live_route = rescuer.get("route")
		if live_route == null or live_route.get("rerouting") == null:
			break
		var calls := int((live_route["rerouting"] as Dictionary).get("resume_calls", 0))
		if calls - previous_calls > 1:
			one_step_per_tick = false
		previous_calls = calls
	_expect(one_step_per_tick, "the retained re-route must advance by at most one budgeted step per tick")

## Blocked travel + trench-crossing re-route +
## retiring an unreachable commitment: the only connections between the
## west and east halves of this carved map are two trench tiles. Rescuer 1
## (west) commits to the safe west-side target; a wall dropped in front of it
## mid-travel leaves no trench-free route to that target at all -- the
## unrestricted shortest re-route would now run through both trenches -- so
## the commitment must be retired (rescuer 1 never trapped, never walked
## through a trench) and rescuer 2 (east) must be chosen instead.
func _check_blocked_corridor_reroute_never_crosses_a_trench_and_another_rescuer_helps() -> void:
	var world := _fresh_world(360030)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 11):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_FLOOR)
		TestAccess.set_tile(world, x, 5, WorldStateType.TILE_FLOOR)
	for y in range(0, 6):
		TestAccess.set_tile(world, 0, y, WorldStateType.TILE_FLOOR)
		TestAccess.set_tile(world, 10, y, WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 5, 5, WorldStateType.TILE_TRENCH)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	_trap_colonist_at(world, victim, Vector2i(5, 0))
	var rescuer_1 := _spawn_colonist(world, "colonist_1", 0, 0)
	var rescuer_2 := _spawn_colonist(world, "colonist_2", 10, 0)
	var rescuer_1_id: String = String(rescuer_1["id"])
	var rescuer_2_id: String = String(rescuer_2["id"])
	var job_1 := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job_1 = _find_rescue_job(world, rescuer_1_id)
		if not job_1.is_empty():
			break
	_expect(not job_1.is_empty() and job_1["target"] == Vector2i(4, 0), "setup: rescuer 1 must commit to the west-side target (4, 0)")
	var job_1_id: String = String(job_1["id"])
	var reached_corridor := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if Vector2i(int(rescuer_1["x"]), int(rescuer_1["y"])) == Vector2i(2, 0):
			reached_corridor = true
			break
	_expect(reached_corridor, "setup: rescuer 1 must be walking the west corridor")
	TestAccess.object_table(world).set_object(3, 0, "wooden_wall")
	var retired := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		_expect(rescuer_1.get("trapped") == null, "rescuer 1 must never fall into a trench while re-routing")
		if String(TestAccess.scheduler(world).queue.get_job(job_1_id).get("status", "")) == "cancelled":
			retired = true
			break
	_expect(retired, "a rescue whose only remaining route crosses a trench must be retired, never walked")
	_expect(not _has_progress_key_for(world, job_1_id), "the retired rescue must drop its own progress key")
	_expect(TestAccess.rescue_giver(world).get_pending_job(rescuer_1_id).is_empty(), "the retired rescuer must be released")
	var rescued := false
	for _i in RESCUE_TICK_BOUND * 2:
		world.tick()
		_expect(rescuer_1.get("trapped") == null and rescuer_2.get("trapped") == null, "no rescuer may ever be trapped")
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the victim must still be rescued by the other available rescuer")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(6, 0) and Vector2i(int(rescuer_2["x"]), int(rescuer_2["y"])) == Vector2i(6, 0),
		"rescuer 2 must complete the rescue from the east-side target (6, 0)")
	var report := ReservationInvariantsType.check(TestAccess.scheduler(world).queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "retiring and re-proposing must leave no orphaned reservations")

## Blocked travel with a safe detour: a wall dropped
## in front of the rescuer mid-travel forces a re-route whose unrestricted
## shortest alternatives tie between a path through the victim's own trench
## and a trench-free one. The re-route must take the trench-free path
## (rescue's own passability treats every trench as impassable) and the
## rescue must complete with the rescuer never trapped.
func _check_blocked_corridor_with_a_safe_detour_reroutes_without_crossing_the_trench() -> void:
	var world := _fresh_world(360031)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 1, 1, WorldStateType.TILE_ROCK)
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 6)
	var rescuer_id: String = String(rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty() and job["target"] == Vector2i(0, 0), "setup: the only target left must be (0, 0)")
	var job_id: String = String(job["id"])
	var reached := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if Vector2i(int(rescuer["x"]), int(rescuer["y"])) == Vector2i(0, 3):
			reached = true
			break
	_expect(reached, "setup: the rescuer must be walking up column x=0")
	TestAccess.object_table(world).set_object(0, 2, "wooden_wall")
	TestAccess.set_tile(world, 1, 1, WorldStateType.TILE_FLOOR)
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		_expect(rescuer.get("trapped") == null, "the rescuer must never step onto the trench while detouring")
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the rescue must complete via the trench-free detour")
	_expect(String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "completed", "the same rescue job must complete (re-routed, not retired)")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(0, 0), "the victim must end up on the rescue target")

## A newly impassable target -- both while the
## commitment is still queued (activation-time path trim) and mid-travel
## (re-route-time trim): a wall on the rescue target must retire the rescue
## rather than let the ordinary impassable-target route trim start rescue
## work one tile off. With no passable neighbour left, the victim's reason
## reads "no rescuer available"; removing the wall lets a fresh rescue finish
## exactly on the target.
func _check_target_made_impassable_retires_the_rescue_instead_of_working_off_target() -> void:
	var world := _fresh_world(360032)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var victim_id: String = String(victim["id"])
	TestAccess.set_tile(world, 0, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 1, 1, WorldStateType.TILE_ROCK)
	var rescuer := _spawn_colonist(world, "colonist_1", 2, 8)
	var rescuer_id: String = String(rescuer["id"])
	var queued_job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		queued_job = _find_rescue_job(world, rescuer_id)
		if not queued_job.is_empty():
			break
	_expect(not queued_job.is_empty() and queued_job["target"] == Vector2i(2, 0), "setup: the rescue must target (2, 0)")
	_expect(String(queued_job.get("status", "")) == "queued", "setup: the commitment is still queued the tick it appears")
	var queued_job_id: String = String(queued_job["id"])
	TestAccess.object_table(world).set_object(2, 0, "wooden_wall")
	var retired_before_moving := false
	for _i in 20:
		world.tick()
		if String(TestAccess.scheduler(world).queue.get_job(queued_job_id).get("status", "")) == "cancelled":
			retired_before_moving = true
			break
	_expect(retired_before_moving, "a queued rescue whose target became impassable must be retired at activation, never trimmed to an adjacent tile")
	_expect(Vector2i(int(rescuer["x"]), int(rescuer["y"])) == Vector2i(2, 8) and rescuer.get("work") == null,
		"the rescuer must not have moved or started work toward an impassable target")
	# The victim's fresh search runs on the tick after the retirement
	# (RescueGiver.advance() precedes _advance_colonists() within a tick).
	world.tick()
	_expect(world.get_colonist_rescue_reason(victim_id) == TestAccess.rescue_giver(world).REASON_NO_RESCUER_AVAILABLE,
		"with every neighbour blocked the victim's reason must read no_rescuer_available")
	_expect(Vector2i(int(rescuer["x"]), int(rescuer["y"])) == Vector2i(2, 8), "no rescue may be re-proposed while the only target is impassable")
	TestAccess.object_table(world).set_object(2, 0, "")
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var candidate := _find_rescue_job(world, rescuer_id)
		if not candidate.is_empty() and String(candidate["id"]) != queued_job_id:
			job = candidate
			break
	_expect(not job.is_empty(), "setup: a fresh rescue must be proposed once the target is passable again")
	var job_id: String = String(job["id"])
	var mid_travel := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if Vector2i(int(rescuer["x"]), int(rescuer["y"])) == Vector2i(2, 4):
			mid_travel = true
			break
	_expect(mid_travel, "setup: the rescuer must be mid-travel toward the target")
	TestAccess.object_table(world).set_object(2, 0, "wooden_wall")
	var retired_mid_travel := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		_expect(rescuer.get("work") == null, "rescue work must never start off-target")
		if String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "cancelled":
			retired_mid_travel = true
			break
	_expect(retired_mid_travel, "a rescue whose target becomes impassable mid-travel must be retired, never trimmed to start work adjacent")
	_expect(victim.get("trapped") != null and Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(1, 0), "the victim must be untouched")
	TestAccess.object_table(world).set_object(2, 0, "")
	var rescued := false
	for _i in RESCUE_TICK_BOUND * 2:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "a fresh rescue must complete once the target is passable again")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(2, 0), "the victim must be moved exactly onto the rescue target")
