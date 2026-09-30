extends SceneTree

## Proves WorldState.to_save_state()/from_save_state() round-trip every piece
## of state needed to keep ticking identically after a load: tiles,
## colonists, jobs/reservations, the scheduler's waiting queue/cursors/
## ordinals/pending route-search progress, the job-ID and event-sequence
## counters, and the seeded RandomNumberGenerator's state. See
## docs/architecture/contracts/game-state.schema.json (schemaVersion 3).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const SEEDS := [20260916, 830115]
const SAVE_TICK := 2
const ADVANCE_TICKS := 12

const CHOP_SAVE_SEED := 314159
const CHOP_SAVE_ADVANCE_TICKS := 500

const ZONE_SAVE_SEED := 909090
const HAUL_SAVE_SEED := 194001
const MINE_SAVE_SEED := 353100

var _failed := false

func _init() -> void:
	for seed_value in SEEDS:
		_check_seed(seed_value)
	_check_pending_chop_save_load()
	_check_zone_save_load()
	_check_haul_save_load_mid_walk_and_mid_carry()
	_check_mine_save_load()

	if _failed:
		quit(1)
		return
	print("test_save_determinism: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A single 1-tile-wide corridor (top row, then the right column) from (0,0)
## to (47,47), everything else impassable rock. This makes route-search
## expansion counts fully predictable: the only path from (0,0) is 94 tiles
## long, more than one STEP_BUDGET (64) but at most two, so a search toward
## the far end is guaranteed to still be "searching" after exactly one
## resume() call. colonist_1 starts at the corridor's other end (47,0), one
## step from colonist_0's own future target, so its own route resolves and
## activates within a single resume() call.
func _fresh_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	# Clear any generator-placed berry_bush (ADR 020)
	# before overwriting tiles, so it can never sit on this fixture's own
	# single-tile-wide corridor.
	world._objects.clear()
	world._object_factions.clear()
	for x in WorldStateType.MAP_WIDTH:
		world._tiles[x] = WorldStateType.TILE_SOIL
	for y in range(1, WorldStateType.MAP_HEIGHT):
		world._tiles[y * WorldStateType.MAP_WIDTH + (WorldStateType.MAP_WIDTH - 1)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 47, "y": 0, "route": null, "work": null, "hands": []})
	# Already held, not merely reachable: this scenario's exact tick-by-tick
	# activation/completion choreography leaves no room for fetch_tool's own
	# travel tick, so both colonists start the run already equipped.
	world.set_tool_item_held(world.spawn_ground_tool_item("pick", 0, 0), "colonist_0")
	world.set_tool_item_held(world.spawn_ground_tool_item("pick", 47, 0), "colonist_1")
	return world

func _apply(world: WorldStateType, command_id: String, type: String, payload: Dictionary) -> Dictionary:
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": type, "payload": payload,
	})
	_expect(result["ok"], "command %s must be accepted: %s" % [command_id, result])
	return result

## Submits EARLY (adjacent to colonist_0, activates and completes within
## tick 1), then at tick 1 submits FAR (far end of the corridor from
## colonist_0, priority HIGH), ACTIVE_JOB (adjacent to colonist_1, priority
## NORMAL) and QUEUED_LOW (near colonist_0, priority LOW). Advances to
## SAVE_TICK, where: colonist_0's batch has FAR as its current candidate,
## created and resumed exactly once this tick and still searching (94-tile
## path > 64-step budget), with QUEUED_LOW sitting untouched as its second,
## unstarted candidate; colonist_1's single-candidate batch resolves
## ACTIVE_JOB's route within that same resume() call (one step away) and
## activates it this tick, so it is genuinely active -- assigned, reserved,
## no longer searching -- while FAR's search is still in flight. Per ADR
## 004, route searches only ever live on a queued job's pending evaluation;
## FAR (queued) carries the in-flight search, never ACTIVE_JOB (active).
func _prime_to_save_tick(world: WorldStateType) -> Dictionary:
	var early: String = _apply(world, "early", "dig", {"x": 1, "y": 0, "priority": 1})["job_id"]
	world.tick() # tick 1: EARLY activates (single, adjacent candidate).
	_apply(world, "complete_early", "complete_job", {"job_id": early})
	var far: String = _apply(world, "far", "dig", {"x": 47, "y": 47, "priority": 2})["job_id"]
	var active_job: String = _apply(world, "active", "dig", {"x": 46, "y": 0, "priority": 1})["job_id"]
	var queued_low: String = _apply(world, "low", "dig", {"x": 2, "y": 0, "priority": 0})["job_id"]
	world.tick() # tick 2 (SAVE_TICK): FAR resumed once (still searching); ACTIVE_JOB resolved + activated.
	_expect(world.get_tick() == SAVE_TICK, "priming must land exactly on SAVE_TICK")
	return {"early": early, "far": far, "active_job": active_job, "queued_low": queued_low}

