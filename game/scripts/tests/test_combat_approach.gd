extends "res://scripts/tests/support/combat_base.gd"

## test_combat_approach checks; shared helpers and the file's full description are in support/combat_base.gd.

func _init() -> void:
	_check_approach_walks_wolf_to_door_and_fights()
	_check_approach_skipped_when_adjacent()
	_check_approach_skipped_while_combat_giver_owns()
	_check_approach_determinism_and_save_load()
	_check_approach_forgets_target_after_flee_release_and_removal()
	_check_approach_retargets_when_actor_target_dies()
	_check_approach_retargets_when_object_target_destroyed()
	_check_approach_cancels_stale_target_while_adjacent_to_different_hostile()
	_check_approach_retargets_when_queued_job_goes_blocked_unreachable()
	_check_approach_falls_back_to_incident_when_fully_walled_off()
	_check_approach_fallback_never_interferes_with_unrelated_incident_job()
	_check_approach_fallback_resumes_same_actors_own_incident_job()
	_check_approach_flee_interrupt_and_resume()

	if _failed:
		quit(1)
		return
	print("test_combat_approach: PASS")
	quit(0)

## Proves ApproachGiver end-to-end: the test supplies no destination at all --
## the wolf must decide on its own to walk to the tile Chebyshev-adjacent to
## the door (wildlife may not pass a colony door, content/factions.json) and
## start fighting it, exactly like an ordinary player order would drive a
## dig/chop job, but entirely job-giver-decided.
func _check_approach_walks_wolf_to_door_and_fights() -> void:
	if _failed: return
	var world := _build_wolf_door_world(100)
	var found_attack := false
	for i in 250:
		world.tick()
		for event in world.get_events():
			if String(event.get("type", "")) == "attacked_by" and String(event.get("data", {}).get("attacker_id", "")) == "wolf_1":
				found_attack = true
		if found_attack:
			break
	_expect(found_attack, "a wolf given no destination must still walk itself adjacent to the colony door blocking its route and attack it, through ApproachGiver alone")
	_expect(world.get_actor_combat_reason("wolf_1") == "fighting", "get_actor_combat_reason(wolf_id) must report 'fighting' once the wolf is adjacent and attacking")

## Rule 1: an actor already adjacent to a hostile target must never be given
## an approach job -- the existing attack rule already covers it.
func _check_approach_skipped_when_adjacent() -> void:
	if _failed: return
	var world := _build_fighters(101)
	for i in 5:
		world.tick()
	var has_approach := false
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "approach":
			has_approach = true
	_expect(not has_approach, "an actor already adjacent to a hostile target must never be given an approach job")

## Rule 2: an actor CombatGiver owns (an open flee episode) must never be
## given or keep an approach job, even though it is otherwise hostile to, and
## not adjacent to, a reachable colony target.
func _check_approach_skipped_while_combat_giver_owns() -> void:
	if _failed: return
	var world := _build_arena(102)
	_spawn_actor(world, "raiders", "fleeing_raider", 5, 5)
	_spawn_actor(world, "colony", "distant_target", 40, 40)
	world.tick() # backfills "combat"/"health" before this test mutates them
	TestAccess.find_colonist(world, "fleeing_raider")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world.tick()
	_expect(TestAccess.combat_giver(world).owns("fleeing_raider"), "the raider must be owned by CombatGiver (fleeing) for this check to be meaningful")
	for i in 15:
		world.tick()
		var has_approach := false
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "approach" and TestAccess.job_restricted_to(world, String(job["id"])) == "fleeing_raider":
				has_approach = true
		_expect(not has_approach, "an actor CombatGiver owns must never be given or keep an approach job (tick %d)" % world.get_tick())

