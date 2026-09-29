const WorldStateType = preload("res://scripts/core/world_state.gd")

## Maps tile, object, item and actor kinds onto the TileSetAtlasSources in
## game/data/tilesets/terrain_tileset.tres (built by
## scripts/tools/build_terrain_tileset.gd from the generated placeholder art in
## game/assets/generated/). Source ids and coords here must match that builder.
##
## Shorelines are not directional water/rock cells. Water and rock always
## render as their own plain, fully opaque base cell; the jagged edge comes
## from a second TileMapLayer that draws a 12-cell grass "blob" (4 edges, 4
## convex corners, 4 concave corners) over every boundary TILE_SOIL cell,
## chosen from its 8 neighbours by grass_shore_selection() below. map_view.gd
## uses the same selection to pick both the overlay shape and the single
## water/rock cell painted underneath, so the overlay's transparent pixels
## always reveal the right material.
const SOURCE_FLOORS := 0
const SOURCE_WATER := 1
const SOURCE_ROCK := 2
const SOURCE_WALL := 3
const SOURCE_CHAIR := 4
const SOURCE_TABLE := 5
const SOURCE_BED := 6
const SOURCE_DOOR := 7
const SOURCE_BERRY_BUSH := 8
const SOURCE_SPROUT := 9
const SOURCE_TREE := 10
## Resources sheet: hazard cluster (0,0), stone (1,0), wood (2,0), 32x20 cells.
const SOURCE_HAZARD := 11
## Horizontal (2x1 footprint) workbench, 32x28, grounded on its footprint.
const SOURCE_WORKBENCH := 12
## Vertical (1x2 footprint) workbench, 16x44, grounded against its 32px
## two-tile footprint.
const SOURCE_WORKBENCH_VERTICAL := 13
## Tool icons: pick (0,0), axe (1,0), 16x16 cells.
const SOURCE_TOOLS := 14
## 16x16 stone wall at local (0,0), like SOURCE_WALL, so construction ghosts
## and TileMapLayer cells sample the same pixels (ghosts ignore margins).
const SOURCE_STONE_WALL := 15

const ART_DIR := "res://assets/generated/"

## Base terrain cell per tile kind -- always a plain, fully opaque cell
## (test_tile_atlas_map.gd's opacity check). TILE_HAZARD/TILE_TREE/
## TILE_PLANTED get their own opaque ground as a base; their cluster/canopy/
## sprout artwork is a separate decor sprite on the object layer (see
## TILE_DECOR_MAP below).
const TILE_ATLAS_MAP: Dictionary = {
	WorldStateType.TILE_ROCK: {"source_id": SOURCE_ROCK, "coords": Vector2i(0, 0)},
	WorldStateType.TILE_SOIL: {"source_id": SOURCE_FLOORS, "coords": Vector2i(0, 5)},
	WorldStateType.TILE_FLOOR: {"source_id": SOURCE_FLOORS, "coords": Vector2i(4, 5)},
	WorldStateType.TILE_HAZARD: {"source_id": SOURCE_FLOORS, "coords": Vector2i(2, 6)},
	WorldStateType.TILE_TREE: {"source_id": SOURCE_FLOORS, "coords": Vector2i(3, 6)},
	WorldStateType.TILE_WATER: {"source_id": SOURCE_WATER, "coords": Vector2i(0, 0)},
	WorldStateType.TILE_PLOWED_SOIL: {"source_id": SOURCE_FLOORS, "coords": Vector2i(0, 6)},
	WorldStateType.TILE_PLANTED: {"source_id": SOURCE_FLOORS, "coords": Vector2i(1, 6)},
	WorldStateType.TILE_TRENCH: {"source_id": SOURCE_FLOORS, "coords": Vector2i(3, 5)},
}

## Discrete grass variants for TILE_SOIL, chosen by hash(seed, x, y) -- never
## by frame. map_view.gd indexes this with hash % size(); index 0 doubles as
## TILE_ATLAS_MAP's own TILE_SOIL default above.
const TILE_SOIL_VARIANTS: Array[Vector2i] = [
	Vector2i(0, 5),
	Vector2i(1, 5),
	Vector2i(2, 5),
]