## Every currently active job is completed by command before the tick that
## follows. Driven identically off each world's own current state, so two
## worlds that agree entering a tick keep agreeing after it.
func _drive_and_advance(world: WorldStateType, ticks: int) -> void:
	for _i in ticks:
		var current_tick := world.get_tick()
		for job in world.get_jobs():
			if job["status"] == "active":
				_apply(world, "complete_%s_at_%d" % [job["id"], current_tick], "complete_job", {"job_id": job["id"]})
		world.tick()

func _assert_pre_save_state(world: WorldStateType, ids: Dictionary, seed_value: int) -> void:
	var jobs_by_id: Dictionary = {}
	for job in world.get_jobs():
		jobs_by_id[job["id"]] = job
	_expect(jobs_by_id[ids["early"]]["status"] == "completed",
		"EARLY must be completed at save tick (seed %d)" % seed_value)
	_expect(jobs_by_id[ids["far"]]["status"] == "queued",
		"FAR must still be queued (activation happens only once its route resolves) at save tick (seed %d)" % seed_value)
	_expect(jobs_by_id[ids["active_job"]]["status"] == "active",
		"ACTIVE_JOB must be active at save tick (seed %d)" % seed_value)
	_expect(jobs_by_id[ids["queued_low"]]["status"] == "queued",
		"QUEUED_LOW must still be queued and untouched at save tick (seed %d)" % seed_value)

	var assignments: Dictionary = world.get_assignments()
	_expect(assignments.has("colonist_1") and assignments["colonist_1"]["job_id"] == ids["active_job"],
		"colonist_1 must be assigned to ACTIVE_JOB at save tick (seed %d)" % seed_value)

	var colonists_by_id: Dictionary = {}
	for colonist in world.get_colonists():
		colonists_by_id[colonist["id"]] = colonist
	# ACTIVE_JOB's target is one step from colonist_1's start, so activation this
	# same tick (see _advance_colonists()) always leaves it mid-route or, once
	# that single step completes, mid-work -- never idle -- by save tick.
	var colonist_1: Dictionary = colonists_by_id["colonist_1"]
	_expect(colonist_1.get("route") != null or colonist_1.get("work") != null,
		"colonist_1 must be walking to or working ACTIVE_JOB at save tick (seed %d)" % seed_value)
	# colonist_0 has no active assignment yet (FAR's route search is still in
	# flight), so it must not be mid-route or mid-work.
	var colonist_0: Dictionary = colonists_by_id["colonist_0"]
	_expect(colonist_0.get("route") == null and colonist_0.get("work") == null,
		"colonist_0 must be idle while FAR's route search is still in flight (seed %d)" % seed_value)

	var pending: Dictionary = world._scheduler.get_pending()
	# Per ADR 004, route searches only ever run on a queued job's pending
	# candidate; a job only becomes active once its route search is terminal.
	# So a worker holding an active assignment can never also carry a
	# pending, non-terminal route -- activation and an in-flight search are
	# mutually exclusive per worker. Assert that invariant directly for every
	# assigned worker at save tick, alongside colonist_0's still-searching
	# FAR batch below, which is where in-flight-search coverage belongs.
	for worker in assignments:
		_expect(not pending.has(worker),
			"a worker holding an active assignment must have no pending batch left (seed %d, worker %s)" % [seed_value, worker])
	_expect(pending.has("colonist_0"), "worker must have a pending evaluation batch at save tick (seed %d)" % seed_value)
	if not pending.has("colonist_0"):
		return
	var route = pending["colonist_0"]["route"]
	_expect(route != null, "FAR's route must exist at save tick (seed %d)" % seed_value)
	if route == null:
		return
	_expect(route["status"] == "searching", "FAR's route must not be terminal at save tick (seed %d)" % seed_value)
	_expect(int(route["resume_calls"]) >= 1, "FAR's route must have been resumed at least once (seed %d)" % seed_value)
	_expect(int(route["expansions"]) > 0, "FAR's route must have partially expanded its frontier (seed %d)" % seed_value)

