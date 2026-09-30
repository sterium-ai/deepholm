extends SceneTree

## Headless end-to-end scenarios for the tool toils (fetch_tool, drop_tool
## and the destroyed-tool failure path; docs/decisions/013-tool-toils.md),
## following docs/architecture/colonist-ai.md section 4's "Tools" entry.
## Drives real jobs through the existing engine (job queue -> scheduler ->
## toil executor, AGENTS.md's "one work engine") and asserts five outcomes,
## reusing the same world-construction and
## command helpers as test_toils_dig_chop_regression.gd and
## test_tool_items.gd:
##   1. two colonists share one axe across two chop orders: both complete,
##      idle ticks stay bounded, and the axe is unreserved (still held) the
##      instant each job finishes.
##   2. no axe exists anywhere: the chop job reaches blocked_no_tool and the
##      colonist completes a different, tool-free (forage) job instead.
##   3. the actively-held/reserved axe is destroyed mid-job: the work toil
##      stops immediately, every reservation the job held is released, and
##      the job re-queues with a nonzero backoff.
##   4. handover: colonist A holds the axe while genuinely busy on a job that
##      needs no tool; colonist B's chop job reserves the held axe and waits
##      (reason waiting_for_tool_handover); A's own next dispatched job runs
##      drop_tool before its own first toil; B then fetches the dropped axe
##      and completes -- all within a declared tick bound.
##   5. a save/load round trip through to_save_state()/from_save_state()
##      leaves state_hash() unchanged, both mid-fetch_tool (walking toward an
##      unclaimed tool) and mid-handover (a holder mid-drop_tool).

const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failed := false

