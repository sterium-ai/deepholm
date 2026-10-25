extends SceneTree

## ADR 044 / B1: an area_order expands through a saved per-tick queue.
## 1) A whole-map dig order, expanded over ticks while the colony works, yields
##    the same dig jobs -- count, targets, order -- as the former release path
##    (one dig command per tile, row-major, all at once).
## 2) A save taken mid-expansion reloads and completes identically: the same
##    state_hash() along the way and at the end, and the same final jobs, as
##    the run never saved.
## 3) Release expands only AreaOrders.TILES_PER_STEP tiles, then the same many
##    per tick; a rectangle within one step completes at release with the
##    same rejections the per-tile path reports.
## 4) Invalid payloads are rejected (apply and preview alike), mutating nothing.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SAVE_PATH := "user://test-area-orders-mid-expansion.json"
const SEED := 42
const SIZE := 128

var _failures: Array[String] = []
var _n := 0

func _init() -> void:
	_check_whole_map_matches_per_tile_path()
	_check_save_mid_expansion()
	_check_step_budget_and_small_rectangles()
	_check_invalid_payloads()
	if not _failures.is_empty():
		for failure in _failures:
			push_error(failure)
		quit(1)
		return
	print("test_area_orders: PASS")
	quit(0)

func _check_whole_map_matches_per_tile_path() -> void:
	var reference = WorldStateType.new(SEED, 10, SIZE, SIZE)
	for y in SIZE:
		for x in SIZE:
			_apply(reference, "dig", {"x": x, "y": y, "priority": 1})
	var expected := _dig_targets(reference)
	_expect(expected.size() > SIZE * SIZE / 3, "sanity: the reference map must offer plenty of dig targets, got %d" % expected.size())
	var world = WorldStateType.new(SEED, 10, SIZE, SIZE)
	var result := _area(world, "dig", Rect2i(0, 0, SIZE, SIZE))
	_expect(result.get("ok", false), "a whole-map area_order must be accepted: %s" % result)
	_expect(int(result.get("remaining", -1)) == SIZE * SIZE - AreaOrders.TILES_PER_STEP,
		"release must expand exactly TILES_PER_STEP tiles, remaining %s" % result.get("remaining"))
	var ticks := 0
	while world._area_orders.remaining_tiles(int(result["area_order_id"])) > 0 and ticks < 1000:
		world.tick()
		ticks += 1
	_expect(ticks == ceili(float(SIZE * SIZE) / AreaOrders.TILES_PER_STEP) - 1,
		"the rest must expand TILES_PER_STEP per tick, took %d ticks" % ticks)
	_expect(_dig_targets(world) == expected, "the expanded dig jobs must match the per-tile path: count, targets and order")

