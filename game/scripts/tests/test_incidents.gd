extends SceneTree

## F5 incidents (issue #294): exercises IncidentScheduler's day-gated budget
## draw, its spawn_incident debug command (and the viewer's dispatch of it),
## the shared job/toil dispatch a spawned actor's walk/wait runs through,
## activation-gated spawning (a proposed actor enters the world only once its
## job activates through the ordinary scheduler tick), faction-aware
## routing/door blocking, the exact content-declared wait, lifecycle cleanup
## on every terminal transition, queue-clock lockstep, and the real SaveIO
## round trip during travel, during the wait, and after despawn.
## incidents_enabled defaults false (see world_state.gd's own doc comment on
## _init()), so every check that wants incidents active passes the third
## constructor argument explicitly.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SaveManagerType = preload("res://scripts/core/persistence/save_manager.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")
const AutosaveTriggerType = preload("res://scripts/viewer/autosave_trigger.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")

const SAVE_PATH := "user://test-incidents-save.json"
const BOOT_RESTORE_DIR := "user://test-incidents-boot-restore"
const NEW_GAME_SAVE_DIR := "user://test-incidents-new-game"
const BOOT_SCENE_PATH := "res://scenes/boot.tscn"
const TICK_RATE := 10
## content/calendar.json's day_length_ticks (issue #349/ADR 023: 2200, was
## 100): tick 4400 is the first tick of day 3.
const DAY_LENGTH_TICKS := 2200
const DAY3_TICK := 2 * DAY_LENGTH_TICKS
## The original 600 gave a fixed 400-tick margin past DAY3_TICK (200) for the
## draw+activation itself to complete -- that overhead is route/scheduler
## work, not day-length-dependent, so the margin stays a flat 400 rather than
## scaling with DAY_LENGTH_TICKS.
const TICK_BUDGET := DAY3_TICK + 400
## issue #300 round 1 review finding 8: the one real (uncontrolled) boot-scene
## check that ticks its own world --
## _check_viewer_dispatches_spawn_incident()'s wait for a viewer-triggered
## actor to enter the world -- now builds at the default New Game size
## (256x256, docs/decisions/020, boot.gd's build_default_world()) instead of
## the old 48x48 debug scenario. Finding a valid bare edge spawn tile and
## walking in from it takes meaningfully longer on a map over 5x wider/taller,
## on top of content/incidents.json's own spawn.wait_ticks (60 for
## trader_visit); an actor was observed found at tick 642. This bound is
## passed explicitly only at that one call site, never by raising the shared
## TICK_BUDGET default above (round 1 review: that would have silently
## loosened every unrelated small-controlled-world regression's own bound).
## The many _build_controlled_world()/_build_pocket_world() checks below stay
## their own small, fully controlled size and complete well within the
## original 600-tick TICK_BUDGET.
const BOOT_TICK_BUDGET := 1500
const WALL_X := 2
const DOOR_Y := 24
const GAP_Y := 0
const NO_TILE := Vector2i(-1, -1)

## Issue #398 (ADR 032): content/incidents.json's test-only "raider_incursion"
## row (raiders faction, hostile to colony per content/factions.json; wolf
## actor_def reused as a fixture, spawn.lingers: true). min_day 10 sits
## comfortably past both this file's fixed-day checks (day 3's
## wildlife_wander draw, trader_visit's day-5 min_day), so it never fires
## inside them.
const LINGER_INCIDENT_ID := "raider_incursion"
const LINGER_MIN_DAY := 10
const LINGER_SPAWN := Vector2i(24, 0)
## Bare floor tiles strictly between the spawn and the door, all genuinely
## NOT Chebyshev-adjacent to it: with LINGER_NEAR_DOOR_TILE sealed off for
## the one tick that runs the daily draw, these are IncidentScheduler's own
## _pick_reachable_target()'s ONLY candidates, so whichever one its seeded
## RNG picks, the incident's own destination is guaranteed non-adjacent to
## the door -- proving the later hand-off is the generic ApproachGiver
## behaviour, not a coincidental incident-target pick (mirrors the reference
## fix in commit 164a29de).
const LINGER_FAR_CORRIDOR_START_Y := 1
const LINGER_FAR_CORRIDOR_END_Y := 5
const LINGER_NEAR_DOOR_TILE := Vector2i(24, 6)
const LINGER_DOOR_TILE := Vector2i(24, 7)
const LINGER_ARRIVAL_BUDGET := 900
const LINGER_ATTACK_OBSERVE_TICKS := 90

var _failed := false

