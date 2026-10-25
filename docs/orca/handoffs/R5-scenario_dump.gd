extends SceneTree

## R5 byte-identity probe for construction. Seed 777, 48x48, 10 colonists, incidents on.
## A 5x5 stockpile next to colonist 0 is stocked with wood and stone (several small stacks,
## so fetch jobs hop between sources and chain onto sibling sites). Orders: a workbench
## (2x1, two builders, two materials), single walls, beds and doors, three build_line rows
## (one with duplicated/out-of-order/occupied tiles), a build_line and a single wall that
## would seal a pocket (rejected), cancel_site at tick 180, cancel_job naming a site id at
## tick 330, chops for more wood, and every 20 ticks three random build/build_line/
## cancel_site commands. Every command is also previewed first. Every 100 ticks the world
## is saved (raw and through SaveIO), reloaded with from_save_state() and play continues
## on the reloaded copy. Every 5 ticks it traces the raw site records, the public site
## view, both site-fetch caches, the site_fetch/site_work jobs and state_hash().
## Runs unchanged on main (fields on WorldState) and on R5 (on world._construction).
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

var _n := 0

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

## preview() then apply(), both recorded.
func _issue(world, results: Array, type: String, payload: Dictionary) -> void:
	var command := _cmd(world, type, payload)
	results.append({"preview": world.preview(command.duplicate(true))})
	results.append(world.apply(command))

## ConstructionSystem on R5, WorldState's own fields on main.
func _construction_state(world) -> Dictionary:
	var system = world.get("_construction")
	if system != null:
		return {"sites": system.site_table.list(), "retargeted": system.site_fetch_source_retargeted,
			"picked_kind": system.site_fetch_picked_kind}
	return {"sites": world.get("_sites").list(), "retargeted": world.get("_site_fetch_source_retargeted"),
		"picked_kind": world.get("_site_fetch_picked_kind")}

func _site_jobs(world) -> Array:
	var out: Array = []
	for job in world.get_jobs():
		if String(job.get("kind", "")) in ["site_fetch", "site_work"]:
			out.append(job)
	return out

func _trace_line(world) -> Dictionary:
	var line := _construction_state(world)
	line["tick"] = world.get_tick()
	line["public"] = world.get_construction_sites()
	line["jobs"] = _site_jobs(world)
	line["hash"] = world.state_hash()
	return line

func _home(world) -> Vector2i:
	var c0: Dictionary = world.get_colonists()[0]
	return Vector2i(int(c0["x"]), int(c0["y"]))

func _tiles(points: Array) -> Array:
	var out: Array = []
	for p in points:
		out.append({"x": p.x, "y": p.y})
	return out

