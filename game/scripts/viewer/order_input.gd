extends RefCounted

## The debug viewer's order input: which tool and wall kind are selected,
## the toolbar buttons that show it, and how a tool + tile rectangle turns
## into WorldState commands (applied, or dry-run through WorldState.preview()
## for hover colouring). Holds no world or map view of its own: boot.gd owns
## those references and passes them in on every call, so a test that swaps
## boot.world or boot._map_view is picked up immediately. WorldState.preview()
## is not a call viewer scripts may make themselves (test_architecture_rules.gd's
## viewer purity), so boot.gd passes it in -- as it does for map_view.gd's
## preview_validity.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

enum Tool { DIG, CHOP, FORAGE, CANCEL, WALL, REMOVE_OBJECT, ZONE, TILL, SOW, MINE, BUILD_DOOR, BUILD_BED, BUILD_WORKBENCH }

var selected_tool: int = -1
var wall_kind := "wooden_wall"
var tool_buttons: Dictionary = {}
var wall_kind_buttons: Dictionary = {}
var rotate_build_button: Button
## The last tile an order rectangle ended on; boot.gd's room label reads it.
var inspected_tile: Vector2i = Vector2i(-1, -1)
var has_inspected_tile: bool = false
## Cancel's tile -> pending jobs map (_pending_jobs_by_tile()) and the
## (world, tick, designation cursor) it was read at: no job can appear without
## advancing one of those, and every use re-reads its candidates' live status,
## so a preview drag reuses one get_jobs() read instead of one per call (B1).
var _cancel_jobs_by_tile: Dictionary = {}
var _cancel_jobs_key: Array = []
var _next_area_order := 0

## Runs the exact same command rules apply() would (WorldState.preview()) without
## mutating state or round-tripping through StateCodec: a read-only dry run per tile, in exactly
## commit order. Preview introduces neither duplicated rules nor live events.
func preview_validity(world: WorldStateType, preview: Callable, map_view: MapViewType, tiles: Array[Vector2i]) -> Array[bool]:
	var result: Array[bool] = []
	if selected_tool == Tool.WALL:
		var outcome: Dictionary = preview.call(wall_command(world, tiles))
		var skipped := {}
		for entry in outcome.get("skipped", []):
			skipped[Vector2i(entry["x"], entry["y"])] = true
		for tile in tiles:
			result.append(bool(outcome.get("ok", false)) and not skipped.has(tile))
	elif selected_tool == Tool.ZONE:
		var first := tiles[0]
		var last := tiles[-1]
		var outcome: Dictionary = preview.call({
			"actor": "player", "command_id": "preview_zone", "tick": world.get_tick(), "type": "zone_add",
			"payload": {"x": first.x, "y": first.y, "width": last.x - first.x + 1, "height": last.y - first.y + 1}})
		for tile in tiles:
			result.append(outcome.get("ok", false))
	else:
		var is_footprint_preview := build_kind_for_tool(selected_tool) == "workbench" and tiles.size() == 2
		if is_footprint_preview:
			var origin := tiles[0]
			var delta := Vector2i.DOWN if build_orientation(map_view) == "vertical" else Vector2i.RIGHT
			is_footprint_preview = tiles[1] == origin + delta
		if is_footprint_preview:
			var command := command_for_tile(world, map_view, selected_tool, tiles[0])
			var valid: bool = not command.is_empty() and bool(preview.call(command).get("ok", false))
			for tile in tiles:
				result.append(valid)
		else:
			var pending_by_tile = _cancel_candidates(world) if selected_tool == Tool.CANCEL else null
			for tile in tiles:
				var command := command_for_tile(world, map_view, selected_tool, tile, pending_by_tile)
				result.append(not command.is_empty() and preview.call(command).get("ok", false))
	return result

## Tools whose preview validity is per tile, independent of the rest of the
## rectangle: MapView may then preview a drag incrementally (B1). Wall and zone
## judge the whole rectangle at once; the build tools preview one footprint.
static func previews_per_tile(tool: int) -> bool:
	return tool in [Tool.DIG, Tool.CHOP, Tool.FORAGE, Tool.CANCEL, Tool.REMOVE_OBJECT, Tool.TILL, Tool.SOW, Tool.MINE]

