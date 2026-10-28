extends "res://scripts/tests/support/combat_base.gd"

## test_combat_flee checks; shared helpers and the file's full description are in support/combat_base.gd.

func _init() -> void:
	_check_flee_threshold_is_strict()
	_check_flee_below_threshold()
	_check_flee_interrupts_active_work()
	_check_flee_wins_over_resuming_work_across_ticks()
	_check_flee_wins_over_committed_need_job()
	_check_flee_wins_while_need_searching()
	_check_flee_target_avoids_blocked_direction()
	_check_flee_target_requires_separation_improvement()
	_check_flee_association_survives_save_load()
	_check_flee_association_survives_save_load_before_activation()
	_check_save_write_accepts_flee_jobs_at_every_status()
	_check_flee_avoids_reserved_destination()
	_check_flee_target_excludes_faction_blocked_door()
	_check_flee_interrupted_incident_job_survives_save_load()
	_check_flee_recovery_retires_searching_job()
	_check_flee_recovery_retires_active_job()
	_check_flee_blocked_targets_survive_save_load_and_match_uninterrupted()
	_check_flee_recovery_after_save_load_matches_uninterrupted()
	_check_flee_recovery_after_destination_exhaustion()
	_check_need_search_survives_flee_activation()
	_check_need_onset_during_existing_flee_episode()
	_check_flee_pending_search_survives_save_load_faction_aware()
	_check_flee_active_reroute_survives_save_load_faction_aware()
	_check_flee_recovery_resume_needs_fresh_route_faction_aware()
	_check_need_cancel_defers_to_active_flee_episode()
	_check_flee_recovery_of_disconnected_incident_target_cancels_without_replacement()
	_check_despawn_cleans_up_suspended_incident_flee_job()
	_check_flee_completes_while_carrying_interrupted_job_cargo()

	if _failed:
		quit(1)
		return
	print("test_combat_flee: PASS")
	quit(0)

func _check_flee_below_threshold() -> void:
	if _failed: return
	var world := _build_fighters(4)
	var prey := TestAccess.find_colonist(world, "fighter_b")
	prey["health"]["hp"] = 25 # 25% of maxHp 100, below the colonist's own 0.3 flee_hp_fraction
	prey["combat"]["cooldown_remaining"] = 0 # ready to attack -- proves the withhold below is the flee rule itself, not a stale cooldown
	var hunter := TestAccess.find_colonist(world, "fighter_a")
	hunter["combat"]["cooldown_remaining"] = 999 # isolate the prey's own flee/no-fight response this check
	var hunter_hp_before := int(hunter["health"]["hp"])
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	world.tick()

	_expect(world.get_actor_combat_reason("fighter_b") == "", "an actor at/below its own flee_hp_fraction must stop fighting")
	# The fleeing actor's own hp only proves it wasn't hit, not that it withheld its own attack -- assert its opponent's hp instead.
	_expect(int(TestAccess.find_colonist(world, "fighter_a")["health"]["hp"]) == hunter_hp_before,
		"a fleeing actor with a ready cooldown must not land an attack on its opponent while below its flee threshold")

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a fleeing actor must be given a job of kind 'flee'")

	for i in 30:
		world.tick()
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "fighter_b")["x"]), int(TestAccess.find_colonist(world, "fighter_b")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor must actually path away from its starting tile")

## The flee rule is "strictly below", not "at or below" --
## exactly at flee_hp_fraction must still fight; one hp below it must flee.
func _check_flee_threshold_is_strict() -> void:
	if _failed: return
	var world_at := _build_fighters(41)
	var prey_at := TestAccess.find_colonist(world_at, "fighter_b")
	TestAccess.find_colonist(world_at, "fighter_a")["combat"]["cooldown_remaining"] = 999
	prey_at["health"]["hp"] = 30 # exactly 0.3 of maxHp 100
	world_at.tick()
	_expect(world_at.get_actor_combat_reason("fighter_b") == "fighting", "an actor exactly at its own flee_hp_fraction must still fight")
	var has_flee_at_threshold := false
	for job in world_at.get_jobs():
		if String(job.get("kind", "")) == "flee":
			has_flee_at_threshold = true
	_expect(not has_flee_at_threshold, "an actor exactly at its own flee_hp_fraction must not be given a flee job")

	var world_below := _build_fighters(42)
	var prey_below := TestAccess.find_colonist(world_below, "fighter_b")
	TestAccess.find_colonist(world_below, "fighter_a")["combat"]["cooldown_remaining"] = 999
	prey_below["health"]["hp"] = 29 # one hp below 0.3 of maxHp 100
	world_below.tick()
	_expect(world_below.get_actor_combat_reason("fighter_b") == "", "an actor one hp below its own flee_hp_fraction must stop fighting")
	var has_flee_below_threshold := false
	for job in world_below.get_jobs():
		if String(job.get("kind", "")) == "flee":
			has_flee_below_threshold = true
	_expect(has_flee_below_threshold, "an actor strictly below its own flee_hp_fraction must be given a flee job")

## Fleeing must interrupt whatever the actor is already
## doing, not let it run to completion first.
func _check_flee_interrupts_active_work() -> void:
	if _failed: return
	var world := _build_arena(6)
	# The prey must be player-orderable (colony faction) for an ordinary
	# submit() to ever activate its own till job in the first place.
	_spawn_actor(world, "colony", "worker", 6, 5)
	_spawn_actor(world, "raiders", "hunter", 5, 5)
	var prey := TestAccess.find_colonist(world, "worker")
	# Give the prey a normal work job elsewhere, activated before it takes damage.
	var submit_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(7, 5), 1, world.get_tick(), "till", "worker")
	_expect(submit_result.get("ok", false), "the prey's own till job must be accepted")
	var work_job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active",
		"the prey's till job must be active before it starts fleeing")

	prey["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999
	world.tick()

	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) != "active",
		"an actor that starts fleeing must have its own prior work job interrupted (suspended for later resumption), not left running to completion")
	var has_flee_job := false
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) in ["queued", "active"]:
			has_flee_job = true
	_expect(has_flee_job, "an interrupted actor must be given a flee job in its place")

## suspend_assignment() (called by _interrupt_current_job())
## returns the interrupted till job to GlobalAssignment's own ordinary
## candidate pool, where it can outscore a merely-queued, unrestricted-priority
## flee job every subsequent tick, forever -- CombatGiver would then see its
## own tracked flee job still queued and never re-interrupt (it only acts on a
## terminal flee job or none at all). Proves the fix (WorldState._committed_jobs()
## layering CombatGiver's own commitment over GlobalAssignment.tick()'s
## `committed_needs` param) actually lets the flee job win assignment and
## movement over several ticks, not merely that it exists in the queue.
func _check_flee_wins_over_resuming_work_across_ticks() -> void:
	if _failed: return
	var world := _build_arena(20)
	_spawn_actor(world, "colony", "worker", 6, 5)
	# Far away: nearest_hostile_actor() is unbounded (never needs adjacency),
	# so this is a real, targetable threat without ever landing a hit itself.
	_spawn_actor(world, "raiders", "hunter", 40, 40)
	var submit_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(7, 5), 1, world.get_tick(), "till", "worker")
	_expect(submit_result.get("ok", false), "the worker's own till job must be accepted")
	var work_job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active",
		"the worker's till job must be active before it starts fleeing")

	TestAccess.find_colonist(world, "worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var start_pos := Vector2i(int(TestAccess.find_colonist(world, "worker")["x"]), int(TestAccess.find_colonist(world, "worker")["y"]))
	var flee_became_active := false
	for _i in 10:
		world.tick()
		_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) != "active",
			"the worker's suspended till job must never win reassignment back while the worker is still below its own flee_hp_fraction (tick %d)" % world.get_tick())
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) == "active":
				flee_became_active = true
	_expect(flee_became_active, "the flee job must actually be assigned (status active), not merely sit queued behind the work it interrupted")
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "worker")["x"]), int(TestAccess.find_colonist(world, "worker")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor whose own interrupted work re-enters the ordinary pool must still actually move away")

## An existing NeedGiver commitment (colonist_id -> job_id in
## GlobalAssignment.tick()'s `committed_needs` param) forces the scheduler to
## propose only that job to its worker, so a flee job merely sitting in the
## ordinary queue could never win the same worker's slot at all. Fakes the
## commitment through the same seam test_faction_reservations.gd uses
## (TestAccess.need_giver_pending(world)), then proves CombatGiver's
## own commitment (layered on top by WorldState._committed_jobs()) wins
## instead once the worker drops below its own flee_hp_fraction.
func _check_flee_wins_over_committed_need_job() -> void:
	if _failed: return
	var world := _build_arena(21)
	_spawn_actor(world, "colony", "worker", 6, 5)
	_spawn_actor(world, "raiders", "hunter", 40, 40)
	var need_submit: Dictionary = TestAccess.scheduler(world).submit(Vector2i(20, 20), 1, world.get_tick(), "drink_water", "worker")
	_expect(need_submit.get("ok", false), "direct scheduler submission of the need job must be accepted")
	var need_job_id := String(need_submit.get("job_id", ""))
	TestAccess.need_giver_pending(world)["worker"] = need_job_id
	world.tick()

	TestAccess.find_colonist(world, "worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var start_pos := Vector2i(int(TestAccess.find_colonist(world, "worker")["x"]), int(TestAccess.find_colonist(world, "worker")["y"]))
	var flee_became_active := false
	for _i in 10:
		world.tick()
		_expect(String(TestAccess.get_job(world, need_job_id).get("status", "")) != "active",
			"an existing committed need job must not out-rank the worker's own flee job while it is below its flee_hp_fraction (tick %d)" % world.get_tick())
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) == "active":
				flee_became_active = true
	_expect(flee_became_active, "a flee job must actually win assignment over an existing committed need job")
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "worker")["x"]), int(TestAccess.find_colonist(world, "worker")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor with a committed need job must still actually move away")

## WorldState._colonists_not_searching_need() excluded every
## mid-search colonist from GlobalAssignment.tick()'s own worker list
## entirely -- a flee job submitted for one could never even be proposed,
## let alone assigned. Fakes a genuine NeedGiver mid-search state (the exact
## shape NeedGiver._start_search() itself builds) directly, mirroring the
## existing `_pending` fake above, and proves both the raw filter and the
## resulting assignment/movement.
func _check_flee_wins_while_need_searching() -> void:
	if _failed: return
	var world := _build_arena(22)
	_spawn_actor(world, "colony", "worker", 6, 5)
	_spawn_actor(world, "raiders", "hunter", 40, 40)
	world.tick() # backfills "combat" before this test mutates it
	TestAccess.find_colonist(world, "worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	TestAccess.need_giver_searching(world)["worker"] = {"kind": "water", "candidates": [Vector2i(20, 20)],
		"distances": [29], "cursor": 0, "search": null, "found": []}
	# _apply_combat() (inside this tick) must record "worker" into CombatGiver's
	# own `_fleeing` before this same tick's _scheduler_workers() call is built,
	# so it is already exercising the fix by the time the very first tick ends.
	world.tick()

	var included := false
	for colonist in TestAccess.colonists_not_searching_need(world):
		if String(colonist["id"]) == "worker":
			included = true
	_expect(included, "an actor CombatGiver already tracks as fleeing must still be proposed the scheduler tick even while mid need-search")

	var start_pos := Vector2i(int(TestAccess.find_colonist(world, "worker")["x"]), int(TestAccess.find_colonist(world, "worker")["y"]))
	var flee_became_active := false
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) == "active":
				flee_became_active = true
	_expect(flee_became_active, "an actor mid need-search must still actually be assigned its own flee job")
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "worker")["x"]), int(TestAccess.find_colonist(world, "worker")["y"]))
	_expect(moved_pos != start_pos, "an actor mid need-search must still actually flee (move)")

