extends SceneTree

## Exercises ToilExecutor.pick_up()/place() directly (colonist-ai.md 3.3,
## issue #402): a ground wood item moves from one tile to another via a
## colonist's hands list, each toil's precondition re-check fails with a
## typed reason rather than crashing when it no longer holds, and a pick_up
## moves at most HANDS_CAPACITY units regardless of how large the ground
## stack is.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

var _failed := false

func _init() -> void:
	_check_pick_up_then_place_moves_the_item()
	_check_pick_up_out_of_reach_fails_typed()
	_check_pick_up_already_gone_fails_typed()
	_check_place_onto_blocked_destination_fails_typed()
	_check_place_onto_colonist_occupied_destination_fails_typed()
	_check_place_onto_item_occupied_destination_fails_typed()
	_check_save_load_round_trip_with_items_and_carrying()
	_check_state_hash_reflects_next_item_id()
	_check_save_load_preserves_next_item_id_continuation()
	_check_pick_up_four_unit_stack_moves_fully_in_one_call()
	_check_pick_up_six_unit_stack_leaves_two_and_hands_never_exceed_capacity()
	_check_pick_up_fails_hands_full()
	_check_pick_up_zero_count_is_a_no_op()

	if _failed:
		quit(1)
		return
	print("test_items_pick_up_place: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A small all-floor map so every tile the test touches is passable except
## the one rock tile _check_place_onto_blocked_destination_fails_typed() uses.
func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	return world

func _colonist(id: String, x: int, y: int) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y, "route": null, "work": null, "hands": []}

func _place_wood_item(world: WorldStateType, item_id: String, x: int, y: int, count: int = 1) -> void:
	world._items[item_id] = {"id": item_id, "x": x, "y": y, "kind": "wood", "count": count}
	world._next_item_id = 2

## Sum of every hands entry's count -- must never exceed InventoryType.HANDS_CAPACITY.
func _hands_total(colonist: Dictionary) -> int:
	var total := 0
	for entry in (colonist.get("hands", []) as Array):
		total += int(entry["count"])
	return total

## The item moves from (2, 2) to (5, 5): removed from the ground map on
## pick_up, hands set while in transit, placed back with a fresh id/position
## and hands cleared on place.
func _check_pick_up_then_place_moves_the_item() -> void:
	if _failed:
		return
	var world := _build_world(1001)
	_place_wood_item(world, "item_1", 2, 2)
	var colonist := _colonist("colonist_0", 2, 2)
	world._colonists.append(colonist)

	_expect(world.get_ground_wood(2, 2) == 1, "item must start on the ground at (2,2)")

	var pick_result := world._toils.pick_up(colonist, "item_1")
	_expect(pick_result.get("ok") == true, "pick_up must succeed while on the item's tile: %s" % pick_result)
	_expect(world.get_ground_wood(2, 2) == 0, "pick_up must remove the item from the ground map")
	_expect(InventoryType.is_carrying(colonist), "pick_up must add the item to the colonist's hands")
	_expect(InventoryType.count_of_kind(colonist, "wood") == 1, "hands must record the item's kind and count")

	var place_result := world._toils.place(colonist, Vector2i(5, 5))
	_expect(place_result.get("ok") == true, "place must succeed onto a free, passable cell: %s" % place_result)
	_expect(not InventoryType.is_carrying(colonist), "place must clear the colonist's hands")
	_expect(world.get_ground_wood(5, 5) == 1, "place must put the item down at the destination cell")
	_expect(world.get_ground_wood(2, 2) == 0, "the item must not remain at its original tile")
	var placed_id: String = String((place_result["item_ids"] as Array)[0])
	_expect(world._items[placed_id]["x"] == 5 and world._items[placed_id]["y"] == 5,
		"the placed item must sit at the new position")

## A colonist too far from the item's tile must fail pick_up with a typed
## reason, leaving the item untouched on the ground.
func _check_pick_up_out_of_reach_fails_typed() -> void:
	if _failed:
		return
	var world := _build_world(1002)
	_place_wood_item(world, "item_1", 2, 2)
	var colonist := _colonist("colonist_0", 10, 10)
	world._colonists.append(colonist)

	var result := world._toils.pick_up(colonist, "item_1")
	_expect(result.get("ok") == false and result.get("reason") == "item_out_of_reach",
		"pick_up from far away must fail with item_out_of_reach: %s" % result)
	_expect(not InventoryType.is_carrying(colonist), "a failed pick_up must not set hands")
	_expect(world.get_ground_wood(2, 2) == 1, "a failed pick_up must leave the item on the ground")

