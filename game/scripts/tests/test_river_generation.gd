extends SceneTree

## Issue #300 acceptance:
## - a fixed suite of >=20 seeds reproduces its map for the same seed/version,
##   its river crosses two opposite edges, all its water is a single
##   4-connected component, with no isolated water tile;
## - width/connectivity checks explicitly detect an artificially broken
##   (multi-component) river and one connected only diagonally, proving the
##   check itself -- not just real generator output -- is rigorous;
## - for every seed, the three spawned colonists reach food, trees and a
##   water interaction tile within documented step bounds, measured as a real
##   4-connected route over passable tiles (never Chebyshev/Euclidean
##   distance), independently of WorldGenerator.place_spawn()'s own distance
##   fields;
## - the search never had to use its documented fallback across the suite;
## - for every seed, the colony has at least colonist_count DISTINCT reachable
##   berry bushes within the food step bound, independently re-counted here
##   (round 5 review): forage fully consumes its bush (one non-regrowing meal),
##   so a short route to the NEAREST bush is not "sufficient" when that same
##   bush is also the nearest one for the other two colonists.
## - for every seed (issue #351/#347), at least one compact rock outcrop
##   exists: an independent 4-connected TILE_ROCK component scan (mirroring
##   _water_components() below, never reusing WorldGenerator's own internal
##   state) filtered to components >= mapgen's outcrop_min_size, and at least
##   one tile of at least one such component is real-route-reachable (via
##   _bfs_route_distance()) from at least one spawned colonist within the tree
##   step bound (outcrop_dist reuses spawn_tree_step_limit, not a separate
##   mapgen field).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const SEEDS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 42, 1337, 20260919]
const WIDTH := 256
const HEIGHT := 256
const NEI4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const NECK_FLOOR := 4
const WATER_STEP_LIMIT := 40
const FOOD_STEP_LIMIT := 40
const TREE_STEP_LIMIT := 50

var _failed := false

