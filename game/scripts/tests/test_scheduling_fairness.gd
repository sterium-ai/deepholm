extends SceneTree

const WorldType = preload("res://scripts/core/world_state.gd")
const SchedulerType = preload("res://scripts/core/scheduling/global_assignment.gd")
const RouteType = preload("res://scripts/core/routing/route_search.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

const MAX_WAIT := 300
const ARRIVAL_TICKS := 600
var _failed := false

func _init() -> void:
	var first := _run_load()
	var second := _run_load()
	_expect(first["hash"] == second["hash"], "seeded load state hashes must match")
	_expect(first["events"] == second["events"], "seeded load event order must match")
	_check_aging()
	_check_partial_routes_and_cancel()
	_check_global_matching()
	_check_route_cost_changes_choice()
	_check_blocked_prefix()
	_check_labour_mix_still_meets_bound()
	_check_enclosed_unreachable_zero_expansions()
	if _failed:
		quit(1)
		return
	print("test_scheduling_fairness: PASS (260 orders/run, zero starved, max wait %d ticks)" % first["max_wait"])
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## Arrange initial authoritative state before commands; no scenes or execution
## mechanics are loaded. The surrounding 48x48 world is impassable rock.
func _world() -> WorldType:
	var world := WorldType.new(47)
	world._tiles.fill(WorldType.TILE_ROCK)
	# issue #300: clear any generator-placed berry_bush (docs/decisions/020)
	# before overwriting tiles, so it can never sit inside this fixture's own
	# 20x10 soil pocket.
	world._objects.clear()
	world._object_factions.clear()
	for y in 10:
		for x in 20:
			world._tiles[y * WorldType.MAP_WIDTH + x] = WorldType.TILE_SOIL
	world._colonists.clear()
	for i in 8:
		world._colonists.append({"id": "colonist_%d" % i, "kind": "colonist", "x": i * 2, "y": 5})
	# Already held: this is ADR 004's own fairness/service-bound proof, wholly
	# unrelated to tools, and the fixture completes every active job by
	# explicit command before the next tick() -- with no pick, dig's own
	# fetch_tool toil would instead fail every order the instant it activates,
	# the same tick, before that command ever runs (issue #271).
	for i in 8:
		world.set_tool_item_held(world.spawn_ground_tool_item("pick", i * 2, 5), "colonist_%d" % i)
	return world

func _command(world: WorldType, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": "%s_%d" % [kind, world.get_events().size()],
		"tick": world.get_tick(), "type": kind, "payload": payload})

func _submit(world: WorldType, target: Vector2i, priority: int, submitted: Dictionary) -> void:
	var result := _command(world, "dig", {"x": target.x, "y": target.y, "priority": priority})
	_expect(result["ok"], "load order must be accepted")
	if result["ok"]:
		submitted[result["job_id"]] = world.get_tick()

func _check_metrics(world: WorldType) -> void:
	var metrics := world.get_scheduling_metrics()
	_expect(metrics.size() == world.get_colonists().size(), "every worker must have tick telemetry")
	for worker in metrics:
		var usage: Dictionary = metrics[worker]
		_expect(usage["job_evaluations"] >= 0 and usage["job_evaluations"] <= 32, "job evaluations exceed 32")
		_expect(usage["route_steps"] >= 0 and usage["route_steps"] <= 64, "actual route expansions exceed 64")
		_expect(usage["route_calls"] <= 1, "a worker resumed more than one route in a tick")
	_expect(RouteType.STEP_BUDGET == 64, "router budget contract changed")
	_expect(SchedulerType.JOB_EVALUATION_BUDGET == 32, "evaluation budget contract changed")

