extends SceneTree

## Exercises WorldState's set_faction debug command, mirroring
## test_labour_table.gd's test style for _apply_set_labour_command, the
## shape/validation pattern set_faction follows exactly. Also covers the
## faction_id default ("colony") on a chopped/foraged item -- world_state.gd's
## _spawn_wood_item()/_spawn_berries_item(), called directly the same way
## test_object_storage.gd calls _set_object() directly, since the toil
## pipeline that reaches them is already exercised elsewhere.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

var _failed := false

func _init() -> void:
	_check_set_faction_valid()
	_check_set_faction_rejects_missing_target()
	_check_set_faction_rejects_empty_target()
	_check_set_faction_rejects_non_string_faction_id()
	_check_set_faction_rejects_unknown_target()
	_check_set_faction_rejects_unknown_faction()
	_check_set_faction_mutates_only_target_actor()
	_check_set_faction_persists_for_non_worker_actor()
	_check_chopped_item_faction_is_colony()
	_check_foraged_berries_faction_is_colony()

	if _failed:
		quit(1)
		return
	print("test_set_faction_command: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _set_faction_command(world: WorldStateType, command_id: String, target, faction_id) -> Dictionary:
	return world.apply({
		"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "set_faction", "payload": {"target": target, "faction_id": faction_id},
	})

func _check_set_faction_valid() -> void:
	if _failed:
		return
	var world := WorldStateType.new(1, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var result := _set_faction_command(world, "set_valid", colonist_id, "wildlife")
	_expect(result.get("ok", false), "a valid set_faction must be accepted")
	var updated := world._find_colonist(colonist_id)
	_expect(updated["factionId"] == "wildlife", "set_faction must update the targeted actor's factionId")

func _check_set_faction_rejects_missing_target() -> void:
	if _failed:
		return
	var world := WorldStateType.new(2, 10)
	var result := world.apply({
		"actor": "player", "command_id": "set_missing_target", "tick": world.get_tick(),
		"type": "set_faction", "payload": {"faction_id": "wildlife"},
	})
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"set_faction with a missing target must be rejected invalid_payload")

func _check_set_faction_rejects_empty_target() -> void:
	if _failed:
		return
	var world := WorldStateType.new(3, 10)
	var result := _set_faction_command(world, "set_empty_target", "", "wildlife")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"set_faction with an empty target must be rejected invalid_payload")

func _check_set_faction_rejects_non_string_faction_id() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4, 10)
	var colonist_id: String = world.get_colonists()[0]["id"]
	var result := _set_faction_command(world, "set_non_string_faction", colonist_id, 5)
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"set_faction with a non-string faction_id must be rejected invalid_payload")

func _check_set_faction_rejects_unknown_target() -> void:
	if _failed:
		return
	var world := WorldStateType.new(5, 10)
	var result := _set_faction_command(world, "set_unknown_target", "colonist_999", "wildlife")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_target",
		"set_faction for an unknown target actor must be rejected invalid_target")

func _check_set_faction_rejects_unknown_faction() -> void:
	if _failed:
		return
	var world := WorldStateType.new(6, 10)
	world.state_hash() # forces _ensure_health()'s factionId backfill
	var colonist_id: String = world.get_colonists()[0]["id"]
	var before: String = world._find_colonist(colonist_id)["factionId"]
	var result := _set_faction_command(world, "set_unknown_faction", colonist_id, "spaceship_crew")
	_expect(not result.get("ok", true) and result["rejection"]["reason"] == "invalid_payload",
		"set_faction with a faction_id absent from the factions registry must be rejected invalid_payload")
	_expect(world._find_colonist(colonist_id)["factionId"] == before, "a rejected set_faction must change nothing")

func _check_set_faction_mutates_only_target_actor() -> void:
	if _failed:
		return
	var world := WorldStateType.new(7, 10)
	world.state_hash() # forces _ensure_health()'s factionId backfill
	var colonists := world.get_colonists()
	_expect(colonists.size() >= 2, "expected at least two colonists for this check")
	if colonists.size() < 2:
		return
	var target_id: String = colonists[0]["id"]
	var other_id: String = colonists[1]["id"]
	var other_before: String = colonists[1]["factionId"]
	var result := _set_faction_command(world, "set_target_only", target_id, "allies")
	_expect(result.get("ok", false), "a valid set_faction must be accepted")
	_expect(world._find_colonist(target_id)["factionId"] == "allies", "the targeted actor's factionId must change")
	_expect(world._find_colonist(other_id)["factionId"] == other_before, "a different actor's factionId must be untouched")

## Regression: a non-worker actor (no "worker"
## component, e.g. a wolf) fails _ensure_needs()'s labour_table_missing check
## on every call, forcing its colonist dict through a key-by-key rebuild. That
## rebuild used to omit "factionId" entirely, so _ensure_health() (which only
## backfills a truly *absent* key) would silently re-stamp "colony" the next
## time state_hash()/to_save_state()/tick() ran. Covers all three call sites.
func _check_set_faction_persists_for_non_worker_actor() -> void:
	if _failed:
		return
	var world := WorldStateType.new(10, 10)
	var wolf := ActorTableType.spawn("wolf", 2, 2, world._content, "wolf_test")
	world._colonists.append(wolf)
	var result := _set_faction_command(world, "set_wolf_faction", "wolf_test", "wildlife")
	_expect(result.get("ok", false), "a valid set_faction on a non-worker actor must be accepted")
	_expect(world._find_colonist("wolf_test")["factionId"] == "wildlife",
		"set_faction must update a non-worker actor's factionId")

	world.state_hash()
	_expect(world._find_colonist("wolf_test")["factionId"] == "wildlife",
		"state_hash() must not reset a non-worker actor's factionId")

	var saved := world.to_save_state()
	var wolf_entity := {}
	for entity in saved["entities"]:
		if entity["id"] == "wolf_test":
			wolf_entity = entity
	_expect(wolf_entity.get("factionId") == "wildlife",
		"to_save_state() must not reset a non-worker actor's factionId")

	world.tick()
	_expect(world._find_colonist("wolf_test")["factionId"] == "wildlife",
		"tick() must not reset a non-worker actor's factionId")

## _spawn_wood_item() is chop's on_work_complete effect (world_state.gd); the
## toil pipeline that reaches it is exercised by test_toils_dig_chop_regression.gd.
func _check_chopped_item_faction_is_colony() -> void:
	if _failed:
		return
	var world := WorldStateType.new(8, 10)
	world._spawn_wood_item(5, 5)
	var items := world.get_items()
	_expect(items.size() == 1 and items[0]["faction_id"] == "colony",
		"a chopped wood item must default to faction_id 'colony'")

## _spawn_berries_item() is forage's on_work_complete effect (world_state.gd);
## ground berries are a per-tile counter (ADR 006), not a first-class item,
## so their faction_id is read through get_ground_berries_faction_id().
func _check_foraged_berries_faction_is_colony() -> void:
	if _failed:
		return
	var world := WorldStateType.new(9, 10)
	world._spawn_berries_item(6, 6)
	_expect(world.get_ground_berries_faction_id(6, 6) == "colony",
		"foraged berries must default to faction_id 'colony'")
