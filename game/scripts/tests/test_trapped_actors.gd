extends SceneTree

## Trap-on-trench-entry and hostile climb-out (ADR 026).
## Exercises WorldState._check_trench_arrival() through real gameplay --
## submitting jobs and ticking -- never by calling private trap methods
## directly, so the whole route-step -> trap -> release -> (hostile)
## auto-submit -> climb-out pipeline is proven end to end.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")

const TRAP_TICK_BOUND := 100
const NEEDS_DECAY_TICKS := 400
const SAVE_IO_TARGET := "user://test-trapped-actors-save-io.json"

var _failed := false

func _init() -> void:
	_check_colonist_falls_into_trench_releases_job()
	_check_trapped_colonist_refuses_new_job()
	_check_trapped_colonist_needs_keep_decaying()
	_check_colonist_stays_trapped_indefinitely()
	_check_hostile_actor_auto_escapes()
	_check_route_choice_unaffected_by_trench()
	_check_save_load_round_trip_preserves_trapped_state()
	_check_hostile_escapes_despite_ground_item_on_trench()
	_check_hostile_escapes_despite_tool_item_on_trench()
	_check_hostile_escapes_despite_object_on_trench()
	_check_hostile_escapes_despite_stockpile_cell_on_trench()
	_check_incident_wait_job_traps_before_despawn()
	_check_hostile_exit_prefers_entry_tile_from_south()
	_check_hostile_exit_falls_back_when_entry_tile_blocked()
	_check_hostile_exit_never_uses_forbidden_door()
	_check_hostile_stays_trapped_and_retries_when_no_exit_available()
	_check_hostile_ticks_remaining_syncs_with_real_work_progress()
	_check_two_hostiles_trapped_on_same_tile_each_get_correct_duration()
	_check_save_io_round_trip_preserves_trapped_hostile()
	_check_save_io_rejects_malformed_from_tile()
	_check_save_load_immediately_after_trapping_preserves_escape_duration()
	_check_save_load_two_queued_escapes_sharing_tile_preserves_duration()
	_check_save_load_after_blocked_exit_retry_preserves_duration()
	_check_trapping_during_need_journey_resolves_need_giver()
	_check_trapping_on_work_target_arrival_clears_progress()
	_check_trapping_mid_haul_releases_item_and_cell_reservations()
	_check_stale_dig_target_dug_by_other_worker_does_not_falsely_trap()
	_check_trapped_colonist_removed_on_death()
	_check_trapped_hostile_removed_on_death_during_escape()
	_check_trader_crosses_trench_unaffected()
	_check_trapped_colonist_cannot_flee_via_combat_giver()
	_check_colonist_trapped_during_active_flee_episode()
	_check_save_load_preserves_trapped_state_during_flee_episode()
	if _failed:
		quit(1)
		return
	print("test_trapped_actors: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A single-colonist world with every tile floored (mirrors
## test_architecture_rules.gd's own _build_world()), but with a complete,
## never-missing needs/needsAccumulator/labourTable/health shape (unlike that
## helper's minimal one): WorldState._ensure_needs() rebuilds a colonist
## dict -- a NEW Dictionary object, _colonists[i] reassigned -- the first
## tick any of those is missing, which would silently orphan a "trapped"
## field reference this file holds across many world.tick() calls. No
## "trapped" key at all yet, proving _check_trench_arrival() reads it
## defensively via .get().
func _fresh_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
		"route": null, "work": null, "hands": [], "held_tool": "",
		"health": {"hp": 100, "maxHp": 100, "dead": false}})
	return world

## Appends a live, world-present (never staged) hostile actor directly, the
## Non-goals-mandated "construct a test actor" route test_faction_reservations.gd
## already establishes for a non-colony actor, rather than a live incident draw.
func _spawn_wolf(world: WorldStateType, id: String, x: int, y: int) -> Dictionary:
	var wolf: Dictionary = ActorTableType.spawn("wolf", x, y, world._content, id)
	wolf["factionId"] = "wildlife"
	world._colonists.append(wolf)
	return wolf

## A trader (content/actors.json's "trader" kind -- no worker
## component, and its own "traders" faction is neutral toward "colony", never
## hostile) is the Non-goals-named non-hostile, non-colonist actor trap-on-
## entry/hostile climb-out must never extend to. Mirrors _spawn_wolf() above.
func _spawn_trader(world: WorldStateType, id: String, x: int, y: int) -> Dictionary:
	var trader: Dictionary = ActorTableType.spawn("trader", x, y, world._content, id)
	trader["factionId"] = "traders"
	world._colonists.append(trader)
	return trader

## A "colonist"-def actor under the "raiders" faction (content/factions.json:
## mutually "hostile" with "colony", test_combat.gd's own _spawn_actor()
## precedent) -- the actual hostile-to-the-colonist threat CombatGiver's own
## flee decision needs. A "wolf" ("wildlife") will not do: colony's own
## relations row rates wildlife merely "neutral" (only wildlife's row rates
## colony hostile, the asymmetric direction _trap_actor()'s own escape check
## reads), so a colonist never flees one.
func _spawn_raider(world: WorldStateType, id: String, x: int, y: int) -> Dictionary:
	var raider: Dictionary = ActorTableType.spawn("colonist", x, y, world._content, id)
	raider.erase("carrying")
	raider["hands"] = []
	raider["factionId"] = "raiders"
	world._append_colonist(raider)
	return raider

func _tick_until_trapped(world: WorldStateType, colonist: Dictionary, bound: int) -> bool:
	for _i in bound:
		world.tick()
		if colonist.get("trapped") != null:
			return true
	return false

## Requirement: "any actor whose route step lands it on a trench tile becomes
## trapped: its current job is released like a cancel (every reservation
## freed)". A straight one-row corridor: the till job's only route crosses
## the trench tile at (1,0) on the way to its (2,0) soil target.
func _check_colonist_falls_into_trench_releases_job() -> void:
	var world := _fresh_world(301001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	var submit := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", colonist_id)
	_expect(submit.get("ok", false), "till submission must be accepted")
	var job_id: String = String(submit["job_id"])
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND),
		"the colonist must become trapped after stepping onto the trench tile")
	_expect(colonist.get("trapped", {}).get("tile") == Vector2i(1, 0),
		"trapped.tile must be the trench tile the colonist stepped onto")
	_expect(not (colonist["trapped"] as Dictionary).has("ticksRemaining"),
		"a trapped colonist must carry no ticksRemaining (only a hostile actor's exit is timed)")
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "cancelled",
		"the till job must be released exactly like cancel_job once the colonist is trapped, got status '%s'" % job.get("status"))
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(),
		"trapping must free every ReservationTable key the released job held, leaving no orphans")

