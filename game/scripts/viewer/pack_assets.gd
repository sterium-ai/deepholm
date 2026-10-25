extends RefCounted

## Presentation-only loader for the Pixel Crawler pack sheets (docs/art/style.md,
## "Pack art and placeholders"). The pack may not be redistributed, so its PNGs
## live only in the git-ignored DEFAULT_ROOT, copied there by
## tools/sync_pack_assets.ps1. Every function returns null when a sheet is
## missing, and callers then keep the generated placeholder: CI, tests and a
## clone without the pack run exactly as if this file did not exist.
##
## A *_pack.json under data/sprite_frames/ maps viewer animation names to
## sheets; its numbers are measured from the real sheets
## (docs/orca/handoffs/B2-measure_pack_frames.py), never typed by hand.

const DEFAULT_ROOT := "res://assets/pack/"
const COLONIST_FRAMES_JSON := "res://data/sprite_frames/colonist_pack.json"

## The sheet's texture, or null if `root` does not hold it. An imported
## texture (after `godot --import`, and in an exported build) is preferred; a
## raw PNG copied in after the last import is read directly so a fresh sync
## works without a re-import.
static func load_texture(relative_path: String, root: String = DEFAULT_ROOT) -> Texture2D:
	var path := root + relative_path
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	if not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)

## The parsed mapping at `json_path`, or {} if it is absent or not an object.
static func read_mapping(json_path: String) -> Dictionary:
	if not FileAccess.file_exists(json_path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	return parsed if parsed is Dictionary else {}

## SpriteFrames for every animation in `mapping` (a *_pack.json), each a
## looping horizontal strip of square frames, or null unless ALL sheets are
## present at `root` with the measured size -- never a mix of pack and
## placeholder art, and never a pack version whose layout the JSON does not
## describe.
static func build_sprite_frames(mapping: Dictionary, root: String = DEFAULT_ROOT) -> SpriteFrames:
	var animations: Dictionary = mapping.get("animations", {})
	if animations.is_empty():
		return null
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	for animation_name: String in animations:
		var entry: Dictionary = animations[animation_name]
		var sheet := load_texture(String(entry.get("sheet", "")), root)
		var sheet_size: Array = entry.get("sheet_size", [])
		if sheet == null or sheet_size.size() != 2 \
				or sheet.get_size() != Vector2(float(sheet_size[0]), float(sheet_size[1])):
			return null
		var count := int(entry.get("frames", 0))
		var frame_size := float(sheet_size[1])
		if count <= 0 or count * frame_size != float(sheet_size[0]):
			return null
		frames.add_animation(animation_name)
		frames.set_animation_loop(animation_name, true)
		frames.set_animation_speed(animation_name, float(entry.get("fps", 1.0)))
		for index in count:
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(index * frame_size, 0, frame_size, frame_size)
			frames.add_frame(animation_name, atlas)
	return frames

## The colonist SpriteFrames from the pack, or null to keep the placeholder.
## Also null when the measured frame size or feet row differs from the
## renderer's grounding constants (`frame_size`, `feet_y`), so a pack update
## can never silently float or sink the colonists.
static func colonist_frames(frame_size: float, feet_y: float, root: String = DEFAULT_ROOT) -> SpriteFrames:
	var mapping := read_mapping(COLONIST_FRAMES_JSON)
	var measured: Array = mapping.get("frame_size", [])
	if measured.size() != 2 or float(measured[0]) != frame_size or float(measured[1]) != frame_size \
			or float(mapping.get("feet_y", -1)) != feet_y:
		return null
	return build_sprite_frames(mapping, root)
