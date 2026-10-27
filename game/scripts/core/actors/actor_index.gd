class_name ActorIndex
extends RefCounted

## A4: actor id -> actor and tile -> actors over WorldState's live roster
## (`_colonists`), so `_find_colonist()`, `_colonist_at()` and
## `_is_cell_occupied()` are lookups instead of a pass over every actor.
## Plain data, no scene/node/wall-clock dependency.
##
## Invariants:
## - Trusted only inside WorldState.tick(): begin_tick() rebuilds it from the
##   roster and end_tick() drops it. Outside a tick (commands, viewer reads,
##   tests that write an actor's x/y or the roster directly) every query runs
##   the same linear pass over the roster as before A4, so an out-of-band
##   write is never answered from a stale index.
## - Inside a tick, every roster or position change goes through added(),
##   removed(), moved() or replaced(): WorldState._append_colonist()/_remove_colonist_by_id(),
##   ToilExecutor.advance_route_step(), TrenchSystem's rescue/escape moves and
##   NeedsSystem.ensure_needs(), which rebuilds an incomplete actor as a new Dictionary.
## - Actor ids are unique in the roster. begin_tick() leaves the index
##   untrusted (linear queries) for a tick whose roster repeats an id.
## - Order inside a tile is not meaningful: every caller asks "any actor here"
##   or picks by id, never by position in the list.
## - Never persisted and never hashed: it is derived from the roster.

var _trusted := false
## id -> live actor Dictionary (the roster's own reference).
var _by_id: Dictionary = {}
## Vector2i -> Array[Dictionary] of live actors standing there.
var _by_tile: Dictionary = {}
## id -> Vector2i the actor is filed under in _by_tile.
var _tile_of: Dictionary = {}

func begin_tick(actors: Array[Dictionary]) -> void:
	_clear()
	for actor in actors:
		if _by_id.has(_id(actor)):
			_clear()
			return
		_add(actor)
	_trusted = true

func end_tick() -> void:
	_clear()

func is_trusted() -> bool:
	return _trusted

func added(actor: Dictionary) -> void:
	if _trusted:
		_add(actor)

func removed(actor: Dictionary) -> void:
	if not _trusted:
		return
	var actor_id := _id(actor)
	var tile: Vector2i = _tile_of.get(actor_id, _tile(actor))
	_by_id.erase(actor_id)
	_unfile(actor, tile)
	_tile_of.erase(actor_id)

## old's roster slot now holds new (same id): files new in old's place.
func replaced(old: Dictionary, new: Dictionary) -> void:
	if not _trusted:
		return
	removed(old)
	_add(new)

## Call after writing actor's "x"/"y".
func moved(actor: Dictionary) -> void:
	if not _trusted:
		return
	var actor_id := _id(actor)
	var to := _tile(actor)
	var from: Vector2i = _tile_of.get(actor_id, to)
	if from == to:
		return
	_unfile(actor, from)
	_file(actor, to)

## The live actor Dictionary for actor_id, or {} when unknown.
func find(actors: Array[Dictionary], actor_id: String) -> Dictionary:
	if _trusted:
		return _by_id.get(actor_id, {})
	for actor in actors:
		if _id(actor) == actor_id:
			return actor
	return {}

## True when any actor other than excluding_id ("" for none) stands on (x, y).
func any_at(actors: Array[Dictionary], x: int, y: int, excluding_id: String = "") -> bool:
	if _trusted:
		for actor: Dictionary in _by_tile.get(Vector2i(x, y), []):
			if _id(actor) != excluding_id:
				return true
		return false
	var tile := Vector2i(x, y)
	for actor in actors:
		if _id(actor) != excluding_id and _tile(actor) == tile:
			return true
	return false

func _clear() -> void:
	_trusted = false
	_by_id.clear()
	_by_tile.clear()
	_tile_of.clear()

func _add(actor: Dictionary) -> void:
	_by_id[_id(actor)] = actor
	_file(actor, _tile(actor))

func _file(actor: Dictionary, tile: Vector2i) -> void:
	if not _by_tile.has(tile):
		_by_tile[tile] = []
	(_by_tile[tile] as Array).append(actor)
	_tile_of[_id(actor)] = tile

func _unfile(actor: Dictionary, tile: Vector2i) -> void:
	var occupants: Array = _by_tile.get(tile, [])
	for i in occupants.size():
		if is_same(occupants[i], actor):
			occupants.remove_at(i)
			break
	if occupants.is_empty():
		_by_tile.erase(tile)

static func _id(actor: Dictionary) -> String:
	return str(actor["id"])

static func _tile(actor: Dictionary) -> Vector2i:
	var x: int = actor["x"]
	var y: int = actor["y"]
	return Vector2i(x, y)
