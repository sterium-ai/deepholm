extends SceneTree

## Evidence for B2: renders colonist_sprites.gd (the real viewer renderer) for
## every facing and state on a flat grass-coloured background and saves a PNG.
## Needs a window (the headless renderer draws nothing). Run from the repo root:
##
##   & $env:GODOT --path game --script ../docs/orca/handoffs/B2-capture.gd -- <out.png> [pack_root]
##
## pack_root defaults to res://assets/pack/ (the synced pack); pass a missing
## directory (e.g. user://none/) to capture the placeholder fallback instead.

const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const ZOOM := 4
const COLUMNS := 5
const GRASS := Color("5d9440")

class FakeWorld:
	extends RefCounted
	var colonists: Array = []
	var jobs: Array = []
	func get_colonists() -> Array: return colonists
	func get_jobs() -> Array: return jobs
	func get_move_ticks_per_tile() -> int: return 4
	func get_tool_item(_id: String) -> Dictionary: return {}
	func get_actors_with_health() -> Array: return []

class FakeDriver:
	extends RefCounted
	func seconds_per_tick() -> float: return 0.5

## label, step (dx, dy) taken before the shot, carrying?, job kind in work.
const CASES := [
	["idle down", Vector2i(0, 0), false, ""],
	["walk down", Vector2i(0, 1), false, ""],
	["walk up", Vector2i(0, -1), false, ""],
	["walk right", Vector2i(1, 0), false, ""],
	["walk left", Vector2i(-1, 0), false, ""],
	["carry walk down", Vector2i(0, 1), true, ""],
	["carry walk up", Vector2i(0, -1), true, ""],
	["carry walk right", Vector2i(1, 0), true, ""],
	["carry walk left", Vector2i(-1, 0), true, ""],
	["chop right", Vector2i(1, 0), false, "chop"],
	["chop down", Vector2i(0, 1), false, "chop"],
	["mine left", Vector2i(-1, 0), false, "mine"],
	["dig up", Vector2i(0, -1), false, "dig"],
	["build down", Vector2i(0, 1), false, "site_work"],
	["build right", Vector2i(1, 0), false, "site_work"],
]

var _viewport: SubViewport

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "user://b2_capture.png"
	var pack_root: String = args[1] if args.size() > 1 else "res://assets/pack/"
	var rows := int(ceil(float(CASES.size()) / COLUMNS))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i((COLUMNS * 4 + 1) * 16, (rows * 5 + 1) * 16) * ZOOM
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	root.add_child(_viewport)
	var background := ColorRect.new()
	background.color = GRASS
	background.size = _viewport.size
	_viewport.add_child(background)
	var holder := Node2D.new()
	holder.scale = Vector2(ZOOM, ZOOM)
	_viewport.add_child(holder)
	var world := FakeWorld.new()
	var sprites := ColonistSpritesType.new(pack_root)
	sprites.set_tick_driver(FakeDriver.new())
	holder.add_child(sprites)
	for index in CASES.size():
		var tile := Vector2i(2 + (index % COLUMNS) * 4, 3 + (index / COLUMNS) * 5)
		world.colonists.append({"id": "c%d" % index, "x": tile.x, "y": tile.y,
			"carrying": null, "work": null})
		var label := Label.new()
		label.text = CASES[index][0]
		# Under where the sprite is drawn: half a step past its start tile.
		var drawn := Vector2(tile) + Vector2(CASES[index][1]) * 0.5
		label.position = Vector2((drawn.x - 1.0) * 16, (drawn.y + 1.0) * 16 + 2) * ZOOM
		label.add_theme_font_size_override("font_size", 12)
		_viewport.add_child(label)
	sprites.set_world(world)
	for index in CASES.size():
		var case: Array = CASES[index]
		var colonist: Dictionary = world.colonists[index]
		colonist["x"] += case[1].x
		colonist["y"] += case[1].y
		if case[2]:
			colonist["carrying"] = {"kind": "wood"}
		if not String(case[3]).is_empty():
			world.jobs.append({"id": "job_%d" % index, "kind": case[3]})
			colonist["work"] = {"job_id": "job_%d" % index, "ticks_remaining": 10}
	sprites.refresh()
	# Half a tile-crossing: walkers mid-stride, half a tile from where they
	# started; workers (whose step only set their facing) mid-swing.
	sprites.advance(1.0)
	sprites.set_process(false)
	_save.call_deferred(out_path)

func _save(out_path: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	var err := image.save_png(out_path)
	print("B2-capture: saved %s (%dx%d) err=%d" % [out_path, image.get_width(), image.get_height(), err])
	quit(0 if err == OK else 1)
