extends Control

## Renders the seeded map and colonists top-down, two ways: flat coloured
## squares (no art assets, diagnostic) or a TileMapLayer populated from the
## generated placeholder tile set via tile_atlas_map.gd's TILE_ATLAS_MAP (art
## is the default view; Toggle Art switches to the flat-colour
## diagnostic view). Both draw paths stay fully working;
## set_art_enabled()/toggle_art_enabled() switch between them at runtime
## without touching world/tick state, so state_hash() (see
## test_viewer_hash.gd) stays independent of which one is active.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const DesignationOverlayType = preload("res://scripts/viewer/designation_overlay.gd")

const TILE_SIZE := 16.0
const GROUND_ITEM_ICON_SIZE := TILE_SIZE * 0.6

const TILE_SET_PATH := "res://data/tilesets/terrain_tileset.tres"

const TILE_COLORS := {
	"rock": Color(0.32, 0.32, 0.34),
	"soil": Color(0.35, 0.52, 0.24),
	"trench": Color(0.42, 0.25, 0.14),
	"floor": Color(0.78, 0.78, 0.80),
	"hazard": Color(0.82, 0.18, 0.18),
	"tree": Color(0.16, 0.48, 0.20),
	"water": Color(0.16, 0.40, 0.78),
	"plowed_soil": Color(0.45, 0.32, 0.16),
	"planted": Color(0.30, 0.42, 0.18),
}
const UNKNOWN_TILE_COLOR := Color.MAGENTA
const COLONIST_COLOR := Color(1.0, 0.95, 0.15)

## Flat colour-mode fallback for world.get_object(x,y), drawn as an inset
## square over the base tile colour, mirroring TILE_COLORS. Kept in sync with
## TileAtlasMapType.OBJECT_ATLAS_MAP's kinds even though only the atlas
## mapping is required (colonist-ai.md 3.5).
const OBJECT_COLORS := {
	"chair": Color(0.85, 0.45, 0.15),
	"door": Color(0.40, 0.22, 0.08),
	"wall": Color(0.60, 0.60, 0.63),
	"table": Color(0.75, 0.60, 0.35),
	"berry_bush": Color(0.55, 0.15, 0.45),
	"bed": Color(0.70, 0.55, 0.65),
}
const UNKNOWN_OBJECT_COLOR := Color.MAGENTA

## Flat diagnostic colours for ground items and carried cargo. Wood keeps
## its original carried colour and its stockpile icon in both modes.
const CARRIED_ITEM_COLOR := Color(0.55, 0.35, 0.10)
const GROUND_ITEM_COLORS := {
	"wood": CARRIED_ITEM_COLOR,
	"stone": Color("526568"),
}
const STOCKPILE_COUNT_TEXT_COLOR := Color.WHITE
const STOCKPILE_COUNT_FONT_SIZE := 10

var world: WorldStateType

## Emitted once per completed drag (mouse-up), carrying every tile in the
## resulting axis-aligned rectangle in row-major order. A plain click with no
## movement is a 1x1 rectangle through this same signal -- there is no
## separate single-tile path.
signal rectangle_committed(tiles: Array[Vector2i])

## Emitted after a zone-tool drag applies its single zone_add command,
## carrying world.apply()'s own result so a caller
## (or a test) can inspect ok/rejection without polling get_zones() itself.
signal zone_add_committed(result: Dictionary)

## Emitted after the build tool's own click-to-place path
## applies its single `build` command, carrying world.apply()'s own result --
## mirrors zone_add_committed above.
signal build_committed(result: Dictionary)

signal tool_left
var tool_enabled := false
var preview_validity: Callable
var _hover := Vector2i(-1, -1)
var _preview_tiles: Array[Vector2i] = []
var _preview_valid: Array[bool] = []
var _suppress_hover := false
var _dragging: bool = false
var _drag_start: Vector2i = Vector2i.ZERO
var _drag_current: Vector2i = Vector2i.ZERO
## The (tool_enabled, hover/drag rectangle, tick) key _preview_tiles/_preview_valid were last
## computed from, so refresh()'s own once-per-tick _update_preview() call can skip
## preview_validity.call() when nothing that could change the outcome actually changed. Starts
## as a key no real state can produce (7 elements never match the empty Array) so the very first
## _update_preview() call always computes.
var _preview_cache_key: Array = []

## Zone-drawing tool state. boot.gd (game/scripts/boot.gd) owns the shared
## toolbar row and toggles this control's zone mode via
## set_zone_tool_enabled() alongside its other tool buttons, but the drag
## itself reuses only the existing mouse-drag rectangle mechanic
## (_gui_input/_dragging/tiles_in_rectangle) and issues its own direct
## world.apply() call here rather than going through the generic per-tile
## rectangle_committed signal, since a zone is one command per drag, not one
## per tile.
var _zone_tool_enabled: bool = false
var _next_zone_command_id: int = 0

