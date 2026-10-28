extends "res://scripts/tests/support/rescue_base.gd"

## test_rescue checks; shared helpers and the file's full description are in support/rescue_base.gd.

func _init() -> void:
	_check_rescue_job_auto_generated_and_completes()
	_check_critical_need_never_diverted_into_rescue()
	_check_pending_rescue_preempts_ordinary_labour()
	_check_two_victims_each_get_own_rescue_no_double_claim()
	_check_no_rescuer_available_reason_when_everyone_trapped()
	_check_rescue_content_shape()
	_check_need_preempts_an_already_active_rescue()
	_check_command_cancelled_rescue_frees_the_rescuer()
	_check_completing_rescue_frees_the_job_own_victim_not_a_shared_neighbour()
	_check_victim_death_mid_rescue_never_frees_a_different_victim()
	_check_need_interrupt_one_tile_beyond_target_requires_exact_arrival()
	_check_shared_target_suspend_resume_preserves_each_jobs_own_progress()
	_check_cancel_during_rescue_work_clears_only_its_own_progress_key()
	_check_cancel_while_suspended_clears_the_rescue_progress_key()
	_check_rescuer_death_clears_the_rescue_progress_key()
	if _failed:
		quit(1)
		return
	print("test_rescue: PASS")
	quit(0)

## When a colonist is trapped and another colonist is available, a rescue job
## is automatically generated, the rescuer routes to an adjacent (never the
## trench) tile, works 20 ticks, and the trapped colonist is moved onto the
## rescuer's tile and resumes ordinary scheduling.
func _check_rescue_job_auto_generated_and_completes() -> void:
	var world := _fresh_world(360001)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var victim_id: String = String(victim["id"])
	# Column x=0 is untouched floor, so a rescuer walking straight up it never
	# steps on the trench at (1, 0) -- proving the rescuer never falls in.
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var rescuer_id: String = String(rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "a rescue job restricted to the available colonist must be auto-generated")
	var target: Vector2i = job["target"]
	_expect(world.get_tile(target.x, target.y) != WorldStateType.TILE_TRENCH,
		"the rescue job's target must never be the trench tile itself")
	_expect(maxi(absi(target.x - 1), absi(target.y - 0)) == 1, "the rescue target must be adjacent to the victim's own trench tile")
	_expect(_tick_until_job_active(world, String(job["id"]), RESCUE_TICK_BOUND), "the committed rescue job must activate")
	var reservation_table := TestAccess.scheduler(world).queue.get_reservation_table()
	_expect(reservation_table.is_reserved("trapped:%s" % victim_id), "activating a committed rescue must acquire the trapped:<victim_id> reservation key")
	var completed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			completed = true
			break
	_expect(completed, "the trapped colonist must be freed once the rescue job completes")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(int(rescuer["x"]), int(rescuer["y"])),
		"a rescued colonist must be moved onto the rescuer's own tile")
	_expect(not reservation_table.is_reserved("trapped:%s" % victim_id), "the trapped:<victim_id> key must be released once the rescue job completes")
	var report := ReservationInvariantsType.check(reservation_table, world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "a completed rescue must leave no orphaned reservations")
	# Resumes ordinary scheduling: an unrelated labour order is now accepted and eventually assigned to the freed colonist.
	TestAccess.set_tile(world, int(victim["x"]) + 3, int(victim["y"]), WorldStateType.TILE_SOIL)
	var order := TestAccess.scheduler(world).submit(Vector2i(int(victim["x"]) + 3, int(victim["y"])), 1, world.get_tick(), "till", victim_id)
	_expect(order.get("ok", false), "the freed colonist must accept an ordinary order again")
	var resumed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var assignment = TestAccess.scheduler(world).get_assignments().get(victim_id)
		if assignment != null and String(assignment["job_id"]) == String(order["job_id"]):
			resumed = true
			break
	_expect(resumed, "the freed colonist must re-enter the fair scheduler's own pool like any other idle colonist")

## A colonist with its own critical need is never diverted into a
## rescue. The only other colonist is busy committing to (then pursuing) a
## critical food need; while that is true, RescueGiver must never pick it,
## exposing REASON_NO_RESCUER_AVAILABLE on the victim instead. Once the need
## resolves, the same colonist becomes available and completes the rescue.
func _check_critical_need_never_diverted_into_rescue() -> void:
	var world := _fresh_world(360002)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var victim_id: String = String(victim["id"])
	var candidate := _spawn_colonist(world, "colonist_1", 0, 5)
	var candidate_id: String = String(candidate["id"])
	candidate["needs"]["food"] = 5 # below every need kind's own "critical" threshold (needs.json)
	# Far enough that the resulting eat_food job stays pending across several
	# ticks (observable by this test's own post-tick polling below), rather
	# than committing and resolving within a single internal tick() call.
	TestAccess.item_table(world).ground_berries["0_20"] = 1
	for kind in TestAccess.need_definitions(world).keys():
		if kind != "food":
			TestAccess.need_definitions(world)[kind]["rate_per_day"] = 0
	var need_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		need_job_id = TestAccess.need_giver(world).get_pending_job(candidate_id)
		_expect(_find_rescue_job(world, candidate_id).is_empty(),
			"a colonist committed to its own critical need must never be proposed the rescue job")
		if not need_job_id.is_empty():
			break
	_expect(not need_job_id.is_empty(), "setup: the candidate's own critical food need must commit a real eat_food job first")
	_expect(world.get_colonist_rescue_reason(victim_id) == "no_rescuer_available",
		"while the only other colonist is busy with its own critical need, the trapped colonist must expose no_rescuer_available")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the candidate must go on to complete the rescue once its own critical need is satisfied")