## Decorative sprite drawn on the object layer, over a tile kind's opaque
## base cell. Excluded from the opacity check: the transparent margin around
## a cluster/canopy/sprout is intended.
const TILE_DECOR_MAP: Dictionary = {
	WorldStateType.TILE_HAZARD: {"source_id": SOURCE_HAZARD, "coords": Vector2i(0, 0)},
	WorldStateType.TILE_TREE: {"source_id": SOURCE_TREE, "coords": Vector2i(0, 0)},
	WorldStateType.TILE_PLANTED: {"source_id": SOURCE_SPROUT, "coords": Vector2i(0, 0)},
}

## Grass blob edges, keyed by the side the foreign (water/rock) neighbour is
## on: that side of the cell is transparent. test_tile_atlas_map.gd re-derives
## each direction from the pixels themselves.
const GRASS_EDGE_COORDS: Dictionary = {
	"N": Vector2i(2, 4),
	"S": Vector2i(2, 0),
	"E": Vector2i(0, 2),
	"W": Vector2i(4, 2),
}

## Grass blob convex corners: two adjacent orthogonal neighbours are foreign,
## so grass is absent from both of those edges.
const GRASS_CORNER_COORDS: Dictionary = {
	"NE": Vector2i(1, 3),
	"NW": Vector2i(3, 3),
	"SE": Vector2i(1, 1),
	"SW": Vector2i(3, 1),
}

## Grass blob concave corners: both orthogonal neighbours on that corner are
## soil but the diagonal one is foreign, so only a small corner bite is missing.
const GRASS_CONCAVE_COORDS: Dictionary = {
	"NE": Vector2i(1, 4),
	"NW": Vector2i(3, 4),
	"SE": Vector2i(1, 0),
	"SW": Vector2i(3, 0),
}

const ATLAS_CELL_SIZE := 16
const ATLAS_CELL_STRIDE := 16

## Shared priority table behind both grass_overlay_coords() (which of the 13
## blob shapes a boundary TILE_SOIL cell shows) and map_view.gd's backing-
## material selection (which single opaque water/rock cell that shape's alpha
## must reveal underneath) -- factored out so the two can never disagree
## about which single foreign side/corner a cell's blob shape represents
## (otherwise the base layer and the overlay could pick their
## directions independently, so the overlay's alpha never lined up with an
## actual foreign-material cell underneath).
##
## Returns {} when no neighbour is foreign (fully interior: the base layer's
## own full-fill grass cell already covers it, no overlay/backing needed).
## Otherwise returns {"shape": "edge"|"corner"|"concave", "dir": one of
## "N"/"S"/"E"/"W"/"NE"/"NW"/"SE"/"SW"}.
##
## Documented approximation (the art
## ships exactly this 13-cell blob -- 4 edges, 4 convex corners, 4 concave
## corners, full -- not a full 47-tile Wang set, so there is no dedicated art
## for two opposite exposed sides (a channel), three exposed sides (a cap) or
## all four (an isolated tile). Each of those approximates to the *nearest*
## already-real cell instead of being synthesized: a channel (2 opposite
## sides foreign) shows the edge of whichever side wins compass priority
## N > E > S > W; a cap (3 sides foreign) and an isolated tile (4 sides
## foreign) show the convex corner of whichever *adjacent* pair of foreign
## sides wins the same priority. This never invents a new shape -- every
## selection names one of the 12 directional cells above, chosen for
## plausibility, not drawn for the occasion.
static func grass_shore_selection(n: bool, s: bool, e: bool, w: bool, ne: bool, nw: bool, se: bool, sw: bool) -> Dictionary:
	var count := int(n) + int(s) + int(e) + int(w)
	if count == 0:
		if ne:
			return {"shape": "concave", "dir": "NE"}
		if nw:
			return {"shape": "concave", "dir": "NW"}
		if se:
			return {"shape": "concave", "dir": "SE"}
		if sw:
			return {"shape": "concave", "dir": "SW"}
		return {}
	if count == 1:
		if n:
			return {"shape": "edge", "dir": "N"}
		if e:
			return {"shape": "edge", "dir": "E"}
		if s:
			return {"shape": "edge", "dir": "S"}
		return {"shape": "edge", "dir": "W"}
	if count == 2 and ((n and s) or (e and w)):
		# Opposite sides (channel): approximate with the higher-priority
		# side's own edge cell rather than inventing a two-sided shape.
		if n:
			return {"shape": "edge", "dir": "N"}
		return {"shape": "edge", "dir": "E"}
	# Two adjacent sides, three sides, or four sides: approximate with the
	# convex corner of the highest-priority adjacent foreign pair.
	if n and e:
		return {"shape": "corner", "dir": "NE"}
	if s and e:
		return {"shape": "corner", "dir": "SE"}
	if n and w:
		return {"shape": "corner", "dir": "NW"}
	return {"shape": "corner", "dir": "SW"}

