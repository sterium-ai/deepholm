extends RefCounted

## Records a viewer session into a ReplayLog (A11) and owns its file. start()
## begins a log on the current world, observe_command() takes every apply()
## call with its result, observe_tick() runs after every tick(), stop()
## closes the log; write_file()/read_file() move it to and from disk.
## ReplayLog itself snapshots, hashes and replays the world (core side of
## the boundary); this module only routes the viewer's calls to it.
##
## Mutates no simulation state: ReplayLog only reads state_hash() and
## to_save_state(), which the autosave and the boot hash also call.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")

var _world: WorldStateType = null
var _log: ReplayLogType = null

func is_recording() -> bool:
	return _log != null

## Starts a new recording of `world` from its current tick. The boot world,
## New Game and a resumed save all run with incidents enabled.
func start(world: WorldStateType, checkpoint_interval: int = ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL, incidents_enabled: bool = true) -> void:
	_world = world
	_log = ReplayLogType.begin(world, checkpoint_interval, incidents_enabled)

## Called with every command the recorded world applied and apply()'s result.
## A command for another world (the viewer swapped worlds) is ignored.
func observe_command(world: WorldStateType, command: Variant, result: Dictionary) -> void:
	if _log == null or world != _world or typeof(command) != TYPE_DICTIONARY:
		return
	_log.record_command(world.get_tick(), command, bool(result.get("ok", false)))

## Called after every tick() of the recorded world.
func observe_tick(world: WorldStateType) -> void:
	if _log == null or world != _world:
		return
	_log.observe_tick(world)

## Closes and returns the log (null when not recording).
func stop() -> ReplayLogType:
	if _log == null:
		return null
	var finished := _log
	finished.finish(_world)
	_log = null
	_world = null
	return finished

static func write_file(replay_log: ReplayLogType, path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "code": "write_failed", "message": "cannot open %s: %s" % [path, error_string(FileAccess.get_open_error())]}
	file.store_string(JSON.stringify(replay_log.to_dict(), "\t"))
	file.close()
	return {"ok": true, "path": path}

## ReplayLog.from_dict()'s result, or missing_file / invalid_replay.
static func read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "missing_file", "message": "no replay file at %s" % path}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "code": "invalid_replay", "message": "%s is not a JSON object" % path}
	return ReplayLogType.from_dict(parsed)