func _init() -> void:
	_check_natural_daily_draw_spawns_wildlife_on_day3()
	_check_same_seed_reproduces_same_spawns_and_hash()
	_check_disabled_reproduces_pre_incident_hash()
	_check_spawned_actor_faction_and_door_block()
	_check_shared_engine_dispatch()
	_check_initial_route_avoids_door_via_alternate_route()
	_check_unreachable_candidate_is_never_spawned()
	_check_door_introduced_mid_travel_blocks_wildlife()
	_check_actor_despawns_after_exact_wait()
	_check_spawn_incident_debug_command()
	_check_two_actor_race_spawns_only_the_winner()
	_check_reserved_by_colonist_job_defers_spawn()
	_check_incident_submission_does_not_disturb_queue_clock_or_backoff()
	_check_cleanup_on_every_terminal_transition()
	_check_unreachable_travel_clears_progress_for_next_job()
	_check_cancelling_queued_competitor_preserves_active_owner_wait()
	_check_door_on_spawn_tile_during_pending_route_retires_proposal()
	_check_door_on_destination_during_travel_is_never_reached()
	_check_terminate_during_active_reroute_releases_search()
	_check_save_load_mid_incident()
	_check_viewer_dispatches_spawn_incident()
	_check_incidents_enabled_after_startup_restore_and_manual_load()
	_check_incidents_enabled_after_new_game_and_survive_save_load()
	_check_lingering_actor_survives_arrival_and_hands_off_to_approach()
	_check_lingering_incident_same_seed_reproduces_hash()

	if _failed:
		quit(1)
		return
	print("test_incidents: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _tick_to(world: WorldStateType, target_tick: int) -> void:
	while world.get_tick() < target_tick:
		world.tick()

## Ticks until predicate(world) holds; the number of ticks spent, or -1 when
## the budget ran out first.
func _tick_until(world: WorldStateType, predicate: Callable, budget: int = TICK_BUDGET) -> int:
	for i in budget:
		if predicate.call(world):
			return i
		world.tick()
	return -1 if not predicate.call(world) else budget

func _incident_started_events(world: WorldStateType, incident_id: String) -> Array:
	var matches: Array = []
	for event in world.get_events():
		if String(event["type"]) == "incident_started" and String(event["data"]["incident_id"]) == incident_id:
			matches.append(event)
	return matches

func _spawn_incident_command(world: WorldStateType, command_id: String, incident_id: String) -> Dictionary:
	return world.apply({
		"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": "spawn_incident", "payload": {"id": incident_id},
	})

func _job_command(world: WorldStateType, command_id: String, type: String, job_id: String) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": type, "payload": {"job_id": job_id}})

func _wait_ticks_of(world: WorldStateType, incident_id: String) -> int:
	return int(world._content.get_entry("incidents", incident_id)["spawn"]["wait_ticks"])

## First in-bounds tile with no colonist, no object and not a tree -- a valid
## place_object target regardless of the seed's generated terrain.
func _find_placeable_tile(world: WorldStateType) -> Vector2i:
	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH:
			if world.get_tile(x, y) != WorldStateType.TILE_TREE and world.get_object(x, y) == "" and not world._colonist_at(x, y):
				return Vector2i(x, y)
	return NO_TILE

func _place(world: WorldStateType, x: int, y: int, kind: String) -> Dictionary:
	return world.apply({"actor": "test", "command_id": "place_%s_%d_%d" % [kind, x, y], "tick": world.get_tick(),
		"type": "place_object", "payload": {"x": x, "y": y, "kind": kind}})

## A full-height double-thick wall at x in {WALL_X, WALL_X+1} with one door
## gap at y=DOOR_Y in both columns: a wildlife actor can only ever cross
## through the door tile itself, which it cannot use.
func _build_wall_column(world: WorldStateType, x: int, door_y: int) -> void:
	for offset in [0, 1]:
		for y in WorldStateType.MAP_HEIGHT:
			_place(world, x + offset, y, "door" if y == door_y else "wooden_wall")

## A single-column wall at x with a door at door_y and, when gap_y >= 0, one
## open floor tile at gap_y: the door is the short way through, the gap the
## only way a faction that may not pass doors can take.
func _build_single_wall(world: WorldStateType, x: int, door_y: int, gap_y: int) -> void:
	for y in WorldStateType.MAP_HEIGHT:
		if y == gap_y:
			continue
		_place(world, x, y, "door" if y == door_y else "wooden_wall")

## A fully controlled, tree/water-free world (test_haul_stockpile.gd's own
## pattern): safe to overwrite _tiles/_colonists directly since _regions/
## _rooms are built lazily, never at _init(), so a direct overwrite can never
## leave them stale.
func _build_controlled_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	# issue #300: a freshly generated world can now place berry_bush objects
	# (docs/decisions/020); a leftover one would make _is_bare_tile() false
	# for whichever tile it landed on, breaking this fixture's "fully
	# determined" spawn/target selection.
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	return world

## A controlled world whose only passable tiles are the given ones, so the
## real spawn path (edge tile + random same-region bare target) is fully
## determined: the first passable west-edge tile is the spawn tile and the
## remaining tiles are the only candidate targets.
func _build_pocket_world(seed_value: int, floor_tiles: Array) -> WorldStateType:
	var world := WorldStateType.new(seed_value, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	world._objects.clear()
	world._object_factions.clear()
	for tile in floor_tiles:
		world._tiles[world._tile_index(tile.x, tile.y)] = WorldStateType.TILE_FLOOR
	world._colonists.clear()
	return world

func _colonist(id: String, x: int, y: int) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y, "route": null, "work": null, "carrying": null}

func _make_wolf(world: WorldStateType, actor_id: String, x: int, y: int) -> Dictionary:
	var actor := ActorTableType.spawn("wolf", x, y, world._content, actor_id)
	actor["factionId"] = "wildlife"
	return actor

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

func _find_haul_job(world: WorldStateType) -> Dictionary:
	for job in world.get_jobs():
		if String(job["kind"]) == "haul":
			return job
	return {}

func _assignment_job_id(world: WorldStateType, actor_id: String) -> String:
	return String(world.get_assignments().get(actor_id, {}).get("job_id", ""))

func _in_world(actor_id: String) -> Callable:
	return func(world: WorldStateType) -> bool: return not world._find_colonist(actor_id).is_empty()

func _gone(actor_id: String) -> Callable:
	return func(world: WorldStateType) -> bool: return world._find_colonist(actor_id).is_empty()

func _actor_pos(world: WorldStateType, actor_id: String) -> Vector2i:
	var actor := world._find_colonist(actor_id)
	return Vector2i(int(actor["x"]), int(actor["y"])) if not actor.is_empty() else NO_TILE

func _check_natural_daily_draw_spawns_wildlife_on_day3() -> void:
	if _failed: return
	var world := WorldStateType.new(4242, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	_tick_to(world, DAY3_TICK)
	var events := _incident_started_events(world, "wildlife_wander")
	_expect(events.size() == 1, "day 3 must draw wildlife_wander exactly once under the daily budget")
	if events.is_empty(): return
	var actor_ids: Array = events[0]["data"]["actor_ids"]
	_expect(actor_ids.size() == 2, "wildlife_wander must propose its content-declared count of 2 wolves")
	for actor_id in actor_ids:
		_expect(_tick_until(world, _in_world(String(actor_id))) >= 0,
			"proposed actor '%s' must enter the world once its job activates" % actor_id)
		var actor := world._find_colonist(String(actor_id))
		if actor.is_empty(): continue
		_expect(String(actor.get("kind", "")) == "wolf", "wildlife_wander must spawn wolves")
		_expect(String(actor.get("factionId", "")) == "wildlife", "a wildlife_wander actor must carry the wildlife faction")
	_expect(_incident_started_events(world, "trader_visit").is_empty(),
		"trader_visit's min_day is 5, it must not fire on day 3")

func _check_same_seed_reproduces_same_spawns_and_hash() -> void:
	if _failed: return
	var a := WorldStateType.new(777, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	var b := WorldStateType.new(777, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	_tick_to(a, DAY3_TICK + 50)
	_tick_to(b, DAY3_TICK + 50)
	_expect(a.state_hash() == b.state_hash(), "the same seed must reproduce the same state hash after day 3's draw")
	var events_a := _incident_started_events(a, "wildlife_wander")
	var events_b := _incident_started_events(b, "wildlife_wander")
	_expect(events_a.size() == 1 and events_b.size() == 1, "the same seed must reproduce the same number of draws")
	if events_a.size() == 1 and events_b.size() == 1:
		_expect(events_a[0]["data"]["actor_ids"] == events_b[0]["data"]["actor_ids"],
			"the same seed must reproduce the same proposed actor ids")

## The genuine pre-#294 baseline is test_toils_dig_chop_regression.gd's own
## unchanged COLONY_EXPECTED_HASH literal (a world that never enables
## incidents); here: the default and an explicitly disabled world match on
## the full hash (their lastProcessedDay never advances either), and enabling
## incidents perturbs colony state (state_hash(false), the projection that
## excludes cooldownUntilDay/lastProcessedDay/rng) nothing until a draw
## actually proposes an actor. Comparing the FULL hash between an enabled and
## a disabled world would fail before that first draw regardless: an enabled
## world's own lastProcessedDay legitimately advances on every calendar-day
## boundary (issue #295, state_hash()'s day-gate coverage) while a disabled
## world's never does, since IncidentScheduler.advance() is a true no-op
## while disabled -- that divergence is real incident-scheduler state, not a
## colony-state leak, so it belongs outside this RNG-isolation comparison.
func _check_disabled_reproduces_pre_incident_hash() -> void:
	if _failed: return
	var default_world := WorldStateType.new(4242, TICK_RATE) # incidents_enabled defaults false
	var disabled_world := WorldStateType.new(4242, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, false)
	var enabled_world := WorldStateType.new(4242, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	_tick_to(enabled_world, DAY3_TICK - 1)
	_tick_to(disabled_world, DAY3_TICK - 1)
	_expect(enabled_world.state_hash(false) == disabled_world.state_hash(false),
		"an enabled world's colony state must hash identically to a disabled one until its first draw (own RNG stream, no shared draw)")
	_expect(enabled_world._random.seed == disabled_world._random.seed and enabled_world._random.state == disabled_world._random.state,
		"an enabled world's own colony RNG stream must stay identical to a disabled world's until an incident draw actually spawns an actor")
	_tick_to(default_world, DAY3_TICK + DAY_LENGTH_TICKS)
	_tick_to(disabled_world, DAY3_TICK + DAY_LENGTH_TICKS)
	_expect(default_world.state_hash() == disabled_world.state_hash(),
		"the default (incidents off) and an explicitly-disabled world must match exactly")
	_expect(_incident_started_events(default_world, "wildlife_wander").is_empty(),
		"incidents must never fire when disabled, even well past min_day")
	_expect(default_world._colonists.size() == 3,
		"a disabled world must never grow the actor roster beyond its 3 starting colonists")
	for entry in default_world._scheduler.get_waiting():
		_expect(not entry.has("autonomous"), "an ordinary queue entry must never carry the autonomous flag")

func _check_spawned_actor_faction_and_door_block() -> void:
	if _failed: return
	var world := WorldStateType.new(101, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	var door := _find_placeable_tile(world)
	_expect(door != NO_TILE, "the generated map must offer at least one placeable tile")
	if door == NO_TILE: return
	_expect(_place(world, door.x, door.y, "door").get("ok", false), "placing the test door must be accepted")
	var spawn_result := _spawn_incident_command(world, "force_wildlife_door", "wildlife_wander")
	_expect(spawn_result.get("ok", false), "spawn_incident must be accepted for a known incident id")
	var actor_ids: Array = spawn_result.get("actor_ids", [])
	_expect(actor_ids.size() == 2, "spawn_incident must propose wildlife_wander's full count")
	if actor_ids.is_empty(): return
	var actor_id := String(actor_ids[0])
	_expect(_tick_until(world, _in_world(actor_id)) >= 0, "a proposed wolf must enter the world once its job activates")
	var actor := world._find_colonist(actor_id)
	_expect(String(actor.get("factionId", "")) == "wildlife", "a forced wildlife_wander actor must carry the wildlife faction")
	var wildlife_result := world.passability(door.x, door.y, "wildlife")
	_expect(not bool(wildlife_result["passable"]) and bool(wildlife_result["is_door"]),
		"a wildlife-faction actor must not be able to pass a colony door")
	_expect(bool(world.passability(door.x, door.y, "colony")["passable"]), "a colony actor must still be able to pass the same door")

## A spawned actor's walk/wait is a real content/jobs.json "incident" job
## driven through GlobalAssignment/JobQueue/ToilExecutor -- the same
## get_jobs()/get_assignments() surface every other job uses. Submission
## only stages the actor; it enters the world the tick its job activates
## through WorldState's ordinary _scheduler.tick() pass (possibly not the
## next tick, if the bounded route search to its target spans several).
func _check_shared_engine_dispatch() -> void:
	if _failed: return
	var world := WorldStateType.new(606, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	var spawn_result := _spawn_incident_command(world, "force_wildlife_dispatch", "wildlife_wander")
	var actor_ids: Array = spawn_result.get("actor_ids", [])
	_expect(actor_ids.size() == 2, "spawn_incident must propose 2 wolves")
	if actor_ids.is_empty(): return
	var actor_id := String(actor_ids[0])
	_expect(world._find_colonist(actor_id).is_empty(), "a proposed actor must not be in the world before its job activates")
	_expect(world._incidents.staged_actors().size() == 2, "both proposed wolves must be staged, not spawned")
	_expect(_tick_until(world, _in_world(actor_id)) >= 0, "the staged wolf must spawn once its job activates")
	var assignment: Dictionary = world.get_assignments().get(actor_id, {})
	_expect(not assignment.is_empty(), "a spawned incident actor must carry an ordinary scheduler assignment the tick it enters")
	var job := _find_job(world, String(assignment.get("job_id", "")))
	_expect(not job.is_empty(), "the assigned job_id must resolve through the ordinary JobQueue.get_jobs() surface")
	_expect(String(job.get("kind", "")) == "incident", "an incident actor's job must carry the 'incident' kind")
	_expect(String(job.get("status", "")) == "active", "a spawned incident actor's job must be active")

## A single wall with a door (the short way) and one far gap: the wolf's
## INITIAL route (GlobalAssignment's own bounded search, run under the
## wolf's faction) must avoid the door and reach the target via the gap,
## while a colonist ordered beyond the same wall routes straight through
## the door.
func _check_initial_route_avoids_door_via_alternate_route() -> void:
	if _failed: return
	var world := _build_controlled_world(303)
	_build_single_wall(world, WALL_X, DOOR_Y, GAP_Y)
	var wolf_target := Vector2i(WALL_X + 2, DOOR_Y)
	var till_target := Vector2i(WALL_X + 2, DOOR_Y + 1)
	world._tiles[world._tile_index(till_target.x, till_target.y)] = WorldStateType.TILE_SOIL
	world._colonists.append(_colonist("door_colonist", 0, DOOR_Y + 1))
	var job_id := world._incidents.propose(_make_wolf(world, "gap_wolf", 0, DOOR_Y), wolf_target, 5)
	_expect(not job_id.is_empty(), "the wolf's job must be accepted")
	var till_result := world.apply({"actor": "test", "command_id": "till_beyond", "tick": world.get_tick(),
		"type": "till", "payload": {"x": till_target.x, "y": till_target.y, "priority": 1}})
	_expect(till_result.get("ok", false), "the colonist's till order beyond the wall must be accepted")

	# The colonist's short route activates (and finishes) long before the
	# wolf's detour is even found, so capture its initial route first.
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return not w.get_assignments().get("door_colonist", {}).is_empty()) >= 0,
		"the colonist's till job must activate")
	var colonist_path: Array = world.get_assignments().get("door_colonist", {}).get("path", [])
	_expect(colonist_path.has(Vector2i(WALL_X, DOOR_Y)), "the colonist's initial route must pass through the door (the short way)")

	_expect(_tick_until(world, _in_world("gap_wolf")) >= 0, "the wolf must spawn once its faction-aware route is found")
	var wolf_path: Array = world.get_assignments().get("gap_wolf", {}).get("path", [])
	_expect(wolf_path.size() > 1, "the wolf's assignment must carry the initial route")
	var wolf_crossings := 0
	for tile in wolf_path:
		if (tile as Vector2i).x == WALL_X:
			wolf_crossings += 1
			_expect((tile as Vector2i).y == GAP_Y, "the wolf's initial route must cross the wall only at the gap, never the door (at %s)" % [tile])
	_expect(wolf_crossings == 1, "the wolf's initial route must cross the wall line exactly once")
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return _actor_pos(w, "gap_wolf") == wolf_target) >= 0,
		"the wolf must reach its target via the gap")
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return _actor_pos(w, "door_colonist") == till_target) >= 0,
		"the colonist must reach the till target through the door")

## A wall with a door and no gap: a candidate target beyond it is
## unreachable for wildlife. The shared bounded search proves it, the job is
## retired through the finish boundary, and the actor never enters the world.
func _check_unreachable_candidate_is_never_spawned() -> void:
	if _failed: return
	var world := _build_controlled_world(303)
	_build_single_wall(world, WALL_X, DOOR_Y, -1)
	var target := Vector2i(WALL_X + 2, DOOR_Y)
	var job_id := world._incidents.propose(_make_wolf(world, "blocked_wolf", 0, DOOR_Y), target, 5)
	_expect(not job_id.is_empty(), "the wolf's job must be accepted")
	var ticks := 0
	while ticks < TICK_BUDGET and String(_find_job(world, job_id).get("status", "")) in ["queued", "active"]:
		world.tick()
		ticks += 1
		_expect(world._find_colonist("blocked_wolf").is_empty(), "a wolf whose target is unreachable for wildlife must never enter the world")
	_expect(String(_find_job(world, job_id).get("status", "")) == "cancelled",
		"the unreachable incident job must be retired (cancelled), not left queued forever")
	_expect(world._incidents.staged_actors().is_empty(), "a retired proposal must leave nothing staged")
	_expect(world._get_work_progress(target) == null, "a never-activated incident job must never stamp a work-progress key")
	_expect(world.get_assignments().is_empty(), "a never-activated incident job must never produce an assignment")

## Dynamic case: the map is open when the actor starts walking and a wall
## with a door is introduced mid-travel, so the re-route path (bounded
## search under the actor's own faction) blocks the wolf too.
func _check_door_introduced_mid_travel_blocks_wildlife() -> void:
	if _failed: return
	var world := _build_controlled_world(303)
	var target := Vector2i(WALL_X + 10, DOOR_Y)
	var job_id := world._incidents.propose(_make_wolf(world, "travel_wolf", 0, DOOR_Y), target, 5)
	_expect(not job_id.is_empty(), "the wolf's job must be accepted")
	_expect(_tick_until(world, _in_world("travel_wolf")) >= 0, "the wolf must spawn on the open map")
	world.tick()
	_expect(_actor_pos(world, "travel_wolf").x < WALL_X, "the wolf must still be on the spawn side when the wall goes up")
	_build_wall_column(world, WALL_X, DOOR_Y)
	for i in TICK_BUDGET:
		world.tick()
		if world._find_colonist("travel_wolf").is_empty():
			break
		_expect(_actor_pos(world, "travel_wolf").x < WALL_X,
			"a wildlife actor must never cross a colony door's wall column (tick %d)" % world.get_tick())
	_expect(world._find_colonist("travel_wolf").is_empty(), "the walled-off wolf must despawn once its target proves unreachable")
	_expect(String(_find_job(world, job_id).get("status", "")) == "cancelled", "the walled-off wolf's job must be cancelled")
	_expect(world._get_work_progress(target) == null, "the cancelled incident job must clear its stamped wait")

## For both seed incidents, through the real spawn path: the actor waits
## exactly its content-declared wait_ticks work steps after arriving (the
## work toil takes its first step on the arrival tick itself, so the despawn
## tick is arrival + wait_ticks - 1), and the two kinds' waits differ by
## exactly their content difference.
func _check_actor_despawns_after_exact_wait() -> void:
	if _failed: return
	var measured: Dictionary = {}
	for incident_id in ["wildlife_wander", "trader_visit"]:
		var world := _build_controlled_world(202)
		var spawn_result := _spawn_incident_command(world, "force_%s" % incident_id, incident_id)
		var actor_ids: Array = spawn_result.get("actor_ids", [])
		_expect(not actor_ids.is_empty(), "%s must propose at least one actor" % incident_id)
		if actor_ids.is_empty(): return
		var actor_id := String(actor_ids[0])
		_expect(_tick_until(world, _in_world(actor_id)) >= 0, "%s's actor must spawn" % incident_id)
		var target: Vector2i = _find_job(world, _assignment_job_id(world, actor_id)).get("target", NO_TILE)
		_expect(target != NO_TILE, "%s's actor must carry an active job target" % incident_id)
		_expect(_tick_until(world, func(w: WorldStateType) -> bool: return _actor_pos(w, actor_id) == target) >= 0,
			"%s's actor must arrive at its target" % incident_id)
		var arrival_tick := world.get_tick()
		var wait_ticks := _wait_ticks_of(world, incident_id)
		var work = world._find_colonist(actor_id).get("work")
		_expect(work != null and int(work["ticks_remaining"]) == wait_ticks - 1,
			"%s's work toil must start from the content-declared wait (%d) on arrival, got %s" % [incident_id, wait_ticks, work])
		_expect(_tick_until(world, _gone(actor_id)) >= 0, "%s's actor must despawn" % incident_id)
		var lived := world.get_tick() - arrival_tick
		_expect(lived == wait_ticks - 1,
			"%s's actor must despawn exactly wait_ticks (%d) work steps after arrival, lived %d ticks past arrival" % [incident_id, wait_ticks, lived])
		_expect(world._get_work_progress(target) == null, "a completed incident job must leave no work-progress key")
		_expect(world.get_assignments().get(actor_id, {}).is_empty(), "a despawned actor must leave no assignment (got %s)" % [world.get_assignments()])
		measured[incident_id] = lived
	if measured.size() == 2:
		var content_delta := _wait_ticks_of(_build_controlled_world(1), "trader_visit") - _wait_ticks_of(_build_controlled_world(1), "wildlife_wander")
		_expect(int(measured["trader_visit"]) - int(measured["wildlife_wander"]) == content_delta,
			"the two incidents' measured waits must differ by exactly their content-declared difference")

func _check_spawn_incident_debug_command() -> void:
	if _failed: return
	var world := WorldStateType.new(303, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	var bad_result := _spawn_incident_command(world, "bad_incident", "not_a_real_incident")
	_expect(not bad_result.get("ok", true) and bad_result["rejection"]["reason"] == "invalid_payload",
		"spawn_incident for an unknown id must be rejected invalid_payload")
	var disabled_world := WorldStateType.new(404, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, false)
	var disabled_result := _spawn_incident_command(disabled_world, "disabled_incident", "wildlife_wander")
	_expect(not disabled_result.get("ok", true) and disabled_result["rejection"]["reason"] == "invalid_target",
		"spawn_incident must be rejected when incidents are disabled for this world")
	# force_spawn bypasses min_day gating entirely -- trader_visit's min_day is
	# 5, but a debug trigger on a fresh (tick 0/day 1) world must still work.
	var trader_result := _spawn_incident_command(world, "force_trader_early", "trader_visit")
	_expect(trader_result.get("ok", false), "spawn_incident must bypass min_day gating")
	_expect((trader_result.get("actor_ids", []) as Array).size() == 1,
		"trader_visit must propose its content-declared count of 1 trader")

## Real spawn path, two wolves, one possible target (a two-tile pocket): the
## ordinary reservation-conflict path (JobQueue.tick()'s target check via
## the normal advance_selection() call) activates exactly one; the loser
## stays queued blocked_target_reserved, unspawned, unstamped, until the
## winner's job releases the target -- then it spawns and runs in turn.
func _check_two_actor_race_spawns_only_the_winner() -> void:
	if _failed: return
	var spawn := Vector2i(0, 10)
	var target := Vector2i(1, 10)
	var world := _build_pocket_world(909, [spawn, target])
	var spawn_result := _spawn_incident_command(world, "race", "wildlife_wander")
	var actor_ids: Array = spawn_result.get("actor_ids", [])
	_expect(actor_ids.size() == 2, "both wolves must be proposed (both queue submissions accepted)")
	if actor_ids.size() != 2: return
	_expect(world._colonists.is_empty(), "no proposed wolf may be in the world before activation")
	world.tick()
	var winner := ""
	var loser := ""
	for actor_id in actor_ids:
		if not world._find_colonist(String(actor_id)).is_empty():
			winner = String(actor_id)
		else:
			loser = String(actor_id)
	_expect(not winner.is_empty() and not loser.is_empty(), "exactly one of two wolves racing for one target may spawn this tick")
	if winner.is_empty() or loser.is_empty(): return
	var winner_job := _find_job(world, _assignment_job_id(world, winner))
	_expect(String(winner_job.get("status", "")) == "active" and winner_job.get("target") == target,
		"the winner's job must be active on the shared target")
	var loser_jobs: Array = []
	for job in world.get_jobs():
		if String(job["kind"]) == "incident" and String(job["id"]) != String(winner_job.get("id", "")):
			loser_jobs.append(job)
	_expect(loser_jobs.size() == 1, "the loser must have exactly one queued incident job")
	if loser_jobs.size() != 1: return
	_expect(String(loser_jobs[0]["status"]) == "queued" and String(loser_jobs[0]["reason"]) == "blocked_target_reserved",
		"the losing incident job must stay queued with the ordinary target-reserved reason, got %s" % [loser_jobs[0]])
	_expect(world._incidents.staged_actors().size() == 1, "the loser must stay staged, not spawned")
	_expect(int(world._get_work_progress(target)) == _wait_ticks_of(world, "wildlife_wander"),
		"only the winner's own confirmed-active job may stamp the shared target's work-progress key")
	_expect(_tick_until(world, _gone(winner)) >= 0, "the winner must finish and despawn")
	_expect(_tick_until(world, _in_world(loser)) >= 0, "the loser must spawn once the target is released")
	_expect(_tick_until(world, _gone(loser)) >= 0, "the loser must then finish and despawn in turn")
	_expect(world._colonists.is_empty() and world._incidents.staged_actors().is_empty() and world._get_work_progress(target) == null,
		"after both runs nothing may remain: no actor, no staged proposal, no work-progress key")

## Real spawn path against a target already reserved by a colonist's own
## job: the wolf stays staged until the till job releases the tile.
func _check_reserved_by_colonist_job_defers_spawn() -> void:
	if _failed: return
	var spawn := Vector2i(0, 10)
	var target := Vector2i(1, 10)
	var world := _build_pocket_world(919, [spawn, target])
	world._tiles[world._tile_index(target.x, target.y)] = WorldStateType.TILE_SOIL
	world._colonists.append(_colonist("tiller", target.x, target.y))
	_expect(world.apply({"actor": "test", "command_id": "till_pocket", "tick": world.get_tick(),
		"type": "till", "payload": {"x": target.x, "y": target.y, "priority": 1}}).get("ok", false), "the till order must be accepted")
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return not w.get_assignments().get("tiller", {}).is_empty()) >= 0,
		"the till job must activate and hold the target's reservation")
	var spawn_result := _spawn_incident_command(world, "reserved", "wildlife_wander")
	var actor_ids: Array = spawn_result.get("actor_ids", [])
	_expect(actor_ids.size() == 2, "both wolves must be proposed")
	if actor_ids.is_empty(): return
	var till_job_id := _assignment_job_id(world, "tiller")
	for i in 5:
		world.tick()
		_expect(world._colonists.size() == 1, "no wolf may spawn while a colonist's job holds the only target (tick %d)" % world.get_tick())
	var stamped = world._get_work_progress(target)
	_expect(stamped == null or int(stamped) < 40 and String(_find_job(world, till_job_id).get("status", "")) == "active",
		"the shared target's work-progress key may only hold the till job's own progress, never a staged wolf's wait")
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return String(_find_job(w, till_job_id).get("status", "")) == "completed") >= 0,
		"the till job must complete and release the target")
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return w._colonists.size() == 2) >= 0,
		"one wolf must spawn once the colonist's job releases the target")