## A second colonist trying to pick up an item another colonist already
## carried away must fail with a typed reason, not throw, even though the
## item id was valid a moment ago.
func _check_pick_up_already_gone_fails_typed() -> void:
	if _failed:
		return
	var world := _build_world(1003)
	_place_wood_item(world, "item_1", 2, 2)
	var first := _colonist("colonist_0", 2, 2)
	var second := _colonist("colonist_1", 2, 3)
	world._colonists.append(first)
	world._colonists.append(second)

	var first_result := world._toils.pick_up(first, "item_1")
	_expect(first_result.get("ok") == true, "the first colonist must successfully pick up the item: %s" % first_result)

	var second_result := world._toils.pick_up(second, "item_1")
	_expect(second_result.get("ok") == false and second_result.get("reason") == "item_not_found",
		"pick_up on an already-gone item must fail with item_not_found rather than throw: %s" % second_result)
	_expect(not InventoryType.is_carrying(second), "the second colonist must not end up carrying anything")

## place() onto an impassable tile must fail with a typed reason and leave
## the colonist still carrying the item.
func _check_place_onto_blocked_destination_fails_typed() -> void:
	if _failed:
		return
	var world := _build_world(1004)
	world._tiles[world._tile_index(6, 6)] = WorldStateType.TILE_ROCK
	_place_wood_item(world, "item_1", 2, 2)
	var colonist := _colonist("colonist_0", 2, 2)
	world._colonists.append(colonist)

	var pick_result := world._toils.pick_up(colonist, "item_1")
	_expect(pick_result.get("ok") == true, "setup pick_up must succeed: %s" % pick_result)

	var place_result := world._toils.place(colonist, Vector2i(6, 6))
	_expect(place_result.get("ok") == false and place_result.get("reason") == "destination_blocked",
		"place onto an impassable tile must fail with destination_blocked: %s" % place_result)
	_expect(InventoryType.is_carrying(colonist), "a failed place must leave the colonist still carrying the item")
	_expect(world.get_ground_wood(6, 6) == 0, "a failed place must not put the item down")

## place() onto a passable tile already occupied by another colonist must
## fail with a typed reason, leave the colonist still carrying the item, and
## must not move the occupying colonist or spawn a second item on its tile.
func _check_place_onto_colonist_occupied_destination_fails_typed() -> void:
	if _failed:
		return
	var world := _build_world(1006)
	_place_wood_item(world, "item_1", 2, 2)
	var carrier := _colonist("colonist_0", 2, 2)
	var occupant := _colonist("colonist_1", 6, 6)
	world._colonists.append(carrier)
	world._colonists.append(occupant)

	var pick_result := world._toils.pick_up(carrier, "item_1")
	_expect(pick_result.get("ok") == true, "setup pick_up must succeed: %s" % pick_result)

	var place_result := world._toils.place(carrier, Vector2i(6, 6))
	_expect(place_result.get("ok") == false and place_result.get("reason") == "destination_blocked",
		"place onto a colonist-occupied tile must fail with destination_blocked: %s" % place_result)
	_expect(InventoryType.is_carrying(carrier), "a failed place must leave the colonist still carrying the item")
	_expect(world.get_ground_wood(6, 6) == 0, "a failed place must not put the item down on an occupied tile")
	_expect(occupant["x"] == 6 and occupant["y"] == 6, "the occupying colonist must not be displaced")

