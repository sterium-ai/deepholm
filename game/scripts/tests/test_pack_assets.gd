extends SceneTree

## pack_assets.gd and colonist_sprites.gd's pack/placeholder switch
## (docs/art/style.md, "Pack art and placeholders"). The real pack is never in
## the repository, so the pack path is driven by fixture sheets written to
## user:// with exactly the sizes colonist_pack.json measured; the fallback
## path by a root that does not exist. Neither depends on whether the real
## pack happens to be synced on this machine.
##
## godot --headless --path game --script res://scripts/tests/test_pack_assets.gd

const PackAssetsType = preload("res://scripts/viewer/pack_assets.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")

const MISSING_ROOT := "user://no_pack_here/"
const FIXTURE_ROOT := "user://pack_fixture/"
const FACINGS := ["down", "up", "side"]
const BASE_PREFIXES := ["idle", "walk", "carry_idle", "carry_walk"]
const WORK_PREFIXES := ["chop", "mine", "dig", "build"]

## Minimal stand-in for the getters colonist_sprites.gd reads, so a colonist
## can be put "in a work toil" of a given job kind without a simulation.
class FakeWorld:
	extends RefCounted
	var colonists: Array = []
	var jobs: Array = []
	func get_colonists() -> Array: return colonists
	func get_jobs() -> Array: return jobs
	# WorldState.get_job() (B1): colonist_sprites.gd reads the one job it needs.
	func get_job(job_id: String) -> Dictionary:
		for job in jobs:
			if String(job["id"]) == job_id:
				return job
		return {}
	func get_move_ticks_per_tile() -> int: return 4
	func get_tool_item(_id: String) -> Dictionary: return {}
	func get_actors_with_health() -> Array: return []

class FakeDriver:
	extends RefCounted
	func seconds_per_tick() -> float: return 0.5

var _failed := false

func _init() -> void:
	var mapping := PackAssetsType.read_mapping(PackAssetsType.COLONIST_FRAMES_JSON)
	_check_mapping(mapping)
	_check_missing_pack_falls_back()
	_write_fixture(mapping, FIXTURE_ROOT)
	_check_fixture_pack(mapping)
	_check_partial_pack_falls_back(mapping)
	_check_wrong_size_sheet_falls_back(mapping)
	_check_work_animations()
	_remove_dir(FIXTURE_ROOT)
	_remove_dir("user://pack_partial/")
	_remove_dir("user://pack_wrong_size/")
	if _failed:
		quit(1)
		return
	print("test_pack_assets: PASS")
	quit()