## Submitting incident jobs (one debug command proposing two wolves) inside
## a tick must never tick JobQueue's/GlobalAssignment's shared clock outside
## WorldState's own single per-tick _scheduler.tick() pass -- proven directly
## and by comparing an unrelated, permanently-backed-off haul job's retry
## schedule (no stockpile zone exists) against an incident-free baseline.
func _check_incident_submission_does_not_disturb_queue_clock_or_backoff() -> void:
	if _failed: return
	var baseline := _build_controlled_world(1111)
	var with_incidents := _build_controlled_world(1111)
	for world in [baseline, with_incidents]:
		world._colonists.append(_colonist("solo_colonist", 5, 5))
		world._items["wood_1"] = {"id": "wood_1", "x": 20, "y": 20, "kind": "wood", "count": 1}
	for i in 40:
		baseline.tick()
		if i == 5:
			var spawn_result := _spawn_incident_command(with_incidents, "clock", "wildlife_wander")
			_expect((spawn_result.get("actor_ids", []) as Array).size() == 2, "two wolves must be proposed inside tick %d" % i)
			_expect(with_incidents._scheduler.queue.get_tick() == i,
				"submitting incident jobs outside tick() must never advance the queue's own clock")
		with_incidents.tick()
		_expect(with_incidents._scheduler.queue.get_tick() == with_incidents.get_tick(),
			"JobQueue's own clock must advance exactly once per WorldState tick regardless of incident submissions (tick %d)" % with_incidents.get_tick())
	var haul_baseline := _find_haul_job(baseline)
	var haul_incidents := _find_haul_job(with_incidents)
	_expect(not haul_baseline.is_empty() and not haul_incidents.is_empty(), "both worlds must still carry the permanently-backed-off haul job")
	if haul_baseline.is_empty() or haul_incidents.is_empty(): return
	_expect(String(haul_baseline["status"]) == "queued" and String(haul_baseline["reason"]) == "blocked_destination_full",
		"the baseline haul job must be backed off with no zone to receive it")
	_expect(int(haul_incidents["retry_at"]) == int(haul_baseline["retry_at"]) and int(haul_incidents["backoff_ticks"]) == int(haul_baseline["backoff_ticks"]),
		"an unrelated haul job's retry_at/backoff_ticks must be unaffected by incident submissions landing in the same tick")
	_expect(String(haul_incidents["status"]) == String(haul_baseline["status"]) and String(haul_incidents["reason"]) == String(haul_baseline["reason"]),
		"an unrelated haul job's status/reason must be unaffected by incident submissions")

