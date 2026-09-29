extends SceneTree

## Exercises WorldState's per-colonist labour table (colonist-ai.md 3.2): every
## freshly spawned colonist defaults every labour kind to 3, and the
## set_labour command validates and applies exactly like place_object/
## remove_object (world_state.gd's _apply_place_object_command()), mirroring
## test_place_object_command.gd's own test style.

const WorldStateType = preload("res://scripts/core/world_state.gd")

var _failed := false

func _init() -> void:
	_check_default_labour_table()
	_check_set_labour_valid()
	_check_set_labour_rejects_unknown_kind()
	_check_set_labour_rejects_level_out_of_range()
	_check_set_labour_rejects_unknown_colonist()
	_check_set_labour_mutates_only_target_colonist()
	_check_replay_determinism()

	if _failed:
		quit(1)
		return
	print("test_labour_table: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _default_table() -> Dictionary:
	return {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}

func _set_labour_command(world: WorldStateType, command_id: String, colonist: String, kind: String, level) -> Dictionary:
	return world.apply({
		"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": colonist, "kind": kind, "level": level},
	})

func _check_default_labour_table() -> void:
	if _failed:
		return
	var world := WorldStateType.new(1, 10)
	var colonists := world.get_colonists()
	_expect(colonists.size() > 0, "expected at least one spawned colonist")
	for colonist in colonists:
		_expect(colonist["labourTable"] == _default_table(),
			"colonist %s must spawn with every labour kind defaulted to 3" % colonist["id"])

func _check_set_labour_valid() -> void:
	if _failed:
		return
	var world := WorldStateType.new(2, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var result := _set_labour_command(world, "set_valid", colonist_id, "mine", 0)
	_expect(result.get("ok", false), "a valid set_labour must be accepted")
	var updated := world.get_colonists()[0]
	_expect(int(updated["labourTable"]["mine"]) == 0, "set_labour must update the targeted colonist's level")

func _check_set_labour_rejects_unknown_kind() -> void:
	if _failed:
		return
	var world := WorldStateType.new(3, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var before: Dictionary = (world.get_colonists()[0]["labourTable"] as Dictionary).duplicate()
	var result := _set_labour_command(world, "set_unknown_kind", colonist_id, "sing", 2)
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"set_labour with an unknown kind must be rejected invalid_payload")
	_expect(world.get_colonists()[0]["labourTable"] == before, "a rejected set_labour must change nothing")

func _check_set_labour_rejects_level_out_of_range() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var before: Dictionary = (world.get_colonists()[0]["labourTable"] as Dictionary).duplicate()
	var too_low := _set_labour_command(world, "set_too_low", colonist_id, "mine", -1)
	_expect(not too_low.get("ok", true) and too_low["rejection"]["reason"] == "invalid_payload",
		"set_labour with a level below 0 must be rejected invalid_payload")
	var too_high := _set_labour_command(world, "set_too_high", colonist_id, "mine", 5)
	_expect(not too_high.get("ok", true) and too_high["rejection"]["reason"] == "invalid_payload",
		"set_labour with a level above 4 must be rejected invalid_payload")
	_expect(world.get_colonists()[0]["labourTable"] == before, "a rejected set_labour must change nothing")

func _check_set_labour_rejects_unknown_colonist() -> void:
	if _failed:
		return
	var world := WorldStateType.new(5, 10)
	var result := _set_labour_command(world, "set_unknown_colonist", "colonist_999", "mine", 2)
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"set_labour for an unknown colonist id must be rejected invalid_target")

func _check_set_labour_mutates_only_target_colonist() -> void:
	if _failed:
		return
	var world := WorldStateType.new(6, 10)
	var colonists := world.get_colonists()
	_expect(colonists.size() >= 2, "expected at least two colonists for this check")
	if colonists.size() < 2:
		return
	var target_id: String = colonists[0]["id"]
	var other_id: String = colonists[1]["id"]
	var other_before: Dictionary = (colonists[1]["labourTable"] as Dictionary).duplicate()
	var result := _set_labour_command(world, "set_target_only", target_id, "cook", 1)
	_expect(result.get("ok", false), "a valid set_labour must be accepted")
	for colonist in world.get_colonists():
		if colonist["id"] == target_id:
			_expect(int(colonist["labourTable"]["cook"]) == 1, "the targeted colonist's level must change")
		elif colonist["id"] == other_id:
			_expect(colonist["labourTable"] == other_before, "a different colonist's labour table must be untouched")

## Two identically-seeded WorldStates replaying the same set_labour command
## sequence must produce equal apply() results and state_hash() values
## (colonist-ai.md 3.2's determinism requirement), mirroring
## test_world_state_determinism.gd's own _check_replay_determinism().
func _check_replay_determinism() -> void:
	if _failed:
		return
	var seed_value := 20260919
	var first := WorldStateType.new(seed_value, 10)
	var second := WorldStateType.new(seed_value, 10)
	var colonist_id: String = first.get_colonists()[0]["id"]

	var commands := [
		{"actor": "player", "command_id": "labour_1", "tick": 0, "type": "set_labour",
			"payload": {"colonist": colonist_id, "kind": "chop", "level": 1}},
		{"actor": "player", "command_id": "labour_2", "tick": 0, "type": "set_labour",
			"payload": {"colonist": colonist_id, "kind": "haul", "level": 0}},
	]
	for command in commands:
		var first_result := first.apply(command)
		var second_result := second.apply(command)
		_expect(first_result == second_result, "apply() results diverged for command %s" % command)
	first.tick()
	second.tick()

	_expect(first.state_hash() == second.state_hash(),
		"state_hash() diverged: %s vs %s" % [first.state_hash(), second.state_hash()])
