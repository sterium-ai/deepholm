extends SceneTree

const WorldStateType = preload("res://scripts/core/world_state.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")

var _failed := false

func _init() -> void:
	_check_initialization()
	_check_snapshot_isolation()
	_check_rejections()
	_check_dig_and_chop_targets()
	_check_tick_advancement()
	_check_event_ordering()
	_check_replay_determinism()
	_check_incident_replay_determinism()
	_check_incidents_disabled_matches_pre_incident_baseline()
	_check_incident_scheduler_fields_affect_state_hash()
	_check_state_hash_distinguishes_dimensions()

	if _failed:
		quit(1)
		return
	print("test_world_state_determinism: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

## issue #299 round 1 review: two restored states with the same flattened
## tiles/entities but different rectangular dimensions (4x4 vs 2x8, both
## area 16) must report DIFFERENT state_hash() values -- width/height now
## govern tile indexing and simulation bounds, so a hash blind to them could
## alias two behaviorally distinct worlds together.
func _check_state_hash_distinguishes_dimensions() -> void:
	var world_a := StateCodecType.decode(_minimal_state_at_size(4, 4))
	var world_b := StateCodecType.decode(_minimal_state_at_size(2, 8))
	if world_a.get_tiles() != world_b.get_tiles():
		_fail("test fixture must give both worlds byte-identical flattened tile content")
		return
	if world_a.state_hash() == world_b.state_hash():
		_fail("state_hash() must distinguish equal-area maps with different dimensions (4x4 vs 2x8), both hashed to %d" % world_a.state_hash())

func _minimal_state_at_size(width: int, height: int) -> Dictionary:
	var tiles: Array = []
	tiles.resize(width * height)
	tiles.fill("soil")
	return {
		"schemaVersion": StateCodecType.SCHEMA_VERSION, "contentVersion": StateCodecType.content_version(),
		"seed": 1, "tick": 0, "epoch": 0,
		"map": {"width": width, "height": height, "tiles": tiles, "generatorVersion": WorldGeneratorType.GENERATOR_VERSION},
		"entities": [], "inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {}, "activatedEntries": {},
		},
		"rng": {"seed": 1, "state": 0},
		"items": {"nextId": 1, "list": []},
		"objects": [], "zones": [], "nextZoneId": 1, "groundBerries": [],
		"workProgress": [], "pausedJobs": [], "toolItems": {"nextId": 1, "list": []},
		"toolReservations": {}, "needJobAssignments": [], "calendarAlerts": {"fired": []},
		"toolFetchExcluded": [],
		"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1, "state": 0}},
	}

