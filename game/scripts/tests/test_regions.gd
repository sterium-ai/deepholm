extends SceneTree

const RegionMapType = preload("res://scripts/core/map/regions.gd")
const RouteType = preload("res://scripts/core/routing/route_search.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failed := false

func _init() -> void:
	_check_stability_across_unrelated_edit()
	_check_split_and_merge()
	_check_random_pairs_match_reachability()
	_check_same_region_blocked_and_out_of_bounds()
	_check_reachable_handles_work_targets()
	_check_footprint_object_invalidates_every_occupied_tile()
	if _failed:
		quit(1)
		return
	print("test_regions: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## A fully open 6x6 room starts as one region; an edit far from (0,0)/(1,1)
## must not change either tile's id or connectivity.
func _check_stability_across_unrelated_edit() -> void:
	var blocked: Dictionary = {}
	var passable := func(x: int, y: int) -> bool: return not blocked.has(Vector2i(x, y))
	var regions := RegionMapType.new(6, 6, passable)
	var before_a := regions.region_id(0, 0)
	var before_b := regions.region_id(1, 1)
	_expect(before_a != 0 and before_a == before_b, "an open room must start as a single region")
	blocked[Vector2i(5, 5)] = true
	regions.on_passability_changed(5, 5)
	_expect(regions.region_id(0, 0) == before_a, "an unrelated edit must not change a distant tile's region id")
	_expect(regions.same_region(Vector2i(0, 0), Vector2i(1, 1)), "an unrelated edit must not change distant tiles' connectivity")

## Two 3x3 rooms joined by one doorway tile: closing it splits the map into
## two distinct ids; reopening it merges them back into the lower/older id.
func _check_split_and_merge() -> void:
	var blocked: Dictionary = {}
	for y in 3:
		blocked[Vector2i(3, y)] = true
	var door := Vector2i(3, 1)
	blocked.erase(door)
	var passable := func(x: int, y: int) -> bool: return not blocked.has(Vector2i(x, y))
	var regions := RegionMapType.new(7, 3, passable)
	var left := Vector2i(0, 0)
	var right := Vector2i(6, 0)
	var original_id := regions.region_id(left.x, left.y)
	_expect(original_id != 0 and regions.same_region(left, right), "the doorway must start the two rooms as one region")
	blocked[door] = true
	regions.on_passability_changed(door.x, door.y)
	var left_id := regions.region_id(left.x, left.y)
	var right_id := regions.region_id(right.x, right.y)
	_expect(left_id != 0 and right_id != 0 and left_id != right_id,
		"closing the doorway must split the room into two distinct region ids")
	_expect(not regions.same_region(left, right), "closed doorway rooms must no longer be the same region")
	blocked.erase(door)
	regions.on_passability_changed(door.x, door.y)
	_expect(regions.same_region(left, right), "reopening the doorway must merge the rooms back into one region")
	_expect(regions.region_id(left.x, left.y) == original_id, "reopening must keep the lower/older region id")

## same_region() must agree with a direct (unbounded) RouteSearch reachability
## check on 100 random passable-tile pairs, across 3 different seeds.
func _check_random_pairs_match_reachability() -> void:
	for seed_value in [1, 2, 3]:
		var random := RandomNumberGenerator.new()
		random.seed = seed_value
		var width := 20
		var height := 20
		var blocked: Dictionary = {}
		var open_tiles: Array[Vector2i] = []
		for y in height:
			for x in width:
				var tile := Vector2i(x, y)
				if random.randf() < 0.3:
					blocked[tile] = true
				else:
					open_tiles.append(tile)
		var passable := func(x: int, y: int) -> bool: return not blocked.has(Vector2i(x, y))
		var regions := RegionMapType.new(width, height, passable)
		_expect(not open_tiles.is_empty(), "a random map needs at least one passable tile")
		for i in 100:
			var a: Vector2i = open_tiles[random.randi() % open_tiles.size()]
			var b: Vector2i = open_tiles[random.randi() % open_tiles.size()]
			var expected := _reachable(a, b, passable, width, height)
			_expect(regions.same_region(a, b) == expected,
				"same_region must agree with a direct route search for seed %d pair %s -> %s" % [seed_value, a, b])

func _reachable(start: Vector2i, target: Vector2i, passable: Callable, width: int, height: int) -> bool:
	var cost_fn := func(tile: Vector2i) -> bool: return passable.call(tile.x, tile.y)
	var route := RouteType.new(start, target, cost_fn, Vector2i.ZERO, Vector2i(width - 1, height - 1))
	while not route.is_terminal():
		route.resume()
	return route.get_status() == RouteType.STATUS_FOUND

## same_region() must be strict and symmetric: an impassable or out-of-bounds
## endpoint on either side is never "the same region" as anything, even a tile
## adjacent to open ground (regression for the open-edge false positive where
## an out-of-bounds b's own neighbour list happened to include a).
func _check_same_region_blocked_and_out_of_bounds() -> void:
	var blocked: Dictionary = {Vector2i(2, 2): true}
	var passable := func(x: int, y: int) -> bool: return not blocked.has(Vector2i(x, y))
	var regions := RegionMapType.new(6, 6, passable)
	var open_tile := Vector2i(0, 0)
	_expect(not regions.same_region(open_tile, Vector2i(-1, 0)),
		"an out-of-bounds destination adjacent to an open edge must not be 'the same region'")
	_expect(not regions.same_region(Vector2i(-1, 0), open_tile),
		"same_region must be symmetric for an out-of-bounds endpoint")
	_expect(not regions.same_region(open_tile, Vector2i(2, 2)),
		"a blocked destination must not be 'the same region' as an open tile")
	_expect(not regions.same_region(Vector2i(2, 2), open_tile),
		"same_region must be symmetric for a blocked endpoint")
	_expect(not regions.same_region(Vector2i(2, 2), Vector2i(2, 2)),
		"a blocked tile is never its own region")
	_expect(regions.same_region(open_tile, open_tile), "an open tile is trivially its own region")
	var random := RandomNumberGenerator.new()
	random.seed = 9
	var tiles: Array[Vector2i] = []
	for y in 6:
		for x in 6:
			tiles.append(Vector2i(x, y))
	for i in 40:
		var a: Vector2i = tiles[random.randi() % tiles.size()]
		var b: Vector2i = tiles[random.randi() % tiles.size()]
		_expect(regions.same_region(a, b) == regions.same_region(b, a),
			"same_region must be symmetric for %s <-> %s" % [a, b])

## reachable() is the scheduler-facing check: it must accept an impassable
## work target (a chop/forage/dig tile) reached via an adjacent passable tile
## in from's region, reject one fully walled in (no passable neighbour at
## all, so nobody could ever stand next to it), and reject an out-of-bounds
## target outright.
func _check_reachable_handles_work_targets() -> void:
	var blocked: Dictionary = {}
	var work_target := Vector2i(3, 3)
	blocked[work_target] = true
	var enclosed_target := Vector2i(5, 5)
	blocked[enclosed_target] = true
	for neighbour in [Vector2i(4, 5), Vector2i(6, 5), Vector2i(5, 4), Vector2i(5, 6)]:
		blocked[neighbour] = true
	var passable := func(x: int, y: int) -> bool:
		if x < 0 or y < 0 or x >= 7 or y >= 7:
			return false
		return not blocked.has(Vector2i(x, y))
	var regions := RegionMapType.new(7, 7, passable)
	var from := Vector2i(0, 0)
	_expect(regions.reachable(from, work_target),
		"an impassable work target reachable via an open neighbour must be reachable")
	_expect(not regions.reachable(from, enclosed_target),
		"a work target walled in on all four sides must not be reachable")
	_expect(not regions.reachable(from, Vector2i(-1, 0)), "an out-of-bounds target must never be reachable")
	_expect(regions.reachable(from, from), "a passable target in from's own region must be reachable")

## WorldState._set_object()'s own RegionMap.on_passability_changed()
## call must run for every tile of a placed footprint, not just its origin --
## otherwise the second tile's cached region_id would stay whatever it was
## before placement (this RegionMap only recomputes a tile explicitly told to
## via on_passability_changed()), silently diverging from what passability()
## now reports for it. Places content/objects.json's "test_footprint_crate"
## (footprint [2, 1], impassable) horizontally across two tiles that start
## passable/regioned, through a real WorldState (not a bare RegionMapType),
## and checks both tiles' region_id() dropped to 0 (impassable/no region).
func _check_footprint_object_invalidates_every_occupied_tile() -> void:
	var world := WorldStateType.new(400, 10)
	world._tiles[world._tile_index(2, 2)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(3, 2)] = WorldStateType.TILE_FLOOR
	var regions := world._get_regions()
	_expect(regions.region_id(2, 2) != 0 and regions.region_id(3, 2) != 0,
		"both setup tiles must start passable/regioned")
	world._set_object(2, 2, "test_footprint_crate", "colony", "horizontal")
	_expect(regions.region_id(2, 2) == 0, "the origin footprint tile's region cache must be invalidated to impassable")
	_expect(regions.region_id(3, 2) == 0, "the second footprint tile's region cache must also be invalidated to impassable")
