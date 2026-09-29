extends SceneTree

## Covers issue #203: the needs decision layer (colonist-ai.md 3.1) drives a
## colonist with an urgent/critical food/water/rest need through a new
## eat_food/drink_water/sleep job -- reserve the nearest reachable unreserved
## source, walk there, consume/sleep, release -- using the same colonist.route/
## colonist.work fields and bounded routing/ search budget as any other
## assigned job, without touching the global fair scheduler (colonist-ai.md
## 3.1's layers 2/4 run before layer 5's work is even considered).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const JOBS_CONTENT_PATH := "res://content/jobs.json"
const NEEDS_CONTENT_PATH := "res://content/needs.json"

const MAX_TICKS := 400

var _failed := false

func _init() -> void:
	_check_content_declares_need_job_kinds()
	_check_eat_food_completes_and_restores_need()
	_check_mid_dig_finishes_before_eat_job_and_is_deterministic()
	_check_no_reachable_food_exposes_need_unmet_once_and_keeps_working()
	_check_two_colonists_one_berries_source()
	_check_blocked_source_reserved_then_need_unmet()
	_check_sleep_completes_and_releases_bed()
	_check_no_bed_reachable_reports_need_unmet_rest()
	_check_critical_need_interrupts_mid_dig_and_resumes_with_progress_kept()
	_check_prefers_shortest_real_route_over_closer_manhattan_candidate()
	_check_unreachable_need_job_resubmission_keeps_colonist_ownership()
	_check_urgent_need_interrupts_haul_at_toil_boundary()

	if _failed:
		quit(1)
		return
	print("test_need_jobs: PASS")
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

## Zeroes every need kind's decay rate except `kind`, so a scenario built
## around one need (food, say) is never disturbed by water/rest crossing
## their own "urgent" threshold over a long-running test and triggering their
## own, unrelated need job/onset. Each WorldState owns its own freshly-loaded
## _need_definitions Dictionary (see _load_need_definitions()), so mutating it
## here never leaks between test worlds.
func _isolate_need(world: WorldStateType, kind: String) -> void:
	for other in world._need_definitions.keys():
		if other != kind:
			world._need_definitions[other]["rate_per_day"] = 0

func _colonist(id: String, x: int, y: int, needs: Dictionary) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y, "needs": needs.duplicate(),
		"route": null, "work": null, "hands": []}

func _full_needs(overrides: Dictionary = {}) -> Dictionary:
	var needs := {"food": 100, "water": 100, "rest": 100}
	for kind in overrides:
		needs[kind] = overrides[kind]
	return needs

