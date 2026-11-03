extends SceneTree

## L3 (ADR 045 §3–§4, ADR 068): VerticalLinks, the region graph and link edges in RouteSearch,
## on a hand-built two-layer map with a stair pair.
##
## The map is 9x5, two layers, every tile open. The stair joins (2, 2, 0) (link_up) and
## (2, 2, 1) (link_down). Column x = 4 on layer 0 is the wall slot: walled, layer 0 splits into
## a west half holding the stair and an east half without one.
##
## - Split: walling x = 4 leaves the east half out of layer 1's graph component.
## - Merge: removing the wall reconnects it.
## - Stair removed: layer 1 is its own component again; a broken link end alone (only one tile
##   declaring it, or one end impassable) is no link either.
## - Dig target: an impassable layer-1 tile is reachable through its same-layer neighbours only;
##   the open tile right below it, in the caller's component, does not count.
## - Two rescues on one layer-1 target keep separate progress keys (key_of round-trips z), and
##   terminating one leaves the other's progress.
## - RouteSearch: with set_vertical_links() a route from layer 0 to layer 1 goes through the
##   stair, costs the same as the planar legs plus one step, is identical on a re-run and after
##   a mid-search restore; without links it stays on its layer; a same-layer search's path is
##   unchanged by attaching links, and its whole state by an empty link set.

const RegionMapType = preload("res://scripts/core/map/regions.gd")
const VerticalLinksType = preload("res://scripts/core/map/vertical_links.gd")
const RouteSearchType = preload("res://scripts/core/routing/route_search.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")

const W := 9
const H := 5
const LAYERS := 2
const STAIR_LOW := Vector3i(2, 2, 0)
const STAIR_HIGH := Vector3i(2, 2, 1)
const WALL_X := 4

var _failed := false
## Flat index -> 1 open / 0 blocked, and the link bits (VerticalLinks.UP | DOWN).
var _open := PackedByteArray()
var _link := PackedByteArray()

func _init() -> void:
	_check_split_merge_and_stair_removal()
	_check_broken_link_ends_are_not_links()
	_check_dig_target_counts_only_its_own_layer()
	_check_two_rescues_keep_their_own_progress()
	_check_route_crosses_the_stair()
	_check_planar_search_unchanged_by_links()
	if _failed:
		quit(1)
		return
	print("test_vertical_links: PASS")
	quit()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _reset_map() -> void:
	_open.resize(W * H * LAYERS)
	_open.fill(1)
	_link.resize(W * H * LAYERS)
	_link.fill(0)
	_link[_flat(STAIR_LOW)] = VerticalLinksType.UP
	_link[_flat(STAIR_HIGH)] = VerticalLinksType.DOWN

func _flat(tile: Vector3i) -> int:
	return tile.z * W * H + tile.y * W + tile.x

func _in_map(tile: Vector3i) -> bool:
	return tile.x >= 0 and tile.x < W and tile.y >= 0 and tile.y < H and tile.z >= 0 and tile.z < LAYERS

func _passable_tile(tile: Vector3i) -> bool:
	return _in_map(tile) and _open[_flat(tile)] == 1

func _link_flags(tile: Vector3i) -> int:
	return _link[_flat(tile)] if _in_map(tile) else 0

func _new_regions() -> RegionMapType:
	return RegionMapType.new(W, H, func(x: int, y: int) -> bool: return _passable_tile(Vector3i(x, y, 0)),
		PackedByteArray(), LAYERS, _passable_tile, _link_flags)

## Edits a tile and tells the region map, like TileGrid.on_passability_changed().
func _set_open(regions: RegionMapType, tile: Vector3i, open: bool) -> void:
	_open[_flat(tile)] = 1 if open else 0
	regions.on_tile_changed(tile)

func _set_wall(regions: RegionMapType, walled: bool) -> void:
	for y in H:
		_set_open(regions, Vector3i(WALL_X, y, 0), not walled)

