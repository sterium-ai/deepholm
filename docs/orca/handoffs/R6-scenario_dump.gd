extends SceneTree

## R6 byte-identity probe for trenches and rescue. Seed 777, 48x48, incidents on. At tick 0
## it clears a yard at the map centre, moves the spawned colonists there and adds four more,
## carves two trench lines (a vertical one east of the yard, a horizontal one south of it)
## and orders chop/till/mine/dig work on the far side, so colonists route across a trench, get trapped, and the others are sent to rescue
## them. Four wolves (wildlife, hostile to the colony) are sent across a trench by
## autonomous incident jobs, so they get trapped and climb out through escape_trench; one of
## them falls into a walled pit whose entry tile is then closed until tick 200, so its
## climb-out is blocked and retried. Every 20 ticks three random orders (chop/till/dig/mine, or cancel_job on a live
## rescue/escape_trench job) and, every 120 ticks, another wolf across a trench. Every 100
## ticks the world is saved (raw and through SaveIO), reloaded with from_save_state() and
## play continues on the reloaded copy. Every 5 ticks it traces every actor's position,
## `trapped` and rescue reason, the raw rescue-reason cache, trap_tile_before, the
## rescue/escape_trench jobs, RescueGiver's associations and state_hash().
## Runs unchanged on main (fields on WorldState) and on R6 (on world._trench).
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

var _n := 0
var _wolves := 0
## The map centre: every colonist, order and trench is placed relative to it.
var _h := Vector2i(24, 24)

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

## preview() then apply(), both recorded.
func _issue(world, results: Array, type: String, payload: Dictionary) -> void:
	var command := _cmd(world, type, payload)
	results.append({"preview": world.preview(command.duplicate(true))})
	results.append(world.apply(command))

## TrenchSystem on R6, WorldState's own fields on main.
func _trench_state(world) -> Dictionary:
	var system = world.get("_trench")
	if system != null:
		return {"rescue_status": system.rescue_status, "trap_tile_before": system.trap_tile_before}
	return {"rescue_status": world.get("_rescue_status"), "trap_tile_before": world.get("_trap_tile_before")}

func _trace_line(world) -> Dictionary:
	var line := _trench_state(world)
	line["tick"] = world.get_tick()
	var actors: Array = []
	for actor in world._colonists:
		actors.append({"id": actor["id"], "x": actor["x"], "y": actor["y"], "trapped": actor.get("trapped"),
			"rescue_reason": world.get_colonist_rescue_reason(String(actor["id"]))})
	line["actors"] = actors
	var jobs: Array = []
	for job in world.get_jobs():
		if String(job.get("kind", "")) in ["rescue", "escape_trench"]:
			jobs.append(job)
	line["jobs"] = jobs
	line["rescue_pending"] = world._rescue_giver.get_pending_assignments()
	line["rescue_victims"] = world._rescue_giver.get_job_victims()
	line["hash"] = world.state_hash()
	return line

