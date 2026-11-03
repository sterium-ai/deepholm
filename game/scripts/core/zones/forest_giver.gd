class_name ForestGiver
extends RefCounted

## Job-giver for forest zones (F6a, ADR 067): on every forest zone tile that is passable soil
## and not claimed by a live farm job, the forest's plant job (labour farm, no seed). A chopped
## tree leaves soil (chop's set_tile), so the next tick replants it. Execution is the toil
## executor's; felling stays the manual chop. Run by FarmSystem.advance() (TickPipeline's
## "farming" phase) after FarmGiver, zones in id order, row-major, like FarmGiver.

const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")

## The player's default order priority, as FarmGiver.
const PRIORITY := JobQueueType.Priority.NORMAL

var _get_forest_zones: Callable
var _view_farm_jobs: Callable
var _submit: Callable
var _passability: Callable
var _get_tile: Callable
var _plant_job: String

## get_forest_zones is ZoneTable.get_forest_zones; view_farm_jobs FarmSystem's read-only view of
## every farm job kind (planting included); submit the scheduler's submit(target, priority, tick,
## kind); plant_job the planted forest's jobs.json kind ("" plants nothing).
func _init(get_forest_zones: Callable, view_farm_jobs: Callable, submit: Callable, passability: Callable,
		get_tile: Callable, plant_job: String) -> void:
	_get_forest_zones = get_forest_zones
	_view_farm_jobs = view_farm_jobs
	_submit = submit
	_passability = passability
	_get_tile = get_tile
	_plant_job = plant_job

func advance(tick: int) -> void:
	if _plant_job.is_empty() or not _get_forest_zones.is_valid():
		return
	var zones: Array = _get_forest_zones.call()
	if zones.is_empty():
		return
	# "Claimed" is derived from the live job list, so a finished or failed job frees its tile.
	var claimed: Dictionary = {}
	for job: Dictionary in (_view_farm_jobs.call() as Array):
		if job["status"] in ["queued", "active"]:
			claimed[job["target"]] = true
	for zone: Dictionary in zones:
		var origin := TileGrid.tile_of(zone)
		var width: int = zone["width"]
		var height: int = zone["height"]
		var rect := Rect2i(origin.x, origin.y, width, height)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var tile := Vector3i(x, y, origin.z)
				if claimed.has(tile) or _get_tile.call(tile) != ContentRegistry.TILE_SOIL:
					continue
				var passability: Dictionary = _passability.call(tile)
				if not passability["passable"]:
					continue
				var result: Dictionary = _submit.call(tile, PRIORITY, tick, _plant_job)
				if result.get("ok", false):
					claimed[tile] = true
