extends SceneTree

## Coverage for issue #243/#238: a need interrupt firing while a colonist is
## mid-haul must never lose or duplicate the carried item, and a save taken
## while a need job, a paused work job (with kept tile progress), and an
## in-flight haul all coexist must restore byte-for-byte, matching an
## uninterrupted run's state_hash() at the same tick. Both checks exercise the
## existing job-queue/scheduler/toil-executor pipeline and NeedGiver/HaulGiver
## job-givers (AGENTS.md "one work engine") -- no decision logic changes here,
## only scenario coverage and the schema-14 save-format changes it needed.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const SEEDS := [2430001, 2430002]
const ADVANCE_TICKS := 250

var _failed := false

func _init() -> void:
	for seed_value in SEEDS:
		_check_combined_round_trip_matches_uninterrupted_run(seed_value)
		_check_haul_interrupted_by_need_preserves_wood(seed_value)
		_check_rest_interrupt_completes_sleep_while_carrying_wood(seed_value)
	if _failed:
		quit(1)
		return
	print("test_haul_need_interrupt: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _apply(world: WorldStateType, command_id: String, type: String, payload: Dictionary) -> Dictionary:
	var result: Dictionary = world.apply({
		"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": type, "payload": payload,
	})
	_expect(result["ok"], "command %s must be accepted: %s" % [command_id, result])
	return result

## Only food ever decays in these checks (water/rest zeroed out, mirroring
## test_save_migration.gd's own critical-interrupt check): the scenario only
## needs one need kind to reach threshold, and a second kind decaying on its
## own schedule would risk a second, unrelated interrupt racing the one under
## test. from_save_state() reloads _need_definitions fresh from content, so
## every check re-applies this after a restore, same as that existing check.
func _zero_other_need_rates(world: WorldStateType) -> void:
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0

func _total_wood_units(world: WorldStateType) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == "wood":
			total += int(item["count"])
	for colonist in world.get_colonists():
		total += InventoryType.count_of_kind(colonist, "wood")
	return total

func _wood_item_ids(world: WorldStateType) -> Array:
	var ids: Array = []
	for item in world.get_items():
		if String(item["kind"]) == "wood":
			ids.append(String(item["id"]))
	return ids

func _job_by_id(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

## The tick of the first event of event_type recorded for job_id, or -1 when
## none exists -- used to verify a transition (e.g. completion) actually
## happened, and when, rather than inferring it from a later polled state.
func _first_event_tick(world: WorldStateType, event_type: String, job_id: String) -> int:
	for event in world.get_events():
		if event["type"] == event_type and event["entity_id"] == job_id:
			return int(event["tick"])
	return -1

## The shared ReservationTable JobQueue._tick_haul()/suspend()/reactivate()
## acquire and release a haul job's "item:"/"cell:" keys on (colonist-ai.md
## 3.4/#189); reused here rather than re-implemented so this test observes the
## exact same ledger the scheduler enforces.
func _reservation_owner(world: WorldStateType, key: String) -> String:
	return world._scheduler.queue.get_reservation_table().owner(key)

## --- (a) combined round trip: active need job + paused work job (kept tile
## progress) + in-flight haul, all at once, must save/restore identically to
## an uninterrupted run -----------------------------------------------------

## An all-floor 48x48 map (WorldState.MAP_WIDTH/HEIGHT are fixed) with two
## colonists placed explicitly: colonist_0 digs, colonist_1 hauls. Ground
## berries at (4,1) sit one diagonal step from colonist_0's dig target so the
## eat_food search/walk this scenario relies on resolves in a handful of
## ticks, not zero (the save must still catch it genuinely pending) and not so
## many the haul (~45 ticks uninterrupted) finishes first.
func _build_combined_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 20, "y": 0, "route": null, "work": null, "hands": []})
	_zero_other_need_rates(world)
	world._ground_berries["4_1"] = 1
	world.spawn_ground_tool_item("pick", 0, 0)
	world._items["item_1"] = {"id": "item_1", "x": 21, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	_apply(world, "zone_setup", "zone_add", {"x": 30, "y": 0, "width": 1, "height": 1})
	return world

## Drives a freshly built combined world up to the moment all three pieces of
## state this check cares about coexist: colonist_0's dig job paused mid-work
## with partial tile progress kept, its critical-food eat_food job already
## committed (not just searching), and colonist_1's haul still in flight
## (walking to the item or carrying it toward the zone -- never far enough
## along to have completed, see the class doc above). Deterministic: every
## step is either a fixed tick count or a budgeted loop over an observable
## condition, so the same seed always reaches the same tick.
func _prime_combined_scenario(world: WorldStateType, seed_value: int) -> void:
	var dig_result := _apply(world, "dig_1", "dig", {"x": 1, "y": 0, "priority": 1})
	var dig_job_id: String = String(dig_result.get("job_id", ""))

	var work_started := false
	for _i in 10:
		world.tick()
		if world.get_colonists()[0].get("work") != null:
			work_started = true
			break
	_expect(work_started, "colonist_0 must start the dig job's work toil within budget (seed %d)" % seed_value)
	if not work_started:
		return
	for _i in 5:
		world.tick()

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 5
	world.tick()

	var committed := false
	for _i in 40:
		if not world._need_giver.get_pending_assignments().is_empty():
			committed = true
			break
		world.tick()
	_expect(committed, "colonist_0's food search must commit to a job within budget (seed %d)" % seed_value)
	if not committed:
		return

	var haul_job_id := ""
	for job in world.get_jobs():
		if String(job["kind"]) == "haul":
			haul_job_id = String(job["id"])
	_expect(not haul_job_id.is_empty(), "HaulGiver must have auto-submitted a haul job by now (seed %d)" % seed_value)
	var haul_job := _job_by_id(world, haul_job_id)
	_expect(String(haul_job.get("status", "")) in ["queued", "active"],
		"the haul job must still be in flight, not yet completed, at prime tick (seed %d)" % seed_value)
	var colonist_1 := world.get_colonists()[1]
	_expect(colonist_1.get("route") != null or InventoryType.is_carrying(colonist_1),
		"colonist_1 must still be walking or carrying mid-haul at prime tick (seed %d)" % seed_value)

func _assert_combined_completion(world: WorldStateType, seed_value: int, label: String) -> void:
	var eat_completed := false
	var dig_completed := false
	var haul_completed := false
	for _i in ADVANCE_TICKS:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "eat_food" and job["status"] == "completed":
				eat_completed = true
			if String(job["kind"]) == "dig" and job["status"] == "completed":
				dig_completed = true
			if String(job["kind"]) == "haul" and job["status"] == "completed":
				haul_completed = true
		if eat_completed and dig_completed and haul_completed:
			break
	_expect(eat_completed, "%s: the eat_food job must complete within budget (seed %d)" % [label, seed_value])
	_expect(dig_completed, "%s: the interrupted dig job must resume and complete (seed %d)" % [label, seed_value])
	_expect(haul_completed, "%s: the haul job must complete (seed %d)" % [label, seed_value])
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_TRENCH,
		"%s: the resumed dig job must still finish transforming its target tile (seed %d)" % [label, seed_value])
	_expect(world.get_ground_wood(30, 0) == 1,
		"%s: the hauled wood must end at the stockpile destination (seed %d)" % [label, seed_value])

