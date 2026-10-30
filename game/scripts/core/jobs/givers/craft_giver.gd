class_name CraftGiver
extends RefCounted

## Job-giver for workbench production (F2, ADR 061), once per tick in TickPipeline's
## craft_giver phase. Stocks crafted tools lying in a stockpile, lets CraftingSystem update its
## bills (bench gone, bill abandoned, next bill chosen), then per bench with a bill: one
## craft_fetch at a time while its inputs are short (labour haul; site_fetch's toils, activation
## and reservations through JobQueue.FETCH_KINDS) and one craft_work once all are held (labour
## craft, at the bench origin). Persists nothing: what is in flight is read back from the job
## queue every tick.

const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const CraftingSystemType = preload("res://scripts/core/crafting/crafting_system.gd")

var _crafting: CraftingSystemType
## The read-only JobQueue.view_jobs_of_kinds() (A5, never mutated).
var _view_jobs_of_kinds: Callable
## (target, priority, tick, kind, restrict_to) -> {ok, job_id}: GlobalAssignment.submit().
var _submit: Callable
var _attach_item: Callable
var _attach_site: Callable

func _init(crafting: CraftingSystemType, view_jobs_of_kinds: Callable, submit: Callable,
		attach_item: Callable, attach_site: Callable) -> void:
	_crafting = crafting
	_view_jobs_of_kinds = view_jobs_of_kinds
	_submit = submit
	_attach_item = attach_item
	_attach_site = attach_site

func advance(tick: int) -> void:
	_crafting.stock_tools()
	var committed: Dictionary = {}
	var fetching: Dictionary = {}
	var working: Dictionary = {}
	var kinds: Array = JobQueueType.FETCH_KINDS + ["craft_work"]
	for job: Dictionary in (_view_jobs_of_kinds.call(kinds) as Array):
		if not (job["status"] in ["queued", "active"]):
			continue
		var kind: String = job["kind"]
		var site: Variant = job.get("site")
		if kind in JobQueueType.FETCH_KINDS:
			committed[job["item_id"]] = true
		if kind == "craft_fetch" and site is Vector2i:
			var bench_tile: Vector2i = site
			fetching[CraftingSystemType.bench_key(bench_tile)] = true
		elif kind == "craft_work":
			var target: Vector2i = job["target"]
			working[CraftingSystemType.bench_key(target)] = true
	_crafting.update_bills(committed, fetching)
	for key: String in _crafting.bench_keys():
		var record := _crafting.bench_record(key)
		var bill: Dictionary = record["bill"]
		if bill.is_empty() or fetching.has(key) or working.has(key):
			continue
		var origin: Vector2i = record["origin"]
		if _crafting.bill_met(bill):
			_submit.call(origin, JobQueueType.Priority.NORMAL, tick, "craft_work", "")
			continue
		_submit_fetch(origin, bill, committed, tick)

## One craft_fetch for the first still-short input that has a free stockpiled source.
func _submit_fetch(origin: Vector2i, bill: Dictionary, committed: Dictionary, tick: int) -> void:
	var recipe_id: String = bill["recipe"]
	for stack: Dictionary in _crafting.recipes.inputs(recipe_id):
		var item: String = stack["item"]
		if _crafting.remaining(origin, item) <= 0:
			continue
		var source := _crafting.source_of(item, committed)
		if source.is_empty():
			continue
		var source_id: String = source["id"]
		var x: int = source["x"]
		var y: int = source["y"]
		var result: Dictionary = _submit.call(Vector2i(x, y), JobQueueType.Priority.NORMAL, tick, "craft_fetch", "")
		if result.get("ok", false):
			var job_id: String = result["job_id"]
			_attach_item.call(job_id, source_id)
			_attach_site.call(job_id, origin)
			committed[source_id] = true
		return
