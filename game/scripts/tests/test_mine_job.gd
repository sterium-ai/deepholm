extends SceneTree

## Covers the "mine" job kind (content/jobs.json, content/items.json),
## wired into world_state.gd's own _apply_job_command()/_toil_on_work_complete() the same way
## dig/chop are (docs/architecture/orders-and-movement.md). mine's target must be a TILE_ROCK
## tile (rejected invalid_target otherwise, no passability check -- rock is impassable, like
## chop's tree target); mine needs a "pick" (jobs.json's needs_tool), so a rock tile with no
## reachable pick blocks the job blocked_no_tool through the fully generic
## fetch_tool/JobQueue.block_no_tool() path dig/chop already exercise; on completion the target
## tile becomes TILE_FLOOR and one "stone" ground item spawns there; that item then hauls into a
## stockpile zone through the existing, unmodified generic "haul" job kind; and mining a rock
## tile does not disturb passability() for any other, un-mined rock tile.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const RouteSearchType = preload("res://scripts/core/routing/route_search.gd")
const ReservationInvariantsType = preload("res://scripts/core/jobs/reservation_invariants.gd")

const MAP_SIZE := 20

var _failed := false

func _init() -> void:
	_check_invalid_target_on_non_rock_tile()
	_check_blocked_no_tool_on_rock_with_no_pick()
	_check_full_order_completes_and_stone_hauls_into_zone()
	_check_overlapping_mine_orders_produce_one_stone()

	if _failed:
		quit(1)
		return
	print("test_mine_job: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _command(world: WorldStateType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

## A small all-floor world with one colonist at (0, 0); MAP_SIZE keeps tick()
## cheap while leaving room for a rock target, a stockpile zone and a route
## search, none of which need the real world generator's terrain.
func _build_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10, MAP_SIZE, MAP_SIZE)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._objects.clear()
	world._object_factions.clear()
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null})
	return world

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

## mine's own target check (world_state.gd's _check_mine_target_command()) must reject a
## non-rock tile as invalid_target, mirroring chop's own tree-only rule.
func _check_invalid_target_on_non_rock_tile() -> void:
	var world := _build_world(352001)
	var result := _command(world, "mine_wrong_tile", "mine", {"x": 5, "y": 0, "priority": 1})
	_expect(not result.get("ok", true), "mine on a non-rock (floor) tile must be rejected")
	_expect(String(result.get("rejection", {}).get("reason", "")) == "invalid_target",
		"mine on a non-rock tile must be rejected invalid_target, got %s" % result.get("rejection"))

## A rock tile with no pick anywhere must submit successfully (the target itself is valid) but
## block on blocked_no_tool via the same generic fetch_tool/JobQueue.block_no_tool() path
## dig already exercises (test_tool_items.gd's own _check_blocked_no_tool_frees_colonist_for_
## other_work()) -- staying a queued, non-terminal job.
func _check_blocked_no_tool_on_rock_with_no_pick() -> void:
	var world := _build_world(352002)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_ROCK
	var submitted := _command(world, "mine_1", "mine", {"x": 2, "y": 0, "priority": 1})
	_expect(submitted.get("ok", false), "mine submission on a rock tile must be accepted even with no pick anywhere")
	var job_id := String(submitted.get("job_id", ""))

	var blocked := false
	for _i in 20:
		world.tick()
		var job := _find_job(world, job_id)
		if String(job.get("reason", "")) == "blocked_no_tool":
			blocked = true
			_expect(String(job.get("status", "")) == "queued",
				"a mine job with no pick anywhere must stay a queued, non-terminal job, got status '%s'" % job.get("status"))
			break
	_expect(blocked, "a mine job with no pick anywhere must expose reason blocked_no_tool within the tick budget")

