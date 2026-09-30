extends SceneTree

## An allied migrant uses the incident job to walk in, remains at
## the colony after arrival, and becomes an ordinary colonist through the
## existing set_faction command. The next scheduler tick must then assign its
## queued dig job using the colonist definition's default labour table.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

var _failed := false

func _init() -> void:
	_check_migrant_incident_and_recruitment()
	if _failed:
		quit(1)
		return
	print("test_migrant_joins: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _check_migrant_incident_and_recruitment() -> void:
	var world := WorldStateType.new(306278, 10, 32, 32, true)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append(ActorTableType.spawn("colonist", 16, 16, world._content, "colonist_home"))

	var entry := world._content.get_entry("incidents", "migrant_joins")
	_expect(int(entry.get("min_day", 0)) == 8, "migrant_joins must be gated to day 8")
	_expect(String(entry.get("faction", "")) == "allies", "migrant_joins must use the allies faction")
	_expect(String(entry.get("spawn", {}).get("actor_def", "")) == "colonist", "migrant_joins must spawn colonist actors")
	if _failed:
		return

	# Use the normal incident spawn path at the first tick of day 8. The
	# content row's lingers flag makes the actor available for recruitment after
	# its arrival wait instead of despawning at the terminal incident job.
	var proposed := world._incidents._spawn(entry, 8, 8 * 2200)
	_expect(proposed.size() == 1, "day 8 must propose one allied migrant")
	if proposed.is_empty():
		return
	var migrant_id := String(proposed[0])
	var migrant_job_id := ""
	for job_id in world._incidents._staged:
		if String(world._incidents._staged[job_id]["actor"]["id"]) == migrant_id:
			migrant_job_id = String(job_id)
			break
	_expect(not migrant_job_id.is_empty(), "migrant must have a queued incident walk job")
	if migrant_job_id.is_empty():
		return

	var arrived := false
	for _i in 400:
		world.tick()
		var actor := world._find_colonist(migrant_id)
		if not actor.is_empty() and world.get_assignments().get(migrant_id, {}).is_empty():
			arrived = true
			break
	_expect(arrived, "migrant must walk to the colony and remain after its incident job")
	if not arrived:
		return

	var migrant := world._find_colonist(migrant_id)
	_expect(String(migrant.get("factionId", "")) == "allies", "arrived migrant must remain allied until recruited")
	_expect(migrant.has("labourTable"), "spawned migrant must have a labour table")
	_expect(not migrant.get("labourTable", {}).is_empty(), "migrant labour table must have defaults")
	_expect(not migrant.get("labour_disabled", false), "migrant must not be labour-disabled")

	var recruit_result := world.apply({
		"actor": "player", "command_id": "recruit_migrant", "tick": world.get_tick(),
		"type": "set_faction", "payload": {"target": migrant_id, "faction_id": "colony"},
	})
	_expect(recruit_result.get("ok", false), "set_faction must recruit the migrant")
	_expect(String(world._find_colonist(migrant_id).get("factionId", "")) == "colony", "recruitment must switch faction to colony")

	var target := Vector2i(int(migrant["x"]) + 1, int(migrant["y"]))
	world._tiles[world._tile_index(target.x, target.y)] = WorldStateType.TILE_SOIL
	var pick_id := world.spawn_ground_tool_item("pick", migrant["x"], migrant["y"])
	_expect(world.set_tool_item_held(pick_id, migrant_id), "recruited migrant must be able to hold a pick")
	var dig_result := world.apply({
		"actor": "player", "command_id": "dig_migrant_target", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": target.x, "y": target.y},
	})
	_expect(dig_result.get("ok", false), "a dig job must be queued for the recruited migrant")
	world.tick()
	var assigned: Dictionary = world.get_assignments().get(migrant_id, {})
	_expect(not assigned.is_empty(), "the recruited migrant must be assigned in the faction-change tick cycle: %s jobs=%s" % [assigned, world.get_jobs()])
	var assigned_job := _find_job(world, String(assigned.get("job_id", "")))
	_expect(String(assigned_job.get("kind", "")) == "dig", "the recruited migrant must receive the queued dig job")

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job.get("id", "")) == job_id:
			return job
	return {}
