extends SceneTree

## Content-only extension point, proving content/factions.json's
## "predators" row, content/actors.json's "wolf" flee_hp_fraction tunable and
## content/incidents.json's "wolf_attack" row (including its own spawn.lingers
## flag, ADR 034) combine through the generic systems alone
## (IncidentScheduler, ApproachGiver/ADR 033, CombatResolver/
## CombatGiver/ADR 021) to spawn a wolf that reaches a colony door,
## fights it, and flees -- no wolf-specific code anywhere. No check in this
## file ever sets the wolf's own destination or target: the incident's own
## spawn choreography and the generic approach/attack/flee systems are what
## place and drive it. Mirrors the reference arena of test_incidents.gd's
## _build_lingering_arena()/_draw_lingering_incident() (ADR 034).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

const TICK_RATE := 10
const SEED := 5304
const MIN_DAY := 6
## content/incidents.json's wolf_attack row spawns on the "south" edge
## (y = MAP_HEIGHT - 1) -- deliberately different from the pre-existing
## test-only "raider_incursion" incident's own "north" edge (ADR 034,
## test_incidents.gd's own lingering-hand-off arena), so this file's daily
## budget draw (day 6 onward) can never compete with that arena's own
## north-edge spawn tile for the same candidate.
const SPAWN_TILE := Vector2i(24, 47)
## Bare floor tiles between the spawn and the door, all genuinely not
## adjacent to it (Chebyshev distance >= 2): with NEAR_DOOR_TILE sealed off
## (see _draw_wolf_attack_naturally_away_from_door()) these are IncidentScheduler's own
## _pick_reachable_target()'s only candidates, so whichever one its seeded RNG
## picks, the wolf's own incident-assigned destination is guaranteed
## non-adjacent to the door -- proving the generic ApproachGiver hand-off
## (not a coincidental incident target) is what closes the gap.
const FAR_CORRIDOR_START_Y := 46
const FAR_CORRIDOR_END_Y := 42
const NEAR_DOOR_TILE := Vector2i(24, 41)
const DOOR_TILE := Vector2i(24, 40)
## Behind the door, not walled off: a "bed" object (passable, no health) sits
## here only to keep this tile out of IncidentScheduler's own
## _pick_reachable_target() candidate pool (a per-tile passability/bareness
## pre-filter, never a faction-aware route) -- otherwise this bare floor tile
## could be handed to the wolf as its own incident target, and the later
## faction-aware route search would then retire the job as unreachable,
## so the wolf would never spawn at all. "predators" may not pass a door
## (content/factions.json), so this is the only thing that keeps the guard
## safe; a rock tile here would prove nothing about the door.
const GUARD_TILE := Vector2i(24, 39)
const GUARD_ID := "door_guard"
const NO_TILE := Vector2i(-1, -1)
## Generous relative to the wolf's own 20-tick combat cooldown (content/
## actors.json): enough ticks after arrival to observe several attacks land.
const ATTACK_OBSERVE_TICKS := 90
const ARRIVAL_TICK_BUDGET := 200
const FLEE_TICK_BUDGET := 30
const NATURAL_DRAW_ARRIVAL_BUDGET := 400

var _failed := false

