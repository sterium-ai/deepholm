extends SceneTree

## Acceptance coverage for issue #189/#194's haul job kind (colonist-ai.md 3.3/3.4):
## WorldState auto-submits one haul job per unreserved loose item every tick,
## driven through the same toils (reserve item+cell, go_to item, pick_up,
## go_to cell, place, release_all) and the same ADR 004 global scheduler as
## dig/chop -- no side queue, no change to aging/budgets.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

var _failed := false

func _init() -> void:
	_check_two_of_three_items_reach_a_two_cell_zone()
	_check_cancel_mid_carry_drops_item_and_rehauls_later()
	_check_zone_removed_mid_walk_fails_blocked_destination_gone()
	_check_backoff_intervals_and_other_work_still_activates()

	if _failed:
		quit(1)
		return
	print("test_haul_stockpile: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	return world

func _colonist(id: String, x: int, y: int) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y, "route": null, "work": null, "hands": []}

func _place_wood_item(world: WorldStateType, item_id: String, x: int, y: int) -> void:
	world._items[item_id] = {"id": item_id, "x": x, "y": y, "kind": "wood", "count": 1}

func _apply(world: WorldStateType, command_id: String, type: String, payload: Dictionary) -> Dictionary:
	var result := world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": type, "payload": payload})
	_expect(result["ok"], "command %s must be accepted: %s" % [command_id, result])
	return result

func _add_zone(world: WorldStateType, command_id: String, x: int, y: int, width: int, height: int) -> String:
	return String(_apply(world, command_id, "zone_add", {"x": x, "y": y, "width": width, "height": height}).get("zone_id", ""))

func _haul_job_key(job: Dictionary) -> String:
	return "item:%s" % String(job.get("item_id", ""))

## Every reservation key must belong to an active job; checked after every
## tick so a mid-run leak (not just an end-state one) would be caught.
func _assert_no_orphaned_reservations(world: WorldStateType, context: String) -> void:
	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect(orphans.is_empty(), "no reservation may outlive its job (%s): orphans=%s" % [context, orphans])

func _haul_jobs(world: WorldStateType) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	for job in world.get_jobs():
		if String(job["kind"]) == "haul":
			jobs.append(job)
	return jobs

## Two colonists (colonist_0/1) and a spare third (colonist_2) with nothing
## else to do; three loose wood items; a 2-cell stockpile zone. Exactly two
## items must reach the zone; the third stays queued blocked_destination_full;
## the invariant helper must find no idle colonist with eligible work left
## undone (the spare colonist legitimately idles once the only remaining job
## is blocked, per its own reason-aware definition of "available"); and the
## reservation-ownership invariant must hold on every tick along the way.
func _check_two_of_three_items_reach_a_two_cell_zone() -> void:
	if _failed:
		return
	var world := _build_world(19001)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	world._colonists.append(_colonist("colonist_1", 0, 3))
	world._colonists.append(_colonist("colonist_2", 0, 6))
	_place_wood_item(world, "item_1", 10, 0)
	_place_wood_item(world, "item_2", 10, 3)
	_place_wood_item(world, "item_3", 10, 6)
	world._next_item_id = 4
	_add_zone(world, "zone_setup", 20, 0, 1, 2)

	for _i in 400:
		world.tick()
		_assert_no_orphaned_reservations(world, "two-of-three settling")

	var zone_cells: Dictionary = {Vector2i(20, 0): true, Vector2i(20, 1): true}
	var items_in_zone := 0
	for item in world.get_items():
		if zone_cells.has(Vector2i(int(item["x"]), int(item["y"]))):
			items_in_zone += 1
	_expect(items_in_zone == 2, "exactly two items must reach the two-cell zone (got %d)" % items_in_zone)

	var haul_jobs := _haul_jobs(world)
	var completed := 0
	var blocked_full := 0
	for job in haul_jobs:
		if job["status"] == "completed":
			completed += 1
		elif job["status"] == "queued" and job["reason"] == "blocked_destination_full":
			blocked_full += 1
	_expect(completed == 2, "exactly two haul jobs must complete (got %d)" % completed)
	_expect(blocked_full == 1, "the third item's haul job must report blocked_destination_full (got %d such jobs)" % blocked_full)

	var invariant := ReservationInvariantsType.check(
		world._scheduler.queue.get_reservation_table(), world.get_jobs(), world.get_colonists(), _haul_job_key,
		Callable(), Callable(), world._content)
	_expect(invariant["orphaned_reservations"].is_empty(), "no orphaned reservations at settle: %s" % [invariant["orphaned_reservations"]])
	_expect(invariant["idle_with_available_work"].is_empty(),
		"no colonist may idle while eligible reachable unreserved work exists: %s" % [invariant["idle_with_available_work"]])