func _command(world: WorldStateType, command_id: String, type: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": type, "payload": payload})

func _colonist_by_id(world: WorldStateType, id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == id:
			return colonist
	return {}

func _jobs_of_kind(world: WorldStateType, kind: String) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	for job in world.get_jobs():
		if String(job["kind"]) == kind:
			jobs.append(job)
	return jobs

func _need_unmet_events(world: WorldStateType, colonist_id: String, kind: String = "") -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for event in world.get_events():
		if event["type"] != "need_unmet" or event["entity_id"] != colonist_id:
			continue
		if not kind.is_empty() and String(event["data"].get("kind", "")) != kind:
			continue
		found.append(event)
	return found

## game/content/jobs.json must declare eat_food/drink_water/sleep using
## reserve/go_to/consume|work/release_all, and toil_executor.gd's vocabulary
## must know "consume"; game/content/needs.json must declare a numeric
## "restore" per kind (colonist-ai.md 3.3).
func _check_content_declares_need_job_kinds() -> void:
	_expect(ToilExecutorType.is_known_toil("consume"), "toil_executor.gd must know the 'consume' toil")

	var jobs_file := FileAccess.open(JOBS_CONTENT_PATH, FileAccess.READ)
	if jobs_file == null:
		_expect(false, "could not open %s" % JOBS_CONTENT_PATH)
		return
	var jobs_parsed = JSON.parse_string(jobs_file.get_as_text())
	jobs_file.close()
	var by_kind: Dictionary = {}
	for entry in jobs_parsed["jobs"]:
		by_kind[entry["kind"]] = entry
	var expected := {
		"eat_food": ["reserve", "go_to", "consume", "release_all"],
		"drink_water": ["reserve", "go_to", "consume", "release_all"],
		"sleep": ["reserve", "go_to", "work", "release_all"],
	}
	for kind in expected:
		var entry = by_kind.get(kind)
		_expect(entry != null, "jobs.json must declare kind '%s'" % kind)
		if entry == null:
			continue
		for toil in entry.get("toils", []):
			_expect(ToilExecutorType.is_known_toil(String(toil)), "%s declares unknown toil '%s'" % [kind, toil])
		_expect(entry["toils"] == expected[kind], "%s must use toils %s (got %s)" % [kind, expected[kind], entry["toils"]])

	var needs_file := FileAccess.open(NEEDS_CONTENT_PATH, FileAccess.READ)
	if needs_file == null:
		_expect(false, "could not open %s" % NEEDS_CONTENT_PATH)
		return
	var needs_parsed = JSON.parse_string(needs_file.get_as_text())
	needs_file.close()
	for entry in needs_parsed["needs"]:
		_expect(typeof(entry.get("restore")) == TYPE_FLOAT or typeof(entry.get("restore")) == TYPE_INT,
			"needs.json '%s' must declare a numeric 'restore'" % entry.get("kind"))

## A hungry colonist with one reachable, unreserved ground-berries tile is
## assigned an eat_food job, reserves it, walks there, consumes it (need
## restored, ground berries decremented to zero and removed), and releases.
func _check_eat_food_completes_and_restores_need() -> void:
	var world := _build_world(50001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._ground_berries["5_0"] = 1

	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		for job in _jobs_of_kind(world, "eat_food"):
			if job["status"] == "completed":
				completed = true
		if completed:
			break
	_expect(completed, "the eat_food job must complete within the tick budget")
	if not completed:
		return

	var colonist := _colonist_by_id(world, "colonist_0")
	_expect(int(colonist["needs"]["food"]) == 100, "eating must restore food to full (got %s)" % colonist["needs"]["food"])
	_expect(world.get_ground_berries(5, 0) == 0, "eating must decrement ground berries to zero")
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved("tile:5,0"),
		"completing eat_food must release the source tile's reservation")
	_expect(world.get_colonist_need_reason("colonist_0") == "",
		"a satisfied need must expose no reason")

## A hungry colonist mid-dig must finish its current toil (the dig completes
## normally, tile changes as usual) before the eat job starts; total ticks
## stay within a declared bound; two seeded runs produce the same state_hash().
func _check_mid_dig_finishes_before_eat_job_and_is_deterministic() -> void:
	var mutate_at_tick := 20
	var total_ticks := 300

	var first := _run_mid_dig_then_eat_scenario(60001, mutate_at_tick, total_ticks)
	var second := _run_mid_dig_then_eat_scenario(60001, mutate_at_tick, total_ticks)

	_expect(first["dig_completed_tick"] >= 0, "the dig order must complete within the tick budget")
	_expect(first["eat_active_tick"] >= 0, "the eat_food job must become active within the tick budget")
	if first["dig_completed_tick"] >= 0 and first["eat_active_tick"] >= 0:
		_expect(first["dig_completed_tick"] < first["eat_active_tick"],
			"the dig job must complete (tick %d) strictly before the eat_food job activates (tick %d)"
				% [first["dig_completed_tick"], first["eat_active_tick"]])
	_expect(world_tile_is_trench(first["world"], 10, 0), "the dig target must become trench")

	_expect(first["world"].state_hash() == second["world"].state_hash(),
		"two identically-seeded runs of the same scenario must produce the same state_hash()")

func world_tile_is_trench(world: WorldStateType, x: int, y: int) -> bool:
	return world.get_tile(x, y) == WorldStateType.TILE_TRENCH

func _run_mid_dig_then_eat_scenario(seed_value: int, mutate_at_tick: int, total_ticks: int) -> Dictionary:
	var world := _build_world(seed_value)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs()))
	world._tiles[world._tile_index(10, 0)] = WorldStateType.TILE_SOIL
	world._ground_berries["15_0"] = 1
	world.spawn_ground_tool_item("pick", 0, 0)

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 0, "priority": 1})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result.get("job_id", ""))

	var dig_completed_tick := -1
	var eat_active_tick := -1
	for _i in total_ticks:
		world.tick()
		var tick_number := world.get_tick()
		if tick_number == mutate_at_tick:
			for i in world._colonists.size():
				if String(world._colonists[i]["id"]) == "colonist_0":
					world._colonists[i]["needs"]["food"] = 20
		# Issue #205 added a critical-need interrupt (colonist-ai.md 3.6): pin
		# food's decay rate to 0 the moment it drops to 20 (still above the
		# "critical" threshold of 10, only "urgent") so this scenario keeps
		# testing what it always tested -- an urgent need waiting for the toil
		# boundary -- rather than continuing to decay into "critical" mid-dig,
		# where an interrupt is now the correct, intended behavior.
		world._need_definitions["food"]["rate_per_day"] = 0
		if dig_completed_tick < 0:
			var dig_job := world._scheduler.queue.get_job(dig_job_id)
			if dig_job["status"] == "completed":
				dig_completed_tick = tick_number
		if eat_active_tick < 0:
			for job in _jobs_of_kind(world, "eat_food"):
				if job["status"] == "active":
					eat_active_tick = tick_number
	return {"world": world, "dig_completed_tick": dig_completed_tick, "eat_active_tick": eat_active_tick}

