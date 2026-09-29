class_name HaulGiver
extends RefCounted

## Job-giver for haul (colonist-ai.md 3.3/3.4, issue #189): decides WHEN a
## haul job should exist -- one per unreserved loose item, every tick, no
## player command needed -- and where its stockpile destination is. Haul
## itself runs entirely through the toil executor once submitted (AGENTS.md
## "one work engine"); this module only ever calls into the same job_queue.gd
## entry points any order-driven job uses.

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

## priority is WorldState.HAUL_PRIORITY. get_jobs/get_items/get_zones/
## is_cell_free/passability must be WorldState's own public methods of the
## same name; is_in_any_zone/is_cell_occupied must be its like-named private
## methods. submit_job must be WorldState._scheduler.submit (the same entry
## point any order-driven job uses); attach_item must be
## WorldState._scheduler.queue.attach_item.
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

## Runs once per tick (WorldState.tick(), before the fair scheduler sees any
## colonist): submits one haul job for every loose item not already named by a
## queued/active haul job. "Unreserved" is derived statelessly from the job
## list itself, so a terminated job (complete/cancel/fail) makes its item
## eligible again next tick with no extra bookkeeping. An item already resting
## inside a stockpile zone is skipped outright: it is already stored (most
## likely by a haul job that has since completed and released its claim), and
## re-hauling it to a possibly-different free cell would only manufacture
## permanently unsatisfiable competition for the scheduler.
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

## Haul destination finder (colonist-ai.md 3.4): the first free, passable,
## unoccupied cell across every stockpile zone, in zone-id then row-major
## order for determinism (get_zones() is already sorted by zone id).
## Deliberately ignores item_id: any free cell suits any item in this slice.
## null when no zone has a free cell right now. Signature matches
## JobQueue.set_haul_destination_finder()'s expected Callable(item_id)->Variant.
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
