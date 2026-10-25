extends SceneTree

## B4 before/after evidence: renders the art-mode MapView (not headless: it needs a real
## renderer) around a tree that gets chopped and five construction sites (wooden wall, door,
## bed, horizontal and vertical workbench) at half progress, then saves two crops:
## `chop.png` (the chopped tile and its neighbours) and `sites.png` (the progress bars).
## Lives outside game/ on purpose (not part of the suite); see docs/orca/handoffs/B4.md:
##   godot --path game --script <abs path to this file> -- <abs out dir>

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

const SEED := 424242
const ZOOM := 4.0
const TICK_BUDGET := 2000
const FRAME_WAIT_COUNT := 10

var _out_dir := ""
var _world: WorldStateType
var _map_view: MapViewType
var _shots: Array = []
var _frames := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out_dir = args[0] if args.size() == 1 else ""
	if _out_dir.is_empty() or not DirAccess.dir_exists_absolute(_out_dir):
		push_error("usage: B4-capture.gd -- <existing output dir>")
		quit(2)
		return
	root.size = Vector2i(640, 480)
	_world = WorldStateType.new(SEED)
	var colonist: Dictionary = _world.get_colonists()[0]
	var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
	_world.spawn_ground_tool_item("axe", origin.x, origin.y)
	var tree := _nearest(origin, "tree")
	_chop(tree)
	print("B4-capture: chopped (%d, %d) -> tile '%s'" % [tree.x, tree.y, _world.get_tile(tree.x, tree.y)])
	var sites_at := _place_sites(origin)
	_map_view = MapViewType.new()
	root.add_child(_map_view)
	_map_view.scale = Vector2.ONE * ZOOM
	_map_view.set_world(_world)
	_shots = [["chop.png", tree], ["sites.png", sites_at]]

func _process(_delta: float) -> bool:
	if _shots.is_empty():
		return false
	var focus: Vector2i = _shots[0][1]
	# Puts the focus tile at the window centre.
	_map_view.position = Vector2(root.size) / 2.0 - (Vector2(focus) + Vector2(0.5, 0.5)) * 16.0 * ZOOM
	_map_view.queue_redraw()
	_frames += 1
	if _frames < FRAME_WAIT_COUNT:
		return false
	_frames = 0
	var path := _out_dir.path_join(String(_shots[0][0]))
	var err := root.get_texture().get_image().save_png(path)
	print("B4-capture: wrote %s (%s)" % [path, error_string(err)])
	_shots.pop_front()
	if _shots.is_empty():
		quit(0)
	return false

## Runs a chop order to completion, keeping needs topped up so only the order runs.
func _chop(tree: Vector2i) -> void:
	_world.apply({"actor": "player", "command_id": "b4_chop", "tick": _world.get_tick(),
		"type": "chop", "payload": {"x": tree.x, "y": tree.y, "priority": 1}})
	var ticks := 0
	while ticks < TICK_BUDGET and _world.get_tile(tree.x, tree.y) == "tree":
		for colonist in _world._colonists:
			for kind in (colonist["needs"] as Dictionary).keys():
				colonist["needs"][kind] = 100
		_world.tick()
		ticks += 1

## One row of sites, 2 tiles apart, on the first soil run found right of `from`; each gets
## half its build_ticks of progress so the bar is visibly part-filled. Returns the row's
## middle tile.
func _place_sites(from: Vector2i) -> Vector2i:
	var specs := [["wooden_wall", ""], ["door", ""], ["bed", ""], ["workbench", "horizontal"], ["workbench", "vertical"]]
	var start := _nearest(from + Vector2i(0, 6), "soil", 12)
	var x := start.x
	var n := 0
	for spec in specs:
		var result: Dictionary = _world.apply({"actor": "player", "command_id": "b4_site_%d" % n,
			"tick": _world.get_tick(), "type": "build",
			"payload": {"kind": spec[0], "x": x, "y": start.y, "orientation": spec[1]}})
		if not bool(result.get("ok", false)):
			push_error("build %s at (%d, %d) rejected: %s" % [spec[0], x, start.y, result])
		x += 4 if spec[0] == "workbench" else 3
		n += 1
	for site in _world._sites.list():
		_world._sites.add_progress(String(site["id"]), int(site["build_ticks"]) / 2)
	return Vector2i(start.x + 7, start.y)

## Nearest tile of `kind` to `from` (Chebyshev rings); with `run` > 0, the nearest tile that
## starts a horizontal run of `run` object-free tiles of that kind.
func _nearest(from: Vector2i, kind: String, run: int = 0) -> Vector2i:
	for radius in range(0, 128):
		for y in range(from.y - radius, from.y + radius + 1):
			for x in range(from.x - radius, from.x + radius + 1):
				if maxi(absi(x - from.x), absi(y - from.y)) != radius:
					continue
				if _is_run(Vector2i(x, y), kind, maxi(run, 1)):
					return Vector2i(x, y)
	return from

func _is_run(at: Vector2i, kind: String, length: int) -> bool:
	for i in length:
		var x := at.x + i
		if at.y < 1 or at.y + 1 >= _world.get_map_height() or x < 0 or x >= _world.get_map_width():
			return false
		if _world.get_tile(x, at.y) != kind or _world.get_object(x, at.y) != "":
			return false
		# The vertical workbench needs the tile below its origin as well.
		if length > 1 and (_world.get_tile(x, at.y + 1) != kind or _world.get_object(x, at.y + 1) != ""):
			return false
	return true
