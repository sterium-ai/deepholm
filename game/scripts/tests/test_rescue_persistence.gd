extends "res://scripts/tests/support/rescue_base.gd"

## test_rescue_persistence checks; shared helpers and the file's full description are in support/rescue_base.gd.

func _init() -> void:
	_check_save_load_preserves_active_rescue_continuation()
	_check_save_load_preserves_suspended_rescue_continuation()
	_check_save_load_through_real_save_io_preserves_shared_target_victim_identity()
	_check_state_hash_reflects_rescue_victim_assignment()
	_check_state_hash_equal_across_save_load_with_digit_boundary_rescue_ids()
	if _failed:
		quit(1)
		return
	print("test_rescue_persistence: PASS")
	quit(0)

## A save/load while a rescue job is active (the
## rescuer already working) must not create a duplicate rescue job for the
## same victim, and the surviving job must still resume and complete
## correctly -- RescueGiver's own bookkeeping (_pending/_job_victim) is
## rebuilt fresh from already-persisted data (state_codec.gd's decode(),
## rescue_giver.gd's restore_victim_assignments()/restore_pending_assignments()),
## never carried on the wire directly.
func _check_save_load_preserves_active_rescue_continuation() -> void:
	var world := _fresh_world(360012)
	_trap_colonist_0(world)
	var victim_id: String = String(TestAccess.colonists(world)[0]["id"])
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
		if not job_id.is_empty() and TestAccess.find_colonist(world, rescuer_id).get("work") != null:
			working = true
			break
	_expect(working, "setup: the rescue must reach its own active work toil before the save/load")
	var state := StateCodecType.encode(world)
	var loaded: WorldStateType = StateCodecType.decode(state)
	_expect(String(TestAccess.scheduler(loaded).queue.get_job(job_id).get("status", "")) == "active",
		"the rescue job must still be active immediately after load")
	_expect(TestAccess.rescue_giver(loaded).get_pending_job(rescuer_id) == job_id,
		"the loaded RescueGiver must still associate the rescuer with the same rescue job")
	var loaded_victim := TestAccess.find_colonist(loaded, victim_id)
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

## The suspended half: a save/load while a rescue
## job is suspended (its own rescuer mid a critical-need interrupt) must
## still resume and complete the same rescue after load, with no orphaned
## reservation left behind.
func _check_save_load_preserves_suspended_rescue_continuation() -> void:
	var world := _fresh_world(360013)
	_trap_colonist_0(world)
	var victim_id: String = String(TestAccess.colonists(world)[0]["id"])
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
		if not job_id.is_empty() and TestAccess.find_colonist(world, rescuer_id).get("work") != null:
			working = true
			break
	_expect(working, "setup: the rescue must reach its own active work toil")
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
	_expect(not need_job_id.is_empty(), "setup: the rescuer's own critical need must interrupt the rescue before the save/load")
	_expect(String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "queued",
		"setup: the rescue job must be suspended (queued) at save time")
	var state := StateCodecType.encode(world)
	var loaded: WorldStateType = StateCodecType.decode(state)
	_expect(TestAccess.rescue_giver(loaded).get_pending_job(rescuer_id) == job_id,
		"the loaded RescueGiver must still associate the rescuer with the suspended rescue job")
	var loaded_victim := TestAccess.find_colonist(loaded, victim_id)
	var rescued := false
	for _i in RESCUE_TICK_BOUND:
		loaded.tick()
		if loaded_victim.get("trapped") == null:
			rescued = true
			break
	_expect(rescued, "the loaded world must still resume and complete the suspended rescue once the need resolves")
	var report := ReservationInvariantsType.check(TestAccess.scheduler(loaded).queue.get_reservation_table(), loaded.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "resuming a loaded, suspended rescue must leave no orphaned reservations")

## Verified through the real SaveIO boundary (not
## just StateCodec directly): the
## exact shared-neighbour geometry from
## _check_completing_rescue_frees_the_job_own_victim_not_a_shared_neighbour(),
## where target-tile-plus-adjacency alone cannot tell victim A and victim B
## apart, with a completed rescue job (an unrelated, already-finished rescue)
## also present in job history alongside the active one under test -- SaveIO
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
		_expect(TestAccess.rescue_giver(loaded).victim_for_job(job_b_id) == victim_b_id,
			"loading through the real SaveIO boundary must preserve job_b's own victim identity exactly -- never victim A's, despite the shared target and overlapping adjacency")
		var loaded_a := TestAccess.find_colonist(loaded, String(victim_a["id"]))
		var loaded_b := TestAccess.find_colonist(loaded, victim_b_id)
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

## state_hash() must reflect RescueGiver's
## own job-to-victim association -- two otherwise-identical states naming a
## different victim for the same job id must never hash equal.
func _check_state_hash_reflects_rescue_victim_assignment() -> void:
	var world := _fresh_world(360024)
	var hash_before := world.state_hash()
	TestAccess.rescue_giver_job_victim(world)["fake_job"] = "colonist_0"
	var hash_a := world.state_hash()
	TestAccess.rescue_giver_job_victim(world)["fake_job"] = "colonist_1"
	var hash_b := world.state_hash()
	_expect(hash_a != hash_before, "state_hash must reflect a newly added rescue victim assignment")
	_expect(hash_a != hash_b, "state_hash must differ when the same job id names a different victim")

## Two live rescues whose job ids straddle a digit
## boundary (job_9 and job_10 -- inserted in that order live, but sorted
## "job_10" < "job_9" on disk) must hash identically before and after a real
## save/load, since the associations themselves are identical.
func _check_state_hash_equal_across_save_load_with_digit_boundary_rescue_ids() -> void:
	var world := _fresh_world(360028)
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_TRENCH)
	TestAccess.set_tile(world, 1, 10, WorldStateType.TILE_TRENCH)
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_SOIL)
	TestAccess.set_tile(world, 2, 10, WorldStateType.TILE_SOIL)
	var victim_a: Dictionary = TestAccess.colonists(world)[0]
	var victim_b := _spawn_colonist(world, "colonist_1", 0, 10)
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
	# Burn job ids up to job_8 with orders cancelled straight away.
	while TestAccess.scheduler(world).queue.get_next_id() < 9:
		var y: int = 20 + TestAccess.scheduler(world).queue.get_next_id()
		TestAccess.set_tile(world, 5, y, WorldStateType.TILE_SOIL)
		var burn := TestAccess.scheduler(world).submit(Vector2i(5, y), 1, world.get_tick(), "till", "")
		_expect(burn.get("ok", false), "setup: id-burning order must be accepted")
		world.apply({"actor": "test", "command_id": "burn_%d" % y, "tick": world.get_tick(), "type": "cancel_job",
			"payload": {"job_id": String(burn["job_id"])}})
	_expect(TestAccess.scheduler(world).queue.get_next_id() == 9, "setup: the next job id must be job_9")
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
	var victims := TestAccess.rescue_giver(world).get_job_victims()
	_expect(victims.has("job_9") and victims.has("job_10"), "setup: the two live rescues must be job_9 and job_10 (got %s)" % [victims.keys()])
	_expect(String(victims.keys()[0]) == "job_9", "setup: the live association must have been inserted job_9 first")
	var live_hash := world.state_hash()
	var loaded: WorldStateType = StateCodecType.decode(StateCodecType.encode(world))
	_expect(TestAccess.rescue_giver(loaded).get_job_victims() == victims, "the loaded associations must be identical")
	_expect(loaded.state_hash() == live_hash,
		"state_hash must be identical across save/load when the only difference is the Dictionary order of identical rescue associations")
