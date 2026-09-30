class_name JobQueue
extends RefCounted

## Standalone deterministic dig queue. See README.md for the integration contract.
const ReservationTableType = preload("res://scripts/core/jobs/reservation_table.gd")
const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")

enum Priority { LOW, NORMAL, HIGH }

const BLOCKED_TARGET_RESERVED := "blocked_target_reserved"
const BLOCKED_TARGET_UNREACHABLE := "blocked_target_unreachable"
const BLOCKED_REACHABILITY_UNAVAILABLE := "blocked_reachability_unavailable"
const BLOCKED_ITEM_RESERVED := "blocked_item_reserved"
const BLOCKED_DESTINATION_FULL := "blocked_destination_full"
const BLOCKED_LABOUR_DISABLED := "labour_disabled"
const BLOCKED_NO_TOOL := "blocked_no_tool"
const SYSTEM_PRIORITY := 50
const TARGET_KEY_PREFIX := "tile:"
const ITEM_KEY_PREFIX := "item:"
const HAUL_KIND := "haul"
## Construction site activation (ADR 040, superseding
## ADR 028/038's single-worker `build` job): a site_fetch job reserves only
## its source item -- the site's own footprint tiles are reserved directly by
## WorldState the instant the `build` command is accepted (owner "site:<id>",
## never a job id), so activation must never also try to acquire them (they
## are never unowned). A site_work job reserves nothing at all: the number of
## concurrent builders is capped by the site record's own builder_ids/
## max_builders, not by the ReservationTable. See _tick_site_fetch()/
## _tick_site_work() below.
const SITE_FETCH_KIND := "site_fetch"
const SITE_WORK_KIND := "site_work"

var _random: RandomNumberGenerator
var _can_reach: Callable
var _tick: int = 0
var _next_id: int = 1
var _sequence: int = 0
var _jobs: Array[Dictionary] = []
var _table: ReservationTableType = ReservationTableType.new()
var _events: Array[Dictionary] = []
## haul-only: item_id -> a free destination cell, or null when none is free
## (colonist-ai.md 3.4's free-cell lookup). Injected post-construction
## (set_haul_destination_finder()) since AssignmentQueue's constructor
## signature is fixed; WorldState is the only real caller.
var _find_haul_destination: Callable = Callable()
## job_id -> {"reason","remedy"}, consulted once by fail()/invalidate() so a
## caller (WorldState) can report a specific typed reason for a haul
## termination through the same terminal path GlobalAssignment.finish()
## already drives. Always empty except transiently within one WorldState
## call; never persisted (see restore()).
var _pending_fail_reasons: Dictionary = {}
## Backoff for a haul job whose destination search keeps failing
## (colonist-ai.md 3.3): retried after this many ticks, doubling on each
## further failure up to the cap. Injected via set_haul_backoff() (mirroring
## how MOVE_TICKS_PER_TILE/WORK_TICKS are injected into ToilExecutor) since
## AssignmentQueue's constructor signature is fixed and has no room for them;
## the defaults below only matter for a JobQueue built directly by a test that
## never calls the setter. A backed-off job keeps its `_waiting` aging
## position untouched (see global_assignment.gd's submit()/finish()): this
## only gates how often _tick_haul() re-attempts the destination search,
## never the job's place in the fair queue.
var _haul_retry_base_ticks: int = 10
var _haul_retry_cap_ticks: int = 40
## tool_requirement_of(job_kind) -> {} or {"kind","retry_base_ticks",
## "retry_cap_ticks"}; tool_available(job_id, tool_kind) -> bool. Injected
## post-construction like set_haul_backoff(). Gating logic lives in
## ToolMatching.gate_check()/gate_force_backoff() (ADR 013).
var _tool_requirement_of: Callable = Callable()
var _tool_available: Callable = Callable()
## job_id -> Array[String] of extra ReservationTable keys a job needs
## alongside its own ordinary target key, injected like set_haul_backoff().
## A rescue job's own
## "trapped:<victim_id>" key must move in lockstep with the target key --
## acquired only while the job is actually active, released for free by
## release_all() on any terminal transition (already generic), and
## re-acquired here on reactivate() -- never held while merely queued, the
## same "reservations exist only while in progress" invariant suspend()'s own
## doc comment already states. Generic across every job kind: a caller with
## no extra keys for job_id returns an empty array (the default Callable()
## below, unset, is treated as "no extra keys for anyone").
var _extra_keys_for_job: Callable = Callable()

## The caller owns/seeds the generator; this queue does not consume random draws.
## can_reach(target: Vector2i) -> bool must be deterministic and non-mutating.
func _init(random_source: RandomNumberGenerator, can_reach: Callable) -> void:
	_random = random_source
	_can_reach = can_reach