## Requirement: "it cannot start a new job while trapped" -- a second order,
## submitted directly through GlobalAssignment.submit() (the
## test_faction_reservations.gd precedent for isolating the scheduler's own
## gate from the command layer), must be refused not_ordered_by_player at
## _colonist_may_be_ordered(), the same typed refusal an ineligible faction
## already gets.
func _check_trapped_colonist_refuses_new_job() -> void:
	var world := _fresh_world(302001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(3, 0)] = WorldStateType.TILE_SOIL
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	_expect(world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", colonist_id).get("ok", false),
		"first till submission must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: the colonist must be trapped before this check runs")
	var submit := world._scheduler.submit(Vector2i(3, 0), 1, world.get_tick(), "till", colonist_id)
	_expect(submit.get("ok", false), "a second submission is still accepted by the queue -- refused later, at the scheduler's own gate")
	var job_id: String = String(submit["job_id"])
	var job: Dictionary = {}
	for _i in TRAP_TICK_BOUND:
		world.tick()
		job = world._scheduler.queue.get_job(job_id)
		if String(job.get("status", "")) == "failed":
			break
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "not_ordered_by_player",
		"a trapped actor must never start a new job -- refused not_ordered_by_player, got status '%s' reason '%s'" % [job.get("status"), job.get("reason")])

## Requirement: "its needs keep decaying" through the existing, untouched
## needs-decay tick.
func _check_trapped_colonist_needs_keep_decaying() -> void:
	var world := _fresh_world(303001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	_expect(world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", colonist_id).get("ok", false),
		"till submission must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: the colonist must be trapped before this check runs")
	var food_before := int(colonist["needs"]["food"])
	for _i in NEEDS_DECAY_TICKS:
		world.tick()
	_expect(int(colonist["needs"]["food"]) < food_before,
		"a trapped colonist's needs must keep decaying through the ordinary needs-decay tick")

## A colonist that becomes trapped stays trapped, with no auto-exit and no
## auto-submitted job.
func _check_colonist_stays_trapped_indefinitely() -> void:
	var world := _fresh_world(304001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	_expect(world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", colonist_id).get("ok", false),
		"till submission must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: the colonist must be trapped before this check runs")
	for _i in 200:
		world.tick()
	_expect(colonist.get("trapped") != null, "a trapped colonist must stay trapped -- no auto-exit without rescue")
	for job in world.get_jobs():
		_expect(String(job.get("kind", "")) != "escape_trench", "a colonist must never get an auto-submitted escape_trench job")

## Requirement: "a hostile actor (Relations.is_hostile true) auto-submits an
## escape_trench job on becoming trapped, waits content/actors.json's
## wild.trench_climb_ticks (default 40), then moves to the tile it fell from
## (or another adjacent passable tile) and is no longer trapped." The
## wolf's own job is submitted directly through GlobalAssignment
## .submit_autonomous() (mirrors IncidentScheduler._spawn_one()'s own real
## submission path) so this check isolates the trap/escape mechanic from
## IncidentScheduler's day-gated draw.
func _check_hostile_actor_auto_escapes() -> void:
	var world := _fresh_world(305001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf", 0, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf")
	_expect(submit.get("ok", false), "direct autonomous submission for the trap scenario must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	var trapped_state: Dictionary = wolf["trapped"]
	_expect(trapped_state.get("tile") == Vector2i(1, 0), "the wolf must be trapped at the tile it fell into")
	_expect(int(trapped_state.get("ticksRemaining", -1)) == WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS,
		"a hostile actor's trapped.ticksRemaining must read content/actors.json's tunables.wild.trench_climb_ticks (default %d)" % WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS)
	var escape_job_found := false
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "escape_trench" and job["target"] == Vector2i(1, 0):
			escape_job_found = true
	_expect(escape_job_found, "a hostile actor must auto-submit an escape_trench job the instant it becomes trapped")
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "the hostile actor must no longer be trapped once its escape_trench job completes")
	_expect(not world._find_colonist("trap_wolf").is_empty(), "the escaped actor must still exist in the world, not despawned")
	var final_tile := Vector2i(int(wolf["x"]), int(wolf["y"]))
	_expect(bool(world.passability(final_tile.x, final_tile.y)["passable"]) and world.get_tile(final_tile.x, final_tile.y) != WorldStateType.TILE_TRENCH,
		"the escaped actor must land on an adjacent passable, non-trench tile")
	_expect(maxi(absi(final_tile.x - 1), absi(final_tile.y - 0)) == 1,
		"the escaped actor must land adjacent to the trench tile it climbed out of")

## Requirement: "a case with an equal-cost trench-free alternative follows the
## existing route_search.gd:220 ascending row-major tie-break, unmodified,
## and is documented as such rather than avoiding the trench." A diamond
## detour around a blocked center tile gives two equal-cost (4-tile) routes,
## one through the tile under test, one through plain floor; passability()
## makes trench and floor cost identically, so the scheduler's resolved path
## must be byte-identical between the two otherwise-identical worlds --
## proof no trench-avoidance term was added to routing.
func _diamond_world(seed_value: int, detour_kind: String) -> WorldStateType:
	var world := _fresh_world(seed_value)
	world._colonists[0]["x"] = 0
	world._colonists[0]["y"] = 1
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(1, 0)] = detour_kind
	world._tiles[world._tile_index(1, 2)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(2, 1)] = WorldStateType.TILE_SOIL
	return world

func _check_route_choice_unaffected_by_trench() -> void:
	var trench_world := _diamond_world(306001, WorldStateType.TILE_TRENCH)
	var floor_world := _diamond_world(306001, WorldStateType.TILE_FLOOR)
	var colonist_id: String = trench_world._colonists[0]["id"]
	var trench_submit := trench_world._scheduler.submit(Vector2i(2, 1), 1, trench_world.get_tick(), "till", colonist_id)
	var floor_submit := floor_world._scheduler.submit(Vector2i(2, 1), 1, floor_world.get_tick(), "till", colonist_id)
	_expect(trench_submit.get("ok", false) and floor_submit.get("ok", false), "both diamond-detour submissions must be accepted")
	var trench_path: Array = []
	var floor_path: Array = []
	for _i in 5:
		trench_world.tick()
		floor_world.tick()
		trench_path = (trench_world._scheduler.get_assignments().get(colonist_id, {}) as Dictionary).get("path", [])
		floor_path = (floor_world._scheduler.get_assignments().get(colonist_id, {}) as Dictionary).get("path", [])
		if not trench_path.is_empty() and not floor_path.is_empty():
			break
	_expect(not trench_path.is_empty() and trench_path == floor_path,
		"route_search.gd:220's ascending row-major tie-break is unmodified: a trench tile costs and routes exactly like floor, so the resolved path must be identical whether the equal-cost detour tile is trench or floor -- proof no trench-avoidance was added, trench=%s floor=%s" % [trench_path, floor_path])

## Requirement: "a save/load round-trip preserves trapped state (tile,
## remaining ticks for a hostile) for every entity."
func _check_save_load_round_trip_preserves_trapped_state() -> void:
	var world := _fresh_world(307001)
	world._colonists[0]["trapped"] = {"tile": Vector2i(1, 0)}
	var colonist_id: String = world._colonists[0]["id"]
	var wolf := _spawn_wolf(world, "trap_wolf", 3, 3)
	wolf["trapped"] = {"tile": Vector2i(3, 3), "ticksRemaining": 17}
	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored._find_colonist(colonist_id).get("trapped") == {"tile": Vector2i(1, 0)},
		"a save/load round trip must preserve a trapped colonist's tile exactly")
	_expect(restored._find_colonist("trap_wolf").get("trapped") == {"tile": Vector2i(3, 3), "ticksRemaining": 17},
		"a save/load round trip must preserve a trapped hostile's tile and ticksRemaining exactly")
	_expect(restored.state_hash() == world.state_hash(),
		"a save/load round trip must reproduce the exact same state_hash() once trapped state is restored")