## Structural checks matching docs/architecture/contracts/game-state.schema.json
## (schemaVersion 15): required top-level keys, the content-declared "needs"
## object, the empty inventory, and the empty
## groundBerries array. Not a full JSON Schema validator; the
## GDScript producer/consumer pair (StateCodec) is the thing under test.
func _assert_matches_schema(state: Dictionary, seed_value: int) -> void:
	_expect(state.get("schemaVersion") == StateCodecType.SCHEMA_VERSION,
		"schemaVersion must be %d (seed %d)" % [StateCodecType.SCHEMA_VERSION, seed_value])
	_expect(typeof(state.get("contentVersion")) == TYPE_STRING and state["contentVersion"] != "",
		"contentVersion must be a non-empty string (seed %d)" % seed_value)
	_expect(state["inventory"] == {}, "inventory must be honestly empty, not fabricated (seed %d)" % seed_value)
	for entity in state.get("entities", []):
		var needs = (entity as Dictionary).get("needs")
		_expect(needs is Dictionary and needs.has("food") and needs.has("water") and needs.has("rest"),
			"entities must include a needs object with food/water/rest (seed %d)" % seed_value)
		if needs is Dictionary:
			for need_key in ["food", "water", "rest"]:
				_expect(needs.has(need_key) and int(needs[need_key]) >= 0 and int(needs[need_key]) <= 100,
					"needs.%s must be an int in 0..100 (seed %d)" % [need_key, seed_value])
		# A saved entity's route/work is null while idle, or -- once a colonist is
		# walking to or working an active job (see WorldState._advance_colonists())
		# -- a well-formed record matching the schema's route/work shapes.
		var route = (entity as Dictionary).get("route")
		_expect(route == null or (route is Dictionary and route.has("jobId") and route.has("path")
				and route.has("step") and route.has("moveTicksRemaining")),
			"a saved entity's route must be null or a well-formed route record (seed %d)" % seed_value)
		var work = (entity as Dictionary).get("work")
		_expect(work == null or (work is Dictionary and work.has("jobId") and work.has("ticksRemaining")),
			"a saved entity's work must be null or a well-formed work record (seed %d)" % seed_value)
		_expect(((entity as Dictionary).get("hands", []) as Array).is_empty(),
			"a freshly generated colonist must carry nothing (seed %d)" % seed_value)
	for required_key in ["seed", "tick", "map", "entities", "inventory", "jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries"]:
		_expect(state.has(required_key), "save state must include '%s' (seed %d)" % [required_key, seed_value])
	var items: Dictionary = state["items"]
	_expect(items.has("nextId") and items.has("list"), "items must include nextId and list (seed %d)" % seed_value)
	_expect(items["list"] == [], "items.list must be honestly empty on a freshly generated world (seed %d)" % seed_value)
	_expect(state["objects"] == [], "objects must be honestly empty on a freshly generated world (seed %d)" % seed_value)
	_expect(state["zones"] == [], "zones must be honestly empty on a freshly generated world (seed %d)" % seed_value)
	_expect(state["groundBerries"] == [], "groundBerries must be honestly empty on a freshly generated world (seed %d)" % seed_value)
	var scheduling: Dictionary = state["scheduling"]
	for required_key in ["nextJobId", "jobSequence", "jobTick", "queueEventSequence", "eventSequence",
			"waiting", "nextOrdinal", "cursors", "pending", "assignments"]:
		_expect(scheduling.has(required_key), "scheduling must include '%s' (seed %d)" % [required_key, seed_value])
	var rng: Dictionary = state["rng"]
	_expect(rng.has("seed") and rng.has("state"), "rng must include seed and state (seed %d)" % seed_value)

