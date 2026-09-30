extends Node2D

## Presentation-only colonist sprites. WorldState remains the sole source of
## grid position (previous_tile/current_tile/facing tracked here are a
## derived, presentation-only cache, per-colonist, never fed back into
## simulation). refresh() (once per WorldState.tick(), via the ticked signal)
## updates that cache; advance(delta) (every rendered frame, from _process()
## below, and directly callable by tests with no scene loop) turns real
## elapsed time into a glide fraction `t` over one full tile-crossing's real
## duration (seconds_per_tick() * move_ticks_per_tile, not
## seconds_per_tick() alone -- travel is continuous across tile boundaries).

const TILE_SIZE := 16.0
const FRAMES: SpriteFrames = preload("res://data/sprite_frames/colonist_frames.tres")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")

## Colonists are 64x64 px source frames with empty canvas around the
## silhouette: the character's feet sit at local y = 47, not the frame's raw
## bottom edge (63). Frames display at native 1.0 scale and are grounded on
## that feet line (FRAME_FEET_Y), not the frame's own edge, so the visible
## figure's feet sit on the tile's bottom
## edge. For tile (x, y) the feet point is (x*16 + 8, y*16 + 16); with
## sprite.centered = false, the top-left corner that puts a
## FRAME_SOURCE_SIZE-wide frame's bottom-center at FRAME_FEET_Y on that point
## is offset by (TILE_SIZE/2 - FRAME_SOURCE_SIZE*DISPLAY_SCALE/2,
## TILE_SIZE - FRAME_FEET_Y*DISPLAY_SCALE) from the tile's own raw pixel origin.
const FRAME_SOURCE_SIZE := 64.0
const FRAME_FEET_Y := 47.0
const DISPLAY_SCALE := 1.0
const SPRITE_POSITION_OFFSET := Vector2(
	TILE_SIZE / 2.0 - FRAME_SOURCE_SIZE * DISPLAY_SCALE / 2.0,
	TILE_SIZE - FRAME_FEET_Y * DISPLAY_SCALE)

## Carried-item marker offset from the colonist sprite's own top-left origin:
## above and to the right, so it reads as a
## badge on the sprite rather than overlapping its face.
const CARRIED_MARKER_OFFSET := Vector2(TILE_SIZE * 0.5, -TILE_SIZE * 0.25)
const CARRIED_MARKER_SIZE := Vector2(TILE_SIZE * 0.6, TILE_SIZE * 0.6)
## Separate left badge so a tool remains visible while carrying cargo.
## Resolve the held kind's registered art, just like carried cargo.
const TOOL_MARKER_OFFSET := Vector2(-TILE_SIZE * 0.25, -TILE_SIZE * 0.25)
const TOOL_MARKER_SIZE := Vector2(TILE_SIZE * 0.6, TILE_SIZE * 0.6)

## Trapped badge reuses the registered wolf actor crop: its hazard silhouette
## is a deliberately legible warning without introducing a second actor-art
## path or any simulation state. The tint distinguishes it from cargo/tool
## badges while keeping the source pixels nearest-neighbour.
const TRAPPED_MARKER_OFFSET := Vector2(TILE_SIZE * 0.1, -TILE_SIZE * 0.35)
const TRAPPED_MARKER_SIZE := Vector2(TILE_SIZE * 0.8, TILE_SIZE * 0.5)
const TRAPPED_MARKER_COLOR := Color("ff5b5b")

## Health bar: a thin two-rect bar (grey background, coloured
## fill) above the colonist's own sprite. health_bar_fill()/health_bar_color()
## are pure static functions -- callable on this script's own preload without
## instantiating a Node2D -- so a headless test can assert bar values without
## a live SceneTree.
const HEALTH_BAR_OFFSET := Vector2(0, -TILE_SIZE * 0.3)
const HEALTH_BAR_SIZE := Vector2(TILE_SIZE, 3.0)
const HEALTH_BAR_BACKGROUND := Color(0.15, 0.15, 0.15, 0.9)

## The bar's fill fraction (0..1, clamped): 0 for a maxHp <= 0 health dict
## instead of dividing by zero. `health` must be an ActorHealth-shaped
## {"hp", "maxHp"} Dictionary.
static func health_bar_fill(health: Dictionary) -> float:
	var max_hp := maxi(1, int(health.get("maxHp", 1)))
	return clampf(float(int(health.get("hp", 0))) / float(max_hp), 0.0, 1.0)

