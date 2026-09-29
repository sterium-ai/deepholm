extends SceneTree

## Acceptance coverage for issue #401: a max_builders-2 site (the workbench)
## may hold two build-labour colonists fetching/working at once, never a
## third; a second concurrent site_fetch job picks the declared-cost source
## nearest the site the other builder has not already reserved (#400's
## per-builder nearest-unclaimed-source rule); two active builders double
## ConstructionSiteTable.progress's own accumulation rate, reaching
## build_ticks in roughly build_ticks / 2 ticks; and a builder leaving
## mid-work (a need interrupt, ADR 009) drops out of builder_ids immediately,
## losing/duplicating no progress, while the remaining builder continues
## alone at single rate. test_construction_site.gd owns the single-builder
## lifecycle (creation, delivery, exact-build_ticks timing, cancellation);
## this file owns everything that only exists once a second builder can join.

const WorldStateType = preload("res://scripts/core/world_state.gd")

const MAX_TICKS := 500

var _failed := false

func _init() -> void:
	_check_two_builders_assigned_third_never_assigned()
	_check_two_concurrent_fetchers_pick_different_nearest_unclaimed_sources()
	_check_two_active_builders_double_the_progress_rate()
	_check_builder_leaving_mid_work_halves_rate_and_preserves_progress()

	if _failed:
		quit(1)
		return
	print("test_build_multi_builder: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._objects.clear()
	return world

func _colonist(id: String, x: int, y: int) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"route": null, "work": null, "carrying": null}

func _command(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": command_type, "payload": payload})

func _command_ok(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	var result := _command(world, command_id, command_type, payload)
	_expect(bool(result.get("ok", false)), "%s must be accepted: %s" % [command_id, result])
	return result

func _add_stock(world: WorldStateType, kind: String, count: int, x: int, y: int) -> void:
	var id := "item_%d" % world._next_item_id
	world._items[id] = {"id": id, "x": x, "y": y, "kind": kind, "count": count}
	world._next_item_id += 1

## Zeroes every need kind's decay rate except `kind` (mirrors test_need_jobs.gd's
## own helper): only test D deliberately drives a need interrupt, and must not
## risk a second, unrelated need crossing its own threshold mid-run.
func _isolate_need(world: WorldStateType, kind: String) -> void:
	for other in world._need_definitions.keys():
		if other != kind:
			world._need_definitions[other]["rate_per_day"] = 0

## Every colonist id currently driving an active site_fetch/site_work job on
## `origin` -- unlike ConstructionSiteTable's own builder_ids (site_work
## only), this also counts a colonist mid-fetch, so it is what tests A/B need
## to observe the fetch phase's own concurrency.
func _active_site_builders(world: WorldStateType, origin: Vector2i) -> Array[String]:
	var active_job_ids := {}
	for job in world.get_jobs():
		if job.get("site") == origin and String(job.get("kind", "")) in ["site_fetch", "site_work"] \
				and String(job.get("status", "")) == "active":
			active_job_ids[String(job["id"])] = true
	var ids: Array[String] = []
	var assignments = world._scheduler.get_assignments()
	for worker in assignments.keys():
		if active_job_ids.has(String(assignments[worker]["job_id"])):
			ids.append(String(worker))
	return ids

## Every queued or active site_fetch/site_work job on `origin`, whether or
## not a colonist has picked it up yet -- what ConstructionGiver's own
## max_builders cap actually throttles.
func _held_site_job_count(world: WorldStateType, origin: Vector2i) -> int:
	var count := 0
	for job in world.get_jobs():
		if job.get("site") == origin and String(job.get("kind", "")) in ["site_fetch", "site_work"] \
				and String(job.get("status", "")) in ["queued", "active"]:
			count += 1
	return count

## Acceptance: "two colonists with build labour enabled are both assigned to
## the same workbench site; a third eligible colonist is not assigned to it"
## -- and never more than max_builders (2) jobs are held on the site at once,
## whichever mix of fetching/working they are.
func _check_two_builders_assigned_third_never_assigned() -> void:
	var world := _build_world(340001)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	world._colonists.append(_colonist("colonist_1", 1, 0))
	world._colonists.append(_colonist("colonist_2", 2, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 3, "height": 1})
	_add_stock(world, "wood", 3, 0, 0)
	_add_stock(world, "stone", 4, 1, 0)
	var site_origin := Vector2i(10, 10)
	_command_ok(world, "wb", "build", {"kind": "workbench", "x": site_origin.x, "y": site_origin.y})
	var ever_builders := {}
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		_expect(_held_site_job_count(world, site_origin) <= 2,
			"no more than max_builders (2) site_fetch/site_work jobs may ever be held on the site at once")
		for id in _active_site_builders(world, site_origin):
			ever_builders[id] = true
		if world.get_construction_site(site_origin.x, site_origin.y).is_empty():
			completed = true
			break
	_expect(completed, "the workbench site must complete within the tick budget")
	_expect(ever_builders.size() == 2,
		"exactly two of the three eligible colonists may ever build this site, never all three (got %s)" % [ever_builders.keys()])

## Acceptance: "each of the two builders fetches from the source nearest the
## site that the other has not reserved (assert the two chosen sources/items
## differ)". Two colonists start at the same distance from two equally
## eligible wood sources (one item id would win any solo nearest-source tie);
## once both site_fetch jobs are concurrently active, #400's per-builder
## exclusion (_next_site_fetch_source()) must have routed the second one onto
## the other source rather than duplicating the first's own pick.
func _check_two_concurrent_fetchers_pick_different_nearest_unclaimed_sources() -> void:
	var world := _build_world(340002)
	world._colonists.append(_colonist("colonist_0", 10, 15))
	world._colonists.append(_colonist("colonist_1", 11, 15))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 5, "width": 25, "height": 15})
	var item_a_id := "item_%d" % world._next_item_id
	_add_stock(world, "wood", 1, 5, 10)
	var item_b_id := "item_%d" % world._next_item_id
	_add_stock(world, "wood", 1, 16, 10)
	var site_origin := Vector2i(10, 10)
	_command_ok(world, "wb", "build", {"kind": "workbench", "x": site_origin.x, "y": site_origin.y})
	var chosen_items: Dictionary = {}
	for _i in MAX_TICKS:
		world.tick()
		chosen_items = {}
		for job in world.get_jobs():
			if job.get("site") == site_origin and String(job.get("kind", "")) == "site_fetch" \
					and String(job.get("status", "")) == "active":
				chosen_items[String(job["id"])] = String(job.get("item_id", ""))
		if chosen_items.size() == 2:
			break
	_expect(chosen_items.size() == 2, "both concurrent site_fetch jobs must be simultaneously active within the tick budget")
	if chosen_items.size() != 2:
		return
	var picked: Array = chosen_items.values()
	_expect(String(picked[0]) != String(picked[1]),
		"two concurrently active site_fetch jobs on the same site must never target the same source item (got %s)" % [picked])
	for item_id in picked:
		_expect(String(item_id) == item_a_id or String(item_id) == item_b_id,
			"each builder must pick one of the two pre-placed equally-eligible wood sources (got %s)" % [item_id])

