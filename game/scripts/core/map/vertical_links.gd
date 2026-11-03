extends RefCounted

## Vertical links (ADR 045 §3, ADR 068): stairs, ramps and tunnels join (x, y, z) and
## (x, y, z + 1), straight up and down only. A link exists while the upper tile declares
## link_down, the lower one link_up, and both are colony-passable. Links are derived from the
## map (objects' link_up / link_down flags), never saved: a load rebuilds them.
## Owned by RegionMap, which feeds on_tile_changed() from TileGrid.on_passability_changed().

const UP := 1
const DOWN := 2

var _width: int
var _height: int
var _layer_count: int
var _layer_size: int
var _passable: Callable
var _link_flags: Callable
## _up[i] == 1: a link between flat index i and i + _layer_size (i on layers 0 .. count - 2).
var _up := PackedByteArray()
var _count := 0

## passable(tile: Vector3i) -> bool and link_flags(tile: Vector3i) -> int (UP | DOWN bits) are
## Passability.passable_tile() and link_flags(). A single layer has no links and no work.
func _init(width: int, height: int, layer_count: int, passable: Callable, link_flags: Callable) -> void:
	_width = width
	_height = height
	_layer_count = maxi(layer_count, 1)
	_layer_size = width * height
	_passable = passable
	_link_flags = link_flags
	_up.resize(_layer_size * (_layer_count - 1))
	_up.fill(0)
	if _layer_count < 2 or not _link_flags.is_valid():
		return
	for z in _layer_count - 1:
		for y in _height:
			for x in _width:
				if _derive(Vector3i(x, y, z)):
					_up[z * _layer_size + y * _width + x] = 1
					_count += 1

func layer_count() -> int:
	return _layer_count

## Number of links on the map.
func size() -> int:
	return _count

## True when lower links to the tile right above it.
func has_link_up(lower: Vector3i) -> bool:
	if not _in_bounds(lower) or lower.z >= _layer_count - 1:
		return false
	return _up[_flat(lower)] == 1

## True when upper links to the tile right below it.
func has_link_down(upper: Vector3i) -> bool:
	if not _in_bounds(upper) or upper.z < 1:
		return false
	return _up[_flat(upper) - _layer_size] == 1

## Every link's lower tile, in ascending flat index.
func links() -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if _count == 0:
		return result
	var index := _up.find(1)
	while index != -1:
		result.append(Vector3i(index % _width, index / _width % _height, index / _layer_size))
		index = _up.find(1, index + 1)
	return result

## Every link's lower tile as a flat index, ascending (RegionMap's graph build).
func lower_indices() -> PackedInt32Array:
	var result := PackedInt32Array()
	var index := _up.find(1) if _count > 0 else -1
	while index != -1:
		result.append(index)
		index = _up.find(1, index + 1)
	return result

## Re-derives the two links tile can take part in (below and above it); true when one changed.
func on_tile_changed(tile: Vector3i) -> bool:
	if _layer_count < 2 or not _in_bounds(tile):
		return false
	var changed := false
	for lower_z in [tile.z - 1, tile.z]:
		if lower_z < 0 or lower_z >= _layer_count - 1:
			continue
		var lower := Vector3i(tile.x, tile.y, lower_z)
		var index := _flat(lower)
		var now := 1 if _derive(lower) else 0
		if _up[index] != now:
			_up[index] = now
			_count += 1 if now == 1 else -1
			changed = true
	return changed

func _derive(lower: Vector3i) -> bool:
	var upper := lower + Vector3i(0, 0, 1)
	if int(_link_flags.call(lower)) & UP == 0 or int(_link_flags.call(upper)) & DOWN == 0:
		return false
	return bool(_passable.call(lower)) and bool(_passable.call(upper))

func _flat(tile: Vector3i) -> int:
	return tile.z * _layer_size + tile.y * _width + tile.x

func _in_bounds(tile: Vector3i) -> bool:
	return (tile.x >= 0 and tile.x < _width and tile.y >= 0 and tile.y < _height
		and tile.z >= 0 and tile.z < _layer_count)
