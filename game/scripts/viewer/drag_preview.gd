extends RefCounted

## MapView's incremental drag preview for tools whose validity is per tile
## (OrderInput.previews_per_tile(); B1). Previewing a whole rectangle on every
## mouse move cost ~10 us per tile through WorldState.preview(): 0.85 s per
## move for a full 256x256 drag, so the drawn selection trailed the cursor.
## Instead:
## - a rectangle change validates only the tiles it newly covers (at most
##   PREVIEW_TILE_BUDGET now; the rest a budget per frame through step());
## - known validity is kept per map cell for the whole drag. A new tick marks
##   it stale (it may have changed) and step() re-validates it a budget per
##   frame, showing the last known colour meanwhile -- a coarse preview; the
##   release still applies every tile through the exact rules (apply());
## - the fill is one RGBA8 pixel per map cell in a texture drawn scaled, not
##   three draw calls per tile; outlines and invalid crosses are drawn only for
##   on-screen tiles, and only while there are few enough of them.
## A tool that judges the whole rectangle at once (Zone) shows it through
## show_uniform() instead: one validity for every tile, two native fills per
## change.
## Presentation only: never mutates the world, holds no world reference.

const TILE_BUDGET := 1024
const OUTLINE_TILE_LIMIT := 4096
const VALID_COLOR := Color(0.3, 1.0, 0.55)
const INVALID_COLOR := Color(1.0, 0.3, 0.3)
const UNKNOWN_COLOR := Color(1.0, 1.0, 1.0)
const FILL_ALPHA := 0.22

enum State { UNKNOWN, VALID, INVALID }

var _width := 0
var _height := 0
## Per map cell: its State, and the generation that state was computed at.
var _state := PackedByteArray()
var _generation_of := PackedInt32Array()
var _generation := 1
var _tick := -1
var _rect := Rect2i()
## Row-major index into _rect from which step() still looks for stale or
## unknown tiles; -1 when every tile in _rect is current.
var _cursor := -1
## The State every tile of _rect shows under show_uniform(); -1 otherwise.
var _uniform := -1
var _image: Image
var _texture: ImageTexture

