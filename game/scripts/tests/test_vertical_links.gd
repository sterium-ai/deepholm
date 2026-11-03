extends SceneTree

## L3 (ADR 045 §3–§4, ADR 068): VerticalLinks, the region graph and link edges in RouteSearch,
## on a hand-built two-layer map with a stair pair.
##
## The map is 9x5, two layers, every tile open. z grows underground (ADR 045): the stair joins
## its top (2, 2, 0), declaring link_down, and its bottom (2, 2, 1), declaring link_up, right
## below. Column x = 4 on layer 0 is the wall slot: walled, layer 0 splits into a west half
## holding the stair and an east half without one.
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
##   stair, costs the same as the planar legs plus one step, is identical on a re-run; a search
##   snapshotted while still searching and restored finishes exactly like an uninterrupted one;
##   without links it stays on its layer; a same-layer search's path is
##   unchanged by attaching links, and its whole state by an empty link set.

const RegionMapType = preload("res://scripts/core/map/regions.gd")
const VerticalLinksType = preload("res://scripts/core/map/vertical_links.gd")
const RouteSearchType = preload("res://scripts/core/routing/route_search.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")

const W := 9
const H := 5
const LAYERS := 2
const STAIR_TOP := Vector3i(2, 2, 0)
const STAIR_BOTTOM := Vector3i(2, 2, 1)
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
	_check_restored_search_continues_the_same()
	_check_link_index_stays_sorted()
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
	_link[_flat(STAIR_TOP)] = VerticalLinksType.DOWN
	_link[_flat(STAIR_BOTTOM)] = VerticalLinksType.UP

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

	_link[_flat(STAIR_TOP)] = 0
	regions.on_tile_changed(STAIR_TOP)
	_expect(regions.vertical_links().size() == 0, "stair removed: no link")
	_expect(not regions.reachable(west, upper) and not regions.reachable(upper, east), "stair removed: layer 1 is cut off")
	_expect(regions.component_of(upper) == regions.region_of(upper), "stair removed: layer 1 is its own component")

	_link[_flat(STAIR_TOP)] = VerticalLinksType.DOWN
	regions.on_tile_changed(STAIR_TOP)
	_expect(regions.reachable(west, upper), "stair rebuilt: layer 1 reconnects")

func _check_broken_link_ends_are_not_links() -> void:
	_reset_map()
	_link[_flat(STAIR_BOTTOM)] = 0
	_expect(_new_regions().vertical_links().size() == 0, "link_down without a link_up below is no link")
	_reset_map()
	_link[_flat(STAIR_TOP)] = VerticalLinksType.UP
	_link[_flat(STAIR_BOTTOM)] = VerticalLinksType.DOWN
	_expect(_new_regions().vertical_links().size() == 0, "flags declared the wrong way round are no link")
	_reset_map()
	_open[_flat(STAIR_BOTTOM)] = 0
	var regions := _new_regions()
	_expect(regions.vertical_links().size() == 0, "a link whose lower end is impassable is no link")
	_set_open(regions, STAIR_BOTTOM, true)
	_expect(regions.vertical_links().size() == 1 and regions.reachable(Vector3i(0, 0, 0), STAIR_BOTTOM),
		"opening the lower end makes the link")
	var links := regions.vertical_links()
	_expect(links.has_link_down(STAIR_TOP) and links.has_link_up(STAIR_BOTTOM), "the top links down, the bottom up")
	_expect(not links.has_link_up(STAIR_TOP) and not links.has_link_down(STAIR_BOTTOM), "and neither the other way")
	_set_open(regions, STAIR_TOP, false)
	_expect(regions.vertical_links().size() == 0 and not regions.reachable(Vector3i(0, 0, 0), STAIR_BOTTOM),
		"blocking the upper end breaks it")
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
	var top_at := path.find(STAIR_TOP)
	_expect(top_at >= 0 and top_at + 1 < path.size() and path[top_at + 1] == STAIR_BOTTOM, "the path goes down the stair: %s" % [path])
	var expected_steps := absi(start.x - STAIR_TOP.x) + absi(start.y - STAIR_TOP.y) + 1 + absi(STAIR_BOTTOM.x - target.x) + absi(STAIR_BOTTOM.y - target.y)
	_expect(path.size() == expected_steps + 1, "the path is the shortest: %d steps, expected %d" % [path.size() - 1, expected_steps])
	for i in range(1, path.size()):
		var step := path[i] - path[i - 1]
		_expect(absi(step.x) + absi(step.y) + absi(step.z) == 1, "every step is one tile: %s -> %s" % [path[i - 1], path[i]])

	var again := _search(start, target, links)
	_finish(again)
	_expect(again.get_path() == path, "the same search gives the same path")

	var down := _search(target, start, links)
	_expect(_finish(down) == RouteSearchType.STATUS_FOUND and down.get_path().size() == path.size(), "the stair works upwards too")

	_expect(_finish(_search(start, target, null)) == RouteSearchType.STATUS_UNREACHABLE, "without links the search stays on its layer")

	var gated := RouteSearchType.new(start, target, _cost, Vector3i.ZERO, Vector3i(W - 1, H - 1, LAYERS - 1), regions.reachable)
	gated.set_vertical_links(links)
	_expect(_finish(gated) == RouteSearchType.STATUS_FOUND, "regions.reachable admits the cross-layer pair")
	_link[_flat(STAIR_TOP)] = 0
	regions.on_tile_changed(STAIR_TOP)
	var cut := RouteSearchType.new(start, target, _cost, Vector3i.ZERO, Vector3i(W - 1, H - 1, LAYERS - 1), regions.reachable)
	_expect(cut.get_status() == RouteSearchType.STATUS_UNREACHABLE, "stair removed: refused before any expansion")
	var unchecked := _search(start, target, links)
	_expect(_finish(unchecked) == RouteSearchType.STATUS_UNREACHABLE, "stair removed: the link edge is gone too")