## Determinism (two fresh runs of the same seed/scenario) and save/load
## (a save taken mid-approach reloads with the same tracked target and
## continues), both covered by state_hash() -- AGENTS.md's simulation rules.
func _check_approach_determinism_and_save_load() -> void:
	if _failed: return
	var world_a := _build_wolf_door_world(103)
	var world_b := _build_wolf_door_world(103)
	# 100 ticks: the wolf's own faction relation makes
	# it hostile to every placed colony-faction object with a health entry, not
	# just the door, so its own search ranks the door against every individual
	# wall segment too (`_build_wolf_door_world()`'s wall column) -- an
	# admissible Chebyshev lower bound cannot prune most
	# of them early, since they tie at the same Chebyshev distance from the
	# wolf's own start tile, so committing the job takes closer to 64 ticks than
	# 20 here.
	for i in 100:
		world_a.tick()
		world_b.tick()
		_expect(world_a.state_hash() == world_b.state_hash(),
			"two runs of the same seed/scenario must produce identical state_hash() at tick %d" % world_a.get_tick())

	var approach_job_id := ""
	for job in world_a.get_jobs():
		if String(job.get("kind", "")) == "approach":
			approach_job_id = String(job["id"])
	_expect(not approach_job_id.is_empty(), "an approach job must exist mid-scenario for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(TestAccess.get_job(world_a, approach_job_id).get("status", "")) in ["queued", "active"],
		"the approach job must still be in flight for this check to be meaningful")
	var target_before: Dictionary = TestAccess.approach_giver(world_a).get_job_targets().get(approach_job_id, {})
	_expect(not target_before.is_empty(), "the in-flight approach job must have a tracked target for this check to be meaningful")

	var loaded := StateCodecType.decode(StateCodecType.encode(world_a))
	var loaded_target: Dictionary = TestAccess.approach_giver(loaded).get_job_targets().get(approach_job_id, {})
	_expect(loaded_target == target_before, "a save taken mid-approach must reload with the same tracked target")

	for i in 40:
		world_a.tick()
		loaded.tick()
		_expect(world_a.state_hash() == loaded.state_hash(),
			"a save taken mid-approach must reload and continue identically to an uninterrupted run (tick %d)" % world_a.get_tick())

## Regression: a paused approach job's target association used to survive
## removal of the actor it belonged to. `_release_tracking()` (rule
## 2) deliberately drops `_tracking[actor_id]` while CombatGiver owns the
## actor but keeps `_job_targets[job_id]` alive, so a recovered episode can
## resume the same job -- `forget()` used to look that association up only
## through `_tracking`, so an actor removed while its approach job sat paused
## (owned by CombatGiver, never reactivated) left its `_job_targets` entry,
## and the persisted `approachJobTargets` array, stale forever. Proves the
## whole sequence -- submission, flee ownership/release, actor removal --
## leaves no association in either get_job_targets() or the encoded state.
func _check_approach_forgets_target_after_flee_release_and_removal() -> void:
	if _failed: return
	var world := _build_arena(104)
	_spawn_actor(world, "raiders", "fleeing_raider", 5, 5)
	_spawn_actor(world, "colony", "distant_target", 40, 40)
	world.tick() # backfills "combat"/"health" before this test mutates them

	var approach_job_id := ""
	for i in 60:
		world.tick()
		approach_job_id = String(_approach_job_of(world, "fleeing_raider").get("id", ""))
		if not approach_job_id.is_empty():
			break
	_expect(not approach_job_id.is_empty(), "an approach job must be submitted for the raider for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"the freshly submitted approach job must have a tracked target for this check to be meaningful")

	TestAccess.find_colonist(world, "fleeing_raider")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	for i in 10:
		world.tick()
		if TestAccess.combat_giver(world).owns("fleeing_raider"):
			break
	_expect(TestAccess.combat_giver(world).owns("fleeing_raider"), "the raider must be owned by CombatGiver (fleeing) for this check to be meaningful")
	_expect(TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"a paused approach job's target association must survive rule 2's release while CombatGiver still owns the actor, for this check to be meaningful")

	TestAccess.remove_colonist_by_id(world, "fleeing_raider", false)
	_expect(not TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"a removed actor must leave no stale approach target association in get_job_targets()")
	var encoded: Dictionary = StateCodecType.encode(world)
	for entry in (encoded.get("approachJobTargets", []) as Array):
		_expect(String((entry as Dictionary).get("jobId", "")) != approach_job_id,
			"the persisted approachJobTargets array must not carry a removed actor's stale association")

## Retarget rule (A), first trigger: a tracked approach job's
## recorded actor target dying is cancelled through the shared finish
## boundary and its association dropped the same tick, re-entering rule 4's
## "no job tracked" branch immediately -- proven by watching the hunter
## commit to the nearer of two colony targets, killing it, and confirming the
## hunter picks the farther one next, all without leaking a reservation.
func _check_approach_retargets_when_actor_target_dies() -> void:
	if _failed: return
	var world := _build_arena(110)
	_spawn_actor(world, "raiders", "hunter", 0, 5)
	_spawn_actor(world, "colony", "near_target", 10, 5)
	_spawn_actor(world, "colony", "far_target", 30, 5)
	world.tick() # backfills "combat"/"health" before this test mutates them

	var approach_job_id := ""
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-death tick %d" % world.get_tick())
		var job := _approach_job_of(world, "hunter")
		if job.is_empty():
			continue
		var target: Dictionary = TestAccess.approach_giver(world).get_job_targets().get(String(job["id"]), {})
		if String(target.get("kind", "")) == "actor" and String(target.get("id", "")) == "near_target":
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the hunter must commit to the nearer target first for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(TestAccess.get_job(world, approach_job_id).get("status", "")) in ["queued", "active"],
		"the approach job must still be in flight when its target dies for this check to be meaningful")

	TestAccess.remove_colonist_by_id(world, "near_target", true) # simulates the current target dying
	_assert_no_orphaned_reservations(world, "immediately after the target's death")

	var retargeted := false
	for i in 100:
		world.tick()
		_assert_no_orphaned_reservations(world, "actor retarget search tick %d" % world.get_tick())
		var job := _approach_job_of(world, "hunter")
		if job.is_empty():
			continue
		var target: Dictionary = TestAccess.approach_giver(world).get_job_targets().get(String(job["id"]), {})
		if String(target.get("kind", "")) == "actor" and String(target.get("id", "")) == "far_target":
			retargeted = true
			break
	_expect(retargeted, "destroying the current target must cause the hostile to pick the next nearest reachable target within a bounded number of further ticks")
	_assert_no_orphaned_reservations(world, "end of actor retarget-succeeds scenario")

