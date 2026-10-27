extends SceneTree

## B3 evidence: renders the real art-mode MapView (map_view.gd with its tile layers,
## colonist_sprites.gd and actor_sprites.gd; not headless, it needs a renderer) over a
## showcase painted into a real WorldState: every tile kind (soil with water and rock
## shores, floor, plowed, planted, trench, hazard, trees), every placed object kind,
## construction-site ghosts (wall, door, bed, both workbench orientations), the ground
## items in a stockpile (wood, stone, pick, axe) and the three non-colonist actors (wolf,
## raider, trader), then saves one PNG.
##
## Like B4-capture.gd it writes WorldState internals directly to build the scene (tiles,
## stackable items, actors, site progress): capture only, nothing is ticked afterwards.
## Lives outside game/ on purpose (not part of the suite):
##   godot --path game --script <abs path to this file> -- <abs out.png> [pack_root]
## pack_root defaults to res://assets/pack/; pass user://none/ for the placeholder look.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

const SEED := 424242
const ZOOM := 3.0
const SIZE := Vector2i(26, 15)
const FRAME_WAIT_COUNT := 10

var _out := ""
var _map_view: MapViewType
var _viewport: SubViewport
var _frames := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() >= 1 else ""
	var pack_root: String = args[1] if args.size() >= 2 else "res://assets/pack/"
	if _out.is_empty():
		push_error("usage: B3-capture.gd -- <abs out.png> [pack_root]")
		quit(2)
		return
	# Renders into its own SubViewport: the window may be smaller than the scene.
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE * 16 * int(ZOOM))
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	var world := WorldStateType.new(SEED)
	var colonist: Dictionary = world.get_colonists()[0]
	var top_left := Vector2i(clampi(int(colonist["x"]) - 4, 0, world.get_map_width() - SIZE.x),
		clampi(int(colonist["y"]) + 2, 0, world.get_map_height() - SIZE.y))
	_paint(world, top_left)
	_place(world, top_left)
	_map_view = MapViewType.new(pack_root)
	_viewport.add_child(_map_view)
	_map_view.scale = Vector2.ONE * ZOOM
	_map_view.position = -Vector2(top_left) * 16.0 * ZOOM
	_map_view.set_world(world)
	_map_view.refresh()
	print("B3-capture: pack art %s, showcase at %s" % [_map_view.is_pack_art(), top_left])

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < FRAME_WAIT_COUNT:
		return false
	var err := _viewport.get_texture().get_image().save_png(_out)
	print("B3-capture: wrote %s (%s)" % [_out, error_string(err)])
	quit(0 if err == OK else 1)
	return false

func _paint_tile(world: WorldStateType, at: Vector2i, kind: String) -> void:
	world._tile_grid.tiles[world._tile_grid.tile_index(at.x, at.y)] = kind

## Soil everywhere, a pond and a rock outcrop (shorelines), a row of each ground kind, and
## trees spread so the hash shows the three sizes.
func _paint(world: WorldStateType, t: Vector2i) -> void:
	for y in SIZE.y:
		for x in SIZE.x:
			_paint_tile(world, t + Vector2i(x, y), WorldStateType.TILE_SOIL)
	for y in range(1, 4):
		for x in range(1, 5):
			_paint_tile(world, t + Vector2i(x, y), WorldStateType.TILE_WATER)
	for y in range(1, 4):
		for x in range(7, 10):
			_paint_tile(world, t + Vector2i(x, y), WorldStateType.TILE_ROCK)
	_paint_tile(world, t + Vector2i(10, 2), WorldStateType.TILE_ROCK)
	for x in range(12, 25, 2):
		_paint_tile(world, t + Vector2i(x, 3), WorldStateType.TILE_TREE)
	for x in range(13, 25, 2):
		_paint_tile(world, t + Vector2i(x, 5), WorldStateType.TILE_TREE)
	var strip := [WorldStateType.TILE_FLOOR, WorldStateType.TILE_PLOWED_SOIL, WorldStateType.TILE_PLANTED,
		WorldStateType.TILE_TRENCH, WorldStateType.TILE_HAZARD]
	for i in strip.size():
		for x in 2:
			_paint_tile(world, t + Vector2i(1 + i * 2 + x, 6), strip[i])

func _command(world: WorldStateType, type: String, payload: Dictionary, n: int) -> void:
	var result: Dictionary = world.apply({"actor": "player", "command_id": "b3_%s_%d" % [type, n],
		"tick": world.get_tick(), "type": type, "payload": payload})
	if not bool(result.get("ok", false)):
		push_error("B3-capture: %s %s rejected: %s" % [type, payload, result])

func _place(world: WorldStateType, t: Vector2i) -> void:
	var n := 0
	var objects := ["chair", "table", "bed", "door", "wooden_wall", "wooden_wall", "stone_wall", "stone_wall",
		"berry_bush", "berry_bush"]
	for i in objects.size():
		_command(world, "place_object", {"x": t.x + 1 + i * 2, "y": t.y + 8, "kind": objects[i]}, n)
		n += 1
	_command(world, "place_object", {"x": t.x + 22, "y": t.y + 8, "kind": "workbench"}, n)
	n += 1
	var sites := [["wooden_wall", ""], ["door", ""], ["bed", ""], ["workbench", "horizontal"], ["workbench", "vertical"]]
	var x := t.x + 1
	for spec in sites:
		_command(world, "build", {"kind": spec[0], "x": x, "y": t.y + 10, "orientation": spec[1]}, n)
		n += 1
		x += 4 if spec[0] == "workbench" else 3
	for site in world._construction.site_table.list():
		world._construction.site_table.add_progress(String(site["id"]), int(site["build_ticks"]) / 2)
	_command(world, "zone_add", {"x": t.x + 16, "y": t.y + 10, "width": 4, "height": 1}, n)
	for item in [["wood", 16, 5], ["stone", 17, 3]]:
		var item_id := "item_%d" % world._next_item_id
		world._next_item_id += 1
		world._items[item_id] = {"id": item_id, "x": t.x + item[1], "y": t.y + 10, "kind": item[0], "count": item[2]}
	world.spawn_ground_tool_item("pick", t.x + 18, t.y + 10)
	world.spawn_ground_tool_item("axe", t.x + 19, t.y + 10)
	for actor in [["wolf_b3", "wolf", "predators", 4], ["raider_b3", "wolf", "raiders", 8], ["trader_b3", "trader", "traders", 12]]:
		world._colonists.append({"id": actor[0], "kind": actor[1], "factionId": actor[2],
			"x": t.x + actor[3], "y": t.y + 13, "route": null, "health": {"hp": 30, "maxHp": 40}})
