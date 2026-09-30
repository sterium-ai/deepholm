extends SceneTree

## The seed suite (test_river_generation.gd) only
## ever proves the fallback flag stayed false on real generated maps -- it
## never forces WorldGenerator.place_spawn()'s own repair/construct tiers to
## actually run. This calls place_spawn() directly (a pure static function,
## no WorldState needed) against small, deliberately hostile synthetic maps
## that make its fast rectangle tiers impossible, so the deterministic
## repair/construct tiers below them are the ones under test:
##
## - _check_water_and_bush_at_old_anchor(): mapgen's own spawn_area_x/y anchor
##   sits inside water and a berry bush, with the only usable land elsewhere.
## - _check_unreachable_resources_reported_honestly(): a perfectly good land
##   clearing exists, but the map has no water/tree/bush anywhere at all --
##   the rule that guaranteed resources do not count when unreachable must show
##   up as an explicit -1, never a silently accepted success.
## - _check_insufficient_land_cells_still_places_three(): the only connected
##   land component on the map is exactly colonist_count tiles, too small for
##   mapgen's own 6x6 clearing rectangle and too small to also reserve room
##   for starting tools/beds.
##
## Every fixture asserts the same invariants: exactly colonist_count colonist
## positions, all mutually reachable through the painted floor (one connected
## clearing, never split across a river or a gap), every returned land_tiles
## pool tile also connected and never water, and the map's own water tiles
## left byte-for-byte untouched (the river survives every tier, including the
## repair ones).

const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

const NEI4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const TILE_SOIL := "soil"
const TILE_ROCK := "rock"
const TILE_WATER := "water"
const TILE_FLOOR := "floor"
const TILE_TREE := "tree"
const TILE_HAZARD := "hazard"

var _failed := false