## Build tool state, mirroring the zone tool's own pair of
## fields above: boot.gd toggles _build_tool_enabled alongside its other tool
## buttons and sets _build_kind to whichever object kind that button builds.
## Unlike the zone tool this is a plain click, not a drag rectangle -- one
## `build` command per click, issued directly from _gui_input() below.
var _build_tool_enabled: bool = false
var _build_kind: String = ""
var _build_orientation: String = "horizontal"
var _build_rotatable: bool = false
var _next_build_command_id: int = 0

## Toggle between the TileMapLayer art renderer (default; this is the
## production presentation path -- its incremental refresh is
## what keeps a large map from rebuilding all width*height cells every tick,
## see _refresh_tile_map() below) and the flat-colour draw_rect renderer
## (kept fully working as a fallback for machines/tests with no art assets,
## reachable via the toggle_art_enabled() button). In art mode, colonists are
## supplied by the sprite layer; colour mode keeps the plain draw_rect
## markers for a dependency-free view.
var _art_enabled: bool = true
var _tile_map_layer: TileMapLayer
var _grass_overlay_layer: TileMapLayer
var _object_tile_map_layer: TileMapLayer
var _colonist_sprites: Node2D
var _designation_overlay: Node2D

## Raw-sheet textures cached once per registered item kind.
var _item_atlas_textures: Dictionary = {}

func _init() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(
		WorldStateType.MAP_WIDTH * TILE_SIZE,
		WorldStateType.MAP_HEIGHT * TILE_SIZE
	)
	size = custom_minimum_size
	for kind in TileAtlasMapType.ITEM_ATLAS_MAP:
		_item_atlas_textures[kind] = load(TileAtlasMapType.ITEM_ATLAS_MAP[kind]["texture_path"])
	var tile_set_resource: TileSet = load(TILE_SET_PATH)
	_tile_map_layer = TileMapLayer.new()
	_tile_map_layer.tile_set = tile_set_resource
	_tile_map_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_tile_map_layer.visible = _art_enabled
	# Children draw on top of their parent's _draw() by default, which would
	# cover the colonist draw_rect markers (drawn in this Control's _draw())
	# with the tile textures. show_behind_parent keeps this layer beneath
	# everything the parent draws so the markers stay visible in art mode.
	_tile_map_layer.show_behind_parent = true
	add_child(_tile_map_layer)
	# Grass blob overlay: drawn only over TILE_SOIL
	# cells, on top of the base layer, so a soil tile next to water/rock
	# shows the terrain sheet's own jagged grass edge over the neighbour's
	# plain opaque base cell -- water and rock never carry directional art
	# of their own (see tile_atlas_map.gd's grass_overlay_coords()).
	_grass_overlay_layer = TileMapLayer.new()
	_grass_overlay_layer.tile_set = tile_set_resource
	_grass_overlay_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_grass_overlay_layer.visible = _art_enabled
	_grass_overlay_layer.show_behind_parent = true
	add_child(_grass_overlay_layer)
	_object_tile_map_layer = TileMapLayer.new()
	_object_tile_map_layer.tile_set = tile_set_resource
	_object_tile_map_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_object_tile_map_layer.visible = _art_enabled
	# Added after the terrain/grass layers so an object's or a tile's own
	# decorative sprite (tree canopy, hazard cluster, planted sprout) draws
	# over both; still show_behind_parent so it stays under the colonist
	# markers this Control draws directly in _draw().
	_object_tile_map_layer.show_behind_parent = true
	add_child(_object_tile_map_layer)
	_colonist_sprites = ColonistSpritesType.new()
	_colonist_sprites.set_visible_for_art(_art_enabled)
	add_child(_colonist_sprites)
	# Added last (and never hidden by art mode) so the designation outline is
	# drawn on top of both tile renderers and the colonists, in either mode --
	# orders exist regardless of which renderer is currently active.
	_designation_overlay = DesignationOverlayType.new()
	add_child(_designation_overlay)

## world.get_dirty_cells() is an append-only log, never cleared by WorldState
## itself (test_architecture_rules.gd's viewer-purity rule permits only
## get_*/apply/tick/get_events calls on world from game/scripts/viewer/*.gd,
## so this Control tracks its own already-consumed prefix length instead of
## asking WorldState to drain it -- mirroring how a get_events() consumer
## would track a sequence cursor).
var _dirty_cells_consumed: int = 0

## Hands the shared TickDriver to the colonist sprite layer, so
## its advance() can read seconds_per_tick() for glide timing. boot.gd calls
## this once both are constructed; no other map_view.gd behaviour changes.
func set_tick_driver(driver) -> void:
	_colonist_sprites.set_tick_driver(driver)

func set_world(world_ref: WorldStateType) -> void:
	cancel_selection()
	world = world_ref
	_resize_for_world()
	_colonist_sprites.set_world(world_ref)
	_designation_overlay.set_world(world_ref)
	# Skip straight past the log's current length: the full rebuild below
	# already covers everything recorded so far, so none of it needs to be
	# replayed as an incremental touch later.
	_dirty_cells_consumed = world.get_dirty_cells().size() if world != null else 0
	_refresh_tile_map(true)
	queue_redraw()