func _setup(world, results: Array) -> void:
	var h := _home(world)
	var zone := h + Vector2i(-6, -6)
	results.append(world.apply(_cmd(world, "zone_add", {"x": zone.x, "y": zone.y, "width": 5, "height": 5})))
	var i := 0
	for dy in 5:
		for dx in 5:
			var kind := "wood" if (dx + dy) % 2 == 0 else "stone"
			var count := 1 + (i % 3)
			results.append({"placed": world._item_table.place_new_ground_item(kind, count, zone.x + dx, zone.y + dy)})
			i += 1
	_issue(world, results, "build", {"kind": "workbench", "x": h.x + 3, "y": h.y + 3})
	_issue(world, results, "build", {"kind": "workbench", "x": h.x + 4, "y": h.y + 3, "orientation": "vertical"})
	for k in 3:
		_issue(world, results, "build", {"kind": "wooden_wall", "x": h.x - 3 + k, "y": h.y + 5})
	_issue(world, results, "build", {"kind": "bed", "x": h.x + 6, "y": h.y - 2})
	_issue(world, results, "build", {"kind": "door", "x": h.x + 6, "y": h.y - 3})
	_issue(world, results, "build", {"kind": "stone_wall", "x": h.x + 7, "y": h.y - 3})
	_issue(world, results, "build_line", {"kind": "wooden_wall", "tiles": _tiles([h + Vector2i(4, 7), h + Vector2i(2, 7),
		h + Vector2i(3, 7), h + Vector2i(3, 7), h + Vector2i(5, 7), h])})
	_issue(world, results, "build_line", {"kind": "workbench", "tiles": _tiles([h + Vector2i(-4, 2), h + Vector2i(-3, 2),
		h + Vector2i(-2, 2)])})
	_issue(world, results, "build_line", {"kind": "stone_wall", "orientation": "vertical",
		"tiles": _tiles([h + Vector2i(8, 1), h + Vector2i(8, 2), h + Vector2i(8, 3)])})
	# A one-tile pocket at the map corner, then the wall that would seal it.
	_issue(world, results, "build", {"kind": "wooden_wall", "x": 1, "y": 0})
	_issue(world, results, "build_line", {"kind": "wooden_wall", "tiles": _tiles([Vector2i(0, 1), Vector2i(1, 1)])})
	_issue(world, results, "build", {"kind": "wooden_wall", "x": 0, "y": 1})

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150 + from_tick
	for t in range(from_tick, to_tick):
		if t == 0:
			_setup(world, results)
		var h := _home(world)
		if t == 40 or t == 260:
			var trees: Array[Vector2i] = []
			var tiles: Array[String] = world.get_tiles()
			for idx in tiles.size():
				if tiles[idx] == "tree" and trees.size() < 3:
					trees.append(Vector2i(idx % 48, idx / 48))
			for tree in trees:
				results.append(world.apply(_cmd(world, "chop", {"x": tree.x, "y": tree.y, "priority": 1})))
		if t == 180:
			var sites: Array = world.get_construction_sites()
			if not sites.is_empty():
				var origin: Vector2i = sites[sites.size() - 1]["origin"]
				_issue(world, results, "cancel_site", {"x": origin.x, "y": origin.y})
		if t == 330:
			var sites: Array = world.get_construction_sites()
			if not sites.is_empty():
				results.append(world.apply(_cmd(world, "cancel_job", {"job_id": String(sites[0]["id"])})))
		if t % 20 == 10:
			for k in 3:
				var p := h + Vector2i(rng.randi_range(-9, 9), rng.randi_range(-9, 9))
				match rng.randi_range(0, 3):
					0:
						_issue(world, results, "build", {"kind": ["wooden_wall", "door", "bed", "stone_wall"][rng.randi_range(0, 3)], "x": p.x, "y": p.y})
					1:
						_issue(world, results, "build_line", {"kind": "wooden_wall",
							"tiles": _tiles([p, p + Vector2i(1, 0), p + Vector2i(2, 0)])})
					2:
						_issue(world, results, "cancel_site", {"x": p.x, "y": p.y})
					3:
						_issue(world, results, "build", {"kind": "workbench", "x": p.x, "y": p.y,
							"orientation": ["", "horizontal", "vertical"][rng.randi_range(0, 2)]})
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
	var site_lines := 0
	var retargeted := 0
	var picked := 0
	var site_ids := {}
	for line in trace:
		var l: Dictionary = line.get("line", line)
		site_lines += (l["sites"] as Array).size()
		retargeted += (l["retargeted"] as Dictionary).size()
		picked += (l["picked_kind"] as Dictionary).size()
		for site in (l["sites"] as Array):
			site_ids[String(site["id"])] = true
	var applied := 0
	var rejected := 0
	for r in results:
		if r.has("ok") and not r.has("preview"):
			if r["ok"]: applied += 1
			else: rejected += 1
	var objects := {}
	for obj in world.get_objects():
		objects[String(obj["kind"])] = int(objects.get(String(obj["kind"]), 0)) + 1
	var failed: Array = []
	for entry in io:
		if not entry["ok"]:
			failed.append("%d:%s" % [entry["tick"], entry["error"]])
	print("scenario_dump: results=%d applied=%d rejected=%d distinct_sites=%d site_lines=%d retargeted=%d picked_kind=%d objects=%s save_refused=%s hash=%d" % [
		results.size(), applied, rejected, site_ids.size(), site_lines, retargeted, picked, str(objects), str(failed), world.state_hash()])
	quit(0)
