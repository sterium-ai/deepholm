class_name WorldGenerator
extends RefCounted

## Pure terrain generation (issue #299/#300), extracted from WorldState to respect
## its core-budgets.json cap: no scenes, nodes, content-registry instances, or
## wall-clock/global randomness -- every draw comes from the RandomNumberGenerator
## the caller injects, consumed in a fixed order, so a given seed reproduces the
## same terrain whenever the same width, height and mapgen document are used
## again (ADR 019, ADR 020).

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

## Bumped whenever the generation algorithm itself changes (not when
## mapgen.json's tunable values change); persisted per save (see
## state_codec.gd's "map.generatorVersion") so a save records which algorithm
## actually produced its stored terrain, for reproducibility diagnostics.
## Bumped to 2 for issue #300: the main-river/correlated-vegetation/
## river-aware spawn algorithm replaces #299's independent per-tile scatter.
## Bumped to 3 for issue #351/#347: grown (not scattered) compact rock
## outcrops are a new terrain-shaping pass, and place_spawn()'s anchor
## scoring now requires outcrop reachability too -- both change the tiles a
## given seed produces.
const GENERATOR_VERSION := 3

const TILE_ROCK := ContentRegistryType.TILE_ROCK
const TILE_SOIL := ContentRegistryType.TILE_SOIL
const TILE_FLOOR := ContentRegistryType.TILE_FLOOR
const TILE_HAZARD := ContentRegistryType.TILE_HAZARD
const TILE_TREE := ContentRegistryType.TILE_TREE
const TILE_WATER := ContentRegistryType.TILE_WATER

## The map size mapgen.json's counts/attempts are tuned for; see resolve_size()
## and _density_scale() below for how a different requested size scales them.
const DEFAULT_REFERENCE_SIZE := 48
const DEFAULT_MIN_WORLD_SIZE := 16
const DEFAULT_MAX_WORLD_SIZE := 512

## River width contract (issue #300 Goal: "a channel roughly 6-12 tiles
## wide"): the hard floor below which a transversal corridor is considered a
## "neck" the task's acceptance forbids. river_min_width/max_width
## (mapgen.json, default 6/12) are themselves always >= NECK_FLOOR, so a
## generated river's measured width -- see _carve_river()'s own doc comment for
## the exact width metric -- never approaches this floor in practice; it exists
## as a defensive clamp for a pathological mapgen.json override, not a value
## the default tuning is expected to reach.
const NECK_FLOOR := 4
const DEFAULT_RIVER_MIN_WIDTH := 6
const DEFAULT_RIVER_MAX_WIDTH := 12
const DEFAULT_RIVER_CONTROL_SPACING := 24
const DEFAULT_RIVER_MAX_DELTA := 6

const DEFAULT_TREE_GROVE_COUNT := 6
const DEFAULT_TREE_GROVE_RADIUS := 5

## Compact rock outcrops (issue #351/#347), complementing rock_vein_count's
## thin (10-22 tile) veins rather than replacing them: outcrop_count scales
## with map area like rock_vein_count; min/max size and compactness are
## spatial and never scaled, like tree_grove_radius.
const DEFAULT_OUTCROP_COUNT := 5
const DEFAULT_OUTCROP_MIN_SIZE := 6
const DEFAULT_OUTCROP_MAX_SIZE := 16
const DEFAULT_OUTCROP_PLACEMENT_ATTEMPTS := 200
const DEFAULT_OUTCROP_COMPACTNESS := 0.7

const DEFAULT_BERRY_BUSH_COUNT := 8
const DEFAULT_BERRY_BUSH_PLACEMENT_ATTEMPTS := 120
const DEFAULT_BERRY_BUSH_GROVE_COUNT := 5
const DEFAULT_BERRY_BUSH_GROVE_RADIUS := 4

## Spawn-clearing search (issue #300 Goal: "a deterministic attempt limit and
## a documented fallback"). Distances are measured in real 4-connected route
## hops over passable (soil) tiles -- see place_spawn()'s own doc comment --
## never Chebyshev/Euclidean distance.
const DEFAULT_SPAWN_SEARCH_ATTEMPTS := 300
const DEFAULT_SPAWN_WATER_STEP_LIMIT := 40
const DEFAULT_SPAWN_FOOD_STEP_LIMIT := 40
const DEFAULT_SPAWN_TREE_STEP_LIMIT := 50

## Concrete starting-food requirement (issue #300 round 5 review). Forage
## fully consumes its berry_bush in one interaction -- world_state.gd's
## _toil_on_work_complete()/_apply_need_effect() clear the bush and leave
## exactly one ground-berries pile, a single full-restore meal, no regrowth --
## so a single reachable bush can feed only one of the three colonists' first
## meals, however short its route distance. Distance-to-NEAREST-bush alone
## (the pre-round-5 check) lets the exact same bush satisfy all three
## colonists' own nearest-distance test while actually feeding only one of
## them. Requiring `colonist_count * FOOD_SOURCES_PER_COLONIST` DISTINCT
## reachable bushes -- not merely a short route to the closest one -- is the
## concrete quantity "enough resources for the initial needs"
## resolves to, derived directly from real forage yield (1) and colonist_count (3).
const FOOD_SOURCES_PER_COLONIST := 1

const NEI4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## Clamps a requested world size into mapgen.json's declared
## min_world_size/max_world_size (falling back to this module's own defaults
## when the document omits them, e.g. a minimal test fixture) so neither a
## degenerate nor an unbounded world can ever reach WorldState._init().
static func resolve_size(requested_width: int, requested_height: int, mapgen: Dictionary) -> Vector2i:
	var min_size := int(mapgen.get("min_world_size", DEFAULT_MIN_WORLD_SIZE))
	var max_size := int(mapgen.get("max_world_size", DEFAULT_MAX_WORLD_SIZE))
	return Vector2i(
		clampi(requested_width, min_size, max_size),
		clampi(requested_height, min_size, max_size)
	)

## The "normal UI" new-game size (issue #299 acceptance: 256x256), read from
## content rather than hardcoded here so a single source of truth governs it.
static func default_new_game_size(mapgen: Dictionary) -> Vector2i:
	return Vector2i(
		int(mapgen.get("default_new_game_width", 256)),
		int(mapgen.get("default_new_game_height", 256))
	)

## Terrain-feature counts/attempts scale with the requested map's area
## relative to mapgen.json's reference_width/reference_height (default
## 48x48, matching every existing fixture, so a request at that exact size
## reproduces the historical counts/attempts unchanged -- verified by
## test_worldgen_determinism.gd's 48x48 parity case). Rounds to the nearest
## whole count/attempt rather than flooring, so a small requested map never
## rounds a positive base count down to zero purely from scaling. Spatial
## extents (river width, grove radius) are never scaled by this -- only
## counts/attempts are (issue #300: a river stays 6-12 tiles wide regardless
## of map size, it does not get proportionally wider on a larger map).
static func _density_scale(width: int, height: int, mapgen: Dictionary) -> float:
	var reference_width := int(mapgen.get("reference_width", DEFAULT_REFERENCE_SIZE))
	var reference_height := int(mapgen.get("reference_height", DEFAULT_REFERENCE_SIZE))
	var reference_area := maxi(1, reference_width * reference_height)
	return float(width * height) / float(reference_area)

static func _scaled(base: int, scale: float) -> int:
	if base <= 0:
		return 0
	return maxi(1, int(round(float(base) * scale)))

