extends SceneTree

## Covers objective #129/issue #133: an active job's colonist walks to it and
## works it, entirely inside WorldState.tick().
## Also covers issue #205 (colonist-ai.md 3.6): tile-keyed work_progress and
## the critical-need interrupt of an in-progress `work` toil.

const WorldType = preload("res://scripts/core/world_state.gd")
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const MAX_TICKS := 400

var _failed := false

func _init() -> void:
	_check_walk_and_work_trace()
	_check_replay_hash_matches()
	_check_interruptible_toil_contract()
	_check_critical_need_interrupts_work_and_resumes_with_preserved_progress()
	_check_critical_need_does_not_interrupt_pick_up()
	_check_paused_job_and_work_progress_round_trip()
	_check_save_load_after_resume_matches_live_run()
	_check_overlapping_dig_orders_produce_one_sand_and_one_find_roll()
	_check_paused_dig_whose_target_changes_fails_without_double_reward()

	if _failed:
		quit(1)
		return
	print("test_movement_and_work: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## A single row corridor: colonist starts at (0,0); (0,0)-(3,0) are soil,
## (4,0) is a tree. Everything else is rock, so the router has exactly one
## path to each target, keeping the position trace below unambiguous. Issue
## #359: the axe spawns at (3,0), past the dig target (2,0), not at (0,0) --
## dig always completes first (nearer), turning (2,0) into trench, so a
## same-side axe would send the colonist's own fetch_tool leg back through
## it to reach (0,0), tripping the new trap-on-entry rule (route search
## still treats trench as ordinary passable terrain; only arrival traps).
func _build_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_ROCK)
	for x in range(0, 5):
		world._tiles[world._tile_index(x, 0)] = WorldType.TILE_SOIL
	world._tiles[world._tile_index(4, 0)] = WorldType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 0)
	world.spawn_ground_tool_item("axe", 3, 0)
	return world

func _dig_target() -> Vector2i:
	return Vector2i(2, 0)

func _chop_target() -> Vector2i:
	return Vector2i(4, 0)

