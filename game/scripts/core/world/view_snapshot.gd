extends RefCounted

## The viewer's one read-only snapshot per refresh (A9, ADR 055), built by
## WorldState.get_view_snapshot(detail_ids). It replaces the several deep-copying
## getters each panel and layer used to call every tick (get_colonists() alone copied
## every actor three to five times per tick). Copying every actor once is still too
## slow at 1,000 actors, so the per-actor facts the map and the lists need are
## columns (read-only Arrays of one type each; a reader assigns one to the matching
## Packed*Array variable to get its own fast copy), and the full actor record is
## copied only for the `detail_ids` the panels ask for. Every Dictionary and Array in it is read-only. Never persisted,
## never hashed. Keys:
##   tick             int
##   date             {day, month, year, window_label}: CalendarService.date_of_tick(tick)
##                    of the world's own calendar (F0, ADR 056)
##   ids              String column, every actor in actor-table order; row i of
##                    every column below is ids[i]
##   kinds, factions  String columns: "kind", "factionId" ("colony" when absent)
##   x, y             int columns
##   worker           int column, 1 for an actor with a worker component
##                    (the get_colonists() roster)
##   carrying         String column, the carried kind (ADR 037 "carrying" view) or ""
##   tool_kinds       String column, the held tool item's kind or ""
##   trapped          int column, 1 while "trapped" is set
##   work_kinds       String column, the kind of the job "work" names, or ""
##   hp, max_hp       int columns, -1 for an actor whose "health" is not a Dictionary
##   workers_by_id    int column, the rows of the workers sorted by id
##   need_reasons     {id: get_colonist_need_reason()}, "" or absent when none
##   details          {id: get_colonists()-shaped frozen copy} for each requested
##                    worker id that exists
##   jobs             {job_id: get_job()} for every job a detailed worker's
##                    assignment, route, work or pending need job names
##   need_job_ids     {detailed id: get_active_need_job_id()}, non-empty only
##   rescue_reasons   {detailed trapped id: get_colonist_rescue_reason()}
##   assignments      the detailed workers' entries of get_assignments()
##   queued_job_summary, tool_items, items, construction_sites, zones,
##   pending_trade_offers   the getters of the same name, called once

const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")

## `actors` is the live actor table, read and never written. `sources` holds the
## live read-only views job_kinds ({job id: kind}) and need_status ({id: reason}), the
## Callables get_job, need_job_id and rescue_reason (WorldState's getters) and the world's
## CalendarService as calendar; `parts` the already-copied collections listed above.
static func build(tick: int, actors: Array, content: ContentRegistryType, sources: Dictionary, parts: Dictionary,
		detail_ids: Array) -> Dictionary:
	var calendar: CalendarServiceType = sources["calendar"]
	var snapshot := {"tick": tick, "date": calendar.date_of_tick(tick)}
	snapshot.merge(parts)
	# The tool store records which worker holds each tool (location "held"), so the
	# tool_kinds column needs no per-actor read of the worker's held_tool.
	var held_kinds := {}
	for tool_item: Dictionary in parts["tool_items"]:
		var location: Dictionary = tool_item["location"]
		if location.get("type") == "held":
			var holder: String = location["colonist_id"]
			held_kinds[holder] = tool_item["kind"]
	var job_kinds: Dictionary = sources["job_kinds"]
	_add_columns(snapshot, actors, content, job_kinds, held_kinds)
	var need_reasons: Dictionary = (sources["need_status"] as Dictionary).duplicate()
	need_reasons.make_read_only() # flat strings: freeze() need not walk it
	snapshot["need_reasons"] = need_reasons
	_add_details(snapshot, actors, content, detail_ids, sources)
	return freeze(snapshot)