## Deterministic terrain for a width x height map: consumes `random` in a
## fixed draw sequence (rock veins, hazards, tree groves, river, berry bush
## groves, spawn search -- see generate_with_decorations()) so the caller's
## own seeded stream stays in sync with everything else _init() draws from it
## afterward (tool spawn ids, colonist shuffle). Tiles-only convenience
## wrapper around generate_with_decorations() for a caller (a focused test)
## that has no use for the decoration/spawn metadata.
static func generate(random: RandomNumberGenerator, width: int, height: int, mapgen: Dictionary) -> Array[String]:
	return generate_with_decorations(random, width, height, mapgen)["tiles"]

## Full terrain + decoration pass: {"tiles": Array[String], "water_tiles":
## Array[Vector2i], "berry_bush_tiles": Array[Vector2i]}. water_tiles/
## berry_bush_tiles are every tile the river/berry-bush pass actually stamped
## (row-major discovery order), consumed by place_spawn() below and by
## WorldState._spawn_colonists() (which writes the berry_bush tiles into its
## own _objects, the one resource kind this module cannot place itself since
## it is an object, not a tile -- see world_state.gd's own doc comment on
## _pending_berry_bush_tiles).
##
## Draw order (each pass consumes `random` in this fixed sequence, so a given
## seed reproduces the same terrain every time -- see this function's own
## top-of-file doc comment): rock veins, hazards, tree groves, rock outcrops,
## then the river LAST among terrain-shaping passes (issue #300 Goal: "later
## placement order must not break the channel") so nothing placed
## before it can leave a rock/hazard/tree/outcrop plug inside its band; every
## pass placed AFTER it (berry bush groves, the spawn clearing) only ever
## writes onto TILE_SOIL, so none of them can touch water either. Rock
## outcrops are the one exception to "consumes `random`": they draw from their
## own private, seed-derived substream (see OUTCROP_SEED_SALT/
## _scatter_rock_outcrops()'s own doc comment) instead, so slotting this new
## pass into the sequence never shifts what every other pass -- before or
## after it -- draws from `random` itself.
static func generate_with_decorations(random: RandomNumberGenerator, width: int, height: int, mapgen: Dictionary) -> Dictionary:
	var map: Array[String] = []
	map.resize(width * height)
	for i in map.size():
		map[i] = TILE_SOIL
	var scale := _density_scale(width, height, mapgen)
	_carve_rock_veins(random, map, width, height, mapgen, scale)
	_scatter_hazards(random, map, width, height, mapgen, scale)
	_scatter_tree_groves(random, map, width, height, mapgen, scale)
	_scatter_rock_outcrops(random, map, width, height, mapgen, scale)
	var water_tiles := _carve_river(random, map, width, height, mapgen)
	var berry_bush_tiles := _scatter_berry_bush_groves(random, map, width, height, mapgen, scale)
	return {"tiles": map, "water_tiles": water_tiles, "berry_bush_tiles": berry_bush_tiles}

static func _index(x: int, y: int, width: int) -> int:
	return y * width + x

static func _carve_rock_veins(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary, scale: float) -> void:
	var count := _scaled(int(mapgen["rock_vein_count"]), scale)
	for vein_index in count:
		var x := random.randi_range(0, width - 1)
		var y := random.randi_range(0, height - 1)
		var length := random.randi_range(int(mapgen["rock_vein_min_length"]), int(mapgen["rock_vein_max_length"]))
		for step in length:
			map[_index(x, y, width)] = TILE_ROCK
			match random.randi_range(0, 3):
				0: x += 1
				1: x -= 1
				2: y += 1
				3: y -= 1
			x = clampi(x, 0, width - 1)
			y = clampi(y, 0, height - 1)

static func _scatter_hazards(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary, scale: float) -> void:
	var placed := 0
	var attempts := 0
	var count := _scaled(int(mapgen["hazard_count"]), scale)
	var max_attempts := _scaled(int(mapgen["hazard_placement_attempts"]), scale)
	while placed < count and attempts < max_attempts:
		attempts += 1
		var x := random.randi_range(0, width - 1)
		var y := random.randi_range(0, height - 1)
		var index := _index(x, y, width)
		if map[index] == TILE_SOIL:
			map[index] = TILE_HAZARD
			placed += 1

## Correlated tree placement (issue #300 Goal: "groups of trees ... through
## correlated zones instead of scattering each element
## independently"): tree_count/tree_placement_attempts (area-scaled, as
## before) are split evenly across tree_grove_count groves (not area-scaled --
## a grove's own footprint is a spatial extent, not a count); each grove
## scatters its share within tree_grove_radius tiles of a random centre,
## rejecting offsets outside the circular radius, onto TILE_SOIL only.
static func _scatter_tree_groves(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary, scale: float) -> void:
	var total_trees := _scaled(int(mapgen["tree_count"]), scale)
	var total_attempts := _scaled(int(mapgen["tree_placement_attempts"]), scale)
	var grove_count := _scaled(int(mapgen.get("tree_grove_count", DEFAULT_TREE_GROVE_COUNT)), scale)
	var radius := maxi(1, int(mapgen.get("tree_grove_radius", DEFAULT_TREE_GROVE_RADIUS)))
	if grove_count <= 0 or total_trees <= 0:
		return
	var per_grove := maxi(1, int(ceil(float(total_trees) / float(grove_count))))
	var attempts_per_grove := maxi(per_grove, int(ceil(float(total_attempts) / float(grove_count))))
	var placed_total := 0
	for grove_index in grove_count:
		if placed_total >= total_trees:
			break
		var center_x := random.randi_range(0, width - 1)
		var center_y := random.randi_range(0, height - 1)
		var placed := 0
		var attempts := 0
		while placed < per_grove and attempts < attempts_per_grove and placed_total < total_trees:
			attempts += 1
			var offset_x := random.randi_range(-radius, radius)
			var offset_y := random.randi_range(-radius, radius)
			if offset_x * offset_x + offset_y * offset_y > radius * radius:
				continue
			var x := clampi(center_x + offset_x, 0, width - 1)
			var y := clampi(center_y + offset_y, 0, height - 1)
			var index := _index(x, y, width)
			if map[index] == TILE_SOIL:
				map[index] = TILE_TREE
				placed += 1
				placed_total += 1

## Distinct salt this pass seeds its own private RandomNumberGenerator from
## (see _scatter_rock_outcrops() below) rather than drawing from the shared
## `random` stream every other pass in generate_with_decorations() consumes
## from -- so inserting this new pass never shifts the random draws every
## other pass (river control points, berry bush groups) already consumed
## before issue #351/#347, which would otherwise change the map (and every
## downstream seed-dependent expectation outside this module, e.g. a hand-built
## test world carved from a real WorldState.new(seed) call) for a huge range
## of pre-existing seeds that never asked for an outcrop-shaped difference.
## Arbitrary, just distinct from world_state.gd's own GEOGRAPHY_SEED_SALT/
## PLACEMENT_SEED_SALT constants (402_653/219_961) so this substream never
## collides with either.
const OUTCROP_SEED_SALT := 100_003

