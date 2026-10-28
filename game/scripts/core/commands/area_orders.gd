class_name AreaOrders
extends RefCounted

## The `area_order` command and its saved expansion queue (ADR 044, B1).
## Dragging an order over a large rectangle used to submit one command per
## tile in a single frame: a whole 256x256 map took seconds of one frame even
## after every per-command cost was made O(1). An area_order names the
## rectangle instead, and is expanded -- in row-major order, through the very
## same per-tile command apply() runs for a single click -- TILES_PER_STEP of
## its own tiles at acceptance, then TILES_PER_STEP tiles at the start of
## every tick for the pending orders, first-in first-out, until done. Nothing
## here reads wall-clock time: the pace is fixed per tick, so the same seed and
## command stream expand identically.
##
## Invariants:
## - Per tile, orders expand in acceptance order: before an order expands a
##   tile, every earlier pending order whose rectangle holds it and has not
##   expanded it yet does so first ("pulled forward": the tile index goes in
##   that order's "done" list, skipped when its row-major cursor "next"
##   reaches it). So a new order never waits behind a backlog, and acts on a
##   tile exactly as if every earlier order had already finished there. A save
##   taken mid-expansion (StateCodec "areaOrders") resumes exactly there.
## - A tile's command is built when the tile is expanded, against the world
##   at that moment, exactly as the viewer built it at release time before;
##   it is applied with the expanding tick, so its command_applied /
##   command_rejected events and envelopes are the per-tile command's own.
## - cancel only ever picks a job, or a construction site, that existed when
##   the order was accepted (jobLimit / siteLimit: the next job / site number
##   at that moment), or a job an earlier area order created since ("created":
##   [first, end, order id] job-number ranges, recorded while a later cancel
##   is pending) -- one created otherwise during the expansion is never
##   cancelled by an order issued before it. Area orders never create sites.

const TILES_PER_STEP := 128
const ORDERS := ["dig", "chop", "forage", "till", "sow", "mine", "cancel", "remove_object"]
const JOB_ORDERS := ["dig", "chop", "forage", "till", "sow", "mine"]
const SITE_JOB_KINDS := ["site_fetch", "site_work"]

var _orders: Array[Dictionary] = []
var _next_id: int = 1
var _created: Array = []
var _apply: Callable
var _get_construction_site: Callable
var _get_job_index: Callable
var _next_job_number: Callable
var _next_site_number: Callable
var _event_log: EventLog
var _clock: SeededClock

## apply(command) -> envelope (WorldState.apply()); get_construction_site(x, y)
## -> site or {}; get_job_index() -> JobQueue's current JobIndex;
## next_job_number() / next_site_number() -> the next id number either table
## will hand out.
func _init(apply: Callable, get_construction_site: Callable, get_job_index: Callable,
		next_job_number: Callable, next_site_number: Callable, event_log: EventLog, clock: SeededClock) -> void:
	_apply = apply
	_get_construction_site = get_construction_site
	_get_job_index = get_job_index
	_next_job_number = next_job_number
	_next_site_number = next_site_number
	_event_log = event_log
	_clock = clock

## area_order payload rule, shared by apply_command() and preview()
## (CommandChecks.check()): {order, x, y, width, height[, priority]} with order
## one of ORDERS, integer fields, and a rectangle of at least one tile inside
## the map. {} when valid.
static func check(payload: Dictionary, map_width: int, map_height: int) -> Dictionary:
	for key in payload.keys():
		if key not in ["order", "x", "y", "width", "height", "priority"]:
			return {"reason": "invalid_payload", "params": {"detail": "area_order_extra_field", "field": str(key)}}
	if typeof(payload.get("order")) != TYPE_STRING or String(payload["order"]) not in ORDERS:
		return {"reason": "invalid_payload", "params": {"detail": "area_order_unknown_order", "orders": str(ORDERS)}}
	for key in ["x", "y", "width", "height"]:
		if typeof(payload.get(key)) != TYPE_INT:
			return {"reason": "invalid_payload", "params": {"detail": "area_order_payload"}}
	if typeof(payload.get("priority", 1)) != TYPE_INT:
		return {"reason": "invalid_payload", "params": {"detail": "area_order_priority"}}
	var rect := Rect2i(int(payload["x"]), int(payload["y"]), int(payload["width"]), int(payload["height"]))
	if not rect.has_area() or not Rect2i(0, 0, map_width, map_height).encloses(rect):
		return {"reason": "invalid_target", "params": {"detail": "area_rect_invalid"}}
	return {}