func set_haul_backoff(base_ticks: int, cap_ticks: int) -> void:
	_haul_retry_base_ticks = base_ticks
	_haul_retry_cap_ticks = cap_ticks

func set_tool_requirement(tool_requirement_of: Callable, tool_available: Callable) -> void:
	_tool_requirement_of = tool_requirement_of
	_tool_available = tool_available

## See _extra_keys_for_job's own doc comment above.
func set_extra_reservation_keys(extra_keys_for_job: Callable) -> void:
	_extra_keys_for_job = extra_keys_for_job

## job_id's own extra keys (see _extra_keys_for_job above), or an empty array
## when no callable is wired or it names none for job_id.
func _extra_keys(job_id: String) -> Array[String]:
	if not _extra_keys_for_job.is_valid():
		return []
	return _extra_keys_for_job.call(job_id) as Array[String]

## "" when every key in keys is either unowned or already owned by job_id;
## otherwise the id of the other job blocking activation on the first
## conflicting key.
func _extra_keys_conflict(keys: Array[String], job_id: String) -> String:
	for key in keys:
		var owner: String = _table.owner(key)
		if not owner.is_empty() and owner != job_id:
			return owner
	return ""

## Pure pre-mutation predicate for submit_dig()'s own target/priority validation,
## shared with CommandChecks.check()'s preview path for dig/chop/forage/till/sow
## (game/scripts/core/commands/command_checks.gd) so a preview can predict this exact
## rejection without calling submit_dig() itself -- which would emit a real job_rejected event
## and advance the sequence counter, side effects preview() must never cause. Returns {} when
## target/priority may be submitted, or the rejection submit_dig() would produce otherwise
## (job_id/tick omitted: preview() has no tick to report and never sees a job_id here). Never
## mutates.
static func check_submission(target: Vector2i, priority: int) -> Dictionary:
	if priority not in [Priority.LOW, Priority.NORMAL, Priority.HIGH]:
		return {"reason": "invalid_priority", "remedy": "choose_supported_priority"}
	if target.x < 0 or target.y < 0:
		return {"reason": "invalid_target", "remedy": "choose_valid_target"}
	return {}

func submit_dig(target: Vector2i, priority: int = Priority.NORMAL, kind: String = "dig") -> Dictionary:
	var submission_check := check_submission(target, priority)
	if not submission_check.is_empty():
		return _reject("", submission_check["reason"], submission_check["remedy"])
	var job_id := "job_%d" % _next_id
	_next_id += 1
	var job := {
		"id": job_id, "kind": kind, "status": "queued",
		"priority": priority, "target": target,
		"reason": "", "remedy": "", "blocking_job_id": "",
		# haul-only fields (colonist-ai.md 3.3/3.4); always present with
		# harmless defaults so dig/chop jobs carry the same shape unchanged.
		"item_id": "", "cell": null, "backoff_ticks": 0, "retry_at": 0,
		# site_fetch/site_work-only field: the construction
		# site's own origin tile -- see attach_site() below. A site_fetch
		# job's "target" still names the reserved source item's own tile
		# (leg one, mirroring haul's "target"/"cell" split); a site_work
		# job's "target" is the site's origin tile directly (its only leg).
		"site": null,
	}
	_jobs.append(job)
	_emit("job_queued", job_id, {})
	return {"ok": true, "job_id": job_id}

## Injected post-submission (WorldState.submit() has no item_id parameter,
## see global_assignment.gd's fixed signature): attaches the ground item a
## queued haul job will reserve/carry. A no-op false for an unknown or
## already-active/terminal job, so a stale caller can never mutate a job
## whose activation has already captured its item_id.
func attach_item(job_id: String, item_id: String) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return false
	job["item_id"] = item_id
	return true

## Injected post-submission like attach_item() (ConstructionGiver's own
## submit-and-attach wrappers, world_state.gd, call this right after
## submitting a fresh site_fetch/site_work job): records the construction
## site's own origin tile, read by _tick_site_fetch()/_tick_site_work() below.
## Neither kind acquires a "tile:" reservation of its own for this field --
## the site itself already reserved every footprint tile the instant its
## `build` command was accepted (owner "site:<id>", not a job id) -- so this
## is bookkeeping only, never gates activation the way attach_build() once did.
## Same no-op-false guard as attach_item().
func attach_site(job_id: String, site: Vector2i) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return false
	job["site"] = site
	return true

