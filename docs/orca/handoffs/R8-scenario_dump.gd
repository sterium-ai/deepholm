extends SceneTree

## R8 byte-identity probe for needs. Seed 4242, 48x48, incidents on. At tick 0 it clears an
## 11x11 yard at the map centre, moves the spawned colonists there and adds three more, starts
## them at mixed need levels and speeds every need's decay up 25x (content rate_per_day, the
## live definitions both sides share), so every colonist goes through several
## warn/urgent/critical cycles. Sources: a two-tile pond, three ground-berries tiles, two beds
## (one of them walled into a small bedroom). Work orders (chop/till/dig/mine) around the yard
## and wood on the ground with a stockpile zone keep colonists busy, so needs interrupt work
## toils and hauls mid-carry. Wolves (wildlife) arrive at ticks 150 and 450 for combat
## interrupts. Every 20 ticks three random orders, or a cancel_job on a live need job or a
## paused job. Every 100 ticks the world is saved (raw and through SaveIO), reloaded with
## from_save_state() and play continues on the reloaded copy. Every 5 ticks it traces every
## actor's needs, accumulator, need reason, active need job, the raw paused-jobs and
## need-reason maps, the need jobs, NeedGiver's pending map, the berries and state_hash().
## Each trace line is a deep copy, so later ticks cannot rewrite earlier observations. The
## event log is runtime only (a reload starts it empty), so it is captured, as a deep copy,
## right before every reload: events.json holds one entry per 100-tick segment.
## Runs unchanged on main (fields on WorldState) and on R8 (on world._needs_system).
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const NEED_JOB_KINDS := ["eat_food", "drink_water", "sleep"]

var _n := 0
var _wolves := 0
var _h := Vector2i(24, 24)

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

## preview() then apply(), both recorded.
func _issue(world, results: Array, type: String, payload: Dictionary) -> void:
	var command := _cmd(world, type, payload)
	results.append({"preview": world.preview(command.duplicate(true))})
	results.append(world.apply(command))

## NeedsSystem's field on R8, WorldState's own "_"-prefixed field on main.
func _field(world, name: String) -> Dictionary:
	var system = world.get("_needs_system")
	return system.get(name) if system != null else world.get("_" + name)

func _trace_line(world) -> Dictionary:
	var line := {"tick": world.get_tick()}
	var actors: Array = []
	for actor in world._colonists:
		var id := String(actor["id"])
		actors.append({"id": id, "x": actor["x"], "y": actor["y"], "needs": actor.get("needs"),
			"acc": actor.get("needsAccumulator"), "work": actor.get("work"), "routed": actor.get("route") != null,
			"reason": world.get_colonist_need_reason(id), "need_job": world.get_active_need_job_id(id)})
	line["actors"] = actors
	line["paused_jobs"] = _field(world, "paused_jobs")
	line["need_status"] = _field(world, "need_status")
	var jobs: Array = []
	for job in world.get_jobs():
		if String(job.get("kind", "")) in NEED_JOB_KINDS:
			jobs.append(job)
	line["jobs"] = jobs
	line["need_pending"] = world._need_giver.get_pending_assignments()
	line["berries"] = world._item_table.ground_berries
	line["hash"] = world.state_hash()
	# Deep copy: the needs, accumulator, paused-job, reason and job dictionaries are live.
	return line.duplicate(true)

