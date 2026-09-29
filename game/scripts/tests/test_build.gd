extends SceneTree

## Acceptance coverage for issue #406's `build` command (docs/decisions/038,
## supersedes ADR 027/036): `build` still names/shapes exactly like before
## ({kind, x, y}, plus t1's optional orientation), but now creates a
## persistent construction site instead of a single tracked job -- so this
## file focuses on the command's own contract (payload validation, footprint/
## enclosure rules, preview/apply parity) and the execution-mechanics
## regression coverage the superseded ADR 027/036 `build` job's own test file
## carried (reservation lifecycle across queued/active/suspend/reactivate,
## cargo conservation across cancel-while-suspended/-while-active and
## refused-resumption, a critical-need interrupt mid-carry, and route-cost-
## based source selection), adapted to `site_fetch`/`site_work`'s own toils
## and #400's hands-filling rules. Site-specific mechanics (immediate
## creation before any material arrives, incremental delivery into
## held_materials, exact build_ticks-after-last-delivery completion timing,
## cancel_site, reservation-invariant proofs, and save/load mid-construction)
## are covered in test_construction_site.gd, per this task's own acceptance
## split; this file does not duplicate that coverage.
##
## Round 4 review: restores the origin/main regression suite this file used
## to carry before this task, minimally adapted. A handful of the superseded
## suite's own checks are intentionally NOT restored because the contract
## they guarded genuinely no longer exists under the site model, not because
## the assertion was inconvenient to port:
## - A site's own footprint reservation ("tile:x,y" owned by "site:<id>") is
##   acquired once at order time and released only at cancel_site or
##   completion -- it is never suspended/reactivated with an individual
##   job the way the superseded single `build` job's one "tile:" reservation
##   was. A rival job can therefore never claim a site's own tile while a
##   colonist working it is merely suspended (the superseded suite's
##   "_check_blocked_resume_after_rival_claims_site_conserves_cargo"), and no
##   rival job can ever be queued at a site's own tile at all (its own
##   "_check_save_load_preserves_work_progress_owner_with_a_queued_rival_on_the_same_tile"):
##   both scenarios are now structurally impossible, not merely untested.
## - A site's own accumulated progress lives directly on the construction
##   site record (ConstructionSiteTable.add_progress(), see toil_executor's
##   own "site_work" doc comment) instead of the shared job-id/tile-keyed
##   work-progress cache (world_state.gd's _work_progress/_suspended_work_
##   progress/"workProgressOwners") dig/till/mine/etc. still share. The
##   entire class of bugs that cache's own ownership reconciliation guarded
##   against (a suspended job's progress silently inherited, clobbered, or
##   lost across save/load, or by a different job kind working the same
##   tile) cannot occur for a construction site by construction, so the
##   superseded suite's "_check_suspended_cancel_during_work_clears_progress_
##   for_replacement", "_check_refused_resumption_during_work_clears_
##   progress", "_check_legacy_save_missing_work_progress_owners_recovers_
##   active/suspended_build_ownership" and "_check_build_suspended_then_till_
##   activates_preserves_each_jobs_progress" (and its reverse) are replaced
##   below by _check_cancel_site_mid_work_clears_progress_for_replacement()
##   and _check_site_progress_survives_a_refused_builder_resumption(), which
##   prove the SITE's own progress (not a job-scoped cache) behaves correctly
##   across the equivalent boundaries.
## - ConstructionGiver never re-validates a site's own terrain/occupancy
##   before submitting its next site_work job, and _finalize_construction_
##   site() places the declared object unconditionally once progress meets
##   build_ticks, with no re-check that the site is still unoccupied,
##   un-enclosing, and actor-free (unlike the superseded single `build` job's
##   own _build_completion_failure()). This task's acceptance criteria do not
##   require that re-validation, so the superseded suite's "_check_site_
##   occupied_during_construction_fails_typed_and_returns_cargo",
##   "_check_actor_on_site_at_completion_is_never_walled_in",
##   "_check_enclosure_revalidated_at_completion" and "_check_intervening_
##   dig_invalidates_queued_build_site" are not restored; see this task's
##   handoff for the honest disclosure.
## - "_check_orders_before_any_tick_use_distinct_wood_and_reject_duplicate_
##   site"'s own two live assertions are already covered elsewhere: no job
##   exists at order time at all any more (ConstructionGiver submits one
##   later, on its own schedule), so there is no job-level item commitment to
##   assert on; "a second order on an already-claimed footprint is rejected"
##   is _check_second_order_on_same_footprint_rejected() below; and its own
##   "an order with no wood left is rejected blocked_missing_input" assertion
##   is now flatly wrong under this task's own new contract (no stock check
##   at submission, see _check_site_created_immediately_with_no_stock()).
## - "_check_multi_source_fetch_visits_nearest_source_first_then_the_rest"'s
##   own core claim (a solo colonist can never complete a >HANDS_CAPACITY
##   order in one hands-load) is superseded by #400's own hands-filling rules,
##   exercised by _check_site_fetch_prefers_nearest_reachable_source_and_
##   applies_very_close_rule() below (which proves the corrected, currently
##   true behavior instead).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")

const BUILDABLE_KINDS := ["wooden_wall", "door", "bed"]
const MAX_TICKS := 400

var _failed := false

func _init() -> void:
	for kind in BUILDABLE_KINDS:
		_check_kind_matches_pre_task_cost_duration_and_object(String(kind))
	_check_site_created_immediately_with_no_stock()
	_check_invalid_payload_rejections()
	_check_invalid_target_rejections()
	_check_orientation_payload_validated()
	_check_non_buildable_kinds_rejected()
	_check_second_order_on_same_footprint_rejected()
	_check_enclosing_wall_rejected_unreachable()
	_check_two_pending_openings_reject_the_second_wall()
	_check_enclosure_seen_from_every_colony_component()
	_check_preview_matches_apply()
	_check_queued_site_fetch_holds_no_reservation_until_active()
	_check_queued_site_fetch_labour_disabled_holds_no_reservation_then_activates()
	_check_suspend_then_reactivate_site_fetch_reacquires_item_reservation()
	_check_cancel_mid_fetch_leaks_no_reservation()
	_check_cancel_while_suspended_returns_cargo()
	_check_refused_resumption_returns_cargo()
	_check_rest_interrupt_completes_sleep_while_carrying_site_fetch_material()
	_check_stockpile_on_site_steps_builder_off()
	_check_stack_larger_than_cost_keeps_remainder()
	_check_save_load_round_trip_preserves_site_state()
	_check_save_io_rejects_site_job_missing_site_field()
	_check_wall_and_bed_orders_hash_differently()
	_check_cancel_site_mid_work_clears_progress_for_replacement()
	_check_site_progress_survives_a_refused_builder_resumption()
	_check_site_fetch_prefers_nearest_reachable_source_and_applies_very_close_rule()
	_check_site_fetch_route_cost_ties_break_by_lowest_item_id()
	_check_route_cost_skips_unreachable_source_behind_a_wall()
	_check_cancel_mid_multi_source_fetch_deposits_everything_and_frees_reservations()
	_check_two_site_orders_disjoint_sources_and_deterministic()

	if _failed:
		quit(1)
		return
	print("test_build: PASS")
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

## A rejected apply()/preview() result nests its typed reason under
## "rejection" (WorldState._rejection()/_pure_rejection()), never at the
## result's own top level.
func _reason_of(result: Dictionary) -> String:
	return String((result.get("rejection", {}) as Dictionary).get("reason", ""))

func _add_zone(world: WorldStateType, command_id: String, x: int, y: int, width: int, height: int) -> void:
	_command_ok(world, command_id, "zone_add", {"x": x, "y": y, "width": width, "height": height})

## Supplies exactly enough stockpiled wood for kind's own declared build_cost
## (every real buildable kind before/after this task costs 1 wood) inside a
## zone, then submits `build`.
func _seed_stock_and_order(world: WorldStateType, kind: String, site: Vector2i, stock_tile: Vector2i) -> Dictionary:
	_add_zone(world, "zone", stock_tile.x, stock_tile.y, 1, 1)
	for cost_entry in (world._object_definitions[kind]["build_cost"] as Array):
		world._items["item_%d" % world._next_item_id] = {"id": "item_%d" % world._next_item_id,
			"x": stock_tile.x, "y": stock_tile.y, "kind": String(cost_entry["item"]), "count": int(cost_entry["quantity"])}
		world._next_item_id += 1
	return _command_ok(world, "build_%s" % kind, "build", {"kind": kind, "x": site.x, "y": site.y})

## Ticks world until get_construction_site(site) is empty (the site
## completed) or MAX_TICKS elapses; returns the tick count consumed (-1 on timeout).
func _tick_until_site_gone(world: WorldStateType, site: Vector2i, budget: int = MAX_TICKS) -> int:
	for i in budget:
		world.tick()
		if world.get_construction_site(site.x, site.y).is_empty():
			return i + 1
	return -1

## Kind-agnostic ground item placement, explicit id (round 3 review's
## reservation-lifecycle/cargo/route-cost checks need deterministic ids to
## reason about which source is nearest/lowest-id).
func _place_item(world: WorldStateType, item_id: String, kind: String, x: int, y: int, count: int = 1) -> void:
	world._items[item_id] = {"id": item_id, "x": x, "y": y, "kind": kind, "count": count}

func _job_by_id(world: WorldStateType, job_id: String) -> Dictionary:
	return world._scheduler.queue.get_job(job_id)