func _check_seed(seed_value: int) -> void:
	if _failed:
		return

	# Path A: an uninterrupted run straight through SAVE_TICK + ADVANCE_TICKS.
	var direct := _fresh_world(seed_value)
	var direct_ids := _prime_to_save_tick(direct)
	_assert_pre_save_state(direct, direct_ids, seed_value)
	_drive_and_advance(direct, ADVANCE_TICKS)

	# Path B: save at SAVE_TICK, restore into a fresh WorldState, then advance
	# the same number of ticks with the same command-generation logic.
	var source := _fresh_world(seed_value)
	var source_ids := _prime_to_save_tick(source)
	_assert_pre_save_state(source, source_ids, seed_value)
	var saved := source.to_save_state()
	_assert_matches_schema(saved, seed_value)

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored.state_hash() == source.state_hash(),
		"restore must match the source's hash before any further ticks (seed %d)" % seed_value)
	_expect(restored._random.seed == source._random.seed,
		"restored RNG seed must match the source's (seed %d)" % seed_value)
	_expect(restored._random.state == source._random.state,
		"restored RNG state must match the source's, not just its seed (seed %d)" % seed_value)
	_drive_and_advance(restored, ADVANCE_TICKS)

	_expect(direct.get_tick() == restored.get_tick(),
		"tick counters must match after advancing %d ticks post-restore (seed %d)" % [ADVANCE_TICKS, seed_value])
	_expect(direct.state_hash() == restored.state_hash(),
		"state_hash must match an uninterrupted run after advancing %d ticks post-restore (seed %d)" % [ADVANCE_TICKS, seed_value])
	_expect(direct.get_jobs() == restored.get_jobs(),
		"full job records must match after advancing post-restore (seed %d)" % seed_value)

