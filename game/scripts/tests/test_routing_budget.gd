extends SceneTree

const RouteSearchType = preload("res://scripts/core/routing/route_search.gd")

var _failed := false

func _init() -> void:
	_check_short_route_completes_within_budget()
	_check_step_budget_boundary()
	_check_tie_break_on_open_grid()
	_check_long_route_resumes_across_calls()
	_check_unreachable_target_terminates()
	_check_trivial_same_tile_route()
	_check_blocked_and_out_of_bounds_start()
	_check_cheaper_route_preferred_over_shorter_costly_route()

	if _failed:
		quit(1)
		return
	print("test_routing_budget: PASS")
	quit()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _corridor(max_x: int) -> Callable:
	return func(tile: Vector2i) -> bool:
		return tile.y == 0 and tile.x >= 0 and tile.x <= max_x

## A route that fits inside a single call's step budget completes
## immediately and returns the deterministic corridor path.
func _check_short_route_completes_within_budget() -> void:
	var passable := _corridor(5)
	var search := RouteSearchType.new(Vector2i.ZERO, Vector2i(5, 0), passable, Vector2i.ZERO, Vector2i(5, 0))
	var status := search.resume()
	_expect(status == RouteSearchType.STATUS_FOUND, "a 5-step route must complete within the 64-step budget in one call")
	var expected_path: Array[Vector2i] = []
	for x in range(0, 6):
		expected_path.append(Vector2i(x, 0))
	_expect(search.get_path() == expected_path, "short route must return the deterministic corridor path")

## A target exactly STEP_BUDGET steps away completes in a single call, but
## one step beyond that needs a second call. This pins the exact 64-step
## constant: raising STEP_BUDGET to 65 would let the second case finish in
## one call too, failing this test.
func _check_step_budget_boundary() -> void:
	var budget: int = RouteSearchType.STEP_BUDGET
	var at_budget := _corridor(budget)
	var boundary_search := RouteSearchType.new(Vector2i.ZERO, Vector2i(budget, 0), at_budget, Vector2i.ZERO, Vector2i(budget, 0))
	_expect(boundary_search.resume() == RouteSearchType.STATUS_FOUND, "a route exactly STEP_BUDGET steps long must complete in one call")

	var beyond_budget := _corridor(budget + 1)
	var beyond_search := RouteSearchType.new(Vector2i.ZERO, Vector2i(budget + 1, 0), beyond_budget, Vector2i.ZERO, Vector2i(budget + 1, 0))
	_expect(beyond_search.resume() == RouteSearchType.STATUS_SEARCHING, "a route one step beyond STEP_BUDGET must not complete on the first call")
	_expect(beyond_search.resume() == RouteSearchType.STATUS_FOUND, "a route one step beyond STEP_BUDGET must complete on the second call")

## On an open grid with two equally short paths between start and target,
## the documented coordinate tie-break (ascending y, then ascending x)
## deterministically prefers moving along the lower row first.
func _check_tie_break_on_open_grid() -> void:
	var passable := func(_tile: Vector2i) -> bool: return true
	var search := RouteSearchType.new(Vector2i.ZERO, Vector2i(1, 1), passable, Vector2i.ZERO, Vector2i(3, 3))
	var status := search.resume()
	_expect(status == RouteSearchType.STATUS_FOUND, "an open grid must find the target")
	var expected_path: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)]
	_expect(search.get_path() == expected_path, "the coordinate tie-break must prefer the (1,0)-then-(1,1) path over (0,1)-then-(1,1)")

func _run_long_route() -> Dictionary:
	var passable := _corridor(100)
	var search := RouteSearchType.new(Vector2i.ZERO, Vector2i(100, 0), passable, Vector2i.ZERO, Vector2i(100, 0))
	var calls := 0
	var status := search.resume()
	calls += 1
	var first_status := status
	while status == RouteSearchType.STATUS_SEARCHING:
		status = search.resume()
		calls += 1
	return {"first_status": first_status, "status": status, "path": search.get_path(), "calls": calls}

