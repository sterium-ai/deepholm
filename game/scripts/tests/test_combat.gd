extends "res://scripts/tests/support/combat_base.gd"

## test_combat checks; shared helpers and the file's full description are in support/combat_base.gd.

func _init() -> void:
	_check_damage_every_cooldown_not_every_tick()
	_check_cooldown_elapses_while_disengaged()
	_check_death_drops_inventory_and_removes_from_scheduling()
	_check_death_releases_queued_job_and_held_tool()
	_check_wall_destroyed_at_zero_hp()
	_check_targeting_prefers_hostile_among_multiple_occupants()
	_check_object_health_survives_save_load()
	_check_health_bar_pure_functions()
	_check_determinism_same_seed()
	_check_death_during_need_job_releases_paused_work()
	_check_object_health_validation()
	_check_dead_worker_pending_search_frees_job_for_other_worker()
	_check_death_drops_generic_inventory_tools_into_tool_store()
	_check_death_drops_every_inventory_tool_unit_usable_by_workers()

	if _failed:
		quit(1)
		return
	print("test_combat: PASS")
	quit(0)

func _check_damage_every_cooldown_not_every_tick() -> void:
	if _failed: return
	var world := _build_fighters(1)
	var cooldown := int(TestAccess.find_colonist(world, "fighter_a")["combat"]["cooldown"])
	_expect(cooldown > 1, "the colonist combat tunable's cooldown must be greater than 1 tick for this check to be meaningful")
	var hp_after_first := int(TestAccess.find_colonist(world, "fighter_b")["health"]["hp"])
	_expect(hp_after_first == 100 - 2, "the first tick with an adjacent hostile target must land a hit immediately")
	while world.get_tick() < cooldown:
		world.tick()
		var hp_now := int(TestAccess.find_colonist(world, "fighter_b")["health"]["hp"])
		_expect(hp_now == hp_after_first, "no second hit may land before the attacker's own cooldown elapses (tick %d)" % world.get_tick())
	world.tick()
	var hp_after_second := int(TestAccess.find_colonist(world, "fighter_b")["health"]["hp"])
	_expect(hp_after_second == hp_after_first - 2, "a second hit must land exactly `cooldown` ticks after the first (tick %d)" % world.get_tick())
	_expect(world.get_actor_combat_reason("fighter_a") == "fighting", "an actor with an adjacent hostile target must be reported as fighting")

