class_name WorldGenerator
extends RefCounted

## Pure terrain generation (ADR 019, ADR 020): no scenes, content-registry instances or global
## randomness. Every draw comes from the injected RandomNumberGenerator in a fixed order, so a
## seed reproduces the same terrain for the same width, height and mapgen document.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

## Bumped when the algorithm changes (not mapgen.json values); saved as map.generatorVersion.
## 2: main river, correlated vegetation, river-aware spawn. 3: grown rock outcrops.
const GENERATOR_VERSION := 3

const TILE_ROCK := ContentRegistryType.TILE_ROCK
const TILE_SOIL := ContentRegistryType.TILE_SOIL
const TILE_FLOOR := ContentRegistryType.TILE_FLOOR
const TILE_HAZARD := ContentRegistryType.TILE_HAZARD
const TILE_TREE := ContentRegistryType.TILE_TREE
const TILE_WATER := ContentRegistryType.TILE_WATER

## The size mapgen.json's counts/attempts are tuned for (see _density_scale()).
const DEFAULT_REFERENCE_SIZE := 48
const DEFAULT_MIN_WORLD_SIZE := 16
const DEFAULT_MAX_WORLD_SIZE := 512

## Defensive floor for river width; mapgen's river_min_width/max_width (6/12) stay above it.
const NECK_FLOOR := 4
const DEFAULT_RIVER_MIN_WIDTH := 6
const DEFAULT_RIVER_MAX_WIDTH := 12
const DEFAULT_RIVER_CONTROL_SPACING := 24
const DEFAULT_RIVER_MAX_DELTA := 6

const DEFAULT_TREE_GROVE_COUNT := 6
const DEFAULT_TREE_GROVE_RADIUS := 5

## Outcrop count scales with area; size and compactness are spatial and never scaled.
const DEFAULT_OUTCROP_COUNT := 5
const DEFAULT_OUTCROP_MIN_SIZE := 6
const DEFAULT_OUTCROP_MAX_SIZE := 16
const DEFAULT_OUTCROP_PLACEMENT_ATTEMPTS := 200
const DEFAULT_OUTCROP_COMPACTNESS := 0.7

const DEFAULT_BERRY_BUSH_COUNT := 8
const DEFAULT_BERRY_BUSH_PLACEMENT_ATTEMPTS := 120
const DEFAULT_BERRY_BUSH_GROVE_COUNT := 5
const DEFAULT_BERRY_BUSH_GROVE_RADIUS := 4

## Spawn distances are real 4-connected route hops over soil, never geometric distance.
const DEFAULT_SPAWN_SEARCH_ATTEMPTS := 300
const DEFAULT_SPAWN_WATER_STEP_LIMIT := 40
const DEFAULT_SPAWN_FOOD_STEP_LIMIT := 40
const DEFAULT_SPAWN_TREE_STEP_LIMIT := 50

## Forage consumes a bush into one meal with no regrowth, so the spawn needs colonist_count *
## this many distinct reachable bushes, not one short route to the nearest.
const FOOD_SOURCES_PER_COLONIST := 1

const NEI4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## Clamps into mapgen's min/max_world_size (module defaults when the document omits them).
static func resolve_size(requested_width: int, requested_height: int, mapgen: Dictionary) -> Vector2i:
	var min_size := int(mapgen.get("min_world_size", DEFAULT_MIN_WORLD_SIZE))
	var max_size := int(mapgen.get("max_world_size", DEFAULT_MAX_WORLD_SIZE))
	return Vector2i(
		clampi(requested_width, min_size, max_size),
		clampi(requested_height, min_size, max_size)
	)

## The new-game UI size, read from content.
static func default_new_game_size(mapgen: Dictionary) -> Vector2i:
	return Vector2i(
		int(mapgen.get("default_new_game_width", 256)),
		int(mapgen.get("default_new_game_height", 256))
	)

