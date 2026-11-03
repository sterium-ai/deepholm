extends SceneTree

## L2 port of A14-scenario_dump.gd for the Vector3i API: every tile argument and literal is a
## Vector3i on layer 0 (the same tiles), and the dirty-cell stream is hashed over its cells'
## pre-L2 Vector2i form (_planar_cells()), so equal hashes still mean an equal stream; nothing
## else changed. L2-dumps.sh runs it on the branch; the original still runs on main. The
## original description follows.

## A14 byte-identity probe for the work-completion effects (copied from R11-scenario_dump.gd;
## the trace also records the tile grid, objects, ground berries and the dirty-cell stream,
## since those are what dig/chop/mine/forage/till/sow change). Seed 6161,
## 48x48, incidents on. At tick 0 it clears a 13x13 soil yard at the map centre, moves the
## spawned colonists there and adds three more. Hauls: stacks of wood, stone, sand and seed
## around the yard and two stockpile zones (the far one is removed at tick 140 and re-added
## at tick 360, so in-flight hauls fail with blocked_destination_gone and drop their cargo).
## Tools: one axe and one pick for a dozen chop/mine/dig orders (fetch_tool, no_tool_found
## requeue, the tool gate). Work effects: chop/mine/dig/till/forage around the yard, sow on
## the tilled tiles from tick 120 (seed is scarce, so some sows fail blocked_missing_input),
## a second mine on an already-mined tile (invalid_target). Unreachable: a dig and a chop
## inside a stone-wall ring placed at tick 30 (first-leg unreachable -> resubmit) and a
## haul whose destination cell is walled off. Construction: a workbench, a wall line and a
## bed, so site_fetch picks up, hops, deposits and chains. Every 20 ticks three random
## orders, cancel_job on a live haul/site_fetch/work job, or fail_job/invalidate_job.
## Every 100 ticks the world is saved (raw and through SaveIO), reloaded with
## from_save_state() and play continues on the reloaded copy; the event log (runtime only)
## is deep-copied right before every reload. Every 5 ticks it traces every actor's
## position, hands, held tool, route/work state, the reroute keys, every job, ground items,
## tool items with their reservations, the construction site-fetch caches, the dirty-cell
## count and state_hash(), each line as a deep copy.
## Runs unchanged on main and on A14 (it never names a changed function).
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const WORK_KINDS := ["haul", "site_fetch", "site_work", "chop", "mine", "dig", "till", "sow", "forage"]

var _n := 0
var _h := Vector3i(24, 24, 0)

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

## preview() then apply(), both recorded.
func _issue(world, results: Array, type: String, payload: Dictionary) -> void:
	var command := _cmd(world, type, payload)
	results.append({"preview": world.preview(command.duplicate(true))})
	results.append(world.apply(command))

func _trace_line(world) -> Dictionary:
	var line := {"tick": world.get_tick()}
	var actors: Array = []
	for actor in world._colonists:
		actors.append({"id": actor["id"], "x": actor["x"], "y": actor["y"], "hands": actor.get("hands"),
			"inventory": actor.get("inventory"), "held_tool": actor.get("held_tool"), "work": actor.get("work"),
			"routed": actor.get("route") != null})
	line["actors"] = actors
	var reroutes: Array = world._reroutes.keys()
	reroutes.sort()
	line["reroutes"] = reroutes
	var jobs: Array = []
	for job in world.get_jobs():
		if String(job.get("status", "")) in ["queued", "active", "blocked"] or String(job.get("kind", "")) in WORK_KINDS:
			jobs.append(job)
	line["jobs"] = jobs
	line["items"] = world.get_items()
	var tools: Array = []
	for tool in world.get_tool_items():
		var entry: Dictionary = tool.duplicate(true)
		entry["reserved_by"] = world.get_tool_item_reservation(String(tool["id"]))
		tools.append(entry)
	line["tools"] = tools
	line["retargeted"] = world._construction.site_fetch_source_retargeted
	line["picked_kind"] = world._construction.site_fetch_picked_kind
	line["sites"] = world.get_construction_sites()
	var dirty: Dictionary = world.get_dirty_cells_since(0)
	line["dirty"] = [dirty["next"], _planar_cells(dirty["cells"]).hash()]
	line["tiles"] = world.get_tiles().hash()
	line["objects"] = world.get_objects()
	line["berries"] = world._item_table.ground_berries
	line["pending_finds"] = world._item_table.pending_dig_finds.size()
	line["hash"] = world.state_hash()
	return line.duplicate(true)

