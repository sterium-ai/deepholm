class_name GiverCodec
extends RefCounted

## StateCodec's encoding of the job givers' own associations (rescue victims, combat
## flee exclusions, approach targets, excluded tool candidates) and of the calendar and
## incident continuation state, JSON-safe both ways with sorted keys.

## RescueGiver's job_id -> victim_id map as [{jobId, victimId}], sorted by job id.
static func _encode_rescue_victim_assignments(job_victims: Dictionary) -> Array:
	var keys := job_victims.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		encoded.append({"jobId": key, "victimId": String(job_victims[key])})
	return encoded

static func _decode_rescue_victim_assignments(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		decoded[String(entry["jobId"])] = String(entry["victimId"])
	return decoded

## The decoded queued/active "rescue" jobs (a terminal one has no live association).
static func _surviving_rescue_jobs(jobs: Array[Dictionary]) -> Array[Dictionary]:
	var rescue_jobs: Array[Dictionary] = []
	for job in jobs:
		if String(job["kind"]) == "rescue" and String(job["status"]) in ["queued", "active"]:
			rescue_jobs.append(job)
	return rescue_jobs

## rescuer_id -> job_id from the scheduler's restrict_to, never a persisted field: a job that
## has activated is in restrict_to_for(); one saved mid-search is found in the waiting list.
static func _rescue_pending_from_scheduler(rescue_jobs: Array[Dictionary], scheduler) -> Dictionary:
	var waiting: Array[Dictionary] = scheduler.get_waiting()
	var pending: Dictionary = {}
	for job in rescue_jobs:
		var job_id: String = String(job["id"])
		var rescuer_id: String = String(scheduler.restrict_to_for(job_id))
		if rescuer_id.is_empty():
			for entry in waiting:
				if String(entry.get("id", "")) == job_id:
					rescuer_id = String(entry.get("restrict_to", ""))
					break
		if not rescuer_id.is_empty():
			pending[rescuer_id] = job_id
	return pending

## CombatGiver's per-actor excluded flee destinations: the cancelled flee job that caused one
## is gone after a load, so they must round-trip. Optional on read (absent = none). Sorted by
## actor; each actor's tiles in their (deterministic) insertion order, never re-sorted.
static func _encode_combat_blocked_targets(blocked: Dictionary) -> Array:
	var keys := blocked.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var tiles: Dictionary = blocked[key]
		var tile_list: Array = []
		for tile in tiles.keys():
			tile_list.append(StateCodec._encode_tile(tile))
		encoded.append({"actorId": key, "tiles": tile_list})
	return encoded

static func _decode_combat_blocked_targets(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var tiles: Dictionary = {}
		for tile in (entry["tiles"] as Array):
			tiles[StateCodec._decode_tile(tile)] = true
		decoded[String(entry["actorId"])] = tiles
	return decoded

## ApproachGiver's job_id -> target as [{jobId, kind, actorId | tile}], sorted by job id;
## persisted because an object target has no live record to re-scan after a load.
static func _encode_approach_job_targets(job_targets: Dictionary) -> Array:
	var keys := job_targets.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var target: Dictionary = job_targets[key]
		var entry := {"jobId": key, "kind": String(target["kind"])}
		if String(target["kind"]) == "actor":
			entry["actorId"] = String(target["id"])
		else:
			entry["tile"] = StateCodec._encode_tile(target["tile"])
		encoded.append(entry)
	return encoded

static func _decode_approach_job_targets(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		if String(entry["kind"]) == "actor":
			decoded[String(entry["jobId"])] = {"kind": "actor", "id": String(entry["actorId"])}
		else:
			decoded[String(entry["jobId"])] = {"kind": "object", "tile": StateCodec._decode_tile(entry["tile"])}
	return decoded

## The decoded queued/active "approach" jobs, like _surviving_rescue_jobs().
static func _surviving_approach_jobs(jobs: Array[Dictionary]) -> Array[Dictionary]:
	var approach_jobs: Array[Dictionary] = []
	for job in jobs:
		if String(job["kind"]) == "approach" and String(job["status"]) in ["queued", "active"]:
			approach_jobs.append(job)
	return approach_jobs

## The set of calendar window ids that already fired this occurrence (ADR 008: caller-tracked),
## sorted.
static func _encode_calendar_alerts(fired: Dictionary) -> Dictionary:
	var keys := fired.keys()
	keys.sort()
	return {"fired": keys}

static func _decode_calendar_alerts(field: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for window_id in (field["fired"] as Array):
		decoded[String(window_id)] = true
	return decoded

## ToolFetchToil's job_id -> unreachable tool ids, sorted by job id; empty lists are omitted.
static func _encode_tool_fetch_excluded(excluded: Dictionary) -> Array:
	var keys := excluded.keys()
	keys.sort()
	var encoded: Array = []
	for key in keys:
		var ids: Array = excluded[key]
		if ids.is_empty():
			continue
		encoded.append({"jobId": key, "toolIds": ids.duplicate()})
	return encoded

static func _decode_tool_fetch_excluded(list: Array) -> Dictionary:
	var decoded: Dictionary = {}
	for entry in list:
		var ids: Array = []
		for id in (entry["toolIds"] as Array):
			ids.append(String(id))
		decoded[String(entry["jobId"])] = ids
	return decoded

## IncidentScheduler's cooldowns, last processed day and RNG (ADR 004: hashed continuation
## state), read from its fields since it has no accessor.
static func _encode_incident_scheduler(incidents: IncidentScheduler) -> Dictionary:
	return {
		"cooldownUntilDay": SchedulingCodec._encode_int_dict(incidents._cooldown_until_day),
		"lastProcessedDay": incidents._last_processed_day,
		"rng": {"seed": incidents._random.seed, "state": incidents._random.state},
	}