## Priority-ordered neighbour offsets for each grass_shore_selection() result,
## used by map_view.gd to pick which single actual neighbour tile (water or
## rock) the selected shape's alpha must reveal as the boundary cell's opaque
## backing. An "edge" or "concave" shape represents exactly one neighbour, so
## it has one offset; a "corner" shape represents two adjacent orthogonal
## neighbours, tried in the same N > E > S > W priority grass_shore_selection()
## itself uses, so a mixed water/rock corner still resolves to one material.
const GRASS_SHORE_BACKING_OFFSETS: Dictionary = {
	"edge:N": [Vector2i(0, -1)],
	"edge:S": [Vector2i(0, 1)],
	"edge:E": [Vector2i(1, 0)],
	"edge:W": [Vector2i(-1, 0)],
	"corner:NE": [Vector2i(0, -1), Vector2i(1, 0)],
	"corner:SE": [Vector2i(0, 1), Vector2i(1, 0)],
	"corner:NW": [Vector2i(0, -1), Vector2i(-1, 0)],
	"corner:SW": [Vector2i(0, 1), Vector2i(-1, 0)],
	"concave:NE": [Vector2i(1, -1)],
	"concave:NW": [Vector2i(-1, -1)],
	"concave:SE": [Vector2i(1, 1)],
	"concave:SW": [Vector2i(-1, 1)],
}

## Priority-ordered neighbour offsets to check for the given selection's
## backing material (see GRASS_SHORE_BACKING_OFFSETS above). Returns an empty
## array for an empty selection (fully interior cell, no backing needed).
static func grass_shore_backing_offsets(selection: Dictionary) -> Array:
	if selection.is_empty():
		return []
	return GRASS_SHORE_BACKING_OFFSETS["%s:%s" % [selection["shape"], selection["dir"]]]

## Resolves a TILE_SOIL cell's grass-overlay atlas coords from its 8
## neighbours (`is_foreign(x, y)` reports whether the tile at that offset is
## water or rock). Returns null when no neighbour is foreign: the cell is
## fully interior, and the base layer's own full-fill grass cell (see
## TILE_ATLAS_MAP/TILE_SOIL_VARIANTS above) already covers it, so no overlay
## cell is drawn (the "full" 13th configuration lives on the base layer,
## not duplicated here). Thin wrapper over grass_shore_selection() -- see
## that function for the full approximation rules.
static func grass_overlay_coords(n: bool, s: bool, e: bool, w: bool, ne: bool, nw: bool, se: bool, sw: bool) -> Variant:
	var selection := grass_shore_selection(n, s, e, w, ne, nw, se, sw)
	if selection.is_empty():
		return null
	return grass_overlay_coords_for_selection(selection)

## Same lookup as grass_overlay_coords() above, taking an already-resolved
## grass_shore_selection() result instead of recomputing it -- map_view.gd
## uses this to resolve the overlay cell from the same selection it already
## used to resolve the base-layer backing material, so the two layers can
## never disagree about which neighbour the boundary cell represents.
## `selection` must be non-empty (callers only reach this for a boundary
## cell -- see _set_soil_cell() in map_view.gd).
static func grass_overlay_coords_for_selection(selection: Dictionary) -> Vector2i:
	match selection["shape"]:
		"edge":
			return GRASS_EDGE_COORDS[selection["dir"]]
		"concave":
			return GRASS_CONCAVE_COORDS[selection["dir"]]
		_:
			return GRASS_CORNER_COORDS[selection["dir"]]

