extends SceneTree

## Issue #360 (ADR 025 t4): rescue_giver.gd, the job-giver that frees a
## trapped colonist. Exercises RescueGiver through real gameplay -- tripping a
## colonist into a trench, ticking the world -- never by calling private
## rescue methods directly, so the whole search -> commit -> route -> work ->
## completion pipeline is proven end to end.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const TRAP_TICK_BOUND := 100
const RESCUE_TICK_BOUND := 200

var _failed := false

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
	_check_save_load_preserves_active_rescue_continuation()
	_check_save_load_preserves_suspended_rescue_continuation()
	_check_unsafe_route_rejected_in_favour_of_a_safe_candidate()
	_check_no_rescue_when_every_route_crosses_the_trench()
	_check_victim_death_mid_rescue_never_frees_a_different_victim()
	_check_save_load_through_real_save_io_preserves_shared_target_victim_identity()
	_check_route_rejected_when_it_crosses_an_unrelated_trench()
	_check_long_ordinary_travel_eventually_lets_a_later_candidate_win()
	_check_moving_candidate_cannot_starve_a_stationary_backup()
	_check_need_interrupt_across_the_trench_rejects_unsafe_resume()
	_check_need_interrupt_one_tile_beyond_target_requires_exact_arrival()
	_check_shared_target_suspend_resume_preserves_each_jobs_own_progress()
	_check_state_hash_reflects_rescue_victim_assignment()
	_check_cancel_during_rescue_work_clears_only_its_own_progress_key()
	_check_cancel_while_suspended_clears_the_rescue_progress_key()
	_check_rescuer_death_clears_the_rescue_progress_key()
	_check_state_hash_equal_across_save_load_with_digit_boundary_rescue_ids()
	_check_rescue_searches_share_the_per_colonist_route_budget()
	_check_blocked_corridor_reroute_never_crosses_a_trench_and_another_rescuer_helps()
	_check_blocked_corridor_with_a_safe_detour_reroutes_without_crossing_the_trench()
	_check_target_made_impassable_retires_the_rescue_instead_of_working_off_target()
	if _failed:
		quit(1)
		return
	print("test_rescue: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A world with a single colonist ("colonist_0") on an all-floor map, mirroring
## test_trapped_actors.gd's own _fresh_world() (a complete needs/health/labour
## shape, so state_hash()'s own rebuild never orphans a live "trapped"
## reference this file holds across many world.tick() calls).
func _fresh_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "factionId": "colony",
		"needs": {"food": 100, "water": 100, "rest": 100},
		"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
		"route": null, "work": null, "hands": [], "held_tool": "",
		"health": {"hp": 100, "maxHp": 100, "dead": false}})
	return world

func _spawn_colonist(world: WorldStateType, id: String, x: int, y: int) -> Dictionary:
	var colonist: Dictionary = ActorTableType.spawn("colonist", x, y, world._content, id)
	colonist.erase("carrying")
	colonist["hands"] = []
	colonist["factionId"] = "colony"
	world._append_colonist(colonist)
	return colonist

func _tick_until_trapped(world: WorldStateType, colonist: Dictionary, bound: int) -> bool:
	for _i in bound:
		world.tick()
		if colonist.get("trapped") != null:
			return true
	return false

func _find_rescue_job(world: WorldStateType, restrict_to_worker: String = "") -> Dictionary:
	for job in world.get_jobs():
		if String(job.get("kind", "")) != "rescue":
			continue
		if restrict_to_worker.is_empty() or world._rescue_giver.colonist_for_job(String(job["id"])) == restrict_to_worker:
			return job
	return {}

## Ticks until job_id is "active" (bounded). A rescue commits AFTER the
## scheduler's own tick (rescue_giver.gd, "Route budget"), so its activation
## -- and with it the activation-gated trapped:<victim_id> key -- lands on a
## later tick than the one the job first appears on.
func _tick_until_job_active(world: WorldStateType, job_id: String, bound: int) -> bool:
	for _i in bound:
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "active":
			return true
		world.tick()
	return String(world._scheduler.queue.get_job(job_id).get("status", "")) == "active"

## Traps colonist_0 at (1, 0) the same way test_trapped_actors.gd's own first
## check does: a till job whose only route crosses the trench tile.
func _trap_colonist_0(world: WorldStateType) -> void:
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var colonist: Dictionary = world._colonists[0]
	var submit := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", String(colonist["id"]))
	_expect(submit.get("ok", false), "setup: till submission must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: colonist_0 must become trapped")

## Traps `colonist` at an arbitrary `trench` tile: places it one step west,
## and submits a till job one step east, so its only route crosses `trench`
## directly -- the same recipe _trap_colonist_0() uses, generalized to any
## tile for the route-safety checks below, which need the trench somewhere
## other than (1, 0).
func _trap_colonist_at(world: WorldStateType, colonist: Dictionary, trench: Vector2i) -> void:
	colonist["x"] = trench.x - 1
	colonist["y"] = trench.y
	world._tiles[world._tile_index(trench.x, trench.y)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(trench.x + 1, trench.y)] = WorldStateType.TILE_SOIL
	var submit := world._scheduler.submit(Vector2i(trench.x + 1, trench.y), 1, world.get_tick(), "till", String(colonist["id"]))
	_expect(submit.get("ok", false), "setup: till submission for the custom trap must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: colonist must become trapped at the requested tile")

## Acceptance: "when a colonist is trapped and another colonist is available, a
## rescue job is automatically generated, the rescuer routes to an adjacent
## (never the trench) tile, works 20 ticks, and the trapped colonist is moved
## onto the rescuer's tile and resumes ordinary scheduling."
func _check_rescue_job_auto_generated_and_completes() -> void:
	var world := _fresh_world(360001)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
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
	var reservation_table := world._scheduler.queue.get_reservation_table()
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
	world._tiles[world._tile_index(int(victim["x"]) + 3, int(victim["y"]))] = WorldStateType.TILE_SOIL
	var order := world._scheduler.submit(Vector2i(int(victim["x"]) + 3, int(victim["y"])), 1, world.get_tick(), "till", victim_id)
	_expect(order.get("ok", false), "the freed colonist must accept an ordinary order again")
	var resumed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var assignment = world._scheduler.get_assignments().get(victim_id)
		if assignment != null and String(assignment["job_id"]) == String(order["job_id"]):
			resumed = true
			break
	_expect(resumed, "the freed colonist must re-enter the fair scheduler's own pool like any other idle colonist")

## Acceptance: "a colonist with its own critical need is never diverted into a
## rescue." The only other colonist is busy committing to (then pursuing) a
## critical food need; while that is true, RescueGiver must never pick it,
## exposing REASON_NO_RESCUER_AVAILABLE on the victim instead. Once the need
## resolves, the same colonist becomes available and completes the rescue.
func _check_critical_need_never_diverted_into_rescue() -> void:
	var world := _fresh_world(360002)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
	var victim_id: String = String(victim["id"])
	var candidate := _spawn_colonist(world, "colonist_1", 0, 5)
	var candidate_id: String = String(candidate["id"])
	candidate["needs"]["food"] = 5 # below every need kind's own "critical" threshold (needs.json)
	# Far enough that the resulting eat_food job stays pending across several
	# ticks (observable by this test's own post-tick polling below), rather
	# than committing and resolving within a single internal tick() call.
	world._ground_berries["0_20"] = 1
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	var need_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		need_job_id = world._need_giver.get_pending_job(candidate_id)
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

