extends "res://scripts/core/jobs/job_queue.gd"

## Narrow integration adapter: all transitions still execute in JobQueue.tick.
var _reachable_targets: Dictionary = {}

func _init(random_source: RandomNumberGenerator) -> void:
	super(random_source, _selected_reachable)

func _selected_reachable(target: Vector2i) -> bool:
	return _reachable_targets.get(target, false)

func advance_selection(selected: Array[String], reachable_targets: Dictionary) -> void:
	_reachable_targets = reachable_targets
	var all_jobs: Array[Dictionary] = _jobs
	var selected_jobs: Array[Dictionary] = []
	for job in all_jobs:
		if job["id"] in selected:
			selected_jobs.append(job)
	_jobs = selected_jobs
	super.tick()
	_jobs = all_jobs
	_reachable_targets = {}
