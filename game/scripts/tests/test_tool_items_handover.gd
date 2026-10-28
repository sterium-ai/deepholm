extends "res://scripts/tests/support/tool_items_base.gd"

## test_tool_items_handover checks; shared helpers and the file's full description are in support/tool_items_base.gd.

func _init() -> void:
	_check_foreign_reservation_triggers_drop_tool_handover()
	_check_drop_tool_prefers_nearby_stockpile_cell()
	_check_requester_waits_for_real_handover_then_completes()
	_check_drop_tool_revalidates_destination_at_arrival()
	_check_adjacent_busy_holder_does_not_steal_tool_same_tick()
	_check_fetch_tool_retargets_when_holder_drops_tool_elsewhere()
	_check_ordinary_route_not_misclassified_as_drop_when_reservation_appears_midflight()
	_check_fetch_route_not_misclassified_as_drop_when_other_reservation_appears()
	_check_requester_cancellation_midflight_still_completes_drop_correctly()
	_check_drop_continues_when_holders_own_next_job_needs_a_different_tool()
	_check_fetch_route_not_misclassified_as_drop_when_leftover_tool_also_foreign_reserved()
	_check_drop_cell_adjacent_to_impassable_ordinary_target_uses_nearest_stockpile_cell()
	_check_drop_cell_exactly_on_passable_ordinary_target_is_used()
	_check_drop_cell_near_passable_ordinary_target_uses_nearest_stockpile_cell()
	_check_fetch_route_survives_drifting_handover_holder_while_requester_holds_leftover()
	_check_drop_tool_skips_cell_already_occupied_by_another_tool()
	_check_drop_tool_falls_back_to_ground_when_destination_zone_removed_midflight()
	_check_drop_tool_during_haul_job_preserves_cargo_identity_in_place()
	_check_drop_tool_during_haul_job_preserves_cargo_identity_via_stockpile()
	_check_destroyed_foreign_held_tool_while_waiting_reconciles_holder()
	_check_destroyed_foreign_held_tool_mid_drop_reconciles_holder_route()

	if _failed:
		quit(1)
		return
	print("test_tool_items_handover: PASS")
	quit(0)

## A colonist holding a tool that a foreign job has reserved
## (held by another colonist but unreserved at the moment fetch_tool
## claimed it; ADR 013, "Holder side") must run drop_tool as the
## first toil of its own next dispatched job, before that job's own go_to/work,
## and must no longer hold the tool once dropped.
func _check_foreign_reservation_triggers_drop_tool_handover() -> void:
	var world := WorldStateType.new(266002)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"),
		"reserving the held pick for a different (foreign) job must succeed")

	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))
	TestAccess.toils(world).clear_trace()

	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete once it drops the foreign-reserved pick")

	var drop_index := -1
	var go_to_index := -1
	for i in TestAccess.toils(world).trace.size():
		var entry: Dictionary = TestAccess.toils(world).trace[i]
		if drop_index == -1 and String(entry.get("toil", "")) == "drop_tool" and String(entry.get("phase", "")) == "complete":
			drop_index = i
		if go_to_index == -1 and String(entry.get("toil", "")) == "go_to" and String(entry.get("phase", "")) == "enter":
			go_to_index = i
	_expect(drop_index != -1, "colonist_0 must run a drop_tool toil before its own forage job: %s" % [TestAccess.toils(world).trace])
	_expect(go_to_index != -1 and drop_index < go_to_index,
		"drop_tool must complete before the forage job's own go_to toil begins: %s" % [TestAccess.toils(world).trace])

	_expect(String(Scenarios.colonist_by_id(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0 must no longer hold the pick once it has been dropped for the handover")
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) in ["ground", "stockpile"],
		"the dropped pick must rest on the ground or a stockpile cell, not stay held")

## When a free stockpile cell lies within ToolDropToil.TOOL_DROP_RADIUS
## of the holder, drop_tool must walk there and drop the tool on that cell
## instead of dropping in place.
func _check_drop_tool_prefers_nearby_stockpile_cell() -> void:
	var world := WorldStateType.new(266003)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add near colonist_0 must be accepted")
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 5, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 5, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 2 and location.get("y") == 0,
		"a free stockpile cell within reach must be preferred over dropping the pick in place, got %s" % location)