func _in_map(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < 48 and p.y < 48

func _set_tile(world, p: Vector2i, kind: String) -> void:
	if not _in_map(p):
		return
	var index: int = world._tile_grid.tile_index(p.x, p.y)
	var was_water: bool = world._tile_grid.tiles[index] == "water"
	world._tile_grid.tiles[index] = kind
	world._tile_grid.update_water_tile_cache(p.x, p.y, was_water, kind == "water")

func _send_wolf(world, results: Array, from: Vector2i) -> void:
	if not _in_map(from):
		return
	_wolves += 1
	var id := "probe_wolf_%d" % _wolves
	var wolf: Dictionary = ActorTableType.spawn("wolf", from.x, from.y, world._content, id)
	wolf["factionId"] = "wildlife"
	world._colonists.append(wolf)
	results.append({"wolf": id})

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
	for dy in range(-5, 6):
		for dx in range(-5, 6):
			_set_tile(world, h + Vector2i(dx, dy), "soil")
			world._object_table.set_object(h.x + dx, h.y + dy, "")
	var start_needs := [[60, 30, 90], [20, 80, 40], [95, 12, 70], [35, 55, 15], [80, 40, 30], [50, 50, 50]]
	var i := 0
	for actor in world._colonists:
		actor["x"] = h.x - 1 + i % 3
		actor["y"] = h.y - 1 + i / 3
		i += 1
	for k in 3:
		var extra: Dictionary = ActorTableType.spawn("colonist", h.x - 1 + k, h.y + 1, world._content, "probe_colonist_%d" % k)
		extra.erase("carrying")
		extra["hands"] = []
		extra["factionId"] = "colony"
		world._append_colonist(extra)
	i = 0
	for actor in world._colonists:
		var levels: Array = start_needs[i % start_needs.size()]
		actor["needs"] = {"food": levels[0], "water": levels[1], "rest": levels[2]}
		i += 1
	for kind in world._need_definitions:
		world._need_definitions[kind]["rate_per_day"] = int(world._need_definitions[kind]["rate_per_day"]) * 25
	_set_tile(world, h + Vector2i(-5, -5), "water")
	_set_tile(world, h + Vector2i(-4, -5), "water")
	world._item_table.ground_berries["%d_%d" % [h.x + 5, h.y - 5]] = 3
	world._item_table.ground_berries["%d_%d" % [h.x + 5, h.y + 5]] = 2
	world._item_table.ground_berries["%d_%d" % [h.x - 5, h.y + 5]] = 4
	world._object_table.set_object(h.x + 4, h.y, "bed")
	# A 3x3-interior walled room on the west edge of the yard: its bed is a bedroom bed.
	for d in range(-2, 3):
		world._object_table.set_object(h.x - 6, h.y + d, "stone_wall")
		world._object_table.set_object(h.x - 2, h.y + d, "stone_wall")
		world._object_table.set_object(h.x - 5 + (d + 2) % 3, h.y - 2, "stone_wall")
		world._object_table.set_object(h.x - 5 + (d + 2) % 3, h.y + 2, "stone_wall")
	world._object_table.set_object(h.x - 2, h.y, "door")
	world._object_table.set_object(h.x - 4, h.y, "bed")
	world._item_table.place_new_ground_item("wood", 3, h.x + 2, h.y - 4)
	world._item_table.place_new_ground_item("wood", 2, h.x - 1, h.y + 4)
	_issue(world, results, "zone_add", {"x": h.x + 3, "y": h.y + 3, "width": 2, "height": 2})
	for dy in range(-10, 11, 3):
		for dx in [-9, -7, 7, 9]:
			_order_at(world, results, h + Vector2i(dx, dy))
	for dx in range(-4, 5, 4):
		_order_at(world, results, h + Vector2i(dx, -8))
		_order_at(world, results, h + Vector2i(dx, 8))

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8080 + from_tick
	for t in range(from_tick, to_tick):
		if t == 0:
			_setup(world, results)
		var h := _h
		if t % 20 == 10:
			for k in 3:
				var roll := rng.randi_range(0, 4)
				if roll == 0:
					var live: Array = []
					for job in world.get_jobs():
						if String(job.get("kind", "")) in NEED_JOB_KINDS and String(job.get("status", "")) in ["queued", "active"]:
							live.append(String(job["id"]))
					if not live.is_empty():
						results.append(world.apply(_cmd(world, "cancel_job", {"job_id": live[rng.randi_range(0, live.size() - 1)]})))
				elif roll == 1:
					var paused: Dictionary = _field(world, "paused_jobs")
					var keys := paused.keys()
					keys.sort()
					if not keys.is_empty():
						var job_id := String(paused[keys[rng.randi_range(0, keys.size() - 1)]])
						results.append(world.apply(_cmd(world, "cancel_job", {"job_id": job_id})))
				else:
					_order_at(world, results, h + Vector2i(rng.randi_range(-11, 11), rng.randi_range(-11, 11)))
		if t == 150 or t == 450:
			_send_wolf(world, results, h + Vector2i(8, rng.randi_range(-3, 3)))
		world.tick()
		if t % 5 == 0:
			trace.append(_trace_line(world))

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(4242, 10, 48, 48, true)
	var results: Array = []
	var trace: Array = []
	var saves: Array = []
	var io: Array = []
	var events: Array = []
	for step in 8:
		var from := step * 100
		_play(world, results, trace, from, from + 100)
		var state: Dictionary = world.to_save_state()
		saves.append(state)
		var check := SaveIOType.write_atomic(out_dir.path_join("save_%d.json" % (from + 100)), state)
		io.append({"tick": from + 100, "ok": check.get("ok"), "error": "%s %s" % [check.get("code", ""), check.get("message", "")]})
		# The event log does not survive the reload below: keep this segment's events first.
		events.append({"segment_end": from + 100, "events": (world.get_events() as Array).duplicate(true)})
		# A reloaded world rebuilds its definitions from content: re-apply the probe's decay speed-up.
		world = WorldStateType.from_save_state(state.duplicate(true))
		world.enable_incidents()
		for kind in world._need_definitions:
			world._need_definitions[kind]["rate_per_day"] = int(world._need_definitions[kind]["rate_per_day"]) * 25
		trace.append({"reloaded": from + 100, "line": _trace_line(world)})
	_write(out_dir.path_join("states.json"), JSON.stringify(saves, "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify(results, "\t"))
	_write(out_dir.path_join("io.json"), JSON.stringify(io, "\t"))
	_write(out_dir.path_join("events.json"), JSON.stringify(events, "\t"))
	var need_jobs := {}
	var completed := {}
	var paused_seen := {}
	var reason_lines := 0
	for line in trace:
		var l: Dictionary = line.get("line", line)
		for actor in (l["actors"] as Array):
			if String(actor["reason"]) != "":
				reason_lines += 1
		for colonist_id in (l["paused_jobs"] as Dictionary):
			paused_seen["%s:%s" % [colonist_id, l["paused_jobs"][colonist_id]]] = true
		for job in (l["jobs"] as Array):
			need_jobs[String(job["id"])] = true
			if String(job["status"]) == "completed":
				completed[String(job["id"])] = true
	var applied := 0
	var rejected := 0
	for r in results:
		if r.has("ok") and not r.has("preview"):
			if r["ok"]: applied += 1
			else: rejected += 1
	var event_count := 0
	var unmet_events := 0
	var unmet_segments := 0
	for segment in events:
		event_count += (segment["events"] as Array).size()
		var in_segment := 0
		for event in (segment["events"] as Array):
			if String(event.get("type", "")) == "need_unmet":
				in_segment += 1
		unmet_events += in_segment
		if in_segment > 0:
			unmet_segments += 1
	var failed: Array = []
	for entry in io:
		if not entry["ok"]:
			failed.append("%d:%s" % [entry["tick"], entry["error"]])
	print("scenario_dump: actors_left=%d results=%d applied=%d rejected=%d need_jobs=%d completed_need_jobs=%d paused_episodes=%d reason_lines=%d events=%d need_unmet_events=%d need_unmet_segments=%d save_refused=%s hash=%d" % [
		world._colonists.size(), results.size(), applied, rejected, need_jobs.size(), completed.size(), paused_seen.size(),
		reason_lines, event_count, unmet_events, unmet_segments, str(failed), world.state_hash()])
	quit(0)
