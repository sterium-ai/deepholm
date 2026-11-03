extends SceneTree

## B7 evidence: renders the real art-mode MapView (not headless, it needs a renderer)
## over a small showcase painted into a real WorldState: every placed object kind
## (bed, door, workbench), construction-site ghosts of both workbench orientations,
## the door and the bed, the carrot growing through its three stages, and one ground
## stack of every item kind (B3's four, B7's seven pack-only kinds and sand), then
## saves one PNG. The colonists are moved to the right edge.
##
## Like B3-capture.gd it writes WorldState internals directly to build the scene:
## capture only, nothing is ticked afterwards. Lives outside game/ on purpose:
##   godot --path game --script <abs path to this file> -- <abs out.png> [pack_root]
## pack_root defaults to res://assets/pack/; pass user://none/ for the placeholder look.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

const SEED := 424242
const ZOOM := 4.0
const SIZE := Vector2i(16, 11)
const FRAME_WAIT_COUNT := 10
const ITEMS := ["wood", "stone", "seed", "food", "coal", "gold_coin", "flint", "planks", "stone_blocks", "sand"]

var _out := ""
var _map_view: MapViewType
var _viewport: SubViewport
var _frames := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() >= 1 else ""
	var pack_root: String = args[1] if args.size() >= 2 else "res://assets/pack/"
	if _out.is_empty():
		push_error("usage: B7-capture.gd -- <abs out.png> [pack_root]")
		quit(2)
		return
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
	print("B7-capture: pack art %s, showcase at %s" % [_map_view.is_pack_art(), top_left])

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < FRAME_WAIT_COUNT:
		return false
	var err := _viewport.get_texture().get_image().save_png(_out)
	print("B7-capture: wrote %s (%s)" % [_out, error_string(err)])
	quit(0 if err == OK else 1)
	return false

func _paint_tile(world: WorldStateType, at: Vector2i, kind: String) -> void:
	world._tile_grid.tiles[world._tile_grid.tile_index(at.x, at.y)] = kind

## Soil everywhere, then the carrot's three stages on plowed ground.
func _paint(world: WorldStateType, t: Vector2i) -> void:
	for y in SIZE.y:
		for x in SIZE.x:
			_paint_tile(world, t + Vector2i(x, y), WorldStateType.TILE_SOIL)
	var stages := [WorldStateType.TILE_PLANTED, "crop_grown", "crop_ripe"]
	for i in stages.size():
		_paint_tile(world, t + Vector2i(11 + i, 2), WorldStateType.TILE_PLOWED_SOIL)
		_paint_tile(world, t + Vector2i(11 + i, 3), stages[i])

func _command(world: WorldStateType, type: String, payload: Dictionary, n: int) -> void:
	var result: Dictionary = world.apply({"actor": "player", "command_id": "b7_%s_%d" % [type, n],
		"tick": world.get_tick(), "type": type, "payload": payload})
	if not bool(result.get("ok", false)):
		push_error("B7-capture: %s %s rejected: %s" % [type, payload, result])

func _place(world: WorldStateType, t: Vector2i) -> void:
	var n := 0
	for spec in [["bed", 1], ["door", 3], ["workbench", 5]]:
		_command(world, "place_object", {"x": t.x + spec[1], "y": t.y + 3, "kind": spec[0]}, n)
		n += 1
	var sites := [["bed", "", 1], ["door", "", 3], ["workbench", "horizontal", 5], ["workbench", "vertical", 8]]
	for spec in sites:
		_command(world, "build", {"kind": spec[0], "x": t.x + spec[2], "y": t.y + 6, "orientation": spec[1]}, n)
		n += 1
	for site in world._construction.site_table.list():
		world._construction.site_table.add_progress(String(site["id"]), int(site["build_ticks"]) / 2)
	# Ground items are drawn on zoned cells only (map_view.gd's _draw_stockpile_counts).
	_command(world, "zone_add", {"x": t.x + 1, "y": t.y + 9, "width": 13, "height": 1}, n)
	# Colonists stepped aside so they hide nothing (capture only, never ticked).
	for i in world._colonists.size():
		world._colonists[i]["x"] = t.x + 14
		world._colonists[i]["y"] = t.y + 2 + i * 2
	for i in ITEMS.size():
		world._item_table.place_new_ground_item(ITEMS[i], 3, Vector3i(t.x + 1 + i, t.y + 9, 0))
	world.spawn_ground_tool_item("pick", t.x + 12, t.y + 9)
	world.spawn_ground_tool_item("axe", t.x + 13, t.y + 9)
