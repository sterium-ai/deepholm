extends SceneTree

## F6b-1 (ADR 070): fauna in state_hash(), save/load and replay. Same seed + same spawns give the
## same hash; animals change it; a mid-run save continues identically; a recorded session with
## animals replays to the same hashes.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const CommandRecorderType = preload("res://scripts/viewer/command_recorder.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SAVE_PATH := "user://test-fauna-persistence-round-trip.json"

const DAY_TICKS := 2200
const MIX: Array[String] = ["grasshopper", "grasshopper", "grasshopper", "bird", "rabbit", "rabbit", "wolf"]

var _failed := false

func _init() -> void:
	_check_hash_is_deterministic()
	_check_save_load_continues_identically()
	_check_real_file_round_trip()
	_check_unknown_species_rejected()
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
	_expect(WorldStateType.new(880001).state_hash() == plain.state_hash(), "the same seed alone hashes the same")
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

## Through the real save file (validation, integrity, exact 64-bit integers): a fauna.rng state
## above 2^53 must come back bit-exact, or the next fauna draw diverges.
func _check_real_file_round_trip() -> void:
	var world := _wild_world(880004)
	for _i in DAY_TICKS / 2:
		world.tick()
	var saved: Dictionary = world.to_save_state()
	var rng_state: int = saved["fauna"]["rng"]["state"]
	_expect(absi(rng_state) > (1 << 53), "the fixture run must carry a fauna.rng state beyond 2^53 (got %d)" % rng_state)
	var written := SaveIOType.write_atomic(SAVE_PATH, saved)
	_expect(written.get("ok", false), "a save with animals must be writable: %s" % written)
	var read := SaveIOType.read(SAVE_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_expect(read.get("ok", false), "a save with animals must load: %s" % read.get("message", ""))
	if not read.get("ok", false):
		return
	_expect(read["state"]["fauna"]["rng"]["state"] == rng_state, "fauna.rng.state must survive the file bit-exact")
	var restored := WorldStateType.from_save_state(read["state"])
	_expect(restored.state_hash() == world.state_hash(), "a file round trip must keep state_hash() with animals")
	for _i in DAY_TICKS:
		world.tick()
		restored.tick()
	_expect(restored.state_hash() == world.state_hash(), "the file-restored world must continue identically")
	_expect(restored._fauna.get_animals() == world._fauna.get_animals(), "the file-restored roster must match")

## Review fix: a saved animal's species must be a species.json id of the session, not just an
## id-shaped string. A save carrying a "dragon" is refused both by validation and by the writer.
func _check_unknown_species_rejected() -> void:
	var world := _wild_world(880005)
	world.tick()
	var saved: Dictionary = world.to_save_state()
	_expect(SaveIOType._validate_state(saved)["ok"], "the untouched save with animals must validate")
	var tampered: Dictionary = saved.duplicate(true)
	for entity: Dictionary in tampered["entities"]:
		if entity.get("kind") == "animal":
			entity["species"] = "dragon"
			break
	var check := SaveIOType._validate_state(tampered)
	_expect(not check["ok"], "a save with an unknown species must be rejected")
	_expect(str(check.get("message", "")).contains("animal"), "the rejection must name the animal species: %s" % check)
	var written := SaveIOType.write_atomic(SAVE_PATH, tampered)
	_expect(not written.get("ok", false), "the writer must refuse a save with an unknown species: %s" % written)
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