## Hands-filling rules: retargets an active site_fetch
## job's own "current source" -- item_id and target move together, exactly
## like attach_item()/attach_site() set them once at submission, but gated on
## "active" instead of "queued" since this fires mid-execution, once
## WorldState's own on-demand planner (world_state.gd, the only caller -- see
## _toil_on_pick_up_success()/_resolve_freshly_activated_site_fetch_sources())
## has already reserved item_id's own "item:" key directly on
## get_reservation_table() before calling this. No new job field: the
## previous source's own reservation is simply left owned by job_id (its
## ground item is already fully or partially consumed by the time this runs)
## until release_all() sweeps it at any terminal transition, exactly like a
## single-source site_fetch job's one reservation always has. A no-op false
## for an unknown, non-active or non-site_fetch job.
func retarget_site_fetch_source(job_id: String, item_id: String, target: Vector2i) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active" or String(job["kind"]) != SITE_FETCH_KIND:
		return false
	job["item_id"] = item_id
	job["target"] = target
	return true

## Hands-filling rules: stamps "cell" -- otherwise a haul-only field, null
## for site_fetch until this call -- with the job's own site, WorldState.
## _toil_is_first_leg()'s signal that this job has decided to stop fetching
## and deliver whatever hands currently hold (job["item_id"]/["target"] keep
## naming the last source visited either way, unconditionally reserved and
## reacquired on suspend/reactivate exactly like a single-source site_fetch
## job always was -- _reactivate_site_fetch()/restore() need no change for
## this). A no-op false for an unknown, non-active or non-site_fetch job.
func mark_site_fetch_delivering(job_id: String) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active" or String(job["kind"]) != SITE_FETCH_KIND:
		return false
	job["cell"] = job["site"]
	return true

## Chains an already-delivering site_fetch job onto a further sibling
## construction site: a colonist whose hands still hold units of
## the job's own kind after a successful `deposit` may continue to a second,
## third or fourth site instead of completing. Stamps "site" (job_id's own
## current-delivery-target record, read by _toil_site_id_for()/
## ConstructionGiver's own committed-site bookkeeping) and "cell" (site_fetch's
## own "delivering" flag/_toil_go_to_target() destination, first set equal to
## "site" by mark_site_fetch_delivering()) with the new site's origin together,
## keeping them in lockstep exactly like mark_site_fetch_delivering() first
## set them. item_id/target are left untouched: they still name the last
## source visited, exactly as they do for a job delivering to its very first
## site -- no new persisted field, "site" simply names whichever site the job
## is currently delivering to, round-tripping through save/load unchanged. A
## no-op false for an unknown, non-active, non-site_fetch, or not-yet-
## delivering (cell == null) job: chaining is only ever a delivering-leg
## transition, never a fetching one.
func retarget_site_fetch_site(job_id: String, site: Vector2i) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active" or String(job["kind"]) != SITE_FETCH_KIND:
		return false
	if job["cell"] == null:
		return false
	job["site"] = site
	job["cell"] = site
	return true

## item_id -> Vector2i free cell, or null when none free (colonist-ai.md 3.4).
func set_haul_destination_finder(finder: Callable) -> void:
	_find_haul_destination = finder

## Marker lives in blocking_job_id, not item_id (a haul job already uses item_id for its own
## carried-item id). See docs/decisions/013-tool-toils.md, "Drop-leg identity marker".
func set_active_item_marker(job_id: String, item_id: String) -> void:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active":
		return
	job["blocking_job_id"] = item_id

## Reads the live record, not a caller-held duplicate, so a same-tick write is visible immediately.
func get_active_item_marker(job_id: String) -> String:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "active":
		return ""
	return String(job["blocking_job_id"])

## Consulted once by the next fail()/invalidate() call for job_id (see
## _pending_fail_reasons). Lets WorldState report a specific typed reason
## (e.g. "blocked_destination_gone") through GlobalAssignment.finish()'s
## existing cleanup path instead of a new termination API.
func set_pending_fail_reason(job_id: String, reason: String, remedy: String) -> void:
	_pending_fail_reasons[job_id] = {"reason": reason, "remedy": remedy}