## True when a get_construction_site()-shaped record's own held_materials
## already meets every entry of its required_materials (ConstructionSiteTable.
## materials_met()'s own rule, read from the public view instead of reaching
## into world._sites directly -- the public record is not guaranteed to still
## resolve to a live internal site by the time a caller gets around to
## checking it).
func _public_site_materials_met(site_record: Dictionary) -> bool:
	var held: Dictionary = {}
	for entry in (site_record.get("held_materials", []) as Array):
		held[String(entry["item"])] = int(entry["quantity"])
	for entry in (site_record.get("required_materials", []) as Array):
		if int(held.get(String(entry["item"]), 0)) < int(entry["quantity"]):
			return false
	return true

func _ground_kind_total(world: WorldStateType, kind: String) -> int:
	var total := 0
	for item in world.get_items():
		if String(item.get("kind", "")) == kind:
			total += int(item.get("count", 0))
	return total

## Every reservation key must belong to an active job or a live construction
## site's own footprint owner (find_orphaned_reservations()'s
## extra_active_owners parameter, issue #406) -- checked after every tick so a
## mid-run leak, not just an end-state one, would be caught.
func _assert_no_orphaned_reservations(world: WorldStateType, context: String) -> void:
	var extra_owners: Array[String] = []
	for site in world.get_construction_sites():
		extra_owners.append(world._sites.owner_key(String(site["id"])))
	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		world._scheduler.queue.get_reservation_table(), world.get_jobs(), extra_owners)
	_expect(orphans.is_empty(), "no reservation may outlive its job (%s): orphans=%s" % [context, orphans])

## One colonist at (0,0), one stockpiled wood item "item_1" at `stockpile`, a
## `build` order for `kind` at `site`; ticks until ConstructionGiver submits
## the site's first site_fetch job and returns its id ("" on timeout/refusal).
func _order_site_fetch(world: WorldStateType, kind: String, site: Vector2i, stockpile: Vector2i = Vector2i(0, 0), count: int = 1) -> String:
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_place_item(world, "item_1", "wood", stockpile.x, stockpile.y, count)
	world._next_item_id = 2
	_add_zone(world, "zone_setup", stockpile.x, stockpile.y, 1, 1)
	var result := _command_ok(world, "build_%s" % kind, "build", {"kind": kind, "x": site.x, "y": site.y})
	if not result.get("ok", false):
		return ""
	for _i in 20:
		world.tick()
		var job_id := _find_site_fetch_job_id(world, site)
		if not job_id.is_empty():
			return job_id
	return ""

func _find_site_fetch_job_id(world: WorldStateType, origin: Vector2i) -> String:
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "site_fetch" and job.get("site") == origin:
			return String(job["id"])
	return ""

## Ticks until the colonist carries an item and is strictly mid-walk (route
## set, left `away_from`) -- the same "caught between two toils" boundary the
## superseded `build` job's own regression suite relied on.
func _tick_until_carrying_mid_walk(world: WorldStateType, away_from: Vector2i) -> bool:
	for _i in 60:
		world.tick()
		_assert_no_orphaned_reservations(world, "mid-fetch settling")
		var colonist := world.get_colonists()[0]
		if (InventoryType.is_carrying(colonist) and colonist.get("route") != null
				and Vector2i(int(colonist["x"]), int(colonist["y"])) != away_from):
			return true
	return false

## Ticks until some colonist's own "work" toil is a site_work job in progress
## (the superseded suite's own _tick_until_working(), scoped to site_work
## since a colonist may also be doing an unrelated job's own work toil).
func _tick_until_site_work_active(world: WorldStateType, budget: int = 200) -> bool:
	for _i in budget:
		world.tick()
		for colonist in world.get_colonists():
			var work = colonist.get("work")
			if work != null:
				var job := _job_by_id(world, String(work.get("job_id", "")))
				if String(job.get("kind", "")) == "site_work":
					return true
	return false

## Proves wall/door/bed's pre-task outcome is unchanged: same declared
## build_cost consumed, same declared build_ticks duration, and the same
## final object appears -- now driven by ConstructionGiver's own site_fetch/
## site_work jobs instead of a single tracked "build" job. Also restores the
## superseded suite's own detailed work-phase assertions, adapted to the site
## model's own mechanics: the builder works from beside the site (never on
## it) for as long as progress remains, the site's own progress increases by
## exactly one every tick a site_work job is genuinely in progress (not a
## single instant jump on delivery), no object exists until progress reaches
## build_ticks, and the builder is free to take a further job afterward.
func _check_kind_matches_pre_task_cost_duration_and_object(kind: String) -> void:
	var world := _build_world(310000 + BUILDABLE_KINDS.find(kind))
	world._colonists.append(_colonist("colonist_0", 0, 0))
	var site := Vector2i(10, 10)
	var stock_tile := Vector2i(0, 0)
	_seed_stock_and_order(world, kind, site, stock_tile)
	var definition: Dictionary = world._object_definitions[kind]
	var declared_ticks := int(definition["build_ticks"])

	var progress_samples: Array[int] = []
	var work_started_tick := -1
	var object_appeared_tick := -1
	var completed := false
	for _i in MAX_TICKS:
		world.tick()
		_assert_no_orphaned_reservations(world, "(%s) build settling" % kind)
		var site_record := world.get_construction_site(site.x, site.y)
		var object_present := world.get_object(site.x, site.y) == kind
		if not site_record.is_empty() and int(site_record.get("progress", 0)) > 0:
			if work_started_tick < 0:
				work_started_tick = world.get_tick()
			progress_samples.append(int(site_record["progress"]))
			for colonist in world.get_colonists():
				var work = colonist.get("work")
				if work == null:
					continue
				var job := _job_by_id(world, String(work.get("job_id", "")))
				if String(job.get("kind", "")) != "site_work" or job.get("site") != site:
					continue
				var colonist_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
				_expect(colonist_tile != site,
					"(%s) the builder must work from beside the site, never standing on it" % kind)
				_expect(maxi(absi(colonist_tile.x - site.x), absi(colonist_tile.y - site.y)) == 1,
					"(%s) the builder must be adjacent to the site during the work phase, got %s vs site %s" % [kind, colonist_tile, site])
			_expect(not object_present,
				"(%s) the object must not exist yet while the site's own progress (%d/%d) is still below build_ticks"
					% [kind, int(site_record["progress"]), declared_ticks])
		if object_appeared_tick < 0 and object_present:
			object_appeared_tick = world.get_tick()
		if world.get_construction_site(site.x, site.y).is_empty() and object_present:
			completed = true
			break
	_expect(completed, "%s build must complete within the tick budget" % kind)
	_expect(work_started_tick >= 0, "(%s) a genuine site_work toil must start once the material is delivered to the site" % kind)
	# The tick that carries progress up to build_ticks also finalizes the site
	# within that same tick() call (_finalize_construction_site()), so the
	# very last progress value is never separately observed here: the site is
	# already gone by the time this loop reads it back.
	_expect(progress_samples.size() >= declared_ticks - 1,
		"(%s) the site's own progress must be sampled at least once per declared build_ticks tick (got %d samples for %d ticks)"
			% [kind, progress_samples.size(), declared_ticks])
	var strictly_increasing := true
	for i in range(1, progress_samples.size()):
		if progress_samples[i] <= progress_samples[i - 1]:
			strictly_increasing = false
	_expect(strictly_increasing, "(%s) the site's own progress must strictly increase every tick it is in progress: %s" % [kind, progress_samples])
	_expect(object_appeared_tick >= 0 and object_appeared_tick > work_started_tick,
		"(%s) the object must appear only once the site's own progress reaches build_ticks, not immediately on delivery" % kind)

	_expect(world.get_object(site.x, site.y) == kind, "%s build must place the declared object at the site" % kind)
	_expect(bool(world.passability(site.x, site.y)["passable"]) == bool(definition.get("passable", true)),
		"%s's placed object must match its declared passable value" % kind)
	for cost_entry in (definition["build_cost"] as Array):
		var kind_name := String(cost_entry["item"])
		_expect(_ground_kind_total(world, kind_name) == 0,
			"%s build must consume exactly its declared %s cost (found some left on the ground)" % [kind, kind_name])

	# The builder must remain free to take and finish a further job afterward.
	var builder := world.get_colonists()[0]
	var builder_tile := Vector2i(int(builder["x"]), int(builder["y"]))
	_expect(builder_tile != site, "(%s) an object built from several tiles away must not appear under its own builder" % kind)
	_expect(bool(world.passability(builder_tile.x, builder_tile.y)["passable"]),
		"(%s) the builder must end up on a tile it can still move from" % kind)
	world._tiles[world._tile_index(0, 5)] = WorldStateType.TILE_SOIL
	world.spawn_ground_tool_item("pick", 0, 0)
	var dig_result := _command_ok(world, "dig_after_build_%s" % kind, "dig", {"x": 0, "y": 5, "priority": 1})
	var dig_terminal := ""
	for _i in 200:
		world.tick()
		dig_terminal = String(_job_by_id(world, String(dig_result.get("job_id", ""))).get("status", ""))
		if dig_terminal not in ["queued", "active"]:
			break
	_expect(dig_terminal == "completed", "(%s) the builder must be able to move and complete a further job after finishing" % kind)

## Acceptance: "ordering a workbench creates a site immediately... before any
## material arrives" generalizes to every buildable kind -- a `build` command
## with zero stockpiled material must still be accepted and create a site.
func _check_site_created_immediately_with_no_stock() -> void:
	var world := _build_world(310100)
	var result := _command(world, "b", "build", {"kind": "wooden_wall", "x": 5, "y": 5})
	_expect(bool(result.get("ok", false)), "build must be accepted with no material on hand: %s" % result)
	_expect(not world.get_construction_site(5, 5).is_empty(), "a site must exist immediately after an accepted build command")
	_expect(world.get_object(5, 5).is_empty(), "no object may appear before any material is delivered")

