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
	_check_malformed_animal_saves_rejected()
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

## Review round 2: animal entities without "fauna", a nextAnimalId that is not past every saved
## animal_N (the next birth would reuse a live id), an id off ^animal_[0-9]+$ and an animal off the
## surface are all refused, by validation and by the writer.
func _check_malformed_animal_saves_rejected() -> void:
	var world := _wild_world(880006)
	world.tick()
	var saved: Dictionary = world.to_save_state()
	_expect(SaveIOType._validate_state(saved)["ok"], "the untouched save with animals must validate")
	var highest := 0
	for entity: Dictionary in saved["entities"]:
		if entity.get("kind") == "animal":
			highest = maxi(highest, (entity["id"] as String).substr(7).to_int())
	_expect(int(saved["fauna"]["nextAnimalId"]) == highest + 1, "the shipped counter is one past the highest animal id")
	var missing := saved.duplicate(true)
	missing.erase("fauna")
	_expect_rejected(missing, "missing fauna", "animal entities without a fauna field")
	var written := SaveIOType.write_atomic(SAVE_PATH, missing)
	_expect(not written.get("ok", false), "the writer must refuse animals without a fauna field: %s" % written)
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	for counter: int in [0, highest]:
		var stale := saved.duplicate(true)
		stale["fauna"]["nextAnimalId"] = counter
		_expect_rejected(stale, "nextAnimalId", "fauna.nextAnimalId %d with animal_%d saved" % [counter, highest])
	for bad_id: String in ["animal_foo", "animal_", "animal_1x"]:
		_expect_rejected(_with_first_animal(saved, "id", bad_id), "animal id", "animal id '%s'" % bad_id)
	# A second layer of tiles (test_map_layers' pattern) puts z 1 on the map, so the surface rule
	# itself must refuse it, not the generic bounds check.
	var two_layers: Dictionary = saved.duplicate(true)
	two_layers["map"]["layerCount"] = 2
	(two_layers["map"]["tiles"] as Array).append_array(saved["map"]["tiles"])
	_expect(SaveIOType._validate_state(two_layers)["ok"], "the two-layer save with surface animals must validate")
	_expect_rejected(_with_first_animal(two_layers, "z", 1), "surface", "an underground animal (z 1)")
	_expect(not SaveIOType._validate_state(_with_first_animal(saved, "z", -1))["ok"], "an animal at z -1 must be rejected")
	var no_animals := saved.duplicate(true)
	no_animals["entities"] = (no_animals["entities"] as Array).filter(func(e: Dictionary) -> bool: return e.get("kind") != "animal")
	no_animals.erase("fauna")
	_expect(SaveIOType._validate_state(no_animals)["ok"], "a save with neither animals nor fauna must still validate")

func _with_first_animal(saved: Dictionary, field: String, value: Variant) -> Dictionary:
	var tampered: Dictionary = saved.duplicate(true)
	for entity: Dictionary in tampered["entities"]:
		if entity.get("kind") == "animal":
			entity[field] = value
			break
	return tampered

func _expect_rejected(state: Dictionary, needle: String, what: String) -> void:
	var check := SaveIOType._validate_state(state)
	_expect(not check["ok"], "%s must be rejected" % what)
	_expect(str(check.get("message", "")).contains(needle), "the rejection of %s must say '%s': %s" % [what, needle, check])
