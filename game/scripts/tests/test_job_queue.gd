extends SceneTree

const QueueType = preload("res://scripts/core/jobs/job_queue.gd")
const InvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
var _failed := false

func _init() -> void:
	_check_reservations_and_recovery()
	_check_reachability_and_reason_changes()
	_check_terminal_releases()
	_check_priorities_and_rejections()
	_check_custom_job_kind()
	_check_isolation()
	_check_replay()
	_check_reservation_invariants_after_scripted_sequence()
	_check_shared_table_releases_every_owned_key()
	_check_labour_disabled_immediate_during_haul_backoff()
	_check_active_item_marker()
	if _failed:
		quit(1)
		return
	print("test_job_queue: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _new_queue(reachability: Callable = Callable()) -> JobQueue:
	var rng := RandomNumberGenerator.new()
	rng.seed = 45
	if not reachability.is_valid():
		reachability = func(_target: Vector2i) -> bool: return true
	return QueueType.new(rng, reachability)

func _submit(queue: JobQueue, target: Vector2i, priority: int = QueueType.Priority.NORMAL, kind: String = "dig") -> String:
	var result := queue.submit_dig(target, priority, kind)
	_expect(result["ok"], "expected valid submission")
	return result.get("job_id", "")

## Finding (issue #267 review round 2): set_labour_disabled() used to leave a
## haul job's blocked_destination_full reason untouched while its backoff was
## unexpired, so a colony with the labour off entirely never displayed
## labour_disabled on it. Backoff timing (retry_at) is now tracked
## independently of the displayed reason string: set_labour_disabled() may
## freely display labour_disabled immediately, mid-backoff, while
## _tick_haul()'s own `_tick < retry_at` gate (not a reason string match)
## still blocks a fresh destination attempt until the backoff naturally
## elapses, and get_reservations() still reports the target reserved on that
## same retry_at-only gate so GlobalAssignment keeps refreshing it without
## re-routing.
func _check_labour_disabled_immediate_during_haul_backoff() -> void:
	var queue := _new_queue()
	queue.set_haul_backoff(10, 40)
	var job_id := _submit(queue, Vector2i(5, 5), QueueType.Priority.NORMAL, "haul")
	_expect(queue.attach_item(job_id, "item_1"), "attach_item must accept a queued haul job")
	queue.set_haul_destination_finder(func(_item_id: String): return null)
	queue.tick()
	var job := queue.get_job(job_id)
	_expect(job["status"] == "queued" and job["reason"] == "blocked_destination_full",
		"a haul job with no free destination must block with blocked_destination_full")
	var retry_at := int(job["retry_at"])

	queue.set_labour_disabled(job_id, true)
	_expect(queue.get_job(job_id)["reason"] == "labour_disabled",
		"disabling labour must be visible immediately even during an active haul backoff")

	# One tick short of retry_at: JobQueue.tick() must make no destination
	# attempt at all, regardless of the now-different displayed reason.
	queue.restore(queue.get_jobs(), retry_at - 2, queue.get_next_id(), queue.get_sequence())
	queue.tick()
	_expect(not _has_event(queue, "haul_destination_attempt"),
		"no destination attempt may occur before the backoff naturally elapses")
	_expect(queue.get_reservations().get(Vector2i(5, 5)) == job_id,
		"the backed-off target must still report reserved while labour is disabled")

	# Re-enabling labour mid-backoff: exactly one job_unblocked, still no
	# destination attempt until retry_at.
	queue.set_labour_disabled(job_id, false)
	_expect(_count_events(queue, "job_unblocked") == 1,
		"re-enabling labour mid-backoff must emit exactly one job_unblocked event")
	_expect(queue.get_job(job_id)["reason"] == "", "re-enabling labour must clear the displayed reason")

	# retry_at finally elapses: the destination search resumes on its own.
	queue.restore(queue.get_jobs(), retry_at, queue.get_next_id(), queue.get_sequence())
	queue.tick()
	_expect(_has_event(queue, "haul_destination_attempt"),
		"once the backoff naturally elapses, the destination search must resume")

func _has_event(queue: JobQueue, event_type: String) -> bool:
	return _count_events(queue, event_type) > 0

func _count_events(queue: JobQueue, event_type: String) -> int:
	var count := 0
	for event in queue.get_events():
		if event["type"] == event_type:
			count += 1
	return count

func _check_reservations_and_recovery() -> void:
	var queue := _new_queue()
	var target := Vector2i(4, 5)
	var owner := _submit(queue, target)
	var waiter := _submit(queue, target)
	var independent := _submit(queue, Vector2i(6, 5))
	queue.tick()
	_expect(queue.get_job(owner)["status"] == "active", "first job must activate")
	var blocked := queue.get_job(waiter)
	_expect(blocked["status"] == "queued", "blocked is not a sixth status")
	_expect(blocked["reason"] == "blocked_target_reserved", "duplicate target needs typed block")
	_expect(blocked["remedy"] == "wait_for_target_release", "reserved block needs remedy")
	_expect(blocked["blocking_job_id"] == owner, "block must identify current owner")
	_expect(queue.get_job(independent)["status"] == "active", "blocked job must not stop same-tick evaluation")
	_expect(queue.get_reservations()[target] == owner, "waiter must not overwrite reservation")
	var event_count := queue.get_events().size()
	queue.tick()
	_expect(queue.get_events().size() == event_count, "unchanged block must not duplicate events")
	_expect(queue.cancel(owner)["ok"], "cancel must succeed")
	_expect(not queue.get_reservations().has(target), "cancel must release before next tick")
	_expect(queue.get_job(owner)["reason"] == "cancelled_by_command", "cancel must explain cause")
	queue.tick()
	_expect(queue.get_reservations()[target] == waiter, "blocked job must recover without resubmission")
	var recovered := queue.get_job(waiter)
	_expect(recovered["status"] == "active" and recovered["reason"] == "", "activation clears reason")
	_expect(recovered["remedy"] == "" and recovered["blocking_job_id"] == "", "activation clears stale block details")
	_expect(queue.get_jobs().size() == 3, "blocked jobs must be retained")

func _check_reachability_and_reason_changes() -> void:
	var inaccessible := {Vector2i(1, 2): true}
	var queue := _new_queue(func(target: Vector2i) -> bool: return not inaccessible.has(target))
	var blocked := _submit(queue, Vector2i(1, 2), QueueType.Priority.HIGH)
	var other := _submit(queue, Vector2i(3, 2), QueueType.Priority.LOW)
	queue.tick()
	_expect(queue.get_job(blocked)["reason"] == "blocked_target_unreachable", "unreachable needs specific reason")
	_expect(queue.get_job(blocked)["remedy"] == "restore_target_access", "unreachable needs remedy")
	_expect(not queue.get_reservations().has(Vector2i(1, 2)), "unreachable target must not be reserved")
	_expect(queue.get_job(other)["status"] == "active", "unreachable high priority must not stop low priority")
	inaccessible.clear()
	queue.tick()
	_expect(queue.get_job(blocked)["status"] == "active", "reachability change must retry original job")
	var waiter := _submit(queue, Vector2i(1, 2))
	queue.tick()
	inaccessible[Vector2i(1, 2)] = true
	queue.cancel(blocked)
	queue.tick()
	var changed := queue.get_job(waiter)
	_expect(changed["reason"] == "blocked_target_unreachable", "released target must update to actual new cause")
	_expect(changed["blocking_job_id"] == "", "new cause must clear stale reserving owner")
	inaccessible.clear()
	queue.tick()
	_expect(queue.get_job(waiter)["status"] == "active", "job must recover after multiple block causes")
	var malformed := _new_queue(func(_target: Vector2i) -> int: return 1)
	var malformed_id := _submit(malformed, Vector2i.ZERO)
	malformed.tick()
	_expect(malformed.get_job(malformed_id)["reason"] == "blocked_reachability_unavailable", "non-boolean callback must fail closed")
	var rng := RandomNumberGenerator.new()
	rng.seed = 45
	var missing := QueueType.new(rng, Callable())
	var missing_id := _submit(missing, Vector2i.ZERO)
	missing.tick()
	_expect(missing.get_job(missing_id)["reason"] == "blocked_reachability_unavailable", "missing callback must explain block")

func _check_terminal_releases() -> void:
	for operation in ["cancel", "fail", "invalidate", "complete"]:
		var queue := _new_queue()
		var target := Vector2i(8, 8)
		var owner := _submit(queue, target)
		var waiter := _submit(queue, target)
		queue.tick()
		var result: Dictionary = queue.call(operation, owner)
		_expect(result["ok"], "%s should succeed on active job" % operation)
		_expect(not queue.get_reservations().has(target), "%s must release immediately" % operation)
		var status := "failed"
		if operation == "cancel":
			status = "cancelled"
		elif operation == "complete":
			status = "completed"
		_expect(queue.get_job(owner)["status"] == status, "terminal status must match schema")
		if operation != "complete":
			_expect(not String(queue.get_job(owner)["reason"]).is_empty(), "terminal interruption must explain cause")
			_expect(not String(queue.get_job(owner)["remedy"]).is_empty(), "terminal interruption needs remedy")
		if operation == "invalidate":
			_expect(queue.get_job(owner)["reason"] == "target_invalidated", "invalidation must be distinguishable from execution failure")
		queue.tick()
		_expect(queue.get_reservations()[target] == waiter, "%s must unblock later job" % operation)
		_expect(not queue.cancel(owner)["ok"], "terminal job cannot restart or be terminated twice")
		_expect(queue.get_reservations()[target] == waiter, "old owner must never release new owner's reservation")
	for operation in ["cancel", "fail", "invalidate"]:
		var queue := _new_queue()
		var owner := _submit(queue, Vector2i.ZERO)
		var waiter := _submit(queue, Vector2i.ZERO)
		queue.tick()
		var result: Dictionary = queue.call(operation, waiter)
		_expect(result["ok"], "blocked job must allow terminal commands")
		_expect(queue.get_reservations()[Vector2i.ZERO] == owner, "terminating waiter must not release owner's reservation")

func _check_priorities_and_rejections() -> void:
	var queue := _new_queue()
	_expect(QueueType.Priority.size() == 3, "exactly three priority levels required")
	for priority in [-1, 3, 99]:
		var result := queue.submit_dig(Vector2i.ZERO, priority)
		_expect(not result["ok"] and result["rejection"]["reason"] == "invalid_priority", "invalid priority must reject")
	_expect(not queue.submit_dig(Vector2i(-1, 0))["ok"], "negative target must reject")
	_expect(queue.get_jobs().is_empty(), "rejections must not create jobs")
	var low := _submit(queue, Vector2i.ZERO, QueueType.Priority.LOW)
	var normal := _submit(queue, Vector2i.ZERO, QueueType.Priority.NORMAL)
	var high := _submit(queue, Vector2i.ZERO, QueueType.Priority.HIGH)
	_expect(low == "job_1", "rejections must not consume IDs")
	_expect(not queue.complete(low)["ok"], "queued job cannot complete")
	_expect(not queue.cancel("missing")["ok"], "unknown ID must reject")
	queue.tick()
	_expect(queue.get_reservations()[Vector2i.ZERO] == high, "high priority evaluated first")
	queue.complete(high)
	queue.tick()
	_expect(queue.get_reservations()[Vector2i.ZERO] == normal, "normal priority before low")
	_expect(queue.get_job(low)["blocking_job_id"] == normal, "block owner must refresh when reservation changes")
	queue.complete(normal)
	queue.tick()
	_expect(queue.get_reservations()[Vector2i.ZERO] == low, "low priority remains eligible")

func _check_custom_job_kind() -> void:
	var queue := _new_queue()
	var result := queue.submit_dig(Vector2i(2, 2), QueueType.Priority.NORMAL, "chop")
	_expect(result["ok"], "custom job kind submission must succeed")
	if result["ok"]:
		_expect(queue.get_job(result["job_id"])["kind"] == "chop", "custom job kind must be stored on the job")
	var default_result := queue.submit_dig(Vector2i(3, 2))
	_expect(default_result["ok"], "default job kind submission must succeed")
	if default_result["ok"]:
		_expect(queue.get_job(default_result["job_id"])["kind"] == "dig", "default job kind must remain dig")

func _check_isolation() -> void:
	var queue := _new_queue()
	var job_id := _submit(queue, Vector2i.ZERO)
	queue.tick()
	var job := queue.get_job(job_id)
	job["status"] = "cancelled"
	var jobs := queue.get_jobs()
	jobs[0]["reason"] = "mutated"
	jobs.clear()
	var reservations := queue.get_reservations()
	reservations.clear()
	var events := queue.get_events()
	events[0]["data"]["mutated"] = true
	events.clear()
	_expect(queue.get_job(job_id)["status"] == "active", "job getter must detach state")
	_expect(queue.get_jobs().size() == 1 and queue.get_job(job_id)["reason"] == "", "jobs getter must deep copy")
	_expect(queue.get_reservations()[Vector2i.ZERO] == job_id, "reservations getter must detach state")
	_expect(not queue.get_events()[0]["data"].has("mutated"), "events getter must deep copy")
	_expect(queue.get_job("missing").is_empty(), "unknown read must be empty")

func _replay() -> JobQueue:
	var unavailable := {Vector2i(7, 7): true}
	var queue := _new_queue(func(target: Vector2i) -> bool: return not unavailable.has(target))
	var first := _submit(queue, Vector2i.ZERO)
	_submit(queue, Vector2i.ZERO)
	_submit(queue, Vector2i(7, 7))
	# Exercise lexical IDs beyond job_9 as well as insertion order.
	for x in range(1, 12):
		_submit(queue, Vector2i(x, 3), x % 3)
	queue.tick()
	queue.cancel(first)
	unavailable.clear()
	queue.tick()
	return queue

func _check_replay() -> void:
	var first := _replay()
	var second := _replay()
	_expect(first.get_events() == second.get_events(), "identical seeded command runs must have identical ordered events")
	_expect(first.get_jobs() == second.get_jobs(), "replayed jobs must match")
	_expect(first.get_reservations() == second.get_reservations(), "replayed reservations must match")
	_expect(first.get_tick() == 2 and second.get_tick() == 2, "only explicit ticks advance time")
	var seen := {}
	var events := first.get_events()
	for event in events:
		seen[event["type"]] = true
	for required in ["reservation_acquired", "reservation_released", "job_blocked", "job_cancelled", "job_unblocked"]:
		_expect(seen.has(required), "replay must exercise %s" % required)
	for i in range(1, events.size()):
		var a: Dictionary = events[i - 1]
		var b: Dictionary = events[i]
		var ordered: bool
		if a["tick"] != b["tick"]:
			ordered = a["tick"] < b["tick"]
		elif a["system_priority"] != b["system_priority"]:
			ordered = a["system_priority"] < b["system_priority"]
		elif a["entity_id"] != b["entity_id"]:
			ordered = a["entity_id"] < b["entity_id"]
		else:
			ordered = a["sequence"] < b["sequence"]
		_expect(ordered, "events must use canonical stable ordering")

## Exercises the reusable invariant helper (colonist-ai.md 3.4/§4) against a
## scripted submit/cancel/fail/complete/invalidate sequence: after every
## terminal transition, no reservation may outlive its job.
func _check_reservation_invariants_after_scripted_sequence() -> void:
	var queue := _new_queue()
	var targets: Array[Vector2i] = []
	for i in range(6):
		targets.append(Vector2i(i, 9))
	var jobs: Array[String] = []
	for target in targets:
		jobs.append(_submit(queue, target))
	queue.tick()
	for job_id in jobs:
		_expect(queue.get_job(job_id)["status"] == "active", "distinct targets must all activate")
	_expect(queue.cancel(jobs[0])["ok"], "cancel must succeed")
	_expect(queue.fail(jobs[1])["ok"], "fail must succeed")
	_expect(queue.complete(jobs[2])["ok"], "complete must succeed")
	_expect(queue.invalidate(jobs[3])["ok"], "invalidate must succeed")
	queue.tick()
	var result := InvariantsType.check(queue.get_reservation_table(), queue.get_jobs())
	_expect(result["orphaned_reservations"].is_empty(),
		"cancel/fail/complete/invalidate must never leave an orphaned reservation")
	# Resubmit onto a cancelled job's freed target and finish it too: the
	# invariant must still hold once every terminal path has fired at least once.
	var resubmitted := _submit(queue, targets[0])
	queue.tick()
	_expect(queue.complete(resubmitted)["ok"], "resubmitted job on a freed target must complete")
	var final_result := InvariantsType.check(queue.get_reservation_table(), queue.get_jobs())
	_expect(final_result["orphaned_reservations"].is_empty(), "zero orphaned reservations after every scripted case")

## get_reservation_table() must expose the queue's actual shared
## ReservationTable (not a detached copy), and every terminal transition must
## release every key the job owns on it -- not only the tile key JobQueue
## derives itself -- so a future item/cell reservation acquired directly on
## this table for the same job is released too, with its own
## reservation_released event.
func _check_shared_table_releases_every_owned_key() -> void:
	for operation in ["cancel", "fail", "invalidate", "complete"]:
		var queue := _new_queue()
		var target := Vector2i(9, 9)
		var owner := _submit(queue, target)
		queue.tick()
		var table := queue.get_reservation_table()
		_expect(table.acquire("item:1", owner),
			"the shared table must accept a future namespaced key for the active job")
		var result: Dictionary = queue.call(operation, owner)
		_expect(result["ok"], "%s should succeed on active job" % operation)
		_expect(not table.is_reserved("item:1"),
			"%s must release every key the job owns on the shared table, not only its tile key" % operation)
		_expect(not queue.get_reservations().has(target), "%s must still release the tile key" % operation)
		var released_keys := []
		for event in queue.get_events():
			if event["type"] == "reservation_released":
				released_keys.append(event["data"]["key"])
		_expect("item:1" in released_keys, "%s must emit reservation_released for the extra key too" % operation)

## set_active_item_marker()/get_active_item_marker() (issue #266 round 5
## review): the live handle ToolDropToil now uses to persist which tool item
## an in-flight drop_tool leg concerns, directly on the job's own field, so
## the marker survives a save/load through JobQueue's ordinary job encoding
## (state_codec.gd) without a new field. Round 6 review: that field is
## blockingJobId, not itemId -- itemId already carries a haul job's own
## cargo identity (see job_queue.gd's set_active_item_marker() doc comment),
## and this marker is written for ANY active job kind drop_tool runs against,
## haul included, so it must never collide with itemId's existing meaning.
## Covers: a no-op on a queued job (nothing to mark before activation), a
## no-op on a terminal job (dig_1 already finished, no in-flight leg left to
## mark), a live write visible immediately through the getter (get_job()'s
## own .duplicate(true) must never be what the getter reads), the marker
## surviving restore() exactly like any other job field, and
## set_active_item_marker(job_id, "") clearing it back to empty on completion.
func _check_active_item_marker() -> void:
	var queue := _new_queue()
	var target := Vector2i(4, 4)
	var job_id := _submit(queue, target)

	queue.set_active_item_marker(job_id, "tool_1")
	_expect(queue.get_active_item_marker(job_id) == "", "a queued job is not active yet -- nothing to mark")
	_expect(queue.get_job(job_id)["blocking_job_id"] == "", "the marker must not leak into a queued job's own blockingJobId either")

	queue.tick()
	_expect(queue.get_job(job_id)["status"] == "active", "the job must be active before the marker can be set")
	_expect(queue.get_active_item_marker(job_id) == "", "the marker must start empty on a freshly activated job")

	queue.set_active_item_marker(job_id, "tool_1")
	_expect(queue.get_active_item_marker(job_id) == "tool_1",
		"the getter must see a marker this same call already wrote, not a stale duplicate")
	_expect(queue.get_job(job_id)["blocking_job_id"] == "tool_1",
		"the marker is the job's own blockingJobId field, so get_job() must see it too")
	_expect(queue.get_job(job_id)["item_id"] == "",
		"the marker must never touch the job's own itemId field -- a haul job needs that for its cargo")

	queue.set_active_item_marker(job_id, "tool_2")
	_expect(queue.get_active_item_marker(job_id) == "tool_2", "a second write must overwrite the first, not append")

	# Persistence: restore() re-derives everything from the jobs array alone
	# (state_codec.gd's own job encoding already round-trips blockingJobId for
	# every job regardless of kind) -- no separate marker state exists to lose.
	var restored := _new_queue()
	restored.restore(queue.get_jobs(), queue.get_tick(), queue.get_next_id(), queue.get_sequence())
	_expect(restored.get_active_item_marker(job_id) == "tool_2",
		"the marker must survive restore() through the job's own ordinary blockingJobId field")

	queue.set_active_item_marker(job_id, "")
	_expect(queue.get_active_item_marker(job_id) == "", "clearing the marker back to empty must be visible immediately")

	var complete_result: Dictionary = queue.complete(job_id)
	_expect(complete_result["ok"], "completing the job must succeed")
	queue.set_active_item_marker(job_id, "tool_3")
	_expect(queue.get_active_item_marker(job_id) == "",
		"a terminal job has no in-flight leg left to mark -- the write must be a no-op")
	_expect(queue.get_job(job_id)["blocking_job_id"] == "",
		"a terminal job's own blockingJobId must stay untouched by a marker write after completion")
