extends SceneTree

## Issue #299 acceptance: "the same seed with the same generator/content
## reproduces terrain and spawn" for the large (256x256) map, across a fixed
## set of seeds, with at least two producing distinct maps -- and the 48x48
## reference size still reproduces the historical fixture output unchanged
## (no naive constant substitution, ADR 019).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")

const SEEDS := [1, 2, 42, 1337, 20260919]
const WIDTH := 256
const HEIGHT := 256

var _failed := false

func _init() -> void:
	var tile_arrays: Dictionary = {}
	for seed_value in SEEDS:
		var first := WorldStateType.new(seed_value, 10, WIDTH, HEIGHT)
		var second := WorldStateType.new(seed_value, 10, WIDTH, HEIGHT)
		_expect(first.get_map_width() == WIDTH and first.get_map_height() == HEIGHT,
			"seed %d must produce a %dx%d map" % [seed_value, WIDTH, HEIGHT])
		_expect(first.get_tiles().size() == WIDTH * HEIGHT,
			"seed %d tile count must equal width*height" % seed_value)
		_expect(first.get_tiles() == second.get_tiles(),
			"seed %d must reproduce identical terrain across two generations" % seed_value)
		_expect(_colonist_positions(first) == _colonist_positions(second),
			"seed %d must reproduce identical spawn positions across two generations" % seed_value)
		_expect(first.get_generator_version() == WorldGeneratorType.GENERATOR_VERSION,
			"get_generator_version() must expose WorldGenerator.GENERATOR_VERSION")
		tile_arrays[seed_value] = first.get_tiles()

	var distinct_pairs := 0
	for i in SEEDS.size():
		for j in range(i + 1, SEEDS.size()):
			if tile_arrays[SEEDS[i]] != tile_arrays[SEEDS[j]]:
				distinct_pairs += 1
	_expect(distinct_pairs > 0, "at least two of the tested seeds must produce distinct 256x256 maps")

	# 48x48 reference-size parity (ADR 019): a request at mapgen.json's own
	# reference_width/reference_height must match WorldState's historical
	# no-args constructor output byte-for-byte -- density scaling must be a
	# no-op at ratio 1.
	var reference_seed: int = SEEDS[SEEDS.size() - 1]
	var default_world := WorldStateType.new(reference_seed)
	var explicit_world := WorldStateType.new(reference_seed, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT)
	_expect(default_world.get_tiles() == explicit_world.get_tiles(),
		"an explicit 48x48 request must match the constructor's own 48x48 default")
	_expect(default_world.get_map_width() == WorldStateType.MAP_WIDTH and default_world.get_map_height() == WorldStateType.MAP_HEIGHT,
		"the default constructor must still produce a 48x48 map")

	# Size clamping (ADR 019 / WorldGenerator.resolve_size()): a request below
	# min_world_size or above max_world_size never reaches WorldState raw.
	var too_small := WorldStateType.new(reference_seed, 10, 1, 1)
	_expect(too_small.get_map_width() >= 16 and too_small.get_map_height() >= 16,
		"a too-small request must be clamped up to mapgen.json's min_world_size")
	var too_large := WorldStateType.new(reference_seed, 10, 100000, 100000)
	_expect(too_large.get_map_width() <= 512 and too_large.get_map_height() <= 512,
		"a too-large request must be clamped down to mapgen.json's max_world_size")

	if _failed:
		quit(1)
		return
	print("test_worldgen_determinism: PASS")
	quit()

func _colonist_positions(world: WorldStateType) -> Array:
	var positions: Array = []
	for colonist in world.get_colonists():
		positions.append("%s:%d:%d" % [colonist["id"], int(colonist["x"]), int(colonist["y"])])
	positions.sort()
	return positions

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
