extends SceneTree

## R2 byte-identity probe: plays a fixed item-heavy scenario (digs with find rolls,
## chops, mines, forages, a till + sow, a stockpile zone with hauls, a trader visit with
## accept_trade, random orders and rejections), with a save/load round trip in the middle.
## Writes the two saves, a per-tick item trace (ground items, ground berries, the dig-find
## RNG state, state_hash) and every command result to the directory given as the first
## user argument. Run before and after the refactor and diff the files.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R2.md:
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

var _n := 0

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

## The `count` tiles of `kind` nearest to `from` (ties by row-major order).
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

func _trace_line(world) -> Dictionary:
	var berries := {}
	for y in world.get_map_height():
		for x in world.get_map_width():
			var b: int = world.get_ground_berries(x, y)
			if b > 0:
				berries["%d_%d" % [x, y]] = [b, world.get_ground_berries_faction_id(x, y)]
	var save: Dictionary = world.to_save_state()
	return {"tick": world.get_tick(), "items": world.get_items(), "berries": berries,
		"digFindRng": save["digFindRng"], "nextItemId": save["items"]["nextId"], "hash": world.state_hash()}

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
			results.append(world.apply(_cmd(world, "bogus", {})))
		if t == 5:
			var c0: Dictionary = world.get_colonists()[0]
			results.append(world.apply(_cmd(world, "zone_add", {"x": int(c0["x"]) - 2, "y": int(c0["y"]) - 2, "width": 3, "height": 3})))
		if t == 150 or t == 500:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "trader_visit"})))
		for offer in world.get_pending_trade_offers():
			results.append(world.apply(_cmd(world, "accept_trade", {"trader_id": offer["trader_id"]})))
		world.tick()
		if t % 10 == 0:
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
	_play(world, results, trace, 0, 400)
	var first := world.to_save_state()
	var io1 := SaveIOType.write_atomic(out_dir.path_join("save_400.json"), first)
	var loaded = WorldStateType.from_save_state(first)
	var results2: Array = []
	_play(loaded, results2, trace, 400, 800)
	var second: Dictionary = loaded.to_save_state()
	# SaveIO validates before writing; also dump the raw state so a validation refusal never hides a diff.
	_write(out_dir.path_join("state_400.json"), JSON.stringify(first, "	"))
	_write(out_dir.path_join("state_800.json"), JSON.stringify(second, "	"))
	var io2 := SaveIOType.write_atomic(out_dir.path_join("save_800.json"), second)
	_write(out_dir.path_join("events.json"), JSON.stringify([world.get_events(), loaded.get_events()], "\t"))
	_write(out_dir.path_join("trace.json"), JSON.stringify(trace, "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify({"a": results, "b": results2, "hash400": world.state_hash(), "hash800": loaded.state_hash()}, "\t"))
	var last: Dictionary = trace[trace.size() - 1]
	if not io2.get("ok"): print("io2: ", io2)
	print("scenario_dump: io1=%s io2=%s results=%d/%d items=%d nextItemId=%d digRng=%s hash=%d/%d" % [io1.get("ok"), io2.get("ok"),
		results.size(), results2.size(), (last["items"] as Array).size(), int(last["nextItemId"]), str(last["digFindRng"]), world.state_hash(), loaded.state_hash()])
	quit(0)