## _actor_may_reserve_target()'s narrow
## self-tile exception must let escape_trench reserve the trapped actor's own
## tile even when it holds colony property -- one case per property kind.
## The wolf's own entry job targets a tile past the trench (2,0), routing
## through the property-laden trench tile as an intermediate step (never
## reserving it) -- exactly like the file's very first colonist check -- so
## this isolates escape_trench's own self-tile reservation (the thing under
## test) from the pre-existing, unrelated bare-tile gate on an entry job that
## targets property directly (which correctly still refuses, unchanged).
func _escape_and_confirm(world: WorldStateType, wolf: Dictionary, wolf_id: String, trench: Vector2i, label: String) -> void:
	var submit := world._scheduler.submit_autonomous(Vector2i(trench.x + 1, trench.y), 1, world.get_tick(), "incident", wolf_id)
	_expect(submit.get("ok", false), "%s: setup submission must be accepted" % label)
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "%s: setup: the wolf must be trapped before this check runs" % label)
	_expect((wolf.get("trapped", {}) as Dictionary).get("tile") == trench,
		"%s: setup: the wolf must be trapped exactly at the property-laden trench tile" % label)
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "%s: a hostile actor trapped on this tile must still auto-escape via the self-tile reservation exception" % label)

func _check_hostile_escapes_despite_ground_item_on_trench() -> void:
	var world := _fresh_world(320001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._items["item_test_wood"] = {"id": "item_test_wood", "x": 1, "y": 0, "kind": "wood", "count": 1}
	world._item_factions["item_test_wood"] = "colony"
	var wolf := _spawn_wolf(world, "trap_wolf_item", 0, 0)
	_escape_and_confirm(world, wolf, "trap_wolf_item", Vector2i(1, 0), "ground item")

func _check_hostile_escapes_despite_tool_item_on_trench() -> void:
	var world := _fresh_world(320002)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	_expect(not world.spawn_ground_tool_item("pick", 1, 0).is_empty(), "setup: a tool item must spawn on the trench tile")
	var wolf := _spawn_wolf(world, "trap_wolf_tool", 0, 0)
	_escape_and_confirm(world, wolf, "trap_wolf_tool", Vector2i(1, 0), "tool item")

func _check_hostile_escapes_despite_object_on_trench() -> void:
	var world := _fresh_world(320003)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._set_object(1, 0, "chair")
	var wolf := _spawn_wolf(world, "trap_wolf_object", 0, 0)
	_escape_and_confirm(world, wolf, "trap_wolf_object", Vector2i(1, 0), "object")

func _check_hostile_escapes_despite_stockpile_cell_on_trench() -> void:
	var world := _fresh_world(320004)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._zones["zone_test"] = {"id": "zone_test", "x": 1, "y": 0, "width": 1, "height": 1}
	var wolf := _spawn_wolf(world, "trap_wolf_zone", 0, 0)
	_escape_and_confirm(world, wolf, "trap_wolf_zone", Vector2i(1, 0), "stockpile cell")

## A go_to arrival and this same tick's work
## completion can land together -- a real IncidentScheduler.propose() wait
## job with wait_ticks=1 targeting a trench tile. Trapping must preempt the
## incident's own completion effect and despawn, not run after it.
func _check_incident_wait_job_traps_before_despawn() -> void:
	var world := _fresh_world(321001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var actor := ActorTableType.spawn("wolf", 0, 0, world._content, "trap_wolf_incident")
	actor["factionId"] = "wildlife"
	var job_id := world._incidents.propose(actor, Vector2i(1, 0), 1)
	_expect(not job_id.is_empty(), "setup: IncidentScheduler.propose() must accept the staged wait job targeting the trench tile")
	var trapped_seen := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		var found := world._find_colonist("trap_wolf_incident")
		if not found.is_empty() and found.get("trapped") != null:
			trapped_seen = true
			break
	_expect(trapped_seen, "the wolf must remain present and become trapped even when its own incident wait job's arrival and 1-tick completion land in the same tick")
	var incident_job := world._scheduler.queue.get_job(job_id)
	_expect(String(incident_job.get("status", "")) == "cancelled",
		"the incident wait job itself must be cancelled by the trap, not completed -- got status '%s'" % incident_job.get("status"))
	_expect(not world._find_colonist("trap_wolf_incident").is_empty(),
		"the wolf must still exist in the world -- trapping must preempt IncidentScheduler's own despawn-on-complete")
	var wolf := world._find_colonist("trap_wolf_incident")
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "the wolf must still auto-escape normally after this trap")

## The exit must prefer the tile the actor fell
## from over the fixed row-major order, for an entry from a direction other
## than west (already exercised by _check_hostile_actor_auto_escapes()).
func _check_hostile_exit_prefers_entry_tile_from_south() -> void:
	var world := _fresh_world(322001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_south", 1, 1)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_south")
	_expect(submit.get("ok", false), "setup: submission from the south must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	_expect((wolf["trapped"] as Dictionary).get("fromTile") == Vector2i(1, 1),
		"trapped.fromTile must record the tile the wolf fell from (south)")
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "setup: the wolf must escape")
	_expect(Vector2i(int(wolf["x"]), int(wolf["y"])) == Vector2i(1, 1),
		"the escaped actor must prefer the tile it fell from (south, (1,1)) over the row-major fallback order, which would otherwise pick west (0,0)")

## Once fromTile itself becomes impassable
## mid-climb, the exit must fall back to the row-major order among the
## remaining candidates, never leave the actor stuck on a stale preference.
func _check_hostile_exit_falls_back_when_entry_tile_blocked() -> void:
	var world := _fresh_world(322002)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_blocked_entry", 1, 1)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_blocked_entry")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	world._set_object(1, 1, "wooden_wall") # seal the tile it fell from after it is already trapped
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "setup: the wolf must still escape once its entry tile is blocked")
	_expect(Vector2i(int(wolf["x"]), int(wolf["y"])) == Vector2i(0, 0),
		"once the entry tile is blocked, the exit must fall back to the row-major fallback order (west, (0,0)) rather than the now-impassable entry tile")

