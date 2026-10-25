extends SceneTree

## R4 byte-identity probe for the work-progress maps. Plays R2's fixed scenario (seed 777,
## 48x48, 10 colonists, incidents on: digs that open trenches and trigger rescues, chops,
## mines, forages, till + sow, hauls, trader visits, random orders) for 800 ticks, and every
## 100 ticks round-trips the world through to_save_state()/from_save_state() and carries on
## with the reloaded copy, so restore_owners() runs seven times on live mid-work state. At
## ticks 250 and 650 it also loads a copy of the save with "workProgressOwners" removed
## (the legacy-save reconstruction path) and dumps what survives.
## Every 5 ticks it traces the three maps (progress, owners, suspended) and state_hash().
## Writes everything to the directory given as the first user argument; run before and
## after the refactor and diff the files. Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

var _n := 0

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

func _nearest_tiles(world, kind: String, from: Vector2i, count: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	var w: int = world.get_map_width()
	var tiles: Array[String] = world.get_tiles()
	for i in tiles.size():
		if tiles[i] == kind:
			found.append(Vector2i(i % w, i / w))
	found.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := absi(a.x - from.x) + absi(a.y - from.y)
		var db := absi(b.x - from.x) + absi(b.y - from.y)
		if da != db:
			return da < db
		return a.y * w + a.x < b.y * w + b.x)
	return found.slice(0, count)

func _nearest_objects(world, kind: String, from: Vector2i, count: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for obj in world.get_objects():
		if String(obj.get("kind", "")) == kind:
			found.append(Vector2i(int(obj["x"]), int(obj["y"])))
	found.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := absi(a.x - from.x) + absi(a.y - from.y)
		var db := absi(b.x - from.x) + absi(b.y - from.y)
		if da != db:
			return da < db
		return a.y * 1000 + a.x < b.y * 1000 + b.x)
	return found.slice(0, count)

func _order_wave(world, results: Array, wave: int) -> void:
	var c0: Dictionary = world.get_colonists()[0]
	var home := Vector2i(int(c0["x"]), int(c0["y"]))
	for t in _nearest_tiles(world, "soil", home, 4 + 2 * wave):
		results.append(world.apply(_cmd(world, "dig", {"x": t.x, "y": t.y, "priority": 1})))
	for t in _nearest_tiles(world, "tree", home, 3):
		results.append(world.apply(_cmd(world, "chop", {"x": t.x, "y": t.y, "priority": 2})))
	for t in _nearest_tiles(world, "rock", home, 2):
		results.append(world.apply(_cmd(world, "mine", {"x": t.x, "y": t.y, "priority": 2})))
	for t in _nearest_objects(world, "berry_bush", home, 2):
		results.append(world.apply(_cmd(world, "forage", {"x": t.x, "y": t.y, "priority": 2})))
	for t in _nearest_tiles(world, "plowed_soil", home, 1):
		results.append(world.apply(_cmd(world, "sow", {"x": t.x, "y": t.y, "priority": 1})))
	for t in _nearest_tiles(world, "soil", home + Vector2i(3, 3), 1):
		results.append(world.apply(_cmd(world, "till", {"x": t.x, "y": t.y, "priority": 1})))

## The three maps, from WorldState's fields on main or from WorkProgress after R4.
func _maps(world) -> Dictionary:
	var table = world.get("_progress_table")
	if table != null:
		return {"progress": table.progress, "owners": table.owners, "suspended": table.suspended}
	return {"progress": world.get("_work_progress"), "owners": world.get("_work_progress_owner"),
		"suspended": world.get("_suspended_work_progress")}

func _trace_line(world) -> Dictionary:
	var line := _maps(world)
	line["tick"] = world.get_tick()
	line["hash"] = world.state_hash()
	return line

func _play(world, results: Array, trace: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242 + from_tick
	for t in range(from_tick, to_tick):
		if t == 0:
			var c0: Dictionary = world.get_colonists()[0]
			for kind in ["pick", "pick", "axe"]:
				results.append({"spawned_tool": world.spawn_ground_tool_item(kind, int(c0["x"]), int(c0["y"]))})
		if t % 120 == 0:
			_order_wave(world, results, t / 120)
		if t % 25 == 0:
			for k in 3:
				var x := rng.randi_range(0, 47)
				var y := rng.randi_range(0, 47)
				var kind: String = ["dig", "chop", "forage", "till", "mine", "sow"][rng.randi_range(0, 5)]
				results.append(world.apply(_cmd(world, kind, {"x": x, "y": y, "priority": 1})))
		if t == 5:
			var c0: Dictionary = world.get_colonists()[0]
			results.append(world.apply(_cmd(world, "zone_add", {"x": int(c0["x"]) - 2, "y": int(c0["y"]) - 2, "width": 3, "height": 3})))
		if t == 150 or t == 500:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "trader_visit"})))
		if t == 60 or t == 460:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "wolf_attack"})))
		for offer in world.get_pending_trade_offers():
			results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": offer["trader_id"]})))
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
	var legacy: Array = []
	for step in 8:
		var from := step * 100
		_play(world, results, trace, from, from + 100)
		var state: Dictionary = world.to_save_state()
		saves.append(state)
		var check := SaveIOType.write_atomic(out_dir.path_join("save_%d.json" % (from + 100)), state)
		io.append({"tick": from + 100, "ok": check.get("ok"), "error": "%s %s" % [check.get("code", ""), check.get("message", "")]})
		world = WorldStateType.from_save_state(state.duplicate(true))
		world.enable_incidents()
		trace.append({"reloaded": from + 100, "maps": _maps(world), "hash": world.state_hash()})
	for at in [2, 6]:
		var state: Dictionary = (saves[at] as Dictionary).duplicate(true)
		state.erase("workProgressOwners")
		var legacy_world = WorldStateType.from_save_state(state)
		legacy.append({"from_save": (at + 1) * 100, "maps": _maps(legacy_world), "hash": legacy_world.state_hash(),
			"resaved": legacy_world.to_save_state()})
	_write(out_dir.path_join("states.json"), JSON.stringify(saves, "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify(results, "\t"))
	_write(out_dir.path_join("legacy.json"), JSON.stringify(legacy, "\t"))
	_write(out_dir.path_join("io.json"), JSON.stringify(io, "\t"))
	var keys := 0
	var scoped := 0
	var owned := 0
	var suspended := 0
	for line in trace:
		if line.has("progress"):
			keys += (line["progress"] as Dictionary).size()
			owned += (line["owners"] as Dictionary).size()
			suspended += (line["suspended"] as Dictionary).size()
			for k in (line["progress"] as Dictionary):
				if String(k).contains(":"):
					scoped += 1
	var failed: Array = []
	for entry in io:
		if not entry["ok"]:
			failed.append("%d:%s" % [entry["tick"], entry["error"]])
	print("scenario_dump: results=%d progress_keys=%d scoped=%d owners=%d suspended=%d save_refused=%s hash=%d" % [
		results.size(), keys, scoped, owned, suspended, str(failed), world.state_hash()])
	quit(0)