func _init() -> void:
	_check_scenario_1_two_colonists_one_axe_two_chop_orders()
	_check_scenario_2_no_tool_anywhere_blocks_and_frees_colonist()
	_check_scenario_3_destroyed_tool_mid_job_fails_and_requeues()
	_check_scenario_4_handover_bounded_ticks()
	_check_scenario_5a_save_load_mid_fetch_tool_matches_hash()
	_check_scenario_5b_save_load_mid_handover_drop_matches_hash()

	if _failed:
		quit(1)
		return
	print("test_tool_handover_scenarios: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _command(world: WorldStateType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

func _find_colonist(world: WorldStateType, colonist_id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}

## Mirrors test_movement_scheduling_load.gd's own eligibility/idle-streak
## invariant helpers verbatim (proven there at load-test scale): a colonist
## only "idles" against the bound below while a reachable, unreserved,
## not-already-under-evaluation queued job exists for it to take instead.
func _has_eligible_queued_job(world: WorldStateType) -> bool:
	var reservations := world.get_reservations()
	var under_evaluation: Dictionary = {}
	var pending: Dictionary = world._scheduler.get_pending()
	for worker in pending:
		for candidate in (pending[worker]["candidates"] as Array):
			under_evaluation[candidate["id"]] = true
	for job in world.get_jobs():
		if (job["status"] == "queued" and not reservations.has(job["target"])
				and String(job.get("reason", "")).is_empty() and not under_evaluation.has(job["id"])):
			return true
	return false

func _idle_colonists(world: WorldStateType) -> Array[String]:
	var idle: Array[String] = []
	for colonist in world.get_colonists():
		if colonist["route"] == null and colonist["work"] == null:
			idle.append(colonist["id"])
	return idle

# --- Scenario 1: two colonists, one axe, two chop orders --------------------

## Same idle-streak bound test_movement_scheduling_load.gd already enforces at
## load-test scale (an ordinary scheduler-reassignment/route-evaluation lag is
## 1-3 ticks; see that file's own _check_no_idle_while_work_available()).
const SCENARIO_1_IDLE_STREAK_BOUND := 3
const SCENARIO_1_MAX_TICKS := 400

func _check_scenario_1_two_colonists_one_axe_two_chop_orders() -> void:
	var world := WorldStateType.new(266101)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(9, 0)] = WorldStateType.TILE_TREE
	world._tiles[world._tile_index(9, 1)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 0, "y": 1, "route": null, "work": null})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)

	var chop1 := _command(world, "chop_1", "chop", {"x": 9, "y": 0, "priority": 1})
	_expect(chop1.get("ok", false), "chop_1 submission must be accepted")
	var chop1_id := String(chop1.get("job_id", ""))
	var chop2 := _command(world, "chop_2", "chop", {"x": 9, "y": 1, "priority": 1})
	_expect(chop2.get("ok", false), "chop_2 submission must be accepted")
	var chop2_id := String(chop2.get("job_id", ""))

	var chop1_done := false
	var chop2_done := false
	var idle_streaks: Dictionary = {}
	var ticks := 0
	while (not chop1_done or not chop2_done) and ticks < SCENARIO_1_MAX_TICKS:
		world.tick()
		ticks += 1
		if not _has_eligible_queued_job(world):
			idle_streaks.clear()
		else:
			var idle_now: Dictionary = {}
			for id in _idle_colonists(world):
				idle_now[id] = true
				idle_streaks[id] = int(idle_streaks.get(id, 0)) + 1
				_expect(int(idle_streaks[id]) <= SCENARIO_1_IDLE_STREAK_BOUND,
					"colonist %s idled %d ticks in a row while eligible chop work existed (tick %d)" %
						[id, idle_streaks[id], ticks])
			for id in idle_streaks.keys():
				if not idle_now.has(id):
					idle_streaks[id] = 0

		if not chop1_done and String(_find_job(world, chop1_id).get("status", "")) == "completed":
			chop1_done = true
			_expect(not world.is_tool_item_reserved(axe_id),
				"the axe must be unreserved the instant chop_1 completes")
			_expect(String(world.get_tool_item(axe_id).get("location", {}).get("type", "")) == "held",
				"the axe must still be held (not dropped) once chop_1 completes -- colonist-ai.md's release, not drop")
		if not chop2_done and String(_find_job(world, chop2_id).get("status", "")) == "completed":
			chop2_done = true
			_expect(not world.is_tool_item_reserved(axe_id),
				"the axe must be unreserved the instant chop_2 completes")
			_expect(String(world.get_tool_item(axe_id).get("location", {}).get("type", "")) == "held",
				"the axe must still be held (not dropped) once chop_2 completes -- colonist-ai.md's release, not drop")

	_expect(chop1_done and chop2_done,
		"both chop orders sharing one axe must complete within %d ticks (chop1=%s chop2=%s)" %
			[SCENARIO_1_MAX_TICKS, chop1_done, chop2_done])

# --- Scenario 2: no matching tool anywhere -----------------------------------

func _check_scenario_2_no_tool_anywhere_blocks_and_frees_colonist() -> void:
	var world := WorldStateType.new(266102)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(9, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})

	var chop := _command(world, "chop_1", "chop", {"x": 9, "y": 0, "priority": 1})
	_expect(chop.get("ok", false), "chop_1 submission must be accepted even with no axe anywhere")
	var chop_id := String(chop.get("job_id", ""))

	var blocked := false
	for _i in 10:
		world.tick()
		var chop_job := _find_job(world, chop_id)
		if String(chop_job.get("reason", "")) == "blocked_no_tool":
			blocked = true
			_expect(String(chop_job.get("status", "")) == "queued",
				"a chop job with no axe anywhere must stay a queued, non-terminal job, got status '%s'" % chop_job.get("status"))
			break
	_expect(blocked, "the chop job must expose reason blocked_no_tool within the tick budget")

	_expect(_command(world, "place_bush", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement must be accepted")
	var forage := _command(world, "forage_1", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage.get("ok", false), "forage submission must be accepted")
	var forage_id := String(forage.get("job_id", ""))

	var forage_done := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, forage_id).get("status", "")) == "completed":
			forage_done = true
			break
	_expect(forage_done,
		"the colonist blocked on the tool-needing chop job must still complete a different, tool-free (forage) job")
	_expect(String(_find_job(world, chop_id).get("status", "")) == "queued",
		"the blocked chop job must remain queued the whole time, not silently replaced by the colonist taking other work")

