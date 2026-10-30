extends Node2D

## Subtle designation fill: marks every tile with a
## pending order (WorldState.get_jobs() status 'queued' or 'active'), at that
## job's 'target' coordinate. Reads world state only -- never mutates it -- so
## test_viewer_hash.gd's state_hash() comparison stays unaffected by adding
## this node. Independent of map_view's art-mode toggle: orders exist
## regardless of which renderer draws the tiles underneath, so this overlay
## stays visible in both.
##
## B1: incremental. Re-reading and re-drawing every job per refresh cost
## ~0.2 s per tick (and 58k draw calls) after a whole-map order. The fill is
## now one pixel per map cell in a texture drawn scaled, updated only for the
## tiles WorldState.get_designation_changes() reports since the last refresh,
## each pixel stacking OUTLINE_COLOR once per pending job on its tile exactly
## as one rect per job did. site_fetch jobs are the exception (their target
## moves between sources, so the core does not count them): their few targets
## are still read and drawn per refresh.

const WorldStateType = preload("res://scripts/core/world_state.gd")

## Mirrors MapView.TILE_SIZE. Not shared via preload to avoid a preload cycle
## (map_view.gd preloads this script to instantiate the overlay); both must
## be kept in sync if the tile size ever changes.
const TILE_SIZE := 16.0

const PENDING_STATUSES := ["queued", "active"]
const OUTLINE_COLOR := Color(1.0, 0.85, 0.1, 0.20)

var world: WorldStateType
var _cursor := 0
var _image: Image
var _texture: ImageTexture

func set_world(world_ref: WorldStateType) -> void:
	world = world_ref
	_cursor = 0
	_image = null
	if world != null:
		_image = Image.create(maxi(world.get_map_width(), 1), maxi(world.get_map_height(), 1), false, Image.FORMAT_RGBA8)
		_texture = ImageTexture.create_from_image(_image)
	refresh()

func refresh() -> void:
	if world != null and _image != null:
		var changes: Dictionary = world.get_designation_changes(_cursor)
		_cursor = int(changes["next"])
		var tiles: Dictionary = changes["tiles"]
		for tile: Vector3i in tiles:
			if tile.z == TileGrid.SURFACE: # the surface until L4's active layer (ADR 045 §7)
				_image.set_pixel(tile.x, tile.y, fill_color(int(tiles[tile])))
		if not tiles.is_empty():
			_texture.update(_image)
	queue_redraw()

## The colour `count` overlapping OUTLINE_COLOR rects blend to.
static func fill_color(count: int) -> Color:
	if count <= 0:
		return Color(0, 0, 0, 0)
	return Color(OUTLINE_COLOR, 1.0 - pow(1.0 - OUTLINE_COLOR.a, count))

func _draw() -> void:
	if world == null:
		return
	if _texture != null:
		draw_texture_rect(_texture, Rect2(Vector2.ZERO, Vector2(_image.get_size()) * TILE_SIZE), false)
	for job in world.get_jobs(["site_fetch"]):
		if String(job["status"]) not in PENDING_STATUSES:
			continue
		var target: Vector3i = job["target"]
		draw_rect(Rect2(
			target.x * TILE_SIZE,
			target.y * TILE_SIZE,
			TILE_SIZE,
			TILE_SIZE
		), OUTLINE_COLOR, true)