## A single diagonal ray away from the threat must not be the
## only candidate direction -- when it is blocked, an alternate direction
## must still be picked rather than leaving the actor stuck with no target.
func _check_flee_target_avoids_blocked_direction() -> void:
	if _failed: return
	var world := _build_arena(7)
	_spawn_actor(world, "raiders", "hunter", 10, 10)
	_spawn_actor(world, "colony", "prey", 11, 10) # threat directly west -- the prey's own "away" ray points due east
	# Wall off the entire due-east ray so the single-ray approach has no candidate.
	for x in range(12, 17):
		TestAccess.object_table(world).set_object(x, 10, "wooden_wall")
	world.tick() # backfills "combat" (ActorTable's spawn path does not add it) before this test mutates it
	var prey := TestAccess.find_colonist(world, "prey")
	prey["health"]["hp"] = 25
	TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	for i in 20:
		world.tick()
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "prey")["x"]), int(TestAccess.find_colonist(world, "prey")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor whose direct away-direction is walled off must still pick an alternate reachable direction")

## Regression: _pick_flee_target() used to try every direction at
## the farthest distance before ever trying a shorter leg, so when every
## distance-6 endpoint except the one directly toward the threat was blocked,
## it picked that one anyway -- moving the prey closer to its own hunter. Wall
## off every distance-6 endpoint except due-west (toward the threat, at (0,10))
## and every shorter due-east (away-from-threat) leg except distance 1, so the
## only fully-open long escape is the trap and the only other option is a
## short, genuinely safe step.
func _check_flee_target_requires_separation_improvement() -> void:
	if _failed: return
	var world := _build_arena(23)
	_spawn_actor(world, "raiders", "hunter", 0, 10) # far west; nearest_hostile_actor() is unbounded
	_spawn_actor(world, "colony", "prey", 10, 10)
	for pos in [Vector2i(16, 10), Vector2i(10, 4), Vector2i(10, 16), Vector2i(16, 4), Vector2i(16, 16), Vector2i(4, 4), Vector2i(4, 16)]:
		TestAccess.object_table(world).set_object(pos.x, pos.y, "wooden_wall")
	for x in [12, 13, 14, 15]:
		TestAccess.object_table(world).set_object(x, 10, "wooden_wall")
	world.tick() # backfills "combat" before this test mutates it
	var prey := TestAccess.find_colonist(world, "prey")
	prey["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	var threat_pos := Vector2i(0, 10)
	var start_distance := absi(start_pos.x - threat_pos.x) + absi(start_pos.y - threat_pos.y)
	for i in 20:
		world.tick()
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "prey")["x"]), int(TestAccess.find_colonist(world, "prey")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor must actually move")
	_expect(moved_pos.x >= start_pos.x, "a fleeing actor must never move toward its own threat even when that is the only long escape available")
	var moved_distance := absi(moved_pos.x - threat_pos.x) + absi(moved_pos.y - threat_pos.y)
	_expect(moved_distance > start_distance, "a fleeing actor's own chosen destination must strictly increase its distance from the threat, never decrease it")

## CombatGiver's own `_fleeing` association is never
## serialized and starts empty after a load, even though the `flee` job it
## submitted before the save is still queued/active in state that did
## persist -- without adopting it back, a reload mid-flee would submit a
## second, duplicate leg every tick.
func _check_flee_association_survives_save_load() -> void:
	if _failed: return
	var world := _build_fighters(11)
	var prey := TestAccess.find_colonist(world, "fighter_b")
	prey["health"]["hp"] = 25
	TestAccess.find_colonist(world, "fighter_a")["combat"]["cooldown_remaining"] = 999
	world.tick()
	var flee_jobs_before := 0
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) in ["queued", "active"]:
			flee_jobs_before += 1
	_expect(flee_jobs_before == 1, "exactly one flee job must exist for the prey before save")

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	loaded.tick()
	var flee_jobs_after := 0
	for job in loaded.get_jobs():
		if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) in ["queued", "active"] and TestAccess.job_restricted_to(loaded, String(job["id"])) == "fighter_b":
			flee_jobs_after += 1
	_expect(flee_jobs_after == 1, "a reload mid-flee must track exactly one nonterminal flee job per actor, never submit a duplicate")

## GlobalAssignment.restrict_to_for() only reads
## _activated_entries, "" by its own contract for a job that has never
## activated -- the check above happens to save an already-active flee job, so
## it never exercised that gap. Submits a flee job directly and saves before
## any scheduler tick ever touches it (still queued, restrict_to known only
## from the raw waiting-queue entry) to prove CombatGiver now resolves that
## restriction too (via WorldState._job_restricted_to()) and
## adopts the surviving job instead of submitting a duplicate.
func _check_flee_association_survives_save_load_before_activation() -> void:
	if _failed: return
	var world := _build_fighters(24)
	var submit_result: Dictionary = TestAccess.scheduler(world).submit_autonomous(Vector2i(10, 10), 1, world.get_tick(), "flee", "fighter_b")
	_expect(submit_result.get("ok", false), "a directly submitted flee job must be accepted")
	var flee_job_id := String(submit_result.get("job_id", ""))
	_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "queued",
		"the flee job must still be queued (never activated) at the moment of save for this check to be meaningful")
	# Mirrors exactly what CombatGiver.advance() itself would have recorded
	# had it submitted this job through the ordinary tick path.
	TestAccess.combat_giver_fleeing(world)["fighter_b"] = flee_job_id

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	TestAccess.find_colonist(loaded, "fighter_b")["health"]["hp"] = 25 # stay below flee_hp_fraction post-load, or CombatGiver would resume/cancel instead of adopting
	loaded.tick()
	var flee_jobs_after := 0
	for job in loaded.get_jobs():
		if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) in ["queued", "active"] and TestAccess.job_restricted_to(loaded, String(job["id"])) == "fighter_b":
			flee_jobs_after += 1
	_expect(flee_jobs_after == 1, "a reload while a flee job was still queued (never activated) must adopt it back, not submit a duplicate leg")