# --- Scenario 3: the reserved/held tool is destroyed mid-job ----------------

func _check_scenario_3_destroyed_tool_mid_job_fails_and_requeues() -> void:
	var world := WorldStateType.new(266103)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("axe", 0, 0)

	var chop := _command(world, "chop_1", "chop", {"x": 2, "y": 0, "priority": 1})
	_expect(chop.get("ok", false), "chop_1 submission must be accepted")
	var job_id := String(chop.get("job_id", ""))

	var working := false
	var held_id := ""
	for _i in 30:
		world.tick()
		if world.get_colonists()[0].get("work") != null:
			working = true
			held_id = String(world.get_colonists()[0].get("held_tool", ""))
			break
	_expect(working, "the chop job must reach its work toil (actively using the axe) within budget")
	_expect(held_id != "", "colonist_0 must be holding the axe while working")
	_expect(world.get_tool_item_reservation(held_id) == job_id,
		"the chop job must own the axe's reservation while actively working")

	# A second, unrelated tool reservation the same job happens to also hold --
	# every reservation the job held must be released below, not just the
	# destroyed one.
	var extra_id := world.spawn_ground_tool_item("pick", 5, 5)
	_expect(world.reserve_tool_item(extra_id, job_id), "reserving a second, unrelated tool for the same job must succeed")

	# Simulate the axe being destroyed/removed out from under the active job.
	world._tool_store.items.erase(held_id)

	var requeued := false
	for _i in 10:
		world.tick()
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "queued":
			requeued = true
			_expect(String(job.get("reason", "")) == "blocked_no_tool",
				"a job whose active tool was destroyed must re-queue with reason blocked_no_tool, got '%s'" % job.get("reason"))
			_expect(int(job.get("backoff_ticks", 0)) > 0,
				"a job whose active tool was destroyed must re-queue with a nonzero backoff, got %d" % job.get("backoff_ticks", 0))
			break
	_expect(requeued, "the chop job must re-queue within the tick budget once its active axe is destroyed")
	_expect(not world.is_tool_item_reserved(held_id),
		"the destroyed axe's own reservation must be released, not left dangling")
	_expect(not world.is_tool_item_reserved(extra_id),
		"every other reservation the failing job held must also be released, not just the destroyed item's")
	_expect(String(world.get_colonists()[0].get("held_tool", "")) == "",
		"the colonist must no longer record held_tool once its actively-used tool is destroyed")
	_expect(world.get_colonists()[0].get("work") == null,
		"the colonist's work toil must stop the instant its active tool is destroyed")

	# Supplying a fresh axe must let the same job id complete afterward.
	world.spawn_ground_tool_item("axe", 0, 0)
	var completed := false
	for _i in 120:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the re-queued job must still complete once a replacement axe becomes available")

# --- Scenario 4: handover, bounded ticks ------------------------------------

## Generous upper bound (mirroring test_movement_scheduling_load.gd's own
## HANDOVER_WAIT_TICK_BOUND reasoning): forage_a's own travel+work, the
## bounded wait, colonist_a's drop_tool leg, and colonist_b's own fetch
## travel+chop work all fit comfortably inside this scenario's small (11x10)
## geometry well before this bound.
const SCENARIO_4_MAX_TICKS := 500

