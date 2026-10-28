extends SceneTree

## A0 benchmark: tick cost against job count at a fixed actor count
## (10 colonists, generated 256x256 seed-42 map), in two parts.
##   retention - a long session that keeps the open backlog small (topped up
##               to OPEN_TARGET queued/active till orders every ORDER_EVERY
##               ticks), so only finished jobs accumulate. Every WINDOW ticks
##               it prints the window's mean tick time, its slowest phases,
##               and the sizes of the job and log structures: JobQueue._jobs
##               (live jobs, plus terminal ones not yet compacted away), its
##               retained terminal history (A5, job_history.gd; before A5 every
##               terminal job stayed in _jobs), JobQueue._events,
##               EventLog._events and TileGrid.dirty_cells.
##   backlog   - fresh worlds with Q open till orders at once (a player
##               designating a large field), BACKLOG_TICKS ticks each.
## Ticks run through BenchCommon.profiled_tick() (same calls as
## WorldState.tick(), see bench_tick_scaling.gd for the hash check).
##
## Evidence, not a gate: always exits 0. Run:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_long_session.gd

const BenchCommon = preload("res://scripts/tests/bench_common.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const SEED := 42
const SIZE := 256
const ACTORS := 10
const TOTAL_TICKS := 6000
const WINDOW := 1000
const ORDER_EVERY := 25
const OPEN_TARGET := 20
const BACKLOG_SIZES := [0, 100, 500, 2000]
const BACKLOG_TICKS := 50

var _order_serial := 0

func _init() -> void:
	print(BenchCommon.header("bench_long_session"))
	_retention()
	for size in BACKLOG_SIZES:
		_backlog(int(size))
	print("bench_long_session: done")
	quit(0)

func _retention() -> void:
	var world := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, ACTORS)
	var candidates := _candidates(world)
	var cursor := 0
	var window_usec := 0
	var totals: Dictionary = {}
	for tick in range(1, TOTAL_TICKS + 1):
		if tick % ORDER_EVERY == 1:
			cursor = _submit(world, candidates, cursor, OPEN_TARGET - _open_jobs(world))
		var t := Time.get_ticks_usec()
		BenchCommon.profiled_tick(world, totals)
		window_usec += Time.get_ticks_usec() - t
		if tick % WINDOW == 0:
			var jobs: Array = TestAccess.queue_jobs(world)
			var retained: int = TestAccess.queue_history(world).size()
			print("bench_long_session: retention ticks=%d mean_tick=%.2fms queue_jobs=%d (open=%d terminal=%d) queue_events=%d world_events=%d dirty_cells=%d top_phases: %s" % [
				tick, window_usec / 1000.0 / WINDOW, jobs.size(), _open_jobs(world), retained,
				TestAccess.queue_events(world).size(), TestAccess.event_log_events(world).size(), TestAccess.tile_grid(world).dirty_cells.size(),
				_top_phases(totals, WINDOW)])
			BenchCommon.row("bench_long_session", "retention", "ticks=%d" % tick, {
				"mean tick ms": "%.2f" % (window_usec / 1000.0 / WINDOW), "queue jobs": jobs.size(),
				"open": _open_jobs(world), "terminal": retained,
				"queue events": TestAccess.queue_events(world).size(), "world events": TestAccess.event_log_events(world).size(),
				"dirty cells": TestAccess.tile_grid(world).dirty_cells.size(), "top phases (ms/tick)": _top_phases(totals, WINDOW)})
			window_usec = 0
			totals = {}

func _backlog(size: int) -> void:
	var world := BenchCommon.world_with_colonists(SEED, SIZE, SIZE, ACTORS)
	var candidates := _candidates(world)
	_submit(world, candidates, 0, size)
	world.tick() # tick 1 pays the lazy region build; not measured
	var totals: Dictionary = {}
	var samples: Array = []
	for i in BACKLOG_TICKS:
		var t := Time.get_ticks_usec()
		BenchCommon.profiled_tick(world, totals)
		samples.append(Time.get_ticks_usec() - t)
	var stats := BenchCommon.stats_ms(samples)
	print("bench_long_session: backlog open_orders=%d actors=%d tick %s top_phases: %s" % [size, ACTORS,
		BenchCommon.format_stats(stats), _top_phases(totals, BACKLOG_TICKS)])
	var values := {"actors": ACTORS}
	values.merge(BenchCommon.stats_values(stats))
	values["top phases (ms/tick)"] = _top_phases(totals, BACKLOG_TICKS)
	BenchCommon.row("bench_long_session", "backlog", "open_orders=%d" % size, values)

func _candidates(world: WorldStateType) -> Array[Vector2i]:
	var origin := Vector2i(int(TestAccess.colonists(world)[0]["x"]), int(TestAccess.colonists(world)[0]["y"]))
	return BenchCommon.passable_tiles_from(world, origin, 30000)

## Submits up to `count` till orders on the next soil tiles of `candidates`;
## returns the new cursor.
func _submit(world: WorldStateType, candidates: Array[Vector2i], cursor: int, count: int) -> int:
	var accepted := 0
	while accepted < count and cursor < candidates.size():
		var tile: Vector2i = candidates[cursor]
		cursor += 1
		if world.get_tile(tile.x, tile.y) != WorldStateType.TILE_SOIL:
			continue
		_order_serial += 1
		var result := BenchCommon.command(world, "till_%d" % _order_serial, "till", {"x": tile.x, "y": tile.y, "priority": 1})
		if bool(result.get("ok", false)):
			accepted += 1
	return cursor

func _open_jobs(world: WorldStateType) -> int:
	var open := 0
	for job in TestAccess.queue_jobs(world):
		if ["queued", "active"].has(String(job.get("status", ""))):
			open += 1
	return open

## The three slowest phases, in ms per tick.
func _top_phases(totals: Dictionary, tick_count: int) -> String:
	var rows: Array = []
	for phase in totals:
		rows.append([int(totals[phase]), String(phase)])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	var parts: Array[String] = []
	for i in mini(3, rows.size()):
		parts.append("%s=%.2f" % [rows[i][1], rows[i][0] / 1000.0 / tick_count])
	return " ".join(parts)