## Regression: SaveIO._validate_state()'s own job-kind whitelist (separate
## from StateCodec/game-state.schema.json's) used to reject
## "flee" outright regardless of status, so any save with a flee job in
## flight -- queued, active, or even a terminal one still on the wire --
## was rejected by SaveIO.write_atomic(). Proves all three lifecycle shapes
## pass through the real entry point, not just the StateCodec round trip
## _check_flee_association_survives_save_load() above already covers.
func _check_save_write_accepts_flee_jobs_at_every_status() -> void:
	if _failed: return
	_cleanup_dir(SAVE_WRITE_FLEE_DIR)
	var user_dir := DirAccess.open("user://")
	if user_dir and not user_dir.dir_exists(SAVE_WRITE_FLEE_DIR):
		user_dir.make_dir_recursive(SAVE_WRITE_FLEE_DIR)

	var world := _build_fighters(13)
	var prey := TestAccess.find_colonist(world, "fighter_b")
	prey["health"]["hp"] = 25
	TestAccess.find_colonist(world, "fighter_a")["combat"]["cooldown_remaining"] = 999
	world.tick()

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a flee job must exist to exercise SaveIO's own job-kind whitelist")
	if flee_job_id.is_empty():
		_cleanup_dir(SAVE_WRITE_FLEE_DIR)
		return

	var state: Dictionary = StateCodecType.encode(world)
	var jobs: Array = state["jobs"]
	var template_index := -1
	for i in jobs.size():
		if String((jobs[i] as Dictionary).get("id", "")) == flee_job_id:
			template_index = i
	_expect(template_index >= 0, "the encoded state must carry the same flee job id")
	if template_index < 0:
		_cleanup_dir(SAVE_WRITE_FLEE_DIR)
		return

	for status in ["queued", "active", "completed"]:
		var candidate_jobs: Array = jobs.duplicate(true)
		var candidate_job: Dictionary = (candidate_jobs[template_index] as Dictionary).duplicate(true)
		candidate_job["status"] = status
		candidate_jobs[template_index] = candidate_job
		var candidate_state: Dictionary = state.duplicate(true)
		candidate_state["jobs"] = candidate_jobs
		var result := SaveIOType.write_atomic(SAVE_WRITE_FLEE_DIR.path_join("save.json"), candidate_state)
		_expect(result.get("ok", false), "SaveIO.write_atomic() must accept a %s 'flee' job, got %s" % [status, result])

	_cleanup_dir(SAVE_WRITE_FLEE_DIR)

## _pick_flee_target() only checked eligibility
## (_actor_may_reserve_target()), never whether the candidate tile is a live
## target of another job's own reservation right now -- so a flee job could
## be submitted straight at a tile already claimed, where it would sit
## queued and blocked (blocked_target_reserved) forever. Reserves the exact
## tile _pick_flee_target()'s own ranking would otherwise try first (the
## farthest distance along the dominant away-direction, mirroring
## `_check_flee_target_avoids_blocked_direction`'s geometry) and proves the
## fleeing actor picks a different, available tile instead.
func _check_flee_avoids_reserved_destination() -> void:
	if _failed: return
	var world := _build_arena(35)
	_spawn_actor(world, "raiders", "hunter", 10, 10)
	_spawn_actor(world, "colony", "prey", 11, 10) # threat directly west -- "away" ray points due east
	world.tick() # backfills "combat" before this test mutates it

	var reserved_tile := Vector2i(17, 10) # prey.x(11) + FLEE_DISTANCE(6) along the dominant away direction
	var reserve_result: Dictionary = TestAccess.scheduler(world).submit(reserved_tile, 1, world.get_tick(), "till")
	_expect(reserve_result.get("ok", false), "a job targeting the prey's own farthest escape tile must be accepted so it can actually reserve that tile")
	world.tick()
	_expect(String(TestAccess.get_job(world, String(reserve_result["job_id"])).get("status", "")) == "active",
		"the blocking job must actually be active (holding a live target reservation) for this check to be meaningful")

	var prey := TestAccess.find_colonist(world, "prey")
	prey["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
	TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	world.tick()

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a fleeing actor must still be given a flee job even when its own preferred escape tile is reserved by another job")
	if not flee_job_id.is_empty():
		var flee_target: Vector2i = TestAccess.get_job(world, flee_job_id)["target"]
		_expect(flee_target != reserved_tile, "a flee job must never target a tile another job already reserves")

	for i in 20:
		world.tick()
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "prey")["x"]), int(TestAccess.find_colonist(world, "prey")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor whose own preferred escape tile is reserved by another job must still find and move to an available alternate")

func _check_flee_target_excludes_faction_blocked_door() -> void:
	if _failed: return
	var world := _build_faction_blocked_door_world(36)
	var prey := TestAccess.find_colonist(world, "prey")
	prey["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
	TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))

	var max_x := start_pos.x
	for i in 150:
		world.tick()
		max_x = maxi(max_x, int(TestAccess.find_colonist(world, "prey")["x"]))
	var moved_pos := Vector2i(int(TestAccess.find_colonist(world, "prey")["x"]), int(TestAccess.find_colonist(world, "prey")["y"]))
	_expect(moved_pos != start_pos,
		"a fleeing raider whose every east-pointing escape route crosses a door forbidden to its own faction must still find and move to a reachable alternate, not remain stranded")
	_expect(max_x < 14,
		"a fleeing raider actor must never actually cross a door its own faction cannot pass (content/factions.json: raiders may_pass_doors=false), not even briefly mid-chase")

## Recovery (hp back above flee_hp_fraction)
## must retire the flee job through the shared finish boundary even while it
## is still "queued" and mid route-search (GlobalAssignment._pending), not
## only once it has gone "active" (see the sibling active-job check below). A
## diagonal threat direction forces the top-ranked flee candidate to
## Manhattan distance 12 (FLEE_DISTANCE (6) in both x and y); an open-arena
## uniform-cost search needs far more than RouteSearch.STEP_BUDGET (64)
## expansions to resolve that, so the job is still genuinely mid-search
## (never active) after the single tick that submits it.
func _check_flee_recovery_retires_searching_job() -> void:
	if _failed: return
	var world := _build_arena(44)
	_spawn_actor(world, "colony", "prey", 10, 10)
	_spawn_actor(world, "raiders", "hunter", 0, 0) # diagonal threat, far enough to never land a hit
	world.tick() # backfills "combat"/"health" before this test mutates them

	TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world.tick() # submits the flee job and starts (but cannot finish) its route search this same tick

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and TestAccess.job_restricted_to(world, String(job["id"])) == "prey":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a flee job must exist for this check to be meaningful")
	_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "queued",
		"the flee job's route search must still be in flight (status queued, not yet active) for this check to be meaningful")
	_expect(TestAccess.scheduler(world).get_pending().has("prey"),
		"the fleeing actor's own route search must still be mid-flight (GlobalAssignment._pending) for this check to be meaningful")

	TestAccess.find_colonist(world, "prey")["health"]["hp"] = 100 # recover above the flee threshold
	world.tick()

	_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) in ["cancelled", "failed", "completed"],
		"a flee job still mid-search at the moment of recovery must be retired, not left dangling")
	_expect(not TestAccess.scheduler(world).get_pending().has("prey"),
		"a retired flee job's own in-flight route search must be dropped, not left claiming its own candidate job forever")
	_expect(not TestAccess.combat_giver(world).get_committed_jobs().has("prey"),
		"a recovered actor must leave no residual CombatGiver association")

## Regression: recovery while the flee job is already active (assigned, holding
## its own destination reservation) previously erased the giver's own
## association and resumed interrupted work without retiring the flee job
## itself, leaving it active (and its reservation held) indefinitely once
## _resume_interrupted_job() overwrote the worker's assignment out from under
## it. A cardinal threat direction keeps the top-ranked flee candidate within a
## small number of RouteSearch budget ticks, so polling a bounded number of
## ticks reliably reaches "active" before recovering.
func _check_flee_recovery_retires_active_job() -> void:
	if _failed: return
	var world := _build_arena(45)
	_spawn_actor(world, "colony", "prey", 10, 10)
	_spawn_actor(world, "raiders", "hunter", 0, 10) # cardinal threat, far enough to never land a hit
	world.tick() # backfills "combat"/"health" before this test mutates them

	TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_job_id := ""
	var became_active := false
	for _i in 20:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and TestAccess.job_restricted_to(world, String(job["id"])) == "prey":
				flee_job_id = String(job["id"])
		if not flee_job_id.is_empty() and String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "active":
			became_active = true
			break
	_expect(became_active, "the flee job must actually reach 'active' status for this check to be meaningful")
	var target: Vector2i = TestAccess.get_job(world, flee_job_id)["target"]
	_expect(TestAccess.flee_target_reserved(world, target.x, target.y),
		"an active flee job must hold a live reservation on its own destination for this check to be meaningful")

	TestAccess.find_colonist(world, "prey")["health"]["hp"] = 100 # recover above the flee threshold
	world.tick()

	_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) in ["cancelled", "failed", "completed"],
		"an active flee job must be retired on recovery, not left running (and its reservation held) indefinitely")
	_expect(not TestAccess.flee_target_reserved(world, target.x, target.y),
		"a retired flee job must release its own destination reservation, not leave it held forever")
	_expect(not TestAccess.combat_giver(world).get_committed_jobs().has("prey"),
		"a recovered actor must leave no residual CombatGiver association")
	var prey_assignment: Dictionary = world.get_assignments().get("prey", {})
	_expect(String(prey_assignment.get("job_id", "")) != flee_job_id,
		"a recovered actor's scheduler assignment must not still point at the retired flee job")