## Requester side of the handover: ToolFetchToil must not take the tool
## straight out of a busy holder's hand instead of waiting for the holder's
## own drop_tool toil. Two real
## colonists, two real jobs throughout: colonist_0 holds a leftover pick
## while busy foraging; colonist_1's real dig job reserves that same pick
## while colonist_0 is still busy, and must wait (reason
## waiting_for_tool_handover, itemId naming the pick, blockingJobId naming
## colonist_0's own currently assigned job) until colonist_0's own next
## dispatched job (a second forage order) runs drop_tool and actually
## releases it -- only then does colonist_1 pick it up and complete.
func _check_requester_waits_for_real_handover_then_completes() -> void:
	var world := WorldStateType.new(266010)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 10, 9, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")

	_expect(Scenarios.command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(Scenarios.command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	_expect(Scenarios.command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1}).get("ok", false),
		"forage A submission must be accepted")
	_expect(Scenarios.command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1}).get("ok", false),
		"forage B submission must be accepted")

	# colonist_0 must already be genuinely busy on forage_a before the dig
	# order (and its fetch_tool reservation) ever exists -- otherwise it would
	# still be transiently unassigned (the ordinary one-tick scheduler lag)
	# when the reservation lands, and the handover wait's own "idle holder"
	# fallback (waiting_for_handover()) would let colonist_1 steal the pick
	# directly instead of exercising the wait this test is about.
	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget, before the dig order below exists")

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var waiting_seen := false
	var completed := false
	for _i in 400:
		world.tick()
		var dig_job := Scenarios.find_job(world, dig_id)
		if String(dig_job.get("reason", "")) == "waiting_for_tool_handover":
			waiting_seen = true
			_expect(String(dig_job.get("item_id", "")) == pick_id,
				"waiting_for_tool_handover's itemId must name the reserved pick, got '%s'" % dig_job.get("item_id"))
			var blocking_job_id := String(dig_job.get("blocking_job_id", ""))
			_expect(not blocking_job_id.is_empty() and _find_job_colonist_id(world, blocking_job_id) == "colonist_0",
				"waiting_for_tool_handover's blockingJobId must name colonist_0's own currently assigned job, got '%s'" % blocking_job_id)
			_expect(String(Scenarios.colonist_by_id(world, "colonist_1").get("held_tool", "")) == "",
				"colonist_1 must not hold the pick while genuinely waiting for the handover")
		if String(dig_job.get("status", "")) == "completed":
			completed = true
			break
	_expect(waiting_seen, "the dig job must expose reason waiting_for_tool_handover while colonist_0 still holds the pick")
	_expect(completed, "the dig job must complete once colonist_0's own next dispatched job drops the pick")
	_expect(String(Scenarios.colonist_by_id(world, "colonist_1").get("held_tool", "")) == pick_id,
		"colonist_1 must end up holding the pick it waited for")

	var drop_seen := false
	for entry in TestAccess.toils(world).trace:
		if String(entry.get("toil", "")) == "drop_tool" and String(entry.get("phase", "")) == "complete":
			drop_seen = true
	_expect(drop_seen, "colonist_0 must have run a drop_tool toil to release the handover: %s" % [TestAccess.toils(world).trace])

## drop_tool's own destination must stay fixed for the whole leg (no
## per-tick recomputation) and must be revalidated at
## arrival, not assumed -- a different job claiming the originally-chosen
## stockpile cell mid-travel must not silently retarget the colonist to a
## closer/farther alternative cell while it is still walking toward the old
## one; it must instead notice at arrival that its own destination is no
## longer free and drop on the ground there instead.
func _check_drop_tool_revalidates_destination_at_arrival() -> void:
	var world := WorldStateType.new(266007)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 4, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 9, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 9, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	# One tick in, drop_tool has already chosen (2, 0) -- the nearest free
	# cell -- and started walking there (distance 2 tiles, 4 ticks/tile: still
	# far from arrival). Claim that exact cell from a different job now,
	# leaving (5, 0) -- also in the zone, also within TOOL_DROP_RADIUS -- free.
	world.tick()
	var colonist := world.get_colonists()[0]
	_expect(colonist.get("route") != null and int(colonist["x"]) == 0 and int(colonist["y"]) == 0,
		"the colonist must still be travelling toward the drop cell, not yet arrived")
	TestAccess.scheduler(world).queue.get_reservation_table().acquire("cell:2,0", "blocker_job")
	_expect(not world.is_cell_free(2, 0), "claiming cell (2, 0) from a different job must make it no longer free")
	_expect(world.is_cell_free(5, 0), "cell (5, 0) must remain free as the untouched alternative")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "the pick must be dropped within the tick budget despite the contested cell")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "ground" and location.get("x") == 2 and location.get("y") == 0,
		"the colonist must still walk all the way to (2, 0) -- its own already-chosen destination -- and only then fall back to dropping on the ground there, got %s" % location)

	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete despite the drop falling back to the ground")

