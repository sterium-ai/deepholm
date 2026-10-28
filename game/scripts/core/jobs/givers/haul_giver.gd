class_name HaulGiver
extends RefCounted

## Job-giver for haul (colonist-ai.md 3.3/3.4): one haul job per unreserved loose item and
## its stockpile destination; execution is the toil executor's ("one work engine").

var _priority: int
var _get_jobs: Callable
var _get_items: Callable
var _is_in_any_zone: Callable
var _submit_job: Callable
var _attach_item: Callable
var _get_zones: Callable
var _is_cell_free: Callable
var _passability: Callable
var _is_cell_occupied: Callable

## priority comes from jobs.json; get_jobs is the read-only JobQueue.view_jobs_of_kinds(["haul"])
## (A5, never mutated); is_in_any_zone is ZoneTable's; the rest are WorldState/scheduler entry points.
func _init(priority: int, get_jobs: Callable, get_items: Callable, is_in_any_zone: Callable,
		submit_job: Callable, attach_item: Callable, get_zones: Callable, is_cell_free: Callable,
		passability: Callable, is_cell_occupied: Callable) -> void:
	_priority = priority
	_get_jobs = get_jobs
	_get_items = get_items
	_is_in_any_zone = is_in_any_zone
	_submit_job = submit_job
	_attach_item = attach_item
	_get_zones = get_zones
	_is_cell_free = is_cell_free
	_passability = passability
	_is_cell_occupied = is_cell_occupied

## Runs once per tick (TickPipeline, before the scheduler). "Unreserved" is derived from the
## job list, so a terminated job frees its item next tick; items already in a zone are skipped.
func advance(tick: int) -> void:
	var claimed: Dictionary = {}
	for job in (_get_jobs.call() as Array):
		if String(job["kind"]) == "haul" and job["status"] in ["queued", "active"]:
			claimed[String(job["item_id"])] = true
	for item in (_get_items.call() as Array):
		var item_id: String = item["id"]
		if claimed.has(item_id):
			continue
		var x: int = int(item["x"])
		var y: int = int(item["y"])
		if bool(_is_in_any_zone.call(x, y)):
			continue
		var result: Dictionary = _submit_job.call(Vector2i(x, y), _priority, tick, "haul")
		if result.get("ok", false):
			_attach_item.call(String(result["job_id"]), item_id)

## First free, passable, unoccupied cell in zone-id then row-major order (deterministic),
## or null. Ignores item_id; matches JobQueue.set_haul_destination_finder()'s Callable.
func find_free_haul_cell(_item_id: String) -> Variant:
	for zone in (_get_zones.call() as Array):
		for y in range(int(zone["y"]), int(zone["y"]) + int(zone["height"])):
			for x in range(int(zone["x"]), int(zone["x"]) + int(zone["width"])):
				if not bool(_is_cell_free.call(x, y)):
					continue
				if not bool((_passability.call(x, y) as Dictionary)["passable"]):
					continue
				if bool(_is_cell_occupied.call(x, y, "")):
					continue
				return Vector2i(x, y)
	return null