## A single colonist, a single item already on its own tile (so pick_up
## happens the very first tick) and a distant one-cell zone (so several ticks
## of leg-two travel elapse before arrival): cancelling mid-carry must drop
## the item on the colonist's exact current tile, release both the item and
## cell reservations, and leave the item eligible to be hauled again once a
## fresh job claims it.
func _check_cancel_mid_carry_drops_item_and_rehauls_later() -> void:
	if _failed:
		return
	var world := _build_world(19002)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_place_wood_item(world, "item_1", 0, 0)
	world._next_item_id = 2
	_add_zone(world, "zone_setup", 0, 10, 1, 1)

	var job_id := ""
	for _i in 30:
		world.tick()
		var colonist := world.get_colonists()[0]
		if InventoryType.is_carrying(colonist) and job_id.is_empty():
			for job in _haul_jobs(world):
				if job["status"] == "active":
					job_id = String(job["id"])
		# Wait until the colonist has actually stepped away from (0,0), not
		# merely started leg two's route this same tick (move_ticks_remaining
		# has not yet elapsed for the first tile): a genuine mid-walk snapshot
		# needs a strictly-between position, not just a non-null route.
		if InventoryType.is_carrying(colonist) and colonist.get("route") != null and not job_id.is_empty() and int(colonist["y"]) > 0:
			break
	_expect(not job_id.is_empty(), "setup must reach an active haul job mid-carry")
	if job_id.is_empty():
		return

	var mid_carry := world.get_colonists()[0]
	_expect(InventoryType.is_carrying(mid_carry), "colonist must be carrying the item before cancelling")
	_expect(mid_carry.get("route") != null, "colonist must still be mid-walk to the cell before cancelling")
	var drop_tile := Vector2i(int(mid_carry["x"]), int(mid_carry["y"]))
	_expect(drop_tile != Vector2i(0, 0) and drop_tile != Vector2i(0, 10),
		"setup must catch the colonist strictly between the item's tile and the cell (got %s)" % [drop_tile])

	_apply(world, "cancel_haul", "cancel_job", {"job_id": job_id})

	var cancelled := world._scheduler.queue.get_job(job_id)
	_expect(cancelled["status"] == "cancelled", "the haul job must be cancelled")
	var after_cancel := world.get_colonists()[0]
	_expect(not InventoryType.is_carrying(after_cancel), "the colonist must no longer be carrying after cancel")
	_expect(world.get_ground_wood(drop_tile.x, drop_tile.y) == 1,
		"the item must land on the colonist's exact tile at the moment of cancellation")
	var table := world._scheduler.queue.get_reservation_table()
	_expect(not table.is_reserved("item:item_1"), "cancel must release the item reservation")
	_expect(not table.is_reserved("cell:0,10"), "cancel must release the cell reservation")

	var rehauled := false
	for _i in 200:
		world.tick()
		_assert_no_orphaned_reservations(world, "post-cancel rehaul")
		if world.get_ground_wood(0, 10) == 1:
			rehauled = true
			break
	_expect(rehauled, "the dropped item must be hauled to the (now-free) cell once a fresh job claims it")

## A colonist walking toward a reserved cell must fail the job
## blocked_destination_gone, with no leaked reservation, when the zone
## covering that cell is removed mid-walk -- distinct from cancellation:
## nothing external told this specific job to stop, its destination simply
## ceased to exist.
func _check_zone_removed_mid_walk_fails_blocked_destination_gone() -> void:
	if _failed:
		return
	var world := _build_world(19003)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_place_wood_item(world, "item_1", 0, 0)
	world._next_item_id = 2
	var zone_id := _add_zone(world, "zone_setup", 0, 10, 1, 1)

	var job_id := ""
	for _i in 30:
		world.tick()
		var colonist := world.get_colonists()[0]
		if job_id.is_empty():
			for job in _haul_jobs(world):
				if job["status"] == "active":
					job_id = String(job["id"])
		if InventoryType.is_carrying(colonist) and colonist.get("route") != null and not job_id.is_empty():
			break
	_expect(not job_id.is_empty(), "setup must reach an active haul job mid-carry")
	if job_id.is_empty():
		return
	var mid_walk := world.get_colonists()[0]
	_expect(mid_walk.get("route") != null, "colonist must still be walking toward the cell before the zone is removed")

	_apply(world, "remove_zone_mid_walk", "zone_remove", {"id": zone_id})

	var failed_job := world._scheduler.queue.get_job(job_id)
	_expect(failed_job["status"] == "failed" and failed_job["reason"] == "blocked_destination_gone",
		"removing the zone mid-walk must fail the job blocked_destination_gone (got status=%s reason=%s)"
			% [failed_job["status"], failed_job["reason"]])
	var table := world._scheduler.queue.get_reservation_table()
	_expect(not table.is_reserved("item:item_1"), "no leaked item reservation after blocked_destination_gone")
	_expect(not table.is_reserved("cell:0,10"), "no leaked cell reservation after blocked_destination_gone")
	_assert_no_orphaned_reservations(world, "after blocked_destination_gone")