func _fail(message: String) -> void:
	push_error("test_pack_assets: FAIL: " + message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## The committed mapping covers every animation the renderer asks for, every
## sheet is in the sync manifest, and the measured grounding matches the
## renderer's constants.
func _check_mapping(mapping: Dictionary) -> void:
	var animations: Dictionary = mapping.get("animations", {})
	_expect(animations.size() == FACINGS.size() * (BASE_PREFIXES.size() + WORK_PREFIXES.size()),
		"colonist_pack.json must have 24 animations, has %d" % animations.size())
	var manifest := PackAssetsType.read_mapping("res://data/sprite_frames/pack_manifest.json")
	var listed: Array = manifest.get("files", [])
	for prefix: String in BASE_PREFIXES + WORK_PREFIXES:
		for facing: String in FACINGS:
			var name := "%s_%s" % [prefix, facing]
			_expect(animations.has(name), "colonist_pack.json missing " + name)
			if not animations.has(name):
				continue
			var entry: Dictionary = animations[name]
			_expect(listed.has(entry["sheet"]), name + ": sheet not in pack_manifest.json")
			var size: Array = entry["sheet_size"]
			_expect(int(size[1]) == int(ColonistSpritesType.FRAME_SOURCE_SIZE), name + ": frame height")
			_expect(int(entry["frames"]) * int(size[1]) == int(size[0]), name + ": frames * height == width")
			var boxes: Array = entry["alpha_bboxes"]
			_expect(boxes.size() == int(entry["frames"]), name + ": one alpha bbox per frame")
			for box: Array in boxes:
				_expect(int(box[3]) <= int(ColonistSpritesType.FRAME_FEET_Y) + 1 or prefix in WORK_PREFIXES,
					name + ": a walk/idle frame reaches below the feet row")
	for walk_or_idle: String in BASE_PREFIXES:
		_expect(int(animations.get(walk_or_idle + "_down", {}).get("frames", 0)) == (6 if walk_or_idle.contains("walk") else 4),
			walk_or_idle + ": frame count matches the placeholder's (timing unchanged)")
	_expect(float(mapping.get("feet_y", -1)) == ColonistSpritesType.FRAME_FEET_Y, "feet_y == FRAME_FEET_Y")

func _check_missing_pack_falls_back() -> void:
	_expect(PackAssetsType.load_texture("Entities/x.png", MISSING_ROOT) == null, "missing sheet loads as null")
	_expect(PackAssetsType.colonist_frames(64.0, 47.0, MISSING_ROOT) == null, "no pack -> no pack frames")
	var sprites := ColonistSpritesType.new(MISSING_ROOT)
	_expect(sprites._frames == ColonistSpritesType.FRAMES, "no pack -> placeholder FRAMES")
	_expect(not sprites._loop_work, "no pack -> placeholder timing")
	sprites.free()

func _check_fixture_pack(mapping: Dictionary) -> void:
	var frames := PackAssetsType.colonist_frames(64.0, 47.0, FIXTURE_ROOT)
	_expect(frames != null, "a complete pack builds SpriteFrames")
	if frames == null:
		return
	_expect(frames.get_animation_names().size() == mapping["animations"].size(), "one animation per mapping entry")
	_expect(frames.get_frame_count("chop_side") == 8, "chop_side has the Slice strip's 8 frames")
	var atlas := frames.get_frame_texture("walk_down", 2) as AtlasTexture
	_expect(atlas != null and atlas.region == Rect2(128, 0, 64, 64), "frame 2 is the third 64x64 cell")
	_expect(PackAssetsType.colonist_frames(64.0, 40.0, FIXTURE_ROOT) == null,
		"a feet row other than the renderer's keeps the placeholder")
	var sprites := ColonistSpritesType.new(FIXTURE_ROOT)
	_expect(sprites._frames != ColonistSpritesType.FRAMES and sprites._loop_work, "pack present -> pack frames")
	sprites.free()

## One missing sheet means no pack art at all, never a mix.
func _check_partial_pack_falls_back(mapping: Dictionary) -> void:
	var root := "user://pack_partial/"
	_write_fixture(mapping, root)
	var first_sheet: String = mapping["animations"]["idle_down"]["sheet"]
	DirAccess.remove_absolute(root + first_sheet)
	_expect(PackAssetsType.colonist_frames(64.0, 47.0, root) == null, "a partial pack keeps the placeholder")

## A sheet whose size differs from the measured one (another pack version)
## also means no pack art at all: every sheet present, one a frame short.
func _check_wrong_size_sheet_falls_back(mapping: Dictionary) -> void:
	var root := "user://pack_wrong_size/"
	_write_fixture(mapping, root)
	var entry: Dictionary = mapping["animations"]["walk_side"]
	var short := Image.create(int(entry["sheet_size"][0]) - int(entry["sheet_size"][1]),
		int(entry["sheet_size"][1]), false, Image.FORMAT_RGBA8)
	_expect(short.save_png(root + String(entry["sheet"])) == OK, "wrong-size fixture sheet written")
	_expect(PackAssetsType.load_texture(String(entry["sheet"]), root) != null, "the wrong-size sheet itself loads")
	_expect(PackAssetsType.colonist_frames(64.0, 47.0, root) == null, "a wrong-size sheet keeps the placeholder")
	var sprites := ColonistSpritesType.new(root)
	_expect(sprites._frames == ColonistSpritesType.FRAMES, "wrong-size sheet -> placeholder FRAMES")
	sprites.free()

## Through the real refresh()/advance() path: a colonist in a chop/mine/dig
## work toil shows that work animation with the pack and loops it; with the
## placeholder, chop shows idle and site_work build_*, exactly as before.
func _check_work_animations() -> void:
	for case in [
		{"root": FIXTURE_ROOT, "kind": "chop", "expected": "chop_down"},
		{"root": FIXTURE_ROOT, "kind": "mine", "expected": "mine_down"},
		{"root": FIXTURE_ROOT, "kind": "dig", "expected": "dig_down"},
		{"root": FIXTURE_ROOT, "kind": "site_work", "expected": "build_down"},
		{"root": FIXTURE_ROOT, "kind": "haul", "expected": "idle_down"},
		{"root": MISSING_ROOT, "kind": "chop", "expected": "idle_down"},
		{"root": MISSING_ROOT, "kind": "site_work", "expected": "build_down"},
	]:
		var world := FakeWorld.new()
		world.jobs = [{"id": "job_1", "kind": case["kind"]}]
		world.colonists = [{"id": "colonist_0", "x": 2, "y": 2, "carrying": null,
			"work": {"job_id": "job_1", "ticks_remaining": 10}}]
		var sprites := ColonistSpritesType.new(case["root"])
		sprites.set_tick_driver(FakeDriver.new())
		sprites.set_world(world)
		var sprite: AnimatedSprite2D = sprites._sprites["colonist_0"]
		var label := "%s with %s" % [case["kind"], "pack" if case["root"] == FIXTURE_ROOT else "placeholder"]
		_expect(sprite.animation == case["expected"],
			"%s: animation %s, expected %s" % [label, sprite.animation, case["expected"]])
		# 1.5 tile-crossings (2.0 s each at 0.5 s/tick * 4 ticks/tile) into the toil.
		sprites.advance(3.0)
		var count := sprite.sprite_frames.get_frame_count(sprite.animation)
		var looping: bool = case["root"] == FIXTURE_ROOT and case["kind"] != "haul"
		var expected_frame := (count / 2) if looping else count - 1
		_expect(sprite.frame == expected_frame,
			"%s: frame %d after 1.5 crossings, expected %d" % [label, sprite.frame, expected_frame])
		sprites.free()

func _write_fixture(mapping: Dictionary, root: String) -> void:
	for animation_name: String in mapping["animations"]:
		var entry: Dictionary = mapping["animations"][animation_name]
		var path: String = root + String(entry["sheet"])
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var image := Image.create(int(entry["sheet_size"][0]), int(entry["sheet_size"][1]), false, Image.FORMAT_RGBA8)
		image.fill_rect(Rect2i(24, 18, 16, 30), Color.BURLYWOOD)
		_expect(image.save_png(path) == OK, "fixture sheet written: " + path)

func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_dir(path.path_join(sub))
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
