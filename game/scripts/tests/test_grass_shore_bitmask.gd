extends SceneTree

## Issue #301 round 4: replaces the round-3 version of this test, whose
## expectations were computed FROM the same GRASS_CORNER_COORDS/
## GRASS_CONCAVE_COORDS dictionaries the implementation uses, so a
## systematic reversal of those two dictionaries (round-4 blocking finding:
## the "convex corner" and "concave corner" cell groups were swapped) stayed
## invisible -- both sides of every assertion moved together. This version:
##
##   A. Checks all 13 configurations (interior, 4 edges, 4 convex corners, 4
##      concave corners) against Vector2i LITERALS matching the sheet's
##      actual measured alpha geometry (see tile_atlas_map.gd's GRASS_CORNER_
##      COORDS/GRASS_CONCAVE_COORDS comments for the round-4 correction), not
##      against the implementation's own dictionaries.
##   B. Checks every documented approximation (channel/cap/isolated) against
##      an exact expected cell, not just "is one of the 12 real cells", and
##      asserts the two opposite channel orientations (N-S vs E-W) resolve to
##      DIFFERENT cells -- the round-3 version only checked set membership,
##      which would have silently accepted both channels collapsing onto one
##      cell.
##   C. Builds a synthetic map with a water body AND a rock outcrop and
##      checks the actual COMPOSED two-layer result at each boundary cell:
##      the base TileMapLayer cell must be the correct material's (water or
##      rock) own plain opaque cell -- not grass -- and the overlay cell must
##      be the matching blob shape, including a corner cell whose two
##      represented sides are DIFFERENT materials (water+rock), where the
##      backing must deterministically pick the higher-priority side's own
##      material. This is exactly the composition round-4's blocking finding
##      said was unverified: the round-3 base layer always painted opaque
##      grass under every soil cell, so its transparent overlay pixels never
##      actually revealed water/rock -- a check that only inspected the
##      overlay cell's coords (as the round-3 version did) could not catch
##      that, since the overlay coords were already correct; only the base
##      layer was wrong.
##   D. Proves incremental refresh matches a fresh full rebuild through both
##      an orthogonal neighbour change and a diagonal-only neighbour change,
##      each added AND then removed again, checking both the base and
##      overlay cell after every step.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")

## Literal expectations, independent of tile_atlas_map.gd's own dictionaries
## (see module comment above for why that independence matters). These must
## match GRASS_EDGE_COORDS/GRASS_CORNER_COORDS/GRASS_CONCAVE_COORDS exactly,
## but are written here by hand so a future accidental reversal of those
## dictionaries fails this test instead of passing it.
const EDGE_N := Vector2i(2, 4)
const EDGE_S := Vector2i(2, 0)
const EDGE_E := Vector2i(0, 2)
const EDGE_W := Vector2i(4, 2)
## Convex corners: both edges on the corner fully exposed (two adjacent
## orthogonal neighbours foreign).
const CORNER_NE := Vector2i(1, 3)
const CORNER_NW := Vector2i(3, 3)
const CORNER_SE := Vector2i(1, 1)
const CORNER_SW := Vector2i(3, 1)
## Concave corners: almost entirely grass, one small diagonal bite (only the
## diagonal neighbour is foreign, both orthogonal neighbours on that corner
## stay soil).
const CONCAVE_NE := Vector2i(1, 4)
const CONCAVE_NW := Vector2i(3, 4)
const CONCAVE_SE := Vector2i(1, 0)
const CONCAVE_SW := Vector2i(3, 0)

var _failed := false

func _init() -> void:
	_check_pure_configurations()
	_check_approximations()
	_check_synthetic_map()
	_check_incremental_matches_full_rebuild()
	if _failed:
		quit(1)
		return
	print("test_grass_shore_bitmask: PASS")
	quit(0)

