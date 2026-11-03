class_name LayerDiscovery
extends RefCounted

## Underground layers (F4, ADR 071): a finished tunnel discovers the layer below it.
## Invariants:
## - Layer N (1..MAX_UNDERGROUND_LAYER) exists only once a tunnel on layer N-1 was finished;
##   layers are appended in order, so TileGrid's existing flat indices never move.
## - A discovered layer is UndergroundGenerator.generate_layer() of the world seed alone (never
##   the tick or the simulation RNG): the same whether it is found on day 3 or day 30.
## - Discovery logs one "layer_discovered" event; the finished tunnel carves a floor landing
##   under itself on the layer below and puts stairs_up there, so the tunnel's link_down and the
##   stairs' link_up form the L3 vertical link. The landing only turns rock and veins into floor:
##   any other object below is kept.
## - One tunnel per layer: may_place() vetoes a tunnel on a layer that already holds a tunnel or a
##   tunnel site, and one whose stairs tile below holds anything but a vein or stairs_up.
## - Route searches see the vertical links through links() (L3b, ADR 068); wire_routing() hands
##   it to the scheduler and the givers each time they are built.
## - generator_version is saved as map.undergroundVersion; nothing else here is state (the
##   layers themselves are tiles and objects, saved with the map).

const TileGridType = preload("res://scripts/core/map/tile_grid.gd")
const ObjectTableType = preload("res://scripts/core/objects/object_table.gd")
const EventLogType = preload("res://scripts/core/world/event_log.gd")
const MeasuredRouteType = preload("res://scripts/core/scheduling/measured_route.gd")

const TUNNEL_KIND := "tunnel"
const STAIRS_KIND := "stairs_up"
const MAX_UNDERGROUND_LAYER := 3
## Half-width of the square floor landing carved around the stairs.
const LANDING_RADIUS := 1
const PRIORITY_TICK := 100

var generator_version: int = UndergroundGenerator.GENERATOR_VERSION
var _world: WeakRef

## Built after world._construction: hooks on_site_completed and may_place into it.
func _init(world: WorldState) -> void:
	_world = weakref(world)
	world._construction.on_site_completed = on_site_completed
	world._construction.may_place = may_place

## The map's current vertical links for RouteSearch.set_vertical_links(); null on a one-layer map.
func links() -> Variant:
	var world := _world.get_ref() as WorldState
	if world == null or world._tile_grid.layer_count < 2:
		return null
	return world._tile_grid.get_regions().vertical_links()

## `search` with links() set, returned (WorldState's reroute factory).
func linked(search: MeasuredRouteType) -> MeasuredRouteType:
	search.use_links(links)
	return search

## Gives links() to the scheduler and the givers (they are rebuilt with the dimension services).
func wire_routing() -> void:
	var world := _world.get_ref() as WorldState
	if world == null:
		return
	world._scheduler.links_of = links
	world._need_giver.links_of = links
	world._rescue_giver.links_of = links
	world._approach_giver.links_of = links

## ConstructionSystem.may_place: {} or the veto of a tunnel at `origin` (see the invariants).
func may_place(kind: String, origin: Vector3i, accepted: Array[Vector3i]) -> Dictionary:
	if kind != TUNNEL_KIND:
		return {}
	var world := _world.get_ref() as WorldState
	if world == null:
		return {}
	var taken := {"reason": "invalid_target", "params": {"detail": "tunnel_layer_taken"}}
	for tile in accepted:
		if tile.z == origin.z:
			return taken
	for tile in world._object_table.tiles_of_kind(TUNNEL_KIND):
		if tile.z == origin.z:
			return taken
	for site in world._construction.site_table.list():
		var site_kind: String = site["kind"]
		if site_kind == TUNNEL_KIND and (site["origin"] as Vector3i).z == origin.z:
			return taken
	var below := Vector3i(origin.x, origin.y, origin.z + 1)
	if world._tile_grid.contains(below) and not _landing_clearable(world, below, true):
		return {"reason": "invalid_target", "params": {"detail": "tunnel_landing_blocked"}}
	return {}

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

## True when `tile` holds no object or a vein (or, for the stairs tile, stairs_up already).
static func _landing_clearable(world: WorldState, tile: Vector3i, stairs_tile: bool) -> bool:
	var kind: String = world._object_table.get_object(tile)
	if kind.is_empty() or (stairs_tile and kind == STAIRS_KIND):
		return true
	return (world._object_definitions.get(kind, {}) as Dictionary).has("vein")

## A floor landing with stairs_up at its centre: rock and veins become floor, other objects stay.
static func _place_stairs(world: WorldState, stairs: Vector3i) -> void:
	var grid: TileGridType = world._tile_grid
	var objects: ObjectTableType = world._object_table
	for dy in range(-LANDING_RADIUS, LANDING_RADIUS + 1):
		for dx in range(-LANDING_RADIUS, LANDING_RADIUS + 1):
			var tile := Vector3i(stairs.x + dx, stairs.y + dy, stairs.z)
			if not grid.contains(tile) or not _landing_clearable(world, tile, false):
				continue
			if not objects.get_object(tile).is_empty():
				objects.set_object(tile, "")
			grid.tiles[grid.index_of(tile)] = UndergroundGenerator.TILE_FLOOR
			grid.mark_dirty(tile)
	if _landing_clearable(world, stairs, true) and objects.get_object(stairs) != STAIRS_KIND:
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
