extends SceneTree

## B1: every indexed read added so a whole-map order stays cheap must return
## exactly what the full scan it replaces returns. Plays an order-heavy world
## (rectangle digs/chops/mines, tools, a zone with hauls, a labour switched off
## and back on, cancels, a save/load round trip) and after every tick compares
## each indexed read against a brute-force recomputation from the full
## getters: get_jobs(kinds), get_job(), get_queued_job_summary(),
## get_events(types), JobQueue.get_events_after(), get_reservations() and the
## scheduler's waiting-queue lookups.

const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failures: Array[String] = []
var _n := 0

func _init() -> void:
	var world = WorldStateType.new(4242, 10, 64, 64)
	var c0: Dictionary = world.get_colonists()[0]
	var home := Vector2i(int(c0["x"]), int(c0["y"]))
	for kind in ["pick", "pick", "axe"]:
		world.spawn_ground_tool_item(kind, home.x, home.y)
	_rect(world, "dig", home - Vector2i(8, 8), Vector2i(16, 16))
	_rect(world, "chop", Vector2i(0, 0), Vector2i(64, 12))
	_apply(world, "zone_add", {"x": home.x - 2, "y": home.y - 2, "width": 4, "height": 4})
	for t in 160:
		if t == 15:
			_set_labour_all(world, "mine", 0)
		if t == 40:
			_set_labour_all(world, "mine", 3)
		if t == 60:
			_cancel_every_third(world)
		if t == 80:
			world = WorldStateType.from_save_state(JSON.parse_string(JSON.stringify(world.to_save_state())))
			_rect(world, "mine", Vector2i(0, 50), Vector2i(64, 10))
		world.tick()
		_check_reads(world, t)
		if _failures.size() > 10:
			break
	if not _failures.is_empty():
		for failure in _failures:
			push_error(failure)
		quit(1)
		return
	print("test_job_read_indexes: PASS")
	quit(0)

func _check_reads(world, t: int) -> void:
	var jobs: Array[Dictionary] = world.get_jobs()
	for kinds in [["dig"], ["site_fetch", "site_work"], ["haul", "chop", "mine"], ["eat_food", "drink_water", "sleep"]]:
		var expected: Array[Dictionary] = []
		for job in jobs:
			if String(job["kind"]) in kinds:
				expected.append(job)
		_expect(world.get_jobs(kinds) == expected, "tick %d: get_jobs(%s) must equal get_jobs() filtered by kind" % [t, kinds])
	for job in jobs.slice(0, 40):
		_expect(world.get_job(String(job["id"])) == job, "tick %d: get_job(%s) must equal its get_jobs() entry" % [t, job["id"]])
	_expect(world.get_job("job_does_not_exist").is_empty(), "get_job() of an unknown id must be {}")
	var queued: Array[Dictionary] = []
	for job in jobs:
		if job["status"] == "queued":
			queued.append(job)
	queued.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	var blocked := {}
	for job in queued:
		if not String(job["reason"]).is_empty():
			blocked = {"reason": job["reason"], "remedy": job["remedy"]}
			break
	_expect(world.get_queued_job_summary() == {"queued": queued.size(), "first_blocked": blocked},
		"tick %d: get_queued_job_summary() must match the queued jobs" % t)
	var events: Array[Dictionary] = world.get_events()
	for types in [["job_queued"], ["job_blocked", "job_unblocked"], ["tick_advanced"], ["no_such_event"]]:
		var expected_events: Array[Dictionary] = []
		for event in events:
			if String(event["type"]) in types:
				expected_events.append(event)
		_expect(world.get_events(types) == expected_events, "tick %d: get_events(%s) must equal get_events() filtered by type" % [t, types])
	var queue = world._scheduler.queue
	var queue_events: Array[Dictionary] = queue.get_events()
	for after in [-1, queue.get_sequence() - 7, queue.get_sequence() - 1]:
		var tail: Array[Dictionary] = []
		for event in queue_events:
			if int(event["sequence"]) > after:
				tail.append(event)
		_expect(queue.get_events_after(after) == tail, "tick %d: JobQueue.get_events_after(%d) must be get_events()' tail" % [t, after])
	var reservations := {}
	var queue_jobs: Array[Dictionary] = queue.get_jobs()
	for job in queue_jobs:
		if job["status"] == "active":
			reservations[job["target"]] = job["id"]
	for job in queue_jobs:
		if job["status"] == "queued" and queue.get_tick() < int(job["retry_at"]) and not reservations.has(job["target"]):
			reservations[job["target"]] = job["id"]
	_expect(queue.get_reservations() == reservations, "tick %d: get_reservations() must match the full scan" % t)
	var kinds_by_id := {}
	for job in queue_jobs:
		kinds_by_id[job["id"]] = String(job["kind"])
	_expect(queue.get_job_kinds() == kinds_by_id, "tick %d: get_job_kinds() must match the jobs" % t)
	var waiting: Array[Dictionary] = world._scheduler.get_waiting()
	for index in range(0, waiting.size(), maxi(1, waiting.size() / 25)):
		var entry: Dictionary = waiting[index]
		_expect(world._scheduler._find_waiting_entry(String(entry["id"])) == entry,
			"tick %d: the waiting lookup must find %s" % [t, entry["id"]])
		_expect(world._scheduler.waiting_restrict_to(String(entry["id"])) == String(entry.get("restrict_to", "")),
			"tick %d: waiting_restrict_to(%s) must match its entry" % [t, entry["id"]])
	for job in queue_jobs:
		if job["status"] != "queued":
			_expect(world._scheduler._find_waiting_entry(String(job["id"])).is_empty() or _waiting_has(waiting, String(job["id"])),
				"tick %d: a %s job must not be found waiting unless it is" % [t, job["status"]])

func _waiting_has(waiting: Array[Dictionary], job_id: String) -> bool:
	for entry in waiting:
		if String(entry["id"]) == job_id:
			return true
	return false

func _apply(world, type: String, payload: Dictionary) -> Dictionary:
	_n += 1
	return world.apply({"actor": "player", "command_id": "t%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload})

func _rect(world, type: String, origin: Vector2i, size: Vector2i) -> void:
	for y in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			_apply(world, type, {"x": x, "y": y, "priority": 1})

func _set_labour_all(world, kind: String, level: int) -> void:
	for colonist in world.get_colonists():
		var result := _apply(world, "set_labour", {"colonist": String(colonist["id"]), "kind": kind, "level": level})
		_expect(result.get("ok", false), "set_labour %s=%d must be accepted" % [kind, level])

func _cancel_every_third(world) -> void:
	var i := 0
	for job in world.get_jobs():
		if String(job["status"]) == "queued":
			if i % 3 == 0:
				_apply(world, "cancel_job", {"job_id": String(job["id"])})
			i += 1

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
