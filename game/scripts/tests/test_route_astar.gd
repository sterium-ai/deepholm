extends SceneTree

## A8 (ADR 054): RouteSearch's A* and its region check.
##
## - On seeded random weighted maps (costs 1..4, scattered walls), the default
##   A* search reaches the same status as plain Dijkstra (min_cost 0) and a
##   path of exactly the same total cost, never more expansions, and a search
##   restored from a mid-search snapshot() finishes exactly like the
##   uninterrupted one (the maps are irregular enough that open tiles get a
##   cheaper parent after discovery, the case A* adds over Dijkstra).
## - reachable(start, target) = Passability.region_reachable on a real
##   WorldState: a walled-off target is refused in _init(), before any
##   expansion, and the check never refuses a target the unchecked search
##   reaches (so it only ever saves work, never changes a found path).
## - Through a real trigger (a forage order whose held pick must be dropped in
##   a stockpile cell walled off by a full-width rock row): the drop leg's
##   re-route is refused on the tick it starts, never reported "searching",
##   and the pick falls back to the ground on the holder's side.

const MeasuredRouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const ScenariosType = preload("res://scripts/tests/support/scenarios.gd")

const MAP_SIZE := 40
const MAP_SEEDS := [3, 17, 101]
const PAIRS_PER_MAP := 25

var _failed := false
var _costs := PackedByteArray()

func _init() -> void:
	_check_astar_matches_dijkstra_cost_on_weighted_maps()
	_check_region_check_refuses_walled_target_before_expanding()
	_check_region_check_never_refuses_a_reachable_target()
	_check_walled_off_drop_target_is_refused_without_searching()

	if _failed:
		quit(1)
		return
	print("test_route_astar: PASS")
	quit()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _check_astar_matches_dijkstra_cost_on_weighted_maps() -> void:
	var cost_fn := func(tile: Vector2i) -> float: return float(_costs[tile.y * MAP_SIZE + tile.x])
	var bounds_max := Vector2i(MAP_SIZE - 1, MAP_SIZE - 1)
	var improved_somewhere := false
	for map_seed in MAP_SEEDS:
		var rng := RandomNumberGenerator.new()
		rng.seed = map_seed
		_costs.resize(MAP_SIZE * MAP_SIZE)
		for i in _costs.size():
			_costs[i] = 0 if rng.randi_range(0, 5) == 0 else rng.randi_range(1, 4)
		for pair in PAIRS_PER_MAP:
			var start := Vector2i(rng.randi_range(0, MAP_SIZE - 1), rng.randi_range(0, MAP_SIZE - 1))
			var target := Vector2i(rng.randi_range(0, MAP_SIZE - 1), rng.randi_range(0, MAP_SIZE - 1))
			var label := "seed %d %s -> %s" % [map_seed, start, target]
			var dijkstra := _run(start, target, cost_fn, bounds_max, 0.0)
			var astar := _run(start, target, cost_fn, bounds_max, MeasuredRouteType.MIN_TILE_COST)
			_expect(astar.get_status() == dijkstra.get_status(), "%s: A* status %s, Dijkstra %s" % [label, astar.get_status(), dijkstra.get_status()])
			_expect(_path_cost(astar.get_path(), cost_fn) == _path_cost(dijkstra.get_path(), cost_fn),
				"%s: A* path cost %s, Dijkstra %s" % [label, _path_cost(astar.get_path(), cost_fn), _path_cost(dijkstra.get_path(), cost_fn)])
			_expect(astar.expansions <= dijkstra.expansions, "%s: A* expanded %d tiles, Dijkstra %d" % [label, astar.expansions, dijkstra.expansions])
			improved_somewhere = _check_restore_matches(label, start, target, cost_fn, bounds_max, astar) or improved_somewhere
	_expect(improved_somewhere, "some A* search must give an open tile a cheaper parent after discovery, or the re-push path is untested")

## Finishes a copy of the search from its mid-search snapshot(); true when that
## snapshot holds an open tile whose recorded parent is not the one it was
## discovered from (its g improved after discovery).
func _check_restore_matches(label: String, start: Vector2i, target: Vector2i, cost_fn: Callable,
		bounds_max: Vector2i, uninterrupted: MeasuredRouteType) -> bool:
	var search := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, bounds_max)
	var first_parent := {}
	var improved := false
	var mid_snapshot := {}
	while not search.is_terminal():
		if search.resume_calls == uninterrupted.resume_calls / 2:
			mid_snapshot = search.snapshot()
		search.resume()
		var came_from: Dictionary = search.snapshot()["came_from"]
		for tile in came_from:
			if not first_parent.has(tile):
				first_parent[tile] = came_from[tile]
			elif first_parent[tile] != came_from[tile]:
				improved = true
	if mid_snapshot.is_empty():
		return improved
	var restored := MeasuredRouteType.new(start, start, cost_fn, Vector2i.ZERO, bounds_max)
	restored.restore(mid_snapshot)
	while not restored.is_terminal():
		restored.resume()
	_expect(restored.get_status() == uninterrupted.get_status() and restored.get_path() == uninterrupted.get_path()
		and restored.expansions == uninterrupted.expansions and restored.resume_calls == uninterrupted.resume_calls,
		"%s: a search restored mid-way must finish exactly like the uninterrupted one" % label)
	return improved