## A route needing more than 64 steps reports "still searching" after the
## first call and completes on a later call using persisted frontier state;
## two identical runs take the same number of calls and find the same path.
func _check_long_route_resumes_across_calls() -> void:
	var first := _run_long_route()
	var second := _run_long_route()
	_expect(first["first_status"] == RouteSearchType.STATUS_SEARCHING, "a 100-step route must not finish on the first call")
	_expect(first["status"] == RouteSearchType.STATUS_FOUND, "the resumed search must eventually find the target")
	_expect(first["calls"] == 2, "a 100-step corridor with a 64-step budget must resolve in exactly two calls")
	_expect(first["calls"] == second["calls"], "identical seeded runs must take the same number of calls")
	_expect(first["path"] == second["path"], "identical seeded runs must produce the same path")
	var expected_path: Array[Vector2i] = []
	for x in range(0, 101):
		expected_path.append(Vector2i(x, 0))
	_expect(first["path"] == expected_path, "resumed search must return the full deterministic path")

## A target walled off by rock is confirmed unreachable once the bounded
## search space is exhausted, and further calls do no additional work.
func _check_unreachable_target_terminates() -> void:
	var passable := func(tile: Vector2i) -> bool: return tile.x <= 4
	var search := RouteSearchType.new(Vector2i.ZERO, Vector2i(9, 9), passable, Vector2i.ZERO, Vector2i(9, 9))
	var status := search.resume()
	_expect(status == RouteSearchType.STATUS_UNREACHABLE, "a target beyond an impassable wall must be confirmed unreachable")
	_expect(search.get_path().is_empty(), "unreachable search must not report a path")
	for _i in range(5):
		_expect(search.resume() == RouteSearchType.STATUS_UNREACHABLE, "terminal unreachable status must stay unreachable and not re-search")
	_expect(search.is_terminal(), "unreachable search must report itself as terminal")

	# A larger walled-off pocket needs multiple calls to exhaust the space,
	# but must still terminate rather than searching indefinitely.
	var big_passable := func(tile: Vector2i) -> bool: return tile.x <= 19
	var big_search := RouteSearchType.new(Vector2i.ZERO, Vector2i(25, 5), big_passable, Vector2i.ZERO, Vector2i(29, 9))
	var big_calls := 0
	var big_status := big_search.resume()
	big_calls += 1
	while big_status == RouteSearchType.STATUS_SEARCHING and big_calls < 10:
		big_status = big_search.resume()
		big_calls += 1
	_expect(big_status == RouteSearchType.STATUS_UNREACHABLE, "exhausting a larger bounded pocket must still confirm unreachable")
	_expect(big_calls == 4, "a 200-tile bounded pocket with a 64-step budget must exhaust in exactly four calls")

## The trivial start-equals-target route is found without searching.
func _check_trivial_same_tile_route() -> void:
	var passable := func(_tile: Vector2i) -> bool: return true
	var search := RouteSearchType.new(Vector2i(3, 3), Vector2i(3, 3), passable, Vector2i.ZERO, Vector2i(9, 9))
	_expect(search.get_status() == RouteSearchType.STATUS_FOUND, "start equal to target must be found without searching")
	var expected: Array[Vector2i] = [Vector2i(3, 3)]
	_expect(search.get_path() == expected, "trivial route path must be the single tile")