func _check_save_mid_expansion() -> void:
	var straight = WorldStateType.new(SEED, 10, SIZE, SIZE)
	_area(straight, "dig", Rect2i(0, 0, SIZE, SIZE))
	_area(straight, "chop", Rect2i(0, 0, SIZE, SIZE / 2))
	for t in 20:
		straight.tick()
	var saved: Dictionary = straight.to_save_state()
	_expect(not (saved["areaOrders"]["list"] as Array).is_empty(), "the save must be taken mid-expansion")
	# Through the real save file path (validation, integrity, integer
	# normalisation), like a player's save.
	var written := SaveIOType.write_atomic(SAVE_PATH, saved)
	_expect(written.get("ok", false), "a mid-expansion save must be writable: %s" % written)
	var read := SaveIOType.read(SAVE_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_expect(read.get("ok", false), "a mid-expansion save must load: %s" % read.get("message", ""))
	if not read.get("ok", false):
		return
	var restored = WorldStateType.from_save_state(read["state"])
	_expect(restored.state_hash() == straight.state_hash(), "a mid-expansion save must restore the same state_hash()")
	var t := 0
	while not (straight._area_orders.encode()["list"] as Array).is_empty() and t < 1000:
		straight.tick()
		restored.tick()
		t += 1
		# state_hash() serialises the whole world: every 16 ticks is plenty to
		# catch a divergence, which never heals once it happens.
		if t % 16 == 0 and restored.state_hash() != straight.state_hash():
			_expect(false, "the restored run must stay identical, diverged by +%d" % t)
			break
	_expect(restored.state_hash() == straight.state_hash(), "the restored run must end in the same state")
	_expect((straight.to_save_state()["areaOrders"]["list"] as Array).is_empty(), "both orders must have finished expanding")
	_expect(restored.get_jobs() == straight.get_jobs(), "the restored run must end with the same jobs")
	# The saved queue is validated like every other field.
	var good: Dictionary = saved["areaOrders"]
	_expect(SaveIOType._validate_state(saved)["ok"], "the mid-expansion save must validate")
	for corrupt in [
		{"order": "build"}, {"next": SIZE * SIZE}, {"width": SIZE + 1}, {"commandId": ""}, {"id": 99}, {"extra": 1},
	]:
		var bad := saved.duplicate(true)
		var entry: Dictionary = (bad["areaOrders"]["list"] as Array)[0]
		for key in corrupt:
			entry[key] = corrupt[key]
		_expect(not SaveIOType._validate_state(bad)["ok"], "an areaOrders entry with %s must be rejected" % [corrupt])
	_expect(good == saved["areaOrders"], "sanity: corrupting copies must leave the save untouched")

func _check_step_budget_and_small_rectangles() -> void:
	var reference = WorldStateType.new(SEED, 10, SIZE, SIZE)
	var world = WorldStateType.new(SEED, 10, SIZE, SIZE)
	var rect := Rect2i(10, 10, 16, AreaOrders.TILES_PER_STEP / 16) # exactly one step
	var expected_rejected: Array[Dictionary] = []
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var result := _apply(reference, "chop", {"x": x, "y": y, "priority": 1})
			if not result.get("ok", false):
				expected_rejected.append({"x": x, "y": y, "reason": String(result["rejection"]["reason"])})
	var result := _area(world, "chop", rect)
	_expect(int(result.get("remaining", -1)) == 0, "a one-step rectangle must finish at release")
	_expect(result.get("skipped") == expected_rejected, "a one-step rectangle must report the per-tile rejections")
	_expect(_targets(world, "chop") == _targets(reference, "chop"), "a one-step rectangle must create the per-tile jobs at release")
	var big := _area(world, "mine", Rect2i(0, 0, SIZE, 8))
	_expect(int(big["remaining"]) == SIZE * 8 - AreaOrders.TILES_PER_STEP, "a larger rectangle must leave the rest for later ticks")

func _check_invalid_payloads() -> void:
	var world = WorldStateType.new(SEED, 10, SIZE, SIZE)
	var hash_before: int = world.state_hash()
	for payload in [
		{"order": "build", "x": 0, "y": 0, "width": 2, "height": 2},
		{"order": "dig", "x": 0, "y": 0, "width": 0, "height": 2},
		{"order": "dig", "x": SIZE - 1, "y": 0, "width": 2, "height": 1},
		{"order": "dig", "x": 0, "y": 0, "width": 1, "height": 1, "colour": "red"},
		{"order": "dig", "x": "0", "y": 0, "width": 1, "height": 1},
	]:
		_n += 1
		var command := {"actor": "player", "command_id": "bad%d" % _n, "tick": world.get_tick(), "type": "area_order", "payload": payload}
		var preview: Dictionary = world.preview(command)
		var applied: Dictionary = world.apply(command)
		_expect(not preview.get("ok", true) and not applied.get("ok", true), "area_order %s must be rejected" % [payload])
		_expect(preview.get("rejection", {}).get("reason") == applied.get("rejection", {}).get("reason"),
			"preview and apply must agree on %s" % [payload])
	_expect(world.state_hash() == hash_before, "rejected area orders must not change the state")
	var ok_preview: Dictionary = world.preview({"actor": "player", "command_id": "fine", "tick": world.get_tick(), "type": "area_order",
		"payload": {"order": "cancel", "x": 0, "y": 0, "width": SIZE, "height": SIZE}})
	_expect(ok_preview.get("ok", false), "a valid area_order must preview as accepted: %s" % ok_preview)

func _dig_targets(world) -> Array:
	return _targets(world, "dig")

## Targets of every job of `kind`, in job id (creation) order.
func _targets(world, kind: String) -> Array:
	var jobs: Array = []
	for job in world.get_jobs():
		if String(job["kind"]) == kind:
			jobs.append(job)
	jobs.sort_custom(func(a, b) -> bool: return int(String(a["id"]).trim_prefix("job_")) < int(String(b["id"]).trim_prefix("job_")))
	var targets: Array = []
	for job in jobs:
		targets.append(job["target"])
	return targets

func _area(world, order: String, rect: Rect2i) -> Dictionary:
	_n += 1
	return world.apply({"actor": "player", "command_id": "area%d" % _n, "tick": world.get_tick(), "type": "area_order",
		"payload": {"order": order, "x": rect.position.x, "y": rect.position.y, "width": rect.size.x, "height": rect.size.y, "priority": 1}})

func _apply(world, type: String, payload: Dictionary) -> Dictionary:
	_n += 1
	return world.apply({"actor": "player", "command_id": "t%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload})

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