## With no reachable food source anywhere, the colonist exposes need_unmet:food,
## keeps working (a reachable, unrelated dig order still completes), and the
## alert is emitted exactly once for that onset, not once per tick, even
## across several retry-backoff cycles.
func _check_no_reachable_food_exposes_need_unmet_once_and_keeps_working() -> void:
	var world := _build_world(70001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._tiles[world._tile_index(5, 0)] = WorldStateType.TILE_SOIL
	world.spawn_ground_tool_item("pick", 0, 0)
	var dig_result := _command(world, "dig_1", "dig", {"x": 5, "y": 0, "priority": 1})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result.get("job_id", ""))

	var dig_completed := false
	for _i in 120:
		world.tick()
		var dig_job := world._scheduler.queue.get_job(dig_job_id)
		if dig_job["status"] == "completed":
			dig_completed = true

	_expect(world.get_colonist_need_reason("colonist_0") == "need_unmet:food",
		"with no reachable source the colonist must expose need_unmet:food (got '%s')"
			% world.get_colonist_need_reason("colonist_0"))
	_expect(dig_completed, "the colonist must keep working: the unrelated dig order must still complete")
	var events := _need_unmet_events(world, "colonist_0", "food")
	_expect(events.size() == 1, "the need_unmet alert must fire exactly once for the onset (got %d)" % events.size())

