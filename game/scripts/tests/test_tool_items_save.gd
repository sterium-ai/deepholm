extends "res://scripts/tests/support/tool_items_base.gd"

## test_tool_items_save checks; shared helpers and the file's full description are in support/tool_items_base.gd.

func _init() -> void:
	_check_save_round_trip()
	_check_save_io_rejects_extra_toolitems_field()
	_check_save_io_round_trip_after_candidate_excluded()
	_check_save_io_round_trip_mid_drop_tool_movement_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_drop_tool_route_search_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_drop_tool_search_impassable_target_between_holder_and_stockpile()
	_check_save_io_round_trip_after_requester_cancellation_midflight()
	_check_save_io_round_trip_in_reservation_release_gap_with_unrelated_foreign_reserved_held_tool()
	_check_save_io_round_trip_ordinary_route_after_held_tool_foreign_reserved_midflight()
	_check_save_io_round_trip_mid_drop_during_haul_job_preserves_cargo_and_completes()

	if _failed:
		quit(1)
		return
	print("test_tool_items_save: PASS")
	quit(0)

## to_save_state()/from_save_state() must round-trip tool items, their
## reservations and a colonist's held_tool.
func _check_save_round_trip() -> void:
	var world := WorldStateType.new(20260919)
	var ground_id := world.spawn_ground_tool_item("pick", 6, 7)
	_expect(world.reserve_tool_item(ground_id, "job_saved"), "reserving the ground item must succeed")
	var colonist_id := String(world.get_colonists()[0]["id"])
	var held_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(held_id, colonist_id), "moving the second item to the colonist's hand must succeed")

	var saved := world.to_save_state()
	_expect(int(saved["schemaVersion"]) == StateCodecType.SCHEMA_VERSION,
		"to_save_state() must report the current schema version")
	_expect(saved.has("toolItems") and saved.has("toolReservations"), "saved state must include toolItems/toolReservations")

	var validation := TestAccess.save_validate_state(saved)
	_expect(validation["ok"], "a freshly produced save must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

	var restored := WorldStateType.from_save_state(saved)
	var restored_ground := restored.get_tool_item(ground_id)
	_expect(restored_ground.get("kind") == "pick" and restored_ground.get("location", {}).get("type") == "ground",
		"restored ground tool item must keep its kind and ground location")
	_expect(restored.get_tool_item_reservation(ground_id) == "job_saved",
		"restored tool reservation map must keep job_saved's reservation")
	var restored_colonist := Scenarios.colonist_by_id(restored, colonist_id)
	_expect(String(restored_colonist.get("held_tool")) == held_id,
		"restored colonist must still record held_tool")
	_expect(restored.get_tool_item(held_id).get("location", {}).get("type") == "held",
		"restored held tool item must keep its 'held' location")

## game-state.schema.json declares toolItems additionalProperties: false;
## SaveIO._valid_tool_items() must reject a current-schema save that carries
## an extra field on the toolItems container itself, not just on its entries.
func _check_save_io_rejects_extra_toolitems_field() -> void:
	var world := WorldStateType.new(20260919)
	world.spawn_ground_tool_item("axe", 1, 1)
	var saved := world.to_save_state()
	_expect(TestAccess.save_validate_state(saved)["ok"], "the unmodified save must pass validation first")

	var tampered: Dictionary = saved.duplicate(true)
	var tool_items: Dictionary = (tampered["toolItems"] as Dictionary).duplicate(true)
	tool_items["extra"] = "unexpected"
	tampered["toolItems"] = tool_items
	var validation := TestAccess.save_validate_state(tampered)
	_expect(not validation["ok"], "a toolItems container with an unexpected field must be rejected")
	_expect(validation.get("code") == "schema_error",
		"an unexpected toolItems field must fail as schema_error, got '%s'" % validation.get("code"))

## ToolFetchToil._excluded (per-job, tried-and-unreachable tool-id set) must
## persist across a real SaveIO round trip
## (write_atomic()/read(), schemaVersion 17) -- otherwise a restored run
## re-tries a candidate an uninterrupted run had already ruled out, changing
## every subsequent tick. Walls off a closer pick (excluded after one failed
## fetch attempt) while a farther one stays reachable, saves right after the
## closer candidate is excluded but before the job completes, and proves both
## the excluded set itself and the full tick-by-tick continuation to
## completion match an uninterrupted run.
func _check_save_io_round_trip_after_candidate_excluded() -> void:
	var world := WorldStateType.new(271014)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 7):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 6, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 2) # closer (distance 2) but walled off
	world.spawn_ground_tool_item("pick", 5, 0) # farther (distance 5) but reachable

	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": 6, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var excluded := false
	for _i in 300:
		world.tick()
		var current: Array = TestAccess.toils(world).get_fetch_tool_excluded().get(job_id, [])
		if not current.is_empty():
			excluded = true
			break
	_expect(excluded, "the closer, walled-off pick must be excluded within the tick budget")
	_expect(String(Scenarios.find_job(world, job_id).get("status", "")) != "completed",
		"the job must not already be complete the instant the closer candidate is excluded")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-exclusion: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-exclusion: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(TestAccess.toils(restored).get_fetch_tool_excluded().get(job_id, []) == TestAccess.toils(world).get_fetch_tool_excluded().get(job_id, []),
		"restore must recover the exact excluded-candidate set, not drop it")
	_expect(restored.state_hash() == world.state_hash(),
		"restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	for _i in 300:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
			break
	_expect(direct_completed, "the uninterrupted run must still complete by fetching the farther pick")

	var restored_completed := false
	for _i in 300:
		restored.tick()
		var restored_job := {}
		for j in restored.get_jobs():
			if String(j["id"]) == job_id:
				restored_job = j
		if String(restored_job.get("status", "")) == "completed":
			restored_completed = true
			break
	_expect(restored_completed, "the SaveIO-restored run must also complete by fetching the farther pick, without re-trying the excluded one")
	_expect(world.state_hash() == restored.state_hash(),
		"the source and SaveIO-restored runs must reach the identical final hash")

## A save/load taken mid-way through a drop_tool leg's own movement (an
## already-resolved path, no in-flight reroute search) must not lose track of
## it being a drop leg (ADR 013, "Drop-leg identity marker": the marker is
## persisted in the job's blockingJobId field), or a restore could treat the
## in-flight route as the tool-free job's own ordinary route and start work
## at the stockpile cell instead of completing the handover.
func _check_save_io_round_trip_mid_drop_tool_movement_matches_uninterrupted_run() -> void:
	var world := WorldStateType.new(266008)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 4, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 9, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")
	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 9, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var midway := false
	for _i in 60:
		world.tick()
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") == null and String(colonist.get("held_tool", "")) == pick_id \
				and int(colonist["x"]) > 0 and int(colonist["x"]) < 4:
			midway = true
			break
	_expect(midway, "the colonist must be caught mid-movement toward the drop cell (resolved path, not yet arrived)")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop-tool-movement: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-drop-tool-movement: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 after the handover resolves")

	var restored_completed := false
	for _i in 200:
		restored.tick()
		if String(Scenarios.find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
			break
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 after the handover resolves")
	_expect(world.state_hash() == restored.state_hash(),
		"the source and SaveIO-restored runs must reach the identical final hash")
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held",
		"the pick must actually have been dropped (handover completed), not stuck mid-travel forever")

## The same save/load guarantee must also hold while a drop_tool leg's own
## bounded re-route search is still in flight (rerouting != null, no
## resolved path yet) -- _restore_reroutes() (state_codec.gd) must rebuild
## the search's cost callable with the plain passability the live drop leg
## uses (ADR 013, "Drop-leg route restore"). A
## wide-open 21x21 room forces the RNG-free Dijkstra search to expand well
## past its own 64-per-tick budget (a uniform-cost flood fill covers ~2*r^2
## tiles by the time it reaches a target r tiles away) before ever reaching
## the target, even though the target itself sits within TOOL_DROP_RADIUS (a
## short, thin wall forces a small detour around it, not a long walk) -- so
## the resolved walk afterward stays short while the search genuinely spans
## more than one tick.
func _check_save_io_round_trip_mid_drop_tool_route_search_matches_uninterrupted_run() -> void:
	var world := WorldStateType.new(266009)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 21):
		for y in range(0, 21):
			TestAccess.set_tile(world, x, y, WorldStateType.TILE_FLOOR)
	for y in range(11, 15):
		TestAccess.set_tile(world, 10, y, WorldStateType.TILE_ROCK)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 10, "y": 15, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 0, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 10, 10)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")
	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 0, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var mid_search := false
	for _i in 10:
		world.tick()
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null and String(colonist.get("held_tool", "")) == pick_id:
			mid_search = true
			break
	_expect(mid_search, "the colonist's drop-tool re-route search must still be unresolved within a few ticks")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop-tool route search: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-drop-tool route search: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	for _i in 400:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 after the handover resolves")

	var restored_completed := false
	for _i in 400:
		restored.tick()
		if String(Scenarios.find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
			break
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 after the handover resolves")
	_expect(world.state_hash() == restored.state_hash(),
		"the source and SaveIO-restored runs must reach the identical final hash")

## _restore_reroutes() must reconstruct a drop_tool leg's
## in-flight search with the same plain passability the live toil always
## uses, not job.target's own target-tile exception -- proven here by placing
## the job's own impassable target directly on a wall between the holder and
## its chosen stockpile cell, the one geometry where that exception would open
## a "shortcut" a live/direct run could never take (the live search is always
## plain, no exception, regardless of save/load). Compares state_hash() after
## every tick, not merely at completion, so any single diverging tick fails
## immediately. A8 (ADR 054: a target in another region "is refused at once,
## before any search"): the wall stops one tile short of the east edge, so
## the stockpile stays in the holder's region and the plain search is a real,
## multi-tick detour through that gap instead of being refused outright.
func _check_save_io_round_trip_mid_drop_tool_search_impassable_target_between_holder_and_stockpile() -> void:
	var world := WorldStateType.new(266019)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	for x in range(0, 47):
		TestAccess.set_tile(world, x, 6, WorldStateType.TILE_ROCK)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 5, "y": 5, "route": null, "work": null})
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 5, "y": 6, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement on the wall row must be accepted")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 5, "y": 9, "width": 1, "height": 1}).get("ok", false),
		"zone_add south of the wall must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 5, 5)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")
	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 5, "y": 6, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var mid_search := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null and String(colonist.get("held_tool", "")) == pick_id:
			mid_search = true
			break
	_expect(mid_search, "the colonist's drop-tool re-route search toward the stockpile cell beyond the wall must still be unresolved within budget")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop-tool search with an impassable target on the wall: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	var restored_completed := false
	for i in 400:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d): a wrong passability exception here would let the restored search cross the wall the direct run never could" % i)
		if not direct_completed and String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(Scenarios.find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 once the pick is dropped")
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 once the pick is dropped")
	_expect(world.get_tool_item(pick_id).get("location", {}) == {"type": "stockpile", "x": 5, "y": 9},
		"the pick must end on the stockpile cell, reached by the only legitimate crossing (the gap at the east edge), got %s" % [world.get_tool_item(pick_id).get("location", {})])

## Reconstructing the drop leg's identity from reservation state on restore
## is unsound in three cases (docs/decisions/013-tool-toils.md, "Drop-leg
## identity marker"). JobQueue.set_active_item_marker()/
## get_active_item_marker() persist the marker advance() maintains directly
## on the job's own already-round-tripped blockingJobId field, so a restore
## needs no bootstrap step. This covers the first of the three cases: a save
## taken after the requester's job that triggered the drop is cancelled (releasing
## the reservation needs_drop() reads), compared tick by tick against an
## uninterrupted run through to both forage jobs completing.
func _check_save_io_round_trip_after_requester_cancellation_midflight() -> void:
	var world := WorldStateType.new(266031)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 10, 9, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	_expect(Scenarios.command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(Scenarios.command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var forage_a_result := Scenarios.command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a_result.get("ok", false), "forage A submission must be accepted")
	var forage_a_id := String(forage_a_result.get("job_id", ""))

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget")

	# ADR 024 slowed real needs decay to points-per-day: colonist_0
	# going idle after forage_a completes no longer starves fast enough, on
	# its own, to earn a second (eat_food) job dispatch before colonist_1's
	# fetch_tool toil simply walks over and takes the unreserved held pick
	# directly -- the scenario this check actually needs is "colonist_0 gets
	# dispatched a new job while holding a foreign-reserved tool", not real
	# hunger timing, so food is pinned low here (mirroring _isolate_need()-
	# style direct need mutation elsewhere in this suite) to make NeedGiver
	# assign colonist_0 the eat_food job for the ground berries forage_a just
	# produced at (1, 0) the instant it goes idle, well before colonist_1
	# physically arrives. forage_b (below) is deliberately not submitted this
	# early -- see its own comment -- so this cannot reuse that job instead.
	for i in TestAccess.colonists(world).size():
		if String(TestAccess.colonists(world)[i]["id"]) == "colonist_0":
			TestAccess.colonists(world)[i]["needs"]["food"] = 20

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var dropping := false
	for _i in 200:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == pick_id and colonist_0.get("route") != null \
				and int(colonist_0["x"]) > 0 and int(colonist_0["x"]) < 5:
			dropping = true
			break
	_expect(dropping, "colonist_0 must be caught mid-walk toward the stockpile cell before cancellation")

	# forage_b is only submitted now, once colonist_1 is already committed to
	# dig_1's own tool reservation: colonist_1's labourTable must stay a
	# SaveIO-valid, full 7-kind table (unlike its plain-live-state-only
	# sibling test above, this one takes a real SaveIO round trip, which
	# rejects any non-canonical key such as a "forage" one used purely to
	# keep a live colonist out of the forage pool) -- sequencing forage_b's
	# submission after colonist_1 already committed keeps it out of
	# contention without relying on a labour toggle forage does not have.
	var forage_b_result := Scenarios.command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_b_result.get("ok", false), "forage B submission must be accepted")
	var forage_b_id := String(forage_b_result.get("job_id", ""))

	_expect(Scenarios.command(world, "cancel_dig_1", "cancel_job", {"job_id": dig_id}).get("ok", false),
		"cancelling dig_1 mid-drop-walk must be accepted")
	_expect(world.get_tool_item_reservation(pick_id) == "", "cancelling dig_1 must release its reservation on the pick")

	# A5 (ADR 053): a job already completed when the save is taken is not saved, so the
	# restored run must not know it at all; the others must complete there as before.
	var completed_before_save: Dictionary = {}
	for job_id in [forage_a_id, forage_b_id]:
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed_before_save[job_id] = true
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken after the requester's job is cancelled mid-drop: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(Scenarios.find_job(world, forage_a_id).get("status", "")) == "completed" \
				and String(Scenarios.find_job(world, forage_b_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and _restored_job_done(restored, forage_a_id, completed_before_save) \
				and _restored_job_done(restored, forage_b_id, completed_before_save):
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run must still complete both forage jobs after the cancellation")
	_expect(restored_completed, "the SaveIO-restored run must also complete both forage jobs, never abandoning or misreading the drop")

## Second of the three marker-restore cases: a save taken inside the window
## between a fetch_tool reservation being released (the holder's own
## drop_tool leg completing) and the requester's own next advance() re-
## reserving it, while the requester also physically holds a second,
## unrelated tool that is itself foreign-reserved -- exactly the state in
## which a restore-time reconstruction (needs_drop() true for the unrelated
## tool) would permanently mark a genuine fetch leg as "dropping". With no
## restore-time reconstruction (the marker is only
## ever set by ToolDropToil.advance() actually starting a drop, and the
## requester never does here -- it only fetches), there is nothing to
## misseed.
##
## The save must land inside the gap, not before the holder's drop completes
## (a save that early would restore correctly even with a reconstruction
## heuristic, so it would not exercise this case). The gap is real but
## brief: WorldState._advance_colonists() advances every colonist within one
## external tick() call, sorted by id (not append order), so whichever of the
## two colonists' ids sorts last runs its own turn after
## the other's within the same tick. Naming the requester "colonist_0" (sorts
## first) and the holder "colonist_1" (sorts second) makes the holder's drop
## -- and the reservation release it causes -- happen strictly after the
## requester's own turn each tick, so the release is invisible to the
## requester until its next turn, at the start of the following external
## tick() call. Saving immediately after the tick() call whose holder turn
## performed the drop, before calling tick() again, therefore captures a
## real, observable gap: the axe genuinely unreserved, the requester's own
## fetch route still in flight, and its own unrelated leftover pick still
## foreign-reserved -- proven directly below before the save is taken.
func _check_save_io_round_trip_in_reservation_release_gap_with_unrelated_foreign_reserved_held_tool() -> void:
	var world := WorldStateType.new(266032)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 25, 0, WorldStateType.TILE_TREE)
	TestAccess.colonists(world).clear()
	var labour_table_all_but_chop := {"mine": 3, "chop": 0, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	var labour_table_all_3 := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	# colonist_0 is the requester (fetches the axe via chop_1) so that its id
	# sorts, and therefore advances, before colonist_1, the holder, every tick --
	# see the doc comment above for why this ordering is what makes the
	# release gap actually observable across a tick() boundary.
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_3})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_but_chop})
	var axe_id := world.spawn_ground_tool_item("axe", 20, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_1"), "moving the axe into colonist_1's hand must succeed")
	var leftover_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(leftover_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 15, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var submitted := Scenarios.command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if world.get_tool_item_reservation(axe_id) == job_id and colonist_0.get("route") != null and int(colonist_0["x"]) > 1:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward idle colonist_1 within budget")

	_expect(world.reserve_tool_item(leftover_id, "foreign_job"),
		"reserving colonist_0's own leftover pick for a foreign job mid-fetch-travel must succeed")
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 20, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(Scenarios.command(world, "forage_0", "forage", {"x": 20, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	# Advance until colonist_1's own drop_tool leg has actually completed (the
	# axe physically leaves its hand and its reservation is genuinely gone) --
	# not merely started -- while colonist_0's own fetch route is still
	# present. Because colonist_0 (the requester) advances before colonist_1
	# (the holder) every tick, the tick whose holder turn performs the drop is
	# already the gap: colonist_0's own turn that same tick ran before the
	# release, so it has not re-scanned yet, and won't until its next turn.
	var in_gap := false
	for _i in 60:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		var axe := world.get_tool_item(axe_id)
		if String(axe.get("location", {}).get("type", "")) != "held" \
				and colonist_0.get("route") != null \
				and world.get_tool_item_reservation(axe_id) == "":
			in_gap = true
			break
	_expect(in_gap, "the axe must be dropped, releasing its reservation, while colonist_0's own fetch route is still in flight, within budget")

	var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
	_expect(colonist_0.get("route") != null, "colonist_0's own fetch route must still exist at the moment of save")
	_expect(world.get_tool_item_reservation(axe_id) == "",
		"the axe's reservation must be genuinely absent at the moment of save -- proving the save lands inside the gap, not before it")
	_expect(world.get_tool_item_reservation(leftover_id) == "foreign_job",
		"colonist_0's own unrelated leftover pick must still be foreign-reserved at the moment of save")
	_expect(String(colonist_0.get("held_tool", "")) == leftover_id,
		"colonist_0 must still physically hold its own unrelated leftover pick at the moment of save")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken inside the reservation-release gap: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(Scenarios.find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "chop_1 must still complete in the uninterrupted run")
	_expect(restored_completed, "chop_1 must still complete in the SaveIO-restored run too, never misread as a drop leg for colonist_1's own leftover pick")

## Third of the three marker-restore cases, and the widest: a save taken
## during an ordinary go_to leg (no fetch_tool, no drop_tool -- forage's own
## plain travel) after the colonist's held tool happens to become foreign-
## reserved mid-leg. Live behaviour never reclassifies an in-flight leg this
## way (drop_tool insertion only ever happens at a toil boundary), and with no
## restore-time heuristic left to misfire on needs_drop() alone, neither does
## a restore.
func _check_save_io_round_trip_ordinary_route_after_held_tool_foreign_reserved_midflight() -> void:
	var world := WorldStateType.new(266033)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 20, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")

	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 20, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var midway := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		if colonist.get("route") != null and int(colonist["x"]) > 2:
			midway = true
			break
	_expect(midway, "colonist_0 must be caught mid-travel toward the bush before the foreign reservation lands")

	_expect(world.reserve_tool_item(pick_id, "foreign_job"),
		"reserving the held pick for a foreign job mid-travel must succeed")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-ordinary-route after the held tool becomes foreign-reserved: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	TestAccess.toils(restored).clear_trace()
	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(Scenarios.find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run must complete forage_1 without ever diverting to drop_tool")
	_expect(restored_completed, "the SaveIO-restored run must also complete forage_1 without ever diverting to drop_tool")
	for entry in TestAccess.toils(restored).trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"the restored run must never misread the already-in-flight ordinary route as a drop leg: %s" % [TestAccess.toils(restored).trace])

## A save/load taken mid-way through the same drop_tool leg
## as above (an already-resolved path toward the stockpile cell, colonist
## still walking) must round-trip the haul job's own cargo identity, its
## own item:/cell: reservations, and reach completion identically in both the
## direct and the SaveIO-restored run -- proving the blockingJobId-based
## marker (not itemId) survives a real file round trip without corrupting
## haul state.
func _check_save_io_round_trip_mid_drop_during_haul_job_preserves_cargo_and_completes() -> void:
	var world := WorldStateType.new(266042)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(axe_id, "foreign_job"),
		"reserving colonist_0's held axe for a foreign job must succeed, before any haul job even exists")
	# Three cells (3,0)/(4,0)/(5,0), all within TOOL_DROP_RADIUS of colonist_0's
	# own start position but far enough to require real travel: the haul
	# job's own destination reservation takes one of them at activation
	# (before the colonist ever moves), leaving at least two still free for
	# the axe's own, independent drop-cell search moments later.
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 3, "y": 0, "width": 3, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	TestAccess.item_table(world).items["item_1"] = {"id": "item_1", "x": 15, "y": 0, "kind": "wood", "count": 1}
	TestAccess.item_table(world).next_item_id = 2

	var haul_job_id := ""
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "haul" and String(job.get("item_id", "")) == "item_1":
				haul_job_id = String(job["id"])
		if not haul_job_id.is_empty():
			break
	_expect(not haul_job_id.is_empty(), "a haul job for item_1 must be auto-submitted and activated within budget")
	if haul_job_id.is_empty():
		return

	var midway := false
	for _i in 30:
		world.tick()
		var colonist := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist.get("route") != null and String(colonist.get("held_tool", "")) == axe_id:
			midway = true
			break
	_expect(midway, "colonist_0 must be caught mid-movement toward the axe's own drop cell (still holding it, still routing), within budget")

	var mid_job := Scenarios.find_job(world, haul_job_id)
	_expect(String(mid_job.get("item_id", "")) == "item_1",
		"the haul job's own itemId must still name its cargo (item_1) while the axe's own drop leg is in flight")
	_expect(String(mid_job.get("blocking_job_id", "")) == axe_id,
		"the haul job's own blockingJobId must carry the in-flight drop-leg marker (the axe's id) while dropping")
	var cell: Vector2i = mid_job["cell"]
	_expect(TestAccess.scheduler(world).queue.get_reservation_table().owner("item:item_1") == haul_job_id,
		"the haul job's own cargo reservation must still be intact mid-drop")
	_expect(TestAccess.scheduler(world).queue.get_reservation_table().owner("cell:%d,%d" % [cell.x, cell.y]) == haul_job_id,
		"the haul job's own destination-cell reservation must still be intact mid-drop")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-drop during a haul job: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")
	_expect(String(Scenarios.find_job(restored, haul_job_id).get("item_id", "")) == "item_1",
		"the restored haul job's own itemId must still name its cargo (item_1) right after restore")
	_expect(TestAccess.scheduler(restored).queue.get_reservation_table().owner("item:item_1") == haul_job_id,
		"the restored haul job's own cargo reservation must still be intact right after restore")

	var direct_completed := false
	var restored_completed := false
	for i in 300:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		if not direct_completed and String(Scenarios.find_job(world, haul_job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(Scenarios.find_job(restored, haul_job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(direct_completed, "the uninterrupted run's haul job must still complete")
	_expect(restored_completed, "the SaveIO-restored run's haul job must also still complete, cargo identity intact throughout")
	var direct_item: Dictionary = TestAccess.item_table(world).items.get("item_1", {})
	var restored_item: Dictionary = TestAccess.item_table(restored).items.get("item_1", {})
	_expect(direct_item.get("x") == restored_item.get("x") and direct_item.get("y") == restored_item.get("y"),
		"item_1 must end up at the same final cell in both runs, got %s vs %s" % [direct_item, restored_item])
