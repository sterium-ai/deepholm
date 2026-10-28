extends "res://scripts/tests/support/tool_items_base.gd"

## test_tool_items checks; shared helpers and the file's full description are in support/tool_items_base.gd.

func _init() -> void:
	_check_items_content_declares_axe_and_pick()
	_check_jobs_content_declares_needs_tool()
	_check_fresh_colonist_held_tool_empty()
	_check_ground_tool_item_and_state_hash()
	_check_held_and_stockpile_locations()
	_check_held_tool_conflict_is_rejected()
	_check_spawn_ground_tool_item_rejects_non_tool_kind()

	if _failed:
		quit(1)
		return
	print("test_tool_items: PASS")
	quit(0)

## game/content/items.json must declare an 'axe' and a 'pick' entry, both
## kind 'tool'.
func _check_items_content_declares_axe_and_pick() -> void:
	var file := FileAccess.open(ITEMS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_expect(false, "could not open %s" % ITEMS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("items")) != TYPE_ARRAY:
		_expect(false, "%s must contain a top-level 'items' array" % ITEMS_CONTENT_PATH)
		return
	var by_id: Dictionary = {}
	for entry in parsed["items"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("id")) == TYPE_STRING:
			by_id[entry["id"]] = entry
	_expect(by_id.get("axe", {}).get("kind") == "tool", "items.json must declare 'axe' with kind 'tool'")
	_expect(by_id.get("pick", {}).get("kind") == "tool", "items.json must declare 'pick' with kind 'tool'")

## game/content/jobs.json's 'dig' entry must declare needs_tool 'pick' and
## 'chop' must declare needs_tool 'axe'.
func _check_jobs_content_declares_needs_tool() -> void:
	var file := FileAccess.open(JOBS_CONTENT_PATH, FileAccess.READ)
	if file == null:
		_expect(false, "could not open %s" % JOBS_CONTENT_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("jobs")) != TYPE_ARRAY:
		_expect(false, "%s must contain a top-level 'jobs' array" % JOBS_CONTENT_PATH)
		return
	var by_kind: Dictionary = {}
	for entry in parsed["jobs"]:
		if typeof(entry) == TYPE_DICTIONARY and typeof(entry.get("kind")) == TYPE_STRING:
			by_kind[entry["kind"]] = entry
	_expect(by_kind.get("dig", {}).get("needs_tool") == "pick", "jobs.json's dig must declare needs_tool 'pick'")
	_expect(by_kind.get("chop", {}).get("needs_tool") == "axe", "jobs.json's chop must declare needs_tool 'axe'")

## A freshly spawned colonist's held_tool must be "" (empty).
func _check_fresh_colonist_held_tool_empty() -> void:
	var world := WorldStateType.new(20260919)
	var colonists := world.get_colonists()
	_expect(colonists.size() > 0, "a fresh world must spawn at least one colonist")
	for colonist in colonists:
		_expect(String(colonist.get("held_tool", "MISSING")) == "",
			"a freshly spawned colonist's held_tool must be empty, got '%s'" % colonist.get("held_tool"))

## Adding a ground tool item and reserving it by job id must change
## state_hash().
func _check_ground_tool_item_and_state_hash() -> void:
	var world := WorldStateType.new(20260919)
	var hash_before_spawn := world.state_hash()
	var item_id := world.spawn_ground_tool_item("axe", 5, 5)
	_expect(item_id != "", "spawn_ground_tool_item must return a non-empty id")
	_expect(world.state_hash() != hash_before_spawn, "spawning a ground tool item must change state_hash()")

	var item := world.get_tool_item(item_id)
	_expect(item.get("kind") == "axe", "spawned tool item must record kind 'axe'")
	_expect(item.get("location", {}).get("type") == "ground", "a freshly spawned tool item must be on the ground")
	_expect(item.get("location", {}).get("x") == 5 and item.get("location", {}).get("y") == 5,
		"a freshly spawned tool item's location must match spawn coordinates")

	var hash_before_reserve := world.state_hash()
	_expect(world.reserve_tool_item(item_id, "job_1"), "reserving a free tool item must succeed")
	_expect(world.state_hash() != hash_before_reserve, "reserving a tool item must change state_hash()")
	_expect(not world.reserve_tool_item(item_id, "job_2"),
		"reserving a tool item already held by another job must fail")
	_expect(world.get_tool_item_reservation(item_id) == "job_1", "item must still be reserved by job_1")

## Moving a tool item into a colonist's hand must set that colonist's
## held_tool and clear it again on drop; a stockpile cell is just another
## location a tool can rest at (no reservation of the cell itself).
func _check_held_and_stockpile_locations() -> void:
	var world := WorldStateType.new(20260919)
	var item_id := world.spawn_ground_tool_item("axe", 3, 3)
	var colonist_id := String(world.get_colonists()[0]["id"])

	_expect(world.set_tool_item_held(item_id, colonist_id), "moving a tool item to a colonist's hand must succeed")
	var held_colonist := Scenarios.colonist_by_id(world, colonist_id)
	_expect(String(held_colonist.get("held_tool")) == item_id, "colonist.held_tool must record the held item id")
	_expect(world.get_tool_item(item_id)["location"]["type"] == "held", "item location must be 'held'")

	_expect(world.set_tool_item_stockpile(item_id, 9, 9), "moving a held tool item to a stockpile cell must succeed")
	held_colonist = Scenarios.colonist_by_id(world, colonist_id)
	_expect(String(held_colonist.get("held_tool")) == "", "dropping a held tool must clear the former holder's held_tool")
	var location: Dictionary = world.get_tool_item(item_id)["location"]
	_expect(location["type"] == "stockpile" and location["x"] == 9 and location["y"] == 9,
		"item must now rest on the stockpile cell (9, 9)")

	_expect(world.set_tool_item_ground(item_id, 4, 4), "moving a stockpiled tool item to the ground must succeed")
	location = world.get_tool_item(item_id)["location"]
	_expect(location["type"] == "ground" and location["x"] == 4 and location["y"] == 4,
		"item must now rest on the ground at (4, 4)")

## A colonist already holding one item must not be handed a second: doing so
## would silently overwrite held_tool while the first item's own location dict
## still claims it is held by this colonist. Both conflict cases: a different
## colonist already holding another item, and re-handing the colonist its own
## already-held item (a no-op success, not a conflict).
func _check_held_tool_conflict_is_rejected() -> void:
	var world := WorldStateType.new(20260919)
	var colonist_id := String(world.get_colonists()[0]["id"])
	var first_item := world.spawn_ground_tool_item("axe", 1, 1)
	var second_item := world.spawn_ground_tool_item("pick", 2, 2)
	_expect(world.set_tool_item_held(first_item, colonist_id), "holding the first item must succeed")

	_expect(not world.set_tool_item_held(second_item, colonist_id),
		"handing a colonist a second item while it still holds the first must be rejected")
	var colonist := Scenarios.colonist_by_id(world, colonist_id)
	_expect(String(colonist.get("held_tool")) == first_item,
		"a rejected handoff must leave the colonist's original held_tool unchanged")
	_expect(world.get_tool_item(second_item)["location"]["type"] == "ground",
		"a rejected handoff must leave the second item where it was")

	_expect(world.set_tool_item_held(first_item, colonist_id),
		"re-handing a colonist the item it already holds must succeed (no-op)")
	colonist = Scenarios.colonist_by_id(world, colonist_id)
	_expect(String(colonist.get("held_tool")) == first_item, "held_tool must still name the same item")

## spawn_ground_tool_item() must refuse any kind that is not a declared tool
## kind (is_tool_kind()), instead of silently storing an arbitrary string.
func _check_spawn_ground_tool_item_rejects_non_tool_kind() -> void:
	var world := WorldStateType.new(20260919)
	var before := world.get_tool_items().size()
	_expect(world.spawn_ground_tool_item("wood", 1, 1) == "", "spawning a non-tool kind ('wood') must be rejected")
	_expect(world.spawn_ground_tool_item("not_a_real_kind", 1, 1) == "", "spawning an unknown kind must be rejected")
	_expect(world.get_tool_items().size() == before, "a rejected spawn must not allocate a tool item id")
