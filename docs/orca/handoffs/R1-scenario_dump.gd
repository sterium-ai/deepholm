extends SceneTree

## R1 byte-identity probe: plays a fixed scenario (orders, rejections, incidents, ticks,
## a save/load round trip), then writes the save JSON and the event log to the directory
## given as the first user argument. Run before and after the refactor and diff the files.
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/R1.md:
##   godot --headless --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

var _n := 0

func _cmd(world, type: String, payload: Dictionary, actor: String = "player") -> Dictionary:
	_n += 1
	return {"actor": actor, "command_id": "c%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload}

func _play(world, results: Array, from_tick: int, to_tick: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242 + from_tick
	for t in range(from_tick, to_tick):
		if t % 25 == 0:
			for k in 4:
				var x := rng.randi_range(0, 47)
				var y := rng.randi_range(0, 47)
				var kind: String = ["dig", "chop", "forage", "till", "mine"][rng.randi_range(0, 4)]
				results.append(world.apply(_cmd(world, kind, {"x": x, "y": y, "priority": 1})))
				results.append(world.preview(_cmd(world, "place_object", {"x": x, "y": y, "kind": "wall"})))
			results.append(world.apply(_cmd(world, "bogus", {})))
			results.append(world.apply({"actor": "player", "command_id": "bad_tick_%d" % t, "tick": -1, "type": "dig", "payload": {}}))
			results.append(world.apply(_cmd(world, "cancel_job", {"job_id": "job_999999"})))
		if t == 60:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "trader_visit"})))
		if t == 120:
			results.append(world.apply(_cmd(world, "spawn_incident", {"id": "wolf_attack"})))
		if t == 180:
			results.append(world.apply(_cmd(world, "zone_add", {"x": 2, "y": 2, "width": 3, "height": 3})))
		world.tick()

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	var world = WorldStateType.new(777, 10, 48, 48, true)
	var results: Array = []
	_play(world, results, 0, 400)
	var first := world.to_save_state()
	var io1 := SaveIOType.write_atomic(out_dir.path_join("save_400.json"), first)
	_write(out_dir.path_join("events_400.json"), JSON.stringify(world.get_events(), "\t"))
	var loaded = WorldStateType.from_save_state(first)
	var results2: Array = []
	_play(loaded, results2, 400, 700)
	var io2 := SaveIOType.write_atomic(out_dir.path_join("save_700.json"), loaded.to_save_state())
	_write(out_dir.path_join("events_700.json"), JSON.stringify(loaded.get_events(), "\t"))
	_write(out_dir.path_join("results.json"), JSON.stringify({"a": results, "b": results2, "hash400": world.state_hash(), "hash700": loaded.state_hash()}, "\t"))
	print("scenario_dump: io1=%s io2=%s events=%d/%d hash=%d/%d" % [io1.get("ok"), io2.get("ok"), world.get_events().size(), loaded.get_events().size(), world.state_hash(), loaded.state_hash()])
	quit(0)