## Acceptance: "with both builders actively working, the site's progress
## reaches build_ticks in build_ticks / 2 ticks."
func _check_two_active_builders_double_the_progress_rate() -> void:
	var world := _build_world(340003)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	world._colonists.append(_colonist("colonist_1", 1, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 2, "height": 1})
	_add_stock(world, "wood", 3, 0, 0)
	_add_stock(world, "stone", 4, 1, 0)
	var site_origin := Vector2i(10, 10)
	_command_ok(world, "wb", "build", {"kind": "workbench", "x": site_origin.x, "y": site_origin.y})
	var build_ticks := int(world._object_definitions["workbench"]["build_ticks"])
	var tick_both := -1
	var progress_both := -1
	for _i in MAX_TICKS:
		world.tick()
		var site := world.get_construction_site(site_origin.x, site_origin.y)
		if site.is_empty():
			_fail("the workbench site must still be under construction while waiting for both builders to join")
			return
		if (site["builder_ids"] as Array).size() == 2:
			tick_both = world.get_tick()
			progress_both = int(site["progress"])
			break
	_expect(tick_both >= 0, "both builders must simultaneously become active site_work builders within the tick budget")
	if tick_both < 0:
		return
	var sample_span := 20
	for _i in sample_span:
		world.tick()
	var site_after_span := world.get_construction_site(site_origin.x, site_origin.y)
	_expect(not site_after_span.is_empty(), "the site must not complete during the short two-builder sampling window")
	if not site_after_span.is_empty():
		_expect((site_after_span["builder_ids"] as Array).size() == 2, "both builders must remain active throughout the sampling window")
		_expect(int(site_after_span["progress"]) == progress_both + 2 * sample_span,
			"progress must climb by exactly 2 ticks per world tick while both builders are active (expected %d, got %d)"
				% [progress_both + 2 * sample_span, int(site_after_span["progress"])])
	var completed_tick := -1
	for _i in MAX_TICKS:
		world.tick()
		if world.get_construction_site(site_origin.x, site_origin.y).is_empty():
			completed_tick = world.get_tick()
			break
	_expect(completed_tick >= 0, "the workbench must complete within the tick budget")
	if completed_tick >= 0:
		var elapsed := completed_tick - tick_both
		var expected := int(ceil(float(build_ticks - progress_both) / 2.0))
		_expect(elapsed <= expected + 10,
			"two continuously active builders must finish in roughly (build_ticks - progress) / 2 ticks from the moment both joined, not build_ticks like a lone builder would (expected ~%d, got %d)"
				% [expected, elapsed])