## Red (empty) to green (full) lerp for a given fill fraction.
static func health_bar_color(fill_fraction: float) -> Color:
	return Color.RED.lerp(Color.GREEN, clampf(fill_fraction, 0.0, 1.0))

var world
var _tick_driver
## Content's move_ticks_per_tile (world.get_move_ticks_per_tile(), cached once
## in set_world()): the number of ticks one full tile-crossing actually spans,
## per docs/architecture/orders-and-movement.md's "Route step semantics" --
## advance()'s glide duration is tick_interval * this, not tick_interval alone.
var _move_ticks_per_tile: int = 1

## Per-colonist id: {previous_tile: Vector2i, current_tile: Vector2i,
## elapsed: float, t: float, facing: "down"|"up"|"side", flip_h: bool,
## carrying: bool}. `elapsed`/`t` are advance()'s own glide clock, reset to 0
## whenever refresh() records a tile change; `facing`/`flip_h` persist across
## an idle stretch (an idle colonist keeps the facing of its last
## movement). Cleared wholesale by set_world() so the next refresh() treats
## every colonist as freshly spawned (case 1: snap, no glide).
var _motion: Dictionary = {}

var _sprites: Dictionary = {}
var _carried_markers: Dictionary = {}
var _tool_markers: Dictionary = {}
var _trapped_markers: Dictionary = {}
var _health_bar_backgrounds: Dictionary = {}
var _health_bar_fills: Dictionary = {}

## Item textures are keyed by actual kind for cargo and held-tool badges,
## refreshed even when the colonist sprite is reused.
var _item_atlas_texture: Texture2D
var _item_region: Rect2
var _cargo_textures: Dictionary = {}

func _init() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for kind in TileAtlasMapType.ITEM_ATLAS_MAP:
		_cargo_textures[kind] = load(TileAtlasMapType.ITEM_ATLAS_MAP[kind]["texture_path"])
	var wood_atlas = TileAtlasMapType.ITEM_ATLAS_MAP.get("wood")
	if wood_atlas != null:
		_item_atlas_texture = load(wood_atlas["texture_path"])
		_item_region = wood_atlas["rect"]

func set_world(world_ref) -> void:
	world = world_ref
	# Viewer purity (test_architecture_rules.gd): read once here through a
	# world.get_* call rather than through a second ContentRegistry load of
	# its own (ADR 010).
	_move_ticks_per_tile = world.get_move_ticks_per_tile() if world != null else 1
	# Load/New Game: drop every cached previous/current
	# tile so the next refresh() below sees no prior state for any colonist and
	# snaps each one (case 1), instead of gliding from a now-meaningless tile
	# left over from the previous world.
	_motion.clear()
	_refresh()

func refresh() -> void:
	_refresh()

## The shared TickDriver: advance() reads its seconds_per_tick()
## to convert real elapsed time into a glide fraction. Settable independently
## of set_world() (boot.gd wires it once at startup) and optional -- with none
## set, advance() treats every colonist as paused (t frozen at its last value).
func set_tick_driver(driver) -> void:
	_tick_driver = driver

func set_visible_for_art(enabled: bool) -> void:
	visible = enabled

func _process(delta: float) -> void:
	advance(delta)

## Real-time interpolation tick, called once per rendered frame
## by _process() above and directly callable by a headless test with no
## running SceneTree. Accumulates elapsed seconds since each colonist's last
## tile change and turns it into t = clamp(elapsed / glide_duration, 0, 1),
## where glide_duration is seconds_per_tick() * move_ticks_per_tile -- the
## real duration of one full tile-crossing (travel is continuous across tile
## boundaries; a single seconds_per_tick() is only one simulation tick, one
## quarter of a tile at the content-declared move_ticks_per_tile, so using it
## alone would make the sprite finish its glide early and then hold at the
## destination pixel for the remaining ticks). seconds_per_tick() == 0.0
## (paused) leaves elapsed/t untouched so the drawn position and animation
## frame freeze exactly where they were.
func advance(delta: float) -> void:
	var tick_interval: float = (_tick_driver.seconds_per_tick() * _move_ticks_per_tile) if _tick_driver != null else 0.0
	for colonist_id in _motion:
		var state: Dictionary = _motion[colonist_id]
		if tick_interval > 0.0:
			state["elapsed"] = float(state["elapsed"]) + delta
			state["t"] = clampf(float(state["elapsed"]) / tick_interval, 0.0, 1.0)
		_apply_motion_visual(colonist_id, state)