## Part A: all 13 real configurations, driven directly against
## grass_overlay_coords() with no world at all, checked against hand-written
## literals (see module comment).
func _check_pure_configurations() -> void:
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, false, false, false, false, false, false) == null,
		"a fully interior soil tile must return null (base layer's full-fill cell already covers it)")
	_expect(TileAtlasMapType.grass_overlay_coords(true, false, false, false, false, false, false, false) == EDGE_N, "N edge")
	_expect(TileAtlasMapType.grass_overlay_coords(false, true, false, false, false, false, false, false) == EDGE_S, "S edge")
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, true, false, false, false, false, false) == EDGE_E, "E edge")
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, false, true, false, false, false, false) == EDGE_W, "W edge")
	# Convex corners: two *adjacent* orthogonal sides foreign -- both edges on
	# that corner must be fully exposed grass-less.
	_expect(TileAtlasMapType.grass_overlay_coords(true, false, true, false, false, false, false, false) == CORNER_NE, "NE convex corner")
	_expect(TileAtlasMapType.grass_overlay_coords(true, false, false, true, false, false, false, false) == CORNER_NW, "NW convex corner")
	_expect(TileAtlasMapType.grass_overlay_coords(false, true, true, false, false, false, false, false) == CORNER_SE, "SE convex corner")
	_expect(TileAtlasMapType.grass_overlay_coords(false, true, false, true, false, false, false, false) == CORNER_SW, "SW convex corner")
	# Concave corners: no orthogonal side foreign, one diagonal is -- almost
	# entirely grass, a small corner bite.
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, false, false, true, false, false, false) == CONCAVE_NE, "NE concave corner")
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, false, false, false, true, false, false) == CONCAVE_NW, "NW concave corner")
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, false, false, false, false, true, false) == CONCAVE_SE, "SE concave corner")
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, false, false, false, false, false, true) == CONCAVE_SW, "SW concave corner")
	var all_coords: Array[Vector2i] = [
		EDGE_N, EDGE_S, EDGE_E, EDGE_W,
		CORNER_NE, CORNER_NW, CORNER_SE, CORNER_SW,
		CONCAVE_NE, CONCAVE_NW, CONCAVE_SE, CONCAVE_SW,
	]
	var seen := {}
	for coords in all_coords:
		_expect(not seen.has(coords), "grass blob coords %s reused by more than one configuration" % coords)
		seen[coords] = true
	_expect(all_coords.size() == 12, "expected exactly 12 directional grass cells (4 edge + 4 corner + 4 concave), found %d" % all_coords.size())
	# The convex and concave families must never collide with each other --
	# this is exactly the check that would have failed had the round-4
	# reversal (both families non-empty but swapped) instead collapsed both
	# groups onto the same 4 coords.
	for i in range(4):
		_expect(all_coords[4 + i] != all_coords[8 + i], "convex corner %s must differ from its concave counterpart %s" % [all_coords[4 + i], all_coords[8 + i]])

## Part B: documented permitted approximations (pack has 13 shapes, not the
## full 47-tile Wang set) -- each checked against its exact expected cell,
## not just membership in the real set, plus an explicit distinctness check
## between opposite channel orientations.
func _check_approximations() -> void:
	_expect(TileAtlasMapType.grass_overlay_coords(true, true, false, false, false, false, false, false) == EDGE_N, "N-S channel must approximate to the higher-priority N edge")
	_expect(TileAtlasMapType.grass_overlay_coords(false, false, true, true, false, false, false, false) == EDGE_E, "E-W channel must approximate to the higher-priority E edge")
	# The two opposite-orientation channels must resolve to genuinely
	# different cells -- round-3's membership-only check would have accepted
	# both collapsing onto the same edge cell.
	_expect(TileAtlasMapType.grass_overlay_coords(true, true, false, false, false, false, false, false)
			!= TileAtlasMapType.grass_overlay_coords(false, false, true, true, false, false, false, false),
		"N-S and E-W channels must resolve to distinct cells, not the same orientation")
	_expect(TileAtlasMapType.grass_overlay_coords(true, true, true, false, false, false, false, false) == CORNER_NE, "cap open W must approximate to the highest-priority adjacent pair (N+E)")
	_expect(TileAtlasMapType.grass_overlay_coords(false, true, true, true, false, false, false, false) == CORNER_SE, "cap open N must approximate to the highest-priority adjacent pair (S+E)")
	_expect(TileAtlasMapType.grass_overlay_coords(true, true, false, true, false, false, false, false) == CORNER_NW, "cap open E must approximate to the highest-priority adjacent pair (N+W)")
	_expect(TileAtlasMapType.grass_overlay_coords(true, false, true, true, false, false, false, false) == CORNER_NE, "cap open S must approximate to the highest-priority adjacent pair (N+E)")
	_expect(TileAtlasMapType.grass_overlay_coords(true, true, true, true, false, false, false, false) == CORNER_NE, "isolated tile must approximate to the highest-priority adjacent pair (N+E)")