## The exit must use the actor's own faction
## passability, never the colony default -- a door open to the colony but
## closed to wildlife (content/factions.json's may_pass_doors) must never be
## used as a hostile actor's own exit, even when it is the first row-major
## fallback candidate. The wolf falls in from the east (fromTile), which is
## then sealed after trapping (mirroring the blocked-entry-tile check above)
## so the exit search must walk the row-major fallback order and correctly
## skip the wildlife-forbidden door north of it.
func _check_hostile_exit_never_uses_forbidden_door() -> void:
	var world := _fresh_world(322003)
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_TRENCH
	world._set_object(1, 0, "door") # north row-major candidate: colony-passable, wildlife-forbidden
	# west (0,1) and south (1,2) stay plain floor from _fresh_world()'s own fill.
	var wolf := _spawn_wolf(world, "trap_wolf_door", 2, 1)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 1), 1, world.get_tick(), "incident", "trap_wolf_door")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	_expect((wolf["trapped"] as Dictionary).get("fromTile") == Vector2i(2, 1),
		"setup: the wolf must have fallen in from the east")
	world._set_object(2, 1, "wooden_wall") # seal fromTile so the search must fall through to the row-major order
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "the wolf must still find a non-door exit")
	var final_tile := Vector2i(int(wolf["x"]), int(wolf["y"]))
	_expect(final_tile != Vector2i(1, 0),
		"the exit must never be the wildlife-forbidden door -- the actor's own faction passability must be used, never the colony default")
	_expect(final_tile == Vector2i(0, 1),
		"with the entry tile blocked and the north candidate a forbidden door, the exit must fall back to the next passable row-major candidate (west, (0,1))")

## A "recoverable blocked-exit outcome" -- every
## candidate impassable for the actor's own faction must leave it trapped
## and retrying, never silently clear trapped or leave it with no job at all.
## Sealed with TILE_ROCK, not a "wooden_wall" object: a wall has combat
## health and CombatResolver lets a hostile actor sieging an adjacent hostile
## object break one down over time, which would eventually free the wolf via
## combat rather than proving escape_trench's own retry-forever behaviour.
## Rock is plain impassable terrain with no object health to attack.
func _check_hostile_stays_trapped_and_retries_when_no_exit_available() -> void:
	var world := _fresh_world(322004)
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_sealed", 1, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 1), 1, world.get_tick(), "incident", "trap_wolf_sealed")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(0, 1)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(2, 1)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(1, 2)] = WorldStateType.TILE_ROCK
	for _i in 300:
		world.tick()
	_expect(wolf.get("trapped") != null,
		"a hostile actor with no passable exit anywhere must stay trapped -- a blocked climb-out is a recoverable outcome, not a silent trapped: null")
	var still_retrying := false
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "escape_trench" and job["target"] == Vector2i(1, 1) and String(job.get("status", "")) == "active":
			still_retrying = true
	_expect(still_retrying, "a blocked climb-out must keep retrying with a freshly submitted escape_trench job, not give up")

## trapped.ticksRemaining must mirror the real
## escape_trench work timer tick by tick (no separate countdown engine), and
## a save/load round trip mid-climb must preserve exactly that live value.
func _check_hostile_ticks_remaining_syncs_with_real_work_progress() -> void:
	var world := _fresh_world(323001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_sync", 0, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_sync")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	_expect(int((wolf["trapped"] as Dictionary).get("ticksRemaining", -1)) == WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS,
		"trapped.ticksRemaining must read the exact configured duration the instant the climb starts")
	for _i in 5:
		world.tick()
	var mid_climb_ticks := int((wolf["trapped"] as Dictionary).get("ticksRemaining", -1))
	_expect(mid_climb_ticks == WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS - 5,
		"trapped.ticksRemaining must decrement in lockstep with the real escape_trench work timer, got %d expected %d" % [mid_climb_ticks, WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS - 5])
	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	var restored_wolf := restored._find_colonist("trap_wolf_sync")
	_expect(int((restored_wolf.get("trapped") as Dictionary).get("ticksRemaining", -1)) == mid_climb_ticks,
		"a save/load round trip mid-climb must preserve the real, already-decremented ticksRemaining, not the original full duration")
	_expect(restored.state_hash() == world.state_hash(), "a save/load round trip mid-climb must reproduce the exact same state_hash()")
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		restored.tick()
		if restored_wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "the restored wolf must still complete its climb and escape after continuing from a mid-climb save")

