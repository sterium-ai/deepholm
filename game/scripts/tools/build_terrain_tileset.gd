extends SceneTree

## Builds game/data/tilesets/terrain_tileset.tres from the generated
## placeholder art in game/assets/generated/ (see
## tools/generate_placeholder_art.py) through Godot's own TileSet API and
## ResourceSaver, so the .tres format is always valid. Source ids and atlas
## coords must match scripts/viewer/tile_atlas_map.gd.
##
## Run: godot --headless --path game --script res://scripts/tools/build_terrain_tileset.gd

const CELL := Vector2i(16, 16)
const ART := "res://assets/generated/"

func _grid_source(file: String, coords_list: Array, region := CELL) -> TileSetAtlasSource:
	var source := TileSetAtlasSource.new()
	source.texture = load(ART + file)
	source.texture_region_size = region
	for coords in coords_list:
		source.create_tile(coords)
	return source

## One sprite per texture at local (0,0). Sprites taller than their footprint
## are grounded: TileMapLayer centres an oversized texture on its cell, so
## moving the bottom edge onto the footprint's bottom needs half the excess.
func _sprite_source(file: String, size: Vector2i, footprint_height: int = CELL.y) -> TileSetAtlasSource:
	var source := _grid_source(file, [Vector2i.ZERO], size)
	var origin := Vector2i(0, (size.y - footprint_height) / 2)
	if origin != Vector2i.ZERO:
		source.get_tile_data(Vector2i.ZERO, 0).texture_origin = origin
	return source

func _init() -> void:
	var tile_set := TileSet.new()
	tile_set.tile_size = CELL
	var terrain_coords := [
		# 12-cell grass shoreline overlay (see GRASS_*_COORDS).
		Vector2i(2, 4), Vector2i(2, 0), Vector2i(0, 2), Vector2i(4, 2),
		Vector2i(1, 3), Vector2i(3, 3), Vector2i(1, 1), Vector2i(3, 1),
		Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 0), Vector2i(3, 0),
		# Grass variants, trench, floor.
		Vector2i(0, 5), Vector2i(1, 5), Vector2i(2, 5), Vector2i(3, 5), Vector2i(4, 5),
		# Plowed soil, planted base, hazard base, forest floor.
		Vector2i(0, 6), Vector2i(1, 6), Vector2i(2, 6), Vector2i(3, 6),
	]
	tile_set.add_source(_grid_source("terrain.png", terrain_coords), 0)
	tile_set.add_source(_grid_source("water.png", [Vector2i.ZERO]), 1)
	tile_set.add_source(_grid_source("rock.png", [Vector2i.ZERO]), 2)
	tile_set.add_source(_grid_source("wooden_wall.png", [Vector2i.ZERO]), 3)
	tile_set.add_source(_sprite_source("chair.png", Vector2i(16, 24)), 4)
	tile_set.add_source(_sprite_source("table.png", Vector2i(16, 24)), 5)
	tile_set.add_source(_sprite_source("bed.png", Vector2i(16, 24)), 6)
	tile_set.add_source(_sprite_source("door.png", Vector2i(16, 24)), 7)
	tile_set.add_source(_sprite_source("berry_bush.png", Vector2i(16, 24)), 8)
	tile_set.add_source(_grid_source("sprout.png", [Vector2i.ZERO]), 9)
	tile_set.add_source(_sprite_source("tree.png", Vector2i(32, 48)), 10)
	# Resources: hazard cluster (0,0), stone (1,0), wood (2,0); 32x20 cells,
	# low ground clutter centred on the tile (no origin correction).
	tile_set.add_source(_grid_source("resources.png", [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)], Vector2i(32, 20)), 11)
	tile_set.add_source(_sprite_source("workbench.png", Vector2i(32, 28)), 12)
	tile_set.add_source(_sprite_source("workbench_vertical.png", Vector2i(16, 44), CELL.y * 2), 13)
	tile_set.add_source(_grid_source("tools.png", [Vector2i(0, 0), Vector2i(1, 0)]), 14)
	tile_set.add_source(_grid_source("stone_wall.png", [Vector2i.ZERO]), 15)
	var out_path := "res://data/tilesets/terrain_tileset.tres"
	var err := ResourceSaver.save(tile_set, out_path)
	print("saved ", out_path, " err=", err, " sources=", tile_set.get_source_count())
	quit(0 if err == OK else 1)