## A requester whose fetch_tool candidate is reserved from a
## busy foreign holder it happens to already stand adjacent to must not steal
## it the very same tick the reservation lands -- advance_go_to()'s own
## path.size()<=1 shortcut would otherwise call on_arrive (pickup) inline,
## inside the same ToolFetchToil.advance() call that just reserved it, before
## ToilExecutor's own waiting_for_handover() gate ever runs again.
func _check_adjacent_busy_holder_does_not_steal_tool_same_tick() -> void:
	var world := WorldStateType.new(266011)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 10, 9, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 20, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(Scenarios.command(world, "forage_a", "forage", {"x": 20, "y": 0, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget, before the dig order below exists")

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var reserved_tick_seen := false
	for _i in 10:
		world.tick()
		if world.get_tool_item_reservation(pick_id) == dig_id:
			reserved_tick_seen = true
			_expect(String(Scenarios.colonist_by_id(world, "colonist_1").get("held_tool", "")) == "",
				"colonist_1 must not hold the pick the same tick its fetch_tool reserves it from a busy holder")
			_expect(String(world.get_tool_item(pick_id).get("location", {}).get("colonist_id", "")) == "colonist_0",
				"the pick must still be physically held by colonist_0 the same tick it gets reserved by dig_1")
			break
	_expect(reserved_tick_seen, "dig_1's fetch_tool must reserve the pick within budget")

	var completed := false
	for _i in 400:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "dig_1 must still complete once colonist_0's own next dispatched job drops the pick")
	_expect(String(Scenarios.colonist_by_id(world, "colonist_1").get("held_tool", "")) == pick_id,
		"colonist_1 must end up holding the pick it waited for")

## A fetch_tool leg that legitimately started travelling
## toward an idle holder's tool must correctly retarget, not fail, once that
## holder later becomes busy and its own drop_tool toil relocates the tool to
## a stockpile cell away from where the fetch route was already heading --
## advance_go_to() never re-targets an already-resolved route on its own, so
## without ToolFetchToil.advance() discarding the stale route, the requester
## would walk all the way to the tool's old position, find nothing there, and
## back off with blocked_no_tool instead of completing.
func _check_fetch_tool_retargets_when_holder_drops_tool_elsewhere() -> void:
	var world := WorldStateType.new(266012)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 25, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 25, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_1 := Scenarios.colonist_by_id(world, "colonist_1")
		if world.get_tool_item_reservation(pick_id) == dig_id and colonist_1.get("route") != null:
			travelling = true
			break
	_expect(travelling, "dig_1's fetch_tool must reserve the pick and start travelling toward idle colonist_0 within budget")
	_expect(Scenarios.colonist_by_id(world, "colonist_0").get("route") == null,
		"colonist_0 must still be idle (a legitimate direct-pickup target) at the moment the reservation lands")

	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 0, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(Scenarios.command(world, "forage_1", "forage", {"x": 0, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must become busy on forage_1 within budget")

	var backed_off := false
	var completed := false
	for _i in 400:
		world.tick()
		var job := Scenarios.find_job(world, dig_id)
		if String(job.get("status", "")) == "queued":
			backed_off = true
		if String(job.get("status", "")) == "completed":
			completed = true
			break
	_expect(not backed_off, "dig_1 must retarget toward the pick's new stockpile location instead of failing blocked_no_tool")
	_expect(completed, "dig_1 must complete once fetch_tool retargets toward the relocated pick")

## is_dropping() must never reinterpret a job's own ordinary
## go_to leg as a drop leg just because needs_drop() also happens to turn true
## mid-flight -- an exact-equality comparison against the (impassable,
## therefore one-tile-trimmed) ordinary target would misclassify every such
## route the instant a foreign job reserved the held tool, diverting it to a
## stockpile cell instead of letting it reach its own job's target.
func _check_ordinary_route_not_misclassified_as_drop_when_reservation_appears_midflight() -> void:
	var world := WorldStateType.new(266013)
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

	TestAccess.toils(world).clear_trace()
	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must complete without being diverted to drop_tool mid-travel")
	for entry in TestAccess.toils(world).trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"an in-flight ordinary route must never run a drop_tool toil while it is still heading to its own job's target: %s" % [TestAccess.toils(world).trace])

## is_dropping() must also leave an in-flight fetch_tool leg
## alone when a different held tool becomes foreign-reserved mid-travel (a
## colonist can hold one leftover tool while fetching an unrelated new one) --
## the route's own destination coincides with ToolFetchToil's own current
## target, not a drop cell, so it must never be reinterpreted as a drop leg.
func _check_fetch_route_not_misclassified_as_drop_when_other_reservation_appears() -> void:
	var world := WorldStateType.new(266014)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 21):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 20, 0, WorldStateType.TILE_TREE)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the leftover pick into colonist_0's hand must succeed")
	world.spawn_ground_tool_item("axe", 20, 0)

	var submitted := Scenarios.command(world, "chop_1", "chop", {"x": 20, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var midway := false
	for _i in 20:
		world.tick()
		var colonist := world.get_colonists()[0]
		if colonist.get("route") != null and int(colonist["x"]) > 2:
			midway = true
			break
	_expect(midway, "colonist_0 must be caught mid-travel toward the axe before the foreign reservation lands")

	_expect(world.reserve_tool_item(pick_id, "foreign_job"),
		"reserving the leftover pick for a foreign job mid-fetch-travel must succeed")

	TestAccess.toils(world).clear_trace()
	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own chop job must still complete, fetching the axe without a spurious drop_tool detour")
	for entry in TestAccess.toils(world).trace:
		_expect(String(entry.get("toil", "")) != "drop_tool",
			"an in-flight fetch_tool leg must never run a drop_tool toil for an unrelated held tool: %s" % [TestAccess.toils(world).trace])
	_expect(String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) == "ground",
		"the leftover pick must end up on the ground (fetch_tool's own minimal drop-at-arrival), not vanish")

## Cancelling the requester's job while the holder's drop_tool leg is still
## mid-walk must not let the same in-flight route be reinterpreted as the
## holder's own ordinary leg once the reservation disappears -- is_dropping()
## must keep recognizing it as a drop in progress from the persisted marker,
## colonist.held_tool and route (never from needs_drop() remaining true),
## completing the drop and then correctly starting the
## holder's own next toil, never mistaking the stockpile arrival for the
## holder's own job target.
func _check_requester_cancellation_midflight_still_completes_drop_correctly() -> void:
	var world := WorldStateType.new(266015)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 10, 9, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
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
	var forage_b_result := Scenarios.command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(forage_b_result.get("ok", false), "forage B submission must be accepted")
	var forage_b_id := String(forage_b_result.get("job_id", ""))

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a within budget")

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

	_expect(Scenarios.command(world, "cancel_dig_1", "cancel_job", {"job_id": dig_id}).get("ok", false),
		"cancelling dig_1 mid-drop-walk must be accepted")
	_expect(world.get_tool_item_reservation(pick_id) == "", "cancelling dig_1 must release its reservation on the pick")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "colonist_0 must still complete the drop after the requester's own job is cancelled mid-walk")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 5 and location.get("y") == 0,
		"colonist_0 must finish walking to its own already-chosen stockpile cell, not abandon the drop mid-way, got %s" % location)

	var both_completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, forage_a_id).get("status", "")) == "completed" \
				and String(Scenarios.find_job(world, forage_b_id).get("status", "")) == "completed":
			both_completed = true
			break
	_expect(both_completed, "colonist_0 must still complete both of its own forage jobs, never mistaking the stockpile arrival for its own job target")