## Sizes this Control to the attached world's own dimensions: a
## loaded/newly generated world need not be the 48x48 fixture default, and
## map_viewport.gd's pan/zoom bounds (_constrain()) read this Control's own
## `size`, so it must reflect whichever world is actually live.
func _resize_for_world() -> void:
	var width: int = world.get_map_width() if world != null else WorldStateType.MAP_WIDTH
	var height: int = world.get_map_height() if world != null else WorldStateType.MAP_HEIGHT
	custom_minimum_size = Vector2(width * TILE_SIZE, height * TILE_SIZE)
	size = custom_minimum_size

## Re-syncs both draw paths with the current world state. boot.gd calls this
## once per tick instead of queue_redraw() directly so the TileMapLayer picks
## up tile changes (e.g. a dig turning rock into floor) exactly like the
## flat-colour path already does by re-reading world.get_tiles() every draw.
func refresh() -> void:
	_update_preview()
	_refresh_tile_map(false)
	_colonist_sprites.refresh()
	_designation_overlay.refresh()
	queue_redraw()

## Flips between the two renderers without rebuilding the world. Safe to call
## at any time, including before set_world().
func set_art_enabled(enabled: bool) -> void:
	_art_enabled = enabled
	_tile_map_layer.visible = enabled
	_grass_overlay_layer.visible = enabled
	_object_tile_map_layer.visible = enabled
	_colonist_sprites.set_visible_for_art(enabled)
	_refresh_tile_map(true)
	queue_redraw()

func toggle_art_enabled() -> void:
	set_art_enabled(not _art_enabled)

func is_art_enabled() -> bool:
	return _art_enabled

## Selects between the generic rectangle_committed signal (dig,
## chop, cancel, remove-object, wall -- boot.gd submits walls as one
## build_line batch and other tools per tile) and this control's own single
## zone_add-per-drag path. boot.gd calls
## this from its zone toolbar button and disables it again whenever another
## toolbar tool is selected. Independent of art mode; safe to call before or
## after set_world().
func set_zone_tool_enabled(enabled: bool) -> void:
	_zone_tool_enabled = enabled

func toggle_zone_tool_enabled() -> void:
	set_zone_tool_enabled(not _zone_tool_enabled)

func is_zone_tool_enabled() -> bool:
	return _zone_tool_enabled

## Selects the build tool's own click-to-place path in _gui_input() below,
## mirroring set_zone_tool_enabled() above. boot.gd calls this from its build
## toolbar buttons and disables it again whenever another tool is selected.
func set_build_tool_enabled(enabled: bool) -> void:
	_build_tool_enabled = enabled

func is_build_tool_enabled() -> bool:
	return _build_tool_enabled

## The content/objects.json kind the next build click submits -- boot.gd sets
## this alongside set_build_tool_enabled(true) when a specific build button
## (Door/Bed/Workbench) is pressed. Walls use the rectangle signal instead;
## their kind also invalidates the cached rectangle preview.
func set_build_kind(kind: String) -> void:
	_build_kind = kind
	_build_orientation = "horizontal"
	_preview_cache_key = []
	queue_redraw()

func set_build_rotatable(rotatable: bool) -> void:
	_build_rotatable = rotatable
	if not rotatable:
		_build_orientation = "horizontal"
	_preview_cache_key = []
	queue_redraw()

func get_build_orientation() -> String:
	return _build_orientation

func is_build_vertical() -> bool:
	return _build_orientation == "vertical"

func toggle_build_orientation() -> void:
	if not _build_tool_enabled or not _build_rotatable:
		return
	_build_orientation = "vertical" if _build_orientation == "horizontal" else "horizontal"
	_preview_cache_key = []
	_update_preview()
	queue_redraw()

func tile_at_local(local_position: Vector2) -> Vector2i:
	return Vector2i(floori(local_position.x / TILE_SIZE), floori(local_position.y / TILE_SIZE))

## Every tile inside the axis-aligned rectangle with corners `start` and
## `end`, both inclusive, in row-major order (ascending y, then ascending x)
## -- the codebase's existing tie-break convention (see colonist_panel.gd's
## and job_queue.gd's own id-ordered tie-breaks).
static func tiles_in_rectangle(start: Vector2i, end: Vector2i) -> Array[Vector2i]:
	var min_x := mini(start.x, end.x)
	var max_x := maxi(start.x, end.x)
	var min_y := mini(start.y, end.y)
	var max_y := maxi(start.y, end.y)
	var tiles: Array[Vector2i] = []
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			tiles.append(Vector2i(x, y))
	return tiles

func set_tool_enabled(enabled: bool) -> void:
	cancel_selection()
	tool_enabled = enabled
	_suppress_hover = false

