extends SceneTree

## F6b-1 (ADR 070): fauna in state_hash(), save/load and replay. Same seed + same spawns give the
## same hash; animals change it; a mid-run save continues identically; a recorded session with
## animals replays to the same hashes.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")

const DAY_TICKS := 2200
const MIX: Array[String] = ["grasshopper", "grasshopper", "grasshopper", "bird", "rabbit", "rabbit", "wolf"]

var _failed := false

func _init() -> void:
	_check_hash_is_deterministic()
	_check_save_load_continues_identically()
	_check_recorded_session_replays()
	if _failed:
		quit(1)
		return
	print("test_fauna_persistence: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A default world plus 14 animals on its first soil tiles.
func _wild_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	var placed := 0
	for y in 48:
		for x in 48:
			if placed < 2 * MIX.size() and world.get_tile(x, y) == "soil":
				world._fauna.spawn(MIX[placed % MIX.size()], Vector3i(x, y, 0))
				placed += 1
	return world

func _check_hash_is_deterministic() -> void:
	var a := _wild_world(880001)
	var b := _wild_world(880001)
	var plain := WorldStateType.new(880001)
	_expect(a.state_hash() == b.state_hash(), "the same seed and spawns must hash the same")
	_expect(a.state_hash() != plain.state_hash(), "animals must change state_hash()")
	_expect(WorldStateType.new(880001).state_hash() == plain.state_hash(), "an animal-free world hashes the same")
	for _i in DAY_TICKS:
		a.tick()
		b.tick()
	_expect(a.state_hash() == b.state_hash(), "the same run must keep the same hash")

func _check_save_load_continues_identically() -> void:
	var world := _wild_world(880002)
	for _i in DAY_TICKS / 2:
		world.tick()
	var restored := WorldStateType.from_save_state(world.to_save_state())
	_expect(restored.state_hash() == world.state_hash(), "save/load must keep state_hash() with animals")
	_expect(restored._fauna.get_animals() == world._fauna.get_animals(), "save/load must keep the roster")
	for _i in DAY_TICKS:
		world.tick()
		restored.tick()
	_expect(restored.state_hash() == world.state_hash(), "the restored world must continue identically")

func _check_recorded_session_replays() -> void:
	var world := _wild_world(880003)
	var recorder := CommandRecorderType.new()
	recorder.start(world, 100, false)
	for _i in DAY_TICKS:
		world.tick()
		recorder.observe_tick(world)
	_expect(not world._fauna.get_animals().is_empty(), "the recorded session must carry animals")
	var replay: Dictionary = recorder.stop().replay()
	_expect(bool(replay.get("ok", false)), "the recorded session must replay identically: %s" % [replay])