## Unlike the cancellation test just above (tool-free forage),
## the holder's own next dispatched job may itself need a different tool than
## the one it is dropping. The instant the foreign job that triggered the drop
## is cancelled, needs_drop() turns false while ToolFetchToil.needs() turns
## true (axe != pick) -- a reservation-based is_dropping() would read that
## combination as "not dropping, must be fetching" and abandon the in-flight
## walk to the stockpile cell partway there. The persisted drop-leg marker
## must keep recognizing the same in-flight leg regardless.
func _check_drop_continues_when_holders_own_next_job_needs_a_different_tool() -> void:
	var world := WorldStateType.new(266029)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 15, 0, WorldStateType.TILE_SOIL)
	TestAccess.set_tile(world, 25, 0, WorldStateType.TILE_TREE)
	TestAccess.colonists(world).clear()
	var labour_table_all_but_mine := {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	var labour_table_all_but_chop := {"mine": 3, "chop": 0, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_but_mine})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": labour_table_all_but_chop})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	world.spawn_ground_tool_item("axe", 20, 0)

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 15, "y": 0, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var reserved := false
	for _i in 20:
		world.tick()
		if world.get_tool_item_reservation(pick_id) == dig_id:
			reserved = true
			break
	_expect(reserved, "dig_1 must reserve colonist_0's held pick within budget")

	var chop_result := Scenarios.command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(chop_result.get("ok", false), "chop submission must be accepted")
	var chop_id := String(chop_result.get("job_id", ""))

	var dropping := false
	for _i in 30:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == pick_id and colonist_0.get("route") != null \
				and int(colonist_0["x"]) > 0 and int(colonist_0["x"]) < 5:
			dropping = true
			break
	_expect(dropping, "colonist_0 must be caught mid-walk toward the stockpile cell, dropping the pick, before dig_1 is cancelled")

	_expect(Scenarios.command(world, "cancel_dig_1", "cancel_job", {"job_id": dig_id}).get("ok", false),
		"cancelling dig_1 mid-drop-walk must be accepted")
	_expect(world.get_tool_item_reservation(pick_id) == "", "cancelling dig_1 must release its reservation on the pick")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "colonist_0 must still complete the drop after dig_1 is cancelled mid-walk, even though its own next job needs a different tool")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 5 and location.get("y") == 0,
		"colonist_0 must finish walking to its own already-chosen stockpile cell instead of abandoning it for chop_1's own axe fetch, got %s" % location)

	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, chop_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0 must still complete chop_1, fetching the axe after finishing the drop")