## place() onto a passable tile already occupied by another ground item must
## fail with a typed reason and leave the colonist still carrying its item.
func _check_place_onto_item_occupied_destination_fails_typed() -> void:
	if _failed:
		return
	var world := _build_world(1007)
	_place_wood_item(world, "item_1", 2, 2)
	world._items["item_2"] = {"id": "item_2", "x": 6, "y": 6, "kind": "wood", "count": 1}
	world._next_item_id = 3
	var carrier := _colonist("colonist_0", 2, 2)
	world._colonists.append(carrier)

	var pick_result := world._toils.pick_up(carrier, "item_1")
	_expect(pick_result.get("ok") == true, "setup pick_up must succeed: %s" % pick_result)

	var place_result := world._toils.place(carrier, Vector2i(6, 6))
	_expect(place_result.get("ok") == false and place_result.get("reason") == "destination_blocked",
		"place onto an item-occupied tile must fail with destination_blocked: %s" % place_result)
	_expect(InventoryType.is_carrying(carrier), "a failed place must leave the colonist still carrying the item")
	_expect(world.get_ground_wood(6, 6) == 1, "the pre-existing item on the destination tile must be untouched")

## A save/load round trip of a world holding an untouched ground item and a
## colonist mid-carry (item removed from the ground map, hands set) must
## reproduce the exact same state_hash(), and the restored colonist must still
## be carrying the same item.
func _check_save_load_round_trip_with_items_and_carrying() -> void:
	if _failed:
		return
	var world := _build_world(1005)
	_place_wood_item(world, "item_1", 2, 2)
	world._items["item_2"] = {"id": "item_2", "x": 7, "y": 7, "kind": "wood", "count": 1}
	world._next_item_id = 3
	var colonist := _colonist("colonist_0", 2, 2)
	world._colonists.append(colonist)

	var pick_result := world._toils.pick_up(colonist, "item_1")
	_expect(pick_result.get("ok") == true, "setup pick_up must succeed: %s" % pick_result)

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored.state_hash() == world.state_hash(),
		"save/load round trip with a ground item and a carrying colonist must reproduce the same state_hash()")
	var restored_colonist: Dictionary = restored._colonists[0]
	_expect(InventoryType.is_carrying(restored_colonist) and InventoryType.count_of_kind(restored_colonist, "wood") == 1,
		"restored colonist must still be carrying the picked-up item")
	_expect(restored.get_ground_wood(7, 7) == 1, "restored world must still have the untouched ground item")
	_expect(restored.get_ground_wood(2, 2) == 0, "restored world must not resurrect the carried item on the ground")

## Two worlds with identical items and colonists but different next-item-id
## counters must hash differently: the counter decides which id the *next*
## chop hands out, so two states that would diverge on their next generated
## item id must not collide under state_hash().
func _check_state_hash_reflects_next_item_id() -> void:
	if _failed:
		return
	var world_a := _build_world(1008)
	_place_wood_item(world_a, "item_1", 2, 2)
	world_a._next_item_id = 5

	var world_b := _build_world(1008)
	_place_wood_item(world_b, "item_1", 2, 2)
	world_b._next_item_id = 6

	_expect(world_a.state_hash() != world_b.state_hash(),
		"differing next_item_id counters must produce different state_hash() results")

## A save/load round trip must preserve not just the existing items but the
## id-generation counter itself: chopping identically on the source and its
## restored copy must hand out the same next item id, proving the counter
## survived the round trip rather than resetting to a colliding default.
func _check_save_load_preserves_next_item_id_continuation() -> void:
	if _failed:
		return
	var world := _build_world(1009)
	_place_wood_item(world, "item_1", 2, 2)
	world._next_item_id = 7

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored._next_item_id == 7, "restore must preserve the source's next_item_id counter")

	world._spawn_wood_item(9, 9)
	restored._spawn_wood_item(9, 9)
	_expect(world._items.has("item_7") and restored._items.has("item_7"),
		"the source and its restore must generate the same next item id after loading")
	_expect(world._next_item_id == restored._next_item_id,
		"the source and its restore must advance the counter identically after generating an item")

## Issue #402 acceptance: 4 units from a ground stack of exactly 4 move in one
## pick_up call, entirely filling the colonist's hands.
func _check_pick_up_four_unit_stack_moves_fully_in_one_call() -> void:
	if _failed:
		return
	var world := _build_world(1010)
	_place_wood_item(world, "item_1", 2, 2, 4)
	var colonist := _colonist("colonist_0", 2, 2)
	world._colonists.append(colonist)

	var result := world._toils.pick_up(colonist, "item_1")
	_expect(result.get("ok") == true and int(result.get("count", 0)) == 4,
		"pick_up of a 4-unit stack must move all 4 units in one call: %s" % result)
	_expect(world.get_ground_wood(2, 2) == 0, "a fully-picked-up stack must leave nothing on the ground")
	_expect(InventoryType.count_of_kind(colonist, "wood") == 4, "hands must hold all 4 units")
	_expect(_hands_total(colonist) == 4, "hands total must be exactly 4")