## Part C: a synthetic map with a water body and a separate rock outcrop --
## checks the actual COMPOSED base+overlay result, including a corner cell
## whose two represented sides are different materials.
func _check_synthetic_map() -> void:
	var width := 24
	var height := 24
	var world := WorldStateType.new(30112, 10, width, height)
	world._tiles.fill(WorldStateType.TILE_SOIL)

	# Water edge: a single water tile directly S of the probe.
	world._tiles[world._tile_index(3, 2)] = WorldStateType.TILE_WATER
	var water_edge_probe := Vector2i(3, 1)

	# Water corner: water directly E and S of the probe (two adjacent
	# orthogonal sides), nothing to its N or W.
	world._tiles[world._tile_index(7, 7)] = WorldStateType.TILE_WATER
	world._tiles[world._tile_index(6, 8)] = WorldStateType.TILE_WATER
	var water_corner_probe := Vector2i(6, 7)

	# Water concave: water ONLY on the NE diagonal, both orthogonal
	# neighbours on that corner (N and E) stay soil.
	world._tiles[world._tile_index(11, 9)] = WorldStateType.TILE_WATER
	var water_concave_probe := Vector2i(10, 10)

	# Rock edge: a single rock tile directly S of the probe (mirrors the
	# water edge case above, to prove the SAME grass cell serves both).
	world._tiles[world._tile_index(3, 12)] = WorldStateType.TILE_ROCK
	var rock_edge_probe := Vector2i(3, 11)

	# Rock concave: rock ONLY on the SE diagonal.
	world._tiles[world._tile_index(16, 16)] = WorldStateType.TILE_ROCK
	var rock_concave_probe := Vector2i(15, 15)

	# Mixed-material NE corner: water to the N, rock to the E -- both
	# foreign, so still a convex NE corner shape, but the two represented
	# sides disagree on material. Backing must deterministically pick N
	# (water) over E (rock), matching grass_shore_selection()'s own N>E
	# priority for a corner's backing offsets.
	world._tiles[world._tile_index(20, 4)] = WorldStateType.TILE_WATER
	world._tiles[world._tile_index(21, 5)] = WorldStateType.TILE_ROCK
	var mixed_ne_probe := Vector2i(20, 5)

	# Mixed-material SE corner: rock to the S, water to the E -- backing
	# must pick S (rock) over E (water).
	world._tiles[world._tile_index(20, 14)] = WorldStateType.TILE_ROCK
	world._tiles[world._tile_index(21, 13)] = WorldStateType.TILE_WATER
	var mixed_se_probe := Vector2i(20, 13)

	var interior_probe := Vector2i(1, 20)

	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_art_enabled(true)
	map_view.set_world(world)

	var base_layer: TileMapLayer = map_view.get("_tile_map_layer")
	var overlay_layer: TileMapLayer = map_view.get("_grass_overlay_layer")
	_expect(base_layer != null, "map_view must expose its terrain TileMapLayer")
	_expect(overlay_layer != null, "map_view must expose its grass overlay TileMapLayer")
	if base_layer == null or overlay_layer == null:
		return

	var water_coords: Vector2i = TileAtlasMapType.TILE_ATLAS_MAP[WorldStateType.TILE_WATER]["coords"]
	var rock_coords: Vector2i = TileAtlasMapType.TILE_ATLAS_MAP[WorldStateType.TILE_ROCK]["coords"]

	# Water/rock TILES themselves always keep their own plain base cell --
	# never a directional one (issue #301 round 3 owner note).
	_expect(base_layer.get_cell_atlas_coords(Vector2i(3, 2)) == water_coords,
		"a water tile bordered by soil must still use the plain water cell")
	_expect(base_layer.get_cell_atlas_coords(Vector2i(3, 12)) == rock_coords,
		"a rock tile bordered by soil must still use the plain rock cell")

	# Water edge: base layer must be WATER's own cell (not grass), overlay
	# must be the S edge blob shape.
	_expect(base_layer.get_cell_atlas_coords(water_edge_probe) == water_coords,
		"soil tile %s bordering water to its S must get WATER's own cell as its base backing, got %s" % [water_edge_probe, base_layer.get_cell_atlas_coords(water_edge_probe)])
	_expect(overlay_layer.get_cell_atlas_coords(water_edge_probe) == EDGE_S,
		"soil tile %s bordering water to its S must get the S grass edge overlay" % water_edge_probe)

	# Water corner.
	_expect(base_layer.get_cell_atlas_coords(water_corner_probe) == water_coords,
		"soil tile %s bordering water to its E and S must get WATER's own cell as its base backing" % water_corner_probe)
	_expect(overlay_layer.get_cell_atlas_coords(water_corner_probe) == CORNER_SE,
		"soil tile %s bordering water to its E and S must get the SE grass corner overlay" % water_corner_probe)

	# Water concave.
	_expect(base_layer.get_cell_atlas_coords(water_concave_probe) == water_coords,
		"soil tile %s with water only on its NE diagonal must get WATER's own cell as its base backing" % water_concave_probe)
	_expect(overlay_layer.get_cell_atlas_coords(water_concave_probe) == CONCAVE_NE,
		"soil tile %s with water only on its NE diagonal must get the NE grass concave overlay" % water_concave_probe)

	# Rock edge: SAME overlay cell as the water edge above, but ROCK's own
	# cell as the base backing.
	_expect(base_layer.get_cell_atlas_coords(rock_edge_probe) == rock_coords,
		"soil tile %s bordering rock to its S must get ROCK's own cell as its base backing, got %s" % [rock_edge_probe, base_layer.get_cell_atlas_coords(rock_edge_probe)])
	_expect(overlay_layer.get_cell_atlas_coords(rock_edge_probe) == EDGE_S,
		"soil tile %s bordering rock to its S must get the SAME S grass edge overlay as the water case" % rock_edge_probe)

	# Rock concave.
	_expect(base_layer.get_cell_atlas_coords(rock_concave_probe) == rock_coords,
		"soil tile %s with rock only on its SE diagonal must get ROCK's own cell as its base backing" % rock_concave_probe)
	_expect(overlay_layer.get_cell_atlas_coords(rock_concave_probe) == CONCAVE_SE,
		"soil tile %s with rock only on its SE diagonal must get the SE grass concave overlay" % rock_concave_probe)

	# Mixed-material corners: overlay depends only on shape/direction (same
	# corner cell regardless of material), base backing deterministically
	# picks the higher-priority side's actual material.
	_expect(overlay_layer.get_cell_atlas_coords(mixed_ne_probe) == CORNER_NE,
		"mixed-material NE corner %s must still get the NE grass corner overlay" % mixed_ne_probe)
	_expect(base_layer.get_cell_atlas_coords(mixed_ne_probe) == water_coords,
		"mixed-material NE corner %s (water N, rock E) must back with WATER (N wins priority over E), got %s" % [mixed_ne_probe, base_layer.get_cell_atlas_coords(mixed_ne_probe)])
	_expect(overlay_layer.get_cell_atlas_coords(mixed_se_probe) == CORNER_SE,
		"mixed-material SE corner %s must still get the SE grass corner overlay" % mixed_se_probe)
	_expect(base_layer.get_cell_atlas_coords(mixed_se_probe) == rock_coords,
		"mixed-material SE corner %s (rock S, water E) must back with ROCK (S wins priority over E), got %s" % [mixed_se_probe, base_layer.get_cell_atlas_coords(mixed_se_probe)])

	# An interior soil tile far from either material must have no overlay
	# cell, and its base cell must be a plain grass fill (never water/rock).
	_expect(not overlay_layer.get_used_cells().has(interior_probe),
		"a fully interior soil tile %s must have no grass overlay cell" % interior_probe)
	var interior_base := base_layer.get_cell_atlas_coords(interior_probe)
	_expect(interior_base != water_coords and interior_base != rock_coords,
		"a fully interior soil tile %s must keep a plain grass base, not a water/rock backing, got %s" % [interior_probe, interior_base])