## Same corridor shape as _fresh_world() (top row + right column, 95 tiles,
## more than one STEP_BUDGET (64) but at most two), reused here for a chop
## target instead of a dig target: (47,47) is TILE_TREE rather than
## TILE_SOIL, only reachable via the _routable() target exception a chop
## route search depends on (see global_assignment.gd). NEAR at (0,1), one
## step from the colonist's start, is also TILE_TREE, off the corridor
## entirely so it cannot shorten FAR's own path.
func _chop_save_load_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	# See _fresh_world()'s own doc comment above.
	world._objects.clear()
	world._object_factions.clear()
	for x in WorldStateType.MAP_WIDTH:
		world._tiles[x] = WorldStateType.TILE_SOIL
	for y in range(1, WorldStateType.MAP_HEIGHT):
		world._tiles[world._tile_index(WorldStateType.MAP_WIDTH - 1, y)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(0, 1)] = WorldStateType.TILE_TREE
	world._tiles[world._tile_index(WorldStateType.MAP_WIDTH - 1, WorldStateType.MAP_HEIGHT - 1)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world.set_tool_item_held(world.spawn_ground_tool_item("axe", 0, 0), "colonist_0")
	return world

## Regression: saving mid-evaluation of a chop
## candidate must not lose information GlobalAssignment needs to resume
## identically. Submitting NEAR and FAR together gives colonist_0's single
## pending batch both shapes at once by SAVE_TICK: NEAR's route resolves into
## "found" (with a resolved path) on the batch's first evaluated tick, and
## cursor then moves on to FAR, whose own route search is still "searching"
## -- past its first resume() budget, same as _fresh_world()'s FAR -- when
## saved. That exercises both StateCodec._decode_found()'s path round trip
## and restore_scheduling()'s target-aware passability for the in-flight
## route together.
func _check_pending_chop_save_load() -> void:
	if _failed:
		return
	var near_target := Vector2i(0, 1)
	var far_target := Vector2i(WorldStateType.MAP_WIDTH - 1, WorldStateType.MAP_HEIGHT - 1)

	var world := _chop_save_load_world(CHOP_SAVE_SEED)
	var near_id: String = _apply(world, "near", "chop", {"x": near_target.x, "y": near_target.y, "priority": 1})["job_id"]
	var far_id: String = _apply(world, "far", "chop", {"x": far_target.x, "y": far_target.y, "priority": 1})["job_id"]

	world.tick() # tick 1: batch created; NEAR's one-step search resolves into "found" this same tick.
	world.tick() # tick 2: FAR's search starts and stays "searching" past its first resume() budget.
	_expect(world.get_tick() == 2, "priming must land on tick 2")

	var pending: Dictionary = world._scheduler.get_pending()
	_expect(pending.has("colonist_0"), "colonist_0 must still hold a pending evaluation batch at tick 2")
	if not pending.has("colonist_0"):
		return
	var request: Dictionary = pending["colonist_0"]
	_expect(int(request["cursor"]) == 1, "batch must have finished evaluating NEAR and moved on to FAR (cursor 1)")
	_expect(request["found"].size() == 1, "NEAR's resolved candidate must sit in 'found', not yet chosen")
	if request["found"].size() != 1:
		return
	var found_path: Array = request["found"][0]["path"]
	_expect(found_path.size() == 2, "NEAR's found path must be the resolved 2-tile route, not empty")
	var route = request["route"]
	_expect(route != null and route["status"] == "searching",
		"FAR's route must still be searching (in flight) at save time")

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored.state_hash() == world.state_hash(),
		"a pending-chop-search save/load round trip must match the source's hash before any further ticks")

	var restored_pending: Dictionary = restored._scheduler.get_pending()
	_expect(restored_pending.has("colonist_0"), "restored world must keep colonist_0's pending batch")
	if restored_pending.has("colonist_0"):
		var restored_found: Array = restored_pending["colonist_0"]["found"]
		var restored_path = restored_found[0].get("path", []) if restored_found.size() == 1 else []
		_expect(restored_found.size() == 1 and restored_path == found_path,
			"restore must recover NEAR's already-found path, not drop it")

	# One more tick resolves FAR's route to a terminal status in both copies
	# (its remaining ~30 expansions comfortably fit the next 64-step budget).
	# Checked tight, right where a wrong-passability restore would diverge:
	# FAR wrongly going "unreachable" here sets its job's reason/remedy via
	# JobQueue._block(), a difference JobQueue.tick()'s later retry silently
	# erases once FAR eventually completes -- so only a check this close to
	# the divergence, not the completion check below, can catch it.
	world.tick()
	restored.tick()
	_expect(world.state_hash() == restored.state_hash(),
		"the tick that resolves FAR's route must still match between the source and its pending-chop restore")
	var direct_far := {}
	var restored_far := {}
	for job in world.get_jobs():
		if job["id"] == far_id:
			direct_far = job
	for job in restored.get_jobs():
		if job["id"] == far_id:
			restored_far = job
	_expect(String(direct_far.get("reason", "")) == String(restored_far.get("reason", "")),
		"FAR's job reason must match between the source and its pending-chop restore right after its route resolves")

	for _i in CHOP_SAVE_ADVANCE_TICKS:
		world.tick()
		restored.tick()

	var direct_jobs: Dictionary = {}
	for job in world.get_jobs():
		direct_jobs[job["id"]] = job
	var restored_jobs: Dictionary = {}
	for job in restored.get_jobs():
		restored_jobs[job["id"]] = job
	for job_id in [near_id, far_id]:
		_expect(direct_jobs[job_id]["status"] == "completed",
			"NEAR/FAR must complete in the uninterrupted run within the advance budget (job %s)" % job_id)
		_expect(restored_jobs[job_id]["status"] == "completed",
			"NEAR/FAR must also complete after a pending-chop save/load, proving the restored FAR search still reaches its own tree target (job %s)" % job_id)

	_expect(world.get_tile(near_target.x, near_target.y) == WorldStateType.TILE_FLOOR, "NEAR target must become floor")
	_expect(world.get_tile(far_target.x, far_target.y) == WorldStateType.TILE_FLOOR, "FAR target must become floor")
	_expect(restored.get_tile(near_target.x, near_target.y) == WorldStateType.TILE_FLOOR, "restored NEAR target must become floor")
	_expect(restored.get_tile(far_target.x, far_target.y) == WorldStateType.TILE_FLOOR, "restored FAR target must become floor")

	_expect(world.state_hash() == restored.state_hash(),
		"advancing the source and its pending-chop restore identically must keep matching state_hash()")