## Map, spawn, colonist, and empty-placeholder invariants at construction.
func _check_initialization() -> void:
	if _failed:
		return
	var world := WorldStateType.new(7, 10)

	var tiles := world.get_tiles()
	if tiles.size() != WorldStateType.MAP_WIDTH * WorldStateType.MAP_HEIGHT:
		_fail("expected %d tiles, found %d" % [WorldStateType.MAP_WIDTH * WorldStateType.MAP_HEIGHT, tiles.size()])
		return

	var valid_kinds := {
		WorldStateType.TILE_ROCK: true,
		WorldStateType.TILE_SOIL: true,
		WorldStateType.TILE_FLOOR: true,
		WorldStateType.TILE_HAZARD: true,
		WorldStateType.TILE_TREE: true,
		WorldStateType.TILE_WATER: true,
	}
	var found_tree := false
	for kind in tiles:
		if not valid_kinds.has(kind):
			_fail("unexpected tile kind '%s'" % kind)
			return
		if kind == WorldStateType.TILE_TREE:
			found_tree = true
	if not found_tree:
		_fail("expected at least one tree tile to be scattered")
		return

	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH:
			if world.get_tile(x, y) == WorldStateType.TILE_TREE and world._is_passable(Vector2i(x, y)) > 0.0:
				_fail("tree tile (%d,%d) must not be passable" % [x, y])
				return

	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH:
			if world.get_ground_wood(x, y) != 0:
				_fail("expected no ground wood at (%d,%d) on a freshly generated world" % [x, y])
				return

	# issue #300: the spawn clearing is chosen dynamically (river-aware,
	# resource-validated -- WorldGenerator.place_spawn(), docs/decisions/020),
	# not a fixed (2,2)-(8,8) rectangle, so this checks whatever clearing this
	# seed's search actually chose, via WorldState's own get_spawn_clearing().
	var clearing := world.get_spawn_clearing()
	for y in range(int(clearing["y"]), int(clearing["y"]) + int(clearing["height"])):
		for x in range(int(clearing["x"]), int(clearing["x"]) + int(clearing["width"])):
			if world.get_tile(x, y) != WorldStateType.TILE_FLOOR:
				_fail("spawn clearing tile (%d,%d) is not floor" % [x, y])
				return

	var colonists := world.get_colonists()
	if colonists.size() != WorldStateType.COLONIST_COUNT:
		_fail("expected %d colonists, found %d" % [WorldStateType.COLONIST_COUNT, colonists.size()])
		return
	for colonist in colonists:
		if world.get_tile(colonist["x"], colonist["y"]) != WorldStateType.TILE_FLOOR:
			_fail("colonist %s is not on a floor tile" % colonist["id"])
			return
		if colonist["route"] != null or colonist["work"] != null:
			_fail("colonist %s must spawn with null route and work" % colonist["id"])
			return
		var health: Dictionary = colonist["health"]
		if health["hp"] != health["maxHp"] or health["dead"] != false:
			_fail("colonist %s must spawn with hp == maxHp and dead == false, got %s" % [colonist["id"], health])
			return

	if world.get_jobs().size() != 0:
		_fail("jobs list is not empty at initialization")
		return
	if world.get_reservations().size() != 0:
		_fail("reservations table is not empty at initialization")
		return
	if world.get_tick() != 0:
		_fail("tick is not zero at initialization")
		return

## Mutating a get_*() return value must never affect WorldState's own state.
func _check_snapshot_isolation() -> void:
	if _failed:
		return
	var world := WorldStateType.new(11, 10)

	var tiles := world.get_tiles()
	tiles[0] = "mutated"
	if world.get_tile(0, 0) == "mutated":
		_fail("mutating get_tiles() result affected world state")
		return

	var colonists := world.get_colonists()
	if colonists.size() == 0:
		_fail("expected at least one colonist for isolation check")
		return
	colonists[0]["x"] = -1
	if world.get_colonists()[0]["x"] == -1:
		_fail("mutating get_colonists() result affected world state")
		return

	var jobs := world.get_jobs()
	jobs.append({"bogus": true})
	if world.get_jobs().size() != 0:
		_fail("mutating get_jobs() result affected world state")
		return

	var reservations := world.get_reservations()
	reservations["bogus"] = true
	if world.get_reservations().size() != 0:
		_fail("mutating get_reservations() result affected world state")
		return

	world.apply({"actor": "colonist_0", "command_id": "iso_1", "tick": 0, "type": "noop", "payload": {}})
	var events := world.get_events()
	var original_count := events.size()
	events.append({"bogus": true})
	events[0]["type"] = "mutated"
	if world.get_events().size() != original_count:
		_fail("mutating get_events() result affected world state")
		return
	if world.get_events()[0]["type"] == "mutated":
		_fail("mutating a get_events() entry affected world state")
		return

