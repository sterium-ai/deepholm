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
##
## A9: the layer keeps no node per colonist. Each colonist's body and badges are
## SpriteRecords (sprite_record.gd) and its health bar a small record, and one
## _draw() paints them layer by layer (bodies, cargo, tools, trapped, health
## bars). refresh() reads the WorldState.get_view_snapshot() it is given (boot.gd
## takes one per tick) instead of calling deep-copying getters itself.

const TILE_SIZE := 16.0
## The generated placeholder frames; replaced per instance by the Pixel
## Crawler pack's frames when the pack is synced (see _init() and
## docs/art/style.md, "Pack art and placeholders").
const FRAMES: SpriteFrames = preload("res://data/sprite_frames/colonist_frames.tres")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")
const PackAssetsType = preload("res://scripts/viewer/pack_assets.gd")
const SpriteRecordType = preload("res://scripts/viewer/sprite_record.gd")

## Work-toil animation prefix per job kind (+ "_" + facing). An animation the
## frames do not register falls back as before: "build" to idle, the others to
## the ordinary idle/walk choice -- the placeholder has only build_*.
const WORK_ANIMATION_BY_JOB_KIND := {
	"site_work": "build", "chop": "chop", "mine": "mine", "dig": "dig",
}

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
## elapsed: float, t: float, cycles: float, facing: "down"|"up"|"side",
## flip_h: bool, carrying: bool, work_animation: String}. `elapsed`/`t`/`cycles`
## (t unclamped) are advance()'s own glide clock, reset to 0
## whenever refresh() records a tile change; `facing`/`flip_h` persist across
## an idle stretch (an idle colonist keeps the facing of its last
## movement). Cleared wholesale by set_world() so the next refresh() treats
## every colonist as freshly spawned (case 1: snap, no glide).
var _motion: Dictionary = {}

## FRAMES, or the pack's frames. `_loop_work` is true only with the pack: its
## work strips loop once per tile-crossing duration while the colonist works
## (the placeholder's build_* keeps its t-driven timing unchanged).
var _frames: SpriteFrames = FRAMES
var _loop_work := false

## colonist id -> SpriteRecord, one Dictionary per drawn layer, in first-seen order.
var _sprites: Dictionary = {}
var _carried_markers: Dictionary = {}
var _tool_markers: Dictionary = {}
var _trapped_markers: Dictionary = {}
## actor id -> {"position": Vector2, "fill": float}: the bar's top-left and fill fraction.
var _health_bars: Dictionary = {}
var _trapped_texture: Texture2D
## The (read-only) columns of the last refresh()'s snapshot, to skip colonists that did not change.
var _last: Dictionary = {}

## Item textures are keyed by actual kind for cargo and held-tool badges,
## refreshed even when the colonist sprite is reused.
var _item_atlas_texture: Texture2D
var _item_region: Rect2
var _cargo_textures: Dictionary = {}
## With the pack (B3): item kind -> {texture, rect}, set by map_view.gd through
## use_item_icons(); a badge then keeps the icon's proportions.
var _pack_icons: Dictionary = {}

## `pack_root` is where the synced pack sheets live; tests pass a fixture
## root or a missing one.
func _init(pack_root: String = PackAssetsType.DEFAULT_ROOT) -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var pack_frames := PackAssetsType.colonist_frames(FRAME_SOURCE_SIZE, FRAME_FEET_Y, pack_root)
	if pack_frames != null:
		_frames = pack_frames
		_loop_work = true
	for kind in TileAtlasMapType.ITEM_ATLAS_MAP:
		_cargo_textures[kind] = load(TileAtlasMapType.ITEM_ATLAS_MAP[kind]["texture_path"])
	var wood_atlas = TileAtlasMapType.ITEM_ATLAS_MAP.get("wood")
	if wood_atlas != null:
		_item_atlas_texture = load(wood_atlas["texture_path"])
		_item_region = wood_atlas["rect"]
	_trapped_texture = load(TileAtlasMapType.ACTOR_ATLAS_MAP["wolf"]["texture_path"])

## Cargo and held-tool badges draw these pack icons (pack_assets.gd's
## item_icons()) instead of the placeholder sheets.
func use_item_icons(icons: Dictionary) -> void:
	_pack_icons = icons