## Layer 1 is a snake of walls (x = 3, 5, 7, alternate gaps) with the target at its far end,
## while layer 0 pulls the heuristic towards the target's column: far more than one resume()'s
## STEP_BUDGET, so the snapshot is taken while the search is still SEARCHING.
func _check_restored_search_continues_the_same() -> void:
	_reset_map()
	for y in range(0, H - 1):
		_open[_flat(Vector3i(3, y, 1))] = 0
		_open[_flat(Vector3i(7, y, 1))] = 0
	for y in range(1, H):
		_open[_flat(Vector3i(5, y, 1))] = 0
	var links := _new_regions().vertical_links()
	var start := Vector3i(8, 4, 0)
	var target := Vector3i(8, 0, 1)
	var whole := _search(start, target, links)
	_expect(_finish(whole) == RouteSearchType.STATUS_FOUND, "the snake route is found")
	var interrupted := _search(start, target, links)
	interrupted.resume()
	_expect(interrupted.get_status() == RouteSearchType.STATUS_SEARCHING, "one resume() does not finish the snake route")
	var restored := RouteSearchType.new(start, target, _cost, Vector3i.ZERO, Vector3i(W - 1, H - 1, LAYERS - 1))
	restored.set_vertical_links(links)
	restored.restore(interrupted.snapshot())
	_expect(restored.snapshot() == interrupted.snapshot(), "restore() takes the whole mid-search state")
	_expect(_finish(restored) == RouteSearchType.STATUS_FOUND, "the restored search finishes")
	_finish(interrupted)
	_expect(restored.get_path() == whole.get_path() and interrupted.get_path() == whole.get_path(),
		"restored and continued searches end on the uninterrupted path: %s" % [restored.get_path()])
	_expect(restored.snapshot() == whole.snapshot(), "and in the same final state")

## The link index stays ascending and matches the per-tile queries through inserts and removals.
func _check_link_index_stays_sorted() -> void:
	_reset_map()
	var regions := _new_regions()
	for top: Vector3i in [Vector3i(6, 1, 0), Vector3i(0, 4, 0), Vector3i(8, 0, 0)]:
		_link[_flat(top)] = VerticalLinksType.DOWN
		_link[_flat(top + Vector3i(0, 0, 1))] = VerticalLinksType.UP
		regions.on_tile_changed(top + Vector3i(0, 0, 1))
	var links := regions.vertical_links()
	_expect(links.links() == _new_regions().vertical_links().links(), "incremental inserts match a full build: %s" % [links.links()])
	_set_open(regions, STAIR_TOP, false)
	_link[_flat(Vector3i(8, 0, 0))] = 0
	regions.on_tile_changed(Vector3i(8, 0, 0))
	var expected: Array[Vector3i] = [Vector3i(6, 1, 0), Vector3i(0, 4, 0)]
	_expect(links.links() == expected, "removals keep the rest in order: %s" % [links.links()])
	var indices := links.upper_indices()
	for i in range(1, indices.size()):
		_expect(indices[i - 1] < indices[i], "the index is strictly ascending")
	for top: Vector3i in links.links():
		_expect(links.has_link_down(top) and links.has_link_up(top + Vector3i(0, 0, 1)), "each indexed link answers both queries")

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
	# (the stair's lower end gone) it must not differ in anything.
	_link[_flat(STAIR_BOTTOM)] = 0
	var empty := _new_regions().vertical_links()
	_expect(empty.size() == 0, "no link left")
	var idle := _search(start, target, empty)
	_finish(idle)
	_expect(idle.snapshot() == planar.snapshot() and idle.get_path() == planar.get_path(),
		"an empty link set leaves the search state unchanged")