func _refresh() -> void:
	if world == null:
		return

	var current_ids: Dictionary = {}
	for colonist in world.get_colonists():
		var colonist_id: String = String(colonist["id"])
		current_ids[colonist_id] = true
		var tile := Vector2i(int(colonist["x"]), int(colonist["y"]))
		var state: Dictionary = _update_motion(colonist_id, tile, colonist)

		var sprite: AnimatedSprite2D = _sprites.get(colonist_id)
		if sprite == null:
			sprite = AnimatedSprite2D.new()
			sprite.sprite_frames = FRAMES
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			sprite.centered = false
			sprite.scale = Vector2(DISPLAY_SCALE, DISPLAY_SCALE)
			_sprites[colonist_id] = sprite
			add_child(sprite)

		# Carried-item marker: a small badge
		# over the colonist's own sprite, visible only while carrying. Added
		# after the AnimatedSprite2D each tick so it always draws on top,
		# mirroring how designation_overlay.gd is added last in map_view.gd
		# to stay above both renderers.
		var marker: Sprite2D = _carried_markers.get(colonist_id)
		if marker == null:
			marker = Sprite2D.new()
			marker.texture = _item_atlas_texture
			marker.region_enabled = true
			marker.region_rect = _item_region
			marker.centered = false
			marker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			_carried_markers[colonist_id] = marker
			add_child(marker)
		var carrying = colonist.get("carrying")
		var cargo: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP.get(String(carrying["kind"]), {}) if carrying != null else {}
		marker.visible = not cargo.is_empty()
		if marker.visible:
			marker.texture = _cargo_textures[String(carrying["kind"])]
			marker.region_rect = cargo["rect"]
			marker.scale = CARRIED_MARKER_SIZE / marker.region_rect.size

		var tool_marker: Sprite2D = _tool_markers.get(colonist_id)
		if tool_marker == null:
			tool_marker = Sprite2D.new()
			tool_marker.region_enabled = true
			tool_marker.centered = false
			tool_marker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			_tool_markers[colonist_id] = tool_marker
			add_child(tool_marker)
		var tool_id := String(colonist.get("held_tool", ""))
		var tool: Dictionary = world.get_tool_item(tool_id) if not tool_id.is_empty() else {}
		var tool_art: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP.get(String(tool.get("kind", "")), {})
		tool_marker.visible = not tool_art.is_empty()
		if tool_marker.visible:
			tool_marker.texture = _cargo_textures[String(tool["kind"])]
			tool_marker.region_rect = tool_art["rect"]
			tool_marker.scale = TOOL_MARKER_SIZE / tool_marker.region_rect.size

		var trapped_marker: Sprite2D = _trapped_markers.get(colonist_id)
		if trapped_marker == null:
			var actor_art: Dictionary = TileAtlasMapType.ACTOR_ATLAS_MAP["wolf"]
			trapped_marker = Sprite2D.new()
			trapped_marker.texture = load(actor_art["texture_path"])
			trapped_marker.region_enabled = true
			trapped_marker.region_rect = actor_art["rect"]
			trapped_marker.centered = false
			trapped_marker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			trapped_marker.scale = TRAPPED_MARKER_SIZE / trapped_marker.region_rect.size
			trapped_marker.modulate = TRAPPED_MARKER_COLOR
			_trapped_markers[colonist_id] = trapped_marker
			add_child(trapped_marker)
		trapped_marker.visible = colonist.get("trapped") != null

		# Drawn immediately at refresh()'s own current t (0 right after a fresh
		# tile change, or the last value advance() computed) so a caller that
		# never runs a frame loop -- test_colonist_panel_toil.gd's synchronous
		# refresh()-then-assert pattern -- still sees a consistent position.
		_apply_motion_visual(colonist_id, state)

	var stale_ids: Array[String] = []
	for colonist_id in _sprites.keys():
		if not current_ids.has(colonist_id):
			stale_ids.append(String(colonist_id))
	for colonist_id in stale_ids:
		var stale: AnimatedSprite2D = _sprites[colonist_id]
		_sprites.erase(colonist_id)
		_motion.erase(colonist_id)
		stale.queue_free()
		var stale_marker: Sprite2D = _carried_markers.get(colonist_id)
		if stale_marker != null:
			_carried_markers.erase(colonist_id)
			stale_marker.queue_free()
		var stale_tool: Sprite2D = _tool_markers.get(colonist_id)
		if stale_tool != null:
			_tool_markers.erase(colonist_id)
			stale_tool.queue_free()
		var stale_trapped: Sprite2D = _trapped_markers.get(colonist_id)
		if stale_trapped != null:
			_trapped_markers.erase(colonist_id)
			stale_trapped.queue_free()

	_refresh_health_bars()