## Every terminal transition goes through WorldState._finish_job(): a
## cancel before activation drops the staged actor; cancel/complete/fail/
## invalidate_job commands during travel or the wait despawn the actor and
## clear its stamped wait.
func _check_cleanup_on_every_terminal_transition() -> void:
	if _failed: return
	# Cancel before activation: the target is held by a colonist's till job.
	var spawn := Vector2i(0, 10)
	var target := Vector2i(1, 10)
	var pocket := _build_pocket_world(929, [spawn, target])
	pocket._tiles[pocket._tile_index(target.x, target.y)] = WorldStateType.TILE_SOIL
	pocket._colonists.append(_colonist("tiller", target.x, target.y))
	pocket.apply({"actor": "test", "command_id": "till_hold", "tick": 0, "type": "till", "payload": {"x": target.x, "y": target.y, "priority": 1}})
	pocket.tick()
	var staged_job := pocket._incidents.propose(_make_wolf(pocket, "staged_wolf", spawn.x, spawn.y), target, 40)
	pocket.tick()
	_expect(String(_find_job(pocket, staged_job).get("status", "")) == "queued", "the staged wolf's job must be queued behind the till job")
	_expect(_job_command(pocket, "cancel_staged", "cancel_job", staged_job).get("ok", false), "cancel_job on a queued incident job must be accepted")
	_expect(pocket._incidents.staged_actors().is_empty(), "cancelling a queued incident job must drop its staged actor")
	for i in 60:
		pocket.tick()
	_expect(pocket._find_colonist("staged_wolf").is_empty(), "a cancelled proposal must never spawn, even once the target frees up")

	for command_type in ["cancel_job", "fail_job", "invalidate_job", "complete_job"]:
		var world := _build_controlled_world(939)
		var wolf_target := Vector2i(30, 10)
		var job_id := world._incidents.propose(_make_wolf(world, "cmd_wolf", 0, 10), wolf_target, 40)
		_expect(_tick_until(world, _in_world("cmd_wolf")) >= 0, "%s: the wolf must spawn" % command_type)
		if command_type == "complete_job":
			# complete_job is accepted only for an active job mid-work: reach the wait first.
			_expect(_tick_until(world, func(w: WorldStateType) -> bool: return w._find_colonist("cmd_wolf").get("work") != null) >= 0,
				"complete_job: the wolf must reach its wait")
		else:
			world.tick()
			_expect(world._find_colonist("cmd_wolf").get("route") != null, "%s: the wolf must be mid-travel" % command_type)
		# Mid-travel the key holds the stamped 40; mid-wait the work toil has
		# already counted it down by one step per tick.
		var stamped = world._get_work_progress(wolf_target)
		_expect(stamped != null and int(stamped) > 0 and int(stamped) <= 40,
			"%s: the active incident job must hold its stamped wait on the target (got %s)" % [command_type, stamped])
		_expect(_job_command(world, "terminal_%s" % command_type, command_type, job_id).get("ok", false), "%s on an active incident job must be accepted" % command_type)
		_expect(world._find_colonist("cmd_wolf").is_empty(), "%s must despawn the incident actor" % command_type)
		_expect(world._get_work_progress(wolf_target) == null, "%s must clear the incident's stamped wait" % command_type)
		_expect(world.get_assignments().is_empty() and world._incidents.staged_actors().is_empty() and world._incidents._actor_by_job.is_empty(),
			"%s must leave no assignment or incident bookkeeping behind" % command_type)
		_expect(String(_find_job(world, job_id).get("status", "")) != "active", "%s must terminate the job" % command_type)
		world.tick()
		_expect(world._find_colonist("cmd_wolf").is_empty(), "%s: the actor must stay gone" % command_type)