func _run_load() -> Dictionary:
	var world := _world()
	var submitted: Dictionary = {}
	var started: Dictionary = {}
	var max_wait := 0
	var saw_partial := false
	var saw_full_evaluation_budget := false
	for i in 200:
		_submit(world, Vector2i(i % 20, i / 20), i % 3, submitted)
	for step in range(1, ARRIVAL_TICKS + MAX_WAIT + 1):
		# Controlled one-tick execution fixture: completion frees t2 reservations.
		for job in world.get_jobs():
			if job["status"] == "active":
				_expect(_command(world, "complete_job", {"job_id": job["id"]})["ok"], "completion failed")
		if step <= ARRIVAL_TICKS and step % 10 == 0:
			var queued_targets: Dictionary = {}
			for job in world.get_jobs():
				if job["status"] == "queued":
					queued_targets[job["target"]] = true
			var arrival_target := Vector2i(-1, -1)
			for i in 200:
				var target := Vector2i(i % 20, i / 20)
				if not queued_targets.has(target):
					arrival_target = target
					break
			_expect(arrival_target.x >= 0, "arrival requires a completed unique target")
			_submit(world, arrival_target, 2, submitted)
		world.tick()
		_check_metrics(world)
		for usage in world.get_scheduling_metrics().values():
			saw_partial = saw_partial or usage["route_steps"] == 64
			saw_full_evaluation_budget = saw_full_evaluation_budget or usage["job_evaluations"] == 32
		var active_count := 0
		for job in world.get_jobs():
			if job["status"] == "active":
				active_count += 1
				_expect(not started.has(job["id"]), "job activated more than once")
				started[job["id"]] = step
				max_wait = maxi(max_wait, step - int(submitted[job["id"]]))
			if not started.has(job["id"]):
				_expect(job["status"] == "queued" and job["reason"] == "", "load order ceased to be continuously eligible")
				_expect(step - int(submitted[job["id"]]) <= MAX_WAIT, "eligible order exceeded 300 ticks")
		_expect(active_count <= 8 and active_count == world.get_assignments().size(), "assignments must be one-to-one")
	_expect(submitted.size() == 260, "full workload must include 200 initial and 60 arriving orders")
	_expect(started.size() == submitted.size(), "zero starvation: every submitted order must start")
	_expect(max_wait <= MAX_WAIT, "maximum service wait exceeded 300 ticks")
	_expect(saw_partial and saw_full_evaluation_budget, "load must exercise both budget boundaries")
	var event_starts: Dictionary = {}
	for event in world.get_events():
		if event["type"] == "job_active":
			_expect(not event_starts.has(event["entity_id"]), "duplicate active event")
			event_starts[event["entity_id"]] = event["tick"]
	_expect(event_starts == started, "start assertions must match actual queue transition events")
	return {"hash": world.state_hash(), "events": world.get_events(), "max_wait": max_wait}

## Issue #267: with a mix of labour levels across the 8 colonists (colonist_0's
## "mine" fully off, the rest varied 1..4) instead of every colonist left at
## its ADR 004 default, the same workload's service bound must still hold for
## every colonist whose labour remains enabled -- colonist_0 simply never
## receives a dig job (colonist-ai.md 3.2's eligibility filter), leaving 7
## effective workers for a workload with ample slack for 8.
func _check_labour_mix_still_meets_bound() -> void:
	var world := _world()
	var levels := [0, 1, 2, 4, 3, 4, 2, 3]
	for i in world._colonists.size():
		# _world()'s hand-built colonists skip _spawn_colonists(), so they carry
		# no labourTable yet (WorldState only backfills one via _ensure_needs()
		# from state_hash()/to_save_state()/_decay_needs(), none of which have
		# run at this point) -- assign the full default table before overriding
		# "mine", rather than mutating a key that does not exist yet.
		var table := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
		table["mine"] = levels[i % levels.size()]
		world._colonists[i]["labourTable"] = table
	var submitted: Dictionary = {}
	var started: Dictionary = {}
	var max_wait := 0
	for i in 200:
		_submit(world, Vector2i(i % 20, i / 20), i % 3, submitted)
	for step in range(1, ARRIVAL_TICKS + MAX_WAIT + 1):
		for job in world.get_jobs():
			if job["status"] == "active":
				_expect(_command(world, "complete_job", {"job_id": job["id"]})["ok"], "completion failed")
		if step <= ARRIVAL_TICKS and step % 10 == 0:
			var queued_targets: Dictionary = {}
			for job in world.get_jobs():
				if job["status"] == "queued":
					queued_targets[job["target"]] = true
			var arrival_target := Vector2i(-1, -1)
			for i in 200:
				var target := Vector2i(i % 20, i / 20)
				if not queued_targets.has(target):
					arrival_target = target
					break
			_expect(arrival_target.x >= 0, "arrival requires a completed unique target")
			_submit(world, arrival_target, 2, submitted)
		world.tick()
		for job in world.get_jobs():
			if job["status"] == "active":
				started[job["id"]] = step
				max_wait = maxi(max_wait, step - int(submitted[job["id"]]))
			elif not started.has(job["id"]):
				_expect(step - int(submitted[job["id"]]) <= MAX_WAIT,
					"eligible order exceeded 300 ticks under a mixed labour table")
	_expect(started.size() == submitted.size(), "zero starvation must hold with a mixed labour table too")
	_expect(max_wait <= MAX_WAIT, "maximum service wait exceeded 300 ticks under a mixed labour table")