## Two hostiles trapped on the same tile must never
## let the second job's real climb inherit the first job's already-cleared
## work-progress key -- the second escape must take its own full configured
## duration, stamped only once IT activates (_activate_pending_escapes()),
## never the placeholder content/jobs.json work_ticks=1 a stale key would give it.
func _check_two_hostiles_trapped_on_same_tile_each_get_correct_duration() -> void:
	var world := _fresh_world(324001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf_a := _spawn_wolf(world, "trap_wolf_a", 0, 0)
	var wolf_b := _spawn_wolf(world, "trap_wolf_b", 2, 0)
	var submit_a := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_a")
	var submit_b := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_b")
	_expect(submit_a.get("ok", false) and submit_b.get("ok", false), "setup: both incident submissions must be accepted")
	var both_trapped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf_a.get("trapped") != null and wolf_b.get("trapped") != null:
			both_trapped = true
			break
	_expect(both_trapped, "setup: both wolves must fall into the same trench tile")
	# Both escape_trench jobs are only submitted (queued) the very tick each
	# wolf traps; activation happens at the START of the next _scheduler.tick()
	# (_activate_pending_escapes()), so give it a few ticks to settle before
	# reading status, without letting either job's 40-tick climb complete.
	var active_count := 0
	var queued_count := 0
	for _i in 5:
		world.tick()
		active_count = 0
		queued_count = 0
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "escape_trench" and job["target"] == Vector2i(1, 0):
				if String(job.get("status", "")) == "active": active_count += 1
				elif String(job.get("status", "")) == "queued": queued_count += 1
		if active_count == 1 and queued_count == 1:
			break
	_expect(active_count == 1 and queued_count == 1,
		"exactly one escape_trench job on the shared tile must be active, the other queued behind its reservation, got active=%d queued=%d" % [active_count, queued_count])
	var first_escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf_a.get("trapped") == null or wolf_b.get("trapped") == null:
			first_escaped = true
			break
	_expect(first_escaped, "setup: the first (active) wolf must escape, freeing the tile for the second")
	var still_trapped: Dictionary = wolf_a if wolf_a.get("trapped") != null else wolf_b
	var ticks_for_second_climb := 0
	var second_escaped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		ticks_for_second_climb += 1
		if still_trapped.get("trapped") == null:
			second_escaped = true
			break
	_expect(second_escaped, "the second wolf must eventually escape once its own turn comes")
	_expect(ticks_for_second_climb >= WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS,
		("the second escape_trench job, activated only after the first released the shared tile, must take the full " +
		"configured duration to climb out -- never the first job's already-cleared placeholder work_ticks (expected >= %d ticks, got %d)")
		% [WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS, ticks_for_second_climb])

func _remove_save_io_target() -> void:
	if FileAccess.file_exists(SAVE_IO_TARGET):
		DirAccess.remove_absolute(SAVE_IO_TARGET)

## to_save_state()/from_save_state() are plain
## StateCodec.encode()/decode() calls (world_state.gd) -- they never run
## SaveIO's own schema/bounds validation, the gate an actual save/load uses.
## A hostile trapped through real gameplay must also round-trip through
## SaveIO.write_atomic()/read(), and the restored world must still complete
## its climb-out after loading.
func _check_save_io_round_trip_preserves_trapped_hostile() -> void:
	_remove_save_io_target()
	var world := _fresh_world(325001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_saveio", 0, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_saveio")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	for _i in 5:
		world.tick()
	var expected_trapped: Dictionary = wolf["trapped"]
	_expect(expected_trapped.has("fromTile"), "setup: a naturally trapped hostile must carry fromTile")
	var state := world.to_save_state()
	var write_result: Dictionary = SaveIOType.write_atomic(SAVE_IO_TARGET, state)
	_expect(write_result.get("ok", false), "SaveIO.write_atomic() must accept a naturally produced trapped-hostile save: %s" % write_result)
	var read_result: Dictionary = SaveIOType.read(SAVE_IO_TARGET)
	_expect(read_result.get("ok", false), "SaveIO.read() must accept the same save it just wrote: %s" % read_result)
	if read_result.get("ok", false):
		var restored: WorldStateType = WorldStateType.from_save_state(read_result["state"])
		var restored_wolf := restored._find_colonist("trap_wolf_saveio")
		_expect(restored_wolf.get("trapped") == expected_trapped,
			"a SaveIO round trip must preserve trapped.tile/ticksRemaining/fromTile exactly, got %s expected %s" % [restored_wolf.get("trapped"), expected_trapped])
		var escaped := false
		for _i in TRAP_TICK_BOUND:
			restored.tick()
			if restored_wolf.get("trapped") == null:
				escaped = true
				break
		_expect(escaped, "the SaveIO-restored hostile must still complete its climb and escape")
	_remove_save_io_target()

## _valid_entity_trapped() must actually validate
## fromTile's own shape/bounds now that it is allowed, not merely accept the
## key -- an out-of-bounds fromTile must still be a typed schema_error.
func _check_save_io_rejects_malformed_from_tile() -> void:
	var world := _fresh_world(325002)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_malformed", 0, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_malformed")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	var state := world.to_save_state()
	var found := false
	for entity in state["entities"]:
		if String((entity as Dictionary).get("id", "")) == "trap_wolf_malformed":
			(entity as Dictionary)["trapped"]["fromTile"] = {"x": -1, "y": 0}
			found = true
	_expect(found, "setup: the encoded state must carry the trapped wolf's own entity")
	var validation: Dictionary = SaveIOType._validate_state(state)
	_expect(not validation.get("ok", true) and validation.get("code", "") == "schema_error",
		"an out-of-bounds trapped.fromTile must be rejected as a typed schema_error, got %s" % validation)

## A save/load taken the same tick a hostile is
## trapped -- before its escape_trench job has even had a chance to activate
## a second time -- must not lose the configured climb duration once it does
## activate after loading. world_state.gd's _activate_pending_escapes() reads
## content/actors.json's tunable fresh (via _trench_climb_ticks()) rather
## than staging it in a transient, unsaved dict, so this needs no persisted
## bookkeeping of its own to hold.
func _check_save_load_immediately_after_trapping_preserves_escape_duration() -> void:
	var world := _fresh_world(326001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_immediate", 0, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_immediate")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	var restored_wolf := restored._find_colonist("trap_wolf_immediate")
	var ticks_to_escape := 0
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		restored.tick()
		ticks_to_escape += 1
		if restored_wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "the restored wolf must still escape after a save taken the instant it was trapped")
	_expect(ticks_to_escape >= WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS and ticks_to_escape <= WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS + 5,
		"a save taken immediately after trapping must not lose the configured climb duration -- expected close to %d ticks, got %d" % [WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS, ticks_to_escape])

## A save/load taken while a second escape_trench
## job is still queued behind the first's own tile reservation must not lose
## its own configured duration once it later activates after loading.
func _check_save_load_two_queued_escapes_sharing_tile_preserves_duration() -> void:
	var world := _fresh_world(326002)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf_a := _spawn_wolf(world, "trap_wolf_q_a", 0, 0)
	var wolf_b := _spawn_wolf(world, "trap_wolf_q_b", 2, 0)
	var submit_a := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_q_a")
	var submit_b := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_q_b")
	_expect(submit_a.get("ok", false) and submit_b.get("ok", false), "setup: both incident submissions must be accepted")
	var both_trapped := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if wolf_a.get("trapped") != null and wolf_b.get("trapped") != null:
			both_trapped = true
			break
	_expect(both_trapped, "setup: both wolves must fall into the same trench tile")
	var active_count := 0
	var queued_count := 0
	for _i in 5:
		world.tick()
		active_count = 0
		queued_count = 0
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "escape_trench" and job["target"] == Vector2i(1, 0):
				if String(job.get("status", "")) == "active": active_count += 1
				elif String(job.get("status", "")) == "queued": queued_count += 1
		if active_count == 1 and queued_count == 1:
			break
	_expect(active_count == 1 and queued_count == 1, "setup: exactly one escape must be active, the other queued, before saving")
	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	var restored_a := restored._find_colonist("trap_wolf_q_a")
	var restored_b := restored._find_colonist("trap_wolf_q_b")
	var first_escaped := false
	for _i in TRAP_TICK_BOUND:
		restored.tick()
		if restored_a.get("trapped") == null or restored_b.get("trapped") == null:
			first_escaped = true
			break
	_expect(first_escaped, "setup: the restored, already-active escape must still complete")
	var still_trapped: Dictionary = restored_a if restored_a.get("trapped") != null else restored_b
	var ticks_for_second_climb := 0
	var second_escaped := false
	for _i in TRAP_TICK_BOUND:
		restored.tick()
		ticks_for_second_climb += 1
		if still_trapped.get("trapped") == null:
			second_escaped = true
			break
	_expect(second_escaped, "the restored, previously-queued escape must eventually complete")
	_expect(ticks_for_second_climb >= WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS,
		"a save/load taken while the second escape was still queued must not lose its own configured duration once activated -- expected >= %d ticks, got %d" % [WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS, ticks_for_second_climb])

