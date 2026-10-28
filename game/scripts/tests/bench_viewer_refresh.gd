extends SceneTree

## A9 benchmark: the debug viewer's per-tick refresh (boot.gd's _refresh(): map view,
## colonist and actor layers, designation overlay, colonist panel, work table, need
## alerts and room line) with 1,000 actors, headless. The boot scene is built the way
## the game builds it (Boot.new() in the tree, then _build_ui(), which headless _ready()
## skips) and its world is swapped for BenchCommon.world_with_colonists() on a generated
## 128x128 map with up to one till order per colonist (the "orders" printed: the map
## has fewer reachable soil tiles than 1,000), so part of the roster walks and works
## while the rest idles, its needs ticking down. Each
## sample is one world.tick() (not timed) followed by one timed boot._refresh(); the
## world swap itself (boot._replace_world(), which builds every row and sprite) is
## reported on its own ("swap").
## The breakdown times the parts of _refresh() (the snapshot, then the four calls that
## read it) separately on the ticks in between.
##
## Evidence, not a gate (bench_common.gd). A9's acceptance is mean <= 4 ms per tick at
## 1,000 actors. Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_viewer_refresh.gd
## Optional: -- --actors=100,1000 --ticks=60

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const Boot = preload("res://scripts/boot.gd")

const SEED := 42
const SIZE := 128
const DEFAULT_ACTORS := [100, 1000]
const DEFAULT_TICKS := 60
## A run stops early once its timed refreshes have taken this long; the sample count is printed.
const RUN_BUDGET_USEC := 60_000_000
const PARTS: Array[String] = ["snapshot", "map_view", "info_panel", "need_alerts", "room_line"]

func _initialize() -> void:
	_run_all.call_deferred()

## Deferred so the tree is live: Boot's _ready() (its TickDriver) runs on add_child().
func _run_all() -> void:
	var args := _parse_args()
	print(BenchCommon.header("bench_viewer_refresh"))
	print("bench_viewer_refresh: map=%dx%d seed=%d ticks<=%d per run" % [SIZE, SIZE, SEED, args["ticks"]])
	for actor_count in args["actors"]:
		_run(int(actor_count), int(args["ticks"]))
	print("bench_viewer_refresh: done")
	quit(0)

func _run(actor_count: int, ticks: int) -> void:
	var world := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, actor_count)
	var orders := BenchCommon.submit_till_orders(world, actor_count)
	var boot := Boot.new()
	root.add_child(boot)
	boot.tick_driver.pause()
	boot._build_ui()
	var start := Time.get_ticks_usec()
	boot._replace_world(world)
	var swap_usec := Time.get_ticks_usec() - start
	var samples: Array = []
	var parts: Dictionary = {}
	var run_usec := 0
	for _i in ticks:
		world.tick()
		start = Time.get_ticks_usec()
		boot._refresh()
		var elapsed := Time.get_ticks_usec() - start
		samples.append(elapsed)
		run_usec += elapsed
		world.tick()
		_time_parts(boot, parts)
		if run_usec > RUN_BUDGET_USEC:
			break
	var stats := BenchCommon.stats_ms(samples)
	var split: Array[String] = []
	var split_values: Dictionary = {}
	for part in PARTS:
		var mean_ms: float = int(parts.get(part, 0)) / 1000.0 / maxi(1, samples.size())
		split.append("%s=%.2fms" % [part, mean_ms])
		split_values[part + " ms"] = "%.2f" % mean_ms
	print("bench_viewer_refresh: actors=%d orders=%d swap=%.2fms %s | %s" % [world.get_colonists().size(),
		orders, swap_usec / 1000.0, BenchCommon.format_stats(stats), " ".join(split)])
	var values := {"actors": world.get_colonists().size(), "swap ms": "%.2f" % (swap_usec / 1000.0)}
	values.merge(BenchCommon.stats_values(stats))
	values.merge(split_values)
	BenchCommon.row("bench_viewer_refresh", "refresh per tick", "%d actors" % actor_count, values)
	root.remove_child(boot)
	boot.free()

## boot._refresh()'s steps, each timed into `parts`: the one snapshot, then the
## four calls that read it.
func _time_parts(boot: Node, parts: Dictionary) -> void:
	var start := Time.get_ticks_usec()
	var snapshot: Dictionary = boot.world.get_view_snapshot(boot._ui_scroll.detail_ids())
	parts["snapshot"] = int(parts.get("snapshot", 0)) + Time.get_ticks_usec() - start
	var calls: Array[Callable] = [boot._map_view.refresh.bind(snapshot), boot._ui_scroll.refresh.bind(snapshot),
		boot._update_need_alerts_label.bind(snapshot), boot._refresh_room_label]
	for i in calls.size():
		start = Time.get_ticks_usec()
		calls[i].call()
		parts[PARTS[i + 1]] = int(parts.get(PARTS[i + 1], 0)) + Time.get_ticks_usec() - start

func _parse_args() -> Dictionary:
	var result := {"actors": DEFAULT_ACTORS, "ticks": DEFAULT_TICKS}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--actors="):
			var counts: Array = []
			for part in arg.substr(9).split(","):
				counts.append(int(part))
			result["actors"] = counts
		elif arg.begins_with("--ticks="):
			result["ticks"] = int(arg.substr(8))
	return result