func leave_tool() -> void:
	set_tool_enabled(false)
	tool_left.emit()

func clear_hover() -> void:
	_hover = Vector2i(-1, -1)
	if not _dragging:
		_update_preview()

func cancel_selection() -> void:
	_dragging = false
	_hover = Vector2i(-1, -1)
	_preview_tiles.clear()
	_preview_valid.clear()
	_suppress_hover = true
	# Cleared directly above rather than through _update_preview(), so drop the cache key too:
	# an unrelated later key that happens to match the pre-cancel one (e.g. after set_world()
	# swaps to a different world) must never skip a recompute and leave a stale preview.
	_preview_cache_key = []
	queue_redraw()

func _inside(tile: Vector2i) -> bool:
	var width: int = world.get_map_width() if world != null else WorldStateType.MAP_WIDTH
	var height: int = world.get_map_height() if world != null else WorldStateType.MAP_HEIGHT
	return tile.x >= 0 and tile.y >= 0 and tile.x < width and tile.y < height

func _bounded(tile: Vector2i) -> Vector2i:
	var width: int = world.get_map_width() if world != null else WorldStateType.MAP_WIDTH
	var height: int = world.get_map_height() if world != null else WorldStateType.MAP_HEIGHT
	return tile.clamp(Vector2i.ZERO, Vector2i(width - 1, height - 1))

## Recomputes _preview_tiles/_preview_valid only when the key above actually changed --
## called once per tick from refresh() (where the hover/drag rectangle is almost always
## unchanged) as well as directly from _gui_input on a real hover/drag change, so the direct
## calls still recompute immediately while refresh()'s own repeats are free.
func _update_preview() -> void:
	var key := _current_preview_key()
	if key == _preview_cache_key:
		return
	_preview_cache_key = key
	_preview_tiles.clear()
	_preview_valid.clear()
	if tool_enabled:
		var next_preview_tiles: Array[Vector2i] = []
		if _dragging:
			next_preview_tiles = tiles_in_rectangle(_drag_start, _drag_current)
		elif not _suppress_hover and _inside(_hover):
			if _build_tool_enabled:
				next_preview_tiles = _build_footprint_tiles(_hover)
			else:
				next_preview_tiles.append(_hover)
		_preview_tiles = next_preview_tiles
	if not _preview_tiles.is_empty() and preview_validity.is_valid():
		_preview_valid = preview_validity.call(_preview_tiles)
	queue_redraw()

## The inputs that determine _preview_tiles/_preview_valid: tool_enabled, the hover/drag
## rectangle, and the world's tick (a command's validity can depend on state a tick just
## changed, e.g. a dig target another colonist just finished). Array equality is element-wise
## in GDScript, so two keys with the same values compare equal without a hand-rolled hash.
func _current_preview_key() -> Array:
	var tick := world.get_tick() if world != null else -1
	return [tool_enabled, _dragging, _drag_start, _drag_current, _hover, _suppress_hover, tick, _build_kind, _build_orientation]

func _build_footprint_tiles(origin: Vector2i) -> Array[Vector2i]:
	if _build_kind == "workbench" and _build_orientation == "vertical":
		return [origin, origin + Vector2i.DOWN]
	if _build_kind == "workbench":
		return [origin, origin + Vector2i.RIGHT]
	return [origin]

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		toggle_build_orientation()

func _gui_input(event: InputEvent) -> void:
	if not tool_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var tile := tile_at_local(event.position)
			if not _inside(tile):
				return
			if _build_tool_enabled:
				_commit_build(tile)
				return
			_dragging = true
			_drag_start = tile
			_drag_current = tile
			_update_preview()
		elif _dragging:
			_drag_current = _bounded(tile_at_local(event.position))
			if _zone_tool_enabled:
				_commit_zone(_drag_start, _drag_current)
			else:
				rectangle_committed.emit(tiles_in_rectangle(_drag_start, _drag_current))
			cancel_selection()
	elif event is InputEventMouseMotion:
		var tile := tile_at_local(event.position)
		var changed := tile != _hover or _suppress_hover
		_hover = tile
		_suppress_hover = false
		if _dragging:
			_drag_current = _bounded(tile)
		if changed:
			_update_preview()

## Reuses the same drag-rectangle mechanic as the generic dig/chop path above
## (_dragging/_drag_start/_drag_current, and the same min/max corner math as
## tiles_in_rectangle()) but issues exactly one zone_add command for the
## whole rectangle instead of one command per tile, matching
## WorldState._apply_zone_add_command()'s {x, y, width, height} payload
## (see test_zone_commands.gd). A no-op when world is unset.
func _commit_zone(start: Vector2i, end: Vector2i) -> void:
	if world == null:
		return
	var min_x := mini(start.x, end.x)
	var max_x := maxi(start.x, end.x)
	var min_y := mini(start.y, end.y)
	var max_y := maxi(start.y, end.y)
	_next_zone_command_id += 1
	var command := {
		"actor": "player",
		"command_id": "viewer_zone_add_%d_%d" % [world.get_tick(), _next_zone_command_id],
		"tick": world.get_tick(),
		"type": "zone_add",
		"payload": {"x": min_x, "y": min_y, "width": max_x - min_x + 1, "height": max_y - min_y + 1},
	}
	var result: Dictionary = world.apply(command)
	zone_add_committed.emit(result)
	refresh()