## Updates (and returns) `colonist_id`'s cached motion state for its newly
## observed `tile`, applying four refresh-time rules:
## (1) no prior state (spawn/first sight) -> snap; (2) Chebyshev distance 1
## from the last current_tile -> glide (previous <- old current, t resets to
## 0); (3) Chebyshev distance > 1 (catch-up burst, teleport-like change) ->
## snap; distance 0 -> state unchanged except `carrying` (advance() keeps
## ticking its own elapsed/t independently). Facing/flip_h only change on an
## actual single-step move (case 2); an idle or snapped colonist keeps its
## last movement's facing.
func _update_motion(colonist_id: String, tile: Vector2i, colonist: Dictionary) -> Dictionary:
	var carrying: bool = colonist.get("carrying") != null
	var building: bool = _is_building(colonist)
	if not _motion.has(colonist_id):
		var fresh_state := {
			"previous_tile": tile, "current_tile": tile, "elapsed": 0.0, "t": 0.0,
			"facing": "down", "flip_h": false, "carrying": carrying, "building": building,
		}
		_motion[colonist_id] = fresh_state
		return fresh_state
	var state: Dictionary = _motion[colonist_id]
	state["carrying"] = carrying
	state["building"] = building
	var previous_current: Vector2i = state["current_tile"]
	if tile == previous_current:
		return state
	var step: Vector2i = tile - previous_current
	var chebyshev: int = maxi(absi(step.x), absi(step.y))
	if chebyshev == 1:
		state["previous_tile"] = previous_current
		state["current_tile"] = tile
		if absi(step.y) > absi(step.x):
			state["facing"] = "up" if step.y < 0 else "down"
			state["flip_h"] = false
		else:
			state["facing"] = "side"
			state["flip_h"] = step.x < 0
	else:
		state["previous_tile"] = tile
		state["current_tile"] = tile
	state["elapsed"] = 0.0
	state["t"] = 0.0
	return state

## The interpolated, feet-anchored pixel position shared by the
## AnimatedSprite2D and both markers: lerp(previous_tile, current_tile, t) in
## tile units, converted to pixels, then offset per docs/art/style.md's feet
## anchor rule.
func _drawn_position(state: Dictionary) -> Vector2:
	var previous := Vector2(state["previous_tile"])
	var current := Vector2(state["current_tile"])
	return previous.lerp(current, float(state["t"])) * TILE_SIZE + SPRITE_POSITION_OFFSET

## "carry_"|"" + "walk"|"idle" + "_" + facing, matching colonist_frames.tres's
## 12 walk/idle/carry animation names, plus up to 3 "build_"+facing entries
## (the build work toil's own animation; there is no carry_build variant
## since a colonist never carries cargo while working a workbench toil).
## Movement is current_tile != previous_tile, independent of t -- a colonist stays in its walk animation for the
## whole glide, not just while t < 1. A colonist mid-"build" job's work toil
## (state["building"], resolved in _update_motion()) always shows its build
## animation regardless of motion/carrying, since the work toil only ever
## runs while stationary -- unless that facing's build_* animation isn't
## registered on FRAMES, in which case this falls back to the plain idle
## pose for that facing rather than erroring on a missing animation name.
func _animation_name(state: Dictionary) -> String:
	if state.get("building", false):
		var build_animation := "build_%s" % state["facing"]
		if FRAMES.has_animation(build_animation):
			return build_animation
		return "idle_%s" % state["facing"]
	var moving: bool = state["current_tile"] != state["previous_tile"]
	var prefix := "carry_" if state["carrying"] else ""
	var motion := "walk" if moving else "idle"
	return "%s%s_%s" % [prefix, motion, state["facing"]]

