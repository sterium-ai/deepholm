class_name ToilBindings
extends RefCounted

## The per-kind callbacks ToilExecutor calls while it drives a job's toils (`hooks`, passed
## to ToilExecutor.advance()/is_dropping_leg()), their completion effects, and the
## carried-item drop/deposit helpers every terminal path shares. ToilExecutor decides *when*
## a toil runs; these decide what a kind does at that point (AGENTS.md "one work engine").
##
## Invariants:
## - This module persists nothing and hashes nothing: route/work and hands live on the
##   colonist records, reroutes in WorldState._reroutes, site-fetch caches in
##   ConstructionSystem. `hooks` is built once and never changes.
## - Carried cargo is never lost at a terminal transition: drop_carried_item_from() and
##   drop_carried_haul_item() fall back to _force_drop_carried_item() (writes straight to
##   the ground, like ToolDropToil's _drop_tool_ground) when place() refuses the tile.
## - A job paused by a need interrupt lives only in NeedsSystem.paused_jobs: its carrier
##   deposits the cargo there without touching route/work, which belong to the need job.
## - A site_fetch job's "cell" is null while fetching and the site origin once delivering
##   (_toil_is_first_leg()); job["site"] always names the site it is delivering to, so a
##   mid-chain save/load needs no extra persisted field.
## - Incident, flee and approach jobs are never resubmitted on unreachable (submit() is
##   may_be_ordered-gated); their givers pick a fresh target on the next tick.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const JobQueueType = preload("res://scripts/core/jobs/job_queue.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ToolMatchingType = preload("res://scripts/core/jobs/tool_matching.gd")
const ToolItemStoreType = preload("res://scripts/core/items/tool_item_store.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const PassabilityType = preload("res://scripts/core/map/passability.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const ConstructionSystemType = preload("res://scripts/core/objects/construction_system.gd")
const TrenchSystemType = preload("res://scripts/core/actors/trench_system.gd")
const NeedsSystemType = preload("res://scripts/core/actors/needs_system.gd")
const CombatGiverType = preload("res://scripts/core/combat/combat_giver.gd")
const ApproachGiverType = preload("res://scripts/core/combat/approach_giver.gd")

const TILE_ROCK := ContentRegistryType.TILE_ROCK
const TILE_SOIL := ContentRegistryType.TILE_SOIL
const TILE_FLOOR := ContentRegistryType.TILE_FLOOR
const TILE_PLOWED_SOIL := ContentRegistryType.TILE_PLOWED_SOIL
const TILE_PLANTED := ContentRegistryType.TILE_PLANTED
const TILE_WATER := ContentRegistryType.TILE_WATER
const TILE_TRENCH := ContentRegistryType.TILE_TRENCH

## Comparison-only stand-in for "unreachable" (hands-filling rules): _route_cost returns
## -1, and _toil_on_pick_up_success() needs a total order against a real cost.
const _UNREACHABLE_ROUTE_COST := 1 << 30

## hook name -> Callable, ToilExecutor's `hooks` argument. Every kind's hooks ignore the
## site_fetch-only entries (pick_up_count_for, site_id_for, on_deposit_success,
## is_first_leg, on_pick_up_success, go_to_skip_assignment_path).
var hooks: Dictionary = {}

var _scheduler: AssignmentType
var _toils: ToilExecutorType
var _item_table: ItemTableType
var _tool_store: ToolItemStoreType
var _tile_grid: TileGridType
var _object_table: ObjectTableType
var _passability: PassabilityType
var _construction: ConstructionSystemType
var _trench: TrenchSystemType
var _needs_system: NeedsSystemType
var _reroutes: Dictionary
var _tool_requirements_by_kind: Dictionary
var _get_colonists: Callable
var _find_colonist: Callable
var _find_job_colonist: Callable
var _finish_job: Callable
var _resubmit_unreachable_job: Callable
var _routable_to: Callable
var _route_cost: Callable
var _need_giver_resolve_job: Callable
var _rescue_giver_resolve_job: Callable

## reroutes is WorldState._reroutes, shared by reference (StateCodec restores into it).
## tool_requirements_by_kind: job kind -> {"kind","retry_base_ticks","retry_cap_ticks"},
## from jobs.json's needs_tool entries. get_colonists and the two resolve_job lambdas:
## StateCodec.decode() reassigns WorldState._colonists and rebuilds NeedGiver/RescueGiver.
func _init(scheduler: AssignmentType, toils: ToilExecutorType, item_table: ItemTableType,
		tool_store: ToolItemStoreType, tile_grid: TileGridType, object_table: ObjectTableType,
		passability: PassabilityType, construction: ConstructionSystemType, trench: TrenchSystemType,
		needs_system: NeedsSystemType, reroutes: Dictionary, tool_requirements_by_kind: Dictionary,
		get_colonists: Callable, find_colonist: Callable, find_job_colonist: Callable, finish_job: Callable,
		resubmit_unreachable_job: Callable, routable_to: Callable, route_cost: Callable,
		need_giver_resolve_job: Callable, rescue_giver_resolve_job: Callable) -> void:
	_scheduler = scheduler
	_toils = toils
	_item_table = item_table
	_tool_store = tool_store
	_tile_grid = tile_grid
	_object_table = object_table
	_passability = passability
	_construction = construction
	_trench = trench
	_needs_system = needs_system
	_reroutes = reroutes
	_tool_requirements_by_kind = tool_requirements_by_kind
	_get_colonists = get_colonists
	_find_colonist = find_colonist
	_find_job_colonist = find_job_colonist
	_finish_job = finish_job
	_resubmit_unreachable_job = resubmit_unreachable_job
	_routable_to = routable_to
	_route_cost = route_cost
	_need_giver_resolve_job = need_giver_resolve_job
	_rescue_giver_resolve_job = rescue_giver_resolve_job
	hooks = {
		"go_to_target": _toil_go_to_target,
		"go_to_passable": _toil_go_to_passable,
		"go_to_force_trim_last": _toil_go_to_force_trim_last,
		"on_unreachable": toil_on_unreachable,
		"item_id_for": _toil_item_id_for,
		"cell_for": _toil_cell_for,
		"on_toil_fail": _toil_on_toil_fail,
		"on_place_success": _toil_on_place_success,
		"on_work_complete": _toil_on_work_complete,
		"on_consume_success": _toil_on_consume_success,
		"on_no_tool_found": _toil_on_no_tool_found,
		"pick_up_count_for": _toil_pick_up_count_for,
		"site_id_for": _toil_site_id_for,
		"on_deposit_success": _toil_on_deposit_success,
		"go_to_skip_assignment_path": _toil_go_to_skip_assignment_path,
		"is_first_leg": _toil_is_first_leg,
		"on_pick_up_success": _toil_on_pick_up_success,
	}

## Deposits any carried item on colonist's own tile (colonist-ai.md 3.3) and clears
## route/work/reroute state.
func drop_carried_item_from(colonist: Dictionary) -> void:
	_deposit_carried_item(colonist)
	colonist["route"] = null
	colonist["work"] = null
	_reroutes.erase(colonist["id"])

## Ordinary place() onto the colonist's own tile, forced drop when refused; no route/work
## reset (the suspended-owner branch of drop_carried_haul_item()).
func _deposit_carried_item(colonist: Dictionary) -> void:
	if not InventoryType.is_carrying(colonist):
		return
	var result := _toils.place(colonist, Vector2i(int(colonist["x"]), int(colonist["y"])))
	if not bool(result.get("ok", false)):
		_force_drop_carried_item(colonist)

## Writes every hands entry straight to the ground (one item per kind, like place()),
## bypassing occupancy/passability: conserving the item beats a tidy cell.
func _force_drop_carried_item(colonist: Dictionary) -> void:
	for entry in InventoryType.hands_snapshot(colonist):
		_item_table.place_new_ground_item(String(entry["kind"]), int(entry["count"]), int(colonist["x"]), int(colonist["y"]))
	InventoryType.clear_hands(colonist)

## Drops a haul/build job's cargo at the shared terminal boundary: through the live
## assignment, else through the NeedsSystem.paused_jobs entry (cleared: nothing to resume).
func drop_carried_haul_item(job_id: String) -> void:
	var colonist: Dictionary = _find_job_colonist.call(job_id)
	if not colonist.is_empty():
		drop_carried_item_from(colonist)
		return
	for colonist_id in _needs_system.paused_jobs.keys():
		if String(_needs_system.paused_jobs[colonist_id]) != job_id:
			continue
		_needs_system.paused_jobs.erase(colonist_id)
		var carrier: Dictionary = _find_colonist.call(String(colonist_id))
		if not carrier.is_empty():
			_deposit_carried_item(carrier)
		return

## Terminal, not retried; HaulGiver resubmits next tick if the item is still on the ground.
func terminate_haul_job_by_id(job_id: String, reason: String, remedy: String) -> void:
	drop_carried_haul_item(job_id)
	_scheduler.queue.set_pending_fail_reason(job_id, reason, remedy)
	_finish_job.call(job_id, "fail_job")

## The tile a job's work toil operates on. A passthrough today; every work-progress key
## reader calls it so a kind with a second destination has one place to redirect.
func work_target_for(job: Dictionary) -> Vector2i:
	return job["target"]

## on_arrive for a resumed go_to leg that must not auto-start work (WorldState's
## _advance_go_to_or_resubmit()).
func toil_no_op_arrive(_colonist: Dictionary, _job_id: String) -> void:
	pass

## Haul: item tile, then its cell; site_fetch's delivery leg: job["site"]; else the target.
func _toil_go_to_target(job: Dictionary, is_first: bool) -> Vector2i:
	var kind := String(job["kind"])
	if kind == "haul":
		return job["target"] if is_first else job["cell"]
	if kind == "site_fetch" and not is_first:
		return job["site"]
	return job["target"]

## site_fetch's "cell" doubles as the delivering flag (JobQueue.mark_site_fetch_delivering()),
## so one job can visit several sources before it delivers.
func _toil_is_first_leg(job: Dictionary, colonist: Dictionary) -> bool:
	if String(job.get("kind", "")) != "site_fetch":
		return not InventoryType.is_carrying(colonist)
	return job.get("cell") == null

## Haul's delivery leg uses plain passability (the cell is known passable); every other leg
## keeps the target-tile exception. faction_id (F5) gates doors for a non-colony actor.
func _toil_go_to_passable(job: Dictionary, is_first: bool, target: Vector2i, faction_id: String = "colony") -> Callable:
	# An incident must genuinely arrive: no impassable-target exception.
	if String(job["kind"]) == "incident":
		return func(tile: Vector2i) -> float: return _passability.passable_for_faction(tile, faction_id)
	# A rescuer never routes through a trench nor trims off-target.
	if String(job["kind"]) == "rescue":
		return _trench.rescue_routable_to(target, faction_id)
	return _routable_to.call(target, faction_id) if is_first or String(job["kind"]) != "haul" else _passability.is_passable

## A site's origin is still passable at travel time, so the trim is forced: a builder lands
## adjacent and can never wall itself in when the site completes.
func _toil_go_to_force_trim_last(job: Dictionary, is_first: bool) -> bool:
	var kind := String(job["kind"])
	return kind == "site_work" or (kind == "site_fetch" and not is_first)

## Forces the fresh bounded search (which applies the trim above) instead of the scheduler's
## precomputed path: always for site_work, and for a site_fetch already retargeted.
func _toil_go_to_skip_assignment_path(job: Dictionary) -> bool:
	var kind := String(job.get("kind", ""))
	if kind == "site_work":
		return true
	return kind == "site_fetch" and _construction.site_fetch_source_retargeted.has(String(job.get("id", "")))

## A first-leg target may be reachable elsewhere: cancel and resubmit; a haul's
## unreachable destination fails. Autonomous kinds are cancelled only (class doc).
func toil_on_unreachable(job_id: String, job: Dictionary, is_first: bool) -> void:
	if String(job["kind"]) in ["incident", CombatGiverType.FLEE_KIND, ApproachGiverType.APPROACH_KIND]:
		_finish_job.call(job_id, "cancel_job")
	elif String(job["kind"]) == "rescue":
		# Retired, so another rescuer may be chosen.
		_trench.retire_rescue_job(job_id, job)
	elif String(job["kind"]) == "site_fetch":
		# Fails (dropping cargo, releasing the item); ConstructionGiver submits a replacement.
		terminate_haul_job_by_id(job_id, "blocked_target_unreachable", "restore_target_access")
	elif String(job["kind"]) == "site_work":
		# No cargo; ConstructionGiver tops the site back up to max_builders later.
		_finish_job.call(job_id, "cancel_job")
	elif is_first or String(job["kind"]) != "haul":
		_resubmit_unreachable_job.call(job_id, job)
	else:
		terminate_haul_job_by_id(job_id, "blocked_destination_gone", "choose_reachable_destination")

func _toil_item_id_for(job: Dictionary) -> String:
	return String(job["item_id"])

## Haul's destination cell (site_fetch ends in deposit, never place).
func _toil_cell_for(job: Dictionary) -> Vector2i:
	return job["cell"]

## The site a site_fetch is delivering to; "" for any other kind.
func _toil_site_id_for(job: Dictionary) -> String:
	if job.get("site") == null:
		return ""
	return _construction.site_table.find_at_origin(job["site"])

## Clamps a site_fetch pick_up to what this site and every reachable, short, not-at-capacity
## sibling still need of that kind, minus what hands hold: deposit() never takes more, and
## an excess would stay in hands. -1 (take the whole stack) otherwise.
func _toil_pick_up_count_for(job: Dictionary, colonist: Dictionary) -> int:
	if String(job.get("kind", "")) != "site_fetch":
		return -1
	var site_id := _toil_site_id_for(job)
	if site_id.is_empty():
		return -1
	var item := _item_table.item_lookup(String(job.get("item_id", "")))
	if item.is_empty():
		return -1
	var kind := String(item.get("kind", ""))
	# Cached: the pick_up may delete the item before _toil_on_pick_up_success() runs.
	_construction.site_fetch_picked_kind[String(job.get("id", ""))] = kind
	var site := _construction.site_table.get_site(site_id)
	var need := _construction.site_table.remaining(site, kind)
	var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
	for sibling in _construction.reachable_short_sibling_sites(colonist, kind, current, site_id):
		need += _construction.site_table.remaining(sibling, kind)
	need -= InventoryType.count_of_kind(colonist, kind)
	return need if need > 0 else -1

## A site_fetch's per-hop decision, once per pick_up (never mid-travel, so no flip-flop):
## deliver when hands cover the need or are full, no source is left, or the site's route
## cost is no farther than the next source's; otherwise reserve and retarget that source.
func _toil_on_pick_up_success(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	if String(job.get("kind", "")) != "site_fetch":
		return
	var colonist: Dictionary = _find_job_colonist.call(job_id)
	if colonist.is_empty():
		return
	var site_id := _toil_site_id_for(job)
	if site_id.is_empty():
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var site := _construction.site_table.get_site(site_id)
	# Not item_lookup(): an exhausting pick_up already deleted the item.
	var kind := String(_construction.site_fetch_picked_kind.get(job_id, ""))
	var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
	if (InventoryType.count_of_kind(colonist, kind) >= _construction.site_table.remaining(site, kind)
			or InventoryType.free_capacity(colonist) <= 0):
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var next_id := _construction.next_site_fetch_source(colonist, job, kind, current)
	if next_id.is_empty():
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	var next_item := _item_table.item_lookup(next_id)
	var next_tile := Vector2i(int(next_item["x"]), int(next_item["y"]))
	var faction_id := String(colonist.get("factionId", "colony"))
	var site_cost: int = _route_cost.call(current, site["origin"], faction_id)
	if site_cost < 0: site_cost = _UNREACHABLE_ROUTE_COST
	var next_cost: int = _route_cost.call(current, next_tile, faction_id)
	if next_cost < 0: next_cost = _UNREACHABLE_ROUTE_COST
	if site_cost <= next_cost:
		_scheduler.queue.mark_site_fetch_delivering(job_id)
		return
	_scheduler.queue.get_reservation_table().acquire(JobQueueType.ITEM_KEY_PREFIX + next_id, job_id)
	_scheduler.queue.retarget_site_fetch_source(job_id, next_id, next_tile)
	_construction.site_fetch_source_retargeted[job_id] = true

## pick_up/place/deposit failures are haul-shaped and fail the job for good; a failed
## consume is a need job's, which NeedGiver must hear about.
func _toil_on_toil_fail(job_id: String, reason: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	if _needs_system.need_kind_for_job(String(job.get("kind", ""))).is_empty():
		terminate_haul_job_by_id(job_id, reason, "resubmit_order")
		return
	_scheduler.queue.set_pending_fail_reason(job_id, reason, "resubmit_need")
	_finish_job.call(job_id, "fail_job")
	_need_giver_resolve_job.call(job_id)

func _toil_on_place_success(job_id: String) -> void:
	_finish_job.call(job_id, "complete_job")

## Chained delivery: leftover hands (of the kind just delivered) retarget the same job at
## the next reachable short sibling site; with none, they are dropped before completing.
## kind is read off the persisted hands, never the runtime cache, so it survives a load.
func _toil_on_deposit_success(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	var colonist: Dictionary = _find_job_colonist.call(job_id)
	if not colonist.is_empty() and InventoryType.is_carrying(colonist):
		var kind := String((InventoryType.hands_snapshot(colonist)[0] as Dictionary)["kind"])
		var current := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var delivered_site_id := _toil_site_id_for(job)
		var next_site := _construction.next_site_fetch_site(colonist, kind, current, delivered_site_id)
		if not next_site.is_empty():
			_scheduler.queue.retarget_site_fetch_site(job_id, next_site["origin"])
			return
		drop_carried_item_from(colonist)
	_finish_job.call(job_id, "complete_job")

## Applies the kind's completion effect, then finishes the job. dig/mine/till/sow re-check
## their tile: a released reservation can let another order complete there first.
## Dirty-cell/region/room hooks fire only when the tile kind actually changed.
func _toil_on_work_complete(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	var target: Vector2i = work_target_for(job)
	# ADR 026: trapping on a same-tick arrival pre-empts the completion effect below.
	if _trench.trap_on_work_complete(job_id, job, target):
		return
	var tile_before: String = _tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)]
	match job["kind"]:
		"dig":
			if _tile_grid.get_tile(target.x, target.y) != TILE_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job.call(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_TRENCH
			var sand_at := _item_table.dig_item_placement(target.x, target.y)
			_item_table.spawn_item("sand", sand_at.x, sand_at.y)
			_item_table.stage_dig_find(job_id, target.x, target.y)
		"chop":
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_SOIL  # trees only grow on soil
			_item_table.spawn_wood_item(target.x, target.y)
		"mine":
			if _tile_grid.get_tile(target.x, target.y) != TILE_ROCK:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job.call(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_FLOOR
			_item_table.spawn_stone_item(target.x, target.y)
		"forage":
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_FLOOR
			_object_table.set_object(target.x, target.y, "")
			_item_table.spawn_berries_item(target.x, target.y)
		"till":
			if _tile_grid.get_tile(target.x, target.y) != TILE_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job.call(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_PLOWED_SOIL
		"sow":
			if _tile_grid.get_tile(target.x, target.y) != TILE_PLOWED_SOIL:
				_scheduler.queue.set_pending_fail_reason(job_id, "invalid_target", "resubmit_order")
				_finish_job.call(job_id, "fail_job")
				return
			if not _item_table.remove_one_item_of_kind("seed"):
				# Seed was consumed by another sow/haul after this job committed.
				_scheduler.queue.set_pending_fail_reason(job_id, "blocked_missing_input", "resubmit_order")
				_finish_job.call(job_id, "fail_job")
				return
			_tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] = TILE_PLANTED
		"site_work":
			# Progress is the site's shared counter (every builder adds to it), so N builders
			# sum; ConstructionSystem finalizes the site once it meets build_ticks.
			_construction.add_site_work(target, job_id)
		"sleep":
			var colonist: Dictionary = _find_job_colonist.call(job_id)
			if not colonist.is_empty():
				_needs_system.apply_need_effect(colonist, job)
		"escape_trench":
			_trench.complete_escape(job_id, target)
		"rescue":
			_trench.complete_rescue(job_id)
	if _tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] != tile_before:
		_tile_grid.update_water_tile_cache(target.x, target.y, tile_before == TILE_WATER, _tile_grid.tiles[_tile_grid.tile_index(target.x, target.y)] == TILE_WATER)
		_tile_grid.mark_dirty(target.x, target.y)
		_tile_grid.get_regions().on_passability_changed(target.x, target.y)
		_tile_grid.get_rooms().on_passability_changed(target.x, target.y)
	_finish_job.call(job_id, "complete_job")
	resolve_giver_association(job_id, String(job["kind"]))

## Tells the giver owning job_id (NeedGiver, RescueGiver, the site's builder slot) that it
## resolved, wherever a job terminates outside its giver's own advance()/resolve_job().
func resolve_giver_association(job_id: String, kind: String) -> void:
	if not _needs_system.need_kind_for_job(kind).is_empty():
		_need_giver_resolve_job.call(job_id)
	elif kind == "rescue":
		_rescue_giver_resolve_job.call(job_id)
	elif kind == "site_work":
		_construction.release_site_builder(job_id)

## eat_food/drink_water: restores the need, finishes, and lets NeedGiver resume the colonist.
func _toil_on_consume_success(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	var colonist: Dictionary = _find_job_colonist.call(job_id)
	if not colonist.is_empty():
		_needs_system.apply_need_effect(colonist, job)
	_finish_job.call(job_id, "complete_job")
	_need_giver_resolve_job.call(job_id)

## requeue, not suspend: the job keeps its own restrict_to, so any eligible colonist may
## take it back; JobQueue.block_no_tool() applies the kind's backoff.
func _toil_on_no_tool_found(job_id: String, colonist_id: String, kind: String) -> void:
	_scheduler.requeue_assignment(colonist_id, job_id)
	_scheduler.queue.block_no_tool(job_id)

## JobQueue's tool gate: a matching tool is free or already reserved by job_id itself
## (reserve_tool_item() may reserve ahead of activation).
func tool_exists(job_id: String, kind: String) -> bool:
	return bool(ToolMatchingType.find_nearest_free_tool(kind, Vector2i.ZERO, job_id,
		_tool_store.get_items(), _tool_store.reservation_of, ToolMatchingType.colonist_position_map(_get_colonists.call())).get("found", false))

## {} for a kind with no needs_tool requirement.
func tool_requirement_for_kind(kind: String) -> Dictionary:
	return _tool_requirements_by_kind.get(kind, {})
