extends SceneTree

## B6 evidence: renders one colonist holding a pick while hauling wood, through
## the real WorldState (auto haul + tool store) and the real colonist_sprites.gd,
## zoomed on its tile, and saves a PNG. Presentation only; needs a window (not
## --headless, whose dummy renderer returns an empty viewport).
## `trapped` after the path also marks the colonist trapped (third badge).
## Usage (from the repo root):
##   & $env:GODOT --path game --script ../docs/orca/handoffs/B6-badge_shot.gd -- <out.png> [trapped]

const WorldStateType = preload("res://scripts/core/world_state.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const PackAssetsType = preload("res://scripts/viewer/pack_assets.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const ZOOM := 4.0
const FRAME_WAIT_COUNT := 10

var _out := ""
var _frames := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() >= 1 else ""
	var world := WorldStateType.new(24601, 10)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({
		"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "z": 0, "route": null, "work": null, "hands": [],
	})
	TestAccess.item_table(world).items["item_1"] = {"id": "item_1", "x": 0, "y": 0, "z": 0, "kind": "wood", "count": 1}
	TestAccess.item_table(world).next_item_id = 2
	world.apply({"actor": "test", "command_id": "zone", "tick": world.get_tick(), "type": "zone_add",
		"payload": {"x": 5, "y": 5, "width": 1, "height": 1}})
	for _i in 60:
		world.tick()
		if InventoryType.is_carrying(world.get_colonists()[0]):
			break
	var pick := world.spawn_ground_tool_item("pick", 0, 0)
	world.set_tool_item_held(pick, "colonist_0")
	if "trapped" in args:
		TestAccess.colonists(world)[0]["trapped"] = {"tile": Vector2i(0, 0), "ticksRemaining": 40, "fromTile": Vector2i(0, 0)}

	RenderingServer.set_default_clear_color(Color(0.18, 0.22, 0.18))
	var scene := Node2D.new()
	root.add_child(scene)
	var colonist := world.get_colonists()[0]
	var tile := Vector2(colonist["x"], colonist["y"]) * ColonistSpritesType.TILE_SIZE
	var outline := ReferenceRect.new()
	outline.position = tile
	outline.size = Vector2.ONE * ColonistSpritesType.TILE_SIZE
	outline.border_color = Color(1, 1, 0, 0.6)
	outline.editor_only = false
	scene.add_child(outline)
	var sprites = ColonistSpritesType.new()
	# Same pack icons map_view.gd hands the sprites (empty without the pack).
	var world_pack := PackAssetsType.world_pack(load(MapViewType.TILE_SET_PATH))
	if not world_pack.is_empty():
		sprites.use_item_icons(PackAssetsType.item_icons(world_pack["tile_set"], TileAtlasMapType.ITEM_ATLAS_MAP))
	scene.add_child(sprites)
	sprites.set_world(world)
	var camera := Camera2D.new()
	camera.position = tile + Vector2.ONE * ColonistSpritesType.TILE_SIZE * 0.5
	camera.zoom = Vector2(ZOOM, ZOOM)
	scene.add_child(camera)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < FRAME_WAIT_COUNT:
		return false
	var image := root.get_texture().get_image()
	if _out == "" or image == null or image.is_empty() or image.save_png(_out) != OK:
		push_error("B6-badge_shot: capture failed (out=%s)" % _out)
		quit(1)
		return true
	print("B6-badge_shot: wrote %s" % _out)
	quit(0)
	return true
