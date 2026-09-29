extends SceneTree

## Builds game/data/sprite_frames/colonist_frames.tres from the generated
## colonist sheets in game/assets/generated/colonist/ (64x64 frames laid out
## horizontally; see tools/generate_placeholder_art.py).
##
## Run: godot --headless --path game --script res://scripts/tools/build_colonist_frames.gd

const SHEET_DIR := "res://assets/generated/colonist/"
const FRAME := 64
const FACINGS := ["down", "up", "side"]

func _add(frames: SpriteFrames, animation: String, count: int, fps: float) -> void:
	var sheet: Texture2D = load(SHEET_DIR + animation + ".png")
	frames.add_animation(animation)
	frames.set_animation_loop(animation, true)
	frames.set_animation_speed(animation, fps)
	for index in count:
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(index * FRAME, 0, FRAME, FRAME)
		frames.add_frame(animation, atlas)

func _init() -> void:
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	for facing in FACINGS:
		for prefix in ["", "carry_"]:
			_add(frames, "%swalk_%s" % [prefix, facing], 6, 3.0)
			_add(frames, "%sidle_%s" % [prefix, facing], 4, 2.0)
		_add(frames, "build_%s" % facing, 8, 6.0)
	var out_path := "res://data/sprite_frames/colonist_frames.tres"
	var err := ResourceSaver.save(frames, out_path)
	print("saved ", out_path, " err=", err, " animations=", frames.get_animation_names().size())
	quit(0 if err == OK else 1)
