extends SceneTree

## Resource-only contract for colonist_frames.tres; no scene or simulation is
## loaded. Every animation is a horizontal strip of 64x64 AtlasTexture frames
## cut from its own generated sheet under res://assets/generated/colonist/.
const ROOT := "res://assets/generated/colonist/"
const BASE_ANIMATIONS := [
	"walk_down", "walk_up", "walk_side",
	"idle_down", "idle_up", "idle_side",
	"carry_walk_down", "carry_walk_up", "carry_walk_side",
	"carry_idle_down", "carry_idle_up", "carry_idle_side",
]
## The build work-toil's own animation, one per facing.
const BUILD_FACINGS := ["down", "up", "side"]
const BUILD_FRAME_COUNT := 8
const BUILD_SPEED := 6.0

var _failed := false

func _init() -> void:
	var frames := load("res://data/sprite_frames/colonist_frames.tres") as SpriteFrames
	if frames == null:
		_expect(false, "cannot load SpriteFrames")
	else:
		for animation: String in BASE_ANIMATIONS:
			var walking := animation.contains("walk")
			_check_strip(frames, animation, 6 if walking else 4, 3.0 if walking else 2.0)
		for facing in BUILD_FACINGS:
			_check_strip(frames, "build_%s" % facing, BUILD_FRAME_COUNT, BUILD_SPEED)
		var expected_count := BASE_ANIMATIONS.size() + BUILD_FACINGS.size()
		_expect(frames.get_animation_names().size() == expected_count,
			"exactly %d animations (12 base + 3 build_* facings)" % expected_count)
	if _failed:
		quit(1)
	else:
		print("test_colonist_frames_resource: PASS")
		quit(0)

func _check_strip(frames: SpriteFrames, animation: String, count: int, fps: float) -> void:
	_expect(frames.has_animation(animation), "missing " + animation)
	if not frames.has_animation(animation):
		return
	_expect(frames.get_frame_count(animation) == count, animation + " frame count")
	_expect(frames.get_animation_loop(animation), animation + " must loop")
	_expect(is_equal_approx(frames.get_animation_speed(animation), fps), animation + " fps")
	for index in range(frames.get_frame_count(animation)):
		var label := "%s frame %d" % [animation, index]
		_expect(frames.get_frame_duration(animation, index) == 1.0, label + " duration")
		var texture := frames.get_frame_texture(animation, index) as AtlasTexture
		_expect(texture != null, label + " must be AtlasTexture")
		if texture == null:
			continue
		_expect(texture.region == Rect2(index * 64, 0, 64, 64), label + " region/order")
		_expect(texture.margin == Rect2(), label + " must not add margins")
		_expect(texture.atlas != null, label + " missing sheet")
		if texture.atlas == null:
			continue
		_expect(texture.atlas.resource_path == ROOT + animation + ".png", label + " matching sheet")
		_expect(texture.atlas.get_size() == Vector2(count * 64, 64), label + " sheet dimensions")
		_expect(not texture.atlas.get_image().has_mipmaps(), label + " mipmaps disabled")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("test_colonist_frames_resource: FAIL: " + message)
