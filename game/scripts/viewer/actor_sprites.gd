extends Node2D

## Presentation-only sprites for the non-colonist actors (wolves, raiders,
## traders), drawn from the Pixel Crawler pack (B3, docs/art/style.md). Without
## the pack this node draws nothing, exactly as before B3: the placeholder art
## has no actor sprites (colonist_sprites.gd still draws their health bars).
##
## An actor snaps to its tile, grounded like the colonists (the measured
## feet row of each animation, world_pack.json), and shows "walk" on the tick
## its tile changed, "idle" otherwise; side sheets face right and are flipped
## after a step left. The frame comes from advance()'s own clock, which stands
## still while the TickDriver is paused, never from autoplay.

const TILE_SIZE := 16.0
const PackAssetsType = preload("res://scripts/viewer/pack_assets.gd")

## Art key for an actor: its content kind, except a wolf-def actor of the
## raiders faction (content/incidents.json raider_incursion), drawn as a raider.
static func art_key(actor: Dictionary) -> String:
	if String(actor.get("kind", "")) == "wolf" and String(actor.get("factionId", "")) == "raiders":
		return "raider"
	return String(actor.get("kind", ""))

var world
var _tick_driver
var _frames: Dictionary = {}
## art key -> animation -> feet row.
var _feet: Dictionary = {}
## actor id -> {sprite, key, tile, moved, flip_h, elapsed}
var _actors: Dictionary = {}

func _init(pack_root: String = PackAssetsType.DEFAULT_ROOT) -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_frames = PackAssetsType.actor_frames(pack_root)
	for key: String in _frames:
		_feet[key] = {}
		for animation in (_frames[key] as SpriteFrames).get_animation_names():
			_feet[key][animation] = PackAssetsType.actor_feet_y(key, animation)

func has_pack_art() -> bool:
	return not _frames.is_empty()

func set_tick_driver(driver) -> void:
	_tick_driver = driver

func set_visible_for_art(enabled: bool) -> void:
	visible = enabled

func set_world(world_ref) -> void:
	world = world_ref
	for state: Dictionary in _actors.values():
		(state["sprite"] as AnimatedSprite2D).queue_free()
	_actors.clear()
	refresh()

func _process(delta: float) -> void:
	advance(delta)

## Advances every sprite's animation clock by `delta` real seconds, unless the
## driver is paused (or absent), so the frame freezes like the colonists'.
func advance(delta: float) -> void:
	var running: bool = _tick_driver != null and _tick_driver.seconds_per_tick() > 0.0
	for state: Dictionary in _actors.values():
		if running:
			state["elapsed"] = float(state["elapsed"]) + delta
		_apply(state)

func refresh() -> void:
	if world == null or _frames.is_empty():
		return
	var colonist_ids := {}
	for colonist in world.get_colonists():
		colonist_ids[String(colonist["id"])] = true
	var seen := {}
	for actor in world.get_actors_with_health():
		var actor_id := String(actor["id"])
		var key := art_key(actor)
		if colonist_ids.has(actor_id) or not _frames.has(key):
			continue
		seen[actor_id] = true
		var tile := Vector2i(int(actor["x"]), int(actor["y"]))
		var state: Dictionary = _actors.get(actor_id, {})
		if state.is_empty():
			var sprite := AnimatedSprite2D.new()
			sprite.sprite_frames = _frames[key]
			sprite.centered = false
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			add_child(sprite)
			state = {"sprite": sprite, "key": key, "tile": tile, "moved": false, "flip_h": false, "elapsed": 0.0}
			_actors[actor_id] = state
		else:
			var step: Vector2i = tile - Vector2i(state["tile"])
			state["moved"] = step != Vector2i.ZERO
			if step.x != 0:
				state["flip_h"] = step.x < 0
			state["tile"] = tile
		_apply(state)
	for actor_id in _actors.keys():
		if not seen.has(actor_id):
			(_actors[actor_id]["sprite"] as AnimatedSprite2D).queue_free()
			_actors.erase(actor_id)

func _apply(state: Dictionary) -> void:
	var sprite: AnimatedSprite2D = state["sprite"]
	var animation := "walk" if bool(state["moved"]) else "idle"
	if sprite.animation != animation:
		sprite.animation = animation
	if sprite.is_playing():
		sprite.stop()
	var frames: SpriteFrames = sprite.sprite_frames
	var count := frames.get_frame_count(animation)
	sprite.frame = posmod(int(floor(float(state["elapsed"]) * frames.get_animation_speed(animation))), count)
	sprite.flip_h = bool(state["flip_h"])
	var frame_size := frames.get_frame_texture(animation, 0).get_size()
	var feet := float(_feet[state["key"]][animation])
	var tile := Vector2(state["tile"])
	sprite.position = tile * TILE_SIZE + Vector2(TILE_SIZE / 2.0 - frame_size.x / 2.0, TILE_SIZE - feet)

## The drawn sprite of an actor id (tests), or null.
func sprite_for(actor_id: String) -> AnimatedSprite2D:
	return _actors.get(actor_id, {}).get("sprite", null)
