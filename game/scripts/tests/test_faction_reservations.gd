extends SceneTree

## F3 (issue #290): before any job's reserve step acquires a tile:/item:/cell:
## key on behalf of an assigned actor for a colony-owned target,
## WorldState._enforce_faction_reservations() consults the assignee's
## faction's rules.may_reserve_colony_items and refuses the reservation,
## typed (not_ordered_by_player), leaving nothing acquired -- the same
## terminal fail() path zone_remove's blocked_destination_gone already uses.
## Exercised by submitting directly through WorldState._scheduler.submit()'s
## restrict_to, bypassing _apply_job_command's own may_be_ordered gate at the
## command layer entirely (test_order_input.gd already covers that gate) --
## the Non-goals-mandated "directly constructing or set_faction-ing a test
## actor" route, never a live-scenario non-colony actor.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const TICK_BOUND := 150
## Two-row-world dig-target enclosure (mirrors test_reroute.gd's own
## _check_unreachable_target_releases_job): a few ticks to reach (2,0), a few
## more to prove unreachable and resubmit, then -- once the walls come back
## down -- a short walk plus WORK_TICKS["dig"] (30) to actually finish it.
const ASSIGNEE_PRESERVED_TICK_BOUND := 250

var _failed := false

func _init() -> void:
	_check_raiders_cannot_reserve()
	_check_allies_follow_their_own_rule()
	_check_haul_item_and_cell_reservations_refused_for_disallowed_reserver()
	_check_resume_after_faction_change_refuses_reacquisition()
	_check_haul_job_never_offered_to_order_ineligible_worker()
	_check_assignee_preserved_across_unreachable_resubmission()
	_check_refused_resumption_returns_carried_haul_item()
	_check_command_boundary_drains_refusal_without_manual_call()
	_check_order_eligibility_revalidated_independent_of_reservation_gate()
	_check_refused_resumption_returns_carried_item_when_own_tile_blocked()
	_check_reservation_gate_refuses_initial_tile_reservation()
	_check_reservation_gate_refuses_haul_item_and_cell_reservation()
	_check_reservation_gate_refuses_suspended_resumption()
	if _failed:
		quit(1)
		return
	print("test_faction_reservations: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _set_faction(world: WorldStateType, command_id: String, target: String, faction_id: String) -> Dictionary:
	return world.apply({
		"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": "set_faction", "payload": {"target": target, "faction_id": faction_id},
	})

## Searches in expanding Chebyshev rings from colonist_0's own tile (issue
## #300: the spawn clearing is chosen dynamically -- docs/decisions/020 -- so
## a tile found scanning from the map origin could be genuinely unreachable,
## across the river from wherever this seed's colonists actually spawned,
## failing the job "blocked_target_unreachable" instead of the
## not_ordered_by_player refusal these checks isolate).
func _find_soil(world: WorldStateType) -> Vector2i:
	var width := world.get_map_width()
	var height := world.get_map_height()
	var origin := Vector2i(int(world.get_colonists()[0]["x"]), int(world.get_colonists()[0]["y"]))
	var max_radius := maxi(width, height)
	for radius in range(0, max_radius + 1):
		for y in range(origin.y - radius, origin.y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin.x - radius, origin.x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin.x), absi(y - origin.y)) != radius:
					continue
				if world.get_tile(x, y) == "soil" and bool(world.passability(x, y)["passable"]):
					return Vector2i(x, y)
	return Vector2i(-1, -1)

## Submits target directly through GlobalAssignment.submit()'s restrict_to
## (bypassing the command layer's own may_be_ordered gate), then ticks until
## the reserve-step gate refuses the job or the bound is exhausted. Uses
## "till" rather than "dig": till needs no tool (content/jobs.json), so a
## freshly spawned colonist with no picks reaches the reserve step directly
## instead of blocking on fetch_tool first.
func _submit_and_await_refusal(world: WorldStateType, colonist_id: String, target: Vector2i) -> Dictionary:
	var submit_result: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "till", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	for _i in range(TICK_BOUND):
		world.tick()
		var job: Dictionary = world._scheduler.queue.get_job(job_id)
		if not job.is_empty() and String(job.get("status", "")) == "failed":
			return job
	return world._scheduler.queue.get_job(job_id)