## Retarget rule (A), second trigger: the same cancel-and-retarget
## behaviour for an object target whose health/objectAt entry clears (the
## symmetric object case of the actor-death check above; ADR 033's target
## set always includes objects).
func _check_approach_retargets_when_object_target_destroyed() -> void:
	if _failed: return
	var world := _build_arena(111)
	_spawn_actor(world, "raiders", "wrecker", 0, 5)
	TestAccess.object_table(world).set_object(10, 5, "wooden_wall") # nearer object target (defaults to colony faction, hostile to raiders)
	TestAccess.object_table(world).set_object(30, 5, "wooden_wall") # farther object target
	world.tick() # backfills "combat"/"health" before this test mutates it

	var approach_job_id := ""
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-destruction tick %d" % world.get_tick())
		var job := _approach_job_of(world, "wrecker")
		if job.is_empty():
			continue
		var target: Dictionary = TestAccess.approach_giver(world).get_job_targets().get(String(job["id"]), {})
		if String(target.get("kind", "")) == "object" and target.get("tile") == Vector2i(10, 5):
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the wrecker must commit to the nearer wall first for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(TestAccess.get_job(world, approach_job_id).get("status", "")) in ["queued", "active"],
		"the approach job must still be in flight when its target is destroyed for this check to be meaningful")

	TestAccess.object_table(world).set_object(10, 5, "") # simulates the current object target being destroyed/cleared
	_assert_no_orphaned_reservations(world, "immediately after the object's destruction")

	var retargeted := false
	for i in 100:
		world.tick()
		_assert_no_orphaned_reservations(world, "object retarget search tick %d" % world.get_tick())
		var job := _approach_job_of(world, "wrecker")
		if job.is_empty():
			continue
		var target: Dictionary = TestAccess.approach_giver(world).get_job_targets().get(String(job["id"]), {})
		if String(target.get("kind", "")) == "object" and target.get("tile") == Vector2i(30, 5):
			retargeted = true
			break
	_expect(retargeted, "destroying the current object target must cause the hostile to pick the next nearest reachable target")
	_assert_no_orphaned_reservations(world, "end of object retarget-succeeds scenario")

