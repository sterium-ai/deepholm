extends RefCounted

## MapView's incremental drag preview for tools whose validity is per tile
## (OrderInput.previews_per_tile(); B1). Previewing a whole rectangle on every
## mouse move cost ~10 us per tile through WorldState.preview(): 0.85 s per
## move for a full 256x256 drag, so the drawn selection trailed the cursor.
## Instead:
## - a rectangle change costs a few native fills -- at most four strips the
##   rectangle left are cleared, at most four it newly covers are filled
##   "unknown" -- plus at most VISIT_BUDGET tiles painted and TILE_BUDGET
##   validated now, newly covered ones first; the rest continues a budget per
##   frame through step(), however far the cursor jumped;
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
##
## Invariant: every tile of _rect is either current (validated at this
## generation and painted with its state) or inside exactly one _pending
## rectangle; _pending rectangles lie inside _rect and never overlap. They are
## plain rectangles (partly done ones are split, never given a cursor), so a
## new rectangle of any shape only intersects them.

const TILE_BUDGET := 1024
const VISIT_BUDGET := 8192
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
## Rectangles of _rect still to paint and, where stale or unknown, validate;
## processed front first.
var _pending: Array[Rect2i] = []
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
	return not _pending.is_empty()

## Drops the rectangle and every known validity (a new drag, tool or world).
func clear() -> void:
	_generation += 1
	_rect = Rect2i()
	_pending = []
	_tick = -1
	_uniform = -1
	if _image != null:
		_image.fill(Color(0, 0, 0, 0))
		_texture.update(_image)

## Moves the previewed rectangle to `rect` at world tick `tick`, then paints
## and validates (through `validity`, OrderInput.preview_validity()'s shape)
## newly covered tiles only, within the per-call budgets: stale tiles the
## rectangle already showed wait for step(), so a mouse move costs what it
## uncovers.
func update(rect: Rect2i, tick: int, validity: Callable) -> void:
	if _image == null:
		return
	if _uniform >= 0:
		clear()
	rect = rect.intersection(Rect2i(0, 0, _width, _height))
	var previous := _rect
	_rect = rect
	for strip in _strips(previous, rect):
		_image.fill_rect(strip, Color(0, 0, 0, 0))
	var fresh := _strips(rect, previous)
	var fresh_area := 0
	for strip in fresh:
		_image.fill_rect(strip, Color(UNKNOWN_COLOR, FILL_ALPHA))
		fresh_area += strip.get_area()
	var kept: Array[Rect2i] = []
	if tick != _tick:
		_tick = tick
		_generation += 1
		var overlap := previous.intersection(rect)
		if overlap.has_area():
			kept.append(overlap)
	else:
		for pending in _pending:
			var clipped := pending.intersection(rect)
			if clipped.has_area():
				kept.append(clipped)
	_pending = fresh
	_pending.append_array(kept)
	_process(validity, mini(fresh_area, VISIT_BUDGET))
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

## Continues the pending work within the per-call budgets. Returns true while
## work remains.
func step(validity: Callable) -> bool:
	if _pending.is_empty():
		return false
	_process(validity, VISIT_BUDGET)
	_texture.update(_image)
	return not _pending.is_empty()

## Every tile of the rectangle, row-major (MapView.tiles_in_rectangle()'s
## order). Tests and benchmarks only: it allocates the whole rectangle.
func tiles() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in range(_rect.position.y, _rect.end.y):
		for x in range(_rect.position.x, _rect.end.x):
			result.append(Vector2i(x, y))
	return result

## Whether each tiles() entry is currently known valid (tests and benchmarks).
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

## Visits _pending tiles front first, row-major within each rectangle: paints
## each with its last known state and collects the stale or unknown ones,
## until `max_visits` (at most VISIT_BUDGET) tiles are visited or TILE_BUDGET
## collected; the partly visited rectangle is split into its unvisited rest.
## Then validates them.
func _process(validity: Callable, max_visits: int) -> void:
	var todo: Array[Vector2i] = []
	var visits := 0
	while not _pending.is_empty() and visits < max_visits and todo.size() < TILE_BUDGET:
		var pending: Rect2i = _pending[0]
		var total := pending.get_area()
		var i := 0
		while i < total and visits < max_visits and todo.size() < TILE_BUDGET:
			var tile := pending.position + Vector2i(i % pending.size.x, i / pending.size.x)
			var index := tile.y * _width + tile.x
			_paint(tile, index)
			if _generation_of[index] != _generation:
				todo.append(tile)
			visits += 1
			i += 1
		_pending.remove_at(0)
		var rest := _rest(pending, i)
		for k in rest.size():
			_pending.insert(k, rest[k])
	_validate(todo, validity)

## The tiles of `rect` from row-major index `from` on, as at most two
## rectangles (the rest of that row, then the rows below).
static func _rest(rect: Rect2i, from: int) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	if from >= rect.get_area():
		return result
	var row := from / rect.size.x
	var column := from % rect.size.x
	if column > 0:
		result.append(Rect2i(rect.position.x + column, rect.position.y + row, rect.size.x - column, 1))
		row += 1
	if row < rect.size.y:
		result.append(Rect2i(rect.position.x, rect.position.y + row, rect.size.x, rect.size.y - row))
	return result

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

func _color(state: int) -> Color:
	match state:
		State.VALID: return VALID_COLOR
		State.INVALID: return INVALID_COLOR
		_: return UNKNOWN_COLOR

## The tiles of `a` not in `b`, as at most four rectangles.
static func _strips(a: Rect2i, b: Rect2i) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	if not a.has_area():
		return result
	var overlap := a.intersection(b)
	if not overlap.has_area():
		result.append(a)
		return result
	for strip in [
		Rect2i(a.position.x, a.position.y, a.size.x, overlap.position.y - a.position.y),
		Rect2i(a.position.x, overlap.end.y, a.size.x, a.end.y - overlap.end.y),
		Rect2i(a.position.x, overlap.position.y, overlap.position.x - a.position.x, overlap.size.y),
		Rect2i(overlap.end.x, overlap.position.y, a.end.x - overlap.end.x, overlap.size.y),
	]:
		if strip.has_area():
			result.append(strip)
	return result
