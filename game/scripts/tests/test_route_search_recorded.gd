extends SceneTree

## A3: RouteSearch run as plain Dijkstra (min_cost 0, no heuristic) must
## expand tiles in exactly the order the pre-heap implementation did. Every A0 route case (bench_route_search.gd: the
## generated seed-42 map at growing path distance, the open 256x256 grid, the
## walled-in unreachable target) plus a few weighted-cost grids is replayed
## and compared against values recorded from the linear-scan RouteSearch on
## `main` (279b42f): status, expansion count, resume() calls, the full path
## (one N/W/E/S letter per step) and a SHA-256 of a mid-search snapshot()
## (frontier order, visited order, came_from pairs). The mid-search snapshot
## is also restored into a fresh instance and finished, which must reach the
## same recorded result.
##
## A8 (ADR 054): every case also runs as the default A* search and is checked
## against RECORDED_ASTAR, recorded from the A* RouteSearch. ADR 054: "the
## path returned is a cheapest one, as before, but among equally cheap paths
## it may differ from the Dijkstra one", so each A* path must cost exactly
## what the Dijkstra path costs (and reach the same status). The generated
## d=256 case pins the acceptance bound: <= 1,500 expansions and <= 25
## resume() calls (Dijkstra: 15,462 and 242).
##
## Re-record (only when a task is allowed to change paths, e.g. A8):
##   & $env:GODOT --headless --path game --script res://scripts/tests/test_route_search_recorded.gd -- --record

const MeasuredRouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 42
const SIZE := 256
const DISTANCES := [8, 32, 64, 128, 256, 384]
const WEIGHTED_SIZE := 64
const ASTAR_D256_MAX_EXPANSIONS := 1500
const ASTAR_D256_MAX_RESUME_CALLS := 25