func _command(world: WorldType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

func _submit_orders(world: WorldType) -> void:
	var dig := _dig_target()
	var chop := _chop_target()
	var dig_result := _command(world, "dig_1", "dig", {"x": dig.x, "y": dig.y, "priority": 1})
	_expect(dig_result["ok"], "dig order must be accepted")
	var chop_result := _command(world, "chop_1", "chop", {"x": chop.x, "y": chop.y, "priority": 1})
	_expect(chop_result["ok"], "chop order must be accepted")

func _jobs_done(world: WorldType) -> bool:
	var completed := 0
	for job in world.get_jobs():
		if job["status"] == "completed":
			completed += 1
	return completed == 2

## Matches WorldState._is_passable() exactly, with no exception for the chop
## target: a colonist works a tree from the adjacent tile it stopped on, and
## must never occupy the tree tile itself (see global_assignment.gd's path
## trim in its "chosen" loop). TILE_TRENCH is included since a colonist digs
## soil while standing on it (ADR 025): the tile flips to trench under the
## colonist's own feet on dig's completing tick.
func _tile_ok(world: WorldType, pos: Vector2i) -> bool:
	return world.get_tile(pos.x, pos.y) in [WorldType.TILE_FLOOR, WorldType.TILE_SOIL, WorldType.TILE_TRENCH]

## ADR 025: dig always spawns a sand item on the nearest adjacent passable,
## non-trench tile to its target (or the target itself when no such neighbour
## exists).
func _has_sand_near(world: WorldType, target: Vector2i) -> bool:
	for item in world.get_items():
		if String(item["kind"]) == "sand" and maxi(absi(int(item["x"]) - target.x), absi(int(item["y"]) - target.y)) <= 1:
			return true
	return false

## Records every colonist's position each tick and asserts a walked trace,
## not just start/end: each step is either a hold or a single orthogonal
## move onto a tile that is passable at that exact tick.
func _check_walk_and_work_trace() -> void:
	var world := _build_world(4242)
	_submit_orders(world)
	var chop := _chop_target()
	var previous: Dictionary = {}
	for colonist in world.get_colonists():
		previous[colonist["id"]] = Vector2i(colonist["x"], colonist["y"])
	var ticks := 0
	while not _jobs_done(world) and ticks < MAX_TICKS:
		world.tick()
		ticks += 1
		for colonist in world.get_colonists():
			var id: String = colonist["id"]
			var pos := Vector2i(colonist["x"], colonist["y"])
			var prev: Vector2i = previous[id]
			var delta := (pos - prev).abs()
			_expect(delta.x + delta.y <= 1,
				"colonist %s jumped from %s to %s at tick %d" % [id, prev, pos, world.get_tick()])
			_expect(_tile_ok(world, pos),
				"colonist %s stands on an impassable tile %s at tick %d" % [id, pos, world.get_tick()])
			previous[id] = pos
	_expect(_jobs_done(world), "both orders must complete within the tick budget")
	if not _jobs_done(world):
		return
	var dig := _dig_target()
	_expect(world.get_tile(dig.x, dig.y) == WorldType.TILE_TRENCH, "dig target must become trench")
	_expect(_has_sand_near(world, dig), "dig target must leave a sand item on or adjacent to the trench")
	_expect(world.get_tile(chop.x, chop.y) == WorldType.TILE_FLOOR, "chop target must become floor")
	_expect(world.get_ground_wood(chop.x, chop.y) == 1, "chop target must leave exactly one ground wood")

## Two independent runs with the same seed and the same command sequence must
## reach an identical state_hash(), proving the walk/work advance is
## deterministic, not just its end state.
func _check_replay_hash_matches() -> void:
	var first := _build_world(777)
	_submit_orders(first)
	var ticks := 0
	while not _jobs_done(first) and ticks < MAX_TICKS:
		first.tick()
		ticks += 1
	_expect(_jobs_done(first), "first replay run must complete both orders")

	var second := _build_world(777)
	_submit_orders(second)
	ticks = 0
	while not _jobs_done(second) and ticks < MAX_TICKS:
		second.tick()
		ticks += 1
	_expect(_jobs_done(second), "second replay run must complete both orders")

	_expect(first.state_hash() == second.state_hash(),
		"identical seed and commands must reproduce the same state_hash()")

## colonist-ai.md 3.6's explicit example: `work` is the only interruptible
## toil; `pick_up`/`consume` are named explicitly as not, and every other
## vocabulary entry defaults to not-interruptible the same way.
func _check_interruptible_toil_contract() -> void:
	_expect(ToilExecutorType.is_interruptible_toil("work"), "'work' must be interruptible")
	for name in ["pick_up", "consume", "reserve", "go_to", "place", "release_all"]:
		_expect(not ToilExecutorType.is_interruptible_toil(name), "'%s' must not be interruptible" % name)

## Zeroes every need kind's decay rate except `kind` (mirrors test_need_jobs.gd's
## own _isolate_need()), so a scenario built around food is never disturbed by
## water/rest crossing their own thresholds over a long-running interrupt test.
func _isolate_need(world: WorldType, kind: String) -> void:
	for other in world._need_definitions.keys():
		if other != kind:
			world._need_definitions[other]["rate_per_day"] = 0

func _set_food(world: WorldType, colonist_id: String, value: int) -> void:
	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == colonist_id:
			world._colonists[i]["needs"]["food"] = value

func _colonist_by_id(world: WorldType, colonist_id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}

## Unlike _colonist_by_id() (which reads a detached duplicate via
## get_colonists()), returns the live Dictionary reference from world._colonists
## itself, so a caller can mutate it in place or pass it to a WorldState method
## that expects the real colonist record (e.g. _pause_work_job()).
func _real_colonist_by_id(world: WorldType, colonist_id: String) -> Dictionary:
	for colonist in world._colonists:
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}