## Acceptance: "one builder leaving mid-work (need interrupt) halves the rate
## again; the remaining builder's progress continues from its last value,
## never resetting or double-counting."
func _check_builder_leaving_mid_work_halves_rate_and_preserves_progress() -> void:
	var world := _build_world(340004)
	_isolate_need(world, "food")
	world._colonists.append(_colonist("colonist_0", 0, 0))
	world._colonists.append(_colonist("colonist_1", 1, 0))
	_command_ok(world, "zone", "zone_add", {"x": 0, "y": 0, "width": 2, "height": 1})
	_add_stock(world, "wood", 3, 0, 0)
	_add_stock(world, "stone", 4, 1, 0)
	# A genuinely reachable food source, so the critical interrupt actually
	# sends the leaving builder away rather than finding nothing to search
	# for and resuming in the same tick (colonist-ai.md 3.8's need_unmet
	# "keeps working" fallback, test_need_jobs.gd's own precedent).
	world._ground_berries["0_5"] = 1
	var site_origin := Vector2i(10, 10)
	_command_ok(world, "wb", "build", {"kind": "workbench", "x": site_origin.x, "y": site_origin.y})
	var builder_ids: Array = []
	for _i in MAX_TICKS:
		world.tick()
		var site := world.get_construction_site(site_origin.x, site_origin.y)
		if site.is_empty():
			_fail("the workbench site must still be under construction while waiting for both builders to join")
			return
		if (site["builder_ids"] as Array).size() == 2:
			builder_ids = (site["builder_ids"] as Array).duplicate()
			break
	_expect(builder_ids.size() == 2, "both builders must simultaneously become active site_work builders within the tick budget")
	if builder_ids.size() != 2:
		return
	for _i in 10:
		world.tick()
	var site_before := world.get_construction_site(site_origin.x, site_origin.y)
	_expect(not site_before.is_empty(), "the site must not complete before the interrupt is applied")
	if site_before.is_empty():
		return
	var progress_before_interrupt := int(site_before["progress"])
	var leaving_id := String(builder_ids[0])
	var staying_id := String(builder_ids[1])
	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == leaving_id:
			world._colonists[i]["needs"]["food"] = 5
	world.tick()
	var site_after_interrupt := world.get_construction_site(site_origin.x, site_origin.y)
	_expect(not site_after_interrupt.is_empty(), "the site must still be under construction right after the interrupt")
	if site_after_interrupt.is_empty():
		return
	var builder_ids_after: Array = site_after_interrupt["builder_ids"]
	_expect(not (leaving_id in builder_ids_after), "the interrupted builder must drop out of builder_ids immediately")
	_expect(builder_ids_after.size() == 1 and staying_id in builder_ids_after,
		"the remaining builder must stay the sole active builder after the interrupt (got %s)" % [builder_ids_after])
	_expect(int(site_after_interrupt["progress"]) == progress_before_interrupt + 1,
		"progress must advance by exactly 1 (the remaining builder alone) on the interrupt's own tick, never lost or duplicated (expected %d, got %d)"
			% [progress_before_interrupt + 1, int(site_after_interrupt["progress"])])
	var progress_at_interrupt := int(site_after_interrupt["progress"])
	var sample_span := 10
	for _i in sample_span:
		world.tick()
	var site_after_span := world.get_construction_site(site_origin.x, site_origin.y)
	_expect(not site_after_span.is_empty(), "the site must not complete during the short single-builder sampling window")
	if not site_after_span.is_empty():
		var builder_ids_span: Array = site_after_span["builder_ids"]
		_expect(builder_ids_span.size() == 1 and staying_id in builder_ids_span,
			"only the remaining builder may still be an active builder during the single-builder sampling window")
		_expect(int(site_after_span["progress"]) == progress_at_interrupt + sample_span,
			"progress must climb by exactly 1 tick per world tick with a single active builder (expected %d, got %d)"
				% [progress_at_interrupt + sample_span, int(site_after_span["progress"])])