func _check_scenario_4_handover_bounded_ticks() -> void:
	var world := WorldStateType.new(266104)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_a", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"chop": 0}})
	world._colonists.append({"id": "colonist_b", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_a"), "moving the axe into colonist_a's hand must succeed")

	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var forage_a := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a.get("ok", false), "forage_a submission must be accepted")
	var forage_a_id := String(forage_a.get("job_id", ""))

	var ticks := 0

	# colonist_a must already be genuinely busy on forage_a -- a real, active
	# job that needs no tool -- before chop_b (and its axe reservation) ever
	# exists, or the direct-idle-holder steal path would run instead of the
	# handover wait this scenario is about.
	var colonist_a_busy := false
	for _i in 20:
		world.tick()
		ticks += 1
		var colonist_a := _find_colonist(world, "colonist_a")
		if colonist_a.get("route") != null or colonist_a.get("work") != null:
			colonist_a_busy = true
			break
	_expect(colonist_a_busy, "colonist_a must be busy on forage_a before chop_b (and its axe reservation) ever exists")

	var chop_b := _command(world, "chop_b", "chop", {"x": 10, "y": 9, "priority": 1})
	_expect(chop_b.get("ok", false), "chop_b submission must be accepted")
	var chop_b_id := String(chop_b.get("job_id", ""))

	var waiting_seen := false
	var completed := false
	var forage_a_done := false
	while ticks < SCENARIO_4_MAX_TICKS:
		world.tick()
		ticks += 1
		if not forage_a_done:
			for job in world.get_jobs():
				if job["id"] == forage_a_id and job["status"] == "completed":
					forage_a_done = true
					# colonist_a's own next dispatched job -- submitted only
					# now, so a third job is never queued while colonist_b
					# waits -- is what makes its first toil drop_tool.
					var forage_b := _command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
					_expect(forage_b.get("ok", false), "forage_b must be accepted right as forage_a completes")
		var chop_job := _find_job(world, chop_b_id)
		if String(chop_job.get("reason", "")) == "waiting_for_tool_handover":
			waiting_seen = true
			_expect(String(chop_job.get("item_id", "")) == axe_id,
				"waiting_for_tool_handover's itemId must name the reserved axe, got '%s'" % chop_job.get("item_id"))
			_expect(String(_find_colonist(world, "colonist_b").get("held_tool", "")) == "",
				"colonist_b must not hold the axe while genuinely waiting for the handover")
		if String(chop_job.get("status", "")) == "completed":
			completed = true
			break
	_expect(waiting_seen, "chop_b must expose reason waiting_for_tool_handover while colonist_a still holds the axe")
	_expect(completed,
		"chop_b must complete, within %d total ticks, once colonist_a's own next dispatched job drops the axe (took %d)" %
			[SCENARIO_4_MAX_TICKS, ticks])
	_expect(String(_find_colonist(world, "colonist_b").get("held_tool", "")) == axe_id,
		"colonist_b must end up holding the axe it waited for")

	var drop_seen := false
	for entry in world._toils.trace:
		if String(entry.get("toil", "")) == "drop_tool" and String(entry.get("phase", "")) == "complete":
			drop_seen = true
	_expect(drop_seen, "colonist_a must have run a drop_tool toil to release the handover: %s" % [world._toils.trace])

# --- Scenario 5: save/load mid-carry and mid-handover -----------------------

func _check_scenario_5a_save_load_mid_fetch_tool_matches_hash() -> void:
	var world := WorldStateType.new(266105)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(11, 0)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	var axe_id := world.spawn_ground_tool_item("axe", 10, 0)

	var chop := _command(world, "chop_1", "chop", {"x": 11, "y": 0, "priority": 1})
	_expect(chop.get("ok", false), "chop_1 submission must be accepted")
	var job_id := String(chop.get("job_id", ""))

	var midway := false
	for _i in 30:
		world.tick()
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") == null and String(colonist.get("held_tool", "")) == "" \
				and int(colonist["x"]) > 0 and int(colonist["x"]) < 10:
			midway = true
			break
	_expect(midway,
		"colonist_0 must be caught mid-fetch_tool travel toward the axe (resolved route, not yet arrived, not yet held)")
	_expect(world.get_tool_item_reservation(axe_id) == job_id,
		"chop_1 must already own the axe's reservation while travelling toward it")

	var before_hash := world.state_hash()
	var restored: WorldStateType = WorldStateType.from_save_state(world.to_save_state())
	_expect(restored.state_hash() == before_hash,
		"restore must match the source's hash immediately, before any further ticks")

	var direct_completed := false
	for _i in 100:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			direct_completed = true
			break
	_expect(direct_completed, "the uninterrupted run must complete chop_1 after fetching the axe")

	var restored_completed := false
	for _i in 100:
		restored.tick()
		if String(_find_job(restored, job_id).get("status", "")) == "completed":
			restored_completed = true
			break
	_expect(restored_completed, "the restored run must also complete chop_1 after fetching the axe")
	_expect(world.state_hash() == restored.state_hash(),
		"the source and restored runs must reach the identical final hash")

func _check_scenario_5b_save_load_mid_handover_drop_matches_hash() -> void:
	var world := WorldStateType.new(266106)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_a", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"chop": 0}})
	world._colonists.append({"id": "colonist_b", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	_expect(_command(world, "zone_add_1", "zone_add", {"x": 4, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"zone_add must be accepted")
	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_a"), "moving the axe into colonist_a's hand must succeed")
	var forage_a := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a.get("ok", false), "forage_a submission must be accepted")
	var forage_a_id := String(forage_a.get("job_id", ""))
	var busy := false
	for _i in 20:
		world.tick()
		var holder := _find_colonist(world, "colonist_a")
		if holder.get("route") != null or holder.get("work") != null:
			busy = true
			break
	_expect(busy, "the holder must be doing real tool-free work before another real job requests the axe")
	var chop_b := _command(world, "chop_b", "chop", {"x": 10, "y": 9, "priority": 1})
	_expect(chop_b.get("ok", false), "chop_b submission must be accepted")
	var chop_b_id := String(chop_b.get("job_id", ""))

	var midway := false
	var waiting_seen := false
	var next_forage_id := ""
	for _i in SCENARIO_4_MAX_TICKS:
		world.tick()
		if next_forage_id == "" and String(_find_job(world, forage_a_id).get("status", "")) == "completed":
			var next_forage := _command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
			_expect(next_forage.get("ok", false), "the holder's next job must be accepted")
			next_forage_id = String(next_forage.get("job_id", ""))
		var waiting_job := _find_job(world, chop_b_id)
		if String(waiting_job.get("reason", "")) == "waiting_for_tool_handover":
			waiting_seen = true
		var colonist := _find_colonist(world, "colonist_a")
		var route = colonist.get("route")
		if waiting_seen and next_forage_id != "" and route != null and route.get("rerouting") == null \
				and String(colonist.get("held_tool", "")) == axe_id \
				and int(colonist["x"]) > 0 and int(colonist["x"]) < 4:
			midway = true
			break
	_expect(waiting_seen, "a real chop job must wait for the busy holder's axe before the snapshot")
	_expect(midway,
		"colonist_a must be caught mid-drop_tool movement for the handover (resolved path, still holding the axe, not yet arrived)")
	_expect(world.get_tool_item_reservation(axe_id) == chop_b_id, "the real waiting chop job must own the axe reservation at save time")

	var before_hash := world.state_hash()
	var restored: WorldStateType = WorldStateType.from_save_state(world.to_save_state())
	_expect(restored.state_hash() == before_hash,
		"restore must match the source's hash immediately, before any further ticks")

	var completed := false
	for _i in SCENARIO_4_MAX_TICKS:
		world.tick()
		restored.tick()
		_expect(world.state_hash() == restored.state_hash(), "restored handover must match the uninterrupted run on every tick")
		if String(_find_job(world, chop_b_id).get("status", "")) == "completed" \
				and String(_find_job(world, next_forage_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "both real jobs must complete within the handover bound after save/load")
	for run in [world, restored]:
		_expect(String(_find_colonist(run, "colonist_b").get("held_tool", "")) == axe_id,
			"the waiting colonist must actually fetch the handed-over axe and finish chopping")
		_expect(not run.is_tool_item_reserved(axe_id), "completion must release the handed-over axe reservation")
