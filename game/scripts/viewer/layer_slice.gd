extends RefCounted

## The one layer the viewer draws (ADR 045 §7, ADR 069). WorldState's (x, y) getters answer for
## the surface only, so the layer's tiles are read from get_tiles() (z-outermost, flat index
## z * width * height + y * width + x) once per read(), on every layer: a full redraw asks for
## each cell and its eight neighbours, which per-cell get_tile() calls made too slow for one
## frame. A deeper layer's objects come from get_objects() (entries carry z); on the surface
## object() keeps calling get_object(), as before L4. The copy is re-read by the map view when
## one of the layer's cells is dirty.
## Viewer state only: nothing here is saved or sent to the core.

const WorldStateType = preload("res://scripts/core/world_state.gd")

const LINK_UP := 1
const LINK_DOWN := 2

var world: WorldStateType
var z := 0
var _offset := 0
var _tiles: Array[String] = []
## Vector2i -> object kind on layer z (deep layers only).
var _objects := {}
## Object kind -> LINK_UP | LINK_DOWN bits, from the objects content (link_up / link_down).
var _link_kinds := {}

## Number of layers of `world`'s map; 1 for a world without one.
static func layer_count(world_ref: WorldStateType) -> int:
	if world_ref == null:
		return 1
	var layer_size := world_ref.get_map_width() * world_ref.get_map_height()
	return maxi(1, world_ref.get_tiles().size() / maxi(layer_size, 1))

## Binds the slice to `world_ref` and layer `layer`, and reads that layer's tiles and objects.
func read(world_ref: WorldStateType, layer: int) -> void:
	world = world_ref
	z = layer
	_tiles = []
	_objects = {}
	_link_kinds = {}
	if world == null:
		return
	for entry in world.get_content_list("objects"):
		var flags := (LINK_UP if bool(entry.get("link_up", false)) else 0) | (LINK_DOWN if bool(entry.get("link_down", false)) else 0)
		if flags != 0:
			_link_kinds[String(entry.get("kind", ""))] = flags
	_offset = z * world.get_map_width() * world.get_map_height()
	_tiles = world.get_tiles()
	if z == 0:
		return
	for entry in world.get_objects():
		if int(entry.get("z", 0)) == z:
			_objects[Vector2i(int(entry["x"]), int(entry["y"]))] = String(entry["kind"])

## Tile kind at (x, y) on this layer.
func tile(x: int, y: int) -> String:
	return _tiles[_offset + y * world.get_map_width() + x]

## The flat get_tiles() copy this slice reads from (every layer; this one starts at z * width * height).
func tiles() -> Array[String]:
	return _tiles

## Object kind at (x, y) on this layer, "" for none.
func object(x: int, y: int) -> String:
	if z == 0:
		return world.get_object(x, y)
	return String(_objects.get(Vector2i(x, y), ""))

## The objects on this layer, get_objects() entries in their order.
func objects() -> Array[Dictionary]:
	var on_layer: Array[Dictionary] = []
	if world == null:
		return on_layer
	for entry in world.get_objects():
		if int(entry.get("z", 0)) == z:
			on_layer.append(entry)
	return on_layer

## The stair/ramp markers of this layer: {x, y, flags} for every object whose kind declares
## link_up or link_down. The flags are the object's own; whether the far end matches (a link,
## VerticalLinks) is the core's question and is not answered here.
func link_markers() -> Array[Dictionary]:
	var markers: Array[Dictionary] = []
	if _link_kinds.is_empty():
		return markers
	for entry in objects():
		var flags := int(_link_kinds.get(String(entry["kind"]), 0))
		if flags != 0:
			markers.append({"x": int(entry["x"]), "y": int(entry["y"]), "flags": flags})
	return markers