## Acceptance: "an ordinary labour job is pre-empted by a pending rescue the
## same way a need job pre-empts it."
func _check_pending_rescue_preempts_ordinary_labour() -> void:
	var world := _fresh_world(360003)
	var worker := _spawn_colonist(world, "colonist_1", 10, 0)
	var worker_id: String = String(worker["id"])
	# Short: the worker quickly arrives and spends its own 30-tick work timer
	# stationary, active but never travelling, giving the rescue search a
	# stable position to converge against well within that window (round-3
	# review finding 2: the rescue search always re-validates against the
	# candidate's LIVE position once a full sweep finishes, see
	# rescue_giver.gd's _advance_search() -- a candidate still travelling the
	# whole time never lets a distance-scaling sweep finish before it moves
	# again, so this deliberately keeps travel short instead of long).
	world._tiles[world._tile_index(10, 2)] = WorldStateType.TILE_SOIL
	var labour_submit := world._scheduler.submit(Vector2i(10, 2), 1, world.get_tick(), "till", worker_id)
	_expect(labour_submit.get("ok", false), "setup: the ordinary labour order must be accepted")
	var labour_job_id: String = String(labour_submit["job_id"])
	var labour_active := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if String(world._scheduler.queue.get_job(labour_job_id).get("status", "")) == "active":
			labour_active = true
			break
	_expect(labour_active, "setup: the ordinary labour job must be active before the trap happens")
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
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
	_expect(String(world._scheduler.queue.get_job(labour_job_id).get("status", "")) == "queued",
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
		if String(world._scheduler.queue.get_job(labour_job_id).get("status", "")) == "active":
			resumed_labour = true
			break
	_expect(resumed_labour, "the worker must resume its own pre-empted labour job once the rescue completes")

## Acceptance: "two colonists trapped at once each get their own rescue job (no
## double-claim of one victim), verified via the trapped:<colonist_id>
## reservation key."
func _check_two_victims_each_get_own_rescue_no_double_claim() -> void:
	var world := _fresh_world(360004)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(1, 10)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(2, 10)] = WorldStateType.TILE_SOIL
	var victim_a: Dictionary = world._colonists[0]
	var victim_b := _spawn_colonist(world, "colonist_1", 0, 10)
	var rescuer_a := _spawn_colonist(world, "colonist_2", 0, 5)
	var rescuer_b := _spawn_colonist(world, "colonist_3", 0, 15)
	var submit_a := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", String(victim_a["id"]))
	var submit_b := world._scheduler.submit(Vector2i(2, 10), 1, world.get_tick(), "till", String(victim_b["id"]))
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
	var reservation_table := world._scheduler.queue.get_reservation_table()
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

## Acceptance: "when every colonist is trapped, WorldState exposes a reason a
## panel can render as 'no one can help' rather than leaving the situation
## unexplained." The only colonist in the world is trapped, so RescueGiver's
## own candidate pool is empty by construction.
func _check_no_rescuer_available_reason_when_everyone_trapped() -> void:
	var world := _fresh_world(360005)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
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

## content/jobs.json's own "rescue" entry (task's Owned content), reusing the
## existing toil vocabulary with no toil_executor.gd change.
func _check_rescue_content_shape() -> void:
	var world := _fresh_world(360006)
	var job_def: Dictionary = world._content.get_entry("jobs", "rescue")
	_expect(not job_def.is_empty(), "content/jobs.json must declare a 'rescue' job kind")
	_expect(job_def.get("toils", []) == ["reserve", "go_to", "work", "release_all"],
		"rescue must reuse the exact reserve/go_to/work/release_all toil sequence")
	_expect(int(job_def.get("work_ticks", -1)) == 20, "rescue's work_ticks must be 20")

## Round-2 review finding 1: a rescuer's own later-arising critical need must
## still take precedence over an already-ACTIVE rescue, suspending it exactly
## like it would any ordinary work, and the rescue must resume once the need
## is satisfied. Exercises _committed_jobs()'s merge order directly: under
## the bug, rescue's entry overwrote need's for the same actor, so the
## scheduler kept trying to reactivate the (suspended) rescue job every tick
## and the need job could never actually be scheduled at all.
func _check_need_preempts_an_already_active_rescue() -> void:
	var world := _fresh_world(360007)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
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
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	world._ground_berries["0_20"] = 1
	var need_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		need_job_id = world._need_giver.get_pending_job(rescuer_id)
		if not need_job_id.is_empty():
			break
	_expect(not need_job_id.is_empty(), "the rescuer's own critical need must interrupt its already-active rescue")
	_expect(String(world._scheduler.queue.get_job(rescue_job_id).get("status", "")) == "queued",
		"the interrupted rescue job must go back to queued, aging preserved, not be cancelled")
	_expect(world._rescue_giver.get_pending_job(rescuer_id) == rescue_job_id,
		"the rescuer must stay associated with the same rescue job while its own need is pursued")
	var need_resolved := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if world._need_giver.get_pending_job(rescuer_id).is_empty():
			need_resolved = true
			break
	_expect(need_resolved, "the rescuer's own critical need must actually be scheduled and resolved, not starved by a stale rescue commitment forcing the scheduler back onto the suspended rescue job every tick")
	var rescue_resumed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if String(world._scheduler.queue.get_job(rescue_job_id).get("status", "")) == "active":
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

## Round-2 review finding 4: cancelling a rescue job through the ordinary
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
	_expect(world._rescue_giver.get_pending_job(rescuer_id).is_empty(),
		"cancelling a rescue job through a command must clear RescueGiver's own association for the rescuer")
	world._tiles[world._tile_index(int(rescuer["x"]) + 3, int(rescuer["y"]))] = WorldStateType.TILE_SOIL
	var order := world._scheduler.submit(Vector2i(int(rescuer["x"]) + 3, int(rescuer["y"])), 1, world.get_tick(), "till", rescuer_id)
	_expect(order.get("ok", false), "setup: an ordinary order restricted to the freed rescuer must be accepted")
	var scheduled := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var assignment = world._scheduler.get_assignments().get(rescuer_id)
		if assignment != null and String(assignment["job_id"]) == String(order["job_id"]):
			scheduled = true
			break
	_expect(scheduled, "the freed rescuer must be able to take ordinary work again, not stay stuck on the cancelled rescue job's own stale RescueGiver association")

