class_name WorkProgress
extends RefCounted

## WorldState's `work`-toil progress (colonist-ai.md 3.6): the live per-tile
## timers, the job that last wrote each one, and the timers of jobs suspended
## mid-work. Plain data, no scene/node/RNG/wall-clock dependency; the job queue
## is injected, every WorldState rule it needs arrives as a Callable.
##
## Invariants:
## - progress is keyed "%d_%d", or "<job_id>:%d_%d" for a "rescue" job (two
##   rescues can share a target); every other kind keeps the plain tile key.
##   key_of() builds a key and key_parts() is its inverse; nothing else
##   formats or splits one (ADR 047: the save codec goes through them too).
## - owners records the job_id that last wrote a progress key, so a job paused
##   mid-work (status back to "queued") still owns its progress and only the
##   owner's termination drops it. "incident" never has an owner: its wait is
##   stamped job_id-less by IncidentScheduler and cleared by
##   WorldState._finish_job() while the job is active.
## - suspended holds job_id -> ticks for a job whose colonist.work was cleared
##   without terminating it, so a different job working the same tile can never
##   inherit, overwrite or erase them. resume() is its only reader (consumes the
##   entry); release_owned() drops it when the job terminates while suspended.
## - All three maps are persisted ("workProgress", "workProgressOwners",
##   "suspendedWorkProgress"). Owners are restored from the save, cross-checked
##   against the restored jobs, by restore_owners(); never guessed from which job
##   targets a key (a dig can be queued on a tile a build owns mid-haul). Keys
##   left without an owner are dropped, except an active incident's wait.
## - state_hash() covers suspended only (hash_into()); progress and owners are
##   deliberately left out.
## - Owners persist as explicit {target, jobId, ownerJobId?} records naming the
##   key's tile and scope (ADR 047), never a re-split of the key.

const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")

var progress: Dictionary = {}
var owners: Dictionary = {}
var suspended: Dictionary = {}
var _queue: JobQueueType
## job kind -> work ticks (content/jobs.json), shared by reference with WorldState.
var _work_ticks: Dictionary
## (x: int, y: int) -> String: JobQueue's "tile:%d,%d" reservation key.
var _tile_key: Callable
## (job: Dictionary) -> Vector2i: the tile a job's `work` toil runs on.
var _work_target_for: Callable

func _init(queue: JobQueueType, work_ticks: Dictionary, tile_key: Callable, work_target_for: Callable) -> void:
	_queue = queue
	_work_ticks = work_ticks
	_tile_key = tile_key
	_work_target_for = work_target_for

## The save fields this table owns, in StateCodec's wire shapes.
func encode() -> Dictionary:
	return {
		"workProgress": StateCodec._encode_work_progress(progress),
		"workProgressOwners": StateCodec._encode_work_progress_owners(owners),
		"suspendedWorkProgress": StateCodec._encode_suspended_work_progress(suspended),
	}

## Restores progress and suspended; returns the persisted key -> job_id owners,
## which restore_owners() applies once the jobs themselves are restored.
func decode(state: Dictionary) -> Dictionary:
	progress = StateCodec._decode_work_progress(state["workProgress"])
	var persisted_owners := StateCodec._decode_work_progress_owners(state.get("workProgressOwners", []))
	suspended = StateCodec._decode_suspended_work_progress(state.get("suspendedWorkProgress", []))
	return persisted_owners

## Adds this table's state_hash() entry to snapshot: suspended ticks decide what
## a job does the moment it resumes, so states differing only there must not hash equal.
func hash_into(snapshot: Dictionary) -> void:
	snapshot["suspended_work_progress"] = StateCodec._encode_suspended_work_progress(suspended)

## The progress key of `tile`: the plain tile key when scope_job_id is empty,
## else the job-scoped "<job_id>:<x>_<y>".
static func key_of(tile: Vector2i, scope_job_id: String = "") -> String:
	if scope_job_id.is_empty():
		return "%d_%d" % [tile.x, tile.y]
	return "%s:%d_%d" % [scope_job_id, tile.x, tile.y]