## Build tool's own click-to-place path, mirroring
## _commit_zone() above but for a single tile and a `build` command instead of
## a drag rectangle and `zone_add`. A no-op when world is unset.
##
## _current_preview_key() includes world.get_tick(), which a
## successful build command does not advance -- while paused, the hovered
## tile's key is otherwise unchanged before and after this call, so
## refresh()'s _update_preview() would skip the recompute and keep showing
## the pre-claim validity (e.g. still green) for the site this click just
## reserved. Clearing the cache key forces refresh() to recompute regardless.
func _commit_build(tile: Vector2i) -> void:
	if world == null:
		return
	_next_build_command_id += 1
	var command := {
		"actor": "player",
		"command_id": "viewer_build_%d_%d" % [world.get_tick(), _next_build_command_id],
		"tick": world.get_tick(),
		"type": "build",
		"payload": {"kind": _build_kind, "x": tile.x, "y": tile.y, "orientation": _build_orientation if _build_rotatable else ""},
	}
	var result: Dictionary = world.apply(command)
	build_committed.emit(result)
	_preview_cache_key = []
	refresh()

## Number of TileMapLayer cells actually touched by the most recent
## _refresh_tile_map() call (instrumentation): a full rebuild
## touches every cell, an incremental refresh touches only the cells newly
## appended to world.get_dirty_cells() since the last call.
## test_map_view_incremental.gd asserts this stays far below width*height on
## a tick with no terrain change, instead of the whole TileMapLayer being
## cleared and rebuilt every tick.
var last_tile_map_cells_touched: int = 0

## Populates the TileMapLayer from world state via TILE_ATLAS_MAP. A no-op
## while art is disabled, so toggling to colour mode leaves the layer's last
## contents untouched (it is hidden, not drawn) instead of doing wasted work
## every tick. `force_full` rebuilds every cell (set_world(), an art-mode
## toggle); otherwise only the newly-appended tail of world.get_dirty_cells()
## (see _dirty_cells_consumed above) is touched, so a tick with no dig/chop/
## forage/till/sow/place_object/remove_object never reconstructs the whole
## map (65536 cells on a 256x256 world).
func _refresh_tile_map(force_full: bool) -> void:
	if not _art_enabled or world == null:
		return
	if force_full:
		_tile_map_layer.clear()
		_grass_overlay_layer.clear()
		_object_tile_map_layer.clear()
		var tiles: Array[String] = world.get_tiles()
		var width: int = world.get_map_width()
		var height: int = world.get_map_height()
		var touched := 0
		for y in height:
			for x in width:
				var kind: String = tiles[y * width + x]
				_set_tile_map_cell(x, y, kind)
				_set_decor_or_object_cell(x, y, kind, "")
				touched += 1
		for object_entry in world.get_objects():
			var ox: int = int(object_entry["x"])
			var oy: int = int(object_entry["y"])
			_set_decor_or_object_cell(ox, oy, tiles[oy * width + ox], String(object_entry["kind"]))
			touched += 1
		last_tile_map_cells_touched = touched
		_dirty_cells_consumed = world.get_dirty_cells().size()
		return
	var dirty_log := world.get_dirty_cells()
	var touched := 0
	for i in range(_dirty_cells_consumed, dirty_log.size()):
		var cell: Vector2i = dirty_log[i]
		var kind := world.get_tile(cell.x, cell.y)
		_set_tile_map_cell(cell.x, cell.y, kind)
		_set_decor_or_object_cell(cell.x, cell.y, kind, world.get_object(cell.x, cell.y))
		# A dirty cell can flip a neighbouring TILE_SOIL cell's shore
		# selection -- both its overlay blob shape and its base-layer backing
		# material -- without that neighbour itself being marked dirty (e.g. a
		# dig turns a rock tile into floor, exposing a straight prairie edge
		# next to it where a corner used to be); re-resolve the full layered
		# cell (_set_soil_cell(), not just the overlay) of all 8
		# orthogonal+diagonal neighbours that are themselves TILE_SOIL.
		# Diagonal neighbours matter since a concave-corner cell depends on
		# its diagonal neighbour's kind, not just its 4 orthogonal ones.
		for offset in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
				Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
			var neighbor: Vector2i = cell + offset
			if not _inside(neighbor):
				continue
			if world.get_tile(neighbor.x, neighbor.y) == WorldStateType.TILE_SOIL:
				_set_soil_cell(neighbor.x, neighbor.y)
		touched += 1
	_dirty_cells_consumed = dirty_log.size()
	last_tile_map_cells_touched = touched

