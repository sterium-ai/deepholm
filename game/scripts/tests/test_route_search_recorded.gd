extends SceneTree

## A3: RouteSearch must expand tiles in exactly the order the pre-heap
## implementation did. Every A0 route case (bench_route_search.gd: the
## generated seed-42 map at growing path distance, the open 256x256 grid, the
## walled-in unreachable target) plus a few weighted-cost grids is replayed
## and compared against values recorded from the linear-scan RouteSearch on
## `main` (279b42f): status, expansion count, resume() calls, the full path
## (one N/W/E/S letter per step) and a SHA-256 of a mid-search snapshot()
## (frontier order, visited order, came_from pairs). The mid-search snapshot
## is also restored into a fresh instance and finished, which must reach the
## same recorded result.
##
## Re-record (only when a task is allowed to change paths, e.g. A8):
##   & $env:GODOT --headless --path game --script res://scripts/tests/test_route_search_recorded.gd -- --record

const MeasuredRouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 42
const SIZE := 256
const DISTANCES := [8, 32, 64, 128, 256, 384]
const WEIGHTED_SIZE := 64

## label -> [status, expansions, resume_calls, path letters, mid-snapshot sha256]
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
		_expect(_seen == RECORDED.size(), "every recorded case must still be produced (%d of %d)" % [_seen, RECORDED.size()])
	if _failed:
		quit(1)
		return
	print("test_route_search_recorded: PASS")
	quit()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _check_case(label: String, start: Vector2i, target: Vector2i, cost_fn: Callable, size: int) -> void:
	var bounds_max := Vector2i(size - 1, size - 1)
	var search := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, bounds_max)
	var probe := MeasuredRouteType.new(start, target, cost_fn, Vector2i.ZERO, bounds_max)
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

	var restored := MeasuredRouteType.new(start, start, cost_fn, Vector2i.ZERO, bounds_max)
	restored.restore(mid_snapshot)
	while not restored.is_terminal():
		restored.resume()
	var restored_result := [restored.get_status(), restored.expansions, restored.resume_calls,
		_path_letters(restored.get_path())]

	if _record:
		print('\t"%s": ["%s", %d, %d, "%s", "%s"],' % [label, actual[0], actual[1], actual[2], actual[3], actual[4]])
		return
	_seen += 1
	_expect(RECORDED.has(label), "%s: no recorded result" % label)
	if not RECORDED.has(label):
		return
	var expected: Array = RECORDED[label]
	_expect(actual[0] == expected[0], "%s: status %s, recorded %s" % [label, actual[0], expected[0]])
	_expect(actual[1] == expected[1], "%s: expansions %d, recorded %d" % [label, actual[1], expected[1]])
	_expect(actual[2] == expected[2], "%s: resume calls %d, recorded %d" % [label, actual[2], expected[2]])
	_expect(actual[3] == expected[3], "%s: path differs from the recorded one" % label)
	_expect(actual[4] == expected[4], "%s: mid-search snapshot differs from the recorded one" % label)
	_expect(restored_result == expected.slice(0, 4),
		"%s: a search restored from its mid-search snapshot must finish like the uninterrupted one" % label)

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
