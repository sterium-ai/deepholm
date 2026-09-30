extends SceneTree

## Exercises WorldState.apply()'s zone_add/zone_remove commands:
## both apply immediately (no job queue), validated/rejected the same way as
## place_object/remove_object in _apply_place_object_command (see
## test_place_object_command.gd). Also exercises the per-cell free/reserved
## lookup t5's haul jobs will build on: WorldState.is_cell_free() answers
## against the scheduler's shared ReservationTable (jobs/reservation_table.gd),
## namespaced with a "cell:" key distinct from JobQueue's own "tile:" keys.

const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failed := false

func _init() -> void:
	_check_zone_add_valid_and_persisted()
	_check_zone_add_rejects_out_of_bounds()
	_check_zone_add_rejects_degenerate()
	_check_zone_add_rejects_overlap()
	_check_zone_add_rejects_invalid_payload()
	_check_zone_remove_succeeds()
	_check_zone_remove_rejects_unknown_id()
	_check_zone_remove_rejects_invalid_payload()
	_check_free_cell_query()

	if _failed:
		quit(1)
		return
	print("test_zone_commands: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _zone_add_command(world: WorldStateType, command_id: String, x: int, y: int, width: int, height: int) -> Dictionary:
	return world.apply({
		"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": x, "y": y, "width": width, "height": height},
	})

func _zone_remove_command(world: WorldStateType, command_id: String, id: String) -> Dictionary:
	return world.apply({
		"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "zone_remove", "payload": {"id": id},
	})

func _check_zone_add_valid_and_persisted() -> void:
	if _failed:
		return
	var world := WorldStateType.new(1, 10)
	var result := _zone_add_command(world, "add_valid", 5, 5, 3, 2)
	_expect(result.get("ok", false), "a valid zone_add must be accepted")
	var zone_id: String = result.get("zone_id", "")
	_expect(not zone_id.is_empty(), "zone_add must return a non-empty zone_id")
	var zones := world.get_zones()
	_expect(zones.size() == 1, "the added zone must be persisted in get_zones()")
	if zones.size() == 1:
		_expect(zones[0]["id"] == zone_id and zones[0]["x"] == 5 and zones[0]["y"] == 5
			and zones[0]["width"] == 3 and zones[0]["height"] == 2,
			"the persisted zone must match the submitted rectangle")
	var fetched := world.get_zone(zone_id)
	_expect(fetched.get("id", "") == zone_id, "get_zone(id) must return the added zone")

func _check_zone_add_rejects_out_of_bounds() -> void:
	if _failed:
		return
	var world := WorldStateType.new(2, 10)
	var result := _zone_add_command(world, "add_oob", WorldStateType.MAP_WIDTH - 1, 0, 3, 2)
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"zone_add extending past the map edge must be rejected invalid_target")
	var negative := _zone_add_command(world, "add_negative", -1, 0, 2, 2)
	_expect(not negative.get("ok", true) and negative["rejection"]["reason"] == "invalid_target",
		"zone_add with a negative origin must be rejected invalid_target")

func _check_zone_add_rejects_degenerate() -> void:
	if _failed:
		return
	var world := WorldStateType.new(3, 10)
	var zero_width := _zone_add_command(world, "add_zero_width", 5, 5, 0, 2)
	_expect(not zero_width.get("ok", true) and zero_width["rejection"]["reason"] == "invalid_target",
		"zone_add with zero width must be rejected invalid_target")
	var zero_height := _zone_add_command(world, "add_zero_height", 5, 5, 2, 0)
	_expect(not zero_height.get("ok", true) and zero_height["rejection"]["reason"] == "invalid_target",
		"zone_add with zero height must be rejected invalid_target")

func _check_zone_add_rejects_overlap() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4, 10)
	var first := _zone_add_command(world, "add_first", 10, 10, 4, 4)
	_expect(first.get("ok", false), "the first zone_add on empty ground must be accepted")
	var overlapping := _zone_add_command(world, "add_overlap", 12, 12, 4, 4)
	_expect(not overlapping.get("ok", true) and overlapping["rejection"]["reason"] == "invalid_target",
		"zone_add overlapping an existing zone must be rejected invalid_target")
	var touching := _zone_add_command(world, "add_touching", 14, 10, 4, 4)
	_expect(touching.get("ok", false), "a zone_add merely touching an existing zone's edge (no shared cell) must be accepted")

func _check_zone_add_rejects_invalid_payload() -> void:
	if _failed:
		return
	var world := WorldStateType.new(5, 10)
	var result: Dictionary = world.apply({
		"actor": "player", "command_id": "add_bad_payload", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 1, "y": 1, "width": 2},
	})
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"zone_add missing a required integer field must be rejected invalid_payload")

func _check_zone_remove_succeeds() -> void:
	if _failed:
		return
	var world := WorldStateType.new(6, 10)
	var add_result := _zone_add_command(world, "remove_setup", 5, 5, 2, 2)
	_expect(add_result.get("ok", false), "setup zone_add must succeed")
	var zone_id: String = add_result["zone_id"]
	var remove_result := _zone_remove_command(world, "remove_success", zone_id)
	_expect(remove_result.get("ok", false), "zone_remove on an existing zone must be accepted")
	_expect(world.get_zones().is_empty(), "get_zones() must be empty after removal")
	_expect(world.get_zone(zone_id).is_empty(), "get_zone(id) must return {} after removal")

func _check_zone_remove_rejects_unknown_id() -> void:
	if _failed:
		return
	var world := WorldStateType.new(7, 10)
	var result := _zone_remove_command(world, "remove_unknown", "zone_999")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"zone_remove for an unknown id must be rejected invalid_target")

func _check_zone_remove_rejects_invalid_payload() -> void:
	if _failed:
		return
	var world := WorldStateType.new(8, 10)
	var result: Dictionary = world.apply({
		"actor": "player", "command_id": "remove_bad_payload", "tick": world.get_tick(),
		"type": "zone_remove", "payload": {},
	})
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"zone_remove missing an id must be rejected invalid_payload")

## Proves is_cell_free() reads the same shared ReservationTable job reservations
## already use (jobs/reservation_table.gd), namespaced with a "cell:" key that
## never collides with JobQueue's own "tile:" target keys: both cells of a
## fresh 2-cell zone report free, then only the cell a synthetic reservation
## is acquired on (mimicking a future haul job's destination reservation)
## reports reserved -- its sibling cell stays free.
func _check_free_cell_query() -> void:
	if _failed:
		return
	var world := WorldStateType.new(9, 10)
	var add_result := _zone_add_command(world, "cell_query_setup", 20, 20, 2, 1)
	_expect(add_result.get("ok", false), "setup zone_add must succeed")
	_expect(world.is_cell_free(20, 20), "an unreserved zone cell must report free")
	_expect(world.is_cell_free(21, 20), "an unreserved zone cell must report free")

	var reservations := world._scheduler.queue.get_reservation_table()
	var acquired := reservations.acquire(world._cell_key(20, 20), "synthetic_job")
	_expect(acquired, "a synthetic reservation must be acquired on a free cell key")
	_expect(not world.is_cell_free(20, 20), "a reserved cell must no longer report free")
	_expect(world.is_cell_free(21, 20), "the sibling, unreserved cell must still report free")

	reservations.release(world._cell_key(20, 20), "synthetic_job")
	_expect(world.is_cell_free(20, 20), "a released cell must report free again")