## Compact rock outcrops (issue #351/#347 Goal: grow, not scatter, so a blob
## is guaranteed 4-connected -- unlike _scatter_tree_groves()'s independent
## circular-offset scatter above, which does not guarantee 4-connectivity and
## would produce scattered pebbles, not a blob). Each of outcrop_count blobs
## seeds a random TILE_SOIL tile, then repeatedly extends to a random
## 4-connected TILE_SOIL neighbour of the blob-so-far -- so every candidate
## neighbour is by construction never water/tree/hazard/existing rock, since
## only a plain TILE_SOIL tile is ever consumed -- until it reaches a size
## drawn from [outcrop_min_size, outcrop_max_size] or outcrop_placement_attempts
## is exhausted (a small/obstructed map may legitimately yield a smaller blob,
## never a bulldozed one). outcrop_compactness (0..1) biases each extension
## step's source tile: with probability outcrop_compactness the newest tile
## added to the blob is grown from (favouring a single elongated tendril);
## otherwise a uniformly random existing blob tile is grown from instead
## (favouring a rounder, more isotropic cluster) -- see mapgen.schema.json's
## own description for the exact knob semantics. Complements rather than
## replaces rock_vein_count's thin (10-22 tile) veins carved above.
##
## Draws from a private OUTCROP_SEED_SALT-derived substream (see that
## constant's own doc comment), read from `random.seed` -- the caller's
## initial seed value, unaffected by how many draws `random` itself has
## already produced -- so this pass never advances `random`'s own position:
## every pass after this one in generate_with_decorations() (namely
## _carve_river()/_scatter_berry_bush_groves()) draws exactly the sequence it
## would have without this pass existing at all, same as every pass before it.
static func _scatter_rock_outcrops(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary, scale: float) -> void:
	var count := _scaled(int(mapgen.get("outcrop_count", DEFAULT_OUTCROP_COUNT)), scale)
	if count <= 0:
		return
	var min_size := maxi(1, int(mapgen.get("outcrop_min_size", DEFAULT_OUTCROP_MIN_SIZE)))
	var max_size := maxi(min_size, int(mapgen.get("outcrop_max_size", DEFAULT_OUTCROP_MAX_SIZE)))
	# 0 is honored as-is (matches hazard_placement_attempts/tree_placement_attempts):
	# a configured budget of zero growth attempts places only the seed tile,
	# never a phantom extension the budget did not pay for.
	var placement_attempts := maxi(0, int(mapgen.get("outcrop_placement_attempts", DEFAULT_OUTCROP_PLACEMENT_ATTEMPTS)))
	var compactness := clampf(float(mapgen.get("outcrop_compactness", DEFAULT_OUTCROP_COMPACTNESS)), 0.0, 1.0)
	var outcrop_random := RandomNumberGenerator.new()
	outcrop_random.seed = random.seed + OUTCROP_SEED_SALT
	for outcrop_index in count:
		_grow_rock_outcrop(outcrop_random, map, width, height, min_size, max_size, placement_attempts, compactness)

## Grows a single outcrop blob in place; see _scatter_rock_outcrops() above
## for the algorithm contract. A no-op when the drawn seed tile is not plain
## TILE_SOIL (already claimed by an earlier pass this call), consuming only
## the one random draw for the seed position -- deterministic and bounded
## exactly like every other placement pass in this file.
static func _grow_rock_outcrop(random: RandomNumberGenerator, map: Array[String], width: int, height: int, min_size: int, max_size: int, placement_attempts: int, compactness: float) -> void:
	var seed_x := random.randi_range(0, width - 1)
	var seed_y := random.randi_range(0, height - 1)
	var seed_index := _index(seed_x, seed_y, width)
	if map[seed_index] != TILE_SOIL:
		return
	var target_size := random.randi_range(min_size, max_size)
	map[seed_index] = TILE_ROCK
	var blob: Array[int] = [seed_index]
	var blob_lookup: Dictionary = {seed_index: true}
	var attempts := 0
	while blob.size() < target_size and attempts < placement_attempts:
		attempts += 1
		var newest_index: int = blob[blob.size() - 1]
		var source_index: int = newest_index if random.randf() < compactness else blob[random.randi_range(0, blob.size() - 1)]
		var neighbor_index := _random_soil_neighbor(random, map, width, height, source_index, blob_lookup)
		if neighbor_index == -1:
			continue
		map[neighbor_index] = TILE_ROCK
		blob.append(neighbor_index)
		blob_lookup[neighbor_index] = true

## A uniformly random 4-connected TILE_SOIL neighbour of `index` not already
## in `blob_lookup`, or -1 when none exists (every neighbour is off-map,
## non-soil, or already part of the blob).
static func _random_soil_neighbor(random: RandomNumberGenerator, map: Array[String], width: int, height: int, index: int, blob_lookup: Dictionary) -> int:
	var x := index % width
	var y := index / width
	var candidates: Array[int] = []
	for offset in NEI4:
		var nx := x + offset.x
		var ny := y + offset.y
		if nx < 0 or nx >= width or ny < 0 or ny >= height:
			continue
		var nindex := _index(nx, ny, width)
		if map[nindex] == TILE_SOIL and not blob_lookup.has(nindex):
			candidates.append(nindex)
	if candidates.is_empty():
		return -1
	return candidates[random.randi_range(0, candidates.size() - 1)]

## Correlated berry-bush placement, the "comida" (food) resource this task
## adds to real terrain generation (previously only the debug scenario placed
## a single berry_bush object, unconditionally, via _place_scenario_objects()
## -- a fresh "New Game" world had none at all, see docs/decisions/020). Never
## mutates `map`: berry_bush is an object, not a tile kind, so this only
## returns the tile positions chosen (deduplicated); WorldState writes the
## actual object entries. Bushes place onto TILE_SOIL only, same as trees, so
## they can never land on water, rock, hazard or an existing tree/bush tile.
static func _scatter_berry_bush_groves(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary, scale: float) -> Array[Vector2i]:
	var positions: Array[Vector2i] = []
	var total_bushes := _scaled(int(mapgen.get("berry_bush_count", DEFAULT_BERRY_BUSH_COUNT)), scale)
	var total_attempts := _scaled(int(mapgen.get("berry_bush_placement_attempts", DEFAULT_BERRY_BUSH_PLACEMENT_ATTEMPTS)), scale)
	var grove_count := _scaled(int(mapgen.get("berry_bush_grove_count", DEFAULT_BERRY_BUSH_GROVE_COUNT)), scale)
	var radius := maxi(1, int(mapgen.get("berry_bush_grove_radius", DEFAULT_BERRY_BUSH_GROVE_RADIUS)))
	if grove_count <= 0 or total_bushes <= 0:
		return positions
	var per_grove := maxi(1, int(ceil(float(total_bushes) / float(grove_count))))
	var attempts_per_grove := maxi(per_grove, int(ceil(float(total_attempts) / float(grove_count))))
	var used: Dictionary = {}
	for grove_index in grove_count:
		if positions.size() >= total_bushes:
			break
		var center_x := random.randi_range(0, width - 1)
		var center_y := random.randi_range(0, height - 1)
		var placed := 0
		var attempts := 0
		while placed < per_grove and attempts < attempts_per_grove and positions.size() < total_bushes:
			attempts += 1
			var offset_x := random.randi_range(-radius, radius)
			var offset_y := random.randi_range(-radius, radius)
			if offset_x * offset_x + offset_y * offset_y > radius * radius:
				continue
			var x := clampi(center_x + offset_x, 0, width - 1)
			var y := clampi(center_y + offset_y, 0, height - 1)
			var index := _index(x, y, width)
			if map[index] != TILE_SOIL or used.has(index):
				continue
			used[index] = true
			positions.append(Vector2i(x, y))
			placed += 1

	return positions

