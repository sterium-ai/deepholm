extends RefCounted

## One drawn sprite of a batched layer (A9): the fields an AnimatedSprite2D or a
## Sprite2D badge used to carry, as plain data, so colonist_sprites.gd and
## actor_sprites.gd draw every actor from one _draw() per layer instead of keeping
## four to six nodes each. Presentation only; the owning layer fills these in on
## refresh()/advance() and draw() paints them. The frame is always set explicitly
## (never autoplayed), so is_playing() is false.

## Body sprites: the frames, animation and frame drawn (texture comes from them).
var sprite_frames: SpriteFrames
var animation: StringName = &""
var frame: int = 0
## Badges: a texture region scaled to the badge box.
var texture: Texture2D
var region_rect := Rect2()
var scale := Vector2.ONE
var modulate := Color.WHITE
var position := Vector2.ZERO
var flip_h := false
var visible := true

func is_playing() -> bool:
	return false

## The texture this record paints: the current frame for a body, the badge texture otherwise.
func current_texture() -> Texture2D:
	if sprite_frames != null:
		return sprite_frames.get_frame_texture(animation, frame)
	return texture

## Paints this record on `canvas` (the layer's own _draw()), as the node it
## replaces did: top-left at `position`, uncentred, mirrored in place by flip_h.
func draw(canvas: CanvasItem) -> void:
	if not visible:
		return
	var tex := current_texture()
	if tex == null:
		return
	var source := region_rect if sprite_frames == null else Rect2(Vector2.ZERO, tex.get_size())
	var size := source.size * scale
	if flip_h:
		canvas.draw_set_transform(position + Vector2(size.x, 0.0), 0.0, Vector2(-1.0, 1.0))
		canvas.draw_texture_rect_region(tex, Rect2(Vector2.ZERO, size), source, modulate)
		canvas.draw_set_transform(Vector2.ZERO)
	else:
		canvas.draw_texture_rect_region(tex, Rect2(position, size), source, modulate)