## key_of()'s inverse: {tile: Vector2i, scope: String}. Job ids never contain
## ":" (the `^[a-z0-9_-]+$` id pattern), so the last ":" separates the scope.
static func key_parts(progress_key: String) -> Dictionary:
	var scope := ""
	var coord_part := progress_key
	var colon_index := progress_key.rfind(":")
	if colon_index >= 0:
		scope = progress_key.substr(0, colon_index)
		coord_part = progress_key.substr(colon_index + 1)
	var coords := coord_part.split("_")
	return {"tile": Vector2i(int(coords[0]), int(coords[1])), "scope": scope}

## The progress key of a specific job, by its own identity, never the tile's
## current reservation owner: terminal cleanup runs after the reservation is released.
func key_for_job(job_id: String, job: Dictionary) -> String:
	var target: Vector2i = job["target"]
	if String(job.get("kind", "")) != "rescue":
		return key_of(target)
	return key_of(target, job_id)

## The tile-addressed key used mid-work: resolves the tile's reservation owner.
func key(x: int, y: int) -> String:
	var owning_job_id: String = _queue.get_reservation_table().owner(_tile_key.call(x, y))
	if owning_job_id.is_empty():
		return key_of(Vector2i(x, y))
	# A construction site's footprint is owned by "site:<id>", not a job id.
	var owning_job := _queue.get_job(owning_job_id)
	if owning_job.is_empty():
		return key_of(Vector2i(x, y))
	return key_for_job(owning_job_id, owning_job)

## Cleanup for a job that just took a terminal transition: a rescue's own key
## always; an ordinary job's shared tile key only when it was the active owner.
func clear_terminated_job(job_id: String, job: Dictionary, was_active: bool) -> void:
	if not job.has("target"):
		return
	var kind := String(job.get("kind", ""))
	if kind == "rescue" or (was_active and _work_ticks.has(kind)):
		progress.erase(key_for_job(job_id, job))

## null when the tile has no stored progress, else its ticks remaining,
## whatever job wrote it (escape_trench's "already stamped?" check).
func get_progress(target: Vector2i):
	var progress_key := key(target.x, target.y)
	if not progress.has(progress_key):
		return null
	return int(progress[progress_key])

## start_work()'s job-scoped lookup (site_work is handled by WorldState first):
## the job's suspended snapshot (consumed), else the live value only when the
## job owns it; null (use the kind's duration) when another job owns the key.
func resume(target: Vector2i, job_id: String):
	if suspended.has(job_id):
		var value := int(suspended[job_id])
		suspended.erase(job_id)
		return value
	var progress_key := key(target.x, target.y)
	if not progress.has(progress_key):
		return null
	# An empty owner is an incident's own job_id-less stamp, which start_work() must pick up.
	var owner := String(owners.get(progress_key, ""))
	if not owner.is_empty() and owner != job_id:
		return null
	return int(progress[progress_key])

## Moves a still-queued (not terminated) job's `work` timer out of the shared
## tile cache into suspended before its colonist.work is cleared.
func suspend(work) -> void:
	if work == null:
		return
	var job_id := String(work.get("job_id", ""))
	var job := _queue.get_job(job_id)
	# "active" too: _pause_work_job() calls this before suspend_assignment() flips the status.
	if job.is_empty() or String(job.get("status", "")) not in ["active", "queued"]:
		return
	var kind := String(job.get("kind", ""))
	if kind == "incident" or not _work_ticks.has(kind):
		return
	suspended[job_id] = int(work.get("ticks_remaining", 0))
	var target: Vector2i = _work_target_for.call(job)
	var progress_key := key(target.x, target.y)
	if String(owners.get(progress_key, "")) == job_id:
		clear(target)