## Unreachable travel cancels the incident and clears its stamped wait, so a
## later job at the same tile starts at its own full duration.
func _check_unreachable_travel_clears_progress_for_next_job() -> void:
	if _failed: return
	var world := _build_controlled_world(949)
	var target := Vector2i(WALL_X + 10, DOOR_Y)
	world._tiles[world._tile_index(target.x, target.y)] = WorldStateType.TILE_SOIL
	var job_id := world._incidents.propose(_make_wolf(world, "cut_wolf", 0, DOOR_Y), target, 40)
	_expect(_tick_until(world, _in_world("cut_wolf")) >= 0, "the wolf must spawn")
	_expect(int(world._get_work_progress(target)) == 40, "the active incident job must have stamped its wait on the target")
	_build_wall_column(world, WALL_X, DOOR_Y)
	_expect(_tick_until(world, _gone("cut_wolf")) >= 0, "the walled-off wolf must despawn on unreachable travel")
	_expect(String(_find_job(world, job_id).get("status", "")) == "cancelled", "the unreachable incident job must be cancelled")
	_expect(world._get_work_progress(target) == null, "the unreachable hook must clear the incident's stamped wait")
	world._colonists.append(_colonist("next_worker", target.x + 1, target.y))
	_expect(world.apply({"actor": "test", "command_id": "till_after", "tick": world.get_tick(),
		"type": "till", "payload": {"x": target.x, "y": target.y, "priority": 1}}).get("ok", false), "a till order on the freed tile must be accepted")
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return w._find_colonist("next_worker").get("work") != null) >= 0,
		"the till job must reach its work toil")
	var work: Dictionary = world._find_colonist("next_worker")["work"]
	var till_ticks := int(world._work_ticks["till"])
	_expect(int(work["ticks_remaining"]) == till_ticks - 1,
		"the later job must start from its own full duration (%d), not inherit the incident's wait (got %d)" % [till_ticks, int(work["ticks_remaining"])])

## Recovery review round 3, defect 1: two incident jobs race for one target;
## terminal commands against the queued loser, including rejected completion
## and repeated commands, must never touch the active winner's stamped wait.
func _check_cancelling_queued_competitor_preserves_active_owner_wait() -> void:
	for command_type in ["cancel_job", "fail_job", "invalidate_job", "complete_job"]:
		_check_queued_competitor_command_preserves_wait(command_type)

func _check_queued_competitor_command_preserves_wait(command_type: String) -> void:
	if _failed: return
	var spawn := Vector2i(0, 10)
	var target := Vector2i(1, 10)
	var world := _build_pocket_world(971, [spawn, target])
	var spawn_result := _spawn_incident_command(world, "competitor", "wildlife_wander")
	var actor_ids: Array = spawn_result.get("actor_ids", [])
	_expect(actor_ids.size() == 2, "both wolves must be proposed")
	if actor_ids.size() != 2: return
	world.tick()
	var winner := ""
	for actor_id in actor_ids:
		if not world._find_colonist(String(actor_id)).is_empty():
			winner = String(actor_id)
	_expect(not winner.is_empty(), "exactly one wolf must win the race for the shared target")
	if winner.is_empty(): return
	var winner_job_id := _assignment_job_id(world, winner)
	var loser_job_id := ""
	for job in world.get_jobs():
		if String(job["kind"]) == "incident" and String(job["id"]) != winner_job_id:
			loser_job_id = String(job["id"])
	_expect(not loser_job_id.is_empty(), "the loser must carry its own queued incident job")
	if loser_job_id.is_empty(): return
	var wait_before = world._get_work_progress(target)
	_expect(wait_before != null, "the winner must have stamped its wait on the shared target")
	var result := _job_command(world, "finish_loser", command_type, loser_job_id)
	_expect(bool(result.get("ok", false)) == (command_type != "complete_job"),
		"%s must accept queued termination but reject completion without activation" % command_type)
	_expect(world._get_work_progress(target) == wait_before,
		"%s against the queued competitor must preserve the active winner's wait (before %s, after %s)" % [command_type, wait_before, world._get_work_progress(target)])
	_expect(not world._find_colonist(winner).is_empty(), "the winner must remain in the world, unaffected by the loser's command")
	var repeat_result := _job_command(world, "finish_loser_again", command_type, loser_job_id)
	_expect(not repeat_result.get("ok", true), "repeating a terminal or rejected command must be rejected")
	_expect(world._get_work_progress(target) == wait_before,
		"a rejected repeated terminal command must never disturb the active winner's wait either")

## Recovery review round 3, defect 3: a door lands on a staged wolf's own
## spawn tile while its target route search is still pending; activation must
## revalidate the spawn tile under the actor's faction and retire the
## proposal (through the shared finish boundary) instead of appending it onto
## a now-forbidden tile.
func _check_door_on_spawn_tile_during_pending_route_retires_proposal() -> void:
	if _failed: return
	var world := _build_controlled_world(985)
	# A wall+gap detour (same shape as _check_initial_route_avoids_door_via_
	# alternate_route) so the bounded search takes more than one tick to find
	# the route: the door lands on the wolf's own spawn tile only after that
	# search has already begun and validated its start, not before.
	_build_single_wall(world, WALL_X, DOOR_Y, GAP_Y)
	var spawn := Vector2i(0, DOOR_Y)
	var target := Vector2i(WALL_X + 2, DOOR_Y)
	var job_id := world._incidents.propose(_make_wolf(world, "gated_wolf", spawn.x, spawn.y), target, 40)
	_expect(not job_id.is_empty(), "the wolf's job must be accepted")
	world.tick()
	_expect(String(_find_job(world, job_id).get("status", "")) == "queued",
		"the wolf's detour search must still be pending after the first tick")
	_expect(_place(world, spawn.x, spawn.y, "door").get("ok", false),
		"placing a door on the staged wolf's own spawn tile mid-search must be accepted")
	for i in TICK_BUDGET:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) not in ["queued", "active"]:
			break
		_expect(world._find_colonist("gated_wolf").is_empty(),
			"a wolf must never be appended onto a spawn tile a door has made forbidden for its faction (tick %d)" % world.get_tick())
	_expect(String(_find_job(world, job_id).get("status", "")) == "cancelled",
		"the invalidated spawn proposal must be retired through the shared finish boundary")
	_expect(world._incidents.staged_actors().is_empty(), "a retired spawn-tile proposal must leave nothing staged")
	_expect(world._find_colonist("gated_wolf").is_empty(), "the gated wolf must never enter the world")

