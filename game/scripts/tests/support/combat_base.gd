extends SceneTree

## Shared header, helpers and members of the test_combat* checks (split by subject in R15);
## the checks themselves live in the test_combat*.gd files that extend this script.

## F5 combat resolution (ADR 021): headless, no-scene proof of the
## generic combat rules using two synthetic fixture actors in opposing
## factions (colony vs raiders, both already mutually hostile per
## content/factions.json) -- independent of wolf/trader content. Covers: damage
## lands every `cooldown` ticks, not every tick; death at hp 0 drops inventory
## as loose items and removes the actor from scheduling; a wall reduced to hp 0
## clears to no object; an actor at/below its own flee_hp_fraction stops
## fighting and starts a `flee` job that actually moves it; and two fresh runs
## of the same seed produce identical state hashes (determinism, AGENTS.md's
## simulation rules).

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const WorkerType = preload("res://scripts/core/actors/components/worker.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const SAVE_WRITE_FLEE_DIR := "user://test-combat-save-write-flee"

const TICK_RATE := 10

var _failed := false

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Every reservation key must belong to an active job:
## the same invariant test_build.gd/test_haul_stockpile.gd/test_rescue.gd
## already check, called after every tick in the new retarget/fallback checks
## below so a mid-run leak (not just an end-state one) is caught too.
func _assert_no_orphaned_reservations(world: WorldStateType, context: String) -> void:
	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		TestAccess.scheduler(world).queue.get_reservation_table(), world.get_jobs())
	_expect(orphans.is_empty(), "no reservation may outlive its job (%s): orphans=%s" % [context, orphans])

## An all-floor, colonist-free world: a controlled arena for fixture actors,
## mirroring test_incidents.gd's own _build_arena() helper.
## A freshly generated world can place berry_bush
## objects (ADR 020); a leftover one would silently block a
## fixture's own hand-placed walls/doors or flee paths, exactly like
## test_incidents.gd's own _build_controlled_world()/_build_pocket_world()
## already guard against.
func _build_arena(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, TICK_RATE, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, false)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	TestAccess.colonists(world).clear()
	return world

## A "colonist"-def actor under an arbitrary faction -- reusing the existing
## colonist definition (which has a `combat` component) rather than
## adding new species content.
func _spawn_actor(world: WorldStateType, faction_id: String, actor_id: String, x: int, y: int) -> Dictionary:
	var actor := ActorTableType.spawn("colonist", Vector3i(x, y, 0), TestAccess.content(world), actor_id)
	# ActorTable.spawn() still literally builds the legacy single-slot
	# "carrying" field; mirror WorldState._spawn_colonists()'s own post-spawn
	# patch to the hands model.
	actor.erase("carrying")
	actor["hands"] = []
	actor["factionId"] = faction_id
	TestAccess.append_colonist(world, actor)
	return actor

