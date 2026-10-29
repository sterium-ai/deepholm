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
##
## A9: no node per actor. Each actor is a SpriteRecord (sprite_record.gd) and
## this node's one _draw() paints them all; refresh() reads the
## WorldState.get_view_snapshot() it is given.

const TILE_SIZE := 16.0
const PackAssetsType = preload("res://scripts/viewer/pack_assets.gd")
const SpriteRecordType = preload("res://scripts/viewer/sprite_record.gd")

## Art key for an actor: its content kind, except a wolf-def actor of the
## raiders faction (content/incidents.json raider_incursion), drawn as a raider.
static func art_key(actor: Dictionary) -> String:
	return art_key_of(String(actor.get("kind", "")), String(actor.get("factionId", "")))

## art_key() from the snapshot's kinds and factions columns.
static func art_key_of(kind: String, faction_id: String) -> String:
	if kind == "wolf" and faction_id == "raiders":
		return "raider"
	return kind

var world
var _tick_driver
var _frames: Dictionary = {}
## art key -> animation -> feet row.
var _feet: Dictionary = {}
## actor id -> {sprite: SpriteRecord, key, tile, moved, flip_h, elapsed}
var _actors: Dictionary = {}

## `frames` is pack_assets.gd's actor_frames() (map_view.gd passes the one
## from world_pack(), so actors and terrain switch to the pack together), or
## {} to draw nothing.
func _init(frames: Dictionary = {}) -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_frames = frames
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
	if running and not _actors.is_empty():
		queue_redraw()

## `snapshot` is this tick's WorldState.get_view_snapshot(); {} takes a fresh one.
func refresh(snapshot: Dictionary = {}) -> void:
	if world == null or _frames.is_empty():
		return
	if snapshot.is_empty():
		snapshot = world.get_view_snapshot()
	var ids: Array = snapshot["ids"]
	var worker: Array = snapshot["worker"]
	var hp: Array = snapshot["hp"]
	var kinds: Array = snapshot["kinds"]
	var factions: Array = snapshot["factions"]
	var xs: Array = snapshot["x"]
	var ys: Array = snapshot["y"]
	var seen := {}
	# The actors with a health component that are not colonists (colonist_sprites.gd draws those).
	for row in (ids.size() if worker.has(0) else 0):
		if worker[row] == 1 or hp[row] < 0:
			continue
		var actor_id: String = ids[row]
		var key := art_key_of(kinds[row], factions[row])
		if not _frames.has(key):
			continue
		seen[actor_id] = true
		var tile := Vector2i(xs[row], ys[row])
		var state: Dictionary = _actors.get(actor_id, {})
		if state.is_empty():
			var sprite := SpriteRecordType.new()
			sprite.sprite_frames = _frames[key]
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
			_actors.erase(actor_id)
	queue_redraw()

func _apply(state: Dictionary) -> void:
	var sprite: SpriteRecordType = state["sprite"]
	var animation := "walk" if bool(state["moved"]) else "idle"
	if sprite.animation != animation:
		sprite.animation = animation
	var frames: SpriteFrames = sprite.sprite_frames
	var count := frames.get_frame_count(animation)
	sprite.frame = posmod(int(floor(float(state["elapsed"]) * frames.get_animation_speed(animation))), count)
	sprite.flip_h = bool(state["flip_h"])
	var frame_size := frames.get_frame_texture(animation, 0).get_size()
	var feet := float(_feet[state["key"]][animation])
	var tile := Vector2(state["tile"])
	sprite.position = tile * TILE_SIZE + Vector2(TILE_SIZE / 2.0 - frame_size.x / 2.0, TILE_SIZE - feet)

func _draw() -> void:
	for state: Dictionary in _actors.values():
		(state["sprite"] as SpriteRecordType).draw(self)

## The drawn sprite of an actor id (tests), or null.
func sprite_for(actor_id: String) -> SpriteRecordType:
	return _actors.get(actor_id, {}).get("sprite", null)