## A 6-tile floor corridor (0,0)-(5,0) with a dig target at (3,0) and one
## ground-berries unit at (5,0): close enough that the eat detour is quick and
## bounded, keeping the scenario deterministic within a small tick budget.
func _build_interrupt_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_FLOOR)
	world._tiles[world._tile_index(3, 0)] = WorldType.TILE_SOIL
	world._colonists.clear()
	_isolate_need(world, "food")
	# "needs" keys are listed alphabetically (food, rest, water) to match
	# StateCodec._encode_needs()'s sorted wire order: JSON.stringify()-based
	# hashing is key-order sensitive, so a hand-built colonist and one that
	# round-tripped through save/load must agree on it to ever hash equal.
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "rest": 100, "water": 100}, "route": null, "work": null, "hands": []})
	world._ground_berries["5_0"] = 1
	world.spawn_ground_tool_item("pick", 0, 0)
	return world

## Acceptance (issue #205, revised by #241/ADR 009): a colonist with a critical
## hunger need has its in-progress `work` toil (dig) interrupted immediately,
## mid-tick-count, not at the next toil boundary; the paused job goes back to
## "queued" (never cancelled/resubmitted to a new id) and releases its
## reservation for the duration of the interrupt, per ADR 009; once the need
## job finishes, the same job resumes and completes with the same total
## work-tick count as WORK_TICKS["dig"], proving tile work_progress was
## preserved rather than reset.
func _check_critical_need_interrupts_work_and_resumes_with_preserved_progress() -> void:
	var world := _build_interrupt_world(555001)
	var dig_result := _command(world, "dig_1", "dig", {"x": 3, "y": 0, "priority": 1})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result.get("job_id", ""))

	var work_started := false
	var ticks := 0
	while not work_started and ticks < MAX_TICKS:
		world.tick()
		ticks += 1
		var colonist := _colonist_by_id(world, "colonist_0")
		if colonist.get("work") != null and String(colonist["work"]["job_id"]) == dig_job_id:
			work_started = true
	_expect(work_started, "the dig job's work toil must start within the tick budget")
	if not work_started:
		return

	# Mid-work, well before the toil's own duration elapses: not a toil
	# boundary by any definition.
	var ticks_remaining_before_interrupt := int(_colonist_by_id(world, "colonist_0")["work"]["ticks_remaining"])
	_expect(ticks_remaining_before_interrupt > 1, "the interrupt must land mid-tick-count, not on the toil's last tick")
	_set_food(world, "colonist_0", 5)

	world.tick()
	ticks += 1
	var interrupted := _colonist_by_id(world, "colonist_0")
	_expect(interrupted.get("work") == null, "a critical need must interrupt the work toil on the very next tick")
	var dig_job_mid_interrupt := world._scheduler.queue.get_job(dig_job_id)
	_expect(dig_job_mid_interrupt["status"] == "queued",
		"the interrupted job must go back to queued (never cancelled or resubmitted to a new id), releasing its reservation per ADR 009 (got '%s')" % dig_job_mid_interrupt["status"])
	_expect(world._paused_jobs.get("colonist_0", "") == dig_job_id,
		"the interrupt must record the paused job for colonist_0")

	# Round-6 review (#278/#303): a suspended job's own progress moves OUT of
	# the shared tile cache into job-id-keyed storage the instant colonist.work
	# is cleared for it (world_state.gd's own _suspend_work_progress()), so a
	# different job that later works the same tile can never inherit it.
	_expect(int(world._suspended_work_progress.get(dig_job_id, -1)) == ticks_remaining_before_interrupt,
		"the paused job's own progress must equal the exact tick count it was interrupted at")
	_expect(not world._work_progress.has("3_0"),
		"a suspended job's tile-cache entry must be cleared, not left for a different job to inherit")

	# From here to completion, "3_0"'s stored progress must never increase and
	# never drop by more than one tick per tick() call: since it started at
	# WORK_TICKS["dig"] - 1 (one tick already spent before the very first
	# observation above) and is cleared only once the toil truly finishes,
	# these two invariants together force the total real work done to be
	# exactly WORK_TICKS["dig"] ticks -- proving resumption continued from
	# the preserved count rather than restarting the timer.
	var resumed := false
	var dig_completed := false
	var last_seen_progress := ticks_remaining_before_interrupt
	while ticks < MAX_TICKS and not dig_completed:
		world.tick()
		ticks += 1
		var colonist := _colonist_by_id(world, "colonist_0")
		if colonist.get("work") != null and String(colonist["work"]["job_id"]) == dig_job_id:
			resumed = true
		if world._work_progress.has("3_0"):
			var current := int(world._work_progress["3_0"])
			_expect(current <= last_seen_progress and current >= last_seen_progress - 1,
				"work_progress must decrease by exactly one tick at a time, never reset upward (was %d, now %d)"
					% [last_seen_progress, current])
			last_seen_progress = current
		var dig_job := world._scheduler.queue.get_job(dig_job_id)
		if dig_job["status"] == "completed":
			dig_completed = true
	_expect(resumed, "the paused job must resume the same colonist.work toil")
	_expect(dig_completed, "the dig job must eventually complete within the tick budget")
	_expect(world.get_colonist_need_reason("colonist_0") == "",
		"the critical hunger must have been satisfied by the interrupt's need job")
	_expect(world.get_tile(3, 0) == WorldType.TILE_TRENCH, "the dig target must become trench")
	_expect(_has_sand_near(world, Vector2i(3, 0)), "the dig target must leave a sand item on or adjacent to the trench")
	_expect(not world._work_progress.has("3_0"), "work_progress for a finished tile must be cleared")