## Every rejection category, plus a successful noop application.
func _check_rejections() -> void:
	if _failed:
		return
	var world := WorldStateType.new(4242, 10)

	var result: Dictionary = world.apply("not a dictionary")
	if result["ok"] or result["rejection"]["reason"] != "invalid_envelope":
		_fail("expected invalid_envelope rejection for a non-dictionary command")
		return

	result = world.apply({"command_id": "c1", "tick": 0, "type": "noop", "payload": {}})
	if result["ok"] or result["rejection"]["reason"] != "invalid_envelope":
		_fail("expected invalid_envelope rejection for a missing actor")
		return

	result = world.apply({"actor": "colonist_0", "tick": 0, "type": "noop", "payload": {}})
	if result["ok"] or result["rejection"]["reason"] != "invalid_envelope":
		_fail("expected invalid_envelope rejection for a missing command_id")
		return

	result = world.apply({"actor": "colonist_0", "command_id": "c2", "type": "noop", "payload": {}})
	if result["ok"] or result["rejection"]["reason"] != "invalid_envelope":
		_fail("expected invalid_envelope rejection for a missing tick")
		return

	result = world.apply({"actor": "colonist_0", "command_id": "c3", "tick": 0, "payload": {}})
	if result["ok"] or result["rejection"]["reason"] != "invalid_envelope":
		_fail("expected invalid_envelope rejection for a missing type")
		return

	result = world.apply({"actor": "colonist_0", "command_id": "c4", "tick": 0, "type": "noop"})
	if result["ok"] or result["rejection"]["reason"] != "invalid_envelope":
		_fail("expected invalid_envelope rejection for a missing payload")
		return

	result = world.apply({"actor": "colonist_0", "command_id": "c5", "tick": 0, "type": "noop", "payload": {"bad": 1.5}})
	if result["ok"] or result["rejection"]["reason"] != "invalid_payload":
		_fail("expected invalid_payload rejection for a float payload value")
		return

	result = world.apply({"actor": "colonist_0", "command_id": "c6", "tick": 5, "type": "noop", "payload": {}})
	if result["ok"] or result["rejection"]["reason"] != "tick_mismatch":
		_fail("expected tick_mismatch rejection for a wrong tick")
		return

	result = world.apply({"actor": "colonist_0", "command_id": "c7", "tick": 0, "type": "explode", "payload": {}})
	if result["ok"] or result["rejection"]["reason"] != "unknown_command_type":
		_fail("expected unknown_command_type rejection for an unhandled type")
		return

	result = world.apply({"actor": "colonist_0", "command_id": "c8", "tick": 0, "type": "noop", "payload": {"note": "hi", "count": 3}})
	if not result["ok"] or result["applied"]["command_id"] != "c8" or result["applied"]["tick"] != 0:
		_fail("expected the noop command to be applied successfully")
		return