## Two colonists and one ground-berries source: exactly one colonist eats
## (need restored, berries gone); the other ends up need_unmet:food, since the
## single unit of food is now gone; no reservation is ever leaked.
func _check_two_colonists_one_berries_source() -> void:
	var world := _build_world(80001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._colonists.append(_colonist("colonist_1", 10, 0, _full_needs({"food": 20})))
	world._ground_berries["5_0"] = 1

	# Track "ever fed" as a sticky flag rather than colonist-needs' final value:
	# with only one unit of food total, the fed colonist eventually hungers
	# again and re-attempts (finding nothing), which would otherwise decay its
	# need back toward zero and flip its own reason back to need_unmet:food --
	# a second, later onset, not evidence the first colonist never ate.
	var ever_fed := {"colonist_0": false, "colonist_1": false}
	var resolved := false
	for _i in MAX_TICKS:
		world.tick()
		var orphans := ReservationInvariantsType.find_orphaned_reservations(
			world._scheduler.queue.get_reservation_table(), world.get_jobs())
		_expect(orphans.is_empty(), "no reservation may outlive its job mid-run: orphans=%s" % [orphans])
		for id in ever_fed:
			if int(_colonist_by_id(world, id)["needs"]["food"]) == 100:
				ever_fed[id] = true
		var unmet_now := 0
		for id in ever_fed:
			if world.get_colonist_need_reason(id) == "need_unmet:food":
				unmet_now += 1
		if world.get_ground_berries(5, 0) == 0 and (ever_fed["colonist_0"] or ever_fed["colonist_1"]) and unmet_now >= 1:
			resolved = true
			break
	_expect(resolved, "the scenario must settle (one fed, the other need_unmet) within the tick budget")

	var fed := 0
	var unmet := 0
	for id in ever_fed:
		if ever_fed[id]:
			fed += 1
		if world.get_colonist_need_reason(id) == "need_unmet:food":
			unmet += 1
	_expect(fed == 1, "exactly one colonist must have eaten (got %d)" % fed)
	_expect(unmet == 1, "exactly one colonist must end up need_unmet:food (got %d)" % unmet)
	_expect(world.get_ground_berries(5, 0) == 0, "the single berries unit must be fully consumed")

	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect(orphans.is_empty(), "no reservation may outlive its job at settle: orphans=%s" % [orphans])

## Deterministic exercise of the blocked_source_reserved reason (colonist-ai.md
## 3.8): the colonist's only candidate is far enough away that its bounded
## search spans several ticks; injecting a competing reservation mid-search
## (simulating another colonist winning the race) must be observed as
## blocked_source_reserved, and -- since no other candidate exists -- resolve
## to need_unmet:food once the candidate list is exhausted.
func _check_blocked_source_reserved_then_need_unmet() -> void:
	var world := _build_world(90001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._ground_berries["47_47"] = 1

	world.tick()
	_expect(_jobs_of_kind(world, "eat_food").is_empty(),
		"a far-away single candidate must still be searching after one tick (no job submitted yet)")

	for _i in 4:
		world.tick()
	_expect(_jobs_of_kind(world, "eat_food").is_empty(),
		"the search must still be in progress before the injected race (no job submitted yet)")

	var table := world._scheduler.queue.get_reservation_table()
	table.acquire("tile:47,47", "external_job")

	var saw_blocked := false
	var saw_unmet := false
	for _i in 60:
		world.tick()
		var reason := world.get_colonist_need_reason("colonist_0")
		if reason == "blocked_source_reserved":
			saw_blocked = true
		if reason == "need_unmet:food":
			saw_unmet = true
	_expect(saw_blocked, "the colonist must observe blocked_source_reserved once its search finds the now-taken source")
	_expect(saw_unmet, "with the only candidate taken, the colonist must end up need_unmet:food")
	table.release("tile:47,47", "external_job")

## A colonist with an urgent rest need and a reachable unreserved bed reserves
## it, sleeps for the declared duration, and the bed's reservation is released
## after.
func _check_sleep_completes_and_releases_bed() -> void:
	var world := _build_world(100001)
	_isolate_need(world, "rest")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"rest": 20})))
	var place_result := _command(world, "place_bed", "place_object", {"x": 5, "y": 0, "kind": "bed"})
	_expect(place_result["ok"], "placing the bed fixture object must be accepted")

	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		for job in _jobs_of_kind(world, "sleep"):
			if job["status"] == "completed":
				completed = true
		if completed:
			break
	_expect(completed, "the sleep job must complete within the tick budget")
	if not completed:
		return

	var colonist := _colonist_by_id(world, "colonist_0")
	# The bed at (5, 0) sits on open floor with no enclosing walls/door, so it
	# is not inside a recognised room (F5 "Rooms"): rest restores by content's
	# plain "restore" value (100, unaffected by needs.json's
	# bedroom_rest_multiplier), not a scaled value -- see test_rooms.gd for the
	# bedroom-vs-ordinary-bed comparison with an isolated test config where the
	# multiplier's effect is directly observable.
	_expect(int(colonist["needs"]["rest"]) == 100, "sleeping in an ordinary bed must restore rest by the plain content value (got %s)" % colonist["needs"]["rest"])
	_expect(world.get_object(5, 0) == "bed", "sleeping must not remove the bed object")
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved("tile:5,0"),
		"completing sleep must release the bed's reservation")

