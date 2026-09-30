extends SceneTree

## Coverage for the trader_visit incident (content/incidents.json, built on
## the generic incident/visitor handling -- see docs/architecture/orders-and-movement.md's "Incident
## jobs") posts a trade_offer partway through its own unchanged wait
## (WorldState._maybe_post_trade_offer(), called from _set_work_progress()
## on the trader's first work-toil tick), and the new accept_trade command
## (WorldState._apply_accept_trade_command()) swaps the offer's two
## content/items.json items between the trader's own "inventory" component
## and the colony's stockpile, then despawns the trader through the same
## shared finish boundary its own unaccepted wait-completion despawn
## already uses. A refused offer (accept_trade never called) still ends
## with the trader gone once its own content-declared wait elapses and the
## stockpile untouched -- test_incidents.gd's exact-wait-timing
## assertions already cover every incident
## actor, trader included, despawning exactly its declared wait after
## arrival; this file does not re-prove that timing, only the trade itself.

const WorldStateType = preload("res://scripts/core/world_state.gd")

const TICK_RATE := 10
const TICK_BUDGET := 1000

var _failed := false

func _init() -> void:
	_check_trade_offer_posted_with_two_valid_items()
	_check_accept_trade_swaps_items_and_trader_leaves()
	_check_accept_trade_requires_stockpiled_item_not_carried()
	_check_refused_trade_trader_leaves_and_stockpile_unchanged()
	_check_accept_trade_rejects_unknown_trader_id()

	if _failed:
		quit(1)
		return
	print("test_trader_visit: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Mirrors test_incidents.gd's own _build_controlled_world(): a fully bare,
## tree/water/object-free floor world so the real spawn path (edge tile +
## random same-region bare target) is fully determined by the seed alone.
func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	return world

func _spawn_trader(world: WorldStateType, command_id: String) -> String:
	var result := world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": "spawn_incident", "payload": {"id": "trader_visit"}})
	_expect(result.get("ok", false), "spawn_incident trader_visit must be accepted: %s" % result)
	var actor_ids: Array = result.get("actor_ids", [])
	_expect(actor_ids.size() == 1, "trader_visit must propose exactly one trader")
	return String(actor_ids[0]) if not actor_ids.is_empty() else ""

func _accept_trade(world: WorldStateType, command_id: String, trader_id: String) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": "accept_trade", "payload": {"trader_id": trader_id}})

## test_haul_stockpile.gd's own _add_zone() helper: a stockpile zone command,
## since accept_trade's want_item must now come from an eligible stockpiled
## item (WorldState._find_available_build_item(), the same zone/reservation
## invariant `build` already resolves its own stockpiled item through).
func _add_zone(world: WorldStateType, command_id: String, x: int, y: int, width: int, height: int) -> String:
	var result := world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": x, "y": y, "width": width, "height": height}})
	_expect(result.get("ok", false), "zone_add must be accepted: %s" % result)
	return String(result.get("zone_id", ""))

func _inventory_kinds(actor: Dictionary) -> Array:
	var kinds: Array = []
	var inventory = actor.get("inventory")
	if inventory is Dictionary:
		for entry in (inventory["items"] as Array):
			kinds.append(String((entry as Dictionary).get("kind", "")))
	return kinds

func _item_kind_at(world: WorldStateType, x: int, y: int) -> String:
	for item in world.get_items():
		if int(item["x"]) == x and int(item["y"]) == y:
			return String(item["kind"])
	return ""

func _tick_until(world: WorldStateType, predicate: Callable, budget: int = TICK_BUDGET) -> int:
	for i in budget:
		if predicate.call(world):
			return i
		world.tick()
	return -1 if not predicate.call(world) else budget

func _has_offer(trader_id: String) -> Callable:
	return func(world: WorldStateType) -> bool:
		for offer in world.get_pending_trade_offers():
			if String(offer["trader_id"]) == trader_id:
				return true
		return false

func _gone(actor_id: String) -> Callable:
	return func(world: WorldStateType) -> bool: return world._find_colonist(actor_id).is_empty()

func _offer_for(world: WorldStateType, trader_id: String) -> Dictionary:
	for offer in world.get_pending_trade_offers():
		if String(offer["trader_id"]) == trader_id:
			return offer
	return {}

func _item_kinds(world: WorldStateType) -> Array:
	var kinds: Array = []
	for entry in world._content.list("items"):
		kinds.append(String(entry["id"]))
	return kinds

func _count_of_kind(world: WorldStateType, kind: String) -> int:
	var total := 0
	for item in world.get_items():
		if String(item["kind"]) == kind:
			total += int(item.get("count", 1))
	return total

func _trade_offer_events(world: WorldStateType, trader_id: String) -> Array:
	var matches: Array = []
	for event in world.get_events():
		if String(event["type"]) == "trade_offer" and String(event["data"]["trader_id"]) == trader_id:
			matches.append(event)
	return matches

func _check_trade_offer_posted_with_two_valid_items() -> void:
	if _failed: return
	var world := _build_world(101)
	var trader_id := _spawn_trader(world, "spawn_1")
	if trader_id.is_empty(): return
	_expect(_tick_until(world, _has_offer(trader_id)) >= 0, "a trade_offer must be posted for the trader")
	var offer := _offer_for(world, trader_id)
	_expect(not offer.is_empty(), "get_pending_trade_offers must expose the posted offer")
	var give_item := String(offer.get("give_item", ""))
	var want_item := String(offer.get("want_item", ""))
	var valid_kinds := _item_kinds(world)
	_expect(valid_kinds.has(give_item), "give_item '%s' must be a content/items.json id" % give_item)
	_expect(valid_kinds.has(want_item), "want_item '%s' must be a content/items.json id" % want_item)
	_expect(give_item != want_item, "the two offered items must be distinct")
	_expect(not world.is_tool_kind(give_item), "give_item must not be a tool kind")
	_expect(not world.is_tool_kind(want_item), "want_item must not be a tool kind")
	var events := _trade_offer_events(world, trader_id)
	_expect(events.size() == 1, "exactly one trade_offer event must be recorded for the trader")
	if not events.is_empty():
		var data: Dictionary = events[0]["data"]
		_expect(String(data["give_item"]) == give_item and String(data["want_item"]) == want_item,
			"the trade_offer event must name the same two items the getter exposes")
	# The trader must still be present (its own unchanged wait is still
	# running) right after the offer is posted -- accept_trade needs it alive.
	_expect(not world._find_colonist(trader_id).is_empty(), "the trader must still be in the world once its offer is posted")

func _check_accept_trade_swaps_items_and_trader_leaves() -> void:
	if _failed: return
	var world := _build_world(202)
	var trader_id := _spawn_trader(world, "spawn_2")
	if trader_id.is_empty(): return
	_expect(_tick_until(world, _has_offer(trader_id)) >= 0, "a trade_offer must be posted for the trader")
	var offer := _offer_for(world, trader_id)
	var give_item := String(offer.get("give_item", ""))
	var want_item := String(offer.get("want_item", ""))
	# The colony must already hold one want_item in an eligible stockpile
	# item for the swap to succeed -- a zoned ground item, exactly like
	# test_haul_stockpile.gd's own zone_add + direct _items fixture, since
	# accept_trade now draws only from _find_available_build_item()'s own
	# zone/reservation invariant, never a bare ground item outside a zone.
	_add_zone(world, "zone_1", 4, 4, 2, 2)
	world._items["stock_want"] = {"id": "stock_want", "x": 5, "y": 5, "kind": want_item, "count": 1}
	var trader_ref := world._find_colonist(trader_id)
	_expect(_inventory_kinds(trader_ref).has(give_item), "the trader must carry give_item before the trade")
	_expect(not _inventory_kinds(trader_ref).has(want_item), "the trader must not carry want_item before the trade")
	var give_before := _count_of_kind(world, give_item)
	var want_before := _count_of_kind(world, want_item)
	_expect(want_before >= 1, "the fixture must actually stock one want_item before accepting")
	var result := _accept_trade(world, "accept_1", trader_id)
	_expect(result.get("ok", false), "accept_trade must be accepted for a live pending offer: %s" % result)
	_expect(_count_of_kind(world, give_item) == give_before + 1,
		"accept_trade must add exactly one give_item to the stockpile")
	_expect(_count_of_kind(world, want_item) == want_before - 1,
		"accept_trade must remove exactly one want_item from the stockpile")
	_expect(_item_kind_at(world, 5, 5) == give_item,
		"give_item must land in the colony's stockpile, at the tile the traded-away want_item vacated")
	_expect(_inventory_kinds(trader_ref).has(want_item), "the trader must carry want_item after the trade")
	_expect(not _inventory_kinds(trader_ref).has(give_item), "the trader must no longer carry give_item after the trade")
	_expect(world._find_colonist(trader_id).is_empty(), "the trader must leave (be removed) once its trade is accepted")
	_expect(world.get_pending_trade_offers().is_empty(), "no pending trade offer may remain once accepted")
	# Already-departed: a second accept_trade for the same trader_id must be
	# rejected with a typed reason, never silently ignored or reapplied.
	var second := _accept_trade(world, "accept_2", trader_id)
	_expect(not second.get("ok", true), "accept_trade must reject a trader that has already departed")
	_expect(String(second.get("rejection", {}).get("reason", "")) == "invalid_target",
		"an already-departed trader must be rejected invalid_target, got %s" % second)

## The old _remove_one_item_of_kind() fallback could pull
## want_item straight out of a colonist's carrying slot mid-haul; accept_trade
## must instead require an eligible stockpiled item (in a zone, unreserved)
## and leave a merely-carried item alone.
func _check_accept_trade_requires_stockpiled_item_not_carried() -> void:
	if _failed: return
	var world := _build_world(505)
	var trader_id := _spawn_trader(world, "spawn_carry")
	if trader_id.is_empty(): return
	_expect(_tick_until(world, _has_offer(trader_id)) >= 0, "a trade_offer must be posted for the trader")
	var offer := _offer_for(world, trader_id)
	var want_item := String(offer.get("want_item", ""))
	# No zone, no ground item: want_item exists only in a colonist's carrying
	# slot, mid-haul -- never an eligible stockpiled item.
	world._colonists.append({"id": "carrier_1", "kind": "colonist", "x": 3, "y": 3,
		"route": null, "work": null, "carrying": {"kind": want_item, "count": 1}})
	var result := _accept_trade(world, "accept_carry", trader_id)
	_expect(not result.get("ok", true), "accept_trade must reject when want_item is only carried, not stockpiled")
	_expect(String(result.get("rejection", {}).get("reason", "")) == "blocked_missing_input",
		"a carried-only want_item must be rejected blocked_missing_input, got %s" % result)
	_expect(not world._find_colonist(trader_id).is_empty(), "a rejected accept_trade must leave the trader in place")
	_expect(not world.get_pending_trade_offers().is_empty(), "a rejected accept_trade must leave the offer pending")

func _check_refused_trade_trader_leaves_and_stockpile_unchanged() -> void:
	if _failed: return
	var world := _build_world(303)
	var trader_id := _spawn_trader(world, "spawn_3")
	if trader_id.is_empty(): return
	_expect(_tick_until(world, _has_offer(trader_id)) >= 0, "a trade_offer must be posted for the trader")
	var before_items := world.get_items().duplicate(true)
	# accept_trade is never called: the trader must still leave once its own
	# content-declared wait elapses, and the stockpile must be untouched.
	var wait_ticks := int(world._content.get_entry("incidents", "trader_visit")["spawn"]["wait_ticks"])
	_expect(_tick_until(world, _gone(trader_id), wait_ticks + 20) >= 0,
		"a trader whose offer was never accepted must still leave after its wait")
	_expect(world.get_items() == before_items, "a refused trade must leave the stockpile completely unchanged")
	_expect(world.get_pending_trade_offers().is_empty(),
		"a departed trader's own pending offer must be cleared immediately, not left for a later command to erase")
	# Its now-stale offer must reject accept_trade as an already-departed target.
	var late_accept := _accept_trade(world, "accept_3", trader_id)
	_expect(not late_accept.get("ok", true), "accept_trade must reject a trader that departed unaccepted")
	_expect(String(late_accept.get("rejection", {}).get("reason", "")) == "invalid_target",
		"a departed, unaccepted trader must be rejected invalid_target, got %s" % late_accept)

func _check_accept_trade_rejects_unknown_trader_id() -> void:
	if _failed: return
	var world := _build_world(404)
	var result := _accept_trade(world, "accept_unknown", "no_such_trader")
	_expect(not result.get("ok", true), "accept_trade must reject an unknown trader_id")
	_expect(String(result.get("rejection", {}).get("reason", "")) == "invalid_target",
		"an unknown trader_id must be rejected invalid_target, got %s" % result)
	var missing_payload := world.apply({"actor": "test", "command_id": "accept_missing_payload",
		"tick": world.get_tick(), "type": "accept_trade", "payload": {}})
	_expect(not missing_payload.get("ok", true), "accept_trade must reject a payload with no trader_id")
	_expect(String(missing_payload.get("rejection", {}).get("reason", "")) == "invalid_payload",
		"a missing trader_id must be rejected invalid_payload, got %s" % missing_payload)