## A save/load taken mid-retry, after a blocked
## climb-out resubmits a fresh escape_trench job for the same tile, must not
## lose that retry's own configured duration either.
func _check_save_load_after_blocked_exit_retry_preserves_duration() -> void:
	var world := _fresh_world(326003)
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_retry", 1, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 1), 1, world.get_tick(), "incident", "trap_wolf_retry")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	var initial_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "escape_trench" and job["target"] == Vector2i(1, 1):
			initial_job_id = String(job["id"])
	_expect(not initial_job_id.is_empty(), "setup: the wolf's first escape_trench job must be found")
	world._set_object(1, 0, "wooden_wall")
	world._set_object(0, 1, "wooden_wall")
	world._set_object(2, 1, "wooden_wall")
	world._set_object(1, 2, "wooden_wall")
	# Tick only until the FIRST climb finishes and the blocked exit forces a
	# fresh resubmission (a new job_id on the same tile) -- save right as
	# that retry appears, still queued or only just active, the exact window
	# where a staged-but-unpersisted duration would be lost.
	var retry_job_id := ""
	for _i in WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS + 10:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "escape_trench" and job["target"] == Vector2i(1, 1) \
					and String(job["id"]) != initial_job_id and String(job.get("status", "")) in ["queued", "active"]:
				retry_job_id = String(job["id"])
		if not retry_job_id.is_empty():
			break
	_expect(not retry_job_id.is_empty(), "setup: a blocked climb-out must resubmit a fresh escape_trench job to retry")
	_expect(wolf.get("trapped") != null, "setup: the wolf must still be trapped, now retrying")
	world._set_object(1, 2, "") # open exactly one exit for the retry to find
	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	var restored_wolf := restored._find_colonist("trap_wolf_retry")
	var ticks_to_escape := 0
	var escaped := false
	for _i in TRAP_TICK_BOUND:
		restored.tick()
		ticks_to_escape += 1
		if restored_wolf.get("trapped") == null:
			escaped = true
			break
	_expect(escaped, "the restored wolf must still escape once its retry's exit opens")
	_expect(ticks_to_escape >= WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS - 5,
		"a save/load taken just as a blocked-exit retry appears must not lose that retry's own configured climb duration -- expected close to %d ticks, got %d" % [WorldStateType.DEFAULT_TRENCH_CLIMB_TICKS, ticks_to_escape])

## Trapping must resolve a cancelled need job's
## NeedGiver association exactly like _apply_job_command()'s own cancel_job
## path does -- otherwise the cancelled job's id stays in NeedGiver._pending
## indefinitely, silently blocking that colonist from ever getting a fresh
## need job for the same need kind.
func _check_trapping_during_need_journey_resolves_need_giver() -> void:
	var world := _fresh_world(327001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._ground_berries["2_0"] = 1
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	colonist["needs"]["food"] = 5
	for other in world._need_definitions.keys():
		if other != "food":
			world._need_definitions[other]["rate_per_day"] = 0
	var job_id := ""
	for _i in TRAP_TICK_BOUND:
		world.tick()
		job_id = world._need_giver.get_pending_job(colonist_id)
		if not job_id.is_empty():
			break
	_expect(not job_id.is_empty(), "setup: the colonist's low food need must commit a real eat_food need job")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "the colonist must fall into the trench en route to its need job")
	_expect(world._need_giver.colonist_for_job(job_id).is_empty(),
		"trapping must resolve the cancelled need job's NeedGiver association, not leave it pending forever")
	_expect(world._need_giver.get_pending_job(colonist_id).is_empty(),
		"trapping must clear the trapped colonist's own pending-job pointer in NeedGiver")

## An actor whose route step lands it exactly on
## its own job's target -- which happens to already be trench -- can have
## the work toil start (writing an initial work-progress entry for that
## tile) in the very same tick trapping cancels the job. That cancelled
## job's progress must not survive the trap.
func _check_trapping_on_work_target_arrival_clears_progress() -> void:
	var world := _fresh_world(328001)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_TRENCH
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	var submit := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", colonist_id)
	_expect(submit.get("ok", false), "setup: till submission targeting the pre-existing trench tile must be accepted (bypasses CommandChecks, exactly like the scheduler's own gate does for an autonomous/direct submission)")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "the colonist must become trapped on arriving at its own job's target")
	_expect(world._get_work_progress(Vector2i(2, 0)) == null,
		"trapping on arrival at a work target must clear that target's owned work-progress key, not leave the cancelled job's progress behind")

## An actor trapped while carrying a haul item
## (mid-second-leg, walking to the stockpile cell) must release both the
## item's own reservation and the destination cell's reservation exactly
## like a real cancel_job, and must not strand the carried item in
## "carrying" forever.
func _check_trapping_mid_haul_releases_item_and_cell_reservations() -> void:
	var world := _fresh_world(329001)
	# The item sits adjacent to the colonist's own start tile, so "reserve,
	# go_to, pick_up" (the haul job's first leg) never has to move at all --
	# pickup happens in place. (1,0) and (2,0) are walled off so the second
	# leg (carrying the item to the stockpile cell) has no equal-or-cheaper
	# route around the trench at (1,1): it must step onto it.
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_TRENCH
	world._items["item_test_wood"] = {"id": "item_test_wood", "x": 0, "y": 1, "kind": "wood", "count": 1}
	var colonist: Dictionary = world._colonists[0]
	var zone_result := world.apply({"actor": "test", "command_id": "zone_1", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 2, "y": 1, "width": 1, "height": 1}})
	_expect(zone_result.get("ok", false), "setup: stockpile zone must be added: %s" % zone_result)
	var job_id := ""
	for _i in TRAP_TICK_BOUND:
		world.tick()
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "haul" and String(job.get("status", "")) == "active":
				job_id = String(job["id"])
		if InventoryType.is_carrying(colonist):
			break
	_expect(InventoryType.is_carrying(colonist), "setup: the colonist must pick up the haul item before this check runs")
	_expect(not job_id.is_empty(), "setup: a real haul job must be active")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "the colonist must fall into the trench en route to the stockpile cell")
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "cancelled", "the haul job must be cancelled exactly like any other trapped actor's own job")
	_expect(not InventoryType.is_carrying(colonist), "trapping mid-haul must drop the carried item, never strand it in 'carrying'")
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(),
		"trapping mid-haul must free both the item's own reservation and the destination cell's reservation, leaving no orphans")