## A blocked or out-of-bounds start is never a valid place to search from, so
## it must be reported unreachable immediately, including when start equals
## target, rather than a false STATUS_FOUND for a tile nobody can stand on.
func _check_blocked_and_out_of_bounds_start() -> void:
	var blocked_start := func(tile: Vector2i) -> bool: return tile != Vector2i(0, 0)
	var blocked_search := RouteSearchType.new(Vector2i(0, 0), Vector2i(1, 0), blocked_start, Vector2i.ZERO, Vector2i(5, 0))
	_expect(blocked_search.get_status() == RouteSearchType.STATUS_UNREACHABLE, "a blocked start must be reported unreachable, not searched from")
	_expect(blocked_search.get_path().is_empty(), "a blocked start must not report a path")
	_expect(blocked_search.resume() == RouteSearchType.STATUS_UNREACHABLE, "a blocked start must stay terminal on resume()")

	var always_passable := func(_tile: Vector2i) -> bool: return true
	var out_of_bounds_search := RouteSearchType.new(Vector2i(-1, 0), Vector2i(0, 0), always_passable, Vector2i.ZERO, Vector2i(5, 0))
	_expect(out_of_bounds_search.get_status() == RouteSearchType.STATUS_UNREACHABLE, "an out-of-bounds start must be reported unreachable")
	_expect(out_of_bounds_search.get_path().is_empty(), "an out-of-bounds start must not report a path")

	var blocked_same_tile := func(tile: Vector2i) -> bool: return tile != Vector2i(2, 2)
	var blocked_trivial := RouteSearchType.new(Vector2i(2, 2), Vector2i(2, 2), blocked_same_tile, Vector2i.ZERO, Vector2i(5, 5))
	_expect(blocked_trivial.get_status() == RouteSearchType.STATUS_UNREACHABLE, "a same-tile request on a blocked tile must be unreachable, not found")

	var out_of_bounds_trivial := RouteSearchType.new(Vector2i(-1, -1), Vector2i(-1, -1), always_passable, Vector2i.ZERO, Vector2i(5, 5))
	_expect(out_of_bounds_trivial.get_status() == RouteSearchType.STATUS_UNREACHABLE, "a same-tile request on an out-of-bounds tile must be unreachable, not found")

## Cost callable for a 4x2 grid: start (0,0), target (3,0). The top row
## (y=0, x=1..3, which includes the target) is a direct 3-tile route; the
## bottom row (y=1) plus the two vertical connectors is a 5-tile route two
## tiles longer. When with_chairs is true, the top row costs 3 per tile
## (three "chair" tiles); the bottom row and (0,0) always cost 1 ("floor").
func _chair_route_cost(with_chairs: bool) -> Callable:
	return func(tile: Vector2i) -> int:
		if tile.x < 0 or tile.x > 3 or tile.y < 0 or tile.y > 1:
			return 0
		if tile.y == 0 and tile.x >= 1:
			return 3 if with_chairs else 1
		return 1

## Proves the search is genuinely cost-weighted, not merely tile-count
## shortest-path: the direct 3-tile route costs 3*3=9 through chair tiles,
## while the 5-tile floor route (two tiles longer) costs 1*4+3=7 (its last
## step still enters the shared target tile, itself a chair). The cheaper,
## longer floor route must be chosen. Removing the chair objects (all tiles
## cost 1) flips the comparison -- 3 for the direct route vs. 5 for the
## floor route -- so the direct route must be chosen instead.
func _check_cheaper_route_preferred_over_shorter_costly_route() -> void:
	var start := Vector2i(0, 0)
	var target := Vector2i(3, 0)
	var bounds_max := Vector2i(3, 1)

	var with_chairs := RouteSearchType.new(start, target, _chair_route_cost(true), Vector2i.ZERO, bounds_max)
	_expect(with_chairs.resume() == RouteSearchType.STATUS_FOUND, "a route around three chair tiles must still be found")
	var floor_path: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(3, 0)]
	_expect(with_chairs.get_path() == floor_path,
		"the cheaper 5-tile floor route (cost 7) must be preferred over the shorter 3-tile chair route (cost 9)")

	var without_chairs := RouteSearchType.new(start, target, _chair_route_cost(false), Vector2i.ZERO, bounds_max)
	_expect(without_chairs.resume() == RouteSearchType.STATUS_FOUND, "the direct route must still be found once the chairs are removed")
	var direct_path: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
	_expect(without_chairs.get_path() == direct_path,
		"removing the chair objects must flip the choice back to the direct 3-tile route (cost 3 vs. the floor route's cost 5)")