## Colony vs raiders (content/factions.json: mutually "hostile") locked
## adjacent at (5,5)/(6,5), with one tick already run so both carry a
## backfilled "combat"/"health" component (WorldState._ensure_combat()).
func _build_fighters(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	_spawn_actor(world, "colony", "fighter_a", 5, 5)
	_spawn_actor(world, "raiders", "fighter_b", 6, 5)
	world.tick()
	return world

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

func _build_combat_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	_spawn_actor(world, "colony", "det_a", 5, 5)
	_spawn_actor(world, "raiders", "det_b", 6, 5)
	TestAccess.object_table(world).set_object(Vector3i(7, 5, 0), "wooden_wall")
	return world

## RegionMap.reachable() (region_map.gd -- err, regions.gd:
## "Physical passability only -- no faction awareness") always evaluates door
## passability under the default "colony" faction, so it reports the whole
## map one connected region even across a door a hostile faction cannot pass
## -- a gap the coarse pre-submission check in _pick_flee_target() cannot see
## through. A full-height wall at x=14 (every row except the door itself at
## y=10) leaves the door as the only crossing between the raider's own west
## side and the entire east side -- not just its single preferred candidate,
## since an open arena would otherwise let the real route search simply walk
## around a lone door tile, proving nothing about faction blocking. The real
## per-tick route search (faction-aware) can never find a path past it, so
## every east-pointing candidate this actor tries repeatedly ends up
## blocked_target_unreachable while queued -- proving advance()'s cancel-and-
## exclude fix keeps trying different candidates (never looping on the same
## doomed tile, or a small fixed set of them, forever) until it reaches a
## direction that never needed the door at all.
## Shared fixture (second pass): the raider "prey" can only
## escape east through a single door its own faction may not pass
## (content/factions.json: raiders may_pass_doors=false), full-height walls
## on every other row of x=14 forcing every east-pointing candidate past x=14
## to repeatedly hit blocked_target_unreachable while queued. Factored out of
## _check_flee_target_excludes_faction_blocked_door() so
## _check_flee_blocked_targets_survive_save_load_and_match_uninterrupted()
## below can build two byte-identical worlds from the same setup.
func _build_faction_blocked_door_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	_spawn_actor(world, "colony", "hunter", 10, 10)
	_spawn_actor(world, "raiders", "prey", 11, 10) # threat directly west -- "away" ray points due east
	for y in WorldStateType.MAP_HEIGHT:
		if y == 10:
			continue
		TestAccess.object_table(world).set_object(Vector3i(14, y, 0), "wooden_wall")
	TestAccess.object_table(world).set_object(Vector3i(14, 10, 0), "door")
	world.tick() # backfills "combat" before a caller mutates it
	return world

## A synthetic incident actor (a "colonist"-def actor staged/spawned through
## IncidentScheduler.propose(), never a wolf/trader -- this file's own
## established convention) under a hostile faction, so it carries the
## `combat`/`flee_hp_fraction` component real wolf/trader content does not
## (flee_hp_fraction is colonist-only; there is no wolf/trader-specific data).
func _make_incident_actor(world: WorldStateType, actor_id: String, x: int, y: int) -> Dictionary:
	var actor := ActorTableType.spawn("colonist", Vector3i(x, y, 0), TestAccess.content(world), actor_id)
	actor.erase("carrying")
	actor["hands"] = []
	actor["factionId"] = "raiders"
	return actor

## The non-terminal `flee` job restricted to actor_id, or the most recently
## submitted one when none is non-terminal (empty when there never was one).
func _flee_job_of(world: WorldStateType, actor_id: String) -> Dictionary:
	var latest: Dictionary = {}
	for job in world.get_jobs():
		if String(job.get("kind", "")) != "flee" or TestAccess.job_restricted_to(world, String(job["id"])) != actor_id:
			continue
		if String(job.get("status", "")) in ["queued", "active"]:
			return job
		latest = job
	return latest

## --- Interrupt/resume ownership boundary -----------------------------------

## --- Faction-aware routing across save/load --------------------------------

## Shared by the active-reroute check below: a raider "prey" walks a short
## direct row (y=0, x=10..15) toward its own first flee candidate; the loop
## around it (left/right columns, bottom row) is its only detour once that
## row is walled mid-walk, and a door blocks the loop's own reconnection back
## to the row -- impassable to the raider's own faction (content/factions.json:
## raiders may_pass_doors=false) but not to colony, so a colony-default
## restore of an in-flight reroute would find a path the raider's own live
## search never could. The loop is ~100 tiles -- over RouteSearch.STEP_BUDGET
## (64) -- so the forced reroute stays genuinely STATUS_SEARCHING for more
## than one tick.
func _build_flee_racetrack_door_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(10, 16):
		TestAccess.set_tile(world, x, 0, WorldStateType.TILE_FLOOR)
	for y in range(0, WorldStateType.MAP_HEIGHT):
		TestAccess.set_tile(world, 10, y, WorldStateType.TILE_FLOOR)
		TestAccess.set_tile(world, 15, y, WorldStateType.TILE_FLOOR)
	for x in range(10, 16):
		TestAccess.set_tile(world, x, WorldStateType.MAP_HEIGHT - 1, WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).set_object(Vector3i(15, 1, 0), "door")
	_spawn_actor(world, "colony", "hunter", 10, 0)
	_spawn_actor(world, "raiders", "prey", 11, 0)
	world.tick() # backfills "combat" before a caller mutates it
	return world

## --- Need/combat/incident lifecycle gaps -----------------------------------

## ADR 033: a full-height wall at x=10 except a
## single colony door at y=24 leaves the door as the wolf's only crossing
## toward the villager beyond it -- mirrors _build_faction_blocked_door_world()'s
## own "one door, everything else walled" shape. `wolf` (content/actors.json)
## is reused as a fixture only, spawned directly like every other
## fixture actor in this file rather than through IncidentScheduler, so its
## own lifetime is not tied to any incident job.
func _build_wolf_door_world(seed_value: int) -> WorldStateType:
	var world := _build_arena(seed_value)
	for y in WorldStateType.MAP_HEIGHT:
		if y == 24:
			continue
		TestAccess.object_table(world).set_object(Vector3i(10, y, 0), "wooden_wall")
	TestAccess.object_table(world).set_object(Vector3i(10, 24, 0), "door")
	var wolf := ActorTableType.spawn("wolf", Vector3i(0, 24, 0), TestAccess.content(world), "wolf_1")
	wolf["factionId"] = "wildlife"
	TestAccess.append_colonist(world, wolf)
	_spawn_actor(world, "colony", "villager", 11, 24)
	return world

## The non-terminal `approach` job restricted to actor_id, or the most
## recently submitted one when none is non-terminal (empty when there never
## was one) -- mirrors _flee_job_of().
func _approach_job_of(world: WorldStateType, actor_id: String) -> Dictionary:
	var latest: Dictionary = {}
	for job in world.get_jobs():
		if String(job.get("kind", "")) != "approach" or TestAccess.job_restricted_to(world, String(job["id"])) != actor_id:
			continue
		if String(job.get("status", "")) in ["queued", "active"]:
			return job
		latest = job
	return latest
