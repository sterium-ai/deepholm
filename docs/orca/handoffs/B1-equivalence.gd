extends SceneTree

## B1 behaviour-identity probe for the step-1 complexity fixes (JobQueue,
## EventLog, GlobalAssignment, per-tick job reads): plays a fixed order-heavy
## scenario -- rectangle digs/chops/mines issued tile by tile, a stockpile zone
## with hauls, a labour switched off for every colonist and back on (the
## labour_disabled block/unblock path), cancels of a third of the queued jobs
## (the waiting-queue removal path), random invalid orders -- with a save/load
## round trip in the middle. Writes every command result, a state_hash trace,
## both event logs (WorldState and JobQueue, sequences included), the scheduler
## snapshot and both saves to the directory given as the first user argument.
## Run on main and on the branch and diff the directories (see handoffs/B1.md):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")

var _n := 0

func _cmd(world, type: String, payload: Dictionary) -> Dictionary:
	_n += 1
	return {"actor": "player", "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

func _rect(world, results: Array, type: String, origin: Vector2i, size: Vector2i, priority: int) -> void:
	for y in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			results.append(world.apply(_cmd(world, type, {"x": x, "y": y, "priority": priority})))

func _set_labour_all(world, results: Array, kind: String, level: int) -> void:
	for colonist in world.get_colonists():
		results.append(world.apply(_cmd(world, "set_labour", {"colonist": String(colonist["id"]), "kind": kind, "level": level})))

func _cancel_every_third(world, results: Array) -> void:
	var i := 0
	for job in world.get_jobs():
		if String(job["status"]) != "queued":
			continue
		if i % 3 == 0:
			results.append(world.apply(_cmd(world, "cancel_job", {"job_id": String(job["id"])})))
		i += 1

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9100 + from_tick
	var c0: Dictionary = world.get_colonists()[0]
	var home := Vector2i(int(c0["x"]), int(c0["y"]))
	for t in range(from_tick, to_tick):
		match t:
			0:
				for kind in ["pick", "pick", "axe"]:
					results.append({"spawned_tool": world.spawn_ground_tool_item(kind, home.x, home.y)})
				_rect(world, results, "dig", home - Vector2i(12, 12), Vector2i(24, 24), 1)
				_rect(world, results, "chop", Vector2i(0, 0), Vector2i(64, 20), 2)
			3:
				results.append(world.apply(_cmd(world, "zone_add", {"x": home.x - 2, "y": home.y - 2, "width": 4, "height": 4})))
			20:
				_set_labour_all(world, results, "mine", 0)
			60:
				_set_labour_all(world, results, "mine", 3)
			90:
				_cancel_every_third(world, results)
			140:
				_rect(world, results, "mine", Vector2i(0, 40), Vector2i(64, 24), 1)
				_rect(world, results, "dig", Vector2i(30, 30), Vector2i(30, 30), 2)
			360:
				_set_labour_all(world, results, "chop", 0)
			400:
				_cancel_every_third(world, results)
			430:
				_set_labour_all(world, results, "chop", 2)
		if t % 17 == 0:
			for k in 3:
				var kind: String = ["dig", "chop", "mine", "forage", "till"][rng.randi_range(0, 4)]
				results.append(world.apply(_cmd(world, kind, {"x": rng.randi_range(0, 63), "y": rng.randi_range(0, 63), "priority": 1})))
		world.tick()
		if t % 10 == 0:
			trace.append([world.get_tick(), world.state_hash(), world.get_jobs().size()])

func _write(path: String, value) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(value, "\t"))
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(4242, 10, 64, 64)
	var results: Array = []
	var trace: Array = []
	_play(world, results, trace, 0, 300)
	var first: Dictionary = world.to_save_state()
	var loaded = WorldStateType.from_save_state(JSON.parse_string(JSON.stringify(first)))
	var results2: Array = []
	_play(loaded, results2, trace, 300, 600)
	var second: Dictionary = loaded.to_save_state()
	_write(out_dir.path_join("state_300.json"), first)
	_write(out_dir.path_join("state_600.json"), second)
	_write(out_dir.path_join("events.json"), [world.get_events(), loaded.get_events()])
	_write(out_dir.path_join("queue_events.json"), [world._scheduler.queue.get_events(), loaded._scheduler.queue.get_events()])
	_write(out_dir.path_join("scheduler.json"), [world._scheduler.snapshot(), loaded._scheduler.snapshot()])
	_write(out_dir.path_join("jobs.json"), [world.get_jobs(), loaded.get_jobs()])
	_write(out_dir.path_join("trace.json"), trace)
	_write(out_dir.path_join("results.json"), {"a": results, "b": results2})
	print("B1-equivalence: results=%d/%d jobs=%d events=%d/%d hash=%d/%d" % [results.size(), results2.size(),
		loaded.get_jobs().size(), world.get_events().size(), loaded.get_events().size(), world.state_hash(), loaded.state_hash()])
	quit(0)