## Counts/attempts scale with area relative to the reference size (48x48 reproduces the
## historical counts); spatial extents (river width, grove radius) never scale. Rounds, so a
## positive base count never scales to zero.
static func _density_scale(width: int, height: int, mapgen: Dictionary) -> float:
	var reference_width := int(mapgen.get("reference_width", DEFAULT_REFERENCE_SIZE))
	var reference_height := int(mapgen.get("reference_height", DEFAULT_REFERENCE_SIZE))
	var reference_area := maxi(1, reference_width * reference_height)
	return float(width * height) / float(reference_area)

static func _scaled(base: int, scale: float) -> int:
	if base <= 0:
		return 0
	return maxi(1, int(round(float(base) * scale)))

## Tiles-only wrapper around generate_with_decorations() for focused tests.
static func generate(random: RandomNumberGenerator, width: int, height: int, mapgen: Dictionary) -> Array[String]:
	return generate_with_decorations(random, width, height, mapgen)["tiles"]

## {"tiles", "water_tiles", "berry_bush_tiles"} (row-major); WorldSeeding writes the bushes into
## ObjectTable. Draw order is fixed: veins, hazards, groves, outcrops, then the river last so
## nothing can plug it; later passes write only onto soil. Outcrops use their own substream, so
## they never shift the draws of other passes.
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

static func _carve_rock_veins(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary, scale: float) -> void:
	var count := _scaled(int(mapgen["rock_vein_count"]), scale)
	for vein_index in count:
		var x := random.randi_range(0, width - 1)
		var y := random.randi_range(0, height - 1)
		var length := random.randi_range(int(mapgen["rock_vein_min_length"]), int(mapgen["rock_vein_max_length"]))
		for step in length:
			map[TileGrid.flat_index(x, y, width)] = TILE_ROCK
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
		var index := TileGrid.flat_index(x, y, width)
		if map[index] == TILE_SOIL:
			map[index] = TILE_HAZARD
			placed += 1

## Trees in groves, not scattered; total trees split evenly across groves, soil only.
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
			var index := TileGrid.flat_index(x, y, width)
			if map[index] == TILE_SOIL:
				map[index] = TILE_TREE
				placed += 1
				placed_total += 1

## Seeds the outcrop substream so that pass never shifts the shared stream's draws. Distinct
## from WorldState's GEOGRAPHY_SEED_SALT/PLACEMENT_SEED_SALT.
const OUTCROP_SEED_SALT := 100_003

## Grown, 4-connected rock blobs onto soil only, up to a drawn size or the attempt budget
## (an obstructed map may yield a smaller blob). outcrop_compactness biases growth from the newest
## tile. Reads only random.seed, never advances `random`.
static func _scatter_rock_outcrops(random: RandomNumberGenerator, map: Array[String], width: int, height: int, mapgen: Dictionary, scale: float) -> void:
	var count := _scaled(int(mapgen.get("outcrop_count", DEFAULT_OUTCROP_COUNT)), scale)
	if count <= 0:
		return
	var min_size := maxi(1, int(mapgen.get("outcrop_min_size", DEFAULT_OUTCROP_MIN_SIZE)))
	var max_size := maxi(min_size, int(mapgen.get("outcrop_max_size", DEFAULT_OUTCROP_MAX_SIZE)))
	# 0 is honored: zero growth attempts places only the seed tile.
	var placement_attempts := maxi(0, int(mapgen.get("outcrop_placement_attempts", DEFAULT_OUTCROP_PLACEMENT_ATTEMPTS)))
	var compactness := clampf(float(mapgen.get("outcrop_compactness", DEFAULT_OUTCROP_COMPACTNESS)), 0.0, 1.0)
	var outcrop_random := RandomNumberGenerator.new()
	outcrop_random.seed = random.seed + OUTCROP_SEED_SALT
	for outcrop_index in count:
		_grow_rock_outcrop(outcrop_random, map, width, height, min_size, max_size, placement_attempts, compactness)