func _check_region_check_refuses_walled_target_before_expanding() -> void:
	var world := WorldStateType.new(7, 1, 12, 12)
	_open_map(world)
	var walled := Vector2i(9, 9)
	for x in range(8, 11):
		for y in range(8, 11):
			if Vector2i(x, y) != walled:
				TestAccess.set_tile(world, x, y, WorldStateType.TILE_ROCK)
	# Raw tile writes: drop the passability cache and the region map so both
	# are rebuilt from the map above on their next query.
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.tile_grid(world).regions = null
	var passability := TestAccess.passability(world)
	var bounds_max := Vector2i(11, 11)
	var checked := MeasuredRouteType.new(Vector2i(1, 1), walled, passability.is_passable, Vector2i.ZERO, bounds_max, passability.region_reachable)
	_expect(checked.get_status() == MeasuredRouteType.STATUS_UNREACHABLE, "a target in another region must be refused in _init()")
	_expect(checked.resume() == MeasuredRouteType.STATUS_UNREACHABLE and checked.expansions == 0,
		"a refused search must never expand a tile (expanded %d)" % checked.expansions)
	_expect((checked.snapshot()["visited"] as Dictionary).is_empty() and (checked.snapshot()["frontier"] as Array).is_empty(),
		"a refused search must leave nothing in its snapshot")
	var unchecked := MeasuredRouteType.new(Vector2i(1, 1), walled, passability.is_passable, Vector2i.ZERO, bounds_max)
	while not unchecked.is_terminal():
		unchecked.resume()
	_expect(unchecked.get_status() == MeasuredRouteType.STATUS_UNREACHABLE and unchecked.expansions > 100,
		"without the region check the same request must exhaust the map (expanded %d)" % unchecked.expansions)

func _check_region_check_never_refuses_a_reachable_target() -> void:
	var world := WorldStateType.new(42, 1, 48, 48)
	var passability := TestAccess.passability(world)
	var bounds_max := Vector2i(47, 47)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var compared := 0
	for i in 60:
		var start := Vector2i(rng.randi_range(0, 47), rng.randi_range(0, 47))
		var target := Vector2i(rng.randi_range(0, 47), rng.randi_range(0, 47))
		if passability.is_passable(start) <= 0.0:
			continue
		compared += 1
		var unchecked := _run_with(start, target, passability.is_passable, bounds_max, Callable())
		var checked := _run_with(start, target, passability.is_passable, bounds_max, passability.region_reachable)
		_expect(checked.get_status() == unchecked.get_status() and checked.get_path() == unchecked.get_path(),
			"%s -> %s: the region check changed the outcome (%s vs %s)" % [start, target, checked.get_status(), unchecked.get_status()])
		_expect(checked.expansions <= unchecked.expansions, "%s -> %s: the region check must never add work" % [start, target])
	_expect(compared >= 20, "too few passable starts compared (%d)" % compared)

func _check_walled_off_drop_target_is_refused_without_searching() -> void:
	var world := WorldStateType.new(266019)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	for x in range(0, 48):
		TestAccess.set_tile(world, x, 6, WorldStateType.TILE_ROCK)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 5, "y": 5, "route": null, "work": null})
	_expect(ScenariosType.command(world, "place_bush", "place_object", {"x": 5, "y": 6, "kind": "berry_bush"}).get("ok", false),
		"berry_bush placement on the wall row must be accepted")
	_expect(ScenariosType.command(world, "zone_add_1", "zone_add", {"x": 5, "y": 9, "width": 1, "height": 1}).get("ok", false),
		"zone_add south of the wall must be accepted")
	var pick_id := world.spawn_ground_tool_item("pick", 5, 5)
	_expect(world.set_tool_item_held(pick_id, "colonist_0"), "moving the pick into colonist_0's hand must succeed")
	_expect(world.reserve_tool_item(pick_id, "foreign_job"), "reserving the held pick for a foreign job must succeed")
	var job_id := String(ScenariosType.command(world, "forage_1", "forage", {"x": 5, "y": 6, "priority": 1}).get("job_id", ""))
	_expect(not job_id.is_empty(), "forage submission must be accepted")
	var saw_searching := false
	var completed := false
	for _i in 200:
		world.tick()
		var route = world.get_colonists()[0].get("route")
		if route != null and route.get("rerouting") != null and String(route["rerouting"].get("status", "")) == "searching":
			saw_searching = true
		if String(ScenariosType.find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(not saw_searching, "a drop leg toward a stockpile cell in another region must be refused before it searches, never left \"searching\"")
	_expect(completed, "forage_1 must complete once the pick has been dropped")
	var location: Dictionary = world.get_tool_item(pick_id).get("location", {})
	_expect(String(location.get("type", "")) == "ground" and int(location.get("y", 99)) < 6,
		"with no crossing, the pick must fall back to the ground on the holder's side, got %s" % [location])

func _open_map(world: WorldStateType) -> void:
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	for y in 12:
		for x in 12:
			TestAccess.set_tile(world, x, y, WorldStateType.TILE_SOIL)

func _run(start: Vector2i, target: Vector2i, cost_fn: Callable, bounds_max: Vector2i, min_cost: float) -> MeasuredRouteType:
	var search := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, bounds_max, Callable(), min_cost)
	while not search.is_terminal():
		search.resume()
	return search

func _run_with(start: Vector2i, target: Vector2i, cost_fn: Callable, bounds_max: Vector2i, reachable: Callable) -> MeasuredRouteType:
	var search := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, bounds_max, reachable)
	while not search.is_terminal():
		search.resume()
	return search

## Sum of cost_fn over every tile entered (the start tile is not entered).
func _path_cost(path: Array[Vector2i], cost_fn: Callable) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += float(cost_fn.call(path[i]))
	return total