## Issue #402 acceptance: a ground stack of 6 leaves 2 on the ground after one
## pick_up of 4 (hands capped at InventoryType.HANDS_CAPACITY), and hands
## total count never exceeds 4 at any point, checked after every tick of the
## scenario through to the haul completing.
func _check_pick_up_six_unit_stack_leaves_two_and_hands_never_exceed_capacity() -> void:
	if _failed:
		return
	var world := _build_world(1011)
	_place_wood_item(world, "item_1", 2, 2, 6)
	var colonist := _colonist("colonist_0", 2, 2)
	world._colonists.append(colonist)

	var result := world._toils.pick_up(colonist, "item_1")
	_expect(result.get("ok") == true and int(result.get("count", 0)) == 4,
		"pick_up of a 6-unit stack must move only 4 units (hands capacity) in one call: %s" % result)
	_expect(world.get_ground_wood(2, 2) == 2, "a 6-unit stack must leave 2 units on the ground after one pick_up of 4")
	_expect(InventoryType.count_of_kind(colonist, "wood") == 4, "hands must hold exactly 4 units")
	_expect(_hands_total(colonist) <= InventoryType.HANDS_CAPACITY, "hands total must never exceed capacity right after pick_up")

	for i in 30:
		world.tick()
		_expect(_hands_total(colonist) <= InventoryType.HANDS_CAPACITY,
			"hands total must never exceed capacity at tick %d" % i)
		for other in world.get_colonists():
			_expect(_hands_total(other) <= InventoryType.HANDS_CAPACITY,
				"no colonist's hands total may ever exceed capacity at tick %d" % i)

## Issue #402: pick_up on a colonist whose hands are already completely full
## must fail with the new typed reason, moving nothing.
func _check_pick_up_fails_hands_full() -> void:
	if _failed:
		return
	var world := _build_world(1012)
	_place_wood_item(world, "item_1", 2, 2, 4)
	_place_wood_item(world, "item_2", 2, 2, 1)
	var colonist := _colonist("colonist_0", 2, 2)
	world._colonists.append(colonist)

	var first := world._toils.pick_up(colonist, "item_1")
	_expect(first.get("ok") == true and int(first.get("count", 0)) == 4, "setup pick_up must fill hands: %s" % first)

	var second := world._toils.pick_up(colonist, "item_2")
	_expect(second.get("ok") == false and second.get("reason") == "hands_full",
		"pick_up with no free hands capacity must fail hands_full: %s" % second)
	_expect(world.get_ground_wood(2, 2) == 1, "a failed pick_up must leave the second item untouched on the ground")
	_expect(_hands_total(colonist) == 4, "hands total must stay at 4 after a failed pick_up")

## Issue #402 revision: an explicit count: 0 request must succeed as a no-op
## -- moving nothing, leaving the ground item's count untouched, and never
## creating a zero-count hands entry (ActorInventory's count >= 1 invariant).
func _check_pick_up_zero_count_is_a_no_op() -> void:
	if _failed:
		return
	var world := _build_world(1013)
	_place_wood_item(world, "item_1", 2, 2, 4)
	var colonist := _colonist("colonist_0", 2, 2)
	world._colonists.append(colonist)

	var result := world._toils.pick_up(colonist, "item_1", 0)
	_expect(result.get("ok") == true and int(result.get("count", -1)) == 0,
		"pick_up with count: 0 must succeed as a no-op: %s" % result)
	_expect(world.get_ground_wood(2, 2) == 4, "a count: 0 pick_up must leave the ground item's count untouched")
	_expect(not InventoryType.is_carrying(colonist), "a count: 0 pick_up must not create a hands entry")
	_expect(_hands_total(colonist) == 0, "hands total must stay at 0 after a count: 0 pick_up")
	for entry in (colonist.get("hands", []) as Array):
		_expect(int(entry["count"]) >= 1, "no hands entry may ever hold a count below 1: %s" % entry)