func _job_command(world: WorldStateType, command_id: String, kind: String, target: Vector2i) -> Dictionary:
	return world.apply({"actor": "colonist_0", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": {"x": target.x, "y": target.y}})

func _check_dig_and_chop_targets() -> void:
	if _failed:
		return
	var world := WorldStateType.new(123, 10)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	world._tiles[world._tile_index(1, 1)] = WorldStateType.TILE_SOIL
	world._tiles[world._tile_index(2, 1)] = WorldStateType.TILE_TREE
	world._tiles[world._tile_index(3, 1)] = WorldStateType.TILE_FLOOR
	for target in [Vector2i(1, 1), Vector2i(0, 0), Vector2i(3, 1)]:
		var chop_result := _job_command(world, "chop_invalid_%d_%d" % [target.x, target.y], "chop", target)
		if chop_result["ok"] or chop_result["rejection"]["reason"] != "invalid_target":
			_fail("chop on non-tree tile must reject invalid_target")
			return
		if target == Vector2i(1, 1) and chop_result["rejection"]["message"] != "Choose a tree tile within the map.":
			_fail("chop rejection must explain that a tree tile is required")
			return
	for target in [Vector2i(2, 1), Vector2i(0, 0), Vector2i(3, 1)]:
		var dig_result := _job_command(world, "dig_invalid_%d_%d" % [target.x, target.y], "dig", target)
		if dig_result["ok"] or dig_result["rejection"]["reason"] != "invalid_target":
			_fail("dig on non-soil tile must reject invalid_target")
			return
	var chop_result := _job_command(world, "chop_unreachable", "chop", Vector2i(2, 1))
	if not chop_result["ok"]:
		_fail("chop on a tree tile must be accepted")
		return
	world.tick()
	var jobs := world.get_jobs()
	if jobs.size() != 1 or jobs[0]["kind"] != "chop":
		_fail("accepted chop must create a chop job")
		return
	if jobs[0]["reason"] != "blocked_target_unreachable" or jobs[0]["remedy"] != "restore_target_access":
		_fail("unreachable chop must expose the standard unreachable reason and remedy")

## tick() advances exactly one tick per call.
func _check_tick_advancement() -> void:
	if _failed:
		return
	var world := WorldStateType.new(99, 10)
	if world.get_tick() != 0:
		_fail("expected the initial tick to be zero")
		return
	world.tick()
	if world.get_tick() != 1:
		_fail("expected tick() to advance exactly one tick")
		return
	world.tick()
	world.tick()
	if world.get_tick() != 3:
		_fail("expected three tick() calls to reach tick 3")
		return

## Events sort by (tick, system_priority, entity_id, sequence).
func _check_event_ordering() -> void:
	if _failed:
		return
	var world := WorldStateType.new(555, 10)
	world.apply({"actor": "colonist_b", "command_id": "e1", "tick": 0, "type": "noop", "payload": {}})
	world.apply({"actor": "colonist_a", "command_id": "e2", "tick": 0, "type": "noop", "payload": {}})
	world.apply({"actor": "colonist_a", "command_id": "e3", "tick": 0, "type": "unknown", "payload": {}})
	world.tick()
	world.apply({"actor": "colonist_a", "command_id": "e4", "tick": 1, "type": "noop", "payload": {}})
	world.tick()

	var events := world.get_events()
	if events.size() == 0:
		_fail("expected events to be recorded")
		return
	for i in range(1, events.size()):
		var previous: Dictionary = events[i - 1]
		var current: Dictionary = events[i]
		if not _is_event_order_valid(previous, current):
			_fail("events out of order at index %d: %s then %s" % [i, previous, current])
			return

## Mirrors WorldState's private ordering key: tick, system_priority, entity_id, sequence.
func _is_event_order_valid(previous: Dictionary, current: Dictionary) -> bool:
	if previous["tick"] != current["tick"]:
		return previous["tick"] < current["tick"]
	if previous["system_priority"] != current["system_priority"]:
		return previous["system_priority"] < current["system_priority"]
	if previous["entity_id"] != current["entity_id"]:
		return previous["entity_id"] < current["entity_id"]
	return previous["sequence"] < current["sequence"]

## Two identically-seeded WorldStates replaying the same command/tick
## sequence must produce equal apply() results, state_hash(), and events.
func _check_replay_determinism() -> void:
	if _failed:
		return
	var seed_value := 20260915
	var first := WorldStateType.new(seed_value, 10)
	var second := WorldStateType.new(seed_value, 10)

	var command_batches := [
		[
			{"actor": "colonist_0", "command_id": "cmd_1", "tick": 0, "type": "noop", "payload": {"note": "hello", "count": 1}},
			{"actor": "colonist_1", "command_id": "cmd_2", "tick": 0, "type": "noop", "payload": {}},
		],
		[
			{"actor": "colonist_2", "command_id": "cmd_3", "tick": 1, "type": "noop", "payload": {"phase": "two"}},
			{"actor": "colonist_0", "command_id": "cmd_4", "tick": 1, "type": "explode", "payload": {}},
			{"actor": "colonist_1", "command_id": "cmd_5", "tick": 5, "type": "noop", "payload": {}},
		],
	]

	for batch in command_batches:
		for command in batch:
			var first_result := first.apply(command)
			var second_result := second.apply(command)
			if first_result != second_result:
				_fail("apply() results diverged for command %s" % command)
				return
		first.tick()
		second.tick()

	if first.state_hash() != second.state_hash():
		_fail("state_hash() diverged: %s vs %s" % [first.state_hash(), second.state_hash()])
		return

	if first.get_events() != second.get_events():
		_fail("event logs diverged")
		return

## F5/#295 determinism proof (objective #277 acceptance item 4): two
## identically-seeded worlds with incidents enabled, ticked far enough to
## cross incidents.json's min_day gates (3, 5) and actually draw/spawn, must
## reach the same state_hash() and event log -- proving IncidentScheduler's
## own RNG stream, cooldowns, and last-processed day are all fully
## deterministic and fully covered by state_hash() (ADR 004).
## IncidentScheduler.advance() draws once per in-game calendar day
## (CalendarService.day_of_tick()); issue #349/ADR 023 grew day_length_ticks
## from 100 to 2200 (22x), so the tick budget needed to cross min_day 3 (day 3
## starts at tick 2 * day_length_ticks = 4400) is scaled by the same factor
## the day length grew by, keeping the original ~6.5-day margin past min_day 5.
const INCIDENT_REPLAY_TICK_BUDGET := 14300
func _check_incident_replay_determinism() -> void:
	if _failed:
		return
	var seed_value := 20260921
	var first := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	var second := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	for _i in INCIDENT_REPLAY_TICK_BUDGET:
		first.tick()
		second.tick()
	var incident_events := 0
	for event in first.get_events():
		if String(event.get("type", "")) == "incident_started":
			incident_events += 1
	if incident_events == 0:
		_fail("expected at least one incident_started event to actually exercise the incident RNG stream")
		return
	if first.state_hash() != second.state_hash():
		_fail("incident-enabled state_hash() diverged: %s vs %s" % [first.state_hash(), second.state_hash()])
		return
	if first.get_events() != second.get_events():
		_fail("incident-enabled event logs diverged")

## F5/#295: an incidents-disabled world's own IncidentScheduler never draws
## (advance()/_run_daily_draw() are a true no-op while disabled), so its
## cooldowns/last-processed-day/RNG stay at their exact freshly-constructed
## values through many ticks. Two separately constructed disabled worlds of
## the same seed reproducing the same full state_hash() only proves
## repeatability of THIS implementation; the actual pre-incident-baseline
## proof is PRE_INCIDENT_BASELINE_HASH below, an independent literal captured
## with Godot from this exact world/scenario's colony-only projection
## (state_hash(false)) -- byte-identical to what state_hash() itself computed
## before issue #295 added any incident field to it, since state_hash(false)
## never includes cooldownUntilDay/lastProcessedDay/rng. Matching that fixed
## literal, plus the colony's own RNG stream staying in lockstep between the
## two runs, is what confirms the incident RNG stream never touches the
## colony's own sequence -- not merely that two new-implementation runs agree
## with each other.
## Issue #302: colonist now carries a real "combat" component
## (content/actors.json), backfilled by WorldState._ensure_combat() the
## first tick any colonist exists, plus state_hash() including
## world._object_health (round-3 review: a wall/door's accumulated damage
## must be hash-visible) and CombatGiver's own excluded-flee-destination set
## (round-6 review, second pass: `_blocked_targets` affects the very next
## flee-destination pick, so a save/load or a determinism comparison that
## differs only in it must not hash equal) -- each a genuine, intentional
## shape change to the same snapshot dict, present even for a colony-only
## world with no combat/damage/flee activity since each new key itself
## changes the dict shape.
## Re-captured for issue #300 (world_generator.gd's own GENERATOR_VERSION
## bump to 2): the prior literal was pinned to #299's independent-per-tile
## water scatter, which this task replaces with the main-river/correlated-
## vegetation algorithm, so seed 20260922's terrain (and therefore this
## colony-only projection) changed even at the 48x48 reference size.
## Re-captured again for issue #300 round 1 revision (world_state.gd's own
## _generate_map()/_spawn_colonists() now consume their own GEOGRAPHY_SEED_
## SALT/PLACEMENT_SEED_SALT-derived local RNGs instead of _random, so seed
## 20260922's terrain/spawn positions -- and therefore this projection --
## changed again, though _random's own post-construction state is now the
## simulation-stream invariant test_river_generation.gd's own
## _check_generation_does_not_perturb_simulation_stream() asserts). Value
## captured via this exact test run in this sandbox with Godot 4.7.2.
## Re-captured for issue #349/ADR 023 (needs.json's per-tick "rate" replaced
## by per-day "rate_per_day", applied through a new persisted per-colonist
## "needsAccumulator" field): both the decay trajectory and the hashed
## colonist shape changed, so this literal moved even though the scenario's
## own seed/tiles/tick count did not.
## Re-captured for issue #351/#347 (world_generator.gd's own GENERATOR_VERSION
## bump to 3): grown compact rock outcrops are a new terrain-shaping pass, and
## place_spawn()'s anchor scoring now also requires outcrop reachability, so
## seed 20260922's terrain/spawn positions -- and therefore this colony-only
## projection -- changed again even at the 48x48 reference size. Value
## captured via this exact test run in this sandbox with Godot 4.7.2.
## Re-captured for issue #351/#347 round 1 revision (world_generator.gd's own
## _scatter_rock_outcrops() now draws from a private OUTCROP_SEED_SALT-derived
## substream instead of the shared `random` stream, so the outcrop pass never
## shifts every other pass's draws -- see that function's own doc comment):
## seed 20260922's rock-outcrop tile positions changed again, though every
## other terrain feature this projection also depends on did not.
## Re-captured for issue #358 round 2 review (ADR 025 amendment): state_hash()
## now also includes world._dig_find_random's own seed/state (dig's find-roll
## RNG continuation, now persisted through save/load), unconditionally rather
## than gated by include_incidents -- a pure snapshot-shape change, not a
## colony-behavior change, but it still moves this colony-only projection.
## Re-captured for issue #359 (ADR 025 t3): every colonist's snapshot now
## also carries a "trapped" field. Re-captured once more to merge the #302
## combat-shape change onto this same snapshot dict. Re-captured once more for
## issue #278/#303 round 6 (second pass): state_hash() now also includes
## world._suspended_work_progress (a suspended job's own progress affects what
## happens the moment it resumes, so two states differing only in it must not
## hash equal) -- a pure snapshot-shape change (an empty array here), not a
## colony-behavior change, but it still moves this projection.
## Re-captured for issue #360 (ADR 025 t4, rescue_giver.gd): state_hash() now
## also includes RescueGiver's own job_id -> victim_id association
## ("rescue_victim_assignments"), unconditionally like the dig-find RNG
## stream above -- always empty here (this scenario never traps a colonist),
## but the new key itself still changes the dict shape this projection hashes
## over. Re-captured once more for #360's round-4 review (finding 3): that
## field is now hashed in state_codec.gd's own sorted {jobId, victimId} array
## encoding (an empty Array here) instead of the raw Dictionary, so identical
## associations restored in a different insertion order hash identically.
## Merging issue #360 onto origin/main (both the #278/#303 suspended-work-
## progress addition and the rescue-victim-assignments field landing together
## for the first time) moved this literal once more -- a pure combined
## snapshot-shape change. Value captured via this exact test run in this
## sandbox with Godot 4.7.2, per AGENTS.md's "never hand-derive a hash" rule.
## Re-captured for issue #390 (ADR 031, ApproachGiver): state_hash() now also
## includes ApproachGiver's own job_id -> target association
## ("approach_job_targets"), unconditionally like rescue's own association
## above -- always empty here (this colony-only scenario never spawns a
## hostile actor), but the new key itself still changes the dict shape this
## projection hashes over. Re-captured again for issue #391: ApproachGiver no
## longer retires an actor permanently (see approach_giver.gd's own class doc
## comment), so state_hash() drops the now-meaningless "approach_retired_actors"
## key it briefly carried (ADR 031 round-2 review finding 2) -- the dict shape
## moves again, even though the key was always empty in this colony-only
## scenario. Re-captured for issue #402 (ADR 035): a colonist's single-slot
## "carrying" field becomes "hands", a list instead of a nullable object --
## a pure snapshot-shape change (empty here, since this scenario never has a
## colonist carrying anything), not a colony-behavior change, but it still
## moves this projection. Value captured via this exact test run in this
## sandbox with Godot 4.7.2.
## Re-captured for issue #406 (ADR 038): state_hash() now also includes
## "construction_sites" (ConstructionSiteTable.list()), unconditionally like
## every other giver's own association above -- always empty here (this
## colony-only scenario never issues a `build` command), but the new key
## itself still changes the dict shape this projection hashes over. Value
## captured via this exact test run in this sandbox with Godot 4.7.2.
const PRE_INCIDENT_BASELINE_HASH := 1196647028

func _check_incidents_disabled_matches_pre_incident_baseline() -> void:
	if _failed:
		return
	var seed_value := 20260922
	var world := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, false)
	var initial_cooldowns: Dictionary = world._incidents._cooldown_until_day.duplicate()
	var initial_day: int = world._incidents._last_processed_day
	var initial_rng_seed: int = world._incidents._random.seed
	var initial_rng_state: int = world._incidents._random.state
	var reference := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, false)
	for _i in 650:
		world.tick()
		reference.tick()
	if world._incidents._cooldown_until_day != initial_cooldowns:
		_fail("an incidents-disabled world must never populate incident cooldowns")
		return
	if world._incidents._last_processed_day != initial_day:
		_fail("an incidents-disabled world must never advance its last-processed day")
		return
	if world._incidents._random.seed != initial_rng_seed or world._incidents._random.state != initial_rng_state:
		_fail("an incidents-disabled world must never draw from its own incident RNG stream")
		return
	if world.state_hash() != reference.state_hash():
		_fail("two incidents-disabled runs of the same seed must reproduce the identical (pre-incident-baseline) state_hash()")
		return
	if world.state_hash(false) != PRE_INCIDENT_BASELINE_HASH:
		_fail("an incidents-disabled world's colony-only projection must match the independent pre-incident baseline (got %d, expected %d)" % [world.state_hash(false), PRE_INCIDENT_BASELINE_HASH])
		return
	if world._random.seed != reference._random.seed or world._random.state != reference._random.state:
		_fail("disabling incidents must never desynchronize the colony's own RNG stream between two otherwise-identical runs")

