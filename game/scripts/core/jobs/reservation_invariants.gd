class_name ReservationInvariants
extends RefCounted

const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

## Reusable invariant checks for any ReservationTable (colonist-ai.md 3.4 /
## §4 "Invariant"), callable by any test in game/scripts/tests/ -- t3/t4/t5
## reuse this for item/cell keys, not just today's tile keys. A plain
## function, not a test file: it returns violations instead of asserting, so
## callers can push()/_expect() them with their own failure messages.

## Every reservation key must belong to a job that is still active. jobs must
## be an Array of Dictionaries with at least "id" and "status"; the table's
## snapshot lists every currently reserved key and its owning job id.
## Returns the reserved keys whose owner is not an active job (an orphan).
## extra_active_owners (issue #406): additional owner strings -- not job ids --
## that are never flagged orphaned, even though they will never appear in
## `jobs`. A construction site reserves its own footprint tiles directly
## (owner "site:<id>"), the instant its `build` order is accepted, so no job
## ever owns that key; every existing caller passes nothing here (the default
## empty array), leaving this check byte-identical to before this parameter
## existed.
static func find_orphaned_reservations(table: ReservationTable, jobs: Array[Dictionary],
		extra_active_owners: Array[String] = []) -> Array[String]:
	var active_ids: Dictionary = {}
	for job in jobs:
		if String(job.get("status", "")) == "active":
			active_ids[String(job["id"])] = true
	for owner in extra_active_owners:
		active_ids[String(owner)] = true
	var orphans: Array[String] = []
	var owners := table.snapshot()
	for key in owners.keys():
		if not active_ids.has(String(owners[key])):
			orphans.append(String(key))
	return orphans

## No colonist may be idle while an eligible reachable unreserved job exists.
## colonists must be an Array of Dictionaries with at least "id", "kind" and
## "work" (idle means the colonist's mover component's route, read via
## ActorTable, and "work" are both null, the existing WorldState convention).
## table and job_key together decide "unreserved": job_key(job: Dictionary)
## -> String must return the ReservationTable key that job would hold once
## active (e.g. a "tile:"-prefixed key today; a future "item:"/"cell:" key
## producer for t3/t4 on the same table); a job whose key is already reserved
## by another job is excluded, exactly like a job with a nonempty "reason"
## already is. is_reachable, when valid, is called with each queued job
## Dictionary and must return whether its target is currently reachable;
## omitted, reachability is assumed already folded into "reason" (as
## JobQueue's own blocked_target_unreachable/blocked_reachability_unavailable
## reasons do). is_eligible, when valid, is called with each queued job
## Dictionary and must return whether it counts as eligible for this check
## beyond reservation/reachability (e.g. a colonist's labour table); omitted,
## every remaining queued job counts. content_registry must be the
## ContentRegistry ActorTable.get_component() (ADR 012) resolves a colonist's
## "mover" component against -- required whenever colonists is non-empty,
## unused otherwise; trailing so existing positional callers of job_key/
## is_reachable/is_eligible are unaffected. Returns the idle colonist ids
## found while at least one such job exists; empty when colonists is empty
## (nothing to check without colonist state).
static func find_idle_colonists_with_available_work(
		table: ReservationTable, colonists: Array[Dictionary], jobs: Array[Dictionary],
		job_key: Callable, is_reachable: Callable = Callable(),
		is_eligible: Callable = Callable(), content_registry = null) -> Array[String]:
	var idle: Array[String] = []
	if colonists.is_empty():
		return idle
	var work_available := false
	for job in jobs:
		if String(job.get("status", "")) != "queued":
			continue
		if not String(job.get("reason", "")).is_empty():
			continue
		if job_key.is_valid() and table.is_reserved(String(job_key.call(job))):
			continue
		if is_reachable.is_valid() and not bool(is_reachable.call(job)):
			continue
		if is_eligible.is_valid() and not bool(is_eligible.call(job)):
			continue
		work_available = true
		break
	if not work_available:
		return idle
	for colonist in colonists:
		var mover_component = ActorTableType.get_component(colonist, "mover", content_registry)
		var route = mover_component.get("route") if mover_component != null else null
		if route == null and colonist.get("work") == null:
			idle.append(String(colonist.get("id", "")))
	return idle

## Convenience wrapper combining both checks; colonists may be left empty
## when the caller (e.g. a JobQueue/ReservationTable-only test) has no
## colonist state to check, in which case job_key/is_reachable/is_eligible go
## unused. Any caller passing a non-empty colonists must pass job_key (see
## find_idle_colonists_with_available_work) so the reserved-key exclusion
## above is actually applied instead of silently skipped.
static func check(table: ReservationTable, jobs: Array[Dictionary],
		colonists: Array[Dictionary] = [], job_key: Callable = Callable(),
		is_reachable: Callable = Callable(), is_eligible: Callable = Callable(),
		content_registry = null) -> Dictionary:
	return {
		"orphaned_reservations": find_orphaned_reservations(table, jobs),
		"idle_with_available_work": find_idle_colonists_with_available_work(
			table, colonists, jobs, job_key, is_reachable, is_eligible, content_registry),
	}
