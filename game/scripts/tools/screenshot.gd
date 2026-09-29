extends SceneTree

## Captures the debug viewer at native resolution and two nearest-neighbour
## scales. This is intentionally a presentation-only tool: it observes the
## already-rendered boot scene and never reaches into WorldState.

const BOOT_SCENE_PATH := "res://scenes/boot.tscn"
const FRAME_WAIT_COUNT := 30

var _output_dir := ""
var _frames_waited := 0
var _startup_error := ""

func _initialize() -> void:
	var boot_scene := load(BOOT_SCENE_PATH) as PackedScene
	if boot_scene == null:
		_startup_error = "could not load %s" % BOOT_SCENE_PATH
		return
	root.add_child(boot_scene.instantiate())

	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0].strip_edges() == "":
		_startup_error = "usage: screenshot.gd <output_dir>"
		return

	_output_dir = args[0].strip_edges()
	if not DirAccess.dir_exists_absolute(_output_dir):
		_startup_error = "output directory does not exist: %s" % _output_dir
		return

func _process(_delta: float) -> bool:
	if _startup_error != "":
		_fail(_startup_error)
		return false

	_frames_waited += 1
	if _frames_waited < FRAME_WAIT_COUNT:
		return false

	_capture()
	return false

func _capture() -> void:
	var viewport_image := root.get_texture().get_image()
	if viewport_image == null or viewport_image.is_empty():
		_fail("viewport capture returned no image")
		return

	if not _save_png(viewport_image, "shot-1x.png"):
		return

	for scale in [2, 3]:
		var scaled_image := viewport_image.duplicate()
		scaled_image.resize(viewport_image.get_width() * scale, viewport_image.get_height() * scale, Image.INTERPOLATE_NEAREST)
		if not _save_png(scaled_image, "shot-%dx.png" % scale):
			return

	quit(0)

func _save_png(image: Image, filename: String) -> bool:
	var path := _output_dir.path_join(filename)
	var error := image.save_png(path)
	if error != OK:
		_fail("could not save %s: %s" % [path, error_string(error)])
		return false
	return true

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