## Carves the main river: a single band around a continuous centerline from
## one edge to the opposite edge (issue #300 Goal: "one main winding river
## from edge to edge"), never a scatter of independent points or a diagonal
## chain. Picks a dominant axis (horizontal: west->east, or vertical:
## north->south) and walks every integer position along it from edge 0 to the
## far edge; the centerline's transversal offset and the band's width are
## each linearly interpolated between randomly-drawn control points spaced
## river_control_point_spacing tiles apart (control offsets differ by at most
## river_max_transversal_delta, so the curve turns gently -- "variar trazado y
## anchura suavemente"), then the full transversal cross-section at that width
## is stamped as water, overwriting whatever was there before (issue #300:
## the river is carved after every other terrain feature specifically so nothing
## already placed can plug or narrow it).
##
## Width contract (issue #300 Goal: "define how width is measured"): because
## the centerline's transversal offset is a single-valued function of the
## dominant-axis coordinate, every transversal cross-section intersects the
## river in exactly one contiguous run of tiles -- this run's length IS the
## river's width at that position, well-defined and directly measurable off
## the generated tile array (see test_river_generation.gd's width/curve
## checks). Because the function is single-valued (never loops back on the
## dominant axis), the centerline cannot self-intersect, so a width spike from
## a self-crossing loop is impossible by construction, not merely tuned away.
## Consecutive cross-sections differ in position by at most a few tiles (drift
## is bounded by river_max_transversal_delta spread over
## river_control_point_spacing steps) while every cross-section is at least
## river_min_width tiles wide, so consecutive stamps always overlap: the whole
## band is a single 4-connected component with no isolated water tile, and
## since every control point's width is clamped into
## [river_min_width, river_max_width] (default 6-12, both >= NECK_FLOOR),
## linear interpolation between two such values never dips below
## river_min_width, satisfying "a transversal corridor of at least 4 tiles in
## bends" with margin to spare.
static func _carve_river(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary) -> Array[Vector2i]:
	var water_tiles: Array[Vector2i] = []
	var horizontal := random.randi_range(0, 1) == 0
	var dominant := width if horizontal else height
	var transversal := height if horizontal else width
	if dominant < 2 or transversal < NECK_FLOOR:
		return water_tiles

	var min_width := clampi(int(mapgen.get("river_min_width", DEFAULT_RIVER_MIN_WIDTH)), NECK_FLOOR, maxi(NECK_FLOOR, transversal - 1))
	var max_width := clampi(int(mapgen.get("river_max_width", DEFAULT_RIVER_MAX_WIDTH)), min_width, maxi(min_width, transversal - 1))
	var spacing := clampi(int(mapgen.get("river_control_point_spacing", DEFAULT_RIVER_CONTROL_SPACING)), 1, maxi(1, dominant))
	var max_delta := maxi(1, int(mapgen.get("river_max_transversal_delta", DEFAULT_RIVER_MAX_DELTA)))

	var margin := clampi(max_width / 2 + 1, 1, maxi(1, transversal / 2))
	var low := margin
	var high := transversal - 1 - margin
	if high < low:
		low = 0
		high = transversal - 1

	var control_positions: Array[int] = []
	var s := 0
	while s < dominant - 1:
		control_positions.append(s)
		s += spacing
	control_positions.append(dominant - 1)

	var control_center: Array[int] = []
	var control_width: Array[int] = []
	var center := random.randi_range(low, high)
	for i in control_positions.size():
		if i > 0:
			center = clampi(center + random.randi_range(-max_delta, max_delta), low, high)
		control_center.append(center)
		control_width.append(random.randi_range(min_width, max_width))

	var segment := 0
	for pos in dominant:
		while segment + 1 < control_positions.size() and pos > control_positions[segment + 1]:
			segment += 1
		var next_index := mini(segment + 1, control_positions.size() - 1)
		var seg_start := control_positions[segment]
		var seg_end := control_positions[next_index]
		var t := 0.0
		if seg_end > seg_start:
			t = float(pos - seg_start) / float(seg_end - seg_start)
		var center_f: float = lerpf(float(control_center[segment]), float(control_center[next_index]), t)
		var width_f: float = lerpf(float(control_width[segment]), float(control_width[next_index]), t)
		var half := width_f * 0.5
		var cross_start := clampi(int(floor(center_f - half)), 0, transversal - 1)
		var cross_end := clampi(cross_start + maxi(1, int(round(width_f))) - 1, 0, transversal - 1)
		for cross in range(cross_start, cross_end + 1):
			var x := pos if horizontal else cross
			var y := cross if horizontal else pos
			map[_index(x, y, width)] = TILE_WATER
			water_tiles.append(Vector2i(x, y))

	return water_tiles

## Multi-source BFS over 4-connected TILE_SOIL tiles (issue #300 Goal: "do not
## confuse geometric distance with route distance" -- this is a real hop-count over
## passable tiles, never Chebyshev/Euclidean distance). Sources are every
## TILE_SOIL tile adjacent to a tile `is_target` accepts, seeded at distance 1
## (the walk to reach it, plus one interaction step onto/into the resource
## itself); `extra_blocked` (berry_bush tile indices) is excluded from both
## seeding and expansion, since a bush occupies its tile the same way an
## impassable object would. Returns a width*height PackedInt32Array, -1 where
## unreached.
static func _distance_field(map: Array[String], width: int, height: int, is_target: Callable, extra_blocked: Dictionary) -> PackedInt32Array:
	var size := width * height
	var dist := PackedInt32Array()
	dist.resize(size)
	for i in size:
		dist[i] = -1
	var queue: Array[int] = []
	for y in height:
		for x in width:
			var index := _index(x, y, width)
			if map[index] != TILE_SOIL or extra_blocked.has(index):
				continue
			for offset in NEI4:
				var nx := x + offset.x
				var ny := y + offset.y
				if nx < 0 or nx >= width or ny < 0 or ny >= height:
					continue
				if is_target.call(nx, ny):
					dist[index] = 1
					queue.append(index)
					break
	var head := 0
	while head < queue.size():
		var index: int = queue[head]
		head += 1
		var next_distance: int = dist[index] + 1
		var x := index % width
		var y := index / width
		for offset in NEI4:
			var nx := x + offset.x
			var ny := y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nindex := _index(nx, ny, width)
			if dist[nindex] != -1:
				continue
			if map[nindex] != TILE_SOIL or extra_blocked.has(nindex):
				continue
			dist[nindex] = next_distance
			queue.append(nindex)
	return dist

## Every TILE_ROCK tile belonging to a 4-connected component of at least
## min_size tiles (issue #351/#347 revision: place_spawn()'s own outcrop
## reachability must apply the SAME qualification test_river_generation.gd's
## _rock_components() enforces, so an isolated rock -- or an undersized
## rock_vein_count stub, which is never grown by _scatter_rock_outcrops() and
## must not accidentally satisfy this either -- can never stand in for a real,
## big-enough outcrop). Independent of _scatter_rock_outcrops()'s own blob
## bookkeeping: this rescans the FINAL map array, exactly like the test does,
## so it also honors any rock painted by an earlier pass. Returns a lookup of
## qualifying tile indices only; every other TILE_ROCK tile is excluded from
## outcrop_dist below the same way an off-map tile is.
static func _qualifying_outcrop_tiles(map: Array[String], width: int, height: int, min_size: int) -> Dictionary:
	var qualifying: Dictionary = {}
	var visited: Dictionary = {}
	for start_index in map.size():
		if map[start_index] != TILE_ROCK or visited.has(start_index):
			continue
		var component: Array[int] = [start_index]
		visited[start_index] = true
		var head := 0
		while head < component.size():
			var index: int = component[head]
			head += 1
			var x := index % width
			var y := index / width
			for offset in NEI4:
				var nx := x + offset.x
				var ny := y + offset.y
				if nx < 0 or nx >= width or ny < 0 or ny >= height:
					continue
				var nindex := _index(nx, ny, width)
				if visited.has(nindex) or map[nindex] != TILE_ROCK:
					continue
				visited[nindex] = true
				component.append(nindex)
		if component.size() >= min_size:
			for index in component:
				qualifying[index] = true
	return qualifying

