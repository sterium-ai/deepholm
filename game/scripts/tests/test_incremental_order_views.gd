extends SceneTree

## B1 viewer: every incremental replacement must show what the full recompute
## it replaces showed.
## 1) MapView's per-tile drag preview (drag_preview.gd), grown tile by tile,
##    ends with exactly tiles_in_rectangle() and OrderInput.preview_validity()
##    over the whole rectangle -- also after a tick made it stale -- and a
##    one-column move validates only the newly covered column; jumps,
##    contractions and a narrower rectangle mid-work stay within the per-call
##    budget and end equal to a fresh preview; tiles whose orders changed are
##    re-validated on the next tick's refresh itself; a whole-map drag held
##    through ticks at X1 with one bounded step per frame catches up with a
##    global validity change everywhere (review 3); a Zone drag
##    previews one corner pair per move, keeps no per-tile list, and shows the
##    whole-rectangle zone_add validity;
## 2) the designation overlay's pixel per tile equals the colour of one
##    OUTLINE_COLOR rect per pending non-site_fetch job on that tile, through
##    orders, cancels, ticks and a save/load world swap;
## 3) a Cancel rectangle previewed through the core's tile index, and
##    committed as an area order, leaves the same jobs and reports the same
##    rejections as the former per-tile scan of every job;
## 4) the stockpile draw visits the same cells, in the same order, as the
##    former walk of every zone cell.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const OrderInputType = preload("res://scripts/viewer/order_input.gd")
const DesignationOverlayType = preload("res://scripts/viewer/designation_overlay.gd")
const DragPreviewType = preload("res://scripts/viewer/drag_preview.gd")

var _failures: Array[String] = []
var _n := 0

func _init() -> void:
	_check_drag_preview()
	_check_designation_overlay()
	_check_cancel_candidates()
	_check_stockpile_cells()
	if not _failures.is_empty():
		for failure in _failures:
			push_error(failure)
		quit(1)
		return
	print("test_incremental_order_views: PASS")
	quit(0)

