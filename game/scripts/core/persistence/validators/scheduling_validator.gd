class_name SchedulingValidator
extends SaveCheck

## Save validation for what JobQueue, GlobalAssignment and EventLog persist: "jobs",
## "scheduling" (queue entries, pending route searches, assignments) and the world "rng".

## "autonomous" (ADR 014 amendment) is optional; absent decodes as false.
static func _valid_queue_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid queue entry type")
	var entry: Dictionary = value
	var required := ["id", "target", "base", "submittedTick", "ordinal", "restrictTo"]
	# Inlined: _require_fields() would reject the optional "autonomous" key.
	if not _keys_allowed(entry, required + ["autonomous"]):
		return _fail("unexpected queue entry field")
	for key in required:
		if not entry.has(key):
			return _fail_missing("missing queue entry field '%s'" % key)
	if not _matches_id_pattern(entry["id"]):
		return _fail("invalid queue entry id")
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _is_int(entry["base"]) or not _is_int_min(entry["submittedTick"], 0) or not _is_int_min(entry["ordinal"], 0):
		return _fail("invalid queue entry fields")
	if not (entry["restrictTo"] is String) or not _matches_optional_id_pattern(entry["restrictTo"]):
		return _fail("invalid queue entry restrictTo")
	if entry.has("autonomous") and not (entry["autonomous"] is bool):
		return _fail("invalid queue entry autonomous")
	return {"ok": true}