static func _add_columns(snapshot: Dictionary, actors: Array, content: ContentRegistryType, job_kinds: Dictionary,
		held_kinds: Dictionary) -> void:
	var ids := PackedStringArray()
	var kinds := PackedStringArray()
	var factions := PackedStringArray()
	var xs := PackedInt32Array()
	var ys := PackedInt32Array()
	var worker := PackedByteArray()
	var carrying := PackedStringArray()
	var tools := PackedStringArray()
	var trapped := PackedByteArray()
	var work_kinds := PackedStringArray()
	var hp := PackedInt32Array()
	var max_hp := PackedInt32Array()
	var worker_kinds := {} # kind -> has a worker component, looked up once per kind
	var last_kind := ""
	var is_worker := false
	var anyone_holds := not held_kinds.is_empty()
	# Hot loop (every actor, every refresh): one read per field, no copies.
	for actor: Dictionary in actors:
		var id: String = actor["id"]
		var kind: String = actor.get("kind", "")
		var faction: String = actor.get("factionId", "colony")
		var x: int = actor["x"]
		var y: int = actor["y"]
		ids.append(id)
		kinds.append(kind)
		factions.append(faction)
		xs.append(x)
		ys.append(y)
		if kind != last_kind or ids.size() == 1: # runs of one kind skip the lookup
			if not worker_kinds.has(kind):
				worker_kinds[kind] = ActorTableType.has_component(actor, "worker", content)
			is_worker = worker_kinds[kind]
			last_kind = kind
		worker.append(1 if is_worker else 0)
		var hands: Variant = actor.get("hands")
		var carried: String = hands[0]["kind"] if hands else ""
		carrying.append(carried)
		var tool_kind: String = held_kinds.get(id, "") if anyone_holds and is_worker else ""
		tools.append(tool_kind)
		trapped.append(0 if actor.get("trapped") == null else 1)
		var work: Variant = actor.get("work")
		var work_kind: String = job_kinds.get(work["job_id"], "") if work != null else ""
		work_kinds.append(work_kind)
		var health: Variant = actor.get("health")
		if health is Dictionary:
			var health_component: Dictionary = health
			var current: int = health_component.get("hp", 0)
			var most: int = health_component.get("maxHp", 1)
			hp.append(current)
			max_hp.append(most)
		else:
			hp.append(-1)
			max_hp.append(-1)
	# A Packed*Array is shared by reference, and cannot be frozen: each column is
	# stored as a read-only Array (a native copy), which a reader typing it as the
	# Packed*Array converts back into its own copy.
	snapshot.merge({"ids": _frozen(Array(ids)), "kinds": _frozen(Array(kinds)), "factions": _frozen(Array(factions)),
		"x": _frozen(Array(xs)), "y": _frozen(Array(ys)), "worker": _frozen(Array(worker)),
		"carrying": _frozen(Array(carrying)), "tool_kinds": _frozen(Array(tools)), "trapped": _frozen(Array(trapped)),
		"work_kinds": _frozen(Array(work_kinds)), "hp": _frozen(Array(hp)), "max_hp": _frozen(Array(max_hp)),
		"workers_by_id": _frozen(Array(_workers_by_id(ids, worker)))})

static func _frozen(column: Array) -> Array:
	column.make_read_only()
	return column

## The memo of _workers_by_id(): a pure function of the ids and worker columns, so
## sharing it between worlds is safe; it saves a sort of the roster on every refresh.
static var _memo_ids := PackedStringArray()
static var _memo_worker := PackedByteArray()
static var _memo_order := PackedInt32Array()
## The worker ids sorted, row-aligned with _memo_order, for _worker_row().
static var _memo_sorted := PackedStringArray()

## The rows of the workers, sorted by id.
static func _workers_by_id(ids: PackedStringArray, worker: PackedByteArray) -> PackedInt32Array:
	if ids == _memo_ids and worker == _memo_worker:
		return _memo_order
	var rows := {}
	for row in ids.size():
		if worker[row] == 1:
			rows[ids[row]] = row
	var sorted_ids := PackedStringArray(rows.keys())
	sorted_ids.sort()
	var order := PackedInt32Array()
	for id in sorted_ids:
		var row: int = rows[id]
		order.append(row)
	_memo_ids = ids
	_memo_worker = worker
	_memo_order = order
	_memo_sorted = sorted_ids
	return order

