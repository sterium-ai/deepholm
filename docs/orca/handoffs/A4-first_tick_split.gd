extends SceneTree

## A4 evidence: splits bench_tick_scaling's "needs" first tick into the one-time lazy
## RegionMap build (TileGrid.get_regions(), a full-map flood fill on 256x256), the water
## tile cache, one need_source_candidates("water") pass and the rest of tick 1. Same world
## as the bench (BenchCommon.world_with_colonists(42, 256, 256, n), water set to 20).
## Lives outside game/ (not part of the suite):
##   godot --headless --path game --script <abs path to this file>

const BenchCommon = preload("res://scripts/tests/bench_common.gd")

func _ms(from: int, to: int) -> float:
	return (to - from) / 1000.0

func _init() -> void:
	for n in [10, 10, 25, 100]:
		var world = BenchCommon.world_with_colonists(42, 256, 256, n)
		for colonist in world._colonists:
			colonist["needs"]["water"] = 20
		var t0 := Time.get_ticks_usec()
		world._tile_grid.get_regions()
		var t1 := Time.get_ticks_usec()
		world._tile_grid.get_water_tiles()
		var t2 := Time.get_ticks_usec()
		world._needs_system.need_source_candidates("water")
		var t3 := Time.get_ticks_usec()
		world.tick()
		var t4 := Time.get_ticks_usec()
		print("first_tick_split: actors=%d regions=%.1fms water_cache=%.1fms candidates=%.1fms rest_of_tick1=%.1fms" % [
			n, _ms(t0, t1), _ms(t1, t2), _ms(t2, t3), _ms(t3, t4)])
	quit()