## `_blocked_targets` is not reconstructible
## from the scheduler's own queued/active jobs after a load (a cancelled
## blocked flee job that produced an exclusion is already gone from the
## queue by the time it is excluded), so it must round-trip through
## StateCodec/state_hash() explicitly. Runs the faction-blocked-door fixture
## (`_build_faction_blocked_door_world()` above) on two byte-identical
## worlds until at least two distinct destinations have been excluded, saves
## one of them mid-episode, and proves: the exact same exclusion set survives
## the round trip, and every subsequent tick's actor position matches the
## uninterrupted run exactly -- not merely that state_hash() would flag a
## divergence, but that the divergence the missing persistence would have
## caused (re-trying an already-proven-blocked destination) does not happen.
func _check_flee_blocked_targets_survive_save_load_and_match_uninterrupted() -> void:
	if _failed: return
	var uninterrupted := _build_faction_blocked_door_world(47)
	var live := _build_faction_blocked_door_world(47)
	for world in [uninterrupted, live]:
		TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
		TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999

	var blocked_before: Dictionary = {}
	var accumulated := false
	for i in 250:
		uninterrupted.tick()
		live.tick()
		blocked_before = (TestAccess.combat_giver(live).get_blocked_targets().get("prey", {}) as Dictionary)
		if blocked_before.size() >= 2:
			accumulated = true
			break
	_expect(accumulated, "the faction-blocked-door fixture must accumulate at least two excluded flee destinations within the bounded tick budget for this check to be meaningful")
	if not accumulated:
		return

	var loaded := StateCodecType.decode(StateCodecType.encode(live))
	var loaded_blocked: Dictionary = (TestAccess.combat_giver(loaded).get_blocked_targets().get("prey", {}) as Dictionary)
	_expect(loaded_blocked.size() == blocked_before.size(),
		"a save/load round trip must carry the exact same number of excluded flee destinations, got %d before vs %d after" % [blocked_before.size(), loaded_blocked.size()])
	for tile in blocked_before.keys():
		_expect(loaded_blocked.has(tile), "a save/load round trip must exclude the exact same destination tiles, got missing %s" % tile)

	for i in 150:
		uninterrupted.tick()
		loaded.tick()
		var uninterrupted_pos := Vector2i(int(TestAccess.find_colonist(uninterrupted, "prey")["x"]), int(TestAccess.find_colonist(uninterrupted, "prey")["y"]))
		var loaded_pos := Vector2i(int(TestAccess.find_colonist(loaded, "prey")["x"]), int(TestAccess.find_colonist(loaded, "prey")["y"]))
		_expect(uninterrupted_pos == loaded_pos,
			"a save made after multiple blocked flee destinations must reproduce identical subsequent positions to an uninterrupted run (tick %d)" % i)
		var uninterrupted_flee_status := ""
		var loaded_flee_status := ""
		for job in uninterrupted.get_jobs():
			if String(job.get("kind", "")) == "flee" and TestAccess.job_restricted_to(uninterrupted, String(job["id"])) == "prey":
				uninterrupted_flee_status = String(job["status"])
		for job in loaded.get_jobs():
			if String(job.get("kind", "")) == "flee" and TestAccess.job_restricted_to(loaded, String(job["id"])) == "prey":
				loaded_flee_status = String(job["status"])
		_expect(uninterrupted_flee_status == loaded_flee_status,
			"a save made after multiple blocked flee destinations must reproduce identical subsequent flee job transitions to an uninterrupted run (tick %d)" % i)