## The requester may also hold a leftover tool that becomes
## foreign-reserved (needs_drop() true) while its own fetch_tool reservation
## on a different tool is momentarily released by the holder's own drop --
## unlike _check_fetch_route_survives_drifting_handover_holder_while_requester_holds_leftover()'s
## unreserved leftover, needs_drop() is genuinely true here, and a
## position-based is_dropping() would misread the frozen fetch route as the
## requester's own drop leg for the wrong tool.
## Also proves a SaveIO round trip taken before the holder's drop resolves the
## gap reaches the identical state_hash() tick by tick through it as an
## uninterrupted run.
func _check_fetch_route_not_misclassified_as_drop_when_leftover_tool_also_foreign_reserved() -> void:
	var world := WorldStateType.new(266030)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 25, 0, WorldStateType.TILE_TREE)
	TestAccess.colonists(world).clear()
	var labour_table_all_but_chop := {"mine": 3, "chop": 0, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	var labour_table_all_3 := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_but_chop})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": labour_table_all_3})
	var axe_id := world.spawn_ground_tool_item("axe", 20, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	var leftover_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(leftover_id, "colonist_1"), "moving the leftover pick into colonist_1's hand must succeed")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 15, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var submitted := Scenarios.command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_1 := Scenarios.colonist_by_id(world, "colonist_1")
		if world.get_tool_item_reservation(axe_id) == job_id and colonist_1.get("route") != null and int(colonist_1["x"]) > 1:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward idle colonist_0 within budget")

	_expect(world.reserve_tool_item(leftover_id, "foreign_job"),
		"reserving colonist_1's own leftover pick for a foreign job mid-fetch-travel must succeed")

	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 20, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(Scenarios.command(world, "forage_0", "forage", {"x": 20, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var drifting := false
	for _i in 30:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == axe_id and colonist_0.get("route") != null:
			drifting = true
			break
	_expect(drifting, "colonist_0 must start walking its own drop_tool leg while still physically holding the axe within budget")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, world.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken while the requester's own leftover tool is also foreign-reserved: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back this save: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return
	var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == world.state_hash(), "restore must match the source's hash immediately, before any further ticks")

	var pick_ever_left_colonist_1 := false
	var direct_completed := false
	var restored_completed := false
	for i in 400:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(),
			"the source and SaveIO-restored runs must stay identical tick by tick (tick %d)" % i)
		var colonist_1 := Scenarios.colonist_by_id(world, "colonist_1")
		var held := String(colonist_1.get("held_tool", ""))
		if held != leftover_id and held != axe_id:
			pick_ever_left_colonist_1 = true
		if not direct_completed and String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
		if not restored_completed and String(Scenarios.find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
		if direct_completed and restored_completed:
			break
	_expect(not pick_ever_left_colonist_1,
		"colonist_1 must hold either its own leftover pick or the freshly fetched axe at every tick, never neither -- a misclassified drop leg would empty its hands early")
	_expect(direct_completed, "chop_1 must still complete in the uninterrupted run once colonist_0 finishes relocating the axe")
	_expect(restored_completed, "chop_1 must still complete in the SaveIO-restored run too")

## _find_drop_cell() must not exclude cells reachable-adjacent to an
## impassable ordinary target (a stockpile zone overlapping the reach of
## forage's own bush; objects.json's berry_bush is never itself walkable):
## is_dropping() does not identify a leg from target position at all (it
## reads the persisted drop-leg marker -- see tool_drop_toil.gd's doc
## comment), so such a cell is a valid, free stockpile cell. The bush tile itself
## is still naturally excluded by _cell_still_free()'s own passability check,
## not by any special-cased "avoid" exclusion, so the nearest remaining free
## cell in the zone must be used rather than falling back to the ground.
func _check_drop_cell_adjacent_to_impassable_ordinary_target_uses_nearest_stockpile_cell() -> void:
	var world := WorldStateType.new(266016)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 3, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 3, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must complete")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 2 and location.get("y") == 0,
		"the nearest free stockpile cell adjacent to the impassable bush must be used, not discarded for a ground fallback, got %s" % location)

## With leg identification no longer based on target position
## at all, a drop destination coinciding exactly with the job's own passable
## ordinary target is not ambiguous with that job's own ordinary/fetch_tool
## leg (they are told apart purely by the persisted drop-leg marker) and must
## be used like any other qualifying free
## stockpile cell -- the zone here contains only that one cell, so there is no
## nearer alternative to prefer.
func _check_drop_cell_exactly_on_passable_ordinary_target_is_used() -> void:
	var world := WorldStateType.new(266028)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 3, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 3, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add exactly on the till target must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := Scenarios.command(world, "till_1", "till", {"x": 3, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "till submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own till job must complete despite dropping exactly on its own passable target")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 3 and location.get("y") == 0,
		"the drop destination coinciding exactly with the passable till target must be used directly, got %s" % location)

## A passable ordinary target (till's own soil target, tiles.json's "soil" is
## walkable -- till, unlike dig, declares no needs_tool at all, so the held
## pick's own foreign reservation below can never block this job's own
## activation-time tool-availability gate the way it would for a pick-needing
## job kind). The zone here spans the target's immediate neighbours on both
## sides; _find_drop_cell() does not exclude the exact target tile (see _check_drop_cell_exactly_on_passable_ordinary_target_is_used()
## below for that case directly), but the nearest of the two neighbours here
## is still strictly closer to the colonist than the target tile itself, so
## the nearest-cell tie-break must still choose one of them, not the target.
func _check_drop_cell_near_passable_ordinary_target_uses_nearest_stockpile_cell() -> void:
	var world := WorldStateType.new(266024)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 3, 0, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 3, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := Scenarios.command(world, "till_1", "till", {"x": 3, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "till submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own till job must complete despite dropping right next to its own passable target")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 2 and location.get("y") == 0,
		"the nearest free stockpile cell adjacent to the passable till target must be used, not discarded or a farther one chosen, got %s" % location)

## A busy foreign holder's own drop_tool leg physically walks
## while still holding the requester's reserved tool -- ToolMatchingType.
## item_target() reports a "held" item's location as the holder's current
## position, so it moves every tick the holder is mid-walk, drifting
## ToolFetchToil.current_target() away from the requester's already-in-flight
## route (frozen by design once reserved, see tool_fetch_toil.gd's own
## "freshly_reserved" gate) until the holder finally arrives and actually
## drops it. The requester also holds an unrelated leftover tool throughout,
## so is_dropping()'s entry gate stays active the whole time this drift is
## happening, and must never misclassify the frozen route as a drop leg --
## proven here by asserting the requester's own leftover pick is only ever
## dropped in the single correct place (ToolFetchToil._arrive()'s own swap
## for the axe once it genuinely arrives), never mid-travel.
func _check_fetch_route_survives_drifting_handover_holder_while_requester_holds_leftover() -> void:
	var world := WorldStateType.new(266023)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 25, 0, WorldStateType.TILE_TREE)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null,
		"labourTable": {"chop": 0}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var axe_id := world.spawn_ground_tool_item("axe", 20, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	var leftover_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(leftover_id, "colonist_1"), "moving the leftover pick into colonist_1's hand must succeed")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 15, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")

	var submitted := Scenarios.command(world, "chop_1", "chop", {"x": 25, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "chop submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var travelling := false
	for _i in 20:
		world.tick()
		var colonist_1 := Scenarios.colonist_by_id(world, "colonist_1")
		if world.get_tool_item_reservation(axe_id) == job_id and colonist_1.get("route") != null and int(colonist_1["x"]) > 1:
			travelling = true
			break
	_expect(travelling, "chop_1 must reserve the axe and start travelling toward idle colonist_0 within budget")
	_expect(Scenarios.colonist_by_id(world, "colonist_0").get("route") == null,
		"colonist_0 must still be idle (a legitimate direct-pickup target) at the moment the reservation lands")

	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 20, "y": 10, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	_expect(Scenarios.command(world, "forage_0", "forage", {"x": 20, "y": 10, "priority": 1}).get("ok", false),
		"forage submission must be accepted")

	var drifting := false
	for _i in 30:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if String(colonist_0.get("held_tool", "")) == axe_id and colonist_0.get("route") != null:
			drifting = true
			break
	_expect(drifting, "colonist_0 must start walking its own drop_tool leg while still physically holding the axe within budget")

	var pick_ever_left_colonist_1 := false
	var completed := false
	for _i in 400:
		world.tick()
		var colonist_1 := Scenarios.colonist_by_id(world, "colonist_1")
		var held := String(colonist_1.get("held_tool", ""))
		if held != leftover_id and held != axe_id:
			pick_ever_left_colonist_1 = true
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(not pick_ever_left_colonist_1,
		"colonist_1 must hold either its own leftover pick or the freshly fetched axe at every tick, never neither -- a mid-travel drop_tool misclassification would empty its hands early")
	_expect(completed, "chop_1 must still complete once colonist_0 finishes relocating the axe and the fetch route retargets to it")

## _find_drop_cell()/_cell_still_free() must also treat a
## cell already holding a ground/stockpiled tool item as occupied -- the
## general cell_occupied callable only ever checked colonists and stackable
## items, never tool items.
func _check_drop_tool_skips_cell_already_occupied_by_another_tool() -> void:
	var world := WorldStateType.new(266020)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 2, "height": 1}).get("ok", false),
		"zone_add near colonist_0 must be accepted")
	world.spawn_ground_tool_item("axe", 2, 0)
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 5, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 5, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "stockpile" and location.get("x") == 3 and location.get("y") == 0,
		"the cell already holding an axe must be skipped in favor of the next free cell, got %s" % location)