## No-op (one draw) when the seed tile is not plain soil.
static func _grow_rock_outcrop(random: RandomNumberGenerator, map: Array[String], width: int, height: int, min_size: int, max_size: int, placement_attempts: int, compactness: float) -> void:
	var seed_x := random.randi_range(0, width - 1)
	var seed_y := random.randi_range(0, height - 1)
	var seed_index := TileGrid.flat_index(seed_x, seed_y, width)
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

## -1 when no soil neighbour outside the blob exists.
static func _random_soil_neighbor(random: RandomNumberGenerator, map: Array[String], width: int, height: int, index: int, blob_lookup: Dictionary) -> int:
	var tile := TileGrid.flat_coord(index, width)
	var candidates: Array[int] = []
	for offset in NEI4:
		var nx := tile.x + offset.x
		var ny := tile.y + offset.y
		if nx < 0 or nx >= width or ny < 0 or ny >= height:
			continue
		var nindex := TileGrid.flat_index(nx, ny, width)
		if map[nindex] == TILE_SOIL and not blob_lookup.has(nindex):
			candidates.append(nindex)
	if candidates.is_empty():
		return -1
	return candidates[random.randi_range(0, candidates.size() - 1)]

## Returns bush positions only (bushes are objects, not tiles); soil tiles only, never mutates
## `map`.
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
			var index := TileGrid.flat_index(x, y, width)
			if map[index] != TILE_SOIL or used.has(index):
				continue
			used[index] = true
			positions.append(Vector2i(x, y))
			placed += 1

	return positions

## One river from edge to edge along a dominant axis; centre offset and width interpolate between
## random control points. The offset is single-valued per axis position, so each cross-section is
## one contiguous run (its width) and the band cannot self-intersect. Widths stay within
## [river_min_width, river_max_width], so consecutive stamps overlap: one 4-connected band.
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
			map[TileGrid.flat_index(x, y, width)] = TILE_WATER
			water_tiles.append(Vector2i(x, y))

	return water_tiles

## Multi-source BFS over soil: real route hops, not geometric distance. Soil tiles next to a
## target start at 1; bush tiles block like objects. -1 where unreached.
static func _distance_field(map: Array[String], width: int, height: int, is_target: Callable, extra_blocked: Dictionary) -> PackedInt32Array:
	var size := width * height
	var dist := PackedInt32Array()
	dist.resize(size)
	for i in size:
		dist[i] = -1
	var queue: Array[int] = []
	for y in height:
		for x in width:
			var index := TileGrid.flat_index(x, y, width)
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
		var tile := TileGrid.flat_coord(index, width)
		for offset in NEI4:
			var nx := tile.x + offset.x
			var ny := tile.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nindex := TileGrid.flat_index(nx, ny, width)
			if dist[nindex] != -1:
				continue
			if map[nindex] != TILE_SOIL or extra_blocked.has(nindex):
				continue
			dist[nindex] = next_distance
			queue.append(nindex)
	return dist

## Rock tiles in 4-connected components of at least min_size, rescanned from the final map, so
## an isolated rock or vein stub never counts as an outcrop.
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
			var tile := TileGrid.flat_coord(index, width)
			for offset in NEI4:
				var nx := tile.x + offset.x
				var ny := tile.y + offset.y
				if nx < 0 or nx >= width or ny < 0 or ny >= height:
					continue
				var nindex := TileGrid.flat_index(nx, ny, width)
				if visited.has(nindex) or map[nindex] != TILE_ROCK:
					continue
				visited[nindex] = true
				component.append(nindex)
		if component.size() >= min_size:
			for index in component:
				qualifying[index] = true
	return qualifying