## Retarget rule (A), adjacent-hostile case: a tracked approach job's own
## recorded target dying must still be cancelled even on a tick the actor also
## happens to stand adjacent to a different hostile (the existing attack rule's
## own target, never this stale job's own) -- advance()'s rule 1
## (`nearest_adjacent_hostile()` non-empty -> do nothing) used to run before
## this cleanup, and its own early `continue` skipped it entirely, leaving a
## dead target's job (and its reservation) tracked forever whenever another
## hostile happened to be adjacent the same tick. `adjacent_bait` is re-pinned
## next to the hunter's own current tile every loop iteration (never a one-shot
## placement): the hunter's tracked job keeps walking it toward its own now-dead
## target's tile even after death, since the job's own target is a fixed
## Vector2i established at commit time, so a one-shot placement could drift out
## of adjacency before ApproachGiver's own post-movement rule-1 check ever saw
## it.
func _check_approach_cancels_stale_target_while_adjacent_to_different_hostile() -> void:
	if _failed: return
	var world := _build_arena(120)
	_spawn_actor(world, "raiders", "hunter", 0, 5)
	_spawn_actor(world, "colony", "far_target", 30, 5)
	world.tick() # backfills "combat"/"health" before this test mutates them

	var approach_job_id := ""
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-adjacency tick %d" % world.get_tick())
		var job := _approach_job_of(world, "hunter")
		if String(job.get("status", "")) in ["queued", "active"]:
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the hunter must commit to the distant target for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"the committed approach job must have a tracked target for this check to be meaningful")

	var hunter := TestAccess.find_colonist(world, "hunter")
	var bait := _spawn_actor(world, "colony", "adjacent_bait", int(hunter["x"]), int(hunter["y"]) - 1)
	TestAccess.remove_colonist_by_id(world, "far_target", true) # the tracked job's own target dies

	var saw_adjacent := false
	var cancelled := false
	for i in 20:
		# Offset by y, not x: the hunter's
		# own route runs due east, so re-pinning the bait one tile north of the
		# hunter's own pre-tick position stays Chebyshev-adjacent to both of
		# the hunter's possible post-movement positions this tick (unmoved, or
		# one step east) -- a west/east offset computed pre-tick would fall out
		# of adjacency the instant the hunter actually takes a step.
		var h := TestAccess.find_colonist(world, "hunter")
		bait["x"] = int(h["x"])
		bait["y"] = int(h["y"]) - 1
		world.tick()
		_assert_no_orphaned_reservations(world, "adjacent-stale-target tick %d" % world.get_tick())
		if world.get_actor_combat_reason("hunter") == "fighting":
			saw_adjacent = true
		if String(TestAccess.get_job(world, approach_job_id).get("status", "")) not in ["queued", "active"]:
			cancelled = true
			break
	_expect(saw_adjacent, "the hunter must be reported adjacent to a hostile (adjacent_bait) at some point for this check to be meaningful")
	_expect(cancelled, "a tracked approach job's own target dying must still cancel it even on a tick the actor stands adjacent to a different hostile")
	_expect(not TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"the cancelled job's target association must be dropped, not left stale, regardless of the actor's own adjacency to a different hostile")
	_assert_no_orphaned_reservations(world, "end of adjacent-stale-target scenario")