func _check_split_merge_and_stair_removal() -> void:
	_reset_map()
	var regions := _new_regions()
	var west := Vector3i(0, 0, 0)
	var east := Vector3i(8, 4, 0)
	var upper := Vector3i(7, 0, 1)
	_expect(regions.vertical_links().size() == 1, "one stair pair, one link")
	_expect(not regions.same_region(west, upper), "a region never spans layers")
	_expect(regions.reachable(east, upper) and regions.reachable(upper, east), "open map: both layers connect through the stair")

	_set_wall(regions, true)
	_expect(regions.region_of(west) != regions.region_of(east), "the wall splits layer 0")
	_expect(regions.reachable(west, upper), "split: the west half keeps its stair")
	_expect(not regions.reachable(east, upper), "split: the east half lost its stair")
	_expect(not regions.reachable(upper, east), "split: layer 1 cannot reach the east half")
	_expect(not regions.reachable(east, west), "split: the halves are apart")
	_expect(regions.component_of(west) == regions.component_of(upper), "split: west and layer 1 share a component")

	_set_wall(regions, false)
	_expect(regions.region_of(west) == regions.region_of(east), "merge: layer 0 is one region again")
	_expect(regions.reachable(east, upper) and regions.reachable(upper, east), "merge: the east half reaches layer 1 again")
	var fresh := _new_regions()
	_expect(regions.component_of(east) == fresh.component_of(east) and regions.component_of(upper) == fresh.component_of(upper),
		"merge: the incremental graph matches a full build")

	_link[_flat(STAIR_LOW)] = 0
	regions.on_tile_changed(STAIR_LOW)
	_expect(regions.vertical_links().size() == 0, "stair removed: no link")
	_expect(not regions.reachable(west, upper) and not regions.reachable(upper, east), "stair removed: layer 1 is cut off")
	_expect(regions.component_of(upper) == regions.region_of(upper), "stair removed: layer 1 is its own component")

	_link[_flat(STAIR_LOW)] = VerticalLinksType.UP
	regions.on_tile_changed(STAIR_LOW)
	_expect(regions.reachable(west, upper), "stair rebuilt: layer 1 reconnects")

func _check_broken_link_ends_are_not_links() -> void:
	_reset_map()
	_link[_flat(STAIR_HIGH)] = 0
	_expect(_new_regions().vertical_links().size() == 0, "link_up without a link_down above is no link")
	_reset_map()
	_open[_flat(STAIR_HIGH)] = 0
	var regions := _new_regions()
	_expect(regions.vertical_links().size() == 0, "a link whose upper end is impassable is no link")
	_set_open(regions, STAIR_HIGH, true)
	_expect(regions.vertical_links().size() == 1 and regions.reachable(Vector3i(0, 0, 0), STAIR_HIGH),
		"opening the upper end makes the link")
	_set_open(regions, STAIR_LOW, false)
	_expect(regions.vertical_links().size() == 0 and not regions.reachable(Vector3i(0, 0, 0), STAIR_HIGH),
		"blocking the lower end breaks it")
	var single := RegionMapType.new(W, H, func(x: int, y: int) -> bool: return _passable_tile(Vector3i(x, y, 0)))
	_expect(single.vertical_links() == null, "a surface-only map has no links")

## The target (6, 2, 1) is impassable, ringed on layer 1 by blocked tiles except (7, 2, 1),
## which sits in a pocket sealed from the stair. The tile below, (6, 2, 0), is open and in the
## caller's component: it must not make the target reachable.
func _check_dig_target_counts_only_its_own_layer() -> void:
	_reset_map()
	var target := Vector3i(6, 2, 1)
	_open[_flat(target)] = 0
	for y in H:
		_open[_flat(Vector3i(5, y, 1))] = 0
	for tile in [Vector3i(6, 1, 1), Vector3i(6, 3, 1)]:
		_open[_flat(tile)] = 0
	var regions := _new_regions()
	var caller := Vector3i(0, 0, 0)
	_expect(regions.reachable(caller, Vector3i(6, 2, 0)), "the tile below the target is in the caller's component")
	_expect(not regions.reachable(caller, target), "dig target: the layer below never counts as its neighbour")
	_expect(regions.reachable(Vector3i(8, 0, 1), target), "dig target: its own pocket on layer 1 reaches it")
	_set_open(regions, Vector3i(5, 0, 1), true)
	_expect(regions.reachable(caller, target), "dig target: opening the pocket to the stair makes it reachable")

func _check_two_rescues_keep_their_own_progress() -> void:
	_reset_map()
	var target := Vector3i(7, 3, 1)
	var regions := _new_regions()
	_expect(regions.reachable(Vector3i(0, 0, 0), target), "the rescue target is reachable across the stair")
	var job_a := {"kind": "rescue", "target": target}
	var job_b := {"kind": "rescue", "target": target}
	var table := WorkProgressType.new(null, {"rescue": 30}, Callable(), Callable())
	var key_a := table.key_for_job("rescue-a", job_a)
	var key_b := table.key_for_job("rescue-b", job_b)
	_expect(key_a != key_b, "two rescues on one target have their own keys")
	for key in [key_a, key_b]:
		var parts := WorkProgressType.key_parts(key)
		_expect(parts["tile"] == target, "key_parts round-trips the layer: %s -> %s" % [key, parts["tile"]])
	_expect(WorkProgressType.key_parts(key_a)["scope"] == "rescue-a", "the key keeps its job scope")
	table.progress[key_a] = 12
	table.progress[key_b] = 25
	table.clear_terminated_job("rescue-a", job_a, true)
	_expect(not table.progress.has(key_a), "the terminated rescue's progress is gone")
	_expect(int(table.progress.get(key_b, -1)) == 25, "the other rescue keeps its own progress")