## Points `badge` at `kind`'s icon and sizes it to `box`: the placeholder
## region stretched to the box as before, a pack icon uniformly scaled.
func _set_badge(badge: SpriteRecordType, kind: String, placeholder_rect: Rect2, box: Vector2) -> void:
	var icon: Dictionary = _pack_icons.get(kind, {})
	if icon.is_empty():
		badge.texture = _cargo_textures[kind]
		badge.region_rect = placeholder_rect
		badge.scale = box / badge.region_rect.size
		return
	badge.texture = icon["texture"]
	badge.region_rect = icon["rect"]
	var factor := minf(box.x / badge.region_rect.size.x, box.y / badge.region_rect.size.y)
	badge.scale = Vector2(factor, factor)

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
	_last = {}
	_refresh({})

## `snapshot` is this tick's WorldState.get_view_snapshot(); {} takes a fresh one.
func refresh(snapshot: Dictionary = {}) -> void:
	_refresh(snapshot)

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
			state["cycles"] = float(state["elapsed"]) / tick_interval
			state["t"] = clampf(float(state["cycles"]), 0.0, 1.0)
		_apply_motion_visual(colonist_id, state)
	if tick_interval > 0.0 and not _motion.is_empty():
		queue_redraw()

## Reads the snapshot's columns (view_snapshot.gd). When the actor table holds the
## same ids in the same rows as last refresh, a colonist whose tile, cargo, tool,
## trapped flag and work kind are all unchanged is skipped: its records already show
## exactly that, and advance() keeps its glide moving.
func _refresh(snapshot: Dictionary) -> void:
	if world == null:
		return
	if snapshot.is_empty():
		snapshot = world.get_view_snapshot()
	var ids: Array = snapshot["ids"]
	var worker: Array = snapshot["worker"]
	var xs: Array = snapshot["x"]
	var ys: Array = snapshot["y"]
	var carrying: Array = snapshot["carrying"]
	var tools: Array = snapshot["tool_kinds"]
	var trapped: Array = snapshot["trapped"]
	var work_kinds: Array = snapshot["work_kinds"]
	var same_rows: bool = ids == _last.get("ids", [])
	var last_x: Array = _last.get("x", [])
	var last_y: Array = _last.get("y", [])
	var last_carrying: Array = _last.get("carrying", [])
	var last_tools: Array = _last.get("tool_kinds", [])
	var last_trapped: Array = _last.get("trapped", [])
	var last_work: Array = _last.get("work_kinds", [])
	var hp: Array = snapshot["hp"]
	var max_hp: Array = snapshot["max_hp"]
	var last_hp: Array = _last.get("hp", [])
	var last_max: Array = _last.get("max_hp", [])
	for row in ids.size():
		# Health bar: every actor with a `health` component (hp >= 0), not just the
		# worker roster below, so a wolf/trader gets its own bar even though this
		# file draws no body for one.
		if hp[row] >= 0:
			if not (same_rows and xs[row] == last_x[row] and ys[row] == last_y[row] and hp[row] == last_hp[row]
					and max_hp[row] == last_max[row]):
				_health_bars[ids[row]] = {"position": Vector2(xs[row] * TILE_SIZE, ys[row] * TILE_SIZE) + HEALTH_BAR_OFFSET,
					"fill": health_bar_fill({"hp": hp[row], "maxHp": max_hp[row]})}
		elif same_rows and last_hp[row] >= 0:
			_health_bars.erase(ids[row])
		if worker[row] == 0:
			continue
		if same_rows and xs[row] == last_x[row] and ys[row] == last_y[row] and carrying[row] == last_carrying[row] \
				and tools[row] == last_tools[row] and trapped[row] == last_trapped[row] and work_kinds[row] == last_work[row]:
			continue
		_refresh_colonist(ids[row], Vector2i(xs[row], ys[row]), carrying[row], tools[row], trapped[row] == 1,
			work_kinds[row])
	if not same_rows:
		_drop_missing(ids, worker, hp)
	_last = {"ids": ids, "x": xs, "y": ys, "carrying": carrying, "tool_kinds": tools, "trapped": trapped,
		"work_kinds": work_kinds, "hp": snapshot["hp"], "max_hp": snapshot["max_hp"]}
	queue_redraw()