## With no bed reachable anywhere, the colonist's reason exposes need_unmet:rest
## (colonist-ai.md 3.8's documented vocabulary; normalized from this task's own
## prose, which also names "need_source_missing:bed" for the same condition --
## see the handoff) and it never sleeps.
func _check_no_bed_reachable_reports_need_unmet_rest() -> void:
	var world := _build_world(110001)
	_isolate_need(world, "rest")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"rest": 20})))

	for _i in 60:
		world.tick()

	_expect(world.get_colonist_need_reason("colonist_0") == "need_unmet:rest",
		"with no reachable bed the colonist must expose need_unmet:rest (got '%s')"
			% world.get_colonist_need_reason("colonist_0"))
	var colonist := _colonist_by_id(world, "colonist_0")
	_expect(int(colonist["needs"]["rest"]) < 100, "the colonist must never have slept")
	_expect(_jobs_of_kind(world, "sleep").is_empty(), "no sleep job may ever be created with no bed reachable")

## Issue #241 review round 1 (ADR 009): a critical need must interrupt a
## colonist's in-progress dig immediately (colonist-ai.md 3.6), and the
## interrupted job must go back through the scheduler's own waiting queue
## with its aging preserved -- not merely left invisible with only the
## worker's own assignment cleared -- while the tile keeps its partial work
## progress. The interrupt also releases the job's own target reservation
## (colonist-ai.md 3.4: a reservation only exists while its job is actually
## being advanced), so `queued`, not `active`, is the correct JobQueue status
## for the whole interrupt window. A second, otherwise-idle colonist must
## never be offered either the interrupted dig job (restrict_to keeps it tied
## to colonist_0, even though its reservation is released) or the eat_food job
## NeedGiver submitted for colonist_0 alone (restrict_to), proving the
## completion effect can only ever land on the colonist whose need actually
## created the job.
func _check_critical_need_interrupts_mid_dig_and_resumes_with_progress_kept() -> void:
	var world := _build_world(120001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 9, 0, _full_needs()))
	world._colonists.append(_colonist("colonist_1", 20, 20, _full_needs()))
	world._tiles[world._tile_index(10, 0)] = WorldStateType.TILE_SOIL
	# Far enough that the eat_food search/walk spans several ticks, so the
	# interrupted dig job's requeued-in-waiting representation is actually
	# observable before the need job resolves and resumes it, rather than
	# both collapsing into the same tick.
	world._ground_berries["9_20"] = 1
	world.spawn_ground_tool_item("pick", 9, 0)

	var dig_result := _command(world, "dig_1", "dig", {"x": 10, "y": 0, "priority": 1})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result.get("job_id", ""))

	var work_started := false
	for _i in 30:
		world.tick()
		if _colonist_by_id(world, "colonist_0").get("work") != null:
			work_started = true
			break
	_expect(work_started, "colonist_0 must start the dig job's work toil within the tick budget")
	if not work_started:
		return

	# Let a few ticks of real work progress accumulate before interrupting.
	for _i in 5:
		world.tick()

	var activated: Dictionary = world._scheduler.get_activated_entries()
	_expect(activated.has(dig_job_id), "the dig job's original waiting entry must be tracked once active")
	var original_entry: Dictionary = activated.get(dig_job_id, {})

	var dig_target_key := "10_0"
	var progress_before := int(world._work_progress.get(dig_target_key, -1))
	_expect(progress_before > 0 and progress_before < int(world._work_ticks["dig"]),
		"real (partial) work progress must exist before the interrupt (got %d)" % progress_before)

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 5

	world.tick()

	_expect(_colonist_by_id(world, "colonist_0").get("work") == null,
		"a critical need must interrupt the colonist's work toil immediately")
	_expect(String(world._scheduler.queue.get_job(dig_job_id).get("status", "")) == "queued",
		"the interrupted job must return to queued, never cancelled (ADR 009: reservation released, not held)")
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved("tile:10,0"),
		"a critical interrupt must release the interrupted job's own target reservation (ADR 009)")

	var requeued_entry := {}
	for entry in world._scheduler.get_waiting():
		if String(entry["id"]) == dig_job_id:
			requeued_entry = entry
	_expect(not requeued_entry.is_empty(),
		"a critical interrupt must put the interrupted job back in the scheduler's own waiting queue")
	if not requeued_entry.is_empty():
		_expect(int(requeued_entry["base"]) == int(original_entry["base"])
			and int(requeued_entry["submitted_tick"]) == int(original_entry["submitted_tick"])
			and int(requeued_entry["ordinal"]) == int(original_entry["ordinal"]),
			"the requeued entry must keep its exact original aging/ordinal, not a freshly-timestamped one")
		_expect(String(requeued_entry.get("restrict_to", "")) == "colonist_0",
			"the requeued entry must be restricted to the colonist it was interrupted from (ADR 009)")

	# Round-6 review (#278/#303): a suspended job's progress moves OUT of the
	# shared tile cache into per-job storage (world_state.gd's own
	# _suspend_work_progress()), so a different job that later works the same
	# tile can never inherit or clobber it -- checked here instead of
	# world._work_progress, which is now empty for a suspended job.
	_expect(int(world._suspended_work_progress.get(dig_job_id, -1)) == progress_before,
		"the interrupted work toil's own progress must be kept, not reset")
	_expect(not world._work_progress.has(dig_target_key),
		"a suspended job's tile-cache entry must be cleared, not left for a different job to inherit")

	var eat_completed := false
	var dig_completed := false
	var colonist_1_ever_assigned := false
	var colonist_0_ever_fed := false
	for _i in 300:
		world.tick()
		for job in _jobs_of_kind(world, "eat_food"):
			if job["status"] == "completed":
				eat_completed = true
		if int(_colonist_by_id(world, "colonist_0")["needs"]["food"]) == 100:
			colonist_0_ever_fed = true
		if world._scheduler.get_assignments().has("colonist_1"):
			colonist_1_ever_assigned = true
		if world._scheduler.queue.get_job(dig_job_id)["status"] == "completed":
			dig_completed = true
		if eat_completed and dig_completed:
			break

	_expect(eat_completed, "the eat_food job must complete within the tick budget")
	_expect(dig_completed, "the interrupted dig job must resume and complete, not be lost")
	_expect(not colonist_1_ever_assigned,
		"an otherwise-idle second colonist must never be offered the restricted eat_food job or the restrict_to-protected dig job")
	_expect(world_tile_is_trench(world, 10, 0), "the resumed dig job must still finish transforming its target tile")
	_expect(not world._work_progress.has(dig_target_key),
		"a completed job must clear its tile's work-progress entry")
	_expect(colonist_0_ever_fed,
		"the interrupted colonist's own food need must be restored at some point, not some other colonist's")