## Proves a world holding at least one player-drawn stockpile zone
## round-trips through to_save_state()/from_save_state() like
## every other piece of state: state_hash() must match immediately after
## restore, and the restored zone list/cell reservation lookup must match too.
func _check_zone_save_load() -> void:
	if _failed:
		return
	var world := WorldStateType.new(ZONE_SAVE_SEED, 10)
	var add_result: Dictionary = world.apply({
		"actor": "player", "command_id": "zone_add", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 3, "y": 3, "width": 2, "height": 2},
	})
	_expect(add_result["ok"], "zone_add setup must be accepted: %s" % add_result)
	var zone_id: String = add_result.get("zone_id", "")
	world.tick()

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored.state_hash() == world.state_hash(),
		"a save/load round trip with a zone present must match the source's hash")
	_expect(restored.get_zones() == world.get_zones(),
		"a restored world must keep the same zone list as its source")
	_expect(not restored.get_zone(zone_id).is_empty(),
		"a restored world must be able to look the saved zone up by id")

	# Regression: state_hash() must cover
	# _next_zone_id, not just the zone dictionary, so a restored world keeps
	# generating the same future zone ids as an uninterrupted run would.
	var source_next: Dictionary = world.apply({
		"actor": "player", "command_id": "zone_add_after_source", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 10, "y": 10, "width": 1, "height": 1},
	})
	_expect(source_next["ok"], "second zone_add on source must be accepted: %s" % source_next)
	var restored_next: Dictionary = restored.apply({
		"actor": "player", "command_id": "zone_add_after_restore", "tick": restored.get_tick(),
		"type": "zone_add", "payload": {"x": 10, "y": 10, "width": 1, "height": 1},
	})
	_expect(restored_next["ok"], "second zone_add on restored must be accepted: %s" % restored_next)
	_expect(source_next.get("zone_id", "") == restored_next.get("zone_id", ""),
		"a restored world must generate the same next zone id as an uninterrupted run (source=%s restored=%s)"
			% [source_next.get("zone_id", ""), restored_next.get("zone_id", "")])

	var reservations := world._scheduler.queue.get_reservation_table()
	reservations.acquire(world._cell_key(3, 3), "synthetic_job")
	_expect(not world.is_cell_free(3, 3), "a synthetic reservation must mark the cell not free before saving")
	var saved_with_reservation := world.to_save_state()
	var restored_with_reservation: WorldStateType = WorldStateType.from_save_state(saved_with_reservation)
	_expect(restored_with_reservation.is_cell_free(3, 3),
		"the shared ReservationTable is diagnostic scheduler state, not persisted state, so a restored world must start with no cell reservations")

func _haul_colonist(world: WorldStateType) -> Dictionary:
	return world.get_colonists()[0]

