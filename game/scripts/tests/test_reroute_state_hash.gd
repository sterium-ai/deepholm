extends SceneTree

## A colonist's route.rerouting holds only the live search's summary() (A3),
## but state_hash() must still cover the whole continuation: two worlds that
## differ only in an in-flight re-route's frontier/visited/parent map must not
## hash equal. Both worlds wall a colonist's next path tile mid-walk, so a
## multi-tick re-route starts; world B also has a chair (move cost 3) beside
## the colonist during that first resume() and removes it right after, so its
## search expanded tiles in a different order while everything else -- the
## persisted state with the rerouting field left out, and summary() -- is the
## same. A save/load round trip of either world keeps its hash.

const WorldType = preload("res://scripts/core/world_state.gd")

## The pick pickup and two tile-advances (4 ticks each) reach the walling
## tile; the re-route then needs several resume() calls in this open area.
const MAX_TICKS := 60

var _failed := false

func _init() -> void:
	_check_reroute_continuation_is_hashed()
	if _failed:
		quit(1)
		return
	print("test_reroute_state_hash: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

func _build_world() -> WorldType:
	var world := WorldType.new(4242)
	TestAccess.tile_grid(world).tiles.fill(WorldType.TILE_SOIL)
	TestAccess.object_table(world).objects.clear()
	TestAccess.object_table(world).object_factions.clear()
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 2, "y": 10, "route": null, "work": null, "carrying": null})
	world.spawn_ground_tool_item("pick", 2, 10)
	world.apply({"actor": "test", "command_id": "dig", "tick": world.get_tick(), "type": "dig",
		"payload": {"x": 20, "y": 10, "priority": 1}})
	return world

## Ticks until the colonist stands on (4,10), walls (5,10) (and, with_chair,
## puts a chair on (4,11)), ticks once so the re-route starts and resumes,
## then removes the chair. Returns false if the re-route is not mid-flight.
func _advance_to_mid_reroute(world: WorldType, with_chair: bool) -> bool:
	for _i in MAX_TICKS:
		world.tick()
		var colonist := world.get_colonists()[0]
		if colonist["x"] == 4 and colonist["y"] == 10:
			TestAccess.object_table(world).set_object(5, 10, "wooden_wall")
			if with_chair:
				TestAccess.object_table(world).set_object(4, 11, "chair")
			world.tick()
			if with_chair:
				TestAccess.object_table(world).set_object(4, 11, "")
			var route = world.get_colonists()[0].get("route")
			return route != null and route.get("rerouting") != null and route["rerouting"]["status"] == "searching"
	return false

## to_save_state() as JSON with every entity's in-flight rerouting dropped.
func _save_without_rerouting(world: WorldType) -> String:
	var state: Dictionary = world.to_save_state()
	for entity in state["entities"]:
		if entity.get("route") != null:
			entity["route"].erase("rerouting")
	return JSON.stringify(state)

func _rerouting(world: WorldType) -> Dictionary:
	return world.get_colonists()[0]["route"]["rerouting"]

func _check_reroute_continuation_is_hashed() -> void:
	var plain := _build_world()
	var chaired := _build_world()
	var plain_mid := _advance_to_mid_reroute(plain, false)
	var chaired_mid := _advance_to_mid_reroute(chaired, true)
	_expect(plain_mid and chaired_mid, "both fixtures must catch the re-route search still STATUS_SEARCHING")
	if not (plain_mid and chaired_mid):
		return

	# Preconditions: the worlds differ only in the re-route's continuation.
	_expect(_save_without_rerouting(plain) == _save_without_rerouting(chaired),
		"apart from the rerouting field the two saves must be identical")
	_expect(_rerouting(plain) == _rerouting(chaired),
		"route.rerouting (summary()) must be identical: %s vs %s" % [_rerouting(plain), _rerouting(chaired)])
	var plain_saved: Dictionary = plain.to_save_state()
	var chaired_saved: Dictionary = chaired.to_save_state()
	_expect(JSON.stringify(plain_saved["entities"][0]["route"]["rerouting"])
		!= JSON.stringify(chaired_saved["entities"][0]["route"]["rerouting"]),
		"the chair must have changed the persisted search continuation")

	_expect(plain.state_hash() != chaired.state_hash(),
		"state_hash() must differ when only the in-flight re-route continuation differs")
	_expect(WorldType.from_save_state(plain_saved).state_hash() == plain.state_hash(),
		"a save/load round trip mid-reroute must keep state_hash() (plain)")
	_expect(WorldType.from_save_state(chaired_saved).state_hash() == chaired.state_hash(),
		"a save/load round trip mid-reroute must keep state_hash() (chaired)")