func _refresh_colonist(colonist_id: String, tile: Vector2i, carried_kind: String, tool_kind: String, is_trapped: bool,
		work_kind: String) -> void:
	var state: Dictionary = _update_motion(colonist_id, tile, carried_kind != "", work_kind)

	if not _sprites.has(colonist_id):
		var body := SpriteRecordType.new()
		body.sprite_frames = _frames
		body.scale = Vector2(DISPLAY_SCALE, DISPLAY_SCALE)
		_sprites[colonist_id] = body

	# Carried-item marker: a small badge over the colonist's own sprite,
	# visible only while carrying. Its layer draws after every body (_draw()),
	# so it always sits on top.
	var marker: SpriteRecordType = _carried_markers.get(colonist_id)
	if marker == null:
		marker = SpriteRecordType.new()
		marker.texture = _item_atlas_texture
		marker.region_rect = _item_region
		_carried_markers[colonist_id] = marker
	var cargo: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP.get(carried_kind, {})
	marker.visible = not cargo.is_empty()
	if marker.visible:
		_set_badge(marker, carried_kind, cargo["rect"], CARRIED_MARKER_SIZE)

	var tool_marker: SpriteRecordType = _tool_markers.get(colonist_id)
	if tool_marker == null:
		tool_marker = SpriteRecordType.new()
		_tool_markers[colonist_id] = tool_marker
	var tool_art: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP.get(tool_kind, {})
	tool_marker.visible = not tool_art.is_empty()
	if tool_marker.visible:
		_set_badge(tool_marker, tool_kind, tool_art["rect"], TOOL_MARKER_SIZE)

	var trapped_marker: SpriteRecordType = _trapped_markers.get(colonist_id)
	if trapped_marker == null:
		trapped_marker = SpriteRecordType.new()
		trapped_marker.texture = _trapped_texture
		trapped_marker.region_rect = TileAtlasMapType.ACTOR_ATLAS_MAP["wolf"]["rect"]
		trapped_marker.scale = TRAPPED_MARKER_SIZE / trapped_marker.region_rect.size
		trapped_marker.modulate = TRAPPED_MARKER_COLOR
		_trapped_markers[colonist_id] = trapped_marker
	trapped_marker.visible = is_trapped

	# Drawn immediately at refresh()'s own current t (0 right after a fresh
	# tile change, or the last value advance() computed) so a caller that
	# never runs a frame loop -- test_colonist_panel_toil.gd's synchronous
	# refresh()-then-assert pattern -- still sees a consistent position.
	_apply_motion_visual(colonist_id, state)

## Forgets every colonist no longer among the snapshot's workers, and every health
## bar whose actor is gone or has no health component any more.
func _drop_missing(ids: Array, worker: Array, hp: Array) -> void:
	var current_ids := {}
	var health_ids := {}
	for row in ids.size():
		if worker[row] == 1:
			current_ids[ids[row]] = true
		if hp[row] >= 0:
			health_ids[ids[row]] = true
	for actor_id: String in _health_bars.keys():
		if not health_ids.has(actor_id):
			_health_bars.erase(actor_id)
	for colonist_id: String in _sprites.keys():
		if not current_ids.has(colonist_id):
			_sprites.erase(colonist_id)
			_motion.erase(colonist_id)
			_carried_markers.erase(colonist_id)
			_tool_markers.erase(colonist_id)
			_trapped_markers.erase(colonist_id)

## One pass per layer, in the order the per-colonist nodes used to stack:
## bodies, then the cargo, tool and trapped badges, then the health bars.
func _draw() -> void:
	for layer: Dictionary in [_sprites, _carried_markers, _tool_markers, _trapped_markers]:
		for record: SpriteRecordType in layer.values():
			record.draw(self)
	for bar: Dictionary in _health_bars.values():
		var bar_position: Vector2 = bar["position"]
		var fill_fraction: float = bar["fill"]
		draw_rect(Rect2(bar_position, HEALTH_BAR_SIZE), HEALTH_BAR_BACKGROUND, true)
		draw_rect(Rect2(bar_position, Vector2(HEALTH_BAR_SIZE.x * fill_fraction, HEALTH_BAR_SIZE.y)),
			health_bar_color(fill_fraction), true)

## Updates (and returns) `colonist_id`'s cached motion state for its newly
## observed `tile`, applying four refresh-time rules:
## (1) no prior state (spawn/first sight) -> snap; (2) Chebyshev distance 1
## from the last current_tile -> glide (previous <- old current, t resets to
## 0); (3) Chebyshev distance > 1 (catch-up burst, teleport-like change) ->
## snap; distance 0 -> state unchanged except `carrying` (advance() keeps
## ticking its own elapsed/t independently). Facing/flip_h only change on an
## actual single-step move (case 2); an idle or snapped colonist keeps its
## last movement's facing.
func _update_motion(colonist_id: String, tile: Vector2i, carrying: bool, work_kind: String) -> Dictionary:
	var work_animation: String = _work_animation(work_kind)
	if not _motion.has(colonist_id):
		var fresh_state := {
			"previous_tile": tile, "current_tile": tile, "elapsed": 0.0, "t": 0.0, "cycles": 0.0,
			"facing": "down", "flip_h": false, "carrying": carrying, "work_animation": work_animation,
		}
		_motion[colonist_id] = fresh_state
		return fresh_state
	var state: Dictionary = _motion[colonist_id]
	state["carrying"] = carrying
	state["work_animation"] = work_animation
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
	state["cycles"] = 0.0
	return state

