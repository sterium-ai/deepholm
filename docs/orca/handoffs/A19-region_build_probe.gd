extends SceneTree

## A19 evidence: where the one-time RegionMap build stands on the bench world
## (BenchCommon.world_with_colonists(42, 256, 256, n), water set to 20, as in
## bench_tick_scaling's needs workload and A4-first_tick_split.gd).
## For each run it prints:
## - whether TileGrid.regions was still unbuilt when tick 1 would start (so tick 1 pays it);
## - the cold Passability cache build (passable_mask()) and the RegionMap build on its own;
## - tick 1 of the real WorldState.tick() on a twin world that never touched regions;
## - a region-id check: every tile's id against an independent tile-by-tile flood fill
##   seeded in row-major order (the numbering regions.gd documents), plus a hash of the
##   id array and the region count, to compare with any other commit.
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file>

const BenchCommon = preload("res://scripts/tests/bench_common.gd")

func _ms(from: int, to: int) -> float:
	return (to - from) / 1000.0

func _world(n: int):
	var world = BenchCommon.world_with_colonists(42, 256, 256, n)
	for colonist in world._colonists:
		colonist["needs"]["water"] = 20
	return world

## Region ids by a plain BFS from each unlabelled passable tile in row-major order.
func _reference_ids(mask: PackedByteArray, width: int, height: int) -> PackedInt32Array:
	var ids := PackedInt32Array()
	ids.resize(width * height)
	ids.fill(0)
	var next_id := 1
	for start in ids.size():
		if mask[start] == 0 or ids[start] != 0:
			continue
		ids[start] = next_id
		var frontier := PackedInt32Array([start])
		var head := 0
		while head < frontier.size():
			var current := frontier[head]
			head += 1
			var x := current % width
			var y := current / width
			for step in [[0, -1], [-1, 0], [1, 0], [0, 1]]:
				var nx: int = x + step[0]
				var ny: int = y + step[1]
				if nx < 0 or nx >= width or ny < 0 or ny >= height:
					continue
				var neighbour := ny * width + nx
				if mask[neighbour] == 1 and ids[neighbour] == 0:
					ids[neighbour] = next_id
					frontier.append(neighbour)
		next_id += 1
	return ids

func _init() -> void:
	for n in [10, 10, 25, 100]:
		var world = _world(n)
		var grid = world._tile_grid
		var unbuilt: bool = grid.regions == null
		var t0 := Time.get_ticks_usec()
		var mask: PackedByteArray = grid._passable_mask.call()
		var t1 := Time.get_ticks_usec()
		grid.get_regions()
		var t2 := Time.get_ticks_usec()
		var twin = _world(n)
		var twin_unbuilt: bool = twin._tile_grid.regions == null
		var t3 := Time.get_ticks_usec()
		twin.tick()
		var t4 := Time.get_ticks_usec()
		print("region_build: actors=%d regions_unbuilt_before_tick1=%s passable_mask=%.1fms region_build=%.1fms twin_unbuilt=%s real_tick1=%.1fms" % [
			n, unbuilt, _ms(t0, t1), _ms(t1, t2), twin_unbuilt, _ms(t3, t4)])
	var world = _world(10)
	var grid = world._tile_grid
	var mask: PackedByteArray = grid._passable_mask.call()
	var regions = grid.get_regions()
	var reference := _reference_ids(mask, grid.width, grid.height)
	var actual := PackedInt32Array()
	actual.resize(grid.width * grid.height)
	var mismatches := 0
	var max_id := 0
	for y in grid.height:
		for x in grid.width:
			var index: int = y * grid.width + x
			actual[index] = regions.region_id(x, y)
			max_id = maxi(max_id, actual[index])
			if actual[index] != reference[index]:
				mismatches += 1
	print("region_ids: seed=42 size=%dx%d regions=%d next_id=%d mismatches_vs_reference_flood=%d ids_hash=%d" % [
		grid.width, grid.height, max_id, regions._next_id, mismatches, hash(actual)])
	quit()