## Resolves whether `colonist` is currently in a "build" job's work toil
## (colonist-ai.md 3.6: colonist.work is populated only by the work toil).
## `colonist["work"]` carries only {job_id, ticks_remaining} (toil_executor.gd)
## -- no job kind -- so this looks the job up the same way colonist_panel.gd's
## own `_find_job()` already does (the only other viewer read of world.get_jobs()
## by job_id), which test_architecture_rules.gd's viewer-purity check already
## permits (any world.get_* call is allowed).
func _is_building(colonist: Dictionary) -> bool:
	var work = colonist.get("work")
	if work == null:
		return false
	for job in world.get_jobs():
		if job["id"] == work["job_id"]:
			# job_queue.gd's SITE_WORK_KIND: the only job kind whose toils
			# reach "work" under labour "build" (content/jobs.json) -- a
			# construction site's builder job, not a literal "build" kind.
			return String(job.get("kind", "")) == "site_work"
	return false

## Applies one colonist's current motion state to its sprite, both item
## markers, and the animation frame -- called from refresh() (t as last
## computed) and from advance() (t just recomputed from real elapsed time).
## The frame is set explicitly from floor(t * frame_count), never left to
## AnimatedSprite2D's own free-running autoplay timer, so it freezes under the
## paused rule and stays in lock-step with the tick interval at any speed.
func _apply_motion_visual(colonist_id: String, state: Dictionary) -> void:
	var sprite: AnimatedSprite2D = _sprites.get(colonist_id)
	if sprite == null:
		return
	var position := _drawn_position(state)
	sprite.position = position
	sprite.flip_h = bool(state["flip_h"])
	var animation_name := _animation_name(state)
	if sprite.animation != animation_name:
		sprite.animation = animation_name
	if sprite.is_playing():
		sprite.stop()
	var frame_count := sprite.sprite_frames.get_frame_count(animation_name)
	sprite.frame = clampi(int(floor(float(state["t"]) * frame_count)), 0, frame_count - 1)

	var marker: Sprite2D = _carried_markers.get(colonist_id)
	if marker != null:
		marker.position = position + CARRIED_MARKER_OFFSET
	var tool_marker: Sprite2D = _tool_markers.get(colonist_id)
	if tool_marker != null:
		tool_marker.position = position + TOOL_MARKER_OFFSET
	var trapped_marker: Sprite2D = _trapped_markers.get(colonist_id)
	if trapped_marker != null:
		trapped_marker.position = position + TRAPPED_MARKER_OFFSET

## Health bar: every actor with a `health`
## component, not just the worker-only roster the sprite loop above renders
## -- WorldState.get_actors_with_health() (unlike get_colonists()) is not
## filtered to worker actors, so a wolf/trader gets its own bar even though
## this file has no dedicated sprite frames for one yet. A separate loop with
## its own stale-tracking, deliberately independent of `_sprites`'s own
## worker-only bookkeeping above.
func _refresh_health_bars() -> void:
	var current_ids: Dictionary = {}
	for actor in world.get_actors_with_health():
		var actor_id: String = String(actor["id"])
		current_ids[actor_id] = true
		var position := Vector2(int(actor["x"]) * TILE_SIZE, int(actor["y"]) * TILE_SIZE)
		var background: ColorRect = _health_bar_backgrounds.get(actor_id)
		var fill: ColorRect = _health_bar_fills.get(actor_id)
		if background == null:
			background = ColorRect.new()
			background.color = HEALTH_BAR_BACKGROUND
			background.size = HEALTH_BAR_SIZE
			_health_bar_backgrounds[actor_id] = background
			add_child(background)
			fill = ColorRect.new()
			fill.size = HEALTH_BAR_SIZE
			_health_bar_fills[actor_id] = fill
			add_child(fill)
		background.position = position + HEALTH_BAR_OFFSET
		var fill_fraction := health_bar_fill(actor.get("health", {}))
		fill.position = background.position
		fill.size = Vector2(HEALTH_BAR_SIZE.x * fill_fraction, HEALTH_BAR_SIZE.y)
		fill.color = health_bar_color(fill_fraction)

	var stale_ids: Array[String] = []
	for actor_id in _health_bar_backgrounds.keys():
		if not current_ids.has(actor_id):
			stale_ids.append(String(actor_id))
	for actor_id in stale_ids:
		var stale_background: ColorRect = _health_bar_backgrounds[actor_id]
		_health_bar_backgrounds.erase(actor_id)
		stale_background.queue_free()
		var stale_fill: ColorRect = _health_bar_fills[actor_id]
		_health_bar_fills.erase(actor_id)
		stale_fill.queue_free()