func resize(width: int, height: int) -> void:
	_width = maxi(width, 1)
	_height = maxi(height, 1)
	_state = PackedByteArray()
	_state.resize(_width * _height)
	_generation_of = PackedInt32Array()
	_generation_of.resize(_width * _height)
	_image = Image.create(_width, _height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	clear()

func is_active() -> bool:
	return _rect.has_area()

func rect() -> Rect2i:
	return _rect

func has_work() -> bool:
	return _cursor >= 0 and _rect.has_area()

## Drops the rectangle and every known validity (a new drag, tool or world).
func clear() -> void:
	_generation += 1
	_rect = Rect2i()
	_cursor = -1
	_tick = -1
	_uniform = -1
	if _image != null:
		_image.fill(Color(0, 0, 0, 0))
		_texture.update(_image)

## Moves the previewed rectangle to `rect` at world tick `tick`, validating
## (through `validity`, OrderInput.preview_validity()'s shape) at most
## TILE_BUDGET of the tiles that need it, newly covered ones first.
func update(rect: Rect2i, tick: int, validity: Callable) -> void:
	if _image == null:
		return
	if _uniform >= 0:
		clear()
	rect = rect.intersection(Rect2i(0, 0, _width, _height))
	if tick != _tick:
		_tick = tick
		_generation += 1
		_cursor = 0
	var previous := _rect
	_rect = rect
	_clear_difference(previous, rect)
	var todo: Array[Vector2i] = []
	for tile in _difference(rect, previous):
		var index := tile.y * _width + tile.x
		_paint(tile, index)
		if _generation_of[index] != _generation:
			if todo.size() < TILE_BUDGET:
				todo.append(tile)
			elif _cursor < 0:
				_cursor = 0
	_validate(todo, validity)
	_texture.update(_image)

## Shows `rect` with one validity for all of its tiles: clears the previous
## rectangle's fill and fills the new one, no per-tile work.
func show_uniform(rect: Rect2i, valid: bool) -> void:
	if _image == null:
		return
	if _uniform < 0:
		clear()
	elif _rect.has_area():
		_image.fill_rect(_rect, Color(0, 0, 0, 0))
	_rect = rect.intersection(Rect2i(0, 0, _width, _height))
	_uniform = State.VALID if valid else State.INVALID
	_image.fill_rect(_rect, Color(_color(_uniform), FILL_ALPHA))
	_texture.update(_image)

## Re-validates up to TILE_BUDGET stale or unknown tiles of the rectangle.
## Returns true while work remains.
func step(validity: Callable) -> bool:
	if _cursor < 0 or not _rect.has_area():
		_cursor = -1
		return false
	var todo: Array[Vector2i] = []
	var total := _rect.get_area()
	while _cursor < total and todo.size() < TILE_BUDGET:
		var tile := _rect.position + Vector2i(_cursor % _rect.size.x, _cursor / _rect.size.x)
		if _generation_of[tile.y * _width + tile.x] != _generation:
			todo.append(tile)
		_cursor += 1
	if _cursor >= total:
		_cursor = -1
	_validate(todo, validity)
	if not todo.is_empty():
		_texture.update(_image)
	return _cursor >= 0

## Every tile of the rectangle, row-major (MapView.tiles_in_rectangle()'s order).
func tiles() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in range(_rect.position.y, _rect.end.y):
		for x in range(_rect.position.x, _rect.end.x):
			result.append(Vector2i(x, y))
	return result

## Whether each tiles() entry is currently known valid.
func valid() -> Array[bool]:
	var result: Array[bool] = []
	for tile in tiles():
		result.append(_state_at(tile.y * _width + tile.x) == State.VALID)
	return result

## Draws onto `canvas` (inside its _draw()): the fill texture, then outlines
## and crosses for the tiles of `visible` (in tiles) within the rectangle.
func draw(canvas: CanvasItem, tile_size: float, visible: Rect2i) -> void:
	if not _rect.has_area():
		return
	canvas.draw_texture_rect(_texture, Rect2(Vector2.ZERO, Vector2(_width, _height) * tile_size), false)
	var shown := visible.intersection(_rect)
	if not shown.has_area() or shown.get_area() > OUTLINE_TILE_LIMIT:
		return
	for y in range(shown.position.y, shown.end.y):
		for x in range(shown.position.x, shown.end.x):
			var state := _state_at(y * _width + x)
			var color := _color(state)
			var cell := Rect2(Vector2(x, y) * tile_size, Vector2.ONE * tile_size)
			canvas.draw_rect(cell, color, false, 1.0)
			if state != State.VALID:
				canvas.draw_line(cell.position + Vector2(3, 3), cell.end - Vector2(3, 3), color, 1.0)

func _validate(tiles: Array[Vector2i], validity: Callable) -> void:
	if tiles.is_empty() or not validity.is_valid():
		return
	var results: Array = validity.call(tiles)
	for i in tiles.size():
		var tile := tiles[i]
		var index := tile.y * _width + tile.x
		_state[index] = State.VALID if i < results.size() and bool(results[i]) else State.INVALID
		_generation_of[index] = _generation
		if _rect.has_point(tile):
			_paint(tile, index)

func _state_at(index: int) -> int:
	return _uniform if _uniform >= 0 else _state[index]

func _paint(tile: Vector2i, index: int) -> void:
	_image.set_pixelv(tile, Color(_color(_state[index]), FILL_ALPHA))

## Clears the pixels of `from` that `to` no longer covers.
func _clear_difference(from: Rect2i, to: Rect2i) -> void:
	for tile in _difference(from, to):
		_image.set_pixelv(tile, Color(0, 0, 0, 0))

func _color(state: int) -> Color:
	match state:
		State.VALID: return VALID_COLOR
		State.INVALID: return INVALID_COLOR
		_: return UNKNOWN_COLOR

## The tiles of `a` not in `b`, as at most four row-major strips.
static func _difference(a: Rect2i, b: Rect2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not a.has_area():
		return result
	var overlap := a.intersection(b)
	if not overlap.has_area():
		for y in range(a.position.y, a.end.y):
			for x in range(a.position.x, a.end.x):
				result.append(Vector2i(x, y))
		return result
	for y in range(a.position.y, a.end.y):
		if y < overlap.position.y or y >= overlap.end.y:
			for x in range(a.position.x, a.end.x):
				result.append(Vector2i(x, y))
		else:
			for x in range(a.position.x, overlap.position.x):
				result.append(Vector2i(x, y))
			for x in range(overlap.end.x, a.end.x):
				result.append(Vector2i(x, y))
	return result