## CombatGiver's own flee interrupt suspends an incident
## actor's active incident job back to "queued" exactly like a critical need
## would, but _reconcile_incident_jobs_after_load() used to cancel every
## queued incident job unconditionally -- treating "queued" as always meaning
## "never activated". Saving mid-flee therefore destroyed a previously
## activated, merely-paused incident job and its actor association. Proves
## the fix distinguishes the two shapes (GlobalAssignment.restrict_to_for()
## is non-empty only once a job has actually activated at least once) and
## that the reloaded actor's lifecycle matches what an uninterrupted run
## would do: once it stops fleeing, its own original incident job resumes and
## goes active again, rather than staying cancelled or orphaned.
func _check_flee_interrupted_incident_job_survives_save_load() -> void:
	if _failed: return
	var world := _build_arena(37)
	var actor_id := "incident_reaper"
	var job_id := TestAccess.incidents(world).propose(_make_incident_actor(world, actor_id, 0, 5), Vector2i(10, 5), 5)
	_expect(not job_id.is_empty(), "the incident proposal must be accepted")

	var spawn_ticks := 0
	while TestAccess.find_colonist(world, actor_id).is_empty() and spawn_ticks < 60:
		world.tick()
		spawn_ticks += 1
	_expect(not TestAccess.find_colonist(world, actor_id).is_empty(), "the incident actor must spawn onto the map for this check to be meaningful")
	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) == "active", "the incident job must be active once its actor has spawned")
	# _ensure_combat() only backfills a colonist already in _colonists, one tick after it was spawned.
	world.tick()
	_expect(TestAccess.find_colonist(world, actor_id).get("combat") is Dictionary, "the spawned incident actor must carry a backfilled combat component for this check to be meaningful")

	_spawn_actor(world, "colony", "colony_defender", 40, 40) # far away; nearest_hostile_actor() is unbounded, giving the incident actor a threat to flee without ever taking a hit itself

	var reaper := TestAccess.find_colonist(world, actor_id)
	reaper["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
	world.tick()

	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) == "queued",
		"combat's own flee interrupt must suspend the incident actor's active incident job back to queued")
	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and TestAccess.job_restricted_to(world, String(job["id"])) == actor_id:
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "the incident actor must be given its own flee job once it starts fleeing")
	_expect(String(TestAccess.needs_system(world).paused_jobs.get(actor_id, "")) == job_id,
		"the incident actor's own paused-job entry must still name its interrupted incident job")

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(not TestAccess.find_colonist(loaded, actor_id).is_empty(), "the incident actor must survive a save/load while fleeing")
	_expect(String(TestAccess.get_job(loaded, job_id).get("status", "")) == "queued",
		"the incident actor's own paused incident job must survive a save/load, not be cancelled just for sitting queued")
	_expect(String(TestAccess.incident_actor_by_job(loaded).get(job_id, "")) == actor_id,
		"the reloaded incident job must still be re-associated with its own actor so on_job_finished() can despawn it correctly")

	# Uninterrupted-lifecycle check: once the actor stops fleeing, its original incident job must actually resume and go active again, exactly like it would have without the save/load.
	TestAccess.find_colonist(loaded, actor_id)["health"]["hp"] = 100
	var resumed := false
	for i in 60:
		loaded.tick()
		if String(TestAccess.get_job(loaded, job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the incident actor's own paused incident job must resume and go active again once it stops fleeing, exactly like an uninterrupted incident's lifecycle")

## Recovery cleanup used to hinge on the giver's own transient
## `_fleeing` map, which every load starts empty, and adoption of a restored
## flee job only ever ran inside the still-fleeing branch -- so a save taken
## mid-flee (job queued and mid route-search, queued and blocked, or active)
## followed by recovery before the next flee decision skipped cancellation
## and resumption entirely, unlike an uninterrupted run. Drives each of the
## three shapes on two byte-identical worlds, saves one, recovers both, and
## compares the flee job, interrupted work, assignments, reservations,
## exclusions and subsequent positions tick by tick.
func _check_flee_recovery_after_save_load_matches_uninterrupted() -> void:
	if _failed: return
	for shape in ["searching", "active", "blocked"]:
		var uninterrupted: WorldStateType
		var live: WorldStateType
		var work_job_id := ""
		if shape == "blocked":
			uninterrupted = _build_faction_blocked_door_world(48)
			live = _build_faction_blocked_door_world(48)
			for world in [uninterrupted, live]:
				TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25
				TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999
		else:
			uninterrupted = _build_arena(48)
			live = _build_arena(48)
			for world in [uninterrupted, live]:
				_spawn_actor(world, "colony", "prey", 10, 10)
				# A diagonal far threat keeps the first leg mid-search for many ticks; a cardinal one lets it go active quickly.
				if shape == "searching":
					_spawn_actor(world, "raiders", "hunter", 0, 0)
				else:
					_spawn_actor(world, "raiders", "hunter", 0, 10)
				var submit_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(11, 10), 1, world.get_tick(), "till", "prey")
				_expect(submit_result.get("ok", false), "[%s] the prey's own till job must be accepted" % shape)
				work_job_id = String(submit_result.get("job_id", ""))
				world.tick()
				_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active", "[%s] the prey's till job must be active before it flees" % shape)
				TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25
		var reached := false
		for _i in 40:
			uninterrupted.tick()
			live.tick()
			var flee_job := _flee_job_of(live, "prey")
			if flee_job.is_empty():
				continue
			var status := String(flee_job.get("status", ""))
			var reason := String(flee_job.get("reason", ""))
			if shape == "searching" and status == "queued" and TestAccess.scheduler(live).get_pending().has("prey"):
				reached = true
			elif shape == "active" and status == "active":
				reached = true
			elif shape == "blocked" and status == "queued" and reason.begins_with("blocked_target_"):
				reached = true
			if reached:
				break
		_expect(reached, "[%s] the flee job must reach the shape under test for this check to be meaningful" % shape)
		if not reached:
			return
		var live_flee_id := String(_flee_job_of(live, "prey")["id"])
		var uninterrupted_flee_id := String(_flee_job_of(uninterrupted, "prey")["id"])
		var loaded := StateCodecType.decode(StateCodecType.encode(live))
		_expect(String(TestAccess.get_job(loaded, live_flee_id).get("status", "")) in ["queued", "active"], "[%s] the flee job must survive the save/load" % shape)
		for world in [uninterrupted, loaded]:
			TestAccess.find_colonist(world, "prey")["health"]["hp"] = 100
		uninterrupted.tick()
		loaded.tick()
		var expected_status := String(TestAccess.get_job(uninterrupted, uninterrupted_flee_id).get("status", ""))
		var loaded_status := String(TestAccess.get_job(loaded, live_flee_id).get("status", ""))
		_expect(expected_status in ["cancelled", "failed", "completed"],
			"[%s] the uninterrupted run must retire its flee job on recovery (got '%s')" % [shape, expected_status])
		_expect(loaded_status == expected_status,
			"[%s] recovery right after a load must retire the restored flee job exactly like the uninterrupted run (got '%s' vs '%s')" % [shape, loaded_status, expected_status])
		_expect(not TestAccess.combat_giver(loaded).get_committed_jobs().has("prey") and not TestAccess.combat_giver(loaded).get_blocked_targets().has("prey"),
			"[%s] recovery right after a load must leave no residual CombatGiver association or exclusions" % shape)
		_expect(not TestAccess.scheduler(loaded).get_pending().has("prey"),
			"[%s] recovery right after a load must drop the restored flee job's own route search" % shape)
		_expect(not TestAccess.needs_system(loaded).paused_jobs.has("prey") and not TestAccess.needs_system(uninterrupted).paused_jobs.has("prey"),
			"[%s] recovery must consume the paused-job entry in both runs" % shape)
		var flee_target: Vector2i = TestAccess.get_job(loaded, live_flee_id)["target"]
		_expect(not TestAccess.flee_target_reserved(loaded, flee_target.x, flee_target.y),
			"[%s] a flee job retired after a load must release its own destination reservation" % shape)
		if not work_job_id.is_empty():
			_expect(String(TestAccess.get_job(loaded, work_job_id).get("status", "")) == "active" and String(TestAccess.get_job(uninterrupted, work_job_id).get("status", "")) == "active",
				"[%s] the interrupted till job must be resumed (active) in both runs" % shape)
		_expect(String((loaded.get_assignments().get("prey", {}) as Dictionary).get("job_id", "")) == String((uninterrupted.get_assignments().get("prey", {}) as Dictionary).get("job_id", "")),
			"[%s] the recovered actor's assignment must match the uninterrupted run" % shape)
		for i in 40:
			uninterrupted.tick()
			loaded.tick()
			var a := Vector2i(int(TestAccess.find_colonist(uninterrupted, "prey")["x"]), int(TestAccess.find_colonist(uninterrupted, "prey")["y"]))
			var b := Vector2i(int(TestAccess.find_colonist(loaded, "prey")["x"]), int(TestAccess.find_colonist(loaded, "prey")["y"]))
			_expect(a == b, "[%s] positions after recovery must match the uninterrupted run (tick %d)" % [shape, i])
			if not work_job_id.is_empty():
				_expect(String(TestAccess.get_job(loaded, work_job_id).get("status", "")) == String(TestAccess.get_job(uninterrupted, work_job_id).get("status", "")),
					"[%s] the resumed till job's status must match the uninterrupted run (tick %d)" % [shape, i])

## A blocked flee leg is cancelled and excluded, and when
## every remaining candidate is then exhausted no replacement is submitted --
## the giver used to erase its only record of the episode (`_fleeing`) at
## that point, so a later recovery never cleared the exclusions nor resumed
## the work it had interrupted. A raiders actor boxed in a three-tile room
## whose only exit is a door its faction cannot pass sees every outside
## candidate pass the coarse region check, get submitted, get blocked, and
## get excluded, one per tick, until nothing is left.
func _check_flee_recovery_after_destination_exhaustion() -> void:
	if _failed: return
	var world := _build_arena(49)
	for x in range(9, 14):
		TestAccess.object_table(world).set_object(x, 9, "wooden_wall")
		TestAccess.object_table(world).set_object(x, 11, "wooden_wall")
	TestAccess.object_table(world).set_object(9, 10, "wooden_wall")
	TestAccess.object_table(world).set_object(13, 10, "door")
	_spawn_actor(world, "colony", "hunter", 10, 10)
	_spawn_actor(world, "raiders", "prey", 11, 10)
	world.tick() # backfills "combat"/"health"
	TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999
	var submit_result: Dictionary = TestAccess.scheduler(world).submit_autonomous(Vector2i(12, 10), 1, world.get_tick(), "till", "prey")
	_expect(submit_result.get("ok", false), "the boxed-in raider's own autonomous till job must be accepted")
	var work_job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active", "the raider's till job must be active before it flees")

	TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25
	var exhausted := false
	var excluded_count := 0
	for _i in 120:
		world.tick()
		excluded_count = (TestAccess.combat_giver(world).get_blocked_targets().get("prey", {}) as Dictionary).size()
		if excluded_count >= 2 and _flee_job_of(world, "prey").get("status", "") not in ["queued", "active"] and not TestAccess.combat_giver(world).get_committed_jobs().has("prey"):
			exhausted = true
			break
	_expect(exhausted, "the boxed-in raider must exhaust every flee destination (blocked, cancelled, excluded) within the tick budget for this check to be meaningful")
	if not exhausted:
		return
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("prey", "")) == work_job_id or String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active",
		"the interrupted till job must still be tracked as paused (or already back active) while the raider is stuck")
	world.tick() # one more tick with nothing left to try: the episode must persist without a job
	_expect(TestAccess.combat_giver(world).get_blocked_targets().has("prey"),
		"exclusions must persist across a tick with no destination left, so the episode remains owned")

	TestAccess.find_colonist(world, "prey")["health"]["hp"] = 100
	world.tick()
	_expect(not TestAccess.combat_giver(world).get_blocked_targets().has("prey"),
		"recovery after destination exhaustion must clear the episode's exclusions")
	_expect(not TestAccess.combat_giver(world).get_committed_jobs().has("prey"), "recovery must leave no residual flee association")
	_expect(not TestAccess.needs_system(world).paused_jobs.has("prey"), "recovery after destination exhaustion must consume the paused-job entry")
	_expect(String(_flee_job_of(world, "prey").get("status", "")) not in ["queued", "active"], "no flee job may outlive recovery")
	var work_status := String(TestAccess.get_job(world, work_job_id).get("status", ""))
	_expect(work_status in ["active", "completed"],
		"recovery after destination exhaustion must resume the interrupted work, not leave it suspended (got '%s')" % work_status)

## A real (non-stub) need search still genuinely in flight when a separate
## hostile actor drops this same colonist below its own flee_hp_fraction.
## Three fully enclosed (unreachable) water tiles keep NeedGiver's own search
## alive for several ticks (_advance_candidate_search() resolves exactly one
## candidate's own bounded search per tick) -- long enough to activate flee
## in between. CombatGiver must own the interrupt/resume boundary for the
## rest of the episode: the frozen search must never reach _onset_failed()'s
## own resume call and clobber the flee assignment, and the original
## pre-need-search work job's _paused_jobs association must survive untouched
## until CombatGiver's own recovery resumes it.
func _check_need_search_survives_flee_activation() -> void:
	if _failed: return
	var world := _build_arena(51)
	_spawn_actor(world, "colony", "worker", 15, 15)
	_spawn_actor(world, "raiders", "reaper", 0, 0) # far away; nearest_hostile_actor() is unbounded, never lands a hit
	for x in range(7, 24):
		TestAccess.object_table(world).set_object(x, 7, "wooden_wall")
		TestAccess.object_table(world).set_object(x, 23, "wooden_wall")
	for y in range(7, 24):
		TestAccess.object_table(world).set_object(7, y, "wooden_wall")
		TestAccess.object_table(world).set_object(23, y, "wooden_wall")
	TestAccess.set_tile(world, 25, 15, WorldStateType.TILE_WATER)
	world.tick() # backfills "combat"/"health" before this test mutates them

	var work_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(16, 15), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the worker's own unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	var settled := false
	for _i in 10:
		world.tick()
		if TestAccess.find_colonist(world, "worker").get("work") != null:
			settled = true
			break
	_expect(settled, "the till job must reach its own work toil before the need onset, for this check to be meaningful")

	TestAccess.find_colonist(world, "worker")["needs"]["water"] = 0
	world.tick() # a real NeedGiver._evaluate() interrupts the till job and starts a real search
	_expect(TestAccess.need_giver_searching(world).has("worker"), "a real need search must have started for this check to be meaningful")
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id, "the need interrupt must pause the till job")

	TestAccess.find_colonist(world, "worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_active := false
	for _i in 10:
		world.tick()
		if TestAccess.need_giver_searching(world).has("worker") and TestAccess.combat_giver(world).get_committed_jobs().has("worker"):
			flee_active = true
			break
	_expect(flee_active, "the need search must still be in flight when the worker starts fleeing, for this check to be meaningful")
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id,
		"the pre-existing need interrupt's own paused-work association must survive flee activation untouched")

	for _i in 20:
		world.tick()
		_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id or not TestAccess.combat_giver(world).owns("worker"),
			"a frozen need search must never overwrite the till job's own paused-job entry while CombatGiver owns this actor (tick %d)" % world.get_tick())

	TestAccess.find_colonist(world, "worker")["health"]["hp"] = 100
	var resumed := false
	for _i in 20:
		world.tick()
		if String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the original pre-need-search till job must resume cleanly once the worker recovers")
	_expect(not TestAccess.needs_system(world).paused_jobs.has("worker"), "recovery must leave no residual paused-job entry")
	_expect(not TestAccess.combat_giver(world).get_committed_jobs().has("worker"), "recovery must leave no residual CombatGiver association")

