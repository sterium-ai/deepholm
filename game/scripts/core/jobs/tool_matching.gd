class_name ToolMatching
extends RefCounted

## Pure nearest-free-tool search and needs_tool gate helpers for the fetch_tool toil
## (colonist-ai.md 2/3.3, ADR 013). Plain data in, plain data out; no side effects:
## the caller (ToilExecutor, JobQueue, GlobalAssignment) reserves or mutates.

## Manhattan-nearest tool of `kind` that is unreserved or already reserved by job_id
## (a retry reuses its own reservation); ties broken by item id for determinism.
## excluded_ids skips candidates already proven unreachable in this fetch attempt.
static func find_nearest_free_tool(kind: String, from: Vector3i, job_id: String,
		tool_items: Array[Dictionary], reservation_of: Callable, colonist_positions: Dictionary,
		excluded_ids: Array = []) -> Dictionary:
	var best_id := ""
	var best_target := Vector3i.ZERO
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
		var target: Variant = item_target(item, colonist_positions)
		if target == null:
			continue
		var distance: int = TileGrid.manhattan(target, from)
		if best_id.is_empty() or distance < best_distance or (distance == best_distance and item_id < best_id):
			best_id = item_id
			best_target = target
			best_distance = distance
	if best_id.is_empty():
		return {"found": false}
	return {"found": true, "item_id": best_id, "target": best_target}

## colonist_id -> current tile, for item_target()'s "held" candidates.
static func colonist_position_map(colonists: Array) -> Dictionary:
	var positions: Dictionary = {}
	for c in colonists:
		positions[String(c["id"])] = TileGrid.tile_of(c)
	return positions

## The tile a tool item occupies: its ground/stockpile cell, or its holder's position;
## null when the holder is not in `colonist_positions`.
static func item_target(item: Dictionary, colonist_positions: Dictionary):
	var location: Dictionary = item.get("location", {})
	match String(location.get("type", "")):
		"ground", "stockpile":
			return TileGrid.tile_of(location)
		"held":
			var holder := String(location.get("colonist_id", ""))
			if not colonist_positions.has(holder):
				return null
			return colonist_positions[holder]
		_:
			return null

## JobQueue's needs_tool activation gate (ADR 013), with JobQueue._tick_haul()'s
## retry_at/backoff. While still backed off it returns false without calling `block`
## again, so the displayed reason refreshes once per backoff window.
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

## Applies the needs_tool backoff once fetch_tool proves every candidate unreachable
## (ToilBindings._toil_on_no_tool_found()).
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

## True while the needs_tool backoff is active; JobQueue.tick() checks it before
## reachability so a backed-off job keeps blocked_no_tool instead of a stale
## blocked_target_unreachable. `<=` (not gate_check()'s `<`): get_reservations() lags tick() by one.
static func gate_backed_off(job: Dictionary, tick: int, requirement_of: Callable) -> bool:
	if not requirement_of.is_valid():
		return false
	var requirement: Dictionary = requirement_of.call(String(job["kind"]))
	if requirement.is_empty():
		return false
	return tick <= int(job["retry_at"])

## Aging-preserved requeue shared by GlobalAssignment.suspend_assignment() (ADR 009) and
## requeue_assignment(); mutates `waiting`/`cursors` in place, no-op if job_id was never
## chosen or is already waiting. A non-empty restrict_to pins the entry to that colonist.
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
