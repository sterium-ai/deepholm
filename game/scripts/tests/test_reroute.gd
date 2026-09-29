extends SceneTree

## Covers issue #180: a colonist re-validates its route's next tile via
## passability() every tick (colonist-ai.md 3.5/3.8). Placing a wall mid-walk
## exposes reason "rerouting", a new bounded route is found and the job
## resumes/completes; enclosing a target with walls instead proves it
## unreachable, releases the job with the existing blocked_target_unreachable
## reason/remedy, frees the colonist for other work, and leaves no reservation
## behind; a save/load taken mid-search resumes and finishes identically to an
## uninterrupted run. Every scenario declares its own explicit tick bound.

const WorldType = preload("res://scripts/core/world_state.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const RouteType = preload("res://scripts/core/scheduling/measured_route.gd")

const SAVE_IO_TEST_PATH := "user://test-reroute-save-io.json"

## Bound for the reroute-then-resume and panel-reason scenarios: the forced
## detour around the "racetrack" (see _build_racetrack_world()) is ~100
## tiles, needing two resume() calls (STEP_BUDGET is 64) to resolve -- which
## is exactly what keeps the re-route search genuinely STATUS_SEARCHING for
## at least one observable tick instead of resolving invisibly within the
## same tick it starts -- then ~100 tile-advances (400 ticks) to walk it plus
## WORK_TICKS["dig"] (30). Generous margin included; still a fixed, declared
## bound, not an unbounded wait.
const REROUTE_RESUME_MAX_TICKS := 600

## Bound for the unreachable-release scenario: ~8 ticks to reach the point
## where the target's only two entrances are found walled, a tick or two to
## prove unreachable and resubmit, then a short walk + WORK_TICKS["dig"] (30)
## for the colonist's next queued order.
const RELEASE_MAX_TICKS := 150

## Bound for the save/load-mid-search scenario: same "racetrack" economics as
## REROUTE_RESUME_MAX_TICKS above.
const SAVE_LOAD_MAX_TICKS := 600

## Bound for the mid-fetch-tool save/load scenario: the colonist must walk the
## ~100-tile racetrack detour twice (once to reach the axe, once to walk back
## to the chop target the fetch detoured away from) plus WORK_TICKS["chop"]
## (40) -- roughly double REROUTE_RESUME_MAX_TICKS's single-detour economics.
const FETCH_TOOL_MAX_TICKS := 1400

var _failed := false

func _init() -> void:
	_check_reroute_then_resume()
	_check_panel_shows_rerouting_reason()
	_check_unreachable_target_releases_job()
	_check_save_load_mid_reroute_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_reroute_matches_uninterrupted_run()
	_check_save_load_mid_fetch_tool_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_fetch_tool_initial_search_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_fetch_tool_after_exclusion_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_fetch_tool_return_leg_matches_uninterrupted_run()
	_check_save_io_round_trip_mid_fetch_tool_holder_moves_matches_uninterrupted_run()
	_check_route_budget_shared_across_scheduler_fetch_and_return()

	if _failed:
		quit(1)
		return
	print("test_reroute: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _command(world: WorldType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

func _job_status(world: WorldType, job_id: String) -> String:
	for job in world.get_jobs():
		if job["id"] == job_id:
			return String(job["status"])
	return ""

## Cancelling and resubmitting a job for the same target (see
## WorldState._advance_go_to_or_resubmit()) leaves the old, terminal job in
## get_jobs() alongside the new one: filtering for "queued" is what finds the
## live job for that target rather than the cancelled one that precedes it.
func _find_queued_job_for_target(world: WorldType, target: Vector2i) -> Dictionary:
	for job in world.get_jobs():
		if job["target"] == target and job["status"] == "queued":
			return job
	return {}

## True once job_id's fetch_tool attempt has proven at least one candidate
## unreachable and excluded it (tool_fetch_toil.gd's _exclude_candidate()),
## for the round-7 after-exclusion save/load scenario below.
func _fetch_tool_has_excluded(world: WorldType, job_id: String) -> bool:
	return (world._toils.get_fetch_tool_excluded().get(job_id, []) as Array).size() > 0

## Two open rows (y=0 and y=1, x=0..4): the direct top-row path to the dig
## target at (4,0) is 4 edges; blocking (2,0) forces a 5-edge detour through
## row 1, which stays well within a single RouteSearch.STEP_BUDGET (64) call.
func _build_two_row_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_ROCK)
	# issue #300: clear any generator-placed berry_bush (docs/decisions/020)
	# before overwriting tiles, so it can never sit on one of this fixture's
	# own narrow rows and block a route the test expects to be open.
	world._objects.clear()
	world._object_factions.clear()
	for x in range(0, 5):
		world._tiles[world._tile_index(x, 0)] = WorldType.TILE_SOIL
		world._tiles[world._tile_index(x, 1)] = WorldType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	world.spawn_ground_tool_item("pick", 0, 0)
	return world

## Walls (2,0) once the colonist has stepped onto (1,0), forcing a re-route
## on the racetrack world (see _build_racetrack_world()) for the remaining
## walk to the dig target at (5,0). Asserts reason "rerouting" is exposed
## within one tick of the next path tile becoming impassable, a new route is
## found, and the job completes within the declared tick bound.
func _check_reroute_then_resume() -> void:
	var world := _build_racetrack_world(9001)
	var target := Vector2i(5, 0)
	var job_id: String = _command(world, "dig", "dig", {"x": target.x, "y": target.y, "priority": 1})["job_id"]

	var walled := false
	var saw_rerouting := false
	var ticks := 0
	while _job_status(world, job_id) != "completed" and ticks < REROUTE_RESUME_MAX_TICKS:
		walled = _tick_and_wall_once(world, walled)
		ticks += 1
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null:
			saw_rerouting = true

	_expect(walled, "test fixture must place the wall before the colonist crosses it")
	_expect(saw_rerouting, "colonist must expose an in-flight re-route search after the wall lands")
	_expect(_job_status(world, job_id) == "completed",
		"job must complete within the declared tick bound (%d) after re-routing" % REROUTE_RESUME_MAX_TICKS)
	_expect(world.get_tile(target.x, target.y) == WorldType.TILE_TRENCH, "dig target must become trench")

## Replays the same scenario just long enough to catch the colonist actively
## rerouting, then asserts colonist_panel.gd surfaces reason "rerouting" for
## it the same way it already surfaces other reasons (for an idle colonist).
func _check_panel_shows_rerouting_reason() -> void:
	var world := _build_racetrack_world(9002)
	var target := Vector2i(5, 0)
	_command(world, "dig", "dig", {"x": target.x, "y": target.y, "priority": 1})

	var walled := false
	var rerouting_colonist := {}
	var ticks := 0
	while rerouting_colonist.is_empty() and ticks < REROUTE_RESUME_MAX_TICKS:
		walled = _tick_and_wall_once(world, walled)
		ticks += 1
		var colonist := world.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null:
			rerouting_colonist = colonist

	_expect(not rerouting_colonist.is_empty(), "test fixture must catch the colonist mid-reroute")
	if rerouting_colonist.is_empty():
		return

	var panel := ColonistPanelType.new()
	var text_table := TextTableType.new()
	panel.setup(world, text_table)
	var status := panel._status_for(rerouting_colonist)
	_expect(not status["idle"], "a rerouting colonist is still on an active job, not idle")
	_expect(status["reason"] == "rerouting", "panel status must report reason 'rerouting' for a rerouting colonist")
	var line: String = panel._line_for(rerouting_colonist)
	_expect(line.find("rerouting") != -1 or line.find("status.reason.rerouting") != -1,
		"panel line must surface the word 'rerouting' the same way it surfaces other reasons: %s" % line)

## Walls both of the dig target's only two entrances -- (3,0) and (4,1) --
## once the colonist reaches (2,0), fully enclosing (4,0). The forced
## re-route search must prove it unreachable, release the job with the
## existing blocked_target_unreachable reason/remedy, free the colonist, and
## leave get_reservations() with no entry for the enclosed target. A second,
## reachable order at (1,1) must then be taken and completed by the freed
## colonist within the declared tick bound.
func _check_unreachable_target_releases_job() -> void:
	var world := _build_two_row_world(9003)
	var enclosed_target := Vector2i(4, 0)
	_command(world, "dig", "dig", {"x": enclosed_target.x, "y": enclosed_target.y, "priority": 1})

	var walled := false
	var released := false
	var second_job_id := ""
	var ticks := 0
	while ticks < RELEASE_MAX_TICKS:
		world.tick()
		ticks += 1
		var colonist := world.get_colonists()[0]
		if not walled and colonist["x"] == 2 and colonist["y"] == 0:
			world._set_object(3, 0, "wooden_wall")
			world._set_object(4, 1, "wooden_wall")
			walled = true
		if walled and not released:
			var blocked_job := _find_queued_job_for_target(world, enclosed_target)
			if not blocked_job.is_empty() and blocked_job["reason"] == "blocked_target_unreachable":
				released = true
				_expect(not world.get_reservations().has(enclosed_target),
					"no reservation must be left behind for the released, enclosed target")
				second_job_id = _command(world, "second", "dig", {"x": 1, "y": 1, "priority": 1})["job_id"]
		if released and second_job_id != "" and _job_status(world, second_job_id) == "completed":
			break

	_expect(walled, "test fixture must enclose the target before the colonist reaches it")
	_expect(released, "enclosed target's job must be released with blocked_target_unreachable within the declared tick bound")
	_expect(second_job_id != "", "a second order must have been submitted once the target was released")
	_expect(_job_status(world, second_job_id) == "completed",
		"the freed colonist must take and complete the next queued order within the declared tick bound (%d)" % RELEASE_MAX_TICKS)
	_expect(not world.get_reservations().has(enclosed_target),
		"the enclosed target must still carry no reservation at the end of the run")
	var final_blocked_job := _find_queued_job_for_target(world, enclosed_target)
	_expect(not final_blocked_job.is_empty() and final_blocked_job["reason"] == "blocked_target_unreachable",
		"the enclosed target's job must remain queued and blocked_target_unreachable")

## A "racetrack": the short top edge (y=0, x=0..5) direct-connects start and
## target, while the left column (x=0), bottom edge (y=47, x=0..5) and right
## column (x=5) form the only alternative route (~100 tiles), forcing the
## post-wall re-route search to still be STATUS_SEARCHING after its first
## resume() call (over RouteSearch.STEP_BUDGET=64) -- a genuinely in-flight
## search to save mid-flight, not one that resolves in the same tick.
func _build_racetrack_world(seed_value: int) -> WorldType:
	var world := WorldType.new(seed_value)
	world._tiles.fill(WorldType.TILE_ROCK)
	# issue #300: see _build_two_row_world()'s own doc comment above.
	world._objects.clear()
	world._object_factions.clear()
	for x in range(0, 6):
		world._tiles[world._tile_index(x, 0)] = WorldType.TILE_SOIL
		world._tiles[world._tile_index(x, WorldType.MAP_HEIGHT - 1)] = WorldType.TILE_SOIL
	for y in range(0, WorldType.MAP_HEIGHT):
		world._tiles[world._tile_index(0, y)] = WorldType.TILE_SOIL
		world._tiles[world._tile_index(5, y)] = WorldType.TILE_SOIL
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	world.spawn_ground_tool_item("pick", 0, 0)
	return world

## Advances world by exactly one tick, walling (2,0) the instant the colonist
## first stands on (1,0) (shared by both runs so they wall at the same point).
func _tick_and_wall_once(world: WorldType, walled: bool) -> bool:
	world.tick()
	if walled:
		return walled
	var colonist := world.get_colonists()[0]
	if colonist["x"] == 1 and colonist["y"] == 0:
		world._set_object(2, 0, "wooden_wall")
		return true
	return walled

## Round 5 review finding: state_codec.gd's _restore_reroutes() rebuilt every
## resumed search's cost callable with a target-tile passability exception at
## job["target"] -- correct for the job's own go_to leg, but wrong for an
## in-flight fetch_tool leg travelling toward a tool at a *different*
## location. A chop job's own target (a tree at (1,0), directly adjacent to
## the colonist's start) needs no search at all to reach; the axe fetch_tool
## must travel for instead sits at (5,0), an otherwise-impassable rock pocket
## only reachable by treating *that* tile as the exception, at the far end of
## a forced ~100-tile racetrack detour (STEP_BUDGET is 64, so this needs two
## resume() calls, catching the search genuinely mid-flight to save). A buggy
## restore would instead except the tree's tile -- irrelevant to this
## search -- and could resolve differently.
func _build_fetch_tool_racetrack_world(seed_value: int) -> WorldType:
	var world := _build_racetrack_world(seed_value)
	world._tiles[world._tile_index(1, 0)] = WorldType.TILE_TREE
	world._tiles[world._tile_index(5, 0)] = WorldType.TILE_ROCK
	world.spawn_ground_tool_item("axe", 5, 0)
	return world

func _check_save_load_mid_fetch_tool_matches_uninterrupted_run() -> void:
	var target := Vector2i(1, 0)
	var seed_value := 9006

	# Path A: an uninterrupted run straight through to completion.
	var direct := _build_fetch_tool_racetrack_world(seed_value)
	var direct_job_id: String = _command(direct, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var direct_ticks := 0
	while _job_status(direct, direct_job_id) != "completed" and direct_ticks < FETCH_TOOL_MAX_TICKS:
		direct.tick()
		direct_ticks += 1
	_expect(_job_status(direct, direct_job_id) == "completed",
		"uninterrupted run must complete within the declared tick bound (%d)" % FETCH_TOOL_MAX_TICKS)

	# Path B: save the instant the fetch_tool travel search is still
	# STATUS_SEARCHING (mid-flight, not yet resolved), restore into a fresh
	# WorldState, then advance identically.
	var source := _build_fetch_tool_racetrack_world(seed_value)
	var source_job_id: String = _command(source, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var mid_search := false
	var source_ticks := 0
	while not mid_search and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		source_ticks += 1
		var colonist := source.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null and route["rerouting"]["status"] == "searching":
			mid_search = true

	_expect(mid_search, "test fixture must catch the fetch_tool search still STATUS_SEARCHING (mid-flight)")
	if not mid_search:
		return

	var saved := source.to_save_state()
	var restored := WorldType.from_save_state(saved)
	_expect(restored.state_hash() == source.state_hash(),
		"restore mid-fetch-tool-search must match the source's hash before any further ticks")

	while _job_status(source, source_job_id) != "completed" and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		restored.tick()
		source_ticks += 1

	_expect(_job_status(source, source_job_id) == "completed",
		"source run must complete within the declared tick bound (%d) after the mid-fetch-tool save" % FETCH_TOOL_MAX_TICKS)
	_expect(_job_status(restored, source_job_id) == "completed",
		"restored run must also complete within the declared tick bound after the mid-fetch-tool save")
	_expect(source.state_hash() == restored.state_hash(),
		"a mid-fetch-tool save/load must finish with the same state_hash() as an uninterrupted run")
	_expect(direct.state_hash() == restored.state_hash(),
		"the mid-fetch-tool-interrupted run must match the uninterrupted run's final state_hash()")

## Round 7 review finding: advance_go_to()'s route==null branch seeded a fresh
## search with path=[] -- StateCodec.encode()/decode() (the to_save_state()/
## from_save_state() pair the check above uses) round-trips that value with no
## complaint, but SaveIO._valid_entity_route() rejects it on read ("entity
## route path must have at least one tile"), so a real save taken mid-search
## could never actually be written during the fetch_tool leg the check above
## exercises. Same fixture and save point, but through SaveIO's real file
## boundary (write_atomic() + read()), and comparing state_hash() after EVERY
## tick once restored -- not merely the final one -- so a divergence on the
## exact tick the search resolves cannot hide behind a coincidentally-matching
## last hash.
func _check_save_io_round_trip_mid_fetch_tool_initial_search_matches_uninterrupted_run() -> void:
	var target := Vector2i(1, 0)
	var seed_value := 9013

	var direct := _build_fetch_tool_racetrack_world(seed_value)
	var direct_job_id: String = _command(direct, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var direct_ticks := 0
	while _job_status(direct, direct_job_id) != "completed" and direct_ticks < FETCH_TOOL_MAX_TICKS:
		direct.tick()
		direct_ticks += 1
	_expect(_job_status(direct, direct_job_id) == "completed",
		"uninterrupted run must complete within the declared tick bound (%d)" % FETCH_TOOL_MAX_TICKS)

	var source := _build_fetch_tool_racetrack_world(seed_value)
	var source_job_id: String = _command(source, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var mid_search := false
	var source_ticks := 0
	while not mid_search and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		source_ticks += 1
		var colonist := source.get_colonists()[0]
		var route = colonist.get("route")
		if String(colonist.get("held_tool", "")).is_empty() and route != null \
				and route.get("rerouting") != null and route["rerouting"]["status"] == "searching":
			mid_search = true

	_expect(mid_search, "test fixture must catch the initial fetch_tool search still STATUS_SEARCHING (mid-flight)")
	if not mid_search:
		return

	var saved_colonist := source.get_colonists()[0]
	var saved_route = saved_colonist.get("route")
	_expect(saved_route != null and (saved_route["path"] as Array).size() >= 1,
		"the saved initial fetch_tool leg must carry at least one path tile (round 7 fix)")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, source.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-initial-fetch-tool-search: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-initial-fetch-tool-search: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored := WorldType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == source.state_hash(),
		"SaveIO round trip mid-initial-fetch-tool-search must match the source's hash before any further ticks")

	while _job_status(source, source_job_id) != "completed" and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		restored.tick()
		source_ticks += 1
		_expect(source.state_hash() == restored.state_hash(),
			"source and restored runs must match state_hash() every tick after the mid-initial-search save (tick %d)" % source_ticks)

	_expect(_job_status(source, source_job_id) == "completed",
		"source run must complete within the declared tick bound (%d) after the mid-initial-search save" % FETCH_TOOL_MAX_TICKS)
	_expect(_job_status(restored, source_job_id) == "completed",
		"restored run must also complete within the declared tick bound after the mid-initial-search save")
	_expect(direct.state_hash() == restored.state_hash(),
		"the mid-initial-search-interrupted run must match the uninterrupted run's final state_hash()")

## Round 7 review finding, second exercise: a second axe at (2,2), nearer by
## ToolMatching's own raw Manhattan ranking (distance 4 from (0,0)) than the
## real one at (5,0) (distance 5) but with no passable neighbor anywhere on
## the map (the racetrack loop's interior stays TILE_ROCK, see
## _build_racetrack_world()) -- tried first, proven unreachable, and excluded
## (tool_fetch_toil.gd's _exclude_candidate()), so the real axe's own search
## only starts on a SECOND, freshly-created colonist.route (advance_go_to()'s
## route==null branch runs again), not the job's very first search.
func _build_fetch_tool_excluded_candidate_world(seed_value: int) -> WorldType:
	var world := _build_fetch_tool_racetrack_world(seed_value)
	world.spawn_ground_tool_item("axe", 2, 2)
	return world

## Real SaveIO round trip (write_atomic() + read()) taken mid-search for the
## SECOND fetch_tool candidate, once the nearer, unreachable one has already
## been excluded -- distinct from the initial-search case above, since
## advance_go_to()'s route==null branch runs a second time here with a
## different job history (a non-empty _excluded set) already persisted
## alongside it. Compares state_hash() after every tick post-restore, not
## merely the final one.
func _check_save_io_round_trip_mid_fetch_tool_after_exclusion_matches_uninterrupted_run() -> void:
	var target := Vector2i(1, 0)
	var seed_value := 9014

	var direct := _build_fetch_tool_excluded_candidate_world(seed_value)
	var direct_job_id: String = _command(direct, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var direct_excluded_seen := false
	var direct_ticks := 0
	while _job_status(direct, direct_job_id) != "completed" and direct_ticks < FETCH_TOOL_MAX_TICKS:
		direct.tick()
		direct_ticks += 1
		if _fetch_tool_has_excluded(direct, direct_job_id):
			direct_excluded_seen = true
	_expect(direct_excluded_seen, "test fixture must actually exclude the nearer, unreachable candidate")
	_expect(_job_status(direct, direct_job_id) == "completed",
		"uninterrupted run must complete within the declared tick bound (%d)" % FETCH_TOOL_MAX_TICKS)

	var source := _build_fetch_tool_excluded_candidate_world(seed_value)
	var source_job_id: String = _command(source, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var mid_search := false
	var source_ticks := 0
	while not mid_search and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		source_ticks += 1
		var colonist := source.get_colonists()[0]
		var route = colonist.get("route")
		if _fetch_tool_has_excluded(source, source_job_id) and String(colonist.get("held_tool", "")).is_empty() \
				and route != null and route.get("rerouting") != null and route["rerouting"]["status"] == "searching":
			mid_search = true

	_expect(mid_search, "test fixture must exclude the nearer candidate and catch the resulting fresh search still STATUS_SEARCHING (mid-flight)")
	if not mid_search:
		return

	var saved_colonist := source.get_colonists()[0]
	var saved_route = saved_colonist.get("route")
	_expect(saved_route != null and (saved_route["path"] as Array).size() >= 1,
		"the saved post-exclusion fetch_tool leg must carry at least one path tile (round 7 fix)")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, source.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-fetch-tool-search after an exclusion: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-fetch-tool-search after an exclusion: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored := WorldType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == source.state_hash(),
		"SaveIO round trip mid-fetch-tool-search after an exclusion must match the source's hash before any further ticks")

	while _job_status(source, source_job_id) != "completed" and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		restored.tick()
		source_ticks += 1
		_expect(source.state_hash() == restored.state_hash(),
			"source and restored runs must match state_hash() every tick after the mid-exclusion save (tick %d)" % source_ticks)

	_expect(_job_status(source, source_job_id) == "completed",
		"source run must complete within the declared tick bound (%d) after the mid-exclusion save" % FETCH_TOOL_MAX_TICKS)
	_expect(_job_status(restored, source_job_id) == "completed",
		"restored run must also complete within the declared tick bound after the mid-exclusion save")
	_expect(direct.state_hash() == restored.state_hash(),
		"the mid-exclusion-interrupted run must match the uninterrupted run's final state_hash()")

## Round 7 review finding, third exercise: the SAME advance_go_to() route==null
## bug applies to the return-to-target leg that starts once fetch_tool itself
## completes (colonist.route is null again after tool_fetch_toil.gd's
## _arrive(), and this leg has no scheduler-precomputed assignment_path left
## to reuse once the colonist has moved away from its own original position to
## fetch the tool -- see ToilExecutor._continue_go_to()/_start_current_toil()'s
## own is_first/assignment_path[0]==current shortcut) -- distinct from the
## initial fetch search exercised above, and needing its OWN fixture: the axe
## sits just two tiles from the colonist's own start (0,2), so the fetch leg
## resolves almost immediately (never mid-flight), moving the colonist just
## far enough that assignment_path[0] (the scheduler's own precomputed path,
## still anchored at (0,0)) no longer matches -- forcing the return leg
## through _continue_go_to()'s own fresh-search fallback. Walling the top-row
## shortcut at (1,0) leaves the long way around the racetrack loop (~73 tiles)
## as the only route from (0,2) to the chop target at (5,24), needing two
## resume() calls (STEP_BUDGET is 64) and so genuinely STATUS_SEARCHING for at
## least one observable tick.
func _build_fetch_tool_return_leg_racetrack_world(seed_value: int) -> WorldType:
	var world := _build_racetrack_world(seed_value)
	world._tiles[world._tile_index(1, 0)] = WorldType.TILE_ROCK
	world._tiles[world._tile_index(5, 24)] = WorldType.TILE_TREE
	world.spawn_ground_tool_item("axe", 0, 2)
	return world

func _check_save_io_round_trip_mid_fetch_tool_return_leg_matches_uninterrupted_run() -> void:
	var target := Vector2i(5, 24)
	var seed_value := 9015

	var direct := _build_fetch_tool_return_leg_racetrack_world(seed_value)
	var direct_job_id: String = _command(direct, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var direct_ticks := 0
	while _job_status(direct, direct_job_id) != "completed" and direct_ticks < FETCH_TOOL_MAX_TICKS:
		direct.tick()
		direct_ticks += 1
	_expect(_job_status(direct, direct_job_id) == "completed",
		"uninterrupted run must complete within the declared tick bound (%d)" % FETCH_TOOL_MAX_TICKS)

	var source := _build_fetch_tool_return_leg_racetrack_world(seed_value)
	var source_job_id: String = _command(source, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var mid_return_search := false
	var source_ticks := 0
	while not mid_return_search and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		source_ticks += 1
		var colonist := source.get_colonists()[0]
		var route = colonist.get("route")
		if not String(colonist.get("held_tool", "")).is_empty() and route != null \
				and route.get("rerouting") != null and route["rerouting"]["status"] == "searching":
			mid_return_search = true

	_expect(mid_return_search, "test fixture must catch the return-to-target search still STATUS_SEARCHING (mid-flight) after the axe was picked up")
	if not mid_return_search:
		return

	var saved_colonist := source.get_colonists()[0]
	var saved_route = saved_colonist.get("route")
	_expect(saved_route != null and (saved_route["path"] as Array).size() >= 1,
		"the saved return-leg fetch_tool route must carry at least one path tile (round 7 fix)")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, source.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-return-leg-search: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-return-leg-search: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored := WorldType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == source.state_hash(),
		"SaveIO round trip mid-return-leg-search must match the source's hash before any further ticks")

	while _job_status(source, source_job_id) != "completed" and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		restored.tick()
		source_ticks += 1
		_expect(source.state_hash() == restored.state_hash(),
			"source and restored runs must match state_hash() every tick after the mid-return-leg save (tick %d)" % source_ticks)

	_expect(_job_status(source, source_job_id) == "completed",
		"source run must complete within the declared tick bound (%d) after the mid-return-leg save" % FETCH_TOOL_MAX_TICKS)
	_expect(_job_status(restored, source_job_id) == "completed",
		"restored run must also complete within the declared tick bound after the mid-return-leg save")
	_expect(direct.state_hash() == restored.state_hash(),
		"the mid-return-leg-interrupted run must match the uninterrupted run's final state_hash()")

## Round 6 review finding: StateCodec._restore_reroutes() rebuilt a resumed
## fetch_tool leg's passability exception from the tool's CURRENT (post-
## restore) location instead of the in-flight search's own already-persisted
## rerouting.target -- these differ once a held tool's holder moves after the
## search begins but before the save. colonist_1 holds an AXE (not a pick --
## _build_racetrack_world() already spawns a pick on colonist_0's own start
## tile, which a dig job would grab with no travel at all) on an otherwise-
## impassable rock tile (5,0), directly reachable at first via the
## racetrack's own top row -- so fetch_tool's first search resolves
## immediately (SaveIO's own entity-route rule requires a saved route's path
## to carry at least one tile; only a colonist already walking a resolved
## path, not one still searching from scratch, satisfies that). Walling
## (2,0) once colonist_0 reaches (1,0) forces a SECOND, genuinely in-flight
## re-route for the same final target while the stale-but-non-empty first
## path stays on the record; colonist_1 relocates the instant THAT second
## search is caught mid-flight -- a restore that excepts the holder's NEW
## tile instead of the frozen original would leave the true target tile
## impassable and diverge from an uninterrupted run, which keeps its own
## frozen, correct exception forever.
func _build_fetch_tool_racetrack_world_with_moving_holder(seed_value: int) -> WorldType:
	var world := _build_racetrack_world(seed_value)
	# (3,1) sits off every racetrack corridor tile (only reachable via (3,0),
	# on the top row) so it cannot block the long left/bottom/right-column
	# detour the SECOND fetch_tool search below needs once (2,0) is walled.
	world._tiles[world._tile_index(3, 1)] = WorldType.TILE_TREE
	world._tiles[world._tile_index(5, 0)] = WorldType.TILE_ROCK
	# colonist_1 stands on (5,0), itself now impassable rock (only enterable
	# via the fetch_tool target-tile exception): a RouteSearch starting FROM
	# an impassable tile is invalid by construction (RouteSearch._init()), so
	# colonist_1's OWN labour is disabled -- it would otherwise still be
	# proposed for (and, being closer, keep winning over colonist_0) the chop
	# job's own activation search every tick, which can never resolve from
	# colonist_1's own invalid start tile, wedging the job forever.
	world._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 5, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"labourTable": {"mine": 0, "chop": 0, "farm": 0, "haul": 0, "build": 0, "craft": 0, "cook": 0},
		"route": null, "work": null, "carrying": null, "held_tool": ""})
	var axe_id := world.spawn_ground_tool_item("axe", 5, 0)
	world.set_tool_item_held(axe_id, "colonist_1")
	return world

## Advances world by exactly one tick, then drives the fixture's two scripted
## side effects in order on `state` (shared across the direct and source/
## restored runs so both hit them at the identical simulated moment): first
## wall (2,0) the instant colonist_0 first stands on (1,0) (forcing the
## second, genuinely in-flight re-route -- see the builder above), then, once
## that second search is first caught STATUS_SEARCHING, relocate colonist_1
## away from its start tile exactly once.
func _drive_fetch_tool_holder_moves_fixture(world: WorldType, state: Dictionary) -> void:
	world.tick()
	var colonist := world.get_colonists()[0]
	if not state.get("walled", false):
		if colonist["x"] == 1 and colonist["y"] == 0:
			world._set_object(2, 0, "wooden_wall")
			state["walled"] = true
		return
	if state.get("moved", false):
		return
	var route = colonist.get("route")
	if route == null or route.get("rerouting") == null or route["rerouting"]["status"] != "searching":
		return
	# (10,10) is another impassable rock tile, off every racetrack corridor:
	# advance_go_to()'s own found-path trim (toil_executor.gd) re-checks
	# passability against whatever target fetch_tool's NEXT advance() call
	# freshly recomputes (the holder's new position), not the search's own
	# frozen one -- relocating to a tile that is ALSO impassable keeps that
	# unrelated trim decision the same either way, isolating this fixture to
	# the one behavior actually under test (the restored search's passability
	# EXCEPTION, not this live trim's own separate target staleness).
	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_1":
			world._colonists[i]["x"] = 10
			world._colonists[i]["y"] = 10
	state["moved"] = true

## True once job_id has reached a settled outcome: either it completed (the
## relocated colonist_1 still happened to leave the axe within reach, an
## unlikely but legal outcome depending on exactly where it moved to), or
## fetch_tool's own arrival re-validation (tool_fetch_toil.gd's _arrive())
## found the axe no longer where colonist_0 ended up and reported
## blocked_no_tool -- the actually expected outcome here, since colonist_1
## relocates away from (5,0) mid-search. Either way this is the run's own
## natural conclusion, not an arbitrary tick cutoff.
func _fetch_tool_holder_moved_job_settled(world: WorldType, job_id: String) -> bool:
	var job := {}
	for j in world.get_jobs():
		if String(j["id"]) == job_id:
			job = j
	return String(job.get("status", "")) == "completed" or String(job.get("reason", "")) == "blocked_no_tool"

## Real SaveIO round trip (write_atomic() + read(), not just StateCodec.
## encode()/decode() directly): a save taken mid-fetch-tool-search, right
## after the tool's holder moves, must round-trip through SaveIO's own file
## boundary and then keep ticking identically to an uninterrupted run whose
## holder moves at the same simulated moment. The relocated colonist_1 no
## longer stands where colonist_0's search was frozen to look (5,0), so both
## runs are expected to settle on blocked_no_tool, not completion -- the
## point under test is that they settle on the SAME outcome at the SAME tick
## (state_hash() equality), not which outcome that is.
func _check_save_io_round_trip_mid_fetch_tool_holder_moves_matches_uninterrupted_run() -> void:
	var target := Vector2i(3, 1)
	var seed_value := 9010

	# Path A: an uninterrupted run, driven by the same scripted wall/holder-
	# move side effects as path B (both share the same frozen search cost_fn
	# regardless; the fix under test only matters at restore).
	var direct := _build_fetch_tool_racetrack_world_with_moving_holder(seed_value)
	var direct_job_id: String = _command(direct, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var direct_state := {"walled": false, "moved": false}
	var direct_ticks := 0
	while not _fetch_tool_holder_moved_job_settled(direct, direct_job_id) and direct_ticks < FETCH_TOOL_MAX_TICKS:
		_drive_fetch_tool_holder_moves_fixture(direct, direct_state)
		direct_ticks += 1
	_expect(_fetch_tool_holder_moved_job_settled(direct, direct_job_id),
		"uninterrupted run must settle (complete or blocked_no_tool) within the declared tick bound (%d)" % FETCH_TOOL_MAX_TICKS)

	# Path B: same fixture and script, saving through SaveIO's real file
	# boundary the instant colonist_1 has just moved mid-second-search.
	var source := _build_fetch_tool_racetrack_world_with_moving_holder(seed_value)
	var source_job_id: String = _command(source, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var source_state := {"walled": false, "moved": false}
	var mid_search := false
	var source_ticks := 0
	while not mid_search and source_ticks < FETCH_TOOL_MAX_TICKS:
		_drive_fetch_tool_holder_moves_fixture(source, source_state)
		source_ticks += 1
		if source_state.get("moved", false):
			mid_search = true

	_expect(mid_search, "test fixture must catch the second fetch_tool re-route still STATUS_SEARCHING right after the holder moves")
	if not mid_search:
		return

	var saved_colonist := source.get_colonists()[0]
	var saved_route = saved_colonist.get("route")
	_expect(saved_route != null and (saved_route["path"] as Array).size() >= 1,
		"the saved fetch_tool leg must still carry its stale-but-non-empty first-resolution path")

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, source.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-fetch-tool-search after the holder moved: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-fetch-tool-search after the holder moved: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored := WorldType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == source.state_hash(),
		"SaveIO round trip mid-fetch-tool-search after the holder moved must match the source's hash before any further ticks")

	while not _fetch_tool_holder_moved_job_settled(source, source_job_id) and source_ticks < FETCH_TOOL_MAX_TICKS:
		source.tick()
		restored.tick()
		source_ticks += 1
		_expect(source.state_hash() == restored.state_hash(),
			"source and restored runs must match state_hash() every tick after the mid-holder-moves save (tick %d)" % source_ticks)

	_expect(_fetch_tool_holder_moved_job_settled(source, source_job_id),
		"source run must settle (complete or blocked_no_tool) within the declared tick bound (%d) after the mid-fetch-tool-holder-moves save" % FETCH_TOOL_MAX_TICKS)
	_expect(_fetch_tool_holder_moved_job_settled(restored, source_job_id),
		"SaveIO-restored run must also settle within the declared tick bound after the holder moved mid-search")
	_expect(direct.state_hash() == restored.state_hash(),
		"a SaveIO round trip taken after the holder moves mid-search must finish with the same state_hash() as an uninterrupted run")

## Round 5 review finding: a colonist owns at most one unfinished RouteSearch
## and spends its resume() at most once per external tick, ADR 004's shared
## "at most 64 frontier expansions across all route work" budget -- but the
## scheduler's own activation search and ToilExecutor's go_to/fetch_tool
## searches were entirely separate accounting, so a worker whose job the
## scheduler just activated (spending its own pending-route search that same
## tick) could still have fetch_tool immediately start and resume a second,
## unrelated search the same tick; and a long fetch-tool-to-return-leg
## transition inside a single ToilExecutor.advance() call could resume the
## SAME search object twice. Reuses the fetch-tool racetrack fixture (a
## trivial job-target search, an axe fetch needing two resume() batches, and
## an equally long return-to-target leg once fetched) to exercise all three
## phases across one run: (1) every persisted search object's own resume_calls
## may rise by at most one per external tick, and (2) on the specific tick the
## job transitions to "active", the scheduler's own resumed search and a
## brand-new fetch_tool search object must not both have spent a resume this
## same tick.
func _check_route_budget_shared_across_scheduler_fetch_and_return() -> void:
	var target := Vector2i(1, 0)
	var seed_value := 9008
	var world := _build_fetch_tool_racetrack_world(seed_value)
	var job_id: String = _command(world, "chop", "chop", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var colonist_id := "colonist_0"

	var multi_batch_seen := false
	var checked_activation_tick := false
	var ticks := 0
	while _job_status(world, job_id) != "completed" and ticks < FETCH_TOOL_MAX_TICKS:
		var prev_search = world._reroutes.get(colonist_id)
		var prev_resume_calls := int(prev_search.resume_calls) if prev_search != null else -1
		var prev_status := _job_status(world, job_id)
		# A search already resumed at least once and still not terminal, right
		# before this tick, structurally needs at least one more resume() call
		# to finish -- proof of a genuine multi-batch search regardless of
		# whether that next resume is later observed directly on this same
		# object (it may resolve and be erased within the very tick that
		# finishes it, see below).
		if prev_search != null and prev_resume_calls >= 1 and prev_search.get_status() == RouteType.STATUS_SEARCHING:
			multi_batch_seen = true

		world.tick()
		ticks += 1

		var cur_search = world._reroutes.get(colonist_id)
		if prev_search != null and cur_search != null and prev_search == cur_search:
			var delta := int(cur_search.resume_calls) - prev_resume_calls
			_expect(delta <= 1,
				"a single in-flight search must resume at most once per external tick (tick %d, resume_calls %d -> %d)"
					% [ticks, prev_resume_calls, int(cur_search.resume_calls)])

		if prev_status != "active" and _job_status(world, job_id) == "active" and not checked_activation_tick:
			checked_activation_tick = true
			var metrics: Dictionary = world.get_scheduling_metrics()
			var ga_resumed := int((metrics.get(colonist_id, {}) as Dictionary).get("route_calls", 0)) > 0
			if ga_resumed and cur_search != null:
				_expect(int(cur_search.resume_calls) == 0,
					"the scheduler's own activation search and fetch_tool's first travel search must not both resume in the tick the job activates")

	_expect(_job_status(world, job_id) == "completed",
		"the chop job must complete within the declared tick bound (%d)" % FETCH_TOOL_MAX_TICKS)
	_expect(multi_batch_seen,
		"test fixture must force at least one search (fetch or return) to need more than one resume() batch")

func _check_save_load_mid_reroute_matches_uninterrupted_run() -> void:
	var target := Vector2i(5, 0)
	var seed_value := 9004

	# Path A: an uninterrupted run straight through to completion.
	var direct := _build_racetrack_world(seed_value)
	var direct_job_id: String = _command(direct, "dig", "dig", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var direct_walled := false
	var direct_ticks := 0
	while _job_status(direct, direct_job_id) != "completed" and direct_ticks < SAVE_LOAD_MAX_TICKS:
		direct_walled = _tick_and_wall_once(direct, direct_walled)
		direct_ticks += 1
	_expect(_job_status(direct, direct_job_id) == "completed",
		"uninterrupted run must complete within the declared tick bound (%d)" % SAVE_LOAD_MAX_TICKS)

	# Path B: save the instant the re-route search is still STATUS_SEARCHING
	# (mid-flight, not yet resolved), restore into a fresh WorldState, then
	# advance identically.
	var source := _build_racetrack_world(seed_value)
	var source_job_id: String = _command(source, "dig", "dig", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var source_walled := false
	var mid_search := false
	var source_ticks := 0
	while not mid_search and source_ticks < SAVE_LOAD_MAX_TICKS:
		source_walled = _tick_and_wall_once(source, source_walled)
		source_ticks += 1
		var colonist := source.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null and route["rerouting"]["status"] == "searching":
			mid_search = true

	_expect(mid_search, "test fixture must catch the re-route search still STATUS_SEARCHING (mid-flight)")
	if not mid_search:
		return

	var saved := source.to_save_state()
	var restored := WorldType.from_save_state(saved)
	_expect(restored.state_hash() == source.state_hash(),
		"restore mid-reroute must match the source's hash before any further ticks")

	while _job_status(source, source_job_id) != "completed" and source_ticks < SAVE_LOAD_MAX_TICKS:
		source.tick()
		restored.tick()
		source_ticks += 1

	_expect(_job_status(source, source_job_id) == "completed",
		"source run must complete within the declared tick bound (%d) after the mid-reroute save" % SAVE_LOAD_MAX_TICKS)
	_expect(_job_status(restored, source_job_id) == "completed",
		"restored run must also complete within the declared tick bound after the mid-reroute save")
	_expect(source.state_hash() == restored.state_hash(),
		"a mid-reroute save/load must finish with the same state_hash() as an uninterrupted run")
	_expect(direct.state_hash() == restored.state_hash(),
		"the mid-reroute-interrupted run must match the uninterrupted run's final state_hash()")

## Regression for the schemaVersion-5 route.rerouting field: a mid-reroute
## state must actually round-trip through SaveIO's file boundary (validated
## write_atomic() + read(), not just StateCodec.encode()/decode() directly as
## _check_save_load_mid_reroute_matches_uninterrupted_run() does above), since
## SaveIO's own _valid_entity_route() allow-list is what previously rejected
## the extra "rerouting" key on read.
func _check_save_io_round_trip_mid_reroute_matches_uninterrupted_run() -> void:
	var target := Vector2i(5, 0)
	var seed_value := 9005

	var direct := _build_racetrack_world(seed_value)
	var direct_job_id: String = _command(direct, "dig", "dig", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var direct_walled := false
	var direct_ticks := 0
	while _job_status(direct, direct_job_id) != "completed" and direct_ticks < SAVE_LOAD_MAX_TICKS:
		direct_walled = _tick_and_wall_once(direct, direct_walled)
		direct_ticks += 1
	_expect(_job_status(direct, direct_job_id) == "completed",
		"uninterrupted run must complete within the declared tick bound (%d)" % SAVE_LOAD_MAX_TICKS)

	var source := _build_racetrack_world(seed_value)
	var source_job_id: String = _command(source, "dig", "dig", {"x": target.x, "y": target.y, "priority": 1})["job_id"]
	var source_walled := false
	var mid_search := false
	var source_ticks := 0
	while not mid_search and source_ticks < SAVE_LOAD_MAX_TICKS:
		source_walled = _tick_and_wall_once(source, source_walled)
		source_ticks += 1
		var colonist := source.get_colonists()[0]
		var route = colonist.get("route")
		if route != null and route.get("rerouting") != null and route["rerouting"]["status"] == "searching":
			mid_search = true

	_expect(mid_search, "test fixture must catch the re-route search still STATUS_SEARCHING (mid-flight)")
	if not mid_search:
		return

	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TEST_PATH, source.to_save_state())
	_expect(write_result["ok"], "SaveIO must accept a save taken mid-reroute: %s" % write_result.get("message", ""))
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TEST_PATH)
	_expect(read_result["ok"], "SaveIO must read back a save taken mid-reroute: %s" % read_result.get("message", ""))
	if FileAccess.file_exists(SAVE_IO_TEST_PATH):
		DirAccess.remove_absolute(SAVE_IO_TEST_PATH)
	if not read_result["ok"]:
		return

	var restored := WorldType.from_save_state(read_result["state"])
	_expect(restored.state_hash() == source.state_hash(),
		"SaveIO round trip mid-reroute must match the source's hash before any further ticks")

	while _job_status(source, source_job_id) != "completed" and source_ticks < SAVE_LOAD_MAX_TICKS:
		source.tick()
		restored.tick()
		source_ticks += 1

	_expect(_job_status(restored, source_job_id) == "completed",
		"SaveIO-restored run must complete within the declared tick bound after the mid-reroute save")
	_expect(direct.state_hash() == restored.state_hash(),
		"a SaveIO round trip taken mid-reroute must finish with the same state_hash() as an uninterrupted run")
