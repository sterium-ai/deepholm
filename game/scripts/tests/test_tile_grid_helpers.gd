extends SceneTree

## TileGrid as the only owner of the flat tile index and the planar metrics (ADR 045 §2/§4, L1):
## the index is row-major (layer 0 keeps y * width + x), coord_of() inverts it, and manhattan,
## chebyshev and distance_sq stay three different formulas.

const TileGridType = preload("res://scripts/core/map/tile_grid.gd")

var _failed := false

func _init() -> void:
	_check_index_is_row_major()
	_check_metrics_stay_distinct()
	if _failed:
		quit(1)
		return
	print("test_tile_grid_helpers: PASS")
	quit()

func _check_index_is_row_major() -> void:
	var grid := TileGridType.new(7, 5, Callable(), Callable())
	for y in 5:
		for x in 7:
			var index := grid.index_of(Vector2i(x, y))
			_expect(index == y * 7 + x, "index_of(%d, %d) = %d, want %d" % [x, y, index, y * 7 + x])
			_expect(grid.tile_index(x, y) == index, "tile_index(%d, %d) differs from index_of()" % [x, y])
			_expect(TileGridType.flat_index(x, y, 7) == index, "flat_index(%d, %d, 7) differs from index_of()" % [x, y])
			_expect(grid.coord_of(index) == Vector2i(x, y), "coord_of(%d) = %s, want (%d, %d)" % [index, grid.coord_of(index), x, y])
			_expect(TileGridType.flat_coord(index, 7) == Vector2i(x, y), "flat_coord(%d, 7) is not index_of()'s inverse" % index)

func _check_metrics_stay_distinct() -> void:
	var a := Vector2i(2, 9)
	var b := Vector2i(5, 5)
	_expect(TileGridType.manhattan(a, b) == 7, "manhattan = %d, want 7" % TileGridType.manhattan(a, b))
	_expect(TileGridType.chebyshev(a, b) == 4, "chebyshev = %d, want 4" % TileGridType.chebyshev(a, b))
	_expect(TileGridType.distance_sq(a, b) == 25, "distance_sq = %d, want 25" % TileGridType.distance_sq(a, b))
	var metrics := {"manhattan": TileGridType.manhattan, "chebyshev": TileGridType.chebyshev,
		"distance_sq": TileGridType.distance_sq}
	for metric: String in metrics:
		var fn: Callable = metrics[metric]
		_expect(int(fn.call(a, b)) == int(fn.call(b, a)), "%s is not symmetric" % metric)
		_expect(int(fn.call(a, a)) == 0, "%s(a, a) is not 0" % metric)
	# The "next to" test (8 neighbours) is chebyshev <= 1; manhattan would drop the diagonals.
	_expect(TileGridType.chebyshev(Vector2i(3, 3), Vector2i(4, 4)) == 1, "a diagonal neighbour is not chebyshev 1")
	_expect(TileGridType.manhattan(Vector2i(3, 3), Vector2i(4, 4)) == 2, "a diagonal neighbour is not manhattan 2")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error("test_tile_grid_helpers: " + message)
		_failed = true