func _cost(tile: Vector3i) -> float:
	return 1.0 if _passable_tile(tile) else 0.0

func _search(start: Vector3i, target: Vector3i, links) -> RouteSearchType:
	var search := RouteSearchType.new(start, target, _cost, Vector3i.ZERO, Vector3i(W - 1, H - 1, LAYERS - 1))
	if links != null:
		search.set_vertical_links(links)
	return search

func _finish(search: RouteSearchType) -> String:
	for i in 1000:
		if search.is_terminal():
			break
		search.resume()
	return search.get_status()

func _check_route_crosses_the_stair() -> void:
	_reset_map()
	var regions := _new_regions()
	var links := regions.vertical_links()
	var start := Vector3i(8, 4, 0)
	var target := Vector3i(0, 0, 1)
	var search := _search(start, target, links)
	_expect(_finish(search) == RouteSearchType.STATUS_FOUND, "the route crosses the stair")
	var path := search.get_path()
	var low_at := path.find(STAIR_LOW)
	_expect(low_at >= 0 and low_at + 1 < path.size() and path[low_at + 1] == STAIR_HIGH, "the path climbs at the stair: %s" % [path])
	var expected_steps := absi(start.x - STAIR_LOW.x) + absi(start.y - STAIR_LOW.y) + 1 + absi(STAIR_HIGH.x - target.x) + absi(STAIR_HIGH.y - target.y)
	_expect(path.size() == expected_steps + 1, "the path is the shortest: %d steps, expected %d" % [path.size() - 1, expected_steps])
	for i in range(1, path.size()):
		var step := path[i] - path[i - 1]
		_expect(absi(step.x) + absi(step.y) + absi(step.z) == 1, "every step is one tile: %s -> %s" % [path[i - 1], path[i]])

	var again := _search(start, target, links)
	_finish(again)
	_expect(again.get_path() == path, "the same search gives the same path")

	var down := _search(target, start, links)
	_expect(_finish(down) == RouteSearchType.STATUS_FOUND and down.get_path().size() == path.size(), "the stair works downwards too")

	var interrupted := _search(start, target, links)
	interrupted.resume()
	var snapshot := interrupted.snapshot()
	var restored := RouteSearchType.new(start, target, _cost, Vector3i.ZERO, Vector3i(W - 1, H - 1, LAYERS - 1))
	restored.set_vertical_links(links)
	restored.restore(snapshot)
	_finish(restored)
	_expect(restored.get_path() == path, "a search restored mid-way finishes on the same path")

	_expect(_finish(_search(start, target, null)) == RouteSearchType.STATUS_UNREACHABLE, "without links the search stays on its layer")

	var gated := RouteSearchType.new(start, target, _cost, Vector3i.ZERO, Vector3i(W - 1, H - 1, LAYERS - 1), regions.reachable)
	gated.set_vertical_links(links)
	_expect(_finish(gated) == RouteSearchType.STATUS_FOUND, "regions.reachable admits the cross-layer pair")
	_link[_flat(STAIR_LOW)] = 0
	regions.on_tile_changed(STAIR_LOW)
	var cut := RouteSearchType.new(start, target, _cost, Vector3i.ZERO, Vector3i(W - 1, H - 1, LAYERS - 1), regions.reachable)
	_expect(cut.get_status() == RouteSearchType.STATUS_UNREACHABLE, "stair removed: refused before any expansion")
	var unchecked := _search(start, target, links)
	_expect(_finish(unchecked) == RouteSearchType.STATUS_UNREACHABLE, "stair removed: the link edge is gone too")

func _check_planar_search_unchanged_by_links() -> void:
	_reset_map()
	for y in range(1, H):
		_open[_flat(Vector3i(WALL_X, y, 0))] = 0
	var links := _new_regions().vertical_links()
	var start := Vector3i(0, 4, 0)
	var target := Vector3i(8, 4, 0)
	var planar := _search(start, target, null)
	var linked := _search(start, target, links)
	_finish(planar)
	_finish(linked)
	_expect(planar.get_status() == RouteSearchType.STATUS_FOUND, "the planar route exists")
	_expect(linked.get_path() == planar.get_path(), "a same-layer route is unchanged by links: %s vs %s" % [linked.get_path(), planar.get_path()])
	# The stair is a real neighbour, so the search state may differ above; with no link at all
	# (the stair's upper end gone) it must not differ in anything.
	_link[_flat(STAIR_HIGH)] = 0
	var empty := _new_regions().vertical_links()
	_expect(empty.size() == 0, "no link left")
	var idle := _search(start, target, empty)
	_finish(idle)
	_expect(idle.snapshot() == planar.snapshot() and idle.get_path() == planar.get_path(),
		"an empty link set leaves the search state unchanged")