func _check_drag_preview() -> void:
	var world := WorldStateType.new(4242, 10, 64, 64)
	var orders := OrderInputType.new()
	var view := MapViewType.new()
	view.set_world(world)
	var validated: Array[int] = [0]
	view.preview_validity = func(tiles: Array[Vector2i]) -> Array[bool]:
		validated[0] += tiles.size()
		return orders.preview_validity(world, world.preview, view, tiles)
	for tool in [OrderInputType.Tool.DIG, OrderInputType.Tool.CHOP, OrderInputType.Tool.MINE]:
		orders.select_tool(world, view, tool)
		_expect(view._preview_per_tile, "tool %d must preview per tile" % tool)
		_mouse(view, Vector2i(3, 2), true)
		for step in range(1, 30):
			_motion(view, Vector2i(3 + step, 2 + step / 2))
		view.finish_preview_work()
		var expected := MapViewType.tiles_in_rectangle(Vector2i(3, 2), Vector2i(32, 16))
		_expect(view._preview_tiles == expected, "tool %d: the drag must preview exactly its rectangle" % tool)
		_expect(view._preview_valid == orders.preview_validity(world, world.preview, view, expected),
			"tool %d: the incremental preview must equal a whole-rectangle preview" % tool)
		validated[0] = 0
		_motion(view, Vector2i(33, 16))
		_expect(validated[0] == 15, "a one-column move must validate only its 15 new tiles, validated %d" % validated[0])
		_mouse(view, Vector2i(33, 16), false)
		_expect(view._preview_tiles.is_empty(), "release must clear the preview")
	# Stale after a tick: a dig order lands on some previewed tiles; once the
	# deferred work runs, validity matches a fresh whole-rectangle preview.
	orders.select_tool(world, view, OrderInputType.Tool.CHOP)
	_mouse(view, Vector2i(0, 0), true)
	_motion(view, Vector2i(40, 40))
	view.finish_preview_work()
	var trees: Array[Vector2i] = []
	for tile in view._preview_tiles:
		if world.get_tile(tile.x, tile.y) == "tree":
			trees.append(tile)
	_expect(trees.size() >= 5, "sanity: the previewed rectangle must hold trees")
	for tile in trees.slice(0, 5):
		TestAccess.set_tile(world, tile.x, tile.y, "soil") # a test-only poke
	world.tick()
	view.refresh()
	view.finish_preview_work()
	var all_tiles := MapViewType.tiles_in_rectangle(Vector2i(0, 0), Vector2i(40, 40))
	_expect(view._preview_valid == orders.preview_validity(world, world.preview, view, all_tiles),
		"after a tick the refreshed preview must equal a fresh whole-rectangle preview")
	view.cancel_selection()
	# Changed tiles first: orders placed under a finished Cancel preview are
	# re-validated by the refresh() of the next tick itself, before any
	# deferred step.
	orders.select_tool(world, view, OrderInputType.Tool.CANCEL)
	_mouse(view, Vector2i(0, 0), true)
	_motion(view, Vector2i(40, 40))
	view.finish_preview_work()
	var ordered := MapViewType.tiles_in_rectangle(Vector2i(20, 20), Vector2i(23, 22))
	_rect(world, "dig", Vector2i(20, 20), Vector2i(4, 3))
	world.tick()
	view.refresh()
	var shown := view._preview_valid
	var fresh := orders.preview_validity(world, world.preview, view, ordered)
	_expect(fresh.has(true), "sanity: some of the dig orders must have landed")
	for i in ordered.size():
		_expect(shown[ordered[i].y * 41 + ordered[i].x] == fresh[i],
			"the tile ordered at %s must show its new Cancel validity on the next tick's refresh" % ordered[i])
	view.cancel_selection()
	_check_drag_preview_under_ticks()
	# Jumps and contractions mid-work: the whole map in one move, one deferred
	# step, then a narrower rectangle (the pending work must follow the new
	# shape, not the old width), a contraction to one tile and back, and a
	# tick in between. Each call validates at most TILE_BUDGET tiles; once the
	# work is done the preview equals a fresh whole-rectangle preview.
	orders.select_tool(world, view, OrderInputType.Tool.DIG)
	_mouse(view, Vector2i(0, 0), true)
	for corner in [Vector2i(63, 63), Vector2i(31, 63), Vector2i(0, 0), Vector2i(63, 40), Vector2i(10, 63)]:
		validated[0] = 0
		_motion(view, corner)
		_expect(validated[0] <= DragPreviewType.TILE_BUDGET, "a move to %s must validate at most TILE_BUDGET tiles, validated %d" % [corner, validated[0]])
		if corner == Vector2i(63, 40):
			world.tick()
			view.refresh()
		validated[0] = 0
		view._process(0.0)
		_expect(validated[0] <= DragPreviewType.TILE_BUDGET, "one deferred step must validate at most TILE_BUDGET tiles, validated %d" % validated[0])
	view.finish_preview_work()
	var final_tiles := MapViewType.tiles_in_rectangle(Vector2i(0, 0), Vector2i(10, 63))
	_expect(view._preview_tiles == final_tiles, "after jumps the drag must preview exactly its rectangle")
	_expect(view._preview_valid == orders.preview_validity(world, world.preview, view, final_tiles),
		"after jumps, a contraction and a tick the preview must equal a fresh whole-rectangle preview")
	view.cancel_selection()
	# Whole-rectangle tools keep the one-call preview.
	orders.select_tool(world, view, OrderInputType.Tool.ZONE)
	_expect(not view._preview_per_tile, "zone must preview the whole rectangle at once")
	for corner in [Vector2i(63, 63), Vector2i(12, 9)]:
		validated[0] = 0
		_mouse(view, Vector2i(0, 0), true)
		for step in range(1, 64):
			_motion(view, Vector2i(mini(step, corner.x), mini(step, corner.y)))
		_expect(validated[0] <= 2 * 64, "a zone drag must preview only the corners per move, validated %d" % validated[0])
		var whole := MapViewType.tiles_in_rectangle(Vector2i.ZERO, corner)
		_expect(view._list_tiles.is_empty(), "a zone drag must keep no per-tile list")
		_expect(view._preview_tiles == whole, "a zone drag must preview exactly its rectangle")
		_expect(view._preview_valid == orders.preview_validity(world, world.preview, view, whole),
			"a zone drag must show the whole-rectangle zone_add validity")
		view.cancel_selection()
		_expect(view._preview_tiles.is_empty(), "cancelling must clear the zone preview")
	view.free()