## Base terrain cell: TILE_ATLAS_MAP's plain/opaque entry for `kind`, except
## for a boundary TILE_SOIL cell (one with a water/rock neighbour), which
## instead gets that neighbour's own plain water/rock cell as its *backing*
## -- see _set_soil_cell() below for why. Water and rock tiles themselves
## never carry directional art of their own (see tile_atlas_map.gd's module
## comment). Also resolves the grass overlay.
func _set_tile_map_cell(x: int, y: int, kind: String) -> void:
	if kind == WorldStateType.TILE_SOIL:
		_set_soil_cell(x, y)
		return
	var coords_pos := Vector2i(x, y)
	var atlas = TileAtlasMapType.TILE_ATLAS_MAP.get(kind)
	if atlas == null:
		_tile_map_layer.erase_cell(coords_pos)
	else:
		_tile_map_layer.set_cell(coords_pos, int(atlas["source_id"]), atlas["coords"])
	_grass_overlay_layer.erase_cell(coords_pos)

## A TILE_SOIL cell's neighbour-driven layered composition.
## tile_atlas_map.gd's grass_shore_selection() resolves this
## cell's 8 neighbours to at most one shape ("edge"/"corner"/"concave") and
## direction, shared by two lookups that must always agree:
##   - the overlay cell (grass_overlay_coords()): the terrain sheet's own
##     transparent-bordered grass blob shape for that direction, drawn on
##     _grass_overlay_layer, on top;
##   - the base cell (_grass_backing_kind() below, via
##     grass_shore_backing_offsets()): the single actual water/rock
##     neighbour that shape's alpha is supposed to expose, drawn as that
##     material's own plain opaque cell on _tile_map_layer, underneath.
## An opaque grass fill under every soil cell would instead make the blob's
## transparent pixels reveal only more grass, never the neighbouring
## water/rock. A fully interior cell (no foreign neighbour) has no
## selection, so it keeps a plain hash-selected grass fill with no overlay.
func _set_soil_cell(x: int, y: int) -> void:
	var coords_pos := Vector2i(x, y)
	var selection := TileAtlasMapType.grass_shore_selection(
		_is_shore_neighbor(x, y - 1), _is_shore_neighbor(x, y + 1),
		_is_shore_neighbor(x + 1, y), _is_shore_neighbor(x - 1, y),
		_is_shore_neighbor(x + 1, y - 1), _is_shore_neighbor(x - 1, y - 1),
		_is_shore_neighbor(x + 1, y + 1), _is_shore_neighbor(x - 1, y + 1))
	if selection.is_empty():
		var atlas = TileAtlasMapType.TILE_ATLAS_MAP[WorldStateType.TILE_SOIL]
		_tile_map_layer.set_cell(coords_pos, int(atlas["source_id"]), _grass_variant_coords(x, y))
		_grass_overlay_layer.erase_cell(coords_pos)
		return
	var backing_kind := _grass_backing_kind(x, y, selection)
	var backing_atlas = TileAtlasMapType.TILE_ATLAS_MAP[backing_kind]
	_tile_map_layer.set_cell(coords_pos, int(backing_atlas["source_id"]), backing_atlas["coords"])
	_grass_overlay_layer.set_cell(coords_pos, TileAtlasMapType.SOURCE_FLOORS, TileAtlasMapType.grass_overlay_coords_for_selection(selection))

## The single water/rock neighbour a boundary soil cell's blob shape must
## expose as its base-layer backing, deterministically chosen by trying
## grass_shore_backing_offsets()' priority-ordered neighbour offsets in order
## and returning the first that is actually water or rock -- so a corner
## shape whose two represented sides are mixed materials (one water, one
## rock) still resolves to exactly one backing cell instead of an undefined
## pick. Falls back to TILE_WATER only if none of the offsets are foreign,
## which cannot happen for a non-empty selection (grass_shore_selection()
## only returns one when at least one represented neighbour is foreign).
func _grass_backing_kind(x: int, y: int, selection: Dictionary) -> String:
	for offset in TileAtlasMapType.grass_shore_backing_offsets(selection):
		var neighbor: Vector2i = Vector2i(x, y) + (offset as Vector2i)
		if not _inside(neighbor):
			continue
		var kind := world.get_tile(neighbor.x, neighbor.y)
		if kind == WorldStateType.TILE_WATER or kind == WorldStateType.TILE_ROCK:
			return kind
	return WorldStateType.TILE_WATER

## True when (x,y) is inside the map and TILE_WATER or TILE_ROCK -- the
## "foreign neighbour" predicate for the grass overlay above. Out-of-bounds
## is never foreign: a prairie tile at the map edge with no water/rock
## neighbour is plain interior, not an invented edge against nothing.
func _is_shore_neighbor(x: int, y: int) -> bool:
	if not _inside(Vector2i(x, y)):
		return false
	var kind := world.get_tile(x, y)
	return kind == WorldStateType.TILE_WATER or kind == WorldStateType.TILE_ROCK

