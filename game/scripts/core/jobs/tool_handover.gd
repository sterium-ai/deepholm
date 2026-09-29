class_name ToolHandover
extends RefCounted

## Presentation-only overlay (issue #266, ADR 012): while a job's own
## fetch_tool toil is waiting on a foreign colonist to physically drop a tool
## it already reserved (ToolDropToil.waiting_for_handover(), case (b)'s third
## location), surfaces that wait through the job record's own existing
## generic reason/remedy/itemId/blockingJobId fields -- reused, not new
## persisted state (docs/architecture/extension-points.md's "Toil" recipe: a
## scheduler/executor reason, not a new decision layer) -- the same way
## JobQueue's own _block()/blocking_job_id already surfaces every other block
## reason. Called from WorldState.get_jobs() only, on the already-detached
## duplicate JobQueue.get_jobs() itself returns: never mutates JobQueue's own
## state, never persisted (to_save_state() reads _scheduler.queue.get_jobs()
## directly, not this overlay), and never consulted by any simulation
## decision (ToilExecutor's own wait behaviour is driven by
## ToolDropToil.waiting_for_handover() directly).

const REASON := "waiting_for_tool_handover"
const REMEDY := "wait_for_tool_handover"

## Mutates `job` in place when it is active and its own colonist's fetch_tool
## toil is currently waiting; a no-op otherwise. assignments is
## GlobalAssignment.get_assignments() (worker -> {"job_id", ...}); toils is
## WorldState's own ToilExecutor instance.
static func apply(job: Dictionary, assignments: Dictionary, toils) -> void:
	if String(job.get("status", "")) != "active":
		return
	var job_id := String(job["id"])
	var colonist_id := ""
	for worker in assignments:
		if String((assignments[worker] as Dictionary)["job_id"]) == job_id:
			colonist_id = String(worker)
			break
	if colonist_id.is_empty():
		return
	var wait: Dictionary = toils.waiting_for_handover(colonist_id, job_id)
	if wait.is_empty():
		return
	var holder_assignment = assignments.get(String(wait["holder_colonist_id"]))
	job["reason"] = REASON
	job["remedy"] = REMEDY
	job["item_id"] = String(wait["item_id"])
	job["blocking_job_id"] = String(holder_assignment["job_id"]) if holder_assignment != null else ""
