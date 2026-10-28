class_name CombatSystem
extends RefCounted

## Combat (ADR 021): runs CombatResolver once per tick (rule 1), applies its deaths (rule 2:
## inventory drop, then the one roster-removal path) and lets CombatGiver decide flee jobs
## (rule 4); owns death/despawn scheduling cleanup, the combat reason and component backfills.
## Invariants:
## - combat_status is runtime only (rebuilt every tick, never saved or hashed); nothing persisted here.
## - cleanup_actor_scheduling() detaches the paused job before cancelling the active one, so a
##   cancelled need job's resume never reactivates work for a removed actor.
## - ensure_combat() appends "combat" last (never a rebuild): state_hash() key order is stable.
## - The backfills are static: WorldState._init() needs them before this module's services exist.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const RelationsType = preload("res://scripts/core/relations/relations.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const HealthType = preload("res://scripts/core/actors/components/health.gd")
const CombatType = preload("res://scripts/core/actors/components/combat.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const CombatResolverType = preload("res://scripts/core/combat/combat_resolver.gd")
const CombatGiverType = preload("res://scripts/core/combat/combat_giver.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const ToolItemStoreType = preload("res://scripts/core/items/tool_item_store.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const WorkProgressType = preload("res://scripts/core/jobs/work_progress.gd")
const NeedsSystemType = preload("res://scripts/core/actors/needs_system.gd")

## Exposed while an actor has an adjacent hostile target this tick.
const REASON_FIGHTING := "fighting"

## actor_id -> REASON_FIGHTING while it has an adjacent hostile target this tick.
var combat_status: Dictionary = {}

var _content: ContentRegistryType
var _relations: RelationsType
var _event_priority: int
var _scheduler: AssignmentType
var _progress_table: WorkProgressType
var _tool_store: ToolItemStoreType
var _item_table: ItemTableType
var _object_table: ObjectTableType
var _event_log: EventLogType
var _needs_system: NeedsSystemType
var _combat_giver: CombatGiverType
var _get_colonists: Callable
var _approach_forget: Callable
var _job_restricted_to: Callable
var _finish_job: Callable
var _resolve_giver_association: Callable
var _remove_colonist_by_id: Callable
var _is_tool_kind: Callable
var _spawn_ground_tool_item: Callable

## get_colonists and approach_forget are lambdas: StateCodec.decode() reassigns
## WorldState._colonists and rebuilds ApproachGiver.
func _init(content: ContentRegistryType, relations: RelationsType, event_priority: int, scheduler: AssignmentType,
		progress_table: WorkProgressType, tool_store: ToolItemStoreType, item_table: ItemTableType,
		object_table: ObjectTableType, event_log: EventLogType, needs_system: NeedsSystemType,
		combat_giver: CombatGiverType, get_colonists: Callable, approach_forget: Callable,
		job_restricted_to: Callable, finish_job: Callable, resolve_giver_association: Callable,
		remove_colonist_by_id: Callable, is_tool_kind: Callable, spawn_ground_tool_item: Callable) -> void:
	_content = content
	_relations = relations
	_event_priority = event_priority
	_scheduler = scheduler
	_progress_table = progress_table
	_tool_store = tool_store
	_item_table = item_table
	_object_table = object_table
	_event_log = event_log
	_needs_system = needs_system
	_combat_giver = combat_giver
	_get_colonists = get_colonists
	_approach_forget = approach_forget
	_job_restricted_to = job_restricted_to
	_finish_job = finish_job
	_resolve_giver_association = resolve_giver_association
	_remove_colonist_by_id = remove_colonist_by_id
	_is_tool_kind = is_tool_kind
	_spawn_ground_tool_item = spawn_ground_tool_item

## Backfills "health", "factionId" ("colony") and "trapped" (null) so state_hash() matches a
## freshly decoded entity.
static func ensure_health(colonists: Array[Dictionary], content: ContentRegistryType) -> void:
	for colonist in colonists:
		if not colonist.has("factionId"): colonist["factionId"] = "colony"
		if not colonist.has("trapped"): colonist["trapped"] = null
		if ActorTableType.get_component(colonist, "health", content) is Dictionary:
			continue
		var definition: Dictionary = content.get_entry("actors", String(colonist.get("kind", "colonist")))
		colonist["health"] = HealthType.build_full(definition.get("tunables", {}).get("health", {}))

## Backfills "combat" (appended last) onto a colonist whose definition declares it; the colonist
## spawn path never builds it, generic actors already have it.
static func ensure_combat(colonists: Array[Dictionary], content: ContentRegistryType) -> void:
	for colonist in colonists:
		if not ActorTableType.has_component(colonist, "worker", content):
			continue
		if colonist.has("combat") or not ActorTableType.has_component(colonist, "combat", content):
			continue
		var definition: Dictionary = content.get_entry("actors", String(colonist.get("kind", "colonist")))
		colonist["combat"] = CombatType.build(definition.get("tunables", {}).get("combat", {}))

## Once per tick before the scheduler sees any colonist: attacks (rule 1), deaths (rule 2),
## then CombatGiver's flee decision (rule 4). Per ADR 011 this calls both, implements neither.
func apply_combat(tick: int) -> void:
	var result := CombatResolverType.resolve_tick(_get_colonists.call(), _content, _relations, tick, _event_priority,
		_object_table.get_object, _object_table.object_health_at, _object_table.get_object_faction_id, _object_table.damage_object, _event_log.insert_event, _event_log.next_sequence)
	combat_status.clear()
	for actor_id in (result["fighting"] as Array):
		combat_status[String(actor_id)] = REASON_FIGHTING
	for dead_actor in (result["dead_actors"] as Array):
		apply_actor_death(dead_actor)
	_combat_giver.advance(_get_colonists.call(), tick)

## "" when actor_id names no known actor or has no adjacent hostile target this tick.
func get_actor_combat_reason(actor_id: String) -> String:
	return String(combat_status.get(actor_id, ""))

## Rule 2: drops the dead actor's inventory (death only, not despawn), then removes it through
## WorldState._remove_colonist_by_id(), which runs cleanup_actor_scheduling().
func apply_actor_death(actor: Dictionary) -> void:
	var colonist_id: String = String(actor["id"])
	_drop_inventory_contents(actor)
	_remove_colonist_by_id.call(colonist_id, true)

## Cancels every nonterminal job restricted to colonist_id through the shared finish boundary and
## tells NeedGiver/CombatGiver/ApproachGiver (death and incident despawn). Paused job detached first
## (class doc); re-cancelling the incident job this runs inside of is a no-op.
func cleanup_actor_scheduling(colonist_id: String) -> void:
	# Retire the actor's in-flight route-search batch, or a candidate it was searching stays claimed.
	_scheduler.retire_worker(colonist_id)
	var paused_job_id := ""
	if _needs_system.paused_jobs.has(colonist_id):
		paused_job_id = String(_needs_system.paused_jobs[colonist_id])
		_needs_system.paused_jobs.erase(colonist_id)
	var assignment: Variant = _scheduler.get_assignments().get(colonist_id)
	if assignment != null:
		_cancel_job_for_death(String(assignment["job_id"]))
	if not paused_job_id.is_empty():
		_cancel_job_for_death(paused_job_id)
	for job in _scheduler.queue.get_jobs():
		if String(job.get("status", "")) not in ["queued", "active"]:
			continue
		var job_id: String = String(job["id"])
		if _job_restricted_to.call(job_id) != colonist_id:
			continue
		_cancel_job_for_death(job_id)
	_combat_giver.forget(colonist_id)
	_approach_forget.call(colonist_id)

## Cancels job_id and tells its giver, so NeedGiver's _pending never points at a removed actor.
func _cancel_job_for_death(job_id: String) -> void:
	var job := _scheduler.queue.get_job(job_id)
	# Only a rescue's job-scoped key is dropped; tile progress outlives the actor for a successor order.
	if _finish_job.call(job_id, "cancel_job").get("ok", false):
		_progress_table.clear_terminated_job(job_id, job, false)
	_resolve_giver_association.call(job_id, String(job.get("kind", "")))

## Drops hands contents, the held tool (moved, keeping identity and reservation) and a generic
## actor's inventory and tool slot as loose items on its tile.
func _drop_inventory_contents(actor: Dictionary) -> void:
	var x := int(actor["x"])
	var y := int(actor["y"])
	for entry in InventoryType.hands_snapshot(actor):
		_item_table.place_new_ground_item(String(entry["kind"]), int(entry["count"]), x, y)
	var held_tool_id := WorkerType.get_held_tool(actor)
	if not held_tool_id.is_empty():
		_tool_store.set_ground(held_tool_id, x, y)
	var inventory: Variant = actor.get("inventory")
	if inventory is Dictionary:
		for raw_item in (inventory.get("items", []) as Array):
			var item: Dictionary = raw_item
			_drop_inventory_item(String(item.get("kind", "")), int(item.get("count", 1)), x, y)
		var carried_tool_kind := String(inventory.get("tool", ""))
		if not carried_tool_kind.is_empty():
			_drop_inventory_item(carried_tool_kind, 1, x, y)

## A tool kind goes to ToolItemStore (one ground tool per unit: tools carry identity); any other
## kind is an ItemTable stack.
func _drop_inventory_item(kind: String, count: int, x: int, y: int) -> void:
	if _is_tool_kind.call(kind):
		for _unit in count:
			_spawn_ground_tool_item.call(kind, x, y)
		return
	_item_table.place_new_ground_item(kind, count, x, y)

## Every actor with health (not just workers), deep copies, for viewer health bars.
func get_actors_with_health() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for actor in _get_colonists.call():
		if actor.get("health") is Dictionary:
			copy.append(actor.duplicate(true))
	return copy