## _toil_on_work_complete()'s own trap pre-check
## must require the actor to have actually arrived ON target this tick, not
## merely that _trap_tile_before != target -- a paused dig resumed from an
## adjacent tile, after another worker has already dug its target into
## trench, must reject the now-invalid dig target (matching the ordinary
## till/sow/mine re-check already just below it), never falsely trap the
## still-adjacent, never-moved actor on its own (non-trench) tile.
func _check_stale_dig_target_dug_by_other_worker_does_not_falsely_trap() -> void:
	var world := _fresh_world(330001)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	world.spawn_ground_tool_item("pick", 0, 0)
	var colonist: Dictionary = world._colonists[0]
	colonist["x"] = 1
	colonist["y"] = 0
	var colonist_id: String = colonist["id"]
	var submit := world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "dig", colonist_id)
	_expect(submit.get("ok", false), "setup: dig submission must be accepted")
	var job_id: String = String(submit["job_id"])
	for _i in TRAP_TICK_BOUND:
		world.tick()
		if String(world._scheduler.queue.get_job(job_id).get("status", "")) == "active" \
				and not String(colonist.get("held_tool", "")).is_empty():
			break
	_expect(String(world._scheduler.queue.get_job(job_id).get("status", "")) == "active", "setup: the dig job must be active")
	_expect(not String(colonist.get("held_tool", "")).is_empty(), "setup: the colonist must already hold a real pick (fetched via the ordinary fetch_tool toil)")
	# Simulate "another worker already dug the target while this job was
	# paused": the target flips to trench underneath, and this colonist's own
	# work resumes from the adjacent tile it was paused at, one tick from
	# completing -- never having actually stepped onto target this tick. Its
	# held_tool (a real tool item id, fetched above) is left exactly as the
	# simulation produced it.
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_TRENCH
	colonist["x"] = 1
	colonist["y"] = 0
	colonist["route"] = null
	colonist["work"] = {"job_id": job_id, "ticks_remaining": 1}
	world.tick()
	_expect(colonist.get("trapped") == null,
		"a stationary actor that never moved onto a target another worker changed into trench must not be trapped")
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "failed" and String(job.get("reason", "")) == "invalid_target",
		"the stale dig target must be rejected like any other invalid target once its tile no longer matches, got status '%s' reason '%s'" % [job.get("status"), job.get("reason")])

## _remove_colonist_by_id()'s trapped-actor despawn
## suppression exists only to stop IncidentScheduler's own ordinary
## incident-lifecycle despawn from vanishing a trapped actor; it must never
## suppress an ACTUAL death. A trapped colonist killed in combat (or any
## other cause routed through _apply_actor_death()) must leave the roster,
## with its scheduling/reservation cleanup intact, exactly like an untrapped
## death always has.
func _check_trapped_colonist_removed_on_death() -> void:
	var world := _fresh_world(331001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	_expect(world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", colonist_id).get("ok", false),
		"setup: till submission must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: the colonist must be trapped before this check runs")
	world._apply_actor_death(colonist)
	_expect(world._find_colonist(colonist_id).is_empty(),
		"a trapped actor killed via _apply_actor_death() must still be removed from the roster -- death must never be suppressed by the trapped-despawn guard")
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "death while trapped must leave no orphaned reservations")

