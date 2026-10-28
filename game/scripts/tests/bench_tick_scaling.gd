extends SceneTree

## A0 benchmark: WorldState.tick() wall time vs. actor count on a generated
## 256x256 map (seed 42), for three workloads:
##   idle  - no orders; measures the per-actor cost of a tick with nothing to do.
##   busy  - one tool-free till order per colonist submitted at tick 0; the
##           scheduler, route searches and toils all run.
##   needs - every colonist's water set to 20 (below "urgent" 25, needs.json)
##           at tick 0, so they all search for a water tile at once (identical
##           spawn needs make this the normal case, not a contrived one). Water,
##           not food: a fresh generated map has no ground berries, so a food
##           search finds no candidate and never routes
##           (WorldState._needs_system.need_source_candidates()); the map has a river.
## Tick 1 is reported on its own ("first"): it pays the lazy full-map region
## build (TileGrid.get_regions()). The mean/p50/p95/max cover ticks 2..n.
## Each run also times every phase of tick() through BenchCommon.profiled_tick()
## and checks that a twin world advanced with the real tick() ends with the
## same state_hash(), so the phase split is trustworthy.
##
## Evidence, not a performance gate. Exits 0, except exit 1 when the
## profiled/real state_hash() check fails (the phase split would be wrong). Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_tick_scaling.gd
## Optional: -- --actors=10,100 --ticks=20 --workloads=idle,busy

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 42
const SIZE := 256
const DEFAULT_ACTORS := [10, 100, 500, 1000]
## The needs workload uses smaller rosters: its first tick grows with A²
## (one water-reachability pass over every colonist per searching colonist,
## WorldState._reachable_candidates_only()), so 500 and 1000 would take hours.
const NEEDS_ACTORS := [10, 25, 50, 100]
const DEFAULT_TICKS := 30
const DEFAULT_WORKLOADS := ["idle", "busy", "needs"]
## A run stops early once its measured ticks have taken this long, so 1000
## actors cannot run for an hour; the sample count is printed.
const RUN_BUDGET_USEC := 90_000_000

var _hash_mismatches := 0

func _init() -> void:
	var args := _parse_args()
	print(BenchCommon.header("bench_tick_scaling"))
	print("bench_tick_scaling: map=%dx%d seed=%d ticks<=%d per run" % [SIZE, SIZE, SEED, args["ticks"]])
	for workload in args["workloads"]:
		var actor_counts: Array = args["actors"]
		if workload == "needs" and not args["actors_given"]:
			actor_counts = NEEDS_ACTORS
		for actor_count in actor_counts:
			_run(String(workload), int(actor_count), int(args["ticks"]))
	if _hash_mismatches > 0:
		push_error("bench_tick_scaling: %d run(s) where profiled_tick() and tick() diverged; the phase split is invalid" % _hash_mismatches)
		print("bench_tick_scaling: FAILED hash check (%d run(s))" % _hash_mismatches)
		quit(1)
		return
	print("bench_tick_scaling: done")
	quit(0)

