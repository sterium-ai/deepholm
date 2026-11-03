extends RefCounted

## Vertical links (ADR 045 §3, ADR 068): stairs, ramps and tunnels join (x, y, z) and
## (x, y, z + 1), straight up and down only. z grows underground, so z is the upper end and
## z + 1 the lower one: a link exists while the upper tile declares link_down, the lower one
## link_up, and both are colony-passable. Links are derived from the map (objects' link_up /
## link_down flags), never saved: a load rebuilds them.
## Owned by RegionMap, which feeds on_tile_changed() from TileGrid.on_passability_changed().

const UP := 1
const DOWN := 2

var _width: int
var _height: int
var _layer_count: int
var _layer_size: int
var _passable: Callable
var _link_flags: Callable
## _down[i] == 1: a link between flat index i (upper end) and i + _layer_size (lower end).
var _down := PackedByteArray()
## The upper ends of every link as flat indices, ascending: what links() and the region graph
## iterate, so neither scans the map.
var _upper := PackedInt32Array()

## passable(tile: Vector3i) -> bool and link_flags(tile: Vector3i) -> int (UP | DOWN bits) are
## Passability.passable_tile() and link_flags(). A single layer has no links and no work.
func _init(width: int, height: int, layers: int, passable: Callable, link_flags: Callable) -> void:
	_width = width
	_height = height
	_layer_count = maxi(layers, 1)
	_layer_size = width * height
	_passable = passable
	_link_flags = link_flags
	_down.resize(_layer_size * (_layer_count - 1))
	_down.fill(0)
	if _layer_count < 2 or not _link_flags.is_valid():
		return
	for z in _layer_count - 1:
		for y in _height:
			for x in _width:
				var upper := Vector3i(x, y, z)
				if _derive(upper):
					var index := _flat(upper)
					_down[index] = 1
					_upper.append(index)

func layer_count() -> int:
	return _layer_count

## Number of links on the map.
func size() -> int:
	return _upper.size()

## True when tile links to the tile right below it, (x, y, z + 1).
func has_link_down(tile: Vector3i) -> bool:
	if not _in_bounds(tile) or tile.z >= _layer_count - 1:
		return false
	return _down[_flat(tile)] == 1

## True when tile links to the tile right above it, (x, y, z - 1).
func has_link_up(tile: Vector3i) -> bool:
	if not _in_bounds(tile) or tile.z < 1:
		return false
	return _down[_flat(tile) - _layer_size] == 1

## Every link's upper tile, in ascending flat index.
func links() -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for index in _upper:
		result.append(TileGrid.coord_in(index, _width, _height))
	return result

## Every link's upper tile as a flat index, ascending (RegionMap's graph build); the lower end
## is index + layer size. O(links).
func upper_indices() -> PackedInt32Array:
	return _upper

## Re-derives the two links tile can take part in (above and below it); true when one changed.
func on_tile_changed(tile: Vector3i) -> bool:
	if _layer_count < 2 or not _in_bounds(tile):
		return false
	var changed := false
	for upper_z: int in [tile.z - 1, tile.z]:
		if upper_z < 0 or upper_z >= _layer_count - 1:
			continue
		var upper := Vector3i(tile.x, tile.y, upper_z)
		var index := _flat(upper)
		var now := 1 if _derive(upper) else 0
		if _down[index] == now:
			continue
		_down[index] = now
		var at := _upper.bsearch(index)
		if now == 1:
			_upper.insert(at, index)
		else:
			_upper.remove_at(at)
		changed = true
	return changed

func _derive(upper: Vector3i) -> bool:
	var lower := upper + Vector3i(0, 0, 1)
	var upper_flags: int = _link_flags.call(upper)
	var lower_flags: int = _link_flags.call(lower)
	if upper_flags & DOWN == 0 or lower_flags & UP == 0:
		return false
	var upper_passable: bool = _passable.call(upper)
	var lower_passable: bool = _passable.call(lower)
	return upper_passable and lower_passable

func _flat(tile: Vector3i) -> int:
	return TileGrid.index_in(tile, _width, _height)

func _in_bounds(tile: Vector3i) -> bool:
	return (tile.x >= 0 and tile.x < _width and tile.y >= 0 and tile.y < _height
		and tile.z >= 0 and tile.z < _layer_count)
