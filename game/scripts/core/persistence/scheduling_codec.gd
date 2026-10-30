class_name SchedulingCodec
extends RefCounted

## StateCodec's "jobs" and "scheduling" encoding: the job list, GlobalAssignment's waiting
## queue, cursors, pending route searches and assignments, JSON-safe both ways.

const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")

## "site" is a site_fetch/site_work job's site origin (JobQueue.attach_site()), optional like
## itemId/cell; the object kind lives on the site record, not on its jobs.
static func _encode_jobs(jobs: Array[Dictionary]) -> Array:
	var encoded: Array = []
	for job in jobs:
		var cell: Variant = job.get("cell")
		var site: Variant = job.get("site")
		encoded.append({
			"id": job["id"], "kind": job["kind"], "status": job["status"],
			"priority": job["priority"], "target": StateCodec._encode_tile(job["target"]),
			"reason": job["reason"], "remedy": job["remedy"],
			"blockingJobId": job["blocking_job_id"],
			"itemId": job.get("item_id", ""),
			"cell": StateCodec._encode_tile(cell) if cell != null else null,
			"retryAt": job.get("retry_at", 0),
			"backoffTicks": job.get("backoff_ticks", 0),
			"site": StateCodec._encode_tile(site) if site != null else null,
		})
	return encoded

static func _decode_jobs(jobs: Array) -> Array[Dictionary]:
	var decoded: Array[Dictionary] = []
	for job in jobs:
		var cell: Variant = job.get("cell")
		var site: Variant = job.get("site")
		decoded.append({
			"id": job["id"], "kind": job["kind"], "status": job["status"],
			"priority": int(job["priority"]), "target": StateCodec._decode_tile(job["target"]),
			"reason": job["reason"], "remedy": job["remedy"],
			"blocking_job_id": job["blockingJobId"],
			"item_id": String(job.get("itemId", "")),
			"cell": StateCodec._decode_tile(cell) if cell != null else null,
			"retry_at": int(job.get("retryAt", 0)),
			"backoff_ticks": int(job.get("backoffTicks", 0)),
			"site": StateCodec._decode_tile(site) if site != null else null,
		})
	return decoded

## scheduler is GlobalAssignment (its queue included); event_log is EventLog.encode()'s
## {queueEventSequence, eventSequence}.
static func _encode_scheduling(scheduler: AssignmentType, event_log: Dictionary) -> Dictionary:
	return {
		"nextJobId": scheduler.queue.get_next_id(),
		"jobSequence": scheduler.queue.get_sequence(),
		"jobTick": scheduler.queue.get_tick(),
		"queueEventSequence": event_log["queueEventSequence"],
		"eventSequence": event_log["eventSequence"],
		"waiting": _encode_entries(scheduler.get_waiting()),
		"nextOrdinal": scheduler.get_next_ordinal(),
		"cursors": scheduler.get_cursors(),
		"pending": _encode_pending(scheduler.get_pending()),
		"assignments": _encode_assignments(scheduler.get_assignments()),
		"activatedEntries": _encode_activated_entries(scheduler.get_activated_entries()),
	}

static func _decode_scheduling(scheduling: Dictionary) -> Dictionary:
	return {
		"waiting": _decode_entries(scheduling["waiting"]),
		"next_ordinal": int(scheduling["nextOrdinal"]),
		"cursors": _decode_int_dict(scheduling["cursors"]),
		"pending": _decode_pending(scheduling["pending"]),
		"assignments": _decode_assignments(scheduling["assignments"]),
		"activated_entries": _decode_activated_entries(scheduling["activatedEntries"]),
	}

## GlobalAssignment's activated entries keyed by job id, sorted.
static func _encode_activated_entries(entries: Dictionary) -> Dictionary:
	var keys := entries.keys()
	keys.sort()
	var encoded: Dictionary = {}
	for key in keys:
		encoded[key] = _encode_entry(entries[key])
	return encoded

