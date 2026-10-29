class_name FarmGiver
extends RefCounted

## Job-giver for farming (F1, ADR 059): a harvest job on every ripe crop, and on every farm
## zone tile a till (soil) or, while the zone crop's window is open and an unclaimed seed
## exists, a sow (plowed soil). The sow and harvest job kinds are the crop's own (crops.json
## sow_job/harvest_job), so their jobs.json effects consume that crop's seed, set its first
## stage and yield its produce. Execution is the toil executor's ("one work engine"); per-tile
## till/sow orders are untouched and count as claims, so a tile never gets a second job.
## Runs from FarmSystem.advance() (TickPipeline's "farming" phase), after the colonists moved.

const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")

const TILL_JOB := "till"
## The player's default order priority: farm work competes like a per-tile order.
const PRIORITY := JobQueueType.Priority.NORMAL

var _get_farm_zones: Callable
var _get_items: Callable
var _view_farm_jobs: Callable
var _submit: Callable
var _passability: Callable
var _get_tile: Callable
var _ripe_harvests: Callable
var _sow_open: Callable
var _sow_job_of: Callable
## sow job kind -> the items.json id it consumes (FarmSystem's, read-only).
var _sow_seeds: Dictionary

## get_farm_zones is ZoneTable.get_farm_zones; get_items ItemTable.get_items; view_farm_jobs the
## read-only JobQueue view of every farm job kind (never mutated); submit the scheduler's
## submit(target, priority, tick, kind); ripe_harvests, sow_open, sow_job_of and sow_seeds are
## FarmSystem's own queries and table.
func _init(get_farm_zones: Callable, get_items: Callable, view_farm_jobs: Callable, submit: Callable,
		passability: Callable, get_tile: Callable, ripe_harvests: Callable, sow_open: Callable, sow_job_of: Callable,
		sow_seeds: Dictionary) -> void:
	_get_farm_zones = get_farm_zones
	_get_items = get_items
	_view_farm_jobs = view_farm_jobs
	_submit = submit
	_passability = passability
	_get_tile = get_tile
	_ripe_harvests = ripe_harvests
	_sow_open = sow_open
	_sow_job_of = sow_job_of
	_sow_seeds = sow_seeds

## Harvests first (ripe tiles in key order), then each farm zone in id order, row-major.
## "Claimed" is derived from the live job list, so a finished or failed job frees its tile
## next tick; sows never outnumber the units of their seed on the ground, so none fails for
## want of one.
func advance(tick: int) -> void:
	var claimed: Dictionary = {}
	# seed item -> units promised to live sows.
	var promised: Dictionary = {}
	for job: Dictionary in (_view_farm_jobs.call() as Array):
		var status: String = job["status"]
		if status not in ["queued", "active"]:
			continue
		claimed[job["target"]] = true
		var seed_kind: String = _sow_seeds.get(job["kind"], "")
		if not seed_kind.is_empty():
			var so_far: int = promised.get(seed_kind, 0)
			promised[seed_kind] = so_far + 1
	for harvest: Array in (_ripe_harvests.call() as Array):
		var tile: Vector2i = harvest[0]
		var harvest_job: String = harvest[1]
		if not claimed.has(tile):
			_submit_at(tile, tick, harvest_job, claimed)
	var zones: Array = _get_farm_zones.call()
	if zones.is_empty():
		return
	# seed item -> ground units not yet promised to a live sow.
	var free_seeds := _ground_units()
	for seed_kind: String in promised.keys():
		var units: int = free_seeds.get(seed_kind, 0)
		var taken: int = promised[seed_kind]
		free_seeds[seed_kind] = units - taken
	for zone: Dictionary in zones:
		_advance_zone(zone, tick, claimed, free_seeds)

## One farm zone's tills and (while its crop's window is open) sows of its crop, row-major.
func _advance_zone(zone: Dictionary, tick: int, claimed: Dictionary, free_seeds: Dictionary) -> void:
	var crop: String = zone["crop"]
	var sow_job: String = _sow_job_of.call(crop)
	var seed_kind: String = _sow_seeds.get(sow_job, "")
	var may_sow: bool = not sow_job.is_empty() and _sow_open.call(crop, tick)
	var zone_x: int = zone["x"]
	var zone_y: int = zone["y"]
	var width: int = zone["width"]
	var height: int = zone["height"]
	var rect := Rect2i(zone_x, zone_y, width, height)
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var tile := Vector2i(x, y)
			if claimed.has(tile):
				continue
			var kind: String = _get_tile.call(x, y)
			if kind == ContentRegistry.TILE_SOIL:
				var passability: Dictionary = _passability.call(x, y)
				if passability["passable"]:
					_submit_at(tile, tick, TILL_JOB, claimed)
			elif kind == ContentRegistry.TILE_PLOWED_SOIL and may_sow:
				var units: int = free_seeds.get(seed_kind, 0)
				if units > 0 and _submit_at(tile, tick, sow_job, claimed):
					free_seeds[seed_kind] = units - 1

func _submit_at(tile: Vector2i, tick: int, kind: String, claimed: Dictionary) -> bool:
	var result: Dictionary = _submit.call(tile, PRIORITY, tick, kind)
	if result.get("ok", false):
		claimed[tile] = true
		return true
	return false

## item kind -> ground units (stockpiled or loose); carried units are not counted.
func _ground_units() -> Dictionary:
	var units: Dictionary = {}
	for item: Dictionary in (_get_items.call() as Array):
		var kind: String = item["kind"]
		var count: int = item["count"]
		var so_far: int = units.get(kind, 0)
		units[kind] = so_far + count
	return units