func _check_combined_round_trip_matches_uninterrupted_run(seed_value: int) -> void:
	if _failed:
		return

	# Path A: an uninterrupted run straight through priming and past completion.
	var direct := _build_combined_world(seed_value)
	_prime_combined_scenario(direct, seed_value)
	_assert_combined_completion(direct, seed_value, "direct")

	# Path B: save right after priming (need job committed, dig paused with
	# kept tile progress, haul in flight), restore into a fresh WorldState,
	# then drive it to completion the identical way.
	var source := _build_combined_world(seed_value)
	_prime_combined_scenario(source, seed_value)

	var saved := source.to_save_state()
	_expect((saved["needJobAssignments"] as Array).size() == 1,
		"a save taken mid-scenario must persist NeedGiver's own colonist->job association (seed %d)" % seed_value)
	_expect((saved["pausedJobs"] as Array).size() == 1,
		"a save taken mid-scenario must persist the paused dig job (seed %d)" % seed_value)
	# Round-6 review (#278/#303): a suspended job's own progress is persisted
	# via job-id-keyed "suspendedWorkProgress", not the shared tile-keyed
	# "workProgress" array -- world_state.gd's own _suspend_work_progress()
	# moves it out the instant the interrupt clears colonist.work, so a
	# different job that later works the same tile can never inherit it.
	var suspended_work_progress: Array = saved["suspendedWorkProgress"]
	var dig_progress := int(suspended_work_progress[0]["ticksRemaining"]) if suspended_work_progress.size() > 0 else -1
	_expect(dig_progress > 0 and dig_progress < int(source._work_ticks["dig"]),
		"a save taken mid-scenario must persist the dig job's own partial progress (seed %d, got %d)" % [seed_value, dig_progress])
	var haul_in_flight := false
	for entity in (saved["entities"] as Array):
		if String(entity["id"]) == "colonist_1" and (entity["route"] != null or not (entity["hands"] as Array).is_empty()):
			haul_in_flight = true
	_expect(haul_in_flight, "a save taken mid-scenario must persist colonist_1's in-flight haul route/hands (seed %d)" % seed_value)

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_zero_other_need_rates(restored)
	_expect(restored.state_hash() == source.state_hash(),
		"restore must match the source's hash before any further ticks (seed %d)" % seed_value)

	_assert_combined_completion(restored, seed_value, "restored")

	_expect(direct.get_tick() == restored.get_tick(),
		"tick counters must match after driving both copies to completion (seed %d)" % seed_value)
	_expect(direct.state_hash() == restored.state_hash(),
		"state_hash must match an uninterrupted run after driving both copies to completion (seed %d)" % seed_value)