## An ordinary labour job is pre-empted by a pending rescue the
## same way a need job pre-empts it.
func _check_pending_rescue_preempts_ordinary_labour() -> void:
	var world := _fresh_world(360003)
	var worker := _spawn_colonist(world, "colonist_1", 10, 0)
	var worker_id: String = String(worker["id"])
	# Short: the worker quickly arrives and spends its own 30-tick work timer
	# stationary, active but never travelling, giving the rescue search a
	# stable position to converge against well within that window (the
	# rescue search always re-validates against the
	# candidate's live position once a full sweep finishes, see
	# rescue_giver.gd's _advance_search() -- a candidate still travelling the
	# whole time never lets a distance-scaling sweep finish before it moves
	# again, so this deliberately keeps travel short instead of long).
	TestAccess.set_tile(world, 10, 2, WorldStateType.TILE_SOIL)
	var labour_submit := TestAccess.scheduler(world).submit(Vector2i(10, 2), 1, world.get_tick(), "till", worker_id)
	_expect(labour_submit.get("ok", false), "setup: the ordinary labour order must be accepted")
	var labour_job_id: String = String(labour_submit["job_id"])
	var labour_active := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if String(TestAccess.scheduler(world).queue.get_job(labour_job_id).get("status", "")) == "active":
			labour_active = true
			break
	_expect(labour_active, "setup: the ordinary labour job must be active before the trap happens")
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var preempted := false
	var rescue_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var job := _find_rescue_job(world, worker_id)
		if not job.is_empty():
			rescue_job_id = String(job["id"])
			preempted = true
			break
	_expect(preempted, "a pending rescue must pre-empt the worker's own ordinary labour job")
	_expect(String(TestAccess.scheduler(world).queue.get_job(labour_job_id).get("status", "")) == "queued",
		"the pre-empted labour job must go back to queued, aging preserved, not be cancelled outright")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "setup: the rescue must still complete")
	var resumed_labour := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if String(TestAccess.scheduler(world).queue.get_job(labour_job_id).get("status", "")) == "active":
			resumed_labour = true
			break
	_expect(resumed_labour, "the worker must resume its own pre-empted labour job once the rescue completes")

## Two colonists trapped at once each get their own rescue job (no
## double-claim of one victim), verified via the trapped:<colonist_id>
## reservation key.
func _check_two_victims_each_get_own_rescue_no_double_claim() -> void:
	var world := _fresh_world(360004)
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_TRENCH)
	TestAccess.set_tile(world, 1, 10, WorldStateType.TILE_TRENCH)
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_SOIL)
	TestAccess.set_tile(world, 2, 10, WorldStateType.TILE_SOIL)
	var victim_a: Dictionary = TestAccess.colonists(world)[0]
	var victim_b := _spawn_colonist(world, "colonist_1", 0, 10)
	var rescuer_a := _spawn_colonist(world, "colonist_2", 0, 5)
	var rescuer_b := _spawn_colonist(world, "colonist_3", 0, 15)
	var submit_a := TestAccess.scheduler(world).submit(Vector2i(2, 0), 1, world.get_tick(), "till", String(victim_a["id"]))
	var submit_b := TestAccess.scheduler(world).submit(Vector2i(2, 10), 1, world.get_tick(), "till", String(victim_b["id"]))
	_expect(submit_a.get("ok", false) and submit_b.get("ok", false), "setup: both till submissions must be accepted")
	var both_trapped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if victim_a.get("trapped") != null and victim_b.get("trapped") != null:
			both_trapped = true
			break
	_expect(both_trapped, "setup: both colonists must become trapped")
	var job_a := {}
	var job_b := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job_a = _find_rescue_job(world, String(rescuer_a["id"]))
		job_b = _find_rescue_job(world, String(rescuer_b["id"]))
		if not job_a.is_empty() and not job_b.is_empty():
			break
	_expect(not job_a.is_empty() and not job_b.is_empty(), "each trapped colonist must get its own rescue job")
	_expect(String(job_a["id"]) != String(job_b["id"]), "the two rescue jobs must be distinct")
	_expect(_tick_until_job_active(world, String(job_a["id"]), RESCUE_TICK_BOUND) and _tick_until_job_active(world, String(job_b["id"]), RESCUE_TICK_BOUND),
		"both committed rescue jobs must activate")
	var reservation_table := TestAccess.scheduler(world).queue.get_reservation_table()
	_expect(reservation_table.is_reserved("trapped:%s" % String(victim_a["id"])), "victim A's own trapped: key must be reserved")
	_expect(reservation_table.is_reserved("trapped:%s" % String(victim_b["id"])), "victim B's own trapped: key must be reserved")
	_expect(reservation_table.owner("trapped:%s" % String(victim_a["id"])) != reservation_table.owner("trapped:%s" % String(victim_b["id"])),
		"the two trapped: keys must be owned by two different jobs -- no double-claim of one victim")
	var both_rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim_a.get("trapped") == null and victim_b.get("trapped") == null:
			both_rescued = true
			break
	_expect(both_rescued, "both trapped colonists must eventually be freed")

