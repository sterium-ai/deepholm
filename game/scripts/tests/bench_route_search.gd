extends SceneTree

## A0 benchmark: route search and region cost on 256x256 maps.
##   1. RouteSearch (game/scripts/core/routing/route_search.gd) on the
##      generated seed-42 map with WorldState's real cost callable
##      (Passability.is_passable -> passability()), from colonist_0 to passable tiles at
##      growing path distance: wall time, frontier expansions, and resume()
##      calls (one call = one tick's STEP_BUDGET of 64 expansions).
##   2. The same searches on an all-open 256x256 grid with a bare array cost
##      callable, to separate the algorithm's own cost from passability()'s.
##   3. An unreachable target (a walled-in cell) on the open grid: the search
##      must exhaust the whole region before it can say so.
##   4. RegionMap (game/scripts/core/map/regions.gd): full build on the
##      generated map (what tick 1 pays) and on the open grid, plus one
##      on_passability_changed() that blocks a tile in a large region.
##
## Evidence, not a gate: always exits 0. Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_route_search.gd

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const MeasuredRouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const RegionMapType = preload("res://scripts/core/map/regions.gd")

const SEED := 42
const SIZE := 256
const DISTANCES := [8, 32, 64, 128, 256, 384]

var _open_grid := PackedByteArray()

func _init() -> void:
	print(BenchCommon.header("bench_route_search"))
	var world := WorldStateType.new(SEED, 10, SIZE, SIZE)
	var start := Vector2i(int(TestAccess.colonists(world)[0]["x"]), int(TestAccess.colonists(world)[0]["y"]))
	_bench_generated_routes(world, start)
	_open_grid.resize(SIZE * SIZE)
	_open_grid.fill(1)
	_bench_open_routes()
	_bench_unreachable()
	_bench_regions(world)
	print("bench_route_search: done")
	quit(0)

func _bench_generated_routes(world: WorldStateType, start: Vector2i) -> void:
	var by_distance := _tiles_at_distances(func(tile: Vector2i) -> bool:
		return bool(world.passability(tile.x, tile.y)["passable"]), start)
	for distance in DISTANCES:
		if not by_distance.has(distance):
			continue
		var target: Vector2i = by_distance[distance]
		_time_search("generated/passability()", start, target, distance, TestAccess.passability(world).is_passable)

func _bench_open_routes() -> void:
	var start := Vector2i(0, 0)
	for distance in DISTANCES:
		if distance > (SIZE - 1) * 2:
			continue
		var target := Vector2i(mini(distance, SIZE - 1), distance - mini(distance, SIZE - 1))
		_time_search("open/array-cost", start, target, distance, _open_cost)

func _bench_unreachable() -> void:
	var target := Vector2i(200, 200)
	for step in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var wall: Vector2i = target + step
		_open_grid[wall.y * SIZE + wall.x] = 0
	_time_search("open/unreachable", Vector2i(0, 0), target, -1, _open_cost)
	for step in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		var wall: Vector2i = target + step
		_open_grid[wall.y * SIZE + wall.x] = 1

func _time_search(label: String, start: Vector2i, target: Vector2i, distance: int, cost_fn: Callable) -> void:
	var t := Time.get_ticks_usec()
	var search := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, Vector2i(SIZE - 1, SIZE - 1))
	while not search.is_terminal():
		search.resume()
	var usec := Time.get_ticks_usec() - t
	var snapshot_size := JSON.stringify(_json_safe(search.snapshot())).length()
	print("bench_route_search: %s from=%s to=%s path_distance=%d status=%s path_len=%d expansions=%d resume_calls(ticks)=%d time=%.2fms us/expansion=%.2f snapshot_json=%dB" % [
		label, start, target, distance, search.get_status(), search.get_path().size(), search.expansions,
		search.resume_calls, usec / 1000.0, float(usec) / maxi(1, search.expansions), snapshot_size])
	BenchCommon.row("bench_route_search", "routes", "%s d=%d" % [label, distance], {
		"from": str(start), "to": str(target), "status": search.get_status(), "path len": search.get_path().size(),
		"expansions": search.expansions, "resume calls (ticks)": search.resume_calls, "time ms": "%.2f" % (usec / 1000.0),
		"us/expansion": "%.2f" % (float(usec) / maxi(1, search.expansions)), "snapshot json B": snapshot_size})