## The interpolated, feet-anchored pixel position shared by the
## body and the badges: lerp(previous_tile, current_tile, t) in
## tile units, converted to pixels, then offset per docs/art/style.md's feet
## anchor rule.
func _drawn_position(state: Dictionary) -> Vector2:
	var previous := Vector2(state["previous_tile"])
	var current := Vector2(state["current_tile"])
	return previous.lerp(current, float(state["t"])) * TILE_SIZE + SPRITE_POSITION_OFFSET

## "carry_"|"" + "walk"|"idle" + "_" + facing, matching colonist_frames.tres's
## 12 walk/idle/carry animation names, plus the work toil's own animation
## (WORK_ANIMATION_BY_JOB_KIND prefix + "_" + facing; there is no carry_ work
## variant since a colonist never carries cargo while working).
## Movement is current_tile != previous_tile, independent of t -- a colonist stays in its walk animation for the
## whole glide, not just while t < 1. A colonist in a work toil
## (state["work_animation"], resolved in _update_motion()) always shows its
## work animation regardless of motion/carrying, since the work toil only ever
## runs while stationary -- unless that facing's animation isn't registered on
## the frames: then "build" falls back to the plain idle pose for that facing
## (rather than erroring on a missing animation name) and the other work kinds
## to the ordinary choice below, exactly as before they had an animation.
func _animation_name(state: Dictionary) -> String:
	var work: String = state.get("work_animation", "")
	if not work.is_empty():
		var work_animation := "%s_%s" % [work, state["facing"]]
		if _frames.has_animation(work_animation):
			return work_animation
		if work == "build":
			return "idle_%s" % state["facing"]
	var moving: bool = state["current_tile"] != state["previous_tile"]
	var prefix := "carry_" if state["carrying"] else ""
	var motion := "walk" if moving else "idle"
	return "%s%s_%s" % [prefix, motion, state["facing"]]

## The WORK_ANIMATION_BY_JOB_KIND prefix for a colonist whose work toil's job
## is of `work_kind` (the snapshot's work_kinds column: "" when it is in no work
## toil, colonist-ai.md 3.6), or "" when that kind has no work animation.
## job_queue.gd's SITE_WORK_KIND ("site_work") is the only job kind whose toils
## reach "work" under labour "build" (content/jobs.json) -- a construction site's
## builder job, not a literal "build" kind.
func _work_animation(work_kind: String) -> String:
	return String(WORK_ANIMATION_BY_JOB_KIND.get(work_kind, ""))

## Applies one colonist's current motion state to its sprite, both item
## markers, and the animation frame -- called from refresh() (t as last
## computed) and from advance() (t just recomputed from real elapsed time).
## The frame is set explicitly from floor(t * frame_count) -- or, for a pack
## work animation, from the unclamped glide clock so the swing loops once per
## tile-crossing duration -- never left to a free-running autoplay timer, so
## it freezes under the paused rule and stays in lock-step with the tick
## interval at any speed.
func _apply_motion_visual(colonist_id: String, state: Dictionary) -> void:
	var sprite: SpriteRecordType = _sprites.get(colonist_id)
	if sprite == null:
		return
	var position := _drawn_position(state)
	sprite.position = position
	sprite.flip_h = bool(state["flip_h"])
	var animation_name := _animation_name(state)
	if sprite.animation != animation_name:
		sprite.animation = animation_name
	var frame_count := sprite.sprite_frames.get_frame_count(animation_name)
	if _loop_work and not String(state["work_animation"]).is_empty():
		sprite.frame = posmod(int(floor(float(state["cycles"]) * frame_count)), frame_count)
	else:
		sprite.frame = clampi(int(floor(float(state["t"]) * frame_count)), 0, frame_count - 1)

	var marker: SpriteRecordType = _carried_markers.get(colonist_id)
	if marker != null:
		marker.position = position + CARRIED_MARKER_OFFSET
	var tool_marker: SpriteRecordType = _tool_markers.get(colonist_id)
	if tool_marker != null:
		tool_marker.position = position + TOOL_MARKER_OFFSET
	var trapped_marker: SpriteRecordType = _trapped_markers.get(colonist_id)
	if trapped_marker != null:
		trapped_marker.position = position + TRAPPED_MARKER_OFFSET