## When every colonist is trapped, WorldState exposes a reason a
## panel can render as "no one can help" rather than leaving the situation
## unexplained. The only colonist in the world is trapped, so RescueGiver's
## own candidate pool is empty by construction.
func _check_no_rescuer_available_reason_when_everyone_trapped() -> void:
	var world := _fresh_world(360005)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var victim_id: String = String(victim["id"])
	var exposed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if world.get_colonist_rescue_reason(victim_id) == "no_rescuer_available":
			exposed = true
			break
	_expect(exposed, "when no rescuer candidate exists at all, WorldState must expose no_rescuer_available for the trapped colonist")
	for _i in 20:
		world.tick()
	_expect(victim.get("trapped") != null, "with nobody to rescue it, the colonist must stay trapped -- no auto-rescue")

## content/jobs.json's own "rescue" entry, reusing the
## existing toil vocabulary with no toil_executor.gd change.
func _check_rescue_content_shape() -> void:
	var world := _fresh_world(360006)
	var job_def: Dictionary = TestAccess.content(world).get_entry("jobs", "rescue")
	_expect(not job_def.is_empty(), "content/jobs.json must declare a 'rescue' job kind")
	_expect(job_def.get("toils", []) == ["reserve", "go_to", "work", "release_all"],
		"rescue must reuse the exact reserve/go_to/work/release_all toil sequence")
	_expect(int(job_def.get("work_ticks", -1)) == 20, "rescue's work_ticks must be 20")

## A rescuer's own later-arising critical need must
## still take precedence over an already-active rescue, suspending it exactly
## like it would any ordinary work, and the rescue must resume once the need
## is satisfied. Exercises _committed_jobs()'s merge order directly: under
## the bug, rescue's entry overwrote need's for the same actor, so the
## scheduler kept trying to reactivate the (suspended) rescue job every tick
## and the need job could never actually be scheduled at all.
func _check_need_preempts_an_already_active_rescue() -> void:
	var world := _fresh_world(360007)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var rescuer_id: String = String(rescuer["id"])
	var rescue_job_id := ""
	var working := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if rescue_job_id.is_empty():
			var job := _find_rescue_job(world, rescuer_id)
			if not job.is_empty():
				rescue_job_id = String(job["id"])
		if not rescue_job_id.is_empty() and rescuer.get("work") != null:
			working = true
			break
	_expect(working, "setup: the rescuer must reach the rescue job's own active work toil")
	# Below every need kind's own "critical" threshold (needs.json), every
	# other need's decay disabled so only food can ever interrupt, and a real
	# ground-berries source so the search actually commits instead of failing
	# immediately and resuming the rescue unchanged the same tick (mirrors
	# _check_critical_need_never_diverted_into_rescue()'s own setup).
	rescuer["needs"]["food"] = 5
	for kind in TestAccess.need_definitions(world).keys():
		if kind != "food":
			TestAccess.need_definitions(world)[kind]["rate_per_day"] = 0
	TestAccess.item_table(world).ground_berries["0_20"] = 1
	var need_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		need_job_id = TestAccess.need_giver(world).get_pending_job(rescuer_id)
		if not need_job_id.is_empty():
			break
	_expect(not need_job_id.is_empty(), "the rescuer's own critical need must interrupt its already-active rescue")
	_expect(String(TestAccess.scheduler(world).queue.get_job(rescue_job_id).get("status", "")) == "queued",
		"the interrupted rescue job must go back to queued, aging preserved, not be cancelled")
	_expect(TestAccess.rescue_giver(world).get_pending_job(rescuer_id) == rescue_job_id,
		"the rescuer must stay associated with the same rescue job while its own need is pursued")
	var need_resolved := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if TestAccess.need_giver(world).get_pending_job(rescuer_id).is_empty():
			need_resolved = true
			break
	_expect(need_resolved, "the rescuer's own critical need must actually be scheduled and resolved, not starved by a stale rescue commitment forcing the scheduler back onto the suspended rescue job every tick")
	var rescue_resumed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if String(TestAccess.scheduler(world).queue.get_job(rescue_job_id).get("status", "")) == "active":
			rescue_resumed = true
			break
	_expect(rescue_resumed, "the rescue must resume once the rescuer's own need is satisfied")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the rescue must still complete once resumed")