func _check_aging() -> void:
	var world := _world()
	world._colonists.resize(1)
	var submitted: Dictionary = {}
	_submit(world, Vector2i(19, 9), 0, submitted)
	var low_id: String = submitted.keys()[0]
	var low_started := false
	for step in MAX_WAIT:
		for job in world.get_jobs():
			if job["status"] == "active":
				_command(world, "complete_job", {"job_id": job["id"]})
		_submit(world, Vector2i(0, 5), 2, submitted)
		world.tick()
		_check_metrics(world)
		for job in world.get_jobs():
			if job["id"] == low_id and job["status"] == "active":
				low_started = true
		if low_started:
			break
	_expect(low_started, "aging must serve distant LOW work under one HIGH arrival every tick")

func _check_partial_routes_and_cancel() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 47
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var workers: Array[Dictionary] = [{"id": "worker", "kind": "colonist", "x": 0, "y": 0}]
	var passable := func(tile: Vector2i) -> bool: return tile.y == 0
	var job_id: String = scheduler.submit(Vector2i(130, 0), 1, 0)["job_id"]
	scheduler.tick(1, workers, passable, Vector2i.ZERO, Vector2i(130, 0))
	_expect(scheduler._pending.has("worker"), "first route slice must leave a pending request")
	if not scheduler._pending.has("worker"):
		return
	var route: RefCounted = scheduler._pending["worker"]["route"]
	_expect(scheduler.queue.get_job(job_id)["status"] == "queued", "partial route must not activate work")
	_expect(scheduler.get_metrics()["worker"]["route_steps"] == 64, "first slice must expand 64 tiles")
	scheduler.tick(2, workers, passable, Vector2i.ZERO, Vector2i(130, 0))
	_expect(scheduler._pending.has("worker"), "second route slice must remain pending")
	if not scheduler._pending.has("worker"):
		return
	_expect(scheduler._pending["worker"]["route"] == route, "route identity must persist between ticks")
	_expect(scheduler.get_metrics()["worker"]["job_evaluations"] == 0, "pending evaluation must not restart")
	scheduler.tick(3, workers, passable, Vector2i.ZERO, Vector2i(130, 0))
	_expect(scheduler.queue.get_job(job_id)["status"] == "active", "third slice must finish retained search")
	_expect(scheduler.get_metrics()["worker"]["route_steps"] == 2, "third slice must expand only the final two tiles")
	scheduler.finish(job_id, "cancel_job")
	_expect(scheduler.queue.get_reservations().is_empty(), "cancel must release target")
	var second: String = scheduler.submit(Vector2i(130, 0), 1, 3)["job_id"]
	scheduler.tick(4, workers, passable, Vector2i.ZERO, Vector2i(130, 0))
	scheduler.finish(second, "cancel_job")
	_expect(scheduler._pending.is_empty(), "cancel must discard pending route")
	scheduler.tick(5, workers, passable, Vector2i.ZERO, Vector2i(130, 0))
	_expect(scheduler.get_assignments().is_empty(), "cancelled search must never activate")