## F5/#295 review round 1: state_hash() must be sensitive to each persisted
## IncidentScheduler field independently -- proving ADR 004's "WorldState's
## diagnostic hash includes this continuation state" actually holds for
## cooldownUntilDay, lastProcessedDay and rng, not merely that an "incidents"
## key exists in the snapshot.
func _check_incident_scheduler_fields_affect_state_hash() -> void:
	if _failed:
		return
	var seed_value := 20260924
	var base_hash: int = WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true).state_hash()

	var cooldown_world := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	cooldown_world._incidents._cooldown_until_day["wildlife_wander"] = 99
	if cooldown_world.state_hash() == base_hash:
		_fail("state_hash() must change when cooldown_until_day changes")

	var day_world := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	day_world._incidents._last_processed_day = 7
	if day_world.state_hash() == base_hash:
		_fail("state_hash() must change when last_processed_day changes")

	var rng_seed_world := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	rng_seed_world._incidents._random.seed += 1
	if rng_seed_world.state_hash() == base_hash:
		_fail("state_hash() must change when the incident RNG stream's seed changes")

	var rng_state_world := WorldStateType.new(seed_value, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	rng_state_world._incidents._random.randi()
	if rng_state_world.state_hash() == base_hash:
		_fail("state_hash() must change when the incident RNG stream's state changes")