## Acceptance (issue #205): the same critical need does not interrupt a
## `pick_up` toil (or the `go_to` leg leading to it) mid-way -- a haul
## colonist still walking to its item keeps walking and successfully picks it
## up despite a critical need, unlike dig/chop's `work` toil above.
func _check_critical_need_does_not_interrupt_pick_up() -> void:
	var world := WorldType.new(555002, 10)
	world._tiles.fill(WorldType.TILE_FLOOR)
	world._colonists.clear()
	_isolate_need(world, "food")
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "rest": 100, "water": 100}, "route": null, "work": null, "hands": []})
	world._items["item_1"] = {"id": "item_1", "x": 9, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var zone_result: Dictionary = world.apply({"actor": "test", "command_id": "zone1", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 5, "y": 1, "width": 1, "height": 1}})
	_expect(zone_result["ok"], "haul destination zone_add must be accepted")

	var walking := false
	var ticks := 0
	while not walking and ticks < MAX_TICKS:
		world.tick()
		ticks += 1
		var colonist := _colonist_by_id(world, "colonist_0")
		if colonist.get("route") != null and not InventoryType.is_carrying(colonist):
			walking = true
	_expect(walking, "the haul colonist must be mid-walk toward the item within the tick budget")
	if not walking:
		return

	_set_food(world, "colonist_0", 5)

	var picked_up := false
	while ticks < MAX_TICKS and not picked_up:
		world.tick()
		ticks += 1
		var colonist := _colonist_by_id(world, "colonist_0")
		if InventoryType.is_carrying(colonist):
			picked_up = true
	_expect(picked_up, "a critical need must not prevent pick_up from eventually succeeding")
	_expect(not world._items.has("item_1"), "the picked-up item must leave the ground map")