## Cancelling a rescue job through the ordinary
## command path (_apply_job_command()) must tell RescueGiver its association
## resolved, exactly like it already tells NeedGiver (_resolve_giver_association())
## -- otherwise the rescuer stays permanently "pending" on a job that is no
## longer queued or active, and _committed_jobs() keeps forcing the scheduler
## to try (and fail) to reactivate it forever, starving the rescuer of any
## other work.
func _check_command_cancelled_rescue_frees_the_rescuer() -> void:
	var world := _fresh_world(360008)
	_trap_colonist_0(world)
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var rescuer_id: String = String(rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "setup: a rescue job restricted to the rescuer must be generated")
	var job_id: String = String(job["id"])
	var cancel_result := world.apply({"actor": "test", "command_id": "cancel_rescue_command_boundary",
		"tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": job_id}})
	_expect(cancel_result.get("ok", false), "cancelling the rescue job through the command boundary must be accepted")
	_expect(TestAccess.rescue_giver(world).get_pending_job(rescuer_id).is_empty(),
		"cancelling a rescue job through a command must clear RescueGiver's own association for the rescuer")
	TestAccess.set_tile(world, int(rescuer["x"]) + 3, int(rescuer["y"]), WorldStateType.TILE_SOIL)
	var order := TestAccess.scheduler(world).submit(Vector2i(int(rescuer["x"]) + 3, int(rescuer["y"])), 1, world.get_tick(), "till", rescuer_id)
	_expect(order.get("ok", false), "setup: an ordinary order restricted to the freed rescuer must be accepted")
	var scheduled := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var assignment = TestAccess.scheduler(world).get_assignments().get(rescuer_id)
		if assignment != null and String(assignment["job_id"]) == String(order["job_id"]):
			scheduled = true
			break
	_expect(scheduled, "the freed rescuer must be able to take ordinary work again, not stay stuck on the cancelled rescue job's own stale RescueGiver association")

