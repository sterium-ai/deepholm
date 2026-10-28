class_name ToolHandover
extends RefCounted

## Presentation-only overlay (ADR 013): while a job's fetch_tool toil waits for another
## colonist to drop a tool it reserved, surfaces that wait through the job record's existing
## reason/remedy/item_id/blocking_job_id fields. Applied by WorldState.get_jobs() to the
## detached copy only: never mutates JobQueue, never persisted, never read by the simulation.

const REASON := "waiting_for_tool_handover"
const REMEDY := "wait_for_tool_handover"

## Mutates `job` in place when it is active and its colonist's fetch_tool toil is waiting;
## a no-op otherwise. assignments is GlobalAssignment.get_assignments(); toils the ToilExecutor.
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
	var holder_assignment: Variant = assignments.get(String(wait["holder_colonist_id"]))
	job["reason"] = REASON
	job["remedy"] = REMEDY
	job["item_id"] = String(wait["item_id"])
	job["blocking_job_id"] = String(holder_assignment["job_id"]) if holder_assignment != null else ""