## The tile-cache write of WorldState._set_work_progress(); a non-empty job_id
## becomes the key's owner.
func record(target: Vector2i, ticks_remaining: int, job_id: String = "") -> void:
	var progress_key := key(target.x, target.y)
	progress[progress_key] = ticks_remaining
	if not job_id.is_empty():
		owners[progress_key] = job_id

func clear(target: Vector2i) -> void:
	var progress_key := key(target.x, target.y)
	progress.erase(progress_key)
	owners.erase(progress_key)

## Every non-incident terminal transition (WorldState._finish_job()): drops the
## job's suspended snapshot and its live key, but only a key it owns.
func release_owned(job_id: String, job: Dictionary) -> void:
	if job.is_empty() or not _work_ticks.has(String(job.get("kind", ""))):
		return
	suspended.erase(job_id)
	var target: Vector2i = _work_target_for.call(job)
	var progress_key := key(target.x, target.y)
	if String(owners.get(progress_key, "")) == job_id:
		clear(target)

## StateCodec.decode()'s post-load owner restore. Must run once jobs and
## paused jobs are restored but before an incident reconcile can cancel a job
## through _finish_job(). A persisted owner is kept only for a queued/active
## job of a work-ticked, non-incident kind; a key the save does not name (a
## save predating "workProgressOwners") is recovered from execution state; a
## key still ownerless is dropped unless an active incident's wait.
func restore_owners(persisted: Dictionary, colonists: Array, paused_jobs: Dictionary) -> void:
	owners.clear()
	for progress_key in persisted:
		var job_id := String(persisted[progress_key])
		var job := _queue.get_job(job_id)
		if job.is_empty() or String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var kind := String(job.get("kind", ""))
		if kind == "incident" or not _work_ticks.has(kind):
			continue
		if progress.has(progress_key):
			owners[progress_key] = job_id
	var reconstructed := reconstruct_owners(colonists, paused_jobs)
	for progress_key in reconstructed:
		if owners.has(progress_key):
			continue
		var candidate = reconstructed[progress_key]
		if candidate != null:
			owners[progress_key] = String(candidate)
	var incident_keys := active_incident_keys()
	for progress_key in progress.keys():
		if not owners.has(progress_key) and not incident_keys.has(progress_key):
			progress.erase(progress_key)

## Fallback owners from execution state every save carries: each colonist's
## "work" job and each paused (queued) job. Two candidates for one key are
## corruption, recorded as null so restore_owners() drops the key.
func reconstruct_owners(colonists: Array, paused_jobs: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for colonist in colonists:
		var work = colonist.get("work")
		if work != null:
			claim_reconstructed_owner(result, String(work.get("job_id", "")))
	for colonist_id in paused_jobs.keys():
		var job_id := String(paused_jobs[colonist_id])
		var job := _queue.get_job(job_id)
		if not job.is_empty() and String(job.get("status", "")) == "queued":
			claim_reconstructed_owner(result, job_id)
	return result

## Keys an active incident job holds without an owner, so restore_owners() keeps them.
func active_incident_keys() -> Dictionary:
	var keys: Dictionary = {}
	for job in _queue.get_jobs():
		if String(job.get("kind", "")) == "incident" and String(job.get("status", "")) == "active":
			var target: Vector2i = _work_target_for.call(job)
			keys[key(target.x, target.y)] = true
	return keys

func claim_reconstructed_owner(result: Dictionary, job_id: String) -> void:
	if job_id.is_empty():
		return
	var job := _queue.get_job(job_id)
	var kind := String(job.get("kind", ""))
	if job.is_empty() or kind == "incident" or not _work_ticks.has(kind):
		return
	var target: Vector2i = _work_target_for.call(job)
	var progress_key := key(target.x, target.y)
	if not progress.has(progress_key):
		return
	if result.has(progress_key):
		if String(result[progress_key]) != job_id:
			result[progress_key] = null
	else:
		result[progress_key] = job_id
