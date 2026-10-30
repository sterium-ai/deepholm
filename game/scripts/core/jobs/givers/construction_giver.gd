class_name ConstructionGiver
extends RefCounted

## Job-giver for construction sites (ADR 040): tops up site_fetch jobs while materials are
## short and site_work jobs once all are held, both capped together at max_builders, through
## the shared job queue. Each site_fetch carries one kind; a fresh one is submitted after the
## previous terminates (ADR 040, "Alternatives considered").

var _get_sites: Callable
var _get_jobs: Callable
var _get_items: Callable
var _is_in_any_zone: Callable
var _reservation_owner: Callable
var _submit_fetch: Callable
var _submit_work: Callable
var _materials_met: Callable
var _remaining: Callable

## Dependencies come from ConstructionSystem and sibling modules, never WorldState;
## get_jobs is the read-only JobQueue.view_jobs_of_kinds() (A5, never mutated).
func _init(get_sites: Callable, get_jobs: Callable, get_items: Callable, is_in_any_zone: Callable,
		reservation_owner: Callable, submit_fetch: Callable, submit_work: Callable,
		materials_met: Callable, remaining: Callable) -> void:
	_get_sites = get_sites
	_get_jobs = get_jobs
	_get_items = get_items
	_is_in_any_zone = is_in_any_zone
	_reservation_owner = reservation_owner
	_submit_fetch = submit_fetch
	_submit_work = submit_work
	_materials_met = materials_met
	_remaining = remaining

func _site_key(origin) -> String:
	if origin == null:
		return ""
	var tile: Vector3i = origin
	return TileGrid.comma_key(tile)

## Runs once per tick (TickPipeline). The submitted source is a position-agnostic seed:
## ConstructionSystem swaps it for the nearest reachable one when a colonist activates the job.
func advance(tick: int) -> void:
	var fetch_counts: Dictionary = {}
	var work_counts: Dictionary = {}
	var committed_items: Dictionary = {}
	for job in (_get_jobs.call() as Array):
		var kind := String(job.get("kind", ""))
		if kind != "site_fetch" and kind != "site_work":
			continue
		if not (String(job.get("status", "")) in ["queued", "active"]):
			continue
		var site: Variant = job.get("site")
		if site == null:
			continue
		var key := _site_key(site)
		if kind == "site_fetch":
			committed_items[String(job.get("item_id", ""))] = true
			fetch_counts[key] = int(fetch_counts.get(key, 0)) + 1
		else:
			work_counts[key] = int(work_counts.get(key, 0)) + 1
	for site in (_get_sites.call() as Array):
		var origin: Vector3i = site["origin"]
		var key := _site_key(origin)
			# Busy = fetch + work jobs holding this site's slots; never more than max_builders.
		var busy: int = int(fetch_counts.get(key, 0)) + int(work_counts.get(key, 0))
		if not bool(_materials_met.call(site)):
			for i in range(maxi(0, int(site["max_builders"]) - busy)):
				var choice := _choose_source(site, committed_items)
				if choice.is_empty():
					break
				var result: Dictionary = _submit_fetch.call(origin, String(choice["item_id"]), choice["tile"], tick)
				if not result.get("ok", false):
					break
				committed_items[String(choice["item_id"])] = true
				fetch_counts[key] = int(fetch_counts.get(key, 0)) + 1
				busy += 1
			continue
		for i in range(maxi(0, int(site["max_builders"]) - busy)):
			var result: Dictionary = _submit_work.call(origin, tick)
			if result.get("ok", false):
				work_counts[key] = int(work_counts.get(key, 0)) + 1

## Seed source: the lowest-id stockpiled, unreserved, uncommitted item of a still-needed
## material, in the site's declared order; {} when none qualifies.
func _choose_source(site: Dictionary, committed_items: Dictionary) -> Dictionary:
	for entry in (site["required_materials"] as Array):
		var kind := String(entry["item"])
		if int(_remaining.call(site, kind)) <= 0:
			continue
		var candidates: Array = []
		for item in (_get_items.call() as Array):
			if String(item["kind"]) != kind:
				continue
			var id := String(item["id"])
			if committed_items.has(id):
				continue
			if not bool(_is_in_any_zone.call(TileGrid.tile_of(item))):
				continue
			if not String(_reservation_owner.call(id)).is_empty():
				continue
			candidates.append(item)
		if candidates.is_empty():
			continue
		candidates.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
		var chosen: Dictionary = candidates[0]
		return {"item_id": String(chosen["id"]), "tile": TileGrid.tile_of(chosen)}
	return {}