func _init() -> void:
	_check_wolf_attack_content_row()
	_check_wolf_attack_natural_draw_at_day6()
	_check_wolf_reaches_door_fights_and_flees_and_guard_survives()
	_check_same_seed_reproduces_identical_hash()

	if _failed:
		quit(1)
		return
	print("test_wolf_attack: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A fully controlled, colonist-free-except-the-guard arena: every tile is
## rock (impassable to everyone) except a single-file corridor from
## SPAWN_TILE (the wolf's own edge spawn) up through FAR_CORRIDOR_START_Y..
## FAR_CORRIDOR_END_Y, NEAR_DOOR_TILE, and GUARD_TILE (excluded from
## IncidentScheduler's own random-target candidacy by its own "bed" object,
## see the doc comment on the constant above). A colony door sits immediately
## north of NEAR_DOOR_TILE; "predators" cannot pass a door (content/
## factions.json), so the wolf can never do anything but stop beside the door
## and fight it, and the guard standing in the passable room directly behind
## that door is reachable only through it.
func _build_wolf_attack_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	for y in range(GUARD_TILE.y, SPAWN_TILE.y + 1):
		world._tiles[world._tile_index(SPAWN_TILE.x, y)] = WorldStateType.TILE_FLOOR
	world._set_object(DOOR_TILE.x, DOOR_TILE.y, "door") # defaults to faction "colony"
	world._set_object(GUARD_TILE.x, GUARD_TILE.y, "bed") # defaults to faction "colony"; keeps GUARD_TILE out of candidacy
	var guard := ActorTableType.spawn("colonist", GUARD_TILE.x, GUARD_TILE.y, world._content, GUARD_ID)
	guard.erase("carrying")
	guard["hands"] = []
	guard["factionId"] = "colony"
	world._append_colonist(guard)
	return world

## content/calendar.json's day_length_ticks combined with MIN_DAY: the exact
## tick at which IncidentScheduler.advance() (called from world.tick(), never
## the spawn_incident debug command) transitions into day 6 and runs that
## day's budgeted draw (calendar_service.gd's day_of_tick(): day 6 covers
## ticks [5*day_length_ticks, 6*day_length_ticks)).
func _day6_tick(world: WorldStateType) -> int:
	return (MIN_DAY - 1) * int(world._calendar.day_length_ticks())

## Ticks world up to (but not including) the one world.tick() call in which
## the day-6 draw fires, so a caller can bracket exactly that call.
func _advance_to_eve_of_day6(world: WorldStateType) -> void:
	var day6_tick := _day6_tick(world)
	while world.get_tick() < day6_tick - 1:
		world.tick()

## Drives the ordinary day-6 budgeted incident draw (IncidentScheduler.
## advance(), reached only through world.tick() -- never spawn_incident/
## force_spawn) to completion. NEAR_DOOR_TILE is sealed with a "bed" object
## for the exact single world.tick() call in which the draw fires --
## IncidentScheduler's own _pick_reachable_target() pre-filter (per-tile
## passability/bareness, never a faction-aware route) runs synchronously
## inside that one call, so with the only door-adjacent tile temporarily
## excluded, its candidate pool is exactly the FAR_CORRIDOR_* tiles, every one
## of them genuinely non-adjacent to the door. The seal is lifted immediately
## after so NEAR_DOOR_TILE is bare and reservable again by the time
## ApproachGiver's own search ever looks at it. Returns the wolf_attack
## incident_started event's own actor_ids ([] if the draw did not fire).
func _draw_wolf_attack_naturally_away_from_door(world: WorldStateType) -> Array:
	_advance_to_eve_of_day6(world)
	world._set_object(NEAR_DOOR_TILE.x, NEAR_DOOR_TILE.y, "bed")
	world.tick()
	world._set_object(NEAR_DOOR_TILE.x, NEAR_DOOR_TILE.y, "")
	var events := _incident_started_events(world, "wolf_attack")
	if events.is_empty():
		return []
	return (events[0].get("data", {}) as Dictionary).get("actor_ids", [])

func _tick_until(world: WorldStateType, predicate: Callable, budget: int) -> int:
	for i in budget:
		if predicate.call(world):
			return i
		world.tick()
	return -1 if not predicate.call(world) else budget

func _in_world(actor_id: String) -> Callable:
	return func(world: WorldStateType) -> bool: return not world._find_colonist(actor_id).is_empty()

func _actor_pos(world: WorldStateType, actor_id: String) -> Vector2i:
	var actor := world._find_colonist(actor_id)
	return Vector2i(int(actor["x"]), int(actor["y"])) if not actor.is_empty() else NO_TILE

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

func _assignment_job_id(world: WorldStateType, actor_id: String) -> String:
	return String(world.get_assignments().get(actor_id, {}).get("job_id", ""))

func _incident_started_events(world: WorldStateType, incident_id: String) -> Array:
	var matches: Array = []
	for event in world.get_events():
		if String(event.get("type", "")) == "incident_started" and String((event.get("data", {}) as Dictionary).get("incident_id", "")) == incident_id:
			matches.append(event)
	return matches

## content/incidents.json's declarative shape:
## faction predators, min_day 6, spawn.lingers set (ADR 034).
func _check_wolf_attack_content_row() -> void:
	if _failed: return
	var world := _build_wolf_attack_world(SEED)
	var entry: Dictionary = world._content.get_entry("incidents", "wolf_attack")
	_expect(not entry.is_empty(), "content/incidents.json must declare a 'wolf_attack' row")
	if entry.is_empty(): return
	_expect(int(entry.get("min_day", -1)) == MIN_DAY, "wolf_attack's min_day must be 6, got %s" % entry.get("min_day"))
	_expect(String(entry.get("faction", "")) == "predators", "wolf_attack's faction must be 'predators', got %s" % entry.get("faction"))
	var spawn_def: Dictionary = entry.get("spawn", {})
	_expect(String(spawn_def.get("actor_def", "")) == "wolf", "wolf_attack must spawn the 'wolf' actor def")
	_expect(bool(spawn_def.get("lingers", false)), "wolf_attack's spawn block must set the lingers flag (ADR 034)")

## Proves the real, budget-gated daily draw fires wolf_attack on its own once
## the calendar reaches its content-declared min_day, on a real generated
## world (never the tiny controlled arena below) -- mirrors test_incidents.gd's
## own natural-draw checks. The checks below reuse the very same day-6 draw
## mechanism, but inside the controlled arena, to pin down movement/combat/
## flee determinism; spawn_incident/force_spawn is never called anywhere in
## this file.
func _check_wolf_attack_natural_draw_at_day6() -> void:
	if _failed: return
	var world := WorldStateType.new(SEED, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	var day6_tick: int = (MIN_DAY - 1) * int(world._calendar.day_length_ticks())
	while world.get_tick() < day6_tick:
		world.tick()
	var events := _incident_started_events(world, "wolf_attack")
	_expect(events.size() >= 1, "day 6's real daily draw must fire the wolf_attack incident on its own, with no spawn_incident command")
	if events.is_empty(): return
	var actor_ids: Array = (events[0].get("data", {}) as Dictionary).get("actor_ids", [])
	_expect(actor_ids.size() == 1, "wolf_attack's natural draw must propose its content-declared count of 1 wolf, got %d" % actor_ids.size())
	if actor_ids.is_empty(): return
	var wolf_id := String(actor_ids[0])
	_expect(_tick_until(world, _in_world(wolf_id), NATURAL_DRAW_ARRIVAL_BUDGET) >= 0,
		"the naturally-drawn wolf must enter the world once its own incident job activates")
	var wolf := world._find_colonist(wolf_id)
	_expect(String(wolf.get("kind", "")) == "wolf", "the naturally-drawn actor must be a 'wolf'")
	_expect(String(wolf.get("factionId", "")) == "predators", "the naturally-drawn actor must carry the 'predators' faction")

## End-to-end, in the controlled arena, through the real day-6 budgeted
## incident draw (IncidentScheduler.advance(), reached only by ticking world
## forward, never spawn_incident/force_spawn): edge/
## target selection, activation, movement, the lingering hand-off, combat and
## flee all run through the real, unmodified generic systems, fired by the
## same daily draw that would occur in an ordinary game on day 6. This test
## supplies no destination or target for the wolf at any point.
##
## _draw_wolf_attack_naturally_away_from_door() guarantees the incident's own
## spawn destination is not adjacent to the door: NEAR_DOOR_TILE is sealed off
## for the one synchronous world.tick() call that picks the incident's own
## target, so that pick can only ever land on a FAR_CORRIDOR_* tile, every one
## genuinely non-adjacent to the door. Content's own "lingers" flag on
## wolf_attack's spawn row (incident_scheduler.gd's on_job_finished(), ADR
## 034) is what makes the hand-off possible at all: once the wolf's own short
## walk-then-wait job ends, it stays in the world instead of despawning,
## freeing its one scheduler assignment for the `approach` job ApproachGiver
## already has queued for it -- which then walks it the rest of the way to
## NEAR_DOOR_TILE and starts the fight.
func _check_wolf_reaches_door_fights_and_flees_and_guard_survives() -> void:
	if _failed: return
	var world := _build_wolf_attack_world(SEED)
	var actor_ids := _draw_wolf_attack_naturally_away_from_door(world)
	_expect(actor_ids.size() == 1, "the day-6 draw must propose wolf_attack's content-declared count of 1 wolf, got %d" % actor_ids.size())
	if actor_ids.is_empty(): return
	var wolf_id := String(actor_ids[0])

	_expect(_tick_until(world, _in_world(wolf_id), ARRIVAL_TICK_BUDGET) >= 0,
		"the proposed wolf must enter the world once its own incident job activates")
	var wolf := world._find_colonist(wolf_id)
	_expect(String(wolf.get("kind", "")) == "wolf", "wolf_attack must spawn a 'wolf' actor")
	_expect(String(wolf.get("factionId", "")) == "predators", "a wolf_attack actor must carry the 'predators' faction")

	# Proves the seal in _draw_wolf_attack_naturally_away_from_door() actually
	# worked: IncidentScheduler's own target for this wolf's first job is a
	# FAR_CORRIDOR_* tile, genuinely non-adjacent to the door -- everything
	# after this point is the generic lingering hand-off/approach behaviour,
	# never a coincidence and never set by this test.
	var incident_target: Vector2i = _find_job(world, _assignment_job_id(world, wolf_id)).get("target", NO_TILE)
	_expect(incident_target != NO_TILE, "the wolf's own incident job must carry a target")
	_expect(maxi(absi(incident_target.x - DOOR_TILE.x), absi(incident_target.y - DOOR_TILE.y)) > 1,
		"the incident's own target (%s) must NOT be adjacent to the door -- the seal in _draw_wolf_attack_naturally_away_from_door() must have worked" % incident_target)

	# The incident's own arrival job (walk then wait at its non-adjacent
	# target) must run to completion, and the wolf must survive that
	# completion (spawn.lingers, ADR 034) instead of despawning.
	var incident_job_id := _assignment_job_id(world, wolf_id)
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return String(_find_job(w, incident_job_id).get("status", "")) == "completed", ARRIVAL_TICK_BUDGET) >= 0,
		"the wolf's own incident arrival job (walk then wait) must run to completion")
	_expect(not world._find_colonist(wolf_id).is_empty(), "the wolf must survive its own incident arrival job's completion instead of despawning (spawn.lingers)")

	# Never set by this test: the incident's own spawn choreography, the
	# lingering hand-off (ADR 034) and the generic approach/attack systems
	# are what put it here.
	_expect(_tick_until(world, func(w: WorldStateType) -> bool: return _actor_pos(w, wolf_id) == NEAR_DOOR_TILE, ARRIVAL_TICK_BUDGET) >= 0,
		"the wolf must walk itself adjacent to the door with no destination supplied by this test")

	# get_actor_combat_reason() is a transient per-tick reason (ADR 021, never
	# an event), so it must be sampled while the wolf is actively engaged --
	# the door only has 40 hp against the wolf's own 8 damage, so it may be
	# destroyed (and the reason revert to "") partway through this window.
	var observed_fighting := false
	for i in ATTACK_OBSERVE_TICKS:
		world.tick()
		if world.get_actor_combat_reason(wolf_id) == "fighting":
			observed_fighting = true
	_expect(observed_fighting,
		"get_actor_combat_reason(wolf_id) must report 'fighting' at some point while the wolf is adjacent to and attacking the door")

	var attacks := 0
	for event in world.get_events():
		if String(event.get("type", "")) != "attacked_by": continue
		if String((event.get("data", {}) as Dictionary).get("attacker_id", "")) != wolf_id: continue
		attacks += 1
	_expect(attacks >= 2, "the wolf must damage the door every cooldown, not merely once (got %d attacked_by events)" % attacks)

	var guard := world._find_colonist(GUARD_ID)
	_expect(not guard.is_empty(), "the guard colonist must still be in the world")
	if not guard.is_empty():
		var guard_health: Dictionary = guard["health"]
		_expect(not bool(guard_health.get("dead", false)) and int(guard_health["hp"]) == int(guard_health["maxHp"]),
			"a colonist behind the closed door, in a passable room reachable only through it, must take no damage and survive (got %s)" % guard_health)

	# Force the wolf below its own content-declared flee_hp_fraction (0.3 of
	# 40 maxHp = 12) the same way test_combat.gd's own flee checks do (a
	# direct hp mutation, not a fabricated attacker) -- proving the generic
	# flee mechanic honours this actor def's own tunable, not that a live
	# opponent can out-damage a door in this arena.
	world._find_colonist(wolf_id)["health"]["hp"] = 5
	var fled := false
	for i in FLEE_TICK_BUDGET:
		world.tick()
		if world._combat_giver.owns(wolf_id):
			fled = true
			break
	_expect(fled, "the wolf must start fleeing once its hp fraction drops below its own flee_hp_fraction (0.3)")

	var guard_after := world._find_colonist(GUARD_ID)
	if not guard_after.is_empty():
		var guard_health_after: Dictionary = guard_after["health"]
		_expect(not bool(guard_health_after.get("dead", false)) and int(guard_health_after["hp"]) == int(guard_health_after["maxHp"]),
			"the guard behind the closed door must remain unharmed through the fight and the flee (got %s)" % guard_health_after)

