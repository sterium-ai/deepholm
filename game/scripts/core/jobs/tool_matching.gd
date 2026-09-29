class_name ToolMatching
extends RefCounted

## Pure nearest-free-tool search for the fetch_tool toil (colonist-ai.md 2/
## 3.3, issue #271): given every tool item WorldState tracks and the position
## of every colonist (for a "held by another colonist" candidate), finds the
## nearest one of `kind` that is either unreserved or already reserved by
## `job_id` itself (so a retry after an interrupt reuses its own in-flight
## reservation instead of leaking a second one). No side effects: the caller
## (toil_executor.gd) reserves/picks up whatever this returns. Kept dependency-
## free (plain data in, plain data out) so it needs no scene, node or WorldState
## reference to test, extracted out of toil_executor.gd purely to keep that
## file under its line budget (docs/architecture/core-budgets.json).

## Manhattan-nearest match, ties broken by item id for determinism (no wall-
## clock/global randomness, colonist-ai.md/AGENTS.md's simulation rules).
## excluded_ids skips a candidate already proven unreachable earlier in the
## same fetch attempt (issue #271 round 3: a closer tool enclosed by walls
## must not block a farther, reachable one forever), so ToilExecutor can
## re-call this after each unreachable result until either a workable
## candidate is found or every match has been tried.
static func find_nearest_free_tool(kind: String, from: Vector2i, job_id: String,
		tool_items: Array[Dictionary], reservation_of: Callable, colonist_positions: Dictionary,
		excluded_ids: Array = []) -> Dictionary:
	var best_id := ""
	var best_target := Vector2i.ZERO
	var best_distance := -1
	for item in tool_items:
		if String(item.get("kind", "")) != kind:
			continue
		var item_id := String(item["id"])
		if item_id in excluded_ids:
			continue
		var owner := String(reservation_of.call(item_id))
		if not owner.is_empty() and owner != job_id:
			continue
		var target = item_target(item, colonist_positions)
		if target == null:
			continue
		var distance: int = absi(target.x - from.x) + absi(target.y - from.y)
		if best_id.is_empty() or distance < best_distance or (distance == best_distance and item_id < best_id):
			best_id = item_id
			best_target = target
			best_distance = distance
	if best_id.is_empty():
		return {"found": false}
	return {"found": true, "item_id": best_id, "target": best_target}

## colonist_id -> current tile (issue #271), for item_target()'s "held"
## candidates below. Shared by WorldState and ToilExecutor rather than each
## keeping its own identical helper.
static func colonist_position_map(colonists: Array) -> Dictionary:
	var positions: Dictionary = {}
	for c in colonists:
		positions[String(c["id"])] = Vector2i(int(c["x"]), int(c["y"]))
	return positions

## The tile a tool item currently occupies: its own ground/stockpile location,
## or the current position of whichever colonist holds it. Null when a held
## item's holder is not in `colonist_positions` (should not happen for a live
## colonist, but keeps this pure function total rather than indexing blindly).
static func item_target(item: Dictionary, colonist_positions: Dictionary):
	var location: Dictionary = item.get("location", {})
	match String(location.get("type", "")):
		"ground", "stockpile":
			return Vector2i(int(location["x"]), int(location["y"]))
		"held":
			var holder := String(location.get("colonist_id", ""))
			if not colonist_positions.has(holder):
				return null
			return colonist_positions[holder]
		_:
			return null

## JobQueue's needs_tool activation gate (issue #271 round 5, ADR 012):
## mirrors _tick_haul()'s own retry_at/backoff_ticks backoff. `block` is
## job_queue.gd's own private _block(job, JobQueue.BLOCKED_NO_TOOL, remedy),
## kept there so this stays a plain data helper. Quietly returns false while
## still backed off, without calling `block` again, so a queued job's own
## displayed reason is only refreshed once per backoff window.
static func gate_check(job: Dictionary, tick: int, requirement_of: Callable,
		tool_available: Callable, block: Callable) -> bool:
	if not requirement_of.is_valid():
		return true
	var requirement: Dictionary = requirement_of.call(String(job["kind"]))
	if requirement.is_empty():
		return true
	if tick < int(job["retry_at"]):
		return false
	if bool(tool_available.call(String(job["id"]), String(requirement["kind"]))):
		return true
	_apply_backoff(job, tick, requirement)
	block.call(job, "craft_or_find:%s" % String(requirement["kind"]))
	return false