## Review 3 regression: a whole 256x256 drag held still while ticks keep
## coming (60 frames per second, a tick every 30 frames: X1), one bounded
## step per frame. Validity flips for every tile at one tick without any tile
## reported changed (state no tile log covers, like the last seed); the
## preview must show the new validity everywhere, the far corner included,
## within one rectangle's worth of steps -- restarting from the corner each
## tick never got past 30 * TILE_BUDGET tiles.
func _check_drag_preview_under_ticks() -> void:
	var size := 256
	var preview := DragPreviewType.new()
	preview.resize(size, size)
	var flipped: Array[bool] = [false]
	var validated: Array[int] = [0]
	var validity := func(tiles: Array[Vector2i]) -> Array[bool]:
		validated[0] += tiles.size()
		var result: Array[bool] = []
		for tile in tiles:
			result.append(((tile.x + tile.y) % 3 == 0) != flipped[0])
		return result
	var rect := Rect2i(0, 0, size, size)
	var tick := 0
	var flip_frame := 300
	# One rectangle's worth of steps, plus the tick frames among them.
	var settle_frames := ceili(float(size * size) / DragPreviewType.TILE_BUDGET) + 4
	for frame in range(flip_frame + settle_frames):
		validated[0] = 0
		if frame % 30 == 0:
			if frame == flip_frame:
				flipped[0] = true
			tick += 1
			preview.update(rect, tick, validity)
		else:
			preview.step(validity)
		_expect(validated[0] <= DragPreviewType.TILE_BUDGET, "frame %d validated %d tiles, over TILE_BUDGET" % [frame, validated[0]])
		if frame == flip_frame - 1:
			var before := preview.valid()
			_expect(before[-1] == (((size - 1) * 2) % 3 == 0), "the far corner must be validated before the flip")
	var shown := preview.valid()
	var wrong := 0
	for i in shown.size():
		var tile := Vector2i(i % size, i / size)
		if shown[i] != (((tile.x + tile.y) % 3 == 0) != true):
			wrong += 1
	_expect(wrong == 0, "%d of %d tiles still showed the validity from before the flip %d frames later, with a tick every 30 frames" % [wrong, shown.size(), settle_frames])

func _check_designation_overlay() -> void:
	var world := WorldStateType.new(4242, 10, 64, 64)
	var overlay := DesignationOverlayType.new()
	overlay.set_world(world)
	_rect(world, "dig", Vector2i(10, 10), Vector2i(20, 20))
	_rect(world, "dig", Vector2i(15, 15), Vector2i(4, 4)) # duplicates stack
	_rect(world, "chop", Vector2i(0, 0), Vector2i(64, 10))
	overlay.refresh()
	_expect_overlay(overlay, world, "after orders")
	var i := 0
	for job in world.get_jobs():
		if i % 4 == 0:
			_apply(world, "cancel_job", {"job_id": String(job["id"])})
		i += 1
	for t in 30:
		world.tick()
	overlay.refresh()
	_expect_overlay(overlay, world, "after cancels and ticks")
	var loaded = WorldStateType.from_save_state(JSON.parse_string(JSON.stringify(world.to_save_state())))
	overlay.set_world(loaded)
	_expect_overlay(overlay, loaded, "after a save/load world swap")
	_rect(loaded, "mine", Vector2i(0, 50), Vector2i(64, 14))
	overlay.refresh()
	_expect_overlay(overlay, loaded, "after orders on the loaded world")
	overlay.free()

func _expect_overlay(overlay, world, label: String) -> void:
	var counts := {}
	for job in world.get_jobs():
		if String(job["status"]) in ["queued", "active"] and String(job["kind"]) != "site_fetch":
			counts[job["target"]] = int(counts.get(job["target"], 0)) + 1
	var image: Image = overlay._image
	var wrong := 0
	for y in world.get_map_height():
		for x in world.get_map_width():
			var expected: Color = DesignationOverlayType.fill_color(int(counts.get(Vector3i(x, y, 0), 0)))
			if not _same_rgba8(image.get_pixel(x, y), expected):
				wrong += 1
	_expect(wrong == 0, "%s: %d overlay pixels must match the pending jobs" % [label, wrong])

## Equal once stored as RGBA8 (the image truncates, Color.r8 rounds).
static func _same_rgba8(a: Color, b: Color) -> bool:
	return (absi(a.r8 - b.r8) <= 1 and absi(a.g8 - b.g8) <= 1
		and absi(a.b8 - b.b8) <= 1 and absi(a.a8 - b.a8) <= 1)