func _cancel_candidates(world: WorldStateType) -> Dictionary:
	var key := [world, world.get_tick(), int(world.get_designation_changes(-1)["next"])]
	if key != _cancel_jobs_key:
		_cancel_jobs_key = key
		_cancel_jobs_by_tile = _pending_jobs_by_tile(world)
	return _cancel_jobs_by_tile

## `pending_by_tile` (Cancel only, optional): a _pending_jobs_by_tile() map to
## pick the job from instead of reading every job for this one tile.
static func command_for_tile(world: WorldStateType, map_view: MapViewType, tool: int, tile: Vector2i,
		pending_by_tile = null) -> Dictionary:
	if tool == Tool.CANCEL:
		var site := world.get_construction_site(tile.x, tile.y)
		if not site.is_empty():
			return {
				"actor": "player", "command_id": "viewer_cancel_site_%s" % site["id"],
				"tick": world.get_tick(), "type": "cancel_site",
				"payload": {"x": int(site["origin"].x), "y": int(site["origin"].y)},
			}
		var candidate := _cancel_job_for_tile(world, tile, pending_by_tile)
		if candidate.is_empty():
			return {}
		return {
			"actor": "player", "command_id": "viewer_cancel_%s" % candidate["id"],
			"tick": world.get_tick(), "type": "cancel_job",
			"payload": {"job_id": candidate["id"]},
		}
	if tool == Tool.REMOVE_OBJECT:
		return {
			"actor": "player",
			"command_id": "viewer_remove_object_%d_%d_%d" % [world.get_tick(), tile.x, tile.y],
			"tick": world.get_tick(),
			"type": "remove_object",
			"payload": {"x": tile.x, "y": tile.y},
		}
	# Build tools: the same command map_view.gd's
	# click path submits, so preview_validity()'s hover colouring runs the
	# identical read-only rule (WorldState.preview() -> _check_build_command()).
	var build_kind := build_kind_for_tool(tool)
	if not build_kind.is_empty():
		var payload := {"kind": build_kind, "x": tile.x, "y": tile.y}
		if build_kind_is_rotatable(world, build_kind):
			payload["orientation"] = map_view.get_build_orientation() if map_view != null else "horizontal"
		return {
			"actor": "player",
			"command_id": "viewer_build_%s_%d_%d_%d" % [build_kind, world.get_tick(), tile.x, tile.y],
			"tick": world.get_tick(),
			"type": "build",
			"payload": payload,
		}
	var command_type := command_type_for_tool(tool)
	if command_type.is_empty():
		return {}
	return {
		"actor": "player",
		"command_id": "viewer_%s_%d_%d_%d" % [command_type, world.get_tick(), tile.x, tile.y],
		"tick": world.get_tick(),
		"type": command_type,
		"payload": {"x": tile.x, "y": tile.y, "priority": 1},
	}

## The tile a pending order is interacted with at: a site_fetch/site_work
## job's construction site (its "target" is the fetch source tile or the
## site itself, but "site" always names the site); for any other job, its
## target.
static func _order_tile(job: Dictionary) -> Vector2i:
	if job.get("site") != null:
		return job["site"]
	return job["target"]

## A construction site has no job at all until ConstructionGiver submits one
## on its own per-tick schedule (ADR 040), so ordering a build and
## cancelling it before the next tick must still resolve to something: falls
## back to the site record itself, keyed by any of its footprint tiles
## (get_construction_site()) -- WorldState._apply_cancel_job_command()
## recognises the same site id standing in for a job id.
## With `pending_by_tile`, the candidates are that map's jobs for this tile,
## each re-read live (world.get_job()) so one cancelled or re-activated since
## the map was built is judged by its current status, exactly as a fresh
## get_jobs() scan would.
static func _cancel_job_for_tile(world: WorldStateType, tile: Vector2i, pending_by_tile = null) -> Dictionary:
	var best := {}
	var candidates: Array = world.get_jobs() if pending_by_tile == null else pending_by_tile.get(tile, [])
	for candidate in candidates:
		var job: Dictionary = candidate if pending_by_tile == null else world.get_job(String(candidate["id"]))
		if job.is_empty() or job["status"] not in ["queued", "active"] or _order_tile(job) != tile:
			continue
		if best.is_empty() or _cancel_job_before(job, best):
			best = job
	if not best.is_empty():
		return best
	var site := world.get_construction_site(tile.x, tile.y)
	if not site.is_empty():
		return {"id": site["id"]}
	return {}