## Round-2 review finding 5: world_state.gd's own rescue completion effect
## must free the victim THIS specific job actually committed to, never merely
## "the first trapped colonist adjacent to the target" -- two different
## trenches can each be cardinally adjacent to the very same free tile.
## Victim A's own trench (1,0) and victim B's own trench (3,0) are both
## adjacent to (2,0). Victim A is trapped FIRST, with no rescuer of its own
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
	var victim_a: Dictionary = world._colonists[0]
	var victim_a_id: String = String(victim_a["id"])
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var submit_a := world._scheduler.submit(Vector2i(5, 0), 1, world.get_tick(), "till", victim_a_id)
	_expect(submit_a.get("ok", false), "setup: victim A's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_a, TRAP_TICK_BOUND), "setup: victim A must become trapped")
	world._tiles[world._tile_index(3, 0)] = WorldStateType.TILE_TRENCH
	var victim_b := _spawn_colonist(world, "colonist_1", 6, 0)
	var victim_b_id: String = String(victim_b["id"])
	var submit_b := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", victim_b_id)
	_expect(submit_b.get("ok", false), "setup: victim B's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_b, TRAP_TICK_BOUND), "setup: victim B must become trapped")
	_expect(Vector2i(int(victim_b["x"]), int(victim_b["y"])) == Vector2i(3, 0), "setup: victim B must be trapped at (3, 0)")
	# Only blocked now, after victim B's own approach already crossed both
	# tiles -- forces victim B's rescue target to the shared tile (2, 0),
	# its only remaining passable, non-trench neighbour.
	world._tiles[world._tile_index(4, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(3, 1)] = WorldStateType.TILE_ROCK
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

## Round-2 review finding 3: a save/load while a rescue job is ACTIVE (the
## rescuer already working) must not create a duplicate rescue job for the
## same victim, and the surviving job must still resume and complete
## correctly -- RescueGiver's own bookkeeping (_pending/_job_victim) is
## rebuilt fresh from already-persisted data (state_codec.gd's decode(),
## rescue_giver.gd's restore_victim_assignments()/restore_pending_assignments()),
## never carried on the wire directly.
func _check_save_load_preserves_active_rescue_continuation() -> void:
	var world := _fresh_world(360012)
	_trap_colonist_0(world)
	var victim_id: String = String(world._colonists[0]["id"])
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var rescuer_id: String = String(rescuer["id"])
	var job_id := ""
	var working := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if job_id.is_empty():
			var job := _find_rescue_job(world, rescuer_id)
			if not job.is_empty():
				job_id = String(job["id"])
		if not job_id.is_empty() and world._find_colonist(rescuer_id).get("work") != null:
			working = true
			break
	_expect(working, "setup: the rescue must reach its own active work toil before the save/load")
	var state := StateCodecType.encode(world)
	var loaded: WorldStateType = StateCodecType.decode(state)
	_expect(String(loaded._scheduler.queue.get_job(job_id).get("status", "")) == "active",
		"the rescue job must still be active immediately after load")
	_expect(loaded._rescue_giver.get_pending_job(rescuer_id) == job_id,
		"the loaded RescueGiver must still associate the rescuer with the same rescue job")
	var loaded_victim := loaded._find_colonist(victim_id)
	var completed := false
	for _i in RESCUE_TICK_BOUND:
		loaded.tick()
		if loaded_victim.get("trapped") == null:
			completed = true
			break
	_expect(completed, "the loaded world must still complete the rescue and free the victim")
	var duplicate_found := false
	for j in loaded.get_jobs():
		if String(j.get("kind", "")) == "rescue" and String(j["id"]) != job_id and String(j.get("status", "")) in ["queued", "active"]:
			duplicate_found = true
	_expect(not duplicate_found, "loading must never create a second rescue job for the same victim")

## Round-2 review finding 3, the suspended half: a save/load while a rescue
## job is SUSPENDED (its own rescuer mid a critical-need interrupt) must
## still resume and complete the same rescue after load, with no orphaned
## reservation left behind.
func _check_save_load_preserves_suspended_rescue_continuation() -> void:
	var world := _fresh_world(360013)
	_trap_colonist_0(world)
	var victim_id: String = String(world._colonists[0]["id"])
	var rescuer := _spawn_colonist(world, "colonist_1", 0, 5)
	var rescuer_id: String = String(rescuer["id"])
	var job_id := ""
	var working := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if job_id.is_empty():
			var job := _find_rescue_job(world, rescuer_id)
			if not job.is_empty():
				job_id = String(job["id"])
		if not job_id.is_empty() and world._find_colonist(rescuer_id).get("work") != null:
			working = true
			break
	_expect(working, "setup: the rescue must reach its own active work toil")
	rescuer["needs"]["food"] = 5
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	world._ground_berries["0_20"] = 1
	var need_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		need_job_id = world._need_giver.get_pending_job(rescuer_id)
		if not need_job_id.is_empty():
			break
	_expect(not need_job_id.is_empty(), "setup: the rescuer's own critical need must interrupt the rescue before the save/load")
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"setup: the rescue job must be suspended (queued) at save time")
	var state := StateCodecType.encode(world)
	var loaded: WorldStateType = StateCodecType.decode(state)
	_expect(loaded._rescue_giver.get_pending_job(rescuer_id) == job_id,
		"the loaded RescueGiver must still associate the rescuer with the suspended rescue job")
	var loaded_victim := loaded._find_colonist(victim_id)
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		loaded.tick()
		if loaded_victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the loaded world must still resume and complete the suspended rescue once the need resolves")
	var report := ReservationInvariantsType.check(loaded._scheduler.queue.get_reservation_table(), loaded.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "resuming a loaded, suspended rescue must leave no orphaned reservations")

## Round-3 review finding 2 ("a reserved near-side tile"): the victim's own
## nearest, cheapest adjacent tile (1, 2) is reserved by an unrelated job, so
## the only remaining target (3, 2) is a straight shot through the trench
## (2, 2) for the near candidate (0, 2) -- exactly the geometry the review
## named, where the old "restricted search proves a detour exists" scheme
## would have committed the near candidate to a route the real go_to executor
## would actually walk straight through the trench. A second, farther
## candidate (5, 2) CAN reach the same target safely (from the far side, never
## touching (2, 2)). The fix must reject the unsafe pairing outright and use
## the safe one instead -- never assume the near candidate's own restricted
## "detour" would really be followed.
func _check_unsafe_route_rejected_in_favour_of_a_safe_candidate() -> void:
	var world := _fresh_world(360014)
	var victim: Dictionary = world._colonists[0]
	_trap_colonist_at(world, victim, Vector2i(2, 2))
	world._tiles[world._tile_index(2, 1)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(2, 3)] = WorldStateType.TILE_ROCK
	# Reserves the near-side target directly on the shared table, exactly like
	# an unrelated job's own active tile reservation would (round-3 review's
	# own scenario), forcing the only remaining target to (3, 2).
	world._scheduler.queue.get_reservation_table().acquire("tile:1,2", "blocker_job")
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
	_expect(world._rescue_giver.colonist_for_job(String(job["id"])) == safe_id,
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

## Round-3 review finding 2 ("intervening trenches"): the victim's trench
## (5, 0) is the ONLY passable crossing point of an otherwise fully walled
## column x=5 -- every route from the west side to the one remaining target
## (6, 0), on the east side, must cross it. No detour exists anywhere on the
## map, unlike the previous check's own far-side candidate. The giver must
## refuse to dispatch anyone rather than send a rescuer through the trench,
## exposing REASON_NO_RESCUER_AVAILABLE exactly as if no candidate existed.
func _check_no_rescue_when_every_route_crosses_the_trench() -> void:
	var world := _fresh_world(360015)
	var victim: Dictionary = world._colonists[0]
	var victim_id: String = String(victim["id"])
	_trap_colonist_at(world, victim, Vector2i(5, 0))
	world._tiles[world._tile_index(4, 0)] = WorldStateType.TILE_ROCK
	for y in range(1, world.get_map_height()):
		world._tiles[world._tile_index(5, y)] = WorldStateType.TILE_ROCK
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

## Round-3 review finding 4: victim B dies (is fully removed, not merely
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
	var victim_a: Dictionary = world._colonists[0]
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var submit_a := world._scheduler.submit(Vector2i(5, 0), 1, world.get_tick(), "till", String(victim_a["id"]))
	_expect(submit_a.get("ok", false), "setup: victim A's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_a, TRAP_TICK_BOUND), "setup: victim A must become trapped")
	world._tiles[world._tile_index(3, 0)] = WorldStateType.TILE_TRENCH
	var victim_b := _spawn_colonist(world, "colonist_1", 6, 0)
	var victim_b_id: String = String(victim_b["id"])
	var submit_b := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", victim_b_id)
	_expect(submit_b.get("ok", false), "setup: victim B's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_b, TRAP_TICK_BOUND), "setup: victim B must become trapped")
	world._tiles[world._tile_index(4, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(3, 1)] = WorldStateType.TILE_ROCK
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
	world._apply_actor_death(victim_b)
	var completed := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if String(world._scheduler.queue.get_job(job_b_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "victim B's own rescue job must still resolve to completion through the ordinary cleanup boundary")
	_expect(victim_a.get("trapped") != null, "victim A must never be freed by victim B's own (now-obsolete) rescue job")
	_expect(Vector2i(int(victim_a["x"]), int(victim_a["y"])) == Vector2i(1, 0), "victim A must stay exactly where it was trapped")
	_expect(world._rescue_giver.get_pending_job(rescuer_b_id).is_empty(), "rescuer B must be freed once its own obsolete rescue resolves")
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "a rescue job whose victim died must leave no orphaned reservations")

## Round-3 review finding 3, verified through the REAL SaveIO boundary (not
## just StateCodec directly, per the reviewer's own repair decision): the
## exact shared-neighbour geometry from
## _check_completing_rescue_frees_the_job_own_victim_not_a_shared_neighbour(),
## where target-tile-plus-adjacency alone cannot tell victim A and victim B
## apart, with a COMPLETED rescue job (an unrelated, already-finished rescue)
## also present in job history alongside the ACTIVE one under test -- SaveIO
## must accept a world containing both (its job-kind allow-list must include
## "rescue"), and decode() must restore job_b's own victim association
## losslessly (never adjacency-guessed) so saving never changes who gets
## rescued.
func _check_save_load_through_real_save_io_preserves_shared_target_victim_identity() -> void:
	var world := _fresh_world(360017)
	# An unrelated, already-completed rescue, so a terminal "rescue" job is
	# present in job history at save time (SaveIO must accept it too).
	var early_victim := _spawn_colonist(world, "early_victim", 20, 20)
	_trap_colonist_at(world, early_victim, Vector2i(20, 21))
	var early_rescuer := _spawn_colonist(world, "early_rescuer", 20, 25)
	var early_rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if early_victim.get("trapped") == null:
			early_rescued = true
			break
	_expect(early_rescued, "setup: the unrelated early rescue must complete before the shared-target scenario begins")

	var victim_a: Dictionary = world._colonists[0]
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var submit_a := world._scheduler.submit(Vector2i(5, 0), 1, world.get_tick(), "till", String(victim_a["id"]))
	_expect(submit_a.get("ok", false), "setup: victim A's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_a, TRAP_TICK_BOUND), "setup: victim A must become trapped")
	world._tiles[world._tile_index(3, 0)] = WorldStateType.TILE_TRENCH
	var victim_b := _spawn_colonist(world, "colonist_1", 6, 0)
	var victim_b_id: String = String(victim_b["id"])
	var submit_b := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", victim_b_id)
	_expect(submit_b.get("ok", false), "setup: victim B's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_b, TRAP_TICK_BOUND), "setup: victim B must become trapped")
	world._tiles[world._tile_index(4, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(3, 1)] = WorldStateType.TILE_ROCK
	var rescuer_b := _spawn_colonist(world, "colonist_2", 2, 5)
	var rescuer_b_id: String = String(rescuer_b["id"])
	var job_b := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		job_b = _find_rescue_job(world, rescuer_b_id)
		if not job_b.is_empty():
			break
	_expect(not job_b.is_empty(), "setup: victim B's own rescue job must be generated")
	_expect(job_b["target"] == Vector2i(2, 0), "setup: victim B's own rescue target must be forced to the shared tile (2, 0)")
	var job_b_id: String = String(job_b["id"])

	var state := StateCodecType.encode(world)
	var path := "user://test-rescue-shared-target-save-io.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var write_result := SaveIOType.write_atomic(path, state)
	_expect(write_result.get("ok", false), "a world with an active and a completed rescue job must save through the real SaveIO boundary: %s" % write_result)
	var read_result := SaveIOType.read(path)
	_expect(read_result.get("ok", false), "the same save must read back through the real SaveIO boundary: %s" % read_result)
	if read_result.get("ok", false):
		var loaded: WorldStateType = StateCodecType.decode(read_result["state"])
		_expect(loaded._rescue_giver.victim_for_job(job_b_id) == victim_b_id,
			"loading through the real SaveIO boundary must preserve job_b's own victim identity exactly -- never victim A's, despite the shared target and overlapping adjacency")
		var loaded_a := loaded._find_colonist(String(victim_a["id"]))
		var loaded_b := loaded._find_colonist(victim_b_id)
		var rescued := false
		for _i in RESCUE_TICK_BOUND:
			loaded.tick()
			if loaded_b.get("trapped") == null:
				rescued = true
				break
		_expect(rescued, "the loaded world must still free victim B, the job's real victim")
		_expect(loaded_a.get("trapped") != null, "the loaded world must never free victim A instead")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## Round-2 review round-4 finding 1's own example: the victim's trench at
## (5, 0) is not the only trench on the map. A near candidate's real route to
## the only remaining target (4, 0) crosses a completely UNRELATED trench at
## (2, 0) -- the old "does the path cross the VICTIM's own tile" check let
## this through, since (2, 0) is not (5, 0). The fix must reject it and use
## the farther, genuinely safe candidate instead.
func _check_route_rejected_when_it_crosses_an_unrelated_trench() -> void:
	var world := _fresh_world(360018)
	var victim: Dictionary = world._colonists[0]
	_trap_colonist_at(world, victim, Vector2i(5, 0))
	world._tiles[world._tile_index(6, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(5, 1)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_TRENCH
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
	_expect(world._rescue_giver.colonist_for_job(String(job["id"])) == safe_id,
		"a candidate whose only route crosses a DIFFERENT trench than the victim's own must never be chosen")
	_expect(job["target"] == Vector2i(4, 0), "the only remaining target must be (4, 0)")
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the safe candidate must still complete the rescue")
	_expect(unsafe_rescuer.get("trapped") == null, "the rejected candidate must never actually be sent, so it never falls into the unrelated trench")

## Round-2 review round-4 finding 2, the real-travel half: a candidate doing
## a genuinely long ordinary labour job keeps moving, tile after tile, for
## far longer than a single sweep takes -- unlike
## _check_pending_rescue_preempts_ordinary_labour()'s own deliberately SHORT
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
	world._tiles[world._tile_index(46, 5)] = WorldStateType.TILE_SOIL
	var labour_submit := world._scheduler.submit(Vector2i(46, 5), 1, world.get_tick(), "till", worker_id)
	_expect(labour_submit.get("ok", false), "setup: the long ordinary labour order must be accepted")
	var labour_job_id: String = String(labour_submit["job_id"])
	# Waits for the worker to be genuinely under way AND far along (not merely
	# assigned, not merely "x > 0"): a rescue search that starts too early
	# converges against a NEARBY, barely-moved position, where each of the (up
	# to four) targets resolves in a single tick -- a 3-target sweep and this
	# actor's own 3-tick move_ticks_per_tile hold then take the exact same
	# duration, so the search spuriously reads "not stale" and legitimately
	# (not staleness) locks in the worker before its own long travel ever
	# really shows drift. Once genuinely far, each target's own route search
	# needs more than one tick, breaking that coincidental alignment.
	var traveling := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if String(world._scheduler.queue.get_job(labour_job_id).get("status", "")) == "active" and int(worker["x"]) >= 10:
			traveling = true
			break
	_expect(traveling, "setup: the long ordinary labour job must be genuinely under way, not merely assigned, before the trap happens")
	var backup := _spawn_colonist(world, "backup_worker", 0, 30)
	var backup_id: String = String(backup["id"])
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
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

## Round-2 review round-4 finding 2, the targeted half: a candidate whose live
## position differs every single tick (teleported here, independent of any
## real job, to make the effect deterministic rather than dependent on
## move_ticks_per_tile timing) must never indefinitely restart the search
## ahead of a later, stationary candidate.
func _check_moving_candidate_cannot_starve_a_stationary_backup() -> void:
	var world := _fresh_world(360020)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
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

## Round-2 review round-4 finding 3, the "across the trench" half: the only
## passage across x=5 is the victim's own trench tile. A critical need whose
## only source sits on the far side is fine for the need job itself (an
## ordinary job may cross a trench), but it leaves the rescuer on the wrong
## side of the only passage for its OWN rescue target. Resuming must never
## blindly walk it back across; the stale commitment must be retired so a
## fresh search can find the still-safe target from the rescuer's new side.
## world._interrupt_current_job()/_resume_interrupted_job() (the exact same
## wrappers a real critical need uses, see
## _check_need_interrupt_one_tile_beyond_target_requires_exact_arrival() below)
## reposition the rescuer directly rather than routing a real need job across
## the trench: any ordinary job's route stepping onto ANY trench tile (a
## waypoint or a target -- world_state.gd's own _check_trench_arrival(),
## unrelated to this task) unconditionally traps a colonist, so a real
## cross-trench need job would itself become a second trapped victim instead
## of landing safely on the far side. Direct repositioning isolates the one
## thing this check is about: world_state.gd's resume path revalidating route
## safety from the rescuer's actual (possibly interrupt-shifted) position,
## never trusting a commitment made from a since-vacated tile.
func _check_need_interrupt_across_the_trench_rejects_unsafe_resume() -> void:
	var world := _fresh_world(360021)
	var victim: Dictionary = world._colonists[0]
	_trap_colonist_at(world, victim, Vector2i(5, 0))
	for y in range(1, world.get_map_height()):
		world._tiles[world._tile_index(5, y)] = WorldStateType.TILE_ROCK
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
	_expect(world._scheduler.queue.get_job(job_id)["target"] == Vector2i(4, 0),
		"setup: the west-side candidate must commit to the only route that never crosses the trench")
	world._interrupt_current_job(rescuer)
	rescuer["x"] = 10
	rescuer["y"] = 0
	world._resume_interrupted_job(rescuer_id)
	_expect(rescuer.get("work") == null,
		"a resumed rescue whose only route back to its own stale target crosses the trench must never resume that work")
	var rescued := false
	var fresh_job := {}
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		# The stale commitment is retired through the toil executor's own
		# budgeted, multi-tick re-route (round-4 review finding 4: never a
		# synchronous search), so the old job id can still be pending for a
		# few ticks -- only a DIFFERENT rescue job counts as the fresh one.
		if fresh_job.is_empty():
			var candidate := _find_rescue_job(world, rescuer_id)
			if not candidate.is_empty() and String(candidate["id"]) != job_id:
				fresh_job = candidate
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the victim must still be rescued, via a fresh safe target, once the unsafe resumption is retired")
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "cancelled",
		"the unsafe stale commitment must be retired (cancelled), never walked through the trench")
	_expect(rescuer.get("trapped") == null, "the rescuer must never have fallen into the trench while re-routing")
	for key in world._work_progress.keys():
		_expect(not String(key).begins_with(job_id + ":"), "retiring the stale rescue must drop its own job-scoped progress key")
	_expect(not fresh_job.is_empty() and fresh_job["target"] == Vector2i(6, 0),
		"the fresh target must be the east-side candidate, reachable from the rescuer's new side without crossing the trench")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(int(rescuer["x"]), int(rescuer["y"])),
		"the victim must end up on the rescuer's own tile")
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "retiring an unsafe resumed rescue must leave no orphaned reservations")

## Round-2 review round-4 finding 3, the "one tile beyond" half: lands the
## rescuer diagonally adjacent to its own rescue target -- Chebyshev-adjacent
## (distance 1) but not the exact tile RescueGiver's own commit-time search
## verified safe. Uses WorldState's own interrupt/resume wrappers directly
## (the same ones a critical need already uses) to pin the exact position
## deterministically, rather than depend on exactly where an eat_food job's
## own consume toil happens to leave the colonist.
func _check_need_interrupt_one_tile_beyond_target_requires_exact_arrival() -> void:
	var world := _fresh_world(360022)
	var victim: Dictionary = world._colonists[0]
	_trap_colonist_at(world, victim, Vector2i(2, 0))
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(2, 1)] = WorldStateType.TILE_ROCK
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
	world._interrupt_current_job(rescuer)
	rescuer["x"] = 4
	rescuer["y"] = 1
	world._resume_interrupted_job(rescuer_id)
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

## Round-2 review round-4 finding 4: rescue A is suspended mid-work with real
## leftover progress; rescue B, a DIFFERENT victim sharing the same target
## tile, activates on the freed tile and runs to completion; rescue A then
## resumes. Each job's own progress must survive untouched by the other's --
## proven through _get_work_progress() directly (never through colonist.work,
## which decrements the very same tick it restarts, off by one from the
## value _work_progress_key() actually restores). The interrupt/resume comes
## from a real critical need (mirrors _check_need_preempts_an_already_active_rescue()'s
## own setup) rather than calling world._interrupt_current_job() directly:
## nothing else would then occupy rescuer A's own committed-assignment slot,
## so _committed_jobs() would keep re-proposing job A for it every tick and
## GlobalAssignment would reactivate it again the very next tick, undoing the
## interrupt before victim B's own search ever got a chance to run.
func _check_shared_target_suspend_resume_preserves_each_jobs_own_progress() -> void:
	var world := _fresh_world(360023)
	var victim_a: Dictionary = world._colonists[0]
	var victim_a_id: String = String(victim_a["id"])
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var submit_a := world._scheduler.submit(Vector2i(5, 0), 1, world.get_tick(), "till", victim_a_id)
	_expect(submit_a.get("ok", false), "setup: victim A's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_a, TRAP_TICK_BOUND), "setup: victim A must become trapped")
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_ROCK
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
	_expect(world._scheduler.queue.get_job(job_a_id)["target"] == Vector2i(2, 0), "setup: job A's target must be the shared tile (2, 0)")

	# Column x=2 has no trench anywhere along it, so routing rescuer A south to
	# its own food source never risks the general "stepping onto ANY trench
	# tile traps the actor" mechanic (world_state.gd's _check_trench_arrival(),
	# unrelated to this task) the way crossing back over x=1 or x=3 would.
	rescuer_a["needs"]["food"] = 5
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	world._ground_berries["2_20"] = 1
	var need_job_id := ""
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if rescuer_a.get("work") != null:
			remaining_before_interrupt = int(rescuer_a["work"]["ticks_remaining"])
		need_job_id = world._need_giver.get_pending_job(rescuer_a_id)
		if not need_job_id.is_empty():
			break
	_expect(not need_job_id.is_empty(), "setup: rescuer A's own critical need must interrupt the active rescue")
	_expect(String(world._scheduler.queue.get_job(job_a_id).get("status", "")) == "queued",
		"setup: job A must be suspended, releasing the shared target's own reservation")

	var victim_b := _spawn_colonist(world, "victim_b", 6, 0)
	var victim_b_id: String = String(victim_b["id"])
	world._tiles[world._tile_index(3, 0)] = WorldStateType.TILE_TRENCH
	var submit_b := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", victim_b_id)
	_expect(submit_b.get("ok", false), "setup: victim B's own till submission must be accepted")
	_expect(_tick_until_trapped(world, victim_b, TRAP_TICK_BOUND), "setup: victim B must become trapped")
	world._tiles[world._tile_index(4, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(3, 1)] = WorldStateType.TILE_ROCK

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
	_expect(String(world._scheduler.queue.get_job(job_b_id).get("status", "")) == "completed",
		"setup: job B must have actually completed, not merely started")

	var need_resolved := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if world._need_giver.get_pending_job(rescuer_a_id).is_empty():
			need_resolved = true
			break
	_expect(need_resolved, "setup: rescuer A's own need must be satisfied so the rescue can resume")
	# Round-6 review (#278/#303): a suspended job's own progress now lives in
	# WorldState._suspended_work_progress (job-id-keyed) rather than staying
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
		"job A must resume from its OWN preserved progress, not restart fresh or inherit job B's leftover (got %d, expected close to %d)" % [live_ticks_remaining, remaining_before_interrupt])
	var restored_progress = world._get_work_progress(Vector2i(2, 0))
	_expect(restored_progress != null and int(restored_progress) == live_ticks_remaining,
		"job A's cached progress must match its own current live work state, never job B's leftover or a corrupted value (got %s expected %s)" % [restored_progress, live_ticks_remaining])
	var rescued_a := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if victim_a.get("trapped") == null:
			rescued_a = true
			break
	_expect(rescued_a, "job A must still go on to complete the rescue")

## Round-2 review round-4 finding 5: state_hash() must reflect RescueGiver's
## own job-to-victim association -- two otherwise-identical states naming a
## different victim for the same job id must never hash equal.
func _check_state_hash_reflects_rescue_victim_assignment() -> void:
	var world := _fresh_world(360024)
	var hash_before := world.state_hash()
	world._rescue_giver._job_victim["fake_job"] = "colonist_0"
	var hash_a := world.state_hash()
	world._rescue_giver._job_victim["fake_job"] = "colonist_1"
	var hash_b := world.state_hash()
	_expect(hash_a != hash_before, "state_hash must reflect a newly added rescue victim assignment")
	_expect(hash_a != hash_b, "state_hash must differ when the same job id names a different victim")

## Ticks until `colonist` is working `job_id` with at least one tick of real
## progress parked under that job's own progress key; returns the key ("" on
## timeout).
func _tick_until_rescue_progress(world: WorldStateType, colonist: Dictionary, job_id: String, bound: int) -> String:
	for _i in bound:
		world.tick()
		var job := world._scheduler.queue.get_job(job_id)
		if job.is_empty() or String(job.get("status", "")) != "active":
			continue
		var target: Vector2i = job["target"]
		var key := "%s:%d_%d" % [job_id, target.x, target.y]
		if colonist.get("work") != null and world._work_progress.has(key):
			return key
	return ""

func _has_progress_key_for(world: WorldStateType, job_id: String) -> bool:
	for key in world._work_progress.keys():
		if String(key).begins_with(job_id + ":"):
			return true
	return false

## Round-4 review finding 2, cancellation during work with a PAUSED ORDINARY
## job sharing the target: an ordinary worker tills the very tile a rescue
## later targets, is interrupted by a real critical need (parking its own
## progress under its own job id via _suspend_work_progress() and releasing
## the tile), then the rescue reserves that tile and starts its own work.
## Cancelling the rescue through the command boundary must drop ONLY the
## rescue's own job-scoped key: the old owner-lookup clear ran after
## _finish_job() had already released the tile, resolved to the plain key,
## and erased the till job's parked progress instead of the rescue's.
func _check_cancel_during_rescue_work_clears_only_its_own_progress_key() -> void:
	var world := _fresh_world(360025)
	_trap_colonist_0(world)
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_ROCK
	var worker := _spawn_colonist(world, "colonist_1", 2, 3)
	var worker_id: String = String(worker["id"])
	var till := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", worker_id)
	_expect(till.get("ok", false), "setup: the worker's own till order on the shared tile must be accepted")
	var till_started := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if worker.get("work") != null and world._work_progress.has("2_0"):
			till_started = true
			break
	_expect(till_started, "setup: the worker must be tilling the shared tile with parked progress")
	worker["needs"]["food"] = 5
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	world._ground_berries["2_40"] = 1
	var interrupted := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		if not world._need_giver.get_pending_job(worker_id).is_empty():
			interrupted = true
			break
	_expect(interrupted, "setup: the worker's own critical need must suspend its till job")
	var till_job_id: String = String(till["job_id"])
	_expect(String(world._scheduler.queue.get_job(till_job_id).get("status", "")) == "queued",
		"setup: the till job must be suspended, releasing the shared tile")
	# Round-6 review (#278/#303): a suspended job's own progress -- till's own
	# ordinary job here included -- now lives in job-id-keyed
	# _suspended_work_progress, not under the shared tile-keyed _work_progress
	# cache (see WorldState._suspend_work_progress()'s own doc comment); this
	# is what removes the shared-tile collision risk this scenario exercises,
	# so the till job's own parked progress is checked there instead.
	var paused_progress = world._suspended_work_progress.get(till_job_id)
	_expect(paused_progress != null, "setup: the suspended till job must keep its progress parked under its own job id")
	_expect(not world._work_progress.has("2_0"), "setup: the suspended till job must release the shared tile's own cache entry")
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
	_expect(world._suspended_work_progress.get(till_job_id) == paused_progress, "setup: rescue work must never touch the till job's own parked progress")
	var cancel := world.apply({"actor": "test", "command_id": "cancel_active_rescue_progress_key",
		"tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": job_id}})
	_expect(cancel.get("ok", false), "cancelling the active rescue through the command boundary must be accepted")
	_expect(not world._work_progress.has(rescue_key), "cancelling an active rescue must drop its own job-scoped progress key")
	_expect(world._suspended_work_progress.get(till_job_id) == paused_progress,
		"cancelling an active rescue must never erase a paused ordinary job's own parked progress on the same tile")
	_expect(String(world._scheduler.queue.get_job(String(till["job_id"])).get("status", "")) == "queued",
		"the paused till job must be untouched by the rescue's cancellation")
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "cancelling an active rescue must leave no orphaned reservations")

## Round-4 review finding 2, cancellation while SUSPENDED: a rescue interrupted
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
	world._interrupt_current_job(rescuer)
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued", "setup: the rescue must be suspended")
	# Round-6 review (#278/#303): suspension moves this job's own progress out
	# of _work_progress into job-id-keyed _suspended_work_progress (see
	# WorldState._suspend_work_progress()'s own doc comment), the same
	# mechanism every other suspended work-ticked kind now uses.
	_expect(not world._work_progress.has(key), "setup: a suspended rescue releases its own tile-keyed cache entry")
	_expect(world._suspended_work_progress.has(job_id), "a suspended rescue keeps its own parked progress until it resumes or terminates")
	var cancel := world.apply({"actor": "test", "command_id": "cancel_suspended_rescue_progress_key",
		"tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": job_id}})
	_expect(cancel.get("ok", false), "cancelling the suspended rescue must be accepted")
	_expect(not world._suspended_work_progress.has(job_id), "cancelling a suspended rescue must drop its own parked progress")
	_expect(world._rescue_giver.get_pending_job(rescuer_id).is_empty(), "the rescuer must be freed")

## Round-4 review finding 2, death: the rescuer dies mid-work; its rescue is
## cancelled through the death boundary and must drop its own progress key.
func _check_rescuer_death_clears_the_rescue_progress_key() -> void:
	var world := _fresh_world(360027)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
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
	world._apply_actor_death(rescuer)
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "cancelled", "the dead rescuer's rescue must be cancelled")
	_expect(not world._work_progress.has(key), "a rescue cancelled by its rescuer's death must drop its own job-scoped progress key")
	_expect(victim.get("trapped") != null, "the victim stays trapped -- nobody rescued it")
	_expect(world._rescue_giver.get_pending_job(rescuer_id).is_empty() and world._rescue_giver.victim_for_job(job_id).is_empty(),
		"RescueGiver must drop every association of the dead rescuer's job")
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "a rescuer's death must leave no orphaned reservations")

## Round-4 review finding 3: two LIVE rescues whose job ids straddle a digit
## boundary (job_9 and job_10 -- inserted in that order live, but sorted
## "job_10" < "job_9" on disk) must hash identically before and after a real
## save/load, since the associations themselves are identical.
func _check_state_hash_equal_across_save_load_with_digit_boundary_rescue_ids() -> void:
	var world := _fresh_world(360028)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(1, 10)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(2, 10)] = WorldStateType.TILE_SOIL
	var victim_a: Dictionary = world._colonists[0]
	var victim_b := _spawn_colonist(world, "colonist_1", 0, 10)
	var submit_a := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", String(victim_a["id"]))
	var submit_b := world._scheduler.submit(Vector2i(2, 10), 1, world.get_tick(), "till", String(victim_b["id"]))
	_expect(submit_a.get("ok", false) and submit_b.get("ok", false), "setup: both till submissions must be accepted")
	var both_trapped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if victim_a.get("trapped") != null and victim_b.get("trapped") != null:
			both_trapped = true
			break
	_expect(both_trapped, "setup: both colonists must become trapped")
	# Burn job ids up to job_8 with orders cancelled straight away.
	while world._scheduler.queue.get_next_id() < 9:
		var y: int = 20 + world._scheduler.queue.get_next_id()
		world._tiles[world._tile_index(5, y)] = WorldStateType.TILE_SOIL
		var burn := world._scheduler.submit(Vector2i(5, y), 1, world.get_tick(), "till", "")
		_expect(burn.get("ok", false), "setup: id-burning order must be accepted")
		world.apply({"actor": "test", "command_id": "burn_%d" % y, "tick": world.get_tick(), "type": "cancel_job",
			"payload": {"job_id": String(burn["job_id"])}})
	_expect(world._scheduler.queue.get_next_id() == 9, "setup: the next job id must be job_9")
	var rescuer_a := _spawn_colonist(world, "colonist_2", 0, 5)
	var rescuer_b := _spawn_colonist(world, "colonist_3", 0, 15)
	var both_active := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		var job_a := _find_rescue_job(world, String(rescuer_a["id"]))
		var job_b := _find_rescue_job(world, String(rescuer_b["id"]))
		if not job_a.is_empty() and not job_b.is_empty() \
				and String(job_a.get("status", "")) == "active" and String(job_b.get("status", "")) == "active":
			both_active = true
			break
	_expect(both_active, "setup: both rescues must be live (active) at once")
	var victims := world._rescue_giver.get_job_victims()
	_expect(victims.has("job_9") and victims.has("job_10"), "setup: the two live rescues must be job_9 and job_10 (got %s)" % [victims.keys()])
	_expect(String(victims.keys()[0]) == "job_9", "setup: the live association must have been inserted job_9 first")
	var live_hash := world.state_hash()
	var loaded: WorldStateType = StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded._rescue_giver.get_job_victims() == victims, "the loaded associations must be identical")
	_expect(loaded.state_hash() == live_hash,
		"state_hash must be identical across save/load when the only difference is the Dictionary order of identical rescue associations")

## Round-4 review finding 4 (ADR 004): three victims' searches all evaluating
## the ONE far-away candidate on a large open map must share that colonist's
## single per-tick route allowance with the scheduler and the toil executor
## -- never one resume() per victim per tick -- while every unfinished search
## is retained across ticks and still completes; and a resumed rescue must
## re-route through the same budgeted, multi-tick search, never a search run
## to completion synchronously.
func _check_rescue_searches_share_the_per_colonist_route_budget() -> void:
	var world := _fresh_world(360029)
	var victim_a: Dictionary = world._colonists[0]
	var victim_b := _spawn_colonist(world, "colonist_1", 0, 0)
	var victim_c := _spawn_colonist(world, "colonist_2", 0, 0)
	var victims: Array = [[victim_a, Vector2i(10, 12)], [victim_b, Vector2i(20, 24)], [victim_c, Vector2i(30, 36)]]
	for entry in victims:
		var victim: Dictionary = entry[0]
		var trench: Vector2i = entry[1]
		victim["x"] = trench.x - 1
		victim["y"] = trench.y
		world._tiles[world._tile_index(trench.x, trench.y)] = WorldStateType.TILE_TRENCH
		world._tiles[world._tile_index(trench.x + 1, trench.y)] = WorldStateType.TILE_SOIL
		var submit := world._scheduler.submit(Vector2i(trench.x + 1, trench.y), 1, world.get_tick(), "till", String(victim["id"]))
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
		for victim_id in world._rescue_giver._searching.keys():
			if world._rescue_giver._searching[victim_id].get("search") != null:
				retained_search_seen = true
		world.tick()
		var telemetry := world._rescue_giver.get_route_telemetry()
		var metrics := world._scheduler.get_metrics()
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
	world._interrupt_current_job(rescuer)
	rescuer["x"] = 47
	rescuer["y"] = 0
	world._resume_interrupted_job(rescuer_id)
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

## Round-4 review finding 5, blocked travel + trench-crossing re-route +
## retiring an unreachable commitment: the only connections between the
## west and east halves of this carved map are two trench tiles. Rescuer 1
## (west) commits to the safe west-side target; a wall dropped in front of it
## mid-travel leaves no trench-free route to that target at all -- the
## unrestricted shortest re-route would now run through BOTH trenches -- so
## the commitment must be retired (rescuer 1 never trapped, never walked
## through a trench) and rescuer 2 (east) must be chosen instead.
func _check_blocked_corridor_reroute_never_crosses_a_trench_and_another_rescuer_helps() -> void:
	var world := _fresh_world(360030)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 11):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
		world._tiles[world._tile_index(x, 5)] = WorldStateType.TILE_FLOOR
	for y in range(0, 6):
		world._tiles[world._tile_index(0, y)] = WorldStateType.TILE_FLOOR
		world._tiles[world._tile_index(10, y)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(5, 5)] = WorldStateType.TILE_TRENCH
	var victim: Dictionary = world._colonists[0]
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
	world._set_object(3, 0, "wooden_wall")
	var retired := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		_expect(rescuer_1.get("trapped") == null, "rescuer 1 must never fall into a trench while re-routing")
		if String(world._scheduler.queue.get_job(job_1_id).get("status", "")) == "cancelled":
			retired = true
			break
	_expect(retired, "a rescue whose only remaining route crosses a trench must be retired, never walked")
	_expect(not _has_progress_key_for(world, job_1_id), "the retired rescue must drop its own progress key")
	_expect(world._rescue_giver.get_pending_job(rescuer_1_id).is_empty(), "the retired rescuer must be released")
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
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "retiring and re-proposing must leave no orphaned reservations")

