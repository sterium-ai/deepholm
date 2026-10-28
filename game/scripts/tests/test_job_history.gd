extends SceneTree

## A5 (ADR 053): JobQueue keeps only live jobs in its list and index; a terminal
## job moves to a bounded history (job_history.gd) that the copying getters still
## show, until it is evicted. Core readers get read-only views.

const QueueType = preload("res://scripts/core/jobs/job_queue.gd")
const JobHistoryType = preload("res://scripts/core/jobs/job_history.gd")
var _failed := false

func _init() -> void:
	_check_retired_job_leaves_live_list_but_stays_queryable()
	_check_history_is_bounded()
	_check_getters_list_submission_order()
	_check_live_list_is_compacted()
	_check_views_are_live_records()
	_check_restore_retires_terminal_jobs()
	_check_mass_cancel_keeps_indexes_consistent()
	if _failed:
		quit(1)
		return
	print("test_job_history: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _new_queue() -> JobQueue:
	var rng := RandomNumberGenerator.new()
	rng.seed = 51
	return QueueType.new(rng, func(_target: Vector2i) -> bool: return true)

func _submit(queue: JobQueue, x: int, kind: String = "dig") -> String:
	var result := queue.submit_dig(Vector2i(x, 0), QueueType.Priority.NORMAL, kind)
	_expect(result["ok"], "expected a valid submission")
	return String(result.get("job_id", ""))

func _ids(jobs: Array[Dictionary]) -> Array[String]:
	var ids: Array[String] = []
	for job in jobs:
		ids.append(String(job["id"]))
	return ids

func _check_retired_job_leaves_live_list_but_stays_queryable() -> void:
	var queue := _new_queue()
	var done := _submit(queue, 1)
	var open := _submit(queue, 2)
	queue.tick()
	_expect(queue.complete(done)["ok"], "completing an active job must succeed")
	_expect(_ids(queue.get_jobs(false)) == [open], "the live list must drop the completed job: %s" % [_ids(queue.get_jobs(false))])
	_expect(_ids(queue.get_jobs()) == [done, open], "get_jobs() must still list the retained job: %s" % [_ids(queue.get_jobs())])
	_expect(queue.get_job(done)["status"] == "completed", "get_job() must read a retained job")
	_expect(not queue.get_job_kinds().has(done), "the kind index must hold live jobs only")
	_expect(not queue.get_reservations().values().has(done), "a retired job must hold no reservation")
	_expect(queue.check_terminal(done)["reason"] == "job_already_terminal", "a retained job must still read as terminal")
	var again := queue.cancel(done)
	_expect(not again["ok"] and again["rejection"]["reason"] == "job_already_terminal",
		"cancelling a retained job must be rejected as already terminal: %s" % again)

func _check_history_is_bounded() -> void:
	var queue := _new_queue()
	var first := _submit(queue, 0)
	queue.cancel(first)
	for i in JobHistoryType.LIMIT + 9:
		queue.cancel(_submit(queue, i + 1))
	var open := _submit(queue, 999)
	var jobs := queue.get_jobs()
	_expect(jobs.size() == JobHistoryType.LIMIT + 1, "history must keep exactly LIMIT retired jobs, got %d" % (jobs.size() - 1))
	_expect(queue.get_job(first).is_empty(), "the oldest retired job must be evicted")
	_expect(queue.check_terminal(first)["reason"] == "unknown_job", "an evicted job must read as unknown")
	_expect(String(jobs[-1]["id"]) == open, "the live job must come last, in submission order")

func _check_getters_list_submission_order() -> void:
	var queue := _new_queue()
	var ids: Array[String] = []
	for i in 8:
		ids.append(_submit(queue, i, "dig" if i % 2 == 0 else "chop"))
	queue.tick()
	# Retire out of submission order, completing and cancelling.
	queue.complete(ids[5])
	queue.cancel(ids[1])
	queue.fail(ids[6])
	_expect(_ids(queue.get_jobs()) == ids, "get_jobs() must merge live and retired jobs in submission order: %s" % [_ids(queue.get_jobs())])
	_expect(_ids(queue.get_jobs_of_kinds(["chop"])) == [ids[1], ids[3], ids[5], ids[7]],
		"get_jobs_of_kinds() must merge the retained jobs of those kinds in order: %s" % [_ids(queue.get_jobs_of_kinds(["chop"]))])
	_expect(_ids(queue.get_jobs_of_kinds(["chop"], false)) == [ids[3], ids[7]],
		"get_jobs_of_kinds(kinds, false) must list the live jobs of those kinds only: %s" % [_ids(queue.get_jobs_of_kinds(["chop"], false))])
	_expect(_ids(queue.view_jobs_of_kinds(["chop", "dig"])) == [ids[0], ids[2], ids[3], ids[4], ids[7]],
		"view_jobs_of_kinds() must list live jobs only, in order: %s" % [_ids(queue.view_jobs_of_kinds(["chop", "dig"]))])

func _check_live_list_is_compacted() -> void:
	var queue := _new_queue()
	var ids: Array[String] = []
	for i in 400:
		ids.append(_submit(queue, i))
	for i in 390:
		queue.cancel(ids[i])
	_expect(TestAccess.queue_live_jobs(queue).size() <= 2 * 10 + 1, "retired jobs must not pile up in the live list: %d entries for 10 live" % TestAccess.queue_live_jobs(queue).size())
	_expect(_ids(queue.get_jobs(false)) == ids.slice(390), "the live list must keep the 10 open jobs in order")

func _check_views_are_live_records() -> void:
	var queue := _new_queue()
	var job_id := _submit(queue, 3)
	var view := queue.view_job(job_id)
	queue.tick()
	_expect(view["status"] == "active", "view_job() must be the live record, updated in place")
	var copy := queue.get_job(job_id)
	copy["status"] = "tampered"
	_expect(queue.view_job(job_id)["status"] == "active", "get_job() must still return a detached copy")
	queue.complete(job_id)
	_expect(is_same(queue.view_job(job_id), view), "view_job() must read the retained record once the job is terminal")
	_expect(queue.view_jobs_of_kinds(["dig"]).is_empty(), "a retired job must leave the kind view")

func _check_restore_retires_terminal_jobs() -> void:
	var queue := _new_queue()
	var ids: Array[String] = []
	for i in 4:
		ids.append(_submit(queue, i))
	queue.tick()
	queue.complete(ids[1])
	queue.cancel(ids[2])
	var restored := _new_queue()
	restored.restore(queue.get_jobs(), queue.get_tick(), queue.get_next_id(), queue.get_sequence())
	_expect(_ids(restored.get_jobs(false)) == [ids[0], ids[3]], "restore() must keep only live jobs live")
	_expect(_ids(restored.get_jobs()) == ids, "restore() must retain the terminal jobs it was given, in order")
	_expect(restored.get_reservations() == queue.get_reservations(), "restore() must rebuild the same reservations")
	var next := _submit(restored, 9)
	_expect(_ids(restored.get_jobs()) == ids + [next], "a job submitted after restore() must come last")

## An area cancel retires thousands of jobs in one call (B1's case): each stays O(1)
## amortized and the indexes stay consistent with a scan of the live jobs.
func _check_mass_cancel_keeps_indexes_consistent() -> void:
	var queue := _new_queue()
	var ids: Array[String] = []
	for i in 5000:
		ids.append(_submit(queue, i, "dig" if i % 3 else "chop"))
	queue.tick()
	for i in range(0, 5000, 7):
		queue.complete(ids[i])
	for i in 5000:
		if i % 7 != 0 and i % 5 != 0:
			queue.cancel(ids[i])
	var expected: Array[String] = []
	for i in 5000:
		if i % 7 != 0 and i % 5 == 0:
			expected.append(ids[i])
	_expect(_ids(queue.get_jobs(false)) == expected, "the live list must be exactly the surviving jobs")
	var chops: Array[String] = []
	for job_id in expected:
		if queue.view_job(job_id)["kind"] == "chop":
			chops.append(job_id)
	_expect(_ids(queue.view_jobs_of_kinds(["chop"])) == chops, "the kind view must match the live jobs after compaction")
	_expect(queue.get_job_kinds().size() == expected.size(), "the kind index must hold exactly the live jobs")
	_expect(queue.get_jobs().size() == expected.size() + JobHistoryType.LIMIT, "history must stay at its bound")