## A real need onset (urgent/critical) that fires only after CombatGiver
## already owns this actor (an open flee episode from an earlier, separate
## interrupt). This must never reach NeedGiver's own
## interrupt/search machinery at all -- the pre-flee work job's own
## _paused_jobs association is the one CombatGiver's own recovery must
## resume, never a need job's.
func _check_need_onset_during_existing_flee_episode() -> void:
	if _failed: return
	var world := _build_arena(52)
	_spawn_actor(world, "colony", "worker", 15, 15)
	_spawn_actor(world, "raiders", "reaper", 14, 15)
	world.tick() # backfills "combat"/"health" before this test mutates them
	TestAccess.find_colonist(world, "reaper")["combat"]["cooldown_remaining"] = 999

	var work_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(16, 15), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the worker's own unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	var settled := false
	for _i in 10:
		world.tick()
		if TestAccess.find_colonist(world, "worker").get("work") != null:
			settled = true
			break
	_expect(settled, "the till job must reach its own work toil before combat interrupts it, for this check to be meaningful")

	TestAccess.find_colonist(world, "worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_active := false
	for _i in 10:
		world.tick()
		if TestAccess.combat_giver(world).get_committed_jobs().has("worker"):
			flee_active = true
			break
	_expect(flee_active, "the worker must actually start fleeing for this check to be meaningful")
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id, "combat's own interrupt must pause the till job")
	_expect(TestAccess.combat_giver(world).owns("worker"), "CombatGiver must own the interrupt/resume boundary for this check to be meaningful")

	# A real need onset now, mid-episode: this must never reach NeedGiver's
	# own interrupt/search machinery at all while CombatGiver owns "worker".
	TestAccess.find_colonist(world, "worker")["needs"]["water"] = 0
	for _i in 20:
		world.tick()
		_expect(not TestAccess.need_giver_searching(world).has("worker"), "a need onset during an open flee episode must never start a real search (tick %d)" % world.get_tick())
		_expect(TestAccess.need_giver(world).get_pending_job("worker").is_empty(), "a need onset during an open flee episode must never submit a need job (tick %d)" % world.get_tick())
		_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id,
			"a need onset during an open flee episode must never overwrite the till job's own paused-job entry (tick %d)" % world.get_tick())

	TestAccess.find_colonist(world, "worker")["health"]["hp"] = 100
	var resumed := false
	for _i in 20:
		world.tick()
		if String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the original pre-flee till job must resume, not a need job, once the worker recovers")
	_expect(TestAccess.need_giver(world).get_pending_job("worker").is_empty(), "recovery must never have submitted a need job for the still-thirsty worker")

	# The need is still genuinely unmet: now that the episode has closed,
	# NeedGiver must finally get a chance to evaluate it (never permanently
	# silenced, only deferred) -- this bare arena has no water source at all,
	# so the exposed reason (not a live search) is the observable proof.
	# Evaluation only resumes once the resumed till job's own walk back (if
	# the flee episode moved "worker" away from its target) finishes and it
	# reaches a toil boundary (_evaluate() skips both the urgent and critical
	# checks while still mid-route), so this uses a generous bound rather
	# than the tighter ones above.
	var handled := false
	for _i in 300:
		world.tick()
		if world.get_colonist_need_reason("worker").begins_with("need_unmet:"):
			handled = true
			break
	_expect(handled, "a need still unmet when the flee episode closed must eventually be evaluated by NeedGiver once ownership is released")

## GlobalAssignment.restore_scheduling() rebuilt a restored
## pending route search with the colony-default `is_passable` regardless of
## whether the underlying candidate was autonomous -- so a raider's own
## in-flight flee search, saved before it ever reaches the faction-forbidden
## door, could resolve differently after a reload than the live, faction-
## aware search tick() itself runs. Saves the instant the raider's flee
## search is still genuinely mid-flight (GlobalAssignment._pending, not yet
## resolved) and proves the restored search's every subsequent tick --
## activation, destination, movement -- matches an uninterrupted twin exactly.
func _check_flee_pending_search_survives_save_load_faction_aware() -> void:
	if _failed: return
	var uninterrupted := _build_faction_blocked_door_world(53)
	var live := _build_faction_blocked_door_world(53)
	for world in [uninterrupted, live]:
		TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25
		TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999
	uninterrupted.tick()
	live.tick()
	_expect(TestAccess.scheduler(live).get_pending().has("prey"), "the raider's own flee route search must still be genuinely in flight for this check to be meaningful")

	var loaded := StateCodecType.decode(StateCodecType.encode(live))
	_expect(TestAccess.scheduler(loaded).get_pending().has("prey"), "a save/load mid-search must restore the raider's own pending route search, not drop it")

	for i in 150:
		uninterrupted.tick()
		loaded.tick()
		var uninterrupted_pos := Vector2i(int(TestAccess.find_colonist(uninterrupted, "prey")["x"]), int(TestAccess.find_colonist(uninterrupted, "prey")["y"]))
		var loaded_pos := Vector2i(int(TestAccess.find_colonist(loaded, "prey")["x"]), int(TestAccess.find_colonist(loaded, "prey")["y"]))
		_expect(uninterrupted_pos == loaded_pos,
			"a save taken mid-search must reproduce identical subsequent positions to an uninterrupted run (tick %d)" % i)
		_expect(int(TestAccess.find_colonist(loaded, "prey")["x"]) < 14, "a restored search must never cross the raider's own faction-forbidden door (tick %d)" % i)

## StateCodec._restore_reroutes() rebuilt a restored in-flight
## reroute search (a colonist's own route.rerouting snapshot) with the
## colony-default `_routable_to()` regardless of the acting actor's own
## faction. Walls the raider's own short direct path once it is genuinely
## mid-walk, forcing a live reroute around the loop above; saves the instant
## that reroute is still genuinely mid-flight, then proves the restored
## search's every subsequent tick matches an uninterrupted twin exactly.
func _check_flee_active_reroute_survives_save_load_faction_aware() -> void:
	if _failed: return
	var uninterrupted := _build_flee_racetrack_door_world(54)
	var live := _build_flee_racetrack_door_world(54)
	for world in [uninterrupted, live]:
		TestAccess.find_colonist(world, "prey")["health"]["hp"] = 25
		TestAccess.find_colonist(world, "hunter")["combat"]["cooldown_remaining"] = 999

	var walled := false
	var mid_reroute := false
	var ticks := 0
	while not mid_reroute and ticks < 400:
		uninterrupted.tick()
		live.tick()
		ticks += 1
		if not walled:
			var prey := TestAccess.find_colonist(live, "prey")
			if int(prey["x"]) == 12 and int(prey["y"]) == 0:
				TestAccess.object_table(live).set_object(13, 0, "wooden_wall")
				TestAccess.object_table(uninterrupted).set_object(13, 0, "wooden_wall")
				walled = true
		var route = TestAccess.find_colonist(live, "prey").get("route")
		if route != null and route.get("rerouting") != null and String(route["rerouting"].get("status", "")) == "searching":
			mid_reroute = true
	_expect(walled, "the test fixture must wall the raider's own direct path before it reaches the wall point")
	_expect(mid_reroute, "the raider's own live reroute search must still be genuinely mid-flight (STATUS_SEARCHING) for this check to be meaningful")
	if not mid_reroute:
		return

	var loaded := StateCodecType.decode(StateCodecType.encode(live))
	var loaded_route = TestAccess.find_colonist(loaded, "prey").get("route")
	_expect(loaded_route != null and loaded_route.get("rerouting") != null, "a save/load mid-reroute must restore the raider's own in-flight search, not drop it")

	for i in 400:
		uninterrupted.tick()
		loaded.tick()
		var uninterrupted_pos := Vector2i(int(TestAccess.find_colonist(uninterrupted, "prey")["x"]), int(TestAccess.find_colonist(uninterrupted, "prey")["y"]))
		var loaded_pos := Vector2i(int(TestAccess.find_colonist(loaded, "prey")["x"]), int(TestAccess.find_colonist(loaded, "prey")["y"]))
		_expect(uninterrupted_pos == loaded_pos,
			"a save taken mid-reroute must reproduce identical subsequent positions to an uninterrupted run (tick %d)" % i)
		_expect(loaded_pos != Vector2i(15, 1), "a restored reroute must never cross the raider's own faction-forbidden door (tick %d)" % i)