## Issue #241 review round 2: NeedGiver must pick the source with the
## shortest real (bounded-route) path, not the one with the smallest
## straight-line Manhattan distance. The colonist starts at (0,0); candidate
## A sits inside a walled 21x21 box whose only entrance is a single gap on
## the box's far side, so its real route is well over 60 tiles even though
## its Manhattan distance (4) is the smaller of the two; candidate B sits on
## a fully clear straight path with Manhattan distance 20 -- also its real
## route length, since nothing blocks it. A colonist that committed to A
## anyway (the exact defect flagged in review round 2, which sorted and
## committed by Manhattan distance alone) would pick the far, walled source
## over the truly nearest reachable one.
func _check_prefers_shortest_real_route_over_closer_manhattan_candidate() -> void:
	var world := _build_world(130001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))

	for x in range(1, 22):
		world._set_object(x, 1, "wall")
		world._set_object(x, 21, "wall")
	for y in range(1, 22):
		world._set_object(1, y, "wall")
		if y != 11:
			world._set_object(21, y, "wall")
	world._ground_berries["2_2"] = 1
	world._ground_berries["0_20"] = 1

	var job := {}
	for _i in 300:
		world.tick()
		var jobs := _jobs_of_kind(world, "eat_food")
		if not jobs.is_empty():
			job = jobs[0]
			break

	_expect(not job.is_empty(), "an eat_food job must be submitted within the tick budget")
	if job.is_empty():
		return
	var target: Vector2i = job["target"]
	_expect(target == Vector2i(0, 20),
		("NeedGiver must choose the shorter real route (0,20), not the Manhattan-nearer "
			+ "but route-blocked (2,2) (got %s)") % [target])