## Acceptance (issue #205): the two new persisted fields (WorldState._work_progress/
## _paused_jobs) round-trip through to_save_state()/from_save_state() exactly,
## checked directly rather than via state_hash(): an in-flight need job/search
## is deliberately out of this task's persistence scope (colonist-ai.md 3.1's
## own non-goal, unchanged here -- WorldState.get_jobs() merges in a live
## _need_jobs entry that to_save_state() never writes at all), so a save taken
## while the eat_food job is still active would make state_hash() itself
## diverge after restore for a reason this task does not touch. Saving at the
## paused instant -- after _pause_work_job() but before the need job's own
## unrelated persistence gap can matter -- isolates exactly what #205 added.
func _check_paused_job_and_work_progress_round_trip() -> void:
	var world := _build_interrupt_world(555004)
	var dig_result := _command(world, "dig_1", "dig", {"x": 3, "y": 0, "priority": 1})
	_expect(dig_result["ok"], "the dig order must be accepted")

	var ticks := 0
	var work_started := false
	while not work_started and ticks < MAX_TICKS:
		world.tick()
		ticks += 1
		var colonist := _colonist_by_id(world, "colonist_0")
		if colonist.get("work") != null:
			work_started = true
	_expect(work_started, "the dig job's work toil must start within the tick budget")
	_set_food(world, "colonist_0", 5)
	world.tick()
	_expect(not world._paused_jobs.is_empty(), "the colonist's job must be paused at the save point")
	# Round-6 review (#278/#303): a suspended job's own progress now lives in
	# job-id-keyed _suspended_work_progress, not the shared tile-keyed
	# _work_progress cache (world_state.gd's own _suspend_work_progress()).
	_expect(world._work_progress.is_empty(), "the paused tile's own tile-cache entry must have moved out")
	_expect(not world._suspended_work_progress.is_empty(), "the paused job must still carry its own suspended progress")

	var saved := world.to_save_state()
	var restored := WorldType.from_save_state(saved)
	_expect(restored._paused_jobs == world._paused_jobs,
		"pausedJobs must round-trip through to_save_state()/from_save_state() unchanged")
	_expect(restored._work_progress == world._work_progress,
		"workProgress must round-trip through to_save_state()/from_save_state() unchanged")
	_expect(restored._suspended_work_progress == world._suspended_work_progress,
		"suspendedWorkProgress must round-trip through to_save_state()/from_save_state() unchanged")

## Acceptance (issue #205): saving after a critical-need interrupt has already
## resumed the same job -- mid-work again, work_progress non-empty, but the
## need job long since finished and released -- and loading, then continuing,
## reaches the same state_hash() as continuing the live run to the same tick.
## This is the "mid-interrupt" scenario that stays entirely within #205's own
## persistence surface (see _check_paused_job_and_work_progress_round_trip()'s
## comment for why saving during the need job itself is excluded -- this test
## drives _pause_work_job()/_resume_paused_job() directly (as _isolate_need()-
## style tests elsewhere in this suite already reach into WorldState's
## internals) rather than through a real need job, so no _need_jobs entry
## (with its own, unrelated, pre-existing persistence gap) is ever created.
func _check_save_load_after_resume_matches_live_run() -> void:
	# Deliberately not _build_interrupt_world(): that helper's _isolate_need()
	# mutates WorldState._need_definitions in memory only (never persisted --
	# from_save_state() reloads content/needs.json fresh), so a restored copy
	# would resume decaying water/rest at their real rates while the live
	# copy's stayed pinned, a save/load mismatch of the test's own making, not
	# a real one. No need source is required here either way, since this test
	# never lets any real need job run.
	var live := WorldType.new(555003)
	live._tiles.fill(WorldType.TILE_FLOOR)
	live._tiles[live._tile_index(3, 0)] = WorldType.TILE_SOIL
	live._colonists.clear()
	live._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "rest": 100, "water": 100}, "route": null, "work": null, "hands": []})
	live.spawn_ground_tool_item("pick", 0, 0)
	var dig_result := _command(live, "dig_1", "dig", {"x": 3, "y": 0, "priority": 1})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result["job_id"])

	var ticks := 0
	var work_started := false
	while not work_started and ticks < MAX_TICKS:
		live.tick()
		ticks += 1
		var colonist := _colonist_by_id(live, "colonist_0")
		if colonist.get("work") != null:
			work_started = true
	_expect(work_started, "the dig job's work toil must start within the tick budget")

	var colonist := _real_colonist_by_id(live, "colonist_0")
	live._pause_work_job(colonist)
	_expect(colonist.get("work") == null, "_pause_work_job() must clear colonist.work")
	_expect(live._paused_jobs.get("colonist_0", "") == dig_job_id, "_pause_work_job() must record the paused job")
	live._resume_paused_job(colonist)
	_expect(live._paused_jobs.is_empty(), "_resume_paused_job() must clear the paused job bookkeeping")
	_expect(colonist.get("work") != null and String(colonist["work"]["job_id"]) == dig_job_id,
		"_resume_paused_job() must resume the same job's work toil when the colonist is already within reach")
	var dig_job_before_save := live._scheduler.queue.get_job(dig_job_id)
	_expect(dig_job_before_save["status"] == "active", "the resumed dig job must not have finished yet")

	var saved := live.to_save_state()
	var restored := WorldType.from_save_state(saved)
	_expect(restored.state_hash() == live.state_hash(),
		"a post-interrupt, mid-resumed-work save/load round trip must match the source's hash before any further ticks")

	var final_ticks := 200
	for _i in final_ticks:
		live.tick()
		restored.tick()
	_expect(live.state_hash() == restored.state_hash(),
		"identically advancing the source and its post-interrupt restore must keep matching state_hash()")
	_expect(live.get_tile(3, 0) == WorldType.TILE_TRENCH and restored.get_tile(3, 0) == WorldType.TILE_TRENCH,
		"both the source and its post-interrupt restore must finish the resumed dig job")
	_expect(_has_sand_near(live, Vector2i(3, 0)) and _has_sand_near(restored, Vector2i(3, 0)),
		"both the source and its post-interrupt restore must leave a sand item on or adjacent to the trench")