## WorldState.apply()'s area_order handler (the envelope is already valid):
## queues the order and expands its own first TILES_PER_STEP tiles now. The
## envelope adds "area_order_id", "remaining" (its tiles left for later ticks)
## and "skipped" ({x, y, reason} per tile command of this order rejected so
## far, row-major).
func apply_command(command: Dictionary, map_width: int, map_height: int) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var rejection := check(payload, map_width, map_height)
	if not rejection.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], rejection["reason"], rejection["params"])
	var order := {
		"id": _next_id, "order": String(payload["order"]), "actor": String(command["actor"]),
		"commandId": String(command["command_id"]), "x": int(payload["x"]), "y": int(payload["y"]),
		"width": int(payload["width"]), "height": int(payload["height"]),
		"priority": int(payload.get("priority", 1)), "next": 0, "done": [],
		"jobLimit": int(_next_job_number.call()), "siteLimit": int(_next_site_number.call()),
	}
	_next_id += 1
	_orders.append(order)
	var applied := _event_log.applied(command)
	var skipped: Array[Dictionary] = []
	_expand(_orders.size() - 1, TILES_PER_STEP, skipped)
	applied["area_order_id"] = order["id"]
	applied["skipped"] = skipped
	applied["remaining"] = remaining_tiles(int(order["id"]))
	return applied

## Expands up to TILES_PER_STEP tiles of the pending orders, first-in
## first-out; returns the per-tile rejections as {x, y, reason}. WorldState
## calls it at the start of every tick().
func advance() -> Array[Dictionary]:
	var skipped: Array[Dictionary] = []
	var budget := TILES_PER_STEP
	while budget > 0 and not _orders.is_empty():
		budget -= _expand(0, budget, skipped)
	return skipped

## Expands up to `budget` not yet expanded tiles of _orders[position],
## row-major, each pulled forward from the earlier orders first; appends the
## order's own rejections to `skipped`, drops the order once done, and
## returns how many of its tiles it expanded.
func _expand(position: int, budget: int, skipped: Array[Dictionary]) -> int:
	var order: Dictionary = _orders[position]
	var width: int = order["width"]
	var total: int = width * int(order["height"])
	var done: Array = order["done"]
	var used := 0
	while int(order["next"]) < total and (used < budget or done.has(int(order["next"]))):
		var index: int = order["next"]
		order["next"] = index + 1
		if done.has(index):
			done.erase(index)
			continue
		used += 1
		var tile := Vector2i(int(order["x"]) + index % width, int(order["y"]) + index / width)
		for earlier in position:
			_pull_forward(_orders[earlier], tile)
		_expand_tile(order, tile, skipped)
	if int(order["next"]) >= total:
		_orders.remove_at(position)
		if not _has_pending_cancel(0):
			_created = []
	return used

## Expands `tile` of the earlier `order` now, out of row-major order, unless
## it lies outside the order or is already expanded. Its rejections are the
## per-tile command_rejected events only.
func _pull_forward(order: Dictionary, tile: Vector2i) -> void:
	var local := tile - Vector2i(int(order["x"]), int(order["y"]))
	if not Rect2i(0, 0, int(order["width"]), int(order["height"])).has_point(local):
		return
	var index: int = local.y * int(order["width"]) + local.x
	if index < int(order["next"]) or (order["done"] as Array).has(index):
		return
	order["done"].append(index)
	var ignored: Array[Dictionary] = []
	_expand_tile(order, tile, ignored)

func _expand_tile(order: Dictionary, tile: Vector2i, skipped: Array[Dictionary]) -> void:
	var command := tile_command(order, tile)
	if command.is_empty():
		return
	var first := int(_next_job_number.call())
	var result: Dictionary = _apply.call(command)
	if not result.get("ok", false):
		skipped.append({"x": tile.x, "y": tile.y, "reason": String(result["rejection"]["reason"])})
	var end := int(_next_job_number.call())
	if end == first or not _has_pending_cancel(int(order["id"])):
		return
	var last: Array = _created.back() if not _created.is_empty() else []
	if not last.is_empty() and int(last[1]) == first and int(last[2]) == int(order["id"]):
		last[1] = end
	else:
		_created.append([first, end, int(order["id"])])