## WorldState._advance_go_to_or_resubmit() -- called by
## _resume_paused_job() when CombatGiver's own recovery resumes an
## autonomous actor's own paused work and it is not yet within reach of the
## target -- defaulted to colony passability regardless of the acting actor's
## own faction. This bug is not save/load-specific (the same call happens on
## a live, never-saved run too), so a run-vs-run comparison could not reveal
## it: an unfixed default would be wrong identically in both. Interrupts a
## raider's own autonomous till job, relocates it (mirroring what a real
## flee episode would have left behind) to the far side of its own
## faction-forbidden door from the job's own target, saves and reloads
## mid-episode, then directly proves the restored recovery's own fresh route
## never crosses the door while still actually reaching the paused job.
func _check_flee_recovery_resume_needs_fresh_route_faction_aware() -> void:
	if _failed: return
	var world := _build_flee_racetrack_door_world(55)
	var submit_result: Dictionary = TestAccess.scheduler(world).submit_autonomous(Vector2i(15, 0), 1, world.get_tick(), "till", "prey")
	_expect(submit_result.get("ok", false), "the raider's own autonomous till job must be accepted")
	var job_id := String(submit_result["job_id"])
	world.tick()
	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) == "active", "the raider's own till job must be active before it is interrupted for this check to be meaningful")

	var prey := TestAccess.find_colonist(world, "prey")
	TestAccess.needs_system(world).interrupt_current_job(prey)
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("prey", "")) == job_id, "the till job must actually be paused for this check to be meaningful")
	prey["x"] = 15
	prey["y"] = 30 # south of the door, on the direct column back to the paused job's own target
	TestAccess.combat_giver_episodes(world)["prey"] = {}

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(String(TestAccess.needs_system(loaded).paused_jobs.get("prey", "")) == job_id, "a save/load must preserve the raider's own paused-job entry")
	_expect(TestAccess.combat_giver(loaded).owns("prey"), "a save/load must preserve the raider's own open flee episode")

	var stood_on_door := false
	var resumed_active := false
	for i in 600:
		loaded.tick()
		var pos := Vector2i(int(TestAccess.find_colonist(loaded, "prey")["x"]), int(TestAccess.find_colonist(loaded, "prey")["y"]))
		if pos == Vector2i(15, 1):
			stood_on_door = true
		if String(TestAccess.get_job(loaded, job_id).get("status", "")) == "active":
			resumed_active = true
	_expect(not stood_on_door, "a restored recovery's own fresh route must never cross the raider's own faction-forbidden door")
	_expect(resumed_active, "the restored recovery must still actually resume and reach the paused job (the long way around), not get permanently stuck")

## NeedGiver.advance() is guarded by _colonists_not_combat_owned(),
## but the resolve_job() callbacks _apply_job_command()'s cancel_job/fail_job/
## invalidate_job path fires directly were not. A need that paused ordinary
## work and submitted a still-queued (never activated) need job, followed by
## combat interrupting the same actor into an active flee episode before that
## need job resolves, left _paused_jobs still naming the original work
## (combat's own interrupt found nothing new to pause -- the need job never
## held a scheduler assignment). Resolving the need job through the ordinary
## command path used to overwrite the active flee assignment. Proves the
## fixed _resume_interrupted_job() defers instead: the flee assignment,
## reservation and CombatGiver ownership all survive the cancellation, and
## the original work still resumes correctly once the actor later recovers.
func _check_need_cancel_defers_to_active_flee_episode() -> void:
	if _failed: return
	var world := _build_arena(60)
	_spawn_actor(world, "colony", "worker", 15, 15)
	_spawn_actor(world, "raiders", "reaper", 0, 0) # far; nearest_hostile_actor() is unbounded, never lands a hit
	world.tick() # backfills "combat"/"health" before this test mutates them

	var work_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(16, 15), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the worker's own unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	world.tick()
	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active", "the unrestricted till job must be active before the interrupt")

	var worker := TestAccess.find_colonist(world, "worker")
	TestAccess.needs_system(world).interrupt_current_job(worker) # mirrors NeedGiver's own critical-need interrupt
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id, "the interrupted till job must be recorded as this worker's own paused job")

	var need_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(20, 20), 1, world.get_tick(), "drink_water", "worker")
	_expect(need_result.get("ok", false), "the worker's own restricted need job must be accepted")
	var need_job_id := String(need_result.get("job_id", ""))
	TestAccess.need_giver_pending(world)["worker"] = need_job_id # fakes a real NeedGiver commitment, same seam other checks in this file use

	worker["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_job_id := ""
	var flee_active := false
	for _i in 20:
		world.tick()
		flee_job_id = String(_flee_job_of(world, "worker").get("id", ""))
		if not flee_job_id.is_empty() and String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "active":
			flee_active = true
			break
	_expect(flee_active, "the worker's own flee job must actually reach active for this check to be meaningful")
	_expect(String(TestAccess.get_job(world, need_job_id).get("status", "")) == "queued",
		"the need job must stay queued -- never assigned, since the flee commitment always wins the propose slot -- for this check to be meaningful")
	var flee_target: Vector2i = TestAccess.get_job(world, flee_job_id)["target"]
	_expect(TestAccess.flee_target_reserved(world, flee_target.x, flee_target.y),
		"the active flee job must hold a live destination reservation for this check to be meaningful")

	# Cancel the still-queued need job through the exact command boundary
	# that calls NeedGiver.resolve_job() -> _resume_interrupted_job().
	var cancel_result := world.apply({"actor": "test", "command_id": "cancel_need_over_flee", "tick": world.get_tick(),
		"type": "cancel_job", "payload": {"job_id": need_job_id}})
	_expect(bool(cancel_result.get("ok", false)), "cancelling the still-queued need job must be accepted")

	_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "active",
		"cancelling a resolved need job must never overwrite the actor's own active flee assignment")
	_expect(String((world.get_assignments().get("worker", {}) as Dictionary).get("job_id", "")) == flee_job_id,
		"the worker's own scheduler assignment must still point at the flee job after the need job resolves")
	_expect(TestAccess.flee_target_reserved(world, flee_target.x, flee_target.y),
		"the flee job's own destination reservation must remain held, not released by an errant resume")
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id,
		"the original interrupted till job must still be the one recorded as paused, deferred until CombatGiver releases ownership")
	_expect(TestAccess.combat_giver(world).owns("worker"), "CombatGiver must still own the flee episode after the need job resolves")

	worker["health"]["hp"] = 100 # recover above the flee threshold
	var resumed := false
	for _i in 20:
		world.tick()
		if String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the original till job must resume once the actor recovers, even after an intervening need-job cancellation mid-episode")
	_expect(not TestAccess.needs_system(world).paused_jobs.has("worker"), "recovery must leave no residual paused-job entry")
	_expect(not TestAccess.combat_giver(world).owns("worker"), "recovery must leave no residual CombatGiver episode")

## _advance_go_to_or_resubmit() (recovery's own fresh-route
## path once a paused job resumes) called _resubmit_unreachable_job()
## unconditionally on "unreachable" instead of the same kind-aware
## _toil_on_unreachable() boundary every other first-leg unreachable case
## already uses. If an incident actor's own original destination became
## disconnected while it was interrupted, recovery's own first-step search
## exhausting immediately used to cancel the incident (despawning the actor
## through _finish_job()) and then submit a replacement ordinary incident
## job restricted to the now-removed actor -- a job that can never run.
## Seals the incident actor's target inside a small room (well under
## RouteSearch.STEP_BUDGET) and walls off its own four orthogonal neighbors
## (the only directions RouteSearch.NEIGHBOR_OFFSETS ever tries) so
## recovery's very first bounded resume() call, not a multi-tick search,
## concludes unreachable. Drives the shared interrupt/episode boundary
## directly (the same idiom _check_flee_recovery_resume_needs_fresh_route_faction_aware()
## above uses), since this fix concerns recovery's own unreachable handling,
## not flee targeting.
func _check_flee_recovery_of_disconnected_incident_target_cancels_without_replacement() -> void:
	if _failed: return
	var world := _build_arena(61)
	for x in range(4, 13):
		TestAccess.object_table(world).set_object(x, 4, "wooden_wall")
		TestAccess.object_table(world).set_object(x, 10, "wooden_wall")
	for y in range(5, 10):
		TestAccess.object_table(world).set_object(4, y, "wooden_wall")
		TestAccess.object_table(world).set_object(12, y, "wooden_wall")
	var actor_id := "incident_trapped"
	var job_id := TestAccess.incidents(world).propose(_make_incident_actor(world, actor_id, 6, 7), Vector2i(10, 7), 5)
	_expect(not job_id.is_empty(), "the incident proposal must be accepted")
	var spawn_ticks := 0
	while TestAccess.find_colonist(world, actor_id).is_empty() and spawn_ticks < 60:
		world.tick()
		spawn_ticks += 1
	_expect(not TestAccess.find_colonist(world, actor_id).is_empty(), "the incident actor must spawn for this check to be meaningful")
	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) == "active", "the incident job must be active once its actor has spawned")
	world.tick() # backfills "combat" before CombatGiver.advance() reads it

	var trapped := TestAccess.find_colonist(world, actor_id)
	TestAccess.needs_system(world).interrupt_current_job(trapped)
	_expect(String(TestAccess.needs_system(world).paused_jobs.get(actor_id, "")) == job_id, "the interrupt must pause the trapped incident actor's own incident job for this check to be meaningful")
	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) == "queued", "the paused incident job must be suspended back to queued")
	TestAccess.combat_giver_episodes(world)[actor_id] = {} # opens the episode directly, mirroring the file's own established idiom for this boundary

	# Disconnect the incident job's own target: wall off its four orthogonal
	# neighbors, so the destination stays a bare floor tile but nothing can
	# ever reach it.
	TestAccess.object_table(world).set_object(9, 7, "wooden_wall")
	TestAccess.object_table(world).set_object(11, 7, "wooden_wall")
	TestAccess.object_table(world).set_object(10, 6, "wooden_wall")
	TestAccess.object_table(world).set_object(10, 8, "wooden_wall")
	TestAccess.route_budget(world).erase(actor_id) # guarantees the recovery's own fresh search actually resumes this tick, not deferred by a stale per-tick routing allowance

	world.tick() # CombatGiver.advance() sees no reason to flee (default full hp), closes the episode, and calls the shared recovery boundary

	_expect(TestAccess.find_colonist(world, actor_id).is_empty(),
		"the trapped incident actor must despawn once its own recovery finds its original destination genuinely unreachable")
	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) in ["cancelled", "failed"],
		"the original incident job must be terminated, not left dangling")
	var replacement_found := false
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			continue
		if String(job.get("kind", "")) == "incident" and TestAccess.job_restricted_to(world, String(job["id"])) == actor_id:
			replacement_found = true
	_expect(not replacement_found, "recovery from an unreachable incident destination must cancel, never resubmit, a replacement job restricted to the now-removed actor")
	_expect(not TestAccess.needs_system(world).paused_jobs.has(actor_id), "recovery must leave no residual paused-job entry for the despawned actor")
	_expect(not TestAccess.combat_giver(world).owns(actor_id), "recovery must leave no residual CombatGiver episode for the despawned actor")
	_expect(world.get_assignments().get(actor_id) == null, "the despawned actor must hold no scheduler assignment")