func _open_cost(tile: Vector2i) -> float:
	return float(_open_grid[tile.y * SIZE + tile.x])

## First tile found at each requested BFS path distance from start.
func _tiles_at_distances(passable: Callable, start: Vector2i) -> Dictionary:
	var result := {}
	var dist := {start: 0}
	var frontier: Array[Vector2i] = [start]
	var head := 0
	while head < frontier.size():
		var tile: Vector2i = frontier[head]
		head += 1
		var d: int = dist[tile]
		if DISTANCES.has(d) and not result.has(d):
			result[d] = tile
		for step in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
			var next: Vector2i = tile + step
			if dist.has(next) or next.x < 0 or next.y < 0 or next.x >= SIZE or next.y >= SIZE:
				continue
			if not passable.call(next):
				continue
			dist[next] = d + 1
			frontier.append(next)
	return result

func _bench_regions(world: WorldStateType) -> void:
	var t := Time.get_ticks_usec()
	TestAccess.tile_grid(world).get_regions()
	_print_map_time("regions full build (generated map, TileGrid.get_regions())", t)
	t = Time.get_ticks_usec()
	var regions := RegionMapType.new(SIZE, SIZE, func(x: int, y: int) -> bool: return _open_grid[y * SIZE + x] == 1)
	_print_map_time("regions full build (open grid, array callable)", t)
	_open_grid[128 * SIZE + 128] = 0
	t = Time.get_ticks_usec()
	regions.on_passability_changed(128, 128)
	_print_map_time("regions on_passability_changed (block one tile mid open 256x256 region)", t)
	_open_grid[128 * SIZE + 128] = 1
	t = Time.get_ticks_usec()
	regions.on_passability_changed(128, 128)
	_print_map_time("regions on_passability_changed (unblock it again)", t)
	# Rooms (game/scripts/core/map/rooms.gd): WorldState calls
	# _tile_grid.get_rooms().on_passability_changed() after every tile-kind change of a
	# completed work job (_toil_on_work_complete), even when passability did
	# not change (soil -> plowed_soil). Timed on the generated map at
	# colonist_0's own tile, whose passability does not change.
	var tile := Vector2i(int(TestAccess.colonists(world)[0]["x"]), int(TestAccess.colonists(world)[0]["y"]))
	t = Time.get_ticks_usec()
	var rooms = TestAccess.tile_grid(world).get_rooms()
	_print_map_time("rooms full build (generated map, TileGrid.get_rooms())", t)
	t = Time.get_ticks_usec()
	rooms.on_passability_changed(tile.x, tile.y)
	_print_map_time("rooms on_passability_changed at %s (no passability change, open area)" % tile, t)

## One region/room timing: its "bench_route_search: <label> time=" line and its row.
func _print_map_time(label: String, since_usec: int) -> void:
	var ms := (Time.get_ticks_usec() - since_usec) / 1000.0
	print("bench_route_search: %s time=%.2fms" % [label, ms])
	BenchCommon.row("bench_route_search", "regions and rooms", label, {"time ms": "%.2f" % ms})

## Vector2i keys/values -> "x,y" strings, only to measure the snapshot's JSON size.
func _json_safe(value):
	match typeof(value):
		TYPE_VECTOR2I:
			return "%d,%d" % [value.x, value.y]
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[str(_json_safe(key))] = _json_safe(value[key])
			return out
		TYPE_ARRAY:
			var out := []
			for item in value:
				out.append(_json_safe(item))
			return out
	return value