func _init() -> void:
	_check_broken_river_detected()
	_check_diagonal_only_river_detected()
	_check_one_cell_neck_detected()
	_check_sharp_bend_neck_detected()
	_check_multi_run_cross_section_detected()
	_check_smooth_curve_not_flagged()
	_check_generation_does_not_perturb_simulation_stream()
	_check_only_one_colonist_reachable_detected()
	_check_bush_blocked_route_detected()
	_check_single_shared_bush_insufficient_food_detected()
	_check_bush_wall_detour_rejected()
	_check_zero_outcrop_placement_attempts_yields_seed_only()

	var mapgen: Dictionary = ContentRegistryType.new().document("mapgen")
	var max_width_tolerance := int(mapgen.get("river_max_width", 12)) + 2
	var outcrop_min_size := int(mapgen.get("outcrop_min_size", 6))
	for seed_value in SEEDS:
		_check_seed(seed_value, mapgen, max_width_tolerance, outcrop_min_size)

	if _failed:
		quit(1)
		return
	print("test_river_generation: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

## -------- connectivity primitive, exercised against synthetic AND real maps --------

## Every water tile's 4-connected component id, plus the total component
## count. Shared by the synthetic broken/diagonal fixtures below and by the
## real per-seed checks, so this exact primitive -- not a separately-trusted
## one -- is what the synthetic fixtures prove rigorous.
func _water_components(tiles: Array[String], width: int, height: int) -> int:
	var component_of: Dictionary = {}
	var component_count := 0
	for y in height:
		for x in width:
			var index := y * width + x
			if tiles[index] != "water" or component_of.has(index):
				continue
			component_count += 1
			var queue: Array[int] = [index]
			component_of[index] = component_count
			var head := 0
			while head < queue.size():
				var current: int = queue[head]
				head += 1
				var cx := current % width
				var cy := current / width
				for offset in NEI4:
					var nx := cx + offset.x
					var ny := cy + offset.y
					if nx < 0 or nx >= width or ny < 0 or ny >= height:
						continue
					var nindex := ny * width + nx
					if tiles[nindex] == "water" and not component_of.has(nindex):
						component_of[nindex] = component_count
						queue.append(nindex)
	return component_count

## Every 4-connected TILE_ROCK component (as raw tile indices), row-major
## discovery order -- mirrors _water_components() above but returns full
## membership (not just a count) so the caller can filter by size. An
## independent implementation, never reusing WorldGenerator's own internal
## _land_components()/blob-growth state (issue #351/#347).
func _rock_components(tiles: Array[String], width: int, height: int) -> Array:
	var visited: Dictionary = {}
	var components: Array = []
	for y in height:
		for x in width:
			var index := y * width + x
			if tiles[index] != "rock" or visited.has(index):
				continue
			var component: Array[int] = []
			var queue: Array[int] = [index]
			visited[index] = true
			var head := 0
			while head < queue.size():
				var current: int = queue[head]
				head += 1
				component.append(current)
				var cx := current % width
				var cy := current / width
				for offset in NEI4:
					var nx := cx + offset.x
					var ny := cy + offset.y
					if nx < 0 or nx >= width or ny < 0 or ny >= height:
						continue
					var nindex := ny * width + nx
					if tiles[nindex] == "rock" and not visited.has(nindex):
						visited[nindex] = true
						queue.append(nindex)
			components.append(component)
	return components

## Issue #351/#347 acceptance: at least one compact rock outcrop exists (a
## 4-connected TILE_ROCK component of at least outcrop_min_size tiles -- big
## enough to distinguish it from a rock_vein_count thin vein cross-section),
## and at least one tile of at least one such component is real-route-
## reachable (via _bfs_route_distance(), exactly like the water/food/tree
## checks above) from at least one spawned colonist within the tree step
## bound (outcrop_dist reuses spawn_tree_step_limit, not a separate mapgen
## field, mirroring place_spawn()'s own outcrop_dist/outcrop_limit).
func _check_rock_outcrops(world: WorldStateType, tiles: Array[String], width: int, height: int, seed_value: int, outcrop_min_size: int) -> void:
	var components := _rock_components(tiles, width, height)
	var qualifying_lookup: Dictionary = {}
	var qualifying_count := 0
	for component in components:
		if component.size() >= outcrop_min_size:
			qualifying_count += 1
			for index in component:
				qualifying_lookup[index] = true
	if qualifying_count == 0:
		_fail("seed %d must generate at least one rock outcrop component of >= %d tiles, found none among %d rock component(s)" % [seed_value, outcrop_min_size, components.size()])
		return

	var colonists := world.get_colonists()
	for colonist in colonists:
		var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var steps := _bfs_route_distance(world, start, func(x, y): return qualifying_lookup.has(y * width + x))
		if steps != -1 and steps <= TREE_STEP_LIMIT:
			return
	_fail("seed %d must have at least one rock outcrop tile real-route-reachable from a spawned colonist within %d steps" % [seed_value, TREE_STEP_LIMIT])

## Round 2 review (issue #351/#347): mapgen's schema permits
## outcrop_placement_attempts=0 (minimum 0, like hazard/tree placement
## attempts), meaning "spend no growth attempts, place only the seed tile" --
## _grow_rock_outcrop()'s own while-loop already honors that (0 < 0 is false),
## but _scatter_rock_outcrops() previously clamped the value to a floor of 1
## via maxi(1, ...), silently spending a growth attempt the configured budget
## never paid for. Calls WorldGeneratorType._scatter_rock_outcrops() directly
## (a private static helper, exercised the same way this file's own
## _count_reachable_food_sources() call above exercises another one) against
## an all-soil synthetic map with outcrop_max_size well above 1, so any
## growth beyond the seed tile would be visible as a component larger than 1.
func _check_zero_outcrop_placement_attempts_yields_seed_only() -> void:
	var width := 20
	var height := 20
	var map: Array[String] = []
	map.resize(width * height)
	map.fill("soil")
	var mapgen: Dictionary = (ContentRegistryType.new().document("mapgen") as Dictionary).duplicate(true)
	mapgen["outcrop_count"] = 3
	mapgen["outcrop_min_size"] = 5
	mapgen["outcrop_max_size"] = 10
	mapgen["outcrop_placement_attempts"] = 0
	var random := RandomNumberGenerator.new()
	random.seed = 99
	WorldGeneratorType._scatter_rock_outcrops(random, map, width, height, mapgen, 1.0)
	var components := _rock_components(map, width, height)
	if components.size() != 3:
		_fail("zero-outcrop-placement-attempts: outcrop_count=3 must still place 3 seed tiles even with a zero growth budget, found %d rock component(s)" % components.size())
		return
	for component in components:
		if component.size() != 1:
			_fail("zero-outcrop-placement-attempts: outcrop_placement_attempts=0 must place only the 1-tile seed, got a component of size %d -- a zero growth-attempt budget must never be silently bumped to 1" % component.size())

func _check_broken_river_detected() -> void:
	var width := 10
	var height := 10
	var tiles: Array[String] = []
	tiles.resize(width * height)
	tiles.fill("soil")
	# Two water blobs several tiles apart -- an artificially broken river.
	for x in range(0, 3):
		tiles[2 * width + x] = "water"
	for x in range(7, 10):
		tiles[7 * width + x] = "water"
	var count := _water_components(tiles, width, height)
	if count < 2:
		_fail("connectivity check must detect an artificially broken (multi-component) river, got %d component(s)" % count)

func _check_diagonal_only_river_detected() -> void:
	var width := 4
	var height := 4
	var tiles: Array[String] = []
	tiles.resize(width * height)
	tiles.fill("soil")
	# (1,1) and (2,2) touch only diagonally -- not 4-connected.
	tiles[1 * width + 1] = "water"
	tiles[2 * width + 2] = "water"
	var count := _water_components(tiles, width, height)
	if count != 2:
		_fail("connectivity check must treat a diagonal-only touch as two separate components, got %d (expected 2)" % count)

## -------- corridor-continuity primitive (round 1 review finding 5) --------
##
## The plain "longest run per cross-section" width check (below) cannot see a
## river that is 4-connected and every individual cross-section wide enough,
## yet whose ACTUAL walkable corridor across a curve is far narrower: two
## fully-valid 6-wide bands offset so they overlap by only one tile remain one
## component and pass every existing width assertion. This computes every
## disjoint water run per dominant-axis position (a real river must have
## exactly one) and the transversal overlap between each pair of adjacent
## positions' runs, so a neck or an over-sharp bend is caught directly instead
## of by proxy.

## Every disjoint [start, end] (inclusive, transversal-coordinate) water run
## at each dominant-axis position, in dominant order. A real single-band river
## has exactly one run per position; more than one is a braided/self-
## intersecting artifact this task's contract forbids ("one band ... never joined
## only by diagonals or points").
func _cross_section_runs(tiles: Array[String], width: int, height: int, horizontal: bool) -> Array:
	var dominant := width if horizontal else height
	var transversal := height if horizontal else width
	var all_runs: Array = []
	for pos in dominant:
		var runs: Array = []
		var run_start := -1
		for cross in transversal:
			var x := pos if horizontal else cross
			var y := cross if horizontal else pos
			var is_water := tiles[y * width + x] == "water"
			if is_water and run_start == -1:
				run_start = cross
			elif not is_water and run_start != -1:
				runs.append([run_start, cross - 1])
				run_start = -1
		if run_start != -1:
			runs.append([run_start, transversal - 1])
		all_runs.append(runs)
	return all_runs

## "" when every pair of adjacent dominant positions with exactly one run each
## overlaps by at least floor_width tiles (a genuine walkable corridor through
## every curve/bend); otherwise a message naming the violation. A position
## with zero or multiple runs is skipped here -- covered by the emptiness and
## multi-run checks respectively, so this only ever reports a true neck.
func _corridor_overlap_violation(runs: Array, floor_width: int) -> String:
	for i in range(runs.size() - 1):
		var current: Array = runs[i]
		var next: Array = runs[i + 1]
		if current.size() != 1 or next.size() != 1:
			continue
		var a: Array = current[0]
		var b: Array = next[0]
		var overlap: int = mini(a[1], b[1]) - maxi(a[0], b[0]) + 1
		if overlap < floor_width:
			return "river corridor overlap between adjacent cross-sections is %d tile(s) (below the %d-tile floor) -- a neck or an over-sharp bend" % [overlap, floor_width]
	return ""

## Two water bands, each individually 6-wide (comfortably above NECK_FLOOR)
## and 4-connected end to end, offset so consecutive columns overlap by
## exactly one tile -- a real generator could never produce this (drift per
## step is bounded far below the minimum width), but a broken width check
## that only measures the longest run per column would still pass it.
func _check_one_cell_neck_detected() -> void:
	var width := 10
	var height := 14
	var tiles: Array[String] = []
	tiles.resize(width * height)
	tiles.fill("soil")
	for x in range(0, 5):
		for y in range(2, 8):
			tiles[y * width + x] = "water"
	for x in range(5, 10):
		for y in range(7, 13):
			tiles[y * width + x] = "water"
	var runs := _cross_section_runs(tiles, width, height, true)
	var message := _corridor_overlap_violation(runs, NECK_FLOOR)
	if message.is_empty():
		_fail("connectivity/width check must detect a one-cell-neck river (adjacent cross-sections overlapping by only 1 tile)")

## A sharper single-step bend (the band's centre jumps so consecutive columns
## overlap by 2 tiles, still below NECK_FLOOR but not as extreme as the
## one-cell-neck fixture above) -- a distinct construction of the same
## underlying gap, exercising the same validator.
func _check_sharp_bend_neck_detected() -> void:
	var width := 10
	var height := 14
	var tiles: Array[String] = []
	tiles.resize(width * height)
	tiles.fill("soil")
	for x in range(0, 5):
		for y in range(2, 8):
			tiles[y * width + x] = "water"
	for x in range(5, 10):
		for y in range(6, 12):
			tiles[y * width + x] = "water"
	var runs := _cross_section_runs(tiles, width, height, true)
	var message := _corridor_overlap_violation(runs, NECK_FLOOR)
	if message.is_empty():
		_fail("connectivity/width check must detect a sharp-bend river (adjacent cross-sections overlapping by only 2 tiles)")

## A single column with two disjoint water runs -- a braided/self-
## intersecting artifact, not the single continuous band the contract requires.
func _check_multi_run_cross_section_detected() -> void:
	var width := 10
	var height := 10
	var tiles: Array[String] = []
	tiles.resize(width * height)
	tiles.fill("soil")
	tiles[1 * width + 5] = "water"
	tiles[2 * width + 5] = "water"
	tiles[6 * width + 5] = "water"
	tiles[7 * width + 5] = "water"
	var runs := _cross_section_runs(tiles, width, height, true)
	var found_multi := false
	for run_list in runs:
		if run_list.size() > 1:
			found_multi = true
			break
	if not found_multi:
		_fail("width check must detect a cross-section with multiple disjoint water runs (a braided/self-intersecting artifact)")

## Positive control (round 1 review rigor: prove no false positives): a smooth
## curve drifting by at most 1 tile every 2 columns, width held at 6, so every
## adjacent overlap is 5 or 6 tiles -- comfortably above NECK_FLOOR. Must pass
## both the multi-run and corridor-overlap checks untouched.
func _check_smooth_curve_not_flagged() -> void:
	var width := 12
	var height := 20
	var tiles: Array[String] = []
	tiles.resize(width * height)
	tiles.fill("soil")
	var center := 5
	for x in width:
		for y in range(center, center + 6):
			if y >= 0 and y < height:
				tiles[y * width + x] = "water"
		if x % 2 == 1:
			center += 1
	var runs := _cross_section_runs(tiles, width, height, true)
	for run_list in runs:
		if run_list.size() > 1:
			_fail("width check must not report multiple runs for a smooth single-band curve")
			return
	var message := _corridor_overlap_violation(runs, NECK_FLOOR)
	if not message.is_empty():
		_fail("width check must not flag a smooth, adequately-overlapping curve: %s" % message)

## -------- simulation-RNG isolation (round 1 review finding 2) --------

## _generate_map()/_spawn_colonists() must consume their own
## GEOGRAPHY_SEED_SALT/PLACEMENT_SEED_SALT-derived local RNGs, never
## WorldState's own _random -- the stream AssignmentType consumes for every
## scheduling decision for the rest of the game. Proven by comparing _random's
## own post-construction seed/state (get_simulation_random_state()) against a
## pristine same-seed RandomNumberGenerator that made zero calls: any amount
## of terrain/decoration/spawn-search randomness drawn during construction (a
## full real mapgen.json run: rock veins, hazards, groves, the river, berry
## bush groves, and the bounded spawn search) must leave _random exactly where
## a fresh RandomNumberGenerator.seed = <seed> would sit, proving generation
## can never perturb the simulation stream's continuation regardless of how
## much decoration a future mapgen.json tuning adds.
func _check_generation_does_not_perturb_simulation_stream() -> void:
	var probe_seed := 918273
	var world := WorldStateType.new(probe_seed, 10, 48, 48)
	var baseline := RandomNumberGenerator.new()
	baseline.seed = probe_seed
	var actual: Dictionary = world.get_simulation_random_state()
	if int(actual["seed"]) != baseline.seed or int(actual["state"]) != baseline.state:
		_fail("world generation and spawn placement must never advance WorldState's own simulation RNG stream (it must still read as freshly seeded right after construction)")

## -------- per-colonist accessibility rigor (round 1 review finding 4) --------

## Only colonist_0 sits near the manually placed water tile; colonist_1/2 sit
## far past WATER_STEP_LIMIT. A merged multi-source BFS (the round 1 bug)
## would report the minimum over all three and pass; checking each colonist
## independently must fail.
func _check_only_one_colonist_reachable_detected() -> void:
	var world := WorldStateType.new(3, 10, 100, 16)
	world._tiles.fill("soil")
	world._tiles[2 * 100 + 1] = "water"
	world._objects.clear()
	world._object_factions.clear()
	world._colonists = [
		ActorTableType.spawn("colonist", 0, 2, world._content, "colonist_0"),
		ActorTableType.spawn("colonist", 90, 2, world._content, "colonist_1"),
		ActorTableType.spawn("colonist", 95, 2, world._content, "colonist_2"),
	]
	for colonist in world.get_colonists():
		var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var steps := _bfs_route_distance(world, start, func(x, y): return world.get_tile(x, y) == "water")
		if steps == -1 or steps > WATER_STEP_LIMIT:
			return # correctly rejected: at least one colonist fails the bound
	_fail("accessibility check must fail when only one of three colonists can reach a resource within budget")

## A colonist fully boxed in by four impassable berry_bush objects (its every
## 4-connected neighbour) with water just outside the box. A route check that
## only inspects tile kind (soil/floor), never real passability(), would treat
## the bush cells as walkable soil and report a short false route; the fixed
## check must report the colonist unreachable.
func _check_bush_blocked_route_detected() -> void:
	var world := WorldStateType.new(4, 10, 20, 20)
	world._tiles.fill("soil")
	world._tiles[0 * 20 + 5] = "water"
	world._objects.clear()
	world._object_factions.clear()
	for pos in [Vector2i(4, 5), Vector2i(6, 5), Vector2i(5, 4), Vector2i(5, 6)]:
		var key := "%d_%d" % [pos.x, pos.y]
		world._objects[key] = "berry_bush"
		world._object_factions[key] = "colony"
	var steps := _bfs_route_distance(world, Vector2i(5, 5), func(x, y): return world.get_tile(x, y) == "water")
	if steps != -1:
		_fail("accessibility BFS must respect blocking objects (a berry bush must not be treated as passable soil), got distance %d instead of unreachable" % steps)

## Round 5 review: exactly one berry bush sits well within FOOD_STEP_LIMIT of
## all three colonists -- the same shape the pre-round-5 per-colonist
## nearest-distance check accepted as "each colonist has a reachable bush".
## Forage fully consumes its bush (one non-regrowing meal), so this single
## bush can feed only one of the three; _count_reachable_food_sources() (the
## same independent counter _check_seed() below applies to every real seed)
## must report 1, below colonists.size() (3), proving it actually detects this
## shape rather than merely counting "any bush reachable".
func _check_single_shared_bush_insufficient_food_detected() -> void:
	var world := WorldStateType.new(5, 10, 20, 20)
	world._tiles.fill("soil")
	world._objects.clear()
	world._object_factions.clear()
	world._colonists = [
		ActorTableType.spawn("colonist", 5, 5, world._content, "colonist_0"),
		ActorTableType.spawn("colonist", 6, 5, world._content, "colonist_1"),
		ActorTableType.spawn("colonist", 7, 5, world._content, "colonist_2"),
	]
	world._objects["10_5"] = "berry_bush"
	world._object_factions["10_5"] = "colony"
	var colonists := world.get_colonists()
	var food_sources := _count_reachable_food_sources(world, colonists, FOOD_STEP_LIMIT)
	if food_sources >= colonists.size():
		_fail("distinct-food-source check must detect a single shared bush as insufficient for %d colonists, counted %d" % [colonists.size(), food_sources])

## Round 6 review: the near footprint/colonist tile sits directly next to the
## target bush (distance 1, trivially "within budget"), but the far tile is
## separated from it by a 3-tile-thick wall of OTHER berry_bush objects that
## fully blocks the only direct line between them; the sole legal route is a
## long detour (verified below to total 30 hops, all soil, no rock). A
## reachability search that does not exclude bush-occupied tiles from its own
## traversal (both when seeding from the footprint/colonists AND when walking
## outward from the candidate bush) can cut straight through that wall as if
## it were plain soil and falsely certify the far tile at 14 hops, well under
## the 20-hop limit used here, when the real route needs 30. Both
## WorldGenerator's own production counter and this file's independent
## per-colonist counter must reject the target bush (and every wall-bush
## candidate) as unconfirmed, leaving 0 distinct reachable bushes -- below the
## 1 required for the single colonist pair used here.
func _check_bush_wall_detour_rejected() -> void:
	var width := 15
	var height := 11
	var limit := 20
	var near := Vector2i(1, 2)
	var far := Vector2i(14, 2)
	var target_bush := Vector2i(0, 2)
	var wall_bushes: Array[Vector2i] = [Vector2i(10, 2), Vector2i(11, 2), Vector2i(12, 2)]

	# -- production counter, called directly against a raw map/bush_lookup --
	var map: Array[String] = []
	map.resize(width * height)
	map.fill("rock")
	for x in range(0, 15):
		map[2 * width + x] = "soil" # the near/far corridor row, including the wall's own tiles
	for y in range(3, 11):
		map[y * width + 9] = "soil" # bypass: down from the near side
	for x in range(10, 14):
		map[10 * width + x] = "soil" # bypass: across the bottom
	for y in range(3, 10):
		map[y * width + 13] = "soil" # bypass: back up to the far side
	var bush_lookup: Dictionary = {}
	bush_lookup[target_bush.y * width + target_bush.x] = true
	for pos in wall_bushes:
		bush_lookup[pos.y * width + pos.x] = true
	var footprint: Array[Vector2i] = [near, far]
	var confirmed := WorldGeneratorType._count_reachable_food_sources(map, width, height, footprint, bush_lookup, limit)
	if confirmed >= 1:
		_fail("production _count_reachable_food_sources must reject a bush only reachable by cutting through a wall of other bushes, counted %d confirmed" % confirmed)

	# -- independent per-colonist counter, against the same shape via WorldState --
	var world := WorldStateType.new(6, 10, width, height)
	world._tiles = map.duplicate()
	world._objects.clear()
	world._object_factions.clear()
	world._objects["%d_%d" % [target_bush.x, target_bush.y]] = "berry_bush"
	world._object_factions["%d_%d" % [target_bush.x, target_bush.y]] = "colony"
	for pos in wall_bushes:
		world._objects["%d_%d" % [pos.x, pos.y]] = "berry_bush"
		world._object_factions["%d_%d" % [pos.x, pos.y]] = "colony"
	world._colonists = [
		ActorTableType.spawn("colonist", near.x, near.y, world._content, "colonist_0"),
		ActorTableType.spawn("colonist", far.x, far.y, world._content, "colonist_1"),
	]
	var colonists := world.get_colonists()
	var independent_count := _count_reachable_food_sources(world, colonists, limit)
	if independent_count >= 1:
		_fail("independent per-colonist food-source counter must reject a bush only reachable by cutting through a wall of other bushes, counted %d confirmed" % independent_count)

## -------- per-seed checks --------

func _check_seed(seed_value: int, mapgen: Dictionary, max_width_tolerance: int, outcrop_min_size: int) -> void:
	var first := WorldStateType.new(seed_value, 10, WIDTH, HEIGHT)
	var second := WorldStateType.new(seed_value, 10, WIDTH, HEIGHT)
	if first.get_tiles() != second.get_tiles():
		_fail("seed %d must reproduce identical terrain across two generations" % seed_value)
		return
	if first.get_generator_version() != WorldGeneratorType.GENERATOR_VERSION:
		_fail("seed %d must report WorldGenerator.GENERATOR_VERSION" % seed_value)

	var tiles := first.get_tiles()
	var width := first.get_map_width()
	var height := first.get_map_height()

	var crosses_horizontal := _column_has_water(tiles, width, height, 0) and _column_has_water(tiles, width, height, width - 1)
	var crosses_vertical := _row_has_water(tiles, width, height, 0) and _row_has_water(tiles, width, height, height - 1)
	if not crosses_horizontal and not crosses_vertical:
		_fail("seed %d river must cross two opposite map edges" % seed_value)
		return

	var component_count := _water_components(tiles, width, height)
	if component_count != 1:
		_fail("seed %d river water must be a single 4-connected component (no isolated water tile), found %d component(s)" % [seed_value, component_count])

	var runs := _cross_section_runs(tiles, width, height, crosses_horizontal)
	for run_list in runs:
		if run_list.size() > 1:
			_fail("seed %d river cross-section has %d disjoint water runs (must be one continuous band)" % [seed_value, run_list.size()])
			break
	var widths := _cross_section_widths(tiles, width, height, crosses_horizontal)
	for w in widths:
		if w < NECK_FLOOR:
			_fail("seed %d river has a %d-tile-wide neck (below the %d-tile floor, including curves)" % [seed_value, w, NECK_FLOOR])
			break
	for w in widths:
		if w > max_width_tolerance:
			_fail("seed %d river has a %d-tile width spike (self-intersection artifact?), tolerance is %d" % [seed_value, w, max_width_tolerance])
			break
	var overlap_message := _corridor_overlap_violation(runs, NECK_FLOOR)
	if not overlap_message.is_empty():
		_fail("seed %d %s" % [seed_value, overlap_message])

	_check_spawn_accessibility(first, seed_value)
	_check_rock_outcrops(first, tiles, width, height, seed_value, outcrop_min_size)

func _column_has_water(tiles: Array[String], width: int, height: int, x: int) -> bool:
	for y in height:
		if tiles[y * width + x] == "water":
			return true
	return false

func _row_has_water(tiles: Array[String], width: int, height: int, y: int) -> bool:
	for x in width:
		if tiles[y * width + x] == "water":
			return true
	return false

## The width contract (world_generator.gd's own doc comment on _carve_river()):
## at each dominant-axis position, width is the longest contiguous water run
## in the transversal cross-section there.
func _cross_section_widths(tiles: Array[String], width: int, height: int, horizontal: bool) -> Array[int]:
	var widths: Array[int] = []
	var dominant := width if horizontal else height
	var transversal := height if horizontal else width
	for pos in dominant:
		var run := 0
		var max_run := 0
		for cross in transversal:
			var x := pos if horizontal else cross
			var y := cross if horizontal else pos
			if tiles[y * width + x] == "water":
				run += 1
				max_run = maxi(max_run, run)
			else:
				run = 0
		widths.append(max_run)
	return widths

## Independent single-source BFS per colonist (round 1 review finding 4: a
## merged multi-source search reports the minimum over the three and can pass
## when two of three are actually unreachable/over-budget), from real
## passability() (never a raw tile-kind check -- a colonist's route can never
## cheat through a blocking object like a berry bush) to the nearest
## water/tree/berry_bush-adjacent tile -- a real route hop count, not
## geometric distance -- cross-checked against
## WorldState.get_spawn_clearing()'s own recorded search outcome.
func _check_spawn_accessibility(world: WorldStateType, seed_value: int) -> void:
	var colonists := world.get_colonists()
	if colonists.size() != 3:
		_fail("seed %d must spawn exactly 3 colonists, found %d" % [seed_value, colonists.size()])
		return

	for colonist in colonists:
		var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var colonist_id: String = String(colonist["id"])
		var water_steps := _bfs_route_distance(world, start, func(x, y): return world.get_tile(x, y) == "water")
		var tree_steps := _bfs_route_distance(world, start, func(x, y): return world.get_tile(x, y) == "tree")
		var food_steps := _bfs_route_distance(world, start, func(x, y): return world.get_object(x, y) == "berry_bush")

		if water_steps == -1 or water_steps > WATER_STEP_LIMIT:
			_fail("seed %d colonist %s water route distance is %d, must be <= %d" % [seed_value, colonist_id, water_steps, WATER_STEP_LIMIT])
		if food_steps == -1 or food_steps > FOOD_STEP_LIMIT:
			_fail("seed %d colonist %s food (berry_bush) route distance is %d, must be <= %d" % [seed_value, colonist_id, food_steps, FOOD_STEP_LIMIT])
		if tree_steps == -1 or tree_steps > TREE_STEP_LIMIT:
			_fail("seed %d colonist %s tree route distance is %d, must be <= %d" % [seed_value, colonist_id, tree_steps, TREE_STEP_LIMIT])

	var clearing := world.get_spawn_clearing()
	if bool(clearing.get("fallback", true)):
		_fail("seed %d spawn search used its documented fallback instead of finding a candidate within the step limits" % seed_value)

	# Round 5 review: distance-to-nearest-bush alone (checked per colonist
	# above) does not prove "sufficient" -- forage fully consumes its bush (one
	# non-regrowing meal), so the same single bush could be every colonist's
	# own nearest one. Independently re-count distinct reachable bushes (never
	# reusing WorldGenerator.place_spawn()'s own distance fields or its
	# internal food-source counter) and require at least one per colonist.
	var food_sources := _count_reachable_food_sources(world, colonists, FOOD_STEP_LIMIT)
	if food_sources < colonists.size():
		_fail("seed %d colony must have at least %d distinct reachable berry bushes (one non-regrowing meal each) within %d steps, found %d" % [seed_value, colonists.size(), FOOD_STEP_LIMIT, food_sources])

## Independent second implementation (never reusing WorldGenerator.place_spawn()'s
## own _count_reachable_food_sources()/_reaches_every_tile()) of the
## distinct-reachable-food-source count this task's spawn contract requires
## (round 5 review). Round 6 review: a merged multi-source BFS from all
## colonists at once only proves a bush is reachable from the UNION of their
## positions, which a single colonist standing far from that bush would still
## wrongly pass -- forage fully consumes its bush (one meal, no regrowth), so
## "sufficient" means every one of the `limit`-required distinct bushes must be
## independently reachable from EVERY spawned colonist's own real position,
## the same worst-case guarantee WorldGenerator's own counter claims. Runs one
## single-source BFS per colonist (each via real world.passability(), never a
## raw tile-kind check) and intersects their reachable-bush sets.
func _count_reachable_food_sources(world: WorldStateType, colonists: Array, limit: int) -> int:
	if colonists.is_empty():
		return 0
	var reachable_per_colonist: Array[Dictionary] = []
	for colonist in colonists:
		var start := Vector2i(int(colonist["x"]), int(colonist["y"]))
		reachable_per_colonist.append(_reachable_bushes_from(world, start, limit))
	var intersection: Dictionary = reachable_per_colonist[0].duplicate()
	for i in range(1, reachable_per_colonist.size()):
		var other: Dictionary = reachable_per_colonist[i]
		for key in intersection.keys().duplicate():
			if not other.has(key):
				intersection.erase(key)
	return intersection.size()

## Single-source BFS from `start` (real world.passability(), matching
## WorldGenerator._distance_field()'s own "walk to reach it, plus one
## interaction step" metric) collecting every DISTINCT berry_bush object index
## reached within `limit` hops.
func _reachable_bushes_from(world: WorldStateType, start: Vector2i, limit: int) -> Dictionary:
	var width := world.get_map_width()
	var height := world.get_map_height()
	var visited: Dictionary = {}
	visited[start.y * width + start.x] = 0
	var queue: Array[Vector2i] = [start]
	var found: Dictionary = {}
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var dist: int = visited[current.y * width + current.x]
		var next_dist := dist + 1
		if next_dist > limit:
			continue
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			if world.get_object(nx, ny) == "berry_bush":
				found[ny * width + nx] = true
				continue
			var nindex := ny * width + nx
			if visited.has(nindex) or not bool(world.passability(nx, ny)["passable"]):
				continue
			visited[nindex] = next_dist
			queue.append(Vector2i(nx, ny))
	return found

## Single-source BFS from `start`, expanding only through world.passability()
## (round 1 review finding 4: a raw tile-kind check treats every soil/floor
## cell as walkable even when a blocking object like a berry bush sits on it)
## to the nearest neighbour `is_target` accepts -- the walk to reach it, plus
## one interaction step onto/into the resource itself, matching
## WorldGenerator._distance_field()'s own metric (docs/decisions/020).
func _bfs_route_distance(world: WorldStateType, start: Vector2i, is_target: Callable) -> int:
	var width := world.get_map_width()
	var height := world.get_map_height()
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [start]
	visited[start.y * width + start.x] = 0
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		var distance: int = visited[current.y * width + current.x]
		for offset in NEI4:
			var nx := current.x + offset.x
			var ny := current.y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			if is_target.call(nx, ny):
				return distance + 1
			var nindex := ny * width + nx
			if not visited.has(nindex) and bool(world.passability(nx, ny)["passable"]):
				visited[nindex] = distance + 1
				queue.append(Vector2i(nx, ny))
	return -1