## Retarget rule (A)'s queued+blocked-unreachable trigger: isolates the branch
## `advance()` itself watches for (`status == "queued" and reason ==
## BLOCKED_TARGET_UNREACHABLE`) from the separate active-route-cancelled-by-
## `WorldState._toil_on_unreachable()` path the existing fallback checks
## exercise instead -- the tracked job here is proven to go straight from
## freshly "queued" to cancelled without ever passing through "active" at
## all, so only the queued-and-blocked branch could have produced it. The
## corridor is severed with a full, gapless wall column (never touching the
## job's own destination tile itself) so the target stays perfectly bare and
## reservation-eligible throughout -- only the route is cut -- isolating
## JobQueue's own reachability check from the separate reservation-
## eligibility gate a held/occupied destination tile would instead trip.
func _check_approach_retargets_when_queued_job_goes_blocked_unreachable() -> void:
	if _failed: return
	var world := _build_arena(122)
	_spawn_actor(world, "raiders", "hunter", 0, 5)
	_spawn_actor(world, "colony", "far_target", 30, 5)
	world.tick() # backfills "combat"/"health" before this test mutates them

	var approach_job_id := ""
	var target := Vector2i.ZERO
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-seal tick %d" % world.get_tick())
		var job := _approach_job_of(world, "hunter")
		if String(job.get("status", "")) in ["queued", "active"]:
			approach_job_id = String(job["id"])
			target = job["target"]
			break
	_expect(not approach_job_id.is_empty(), "the hunter must commit to the distant target for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(TestAccess.get_job(world, approach_job_id).get("status", "")) == "queued",
		"the freshly committed approach job must still be queued, not yet active, for this check to isolate the queued path")

	# Seals the only corridor between the hunter and its own tracked target,
	# using the hunter's own "raiders" faction so the seal creates no new
	# hostile target (mirrors _check_approach_falls_back_to_incident_when_fully_walled_off()'s
	# own trick).
	for y in WorldStateType.MAP_HEIGHT:
		TestAccess.object_table(world).set_object(15, y, "wooden_wall", "raiders")
	var hunter := TestAccess.find_colonist(world, "hunter")
	_expect(not TestAccess.passability(world).region_reachable(Vector2i(int(hunter["x"]), int(hunter["y"])), target),
		"the tracked job's own target must actually become unreachable once the corridor is sealed, for this check to be meaningful")
	_assert_no_orphaned_reservations(world, "immediately after sealing the corridor")

	var ever_active := false
	var cancelled := false
	for i in 20:
		world.tick()
		_assert_no_orphaned_reservations(world, "seal-and-cancel tick %d" % world.get_tick())
		var status := String(TestAccess.get_job(world, approach_job_id).get("status", ""))
		if status == "active":
			ever_active = true
		if status not in ["queued", "active"]:
			cancelled = true
			break
	_expect(not ever_active, "a queued job whose target becomes unreachable must be cancelled without ever activating, isolating the queued+blocked_target_unreachable path from the separate active-route-unreachable path")
	_expect(cancelled, "a tracked approach job that goes queued+blocked_target_unreachable must be cancelled through the shared finish boundary")
	_expect(not TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"the cancelled job's target association must be dropped, not left stale")
	_assert_no_orphaned_reservations(world, "end of queued-blocked-unreachable scenario")

	# The corridor is sealed on every side; no replacement job may commit either (rule 5 fallback).
	for i in 15:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-seal fallback tick %d" % world.get_tick())
	_expect(String(_approach_job_of(world, "hunter").get("status", "")) not in ["queued", "active"],
		"no approach job may be left queued or active once the only route to every reachable target is sealed")

## Retarget rule (A)'s fallback branch: once every reachable target is
## walled off, cancellation (here via a tracked job going queued+blocked-
## unreachable, or cancelled by WorldState._toil_on_unreachable() mid-walk --
## whichever fires first) leaves the actor with no approach job at all, rule
## 5 re-evaluated fresh every tick rather than a permanent latch, free for
## IncidentScheduler's own walk-then-wait to drive it -- this giver never
## cancels or interferes with that unrelated incident job.
func _check_approach_falls_back_to_incident_when_fully_walled_off() -> void:
	if _failed: return
	var world := _build_wolf_door_world(112)

	var committed := false
	for i in 150:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-wall-off tick %d" % world.get_tick())
		if String(_approach_job_of(world, "wolf_1").get("status", "")) in ["queued", "active"]:
			committed = true
			break
	_expect(committed, "the wolf must have a tracked approach job before it gets sealed off, for this check to be meaningful")
	if not committed:
		return

	# Seals the wolf's own current tile with walls on every neighbor (the map
	# edge itself seals any side that would fall out of bounds), using the
	# wolf's own "wildlife" faction so the seal creates no new hostile target
	# for it to fight or approach instead -- only the map edge/these walls
	# stand between it and every target the fixture placed.
	var wolf := TestAccess.find_colonist(world, "wolf_1")
	var wx := int(wolf["x"])
	var wy := int(wolf["y"])
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var nx := wx + dx
			var ny := wy + dy
			if nx < 0 or ny < 0 or nx >= WorldStateType.MAP_WIDTH or ny >= WorldStateType.MAP_HEIGHT:
				continue
			TestAccess.object_table(world).set_object(nx, ny, "wooden_wall", "wildlife")
	_assert_no_orphaned_reservations(world, "immediately after sealing the wolf in")

	var stopped_pursuing := false
	for i in 250:
		world.tick()
		_assert_no_orphaned_reservations(world, "fallback tick %d" % world.get_tick())
		if String(_approach_job_of(world, "wolf_1").get("status", "")) not in ["queued", "active"]:
			stopped_pursuing = true
			break
	_expect(stopped_pursuing, "walling off every reachable target must cause the hostile to stop pursuing")

	for i in 20:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-fallback settle tick %d" % world.get_tick())
	_expect(String(_approach_job_of(world, "wolf_1").get("status", "")) not in ["queued", "active"],
		"no approach job may be left queued or active once every reachable target is walled off")
	_assert_no_orphaned_reservations(world, "end of fallback scenario")