## Part D: incremental refresh must match a fresh full rebuild through both
## an orthogonal and a diagonal-only neighbour change, each added and then
## removed, checking both the base and overlay cell every time.
func _check_incremental_matches_full_rebuild() -> void:
	var width := 10
	var height := 10
	var world := WorldStateType.new(30113, 10, width, height)
	world._tiles.fill(WorldStateType.TILE_SOIL)

	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_art_enabled(true)
	map_view.set_world(world)
	var base_layer: TileMapLayer = map_view.get("_tile_map_layer")
	var overlay_layer: TileMapLayer = map_view.get("_grass_overlay_layer")

	var probe := Vector2i(5, 5)
	var water_coords: Vector2i = TileAtlasMapType.TILE_ATLAS_MAP[WorldStateType.TILE_WATER]["coords"]
	var rock_coords: Vector2i = TileAtlasMapType.TILE_ATLAS_MAP[WorldStateType.TILE_ROCK]["coords"]

	_expect(not overlay_layer.get_used_cells().has(probe), "probe tile must start with no overlay (fully interior soil)")

	# Orthogonal add: rock directly N of the probe (5,4).
	world._tiles[world._tile_index(5, 4)] = WorldStateType.TILE_ROCK
	world._dirty_cells.append(Vector2i(5, 4))
	map_view.refresh()
	_expect(overlay_layer.get_cell_atlas_coords(probe) == EDGE_N, "after an orthogonal neighbour addition, incremental refresh must set the N edge overlay, got %s" % overlay_layer.get_cell_atlas_coords(probe))
	_expect(base_layer.get_cell_atlas_coords(probe) == rock_coords, "after an orthogonal neighbour addition, incremental refresh must set ROCK's own cell as the base backing, got %s" % base_layer.get_cell_atlas_coords(probe))
	_assert_matches_fresh_rebuild(world, probe, base_layer, overlay_layer, "after orthogonal addition")

	# Orthogonal removal: revert (5,4) back to soil.
	world._tiles[world._tile_index(5, 4)] = WorldStateType.TILE_SOIL
	world._dirty_cells.append(Vector2i(5, 4))
	map_view.refresh()
	_expect(not overlay_layer.get_used_cells().has(probe), "after reverting the orthogonal neighbour, the probe must have no overlay cell again")
	_expect(base_layer.get_cell_atlas_coords(probe) != rock_coords and base_layer.get_cell_atlas_coords(probe) != water_coords,
		"after reverting the orthogonal neighbour, the probe's base cell must return to a plain grass fill")
	_assert_matches_fresh_rebuild(world, probe, base_layer, overlay_layer, "after orthogonal removal")

	# Diagonal-only add: water at the probe's NE diagonal (6,4).
	world._tiles[world._tile_index(6, 4)] = WorldStateType.TILE_WATER
	world._dirty_cells.append(Vector2i(6, 4))
	map_view.refresh()
	_expect(overlay_layer.get_cell_atlas_coords(probe) == CONCAVE_NE, "after a diagonal-only neighbour addition, incremental refresh must set the NE concave overlay, got %s" % overlay_layer.get_cell_atlas_coords(probe))
	_expect(base_layer.get_cell_atlas_coords(probe) == water_coords, "after a diagonal-only neighbour addition, incremental refresh must set WATER's own cell as the base backing, got %s" % base_layer.get_cell_atlas_coords(probe))
	_assert_matches_fresh_rebuild(world, probe, base_layer, overlay_layer, "after diagonal addition")

	# Diagonal-only removal: revert (6,4) back to soil.
	world._tiles[world._tile_index(6, 4)] = WorldStateType.TILE_SOIL
	world._dirty_cells.append(Vector2i(6, 4))
	map_view.refresh()
	_expect(not overlay_layer.get_used_cells().has(probe), "after reverting the diagonal neighbour, the probe must have no overlay cell again")
	_expect(base_layer.get_cell_atlas_coords(probe) != rock_coords and base_layer.get_cell_atlas_coords(probe) != water_coords,
		"after reverting the diagonal neighbour, the probe's base cell must return to a plain grass fill")
	_assert_matches_fresh_rebuild(world, probe, base_layer, overlay_layer, "after diagonal removal")