## True when a cancel order accepted after order `after_id` is pending.
func _has_pending_cancel(after_id: int) -> bool:
	for order in _orders:
		if int(order["id"]) > after_id and order["order"] == "cancel":
			return true
	return false

## Whether the cancel `order` may pick the job numbered `number`.
func _cancellable(order: Dictionary, number: int) -> bool:
	if number < int(order["jobLimit"]):
		return true
	for created in _created:
		if number >= int(created[0]) and number < int(created[1]):
			return int(created[2]) < int(order["id"])
	return false

## Tiles of order `id` not yet expanded; 0 once done or unknown.
func remaining_tiles(id: int) -> int:
	for order in _orders:
		if int(order["id"]) == id:
			return int(order["width"]) * int(order["height"]) - int(order["next"]) - (order["done"] as Array).size()
	return 0

## The per-tile command `order` expands to at `tile`, or {} when there is
## nothing to order there (Cancel over a tile with no pending order -- never a
## rejection, as a single click never was).
func tile_command(order: Dictionary, tile: Vector2i) -> Dictionary:
	var type: String = order["order"]
	var command := {"actor": order["actor"], "command_id": "%s:%d,%d" % [order["commandId"], tile.x, tile.y],
		"tick": _clock.tick}
	if type in JOB_ORDERS:
		command["type"] = type
		command["payload"] = {"x": tile.x, "y": tile.y, "priority": order["priority"]}
	elif type == "remove_object":
		command["type"] = "remove_object"
		command["payload"] = {"x": tile.x, "y": tile.y}
	else:
		var site: Dictionary = _get_construction_site.call(tile.x, tile.y)
		if not site.is_empty() and _number(String(site["id"])) < int(order["siteLimit"]):
			command["type"] = "cancel_site"
			command["payload"] = {"x": int(site["origin"].x), "y": int(site["origin"].y)}
			return command
		var candidates: Array = []
		for job in _get_job_index.call().pending_at(tile):
			if _cancellable(order, _number(String(job["id"]))):
				candidates.append(job)
		var job := best_cancel_candidate(candidates)
		if job.is_empty():
			return {}
		command["type"] = "cancel_job"
		command["payload"] = {"job_id": String(job["id"])}
	return command

## The pending job Cancel picks among `jobs` (JobIndex.pending_at(): the
## queued/active jobs targeting one tile, construction-site jobs excluded --
## a tile with a pending site job always has its site, which Cancel takes
## first): queued before active, then higher priority, then lower String id.
static func best_cancel_candidate(jobs: Array) -> Dictionary:
	var best := {}
	for job in jobs:
		if String(job["status"]) not in ["queued", "active"]:
			continue
		if best.is_empty() or cancel_before(job, best):
			best = job
	return best

## Cancel's preference between two pending jobs on the same tile.
static func cancel_before(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_status := 0 if candidate["status"] == "queued" else 1
	var current_status := 0 if current["status"] == "queued" else 1
	if candidate_status != current_status:
		return candidate_status < current_status
	if int(candidate["priority"]) != int(current["priority"]):
		return int(candidate["priority"]) > int(current["priority"])
	return String(candidate["id"]) < String(current["id"])

static func _number(id: String) -> int:
	return int(id.get_slice("_", id.get_slice_count("_") - 1))

## True when no order is pending. WorldState.state_hash() covers the queue
## only while it is not idle: pending expansion decides what the next ticks
## create, while an idle queue's nextId is never observable outside the save.
func is_idle() -> bool:
	return _orders.is_empty()

## Persisted as StateCodec "areaOrders": {nextId, list, created} (every field
## above: JSON-safe ints, strings and int arrays).
func encode() -> Dictionary:
	return {"nextId": _next_id, "list": _orders.duplicate(true), "created": _created.duplicate(true)}

func decode(state: Dictionary) -> void:
	_next_id = int(state.get("nextId", 1))
	_orders = []
	for entry in state.get("list", []):
		var order: Dictionary = {}
		for key in entry:
			var value: Variant = entry[key]
			order[key] = value if value is String else (_ints(value) if value is Array else int(value))
		_orders.append(order)
	_created = []
	for created in state.get("created", []):
		_created.append(_ints(created))

static func _ints(values: Array) -> Array:
	var ints: Array = []
	for value in values:
		ints.append(int(value))
	return ints