func _in_map(p: Vector3i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < 48 and p.y < 48

func _set_tile(world, p: Vector3i, kind: String) -> void:
	if not _in_map(p):
		return
	var index: int = world._tile_grid.tile_index(p.x, p.y)
	var was_water: bool = world._tile_grid.tiles[index] == "water"
	world._tile_grid.tiles[index] = kind
	world._tile_grid.update_water_tile_cache(p, was_water, kind == "water")

func _order_at(world, results: Array, p: Vector3i) -> void:
	if not _in_map(p):
		return
	match world.get_tile(p.x, p.y):
		"tree":
			_issue(world, results, "chop", {"x": p.x, "y": p.y, "priority": 1})
		"rock":
			_issue(world, results, "mine", {"x": p.x, "y": p.y, "priority": 1})
		"soil":
			_issue(world, results, ["till", "dig"][(p.x + p.y) % 2], {"x": p.x, "y": p.y, "priority": 1})
		"plowed_soil":
			_issue(world, results, "sow", {"x": p.x, "y": p.y, "priority": 1})

func _ring(world, centre: Vector3i, kind: String) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx != 0 or dy != 0:
				world._object_table.set_object(Vector3i(centre.x + dx, centre.y + dy, 0), kind)

func _setup(world, results: Array) -> void:
	var h := _h
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			_set_tile(world, h + Vector3i(dx, dy, 0), "soil")
			world._object_table.set_object(Vector3i(h.x + dx, h.y + dy, 0), "")
	var i := 0
	for actor in world._colonists:
		actor["x"] = h.x - 1 + i % 3
		actor["y"] = h.y - 1 + i / 3
		i += 1
	for k in 3:
		var extra: Dictionary = ActorTableType.spawn("colonist", Vector3i(h.x - 1 + k, h.y + 1, 0), world._content, "probe_colonist_%d" % k)
		extra.erase("carrying")
		extra["hands"] = []
		extra["factionId"] = "colony"
		world._append_colonist(extra)
	# Trees, rock and berry bushes inside the yard, so the work orders are close.
	for p in [Vector3i(-5, -5, 0), Vector3i(-4, -5, 0), Vector3i(5, -5, 0), Vector3i(5, -4, 0)]:
		_set_tile(world, h + p, "tree")
	for p in [Vector3i(-5, 5, 0), Vector3i(-4, 5, 0), Vector3i(-3, 5, 0), Vector3i(5, 5, 0)]:
		_set_tile(world, h + p, "rock")
	for p in [Vector3i(0, -6, 0), Vector3i(2, -6, 0)]:
		world._object_table.set_object(Vector3i(h.x + p.x, h.y + p.y, 0), "berry_bush")
	# Hauls.
	var kinds := ["wood", "stone", "sand", "wood", "stone"]
	var spots := [Vector3i(-3, -3, 0), Vector3i(3, -3, 0), Vector3i(-3, 3, 0), Vector3i(2, 4, 0), Vector3i(-6, 0, 0), Vector3i(6, 1, 0)]
	for k in spots.size():
		world._item_table.place_new_ground_item(kinds[k % kinds.size()], 1 + k % 3, Vector3i(h.x + spots[k].x, h.y + spots[k].y, 0))
	world._item_table.place_new_ground_item("seed", 2, Vector3i(h.x + 1, h.y - 3, 0))
	_issue(world, results, "zone_add", {"x": h.x + 3, "y": h.y + 2, "width": 2, "height": 2})
	_issue(world, results, "zone_add", {"x": h.x - 6, "y": h.y - 2, "width": 2, "height": 3})
	# Tools: one of each for many orders.
	results.append({"tool": world.spawn_ground_tool_item("axe", h.x, h.y - 2)})
	results.append({"tool": world.spawn_ground_tool_item("pick", h.x + 1, h.y + 2)})
	for p in [Vector3i(-5, -5, 0), Vector3i(-4, -5, 0), Vector3i(5, -5, 0), Vector3i(5, -4, 0), Vector3i(-5, 5, 0), Vector3i(-4, 5, 0),
			Vector3i(-3, 5, 0), Vector3i(5, 5, 0), Vector3i(-2, -4, 0), Vector3i(4, 3, 0), Vector3i(-1, 4, 0)]:
		_order_at(world, results, h + p)
	for p in [Vector3i(-3, -1, 0), Vector3i(-2, 0, 0), Vector3i(3, -1, 0), Vector3i(4, -2, 0), Vector3i(1, 3, 0)]:
		_issue(world, results, "till", {"x": h.x + p.x, "y": h.y + p.y, "priority": 1})
	for p in [Vector3i(0, -6, 0), Vector3i(2, -6, 0)]:
		_issue(world, results, "forage", {"x": h.x + p.x, "y": h.y + p.y, "priority": 1})
	# Two mines on one rock: the second one finds floor (invalid_target).
	_issue(world, results, "mine", {"x": h.x - 5, "y": h.y + 5, "priority": 1})
	_issue(world, results, "build", {"kind": "workbench", "x": h.x + 2, "y": h.y - 1})
	_issue(world, results, "build", {"kind": "bed", "x": h.x - 2, "y": h.y + 3})
	_issue(world, results, "build_line", {"kind": "wooden_wall", "tiles": [{"x": h.x - 1, "y": h.y - 5},
		{"x": h.x, "y": h.y - 5}, {"x": h.x + 1, "y": h.y - 5}]})

func _live(world, kinds: Array) -> Array:
	var out: Array = []
	for job in world.get_jobs():
		if String(job.get("kind", "")) in kinds and String(job.get("status", "")) in ["queued", "active"]:
			out.append(String(job["id"]))
	return out

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6161 + from_tick
	for t in range(from_tick, to_tick):
		if t == 0:
			_setup(world, results)
		var h := _h
		if t == 30:
			# A dig and a chop walled in: first-leg unreachable.
			_set_tile(world, h + Vector3i(-9, -9, 0), "soil")
			_set_tile(world, h + Vector3i(9, -9, 0), "tree")
			_ring(world, h + Vector3i(-9, -9, 0), "stone_wall")
			_ring(world, h + Vector3i(9, -9, 0), "stone_wall")
			_issue(world, results, "dig", {"x": h.x - 9, "y": h.y - 9, "priority": 1})
			_issue(world, results, "chop", {"x": h.x + 9, "y": h.y - 9, "priority": 1})
			world._item_table.place_new_ground_item("stone", 2, Vector3i(h.x + 6, h.y - 6, 0))
		if t == 45:
			# The near stockpile is walled off while hauls are under way.
			_ring(world, h + Vector3i(4, 3, 0), "stone_wall")
		if t == 120 or t == 320:
			for p in [Vector3i(-3, -1, 0), Vector3i(-2, 0, 0), Vector3i(3, -1, 0), Vector3i(4, -2, 0), Vector3i(1, 3, 0)]:
				_order_at(world, results, h + p)
		if t == 140:
			_issue(world, results, "zone_remove", {"x": h.x - 6, "y": h.y - 2})
		if t == 200:
			_ring(world, h + Vector3i(4, 3, 0), "")
			_ring(world, h + Vector3i(-9, -9, 0), "")
		if t == 360:
			_issue(world, results, "zone_add", {"x": h.x - 6, "y": h.y - 2, "width": 2, "height": 3})
			world._item_table.place_new_ground_item("seed", 3, Vector3i(h.x - 1, h.y - 3, 0))
		if t % 20 == 10:
			for k in 3:
				var roll := rng.randi_range(0, 5)
				if roll == 0:
					var live := _live(world, ["haul", "site_fetch"])
					if not live.is_empty():
						results.append(world.apply(_cmd(world, "cancel_job", {"job_id": live[rng.randi_range(0, live.size() - 1)]})))
				elif roll == 1:
					var live := _live(world, ["chop", "mine", "dig", "till", "sow", "forage"])
					if not live.is_empty():
						var type: String = ["cancel_job", "fail_job", "invalidate_job"][rng.randi_range(0, 2)]
						results.append(world.apply(_cmd(world, type, {"job_id": live[rng.randi_range(0, live.size() - 1)]})))
				elif roll == 2:
					world._item_table.place_new_ground_item(["wood", "stone", "sand"][rng.randi_range(0, 2)], rng.randi_range(1, 3),
						Vector3i(h.x + rng.randi_range(-6, 6), h.y + rng.randi_range(-6, 6), 0))
				else:
					_order_at(world, results, h + Vector3i(rng.randi_range(-11, 11), rng.randi_range(-11, 11), 0))
		world.tick()
		if t % 5 == 0:
			trace.append(_trace_line(world))

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(6161, 10, 48, 48, true)
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
		events.append(world.get_events().duplicate(true))
		world = WorldStateType.from_save_state(state.duplicate(true))
		world.enable_incidents()
		trace.append({"reloaded": from + 100, "line": _trace_line(world)})
	_write(out_dir.path_join("states.json"), JSON.stringify(saves, "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify(results, "\t"))
	_write(out_dir.path_join("io.json"), JSON.stringify(io, "\t"))
	_write(out_dir.path_join("events.json"), JSON.stringify(events, "\t"))
	var counts := {}
	var reasons := {}
	var total_events := 0
	for segment in events:
		for event in segment:
			total_events += 1
			var type := String(event.get("type", ""))
			counts[type] = int(counts.get(type, 0)) + 1
			var payload: Dictionary = event.get("data", {}) if event.get("data") is Dictionary else {}
			if type == "job_failed" or type == "job_blocked":
				var key := "%s:%s" % [type, String(payload.get("reason", ""))]
				reasons[key] = int(reasons.get(key, 0)) + 1
	var applied := 0
	var rejected := 0
	for r in results:
		if r.has("ok") and not r.has("preview"):
			if r["ok"]: applied += 1
			else: rejected += 1
	var carrying_lines := 0
	var tool_held_lines := 0
	for line in trace:
		var l: Dictionary = line.get("line", line)
		for a in l["actors"]:
			if a["hands"] is Array and not (a["hands"] as Array).is_empty(): carrying_lines += 1
			if not String(a.get("held_tool", "")).is_empty(): tool_held_lines += 1
	var failed: Array = []
	for entry in io:
		if not entry["ok"]:
			failed.append("%d:%s" % [entry["tick"], entry["error"]])
	var type_keys := counts.keys()
	type_keys.sort()
	var type_parts: Array = []
	for k in type_keys: type_parts.append("%s=%d" % [k, counts[k]])
	var reason_keys := reasons.keys()
	reason_keys.sort()
	var reason_parts: Array = []
	for k in reason_keys: reason_parts.append("%s=%d" % [k, reasons[k]])
	print("scenario_dump: results=%d applied=%d rejected=%d events=%d carrying_lines=%d tool_held_lines=%d items_end=%d tools_end=%d sites_end=%d save_refused=%s hash=%d" % [
		results.size(), applied, rejected, total_events, carrying_lines, tool_held_lines, world.get_items().size(),
		world.get_tool_items().size(), world.get_construction_sites().size(), str(failed), world.state_hash()])
	print("scenario_dump_events: " + ", ".join(type_parts))
	print("scenario_dump_reasons: " + ", ".join(reason_parts))
	quit(0)

## The cells as the Vector2i the pre-L2 stream held (every cell is on layer 0 here).
func _planar_cells(cells: Array) -> Array:
	var planar: Array = []
	for cell: Vector3i in cells:
		assert(cell.z == 0)
		planar.append(Vector2i(cell.x, cell.y))
	return planar
