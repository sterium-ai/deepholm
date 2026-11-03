class_name LayerDiscovery
extends RefCounted

## Underground layers (F4, ADR 071): a finished tunnel discovers the layer below it.
## Invariants:
## - Layer N (1..MAX_UNDERGROUND_LAYER) exists only once a tunnel on layer N-1 was finished;
##   layers are appended in order, so TileGrid's existing flat indices never move.
## - A discovered layer is UndergroundGenerator.generate_layer() of the world seed alone (never
##   the tick or the simulation RNG): the same whether it is found on day 3 or day 30.
## - Discovery logs one "layer_discovered" event; every finished tunnel (first or not) carves a
##   floor landing under itself on the layer below and puts stairs_up there, so the tunnel's
##   link_down and the stairs' link_up form the L3 vertical link.
## - generator_version is saved as map.undergroundVersion; nothing else here is state (the
##   layers themselves are tiles and objects, saved with the map).

const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")

const TUNNEL_KIND := "tunnel"
const STAIRS_KIND := "stairs_up"
const MAX_UNDERGROUND_LAYER := 3
## Half-width of the square floor landing carved around the stairs.
const LANDING_RADIUS := 1
const PRIORITY_TICK := 100

var generator_version: int = UndergroundGenerator.GENERATOR_VERSION
var _world: WeakRef

func _init(world: WorldState) -> void:
	_world = weakref(world)

## ConstructionSystem.on_site_completed: (kind, origin) of every finished site.
func on_site_completed(kind: String, origin: Vector3i) -> void:
	if kind != TUNNEL_KIND or origin.z + 1 > MAX_UNDERGROUND_LAYER:
		return
	var world := _world.get_ref() as WorldState
	if world == null:
		return
	var layer := origin.z + 1
	if layer >= world._tile_grid.layer_count:
		_append_layer(world, layer)
	_place_stairs(world, Vector3i(origin.x, origin.y, layer))

## Generates `layer` (the next one) from the seed, places its veins and logs the discovery.
static func _append_layer(world: WorldState, layer: int) -> void:
	var grid: TileGridType = world._tile_grid
	var generated := UndergroundGenerator.generate_layer(world._seed, layer, grid.width, grid.height, world._object_definitions)
	var tiles: Array[String] = generated["tiles"]
	grid.tiles.append_array(tiles)
	grid.layer_count = layer + 1
	grid.regions = null
	grid.water_tile_cache.clear()
	grid.water_tile_cache_built = false
	var base: int = layer * grid.layer_size()
	var veins: Array = generated["veins"]
	for vein: Array in veins:
		var planar: int = vein[0]
		var vein_kind: String = vein[1]
		world._object_table.place_generated(TileGridType.coord_in(base + planar, grid.width, grid.height), vein_kind)
	grid.reset_cells()
	_refresh_giver_bounds(world, grid.bounds_max())
	var event_log: EventLogType = world._event_log
	event_log.insert_event({
		"type": "layer_discovered", "tick": world._clock.tick, "system_priority": PRIORITY_TICK,
		"entity_id": "world", "sequence": event_log.next_sequence(),
		"data": {"layer": layer, "first_index": base},
	})

## A floor landing (clearing any vein on it) with stairs_up at its centre.
static func _place_stairs(world: WorldState, stairs: Vector3i) -> void:
	var grid: TileGridType = world._tile_grid
	var objects: ObjectTableType = world._object_table
	for dy in range(-LANDING_RADIUS, LANDING_RADIUS + 1):
		for dx in range(-LANDING_RADIUS, LANDING_RADIUS + 1):
			var tile := Vector3i(stairs.x + dx, stairs.y + dy, stairs.z)
			if not grid.contains(tile):
				continue
			if not objects.get_object(tile).is_empty():
				objects.set_object(tile, "")
			grid.tiles[grid.index_of(tile)] = UndergroundGenerator.TILE_FLOOR
			grid.mark_dirty(tile)
	objects.set_object(stairs, STAIRS_KIND)
	grid.regions = null
	grid.reset_cells()

## The givers copied TileGrid.bounds_max() when built; a new layer raises its z.
static func _refresh_giver_bounds(world: WorldState, bounds_max: Vector3i) -> void:
	if world._need_giver != null:
		world._need_giver._bounds_max = bounds_max
	if world._rescue_giver != null:
		world._rescue_giver._bounds_max = bounds_max
	if world._approach_giver != null:
		world._approach_giver._bounds_max = bounds_max
	if world._combat_giver != null:
		world._combat_giver._bounds_max = bounds_max