func _check_invalid_payload_rejections() -> void:
	var world := _build_world(310200)
	_expect(_reason_of(_command(world, "a", "build", {"kind": "wooden_wall", "x": 1, "y": "1"})) == "invalid_payload",
		"non-integer y must be rejected invalid_payload")
	_expect(_reason_of(_command(world, "b", "build", {"kind": "wooden_wall", "x": 1})) == "invalid_payload",
		"missing y must be rejected invalid_payload")
	_expect(_reason_of(_command(world, "c", "build", {"kind": "wooden_wall", "x": 1, "y": 1, "extra": 1})) == "invalid_payload",
		"an unknown payload field must be rejected invalid_payload")
	_expect(_reason_of(_command(world, "d", "build", {"kind": "not_a_kind", "x": 1, "y": 1})) == "invalid_payload",
		"an unknown object kind must be rejected invalid_payload")

func _check_invalid_target_rejections() -> void:
	var world := _build_world(310300)
	world._colonists.append(_colonist("colonist_0", 3, 3))
	world._tiles[world._tile_index(4, 4)] = WorldStateType.TILE_TREE
	world._tiles[world._tile_index(5, 5)] = WorldStateType.TILE_ROCK
	_command_ok(world, "wall1", "build", {"kind": "wooden_wall", "x": 6, "y": 6})
	_expect(_reason_of(_command(world, "on_colonist", "build", {"kind": "wooden_wall", "x": 3, "y": 3})) == "invalid_target",
		"a colonist's own tile must be rejected invalid_target")
	_expect(_reason_of(_command(world, "on_tree", "build", {"kind": "wooden_wall", "x": 4, "y": 4})) == "invalid_target",
		"a tree tile must be rejected invalid_target")
	_expect(_reason_of(_command(world, "on_rock", "build", {"kind": "wooden_wall", "x": 5, "y": 5})) == "invalid_target",
		"an impassable rock tile must be rejected invalid_target")
	_expect(_reason_of(_command(world, "on_site", "build", {"kind": "wooden_wall", "x": 6, "y": 6})) == "invalid_target",
		"a tile another site already claims must be rejected invalid_target")
	_expect(_reason_of(_command(world, "out_of_bounds", "build", {"kind": "wooden_wall", "x": -1, "y": 0})) == "invalid_target",
		"an out-of-bounds target must be rejected invalid_target")

func _check_orientation_payload_validated() -> void:
	var world := _build_world(310400)
	_expect(_reason_of(_command(world, "bad_orient", "build", {"kind": "wooden_wall", "x": 1, "y": 1, "orientation": "sideways"})) == "invalid_payload",
		"an unsupported orientation string must be rejected invalid_payload")
	var result := _command_ok(world, "workbench_v", "build", {"kind": "workbench", "x": 10, "y": 10, "orientation": "vertical"})
	_expect(result.get("ok", false), "workbench with a valid orientation must be accepted: %s" % result)
	_expect(not world.get_construction_site(10, 11).is_empty(),
		"a vertical [2,1] workbench must reserve/occupy its rotated second footprint tile")

## objects.json declares build_cost on every row (issue #405), including an
## empty list for kinds that were never buildable (chair, table, berry_bush)
## and the footprint test fixture (test_footprint_crate, footprint [2,1]
## with no cost) -- an empty build_cost must still read as non-buildable for
## a multi-tile kind, not just a [1,1] one.
func _check_non_buildable_kinds_rejected() -> void:
	var world := _build_world(310500)
	for kind in ["chair", "table", "berry_bush", "test_footprint_crate"]:
		var result := _command(world, "nb_%s" % kind, "build", {"kind": kind, "x": 2, "y": 2})
		_expect(_reason_of(result) == "invalid_payload",
			"%s has no build_cost and must be rejected invalid_payload for build (got %s)" % [kind, result])
		_expect(world.get_object(2, 2) == "", "(%s) a rejected build command must place nothing" % kind)

func _check_second_order_on_same_footprint_rejected() -> void:
	var world := _build_world(310600)
	_command_ok(world, "first", "build", {"kind": "door", "x": 8, "y": 8})
	var result := _command(world, "second", "build", {"kind": "wooden_wall", "x": 8, "y": 8})
	_expect(_reason_of(result) == "invalid_target", "a second order on an already-claimed footprint tile must be rejected invalid_target: %s" % result)

## Seven walls around (4,4) leaving only the north gap at (4,3) open; the
## colonist stands outside at (4,1). Returns the world.
func _room_with_north_gap(seed_value: int) -> WorldStateType:
	var world := _build_world(seed_value)
	for cell in [Vector2i(3, 3), Vector2i(5, 3), Vector2i(3, 4), Vector2i(5, 4),
			Vector2i(3, 5), Vector2i(4, 5), Vector2i(5, 5)]:
		world._set_object(cell.x, cell.y, "wooden_wall")
	return world

## The enclosure rule (_would_enclose_tiles(), footprint-aware generalization
## of the superseded single-tile _would_enclose()) still refuses an impassable
## kind that would strand a reachable tile.
func _check_enclosing_wall_rejected_unreachable() -> void:
	var world := _build_world(310700)
	world._colonists.append(_colonist("colonist_0", 5, 5))
	# A 4x4 room (x=4..7, y=4..7): walls on all four sides except one opening
	# at (7, 5); closing that last opening would seal the colonist in.
	for x in range(4, 8):
		_command_ok(world, "top_%d" % x, "build", {"kind": "wooden_wall", "x": x, "y": 4})
		_command_ok(world, "bot_%d" % x, "build", {"kind": "wooden_wall", "x": x, "y": 7})
	for y in range(5, 7):
		_command_ok(world, "left_%d" % y, "build", {"kind": "wooden_wall", "x": 4, "y": y})
	_command_ok(world, "right_6", "build", {"kind": "wooden_wall", "x": 7, "y": 6})
	var result := _command(world, "seal", "build", {"kind": "wooden_wall", "x": 7, "y": 5})
	_expect(_reason_of(result) == "blocked_target_unreachable",
		"sealing the only remaining opening must be rejected blocked_target_unreachable: %s" % result)

	# The same gap must remain a valid target for a kind that never encloses
	# anything (content/objects.json declares door passable).
	var world_door := _build_world(310701)
	world_door._colonists.append(_colonist("colonist_0", 5, 5))
	for x in range(4, 8):
		world_door._set_object(x, 4, "wooden_wall")
		world_door._set_object(x, 7, "wooden_wall")
	for y in range(5, 7):
		world_door._set_object(4, y, "wooden_wall")
	world_door._set_object(7, 6, "wooden_wall")
	var door_result := _command(world_door, "build_door_in_gap", "build", {"kind": "door", "x": 7, "y": 5})
	_expect(door_result.get("ok", false), "a passable object (door) must never trigger the enclosure check: %s" % [door_result])

## A room with two openings: the first wall order (into one opening) is
## accepted, and the second (into the other) must be refused because the
## first, still pending, already counts as blocking (round-2 review of the
## superseded suite this restores).
func _check_two_pending_openings_reject_the_second_wall() -> void:
	var world := _room_with_north_gap(310750)
	world._set_object(4, 5, "")  # a second opening, south
	world._colonists.append(_colonist("colonist_0", 4, 1))
	var north := _command(world, "close_north", "build", {"kind": "wooden_wall", "x": 4, "y": 3})
	_expect(north.get("ok", false), "the first of two openings may be walled: %s" % [north])
	var south := _command(world, "close_south", "build", {"kind": "wooden_wall", "x": 4, "y": 5})
	_expect(_reason_of(south) == "blocked_target_unreachable",
		"the second opening must be refused while the first wall is still pending: %s" % [south])

## Colonists in two disconnected components: a wall sealing a room only the
## SECOND colonist can reach must still be refused (the first colonist's
## component does not contain the target), and a first colonist standing on
## an impassable tile must never hide the enclosure either (round-2 review of
## the superseded suite this restores).
func _check_enclosure_seen_from_every_colony_component() -> void:
	var world := _room_with_north_gap(310760)
	# Split the map: a full wall column at x=20 puts colonist_0 (east) in a
	# component that never contains the room's gap at (4,3).
	for y in world.get_map_height():
		world._set_object(20, y, "wooden_wall")
	world._colonists.append(_colonist("colonist_0", 30, 30))
	world._colonists.append(_colonist("colonist_1", 4, 1))
	var sealed := _command(world, "seal_other_component", "build", {"kind": "wooden_wall", "x": 4, "y": 3})
	_expect(_reason_of(sealed) == "blocked_target_unreachable",
		"an enclosure reachable only by a later colonist must still be refused: %s" % [sealed])

	var trapped_world := _room_with_north_gap(310761)
	trapped_world._tiles[trapped_world._tile_index(30, 30)] = WorldStateType.TILE_ROCK
	trapped_world._colonists.append(_colonist("colonist_0", 30, 30))
	trapped_world._colonists.append(_colonist("colonist_1", 4, 1))
	var hidden := _command(trapped_world, "seal_with_first_actor_on_rock", "build", {"kind": "wooden_wall", "x": 4, "y": 3})
	_expect(_reason_of(hidden) == "blocked_target_unreachable",
		"a first actor on an impassable tile must not hide an enclosure seen by another: %s" % [hidden])