## Every rectangle tile, row-major -- the footprint a rect-based candidate
## (tiers 1/2 below) hands to _count_reachable_food_sources().
static func _rect_tiles(anchor_x: int, anchor_y: int, clearing_width: int, clearing_height: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for y in range(anchor_y, anchor_y + clearing_height):
		for x in range(anchor_x, anchor_x + clearing_width):
			tiles.append(Vector2i(x, y))
	return tiles

## Counts DISTINCT berry-bush tiles reachable from EVERY tile of `footprint`
## (a candidate clearing's own soil tiles, evaluated before it is ever painted
## to floor) within `limit` hops -- not merely from the footprint's own
## nearest tile. The later Fisher-Yates shuffle (place_spawn()'s own
## _shuffle_positions() call) can assign a colonist to ANY tile the footprint
## reserves, so a bush counted only because the footprint's CLOSEST tile can
## reach it would not actually be guaranteed for a colonist landing on the
## footprint's FARTHEST tile instead -- this is the worst-case, not the
## best-case, over the whole footprint.
##
## Two bounded passes, no full-grid scan: (1) a cheap multi-source BFS from
## every footprint tile at once finds every bush whose NEAREST footprint tile
## is in budget -- a superset of the true answer, cheaply ruling out anything
## too far from the footprint entirely; (2) for each of that small candidate
## set, one bounded BFS from the bush itself (_reaches_every_tile()) confirms
## every footprint tile -- not just the nearest -- is within `limit`. Distance
## follows _distance_field()'s own "walk to reach it, plus one interaction
## step" metric throughout (a bush's own tile is never entered, matching a
## real berry_bush object's passability).
static func _count_reachable_food_sources(map: Array[String], width: int, height: int, footprint: Array[Vector2i], bush_lookup: Dictionary, limit: int) -> int:
	if limit < 0 or footprint.is_empty():
		return 0
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = []
	for pos in footprint:
		var index := _index(pos.x, pos.y, width)
		if not visited.has(index):
			visited[index] = 0
			queue.append(pos)
	var candidate_bushes: Dictionary = {}
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var dist: int = visited[_index(current.x, current.y, width)]
		var next_dist := dist + 1
		if next_dist > limit:
			continue
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nindex := _index(nx, ny, width)
			if bush_lookup.has(nindex):
				candidate_bushes[nindex] = true
				continue
			if map[nindex] != TILE_SOIL or visited.has(nindex):
				continue
			visited[nindex] = next_dist
			queue.append(Vector2i(nx, ny))

	if candidate_bushes.is_empty():
		return 0

	var footprint_lookup: Dictionary = {}
	for pos in footprint:
		footprint_lookup[_index(pos.x, pos.y, width)] = true

	var confirmed := 0
	for bush_index in candidate_bushes.keys():
		var bush := Vector2i(int(bush_index) % width, int(bush_index) / width)
		if _reaches_every_tile(map, width, height, bush, footprint_lookup, bush_lookup, limit):
			confirmed += 1
	return confirmed

## True when a bounded BFS outward from `bush` (over TILE_SOIL, never entering
## the bush's own tile, nor any OTHER bush-occupied tile in `bush_lookup` --
## a bush occupies its tile the same way an impassable object would, so a
## route cannot cut through one bush to certify reachability of another;
## round 6 review: without this exclusion the search could walk straight
## through a wall of blocking bushes and falsely certify a farther footprint
## tile that a real, bush-respecting route could never reach within budget)
## reaches every index in `targets` within `limit` hops. The worst-case
## distance from this one bush to any tile a later shuffle could assign a
## colonist to, not merely the nearest such tile.
static func _reaches_every_tile(map: Array[String], width: int, height: int, bush: Vector2i, targets: Dictionary, bush_lookup: Dictionary, limit: int) -> bool:
	var remaining := targets.size()
	if remaining <= 0:
		return true
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = []
	for offset in NEI4:
		var nx := bush.x + offset.x
		var ny := bush.y + offset.y
		if nx < 0 or nx >= width or ny < 0 or ny >= height:
			continue
		var nindex := _index(nx, ny, width)
		if map[nindex] != TILE_SOIL or bush_lookup.has(nindex) or visited.has(nindex):
			continue
		visited[nindex] = 1
		if targets.has(nindex):
			remaining -= 1
		queue.append(Vector2i(nx, ny))
	if remaining <= 0:
		return true
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var dist: int = visited[_index(current.x, current.y, width)]
		var next_dist := dist + 1
		if next_dist > limit:
			continue
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nindex := _index(nx, ny, width)
			if visited.has(nindex) or map[nindex] != TILE_SOIL or bush_lookup.has(nindex):
				continue
			visited[nindex] = next_dist
			if targets.has(nindex):
				remaining -= 1
				if remaining <= 0:
					return true
			queue.append(Vector2i(nx, ny))
	return remaining <= 0

## Bounded deterministic search for the colonists' starting clearing (issue
## #300 Goal: "search for a spawn with a deterministic attempt limit and a
## documented fallback; no loops until it randomly succeeds"). Four
## deterministic, bounded tiers, each only run once the previous one produced
## nothing, and each always preferring a fully budget-compliant candidate over
## a relaxed one before ever relaxing further (round 2 review: a soft
## over-budget "best" from an earlier tier must never suppress a later,
## better-searching tier from running at all):
##
## 1. Random search (`_evaluate_clearing`), up to spawn_search_attempts tries,
##    biased near a random river tile. Accepts ONLY a fully-compliant
##    candidate (all-soil, bush-free, every tile's water/food/tree/outcrop
##    route distance within mapgen.json's own step limits -- outcrop_dist
##    reuses spawn_tree_step_limit, threaded through exactly parallel to
##    tree_dist, issue #351/#347 -- AND at least
##    `colonist_count * FOOD_SOURCES_PER_COLONIST` DISTINCT reachable bushes
##    within the food step limit -- round 5 review: a short route to the
##    NEAREST bush is not "sufficient" when that same single-use bush is the
##    nearest one for all three colonists) -- an over-budget or
##    insufficient-food candidate is discarded outright here, never kept as a
##    blocking "best", so tier 2 always gets to run when tier 1 does not find
##    a real match.
## 2. Exhaustive row-major scan (_scan_for_clearing) of every possible anchor,
##    same full-compliance bar as tier 1 (including the distinct-food-source
##    floor) but guaranteed to find any compliant anchor tier 1's random
##    sampling missed. Falls back, only within this same scan, to the
##    least-over-budget still-REACHABLE anchor (no -1 distance anywhere in its
##    footprint, scored including any food-source shortfall) if no
##    fully-compliant one exists -- "recursos garantizados no cuentan si son
##    inaccesibles" is enforced here structurally: an anchor with any
##    unreachable resource is never chosen by this tier at all, only relaxed
##    on the step-limit/food-source-count budget.
## 3. Deterministic repair/construct (_repair_land_clearing): only reached
##    when no clearing_width x clearing_height all-soil rectangle exists
##    anywhere satisfying tier 2 (e.g. a small or heavily obstructed map).
##    Finds every 4-connected TILE_SOIL (bush-free) component on the map and
##    picks whichever one, big enough to hold colonist_count colonists plus
##    room for starting tools/beds, is fully compliant, else least-over-budget
##    reachable, else (last resort within this tier) simply the first
##    big-enough component -- honestly reporting -1 for any dimension that
##    truly has no reachable source, rather than silently accepting it as
##    good. Never touches water or an existing berry bush (the component
##    search excludes both by construction), so the river and existing
##    decoration are never bulldozed.
## 4. Absolute last resort (_expanding_soil_search from mapgen.json's own
##    spawn_area_x/y): only reached when the ENTIRE map has no connected land
##    component with even colonist_count soil tiles (never observed for any
##    real generated map). Expands outward in bounded rings collecting plain
##    soil tiles, painting only what it actually finds -- it may legitimately
##    return fewer than colonist_count positions rather than ever bulldozing
##    rock/hazard/tree terrain or overwriting water.
##
## Because every tier's distance fields only ever expand across TILE_SOIL, a
## candidate can only succeed using resources reachable without crossing the
## (impassable) river, which is exactly "misma orilla" (same shore) without
## any separate bank-side bookkeeping. Every fallback path (any tier past the
## first) is reported via the returned "fallback" flag so a caller (or a
## test) can assert it was never actually taken for the real seed suite.
static func place_spawn(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary,
		water_tiles: Array[Vector2i], berry_bush_tiles: Array[Vector2i], colonist_count: int) -> Dictionary:
	var clearing_width := maxi(1, mini(int(mapgen.get("spawn_area_width", 6)), width))
	var clearing_height := maxi(1, mini(int(mapgen.get("spawn_area_height", 6)), height))
	var attempts := maxi(1, int(mapgen.get("spawn_search_attempts", DEFAULT_SPAWN_SEARCH_ATTEMPTS)))
	var water_limit := int(mapgen.get("spawn_water_step_limit", DEFAULT_SPAWN_WATER_STEP_LIMIT))
	var food_limit := int(mapgen.get("spawn_food_step_limit", DEFAULT_SPAWN_FOOD_STEP_LIMIT))
	var tree_limit := int(mapgen.get("spawn_tree_step_limit", DEFAULT_SPAWN_TREE_STEP_LIMIT))

	var bush_lookup: Dictionary = {}
	for pos in berry_bush_tiles:
		bush_lookup[_index(pos.x, pos.y, width)] = true

	var water_dist := _distance_field(map, width, height, func(x, y): return map[_index(x, y, width)] == TILE_WATER, bush_lookup)
	var tree_dist := _distance_field(map, width, height, func(x, y): return map[_index(x, y, width)] == TILE_TREE, bush_lookup)
	var food_dist := _distance_field(map, width, height, func(x, y): return bush_lookup.has(_index(x, y, width)), bush_lookup)
	# outcrop_dist is bounded by the SAME spawn_tree_step_limit already read
	# for trees (tree_limit) -- issue #351/#347 Goal: no separate mapgen field
	# for this bound -- so a spawn clearing gets the same structural
	# reachability guarantee for a rock outcrop that it already gets for trees.
	# Qualified against outcrop_min_size (see _qualifying_outcrop_tiles() above)
	# so a nearby isolated rock or an undersized rock_vein_count stub can never
	# satisfy full acceptance or distort relaxed-candidate scoring in place of
	# a real, big-enough outcrop.
	var outcrop_min_size := maxi(1, int(mapgen.get("outcrop_min_size", DEFAULT_OUTCROP_MIN_SIZE)))
	var qualifying_outcrop_tiles := _qualifying_outcrop_tiles(map, width, height, outcrop_min_size)
	var outcrop_dist := _distance_field(map, width, height, func(x, y): return qualifying_outcrop_tiles.has(_index(x, y, width)), bush_lookup)
	var outcrop_limit := tree_limit
	var required_food_sources := colonist_count * FOOD_SOURCES_PER_COLONIST

	var max_anchor_x := maxi(0, width - clearing_width)
	var max_anchor_y := maxi(0, height - clearing_height)

	# Tier 1.
	var chosen: Dictionary = {}
	for attempt in attempts:
		if water_tiles.is_empty():
			break
		var seed_tile: Vector2i = water_tiles[random.randi_range(0, water_tiles.size() - 1)]
		var anchor_x := clampi(seed_tile.x + random.randi_range(-water_limit, water_limit), 0, max_anchor_x)
		var anchor_y := clampi(seed_tile.y + random.randi_range(-water_limit, water_limit), 0, max_anchor_y)
		var candidate := _evaluate_clearing(map, anchor_x, anchor_y, clearing_width, clearing_height, width, water_dist, tree_dist, food_dist, outcrop_dist, bush_lookup, true)
		if candidate.is_empty():
			continue
		if int(candidate["water"]) > water_limit or int(candidate["food"]) > food_limit or int(candidate["tree"]) > tree_limit or int(candidate["outcrop"]) > outcrop_limit:
			continue
		# Cheap distance checks passed -- only now pay for the bounded
		# distinct-bush BFS (round 5 review): the same single reachable bush
		# that satisfies the cheap "nearest" check above must not be accepted
		# as "sufficient" for all three colonists.
		var food_sources := _count_reachable_food_sources(map, width, height, _rect_tiles(anchor_x, anchor_y, clearing_width, clearing_height), bush_lookup, food_limit)
		if food_sources < required_food_sources:
			continue
		candidate["food_sources"] = food_sources
		chosen = candidate
		break

	var fallback := chosen.is_empty()

	# Tier 2.
	if chosen.is_empty():
		chosen = _scan_for_clearing(map, width, height, clearing_width, clearing_height,
			water_dist, tree_dist, food_dist, outcrop_dist, bush_lookup, water_limit, food_limit, tree_limit, outcrop_limit, required_food_sources)

	var rect_based := not chosen.is_empty()
	var repaired: Dictionary = {}

	# Tier 3.
	if chosen.is_empty():
		repaired = _repair_land_clearing(map, width, height, colonist_count, bush_lookup,
			water_dist, tree_dist, food_dist, outcrop_dist, water_limit, food_limit, tree_limit, outcrop_limit, required_food_sources)

	# Tier 4.
	if chosen.is_empty() and repaired.is_empty():
		var origin_x := clampi(int(mapgen.get("spawn_area_x", 2)), 0, maxi(0, width - 1))
		var origin_y := clampi(int(mapgen.get("spawn_area_y", 2)), 0, maxi(0, height - 1))
		var found := _expanding_soil_search(map, width, height, origin_x, origin_y, bush_lookup, colonist_count + REPAIR_RESERVE_CELLS)
		repaired = {"land_tiles": found,
			"water": -1 if found.is_empty() else 0, "food": -1 if found.is_empty() else 0, "tree": -1 if found.is_empty() else 0,
			"outcrop": -1 if found.is_empty() else 0,
			"food_sources": 0 if found.is_empty() else _count_reachable_food_sources(map, width, height, found, bush_lookup, food_limit)}

	var land_tiles: Array[Vector2i] = []
	var clearing_x: int
	var clearing_y: int
	var report_width: int
	var report_height: int
	var water_steps: int
	var food_steps: int
	var tree_steps: int
	var outcrop_steps: int
	var food_sources: int

	if rect_based:
		clearing_x = chosen["x"]
		clearing_y = chosen["y"]
		report_width = clearing_width
		report_height = clearing_height
		water_steps = int(chosen["water"])
		food_steps = int(chosen["food"])
		tree_steps = int(chosen["tree"])
		outcrop_steps = int(chosen["outcrop"])
		food_sources = int(chosen.get("food_sources", 0))
		# Never overwrites a water tile -- the one invariant every tier above
		# must honour identically, so the river's connectivity/width survives
		# regardless of which tier chose the anchor.
		for y in range(clearing_y, clearing_y + clearing_height):
			for x in range(clearing_x, clearing_x + clearing_width):
				var index := _index(x, y, width)
				if map[index] != TILE_WATER:
					map[index] = TILE_FLOOR
				if map[_index(x, y, width)] == TILE_FLOOR:
					land_tiles.append(Vector2i(x, y))
	else:
		var reserved: Array[Vector2i] = repaired.get("land_tiles", [])
		for pos in reserved:
			map[_index(pos.x, pos.y, width)] = TILE_FLOOR
			land_tiles.append(pos)
		# A repaired/constructed clearing is a scattered land selection, not a
		# solid rectangle -- reporting its own bounding box as a "rectangle"
		# could claim a non-floor tile (rock/hazard/water) is inside the
		# clearing. Every caller that reads x/y/width/height (debug_scenario.gd
		## wall/furniture rows, test_world_state_determinism.gd's per-tile
		## floor check) only needs a guaranteed-floor anchor, so this reports a
		## degenerate 1x1 rectangle at the first reserved tile instead.
		if land_tiles.is_empty():
			clearing_x = clampi(int(mapgen.get("spawn_area_x", 2)), 0, maxi(0, width - 1))
			clearing_y = clampi(int(mapgen.get("spawn_area_y", 2)), 0, maxi(0, height - 1))
		else:
			clearing_x = land_tiles[0].x
			clearing_y = land_tiles[0].y
		report_width = 1
		report_height = 1
		water_steps = int(repaired.get("water", -1))
		food_steps = int(repaired.get("food", -1))
		tree_steps = int(repaired.get("tree", -1))
		outcrop_steps = int(repaired.get("outcrop", -1))
		food_sources = int(repaired.get("food_sources", 0))

	# A berry bush whose tile fell inside the chosen clearing must not survive
	# as an object placed over the new floor (a colonist could otherwise spawn
	# on/beside a retained blocking bush); every tier above already excludes
	# bush tiles from a footprint it accepts, so this only ever prunes
	# something a repair/last-resort tier's own component search somehow
	# still touched. WorldState._spawn_colonists() places bush objects from
	# this returned list, not from its own pre-search snapshot.
	var land_lookup: Dictionary = {}
	for pos in land_tiles:
		land_lookup[_index(pos.x, pos.y, width)] = true
	var remaining_berry_bush_tiles: Array[Vector2i] = []
	for pos in berry_bush_tiles:
		if not land_lookup.has(_index(pos.x, pos.y, width)):
			remaining_berry_bush_tiles.append(pos)

	_shuffle_positions(random, land_tiles)
	var colonist_positions: Array[Vector2i] = land_tiles.slice(0, mini(colonist_count, land_tiles.size()))
	# Every reserved land tile not used for a colonist is a guaranteed-safe
	# (never water, never a retained bush) tile for boot.gd/debug_scenario.gd
	# to place starting tools/beds on, instead of computing a raw
	# `clearing_x + i % clearing_width` offset that a fallback tier's
	# rectangle could leave pointing at a still-water cell (round 2 review).
	var tool_tiles: Array[Vector2i] = land_tiles.slice(colonist_positions.size())

	return {
		"clearing": {
			"x": clearing_x, "y": clearing_y, "width": report_width, "height": report_height,
			"water_steps": water_steps, "food_steps": food_steps, "tree_steps": tree_steps, "outcrop_steps": outcrop_steps,
			"food_sources": food_sources, "required_food_sources": required_food_sources,
			"fallback": fallback or not rect_based,
			"land_tiles": tool_tiles,
		},
		"colonist_positions": colonist_positions,
		"berry_bush_tiles": remaining_berry_bush_tiles,
	}

## Exhaustive, deterministic, row-major scan of every possible anchor
## position -- bounded by width*height, never "until luck": the tier for when
## spawn_search_attempts random samples (biased near the river) missed a
## fully-compliant anchor that exists elsewhere on the map. Reuses
## _evaluate_clearing(require_reachable=true) so it can never accept a
## footprint touching water, a berry-bush tile, or any tile with an
## unreachable (-1) resource distance -- "recursos garantizados no cuentan si
## son inaccesibles" holds for this tier's own relaxed branch too, which only
## ever relaxes the step-limit BUDGET, never reachability itself. Returns a
## fully budget-compliant anchor the instant one is found (never relaxes
## unnecessarily); otherwise the least-over-budget reachable anchor seen,
## scored by summed overage across all four limits (water/food/tree/outcrop --
## outcrop_dist is threaded through exactly parallel to tree_dist/tree_limit,
## issue #351/#347) plus any distinct-food-source deficit (round 5 review:
## distance to the nearest bush alone is not "sufficient" -- see
## FOOD_SOURCES_PER_COLONIST); {} only when no all-soil, bush-free,
## fully-reachable footprint of this size exists anywhere on the map.
static func _scan_for_clearing(map: Array[String], width: int, height: int, clearing_width: int, clearing_height: int,
		water_dist: PackedInt32Array, tree_dist: PackedInt32Array, food_dist: PackedInt32Array, outcrop_dist: PackedInt32Array, bush_lookup: Dictionary,
		water_limit: int, food_limit: int, tree_limit: int, outcrop_limit: int, required_food_sources: int) -> Dictionary:
	var max_anchor_x := maxi(0, width - clearing_width)
	var max_anchor_y := maxi(0, height - clearing_height)
	var best_relaxed: Dictionary = {}
	var best_relaxed_score := INF
	for anchor_y in range(0, max_anchor_y + 1):
		for anchor_x in range(0, max_anchor_x + 1):
			var candidate := _evaluate_clearing(map, anchor_x, anchor_y, clearing_width, clearing_height, width,
				water_dist, tree_dist, food_dist, outcrop_dist, bush_lookup, true)
			if candidate.is_empty():
				continue
			var water: int = candidate["water"]
			var food: int = candidate["food"]
			var tree: int = candidate["tree"]
			var outcrop: int = candidate["outcrop"]
			var food_sources := _count_reachable_food_sources(map, width, height, _rect_tiles(anchor_x, anchor_y, clearing_width, clearing_height), bush_lookup, food_limit)
			candidate["food_sources"] = food_sources
			if water <= water_limit and food <= food_limit and tree <= tree_limit and outcrop <= outcrop_limit and food_sources >= required_food_sources:
				return candidate
			var score: float = (maxf(0.0, float(water - water_limit)) + maxf(0.0, float(food - food_limit))
				+ maxf(0.0, float(tree - tree_limit)) + maxf(0.0, float(outcrop - outcrop_limit)) + maxf(0.0, float(required_food_sources - food_sources)))
			if score < best_relaxed_score:
				best_relaxed_score = score
				best_relaxed = candidate
	return best_relaxed

## Extra land tiles reserved (beyond colonist_count) for a repaired/
## constructed clearing, so starting tools and one bed per colonist (see
## boot.gd's _spawn_starting_tools/_spawn_starting_beds) still have somewhere
## safe to land even when the whole clearing had to be assembled from a bare
## connected land component instead of a spacious mapgen.json rectangle.
const REPAIR_RESERVE_CELLS := 8

## Tier 3: every 4-connected TILE_SOIL (bush-free) component on the map, each
## scored exactly like _scan_for_clearing above (full budget compliance,
## including the distinct-food-source floor, preferred, then
## least-over-budget-but-reachable, then, only if nothing on the whole map is
## even resource-reachable, the first component simply big enough to hold
## colonist_count colonists) -- so a fully-compliant or
## reachable-but-relaxed connected clearing is always preferred over one
## reporting a dishonest/unreachable resource. {} only when no connected land
## component anywhere has even colonist_count cells.
static func _repair_land_clearing(map: Array[String], width: int, height: int, colonist_count: int, bush_lookup: Dictionary,
		water_dist: PackedInt32Array, tree_dist: PackedInt32Array, food_dist: PackedInt32Array, outcrop_dist: PackedInt32Array,
		water_limit: int, food_limit: int, tree_limit: int, outcrop_limit: int, required_food_sources: int) -> Dictionary:
	var needed_cells := colonist_count + REPAIR_RESERVE_CELLS
	var components := _land_components(map, width, height, bush_lookup)
	var best_full: Dictionary = {}
	var best_relaxed: Dictionary = {}
	var best_relaxed_score := INF
	var best_any: Dictionary = {}
	for component in components:
		if component.size() < colonist_count:
			continue
		var reserved: Array[Vector2i] = component.slice(0, mini(component.size(), needed_cells))
		var worst_water := 0
		var worst_food := 0
		var worst_tree := 0
		var worst_outcrop := 0
		var water_unreachable := false
		var food_unreachable := false
		var tree_unreachable := false
		var outcrop_unreachable := false
		for pos in reserved:
			var index := _index(pos.x, pos.y, width)
			var wd: int = water_dist[index]
			var fd: int = food_dist[index]
			var td: int = tree_dist[index]
			var od: int = outcrop_dist[index]
			if wd == -1:
				water_unreachable = true
			else:
				worst_water = maxi(worst_water, wd)
			if fd == -1:
				food_unreachable = true
			else:
				worst_food = maxi(worst_food, fd)
			if td == -1:
				tree_unreachable = true
			else:
				worst_tree = maxi(worst_tree, td)
			if od == -1:
				outcrop_unreachable = true
			else:
				worst_outcrop = maxi(worst_outcrop, od)
		var food_sources := _count_reachable_food_sources(map, width, height, reserved, bush_lookup, food_limit)
		var result := {
			"land_tiles": reserved,
			"water": -1 if water_unreachable else worst_water,
			"food": -1 if food_unreachable else worst_food,
			"tree": -1 if tree_unreachable else worst_tree,
			"outcrop": -1 if outcrop_unreachable else worst_outcrop,
			"food_sources": food_sources,
		}
		if best_any.is_empty():
			best_any = result
		if water_unreachable or food_unreachable or tree_unreachable or outcrop_unreachable:
			continue
		if worst_water <= water_limit and worst_food <= food_limit and worst_tree <= tree_limit and worst_outcrop <= outcrop_limit and food_sources >= required_food_sources:
			if best_full.is_empty():
				best_full = result
				continue
		var score: float = (maxf(0.0, float(worst_water - water_limit)) + maxf(0.0, float(worst_food - food_limit))
			+ maxf(0.0, float(worst_tree - tree_limit)) + maxf(0.0, float(worst_outcrop - outcrop_limit)) + maxf(0.0, float(required_food_sources - food_sources)))
		if score < best_relaxed_score:
			best_relaxed_score = score
			best_relaxed = result
	if not best_full.is_empty():
		return best_full
	if not best_relaxed.is_empty():
		return best_relaxed
	return best_any

## Every 4-connected component of TILE_SOIL tiles that are not a berry-bush
## tile, in row-major discovery order -- a single deterministic full-map scan
## (bounded by width*height, never "until luck"), each component's own tiles
## in BFS order from its first-discovered cell.
static func _land_components(map: Array[String], width: int, height: int, bush_lookup: Dictionary) -> Array:
	var visited: Dictionary = {}
	var components: Array = []
	for y in height:
		for x in width:
			var index := _index(x, y, width)
			if map[index] != TILE_SOIL or bush_lookup.has(index) or visited.has(index):
				continue
			var component: Array[Vector2i] = []
			var queue: Array[int] = [index]
			visited[index] = true
			var head := 0
			while head < queue.size():
				var current: int = queue[head]
				head += 1
				var cx := current % width
				var cy := current / width
				component.append(Vector2i(cx, cy))
				for offset in NEI4:
					var nx := cx + offset.x
					var ny := cy + offset.y
					if nx < 0 or nx >= width or ny < 0 or ny >= height:
						continue
					var nindex := _index(nx, ny, width)
					if visited.has(nindex) or map[nindex] != TILE_SOIL or bush_lookup.has(nindex):
						continue
					visited[nindex] = true
					queue.append(nindex)
			components.append(component)
	return components

## Tier 4, the absolute last resort (never observed for any real generated
## map): a bounded expanding-ring scan outward from mapgen.json's own
## spawn_area_x/y, collecting plain soil tiles (never a berry-bush tile) up to
## max_needed. Bounded by max(width, height) rings -- never "until luck" --
## and may legitimately return fewer than max_needed tiles (even zero) rather
## than ever touching water, rock, hazard or tree terrain.
static func _expanding_soil_search(map: Array[String], width: int, height: int, origin_x: int, origin_y: int,
		bush_lookup: Dictionary, max_needed: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	var max_radius := maxi(width, height)
	for radius in range(0, max_radius + 1):
		for y in range(origin_y - radius, origin_y + radius + 1):
			if y < 0 or y >= height:
				continue
			for x in range(origin_x - radius, origin_x + radius + 1):
				if x < 0 or x >= width:
					continue
				if maxi(absi(x - origin_x), absi(y - origin_y)) != radius:
					continue
				var index := _index(x, y, width)
				if map[index] == TILE_SOIL and not bush_lookup.has(index):
					found.append(Vector2i(x, y))
					if found.size() >= max_needed:
						return found
	return found

## Returns {} when the footprint runs off the map, contains any non-soil
## tile, contains a berry-bush tile, or (when require_reachable) contains a
## tile any of the four distance fields never reached; otherwise
## {"x","y","water","food","tree","outcrop"}, each distance the WORST (max)
## over the footprint -- so passing the check means every tile in the
## clearing, not just its closest corner, is within bounds. outcrop_dist is
## threaded through exactly parallel to tree_dist (issue #351/#347), not a
## separate post-hoc check. bush_lookup is checked explicitly (round 1 review
## finding 3), not only inferred from an unreached distance field, so a
## caller with require_reachable false still excludes bush tiles.
static func _evaluate_clearing(map: Array[String], anchor_x: int, anchor_y: int, clearing_width: int, clearing_height: int,
		width: int, water_dist: PackedInt32Array, tree_dist: PackedInt32Array, food_dist: PackedInt32Array, outcrop_dist: PackedInt32Array,
		bush_lookup: Dictionary, require_reachable: bool) -> Dictionary:
	var height := water_dist.size() / width
	if anchor_x < 0 or anchor_y < 0 or anchor_x + clearing_width > width or anchor_y + clearing_height > height:
		return {}
	var worst_water := 0
	var worst_food := 0
	var worst_tree := 0
	var worst_outcrop := 0
	for y in range(anchor_y, anchor_y + clearing_height):
		for x in range(anchor_x, anchor_x + clearing_width):
			var index := _index(x, y, width)
			if map[index] != TILE_SOIL or bush_lookup.has(index):
				return {}
			var wd: int = water_dist[index]
			var fd: int = food_dist[index]
			var td: int = tree_dist[index]
			var od: int = outcrop_dist[index]
			if require_reachable and (wd == -1 or fd == -1 or td == -1 or od == -1):
				return {}
			worst_water = maxi(worst_water, wd)
			worst_food = maxi(worst_food, fd)
			worst_tree = maxi(worst_tree, td)
			worst_outcrop = maxi(worst_outcrop, od)
	return {"x": anchor_x, "y": anchor_y, "water": worst_water, "food": worst_food, "tree": worst_tree, "outcrop": worst_outcrop}

## Fisher-Yates, shared by place_spawn() above (issue #300; moved from
## WorldState._shuffle_positions(), which had no other caller left once
## colonist placement moved into this module).
static func _shuffle_positions(random: RandomNumberGenerator, positions: Array[Vector2i]) -> void:
	for i in range(positions.size() - 1, 0, -1):
		var j := random.randi_range(0, i)
		var temp := positions[i]
		positions[i] = positions[j]
		positions[j] = temp