## Discrete prairie variant, chosen by hash(seed, x, y), never by frame --
## a pure function of the
## world's seed and the cell's own coordinates, so it is stable across pan,
## zoom, save and load, and never changes on its own between redraws.
func _grass_variant_coords(x: int, y: int) -> Vector2i:
	var variants := TileAtlasMapType.TILE_SOIL_VARIANTS
	var seed_value: int = world.get_seed() if world != null else 0
	var key := "%d:%d:%d" % [seed_value, x, y]
	var index: int = key.hash() % variants.size()
	return variants[index]

## Object/decor layer cell: an actual placed object (`object_kind`, from
## world.get_objects()/get_object()) takes priority when present; otherwise
## a tile kind with its own decorative sprite (tree canopy, hazard cluster,
## planted sprout -- see tile_atlas_map.gd's TILE_DECOR_MAP) draws one;
## otherwise the cell is cleared. `object_kind == ""` means no placed object
## (e.g. during an incremental refresh after remove_object, or a forage
## clearing its berry_bush) so this falls through to the tile's own decor, if any.
func _set_decor_or_object_cell(x: int, y: int, tile_kind: String, object_kind: String) -> void:
	var coords := Vector2i(x, y)
	if not object_kind.is_empty():
		var object_atlas = TileAtlasMapType.OBJECT_ATLAS_MAP.get(object_kind)
		if object_atlas != null:
			_object_tile_map_layer.set_cell(coords, int(object_atlas["source_id"]), object_atlas["coords"])
			return
	var decor = TileAtlasMapType.TILE_DECOR_MAP.get(tile_kind)
	if decor != null:
		_object_tile_map_layer.set_cell(coords, int(decor["source_id"]), decor["coords"])
		return
	_object_tile_map_layer.erase_cell(coords)

func _draw() -> void:
	if world == null:
		return
	if not _art_enabled:
		var tiles: Array[String] = world.get_tiles()
		var width: int = world.get_map_width()
		for y in world.get_map_height():
			for x in width:
				var kind: String = tiles[y * width + x]
				var color: Color = TILE_COLORS.get(kind, UNKNOWN_TILE_COLOR)
				draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color, true)
		# Drawn once for the whole map, never inside the row loop above:
		# world.get_objects() is O(objects), and iterating it once per row
		# would make this O(height * objects).
		var object_inset := TILE_SIZE * 0.1
		for object_entry in world.get_objects():
			var object_color: Color = OBJECT_COLORS.get(String(object_entry["kind"]), UNKNOWN_OBJECT_COLOR)
			draw_rect(Rect2(
				int(object_entry["x"]) * TILE_SIZE + object_inset,
				int(object_entry["y"]) * TILE_SIZE + object_inset,
				TILE_SIZE - object_inset * 2.0,
				TILE_SIZE - object_inset * 2.0
			), object_color, true)
	if not _art_enabled:
		var inset := TILE_SIZE * 0.2
		for colonist in world.get_colonists():
			draw_rect(Rect2(
				colonist["x"] * TILE_SIZE + inset,
				colonist["y"] * TILE_SIZE + inset,
				TILE_SIZE - inset * 2.0,
				TILE_SIZE - inset * 2.0
			), COLONIST_COLOR, true)
			# Colour-mode carried-item marker.
			# The art-mode equivalent lives in colonist_sprites.gd, layered
			# onto the colonist's own AnimatedSprite2D so it renders on top
			# of the sprite in art mode instead of underneath it.
			if colonist.get("carrying") != null:
				var marker_size := TILE_SIZE * 0.35
				draw_rect(Rect2(
					colonist["x"] * TILE_SIZE + TILE_SIZE - marker_size,
					colonist["y"] * TILE_SIZE,
					marker_size,
					marker_size
				), GROUND_ITEM_COLORS.get(String(colonist["carrying"]["kind"]), Color.MAGENTA), true)
	_draw_stockpile_counts()
	_draw_construction_sites()
	for i in _preview_tiles.size():
		var tile := _preview_tiles[i]
		var valid := i < _preview_valid.size() and _preview_valid[i]
		var color := Color(0.3, 1.0, 0.55) if valid else Color(1.0, 0.3, 0.3)
		var rect := Rect2(Vector2(tile) * TILE_SIZE, Vector2.ONE * TILE_SIZE)
		draw_rect(rect, Color(color, 0.22), true)
		draw_rect(rect, color, false, 1.0)
		if not valid:
			draw_line(rect.position + Vector2(3, 3), rect.end - Vector2(3, 3), color, 1.0)