func _check_invariants(world: WorldStateType, label: String) -> void:
	var report := ReservationInvariantsType.check(
		world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(),
		"%s: ReservationInvariants.check() must report no orphaned_reservations after a refused attempt" % label)

## Every reservation_acquired event ever recorded for job_id -- proves the
## reserve-step gate refuses BEFORE acquisition (never a transient acquire
## followed by a release): a refused job must show zero of these, and a job
## resumed after a disallowed faction change must show no MORE than its
## original activation's own single event.
func _reservation_acquired_events(world: WorldStateType, job_id: String) -> Array:
	var matches: Array = []
	for event in world.get_events():
		if String(event.get("type", "")) == "reservation_acquired" and String(event.get("entity_id", "")) == job_id:
			matches.append(event)
	return matches

func _check_raiders_cannot_reserve() -> void:
	if _failed:
		return
	var world := WorldStateType.new(1, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	_expect(_set_faction(world, "set_raider", colonist_id, "raiders").get("ok", false),
		"set_faction to raiders must be accepted")
	var target := _find_soil(world)
	_expect(target != Vector2i(-1, -1), "expected a soil tile for this check")
	var job := _submit_and_await_refusal(world, colonist_id, target)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a raiders-faction actor's job must be refused not_ordered_by_player, typed, on the reserve step")
	_expect(_reservation_acquired_events(world, String(job.get("id", ""))).is_empty(),
		"a raiders-faction actor's job must never acquire a reservation, not even transiently")
	_check_invariants(world, "raiders")

func _check_allies_follow_their_own_rule() -> void:
	if _failed:
		return
	var world := WorldStateType.new(2, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	_expect(_set_faction(world, "set_allies", colonist_id, "allies").get("ok", false),
		"set_faction to allies must be accepted")
	var target := _find_soil(world)
	_expect(target != Vector2i(-1, -1), "expected a soil tile for this check")
	var job := _submit_and_await_refusal(world, colonist_id, target)
	# allies' own content/factions.json rules.may_reserve_colony_items is
	# false today; this reads that value through the registry rather than
	# assuming it, so a future content change making it true would let this
	# same job activate instead of being refused.
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"an allies-faction actor's reservation must follow its own may_reserve_colony_items rule (false today)")
	_expect(_reservation_acquired_events(world, String(job.get("id", ""))).is_empty(),
		"an allies-faction actor's job must never acquire a reservation, not even transiently")
	_check_invariants(world, "allies")

## F3 (issue #290): a haul job's own item:/cell: reservation pair is gated by
## the exact same may_reserve_colony_items check as dig/chop/forage's tile:
## key -- HaulGiver itself never assigns an actor (see haul_giver.gd), so this
## submits directly through restrict_to + attach_item, the same seam
## _submit_and_await_refusal() above uses, to exercise the reserve step in
## isolation.
func _check_haul_item_and_cell_reservations_refused_for_disallowed_reserver() -> void:
	if _failed:
		return
	var world := WorldStateType.new(3, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	var colonist_id := "colonist_0"
	world._colonists.append({"id": colonist_id, "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._items["item_1"] = {"id": "item_1", "x": 5, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var zone_result := world.apply({"actor": "test", "command_id": "zone_haul_reserve", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 10, "y": 0, "width": 1, "height": 1}})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	_expect(_set_faction(world, "set_allies_haul_reserve", colonist_id, "allies").get("ok", false),
		"set_faction to allies must be accepted")
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(5, 0), 1, world.get_tick(), "haul", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission of a haul job must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	_expect(world._scheduler.queue.attach_item(job_id, "item_1"), "attach_item must succeed for a queued haul job")
	for _i in range(TICK_BOUND):
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "failed":
			break
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"an allies-faction actor's haul job must be refused not_ordered_by_player on its item:/cell: reserve step")
	_expect(_reservation_acquired_events(world, job_id).is_empty(),
		"a refused haul job must never acquire its item: or cell: reservation, not even transiently")
	_check_invariants(world, "haul_item_cell")

## F3 (issue #290, round 1 revision): resume_assignment()'s own pre-reactivate
## check -- not just tick()'s pre-activation one -- must refuse a job whose
## actor's faction changed while it was suspended (colonist-ai.md 3.6's
## critical-need interrupt). Drives suspend_assignment()/resume_assignment()
## directly (the same scheduler seam WorldState._interrupt_current_job()/
## _resume_interrupted_job() themselves call) rather than through a live need
## interrupt: need_giver.gd's own may_be_ordered actor-pool filter would
## otherwise freeze the need search itself the instant the faction below
## changes, before resume_assignment() is ever reached.
func _check_resume_after_faction_change_refuses_reacquisition() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var target := _find_soil(world)
	_expect(target != Vector2i(-1, -1), "expected a soil tile for this check")
	var submit_result: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "till", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	var activated := false
	for _i in range(TICK_BOUND):
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "active":
			activated = true
			break
	_expect(activated, "the job must activate for a colony-faction colonist before this check can proceed")
	if not activated:
		return
	world._scheduler.suspend_assignment(colonist_id, job_id)
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"suspend_assignment must release the job's reservation back to queued")
	_expect(_set_faction(world, "set_raider_mid_pause", colonist_id, "raiders").get("ok", false),
		"set_faction while the job is suspended must be accepted")
	world._scheduler.resume_assignment(colonist_id, job_id)
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"resume_assignment must not reacquire a reservation for a now-disallowed faction")
	world._resolve_refused_reservations()
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a resumed job must be refused not_ordered_by_player once the actor's faction changed while suspended")
	_expect(_reservation_acquired_events(world, job_id).size() == 1,
		"resume_assignment must never reacquire a reservation for a now-disallowed faction (only the original activation's own event may exist)")
	_check_invariants(world, "resume_after_faction_change")