## The check above uses a wolf
## appended directly to the roster (`_spawn_actor()`), never through
## IncidentScheduler, so it cannot prove the fallback rule actually leaves an
## unrelated incident job's own walk-then-wait lifecycle untouched. Proves it
## with a real `_incidents.propose()` actor/job: its own incident job (a walk
## on the actor's own side of a sealed corridor, entirely unrelated to combat)
## commits, activates and runs to natural completion -- despawning the actor,
## exactly like an uninterrupted incident always does -- the whole time a
## separate, already-committed `approach` job for a sealed-off colony target
## sits alongside it. `submit_autonomous()`'s own worker exclusivity (a busy
## worker's other queued entries are never re-selected for activation, see
## `GlobalAssignment.tick()`) means that approach job can only ever sit
## "queued", never "active", for as long as the incident job keeps the same
## actor busy -- proving ApproachGiver neither races nor interferes with it:
## the incident finishes on its own schedule, and the now-orphaned approach
## job is swept up by the ordinary despawn cleanup
## (`WorldState._cleanup_actor_scheduling()`) exactly like any other
## nonterminal job restricted to a removed actor, never left behind.
func _check_approach_fallback_never_interferes_with_unrelated_incident_job() -> void:
	if _failed: return
	var world := _build_arena(114)
	var actor_id := "raider_1"
	# wait_ticks=5 (short) keeps the incident's own walk-then-wait bounded so
	# it completes (and despawns the actor) well within this check's own tick
	# budget below; its target (0, 15) sits on the actor's own side of the
	# corridor sealed further down, so the seal never affects it.
	var incident_job_id := TestAccess.incidents(world).propose(_make_incident_actor(world, actor_id, 0, 0), Vector2i(0, 15), 5)
	_expect(not incident_job_id.is_empty(), "the incident proposal must be accepted")
	_spawn_actor(world, "colony", "villager", 30, 0) # the actor's own separate, unrelated hostile target

	var approach_job_id := ""
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-seal tick %d" % world.get_tick())
		_expect(String(TestAccess.get_job(world, incident_job_id).get("status", "")) != "cancelled",
			"the incident actor's own job must never be cancelled by this giver just because its own combat retargeting is in progress (tick %d)" % world.get_tick())
		var job := _approach_job_of(world, actor_id)
		if String(job.get("status", "")) in ["queued", "active"]:
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the incident actor must commit an approach job to the villager for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(TestAccess.get_job(world, incident_job_id).get("status", "")) == "active",
		"the incident actor's own job must still be active while its unrelated approach job commits, for this check to be meaningful")

	# Seals the only corridor to the villager using the actor's own "raiders"
	# faction (mirrors _check_approach_falls_back_to_incident_when_fully_walled_off()'s
	# own trick) so the seal itself is never a new hostile target -- the
	# incident job's own target (0, 15) is untouched by it.
	for y in WorldStateType.MAP_HEIGHT:
		TestAccess.object_table(world).set_object(15, y, "wooden_wall", "raiders")
	_assert_no_orphaned_reservations(world, "immediately after sealing the corridor")

	var incident_completed := false
	for i in 200:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-seal tick %d" % world.get_tick())
		if String(TestAccess.get_job(world, incident_job_id).get("status", "")) == "completed":
			incident_completed = true
			break
	_expect(incident_completed, "the incident actor's own walk-then-wait job must reach completed status on its own, entirely unaffected by the sealed-off, unrelated approach job")
	_expect(TestAccess.find_colonist(world, actor_id).is_empty(), "the incident actor must despawn on its own job's natural completion, exactly like an uninterrupted incident")
	_expect(String(TestAccess.get_job(world, approach_job_id).get("status", "")) not in ["queued", "active"],
		"the sealed-off approach job must not be left queued or active once its own actor is gone")
	_expect(not TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"the despawned actor must leave no stale approach target association behind")
	_assert_no_orphaned_reservations(world, "end of incident-fallback-non-interference scenario")