## Issue #241 review round 1 (ADR 009): when a need job's first-leg target
## becomes unreachable, WorldState cancels and resubmits it under a fresh id
## (colonist-ai.md 3.3) -- NeedGiver's own ownership association must follow
## the new id, restricted to the same colonist, rather than being dropped.
## Dropping it (the pre-fix behavior) let the fair scheduler hand the
## replacement job to any colonist while telling the original one its need
## was already met, so it resumed its interrupted work with the need still
## unsatisfied.
func _check_unreachable_need_job_resubmission_keeps_colonist_ownership() -> void:
	var world := _build_world(140001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs({"food": 20})))
	world._ground_berries["5_0"] = 1

	var original_job_id := ""
	for _i in 100:
		world.tick()
		var jobs := _jobs_of_kind(world, "eat_food")
		if not jobs.is_empty():
			original_job_id = String(jobs[0]["id"])
			break
	_expect(not original_job_id.is_empty(), "an eat_food job must be submitted within the tick budget")
	if original_job_id.is_empty():
		return
	_expect(world._need_giver.get_pending_job("colonist_0") == original_job_id,
		"NeedGiver must track the original job as colonist_0's pending need job")

	var job := world._scheduler.queue.get_job(original_job_id)
	world._resubmit_unreachable_job(original_job_id, job)

	_expect(String(world._scheduler.queue.get_job(original_job_id).get("status", "")) == "cancelled",
		"resubmission must cancel the original job id")
	var new_job_id := world._need_giver.get_pending_job("colonist_0")
	_expect(not new_job_id.is_empty() and new_job_id != original_job_id,
		"resubmission must move colonist_0's pending job to the fresh id, not drop the association")
	var new_entry := {}
	for entry in world._scheduler.get_waiting():
		if String(entry["id"]) == new_job_id:
			new_entry = entry
	_expect(String(new_entry.get("restrict_to", "")) == "colonist_0",
		"the resubmitted need job must stay restricted to the colonist whose need created it")