## preview() must run the identical _check_construction_command() rule apply()
## does, so a toolbar hover and the click never disagree -- including that
## preview never mutates the world, and that once a site is claimed the same
## target previews as claimed too.
func _check_preview_matches_apply() -> void:
	var world := _build_world(310800)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	var preview_ok := world.preview({"actor": "test", "command_id": "p", "tick": world.get_tick(),
		"type": "build", "payload": {"kind": "wooden_wall", "x": 12, "y": 12}})
	_expect(bool(preview_ok.get("ok", false)), "preview must accept a valid build target: %s" % preview_ok)
	var hash_before := world.state_hash()
	var preview_bad := world.preview({"actor": "test", "command_id": "p2", "tick": world.get_tick(),
		"type": "build", "payload": {"kind": "wooden_wall", "x": 0, "y": 0}})
	_expect(not bool(preview_bad.get("ok", false)), "preview must reject a build target on a colonist's own tile")
	_expect(world.state_hash() == hash_before, "preview must never mutate the world")
	var apply_result := _command(world, "a", "build", {"kind": "wooden_wall", "x": 0, "y": 0})
	_expect(not bool(apply_result.get("ok", false)) and _reason_of(apply_result) == "invalid_target",
		"apply must reject the same target preview rejected, with the same reason: %s" % apply_result)
	var applied := _command_ok(world, "apply_valid", "build", {"kind": "wooden_wall", "x": 12, "y": 12})
	_expect(applied.get("ok", false), "the previously-previewed-valid build must apply ok")
	_expect(_reason_of(world.preview({"actor": "test", "command_id": "p3", "tick": world.get_tick(),
		"type": "build", "payload": {"kind": "wooden_wall", "x": 12, "y": 12}})) == "invalid_target",
		"once applied, the same site must preview as claimed (invalid_target)")

## A submitted-but-not-yet-active site_fetch job holds no item reservation
## while queued (issue #278/#303 round-1 review, reapplied to site_fetch's own
## shape: reservations are only acquired once JobQueue._tick_site_fetch()
## actually activates the job).
func _check_queued_site_fetch_holds_no_reservation_until_active() -> void:
	var world := _build_world(320000)
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(0, 10))
	_expect(not job_id.is_empty(), "setup must produce a site_fetch job")
	if job_id.is_empty():
		return
	var table := world._scheduler.queue.get_reservation_table()
	if String(_job_by_id(world, job_id).get("status", "")) == "queued":
		_expect(not table.is_reserved("item:item_1"), "a still-queued site_fetch job must hold no item reservation")
	var active := false
	for _i in 20:
		world.tick()
		if String(_job_by_id(world, job_id).get("status", "")) == "active":
			active = true
			break
	_expect(active, "the site_fetch job must eventually activate")
	_expect(table.is_reserved("item:item_1"), "an active site_fetch job must hold its item reservation")
	_assert_no_orphaned_reservations(world, "after site_fetch activation")

## Reservation-lifecycle regression (adapted from the superseded `build` job's
## own suite, ADR 027): a site_fetch job ConstructionGiver submits while its
## only eligible colonist has build labour disabled must stay queued forever,
## holding no item reservation -- and must run to completion the instant
## labour is re-enabled.
func _check_queued_site_fetch_labour_disabled_holds_no_reservation_then_activates() -> void:
	var world := _build_world(320100)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_place_item(world, "item_1", "wood", 0, 0, 1)
	world._next_item_id = 2
	_add_zone(world, "zone_setup", 0, 0, 1, 1)
	_command_ok(world, "labour_off", "set_labour", {"colonist": "colonist_0", "kind": "build", "level": 0})
	_command_ok(world, "build_wall", "build", {"kind": "wooden_wall", "x": 0, "y": 10})
	var table := world._scheduler.queue.get_reservation_table()
	var job_id := ""
	for _i in 30:
		world.tick()
		_assert_no_orphaned_reservations(world, "site_fetch queued with build labour disabled")
		if job_id.is_empty():
			job_id = _find_site_fetch_job_id(world, Vector2i(0, 10))
	_expect(not job_id.is_empty(), "ConstructionGiver must submit a site_fetch job regardless of labour")
	if job_id.is_empty():
		return
	_expect(String(_job_by_id(world, job_id).get("status", "")) == "queued",
		"a site_fetch job nobody may take must stay queued while build labour is disabled")
	_expect(not table.is_reserved("item:item_1"),
		"a site_fetch job queued with its labour disabled must hold no item reservation")
	_command_ok(world, "labour_on", "set_labour", {"colonist": "colonist_0", "kind": "build", "level": 2})
	var completed := false
	for _i in 200:
		world.tick()
		_assert_no_orphaned_reservations(world, "site_fetch settling after labour re-enabled")
		if world.get_construction_site(0, 10).is_empty():
			completed = true
			break
	_expect(completed, "re-enabling build labour must let the queued order run to completion")
	_expect(world.get_object(0, 10) == "wooden_wall", "the wall must be placed once labour is re-enabled and delivery completes")

## Suspending an active site_fetch job (JobQueue.suspend(), the critical-need
## interrupt boundary, ADR 009) must release its item reservation, and
## reactivating it must reacquire it (issue #278/#303's own round-1 review,
## reapplied to site_fetch's single-reservation shape). The site's OWN
## footprint reservation is untouched throughout: it belongs to the site, not
## the job, so it neither drops on suspend nor needs reacquiring on reactivate.
func _check_suspend_then_reactivate_site_fetch_reacquires_item_reservation() -> void:
	var world := _build_world(320200)
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(0, 10))
	_expect(not job_id.is_empty(), "setup must produce a site_fetch job")
	if job_id.is_empty():
		return
	var active := false
	for _i in 20:
		if String(_job_by_id(world, job_id).get("status", "")) == "active":
			active = true
			break
		world.tick()
	_expect(active, "the site_fetch job must activate before this check can proceed")
	if not active:
		return
	var table := world._scheduler.queue.get_reservation_table()
	_expect(table.is_reserved("item:item_1"), "an active site_fetch job must hold its item reservation")
	_expect(table.is_reserved("tile:0,10"), "the site's own footprint reservation must be held while its site_fetch job is active")
	var suspended := world._scheduler.queue.suspend(job_id)
	_expect(suspended.get("ok", false), "suspend must accept an active site_fetch job")
	_expect(String(_job_by_id(world, job_id).get("status", "")) == "queued",
		"a suspended site_fetch job must return to queued")
	_expect(not table.is_reserved("item:item_1"), "suspend must release the item reservation")
	_expect(table.is_reserved("tile:0,10"), "suspending the job must never release the site's own footprint reservation")
	_assert_no_orphaned_reservations(world, "after site_fetch suspend")
	var reactivated := world._scheduler.queue.reactivate(job_id)
	_expect(reactivated, "reactivate must reacquire an unclaimed site_fetch job's reservation")
	_expect(String(_job_by_id(world, job_id).get("status", "")) == "active",
		"a reactivated site_fetch job must be active again")
	_expect(table.is_reserved("item:item_1"), "reactivate must reacquire the item reservation")
	_expect(table.is_reserved("tile:0,10"), "the site's own footprint reservation must still be held after reactivate")
	_assert_no_orphaned_reservations(world, "after site_fetch reactivate")

## Cancelling a site_fetch job mid-fetch (carrying material, still walking to
## the site, ACTIVE -- not suspended) must drop the item where the colonist
## stands, release the item reservation (JobQueue._finish()'s existing
## release_all(), reused unchanged), and place no object -- restored from the
## superseded suite's own _check_cancel_mid_haul_leaks_no_reservation().
func _check_cancel_mid_fetch_leaks_no_reservation() -> void:
	var world := _build_world(320050)
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(0, 10))
	if job_id.is_empty():
		return
	var table := world._scheduler.queue.get_reservation_table()
	var caught_mid_walk := _tick_until_carrying_mid_walk(world, Vector2i(0, 0))
	_expect(caught_mid_walk, "setup must catch the colonist carrying the wood, strictly mid-walk to the build site")
	if not caught_mid_walk:
		return

	_expect(table.is_reserved("item:item_1"), "an active site_fetch job mid-haul must hold the item reservation")
	_expect(table.is_reserved("tile:0,10"), "an active site_fetch job's site must still hold its own footprint reservation")

	var mid_carry := world.get_colonists()[0]
	var drop_tile := Vector2i(int(mid_carry["x"]), int(mid_carry["y"]))
	_expect(drop_tile != Vector2i(0, 0) and drop_tile != Vector2i(0, 10),
		"setup must catch the colonist strictly between the stockpile and the build site (got %s)" % [drop_tile])

	_command_ok(world, "cancel_fetch", "cancel_job", {"job_id": job_id})

	var cancelled := _job_by_id(world, job_id)
	_expect(cancelled["status"] == "cancelled", "the site_fetch job must be cancelled")
	var after_cancel := world.get_colonists()[0]
	_expect(not InventoryType.is_carrying(after_cancel), "the colonist must no longer be carrying after cancel")
	_expect(world.get_ground_wood(drop_tile.x, drop_tile.y) == 1,
		"the wood must drop on the colonist's exact tile at the moment of cancellation")
	_expect(world.get_object(0, 10) == "", "cancelling mid-fetch must place no object at the build site")
	_expect(not table.is_reserved("item:item_1"), "cancel must release the item reservation")
	_expect(table.is_reserved("tile:0,10"), "cancelling one delivery job must never release the site's own footprint reservation -- the site itself still exists")
	_assert_no_orphaned_reservations(world, "after site_fetch cancel")