## A permanently-failing haul job (no zone exists at all, so
## _find_free_haul_cell() never returns a cell) must retry at
## WorldState.HAUL_RETRY_BASE_TICKS, then double, capped at
## WorldState.HAUL_RETRY_CAP_TICKS -- read from the event log's
## "haul_destination_attempt" entries for that job, not re-derived here.
## A second, unrelated colonist's dig order must still activate and complete
## comfortably within ADR 004's proven 300-tick service bound while the first
## colonist repeatedly, harmlessly retries the doomed haul job.
func _check_backoff_intervals_and_other_work_still_activates() -> void:
	if _failed:
		return
	var world := _build_world(19004)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	world._colonists.append(_colonist("colonist_1", 5, 5))
	_place_wood_item(world, "item_1", 0, 0)
	world._next_item_id = 2
	world._tiles[world._tile_index(7, 5)] = WorldStateType.TILE_SOIL
	world.spawn_ground_tool_item("pick", 5, 5)

	var dig_result := _apply(world, "dig_other", "dig", {"x": 7, "y": 5, "priority": 1})
	var dig_job_id := String(dig_result.get("job_id", ""))
	var dig_activated_tick := -1
	var dig_completed := false

	var haul_job_id := ""
	const RUN_TICKS := 200
	for _i in RUN_TICKS:
		world.tick()
		if haul_job_id.is_empty():
			for job in _haul_jobs(world):
				haul_job_id = String(job["id"])
		if dig_activated_tick < 0:
			var dig_job := world._scheduler.queue.get_job(dig_job_id)
			if dig_job["status"] == "active":
				dig_activated_tick = world.get_tick()
		if not dig_completed:
			var dig_job := world._scheduler.queue.get_job(dig_job_id)
			if dig_job["status"] == "completed":
				dig_completed = true

	_expect(dig_activated_tick >= 0 and dig_activated_tick <= 300,
		"the unrelated dig order must activate within ADR 004's 300-tick bound despite the doomed haul job (activated at %d)" % dig_activated_tick)
	_expect(dig_completed, "the unrelated dig order must complete while the haul job keeps failing")
	_expect(not haul_job_id.is_empty(), "the permanently-failing haul job must exist")
	if haul_job_id.is_empty():
		return

	var final_job := world._scheduler.queue.get_job(haul_job_id)
	_expect(final_job["status"] == "queued" and final_job["reason"] == "blocked_destination_full",
		"a haul job with no reachable zone must stay queued blocked_destination_full (got status=%s reason=%s)"
			% [final_job["status"], final_job["reason"]])

	var attempt_ticks: Array[int] = []
	for event in world.get_events():
		if event["type"] == "haul_destination_attempt" and event["entity_id"] == haul_job_id:
			attempt_ticks.append(int(event["tick"]))
	attempt_ticks.sort()
	_expect(attempt_ticks.size() >= 3, "at least three retry attempts must be observed within the run (got %d)" % attempt_ticks.size())
	if attempt_ticks.size() < 3:
		return
	var first_gap := attempt_ticks[1] - attempt_ticks[0]
	var second_gap := attempt_ticks[2] - attempt_ticks[1]
	var haul_retry_base_ticks := int(world._scheduler.queue._haul_retry_base_ticks)
	var haul_retry_cap_ticks := int(world._scheduler.queue._haul_retry_cap_ticks)
	_expect(first_gap >= haul_retry_base_ticks,
		"the first retry gap must be at least the base backoff (got %d, base %d)" % [first_gap, haul_retry_base_ticks])
	_expect(second_gap >= first_gap,
		"backoff must not shrink between successive retries (got %d then %d)" % [first_gap, second_gap])
	for gap in [first_gap, second_gap]:
		_expect(gap <= haul_retry_cap_ticks,
			"no retry gap may exceed the declared cap (got %d, cap %d)" % [gap, haul_retry_cap_ticks])
