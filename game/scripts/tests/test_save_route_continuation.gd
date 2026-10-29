extends SceneTree

## A7 (ADR 058): an in-flight route search keeps its accumulated costs across a save, so a
## search that spans a map change continues exactly as the uninterrupted one. Before A7,
## RouteSearch.restore() rebuilt the costs from the current map (_rebuild_costs()), which
## gives a tile visited before the change its new cost and can reorder the frontier.
##
## Two levels, each with the two map changes the acceptance names, made between ticks after
## the search has started and before the save:
## - "visited": a tile the search already visited gets another cost while staying passable
##   (route level: 1 -> 12; world level: a chair, move_cost 3, on a floor tile);
## - "frontier": a tile on the search frontier becomes impassable (a rock / a wooden wall).
## Route level: RouteSearch -> SchedulingCodec route -> SaveWire.pack_route() -> JSON ->
## SaveWire.unpack_route() -> restore(), finished and compared with the uninterrupted search
## (path, status, expansions, resume() calls); the restored snapshot() equals the live one.
## World level: the real SaveIO.write_atomic()/read() and StateCodec.decode(); state_hash()
## must match the uninterrupted world before the first tick and after every tick, and the
## search ends with the same path, status and expansion count.
## Each case also restores the same save without its "cost" (the pre-A7 restore) and expects
## a difference, so the check cannot pass by accident.

const RouteType = preload("res://scripts/core/scheduling/measured_route.gd")
const SchedulingCodecType = preload("res://scripts/core/persistence/scheduling_codec.gd")
const SaveWireType = preload("res://scripts/core/persistence/save_wire.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const GRID := 40
const SAVE_PATH := "user://test-save-route-continuation.json"
const WORLD_MAX_TICKS := 400

var _failed := false

func _init() -> void:
	for change in ["visited", "frontier"]:
		_check_route_level(change)
		_check_world_level(change)
	_remove(SAVE_PATH)
	if _failed:
		quit(1)
		return
	print("test_save_route_continuation: PASS")
	quit()

func _fail(message: String) -> void:
	_failed = true
	push_error(message)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

# --- route level -------------------------------------------------------------------

## A 40x40 grid with a wall across the middle and gaps at both ends: the search floods the
## start's half, so its frontier holds two competing branches (west and east gap).
func _grid_costs() -> Dictionary:
	var costs: Dictionary = {}
	for y in GRID:
		for x in GRID:
			costs[Vector2i(x, y)] = 0.0 if y == 20 and x > 1 and x < GRID - 2 else 1.0
	return costs

func _new_search(costs: Dictionary) -> RouteType:
	var cost_fn := func(tile: Vector2i) -> float: return costs.get(tile, 0.0)
	return RouteType.new(Vector2i(18, 5), Vector2i(18, 35), cost_fn, Vector2i.ZERO, Vector2i(GRID - 1, GRID - 1))

## Resumes twice (128 expansions), then applies the change: the visited parent of the
## westmost frontier tile (so a rebuild would push that branch back behind the east one), or
## the oldest frontier tile.
func _start_and_change(costs: Dictionary, change: String) -> RouteType:
	var search := _new_search(costs)
	search.resume()
	search.resume()
	var snapshot := search.snapshot()
	if change == "visited":
		var west: Vector2i = snapshot["frontier"][0]
		for tile: Vector2i in snapshot["frontier"]:
			if tile.x < west.x:
				west = tile
		var parent: Vector2i = snapshot["came_from"][west]
		_expect(parent != snapshot["start"], "route/visited: the changed tile must not be the start")
		costs[parent] = 12.0
	else:
		var frontier: Array = snapshot["frontier"]
		costs[frontier[0]] = 0.0
	return search

func _finish(search: RouteType) -> Dictionary:
	while not search.is_terminal():
		search.resume()
	return {"status": search.get_status(), "path": search.get_path(), "expansions": search.expansions,
		"resume_calls": search.resume_calls}

## The live search's snapshot() through the save path: codec dict, SaveWire, JSON text and back.
func _through_save(snapshot: Dictionary) -> Dictionary:
	var plain: Dictionary = SchedulingCodecType._encode_route(snapshot)
	var packed := SaveWireType.pack_route(plain, GRID, GRID)
	_expect(packed.has("costBytes") and packed.has("visitedBits") and not packed.has("visited"),
		"a codec route state must pack to the compact form (got keys %s)" % [packed.keys()])
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(packed))
	SaveJsonInts._coerce_floats_to_ints(parsed)
	var unpacked := SaveWireType.unpack_route(parsed, GRID, GRID)
	_expect(unpacked["ok"], "the packed route must unpack: %s" % unpacked)
	var check := SchedulingValidator._valid_route_state(unpacked["route"], GRID, GRID)
	_expect(check["ok"], "the unpacked route must validate: %s" % check)
	return SchedulingCodecType._decode_route(unpacked["route"])

