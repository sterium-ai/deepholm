extends SceneTree

## A11: a 500-tick viewer session (the real boot world, incidents on) with a
## mix of accepted and rejected commands is recorded by CommandRecorder,
## written to a file, read back and replayed headless: every state_hash()
## checkpoint matches. A nondeterminism planted inside one tick of the replay
## is reported at the first checkpoint after it, with the last matching
## checkpoint before it; at interval 1 that is the planted tick itself. A
## tampered checkpoint, a dropped command and a content version mismatch are
## each reported with their own code.

const BootType = preload("res://scripts/boot.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")

const SESSION_TICKS := 500
const PLANTED_TICK := 237
const REPLAY_PATH := "user://test_command_replay.json"

var _failed := false
var _next_command := 0

func _init() -> void:
	var recording := _record_session(ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL, 0, SESSION_TICKS)
	_check_recording(recording)
	_check_file_round_trip_replays_every_checkpoint(recording)
	_check_planted_nondeterminism(recording, PLANTED_TICK, 240, 230)
	_check_planted_nondeterminism(_record_session(1, 0, 260), PLANTED_TICK, PLANTED_TICK, PLANTED_TICK - 1)
	_check_recording_started_mid_session()
	_check_tampered_checkpoint(recording)
	_check_malformed_checkpoints(recording)
	_check_dropped_command(recording)
	_check_content_version_mismatch(recording)
	if _failed:
		quit(1)
		return
	print("test_command_replay: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Runs the default boot world for `ticks` ticks, recording from `record_from`.
## Every command goes through world.apply() and then the recorder, exactly the
## path the viewer's command observer takes.
func _record_session(interval: int, record_from: int, ticks: int) -> ReplayLogType:
	var world: WorldStateType = BootType.build_default_world()
	var recorder := CommandRecorderType.new()
	var target_tick := record_from + ticks
	while world.get_tick() < target_tick:
		if world.get_tick() == record_from and not recorder.is_recording():
			recorder.start(world, interval)
		for command in _commands_for_tick(world):
			var result := world.apply(command)
			recorder.observe_command(world, command, result)
		world.tick()
		recorder.observe_tick(world)
	for command in _commands_for_tick(world):
		recorder.observe_command(world, command, world.apply(command))
	return recorder.stop()

## The mixed command stream: orders, an area order, a zone, a wall, labour,
## incidents, a cancel and deliberately rejected commands, all keyed off the
## world's own tick and map so the same seed gives the same stream.
func _commands_for_tick(world: WorldStateType) -> Array[Dictionary]:
	var tick := world.get_tick()
	var clearing := world.get_spawn_clearing()
	var cx := int(clearing["x"])
	var cy := int(clearing["y"])
	var colonists := world.get_colonists()
	var out: Array[Dictionary] = []
	match tick:
		0:
			out.append(_command(world, "set_labour", {"colonist": String(colonists[0]["id"]), "kind": "chop", "level": 4}))
		3:
			var tree := _find_tile(world, WorldStateType.TILE_TREE)
			out.append(_command(world, "chop", {"x": tree.x, "y": tree.y, "priority": 1}))
		7:
			out.append(_previewed(world, "dig", {"priority": 1}))
			var rock := _find_tile(world, WorldStateType.TILE_ROCK)
			out.append(_command(world, "mine", {"x": rock.x, "y": rock.y, "priority": 1}))
		15:
			out.append(_command(world, "area_order", {"order": "chop", "x": maxi(0, cx - 8), "y": maxi(0, cy - 8), "width": 16, "height": 16}))
		25:
			out.append(_command(world, "zone_add", {"x": cx, "y": cy, "width": 2, "height": 2}))
		40:
			out.append(_previewed(world, "build", {"kind": "wooden_wall"}))
		60:
			out.append(_command(world, "spawn_incident", {"id": "trader_visit"}))
		90:
			var jobs := world.get_jobs()
			if not jobs.is_empty():
				out.append(_command(world, "cancel_job", {"job_id": String(jobs[jobs.size() - 1]["id"])}))
		120:
			out.append(_command(world, "spawn_incident", {"id": "wildlife_wander"}))
		150:
			out.append(_command(world, "area_order", {"order": "dig", "x": maxi(0, cx - 6), "y": maxi(0, cy - 6), "width": 12, "height": 12}))
		200:
			out.append(_command(world, "set_labour", {"colonist": String(colonists[colonists.size() - 1]["id"]), "kind": "mine", "level": 0}))
		300:
			out.append(_command(world, "area_order", {"order": "cancel", "x": cx, "y": cy, "width": 4, "height": 4}))
		400:
			out.append(_command(world, "spawn_incident", {"id": "migrant_joins"}))
	if tick % 50 == 25:
		out.append(_command(world, "noop", {"note": "tick %d" % tick}))
		# Rejected: a stale tick, an unknown type, and a float tick that only
		# a lossless file round trip keeps rejected (0.0 is not the int 0).
		var stale := _command(world, "noop", {})
		stale["tick"] = tick + 1
		out.append(stale)
		out.append(_command(world, "bogus_type", {}))
		var float_tick := _command(world, "noop", {})
		float_tick["tick"] = float(tick)
		out.append(float_tick)
	return out

func _command(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	_next_command += 1
	return {"actor": "player", "command_id": "replay_%d" % _next_command, "tick": world.get_tick(), "type": type, "payload": payload}

## The command at the first tile, nearest the clearing's centre first, that
## preview() accepts: the hover check the viewer itself runs before a click.
func _previewed(world: WorldStateType, type: String, payload: Dictionary) -> Dictionary:
	var command := _command(world, type, payload)
	var clearing := world.get_spawn_clearing()
	var center := Vector2i(int(clearing["x"]) + int(clearing["width"]) / 2, int(clearing["y"]) + int(clearing["height"]) / 2)
	for radius in range(1, 12):
		for y in range(center.y - radius, center.y + radius + 1):
			for x in range(center.x - radius, center.x + radius + 1):
				command["payload"]["x"] = x
				command["payload"]["y"] = y
				if world.preview(command).get("ok", false):
					return command
	return command

func _find_tile(world: WorldStateType, kind: String) -> Vector2i:
	var clearing := world.get_spawn_clearing()
	var center := Vector2i(int(clearing["x"]) + int(clearing["width"]) / 2, int(clearing["y"]) + int(clearing["height"]) / 2)
	var best := Vector2i(-1, -1)
	var best_distance := 1 << 30
	for y in world.get_map_height():
		for x in world.get_map_width():
			if world.get_tile(x, y) != kind:
				continue
			var distance := absi(x - center.x) + absi(y - center.y)
			if distance < best_distance:
				best_distance = distance
				best = Vector2i(x, y)
	return best

func _check_recording(recording: ReplayLogType) -> void:
	_expect(recording.start_tick == 0 and recording.end_tick == SESSION_TICKS,
		"recording spans ticks %d..%d, expected 0..%d" % [recording.start_tick, recording.end_tick, SESSION_TICKS])
	_expect(recording.checkpoints.size() == SESSION_TICKS / ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL + 1,
		"expected %d checkpoints, recorded %d" % [SESSION_TICKS / ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL + 1, recording.checkpoints.size()])
	var applied_types := {}
	var rejected := 0
	for entry in recording.commands:
		if bool(entry["ok"]):
			applied_types[String(entry["command"]["type"])] = true
		else:
			rejected += 1
	for type in ["set_labour", "chop", "dig", "mine", "area_order", "zone_add", "build", "spawn_incident", "noop"]:
		_expect(applied_types.has(type), "the recorded session must include an accepted '%s' command (accepted: %s)" % [type, applied_types.keys()])
	_expect(rejected >= 3 * (SESSION_TICKS / 50), "expected the deliberate rejections in the recording, found %d" % rejected)
	var hashes := {}
	for checkpoint in recording.checkpoints:
		hashes[int(checkpoint["hash"])] = true
	_expect(hashes.size() > recording.checkpoints.size() / 2, "checkpoint hashes barely change; the session is not exercising the world")

func _check_file_round_trip_replays_every_checkpoint(recording: ReplayLogType) -> void:
	var written := CommandRecorderType.write_file(recording, REPLAY_PATH)
	_expect(written.get("ok", false), "write_file failed: %s" % [written])
	var read := CommandRecorderType.read_file(REPLAY_PATH)
	if not read.get("ok", false):
		_fail("read_file failed: %s" % [read])
		return
	var loaded: ReplayLogType = read["log"]
	_expect(JSON.stringify(loaded.to_dict()) == JSON.stringify(recording.to_dict()),
		"a replay file must read back to the same log")
	var float_ticks := 0
	for entry in loaded.commands:
		if typeof(entry["command"]["tick"]) == TYPE_FLOAT:
			float_ticks += 1
			_expect(not bool(entry["ok"]), "a float-tick command must have been recorded as rejected")
	_expect(float_ticks == SESSION_TICKS / 50, "the file must keep %d float-tick commands as floats, found %d" % [SESSION_TICKS / 50, float_ticks])
	var result := loaded.replay()
	_expect(result.get("ok", false), "replaying the recorded session must match every checkpoint: %s" % [result])
	_expect(int(result.get("checkpoints", 0)) == recording.checkpoints.size(),
		"replay compared %s checkpoints, expected %d" % [result.get("checkpoints"), recording.checkpoints.size()])
	_expect(int(result.get("commands", 0)) == recording.commands.size(),
		"replay re-applied %s commands, expected %d" % [result.get("commands"), recording.commands.size()])

## A ground tool that appears inside tick `planted` only in the replay stands
## in for any hidden nondeterminism (global RNG, wall clock, dictionary order).
func _check_planted_nondeterminism(recording: ReplayLogType, planted: int, expected_tick: int, expected_last: int) -> void:
	var plant := func(world: WorldStateType, tick: int) -> void:
		if tick == planted:
			var clearing := world.get_spawn_clearing()
			world.spawn_ground_tool_item("pick", int(clearing["x"]), int(clearing["y"]))
	var result := recording.replay(plant)
	_expect(not result.get("ok", true) and result.get("code") == "diverged" and result.get("kind") == "checkpoint",
		"a planted nondeterminism must be reported as a diverged checkpoint: %s" % [result])
	_expect(int(result.get("tick", -1)) == expected_tick,
		"interval %d: nondeterminism planted in tick %d must be reported at tick %d, got %s" % [recording.checkpoint_interval, planted, expected_tick, result.get("tick")])
	_expect(int(result.get("last_matching_tick", -1)) == expected_last,
		"interval %d: last matching checkpoint must be %d, got %s" % [recording.checkpoint_interval, expected_last, result.get("last_matching_tick")])

## Recording can start on a world that has already run (a resumed save, a
## session in progress): the snapshot carries everything the seed cannot.
func _check_recording_started_mid_session() -> void:
	var recording := _record_session(ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL, 45, 120)
	_expect(recording.start_tick == 45 and recording.end_tick == 165, "mid-session recording must span 45..165")
	var result := recording.replay()
	_expect(result.get("ok", false), "a recording started at tick 45 must replay: %s" % [result])

func _check_tampered_checkpoint(recording: ReplayLogType) -> void:
	var tampered := _copy(recording)
	for checkpoint in tampered.checkpoints:
		if int(checkpoint["tick"]) == 300:
			checkpoint["hash"] = int(checkpoint["hash"]) ^ 1
	var result := tampered.replay()
	_expect(not result.get("ok", true) and int(result.get("tick", -1)) == 300 and int(result.get("last_matching_tick", -1)) == 290,
		"a tampered checkpoint at tick 300 must be the reported divergence: %s" % [result])

## A checkpoint off the recorded grid, duplicated, missing or not a whole
## number is refused when read, so replay can never report success with a
## checkpoint left unchecked. The unmutated JSON (whole floats) still reads.
func _check_malformed_checkpoints(recording: ReplayLogType) -> void:
	var cases := {
		"out of range": func(data: Dictionary) -> void: data["checkpoints"].append({"tick": SESSION_TICKS + 5, "hash": 1}),
		"duplicate": func(data: Dictionary) -> void: data["checkpoints"].insert(3, data["checkpoints"][3].duplicate()),
		"missing": func(data: Dictionary) -> void: data["checkpoints"].remove_at(7),
		"off the grid": func(data: Dictionary) -> void: data["checkpoints"][4]["tick"] = 41,
		# Fractions are refused, never truncated back onto the grid (40.5 is not 40).
		"fractional tick": func(data: Dictionary) -> void: data["checkpoints"][4]["tick"] = 40.5,
		"fractional hash": func(data: Dictionary) -> void: data["checkpoints"][4]["hash"] = float(data["checkpoints"][4]["hash"]) + 0.5,
		"fractional command tick": func(data: Dictionary) -> void: data["commands"][0]["tick"] = 0.5,
		"fractional endTick": func(data: Dictionary) -> void: data["endTick"] = float(SESSION_TICKS) + 0.5,
		"fractional interval": func(data: Dictionary) -> void: data["checkpointInterval"] = 10.5,
		"string tick": func(data: Dictionary) -> void: data["checkpoints"][4]["tick"] = "40",
	}
	var untouched := ReplayLogType.from_dict(JSON.parse_string(JSON.stringify(recording.to_dict())))
	_expect(untouched.get("ok", false), "the unmutated JSON must still read: %s" % [untouched])
	for label: String in cases:
		var data: Dictionary = JSON.parse_string(JSON.stringify(recording.to_dict()))
		var mutate: Callable = cases[label]
		mutate.call(data)
		var parsed := ReplayLogType.from_dict(data)
		_expect(not parsed.get("ok", true) and parsed.get("code") == "invalid_replay",
			"a %s checkpoint must be refused as invalid_replay: %s" % [label, parsed])
	# A malformed start snapshot is refused before StateCodec.decode() sees it.
	var snapshots := {
		"empty": {},
		"missing map": _without(recording.initial_state, "map"),
		"older schemaVersion": _with(recording.initial_state, "schemaVersion", int(recording.initial_state["schemaVersion"]) - 1),
		"wrong-typed tick": _with(recording.initial_state, "tick", "zero"),
	}
	for label: String in snapshots:
		var data: Dictionary = JSON.parse_string(JSON.stringify(recording.to_dict()))
		data["initialState"] = Marshalls.variant_to_base64(snapshots[label])
		var parsed := ReplayLogType.from_dict(data)
		_expect(not parsed.get("ok", true) and parsed.get("code") == "invalid_replay",
			"a %s initialState must be refused as invalid_replay: %s" % [label, parsed])
	var empty_snapshot := _copy(recording)
	empty_snapshot.initial_state = {}
	var refused := empty_snapshot.replay()
	_expect(not refused.get("ok", true) and refused.get("code") == "invalid_replay",
		"replay() must refuse an empty initialState set in memory: %s" % [refused])
	var in_memory := _copy(recording)
	in_memory.checkpoints.remove_at(2)
	var result := in_memory.replay()
	_expect(not result.get("ok", true) and result.get("code") == "invalid_replay",
		"replay() must refuse a log with a checkpoint removed in memory: %s" % [result])

func _check_dropped_command(recording: ReplayLogType) -> void:
	var dropped := _copy(recording)
	var index := -1
	for i in dropped.commands.size():
		if String(dropped.commands[i]["command"]["type"]) == "zone_add":
			index = i
	dropped.commands.remove_at(index)
	var result := dropped.replay()
	_expect(not result.get("ok", true) and result.get("code") == "diverged" and int(result.get("tick", -1)) == 30,
		"dropping the tick-25 zone_add must diverge at checkpoint 30: %s" % [result])

func _check_content_version_mismatch(recording: ReplayLogType) -> void:
	var other := _copy(recording)
	other.content_version = "0.0.0-other"
	var result := other.replay()
	_expect(result.get("code") == "content_version_mismatch", "a different content version must be refused: %s" % [result])

func _without(state: Dictionary, key: String) -> Dictionary:
	var copy := state.duplicate(true)
	copy.erase(key)
	return copy

func _with(state: Dictionary, key: String, value: Variant) -> Dictionary:
	var copy := state.duplicate(true)
	copy[key] = value
	return copy

func _copy(recording: ReplayLogType) -> ReplayLogType:
	var parsed := ReplayLogType.from_dict(JSON.parse_string(JSON.stringify(recording.to_dict())))
	return parsed["log"]