func _check_global_matching() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 47
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	# First worker is far away: a per-worker grab loop would take the wrong pair.
	var workers: Array[Dictionary] = [{"id": "a", "kind": "colonist", "x": 0, "y": 0}, {"id": "b", "kind": "colonist", "x": 9, "y": 0}]
	var job_id: String = scheduler.submit(Vector2i(9, 0), 1, 0)["job_id"]
	scheduler.tick(1, workers, func(_tile: Vector2i) -> bool: return true, Vector2i.ZERO, Vector2i(9, 0))
	_expect(scheduler.get_assignments().has("b"), "global matching must choose the closer worker regardless of ID order")
	if not scheduler.get_assignments().has("b"):
		return
	_expect(scheduler.get_assignments()["b"]["job_id"] == job_id, "chosen job must match")
	_expect(scheduler.get_assignments()["b"]["travel_ticks"] == 0, "travel estimate must come from the found route")

func _check_blocked_prefix() -> void:
	var world := _world()
	world._colonists.resize(2)
	var submitted: Dictionary = {}
	_submit(world, Vector2i(0, 5), 2, submitted)
	world.tick() # Keep this assignment active to reserve the shared target.
	for i in 40:
		_submit(world, Vector2i(0, 5), 2, submitted)
	_submit(world, Vector2i(2, 5), 0, submitted)
	var last_id: String = submitted.keys().back()
	for i in 5:
		world.tick()
		_check_metrics(world)
	var found := false
	for job in world.get_jobs():
		if job["id"] == last_id:
			found = job["status"] == "active"
	_expect(found, "persistent evaluation cursor must bypass a reserved prefix longer than 32")

## F5 "Regions" (issue #292): a dig target walled off from every colonist by
## rock on all four sides must never even construct a RouteSearch for it --
## the region pre-check proves it unreachable up front, so telemetry records
## zero route expansions/resumes across every tick, and the job never activates.
func _check_enclosed_unreachable_zero_expansions() -> void:
	var world := _world()
	world._tiles[30 * WorldType.MAP_WIDTH + 30] = WorldType.TILE_SOIL
	var target := Vector2i(30, 30)
	var submitted: Dictionary = {}
	_submit(world, target, 2, submitted)
	var job_id: String = submitted.keys()[0]
	for step in 5:
		world.tick()
		for usage in world.get_scheduling_metrics().values():
			_expect(usage["route_steps"] == 0, "an enclosed unreachable target must record zero route expansions")
			_expect(usage["route_calls"] == 0, "an enclosed unreachable target must never resume a route search")
	var status := ""
	for job in world.get_jobs():
		if job["id"] == job_id:
			status = job["status"]
	_expect(status == "queued", "an enclosed unreachable target must never activate")

func _check_route_cost_changes_choice() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 47
	var scheduler := SchedulerType.new(random, ContentRegistryType.new())
	var workers: Array[Dictionary] = [{"id": "worker", "kind": "colonist", "x": 0, "y": 0}]
	var passable := func(tile: Vector2i) -> bool: return tile.x != 1 or tile.y >= 3
	var near_id: String = scheduler.submit(Vector2i(2, 0), 1, 0)["job_id"]
	var quick_id: String = scheduler.submit(Vector2i(0, 4), 1, 0)["job_id"]
	scheduler.tick(1, workers, passable, Vector2i.ZERO, Vector2i(3, 4))
	_expect(scheduler.get_assignments().is_empty(), "retain first result until the second candidate is evaluated")
	var snapshot := scheduler.snapshot()
	_expect(snapshot["pending"].has("worker"), "evaluation batch must remain pending")
	if not snapshot["pending"].has("worker"):
		return
	_expect(snapshot["pending"]["worker"]["cursor"] == 1, "partial evaluation cursor must persist")
	scheduler.tick(2, workers, passable, Vector2i.ZERO, Vector2i(3, 4))
	var assignments := scheduler.get_assignments()
	_expect(assignments.has("worker"), "completed batch must assign a worker")
	if assignments.has("worker"):
		_expect(assignments["worker"]["job_id"] == quick_id, "actual route cost must overturn Manhattan-nearest choice")
		_expect(assignments["worker"]["travel_ticks"] == 4, "chosen router travel estimate must be four steps")
	_expect(scheduler.queue.get_job(near_id)["status"] == "queued", "unused route candidate must remain eligible")
	_expect(scheduler.get_metrics()["worker"]["job_evaluations"] == 0, "second candidate resumes the existing evaluation batch")
