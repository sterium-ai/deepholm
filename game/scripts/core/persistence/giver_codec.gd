class_name GiverCodec
extends RefCounted

## StateCodec's encoding of the job givers' own associations (rescue victims, combat
## flee exclusions, approach targets, excluded tool candidates) and of the calendar and
## incident continuation state, JSON-safe both ways with sorted keys.

## RescueGiver.get_job_victims()'s own job_id -> victim_id association,
## encoded as an array of {jobId, victimId} entries: unlike _encode_paused_jobs()'s colonist-keyed shape, this map is keyed
## by job id (a colonist can be the victim of at most one live rescue job, but
## nothing here depends on that -- job id is what's actually unique), so
## sorting by job id gives the same deterministic encoding order every other
## keyed-map encoder here uses.
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

## Every decoded job still queued or active (a terminal one is already
## resolved and carries no live RescueGiver association) whose kind is
## "rescue" -- decode()'s own shared input for both
## RescueGiver.restore_victim_assignments() and _rescue_pending_from_scheduler()
## below.
static func _surviving_rescue_jobs(jobs: Array[Dictionary]) -> Array[Dictionary]:
	var rescue_jobs: Array[Dictionary] = []
	for job in jobs:
		if String(job["kind"]) == "rescue" and String(job["status"]) in ["queued", "active"]:
			rescue_jobs.append(job)
	return rescue_jobs

## rescuer_id -> job_id for every surviving rescue job, read straight off the
## scheduler's own restrict_to instead of any persisted RescueGiver field
## (see decode()'s own comment): GlobalAssignment.restrict_to_for() covers a
## job that has activated at least once (active now, or queued again after a
## need/combat suspension); a rescue job saved mid-search and never yet
## activated has no such entry, so this falls back to scanning the
## scheduler's own waiting list for the same job's restrict_to directly.
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

## world._combat_giver's own per-actor excluded-flee-destination set
## (CombatGiver._blocked_targets, actor_id -> Dictionary[Vector2i, true]):
## unlike `_fleeing`, this cannot be reconstructed from the scheduler's own
## queued/active jobs after a load (a cancelled blocked flee job that
## produced an exclusion is already gone from the queue by the time it is
## excluded), so it must round-trip explicitly. Optional on read
## (SaveIO._validate_state()) -- absent on any save written before this
## round, decoded as no exclusions, exactly like "health" is optional on an
## individual objects entry. Sorted actor keys give a deterministic encoding
## order; each actor's own tiles are emitted in the live Dictionary's
## insertion order (never re-sorted), which is itself deterministic given
## identical prior ticks -- matching every other keyed-map encoder here.
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

## ApproachGiver.get_job_targets()'s own job_id -> {kind, id/tile} association,
## encoded as an array of {jobId, kind, actorId} or {jobId, kind, tile}
## entries (mirroring _encode_rescue_victim_assignments()'s job-keyed shape):
## an object target has no living record to re-scan after a load (unlike an
## actor target, which still exists to look up but is not re-derived from it
## either, for the same "no per-job field" reason rescue's own victim
## association is never re-derived). Sorted job-id keys give a deterministic
## encoding order.
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

## Every decoded job still queued or active whose kind is "approach" -- a
## terminal one carries no live ApproachGiver association (mirrors
## _surviving_rescue_jobs()).
static func _surviving_approach_jobs(jobs: Array[Dictionary]) -> Array[Dictionary]:
	var approach_jobs: Array[Dictionary] = []
	for job in jobs:
		if String(job["kind"]) == "approach" and String(job["status"]) in ["queued", "active"]:
			approach_jobs.append(job)
	return approach_jobs

## world._calendar_alerts_fired is a set of calendar window ids (Dictionary
## keys -> true) that have already fired their one-shot alert for the current
## occurrence (ADR 008 consequence 6: already_fired is caller-tracked, not
## calendar-owned). Sorted for deterministic encoding order, matching every
## other keyed-map encoder here.
static func _encode_calendar_alerts(fired: Dictionary) -> Dictionary:
	var keys := fired.keys()
	keys.sort()
	return {"fired": keys}

static func _decode_calendar_alerts(field: Dictionary) -> Dictionary:
	var decoded: Dictionary = {}
	for window_id in (field["fired"] as Array):
		decoded[String(window_id)] = true
	return decoded

## ToolFetchToil's own _excluded map (see tool_fetch_toil.gd's get_excluded()/
## restore_excluded()): job_id -> Array[String] of tool ids already proven
## unreachable within that job's current fetch attempt. Sorted job-id keys
## give a deterministic encoding order, matching every other keyed-map
## encoder here; a job id with an empty list is simply omitted (decode()'s
## own default read is an empty array either way).
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

## world._incidents' own cooldown-until-day map, last-processed day, and its
## independent seeded RNG stream (ADR 004 "WorldState's diagnostic hash
## includes this continuation state") -- read directly off IncidentScheduler's
## fields since that file exposes no accessor, mirroring how encode() already reads world._random
## directly rather than through a getter.
static func _encode_incident_scheduler(world: WorldState) -> Dictionary:
	return {
		"cooldownUntilDay": SchedulingCodec._encode_int_dict(world._incidents._cooldown_until_day),
		"lastProcessedDay": world._incidents._last_processed_day,
		"rng": {"seed": world._incidents._random.seed, "state": world._incidents._random.state},
	}
