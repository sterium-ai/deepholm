extends SceneTree

## Exercises the till/sow job kinds (issue #268, colonist-ai.md 3.3/3.8): both
## are composed only of existing toils (reserve, go_to, work, release_all),
## matching dig/chop/forage's own shape, driven purely through world.tick()
## like every other job kind (AGENTS.md "one work engine"). till turns a soil
## tile into plowed_soil; sow turns a plowed_soil tile into planted and
## consumes one existing "seed" item anywhere in the world, rejected
## blocked_missing_input (colonist-ai.md 3.8) when none exists. Both use the
## "farm" labour kind, so t1's labour-priority scheduling and labour_disabled
## reason (test_labour_priority_scheduling.gd) apply unchanged.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const TICK_BUDGET := 400

var _failed := false

func _init() -> void:
	_check_till_completes_and_plows_tile()
	_check_sow_completes_consumes_seed_and_plants_tile()
	_check_sow_rejected_when_no_seed_anywhere()
	_check_sow_completion_fails_blocked_missing_input_when_seed_taken_first()
	_check_sow_counts_a_seed_mid_haul()
	_check_labour_priority_till_before_haul()
	_check_labour_priority_sow_before_haul()
	_check_farm_disabled_blocks_till_sow_not_others()
	_check_save_state_includes_new_tile_and_job_kinds()
	_check_save_state_passes_runtime_validator()
	_check_sow_consumes_carried_seed_while_haul_paused_for_need()
	_check_till_completion_fails_invalid_target_when_tile_changed_underneath()
	_check_sow_completion_fails_invalid_target_for_stale_duplicate_order()
	_check_sow_consumption_fails_queued_haul_with_no_free_destination()
	_check_replay_determinism()

	if _failed:
		quit(1)
		return
	print("test_farming_content: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _default_labour_table() -> Dictionary:
	return {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}

func _labour_table_with_two(kind_a: String, level_a: int, kind_b: String, level_b: int) -> Dictionary:
	var table := _default_labour_table()
	table[kind_a] = level_a
	table[kind_b] = level_b
	return table

## One colonist at (0,0) on an all-floor map. No "needs" key, so
## _ensure_needs() backfills an empty Dictionary and _decay_needs() has no
## keys to decay -- no need job can ever fire to interrupt a long-running
## till/sow scenario (mirrors test_labour_priority_scheduling.gd's own
## _single_colonist_world()).
func _single_colonist_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	return world

func _command(world: WorldStateType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

func _set_labour(world: WorldStateType, command_id: String, colonist: String, kind: String, level: int) -> Dictionary:
	return world.apply({"actor": "player", "command_id": command_id, "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": colonist, "kind": kind, "level": level}})

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if job["id"] == job_id:
			return job
	return {}

## till on a soil tile must complete purely through world.tick() (no direct
## tile mutation in the test) and leave the target tile plowed_soil.
func _check_till_completes_and_plows_tile() -> void:
	var world := _single_colonist_world(268001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	var result := _command(world, "till_1", "till", {"x": 1, "y": 0, "priority": 1})
	_expect(result.get("ok", false), "till submission on a soil tile must be accepted")

	var completed := false
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(1, 0) == WorldStateType.TILE_PLOWED_SOIL:
			completed = true
			break
	_expect(completed, "till job must complete and turn the target tile to plowed_soil within the tick budget")

## sow on a plowed_soil tile with one seed item in the world must complete,
## consume that seed item, and leave the target tile planted.
func _check_sow_completes_consumes_seed_and_plants_tile() -> void:
	var world := _single_colonist_world(268002)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._next_item_id = 2
	var result := _command(world, "sow_1", "sow", {"x": 1, "y": 0, "priority": 1})
	_expect(result.get("ok", false), "sow submission on a plowed_soil tile with a seed available must be accepted")

	var completed := false
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(1, 0) == WorldStateType.TILE_PLANTED:
			completed = true
			break
	_expect(completed, "sow job must complete and turn the target tile to planted within the tick budget")
	_expect(not world._items.has("item_seed_1"), "sow's on_work_complete effect must consume the seed item")

## sow targeting a plowed_soil tile with zero seed items anywhere must be
## rejected at submission (like dig/chop's own invalid_target rejection) with
## the reason blocked_missing_input (colonist-ai.md 3.8), changing no tile or
## item state.
func _check_sow_rejected_when_no_seed_anywhere() -> void:
	var world := _single_colonist_world(268003)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_PLOWED_SOIL
	var tile_before := world.get_tile(1, 0)
	var items_before := world.get_items()

	var result := _command(world, "sow_1", "sow", {"x": 1, "y": 0, "priority": 1})
	_expect(not result.get("ok", true), "sow with zero seed items anywhere must be rejected")
	_expect(String(result.get("rejection", {}).get("reason", "")) == "blocked_missing_input",
		"a sow order with no seed anywhere must be rejected blocked_missing_input, got %s" % result)
	_expect(world.get_tile(1, 0) == tile_before, "a rejected sow must not change tile state")
	_expect(world.get_items() == items_before, "a rejected sow must not change item state")

## Two colonists, equidistant from their own plowed_soil target, both submit a
## sow order while exactly one seed exists: both submissions are accepted
## (the seed exists at submission time for both), but only one may actually
## plant -- _toil_on_work_complete() must fail the loser blocked_missing_input
## rather than let it plant without ever consuming an input.
func _check_sow_completion_fails_blocked_missing_input_when_seed_taken_first() -> void:
	var world := WorldStateType.new(268006, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._tiles[world._tile_index(11, 10)] = WorldStateType.TILE_PLOWED_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_a", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world._colonists.append({"id": "colonist_b", "kind": "colonist", "x": 10, "y": 10,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._next_item_id = 2

	var sow_a := _command(world, "sow_a", "sow", {"x": 1, "y": 0, "priority": 1})
	_expect(sow_a.get("ok", false), "first sow submission must be accepted while a seed exists")
	var sow_b := _command(world, "sow_b", "sow", {"x": 11, "y": 10, "priority": 1})
	_expect(sow_b.get("ok", false), "second sow submission racing for the same single seed must also be accepted at submission time")

	var job_ids := [String(sow_a["job_id"]), String(sow_b["job_id"])]
	var completed_count := 0
	var failed_count := 0
	for _i in TICK_BUDGET:
		world.tick()
		completed_count = 0
		failed_count = 0
		for job_id in job_ids:
			match String(_find_job(world, job_id).get("status", "")):
				"completed": completed_count += 1
				"failed": failed_count += 1
		if completed_count + failed_count == 2:
			break

	_expect(completed_count == 1, "exactly one of two sow orders racing for a single seed must complete, got %d" % completed_count)
	_expect(failed_count == 1, "exactly one of two sow orders racing for a single seed must fail, got %d" % failed_count)
	for job_id in job_ids:
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "failed":
			_expect(String(job.get("reason", "")) == "blocked_missing_input",
				"the sow order that loses the race for the only seed must fail blocked_missing_input, got %s" % job)
	_expect(not world._items.has("item_seed_1"), "the single seed must be consumed exactly once, by the winner only")
	var planted_count := 0
	if world.get_tile(1, 0) == WorldStateType.TILE_PLANTED:
		planted_count += 1
	if world.get_tile(11, 10) == WorldStateType.TILE_PLANTED:
		planted_count += 1
	_expect(planted_count == 1, "exactly one target tile must become planted, got %d" % planted_count)

## sow's "a seed exists anywhere" precondition and its on_work_complete
## consumption must both see a seed currently mid-haul in a colonist's
## hands, not just one lying in _items -- pick_up moves an item out of
## _items into colonist["hands"] (toil_executor.gd), so checking _items
## alone would wrongly treat an in-transit seed as missing. Drives a real haul
## to pick up the only seed, submits and completes a sow order while it is
## still carried (the stockpile is placed far away so the haul's second leg
## cannot finish first), and checks the haul job that was carrying it fails
## blocked_missing_input instead of later placing an emptied stack.
func _check_sow_counts_a_seed_mid_haul() -> void:
	var world := WorldStateType.new(268007, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "hauler", "kind": "colonist", "x": 20, "y": 20,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world._colonists.append({"id": "farmer", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 21, "y": 20, "kind": "seed", "count": 1}
	world._next_item_id = 2
	_expect(_command(world, "zone_1", "zone_add", {"x": 47, "y": 47, "width": 1, "height": 1}).get("ok", false),
		"a stockpile zone far from the pickup must be accepted")

	var hauler_carrying := false
	for _i in TICK_BUDGET:
		world.tick()
		for colonist in world.get_colonists():
			if String(colonist["id"]) == "hauler" and InventoryType.is_carrying(colonist):
				hauler_carrying = true
		if hauler_carrying:
			break
	_expect(hauler_carrying, "setup: the hauler must pick up the only seed before this test submits sow")
	_expect(not world._items.has("item_seed_1"), "setup: the picked-up seed must have left the ground map")

	var sow_result := _command(world, "sow_1", "sow", {"x": 1, "y": 0, "priority": 1})
	_expect(sow_result.get("ok", false), "sow submission must be accepted while the only seed is mid-haul")

	var haul_job_id := ""
	for job in world.get_jobs():
		if String(job["kind"]) == "haul":
			haul_job_id = String(job["id"])
	_expect(not haul_job_id.is_empty(), "setup: a haul job must exist for the seed pickup")

	var sown := false
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(1, 0) == WorldStateType.TILE_PLANTED:
			sown = true
			break
		if String(_find_job(world, haul_job_id).get("status", "")) == "completed":
			break
	_expect(sown, "sow must complete and consume the carried seed before the far-off haul destination is ever reached")

	var haul_job := _find_job(world, haul_job_id)
	_expect(String(haul_job.get("status", "")) == "failed" and String(haul_job.get("reason", "")) == "blocked_missing_input",
		"the haul job carrying the now-consumed seed must fail blocked_missing_input, got %s" % haul_job)

## Two colonists both at (0,0) (removes travel distance as a factor, mirroring
## test_labour_priority_scheduling.gd's _check_labour_priority_ordering()):
## colonist A (farm=1, haul=4) prefers farm work, colonist B (farm=4, haul=1)
## prefers haul. Reused by both _check_labour_priority_till_before_haul() and
## _check_labour_priority_sow_before_haul() below so each farm kind is proven
## against haul independently, rather than accepting either for colonist A.
func _mixed_labour_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._calendar = CalendarServiceType.new("", {"day_length_ticks": 1000, "windows": []})
	world._colonists.clear()
	world._colonists.append({"id": "colonist_a", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _labour_table_with_two("farm", 1, "haul", 4)})
	world._colonists.append({"id": "colonist_b", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _labour_table_with_two("farm", 4, "haul", 1)})
	return world

func _job_kind_of(world: WorldStateType, job_id: String) -> String:
	return String(_find_job(world, job_id).get("kind", ""))

## Ticks world until both colonist_a and colonist_b have activated some job
## (or the budget runs out), returning {"a": <kind>, "b": <kind>} ("" if never
## activated).
func _first_activated_kinds(world: WorldStateType) -> Dictionary:
	var a_kind := ""
	var b_kind := ""
	for _i in 60:
		world.tick()
		var assignments := world.get_assignments()
		if a_kind.is_empty() and assignments.has("colonist_a"):
			a_kind = _job_kind_of(world, String(assignments["colonist_a"]["job_id"]))
		if b_kind.is_empty() and assignments.has("colonist_b"):
			b_kind = _job_kind_of(world, String(assignments["colonist_b"]["job_id"]))
		if not a_kind.is_empty() and not b_kind.is_empty():
			break
	return {"a": a_kind, "b": b_kind}

## A loose till job (plus two loose wood items with a stockpile zone, auto-
## submitting one "haul" labour job per colonist) proves colonist A activates
## its own till job before any haul job, while colonist B activates haul
## first, exercising t1's labour-priority formula (colonist-ai.md 3.2) for
## till specifically.
func _check_labour_priority_till_before_haul() -> void:
	var world := _mixed_labour_world(268004)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._items["item_wood_1"] = {"id": "item_wood_1", "x": 3, "y": 0, "kind": "wood", "count": 1}
	world._items["item_wood_2"] = {"id": "item_wood_2", "x": 4, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 3
	_expect(_command(world, "zone_1", "zone_add", {"x": 10, "y": 0, "width": 2, "height": 2}).get("ok", false),
		"zone_add must be accepted")
	_expect(_command(world, "till_1", "till", {"x": 1, "y": 0, "priority": 1}).get("ok", false),
		"till submission must be accepted")

	var kinds := _first_activated_kinds(world)
	_expect(String(kinds["a"]) == "till",
		"colonist A (farm=1, haul=4) must activate its own till job before any haul job, got '%s'" % kinds["a"])
	_expect(String(kinds["b"]) == "haul",
		"colonist B (farm=4, haul=1) must activate a haul job before the till job, got '%s'" % kinds["b"])

## Same shape as _check_labour_priority_till_before_haul() above, but with a
## loose sow job instead, so sow's own labour priority is proven independently
## rather than piggy-backing on till's result.
func _check_labour_priority_sow_before_haul() -> void:
	var world := _mixed_labour_world(268009)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._items["item_wood_1"] = {"id": "item_wood_1", "x": 3, "y": 0, "kind": "wood", "count": 1}
	world._items["item_wood_2"] = {"id": "item_wood_2", "x": 4, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 4
	_expect(_command(world, "zone_1", "zone_add", {"x": 10, "y": 0, "width": 2, "height": 2}).get("ok", false),
		"zone_add must be accepted")
	_expect(_command(world, "sow_1", "sow", {"x": 2, "y": 0, "priority": 1}).get("ok", false),
		"sow submission must be accepted")

	var kinds := _first_activated_kinds(world)
	_expect(String(kinds["a"]) == "sow",
		"colonist A (farm=1, haul=4) must activate its own sow job before any haul job, got '%s'" % kinds["a"])
	_expect(String(kinds["b"]) == "haul",
		"colonist B (farm=4, haul=1) must activate a haul job before the sow job, got '%s'" % kinds["b"])

## With "farm" set to 0 for the colony's only colonist, a queued till and a
## queued sow job must both report reason "labour_disabled" via get_jobs() and
## stay queued for as long as the colonist works other labour kinds -- proven
## here by driving the world until dig, chop, AND the auto-submitted haul job
## (three different labour kinds, none of them "farm") each actually reach
## "completed", re-checking till/sow's queued/labour_disabled status every
## tick along the way rather than once up front -- mirrors
## test_labour_priority_scheduling.gd's own _check_labour_disabled_reason().
## Issue #359: the dig target moved from (3,0) -- on both item_wood_1's own
## column (3,3) and, tried next, the straight-line path any haul delivery
## from further out takes back to the (10,0) zone -- to (9,9), well outside
## every other target/item/zone this scenario uses and never itself between
## any two of them: a haul job only ever needs to leave a dig's own trench,
## never re-enter it (route search still treats trench as ordinary passable
## terrain; only arrival traps -- a real interaction with this fixture's own
## geometry, not a routing regression).
func _check_farm_disabled_blocks_till_sow_not_others() -> void:
	var world := _single_colonist_world(268005)
	var colonist_id: String = world.get_colonists()[0]["id"]
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._tiles[world._tile_index(9, 9)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(0, 1)] = WorldStateType.TILE_TREE
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._items["item_wood_1"] = {"id": "item_wood_1", "x": 3, "y": 3, "kind": "wood", "count": 1}
	world._next_item_id = 2
	# dig/chop's needs_tool fetch_tool toil (issue #271) requires a matching
	# tool to exist somewhere; both sit right under the colonist so this
	# test's dig/chop completion checks are unaffected by travel time.
	world.spawn_ground_tool_item("pick", 0, 0)
	world.spawn_ground_tool_item("axe", 0, 0)
	_expect(_command(world, "zone_1", "zone_add", {"x": 10, "y": 0, "width": 2, "height": 2}).get("ok", false),
		"zone_add must be accepted")
	_expect(_set_labour(world, "off_farm", colonist_id, "farm", 0).get("ok", false),
		"set_labour farm=0 must be accepted")

	var till_result := _command(world, "till_1", "till", {"x": 1, "y": 0, "priority": 1})
	_expect(till_result.get("ok", false), "till submission must be accepted even though farm is disabled")
	var sow_result := _command(world, "sow_1", "sow", {"x": 2, "y": 0, "priority": 1})
	_expect(sow_result.get("ok", false), "sow submission must be accepted even though farm is disabled")
	var dig_result := _command(world, "dig_1", "dig", {"x": 9, "y": 9, "priority": 1})
	_expect(dig_result.get("ok", false), "dig submission must be accepted")
	var chop_result := _command(world, "chop_1", "chop", {"x": 0, "y": 1, "priority": 1})
	_expect(chop_result.get("ok", false), "chop submission must be accepted")

	var till_ever_wrong := false
	var sow_ever_wrong := false
	var dig_done := false
	var chop_done := false
	var haul_done := false
	for _i in TICK_BUDGET:
		world.tick()
		var till_job := _find_job(world, String(till_result["job_id"]))
		if not (String(till_job.get("status", "")) == "queued" and String(till_job.get("reason", "")) == "labour_disabled"):
			till_ever_wrong = true
		var sow_job := _find_job(world, String(sow_result["job_id"]))
		if not (String(sow_job.get("status", "")) == "queued" and String(sow_job.get("reason", "")) == "labour_disabled"):
			sow_ever_wrong = true
		if String(_find_job(world, String(dig_result["job_id"])).get("status", "")) == "completed":
			dig_done = true
		if String(_find_job(world, String(chop_result["job_id"])).get("status", "")) == "completed":
			chop_done = true
		for job in world.get_jobs():
			if String(job["kind"]) == "haul" and String(job.get("status", "")) == "completed":
				haul_done = true
		if dig_done and chop_done and haul_done:
			break

	_expect(not till_ever_wrong,
		"a till job must stay queued/labour_disabled for as long as the only colonist's farm is off")
	_expect(not sow_ever_wrong,
		"a sow job must stay queued/labour_disabled for as long as the only colonist's farm is off")
	_expect(dig_done, "dig work must proceed to completion while only farm is disabled")
	_expect(chop_done, "chop work must proceed to completion while only farm is disabled")
	_expect(haul_done, "haul work must proceed to completion while only farm is disabled")

## Save-state regression for the new content (issue #268 review round 1):
## docs/architecture/contracts/game-state.schema.json's map.tiles.items.enum
## and jobs.items.properties.kind.enum both now list plowed_soil/planted and
## till/sow. Drives a world to hold one plowed_soil tile (tilled, not sown)
## and one planted tile (tilled and sown), then checks to_save_state() -- what
## StateCodec actually serializes -- reports exactly those literal strings, at
## the same schemaVersion (till/sow add no persisted field or version bump).
func _check_save_state_includes_new_tile_and_job_kinds() -> void:
	var world := WorldStateType.new(268010, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._next_item_id = 2

	_expect(_command(world, "till_1", "till", {"x": 1, "y": 0, "priority": 1}).get("ok", false),
		"first till submission must be accepted")
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(1, 0) == WorldStateType.TILE_PLOWED_SOIL:
			break
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_PLOWED_SOIL, "setup: the first tile must be tilled")

	_expect(_command(world, "till_2", "till", {"x": 2, "y": 0, "priority": 1}).get("ok", false),
		"second till submission must be accepted")
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(2, 0) == WorldStateType.TILE_PLOWED_SOIL:
			break
	_expect(world.get_tile(2, 0) == WorldStateType.TILE_PLOWED_SOIL, "setup: the second tile must be tilled")

	_expect(_command(world, "sow_1", "sow", {"x": 2, "y": 0, "priority": 1}).get("ok", false),
		"sow submission must be accepted")
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(2, 0) == WorldStateType.TILE_PLANTED:
			break
	_expect(world.get_tile(2, 0) == WorldStateType.TILE_PLANTED, "setup: the second tile must be sown")

	var state := world.to_save_state()
	_expect(int(state.get("schemaVersion", -1)) == StateCodecType.SCHEMA_VERSION,
		"till/sow must add no schema/version bump, got %s" % state.get("schemaVersion"))
	var tiles: Array = state["map"]["tiles"]
	_expect(tiles.has("plowed_soil"), "save state's map.tiles must include the literal 'plowed_soil' the schema enum now declares")
	_expect(tiles.has("planted"), "save state's map.tiles must include the literal 'planted' the schema enum now declares")
	var kinds: Array = []
	for job in state["jobs"]:
		kinds.append(String((job as Dictionary)["kind"]))
	_expect(kinds.has("till"), "save state's jobs must include the literal 'till' kind the schema enum now declares")
	_expect(kinds.has("sow"), "save state's jobs must include the literal 'sow' kind the schema enum now declares")

## Review round 2 finding: a save state holding the new content must also
## pass SaveIO's own runtime schema validator (save_io.gd's
## _validate_state()), not just the JSON contract schema the check above
## already proves against docs/architecture/contracts/game-state.schema.json.
## Reuses the same tilled/sown setup as
## _check_save_state_includes_new_tile_and_job_kinds() above.
func _check_save_state_passes_runtime_validator() -> void:
	var world := WorldStateType.new(268011, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._next_item_id = 2

	_expect(_command(world, "till_1", "till", {"x": 1, "y": 0, "priority": 1}).get("ok", false),
		"till submission must be accepted")
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(1, 0) == WorldStateType.TILE_PLOWED_SOIL:
			break
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_PLOWED_SOIL, "setup: the tile must be tilled")

	_expect(_command(world, "sow_1", "sow", {"x": 1, "y": 0, "priority": 1}).get("ok", false),
		"sow submission must be accepted")
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(1, 0) == WorldStateType.TILE_PLANTED:
			break
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_PLANTED, "setup: the tile must be sown")

	var state := world.to_save_state()
	var validation := SaveIOType._validate_state(state)
	_expect(validation.get("ok", false),
		"a save state holding plowed_soil/planted tiles and till/sow jobs must pass SaveIO._validate_state(), got %s" % validation.get("message", ""))

## Review round 2 finding: consuming the last carried seed while its haul is
## paused for a critical-need interrupt must still fail that haul
## blocked_missing_input and clear its _paused_jobs entry, the same as when
## the haul is merely mid-flight (_check_sow_counts_a_seed_mid_haul() above).
## Mirrors test_haul_need_interrupt.gd's own boundary-interrupt setup
## (colonist.carrying set, colonist.route/work both null for exactly one
## tick): once the food need commits, the haul job is suspended into
## _paused_jobs rather than staying the colonist's active scheduler
## assignment, which is exactly the case
## _cancel_haul_job_carrying_consumed_item() must also cover.
func _check_sow_consumes_carried_seed_while_haul_paused_for_need() -> void:
	var world := WorldStateType.new(268012, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(41, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "hauler", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "hands": [], "labourTable": _default_labour_table()})
	world._colonists.append({"id": "farmer", "kind": "colonist", "x": 40, "y": 0,
		"route": null, "work": null, "hands": [], "labourTable": _default_labour_table()})
	for kind in world._need_definitions.keys():
		if kind != "food":
			world._need_definitions[kind]["rate_per_day"] = 0
	world._ground_berries["1_1"] = 1
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 0, "kind": "seed", "count": 1}
	world._next_item_id = 2
	_expect(_command(world, "zone_1", "zone_add", {"x": 10, "y": 0, "width": 1, "height": 1}).get("ok", false),
		"a stockpile zone for the seed haul must be accepted")

	var boundary_reached := false
	var haul_job_id := ""
	for _i in 40:
		world.tick()
		if haul_job_id.is_empty():
			for job in world.get_jobs():
				if String(job["kind"]) == "haul":
					haul_job_id = String(job["id"])
		for colonist in world.get_colonists():
			if String(colonist["id"]) == "hauler" and InventoryType.is_carrying(colonist) \
					and colonist.get("route") == null and colonist.get("work") == null:
				boundary_reached = true
		if boundary_reached:
			break
	_expect(boundary_reached, "setup: the hauler must reach the post-pick_up toil boundary carrying the only seed within budget")
	_expect(not haul_job_id.is_empty(), "setup: a haul job must exist for the seed pickup")

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "hauler":
			world._colonists[i]["needs"]["food"] = 5

	var interrupted := false
	for _i in 60:
		world.tick()
		if String(_find_job(world, haul_job_id).get("status", "")) == "queued":
			interrupted = true
			break
	_expect(interrupted, "setup: the food need must interrupt the haul job while it carries the only seed")

	var hauler_colonist := {}
	for colonist in world.get_colonists():
		if String(colonist["id"]) == "hauler":
			hauler_colonist = colonist
	_expect(InventoryType.has_kind(hauler_colonist, "seed"),
		"setup: the hauler must still be carrying the seed the instant the need job interrupts it")
	_expect(world._paused_jobs.get("hauler", "") == haul_job_id,
		"setup: the interrupted haul must be recorded in _paused_jobs, not the colonist's current assignment")

	var sow_result := _command(world, "sow_1", "sow", {"x": 41, "y": 0, "priority": 1})
	_expect(sow_result.get("ok", false), "sow submission must be accepted while the only seed is carried by an interrupted haul")

	var sown := false
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(41, 0) == WorldStateType.TILE_PLANTED:
			sown = true
			break
	_expect(sown, "sow must complete and consume the interrupted haul's carried seed within the tick budget")

	var haul_job := _find_job(world, haul_job_id)
	_expect(String(haul_job.get("status", "")) == "failed" and String(haul_job.get("reason", "")) == "blocked_missing_input",
		"the haul job paused for a need, carrying the now-consumed seed, must fail blocked_missing_input, got %s" % haul_job)
	_expect(not world._paused_jobs.has("hauler"),
		"the cancelled haul's _paused_jobs entry must be cleared so the hauler is never resumed toward a delivery that no longer exists")

	var eat_completed := false
	for _i in TICK_BUDGET:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "eat_food" and String(job.get("status", "")) == "completed":
				eat_completed = true
		if eat_completed:
			break
	_expect(eat_completed, "the need job that interrupted the haul must still be free to complete, unaffected by the haul's cancellation")

## Review round 4 finding: the reservation table only guarantees no other
## order-driven job was ACTIVE on a till job's target tile at the same time,
## not that the tile still matches by completion time (e.g. a need interrupt
## can release a paused till job's own reservation, letting a second order on
## the same tile activate and complete first). Simulates that by mutating the
## tile directly once this job is confirmed active, then checks
## _toil_on_work_complete()'s own revalidation fails it invalid_target instead
## of overwriting the tile changed by whatever else set it.
func _check_till_completion_fails_invalid_target_when_tile_changed_underneath() -> void:
	var world := _single_colonist_world(268013)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	var result := _command(world, "till_1", "till", {"x": 1, "y": 0, "priority": 1})
	_expect(result.get("ok", false), "till submission on a soil tile must be accepted")
	var job_id := String(result["job_id"])

	var became_active := false
	for _i in TICK_BUDGET:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "active":
			became_active = true
			break
	_expect(became_active, "setup: the till job must become active before this test changes its target underneath it")

	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_FLOOR

	var terminal := false
	for _i in TICK_BUDGET:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) in ["completed", "failed"]:
			terminal = true
			break
	_expect(terminal, "the stale till job must reach a terminal state within the tick budget")
	var job := _find_job(world, job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "invalid_target",
		"a till job whose target tile changed underneath it must fail invalid_target, got %s" % job)
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_FLOOR,
		"a stale till job's completion must not overwrite the tile changed by another job")

## Review round 4 finding: two sow orders queued for the SAME plowed_soil
## tile, with two seeds available (so the seed itself is never the limiting
## factor), can both be accepted -- only one may be active at once, but the
## second activates right after the first completes and plants the tile.
## _toil_on_work_complete() must revalidate the tile is still plowed_soil
## before consuming the second seed, failing invalid_target instead of
## re-planting an already-planted tile for a wasted second seed.
func _check_sow_completion_fails_invalid_target_for_stale_duplicate_order() -> void:
	var world := _single_colonist_world(268014)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._items["item_seed_2"] = {"id": "item_seed_2", "x": 6, "y": 5, "kind": "seed", "count": 1}
	world._next_item_id = 3

	var sow_1 := _command(world, "sow_1", "sow", {"x": 1, "y": 0, "priority": 1})
	_expect(sow_1.get("ok", false), "first sow submission on a plowed_soil tile with seeds available must be accepted")
	var sow_2 := _command(world, "sow_2", "sow", {"x": 1, "y": 0, "priority": 1})
	_expect(sow_2.get("ok", false), "second sow submission for the same tile, with a second seed still available, must also be accepted")

	var job_ids := [String(sow_1["job_id"]), String(sow_2["job_id"])]
	var completed_count := 0
	var failed_count := 0
	for _i in TICK_BUDGET:
		world.tick()
		completed_count = 0
		failed_count = 0
		for job_id in job_ids:
			match String(_find_job(world, job_id).get("status", "")):
				"completed": completed_count += 1
				"failed": failed_count += 1
		if completed_count + failed_count == 2:
			break

	_expect(completed_count == 1, "exactly one of two sow orders queued for the same tile must complete, got %d" % completed_count)
	_expect(failed_count == 1, "exactly one of two sow orders queued for the same tile must fail, got %d" % failed_count)
	for job_id in job_ids:
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "failed":
			_expect(String(job.get("reason", "")) == "invalid_target",
				"the second sow order to reach an already-planted tile must fail invalid_target (a second seed exists, so it is not blocked_missing_input), got %s" % job)
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_PLANTED, "the tile must end up planted exactly once")
	var remaining_seeds := 0
	for item in world._items.values():
		if String(item["kind"]) == "seed":
			remaining_seeds += int(item.get("count", 1))
	_expect(remaining_seeds == 1, "only one of the two available seeds may be consumed; the stale second sow must not consume the other, got %d" % remaining_seeds)

## Review round 4 finding: HaulGiver attaches a loose seed to a haul job the
## moment it appears, even with no stockpile zone to receive it -- that haul
## job then sits queued forever under blocked_destination_full, never picking
## the seed up. An ordinary sow consuming that same ground seed must still
## fail the dangling haul blocked_missing_input rather than leave it retrying
## for an item that no longer exists.
func _check_sow_consumption_fails_queued_haul_with_no_free_destination() -> void:
	var world := _single_colonist_world(268015)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._next_item_id = 2

	var haul_job_id := ""
	for _i in TICK_BUDGET:
		world.tick()
		if haul_job_id.is_empty():
			for job in world.get_jobs():
				if String(job["kind"]) == "haul":
					haul_job_id = String(job["id"])
		if not haul_job_id.is_empty():
			var haul_job := _find_job(world, haul_job_id)
			if String(haul_job.get("status", "")) == "queued" and String(haul_job.get("reason", "")) == "blocked_destination_full":
				break
	_expect(not haul_job_id.is_empty(), "setup: a haul job must exist for the loose seed")
	var haul_before := _find_job(world, haul_job_id)
	_expect(String(haul_before.get("status", "")) == "queued" and String(haul_before.get("reason", "")) == "blocked_destination_full",
		"setup: the haul job must be queued, backed off with no free destination, before this test submits sow, got %s" % haul_before)

	var sow_result := _command(world, "sow_1", "sow", {"x": 1, "y": 0, "priority": 1})
	_expect(sow_result.get("ok", false), "sow submission must be accepted while the seed still sits on the ground")

	var sown := false
	for _i in TICK_BUDGET:
		world.tick()
		if world.get_tile(1, 0) == WorldStateType.TILE_PLANTED:
			sown = true
			break
	_expect(sown, "sow must complete and consume the ground seed within the tick budget")

	var haul_job := _find_job(world, haul_job_id)
	_expect(String(haul_job.get("status", "")) == "failed" and String(haul_job.get("reason", "")) == "blocked_missing_input",
		"the haul job queued for the now-consumed ground seed must fail blocked_missing_input instead of retrying forever, got %s" % haul_job)

## One colonist on an all-floor map with a soil tile at (1,0) (till target),
## reused by _check_replay_determinism().
func _deterministic_farm_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": _default_labour_table()})
	return world

## Two identically-seeded WorldStates replaying the same set_labour + till +
## sow command sequence must produce equal apply() results and equal
## state_hash() values (colonist-ai.md 3.2's determinism requirement),
## mirroring test_labour_table.gd's own _check_replay_determinism().
func _check_replay_determinism() -> void:
	var seed_value := 20260919268
	var first := _deterministic_farm_world(seed_value)
	var second := _deterministic_farm_world(seed_value)
	var colonist_id: String = first.get_colonists()[0]["id"]
	for world in [first, second]:
		world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
		world._next_item_id = 2

	var setup_commands := [
		{"actor": "player", "command_id": "labour_1", "tick": 0, "type": "set_labour",
			"payload": {"colonist": colonist_id, "kind": "farm", "level": 1}},
		{"actor": "test", "command_id": "till_1", "tick": 0, "type": "till",
			"payload": {"x": 1, "y": 0, "priority": 1}},
	]
	for command in setup_commands:
		var first_result := first.apply(command)
		var second_result := second.apply(command)
		_expect(first_result == second_result, "apply() results diverged for command %s" % command)

	for _i in 60:
		first.tick()
		second.tick()
	_expect(first.get_tile(1, 0) == WorldStateType.TILE_PLOWED_SOIL,
		"setup: the till job must complete before this test submits its sow order")

	var sow_command := {"actor": "test", "command_id": "sow_1", "tick": first.get_tick(), "type": "sow",
		"payload": {"x": 1, "y": 0, "priority": 1}}
	var first_sow := first.apply(sow_command)
	var second_sow := second.apply(sow_command)
	_expect(first_sow == second_sow, "apply() results diverged for command %s" % sow_command)

	for _i in 60:
		first.tick()
		second.tick()

	_expect(first.state_hash() == second.state_hash(),
		"state_hash() diverged: %s vs %s" % [first.state_hash(), second.state_hash()])