func _draw_construction_sites() -> void:
	for site in world.get_construction_sites():
		var origin := Vector2i(site["origin"])
		var orientation := String(site.get("orientation", "horizontal"))
		var kind := String(site["kind"])
		var size := Vector2i(2, 1) if kind == "workbench" and orientation != "vertical" else Vector2i(1, 2) if kind == "workbench" else Vector2i.ONE
		var footprint_rect := Rect2(Vector2(origin) * TILE_SIZE, Vector2(size) * TILE_SIZE)
		# A vertical-orientation kind with its own dedicated atlas
		# entry (e.g. "workbench_vertical") draws that real art directly, at
		# its own real size/grounding -- no synthetic 90-degree rotation of
		# the horizontal crop. Falls back to the
		# plain kind key when no dedicated vertical entry is registered yet.
		var vertical_key := kind + "_vertical"
		var atlas_key := vertical_key if orientation == "vertical" and TileAtlasMapType.OBJECT_ATLAS_MAP.has(vertical_key) else kind
		var atlas: Dictionary = TileAtlasMapType.OBJECT_ATLAS_MAP.get(atlas_key, {})
		if atlas.is_empty() or _tile_map_layer.tile_set.get_source(int(atlas["source_id"])) == null:
			continue
		var source := _tile_map_layer.tile_set.get_source(int(atlas["source_id"])) as TileSetAtlasSource
		var texture := source.texture
		var region := Rect2(Vector2(atlas["coords"]) * Vector2(source.texture_region_size), Vector2(source.texture_region_size))
		var sprite_size := region.size
		var tile_data := source.get_tile_data(atlas["coords"], 0)
		var texture_origin := Vector2(tile_data.texture_origin)
		var footprint_center := footprint_rect.get_center()
		var sprite_rect := Rect2(footprint_center - sprite_size / 2.0 - texture_origin, sprite_size)
		draw_texture_rect_region(texture, sprite_rect, region, Color(1.0, 1.0, 1.0, 0.5))
		var sprite_top := sprite_rect.position.y
		var progress := clampf(float(site.get("progress", 0)) / maxf(1.0, float(site.get("build_ticks", 1))), 0.0, 1.0)
		var bar_rect := Rect2(Vector2(footprint_center.x - 16.0, sprite_top - TILE_SIZE), Vector2(32.0, 3.0))
		draw_rect(bar_rect, Color(0.18, 0.12, 0.12, 0.9), true)
		draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * progress, bar_rect.size.y)), Color(0.35, 0.95, 0.45, 0.95), true)

## Sum the generic ground-item snapshot once, never scan all items per cell.
## Carried cargo is absent from get_items() and cannot inflate these counts.
func _ground_item_counts() -> Dictionary:
	var counts := {}
	for item in world.get_items():
		var kind := String(item["kind"])
		if not TileAtlasMapType.ITEM_ATLAS_MAP.has(kind):
			continue
		var cell := Vector2i(int(item["x"]), int(item["y"]))
		if not counts.has(cell):
			counts[cell] = {}
		counts[cell][kind] = int(counts[cell].get(kind, 0)) + int(item["count"])
	for item in world.get_tool_items():
		var location: Dictionary = item["location"]
		if location["type"] != "ground":
			continue
		var kind := String(item["kind"])
		if not TileAtlasMapType.ITEM_ATLAS_MAP.has(kind):
			continue
		var cell := Vector2i(int(location["x"]), int(location["y"]))
		if not counts.has(cell):
			counts[cell] = {}
		counts[cell][kind] = int(counts[cell].get(kind, 0)) + 1
	return counts

## Wood retains its original icon, dimensions, origin and count baseline in
## both modes. Additional kinds occupy subsequent rows only on mixed cells.
func _draw_stockpile_counts() -> void:
	var counts := _ground_item_counts()
	var font := ThemeDB.fallback_font
	var icon_size := GROUND_ITEM_ICON_SIZE
	for zone in world.get_zones():
		var zx: int = zone["x"]
		var zy: int = zone["y"]
		var zw: int = zone["width"]
		var zh: int = zone["height"]
		for y in range(zy, zy + zh):
			for x in range(zx, zx + zw):
				var cell_counts: Dictionary = counts.get(Vector2i(x, y), {})
				var row := 0
				for kind in TileAtlasMapType.ITEM_ATLAS_MAP:
					var count := int(cell_counts.get(kind, 0))
					if count <= 0:
						continue
					var atlas: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP[kind]
					var origin := Vector2(x * TILE_SIZE, y * TILE_SIZE + row * TILE_SIZE)
					var icon_rect := Rect2(origin, Vector2(icon_size, icon_size))
					if _art_enabled or kind == "wood":
						draw_texture_rect_region(_item_atlas_textures[kind], icon_rect, atlas["rect"])
					else:
						draw_rect(icon_rect, GROUND_ITEM_COLORS.get(kind, Color.MAGENTA), true)
					draw_string(font, origin + Vector2(icon_size + 1.0, TILE_SIZE - 2.0), str(count),
						HORIZONTAL_ALIGNMENT_LEFT, -1, STOCKPILE_COUNT_FONT_SIZE, STOCKPILE_COUNT_TEXT_COLOR)
					row += 1
