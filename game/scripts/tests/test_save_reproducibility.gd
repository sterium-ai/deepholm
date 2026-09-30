extends SceneTree

## Generator provenance and seed fidelity, both
## exercised through actual SaveIO writes and reads (not just StateCodec
## encode()/decode() in memory).
##
## Generator provenance: re-saving a world loaded from an older generator
## build must keep recording that build's own map.generatorVersion, never
## silently relabel it to the running build's own GENERATOR_VERSION constant.
##
## Seed fidelity: the top-level "seed" and "rng.seed"/"rng.state" fields are
## 64-bit integers; JSON.parse_string() decodes every number as a 64-bit
## float, which cannot exactly represent a magnitude at or beyond 2^53. A
## seed in that range (the New Game seed field accepts any 64-bit integer)
## must still round-trip through a real save file exactly.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const LARGE_SEED := 9007199254740993 # 2^53 + 1: the smallest integer a double cannot represent exactly
const DIG_TICK_BUDGET := 200

var _failed := false

func _init() -> void:
	_check_seed_fidelity_through_save_io()
	_check_generator_provenance_preserved_through_resave()
	_check_completed_dig_saves_and_reloads_through_save_io()
	_check_dig_find_rng_continuation_survives_save_io_round_trip()
	if _failed:
		quit(1)
		return
	print("test_save_reproducibility: PASS")
	quit()

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _check_seed_fidelity_through_save_io() -> void:
	var world := WorldStateType.new(LARGE_SEED, 10, 48, 48)
	var state := StateCodecType.encode(world)
	_expect(int(state["seed"]) == LARGE_SEED, "encoded top-level seed must equal the constructor's exact seed")
	var path := "user://test-save-reproducibility-seed.json"
	_remove(path)
	var write_result := SaveIOType.write_atomic(path, state)
	_expect(write_result.get("ok", false), "a seed beyond 2^53 must save: %s" % write_result)
	var read_result := SaveIOType.read(path)
	_expect(read_result.get("ok", false), "a seed beyond 2^53 must read back: %s" % read_result)
	if read_result.get("ok", false):
		var read_state: Dictionary = read_result["state"]
		_expect(int(read_state["seed"]) == LARGE_SEED,
			"the top-level seed must round-trip through a save file exactly, got %d expected %d" % [int(read_state["seed"]), LARGE_SEED])
		_expect(int(read_state["rng"]["seed"]) == int(state["rng"]["seed"]),
			"rng.seed must round-trip through a save file exactly, got %d expected %d" % [int(read_state["rng"]["seed"]), int(state["rng"]["seed"])])
		var loaded := StateCodecType.decode(read_state)
		_expect(loaded.get_seed() == LARGE_SEED, "a decoded world must report the exact original seed, got %d" % loaded.get_seed())
	_remove(path)

func _check_generator_provenance_preserved_through_resave() -> void:
	var world := WorldStateType.new(501, 10, 48, 48)
	var state := StateCodecType.encode(world)
	# A value distinct from the running build's own GENERATOR_VERSION, so the
	# test actually distinguishes "preserved the loaded value" from "always
	# reports the running build's constant" -- the two would be
	# indistinguishable if this matched WorldGeneratorType.GENERATOR_VERSION.
	var synthetic_version := WorldGeneratorType.GENERATOR_VERSION + 41
	var map: Dictionary = (state["map"] as Dictionary).duplicate(true)
	map["generatorVersion"] = synthetic_version
	state["map"] = map

	var path := "user://test-save-reproducibility-generator-version.json"
	_remove(path)
	var write_result := SaveIOType.write_atomic(path, state)
	_expect(write_result.get("ok", false), "a save with an older generatorVersion must save: %s" % write_result)
	var read_result := SaveIOType.read(path)
	_expect(read_result.get("ok", false), "a save with an older generatorVersion must read back: %s" % read_result)
	if read_result.get("ok", false):
		var loaded := StateCodecType.decode(read_result["state"])
		_expect(loaded.get_generator_version() == synthetic_version,
			"a decoded world must report the loaded save's own generatorVersion, not the running build's constant (got %d, expected %d)"
				% [loaded.get_generator_version(), synthetic_version])
		var resaved := StateCodecType.encode(loaded)
		_expect(int(resaved["map"]["generatorVersion"]) == synthetic_version,
			"re-encoding a loaded world must keep recording its true generatorVersion, got %d expected %d"
				% [int(resaved["map"]["generatorVersion"]), synthetic_version])
	_remove(path)

## A small hand-built corridor (mirrors test_toils_dig_chop_regression.gd's own
## _build_world()): rock everywhere except a soil row a colonist can dig its
## own way along, with a pick already on the ground so dig's needs_tool
## precondition never blocks it.
func _build_dig_test_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10, 16, 16)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	world._objects.clear()
	world._object_factions.clear()
	for x in range(0, 8):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 0)
	return world

