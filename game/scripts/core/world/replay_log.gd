class_name ReplayLog
extends RefCounted

## A recorded session (A11): the starting state, every command the session
## applied in apply() order, and state_hash() checkpoints taken while it ran,
## plus the headless replay that checks them. No file I/O and no
## scene/node/RNG/wall-clock dependency; it only reads the world it is handed
## (state_hash(), to_save_state()) and replays through apply()/tick().
## viewer/command_recorder.gd drives recording and owns the file;
## tools/replay.ps1 replays a file.
##
## Invariants:
## - Checkpoint T is state_hash() right after the tick() that brought the clock
##   to T, before any command of tick T. The first one is start_tick itself,
##   taken before the first command; then every checkpoint_interval ticks,
##   with none missing, duplicated or off that grid (validate()). Replay
##   compares every one of them or reports invalid_replay.
## - commands stays in apply() order, so its "tick" fields never decrease.
##   Rejected commands are kept too: some rejections still draw a JobQueue
##   sequence, and replay checks each command's "ok" against the recording.
## - final_hash is state_hash() at end_tick after that tick's commands.
## - to_dict() is JSON-safe and lossless: initial_state travels as a base64
##   Variant blob (64-bit RNG states survive), each command as
##   JSON.from_native() (an int stays an int and a float a float, so a command
##   rejected for a float value is still rejected on replay), the seed as a
##   string, and every other number fits a double exactly.

const FORMAT := "deepholm-replay"
const FORMAT_VERSION := 1
const DEFAULT_CHECKPOINT_INTERVAL := 10
## 2^53: above it a JSON number (a double) no longer holds every integer.
const MAX_EXACT_JSON_INT := 9007199254740992.0

var content_version: String = ""
var generator_version: int = 0
var world_seed: int = 0
## decode() always builds incidents disabled; replay re-enables them when this is true.
var incidents_enabled: bool = false
var start_tick: int = 0
var end_tick: int = 0
var checkpoint_interval: int = DEFAULT_CHECKPOINT_INTERVAL
## WorldState.to_save_state() at start_tick, before any recorded command.
var initial_state: Dictionary = {}
## {"tick": int, "ok": bool, "command": Dictionary}, in apply() order.
var commands: Array[Dictionary] = []
## {"tick": int, "hash": int}, in tick order.
var checkpoints: Array[Dictionary] = []
var final_hash: int = 0

## A new log whose first checkpoint is `world` as it stands now.
static func begin(world: WorldState, interval: int, with_incidents: bool) -> ReplayLog:
	var started := ReplayLog.new()
	started.content_version = StateCodec.content_version()
	started.generator_version = world.get_generator_version()
	started.world_seed = world.get_seed()
	started.incidents_enabled = with_incidents
	started.start_tick = world.get_tick()
	started.checkpoint_interval = maxi(1, interval)
	started.initial_state = world.to_save_state().duplicate(true)
	started.record_checkpoint(world.get_tick(), world.state_hash())
	return started

func is_checkpoint_tick(tick: int) -> bool:
	return tick >= start_tick and (tick - start_tick) % checkpoint_interval == 0

func record_command(tick: int, command: Dictionary, ok: bool) -> void:
	commands.append({"tick": tick, "ok": ok, "command": command.duplicate(true)})

func record_checkpoint(tick: int, state_hash: int) -> void:
	checkpoints.append({"tick": tick, "hash": state_hash})

## Called after every tick() of the recorded world.
func observe_tick(world: WorldState) -> void:
	if is_checkpoint_tick(world.get_tick()):
		record_checkpoint(world.get_tick(), world.state_hash())

func finish(world: WorldState) -> void:
	end_tick = world.get_tick()
	final_hash = world.state_hash()

## tick -> recorded hash.
func checkpoint_index() -> Dictionary[int, int]:
	var by_tick: Dictionary[int, int] = {}
	for checkpoint in checkpoints:
		var tick: int = checkpoint["tick"]
		var state_hash: int = checkpoint["hash"]
		by_tick[tick] = state_hash
	return by_tick