func _check_cancel_candidates() -> void:
	var world := WorldStateType.new(4242, 10, 64, 64)
	_rect(world, "dig", Vector2i(5, 5), Vector2i(30, 30))
	_rect(world, "dig", Vector2i(10, 10), Vector2i(5, 5))
	for t in 20:
		world.tick()
	# Both sides start from the same load, so only the Cancel path differs.
	var saved := JSON.stringify(world.to_save_state())
	world = WorldStateType.from_save_state(JSON.parse_string(saved))
	var twin = WorldStateType.from_save_state(JSON.parse_string(saved))
	var orders := OrderInputType.new()
	orders.selected_tool = OrderInputType.Tool.CANCEL
	var tiles := MapViewType.tiles_in_rectangle(Vector2i(0, 0), Vector2i(40, 40))
	var previewed := orders.preview_validity(world, world.preview, null, tiles)
	var rejected := orders.commit_rectangle(world, null, tiles)
	# 1681 tiles: the area order expands TILES_PER_STEP now; drain the rest at
	# this same tick (what the next ticks would do first) to compare like for like.
	while TestAccess.area_orders(world).remaining_tiles(1) > 0:
		for entry in TestAccess.area_orders(world).advance():
			rejected.append({"tile": Vector2i(entry["x"], entry["y"]), "reason": entry["reason"]})
	# The former path: every tile scans every job (no tile index).
	var expected_preview: Array[bool] = []
	for tile in tiles:
		var command := _scan_cancel_command(twin, tile)
		expected_preview.append(not command.is_empty() and twin.preview(command).get("ok", false))
	var expected_rejected: Array[Dictionary] = []
	for tile in tiles:
		var command := _scan_cancel_command(twin, tile)
		if command.is_empty():
			continue
		var result: Dictionary = twin.apply(command)
		if not result.get("ok", false):
			expected_rejected.append({"tile": tile, "reason": String(result["rejection"]["reason"])})
	_expect(previewed == expected_preview, "the Cancel preview must match the per-tile scan")
	_expect(rejected == expected_rejected, "Cancel must report the same rejections as the per-tile scan")
	_expect(world.get_jobs() == twin.get_jobs(), "Cancel must leave the same jobs as the per-tile scan")
	_expect(world.get_construction_sites() == twin.get_construction_sites(), "Cancel must leave the same sites as the per-tile scan")

## The former Cancel lookup (before B1): a site on the tile, else the best
## pending job among every job whose order tile it is.
func _scan_cancel_command(world, tile: Vector2i) -> Dictionary:
	var command := {"actor": "player", "command_id": "scan_cancel_%d_%d" % [tile.x, tile.y], "tick": world.get_tick()}
	var site: Dictionary = world.get_construction_site(tile.x, tile.y)
	if not site.is_empty():
		command["type"] = "cancel_site"
		command["payload"] = {"x": int(site["origin"].x), "y": int(site["origin"].y), "z": 0}
		return command
	var best := {}
	for job in world.get_jobs():
		if job["status"] not in ["queued", "active"] or OrderInputType._order_tile(job) != Vector3i(tile.x, tile.y, 0):
			continue
		if best.is_empty() or AreaOrders.cancel_before(job, best):
			best = job
	if best.is_empty():
		return {}
	command["type"] = "cancel_job"
	command["payload"] = {"job_id": best["id"]}
	return command

func _check_stockpile_cells() -> void:
	var world := WorldStateType.new(4242, 10, 64, 64)
	var view := MapViewType.new()
	view.set_world(world)
	_apply(world, "zone_add", {"x": 20, "y": 20, "z": 0, "width": 6, "height": 4})
	_apply(world, "zone_add", {"x": 2, "y": 40, "z": 0, "width": 3, "height": 3})
	# The map draws from the view snapshot of its last refresh() (A9, ADR 055); these
	# commands bypassed the map, so refresh it as boot.gd does after every command.
	view.refresh()
	var counts := {}
	for cell in [Vector2i(21, 21), Vector2i(3, 41), Vector2i(25, 23), Vector2i(20, 20), Vector2i(50, 50), Vector2i(2, 42)]:
		counts[cell] = {"wood": 1}
	var expected: Array[Vector2i] = []
	for zone in world.get_zones():
		for y in range(int(zone["y"]), int(zone["y"]) + int(zone["height"])):
			for x in range(int(zone["x"]), int(zone["x"]) + int(zone["width"])):
				if counts.has(Vector2i(x, y)):
					expected.append(Vector2i(x, y))
	_expect(view._zoned_cells_in_draw_order(counts) == expected,
		"the stockpile draw must visit the zoned item cells in zone, then row-major order")
	view.free()

func _apply(world, type: String, payload: Dictionary) -> Dictionary:
	_n += 1
	return world.apply({"actor": "player", "command_id": "v%d" % _n, "tick": world.get_tick(), "type": type, "payload": payload})

func _rect(world, type: String, origin: Vector2i, size: Vector2i) -> void:
	for y in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			_apply(world, type, {"x": x, "y": y, "z": 0, "priority": 1})

func _mouse(view, tile: Vector2i, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = (Vector2(tile) + Vector2(0.5, 0.5)) * MapViewType.TILE_SIZE
	view._gui_input(event)

func _motion(view, tile: Vector2i) -> void:
	var event := InputEventMouseMotion.new()
	event.position = (Vector2(tile) + Vector2(0.5, 0.5)) * MapViewType.TILE_SIZE
	view._gui_input(event)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