## Cancelling an incident job suspended by a flee interrupt
## calls IncidentScheduler.on_job_finished() -> _remove_colonist_by_id()
## directly, bypassing every scheduling/giver cleanup step _apply_actor_death()
## used to perform alone -- the actor's own flee job (searching or active),
## its route search, its destination reservation, its paused-job entry and
## its CombatGiver association all survived the despawn. Covers both shapes
## the flee job can be in at the moment of cancellation: still mid-search (a
## diagonal, slow-resolving threat, mirroring _check_flee_recovery_retires_searching_job())
## and already active with a live destination reservation (a cardinal,
## fast-resolving threat, mirroring _check_flee_recovery_retires_active_job()).
func _check_despawn_cleans_up_suspended_incident_flee_job() -> void:
	if _failed: return
	for searching in [true, false]:
		var world := _build_arena(62 if searching else 63)
		var actor_id := "incident_fleeing"
		var job_id := TestAccess.incidents(world).propose(_make_incident_actor(world, actor_id, 10, 10), Vector2i(20, 10), 5)
		_expect(not job_id.is_empty(), "the incident proposal must be accepted")
		var spawn_ticks := 0
		while TestAccess.find_colonist(world, actor_id).is_empty() and spawn_ticks < 60:
			world.tick()
			spawn_ticks += 1
		_expect(not TestAccess.find_colonist(world, actor_id).is_empty(), "the incident actor must spawn for this check to be meaningful")
		_expect(String(TestAccess.get_job(world, job_id).get("status", "")) == "active", "the incident job must be active once its actor has spawned")
		world.tick() # backfills "combat" before this test mutates it

		if searching:
			_spawn_actor(world, "colony", "hunter", 0, 0) # diagonal threat: keeps the flee route search running for several ticks
		else:
			_spawn_actor(world, "colony", "hunter", 0, 10) # cardinal threat: resolves within a bounded number of ticks

		TestAccess.find_colonist(world, actor_id)["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
		var flee_job_id := ""
		for _i in 20:
			world.tick()
			flee_job_id = String(_flee_job_of(world, actor_id).get("id", ""))
			if flee_job_id.is_empty():
				continue
			var status := String(TestAccess.get_job(world, flee_job_id).get("status", ""))
			if searching and status == "queued" and TestAccess.scheduler(world).get_pending().has(actor_id):
				break
			if not searching and status == "active":
				break
		_expect(not flee_job_id.is_empty(), "a flee job must exist for this check to be meaningful")
		var flee_target: Vector2i = TestAccess.get_job(world, flee_job_id).get("target", Vector2i(-1, -1))
		if searching:
			_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "queued" and TestAccess.scheduler(world).get_pending().has(actor_id),
				"the flee job's own route search must still be mid-flight for this check to be meaningful")
		else:
			_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "active", "the flee job must actually reach 'active' status for this check to be meaningful")
			_expect(TestAccess.flee_target_reserved(world, flee_target.x, flee_target.y),
				"an active flee job must hold a live reservation on its own destination for this check to be meaningful")
		_expect(String(TestAccess.needs_system(world).paused_jobs.get(actor_id, "")) == job_id,
			"combat's own flee interrupt must pause the incident actor's own incident job for this check to be meaningful")

		var cancel_result := world.apply({"actor": "test", "command_id": "cancel_suspended_incident_%s" % searching, "tick": world.get_tick(),
			"type": "cancel_job", "payload": {"job_id": job_id}})
		_expect(bool(cancel_result.get("ok", false)), "cancelling the suspended incident job must be accepted")

		_expect(TestAccess.find_colonist(world, actor_id).is_empty(), "cancelling the suspended incident job must despawn its actor")
		_expect(String(TestAccess.get_job(world, job_id).get("status", "")) in ["cancelled", "failed"], "the incident job itself must be terminated")
		_expect(String(TestAccess.get_job(world, flee_job_id).get("status", "")) in ["cancelled", "failed", "completed"],
			"the actor's own flee job (searching=%s) must not survive its despawn" % searching)
		_expect(world.get_assignments().get(actor_id) == null, "the despawned actor must hold no scheduler assignment")
		_expect(not TestAccess.scheduler(world).get_pending().has(actor_id), "the despawned actor must hold no in-flight route search")
		if not searching:
			_expect(not TestAccess.flee_target_reserved(world, flee_target.x, flee_target.y),
				"the despawned actor's own flee destination reservation must be released, not held indefinitely")
		_expect(not TestAccess.needs_system(world).paused_jobs.has(actor_id), "the despawned actor must leave no residual paused-job entry")
		_expect(not TestAccess.combat_giver(world).owns(actor_id), "the despawned actor must leave no residual CombatGiver episode")
		_expect(not TestAccess.combat_giver(world).get_committed_jobs().has(actor_id), "the despawned actor must leave no residual CombatGiver commitment")
		var residual_job := false
		for job in world.get_jobs():
			if String(job["id"]) in [job_id, flee_job_id]:
				continue
			if TestAccess.job_restricted_to(world, String(job["id"])) == actor_id and String(job.get("status", "")) in ["queued", "active"]:
				residual_job = true
		_expect(not residual_job, "no other job may remain queued or active for the despawned actor (searching=%s)" % searching)

## An actor that starts fleeing while still carrying cargo
## from an unrelated interrupted job (a haul/build leg two, ADR 009's own
## need/combat interrupt boundary) must actually complete its flee job, not
## stall on arrival. flee's toils ([reserve, go_to, work, release_all]) have
## no pick_up of their own, so ToilExecutor's go_to/work selection must be
## read off flee's own declared sequence -- never off the actor's leftover
## is_carrying() flag from the paused haul/build job, which used to make
## flee's single go_to look like haul/build's own "leg two" (pick_up already
## done) and pick the no-op arrival forever, leaving the actor stuck in
## attack range instead of actually moving away.
func _check_flee_completes_while_carrying_interrupted_job_cargo() -> void:
	if _failed: return
	var world := _build_fighters(70)
	var prey := TestAccess.find_colonist(world, "fighter_b")
	# Simulates the exact leftover state a combat interrupt leaves behind
	# (colonist-ai.md 3.6): a colonist mid-haul/build carries its item right
	# through a need/combat interrupt, never dropping it.
	InventoryType.add_to_hands(prey, "wood", 1)
	prey["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	TestAccess.find_colonist(world, "fighter_a")["combat"]["cooldown_remaining"] = 999
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	world.tick()

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a fleeing actor must be given a job of kind 'flee' even while carrying cargo")
	if flee_job_id.is_empty():
		return

	var moved := false
	var flee_completed := false
	for _i in 60:
		world.tick()
		_expect(InventoryType.has_kind(TestAccess.find_colonist(world, "fighter_b"), "wood"),
			"the carried item must survive the whole flee episode, never dropped or duplicated (tick %d)" % world.get_tick())
		var pos := Vector2i(int(TestAccess.find_colonist(world, "fighter_b")["x"]), int(TestAccess.find_colonist(world, "fighter_b")["y"]))
		if pos != start_pos:
			moved = true
		if String(TestAccess.get_job(world, flee_job_id).get("status", "")) == "completed":
			flee_completed = true
			break
	_expect(moved, "a fleeing actor carrying unrelated cargo must actually path away from its starting tile, not stall at arrival")
	_expect(flee_completed, "the flee job must reach completed status while the actor carries unrelated cargo, not stall forever")