## Replays this log headless. after_tick(world, tick) runs after every tick(),
## before that tick's checkpoint is compared (tests plant nondeterminism there).
## Returns {"ok": true, "ticks", "checkpoints", "commands"} or {"ok": false,
## "code"} where code is content_version_mismatch, generator_version_mismatch
## or diverged; a divergence names "tick" (the first checkpoint that differs),
## "last_matching_tick", "kind" (checkpoint, command_result or final_hash),
## and the expected/actual values.
func replay(after_tick: Callable = Callable()) -> Dictionary:
	var invalid := validate()
	if invalid != "":
		return _invalid(invalid)
	var running_content := StateCodec.content_version()
	if content_version != running_content:
		return {"ok": false, "code": "content_version_mismatch",
			"message": "recorded with content %s, running %s" % [content_version, running_content]}
	if generator_version != WorldGenerator.GENERATOR_VERSION:
		return {"ok": false, "code": "generator_version_mismatch",
			"message": "recorded with generator %d, running %d" % [generator_version, WorldGenerator.GENERATOR_VERSION]}
	var world := WorldState.from_save_state(initial_state.duplicate(true))
	if incidents_enabled:
		world.enable_incidents()
	var expected := checkpoint_index()
	var last_matching := -1
	var compared := 0
	var next_command := 0
	var tick := world.get_tick()
	while true:
		if expected.has(tick):
			var actual := world.state_hash()
			if actual != expected[tick]:
				return _diverged("checkpoint", tick, last_matching, expected[tick], actual)
			last_matching = tick
			compared += 1
		while next_command < commands.size() and commands[next_command]["tick"] == tick:
			var entry: Dictionary = commands[next_command]
			var command: Dictionary = entry["command"]
			var recorded_ok: bool = entry["ok"]
			var result := world.apply(command.duplicate(true))
			var replayed_ok: bool = result.get("ok", false)
			if replayed_ok != recorded_ok:
				var diverged := _diverged("command_result", tick, last_matching, int(recorded_ok), int(replayed_ok))
				diverged["command_id"] = command.get("command_id", "")
				return diverged
			next_command += 1
		if tick >= end_tick:
			break
		world.tick()
		tick = world.get_tick()
		if after_tick.is_valid():
			after_tick.call(world, tick)
	if compared != checkpoints.size():
		return _invalid("compared %d of %d recorded checkpoints" % [compared, checkpoints.size()])
	var replayed_final := world.state_hash()
	if replayed_final != final_hash:
		return _diverged("final_hash", tick, last_matching, final_hash, replayed_final)
	return {"ok": true, "ticks": end_tick - start_tick, "checkpoints": compared, "commands": next_command}

static func _diverged(kind: String, tick: int, last_matching: int, expected: int, actual: int) -> Dictionary:
	return {"ok": false, "code": "diverged", "kind": kind, "tick": tick, "last_matching_tick": last_matching,
		"expected": expected, "actual": actual}

## "" when the log is well formed, else what is wrong: initial_state is a save
## state of this build's schema that passes SaveIO's full schema check (so
## from_save_state() never sees a malformed snapshot), the checkpoints are
## exactly start_tick, then every checkpoint_interval ticks up to end_tick,
## and command ticks never decrease within [start_tick, end_tick].
func validate() -> String:
	if checkpoint_interval < 1 or end_tick < start_tick:
		return "checkpointInterval must be >= 1 and endTick >= startTick"
	if typeof(initial_state.get("schemaVersion")) != TYPE_INT or initial_state["schemaVersion"] != StateCodec.SCHEMA_VERSION:
		return "initialState must be a save state of schemaVersion %d, found %s" % [StateCodec.SCHEMA_VERSION, str(initial_state.get("schemaVersion"))]
	var snapshot := SaveIO._validate_state(initial_state)
	if not snapshot.get("ok", false):
		return "initialState is not a valid save state (%s: %s)" % [str(snapshot.get("code")), str(snapshot.get("message"))]
	var last_tick := start_tick
	for entry in commands:
		if typeof(entry.get("tick")) != TYPE_INT:
			return "every command tick must be an int"
		var tick: int = entry["tick"]
		if tick < last_tick or tick > end_tick:
			return "command ticks must be non-decreasing within [startTick, endTick]"
		if typeof(entry.get("command")) != TYPE_DICTIONARY or typeof(entry.get("ok")) != TYPE_BOOL:
			return "every commands entry needs a command Dictionary and a bool ok"
		last_tick = tick
	for i in checkpoints.size():
		if typeof(checkpoints[i].get("tick")) != TYPE_INT:
			return "checkpoint %d tick must be an int" % i
		var tick: int = checkpoints[i]["tick"]
		if tick != start_tick + i * checkpoint_interval or tick > end_tick or typeof(checkpoints[i].get("hash")) != TYPE_INT:
			return "checkpoint %d must be at tick %d (<= endTick) with an int hash" % [i, start_tick + i * checkpoint_interval]
	if checkpoints.is_empty() or start_tick + checkpoints.size() * checkpoint_interval <= end_tick:
		return "checkpoints stop before endTick %d (every %d ticks from %d)" % [end_tick, checkpoint_interval, start_tick]
	return ""