## The two checks above never prove the same actor falling
## back to and completing its own IncidentScheduler walk-then-wait after
## approach retargeting fails -- the wolf above has no incident job at all,
## and the incident-actor check above never gets its own approach job
## active (worker exclusivity means it can only ever sit queued behind an
## already-active incident job, per that check's own comment). This proves
## the missing causality: the actor's own approach job commits and goes
## active first (chasing a reachable colony target); only then is a real
## "incident" kind job submitted for the same actor, directly through
## `WorldState._submit_incident_job()`/`IncidentScheduler.adopt()` -- the
## same two primitives `IncidentScheduler.propose()`/`activate_pending()`
## use internally, minus the edge-tile spawn choreography this already-live
## actor does not need -- so it sits queued behind the busy worker, exactly
## like "IncidentScheduler's own walk-then-wait already has it doing".
## Sealing off the approach target with no replacement then cancels the
## approach job (rule 5) and frees the worker: the same actor's own queued
## incident job activates through the ordinary fair-queue path -- no special
## hook, no giver interrupts it -- walks to its own destination, waits, and
## completes to natural despawn.
func _check_approach_fallback_resumes_same_actors_own_incident_job() -> void:
	if _failed: return
	var world := _build_arena(115)
	var actor_id := "raider_2"
	_spawn_actor(world, "raiders", actor_id, 0, 0)
	_spawn_actor(world, "colony", "hostile_target", 30, 0)
	world.tick() # backfills "combat"/"health" before ApproachGiver reads it

	var approach_job_id := ""
	for i in 150:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-commit tick %d" % world.get_tick())
		var job := _approach_job_of(world, actor_id)
		if String(job.get("status", "")) == "active":
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the actor's own approach job must be active before its own incident job is submitted, for this check to be meaningful")
	if approach_job_id.is_empty():
		return

	# Mirrors the corridor-sealing trick above: (0, 15) sits on the actor's
	# own side (x < 15) of the wall column sealed further down, so the
	# incident job's own target stays reachable regardless of the seal.
	var incident_target := Vector2i(0, 15)
	var incident_job_id := TestAccess.submit_incident_job(world, actor_id, incident_target)
	_expect(not incident_job_id.is_empty(), "the actor's own incident-kind job must be accepted")
	if incident_job_id.is_empty():
		return
	TestAccess.incidents(world).adopt(incident_job_id, actor_id)
	TestAccess.set_work_progress(world, incident_target, 5)
	_expect(String(TestAccess.get_job(world, incident_job_id).get("status", "")) == "queued",
		"the actor's own incident job must sit queued behind its already-active approach job, for this check to be meaningful")
	_assert_no_orphaned_reservations(world, "immediately after queuing the actor's own incident job")

	# Seals the only corridor to the hostile target using the actor's own
	# "raiders" faction (mirrors _check_approach_falls_back_to_incident_when_fully_walled_off()'s
	# own trick) so the seal itself is never a new hostile target -- the
	# incident job's own target (0, 15) is untouched by it.
	for y in WorldStateType.MAP_HEIGHT:
		TestAccess.object_table(world).set_object(15, y, "wooden_wall", "raiders")
	_assert_no_orphaned_reservations(world, "immediately after sealing the corridor")

	var approach_cancelled := false
	for i in 250:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-seal tick %d" % world.get_tick())
		if String(TestAccess.get_job(world, approach_job_id).get("status", "")) not in ["queued", "active"]:
			approach_cancelled = true
			break
	_expect(approach_cancelled, "walling off the actor's own approach target with no replacement must cancel its approach job")
	_expect(not TestAccess.approach_giver(world).get_job_targets().has(approach_job_id),
		"the cancelled approach job must leave no stale target association behind")

	var incident_completed := false
	for i in 200:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-fallback tick %d" % world.get_tick())
		if String(TestAccess.get_job(world, incident_job_id).get("status", "")) == "completed":
			incident_completed = true
			break
	_expect(incident_completed, "the actor's own queued incident job must activate through the ordinary fair-queue path once its approach job frees the worker, and reach completed status on its own walk-then-wait")
	_expect(TestAccess.find_colonist(world, actor_id).is_empty(), "the actor must despawn on its own incident job's natural completion, exactly like an uninterrupted incident")
	_expect(String(TestAccess.get_job(world, approach_job_id).get("status", "")) not in ["queued", "active"],
		"the sealed-off approach job must stay terminated, never left queued or active once its own actor is gone")
	_assert_no_orphaned_reservations(world, "end of same-actor fallback scenario")

