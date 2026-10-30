class_name OrderHandler
extends RefCounted

## Job order commands: work submissions, the terminal transitions, and area_order.
## Invariants:
## - A target-valid job command always calls through to the scheduler's own
##   submit(), so an unsupported priority still produces JobQueue's job_rejected
##   event (CommandChecks.check_job_submission() is preview()-only).
## - A rejected terminal command keeps its job_rejected + command_rejected event
##   pair: the terminal branch never consults CommandChecks.check_terminal_job_command().
## - Work progress is cleared only once the terminal transition succeeds, by the
##   terminating job's own identity (WorkProgress.clear_terminated_job()).

const SeededClockType = preload("res://scripts/core/seeded_clock.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")
const ConstructionSystemType = preload("res://scripts/core/objects/construction_system.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")

var _clock: SeededClockType
var _event_log: EventLogType
var _scheduler: AssignmentType
var _progress_table: WorkProgressType
var _construction: ConstructionSystemType
var _area_orders: AreaOrders
var _tile_grid: TileGridType
## (check: Callable, command: Dictionary) -> Dictionary: check.call(world, command).
var _check: Callable
## (job_id: String) -> void: drops a haul/site_fetch job's carried item.
var _drop_carried_haul_item: Callable
## (job_id: String, status: String) -> Dictionary: WorldState's terminal-transition boundary.
var _finish_job: Callable
## (job_id: String, kind: String) -> void: tells the owning giver its job ended.
var _resolve_giver_association: Callable
## () -> void: drains resumes GlobalAssignment refused.
var _resolve_refused_reservations: Callable

func _init(clock: SeededClockType, event_log: EventLogType, scheduler: AssignmentType,
		progress_table: WorkProgressType, construction: ConstructionSystemType, area_orders: AreaOrders,
		tile_grid: TileGridType, check: Callable, drop_carried_haul_item: Callable, finish_job: Callable,
		resolve_giver_association: Callable, resolve_refused_reservations: Callable) -> void:
	_clock = clock
	_event_log = event_log
	_scheduler = scheduler
	_progress_table = progress_table
	_construction = construction
	_area_orders = area_orders
	_tile_grid = tile_grid
	_check = check
	_drop_carried_haul_item = drop_carried_haul_item
	_finish_job = finish_job
	_resolve_giver_association = resolve_giver_association
	_resolve_refused_reservations = resolve_refused_reservations

func apply_job_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var result: Dictionary
	if command["type"] in ["dig", "chop", "forage", "till", "sow", "mine"]:
		var check: Dictionary = _check.call(CommandChecks.check_target_job_command, command)
		if not check.is_empty():
			return _event_log.rejection(command["command_id"], command["actor"], check["reason"], check["params"])
		var target := Vector2i(payload["x"], payload["y"])
		# assignee (F3), dig/chop/forage/mine only: submit()'s restrict_to, as need_giver.gd uses it.
		var assignee := String(payload.get("assignee", "")) if command["type"] in ["dig", "chop", "forage", "mine"] else ""
		result = _scheduler.submit(target, payload.get("priority", 1), _clock.tick, command["type"], assignee)
	else:
		if typeof(payload.get("job_id")) != TYPE_STRING or String(payload["job_id"]).is_empty():
			return _event_log.rejection(command["command_id"], command["actor"], "invalid_payload", {"detail": "missing_job_id"})
		# Cancelling/failing/invalidating a haul, site_fetch or craft_fetch job mid-carry drops the carried item (colonist-ai.md 3.3).
		if command["type"] in ["cancel_job", "fail_job", "invalidate_job"]:
			var target_job := _scheduler.queue.get_job(String(payload["job_id"]))
			if String(target_job.get("kind", "")) in ["haul", "site_fetch", "craft_fetch"]:
				_drop_carried_haul_item.call(String(payload["job_id"]))
		var terminal_job := _scheduler.queue.get_job(String(payload["job_id"]))
		var terminal_was_active: bool = String(terminal_job.get("status", "")) == "active"
		result = _finish_job.call(payload["job_id"], command["type"])
		if result["ok"] and command["type"] in ["complete_job", "cancel_job", "fail_job", "invalidate_job"]:
			_progress_table.clear_terminated_job(String(payload["job_id"]), terminal_job, terminal_was_active)
		# A command ending a rescue/need job must tell its giver too, or the giver keeps naming a dead job.
		if result["ok"]:
			_resolve_giver_association.call(String(payload["job_id"]), String(terminal_job.get("kind", "")))
	# F3: a cancel/fail/invalidate_job can resolve a need and get a resume
	# refused outside tick(); drain it now. Harmless otherwise.
	_resolve_refused_reservations.call()
	_event_log.collect_queue_events()
	if not result["ok"]:
		return _event_log.rejection(command["command_id"], command["actor"], result["rejection"]["reason"], {"remedy": result["rejection"]["remedy"]})
	var applied := _event_log.applied(command)
	applied["job_id"] = result["job_id"]
	return applied

## A site id doubles as job_id (ADR 040): cancel_job on one tears the site down like cancel_site.
func apply_cancel_job_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command.get("payload", {})
	var site_id := String(payload.get("job_id", ""))
	if not site_id.is_empty() and _construction.site_table.has(site_id):
		_construction.cancel_construction_site(site_id)
		_event_log.collect_queue_events()
		var applied := _event_log.applied(command)
		applied["site_id"] = site_id
		applied["job_id"] = site_id
		return applied
	return apply_job_command(command)

## Queues the order; AreaOrders expands it into per-tile commands a budget per tick (ADR 044).
func apply_area_order_command(command: Dictionary) -> Dictionary:
	return _area_orders.apply_command(command, _tile_grid.width, _tile_grid.height)
