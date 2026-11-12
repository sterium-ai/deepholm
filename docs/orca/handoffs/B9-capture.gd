extends SceneTree

## B9 evidence: renders the real art-mode MapView (not headless, it needs a renderer)
## over a real WorldState that is ticked, so every shot shows the core's own stance and
## the viewer's own facing / tool-tip offset. One PNG per case, written to <out_dir>:
##   b9_dig_east.png, b9_dig_north.png, b9_dig_west.png, b9_dig_south.png - a digger with
##     a shovel mid-swing beside its target, tool tip on the target tile;
##   b9_mine_west.png - a miner with a pick mid-swing at a rock face;
##   b9_plant.png - a farmer planting a sapling in a forest zone (Collect strip stand-in);
##   b9_trench.png - the same dig after it completed: the darker trench tile.
## Mid-swing shots hold the strip's impact frame (the one the tool tips were measured on).
## Each case is a 7x5 soil pocket walled by rock with one colonist in the middle, so no
## other job or colonist reaches in. Like B7-capture.gd it writes WorldState internals
## to build the pocket (capture only). Lives outside game/ on purpose:
##   godot --path game --script <abs path to this file> -- <abs out_dir> [pack_root]
## pack_root defaults to res://assets/pack/; pass user://none/ for the placeholder look.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

const SEED := 424242
const ZOOM := 6.0
const SIZE := Vector2i(7, 5)
const CENTRE := Vector2i(3, 2)
const FRAME_WAIT_COUNT := 8
const MAX_TICKS := 400
const IMPACT_FRAME := 3

## name, job type, target step from the colonist, tool, shoot when ("work" = mid-swing,
## "done" = after the job completed).
const CASES := [
	["b9_dig_east", "dig", Vector2i(1, 0), "shovel", "work"],
	["b9_dig_north", "dig", Vector2i(0, -1), "shovel", "work"],
	["b9_dig_west", "dig", Vector2i(-1, 0), "shovel", "work"],
	["b9_dig_south", "dig", Vector2i(0, 1), "shovel", "work"],
	["b9_mine_west", "mine", Vector2i(-1, 0), "pick", "work"],
	["b9_plant", "plant", Vector2i(1, 0), "", "work"],
	["b9_trench", "dig", Vector2i(1, 0), "shovel", "done"],
]

var _out_dir := ""
var _pack_root := ""
var _viewport: SubViewport
var _map_view: MapViewType
var _world: WorldStateType
var _top_left := Vector2i.ZERO
var _case := -1
var _ticks := 0
var _frames := 0
var _shooting := false
var _failed := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out_dir = args[0] if args.size() >= 1 else ""
	_pack_root = args[1] if args.size() >= 2 else "res://assets/pack/"
	if _out_dir.is_empty():
		push_error("usage: B9-capture.gd -- <abs out_dir> [pack_root]")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE * 16 * int(ZOOM))
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_next_case()

func _process(_delta: float) -> bool:
	if _case >= CASES.size():
		return false
	if _shooting:
		_frames += 1
		if _frames >= FRAME_WAIT_COUNT:
			_save()
			_next_case()
		return false
	var case: Array = CASES[_case]
	_world.tick()
	_ticks += 1
	_map_view.refresh()
	if _ready_to_shoot(String(case[4])):
		_shooting = true
		_frames = 0
		if case[4] == "work":
			_hold_impact_frame()
	elif _ticks > MAX_TICKS:
		push_error("B9-capture: %s never reached '%s'" % [case[0], case[4]])
		_failed = true
		_next_case()
	return false

func _ready_to_shoot(when: String) -> bool:
	var colonist: Dictionary = _world._colonists[0]
	var work = colonist.get("work")
	if when == "work":
		# Mid-swing: past half the work so the pose is settled.
		return work != null and int(work.get("ticks_remaining", 0)) <= int(work.get("ticks_total", 30)) / 2
	for job in _world.get_jobs():
		if String(job.get("status", "")) == "completed":
			return true
	return false

## Freezes the worker on its strip's impact frame (IMPACT_FRAME, the frame
## colonist_pack.json's tool_tip was measured on) so the shot shows the tip landing.
func _hold_impact_frame() -> void:
	var sprites: Node2D = _map_view._colonist_sprites
	sprites.set_process(false)
	var body = sprites._sprites.get(String(_world._colonists[0]["id"]))
	if body != null:
		body.frame = IMPACT_FRAME

func _save() -> void:
	var path := _out_dir.path_join("%s.png" % CASES[_case][0])
	var err := _viewport.get_texture().get_image().save_png(path)
	var colonist: Dictionary = _world._colonists[0]
	print("B9-capture: wrote %s (%s) colonist at %s after %d ticks" % [path, error_string(err),
		Vector2i(int(colonist["x"]), int(colonist["y"])) - _top_left, _ticks])
	if err != OK:
		_failed = true

func _next_case() -> void:
	if _map_view != null:
		_map_view.queue_free()
		_map_view = null
	_case += 1
	_shooting = false
	_ticks = 0
	if _case >= CASES.size():
		quit(1 if _failed else 0)
		return
	_build(CASES[_case])

func _paint_tile(at: Vector2i, kind: String) -> void:
	_world._tile_grid.tiles[_world._tile_grid.tile_index(at.x, at.y)] = kind

func _build(case: Array) -> void:
	_world = WorldStateType.new(SEED)
	var start: Dictionary = _world.get_colonists()[0]
	_top_left = Vector2i(clampi(int(start["x"]) - CENTRE.x, 1, _world.get_map_width() - SIZE.x - 1),
		clampi(int(start["y"]) + 4, 1, _world.get_map_height() - SIZE.y - 1))
	# Rock all round the pocket so nothing outside can reach in or be reached.
	for y in range(-1, SIZE.y + 1):
		for x in range(-1, SIZE.x + 1):
			var inside := x >= 0 and y >= 0 and x < SIZE.x and y < SIZE.y
			_paint_tile(_top_left + Vector2i(x, y), WorldStateType.TILE_SOIL if inside else WorldStateType.TILE_ROCK)
	var at := _top_left + CENTRE
	var target := at + Vector2i(case[2])
	if case[1] == "mine":
		_paint_tile(target, WorldStateType.TILE_ROCK)
	_world._colonists.resize(1)
	_world._colonists[0]["x"] = at.x
	_world._colonists[0]["y"] = at.y
	_world._colonists[0]["route"] = null
	_world._colonists[0]["work"] = null
	if not String(case[3]).is_empty():
		_world.spawn_ground_tool_item(String(case[3]), at.x, at.y)
	var command := {"actor": "player", "command_id": "b9_%s" % case[0], "tick": _world.get_tick()}
	if case[1] == "plant":
		# A one-tile forest zone: the farmer plants a sapling on it.
		command.merge({"type": "zone_add", "payload": {"x": target.x, "y": target.y, "z": 0,
			"width": 1, "height": 1, "kind": "forest"}})
	else:
		command.merge({"type": case[1], "payload": {"x": target.x, "y": target.y, "z": 0, "priority": 1}})
	var result: Dictionary = _world.apply(command)
	if not bool(result.get("ok", false)):
		push_error("B9-capture: %s rejected: %s" % [case[0], result])
		_failed = true
	_map_view = MapViewType.new(_pack_root)
	_viewport.add_child(_map_view)
	_map_view.scale = Vector2.ONE * ZOOM
	_map_view.position = -Vector2(_top_left) * 16.0 * ZOOM
	_map_view.set_world(_world)
	_map_view.refresh()