## --- (b) a colonist carrying wood, interrupted mid-haul: wood is never lost
## or duplicated, and the haul resumes to completion -------------------------

func _build_haul_only_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "hands": []})
	_zero_other_need_rates(world)
	world._ground_berries["4_1"] = 1
	world._items["item_1"] = {"id": "item_1", "x": 5, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	_apply(world, "zone_setup", "zone_add", {"x": 10, "y": 0, "width": 1, "height": 1})
	return world

## A haul job has no `work` toil (content/jobs.json), so is_interruptible_toil
## never applies to it directly (colonist-ai.md 3.6/NeedGiver's own doc
## comment): the only point a need can preempt it is the toil boundary between
## its instant pick_up/place toils, where colonist.route and colonist.work are
## both null for exactly one tick while colonist.carrying is already set.
## Forcing food to a critical value while parked at that boundary is what
## fires the interrupt one tick later, with the item already in hand.
func _check_haul_interrupted_by_need_preserves_wood(seed_value: int) -> void:
	if _failed:
		return
	var world := _build_haul_only_world(seed_value)
	_expect(_total_wood_units(world) == 1, "world must start with exactly one wood unit (seed %d)" % seed_value)

	var boundary_reached := false
	var haul_job_id := ""
	for _i in 40:
		world.tick()
		_expect(_total_wood_units(world) == 1,
			"wood must never be lost or duplicated before pick-up (seed %d, tick %d)" % [seed_value, world.get_tick()])
		if haul_job_id.is_empty():
			for job in world.get_jobs():
				if String(job["kind"]) == "haul":
					haul_job_id = String(job["id"])
		var colonist := world.get_colonists()[0]
		if InventoryType.is_carrying(colonist) and colonist.get("route") == null and colonist.get("work") == null:
			boundary_reached = true
			break
	_expect(boundary_reached, "setup must reach the post-pick_up toil boundary within budget (seed %d)" % seed_value)
	_expect(not haul_job_id.is_empty(), "HaulGiver must have auto-submitted a haul job (seed %d)" % seed_value)
	if not boundary_reached or haul_job_id.is_empty():
		return

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 5

	# Watches the haul job's own status rather than NeedGiver.get_pending_assignments():
	# once the scheduler actually gives the committed need job priority (issue
	# #267's committed_needs fix, replacing the old score-based restrict_to
	# race the interrupted haul job used to always win), a short-distance need
	# can commit, resolve, and hand the colonist straight back to the haul job
	# within a single world.tick() call -- too fast for between-tick sampling
	# to ever observe get_pending_assignments() (or get_active_need_job_id())
	# non-empty, even though the interrupt and the commit both genuinely
	# happened. The haul job going "active" -> "queued" is what an
	# interruption always looks like from JobQueue's own perspective (ADR
	# 009's suspend()), regardless of how quickly the replacing need resolves;
	# proof that a need job actually committed (not just that NeedGiver
	# suspended the haul job before searching) is recovered afterwards from
	# job/event history below, which -- unlike live polling -- cannot miss a
	# same-tick commit-then-resolve.
	var interrupted := false
	for _i in 60:
		world.tick()
		_expect(_total_wood_units(world) == 1,
			"wood must never be lost or duplicated while the need job commits (seed %d, tick %d)" % [seed_value, world.get_tick()])
		if String(_job_by_id(world, haul_job_id).get("status", "")) == "queued":
			interrupted = true
			break
	_expect(interrupted, "the food need must interrupt the haul job while carrying wood (seed %d)" % seed_value)
	if not interrupted:
		return

	var interrupted_colonist := world.get_colonists()[0]
	_expect(InventoryType.has_kind(interrupted_colonist, "wood"),
		"the colonist must still be carrying the wood the instant the need job commits (seed %d)" % seed_value)
	var paused_haul := _job_by_id(world, haul_job_id)
	_expect(String(paused_haul.get("status", "")) == "queued",
		"the interrupted haul job must be paused (queued, restricted back to this colonist), not terminated (seed %d)" % seed_value)

	# The item/destination cell reservations JobQueue._tick_haul() acquired at
	# activation (colonist-ai.md 3.4/#189) must not outlive the suspend() that
	# paused this job (JobQueue.suspend() -> ReservationTable.release_all()):
	# right after interruption they are either released (owner "") or, if
	# nothing has claimed them yet, still owned by this same haul job -- never
	# handed to a different job.
	var item_key := "item:item_1"
	var haul_cell = paused_haul.get("cell")
	var cell_key := "cell:%d,%d" % [int(haul_cell.x), int(haul_cell.y)] if haul_cell != null else ""
	_expect(_reservation_owner(world, item_key) in ["", haul_job_id],
		"the item reservation must be released or still owned by the resumed haul job right after interruption (seed %d)" % seed_value)
	if haul_cell != null:
		_expect(_reservation_owner(world, cell_key) in ["", haul_job_id],
			"the destination reservation must be released or still owned by the resumed haul job right after interruption (seed %d)" % seed_value)

	var completed := false
	for _i in 300:
		world.tick()
		_expect(_total_wood_units(world) == 1,
			"wood must never be lost or duplicated while the haul resumes (seed %d, tick %d)" % [seed_value, world.get_tick()])
		var ids := _wood_item_ids(world)
		# place() now always mints a fresh item id (issue #402: hands entries
		# have no id of their own to preserve across a pick_up/place round
		# trip), so the ground wood item's id may legitimately change once the
		# haul deposits it -- only "never more than one at a time" still holds.
		_expect(ids.size() <= 1,
			"the resumed haul must never spawn a second, duplicate wood item (seed %d, tick %d)" % [seed_value, world.get_tick()])
		var resumed_haul := _job_by_id(world, haul_job_id)
		if String(resumed_haul.get("status", "")) == "active":
			_expect(_reservation_owner(world, item_key) == haul_job_id,
				"the item reservation must be owned by the resumed haul job while it is active (seed %d, tick %d)" % [seed_value, world.get_tick()])
			if haul_cell != null:
				_expect(_reservation_owner(world, cell_key) == haul_job_id,
					"the destination reservation must be owned by the resumed haul job while it is active (seed %d, tick %d)" % [seed_value, world.get_tick()])
		else:
			_expect(_reservation_owner(world, item_key) in ["", haul_job_id],
				"the item reservation must never be owned by a different job while the haul resumes (seed %d, tick %d)" % [seed_value, world.get_tick()])
			if haul_cell != null:
				_expect(_reservation_owner(world, cell_key) in ["", haul_job_id],
					"the destination reservation must never be owned by a different job while the haul resumes (seed %d, tick %d)" % [seed_value, world.get_tick()])
		if String(resumed_haul.get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "the interrupted haul job must resume to completion under the same job id (seed %d)" % seed_value)

	# Job records persist after completion (world.get_jobs() never drops a
	# terminal job), so this recovers the need job's identity and outcome from
	# history rather than the racy live polling the comment above warns
	# against: a same-tick commit-then-resolve can never be missed here.
	var eat_food_job_id := ""
	for job in world.get_jobs():
		if String(job["kind"]) == "eat_food":
			eat_food_job_id = String(job["id"])
			break
	_expect(not eat_food_job_id.is_empty(),
		"the food need's interruption must have actually submitted an eat_food job, not merely suspended the haul job (seed %d)" % seed_value)
	_expect(String(_job_by_id(world, eat_food_job_id).get("status", "")) == "completed",
		"the committed eat_food job must actually complete during the interruption, before the haul finishes (seed %d)" % seed_value)
	var eat_food_completed_tick := _first_event_tick(world, "job_completed", eat_food_job_id)
	var haul_completed_tick := _first_event_tick(world, "job_completed", haul_job_id)
	_expect(eat_food_completed_tick >= 0,
		"a job_completed event must be recorded in history for the committed eat_food job (seed %d)" % seed_value)
	_expect(haul_completed_tick >= 0,
		"a job_completed event must be recorded in history for the resumed haul job (seed %d)" % seed_value)
	_expect(eat_food_completed_tick <= haul_completed_tick,
		"event history must show the eat_food job completing at or before the haul job finishes (seed %d)" % seed_value)
	_expect(world.get_ground_wood(10, 0) == 1,
		"the hauled wood must end at the stockpile destination, not lost or duplicated (seed %d)" % seed_value)
	_expect(not InventoryType.is_carrying(world.get_colonists()[0]),
		"the colonist must no longer be carrying anything once the haul completes (seed %d)" % seed_value)

## --- (c) a rest interrupt firing while a colonist carries wood mid-haul must
## actually complete sleep, not stall on arrival (round-6 review): sleep's
## toils ([reserve, go_to, work, release_all]) have no pick_up of their own,
## so ToilExecutor's is_first/_next_toil_after_go_to selection must be read
## off SLEEP's own declared sequence, never off the colonist's leftover
## is_carrying() flag from the paused haul job -- the raw flag reported
## sleep's single go_to as haul's "leg two" (pick_up already done), picked the
## no-op arrival, and the colonist repeated arrival forever without ever
## starting sleep's work timer. -----------------------------------------------
func _check_rest_interrupt_completes_sleep_while_carrying_wood(seed_value: int) -> void:
	if _failed:
		return
	var world := _build_haul_only_world(seed_value)
	_apply(world, "place_bed", "place_object", {"x": 0, "y": 5, "kind": "bed"})

	var boundary_reached := false
	var haul_job_id := ""
	for _i in 40:
		world.tick()
		if haul_job_id.is_empty():
			for job in world.get_jobs():
				if String(job["kind"]) == "haul":
					haul_job_id = String(job["id"])
		var colonist := world.get_colonists()[0]
		if InventoryType.is_carrying(colonist) and colonist.get("route") == null and colonist.get("work") == null:
			boundary_reached = true
			break
	_expect(boundary_reached, "setup must reach the post-pick_up toil boundary within budget (seed %d)" % seed_value)
	_expect(not haul_job_id.is_empty(), "HaulGiver must have auto-submitted a haul job (seed %d)" % seed_value)
	if not boundary_reached or haul_job_id.is_empty():
		return

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["rest"] = 5

	var interrupted := false
	for _i in 60:
		world.tick()
		if String(_job_by_id(world, haul_job_id).get("status", "")) == "queued":
			interrupted = true
			break
	_expect(interrupted, "the critical rest need must interrupt the haul job while carrying wood (seed %d)" % seed_value)
	if not interrupted:
		return
	var rest_interrupted_colonist := world.get_colonists()[0]
	_expect(InventoryType.has_kind(rest_interrupted_colonist, "wood"),
		"the colonist must still be carrying the wood the instant the rest interrupt commits (seed %d)" % seed_value)

	# Sleep's own work toil must genuinely start and tick down over more than
	# one tick while the wood stays carried, not stall at the go_to arrival
	# (the exact bug this check exists to catch). The sleep job itself may
	# take a few more ticks to commit after the haul job is suspended
	# (NeedGiver's own search), same as any other committed need job.
	var sleep_job_id := ""
	for _i in 40:
		world.tick()
		_expect(_total_wood_units(world) == 1,
			"wood must never be lost or duplicated while the sleep job commits (seed %d, tick %d)" % [seed_value, world.get_tick()])
		for job in world.get_jobs():
			if String(job["kind"]) == "sleep":
				sleep_job_id = String(job["id"])
		if not sleep_job_id.is_empty():
			break
	_expect(not sleep_job_id.is_empty(), "the rest interrupt must actually submit a sleep job (seed %d)" % seed_value)
	if sleep_job_id.is_empty():
		return

	var work_started := false
	var distinct_work_values: Dictionary = {}
	var sleep_completed := false
	for _i in 200:
		world.tick()
		_expect(_total_wood_units(world) == 1,
			"wood must never be lost or duplicated while sleep interrupts the haul (seed %d, tick %d)" % [seed_value, world.get_tick()])
		var colonist := world.get_colonists()[0]
		var work = colonist.get("work")
		if work != null:
			work_started = true
			distinct_work_values[int(work.get("ticks_remaining", -1))] = true
		if String(_job_by_id(world, sleep_job_id).get("status", "")) == "completed":
			sleep_completed = true
			break
	_expect(work_started, "sleep's own work toil must actually start, not stall at arrival, while the colonist carries wood (seed %d)" % seed_value)
	_expect(distinct_work_values.size() > 1,
		"sleep's work timer must tick down over more than one tick, not complete in a single sample (seed %d)" % seed_value)
	_expect(sleep_completed, "the interrupted-by-rest sleep job must complete within budget while wood stays carried (seed %d)" % seed_value)
	if not sleep_completed:
		return
	_expect(InventoryType.has_kind(world.get_colonists()[0], "wood"),
		"the carried wood must survive sleep completing (seed %d)" % seed_value)

	var haul_completed := false
	for _i in 300:
		world.tick()
		_expect(_total_wood_units(world) == 1,
			"wood must never be lost or duplicated while the haul resumes after sleep (seed %d, tick %d)" % [seed_value, world.get_tick()])
		if String(_job_by_id(world, haul_job_id).get("status", "")) == "completed":
			haul_completed = true
			break
	_expect(haul_completed, "the haul job must resume and complete after the sleep interrupt (seed %d)" % seed_value)
	_expect(world.get_ground_wood(10, 0) == 1,
		"the hauled wood must end at the stockpile destination after the sleep interrupt (seed %d)" % seed_value)