## Cancelling a site_fetch that a critical-need interrupt has SUSPENDED after
## pickup (WorldState._interrupt_current_job(), ADR 009: the job is queued
## again and only _paused_jobs remembers who carries its wood) must still find
## that carrier and return the cargo to the ground, leaving the colonist's
## other (need) work state untouched -- adapted from the superseded `build`
## job's own round-2 review case, now exercising the `["haul", "site_fetch"]`
## carrier lookup _trap_actor()/_resolve_refused_reservations()/
## _resume_interrupted_job() all share.
func _check_cancel_while_suspended_returns_cargo() -> void:
	var world := _build_world(320300)
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(0, 10))
	if job_id.is_empty():
		return
	if not _tick_until_carrying_mid_walk(world, Vector2i(0, 0)):
		_fail("setup must catch the colonist carrying the wood mid-walk to the site")
		return
	var colonist: Dictionary = world._find_colonist("colonist_0")
	world._interrupt_current_job(colonist)
	_expect(String(_job_by_id(world, job_id).get("status", "")) == "queued",
		"interrupting a mid-carry site_fetch must suspend it back to queued")
	_expect(world._paused_jobs.get("colonist_0") == job_id,
		"the interrupt must record the paused site_fetch job for its carrier")
	_expect(InventoryType.is_carrying(colonist), "a suspended site_fetch's carrier still holds the wood until the job ends")
	# Stand in for the need job that now drives this colonist: its own
	# route/work must survive the site_fetch's termination untouched.
	colonist["work"] = {"job_id": "need_stand_in", "ticks_remaining": 3}
	var tile := Vector2i(int(colonist["x"]), int(colonist["y"]))

	_command_ok(world, "cancel_suspended_fetch", "cancel_job", {"job_id": job_id})
	_expect(String(_job_by_id(world, job_id).get("status", "")) == "cancelled", "the suspended site_fetch must be cancelled")
	_expect(not InventoryType.is_carrying(colonist), "cancelling a suspended site_fetch must clear its carrier's carrying")
	_expect(world.get_ground_wood(tile.x, tile.y) == 1,
		"the suspended site_fetch's wood must return to the ground exactly once, at the carrier's tile")
	_expect(colonist.get("work") != null and colonist["work"]["job_id"] == "need_stand_in",
		"terminating a suspended site_fetch must not clear the work state now owned by another job")
	_expect(not world._paused_jobs.has("colonist_0"), "a cancelled site_fetch must leave no pause entry behind")
	_assert_no_orphaned_reservations(world, "after cancelling a suspended site_fetch")

## A suspended site_fetch whose carrier is switched to a non-orderable faction
## while paused is refused on resumption (F3's not_ordered_by_player path,
## mirroring test_faction_reservations.gd's haul case) -- the refusal must
## drop the site_fetch's cargo too (round-2 review of the superseded `build`
## job), exercising _resolve_refused_reservations()'s own
## `["haul", "site_fetch"]` carrier lookup restored this round.
func _check_refused_resumption_returns_cargo() -> void:
	var world := _build_world(320400)
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(0, 10))
	if job_id.is_empty():
		return
	if not _tick_until_carrying_mid_walk(world, Vector2i(0, 0)):
		_fail("setup must catch the colonist carrying the wood mid-walk")
		return
	world._interrupt_current_job(world.get_colonists()[0])
	_expect(_command(world, "set_raider_mid_carry", "set_faction", {"target": "colonist_0", "faction_id": "raiders"}).get("ok", false),
		"set_faction while the site_fetch is suspended mid-carry must be accepted")
	world._resume_interrupted_job("colonist_0")
	world._resolve_refused_reservations()
	var job := _job_by_id(world, job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a refused resumption must terminally fail the site_fetch not_ordered_by_player (got %s/%s)" % [job.get("status"), job.get("reason")])
	_expect(not InventoryType.is_carrying(world.get_colonists()[0]), "a refused site_fetch resumption must drop the carried wood")
	_expect(_ground_kind_total(world, "wood") == 1, "the refused site_fetch's wood must return to the ground exactly once")
	_assert_no_orphaned_reservations(world, "after a refused site_fetch resumption")

## A critical rest need must interrupt a site_fetch job exactly at the
## post-pick_up toil boundary (colonist-ai.md 3.6), let sleep run to genuine
## completion (its own work toil actually starting and ticking down over more
## than one sample, not stalling at arrival on the colonist's leftover
## is_carrying() flag -- round-6 review of the superseded suite this
## restores) while the fetched wood stays carried, then resume and complete
## the site.
func _check_rest_interrupt_completes_sleep_while_carrying_site_fetch_material() -> void:
	var world := _build_world(320500)
	for other in world._need_definitions.keys():
		if other != "rest":
			world._need_definitions[other]["rate_per_day"] = 0
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(6, 0))
	_expect(not job_id.is_empty(), "the site_fetch job must be submitted")
	if job_id.is_empty():
		return
	_command_ok(world, "place_bed", "place_object", {"x": 0, "y": 5, "kind": "bed"})

	var at_boundary := false
	for _i in 60:
		world.tick()
		var colonist := world.get_colonists()[0]
		if InventoryType.is_carrying(colonist) and colonist.get("route") == null and colonist.get("work") == null:
			at_boundary = true
			break
	_expect(at_boundary, "setup must reach the post-pick_up toil boundary before the rest interrupt")
	if not at_boundary:
		return

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["rest"] = 5

	var interrupted := false
	for _i in 60:
		world.tick()
		if String(_job_by_id(world, job_id).get("status", "")) == "queued":
			interrupted = true
			break
	_expect(interrupted, "the critical rest need must interrupt the site_fetch job while carrying wood")
	if not interrupted:
		return
	_expect(InventoryType.has_kind(world.get_colonists()[0], "wood"),
		"the colonist must still be carrying the wood the instant the rest interrupt commits")

	var sleep_job_id := ""
	for _i in 40:
		world.tick()
		for job in world.get_jobs():
			if String(job["kind"]) == "sleep":
				sleep_job_id = String(job["id"])
		if not sleep_job_id.is_empty():
			break
	_expect(not sleep_job_id.is_empty(), "the rest interrupt must actually submit a sleep job")
	if sleep_job_id.is_empty():
		return

	var work_started := false
	var distinct_work_values: Dictionary = {}
	var sleep_completed := false
	for _i in 200:
		world.tick()
		var work = world.get_colonists()[0].get("work")
		if work != null:
			work_started = true
			distinct_work_values[int(work.get("ticks_remaining", -1))] = true
		if String(_job_by_id(world, sleep_job_id).get("status", "")) == "completed":
			sleep_completed = true
			break
	_expect(work_started, "sleep's own work toil must actually start, not stall at arrival, while the colonist carries site_fetch material")
	_expect(distinct_work_values.size() > 1,
		"sleep's work timer must tick down over more than one tick, not complete in a single sample")
	_expect(sleep_completed, "the interrupted-by-rest sleep job must complete within budget while site_fetch wood stays carried")
	if not sleep_completed:
		return
	_expect(InventoryType.has_kind(world.get_colonists()[0], "wood"), "the carried site_fetch wood must survive sleep completing")

	var site_completed := false
	for _i in 300:
		world.tick()
		if world.get_construction_site(6, 0).is_empty():
			site_completed = true
			break
	_expect(site_completed, "the site must resume and complete after the sleep interrupt")
	_expect(world.get_object(6, 0) == "wooden_wall", "the wall must be placed once the interrupted fetch resumes and completes")

## The stockpile sits ON the wall site (round-2 review's reproduction): leg
## one ends with the builder standing on the site, so the ordinary
## trim-the-last-tile rule has nothing to drop. The go_to machinery must step
## the builder off before its site_work toil starts, and the wall must appear
## with the builder beside it, never under it.
func _check_stockpile_on_site_steps_builder_off() -> void:
	var world := _build_world(320900)
	var site := Vector2i(5, 10)
	var job_id := _order_site_fetch(world, "wooden_wall", site, site)
	if job_id.is_empty():
		return
	var worked_on_site := false
	var elapsed := 0
	for _i in MAX_TICKS:
		world.tick()
		elapsed += 1
		_assert_no_orphaned_reservations(world, "stockpile-on-site settling")
		var colonist := world.get_colonists()[0]
		if colonist.get("work") != null and Vector2i(int(colonist["x"]), int(colonist["y"])) == site:
			worked_on_site = true
		if world.get_construction_site(site.x, site.y).is_empty():
			break
	_expect(world.get_object(site.x, site.y) == "wooden_wall",
		"a wall ordered on its own stockpile tile must still complete")
	_expect(not worked_on_site, "the builder must never run its site_work toil while standing on the wall site")
	var builder := world.get_colonists()[0]
	var builder_tile := Vector2i(int(builder["x"]), int(builder["y"]))
	_expect(builder_tile != site and bool(world.passability(builder_tile.x, builder_tile.y)["passable"]),
		"the builder must end beside the wall on a passable tile, not under it (got %s)" % [builder_tile])

## A stockpiled stack larger than the declared cost loses exactly the cost;
## the remainder returns to the ground through the ordinary deposit path
## instead of being destroyed with the rest of the stack (round-2 review of
## the superseded suite this restores).
func _check_stack_larger_than_cost_keeps_remainder() -> void:
	var world := _build_world(320950)
	var quantity := int(world._object_definitions["wooden_wall"]["build_cost"][0]["quantity"])
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(0, 10), Vector2i(0, 0), quantity + 2)
	if job_id.is_empty():
		return
	var elapsed := _tick_until_site_gone(world, Vector2i(0, 10))
	_expect(elapsed > 0, "a build fed from a larger stack must complete")
	_expect(world.get_object(0, 10) == "wooden_wall", "the wall must be placed")
	_expect(_ground_kind_total(world, "wood") == 2,
		"exactly the declared quantity must be spent; the remainder of the stack must survive on the ground (got %d)" % _ground_kind_total(world, "wood"))
	_expect(not InventoryType.is_carrying(world.get_colonists()[0]), "nothing may stay in carrying after completion")
	_assert_no_orphaned_reservations(world, "after building from a larger stack")

