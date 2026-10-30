extends SceneTree

## Shared header, helpers and members of the test_rescue* checks (split by subject in R15);
## the checks themselves live in the test_rescue*.gd files that extend this script.

## ADR 026: rescue_giver.gd, the job-giver that frees a
## trapped colonist. Exercises RescueGiver through real gameplay -- tripping a
## colonist into a trench, ticking the world -- never by calling private
## rescue methods directly, so the whole search -> commit -> route -> work ->
## completion pipeline is proven end to end.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const TRAP_TICK_BOUND := 100
const RESCUE_TICK_BOUND := 200

var _failed := false

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A world with a single colonist ("colonist_0") on an all-floor map, mirroring
## test_trapped_actors.gd's own _fresh_world() (a complete needs/health/labour
## shape, so state_hash()'s own rebuild never orphans a live "trapped"
## reference this file holds across many world.tick() calls).
func _fresh_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "z": 0, "factionId": "colony",
		"needs": {"food": 100, "water": 100, "rest": 100},
		"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
		"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
		"route": null, "work": null, "hands": [], "held_tool": "",
		"health": {"hp": 100, "maxHp": 100, "dead": false}})
	return world

func _spawn_colonist(world: WorldStateType, id: String, x: int, y: int) -> Dictionary:
	var colonist: Dictionary = ActorTableType.spawn("colonist", Vector3i(x, y, 0), TestAccess.content(world), id)
	colonist.erase("carrying")
	colonist["hands"] = []
	colonist["factionId"] = "colony"
	TestAccess.append_colonist(world, colonist)
	return colonist

## The two-victim recipe (victim A trapped at (1, 0), victim B walking from
## (6, 0) to (2, 0) over its own trench at (3, 0)) needs B never to be picked
## as A's rescuer on the way. Before A8 that held only because the rescue
## search restarted every time B moved and could not finish between steps;
## A* (ADR 054: "a long walk costs a few hundred tile checks instead of
## fifteen thousand") finishes it in one tick. Rock on row y = 1 from x = 3
## east leaves B only routes that cross a trench, which the rescue safety
## check always rejects, so the setup no longer depends on search speed.
## Raw tile writes: the caches and region/room maps are rebuilt.
func _fence_victim_b_lane(world: WorldStateType) -> void:
	for x in range(3, TestAccess.tile_grid(world).width):
		TestAccess.set_tile(world, x, 1, WorldStateType.TILE_ROCK)
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.tile_grid(world).regions = null
	TestAccess.tile_grid(world).rooms = null

func _tick_until_trapped(world: WorldStateType, colonist: Dictionary, bound: int) -> bool:
	for _i in bound:
		world.tick()
		if colonist.get("trapped") != null:
			return true
	return false

func _find_rescue_job(world: WorldStateType, restrict_to_worker: String = "") -> Dictionary:
	for job in world.get_jobs():
		if String(job.get("kind", "")) != "rescue":
			continue
		if restrict_to_worker.is_empty() or TestAccess.rescue_giver(world).colonist_for_job(String(job["id"])) == restrict_to_worker:
			return job
	return {}

## Ticks until job_id is "active" (bounded). A rescue commits after the
## scheduler's own tick (rescue_giver.gd, "Route budget"), so its activation
## -- and with it the activation-gated trapped:<victim_id> key -- lands on a
## later tick than the one the job first appears on.
func _tick_until_job_active(world: WorldStateType, job_id: String, bound: int) -> bool:
	for _i in bound:
		if String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "active":
			return true
		world.tick()
	return String(TestAccess.scheduler(world).queue.get_job(job_id).get("status", "")) == "active"

## Traps colonist_0 at (1, 0) the same way test_trapped_actors.gd's own first
## check does: a till job whose only route crosses the trench tile.
func _trap_colonist_0(world: WorldStateType) -> void:
	TestAccess.set_tile(world, 1, 0, WorldStateType.TILE_TRENCH)
	TestAccess.set_tile(world, 2, 0, WorldStateType.TILE_SOIL)
	var colonist: Dictionary = TestAccess.colonists(world)[0]
	var submit := TestAccess.scheduler(world).submit(Vector3i(2, 0, 0), 1, world.get_tick(), "till", String(colonist["id"]))
	_expect(submit.get("ok", false), "setup: till submission must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: colonist_0 must become trapped")

## Traps `colonist` at an arbitrary `trench` tile: places it one step west,
## and submits a till job one step east, so its only route crosses `trench`
## directly -- the same recipe _trap_colonist_0() uses, generalized to any
## tile for the route-safety checks below, which need the trench somewhere
## other than (1, 0).
func _trap_colonist_at(world: WorldStateType, colonist: Dictionary, trench: Vector3i) -> void:
	colonist["x"] = trench.x - 1
	colonist["y"] = trench.y
	TestAccess.set_tile(world, trench.x, trench.y, WorldStateType.TILE_TRENCH)
	TestAccess.set_tile(world, trench.x + 1, trench.y, WorldStateType.TILE_SOIL)
	var submit := TestAccess.scheduler(world).submit(Vector3i(trench.x + 1, trench.y, 0), 1, world.get_tick(), "till", String(colonist["id"]))
	_expect(submit.get("ok", false), "setup: till submission for the custom trap must be accepted")
	_expect(_tick_until_trapped(world, colonist, TRAP_TICK_BOUND), "setup: colonist must become trapped at the requested tile")

## Ticks until `colonist` is working `job_id` with at least one tick of real
## progress parked under that job's own progress key; returns the key ("" on
## timeout).
func _tick_until_rescue_progress(world: WorldStateType, colonist: Dictionary, job_id: String, bound: int) -> String:
	for _i in bound:
		world.tick()
		var job := TestAccess.scheduler(world).queue.get_job(job_id)
		if job.is_empty() or String(job.get("status", "")) != "active":
			continue
		var target: Vector3i = job["target"]
		var key := "%s:%d_%d" % [job_id, target.x, target.y]
		if colonist.get("work") != null and TestAccess.progress_table(world).progress.has(key):
			return key
	return ""

func _has_progress_key_for(world: WorldStateType, job_id: String) -> bool:
	for key in TestAccess.progress_table(world).progress.keys():
		if String(key).begins_with(job_id + ":"):
			return true
	return false