## Retarget rule (B): confirms ApproachGiver's owns()-check deference end
## to end -- a hostile actor whose hp fraction drops below its own
## flee_hp_fraction while mid-approach is interrupted into CombatGiver's flee
## job, its own approach job cleanly paused (never left active, never
## orphaned), and resumes approaching once its hp fraction recovers, picking
## up wherever ApproachGiver's own target-selection logic puts it fresh.
func _check_approach_flee_interrupt_and_resume() -> void:
	if _failed: return
	var world := _build_arena(113)
	_spawn_actor(world, "raiders", "hunter_raider", 0, 0)
	_spawn_actor(world, "colony", "far_target", 25, 0)
	world.tick() # backfills "combat"/"health" before this test mutates them

	var approach_job_id := ""
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-flee tick %d" % world.get_tick())
		var job := _approach_job_of(world, "hunter_raider")
		if String(job.get("status", "")) == "active":
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "an active approach job must exist mid-chase for this check to be meaningful")
	if approach_job_id.is_empty():
		return

	TestAccess.find_colonist(world, "hunter_raider")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world.tick()
	_expect(TestAccess.combat_giver(world).owns("hunter_raider"),
		"a hostile actor whose hp fraction drops below its own flee_hp_fraction mid-approach must be claimed by CombatGiver")
	_expect(String(TestAccess.get_job(world, approach_job_id).get("status", "")) != "active",
		"the approach job must not be left active once CombatGiver interrupts it for a flee episode")
	_assert_no_orphaned_reservations(world, "immediately after the flee interrupt")

	var flee_job_found := false
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and TestAccess.job_restricted_to(world, String(job["id"])) == "hunter_raider":
			flee_job_found = true
	_expect(flee_job_found, "a hostile actor below its own flee_hp_fraction mid-approach must be given a flee job instead")

	for i in 30:
		world.tick()
		_assert_no_orphaned_reservations(world, "mid-flee tick %d" % world.get_tick())
	_expect(String(TestAccess.get_job(world, approach_job_id).get("status", "")) != "active",
		"the paused approach job must still not be active while the flee episode is ongoing, never left orphaned")

	TestAccess.find_colonist(world, "hunter_raider")["health"]["hp"] = 100 # recover above the flee threshold
	var recovered := false
	for i in 80:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-recovery tick %d" % world.get_tick())
		if not TestAccess.combat_giver(world).owns("hunter_raider"):
			recovered = true
			break
	_expect(recovered, "a hostile actor must recover from its flee episode within a bounded number of ticks once its hp fraction recovers")

	var resumed := false
	for i in 80:
		world.tick()
		_assert_no_orphaned_reservations(world, "resume-approach tick %d" % world.get_tick())
		if String(_approach_job_of(world, "hunter_raider").get("status", "")) in ["queued", "active"]:
			resumed = true
			break
	_expect(resumed, "a recovered hostile actor must resume approaching once its hp fraction recovers")
