extends SceneTree

## F6b-1 evidence: WorldState.tick() wall time with 1000 colonists on bench_tick_scaling's 256x256
## seed-42 map ("idle" workload), without and with 200 wild animals on the soil tiles nearest the colony, plus
## the "fauna" phase alone (BenchCommon.profiled_tick()). The budget cited is the foundation audit's
## (docs/architecture/foundation-audit.md §1): a tick under one frame (~16 ms) is no hitch, and one
## under 167 ms keeps up at x3. Run from the repo root:
##   godot --headless --path game --script ../docs/orca/handoffs/F6b-1-bench.gd

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 42
const SIZE := 256
const COLONISTS := 1000
const ANIMALS := 200
const TICKS := 60
const MIX: Array[String] = ["grasshopper", "grasshopper", "grasshopper", "grasshopper", "bird", "rabbit",
	"rabbit", "fox", "deer", "wolf"]

func _init() -> void:
	var plain := _run(false)
	var wild := _run(true)
	print("F6b-1-bench: colonists=%d animals=0 %s" % [COLONISTS, BenchCommon.format_stats(plain["tick"])])
	print("F6b-1-bench: colonists=%d animals=%d (alive at end %d) %s" % [COLONISTS, ANIMALS, wild["alive"],
		BenchCommon.format_stats(wild["tick"])])
	print("F6b-1-bench: fauna phase mean %.3f ms/tick over %d ticks" % [wild["fauna_ms"], TICKS])
	quit(0)

func _run(with_animals: bool) -> Dictionary:
	var world := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, COLONISTS)
	if with_animals:
		var origin := Vector2i(int(TestAccess.colonists(world)[0]["x"]), int(TestAccess.colonists(world)[0]["y"]))
		var placed := 0
		for tile in BenchCommon.passable_tiles_from(world, origin, 40000):
			if placed >= ANIMALS:
				break
			if world.get_tile(tile.x, tile.y) == WorldStateType.TILE_SOIL:
				world._fauna.spawn(MIX[placed % MIX.size()], Vector3i(tile.x, tile.y, 0))
				placed += 1
	world.tick() # the lazy region build, as bench_tick_scaling reports apart
	var samples := []
	var totals := {}
	for _i in TICKS:
		var t := Time.get_ticks_usec()
		BenchCommon.profiled_tick(world, totals)
		samples.append(Time.get_ticks_usec() - t)
	return {"tick": BenchCommon.stats_ms(samples), "alive": world._fauna.get_animals().size(),
		"fauna_ms": float(totals.get("fauna", 0)) / 1000.0 / TICKS}