## Non-terminal block reason for a queued job whose labour is off for every
## colonist that could ever do it (colonist-ai.md 3.2): driven entirely by
## GlobalAssignment's own per-tick scan (this queue has no colonist/labour-
## table knowledge of its own), mirroring the existing _block()/job_unblocked
## pattern BLOCKED_TARGET_RESERVED/BLOCKED_DESTINATION_FULL already use,
## rather than repurposing set_pending_fail_reason() (that path is only
## consulted by fail()/invalidate(), a terminal transition -- this reason
## must leave the job queued). A no-op for an unknown job or one that is not
## currently queued (an active/terminal job is untouched).
##
## Called once per tick for every waiting entry, before this job could ever be
## selected/advanced again this same tick (GlobalAssignment.tick() now checks
## labour eligibility before its own reservation-recheck branch, so a
## disabled job is never added to `selected` and this queue's own tick()
## never touches its reason while disabled). Freely overwrites a haul job's
## BLOCKED_DESTINATION_FULL reason -- unlike the displayed reason, the
## backoff itself (`retry_at`) is tracked independently (see _tick_haul()'s
## and get_reservations()'s own gates below) and is never reset by this call,
## so a labour toggle can never shorten an in-progress retry delay even
## though it now shows labour_disabled immediately.
func set_labour_disabled(job_id: String, disabled: bool) -> void:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return
	if disabled:
		_block(job, BLOCKED_LABOUR_DISABLED, "enable_labour_for_a_colonist")
	elif job["reason"] == BLOCKED_LABOUR_DISABLED:
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
		_set_reason(job, "", "")

## One explicit tick evaluates every queued job, highest priority first, FIFO
## within a priority. Blocked jobs remain queued and are retried on every tick.
func tick() -> void:
	_tick += 1
	for priority in [Priority.HIGH, Priority.NORMAL, Priority.LOW]:
		for job in _jobs:
			if job["status"] != "queued" or job["priority"] != priority:
				continue
			if String(job["kind"]) == HAUL_KIND:
				_tick_haul(job)
				continue
			if String(job["kind"]) == SITE_FETCH_KIND:
				_tick_site_fetch(job)
				continue
			if String(job["kind"]) == SITE_WORK_KIND:
				_tick_site_work(job)
				continue
			if ToolMatchingType.gate_backed_off(job, _tick, _tool_requirement_of): continue
			var target: Vector2i = job["target"]
			var owner: String = _table.owner(_target_key(target))
			if not owner.is_empty() and owner != job["id"]:
				_block(job, BLOCKED_TARGET_RESERVED, "wait_for_target_release", owner)
				continue
			if not _can_reach.is_valid():
				_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
				continue
			var reachable: Variant = _can_reach.call(target)
			if not reachable is bool:
				_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
				continue
			if not reachable:
				_block(job, BLOCKED_TARGET_UNREACHABLE, "restore_target_access")
				continue
			if not _tool_requirement_satisfied(job):
				continue
			var extra_keys := _extra_keys(job["id"])
			var extra_blocked_by := _extra_keys_conflict(extra_keys, job["id"])
			if not extra_blocked_by.is_empty():
				_block(job, BLOCKED_TARGET_RESERVED, "wait_for_target_release", extra_blocked_by)
				continue
			if not String(job["reason"]).is_empty():
				_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
			_set_reason(job, "", "")
			_table.acquire(_target_key(target), job["id"])
			for key in extra_keys:
				_table.acquire(key, job["id"])
			job["status"] = "active"
			_emit("reservation_acquired", job["id"], {"target": target})
			_emit("job_active", job["id"], {})