func to_dict() -> Dictionary:
	return {
		"format": FORMAT,
		"formatVersion": FORMAT_VERSION,
		"contentVersion": content_version,
		"generatorVersion": generator_version,
		"seed": str(world_seed),
		"incidentsEnabled": incidents_enabled,
		"startTick": start_tick,
		"endTick": end_tick,
		"checkpointInterval": checkpoint_interval,
		"initialState": Marshalls.variant_to_base64(initial_state),
		"commands": _commands_to_json(),
		"checkpoints": checkpoints.duplicate(true),
		"finalHash": final_hash,
	}

## {"ok": true, "log": ReplayLog} or {"ok": false, "code": "invalid_replay", "message": String}.
static func from_dict(data: Dictionary) -> Dictionary:
	if data.get("format") != FORMAT:
		return _invalid("not a %s file" % FORMAT)
	if _whole(data.get("formatVersion")) != FORMAT_VERSION:
		return _invalid("unsupported formatVersion %s (expected %d)" % [str(data.get("formatVersion")), FORMAT_VERSION])
	for key: String in ["contentVersion", "generatorVersion", "seed", "incidentsEnabled", "startTick", "endTick",
			"checkpointInterval", "initialState", "commands", "checkpoints", "finalHash"]:
		if not data.has(key):
			return _invalid("missing field '%s'" % key)
	# Every number must be a whole JSON number: 40.5 is refused, never truncated to 40.
	for key: String in ["generatorVersion", "startTick", "endTick", "checkpointInterval", "finalHash"]:
		if _whole(data[key]) == null:
			return _invalid("%s must be a whole number, found %s" % [key, str(data[key])])
	if typeof(data["seed"]) != TYPE_STRING or not str(data["seed"]).is_valid_int():
		return _invalid("seed must be a decimal integer string")
	if typeof(data["incidentsEnabled"]) != TYPE_BOOL:
		return _invalid("incidentsEnabled must be a bool")
	var replay_log := ReplayLog.new()
	replay_log.content_version = str(data["contentVersion"])
	replay_log.generator_version = _whole(data["generatorVersion"])
	replay_log.world_seed = str(data["seed"]).to_int()
	replay_log.incidents_enabled = data["incidentsEnabled"]
	replay_log.start_tick = _whole(data["startTick"])
	replay_log.end_tick = _whole(data["endTick"])
	replay_log.checkpoint_interval = _whole(data["checkpointInterval"])
	replay_log.final_hash = _whole(data["finalHash"])
	var state: Variant = Marshalls.base64_to_variant(str(data["initialState"]))
	if typeof(state) != TYPE_DICTIONARY:
		return _invalid("initialState does not decode to a Dictionary")
	replay_log.initial_state = state
	if typeof(data["commands"]) != TYPE_ARRAY or typeof(data["checkpoints"]) != TYPE_ARRAY:
		return _invalid("commands and checkpoints must be arrays")
	var raw_commands: Array = data["commands"]
	var raw_checkpoints: Array = data["checkpoints"]
	for i in raw_commands.size():
		if typeof(raw_commands[i]) != TYPE_DICTIONARY:
			return _invalid("every commands entry must be a Dictionary")
		var entry: Dictionary = raw_commands[i]
		var tick: Variant = _whole(entry.get("tick"))
		if tick == null:
			return _invalid("commands[%d].tick must be a whole number, found %s" % [i, str(entry.get("tick"))])
		replay_log.commands.append({"tick": tick, "ok": entry.get("ok"), "command": JSON.to_native(entry.get("command"))})
	for i in raw_checkpoints.size():
		if typeof(raw_checkpoints[i]) != TYPE_DICTIONARY:
			return _invalid("every checkpoints entry must be a Dictionary")
		var entry: Dictionary = raw_checkpoints[i]
		var tick: Variant = _whole(entry.get("tick"))
		var state_hash: Variant = _whole(entry.get("hash"))
		if tick == null or state_hash == null:
			return _invalid("checkpoints[%d] tick and hash must be whole numbers, found %s" % [i, str(entry)])
		replay_log.checkpoints.append({"tick": tick, "hash": state_hash})
	var invalid := replay_log.validate()
	if invalid != "":
		return _invalid(invalid)
	return {"ok": true, "log": replay_log}

static func _invalid(message: String) -> Dictionary:
	return {"ok": false, "code": "invalid_replay", "message": message}

## The int a JSON number stands for, or null when it is not a whole number
## that a double holds exactly (a fraction, a string, a missing value...).
static func _whole(value: Variant) -> Variant:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT:
		var number: float = value
		if number == floorf(number) and absf(number) <= MAX_EXACT_JSON_INT:
			return int(number)
	return null

func _commands_to_json() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in commands:
		out.append({"tick": entry["tick"], "ok": entry["ok"], "command": JSON.from_native(entry["command"])})
	return out
