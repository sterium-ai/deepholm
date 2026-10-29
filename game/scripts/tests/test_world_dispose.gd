extends SceneTree

## A7 (ADR 058) review round 1: WorldState.dispose() frees the world it is called on and
## nothing else. The disposer walks only what the world owns, so what the caller handed in or
## hooked on survives it:
## - a CommandRecorder recording the world through command_observer keeps its log (the
##   observer Callable is reset, never followed): its commands, initial state and checkpoints;
## - the session ContentRegistry and the WorldSetup passed to WorldState.new() keep their data,
##   and a new world built on them hashes like one built before the dispose;
## - the disposed world itself is freed once dropped (no RefCounted cycle left).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldSetupType = preload("res://scripts/core/world/world_setup.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")

const SEED := 4242
const SIZE := 32
const TICKS := 30

var _failed := false

func _init() -> void:
	_check_recorder_survives_dispose()
	_check_registry_and_setup_survive_dispose()
	_check_disposed_world_is_freed()
	if _failed:
		quit(1)
		return
	print("test_world_dispose: PASS")
	quit()

func _fail(message: String) -> void:
	_failed = true
	push_error(message)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Records a few ticks of orders and disposes the world mid-recording. stop() would read the
## disposed world (ReplayLog.finish()), so the log is inspected directly: the recorder is a
## viewer object with no getter for it, and only its contents matter here.
func _check_recorder_survives_dispose() -> void:
	var world := WorldStateType.new(SEED, 3, SIZE, SIZE)
	var recorder := CommandRecorderType.new()
	recorder.start(world, 10)
	for i in TICKS:
		world.apply({"actor": "player", "command_id": "dispose_%d" % i, "tick": world.get_tick(), "type": "dig",
			"payload": {"x": i % SIZE, "y": 1, "priority": 1}})
		world.tick()
		recorder.observe_tick(world)
	world.dispose()
	_expect(not world.command_observer.is_valid(), "dispose() must detach the world's command observer")
	_expect(recorder.is_recording(), "dispose() must not touch the recorder hooked on the world")
	var recording: ReplayLog = recorder._log
	_expect(recording != null and recording.commands.size() == TICKS,
		"the recorder must keep every command it heard (%d), got %s" % [TICKS, recording.commands.size() if recording != null else -1])
	_expect(recording != null and not recording.initial_state.is_empty() and not recording.checkpoints.is_empty(),
		"the recorder's initial state and checkpoints must survive the world's dispose()")

func _check_registry_and_setup_survive_dispose() -> void:
	var content := ContentRegistryType.new()
	var setup := WorldSetupType.new()
	var before_setup := JSON.stringify({"count": setup.colonist_count, "colonists": setup.colonists,
		"calendar": setup.calendar, "incidents": setup.enabled_incidents})
	var reference := WorldStateType.new(SEED, 3, SIZE, SIZE, false, content, setup)
	var expected_hash := reference.state_hash()
	var world := WorldStateType.new(SEED, 3, SIZE, SIZE, false, content, setup)
	world.tick()
	world.dispose()
	_expect(content.is_valid() and not content.list("tiles").is_empty() and not content.list("jobs").is_empty(),
		"the session ContentRegistry must keep its documents after a world built on it is disposed")
	var after_setup := JSON.stringify({"count": setup.colonist_count, "colonists": setup.colonists,
		"calendar": setup.calendar, "incidents": setup.enabled_incidents})
	_expect(after_setup == before_setup, "the WorldSetup handed in must be unchanged by dispose()")
	var rebuilt := WorldStateType.new(SEED, 3, SIZE, SIZE, false, content, setup)
	_expect(rebuilt.state_hash() == expected_hash,
		"a world built on the same registry and setup after the dispose must hash like one built before it")

func _check_disposed_world_is_freed() -> void:
	var world := WorldStateType.new(SEED, 3, SIZE, SIZE)
	world.tick()
	var tracker: WeakRef = weakref(world)
	world.dispose()
	world = null
	_expect(tracker.get_ref() == null, "a disposed and dropped WorldState must be freed")