## Haul activation (colonist-ai.md 3.3/3.4): reserves the item and one
## free destination cell together, before any travel begins, using "item:"/
## "cell:" ReservationTable keys distinct from dig/chop's own "tile:" key
## (job["target"] stays the item's tile purely for the scheduler's routing/
## get_reservations() bookkeeping, unrelated to these two keys). A missing
## free cell blocks with BLOCKED_DESTINATION_FULL under an explicit backoff
## (HAUL_RETRY_BASE_TICKS, doubling to HAUL_RETRY_CAP_TICKS) rather than
## retrying every tick like dig/chop's reservation/reachability blocks.
func _tick_haul(job: Dictionary) -> void:
	# Backed off: return before touching reachability/item ownership, whatever
	# reason is currently displayed (may read labour_disabled -- see
	# set_labour_disabled() -- while this backoff still applies).
	# get_reservations() reports this job's target "reserved" for as long as
	# this holds, keeping global_assignment.gd refreshing it as a cheap no-op
	# without a real route search/scoring competition; calling _can_reach()
	# here regardless would misreport a reachable item as
	# blocked_target_unreachable since no search ran, pulling the job back
	# into scoring -- the exact starvation this reason exists to prevent.
	if _tick < int(job["retry_at"]):
		return
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var owner: String = _table.owner(item_key)
	if not owner.is_empty() and owner != job["id"]:
		_block(job, BLOCKED_ITEM_RESERVED, "wait_for_item_release", owner)
		return
	if not _can_reach.is_valid():
		_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
		return
	var reachable: Variant = _can_reach.call(job["target"])
	if not reachable is bool:
		_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
		return
	if not reachable:
		_block(job, BLOCKED_TARGET_UNREACHABLE, "restore_target_access")
		return
	var cell = _find_haul_destination.call(String(job["item_id"])) if _find_haul_destination.is_valid() else null
	_emit("haul_destination_attempt", job["id"], {"attempt_tick": _tick})
	if cell == null:
		var backoff: int = int(job["backoff_ticks"])
		backoff = _haul_retry_base_ticks if backoff == 0 else mini(backoff * 2, _haul_retry_cap_ticks)
		job["backoff_ticks"] = backoff
		job["retry_at"] = _tick + backoff
		_block(job, BLOCKED_DESTINATION_FULL, "wait_for_free_destination")
		return
	if not _table.acquire(item_key, job["id"]):
		_block(job, BLOCKED_ITEM_RESERVED, "wait_for_item_release", _table.owner(item_key))
		return
	var cell_key := _cell_key(cell)
	if not _table.acquire(cell_key, job["id"]):
		_table.release(item_key, job["id"])
		_block(job, BLOCKED_DESTINATION_FULL, "wait_for_free_destination")
		return
	if not String(job["reason"]).is_empty():
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
	_set_reason(job, "", "")
	job["cell"] = cell
	job["backoff_ticks"] = 0
	job["retry_at"] = 0
	job["status"] = "active"
	_emit("reservation_acquired", job["id"], {"target": job["item_id"], "key": item_key})
	_emit("reservation_acquired", job["id"], {"target": cell, "key": cell_key})
	_emit("job_active", job["id"], {})

## site_fetch activation: reserves only the source item, before
## any travel begins -- the same "acquire only on activation" shape
## _tick_haul() uses, but with no destination-cell search and no site-tile
## reservation of its own: the site's every footprint tile is already
## reserved directly by WorldState (owner "site:<id>") the instant its
## `build` command was accepted, so a fetch job must never also try to
## acquire it (it is never unowned, and would therefore block forever).
func _tick_site_fetch(job: Dictionary) -> void:
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var item_owner: String = _table.owner(item_key)
	if not item_owner.is_empty() and item_owner != job["id"]:
		_block(job, BLOCKED_ITEM_RESERVED, "wait_for_item_release", item_owner)
		return
	if not _can_reach.is_valid():
		_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
		return
	var reachable: Variant = _can_reach.call(job["target"])
	if not reachable is bool:
		_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
		return
	if not reachable:
		_block(job, BLOCKED_TARGET_UNREACHABLE, "restore_target_access")
		return
	if not String(job["reason"]).is_empty():
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
	_set_reason(job, "", "")
	_table.acquire(item_key, job["id"])
	job["status"] = "active"
	_emit("reservation_acquired", job["id"], {"target": job["item_id"], "key": item_key})
	_emit("job_active", job["id"], {})

## site_work activation: holds no reservation at all -- the
## number of concurrent builders on a site is capped by the site record's own
## builder_ids/max_builders (ConstructionSiteTable), not by this table, and
## the site's own footprint tiles are already reserved to the site itself.
## Activation is therefore just a reachability gate; ConstructionGiver never
## submits more than max_builders of these per site, and the mechanism
## places no lower gate here.
func _tick_site_work(job: Dictionary) -> void:
	if not _can_reach.is_valid():
		_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
		return
	var reachable: Variant = _can_reach.call(job["target"])
	if not reachable is bool:
		_block(job, BLOCKED_REACHABILITY_UNAVAILABLE, "provide_reachability_check")
		return
	if not reachable:
		_block(job, BLOCKED_TARGET_UNREACHABLE, "restore_target_access")
		return
	if not String(job["reason"]).is_empty():
		_emit("job_unblocked", job["id"], {"previous_reason": job["reason"]})
	_set_reason(job, "", "")
	job["status"] = "active"
	_emit("job_active", job["id"], {})

## Gates activation on a matching free tool existing anywhere (colonist-ai.md
## 2/3.3, ADR 013). Backoff/blocking logic lives in
## ToolMatching.gate_check(), extracted to stay under this file's line budget.
func _tool_requirement_satisfied(job: Dictionary) -> bool:
	return ToolMatchingType.gate_check(job, _tick, _tool_requirement_of, _tool_available, _block_no_tool)

## Applies job_id's own needs_tool backoff once fetch_tool proves no reachable
## candidate remains (WorldState._toil_on_no_tool_found()). No-op otherwise.
func block_no_tool(job_id: String) -> void:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return
	ToolMatchingType.gate_force_backoff(job, _tick, _tool_requirement_of, _block_no_tool)