func _in_map(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < 48 and p.y < 48

func _set_tile(world, p: Vector2i, kind: String) -> void:
	if _in_map(p):
		world._tile_grid.tiles[world._tile_grid.tile_index(p.x, p.y)] = kind

## A wolf at `from` sent by an autonomous incident job to `to` (across a trench).
func _send_wolf(world, results: Array, from: Vector2i, to: Vector2i) -> void:
	if not (_in_map(from) and _in_map(to)):
		return
	_wolves += 1
	var id := "probe_wolf_%d" % _wolves
	var wolf: Dictionary = ActorTableType.spawn("wolf", from.x, from.y, world._content, id)
	wolf["factionId"] = "wildlife"
	world._colonists.append(wolf)
	results.append({"wolf": id, "submit": world._scheduler.submit_autonomous(to, 1, world.get_tick(), "incident", id)})

func _order_at(world, results: Array, p: Vector2i) -> void:
	if not _in_map(p):
		return
	match world.get_tile(p.x, p.y):
		"tree":
			_issue(world, results, "chop", {"x": p.x, "y": p.y, "priority": 1})
		"rock":
			_issue(world, results, "mine", {"x": p.x, "y": p.y, "priority": 1})
		"soil":
			_issue(world, results, ["till", "dig"][(p.x + p.y) % 2], {"x": p.x, "y": p.y, "priority": 1})

func _setup(world, results: Array) -> void:
	var h := _h
	# A cleared 7x7 yard at the centre; the spawned colonists move there and four more join.
	for dy in range(-3, 4):
		for dx in range(-3, 3):
			_set_tile(world, h + Vector2i(dx, dy), "soil")
			world._object_table.set_object(h.x + dx, h.y + dy, "")
	var i := 0
	for actor in world._colonists:
		actor["x"] = h.x - 2 + i % 3
		actor["y"] = h.y - 2 + i / 3
		i += 1
	for k in 4:
		var extra: Dictionary = ActorTableType.spawn("colonist", h.x - 2 + k % 3, h.y + 1 + k / 3, world._content, "probe_colonist_%d" % k)
		extra.erase("carrying")
		extra["hands"] = []
		extra["factionId"] = "colony"
		world._append_colonist(extra)
	# Work on the far side of the trenches: soil to till/dig, plus whatever already grows there.
	for dy in range(-6, 7, 2):
		for dx in range(5, 12, 3):
			if (dx + dy) % 4 == 0:
				_set_tile(world, h + Vector2i(dx, dy), "soil")
	for dx in range(-6, 3, 2):
		for dy in range(6, 11, 2):
			if (dx + dy) % 4 == 0:
				_set_tile(world, h + Vector2i(dx, dy), "soil")
	for dy in range(-8, 9):
		_set_tile(world, Vector2i(h.x + 3, h.y + dy), "trench")
	for dx in range(-8, 3):
		_set_tile(world, Vector2i(h.x + dx, h.y + 4), "trench")
	# A walled-in trench tile: a wolf falling into it finds no exit and retries.
	var pit := h + Vector2i(-6, -5)
	_set_tile(world, pit, "trench")
	for n in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0)]:
		_set_tile(world, pit + n, "rock")
	for dy in range(-6, 7, 2):
		for dx in range(5, 12, 3):
			_order_at(world, results, h + Vector2i(dx, dy))
	for dx in range(-6, 3, 2):
		for dy in range(6, 11, 2):
			_order_at(world, results, h + Vector2i(dx, dy))
	_send_wolf(world, results, h + Vector2i(6, 0), h + Vector2i(1, 0))
	_send_wolf(world, results, h + Vector2i(6, 2), h + Vector2i(0, 1))
	_send_wolf(world, results, h + Vector2i(-2, 7), h + Vector2i(-2, 1))
	_send_wolf(world, results, pit + Vector2i(0, 2), pit)

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6160 + from_tick
	for t in range(from_tick, to_tick):
		if t == 0:
			_setup(world, results)
		var h := _h
		if t % 20 == 10:
			for k in 3:
				var p := h + Vector2i(rng.randi_range(-10, 10), rng.randi_range(-10, 10))
				if rng.randi_range(0, 3) == 0:
					var live: Array = []
					for job in world.get_jobs():
						if String(job.get("kind", "")) in ["rescue", "escape_trench"] and String(job.get("status", "")) in ["queued", "active"]:
							live.append(String(job["id"]))
					if not live.is_empty():
						results.append(world.apply(_cmd(world, "cancel_job", {"job_id": live[rng.randi_range(0, live.size() - 1)]})))
				else:
					_order_at(world, results, p)
		# The pit's entry tile is rock while its wolf is trapped (before tick 200), so every
		# climb-out finds no exit and is retried; at tick 200 it opens again.
		var pit := h + Vector2i(-6, -5)
		if t < 200:
			for actor in world._colonists:
				if String(actor["id"]) == "probe_wolf_4" and actor.get("trapped") != null:
					_set_tile(world, pit + Vector2i(0, 1), "rock")
		elif t == 200:
			_set_tile(world, pit + Vector2i(0, 1), "soil")
		if t % 120 == 30:
			var side := rng.randi_range(-6, 6)
			_send_wolf(world, results, h + Vector2i(7, side), h + Vector2i(0, side))
		world.tick()
		if t % 5 == 0:
			trace.append(_trace_line(world))

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(777, 10, 48, 48, true)
	var results: Array = []
	var trace: Array = []
	var saves: Array = []
	var io: Array = []
	for step in 8:
		var from := step * 100
		_play(world, results, trace, from, from + 100)
		var state: Dictionary = world.to_save_state()
		saves.append(state)
		var check := SaveIOType.write_atomic(out_dir.path_join("save_%d.json" % (from + 100)), state)
		io.append({"tick": from + 100, "ok": check.get("ok"), "error": "%s %s" % [check.get("code", ""), check.get("message", "")]})
		world = WorldStateType.from_save_state(state.duplicate(true))
		world.enable_incidents()
		trace.append({"reloaded": from + 100, "line": _trace_line(world)})
	_write(out_dir.path_join("states.json"), JSON.stringify(saves, "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify(results, "\t"))
	_write(out_dir.path_join("io.json"), JSON.stringify(io, "\t"))
	_write(out_dir.path_join("events.json"), JSON.stringify(world.get_events(), "\t"))
	# Distinct (actor, trap tile) episodes, rescue and escape jobs, reasons seen.
	var traps := {}
	var rescue_jobs := {}
	var escape_jobs := {}
	var completed := {}
	var no_rescuer_lines := 0
	for line in trace:
		var l: Dictionary = line.get("line", line)
		for actor in (l["actors"] as Array):
			if actor["trapped"] != null:
				traps["%s@%s" % [actor["id"], str((actor["trapped"] as Dictionary)["tile"])]] = true
			if String(actor["rescue_reason"]) != "":
				no_rescuer_lines += 1
		for job in (l["jobs"] as Array):
			var bucket: Dictionary = rescue_jobs if String(job["kind"]) == "rescue" else escape_jobs
			bucket[String(job["id"])] = true
			if String(job["status"]) == "completed":
				completed[String(job["id"])] = String(job["kind"])
	var applied := 0
	var rejected := 0
	for r in results:
		if r.has("ok") and not r.has("preview"):
			if r["ok"]: applied += 1
			else: rejected += 1
	var completed_rescues := 0
	for id in completed:
		if completed[id] == "rescue": completed_rescues += 1
	var failed: Array = []
	for entry in io:
		if not entry["ok"]:
			failed.append("%d:%s" % [entry["tick"], entry["error"]])
	print("scenario_dump: actors_left=%d results=%d applied=%d rejected=%d trap_episodes=%d rescue_jobs=%d completed_rescues=%d escape_jobs=%d no_rescuer_lines=%d save_refused=%s hash=%d" % [
		world._colonists.size(), results.size(), applied, rejected, traps.size(), rescue_jobs.size(), completed_rescues, escape_jobs.size(),
		no_rescuer_lines, str(failed), world.state_hash()])
	quit(0)