## Row-major footprint of a rect candidate (tiers 1/2).
static func _rect_tiles(anchor_x: int, anchor_y: int, clearing_width: int, clearing_height: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for y in range(anchor_y, anchor_y + clearing_height):
		for x in range(anchor_x, anchor_x + clearing_width):
			tiles.append(Vector2i(x, y))
	return tiles

## Distinct bushes reachable within `limit` from EVERY footprint tile: the shuffle may put a
## colonist anywhere in it. A cheap multi-source BFS finds candidates, then one bounded BFS per
## bush confirms the worst-case tile.
static func _count_reachable_food_sources(map: Array[String], width: int, height: int, footprint: Array[Vector2i], bush_lookup: Dictionary, limit: int) -> int:
	if limit < 0 or footprint.is_empty():
		return 0
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = []
	for pos in footprint:
		var index := TileGrid.flat_index(pos.x, pos.y, width)
		if not visited.has(index):
			visited[index] = 0
			queue.append(pos)
	var candidate_bushes: Dictionary = {}
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var dist: int = visited[TileGrid.flat_index(current.x, current.y, width)]
		var next_dist := dist + 1
		if next_dist > limit:
			continue
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nindex := TileGrid.flat_index(nx, ny, width)
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
		footprint_lookup[TileGrid.flat_index(pos.x, pos.y, width)] = true

	var confirmed := 0
	for bush_index in candidate_bushes.keys():
		var bush := TileGrid.flat_coord(int(bush_index), width)
		if _reaches_every_tile(map, width, height, bush, footprint_lookup, bush_lookup, limit):
			confirmed += 1
	return confirmed

## True when a bounded BFS from `bush` reaches every target; other bushes block like objects, so
## a route cannot cut through them.
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
		var nindex := TileGrid.flat_index(nx, ny, width)
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
		var dist: int = visited[TileGrid.flat_index(current.x, current.y, width)]
		var next_dist := dist + 1
		if next_dist > limit:
			continue
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nindex := TileGrid.flat_index(nx, ny, width)
			if visited.has(nindex) or map[nindex] != TILE_SOIL or bush_lookup.has(nindex):
				continue
			visited[nindex] = next_dist
			if targets.has(nindex):
				remaining -= 1
				if remaining <= 0:
					return true
			queue.append(Vector2i(nx, ny))
	return remaining <= 0

## Bounded deterministic spawn search in four tiers, each run only if the previous found nothing:
## 1. random tries near the river, fully compliant only (step limits, outcrop under the tree
##    limit, and colonist_count distinct reachable bushes);
## 2. exhaustive row-major scan, else the least-over-budget fully reachable anchor;
## 3. best connected soil component (_repair_land_clearing);
## 4. expanding-ring soil search from spawn_area_x/y (may return fewer tiles).
## Distance fields expand over soil only, so resources are on the same shore. Water is never
## overwritten. "fallback" reports any tier past the first.
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
		bush_lookup[TileGrid.flat_index(pos.x, pos.y, width)] = true

	var water_dist := _distance_field(map, width, height, func(x, y): return map[TileGrid.flat_index(x, y, width)] == TILE_WATER, bush_lookup)
	var tree_dist := _distance_field(map, width, height, func(x, y): return map[TileGrid.flat_index(x, y, width)] == TILE_TREE, bush_lookup)
	var food_dist := _distance_field(map, width, height, func(x, y): return bush_lookup.has(TileGrid.flat_index(x, y, width)), bush_lookup)
	# Outcrops share spawn_tree_step_limit; only qualifying (min-size) outcrops count.
	var outcrop_min_size := maxi(1, int(mapgen.get("outcrop_min_size", DEFAULT_OUTCROP_MIN_SIZE)))
	var qualifying_outcrop_tiles := _qualifying_outcrop_tiles(map, width, height, outcrop_min_size)
	var outcrop_dist := _distance_field(map, width, height, func(x, y): return qualifying_outcrop_tiles.has(TileGrid.flat_index(x, y, width)), bush_lookup)
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
		# Distinct-bush count only after the cheap distance checks pass.
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
		# Never overwrites water, whatever tier chose the anchor.
		for y in range(clearing_y, clearing_y + clearing_height):
			for x in range(clearing_x, clearing_x + clearing_width):
				var index := TileGrid.flat_index(x, y, width)
				if map[index] != TILE_WATER:
					map[index] = TILE_FLOOR
				if map[TileGrid.flat_index(x, y, width)] == TILE_FLOOR:
					land_tiles.append(Vector2i(x, y))
	else:
		var reserved: Array[Vector2i] = repaired.get("land_tiles", [])
		for pos in reserved:
			map[TileGrid.flat_index(pos.x, pos.y, width)] = TILE_FLOOR
			land_tiles.append(pos)
		# A scattered selection, not a rectangle: report a 1x1 at the first floor tile.
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

	# Drop bushes inside the clearing; WorldSeeding places objects from the returned list.
	var land_lookup: Dictionary = {}
	for pos in land_tiles:
		land_lookup[TileGrid.flat_index(pos.x, pos.y, width)] = true
	var remaining_berry_bush_tiles: Array[Vector2i] = []
	for pos in berry_bush_tiles:
		if not land_lookup.has(TileGrid.flat_index(pos.x, pos.y, width)):
			remaining_berry_bush_tiles.append(pos)

	_shuffle_positions(random, land_tiles)
	var colonist_positions: Array[Vector2i] = land_tiles.slice(0, mini(colonist_count, land_tiles.size()))
	# Leftover reserved tiles are safe spots for new_game_setup.gd's starting tools and beds.
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

## Tier 2: every anchor, row-major. Returns the first fully compliant one, else the reachable
## anchor with the least summed overage (including any food-source deficit); never relaxes
## reachability. {} when no all-soil, bush-free, reachable footprint exists.
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

## Extra tiles a repaired clearing reserves for starting tools and beds.
const REPAIR_RESERVE_CELLS := 8

## Tier 3: connected soil components, preferring fully compliant, then least-over-budget
## reachable, then the first big enough. {} when none holds colonist_count cells.
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
			var index := TileGrid.flat_index(pos.x, pos.y, width)
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

## Row-major discovery, each component in BFS order: deterministic, bounded by width*height.
static func _land_components(map: Array[String], width: int, height: int, bush_lookup: Dictionary) -> Array:
	var visited: Dictionary = {}
	var components: Array = []
	for y in height:
		for x in width:
			var index := TileGrid.flat_index(x, y, width)
			if map[index] != TILE_SOIL or bush_lookup.has(index) or visited.has(index):
				continue
			var component: Array[Vector2i] = []
			var queue: Array[int] = [index]
			visited[index] = true
			var head := 0
			while head < queue.size():
				var current: int = queue[head]
				head += 1
				var tile := TileGrid.flat_coord(current, width)
				component.append(tile)
				for offset in NEI4:
					var nx := tile.x + offset.x
					var ny := tile.y + offset.y
					if nx < 0 or nx >= width or ny < 0 or ny >= height:
						continue
					var nindex := TileGrid.flat_index(nx, ny, width)
					if visited.has(nindex) or map[nindex] != TILE_SOIL or bush_lookup.has(nindex):
						continue
					visited[nindex] = true
					queue.append(nindex)
			components.append(component)
	return components

## Tier 4: rings outward, at most max(width, height); never touches non-soil terrain.
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
				if TileGrid.chebyshev(Vector2i(x, y), Vector2i(origin_x, origin_y)) != radius:
					continue
				var index := TileGrid.flat_index(x, y, width)
				if map[index] == TILE_SOIL and not bush_lookup.has(index):
					found.append(Vector2i(x, y))
					if found.size() >= max_needed:
						return found
	return found

## {} when off-map, non-soil, a bush tile, or (require_reachable) unreached; else the worst
## distance per resource over the whole footprint.
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
			var index := TileGrid.flat_index(x, y, width)
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

## Fisher-Yates.
static func _shuffle_positions(random: RandomNumberGenerator, positions: Array[Vector2i]) -> void:
	for i in range(positions.size() - 1, 0, -1):
		var j := random.randi_range(0, i)
		var temp := positions[i]
		positions[i] = positions[j]
		positions[j] = temp