func _block_no_tool(job: Dictionary, remedy: String) -> void:
	_block(job, BLOCKED_NO_TOOL, remedy)

## Critical-need interrupt support (colonist-ai.md 3.6/ADR 009): releases
## job_id's own reservation and returns it to "queued" without touching its
## target/kind/priority, so it re-enters JobQueue's ordinary queued lifecycle
## exactly as if freshly blocked -- a different job may claim the same target
## while the colonist working it is away, instead of the target staying
## reserved to a job nobody is currently advancing (colonist-ai.md 3.4:
## reservations exist only while their job is actually in progress). Not a
## terminal transition (see _finish()): job_id remains eligible for suspend()/
## reactivate()/complete()/fail() exactly like any other queued job. A no-op
## rejection for a job that is not currently active.
func suspend(job_id: String) -> Dictionary:
	var job := _find_job(job_id)
	if job.is_empty():
		return _reject(job_id, "unknown_job", "choose_existing_job")
	if job["status"] != "active":
		return _reject(job_id, "job_not_active", "wait_for_activation")
	var target: Vector2i = job["target"]
	for key in _table.release_all(job_id):
		_emit("reservation_released", job_id, {"target": target, "key": key, "reason": "need_interrupt"})
	job["status"] = "queued"
	_set_reason(job, "", "")
	return {"ok": true, "job_id": job_id}

## Reverses suspend(): re-derives job_id's activation directly by ownership
## alone -- reachability was already proven when the job first activated, and
## re-running a full route search is outside JobQueue's own remit -- used only
## to resume a job suspend() paused once the colonist doing it is free again.
## Returns true and re-acquires the same reservation(s) when nothing else has
## claimed them meanwhile; otherwise leaves the job queued (still eligible for
## the ordinary fair-queue path -- colonist-ai.md 3.6's "the colonist is
## reassigned" -- rather than forcing a double reservation) and returns false.
## A haul job holds two reservations at once (its item and its destination
## cell, both acquired together at activation -- see _tick_haul()), so it
## re-acquires both or neither, mirroring restore()'s own haul-aware
## reservation rebuild for the same reason.
func reactivate(job_id: String) -> bool:
	var job := _find_job(job_id)
	if job.is_empty() or job["status"] != "queued":
		return false
	if String(job["kind"]) == HAUL_KIND:
		return _reactivate_haul(job)
	if String(job["kind"]) == SITE_FETCH_KIND:
		return _reactivate_site_fetch(job)
	if String(job["kind"]) == SITE_WORK_KIND:
		job["status"] = "active"
		_set_reason(job, "", "")
		_emit("job_active", job_id, {})
		return true
	var target: Vector2i = job["target"]
	var owner: String = _table.owner(_target_key(target))
	if not owner.is_empty() and owner != job_id:
		return false
	var extra_keys := _extra_keys(job_id)
	if not _extra_keys_conflict(extra_keys, job_id).is_empty():
		return false
	_table.acquire(_target_key(target), job_id)
	for key in extra_keys:
		_table.acquire(key, job_id)
	job["status"] = "active"
	_set_reason(job, "", "")
	_emit("reservation_acquired", job_id, {"target": target})
	_emit("job_active", job_id, {})
	return true

func _reactivate_haul(job: Dictionary) -> bool:
	var job_id: String = job["id"]
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var item_owner: String = _table.owner(item_key)
	if not item_owner.is_empty() and item_owner != job_id:
		return false
	var cell_key := _cell_key(job["cell"])
	var cell_owner: String = _table.owner(cell_key)
	if not cell_owner.is_empty() and cell_owner != job_id:
		return false
	_table.acquire(item_key, job_id)
	_table.acquire(cell_key, job_id)
	job["status"] = "active"
	_set_reason(job, "", "")
	_emit("reservation_acquired", job_id, {"target": job["item_id"], "key": item_key})
	_emit("reservation_acquired", job_id, {"target": job["cell"], "key": cell_key})
	_emit("job_active", job_id, {})
	return true

## Mirrors _reactivate_haul()'s item-only half for a site_fetch job: only
## the source item is ever a job-owned reservation for this kind
## (see _tick_site_fetch()); the site's own footprint stays reserved to the
## site the entire time, suspended or not, so there is no second key to
## reacquire here.
func _reactivate_site_fetch(job: Dictionary) -> bool:
	var job_id: String = job["id"]
	var item_key := ITEM_KEY_PREFIX + String(job["item_id"])
	var item_owner: String = _table.owner(item_key)
	if not item_owner.is_empty() and item_owner != job_id:
		return false
	_table.acquire(item_key, job_id)
	job["status"] = "active"
	_set_reason(job, "", "")
	_emit("reservation_acquired", job_id, {"target": job["item_id"], "key": item_key})
	_emit("job_active", job_id, {})
	return true

