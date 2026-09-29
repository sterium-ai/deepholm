extends SceneTree

## Confirms DebugScenario.build() seeds at least one door, wooden_wall, chair, table,
## berry_bush and bed object (colonist-ai.md 3.5's passability content and
## section 3's "the debug scenario places some of each"), that its generated
## map contains at least one water tile, and that tile_atlas_map.gd declares
## atlas entries for water/berry_bush/bed -- independent of
## test_viewer_hash.gd's hash-equality check.

const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")

var _failed := false

func _init() -> void:
	_check_atlas_entries()

	var world = DebugScenarioType.build()
	var kinds_present: Dictionary = {}
	for object_entry in world.get_objects():
		kinds_present[String(object_entry["kind"])] = true
	for kind in ["door", "wooden_wall", "chair", "table", "berry_bush", "bed"]:
		if not kinds_present.get(kind, false):
			_fail("debug scenario must place at least one '%s' object" % kind)

	var found_water := false
	for y in WorldStateType.MAP_HEIGHT:
		for x in WorldStateType.MAP_WIDTH:
			if world.get_tile(x, y) == WorldStateType.TILE_WATER:
				found_water = true
	if not found_water:
		_fail("debug scenario's generated map must contain at least one water tile")

	if _failed:
		quit(1)
		return
	print("test_debug_scenario_objects: PASS")
	quit(0)

func _check_atlas_entries() -> void:
	if not TileAtlasMapType.TILE_ATLAS_MAP.has(WorldStateType.TILE_WATER):
		_fail("TILE_ATLAS_MAP must declare an entry for TILE_WATER")
	if not TileAtlasMapType.OBJECT_ATLAS_MAP.has("berry_bush"):
		_fail("OBJECT_ATLAS_MAP must declare an entry for 'berry_bush'")
	if not TileAtlasMapType.OBJECT_ATLAS_MAP.has("bed"):
		_fail("OBJECT_ATLAS_MAP must declare an entry for 'bed'")

func _fail(message: String) -> void:
	push_error(message)
	_failed = true