func _restored(costs: Dictionary, state: Dictionary) -> RouteType:
	var search := _new_search(costs)
	search.restore(state)
	return search

func _check_route_level(change: String) -> void:
	var live_costs := _grid_costs()
	var live := _start_and_change(live_costs, change)
	var saved_costs := _grid_costs()
	var saved := _start_and_change(saved_costs, change)
	var state := _through_save(saved.snapshot())
	var restored := _restored(saved_costs, state)
	_expect(restored.snapshot() == saved.snapshot(),
		"route/%s: the restored search's snapshot() must equal the saved search's exactly" % change)
	var expected := _finish(live)
	var actual := _finish(restored)
	_expect(actual == expected, "route/%s: the restored search must finish like the uninterrupted one: %s vs %s" % [
		change, _summary(actual), _summary(expected)])
	var legacy_state := state.duplicate()
	legacy_state.erase("cost")
	var legacy := _finish(_restored(saved_costs, legacy_state))
	_expect(legacy != expected, "route/%s: the pre-A7 cost rebuild must diverge here, or this case proves nothing (%s)" % [
		change, _summary(legacy)])

# --- world level -------------------------------------------------------------------

## A colonist at (0, 0) above a rock row whose only gap is at the east edge, and a chop order
## on a tree below it: the assignment search floods the colonist's side over several ticks.
func _build_world() -> WorldStateType:
	var world := Scenarios.floor_world(7007)
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	TestAccess.colonists(world).append(Scenarios.idle_colonist("colonist_0", 0, 0))
	Scenarios.rock_row_with_gap(world, 24, 44)
	TestAccess.set_tile(world, 2, 40, WorldStateType.TILE_TREE)
	world.spawn_ground_tool_item("axe", 1, 0)
	var order := Scenarios.command(world, "chop_far", "chop", {"x": 2, "y": 40, "priority": 1})
	_expect(order.get("ok", false), "the chop order must be accepted: %s" % order)
	return world

## The first in-flight route search of world (a colonist re-route, else a pending assignment).
func _live_search(world: WorldStateType) -> RouteType:
	for colonist_id: String in TestAccess.reroutes(world):
		var search: RouteType = TestAccess.reroutes(world)[colonist_id]
		if not search.is_terminal():
			return search
	var pending := TestAccess.assignment_pending(TestAccess.scheduler(world))
	for worker: String in pending:
		var route: Variant = pending[worker]["route"]
		if route != null and not (route as RouteType).is_terminal():
			return route
	return null

## Ticks until a search has expanded at least 100 tiles, then applies the change through
## ObjectTable (chair on a visited corridor tile, wall on a frontier tile).
func _advance_and_change(world: WorldStateType, change: String) -> bool:
	for _i in WORLD_MAX_TICKS:
		world.tick()
		var search := _live_search(world)
		if search == null or search.expansions < 100:
			continue
		var snapshot := search.snapshot()
		var tile := Vector2i(-1, -1)
		if change == "visited":
			var came_from: Dictionary = snapshot["came_from"]
			for candidate: Vector2i in came_from:
				if came_from.values().has(candidate) and candidate != snapshot["start"]:
					tile = candidate
					break
			TestAccess.object_table(world).set_object(tile.x, tile.y, "chair")
		else:
			tile = (snapshot["frontier"] as Array)[0]
			TestAccess.object_table(world).set_object(tile.x, tile.y, "wooden_wall")
		return tile.x >= 0
	return false

