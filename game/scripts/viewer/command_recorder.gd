extends RefCounted

## Records a viewer session into a ReplayLog (A11) and owns its file. start()
## begins a log on the current world and sets that world's command_observer,
## so observe_command() hears every apply() call with its result, wherever in
## the viewer it came from; observe_tick() runs after every tick() (boot.gd's
## ticked handler); stop() clears the observer and closes the log;
## write_file()/read_file() move it to and from disk. One recorder owns the
## world's single observer slot while it records.
## ReplayLog itself snapshots, hashes and replays the world (core side of
## the boundary); this module only routes the viewer's calls to it.
##
## Mutates no simulation state: ReplayLog only reads state_hash() and
## to_save_state(), which the autosave and the boot hash also call.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ReplayLogType = preload("res://scripts/core/world/replay_log.gd")

const REPLAY_DIR := "user://replays"

var _world: WorldStateType = null
var _log: ReplayLogType = null

func is_recording() -> bool:
	return _log != null

## Starts a new recording of `world` from its current tick. The boot world,
## New Game and a resumed save all run with incidents enabled.
func start(world: WorldStateType, checkpoint_interval: int = ReplayLogType.DEFAULT_CHECKPOINT_INTERVAL, incidents_enabled: bool = true) -> void:
	_world = world
	_log = ReplayLogType.begin(world, checkpoint_interval, incidents_enabled)
	world.command_observer = observe_command.bind(world)

## WorldState.command_observer, bound to the recorded world: every command it
## applied and apply()'s result. A command for another world is ignored.
func observe_command(command: Variant, result: Dictionary, world: WorldStateType) -> void:
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
	_world.command_observer = Callable()
	_log = null
	_world = null
	return finished

## REPLAY_DIR/replay-<seed>-t<start>-<end tick>-<local date and time>.json, creating
## the folder. The wall clock only names the file; it never reaches the log.
static func session_path(replay_log: ReplayLogType) -> String:
	DirAccess.make_dir_recursive_absolute(REPLAY_DIR)
	var stamp := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "-")
	return "%s/replay-%d-t%d-%d-%s.json" % [REPLAY_DIR, replay_log.world_seed, replay_log.start_tick, replay_log.end_tick, stamp]

static func write_file(replay_log: ReplayLogType, path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "code": "write_failed", "path": path, "error": error_string(FileAccess.get_open_error())}
	file.store_string(JSON.stringify(replay_log.to_dict(), "\t"))
	file.close()
	return {"ok": true, "path": path}

## ReplayLog.from_dict()'s result, or missing_file / invalid_replay. Only the
## headless replay tool reads replays, so the messages are developer text,
## like ReplayLog's own (dev-text: test_viewer_text_lint.gd skips those lines).
static func read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "code": "missing_file", "message": "no replay file at %s" % path}  # dev-text
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "code": "invalid_replay", "message": "%s is not a JSON object" % path}  # dev-text
	return ReplayLogType.from_dict(parsed)