## F3 (issue #290, round 1 revision): fixes the gap the reviewer named for
## haul specifically -- HaulGiver has no actor pool to filter, so an
## order-ineligible worker's own scan must never even propose its ambient
## (unrestricted) haul job, leaving it available to an eligible colonist
## instead of an ineligible one winning and failing it repeatedly.
func _check_haul_job_never_offered_to_order_ineligible_worker() -> void:
	if _failed:
		return
	var world := WorldStateType.new(5, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null, "hands": []})
	world._items["item_1"] = {"id": "item_1", "x": 5, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var zone_result := world.apply({"actor": "test", "command_id": "zone_haul_elig", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 10, "y": 0, "width": 1, "height": 1}})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	# Issue #390 (ADR 031): "traders" rather than "raiders" -- both share the
	# same may_be_ordered=false/may_reserve_colony_items=false rules this check
	# actually exercises, but traders' own relation to colony is "neutral"
	# (both directions), never "hostile", so colonist_1 is never itself given
	# a competing `approach` job by ApproachGiver, which would otherwise walk
	# it off its own (20, 0) tile toward colonist_0 across this test's own
	# 150-tick budget and fail the "must never move" assertion below for a
	# reason unrelated to order-eligibility.
	_expect(_set_faction(world, "set_raider_haul_elig", "colonist_1", "traders").get("ok", false),
		"set_faction to traders must be accepted")
	var completed := false
	for _i in range(TICK_BOUND):
		world.tick()
		_expect(not world._scheduler.get_assignments().has("colonist_1"),
			"an order-ineligible colonist must never be assigned the ambient haul job, leaving it available to the eligible colonist")
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "haul" and String(job.get("item_id", "")) == "item_1" and String(job.get("status", "")) == "completed":
				completed = true
		if completed:
			break
	_expect(completed, "the haul job must eventually complete via the eligible (colony) colonist")
	var raider_colonist := {}
	for colonist in world.get_colonists():
		if String(colonist["id"]) == "colonist_1":
			raider_colonist = colonist
	_expect(not raider_colonist.is_empty() and int(raider_colonist["x"]) == 20 and int(raider_colonist["y"]) == 0,
		"the order-ineligible colonist must never move to pursue the haul job")
	_check_invariants(world, "haul_mixed_faction")