static func _decode_activated_entries(entries: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in entries.keys():
		decoded[key] = _decode_entry(entries[key])
	return decoded

static func _encode_entries(entries: Array[Dictionary]) -> Array:
	var encoded: Array = []
	for entry in entries:
		encoded.append(_encode_entry(entry))
	return encoded

static func _encode_entry(entry: Dictionary) -> Dictionary:
	var encoded := {
		"id": entry["id"], "target": StateCodec._encode_tile(entry["target"]),
		"base": entry["base"], "submittedTick": entry["submitted_tick"],
		"ordinal": entry["ordinal"], "restrictTo": String(entry.get("restrict_to", "")),
	}
	# ADR 014 amendment: written only when true, so ordinary entries keep their shape.
	if bool(entry.get("autonomous", false)):
		encoded["autonomous"] = true
	return encoded

static func _decode_entries(entries: Array) -> Array[Dictionary]:
	var decoded: Array[Dictionary] = []
	for entry in entries:
		decoded.append(_decode_entry(entry))
	return decoded

static func _decode_entry(entry: Dictionary) -> Dictionary:
	var decoded := {
		"id": entry["id"], "target": StateCodec._decode_tile(entry["target"]),
		"base": int(entry["base"]), "submitted_tick": int(entry["submittedTick"]),
		"ordinal": int(entry["ordinal"]), "restrict_to": String(entry.get("restrictTo", "")),
	}
	if bool(entry.get("autonomous", false)):
		decoded["autonomous"] = true
	return decoded

static func _encode_int_dict(source: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	for key in source:
		encoded[key] = source[key]
	return encoded

static func _decode_int_dict(source: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for key in source:
		decoded[key] = int(source[key])
	return decoded

static func _encode_pending(pending: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	for worker in pending:
		var request: Dictionary = pending[worker]
		encoded[worker] = {
			"candidates": _encode_entries(request["candidates"]),
			"cursor": request["cursor"],
			"found": _encode_found(request["found"]),
			"start": StateCodec._encode_tile(request["start"]),
			"route": _encode_route(request["route"]),
		}
	return encoded

static func _decode_pending(pending: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for worker in pending:
		var request: Dictionary = pending[worker]
		decoded[worker] = {
			"candidates": _decode_entries(request["candidates"]),
			"cursor": int(request["cursor"]),
			"found": _decode_found(request["found"]),
			"start": StateCodec._decode_tile(request["start"]),
			"route": _decode_route(request["route"]),
		}
	return decoded

static func _encode_found(found: Array) -> Array:
	var encoded: Array = []
	for pair in found:
		encoded.append({
			"worker": pair["worker"], "entry": _encode_entry(pair["entry"]),
			"travel": pair["travel"],
		})
	return encoded

static func _decode_found(found: Array) -> Array:
	var decoded: Array = []
	for pair in found:
		decoded.append({
			"worker": pair["worker"], "entry": _decode_entry(pair["entry"]),
			"travel": int(pair["travel"]),
		})
	return decoded

static func _encode_route(route_state):
	if route_state == null:
		return null
	var visited: Array = []
	for tile in (route_state["visited"] as Dictionary).keys():
		visited.append(StateCodec._encode_tile(tile))
	var came_from: Array = []
	var came_from_map: Dictionary = route_state["came_from"]
	for child in came_from_map.keys():
		came_from.append({"child": StateCodec._encode_tile(child), "parent": StateCodec._encode_tile(came_from_map[child])})
	var encoded := {
		"start": StateCodec._encode_tile(route_state["start"]),
		"target": StateCodec._encode_tile(route_state["target"]),
		"status": route_state["status"],
		"frontier": StateCodec._encode_tile_array(route_state["frontier"]),
		"visited": visited,
		"cameFrom": came_from,
		"path": StateCodec._encode_tile_array(route_state["path"]),
		"expansions": route_state["expansions"],
		"resumeCalls": route_state["resume_calls"],
	}
	# A7 (schema v5): the accumulated cost of each visited tile, in "visited" order. These are the
	# only floats in the state; SaveWire writes them as base64 doubles, never as JSON numbers.
	var cost_value: Variant = (route_state as Dictionary).get("cost")
	if cost_value is Dictionary:
		var cost_map: Dictionary = cost_value
		var visited_map: Dictionary = (route_state as Dictionary)["visited"]
		var cost: Array = []
		for tile: Vector3i in visited_map:
			var g: float = cost_map[tile]
			cost.append(g)
		encoded["cost"] = cost
	return encoded

static func _decode_route(route):
	if route == null:
		return null
	var visited: Dictionary = {}
	for tile in route["visited"]:
		visited[StateCodec._decode_tile(tile)] = true
	var came_from: Dictionary = {}
	for pair in route["cameFrom"]:
		came_from[StateCodec._decode_tile(pair["child"])] = StateCodec._decode_tile(pair["parent"])
	var decoded := {
		"start": StateCodec._decode_tile(route["start"]),
		"target": StateCodec._decode_tile(route["target"]),
		"status": route["status"],
		"frontier": StateCodec._decode_tile_array(route["frontier"]),
		"visited": visited,
		"came_from": came_from,
		"path": StateCodec._decode_tile_array(route["path"]),
		"expansions": int(route["expansions"]),
		"resume_calls": int(route["resumeCalls"]),
	}
	# Absent in a state migrated from v4: RouteSearch.restore() then rebuilds the costs.
	var cost_value: Variant = (route as Dictionary).get("cost")
	if cost_value is Array:
		var saved: Array = cost_value
		var visited_list: Array = (route as Dictionary)["visited"]
		var cost: Dictionary = {}
		for i in visited_list.size():
			var tile: Dictionary = visited_list[i]
			var g: float = saved[i]
			cost[StateCodec._decode_tile(tile)] = g
		decoded["cost"] = cost
	return decoded

static func _encode_assignments(assignments: Dictionary) -> Dictionary:
	var encoded: Dictionary = {}
	for worker in assignments:
		var assignment: Dictionary = assignments[worker]
		encoded[worker] = {
			"jobId": assignment["job_id"], "startedTick": assignment["started_tick"],
			"travelTicks": assignment["travel_ticks"],
			"path": StateCodec._encode_tile_array(assignment.get("path", [])),
		}
	return encoded

static func _decode_assignments(assignments: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for worker in assignments:
		var assignment: Dictionary = assignments[worker]
		decoded[worker] = {
			"job_id": assignment["jobId"], "started_tick": int(assignment["startedTick"]),
			"travel_ticks": int(assignment["travelTicks"]),
			"path": StateCodec._decode_tile_array(assignment.get("path", [])),
		}
	return decoded
