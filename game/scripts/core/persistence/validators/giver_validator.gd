class_name GiverValidator
extends SaveCheck

## Save validation for what NeedsSystem and the job givers persist: "pausedJobs",
## "needJobAssignments", "rescueVictimAssignments", "combatBlockedTargets", "approachJobTargets".

## NeedsSystem.paused_jobs as [{colonistId, jobId}]: the job a critical need interrupted
## (colonist-ai.md 3.6), never a job record.
static func _valid_paused_jobs(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid pausedJobs type")
	var seen_colonists := {}
	for entry in (value as Array):
		var entry_check := _valid_paused_job_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var colonist_id: String = (entry as Dictionary)["colonistId"]
		if seen_colonists.has(colonist_id):
			return _fail("duplicate pausedJobs colonistId '%s'" % colonist_id)
		seen_colonists[colonist_id] = true
	return {"ok": true}

static func _valid_paused_job_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid pausedJobs entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["colonistId", "jobId"], "pausedJobs entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["colonistId"]):
		return _fail("invalid pausedJobs entry colonistId")
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid pausedJobs entry jobId")
	return {"ok": true}

## NeedGiver's colonist -> need-job map, same shape as pausedJobs.
static func _valid_need_job_assignments(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid needJobAssignments type")
	var seen_colonists := {}
	for entry in (value as Array):
		var entry_check := _valid_need_job_assignment_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var colonist_id: String = (entry as Dictionary)["colonistId"]
		if seen_colonists.has(colonist_id):
			return _fail("duplicate needJobAssignments colonistId '%s'" % colonist_id)
		seen_colonists[colonist_id] = true
	return {"ok": true}

static func _valid_need_job_assignment_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid needJobAssignments entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["colonistId", "jobId"], "needJobAssignments entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["colonistId"]):
		return _fail("invalid needJobAssignments entry colonistId")
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid needJobAssignments entry jobId")
	return {"ok": true}

## RescueGiver's [{jobId, victimId}], keyed by job id; optional at the top level.
static func _valid_rescue_victim_assignments(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid rescueVictimAssignments type")
	var seen_jobs := {}
	for entry in (value as Array):
		var entry_check := _valid_rescue_victim_assignment_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var job_id: String = (entry as Dictionary)["jobId"]
		if seen_jobs.has(job_id):
			return _fail("duplicate rescueVictimAssignments jobId '%s'" % job_id)
		seen_jobs[job_id] = true
	return {"ok": true}

static func _valid_rescue_victim_assignment_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid rescueVictimAssignments entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["jobId", "victimId"], "rescueVictimAssignments entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid rescueVictimAssignments entry jobId")
	if not _matches_id_pattern(entry["victimId"]):
		return _fail("invalid rescueVictimAssignments entry victimId")
	return {"ok": true}

## CombatGiver's [{actorId, tiles}] flee exclusions.
static func _valid_combat_blocked_targets(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid combatBlockedTargets type")
	var seen_actors := {}
	for entry in (value as Array):
		var entry_check := _valid_combat_blocked_targets_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
		var actor_id: String = (entry as Dictionary)["actorId"]
		if seen_actors.has(actor_id):
			return _fail("duplicate combatBlockedTargets actorId '%s'" % actor_id)
		seen_actors[actor_id] = true
	return {"ok": true}

static func _valid_combat_blocked_targets_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid combatBlockedTargets entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["actorId", "tiles"], "combatBlockedTargets entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["actorId"]):
		return _fail("invalid combatBlockedTargets entry actorId")
	var tiles_check := _valid_tile_array(entry["tiles"], map_width, map_height)
	if not tiles_check["ok"]:
		return tiles_check
	return {"ok": true}

## ApproachGiver's [{jobId, kind, actorId | tile}] (ADR 033).
static func _valid_approach_job_targets(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid approachJobTargets type")
	var seen_jobs := {}
	for entry in (value as Array):
		var entry_check := _valid_approach_job_target_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
		var job_id: String = (entry as Dictionary)["jobId"]
		if seen_jobs.has(job_id):
			return _fail("duplicate approachJobTargets jobId '%s'" % job_id)
		seen_jobs[job_id] = true
	return {"ok": true}

static func _valid_approach_job_target_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid approachJobTargets entry type")
	var entry: Dictionary = value
	if not (entry.get("kind") is String) or not ["actor", "object"].has(entry["kind"]):
		return _fail("invalid approachJobTargets entry kind")
	var is_actor := String(entry["kind"]) == "actor"
	var check := _require_fields(entry, ["jobId", "kind", "actorId"] if is_actor else ["jobId", "kind", "tile"], "approachJobTargets entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid approachJobTargets entry jobId")
	if is_actor:
		if not _matches_id_pattern(entry["actorId"]):
			return _fail("invalid approachJobTargets entry actorId")
		return {"ok": true}
	return _valid_tile(entry["tile"], map_width, map_height)