## The row of worker `id` in the columns _workers_by_id() last sorted, or -1.
static func _worker_row(id: String) -> int:
	var index := _memo_sorted.bsearch(id)
	if index < _memo_sorted.size() and _memo_sorted[index] == id:
		return _memo_order[index]
	return -1

static func _add_details(snapshot: Dictionary, actors: Array, content: ContentRegistryType, detail_ids: Array,
		sources: Dictionary) -> void:
	var get_job: Callable = sources["get_job"]
	var need_job_of: Callable = sources["need_job_id"]
	var rescue_reason_of: Callable = sources["rescue_reason"]
	var details := {}
	var jobs := {}
	var need_job_ids := {}
	var rescue_reasons := {}
	# get_assignments()' full copy serves the job lookups; the snapshot keeps only the
	# detailed workers' entries, which is all the panels read (and all that is frozen).
	var assignments: Dictionary = snapshot["assignments"]
	var detailed_assignments := {}
	for wanted: Variant in detail_ids:
		var id: String = wanted
		var row := _worker_row(id) # _add_columns() just sorted this snapshot's workers
		if row < 0 or details.has(id):
			continue
		var actor: Dictionary = actors[row]
		details[id] = actor_copy(actor)
		var job_ids: Array[String] = []
		if assignments.has(id):
			var assignment: Dictionary = assignments[id]
			detailed_assignments[id] = assignment
			var assigned_job: String = assignment["job_id"]
			job_ids.append(assigned_job)
		# The route through the mover component (ADR 012); "work" is ToilExecutor's own field.
		var mover: Variant = ActorTableType.get_component(actor, "mover", content)
		var route: Variant = (mover as Dictionary).get("route") if mover is Dictionary else null
		for leg: Variant in [route, actor.get("work")]:
			if leg is Dictionary:
				var leg_fields: Dictionary = leg
				var leg_job: String = leg_fields.get("job_id", "")
				job_ids.append(leg_job)
		var need_job_id: String = need_job_of.call(id)
		if not need_job_id.is_empty():
			need_job_ids[id] = need_job_id
			job_ids.append(need_job_id)
		if actor.get("trapped") != null:
			var rescue_reason: String = rescue_reason_of.call(id)
			rescue_reasons[id] = rescue_reason
		for job_id in job_ids:
			if not job_id.is_empty() and not jobs.has(job_id):
				jobs[job_id] = get_job.call(job_id, assignments) # one assignments copy for every job
	snapshot.merge({"details": details, "jobs": jobs, "need_job_ids": need_job_ids, "rescue_reasons": rescue_reasons,
		"assignments": detailed_assignments}, true)

## One actor as get_colonists() shows it: a deep copy plus the "carrying" view.
static func actor_copy(actor: Dictionary) -> Dictionary:
	var entry: Dictionary = actor.duplicate(true)
	entry["carrying"] = carrying_view(actor)
	return entry

## ADR 037: the single-slot "carrying" view of "hands" for the viewer; exists only on
## the copies, never persisted or hashed.
static func carrying_view(actor: Dictionary) -> Variant:
	if not InventoryType.is_carrying(actor):
		return null
	var first: Dictionary = InventoryType.hands_snapshot(actor)[0]
	return {"kind": first["kind"], "count": first["count"]}

## Makes `value` and every Dictionary/Array inside it read-only, in place; a
## container that is already read-only (an entry shared by two lists) is skipped.
static func freeze(value: Variant) -> Variant:
	if value is Dictionary:
		var dict: Dictionary = value
		if not dict.is_read_only():
			for item: Variant in dict.values():
				if item is Dictionary or item is Array:
					freeze(item)
			dict.make_read_only()
	elif value is Array:
		var list: Array = value
		if not list.is_read_only():
			for item: Variant in list:
				if item is Dictionary or item is Array:
					freeze(item)
			list.make_read_only()
	return value