func _check_world_level(change: String) -> void:
	var direct := _build_world()
	var source := _build_world()
	var changed_direct := _advance_and_change(direct, change)
	var changed_source := _advance_and_change(source, change)
	_expect(changed_direct and changed_source, "world/%s: the scenario must catch a search mid-flight and change the map" % change)
	if not (changed_direct and changed_source):
		return
	var search := _live_search(source)
	_expect(search != null and (search.snapshot()["cost"] as Dictionary).size() > 100,
		"world/%s: the save must hold a search with its costs" % change)
	_remove(SAVE_PATH)
	var written := SaveIOType.write_atomic(SAVE_PATH, source.to_save_state())
	_expect(written["ok"], "world/%s: the mid-search save must write: %s" % [change, written])
	var read := SaveIOType.read(SAVE_PATH)
	_expect(read["ok"], "world/%s: the mid-search save must read back: %s" % [change, read])
	if not read["ok"]:
		return
	var legacy_state: Dictionary = (read["state"] as Dictionary).duplicate(true)
	var stripped := _strip_costs(legacy_state)
	var restored := StateCodecType.decode(read["state"])
	_expect(restored.state_hash() == direct.state_hash(),
		"world/%s: the restored world must hash like the uninterrupted one before any tick" % change)
	_expect(stripped > 0 and StateCodecType.decode(legacy_state).state_hash() != direct.state_hash(),
		"world/%s: the pre-A7 cost rebuild must hash differently here, or this case proves nothing" % change)
	var direct_search := _live_search(direct)
	var restored_search := _live_search(restored)
	_expect(restored_search != null and restored_search.snapshot() == direct_search.snapshot(),
		"world/%s: the restored search's snapshot() must equal the uninterrupted one's" % change)
	if restored_search == null:
		return
	var ticks := 0
	while not direct_search.is_terminal() and ticks < WORLD_MAX_TICKS:
		direct.tick()
		restored.tick()
		ticks += 1
		_expect(restored.state_hash() == direct.state_hash(),
			"world/%s: state_hash() must match the uninterrupted run after tick %d" % [change, ticks])
	_expect(direct_search.is_terminal() and restored_search.is_terminal(),
		"world/%s: both searches must end within %d ticks" % [change, WORLD_MAX_TICKS])
	_expect(restored_search.get_status() == direct_search.get_status() and restored_search.get_path() == direct_search.get_path()
		and restored_search.expansions == direct_search.expansions,
		"world/%s: the restored search must end with the same status, path and expansions (%s/%d/%d vs %s/%d/%d)" % [
			change, restored_search.get_status(), restored_search.get_path().size(), restored_search.expansions,
			direct_search.get_status(), direct_search.get_path().size(), direct_search.expansions])
	for _i in 30:
		direct.tick()
		restored.tick()
	_expect(restored.state_hash() == direct.state_hash(), "world/%s: the worlds must stay in step after the search" % change)

## Removes "cost" from every route state in state (a pre-A7 save's routes); the count removed.
func _strip_costs(state: Dictionary) -> int:
	var removed := 0
	for entity: Dictionary in state["entities"]:
		var route: Variant = entity.get("route")
		if route is Dictionary and (route as Dictionary).get("rerouting") is Dictionary:
			removed += 1 if (route["rerouting"] as Dictionary).erase("cost") else 0
	var pending: Dictionary = state["scheduling"]["pending"]
	for worker: String in pending:
		var route: Variant = pending[worker]["route"]
		if route is Dictionary:
			removed += 1 if (route as Dictionary).erase("cost") else 0
	return removed

func _summary(result: Dictionary) -> String:
	return "%s path=%d expansions=%d resumes=%d" % [result["status"], (result["path"] as Array).size(),
		result["expansions"], result["resume_calls"]]

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