func _complete_dig(world: WorldStateType, target: Vector2i, command_id: String) -> bool:
	var result := world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": "dig", "payload": {"x": target.x, "y": target.y, "priority": 1}})
	if not result.get("ok", false):
		return false
	var ticks := 0
	while ticks < DIG_TICK_BUDGET and world.get_tile(target.x, target.y) != WorldStateType.TILE_TRENCH:
		world.tick()
		ticks += 1
	return world.get_tile(target.x, target.y) == WorldStateType.TILE_TRENCH

func _item_kinds_near(world: WorldStateType, target: Vector2i) -> Array:
	var kinds: Array = []
	for item in world.get_items():
		if maxi(absi(int(item["x"]) - target.x), absi(int(item["y"]) - target.y)) <= 1:
			kinds.append(String(item["kind"]))
	kinds.sort()
	return kinds

## A completed dig turns its target tile into
## `trench` (ADR 026); game-state.schema.json/SaveIO._validate_state() must
## accept that tile kind rather than reject it as "invalid map tile" the
## moment any dig completes. Exercises a real
## dig through world.apply()/tick(), not a hand-built dictionary, then a real
## SaveIO.write_atomic()/read() round trip, not just StateCodec.encode()/decode()
## in memory.
func _check_completed_dig_saves_and_reloads_through_save_io() -> void:
	var world := _build_dig_test_world(730001)
	var target := Vector2i(0, 0)
	_expect(_complete_dig(world, target, "dig_1"), "the dig order must complete within the tick budget")

	var state := world.to_save_state()
	var path := "user://test-save-reproducibility-dig-trench.json"
	_remove(path)
	var write_result := SaveIOType.write_atomic(path, state)
	_expect(write_result.get("ok", false), "a world with a completed dig (trench tile) must save through SaveIO: %s" % write_result)
	var read_result := SaveIOType.read(path)
	_expect(read_result.get("ok", false), "a world with a completed dig (trench tile) must read back through SaveIO: %s" % read_result)
	if read_result.get("ok", false):
		var loaded := StateCodecType.decode(read_result["state"])
		_expect(loaded.get_tile(target.x, target.y) == WorldStateType.TILE_TRENCH,
			"a reloaded world must keep its dug tile as trench")
	_remove(path)

## world._dig_find_random's own continuation must
## survive a real SaveIO.write_atomic()/read() round trip (not just an
## in-memory StateCodec.encode()/decode(), already covered by
## test_save_migration.gd's own _check_dig_find_rng_continuation_survives_save_load_round_trip()),
## and a restored world's next dig-find roll after several already-completed
## digs must match an uninterrupted live run's own next roll exactly -- proving
## the restored stream keeps going from where the saved run left off instead
## of restarting.
func _check_dig_find_rng_continuation_survives_save_io_round_trip() -> void:
	var live := _build_dig_test_world(730002)
	for x in range(0, 3):
		_expect(_complete_dig(live, Vector2i(x, 0), "dig_%d" % x), "dig %d must complete within the tick budget" % x)

	var state := live.to_save_state()
	var path := "user://test-save-reproducibility-dig-find-rng.json"
	_remove(path)
	var write_result := SaveIOType.write_atomic(path, state)
	_expect(write_result.get("ok", false), "a world with several completed digs must save through SaveIO: %s" % write_result)
	var read_result := SaveIOType.read(path)
	_expect(read_result.get("ok", false), "a world with several completed digs must read back through SaveIO: %s" % read_result)
	_remove(path)
	if not read_result.get("ok", false):
		return
	var restored: WorldStateType = StateCodecType.decode(read_result["state"])
	_expect(restored._dig_find_random.seed == live._dig_find_random.seed and restored._dig_find_random.state == live._dig_find_random.state,
		"a real SaveIO round trip must preserve the dig-find RNG's own stream exactly")

	# Continue both the live run and its SaveIO-restored counterpart through one
	# more completed dig each, at the same target, and compare the resulting
	# find item and state_hash() -- a restored run must diverge from neither.
	var next_target := Vector2i(3, 0)
	_expect(_complete_dig(live, next_target, "dig_live_continue"), "the live run's continuation dig must complete")
	_expect(_complete_dig(restored, next_target, "dig_restored_continue"), "the restored run's continuation dig must complete")
	_expect(_item_kinds_near(live, next_target) == _item_kinds_near(restored, next_target),
		"a SaveIO-restored world's next dig-find roll must match the uninterrupted live run's roll exactly")
	_expect(restored.state_hash() == live.state_hash(),
		"a SaveIO-restored world must reach the exact same state_hash() as the uninterrupted live run after an identical continuation dig")

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
