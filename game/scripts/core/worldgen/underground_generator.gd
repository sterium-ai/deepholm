class_name UndergroundGenerator
extends RefCounted

## Deterministic generation of one underground layer (F4, ADR 071; ADR 045 §5).
## Invariants:
## - generate_layer() is a pure function of (world seed, layer, width, height, vein kinds):
##   its RNG is seeded from those alone, never from the tick or the world RNGs, so a layer is
##   identical whether it is discovered on day 3 or day 30.
## - The layer is rock with floor cave pockets; veins sit on rock tiles only, at most one per
##   tile, in a fixed draw order (vein kinds sorted by id).
## - GENERATOR_VERSION names this algorithm; a save records it (map.undergroundVersion) so a
##   changed algorithm cannot silently regenerate an old world's next layer differently.

const GENERATOR_VERSION := 1
## Mixed into the world seed; distinct from WorldState's surface salts.
const UNDERGROUND_SEED_SALT := 557_093
## Per-layer stride so each layer draws from its own stream.
const LAYER_SEED_STRIDE := 7_919
const TILE_ROCK := ContentRegistry.TILE_ROCK
const TILE_FLOOR := ContentRegistry.TILE_FLOOR
## One cave pocket per this many tiles (at least one).
const TILES_PER_POCKET := 256
const POCKET_MIN_STEPS := 8
const POCKET_MAX_STEPS := 24
## Placement tries per vein before it is skipped (a full layer of floor places none).
const VEIN_PLACEMENT_ATTEMPTS := 8

## Vein object kinds for layer, sorted by id: object definitions whose "vein.layer" is layer.
static func vein_kinds_for_layer(object_definitions: Dictionary, layer: int) -> Array[String]:
	var kinds: Array[String] = []
	for kind: String in object_definitions.keys():
		var vein: Variant = (object_definitions[kind] as Dictionary).get("vein")
		if not vein is Dictionary:
			continue
		var vein_layer: int = (vein as Dictionary).get("layer", 0)
		if vein_layer == layer:
			kinds.append(kind)
	kinds.sort()
	return kinds

## {"tiles": Array[String] (width*height, row-major), "veins": [[planar index, kind], ...]}.
## object_definitions supplies each vein kind's "vein.per_thousand_tiles" density.
static func generate_layer(world_seed: int, layer: int, width: int, height: int, object_definitions: Dictionary) -> Dictionary:
	var random := RandomNumberGenerator.new()
	random.seed = world_seed + UNDERGROUND_SEED_SALT + layer * LAYER_SEED_STRIDE
	var area := width * height
	var tiles: Array[String] = []
	tiles.resize(area)
	tiles.fill(TILE_ROCK)
	for pocket in maxi(1, floori(area / float(TILES_PER_POCKET))):
		_carve_pocket(random, tiles, width, height)
	var occupied: Dictionary = {}
	var veins: Array = []
	for kind in vein_kinds_for_layer(object_definitions, layer):
		var density: float = ((object_definitions[kind] as Dictionary)["vein"] as Dictionary).get("per_thousand_tiles", 1.0)
		for vein_index in maxi(1, roundi(area * density / 1000.0)):
			for attempt in VEIN_PLACEMENT_ATTEMPTS:
				var index := random.randi_range(0, area - 1)
				if tiles[index] == TILE_ROCK and not occupied.has(index):
					occupied[index] = true
					veins.append([index, kind])
					break
	return {"tiles": tiles, "veins": veins}

## A random walk of floor from a random start, clamped to the layer.
static func _carve_pocket(random: RandomNumberGenerator, tiles: Array[String], width: int, height: int) -> void:
	var x := random.randi_range(0, width - 1)
	var y := random.randi_range(0, height - 1)
	for step in random.randi_range(POCKET_MIN_STEPS, POCKET_MAX_STEPS):
		tiles[y * width + x] = TILE_FLOOR
		match random.randi_range(0, 3):
			0:
				x = mini(x + 1, width - 1)
			1:
				x = maxi(x - 1, 0)
			2:
				y = mini(y + 1, height - 1)
			_:
				y = maxi(y - 1, 0)