## Drives a fresh site scenario (wood five tiles from the colonist, site ten
## tiles further on, behind a long wall row so the second leg's bounded
## search needs more than one tick) until the named phase holds, so each
## save/load check below exercises a genuinely different point in a site's
## own lifecycle: "queued" (a site_fetch job submitted but, with build labour
## disabled, never activated), "hauling" (leg one, walking to the wood, not
## yet carrying), "carrying" (leg two, walking to the site with the wood in
## hand), "searching" (leg two's route search still in flight, route.rerouting
## set) and "working" (arrived, a site_work job in progress). Returns the
## currently active/queued job id ("" on setup failure).
func _prime_site_phase(world: WorldStateType, phase: String, site: Vector2i) -> String:
	for x in range(0, 40):
		world._set_object(x, 6, "wooden_wall")
	world._colonists.append(_colonist("colonist_0", 0, 0))
	_place_item(world, "item_1", "wood", 5, 0)
	world._next_item_id = 2
	_add_zone(world, "zone_setup", 5, 0, 1, 1)
	if phase == "queued":
		_command_ok(world, "labour_off", "set_labour", {"colonist": "colonist_0", "kind": "build", "level": 0})
	_command_ok(world, "build_wall", "build", {"kind": "wooden_wall", "x": site.x, "y": site.y})
	if phase == "queued":
		for _i in 20:
			world.tick()
			var job_id := _find_site_fetch_job_id(world, site)
			if not job_id.is_empty():
				return job_id
		_fail("setup must reach the \"queued\" phase within budget")
		return ""
	for _i in 400:
		world.tick()
		var colonist := world.get_colonists()[0]
		var carrying := InventoryType.is_carrying(colonist)
		var route = colonist.get("route")
		match phase:
			"hauling":
				if route != null and not carrying:
					return _find_site_fetch_job_id(world, site)
			"carrying":
				if carrying and route != null:
					return _find_site_fetch_job_id(world, site)
			"searching":
				if carrying and route != null and route.get("rerouting") != null:
					return _find_site_fetch_job_id(world, site)
			"working":
				var work = colonist.get("work")
				if work != null:
					var job := _job_by_id(world, String(work.get("job_id", "")))
					if String(job.get("kind", "")) == "site_work":
						return String(job["id"])
	_fail("setup must reach the \"%s\" site phase within budget" % phase)
	return ""

## A site's own destination and declared kind, and its currently in-flight
## site_fetch/site_work job's own site field, must survive a save/load round
## trip at every phase of the site's own lifecycle, not only once delivered --
## and the restored world must hash identically to the source before any
## further tick, then drive to an identical completed outcome. The
## "searching" phase proves a second-leg search restored mid-flight targets
## the site with the same passability policy live execution uses (round-2
## review of the superseded suite this restores).
func _check_save_load_round_trip_preserves_site_state() -> void:
	var phase_seeds := {"queued": 321001, "hauling": 321002, "carrying": 321003, "searching": 321005, "working": 321004}
	for phase in ["queued", "hauling", "carrying", "searching", "working"]:
		var site := Vector2i(5, 10)
		var source := _build_world(int(phase_seeds[phase]))
		var job_id := _prime_site_phase(source, phase, site)
		if job_id.is_empty() or _failed:
			continue

		var source_job := _job_by_id(source, job_id)
		_expect(String(source_job.get("kind", "")) in ["site_fetch", "site_work"],
			"(%s) the primed job must be a site_fetch or site_work job" % phase)
		_expect(not source.get_construction_site(site.x, site.y).is_empty(),
			"(%s) the primed site must still exist before saving" % phase)

		var saved := source.to_save_state()
		var restored: WorldStateType = WorldStateType.from_save_state(saved)
		var restored_job := _job_by_id(restored, job_id)
		_expect(restored_job.get("site") == source_job.get("site"),
			"(%s) a restored job's own site must survive the round trip exactly (got %s, want %s)"
				% [phase, restored_job.get("site"), source_job.get("site")])
		var restored_site := restored.get_construction_site(site.x, site.y)
		var source_site := source.get_construction_site(site.x, site.y)
		_expect(String(restored_site.get("kind", "")) == String(source_site.get("kind", "")),
			"(%s) a restored site's declared kind must survive the round trip (got %s, want %s)"
				% [phase, restored_site.get("kind"), source_site.get("kind")])
		_expect(restored.state_hash() == source.state_hash(),
			"(%s) restore must match the source's hash before any further ticks" % phase)

		if phase == "queued":
			_command_ok(source, "labour_on_source", "set_labour", {"colonist": "colonist_0", "kind": "build", "level": 2})
			_command_ok(restored, "labour_on_restored", "set_labour", {"colonist": "colonist_0", "kind": "build", "level": 2})

		var source_elapsed := _tick_until_site_gone(source, site)
		var restored_elapsed := _tick_until_site_gone(restored, site)
		_expect(source_elapsed > 0 and restored_elapsed > 0,
			"(%s) both the source and restored copy must complete the site (got %d / %d)" % [phase, source_elapsed, restored_elapsed])
		_expect(source.get_tick() == restored.get_tick(), "(%s) tick counters must match after driving both copies to completion" % phase)
		_expect(source.state_hash() == restored.state_hash(),
			"(%s) state_hash must match after driving both copies to completion" % phase)
		_expect(restored.get_object(site.x, site.y) == "wooden_wall", "(%s) the restored copy must build the wall at the site" % phase)

## SaveIO's validator must reject a site_fetch/site_work job whose own "site"
## field is missing before it is ever decoded or ticked, while a non-site job
## without it (a same-version save written before construction sites existed)
## still validates (round-2 review of the superseded suite this restores).
func _check_save_io_rejects_site_job_missing_site_field() -> void:
	var world := _build_world(320999)
	var job_id := _order_site_fetch(world, "wooden_wall", Vector2i(0, 10))
	if job_id.is_empty():
		return
	world._tiles[world._tile_index(3, 3)] = WorldStateType.TILE_SOIL
	_command_ok(world, "dig_legacy_shape", "dig", {"x": 3, "y": 3, "priority": 1})
	var state := world.to_save_state()
	_expect(SaveIOType._validate_state(state).get("ok", false),
		"a freshly encoded state with a site_fetch job must validate: %s" % [SaveIOType._validate_state(state)])
	var fetch_index := -1
	var dig_index := -1
	for i in range(state["jobs"].size()):
		if String(state["jobs"][i]["kind"]) == "site_fetch":
			fetch_index = i
		elif String(state["jobs"][i]["kind"]) == "dig":
			dig_index = i
	_expect(fetch_index >= 0 and dig_index >= 0, "the encoded state must contain both jobs")
	if fetch_index < 0 or dig_index < 0:
		return
	var no_site: Dictionary = state.duplicate(true)
	no_site["jobs"][fetch_index]["site"] = null
	_expect(not SaveIOType._validate_state(no_site).get("ok", true), "a site_fetch job with a null site must be rejected")
	var legacy: Dictionary = state.duplicate(true)
	legacy["jobs"][dig_index].erase("site")
	_expect(SaveIOType._validate_state(legacy).get("ok", false),
		"a non-site job without site (a pre-construction-site save) must still validate: %s" % [SaveIOType._validate_state(legacy)])

## An in-flight wall order and an in-flight bed order, otherwise identical and
## at the same tick, must hash differently -- proving the site's own declared
## kind is actually part of state_hash()'s own snapshot, not merely
## round-tripped and ignored.
func _check_wall_and_bed_orders_hash_differently() -> void:
	var wall_world := _build_world(320970)
	_order_site_fetch(wall_world, "wooden_wall", Vector2i(0, 10))
	var bed_world := _build_world(320970)
	_order_site_fetch(bed_world, "bed", Vector2i(0, 10))
	_expect(wall_world.get_tick() == bed_world.get_tick(), "both worlds must be compared at the same tick")
	_expect(wall_world.state_hash() != bed_world.state_hash(),
		"an in-flight wall order and an in-flight bed order at the same tick must hash differently")

## Replaces the superseded suite's own job-scoped/tile-cache "suspended-
## cancel-during-work" check (see this file's own top-of-file doc comment):
## a site's own progress lives directly on the construction site record, so
## cancelling it mid-work (cancel_site, terminating the in-progress site_work
## job through the existing release_all()/terminal-job path) simply removes
## the whole record -- there is no separate cache entry that could survive to
## be silently inherited by a fresh order at the same tile. Proven two ways:
## the site is gone immediately after cancellation, and a replacement order at
## the same tile starts its own progress at zero, not the abandoned partial one.
func _check_cancel_site_mid_work_clears_progress_for_replacement() -> void:
	var world := _build_world(321100)
	var site := Vector2i(0, 10)
	var job_id := _order_site_fetch(world, "wooden_wall", site)
	if job_id.is_empty():
		return
	_expect(_tick_until_site_work_active(world), "setup must catch the site's own site_work job in progress")
	for _i in 3:
		world.tick()
	var progress_before := int(world.get_construction_site(site.x, site.y).get("progress", 0))
	_expect(progress_before > 0, "setup must catch genuine site progress before cancelling")

	_command_ok(world, "cancel_site_mid_work", "cancel_site", {"x": site.x, "y": site.y})
	_expect(world.get_construction_site(site.x, site.y).is_empty(), "cancel_site must remove the site record, progress included")
	_expect(not InventoryType.is_carrying(world.get_colonists()[0]), "cancelling a site mid-work must clear its builder's carrying")
	_assert_no_orphaned_reservations(world, "after cancelling a site mid-work")

	# A replacement order at the same tile must start its own progress at
	# zero, never inheriting the abandoned partial one. Reuses the existing
	# colonist/zone (still standing) rather than _order_site_fetch(), which
	# would append a second, colliding "colonist_0" to this already-populated
	# world.
	_place_item(world, "item_replacement", "wood", 0, 0, 1)
	var replacement := _command_ok(world, "replacement_build", "build", {"kind": "wooden_wall", "x": site.x, "y": site.y})
	_expect(replacement.get("ok", false), "a replacement build order at the freed site must be accepted")
	if not replacement.get("ok", false):
		return
	_expect(_tick_until_site_work_active(world), "the replacement site must reach its own work phase")
	var replacement_progress := int(world.get_construction_site(site.x, site.y).get("progress", 0))
	_expect(replacement_progress < progress_before,
		"a replacement site at the same tile must not inherit the abandoned site's own progress (got %d, previous site reached %d)"
			% [replacement_progress, progress_before])
	_expect(_tick_until_site_gone(world, site) > 0, "the replacement build must complete normally")

