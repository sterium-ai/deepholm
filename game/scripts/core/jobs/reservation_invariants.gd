class_name ReservationInvariants
extends RefCounted

const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

## Reusable ReservationTable invariant checks for tests (colonist-ai.md 3.4 "Invariant");
## they return violations instead of asserting.

## Every reservation key must belong to an active job; returns the orphaned keys.
## extra_active_owners are non-job owners never flagged (a site's "site:<id>" footprint).
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

## No colonist may be idle while an eligible, reachable, unreserved job exists; returns the
## idle colonist ids. job_key(job) is the key the job would hold; is_reachable/is_eligible
## are optional filters; content_registry resolves the "mover" component (ADR 012).
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
		var mover_component: Variant = ActorTableType.get_component(colonist, "mover", content_registry)
		var route: Variant = mover_component.get("route") if mover_component != null else null
		if route == null and colonist.get("work") == null:
			idle.append(String(colonist.get("id", "")))
	return idle

## Both checks; colonists may be empty, otherwise job_key is required.
static func check(table: ReservationTable, jobs: Array[Dictionary],
		colonists: Array[Dictionary] = [], job_key: Callable = Callable(),
		is_reachable: Callable = Callable(), is_eligible: Callable = Callable(),
		content_registry = null) -> Dictionary:
	return {
		"orphaned_reservations": find_orphaned_reservations(table, jobs),
		"idle_with_available_work": find_idle_colonists_with_available_work(
			table, colonists, jobs, job_key, is_reachable, is_eligible, content_registry),
	}