## tile -> every queued/active job whose _order_tile() it is, in get_jobs()
## order, from a single get_jobs() read.
static func _pending_jobs_by_tile(world: WorldStateType) -> Dictionary:
	var by_tile := {}
	for job in world.get_jobs():
		if job["status"] not in ["queued", "active"]:
			continue
		var tile := _order_tile(job)
		if not by_tile.has(tile):
			by_tile[tile] = []
		by_tile[tile].append(job)
	return by_tile

## The core's own Cancel preference (AreaOrders.cancel_before()), so the
## preview and an expanded area order always pick the same job.
static func _cancel_job_before(candidate: Dictionary, current: Dictionary) -> bool:
	return AreaOrders.cancel_before(candidate, current)

## Walls apply one build_line for the complete rectangle. The per-tile tools
## (previews_per_tile()) apply one area_order for a rectangle (ADR 044): the
## core expands it into the same per-tile commands, row-major, the first
## AreaOrders.TILES_PER_STEP now and the rest a budget per tick, so releasing
## a whole-map drag never blocks the frame. A tile list that is not a full
## rectangle still applies one command per tile, in the given order. A tile
## with no command to build (e.g. Cancel over a tile with no matching job) is
## silently skipped, same as a single click always has been -- it is not a
## rejection. Every tile whose command world.apply() rejects (for an area
## order: among the tiles expanded at release) is returned so the caller (and
## tests) can inspect the reason without depending on UI. Also records the
## rectangle's last tile as the inspected tile.
func commit_rectangle(world: WorldStateType, map_view: MapViewType, tiles: Array[Vector2i]) -> Array[Dictionary]:
	var rejected: Array[Dictionary] = []
	if selected_tool == Tool.WALL and not tiles.is_empty():
		var result: Dictionary = world.apply(wall_command(world, tiles))
		if not result.get("ok", false):
			for tile in tiles:
				rejected.append({"tile": tile, "reason": String(result["rejection"]["reason"])})
		else:
			for entry in result.get("skipped", []):
				rejected.append({"tile": Vector2i(entry["x"], entry["y"]), "reason": entry["reason"]})
	elif previews_per_tile(selected_tool) and _rectangle_of(tiles).has_area():
		var rect := _rectangle_of(tiles)
		_next_area_order += 1
		var result: Dictionary = world.apply({"actor": "player",
			"command_id": "viewer_area_%d_%d" % [world.get_tick(), _next_area_order], "tick": world.get_tick(),
			"type": "area_order", "payload": {"order": area_order_kind(selected_tool), "x": rect.position.x,
				"y": rect.position.y, "width": rect.size.x, "height": rect.size.y, "priority": 1}})
		if not result.get("ok", false):
			for tile in tiles:
				rejected.append({"tile": tile, "reason": String(result["rejection"]["reason"])})
		else:
			for entry in result.get("skipped", []):
				rejected.append({"tile": Vector2i(entry["x"], entry["y"]), "reason": entry["reason"]})
	else:
		var pending_by_tile = _pending_jobs_by_tile(world) if selected_tool == Tool.CANCEL else null
		for tile in tiles:
			var command := command_for_tile(world, map_view, selected_tool, tile, pending_by_tile)
			if command.is_empty():
				continue
			var result: Dictionary = world.apply(command)
			if not result.get("ok", false):
				rejected.append({"tile": tile, "reason": String(result["rejection"]["reason"])})
	if not tiles.is_empty():
		inspected_tile = tiles[tiles.size() - 1]
		has_inspected_tile = true
	return rejected