## Round-3 review (#358): two dig orders queued for the SAME soil tile, with a single colonist
## and a single pick forcing them to run sequentially, must not both spawn a sand item or both
## consume a find roll. _toil_on_work_complete()'s "dig" branch now revalidates TILE_SOIL before
## flooring/spawning (mirroring mine's own stale-duplicate-order guard, test_mine_job.gd's
## _check_overlapping_mine_orders_produce_one_stone()): the first order digs and trenches the
## tile; the second, already queued while the tile was still soil, reaches work-complete against
## a now-TILE_TRENCH target and must fail invalid_target instead of producing a second sand item
## or staging a second find roll -- and must not leave its tile reservation behind once terminal.
func _check_overlapping_dig_orders_produce_one_sand_and_one_find_roll() -> void:
	var world := WorldType.new(358001)
	world._tiles.fill(WorldType.TILE_FLOOR)
	var target := Vector2i(2, 0)
	world._tiles[world._tile_index(target.x, target.y)] = WorldType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	world.spawn_ground_tool_item("pick", 0, 0)

	var dig_1 := _command(world, "dig_dup_1", "dig", {"x": target.x, "y": target.y, "priority": 1})
	_expect(dig_1["ok"], "first dig submission on a soil tile must be accepted")
	var dig_2 := _command(world, "dig_dup_2", "dig", {"x": target.x, "y": target.y, "priority": 1})
	_expect(dig_2["ok"], "second dig submission for the same soil tile must also be accepted")

	var job_ids := [String(dig_1["job_id"]), String(dig_2["job_id"])]
	var completed_count := 0
	var failed_count := 0
	for _i in MAX_TICKS:
		world.tick()
		completed_count = 0
		failed_count = 0
		for job_id in job_ids:
			match String(world._scheduler.queue.get_job(job_id).get("status", "")):
				"completed": completed_count += 1
				"failed": failed_count += 1
		if completed_count + failed_count == 2:
			break

	_expect(completed_count == 1, "exactly one of two dig orders queued for the same soil tile must complete, got %d" % completed_count)
	_expect(failed_count == 1, "exactly one of two dig orders queued for the same soil tile must fail, got %d" % failed_count)
	for job_id in job_ids:
		var job := world._scheduler.queue.get_job(job_id)
		if String(job.get("status", "")) == "failed":
			_expect(String(job.get("reason", "")) == "invalid_target",
				"the second dig order to reach an already-dug tile must fail invalid_target, got %s" % job)

	_expect(world.get_tile(target.x, target.y) == WorldType.TILE_TRENCH, "the tile must end up dug (trench) exactly once")
	var sand_count := 0
	for item in world.get_items():
		if String(item.get("kind", "")) == "sand":
			sand_count += 1
	_expect(sand_count == 1,
		"exactly one sand item must exist after two overlapping dig orders on the same soil tile, got %d" % sand_count)
	_expect(world._pending_dig_finds.is_empty(),
		"no find roll may remain staged once both overlapping dig orders are terminal, got %s" % [world._pending_dig_finds])

	_expect(not world._scheduler.queue.get_reservation_table().is_reserved("tile:%d,%d" % [target.x, target.y]),
		"the target tile must be unreserved once both dig orders are terminal")
	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect(orphans.is_empty(), "the stale dig order must not leave any orphaned reservation, got %s" % [orphans])