## The same death-must-win guarantee for a hostile
## actor killed while its own auto-submitted escape_trench job is active.
## Killing the wolf right after submission would not exercise the cleanup,
## because the job would not yet have activated or acquired its self-tile
## reservation. So this ticks until the escape_trench job reports "active",
## asserts its assignment (restricted to the wolf) and its self-tile
## reservation both exist, then kills the wolf and verifies removal, job
## termination, and reservation release.
func _check_trapped_hostile_removed_on_death_during_escape() -> void:
	var world := _fresh_world(332001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var wolf := _spawn_wolf(world, "trap_wolf_death", 0, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_wolf_death")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	_expect(_tick_until_trapped(world, wolf, TRAP_TICK_BOUND), "setup: the wolf must be trapped before this check runs")
	var escape_job_id := ""
	for _i in TRAP_TICK_BOUND:
		for job in world.get_jobs():
			if String(job.get("kind", "")) == "escape_trench" and job["target"] == Vector2i(1, 0) \
					and String(job.get("status", "")) == "active":
				escape_job_id = String(job["id"])
		if not escape_job_id.is_empty():
			break
		world.tick()
	_expect(not escape_job_id.is_empty(),
		"setup: the wolf's auto-submitted escape_trench job must actually reach 'active' before this check runs")
	if escape_job_id.is_empty():
		return
	_expect(world._job_restricted_to(escape_job_id) == "trap_wolf_death",
		"setup: the active escape_trench job must be assigned to the trapped wolf")
	var reservation_key := world._tile_key(1, 0)
	_expect(world._scheduler.queue.get_reservation_table().is_reserved(reservation_key),
		"setup: the active escape_trench job must hold its own self-tile reservation before death")
	world._apply_actor_death(wolf)
	_expect(world._find_colonist("trap_wolf_death").is_empty(),
		"a trapped hostile killed mid-escape must still be removed from the roster, not kept alive by the trapped-despawn guard")
	var final_status := String(world._scheduler.queue.get_job(escape_job_id).get("status", ""))
	_expect(final_status in ["cancelled", "failed", "completed"],
		"death mid-escape must terminate the active escape_trench job, got status '%s'" % final_status)
	_expect(not world._scheduler.queue.get_reservation_table().is_reserved(reservation_key),
		"death mid-escape must release the active escape_trench job's own self-tile reservation")
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(),
		"death mid-escape must release the active escape_trench job's own reservations, leaving no orphans")

## Trap/climb-out behaviour does not extend to non-hostile, non-colonist
## actors (ADR 026 non-goal). A trader (no worker
## component, faction "traders" -- neutral toward "colony", never hostile per
## Relations) must land on a trench tile via a real, ticked job -- go_to's
## own route step, then work's own arrival -- completely unaffected: never
## trapped, its job completes normally, and it is never held in place the way
## a trapped actor's own cancelled job would be.
func _check_trader_crosses_trench_unaffected() -> void:
	var world := _fresh_world(333001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	var trader := _spawn_trader(world, "trap_trader", 0, 0)
	var submit := world._scheduler.submit_autonomous(Vector2i(1, 0), 1, world.get_tick(), "incident", "trap_trader")
	_expect(submit.get("ok", false), "setup: submission must be accepted")
	var job_id: String = String(submit["job_id"])
	var reached_trench := false
	for _i in TRAP_TICK_BOUND:
		world.tick()
		_expect(trader.get("trapped") == null, "a trader must never become trapped by stepping onto or targeting a trench tile")
		if Vector2i(int(trader["x"]), int(trader["y"])) == Vector2i(1, 0):
			reached_trench = true
			break
	_expect(reached_trench, "setup: the trader must actually reach the trench tile")
	_expect(trader.get("trapped") == null, "the trader must stay untrapped once it reaches the trench tile")
	for _i in 5:
		world.tick()
	var job := world._scheduler.queue.get_job(job_id)
	_expect(String(job.get("status", "")) == "completed",
		"the trader's own job must complete normally, exactly like any other non-trapped incident actor's, got status '%s'" % job.get("status"))

## CombatGiver still receives a trapped actor (it
## filters only on the "combat" component, never trapped state) and would
## otherwise submit a `flee` job for one below its own flee_hp_fraction
## through submit_autonomous() -- bypassing _colonist_may_be_ordered()
## entirely, the same gate an ordinary job command is refused at.
## _actor_may_reserve_target() now refuses every autonomous target for a
## trapped actor except its own tile, so every flee candidate CombatGiver
## considers is refused and it can never actually submit one; a trapped actor
## also never moves. Lowering hp alone is not enough: without a hostile
## threat, CombatGiver's `threat.is_empty()` guard short-circuits before the
## reservation gate, so the check would pass for the wrong reason. This check
## introduces a real hostile threat (a raider, `_spawn_raider`) after
## trapping, and adds an identical, untrapped control colonist exposed to the
## same threat and hp to prove
## CombatGiver actually attempts (and succeeds at) fleeing under these exact
## conditions -- so the trapped colonist's own lack of a flee job is proven to
## be the reservation gate at work, not an absent threat.
func _check_trapped_colonist_cannot_flee_via_combat_giver() -> void:
	var world := _fresh_world(334001)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TRENCH
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	_expect(world._scheduler.submit(Vector2i(2, 0), 1, world.get_tick(), "till", colonist_id).get("ok", false),
		"setup: till submission must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: the colonist must be trapped before this check runs")
	var trapped_tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
	var control: Dictionary = ActorTableType.spawn("colonist", 20, 20, world._content, "flee_control_colonist")
	control.erase("carrying")
	control["hands"] = []
	world._append_colonist(control)
	var control_start := Vector2i(int(control["x"]), int(control["y"]))
	_spawn_raider(world, "flee_threat_raider_cg", trapped_tile.x + 3, trapped_tile.y)
	colonist["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	control["health"]["hp"] = 25 # the same threshold, so the control is equally eligible to flee
	for _i in TRAP_TICK_BOUND:
		world.tick()
	for job in world.get_jobs():
		_expect(String(job.get("kind", "")) != "flee" or world._job_restricted_to(String(job["id"])) != colonist_id,
			"a trapped colonist below its own flee threshold must never get an auto-submitted flee job, got one in status '%s'" % job.get("status"))
	_expect(colonist.get("trapped") != null, "the colonist must still be trapped")
	_expect(Vector2i(int(colonist["x"]), int(colonist["y"])) == trapped_tile,
		"a trapped colonist must never move away, even while below its own flee threshold")
	_expect(Vector2i(int(control["x"]), int(control["y"])) != control_start,
		"control: an untrapped colonist facing the same hostile threat and hp must actually flee, proving CombatGiver was exercised for real -- otherwise the trapped colonist's own lack of a flee job proves nothing")

## Trapping also applies to a colonist that falls into a trench during an
## existing flee episode: an actor already mid-flee (its own
## `flee` job active, walking its resolved path) that steps onto a trench
## tile must be trapped exactly like any other job's actor: released like
## cancel_job, no auto-exit (a colonist, per ADR 026's non-goals), and CombatGiver must
## never resurrect a replacement flee leg for it while it stays trapped (the
## same _actor_may_reserve_target() fix that backs the check above).
## Boxes (x, y) in with impassable rock on every one of its 8 neighbours
## except due north, which is left as a single-tile corridor -- so any
## reachable destination CombatGiver's own flee-target search can find lies
## through that one tile, regardless of exactly which distance/direction it
## eventually picks. Used to force a fleeing actor's very first step onto a
## tile this file controls (the corridor tile, set to trench by the caller)
## without depending on the exact resolved path array CombatGiver's own
## target search produces.
func _box_in_except_north(world: WorldStateType, x: int, y: int) -> void:
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0: continue
			if dx == 0 and dy == -1: continue # the one open exit
			world._tiles[world._tile_index(x + dx, y + dy)] = WorldStateType.TILE_ROCK

func _check_colonist_trapped_during_active_flee_episode() -> void:
	var world := _fresh_world(335001)
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	colonist["x"] = 5
	colonist["y"] = 5
	_box_in_except_north(world, 5, 5)
	world._tiles[world._tile_index(5, 4)] = WorldStateType.TILE_TRENCH # the one exit, away from the threat below
	_spawn_raider(world, "flee_threat_raider", 5, 20)
	colonist["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND),
		"the colonist must become trapped once its own flee job's first step lands it on the only available exit tile, a trench")
	var flee_job_id := ""
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			flee_job_id = String(job["id"])
	_expect(not flee_job_id.is_empty(), "setup: the colonist must have gotten a real flee job before falling into the trench")
	if flee_job_id.is_empty():
		return
	var flee_job := world._scheduler.queue.get_job(flee_job_id)
	_expect(String(flee_job.get("status", "")) == "cancelled",
		"the active flee job must be released exactly like cancel_job once the colonist is trapped, got status '%s'" % flee_job.get("status"))
	for _i in TRAP_TICK_BOUND:
		world.tick()
	_expect(colonist.get("trapped") != null, "a trapped colonist mid-flee must stay trapped -- no auto-exit, matching every other trapped colonist")
	for job in world.get_jobs():
		if String(job.get("kind", "")) == "flee":
			_expect(String(job.get("status", "")) in ["cancelled", "failed"],
				"CombatGiver must never resurrect a replacement flee leg for a trapped colonist, got a flee job in status '%s'" % job.get("status"))
	var report := ReservationInvariantsType.check(world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect((report["orphaned_reservations"] as Array).is_empty(), "trapping mid-flee must leave no orphaned reservations")

## "including save/load continuation" -- a colonist trapped
## mid-flee must survive a save/load round trip without CombatGiver
## resurrecting a replacement flee leg once ticking resumes on the restored
## world, exactly like the live-world check above.
func _check_save_load_preserves_trapped_state_during_flee_episode() -> void:
	var world := _fresh_world(336001)
	var colonist: Dictionary = world._colonists[0]
	var colonist_id: String = colonist["id"]
	colonist["x"] = 5
	colonist["y"] = 5
	_box_in_except_north(world, 5, 5)
	world._tiles[world._tile_index(5, 4)] = WorldStateType.TILE_TRENCH # the one exit, away from the threat below
	_spawn_raider(world, "flee_threat_raider_save", 5, 20)
	colonist["health"]["hp"] = 25 # below the colonist's own 0.3 flee_hp_fraction
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: the colonist must become trapped mid-flee")
	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored._find_colonist(colonist_id).get("trapped") != null,
		"a save/load round trip must preserve a colonist trapped mid-flee")
	for _i in TRAP_TICK_BOUND:
		restored.tick()
	_expect(restored._find_colonist(colonist_id).get("trapped") != null,
		"a colonist trapped mid-flee must stay trapped after a save/load round trip, with no auto-exit")
	for job in restored.get_jobs():
		if String(job.get("kind", "")) == "flee":
			_expect(String(job.get("status", "")) in ["cancelled", "failed"],
				"CombatGiver must never resurrect a replacement flee leg for a trapped colonist after a save/load round trip, got a flee job in status '%s'" % job.get("status"))