## Proves a haul job's save/load round trip matches an uninterrupted run at
## two distinct in-flight moments: mid-walk to the item
## (leg one, not yet carrying) and mid-carry (leg two, carrying, walking
## toward the reserved cell) -- both exercised the same way every other
## in-flight state is here, by comparing state_hash() immediately after
## restore and again after advancing both copies identically.
func _check_haul_save_load_mid_walk_and_mid_carry() -> void:
	if _failed:
		return
	var world := WorldStateType.new(HAUL_SAVE_SEED, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._items["item_1"] = {"id": "item_1", "x": 10, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var zone_result := world.apply({"actor": "test", "command_id": "zone_setup", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 20, "y": 0, "width": 1, "height": 1}})
	_expect(zone_result["ok"], "haul save/load setup zone_add must succeed: %s" % zone_result)

	# Mid-walk to the item (leg one): tick until a route toward item_1 exists
	# but the colonist has not yet picked it up.
	var walking := false
	for _i in 20:
		world.tick()
		var colonist := _haul_colonist(world)
		if colonist.get("route") != null and not InventoryType.is_carrying(colonist):
			walking = true
			break
	_expect(walking, "haul save/load setup must reach a mid-walk-to-item state")
	var walk_saved := world.to_save_state()
	var walk_restored: WorldStateType = WorldStateType.from_save_state(walk_saved)
	_expect(walk_restored.state_hash() == world.state_hash(),
		"a mid-walk-to-item save/load round trip must match the source's hash before any further ticks")
	for _i in 150:
		world.tick()
		walk_restored.tick()
	_expect(world.state_hash() == walk_restored.state_hash(),
		"identically advancing the source and its mid-walk-to-item restore must keep matching state_hash()")

	# Mid-carry (leg two): a fresh run, ticked until the colonist is carrying
	# and mid-route toward the reserved cell.
	var carry_world := WorldStateType.new(HAUL_SAVE_SEED, 10)
	carry_world._tiles.fill(WorldStateType.TILE_FLOOR)
	carry_world._colonists.clear()
	carry_world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	carry_world._items["item_1"] = {"id": "item_1", "x": 10, "y": 0, "kind": "wood", "count": 1}
	carry_world._next_item_id = 2
	var carry_zone_result := carry_world.apply({"actor": "test", "command_id": "zone_setup", "tick": carry_world.get_tick(),
		"type": "zone_add", "payload": {"x": 20, "y": 0, "width": 1, "height": 1}})
	_expect(carry_zone_result["ok"], "haul save/load mid-carry setup zone_add must succeed: %s" % carry_zone_result)

	var carrying := false
	for _i in 60:
		carry_world.tick()
		var colonist := _haul_colonist(carry_world)
		if InventoryType.is_carrying(colonist) and colonist.get("route") != null:
			carrying = true
			break
	_expect(carrying, "haul save/load setup must reach a mid-carry state")
	var carry_saved := carry_world.to_save_state()
	var carry_restored: WorldStateType = WorldStateType.from_save_state(carry_saved)
	_expect(carry_restored.state_hash() == carry_world.state_hash(),
		"a mid-carry save/load round trip must match the source's hash before any further ticks")
	var restored_colonist := _haul_colonist(carry_restored)
	_expect(InventoryType.is_carrying(restored_colonist), "a mid-carry restore must still be carrying the item")
	for _i in 150:
		carry_world.tick()
		carry_restored.tick()
	_expect(carry_world.state_hash() == carry_restored.state_hash(),
		"identically advancing the source and its mid-carry restore must keep matching state_hash()")
	_expect(carry_world.get_ground_wood(20, 0) == 1 and carry_restored.get_ground_wood(20, 0) == 1,
		"both the source and its mid-carry restore must finish hauling the item to the zone cell")

func _job_status(world: WorldStateType, job_id: String) -> String:
	for job in world.get_jobs():
		if job["id"] == job_id:
			return String(job["status"])
	return ""

## Regression: a save/load round trip
## with an active "mine" job and an existing ground "stone" item present must
## match the source's hash immediately after restore, then keep matching
## while both copies are driven identically through mine job completion (rock
## -> floor, a second stone item spawns) -- the same treatment every other
## in-flight scenario above gets, not just the migration test's static
## before/after field check.
func _check_mine_save_load() -> void:
	if _failed:
		return
	var world := WorldStateType.new(MINE_SAVE_SEED, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_ROCK
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "hands": []})
	world.set_tool_item_held(world.spawn_ground_tool_item("pick", 0, 0), "colonist_0")
	world._spawn_stone_item(5, 5)

	var submit := _apply(world, "mine_1", "mine", {"x": 1, "y": 0, "priority": 1})
	var job_id := String(submit["job_id"])

	var active := false
	for _i in 10:
		world.tick()
		if _job_status(world, job_id) == "active":
			active = true
			break
	_expect(active, "setup: the mine job must reach active status before saving")
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_ROCK, "setup: the target tile must still be rock before saving")

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored.state_hash() == world.state_hash(),
		"a save/load round trip with an active mine job and a ground stone item present must match the source's hash before any further ticks")

	var completed := false
	for _i in 100:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and its mine save/load restore must keep matching state_hash() every tick while driven identically")
		if not completed and _job_status(world, job_id) == "completed":
			completed = true
	_expect(completed, "the mine job must complete within the tick budget in the uninterrupted source run")
	_expect(_job_status(restored, job_id) == "completed",
		"the mine job must also complete in the restored copy, driven identically")

	_expect(world.get_tile(1, 0) == WorldStateType.TILE_FLOOR and restored.get_tile(1, 0) == WorldStateType.TILE_FLOOR,
		"the mined tile must become floor in both the source and its restore")

	var source_stone_count := 0
	for item in world.get_items():
		if String(item.get("kind", "")) == "stone":
			source_stone_count += 1
	var restored_stone_count := 0
	for item in restored.get_items():
		if String(item.get("kind", "")) == "stone":
			restored_stone_count += 1
	_expect(source_stone_count == 2 and restored_stone_count == 2,
		"two stone items (the pre-existing one and the mined one) must exist in both the source and its restore, got %d/%d" % [source_stone_count, restored_stone_count])

	_expect(world.state_hash() == restored.state_hash(),
		"the source and its mine save/load restore must still match state_hash() after mine completion")