## Recovery review round 3, defect 4: a door lands on an incident's own
## destination tile while its actor is travelling. The resource-target
## adjacency exception (_routable_to()) must never let stopping next to that
## tile count as having reached it; the job must instead prove the tile
## unreachable and cancel through the shared finish boundary.
func _check_door_on_destination_during_travel_is_never_reached() -> void:
	if _failed: return
	var world := _build_controlled_world(991)
	var target := Vector2i(30, 10)
	var job_id := world._incidents.propose(_make_wolf(world, "dest_wolf", 0, 10), target, 40)
	_expect(_tick_until(world, _in_world("dest_wolf")) >= 0, "the wolf must spawn on the open map")
	_expect(_place(world, target.x, target.y, "door").get("ok", false),
		"placing a door on the incident's own destination must be accepted")
	for i in TICK_BUDGET:
		world.tick()
		if world._find_colonist("dest_wolf").is_empty():
			break
		_expect(_actor_pos(world, "dest_wolf") != target,
			"the wolf must never be recorded as standing on a destination a door has made impassable (tick %d)" % world.get_tick())
	_expect(world._find_colonist("dest_wolf").is_empty(), "the wolf must despawn once its gated destination proves unreachable")
	_expect(String(_find_job(world, job_id).get("status", "")) == "cancelled",
		"an incident whose destination is blocked by a door must cancel, never complete its wait adjacent to it")
	_expect(world._get_work_progress(target) == null, "the cancelled incident must clear its stamped wait")

## Recovery review round 3, minor finding: terminating an incident actor while
## its bounded reroute search is still active (route.rerouting.status ==
## "searching") must release that search from WorldState._reroutes, exactly
## like an ordinary colonist's later _advance_colonists() pass would -- a
## despawned actor never gets that later pass.
func _check_terminate_during_active_reroute_releases_search() -> void:
	if _failed: return
	var world := _build_controlled_world(997)
	var target := Vector2i(WALL_X + 10, DOOR_Y)
	var job_id := world._incidents.propose(_make_wolf(world, "reroute_wolf", 0, DOOR_Y), target, 40)
	_expect(_tick_until(world, _in_world("reroute_wolf")) >= 0, "the wolf must spawn")
	world.tick()
	_build_wall_column(world, WALL_X, DOOR_Y)
	var searching := _tick_until(world, func(w: WorldStateType) -> bool:
		var actor := w._find_colonist("reroute_wolf")
		if actor.is_empty(): return false
		var route = actor.get("route")
		return route != null and route.get("rerouting") != null and String(route["rerouting"]["status"]) == "searching")
	_expect(searching >= 0, "the wolf must begin an in-flight bounded reroute search after the wall lands")
	if searching < 0: return
	_expect(world._reroutes.has("reroute_wolf"), "the live reroute search must be tracked while it is active")
	_expect(_job_command(world, "cancel_during_reroute", "cancel_job", job_id).get("ok", false),
		"cancel_job on a rerouting incident job must be accepted")
	_expect(not world._reroutes.has("reroute_wolf"), "terminating an actor mid-reroute must release its search entry")
	_expect(world._find_colonist("reroute_wolf").is_empty(), "the cancelled actor must be gone")

## Recovery review round 3, defect 2: both startup autosave restoration and a
## manual Load construct their world through StateCodec.decode(), which
## always builds with incidents disabled -- boot.gd must re-enable incidents
## on the restored world either way, and a freshly spawned actor's id must
## never collide with one already alive in the restored roster.
func _check_incidents_enabled_after_startup_restore_and_manual_load() -> void:
	if _failed: return
	_cleanup_dir(BOOT_RESTORE_DIR)
	var seed_world := _build_controlled_world(1013)
	var spawn_result := _spawn_incident_command(seed_world, "restore_seed", "wildlife_wander")
	var seed_actor_ids: Array = spawn_result.get("actor_ids", [])
	_expect(seed_actor_ids.size() == 2, "seeding the restore-test save must propose 2 wolves")
	if seed_actor_ids.size() != 2:
		_cleanup_dir(BOOT_RESTORE_DIR)
		return
	_expect(_tick_until(seed_world, _in_world(String(seed_actor_ids[0]))) >= 0, "the seed wolf must spawn before saving")
	var restore_manager := SaveManagerType.new(BOOT_RESTORE_DIR)
	_expect(restore_manager.save_manual(seed_world).get("ok", false), "seeding the restore-test save must succeed")

	var boot_scene: PackedScene = load(BOOT_SCENE_PATH)
	for restore_mode in ["startup", "manual_load"]:
		var boot_node: Node = boot_scene.instantiate()
		root.add_child(boot_node)
		# _ready() (which would normally wire these) never runs in this
		# headless harness (see _check_viewer_dispatches_spawn_incident's own
		# doc comment); wire just enough of it by hand -- pointed at the real
		# restore_manager, not a fresh default one -- so _restore_from_save()/
		# _on_load_pressed()'s _replace_world() call has a tick_driver and
		# autosave_trigger to repoint.
		boot_node.tick_driver = TickDriverType.new(boot_node.world)
		boot_node.add_child(boot_node.tick_driver)
		boot_node.save_manager = restore_manager
		boot_node.autosave_trigger = AutosaveTriggerType.new(boot_node.world, restore_manager)
		boot_node.add_child(boot_node.autosave_trigger)
		if restore_mode == "startup":
			boot_node._restore_from_save()
		else:
			boot_node._on_load_pressed()
		var restored_world: WorldStateType = boot_node.get("world")
		_expect(restored_world != null, "%s: the boot node must expose a restored world" % restore_mode)
		if restored_world != null:
			_expect(restored_world._incidents.is_enabled(), "%s: incidents must be re-enabled on a restored world" % restore_mode)
			var restored_roster_ids: Array = []
			for colonist in restored_world.get_colonists():
				restored_roster_ids.append(String(colonist["id"]))
			var buttons: Array = boot_node._make_incident_buttons()
			_expect(buttons.size() == 5, "%s: the restored viewer must offer one spawn button per content incident" % restore_mode)
			for button in buttons:
				var incident_button: Button = button
				if String(incident_button.text).contains("wildlife_wander"):
					var before := _incident_started_events(restored_world, "wildlife_wander").size()
					incident_button.pressed.emit()
					var events := _incident_started_events(restored_world, "wildlife_wander")
					_expect(events.size() == before + 1, "%s: pressing the restored Spawn button must dispatch a real spawn" % restore_mode)
					if events.size() > before:
						var new_actor_ids: Array = events[events.size() - 1]["data"]["actor_ids"]
						for new_id in new_actor_ids:
							_expect(not restored_roster_ids.has(new_id),
								"%s: a freshly spawned incident actor id must never collide with a restored one (got %s, roster %s)" % [restore_mode, new_id, restored_roster_ids])
				incident_button.free()
		root.remove_child(boot_node)
		boot_node.free()
	_cleanup_dir(BOOT_RESTORE_DIR)

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))

## Component fields a kind must round-trip, and the colonist-only ones it must not carry.
const KIND_FIELDS := {
	"wolf": {"present": ["needs", "combat", "wild", "health"], "absent": ["labourTable", "held_tool", "carrying", "inventory", "visitor"]},
	"trader": {"present": ["inventory", "visitor", "health"], "absent": ["labourTable", "held_tool", "carrying", "needs", "combat", "wild"]},
}

func _assert_actor_shape(actor: Dictionary, label: String) -> void:
	var kind := String(actor.get("kind", ""))
	_expect(KIND_FIELDS.has(kind), "%s: unexpected actor kind %s" % [label, kind])
	if not KIND_FIELDS.has(kind): return
	for field in KIND_FIELDS[kind]["present"]:
		_expect(actor.has(field), "%s: a %s must carry its declared '%s' component" % [label, kind, field])
	for field in KIND_FIELDS[kind]["absent"]:
		_expect(not actor.has(field), "%s: a %s must not carry the undeclared '%s' field" % [label, kind, field])