## The area_order "order" a per-tile tool expands to.
static func area_order_kind(tool: int) -> String:
	match tool:
		Tool.CANCEL: return "cancel"
		Tool.REMOVE_OBJECT: return "remove_object"
		_: return command_type_for_tool(tool)

## The job command type of a dig-like tool, "" for any other tool.
static func command_type_for_tool(tool: int) -> String:
	match tool:
		Tool.DIG: return "dig"
		Tool.CHOP: return "chop"
		Tool.FORAGE: return "forage"
		Tool.TILL: return "till"
		Tool.SOW: return "sow"
		Tool.MINE: return "mine"
		_: return ""

## The rectangle `tiles` lists exactly, row-major (MapView.tiles_in_rectangle()
## of its first and last tile), or an empty Rect2i when it is anything else.
static func _rectangle_of(tiles: Array[Vector2i]) -> Rect2i:
	if tiles.is_empty():
		return Rect2i()
	var first := tiles[0]
	var last := tiles[tiles.size() - 1]
	var rect := Rect2i(first, last - first + Vector2i.ONE)
	if not rect.has_area() or rect.get_area() != tiles.size() or tiles != MapViewType.tiles_in_rectangle(first, last):
		return Rect2i()
	return rect

## "" for a tool that isn't one of the build buttons, else the
## content/objects.json kind that tool builds.
static func build_kind_for_tool(tool: int) -> String:
	match tool:
		Tool.BUILD_DOOR: return "door"
		Tool.BUILD_BED: return "bed"
		Tool.BUILD_WORKBENCH: return "workbench"
		_: return ""

## The same complete batch is used for read-only preview and release submission.
func wall_command(world: WorldStateType, tiles: Array[Vector2i]) -> Dictionary:
	var payload_tiles: Array[Dictionary] = []
	for tile in tiles:
		payload_tiles.append({"x": tile.x, "y": tile.y})
	return {"actor": "player", "command_id": "viewer_wall_%d" % world.get_tick(),
		"tick": world.get_tick(), "type": "build_line",
		"payload": {"kind": wall_kind, "tiles": payload_tiles}}

func select_wall_kind(map_view: MapViewType, kind: String) -> void:
	wall_kind = kind
	for key in wall_kind_buttons:
		wall_kind_buttons[key].set_pressed_no_signal(key == kind)
	if map_view != null and selected_tool == Tool.WALL:
		map_view.set_build_kind(kind)
		map_view.refresh()

static func build_orientation(map_view: MapViewType) -> String:
	return map_view.get_build_orientation() if map_view != null else "horizontal"

func select_tool(world: WorldStateType, map_view: MapViewType, tool: int) -> void:
	selected_tool = tool
	for key in tool_buttons:
		tool_buttons[key].set_pressed_no_signal(key == tool)
	if map_view != null:
		map_view.set_tool_enabled(tool >= 0)
		map_view.set_preview_per_tile(previews_per_tile(tool))
		map_view.set_zone_tool_enabled(tool == Tool.ZONE)
		var build_kind := build_kind_for_tool(tool)
		map_view.set_build_tool_enabled(not build_kind.is_empty())
		if tool == Tool.WALL:
			map_view.set_build_kind(wall_kind)
		if not build_kind.is_empty():
			map_view.set_build_kind(build_kind)
			map_view.set_build_rotatable(build_kind_is_rotatable(world, build_kind))
		if rotate_build_button != null:
			var rotatable := build_kind_is_rotatable(world, build_kind)
			rotate_build_button.disabled = not rotatable
			rotate_build_button.set_pressed_no_signal(map_view.is_build_vertical() if rotatable else false)

func rotate_build(world: WorldStateType, map_view: MapViewType) -> void:
	if map_view == null or not build_kind_is_rotatable(world, build_kind_for_tool(selected_tool)):
		return
	map_view.toggle_build_orientation()
	rotate_build_button.set_pressed_no_signal(map_view.is_build_vertical())

static func build_kind_is_rotatable(world: WorldStateType, kind: String) -> bool:
	if world == null:
		return false
	for entry in world._content.list("objects"):
		if String(entry.get("kind", "")) == kind:
			return bool(entry.get("rotatable", false))
	return false