func _run(workload: String, actor_count: int, ticks: int) -> void:
	var build_start := Time.get_ticks_usec()
	var world := _build(workload, actor_count)
	var build_usec := Time.get_ticks_usec() - build_start
	var twin := _build(workload, actor_count)
	var totals: Dictionary = {}
	var samples: Array = []
	var run_usec := 0
	for i in ticks:
		var start := Time.get_ticks_usec()
		BenchCommon.profiled_tick(world, totals)
		var elapsed := Time.get_ticks_usec() - start
		samples.append(elapsed)
		run_usec += elapsed
		if i == 0:
			_print_phases("first tick", workload, world, totals, 1)
			totals = {}
		if run_usec > RUN_BUDGET_USEC:
			break
	var twin_samples: Array = []
	for i in samples.size():
		var start := Time.get_ticks_usec()
		twin.tick()
		twin_samples.append(Time.get_ticks_usec() - start)
	var hash_match: bool = world.state_hash() == twin.state_hash()
	if not hash_match:
		_hash_mismatches += 1
	var stats := BenchCommon.stats_ms(samples.slice(1))
	var real_stats := BenchCommon.stats_ms(twin_samples.slice(1))
	var active := 0
	for job in TestAccess.scheduler(world).queue.get_jobs():
		if String(job.get("status", "")) == "active":
			active += 1
	print("bench_tick_scaling: workload=%s actors=%d setup=%.0fms tick[profiled, ticks 2..n] %s" % [workload,
		TestAccess.colonists(world).size(), build_usec / 1000.0, BenchCommon.format_stats(stats)])
	var water_tiles := 0
	var water_candidates := 0
	if workload == "needs":
		water_tiles = TestAccess.tile_grid(world).get_water_tiles().size()
		water_candidates = TestAccess.needs_system(world).need_source_candidates("water").size()
		print("bench_tick_scaling: workload=needs actors=%d water_tiles=%d reachable_water_candidates=%d" % [
			TestAccess.colonists(world).size(), water_tiles, water_candidates])
	print("bench_tick_scaling: workload=%s actors=%d tick[real, ticks 2..n] %s first=%.2fms hash_match=%s jobs=%d active=%d events=%d" % [
		workload, TestAccess.colonists(twin).size(), BenchCommon.format_stats(real_stats),
		int(twin_samples[0]) / 1000.0 if not twin_samples.is_empty() else 0.0, hash_match,
		TestAccess.scheduler(world).queue.get_jobs().size(), active, TestAccess.event_log_events(world).size()])
	var values := {"setup ms": "%.0f" % (build_usec / 1000.0),
		"first ms": "%.2f" % (int(twin_samples[0]) / 1000.0 if not twin_samples.is_empty() else 0.0)}
	values.merge(BenchCommon.stats_values(real_stats))
	values["profiled mean ms"] = "%.2f" % stats["mean"]
	values.merge({"hash match": hash_match, "jobs": TestAccess.scheduler(world).queue.get_jobs().size(), "active": active,
		"events": TestAccess.event_log_events(world).size()})
	if workload == "needs":
		values.merge({"water tiles": water_tiles, "reachable water": water_candidates})
	BenchCommon.row("bench_tick_scaling", "ticks (real tick(), ticks 2..n)", "%s actors=%d" % [workload,
		TestAccess.colonists(twin).size()], values)
	_print_phases("ticks 2..n", workload, world, totals, samples.size() - 1)

## Phases under 0.05 ms/tick are left out to keep the line readable.
func _print_phases(label: String, workload: String, world: WorldStateType, totals: Dictionary, tick_count: int) -> void:
	var phase_line := "bench_tick_scaling: workload=%s actors=%d phases[%s] (ms/tick):" % [workload,
		TestAccess.colonists(world).size(), label]
	var values := {}
	for phase in BenchCommon.PHASES:
		var per_tick: float = int(totals.get(phase, 0)) / 1000.0 / maxi(1, tick_count)
		if per_tick >= 0.05:
			phase_line += " %s=%.2f" % [phase, per_tick]
			values[phase] = "%.2f" % per_tick
	print(phase_line)
	BenchCommon.row("bench_tick_scaling", "phases %s (ms/tick)" % label, "%s actors=%d" % [workload,
		TestAccess.colonists(world).size()], values)

func _build(workload: String, actor_count: int) -> WorldStateType:
	var world := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, actor_count)
	match workload:
		"busy":
			BenchCommon.submit_till_orders(world, actor_count)
		"needs":
			for colonist in TestAccess.colonists(world):
				colonist["needs"]["water"] = 20
	return world

func _parse_args() -> Dictionary:
	var result := {"actors": DEFAULT_ACTORS, "actors_given": false, "ticks": DEFAULT_TICKS, "workloads": DEFAULT_WORKLOADS}
	for arg in OS.get_cmdline_user_args():
		var parts := String(arg).trim_prefix("--").split("=")
		if parts.size() != 2:
			continue
		match parts[0]:
			"actors":
				result["actors"] = Array(parts[1].split(",")).map(func(v): return int(v))
				result["actors_given"] = true
			"ticks":
				result["ticks"] = int(parts[1])
			"workloads":
				result["workloads"] = Array(parts[1].split(","))
	return result