## The real SaveIO path (write_atomic()/read()), not StateCodec directly.
func _save_and_reload(world: WorldStateType, label: String) -> WorldStateType:
	_remove_save_file()
	var write_result := SaveIOType.write_atomic(SAVE_PATH, world.to_save_state())
	_expect(write_result.get("ok", false), "%s: the save must pass SaveIO's real validator: %s" % [label, write_result.get("message", "")])
	var read_result := SaveIOType.read(SAVE_PATH)
	_expect(read_result.get("ok", false), "%s: reading the save back must pass SaveIO's real validator: %s" % [label, read_result.get("message", "")])
	_remove_save_file()
	if not write_result.get("ok", false) or not read_result.get("ok", false):
		return null
	return WorldStateType.from_save_state(read_result["state"])

func _assert_round_trip(before: Dictionary, after: Dictionary, label: String) -> void:
	_expect(not after.is_empty(), "%s: the actor must survive the round trip" % label)
	if after.is_empty(): return
	var before_keys := before.keys(); before_keys.sort()
	var after_keys := after.keys(); after_keys.sort()
	_expect(before_keys == after_keys, "%s: the actor's field set must round-trip exactly (%s vs %s)" % [label, before_keys, after_keys])
	for key in before_keys:
		if key in ["route", "work"]:
			continue
		_expect(after.get(key) == before[key], "%s: field '%s' must round-trip identically (%s vs %s)" % [label, key, before[key], after.get(key)])
	_expect((after.get("route") == null) == (before.get("route") == null) and (after.get("work") == null) == (before.get("work") == null),
		"%s: route/work presence must round-trip" % label)
	_assert_actor_shape(after, label)

func _check_save_load_mid_incident() -> void:
	if _failed: return
	for incident_id in ["wildlife_wander", "trader_visit"]:
		var world := _build_controlled_world(505)
		var spawn_result := _spawn_incident_command(world, "save_%s" % incident_id, incident_id)
		var actor_ids: Array = spawn_result.get("actor_ids", [])
		_expect(not actor_ids.is_empty(), "%s must propose an actor for the save/load check" % incident_id)
		if actor_ids.is_empty(): return
		var actor_id := String(actor_ids[0])
		_expect(_tick_until(world, _in_world(actor_id)) >= 0, "%s's actor must spawn" % incident_id)
		# During travel: the route is in flight.
		_expect(_tick_until(world, func(w: WorldStateType) -> bool: return w._find_colonist(actor_id).get("route") != null) >= 0,
			"%s's actor must begin travelling before the mid-travel save" % incident_id)
		var travelling := world._find_colonist(actor_id).duplicate(true)
		var job_id := _assignment_job_id(world, actor_id)
		_assert_actor_shape(travelling, "%s live (travel)" % incident_id)
		var restored := _save_and_reload(world, "%s mid-travel" % incident_id)
		if restored == null: return
		_assert_round_trip(travelling, restored._find_colonist(actor_id), "%s mid-travel" % incident_id)
		_expect(not restored.get_assignments().get(actor_id, {}).is_empty(), "%s: the active incident assignment must be restored" % incident_id)
		# The restored actor still despawns when its job finishes (adopted on load).
		_expect(_tick_until(restored, _gone(actor_id)) >= 0, "%s: the restored actor must still despawn after load" % incident_id)
		_expect(restored._colonists.is_empty(), "%s: the restored world must hold no leftover actor after despawn" % incident_id)
		# During the wait: the work toil is counting down.
		_expect(_tick_until(world, func(w: WorldStateType) -> bool: return w._find_colonist(actor_id).get("work") != null) >= 0,
			"%s's actor must reach its wait before the mid-wait save" % incident_id)
		var waiting := world._find_colonist(actor_id).duplicate(true)
		var restored_wait := _save_and_reload(world, "%s mid-wait" % incident_id)
		if restored_wait == null: return
		var after_wait := restored_wait._find_colonist(actor_id)
		_assert_round_trip(waiting, after_wait, "%s mid-wait" % incident_id)
		_expect(after_wait.get("work") != null and int(after_wait["work"]["ticks_remaining"]) == int(waiting["work"]["ticks_remaining"]),
			"%s: the wait's remaining ticks must round-trip" % incident_id)
		# After despawn: nothing incident-specific may remain in the world.
		_expect(_tick_until(world, _gone(actor_id)) >= 0, "%s's actor must despawn" % incident_id)
		var restored_after := _save_and_reload(world, "%s post-despawn" % incident_id)
		if restored_after == null: return
		_expect(restored_after._find_colonist(actor_id).is_empty(), "%s: a despawned actor must not reappear after save/load" % incident_id)
		# (The world keeps ticking past day 3 here, so the natural daily draw
		# may legitimately have proposed other actors: assert on this one's own.)
		_expect(restored_after.get_assignments().get(actor_id, {}).is_empty(), "%s: a post-despawn load must carry no assignment for the despawned actor" % incident_id)
		_expect(restored_after._incidents.staged_actor(actor_id).is_empty(), "%s: a post-despawn load must carry no staged proposal for the despawned actor" % incident_id)
		var own_job := _find_job(restored_after, job_id)
		_expect(String(own_job.get("status", "")) == "completed", "%s: the despawned actor's own job record must be terminal (completed), got %s" % [incident_id, own_job])
		for i in 10:
			restored_after.tick()
		restored_after.state_hash()

## The viewer's own spawn_incident dispatch (boot.gd's debug buttons call
## spawn_incident(id) -> WorldState.apply()) on the live scenario build,
## which is the one caller that enables incidents.
func _check_viewer_dispatches_spawn_incident() -> void:
	if _failed: return
	var boot_scene: PackedScene = load(BOOT_SCENE_PATH)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	var world = boot_node.get("world")
	_expect(world != null, "the boot scene must expose a world")
	if world != null:
		# The control bar itself is built in _ready(), which a headless test
		# never runs: build the same buttons and press them.
		var buttons: Array = boot_node._make_incident_buttons()
		_expect(buttons.size() == 5, "the viewer must offer one spawn button per content incident (got %d)" % buttons.size())
		var seen: Array[String] = []
		for i in buttons.size():
			var button: Button = buttons[i]
			var incident_id := ""
			for candidate in ["wildlife_wander", "trader_visit", "migrant_joins", "raider_incursion", "wolf_attack"]:
				if String(button.text).contains(candidate):
					incident_id = candidate
			_expect(not incident_id.is_empty() and not seen.has(incident_id), "spawn button %d must name a distinct seed incident (got '%s')" % [i, button.text])
			seen.append(incident_id)
			var before := _incident_started_events(world, incident_id).size()
			button.pressed.emit()
			var events := _incident_started_events(world, incident_id)
			_expect(events.size() == before + 1, "pressing the %s button must dispatch spawn_incident through the live world" % incident_id)
			if events.size() > before:
				var actor_ids: Array = events[events.size() - 1]["data"]["actor_ids"]
				_expect(not actor_ids.is_empty(), "the viewer-triggered %s must propose actors" % incident_id)
				if not actor_ids.is_empty():
					_expect(_tick_until(world, _in_world(String(actor_ids[0])), BOOT_TICK_BUDGET) >= 0,
						"the viewer-triggered %s actor must enter the live world" % incident_id)
			button.free()
		var direct: Dictionary = boot_node.spawn_incident("not_a_real_incident")
		_expect(not direct.get("ok", true), "the viewer's spawn_incident must surface the world's rejection for an unknown id")
	root.remove_child(boot_node)
	boot_node.free()

## Round 5 review finding 1: _start_new_game() built its fresh WorldState with
## the bare constructor's own incidents_enabled=false default, unlike every
## other world-building path (_init()'s live build, _restore_from_save(),
## _on_load_pressed()) which all explicitly re-enable it -- a brand-new colony
## rejected spawn_incident commands and drew no daily incidents until the
## player happened to Save and Load it once. Proves incident commands work
## immediately after New Game, and still work after a Save/Load round trip of
## that same new game.
func _check_incidents_enabled_after_new_game_and_survive_save_load() -> void:
	if _failed: return
	_cleanup_dir(NEW_GAME_SAVE_DIR)
	var boot_scene: PackedScene = load(BOOT_SCENE_PATH)
	var boot_node: Node = boot_scene.instantiate()
	root.add_child(boot_node)
	var new_game_manager := SaveManagerType.new(NEW_GAME_SAVE_DIR)
	# _ready() never runs in this headless harness (see
	# _check_incidents_enabled_after_startup_restore_and_manual_load()'s own
	# doc comment); wire just enough of it by hand so _start_new_game()'s
	# _replace_world() call has a tick_driver/autosave_trigger to repoint.
	boot_node.tick_driver = TickDriverType.new(boot_node.world)
	boot_node.add_child(boot_node.tick_driver)
	boot_node.save_manager = new_game_manager
	boot_node.autosave_trigger = AutosaveTriggerType.new(boot_node.world, new_game_manager)
	boot_node.add_child(boot_node.autosave_trigger)

	boot_node._start_new_game(1023)
	var world: WorldStateType = boot_node.get("world")
	_expect(world != null, "New Game must produce a world")
	if world != null:
		_expect(world._incidents.is_enabled(), "incidents must be enabled immediately after New Game")
		var before := _spawn_incident_command(world, "new_game_spawn_before", "wildlife_wander")
		_expect(before.get("ok", false), "spawn_incident must be accepted on a brand-new colony straight out of New Game (got %s)" % before)

	if world != null:
		_expect(new_game_manager.save_manual(world).get("ok", false), "saving the new game must succeed")
	boot_node._on_load_pressed()
	var reloaded: WorldStateType = boot_node.get("world")
	_expect(reloaded != null, "Load after New Game must produce a world")
	if reloaded != null:
		_expect(reloaded._incidents.is_enabled(), "incidents must still be enabled after Save/Load of a brand-new game")
		var after := _spawn_incident_command(reloaded, "new_game_spawn_after", "trader_visit")
		_expect(after.get("ok", false), "spawn_incident must still be accepted after a Save/Load round trip of a new game (got %s)" % after)

	root.remove_child(boot_node)
	boot_node.free()
	_cleanup_dir(NEW_GAME_SAVE_DIR)