func _check_death_drops_inventory_and_removes_from_scheduling() -> void:
	if _failed: return
	var world := _build_arena(2)
	_spawn_actor(world, "raiders", "attacker", 5, 5)
	_spawn_actor(world, "colony", "victim", 6, 5)
	# "till" (no needs_tool, unlike "dig"/"chop") keeps this a plain
	# reserve/go_to/work job so the assignment activates within one tick.
	var submit_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(7, 5), 1, world.get_tick(), "till", "victim")
	_expect(submit_result.get("ok", false), "the victim's own till job must be accepted")
	var job_id := String(submit_result.get("job_id", ""))
	world.tick()
	_expect(not (world.get_assignments().get("victim", {}) as Dictionary).is_empty(),
		"the victim's dig job must have an active scheduler assignment before death")

	var victim := TestAccess.find_colonist(world, "victim")
	InventoryType.add_to_hands(victim, "wood", 3)
	victim["health"]["hp"] = 1
	var attacker := TestAccess.find_colonist(world, "attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(TestAccess.find_colonist(world, "victim").is_empty(), "a dead actor must be removed from the world")
	_expect((world.get_assignments().get("victim") == null), "a dead actor's scheduler assignment must be released")
	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) in ["cancelled", "failed"],
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
	TestAccess.object_table(world).set_object(6, 5, "wooden_wall")
	world.tick()
	_expect(not TestAccess.object_table(world).object_health_at(6, 5).is_empty(), "a freshly placed wall must carry per-instance health")
	var attacker := TestAccess.find_colonist(world, "wall_attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()
	_expect(world.get_object(6, 5) == "", "a wall reduced to 0 hp must clear to no object (floor underneath)")
	_expect(TestAccess.object_table(world).object_health_at(6, 5).is_empty(), "a destroyed object's health entry must be cleared")

## Cooldown must elapse on wall-clock ticks, not only while an
## adjacent target exists -- an actor that attacks, disengages for longer
## than its own cooldown, then re-engages must attack again immediately, not
## wait out a stale remaining value frozen from mid-engagement.
func _check_cooldown_elapses_while_disengaged() -> void:
	if _failed: return
	var world := _build_fighters(5) # one tick already run: fighter_a landed its first hit
	var cooldown := int(TestAccess.find_colonist(world, "fighter_a")["combat"]["cooldown"])
	var fighter_b := TestAccess.find_colonist(world, "fighter_b")
	var hp_after_first := int(fighter_b["health"]["hp"])
	# Disengage: move fighter_b far away for longer than `cooldown` ticks.
	fighter_b["x"] = 40
	fighter_b["y"] = 40
	for i in cooldown + 5:
		world.tick()
	_expect(int(TestAccess.find_colonist(world, "fighter_b")["health"]["hp"]) == hp_after_first,
		"no hit may land while the two actors are not adjacent")
	# Re-engage: bring fighter_b back adjacent to fighter_a.
	var fighter_a := TestAccess.find_colonist(world, "fighter_a")
	TestAccess.find_colonist(world, "fighter_b")["x"] = int(fighter_a["x"]) + 1
	TestAccess.find_colonist(world, "fighter_b")["y"] = int(fighter_a["y"])
	world.tick()
	_expect(int(TestAccess.find_colonist(world, "fighter_b")["health"]["hp"]) == hp_after_first - 2,
		"cooldown elapsed during disengagement must let the very next re-engaged tick land a hit immediately, not wait out a stale remaining value")

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
		var watcher := TestAccess.find_colonist(world, "watcher")
		watcher["combat"]["cooldown_remaining"] = 0
		var enemy_hp_before := int(TestAccess.find_colonist(world, "enemy")["health"]["hp"])
		world.tick()
		_expect(int(TestAccess.find_colonist(world, "enemy")["health"]["hp"]) < enemy_hp_before,
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
	TestAccess.object_table(world).set_object(6, 5, "wooden_wall")
	TestAccess.object_table(world).set_object(7, 5, "door")
	world.tick()
	var wall_max := int(TestAccess.object_table(world).object_health_at(6, 5)["maxHp"])
	var door_max := int(TestAccess.object_table(world).object_health_at(7, 5)["maxHp"])
	TestAccess.object_table(world).damage_object(6, 5, 30)
	TestAccess.object_table(world).damage_object(7, 5, 15)
	var wall_hp_before := int(TestAccess.object_table(world).object_health_at(6, 5)["hp"])
	var door_hp_before := int(TestAccess.object_table(world).object_health_at(7, 5)["hp"])
	_expect(wall_hp_before == wall_max - 30, "a damaged wall must carry its exact damaged hp before save")
	_expect(door_hp_before == door_max - 15, "a damaged door must carry its exact damaged hp before save")
	_expect(wall_hp_before != wall_max and door_hp_before != door_max,
		"both fixtures must actually be damaged (below max) for this check to be meaningful")

	var loaded := StateCodecType.decode(StateCodecType.encode(world))
	_expect(loaded.get_object(6, 5) == "wooden_wall", "a wall must survive a save/load round trip")
	_expect(loaded.get_object(7, 5) == "door", "a door must survive a save/load round trip")
	_expect(int(TestAccess.object_table(loaded).object_health_at(6, 5).get("hp", -1)) == wall_hp_before,
		"a damaged wall's exact hp must survive save/load, not reset to full")
	_expect(int(TestAccess.object_table(loaded).object_health_at(7, 5).get("hp", -1)) == door_hp_before,
		"a damaged door's exact hp must survive save/load, not reset to full")

	TestAccess.object_table(loaded).damage_object(6, 5, wall_hp_before)
	_expect(loaded.get_object(6, 5) == "", "a wall already damaged before save must clear to floor once its persisted hp (not a reset full hp) reaches 0 after load")
	TestAccess.object_table(loaded).damage_object(7, 5, door_hp_before - 1)
	_expect(int(TestAccess.object_table(loaded).object_health_at(7, 5).get("hp", -1)) == 1,
		"further damage after load must land relative to the persisted hp, not a reset full hp")

## A dead actor's queued (not-yet-activated) job restricted
## to it must be cancelled too, and its held tool must be moved to the
## ground rather than left pointing at a removed actor.
func _check_death_releases_queued_job_and_held_tool() -> void:
	if _failed: return
	var world := _build_arena(12)
	_spawn_actor(world, "raiders", "attacker", 5, 5)
	_spawn_actor(world, "colony", "victim", 6, 5)
	var victim := TestAccess.find_colonist(world, "victim")

	var active_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(7, 5), 1, world.get_tick(), "till", "victim")
	_expect(active_result.get("ok", false), "the victim's own active till job must be accepted")
	var active_job_id := String(active_result.get("job_id", ""))
	world.tick()
	_expect(String(TestAccess.get_job(world, active_job_id).get("status", "")) == "active", "the victim's first job must be active before death")

	# A second job restricted to the same, already-busy victim: it can only
	# ever sit queued, never activated, since the victim has no free capacity.
	var queued_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(8, 5), 1, world.get_tick(), "till", "victim")
	_expect(queued_result.get("ok", false), "a second job restricted to the victim must still be accepted onto the queue")
	var queued_job_id := String(queued_result.get("job_id", ""))
	_expect(String(TestAccess.get_job(world, queued_job_id).get("status", "")) == "queued", "the second job restricted to the busy victim must remain queued, never activated")

	var tool_item_id := TestAccess.tool_store(world).spawn_ground("axe", int(victim["x"]), int(victim["y"]))
	TestAccess.tool_store(world).set_held(tool_item_id, "victim")
	_expect(String(TestAccess.tool_store(world).get_item(tool_item_id)["location"]["type"]) == "held", "the victim must be holding the tool before death")

	victim["health"]["hp"] = 1
	var attacker := TestAccess.find_colonist(world, "attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(TestAccess.find_colonist(world, "victim").is_empty(), "a dead actor must be removed from the world")
	_expect(String(TestAccess.get_job(world, active_job_id).get("status", "")) in ["cancelled", "failed"], "a dead actor's own active job must be terminated")
	_expect(String(TestAccess.get_job(world, queued_job_id).get("status", "")) in ["cancelled", "failed"],
		"a dead actor's own still-queued (never activated) job must also be terminated, not left dangling in the queue forever")
	var tool_location: Dictionary = TestAccess.tool_store(world).get_item(tool_item_id).get("location", {})
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
	var work_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(7, 5), 1, world.get_tick(), "till")
	_expect(work_result.get("ok", false), "the unrestricted till job must be accepted")
	var work_job_id := String(work_result.get("job_id", ""))
	world.tick()
	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) == "active", "the unrestricted till job must be active before the interrupt")
	_expect(String((world.get_assignments().get("worker", {}) as Dictionary).get("job_id", "")) == work_job_id,
		"the worker must be assigned the unrestricted till job before the interrupt")

	var worker := TestAccess.find_colonist(world, "worker")
	TestAccess.needs_system(world).interrupt_current_job(worker) # mirrors NeedGiver's own critical-need interrupt
	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) == "queued", "the interrupted till job must be suspended back to queued")
	_expect(String(TestAccess.needs_system(world).paused_jobs.get("worker", "")) == work_job_id, "the interrupted till job must be recorded as this worker's own paused job")

	var need_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(8, 5), 1, world.get_tick(), "drink_water", "worker")
	_expect(need_result.get("ok", false), "the worker's own restricted need job must be accepted")
	var need_job_id := String(need_result.get("job_id", ""))
	TestAccess.need_giver_pending(world)["worker"] = need_job_id
	world.tick()
	_expect(String(TestAccess.get_job(world, need_job_id).get("status", "")) == "active", "the need job must be active before death for this check to be meaningful")
	_expect(String((world.get_assignments().get("worker", {}) as Dictionary).get("job_id", "")) == need_job_id,
		"the worker's own active assignment must be the need job, not the paused work job, at the moment of death")

	worker["health"]["hp"] = 1
	var reaper := TestAccess.find_colonist(world, "reaper")
	reaper["combat"]["damage"] = 999
	reaper["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(TestAccess.find_colonist(world, "worker").is_empty(), "a dead actor must be removed from the world")
	_expect(world.get_assignments().get("worker") == null,
		"a dead actor's scheduler assignment must be released, not reactivated onto its own previously-paused, unrestricted work")
	_expect(String(TestAccess.get_job(world, need_job_id).get("status", "")) in ["cancelled", "failed"], "the dead actor's own active need job must be terminated")
	_expect(String(TestAccess.get_job(world, work_job_id).get("status", "")) in ["cancelled", "failed"],
		"the dead actor's own previously-paused, unrestricted work job must also be terminated, not silently resumed and left dangling")
	_expect(not (TestAccess.needs_system(world).paused_jobs as Dictionary).has("worker"), "a dead actor must leave no residual paused-job entry")
	_expect(TestAccess.need_giver(world).get_pending_job("worker").is_empty(), "a dead actor must leave no residual NeedGiver pending association")

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
	var victim := TestAccess.find_colonist(world, "victim")
	victim["inventory"] = {"items": [{"kind": "axe", "count": 1}, {"kind": "wood", "count": 2}], "tool": "pick", "capacity": 3}

	victim["health"]["hp"] = 1
	var attacker := TestAccess.find_colonist(world, "attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(TestAccess.find_colonist(world, "victim").is_empty(), "a dead actor must be removed from the world")

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
	_expect(String(WorkerType.get_held_tool(TestAccess.find_colonist(world, "smith"))) == dropped_pick_id,
		"a surviving worker holding a dead actor's dropped inventory.tool must be recorded exactly like picking up any other tool item")

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
	TestAccess.object_table(world).set_object(6, 5, "wooden_wall")
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
	TestAccess.find_colonist(world, "reaper")["combat"]["cooldown_remaining"] = 999

	# (5,25) is Manhattan distance 20 from doomed_worker and 15 from
	# rescue_worker -- both >= MAX_TRAVEL_PENALTY, so both proposals tie on
	# score and the tie-break falls to worker id.
	var submit_result: Dictionary = TestAccess.scheduler(world).submit(Vector2i(5, 25), 1, world.get_tick(), "till")
	_expect(submit_result.get("ok", false), "the unrestricted till job must be accepted")
	var job_id := String(submit_result.get("job_id", ""))

	world.tick() # doomed_worker (alphabetically first) is proposed and begins its own route search
	_expect(TestAccess.scheduler(world).get_pending().has("doomed_worker"),
		"doomed_worker must be mid-search on the freed job for this check to be meaningful")
	_expect(not TestAccess.scheduler(world).get_pending().has("rescue_worker"),
		"only the winning worker's own proposal should occupy a pending search slot while the job is still claimed")
	_expect(world.get_assignments().get("doomed_worker") == null,
		"the search must still be in flight (not yet assigned) for this check to be meaningful")

	for i in 3:
		world.tick()
	_expect(TestAccess.scheduler(world).get_pending().has("doomed_worker"),
		"doomed_worker's own route search must still be unfinished (genuinely multi-tick) at the moment of death for this check to be meaningful")
	_expect(world.get_assignments().get("doomed_worker") == null,
		"doomed_worker must still be unassigned (mid-search) at the moment of death for this check to be meaningful")

	var doomed := TestAccess.find_colonist(world, "doomed_worker")
	doomed["health"]["hp"] = 1
	var reaper := TestAccess.find_colonist(world, "reaper")
	reaper["combat"]["damage"] = 999
	reaper["combat"]["cooldown_remaining"] = 0
	world.tick()

	_expect(TestAccess.find_colonist(world, "doomed_worker").is_empty(), "the doomed worker must be removed from the world")
	_expect(not TestAccess.scheduler(world).get_pending().has("doomed_worker"),
		"a dead worker's own pending route-search state must be retired, not left claiming its candidate job(s) forever")
	_expect(String(TestAccess.get_job(world, job_id).get("status", "")) == "queued",
		"the unrestricted job a dead worker was merely searching (never assigned) must stay queued for another worker, not be cancelled")

	var rescued := false
	for i in 20:
		world.tick()
		if String(TestAccess.get_job(world, job_id).get("status", "")) == "active" and String((world.get_assignments().get("rescue_worker", {}) as Dictionary).get("job_id", "")) == job_id:
			rescued = true
			break
	_expect(rescued, "a surviving worker must actually be able to receive and be assigned the job a dead worker's own retired pending search left behind")

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
	var victim := TestAccess.find_colonist(world, "victim")
	victim["inventory"] = {"items": [{"kind": "axe", "count": 2}, {"kind": "wood", "count": 2}], "tool": "pick", "capacity": 4}
	victim["health"]["hp"] = 1
	var attacker := TestAccess.find_colonist(world, "attacker")
	attacker["combat"]["damage"] = 999
	attacker["combat"]["cooldown_remaining"] = 0
	world.tick()
	_expect(TestAccess.find_colonist(world, "victim").is_empty(), "a dead actor must be removed from the world")

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
	TestAccess.set_tile(world, 22, 5, WorldStateType.TILE_TREE)
	TestAccess.set_tile(world, 6, 22, WorldStateType.TILE_SOIL)
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
			if WorkerType.get_held_tool(TestAccess.find_colonist(world, "lumberjack")) == axe_id:
				axe_held = true
		for pick_id in pick_ids:
			if world.get_tool_item_reservation(pick_id) == dig_id:
				pick_reserved_for_dig = true
			if WorkerType.get_held_tool(TestAccess.find_colonist(world, "miner")) == pick_id:
				pick_held = true
		if String(TestAccess.get_job(world, chop_id).get("status", "")) == "completed" and String(TestAccess.get_job(world, dig_id).get("status", "")) == "completed":
			both_done = true
			break
	_expect(axe_reserved_for_chop, "the chop job must reserve one of the dropped inventory.items axes through normal discovery")
	_expect(axe_held, "the lumberjack must pick up and hold a dropped inventory.items axe")
	_expect(pick_reserved_for_dig, "the dig job must reserve the dropped inventory.tool pick through normal discovery")
	_expect(pick_held, "the miner must pick up and hold the dropped inventory.tool pick")
	_expect(both_done, "both tool-requiring jobs must complete using only the dropped tools (chop '%s', dig '%s')" % [TestAccess.get_job(world, chop_id).get("status", ""), TestAccess.get_job(world, dig_id).get("status", "")])
	_expect(world.get_tile(22, 5) != WorldStateType.TILE_TREE and world.get_tile(6, 22) != WorldStateType.TILE_SOIL,
		"the chop and dig work effects must have been applied with the dropped tools")
