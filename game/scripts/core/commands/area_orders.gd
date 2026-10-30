class_name AreaOrders
extends RefCounted

## The `area_order` command and its saved expansion queue (ADR 044): a rectangle expanded
## row-major through the same per-tile command a click applies, TILES_PER_STEP tiles at
## acceptance and per tick (FIFO). The pace is fixed per tick, never wall-clock.
## Invariants:
## - Per tile, orders expand in acceptance order: earlier pending orders covering a tile are
##   "pulled forward" first. A save mid-expansion ("areaOrders") resumes exactly there.
## - A tile's command is built against the world when expanded and emits its own events.
## - cancel only picks a job/site that existed at acceptance (jobLimit/siteLimit) or one an
##   earlier area order created since ("created" ranges). Area orders never create sites.

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

## next_job_number()/next_site_number() return the next id number either table hands out.
func _init(apply: Callable, get_construction_site: Callable, get_job_index: Callable,
		next_job_number: Callable, next_site_number: Callable, event_log: EventLog, clock: SeededClock) -> void:
	_apply = apply
	_get_construction_site = get_construction_site
	_get_job_index = get_job_index
	_next_job_number = next_job_number
	_next_site_number = next_site_number
	_event_log = event_log
	_clock = clock

## area_order payload rule shared by apply_command() and preview(); {} when valid.
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

## Queues the order and expands its first TILES_PER_STEP tiles now; the envelope adds
## "area_order_id", "remaining" and "skipped" ({x, y, reason} per rejected tile).
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

## TickPipeline's first phase: up to TILES_PER_STEP tiles, FIFO; returns the rejections.
func advance() -> Array[Dictionary]:
	var skipped: Array[Dictionary] = []
	var budget := TILES_PER_STEP
	while budget > 0 and not _orders.is_empty():
		budget -= _expand(0, budget, skipped)
	return skipped

## Expands up to `budget` tiles of _orders[position] (earlier orders pulled forward first);
## returns how many it expanded.
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
		var tile := Vector2i(int(order["x"]), int(order["y"])) + TileGrid.flat_coord(index, width)
		for earlier in position:
			_pull_forward(_orders[earlier], tile)
		_expand_tile(order, tile, skipped)
	if int(order["next"]) >= total:
		_orders.remove_at(position)
		if not _has_pending_cancel(0):
			_created = []
	return used

## Expands `tile` of the earlier `order` now, unless outside it or already done.
func _pull_forward(order: Dictionary, tile: Vector2i) -> void:
	var local := tile - Vector2i(int(order["x"]), int(order["y"]))
	if not Rect2i(0, 0, int(order["width"]), int(order["height"])).has_point(local):
		return
	var index: int = TileGrid.flat_index(local.x, local.y, int(order["width"]))
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

## The per-tile command for `tile`, or {} when there is nothing to order (never a rejection).
func tile_command(order: Dictionary, tile: Vector2i) -> Dictionary:
	var type: String = order["order"]
	var command := {"actor": order["actor"], "command_id": "%s:%s" % [order["commandId"], TileGrid.comma_key(tile.x, tile.y)],
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

## Cancel's pick among a tile's pending jobs: queued before active, then higher priority,
## then lower id.
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

## True when no order is pending; state_hash() covers the queue only while it is not idle.
func is_idle() -> bool:
	return _orders.is_empty()

## Persisted as StateCodec "areaOrders": {nextId, list, created}.
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