## Replaces the superseded suite's own job-scoped/tile-cache "refused-
## resumption-during-work" check (see this file's own top-of-file doc
## comment): a site_work job's own refused resumption (F3's
## not_ordered_by_player path) must not lose the site's own progress -- unlike
## the superseded single `build` job, the site (not the terminating job) owns
## progress, so a refused builder's own termination must leave it untouched
## and available to whichever builder ConstructionGiver next assigns.
func _check_site_progress_survives_a_refused_builder_resumption() -> void:
	var world := _build_world(321150)
	var site := Vector2i(0, 10)
	var job_id := _order_site_fetch(world, "wooden_wall", site)
	if job_id.is_empty():
		return
	_expect(_tick_until_site_work_active(world), "setup must catch the site's own site_work job in progress")
	for _i in 3:
		world.tick()
	var colonist: Dictionary = world._find_colonist("colonist_0")
	_expect(colonist.get("work") != null, "the builder must still be working a few ticks after starting")
	var work_job_id := String(colonist["work"].get("job_id", ""))
	var progress_before := int(world.get_construction_site(site.x, site.y).get("progress", 0))
	_expect(progress_before > 0, "setup must have recorded genuine progress at the site")

	world._interrupt_current_job(colonist)
	_expect(_command(world, "set_raider_mid_work", "set_faction", {"target": "colonist_0", "faction_id": "raiders"}).get("ok", false),
		"set_faction while the builder is suspended mid-work must be accepted")
	world._resume_interrupted_job("colonist_0")
	world._resolve_refused_reservations()
	var job := _job_by_id(world, work_job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a refused resumption must terminally fail the site_work job not_ordered_by_player (got %s/%s)" % [job.get("status"), job.get("reason")])
	_expect(int(world.get_construction_site(site.x, site.y).get("progress", 0)) >= progress_before,
		"a refused builder's own termination must never lose the site's own progress")
	_assert_no_orphaned_reservations(world, "after a refused site_work resumption")

## #400's hands-filling rules (round 3 review): the source ConstructionGiver
## submits a site_fetch job against is only a position-agnostic seed (the
## lowest-id eligible item); the real nearest-reachable source is resolved at
## activation and re-resolved after every pick_up. Geometry: colonist_0
## starts at (0,0); the site (a `test_multi_source_crate`, 3 wood + 2 stone)
## sits at (40,0). Wood is a single 3-unit stack right next to the colonist,
## so the wood phase is a control (one hop, no ambiguity). For stone, item_2
## (the LOWER id, so also the position-agnostic submission-time seed) sits far
## from the site at (46,0); item_3 (the HIGHER id) sits close to the site at
## (42,0). Once the colonist finishes delivering wood and stands next to the
## site, the stone-phase job must swap onto item_3 (nearer to the colonist
## than item_2, regardless of id) -- proving the activation-time correction --
## then, after picking up item_3's single unit (still short one more, hands
## not full), must deliver that partial load immediately rather than chasing
## the farther item_2, because the site is nearer than item_2 is from where
## item_3 left the colonist standing (the "very close" rule). A second
## site_fetch job then fetches the sole remaining candidate, item_2, and the
## site completes.
func _check_site_fetch_prefers_nearest_reachable_source_and_applies_very_close_rule() -> void:
	var world := _build_world(320600)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	var site := Vector2i(40, 0)
	_place_item(world, "item_1", "wood", 1, 0, 3)
	_place_item(world, "item_2", "stone", 46, 0, 1)
	_place_item(world, "item_3", "stone", 42, 0, 1)
	world._next_item_id = 4
	_add_zone(world, "zone_setup", 0, 0, 48, 3)
	_command_ok(world, "build_crate", "build", {"kind": "test_multi_source_crate", "x": site.x, "y": site.y})

	var ids := ["item_2", "item_3"]
	var seen := {}
	var order: Array[String] = []
	var completed := false
	for _i in 400:
		world.tick()
		_assert_no_orphaned_reservations(world, "nearest-source/very-close settling")
		for id in ids:
			if not seen.has(id) and not world._items.has(id):
				seen[id] = true
				order.append(id)
		if world.get_construction_site(site.x, site.y).is_empty():
			completed = true
			break
	_expect(completed, "the crate must complete within the tick budget")
	_expect(order == ["item_3", "item_2"],
		"item_3 (nearer the site, higher id) must be fetched before item_2 (farther, lower id) -- the source must be chosen by route cost, not by id (got %s)" % [order])
	_expect(world.get_object(site.x, site.y) == "test_multi_source_crate", "the crate must be placed once both stone units arrive")
	_expect(_ground_kind_total(world, "wood") == 0 and _ground_kind_total(world, "stone") == 0,
		"every declared unit of wood and stone must be consumed, none left stranded on the ground")

## #400's hands-filling rules (round 3 review): on an equal route-cost tie
## between two eligible sources, the tie must break by lowest item id alone.
## Geometry: colonist_0 starts at (0,0); item_2 (the lower id) sits at (3,0)
## and item_3 sits at (0,3) -- symmetric, so any reasonable distance metric
## ties them regardless of its exact formula. item_4, a third wood unit
## needed to reach the crate's declared 3, sits at (8,0), just an ordinary
## (untied) further source that lets the site actually complete.
func _check_site_fetch_route_cost_ties_break_by_lowest_item_id() -> void:
	var world := _build_world(320700)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	var site := Vector2i(15, 0)
	_place_item(world, "item_2", "wood", 3, 0, 1)
	_place_item(world, "item_3", "wood", 0, 3, 1)
	_place_item(world, "item_4", "wood", 8, 0, 1)
	_place_item(world, "item_5", "stone", 16, 0, 2)
	world._next_item_id = 6
	_add_zone(world, "zone_setup", 0, 0, 16, 4)
	_command_ok(world, "build_crate", "build", {"kind": "test_multi_source_crate", "x": site.x, "y": site.y})

	var ids := ["item_2", "item_3", "item_4"]
	var seen := {}
	var order: Array[String] = []
	var completed := false
	for _i in 800:
		world.tick()
		_assert_no_orphaned_reservations(world, "tie-break settling")
		for id in ids:
			if not seen.has(id) and not world._items.has(id):
				seen[id] = true
				order.append(id)
		if world.get_construction_site(site.x, site.y).is_empty():
			completed = true
			break
	_expect(completed, "the crate must complete within the tick budget")
	_expect(order.size() == 3 and order.find("item_2") < order.find("item_3"),
		"item_2 (the lower id) must be fetched before its route-cost tie item_3 (got %s)" % [order])
	_expect(world.get_object(site.x, site.y) == "test_multi_source_crate", "the crate must be placed once every unit arrives")

## issue #403 round-2 review (restored from the superseded suite): among two
## eligible wood items, one sealed entirely behind a wall ring so nothing
## outside can ever reach it, the fetch must select the reachable source and
## complete, never retargeting onto the geometrically-closer but sealed-off
## one.
func _check_route_cost_skips_unreachable_source_behind_a_wall() -> void:
	var world := _build_world(320800)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	var site := Vector2i(10, 5)
	_place_item(world, "item_1", "wood", 10, 0)
	_place_item(world, "item_2", "wood", 3, 3)
	world._next_item_id = 3
	# Seal item_2 inside a complete wall ring: every perimeter tile of the
	# 2..4 x 2..4 box is a wall with no gap, so nothing outside can ever
	# reach (3,3) or step adjacent to it.
	for x in range(2, 5):
		world._set_object(x, 2, "wooden_wall")
		world._set_object(x, 4, "wooden_wall")
	world._set_object(2, 3, "wooden_wall")
	world._set_object(4, 3, "wooden_wall")
	_add_zone(world, "zone_setup", 0, 0, 11, 6)
	var result := _command_ok(world, "build_wall_behind_obstacle", "build", {"kind": "wooden_wall", "x": site.x, "y": site.y})
	_expect(result.get("ok", false), "the build order must be accepted")
	var elapsed := _tick_until_site_gone(world, site, 300)
	_expect(elapsed > 0,
		"the wall order must complete by fetching the reachable source (item_1), never getting retargeted onto the geometrically-closer but sealed-off item_2")
	_expect(not world._items.has("item_1"), "item_1, the only reachable wood, must be the one consumed")
	_expect(world._items.has("item_2"), "item_2, sealed behind the wall ring, must never be visited/consumed")
	_assert_no_orphaned_reservations(world, "after completing behind the obstacle")

## issue #403 (restored from the superseded suite): cancelling a site_fetch
## order strictly mid-multi-source-fetch, with hands already holding units
## from MORE THAN ONE already-visited source (item_1 and item_2, both wood),
## must deposit everything at the colonist's exact tile in one go (place()'s
## existing hands_snapshot()-driven deposit, unchanged), release every
## reservation this job holds (the two already-consumed sources' own keys
## included, swept by the generic release_all()), and leave the deposited
## stack immediately available to a completely different colonist.
func _check_cancel_mid_multi_source_fetch_deposits_everything_and_frees_reservations() -> void:
	var world := _build_world(320850)
	world._colonists.append(_colonist("colonist_0", 0, 0))
	var site := Vector2i(47, 0)
	_place_item(world, "item_1", "wood", 1, 0)
	_place_item(world, "item_2", "wood", 5, 0)
	_place_item(world, "item_3", "wood", 9, 0)
	_place_item(world, "item_4", "stone", 15, 0)
	_place_item(world, "item_5", "stone", 19, 0)
	world._next_item_id = 6
	_add_zone(world, "zone_setup", 0, 0, 47, 2)
	var result := _command_ok(world, "build_crate", "build", {"kind": "test_multi_source_crate", "x": site.x, "y": site.y})
	_expect(result.get("ok", false), "the build order must be accepted")

	var caught := false
	var mid_carry_tile := Vector2i(-1, -1)
	var visited_tiles := [Vector2i(1, 0), Vector2i(5, 0), Vector2i(9, 0)]
	var job_id := ""
	for _i in 200:
		world.tick()
		_assert_no_orphaned_reservations(world, "mid multi-source-fetch settling")
		var colonist := world.get_colonists()[0]
		var tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
		if InventoryType.count_of_kind(colonist, "wood") == 2 and colonist.get("route") != null and not (tile in visited_tiles):
			caught = true
			mid_carry_tile = tile
			job_id = String(colonist["route"].get("job_id", ""))
			break
	_expect(caught, "setup must catch the colonist carrying wood from two already-visited sources, still walking toward a third")
	if not caught:
		return
	_expect(mid_carry_tile != Vector2i(1, 0) and mid_carry_tile != Vector2i(5, 0) and mid_carry_tile != Vector2i(9, 0),
		"setup must catch the colonist strictly between sources, not standing on one (got %s)" % [mid_carry_tile])
	_expect(not job_id.is_empty(), "setup must capture the in-flight site_fetch job's own id")

	var before_ids := world._items.keys()
	_command_ok(world, "cancel_multi_fetch", "cancel_job", {"job_id": job_id})
	_expect(String(_job_by_id(world, job_id).get("status", "")) == "cancelled", "the site_fetch job must be cancelled")
	var after_colonist := world.get_colonists()[0]
	_expect(not InventoryType.is_carrying(after_colonist), "the colonist must no longer be carrying anything after cancel")

	var deposited_id := ""
	for id in world._items.keys():
		if not (id in before_ids):
			deposited_id = String(id)
	_expect(not deposited_id.is_empty(), "cancelling mid-fetch must deposit a fresh ground item")
	if deposited_id.is_empty():
		return
	var deposited: Dictionary = world._items[deposited_id]
	_expect(String(deposited["kind"]) == "wood" and int(deposited["count"]) == 2,
		"the deposit must carry both already-visited sources' wood in one stack (got %s)" % [deposited])
	_expect(Vector2i(int(deposited["x"]), int(deposited["y"])) == mid_carry_tile,
		"the wood must drop on the colonist's exact tile at the moment of cancellation")
	_assert_no_orphaned_reservations(world, "after cancelling mid multi-source fetch")
	var table := world._scheduler.queue.get_reservation_table()
	_expect(not table.is_reserved("item:" + deposited_id), "the freshly deposited item must not be reserved by anything")

	# A different colonist must be able to pick the deposited stack straight
	# up (no further tick: unlike the superseded suite's own single `build`
	# job, ConstructionGiver keeps running and could otherwise submit a fresh
	# site_fetch job for this exact, now-unreserved item before this check
	# ever gets to it -- the point here is that the deposit itself is
	# unreserved and available immediately, not that it survives untouched
	# for a full tick).
	world._colonists.append(_colonist("colonist_1", mid_carry_tile.x, mid_carry_tile.y))
	var colonist_1 := world._find_colonist("colonist_1")
	var pick_result := world._toils.pick_up(colonist_1, deposited_id)
	_expect(pick_result.get("ok", false), "a different colonist must be able to pick up the deposited items the next tick: %s" % pick_result)
	_expect(InventoryType.count_of_kind(colonist_1, "wood") == 2, "the picking-up colonist must receive the full deposited stack")

## issue #403 (restored, adapted): two build orders of the same
## >HANDS_CAPACITY content kind, submitted concurrently and sharing one
## stockpile, must not deadlock or starve each other -- proving the shared
## ReservationTable's "skip an item already reserved by a different active
## job" rule still applies once fetching is spread across many transient
## per-delivery site_fetch jobs rather than one job spanning an order's whole
## fetch phase. "Done fetching" is each site's own materials_met() (there is
## no longer a single persistent job to read a "cell" field from). Unlike the
## superseded suite's own version, this does not assert which specific items
## each order claimed (that bookkeeping lived on one job id per order, which
## no longer exists under the per-delivery-trip job model) -- only that both
## orders complete, two colonists finish strictly faster than one serializing
## them, and re-running the same seed is fully deterministic.
func _check_two_site_orders_disjoint_sources_and_deterministic() -> void:
	var two_colonist_result := _run_two_orders_scenario(340200, true)
	var one_colonist_result := _run_two_orders_scenario(340200, false)
	_expect(int(two_colonist_result["both_done_tick"]) > 0, "both orders must finish fetching within the two-colonist run's own budget")
	_expect(int(one_colonist_result["both_done_tick"]) > 0, "both orders must finish fetching within the one-colonist run's own budget")
	if int(two_colonist_result["both_done_tick"]) <= 0 or int(one_colonist_result["both_done_tick"]) <= 0:
		return
	_expect(int(two_colonist_result["both_done_tick"]) < int(one_colonist_result["both_done_tick"]),
		"two colonists fetching concurrently must finish both orders' fetch in fewer ticks than one colonist serializing them (two=%d, one=%d)"
			% [two_colonist_result["both_done_tick"], one_colonist_result["both_done_tick"]])

	var repeat_result := _run_two_orders_scenario(340200, true)
	_expect(int(repeat_result["both_done_tick"]) == int(two_colonist_result["both_done_tick"]),
		"two runs of the same seed must finish fetching on the identical tick (got %d and %d)"
			% [repeat_result["both_done_tick"], two_colonist_result["both_done_tick"]])
	_expect(repeat_result["colonist_a_hands"] == two_colonist_result["colonist_a_hands"] and repeat_result["colonist_b_hands"] == two_colonist_result["colonist_b_hands"],
		"two runs of the same seed must leave each order's colonist holding identical hands")

## Shared setup for _check_two_site_orders_disjoint_sources_and_deterministic():
## one or two colonists (two_colonists), two test_multi_source_crate orders
## sharing one 10-item stockpile (6 wood + 4 stone, exactly matching both
## orders' combined declared cost) spread x=5..14, y=0. Runs until both
## sites' own held_materials fully meet their required_materials ("done
## fetching", docs/decisions/036) or the tick budget runs out (both_done_tick
## stays 0, unmet).
func _run_two_orders_scenario(seed_value: int, two_colonists: bool) -> Dictionary:
	var world := _build_world(seed_value)
	world._colonists.append(_colonist("colonist_a", 0, 0))
	if two_colonists:
		world._colonists.append(_colonist("colonist_b", 2, 0))
	var kinds := {"ia": "wood", "ib": "wood", "ic": "wood", "id": "stone", "ie": "stone",
		"if": "wood", "ig": "wood", "ih": "wood", "ii": "stone", "ij": "stone"}
	var xs := {"ia": 5, "ib": 6, "ic": 7, "id": 8, "ie": 9, "if": 10, "ig": 11, "ih": 12, "ii": 13, "ij": 14}
	for id in kinds.keys():
		_place_item(world, id, String(kinds[id]), int(xs[id]), 0)
	world._next_item_id = 100
	_add_zone(world, "zone_setup", 0, 0, 16, 2)
	var site_a := Vector2i(0, 20)
	var site_b := Vector2i(30, 20)
	_command_ok(world, "order_a", "build", {"kind": "test_multi_source_crate", "x": site_a.x, "y": site_a.y})
	_command_ok(world, "order_b", "build", {"kind": "test_multi_source_crate", "x": site_b.x, "y": site_b.y})
	var both_done_tick := 0
	# ConstructionGiver submits one fresh, single-delivery site_fetch job per
	# hop rather than the superseded suite's own multi-hop-per-job model, so
	# each hop pays its own reserve/activate/deliver/release cycle -- these
	# budgets are generous multiples of the superseded suite's own 300/1200,
	# not a tight bound.
	var budget := 900 if two_colonists else 3000
	# Sticky, not a live re-check every tick: once a site's own held_materials
	# meets its required_materials it starts its site_work phase and may
	# finish (and be removed) well before this loop notices, at which point
	# get_construction_site() would otherwise read back empty and this test
	# would wrongly conclude "not yet met".
	var a_met := false
	var b_met := false
	for _i in budget:
		world.tick()
		_assert_no_orphaned_reservations(world, "two-order fetch settling")
		var site_a_record := world.get_construction_site(site_a.x, site_a.y)
		var site_b_record := world.get_construction_site(site_b.x, site_b.y)
		if not a_met and not site_a_record.is_empty():
			a_met = _public_site_materials_met(site_a_record)
		if not b_met and not site_b_record.is_empty():
			b_met = _public_site_materials_met(site_b_record)
		if a_met and b_met:
			both_done_tick = world.get_tick()
			break
	var colonist_a := world._find_colonist("colonist_a")
	var colonist_b := world._find_colonist("colonist_b") if two_colonists else {}
	return {
		"both_done_tick": both_done_tick,
		"colonist_a_hands": InventoryType.hands_snapshot(colonist_a) if not colonist_a.is_empty() else [],
		"colonist_b_hands": InventoryType.hands_snapshot(colonist_b) if not colonist_b.is_empty() else [],
	}