func cancel(job_id: String) -> Dictionary:
	return _finish(job_id, "cancelled", "cancelled_by_command", "resubmit_order")

func fail(job_id: String) -> Dictionary:
	var override := _take_pending_fail_reason(job_id)
	if not override.is_empty():
		return _finish(job_id, "failed", override["reason"], override["remedy"])
	return _finish(job_id, "failed", "job_execution_failed", "inspect_target_and_resubmit")

## The owning simulation calls this when the target/order ceases to be valid.
## Invalidation is terminal failure, not a sixth persisted status.
func invalidate(job_id: String) -> Dictionary:
	var override := _take_pending_fail_reason(job_id)
	if not override.is_empty():
		return _finish(job_id, "failed", override["reason"], override["remedy"])
	return _finish(job_id, "failed", "target_invalidated", "choose_valid_target")

func _take_pending_fail_reason(job_id: String) -> Dictionary:
	if not _pending_fail_reasons.has(job_id):
		return {}
	var override: Dictionary = _pending_fail_reasons[job_id]
	_pending_fail_reasons.erase(job_id)
	return override

func complete(job_id: String) -> Dictionary:
	return _finish(job_id, "completed", "", "", true)

func get_tick() -> int:
	return _tick

## Job-ID/event-sequence counters, exposed for save/restore round-tripping
## (state_codec.gd). Not consumed by in-process decision logic; only incremented.
func get_next_id() -> int:
	return _next_id

func get_sequence() -> int:
	return _sequence

func get_job(job_id: String) -> Dictionary:
	return _find_job(job_id).duplicate(true)

func get_jobs() -> Array[Dictionary]:
	return _jobs.duplicate(true)

## Vector2i target -> owning job id, for every active job, plus every queued
## haul job still within its destination backoff (colonist-ai.md 3.4,
## gated on `retry_at` alone -- see _tick_haul()'s gate -- never the
## currently displayed reason, which may read labour_disabled). Derived from
## _jobs, not _table directly: today exactly one reservation exists per
## active job, on its own target. The backed-off-haul half is a deliberate
## extension: without it a backed-off haul job's unboundedly aging score
## (ADR 004) would keep winning global_assignment.gd's per-worker "best pair"
## every tick forever, since its pre-scoring "already reserved" exclusion
## never applies -- reporting its target "reserved" here routes it through
## that same exclusion, still refreshed each selection but never competing
## for a route-search slot or a chosen assignment while backed off.
func get_reservations() -> Dictionary:
	var reservations: Dictionary = {}
	for job in _jobs:
		if job["status"] == "active":
			reservations[job["target"]] = job["id"]
	# Any backed-off queued job (haul or needs_tool, sharing "retry_at" --
	# see _tick_haul()/_tool_requirement_satisfied()) also counts as reserved,
	# so its aging score can't keep winning a route-search slot while backed off.
	for job in _jobs:
		if job["status"] == "queued" and _tick < int(job["retry_at"]):
			if not reservations.has(job["target"]):
				reservations[job["target"]] = job["id"]
	return reservations

## The actual shared ReservationTable (colonist-ai.md 3.4), for callers that
## need the generic String-keyed ledger directly -- e.g. the reserve toil
## acquiring a future item/cell key on this same table, or the reusable
## invariant helper -- rather than get_reservations()'s detached Vector2i
## read model. ReservationTable is a RefCounted: this is share-by-reference,
## unlike every other getter on this class, so a future item/cell reservation
## acquired through it is real and this queue's own release_all() on that
## job's terminal transition frees it too.
func get_reservation_table() -> ReservationTableType:
	return _table

func get_events() -> Array[Dictionary]:
	return _events.duplicate(true)