## Two colony colonists (colonist_0 the assignee, colonist_1 idle and equally
## eligible otherwise), a dig target enclosed mid-walk exactly like
## test_reroute.gd's own _check_unreachable_target_releases_job(): the forced
## cancel-and-resubmit must carry colonist_0's assignee restriction onto the
## replacement job (WorldState._resubmit_unreachable_job(), via
## GlobalAssignment.restrict_to_for()) so colonist_1 can never receive it,
## before or after the walls come back down.
func _build_two_row_colony_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 5):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_SOIL
		world._tiles[world._tile_index(x, 1)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 1, "route": null, "work": null, "hands": []})
	# dig needs_tool "pick" (content/jobs.json); spawned on colonist_0's own
	# tile so fetch_tool resolves immediately, matching test_reroute.gd's own
	# _build_two_row_world() fixture.
	world.spawn_ground_tool_item("pick", 0, 0)
	return world

func _find_queued_job_for_target(world: WorldStateType, target: Vector2i) -> Dictionary:
	for job in world.get_jobs():
		if job["target"] == target and job["status"] == "queued":
			return job
	return {}

## restrict_to_for() only knows a job's restrict_to once it has actually
## activated (GlobalAssignment._activated_entries is populated on activation,
## not submission); a still-queued (blocked_target_unreachable) replacement
## job's restrict_to instead lives on its own _waiting entry, read here
## directly rather than waiting for it to activate first.
func _waiting_restrict_to(world: WorldStateType, job_id: String) -> String:
	for entry in world._scheduler.get_waiting():
		if String(entry.get("id", "")) == job_id:
			return String(entry.get("restrict_to", ""))
	return ""