## Removing the destination zone mid-travel must also be
## revalidated at arrival -- storing location.type "stockpile" for a cell
## that no longer belongs to any zone would be wrong, so arrival must fall
## back to dropping on the ground when the zone is gone.
func _check_drop_tool_falls_back_to_ground_when_destination_zone_removed_midflight() -> void:
	var world := WorldStateType.new(266021)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var zone_result := Scenarios.command(world, "zone_add_1", "zone_add", {"x": 2, "y": 0, "width": 1, "height": 1})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	var zone_id := String(zone_result.get("zone_id", ""))
	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 9, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")

	var submitted := Scenarios.command(world, "forage_1", "forage", {"x": 9, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "forage submission must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	world.tick()
	var colonist := world.get_colonists()[0]
	_expect(colonist.get("route") != null and int(colonist["x"]) == 0 and int(colonist["y"]) == 0,
		"the colonist must still be travelling toward the drop cell, not yet arrived")
	_expect(Scenarios.command(world, "zone_remove_1", "zone_remove", {"id": zone_id}).get("ok", false),
		"removing the destination zone mid-travel must be accepted")

	var dropped := false
	for _i in 60:
		world.tick()
		if String(world.get_tool_item(pick_id).get("location", {}).get("type", "")) != "held":
			dropped = true
			break
	_expect(dropped, "the pick must be dropped within the tick budget despite its destination zone disappearing")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(location.get("type", "") == "ground" and location.get("x") == 2 and location.get("y") == 0,
		"the colonist must still walk all the way to its own already-chosen cell (2, 0) and only then fall back to the ground once that cell no longer belongs to any zone, got %s" % location)

	var completed := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "colonist_0's own forage job must still complete despite the drop falling back to the ground")

## drop_tool runs for any active job kind,
## including haul -- needs_drop() is unconditional on job kind, and a freshly
## activated job's colonist.route/work both start null exactly like any other
## toil boundary, so a haul job's colonist can be sent to drop_tool before its
## own first pick_up toil ever runs. The drop-leg marker must never be written
## into the job's own itemId field: for a haul job that field already is the
## cargo's own item id (attached at submission by HaulGiver, read back by
## pick_up's item_id_for hook), and overwriting/clearing it mid-drop would
## corrupt which ground item the job is actually carrying. This drives a real
## haul job through an in-place drop (no stockpile cell within
## TOOL_DROP_RADIUS of the colonist's own position at activation) and proves
## the cargo's own itemId survives untouched on every single tick, and the
## haul job still completes and places its real cargo.
func _check_drop_tool_during_haul_job_preserves_cargo_identity_in_place() -> void:
	var world := WorldStateType.new(266040)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(axe_id, "foreign_job"),
		"reserving colonist_0's held axe for a foreign job must succeed, before any haul job even exists")
	# Zone far from colonist_0's own position (distance 20) so no cell inside
	# it ever falls within TOOL_DROP_RADIUS (5) of the drop: the axe's own
	# drop must fall back to dropping in place, not walking to a stockpile.
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 20, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	TestAccess.item_table(world).items["item_1"] = {"id": "item_1", "x": 10, "y": 0, "kind": "wood", "count": 1}
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

	var dropped := false
	for _i in 40:
		world.tick()
		_expect(String(Scenarios.find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must always name its cargo (item_1), never the tool being dropped or empty")
		if String(world.get_tool_item(axe_id).get("location", {}).get("type", "")) == "ground":
			dropped = true
			break
	_expect(dropped, "the axe must be dropped in place within budget")

	var completed := false
	for _i in 200:
		world.tick()
		_expect(String(Scenarios.find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must still name its cargo (item_1) all the way through completion")
		if String(Scenarios.find_job(world, haul_job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the haul job must still complete after the in-place drop")
	var final_item: Dictionary = _wood_item(world)
	_expect(int(final_item.get("x", -1)) == 20 and int(final_item.get("y", -1)) == 0,
		"item_1 must end up placed inside the stockpile zone at (20, 0), got %s" % final_item)

## Same regression as above, but the axe's own drop must walk to a nearby
## free stockpile cell instead of dropping in place (ToolDropToil's own
## nearest-cell preference). A single zone with two cells is used so the
## haul job's own destination reservation and the axe's own drop cell can
## each take one without contesting the other -- which specific cell either
## one lands on is left unasserted (an implementation detail of two
## independent, unrelated cell searches), only that they end up on different
## cells inside the same zone, and that the cargo's own itemId survives.
func _check_drop_tool_during_haul_job_preserves_cargo_identity_via_stockpile() -> void:
	var world := WorldStateType.new(266041)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"), "moving the axe into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(axe_id, "foreign_job"),
		"reserving colonist_0's held axe for a foreign job must succeed, before any haul job even exists")
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 3, "y": 0, "width": 2, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	TestAccess.item_table(world).items["item_1"] = {"id": "item_1", "x": 10, "y": 0, "kind": "wood", "count": 1}
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

	var axe_cell: Vector2i
	var dropped := false
	for _i in 60:
		world.tick()
		_expect(String(Scenarios.find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must always name its cargo (item_1), never the tool being dropped or empty")
		var location: Dictionary = world.get_tool_item(axe_id).get("location", {})
		if String(location.get("type", "")) == "stockpile":
			axe_cell = Vector2i(int(location["x"]), int(location["y"]))
			_expect(axe_cell.y == 0 and axe_cell.x in [3, 4], "the axe must land inside the zone, got %s" % [axe_cell])
			dropped = true
			break
	_expect(dropped, "the axe must be walked to a free stockpile cell and dropped there within budget")

	var completed := false
	for _i in 200:
		world.tick()
		_expect(String(Scenarios.find_job(world, haul_job_id).get("item_id", "")) == "item_1",
			"the haul job's own itemId must still name its cargo (item_1) all the way through completion")
		if String(Scenarios.find_job(world, haul_job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the haul job must still complete after the stockpile-cell drop")
	var final_item: Dictionary = _wood_item(world)
	_expect(int(final_item.get("y", -1)) == 0 and int(final_item.get("x", -1)) in [3, 4],
		"item_1 must end up placed inside the same zone, got %s" % final_item)
	_expect(not (int(final_item.get("x", -1)) == axe_cell.x and int(final_item.get("y", -1)) == axe_cell.y),
		"item_1's own cell must not be the same cell the axe was dropped on")

## Destroying a tool while its foreign holder is still busy (not yet
## dropping it) must not leave that holder's own held_tool pointing at the
## vanished id forever -- tool_item_store.gd's set_held()/set_ground()
## both refuse to touch a colonist's held_tool once the item itself is gone
## (there is no location left for their own _clear_holder() to read), so a
## stale reference would never be cleared and would block every later pickup
## for that colonist. Two real colonists, two real jobs, same shape as
## _check_requester_waits_for_real_handover_then_completes(): colonist_0
## holds a leftover pick while busy foraging; colonist_1's dig job reserves
## that same pick and must wait -- destroyed here mid-wait, proving
## colonist_1's job releases and backs off, colonist_0's own held_tool is
## reconciled even though colonist_0 was never the failing job's own
## colonist, and colonist_0 can still pick up a genuinely new tool afterward.
func _check_destroyed_foreign_held_tool_while_waiting_reconciles_holder() -> void:
	var world := WorldStateType.new(266030)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 10, 9, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")

	_expect(Scenarios.command(world, "place_bush", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var forage_a := Scenarios.command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a.get("ok", false), "forage_a submission must be accepted")
	var forage_a_id := String(forage_a["job_id"])

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a before the dig order below exists")

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var waiting_seen := false
	for _i in 400:
		world.tick()
		if String(Scenarios.find_job(world, dig_id).get("reason", "")) == "waiting_for_tool_handover":
			waiting_seen = true
			break
	_expect(waiting_seen, "the dig job must expose reason waiting_for_tool_handover while colonist_0 still holds the pick")
	_expect(String(Scenarios.colonist_by_id(world, "colonist_0").get("held_tool", "")) == pick_id,
		"colonist_0 must still physically hold the pick right before it is destroyed")

	TestAccess.tool_store(world).items.erase(pick_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, dig_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"the waiting dig job must re-queue with reason blocked_no_tool once its reserved tool is destroyed, got '%s'" % job.get("reason"))
			_expect(int(job.get("backoff_ticks", 0)) > 0,
				"the waiting dig job must re-queue with a nonzero backoff")
			break
	_expect(requeued, "the waiting dig job must re-queue within the tick budget once its reserved tool is destroyed")
	_expect(not world.is_tool_item_reserved(pick_id), "the destroyed pick's reservation must be released")
	_expect(String(Scenarios.colonist_by_id(world, "colonist_0").get("held_tool", "")) == "",
		"colonist_0's own held_tool must be reconciled even though colonist_0 was never the failing job's own colonist")

	var forage_done := false
	for _i in 60:
		world.tick()
		if String(Scenarios.find_job(world, forage_a_id).get("status", "")) == "completed":
			forage_done = true
			break
	_expect(forage_done, "colonist_0's own forage_a job must still complete")

	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_0"),
		"colonist_0 must be able to hold a genuinely new tool now that its stale held_tool reference is cleared")

## Destroying a foreign-held reserved tool while its holder
## is actively mid-drop (already walking toward a stockpile cell for its own
## next dispatched job, is_dropping() true) must not leave a dangling route:
## the holder's own drop-leg marker would otherwise still name the vanished
## item while held_tool no longer does, and the holder's own next-tick
## advance() would misread the stale, still-in-flight route as its ordinary
## go_to leg and arrive at the drop cell instead of its actual target.
func _check_destroyed_foreign_held_tool_mid_drop_reconciles_holder_route() -> void:
	var world := WorldStateType.new(266031)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.set_tile(world, 10, 9, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"mine": 0}})
	TestAccess.colonists(world).append({"id": "colonist_1", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	_expect(Scenarios.command(world, "zone_add_1", "zone_add", {"x": 5, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 0, 0)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(Scenarios.command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(Scenarios.command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var forage_a := Scenarios.command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a.get("ok", false), "forage_a must be accepted")
	var forage_a_id := String(forage_a["job_id"])

	var colonist_0_busy := false
	for _i in 20:
		world.tick()
		var colonist_0 := Scenarios.colonist_by_id(world, "colonist_0")
		if colonist_0.get("route") != null or colonist_0.get("work") != null:
			colonist_0_busy = true
			break
	_expect(colonist_0_busy, "colonist_0 must be busy on forage_a before the dig order below exists")

	var dig_result := Scenarios.command(world, "dig_1", "dig", {"x": 10, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var dig_id := String(dig_result.get("job_id", ""))

	var forage_a_done := false
	var forage_b_id := ""
	for _i in 400:
		world.tick()
		if not forage_a_done and String(Scenarios.find_job(world, forage_a_id).get("status", "")) == "completed":
			forage_a_done = true
			var forage_b := Scenarios.command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
			_expect(forage_b.get("ok", false), "forage_b must be accepted right as forage_a completes")
			forage_b_id = String(forage_b.get("job_id", ""))
		if not forage_b_id.is_empty():
			break
	_expect(forage_a_done, "forage_a must complete within budget")
	_expect(not forage_b_id.is_empty(), "forage_b must have been submitted once forage_a completed")

	# forage_b's own first toil is drop_tool (colonist_0's held pick is now
	# foreign-reserved by dig_1) -- caught two ticks in, still travelling.
	world.tick()
	var mid_drop := Scenarios.colonist_by_id(world, "colonist_0")
	_expect(mid_drop.get("route") != null and String(mid_drop.get("held_tool", "")) == pick_id,
		"colonist_0 must be mid-drop-leg, still holding the pick, one tick into forage_b")
	world.tick()
	var still_travelling := Scenarios.colonist_by_id(world, "colonist_0")
	_expect(still_travelling.get("route") != null and String(still_travelling.get("held_tool", "")) == pick_id,
		"colonist_0 must still be travelling toward the drop cell, not yet arrived")

	TestAccess.tool_store(world).items.erase(pick_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := Scenarios.find_job(world, dig_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"the dig job must re-queue with reason blocked_no_tool once the pick is destroyed mid-drop, got '%s'" % job.get("reason"))
			_expect(int(job.get("backoff_ticks", 0)) > 0, "the dig job must re-queue with a nonzero backoff")
			break
	_expect(requeued, "the dig job must re-queue within the tick budget once the pick is destroyed mid-drop")
	_expect(not world.is_tool_item_reserved(pick_id), "the destroyed pick's reservation must be released")

	var after_destroy := Scenarios.colonist_by_id(world, "colonist_0")
	_expect(String(after_destroy.get("held_tool", "")) == "",
		"colonist_0's held_tool must be reconciled once its in-flight drop target is destroyed")
	_expect(after_destroy.get("route") == null,
		"colonist_0's dangling mid-drop route must be cleared, not left to be misread as its own ordinary go_to leg")

	var forage_b_done := false
	for _i in 200:
		world.tick()
		if String(Scenarios.find_job(world, forage_b_id).get("status", "")) == "completed":
			forage_b_done = true
			break
	_expect(forage_b_done, "colonist_0 must still complete forage_b at its own real target, not the abandoned drop cell")