## The full order: submit through fetch_tool/reserve/go_to/work/release_all on a rock tile with
## a reachable pick. On completion the target tile is TILE_FLOOR/passable and exactly one
## "stone" item sits on the ground there; a subsequent zone_add stockpile zone then absorbs that
## stone item through the existing, unmodified generic haul job kind. Also proves the mining
## did not touch any other, un-mined rock tile's own passability, and that the freshly mined
## tile is genuinely crossable by a standalone route search (not just individually "passable").
func _check_full_order_completes_and_stone_hauls_into_zone() -> void:
	var world := _build_world(352003)
	var target := Vector2i(5, 0)
	world._tiles[world._tile_index(target.x, target.y)] = WorldStateType.TILE_ROCK
	var untouched_rock := Vector2i(15, 15)
	world._tiles[world._tile_index(untouched_rock.x, untouched_rock.y)] = WorldStateType.TILE_ROCK
	world.spawn_ground_tool_item("pick", 0, 0)

	var submitted := _command(world, "mine_1", "mine", {"x": target.x, "y": target.y, "priority": 1})
	_expect(submitted.get("ok", false), "mine submission on a rock tile with a reachable pick must be accepted")
	var job_id := String(submitted.get("job_id", ""))

	var completed := false
	for _i in 100:
		world.tick()
		if String(_find_job(world, job_id).get("status", "")) == "completed":
			completed = true
			break
	_expect(completed, "a mine job with a reachable pick must complete via fetch_tool/reserve/go_to/work/release_all within the tick budget")
	if not completed:
		return

	_expect(world.get_tile(target.x, target.y) == WorldStateType.TILE_FLOOR,
		"the mined tile must become TILE_FLOOR on completion")
	var mined_passability := world.passability(target.x, target.y)
	_expect(bool(mined_passability["passable"]), "the freshly mined tile must be passable")

	var untouched_passability := world.passability(untouched_rock.x, untouched_rock.y)
	_expect(not bool(untouched_passability["passable"]),
		"an un-mined TILE_ROCK tile elsewhere must remain impassable after another tile is mined")

	var stone_items: Array[Dictionary] = []
	for item in world.get_items():
		if String(item.get("kind", "")) == "stone":
			stone_items.append(item)
	_expect(stone_items.size() == 1, "exactly one stone item must exist after mining, got %d" % stone_items.size())
	if stone_items.size() == 1:
		_expect(int(stone_items[0]["x"]) == target.x and int(stone_items[0]["y"]) == target.y,
			"the stone item must sit on the ground at the mined tile")
		_expect(int(stone_items[0]["count"]) == 1, "the stone item must have count 1")

	# A standalone bounded route search must actually cross the freshly mined tile, not merely
	# report it individually passable.
	var route := RouteSearchType.new(Vector2i(target.x - 1, target.y), Vector2i(target.x + 1, target.y),
		func(tile: Vector2i) -> bool: return bool(world.passability(tile.x, tile.y)["passable"]),
		Vector2i.ZERO, Vector2i(MAP_SIZE - 1, MAP_SIZE - 1))
	var route_status := route.get_status()
	while route_status == RouteSearchType.STATUS_SEARCHING:
		route_status = route.resume()
	_expect(route_status == RouteSearchType.STATUS_FOUND,
		"a route search must be able to cross the freshly mined tile, got status '%s'" % route_status)
	_expect(route.get_path().has(target), "the found route must actually pass through the mined tile")

	# Now haul the stone item into a stockpile zone through the ordinary, unmodified generic
	# haul job kind (WorldState auto-submits one haul job per unreserved ground item every tick).
	var zone_result := _command(world, "zone_setup", "zone_add", {"x": 12, "y": 0, "width": 2, "height": 2})
	_expect(zone_result.get("ok", false), "zone_add must be accepted")
	var zone: Dictionary = world._zones[String(zone_result["zone_id"])]

	var hauled := false
	for _i in 200:
		world.tick()
		for item in world.get_items():
			if String(item.get("kind", "")) == "stone":
				var ix := int(item["x"])
				var iy := int(item["y"])
				if ix >= int(zone["x"]) and ix < int(zone["x"]) + int(zone["width"]) \
						and iy >= int(zone["y"]) and iy < int(zone["y"]) + int(zone["height"]):
					hauled = true
		if hauled:
			break
	_expect(hauled, "the mined stone item must be hauled into the stockpile zone within the tick budget")

## Two mine orders queued for the same rock tile, with a single colonist
## and a single pick forcing them to run sequentially, must not both spawn a stone.
## _toil_on_work_complete()'s "mine" branch revalidates TILE_ROCK before spawning/flooring
## (mirroring till/sow's own stale-duplicate-order pattern, test_farming_content.gd): the first
## order mines and floors the tile; the second, already queued while the tile was still rock,
## reaches work-complete against a now-TILE_FLOOR target and must fail invalid_target instead of
## producing a second stone -- and must not leave its tile reservation behind once terminal.
func _check_overlapping_mine_orders_produce_one_stone() -> void:
	var world := _build_world(352004)
	var target := Vector2i(2, 0)
	world._tiles[world._tile_index(target.x, target.y)] = WorldStateType.TILE_ROCK
	world.spawn_ground_tool_item("pick", 0, 0)

	var mine_1 := _command(world, "mine_dup_1", "mine", {"x": target.x, "y": target.y, "priority": 1})
	_expect(mine_1.get("ok", false), "first mine submission on a rock tile must be accepted")
	var mine_2 := _command(world, "mine_dup_2", "mine", {"x": target.x, "y": target.y, "priority": 1})
	_expect(mine_2.get("ok", false), "second mine submission for the same rock tile must also be accepted")

	var job_ids := [String(mine_1["job_id"]), String(mine_2["job_id"])]
	var completed_count := 0
	var failed_count := 0
	for _i in 400:
		world.tick()
		completed_count = 0
		failed_count = 0
		for job_id in job_ids:
			match String(_find_job(world, job_id).get("status", "")):
				"completed": completed_count += 1
				"failed": failed_count += 1
		if completed_count + failed_count == 2:
			break

	_expect(completed_count == 1, "exactly one of two mine orders queued for the same rock tile must complete, got %d" % completed_count)
	_expect(failed_count == 1, "exactly one of two mine orders queued for the same rock tile must fail, got %d" % failed_count)
	for job_id in job_ids:
		var job := _find_job(world, job_id)
		if String(job.get("status", "")) == "failed":
			_expect(String(job.get("reason", "")) == "invalid_target",
				"the second mine order to reach an already-mined tile must fail invalid_target, got %s" % job)

	_expect(world.get_tile(target.x, target.y) == WorldStateType.TILE_FLOOR, "the tile must end up mined (floor) exactly once")
	var stone_items: Array[Dictionary] = []
	for item in world.get_items():
		if String(item.get("kind", "")) == "stone":
			stone_items.append(item)
	_expect(stone_items.size() == 1,
		"exactly one stone item must exist after two overlapping mine orders on the same rock tile, got %d" % stone_items.size())

	_expect(not world._scheduler.queue.get_reservation_table().is_reserved("tile:%d,%d" % [target.x, target.y]),
		"the target tile must be unreserved once both mine orders are terminal")
	var orphans := ReservationInvariantsType.find_orphaned_reservations(
		world._scheduler.queue.get_reservation_table(), world.get_jobs())
	_expect(orphans.is_empty(), "the stale mine order must not leave any orphaned reservation, got %s" % [orphans])