func _check_assignee_preserved_across_unreachable_resubmission() -> void:
	if _failed:
		return
	var world := _build_two_row_colony_world(9010)
	var enclosed_target := Vector2i(4, 0)
	var dig_result := world.apply({"actor": "player", "command_id": "assignee_dig", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": enclosed_target.x, "y": enclosed_target.y, "assignee": "colonist_0"}})
	_expect(dig_result.get("ok", false), "an assignee'd dig command on a valid soil target must be accepted")

	var walled := false
	var released := false
	var replacement_job_id := ""
	var ticks := 0
	var wrong_worker_seen := false
	while ticks < ASSIGNEE_PRESERVED_TICK_BOUND:
		world.tick()
		ticks += 1
		var colonist_0 := world.get_colonists()[0]
		if not walled and int(colonist_0["x"]) == 2 and int(colonist_0["y"]) == 0:
			world._set_object(3, 0, "wall")
			world._set_object(4, 1, "wall")
			walled = true
		if walled and not released:
			var blocked_job := _find_queued_job_for_target(world, enclosed_target)
			if not blocked_job.is_empty() and String(blocked_job.get("reason", "")) == "blocked_target_unreachable":
				released = true
				replacement_job_id = String(blocked_job["id"])
				_expect(_waiting_restrict_to(world, replacement_job_id) == "colonist_0",
					"the replacement job must preserve the original assignee's restrict_to")
				world._set_object(3, 0, "")
				world._set_object(4, 1, "")
		if released:
			var assignments := world._scheduler.get_assignments()
			if assignments.has("colonist_1") and String(assignments["colonist_1"]["job_id"]) == replacement_job_id:
				wrong_worker_seen = true
			if String(world._scheduler.queue.get_job(replacement_job_id).get("status", "")) == "completed":
				break

	_expect(walled, "test fixture must enclose the target before colonist_0 reaches it")
	_expect(released, "enclosed target's job must be released with blocked_target_unreachable within the declared tick bound")
	_expect(replacement_job_id != "", "a replacement job must exist once the target was released")
	_expect(not wrong_worker_seen, "colonist_1 (not the assignee) must never receive the replacement job")
	if replacement_job_id != "":
		_expect(String(world._scheduler.queue.get_job(replacement_job_id).get("status", "")) == "completed",
			"the assignee must take and complete the replacement job within the declared tick bound (%d)" % ASSIGNEE_PRESERVED_TICK_BOUND)
	_check_invariants(world, "assignee_preserved")

## F3 (issue #290, round 2): a colonist mid-carry (picked up, not yet placed)
## whose haul job is interrupted by a critical need, then refused on resume
## after a faction change, must not strand its cargo: WorldState._resolve_
## refused_reservations() must return the carried item to the ground the same
## way an ordinary haul termination does, since by the time the resumption is
## refused, the job's scheduler assignment (and thus _find_job_colonist()'s
## own lookup) is already gone.
func _check_refused_resumption_returns_carried_haul_item() -> void:
	if _failed:
		return
	var world := WorldStateType.new(6, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	var colonist_id := "colonist_0"
	world._colonists.append({"id": colonist_id, "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._items["item_1"] = {"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var zone_result := world.apply({"actor": "test", "command_id": "zone_carry_return", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 10, "y": 0, "width": 1, "height": 1}})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "haul", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission of a haul job must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	_expect(world._scheduler.queue.attach_item(job_id, "item_1"), "attach_item must succeed for a queued haul job")
	var carrying := false
	for _i in range(TICK_BOUND):
		world.tick()
		if InventoryType.is_carrying(world._find_colonist(colonist_id)):
			carrying = true
			break
	_expect(carrying, "the colonist must pick up the item before this check can proceed")
	if not carrying:
		return
	world._interrupt_current_job(world._find_colonist(colonist_id))
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"interrupting a mid-carry haul must suspend its reservation back to queued")
	_expect(_set_faction(world, "set_raider_mid_carry", colonist_id, "raiders").get("ok", false),
		"set_faction while the haul is suspended mid-carry must be accepted")
	world._resume_interrupted_job(colonist_id)
	world._resolve_refused_reservations()
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a refused resumption must terminally fail the haul job not_ordered_by_player")
	_expect(not InventoryType.is_carrying(world._find_colonist(colonist_id)),
		"a refused resumption must drop the colonist's carried item instead of stranding it")
	var ground_count := 0
	for item in world.get_items():
		if String(item.get("kind", "")) == "wood":
			ground_count += int(item.get("count", 0))
	_expect(ground_count == 1, "the carried item must return to the ground exactly once")
	_check_invariants(world, "refused_resumption_carried_item")

## F3 (issue #290, round 3): the check above only ever exercises the always-
## free case for the carrier's own tile; this one occupies that exact tile
## with a second colonist right before the refused resumption, forcing
## ToilExecutor.place()'s ordinary re-validation to refuse so
## WorldState._force_drop_carried_item()'s fallback (an unconditional ground
## write, mirroring tool_drop_toil.gd's own terminal _drop_tool_ground) is
## what actually returns the item -- proving cargo is never stranded even when
## the ordinary drop path itself is blocked.
func _check_refused_resumption_returns_carried_item_when_own_tile_blocked() -> void:
	if _failed:
		return
	var world := WorldStateType.new(12, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	var colonist_id := "colonist_0"
	world._colonists.append({"id": colonist_id, "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._items["item_1"] = {"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var zone_result := world.apply({"actor": "test", "command_id": "zone_carry_return_blocked", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 10, "y": 0, "width": 1, "height": 1}})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "haul", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission of a haul job must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	_expect(world._scheduler.queue.attach_item(job_id, "item_1"), "attach_item must succeed for a queued haul job")
	var carrying := false
	for _i in range(TICK_BOUND):
		world.tick()
		if InventoryType.is_carrying(world._find_colonist(colonist_id)):
			carrying = true
			break
	_expect(carrying, "the colonist must pick up the item before this check can proceed")
	if not carrying:
		return
	var carrier := world._find_colonist(colonist_id)
	var blocker_tile := Vector2i(int(carrier["x"]), int(carrier["y"]))
	world._colonists.append({"id": "colonist_1", "kind": "colonist",
		"x": blocker_tile.x, "y": blocker_tile.y, "route": null, "work": null, "hands": []})
	world._interrupt_current_job(world._find_colonist(colonist_id))
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"interrupting a mid-carry haul must suspend its reservation back to queued")
	_expect(_set_faction(world, "set_raider_mid_carry_blocked", colonist_id, "raiders").get("ok", false),
		"set_faction while the haul is suspended mid-carry must be accepted")
	world._resume_interrupted_job(colonist_id)
	world._resolve_refused_reservations()
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a refused resumption must terminally fail the haul job not_ordered_by_player even when the colonist's own tile is blocked")
	_expect(not InventoryType.is_carrying(world._find_colonist(colonist_id)),
		"a refused resumption must clear the colonist's carried item even when its own tile is occupied")
	var ground_count := 0
	for item in world.get_items():
		if String(item.get("kind", "")) == "wood":
			ground_count += int(item.get("count", 0))
	_expect(ground_count == 1, "the carried item must be conserved (returned to the ground exactly once) even when the drop tile is blocked")
	_check_invariants(world, "refused_resumption_carried_item_blocked")

## F3 (issue #290, round 3): mirrors _check_order_eligibility_revalidated_
## independent_of_reservation_gate() below but swapped -- may_be_ordered true,
## may_reserve_colony_items alone false -- covering the three reserve-step
## call sites the round 3 review named as unexercised: initial tile
## reservation (here), haul item/cell reservation, and suspended resumption
## (the two functions below). Without _worker_may_reserve() actually gating
## activation, each of these three would activate and eventually complete
## instead of being refused not_ordered_by_player.
func _check_reservation_gate_refuses_initial_tile_reservation() -> void:
	if _failed:
		return
	var world := WorldStateType.new(13, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var target := _find_soil(world)
	_expect(target != Vector2i(-1, -1), "expected a soil tile for this check")
	world._scheduler.set_order_eligibility(func(_worker: String) -> bool: return true)
	world._scheduler.set_reservation_gate(func(worker: String) -> bool: return worker != colonist_id)
	var submit_result: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "till", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	for _i in range(TICK_BOUND):
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "failed":
			break
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a restrict_to'd order must be refused when the assignee fails ONLY may_reserve_colony_items, even with may_be_ordered true")
	_expect(_reservation_acquired_events(world, job_id).is_empty(),
		"a reservation-ineligible actor's restrict_to'd job must never acquire a reservation, not even transiently")
	_check_invariants(world, "reservation_gate_independent_of_order_initial")

## Haul counterpart of the check above: exercises the item:/cell: reserve
## step specifically, the same seam
## _check_haul_item_and_cell_reservations_refused_for_disallowed_reserver()
## exercises for may_be_ordered, but with the gates swapped.
func _check_reservation_gate_refuses_haul_item_and_cell_reservation() -> void:
	if _failed:
		return
	var world := WorldStateType.new(14, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	var colonist_id := "colonist_0"
	world._colonists.append({"id": colonist_id, "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._items["item_1"] = {"id": "item_1", "x": 5, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var zone_result := world.apply({"actor": "test", "command_id": "zone_haul_reserve_gate", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 10, "y": 0, "width": 1, "height": 1}})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	world._scheduler.set_order_eligibility(func(_worker: String) -> bool: return true)
	world._scheduler.set_reservation_gate(func(worker: String) -> bool: return worker != colonist_id)
	var submit_result: Dictionary = world._scheduler.submit(Vector2i(5, 0), 1, world.get_tick(), "haul", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission of a haul job must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	_expect(world._scheduler.queue.attach_item(job_id, "item_1"), "attach_item must succeed for a queued haul job")
	for _i in range(TICK_BOUND):
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "failed":
			break
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a reservation-ineligible actor's haul job must be refused on its item:/cell: reserve step even with may_be_ordered true")
	_expect(_reservation_acquired_events(world, job_id).is_empty(),
		"a reservation-ineligible actor's haul job must never acquire its item: or cell: reservation, not even transiently")
	_check_invariants(world, "reservation_gate_independent_of_order_haul")

## Suspended-resumption counterpart: mirrors
## _check_resume_after_faction_change_refuses_reacquisition()'s shape but
## swaps which gate alone is false, proving resume_assignment()'s own
## _worker_may_reserve() revalidation (not just _worker_may_be_ordered())
## refuses reactivation.
func _check_reservation_gate_refuses_suspended_resumption() -> void:
	if _failed:
		return
	var world := WorldStateType.new(15, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var target := _find_soil(world)
	_expect(target != Vector2i(-1, -1), "expected a soil tile for this check")
	world._scheduler.set_order_eligibility(func(_worker: String) -> bool: return true)
	var submit_result: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "till", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	var activated := false
	for _i in range(TICK_BOUND):
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "active":
			activated = true
			break
	_expect(activated, "the job must activate while may_reserve_colony_items still passes before this check can proceed")
	if not activated:
		return
	world._scheduler.suspend_assignment(colonist_id, job_id)
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"suspend_assignment must release the job's reservation back to queued")
	world._scheduler.set_reservation_gate(func(worker: String) -> bool: return worker != colonist_id)
	world._scheduler.resume_assignment(colonist_id, job_id)
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "queued",
		"resume_assignment must not reacquire a reservation for a now reservation-ineligible actor, even with may_be_ordered true")
	world._resolve_refused_reservations()
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"resume_assignment must refuse a reservation-ineligible actor even when may_be_ordered alone would allow it")
	_expect(_reservation_acquired_events(world, job_id).size() == 1,
		"resume_assignment must never reacquire a reservation for a now reservation-ineligible actor (only the original activation's own event may exist)")
	_check_invariants(world, "reservation_gate_independent_of_order_resume")

## F3 (issue #290, round 2): a refusal produced entirely OUTSIDE tick() -- here,
## a cancel_job command resolving a need whose resume_interrupted_job() call
## gets refused -- must already be terminally resolved by the time apply()
## itself returns, not left for the next tick() to discover. No manual
## _resolve_refused_reservations() call in this check: if the fix regressed,
## the till job below would still read "queued" (suspended, not yet failed)
## immediately after apply() returns.
func _check_command_boundary_drains_refusal_without_manual_call() -> void:
	if _failed:
		return
	var world := WorldStateType.new(7, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var target := _find_soil(world)
	_expect(target != Vector2i(-1, -1), "expected a soil tile for this check")
	var submit_result: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "till", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission must be accepted")
	var till_job_id: String = String(submit_result.get("job_id", ""))
	var working := false
	for _i in range(TICK_BOUND):
		world.tick()
		if (world._find_colonist(colonist_id).get("work") != null
				and String(world._scheduler.queue.get_job(till_job_id).get("status", "")) == "active"):
			working = true
			break
	_expect(working, "the colonist must be actively working the till job before this check can proceed")
	if not working:
		return
	world._interrupt_current_job(world._find_colonist(colonist_id))
	_expect(String(world._scheduler.queue.get_job(till_job_id).get("status", "")) == "queued",
		"interrupting the till job must suspend its reservation back to queued")
	# Fakes a NeedGiver commitment through the same seam need_giver.gd itself
	# uses (submit()'s restrict_to + _pending), so cancelling it below drives
	# the real resolve_job() -> resume_interrupted_job() path.
	var need_submit: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "drink_water", colonist_id)
	_expect(need_submit.get("ok", false), "direct scheduler submission of the need job must be accepted")
	var need_job_id: String = String(need_submit.get("job_id", ""))
	world._need_giver._pending[colonist_id] = need_job_id
	_expect(_set_faction(world, "set_raider_command_boundary", colonist_id, "raiders").get("ok", false),
		"set_faction while the till job is suspended must be accepted")
	var cancel_result := world.apply({"actor": "test", "command_id": "cancel_need_boundary", "tick": world.get_tick(),
		"type": "cancel_job", "payload": {"job_id": need_job_id}})
	_expect(cancel_result.get("ok", false), "cancelling the need job must be accepted")
	var till_job := world._scheduler.queue.get_job(till_job_id)
	_expect(String(till_job.get("status", "")) == "failed" and String(till_job.get("reason", "")) == "not_ordered_by_player",
		"cancelling a need job outside tick() must synchronously refuse and terminate the suspended till job before apply() returns")
	_expect(world._scheduler.take_refused_reservations().is_empty(),
		"no refusal may be left undrained in GlobalAssignment once _apply_job_command() has returned")
	_check_invariants(world, "command_boundary_drain")
	var restored := WorldStateType.from_save_state(world.to_save_state())
	_expect(restored.state_hash() == world.state_hash(),
		"a refusal already resolved before the command returned must leave no divergence across a save/restore round trip")

## F3 (issue #290, round 2): may_be_ordered and may_reserve_colony_items are
## independent rules -- content/factions.json has no faction combining
## may_be_ordered=false with may_reserve_colony_items=true today, so this
## drives GlobalAssignment's two gates directly through set_order_eligibility()/
## set_reservation_gate() (never editing factions.json, which this task does
## not own) to prove a restrict_to'd order and a resume_assignment() call are
## each refused on may_be_ordered ALONE, closing the bypass the reviewer named:
## an early scan-time filter is not the same as revalidating at the reserve step.
func _check_order_eligibility_revalidated_independent_of_reservation_gate() -> void:
	if _failed:
		return
	var world := WorldStateType.new(8, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var target := _find_soil(world)
	_expect(target != Vector2i(-1, -1), "expected a soil tile for this check")
	world._scheduler.set_order_eligibility(func(worker: String) -> bool: return worker != colonist_id)
	world._scheduler.set_reservation_gate(func(_worker: String) -> bool: return true)
	var submit_result: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "till", colonist_id)
	_expect(submit_result.get("ok", false), "direct scheduler submission must be accepted")
	var job_id: String = String(submit_result.get("job_id", ""))
	for _i in range(TICK_BOUND):
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "failed":
			break
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a restrict_to'd order must be refused when the assignee fails ONLY may_be_ordered, even with may_reserve_colony_items true")
	_expect(_reservation_acquired_events(world, job_id).is_empty(),
		"an order-ineligible actor's restrict_to'd job must never acquire a reservation, not even transiently")
	_check_invariants(world, "order_eligibility_independent_of_reservation_fresh")

	world._scheduler.set_order_eligibility(func(_worker: String) -> bool: return true)
	var submit_result2: Dictionary = world._scheduler.submit(target, 1, world.get_tick(), "till", colonist_id)
	_expect(submit_result2.get("ok", false), "direct scheduler submission must be accepted")
	var job_id2: String = String(submit_result2.get("job_id", ""))
	var activated := false
	for _i in range(TICK_BOUND):
		world.tick()
		if String(world._scheduler.queue.get_job(job_id2).get("status", "")) == "active":
			activated = true
			break
	_expect(activated, "the job must activate while both gates pass before this check can proceed")
	if not activated:
		return
	world._scheduler.suspend_assignment(colonist_id, job_id2)
	_expect(String(world._scheduler.queue.get_job(job_id2).get("status", "")) == "queued",
		"suspend_assignment must release the job's reservation back to queued")
	world._scheduler.set_order_eligibility(func(worker: String) -> bool: return worker != colonist_id)
	world._scheduler.resume_assignment(colonist_id, job_id2)
	_expect(String(world._scheduler.queue.get_job(job_id2).get("status", "")) == "queued",
		"resume_assignment must not reacquire a reservation for a now order-ineligible actor, even with may_reserve_colony_items true")
	world._resolve_refused_reservations()
	var job2 := world._scheduler.queue.get_job(job_id2)
	_expect(String(job2.get("status", "")) == "failed" and String(job2.get("reason", "")) == "not_ordered_by_player",
		"resume_assignment must refuse an order-ineligible actor even when may_reserve_colony_items alone would allow it")
	_expect(_reservation_acquired_events(world, job_id2).size() == 1,
		"resume_assignment must never reacquire a reservation for a now order-ineligible actor (only the original activation's own event may exist)")
	_check_invariants(world, "order_eligibility_independent_of_reservation_resume")