## Two fresh runs of the same seed, through the same scripted sequence
## (AGENTS.md's simulation rules: injected seeded randomness, no wall-clock/
## global RNG), must reach the wolf adjacent to the door in the same number of
## ticks and hash identically throughout, including the day-6 draw itself, the
## lingering hand-off, the fight, and the flee.
func _check_same_seed_reproduces_identical_hash() -> void:
	if _failed: return
	var world_a := _build_wolf_attack_world(SEED)
	var world_b := _build_wolf_attack_world(SEED)
	var ids_a := _draw_wolf_attack_naturally_away_from_door(world_a)
	var ids_b := _draw_wolf_attack_naturally_away_from_door(world_b)
	_expect(ids_a == ids_b and ids_a.size() == 1, "the same seed must propose the identical wolf actor id")
	if ids_a.size() != 1 or ids_b.size() != 1: return
	var wolf_id := String(ids_a[0])
	_expect(world_a.state_hash() == world_b.state_hash(), "the same seed must reproduce the same state hash immediately after the draw")

	var arrived_a := _tick_until(world_a, func(w: WorldStateType) -> bool: return _actor_pos(w, wolf_id) == NEAR_DOOR_TILE, ARRIVAL_TICK_BUDGET)
	var arrived_b := _tick_until(world_b, func(w: WorldStateType) -> bool: return _actor_pos(w, wolf_id) == NEAR_DOOR_TILE, ARRIVAL_TICK_BUDGET)
	_expect(arrived_a >= 0 and arrived_a == arrived_b, "the same seed must reach the door in the identical number of ticks (got %d vs %d)" % [arrived_a, arrived_b])
	_expect(world_a.state_hash() == world_b.state_hash(), "the same seed must reproduce the same state_hash() once the wolf reaches the door")

	for i in ATTACK_OBSERVE_TICKS:
		world_a.tick()
		world_b.tick()
		_expect(world_a.state_hash() == world_b.state_hash(),
			"two runs of the same seed must produce identical state_hash() during the fight (tick %d)" % world_a.get_tick())

	world_a._find_colonist(wolf_id)["health"]["hp"] = 5
	world_b._find_colonist(wolf_id)["health"]["hp"] = 5
	for i in FLEE_TICK_BUDGET:
		world_a.tick()
		world_b.tick()
		_expect(world_a.state_hash() == world_b.state_hash(),
			"two runs of the same seed must produce identical state_hash() while fleeing (tick %d)" % world_a.get_tick())