## Object kinds (content/objects.json, docs/architecture/colonist-ai.md 3.5),
## each its own distinct source -- none reuse another kind's cell.
const OBJECT_ATLAS_MAP: Dictionary = {
	"chair": {"source_id": SOURCE_CHAIR, "coords": Vector2i(0, 0)},
	"door": {"source_id": SOURCE_DOOR, "coords": Vector2i(0, 0)},
	"wooden_wall": {"source_id": SOURCE_WALL, "coords": Vector2i(0, 0)},
	"stone_wall": {"source_id": SOURCE_STONE_WALL, "coords": Vector2i(0, 0)},
	"table": {"source_id": SOURCE_TABLE, "coords": Vector2i(0, 0)},
	"berry_bush": {"source_id": SOURCE_BERRY_BUSH, "coords": Vector2i(0, 0)},
	"bed": {"source_id": SOURCE_BED, "coords": Vector2i(0, 0)},
	# Horizontal (2x1 footprint) workbench.
	"workbench": {"source_id": SOURCE_WORKBENCH, "coords": Vector2i(0, 0)},
	# Vertical (1x2 footprint) orientation. map_view.gd's construction-site
	# ghost looks this key up for a vertical site instead of rotating the
	# horizontal sprite. A completed workbench's orientation is not yet exposed
	# by WorldState.get_objects(), so a finished vertical workbench still
	# renders through "workbench" above.
	"workbench_vertical": {"source_id": SOURCE_WORKBENCH_VERTICAL, "coords": Vector2i(0, 0)},
}

## Native pixel ceilings for presentation props.
const PROP_MAX_SIZE_1X1 := Vector2i(16, 24)
const PROP_MAX_SIZE_2X1 := Vector2i(32, 28)
const GROUND_ITEM_ICON_MIN_SIZE := 8.0
const GROUND_ITEM_ICON_MAX_SIZE := 10.0

## Item kinds (WorldState.get_items()/carrying) mapped to an icon used for the
## carried-item badge, the held-tool badge and the stockpile/ground icons.
## Those are drawn straight from the texture (draw_texture_rect_region()/
## region_rect) rather than through a TileMapLayer, so each entry carries its
## `texture_path` and absolute pixel `rect` alongside the `source_id`/`coords`
## pair that registers the same region in the TileSet;
## test_tile_atlas_map.gd asserts the two always agree.
const ITEM_ATLAS_MAP: Dictionary = {
	"wood": {
		"source_id": SOURCE_HAZARD,
		"coords": Vector2i(2, 0),
		"texture_path": ART_DIR + "resources.png",
		"rect": Rect2(64, 0, 32, 20),
	},
	"stone": {
		"source_id": SOURCE_HAZARD,
		"coords": Vector2i(1, 0),
		"texture_path": ART_DIR + "resources.png",
		"rect": Rect2(32, 0, 32, 20),
	},
	# Tool icons: each head is set across its haft (checked from pixels).
	"pick": {
		"source_id": SOURCE_TOOLS,
		"coords": Vector2i(0, 0),
		"texture_path": ART_DIR + "tools.png",
		"rect": Rect2(0, 0, 16, 16),
	},
	"axe": {
		"source_id": SOURCE_TOOLS,
		"coords": Vector2i(1, 0),
		"texture_path": ART_DIR + "tools.png",
		"rect": Rect2(16, 0, 16, 16),
	},
}

## Actor kinds (content/actors.json), deliberately reusing the hazard/door
## cells (signal danger / mark an edge crossing) until dedicated actor art
## exists.
const ACTOR_ATLAS_MAP: Dictionary = {
	"wolf": {"source_id": SOURCE_HAZARD, "coords": Vector2i(0, 0),
		"texture_path": ART_DIR + "resources.png",
		"rect": Rect2(0, 0, 32, 20)},
	"trader": {"source_id": SOURCE_DOOR, "coords": Vector2i(0, 0)},
}

## The source pixel rect for atlas coords (col,row) within a *grid* source
## whose margins are (0,0) and whose region size is (ATLAS_CELL_SIZE,
## ATLAS_CELL_SIZE) -- i.e. the terrain sheet (SOURCE_FLOORS). Kept as
## a pure grid helper (not used by ITEM_ATLAS_MAP, which now carries its own
## absolute `rect` -- see above) for any future direct-region draw against
## SOURCE_FLOORS.
static func atlas_pixel_region(coords: Vector2i) -> Rect2:
	return Rect2(coords.x * ATLAS_CELL_STRIDE, coords.y * ATLAS_CELL_STRIDE, ATLAS_CELL_SIZE, ATLAS_CELL_SIZE)