func _init() -> void:
	_check_water_and_bush_at_old_anchor()
	_check_unreachable_resources_reported_honestly()
	_check_insufficient_land_cells_still_places_three()
	_check_single_shared_bush_reported_insufficient()
	_check_isolated_rock_does_not_satisfy_outcrop_reachability()

	if _failed:
		quit(1)
		return
	print("test_spawn_fallback: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _base_mapgen() -> Dictionary:
	return (ContentRegistryType.new().document("mapgen") as Dictionary).duplicate(true)

## mapgen's documented last-resort anchor (spawn_area_x/y = 2,2) sits inside a
## river tile and a berry bush; the rest of a small 24x16 map is TILE_ROCK
## except one clean 8x6 soil pocket well away from that anchor, with its own
## reachable water/tree/bush right on its edge -- large enough, and resourced
## enough, to satisfy tier 1/2's own all-soil rectangle search directly,
## proving a hostile old anchor does not stall or crash the search (the
## repair tiers are exercised separately, by the two fixtures below, so this
## one isolates "the documented anchor itself is unusable").
func _check_water_and_bush_at_old_anchor() -> void:
	var width := 24
	var height := 16
	var map: Array[String] = []
	map.resize(width * height)
	map.fill(TILE_ROCK)
	for y in range(4, 10):
		for x in range(14, 22):
			map[y * width + x] = TILE_SOIL
	map[2 * width + 2] = TILE_WATER
	map[6 * width + 13] = TILE_WATER # adjacent to the pocket's own left edge
	map[5 * width + 22] = TILE_SOIL # a one-tile arm hosting the reachable bush
	map[7 * width + 22] = TILE_TREE # adjacent to the pocket's own right edge
	var water_tiles: Array[Vector2i] = [Vector2i(2, 2), Vector2i(13, 6)]
	var berry_bush_tiles: Array[Vector2i] = [Vector2i(3, 2), Vector2i(22, 5)]
	var mapgen := _base_mapgen()
	mapgen["spawn_area_x"] = 2
	mapgen["spawn_area_y"] = 2
	mapgen["spawn_area_width"] = 6
	mapgen["spawn_area_height"] = 6
	mapgen["spawn_water_step_limit"] = 30
	mapgen["spawn_food_step_limit"] = 30
	mapgen["spawn_tree_step_limit"] = 30
	var random := RandomNumberGenerator.new()
	random.seed = 1
	var placement := WorldGeneratorType.place_spawn(random, map, width, height, mapgen, water_tiles, berry_bush_tiles, 3)
	_expect_valid_placement(placement, map, width, height, water_tiles, "water-and-bush-at-old-anchor")
	var clearing: Dictionary = placement["clearing"]
	_expect(int(clearing["water_steps"]) != -1 and int(clearing["food_steps"]) != -1 and int(clearing["tree_steps"]) != -1,
		"water-and-bush-at-old-anchor: a resourced pocket elsewhere must be found reachable, not merely repaired with honest -1s")
	for pos: Vector2i in placement["colonist_positions"]:
		_expect(pos.x >= 14 and pos.x < 22 and pos.y >= 4 and pos.y < 10,
			"water-and-bush-at-old-anchor: colonist position %s must land in the real soil pocket, not near the hostile old anchor" % pos)
	_expect(map[2 * width + 2] == TILE_WATER, "water-and-bush-at-old-anchor: the old anchor's own water tile must survive untouched")

## A clean 3x3 soil clearing exists (satisfying colonist_count with room to
## spare), but the whole map has no water, no tree, and no berry bush at all
## -- every distance field is -1 everywhere. Tiers 1/2 (which require full
## reachability) must find nothing even though a full 6x6 all-soil rectangle
## genuinely exists (isolating "unreachable" from "not enough land cells",
## the separate fixture below); tier 3's repair must still place the three
## colonists on that land, but must report -1, never a fabricated in-budget
## distance, for a resource that plainly cannot be reached.
func _check_unreachable_resources_reported_honestly() -> void:
	var width := 16
	var height := 16
	var map: Array[String] = []
	map.resize(width * height)
	map.fill(TILE_ROCK)
	for y in range(4, 10):
		for x in range(4, 10):
			map[y * width + x] = TILE_SOIL
	var water_tiles: Array[Vector2i] = []
	var berry_bush_tiles: Array[Vector2i] = []
	var mapgen := _base_mapgen()
	mapgen["spawn_area_width"] = 6
	mapgen["spawn_area_height"] = 6
	var random := RandomNumberGenerator.new()
	random.seed = 2
	var placement := WorldGeneratorType.place_spawn(random, map, width, height, mapgen, water_tiles, berry_bush_tiles, 3)
	_expect_valid_placement(placement, map, width, height, water_tiles, "unreachable-resources")
	var clearing: Dictionary = placement["clearing"]
	_expect(bool(clearing["fallback"]), "unreachable-resources: a map with no water/tree/bush anywhere must report fallback=true")
	_expect(int(clearing["water_steps"]) == -1, "unreachable-resources: water_steps must honestly report -1 (unreachable), got %d" % int(clearing["water_steps"]))
	_expect(int(clearing["food_steps"]) == -1, "unreachable-resources: food_steps must honestly report -1 (unreachable), got %d" % int(clearing["food_steps"]))
	_expect(int(clearing["tree_steps"]) == -1, "unreachable-resources: tree_steps must honestly report -1 (unreachable), got %d" % int(clearing["tree_steps"]))

## The only connected land component on the whole map is exactly 3 soil
## tiles (a short line) -- too small for mapgen's own 6x6 rectangle and too
## small to also reserve extra room for starting tools/beds. Water, a tree,
## and a bush all sit right next to it (within budget) so this isolates "not
## enough land cells" from "resources unreachable" (covered separately
## above): place_spawn must still place all 3 colonists on that exact
## component, with in-budget resource distances.
func _check_insufficient_land_cells_still_places_three() -> void:
	var width := 12
	var height := 12
	var map: Array[String] = []
	map.resize(width * height)
	map.fill(TILE_ROCK)
	map[5 * width + 4] = TILE_SOIL
	map[5 * width + 5] = TILE_SOIL
	map[5 * width + 6] = TILE_SOIL
	map[5 * width + 7] = TILE_WATER
	map[4 * width + 4] = TILE_TREE
	map[4 * width + 5] = TILE_SOIL # hosts the reachable bush, adjacent to the component
	var water_tiles: Array[Vector2i] = [Vector2i(7, 5)]
	var berry_bush_tiles: Array[Vector2i] = [Vector2i(5, 4)]
	var mapgen := _base_mapgen()
	mapgen["spawn_area_width"] = 6
	mapgen["spawn_area_height"] = 6
	mapgen["spawn_water_step_limit"] = 999
	mapgen["spawn_food_step_limit"] = 999
	mapgen["spawn_tree_step_limit"] = 999
	var random := RandomNumberGenerator.new()
	random.seed = 3
	var placement := WorldGeneratorType.place_spawn(random, map, width, height, mapgen, water_tiles, berry_bush_tiles, 3)
	_expect_valid_placement(placement, map, width, height, water_tiles, "insufficient-land-cells")
	var colonist_positions: Array = placement["colonist_positions"]
	var expected := [Vector2i(4, 5), Vector2i(5, 5), Vector2i(6, 5)]
	for pos: Vector2i in colonist_positions:
		_expect(expected.has(pos), "insufficient-land-cells: colonist position %s must be one of the only 3 connected land tiles" % pos)
	_expect(map[7 + 5 * width] == TILE_WATER, "insufficient-land-cells: the adjacent water tile must survive untouched")
	var clearing: Dictionary = placement["clearing"]
	_expect(int(clearing["water_steps"]) != -1 and int(clearing["food_steps"]) != -1 and int(clearing["tree_steps"]) != -1,
		"insufficient-land-cells: resources adjacent to the tiny component must still be reported reachable (resource bounds honoured even under repair)")

## A single reachable berry bush is close enough to satisfy
## the nearest-bush distance check (food_steps) for every candidate anchor on
## this map, exactly the shape an earlier nearest-distance-only check accepted as "sufficient"
## -- but forage yields exactly one non-regrowing meal per bush (world_state.gd's
## _spawn_berries_item()), so one bush can never feed three colonists. A large
## clean soil rectangle (plenty of fully-compliant, non-food-limited anchors)
## surrounds the single bush, so the only reason no anchor is fully compliant
## is the distinct-food-source floor (colonist_count == 3), not distance,
## reachability, or land size.
func _check_single_shared_bush_reported_insufficient() -> void:
	var width := 20
	var height := 14
	var map: Array[String] = []
	map.resize(width * height)
	map.fill(TILE_ROCK)
	for y in range(2, 12):
		for x in range(4, 16):
			map[y * width + x] = TILE_SOIL
	map[3 * width + 5] = TILE_WATER
	map[3 * width + 10] = TILE_TREE
	map[9 * width + 10] = TILE_SOIL # hosts the one and only bush
	var water_tiles: Array[Vector2i] = [Vector2i(5, 3)]
	var berry_bush_tiles: Array[Vector2i] = [Vector2i(10, 9)]
	var mapgen := _base_mapgen()
	mapgen["spawn_area_width"] = 6
	mapgen["spawn_area_height"] = 6
	mapgen["spawn_water_step_limit"] = 30
	mapgen["spawn_food_step_limit"] = 30
	mapgen["spawn_tree_step_limit"] = 30
	var random := RandomNumberGenerator.new()
	random.seed = 4
	var placement := WorldGeneratorType.place_spawn(random, map, width, height, mapgen, water_tiles, berry_bush_tiles, 3)
	_expect_valid_placement(placement, map, width, height, water_tiles, "single-shared-bush")
	var clearing: Dictionary = placement["clearing"]
	_expect(int(clearing.get("required_food_sources", -1)) == 3,
		"single-shared-bush: required_food_sources must equal colonist_count (3), got %d" % int(clearing.get("required_food_sources", -1)))
	_expect(int(clearing.get("food_sources", -1)) == 1,
		"single-shared-bush: only one bush exists anywhere on this map, food_sources must honestly report 1, got %d" % int(clearing.get("food_sources", -1)))
	_expect(int(clearing["food_steps"]) <= int(mapgen["spawn_food_step_limit"]),
		"single-shared-bush: nearest-bush route distance must still read as in-budget (%d <= %d) -- proving a nearest-distance-only check would have wrongly accepted this map as sufficient" % [int(clearing["food_steps"]), int(mapgen["spawn_food_step_limit"])])
	_expect(bool(clearing["fallback"]),
		"single-shared-bush: with only one bush existing globally, no anchor can ever satisfy 3 distinct food sources, so the search must honestly report fallback=true instead of silently accepting the single-bush spot as fully compliant")

## An earlier version of the fixture below used only a
## single berry bush, so FOOD_SOURCES_PER_COLONIST * colonist_count (3
## distinct bushes required, see _check_single_shared_bush_reported_insufficient
## above) forced fallback=true all by itself -- both the pre-fix raw-TILE_ROCK
## distance (9) and the fixed qualified-component distance (21) exceeded the
## 6-step limit, so the fixture's fallback/outcrop_steps assertions passed
## unchanged whichever way outcrop_dist was computed and never actually
## exercised the qualification. This map instead gives every anchor near the
## resource cluster water, a tree, and three distinct reachable bushes all
## comfortably in budget (so food-source count can never be the reason for
## fallback), an isolated 1-tile TILE_ROCK stub (below outcrop_min_size)
## sitting close enough to the cluster to be in-budget under raw targeting,
## and a real qualifying 6-tile blob reachable only through a single-soil-
## tile-wide corridor far to the east (so no clearing_width x clearing_height
## rectangle can ever land in the corridor or the blob's own pocket -- the
## cluster is the only place a candidate clearing can exist at all). An
## independent, non-qualifying BFS (_raw_rock_distance_field below,
## deliberately mirroring _distance_field()'s shape but targeting every
## TILE_ROCK tile unfiltered by component size, exactly the pre-fix behavior)
## proves the regression directly: evaluated over the clearing place_spawn()
## actually returns, the raw distance to the isolated stub is in budget (so a
## raw-targeting implementation would have accepted this very clearing as
## fully compliant, fallback=false) while the real outcrop_steps this test
## reads back from place_spawn() is not (so the fix must keep rejecting it,
## fallback=true) -- demonstrating the regression fails under raw targeting
## and passes under qualified-component targeting on the same fixture.
func _check_isolated_rock_does_not_satisfy_outcrop_reachability() -> void:
	var width := 40
	var height := 10
	var map: Array[String] = []
	map.resize(width * height)
	map.fill(TILE_HAZARD) # impassable filler, deliberately not TILE_ROCK -- background rock would itself form one giant qualifying component adjacent to the whole map, swamping the two deliberately-placed rock features below
	for y in range(3, 8):
		for x in range(4, 12):
			map[y * width + x] = TILE_SOIL # compact cluster island -- (6,4)/4x3 is its only obstacle-free clearing rectangle, so the chosen anchor is deterministic
	for x in range(12, 34):
		map[5 * width + x] = TILE_SOIL # single-soil-tile-wide corridor, too thin for any clearing rectangle
	for y in range(3, 8):
		for x in range(34, 40):
			map[y * width + x] = TILE_SOIL
	for y in range(4, 6):
		for x in range(36, 39):
			map[y * width + x] = TILE_ROCK # real 6-tile qualifying outcrop, reachable only via the corridor
	map[5 * width + 5] = TILE_WATER
	map[5 * width + 10] = TILE_TREE
	map[3 * width + 7] = TILE_SOIL # hosts bush 1
	map[7 * width + 7] = TILE_SOIL # hosts bush 2
	map[7 * width + 6] = TILE_SOIL # hosts bush 3
	map[4 * width + 11] = TILE_ROCK # isolated 1-tile stub, below outcrop_min_size, close to the cluster
	var water_tiles: Array[Vector2i] = [Vector2i(5, 5)]
	var berry_bush_tiles: Array[Vector2i] = [Vector2i(7, 3), Vector2i(7, 7), Vector2i(6, 7)]
	var mapgen := _base_mapgen()
	mapgen["spawn_area_width"] = 4
	mapgen["spawn_area_height"] = 3
	mapgen["spawn_water_step_limit"] = 8
	mapgen["spawn_food_step_limit"] = 8
	mapgen["spawn_tree_step_limit"] = 8
	mapgen["outcrop_min_size"] = 4
	var random := RandomNumberGenerator.new()
	random.seed = 5
	var placement := WorldGeneratorType.place_spawn(random, map, width, height, mapgen, water_tiles, berry_bush_tiles, 3)
	_expect_valid_placement(placement, map, width, height, water_tiles, "isolated-rock-vs-outcrop")
	var clearing: Dictionary = placement["clearing"]
	var outcrop_limit := int(mapgen["spawn_tree_step_limit"])
	_expect(int(clearing.get("water_steps", -1)) != -1 and int(clearing.get("water_steps", 999)) <= outcrop_limit,
		"isolated-rock-vs-outcrop: water must be in-budget at the chosen anchor so fallback can only be caused by outcrop reachability, got water_steps=%d" % int(clearing.get("water_steps", -1)))
	_expect(int(clearing.get("tree_steps", -1)) != -1 and int(clearing.get("tree_steps", 999)) <= outcrop_limit,
		"isolated-rock-vs-outcrop: tree must be in-budget at the chosen anchor so fallback can only be caused by outcrop reachability, got tree_steps=%d" % int(clearing.get("tree_steps", -1)))
	_expect(int(clearing.get("food_sources", -1)) >= int(clearing.get("required_food_sources", 3)),
		"isolated-rock-vs-outcrop: three distinct bushes are all in-budget, so the required food-source floor must be met independent of outcrop reachability, got %d/%d" % [int(clearing.get("food_sources", -1)), int(clearing.get("required_food_sources", 3))])
	# The regression check itself: an independent, non-qualifying BFS
	# (mirroring the pre-fix behavior) evaluated over the same clearing
	# footprint place_spawn() actually returned.
	var raw_dist := _raw_rock_distance_field(map, width, height)
	var raw_worst := _worst_over_footprint(raw_dist, width, int(clearing["x"]), int(clearing["y"]), int(clearing["width"]), int(clearing["height"]))
	_expect(raw_worst != -1 and raw_worst <= outcrop_limit,
		"isolated-rock-vs-outcrop: fixture must put the isolated stub in-budget of the chosen clearing under raw (unqualified) TILE_ROCK targeting, got raw_worst=%d (limit %d) -- otherwise this fixture no longer demonstrates the regression" % [raw_worst, outcrop_limit])
	_expect(int(clearing["x"]) == 6 and int(clearing["y"]) == 4 and int(clearing["width"]) == 4 and int(clearing["height"]) == 3,
		"isolated-rock-vs-outcrop: the cluster island's only obstacle-free clearing rectangle is (6,4)/4x3, got (%d,%d)/%dx%d" % [int(clearing["x"]), int(clearing["y"]), int(clearing["width"]), int(clearing["height"])])
	_expect(int(clearing.get("outcrop_steps", -1)) == 33,
		"isolated-rock-vs-outcrop: the real (qualified-component) outcrop_steps must equal the independently-BFS'd route distance (33) to the real qualifying blob through the corridor, not the nearby undersized rock stub's in-budget raw distance of %d, got %d" % [raw_worst, int(clearing.get("outcrop_steps", -1))])
	_expect(bool(clearing["fallback"]),
		"isolated-rock-vs-outcrop: a raw-targeting implementation would have accepted this exact clearing as fully compliant (fallback=false) since the isolated stub is in budget -- the qualified-component fix must still report fallback=true")
	_expect(map[4 * width + 11] == TILE_ROCK, "isolated-rock-vs-outcrop: the isolated rock stub must survive untouched")

## Shared invariants every forced-fallback fixture above must satisfy:
## exactly 3 colonists, all mutually reachable through the painted floor (one
## connected clearing -- "same-bank connectivity"), every reserved land_tiles
## pool entry also connected and safe for a starting tool/bed ("tool
## accessibility"), and every one of the map's own original water tiles still
## water afterward (the river is never bulldozed by any tier).
func _expect_valid_placement(placement: Dictionary, map: Array[String], width: int, height: int, water_tiles: Array[Vector2i], label: String) -> void:
	var colonist_positions: Array = placement["colonist_positions"]
	_expect(colonist_positions.size() == 3, "%s: must place exactly 3 colonists, got %d" % [label, colonist_positions.size()])
	for pos: Vector2i in colonist_positions:
		_expect(map[pos.y * width + pos.x] == TILE_FLOOR, "%s: colonist position %s must be real floor, not water/rock/hazard" % [label, pos])
	var clearing: Dictionary = placement["clearing"]
	var land_tiles: Array = clearing.get("land_tiles", [])
	for pos: Vector2i in land_tiles:
		_expect(map[pos.y * width + pos.x] == TILE_FLOOR, "%s: reserved tool/bed tile %s must be real floor, not water" % [label, pos])
	if colonist_positions.size() > 1:
		var component := _flood_fill(map, width, height, colonist_positions[0])
		for pos: Vector2i in colonist_positions:
			_expect(component.has(pos.y * width + pos.x), "%s: colonist position %s must be in the same connected land clearing as the others (same-bank connectivity)" % [label, pos])
		for pos: Vector2i in land_tiles:
			_expect(component.has(pos.y * width + pos.x), "%s: reserved tool/bed tile %s must connect to the colonists' own clearing (tool accessibility)" % [label, pos])
	for pos: Vector2i in water_tiles:
		_expect(map[pos.y * width + pos.x] == TILE_WATER, "%s: original water tile %s must survive untouched by every fallback tier" % [label, pos])

func _flood_fill(map: Array[String], width: int, height: int, start: Vector2i) -> Dictionary:
	var visited: Dictionary = {}
	var start_index := start.y * width + start.x
	visited[start_index] = true
	var queue: Array[int] = [start_index]
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
			if visited.has(nindex) or map[nindex] != TILE_FLOOR:
				continue
			visited[nindex] = true
			queue.append(nindex)
	return visited

## Independent regression probe for _check_isolated_rock_does_not_satisfy_outcrop_reachability()
## above: deliberately mirrors world_generator.gd's own _distance_field() BFS
## shape (walk over TILE_SOIL/TILE_FLOOR, dist=1 at the first ring adjacent to
## a target, breadth-first outward) but targets every TILE_ROCK tile
## unfiltered by component size -- exactly the pre-fix behavior an earlier
## version of this fixture failed to exercise. Never calls into
## WorldGenerator; this is a separate reimplementation, same as
## test_river_generation.gd's own _water_components()/_bfs_route_distance().
func _raw_rock_distance_field(map: Array[String], width: int, height: int) -> PackedInt32Array:
	var size := width * height
	var dist := PackedInt32Array()
	dist.resize(size)
	for i in size:
		dist[i] = -1
	var queue: Array[int] = []
	for y in height:
		for x in width:
			var index := y * width + x
			if map[index] != TILE_SOIL and map[index] != TILE_FLOOR:
				continue
			for offset in NEI4:
				var nx := x + offset.x
				var ny := y + offset.y
				if nx < 0 or nx >= width or ny < 0 or ny >= height:
					continue
				if map[ny * width + nx] == TILE_ROCK:
					dist[index] = 1
					queue.append(index)
					break
	var head := 0
	while head < queue.size():
		var current: int = queue[head]
		head += 1
		var next_distance: int = dist[current] + 1
		var cx := current % width
		var cy := current / width
		for offset in NEI4:
			var nx := cx + offset.x
			var ny := cy + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nindex := ny * width + nx
			if dist[nindex] != -1:
				continue
			if map[nindex] != TILE_SOIL and map[nindex] != TILE_FLOOR:
				continue
			dist[nindex] = next_distance
			queue.append(nindex)
	return dist

## Worst (max) value of a _distance_field()-shaped array over a rectangular
## footprint, exactly how _evaluate_clearing() itself scores a candidate --
## -1 (unreached) counts as worst-case, reported as -1.
func _worst_over_footprint(dist: PackedInt32Array, width: int, anchor_x: int, anchor_y: int, footprint_width: int, footprint_height: int) -> int:
	var worst := 0
	for y in range(anchor_y, anchor_y + footprint_height):
		for x in range(anchor_x, anchor_x + footprint_width):
			var value: int = dist[y * width + x]
			if value == -1:
				return -1
			worst = maxi(worst, value)
	return worst