## Round-4 review finding 5, blocked travel with a safe detour: a wall dropped
## in front of the rescuer mid-travel forces a re-route whose unrestricted
## shortest alternatives tie between a path through the victim's own trench
## and a trench-free one. The re-route must take the trench-free path
## (rescue's own passability treats every trench as impassable) and the
## rescue must complete with the rescuer never trapped.
func _check_blocked_corridor_with_a_safe_detour_reroutes_without_crossing_the_trench() -> void:
	var world := _fresh_world(360031)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_ROCK
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
	world._set_object(0, 2, "wooden_wall")
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_FLOOR
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		_expect(rescuer.get("trapped") == null, "the rescuer must never step onto the trench while detouring")
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the rescue must complete via the trench-free detour")
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "completed", "the SAME rescue job must complete (re-routed, not retired)")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(0, 0), "the victim must end up on the rescue target")

## Round-4 review finding 5, a newly impassable target -- both while the
## commitment is still queued (activation-time path trim) and mid-travel
## (re-route-time trim): a wall on the rescue target must retire the rescue
## rather than let the ordinary impassable-target route trim start rescue
## work one tile off. With no passable neighbour left, the victim's reason
## reads "no rescuer available"; removing the wall lets a fresh rescue finish
## exactly on the target.
func _check_target_made_impassable_retires_the_rescue_instead_of_working_off_target() -> void:
	var world := _fresh_world(360032)
	_trap_colonist_0(world)
	var victim: Dictionary = world._colonists[0]
	var victim_id: String = String(victim["id"])
	world._tiles[world._tile_index(0, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_ROCK
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
	world._set_object(2, 0, "wooden_wall")
	var retired_before_moving := false
	for _i in 20:
		world.tick()
		if String(world._scheduler.queue.get_job(queued_job_id).get("status", "")) == "cancelled":
			retired_before_moving = true
			break
	_expect(retired_before_moving, "a queued rescue whose target became impassable must be retired at activation, never trimmed to an adjacent tile")
	_expect(Vector2i(int(rescuer["x"]), int(rescuer["y"])) == Vector2i(2, 8) and rescuer.get("work") == null,
		"the rescuer must not have moved or started work toward an impassable target")
	# The victim's fresh search runs on the tick after the retirement
	# (RescueGiver.advance() precedes _advance_colonists() within a tick).
	world.tick()
	_expect(world.get_colonist_rescue_reason(victim_id) == world._rescue_giver.REASON_NO_RESCUER_AVAILABLE,
		"with every neighbour blocked the victim's reason must read no_rescuer_available")
	_expect(Vector2i(int(rescuer["x"]), int(rescuer["y"])) == Vector2i(2, 8), "no rescue may be re-proposed while the only target is impassable")
	world._set_object(2, 0, "")
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
	world._set_object(2, 0, "wooden_wall")
	var retired_mid_travel := false
	for _i in RESCUE_TICK_BOUND:
		world.tick()
		_expect(rescuer.get("work") == null, "rescue work must never start off-target")
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "cancelled":
			retired_mid_travel = true
			break
	_expect(retired_mid_travel, "a rescue whose target becomes impassable mid-travel must be retired, never trimmed to start work adjacent")
	_expect(victim.get("trapped") != null and Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(1, 0), "the victim must be untouched")
	world._set_object(2, 0, "")
	var rescued := false
	for _i in RESCUE_TICK_BOUND * 2:
		world.tick()
		if victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "a fresh rescue must complete once the target is passable again")
	_expect(Vector2i(int(victim["x"]), int(victim["y"])) == Vector2i(2, 0), "the victim must be moved exactly onto the rescue target")
