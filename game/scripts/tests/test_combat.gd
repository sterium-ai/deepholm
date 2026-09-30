extends SceneTree

## F5 combat resolution (ADR 021): headless, no-scene proof of the
## generic combat rules using two synthetic fixture actors in opposing
## factions (colony vs raiders, both already mutually hostile per
## content/factions.json) -- independent of wolf/trader content. Covers: damage
## lands every `cooldown` ticks, not every tick; death at hp 0 drops inventory
## as loose items and removes the actor from scheduling; a wall reduced to hp 0
## clears to no object; an actor at/below its own flee_hp_fraction stops
## fighting and starts a `flee` job that actually moves it; and two fresh runs
## of the same seed produce identical state hashes (determinism, AGENTS.md's
## simulation rules).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")

const SAVE_WRITE_FLEE_DIR := "user://test-combat-save-write-flee"

const TICK_RATE := 10

var _failed := false

func _init() -> void:
	_check_damage_every_cooldown_not_every_tick()
	_check_cooldown_elapses_while_disengaged()
	_check_death_drops_inventory_and_removes_from_scheduling()
	_check_death_releases_queued_job_and_held_tool()
	_check_wall_destroyed_at_zero_hp()
	_check_flee_threshold_is_strict()
	_check_flee_below_threshold()
	_check_flee_interrupts_active_work()
	_check_flee_wins_over_resuming_work_across_ticks()
	_check_flee_wins_over_committed_need_job()
	_check_flee_wins_while_need_searching()
	_check_flee_target_avoids_blocked_direction()
	_check_flee_target_requires_separation_improvement()
	_check_targeting_prefers_hostile_among_multiple_occupants()
	_check_object_health_survives_save_load()
	_check_flee_association_survives_save_load()
	_check_flee_association_survives_save_load_before_activation()
	_check_save_write_accepts_flee_jobs_at_every_status()
	_check_health_bar_pure_functions()
	_check_determinism_same_seed()
	_check_death_during_need_job_releases_paused_work()
	_check_flee_avoids_reserved_destination()
	_check_flee_target_excludes_faction_blocked_door()
	_check_flee_interrupted_incident_job_survives_save_load()
	_check_object_health_validation()
	_check_dead_worker_pending_search_frees_job_for_other_worker()
	_check_flee_recovery_retires_searching_job()
	_check_flee_recovery_retires_active_job()
	_check_flee_blocked_targets_survive_save_load_and_match_uninterrupted()
	_check_death_drops_generic_inventory_tools_into_tool_store()
	_check_flee_recovery_after_save_load_matches_uninterrupted()
	_check_flee_recovery_after_destination_exhaustion()
	_check_death_drops_every_inventory_tool_unit_usable_by_workers()
	_check_need_search_survives_flee_activation()
	_check_need_onset_during_existing_flee_episode()
	_check_flee_pending_search_survives_save_load_faction_aware()
	_check_flee_active_reroute_survives_save_load_faction_aware()
	_check_flee_recovery_resume_needs_fresh_route_faction_aware()
	_check_need_cancel_defers_to_active_flee_episode()
	_check_flee_recovery_of_disconnected_incident_target_cancels_without_replacement()
	_check_despawn_cleans_up_suspended_incident_flee_job()
	_check_flee_completes_while_carrying_interrupted_job_cargo()
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
	print("test_combat: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Every reservation key must belong to an active job:
## the same invariant test_build.gd/test_haul_stockpile.gd/test_rescue.gd
## already check, called after every tick in the new retarget/fallback checks
## below so a mid-run leak (not just an end-state one) is caught too.
func _assert_no_orphaned_reservations(world: WorldStateType, context: String) -> void:
	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect(orphans.is_empty(), "no reservation may outlive its job (%s): orphans=%s" % [context, orphans])

## An all-floor, colonist-free world: a controlled arena for fixture actors,
## mirroring test_incidents.gd's own _build_arena() helper.
## A freshly generated world can place berry_bush
## objects (ADR 020); a leftover one would silently block a
## fixture's own hand-placed walls/doors or flee paths, exactly like
## test_incidents.gd's own _build_controlled_world()/_build_pocket_world()
## already guard against.
func _build_arena(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, false)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	return world

## A "colonist"-def actor under an arbitrary faction -- reusing the existing
## colonist definition (which has a `combat` component) rather than
## adding new species content.
func _spawn_actor(world: WorldStateType, faction_id: String, actor_id: String, x: int, y: int) -> Dictionary:
	var actor := ActorTableType.spawn("colonist", x, y, world._content, actor_id)
	# ActorTable.spawn() still literally builds the legacy single-slot
	# "carrying" field; mirror WorldState._spawn_colonists()'s own post-spawn
	# patch to the hands model.
	actor.erase("carrying")
	actor["hands"] = []
	actor["factionId"] = faction_id
	world._append_colonist(actor)
	return actor

## Colony vs raiders (content/factions.json: mutually "hostile") locked
## adjacent at (5,5)/(6,5), with one tick already run so both carry a
## backfilled "combat"/"health" component (WorldState._ensure_combat()).
func _build_fighters(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	_spawn_actor(world, "colony", "fighter_a", 5, 5)
	_spawn_actor(world, "raiders", "fighter_b", 6, 5)
	world.tick()
	return world

func _check_damage_every_cooldown_not_every_tick() -> void:
	if _failed: return
	var world := _build_fighters(1)
	var cooldown := int(world._find_colonist("fighter_a")["combat"]["cooldown"])
	_expect(cooldown > 1, "the colonist combat tunable's cooldown must be greater than 1 tick for this check to be meaningful")
	var hp_after_first := int(world._find_colonist("fighter_b")["health"]["hp"])
	_expect(hp_after_first == 100 - 2, "the first tick with an adjacent hostile target must land a hit immediately")
	while world.get_tick() < cooldown:
		world.tick()
		var hp_now := int(world._find_colonist("fighter_b")["health"]["hp"])
		_expect(hp_now == hp_after_first, "no second hit may land before the attacker's own cooldown elapses (tick %d)" % world.get_tick())
	world.tick()
	var hp_after_second := int(world._find_colonist("fighter_b")["health"]["hp"])
	_expect(hp_after_second == hp_after_first - 2, "a second hit must land exactly `cooldown` ticks after the first (tick %d)" % world.get_tick())
	_expect(world.get_actor_combat_reason("fighter_a") == "fighting", "an actor with an adjacent hostile target must be reported as fighting")

func _check_death_drops_inventory_and_removes_from_scheduling() -> void:
	if _failed: return
	var world := _build_arena(2)
	_spawn_actor(world, "raiders", "attacker", 5, 5)
	_spawn_actor(world, "colony", "victim", 6, 5)
	# "till" (no needs_tool, unlike "dig"/"chop") keeps this a plain
	# reserve/go_to/work job so the assignment activates within one tick.
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(7, 5), 1, world.get_tick(), "till", "victim")
	_expect(submit_result.get("ok", false), "the victim's own till job must be accepted")
	var job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(not (world.get_assignments().get("victim", {}) as Dictionary).is_empty(),
		"the victim's dig job must have an active scheduler assignment before death")

	var victim := world._find_colonist("victim")
	InventoryType.add_to_hands(victim, "wood", 3)
	victim["health"]["hp"] = 1
	var attacker := world._find_colonist("attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(world._find_colonist("victim").is_empty(), "a dead actor must be removed from the world")
	_expect((world.get_assignments().get("victim") == null), "a dead actor's scheduler assignment must be released")
	_expect(String(world._get_job(job_id).get("status", "")) in ["cancelled", "failed"],
		"a dead actor's own active job must be terminated, not left dangling")
	var found_wood := false
	for item in world.get_items():
		if int(item["x"]) == 6 and int(item["y"]) == 5 and String(item["kind"]) == "wood" and int(item["count"]) == 3:
			found_wood = true
	_expect(found_wood, "a dead actor's carried item must drop as a loose item on its own tile")

func _check_wall_destroyed_at_zero_hp() -> void:
	if _failed: return
	var world := _build_arena(3)
	_spawn_actor(world, "raiders", "wall_attacker", 5, 5)
	world._set_object(6, 5, "wooden_wall")
	world.tick()
	_expect(not world._object_health_at(6, 5).is_empty(), "a freshly placed wall must carry per-instance health")
	var attacker := world._find_colonist("wall_attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()
	_expect(world.get_object(6, 5) == "", "a wall reduced to 0 hp must clear to no object (floor underneath)")
	_expect(world._object_health_at(6, 5).is_empty(), "a destroyed object's health entry must be cleared")

func _check_flee_below_threshold() -> void:
	if _failed: return
	var world := _build_fighters(4)
	var prey := world._find_colonist("fighter_b")
	prey["health"]["hp"] = 25 # 25% of maxHp 100, below the colonist's own 0.3 flee_hp_fraction
	prey["combat"]["cooldown_remaining"] = 0 # ready to attack -- proves the withhold below is the flee rule itself, not a stale cooldown
	var hunter := world._find_colonist("fighter_a")
	hunter["combat"]["cooldown_remaining"] = 999 # isolate the prey's own flee/no-fight response this check
	var hunter_hp_before := int(hunter["health"]["hp"])
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	world.tick()

	_expect(world.get_actor_combat_reason("fighter_b") == "", "an actor at/below its own flee_hp_fraction must stop fighting")
	# The fleeing actor's own hp only proves it wasn't hit, not that it withheld its own attack -- assert its opponent's hp instead.
	_expect(int(world._find_colonist("fighter_a")["health"]["hp"]) == hunter_hp_before,
		"a fleeing actor with a ready cooldown must not land an attack on its opponent while below its flee threshold")

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a fleeing actor must be given a job of kind 'flee'")

	for i in 30:
		world.tick()
	var moved_pos := Vector2i(int(world._find_colonist("fighter_b")["x"]), int(world._find_colonist("fighter_b")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor must actually path away from its starting tile")

## The flee rule is "strictly below", not "at or below" --
## exactly at flee_hp_fraction must still fight; one hp below it must flee.
func _check_flee_threshold_is_strict() -> void:
	if _failed: return
	var world_at := _build_fighters(41)
	var prey_at := world_at._find_colonist("fighter_b")
	world_at._find_colonist("fighter_a")["combat"]["cooldown_remaining"] = 999
	prey_at["health"]["hp"] = 30 # exactly 0.3 of maxHp 100
	world_at.tick()
	_expect(world_at.get_actor_combat_reason("fighter_b") == "fighting", "an actor exactly at its own flee_hp_fraction must still fight")
	var has_flee_at_threshold := false
	for job in world_at.get_jobs():
		if String(job.get("kind", "")) == "flee":
			has_flee_at_threshold = true
	_expect(not has_flee_at_threshold, "an actor exactly at its own flee_hp_fraction must not be given a flee job")

	var world_below := _build_fighters(42)
	var prey_below := world_below._find_colonist("fighter_b")
	world_below._find_colonist("fighter_a")["combat"]["cooldown_remaining"] = 999
	prey_below["health"]["hp"] = 29 # one hp below 0.3 of maxHp 100
	world_below.tick()
	_expect(world_below.get_actor_combat_reason("fighter_b") == "", "an actor one hp below its own flee_hp_fraction must stop fighting")
	var has_flee_below_threshold := false
	for job in world_below.get_jobs():
		if String(job.get("kind", "")) == "flee":
			has_flee_below_threshold = true
	_expect(has_flee_below_threshold, "an actor strictly below its own flee_hp_fraction must be given a flee job")

## Cooldown must elapse on wall-clock ticks, not only while an
## adjacent target exists -- an actor that attacks, disengages for longer
## than its own cooldown, then re-engages must attack again immediately, not
## wait out a stale remaining value frozen from mid-engagement.
func _check_cooldown_elapses_while_disengaged() -> void:
	if _failed: return
	var world := _build_fighters(5) # one tick already run: fighter_a landed its first hit
	var cooldown := int(world._find_colonist("fighter_a")["combat"]["cooldown"])
	var fighter_b := world._find_colonist("fighter_b")
	var hp_after_first := int(fighter_b["health"]["hp"])
	# Disengage: move fighter_b far away for longer than `cooldown` ticks.
	fighter_b["x"] = 40
	fighter_b["y"] = 40
	for i in cooldown + 5:
		world.tick()
	_expect(int(world._find_colonist("fighter_b")["health"]["hp"]) == hp_after_first,
		"no hit may land while the two actors are not adjacent")
	# Re-engage: bring fighter_b back adjacent to fighter_a.
	var fighter_a := world._find_colonist("fighter_a")
	world._find_colonist("fighter_b")["x"] = int(fighter_a["x"]) + 1
	world._find_colonist("fighter_b")["y"] = int(fighter_a["y"])
	world.tick()
	_expect(int(world._find_colonist("fighter_b")["health"]["hp"]) == hp_after_first - 2,
		"cooldown elapsed during disengagement must let the very next re-engaged tick land a hit immediately, not wait out a stale remaining value")

## Fleeing must interrupt whatever the actor is already
## doing, not let it run to completion first.
func _check_flee_interrupts_active_work() -> void:
	if _failed: return
	var world := _build_arena(6)
	# The prey must be player-orderable (colony faction) for an ordinary
	# submit() to ever activate its own till job in the first place.
	_spawn_actor(world, "colony", "worker", 6, 5)
	_spawn_actor(world, "raiders", "hunter", 5, 5)
	var prey := world._find_colonist("worker")
	# Give the prey a normal work job elsewhere, activated before it takes damage.
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(7, 5), 1, world.get_tick(), "till", "worker")
	_expect(submit_result.get("ok", false), "the prey's own till job must be accepted")
	var work_job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(String(world._get_job(work_job_id).get("status", "")) == "active",
		"the prey's till job must be active before it starts fleeing")

	prey["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999
	world.tick()

	_expect(String(world._get_job(work_job_id).get("status", "")) != "active",
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
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(7, 5), 1, world.get_tick(), "till", "worker")
	_expect(submit_result.get("ok", false), "the worker's own till job must be accepted")
	var work_job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(String(world._get_job(work_job_id).get("status", "")) == "active",
		"the worker's till job must be active before it starts fleeing")

	world._find_colonist("worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var start_pos := Vector2i(int(world._find_colonist("worker")["x"]), int(world._find_colonist("worker")["y"]))
	var flee_became_active := false
	for _i in 10:
		world.tick()
		_expect(String(world._get_job(work_job_id).get("status", "")) != "active",
			"the worker's suspended till job must never win reassignment back while the worker is still below its own flee_hp_fraction (tick %d)" % world.get_tick())
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) == "active":
				flee_became_active = true
	_expect(flee_became_active, "the flee job must actually be assigned (status active), not merely sit queued behind the work it interrupted")
	var moved_pos := Vector2i(int(world._find_colonist("worker")["x"]), int(world._find_colonist("worker")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor whose own interrupted work re-enters the ordinary pool must still actually move away")

## An existing NeedGiver commitment (colonist_id -> job_id in
## GlobalAssignment.tick()'s `committed_needs` param) forces the scheduler to
## propose only that job to its worker, so a flee job merely sitting in the
## ordinary queue could never win the same worker's slot at all. Fakes the
## commitment through the same seam test_faction_reservations.gd uses
## (world._need_giver._pending), then proves CombatGiver's
## own commitment (layered on top by WorldState._committed_jobs()) wins
## instead once the worker drops below its own flee_hp_fraction.
func _check_flee_wins_over_committed_need_job() -> void:
	if _failed: return
	var world := _build_arena(21)
	_spawn_actor(world, "colony", "worker", 6, 5)
	_spawn_actor(world, "raiders", "hunter", 40, 40)
	var need_submit: Dictionary = world._scheduler.submit(Vector2i(20, 20), 1, world.get_tick(), "drink_water", "worker")
	_expect(need_submit.get("ok", false), "direct scheduler submission of the need job must be accepted")
	var need_job_id := String(need_submit.get("job_id", ""))
	world._need_giver._pending["worker"] = need_job_id
	world.tick()

	world._find_colonist("worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var start_pos := Vector2i(int(world._find_colonist("worker")["x"]), int(world._find_colonist("worker")["y"]))
	var flee_became_active := false
	for _i in 10:
		world.tick()
		_expect(String(world._get_job(need_job_id).get("status", "")) != "active",
			"an existing committed need job must not out-rank the worker's own flee job while it is below its flee_hp_fraction (tick %d)" % world.get_tick())
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) == "active":
				flee_became_active = true
	_expect(flee_became_active, "a flee job must actually win assignment over an existing committed need job")
	var moved_pos := Vector2i(int(world._find_colonist("worker")["x"]), int(world._find_colonist("worker")["y"]))
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
	world._find_colonist("worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world._need_giver._searching["worker"] = {"kind": "water", "candidates": [Vector2i(20, 20)],
		"distances": [29], "cursor": 0, "search": null, "found": []}
	# _apply_combat() (inside this tick) must record "worker" into CombatGiver's
	# own `_fleeing` before this same tick's _scheduler_workers() call is built,
	# so it is already exercising the fix by the time the very first tick ends.
	world.tick()

	var included := false
	for colonist in world._colonists_not_searching_need():
		if String(colonist["id"]) == "worker":
			included = true
	_expect(included, "an actor CombatGiver already tracks as fleeing must still be proposed the scheduler tick even while mid need-search")

	var start_pos := Vector2i(int(world._find_colonist("worker")["x"]), int(world._find_colonist("worker")["y"]))
	var flee_became_active := false
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) == "active":
				flee_became_active = true
	_expect(flee_became_active, "an actor mid need-search must still actually be assigned its own flee job")
	var moved_pos := Vector2i(int(world._find_colonist("worker")["x"]), int(world._find_colonist("worker")["y"]))
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
		world._set_object(x, 10, "wooden_wall")
	world.tick() # backfills "combat" (ActorTable's spawn path does not add it) before this test mutates it
	var prey := world._find_colonist("prey")
	prey["health"]["hp"] = 25
	world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	for i in 20:
		world.tick()
	var moved_pos := Vector2i(int(world._find_colonist("prey")["x"]), int(world._find_colonist("prey")["y"]))
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
		world._set_object(pos.x, pos.y, "wooden_wall")
	for x in [12, 13, 14, 15]:
		world._set_object(x, 10, "wooden_wall")
	world.tick() # backfills "combat" before this test mutates it
	var prey := world._find_colonist("prey")
	prey["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	var threat_pos := Vector2i(0, 10)
	var start_distance := absi(start_pos.x - threat_pos.x) + absi(start_pos.y - threat_pos.y)
	for i in 20:
		world.tick()
	var moved_pos := Vector2i(int(world._find_colonist("prey")["x"]), int(world._find_colonist("prey")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor must actually move")
	_expect(moved_pos.x >= start_pos.x, "a fleeing actor must never move toward its own threat even when that is the only long escape available")
	var moved_distance := absi(moved_pos.x - threat_pos.x) + absi(moved_pos.y - threat_pos.y)
	_expect(moved_distance > start_distance, "a fleeing actor's own chosen destination must strictly increase its distance from the threat, never decrease it")

## actors_by_pos must not overwrite one occupant with
## another -- a friendly actor sharing a hostile actor's tile must never hide
## that hostile actor from targeting, in either insertion order.
func _check_targeting_prefers_hostile_among_multiple_occupants() -> void:
	if _failed: return
	for hostile_first in [true, false]:
		var world := _build_arena(8 if hostile_first else 9)
		_spawn_actor(world, "colony", "watcher", 5, 5)
		if hostile_first:
			_spawn_actor(world, "raiders", "enemy", 6, 5)
			_spawn_actor(world, "colony", "friend", 6, 5)
		else:
			_spawn_actor(world, "colony", "friend", 6, 5)
			_spawn_actor(world, "raiders", "enemy", 6, 5)
		world.tick() # backfills "combat" (ActorTable's spawn path does not add it) before this test mutates it, landing hostile_first's own first hit too
		var watcher := world._find_colonist("watcher")
		watcher["combat"]["cooldown_remaining"] = 0
		var enemy_hp_before := int(world._find_colonist("enemy")["health"]["hp"])
		world.tick()
		_expect(int(world._find_colonist("enemy")["health"]["hp"]) < enemy_hp_before,
			"a hostile occupant sharing a tile with a friendly one must still be targeted (insertion order hostile_first=%s)" % hostile_first)

## StateCodec.decode() restores `_objects` directly, bypassing
## `_set_object()` -- without `_ensure_object_health()`'s own backfill, a
## restored wall/door would carry no health entry and read as untargetable.
## A presence check alone only proves a health entry exists after
## load, not that its actual accumulated damage survived -- a wall/door
## silently reset to full health on every load would still pass it.
## Damages a wall and a door to distinct partial hp values before saving,
## proves both exact values (not the object's full/default health) survive
## the round trip, then proves combat continues uninterrupted from the
## persisted value afterward: further damage still lands relative to it, and
## reaching 0 still clears the object.
func _check_object_health_survives_save_load() -> void:
	if _failed: return
	var world := _build_arena(10)
	world._set_object(6, 5, "wooden_wall")
	world._set_object(7, 5, "door")
	world.tick()
	var wall_max := int(world._object_health_at(6, 5)["maxHp"])
	var door_max := int(world._object_health_at(7, 5)["maxHp"])
	world._damage_object(6, 5, 30)
	world._damage_object(7, 5, 15)
	var wall_hp_before := int(world._object_health_at(6, 5)["hp"])
	var door_hp_before := int(world._object_health_at(7, 5)["hp"])
	_expect(wall_hp_before == wall_max - 30, "a damaged wall must carry its exact damaged hp before save")
	_expect(door_hp_before == door_max - 15, "a damaged door must carry its exact damaged hp before save")
	_expect(wall_hp_before != wall_max and door_hp_before != door_max,
		"both fixtures must actually be damaged (below max) for this check to be meaningful")

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded.get_object(6, 5) == "wooden_wall", "a wall must survive a save/load round trip")
	_expect(loaded.get_object(7, 5) == "door", "a door must survive a save/load round trip")
	_expect(int(loaded._object_health_at(6, 5).get("hp", -1)) == wall_hp_before,
		"a damaged wall's exact hp must survive save/load, not reset to full")
	_expect(int(loaded._object_health_at(7, 5).get("hp", -1)) == door_hp_before,
		"a damaged door's exact hp must survive save/load, not reset to full")

	loaded._damage_object(6, 5, wall_hp_before)
	_expect(loaded.get_object(6, 5) == "", "a wall already damaged before save must clear to floor once its persisted hp (not a reset full hp) reaches 0 after load")
	loaded._damage_object(7, 5, door_hp_before - 1)
	_expect(int(loaded._object_health_at(7, 5).get("hp", -1)) == 1,
		"further damage after load must land relative to the persisted hp, not a reset full hp")

## CombatGiver's own `_fleeing` association is never
## serialized and starts empty after a load, even though the `flee` job it
## submitted before the save is still queued/active in state that did
## persist -- without adopting it back, a reload mid-flee would submit a
## second, duplicate leg every tick.
func _check_flee_association_survives_save_load() -> void:
	if _failed: return
	var world := _build_fighters(11)
	var prey := world._find_colonist("fighter_b")
	prey["health"]["hp"] = 25
	world._find_colonist("fighter_a")["combat"]["cooldown_remaining"] = 999
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
		if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) in ["queued", "active"] and loaded._job_restricted_to(String(job["id"])) == "fighter_b":
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
	var submit_result: Dictionary = world._scheduler.submit_autonomous(Vector2i(10, 10), 1, world.get_tick(), "flee", "fighter_b")
	_expect(submit_result.get("ok", false), "a directly submitted flee job must be accepted")
	var flee_job_id := String(submit_result.get("job_id", ""))
	_expect(String(world._get_job(flee_job_id).get("status", "")) == "queued",
		"the flee job must still be queued (never activated) at the moment of save for this check to be meaningful")
	# Mirrors exactly what CombatGiver.advance() itself would have recorded
	# had it submitted this job through the ordinary tick path.
	world._combat_giver._fleeing["fighter_b"] = flee_job_id

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	loaded._find_colonist("fighter_b")["health"]["hp"] = 25 # stay below flee_hp_fraction post-load, or CombatGiver would resume/cancel instead of adopting
	loaded.tick()
	var flee_jobs_after := 0
	for job in loaded.get_jobs():
		if String(job.get("kind", "")) == "flee" and String(job.get("status", "")) in ["queued", "active"] and loaded._job_restricted_to(String(job["id"])) == "fighter_b":
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
	var prey := world._find_colonist("fighter_b")
	prey["health"]["hp"] = 25
	world._find_colonist("fighter_a")["combat"]["cooldown_remaining"] = 999
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

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))

## A dead actor's queued (not-yet-activated) job restricted
## to it must be cancelled too, and its held tool must be moved to the
## ground rather than left pointing at a removed actor.
func _check_death_releases_queued_job_and_held_tool() -> void:
	if _failed: return
	var world := _build_arena(12)
	_spawn_actor(world, "raiders", "attacker", 5, 5)
	_spawn_actor(world, "colony", "victim", 6, 5)
	var victim := world._find_colonist("victim")

	var active_result: Dictionary = world._scheduler.submit(Vector2i(7, 5), 1, world.get_tick(), "till", "victim")
	_expect(active_result.get("ok", false), "the victim's own active till job must be accepted")
	var active_job_id := String(active_result.get("job_id", ""))
	world.tick()
	_expect(String(world._get_job(active_job_id).get("status", "")) == "active", "the victim's first job must be active before death")

	# A second job restricted to the same, already-busy victim: it can only
	# ever sit queued, never activated, since the victim has no free capacity.
	var queued_result: Dictionary = world._scheduler.submit(Vector2i(8, 5), 1, world.get_tick(), "till", "victim")
	_expect(queued_result.get("ok", false), "a second job restricted to the victim must still be accepted onto the queue")
	var queued_job_id := String(queued_result.get("job_id", ""))
	_expect(String(world._get_job(queued_job_id).get("status", "")) == "queued", "the second job restricted to the busy victim must remain queued, never activated")

	var tool_item_id := world._tool_store.spawn_ground("axe", int(victim["x"]), int(victim["y"]))
	world._tool_store.set_held(tool_item_id, "victim")
	_expect(String(world._tool_store.get_item(tool_item_id)["location"]["type"]) == "held", "the victim must be holding the tool before death")

	victim["health"]["hp"] = 1
	var attacker := world._find_colonist("attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(world._find_colonist("victim").is_empty(), "a dead actor must be removed from the world")
	_expect(String(world._get_job(active_job_id).get("status", "")) in ["cancelled", "failed"], "a dead actor's own active job must be terminated")
	_expect(String(world._get_job(queued_job_id).get("status", "")) in ["cancelled", "failed"],
		"a dead actor's own still-queued (never activated) job must also be terminated, not left dangling in the queue forever")
	var tool_location: Dictionary = world._tool_store.get_item(tool_item_id).get("location", {})
	_expect(String(tool_location.get("type", "")) == "ground", "a dead actor's held tool must be moved to the ground, not left pointing at a removed actor")
	_expect(int(tool_location.get("x", -1)) == 6 and int(tool_location.get("y", -1)) == 5, "a dead actor's dropped tool must land on its own death tile")

func _check_health_bar_pure_functions() -> void:
	if _failed: return
	_expect(is_equal_approx(ColonistSpritesType.health_bar_fill({"hp": 50, "maxHp": 100}), 0.5),
		"health_bar_fill must return the hp/maxHp fraction")
	_expect(is_equal_approx(ColonistSpritesType.health_bar_fill({"hp": 0, "maxHp": 100}), 0.0),
		"health_bar_fill must return 0 at 0 hp")
	_expect(ColonistSpritesType.health_bar_color(0.0) == Color.RED, "an empty bar must be red")
	_expect(ColonistSpritesType.health_bar_color(1.0) == Color.GREEN, "a full bar must be green")

func _build_combat_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	_spawn_actor(world, "colony", "det_a", 5, 5)
	_spawn_actor(world, "raiders", "det_b", 6, 5)
	world._set_object(7, 5, "wooden_wall")
	return world

func _check_determinism_same_seed() -> void:
	if _failed: return
	var world_a := _build_combat_world(99)
	var world_b := _build_combat_world(99)
	for i in 50:
		world_a.tick()
		world_b.tick()
	_expect(world_a.state_hash() == world_b.state_hash(), "two runs of the same seed must produce identical state hashes")

## An unrestricted work job's own assignment survived a
## death that occurred while the same actor's active assignment was instead a
## need job (a critical need having already interrupted/paused the work job).
## _apply_actor_death() cancelled the active need job first, whose
## NeedGiver.resolve_job() called _resume_interrupted_job() and reactivated
## the paused, unrestricted work job's own assignment for the about-to-be-
## removed actor -- _job_restricted_to() then found no restriction for it
## (unrestricted) and never cancelled it, leaving a dangling assignment and
## reservation. Mirrors _interrupt_current_job()'s own real call shape rather
## than NeedGiver's full decay/threshold machinery, exactly like the existing
## committed-need fakes above (_check_flee_wins_over_committed_need_job` etc.)
## already do for the same NeedGiver seam.
func _check_death_during_need_job_releases_paused_work() -> void:
	if _failed: return
	var world := _build_arena(34)
	_spawn_actor(world, "raiders", "reaper", 5, 5)
	_spawn_actor(world, "colony", "worker", 6, 5)
	world.tick() # backfills "combat"/"health" before this test mutates them

	# An unrestricted work job (restrict_to defaults to "" -- any eligible worker may take it).
	var work_result: Dictionary = world._scheduler.submit(Vector2i(7, 5), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	world.tick()
	_expect(String(world._get_job(work_job_id).get("status", "")) == "active", "the unrestricted till job must be active before the interrupt")
	_expect(String((world.get_assignments().get("worker", {}) as Dictionary).get("job_id", "")) == work_job_id,
		"the worker must be assigned the unrestricted till job before the interrupt")

	var worker := world._find_colonist("worker")
	world._interrupt_current_job(worker) # mirrors NeedGiver's own critical-need interrupt
	_expect(String(world._get_job(work_job_id).get("status", "")) == "queued", "the interrupted till job must be suspended back to queued")
	_expect(String(world._paused_jobs.get("worker", "")) == work_job_id, "the interrupted till job must be recorded as this worker's own paused job")

	var need_result: Dictionary = world._scheduler.submit(Vector2i(8, 5), 1, world.get_tick(), "drink_water", "worker")
	_expect(need_result.get("ok", false), "the worker's own restricted need job must be accepted")
	var need_job_id := String(need_result.get("job_id", ""))
	world._need_giver._pending["worker"] = need_job_id
	world.tick()
	_expect(String(world._get_job(need_job_id).get("status", "")) == "active", "the need job must be active before death for this check to be meaningful")
	_expect(String((world.get_assignments().get("worker", {}) as Dictionary).get("job_id", "")) == need_job_id,
		"the worker's own active assignment must be the need job, not the paused work job, at the moment of death")

	worker["health"]["hp"] = 1
	var reaper := world._find_colonist("reaper")
	reaper["combat"]["damage"] = 999
	reaper["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(world._find_colonist("worker").is_empty(), "a dead actor must be removed from the world")
	_expect(world.get_assignments().get("worker") == null,
		"a dead actor's scheduler assignment must be released, not reactivated onto its own previously-paused, unrestricted work")
	_expect(String(world._get_job(need_job_id).get("status", "")) in ["cancelled", "failed"], "the dead actor's own active need job must be terminated")
	_expect(String(world._get_job(work_job_id).get("status", "")) in ["cancelled", "failed"],
		"the dead actor's own previously-paused, unrestricted work job must also be terminated, not silently resumed and left dangling")
	_expect(not (world._paused_jobs as Dictionary).has("worker"), "a dead actor must leave no residual paused-job entry")
	_expect(world._need_giver.get_pending_job("worker").is_empty(), "a dead actor must leave no residual NeedGiver pending association")

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
	var reserve_result: Dictionary = world._scheduler.submit(reserved_tile, 1, world.get_tick(), "till")
	_expect(reserve_result.get("ok", false), "a job targeting the prey's own farthest escape tile must be accepted so it can actually reserve that tile")
	world.tick()
	_expect(String(world._get_job(String(reserve_result["job_id"])).get("status", "")) == "active",
		"the blocking job must actually be active (holding a live target reservation) for this check to be meaningful")

	var prey := world._find_colonist("prey")
	prey["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
	world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))
	world.tick()

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a fleeing actor must still be given a flee job even when its own preferred escape tile is reserved by another job")
	if not flee_job_id.is_empty():
		var flee_target: Vector2i = world._get_job(flee_job_id)["target"]
		_expect(flee_target != reserved_tile, "a flee job must never target a tile another job already reserves")

	for i in 20:
		world.tick()
	var moved_pos := Vector2i(int(world._find_colonist("prey")["x"]), int(world._find_colonist("prey")["y"]))
	_expect(moved_pos != start_pos, "a fleeing actor whose own preferred escape tile is reserved by another job must still find and move to an available alternate")

## RegionMap.reachable() (region_map.gd -- err, regions.gd:
## "Physical passability only -- no faction awareness") always evaluates door
## passability under the default "colony" faction, so it reports the whole
## map one connected region even across a door a hostile faction cannot pass
## -- a gap the coarse pre-submission check in _pick_flee_target() cannot see
## through. A full-height wall at x=14 (every row except the door itself at
## y=10) leaves the door as the only crossing between the raider's own west
## side and the entire east side -- not just its single preferred candidate,
## since an open arena would otherwise let the real route search simply walk
## around a lone door tile, proving nothing about faction blocking. The real
## per-tick route search (faction-aware) can never find a path past it, so
## every east-pointing candidate this actor tries repeatedly ends up
## blocked_target_unreachable while queued -- proving advance()'s cancel-and-
## exclude fix keeps trying different candidates (never looping on the same
## doomed tile, or a small fixed set of them, forever) until it reaches a
## direction that never needed the door at all.
## Shared fixture (second pass): the raider "prey" can only
## escape east through a single door its own faction may not pass
## (content/factions.json: raiders may_pass_doors=false), full-height walls
## on every other row of x=14 forcing every east-pointing candidate past x=14
## to repeatedly hit blocked_target_unreachable while queued. Factored out of
## _check_flee_target_excludes_faction_blocked_door() so
## _check_flee_blocked_targets_survive_save_load_and_match_uninterrupted()
## below can build two byte-identical worlds from the same setup.
func _build_faction_blocked_door_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	_spawn_actor(world, "colony", "hunter", 10, 10)
	_spawn_actor(world, "raiders", "prey", 11, 10) # threat directly west -- "away" ray points due east
	for y in WorldStateType.MAP_HEIGHT:
		if y == 10:
			continue
		world._set_object(14, y, "wooden_wall")
	world._set_object(14, 10, "door")
	world.tick() # backfills "combat" before a caller mutates it
	return world

func _check_flee_target_excludes_faction_blocked_door() -> void:
	if _failed: return
	var world := _build_faction_blocked_door_world(36)
	var prey := world._find_colonist("prey")
	prey["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
	world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999
	var start_pos := Vector2i(int(prey["x"]), int(prey["y"]))

	var max_x := start_pos.x
	for i in 150:
		world.tick()
		max_x = maxi(max_x, int(world._find_colonist("prey")["x"]))
	var moved_pos := Vector2i(int(world._find_colonist("prey")["x"]), int(world._find_colonist("prey")["y"]))
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

	world._find_colonist("prey")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world.tick() # submits the flee job and starts (but cannot finish) its route search this same tick

	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and world._job_restricted_to(String(job["id"])) == "prey":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "a flee job must exist for this check to be meaningful")
	_expect(String(world._get_job(flee_job_id).get("status", "")) == "queued",
		"the flee job's route search must still be in flight (status queued, not yet active) for this check to be meaningful")
	_expect(world._scheduler.get_pending().has("prey"),
		"the fleeing actor's own route search must still be mid-flight (GlobalAssignment._pending) for this check to be meaningful")

	world._find_colonist("prey")["health"]["hp"] = 100 # recover above the flee threshold
	world.tick()

	_expect(String(world._get_job(flee_job_id).get("status", "")) in ["cancelled", "failed", "completed"],
		"a flee job still mid-search at the moment of recovery must be retired, not left dangling")
	_expect(not world._scheduler.get_pending().has("prey"),
		"a retired flee job's own in-flight route search must be dropped, not left claiming its own candidate job forever")
	_expect(not world._combat_giver.get_committed_jobs().has("prey"),
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

	world._find_colonist("prey")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_job_id := ""
	var became_active := false
	for _i in 20:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "flee" and world._job_restricted_to(String(job["id"])) == "prey":
				flee_job_id = String(job["id"])
		if not flee_job_id.is_empty() and String(world._get_job(flee_job_id).get("status", "")) == "active":
			became_active = true
			break
	_expect(became_active, "the flee job must actually reach 'active' status for this check to be meaningful")
	var target: Vector2i = world._get_job(flee_job_id)["target"]
	_expect(world._flee_target_reserved(target.x, target.y),
		"an active flee job must hold a live reservation on its own destination for this check to be meaningful")

	world._find_colonist("prey")["health"]["hp"] = 100 # recover above the flee threshold
	world.tick()

	_expect(String(world._get_job(flee_job_id).get("status", "")) in ["cancelled", "failed", "completed"],
		"an active flee job must be retired on recovery, not left running (and its reservation held) indefinitely")
	_expect(not world._flee_target_reserved(target.x, target.y),
		"a retired flee job must release its own destination reservation, not leave it held forever")
	_expect(not world._combat_giver.get_committed_jobs().has("prey"),
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
		world._find_colonist("prey")["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
		world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999

	var blocked_before: Dictionary = {}
	var accumulated := false
	for i in 250:
		uninterrupted.tick()
		live.tick()
		blocked_before = (live._combat_giver.get_blocked_targets().get("prey", {}) as Dictionary)
		if blocked_before.size() >= 2:
			accumulated = true
			break
	_expect(accumulated, "the faction-blocked-door fixture must accumulate at least two excluded flee destinations within the bounded tick budget for this check to be meaningful")
	if not accumulated:
		return

	var loaded := StateCodecType.decode(StateCodecType.encode(live))
	var loaded_blocked: Dictionary = (loaded._combat_giver.get_blocked_targets().get("prey", {}) as Dictionary)
	_expect(loaded_blocked.size() == blocked_before.size(),
		"a save/load round trip must carry the exact same number of excluded flee destinations, got %d before vs %d after" % [blocked_before.size(), loaded_blocked.size()])
	for tile in blocked_before.keys():
		_expect(loaded_blocked.has(tile), "a save/load round trip must exclude the exact same destination tiles, got missing %s" % tile)

	for i in 150:
		uninterrupted.tick()
		loaded.tick()
		var uninterrupted_pos := Vector2i(int(uninterrupted._find_colonist("prey")["x"]), int(uninterrupted._find_colonist("prey")["y"]))
		var loaded_pos := Vector2i(int(loaded._find_colonist("prey")["x"]), int(loaded._find_colonist("prey")["y"]))
		_expect(uninterrupted_pos == loaded_pos,
			"a save made after multiple blocked flee destinations must reproduce identical subsequent positions to an uninterrupted run (tick %d)" % i)
		var uninterrupted_flee_status := ""
		var loaded_flee_status := ""
		for job in uninterrupted.get_jobs():
			if String(job.get("kind", "")) == "flee" and uninterrupted._job_restricted_to(String(job["id"])) == "prey":
				uninterrupted_flee_status = String(job["status"])
		for job in loaded.get_jobs():
			if String(job.get("kind", "")) == "flee" and loaded._job_restricted_to(String(job["id"])) == "prey":
				loaded_flee_status = String(job["status"])
		_expect(uninterrupted_flee_status == loaded_flee_status,
			"a save made after multiple blocked flee destinations must reproduce identical subsequent flee job transitions to an uninterrupted run (tick %d)" % i)

## Regression: _drop_inventory_contents() used to route a generic
## actor's inventory.tool slot and any tool-kind entry inside inventory.items
## through _place_ground_item() (the ordinary stackable-pile store), but
## every tool-match precondition (ToilExecutor's fetch-tool toil) only ever
## searches ToolItemStore -- the dropped tool was permanently invisible to
## any job that required one. Both must now land in ToolItemStore instead,
## reservable and holdable by a surviving worker exactly like an axe/pick
## spawned any other way; a non-tool kind inside inventory.items must still
## drop as an ordinary loose item, unchanged.
func _check_death_drops_generic_inventory_tools_into_tool_store() -> void:
	if _failed: return
	var world := _build_arena(46)
	_spawn_actor(world, "raiders", "attacker", 5, 5)
	_spawn_actor(world, "colony", "victim", 6, 5)
	world.tick() # backfills "combat"/"health" before this test mutates them
	var victim := world._find_colonist("victim")
	victim["inventory"] = {"items": [{"kind": "axe", "count": 1}, {"kind": "wood", "count": 2}], "tool": "pick", "capacity": 3}

	victim["health"]["hp"] = 1
	var attacker := world._find_colonist("attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(world._find_colonist("victim").is_empty(), "a dead actor must be removed from the world")

	var dropped_axe_id := ""
	var dropped_pick_id := ""
	for tool_item in world.get_tool_items():
		var location: Dictionary = tool_item.get("location", {})
		if String(location.get("type", "")) != "ground" or int(location.get("x", -1)) != 6 or int(location.get("y", -1)) != 5:
			continue
		if String(tool_item["kind"]) == "axe":
			dropped_axe_id = String(tool_item["id"])
		elif String(tool_item["kind"]) == "pick":
			dropped_pick_id = String(tool_item["id"])
	_expect(not dropped_axe_id.is_empty(), "a tool kind inside inventory.items must land in ToolItemStore on the victim's own death tile, not the generic item pile")
	_expect(not dropped_pick_id.is_empty(), "inventory.tool must land in ToolItemStore on the victim's own death tile, not the generic item pile")

	var found_wood := false
	for item in world.get_items():
		if int(item["x"]) == 6 and int(item["y"]) == 5 and String(item["kind"]) == "wood" and int(item["count"]) == 2:
			found_wood = true
	_expect(found_wood, "a non-tool kind inside inventory.items must still drop as an ordinary loose item, unchanged")

	_expect(world.reserve_tool_item(dropped_axe_id, "job_surviving_worker"),
		"a surviving worker must be able to reserve a dead actor's dropped inventory.items tool through the ordinary ToolItemStore API")
	_spawn_actor(world, "colony", "smith", 20, 20)
	_expect(world.set_tool_item_held(dropped_pick_id, "smith"),
		"a surviving worker must be able to pick up and hold a dead actor's dropped inventory.tool through the ordinary ToolItemStore API")
	_expect(String(WorkerType.get_held_tool(world._find_colonist("smith"))) == dropped_pick_id,
		"a surviving worker holding a dead actor's dropped inventory.tool must be recorded exactly like picking up any other tool item")

## A synthetic incident actor (a "colonist"-def actor staged/spawned through
## IncidentScheduler.propose(), never a wolf/trader -- this file's own
## established convention) under a hostile faction, so it carries the
## `combat`/`flee_hp_fraction` component real wolf/trader content does not
## (flee_hp_fraction is colonist-only; there is no wolf/trader-specific data).
func _make_incident_actor(world: WorldStateType, actor_id: String, x: int, y: int) -> Dictionary:
	var actor := ActorTableType.spawn("colonist", x, y, world._content, actor_id)
	actor.erase("carrying")
	actor["hands"] = []
	actor["factionId"] = "raiders"
	return actor

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
	var job_id := world._incidents.propose(_make_incident_actor(world, actor_id, 0, 5), Vector2i(10, 5), 5)
	_expect(not job_id.is_empty(), "the incident proposal must be accepted")

	var spawn_ticks := 0
	while world._find_colonist(actor_id).is_empty() and spawn_ticks < 60:
		world.tick()
		spawn_ticks += 1
	_expect(not world._find_colonist(actor_id).is_empty(), "the incident actor must spawn onto the map for this check to be meaningful")
	_expect(String(world._get_job(job_id).get("status", "")) == "active", "the incident job must be active once its actor has spawned")
	# _ensure_combat() only backfills a colonist already in _colonists, one tick after it was spawned.
	world.tick()
	_expect(world._find_colonist(actor_id).get("combat") is Dictionary, "the spawned incident actor must carry a backfilled combat component for this check to be meaningful")

	_spawn_actor(world, "colony", "colony_defender", 40, 40) # far away; nearest_hostile_actor() is unbounded, giving the incident actor a threat to flee without ever taking a hit itself

	var reaper := world._find_colonist(actor_id)
	reaper["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
	world.tick()

	_expect(String(world._get_job(job_id).get("status", "")) == "queued",
		"combat's own flee interrupt must suspend the incident actor's active incident job back to queued")
	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and world._job_restricted_to(String(job["id"])) == actor_id:
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "the incident actor must be given its own flee job once it starts fleeing")
	_expect(String(world._paused_jobs.get(actor_id, "")) == job_id,
		"the incident actor's own paused-job entry must still name its interrupted incident job")

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(not loaded._find_colonist(actor_id).is_empty(), "the incident actor must survive a save/load while fleeing")
	_expect(String(loaded._get_job(job_id).get("status", "")) == "queued",
		"the incident actor's own paused incident job must survive a save/load, not be cancelled just for sitting queued")
	_expect(String(loaded._incidents._actor_by_job.get(job_id, "")) == actor_id,
		"the reloaded incident job must still be re-associated with its own actor so on_job_finished() can despawn it correctly")

	# Uninterrupted-lifecycle check: once the actor stops fleeing, its original incident job must actually resume and go active again, exactly like it would have without the save/load.
	loaded._find_colonist(actor_id)["health"]["hp"] = 100
	var resumed := false
	for i in 60:
		loaded.tick()
		if String(loaded._get_job(job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the incident actor's own paused incident job must resume and go active again once it stops fleeing, exactly like an uninterrupted incident's lifecycle")

## SaveIO._valid_object_health() accepted an explicit
## "health": null the same way as an omitted key, so a malformed save could
## slip past validation and then crash StateCodec._decode_objects(), which
## assigns item["health"] straight into a typed Dictionary variable the
## instant item.has("health") is true (null does not coerce). Proves the key's
## absence is still accepted, a valid shape is still accepted, and both an
## explicit null and a malformed Dictionary are now rejected.
func _check_object_health_validation() -> void:
	if _failed: return
	var world := _build_arena(38)
	world._set_object(6, 5, "wooden_wall")
	world.tick()
	var state: Dictionary = StateCodecType.encode(world)
	var objects: Array = state["objects"]
	var wall_index := -1
	for i in objects.size():
		if String((objects[i] as Dictionary).get("kind", "")) == "wooden_wall":
			wall_index = i
	_expect(wall_index >= 0, "the encoded state must carry the wall object fixture")
	if wall_index < 0:
		return

	var dir_path := "user://test-combat-object-health-validation"
	_cleanup_dir(dir_path)
	var user_dir := DirAccess.open("user://")
	if user_dir and not user_dir.dir_exists(dir_path):
		user_dir.make_dir_recursive(dir_path)

	var omitted_objects: Array = objects.duplicate(true)
	var omitted_entry: Dictionary = (omitted_objects[wall_index] as Dictionary).duplicate(true)
	omitted_entry.erase("health")
	omitted_objects[wall_index] = omitted_entry
	var omitted_state: Dictionary = state.duplicate(true)
	omitted_state["objects"] = omitted_objects
	var omitted_result := SaveIOType.write_atomic(dir_path.path_join("omitted.json"), omitted_state)
	_expect(omitted_result.get("ok", false), "an object entry with the 'health' key omitted entirely must still validate, got %s" % omitted_result)

	var valid_result := SaveIOType.write_atomic(dir_path.path_join("valid.json"), state)
	_expect(valid_result.get("ok", false), "an object entry with a valid 'health' Dictionary must validate, got %s" % valid_result)

	var null_objects: Array = objects.duplicate(true)
	var null_entry: Dictionary = (null_objects[wall_index] as Dictionary).duplicate(true)
	null_entry["health"] = null
	null_objects[wall_index] = null_entry
	var null_state: Dictionary = state.duplicate(true)
	null_state["objects"] = null_objects
	var null_result := SaveIOType.write_atomic(dir_path.path_join("null.json"), null_state)
	_expect(not null_result.get("ok", false), "an object entry with an explicit 'health': null must be rejected, not waved through as absent")

	var malformed_objects: Array = objects.duplicate(true)
	var malformed_entry: Dictionary = (malformed_objects[wall_index] as Dictionary).duplicate(true)
	malformed_entry["health"] = {"hp": 5} # missing required "maxHp"
	malformed_objects[wall_index] = malformed_entry
	var malformed_state: Dictionary = state.duplicate(true)
	malformed_state["objects"] = malformed_objects
	var malformed_result := SaveIOType.write_atomic(dir_path.path_join("malformed.json"), malformed_state)
	_expect(not malformed_result.get("ok", false), "an object entry with a malformed 'health' Dictionary (missing maxHp) must be rejected")

	_cleanup_dir(dir_path)

## Regression: a dead worker's own scheduler route-search
## state (GlobalAssignment._pending) was never retired, so the unrestricted
## job id it was still mid-searching stayed marked "claimed" by tick()'s own
## claimed_jobs rebuild (built fresh every tick straight from every _pending
## entry) forever -- no other worker could ever be proposed that job again,
## even though nobody was actually searching it anymore. Proves
## GlobalAssignment.retire_worker() (wired into WorldState._apply_actor_death())
## erases exactly the dead worker's own _pending entry, and that a second,
## surviving worker can then actually receive and be assigned the freed job.
## Both workers sit at Manhattan distance >= MAX_TRAVEL_PENALTY (15) from the
## shared target so their initial proposals tie on score and fall to the
## worker-id tie-break, guaranteeing "doomed_worker" (alphabetically first)
## wins the single slot -- never "rescue_worker" -- so this reproduces the
## exact failure shape: death strikes the worker already mid-search
## on the job, not one that was never even proposed it.
func _check_dead_worker_pending_search_frees_job_for_other_worker() -> void:
	if _failed: return
	var world := _build_arena(43)
	_spawn_actor(world, "colony", "doomed_worker", 5, 5)
	_spawn_actor(world, "colony", "rescue_worker", 5, 10)
	_spawn_actor(world, "raiders", "reaper", 6, 5)
	world.tick() # backfills "combat"/"health" before this test mutates them
	world._find_colonist("reaper")["combat"]["cooldown_remaining"] = 999

	# (5,25) is Manhattan distance 20 from doomed_worker and 15 from
	# rescue_worker -- both >= MAX_TRAVEL_PENALTY, so both proposals tie on
	# score and the tie-break falls to worker id.
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(5, 25), 1, world.get_tick(), "till")
	_expect(submit_result.get("ok", false), "the unrestricted till job must be accepted")
	var job_id := String(submit_result.get("job_id", ""))

	world.tick() # doomed_worker (alphabetically first) is proposed and begins its own route search
	_expect(world._scheduler.get_pending().has("doomed_worker"),
		"doomed_worker must be mid-search on the freed job for this check to be meaningful")
	_expect(not world._scheduler.get_pending().has("rescue_worker"),
		"only the winning worker's own proposal should occupy a pending search slot while the job is still claimed")
	_expect(world.get_assignments().get("doomed_worker") == null,
		"the search must still be in flight (not yet assigned) for this check to be meaningful")

	for i in 3:
		world.tick()
	_expect(world._scheduler.get_pending().has("doomed_worker"),
		"doomed_worker's own route search must still be unfinished (genuinely multi-tick) at the moment of death for this check to be meaningful")
	_expect(world.get_assignments().get("doomed_worker") == null,
		"doomed_worker must still be unassigned (mid-search) at the moment of death for this check to be meaningful")

	var doomed := world._find_colonist("doomed_worker")
	doomed["health"]["hp"] = 1
	var reaper := world._find_colonist("reaper")
	reaper["combat"]["damage"] = 999
	reaper["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(world._find_colonist("doomed_worker").is_empty(), "the doomed worker must be removed from the world")
	_expect(not world._scheduler.get_pending().has("doomed_worker"),
		"a dead worker's own pending route-search state must be retired, not left claiming its candidate job(s) forever")
	_expect(String(world._get_job(job_id).get("status", "")) == "queued",
		"the unrestricted job a dead worker was merely searching (never assigned) must stay queued for another worker, not be cancelled")

	var rescued := false
	for i in 20:
		world.tick()
		if String(world._get_job(job_id).get("status", "")) == "active" and String((world.get_assignments().get("rescue_worker", {}) as Dictionary).get("job_id", "")) == job_id:
			rescued = true
			break
	_expect(rescued, "a surviving worker must actually be able to receive and be assigned the job a dead worker's own retired pending search left behind")

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
				world._find_colonist("prey")["health"]["hp"] = 25
				world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999
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
				var submit_result: Dictionary = world._scheduler.submit(Vector2i(11, 10), 1, world.get_tick(), "till", "prey")
				_expect(submit_result.get("ok", false), "[%s] the prey's own till job must be accepted" % shape)
				work_job_id = String(submit_result.get("job_id", ""))
				world.tick()
				_expect(String(world._get_job(work_job_id).get("status", "")) == "active", "[%s] the prey's till job must be active before it flees" % shape)
				world._find_colonist("prey")["health"]["hp"] = 25
		var reached := false
		for _i in 40:
			uninterrupted.tick()
			live.tick()
			var flee_job := _flee_job_of(live, "prey")
			if flee_job.is_empty():
				continue
			var status := String(flee_job.get("status", ""))
			var reason := String(flee_job.get("reason", ""))
			if shape == "searching" and status == "queued" and live._scheduler.get_pending().has("prey"):
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
		_expect(String(loaded._get_job(live_flee_id).get("status", "")) in ["queued", "active"], "[%s] the flee job must survive the save/load" % shape)
		for world in [uninterrupted, loaded]:
			world._find_colonist("prey")["health"]["hp"] = 100
		uninterrupted.tick()
		loaded.tick()
		var expected_status := String(uninterrupted._get_job(uninterrupted_flee_id).get("status", ""))
		var loaded_status := String(loaded._get_job(live_flee_id).get("status", ""))
		_expect(expected_status in ["cancelled", "failed", "completed"],
			"[%s] the uninterrupted run must retire its flee job on recovery (got '%s')" % [shape, expected_status])
		_expect(loaded_status == expected_status,
			"[%s] recovery right after a load must retire the restored flee job exactly like the uninterrupted run (got '%s' vs '%s')" % [shape, loaded_status, expected_status])
		_expect(not loaded._combat_giver.get_committed_jobs().has("prey") and not loaded._combat_giver.get_blocked_targets().has("prey"),
			"[%s] recovery right after a load must leave no residual CombatGiver association or exclusions" % shape)
		_expect(not loaded._scheduler.get_pending().has("prey"),
			"[%s] recovery right after a load must drop the restored flee job's own route search" % shape)
		_expect(not loaded._paused_jobs.has("prey") and not uninterrupted._paused_jobs.has("prey"),
			"[%s] recovery must consume the paused-job entry in both runs" % shape)
		var flee_target: Vector2i = loaded._get_job(live_flee_id)["target"]
		_expect(not loaded._flee_target_reserved(flee_target.x, flee_target.y),
			"[%s] a flee job retired after a load must release its own destination reservation" % shape)
		if not work_job_id.is_empty():
			_expect(String(loaded._get_job(work_job_id).get("status", "")) == "active" and String(uninterrupted._get_job(work_job_id).get("status", "")) == "active",
				"[%s] the interrupted till job must be resumed (active) in both runs" % shape)
		_expect(String((loaded.get_assignments().get("prey", {}) as Dictionary).get("job_id", "")) == String((uninterrupted.get_assignments().get("prey", {}) as Dictionary).get("job_id", "")),
			"[%s] the recovered actor's assignment must match the uninterrupted run" % shape)
		for i in 40:
			uninterrupted.tick()
			loaded.tick()
			var a := Vector2i(int(uninterrupted._find_colonist("prey")["x"]), int(uninterrupted._find_colonist("prey")["y"]))
			var b := Vector2i(int(loaded._find_colonist("prey")["x"]), int(loaded._find_colonist("prey")["y"]))
			_expect(a == b, "[%s] positions after recovery must match the uninterrupted run (tick %d)" % [shape, i])
			if not work_job_id.is_empty():
				_expect(String(loaded._get_job(work_job_id).get("status", "")) == String(uninterrupted._get_job(work_job_id).get("status", "")),
					"[%s] the resumed till job's status must match the uninterrupted run (tick %d)" % [shape, i])

## The non-terminal `flee` job restricted to actor_id, or the most recently
## submitted one when none is non-terminal (empty when there never was one).
func _flee_job_of(world: WorldStateType, actor_id: String) -> Dictionary:
	var latest: Dictionary = {}
	for job in world.get_jobs():
		if String(job.get("kind", "")) != "flee" or world._job_restricted_to(String(job["id"])) != actor_id:
			continue
		if String(job.get("status", "")) in ["queued", "active"]:
			return job
		latest = job
	return latest

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
		world._set_object(x, 9, "wooden_wall")
		world._set_object(x, 11, "wooden_wall")
	world._set_object(9, 10, "wooden_wall")
	world._set_object(13, 10, "door")
	_spawn_actor(world, "colony", "hunter", 10, 10)
	_spawn_actor(world, "raiders", "prey", 11, 10)
	world.tick() # backfills "combat"/"health"
	world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999
	var submit_result: Dictionary = world._scheduler.submit_autonomous(Vector2i(12, 10), 1, world.get_tick(), "till", "prey")
	_expect(submit_result.get("ok", false), "the boxed-in raider's own autonomous till job must be accepted")
	var work_job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(String(world._get_job(work_job_id).get("status", "")) == "active", "the raider's till job must be active before it flees")

	world._find_colonist("prey")["health"]["hp"] = 25
	var exhausted := false
	var excluded_count := 0
	for _i in 120:
		world.tick()
		excluded_count = (world._combat_giver.get_blocked_targets().get("prey", {}) as Dictionary).size()
		if excluded_count >= 2 and _flee_job_of(world, "prey").get("status", "") not in ["queued", "active"] and not world._combat_giver.get_committed_jobs().has("prey"):
			exhausted = true
			break
	_expect(exhausted, "the boxed-in raider must exhaust every flee destination (blocked, cancelled, excluded) within the tick budget for this check to be meaningful")
	if not exhausted:
		return
	_expect(String(world._paused_jobs.get("prey", "")) == work_job_id or String(world._get_job(work_job_id).get("status", "")) == "active",
		"the interrupted till job must still be tracked as paused (or already back active) while the raider is stuck")
	world.tick() # one more tick with nothing left to try: the episode must persist without a job
	_expect(world._combat_giver.get_blocked_targets().has("prey"),
		"exclusions must persist across a tick with no destination left, so the episode remains owned")

	world._find_colonist("prey")["health"]["hp"] = 100
	world.tick()
	_expect(not world._combat_giver.get_blocked_targets().has("prey"),
		"recovery after destination exhaustion must clear the episode's exclusions")
	_expect(not world._combat_giver.get_committed_jobs().has("prey"), "recovery must leave no residual flee association")
	_expect(not world._paused_jobs.has("prey"), "recovery after destination exhaustion must consume the paused-job entry")
	_expect(String(_flee_job_of(world, "prey").get("status", "")) not in ["queued", "active"], "no flee job may outlive recovery")
	var work_status := String(world._get_job(work_job_id).get("status", ""))
	_expect(work_status in ["active", "completed"],
		"recovery after destination exhaustion must resume the interrupted work, not leave it suspended (got '%s')" % work_status)

## _drop_inventory_item() spawned exactly one ground tool for
## a tool kind regardless of the entry's count, so {kind: "axe", count: 2}
## lost an axe on death; and the earlier regression only poked the store's
## setters, never a worker's own job. Proves exact quantity conservation for
## a multi-unit tool entry plus inventory.tool, then lets two surviving
## workers run a real chop and a real dig -- discovery, reservation, pickup,
## use -- against nothing but the dropped tools.
func _check_death_drops_every_inventory_tool_unit_usable_by_workers() -> void:
	if _failed: return
	var world := _build_arena(50)
	_spawn_actor(world, "raiders", "attacker", 5, 5)
	_spawn_actor(world, "colony", "victim", 6, 5)
	world.tick()
	var victim := world._find_colonist("victim")
	victim["inventory"] = {"items": [{"kind": "axe", "count": 2}, {"kind": "wood", "count": 2}], "tool": "pick", "capacity": 4}
	victim["health"]["hp"] = 1
	var attacker := world._find_colonist("attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()
	_expect(world._find_colonist("victim").is_empty(), "a dead actor must be removed from the world")

	var axe_ids: Array[String] = []
	var pick_ids: Array[String] = []
	for tool_item in world.get_tool_items():
		var location: Dictionary = tool_item.get("location", {})
		_expect(String(location.get("type", "")) == "ground" and int(location.get("x", -1)) == 6 and int(location.get("y", -1)) == 5,
			"every dropped tool must lie on the victim's own death tile")
		if String(tool_item["kind"]) == "axe":
			axe_ids.append(String(tool_item["id"]))
		elif String(tool_item["kind"]) == "pick":
			pick_ids.append(String(tool_item["id"]))
	_expect(axe_ids.size() == 2, "an inventory.items tool entry with count 2 must drop exactly 2 identity-bearing ground tools (got %d)" % axe_ids.size())
	_expect(pick_ids.size() == 1, "inventory.tool must drop exactly 1 ground tool (got %d)" % pick_ids.size())
	_expect(world.get_tool_items().size() == 3, "no extra or missing tool item may exist after the drop (got %d)" % world.get_tool_items().size())
	if axe_ids.size() == 2:
		_expect(axe_ids[0] != axe_ids[1], "each dropped tool unit must carry its own identity")
	var pile_tools := 0
	for item in world.get_items():
		if String(item["kind"]) in ["axe", "pick"]:
			pile_tools += 1
	_expect(pile_tools == 0, "no tool kind may land in the ordinary item pile")

	# Get the killer out of the way so the surviving workers can fetch the tools unharmed.
	attacker["x"] = 40
	attacker["y"] = 40
	attacker["combat"]["cooldown_remaining"] = 100000
	_spawn_actor(world, "colony", "lumberjack", 20, 5)
	_spawn_actor(world, "colony", "miner", 6, 20)
	world._tiles[world._tile_index(22, 5)] = WorldStateType.TILE_TREE
	world._tiles[world._tile_index(6, 22)] = WorldStateType.TILE_SOIL
	var chop := world.apply({"actor": "test", "command_id": "chop_1", "tick": world.get_tick(), "type": "chop", "payload": {"x": 22, "y": 5, "priority": 1}})
	var dig := world.apply({"actor": "test", "command_id": "dig_1", "tick": world.get_tick(), "type": "dig", "payload": {"x": 6, "y": 22, "priority": 1}})
	_expect(chop.get("ok", false) and dig.get("ok", false), "chop and dig orders must be accepted: %s / %s" % [chop, dig])
	var chop_id := String(chop.get("job_id", ""))
	var dig_id := String(dig.get("job_id", ""))
	var axe_reserved_for_chop := false
	var pick_reserved_for_dig := false
	var axe_held := false
	var pick_held := false
	var both_done := false
	for _i in 400:
		world.tick()
		for axe_id in axe_ids:
			if world.get_tool_item_reservation(axe_id) == chop_id:
				axe_reserved_for_chop = true
			if WorkerType.get_held_tool(world._find_colonist("lumberjack")) == axe_id:
				axe_held = true
		for pick_id in pick_ids:
			if world.get_tool_item_reservation(pick_id) == dig_id:
				pick_reserved_for_dig = true
			if WorkerType.get_held_tool(world._find_colonist("miner")) == pick_id:
				pick_held = true
		if String(world._get_job(chop_id).get("status", "")) == "completed" and String(world._get_job(dig_id).get("status", "")) == "completed":
			both_done = true
			break
	_expect(axe_reserved_for_chop, "the chop job must reserve one of the dropped inventory.items axes through normal discovery")
	_expect(axe_held, "the lumberjack must pick up and hold a dropped inventory.items axe")
	_expect(pick_reserved_for_dig, "the dig job must reserve the dropped inventory.tool pick through normal discovery")
	_expect(pick_held, "the miner must pick up and hold the dropped inventory.tool pick")
	_expect(both_done, "both tool-requiring jobs must complete using only the dropped tools (chop '%s', dig '%s')" % [world._get_job(chop_id).get("status", ""), world._get_job(dig_id).get("status", "")])
	_expect(world.get_tile(22, 5) != WorldStateType.TILE_TREE and world.get_tile(6, 22) != WorldStateType.TILE_SOIL,
		"the chop and dig work effects must have been applied with the dropped tools")

## --- Interrupt/resume ownership boundary -----------------------------------

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
		world._set_object(x, 7, "wooden_wall")
		world._set_object(x, 23, "wooden_wall")
	for y in range(7, 24):
		world._set_object(7, y, "wooden_wall")
		world._set_object(23, y, "wooden_wall")
	world._tiles[world._tile_index(25, 15)] = WorldStateType.TILE_WATER
	world.tick() # backfills "combat"/"health" before this test mutates them

	var work_result: Dictionary = world._scheduler.submit(Vector2i(16, 15), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the worker's own unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	var settled := false
	for _i in 10:
		world.tick()
		if world._find_colonist("worker").get("work") != null:
			settled = true
			break
	_expect(settled, "the till job must reach its own work toil before the need onset, for this check to be meaningful")

	world._find_colonist("worker")["needs"]["water"] = 0
	world.tick() # a real NeedGiver._evaluate() interrupts the till job and starts a real search
	_expect(world._need_giver._searching.has("worker"), "a real need search must have started for this check to be meaningful")
	_expect(String(world._paused_jobs.get("worker", "")) == work_job_id, "the need interrupt must pause the till job")

	world._find_colonist("worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_active := false
	for _i in 10:
		world.tick()
		if world._need_giver._searching.has("worker") and world._combat_giver.get_committed_jobs().has("worker"):
			flee_active = true
			break
	_expect(flee_active, "the need search must still be in flight when the worker starts fleeing, for this check to be meaningful")
	_expect(String(world._paused_jobs.get("worker", "")) == work_job_id,
		"the pre-existing need interrupt's own paused-work association must survive flee activation untouched")

	for _i in 20:
		world.tick()
		_expect(String(world._paused_jobs.get("worker", "")) == work_job_id or not world._combat_giver.owns("worker"),
			"a frozen need search must never overwrite the till job's own paused-job entry while CombatGiver owns this actor (tick %d)" % world.get_tick())

	world._find_colonist("worker")["health"]["hp"] = 100
	var resumed := false
	for _i in 20:
		world.tick()
		if String(world._get_job(work_job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the original pre-need-search till job must resume cleanly once the worker recovers")
	_expect(not world._paused_jobs.has("worker"), "recovery must leave no residual paused-job entry")
	_expect(not world._combat_giver.get_committed_jobs().has("worker"), "recovery must leave no residual CombatGiver association")

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
	world._find_colonist("reaper")["combat"]["cooldown_remaining"] = 999

	var work_result: Dictionary = world._scheduler.submit(Vector2i(16, 15), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the worker's own unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	var settled := false
	for _i in 10:
		world.tick()
		if world._find_colonist("worker").get("work") != null:
			settled = true
			break
	_expect(settled, "the till job must reach its own work toil before combat interrupts it, for this check to be meaningful")

	world._find_colonist("worker")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_active := false
	for _i in 10:
		world.tick()
		if world._combat_giver.get_committed_jobs().has("worker"):
			flee_active = true
			break
	_expect(flee_active, "the worker must actually start fleeing for this check to be meaningful")
	_expect(String(world._paused_jobs.get("worker", "")) == work_job_id, "combat's own interrupt must pause the till job")
	_expect(world._combat_giver.owns("worker"), "CombatGiver must own the interrupt/resume boundary for this check to be meaningful")

	# A real need onset now, mid-episode: this must never reach NeedGiver's
	# own interrupt/search machinery at all while CombatGiver owns "worker".
	world._find_colonist("worker")["needs"]["water"] = 0
	for _i in 20:
		world.tick()
		_expect(not world._need_giver._searching.has("worker"), "a need onset during an open flee episode must never start a real search (tick %d)" % world.get_tick())
		_expect(world._need_giver.get_pending_job("worker").is_empty(), "a need onset during an open flee episode must never submit a need job (tick %d)" % world.get_tick())
		_expect(String(world._paused_jobs.get("worker", "")) == work_job_id,
			"a need onset during an open flee episode must never overwrite the till job's own paused-job entry (tick %d)" % world.get_tick())

	world._find_colonist("worker")["health"]["hp"] = 100
	var resumed := false
	for _i in 20:
		world.tick()
		if String(world._get_job(work_job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the original pre-flee till job must resume, not a need job, once the worker recovers")
	_expect(world._need_giver.get_pending_job("worker").is_empty(), "recovery must never have submitted a need job for the still-thirsty worker")

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

## --- Faction-aware routing across save/load --------------------------------

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
		world._find_colonist("prey")["health"]["hp"] = 25
		world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999
	uninterrupted.tick()
	live.tick()
	_expect(live._scheduler.get_pending().has("prey"), "the raider's own flee route search must still be genuinely in flight for this check to be meaningful")

	var loaded := StateCodecType.decode(StateCodecType.encode(live))
	_expect(loaded._scheduler.get_pending().has("prey"), "a save/load mid-search must restore the raider's own pending route search, not drop it")

	for i in 150:
		uninterrupted.tick()
		loaded.tick()
		var uninterrupted_pos := Vector2i(int(uninterrupted._find_colonist("prey")["x"]), int(uninterrupted._find_colonist("prey")["y"]))
		var loaded_pos := Vector2i(int(loaded._find_colonist("prey")["x"]), int(loaded._find_colonist("prey")["y"]))
		_expect(uninterrupted_pos == loaded_pos,
			"a save taken mid-search must reproduce identical subsequent positions to an uninterrupted run (tick %d)" % i)
		_expect(int(loaded._find_colonist("prey")["x"]) < 14, "a restored search must never cross the raider's own faction-forbidden door (tick %d)" % i)

## Shared by the active-reroute check below: a raider "prey" walks a short
## direct row (y=0, x=10..15) toward its own first flee candidate; the loop
## around it (left/right columns, bottom row) is its only detour once that
## row is walled mid-walk, and a door blocks the loop's own reconnection back
## to the row -- impassable to the raider's own faction (content/factions.json:
## raiders may_pass_doors=false) but not to colony, so a colony-default
## restore of an in-flight reroute would find a path the raider's own live
## search never could. The loop is ~100 tiles -- over RouteSearch.STEP_BUDGET
## (64) -- so the forced reroute stays genuinely STATUS_SEARCHING for more
## than one tick.
func _build_flee_racetrack_door_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(10, 16):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
	for y in range(0, WorldStateType.MAP_HEIGHT):
		world._tiles[world._tile_index(10, y)] = WorldStateType.TILE_FLOOR
		world._tiles[world._tile_index(15, y)] = WorldStateType.TILE_FLOOR
	for x in range(10, 16):
		world._tiles[world._tile_index(x, WorldStateType.MAP_HEIGHT - 1)] = WorldStateType.TILE_FLOOR
	world._set_object(15, 1, "door")
	_spawn_actor(world, "colony", "hunter", 10, 0)
	_spawn_actor(world, "raiders", "prey", 11, 0)
	world.tick() # backfills "combat" before a caller mutates it
	return world

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
		world._find_colonist("prey")["health"]["hp"] = 25
		world._find_colonist("hunter")["combat"]["cooldown_remaining"] = 999

	var walled := false
	var mid_reroute := false
	var ticks := 0
	while not mid_reroute and ticks < 400:
		uninterrupted.tick()
		live.tick()
		ticks += 1
		if not walled:
			var prey := live._find_colonist("prey")
			if int(prey["x"]) == 12 and int(prey["y"]) == 0:
				live._set_object(13, 0, "wooden_wall")
				uninterrupted._set_object(13, 0, "wooden_wall")
				walled = true
		var route = live._find_colonist("prey").get("route")
		if route != null and route.get("rerouting") != null and String(route["rerouting"].get("status", "")) == "searching":
			mid_reroute = true
	_expect(walled, "the test fixture must wall the raider's own direct path before it reaches the wall point")
	_expect(mid_reroute, "the raider's own live reroute search must still be genuinely mid-flight (STATUS_SEARCHING) for this check to be meaningful")
	if not mid_reroute:
		return

	var loaded := StateCodecType.decode(StateCodecType.encode(live))
	var loaded_route = loaded._find_colonist("prey").get("route")
	_expect(loaded_route != null and loaded_route.get("rerouting") != null, "a save/load mid-reroute must restore the raider's own in-flight search, not drop it")

	for i in 400:
		uninterrupted.tick()
		loaded.tick()
		var uninterrupted_pos := Vector2i(int(uninterrupted._find_colonist("prey")["x"]), int(uninterrupted._find_colonist("prey")["y"]))
		var loaded_pos := Vector2i(int(loaded._find_colonist("prey")["x"]), int(loaded._find_colonist("prey")["y"]))
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
	var submit_result: Dictionary = world._scheduler.submit_autonomous(Vector2i(15, 0), 1, world.get_tick(), "till", "prey")
	_expect(submit_result.get("ok", false), "the raider's own autonomous till job must be accepted")
	var job_id := String(submit_result["job_id"])
	world.tick()
	_expect(String(world._get_job(job_id).get("status", "")) == "active", "the raider's own till job must be active before it is interrupted for this check to be meaningful")

	var prey := world._find_colonist("prey")
	world._interrupt_current_job(prey)
	_expect(String(world._paused_jobs.get("prey", "")) == job_id, "the till job must actually be paused for this check to be meaningful")
	prey["x"] = 15
	prey["y"] = 30 # south of the door, on the direct column back to the paused job's own target
	world._combat_giver._episodes["prey"] = {}

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(String(loaded._paused_jobs.get("prey", "")) == job_id, "a save/load must preserve the raider's own paused-job entry")
	_expect(loaded._combat_giver.owns("prey"), "a save/load must preserve the raider's own open flee episode")

	var stood_on_door := false
	var resumed_active := false
	for i in 600:
		loaded.tick()
		var pos := Vector2i(int(loaded._find_colonist("prey")["x"]), int(loaded._find_colonist("prey")["y"]))
		if pos == Vector2i(15, 1):
			stood_on_door = true
		if String(loaded._get_job(job_id).get("status", "")) == "active":
			resumed_active = true
	_expect(not stood_on_door, "a restored recovery's own fresh route must never cross the raider's own faction-forbidden door")
	_expect(resumed_active, "the restored recovery must still actually resume and reach the paused job (the long way around), not get permanently stuck")

## --- Need/combat/incident lifecycle gaps -----------------------------------

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

	var work_result: Dictionary = world._scheduler.submit(Vector2i(16, 15), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the worker's own unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	world.tick()
	_expect(String(world._get_job(work_job_id).get("status", "")) == "active", "the unrestricted till job must be active before the interrupt")

	var worker := world._find_colonist("worker")
	world._interrupt_current_job(worker) # mirrors NeedGiver's own critical-need interrupt
	_expect(String(world._paused_jobs.get("worker", "")) == work_job_id, "the interrupted till job must be recorded as this worker's own paused job")

	var need_result: Dictionary = world._scheduler.submit(Vector2i(20, 20), 1, world.get_tick(), "drink_water", "worker")
	_expect(need_result.get("ok", false), "the worker's own restricted need job must be accepted")
	var need_job_id := String(need_result.get("job_id", ""))
	world._need_giver._pending["worker"] = need_job_id # fakes a real NeedGiver commitment, same seam other checks in this file use

	worker["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	var flee_job_id := ""
	var flee_active := false
	for _i in 20:
		world.tick()
		flee_job_id = String(_flee_job_of(world, "worker").get("id", ""))
		if not flee_job_id.is_empty() and String(world._get_job(flee_job_id).get("status", "")) == "active":
			flee_active = true
			break
	_expect(flee_active, "the worker's own flee job must actually reach active for this check to be meaningful")
	_expect(String(world._get_job(need_job_id).get("status", "")) == "queued",
		"the need job must stay queued -- never assigned, since the flee commitment always wins the propose slot -- for this check to be meaningful")
	var flee_target: Vector2i = world._get_job(flee_job_id)["target"]
	_expect(world._flee_target_reserved(flee_target.x, flee_target.y),
		"the active flee job must hold a live destination reservation for this check to be meaningful")

	# Cancel the still-queued need job through the exact command boundary
	# that calls NeedGiver.resolve_job() -> _resume_interrupted_job().
	var cancel_result := world.apply({"actor": "test", "command_id": "cancel_need_over_flee", "tick": world.get_tick(),
		"type": "cancel_job", "payload": {"job_id": need_job_id}})
	_expect(bool(cancel_result.get("ok", false)), "cancelling the still-queued need job must be accepted")

	_expect(String(world._get_job(flee_job_id).get("status", "")) == "active",
		"cancelling a resolved need job must never overwrite the actor's own active flee assignment")
	_expect(String((world.get_assignments().get("worker", {}) as Dictionary).get("job_id", "")) == flee_job_id,
		"the worker's own scheduler assignment must still point at the flee job after the need job resolves")
	_expect(world._flee_target_reserved(flee_target.x, flee_target.y),
		"the flee job's own destination reservation must remain held, not released by an errant resume")
	_expect(String(world._paused_jobs.get("worker", "")) == work_job_id,
		"the original interrupted till job must still be the one recorded as paused, deferred until CombatGiver releases ownership")
	_expect(world._combat_giver.owns("worker"), "CombatGiver must still own the flee episode after the need job resolves")

	worker["health"]["hp"] = 100 # recover above the flee threshold
	var resumed := false
	for _i in 20:
		world.tick()
		if String(world._get_job(work_job_id).get("status", "")) == "active":
			resumed = true
			break
	_expect(resumed, "the original till job must resume once the actor recovers, even after an intervening need-job cancellation mid-episode")
	_expect(not world._paused_jobs.has("worker"), "recovery must leave no residual paused-job entry")
	_expect(not world._combat_giver.owns("worker"), "recovery must leave no residual CombatGiver episode")

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
## (the only directions RouteSearch._ordered_neighbors() ever tries) so
## recovery's very first bounded resume() call, not a multi-tick search,
## concludes unreachable. Drives the shared interrupt/episode boundary
## directly (the same idiom _check_flee_recovery_resume_needs_fresh_route_faction_aware()
## above uses), since this fix concerns recovery's own unreachable handling,
## not flee targeting.
func _check_flee_recovery_of_disconnected_incident_target_cancels_without_replacement() -> void:
	if _failed: return
	var world := _build_arena(61)
	for x in range(4, 13):
		world._set_object(x, 4, "wooden_wall")
		world._set_object(x, 10, "wooden_wall")
	for y in range(5, 10):
		world._set_object(4, y, "wooden_wall")
		world._set_object(12, y, "wooden_wall")
	var actor_id := "incident_trapped"
	var job_id := world._incidents.propose(_make_incident_actor(world, actor_id, 6, 7), Vector2i(10, 7), 5)
	_expect(not job_id.is_empty(), "the incident proposal must be accepted")
	var spawn_ticks := 0
	while world._find_colonist(actor_id).is_empty() and spawn_ticks < 60:
		world.tick()
		spawn_ticks += 1
	_expect(not world._find_colonist(actor_id).is_empty(), "the incident actor must spawn for this check to be meaningful")
	_expect(String(world._get_job(job_id).get("status", "")) == "active", "the incident job must be active once its actor has spawned")
	world.tick() # backfills "combat" before CombatGiver.advance() reads it

	var trapped := world._find_colonist(actor_id)
	world._interrupt_current_job(trapped)
	_expect(String(world._paused_jobs.get(actor_id, "")) == job_id, "the interrupt must pause the trapped incident actor's own incident job for this check to be meaningful")
	_expect(String(world._get_job(job_id).get("status", "")) == "queued", "the paused incident job must be suspended back to queued")
	world._combat_giver._episodes[actor_id] = {} # opens the episode directly, mirroring the file's own established idiom for this boundary

	# Disconnect the incident job's own target: wall off its four orthogonal
	# neighbors, so the destination stays a bare floor tile but nothing can
	# ever reach it.
	world._set_object(9, 7, "wooden_wall")
	world._set_object(11, 7, "wooden_wall")
	world._set_object(10, 6, "wooden_wall")
	world._set_object(10, 8, "wooden_wall")
	world._route_budget.erase(actor_id) # guarantees the recovery's own fresh search actually resumes this tick, not deferred by a stale per-tick routing allowance

	world.tick() # CombatGiver.advance() sees no reason to flee (default full hp), closes the episode, and calls the shared recovery boundary

	_expect(world._find_colonist(actor_id).is_empty(),
		"the trapped incident actor must despawn once its own recovery finds its original destination genuinely unreachable")
	_expect(String(world._get_job(job_id).get("status", "")) in ["cancelled", "failed"],
		"the original incident job must be terminated, not left dangling")
	var replacement_found := false
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			continue
		if String(job.get("kind", "")) == "incident" and world._job_restricted_to(String(job["id"])) == actor_id:
			replacement_found = true
	_expect(not replacement_found, "recovery from an unreachable incident destination must cancel, never resubmit, a replacement job restricted to the now-removed actor")
	_expect(not world._paused_jobs.has(actor_id), "recovery must leave no residual paused-job entry for the despawned actor")
	_expect(not world._combat_giver.owns(actor_id), "recovery must leave no residual CombatGiver episode for the despawned actor")
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
		var job_id := world._incidents.propose(_make_incident_actor(world, actor_id, 10, 10), Vector2i(20, 10), 5)
		_expect(not job_id.is_empty(), "the incident proposal must be accepted")
		var spawn_ticks := 0
		while world._find_colonist(actor_id).is_empty() and spawn_ticks < 60:
			world.tick()
			spawn_ticks += 1
		_expect(not world._find_colonist(actor_id).is_empty(), "the incident actor must spawn for this check to be meaningful")
		_expect(String(world._get_job(job_id).get("status", "")) == "active", "the incident job must be active once its actor has spawned")
		world.tick() # backfills "combat" before this test mutates it

		if searching:
			_spawn_actor(world, "colony", "hunter", 0, 0) # diagonal threat: keeps the flee route search running for several ticks
		else:
			_spawn_actor(world, "colony", "hunter", 0, 10) # cardinal threat: resolves within a bounded number of ticks

		world._find_colonist(actor_id)["health"]["hp"] = 25 # below the colonist def's own 0.3 flee_hp_fraction
		var flee_job_id := ""
		for _i in 20:
			world.tick()
			flee_job_id = String(_flee_job_of(world, actor_id).get("id", ""))
			if flee_job_id.is_empty():
				continue
			var status := String(world._get_job(flee_job_id).get("status", ""))
			if searching and status == "queued" and world._scheduler.get_pending().has(actor_id):
				break
			if not searching and status == "active":
				break
		_expect(not flee_job_id.is_empty(), "a flee job must exist for this check to be meaningful")
		var flee_target: Vector2i = world._get_job(flee_job_id).get("target", Vector2i(-1, -1))
		if searching:
			_expect(String(world._get_job(flee_job_id).get("status", "")) == "queued" and world._scheduler.get_pending().has(actor_id),
				"the flee job's own route search must still be mid-flight for this check to be meaningful")
		else:
			_expect(String(world._get_job(flee_job_id).get("status", "")) == "active", "the flee job must actually reach 'active' status for this check to be meaningful")
			_expect(world._flee_target_reserved(flee_target.x, flee_target.y),
				"an active flee job must hold a live reservation on its own destination for this check to be meaningful")
		_expect(String(world._paused_jobs.get(actor_id, "")) == job_id,
			"combat's own flee interrupt must pause the incident actor's own incident job for this check to be meaningful")

		var cancel_result := world.apply({"actor": "test", "command_id": "cancel_suspended_incident_%s" % searching, "tick": world.get_tick(),
			"type": "cancel_job", "payload": {"job_id": job_id}})
		_expect(bool(cancel_result.get("ok", false)), "cancelling the suspended incident job must be accepted")

		_expect(world._find_colonist(actor_id).is_empty(), "cancelling the suspended incident job must despawn its actor")
		_expect(String(world._get_job(job_id).get("status", "")) in ["cancelled", "failed"], "the incident job itself must be terminated")
		_expect(String(world._get_job(flee_job_id).get("status", "")) in ["cancelled", "failed", "completed"],
			"the actor's own flee job (searching=%s) must not survive its despawn" % searching)
		_expect(world.get_assignments().get(actor_id) == null, "the despawned actor must hold no scheduler assignment")
		_expect(not world._scheduler.get_pending().has(actor_id), "the despawned actor must hold no in-flight route search")
		if not searching:
			_expect(not world._flee_target_reserved(flee_target.x, flee_target.y),
				"the despawned actor's own flee destination reservation must be released, not held indefinitely")
		_expect(not world._paused_jobs.has(actor_id), "the despawned actor must leave no residual paused-job entry")
		_expect(not world._combat_giver.owns(actor_id), "the despawned actor must leave no residual CombatGiver episode")
		_expect(not world._combat_giver.get_committed_jobs().has(actor_id), "the despawned actor must leave no residual CombatGiver commitment")
		var residual_job := false
		for job in world.get_jobs():
			if String(job["id"]) in [job_id, flee_job_id]:
				continue
			if world._job_restricted_to(String(job["id"])) == actor_id and String(job.get("status", "")) in ["queued", "active"]:
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
	var prey := world._find_colonist("fighter_b")
	# Simulates the exact leftover state a combat interrupt leaves behind
	# (colonist-ai.md 3.6): a colonist mid-haul/build carries its item right
	# through a need/combat interrupt, never dropping it.
	InventoryType.add_to_hands(prey, "wood", 1)
	prey["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world._find_colonist("fighter_a")["combat"]["cooldown_remaining"] = 999
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
		_expect(InventoryType.has_kind(world._find_colonist("fighter_b"), "wood"),
			"the carried item must survive the whole flee episode, never dropped or duplicated (tick %d)" % world.get_tick())
		var pos := Vector2i(int(world._find_colonist("fighter_b")["x"]), int(world._find_colonist("fighter_b")["y"]))
		if pos != start_pos:
			moved = true
		if String(world._get_job(flee_job_id).get("status", "")) == "completed":
			flee_completed = true
			break
	_expect(moved, "a fleeing actor carrying unrelated cargo must actually path away from its starting tile, not stall at arrival")
	_expect(flee_completed, "the flee job must reach completed status while the actor carries unrelated cargo, not stall forever")

## ADR 033: a full-height wall at x=10 except a
## single colony door at y=24 leaves the door as the wolf's only crossing
## toward the villager beyond it -- mirrors _build_faction_blocked_door_world()'s
## own "one door, everything else walled" shape. `wolf` (content/actors.json)
## is reused as a fixture only, spawned directly like every other
## fixture actor in this file rather than through IncidentScheduler, so its
## own lifetime is not tied to any incident job.
func _build_wolf_door_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	for y in WorldStateType.MAP_HEIGHT:
		if y == 24:
			continue
		world._set_object(10, y, "wooden_wall")
	world._set_object(10, 24, "door")
	var wolf := ActorTableType.spawn("wolf", 0, 24, world._content, "wolf_1")
	wolf["factionId"] = "wildlife"
	world._append_colonist(wolf)
	_spawn_actor(world, "colony", "villager", 11, 24)
	return world

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
	world._find_colonist("fleeing_raider")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world.tick()
	_expect(world._combat_giver.owns("fleeing_raider"), "the raider must be owned by CombatGiver (fleeing) for this check to be meaningful")
	for i in 15:
		world.tick()
		var has_approach := false
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "approach" and world._job_restricted_to(String(job["id"])) == "fleeing_raider":
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
	_expect(String(world_a._get_job(approach_job_id).get("status", "")) in ["queued", "active"],
		"the approach job must still be in flight for this check to be meaningful")
	var target_before: Dictionary = world_a._approach_giver.get_job_targets().get(approach_job_id, {})
	_expect(not target_before.is_empty(), "the in-flight approach job must have a tracked target for this check to be meaningful")

	var loaded := StateCodecType.decode(StateCodecType.encode(world_a))
	var loaded_target: Dictionary = loaded._approach_giver.get_job_targets().get(approach_job_id, {})
	_expect(loaded_target == target_before, "a save taken mid-approach must reload with the same tracked target")

	for i in 40:
		world_a.tick()
		loaded.tick()
		_expect(world_a.state_hash() == loaded.state_hash(),
			"a save taken mid-approach must reload and continue identically to an uninterrupted run (tick %d)" % world_a.get_tick())

## The non-terminal `approach` job restricted to actor_id, or the most
## recently submitted one when none is non-terminal (empty when there never
## was one) -- mirrors _flee_job_of().
func _approach_job_of(world: WorldStateType, actor_id: String) -> Dictionary:
	var latest: Dictionary = {}
	for job in world.get_jobs():
		if String(job.get("kind", "")) != "approach" or world._job_restricted_to(String(job["id"])) != actor_id:
			continue
		if String(job.get("status", "")) in ["queued", "active"]:
			return job
		latest = job
	return latest

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
	_expect(world._approach_giver.get_job_targets().has(approach_job_id),
		"the freshly submitted approach job must have a tracked target for this check to be meaningful")

	world._find_colonist("fleeing_raider")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	for i in 10:
		world.tick()
		if world._combat_giver.owns("fleeing_raider"):
			break
	_expect(world._combat_giver.owns("fleeing_raider"), "the raider must be owned by CombatGiver (fleeing) for this check to be meaningful")
	_expect(world._approach_giver.get_job_targets().has(approach_job_id),
		"a paused approach job's target association must survive rule 2's release while CombatGiver still owns the actor, for this check to be meaningful")

	world._remove_colonist_by_id("fleeing_raider", false)
	_expect(not world._approach_giver.get_job_targets().has(approach_job_id),
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
		var target: Dictionary = world._approach_giver.get_job_targets().get(String(job["id"]), {})
		if String(target.get("kind", "")) == "actor" and String(target.get("id", "")) == "near_target":
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the hunter must commit to the nearer target first for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(world._get_job(approach_job_id).get("status", "")) in ["queued", "active"],
		"the approach job must still be in flight when its target dies for this check to be meaningful")

	world._remove_colonist_by_id("near_target", true) # simulates the current target dying
	_assert_no_orphaned_reservations(world, "immediately after the target's death")

	var retargeted := false
	for i in 100:
		world.tick()
		_assert_no_orphaned_reservations(world, "actor retarget search tick %d" % world.get_tick())
		var job := _approach_job_of(world, "hunter")
		if job.is_empty():
			continue
		var target: Dictionary = world._approach_giver.get_job_targets().get(String(job["id"]), {})
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
	world._set_object(10, 5, "wooden_wall") # nearer object target (defaults to colony faction, hostile to raiders)
	world._set_object(30, 5, "wooden_wall") # farther object target
	world.tick() # backfills "combat"/"health" before this test mutates it

	var approach_job_id := ""
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-destruction tick %d" % world.get_tick())
		var job := _approach_job_of(world, "wrecker")
		if job.is_empty():
			continue
		var target: Dictionary = world._approach_giver.get_job_targets().get(String(job["id"]), {})
		if String(target.get("kind", "")) == "object" and target.get("tile") == Vector2i(10, 5):
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the wrecker must commit to the nearer wall first for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(world._get_job(approach_job_id).get("status", "")) in ["queued", "active"],
		"the approach job must still be in flight when its target is destroyed for this check to be meaningful")

	world._set_object(10, 5, "") # simulates the current object target being destroyed/cleared
	_assert_no_orphaned_reservations(world, "immediately after the object's destruction")

	var retargeted := false
	for i in 100:
		world.tick()
		_assert_no_orphaned_reservations(world, "object retarget search tick %d" % world.get_tick())
		var job := _approach_job_of(world, "wrecker")
		if job.is_empty():
			continue
		var target: Dictionary = world._approach_giver.get_job_targets().get(String(job["id"]), {})
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
	_expect(world._approach_giver.get_job_targets().has(approach_job_id),
		"the committed approach job must have a tracked target for this check to be meaningful")

	var hunter := world._find_colonist("hunter")
	var bait := _spawn_actor(world, "colony", "adjacent_bait", int(hunter["x"]), int(hunter["y"]) - 1)
	world._remove_colonist_by_id("far_target", true) # the tracked job's own target dies

	var saw_adjacent := false
	var cancelled := false
	for i in 20:
		# Offset by y, not x: the hunter's
		# own route runs due east, so re-pinning the bait one tile north of the
		# hunter's own pre-tick position stays Chebyshev-adjacent to both of
		# the hunter's possible post-movement positions this tick (unmoved, or
		# one step east) -- a west/east offset computed pre-tick would fall out
		# of adjacency the instant the hunter actually takes a step.
		var h := world._find_colonist("hunter")
		bait["x"] = int(h["x"])
		bait["y"] = int(h["y"]) - 1
		world.tick()
		_assert_no_orphaned_reservations(world, "adjacent-stale-target tick %d" % world.get_tick())
		if world.get_actor_combat_reason("hunter") == "fighting":
			saw_adjacent = true
		if String(world._get_job(approach_job_id).get("status", "")) not in ["queued", "active"]:
			cancelled = true
			break
	_expect(saw_adjacent, "the hunter must be reported adjacent to a hostile (adjacent_bait) at some point for this check to be meaningful")
	_expect(cancelled, "a tracked approach job's own target dying must still cancel it even on a tick the actor stands adjacent to a different hostile")
	_expect(not world._approach_giver.get_job_targets().has(approach_job_id),
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
	_expect(String(world._get_job(approach_job_id).get("status", "")) == "queued",
		"the freshly committed approach job must still be queued, not yet active, for this check to isolate the queued path")

	# Seals the only corridor between the hunter and its own tracked target,
	# using the hunter's own "raiders" faction so the seal creates no new
	# hostile target (mirrors _check_approach_falls_back_to_incident_when_fully_walled_off()'s
	# own trick).
	for y in WorldStateType.MAP_HEIGHT:
		world._set_object(15, y, "wooden_wall", "raiders")
	var hunter := world._find_colonist("hunter")
	_expect(not world._region_reachable(Vector2i(int(hunter["x"]), int(hunter["y"])), target),
		"the tracked job's own target must actually become unreachable once the corridor is sealed, for this check to be meaningful")
	_assert_no_orphaned_reservations(world, "immediately after sealing the corridor")

	var ever_active := false
	var cancelled := false
	for i in 20:
		world.tick()
		_assert_no_orphaned_reservations(world, "seal-and-cancel tick %d" % world.get_tick())
		var status := String(world._get_job(approach_job_id).get("status", ""))
		if status == "active":
			ever_active = true
		if status not in ["queued", "active"]:
			cancelled = true
			break
	_expect(not ever_active, "a queued job whose target becomes unreachable must be cancelled without ever activating, isolating the queued+blocked_target_unreachable path from the separate active-route-unreachable path")
	_expect(cancelled, "a tracked approach job that goes queued+blocked_target_unreachable must be cancelled through the shared finish boundary")
	_expect(not world._approach_giver.get_job_targets().has(approach_job_id),
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
	var wolf := world._find_colonist("wolf_1")
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
			world._set_object(nx, ny, "wooden_wall", "wildlife")
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
	var incident_job_id := world._incidents.propose(_make_incident_actor(world, actor_id, 0, 0), Vector2i(0, 15), 5)
	_expect(not incident_job_id.is_empty(), "the incident proposal must be accepted")
	_spawn_actor(world, "colony", "villager", 30, 0) # the actor's own separate, unrelated hostile target

	var approach_job_id := ""
	for i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "pre-seal tick %d" % world.get_tick())
		_expect(String(world._get_job(incident_job_id).get("status", "")) != "cancelled",
			"the incident actor's own job must never be cancelled by this giver just because its own combat retargeting is in progress (tick %d)" % world.get_tick())
		var job := _approach_job_of(world, actor_id)
		if String(job.get("status", "")) in ["queued", "active"]:
			approach_job_id = String(job["id"])
			break
	_expect(not approach_job_id.is_empty(), "the incident actor must commit an approach job to the villager for this check to be meaningful")
	if approach_job_id.is_empty():
		return
	_expect(String(world._get_job(incident_job_id).get("status", "")) == "active",
		"the incident actor's own job must still be active while its unrelated approach job commits, for this check to be meaningful")

	# Seals the only corridor to the villager using the actor's own "raiders"
	# faction (mirrors _check_approach_falls_back_to_incident_when_fully_walled_off()'s
	# own trick) so the seal itself is never a new hostile target -- the
	# incident job's own target (0, 15) is untouched by it.
	for y in WorldStateType.MAP_HEIGHT:
		world._set_object(15, y, "wooden_wall", "raiders")
	_assert_no_orphaned_reservations(world, "immediately after sealing the corridor")

	var incident_completed := false
	for i in 200:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-seal tick %d" % world.get_tick())
		if String(world._get_job(incident_job_id).get("status", "")) == "completed":
			incident_completed = true
			break
	_expect(incident_completed, "the incident actor's own walk-then-wait job must reach completed status on its own, entirely unaffected by the sealed-off, unrelated approach job")
	_expect(world._find_colonist(actor_id).is_empty(), "the incident actor must despawn on its own job's natural completion, exactly like an uninterrupted incident")
	_expect(String(world._get_job(approach_job_id).get("status", "")) not in ["queued", "active"],
		"the sealed-off approach job must not be left queued or active once its own actor is gone")
	_expect(not world._approach_giver.get_job_targets().has(approach_job_id),
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
	var incident_job_id := world._submit_incident_job(actor_id, incident_target)
	_expect(not incident_job_id.is_empty(), "the actor's own incident-kind job must be accepted")
	if incident_job_id.is_empty():
		return
	world._incidents.adopt(incident_job_id, actor_id)
	world._set_work_progress(incident_target, 5)
	_expect(String(world._get_job(incident_job_id).get("status", "")) == "queued",
		"the actor's own incident job must sit queued behind its already-active approach job, for this check to be meaningful")
	_assert_no_orphaned_reservations(world, "immediately after queuing the actor's own incident job")

	# Seals the only corridor to the hostile target using the actor's own
	# "raiders" faction (mirrors _check_approach_falls_back_to_incident_when_fully_walled_off()'s
	# own trick) so the seal itself is never a new hostile target -- the
	# incident job's own target (0, 15) is untouched by it.
	for y in WorldStateType.MAP_HEIGHT:
		world._set_object(15, y, "wooden_wall", "raiders")
	_assert_no_orphaned_reservations(world, "immediately after sealing the corridor")

	var approach_cancelled := false
	for i in 250:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-seal tick %d" % world.get_tick())
		if String(world._get_job(approach_job_id).get("status", "")) not in ["queued", "active"]:
			approach_cancelled = true
			break
	_expect(approach_cancelled, "walling off the actor's own approach target with no replacement must cancel its approach job")
	_expect(not world._approach_giver.get_job_targets().has(approach_job_id),
		"the cancelled approach job must leave no stale target association behind")

	var incident_completed := false
	for i in 200:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-fallback tick %d" % world.get_tick())
		if String(world._get_job(incident_job_id).get("status", "")) == "completed":
			incident_completed = true
			break
	_expect(incident_completed, "the actor's own queued incident job must activate through the ordinary fair-queue path once its approach job frees the worker, and reach completed status on its own walk-then-wait")
	_expect(world._find_colonist(actor_id).is_empty(), "the actor must despawn on its own incident job's natural completion, exactly like an uninterrupted incident")
	_expect(String(world._get_job(approach_job_id).get("status", "")) not in ["queued", "active"],
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

	world._find_colonist("hunter_raider")["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	world.tick()
	_expect(world._combat_giver.owns("hunter_raider"),
		"a hostile actor whose hp fraction drops below its own flee_hp_fraction mid-approach must be claimed by CombatGiver")
	_expect(String(world._get_job(approach_job_id).get("status", "")) != "active",
		"the approach job must not be left active once CombatGiver interrupts it for a flee episode")
	_assert_no_orphaned_reservations(world, "immediately after the flee interrupt")

	var flee_job_found := false
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee" and world._job_restricted_to(String(job["id"])) == "hunter_raider":
			flee_job_found = true
	_expect(flee_job_found, "a hostile actor below its own flee_hp_fraction mid-approach must be given a flee job instead")

	for i in 30:
		world.tick()
		_assert_no_orphaned_reservations(world, "mid-flee tick %d" % world.get_tick())
	_expect(String(world._get_job(approach_job_id).get("status", "")) != "active",
		"the paused approach job must still not be active while the flee episode is ongoing, never left orphaned")

	world._find_colonist("hunter_raider")["health"]["hp"] = 100 # recover above the flee threshold
	var recovered := false
	for i in 80:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-recovery tick %d" % world.get_tick())
		if not world._combat_giver.owns("hunter_raider"):
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
