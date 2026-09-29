extends SceneTree

## Covers ReservationTable (colonist-ai.md 3.4) directly -- acquire/release/
## owner-lookup and the reusable invariant helper -- independent of JobQueue.
## See test_job_queue.gd for the helper exercised against a real job list.

const TableType = preload("res://scripts/core/jobs/reservation_table.gd")
const InvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

var _failed := false

func _init() -> void:
	_check_acquire_release_owner()
	_check_double_acquire_refused()
	_check_release_all()
	_check_isolation()
	_check_invariant_helper()
	if _failed:
		quit(1)
		return
	print("test_reservation_table: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _check_acquire_release_owner() -> void:
	var table := TableType.new()
	_expect(table.owner("tile:1,1") == "", "unreserved key has no owner")
	_expect(not table.is_reserved("tile:1,1"), "unreserved key must not report reserved")
	_expect(table.acquire("tile:1,1", "job_1"), "first acquire must succeed")
	_expect(table.owner("tile:1,1") == "job_1", "owner lookup must report the acquiring job")
	_expect(table.is_reserved("tile:1,1"), "acquired key must report reserved")
	_expect(table.release("tile:1,1", "job_1"), "owner release must succeed")
	_expect(table.owner("tile:1,1") == "", "released key has no owner")
	_expect(not table.is_reserved("tile:1,1"), "released key must not be reserved")

func _check_double_acquire_refused() -> void:
	var table := TableType.new()
	_expect(table.acquire("tile:2,2", "job_1"), "first acquire must succeed")
	_expect(not table.acquire("tile:2,2", "job_2"), "a different job must be refused the same key")
	_expect(table.owner("tile:2,2") == "job_1", "a refused acquire must not change the owner")
	_expect(table.acquire("tile:2,2", "job_1"), "re-acquiring a key already owned by the same job must succeed")
	_expect(not table.release("tile:2,2", "job_2"), "a non-owner release must be refused")
	_expect(table.owner("tile:2,2") == "job_1", "a refused release must not change the owner")

func _check_release_all() -> void:
	var table := TableType.new()
	table.acquire("tile:1,1", "job_1")
	table.acquire("tile:2,2", "job_1")
	table.acquire("tile:3,3", "job_2")
	table.release_all("job_1")
	_expect(table.owner("tile:1,1") == "", "release_all must release every key owned by the job")
	_expect(table.owner("tile:2,2") == "", "release_all must release every key owned by the job")
	_expect(table.owner("tile:3,3") == "job_2", "release_all must not release another job's key")

func _check_isolation() -> void:
	var table := TableType.new()
	table.acquire("tile:1,1", "job_1")
	var snapshot := table.snapshot()
	snapshot["tile:1,1"] = "mutated"
	snapshot["tile:9,9"] = "job_x"
	_expect(table.owner("tile:1,1") == "job_1", "snapshot must be detached from internal state")
	_expect(not table.is_reserved("tile:9,9"), "mutating a snapshot must not leak into the table")

func _check_invariant_helper() -> void:
	var table := TableType.new()
	table.acquire("tile:1,1", "job_1")
	table.acquire("tile:2,2", "job_2")
	var jobs: Array[Dictionary] = [
		{"id": "job_1", "status": "active"},
		{"id": "job_2", "status": "active"},
	]
	var result := InvariantsType.check(table, jobs)
	_expect(result["orphaned_reservations"].is_empty(), "every reservation belongs to an active job")
	_expect(result["idle_with_available_work"].is_empty(), "no colonists supplied means no idle violations")

	table.acquire("tile:3,3", "job_3")
	var stale_result := InvariantsType.check(table, jobs)
	_expect(stale_result["orphaned_reservations"] == ["tile:3,3"], "a reservation with no active job must be reported")

	table.release("tile:3,3", "job_3")
	var content_registry := ContentRegistryType.new()
	var job_key := func(job: Dictionary) -> String: return String(job["key"])
	var idle_colonists: Array[Dictionary] = [
		{"id": "colonist_0", "kind": "colonist", "route": null, "work": null},
	]
	var busy_jobs: Array[Dictionary] = [
		{"id": "job_1", "status": "active"},
		{"id": "job_4", "status": "queued", "reason": "", "key": "tile:4,4"},
	]
	var idle_result := InvariantsType.check(table, busy_jobs, idle_colonists, job_key, Callable(), Callable(), content_registry)
	_expect(idle_result["idle_with_available_work"] == ["colonist_0"],
		"an idle colonist with an eligible reachable unreserved job must be reported")

	var busy_colonists: Array[Dictionary] = [
		{"id": "colonist_0", "kind": "colonist", "route": {"job_id": "job_1"}, "work": null},
	]
	var busy_result := InvariantsType.check(table, busy_jobs, busy_colonists, job_key, Callable(), Callable(), content_registry)
	_expect(busy_result["idle_with_available_work"].is_empty(), "a working colonist is not idle")

	# A queued job whose key is already reserved by another job must not count
	# as available work even though its own "reason" field is empty: the
	# table, not just "reason", decides "unreserved".
	table.acquire("tile:4,4", "job_5")
	var reserved_result := InvariantsType.check(table, busy_jobs, idle_colonists, job_key, Callable(), Callable(), content_registry)
	_expect(reserved_result["idle_with_available_work"].is_empty(),
		"a queued job whose key is already reserved must not count as available work")
	table.release("tile:4,4", "job_5")

	# An unreachable queued job (reported via is_reachable, for callers whose
	# job schema does not already fold reachability into "reason") must
	# likewise not count as available work.
	var is_reachable := func(job: Dictionary) -> bool: return String(job["id"]) != "job_4"
	var unreachable_result := InvariantsType.check(table, busy_jobs, idle_colonists, job_key, is_reachable, Callable(), content_registry)
	_expect(unreachable_result["idle_with_available_work"].is_empty(),
		"an unreachable queued job must not count as available work")