static func _valid_route_state(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid route state type")
	var route: Dictionary = value
	var required := ["start", "target", "status", "frontier", "visited", "cameFrom", "path", "expansions", "resumeCalls"]
	# "cost" (A7, schema v5) is optional: a state migrated from v4 has none.
	if not _keys_allowed(route, required + ["cost"]):
		return _fail("unexpected route state field")
	for key: String in required:
		if not route.has(key):
			return _fail_missing("missing route state field '%s'" % key)
	var start_check := _valid_tile(route["start"], map_width, map_height)
	if not start_check["ok"]:
		return start_check
	var target_check := _valid_tile(route["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not (route["status"] is String) or not ["searching", "found", "unreachable"].has(route["status"]):
		return _fail("invalid route status")
	var frontier_check := _valid_tile_array(route["frontier"], map_width, map_height)
	if not frontier_check["ok"]:
		return frontier_check
	var visited_check := _valid_tile_array(route["visited"], map_width, map_height)
	if not visited_check["ok"]:
		return visited_check
	var path_check := _valid_tile_array(route["path"], map_width, map_height)
	if not path_check["ok"]:
		return path_check
	if not (route["cameFrom"] is Array):
		return _fail("invalid route cameFrom type")
	for pair in route["cameFrom"]:
		if not (pair is Dictionary):
			return _fail("invalid route cameFrom entry type")
		var pair_check := _require_fields(pair, ["child", "parent"], "cameFrom entry")
		if not pair_check["ok"]:
			return pair_check
		var child_check := _valid_tile(pair["child"], map_width, map_height)
		if not child_check["ok"]:
			return child_check
		var parent_check := _valid_tile(pair["parent"], map_width, map_height)
		if not parent_check["ok"]:
			return parent_check
	if not _is_int_min(route["expansions"], 0) or not _is_int_min(route["resumeCalls"], 0):
		return _fail("invalid route expansions or resumeCalls")
	if route.has("cost"):
		return _valid_route_cost(route["cost"], (route["visited"] as Array).size())
	return {"ok": true}

## One finite, non-negative accumulated cost per visited tile, in "visited" order.
static func _valid_route_cost(value: Variant, visited_count: int) -> Dictionary:
	if not (value is Array) or (value as Array).size() != visited_count:
		return _fail("route cost must hold one number per visited tile")
	for cost: Variant in value:
		if typeof(cost) != TYPE_FLOAT and typeof(cost) != TYPE_INT:
			return _fail("invalid route cost")
		var number: float = cost
		if not is_finite(number) or number < 0.0:
			return _fail("invalid route cost")
	return {"ok": true}

static func _valid_found_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid found entry type")
	var found: Dictionary = value
	var required := ["worker", "entry", "travel"]
	var check := _require_fields(found, required, "found entry")
	if not check["ok"]:
		return check
	if not (found["worker"] is String):
		return _fail("invalid found entry worker")
	var entry_check := _valid_queue_entry(found["entry"], map_width, map_height)
	if not entry_check["ok"]:
		return entry_check
	if not _is_int_min(found["travel"], 0):
		return _fail("invalid found entry travel")
	return {"ok": true}

static func _valid_pending_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid pending entry type")
	var pending: Dictionary = value
	var required := ["candidates", "cursor", "found", "start", "route"]
	var check := _require_fields(pending, required, "pending entry")
	if not check["ok"]:
		return check
	if not (pending["candidates"] is Array):
		return _fail("invalid pending candidates type")
	for candidate in pending["candidates"]:
		var candidate_check := _valid_queue_entry(candidate, map_width, map_height)
		if not candidate_check["ok"]:
			return candidate_check
	if not _is_int_min(pending["cursor"], 0):
		return _fail("invalid pending cursor")
	if not (pending["found"] is Array):
		return _fail("invalid pending found type")
	for found in pending["found"]:
		var found_check := _valid_found_entry(found, map_width, map_height)
		if not found_check["ok"]:
			return found_check
	var start_check := _valid_tile(pending["start"], map_width, map_height)
	if not start_check["ok"]:
		return start_check
	var route: Variant = pending["route"]
	if route == null:
		return {"ok": true}
	return _valid_route_state(route, map_width, map_height)

static func _valid_assignment_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid assignment entry type")
	var assignment: Dictionary = value
	var required := ["jobId", "startedTick", "travelTicks", "path"]
	var check := _require_fields(assignment, required, "assignment entry")
	if not check["ok"]:
		return check
	if not (assignment["jobId"] is String) or not _is_int_min(assignment["startedTick"], 0) or not _is_int_min(assignment["travelTicks"], 0):
		return _fail("invalid assignment fields")
	var path_check := _valid_tile_array(assignment["path"], map_width, map_height)
	if not path_check["ok"]:
		return path_check
	return {"ok": true}

## job_kinds: jobs.json's kinds from the session registry (SaveIO.content_rules()).
static func _valid_jobs(value, map_width: int, map_height: int, job_kinds: Array[String]) -> Dictionary:
	if not (value is Array):
		return _fail("invalid jobs type")
	var job_required := ["id", "kind", "status", "priority", "target", "reason", "remedy", "blockingJobId",
		"itemId", "cell", "retryAt", "backoffTicks"]
	# "site" is optional on the wire (absent means null, as on every non-site job);
	# encode() always writes it.
	var job_optional := ["site"]
	for job in value:
		if not (job is Dictionary):
			return _fail("invalid job type")
		if not _keys_allowed(job, job_required + job_optional):
			return _fail("unexpected job field")
		for key in job_required:
			if not job.has(key):
				return _fail_missing("missing job field '%s'" % key)
		if not _matches_id_pattern(job["id"]):
			return _fail("invalid job id")
		if not (job["kind"] is String) or not job_kinds.has(job["kind"]):
			return _fail("invalid job kind")
		if not (job["status"] is String) or not ["queued", "active", "completed", "failed", "cancelled"].has(job["status"]):
			return _fail("invalid job status")
		if not _is_int(job["priority"]) or not [0, 1, 2].has(int(job["priority"])):
			return _fail("invalid job priority")
		var job_target_check := _valid_tile(job["target"], map_width, map_height)
		if not job_target_check["ok"]:
			return job_target_check
		if not (job["reason"] is String) or not (job["remedy"] is String) or not (job["blockingJobId"] is String):
			return _fail("invalid job reason, remedy, or blockingJobId")
		if not (job["itemId"] is String) or not _matches_optional_id_pattern(job["itemId"]):
			return _fail("invalid job itemId")
		if job["cell"] != null:
			var cell_check := _valid_tile(job["cell"], map_width, map_height)
			if not cell_check["ok"]:
				return cell_check
		if not _is_int_min(job["retryAt"], 0) or not _is_int_min(job["backoffTicks"], 0):
			return _fail("invalid job retryAt or backoffTicks")
		if job.get("site") != null:
			var site_check := _valid_tile(job["site"], map_width, map_height)
			if not site_check["ok"]:
				return site_check
		# A site_fetch/site_work job's site is mandatory: activation and completion both need it.
		if String(job["kind"]) in ["site_fetch", "site_work"] and job.get("site") == null:
			return _fail("site job missing site")
	return {"ok": true}

static func _valid_scheduling(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid scheduling type")
	var scheduling: Dictionary = value
	var scheduling_required := ["nextJobId", "jobSequence", "jobTick", "queueEventSequence", "eventSequence",
		"waiting", "nextOrdinal", "cursors", "pending", "assignments", "activatedEntries"]
	if not _keys_allowed(scheduling, scheduling_required):
		return _fail("unexpected scheduling field")
	for key in scheduling_required:
		if not scheduling.has(key):
			return _fail_missing("missing scheduling field '%s'" % key)
	if not _is_int_min(scheduling["nextJobId"], 1):
		return _fail("invalid scheduling.nextJobId")
	if not _is_int_min(scheduling["jobSequence"], 0):
		return _fail("invalid scheduling.jobSequence")
	if not _is_int_min(scheduling["jobTick"], 0):
		return _fail("invalid scheduling.jobTick")
	if not _is_int_min(scheduling["queueEventSequence"], -1):
		return _fail("invalid scheduling.queueEventSequence")
	if not _is_int_min(scheduling["eventSequence"], 0):
		return _fail("invalid scheduling.eventSequence")
	if not _is_int_min(scheduling["nextOrdinal"], 0):
		return _fail("invalid scheduling.nextOrdinal")
	if not (scheduling["waiting"] is Array):
		return _fail("invalid scheduling.waiting type")
	for entry in scheduling["waiting"]:
		var waiting_check := _valid_queue_entry(entry, map_width, map_height)
		if not waiting_check["ok"]:
			return waiting_check
	if not (scheduling["cursors"] is Dictionary):
		return _fail("invalid scheduling.cursors type")
	for key in scheduling["cursors"].keys():
		if not _is_int_min(scheduling["cursors"][key], 0):
			return _fail("invalid scheduling.cursors value")
	if not (scheduling["pending"] is Dictionary):
		return _fail("invalid scheduling.pending type")
	for key in scheduling["pending"].keys():
		var pending_check := _valid_pending_entry(scheduling["pending"][key], map_width, map_height)
		if not pending_check["ok"]:
			return pending_check
	if not (scheduling["assignments"] is Dictionary):
		return _fail("invalid scheduling.assignments type")
	for key in scheduling["assignments"].keys():
		var assignment_check := _valid_assignment_entry(scheduling["assignments"][key], map_width, map_height)
		if not assignment_check["ok"]:
			return assignment_check
	if not (scheduling["activatedEntries"] is Dictionary):
		return _fail("invalid scheduling.activatedEntries type")
	for key in scheduling["activatedEntries"].keys():
		if not _matches_id_pattern(key):
			return _fail("invalid scheduling.activatedEntries key")
		var activated_entry_check := _valid_queue_entry(scheduling["activatedEntries"][key], map_width, map_height)
		if not activated_entry_check["ok"]:
			return activated_entry_check
	return {"ok": true}

static func _valid_rng(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid rng type")
	var rng: Dictionary = value
	if not _keys_allowed(rng, ["seed", "state"]):
		return _fail("unexpected rng field")
	if not rng.has("seed") or not rng.has("state"):
		return _fail_missing("missing rng field")
	if not _is_int(rng["seed"]) or not _is_int(rng["state"]):
		return _fail("invalid rng fields")
	return {"ok": true}
