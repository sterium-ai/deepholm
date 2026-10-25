extends SceneTree

## A0 benchmark: WorldState.tick() wall time vs. actor count on a generated
## 256x256 map (seed 42), for three workloads:
##   idle  - no orders; measures the per-actor cost of a tick with nothing to do.
##   busy  - one tool-free till order per colonist submitted at tick 0; the
##           scheduler, route searches and toils all run.
##   needs - every colonist's food set to 20 (below "urgent" 25, needs.json)
##           at tick 0, so they all search for food at once (identical spawn
##           needs make this the normal case, not a contrived one).
## Tick 1 is reported on its own ("first"): it pays the lazy full-map region
## build (TileGrid.get_regions()). The mean/p50/p95/max cover ticks 2..n.
## Each run also times every phase of tick() through BenchCommon.profiled_tick()
## and checks that a twin world advanced with the real tick() ends with the
## same state_hash(), so the phase split is trustworthy.
##
## Evidence, not a gate: always exits 0. Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_tick_scaling.gd
## Optional: -- --actors=10,100 --ticks=20 --workloads=idle,busy

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 42
const SIZE := 256
const DEFAULT_ACTORS := [10, 100, 500, 1000]
const DEFAULT_TICKS := 30
const DEFAULT_WORKLOADS := ["idle", "busy", "needs"]
## A run stops early once its measured ticks have taken this long, so 1000
## actors cannot run for an hour; the sample count is printed.
const RUN_BUDGET_USEC := 90_000_000

func _init() -> void:
	var args := _parse_args()
	print(BenchCommon.header("bench_tick_scaling"))
	print("bench_tick_scaling: map=%dx%d seed=%d ticks<=%d per run" % [SIZE, SIZE, SEED, args["ticks"]])
	for workload in args["workloads"]:
		for actor_count in args["actors"]:
			_run(String(workload), int(actor_count), int(args["ticks"]))
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
	var stats := BenchCommon.stats_ms(samples.slice(1))
	var real_stats := BenchCommon.stats_ms(twin_samples.slice(1))
	var active := 0
	for job in world._scheduler.queue.get_jobs():
		if String(job.get("status", "")) == "active":
			active += 1
	print("bench_tick_scaling: workload=%s actors=%d setup=%.0fms tick[profiled, ticks 2..n] %s" % [workload,
		world._colonists.size(), build_usec / 1000.0, BenchCommon.format_stats(stats)])
	print("bench_tick_scaling: workload=%s actors=%d tick[real, ticks 2..n] %s first=%.2fms hash_match=%s jobs=%d active=%d events=%d" % [
		workload, twin._colonists.size(), BenchCommon.format_stats(real_stats),
		int(twin_samples[0]) / 1000.0 if not twin_samples.is_empty() else 0.0, hash_match,
		world._scheduler.queue.get_jobs().size(), active, world._event_log._events.size()])
	_print_phases("ticks 2..n", workload, world, totals, samples.size() - 1)

## Phases under 0.05 ms/tick are left out to keep the line readable.
func _print_phases(label: String, workload: String, world: WorldStateType, totals: Dictionary, tick_count: int) -> void:
	var phase_line := "bench_tick_scaling: workload=%s actors=%d phases[%s] (ms/tick):" % [workload,
		world._colonists.size(), label]
	for phase in BenchCommon.PHASES:
		var per_tick: float = int(totals.get(phase, 0)) / 1000.0 / maxi(1, tick_count)
		if per_tick >= 0.05:
			phase_line += " %s=%.2f" % [phase, per_tick]
	print(phase_line)

func _build(workload: String, actor_count: int) -> WorldStateType:
	var world := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, actor_count)
	match workload:
		"busy":
			BenchCommon.submit_till_orders(world, actor_count)
		"needs":
			for colonist in world._colonists:
				colonist["needs"]["food"] = 20
	return world

func _parse_args() -> Dictionary:
	var result := {"actors": DEFAULT_ACTORS, "ticks": DEFAULT_TICKS, "workloads": DEFAULT_WORKLOADS}
	for arg in OS.get_cmdline_user_args():
		var parts := String(arg).trim_prefix("--").split("=")
		if parts.size() != 2:
			continue
		match parts[0]:
			"actors":
				result["actors"] = Array(parts[1].split(",")).map(func(v): return int(v))
			"ticks":
				result["ticks"] = int(parts[1])
			"workloads":
				result["workloads"] = Array(parts[1].split(","))
	return result