## world_state.gd's own rescue completion effect
## must free the victim this specific job actually committed to, never merely
## "the first trapped colonist adjacent to the target" -- two different
## trenches can each be cardinally adjacent to the very same free tile.
## Victim A's own trench (1,0) and victim B's own trench (3,0) are both
## adjacent to (2,0). Victim A is trapped first, with no rescuer of its own
## anywhere in the world yet -- if it were trapped afterward instead, it
## would itself be a perfectly ordinary, idle candidate colonist and could be
## picked as victim B's own rescuer, which is not what this test means to
## exercise. Victim B's own rescue (forced to target the shared tile (2,0) by
## blocking its other neighbours once B is already trapped) is the one that
## completes; victim A is left with no rescuer at all (the only other
## colonist, rescuer_b, is already pending on victim B's job by the time
## victim A's own search ever sees it as a candidate) and stays trapped
## throughout. Under the old "scan _colonists for the first adjacent trapped
## colonist" bug, victim A -- earlier in the colonist array, still trapped,
## still adjacent to (2,0) -- would have been wrongly freed instead of
## victim B when victim B's job completed.
func _check_completing_rescue_frees_the_job_own_victim_not_a_shared_neighbour() -> void:
	var world := _fresh_world(360011)
	var victim_a: Dictionary = TestAccess.colonists(world)[0]
	var victim_a_id: String = String(victim_a["id"])
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_TRENCH)
	var submit_a := TestAccess.scheduler(world).submit(Vector2i(5, 0), 1, world.get_tick(), "till", victim_a_id)
	_expect(submit_a.get("ok", false), "setup: victim A's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_a, TRAP_TICK_BOUND), "setup: victim A must become trapped")
	TestAccess.set_tile(world, 3, 0, WorldStateType.TILE_TRENCH)
	_fence_victim_b_lane(world)
	var victim_b := _spawn_colonist(world, "colonist_1", 6, 0)
	var victim_b_id: String = String(victim_b["id"])
	var submit_b := TestAccess.scheduler(world).submit(Vector2i(2, 0), 1, world.get_tick(), "till", victim_b_id)
	_expect(submit_b.get("ok", false), "setup: victim B's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_b, TRAP_TICK_BOUND), "setup: victim B must become trapped")
	_expect(Vector2i(int(victim_b["x"]), int(victim_b["y"])) == Vector2i(3, 0), "setup: victim B must be trapped at (3, 0)")
	# Only blocked now, after victim B's own approach already crossed both
	# tiles -- forces victim B's rescue target to the shared tile (2, 0),
	# its only remaining passable, non-trench neighbour.
	TestAccess.set_tile(world, 4, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 3, 1, WorldStateType.TILE_ROCK)
	var rescuer_b := _spawn_colonist(world, "colonist_2", 2, 5)
	var rescuer_b_id: String = String(rescuer_b["id"])
	var job_b := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job_b = _find_rescue_job(world, rescuer_b_id)
		if not job_b.is_empty():
			break
	_expect(not job_b.is_empty(), "setup: victim B's own rescue job must be generated")
	_expect(job_b["target"] == Vector2i(2, 0),
		"setup: victim B's own rescue target must be forced to the shared tile (2, 0)")
	var b_rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim_b.get("trapped") == null:
			b_rescued = true
			break
	_expect(b_rescued, "victim B's own rescue must complete")
	_expect(Vector2i(int(victim_b["x"]), int(victim_b["y"])) == Vector2i(int(rescuer_b["x"]), int(rescuer_b["y"])),
		"victim B must be moved onto its own rescuer's tile")
	_expect(victim_a.get("trapped") != null,
		"victim A, merely adjacent to the same shared target tile, must never be freed by victim B's own rescue job")
	_expect(Vector2i(int(victim_a["x"]), int(victim_a["y"])) == Vector2i(1, 0),
		"victim A must stay exactly where it was trapped, untouched by victim B's rescue")

## Victim B dies (is fully removed, not merely
## un-trapped) while its own rescue job is still active. The completion
## effect must treat this as an obsolete rescue -- resolved through the
## ordinary cleanup boundary, never substituting a different, merely-adjacent
## trapped colonist. Reuses the shared-target geometry from
## _check_completing_rescue_frees_the_job_own_victim_not_a_shared_neighbour():
## victim A (1, 0) is cardinally adjacent to the same target tile (2, 0) job_b
## is using, so the old "scan for the first adjacent trapped colonist"
## fallback would have wrongly freed A when B's job finished.
func _check_victim_death_mid_rescue_never_frees_a_different_victim() -> void:
	var world := _fresh_world(360016)
	var victim_a: Dictionary = TestAccess.colonists(world)[0]
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_TRENCH)
	var submit_a := TestAccess.scheduler(world).submit(Vector2i(5, 0), 1, world.get_tick(), "till", String(victim_a["id"]))
	_expect(submit_a.get("ok", false), "setup: victim A's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_a, TRAP_TICK_BOUND), "setup: victim A must become trapped")
	TestAccess.set_tile(world, 3, 0, WorldStateType.TILE_TRENCH)
	_fence_victim_b_lane(world)
	var victim_b := _spawn_colonist(world, "colonist_1", 6, 0)
	var victim_b_id: String = String(victim_b["id"])
	var submit_b := TestAccess.scheduler(world).submit(Vector2i(2, 0), 1, world.get_tick(), "till", victim_b_id)
	_expect(submit_b.get("ok", false), "setup: victim B's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_b, TRAP_TICK_BOUND), "setup: victim B must become trapped")
	TestAccess.set_tile(world, 4, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 3, 1, WorldStateType.TILE_ROCK)
	var rescuer_b := _spawn_colonist(world, "colonist_2", 2, 5)
	var rescuer_b_id: String = String(rescuer_b["id"])
	var job_b := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job_b = _find_rescue_job(world, rescuer_b_id)
		if not job_b.is_empty():
			break
	_expect(not job_b.is_empty(), "setup: victim B's own rescue job must be generated")
	var job_b_id: String = String(job_b["id"])
	var working := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if rescuer_b.get("work") != null:
			working = true
			break
	_expect(working, "setup: rescuer B must reach its own active work toil before victim B dies")
	TestAccess.combat_system(world).apply_actor_death(victim_b)
	var completed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if String(TestAccess.scheduler(world).queue.get_job(job_b_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "victim B's own rescue job must still resolve to completion through the ordinary cleanup boundary")
	_expect(victim_a.get("trapped") != null, "victim A must never be freed by victim B's own (now-obsolete) rescue job")
	_expect(Vector2i(int(victim_a["x"]), int(victim_a["y"])) == Vector2i(1, 0), "victim A must stay exactly where it was trapped")
	_expect(TestAccess.rescue_giver(world).get_pending_job(rescuer_b_id).is_empty(), "rescuer B must be freed once its own obsolete rescue resolves")
	var report := ReservationInvariantsType.check(TestAccess.scheduler(world).queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "a rescue job whose victim died must leave no orphaned reservations")

## The "one tile beyond" half: lands the
## rescuer diagonally adjacent to its own rescue target -- Chebyshev-adjacent
## (distance 1) but not the exact tile RescueGiver's own commit-time search
## verified safe. Uses WorldState's own interrupt/resume wrappers directly
## (the same ones a critical need already uses) to pin the exact position
## deterministically, rather than depend on exactly where an eat_food job's
## own consume toil happens to leave the colonist.
func _check_need_interrupt_one_tile_beyond_target_requires_exact_arrival() -> void:
	var world := _fresh_world(360022)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	_trap_colonist_at(world, victim, Vector2i(2, 0))
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 2, 1, WorldStateType.TILE_ROCK)
	var rescuer := _spawn_colonist(world, "colonist_1", 3, 5)
	var rescuer_id: String = String(rescuer["id"])
	var job := {}
	var working := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if job.is_empty():
			job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty() and rescuer.get("work") != null:
			working = true
			break
	_expect(working, "setup: the rescuer must reach its own active work toil")
	_expect(job["target"] == Vector2i(3, 0), "setup: the only remaining target must be (3, 0)")
	TestAccess.needs_system(world).interrupt_current_job(rescuer)
	rescuer["x"] = 4
	rescuer["y"] = 1
	TestAccess.needs_system(world).resume_interrupted_job(rescuer_id)
	_expect(rescuer.get("work") == null,
		"a rescuer merely Chebyshev-adjacent (not exactly on) the target must never start rescue work")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the rescuer must still travel the remaining step and complete the rescue")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(int(rescuer["x"]), int(rescuer["y"])),
		"the victim must end up on the rescuer's own tile")

## Rescue A is suspended mid-work with real
## leftover progress; rescue B, a different victim sharing the same target
## tile, activates on the freed tile and runs to completion; rescue A then
## resumes. Each job's own progress must survive untouched by the other's --
## proven through _get_work_progress() directly (never through colonist.work,
## which decrements the very same tick it restarts, off by one from the
## value _work_progress_key() actually restores). The interrupt/resume comes
## from a real critical need (mirrors _check_need_preempts_an_already_active_rescue()'s
## own setup) rather than calling TestAccess.needs_system(world).interrupt_current_job() directly:
## nothing else would then occupy rescuer A's own committed-assignment slot,
## so _committed_jobs() would keep re-proposing job A for it every tick and
## GlobalAssignment would reactivate it again the very next tick, undoing the
## interrupt before victim B's own search ever got a chance to run.
func _check_shared_target_suspend_resume_preserves_each_jobs_own_progress() -> void:
	var world := _fresh_world(360023)
	var victim_a: Dictionary = TestAccess.colonists(world)[0]
	var victim_a_id: String = String(victim_a["id"])
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_TRENCH)
	var submit_a := TestAccess.scheduler(world).submit(Vector2i(5, 0), 1, world.get_tick(), "till", victim_a_id)
	_expect(submit_a.get("ok", false), "setup: victim A's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_a, TRAP_TICK_BOUND), "setup: victim A must become trapped")
	TestAccess.set_tile(world, 0, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 1, 1, WorldStateType.TILE_ROCK)
	var rescuer_a := _spawn_colonist(world, "rescuer_a", 2, 5)
	var rescuer_a_id: String = String(rescuer_a["id"])
	var job_a_id := ""
	var working_a := false
	var remaining_before_interrupt := -1
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if job_a_id.is_empty():
			var job := _find_rescue_job(world, rescuer_a_id)
			if not job.is_empty():
				job_a_id = String(job["id"])
		if not job_a_id.is_empty() and rescuer_a.get("work") != null and int(rescuer_a["work"]["ticks_remaining"]) <= 15:
			working_a = true
			remaining_before_interrupt = int(rescuer_a["work"]["ticks_remaining"])
			break
	_expect(working_a, "setup: rescuer A must reach its own active work toil and make some real progress")
	_expect(TestAccess.scheduler(world).queue.get_job(job_a_id)["target"] == Vector2i(2, 0), "setup: job A's target must be the shared tile (2, 0)")

	# Column x=2 has no trench anywhere along it, so routing rescuer A south to
	# its own food source never risks the general "stepping onto any trench
	# tile traps the actor" mechanic (world_state.gd's _check_trench_arrival(),
	# a separate mechanic) the way crossing back over x=1 or x=3 would.
	rescuer_a["needs"]["food"] = 5
	for kind in TestAccess.need_definitions(world).keys():
		if kind != "food":
			TestAccess.need_definitions(world)[kind]["rate_per_day"] = 0
	TestAccess.item_table(world).ground_berries["2_20"] = 1
	var need_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if rescuer_a.get("work") != null:
			remaining_before_interrupt = int(rescuer_a["work"]["ticks_remaining"])
		need_job_id = TestAccess.need_giver(world).get_pending_job(rescuer_a_id)
		if not need_job_id.is_empty():
			break
	_expect(not need_job_id.is_empty(), "setup: rescuer A's own critical need must interrupt the active rescue")
	_expect(String(TestAccess.scheduler(world).queue.get_job(job_a_id).get("status", "")) == "queued",
		"setup: job A must be suspended, releasing the shared target's own reservation")

	var victim_b := _spawn_colonist(world, "victim_b", 6, 0)
	var victim_b_id: String = String(victim_b["id"])
	TestAccess.set_tile(world, 3, 0, WorldStateType.TILE_TRENCH)
	_fence_victim_b_lane(world)
	var submit_b := TestAccess.scheduler(world).submit(Vector2i(2, 0), 1, world.get_tick(), "till", victim_b_id)
	_expect(submit_b.get("ok", false), "setup: victim B's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_b, TRAP_TICK_BOUND), "setup: victim B must become trapped")
	TestAccess.set_tile(world, 4, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 3, 1, WorldStateType.TILE_ROCK)

	var rescuer_b := _spawn_colonist(world, "rescuer_b", 2, 10)
	var rescuer_b_id: String = String(rescuer_b["id"])
	var job_b_id := ""
	var b_started_fresh := false
	var b_rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if job_b_id.is_empty():
			var job := _find_rescue_job(world, rescuer_b_id)
			if not job.is_empty():
				job_b_id = String(job["id"])
		if not b_started_fresh and rescuer_b.get("work") != null:
			b_started_fresh = true
			_expect(int(rescuer_b["work"]["ticks_remaining"]) > remaining_before_interrupt,
				"job B must start with its own full work duration, never job A's smaller leftover")
		if not job_b_id.is_empty() and victim_b.get("trapped") == null:
			b_rescued = true
			break
	_expect(b_rescued, "setup: victim B's own rescue must run to completion while job A is suspended")
	_expect(String(TestAccess.scheduler(world).queue.get_job(job_b_id).get("status", "")) == "completed",
		"setup: job B must have actually completed, not merely started")

	var need_resolved := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if TestAccess.need_giver(world).get_pending_job(rescuer_a_id).is_empty():
			need_resolved = true
			break
	_expect(need_resolved, "setup: rescuer A's own need must be satisfied so the rescue can resume")
	# A suspended job's own progress now lives in
	# WorldState._progress_table.suspended (job-id-keyed) rather than staying
	# live under the shared tile-keyed _work_progress cache -- exactly the
	# same mechanism a suspended ordinary job now uses -- so it is only
	# re-established there once the rescuer physically arrives back at the
	# target and start_work() re-queries it (_resume_paused_rescue() defers
	# the work toil itself, see its own doc comment); "need resolved" alone
	# only means the interrupt's own consume toil finished, not that the
	# rescuer has traveled back yet.
	var work_resumed := rescuer_a.get("work") != null and String(rescuer_a["work"]["job_id"]) == job_a_id
	for _i in RESCUE_TICK_BOUND:
		if work_resumed:
			break
		world.tick()
		work_resumed = rescuer_a.get("work") != null and String(rescuer_a["work"]["job_id"]) == job_a_id
	_expect(work_resumed, "setup: rescuer A must travel back and resume its own work toil")
	# A go_to arriving straight into a work toil chains into that toil's first
	# tick the same tick (ToilExecutor.advance()'s own documented chaining),
	# so ticks_remaining may already be one below its resumed starting point
	# by the time work_resumed above is observed -- comparing against the
	# colonist's own current live value (never job B's unrelated leftover)
	# is what actually proves no cross-job corruption happened.
	var live_ticks_remaining := int(rescuer_a["work"]["ticks_remaining"])
	_expect(live_ticks_remaining <= remaining_before_interrupt and live_ticks_remaining >= remaining_before_interrupt - 1,
		"job A must resume from its own preserved progress, not restart fresh or inherit job B's leftover (got %d, expected close to %d)" % [live_ticks_remaining, remaining_before_interrupt])
	var restored_progress = TestAccess.progress_table(world).get_progress(Vector2i(2, 0))
	_expect(restored_progress != null and int(restored_progress) == live_ticks_remaining,
		"job A's cached progress must match its own current live work state, never job B's leftover or a corrupted value (got %s expected %s)" % [restored_progress, live_ticks_remaining])
	var rescued_a := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim_a.get("trapped") == null:
			rescued_a = true
			break
	_expect(rescued_a, "job A must still go on to complete the rescue")

## Cancellation during work with a paused ordinary
## job sharing the target: an ordinary worker tills the very tile a rescue
## later targets, is interrupted by a real critical need (parking its own
## progress under its own job id via _suspend_work_progress() and releasing
## the tile), then the rescue reserves that tile and starts its own work.
## Cancelling the rescue through the command boundary must drop only the
## rescue's own job-scoped key: the old owner-lookup clear ran after
## _finish_job() had already released the tile, resolved to the plain key,
## and erased the till job's parked progress instead of the rescue's.
func _check_cancel_during_rescue_work_clears_only_its_own_progress_key() -> void:
	var world := _fresh_world(360025)
	_trap_colonist_0(world)
	TestAccess.set_tile(world, 0, 0, WorldStateType.TILE_ROCK)
	TestAccess.set_tile(world, 1, 1, WorldStateType.TILE_ROCK)
	var worker := _spawn_colonist(world, "colonist_1", 2, 3)
	var worker_id: String = String(worker["id"])
	var till := TestAccess.scheduler(world).submit(Vector2i(2, 0), 1, world.get_tick(), "till", worker_id)
	_expect(till.get("ok", false), "setup: the worker's own till order on the shared tile must be accepted")
	var till_started := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if worker.get("work") != null and TestAccess.progress_table(world).progress.has("2_0"):
			till_started = true
			break
	_expect(till_started, "setup: the worker must be tilling the shared tile with parked progress")
	worker["needs"]["food"] = 5
	for kind in TestAccess.need_definitions(world).keys():
		if kind != "food":
			TestAccess.need_definitions(world)[kind]["rate_per_day"] = 0
	TestAccess.item_table(world).ground_berries["2_40"] = 1
	var interrupted := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if not TestAccess.need_giver(world).get_pending_job(worker_id).is_empty():
			interrupted = true
			break
	_expect(interrupted, "setup: the worker's own critical need must suspend its till job")
	var till_job_id: String = String(till["job_id"])
	_expect(String(TestAccess.scheduler(world).queue.get_job(till_job_id).get("status", "")) == "queued",
		"setup: the till job must be suspended, releasing the shared tile")
	# A suspended job's own progress -- till's own
	# ordinary job here included -- now lives in job-id-keyed
	# _suspended_work_progress, not under the shared tile-keyed _work_progress
	# cache (see WorldState._suspend_work_progress()'s own doc comment); this
	# is what removes the shared-tile collision risk this scenario exercises,
	# so the till job's own parked progress is checked there instead.
	var paused_progress = TestAccess.progress_table(world).suspended.get(till_job_id)
	_expect(paused_progress != null, "setup: the suspended till job must keep its progress parked under its own job id")
	_expect(not TestAccess.progress_table(world).progress.has("2_0"), "setup: the suspended till job must release the shared tile's own cache entry")
	var rescuer := _spawn_colonist(world, "colonist_2", 2, 6)
	var rescuer_id: String = String(rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty() and job["target"] == Vector2i(2, 0), "setup: the rescue must target the shared tile (2, 0)")
	var job_id: String = String(job["id"])
	var rescue_key := _tick_until_rescue_progress(world, rescuer, job_id, RESCUE_TICK_BOUND)
	_expect(not rescue_key.is_empty(), "setup: the rescue must be mid-work with progress parked under its own job-scoped key")
	_expect(TestAccess.progress_table(world).suspended.get(till_job_id) == paused_progress, "setup: rescue work must never touch the till job's own parked progress")
	var cancel := world.apply({"actor": "test", "command_id": "cancel_active_rescue_progress_key",
		"tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": job_id}})
	_expect(cancel.get("ok", false), "cancelling the active rescue through the command boundary must be accepted")
	_expect(not TestAccess.progress_table(world).progress.has(rescue_key), "cancelling an active rescue must drop its own job-scoped progress key")
	_expect(TestAccess.progress_table(world).suspended.get(till_job_id) == paused_progress,
		"cancelling an active rescue must never erase a paused ordinary job's own parked progress on the same tile")
	_expect(String(TestAccess.scheduler(world).queue.get_job(String(till["job_id"])).get("status", "")) == "queued",
		"the paused till job must be untouched by the rescue's cancellation")
	var report := ReservationInvariantsType.check(TestAccess.scheduler(world).queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "cancelling an active rescue must leave no orphaned reservations")

## Cancellation while suspended: a rescue interrupted
## mid-work keeps its progress parked under its own job id (that is what lets
## it resume with its own progress); cancelling the suspended job must drop
## that entry even though the job is no longer "active" -- nobody else can
## ever own a key that names this job id.
func _check_cancel_while_suspended_clears_the_rescue_progress_key() -> void:
	var world := _fresh_world(360026)
	_trap_colonist_0(world)
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var rescuer_id: String = String(rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "setup: a rescue job must be generated")
	var job_id: String = String(job["id"])
	var key := _tick_until_rescue_progress(world, rescuer, job_id, RESCUE_TICK_BOUND)
	_expect(not key.is_empty(), "setup: the rescue must be mid-work with parked progress")
	TestAccess.needs_system(world).interrupt_current_job(rescuer)
	_expect(String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "queued", "setup: the rescue must be suspended")
	# Suspension moves this job's own progress out
	# of _work_progress into job-id-keyed _suspended_work_progress (see
	# WorldState._suspend_work_progress()'s own doc comment), the same
	# mechanism every other suspended work-ticked kind now uses.
	_expect(not TestAccess.progress_table(world).progress.has(key), "setup: a suspended rescue releases its own tile-keyed cache entry")
	_expect(TestAccess.progress_table(world).suspended.has(job_id), "a suspended rescue keeps its own parked progress until it resumes or terminates")
	var cancel := world.apply({"actor": "test", "command_id": "cancel_suspended_rescue_progress_key",
		"tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": job_id}})
	_expect(cancel.get("ok", false), "cancelling the suspended rescue must be accepted")
	_expect(not TestAccess.progress_table(world).suspended.has(job_id), "cancelling a suspended rescue must drop its own parked progress")
	_expect(TestAccess.rescue_giver(world).get_pending_job(rescuer_id).is_empty(), "the rescuer must be freed")

## Death: the rescuer dies mid-work; its rescue is
## cancelled through the death boundary and must drop its own progress key.
func _check_rescuer_death_clears_the_rescue_progress_key() -> void:
	var world := _fresh_world(360027)
	_trap_colonist_0(world)
	var victim: Dictionary = TestAccess.colonists(world)[0]
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var rescuer_id: String = String(rescuer["id"])
	var job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job = _find_rescue_job(world, rescuer_id)
		if not job.is_empty():
			break
	_expect(not job.is_empty(), "setup: a rescue job must be generated")
	var job_id: String = String(job["id"])
	var key := _tick_until_rescue_progress(world, rescuer, job_id, RESCUE_TICK_BOUND)
	_expect(not key.is_empty(), "setup: the rescue must be mid-work with parked progress")
	TestAccess.combat_system(world).apply_actor_death(rescuer)
	_expect(String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "cancelled", "the dead rescuer's rescue must be cancelled")
	_expect(not TestAccess.progress_table(world).progress.has(key), "a rescue cancelled by its rescuer's death must drop its own job-scoped progress key")
	_expect(victim.get("trapped") != null, "the victim stays trapped -- nobody rescued it")
	_expect(TestAccess.rescue_giver(world).get_pending_job(rescuer_id).is_empty() and TestAccess.rescue_giver(world).victim_for_job(job_id).is_empty(),
		"RescueGiver must drop every association of the dead rescuer's job")
	var report := ReservationInvariantsType.check(TestAccess.scheduler(world).queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "a rescuer's death must leave no orphaned reservations")
