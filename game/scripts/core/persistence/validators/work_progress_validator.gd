class_name WorkProgressValidator
extends SaveCheck

## Save validation for what WorkProgress persists: "workProgress", "workProgressOwners",
## "suspendedWorkProgress".

## Mirrors _valid_ground_berries()/_valid_ground_berries_entry():
## world._work_progress's wire shape is an array of {target, ticksRemaining}
## entries (see StateCodec._encode_work_progress()), colonist-ai.md 3.6's
## tile-keyed remaining-ticks store for an interruptible `work` toil.
static func _valid_work_progress(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid workProgress type")
	for entry in (value as Array):
		var entry_check := _valid_work_progress_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
	return {"ok": true}

## "ownerJobId" is optional on the wire, like "autonomous" on a queue entry: present only when the tile's
## reservation was owned by a job when the entry was encoded, absent for the
## plain tile-keyed case.
static func _valid_work_progress_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid workProgress entry type")
	var entry: Dictionary = value
	var required := ["target", "ticksRemaining"]
	if not _keys_allowed(entry, required + ["ownerJobId"]):
		return _fail("unexpected workProgress entry field")
	for key in required:
		if not entry.has(key):
			return _fail_missing("missing workProgress entry field '%s'" % key)
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _is_int_min(entry["ticksRemaining"], 1):
		return _fail("invalid workProgress entry ticksRemaining")
	if entry.has("ownerJobId") and not _matches_id_pattern(entry["ownerJobId"]):
		return _fail("invalid workProgress entry ownerJobId")
	return {"ok": true}

## WorkProgress.owners's wire shape is an array of {target, jobId, ownerJobId?}
## entries (StateCodec._encode_work_progress_owners()): the exact job that
## owns a workProgress key, so decode() never
## has to guess it from whichever job happens to target that key. target +
## ownerJobId name the key like a workProgress entry (ADR 047). At most one
## job owns a given key, so a duplicate (ownerJobId, target) pair is rejected
## the same way duplicate colonistId/actorId are for pausedJobs/combatBlockedTargets;
## two rescues' scoped keys on one tile are distinct keys and both allowed.
static func _valid_work_progress_owners(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid workProgressOwners type")
	var seen_targets := {}
	for entry in (value as Array):
		var entry_check := _valid_work_progress_owner_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
		var target: Dictionary = (entry as Dictionary)["target"]
		var target_key := "%s:%s_%s" % [(entry as Dictionary).get("ownerJobId", ""), target["x"], target["y"]]
		if seen_targets.has(target_key):
			return _fail("duplicate workProgressOwners target")
		seen_targets[target_key] = true
	return {"ok": true}

static func _valid_work_progress_owner_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid workProgressOwners entry type")
	var entry: Dictionary = value
	var required := ["target", "jobId"]
	if not _keys_allowed(entry, required + ["ownerJobId"]):
		return _fail("unexpected workProgressOwners entry field")
	for key in required:
		if not entry.has(key):
			return _fail_missing("missing workProgressOwners entry field '%s'" % key)
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid workProgressOwners entry jobId")
	if entry.has("ownerJobId") and not _matches_id_pattern(entry["ownerJobId"]):
		return _fail("invalid workProgressOwners entry ownerJobId")
	return {"ok": true}

## world._suspended_work_progress's wire shape is an array of {jobId,
## ticksRemaining} entries (StateCodec._encode_suspended_work_progress()):
## a suspended job's own work-toil ticks, keyed by job_id alone (no tile coordinate -- unlike workProgress/
## workProgressOwners, at most one entry per job_id, never per tile, since a
## suspended job's snapshot has already left the shared tile cache). Optional
## on the wire like workProgressOwners.
static func _valid_suspended_work_progress(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid suspendedWorkProgress type")
	var seen_job_ids := {}
	for entry in (value as Array):
		var entry_check := _valid_suspended_work_progress_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var job_id: String = (entry as Dictionary)["jobId"]
		if seen_job_ids.has(job_id):
			return _fail("duplicate suspendedWorkProgress jobId '%s'" % job_id)
		seen_job_ids[job_id] = true
	return {"ok": true}

static func _valid_suspended_work_progress_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid suspendedWorkProgress entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["jobId", "ticksRemaining"], "suspendedWorkProgress entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid suspendedWorkProgress entry jobId")
	if not _is_int_min(entry["ticksRemaining"], 1):
		return _fail("invalid suspendedWorkProgress entry ticksRemaining")
	return {"ok": true}
