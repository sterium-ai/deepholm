extends RefCounted

## Shared helpers for the headless bench_*.gd benchmarks (A0 foundation audit,
## docs/architecture/foundation-audit.md). Benchmarks are evidence, not a gate:
## they print numbers and exit 0 (bench_tick_scaling exits 1 only if its own
## profiled/real state_hash() check fails). They are named bench_*.gd so
## tools/run_tests.* (which only globs test_*.gd) never runs them.
##
## Run all of them, and rewrite docs/architecture/bench-baseline.md, with:
##   tools\run_benches.ps1
## Run one with:
##   & $env:GODOT --headless --path game --script res://scripts/tests/bench_tick_scaling.gd

const WorldStateType = preload("res://scripts/core/world_state.gd")

const TickPipelineType = preload("res://scripts/core/world/tick_pipeline.gd")

## Phase names of profiled_tick(), in WorldState.tick()'s own order.
const PHASES: Array[String] = TickPipelineType.PHASES

static func header(bench_name: String) -> String:
	var info := Engine.get_version_info()
	return "%s: commit=%s godot=%s os=%s cpu=%s threads=%d" % [bench_name, commit_hash(),
		info.get("string", "?"), OS.get_name(), OS.get_processor_name(), OS.get_processor_count()]

static func commit_hash() -> String:
	var output := []
	var exit_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], output)
	if exit_code == 0 and not output.is_empty():
		return String(output[0]).strip_edges()
	return "unknown"

## Mean / p50 / p95 / max (milliseconds) of a list of microsecond samples.
static func stats_ms(samples_usec: Array) -> Dictionary:
	if samples_usec.is_empty():
		return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0, "n": 0}
	var sorted := samples_usec.duplicate()
	sorted.sort()
	var total := 0
	for s in sorted:
		total += int(s)
	return {
		"mean": total / 1000.0 / sorted.size(),
		"p50": int(sorted[sorted.size() / 2]) / 1000.0,
		"p95": int(sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))]) / 1000.0,
		"max": int(sorted[sorted.size() - 1]) / 1000.0,
		"n": sorted.size(),
	}

static func format_stats(stats: Dictionary) -> String:
	return "mean=%.2fms p50=%.2fms p95=%.2fms max=%.2fms n=%d" % [stats["mean"], stats["p50"],
		stats["p95"], stats["max"], stats["n"]]

## stats_ms() as row() columns, formatted like format_stats(); `prefix` names
## the series when a row carries two (e.g. "real " and "profiled ").
static func stats_values(stats: Dictionary, prefix: String = "") -> Dictionary:
	return {
		prefix + "mean ms": "%.2f" % stats["mean"], prefix + "p50 ms": "%.2f" % stats["p50"],
		prefix + "p95 ms": "%.2f" % stats["p95"], prefix + "max ms": "%.2f" % stats["max"],
		prefix + "n": stats["n"],
	}

## Machine-readable twin of a "bench_*:" result line, for tools/run_benches.ps1,
## which turns them into the tables of docs/architecture/bench-baseline.md
## (one table per `table` name, one row per call). Printed as "@row <json>" so
## that filters on "^bench_" keep only the human lines. `values` keeps its
## insertion order, which becomes the column order; floats are passed already
## formatted as strings so the table shows the same digits as the line.
static func row(bench_name: String, table: String, case_label: String, values: Dictionary) -> void:
	print("@row " + JSON.stringify({"bench": bench_name, "table": table, "case": case_label, "values": values}, "", false))

## Passable tiles in breadth-first order from `origin` (4-neighbour, the
## colony's own passability rule), skipping tiles that already hold an
## actor. Used to seat N actors around the generated spawn clearing.
static func passable_tiles_from(world: WorldStateType, origin: Vector2i, count: int) -> Array[Vector2i]:
	var occupied: Dictionary = {}
	for actor in TestAccess.colonists(world):
		occupied[Vector2i(int(actor["x"]), int(actor["y"]))] = true
	var result: Array[Vector2i] = []
	var seen: Dictionary = {origin: true}
	var frontier: Array[Vector2i] = [origin]
	var head := 0
	while head < frontier.size() and result.size() < count:
		var tile: Vector2i = frontier[head]
		head += 1
		if not occupied.has(tile):
			result.append(tile)
		for step in [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
			var next: Vector2i = tile + step
			if seen.has(next):
				continue
			seen[next] = true
			if bool(world.passability(next.x, next.y)["passable"]):
				frontier.append(next)
	return result

## A generated world (WorldState.new(seed, 10, width, height)) whose roster
## is replaced by `actor_count` colonists cloned from the generator's own
## colonist_0 (so every field and key order is the real spawn shape), seated
## on distinct passable tiles around the spawn clearing.
static func world_with_colonists(seed_value: int, width: int, height: int, actor_count: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10, width, height)
	var template: Dictionary = TestAccess.colonists(world)[0].duplicate(true)
	var origin := Vector2i(int(template["x"]), int(template["y"]))
	TestAccess.colonists(world).clear()
	var tiles := passable_tiles_from(world, origin, actor_count)
	for i in tiles.size():
		var colonist: Dictionary = template.duplicate(true)
		colonist["id"] = "colonist_%d" % i
		colonist["x"] = tiles[i].x
		colonist["y"] = tiles[i].y
		TestAccess.colonists(world).append(colonist)
	return world

static func command(world: WorldStateType, command_id: String, type: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "bench", "command_id": command_id, "tick": world.get_tick(),
		"type": type, "payload": payload})

## Submits up to `count` till orders on soil tiles nearest the colonists
## (breadth-first from colonist_0), so every colonist has a reachable,
## tool-free job. Returns the number accepted.
static func submit_till_orders(world: WorldStateType, count: int) -> int:
	var prefix := "till_t%d" % world.get_tick()
	var origin := Vector2i(int(TestAccess.colonists(world)[0]["x"]), int(TestAccess.colonists(world)[0]["y"]))
	var accepted := 0
	var candidates := passable_tiles_from(world, origin, count * 4 + 64)
	for tile in candidates:
		if accepted >= count:
			break
		if world.get_tile(tile.x, tile.y) != WorldStateType.TILE_SOIL:
			continue
		var result := command(world, "%s_%d" % [prefix, accepted], "till", {"x": tile.x, "y": tile.y, "priority": 1})
		if bool(result.get("ok", false)):
			accepted += 1
	return accepted

## WorldState.tick() with a timer around each phase: runs the world's own
## TickPipeline phases (game/scripts/core/world/tick_pipeline.gd) in order, so
## it cannot drift from tick(); bench_tick_scaling.gd still compares
## state_hash() against a twin world advanced with the real tick(). Adds the
## elapsed microseconds per phase into `totals`.
static func profiled_tick(world: WorldStateType, totals: Dictionary) -> void:
	var phases: Array[Callable] = TestAccess.tick_pipeline(world).phases()
	var t := Time.get_ticks_usec()
	for i in phases.size():
		phases[i].call()
		t = _lap(totals, PHASES[i], t)

static func _lap(totals: Dictionary, phase: String, since: int) -> int:
	var now := Time.get_ticks_usec()
	totals[phase] = int(totals.get(phase, 0)) + (now - since)
	return now
