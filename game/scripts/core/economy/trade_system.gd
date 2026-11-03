class_name TradeSystem
extends RefCounted

## Trader visits (ADR 035, 036): a visitor's trade_offer and the accept_trade swap.
## Invariants:
## - A visitor posts once, on its incident job's first work tick (pending_offers is the guard).
## - The pick is deterministic from the trader id's hash: no RNG stream.
## - accept_trade takes only an unreserved stockpiled unit, never one in a colonist's hands.
## - WorldState._finish_job() erases an offer on any terminal transition of its trader's job.
## - pending_offers is neither persisted nor hashed: an offer is lost across a save/load.

const SeededClockType = preload("res://scripts/core/seeded_clock.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const AssignmentType = preload("res://scripts/core/scheduling/global_assignment.gd")
const ItemTableType = preload("res://scripts/core/items/item_table.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")

## trader_id -> {"give_item", "want_item"}: each trader's outstanding trade_offer.
var pending_offers: Dictionary = {}

var _clock: SeededClockType
var _content: ContentRegistryType
var _item_table: ItemTableType
var _scheduler: AssignmentType
var _event_log: EventLogType
## system_priority of the trade_offer event (WorldState.PRIORITY_TICK).
var _priority_tick: int
## (kind: String) -> bool: kind is a content/items.json tool.
var _is_tool_kind: Callable
## (colonist_id: String) -> Dictionary: the live actor record, or {}.
var _find_colonist: Callable
## (job_id: String) -> Dictionary: the colonist assigned to the job, or {}.
var _find_job_colonist: Callable
## (job_id: String, status: String) -> Dictionary: WorldState's terminal-transition boundary.
var _finish_job: Callable
## (colonist_id: String) -> void: removes an actor from the roster.
var _remove_colonist_by_id: Callable

func _init(clock: SeededClockType, content: ContentRegistryType, item_table: ItemTableType,
		scheduler: AssignmentType, event_log: EventLogType, priority_tick: int, is_tool_kind: Callable,
		find_colonist: Callable, find_job_colonist: Callable, finish_job: Callable,
		remove_colonist_by_id: Callable) -> void:
	_clock = clock
	_content = content
	_item_table = item_table
	_scheduler = scheduler
	_event_log = event_log
	_priority_tick = priority_tick
	_is_tool_kind = is_tool_kind
	_find_colonist = find_colonist
	_find_job_colonist = find_job_colonist
	_finish_job = finish_job
	_remove_colonist_by_id = remove_colonist_by_id

## Every outstanding trade_offer, for the presentation layer.
func get_pending_trade_offers() -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	for trader_id in pending_offers:
		var offer: Dictionary = pending_offers[trader_id]
		offers.append({"trader_id": trader_id, "give_item": String(offer["give_item"]), "want_item": String(offer["want_item"])})
	return offers

## Posts job_id's trader offer once; a no-op for a non-visitor or one that already posted.
func maybe_post_trade_offer(job_id: String) -> void:
	var actor: Dictionary = _find_job_colonist.call(job_id)
	if actor.is_empty() or not ActorTableType.has_component(actor, "visitor", _content):
		return
	var trader_id: String = String(actor["id"])
	if pending_offers.has(trader_id):
		return
	_post_trade_offer(actor)

## give_item goes into the trader's inventory component; want_item is taken only on accept.
func _post_trade_offer(actor: Dictionary) -> void:
	var trader_id: String = String(actor["id"])
	var picks := _pick_trade_items(trader_id)
	var give_item: String = picks[0]
	var want_item: String = picks[1]
	_append_trader_inventory_item(actor, give_item)
	pending_offers[trader_id] = {"give_item": give_item, "want_item": want_item}
	_event_log.insert_event({
		"type": "trade_offer", "tick": _clock.tick, "system_priority": _priority_tick,
		"entity_id": trader_id, "sequence": _event_log.next_sequence(),
		"data": {"trader_id": trader_id, "give_item": give_item, "want_item": want_item},
	})

## Two distinct non-tool kinds (tools would need ToolItemStore's reservation machinery).
func _pick_trade_items(trader_id: String) -> Array:
	var kinds: Array[String] = []
	for entry in _content.list("items"):
		var id := String(entry["id"])
		if not _is_tool_kind.call(id):
			kinds.append(id)
	kinds.sort()
	var base := int(trader_id.hash()) % kinds.size()
	if base < 0:
		base += kinds.size()
	return [kinds[base], kinds[(base + 1) % kinds.size()]]

## accept_trade {trader_id}: swaps one stockpiled want_item unit for give_item on the vacated
## tile, then cancels the trader's job so it leaves like an unaccepted despawn.
func apply_accept_trade_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if not (payload.get("trader_id") is String) or String(payload.get("trader_id", "")).is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], "invalid_payload",
			{"detail": "accept_trade_payload"})
	var trader_id: String = String(payload["trader_id"])
	if not pending_offers.has(trader_id):
		return _event_log.rejection(command["command_id"], command["actor"], "invalid_target",
			{"detail": "no_pending_offer", "trader_id": trader_id})
	var trader: Dictionary = _find_colonist.call(trader_id)
	if trader.is_empty():
		pending_offers.erase(trader_id)
		return _event_log.rejection(command["command_id"], command["actor"], "invalid_target",
			{"detail": "trader_departed", "trader_id": trader_id})
	var offer: Dictionary = pending_offers[trader_id]
	var want_item := String(offer["want_item"])
	var give_item := String(offer["give_item"])
	var stock_item_id := _item_table.find_available_stockpiled_item(want_item, 1)
	if stock_item_id.is_empty():
		return _event_log.rejection(command["command_id"], command["actor"], "blocked_missing_input",
			{"remedy": "stockpile_the_required_item", "item": want_item})
	var stock_tile := _item_table.remove_stockpiled_item_unit(stock_item_id)
	_append_trader_inventory_item(trader, want_item)
	_remove_trader_offered_item(trader, give_item)
	_item_table.spawn_item(give_item, stock_tile)
	pending_offers.erase(trader_id)
	var assignment: Variant = _scheduler.get_assignments().get(trader_id)
	if assignment != null:
		_finish_job.call(String(assignment["job_id"]), "cancel_job")
	else:
		_remove_colonist_by_id.call(trader_id)
	return _event_log.applied(command)

## One unit of `kind` into actor's inventory component (per-instance shape, no "id").
func _append_trader_inventory_item(actor: Dictionary, kind: String) -> void:
	var inventory: Variant = actor.get("inventory")
	if inventory is Dictionary:
		(inventory["items"] as Array).append({"kind": kind, "count": 1})

## Removes the first inventory entry of `kind` (the one _append_trader_inventory_item() added).
func _remove_trader_offered_item(trader: Dictionary, kind: String) -> void:
	var inventory: Variant = trader.get("inventory")
	if not (inventory is Dictionary):
		return
	var items: Array = inventory["items"]
	for i in items.size():
		if String((items[i] as Dictionary).get("kind", "")) == kind:
			items.remove_at(i)
			return