## Applies job_id's own needs_tool backoff directly once fetch_tool itself
## proves every known candidate unreachable (WorldState._toil_on_no_tool_found(),
## distinct from gate_check()'s "does a match exist at all" question above).
static func gate_force_backoff(job: Dictionary, tick: int, requirement_of: Callable, block: Callable) -> void:
	if not requirement_of.is_valid():
		return
	var requirement: Dictionary = requirement_of.call(String(job["kind"]))
	if requirement.is_empty():
		return
	_apply_backoff(job, tick, requirement)
	block.call(job, "craft_or_find:%s" % String(requirement["kind"]))

static func _apply_backoff(job: Dictionary, tick: int, requirement: Dictionary) -> void:
	var backoff: int = int(job["backoff_ticks"])
	var base: int = int(requirement["retry_base_ticks"])
	var cap: int = int(requirement["retry_cap_ticks"])
	backoff = base if backoff == 0 else mini(backoff * 2, cap)
	job["backoff_ticks"] = backoff
	job["retry_at"] = tick + backoff

## True while job_id's own needs_tool backoff (gate_check()'s retry_at) is
## still active, checked BEFORE reachability/reservation-owner in
## JobQueue.tick() (mirroring _tick_haul()'s own early backoff return, issue
## #271 round 6 review): otherwise the scheduler's own reservations-shortcut
## selection of a backed-off job fed a stale/no-search-this-tick _can_reach()
## result into the SAME job and overwrote blocked_no_tool's reason with
## blocked_target_unreachable for the entire backoff window, even though the
## target itself is genuinely reachable. Uses `<=`, not gate_check()'s own
## `<`: JobQueue.get_reservations() (consulted by GlobalAssignment.tick()
## BEFORE this same cycle's tick() call increments `_tick`) still reports
## this job "reserved" one tick later than tick()'s own loop would otherwise
## stop treating it as backed off, so the boundary tick must stay gated here
## too or that one tick falls through to a reachability result no real route
## search this cycle ever produced.
static func gate_backed_off(job: Dictionary, tick: int, requirement_of: Callable) -> bool:
	if not requirement_of.is_valid():
		return false
	var requirement: Dictionary = requirement_of.call(String(job["kind"]))
	if requirement.is_empty():
		return false
	return tick <= int(job["retry_at"])

## Shared aging-preserved requeue for GlobalAssignment.suspend_assignment()
## (ADR 009 critical-need interrupt) and .requeue_assignment() (issue #271
## round 6 review: an ordinary fetch_tool failure), extracted to keep both
## call sites' own files under their line budgets. Mutates `waiting`/
## `cursors` in place (both are shared-by-reference Godot containers). A
## no-op when job_id was never chosen or is already back in `waiting`.
## restrict_to overrides the reinserted entry's own restriction only when
## non-empty -- suspend_assignment() always pins to `worker` (the same
## colonist resumes it later); requeue_assignment() passes "" to keep the
## entry's ORIGINAL restrict_to (usually empty), since an ordinary failure
## must return the job to the fair pool for ANY eligible colonist, not just
## the one whose own attempt just failed.
static func reinsert_activated_entry(waiting: Array, cursors: Dictionary, activated_entries: Dictionary,
		job_id: String, restrict_to: String, entry_before: Callable) -> void:
	if not activated_entries.has(job_id):
		return
	for entry in waiting:
		if entry["id"] == job_id:
			return
	var entry: Dictionary = (activated_entries[job_id] as Dictionary).duplicate(true)
	if not restrict_to.is_empty():
		entry["restrict_to"] = restrict_to
	var index := 0
	while index < waiting.size() and bool(entry_before.call(waiting[index], entry)):
		index += 1
	waiting.insert(index, entry)
	for w in cursors:
		if int(cursors[w]) > index:
			cursors[w] += 1