## A fresh MapView built from the world's current end-state (a full rebuild)
## must produce byte-identical base AND overlay coords at `probe` to the
## incrementally-refreshed layers.
func _assert_matches_fresh_rebuild(world, probe: Vector2i, base_layer: TileMapLayer, overlay_layer: TileMapLayer, label: String) -> void:
	var fresh_view := MapViewType.new()
	root.add_child(fresh_view)
	fresh_view.set_art_enabled(true)
	fresh_view.set_world(world)
	var fresh_base: TileMapLayer = fresh_view.get("_tile_map_layer")
	var fresh_overlay: TileMapLayer = fresh_view.get("_grass_overlay_layer")
	_expect(fresh_base.get_cell_atlas_coords(probe) == base_layer.get_cell_atlas_coords(probe),
		"%s: a fresh full rebuild must match the incrementally-refreshed BASE cell at %s (fresh=%s, incremental=%s)"
			% [label, probe, fresh_base.get_cell_atlas_coords(probe), base_layer.get_cell_atlas_coords(probe)])
	_expect(fresh_overlay.get_used_cells().has(probe) == overlay_layer.get_used_cells().has(probe),
		"%s: a fresh full rebuild must match the incrementally-refreshed overlay presence at %s" % [label, probe])
	if fresh_overlay.get_used_cells().has(probe):
		_expect(fresh_overlay.get_cell_atlas_coords(probe) == overlay_layer.get_cell_atlas_coords(probe),
			"%s: a fresh full rebuild must match the incrementally-refreshed OVERLAY cell at %s (fresh=%s, incremental=%s)"
				% [label, probe, fresh_overlay.get_cell_atlas_coords(probe), overlay_layer.get_cell_atlas_coords(probe)])
	fresh_view.queue_free()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