## Round-3 review (#358): a dig job paused mid-work (critical-need interrupt, ADR 009 -- see
## _check_critical_need_interrupts_work_and_resumes_with_preserved_progress() above) releases its
## tile reservation for the duration of the interrupt. If another job changes that same tile while
## this one is paused -- here simulated directly, the same way _build_world()/_build_interrupt_world()
## above hand-build tile state, standing in for a second dig job's own completion effect so this
## test isolates the paused-job's own revalidation from a second full walk/work simulation -- the
## resumed job must reach work-complete against a stale target and fail invalid_target rather than
## spawning a second sand item or consuming a second find roll.
func _check_paused_dig_whose_target_changes_fails_without_double_reward() -> void:
	var world := _build_interrupt_world(358002)
	var dig_result := _command(world, "dig_1", "dig", {"x": 3, "y": 0, "priority": 1})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result["job_id"])

	var ticks := 0
	var work_started := false
	while not work_started and ticks < MAX_TICKS:
		world.tick()
		ticks += 1
		var colonist := _colonist_by_id(world, "colonist_0")
		if colonist.get("work") != null:
			work_started = true
	_expect(work_started, "the dig job's work toil must start within the tick budget")
	if not work_started:
		return

	# _interrupt_current_job()/_resume_interrupted_job() (not the lower-level
	# _pause_work_job()/_resume_paused_job() pair) are what the real ADR 009
	# critical-need path drives: only these also suspend/restore the scheduler
	# assignment, which is what actually releases and re-acquires the tile
	# reservation below.
	var colonist := _real_colonist_by_id(world, "colonist_0")
	world._interrupt_current_job(colonist)
	_expect(colonist.get("work") == null, "_interrupt_current_job() must clear colonist.work")
	_expect(world._paused_jobs.get("colonist_0", "") == dig_job_id, "_interrupt_current_job() must record the paused job")
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved("tile:3,0"),
		"pausing the job must release its tile reservation")

	# Stand in for a second dig job completing on this same tile while colonist_0's job sits
	# paused: exactly the effect world_state.gd's own "dig" branch would have produced.
	world._tiles[world._tile_index(3, 0)] = WorldType.TILE_TRENCH
	world._spawn_item("sand", 4, 0)

	world._resume_interrupted_job("colonist_0")
	_expect(world._paused_jobs.is_empty(), "_resume_interrupted_job() must clear the paused job bookkeeping")
	_expect(colonist.get("work") != null and String(colonist["work"]["job_id"]) == dig_job_id,
		"_resume_interrupted_job() must resume the same job's work toil when the colonist is already within reach")

	var terminal := false
	while ticks < MAX_TICKS and not terminal:
		world.tick()
		ticks += 1
		var job := world._scheduler.queue.get_job(dig_job_id)
		if String(job.get("status", "")) in ["completed", "failed"]:
			terminal = true
	_expect(terminal, "the resumed dig job must reach a terminal status within the tick budget")
	if not terminal:
		return

	var final_job := world._scheduler.queue.get_job(dig_job_id)
	_expect(String(final_job.get("status", "")) == "failed",
		"a resumed dig job whose target changed while paused must fail, not complete a second time (got '%s')" % final_job.get("status"))
	_expect(String(final_job.get("reason", "")) == "invalid_target",
		"the resumed dig job's failure must report invalid_target, got '%s'" % final_job.get("reason"))

	var sand_count := 0
	for item in world.get_items():
		if String(item.get("kind", "")) == "sand":
			sand_count += 1
	_expect(sand_count == 1,
		"the resumed dig job must not spawn a second sand item once its target is stale, got %d" % sand_count)
	_expect(world._pending_dig_finds.is_empty(),
		"the resumed dig job must not stage a second find roll once its target is stale, got %s" % [world._pending_dig_finds])
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved("tile:3,0"),
		"the resumed dig job must not leave its tile reservation behind once terminal")
