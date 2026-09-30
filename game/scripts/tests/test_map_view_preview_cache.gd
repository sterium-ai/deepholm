extends SceneTree

## map_view.gd's refresh() must not re-run preview_validity (the expensive per-tile
## dry run injected by boot.gd) every tick when the hover/drag rectangle and the world's tick
## both stayed the same -- refresh() is called once per tick unconditionally
## (boot.gd::_refresh()), and calling preview_validity from it on every one of those ticks is
## what froze pan/zoom while a tool was selected during Play, even after preview() itself
## stopped round-tripping through StateCodec. Proves _update_preview()'s own cache: a hover that
## does not move across 20 refresh() calls at the same tick invokes preview_validity exactly
## once, and again only once the tick advances or the hover moves.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

var _failed := false
var _preview_validity_calls := 0

func _init() -> void:
	var world := WorldStateType.new(346100, 10)
	var map_view := MapViewType.new()
	root.add_child(map_view)
	map_view.set_world(world)
	map_view.preview_validity = _counting_preview_validity
	map_view.tool_enabled = true

	var hover_tile := _find_tile(world, "floor")
	_expect(hover_tile != Vector2i(-1, -1), "a fresh 48x48 world must have at least one floor tile")
	map_view._hover = hover_tile
	map_view._suppress_hover = false

	for _i in 20:
		map_view.refresh()
	_expect(_preview_validity_calls == 1,
		"a hover that does not move across 20 refresh() calls at the same tick must invoke preview_validity exactly once, got %d" % _preview_validity_calls)

	world.tick()
	map_view.refresh()
	_expect(_preview_validity_calls == 2,
		"refresh() must invoke preview_validity again once the tick advances, got %d" % _preview_validity_calls)

	for _i in 5:
		map_view.refresh()
	_expect(_preview_validity_calls == 2,
		"further refresh() calls at the same (now unchanged) tick must not invoke preview_validity again, got %d" % _preview_validity_calls)

	var moved_tile := _find_tile(world, "floor", [hover_tile])
	_expect(moved_tile != Vector2i(-1, -1), "a fresh 48x48 world must have a second floor tile distinct from the first")
	map_view._hover = moved_tile
	map_view.refresh()
	_expect(_preview_validity_calls == 3,
		"refresh() must invoke preview_validity again once the hover moves, got %d" % _preview_validity_calls)

	# _current_preview_key() includes
	# world.get_tick(), which a successful build command does not advance --
	# while paused, the hovered site's key is otherwise unchanged across the
	# click, so without _commit_build() clearing the cache key itself,
	# refresh()'s own call inside it would be skipped and the just-claimed
	# site would keep showing its pre-claim validity.
	var colonist_tile := _find_tile(world, "floor", [hover_tile, moved_tile])
	_expect(colonist_tile != Vector2i(-1, -1), "a fresh 48x48 world must have a third floor tile for the build colonist")
	var build_site := _find_tile(world, "floor", [hover_tile, moved_tile, colonist_tile])
	_expect(build_site != Vector2i(-1, -1), "a fresh 48x48 world must have a fourth floor tile for the build site")
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": colonist_tile.x, "y": colonist_tile.y,
		"route": null, "work": null, "carrying": null})
	world._items["item_1"] = {"id": "item_1", "x": colonist_tile.x, "y": colonist_tile.y, "kind": "wood", "count": 1}
	world._next_item_id = 2
	world.apply({"actor": "test", "command_id": "zone_setup", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": colonist_tile.x, "y": colonist_tile.y, "width": 1, "height": 1}})

	map_view.set_build_tool_enabled(true)
	map_view.set_build_kind("wooden_wall")
	map_view._hover = build_site
	map_view._suppress_hover = false
	map_view.refresh()
	var calls_before_click := _preview_validity_calls
	var tick_before_click := world.get_tick()

	# A single-element Array, not a plain local: GDScript lambdas capture an
	# outer local by value, so only mutating a shared container (not
	# reassigning a captured variable) is visible after the signal fires.
	var last_build_result := [{}]
	map_view.build_committed.connect(func(result: Dictionary) -> void: last_build_result[0] = result)
	map_view._commit_build(build_site)
	_expect(bool((last_build_result[0] as Dictionary).get("ok", false)),
		"the build command itself must be accepted: %s" % [last_build_result[0]])
	_expect(world.get_tick() == tick_before_click, "a successful build command must not advance the simulation tick")
	_expect(_preview_validity_calls > calls_before_click,
		"a successful build click must invalidate the preview cache and recompute the hovered site's validity even though the tick did not advance (got %d calls before, %d after)"
			% [calls_before_click, _preview_validity_calls])

	root.remove_child(map_view)
	map_view.free()
	_finish()

func _counting_preview_validity(tiles: Array[Vector2i]) -> Array[bool]:
	_preview_validity_calls += 1
	var result: Array[bool] = []
	for _tile in tiles:
		result.append(true)
	return result

func _find_tile(world: WorldStateType, kind: String, excluded: Array[Vector2i] = []) -> Vector2i:
	var tiles: Array[String] = world.get_tiles()
	var width: int = world.get_map_width()
	for y in world.get_map_height():
		for x in width:
			if tiles[y * width + x] == kind and not excluded.has(Vector2i(x, y)):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _finish() -> void:
	if _failed:
		quit(1)
		return
	print("test_map_view_preview_cache: PASS")
	quit(0)