## Issue #241 review round 2: an urgent need reaching this module's evaluation
## exactly at a toil boundary (colonist-ai.md 3.6) must interrupt whatever
## active job the colonist still holds through the shared scheduler, not just
## wait for colonist.route/work to go null. A haul job idles between its
## instant pick_up/place toils -- neither sets colonist.route or colonist.work
## -- so the colonist looks idle at world_state level while its haul job's own
## scheduler assignment is still live. The finding this regresses: without
## suspending that assignment, GlobalAssignment.tick() skips this worker (it
## already has one), so the restricted need job would sit "queued" forever --
## never even proposed for colonist_0 -- until the haul job finishes entirely
## on its own, rather than being freed to compete for the worker like ADR
## 009's existing critical-need interrupt already does for a `work` toil.
## This exercises the go_to -> pick_up boundary specifically: the suspended
## haul job must go back to "queued" with its item/cell reservations released
## (mirroring the dig/eat_food critical-need test's own assertions), and both
## jobs must eventually complete, with the haul job resuming (not restarting
## or losing its carried/target item) once the need resolves.
func _check_urgent_need_interrupts_haul_at_toil_boundary() -> void:
	var world := _build_world(160001)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0, _full_needs()))
	world._items["item_1"] = {"id": "item_1", "x": 9, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	world._ground_berries["9_5"] = 1
	var zone_result := _command(world, "zone1", "zone_add", {"x": 5, "y": 1, "width": 1, "height": 1})
	_expect(zone_result["ok"], "the haul destination zone_add must be accepted")

	var haul_job_id := ""
	for _i in 60:
		world.tick()
		var jobs := _jobs_of_kind(world, "haul")
		if not jobs.is_empty():
			haul_job_id = String(jobs[0]["id"])
			break
	_expect(not haul_job_id.is_empty(), "the haul job must auto-submit within the tick budget")
	if haul_job_id.is_empty():
		return

	# Tick until colonist_0 sits exactly at the go_to -> pick_up toil boundary:
	# arrived (route null), pick_up not yet run this tick (carrying null), with
	# the haul job's own scheduler assignment still live.
	var at_boundary := false
	for _i in MAX_TICKS:
		world.tick()
		var colonist := _colonist_by_id(world, "colonist_0")
		if InventoryType.is_carrying(colonist):
			break
		if colonist.get("route") == null and colonist.get("work") == null \
				and world._scheduler.get_assignments().has("colonist_0"):
			at_boundary = true
			break
	_expect(at_boundary, "colonist_0 must reach the go_to -> pick_up toil boundary before picking up")
	if not at_boundary:
		return
	_expect(String(world._scheduler.queue.get_job(haul_job_id).get("status", "")) == "active",
		"the haul job must still be active at the toil boundary, not yet finished")
	var item_key := "item:item_1"
	var cell_key := "cell:%d,%d" % [int(world._scheduler.queue.get_job(haul_job_id)["cell"].x),
		int(world._scheduler.queue.get_job(haul_job_id)["cell"].y)]
	_expect(world._scheduler.queue.get_reservation_table().is_reserved(item_key),
		"the active haul job must hold its item reservation at the toil boundary")

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 20
	world.tick()

	_expect(String(world._scheduler.queue.get_job(haul_job_id).get("status", "")) == "queued",
		"an urgent need reaching a toil boundary must suspend the colonist's still-active haul job back to queued")
	_expect(world._paused_jobs.get("colonist_0", "") == haul_job_id,
		"the interrupt must record the haul job as paused for colonist_0")
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved(item_key),
		"suspending the haul job must release its item reservation (colonist-ai.md 3.4)")
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved(cell_key),
		"suspending the haul job must release its destination-cell reservation (colonist-ai.md 3.4)")
	var requeued := {}
	for entry in world._scheduler.get_waiting():
		if String(entry["id"]) == haul_job_id:
			requeued = entry
	_expect(not requeued.is_empty(), "the interrupted haul job must go back into the scheduler's own waiting queue")
	_expect(String(requeued.get("restrict_to", "")) == "colonist_0",
		"the requeued haul job must stay restricted to the colonist it was interrupted from")

	var eat_completed := false
	var haul_completed := false
	var colonist_0_ever_fed := false
	for _i in MAX_TICKS:
		world.tick()
		for job in _jobs_of_kind(world, "eat_food"):
			if job["status"] == "completed":
				eat_completed = true
		if int(_colonist_by_id(world, "colonist_0")["needs"]["food"]) == 100:
			colonist_0_ever_fed = true
		if world._scheduler.queue.get_job(haul_job_id)["status"] == "completed":
			haul_completed = true
		if eat_completed and haul_completed:
			break

	_expect(eat_completed, "the urgent eat_food job must eventually complete for colonist_0")
	_expect(colonist_0_ever_fed, "the interrupted colonist's own food need must be restored")
	_expect(haul_completed, "the interrupted haul job must resume and eventually complete, not be lost")
	# place() now always mints a fresh item id (issue #402: hands entries have
	# no id of their own to preserve across a pick_up/place round trip), so
	# the delivered item is found by kind, not by its original "item_1" id.
	var delivered := {}
	for item in world._items.values():
		if String(item["kind"]) == "wood":
			delivered = item
	_expect(not delivered.is_empty(), "the delivered item must still exist on the ground, in its stockpile cell")
	if not delivered.is_empty():
		_expect(int(delivered["x"]) == 5 and int(delivered["y"]) == 1,
			"the resumed haul job must still deliver the item to its reserved stockpile cell (got %s,%s)"
				% [delivered["x"], delivered["y"]])