## label -> [status, expansions, resume_calls, path letters, mid-snapshot sha256]
## Dijkstra (min_cost 0): recorded before A3 and unchanged by A8.
const RECORDED := {
	"generated/d8": ["found", 79, 2, "NNNNNNNN", "98f36425eb39bf5e91ce20d96dea4cc6c95d5ff64ee964eb582ee6212ca8008a"],
	"generated/d32": ["found", 1728, 27, "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNW", "1d7dba2ef62bf29ed7cef55b231bda1e23f00c084efb20f7b4b5d153867a4d18"],
	"generated/d64": ["found", 4482, 71, "NNNNNNNNNNNNNNNNNNNNNNNNNWWWWNWWWWWWWWWWNWWWWWWNNWWNWWNWWWWWWWWW", "119202da01aed8a6c6fc6be0e340ecb3ba54d599d537c6d2330e08f868520563"],
	"generated/d128": ["found", 8423, 132, "NNNNNNNNNNNNNNNNNNWWWWWWWWWWWWWWNWWWWWWWWNWWWWWWWWWWWWWWWWWWWWNWNWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWNWNNWWWWNNWWWWNWWNWWWNNWWWWWWW", "2030268408c46bcda7cbd618bcf82d193f165cedf7a38f0ee4eda916c1c4c375"],
	"generated/d256": ["found", 15462, 242, "NNNNNNNNWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWNNNWWWWWWWWWWWWWWNNWWWWWWWWWWNNNNWWWWWWWWWWWWNWWWNWWWWNWWWWWWWWWWWWNWWWWWWWWWWWWWWWWWWWWWNWWWWWWWNWWNWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWNWWWNNNWWWWWWWWWWWNWWWWWWWWWWWWWWWWWWWWNNWWWWWWWWWWWWWWWW", "f48a414df1c9147fd3c94dbc0d8d56727e43ad96c185622b9580c15d9d2a1df9"],
	"open/d8": ["found", 29, 1, "EEEEEEEE", "51c49aa37ab804b9fd80a40077b648ceba0bf9b64dffde8368e811e5f32281b2"],
	"open/d32": ["found", 497, 8, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "bd2a3919bae9840781e8b873284392b4d1b2cc1c3a131d7e3195430208a0d34c"],
	"open/d64": ["found", 2017, 32, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "42313f7f7d0a672612306727042541d090a0a28d2c781d8b90b5d55ac22adcfa"],
	"open/d128": ["found", 8129, 128, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "542fe1767dd01a452ed046b2ecf23daaec2cac883577e272729ed677b073530b"],
	"open/d256": ["found", 32641, 511, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEES", "fdb247f18de5dd46a27db0f803a9ad4da12256147646ec4ce358d3ee78c50fec"],
	"open/d384": ["found", 57281, 896, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEESSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS", "1afd49d9483182b3d9bb1f5d4ef1206658317318c972de44206b373f40508a51"],
	"open/unreachable": ["unreachable", 65531, 1024, "", "1d771b0d75b410562ae60ddc93fabafeec99344df0b1d73c683da69a62de150a"],
	"weighted/63_63": ["found", 3721, 59, "SESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESE", "245c534d268b935bdb95385695bda38ef2f99b8d853dcf2954062cc0256229f0"],
	"weighted/40_5": ["found", 1366, 22, "SESESEEEEESESEEEEESESEEEEEEENEEEEEEEENEEEEEEEENEE", "8776362ec423a9f13580dc0cce5a918183df43e7063fa0ab3c15ca4f5a1d057a"],
	"weighted/5_60": ["found", 2911, 46, "SESESSSSSESSSSSESESSSSSESSSSSESSSSSESSSSWSSSSSSSWSSSSSSSWSSSSSSSWSSSSSS", "12b0cacf8129f51c8838617faa528e4a12445d2682fe91d8194450136521658c"],
	"weighted/33_33": ["unreachable", 3724, 59, "", "50affa4c685f1fb76dd7b1310d0cab9749109b635a6be2b360a612e1799d35d8"],
}

## The same, for the default A* search (min_cost = RouteSearch.MIN_TILE_COST).
const RECORDED_ASTAR := {
	"generated/d8": ["found", 8, 1, "NNNNNNNN", "e475326fd73ae5356f64ad59fc218c74176047138cfbf6c1dd0e48d791731c47"],
	"generated/d32": ["found", 50, 1, "NNNNNNNNNNNNNNNNNNNNNNNWNNNNNNNN", "564c04dba1974e02f87f6d7353c2318d510fcae5942ff6f61001fed0383e18b5"],
	"generated/d64": ["found", 64, 1, "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN", "47728a004570a586feba96407755538bd4808719b9621b30dded08c9101013f9"],
	"generated/d128": ["found", 167, 3, "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWNNWWWWWWWWWWWWWWWWWWWWWWWWWWWWNWWWWWWWWWWWWWWWWWWNNNNNNWWWWWWWWWWWNNNNNNNNNNNNNWNNNNNNNWNWN", "a0612614374f70470d9d2fe00ec3396c53b27573c79aa5c9e0ad39cf5d52106d"],
	"generated/d256": ["found", 266, 5, "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWNNWWWWWWWWWWWWWWWWWWWWWWWWWWWWNWWWWWWWWWWWWWWWWWWNNNNNNWWWWWWWWWWWWWWWWNNNNNNNNWWWWWWWWWWWWWWWWNWNWNWWNWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWNWWNNWWWWWWWWWWWWWWWWWWNWWWWWWWWWWWWWWWWWWWWWWWNNNNNN", "20a708f948a15e0c406b8728ecffc77e4c3eb218cf481e35419a79f99c4dc8be"],
	"open/d8": ["found", 8, 1, "EEEEEEEE", "51c49aa37ab804b9fd80a40077b648ceba0bf9b64dffde8368e811e5f32281b2"],
	"open/d32": ["found", 32, 1, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "fb18a4322cadde90720ef4e2e097a69d97def1e2050b4a547082bb36facce0da"],
	"open/d64": ["found", 64, 1, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "0a2be64f6c714fbc1d6a8e9693a1298c54c31bbcf081e0aa80e9fdb3ec8b5740"],
	"open/d128": ["found", 128, 2, "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "7cca04fa5b1937daaaae0b9521ac2e99aa40042b4c78c5361003190f98acaf26"],
	"open/d256": ["found", 256, 4, "SEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "2f49f036b95488b474b92fe7b95734f86f4a09b3cca49809a72f955c61c5da12"],
	"open/d384": ["found", 384, 6, "SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE", "21ec60bd90f07cb8d1824be9e07635af37072f22017b75dea01e232842015532"],
	"open/unreachable": ["unreachable", 65531, 1024, "", "91c2bdef26b7482a458f49d627cb2f092ebca5b6d57ca4fa852252de1f88b9cd"],
	"weighted/63_63": ["found", 3321, 52, "SESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESESESESSEESESESEESSESESE", "3a20e15b33cec6e32c90c49df3e3f1029fb2947c4af8b79d9a79ad539d1374ea"],
	"weighted/40_5": ["found", 734, 12, "SESESEEEEESEEEEESEEEENEEEEEEEESEEENEEEEESEEEEEENE", "21bf01be0bd95c8bfc7d27cbb38201c1f51ea5933b71993a8f1028eb556c7e86"],
	"weighted/5_60": ["found", 1503, 24, "SESSSSSESESSSSSSSWSSSSSSSWSSSSSSSWSSSSSESSSSSESSSSSESESSSSSSSWSSSSSESSS", "de0a5c279cf1fd8fe332ae5010870c87a75e0cb23f5811170f7aab62c046c11a"],
	"weighted/33_33": ["unreachable", 3724, 59, "", "e0f27b34643bf836ffb7a9608b5f4e427d3e798a281769b0040c05360e32f1c5"],
}

var _failed := false
var _record := false
var _seen := 0
var _open_grid := PackedByteArray()

func _init() -> void:
	_record = OS.get_cmdline_user_args().has("--record")
	var world := WorldStateType.new(SEED, 10, SIZE, SIZE)
	var start := Vector2i(int(TestAccess.colonists(world)[0]["x"]), int(TestAccess.colonists(world)[0]["y"]))
	var by_distance := _tiles_at_distances(func(tile: Vector2i) -> bool:
		return bool(world.passability(tile.x, tile.y)["passable"]), start)
	for distance in DISTANCES:
		if by_distance.has(distance):
			_check_case("generated/d%d" % distance, start, by_distance[distance], TestAccess.passability(world).is_passable, SIZE)

	_open_grid.resize(SIZE * SIZE)
	_open_grid.fill(1)
	for distance in DISTANCES:
		var target := Vector2i(mini(distance, SIZE - 1), distance - mini(distance, SIZE - 1))
		_check_case("open/d%d" % distance, Vector2i.ZERO, target, _open_cost, SIZE)
	var walled := Vector2i(200, 200)
	for step in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		_open_grid[(walled + step).y * SIZE + (walled + step).x] = 0
	_check_case("open/unreachable", Vector2i.ZERO, walled, _open_cost, SIZE)

	for target in [Vector2i(63, 63), Vector2i(40, 5), Vector2i(5, 60), Vector2i(33, 33)]:
		_check_case("weighted/%d_%d" % [target.x, target.y], Vector2i(1, 1), target, _weighted_cost, WEIGHTED_SIZE)

	if not _record:
		_expect(_seen == RECORDED.size() + RECORDED_ASTAR.size(),
			"every recorded case must still be produced (%d of %d)" % [_seen, RECORDED.size() + RECORDED_ASTAR.size()])
	if _failed:
		quit(1)
		return
	print("test_route_search_recorded: PASS")
	quit()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## Runs one case as Dijkstra and as A*: each against its own table, and the
## A* path must cost what the Dijkstra one does.
func _check_case(label: String, start: Vector2i, target: Vector2i, cost_fn: Callable, size: int) -> void:
	var dijkstra := _check_mode(label, start, target, cost_fn, size, 0.0, RECORDED)
	var astar := _check_mode(label, start, target, cost_fn, size, MeasuredRouteType.MIN_TILE_COST, RECORDED_ASTAR)
	if _record:
		return
	_expect(astar[0] == dijkstra[0], "%s: A* status %s, Dijkstra %s" % [label, astar[0], dijkstra[0]])
	_expect(_path_cost(astar[3], cost_fn) == _path_cost(dijkstra[3], cost_fn),
		"%s: A* path cost %s, Dijkstra %s" % [label, _path_cost(astar[3], cost_fn), _path_cost(dijkstra[3], cost_fn)])
	if label == "generated/d256":
		_expect(int(astar[1]) <= ASTAR_D256_MAX_EXPANSIONS, "%s: A* expansions %d > %d" % [label, astar[1], ASTAR_D256_MAX_EXPANSIONS])
		_expect(int(astar[2]) <= ASTAR_D256_MAX_RESUME_CALLS, "%s: A* resume calls %d > %d" % [label, astar[2], ASTAR_D256_MAX_RESUME_CALLS])

## [status, expansions, resume_calls, path] of one mode, checked against table.
func _check_mode(label: String, start: Vector2i, target: Vector2i, cost_fn: Callable, size: int,
		min_cost: float, table: Dictionary) -> Array:
	var bounds_max := Vector2i(size - 1, size - 1)
	var search := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, bounds_max, Callable(), min_cost)
	var probe := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, bounds_max, Callable(), min_cost)
	while not probe.is_terminal():
		probe.resume()
	var mid_call := probe.resume_calls / 2
	var mid_snapshot := {}
	while not search.is_terminal():
		if search.resume_calls == mid_call:
			mid_snapshot = search.snapshot()
		search.resume()
	if mid_snapshot.is_empty():
		mid_snapshot = search.snapshot()
	var actual := [search.get_status(), search.expansions, search.resume_calls,
		_path_letters(search.get_path()), _snapshot_sha(mid_snapshot)]

	var result := [actual[0], actual[1], actual[2], search.get_path()]
	var restored := MeasuredRouteType.new(start, start, cost_fn, Vector2i.ZERO, bounds_max, Callable(), min_cost)
	restored.restore(mid_snapshot)
	while not restored.is_terminal():
		restored.resume()
	var restored_result := [restored.get_status(), restored.expansions, restored.resume_calls,
		_path_letters(restored.get_path())]

	if _record:
		print('%s	"%s": ["%s", %d, %d, "%s", "%s"],' % ["astar" if min_cost > 0.0 else "dijkstra", label, actual[0], actual[1], actual[2], actual[3], actual[4]])
		return result
	_seen += 1
	_expect(table.has(label), "%s: no recorded result" % label)
	if not table.has(label):
		return result
	var expected: Array = table[label]
	_expect(actual[0] == expected[0], "%s: status %s, recorded %s" % [label, actual[0], expected[0]])
	_expect(actual[1] == expected[1], "%s: expansions %d, recorded %d" % [label, actual[1], expected[1]])
	_expect(actual[2] == expected[2], "%s: resume calls %d, recorded %d" % [label, actual[2], expected[2]])
	_expect(actual[3] == expected[3], "%s: path differs from the recorded one" % label)
	_expect(actual[4] == expected[4], "%s: mid-search snapshot differs from the recorded one" % label)
	_expect(restored_result == expected.slice(0, 4),
		"%s: a search restored from its mid-search snapshot must finish like the uninterrupted one" % label)
	return result

## Sum of cost_fn over every tile entered (the start tile is not entered).
func _path_cost(path: Array[Vector2i], cost_fn: Callable) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += float(cost_fn.call(path[i]))
	return total

func _open_cost(tile: Vector2i) -> float:
	return float(_open_grid[tile.y * SIZE + tile.x])

## Costs 1..4 with scattered walls, so the frontier holds many equal-cost
## tiles and the (cost, insertion order) tie-break decides the expansion order.
func _weighted_cost(tile: Vector2i) -> float:
	if tile != Vector2i(1, 1) and (tile.x * 31 + tile.y * 17) % 11 == 0:
		return 0.0
	return float(1 + (tile.x * 7 + tile.y * 13) % 4)

func _path_letters(path: Array[Vector2i]) -> String:
	var letters := ""
	for i in range(1, path.size()):
		match path[i] - path[i - 1]:
			Vector2i(0, -1): letters += "N"
			Vector2i(-1, 0): letters += "W"
			Vector2i(1, 0): letters += "E"
			Vector2i(0, 1): letters += "S"
			_: letters += "?"
	return letters

## Order-sensitive digest of snapshot(): status, frontier in order, visited
## keys in insertion order, came_from pairs in insertion order, path.
func _snapshot_sha(state: Dictionary) -> String:
	var parts := PackedStringArray([str(state["start"]), str(state["target"]), String(state["status"])])
	parts.append("frontier")
	for tile in state["frontier"]:
		parts.append(str(tile))
	parts.append("visited")
	for tile in (state["visited"] as Dictionary).keys():
		parts.append(str(tile))
	parts.append("came_from")
	var came_from: Dictionary = state["came_from"]
	for child in came_from.keys():
		parts.append("%s<%s" % [child, came_from[child]])
	parts.append("path")
	for tile in state["path"]:
		parts.append(str(tile))
	return ";".join(parts).sha256_text()

## First tile found at each requested BFS path distance from start (the same
## target choice as bench_route_search.gd).
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