## Overwrites the job list and counters from a prior save state. Reservations
## are not a separate input: they are re-derived from active jobs' targets,
## the same invariant tick() maintains (exactly one reservation per active
## job, on that job's own target). The event log is not restored: it is
## diagnostic only, and every event a future tick() emits still gets a
## correctly continued sequence number from the restored counters.
func restore(jobs: Array[Dictionary], tick_value: int, next_id: int, sequence: int) -> void:
	_jobs = jobs
	_tick = tick_value
	_next_id = next_id
	_sequence = sequence
	_table = ReservationTableType.new()
	_pending_fail_reasons = {}
	for job in _jobs:
		if job["status"] != "active":
			continue
		if String(job["kind"]) == HAUL_KIND:
			_table.acquire(ITEM_KEY_PREFIX + String(job["item_id"]), job["id"])
			var cell = job.get("cell")
			if cell != null:
				_table.acquire(_cell_key(cell), job["id"])
		elif String(job["kind"]) == SITE_FETCH_KIND:
			_table.acquire(ITEM_KEY_PREFIX + String(job["item_id"]), job["id"])
		elif String(job["kind"]) == SITE_WORK_KIND:
			pass # no reservation of its own -- see _tick_site_work().
		else:
			_table.acquire(_target_key(job["target"]), job["id"])
			for key in _extra_keys(job["id"]):
				_table.acquire(key, job["id"])
	_events = []

## Namespaces a tile target into the ReservationTable's generic String key
## space (colonist-ai.md 3.4), so an "item:"/"cell:" key can never collide
## with a tile key.
func _target_key(target: Vector2i) -> String:
	return "%s%d,%d" % [TARGET_KEY_PREFIX, target.x, target.y]

## Matches WorldState._cell_key()'s format exactly: both name the same
## ReservationTable key, so is_cell_free() sees the reservation this queue
## acquires on a haul job's destination cell.
func _cell_key(cell: Vector2i) -> String:
	return "cell:%d,%d" % [cell.x, cell.y]

func _find_job(job_id: String) -> Dictionary:
	for job in _jobs:
		if job["id"] == job_id:
			return job
	return {}

## Pure pre-mutation predicate for _finish()'s own unknown-job/already-terminal/not-active
## rules, shared with CommandChecks.check_terminal_job_command()'s preview
## path (game/scripts/core/commands/command_checks.gd) so the two can never drift. active_only
## mirrors complete()'s own active-only transition. Returns {} when job_id may transition to a
## terminal status, or the rejection _finish() would produce otherwise. Never mutates.
func check_terminal(job_id: String, active_only: bool = false) -> Dictionary:
	var job := _find_job(job_id)
	if job.is_empty():
		return {"reason": "unknown_job", "remedy": "choose_existing_job"}
	if job["status"] not in ["queued", "active"]:
		return {"reason": "job_already_terminal", "remedy": "submit_new_order"}
	if active_only and job["status"] != "active":
		return {"reason": "job_not_active", "remedy": "wait_for_activation"}
	return {}

func _finish(job_id: String, status: String, reason: String, remedy: String, active_only: bool = false) -> Dictionary:
	var terminal_check := check_terminal(job_id, active_only)
	if not terminal_check.is_empty():
		return _reject(job_id, terminal_check["reason"], terminal_check["remedy"])
	var job := _find_job(job_id)
	var target: Vector2i = job["target"]
	for key in _table.release_all(job_id):
		_emit("reservation_released", job_id, {"target": target, "key": key, "reason": reason})
	job["status"] = status
	_set_reason(job, reason, remedy)
	_emit("job_" + status, job_id, {"reason": reason, "remedy": remedy})
	return {"ok": true, "job_id": job_id}

func _block(job: Dictionary, reason: String, remedy: String, owner: String = "") -> void:
	if job["reason"] == reason and job["remedy"] == remedy and job["blocking_job_id"] == owner:
		return
	_set_reason(job, reason, remedy, owner)
	_emit("job_blocked", job["id"], {"reason": reason, "remedy": remedy, "blocking_job_id": owner})

func _set_reason(job: Dictionary, reason: String, remedy: String, owner: String = "") -> void:
	job["reason"] = reason
	job["remedy"] = remedy
	job["blocking_job_id"] = owner

func _reject(job_id: String, reason: String, remedy: String) -> Dictionary:
	var rejection := {"job_id": job_id, "reason": reason, "remedy": remedy, "tick": _tick}
	_emit("job_rejected", job_id, rejection)
	return {"ok": false, "rejection": rejection.duplicate(true)}

func _emit(event_type: String, job_id: String, data: Dictionary) -> void:
	_events.append({
		"type": event_type, "tick": _tick, "system_priority": SYSTEM_PRIORITY,
		"entity_id": job_id, "sequence": _sequence, "data": data.duplicate(true),
	})
	_sequence += 1
	_events.sort_custom(_event_before)

func _event_before(a: Dictionary, b: Dictionary) -> bool:
	if a["tick"] != b["tick"]:
		return a["tick"] < b["tick"]
	if a["system_priority"] != b["system_priority"]:
		return a["system_priority"] < b["system_priority"]
	if a["entity_id"] != b["entity_id"]:
		return a["entity_id"] < b["entity_id"]
	return a["sequence"] < b["sequence"]