## A rock-filled arena with a single-file floor corridor from LINGER_SPAWN
## (raider_incursion's own north-edge spawn tile) down through
## LINGER_NEAR_DOOR_TILE, with a colony door at LINGER_DOOR_TILE -- "raiders"
## may not pass a colony door (content/factions.json), and the door itself
## carries a health entry, so it is the actor's only reachable hostile
## target once ApproachGiver takes over. Mirrors _build_wolf_attack_world()
## from the reference fix (commit 164a29de).
func _build_lingering_arena(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	for y in range(LINGER_SPAWN.y, LINGER_DOOR_TILE.y + 1):
		world._tiles[world._tile_index(LINGER_SPAWN.x, y)] = WorldStateType.TILE_FLOOR
	world._set_object(LINGER_DOOR_TILE.x, LINGER_DOOR_TILE.y, "door")
	return world

## Ticks to one tick before raider_incursion's own min_day boundary, seals
## LINGER_NEAR_DOOR_TILE for exactly the one tick that runs the daily draw
## (IncidentScheduler's own random-target pick is a per-tile passability/
## bareness pre-filter, never a faction-aware route search, so a bare
## near-door tile would sometimes be handed to the actor as its own incident
## target), then unseals it immediately after. Returns the proposed actor
## ids ([] if the draw did not fire exactly once).
func _draw_lingering_incident(world: WorldStateType) -> Array:
	var draw_tick := (LINGER_MIN_DAY - 1) * DAY_LENGTH_TICKS
	_tick_to(world, draw_tick - 1)
	world._set_object(LINGER_NEAR_DOOR_TILE.x, LINGER_NEAR_DOOR_TILE.y, "bed")
	world.tick()
	world._set_object(LINGER_NEAR_DOOR_TILE.x, LINGER_NEAR_DOOR_TILE.y, "")
	var events := _incident_started_events(world, LINGER_INCIDENT_ID)
	if events.size() != 1:
		return []
	return events[0]["data"]["actor_ids"]

func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))

## get_colonists() filters to worker-component actors only (ADR 012), which a
## wolf never has -- get_actors_with_health() is the generic "still a real
## actor in the world" accessor a non-worker incident actor shows up in.
func _has_actor_with_health_id(world: WorldStateType, actor_id: String) -> bool:
	for actor in world.get_actors_with_health():
		if String(actor["id"]) == actor_id:
			return true
	return false

## Issue #398 (ADR 032): proves spawn.lingers end to end, through the real
## generic systems alone -- no lingering-specific or wolf-specific code
## anywhere else. raider_incursion fires on its own min_day through the
## ordinary daily budgeted draw (not force_spawn/spawn_incident, which
## bypass min_day and would not prove the gating); the actor's arrival job
## (walk to its incident-picked, deliberately non-adjacent target, then
## wait) runs to completion; the actor survives that completion instead of
## despawning (the lingering proof); with no destination ever supplied by
## this test, ApproachGiver alone then walks it to a tile adjacent to the
## colony door and CombatResolver starts the fight.
func _check_lingering_actor_survives_arrival_and_hands_off_to_approach() -> void:
	if _failed: return
	var world := _build_lingering_arena(1098)
	var actor_ids := _draw_lingering_incident(world)
	_expect(actor_ids.size() == 1, "raider_incursion must draw exactly once, proposing its content-declared count of 1, on its own min_day (%d) through the ordinary daily budgeted draw" % LINGER_MIN_DAY)
	if actor_ids.is_empty(): return
	var actor_id := String(actor_ids[0])

	_expect(_tick_until(world, _in_world(actor_id), LINGER_ARRIVAL_BUDGET) >= 0, "the lingering actor must spawn once its own incident job activates")
	var spawned := world._find_colonist(actor_id)
	_expect(String(spawned.get("kind", "")) == "wolf" and String(spawned.get("factionId", "")) == "raiders",
		"raider_incursion must spawn a wolf carrying the raiders faction, got %s" % spawned)

	var incident_job_id := _assignment_job_id(world, actor_id)
	var incident_target: Vector2i = _find_job(world, incident_job_id).get("target", NO_TILE)
	_expect(incident_target != NO_TILE, "the lingering actor's own incident job must carry a target")
	_expect(_chebyshev(incident_target, LINGER_DOOR_TILE) > 1,
		"the incident's own picked target (%s) must NOT be adjacent to the door (%s) -- the near-door seal must have worked" % [incident_target, LINGER_DOOR_TILE])

	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return String(_find_job(w, incident_job_id).get("status", "")) == "completed", LINGER_ARRIVAL_BUDGET) >= 0,
		"the lingering actor's own arrival job (walk then wait) must run to completion")
	_expect(not world._find_colonist(actor_id).is_empty(), "a lingering actor must survive its own arrival job's completion instead of despawning")
	_expect(_has_actor_with_health_id(world, actor_id), "a lingering actor must still appear in get_actors_with_health() after its arrival job completes")

	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return _chebyshev(_actor_pos(w, actor_id), LINGER_DOOR_TILE) == 1, LINGER_ARRIVAL_BUDGET) >= 0,
		"the lingering actor must be driven, with no destination supplied by this test, to a tile adjacent to the closed door -- the generic ApproachGiver hand-off")

	var found_attack := false
	var observed_fighting := false
	for i in LINGER_ATTACK_OBSERVE_TICKS:
		world.tick()
		if world.get_actor_combat_reason(actor_id) == "fighting":
			observed_fighting = true
		for event in world.get_events():
			if String(event.get("type", "")) == "attacked_by" and String(event.get("data", {}).get("attacker_id", "")) == actor_id:
				found_attack = true
	_expect(found_attack, "an 'attacked_by' event naming the lingering actor as attacker must appear in world.get_events()")
	_expect(observed_fighting, "world.get_actor_combat_reason(actor_id) must report 'fighting' while the lingering actor attacks the door")
	_expect(not world._find_colonist(actor_id).is_empty(), "the lingering actor must still be present in the world after the hand-off completes")

	var orphans := ReservationInvariantsType.find_orphaned_reservations(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect(orphans.is_empty(), "no reservation may outlive its job after the lingering hand-off (orphans=%s)" % [orphans])

## Two fresh runs of the same seed through the identical scripted sequence
## (draw, arrival, lingering, ApproachGiver hand-off, combat) must hash
## identically at every sampled tick spanning arrival to combat.
func _check_lingering_incident_same_seed_reproduces_hash() -> void:
	if _failed: return
	var world_a := _build_lingering_arena(1098)
	var world_b := _build_lingering_arena(1098)
	var ids_a := _draw_lingering_incident(world_a)
	var ids_b := _draw_lingering_incident(world_b)
	_expect(ids_a == ids_b and ids_a.size() == 1, "the same seed must reproduce the identical proposed raider_incursion actor id")
	if ids_a.size() != 1 or ids_b.size() != 1: return
	_expect(world_a.state_hash() == world_b.state_hash(), "the same seed must reproduce the same state hash immediately after the draw")
	var actor_id := String(ids_a[0])

	var sample_points: Array[Callable] = [
		_in_world(actor_id),
		func(w: WorldStateType) -> bool: return _chebyshev(_actor_pos(w, actor_id), LINGER_DOOR_TILE) == 1,
	]
	for predicate in sample_points:
		var reached_a := _tick_until(world_a, predicate, LINGER_ARRIVAL_BUDGET)
		var reached_b := _tick_until(world_b, predicate, LINGER_ARRIVAL_BUDGET)
		_expect(reached_a >= 0 and reached_a == reached_b, "the same seed must reach each sampled milestone in the identical number of ticks (got %d vs %d)" % [reached_a, reached_b])
		_expect(world_a.state_hash() == world_b.state_hash(), "the same seed must reproduce the same state hash at each sampled milestone")

	for i in LINGER_ATTACK_OBSERVE_TICKS:
		world_a.tick()
		world_b.tick()
		_expect(world_a.state_hash() == world_b.state_hash(),
			"two runs of the same seed must produce identical state_hash() through the arrival-to-combat sequence (tick %d)" % world_a.get_tick())

func _remove_save_file() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
